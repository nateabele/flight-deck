import FleetKit
import XCTest

/// The phone's Send button must agree with the Mac, so these are the cases IntakeKit's
/// `StructuredQuestionTests` run, over the wire types. The Mac stays authoritative.
final class StructuredAnswerRulesTests: XCTestCase {
    private func q(_ kind: String, options: [String] = ["a", "b"], recommended: [String] = []) -> WireStructuredQuestion {
        WireStructuredQuestion(id: "q1", text: "Which?", kind: kind,
                               options: options.map { WireOption(id: $0, label: $0.uppercased()) },
                               recommended: recommended, allowOther: true)
    }
    private func a(_ selected: [String] = [], other: String? = nil) -> WireStructuredAnswer {
        WireStructuredAnswer(questionID: "q1", selected: selected, other: other)
    }

    func testTextNeedsNonBlankOther() {
        XCTAssertFalse(q("text").isComplete(a()))
        XCTAssertFalse(q("text").isComplete(a(other: "  \n")))
        XCTAssertTrue(q("text").isComplete(a(other: "yes")))
    }

    func testSingleNeedsExactlyOnePickOrOther() {
        XCTAssertFalse(q("single").isComplete(a()))
        XCTAssertFalse(q("single").isComplete(a(other: "   ")))
        XCTAssertTrue(q("single").isComplete(a(["a"])))
        XCTAssertFalse(q("single").isComplete(a(["a", "b"])))
        XCTAssertTrue(q("single").isComplete(a(other: "mine")))
    }

    func testMultiAndToggleAreAlwaysComplete() {
        XCTAssertTrue(q("multi").isComplete(a()))
        XCTAssertTrue(q("multi").isComplete(a(["a", "b"])))
        XCTAssertTrue(q("toggle", options: ["on"]).isComplete(a()))
        XCTAssertTrue(q("toggle", options: ["on"]).isComplete(a(["on"])))
    }

    func testUnknownKindActsLikeText() {
        XCTAssertFalse(q("slider").isComplete(a(["a"])))
        XCTAssertTrue(q("slider").isComplete(a(other: "x")))
        XCTAssertEqual(q("slider", recommended: ["a"]).initialAnswer.selected, [])
    }

    func testInitialAnswerPreselectsRecommended() {
        XCTAssertEqual(q("single", recommended: ["b"]).initialAnswer.selected, ["b"])
        XCTAssertEqual(q("multi", recommended: ["a", "b"]).initialAnswer.selected, ["a", "b"])
        XCTAssertEqual(q("single", recommended: ["b"]).initialAnswer.questionID, "q1")
        XCTAssertNil(q("single", recommended: ["b"]).initialAnswer.other)
    }

    func testInitialAnswerDropsInventedIds() {
        XCTAssertEqual(q("multi", recommended: ["zzz", "a"]).initialAnswer.selected, ["a"])
        XCTAssertEqual(q("single", recommended: ["zzz"]).initialAnswer.selected, [])
    }

    func testSingleAndToggleAreCappedAtOne() {
        XCTAssertEqual(q("single", recommended: ["a", "b"]).initialAnswer.selected, ["a"])
        XCTAssertEqual(q("toggle", options: ["on"], recommended: ["on", "on"]).initialAnswer.selected, ["on"])
    }

    func testToggleIsOffUnlessRecommended() {
        XCTAssertEqual(q("toggle", options: ["on"]).initialAnswer.selected, [])
    }

    func testTextStartsEmpty() {
        XCTAssertEqual(q("text", recommended: ["a"]).initialAnswer.selected, [])
    }
}
