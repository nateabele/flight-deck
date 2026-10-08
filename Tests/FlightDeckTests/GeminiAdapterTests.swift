import XCTest
import FleetKit
import IntakeKit
import SQLite3
@testable import FlightDeck

/// Track M: the gemini (`agy`) tab adapter. Every screen and record below is SYNTHETIC — built in
/// the shape agy 1.3.1 drew and wrote when probed (`.superpowers/agy-tui-facts.md`, and the
/// 2026-10-08 smoke), with no real account, path or conversation in it.
enum GeminiScreens {
    static let rule = String(repeating: "─", count: 120)
    static let echoRule = String(repeating: "─", count: 60)

    static let header = """
          ▄▀▀▄        Antigravity CLI 1.3.1
         ▀▀▀▀▀▀       user@example.com (Google AI Pro)
        ▀▀▀▀▀▀▀▀      Gemini 3.6 Flash (Low)
       ▄▀▀    ▀▀▄     ~/project
    """

    static func composer(_ row: String = ">", footer: String = "? for shortcuts") -> String {
        """
        \(header)

        \(rule)
        \(row)
        \(rule)
        \(footer)                                                                                   Gemini 3.6 Flash · low
        """
    }

    static let fileDialog = """
    \(header)

    \(echoRule)
    > Create a file named a.txt containing hi

    ● Edited 1 file (a.txt) (ctrl+o to expand)

    Create file
    \(rule)

    /tmp/project/a.txt  +1
       1 +  hi

    Allow creation of this file?
    > 1. Yes, allow creation
      2. No, deny creation

      ↑/↓ Navigate · tab Amend · f full diff
    esc to cancel                                                                                     Gemini 3.6 Flash · low
    """

    static let commandDialog = """
    \(echoRule)
    > Run the shell command: git status --short

    ● Ran (git status --short) (ctrl+o to expand)

    Command
    \(rule)

    Requesting permission for:
       git status --short

    Run this command?
    > 1. Yes, run command
      2. Yes, and always allow in this conversation for commands that start with 'git status'
      3. Yes, and always allow for commands that start with 'git status' (Persist to settings.json)
      4. No, cancel

      ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
    esc to cancel
    """

    static let trustDialog = """
    Accessing workspace:

    /tmp/project

    Do you trust the contents of this project?

    Antigravity CLI requires permission to read, edit, and execute files here.

    > Yes, I trust this folder
      No, exit

      ↑/↓ Navigate · enter Confirm
    """

    /// A bare shell whose prompt is `>` — what fish draws on this machine.
    static let bareShell = """
    Last login: Thu Oct  8 09:00:00 on ttys001
    ~/project
    >
    """
}

/// A screen that answers `readViewport` and records keys; Ctrl-U clears the draft row and Ctrl-Y
/// restores it, as agy does.
@MainActor
private final class AgyScreen: TextInjecting {
    var draft: String
    var keys: [String] = []
    var screen: (String) -> String
    init(draft: String = "", screen: @escaping (String) -> String = { GeminiScreens.composer($0.isEmpty ? ">" : "> \($0)") }) {
        self.draft = draft; self.screen = screen
    }
    private var ring = ""
    func sendText(_ text: String) { keys.append("text:\(text)") }
    func sendReturn() { keys.append("return") }
    func sendKillLine() { keys.append("kill"); if !draft.isEmpty { ring = draft; draft = "" } }
    func sendYank() { keys.append("yank"); draft = ring }
    func sendArrowDown() { keys.append("down") }
    func sendArrowUp() { keys.append("up") }
    func sendEscape() { keys.append("esc") }
    func readViewport() -> String? { screen(draft) }
}

@MainActor
final class GeminiAdapterTests: XCTestCase {
    private let id = UUID(uuidString: "5E7B8B6D-C690-43B3-877E-0049C1DB7CA8")!
    private let paths = GeminiPaths(root: URL(fileURLWithPath: "/agy", isDirectory: true))

    // MARK: Paths and title

