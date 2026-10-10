import Foundation

/// Everything Flight Deck knows about the `codex` CLI that is not specific to tabs or to
/// headless planning (grok/gemini planning spec §3.0) — the codex half of what `ClaudeProfile`
/// is for claude.
public struct CodexProfile: AgentProfile {
    /// The variable that binds a codex process to an account's home. Auth, rollouts and
    /// `config.toml` all live under it.
    public static let homeEnvironmentKey = "CODEX_HOME"

    /// codex lists its models at runtime through the app-server's `model/list` RPC, not an
    /// argv command, so `listArguments` is nil and there are no static aliases: a hand-kept
    /// list of codex ids goes stale the day codex retires one. The default is the planning
    /// default since triage shipped. The effort values are the ones every listed model offers
    /// below `ultra` (`codex-model-list.json`, captured 2026-10-04), which is excluded for the
    /// reason `ClaudeProfile.catalog` gives.
    public static let catalog = ProfileModelCatalog(
        aliases: [],
        listArguments: nil,
        defaultPlanningModel: "gpt-6-sol",
        defaultPlanningEffort: "high",
        effortValues: ["low", "medium", "high", "xhigh", "max"])

    /// One entry of a `model/list` result.
    public struct ListedModel: Sendable, Equatable {
        public var id: String
        public var displayName: String
        public var efforts: [String]
    }

    /// Every visible model in a `model/list` result (all pages merged into one `data` array),
    /// the `isDefault` one first. Hidden models are left out — codex itself does not offer
    /// them. The routing catalog and `parseModelList` both read through this, so the two can
    /// never disagree on which models codex has.
    public static func listedModels(_ result: [String: Any]) -> [ListedModel] {
        var models: [ListedModel] = []
        var defaultIndex: Int?
        for m in result["data"] as? [[String: Any]] ?? [] where (m["hidden"] as? Bool) != true {
            guard let id = m["id"] as? String, !id.isEmpty else { continue }
            let efforts = (m["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            if m["isDefault"] as? Bool == true, defaultIndex == nil { defaultIndex = models.count }
            models.append(ListedModel(id: id, displayName: m["displayName"] as? String ?? id, efforts: efforts))
        }
        if let i = defaultIndex, i > 0 { models.insert(models.remove(at: i), at: 0) }
        return models
    }

    /// The home whose `.codex/config.toml` the built-in account's `service_tier` comes from.
    /// Injectable so a test never reads the operator's own config.
    public var userHome: URL

    public init(userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.userHome = userHome
    }

    public var id: AgentID { .codex }
    public var binaryName: String { "codex" }

    /// `codex login status`: local, read-only, spends no tokens. Probed 2026-10-07 on
    /// codex-cli 0.160.0 — signed in exits 0 (and prints "Logged in using ChatGPT" on STDERR,
    /// not stdout); a home with no login prints "Not logged in" and exits 1. The exit code is
    /// the only part stable enough to judge.
    public var signInCheck: SignInCheck {
        SignInCheck(arguments: ["login", "status"], signedOutHint: "Codex: run `codex login` in a terminal",
                    isSignedIn: { $0.exitCode == 0 })
    }

    public var modelCatalog: ProfileModelCatalog { Self.catalog }

    /// Model ids from the JSON text of a `model/list` result (`{"data": [...]}`), default first.
    public func parseModelList(_ stdout: String) -> [String] {
        guard let result = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else { return [] }
        return Self.listedModels(result).map(\.id)
    }

    /// `codex exec --output-schema`.
    public var hasNativeSchema: Bool { true }

    public func classify(error: AgentErrorSignal) -> AgentFailureKind? {
        AgentErrorVocabulary.classify(error)
    }

    /// `base` with `CODEX_HOME` bound to a non-nil account. nil is `base` exactly — the
    /// built-in home, as before accounts reached planning. codex has no child-session marker
    /// of its own, and claude's means nothing to it, so there is nothing to scrub; codex's one
    /// isolation casualty, `service_tier`, is argv, not environment (`serviceTierArguments`).
    public func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] {
        guard let account else { return base }
        var environment = base
        environment[Self.homeEnvironmentKey] = account.home.path
        return environment
    }

    /// `-c service_tier="…"` from the config `--ignore-user-config` dropped: the account's own
    /// `config.toml` when one is bound (its home IS the `CODEX_HOME` the run reads auth from),
    /// else the built-in `~/.codex`. Nothing when the file sets none.
    public func serviceTierArguments(account: AgentAccountRef?) -> [String] {
        CodexUserConfig.arguments(configDirectory: account?.home ?? userHome.appendingPathComponent(".codex", isDirectory: true))
    }
}
