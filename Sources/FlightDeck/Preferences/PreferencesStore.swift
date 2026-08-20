import Foundation
import SwiftUI

@MainActor
protocol PreferencesPersisting: AnyObject {
    func load() -> Preferences?
    func save(_ preferences: Preferences)
}

/// Preferences belong in `UserDefaults` — that is what the defaults system is for, and unlike
/// the session graph (see `FileSessionPersistence`) they are small, user-tunable, and cheap to
/// lose. The UITest gate stays hermetic by constructing `PreferencesStore` with a nil
/// persistence under `-FlightDeckResetState` (see `FlightDeckApp`), not by deleting this key.
@MainActor
final class UserDefaultsPreferencesPersistence: PreferencesPersisting {
    private let defaults: UserDefaults
    private let key = "preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Preferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    func save(_ preferences: Preferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Single source of truth for preferences. Owned by `FlightDeckApp` and read by both the
/// Preferences window and `SessionStore` at session-creation time.
@MainActor
final class PreferencesStore: ObservableObject {
    @Published var preferences: Preferences {
        didSet { persistence?.save(preferences) }
    }

    private let persistence: PreferencesPersisting?

    init(persistence: PreferencesPersisting?) {
        self.persistence = persistence
        var loaded = persistence?.load() ?? Preferences()
        loaded.migrateAgentsIfNeeded()
        // Accounts must exist before anything resolves against them, project settings before
        // the global-flags fold has a claude row to land on either side of, so this order is
        // load-bearing, not incidental.
        loaded.migrateAccountsIfNeeded()
        loaded.migrateProjectSettingsIfNeeded()
        loaded.migrateGlobalFlagsIfNeeded()
        // Probes for an installed terminal, so it is done here rather than in the `tools`
        // getter: a computed property is not a place to touch `NSWorkspace`. The probe is
        // idempotent and only runs while `storedTools` is nil, so at worst it repeats once per
        // launch until the user's first edit persists the list.
        loaded.migrateToolsIfNeeded(terminalCommand: DefaultTerminalResolver.command())
        self.preferences = loaded
    }

    convenience init() {
        self.init(persistence: UserDefaultsPreferencesPersistence())
    }

    // MARK: Accounts

    /// Matches `SessionStore.indexOfRepo`, which compares `standardizedFileURL.path`.
    private static func key(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    func account(id: UUID) -> AgentAccount? { preferences.accounts.first { $0.id == id } }

    /// The account a new session for `agent` in `project` launches under. nil is BROKEN — an
    /// explicit assignment that no longer resolves must never silently become another login.
    func account(for agent: AgentID, project: String) -> AgentAccount? {
        if let assigned = preferences.projectSettings[Self.key(project)]?.accounts[agent] {
            return account(id: assigned)
        }
        return preferences.accounts.first { $0.agent == agent }
    }

    /// Normalises a stored `Session.accountID`. nil means the agent's built-in home — not "the
    /// current default" — so a legacy tab and a tab created today on that home share one
    /// identity, and one home can never carry two instance keys.
    func resolvedAccountID(for agent: AgentID, in stored: UUID?) -> UUID? {
        if let stored { return account(id: stored)?.id }
        return preferences.accounts.first { $0.agent == agent && $0.isBuiltIn }?.id
    }

    /// Global agent options merged with the project's. Applies whenever that agent launches
    /// here, independently of `defaultAgent` — the Projects dropdown chooses what you edit and
    /// what ⌘N picks, not whether an override is in force.
    func resolvedOptions(for agent: AgentID, project: String) -> AgentOptions {
        let global = preferences.agents.first { $0.id == agent }?.options
        let override = preferences.projectSettings[Self.key(project)]?.options[agent]
        switch (global ?? Self.emptyOptions(for: agent), override) {
        case (.claude(let g), .claude(let p)?): return .claude(FlagSetMerge.merge(global: g, project: p))
        case (.codex(let g), .codex(let p)?):   return .codex(CodexThreadOptions.merge(global: g, project: p))
        case (let g, _):                        return g
        }
    }

    private static func emptyOptions(for agent: AgentID) -> AgentOptions {
        switch agent {
        case .claude: return .claude(FlagSet())
        case .codex:  return .codex(CodexThreadOptions())
        }
    }

    /// The agent list as this project sees it: its default agent promoted to the front, every
    /// other agent following in global order. Feeds `NewSessionAffordance`, so ⌘N is always the
    /// project's agent and no agent is left unreachable by shortcut.
    func agentOrder(forProject project: String) -> [AgentSettings] {
        let global = preferences.agents
        guard let preferred = preferences.projectSettings[Self.key(project)]?.defaultAgent,
              let row = global.first(where: { $0.id == preferred })
        else { return global }
        return [row] + global.filter { $0.id != preferred }
    }

    func homeIsTaken(_ home: URL, excluding id: UUID?) -> Bool {
        preferences.accounts.contains { $0.id != id && AgentAccount.key($0.home) == AgentAccount.key(home) }
    }

    func addAccount(_ account: AgentAccount) { preferences.accounts.append(account) }

    func renameAccount(id: UUID, to name: String) {
        guard let index = preferences.accounts.firstIndex(where: { $0.id == id }) else { return }
        preferences.accounts[index].displayName = name
    }

    func relocateAccount(id: UUID, to home: URL) {
        guard let index = preferences.accounts.firstIndex(where: { $0.id == id }) else { return }
        preferences.accounts[index].home = home
        preferences.accounts[index].cachedIdentity =
            AccountDirectory.identity(atHome: home, agent: preferences.accounts[index].agent)
    }

    /// Drops the account AND every project assignment naming it, so nothing is left pointing at
    /// an id that no longer resolves. A record emptied by that clearing is removed, matching how
    /// an emptied flag override already drops a project from the list.
    func removeAccount(id: UUID) {
        preferences.accounts.removeAll { $0.id == id }
        for (path, var settings) in preferences.projectSettings {
            let before = settings.accounts
            settings.accounts = settings.accounts.filter { $0.value != id }
            guard settings.accounts != before else { continue }
            preferences.projectSettings[path] = settings.isEmpty ? nil : settings
        }
    }

    func projectSettings(_ path: String) -> ProjectSettings {
        preferences.projectSettings[Self.key(path)] ?? ProjectSettings()
    }

    /// The single write path, so an emptied record can never linger with its badge hidden and
    /// its Remove button disabled.
    func setProjectSettings(_ path: String, _ settings: ProjectSettings) {
        preferences.projectSettings[Self.key(path)] = settings.isEmpty ? nil : settings
    }

    /// Sorted so the Projects tab's list order is stable across launches.
    var configuredProjectPaths: [String] { preferences.projectSettings.keys.sorted() }

    // MARK: Shell

    func resolvedShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        ShellResolver.resolve(environment: environment, override: preferences.shell.shellOverride)
    }

