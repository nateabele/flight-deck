import XCTest
@testable import FlightDeck

/// Creating a codex tab, and refusing to create one that could never launch.
///
/// Nothing here spawns `codex`: every store below is handed a `CodexAdapter` over a scripted
/// transport through `overrideAdapter`, which is also what keeps the app-server from ever
/// being spawned — `createSession` only starts a process for the adapter it built itself.
@MainActor
final class CodexLaunchFailureTests: XCTestCase {
    /// The thread id codex hands back. Deliberately NOT any tab id: the whole point of
    /// `prepare` is that codex names the conversation, and a tab that launched with its own
    /// id would resume a thread that does not exist.
    private let threadID = UUID(uuidString: "01a01705-bd49-7b70-a0a1-4514d4bda5dd")!

    /// A `codex app-server` that answers. Replies inline from `send`, so every assertion in
    /// this file is deterministic without a clock or an expectation.
    private final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        var threadID = "01a01705-bd49-7b70-a0a1-4514d4bda5dd"

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(threadID)","path":"/r/t.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    /// An app-server that is not there. Fails the request from inside `send` rather than
    /// answering nothing, deliberately: `CodexRPC.transportClosed()` resumes what is pending
    /// *at that moment* and latches nothing, so a transport that simply stays silent would
    /// hang this test rather than fail it.
    private final class DeadTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        weak var rpc: CodexRPC?
        func send(_ line: String) { rpc?.transportClosed() }
    }

    /// Rejects one specific request, the way codex rejects a thread it will not open.
    private final class RefusingTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? Int else { return }
            onLine?(#"{"id":\#(id),"error":{"code":-32602,"message":"cwd is not trusted"}}"#)
        }
    }

    private final class SpyReporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }

    /// Keeps every configuration it was handed: the launch text is what proves which
    /// conversation the pty was pointed at.
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

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

    /// Every store gets the spy reporter, not only the test that asserts on it.
    ///
    /// The default reporter is an `NSAlert`, and a store built without this one would put a
    /// real panel on the machine running the suite the moment a creation failed — which is
    /// exactly what an earlier draft of these tests did.
    ///
    /// `SessionStore.provider` is weak, so a provider held only by the store deallocates
    /// before it is ever asked for a surface — same retention trick as `SessionCreationTests`.
    private func makeStore() -> (SessionStore, RecordingProvider) {
        let provider = RecordingProvider()
        retained.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.projectsRoot = projectsRoot
        store.launchFailureReporter = reporter
        return (store, provider)
    }

    private var reporter = SpyReporter()

    func testAHardPrepareFailureCreatesNoTab() async {
        let (store, _) = makeStore()
        let transport = DeadTransport()
        let rpc = CodexRPC(transport: transport)
        transport.rpc = rpc            // the app-server is gone before we start
        store.overrideAdapter(CodexAdapter(rpc: rpc), for: .codex)

        let before = store.repos.flatMap(\.sessions).count
        let result = await store.createSession(agent: .codex, in: NSTemporaryDirectory())

        // A tab bound to a thread that was never committed looks fine until the terminal
        // says it cannot resume. No tab plus a named error beats a tab that silently
        // degrades — the exact failure class this codebase keeps fixing.
        guard case .failure(let error) = result else { return XCTFail("expected a hard failure") }
        XCTAssertEqual(error, .prepareFailed("the Codex app-server stopped before it answered."),
                       "an alert reading \"transportClosed\" has told the user nothing")
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, before,
                       "no tab may survive a failed prepare")
    }

    /// The commit half of `prepare`. `thread/start` alone persists nothing, so a failure to
    /// name the thread has to fail the whole creation rather than leave a tab behind.
    func testARefusedThreadAlsoCreatesNoTab() async {
        let (store, _) = makeStore()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: RefusingTransport())), for: .codex)

        let result = await store.createSession(agent: .codex, in: NSTemporaryDirectory())

        guard case .failure(let error) = result else { return XCTFail("expected a hard failure") }
        XCTAssertEqual(error, .prepareFailed("cwd is not trusted"),
                       "codex's own message is the most specific thing anyone knows about "
                       + "the failure; the alert must repeat it rather than show a case name")
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty)
    }

    func testTheErrorNamesTheCause() {
        XCTAssertTrue(
            AgentLaunchError.versionTooOld(found: "0.140.0", minimum: "0.142.4")
                .errorDescription?.contains("0.142.4") ?? false,
            "the alert must say what to do, not just that something failed"
        )
    }

    /// A `Result` nobody reads is a silent failure. The store reports it itself, so every
    /// call site — menu item, shortcut, drop — gets the alert without repeating the code.
    func testAFailedCreationReachesTheUser() async {
        let (store, _) = makeStore()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: RefusingTransport())), for: .codex)

        _ = await store.createSession(agent: .codex, in: NSTemporaryDirectory())

        XCTAssertEqual(reporter.reported.count, 1, "a failed creation must not fail silently")
    }

    /// Carry-forward from Task 5: creation must go through `prepare`, never `binding(for:)`.
    /// `binding(for:)` would hand back the tab's own locally-minted id, and
    /// `codex resume <that>` dies with "No saved session found with ID …".
    func testACreatedCodexTabIsPinnedToTheThreadCodexNamed() async {
        let (store, provider) = makeStore()
        let transport = ScriptedTransport()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: transport)), for: .codex)

        let result = await store.createSession(agent: .codex, in: NSTemporaryDirectory())

        guard case .success(let tabID) = result else { return XCTFail("expected success: \(result)") }
        let session = store.repos.flatMap(\.sessions).first { $0.id == tabID }
        XCTAssertEqual(session?.agent, .codex)
        XCTAssertEqual(session?.pinnedConversationID, threadID,
                       "the tab must follow the thread codex named, not its own id")
        XCTAssertNotEqual(session?.pinnedConversationID, tabID)
        XCTAssertEqual(session?.transcriptPath, "/r/t.jsonl",
                       "codex reports its rollout path; the tab must keep it")
        XCTAssertEqual(provider.configs.last?.initialInput,
                       "codex resume \(threadID.uuidString.lowercased())\n")
        XCTAssertEqual(transport.methods, ["thread/start", "thread/name/set"],
                       "start then name, in that order — naming is what commits the thread")
    }

    /// Claude mints its own id and cannot fail, so it must keep the synchronous path
    /// `seedInitialSession` runs inside `SessionStore.init`.
    func testCreatingAClaudeSessionKeepsItsOwnIdentity() async {
        let (store, _) = makeStore()

        let result = await store.createSession(agent: .claude, in: NSTemporaryDirectory())

        guard case .success(let tabID) = result else { return XCTFail("claude cannot fail here") }
        let session = store.repos.flatMap(\.sessions).first { $0.id == tabID }
        XCTAssertEqual(session?.agent, .claude)
        XCTAssertEqual(session?.pinnedConversationID, tabID)
    }

    /// The app-server is app-wide and lazy: nothing spawns it until a codex tab exists, and
    /// nothing keeps it alive once the last one is gone. Building the stack starts no
    /// process, so this test observes the lifetime without ever running `codex`.
    func testTheStackIsBuiltOnFirstCodexUseAndDroppedWithTheLastCodexTab() async {
        let (store, _) = makeStore()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport())), for: .codex)

        XCTAssertFalse(store.hasCodexStackForTesting, "a store with no codex tab spawns nothing")
        _ = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        XCTAssertFalse(store.hasCodexStackForTesting, "a claude tab must not build one either")

        let result = await store.createSession(agent: .codex, in: NSTemporaryDirectory())
        guard case .success(let tabID) = result else { return XCTFail("expected success: \(result)") }
        XCTAssertTrue(store.hasCodexStackForTesting, "a codex tab needs the runtime behind it")

        store.closeSession(tabID)
        XCTAssertFalse(store.hasCodexStackForTesting,
                       "the last codex tab closing must not leave an app-server running")
    }
}
