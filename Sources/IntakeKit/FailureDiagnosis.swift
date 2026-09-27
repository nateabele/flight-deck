import Foundation

/// Classifies a finished harness run — exit code, both streams, and whatever `HarnessOutput.parse`
/// threw — into a `Diagnosis` the human sees when a round pauses instead of stopping cleanly.
/// Rules are checked in a fixed order and matched case-insensitively; the first match wins.
public enum FailureDiagnosis {
    /// `harness` disambiguates the login command an `authExpired` diagnosis recommends when the
    /// failure text itself doesn't name one (a bare "401" or "unauthorized"). It isn't part of
    /// the brief's signature — callers that don't know which harness ran can omit it and get
    /// claude's login command by default.
    public static func classify(exitCode: Int32, stdout: Data, stderr: String, parseError: Error?,
                                 harness: Harness? = nil) -> Diagnosis {
        let outText = String(decoding: stdout, as: UTF8.self)
        let haystack = (stderr + "\n" + outText).lowercased()

        if haystack.contains("rate limit") || haystack.contains("429") || haystack.contains("usage limit") {
            return Diagnosis(category: .rateLimited, detail: tail(stderr, outText),
                              action: "Wait for the limit to reset, or switch this slot to another model.")
        }
        if haystack.contains("not logged in") || haystack.contains("authentication") || haystack.contains("unauthorized")
            || haystack.contains("401") || haystack.contains("claude /login") || haystack.contains("codex login") {
            let action: String
            if haystack.contains("codex login") {
                action = "Run `codex login` in a terminal"
            } else if haystack.contains("claude /login") {
                action = "Run `claude /login` in a terminal"
            } else {
                switch harness {
                case .codex: action = "Run `codex login` in a terminal"
                case .claude, .none: action = "Run `claude /login` in a terminal"
                }
            }
            return Diagnosis(category: .authExpired, detail: tail(stderr, outText), action: action)
        }
        if exitCode == 124 || haystack.contains("timed out") {
            return Diagnosis(category: .timeout, detail: tail(stderr, outText), action: "Retry the round.")
        }
        if exitCode == 0, let parseError {
            return Diagnosis(category: .invalidOutput, detail: "\(parseError)",
                              action: "The model returned something other than the schema — retry, or switch this slot's model.")
        }
        let lastThree = stderr.split(separator: "\n", omittingEmptySubsequences: false).suffix(3).joined(separator: "\n")
        return Diagnosis(category: .harnessError, detail: lastThree.isEmpty ? "exit \(exitCode)" : lastThree,
                          action: "Retry, or change this slot.")
    }

    /// A short excerpt for `detail` — stderr when there is any, otherwise stdout, since a
    /// harness that fails before producing output leaves stderr empty.
    private static func tail(_ stderr: String, _ stdout: String) -> String {
        let text = stderr.isEmpty ? stdout : stderr
        return String(text.prefix(200))
    }
}
