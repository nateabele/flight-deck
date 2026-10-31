import XCTest
@testable import IntakeKit

final class StructuredQuestionTests: XCTestCase {
    private func question(_ kind: StructuredQuestion.Kind, recommended: [String] = [],
                          options: [String] = ["a", "b"]) -> StructuredQuestion {
        StructuredQuestion(
            id: "q1", text: "Which?", kind: kind,
            options: options.map { .init(id: $0, label: $0.uppercased(), detail: nil) },
            recommended: recommended, allowOther: true, cost: nil)
    }

    func testSingleAnsweredByOtherOnly() {
        let q = question(.single)
        let a = StructuredAnswer(questionID: "q1", selected: [], other: "Keep it")
        XCTAssertTrue(q.isComplete(a))
        XCTAssertEqual(q.render(a), "Other: Keep it")
    }

    func testMultiWithNothingSelectedIsCompleteAndRendersNone() {
        let q = question(.multi)
        let a = StructuredAnswer(questionID: "q1", selected: [], other: nil)
        XCTAssertTrue(q.isComplete(a))
        XCTAssertEqual(q.render(a), "None")
    }

    func testRenderFormsPerKind() {
        var single = question(.single, options: ["mac", "all"])
        single.options[0].label = "Only this Mac"
        XCTAssertEqual(single.render(.init(questionID: "q1", selected: ["mac"], other: nil)), "Only this Mac")

        let multi = question(.multi)
        XCTAssertEqual(multi.render(.init(questionID: "q1", selected: ["a", "b"], other: "C")), "A, B; Other: C")

        let toggle = question(.toggle, options: ["on"])
        XCTAssertEqual(toggle.render(.init(questionID: "q1", selected: ["on"], other: nil)), "Yes")
        XCTAssertEqual(toggle.render(.init(questionID: "q1", selected: [], other: nil)), "No")

        let text = StructuredQuestion.text(id: "q1", "Who?")
        XCTAssertEqual(text.render(.init(questionID: "q1", selected: [], other: "  the maintainer \n")), "the maintainer")
    }

    func testBlankTextAndUnchosenSingleAreIncomplete() {
        let text = StructuredQuestion.text(id: "q1", "Who?")
        XCTAssertFalse(text.isComplete(.init(questionID: "q1", selected: [], other: "  \n")))
        XCTAssertFalse(text.isComplete(.init(questionID: "q1", selected: [], other: nil)))
        let single = question(.single)
        XCTAssertFalse(single.isComplete(.init(questionID: "q1", selected: [], other: nil)))
        XCTAssertFalse(single.isComplete(.init(questionID: "q1", selected: [], other: "  ")))
    }

    func testInitialAnswerPreselectsRecommended() {
        XCTAssertEqual(question(.single, recommended: ["b"]).initialAnswer.selected, ["b"])
        XCTAssertEqual(question(.multi, recommended: ["a", "c"], options: ["a", "b", "c"]).initialAnswer.selected,
                       ["a", "c"])
        XCTAssertEqual(question(.toggle, recommended: ["on"], options: ["on"]).initialAnswer.selected, ["on"])
        XCTAssertEqual(question(.toggle, options: ["on"]).initialAnswer.selected, [])
    }

    func testInitialAnswerDropsRecommendedIdsThatAreNotOptions() {
        XCTAssertEqual(question(.single, recommended: ["zzz"]).initialAnswer.selected, [])
        XCTAssertEqual(question(.multi, recommended: ["a", "zzz"]).initialAnswer.selected, ["a"])
    }

    func testInitialAnswerCapsSingleAndToggleAtOnePick() {
        XCTAssertEqual(question(.single, recommended: ["a", "b"]).initialAnswer.selected, ["a"])
        XCTAssertEqual(question(.toggle, recommended: ["a", "b"]).initialAnswer.selected, ["a"])
    }

    func testRenderFallsBackToTheIdForAnUnknownSelection() {
        XCTAssertEqual(question(.single).render(.init(questionID: "q1", selected: ["ghost"], other: nil)), "ghost")
        XCTAssertEqual(question(.multi).render(.init(questionID: "q1", selected: ["a", "ghost"], other: nil)), "A, ghost")
    }

    func testToggleIgnoresForeignIds() {
        let toggle = question(.toggle, options: ["on"])
        XCTAssertEqual(toggle.render(.init(questionID: "q1", selected: ["other"], other: nil)), "No")
        XCTAssertEqual(toggle.render(.init(questionID: "q1", selected: ["other", "on"], other: nil)), "Yes")
        XCTAssertTrue(toggle.isComplete(.init(questionID: "q1", selected: ["other"], other: nil)))
    }

    func testLegacyExchangeDecodesAndPresentsAsTextQuestions() throws {
        let json = #"{"questions":["Who?","When?"],"answers":null}"#
        let ex = try JSONDecoder().decode(TriageExchange.self, from: Data(json.utf8))
        XCTAssertNil(ex.structured)
        XCTAssertEqual(ex.presentedQuestions.map(\.id), ["q1", "q2"])
        XCTAssertEqual(ex.presentedQuestions.map(\.kind), [.text, .text])
        XCTAssertEqual(ex.presentedQuestions.map(\.text), ["Who?", "When?"])
    }

    func testStructuredExchangeRoundTrips() throws {
        var ex = TriageExchange(questions: ["Which?"])
        ex.structured = [question(.single, recommended: ["a"])]
        ex.structuredAnswers = [.init(questionID: "q1", selected: ["a"], other: nil)]
        let back = try JSONDecoder().decode(TriageExchange.self, from: JSONEncoder().encode(ex))
        XCTAssertEqual(back, ex)
        XCTAssertEqual(back.presentedQuestions, ex.structured)
    }
}
