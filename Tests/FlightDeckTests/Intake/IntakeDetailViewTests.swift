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

    /// Every state but `.releasing` has a way off the list: an intake stuck at a question, a
    /// choice or the review used to have no exit at all. `.releasing` refuses because
    /// `IntakeService.discard` does (half-written beads, no record); `.discarded` is never
    /// listed. Released states say Dismiss — nothing is thrown away, the record stays on disk.
    func testEveryStateButReleasingHasACloseAction() {
        let expected: [IntakeState: String?] = [
            .triaging: "Discard", .needsAnswers: "Discard", .awaitingChoice: "Discard", .parked: "Discard",
            .review: "Discard", .failed: "Discard", .interrupted: "Discard",
            .released: "Dismiss", .partiallyReleased: "Dismiss",
            .releasing: nil, .discarded: nil,
        ]
        for (state, label) in expected {
            XCTAssertEqual(IntakeDetailView.closeAction(for: state), label, "\(state)")
        }
    }
}
