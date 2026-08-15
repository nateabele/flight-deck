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
        self.preferences = persistence?.load() ?? Preferences()
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
}
