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
        var loaded = persistence?.load() ?? Preferences()
        loaded.migrateAgentsIfNeeded()
        // Probes for an installed terminal, so it is done here rather than in the `tools`
        // getter: a computed property is not a place to touch `NSWorkspace`. The probe is
        // idempotent and only runs while `storedTools` is nil, so at worst it repeats once per
        // launch until the user's first edit persists the list.
        loaded.migrateToolsIfNeeded(terminalCommand: DefaultTerminalResolver.command())

        // Minted here rather than on first read of `installSuffix`, so that stays a pure read
        // — see its doc comment.
        let mintedNow = loaded.installID == nil
        if mintedNow { loaded.installID = UUID() }
        self.installSuffix = String(
            (loaded.installID ?? UUID()).uuidString.prefix(4)
        ).lowercased()
        self.preferences = loaded

        // Explicit, because `preferences`'s `didSet` does not fire during `init`. Without
        // this a freshly minted id never reaches disk and the next launch mints a different
        // one, which is the one failure this identifier exists to prevent.
        if mintedNow { persistence?.save(loaded) }
    }

    convenience init() {
        self.init(persistence: UserDefaultsPreferencesPersistence())
    }

    // MARK: Flags

    /// The flags a new session in `path` launches with: globals with the project's
    /// override applied per flag.
    func resolvedFlags(forProject path: String) -> FlagSet {
        FlagSetMerge.merge(
            global: preferences.globalFlags,
            project: preferences.projectFlags[Self.key(path)] ?? FlagSet()
        )
    }

    /// The `thread/start` options a new codex tab launches with.
    ///
    /// Codex's counterpart to `resolvedFlags(forProject:)`, minus the project layer: there
    /// is no per-project codex storage, so this is the one global row. Looked up by id
    /// rather than by position, because the list's order is the New Session shortcut
    /// binding and the user can reorder it — the same lookup `CodexOptionsForm` writes
    /// through, so the pane and the launch path cannot disagree about which row is codex's.
    func resolvedCodexOptions() -> CodexThreadOptions {
        guard case .codex(let options)? = preferences.agents.first(where: { $0.id == .codex })?.options
        else { return CodexThreadOptions() }
        return options
    }

    func projectOverride(_ path: String) -> FlagSet {
        preferences.projectFlags[Self.key(path)] ?? FlagSet()
    }

    func setProjectOverride(_ path: String, _ flags: FlagSet) {
        preferences.projectFlags[Self.key(path)] = flags
    }

    func removeProjectOverride(_ path: String) {
        preferences.projectFlags.removeValue(forKey: Self.key(path))
    }

    /// Sorted so the Projects tab's list order is stable across launches.
    var overriddenProjectPaths: [String] {
        preferences.projectFlags.keys.sorted()
    }

    /// Matches `SessionStore.indexOfRepo`, which compares `standardizedFileURL.path`.
    private static func key(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

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
    func sessionEnvironment(
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = preferences.shell.environment
        if preferences.shell.clearChildSessionMarker,
           inherited["CLAUDE_CODE_CHILD_SESSION"] != nil {
            environment["CLAUDE_CODE_CHILD_SESSION"] = ""
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

    func renameDevice(slot: UUID, to name: String) {
        mutateDevice(slot) { $0.name = name }
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
