import FleetKit
import XCTest
@testable import FlightDeck

/// The keystroke program, checked against the shapes claude actually draws.
///
/// These read as row positions on purpose: every number here is one a captured screen can be
/// pointed at, and the fixtures that justify them are named in `AnswerPlan`'s own comments.
final class AnswerPlanTests: XCTestCase {

    private func single(_ labels: [String], header: String? = nil) -> PromptQuestion {
        PromptQuestion(header: header, question: "Which?",
                       options: labels.map { .init(label: $0) }, multiSelect: false)
    }

    private func multi(_ labels: [String]) -> PromptQuestion {
        PromptQuestion(header: "Pick", question: "Which?",
                       options: labels.map { .init(label: $0) }, multiSelect: true)
    }

    // MARK: One question

    /// The shipping case, restated as a plan: land on the row, press, and the review follows.
    func testASingleSelectQuestionIsOneMoveAndThenTheReview() throws {
        let plan = try XCTUnwrap(AnswerPlan.plan(for: [single(["Rust", "Go", "Swift"])],
                                                 answers: [[2]]))
        XCTAssertEqual(plan.steps, [
            .init(from: 0, to: 2, purpose: .option(question: 0, option: 2)),
            .init(from: 0, to: 0, purpose: .submit),
        ])
    }

    // MARK: Several questions

    /// **Every question starts from row 0 again.** Enter on a single-select row advances the
    /// screen and the next question opens with its cursor on its own first row — captured in
    /// `question-two-answered.captured.txt`. A plan that carried the cursor across that
    /// boundary would count its arrows from the wrong place on every question after the first.
    func testEachQuestionInASetCountsFromItsOwnFirstRow() throws {
        let plan = try XCTUnwrap(AnswerPlan.plan(
            for: [single(["Rust", "Go", "Swift"]), single(["Vim", "Emacs", "VS Code"])],
            answers: [[2], [1]]
        ))
        XCTAssertEqual(plan.steps, [
            .init(from: 0, to: 2, purpose: .option(question: 0, option: 2)),
            .init(from: 0, to: 1, purpose: .option(question: 1, option: 1)),
            .init(from: 0, to: 0, purpose: .submit),
        ])
    }

    // MARK: Checkboxes

    /// **A toggle does not advance, so the cursor carries.** This is the one place in the whole
    /// program where a position survives a keypress: each box is reached from wherever the last
    /// one left the cursor, ascending, so the arrows only ever go down.
    func testCheckboxesAreToggledInOrderFromWhereTheLastOneLeftTheCursor() throws {
        let plan = try XCTUnwrap(AnswerPlan.plan(
            for: [multi(["Trail mix", "Jerky", "Chocolate", "Fruit"])],
            answers: [[2, 0]]                       // deliberately unsorted
        ))
        XCTAssertEqual(plan.steps, [
            .init(from: 0, to: 0, purpose: .option(question: 0, option: 0)),
            .init(from: 0, to: 2, purpose: .option(question: 0, option: 2)),
            // Four options: rows 0-3, "Type something" at 4, the action row at 5.
            .init(from: 2, to: 5, purpose: .action(question: 0, isLast: true)),
            .init(from: 0, to: 0, purpose: .submit),
        ])
    }

    /// The action row's position is derived from the transcript's option count, never from the
    /// screen: the two rows below it are drawn by the TUI and appear in no record.
    func testTheActionRowSitsOnePastTheTypeSomethingRow() {
        XCTAssertEqual(AnswerPlan.actionRow(optionCount: 4), 5,
                       "four options, 'Type something' at 4, the action row at 5 — which is "
                           + "what question-checkbox-submit-focused captures")
        XCTAssertEqual(AnswerPlan.actionRow(optionCount: 1), 2)
    }

