import Foundation

/// The ONE error vocabulary claude and codex classify through (grok/gemini planning spec §3.0).
///
/// Before this there were four lists, each written for one consumer and each missing the
/// others' spellings: `FailureDiagnosis`'s phrase checks, `RateLimitClassifier.kinds`,
/// `CodexTurnRecovery`'s transient allowlist, and `ClaudeSession`'s two hard-coded transient
/// kinds. A spelling one list learned never reached the others — claude's `overloaded` was
/// transient to claude's tab and unknown to codex's, and codex's `server_overloaded` was the
/// reverse. This table is their union, entry for entry: every
/// spelling an old list recognized classifies here exactly as that list did (pinned by
/// `AgentProfileMigrationTests`), and a spelling now reaches every consumer at once.
///
/// One table for both CLIs rather than one per profile: the kinds are disjoint in practice
/// (claude writes `overloaded`, codex `server_overloaded`), so sharing costs nothing, and a
/// consumer that does not know which CLI produced a kind (`RateLimitClassifier`, fed by L3's
/// usage service) still gets one answer.
public enum AgentErrorVocabulary {
    /// What one API-error kind means, and whether a retry can be expected to succeed.
    public struct KindMeaning: Sendable, Equatable {
        public var failure: AgentFailureKind
        /// Retrying soon is sensible. Deliberately NOT implied by `rateLimited`: a usage limit
        /// resets in hours, and auto-retrying it only spends the ladder hammering a closed door.
        public var transient: Bool
    }

    /// Every API-error kind either CLI is known to write, by its CLI's own spelling.
    ///
    /// - claude (transcript `error` key): `rate_limit`, `overloaded`, `server_error`. claude's
    ///   own record also carries `apiErrorIsTransient` for capacity-shaped 429s, which wins over
    ///   this table at the one site that has the record (`ClaudeSession`).
    /// - codex (rollout `codex_error_info`, snake_case — NOT the app-server schema's camelCase;
    ///   probed 2026-09-21 on codex-cli 0.155.1, where a 429 wrote
    ///   `response_too_many_failed_attempts`): everything else here.
    /// - `usage_limit_*`: the L3 usage meters' quota spellings (`RateLimitClassifier`).
    public static let kinds: [String: KindMeaning] = [
        // Quota and rate limits. Only codex's per-minute `rate_limit_exceeded` was ever on a
        // transient list; the rest stay non-transient as they were.
        "rate_limit": KindMeaning(failure: .rateLimited, transient: false),
        "rate_limit_exceeded": KindMeaning(failure: .rateLimited, transient: true),
        "usage_limit_exceeded": KindMeaning(failure: .rateLimited, transient: false),
        "usage_limit_reached": KindMeaning(failure: .rateLimited, transient: false),
        // Capacity. NOT rate limits: `RateLimitClassifier` must never roll an account over for
        // a server that is merely busy.
        "overloaded": KindMeaning(failure: .overloaded, transient: true),
        "server_error": KindMeaning(failure: .overloaded, transient: true),
        "server_overloaded": KindMeaning(failure: .overloaded, transient: true),
        "internal_server_error": KindMeaning(failure: .overloaded, transient: true),
        // Transport and retry exhaustion: transient, but neither a quota nor capacity. The 429
        // that `response_too_many_failed_attempts` carries is in its status, which
        // `RateLimitClassifier` reads on its own.
        "response_too_many_failed_attempts": KindMeaning(failure: .other, transient: true),
        "response_stream_connection_failed": KindMeaning(failure: .other, transient: true),
        "response_stream_disconnected": KindMeaning(failure: .other, transient: true),
        "http_connection_failed": KindMeaning(failure: .other, transient: true),
        // codex's unit variant for a rejected login (named in `CodexEventMapper`'s doc). New to
        // the table, and read by nothing that changes behaviour today.
        "unauthorized": KindMeaning(failure: .authExpired, transient: false),
    ]

    public static func meaning(ofKind kind: String?) -> KindMeaning? {
        kind.flatMap { kinds[$0] }
    }

