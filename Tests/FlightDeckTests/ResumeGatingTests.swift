import XCTest
@testable import FlightDeck

/// Task 6: when a session's daemon is already live at restore, the agent never stopped — so
/// `restore()` must neither type a resume command at it nor queue the "Keep going" nudge, for
/// either adapter. Dead daemon (including the production default, which is what every restore
/// test outside this file exercises) must behave exactly as before.
///
/// Keyed on `DaemonControlling.isLive`, the same probe `insertSession`/`LaunchPlan.decide`
/// already query — never on `AgentID`, which is the whole point: this is not a Claude-only fix.
@MainActor
final class ResumeGatingTests: XCTestCase {
    /// Same idiom as `SessionDaemonWiringTests.FakeDaemonControl`: a forced answer rather than
    /// one derived from a real socket, so a test can drive both branches on demand.
    private final class FakeDaemonControl: DaemonControlling {
        var forcedIsLive = false
        private(set) var queriedIDs: [UUID] = []

        func isLive(_ id: UUID) -> Bool {
            queriedIDs.append(id)
            return forcedIsLive
        }
        func daemonPID(_ id: UUID) -> pid_t? { nil }
        func terminate(_ id: UUID) {}
    }

    // MARK: - Claude

    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    private final class MemoryPreferences: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private let allDirsExist: (String) -> Bool = { _ in true }

    private func preferences(autoResume: Bool) -> PreferencesStore {
        let store = PreferencesStore(persistence: MemoryPreferences())
        store.autoResumesRunningSessions = autoResume
        return store
    }

    /// A restorable Claude session, busy — the exact shape `SessionAutoResumeTests` uses to
    /// prove the "Keep going" gate fires when the daemon is dead. `autoResume` is forced on:
    /// the point of these tests is that liveness gates it even when every other condition
    /// the queue checks is satisfied.
    private func makeClaudeStore(
        daemonControl: DaemonControlling
    ) -> (store: SessionStore, provider: RecordingProvider, id: UUID) {
        let id = UUID()
        let entry = SessionSnapshot.Entry(
            id: id, title: "s", workingDirectory: "/w", activity: "busy", agent: .claude
        )
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [entry], selectedSessionID: nil, sessionCounter: 1
        )
        let provider = RecordingProvider()
        retained.append(provider)
        let store = SessionStore(
            provider: provider,
            persistence: persistence,
            preferences: preferences(autoResume: true),
            daemonControl: daemonControl
        )
        return (store, provider, id)
    }

    func testLiveClaudeDaemonSkipsResumeTextAndKeepGoing() {
        let control = FakeDaemonControl()
        control.forcedIsLive = true
        let (store, provider, id) = makeClaudeStore(daemonControl: control)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))

        XCTAssertEqual(
            provider.configs.last?.initialInput, "",
            "the agent never stopped: nothing may be typed into an attached live daemon"
        )
        XCTAssertNil(
            store.pendingPrompts[id],
            "the agent never stopped: 'Keep going' must not be queued for a live daemon"
        )
        XCTAssertTrue(control.queriedIDs.contains(id))
    }

    func testDeadClaudeDaemonTypesResumeAndQueuesKeepGoing() {
        let control = FakeDaemonControl()
        control.forcedIsLive = false
        let (store, provider, id) = makeClaudeStore(daemonControl: control)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))

        XCTAssertFalse(
            (provider.configs.last?.initialInput ?? "").isEmpty,
            "unchanged behavior: a dead daemon still gets the resume command typed as today"
        )
        XCTAssertNotNil(
            store.pendingPrompts[id],
            "unchanged behavior: a dead daemon still gets the same 'Keep going' offer as today"
        )
    }

    // MARK: - Codex

    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    /// Records what would have been typed at the restored tab's shell.
    private final class SpyInjector: TextInjecting {
        var sent: [String] = []
        var returns = 0
        func sendText(_ text: String) { sent.append(text) }
        func sendReturn() { returns += 1 }
        func sendKillLine() {}
        func sendYank() {}
        func sendArrowDown() {}
        func sendArrowUp() {}
        func sendEscape() {}
        func readViewport() -> String? { nil }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// The `thread/read`/`thread/start` fixtures `CodexResumeTests.ScriptedTransport` uses —
    /// duplicated rather than imported, since that class is private to its own file. Answers
    /// the existing thread as idle, so `rebind` reuses it without a re-pin.
    private final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            switch method {
            case "thread/read":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","name":"restored","status":{"type":"idle"},"path":"/r/x.jsonl","cwd":"/w/a"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private let existing = UUID(uuidString: "01a01269-baa6-7493-8d15-8fa21bcb602b")!

    private var projectsRoot: URL!
    private var retained: [RecordingProvider] = []

    override func setUpWithError() throws {
        projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
        retained.removeAll()
    }

    /// A store holding one restored codex tab, wired to a scripted app-server exactly as
    /// `CodexResumeTests.makeRestoredStore` is — but with a `daemonControl` this file controls.
    private func makeCodexStore(
        daemonControl: DaemonControlling
    ) -> (store: SessionStore, injector: SpyInjector, tabID: UUID) {
        let tabID = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(
                id: tabID,
                title: "a",
                workingDirectory: "/w/a",
                pinnedConversationID: existing,
                agent: .codex,
                transcriptPath: "/r/x.jsonl"
            )],
            selectedSessionID: tabID,
            sessionCounter: 1
        )
        let provider = RecordingProvider()
        retained.append(provider)
        let store = SessionStore(
            provider: provider, persistence: persistence, daemonControl: daemonControl
        )
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl`: restoring a codex session
        // below builds a real `CodexStack`, whose `CodexNameWatcher` would otherwise tail it.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        let injector = SpyInjector()
        store.injectorOverride = injector
        store.overrideAdapter(
            CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport()), rolloutExists: { _ in true }),
            for: .codex, account: nil
        )
        return (store, injector, tabID)
    }

    func testLiveCodexDaemonSkipsTypingTheResumeCommand() async {
        let control = FakeDaemonControl()
        control.forcedIsLive = true
        let (store, injector, tabID) = makeCodexStore(daemonControl: control)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertTrue(
            injector.sent.isEmpty,
            "the codex thread is already live in the daemon: nothing may be typed at it"
        )
        XCTAssertNil(store.pendingPrompts[tabID])
        XCTAssertTrue(control.queriedIDs.contains(tabID))
    }

    func testDeadCodexDaemonRunsTheExistingResumeFlow() async {
        let control = FakeDaemonControl()
        control.forcedIsLive = false
        let (store, injector, _) = makeCodexStore(daemonControl: control)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(
            injector.sent, ["codex resume \(existing.uuidString.lowercased())"],
            "unchanged behavior: a dead daemon still gets the same typed resume as today"
        )
    }
}