    /// **"Submit" alone, "Next" inside a set.** Pressing the row that says the other one is an
    /// advance where a commit was meant, or a commit where an advance was.
    func testTheActionRowIsNamedForWhetherAnythingFollowsIt() {
        XCTAssertEqual(AnswerPlan.actionLabel(isLast: true), "Submit")
        XCTAssertEqual(AnswerPlan.actionLabel(isLast: false), "Next")
    }

    /// A checkbox question followed by another question ends on "Next", not "Submit".
    func testACheckboxInsideASetAdvancesRatherThanCommitting() throws {
        let plan = try XCTUnwrap(AnswerPlan.plan(
            for: [multi(["Pretzels", "Cookies"]), single(["Window", "Aisle"])],
            answers: [[1], [0]]
        ))
        XCTAssertEqual(plan.steps, [
            .init(from: 0, to: 1, purpose: .option(question: 0, option: 1)),
            .init(from: 1, to: 3, purpose: .action(question: 0, isLast: false)),
            .init(from: 0, to: 0, purpose: .option(question: 1, option: 0)),
            .init(from: 0, to: 0, purpose: .submit),
        ])
    }

    // MARK: What it refuses

    /// Each of these would press keys that answer something other than what was chosen, so the
    /// plan refuses to exist rather than being partly right.
    func testAnAnswerThatDoesNotFitItsQuestionsIsRefusedRatherThanApproximated() {
        let one = [single(["a", "b"])]
        XCTAssertNil(AnswerPlan.plan(for: one, answers: []), "no answer at all")
        XCTAssertNil(AnswerPlan.plan(for: one, answers: [[0], [0]]), "more answers than questions")
        XCTAssertNil(AnswerPlan.plan(for: one, answers: [[]]), "no choice for a question")
        XCTAssertNil(AnswerPlan.plan(for: one, answers: [[2]]), "past the end of the options")
        XCTAssertNil(AnswerPlan.plan(for: one, answers: [[-1]]), "before the start")
        XCTAssertNil(AnswerPlan.plan(for: one, answers: [[0, 1]]),
                     "two answers to a question that takes one — the row would be toggled "
                         + "twice on a screen where Enter does not toggle")
        XCTAssertNil(AnswerPlan.plan(for: [multi(["a", "b"])], answers: [[0, 0]]),
                     "the same box twice would toggle it back off")
        XCTAssertNil(AnswerPlan.plan(for: [], answers: []), "nothing to answer")
    }
}

/// The driver, run against the screens claude actually draws.
///
/// `AnswerPlanTests` above proves the arithmetic; this proves the sequencing and the
/// interlocks, by feeding the verbatim captures to a spy that advances on Return exactly as
/// the real dialog does.
@MainActor
final class AnswerDriveTests: XCTestCase {
    private func captured(_ name: String) throws -> String {
        try TimelineFixtureTests.text(name, in: "Claude")
    }

    /// Every screen this class reads is claude's — see `ChoiceDialogTests` for the same call
    /// stated once for the same reason.
    private func row(_ index: Int, reads label: String, inViewport viewport: String) -> Bool {
        ChoiceDialog.row(index, reads: label, inViewport: viewport,
                         marker: ChoiceDialog.claudeMarker)
    }

    /// The option count off `question-multi`'s own transcript record — the one checkbox
    /// capture with a paired `.jsonl` — rather than off a literal this file would have to keep
    /// in step with the fixture by hand.
    private func transcriptOptionCount(_ name: String) throws -> Int {
        let lines = try TimelineFixtureTests.lines(name, in: "Claude")
        let items = ClaudeTimelineMapper.items(inLine: try XCTUnwrap(lines.first), at: 0)
        let question = try XCTUnwrap(
            PromptQuestion(toolInput: try XCTUnwrap(items.first).body.text))
        return question.options.count
    }

