import Combine
import HostKit
import XCTest
@testable import FlightDeck

/// The app wiring around delegation that lives outside `DelegationService`: route shims in a
/// tab's launch environment, the tab-close notice, resuming watched runs at launch and on
/// reconnect, and `/reload-plugins` for adopted claude tabs.
@MainActor
final class DelegationBootstrapTests: XCTestCase {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/RouteShim/flightdeck-route-shim.sh")

    private final class MemoryPreferences: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    private final class LiveDaemons: DaemonControlling {
        let live: Set<UUID>
        init(_ live: Set<UUID>) { self.live = live }
        func isLive(_ id: UUID) -> Bool { live.contains(id) }
        func isLive(socketPath: String) -> Bool { true }
        func daemonPID(_ id: UUID) -> pid_t? { nil }
        func daemonPID(socketPath: String) -> pid_t? { nil }
        func terminate(_ id: UUID) {}
        func terminate(socketPath: String) {}
        func peerPID(socketPath: String) -> pid_t? { nil }
        func terminate(pid: pid_t, socketPath: String) {}
        func stop(_ id: UUID) {}
        func cont(_ id: UUID) {}
    }

    private final class RecordingHooks: DelegationSessionHooks {
        var launched: [UUID] = []
        var closed: [UUID] = []
        func launchEnvironment(_ environment: [String: String], session: UUID, projectRoot: URL) -> [String: String] {
            launched.append(session)
            return environment
        }
        func sessionClosed(_ session: UUID) { closed.append(session) }
    }

    private final class CountingLifecycle: DelegationLifecycle {
        var resumes = 0
        func resumeWatching() { resumes += 1 }
    }

    private var temp: URL!

