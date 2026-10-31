import AppKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// The gutter controller's wiring without a window: it finds each diff's passage, picks a hover by
/// where the pointer is, and sends decisions (and the Edit flow's) where they go.
@MainActor
final class DiffGutterControllerTests: XCTestCase {
    private let plan = "# Plan\n\nAlpha beta gamma.\n\nDelta epsilon zeta.\n"

    private func diff(_ quote: String, new: String = "replacement") -> ThreadDiff {
        let range = plan.range(of: quote)!
        return ThreadDiff(thread: ThreadID(), checkpoint: 2, anchor: NoteAnchor(checkpoint: 2, selecting: range, in: plan),
                          old: quote, new: new)
    }

    private func controller() -> DiffGutterController {
        let c = DiffGutterController()
        // One 20 pt line per passage, at y = its offset: enough geometry for a hit test.
        c.segments = { [plan] range in
            let line = (plan as NSString).substring(to: range.location).filter { $0 == "\n" }.count
            return [CGRect(x: 40, y: CGFloat(line) * 20, width: 200, height: 20)]
        }
        c.currentText = { [plan] in plan }
        return c
    }

    func testEachDiffIsFoundInThePlan() {
        let c = controller()
        let a = diff("Alpha beta gamma."), b = diff("Delta epsilon zeta.")
        c.update([a, b], in: plan)
        XCTAssertEqual(c.located[a.id], (plan as NSString).range(of: "Alpha beta gamma."))
        XCTAssertEqual(c.located[b.id], (plan as NSString).range(of: "Delta epsilon zeta."))
        XCTAssertEqual(c.locatedDiffs.count, 2)
        c.update([a], in: "# Plan\n\nSomething else entirely.\n")
        XCTAssertTrue(c.locatedDiffs.isEmpty, "a diff whose passage is gone is not drawn")
    }

    func testThePointerOnAPassageShowsItsHoverAndLeavingHidesIt() {
        let c = controller()
        let a = diff("Alpha beta gamma."), b = diff("Delta epsilon zeta.")
        c.update([a, b], in: plan)
        let line = c.segments(c.located[b.id]!)[0]
        c.hover(at: NSPoint(x: line.midX, y: line.midY))
        XCTAssertEqual(c.shownCard, b.id)
        c.hover(at: NSPoint(x: 5000, y: 5000))
        c.hideCard()
        XCTAssertNil(c.shownCard)
    }

    func testAHoverOnADiffDrawnInPlaceOpensItsRoomThroughTheEditor() {
        let c = controller()
        let a = diff("Alpha beta gamma.")
        c.update([a], in: plan)
        var hovered: [UUID?] = []
        c.inlineBlock = { _ in (NSRange(location: 8, length: 17), true) }
        c.onHoverProposal = { hovered.append($0) }
        XCTAssertTrue(c.isInline(a.id))
        c.show(a)
        XCTAssertEqual(hovered, [a.id])
        c.hideCard()
        XCTAssertEqual(hovered, [a.id, nil], "leaving closes the room")
    }

    func testDecisionsGoToTheOwner() {
        let c = controller()
        let a = diff("Alpha beta gamma.")
        var seen: [(Bool, String?)] = []
        c.onDecide = { _, accept, edited in seen.append((accept, edited)) }
        c.decide(a, accept: true)
        c.decide(a, accept: false)
        XCTAssertEqual(seen.map(\.0), [true, false])
        XCTAssertEqual(seen.map(\.1), [nil, nil])
    }

    func testEditThenAcceptEditedSendsTheWholeEditedPlanAsAnAccept() {
        let c = controller()
        let a = diff("Alpha beta gamma.", new: "Alpha beta gamma, changed.")
        c.update([a], in: plan)
        var edited: [NSRange] = []
        var decided: [(Bool, String?)] = []
        c.onEdit = { _, range in edited.append(range) }
        c.onDecide = { _, accept, markdown in decided.append((accept, markdown)) }
        c.edit(a)
        XCTAssertEqual(edited, [(plan as NSString).range(of: "Alpha beta gamma.")])
        XCTAssertEqual(c.editing?.id, a.id)
        c.acceptEdited()
        XCTAssertEqual(decided.count, 1)
        XCTAssertEqual(decided.first?.0, true, "recorded as an accept")
        XCTAssertEqual(decided.first?.1, plan, "with the plan as it reads")
        XCTAssertNil(c.editing)
    }

    func testCancelUndoesTheInsertAndDecidesNothing() {
        let c = controller()
        let a = diff("Alpha beta gamma.")
        c.update([a], in: plan)
        var undone = 0
        var decided = 0
        c.onEdit = { _, _ in }
        c.onCancelEdit = { undone += 1 }
        c.onDecide = { _, _, _ in decided += 1 }
        c.edit(a)
        c.cancelEdit()
        c.cancelEdit()
        XCTAssertEqual(undone, 1)
        XCTAssertEqual(decided, 0)
        XCTAssertNil(c.editing)
    }
}
