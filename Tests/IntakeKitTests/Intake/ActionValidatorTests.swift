import XCTest
import IntakeKit

/// `ActionValidator` (R6): a thread's actions are checked against the plan they target, and a
/// diff is kept only when its quote is found exactly once.
final class ActionValidatorTests: XCTestCase {
    static let plan = """
    # Plan

    ## Storage
    Retry the upload. Use SQLite for the queue.

    ## Sync
    Retry the upload. The client races the first sync.
    """

    private func diff(_ quote: String, prefix: String = "", suffix: String = "", replacement: String = "X",
                      checkpoint: Int = 4) -> ThreadAction {
        .proposeDiff(ProposedThreadDiff(checkpoint: checkpoint, quote: quote, prefix: prefix, suffix: suffix,
                                        replacement: replacement))
    }

    private func validate(_ actions: [ThreadAction]) -> ActionValidator.Outcome {
        ActionValidator.validate(actions, checkpoint: 4, plan: Self.plan)
    }

    func testAQuoteFoundOnceIsLocated() throws {
        let outcome = validate([diff("Use SQLite for the queue.", replacement: "Use a file queue.")])
        XCTAssertTrue(outcome.isValid, "\(outcome.errors)")
        let located = try XCTUnwrap(outcome.diffs.first)
        XCTAssertEqual(located.old, "Use SQLite for the queue.")
        XCTAssertEqual(located.anchor.checkpoint, 4)
        XCTAssertEqual(located.anchor.section, "## Storage")
        XCTAssertEqual(located.index, 0)
    }

    /// The same words in two sections, with no context to pick one: refused, never guessed.
    func testAnAmbiguousQuoteIsRefused() {
        let outcome = validate([diff("Retry the upload.")])
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(outcome.errors[0].contains("ambiguous: the quote matches 2 places"), outcome.errors[0])
        XCTAssertTrue(outcome.diffs.isEmpty)
    }

    /// Context that picks one copy makes it unambiguous.
    func testContextPicksOneCopy() throws {
        let outcome = validate([diff("Retry the upload.", suffix: " The client")])
        XCTAssertTrue(outcome.isValid, "\(outcome.errors)")
        XCTAssertEqual(outcome.diffs.first?.anchor.section, "## Sync")
    }

    func testAMissingQuoteIsRefused() {
        XCTAssertTrue(validate([diff("Use Postgres")]).errors[0].contains("not in the plan"))
    }

    /// A reflowed quote still matches, once, and `old` is the plan's own text.
    func testWhitespaceDifferencesAreForgivenButStillExactlyOnce() {
        let outcome = validate([diff("Use  SQLite\nfor the queue.")])
        XCTAssertTrue(outcome.isValid, "\(outcome.errors)")
        XCTAssertEqual(outcome.diffs.first?.old, "Use SQLite for the queue.")
    }

    func testADiffOnAnotherCheckpointIsRefused() {
        XCTAssertTrue(validate([diff("Use SQLite for the queue.", checkpoint: 3)]).errors[0].contains("checkpoint 3"))
    }

    func testANoOpDiffIsRefused() {
        XCTAssertTrue(validate([diff("Use SQLite", replacement: "Use SQLite")]).errors[0].contains("changes nothing"))
    }

    /// One bad action refuses the answer: nothing of it is kept.
    func testOneRefusalKeepsNothing() {
        let outcome = validate([diff("Use SQLite for the queue."), diff("Use Postgres")])
        XCTAssertEqual(outcome.errors.count, 1)
        XCTAssertTrue(outcome.errors[0].hasPrefix("Action 2"))
        XCTAssertTrue(outcome.diffs.isEmpty)
    }

    func testNotesMustHaveAValidKindAndAnchor() {
        let good = PlanNote(kind: .mustChange, note: "Name the queue's owner.",
                            anchor: NoteAnchor(checkpoint: 4, quote: "Use SQLite for the queue."))
        XCTAssertTrue(validate([.addNote(good)]).isValid)
        XCTAssertTrue(validate([.addNote(PlanNote(kind: .question, note: "Why?"))]).errors[0].contains("askQuestion"))
        XCTAssertTrue(validate([.addNote(PlanNote(kind: .replace, note: " "))]).errors[0].contains("needs words"))
        let stale = PlanNote(kind: .comment, note: "x", anchor: NoteAnchor(checkpoint: 2, quote: "Use SQLite"))
        XCTAssertTrue(validate([.addNote(stale)]).errors[0].contains("checkpoint 2"))
        let ambiguous = PlanNote(kind: .comment, note: "x", anchor: NoteAnchor(checkpoint: 4, quote: "Retry the upload."))
        XCTAssertTrue(validate([.addNote(ambiguous)]).errors[0].contains("ambiguous"))
    }

    func testQuestionIDsMustBeUnique() {
        let q = StructuredQuestion(id: "q1", text: "Which?", kind: .single,
                                   options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")])
        XCTAssertTrue(validate([.askQuestion(q)]).isValid)
        XCTAssertTrue(validate([.askQuestion(q), .askQuestion(q)]).errors[0].contains("used twice"))
        let noOptions = StructuredQuestion(id: "q2", text: "Which?", kind: .multi)
        XCTAssertTrue(validate([.askQuestion(noOptions)]).errors[0].contains("needs options"))
    }

    func testApplyReplacesTheLocatedPassage() throws {
        let located = try XCTUnwrap(validate([diff("Use SQLite for the queue.", replacement: "Use a file queue.")]).diffs.first)
        let applied = try XCTUnwrap(ActionValidator.apply(old: located.old, anchor: located.anchor, new: located.new,
                                                          to: Self.plan))
        XCTAssertTrue(applied.contains("Retry the upload. Use a file queue.\n\n## Sync"))
        XCTAssertNil(ActionValidator.apply(old: "gone", anchor: located.anchor, new: "x", to: Self.plan))
    }
}
