import XCTest
@testable import FlightDeck

/// The seam itself: that the store picks an agent's adapter and runtime by the *session's*
/// agent rather than reaching for `ClaudeSession` directly, and that whatever a runtime
/// reports lands on the tab. Everything claude-specific about that route is pinned by the
/// pre-existing suites (`SessionLaunchTests`, `ConversationRepinTests`,
/// `SessionProjectMoveTests`); these tests pin only that the route exists.
@MainActor
final class AgentRoutingTests: XCTestCase {
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// A throwaway stand-in for `~/.claude/projects`. Every store below creates a session,
    /// and creating one now derives a transcript path through `ClaudeAdapter` and starts a
    /// watcher polling it — pointed at the real root, these tests would poll the user's own
    /// transcripts. This diff is what taught the adapter to honour `projectsRoot`; these
    /// tests are the first that must use it.
    private var projectsRoot: URL!

    /// `SessionStore.provider` is weak, so a provider held only by the store deallocates
    /// before it is ever asked for a surface — same retention trick as `SessionCreationTests`.
    private var retainedProviders: [RecordingProvider] = []

    override func setUpWithError() throws {
        projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.projectsRoot = projectsRoot
        return store
    }

    private func makeRecordingStore() -> (SessionStore, RecordingProvider) {
        let provider = RecordingProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.projectsRoot = projectsRoot
        return (store, provider)
    }

    func testTheStoreSelectsAnAdapterByTheSessionsAgent() {
        let store = makeStore()
        XCTAssertEqual(type(of: store.adapter(for: .claude)).id, .claude)
    }

    func testEventsFromARuntimeReachTheSessionTitle() {
        let store = makeStore()
        let fake = FakeAgentRuntime()
        store.overrideRuntime(fake, for: .claude)

        let session = store.newSession(in: tmp)
        XCTAssertEqual(fake.attached, [session.pinnedConversationID],
                       "creating a tab must attach its binding to the agent's runtime")

        fake.emit(.title("after"), for: session.pinnedConversationID)

        XCTAssertEqual(store.title(of: session.id), "after",
                       "a runtime event must move the sidebar title")
    }

    func testClosingATabDetachesItsBinding() {
        let store = makeStore()
        let fake = FakeAgentRuntime()
        store.overrideRuntime(fake, for: .claude)

        let session = store.newSession(in: tmp)
        store.closeSession(session.id)

        XCTAssertEqual(fake.detached, [session.pinnedConversationID])
    }

    /// The launch text is the adapter's to build, so an overridden adapter must be what the
    /// pty is fed — otherwise the store is still talking to `ClaudeSession` behind its back.
    func testTheAdapterBuildsTheLaunchCommand() {
        let (store, provider) = makeRecordingStore()
        store.overrideAdapter(StubAdapter(), for: .claude)

        _ = store.newSession(in: tmp)

        XCTAssertEqual(provider.configs.last?.initialInput, "stub-launch")
    }

    /// `AgentAdapter.rename` is how an agent that owns its own conversation name gets asked
    /// to change it. For claude that is still `/rename` typed into the pty, so it must land
    /// on the *same* route `SessionStore.rename` uses — one `pendingRenames` entry behind one
    /// `injecting` guard, not a second injector wired in beside it.
    func testTheAdaptersRenameTypesThroughTheStoresOwnInjectionRoute() async throws {
        let store = makeStore()
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity: .idle)])
        spy.events.removeAll()

        let adapter = store.adapter(for: .claude)
        // Deliberately unsanitized: the adapter route is the one an agent's own caller
        // reaches, and what it queues becomes text typed into a pty.
        try await adapter.rename(adapter.binding(for: session), to: "  from\nthe adapter  ")

        XCTAssertEqual(spy.events, [.killLine, .text("/rename fromthe adapter"), .ret],
                       "the adapter route must reach the same sanitizer as the sidebar's")
    }

    private func entry(_ conversation: UUID, activity: SessionActivity) -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: conversation, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: tmp.path)
    }

    /// Mirrors `ClaudeAdapter` with every command replaced by a constant, so a test can see
    /// which of the two the store asked for.
    private struct StubAdapter: AgentAdapter {
        static let id: AgentID = .claude

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }

        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }

        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "stub-launch" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "stub-resume" }
        func rename(_: AgentBinding, to: String) async throws {}
    }

    /// Keeps every configuration it was handed. `SessionCreationTests.StubProvider` throws
    /// its config away, and the initial input is exactly what these tests are about.
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }
}
