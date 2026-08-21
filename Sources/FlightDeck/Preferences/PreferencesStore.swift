import FleetKit
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
        let loaded = persistence?.load()
        var migrated = loaded ?? Preferences()
        migrated.migrateAgentsIfNeeded()
        // Accounts must exist before anything resolves against them, project settings before
        // the global-flags fold has a claude row to land on either side of, so this order is
        // load-bearing, not incidental.
        migrated.migrateAccountsIfNeeded()
        migrated.migrateProjectSettingsIfNeeded()
        migrated.migrateGlobalFlagsIfNeeded()
        // Probes for an installed terminal, so it is done here rather than in the `tools`
        // getter: a computed property is not a place to touch `NSWorkspace`. The probe is
        // idempotent and only runs while `storedTools` is nil, and the write below settles it
        // on the launch that first runs it rather than leaving it to repeat until the user's
        // first edit.
        migrated.migrateToolsIfNeeded(terminalCommand: DefaultTerminalResolver.command())

        // Minted here rather than on first read of `installSuffix`, so that stays a pure read
        // — see its doc comment. Mutating `migrated` is also what persists it: the comparison
        // below sees a value that differs from what `load()` returned, so a freshly minted id
        // reaches disk on the same launch that minted it. That is the whole point of the
        // identifier — a suffix re-minted every launch breaks Bonjour rediscovery in exactly
        // the case it exists for, and property observers do not fire during `init`.
        if migrated.installID == nil { migrated.installID = UUID() }
        self.installSuffix = String(
            (migrated.installID ?? UUID()).uuidString.prefix(4)
        ).lowercased()

        self.preferences = migrated
        // Migration has to reach disk *here*. Assigning `preferences` inside `init` does not
        // fire the `didSet` above — Swift skips property observers on an initializing
        // assignment — so the only other write path is the user happening to edit a preference.
        // Without this the seeded accounts are re-minted with fresh `UUID()`s on every launch:
        // a `Session.accountID` stamped on launch 1 dangles on launch 2, and the tab restores
        // orphaned (no resume text, no `CLAUDE_CONFIG_DIR`, no watcher) under an "account no
        // longer exists" alert, re-persisting the dangling id so it never recovers.
        //
        // Guarded twice. A nil persistence stays hermetic — tests and `-FlightDeckResetState`
        // must not write anywhere — and a blob that migration did not actually change is not
        // rewritten, comparing against exactly what `load()` returned so a steady-state launch
        // touches no defaults key.
        if let persistence, migrated != loaded { persistence.save(migrated) }
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

    /// The account each of `agents` currently resolves to for `project` — what
    /// `NewSessionAffordance.menu`'s checkmark compares against, so a click in the dropdown
    /// and a bare ⌘N can never disagree about which login either one would use. An agent this
    /// project has no account for at all is simply absent from the map, not mapped to nil.
    func resolvedAccounts(for agents: [AgentSettings], project: String) -> [AgentID: UUID] {
        Dictionary(uniqueKeysWithValues: agents.compactMap { settings in
            account(for: settings.id, project: project).map { (settings.id, $0.id) }
        })
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

    // MARK: Paired devices

    var pairedDevices: [PairedDevice] { preferences.pairedDevices ?? [] }

    /// Four hex characters disambiguating this Mac's advertised Bonjour name, so a phone that
    /// remembers which Mac it paired with keeps resolving it after a relaunch. A suffix
    /// regenerated per launch would break rediscovery in exactly the case it exists for.
    ///
    /// Computed once in `init` rather than minted on first read. It is displayed in the
    /// pairing UI, and a getter that minted-and-persisted would mutate `@Published` state
    /// during a SwiftUI `body` evaluation — the "Modifying state during view update" hazard.
    /// Making it a stored `let` means the read is pure by construction rather than by
    /// convention about who is allowed to call it.
    let installSuffix: String

    /// What `FleetService` starts its listener with. A revoked device is absent here, which
    /// is the entirety of what revocation means — and an expired provisional one is filtered
    /// here too, so an unclaimed pairing window stops being a key the instant anything asks
    /// for the accepted set, rather than only once whoever is watching the clock remembers to
    /// prune it. `at` defaults to `Date()` and is a parameter only so a test can pin "after
    /// the window closed" without a real sleep.
    func deviceKeys(at now: Date = Date()) -> [FleetDeviceKey] {
        pairedDevices.filter { $0.isLive(at: now) }.map { $0.key() }
    }

    func upsert(_ device: PairedDevice) {
        var devices = pairedDevices
        if let at = devices.firstIndex(where: { $0.slot == device.slot }) {
            devices[at] = device
        } else {
            devices.append(device)
        }
        preferences.pairedDevices = devices
    }

    func revokeDevice(slot: UUID) {
        preferences.pairedDevices = pairedDevices.filter { $0.slot != slot }
    }

    /// The user naming a device on this Mac. Sticky: it marks the device user-named, so the
    /// name the phone claims in every `hello` stops overwriting it — see `adoptClaimedName`.
    func renameDevice(slot: UUID, to name: String) {
        mutateDevice(slot) {
            $0.name = name
            $0.storedUserNamed = true
        }
    }

    /// The device saying what it calls itself. Adopted on every attach, so renaming the
    /// phone shows up here too — but never over a name the user typed, which is the whole
    /// point of `PairedDevice.isUserNamed`.
    func adoptClaimedName(slot: UUID, _ name: String) {
        mutateDevice(slot) {
            guard !$0.isUserNamed else { return }
            $0.name = name
        }
    }

    func noteDeviceSeen(slot: UUID, at date: Date) {
        mutateDevice(slot) { $0.lastSeenAt = date }
    }

    private func mutateDevice(_ slot: UUID, _ body: (inout PairedDevice) -> Void) {
        var devices = pairedDevices
        guard let at = devices.firstIndex(where: { $0.slot == slot }) else { return }
        body(&devices[at])
        preferences.pairedDevices = devices
    }
}
