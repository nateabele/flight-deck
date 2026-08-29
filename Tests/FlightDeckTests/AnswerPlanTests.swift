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
