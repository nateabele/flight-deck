import OSLog
import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences: PreferencesStore
    @StateObject private var store: SessionStore
    @StateObject private var fleet: FleetService
    @StateObject private var hosts: HostService
    @StateObject private var hosting: HostingController
    @StateObject private var routing: RoutingService

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
    ///
    /// **A Debug build refuses an override naming the live directory** — by any spelling,
    /// symlinks included — and gets its own `Flight Deck (Debug)` directory instead. That is
    /// the only route left by which a Debug build could restore the live deck and resume a
    /// duplicate agent per session (see `FileSessionPersistence.defaultDirectory(debug:)`).
    @MainActor
    static func stateDirectory(
        _ defaults: UserDefaults = .standard,
        debug: Bool = SessionDaemon.isDebugBuild
    ) -> URL? {
        guard let path = defaults.string(forKey: "FlightDeckStateDir"), !path.isEmpty else {
            return nil
        }
        let url = URL(
            fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        guard debug else { return url }
        let live = FileSessionPersistence.defaultDirectory(debug: false)
        guard url.resolvingSymlinksInPath().standardizedFileURL.path
                == live.resolvingSymlinksInPath().standardizedFileURL.path
        else { return url }
        logger.error("refusing -FlightDeckStateDir \(path, privacy: .public): a Debug build never opens the live deck")
        return FileSessionPersistence.defaultDirectory(debug: true)
    }

    /// The defaults domain `FileSessionPersistence` may migrate the legacy
    /// `sessions.snapshot.v1` blob out of, or nil for none. Debug and Release share one bundle
    /// id and so one domain, and migration *removes* the key: a Debug store allowed to migrate
    /// would move the live user's blob into the debug directory. An overridden store never
    /// migrates for the same reason (see `fileSessionPersistence()`).
    static func legacyMigrationDefaults(overridden: Bool, debug: Bool) -> UserDefaults? {
        overridden || debug ? nil : .standard
    }

    /// `-FlightDeckDaemonDir <path>`. Overrides the fd-abduco socket/pidfile root
    /// (`SessionDaemon`'s build-specific default). Debug and release builds already default to
    /// *different* roots so they never share one; this is the explicit override for finer
    /// isolation — e.g. running two debug instances at once, or pinning a test's daemons to a
    /// scratch directory. `nil` when unset, so `SessionDaemon(directory:)` falls back to its
    /// default. Like `-FlightDeckStateDir`, not gated on anything: a real launch simply never
    /// passes it.
    static func daemonDirectory(_ defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: "FlightDeckDaemonDir"), !path.isEmpty else {
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
        let directory = stateDirectory()
        return FileSessionPersistence(
            directory: directory,
            legacyDefaults: legacyMigrationDefaults(
                overridden: directory != nil, debug: SessionDaemon.isDebugBuild))
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
        #if DEBUG
        // L3-S UI tests: Flight Control on for the fixture project, in the hermetic (nil
        // persistence) preferences a reset run uses — so nothing reaches `preferences.v1`.
        if Self.isResettingState, let backend = FlightControlFixtureBackend.fromDefaults() {
            var settings = preferences.projectSettings(backend.projectPath)
            settings.flywheelEnabled = true
            preferences.setProjectSettings(backend.projectPath, settings)
        }
        #endif
        _preferences = StateObject(wrappedValue: preferences)
        // Eager like `preferences`, for the same reason: the Settings scene and the store need
        // the same instance. Building it spawns nothing.
        let routing = RoutingService.make(preferences: preferences)
        _routing = StateObject(wrappedValue: routing)

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
        // Eager like `hosts` below, and before the store, which launches its restored tabs
        // inside its own initializer and needs the route shims by then. Nil under a reset.
        let delegation = Self.makeDelegationBootstrap()
        let deferredStore = DeferredOnce {
            Self.makeStore(preferences: preferences, routing: routing, delegation: delegation)
        }
        _store = StateObject(wrappedValue: deferredStore())
        // Eager, unlike the store: it touches neither `NSApp` nor the session store, and
        // being built here — not in a `@StateObject` thunk SwiftUI may evaluate whenever —
        // is what guarantees the links open at launch. Built before `fleet` so the fleet's
        // thunk can capture this same instance: a second one would hold its own links, and
        // `flightdeck host ls` would report a registry Settings never sees.
        let hosts = Self.makeHostService()
        _hosts = StateObject(wrappedValue: hosts)
        _hosting = StateObject(wrappedValue: Self.makeHostingController())
        _fleet = StateObject(wrappedValue: Self.makeFleetService(
            store: deferredStore(), preferences: preferences, hosts: hosts, delegation: delegation
        ))
    }

    /// Route shims and delegated execution (`DelegationBootstrap`). Nil under a UITest reset,
    /// for the reason `makeHostService` gives its reset run nothing real: a GUI test must not
    /// write shims into the state directory or reach a paired host.
    @MainActor
    private static func makeDelegationBootstrap() -> DelegationBootstrap? {
        guard !isResettingState else { return nil }
        return DelegationBootstrap(stateDirectory: stateDirectory() ?? FileSessionPersistence.defaultDirectory())
    }

    /// Builds the host service beside `FleetService` and starts its links. Cannot hold up
    /// launch: `hosts.json` is a few hundred bytes, `start()` returns at once and reads the
    /// Keychain off the main thread, and with no paired hosts it does nothing.
    ///
    /// Under a UITest reset it gets a throwaway file and an in-memory secret store and is
    /// never started, for the reason the fleet listener is not: a reset run must neither read
    /// the developer's paired hosts nor dial them.
    @MainActor
    private static func makeHostService() -> HostService {
        let controllerName = Host.current().localizedName ?? "Mac"
        guard !isResettingState else {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("flightdeck-hosts-\(UUID().uuidString).json")
            return HostService(
                registry: HostRegistry(fileURL: scratch, secrets: InMemoryHostSecretStore()),
                controllerName: controllerName)
        }
        // Beside `sessions.json`, through the same resolution, so a Debug build reads
        // "Flight Deck (Debug)" and `-FlightDeckStateDir` moves it too.
        let directory = stateDirectory() ?? FileSessionPersistence.defaultDirectory()
        let service = HostService(
            registry: HostRegistry(fileURL: directory.appendingPathComponent("hosts.json"),
                                   secrets: KeychainHostSecretStore()),
            controllerName: controllerName)
        service.start()
        return service
    }

    /// The Hosting tab's model. Inert until that tab is shown: it reads nothing at
    /// construction, and its admin poll runs only while the tab is visible.
    ///
    /// Under a UITest reset its admin socket is a path nothing listens on and its LaunchAgent is
    /// `InertAgentService`, so a reset run never reads, arms or revokes the developer's real
    /// hostd, and never registers (or unregisters) the real `dev.flightdeck.hostd` agent.
    @MainActor
    private static func makeHostingController() -> HostingController {
        guard !isResettingState else {
            return HostingController(service: InertAgentService(),
                                     adminPath: "/tmp/fd-uitest-\(UUID().uuidString.prefix(8)).sock")
        }
        return HostingController(adminPath: HostingController.defaultAdminPath)
    }

    /// Builds the fleet service and starts its listener, unless the launch is a UITest
    /// reset — see the guard below. `@MainActor` because both `FleetService` and the
    /// `Task` it starts are.
    @MainActor
    private static func makeFleetService(store: SessionStore, preferences: PreferencesStore,
                                         hosts: HostService, delegation: DelegationBootstrap?) -> FleetService {
        let service = FleetService(store: store, preferences: preferences, armer: PairingArmer(),
                                   hosts: hosts)
        // The UITest gate is hermetic: a listener advertising this Mac on the real LAN
        // during a GUI test would be a live service, not a test fixture.
        guard !isResettingState else { return service }
        // Before either socket starts, so no `delegate.*` request is ever answered
        // `not_implemented` by a fleet that simply had not been handed its service yet.
        delegation?.connect(fleet: service, hosts: hosts) { [weak store] in store?.title(of: $0) }
        Task {
            do {
                try await service.start()
            } catch {
                // A listener that will not bind is a mobile companion that does not work,
                // which is very different from an app that does not work. Log and carry on.
                logger.error("fleet listener failed to bind: \(String(describing: error), privacy: .public)")
            }
        }
        // Its own start, never inside the `do` above: a phone listener that will not bind must
        // not take the CLI down with it, and the reverse. After the reset guard on purpose, so a
        // UITest run neither binds a live socket nor hands its tabs a path to one.
        if ControlEnvironment.isEnabled() {
            let url = ControlEnvironment.socketURL()
            store.controlSocket = url
            store.controlSecret = service.controlSecret
            Task {
                do { try await service.startLocal(at: url) }
                catch { logger.error("control socket failed to bind: \(String(describing: error), privacy: .public)") }
            }
        }
        return service
    }

    @MainActor
    private static func makeStore(
        preferences: PreferencesStore, routing: RoutingService, delegation: DelegationBootstrap?
    ) -> SessionStore {
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

        // Beside `intakes/`, honouring `-FlightDeckStateDir`; a reset run gets a scratch root.
        let defaultSwarmsRoot: URL? = resetState ? nil : (Self.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
        #if DEBUG
        let flightControlFixture = resetState ? FlightControlFixtureBackend.fromDefaults() : nil
        let flywheelTools = flightControlFixture?.tools ?? .system
        let swarmsRoot = flightControlFixture?.swarmsRoot ?? defaultSwarmsRoot
        #else
        let flywheelTools = FlywheelToolPaths.system
        let swarmsRoot = defaultSwarmsRoot
        #endif

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
            statusIsAlive: fixture == nil ? nil : { _ in true },
            // Honour `-FlightDeckDaemonDir`; `nil` falls back to `SessionDaemon`'s build-specific
            // default (debug and release already differ, so they never share a socket dir).
            // The store forwards this same daemon to its `PosixDaemonControl`, so `liveSessionIDs`
            // and `terminate` operate on one consistent directory.
            daemon: SessionDaemon(directory: Self.daemonDirectory()),
            // The only store that names the real intakes directory — every other gets a scratch
            // one (`SessionStore.resolvedIntakesRoot`). Honours `-FlightDeckStateDir` like the
            // search index does, so a debug instance pointed at a copy of a real deck never
            // triages into the real one's intakes.
            intakesRoot: (Self.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
                .appendingPathComponent("intakes", isDirectory: true),
            delegationHooks: delegation,
            flywheelTools: flywheelTools,
            swarmsRoot: swarmsRoot
        )

        // After `restore()` (inside the initializer above), which is what records the claude
        // tabs adopted from the previous run. Not under a reset: the fingerprint record lives
        // in the real defaults domain, and a reset run has no adopted tabs anyway.
        if !resetState, let plugin = ClaudePluginLocation.directory(bundle: .main) {
            store.armPluginReload(pluginChanged: PluginReload.pluginChanged(
                current: PluginReload.fingerprint(of: plugin), defaults: .standard))
        }
        // Set after the store exists: the service schedules itself on the store's `WatchClock`.
        store.capabilityIndexService = Self.makeCapabilityIndexService(store: store, resetState: resetState)

        // Test-only second project, so the sidebar has something to reorder. Guarded by
        // `resetState` as well as its own flag: a reset run reads and writes no persistence,
        // so this can never reach the developer's real `sessions.json`.
        if resetState, Self.isSeedingSecondProject {
            store.newSession(in: FileManager.default.temporaryDirectory)
        }

        // Wraps the SAME `Notifying` instance `notifier` above wraps for ordinary session
        // notifications — no second `Notifying` is constructed, and no extra launch-time
        // `requestAuthorization()` call is added here: `SessionStore.startObserving(project:)`
        // requests it lazily, the first time any project actually turns Observe on.
        let flywheelNotifier = FlywheelNotifier(notifier: notifier)
        flywheelNotifier.route = { [weak store] project, agentName in
            store?.session(project: project, agentName: agentName)?.id
        }
        store.flywheelNotifier = flywheelNotifier
        // Intake release asks the store's routing for each created task's block (L3-R §4).
        store.flightControlRouting = routing

        #if DEBUG
        if let flightControlFixture { store.swarmDependencies = flightControlFixture.dependencies() }
        #endif

        return store
    }

    /// The capability index. A UITest reset run gets a scratch directory — seeded from
    /// `-FlightDeckCapabilityIndexFixture <dir>` when given, copied so a rollback in the test
    /// never edits the fixture in the repo — and is NEVER scheduled. Its runner always throws, so
    /// even a click on "Refresh now" in a reset or UI-test launch fails fast and spends no tokens. A real launch uses `<state dir>/capability-index`, which
    /// already differs between Debug and Release builds.
    @MainActor
    private static func makeCapabilityIndexService(store: SessionStore, resetState: Bool) -> CapabilityIndexService {
        if resetState {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("FlightDeck-capability-index-\(UUID().uuidString)", isDirectory: true)
            if let path = UserDefaults.standard.string(forKey: "FlightDeckCapabilityIndexFixture"), !path.isEmpty {
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: path, isDirectory: true), to: scratch)
            }
            return CapabilityIndexService(directory: scratch, runner: IndexRefreshRunner(headless: RefreshDisabledHeadlessRunner()))
        }
        let root = Self.stateDirectory() ?? FileSessionPersistence.defaultDirectory()
        let service = CapabilityIndexService(
            directory: CapabilityIndexService.directory(stateRoot: root),
            // Every registered harness. Until L3-R fills `modelCatalog()` these are the L3-0
            // stubs' empty catalogs, so a refresh proposes no aliases before integration.
            catalogs: { await RoutingCapabilityRegistry.standard().catalogs(enabled: Set(AgentID.allCases.map(\.harnessID))) })
        service.startScheduling(clock: store.watchClock)
        return service
    }

    /// The capability index's runner in reset and UI-test launches. A real `claude -p` there would
    /// spend tokens from a test, so every run throws and is recorded as a failed refresh.
    private struct RefreshDisabledHeadlessRunner: HeadlessRunner {
        struct Disabled: LocalizedError { var errorDescription: String? { "refresh is disabled in reset/test launches" } }
        func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]), cwd: URL)
            async throws -> (stdout: Data, stderr: String, exitCode: Int32) { throw Disabled() }
        func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]), cwd: URL,
                 onStdout: (@Sendable (Data) -> Void)?) async throws -> (stdout: Data, stderr: String, exitCode: Int32) { throw Disabled() }
    }

    var body: some Scene {
        RootWindow(store: store, preferences: preferences,
                   phoneActiveSessions: fleet.phoneActiveSessions)
            .commands {
                SessionCommands(store: store, preferences: preferences)
                EditCommands()
                FontSizeCommands(store: store, preferences: preferences)
                TabNavigationCommands(store: store)
                SearchCommands()
                PlanningCommands()
                ShortcutOverlayCommands()
            }

        // A `Settings` scene gives ⌘, and the standard Preferences window for free.
        Settings {
            PreferencesView(preferences: preferences, sessions: store, fleet: fleet,
                            hosts: hosts, hosting: hosting, routing: routing)
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
        // Not actor-isolated — `_store` and `_fleet`'s `@StateObject` autoclosures are
        // evaluated by SwiftUI on the main thread, and `resolved` is read-then-written here
        // with no lock. `FleetService`'s `onAttachedSlotsChanged` handler guards the identical
        // main-thread-only hazard explicitly (see its comment); this does the same rather
        // than leaving the assumption to be rediscovered by whoever calls this from
        // somewhere else and gets two stores instead of one.
        dispatchPrecondition(condition: .onQueue(.main))
        if let resolved { return resolved }
        let value = make()
        resolved = value
        return value
    }
}
