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

    /// Detection lands after launch, often with the plan already on screen and its config seeded
    /// from the codex/claude fallback. The fresh detection re-seeds it with the agents now signed
    /// in; a config the human edited is left alone.
    func testDetectedAgentsReseedAnUneditedConfigOnly() throws {
        let detected = AvailableModels(choices: [
            .codex: .init(agent: .codex, model: "gpt-6-sol", effort: "high"),
            .claude: .init(agent: .claude, model: "opus", effort: "high"),
            .gemini: .init(agent: .gemini, model: "gemini-3.1-pro-high", effort: "high"),
            .grok: .init(agent: .grok, model: "grok-4.7", effort: "medium")])
        let stale = PresetExpansion.config(for: .fullPlan, available: .defaults)
        let fresh = try XCTUnwrap(IntakeDetailView.reseeded(stale, preset: .fullPlan, available: detected))
        XCTAssertEqual(fresh.drafters.map(\.choice.agent), [.codex, .claude, .gemini, .grok])
        XCTAssertEqual(fresh.crossReviewer?.choice.agent, .gemini)

        var edited = try XCTUnwrap(stale)
        edited.customized = true
        XCTAssertEqual(IntakeDetailView.reseeded(edited, preset: .fullPlan, available: detected), edited,
                       "the human's own edits survive a re-detection")
    }
}
