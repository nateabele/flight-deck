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

    private func makeStore(preferences: PreferencesStore? = nil) -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        store.transcriptsRootOverride = projectsRoot
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
        store.overrideAdapter(RelocatingAdapter(), for: .claude, account: nil)
        XCTAssertEqual(store.toolContext()?.workingDirectory, "/elsewhere")
    }

    func testIdentityAndTranscriptComeFromTheAdaptersBinding() {
        let store = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        store.overrideAdapter(RelocatingAdapter(), for: .claude, account: nil)
        let context = store.toolContext()
        XCTAssertEqual(context?.conversationID, RelocatingAdapter.pinned)
        XCTAssertEqual(context?.transcriptPath, "/t/fixed.jsonl")
    }

    func testProjectFactsComeFromTheRepoNotFromTheAgent() {
        let store = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        store.overrideAdapter(RelocatingAdapter(), for: .claude, account: nil)
        let context = store.toolContext()
        XCTAssertEqual(context?.projectPath, "/tmp/repo")
        XCTAssertEqual(context?.projectName, "repo")
        XCTAssertEqual(context?.agent, .claude)
    }

    /// The account half feeds a tool the same variable a launched session gets — see
    /// `SessionStore.toolContext()` — so a template naming `${account}`/`${accountHome}` or
    /// reading `$CLAUDE_CONFIG_DIR` behaves identically whether it opened from the session or
    /// from a tool launched against it.
    func testAccountFieldsComeFromTheSessionsResolvedAccount() {
        let home = projectsRoot.appendingPathComponent("work-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let account = AgentAccount(agent: .claude, displayName: "Work", home: home)
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = [account]

        let store = makeStore(preferences: preferences)
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        let context = store.toolContext()

        XCTAssertEqual(context?.accountName, "Work")
        XCTAssertEqual(context?.accountHome, home.path)
        XCTAssertEqual(context?.accountEnvironment, ["CLAUDE_CONFIG_DIR": home.path])
    }

    /// A tool is not a session: a tab whose stored account has been deleted must still hand
    /// back a context, just with nothing in the account fields, rather than making `toolContext`
    /// return nil and disabling every tool over what is otherwise a perfectly usable tab.
    func testNoResolvableAccountStillProducesAContext() {
        let store = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        let context = store.toolContext()

        XCTAssertNotNil(context)
        XCTAssertNil(context?.accountName)
        XCTAssertNil(context?.accountHome)
        XCTAssertEqual(context?.accountEnvironment, [:])
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
