import XCTest
@testable import FlightDeck

/// That a tool's view of a session is assembled from the ADAPTER, not from `Session` fields.
/// These tests assert the routing, not the values — the values are `ClaudeAdapterTests`' job.
@MainActor
final class ToolContextTests: XCTestCase {
    private var projectsRoot: URL!

    override func setUpWithError() throws {
        // Same isolation `AgentRoutingTests` uses: creating a session derives a transcript
        // path and starts a watcher, and pointed at the real root these tests would poll the
        // developer's own transcripts.
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

    func testThereIsNoContextWithoutASelection() {
        let store = makeStore()
        store.selectedSessionID = nil
        XCTAssertNil(store.toolContext(), "no selection means no cwd, so no tool may run")
    }

    func testTheWorkingDirectoryComesFromTheAdapterNotFromTheSession() {
        // The point of the whole boundary: swap the adapter and the context follows. If this
        // ever passes with a field read, the seam is decorative.
        let store = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        store.overrideAdapter(RelocatingAdapter(), for: .claude)
        XCTAssertEqual(store.toolContext()?.workingDirectory, "/elsewhere")
    }

    func testIdentityAndTranscriptComeFromTheAdaptersBinding() {
        let store = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        store.overrideAdapter(RelocatingAdapter(), for: .claude)
        let context = store.toolContext()
        XCTAssertEqual(context?.conversationID, RelocatingAdapter.pinned)
        XCTAssertEqual(context?.transcriptPath, "/t/fixed.jsonl")
    }

    func testProjectFactsComeFromTheRepoNotFromTheAgent() {
        let store = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        store.overrideAdapter(RelocatingAdapter(), for: .claude)
        let context = store.toolContext()
        XCTAssertEqual(context?.projectPath, "/tmp/repo")
        XCTAssertEqual(context?.projectName, "repo")
        XCTAssertEqual(context?.agent, .claude)
    }

    /// Reports a location nothing on `Session` could produce, so a passing assertion can only
    /// mean the store asked the adapter.
    private struct RelocatingAdapter: AgentAdapter {
        static let id: AgentID = .claude
        static let pinned = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }
        func binding(for session: Session) -> AgentBinding {
            AgentBinding(
                conversationID: Self.pinned,
                transcriptURL: URL(fileURLWithPath: "/t/fixed.jsonl")
            )
        }
        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: "/elsewhere", binding: binding(for: session))
        }
        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
        func loginInvocation(for account: AgentAccount) -> LoginInvocation { LoginInvocation(command: "", inject: nil) }
    }
}
