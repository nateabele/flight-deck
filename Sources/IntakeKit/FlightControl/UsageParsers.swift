import Foundation

/// Which reported failures mean "this account is out of quota", as opposed to "the API is having
/// a bad day". Only the first moves an account to over-hard: treating an overloaded API as
/// exhaustion would hand off every agent on every account at once, onto accounts that are just
/// as overloaded. Kinds are each agent's own spelling — claude's transcript `error`, codex's
/// rollout `codex_error_info` in snake_case (see `CodexTurnRecovery`).
///
/// The spellings are no longer kept here: every agent profile classifies them from the one
/// shared `AgentErrorVocabulary`. Asked of EVERY profile because a reported error carries no
/// harness here, and a profile that learns a spelling (grok's, gemini's) must reach the
/// usage meters without anyone remembering to copy it into a fifth list.
public enum RateLimitClassifier {
    /// Every kind any profile reads as a rate limit — derived, for callers that list them.
    public static var kinds: Set<String> {
        Set(AgentErrorVocabulary.kinds.keys.filter { isRateLimit(status: nil, kind: $0) })
    }

    public static func isRateLimit(status: Int?, kind: String?) -> Bool {
        if status == 429 { return true }
        guard let kind else { return false }
        return AgentProfiles.all.contains { $0.classify(error: .transcriptAPIError(kind: kind)) == .rateLimited }
    }
}

/// One spelling for a window across vendors, so the popover says "five_hour" for claude's
/// `five_hour` and codex's 300-minute primary alike.
public enum UsageWindowName {
    public static func forDuration(minutes: Int?) -> String {
        switch minutes {
        case 300?: return "five_hour"
        case 10080?: return "seven_day"
        case let m?: return "\(m)m"
        case nil: return "window"
        }
    }
}

/// One codex rate-limit bucket (`limitId`), as the app-server reports it.
public struct CodexRateBucket: Equatable, Sendable {
    public var limitId: String
    public var primary: UsageWindow?
    public var secondary: UsageWindow?
    /// Non-nil once codex says a limit was reached (`rate_limit_reached`, a depleted workspace…).
    public var reachedType: String?

    public init(limitId: String, primary: UsageWindow? = nil, secondary: UsageWindow? = nil, reachedType: String? = nil) {
        self.limitId = limitId; self.primary = primary; self.secondary = secondary; self.reachedType = reachedType
    }
}

/// `account/rateLimits/read` and `account/rateLimits/updated`, per the schema in
/// `codex-app-server-v2.generated.json`: `usedPercent` is an integer 0–100, `resetsAt` unix
/// seconds, `windowDurationMins` minutes.
public enum CodexRateLimitParser {
    static func window(_ raw: Any?, limitId: String) -> UsageWindow? {
        guard let w = raw as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (w["windowDurationMins"] as? NSNumber)?.intValue
        let resets = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let base = UsageWindowName.forDuration(minutes: minutes)
        return UsageWindow(name: limitId == "codex" ? base : "\(limitId):\(base)", utilization: used / 100, resetsAt: resets)
    }

    public static func bucket(_ snapshot: [String: Any]) -> CodexRateBucket {
        let id = snapshot["limitId"] as? String ?? "codex"
        return CodexRateBucket(limitId: id,
                               primary: window(snapshot["primary"], limitId: id),
                               secondary: window(snapshot["secondary"], limitId: id),
                               reachedType: snapshot["rateLimitReachedType"] as? String)
    }

    /// The multi-bucket view when the server sends one, else the backward-compatible single
    /// bucket. Keyed by `limitId`.
    public static func readResponse(_ result: [String: Any]) -> [String: CodexRateBucket] {
        if let byID = result["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            var out: [String: CodexRateBucket] = [:]
            for (key, value) in byID {
                guard var snapshot = value as? [String: Any] else { continue }
                if snapshot["limitId"] as? String == nil { snapshot["limitId"] = key }
                let b = bucket(snapshot)
                out[b.limitId] = b
            }
            return out
        }
        guard let single = result["rateLimits"] as? [String: Any] else { return [:] }
        let b = bucket(single)
        return [b.limitId: b]
    }

    /// A rolling update is sparse: the schema says a missing or null value "does not clear a
    /// previously observed value". So only what the update carries replaces what the last read
    /// said; the 120-second read (UsageService) is what corrects anything an update left stale.
    public static func merge(update params: [String: Any], into buckets: [String: CodexRateBucket]) -> [String: CodexRateBucket] {
        guard let snapshot = params["rateLimits"] as? [String: Any] else { return buckets }
        let id = snapshot["limitId"] as? String ?? "codex"
        var out = buckets
        var b = out[id] ?? CodexRateBucket(limitId: id)
        if let p = window(snapshot["primary"], limitId: id) { b.primary = p }
        if let s = window(snapshot["secondary"], limitId: id) { b.secondary = s }
        if let reached = snapshot["rateLimitReachedType"] as? String { b.reachedType = reached }
        out[id] = b
        return out
    }

    public static func reading(_ buckets: [String: CodexRateBucket], account: AccountRef, readAt: Date,
                               source: String = "codex app-server") -> UsageReading? {
        guard !buckets.isEmpty else { return nil }
        let ordered = buckets.keys.sorted().compactMap { buckets[$0] }
        let windows = ordered.flatMap { [$0.primary, $0.secondary].compactMap { $0 } }
        return UsageReading(account: account, windows: windows, readAt: readAt, source: source,
                            hardRejection: ordered.contains { $0.reachedType != nil })
    }
}

