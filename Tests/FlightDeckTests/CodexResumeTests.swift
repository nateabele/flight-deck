import XCTest
@testable import FlightDeck

/// Bringing a codex tab back across a relaunch: settling its thread before anything is typed
/// at it, re-pinning when that thread is gone, and starting the app-server the restored tab
/// needs in order to report anything at all.
///
/// Nothing here spawns `codex`. Every store is handed a `CodexAdapter` over a scripted
/// transport through `overrideAdapter`, which is also what keeps the restore path from
/// reaching `startCodex()` — see `codexServerRequestsForTesting` for how "it asked for the
/// app-server" is asserted without one existing.
@MainActor
final class CodexResumeTests: XCTestCase {
    final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        var threadMissing = false

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            switch method {
            case "thread/read" where threadMissing:
                onLine?(#"{"id":\#(id),"error":{"code":-32602,"message":"no such thread"}}"#)
            case "thread/read":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","name":"restored","status":{"type":"idle"},"path":"/r/x.jsonl","cwd":"/w/a"}}}"#)
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01705-bd49-7b70-a0a1-4514d4bda5dd","cwd":"/w/a","path":"/r/y.jsonl"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    /// An app-server that takes every request and never answers. Stands in for one that
    /// completed its handshake and then went quiet — the case `CodexRPC.request` has no
    /// deadline of its own for.
    private final class SilentTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {}
    }

    private let existing = UUID(uuidString: "01a01269-baa6-7493-8d15-8fa21bcb602b")!
    private let fresh = UUID(uuidString: "01a01705-bd49-7b70-a0a1-4514d4bda5dd")!

    // MARK: - The adapter

    func testReadReturnsTheAuthoritativeTitleAndStatus() async throws {
        let t = ScriptedTransport()
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

        let state = try await adapter.read(AgentBinding(conversationID: existing, transcriptURL: nil))

        // This is what reconcile-on-first-contact applies for a tab that launched behind
        // the hooks prompt and therefore reported nothing until the user cleared it.
        XCTAssertEqual(state.title, "restored")
        XCTAssertEqual(state.activity, .idle)
    }

    func testRebindReusesAThreadThatStillExists() async throws {
        let t = ScriptedTransport()
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        let session = Session(title: "t", workingDirectory: "/w/a", pinnedConversationID: existing)

        let binding = try await adapter.rebind(for: session, options: .codex(CodexThreadOptions()))

        XCTAssertEqual(binding.conversationID, existing, "a live thread must be reused, not replaced")
        XCTAssertFalse(t.methods.contains("thread/start"))
    }

    func testRebindStartsAFreshThreadWhenTheOldOneIsGone() async throws {
        let t = ScriptedTransport()
        t.threadMissing = true
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        let session = Session(title: "t", workingDirectory: "/w/a", pinnedConversationID: existing)

        let binding = try await adapter.rebind(for: session, options: .codex(CodexThreadOptions()))

        // Mirrors claude's `--resume || --session-id` fallback: a deleted or archived thread
        // must not strand the tab. Re-pinning is the caller's job once this returns.
        XCTAssertNotEqual(binding.conversationID, existing)
        XCTAssertEqual(t.methods, ["thread/read", "thread/start", "thread/name/set"])
    }

    /// A silent app-server says nothing about whether the thread exists, so answering it by
    /// starting a fresh one would re-pin the tab away from the user's real conversation on
    /// nothing more than a slow reply. Only a refusal means "gone".
    func testRebindDoesNotReplaceAThreadItSimplyCouldNotReach() async {
        let adapter = CodexAdapter(rpc: CodexRPC(transport: SilentTransport()), readTimeout: 0.05)
        let session = Session(title: "t", workingDirectory: "/w/a", pinnedConversationID: existing)

        do {
            _ = try await adapter.rebind(for: session, options: .codex(CodexThreadOptions()))
            XCTFail("an unreachable app-server must not be read as a deleted thread")
        } catch {
            XCTAssertEqual(error as? CodexRPCError, .timeout,
                           "`CodexRPC.request` has no deadline of its own; `read` must supply one")
        }
    }

    // MARK: - The reconcile ordering guard

    private func makeRuntime() -> CodexRuntime {
        CodexRuntime(rpc: CodexRPC(transport: SilentTransport()))
    }

    /// The hazard in one line: a `thread/read` issued by the first notification answering
    /// after a second notification has already moved the tab on.
    func testALateReconcileResultIsDroppedWhenANotificationLandedFirst() {
        let runtime = makeRuntime()
        var events: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: existing, transcriptURL: nil)) { events.append($0) }

