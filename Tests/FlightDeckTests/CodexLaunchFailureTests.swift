import FleetKit
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

    /// Blocks in `prepare` until it is released, so a test can act while a codex creation is
    /// genuinely mid-negotiation.
    private final class GatedAdapter: AgentAdapter {
        static let id: AgentID = .codex
        /// Codex's answers, because this stands in for codex — the store reads both
        /// capabilities off `AgentID`, so a stub that disagreed would describe an agent that
        /// does not exist.
        static let textChannel: AgentTextChannel? = nil
        static let dialogDriver: AgentDialogDriver? = nil
        static let negotiatesIdentity = true
        static let needsRuntimeStart = true
        static let hasStatusRegistry = false
        nonisolated static func sanitizedTitle(_ raw: String) -> String? {
            CodexAdapter.sanitizedTitle(raw)
        }
        nonisolated static func title(fromTranscriptAt url: URL) -> String? {
            CodexAdapter.title(fromTranscriptAt: url)
        }
        nonisolated static func timelineItems(inLine line: String, at offset: Int) -> [TimelineItem] {
            CodexAdapter.timelineItems(inLine: line, at: offset)
        }
        nonisolated static let homeMarkerFile = CodexAdapter.homeMarkerFile
        nonisolated static func identity(fromHomeData data: Data) -> AccountIdentity? {
            CodexAdapter.identity(fromHomeData: data)
        }
        static let openPromptReader: AgentOpenPromptReader? = CodexAdapter.openPromptReader
        private var resume: CheckedContinuation<Void, Never>?
        private var entered: CheckedContinuation<Void, Never>?
        private var hasEntered = false

        /// Suspends until `prepare` is actually inside the gate.
        func waitUntilPreparing() async {
            guard !hasEntered else { return }
            await withCheckedContinuation { entered = $0 }
        }

        func release() { resume?.resume(); resume = nil }

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            hasEntered = true
            entered?.resume()
            entered = nil
            await withCheckedContinuation { resume = $0 }
            return AgentBinding(conversationID: UUID(), transcriptURL: nil)
        }

        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }

        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
        }

        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
        func loginInvocation(for account: AgentAccount) -> LoginInvocation { LoginInvocation(command: "", inject: nil) }
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
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl`: every test below creates a
        // codex tab, and only the adapter is overridden — `runtime(for: .codex)` still builds
        // a real `CodexStack`, whose `CodexNameWatcher` would otherwise tail the user's home.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = reporter
        return (store, provider)
    }

    private var reporter = SpyReporter()

    // MARK: - Stopping the app-server without racing a creation

    /// Closing the last codex tab must not kill the app-server a *concurrent* creation is
    /// still negotiating against.
    ///
    /// `stopCodexIfUnused` counts codex tabs in `repos`, and a creation's tab is not in
    /// `repos` until `addSession` runs — so a close landing mid-`prepare` used to stop the
    /// app-server between `thread/start` and `thread/name/set`, which EVAPORATES the thread,
    /// because naming is what commits it. The tab would then exist bound to a thread
    /// `codex resume` cannot find.
    func testClosingTheLastTabDoesNotKillAnAppServerACreationIsStillUsing() async {
        let (store, _) = makeStore()
        // Builds the stack without spawning anything — only `startCodex()` runs a process,
        // and the override below is what keeps `createSession` away from it. Building it
        // first is what makes `stopCodexIfUnused` observable at all. `account: nil` is the
        // key every tab in this file resolves to: these stores have no `PreferencesStore`,
        // so there is no account to name.
        _ = store.adapter(for: .codex, account: nil)
        XCTAssertTrue(store.hasCodexStackForTesting)
        let gate = GatedAdapter()
        store.overrideAdapter(gate, for: .codex, account: nil)
        let claudeTab = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        let creation = Task { await store.createSession(agent: .codex, in: NSTemporaryDirectory()) }
        await gate.waitUntilPreparing()

        store.closeSession(claudeTab.id)

        XCTAssertTrue(store.hasCodexStackForTesting,
                      "a creation mid-negotiation still needs the app-server it is talking to")

        gate.release()
        _ = await creation.value
    }

    /// The other half: once that creation is done, the deferred teardown must actually run.
    /// Skipping it would leave `codex app-server` alive with no codex tab for the rest of
    /// the session, which is the leak `stopCodexIfUnused` exists to prevent.
    func testTheDeferredTeardownRunsOnceTheCreationFinishes() async {
        let (store, _) = makeStore()
        _ = store.adapter(for: .codex, account: nil)
        let transport = DeadTransport()
        let rpc = CodexRPC(transport: transport)
        transport.rpc = rpc            // this creation will fail, leaving no codex tab
        store.overrideAdapter(CodexAdapter(rpc: rpc), for: .codex, account: nil)

        _ = await store.createSession(agent: .codex, in: NSTemporaryDirectory())

        XCTAssertFalse(store.hasCodexStackForTesting,
                       "a failed creation must not leave the app-server running with no codex tab")
    }

    func testAHardPrepareFailureCreatesNoTab() async {
        let (store, _) = makeStore()
        let transport = DeadTransport()
        let rpc = CodexRPC(transport: transport)
        transport.rpc = rpc            // the app-server is gone before we start
        store.overrideAdapter(CodexAdapter(rpc: rpc), for: .codex, account: nil)

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
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: RefusingTransport())),
                              for: .codex, account: nil)

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
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: RefusingTransport())),
                              for: .codex, account: nil)

        _ = await store.createSession(agent: .codex, in: NSTemporaryDirectory())

        XCTAssertEqual(reporter.reported.count, 1, "a failed creation must not fail silently")
    }

    /// Carry-forward from Task 5: creation must go through `prepare`, never `binding(for:)`.
    /// `binding(for:)` would hand back the tab's own locally-minted id, and
    /// `codex resume <that>` dies with "No saved session found with ID …".
    func testACreatedCodexTabIsPinnedToTheThreadCodexNamed() async {
        let (store, provider) = makeStore()
        let transport = ScriptedTransport()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: transport)), for: .codex, account: nil)

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
        XCTAssertEqual(transport.methods,
                       ["thread/start", "thread/name/set", "thread/archive", "thread/unarchive"],
                       "start then name, in that order — naming is what commits the thread — "
                       + "then archive/unarchive to release the writer lock thread/start took out")
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

    /// A crashed app-server must be forgotten, not reused.
    ///
    /// `CodexRPC.transportClosed()` fails what is pending *at that moment* and latches
    /// nothing, so a stack kept past the crash would take the next creation's `thread/start`,
    /// swallow the write into a dead pipe, and suspend it on a continuation nothing will ever
    /// resume — no alert, no failed `Result`, just a session that never appears.
    ///
    /// Deterministic and bounded: nothing here awaits a process, so a regression fails on the
    /// assertions rather than stalling the suite.
    func testACrashedAppServerIsForgottenSoTheNextSessionRespawns() async {
        let (store, _) = makeStore()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport())),
                              for: .codex, account: nil)
        let first = await store.createSession(agent: .codex, in: NSTemporaryDirectory())
        guard case .success = first else { return XCTFail("expected success: \(first)") }
        let before = store.runtime(for: .codex, account: nil) as AnyObject
        XCTAssertTrue(store.hasCodexStackForTesting)

        store.simulateCodexTerminationForTesting(account: nil)

        XCTAssertFalse(store.hasCodexStackForTesting,
                       "the store must forget an app-server that stopped running")

        // The next creation completes rather than hanging, and is served by a *new* stack.
        let second = await store.createSession(agent: .codex, in: NSTemporaryDirectory())
        guard case .success = second else { return XCTFail("expected success: \(second)") }
        XCTAssertTrue(store.hasCodexStackForTesting)
        XCTAssertFalse(store.runtime(for: .codex, account: nil) === before,
                       "a creation after a crash must re-spawn, not talk to the corpse")
    }

    /// The app-server is app-wide and lazy: nothing spawns it until a codex tab exists, and
    /// nothing keeps it alive once the last one is gone. Building the stack starts no
    /// process, so this test observes the lifetime without ever running `codex`.
    func testTheStackIsBuiltOnFirstCodexUseAndDroppedWithTheLastCodexTab() async {
        let (store, _) = makeStore()
        store.overrideAdapter(CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport())),
                              for: .codex, account: nil)

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