    /// Whether an API error of this kind is worth retrying automatically.
    public static func isTransient(kind: String?) -> Bool {
        meaning(ofKind: kind)?.transient ?? false
    }

    // MARK: - Free text (stderr, structured error messages)

    /// Matched case-insensitively as substrings, rate limits before auth — the order
    /// `FailureDiagnosis` has always checked them in, so a "429 … unauthorized" stays a rate
    /// limit. Only ever applied to the CLI's own error channels, never to the model's prose.
    ///
    /// grok's spellings (grok 1.0.30's string table, Track G) are part of the union: its usage
    /// limits ("You hit your weekly limit.", "…the credit limit for your plan") say neither
    /// "rate limit" nor "429", so without them a spent SuperGrok pool read as a harness error
    /// and the human retried straight into it. Its signed-out error ("Not signed in.") was
    /// captured live; the limit spellings were never provoked. "403" is deliberately absent —
    /// grok uses it for both credit exhaustion and permission errors.
    static let rateLimitPhrases = ["rate limit", "429", "usage limit",
                                   "weekly limit", "credit limit", "out of credits", "usage balance exhausted",
                                   "spending limit", "too many requests", "payment required", "status 402"]
    static let authPhrases = ["not logged in", "authentication", "unauthorized", "401", "/login", "codex login",
                              "invalid api key",
                              "not authenticated", "not signed in", "session has expired", "credentials were rejected",
                              "grok login"]

    public static func classify(text: String) -> AgentFailureKind? {
        let lower = text.lowercased()
        if rateLimitPhrases.contains(where: lower.contains) { return .rateLimited }
        if authPhrases.contains(where: lower.contains) { return .authExpired }
        return nil
    }

    /// The error message one structured error event carries: codex `--json`'s `error` /
    /// `turn.failed`, or a claude result flagged `is_error` (whose `result` is then the error,
    /// not an answer). nil for anything else — agent messages and successful results are the
    /// model talking.
    public static func message(ofErrorEvent json: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        switch obj["type"] as? String {
        case "error": return obj["message"] as? String
        case "turn.failed": return (obj["error"] as? [String: Any])?["message"] as? String
        default:
            // Keyed on `is_error` itself rather than `type == "result"`: `--output-format json`
            // fixtures recorded before claude seats streamed are one bare result object.
            guard obj["is_error"] as? Bool == true else { return nil }
            // grok's failed `result` has no `result` text; its reason is in `errors[]` (strings,
            // probed signed out on grok 1.0.30) — read before the bare `subtype`
            // (`error_during_execution`), which says nothing a human can act on.
            let errors = (obj["errors"] as? [Any] ?? []).compactMap { $0 as? String ?? ($0 as? [String: Any])?["message"] as? String }
            return obj["result"] as? String ?? (errors.isEmpty ? nil : errors.joined(separator: "\n"))
                ?? obj["subtype"] as? String ?? "is_error"
        }
    }

    /// The shared classifier claude's and codex's profiles both answer with.
    public static func classify(_ signal: AgentErrorSignal) -> AgentFailureKind? {
        switch signal {
        case .stderr(let text): return classify(text: text)
        case .streamErrorEvent(let json): return message(ofErrorEvent: json).flatMap { classify(text: $0) }
        case .transcriptAPIError(let kind): return meaning(ofKind: kind)?.failure
        case .appServerError(_, let message): return classify(text: message)
        }
    }
}

/// One failure from several pieces of evidence: the most actionable wins. A rate limit beats an
/// auth failure (the order `FailureDiagnosis` always checked), and either beats a busy server.
public extension AgentFailureKind {
    static func strongest(_ kinds: [AgentFailureKind]) -> AgentFailureKind? {
        let order: [AgentFailureKind] = [.rateLimited, .authExpired, .overloaded, .other]
        return order.first(where: kinds.contains)
    }
}

public extension AgentProfile {
    /// Whether an API error of `kind` (the CLI's own spelling) is worth an automatic retry. An
    /// extension, not a protocol requirement, so every profile answers from the one vocabulary.
    func isTransient(apiErrorKind kind: String?) -> Bool {
        AgentErrorVocabulary.isTransient(kind: kind)
    }
}
