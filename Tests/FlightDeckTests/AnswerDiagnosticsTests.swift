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
        var defaultFontSize: Float { 12 }
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

    private var permission: OpenPrompt {
        .permission(callID: "toolu_B", tool: "Bash", summary: "rm -rf build")
    }

    // MARK: The early guards — before any plan step exists

    /// The set path's label cross-check, isolated from the drive it would otherwise have to
    /// pass through first. The mismatch is what refuses, so the record has to name it as such
    /// rather than folding it into one of `perform`'s own checks.
    func testASetAnswerWhoseLabelDisagreesWithTheMacsCopyNamesItself() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No"], selected: 0)
        store.answerPrompt(
            .question(callID: "toolu_A", single(["Yes", "No"])),
            with: .answers([[AnswerSelection(index: 0, label: "Wrong")]]), in: id, token: UUID()
        )

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .setLabelMismatch)
        XCTAssertEqual(abort.expected, "Yes")
        XCTAssertNil(abort.step)
        XCTAssertEqual(abort.from, 0)
        XCTAssertEqual(abort.to, 0)
        XCTAssertNotNil(abort.viewport)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// The one-question path's own label cross-check, the same mismatch through `.option`
    /// instead of `.answers`.
    func testAnOptionAnswerWhoseLabelDisagreesWithTheMacsCopyNamesItself() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No"], selected: 0)
        store.answerPrompt(
            .question(callID: "toolu_A", single(["Yes", "No"])),
            with: .option(index: 1, label: "Wrong"), in: id, token: UUID()
        )

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .optionLabelMismatch)
        XCTAssertEqual(abort.expected, "No")
        XCTAssertNotNil(abort.viewport)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// A set answer against a permission dialog — there is no question for it to fit.
    func testASetAnswerAgainstAPermissionDialogNamesItself() throws {
        let (store, spy, id, log) = makeStore()
        store.answerPrompt(
            permission, with: .answers([[AnswerSelection(index: 0, label: "Yes")]]),
            in: id, token: UUID()
        )

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .setNotQuestion)
        XCTAssertNil(abort.expected)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// `.option` against a permission dialog, the same refusal on the other answer shape.
    func testAnOptionAnswerAgainstAPermissionDialogNamesItself() throws {
        let (store, spy, id, log) = makeStore()
        store.answerPrompt(permission, with: .option(index: 0, label: "Yes"), in: id, token: UUID())

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .optionNotQuestion)
        XCTAssertTrue(spy.events.isEmpty)
    }

    /// A tab with no surface at all — `injector(for:)` itself returns nil, before any screen
    /// could be read. No viewport is possible, so the record carries none.
    func testATabWithNoSurfaceNamesTheMissingInjector() throws {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.transcriptsRootOverride = projectsRoot
        store.codexIndexURLOverride = projectsRoot.appendingPathComponent("session_index.jsonl")
        store.injectionSettle = { $0() }
        let recorder = Recorder()
        store.answerAbortSink = { recorder.aborts.append($0) }
        let session = store.newSession(in: tmp)
        store.applyRegistry([1: entry(session.pinnedConversationID, .waiting, cwd: tmp.path)])
        XCTAssertNil(store.viewport(of: session.id), "no surface, nothing to read")

        store.answerPrompt(permission, with: .deny, in: session.id, token: UUID())

        let abort = try XCTUnwrap(recorder.aborts.first)
        XCTAssertEqual(abort.check, .noInjector)
        XCTAssertNil(abort.viewport)
        XCTAssertNil(abort.focused)
    }

    // MARK: The two checks in `perform`

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

    /// **A screen with no select list on it at all.** The one check `perform` still makes, and
    /// the only thing it can now say: the record carries the step, the purpose and the screen,
    /// and nothing about a row, because no row was read.
    func testAScreenWithNoSelectListNamesItselfAndCarriesTheScreen() throws {
        let (store, spy, id, log) = makeStore()   // no `showOptions`: the input bar is up
        drive(store, single(["Yes", "No"]), [[0]], in: id)

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(log.aborts.count, 1, "one abort, and the drive stops")
        XCTAssertEqual(abort.check, .noDialogOnScreen)
        XCTAssertEqual(abort.step, 0)
        XCTAssertEqual(abort.purpose, .option(question: 0, option: 0))
        XCTAssertNil(abort.expected, "no label was compared, so none is claimed")
        XCTAssertNil(abort.focused, "and no row was read")
        XCTAssertNotNil(abort.viewport, "the screen it refused against, verbatim")
        XCTAssertTrue(spy.events.isEmpty, "and no key was sent")
    }

    /// **The cursor somewhere else no longer refuses, and this is the record of that.** It used
    /// to file `pre-press-cursor`: `focusedRow` disagreed with `step.from`, and the drive
    /// stopped. It stopped on a real dialog too — a wrapped option description is enough to
    /// make `focusedRow` nil — so the check went and the plan drives regardless. `AnswerPlan`
    /// computed these keystrokes from the transcript; the screen is not consulted about them.
    func testACursorSomewhereElseNoLongerStopsTheDrive() {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 2)
        drive(store, single(["Yes", "No", "Maybe"]), [[0]], in: id)

        XCTAssertTrue(log.aborts.isEmpty, "nothing refused")
        XCTAssertEqual(spy.events, [.ret, .ret],
                       "the plan's step 0 is 0→0, so it presses where it planned to, "
                       + "then presses again on the review")
    }

    /// The same for the label: a row reading something else is no longer compared, so there is
    /// nothing to refuse. What the Mac's copy IS still checked against is the phone's own claim
    /// — `setLabelMismatch` above — which happens before any screen is read.
    func testARowThatReadsSomethingElseNoLongerStopsTheDrive() {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "Something else entirely"], selected: 0)
        drive(store, single(["Yes", "No"]), [[1]], in: id)

        XCTAssertTrue(log.aborts.isEmpty)
        XCTAssertEqual(spy.events, [.arrow(1), .ret, .ret])
    }

    /// **The observed failure, and what became of it.** A four-option multiSelect question with
    /// boxes 0 and 1 chosen: both ticks land, and then the action row two rows below the last
    /// option is not on this screen — the spy draws four rows and no `Submit`. That used to be
    /// caught by the label check and named `purpose=action expected="Submit"`.
    ///
    /// **It is not caught any more, and saying so is the point of keeping this test.** The
    /// drive sends its four Downs into a four-row list, the marker stops at the bottom, and
    /// Return goes out there. What bounds that is not this file: `.answers` commits nothing
    /// until the review screen, so a mis-landed press leaves a dialog a person can still
    /// finish — which is the trade `SessionStore.drive(_:driver:injector:id:token:)` documents,
    /// and the reason `.allow` did not make it.
    func testAMissingActionRowNoLongerStopsACheckboxDrive() {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Rust", "Go", "Swift", "Zig"], selected: 0)
        drive(store, multi(["Rust", "Go", "Swift", "Zig"]), [[0, 1]], in: id)

        XCTAssertTrue(log.aborts.isEmpty)
        XCTAssertEqual(
            spy.events,
            [.ret, .arrow(1), .ret, .arrow(1), .arrow(1), .arrow(1), .arrow(1), .ret, .ret],
            "two ticks, then four Downs for the action row the plan computed, then the review"
        )
    }

    /// **The arrows went out and the marker did not follow, and the planned drive presses
    /// anyway.** It used to re-read after the move and file `post-move-landing`; the re-read is
    /// gone with the rest of the per-step screen reading. The residual is bounded the same way
    /// everything else on this path is — nothing commits before the review screen.
    ///
    /// `.allow` and `.option` still have this check: they walk `drive(from:to:confirm:)`, which
    /// is unchanged, and the two tests further down assert it there.
    func testAMarkerThatDidNotFollowTheArrowsNoLongerStopsThePlannedDrive() {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        spy.ignoreArrowsAfter = 0
        drive(store, single(["Yes", "No", "Maybe"]), [[2]], in: id)

        XCTAssertTrue(log.aborts.isEmpty)
        XCTAssertEqual(spy.selected, 0, "the fixture is only meaningful if nothing moved")
        XCTAssertEqual(spy.events, [.arrow(1), .arrow(1), .ret, .ret])
    }

    /// A screen readable before the arrows and not after — the settle is where that happens, so
    /// that is where the test breaks it. There is no post-move read left to fail, so the press
    /// goes out and the NEXT step is what finds the terminal unreadable, before its own press.
    /// That is the same refusal a step later, which is why the drive still stops.
    func testAScreenThatGoesUnreadableAfterTheMoveStopsAtTheNextStep() throws {
        let (store, spy, id, log) = makeStore()
        spy.showOptions(["Yes", "No", "Maybe"], selected: 0)
        store.injectionSettle = { work in
            spy.viewportIsReadable = false
            work()
        }
        drive(store, single(["Yes", "No", "Maybe"]), [[1]], in: id)

        let abort = try XCTUnwrap(log.aborts.first)
        XCTAssertEqual(abort.check, .unreadableBeforePress)
        XCTAssertEqual(abort.step, 1)
        XCTAssertEqual(abort.purpose, .submit)
        XCTAssertNil(abort.viewport)
        XCTAssertEqual(spy.events, [.arrow(1), .ret], "moved, pressed, and stopped there")
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
    ///
    /// **Hand-assembled to exercise every field at once, which no single check files today:**
    /// `no-dialog-on-screen` carries the step and the purpose and neither of the row fields,
    /// while the checks that do carry `expected` and `focused` are early aborts with no step.
    /// This is a test of the FORMAT, not a claim about a record production writes.
    func testTheSummaryLineNamesEveryFieldAndOmitsTheViewport() {
        let abort = AnswerAbort(
            check: .noDialogOnScreen, step: 2, purpose: .action(question: 0, isLast: true),
            from: 1, to: 5, expected: "Submit", focused: 1,
            viewport: "a secret the terminal happened to be showing"
        )
        XCTAssertEqual(
            abort.summary,
            #"answer abort check=no-dialog-on-screen step=2 purpose=action(q0,Submit) from=1 to=5 focused=1 expected="Submit""#
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
            AnswerAbort(check: .noDialogOnScreen, step: 0,
                        purpose: .option(question: 0, option: 0), from: 0, to: 0,
                        expected: nil, focused: nil, viewport: "row one\nrow two"),
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
        XCTAssertTrue(text.contains("check=no-dialog-on-screen"))
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