/// codex's rollout file (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<stamp>-<thread>.jsonl`), the
/// only place a headless `codex exec` run reports its account's rate limits: its `--json`
/// stdout carries token counts and nothing else (codex-cli 0.160.0, probed 2026-10-09), while
/// the rollout it writes has an `event_msg` `token_count` per turn whose `rate_limits` is the
/// app-server snapshot in snake_case — `used_percent` 0–100, `window_minutes`, `resets_at` unix
/// seconds, `limit_id`, `rate_limit_reached_type`.
public enum CodexRolloutRateLimits {
    /// The newest `token_count` in `text` that carries `rate_limits`, as buckets, with its
    /// timestamp. nil when no line carries one.
    public static func newest(inRolloutTail text: String) -> (buckets: [String: CodexRateBucket], readAt: Date?)? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }
            let id = limits["limit_id"] as? String ?? "codex"
            let bucket = CodexRateBucket(limitId: id, primary: window(limits["primary"], limitId: id),
                                         secondary: window(limits["secondary"], limitId: id),
                                         reachedType: limits["rate_limit_reached_type"] as? String)
            guard bucket.primary != nil || bucket.secondary != nil || bucket.reachedType != nil else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(timestamp(_:))
            return ([id: bucket], stamp)
        }
        return nil
    }

    static func window(_ raw: Any?, limitId: String) -> UsageWindow? {
        guard let w = raw as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (w["window_minutes"] as? NSNumber)?.intValue
        let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let base = UsageWindowName.forDuration(minutes: minutes)
        return UsageWindow(name: limitId == "codex" ? base : "\(limitId):\(base)", utilization: used / 100, resetsAt: resets)
    }

    static func timestamp(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

/// claude's stream-json `rate_limit_event.rate_limit_info`. `unifiedWindows` utilization is
/// already 0–1; `resetsAt` is unix seconds.
public enum ClaudeRateLimitParser {
    public static func windows(rateLimitInfo info: [String: Any]) -> [UsageWindow] {
        guard let unified = info["unifiedWindows"] as? [String: Any] else { return [] }
        return unified.keys.sorted().compactMap { name in
            guard let w = unified[name] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(name: name, utilization: u, resetsAt: resets)
        }
    }

    /// `allowed` and `allowed_warning` pass; anything else that is present is a refusal. An
    /// absent status is no evidence either way.
    public static func isRejected(rateLimitInfo info: [String: Any]) -> Bool {
        guard let status = info["status"] as? String else { return false }
        return !status.hasPrefix("allowed")
    }

    public static func resetsAt(rateLimitInfo info: [String: Any]) -> Date? {
        (info["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
}

/// The file Flight Deck's claude status line writes per tab: `<usage dir>/<id>.json`. `percentUsed`
/// is 0–100, as claude's `rate_limits.<window>.used_percentage`, so it is divided here, once.
/// The shape is the one the retired usage mod wrote, kept so files on disk stay readable; the
/// status line adds an `fp` key (its change detector) that this ignores.
public struct ClaudeUsageFile: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var kind: String
        public var percentUsed: Double
        public var resetsAt: Date?
        public init(kind: String, percentUsed: Double, resetsAt: Date?) { self.kind = kind; self.percentUsed = percentUsed; self.resetsAt = resetsAt }
    }
    public static let currentVersion = 1

    public var v: Int
    public var tab: String?
    public var session: String?
    public var readAt: Date
    public var rateLimits: [Window]

    public var windows: [UsageWindow] {
        rateLimits.map { UsageWindow(name: $0.kind, utilization: $0.percentUsed / 100, resetsAt: $0.resetsAt) }
    }

    static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    /// Nil for a torn write (the status line's write and this read can interleave; the next scan
    /// retries), a newer version, or a missing `readAt` — never a partial reading.
    public static func decode(_ data: Data) -> ClaudeUsageFile? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let v = (obj["v"] as? NSNumber)?.intValue, v <= currentVersion,
              let readAt = date(obj["readAt"]) else { return nil }
        let raw = obj["rateLimits"] as? [[String: Any]] ?? []
        let windows = raw.compactMap { w -> Window? in
            guard let kind = w["kind"] as? String, let pct = (w["percentUsed"] as? NSNumber)?.doubleValue else { return nil }
            return Window(kind: kind, percentUsed: pct, resetsAt: date(w["resetsAt"]))
        }
        return ClaudeUsageFile(v: v, tab: obj["tab"] as? String, session: obj["session"] as? String, readAt: readAt, rateLimits: windows)
    }
}

/// What the OpenCode adapter reports when its server answers with an `APIError`. Defined here,
/// not on that adapter's branch, so the meter can be built and tested before it merges.
public struct OpenCodeAPIErrorEvent: Equatable, Sendable {
    public var status: Int
    /// Seconds, from the `retry-after` header when the provider sent one.
    public var retryAfter: TimeInterval?
    public var message: String
    public var at: Date
    public init(status: Int, retryAfter: TimeInterval?, message: String, at: Date) {
        self.status = status; self.retryAfter = retryAfter; self.message = message; self.at = at
    }
}

/// OpenCode has no meter, only refusals: a 429 is the whole signal.
public enum OpenCodeRateLimit {
    /// Equals `HeadroomPolicy.rejectionBackoff` (15 min) — the rejection timeout when a 429
    /// names no reset time. Derived from the same source to avoid a drifted constant.
    public static let backoff: TimeInterval = HeadroomPolicy.rejectionBackoff

    public static func reading(for event: OpenCodeAPIErrorEvent, account: AccountRef) -> UsageReading? {
        guard event.status == 429 else { return nil }
        let windows = event.retryAfter.map {
            [UsageWindow(name: "retry-after", utilization: 1, resetsAt: event.at.addingTimeInterval($0))]
        } ?? []
        return UsageReading(account: account, windows: windows, readAt: event.at, source: "opencode 429", hardRejection: true)
    }
}