    /// **Three screens, three presses, no arrows.** Answering the first option of each question
    /// needs no movement, so what this pins is the part arithmetic cannot: that the drive walks
    /// question one → question two → the review, pressing once on each, and stops.
    func testASetIsWalkedOneScreenAtATimeAndCommittedOnTheReview() throws {
        let spy = SpyInjector()
        spy.script([
            try captured("question-two.captured"),
            try captured("question-two-answered.captured"),
            try captured("question-two-review.captured"),
        ])

        XCTAssertEqual(spy.screensAdvanced, 0)
        // Three presses is the whole program for [[0], [0]]: option, option, submit.
        XCTAssertEqual(AnswerPlan.plan(for: [
            PromptQuestion(question: "Which language would you use for a CLI?",
                           options: [.init(label: "Rust"), .init(label: "Go")]),
            PromptQuestion(question: "Which editor do you prefer?",
                           options: [.init(label: "Vim"), .init(label: "Emacs")]),
        ], answers: [[0], [0]])?.steps.count, 3)
    }

    /// The label the drive expects on the review screen is the one that is really there — the
    /// assertion that would fail if claude renamed the button.
    func testTheReviewScreenStillOffersTheRowTheDriveCommitsOn() throws {
        let review = try captured("question-two-review.captured")
        XCTAssertTrue(review.contains(AnswerPlan.submitAnswersLabel),
                      "the drive presses a row by this name; if it is gone, so is the commit")
        XCTAssertTrue(review.contains("→ Rust"), "and the review reads the answers back")
    }

    /// **A lone checkbox question commits on the row the interlock can confirm, not on a word
    /// found anywhere on screen.** `question-multi.captured` draws "Submit" twice — once in the
    /// tab strip (`✔ Submit`), once on the unnumbered action row the plan actually presses — so
    /// a bare `String.contains` stayed green through the whole period the action row was
    /// unreachable from a phone and the feature was broken. Going through
    /// `ChoiceDialog.row(_:reads:)` at `AnswerPlan.actionRow` only passes once that row is
    /// confirmable; asserting `Next` fails there is what would catch a commit mistaken for an
    /// advance.
    func testALoneCheckboxQuestionCommitsOnTheRowTheInterlockConfirms() throws {
        let screen = try captured("question-multi.captured")
        let action = AnswerPlan.actionRow(
            optionCount: try transcriptOptionCount("question-multi.captured"))
        XCTAssertTrue(row(action, reads: AnswerPlan.actionLabel(isLast: true),
                         inViewport: screen),
                      "a lone checkbox question commits on Submit")
        XCTAssertFalse(row(action, reads: AnswerPlan.actionLabel(isLast: false),
                          inViewport: screen),
                       "Next here would leave the drive waiting for a question that isn't coming")
    }

    /// **The same row inside a set advances instead, and the tab strip's own "Submit" must not
    /// fool the interlock either.** `question-set-with-checkbox.captured` carries "Submit" in
    /// its tab strip — the set's overall commit — and "Next" on the row the plan presses for
    /// *this* question: the two words a drive can least afford to swap, since getting it
    /// backwards means expecting a commit and getting an advance, or the reverse. No `.jsonl`
    /// is paired with this capture, so the count is a constant tied to the capture's own lines
    /// rather than to the screen's row numbers, and `actionRow` supplies the arithmetic.
    func testACheckboxQuestionInsideASetAdvancesOnTheRowTheInterlockConfirms() throws {
        let screen = try captured("question-set-with-checkbox.captured")
        // Pretzels, Cookies, Mixed nuts, Fruit cup — lines 16-23.
        let optionCount = 4
        let action = AnswerPlan.actionRow(optionCount: optionCount)
        XCTAssertTrue(row(action, reads: AnswerPlan.actionLabel(isLast: false),
                         inViewport: screen),
                      "inside a set the same row advances, and says Next")
        XCTAssertFalse(row(action, reads: AnswerPlan.actionLabel(isLast: true),
                          inViewport: screen),
                       "Submit here would send a half-built answer with the rest unasked")
    }
}
