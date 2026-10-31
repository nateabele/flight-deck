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

    // MARK: accepts

    func testAcceptsOnlyTheQuestionsOwnOptionsEachOnce() {
        let single = question(.single), multi = question(.multi)
        XCTAssertTrue(single.accepts(.init(questionID: "q1", selected: ["a"])))
        XCTAssertTrue(multi.accepts(.init(questionID: "q1", selected: ["a", "b"], other: "C")))
        XCTAssertTrue(multi.accepts(.init(questionID: "q1", selected: [])))
        XCTAssertFalse(single.accepts(.init(questionID: "q1", selected: ["ghost"])), "an unknown id")
        XCTAssertFalse(multi.accepts(.init(questionID: "q1", selected: ["a", "ghost"])), "an unknown id among known")
        XCTAssertFalse(multi.accepts(.init(questionID: "q1", selected: ["a", "a"])), "a duplicate id")
        XCTAssertFalse(question(.toggle, options: ["on"]).accepts(.init(questionID: "q1", selected: ["off"])))
        let text = StructuredQuestion.text(id: "q1", "Who?")
        XCTAssertTrue(text.accepts(.init(questionID: "q1", selected: [], other: "the maintainer")))
        XCTAssertFalse(text.accepts(.init(questionID: "q1", selected: ["a"], other: "the maintainer")), "selected on a text question")
    }

    // MARK: questionsDigest

    private func exchange(_ questions: [StructuredQuestion]) -> TriageExchange {
        TriageExchange(questions: questions.map(\.text), structured: questions)
    }

    func testTheDigestIsStableAndIgnoresAnswersAndLabels() {
        let q = question(.single, recommended: ["a"])
        let a = exchange([q])
        XCTAssertEqual(a.questionsDigest.count, 16)
        XCTAssertTrue(a.questionsDigest.allSatisfy(\.isHexDigit), a.questionsDigest)
        var answered = a
        answered.answers = ["A"]
        answered.structuredAnswers = [.init(questionID: "q1", selected: ["a"])]
        XCTAssertEqual(answered.questionsDigest, a.questionsDigest, "answering a round does not rename it")
        var relabelled = q
        relabelled.options[0].label = "Option A"
        XCTAssertEqual(exchange([relabelled]).questionsDigest, a.questionsDigest)
        // Pinned, so a change to the encoding is a deliberate one: drafts on disk are keyed by it.
        // The value was checked by hand against FNV-1a 64 over "2:q1" "4:Who?" "4:text" "1:0".
        XCTAssertEqual(TriageExchange(questions: ["Who?"]).questionsDigest, "6660fac6cf48ba4e")
    }

    /// A retry's fresh triage can reuse index 0 and even the same text; anything that changes what
    /// an answer's ids mean must change the digest.
    func testTheDigestChangesWithWhatTheRoundAsks() {
        let base = question(.single)
        let digest = exchange([base]).questionsDigest
        var otherOptions = base
        otherOptions.options = [.init(id: "x", label: "A"), .init(id: "b", label: "B")]
        var otherText = base
        otherText.text = "Which one?"
        var otherID = base
        otherID.id = "q2"
        var otherKind = base
        otherKind.kind = .multi
        for changed in [otherOptions, otherText, otherID, otherKind] {
            XCTAssertNotEqual(exchange([changed]).questionsDigest, digest, "\(changed)")
        }
        let two = StructuredQuestion.text(id: "q2", "When?")
        XCTAssertNotEqual(exchange([base, two]).questionsDigest, exchange([two, base]).questionsDigest, "order matters")
        // Length-prefixed: moving a character across a field boundary is a different round.
        XCTAssertNotEqual(TriageExchange(questions: ["ab", "c"]).questionsDigest,
                          TriageExchange(questions: ["a", "bc"]).questionsDigest)
        XCTAssertNotEqual(TriageExchange(questions: ["Who?"]).questionsDigest, TriageExchange(questions: ["When?"]).questionsDigest)
    }
}
