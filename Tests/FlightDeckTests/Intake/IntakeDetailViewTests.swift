import XCTest
import IntakeKit
@testable import FlightDeck

/// `IntakeDetailView.canSendAnswers` is the guard behind "Send answers" being disabled —
/// pinned here so a blank/partial answer set can never regress into being sendable again.
final class IntakeDetailViewTests: XCTestCase {
    func testEmptyAnswersCannotBeSent() {
        XCTAssertFalse(IntakeDetailView.canSendAnswers([]))
    }

    func testAnyBlankAnswerBlocksSending() {
        XCTAssertFalse(IntakeDetailView.canSendAnswers(["yes", ""]))
        XCTAssertFalse(IntakeDetailView.canSendAnswers(["", "no"]))
    }

    func testWhitespaceOnlyAnswerBlocksSending() {
        XCTAssertFalse(IntakeDetailView.canSendAnswers(["yes", "  \n\t "]))
    }

    func testEveryAnswerNonBlankAllowsSending() {
        XCTAssertTrue(IntakeDetailView.canSendAnswers(["yes", "no"]))
        XCTAssertTrue(IntakeDetailView.canSendAnswers(["  a single answer, padded  "]))
    }

    // The close and primary action titles per state moved with the layout to `DetailLayout`
    // (`DetailLayoutTests.testPrimaryActionTitles`, `testCloseActionIsDiscardUntilReleased`).

    func testRoundLabelNumbersByExchangePosition() {
        XCTAssertEqual(IntakeDetailView.roundLabel(index: 0, exchange: TriageExchange(questions: ["a", "b", "c"], answers: ["1", "2", "3"])),
                       "Round 1 · 3 questions")
        XCTAssertEqual(IntakeDetailView.roundLabel(index: 1, exchange: TriageExchange(questions: ["a"], answers: ["1"])),
                       "Round 2 · 1 question")
    }
}
