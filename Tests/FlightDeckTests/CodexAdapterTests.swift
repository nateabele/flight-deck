import XCTest
@testable import FlightDeck

@MainActor
final class CodexAdapterTests: XCTestCase {
    /// Records the call order and answers each method with a canned result.
    final class ScriptedTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        var threadID = "01a01269-baa6-7493-8d15-8fa21bcb602b"
        var failNameSet = false

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(
                with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String else { return }
            methods.append(method)
            guard let id = obj["id"] as? Int else { return }
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"\#(threadID)","cwd":"/w/a","path":"/r/\#(threadID).jsonl"}}}"#)
            case "thread/name/set":
                onLine?(failNameSet
                    ? #"{"id":\#(id),"error":{"code":-32000,"message":"boom"}}"#
                    : #"{"id":\#(id),"result":{}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    /// Answers `thread/start` with a `thread` object that carries no `path` at all — the
    /// "unusable path" case, distinct from a path that is present but whose file
    /// `rolloutExists` reports missing. Kept separate from `ScriptedTransport` because that
    /// one always emits `path`.
    private final class PathlessTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            switch method {
            case "thread/start":
                onLine?(#"{"id":\#(id),"result":{"thread":{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b"}}}"#)
            default:
                onLine?(#"{"id":\#(id),"result":{}}"#)
            }
        }
    }

    /// Answers `thread/list` with a scripted `data` array (or a scripted error), and records
    /// the params it was sent so the request-shape test can assert on them directly. Kept
    /// separate from `ScriptedTransport`, which has no `thread/list` case of its own and
    /// whose existing scripts are about `thread/start`'s sequence, not this one's.
    private final class ThreadListTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        private(set) var methods: [String] = []
        private(set) var lastParams: [String: Any]?
        /// Raw JSON for the `data` array codex would answer with — set per test.
        var data = "[]"
        /// When set, `thread/list` answers with this error instead of a result.
        var error: (code: Int, message: String)?

        func send(_ line: String) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = obj["method"] as? String, let id = obj["id"] as? Int else { return }
            methods.append(method)
            lastParams = obj["params"] as? [String: Any]
            if let error {
                onLine?(#"{"id":\#(id),"error":{"code":\#(error.code),"message":"\#(error.message)"}}"#)
            } else {
                onLine?(#"{"id":\#(id),"result":{"data":\#(data),"nextCursor":null,"backwardsCursor":null}}"#)
            }
        }
    }

    private func makeAdapter() -> (CodexAdapter, ScriptedTransport) {
        let t = ScriptedTransport()
        // Every fixture's `thread["path"]` is a fake, non-existent path (`/r/<id>.jsonl`), so
        // the production `rolloutExists` default would fail every one of these tests the
        // moment `prepare`'s history-contract check exists. Stubbed true here rather than
        // weakening the four-call-sequence assertions the tests below depend on.
        return (CodexAdapter(rpc: CodexRPC(transport: t), rolloutExists: { _ in true }), t)
    }

    func testPrepareStartsThenNamesTheThread() async throws {
        let (adapter, t) = makeAdapter()
        let session = Session(title: "my tab", workingDirectory: "/w/a")

        let binding = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))

        // Order is load-bearing: thread/start alone does NOT persist the thread, so naming
        // it is what commits it — under the `legacy` history contract `CodexAdapter`
        // pins. Reversing these leaves a thread codex cannot resume.
        // The archive/unarchive pair that follows releases the writer lock `thread/start`
        // takes out — see the comment at that call site in `CodexAdapter.prepare` — and
        // must come after naming (archiving an unnamed thread has no rollout to archive)
        // and in that internal order (unarchiving before archiving is meaningless).
        XCTAssertEqual(t.methods, ["thread/start", "thread/name/set", "thread/archive", "thread/unarchive"])
        XCTAssertEqual(binding.conversationID.uuidString.lowercased(), t.threadID)
        XCTAssertEqual(binding.transcriptURL?.path, "/r/\(t.threadID).jsonl")
    }

    func testPrepareFailsWhenTheThreadCannotBeCommitted() async {
        let (adapter, t) = makeAdapter()
        t.failNameSet = true
        let session = Session(title: "my tab", workingDirectory: "/w/a")

        do {
            _ = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))
            XCTFail("an uncommitted thread must not be handed back — `codex resume` would fail on it")
        } catch {}
    }

    /// The diagnostic added for the paginated-history breakage: a missing rollout must
    /// surface as `AgentLaunchError.prepareFailed`, naming the real cause, rather than as
    /// codex's own raw `-32600 no rollout found for thread id <id>` — which is exactly what
    /// `thread/archive` would answer with if this check did not exist.
    func testPrepareDiagnosesAMissingRolloutRatherThanLettingCodexsRawErrorSurface() async {
        let t = ScriptedTransport()
        var adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        adapter.rolloutExists = { _ in false }
        let session = Session(title: "my tab", workingDirectory: "/w/a")

        do {
            _ = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))
            XCTFail("a thread whose rollout never appeared is not resumable")
        } catch AgentLaunchError.prepareFailed {
            // expected — codex's own error must not reach the caller here.
        } catch {
            XCTFail("expected AgentLaunchError.prepareFailed, not codex's raw \(error)")
        }
        // The check sits between naming and archiving, so a missing rollout must be caught
        // before `thread/archive` runs — never surfaced as that call's own failure, and
        // never fired before `thread/name/set` either (that would trip on every healthy
        // thread, per the comment at the check's call site).
        XCTAssertEqual(t.methods, ["thread/start", "thread/name/set"],
                       "the missing-rollout check must fire before thread/archive, not after")
    }

    /// `historyMode == nil` means this codex predates the pin and was sent nothing — a
    /// materially different situation from the case below, so the message must say so.
    func testPrepareMissingRolloutMessageNamesTheUnpinnedCodexWhenHistoryModeIsNil() async {
        let t = ScriptedTransport()
        var adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        adapter.rolloutExists = { _ in false }
        adapter.historyMode = nil
        let session = Session(title: "my tab", workingDirectory: "/w/a")

        do {
            _ = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))
            XCTFail("expected prepareFailed")
        } catch AgentLaunchError.prepareFailed(let why) {
            XCTAssertTrue(why.contains("no history-mode pin"),
                          "the nil-historyMode branch must say Flight Deck sent nothing: \(why)")
        } catch {
            XCTFail("expected AgentLaunchError.prepareFailed, got \(error)")
        }
    }

    /// `historyMode == "legacy"` means Flight Deck asked for the legacy contract and codex
    /// still did not honor it — more alarming than the nil case, and the message must differ.
    func testPrepareMissingRolloutMessageNamesTheBrokenPinWhenHistoryModeIsLegacy() async {
        let t = ScriptedTransport()
        var adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        adapter.rolloutExists = { _ in false }
        adapter.historyMode = "legacy"
        let session = Session(title: "my tab", workingDirectory: "/w/a")

        do {
            _ = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))
            XCTFail("expected prepareFailed")
        } catch AgentLaunchError.prepareFailed(let why) {
            XCTAssertTrue(why.contains("legacy history contract"),
                          "the legacy-historyMode branch must say Flight Deck asked and was "
                          + "refused, not that nothing was sent: \(why)")
        } catch {
            XCTFail("expected AgentLaunchError.prepareFailed, got \(error)")
        }
    }

    /// The seam's own default path: when the rollout genuinely exists, the check must be
    /// invisible — the full four-call sequence still runs and `prepare` still succeeds.
    func testPrepareSucceedsWithTheFullSequenceWhenTheRolloutExists() async throws {
        let t = ScriptedTransport()
        var adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        adapter.rolloutExists = { _ in true }
        let session = Session(title: "my tab", workingDirectory: "/w/a")

        _ = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))

        XCTAssertEqual(t.methods, ["thread/start", "thread/name/set", "thread/archive", "thread/unarchive"])
    }

    /// Pins the SEAM'S OWN default, not a stub of it — the only thing standing between
    /// `prepare`'s history-contract check and always-true. Every other test in this file
    /// (deliberately) overrides `rolloutExists`, and `CodexIntegrationTests`'s coverage of the
    /// real default needs a live codex and skips without one, so this is the only place in the
    /// hermetic suite that would catch the production closure being replaced with
    /// `{ _ in true }`. Exercised directly against `rolloutExists` rather than through
    /// `prepare`, because `prepare` has no other vantage point to observe it from.
    func testTheProductionRolloutExistsDefaultChecksTheRealFilesystem() throws {
        let adapter = CodexAdapter(rpc: CodexRPC(transport: ScriptedTransport()))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let real = dir.appendingPathComponent("codex-adapter-rollout-\(UUID().uuidString).jsonl")
        let missing = dir.appendingPathComponent("codex-adapter-rollout-\(UUID().uuidString).jsonl")
        try Data("{}".utf8).write(to: real)
        defer { try? FileManager.default.removeItem(at: real) }

        XCTAssertTrue(adapter.rolloutExists(real),
                      "a rollout actually written to disk must read as present")
        XCTAssertFalse(adapter.rolloutExists(missing),
                       "a sibling path nothing ever wrote must read as absent, not present")
    }

    /// The other half of "absent or unusable": a `thread/start` result
    /// whose `thread` object carries no `path` key at all, as opposed to a `path` that is
    /// present but whose rollout `rolloutExists` reports missing (the case above). Written so
    /// that rewriting the guard as `thread["path"] as? String ?? ""` would fail this test.
    func testPrepareDiagnosesAThreadStartResultWithNoRolloutPathAtAll() async {
        let t = PathlessTransport()
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))
        let session = Session(title: "my tab", workingDirectory: "/w/a")

        do {
            _ = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))
            XCTFail("a thread whose rollout path codex never named is not resumable")
        } catch AgentLaunchError.prepareFailed {
            // expected — codex's own error must not reach the caller here.
        } catch {
            XCTFail("expected AgentLaunchError.prepareFailed, not codex's raw \(error)")
        }
        XCTAssertEqual(t.methods, ["thread/start", "thread/name/set"],
                       "an absent path must be caught before thread/archive runs, same as a "
                       + "path whose rollout does not exist")
    }

    func testLaunchCommandResumesTheBoundThread() async throws {
        let (adapter, t) = makeAdapter()
        let session = Session(title: "my tab", workingDirectory: "/w/a")
        let binding = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))

        XCTAssertEqual(
            adapter.launchCommand(binding, session, .codex(CodexThreadOptions())),
            "codex resume \(t.threadID)\n"
        )
    }

    func testRenameSendsThreadNameSet() async throws {
        let (adapter, t) = makeAdapter()
        let session = Session(title: "t", workingDirectory: "/w/a")
        let binding = try await adapter.prepare(for: session, options: .codex(CodexThreadOptions()))

        try await adapter.rename(binding, to: "renamed")

        XCTAssertEqual(t.methods.last, "thread/name/set",
                       "rename is a request, not text typed into a pty")
    }

    func testBindingForReadsTheAlreadySettledIdentity() {
        // `binding(for:)` is synchronous and codex cannot mint an id locally — the only
        // case it serves is a tab whose identity is already settled (restored from a
        // snapshot), so it must read straight off the session rather than call the RPC.
        let (adapter, t) = makeAdapter()
        let id = UUID()
        let session = Session(
            id: UUID(), title: "t", workingDirectory: "/w/a",
            pinnedConversationID: id, agent: .codex, transcriptPath: "/r/restored.jsonl"
        )

        let binding = adapter.binding(for: session)

        XCTAssertEqual(binding.conversationID, id)
        XCTAssertEqual(binding.transcriptURL?.path, "/r/restored.jsonl")
        XCTAssertTrue(t.methods.isEmpty, "binding(for:) must not talk to the app-server")
    }

    func testAsThreadStartParamsOmitsNilKeysRatherThanSendingNulls() {
        // An explicit null would pin the value in the JSON-RPC call and defeat the user's
        // own config.toml defaults, so unset fields must be absent, not null.
        let bare = CodexThreadOptions().asThreadStartParams(cwd: "/w/a", historyMode: nil)

        XCTAssertEqual(bare["cwd"] as? String, "/w/a")
        XCTAssertNil(bare["model"])
        XCTAssertNil(bare["sandbox"])
        XCTAssertNil(bare["approvalPolicy"])
        XCTAssertNil(bare["addDirs"])
        XCTAssertNil(bare["historyMode"])
        XCTAssertEqual(bare.count, 1)
    }

    func testAsThreadStartParamsIncludesEverySetField() {
        let full = CodexThreadOptions(
            model: "gpt-5-codex", sandbox: "workspace-write",
            approvalPolicy: "on-request", addDirs: ["/w/b", "/w/c"]
        ).asThreadStartParams(cwd: "/w/a", historyMode: nil)

        XCTAssertEqual(full["cwd"] as? String, "/w/a")
        XCTAssertEqual(full["model"] as? String, "gpt-5-codex")
        XCTAssertEqual(full["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(full["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(full["addDirs"] as? [String], ["/w/b", "/w/c"])
    }

    func testAsThreadStartParamsIncludesHistoryModeWhenSetWithoutDisturbingOtherKeys() {
        // `historyMode` is the one deliberate exception to "omitted means codex's own
        // default" — see `CodexThreadOptions.asThreadStartParams`. `CodexAdapter` only ever
        // passes `"legacy"`, so that is what this pins.
        let params = CodexThreadOptions(
            model: "gpt-5-codex", sandbox: "workspace-write",
            approvalPolicy: "on-request", addDirs: ["/w/b", "/w/c"]
        ).asThreadStartParams(cwd: "/w/a", historyMode: "legacy")

        XCTAssertEqual(params["historyMode"] as? String, "legacy")
        XCTAssertEqual(params["cwd"] as? String, "/w/a")
        XCTAssertEqual(params["model"] as? String, "gpt-5-codex")
        XCTAssertEqual(params["sandbox"] as? String, "workspace-write")
        XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(params["addDirs"] as? [String], ["/w/b", "/w/c"])
        XCTAssertNotNil(params["config"], "addDirs still routes through the config override")
        XCTAssertEqual(params.count, 7)
    }

    func testThreadsInDirectoryMapsEntriesInServerOrder() async throws {
        let t = ThreadListTransport()
        t.data = """
        [
          {"id":"01a0878d-3172-7c60-ac84-2a9805894a60","name":"Flesh out authoring UI plan",
           "path":"/Users/nate/.codex/sessions/2026/09/09/a.jsonl","updatedAt":1788993339},
          {"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","name":"Fix the phone empty bug",
           "path":"/Users/nate/.codex/sessions/2026/09/09/b.jsonl","updatedAt":1788980001}
        ]
        """
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

        let threads = try await adapter.threads(inDirectory: "/w/a")

        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(threads[0].id, UUID(uuidString: "01a0878d-3172-7c60-ac84-2a9805894a60"))
        XCTAssertEqual(threads[0].name, "Flesh out authoring UI plan")
        XCTAssertEqual(threads[0].path, "/Users/nate/.codex/sessions/2026/09/09/a.jsonl")
        XCTAssertEqual(threads[0].updatedAt, 1_788_993_339, "updatedAt is the seconds integer, verbatim")
        XCTAssertEqual(threads[1].id, UUID(uuidString: "01a01269-baa6-7493-8d15-8fa21bcb602b"))
        XCTAssertEqual(threads[1].name, "Fix the phone empty bug")
        XCTAssertEqual(threads[1].path, "/Users/nate/.codex/sessions/2026/09/09/b.jsonl")
        XCTAssertEqual(threads[1].updatedAt, 1_788_980_001)
    }

    func testThreadsInDirectorySendsTheExactRequestShape() async throws {
        // This is the assertion that catches a silently-wrong query: `cwd` is matched as an
        // exact string, and a mismatch comes back `[]` with no error, forever.
        let t = ThreadListTransport()
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

        _ = try await adapter.threads(inDirectory: "/w/some/dir")

        XCTAssertEqual(t.methods, ["thread/list"])
        let params = try XCTUnwrap(t.lastParams)
        XCTAssertEqual(params["cwd"] as? String, "/w/some/dir")
        XCTAssertEqual(params["sortKey"] as? String, "updated_at")
        XCTAssertEqual(params["sortDirection"] as? String, "desc")
        XCTAssertEqual(Set(params["sourceKinds"] as? [String] ?? []), ["cli", "vscode"])
    }

    func testThreadsInDirectoryReturnsEmptyArrayForEmptyData() async throws {
        let t = ThreadListTransport()
        t.data = "[]"
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

        let threads = try await adapter.threads(inDirectory: "/w/a")

        XCTAssertTrue(threads.isEmpty, "empty data must map to [], not throw")
    }

    func testThreadsInDirectorySkipsAnEntryWithAnUnparseableID() async throws {
        let t = ThreadListTransport()
        t.data = """
        [
          {"id":"not-a-uuid","name":"broken","path":"/x.jsonl","updatedAt":1},
          {"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","name":"fine","path":"/y.jsonl","updatedAt":2}
        ]
        """
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

        let threads = try await adapter.threads(inDirectory: "/w/a")

        XCTAssertEqual(threads.count, 1, "the one malformed entry must not lose the rest")
        XCTAssertEqual(threads[0].id, UUID(uuidString: "01a01269-baa6-7493-8d15-8fa21bcb602b"))
    }

    func testThreadsInDirectoryKeepsAnEntryWithNoPathAndNoName() async throws {
        let t = ThreadListTransport()
        t.data = """
        [{"id":"01a01269-baa6-7493-8d15-8fa21bcb602b","updatedAt":42}]
        """
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

        let threads = try await adapter.threads(inDirectory: "/w/a")

        XCTAssertEqual(threads.count, 1, "a genuinely-nil path/name must not be dropped")
        XCTAssertNil(threads[0].path)
        XCTAssertNil(threads[0].name)
        XCTAssertEqual(threads[0].updatedAt, 42)
    }

    func testThreadsInDirectoryPropagatesARemoteErrorRatherThanReturningEmpty() async throws {
        // Task 4 must be able to tell "asked and there are none" apart from "could not ask" —
        // collapsing a broken app-server to [] would make the reconciler read it as "no
        // threads here" and silently do nothing.
        let t = ThreadListTransport()
        t.error = (code: -32000, message: "boom")
        let adapter = CodexAdapter(rpc: CodexRPC(transport: t))

        do {
            _ = try await adapter.threads(inDirectory: "/w/a")
            XCTFail("a remote error must propagate, not collapse to []")
        } catch CodexRPCError.remote(let code, let message) {
            XCTAssertEqual(code, -32000)
            XCTAssertEqual(message, "boom")
        } catch {
            XCTFail("expected CodexRPCError.remote, got \(error)")
        }
    }

    func testThreadsInDirectoryTimesOutRatherThanHangingOnASilentAppServer() async throws {
        // `readTimeout` is a `var` precisely so this can be driven low rather than waiting
        // out a real multi-second hang.
        var adapter = CodexAdapter(rpc: CodexRPC(transport: SilentTransport()))
        adapter.readTimeout = 0.05

        do {
            _ = try await adapter.threads(inDirectory: "/w/a")
            XCTFail("expected a timeout")
        } catch CodexRPCError.timeout {
            // expected
        } catch {
            XCTFail("expected CodexRPCError.timeout, got \(error)")
        }
    }
}

/// A transport that records nothing and answers nothing — every request it is sent hangs
/// forever, so the only way a caller unblocks is `readTimeout`'s own race. Used to prove
/// `threads(inDirectory:)` is genuinely bounded, the same way `read(_:)` already is.
private final class SilentTransport: CodexTransport {
    var onLine: ((String) -> Void)?
    func send(_ line: String) {}
}
