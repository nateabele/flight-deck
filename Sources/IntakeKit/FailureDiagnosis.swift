import Foundation

/// Classifies a finished harness run — exit code, stderr, the structured error events in stdout,
/// and whatever `HarnessOutput.parse` threw — into a `Diagnosis` the human sees when a round pauses instead of stopping cleanly.
/// Rules are checked in a fixed order and matched case-insensitively; the first match wins.
public enum FailureDiagnosis {
    /// `harness` disambiguates the login command an `authExpired` diagnosis recommends when the
    /// failure text itself doesn't name one (a bare "401" or "unauthorized"). It isn't part of
    /// the brief's signature — callers that don't know which harness ran can omit it and get
    /// claude's login command by default.
    ///
    /// Only stderr and the harness's STRUCTURED error reports are read — never the agent's own
    /// text. A drafter whose plan discusses "401 authentication" and then crashes wrote those
    /// words as content; matching them sent the human off to log in again for a crash.
    public static func classify(exitCode: Int32, stdout: Data, stderr: String, parseError: Error?,
                                 harness: Harness? = nil) -> Diagnosis {
        let errorText = errorEvents(in: stdout).joined(separator: "\n")
        let haystack = (stderr + "\n" + errorText).lowercased()

        // grok's own spellings first: its usage-limit messages ("You hit your weekly limit.")
        // say neither "rate limit" nor "429", so the generic rules below would call a spent
        // SuperGrok pool a harness error and the human would retry straight into it.
        if harness == .grok, let kind = grokKind(stdout: stdout, stderr: stderr) {
            switch kind {
            case .rateLimited:
                return Diagnosis(category: .rateLimited, detail: tail(stderr, errorText),
                                 action: "Wait for Grok's usage limit to reset, or switch this slot to another model.")
            case .authExpired:
                return Diagnosis(category: .authExpired, detail: tail(stderr, errorText), action: "Run `grok login` in a terminal")
            case .overloaded, .other:
                break
            }
        }

        if haystack.contains("rate limit") || haystack.contains("429") || haystack.contains("usage limit") {
            return Diagnosis(category: .rateLimited, detail: tail(stderr, errorText),
                              action: "Wait for the limit to reset, or switch this slot to another model.")
        }
        if haystack.contains("not logged in") || haystack.contains("authentication") || haystack.contains("unauthorized")
            || haystack.contains("401") || haystack.contains("/login") || haystack.contains("codex login")
            || haystack.contains("invalid api key") {
            let action: String
            if haystack.contains("codex login") {
                action = "Run `codex login` in a terminal"
            } else if haystack.contains("claude /login") {
                action = "Run `claude /login` in a terminal"
            } else {
                switch harness {
                case .codex: action = "Run `codex login` in a terminal"
                case .claude, .none: action = "Run `claude /login` in a terminal"
                // `grok login` is grok 1.0.30's sign-in command (`grok login --help`).
                case .grok?: action = "Run `grok login` in a terminal"
                // Generic until Track M probes gemini's real sign-in flow: naming a command
                // nobody verified would send the human to run something that doesn't exist.
                case .gemini?: action = "Sign in to `\(GeminiProfile().binaryName)` in a terminal"
                }
            }
            return Diagnosis(category: .authExpired, detail: tail(stderr, errorText), action: action)
        }
        if exitCode == 124 || haystack.contains("timed out") {
            return Diagnosis(category: .timeout, detail: tail(stderr, errorText), action: "Retry the round.")
        }
        if exitCode == 0, let parseError {
            return Diagnosis(category: .invalidOutput, detail: "\(parseError)",
                              action: "The model returned something other than the schema — retry, or switch this slot's model.")
        }
        let text = stderr.isEmpty ? errorText : stderr
        let lastThree = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(3).joined(separator: "\n")
        return Diagnosis(category: .harnessError, detail: lastThree.isEmpty ? "exit \(exitCode)" : lastThree,
                          action: "Retry, or change this slot.")
    }

    /// The error messages a harness reported in its own structured output: codex `--json`'s
    /// `error` / `turn.failed` events, and a claude result flagged `is_error` (whose `result`
    /// is then the error, not an answer) — the whole of stdout under `--output-format json`,
    /// the last line under stream-json. Everything else in stdout — agent messages, a
    /// successful result — is the model talking and is skipped.
    static func errorEvents(in stdout: Data) -> [String] {
        // Keyed on `is_error` itself, not on "stdout is one JSON object": a codex run that
        // printed only its `turn.failed` line is one object too.
        if let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any], let isError = obj["is_error"] as? Bool {
            guard isError else { return [] }
            return [obj["result"] as? String ?? obj["subtype"] as? String ?? "is_error"]
        }
        return stdout.split(separator: UInt8(ascii: "\n")).compactMap { line -> String? in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
            switch obj["type"] as? String {
            case "error": return obj["message"] as? String
            case "turn.failed": return (obj["error"] as? [String: Any])?["message"] as? String
            case "result" where obj["is_error"] as? Bool == true:
                return obj["result"] as? String ?? obj["subtype"] as? String ?? "is_error"
            default: return nil
            }
        }
    }

    /// What `GrokProfile` makes of a grok run's stderr and of each structured error line in its
    /// stdout (an `error` event, or a `result` flagged `is_error`) — the first verdict wins.
    /// Only those channels are read, for the same reason as `errorEvents`.
    private static func grokKind(stdout: Data, stderr: String) -> AgentFailureKind? {
        let profile = GrokProfile()
        var signals: [AgentErrorSignal] = stderr.isEmpty ? [] : [.stderr(stderr)]
        for line in stdout.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let isError = obj["type"] as? String == "error"
                || (obj["type"] as? String == "result" && obj["is_error"] as? Bool == true)
            if isError { signals.append(.streamErrorEvent(json: String(decoding: line, as: UTF8.self))) }
        }
        return signals.lazy.compactMap { profile.classify(error: $0) }.first
    }

    /// A short excerpt for `detail` — stderr when there is any, otherwise the structured error,
    /// since a harness that reports through `--json` may leave stderr empty. The END of it: a
    /// CLI states why it died last, after whatever banners and warnings came first.
    private static func tail(_ stderr: String, _ errorText: String) -> String {
        let text = stderr.isEmpty ? errorText : stderr
        return String(text.suffix(200))
    }
}
