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

    /// `SessionStore.provider` is weak, so a provider held only by the store deallocates
    /// before it is ever asked for a surface — same retention trick as `SessionCreationTests`.
    private var retainedProviders: [RecordingProvider] = []

    private func makeStore() -> SessionStore {
        SessionStore(provider: nil, persistence: nil)
    }

    private func makeRecordingStore() -> (SessionStore, RecordingProvider) {
        let provider = RecordingProvider()
        retainedProviders.append(provider)
        return (SessionStore(provider: provider, persistence: nil), provider)
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

    /// The status registry is claude's app-wide source and `SessionStore` scans it once per
    /// tick, so the runtime is *fed* rather than owning a scanner. This pins that the feed is
    /// actually connected — in production it agrees with `applyRegistry` by construction, so
    /// only a second, disagreeing scan can show the wire is live.
    func testTheStatusRegistryFansOutThroughTheRuntime() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: entry(session.pinnedConversationID, activity: .busy)])
        XCTAssertEqual(store.status(for: session.id)?.activity, .busy)

        store.ingestStatusEntriesForTesting(
            [1: entry(session.pinnedConversationID, activity: .waiting)]
        )
        XCTAssertEqual(store.status(for: session.id)?.activity, .waiting,
                       "a registry row must reach the tab through its runtime")
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
