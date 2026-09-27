import XCTest
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
}
