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
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl` — tests below create codex
        // tabs, and a real path would have those tabs' watchers tail the user's own home.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        return store
    }

    private func makeRecordingStore() -> (SessionStore, RecordingProvider) {
        let provider = RecordingProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        return (store, provider)
    }

    /// `account: nil` throughout this file, and it is not a placeholder: every store here is
    /// built with no `PreferencesStore`, so there is no account to name and `nil` is exactly
    /// the key `SessionStore.instance(for:)` resolves for the tabs these tests create. An
    /// override filed under any other account would simply not be found.
    func testTheStoreSelectsAnAdapterByTheSessionsAgent() {
        let store = makeStore()
        XCTAssertEqual(type(of: store.adapter(for: .claude, account: nil)).id, .claude)
    }

    func testEventsFromARuntimeReachTheSessionTitle() {
        let store = makeStore()
        let fake = FakeAgentRuntime()
        store.overrideRuntime(fake, for: .claude, account: nil)

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
        store.overrideRuntime(fake, for: .claude, account: nil)

        let session = store.newSession(in: tmp)
        store.closeSession(session.id)

        XCTAssertEqual(fake.detached, [session.pinnedConversationID])
    }

    /// The launch text is the adapter's to build, so an overridden adapter must be what the
    /// pty is fed — otherwise the store is still talking to `ClaudeSession` behind its back.
    func testTheAdapterBuildsTheLaunchCommand() {
        let (store, provider) = makeRecordingStore()
        store.overrideAdapter(StubAdapter(), for: .claude, account: nil)

        _ = store.newSession(in: tmp)

        XCTAssertEqual(provider.configs.last?.initialInput, "stub-launch")
    }

    // MARK: - Which route the SIDEBAR's rename takes

    /// Answers `thread/name/set` and records every method it was asked for.
    private final class RenameTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        private(set) var names: [String] = []

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            if method == "thread/name/set",
               let name = (obj["params"] as? [String: Any])?["name"] as? String {
                names.append(name)
            }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","cwd":"/w/a","path":"/r/x.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    /// `SessionSidebar` calls `store.rename` for every tab regardless of agent, so this is
    /// the route production actually takes — unlike
    /// `testTheAdaptersRenameTypesThroughTheStoresOwnInjectionRoute` below, which calls the
    /// adapter directly and therefore could not have caught a store that never dispatched.
    func testRenamingACodexTabRenamesTheCodexThread() async throws {
        let store = makeStore()
        store.launchFailureReporter = SilentReporter()
        let t = RenameTransport()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: t)), for: .codex, account: nil)
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        guard case .success(let id) = await store.createSession(agent: .codex, in: tmp.path) else {
            return XCTFail("codex tab creation must succeed against a scripted transport")
        }
        spy.events.removeAll()
        // Creation already named the thread once — `thread/name/set` is what commits it — so
        // the rename is the SECOND name, not the first.
        let namesAfterCreation = t.names.count

        store.rename(id, to: "renamed")
        // The rename is dispatched, not awaited: the sidebar must not block on the RPC. So
        // the request lands in a later turn of the run loop, and a bare `Task.yield()` is one
        // scheduling assumption too many — spin until it arrives, bounded.
        for _ in 0..<100 where t.names.count == namesAfterCreation { await Task.yield() }

        XCTAssertEqual(store.title(of: id), "renamed", "the sidebar is authoritative and immediate")
        XCTAssertEqual(t.names.last, "renamed",
                       "renaming a codex tab must send thread/name/set — the thread name is what "
                       + "session_index.jsonl and thread/read both report, so a divergence "
                       + "flicks the title back on the next tail or restore")
        XCTAssertTrue(spy.events.isEmpty,
                      "a codex tab must never queue `/rename` for the pty: nothing retires the "
                      + "entry, and a match would paste it into the user's live codex session")
    }

    /// The other half, and the one that must not have moved: claude still types.
    func testRenamingAClaudeTabStillTypesIntoThePtyAndSendsNoRequest() {
        let store = makeStore()
        let t = RenameTransport()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: t)), for: .codex, account: nil)
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity: .idle)])
        spy.events.removeAll()

        store.rename(session.id, to: "renamed")

        // Synchronously, in the same turn of the run loop, exactly as before the dispatch
        // existed: `inject` decides *now* whether the input bar is busy.
        XCTAssertEqual(spy.events, [.killLine, .text("/rename renamed"), .ret])
        XCTAssertTrue(t.methods.isEmpty, "claude's rename must not reach codex's app-server")
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

        let adapter = store.adapter(for: .claude, account: nil)
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
        /// Claude's answers, because this stands in for claude — the store reads both
        /// capabilities off `AgentID`, so a stub that disagreed would describe an agent that
        /// does not exist.
        static let textChannel: AgentTextChannel? = ClaudeTextChannel()
        static let dialogDriver: AgentDialogDriver? = ClaudeDialogDriver()
        static let negotiatesIdentity = false
        static let needsRuntimeStart = false
        static let hasStatusRegistry = true

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }

        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }

        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
        }

        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "stub-launch" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "stub-resume" }
        func rename(_: AgentBinding, to: String) async throws {}
        func loginInvocation(for account: AgentAccount) -> LoginInvocation { LoginInvocation(command: "", inject: nil) }
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
