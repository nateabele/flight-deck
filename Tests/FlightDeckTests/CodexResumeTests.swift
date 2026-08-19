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
                // codex's ACTUAL answer for a thread with no rollout, probed against
                // codex-cli 0.147.0. This stub used to say `-32602 "no such thread"`, which
                // codex has never sent: every app-server error is `-32600`, and the message
                // names the thread. `CodexAdapter.isThreadGone` keys on the message for
                // exactly that reason, so a stub that invented one proved nothing.
                onLine?(#"{"id":\#(id),"error":{"code":-32600,"message":"thread not loaded: 01a01269-baa6-7493-8d15-8fa21bcb602b"}}"#)
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

    /// The under-narrowing this replaced: `catch CodexRPCError.remote(_, _)` treated every
    /// remote refusal as "the thread is gone" and re-pinned the tab onto a fresh empty
    /// thread — throwing away the pin that was the only record of where the conversation
    /// was. Each message below is one codex really sends.
    func testOnlyANoSuchThreadRefusalCountsAsGone() {
        let id = "01a01269-baa6-7493-8d15-8fa21bcb602b"

        // Observed against a live app-server at codex-cli 0.147.0.
        XCTAssertTrue(CodexAdapter.isThreadGone(message: "thread not loaded: \(id)", threadID: id))
        XCTAssertTrue(CodexAdapter.isThreadGone(
            message: "no rollout found for thread id \(id)", threadID: id))

        // Generic protocol failures. None of these says the thread is gone, and none of them
        // names it — which is exactly what makes the message, not the code, the signal.
        for message in [
            "Invalid request: unknown variant `thread/read`",
            "Invalid request: missing field `threadId`",
            "Method not found",
            "thread is busy and cannot be read right now",
            "thread requires migration before it can be opened",
        ] {
            XCTAssertFalse(CodexAdapter.isThreadGone(message: message, threadID: id),
                           "must propagate rather than re-pin: \(message)")
        }

        // Names a thread, but not ours.
        XCTAssertFalse(CodexAdapter.isThreadGone(
            message: "thread not loaded: 01a01705-bd49-7b70-a0a1-4514d4bda5dd", threadID: id))
    }

    /// End to end through `rebind`: a refusal that is not "gone" must reach the caller so it
    /// can degrade to the thread it already had.
    func testRebindPropagatesARefusalThatDoesNotMeanGone() async {
        final class BusyTransport: CodexTransport {
            var onLine: ((String) -> Void)?
            private(set) var methods: [String] = []
            func send(_ line: String) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
                methods.append(method)
                onLine?(#"{"id":\#(id),"error":{"code":-32600,"message":"thread is busy"}}"#)
            }
        }
        let t = BusyTransport()
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        let session = Session(title: "t", workingDirectory: "/w/a", pinnedConversationID: existing)

        do {
            _ = try await adapter.rebind(for: session, options: .codex(CodexThreadOptions()))
            XCTFail("a busy thread is not a deleted one — re-pinning here is unrecoverable")
        } catch {
            XCTAssertEqual(error as? CodexRPCError, .remote(code: -32600, message: "thread is busy"))
        }
        // The route, not just the error. A transport that refuses everything throws the same
        // error from `thread/start` as from `thread/read`, so asserting only the error would
        // pass against the very under-narrowing this test exists to catch.
        XCTAssertEqual(t.methods, ["thread/read"],
                       "a refusal that does not mean `gone` must never reach thread/start")
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
