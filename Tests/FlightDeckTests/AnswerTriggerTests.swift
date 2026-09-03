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
        var defaultFontSize: Float { 12 }
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
        let trigger = AnswerTrigger(store: store)
        // Silenced for `PromptServiceTests.makeService`'s reason: the default sink appends to
        // the developer's own `~/Library/Logs/flight-deck-prompt.log`.
        trigger.prompts.lifecycleSink = { _ in }
        return (trigger, spy, session.id)
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
        // **Unwrapped rather than awaited, and the `XCTUnwrap` is the assertion.** `handle`
        // takes a completion because the `logs` op waits on a phone; `list` and `answer` still
        // answer before it returns, and every caller here is one of those two. A nil here would
        // mean one of them had quietly become asynchronous, which is worth failing on.
        var text: String?
        trigger.handle(request) { text = $0 }
        let answered = try XCTUnwrap(text, "list and answer answer synchronously")
        let object = try JSONSerialization.jsonObject(with: Data(answered.utf8))
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

    // MARK: - logs

    /// The phones a `logs` fetch would reach, played without a socket, a pairing or a handset.
    /// See `PhoneLogFetching` for why the trigger takes this seam rather than `FleetService`.
    private final class StubPhones: PhoneLogFetching {
        var attachedClients: [FleetAttachment] = []
        /// What each connection answers, by id. A connection with no entry never answers at
        /// all, which is how "the phone went into a pocket" is played.
        var answers: [UUID: Result<WirePhoneLogs, FleetRequestError>] = [:]
        private(set) var asked: [(client: UUID, seconds: Int, limit: Int)] = []

        func fetchPhoneLogs(
            from client: UUID, seconds: Int, limit: Int,
            then completion: @escaping (Result<WirePhoneLogs, FleetRequestError>) -> Void
        ) {
            asked.append((client, seconds, limit))
            guard let answer = answers[client] else { return }
            completion(answer)
        }
    }

    private func phone(
        _ name: String, caps: Set<String> = [FleetCapability.logs]
    ) -> FleetAttachment {
        FleetAttachment(id: UUID(), slot: UUID(), name: name, caps: caps)
    }

    private func logs(_ messages: [String], truncated: Bool = false) -> WirePhoneLogs {
        WirePhoneLogs(
            entries: messages.map {
                WirePhoneLogEntry(
                    at: "2026-09-01T09:15:00.000+01:00", level: "notice",
                    category: "prompt", message: $0
                )
            },
            truncated: truncated
        )
    }

    /// A trigger whose `logs` op reaches `phones` and appends nowhere near the developer's
    /// real `~/Library/Logs/flight-deck-phone.log`.
    private func makeLogTrigger(_ phones: StubPhones) -> (AnswerTrigger, [WirePhoneLogs]) {
        let (trigger, _, _) = makeTrigger()
        trigger.phones = phones
        return (trigger, [])
    }

    func testLogsFetchesEveryAttachedPhoneAndSaysWhereItLanded() throws {
        let phones = StubPhones()
        let iphone = phone("iPhone")
        phones.attachedClients = [iphone]
        phones.answers[iphone.id] = .success(logs(["prompt derived=toolu_1 shown=toolu_1"]))
        let (trigger, _) = makeLogTrigger(phones)
        var appended: [(WirePhoneLogs, String?)] = []
        trigger.appendPhoneLogs = { appended.append(($0, $1)) }

        let reply = try self.reply(trigger, #"{"op":"logs"}"#)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["entries"] as? Int, 1)
        XCTAssertEqual(reply["path"] as? String, PhoneLogFile.fileURL.path)
        // The default window, and the cap the phone will clamp to anyway — asserted here
        // because a caller reading `seconds` back is how it knows what it actually got.
        XCTAssertEqual(reply["seconds"] as? Int, PhoneLogLimits.defaultSeconds)
        XCTAssertEqual(phones.asked.first?.limit, PhoneLogLimits.maxEntries)
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.first?.1, "iPhone")
    }

    /// A window a caller names is passed through; one past the ceiling is clamped rather than
    /// refused, the same contract the phone itself keeps against this Mac.
    func testLogsClampsTheWindowRatherThanRefusingIt() throws {
        let phones = StubPhones()
        let iphone = phone("iPhone")
        phones.attachedClients = [iphone]
        phones.answers[iphone.id] = .success(logs([]))
        let (trigger, _) = makeLogTrigger(phones)
        trigger.appendPhoneLogs = { _, _ in }

        _ = try reply(trigger, #"{"op":"logs","seconds":90}"#)
        XCTAssertEqual(phones.asked.last?.seconds, 90)
        _ = try reply(trigger, #"{"op":"logs","seconds":9999999}"#)
        XCTAssertEqual(phones.asked.last?.seconds, PhoneLogLimits.maxSeconds)
    }

    /// **The compatibility case, from the shell's side.** A handset built before this feature
    /// existed never claimed `logs`, so `FleetSocketServer.request` refuses without sending it
    /// anything — and the caller is told which phone and why, rather than being left to guess
    /// from an empty file.
    func testAPhoneTooOldToBeAskedIsNamedRatherThanSilentlySkipped() throws {
        let phones = StubPhones()
        let old = phone("iPhone", caps: [])
        phones.attachedClients = [old]
        phones.answers[old.id] = .failure(.server(code: "unsupported_peer"))
        let (trigger, _) = makeLogTrigger(phones)
        var appended = 0
        trigger.appendPhoneLogs = { _, _ in appended += 1 }

        let reply = try self.reply(trigger, #"{"op":"logs"}"#)
        // `ok: false` because nothing new is in the file, which is what a script branches on.
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "no_logs")
        let devices = try XCTUnwrap(reply["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.first?["device"] as? String, "iPhone")
        XCTAssertEqual(devices.first?["error"] as? String, "unsupported_peer")
        XCTAssertEqual(appended, 0, "a refusal must not write a block to the file")
    }

    /// Two phones, one of which cannot answer. A partial fetch is a success with one bad row
    /// in it — a top-level error there would have a script discard a file it should be reading.
    func testOnePhoneRefusingDoesNotSinkTheWholeFetch() throws {
        let phones = StubPhones()
        let good = phone("iPhone")
        let old = phone("iPad", caps: [])
        phones.attachedClients = [good, old]
        phones.answers[good.id] = .success(logs(["a", "b"], truncated: true))
        phones.answers[old.id] = .failure(.server(code: "unsupported_peer"))
        let (trigger, _) = makeLogTrigger(phones)
        var appended: [(WirePhoneLogs, String?)] = []
        trigger.appendPhoneLogs = { appended.append(($0, $1)) }

        let reply = try self.reply(trigger, #"{"op":"logs"}"#)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertNil(reply["error"])
        XCTAssertEqual(reply["entries"] as? Int, 2)
        let devices = try XCTUnwrap(reply["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(
            Set(devices.compactMap { $0["device"] as? String }), ["iPhone", "iPad"]
        )
        XCTAssertEqual(appended.map(\.1), ["iPhone"])
        XCTAssertEqual(appended.first?.0.truncated, true)
    }

    /// Nothing attached is its own answer, not an empty success: "no phone is connected" and
    /// "your phone had nothing to say" send a person to two different places.
    func testLogsWithNoPhoneAttachedSaysSoRatherThanReturningNothing() throws {
        let (trigger, _) = makeLogTrigger(StubPhones())
        let reply = try self.reply(trigger, #"{"op":"logs"}"#)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "no_phones")
    }

    /// The fleet service is gone — the app is shutting down, or was never listening. Named
    /// distinctly from `no_phones` so a caller can tell "nothing to ask" from "nothing to ask
    /// with".
    func testLogsWithNoFleetServiceIsRefusedByName() throws {
        let (trigger, _, _) = makeTrigger()
        trigger.phones = nil
        let reply = try self.reply(trigger, #"{"op":"logs"}"#)
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual(reply["error"] as? String, "stopped")
    }

    // MARK: - The file

    /// A header per fetch, even for an empty answer, and the phone's own timestamps kept
    /// verbatim. Restamping them on this Mac would put every entry of a fetch at one instant,
    /// which destroys the only thing these lines are for.
    func testTheFetchedLogIsAppendedWithThePhonesOwnTimestamps() throws {
        let url = socketRoot.appendingPathComponent("\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        PhoneLogFile.append(
            WirePhoneLogs(entries: [WirePhoneLogEntry(
                at: "2026-09-01T09:15:00.000+01:00", level: "notice", category: "prompt",
                message: "prompt derived=toolu_1 mac=toolu_2 shown=none"
            )], truncated: false),
            device: "iPhone", to: url
        )
        PhoneLogFile.append(
            WirePhoneLogs(entries: [], truncated: false), device: nil, to: url
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains(#"fetch device="iPhone" entries=1 truncated=false"#))
        XCTAssertEqual(
            lines[1],
            "2026-09-01T09:15:00.000+01:00 [prompt/notice]"
                + " prompt derived=toolu_1 mac=toolu_2 shown=none"
        )
        // The empty fetch still leaves a header: "the phone had nothing in the window" and
        // "the fetch never happened" are different facts.
        XCTAssertTrue(lines[2].contains(#"fetch device="-" entries=0 truncated=false"#))
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
        let socket = AnswerTriggerSocket(url: url) { line, reply in
            XCTAssertEqual(line.trimmingCharacters(in: .newlines), #"{"op":"ping"}"#)
            reply(#"{"ok":true,"op":"ping"}"#)
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

    /// The handler that answers *after* it returns, which is what the `logs` op does and what
    /// the socket had to grow a semaphore for. A synchronous `DispatchQueue.main.sync` would
    /// have written the caller an empty reply and closed the connection before the answer
    /// existed — the failure this shape exists to prevent, and one no in-process test of
    /// `AnswerTrigger` alone could see.
    func testASocketWaitsForAHandlerThatAnswersLater() throws {
        let url = socketRoot.appendingPathComponent("\(UUID().uuidString).sock")
        let socket = AnswerTriggerSocket(url: url) { _, reply in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                reply(#"{"ok":true,"op":"logs"}"#)
            }
        }
        try socket.start()
        defer { socket.stop() }

        let answered = expectation(description: "the socket waits")
        let received = Received()
        DispatchQueue.global().async {
            received.text = Self.roundTrip(#"{"op":"logs"}"#, to: url.path)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertEqual(
            received.text?.trimmingCharacters(in: .newlines), #"{"ok":true,"op":"logs"}"#
        )
    }

    /// **A path that will not fit is refused by name.** `sockaddr_un` does not truncate — it
    /// fails with `EINVAL`, which says nothing about a length — and the socket lives wherever
    /// `-FlightDeckStateDir` points, so this is reachable without doing anything unusual.
    func testAPathTooLongForAUnixSocketIsRefusedByName() {
        let long = "/tmp/" + String(repeating: "d", count: AnswerTriggerSocket.maxPathLength)
        let socket = AnswerTriggerSocket(url: URL(fileURLWithPath: long)) { _, reply in reply("") }
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
