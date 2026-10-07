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
        let events = errorEventJSON(in: stdout)
        let errorText = events.compactMap(AgentErrorVocabulary.message(ofErrorEvent:)).joined(separator: "\n")
        let haystack = (stderr + "\n" + errorText).lowercased()

        // The CLI's profile classifies each piece of evidence (stderr, and every structured
        // error event on its own). A profile that recognizes nothing — a grok/gemini stub until
        // Tracks G/M — falls back to the shared vocabulary, which is what every harness was
        // matched against before profiles existed.
        let profile = AgentProfiles.profile(for: harness ?? .claude)
        let signals = [AgentErrorSignal.stderr(stderr)] + events.map { .streamErrorEvent(json: $0) }
        let kind = AgentFailureKind.strongest(signals.compactMap { profile.classify(error: $0) ?? AgentErrorVocabulary.classify($0) })

        if kind == .rateLimited {
            return Diagnosis(category: .rateLimited, detail: tail(stderr, errorText),
                              action: "Wait for the limit to reset, or switch this slot to another model.")
        }
        if kind == .authExpired {
            let action: String
            if haystack.contains("codex login") {
                action = "Run `codex login` in a terminal"
            } else if haystack.contains("claude /login") {
                action = "Run `claude /login` in a terminal"
            } else {
                switch harness {
                case .codex: action = "Run `codex login` in a terminal"
                case .claude, .none: action = "Run `claude /login` in a terminal"
                // Generic until Tracks G/M probe each CLI's real sign-in flow: naming a command
                // nobody verified would send the human to run something that doesn't exist.
                case .grok?: action = "Sign in to `\(GrokProfile().binaryName)` in a terminal"
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
        errorEventJSON(in: stdout).compactMap(AgentErrorVocabulary.message(ofErrorEvent:))
    }

    /// The raw JSON text of each structured error event — what a profile classifies, as
    /// `AgentErrorSignal.streamErrorEvent`. Its message is read by the one shared
    /// `AgentErrorVocabulary.message(ofErrorEvent:)`.
    static func errorEventJSON(in stdout: Data) -> [String] {
        // Keyed on `is_error` itself, not on "stdout is one JSON object": a codex run that
        // printed only its `turn.failed` line is one object too.
        if let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any], let isError = obj["is_error"] as? Bool {
            return isError ? [String(decoding: stdout, as: UTF8.self)] : []
        }
        return stdout.split(separator: UInt8(ascii: "\n")).compactMap { line -> String? in
            let json = String(decoding: line, as: UTF8.self)
            return AgentErrorVocabulary.message(ofErrorEvent: json) == nil ? nil : json
        }
    }

    /// A short excerpt for `detail` — stderr when there is any, otherwise the structured error,
    /// since a harness that reports through `--json` may leave stderr empty. The END of it: a
    /// CLI states why it died last, after whatever banners and warnings came first.
    private static func tail(_ stderr: String, _ errorText: String) -> String {
        let text = stderr.isEmpty ? errorText : stderr
        return String(text.suffix(200))
    }
}
