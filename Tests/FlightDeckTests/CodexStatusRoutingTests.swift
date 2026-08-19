import XCTest
@testable import FlightDeck

/// Codex has no status registry behind it: it reports what it is doing outright, and those
/// reports have to land on the same machinery a claude registry tick drives — the diff that
/// `applyReadState`, `deliverNotifications` and `cancelSupersededPrompts` all read.
///
/// Writing `statuses` directly instead is the bug these tests exist to prevent: the written
/// value becomes the `previous` snapshot the next tick diffs against, so a later tick
/// fabricates or swallows an edge.
@MainActor
final class CodexStatusRoutingTests: XCTestCase {
    private let thread = UUID(uuidString: "01a01705-bd49-7b70-a0a1-4514d4bda5dd")!

    /// Codex's shape with the protocol removed: identity is *returned* by `prepare`, and the
    /// tab that comes back is pinned to it. No transport, so nothing here can spawn or hang.
    private struct StubCodexAdapter: AgentAdapter {
        static let id: AgentID = .codex
        let thread: UUID

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            AgentBinding(conversationID: thread, transcriptURL: nil)
        }

        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }

        func launchCommand(_ b: AgentBinding, _: Session, _: AgentOptions) -> String {
            "codex resume \(b.conversationID.uuidString.lowercased())\n"
        }

        func resumeCommand(_ b: AgentBinding, _ s: Session, _ o: AgentOptions) -> String {
            launchCommand(b, s, o)
        }

        func rename(_: AgentBinding, to: String) async throws {}
    }

    private final class SpyNotifier: Notifying {
        var notified: [UUID] = []
        var withdrawn: [UUID] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, body: String) { notified.append(sessionID) }
        func withdraw(sessionID: UUID) { withdrawn.append(sessionID) }
    }

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    /// Swallows what the default reporter would put on screen. Nothing here is *meant* to
    /// fail a creation, but the default is a real `NSAlert`, and a test suite that can raise
    /// a panel on the machine running it is a test suite that will.
    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.projectsRoot = projectsRoot
        store.launchFailureReporter = SilentReporter()
        // Deterministic rather than whatever `NSApp` reports under `xctest`: read state and
        // notification delivery both branch on it.
        store.appIsActive = { false }
        store.titleResolver = { _, done in done(nil) }
        return store
    }

    /// Returns the tab id and the fake runtime feeding it.
    private func makeCodexTab(in store: SessionStore) async throws -> (UUID, FakeAgentRuntime) {
        let runtime = FakeAgentRuntime()
        store.overrideAdapter(StubCodexAdapter(thread: thread), for: .codex)
        store.overrideRuntime(runtime, for: .codex)
        let result = await store.createSession(agent: .codex, in: tmp.path)
        guard case .success(let id) = result else {
            throw XCTSkip("createSession failed: \(result)")
        }
        return (id, runtime)
    }

    private func entry(_ conversation: UUID, _ activity: SessionActivity, pid: pid_t = 1)
        -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: conversation, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: tmp.path, procStart: "start-a")
    }

    func testAnActivityReportMovesTheTabsStatus() async throws {
        let store = makeStore()
        let (tab, runtime) = try await makeCodexTab(in: store)

        runtime.emit(.activity(.busy), for: thread)

        XCTAssertEqual(store.status(for: tab)?.activity, .busy)
    }

    /// The unread mark is what tells you a session finished while you were away, and for
    /// codex it can only come from here: there is no registry tick to produce the edge.
    func testATurnEndingMarksTheTabUnread() async throws {
        let store = makeStore()
        let (tab, runtime) = try await makeCodexTab(in: store)

        runtime.emit(.activity(.busy), for: thread)
        runtime.emit(.turnEnded, for: thread)

        XCTAssertEqual(store.status(for: tab)?.activity, .idle)
        XCTAssertTrue(store.unreadIdle.contains(tab),
                      "a codex turn ending away from the user must mark the tab unread")
    }

    /// `turn/completed` maps to `.activity(.idle)` *then* `.turnEnded`, so the second event
    /// lands on a tab that is already idle. It must not re-mark or re-notify.
    func testTheIdleReportAndTheTurnEndAgreeRatherThanFireTwice() async throws {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        let (tab, runtime) = try await makeCodexTab(in: store)

        runtime.emit(.activity(.busy), for: thread)
        runtime.emit(.activity(.idle), for: thread)
        store.selectSession(tab)                // the user looks at it; the mark clears
        runtime.emit(.turnEnded, for: thread)   // …and the trailing half of turn/completed lands

        XCTAssertFalse(store.unreadIdle.contains(tab),
                       "idle → idle is not an edge; the trailing turn end must not re-mark")
        XCTAssertTrue(spy.notified.isEmpty)
    }

    /// A blocked codex thread has to raise the same banner a blocked claude does.
    func testWaitingNotifiesThroughTheSamePolicy() async throws {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        let (tab, runtime) = try await makeCodexTab(in: store)

        runtime.emit(.activity(.busy), for: thread)
        runtime.emit(.activity(.waiting), for: thread)

        XCTAssertEqual(spy.notified, [tab])

        runtime.emit(.activity(.busy), for: thread)
        XCTAssertEqual(spy.withdrawn, [tab], "the banner is stale once the prompt is gone")
    }

    /// The regression this file is really about. `applyRegistry` rebuilds `statuses` from
    /// pid anchors a codex tab will never have, so a tick that rebuilt blindly would erase
    /// codex's status and hand `applyReadState` a fabricated `busy → gone` edge.
    func testAClaudeRegistryTickLeavesACodexStatusAlone() async throws {
        let store = makeStore()
        let (codexTab, runtime) = try await makeCodexTab(in: store)
        let claudeTab = store.newSession(in: tmp)
        runtime.emit(.activity(.busy), for: thread)

        store.applyRegistry([1: entry(claudeTab.pinnedConversationID, .busy)])

        XCTAssertEqual(store.status(for: codexTab)?.activity, .busy,
                       "a claude scan can neither confirm nor refute a codex thread")
        XCTAssertEqual(store.status(for: claudeTab.id)?.activity, .busy)
        XCTAssertTrue(store.unreadIdle.isEmpty, "no edge happened; nothing may be marked")
    }

    /// The other direction: a codex report must not disturb the claude tabs sharing the map.
    func testACodexReportLeavesClaudeStatusesAlone() async throws {
        let store = makeStore()
        let (_, runtime) = try await makeCodexTab(in: store)
        let claudeTab = store.newSession(in: tmp)
        store.applyRegistry([1: entry(claudeTab.pinnedConversationID, .waiting)])

        runtime.emit(.activity(.busy), for: thread)

        XCTAssertEqual(store.status(for: claudeTab.id)?.activity, .waiting)
    }

    /// Closing a codex tab drops its status the same way a claude tab's is dropped, and a
    /// later registry tick must not resurrect it from the carry-forward.
    func testClosingACodexTabDropsItsStatus() async throws {
        let store = makeStore()
        let (tab, runtime) = try await makeCodexTab(in: store)
        runtime.emit(.activity(.busy), for: thread)

        store.closeSession(tab)
        store.applyRegistry([:])

        XCTAssertNil(store.status(for: tab))
    }
}
