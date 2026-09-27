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

    /// The trailing default button per state, title-cased (HIG). Triage, shaping and release
    /// have nothing to press — shaping's transport lives in `ShapingView` — and released
    /// intakes only offer Dismiss.
    func testPrimaryActionPerState() {
        let expected: [IntakeState: String?] = [
            .needsAnswers: "Send Answers", .awaitingChoice: "Continue", .parked: "Continue",
            .review: "Open Release Review", .failed: "Retry", .interrupted: "Retry",
            .triaging: nil, .shaping: nil, .releasing: nil, .released: nil, .partiallyReleased: nil, .discarded: nil,
        ]
        for (state, title) in expected {
            XCTAssertEqual(IntakeDetailView.primaryAction(for: state, preset: .bead), title, "\(state)")
        }
        XCTAssertEqual(IntakeDetailView.primaryAction(for: .awaitingChoice, preset: .featurePlan), "Start Planning")
        XCTAssertEqual(IntakeDetailView.primaryAction(for: .parked, preset: .sketch), "Start Planning")
    }

    func testRoundLabelNumbersByExchangePosition() {
        XCTAssertEqual(IntakeDetailView.roundLabel(index: 0, exchange: TriageExchange(questions: ["a", "b", "c"], answers: ["1", "2", "3"])),
                       "Round 1 · 3 questions")
        XCTAssertEqual(IntakeDetailView.roundLabel(index: 1, exchange: TriageExchange(questions: ["a"], answers: ["1"])),
                       "Round 2 · 1 question")
    }
}
