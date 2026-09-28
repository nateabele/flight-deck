import XCTest
import IntakeKit
@testable import FlightDeck

/// The release review sheet's words (spec §10): its Release button, the summary line above it
/// and the header caption have to count the same things, and every row names tasks by title.
final class ReleaseSheetModelTests: XCTestCase {
    private let pre = Precondition(status: "open", assignee: nil)

    /// The render the controller caught: 3 new tasks (one a follow-up), 2 edits, 2 dependencies.
    private var ops: [ChangeOp] {
        [
            .createBead(NewBead(tempId: "t1", title: "Technician skills", description: "")),
            .createBead(NewBead(tempId: "t2", title: "Offline check-in", description: "")),
            .followUp(tempId: "t3", of: "fd-9-dsp", title: "Auto-assignment mode", description: "", pre: pre),
            .editBead(id: "fd-9-sfr", set: FieldSet(description: "soft"), pre: pre, delivery: nil),
            .reopen(id: "fd-9-dsp", reason: "one more pass", pre: pre),
            .addEdge(from: .new("t2"), to: .new("t1"), kind: .blocks),
            .addEdge(from: .existing("fd-9-sfr"), to: .new("t1"), kind: .blocks),
        ]
    }

    private let titles = ["fd-9-sfr": "Skill match is a soft constraint", "fd-9-dsp": "Dispatch board v1"]

    /// The button, the summary line and the header tie together: the button's number is the
    /// summary's first number, and what was left out is the header's. It once read "Release 7
    /// Tasks" (every op) over "Release 2 tasks" (only `createBead`) under "7 of 7 selected".
    func testButtonSummaryAndHeaderAgree() {
        let model = ReleaseSheetModel(ops: ops, drift: Array(repeating: .holds, count: 7), dropped: [1], titles: titles)
        let summary = ReleaseSummary.text(ops, drift: Array(repeating: .holds, count: 7), dropped: [1],
                                          ratings: [:], hasSession: { _ in false })
        XCTAssertEqual(model.releaseButton, "Release 2 New Tasks")
        XCTAssertEqual(summary, "2 new tasks · 2 edits · 2 dependencies")
        XCTAssertTrue(summary.hasPrefix(model.counts.phrase), "the summary line leads with the button's own count")
        XCTAssertEqual(model.header, "1 dropped")

        let untouched = ReleaseSheetModel(ops: ops, drift: Array(repeating: .holds, count: 7), dropped: [], titles: titles)
        XCTAssertEqual(untouched.releaseButton, "Release 3 New Tasks")
        XCTAssertNil(untouched.header, "nothing left out, nothing to say — there is no selection to count")
    }

    /// An impossible op is left out exactly like a dropped one, by all three.
    func testImpossibleOpsAreLeftOutEverywhere() {
        var drift = Array(repeating: OpDrift.holds, count: 7)
        drift[0] = .impossible(reason: "gone")
        let model = ReleaseSheetModel(ops: ops, drift: drift, dropped: [], titles: titles)
        XCTAssertEqual(model.releaseButton, "Release 2 New Tasks")
        XCTAssertEqual(model.header, "1 dropped")
        XCTAssertEqual(ReleaseSummary.text(ops, drift: drift, dropped: [], ratings: [:], hasSession: { _ in false }),
                       "2 new tasks · 2 edits · 2 dependencies")
    }

    /// With no new task the button still says what it does, singular and without a zero.
    func testButtonWordingWithoutNewTasks() {
        XCTAssertEqual(UIText.releaseButton(ReleaseCounts([ops[0]])), "Release 1 New Task")
        XCTAssertEqual(UIText.releaseButton(ReleaseCounts([ops[3], ops[5]])), "Release Changes")
        XCTAssertEqual(UIText.releaseButton(ReleaseCounts([])), "Release")
    }

    /// Rows name tasks by title — the change set's own title for a task it creates, the live
    /// graph's for one that exists — and never by id (`fd-…-sfr`, `new:t1`), which goes to
    /// the row's help text instead.
    func testRowsNameTasksByTitle() {
        let model = ReleaseSheetModel(ops: ops, drift: Array(repeating: .holds, count: 7), dropped: [], titles: titles)
        let lines = ops.map(model.line)
        XCTAssertEqual(lines.map(\.text), [
            "Technician skills",
            "Offline check-in",
            "Auto-assignment mode · follow-up to Dispatch board v1",
            "Skill match is a soft constraint",
            "Reopen Dispatch board v1: one more pass",
            "Offline check-in waits on Technician skills",
            "Skill match is a soft constraint waits on Technician skills",
        ])
        for line in lines {
            XCTAssertFalse(line.text.contains("fd-9"), line.text)
            XCTAssertFalse(line.text.contains("new:"), line.text)
        }
        XCTAssertEqual(lines[3].help, "fd-9-sfr")
        XCTAssertEqual(lines[6].help, "fd-9-sfr → new:t1")
        // A task the live graph no longer knows falls back to its id rather than to nothing.
        XCTAssertEqual(ReleaseSheetModel(ops: ops, drift: [], dropped: [], titles: [:]).line(ops[3]).text, "fd-9-sfr")
    }

    /// The edge that waits for release is said in words, not "held".
    func testWaitingEdgeIsFlaggedInWords() {
        XCTAssertTrue(ReleaseSheetModel.waitsForRelease(ops[6]))
        XCTAssertFalse(ReleaseSheetModel.waitsForRelease(ops[5]))
        XCTAssertEqual(UIText.waitsForRelease, "waits for release")
    }

    /// The in-progress row's planned delivery, in words: no raw action kinds, no "FD".
    func testPlannedDeliveryInWords() {
        XCTAssertEqual(ReleaseSheetModel.plannedDelivery(assignee: "BlueFalcon", rating: .scopeChange, reason: "r", hasSession: true),
                       "BlueFalcon: session message + mail")
        XCTAssertEqual(ReleaseSheetModel.plannedDelivery(assignee: "BlueFalcon", rating: .invalidating, reason: "r", hasSession: true),
                       "BlueFalcon: task taken back + session message + mail")
        XCTAssertEqual(ReleaseSheetModel.plannedDelivery(assignee: "BlueFalcon", rating: .scopeChange, reason: "r", hasSession: false),
                       "BlueFalcon has no Flight Deck session — mail only")
    }
}
