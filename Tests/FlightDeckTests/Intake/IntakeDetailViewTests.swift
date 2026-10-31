import XCTest
import IntakeKit
@testable import FlightDeck

/// `IntakeDetailView.canSendAnswers` is the guard behind "Send answers" being disabled —
/// pinned here so a blank/partial answer set can never regress into being sendable again.
final class IntakeDetailViewTests: XCTestCase {
    private let text = StructuredQuestion.text(id: "t", "Why?")
    private let single = StructuredQuestion(id: "s", text: "Which?", kind: .single,
        options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")], allowOther: true)
    private let multi = StructuredQuestion(id: "m", text: "Which ones?", kind: .multi,
        options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")])

    private func send(_ qs: [StructuredQuestion], _ answers: [StructuredAnswer]) -> Bool {
        IntakeDetailView.canSendAnswers(qs, answers)
    }

    func testNoQuestionsCannotBeSent() {
        XCTAssertFalse(send([], []))
    }

    func testAnyIncompleteAnswerBlocksSending() {
        // A blank (or whitespace-only) text answer blocks.
        XCTAssertFalse(send([text], [StructuredAnswer(questionID: "t")]))
        XCTAssertFalse(send([text], [StructuredAnswer(questionID: "t", other: "  \n\t ")]))
        // A single with nothing chosen and no Other text blocks; an empty Other still blocks.
        XCTAssertFalse(send([single], [StructuredAnswer(questionID: "s")]))
        XCTAssertFalse(send([single], [StructuredAnswer(questionID: "s", other: " ")]))
        // A question with no answer yet blocks rather than counting as complete.
        XCTAssertFalse(send([text, multi], [StructuredAnswer(questionID: "t", other: "x")]))
        // A multi with nothing selected does not: "none" is a real answer.
        XCTAssertTrue(send([multi], [StructuredAnswer(questionID: "m")]))
    }

    func testEveryAnswerCompleteAllowsSending() {
        XCTAssertTrue(send([text, single, multi], [
            StructuredAnswer(questionID: "t", other: "  padded  "),
            StructuredAnswer(questionID: "s", selected: ["a"]),
            StructuredAnswer(questionID: "m", selected: ["a", "b"])]))
        XCTAssertTrue(send([single], [StructuredAnswer(questionID: "s", other: "something else")]))
    }

    func testOnlyTheRecommendedOptionCarriesTheCaption() {
        let q = StructuredQuestion(id: "s", text: "?", kind: .single,
                                   options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")], recommended: ["b"])
        XCTAssertNil(StructuredQuestionView.caption(for: q.options[0], in: q))
        XCTAssertEqual(StructuredQuestionView.caption(for: q.options[1], in: q), "recommended")
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