    override func setUpWithError() throws {
        // A space on purpose, as in the real "Application Support/Flight Deck".
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("delegation bootstrap \(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func project(routing command: String) throws -> URL {
        let root = temp.appendingPathComponent("project", isDirectory: true)
        let file = DelegateConfigParser.fileURL(projectRoot: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [recipe.ui]
        run = "\(command) test"
        [[route]]
        match = "\(command) test*"
        recipe = "ui"
        """.write(to: file, atomically: true, encoding: .utf8)
        return root
    }

    private func bootstrap() -> DelegationBootstrap {
        DelegationBootstrap(
            shims: RouteShims(root: temp.appendingPathComponent("route-shims"), script: Self.script),
            cli: URL(fileURLWithPath: "/Applications/Flight Deck.app/Contents/MacOS/flightdeck"))
    }

    private func store(hooks: DelegationSessionHooks?) -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil,
                                 preferences: PreferencesStore(persistence: MemoryPreferences()))
        store.delegationHooks = hooks
        return store
    }

    // MARK: Route shims

    func testALaunchedTabHasItsShimDirectoryFirstOnPathAndTheRoutedCommandLinked() throws {
        let root = try project(routing: "xcodebuild")
        let hooks = bootstrap()
        let store = store(hooks: hooks)
        store.preferences?.preferences.shell.environment["PATH"] = "/custom/bin:/usr/bin"
        let session = store.newSession(in: root)

        let env = store.launchEnvironment(for: session, adapter: ClaudeAdapter(), orphaned: false)

        let dir = temp.appendingPathComponent("route-shims/\(session.id.uuidString)")
        XCTAssertEqual(env["PATH"], "\(dir.path):/custom/bin:/usr/bin",
                       "the shim directory goes in front of the Shell pane's PATH, which is kept")
        XCTAssertEqual(env["FLIGHTDECK_SHIM_DIR"], dir.path)
        XCTAssertEqual(env["FLIGHTDECK_CLI"], "/Applications/Flight Deck.app/Contents/MacOS/flightdeck")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("xcodebuild").path), Self.script.path)
        XCTAssertEqual(hooks.trackedSessions(in: root), [session.id])
    }

    func testWithoutHooksATabLaunchesExactlyAsBefore() {
        let store = store(hooks: nil)
        let session = store.newSession(in: temp)
        let env = store.launchEnvironment(for: session, adapter: ClaudeAdapter(), orphaned: false)
        XCTAssertNil(env["FLIGHTDECK_SHIM_DIR"])
        XCTAssertNil(env["FLIGHTDECK_CLI"])
    }

    func testClosingATabNotifiesTheHooks() {
        let hooks = RecordingHooks()
        let store = store(hooks: hooks)
        let session = store.newSession(in: temp)
        XCTAssertEqual(hooks.launched, [session.id], "a new tab's launch goes through the hooks")
        store.closeSession(session.id)
        XCTAssertEqual(hooks.closed, [session.id])
    }

    func testClosingATabRemovesItsShimDirectoryAndStopsTrackingIt() throws {
        let root = try project(routing: "make")
        let hooks = bootstrap()
        let store = store(hooks: hooks)
        let kept = store.newSession(in: root)
        let closed = store.newSession(in: root)
        let dir = temp.appendingPathComponent("route-shims/\(closed.id.uuidString)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        store.closeSession(closed.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(hooks.trackedSessions(in: root), [kept.id])
    }

    func testEditingDelegateTomlRebuildsTheProjectsShims() throws {
        let root = try project(routing: "make")
        let hooks = bootstrap()
        let store = store(hooks: hooks)
        let session = store.newSession(in: root)
        let link = temp.appendingPathComponent("route-shims/\(session.id.uuidString)/cargo").path

        try """
        [recipe.ui]
        run = "cargo test"
        [[route]]
        match = "cargo test*"
        recipe = "ui"
        """.write(to: DelegateConfigParser.fileURL(projectRoot: root), atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: link), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: link), "the watcher rebuilt the tab's shims")
    }

    // MARK: Launch and reconnect

    func testRunsAreWatchedAgainAtLaunchAndWhenAHostComesOnline() {
        let hooks = bootstrap()
        let lifecycle = CountingLifecycle()
        let states = PassthroughSubject<[UUID: HostLinkState], Never>()
        let mini = UUID(), box = UUID()

        hooks.attach(lifecycle, hostStates: states.eraseToAnyPublisher())
        XCTAssertEqual(lifecycle.resumes, 1, "at launch")

        states.send([mini: .connecting, box: .offline(lastSeen: nil)])
        XCTAssertEqual(lifecycle.resumes, 1, "nothing came online")
        states.send([mini: .online(hostName: "mini"), box: .offline(lastSeen: nil)])
        XCTAssertEqual(lifecycle.resumes, 2, "mini came online")
        states.send([mini: .online(hostName: "mini"), box: .offline(lastSeen: nil)])
        XCTAssertEqual(lifecycle.resumes, 2, "still online is not news")
        states.send([mini: .offline(lastSeen: nil), box: .offline(lastSeen: nil)])
        states.send([mini: .online(hostName: "mini"), box: .offline(lastSeen: nil)])
        XCTAssertEqual(lifecycle.resumes, 3, "a reconnect is")
    }

    // MARK: Plugin reload

    func testPluginReloadIsDueOnlyForIdleAdoptedTabs() {
        let store = store(hooks: nil)
        let idle = store.newSession(in: temp).id
        let busy = store.newSession(in: temp).id
        let waiting = store.newSession(in: temp).id
        let fresh = store.newSession(in: temp).id
        store.armPluginReload(pluginChanged: true, adopted: [idle, busy, waiting])

        store.applyRegistryForTesting([
            idle: SessionStatus(activity: .idle), busy: SessionStatus(activity: .busy),
            waiting: SessionStatus(activity: .waiting), fresh: SessionStatus(activity: .idle),
        ])

        XCTAssertEqual(store.pluginReloadsDue(), [idle])
    }

    func testNoPluginReloadWhenThePluginDidNotChange() {
        let store = store(hooks: nil)
        let id = store.newSession(in: temp).id
        store.armPluginReload(pluginChanged: false, adopted: [id])
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        XCTAssertEqual(store.pluginReloadsDue(), [])
    }

    func testAClosedTabIsNoLongerDueAReload() {
        let store = store(hooks: nil)
        let id = store.newSession(in: temp).id
        store.armPluginReload(pluginChanged: true, adopted: [id])
        store.closeSession(id)
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        XCTAssertEqual(store.pluginReloadsDue(), [])
    }

    func testRestoreAdoptsOnlyTabsWhoseAgentWasStillRunning() {
        let adopted = UUID(), relaunched = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                SessionSnapshot.Entry(id: adopted, title: "a", workingDirectory: "/w", activity: "idle", agent: .claude),
                SessionSnapshot.Entry(id: relaunched, title: "r", workingDirectory: "/w", activity: "idle", agent: .claude),
            ],
            selectedSessionID: nil, sessionCounter: 2)
        let store = SessionStore(provider: nil, persistence: persistence,
                                 preferences: PreferencesStore(persistence: MemoryPreferences()),
                                 daemonControl: LiveDaemons([adopted]))
        XCTAssertTrue(store.restore(directoryExists: { _ in true }))

        store.armPluginReload(pluginChanged: true)
        store.applyRegistryForTesting([adopted: SessionStatus(activity: .idle),
                                       relaunched: SessionStatus(activity: .idle)])

        XCTAssertEqual(store.pluginReloadsDue(), [adopted],
                       "a tab this run relaunched loads the current plugin itself")
    }
}