    func testPathsNameConversationsInLowercase() {
        XCTAssertEqual(paths.transcript(id).path,
                       "/agy/brain/5e7b8b6d-c690-43b3-877e-0049c1db7ca8/.system_generated/logs/transcript_full.jsonl")
        XCTAssertEqual(paths.annotation(id).path, "/agy/annotations/5e7b8b6d-c690-43b3-877e-0049c1db7ca8.pbtxt")
        XCTAssertEqual(paths.stepStore(id).path, "/agy/conversations/5e7b8b6d-c690-43b3-877e-0049c1db7ca8.db")
    }

    func testATranscriptPathNamesItsConversationAndRoot() throws {
        let found = try XCTUnwrap(GeminiPaths.conversation(ofTranscript: paths.transcript(id)))
        XCTAssertEqual(found.id, id)
        XCTAssertEqual(found.paths.root.path, "/agy")
        XCTAssertNil(GeminiPaths.conversation(ofTranscript: URL(fileURLWithPath: "/x/y.jsonl")))
    }

    func testOnlyThisRootsPresenceLocksNameAConversation() {
        XCTAssertEqual(paths.conversation(ofPresenceLockPath: "/agy/presence/5e7b8b6d-c690-43b3-877e-0049c1db7ca8.lock"), id)
        XCTAssertNil(paths.conversation(ofPresenceLockPath: "/other/presence/5e7b8b6d-c690-43b3-877e-0049c1db7ca8.lock"))
        XCTAssertNil(paths.conversation(ofPresenceLockPath: "/agy/presence/not-a-uuid.lock"))
        XCTAssertNil(paths.conversation(ofPresenceLockPath: "/agy/conversations/5e7b8b6d-c690-43b3-877e-0049c1db7ca8.db"))
    }

