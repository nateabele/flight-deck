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
        /// The `ThreadStatus` object `thread/read` answers with, as raw JSON. Configurable
        /// because `read` maps the whole union through `CodexThreadStatus`, and `idle` — the
        /// default the rest of this file relies on — is only one of its four cases.
        var readStatus = #"{"type":"idle"}"#

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            switch method {
            case "thread/read" where threadMissing:
                onLine?(#"{"id":\#(id),"error":{"code":-32602,"message":"no such thread"}}"#)
            case "thread/read":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","name":"restored","status":\#(readStatus),"path":"/r/x.jsonl","cwd":"/w/a"}}}"#)
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

    /// `read` is the second consumer of the status table, and it used to carry its own copy
    /// that answered "anything not `running`/`busy`" with `.idle` — so a thread codex
    /// reported as `active` came back from every reconcile as idle, actively wrong rather
    /// than merely uninformative.
    func testReadMapsTheWholeThreadStatusUnion() async throws {
        let cases: [(String, SessionActivity?)] = [
            (#"{"type":"idle"}"#, .idle),
            (#"{"type":"active","activeFlags":[]}"#, .busy),
            (#"{"type":"active","activeFlags":["waitingOnUserInput"]}"#, .waiting),
            (#"{"type":"systemError"}"#, .idle),
            // Confirmed against a live app-server: `thread/read` on a thread that exists on
            // disk but is not open in this process succeeds with `notLoaded`.
            (#"{"type":"notLoaded"}"#, nil),
        ]
        for (status, expected) in cases {
            let t = ScriptedTransport()
            t.readStatus = status
            let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

            let state = try await adapter.read(
                AgentBinding(conversationID: existing, transcriptURL: nil)
            )

            XCTAssertEqual(state.activity, expected, "status \(status)")
            XCTAssertEqual(state.title, "restored", "the title must survive every status")
        }
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

    /// Holds each reconcile open until the test lets it home, and stamps what it read with
    /// the order it was issued in — which is what makes "the *first* read landed after the
    /// second one was issued" expressible at all.
    /// `@MainActor` explicitly: a nested type does not inherit its enclosing type's
    /// isolation, and a gate that hops actors would race the very ordering it is measuring.
    @MainActor
    private final class ReadGate {
        private var gates: [CheckedContinuation<Void, Never>] = []

        /// Derived from `gates` rather than counted separately, which is load-bearing: a
        /// counter bumped *before* `withCheckedContinuation` lets `waitForReads` return in the
        /// window before the continuation is parked, and `release` then finds nothing.
        var issued: Int { gates.count }

        func hold() async {
            await withCheckedContinuation { gates.append($0) }
        }

        /// Fails rather than traps when the read was never issued: a guard that abandons a
        /// reconcile is a test failure, not a reason to take the whole suite down.
        func release(_ index: Int) {
            guard index < gates.count else { return XCTFail("read \(index + 1) was never issued") }
            gates[index].resume()
        }

        /// Spins the main actor until `count` reads are parked. Bounded so a regression fails
        /// the assertion below rather than hanging the suite.
        func waitForReads(_ count: Int) async {
            var spins = 0
            while issued < count, spins < 10_000 {
                await Task.yield()
                spins += 1
            }
        }
    }

    /// The production wire itself: `reconcileByReading` must issue a real `thread/read` and
    /// deliver what it answers. Every other test here injects its own closure, so without
    /// this one the requirement-4 deliverable — the closure `CodexStack.init` installs —
    /// would have no coverage at all.
    func testTheProductionWireReadsTheThreadAndAppliesWhatItSays() async {
        let t = ScriptedTransport()
        let rpc = CodexRPC(transport: t)
        let runtime = CodexRuntime(rpc: rpc)
        runtime.reconcileByReading(with: CodexAdapter(rpc: rpc))
        var events: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: existing, transcriptURL: nil)) { events.append($0) }

        runtime.handle(method: "turn/started", params: ["threadId": existing.uuidString.lowercased()])
        for _ in 0..<50 where events.count < 3 { await Task.yield() }

        XCTAssertEqual(t.methods, ["thread/read"])
        XCTAssertEqual(events, [.activity(.busy), .title("restored"), .activity(.idle)])
    }

    /// The guard driven the way production drives it: through the injected `reconcile`, which
    /// is `async` while `handle` is not. The gate holds the read open across a notification,
    /// which is the interleaving that genuinely makes a read stale.
    func testAScheduledReconcileCannotOverwriteANotificationThatBeatItHome() async {
        let runtime = makeRuntime()
        var events: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: existing, transcriptURL: nil)) { events.append($0) }
        let gate = ReadGate()
        runtime.reconcile = { [weak runtime] id in
            await gate.hold()
            runtime?.applyReconciled(title: "stale", activity: .busy, for: id)
        }

        let id = existing.uuidString.lowercased()
        runtime.handle(method: "turn/started", params: ["threadId": id])
        await gate.waitForReads(1)
        runtime.handle(method: "turn/completed", params: ["threadId": id])
        gate.release(0)
        await Task.yield()

        XCTAssertEqual(events, [.activity(.busy), .activity(.idle), .turnEnded],
                       "the turn ended while the read was in flight; the read must not revive it")
    }

    /// `CodexProcessTransport` delivers every line of one pipe chunk in a single synchronous
    /// loop, so first contact is routinely a *burst* — and the whole burst lands before the
    /// scheduled `Task` has issued anything. None of it can make a read stale: the read has
    /// not been sent yet, and codex answers it with everything those notifications reported.
    /// Invalidating on them drops the reconcile deterministically for the ordinary shape of a
    /// turn, which is exactly the case it exists to serve.
    func testAFirstContactBurstDoesNotDropTheReconcileItScheduled() async {
        let runtime = makeRuntime()
        var events: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: existing, transcriptURL: nil)) { events.append($0) }
        let gate = ReadGate()
        runtime.reconcile = { [weak runtime] id in
            await gate.hold()
            runtime?.applyReconciled(title: "read", activity: nil, for: id)
        }

        let id = existing.uuidString.lowercased()
        // One chunk, delivered synchronously: a turn beginning, an item that maps to nothing,
        // and a rename. The `Task` cannot have run yet.
        runtime.handle(method: "turn/started", params: ["threadId": id])
        runtime.handle(method: "item/started", params: ["threadId": id, "item": ["type": "assistantMessage"]])
        runtime.handle(method: "thread/name/updated", params: ["threadId": id, "threadName": "burst"])
        await gate.waitForReads(1)
        gate.release(0)
        await Task.yield()

        XCTAssertEqual(events, [.activity(.busy), .title("burst"), .title("read")],
                       "nothing that arrived before the read was issued can have made it stale")
    }

    /// A notification that maps to no events changed nothing, so it cannot invalidate a read
    /// in flight either.
    func testANotificationThatChangesNothingDoesNotInvalidateAReadInFlight() async {
        let runtime = makeRuntime()
        var events: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: existing, transcriptURL: nil)) { events.append($0) }
        let gate = ReadGate()
        runtime.reconcile = { [weak runtime] id in
            await gate.hold()
            runtime?.applyReconciled(title: "read", activity: nil, for: id)
        }

        let id = existing.uuidString.lowercased()
        runtime.handle(method: "turn/started", params: ["threadId": id])
        await gate.waitForReads(1)
        // An unrecognised status maps to `[]` — see `CodexEventMapper.activity(forThreadStatus:)`.
        runtime.handle(method: "thread/status/changed",
                       params: ["threadId": id, "status": ["type": "somethingNew"]])
        gate.release(0)
        await Task.yield()

        XCTAssertEqual(events, [.activity(.busy), .title("read")])
    }

    /// A read that was overtaken is retried on the next notification rather than abandoned
    /// for the life of the attachment.
    func testAnOvertakenReconcileIsRetriedRatherThanAbandoned() async {
        let runtime = makeRuntime()
        var events: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: existing, transcriptURL: nil)) { events.append($0) }
        let gate = ReadGate()
        runtime.reconcile = { [weak runtime] id in
            let attempt = gate.issued + 1
            await gate.hold()
            runtime?.applyReconciled(title: "read\(attempt)", activity: nil, for: id)
        }

        let id = existing.uuidString.lowercased()
        runtime.handle(method: "turn/started", params: ["threadId": id])
        await gate.waitForReads(1)
        runtime.handle(method: "thread/name/updated", params: ["threadId": id, "threadName": "live"])
        gate.release(0)                     // dropped: overtaken by the rename
        await Task.yield()
        runtime.handle(method: "turn/completed", params: ["threadId": id])
        await gate.waitForReads(2)
        gate.release(1)
        await Task.yield()

        XCTAssertFalse(events.contains(.title("read1")), "the overtaken read must not land")
        XCTAssertEqual(events.last, .title("read2"), "but the tab must still get reconciled")
    }

    /// A reconcile answering for an attachment that has since been replaced is stale by
    /// construction, however far the replacement's own counter has got. Latent today — no
    /// codex path detaches and re-attaches one conversation id — but this is the exact
    /// failure class the guard exists to remove, so it is closed by identity rather than by
    /// counting.
    func testAReconcileForAReattachedThreadIsDropped() async {
        let runtime = makeRuntime()
        let binding = AgentBinding(conversationID: existing, transcriptURL: nil)
        let gate = ReadGate()
        runtime.reconcile = { [weak runtime] id in
            let attempt = gate.issued + 1
            await gate.hold()
            runtime?.applyReconciled(title: "read\(attempt)", activity: nil, for: id)
        }
        let id = existing.uuidString.lowercased()

        runtime.attach(binding) { _ in }
        runtime.handle(method: "turn/started", params: ["threadId": id])
        await gate.waitForReads(1)

        var events: [AgentEvent] = []
        runtime.detach(binding)
        runtime.attach(binding) { events.append($0) }
        runtime.handle(method: "turn/started", params: ["threadId": id])
        await gate.waitForReads(2)

        gate.release(0)                     // the replaced attachment's read comes home
        await Task.yield()
        gate.release(1)
        await Task.yield()

        XCTAssertEqual(events, [.activity(.busy), .title("read2")],
                       "a counter that restarts at attach must not let read1 match read2's slot")
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
