import OSLog
import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences: PreferencesStore
    @StateObject private var store: SessionStore
    @StateObject private var fleet: FleetService

    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "fleet")

    /// `-FlightDeckResetState YES`, the UITest's "start from a known slate" switch.
    ///
    /// It gates *both* stores. It used to cover only sessions, because `scripts/smoke.sh`
    /// deleted the whole defaults domain and so reset preferences as a side effect. That
    /// deletion also destroyed the developer's real sessions and preferences on every run, so
    /// it is gone — which means this flag now has to do the isolating itself.
    private static var isResettingState: Bool {
        UserDefaults.standard.bool(forKey: "FlightDeckResetState")
    }

    /// `-FlightDeckSeedSecondProject YES`. Used by exactly one UI test, the one that drags a
    /// project heading to reorder it: that needs two projects in the sidebar, and the only
    /// production route to a second one is an `NSOpenPanel`, which a UI test cannot drive
    /// reliably. Gated on `isResettingState` at its call site so it cannot fire in a real
    /// launch even if the default were somehow set.
    private static var isSeedingSecondProject: Bool {
        UserDefaults.standard.bool(forKey: "FlightDeckSeedSecondProject")
    }

    /// `-FlightDeckStateDir <path>`. Puts `sessions.json` somewhere other than
    /// `~/Library/Application Support/Flight Deck`, so a second instance can be run against a
    /// *copy* of a real deck without touching the original.
    ///
    /// This exists because there was no other way to do it. Redirecting `HOME` does not work:
    /// `FileSessionPersistence.defaultDirectory()` goes through
    /// `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`, which
    /// resolves the real home via `getpwuid` and ignores the environment entirely. A debug run
    /// launched that way silently restores the developer's live sessions and starts a second
    /// `claude --resume` for every one of them — the duplicate-instance collision
    /// `scripts/swap-release.sh` warns about, reached by accident rather than by executing the
    /// bundle.
    ///
    /// Unlike `FlightDeckResetState` this is *not* gated on anything: pointing the app at a
    /// different directory is a legitimate thing to want in a real launch, and unlike the
    /// fixture flags it cannot pose as someone else's data — it only decides where this
    /// instance's own state lives.
    ///
    /// Internal rather than private so `StateDirectoryOverrideTests` can exercise the parsing
    /// without launching an app; the `defaults` parameter is what lets those tests use a suite
    /// of their own instead of the real domain.
    static func stateDirectory(_ defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: "FlightDeckStateDir"), !path.isEmpty else {
            return nil
        }
        return URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The session store for this launch, honouring `-FlightDeckStateDir`.
    ///
    /// `legacyDefaults: nil` under an override is load-bearing, not tidiness.
    /// `FileSessionPersistence.migrateFromDefaults` *removes* the legacy key once it has
    /// written the file, so an overridden store allowed to migrate would consume the real
    /// user's `sessions.snapshot.v1` blob as a side effect of running a debug instance —
    /// isolation that mutates the very thing it is isolating from.
    private static func fileSessionPersistence() -> FileSessionPersistence {
        guard let directory = stateDirectory() else { return FileSessionPersistence() }
        return FileSessionPersistence(directory: directory, legacyDefaults: nil)
    }

    /// `-FlightDeckFixture <dir>`. Used by exactly one UI test, the one that produces the
    /// README screenshot: it needs several projects and a session in every status at once, and
    /// statuses come from live `claude` processes, so there is no production route to it.
    ///
    /// Read only when `isResettingState` is also set — see `makeStore`, which is the only
    /// caller — so a stray default cannot pose a real user's deck. `SessionFixture` writes
    /// nothing; the flag's whole safety story is in that type's doc comment.
    private static var fixture: SessionFixture? {
        guard let path = UserDefaults.standard.string(forKey: "FlightDeckFixture"),
              !path.isEmpty else { return nil }
        return SessionFixture(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    init() {
        // Constructed eagerly, unlike the store: this only reads `UserDefaults`, and both
        // the Settings scene and the store below need the *same* instance.
        //
        // A nil persistence is what makes a reset run hermetic: `PreferencesStore` then
        // starts from `Preferences()` and never writes back, so the test neither reads nor
        // clobbers the real `preferences.v1`.
        let preferences = PreferencesStore(
            persistence: Self.isResettingState ? nil : UserDefaultsPreferencesPersistence()
        )
        // Point fixture sessions at the fixture's own executable instead of the login shell.
        //
        // This is the difference between a screenshot run and a screenshot run that trashes
        // the machine's state. A session launches `resolvedShell()`, and the login shell's
        // profile is what starts `claude` — so without this override every seeded session
        // spawns a real agent, each writing a status file into `~/.claude/sessions` and
        // colliding in the pid-keyed name registry. Safe to assign: under reset the store
        // has a nil persistence, so this never reaches `preferences.v1`.
        if Self.isResettingState, let fixture = Self.fixture {
            preferences.preferences.shell.shellOverride = fixture.shellURL.path
        }
        _preferences = StateObject(wrappedValue: preferences)

        // `wrappedValue` is an @autoclosure: this call is NOT evaluated here. That is
        // load-bearing for two unrelated reasons:
        //
        // 1. Constructing the store touches `GhosttyApp.shared`, which reads `NSApp.isActive`,
        //    and `NSApp` does not exist yet during `App.init`. SwiftUI evaluates the thunk
        //    later, once the app is up.
        // 2. `SessionStore.init` posts `.flightDeckStoreReady`, which is how `AppDelegate`
        //    finds the store it reaps every session through at quit. The delegate registers
        //    its observer in `applicationWillFinishLaunching` — *after* `App.init` — so an
        //    eagerly constructed store would post to nobody. `AppDelegate` now also falls back
        //    to `SessionStore.current` so that quit reaping does not silently become a no-op
        //    if this ever changes, but the ordering is still the primary path.
        //
        // Anyone tempted to construct the store here eagerly has to satisfy both.
        //
        // `fleet` needs that exact same instance — `FleetService` wires itself to a store's
        // events on construction — but its own `@StateObject` autoclosure is a second,
        // independent thunk with no way to read `_store`'s result back out (reading a
        // `@StateObject`'s `wrappedValue` before the view is installed forces early
        // evaluation, which is the very hazard `_store` is deferred to avoid). `deferredStore`
        // is the shared, call-once seam both thunks resolve through instead, so whichever of
        // the two SwiftUI happens to evaluate first builds the store and the other reuses it.
        let deferredStore = DeferredOnce { Self.makeStore(preferences: preferences) }
        _store = StateObject(wrappedValue: deferredStore())
        _fleet = StateObject(wrappedValue: Self.makeFleetService(
            store: deferredStore(), preferences: preferences
        ))
    }

    /// Builds the fleet service and starts its listener, unless the launch is a UITest
    /// reset — see the guard below. `@MainActor` because both `FleetService` and the
    /// `Task` it starts are.
    @MainActor
    private static func makeFleetService(store: SessionStore, preferences: PreferencesStore) -> FleetService {
        let service = FleetService(store: store, preferences: preferences, armer: PairingArmer())
        // The UITest gate is hermetic: a listener advertising this Mac on the real LAN
        // during a GUI test would be a live service, not a test fixture.
        guard !isResettingState else { return service }
        Task {
            do {
                try await service.start()
            } catch {
                // A listener that will not bind is a mobile companion that does not work,
                // which is very different from an app that does not work. Log and carry on.
                logger.error("fleet listener failed to bind: \(String(describing: error), privacy: .public)")
            }
        }
        return service
    }

    @MainActor
    private static func makeStore(preferences: PreferencesStore) -> SessionStore {
        let resetState = Self.isResettingState
        // Built here rather than inside the store: `UNUserNotificationCenter` traps
        // outside a signed bundle, and `SessionStore`'s convenience init is reachable
        // from tests (SessionPersistenceTests). This factory is not.
        //
        // Constructed and authorized BEFORE the store, then passed in, so `notifier` is
        // set before the convenience init's `startStatusWatching()` runs — see the
        // comment on that initializer.
        let notifier = SessionNotifier()
        notifier.requestAuthorization()

        // `preferences` is passed in rather than built here because the convenience init
        // restores sessions inline and resolves each one's flags as it goes, so it needs a
        // live store — and the Settings scene must observe that same instance.
        // A nil persistence under reset, for the same reason as `PreferencesStore` above and
        // one more: `resetState` suppresses *restore*, not *save*. The store seeds a session
        // and immediately persists it, so a reset run backed by the real
        // `FileSessionPersistence` overwrites the developer's own `sessions.json` with the
        // test's seed — which is precisely the data loss this whole change set is about.
        // Nil makes a reset run read nothing and write nothing.
        // A posed deck for the screenshot run. Gated on `resetState` like the seed flag below,
        // so it cannot fire in a real launch even if the default were somehow set.
        //
        // It deliberately passes `resetState: false` to the store while the *app* is still in
        // reset: `resetState` suppresses `restore()`, and restoring is the entire point here.
        // Safety does not come from that flag in this path, it comes from the persistence —
        // `FixtureSessionPersistence` reads the fixture and discards every write, so the
        // developer's `sessions.json` is neither read nor written. Preferences are still
        // hermetic, because `isResettingState` gave that store a nil persistence above.
        let fixture = resetState ? Self.fixture : nil

        let store = SessionStore(
            ghostty: GhosttyApp.shared,
            resetState: resetState && fixture == nil,
            preferences: preferences,
            notifier: notifier,
            // Passed in rather than assigned after construction for the same two reasons as
            // `notifier` above: `UNUserNotificationCenter` traps here too, and the
            // convenience init's launch-time orphan sweep reports through `reapReporter`
            // before this factory could ever assign it afterwards.
            reapReporter: UserNotificationReapReporter(),
            persistence: fixture?.persistence() ?? (resetState ? nil : Self.fileSessionPersistence()),
            // Point the watcher at the fixture's status files instead of `~/.claude/sessions`,
            // and believe them: they name pids that were never spawned, so the real liveness
            // check would drop every row.
            statusRoot: fixture?.statusRoot,
            transcriptsRoot: fixture?.projectsRoot,
            statusIsAlive: fixture == nil ? nil : { _ in true }
        )

        // Test-only second project, so the sidebar has something to reorder. Guarded by
        // `resetState` as well as its own flag: a reset run reads and writes no persistence,
        // so this can never reach the developer's real `sessions.json`.
        if resetState, Self.isSeedingSecondProject {
            store.newSession(in: FileManager.default.temporaryDirectory)
        }
        return store
    }

    var body: some Scene {
        RootWindow(store: store, preferences: preferences)
            .commands {
                SessionCommands(store: store, preferences: preferences)
                EditCommands()
                TabNavigationCommands(store: store)
            }

        // A `Settings` scene gives ⌘, and the standard Preferences window for free.
        Settings {
            PreferencesView(preferences: preferences, sessions: store, fleet: fleet)
        }
    }
}

/// Lets `_store` and `_fleet`'s independent `@StateObject` autoclosures share exactly one
/// `SessionStore` no matter which of the two SwiftUI happens to evaluate first — see the
/// comment on `_store`'s assignment in `init()`. `make` must run at most once: calling
/// `Self.makeStore` twice would build two stores, each posting `.flightDeckStoreReady` and
/// spawning its own `claude --resume` per restored session.
private final class DeferredOnce<Value> {
    private let make: () -> Value
    private var resolved: Value?

    init(_ make: @escaping () -> Value) { self.make = make }

    func callAsFunction() -> Value {
        if let resolved { return resolved }
        let value = make()
        resolved = value
        return value
    }
}
