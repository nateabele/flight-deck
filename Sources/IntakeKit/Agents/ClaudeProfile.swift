import Foundation

/// Everything Flight Deck knows about the `claude` CLI that is not specific to tabs or to
/// headless planning (grok/gemini planning spec §3.0). The tab side (`ClaudeFlagCatalog`,
/// `ClaudeRoutingCatalog`, `AgentID.homeEnvironmentKey`, `PreferencesStore`'s marker blanking)
/// and the headless side (`HeadlessCommand`, `RoundExecutor`, triage defaults) all read these
/// answers from here, so a new model alias or a renamed variable is one edit, not five that
/// drift — the drift that left `fable` offered in Settings and unknown to planning.
public struct ClaudeProfile: AgentProfile {
    /// The variable that binds a claude process to an account's config directory.
    public static let homeEnvironmentKey = "CLAUDE_CONFIG_DIR"

    /// Set by Claude Code in every process it spawns. A claude started with it set believes it
    /// is a nested session and silently skips saving its transcript — so `--resume` then has
    /// nothing to resume, and a tab's rename sync goes dead.
    public static let childSessionMarker = "CLAUDE_CODE_CHILD_SESSION"

    /// Every variable that makes a claude child think it runs inside another Claude Code
    /// session. The headless harness, the index extractor and the intake runner all remove
    /// exactly these; before this list they each spelled the pair out by hand.
    public static let childSessionVariables = [childSessionMarker, "CLAUDECODE"]

    /// `environment` with the child-session variables removed.
    public static func scrubbingChildSession(_ environment: [String: String]) -> [String: String] {
        var scrubbed = environment
        for key in childSessionVariables { scrubbed.removeValue(forKey: key) }
        return scrubbed
    }

    /// The model catalog, static because claude has no model-list command. `--model` also
    /// accepts any full model name; these are the aliases that track the latest of each line,
    /// in the order `claude --help` (2026-08-11) and Settings have always listed them. The
    /// default is `opus`/`high`, Flight Deck's claude default everywhere since triage shipped.
    public static let catalog = ProfileModelCatalog(
        aliases: ["fable", "opus", "sonnet", "haiku"],
        listArguments: nil,
        defaultPlanningModel: "opus",
        defaultPlanningEffort: "high",
        // `--effort`'s values in claude 2.1.x `--help`. `ultra` is left out on purpose: it
        // enables delegation and is not a Pro tier (`RoundConfigEditor` relied on this).
        effortValues: ["low", "medium", "high", "xhigh", "max"])

    /// The home whose `.claude/settings.json` the built-in account's children read. Injectable
    /// so a test never reads the operator's own settings.
    public var userHome: URL

    public init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.userHome = userHome
    }

    public var id: AgentID { .claude }
    public var binaryName: String { "claude" }

    /// `claude auth status`: local, read-only, spends no tokens. Probed 2026-10-07 on claude
    /// 2.1.293 — signed in prints JSON with `"loggedIn": true` and exits 0; a config dir with no
    /// login prints `"loggedIn": false` and exits 1. Both are required, so a future build that
    /// exits 0 while signed out (or prints prose) can never read as ready.
    public var signInCheck: SignInCheck {
        SignInCheck(arguments: ["auth", "status"], signedOutHint: "Claude: run `claude auth login` in a terminal",
                    isSignedIn: { output in
                        guard output.exitCode == 0,
                              let obj = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any]
                        else { return false }
                        return obj["loggedIn"] as? Bool == true
                    })
    }

    public var modelCatalog: ProfileModelCatalog { Self.catalog }
    public func parseModelList(_ stdout: String) -> [String] { [] }
    public var hasNativeSchema: Bool { true }

    public func classify(error: AgentErrorSignal) -> AgentFailureKind? {
        AgentErrorVocabulary.classify(error)
    }

    /// The child's environment, from the caller's resolved `base`:
    /// - the account's `settings.json` `env` underneath `base` (`--restricted` drops the file,
    ///   and with it this machine's `ANTHROPIC_BASE_URL` proxy — see `ClaudeUserEnv`). nil reads
    ///   the built-in `~/.claude`, exactly as before accounts reached planning;
    /// - `CLAUDE_CONFIG_DIR` bound to a non-nil account, over anything the settings or `base`
    ///   said — a seat billed to one account must never run in another's home;
    /// - the child-session scrub LAST, so neither the settings file nor `base` can put the
    ///   marker back.
    public func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] {
        let configDirectory = account?.home ?? userHome.appendingPathComponent(".claude", isDirectory: true)
        var environment = ClaudeUserEnv.merged(into: base, configDirectory: configDirectory)
        if let account { environment[Self.homeEnvironmentKey] = account.home.path }
        return Self.scrubbingChildSession(environment)
    }
}
