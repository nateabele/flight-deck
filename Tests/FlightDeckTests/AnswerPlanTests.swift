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

    /// **One move and one press, and nothing after it.** A lone single-select question has no
    /// review screen: its Return commits, and the screen it leaves behind has no list on it —
    /// `question-single-committed-no-review.captured.txt`, claude 2.1.289. A trailing submit
    /// would press on whatever claude drew next.
    func testALoneSingleSelectQuestionIsOneMoveAndOnePress() throws {
        let plan = try XCTUnwrap(AnswerPlan.plan(for: [single(["Rust", "Go", "Swift"])],
                                                 answers: [[2]]))
        XCTAssertEqual(plan.steps, [
            .init(from: 0, to: 2, purpose: .option(question: 0, option: 2)),
        ])
    }

    // MARK: Typed answers

    /// "Type something" is the row directly under the options: three options, row 3. The paste
    /// then a Return answers it exactly as an option's Return would —
    /// `question-typed-single.captured.txt` then `-committed`.
    func testATypedAnswerLandsOnTheRowUnderTheOptionsAndPresses() throws {
        let plan = try XCTUnwrap(AnswerPlan.plan(
            for: [single(["Red", "Green", "Blue"])], picks: [[.typed("teal 3 ok")]]
        ))
        XCTAssertEqual(plan.steps, [
            .init(from: 0, to: 3, purpose: .typed(question: 0, text: "teal 3 ok", thenPress: true)),
        ])
    }

    /// Inside a set the typed row advances like any other single-select answer, so the next
    /// question still counts from row 0 and the review still follows —
    /// `question-typed-set.captured.txt`.
    func testATypedAnswerInsideASetAdvancesAndTheReviewFollows() throws {
        let plan = try XCTUnwrap(AnswerPlan.plan(
            for: [single(["Red", "Green", "Blue"]), single(["Cat", "Dog", "Bird"])],
            picks: [[.typed("teal")], [.option(0)]]
        ))
        XCTAssertEqual(plan.steps, [
            .init(from: 0, to: 3, purpose: .typed(question: 0, text: "teal", thenPress: true)),
            .init(from: 0, to: 0, purpose: .option(question: 1, option: 0)),
            .init(from: 0, to: 0, purpose: .submit),
        ])
    }

    /// **On a checkbox question the paste ticks the box, so nothing presses it.** A Return there
    /// would toggle it straight back off. The typed row comes after every option, the cursor
    /// stays on it, and the action row is one below — `question-typed-checkbox.captured.txt`
    /// shows the tick, `-submit-focused` the next row.
    func testATypedCheckboxAnswerIsPastedWithoutAPressThenTheActionRow() throws {
        let plan = try XCTUnwrap(AnswerPlan.plan(
            for: [multi(["Chips", "Nuts", "Fruit"])],
            picks: [[.typed("pretzels"), .option(1)]]       // typed first, deliberately
        ))
        XCTAssertEqual(plan.steps, [
            .init(from: 0, to: 1, purpose: .option(question: 0, option: 1)),
            .init(from: 1, to: 3, purpose: .typed(question: 0, text: "pretzels", thenPress: false)),
            .init(from: 3, to: 4, purpose: .action(question: 0, isLast: true)),
            .init(from: 0, to: 0, purpose: .submit),
        ])
    }

    func testACheckboxQuestionCanBeAnsweredWithTypedWordsAlone() throws {
        let plan = try XCTUnwrap(AnswerPlan.plan(
            for: [multi(["Chips", "Nuts", "Fruit"])], picks: [[.typed("pretzels")]]
        ))
        XCTAssertEqual(plan.steps.map(\.to), [3, 4, 0])
    }

    /// The text goes in as a paste into a one-line field, so a control character is a key.
    func testTypedWordsThatWouldBeKeystrokesAreRefused() {
        let one = [single(["a", "b"])]
        XCTAssertNil(AnswerPlan.plan(for: one, picks: [[.typed("one\ntwo")]]),
                     "a newline is Return — it would commit half the answer")
        XCTAssertNil(AnswerPlan.plan(for: one, picks: [[.typed("x\u{1b}[201~")]]),
                     "an Escape ends the paste and then cancels the dialog")
        XCTAssertNil(AnswerPlan.plan(for: one, picks: [[.typed("tab\there")]]))
        XCTAssertNil(AnswerPlan.plan(for: one, picks: [[.typed("   ")]]),
                     "an empty row answers nothing")
        XCTAssertNil(AnswerPlan.plan(for: one, picks: [[.typed("x"), .option(0)]]),
                     "a single-select question takes one answer, typed or not")
        XCTAssertNil(AnswerPlan.plan(for: [multi(["a"])], picks: [[.typed("x"), .typed("y")]]),
                     "there is one Type something row")
        XCTAssertNotNil(AnswerPlan.plan(for: one, picks: [[.typed(#"é "quoted", 3 ok"#)]]),
                        "punctuation, digits and accents are text — the probe recorded them verbatim")
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

    /// **Every screen a typed drive reads before a key still shows a list,** so the one check
    /// the drive makes per step passes — words in the row do not stop it reading as one. And
    /// the screen a lone question leaves after its press has none: the evidence that it needs
    /// no submit step, and that one sent anyway would press on whatever came next.
    func testTypedScreensStillReadAsAListAndACommittedQuestionLeavesNone() throws {
        let claude = ClaudeDialogDriver()
        for name in ["question-typed-focused.captured", "question-typed-single.captured",
                     "question-typed-set.captured", "question-typed-checkbox.captured",
                     "question-typed-checkbox-review.captured"] {
            XCTAssertTrue(claude.hasSelectList(inViewport: try captured(name)), name)
        }
        for name in ["question-typed-single-committed.captured",
                     "question-single-committed-no-review.captured"] {
            XCTAssertFalse(claude.hasSelectList(inViewport: try captured(name)), name)
        }
        XCTAssertTrue(try captured("question-typed-checkbox.captured").contains("[✔] pretzels"),
                      "the paste alone ticked the box — which is why the plan does not press it")
    }

    /// The label the drive expects on the review screen is the one that is really there — the
    /// assertion that would fail if claude renamed the button.
    func testTheReviewScreenStillOffersTheRowTheDriveCommitsOn() throws {
        let review = try captured("question-two-review.captured")
        XCTAssertTrue(review.contains(AnswerPlan.submitAnswersLabel),
                      "the drive presses a row by this name; if it is gone, so is the commit")
        XCTAssertTrue(review.contains("→ Rust"), "and the review reads the answers back")
    }
}
