import FleetKit
import XCTest
@testable import FlightDeck

/// The answer drive, reached from a shell instead of from a handset.
///
/// **What these assert is that nothing was shortcut.** The value of this entry point is
/// entirely that it goes through `PromptService` and `SessionStore.answerPrompt` — the same
/// two calls `FleetService`'s `.answerPrompt` arm makes — so the assertions that matter are
/// the ones about keystrokes reaching the spy and about a store refusal reaching the caller
/// with its own code. A trigger that typed keys itself would pass a JSON-shape test and prove
/// nothing.
@MainActor
final class AnswerTriggerTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private var projectsRoot: URL!
    private var socketRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        // **Under `/tmp` rather than under `NSTemporaryDirectory()`, and that is not a
        // preference.** A unix socket path has 103 bytes; the per-process temporary directory
        // is a `/var/folders/…` path most of the way through that on its own, so a socket
        // named there is one long test-run identifier away from failing to bind for a reason
        // that has nothing to do with what is being tested.
        socketRoot = URL(fileURLWithPath: "/tmp/flight-deck-trigger", isDirectory: true)
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// A waiting claude tab whose injection settles synchronously, plus the trigger over it —
    /// `PromptServiceTests.makeService`, one layer up.
    private func makeTrigger(activity: SessionActivity = .waiting)
        -> (AnswerTrigger, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, activity, cwd: tmp.path)])
        spy.events.removeAll()
        return (AnswerTrigger(store: store), spy, session.id)
    }

    /// One `AskUserQuestion` record, in claude's own transcript shape.
    private func askLine(_ id: String, multiSelect: Bool = false) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"AskUserQuestion","input":{"questions":[{"question":"Which?",\
        "header":"Pick","multiSelect":\(multiSelect),"options":[{"label":"Yes",\
        "description":"the affirmative"},{"label":"No"}]}]}}]}}
        """
    }

    /// Two questions in one call — 16% of real ones, and the shape whose *count* the store
    /// checks an answer against.
    private func askTwoLine(_ id: String) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"AskUserQuestion","input":{"questions":[\
        {"question":"Which?","options":[{"label":"Yes"},{"label":"No"}]},\
        {"question":"And then?","options":[{"label":"Stop"},{"label":"Go"}]}]}}]}}
        """
    }

    private func bashLine(_ id: String) -> String {
        """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"\(id)","name":"Bash","input":{"command":"rm -rf build"}}]}}
        """
    }

    private func show(_ trigger: AnswerTrigger, _ line: String) {
        let lines = [SourceLine(offset: 0, text: line)]
        trigger.prompts.tail = { _, _ in lines }
    }

    /// The reply, as a dictionary, because the caller is a script reading JSON and that is
    /// what a script sees.
    private func reply(_ trigger: AnswerTrigger, _ request: String) throws -> [String: Any] {
        let text = trigger.handle(request)
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any], "a reply is always a JSON object")
    }

    // MARK: - The gate

    /// **Off by default, and that is the security property.** Anything that can reach this
    /// socket can press Return in the developer's terminal, so a shipped launch must open
    /// nothing at all.
    func testTheTriggerIsOffUntilSomebodyTurnsItOn() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "answer-trigger-\(UUID().uuidString)"))
        XCTAssertFalse(AnswerTrigger.isEnabled(suite))
        suite.set(true, forKey: AnswerTrigger.defaultsKey)
        XCTAssertTrue(AnswerTrigger.isEnabled(suite))
    }

    // MARK: - list

    func testListNamesTheOpenQuestionItsOptionsAndTheirIndices() throws {
        let (trigger, _, id) = makeTrigger()
        show(trigger, askLine("toolu_A", multiSelect: true))

        let body = try reply(trigger, #"{"op":"list"}"#)
        XCTAssertEqual(body["ok"] as? Bool, true)
        let sessions = try XCTUnwrap(body["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 1)
        let open = try XCTUnwrap(sessions.first)
        XCTAssertEqual(open["session"] as? String, id.uuidString)
        XCTAssertEqual(open["call"] as? String, "toolu_A")
        XCTAssertEqual(open["kind"] as? String, "question")
        XCTAssertEqual(open["agent"] as? String, "claude")

        let questions = try XCTUnwrap(open["questions"] as? [[String: Any]])
        let question = try XCTUnwrap(questions.first)
        XCTAssertEqual(question["index"] as? Int, 0)
        XCTAssertEqual(question["question"] as? String, "Which?")
        XCTAssertEqual(question["header"] as? String, "Pick")
        XCTAssertEqual(question["multiSelect"] as? Bool, true)

        let options = try XCTUnwrap(question["options"] as? [[String: Any]])
        XCTAssertEqual(options.map { $0["index"] as? Int }, [0, 1])
        XCTAssertEqual(options.map { $0["label"] as? String }, ["Yes", "No"])
        XCTAssertEqual(options.first?["detail"] as? String, "the affirmative")
    }

    /// A tab with nothing blocked on it is not a menu entry. `openPrompt(inSession:)` refuses
    /// it `not_waiting`, and a listing that reported that for every idle tab would bury the
    /// one row a caller is looking for.
    func testATabThatIsNotWaitingIsNotListed() throws {
        let (trigger, _, _) = makeTrigger(activity: .idle)
        show(trigger, askLine("toolu_A"))
        let body = try reply(trigger, #"{"op":"list"}"#)
        XCTAssertEqual(try XCTUnwrap(body["sessions"] as? [[String: Any]]).count, 0)
    }

    /// A permission dialog is listed — a caller has to be able to see what the tab is blocked
    /// on — but it carries no questions, because there are none to carry. `OpenPrompt.permission`
    /// says why at length.
    func testAPermissionDialogIsListedWithNoOptionsToIndex() throws {
        let (trigger, _, _) = makeTrigger()
        show(trigger, bashLine("toolu_B"))
        let body = try reply(trigger, #"{"op":"list"}"#)
        let open = try XCTUnwrap((body["sessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(open["kind"] as? String, "permission")
        XCTAssertEqual(open["tool"] as? String, "Bash")
        XCTAssertNil(open["questions"])
    }

    // MARK: - answer

    /// **The whole point, end to end.** A line of JSON names option 1, and the terminal is
    /// driven: one arrow down onto the row, then Return. Those two events come from
    /// `SessionStore.drive`, through `AnswerPlan`, past the interlock that re-reads the screen
    /// — none of which a trigger that typed keys itself would have touched.
    func testAnAnswerByIndexDrivesTheRealPlan() throws {
        let (trigger, spy, id) = makeTrigger()
        show(trigger, askLine("toolu_A"))
        spy.showOptions(["Yes", "No"], selected: 0)

        let body = try reply(
            trigger, #"{"op":"answer","session":"\#(id.uuidString)","selections":[[1]]}"#
        )
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(body["result"] as? String, "dispatched")
        XCTAssertEqual(body["call"] as? String, "toolu_A")
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
    }

    /// The reply carries where the abort log ended *before* the keystroke, because a drive
    /// aborts across `injectionSettle` and the reply has already gone by then. Read after the
    /// drive it would include this drive's own record only sometimes, which is worse than not
    /// carrying one at all.
    func testTheReplyCarriesACursorIntoTheAbortLogTakenBeforeTheDrive() throws {
        let (trigger, spy, id) = makeTrigger()
        show(trigger, askLine("toolu_A"))
        spy.showOptions(["Yes", "No"], selected: 0)
        trigger.answerLogLength = { 4096 }

        let body = try reply(
            trigger, #"{"op":"answer","session":"\#(id.uuidString)","selections":[[0]]}"#
        )
        let cursor = try XCTUnwrap(body["abortLog"] as? [String: Any])
        XCTAssertEqual(cursor["offset"] as? Int, 4096)
        XCTAssertEqual(cursor["path"] as? String, AnswerAbortLog.fileURL.path)
    }

    /// A `call` supplied is compared exactly as a phone's is. This is the check a shell
    /// *may* skip by omitting the field, so the case where it does not skip it has to hold.
    func testACallThatNamesADifferentDialogIsRefused() throws {
        let (trigger, spy, id) = makeTrigger()
        show(trigger, askLine("toolu_A"))
        spy.showOptions(["Yes", "No"], selected: 0)

        let body = try reply(
            trigger,
            #"{"op":"answer","session":"\#(id.uuidString)","call":"toolu_OLD","selections":[[0]]}"#
        )
        XCTAssertEqual(body["ok"] as? Bool, false)
        XCTAssertEqual(body["error"] as? String, "prompt_changed")
        XCTAssertTrue(spy.events.isEmpty, "nothing is typed at a dialog nobody named")
    }

    /// **A refusal from the store keeps its own code.** Two questions answered with one array
    /// is what `answerPrompt` refuses as `unreadable_screen`, and reproducing that refusal from
    /// a shell — rather than having the trigger pre-empt it with a validation of its own — is
    /// one of the reasons this exists.
    func testARefusalFromTheStoreReachesTheCallerVerbatim() throws {
        let (trigger, spy, id) = makeTrigger()
        show(trigger, askTwoLine("toolu_A"))
        spy.showOptions(["Yes", "No"], selected: 0)

        let body = try reply(
            trigger, #"{"op":"answer","session":"\#(id.uuidString)","selections":[[0]]}"#
        )
        XCTAssertEqual(body["ok"] as? Bool, false)
        XCTAssertEqual(body["error"] as? String, "unreadable_screen")
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// An index the transcript does not have has no label to send beside it, so it is named as
    /// the caller's typo rather than turned into a keystroke.
    func testAnOptionTheQuestionDoesNotHaveIsNamedRatherThanSent() throws {
        let (trigger, spy, id) = makeTrigger()
        show(trigger, askLine("toolu_A"))
        spy.showOptions(["Yes", "No"], selected: 0)

        let body = try reply(
            trigger, #"{"op":"answer","session":"\#(id.uuidString)","selections":[[7]]}"#
        )
        XCTAssertEqual(body["error"] as? String, "bad_selection")
        XCTAssertEqual(body["detail"] as? String, "question 0 has no option 7")
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAPermissionDialogCannotBeAnsweredByIndex() throws {
        let (trigger, spy, id) = makeTrigger()
        show(trigger, bashLine("toolu_B"))
        spy.showOptions(["Yes", "No"], selected: 0)

        let body = try reply(
            trigger, #"{"op":"answer","session":"\#(id.uuidString)","selections":[[0]]}"#
        )
        XCTAssertEqual(body["error"] as? String, "not_a_question")
        XCTAssertTrue(spy.events.isEmpty)
    }

    func testAnUnknownTabIsRefusedWithTheStoresOwnCode() throws {
        let (trigger, _, _) = makeTrigger()
        show(trigger, askLine("toolu_A"))
        let body = try reply(
            trigger, #"{"op":"answer","session":"\#(UUID().uuidString)","selections":[[0]]}"#
        )
        XCTAssertEqual(body["error"] as? String, "unknown_session")
    }

    // MARK: - Malformed requests

    /// A caller is a script, and a script gets a line it can parse even when it sent one that
    /// could not be. Trapping here would take the whole app down over a typo in a shell.
    func testALineThatIsNotJSONIsAnErrorRatherThanACrash() throws {
        let (trigger, _, _) = makeTrigger()
        let body = try reply(trigger, "not json at all")
        XCTAssertEqual(body["ok"] as? Bool, false)
        XCTAssertEqual(body["error"] as? String, "bad_request")
        XCTAssertNotNil(body["detail"], "and it says what a request looks like")
    }

    func testAnOperationThisBuildDoesNotHaveIsRefused() throws {
        let (trigger, _, _) = makeTrigger()
        XCTAssertEqual(
            try reply(trigger, #"{"op":"drive"}"#)["error"] as? String, "bad_request"
        )
    }

    func testAnAnswerWithNoSelectionsSaysWhatIsMissing() throws {
        let (trigger, _, id) = makeTrigger()
        let body = try reply(trigger, #"{"op":"answer","session":"\#(id.uuidString)"}"#)
        XCTAssertEqual(body["error"] as? String, "missing_selections")
    }

    func testAnAnswerWithNoSessionSaysWhatIsMissing() throws {
        let (trigger, _, _) = makeTrigger()
        XCTAssertEqual(
            try reply(trigger, #"{"op":"answer","selections":[[0]]}"#)["error"] as? String,
            "missing_session"
        )
    }

    // MARK: - The socket

    /// The transport, once, over a real unix socket — because `nc -U` is the only client this
    /// will ever have and "the handler returns a string" is not the claim being made.
    ///
    /// The client runs off the main queue and the test waits on an expectation: the socket
    /// serves a request by hopping to the main actor, so a test that blocked the main thread
    /// on the read would be waiting for a reply that cannot be computed until it stops.
    func testASocketCarriesOneRequestAndItsReplyBack() throws {
        let url = socketRoot.appendingPathComponent("\(UUID().uuidString).sock")
        let socket = AnswerTriggerSocket(url: url) { line in
            XCTAssertEqual(line.trimmingCharacters(in: .newlines), #"{"op":"ping"}"#)
            return #"{"ok":true,"op":"ping"}"#
        }
        try socket.start()
        defer { socket.stop() }

        let answered = expectation(description: "the socket replies")
        let received = Received()
        DispatchQueue.global().async {
            received.text = Self.roundTrip(#"{"op":"ping"}"#, to: url.path)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(received.text?.trimmingCharacters(in: .newlines), #"{"ok":true,"op":"ping"}"#)
    }

    /// **A path that will not fit is refused by name.** `sockaddr_un` does not truncate — it
    /// fails with `EINVAL`, which says nothing about a length — and the socket lives wherever
    /// `-FlightDeckStateDir` points, so this is reachable without doing anything unusual.
    func testAPathTooLongForAUnixSocketIsRefusedByName() {
        let long = "/tmp/" + String(repeating: "d", count: AnswerTriggerSocket.maxPathLength)
        let socket = AnswerTriggerSocket(url: URL(fileURLWithPath: long)) { _ in "" }
        XCTAssertThrowsError(try socket.start()) { error in
            XCTAssertEqual(
                error as? AnswerTriggerSocket.Failure, .pathTooLong(long.utf8.count)
            )
        }
    }

    /// Where the client's reply lands. A class because the closure runs on another queue and
    /// a captured `var` cannot be written from one.
    private final class Received: @unchecked Sendable {
        var text: String?
    }

    /// One connect / send / read / close, in the shape `nc -U` does it.
    private static func roundTrip(_ request: String, to path: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: AnswerTriggerSocket.maxPathLength + 1) {
                _ = strlcpy($0, path, AnswerTriggerSocket.maxPathLength + 1)
            }
        }
        let joined = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard joined == 0 else { return nil }
        var outgoing = Array((request + "\n").utf8)
        guard write(fd, &outgoing, outgoing.count) == outgoing.count else { return nil }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            reply.append(contentsOf: buffer[0..<n])
            if buffer[0..<n].contains(UInt8(ascii: "\n")) { break }
        }
        return String(data: reply, encoding: .utf8)
    }
}