    /// The real libproc read, against this test process: a presence lock it holds open names the
    /// conversation; a process tree that holds none names nothing.
    func testThePresenceLockAProcessHoldsOpenNamesItsConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-pres-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = GeminiPaths(root: root)
        try FileManager.default.createDirectory(at: paths.presenceDirectory, withIntermediateDirectories: true)
        XCTAssertNil(GeminiPresence().heldConversation(underRoots: [getpid()], paths: paths))
        FileManager.default.createFile(atPath: paths.presenceLock(id).path, contents: nil)
        let handle = try FileHandle(forReadingFrom: paths.presenceLock(id))
        defer { try? handle.close() }
        XCTAssertEqual(GeminiPresence().heldConversation(underRoots: [getpid()], paths: paths), id)
        XCTAssertNil(GeminiPresence().heldConversation(underRoots: [], paths: paths))
    }

    func testTitleParsesTextFormatEscapes() {
        XCTAssertEqual(GeminiTitle.parse(#"title:"Single Word Reply Test""#), "Single Word Reply Test")
        XCTAssertEqual(GeminiTitle.parse(#"title:"say \"hi\" \\ done""#), #"say "hi" \ done"#)
        // Non-ASCII written as octal UTF-8 bytes: 日 = E6 97 A5.
        XCTAssertEqual(GeminiTitle.parse(#"title:"\346\227\245 notes""#), "日 notes")
        XCTAssertNil(GeminiTitle.parse(#"title:"torn"#))
        XCTAssertNil(GeminiTitle.parse(#"title:"""#))
    }

    func testTitleIsReadFromTheAnnotationBesideTheTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agy-title-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = GeminiPaths(root: root)
        try FileManager.default.createDirectory(at: paths.annotation(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"title:"FD Probe Title""#.utf8).write(to: paths.annotation(id))
        XCTAssertEqual(GeminiAdapter.title(fromTranscriptAt: paths.transcript(id)), "FD Probe Title")
        XCTAssertEqual(AgentID.gemini.title(fromTranscriptAt: paths.transcript(id)), "FD Probe Title")
    }

    // MARK: Launch and resume

    private func session() -> Session {
        Session(title: "t", workingDirectory: "/tmp/project", pinnedConversationID: id, agent: .gemini)
    }

    func testLaunchAlwaysNamesAGeminiModel() {
        let adapter = GeminiAdapter(paths: paths)
        let s = session(), b = adapter.binding(for: s)
        XCTAssertEqual(adapter.launchCommand(b, s, .gemini(GeminiOptions())), "agy --model gemini-3.1-pro-high\n")
        XCTAssertEqual(adapter.launchCommand(b, s, .gemini(GeminiOptions(model: "gemini-3.8-flash-low"))),
                       "agy --model gemini-3.8-flash-low\n")
        // agy also serves Claude models; a gemini tab never launches one, nor anything a shell
        // would read as more than a slug.
        XCTAssertEqual(adapter.launchCommand(b, s, .gemini(GeminiOptions(model: "claude-opus-5-5-high"))),
                       "agy --model gemini-3.1-pro-high\n")
        XCTAssertEqual(adapter.launchCommand(b, s, .gemini(GeminiOptions(model: "gemini-x; rm -rf ~"))),
                       "agy --model gemini-3.1-pro-high\n")
    }

    /// agy answers `--conversation=<unknown>` by silently minting a fresh conversation, so a
    /// resume is typed only for an id agy has a step store for.
    func testResumeOnlyAConversationAgyHas() {
        var adapter = GeminiAdapter(paths: paths)
        let s = session(), b = adapter.binding(for: s)
        adapter.exists = { $0 == self.paths.stepStore(self.id).path }
        XCTAssertEqual(adapter.resumeCommand(b, s, .gemini(GeminiOptions())),
                       "agy --conversation=5e7b8b6d-c690-43b3-877e-0049c1db7ca8 --model gemini-3.1-pro-high\n")
        adapter.exists = { _ in false }
        XCTAssertEqual(adapter.resumeCommand(b, s, .gemini(GeminiOptions())), "agy --model gemini-3.1-pro-high\n")
    }

    func testBindingIsThePinAndItsTranscript() {
        let b = GeminiAdapter(paths: paths).binding(for: session())
        XCTAssertEqual(b.conversationID, id)
        XCTAssertEqual(b.transcriptURL, paths.transcript(id))
    }

    func testCapabilitiesAreStated() {
        XCTAssertTrue(AgentID.gemini.tabReady)
        XCTAssertNotNil(AgentID.gemini.textChannel)
        XCTAssertNotNil(AgentID.gemini.dialogDriver)
        XCTAssertNotNil(AgentID.gemini.openPromptReader)
        XCTAssertNotNil(AgentID.gemini.searchCorpus)
        XCTAssertNil(AgentID.gemini.renameTyping, "single-stage /rename")
        XCTAssertNil(AgentID.gemini.turnRecovery, "no transience classification on disk")
        XCTAssertFalse(AgentID.gemini.negotiatesIdentity)
        XCTAssertFalse(AgentID.gemini.needsRuntimeStart)
        XCTAssertFalse(AgentID.gemini.hasStatusRegistry)
        XCTAssertEqual(GeminiAdapter().loginInvocation(for: AgentAccount(agent: .gemini, displayName: "G", home: AgentID.gemini.builtInHome)),
                       LoginInvocation(command: "agy", inject: nil))
    }

    // MARK: Timeline

    func testUserTurnIsTheRequestWithoutAgysWrapper() {
        let line = #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-08T14:58:26Z","content":"<USER_REQUEST>\nReply with ok\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: 2026-10-08T09:58:26-05:00.\n</ADDITIONAL_METADATA>"}"#
        let items = GeminiAdapter.timelineItems(inLine: line, at: 0)
        XCTAssertEqual(items.map(\.kind), [.userTurn])
        XCTAssertEqual(items.first?.body.text, "Reply with ok")
        XCTAssertEqual(items.first?.at, "2026-10-08T14:58:26Z")
    }

    func testPlannerResponseIsThinkingProseAndCalls() {
        let line = #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-08T14:58:27Z","thinking":"Plan it.","content":"Writing it.","tool_calls":[{"name":"write_to_file","args":{"TargetFile":"/tmp/a.txt","CodeContent":"hi","toolSummary":"Create a.txt"}}]}"#
        let items = AgentID.gemini.timelineItems(inLine: line, at: 120)
        XCTAssertEqual(items.map(\.kind), [.thinking, .assistantText, .toolCall])
        XCTAssertEqual(items.map(\.id), ["120#0", "120#1", "120#2"])
        XCTAssertEqual(items[2].body.tool, "write_to_file")
        XCTAssertEqual(items[2].body.summary, "Create a.txt")
        XCTAssertEqual(items[2].body.callID, "3.0")
    }

    func testADeniedToolIsAnErrorResultAndSystemMessagesAreNotTheUser() {
        let denied = #"{"step_index":2,"source":"MODEL","type":"GENERIC","status":"ERROR","error":"permission check failed: user denied permission","content":""}"#
        let result = GeminiTimelineMapper.items(inLine: denied, at: 0)
        XCTAssertEqual(result.map(\.kind), [.toolResult])
        XCTAssertTrue(result[0].body.isError)
        let system = #"{"step_index":5,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"[Notice] background tasks stopped"}"#
        XCTAssertEqual(GeminiTimelineMapper.items(inLine: system, at: 0).map(\.kind), [.systemNotice])
        XCTAssertTrue(GeminiTimelineMapper.items(inLine: "not json", at: 0).isEmpty)
    }

    // MARK: Screen grammar

    func testTheComposerIsTheRuleSandwichAroundTheLastPrompt() {
        XCTAssertTrue(GeminiTextChannel.isComposerBox(GeminiScreens.composer()))
        XCTAssertTrue(GeminiTextChannel.isComposerBox(GeminiScreens.composer("> a draft", footer: "")))
        XCTAssertTrue(GeminiTextChannel.isComposerBox(GeminiScreens.composer(">", footer: "esc to cancel")),
                      "busy still draws the composer; agy queues what is typed")
        XCTAssertFalse(GeminiTextChannel.isComposerBox(GeminiScreens.fileDialog))
        XCTAssertFalse(GeminiTextChannel.isComposerBox(GeminiScreens.commandDialog))
        XCTAssertFalse(GeminiTextChannel.isComposerBox(GeminiScreens.trustDialog))
        XCTAssertFalse(GeminiTextChannel.isComposerBox(GeminiScreens.bareShell))
    }

    func testEveryDialogIsKnownNotToBeTheComposer() {
        XCTAssertTrue(GeminiTextChannel.isKnownNonComposer(GeminiScreens.fileDialog))
        XCTAssertTrue(GeminiTextChannel.isKnownNonComposer(GeminiScreens.commandDialog))
        XCTAssertTrue(GeminiTextChannel.isKnownNonComposer(GeminiScreens.trustDialog), "unnumbered rows, caught by the hint")
        XCTAssertFalse(GeminiTextChannel.isKnownNonComposer(GeminiScreens.composer()))
        XCTAssertFalse(GeminiTextChannel.isKnownNonComposer(GeminiScreens.composer(">", footer: "esc to cancel")),
                       "a busy composer's footer is not a dialog")
    }

    func testModePlaceholdersReadAsEmpty() {
        let channel = GeminiTextChannel()
        XCTAssertTrue(channel.isComposerEmpty(AgyScreen()))
        XCTAssertTrue(channel.isComposerEmpty(AgyScreen(screen: { _ in
            GeminiScreens.composer("> Plan mode: research & plan only (shift+tab to cycle)") })))
        XCTAssertFalse(channel.isComposerEmpty(AgyScreen(draft: "half a thought")))
    }

    func testSubmitTypesAroundADraftAndPutsItBack() {
        let screen = AgyScreen(draft: "half a thought")
        var finished: Bool?
        XCTAssertTrue(GeminiTextChannel().submit("/rename X", into: screen, settle: { $0() },
                                                 stillWanted: { true }, onFinished: { finished = $0 }))
        XCTAssertEqual(screen.keys, ["kill", "text:/rename X", "return", "yank"])
        XCTAssertEqual(finished, true)
        XCTAssertEqual(screen.draft, "half a thought")
    }

    func testSubmitOnAnEmptyComposerYanksNothing() {
        let screen = AgyScreen()
        XCTAssertTrue(GeminiTextChannel().submit("hi", into: screen, settle: { $0() }, stillWanted: { true }, onFinished: { _ in }))
        XCTAssertEqual(screen.keys, ["kill", "text:hi", "return"])
    }

    func testSubmitRefusesADialogAndASupersededRequestTypesNothing() {
        let dialog = AgyScreen(screen: { _ in GeminiScreens.fileDialog })
        XCTAssertFalse(GeminiTextChannel().submit("hi", into: dialog, settle: { $0() }, stillWanted: { true }, onFinished: { _ in }))
        XCTAssertTrue(dialog.keys.isEmpty)

        let screen = AgyScreen(draft: "mine")
        var finished: Bool?
        _ = GeminiTextChannel().submit("hi", into: screen, settle: { $0() }, stillWanted: { false }, onFinished: { finished = $0 })
        XCTAssertEqual(screen.keys, ["kill", "yank"])
        XCTAssertEqual(finished, false)
    }

    // MARK: Dialogs

    func testDialogRowsReadWithAgysMarker() {
        let driver = GeminiDialogDriver()
        XCTAssertEqual(driver.focusedRow(inViewport: GeminiScreens.fileDialog), 0)
        XCTAssertTrue(driver.row(0, reads: "Yes, allow creation", inViewport: GeminiScreens.fileDialog))
        XCTAssertTrue(driver.row(3, reads: "No, cancel", inViewport: GeminiScreens.commandDialog))
        XCTAssertTrue(driver.hasSelectList(inViewport: GeminiScreens.commandDialog))
        XCTAssertFalse(driver.hasSelectList(inViewport: GeminiScreens.composer("> a draft")))
        XCTAssertEqual(driver.allowRow, 0)
    }

    /// Esc cancels agy's whole turn, so a deny moves to the LAST row and presses Return.
    func testDenyPressesTheLastRowAndNeverEscape() {
        let file = AgyScreen(screen: { _ in GeminiScreens.fileDialog })
        GeminiDialogDriver().deny(file)
        XCTAssertEqual(file.keys, ["down", "return"])

        let command = AgyScreen(screen: { _ in GeminiScreens.commandDialog })
        GeminiDialogDriver().deny(command)
        XCTAssertEqual(command.keys, ["down", "down", "down", "return"])
    }

    func testDenyPressesNothingWhenTheLastRowIsNotARefusal() {
        let odd = AgyScreen(screen: { _ in GeminiScreens.fileDialog.replacingOccurrences(of: "2. No, deny creation", with: "2. Maybe later") })
        GeminiDialogDriver().deny(odd)
        XCTAssertTrue(odd.keys.isEmpty)
        let blank = AgyScreen(screen: { _ in GeminiScreens.composer() })
        GeminiDialogDriver().deny(blank)
        XCTAssertTrue(blank.keys.isEmpty)
    }

    // MARK: Step store (the only place a WAITING step exists)

    /// A step payload in the shape agy writes: field 1 step type, field 4 status, field 5 → 4
    /// the call (`1` id, `2` tool, `3` args JSON).
    static func payload(callID: String, tool: String, args: String) -> Data {
        func varint(_ v: Int) -> [UInt8] {
            var v = UInt64(v), out: [UInt8] = []
            repeat { var b = UInt8(v & 0x7F); v >>= 7; if v != 0 { b |= 0x80 }; out.append(b) } while v != 0
            return out
        }
        func field(_ n: Int, _ bytes: [UInt8]) -> [UInt8] { varint(n << 3 | 2) + varint(bytes.count) + bytes }
        let call = field(1, Array(callID.utf8)) + field(2, Array(tool.utf8)) + field(3, Array(args.utf8))
        let step = field(1, [0x08, 0x01]) + field(4, call) + field(12, Array("x".utf8))
        return Data(varint(1 << 3) + varint(132) + varint(4 << 3) + varint(9) + field(5, step))
    }

    func testAPendingCallDecodesFromItsPayload() throws {
        let call = try XCTUnwrap(GeminiStepStore.decodeCall(
            Self.payload(callID: "call_1", tool: "run_command", args: #"{"CommandLine":"ls"}"#), stepIndex: 2))
        XCTAssertEqual(call, GeminiPendingCall(callID: "call_1", tool: "run_command", argumentsJSON: #"{"CommandLine":"ls"}"#, stepIndex: 2))
        XCTAssertNil(GeminiStepStore.decodeCall(Data([0xFF, 0xFF]), stepIndex: 0), "a torn read is no call, not a trap")
    }

    func testThePendingCallIsTheWaitingRowOfALiveStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-steps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("c.db")
        try Self.makeStore(db, rows: [
            (0, 14, 3, Data()),
            (1, 15, 3, Data()),
            (2, 132, 9, Self.payload(callID: "call_9", tool: "write_to_file", args: #"{"toolSummary":"Create a.txt"}"#)),
        ])
        XCTAssertEqual(GeminiStepStore.pendingCall(in: db)?.callID, "call_9")
        try Self.makeStore(db, rows: [(2, 132, 7, Self.payload(callID: "call_9", tool: "write_to_file", args: "{}"))])
        XCTAssertNil(GeminiStepStore.pendingCall(in: db), "answered: status 7, not 9")
        XCTAssertNil(GeminiStepStore.pendingCall(in: dir.appendingPathComponent("missing.db")))
    }

    static func makeStore(_ url: URL, rows: [(Int, Int, Int, Data)]) throws {
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE steps (idx integer, step_type integer, status integer, step_payload blob, PRIMARY KEY (idx))", nil, nil, nil), SQLITE_OK)
        for (idx, type, status, payload) in rows {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO steps VALUES (?, ?, ?, ?)", -1, &statement, nil)
            sqlite3_bind_int(statement, 1, Int32(idx)); sqlite3_bind_int(statement, 2, Int32(type)); sqlite3_bind_int(statement, 3, Int32(status))
            _ = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32(payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
    }

    func testSummariesReadStatusWorkspacesAndTitle() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-sum-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("conversation_summaries.db")
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, """
            CREATE TABLE conversation_summaries (conversation_id text, title text, workspace_uris text, status text, last_modified_time datetime);
            INSERT INTO conversation_summaries VALUES ('5e7b8b6d-c690-43b3-877e-0049c1db7ca8', 'Greeting', '["file:///tmp/project"]', 'CASCADE_RUN_STATUS_RUNNING', '2026-10-07 22:37:33.685173+00:00');
            """, nil, nil, nil)
        sqlite3_close(db)
        let summary = try XCTUnwrap(GeminiSummaries.summary(id, in: url))
        XCTAssertEqual(summary.title, "Greeting")
        XCTAssertEqual(summary.workspaces, ["/tmp/project"])
        XCTAssertTrue(summary.isRunning)
        XCTAssertNotNil(summary.modified)
        XCTAssertNil(GeminiSummaries.summary(UUID(), in: url))
    }

    // MARK: Open prompt

    func testTheOpenPromptIsTheStoresWaitingCallAndOnlyWhileWaiting() {
        let reader = GeminiOpenPromptReader(pendingCall: { url in
            url.lastPathComponent == "5e7b8b6d-c690-43b3-877e-0049c1db7ca8.db"
                ? GeminiPendingCall(callID: "call_7", tool: "run_command", argumentsJSON: #"{"CommandLine":"ls","toolSummary":"List files"}"#, stepIndex: 2)
                : nil
        })
        let url = paths.transcript(id)
        XCTAssertEqual(reader.openPrompt(inTranscriptAt: url, tail: [], activity: .waiting),
                       .permission(callID: "call_7", tool: "run_command", summary: "List files"))
        XCTAssertNil(reader.openPrompt(inTranscriptAt: url, tail: [], activity: .busy))
        XCTAssertNil(reader.openPrompt(inTranscriptAt: paths.transcript(UUID()), tail: [], activity: .waiting))
        XCTAssertNil(reader.openPrompt(inTranscriptTail: [], activity: .waiting), "lines alone name no store")
    }

    /// The default keeps every other agent's reader on its line-based derivation.
    func testOtherReadersIgnoreThePath() {
        XCTAssertNil(ClaudeOpenPromptReader().openPrompt(inTranscriptAt: URL(fileURLWithPath: "/x.jsonl"), tail: [], activity: .waiting))
    }

    // MARK: Runtime

    private func runtime(_ observation: @escaping () -> GeminiObservation) -> GeminiRuntime {
        let observer = GeminiObserver(held: { _ in observation().held }, running: { _ in observation().running },
                                      pending: { _ in observation().pending }, title: { _ in observation().title })
        return GeminiRuntime(clock: nil, paths: paths, roots: { _ in [1] }, observer: observer)
    }

    func testANewTabIsRepinnedToTheConversationItsAgyHolds() {
        let minted = UUID()
        let rt = runtime { GeminiObservation(held: minted, running: false, pending: nil, title: nil) }
        var events: [AgentEvent] = []
        _ = rt.attach(AgentBinding(conversationID: id, transcriptURL: nil), for: UUID()) { events.append($0) }
        rt.drain()
        XCTAssertEqual(events, [.rebound(AgentBinding(conversationID: minted, transcriptURL: paths.transcript(minted)))])
    }

    func testStatusFollowsTheStoresAndATurnEndsOnIdle() {
        var observation = GeminiObservation(held: id, running: true, pending: nil, title: "Greeting")
        let rt = runtime { observation }
        var events: [AgentEvent] = []
        _ = rt.attach(AgentBinding(conversationID: id, transcriptURL: nil), for: UUID()) { events.append($0) }
        rt.drain()
        XCTAssertEqual(events, [.lifecycle(.live), .activity(.busy), .title("Greeting")])
        events = []
        observation.pending = GeminiPendingCall(callID: "c", tool: "t", argumentsJSON: "{}", stepIndex: 1)
        rt.drain()
        XCTAssertEqual(events, [.activity(.waiting)])
        events = []
        observation.pending = nil; observation.running = false
        rt.drain()
        XCTAssertEqual(events, [.activity(.idle), .turnEnded])
        events = []
        rt.drain()
        XCTAssertEqual(events, [], "nothing changed, nothing reported")
        observation.held = nil
        rt.drain()
        XCTAssertEqual(events, [.lifecycle(.absent)])
    }

    func testADetachedTabHearsNothing() {
        let rt = runtime { GeminiObservation(held: self.id, running: true, pending: nil, title: nil) }
        var events: [AgentEvent] = []
        let token = rt.attach(AgentBinding(conversationID: id, transcriptURL: nil), for: UUID()) { events.append($0) }
        rt.detach(token)
        rt.drain()
        XCTAssertTrue(events.isEmpty)
    }

    /// The store follows `.rebound`: the tab's pin and transcript move to the conversation agy
    /// named, and are persisted.
    func testTheStoreRepinsATabOnRebound() throws {
        let store = SessionStore(provider: nil, persistence: nil)
        store.geminiPaths = paths
        let created = store.newSession(in: URL(fileURLWithPath: "/tmp/project", isDirectory: true), agent: .gemini)
        XCTAssertEqual(store.agent(of: created.id), .gemini, "createSession's synchronous path opens the agent asked for")
        let minted = UUID()
        store.apply(.rebound(AgentBinding(conversationID: minted, transcriptURL: paths.transcript(minted))), to: created.id)
        XCTAssertEqual(store.pinnedConversationID(of: created.id), minted)
    }

    // MARK: Usage, routing, search

    func testUsageReadsTheGeminiGroupOnly() throws {
        let json = #"{"conversation_id":"","status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.75,"reset_time":"2026-10-14T22:37:32Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.5,"reset_time":"2026-10-08T03:37:32Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-5h","window":"5h","remaining_fraction":0.1,"reset_time":"2026-10-08T07:17:50Z"}]}]}}}"#
        let windows = try XCTUnwrap(GeminiUsageSource.windows(fromUsageJSON: Data(json.utf8)))
        XCTAssertEqual(windows.map(\.name), ["gemini-weekly", "gemini-5h"])
        XCTAssertEqual(windows.map(\.utilization), [0.25, 0.5])
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNil(GeminiUsageSource.windows(fromUsageJSON: Data("{}".utf8)))
    }

    func testUsageIsNeverReadFromASignedOutAgy() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agy-bin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let agy = dir.appendingPathComponent("agy")
        try Data("#!/bin/sh\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)
        final class Calls: @unchecked Sendable { var list: [[String]] = [] }
        let calls = Calls()
        let signedOut = SignInProbe { _, args, _ in
            calls.list.append(args)
            return SignInCheckOutput(stdout: "", stderr: "Please sign in to view available models", exitCode: 1)
        }
        XCTAssertNil(GeminiUsageSource.read(path: dir.path, probe: signedOut))
        XCTAssertEqual(calls.list, [["models"]], "/usage must not run: a signed-out agy -p opens a browser")
    }

    func testOverridesTakeGeminiModelsOnly() {
        let base = AgentOptions.gemini(GeminiOptions())
        XCTAssertEqual(GeminiLaunchOverrides.apply(LaunchOverrides(model: "gemini-3.8-flash-high", knobs: [:]), to: base).value,
                       .gemini(GeminiOptions(model: "gemini-3.8-flash-high")))
        XCTAssertNil(GeminiLaunchOverrides.apply(LaunchOverrides(model: "claude-opus-5-5-high", knobs: [:]), to: base).value)
        XCTAssertNil(GeminiLaunchOverrides.apply(LaunchOverrides(model: nil, knobs: ["effort": "high"]), to: base).value)
    }

    func testRoutingCatalogIsTheAccountsGeminiList() async {
        let caps = GeminiRoutingCapabilities()
        caps.list = { ["gemini-3.1-pro-high", "gemini-3.8-flash-low"] }
        let listed = await caps.modelCatalog().value?.map(\.id)
        XCTAssertEqual(listed, ["gemini-3.1-pro-high", "gemini-3.8-flash-low"])
        let signedOut = GeminiRoutingCapabilities()
        signedOut.list = { nil }
        let none = await signedOut.modelCatalog().value
        XCTAssertNil(none)
        XCTAssertTrue(RoutingCapabilityRegistry.standard().agents.contains(.gemini))
    }

    func testSearchFilesConversationsByTheirWorkspace() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agy-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = GeminiPaths.forHome(home)
        let other = UUID()
        for conversation in [id, other] {
            try FileManager.default.createDirectory(at: paths.transcript(conversation).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: paths.transcript(conversation))
        }
        let project = home.appendingPathComponent("project").path
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        var corpus = GeminiSearchCorpus()
        let summaries = [
            GeminiSummary(conversationID: id, title: "Greeting", workspaces: [project], status: "", modified: nil),
            GeminiSummary(conversationID: other, title: "Elsewhere", workspaces: ["/nowhere"], status: "", modified: nil),
        ]
        corpus.summaries = { _ in summaries }
        let account = AgentAccount(agent: .gemini, displayName: "G", home: home)
        let refs = corpus.transcripts(forProjects: [project], accounts: [account])
        XCTAssertEqual(refs.map(\.conversationID), [GeminiPaths.name(id)])
        XCTAssertEqual(refs.first?.agent, .gemini)
        XCTAssertEqual(corpus.conversationName(inLines: [], for: try XCTUnwrap(refs.first)), .authoritative("Greeting"))

        let user = #"{"type":"USER_INPUT","created_at":"2026-10-08T14:58:26Z","content":"<USER_REQUEST>\nfind me\n</USER_REQUEST>"}"#
        XCTAssertEqual(corpus.indexedMessages(inLine: user, conversationID: "c", at: 7).map(\.text), ["find me"])
        XCTAssertTrue(corpus.indexedMessages(inLine: #"{"type":"GENERIC","content":"tool output"}"#, conversationID: "c", at: 0).isEmpty)
    }
}
