import XCTest
import IntakeKit

final class ReleaseSummaryTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)
    let openPre = Precondition(status: "open", assignee: nil)

    func testCreateEdgeAndScopeChangeWithSession() {
        let ops: [ChangeOp] = [
            .createBead(NewBead(tempId: "n1", title: "n", description: "d")),
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),
            .editBead(id: "b2", set: FieldSet(title: "x"),
                      pre: Precondition(status: "in_progress", assignee: "BlueFalcon"),
                      delivery: Delivery(rating: .scopeChange, reason: "why")),
        ]
        let drift: [OpDrift] = [.holds, .holds, .holds]
        let text = ReleaseSummary.text(ops, drift: drift, dropped: [],
                                       ratings: [:], hasSession: { _ in true })
        XCTAssertEqual(text, "1 new task · 1 edit · 1 dependency · 2 notices (1 session message, 1 mail)")
    }

    func testEntirelyDroppedIsNothingToRelease() {
        let ops: [ChangeOp] = [.createBead(NewBead(tempId: "n1", title: "n", description: "d"))]
        let text = ReleaseSummary.text(ops, drift: [.holds], dropped: [0],
                                       ratings: [:], hasSession: { _ in true })
        XCTAssertEqual(text, "Nothing to release")
    }

    func testPluralWordingAcrossAllSegments() {
        let ops: [ChangeOp] = [
            .createBead(NewBead(tempId: "n1", title: "n1", description: "d")),
            .createBead(NewBead(tempId: "n2", title: "n2", description: "d")),
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),
            .addEdge(from: .existing("b2"), to: .new("n2"), kind: .blocks),
            .editBead(id: "b3", set: FieldSet(title: "x"),
                      pre: Precondition(status: "in_progress", assignee: "BlueFalcon"),
                      delivery: Delivery(rating: .invalidating, reason: "why")),
        ]
        let drift: [OpDrift] = [.holds, .holds, .holds, .holds, .holds]
        let text = ReleaseSummary.text(ops, drift: drift, dropped: [],
                                       ratings: [:], hasSession: { _ in true })
        // Invalidating with a session plans reclaim+inject+mail (`DeliveryPlanner.plan`),
        // but a reclaim is a graph write, not a notice sent to the holder — spec §8.4's
        // format counts only inject/mail, so this is 2 notices, not 3.
        XCTAssertEqual(text, "2 new tasks · 1 edit · 2 dependencies · 2 notices (1 session message, 1 mail)")
    }

    func testImpossibleOpIsExcludedLikeADrop() {
        let ops: [ChangeOp] = [
            .createBead(NewBead(tempId: "n1", title: "n", description: "d")),
            .editBead(id: "gone", set: FieldSet(title: "x"),
                      pre: Precondition(status: "in_progress", assignee: "BlueFalcon"),
                      delivery: Delivery(rating: .scopeChange, reason: "why")),
        ]
        let drift: [OpDrift] = [.holds, .impossible(reason: "gone no longer exists")]
        let text = ReleaseSummary.text(ops, drift: drift, dropped: [],
                                       ratings: [:], hasSession: { _ in true })
        XCTAssertEqual(text, "1 new task")
    }

    func testZeroCountSegmentsAreOmittedIndividually() {
        let ops: [ChangeOp] = [
            .editBead(id: "b1", set: FieldSet(title: "x"),
                      pre: Precondition(status: "in_progress", assignee: "BlueFalcon"),
                      delivery: Delivery(rating: .clarifying, reason: "why")),
        ]
        let text = ReleaseSummary.text(ops, drift: [.holds], dropped: [],
                                       ratings: [:], hasSession: { _ in true })
        XCTAssertEqual(text, "1 edit · 1 notice (1 mail)")
    }

    func testRatingOverrideChangesTheNoticeBreakdown() {
        let ops: [ChangeOp] = [
            .editBead(id: "b1", set: FieldSet(title: "x"),
                      pre: Precondition(status: "in_progress", assignee: "BlueFalcon"),
                      delivery: Delivery(rating: .invalidating, reason: "why")),
        ]
        let text = ReleaseSummary.text(ops, drift: [.holds], dropped: [],
                                       ratings: [0: .clarifying], hasSession: { _ in true })
        XCTAssertEqual(text, "1 edit · 1 notice (1 mail)")
    }

    /// A follow-up is a new task, the same as the sheet's New tasks section lists it — the
    /// footer once counted only `createBead`, so a follow-up listed under New tasks was missing
    /// from the count right below it.
    func testFollowUpCountsAsANewTask() {
        let ops: [ChangeOp] = [
            .createBead(NewBead(tempId: "n1", title: "n", description: "d")),
            .followUp(tempId: "n2", of: "b1", title: "f", description: "d", pre: openPre),
            .reopen(id: "b2", reason: "r", pre: openPre),
        ]
        let text = ReleaseSummary.text(ops, drift: [.holds, .holds, .holds], dropped: [],
                                       ratings: [:], hasSession: { _ in true })
        XCTAssertEqual(text, "2 new tasks · 1 edit")
    }

    /// Two notices of one kind read as a plural — except mail, a mass noun.
    func testNoticeBreakdownPlurals() {
        let edit = { (id: String) in
            ChangeOp.editBead(id: id, set: FieldSet(title: "x"), pre: Precondition(status: "in_progress", assignee: "BlueFalcon"),
                              delivery: Delivery(rating: .scopeChange, reason: "why"))
        }
        let text = ReleaseSummary.text([edit("b1"), edit("b2")], drift: [.holds, .holds], dropped: [],
                                       ratings: [:], hasSession: { _ in true })
        XCTAssertEqual(text, "2 edits · 4 notices (2 session messages, 2 mail)")
    }
}
