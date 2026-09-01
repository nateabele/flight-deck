import FleetKit
import XCTest
@testable import FlightDeck

/// What an aborted drive says about itself.
///
/// **These are tests about EVIDENCE, not about behaviour.** Every case below is a drive that
/// already refused correctly — `AnswerPromptTests` owns those assertions — and what is pinned
/// here is that the refusal named itself: which check, which step, which row, and the screen it
/// was looking at. The whole reason this exists is that a real four-option checkbox question
/// ticked one box on a Release build and stopped, and there was nothing to read afterwards.
@MainActor
final class AnswerDiagnosticsTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private var projectsRoot: URL!
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    override func setUpWithError() throws {
        projectsRoot = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity, cwd: String)
        -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: "start-a")
    }

    /// The same waiting claude tab `AnswerPromptTests.makeStore` builds, with the sink
    /// redirected into an array so a test can read what production would have written.
    private func makeStore() -> (SessionStore, SpyInjector, UUID, Recorder) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        let spy = SpyInjector()
        store.injectorOverride = spy
        store.injectionSettle = { $0() }
        let recorder = Recorder()
        store.answerAbortSink = { recorder.aborts.append($0) }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, .waiting, cwd: tmp.path)])
        spy.events.removeAll()
        return (store, spy, session.id, recorder)
    }

    /// A class so the sink closure and the test read the same array.
    private final class Recorder {
        var aborts: [AnswerAbort] = []
    }

    private func single(_ labels: [String]) -> [PromptQuestion] {
        [PromptQuestion(header: "Pick", question: "Which?",
                        options: labels.map { .init(label: $0) })]
    }

    private func multi(_ labels: [String]) -> [PromptQuestion] {
        [PromptQuestion(header: "Pick", question: "Which?",
                        options: labels.map { .init(label: $0) }, multiSelect: true)]
    }

    private func answer(_ questions: [PromptQuestion], _ chosen: [[Int]]) -> PromptAnswer {
        .answers(zip(questions, chosen).map { question, picks in
            picks.map { AnswerSelection(index: $0, label: question.options[$0].label) }
        })
    }

    private func drive(
        _ store: SessionStore, _ questions: [PromptQuestion], _ chosen: [[Int]], in id: UUID
    ) {
        store.answerPrompt(.question(callID: "toolu_A", questions),
                           with: answer(questions, chosen), in: id, token: UUID())
    }

    // MARK: The four checks in `perform`

    /// A terminal that cannot be read at all, before a key moves. Nothing to quote, so the
    /// record says so rather than carrying an empty screen that would read like a blank one.
    func testAnUnreadableScreenBeforeThePressNamesItselfAndCarriesNoViewport() throws {
        let (store, spy, id, log) = makeStore()
        spy.viewportIsReadable = false
        let questions = single(["Yes", "No"])
        drive(store, questions, [[0]], in: id)

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(log.aborts.count, 1, "one abort, and the drive stops")
        XCTAssertEqual(abort.check, .unreadableBeforePress)
        XCTAssertEqual(abort.step, 0)
        XCTAssertEqual(abort.purpose, .option(question: 0, option: 0))
        XCTAssertNil(abort.viewport)
        XCTAssertNil(abort.focused)
        XCTAssertTrue(spy.events.isEmpty, "and no key was sent")
    }

    /// The cursor is not where the plan says the step starts. The number it actually returned
    /// is the field that diagnoses this — "somewhere else" is what we already knew.
    func testACursorSomewhereElseReportsWhereItActuallyWas() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 2)
        drive(store, single(["Yes", "No", "Maybe"]), [[0]], in: id)

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .cursorBeforePress)
        XCTAssertEqual(abort.focused, 2)
        XCTAssertEqual(abort.from, 0)
        XCTAssertEqual(abort.to, 0)
        XCTAssertEqual(try XCTUnwrap(abort.viewport).contains("Maybe"), true,
                       "the screen the check refused against, verbatim")
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The row about to be pressed reads something else. The expected label goes in verbatim,
    /// because a stripped glyph or a trailing space is exactly the difference to be found here.
    func testARowThatReadsSomethingElseCarriesTheExpectedLabelVerbatim() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "Something else entirely"], selected: 0)
        drive(store, single(["Yes", "No"]), [[1]], in: id)

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .labelBeforePress)
        XCTAssertEqual(abort.expected, "No")
        XCTAssertEqual(abort.focused, 0, "the cursor was fine; the label was not")
        XCTAssertEqual(abort.to, 1)
        XCTAssertEqual(try XCTUnwrap(abort.viewport).contains("Something else entirely"), true)
    }

    /// **The observed failure, reproduced.** A four-option multiSelect question with boxes 0
    /// and 1 chosen: both ticks land, and then the action row two rows below the last option is
    /// not on this screen. Without the record there is no way to tell this from a dropped
    /// keystroke; with it, `purpose=action` and `expected="Submit"` say which row went missing.
    func testTheMissingActionRowOfACheckboxQuestionIsNamedAsSuch() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Rust", "Go", "Swift", "Zig"], selected: 0)
        drive(store, multi(["Rust", "Go", "Swift", "Zig"]), [[0, 1]], in: id)

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .labelBeforePress)
        XCTAssertEqual(abort.step, 2, "two ticks landed; the third step is the action row")
        XCTAssertEqual(abort.purpose, .action(question: 0, isLast: true))
        XCTAssertEqual(abort.expected, "Submit")
        XCTAssertEqual(abort.from, 1)
        XCTAssertEqual(abort.to, AnswerPlan.actionRow(optionCount: 4))
        XCTAssertEqual(abort.focused, 1, "the cursor sat on the second box it had just ticked")
        XCTAssertEqual(spy.events, [.ret, .arrow(1), .ret],
                       "unchanged behaviour: two ticks, and nothing after the refusal")
    }

    /// The arrows went out and the marker did not follow — a keystroke the TUI dropped, or a
    /// repaint that has not landed. Reported after the move, with the row it stopped on.
    func testAMarkerThatDidNotFollowTheArrowsReportsWhereItStopped() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        spy.ignoreArrowsAfter = 0
        drive(store, single(["Yes", "No", "Maybe"]), [[2]], in: id)

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .landingAfterMove)
        XCTAssertEqual(abort.focused, 0, "still on the row it started from")
        XCTAssertEqual(abort.to, 2)
        XCTAssertEqual(abort.expected, "Maybe")
        XCTAssertNotNil(abort.viewport)
        XCTAssertFalse(spy.events.contains(.ret), "unchanged behaviour: no Return")
    }

    /// A screen readable before the arrows and not after — the settle is where that happens,
    /// so that is where the test breaks it.
    func testAScreenThatGoesUnreadableAfterTheMoveIsItsOwnCase() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        store.injectionSettle = { work in
            spy.viewportIsReadable = false
            work()
        }
        drive(store, single(["Yes", "No", "Maybe"]), [[1]], in: id)

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .unreadableAfterMove)
        XCTAssertEqual(abort.expected, "No")
        XCTAssertNil(abort.viewport)
        XCTAssertEqual(spy.events, [.arrow(1)], "unchanged behaviour: moved, then no Return")
    }

    // MARK: The one-step drive

    /// `.option` walks no plan, so its record has no step and no purpose — and the marker's
    /// position is the one thing that can still be said about a composed `confirm`'s refusal.
    func testTheOneStepDriveReportsAConfirmationFailureWithNoPlanStep() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        spy.ignoreArrowsAfter = 1
        store.answerPrompt(
            .question(callID: "toolu_A", single(["Yes", "No", "Maybe"])),
            with: .option(index: 2, label: "Maybe"), in: id, token: UUID()
        )

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .landingAfterMove)
        XCTAssertNil(abort.step)
        XCTAssertNil(abort.purpose)
        XCTAssertEqual(abort.from, 0)
        XCTAssertEqual(abort.to, 2)
        XCTAssertEqual(abort.focused, 1, "one arrow was honoured, the second was not")
        XCTAssertNotNil(abort.viewport)
        XCTAssertFalse(spy.events.contains(.ret))
    }

    func testTheOneStepDriveReportsAnUnreadableScreenAfterTheMove() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No"], selected: 0)
        store.injectionSettle = { work in
            spy.viewportIsReadable = false
            work()
        }
        store.answerPrompt(
            .question(callID: "toolu_A", single(["Yes", "No"])),
            with: .option(index: 1, label: "No"), in: id, token: UUID()
        )

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .unreadableAfterMove)
        XCTAssertNil(abort.focused)
        XCTAssertNil(abort.viewport)
        XCTAssertEqual(spy.events, [.arrow(1)])
    }

    /// A drive that lands sends its Return and files nothing. The record is for aborts alone;
    /// a log that also described successes would bury the four lines worth reading.
    func testASuccessfulDriveRecordsNothing() {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No"], selected: 0)
        store.answerPrompt(.question(callID: "toolu_A", single(["Yes", "No"])),
                           with: .option(index: 1, label: "No"), in: id, token: UUID())
        XCTAssertEqual(spy.events, [.arrow(1), .ret])
        XCTAssertTrue(log.aborts.isEmpty)
    }

    // MARK: The summary line, and the file

    /// os_log truncates, so the summary carries the fields and NOT the screen — the split that
    /// makes the file worth having. It also keeps the user's terminal out of the unified log,
    /// which is readable by more than the person at this keyboard.
    func testTheSummaryLineNamesEveryFieldAndOmitsTheViewport() {
        let abort = AnswerAbort(
            check: .labelBeforePress, step: 2, purpose: .action(question: 0, isLast: true),
            from: 1, to: 5, expected: "Submit", focused: 1,
            viewport: "a secret the terminal happened to be showing"
        )
        XCTAssertEqual(
            abort.summary,
            #"answer abort check=pre-press-label step=2 purpose=action(q0,Submit) from=1 to=5 focused=1 expected="Submit""#
        )
        XCTAssertFalse(abort.summary.contains("secret"), "the screen never goes to os_log")
    }

    func testTheSummaryOfTheOneStepDriveReadsWithoutAStepOrAPurpose() {
        let abort = AnswerAbort(
            check: .unreadableAfterMove, step: nil, purpose: nil, from: 0, to: 2,
            expected: nil, focused: nil, viewport: nil
        )
        XCTAssertEqual(
            abort.summary,
            "answer abort check=unreadable-viewport-after-move step=- purpose=- from=0 to=2 focused=nil expected=-"
        )
    }

    /// **Appended, and delimited.** Two aborts in a row have to come apart again, and the
    /// screens are multi-line, so the markers are what makes the file readable at all.
    func testTwoRecordsAppendAndComeApartAgain() throws {
        let url = projectsRoot.appendingPathComponent("logs/answer.log")
        AnswerAbortLog.write(
            AnswerAbort(check: .cursorBeforePress, step: 0,
                        purpose: .option(question: 0, option: 0), from: 0, to: 0,
                        expected: nil, focused: 3, viewport: "row one\nrow two"),
            to: url
        )
        AnswerAbortLog.write(
            AnswerAbort(check: .landingAfterMove, step: 1, purpose: .submit, from: 0, to: 0,
                        expected: "Submit answers", focused: nil, viewport: "later screen"),
            to: url
        )

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "--- viewport begin ---").count - 1, 2,
                       "the directory was created and the second write appended")
        XCTAssertTrue(text.contains("row one\nrow two"), "the screen goes in whole")
        XCTAssertTrue(text.contains("later screen"))
        XCTAssertTrue(text.contains("check=pre-press-cursor"))
        XCTAssertTrue(text.contains(#"expected="Submit answers""#))
        let firstDump = try XCTUnwrap(
            text.components(separatedBy: "--- viewport begin ---").dropFirst().first?
                .components(separatedBy: "--- viewport end ---").first
        )
        XCTAssertEqual(firstDump.trimmingCharacters(in: .whitespacesAndNewlines), "row one\nrow two")
    }

    /// An unreadable screen leaves a record that says so, rather than an empty dump that reads
    /// like a blank terminal.
    func testAnAbortWithNoScreenSaysWhyTheDumpIsEmpty() throws {
        let url = projectsRoot.appendingPathComponent("logs/answer.log")
        AnswerAbortLog.write(
            AnswerAbort(check: .unreadableBeforePress, step: 0, purpose: .submit,
                        from: 0, to: 0, expected: nil, focused: nil, viewport: nil),
            to: url
        )
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("readViewport()"))
    }

    /// A log that cannot be written changes nothing. This runs inside a drive someone is
    /// waiting on, so the write is best-effort by construction.
    func testAWriteToAnImpossiblePathIsSwallowed() {
        AnswerAbortLog.write(
            AnswerAbort(check: .landingAfterMove, step: nil, purpose: nil, from: 0, to: 1,
                        expected: nil, focused: nil, viewport: "screen"),
            to: URL(fileURLWithPath: "/dev/null/not-a-directory/answer.log")
        )
    }

    /// Production's own destination, asserted because it is the path a person is told to read.
    func testTheProductionLogLivesInTheUsersLogsFolder() {
        XCTAssertEqual(AnswerAbortLog.fileURL.path,
                       FileManager.default.homeDirectoryForCurrentUser
                           .appendingPathComponent("Library/Logs/flight-deck-answer.log").path)
    }
}
