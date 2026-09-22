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
        /// `thread/list` results, as raw entries, keyed by the `cwd` asked about — the shape
        /// `CodexAdapter.threads` decodes. Empty by default, which is what every test written
        /// before the reconcile pass moved in front of the sends assumes: a directory codex
        /// reports no threads for leaves every pin exactly where it is.
        var threads: [String: [[String: Any]]] = [:]
        /// Every `cwd` a `thread/list` carried, in order and unmodified. `thread/list` matches
        /// `cwd` as an exact string, so a normalised path is a silent no-op that looks just
        /// like "no threads here".
        private(set) var listed: [String] = []
        /// Answers `thread/list` with codex's own error shape instead of a result. "Could not
        /// ask" is not "asked, and there are none": a reconcile pass that cannot reach the
        /// app-server must leave every pin in the group exactly where it is.
        var listFails = false

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            let params = obj["params"] as? [String: Any]
            switch method {
            case "thread/read" where threadMissing:
                // codex's ACTUAL answer for a thread with no rollout, probed against
                // codex-cli 0.147.0. This stub used to say `-32602 "no such thread"`, which
                // codex has never sent: every app-server error is `-32600`, and the message
                // names the thread. `CodexAdapter.isThreadGone` keys on the message for
                // exactly that reason, so a stub that invented one proved nothing.
                //
                // The id is echoed from the request rather than hard-coded, because that is
                // the half of the signal `isThreadGone` actually keys on: it requires the
                // message to name the thread *it asked about*. A canned id answers "gone" for
                // one fixture thread and "some unrelated remote error" for every other one,
                // which silently disables the gone-path for any test that re-pins first.
                let asked = params?["threadId"] as? String ?? ""
                onLine?(#"{"id":\#(id),"error":{"code":-32600,"message":"thread not loaded: \#(asked)"}}"#)
            case "thread/list":
                let cwd = params?["cwd"] as? String ?? ""
                listed.append(cwd)
                guard !listFails else {
                    onLine?(#"{"id":\#(id),"error":{"code":-32600,"message":"app-server is gone"}}"#)
                    return
                }
                let body: [String: Any] = ["id": id, "result": ["data": threads[cwd] ?? []]]
                guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
                onLine?(String(decoding: data, as: UTF8.self))
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

    /// The live case the reconcile-before-send restructure was diagnosed from, replayed as a
    /// fixture: a tab pinned to a thread Flight Deck created and nobody ever took a turn in,
    /// in a directory whose newest thread is the conversation the user is really having. The
    /// id prefixes and the directory are the real ones from `~/.codex/state_5.sqlite`; the
    /// uuid tails are synthetic, because only the `updatedAt` ordering decides anything.
    private let stalePin = UUID(uuidString: "01a07927-0000-7000-8000-000000000001")!
    private let liveThread = UUID(uuidString: "01a0878d-0000-7000-8000-000000000002")!
    private let otherPin = UUID(uuidString: "01a0878d-0000-7000-8000-000000000003")!
    private let liveDirectory = "/Users/nate/Projects/Startups/Field/ogolvy-app"

    // MARK: - The adapter

    func testReadReturnsTheAuthoritativeTitleAndStatus() async throws {
        let t = ScriptedTransport()
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

        let state = try await adapter.read(AgentBinding(conversationID: existing, transcriptURL: nil))

        // This is what `rebind` reads on every restore, and what `resumeRestoredCodex`
        // applies as a tab's title for a rename made while Flight Deck was closed — the
        // one gap tailing `session_index.jsonl` can't cover, since it starts at end-of-file.
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

    // MARK: - prepare / the writer-lock release

    /// The whole point of the fix: `thread/archive` and `thread/unarchive` must follow
    /// `thread/name/set`, in that exact order — archiving before naming would fail (an
    /// unnamed thread has no rollout to archive, under the `legacy` history contract
    /// `CodexAdapter` pins), and unarchiving before archiving is meaningless. See the
    /// comment at the call site in `CodexAdapter.prepare` for why the round trip exists at
    /// all: it releases the writer lock `thread/start` takes out, which otherwise makes
    /// `codex resume <id>` refuse on codex-cli 0.148.0 (re-verified on 0.151.0).
    func testPrepareArchivesAndUnarchivesTheThreadAfterNamingIt() async throws {
        let t = ScriptedTransport()
        // The fixture's `thread["path"]` (`/r/y.jsonl`) does not exist on disk, so this must
        // be stubbed true rather than left at the production default — see `CodexAdapter`'s
        // history-contract check in `prepare`.
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t), rolloutExists: { _ in true })
        let session = Session(title: "t", workingDirectory: "/w/a", pinnedConversationID: existing)

        let binding = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))

        XCTAssertEqual(binding.conversationID, fresh)
        XCTAssertEqual(t.methods, ["thread/start", "thread/name/set", "thread/archive", "thread/unarchive"])
    }

    /// The ordering hazard the fix has to get right: if `thread/archive` succeeds and
    /// `thread/unarchive` then fails, the thread is left archived — worse than the writer
    /// lock this round trip exists to release, because codex refuses to resume an archived
    /// thread outright ("session is archived. Run `codex unarchive <id>`"). `prepare` must
    /// propagate that failure rather than swallow it and return a binding that looks fine,
    /// exactly the same reasoning that already governs a failed `thread/name/set`.
    func testPrepareFailsRatherThanReturnAThreadItLeftArchived() async {
        final class UnarchiveFailsTransport: CodexTransport {
            var onLine: ((String) -> Void)?
            private(set) var methods: [String] = []
            func send(_ line: String) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
                methods.append(method)
                switch method {
                case "thread/start":
                    onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01705-bd49-7b70-a0a1-4514d4bda5dd","cwd":"/w/a","path":"/r/y.jsonl"}}}"#)
                case "thread/unarchive":
                    onLine?(#"{"id":\#(id),"error":{"code":-32600,"message":"internal error"}}"#)
                default:
                    onLine?(#"{"id":\#(id),"result":{}}"#)
                }
            }
        }
        let t = UnarchiveFailsTransport()
        // Stubbed true for the same reason as the fixture above: `/r/y.jsonl` does not exist
        // on disk, and this test's failure must come from the unarchive refusal below, not
        // from the earlier history-contract check.
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t), rolloutExists: { _ in true })
        let session = Session(title: "t", workingDirectory: "/w/a", pinnedConversationID: existing)

        do {
            _ = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))
            XCTFail("a thread left archived by a failed unarchive must not be handed back as a usable binding")
        } catch {
            XCTAssertEqual(error as? CodexRPCError, .remote(code: -32600, message: "internal error"))
        }
        // Both were attempted, in order, before the failure reached the caller — proof this
        // is the ordering hazard the comment describes, not some earlier request failing.
        XCTAssertEqual(t.methods, ["thread/start", "thread/name/set", "thread/archive", "thread/unarchive"])
    }

    func testRebindStartsAFreshThreadWhenTheOldOneIsGone() async throws {
        let t = ScriptedTransport()
        t.threadMissing = true
        // Stubbed true: this exercises `rebind`'s recovery `prepare` call, whose fixture
        // path (`/r/y.jsonl`) does not exist on disk.
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t), rolloutExists: { _ in true })
        let session = Session(title: "t", workingDirectory: "/w/a", pinnedConversationID: existing)

        let binding = try await adapter.rebind(for: session, options: .codex(CodexThreadOptions()))

        // Mirrors claude's `--resume || --session-id` fallback: a deleted or archived thread
        // must not strand the tab. Re-pinning is the caller's job once this returns.
        XCTAssertNotEqual(binding.conversationID, existing)
        XCTAssertEqual(t.methods,
                       ["thread/read", "thread/start", "thread/name/set", "thread/archive", "thread/unarchive"])
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
        var defaultFontSize: Float { 12 }
    }

    /// Records what would have been typed at the restored tab's shell.
    private final class SpyInjector: TextInjecting {
        var sent: [String] = []
        var returns = 0
        func sendText(_ text: String) { sent.append(text) }
        func sendReturn() { returns += 1 }
        func sendKillLine() {}
        func sendYank() {}
        func sendArrowDown() {}
        func sendArrowUp() {}
        func sendEscape() {}
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
        let (store, provider, injector) = makeStore(
            entries: [.init(
                id: tabID,
                title: "a",
                workingDirectory: "/w/a",
                pinnedConversationID: agent == .codex ? existing : tabID,
                agent: agent,
                transcriptPath: agent == .codex ? "/r/x.jsonl" : nil
            )],
            transport: transport,
            readTimeout: readTimeout
        )
        return (store, provider, injector, tabID)
    }

    /// The same store, over an arbitrary set of restored tabs.
    ///
    /// Split out of `makeRestoredStore` for the reconcile-before-send cases below, whose
    /// fixtures need a pin, a directory or a second tab of their own — the one canned session
    /// that helper builds cannot express any of them.
    private func makeStore(
        entries: [SessionSnapshot.Entry], transport: CodexTransport?, readTimeout: Double = 5
    ) -> (SessionStore, RecordingProvider, SpyInjector) {
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: entries,
            selectedSessionID: entries.first?.id,
            sessionCounter: entries.count
        )
        let provider = RecordingProvider()
        retained.append(provider)
        let store = SessionStore(provider: provider, persistence: persistence)
        store.transcriptsRootOverride = projectsRoot
        // Never the user's real `~/.codex/session_index.jsonl`: restoring a codex session
        // below builds a real `CodexStack`, whose `CodexNameWatcher` would otherwise tail it.
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.launchFailureReporter = SilentReporter()
        let injector = SpyInjector()
        store.injectorOverride = injector
        if let transport {
            store.overrideAdapter(
                // Stubbed true: the restore-then-gone test below drives `rebind`'s recovery
                // `prepare` call, whose fixture path does not exist on disk.
                CodexAdapter(
                    rpc: CodexRPC(transport: transport), readTimeout: readTimeout,
                    rolloutExists: { _ in true }
                ),
                // No `PreferencesStore` on this store, so every tab resolves to the nil
                // account — the key the restore path will look this up under.
                for: .codex, account: nil
            )
        }
        return (store, provider, injector)
    }

    /// One restored codex tab, in the shape the snapshot stores it.
    private func codexEntry(
        _ id: UUID, pinned: UUID, directory: String = "/w/a", path: String = "/r/x.jsonl"
    ) -> SessionSnapshot.Entry {
        .init(
            id: id, title: "a", workingDirectory: directory, pinnedConversationID: pinned,
            agent: .codex, transcriptPath: path
        )
    }

    /// One `thread/list` entry, in the shape `CodexAdapter.threads` decodes.
    private func entry(_ id: UUID, updatedAt: Int, path: String? = "/r/live.jsonl") -> [String: Any] {
        var raw: [String: Any] = ["id": id.uuidString.lowercased(), "updatedAt": updatedAt]
        if let path { raw["path"] = path }
        return raw
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

        // A `thread/list` and then two reads, in that order. The reconcile pass runs *before*
        // anything is bound or typed, so the two reads that follow it — `rebind` settling
        // identity, then the follow-up read that recovers a title changed while Flight Deck
        // was closed — see a pin that is already current. Typing first and reconciling
        // afterwards is the defect this ordering exists to close: it left the terminal on a
        // thread the store had already moved off. See `SessionStore.reconcileCodexPins`.
        XCTAssertEqual(t.methods, ["thread/list", "thread/read", "thread/read"])
        XCTAssertEqual(injector.sent, ["codex resume \(existing.uuidString.lowercased())"])
        XCTAssertEqual(injector.returns, 1, "a paste alone submits nothing")
        XCTAssertEqual(store.pinnedConversationID(of: tabID), existing)
    }

    /// Requirement (item 1 of the final fix wave): a rename made while Flight Deck was
    /// closed is invisible to both watchers — they start at end-of-file — so nothing but
    /// this follow-up read can recover it. Without applying it, this test fails: the tab
    /// keeps the stale title `"a"` from the snapshot forever.
    func testARestoredCodexTabRecoversATitleChangedWhileItWasClosed() async {
        let t = ScriptedTransport()
        let (store, _, _, tabID) = makeRestoredStore(agent: .codex, transport: t)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(store.title(of: tabID), "restored",
                       "the title `thread/read` reports must reach the tab on restore, the "
                       + "same way a live rename would")
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

    // MARK: - Reconcile before the command is typed

    /// **The defect this ordering closes.** `codex resume <id>` is not broken — codex attaches
    /// to exactly the thread it is given. What was broken is which id a relaunch handed it.
    /// `rebind` only asks whether the *pinned* thread still exists, never whether it is still
    /// the thread the user works in, so a pin left behind by a previous run survives it
    /// untouched and gets typed at the shell. The pass that knows better used to run after the
    /// loop, which left the store, the watcher, the title and the phone all on the right
    /// thread while the terminal sat on the wrong one — an empty TUI, because Flight Deck
    /// creates its pinned thread itself in `prepare` and it is empty by construction.
    ///
    /// Replays the live case: three separate TUI processes resumed `01a07927` (0 tokens since
    /// creation) and were switched by hand to a real thread, the last of them 1 h 48 m later.
    /// Against the pre-fix ordering this test names `01a07927` — that assertion is the bug.
    func testARestoredCodexTabResumesTheThreadTheUserIsActuallyDriving() async {
        let t = ScriptedTransport()
        t.threads[liveDirectory] = [
            entry(liveThread, updatedAt: 2_000, path: "/r/live.jsonl"),
            entry(stalePin, updatedAt: 1_000, path: "/r/stale.jsonl"),
        ]
        let tabID = UUID()
        let (store, _, injector) = makeStore(
            entries: [codexEntry(
                tabID, pinned: stalePin, directory: liveDirectory, path: "/r/stale.jsonl"
            )],
            transport: t
        )

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(injector.sent, ["codex resume \(liveThread.uuidString.lowercased())"],
                       "the command must name the thread the reconcile pass settled on, not "
                       + "the pin it was settled from")
        XCTAssertEqual(store.pinnedConversationID(of: tabID), liveThread,
                       "the terminal and the record must land on the same thread")
        XCTAssertEqual(t.listed, [liveDirectory],
                       "the directory goes on the wire verbatim: `thread/list` matches `cwd` "
                       + "as an exact string and answers a normalised one with an empty array")
    }

    /// The other half of the rule: a pin that is already the newest thread in its directory is
    /// left exactly where it is. The record's own rollout path differs from the one the
    /// listing reports for the same thread, so a re-pin — which rewrites that path — is
    /// distinguishable from having correctly done nothing.
    func testARestoredCodexTabWhosePinIsAlreadyCurrentIsTypedThatPin() async {
        let t = ScriptedTransport()
        t.threads["/w/a"] = [entry(existing, updatedAt: 2_000, path: "/r/live.jsonl")]
        let (store, _, injector, tabID) = makeRestoredStore(agent: .codex, transport: t)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(injector.sent, ["codex resume \(existing.uuidString.lowercased())"])
        XCTAssertEqual(store.pinnedConversationID(of: tabID), existing)
        let session = store.repos.flatMap(\.sessions).first { $0.id == tabID }
        XCTAssertEqual(session?.transcriptPath, "/r/x.jsonl",
                       "no re-pin happened: `repinCodex` would have rewritten this to the "
                       + "path the listing reported")
    }

    /// The degraded path. An app-server that will not answer says nothing about this
    /// directory's threads, so the pass leaves the pin alone and the tab is still typed at —
    /// not knowing whether a thread has moved is not the same as knowing it has. The listing
    /// is stocked with a newer thread that would win outright, so what refuses it is the
    /// failure itself rather than an empty answer.
    ///
    /// The sibling case where `preparedAdapter` *throws* — a real `startCodex()` failure,
    /// which no store here can produce because `overrideAdapter` answers first — is covered by
    /// `CodexIntegrationTests.testARestoredCodexTabReattachesAfterAStartCodexFailure`,
    /// including the `stopWatching`/`startWatching` re-attach that goes with it.
    func testAReconcilePassThatCannotAskLeavesThePinAndStillTypesIt() async {
        let t = ScriptedTransport()
        t.listFails = true
        t.threads["/w/a"] = [entry(liveThread, updatedAt: 2_000, path: "/r/live.jsonl")]
        let (store, _, injector, tabID) = makeRestoredStore(agent: .codex, transport: t)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(injector.sent, ["codex resume \(existing.uuidString.lowercased())"],
                       "a restore that cannot reach the app-server must still produce a "
                       + "usable tab, on the thread it already had")
        XCTAssertEqual(store.pinnedConversationID(of: tabID), existing)
    }

    /// A thread that was deleted between launches still ends on the replacement `prepare`
    /// started, and nothing moves it afterwards.
    ///
    /// Exactly one `thread/list`: the pass that used to trail the loop is gone. Removing it is
    /// safe precisely here, on the only path where stage 3 can still change a pin — a second
    /// pass would find that replacement is the newest thread in the directory *and* already in
    /// `codexThreadsEverPinned`, so it would re-select nothing and stop. The 5 s ticker covers
    /// everything after restore.
    func testAGoneThreadEndsOnItsReplacementWithNoSecondReconcilePass() async {
        let t = ScriptedTransport()
        t.threadMissing = true
        t.threads["/w/a"] = [entry(liveThread, updatedAt: 2_000, path: "/r/live.jsonl")]
        let (store, _, injector, tabID) = makeRestoredStore(agent: .codex, transport: t)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(store.pinnedConversationID(of: tabID), fresh,
                       "the pass re-pins onto the directory's newest thread, `rebind` finds "
                       + "that one gone too, and `prepare`'s replacement is what survives")
        XCTAssertEqual(injector.sent, ["codex resume \(fresh.uuidString.lowercased())"])
        XCTAssertEqual(t.methods.filter { $0 == "thread/list" }.count, 1,
                       "one reconcile pass per restore, in front of the sends — never a "
                       + "second one behind them")
    }

    /// Two live codex tabs in one directory: `thread/list` reports the directory's threads,
    /// not which tab is driving which, so a newly appeared thread cannot be attributed to
    /// either of them and the group is skipped whole. Both tabs are still typed at, each with
    /// its own pin. Guessing wrong here would re-pin a tab away from the user's real
    /// conversation, and the pin is the only record of where that conversation was.
    func testTwoCodexTabsInOneDirectoryAreEachTypedTheirOwnPin() async {
        let t = ScriptedTransport()
        t.threads["/w/a"] = [entry(liveThread, updatedAt: 9_000, path: "/r/live.jsonl")]
        let first = UUID()
        let second = UUID()
        let (store, _, injector) = makeStore(
            entries: [
                codexEntry(first, pinned: stalePin, path: "/r/one.jsonl"),
                codexEntry(second, pinned: otherPin, path: "/r/two.jsonl"),
            ],
            transport: t
        )

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))
        await store.codexRestoreTask?.value

        XCTAssertEqual(injector.sent, [
            "codex resume \(stalePin.uuidString.lowercased())",
            "codex resume \(otherPin.uuidString.lowercased())",
        ])
        XCTAssertEqual(store.pinnedConversationID(of: first), stalePin)
        XCTAssertEqual(store.pinnedConversationID(of: second), otherPin)
    }
}
