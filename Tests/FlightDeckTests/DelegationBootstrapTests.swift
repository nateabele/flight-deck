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
        // And each shell is pointed at the snippet that keeps it first after its startup files.
        let integration = Self.script.deletingLastPathComponent()
        XCTAssertEqual(env["ZDOTDIR"], integration.appendingPathComponent("zsh").path)
        XCTAssertEqual(env["XDG_DATA_DIRS"]?.hasPrefix(integration.path + ":"), true)
        XCTAssertEqual(env["PROMPT_COMMAND"]?.contains("bash/flightdeck-route-shim.bash"), true)
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

    // MARK: Plugin reload

    /// A claude composer whose Return can be made to go missing, which is what left
    /// `/reload-plugins` sitting in users' boxes. Kill, yank and paste act on `box` the way
    /// claude's line editor does, so `submit`'s kill-and-yank round trip is exercised for real.
    private final class Composer: TextInjecting {
        var box = ""
        var returnSubmits = true
        private var ring = ""
        private(set) var submitted: [String] = []
        func sendText(_ text: String) { box += text }
        func sendReturn() {
            guard returnSubmits else { return }
            submitted.append(box)
            box = ""
        }
        func sendKillLine() {
            guard !box.isEmpty else { return }
            ring = box
            box = ""
        }
        func sendYank() { box += ring }
        func sendArrowDown() {}
        func sendArrowUp() {}
        func sendTab() {}
        func sendEscape() {}
        func sendCharacterKey(_ character: Character) {}
        func sendControlKey(_ letter: Character) {}
        func readViewport() -> String? {
            let rule = String(repeating: "─", count: 92)
            return [rule, box.isEmpty ? "❯" : "❯\u{a0}" + box, rule, "  Opus 5 (1M context)  ⎇ master"]
                .joined(separator: "\n")
        }
    }

    /// A store whose app is frontmost and whose injection settles synchronously.
    private func reloadStore() -> SessionStore {
        let store = store(hooks: nil)
        store.appIsActive = { true }
        store.injectionSettle = { $0() }
        return store
    }

    func testPluginReloadIsDueOnlyForTheSelectedIdleAdoptedTab() {
        let store = reloadStore()
        let idle = store.newSession(in: temp).id
        let other = store.newSession(in: temp).id
        let busy = store.newSession(in: temp).id
        let fresh = store.newSession(in: temp).id
        store.armPluginReload(pluginChanged: true, adopted: [idle, other, busy])
        store.applyRegistryForTesting([
            idle: SessionStatus(activity: .idle), other: SessionStatus(activity: .idle),
            busy: SessionStatus(activity: .busy), fresh: SessionStatus(activity: .idle),
        ])

        store.selectedSessionID = fresh
        XCTAssertEqual(store.pluginReloadsDue(), [], "a tab this run launched loads the current plugin")
        store.selectedSessionID = busy
        XCTAssertEqual(store.pluginReloadsDue(), [], "claude queues a command typed mid-turn")
        store.selectedSessionID = idle
        XCTAssertEqual(store.pluginReloadsDue(), [idle], "only the tab being looked at, not `other`")
        store.appIsActive = { false }
        XCTAssertEqual(store.pluginReloadsDue(), [], "a selected tab in a background app is not active")
    }

    func testNoPluginReloadWhenThePluginDidNotChange() {
        let store = reloadStore()
        let id = store.newSession(in: temp).id
        store.armPluginReload(pluginChanged: false, adopted: [id])
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        XCTAssertEqual(store.pluginReloadsDue(), [])
    }

    /// A tab not activated in the run that saw the change is still owed its reload in the next.
    func testATabStillStaleFromThePreviousRunIsDueWithoutANewChange() {
        let store = reloadStore()
        let owed = store.newSession(in: temp).id
        let done = store.newSession(in: temp).id
        var saved: Set<UUID>?
        store.armPluginReload(pluginChanged: false, adopted: [owed, done], stillStale: [owed],
                              save: { saved = $0 })
        XCTAssertEqual(saved, [owed], "armed state is saved at once, so a crash keeps it")
        store.applyRegistryForTesting([owed: SessionStatus(activity: .idle), done: SessionStatus(activity: .idle)])
        store.selectedSessionID = done
        XCTAssertEqual(store.pluginReloadsDue(), [])
        store.selectedSessionID = owed
        XCTAssertEqual(store.pluginReloadsDue(), [owed])
    }

    func testAClosedTabIsNoLongerDueAReload() {
        let store = reloadStore()
        let id = store.newSession(in: temp).id
        var saved: Set<UUID>?
        store.armPluginReload(pluginChanged: true, adopted: [id], save: { saved = $0 })
        store.closeSession(id)
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        XCTAssertEqual(store.pluginReloadsDue(), [])
        XCTAssertEqual(saved, [], "the record drops it too")
    }

    func testAReloadThatSubmitsRetiresTheTab() {
        let store = reloadStore()
        let composer = Composer()
        store.injectorOverride = composer
        let id = store.newSession(in: temp).id
        var saved: Set<UUID>?
        store.armPluginReload(pluginChanged: true, adopted: [id], save: { saved = $0 })
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        store.maintenanceTickForTesting()

        XCTAssertEqual(composer.submitted, [PluginReload.command])
        XCTAssertEqual(composer.box, "")
        XCTAssertEqual(saved, [])
        store.selectedSessionID = id
        XCTAssertEqual(store.pluginReloadsDue(), [], "reactivating a reloaded tab types nothing")
    }

    /// The bug this guards: a Return that never landed left the command in the box, and the
    /// next attempt's kill-and-yank put it back behind its own copy. The check clears every
    /// copy, keeps the draft behind them, and waits for the user to come back to the tab.
    func testALostReturnIsClearedKeepsTheDraftAndWaitsForTheNextActivation() {
        let store = reloadStore()
        let composer = Composer()
        composer.box = "/reload-plugins/reload-pluginsfix the parser"
        composer.returnSubmits = false
        store.injectorOverride = composer
        let id = store.newSession(in: temp).id
        var saved: Set<UUID>?
        store.armPluginReload(pluginChanged: true, adopted: [id], save: { saved = $0 })
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        store.maintenanceTickForTesting()
        XCTAssertEqual(composer.box, "fix the parser", "residue cleared, draft kept")
        XCTAssertEqual(saved, [id], "still owed a reload")
        store.maintenanceTickForTesting()
        XCTAssertEqual(composer.box, "fix the parser", "not retried on the next tick")

        composer.returnSubmits = true
        store.selectedSessionID = id
        store.maintenanceTickForTesting()
        XCTAssertEqual(composer.submitted, [PluginReload.command])
        XCTAssertEqual(composer.box, "fix the parser")
        XCTAssertEqual(saved, [])
    }

    /// The command flips the registry idle → busy → idle for about 90 ms. A poll that catches
    /// it must not leave the tab looking like it finished a turn.
    func testTheReloadBlipLeavesUnreadAndLastActiveAlone() {
        let store = store(hooks: nil)
        store.appIsActive = { false }
        var clock = Date(timeIntervalSince1970: 1_000)
        store.now = { clock }
        let id = store.newSession(in: temp).id
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        let stamped = store.lastActiveAt(for: id)

        clock += 60
        store.pluginReloadSentForTesting(id)
        clock += 0.05
        store.applyRegistryForTesting([id: SessionStatus(activity: .busy)])
        clock += 0.5
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        XCTAssertFalse(store.unreadIdle.contains(id))
        XCTAssertEqual(store.lastActiveAt(for: id), stamped)
    }

    func testRealWorkAfterTheReloadStillMarksTheTab() {
        let store = store(hooks: nil)
        store.appIsActive = { false }
        var clock = Date(timeIntervalSince1970: 1_000)
        store.now = { clock }
        let id = store.newSession(in: temp).id
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        store.pluginReloadSentForTesting(id)
        store.applyRegistryForTesting([id: SessionStatus(activity: .busy)])
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])
        // The blip landed and closed the window: the next turn is the session's own.
        clock += 1
        store.applyRegistryForTesting([id: SessionStatus(activity: .busy)])
        clock += 30
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        XCTAssertTrue(store.unreadIdle.contains(id))
        XCTAssertEqual(store.lastActiveAt(for: id), clock)
    }

    func testABusySpellThatOutlivesTheWindowStillMarksTheTab() {
        let store = store(hooks: nil)
        store.appIsActive = { false }
        var clock = Date(timeIntervalSince1970: 1_000)
        store.now = { clock }
        let id = store.newSession(in: temp).id
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        store.pluginReloadSentForTesting(id)
        store.applyRegistryForTesting([id: SessionStatus(activity: .busy)])
        clock += PluginReload.quietWindow + 1
        store.applyRegistryForTesting([id: SessionStatus(activity: .idle)])

        XCTAssertTrue(store.unreadIdle.contains(id))
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

        store.appIsActive = { true }
        store.armPluginReload(pluginChanged: true)
        store.applyRegistryForTesting([adopted: SessionStatus(activity: .idle),
                                       relaunched: SessionStatus(activity: .idle)])

        store.selectedSessionID = adopted
        XCTAssertEqual(store.pluginReloadsDue(), [adopted])
        store.selectedSessionID = relaunched
        XCTAssertEqual(store.pluginReloadsDue(), [],
                       "a tab this run relaunched loads the current plugin itself")
    }
}