    /// The environment overrides handed to `Ghostty.SurfaceConfiguration`. Only the deltas
    /// are returned; libghostty merges them over the inherited environment.
    ///
    /// The marker is blanked rather than removed because the surface config can only *set*
    /// variables, not unset them — and `claude` treats an empty value as absent.
    ///
    /// `account` is what actually binds the tab's shell to a login, and it is applied **last**
    /// — over anything typed into the Shell pane. A user who typed `CLAUDE_CONFIG_DIR` there
    /// must not be able to silently repoint a tab at another home: every watcher, every
    /// registry key and every resumed conversation is derived from the account the tab was
    /// stamped with, so a hand-typed variable that disagreed would produce a tab observed in
    /// one home and running in another. nil means no account to bind to — a store with none
    /// configured — and leaves the environment exactly as it was before accounts existed.
    ///
    /// The pair is built here rather than through `AgentAdapter.environment(for:)` on purpose:
    /// preferences must not depend on the adapter layer, and `AgentID` already owns the
    /// variable's name, so this is the same expression that default evaluates.
    func sessionEnvironment(
        for account: AgentAccount? = nil,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = preferences.shell.environment
        if preferences.shell.clearChildSessionMarker,
           inherited["CLAUDE_CODE_CHILD_SESSION"] != nil {
            environment["CLAUDE_CODE_CHILD_SESSION"] = ""
        }
        if let account {
            environment[account.agent.homeEnvironmentKey] = account.home.path
        }
        return environment
    }

    // MARK: Confirmations

    /// Whether closing a project with several sessions asks first. Phrased positively — the
    /// stored flag is a suppression, but every reader wants the question, and a checkbox
    /// labelled with a negative is a checkbox people get backwards.
    var confirmsProjectClose: Bool {
        get { !(preferences.confirmations?.suppressProjectClose ?? false) }
        set {
            var confirmations = preferences.confirmations ?? ConfirmationPreferences()
            confirmations.suppressProjectClose = !newValue
            preferences.confirmations = confirmations
        }
    }

    // MARK: Claude

    /// Whether sessions recorded as working at shutdown are prompted to continue on the
    /// next launch. Reads through the optional so an unconfigured `Preferences` is off.
    var autoResumesRunningSessions: Bool {
        get { preferences.claude?.autoResumeRunningSessions ?? false }
        set {
            var claude = preferences.claude ?? ClaudePreferences()
            claude.autoResumeRunningSessions = newValue
            preferences.claude = claude
        }
    }

    // MARK: Tools

    /// The configured tools, in overlay order. The single accessor the menu, the overlay and
    /// the preferences pane all read and write through.
    var tools: [ToolDefinition] {
        get { preferences.tools }
        set { preferences.tools = newValue }
    }
}
