import Foundation

/// The Gemini planning harness, driven through Google's Antigravity CLI `agy` — NOT the `gemini`
/// CLI. Google stopped serving Google AI Pro / Ultra / free accounts from `gemini` on
/// 2026-06-18; an AI Pro account (billed through Google One) can only run headless through
/// `agy`. The harness's raw value and family stay `gemini`: the model family is what coverage
/// and the editor care about, the binary is an implementation detail of this profile.
///
/// Every fact below was read off `agy` 1.2.3's `--help` on 2026-10-07 unless it says "probed",
/// in which case it was exercised live on that date (see spec §10, Gemini column).
public struct GeminiProfile: AgentProfile {
    public init() {}
    public var id: Harness { .gemini }
    public var family: ModelFamily { .gemini }
    public var binaryName: String { "agy" }

    /// The one-line fix the editor shows next to a signed-out Gemini. `agy` signs in from its
    /// interactive first run; there is no `login` subcommand (agy 1.2.3 `--help`).
    public static let signInHint = "Gemini: run `agy` in a terminal to sign in"

    /// `agy models` is the sign-in check: signed out it prints "Please sign in to view
    /// available models" and exits 1 WITHOUT starting the OAuth flow (probed 2026-10-07), and
    /// signed in it lists the models — read-only, no tokens. It is the ONLY safe probe: a
    /// signed-out `agy -p` opens a Google sign-in in the browser instead of failing.
    public var signInCheck: SignInCheck {
        SignInCheck(arguments: ["models"], signedOutHint: Self.signInHint) { output in
            let text = (output.stdout + "\n" + output.stderr).lowercased()
            // A model list is also required: an exit-0 run that listed nothing proves nothing
            // about the account (and a stray `agy` that is not Antigravity's prints none).
            return output.exitCode == 0 && !text.contains("sign in") && !text.contains("not logged in")
                && !GeminiProfile().parseModelList(output.stdout).isEmpty
        }
    }

    /// Effort is `--effort low|medium|high` (agy 1.2.3 `--help`) — a real knob, so the editor
    /// shows it with exactly these three values rather than claude's five.
    public var modelCatalog: ProfileModelCatalog {
        ProfileModelCatalog(aliases: [], listArguments: ["models"],
                            defaultPlanningModel: Self.defaultPlanningModel,
                            defaultPlanningEffort: "high", effortValues: ["low", "medium", "high"])
    }

    /// PROVISIONAL until the signed-in probe reads `agy models`.
    public static let defaultPlanningModel = "gemini-3.8-pro"

    /// One model id per line of `agy models`. Banner lines ("Fetching available models...")
    /// and anything with spaces in it are not ids. PROVISIONAL format until the signed-in probe.
    public func parseModelList(_ stdout: String) -> [String] {
        stdout.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "* ", "• "] where line.hasPrefix(bullet) { line.removeFirst(bullet.count) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains(" "), !line.hasSuffix(":"), !line.hasSuffix("...") else { return nil }
            return line
        }
    }

    /// `agy --json-schema` constrains the final answer and returns it as `structured_output`.
    public var hasNativeSchema: Bool { true }

    public var headlessSignInPreflight: Bool { true }

    /// The spellings `agy` uses for the failures a seat row must name. Auth: "Authentication
    /// required" (stderr) and "authentication failed or timed out" (the result's `error`),
    /// probed signed out 2026-10-07; "not logged into Antigravity" from the binary's strings.
    /// Rate limit / overload: NOT observed — Google's API spellings (`RESOURCE_EXHAUSTED`,
    /// quota, 429 / `UNAVAILABLE`, 503), unverified until a real one is captured.
    public func classify(error: AgentErrorSignal) -> AgentFailureKind? {
        let text: String
        switch error {
        case .stderr(let s): text = s
        case .streamErrorEvent(let json): text = json
        case .transcriptAPIError(let kind): text = kind
        case .appServerError(_, let message): text = message
        }
        let t = text.lowercased()
        if ["resource_exhausted", "rate limit", "quota", "429", "too many requests"].contains(where: t.contains) {
            return .rateLimited
        }
        if ["authentication required", "authentication failed", "not logged in", "please sign in",
            "unauthenticated", "401"].contains(where: t.contains) {
            return .authExpired
        }
        if ["overloaded", "503", "\"unavailable\"", "status: unavailable"].contains(where: t.contains) {
            return .overloaded
        }
        return nil
    }

    /// The built-in account only. `agy` has no home-relocation variable (none in its `--help`
    /// or its binary's strings), keeps its login in the OS keyring keyed per user rather than
    /// per directory, and shares `~/.gemini` with the `gemini` CLI — so there is no directory
    /// a second account could be bound to. A non-nil `account` is therefore ignored rather than
    /// approximated with a `HOME` override, which would move agy's conversations (breaking
    /// `--conversation` resume) without moving its login.
    public func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] {
        var env = base
        // A planning seat is never a child session of whatever spawned Flight Deck.
        env.removeValue(forKey: "CLAUDE_CODE_CHILD_SESSION")
        env.removeValue(forKey: "CLAUDECODE")
        return env
    }
}