        let id = existing.uuidString.lowercased()
        runtime.handle(method: "turn/started", params: ["threadId": id])
        runtime.handle(method: "thread/name/updated", params: ["threadId": id, "threadName": "newer"])
        runtime.applyReconciled(title: "stale", activity: .idle, for: existing)

        XCTAssertEqual(events, [.activity(.busy), .title("newer")],
                       "a read that predates the rename must not flick the title back")
    }

    func testAReconcileResultAppliesWhenNothingMovedUnderIt() {
        let runtime = makeRuntime()
        var events: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: existing, transcriptURL: nil)) { events.append($0) }

        let id = existing.uuidString.lowercased()
        runtime.handle(method: "turn/started", params: ["threadId": id])
        runtime.applyReconciled(title: "restored", activity: .idle, for: existing)

        XCTAssertEqual(events, [.activity(.busy), .title("restored"), .activity(.idle)])
    }

    /// The same guard driven the way production drives it: through the injected `reconcile`,
    /// which is `async` while `handle` is not. The gate holds the read open across a
    /// notification, which is exactly the interleaving that cannot be produced by calling
    /// `applyReconciled` directly.
    func testAScheduledReconcileCannotOverwriteANotificationThatBeatItHome() async {
        let runtime = makeRuntime()
        var events: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: existing, transcriptURL: nil)) { events.append($0) }

        var release: (() -> Void)?
        runtime.reconcile = { [weak runtime] id in
            await withCheckedContinuation { continuation in release = { continuation.resume() } }
            runtime?.applyReconciled(title: "stale", activity: .busy, for: id)
        }

        let id = existing.uuidString.lowercased()
        runtime.handle(method: "turn/started", params: ["threadId": id])
        while release == nil { await Task.yield() }
        runtime.handle(method: "turn/completed", params: ["threadId": id])
        release?()
        await Task.yield()

        XCTAssertEqual(events, [.activity(.busy), .activity(.idle), .turnEnded],
                       "the turn ended while the read was in flight; the read must not revive it")
    }

    /// A reconcile answering for an attachment that has since been replaced is stale by
    /// construction: the new attachment reconciles on its own first contact.
    func testAReconcileForAReattachedThreadIsDropped() {
        let runtime = makeRuntime()
        let binding = AgentBinding(conversationID: existing, transcriptURL: nil)
        runtime.attach(binding) { _ in }
        runtime.handle(method: "turn/started", params: ["threadId": existing.uuidString.lowercased()])

        var events: [AgentEvent] = []
        runtime.detach(binding)
        runtime.attach(binding) { events.append($0) }
        runtime.applyReconciled(title: "stale", activity: .idle, for: existing)

        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - Restore

    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    /// Records what would have been typed at the restored tab's shell.
    private final class SpyInjector: TextInjecting {
        var sent: [String] = []
        var returns = 0
        func sendText(_ text: String) { sent.append(text) }
        func sendReturn() { returns += 1 }
        func sendKillLine() {}
        func sendYank() {}
        func readViewport() -> String? { nil }
    }

    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
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

    /// A store holding one restored session, plus the pieces every assertion below reads.
    private func makeRestoredStore(
        agent: AgentID, transport: CodexTransport?, readTimeout: Double = 5
    ) -> (SessionStore, RecordingProvider, SpyInjector, UUID) {
        let tabID = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(
                id: tabID,
                title: "a",
                workingDirectory: "/w/a",
                pinnedConversationID: agent == .codex ? existing : tabID,
                agent: agent,
                transcriptPath: agent == .codex ? "/r/x.jsonl" : nil
            )],
            selectedSessionID: tabID,
            sessionCounter: 1
        )
        let provider = RecordingProvider()
        retained.append(provider)
        let store = SessionStore(provider: provider, persistence: persistence)
        store.projectsRoot = projectsRoot
        store.launchFailureReporter = SilentReporter()
        let injector = SpyInjector()
        store.injectorOverride = injector
        if let transport {
            store.overrideAdapter(
                CodexAdapter(rpc: CodexRPC(transport: transport), readTimeout: readTimeout),
                for: .codex
            )
        }
        return (store, provider, injector, tabID)
    }

    /// Requirement: the restore path settles identity with `thread/read`, never straight off
    /// the pin. `binding(for:)` cannot tell a live thread from a deleted one, and the tab it
    /// produces for a deleted one runs `codex resume` against nothing.
    func testARestoredCodexTabSettlesItsThreadBeforeTypingAnything() async {
        let t = ScriptedTransport()
        let (store, provider, injector, tabID) = makeRestoredStore(agent: .codex, transport: t)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        XCTAssertEqual(provider.configs.last?.initialInput, "",
                       "nothing may be typed at a codex tab before its thread is known to exist")
        await store.codexRestoreTask?.value

        XCTAssertEqual(t.methods, ["thread/read"])
        XCTAssertEqual(injector.sent, ["codex resume \(existing.uuidString.lowercased())"])
        XCTAssertEqual(injector.returns, 1, "a paste alone submits nothing")
        XCTAssertEqual(store.pinnedConversationID(of: tabID), existing)
    }

    func testARestoredCodexTabWhoseThreadIsGoneIsRepinnedToAFreshOne() async {
        let t = ScriptedTransport()
        t.threadMissing = true
        let (store, _, injector, tabID) = makeRestoredStore(agent: .codex, transport: t)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(store.pinnedConversationID(of: tabID), fresh,
                       "a tab whose thread was deleted between launches must follow the new one")
        XCTAssertEqual(injector.sent, ["codex resume \(fresh.uuidString.lowercased())"])
        let session = store.repos.flatMap(\.sessions).first { $0.id == tabID }
        XCTAssertEqual(session?.transcriptPath, "/r/y.jsonl",
                       "the rollout path of the thread that was actually started")
    }

    /// An app-server that cannot be reached must not leave the tab at a bare prompt: not
    /// knowing whether a thread is gone is not the same as knowing it is.
    func testARestoredCodexTabFallsBackToItsPinnedThreadWhenNothingAnswers() async {
        let (store, _, injector, tabID) = makeRestoredStore(
            agent: .codex, transport: SilentTransport(), readTimeout: 0.05
        )

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(store.pinnedConversationID(of: tabID), existing)
        XCTAssertEqual(injector.sent, ["codex resume \(existing.uuidString.lowercased())"])
    }

    /// Requirement: a restored codex tab must actually start the app-server. Without it the
    /// tab's runtime sits on a transport nobody started — no activity, no unread mark —
    /// until some later creation happens to revive the memoized stack.
    func testARestoredCodexTabAsksForTheAppServer() async {
        let (store, _, _, _) = makeRestoredStore(agent: .codex, transport: ScriptedTransport())

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(store.codexServerRequestsForTesting, 1)
    }

    /// The other half of that requirement: lazily. A run that restored no codex tab must not
    /// spawn `codex app-server` behind the user's back.
    func testAClaudeOnlyRestoreNeverAsksForCodex() async {
        let (store, provider, injector, _) = makeRestoredStore(agent: .claude, transport: nil)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(store.codexServerRequestsForTesting, 0)
        XCTAssertFalse(store.hasCodexStackForTesting)
        XCTAssertTrue(injector.sent.isEmpty, "claude's resume text goes in at surface creation")
        XCTAssertNotEqual(provider.configs.last?.initialInput, "",
                          "claude's restore path must be untouched")
    }
}
