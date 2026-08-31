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
        // it is what commits it. Reversing these leaves a thread codex cannot resume.
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
}
