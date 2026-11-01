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
        XCTAssertEqual(c.editing?.diff.id, a.id)
        c.acceptEdited()
        XCTAssertEqual(decided.count, 1)
        XCTAssertEqual(decided.first?.0, true, "recorded as an accept")
        XCTAssertEqual(decided.first?.1, plan, "with the plan as it reads")
        XCTAssertNil(c.editing)
    }

    /// A controller wired to a real text storage, as the bridge wires it: edits reach `textEdited`,
    /// Edit replaces the passage, Cancel replaces it back.
    private func wired(_ plan: String) -> (DiffGutterController, NSTextStorage, NSObjectProtocol) {
        let storage = NSTextStorage(string: plan)
        let c = DiffGutterController()
        c.segments = { _ in [CGRect(x: 40, y: 0, width: 200, height: 20)] }
        c.currentText = { storage.string }
        c.onEdit = { diff, range in storage.replaceCharacters(in: range, with: diff.new) }
        c.onRestore = { range, original in storage.replaceCharacters(in: range, with: original) }
        let observer = TextEdit.observe(storage) { c.textEdited($0) }
        return (c, storage, observer)
    }

    func testCancelAfterTypingRestoresTheOriginalPassage() {
        let (c, storage, observer) = wired(plan)
        defer { NotificationCenter.default.removeObserver(observer) }
        let a = diff("Alpha beta gamma.", new: "Alpha beta gamma, changed.")
        c.update([a], in: plan)
        c.edit(a)
        XCTAssertEqual(storage.string, plan.replacingOccurrences(of: "Alpha beta gamma.", with: "Alpha beta gamma, changed."))
        // The person types inside the inserted words, at their end, and above them.
        let at = (storage.string as NSString).range(of: "changed").location
        storage.replaceCharacters(in: NSRange(location: at, length: 0), with: "VERY ")
        let end = (storage.string as NSString).range(of: "changed.").upperBound
        storage.replaceCharacters(in: NSRange(location: end, length: 0), with: " More.")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Intro line.\n")
        var decided = 0
        c.onDecide = { _, _, _ in decided += 1 }
        c.cancelEdit()
        XCTAssertEqual(storage.string, "Intro line.\n" + plan, "the original passage is back, and the typing elsewhere is kept")
        XCTAssertEqual(decided, 0)
        XCTAssertNil(c.editing)
    }

    func testCancelRestoresByRangeNotByUndoingTheLastGroup() {
        let (c, storage, observer) = wired(plan)
        defer { NotificationCenter.default.removeObserver(observer) }
        let a = diff("Alpha beta gamma.", new: "Alpha beta gamma, changed.")
        c.update([a], in: plan)
        c.edit(a)
        // An unrelated edit after Edit, far from the passage: Cancel must leave it alone.
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "Tail note.\n")
        c.cancelEdit()
        XCTAssertEqual(storage.string, plan + "Tail note.\n")
    }

    func testTheStripFollowsTheEditedPassageNotAnEarlierOccurrence() {
        let text = "# Plan\n\nreplacement\n\nAlpha beta gamma.\n"
        let (c, storage, observer) = wired(text)
        defer { NotificationCenter.default.removeObserver(observer) }
        let range = (text as NSString).range(of: "Alpha beta gamma.")
        let a = ThreadDiff(thread: ThreadID(), checkpoint: 2,
                           anchor: NoteAnchor(checkpoint: 2, selecting: text.range(of: "Alpha beta gamma.")!, in: text),
                           old: "Alpha beta gamma.", new: "replacement")
        c.update([a], in: text)
        c.edit(a)
        let expected = NSRange(location: range.location, length: ("replacement" as NSString).length)
        XCTAssertEqual(c.editing?.anchor, expected, "the inserted words, not the first \"replacement\" in the plan")
        // Typing above moves the anchor with the text; typing inside grows it.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "ab")
        XCTAssertEqual(c.editing?.anchor, NSRange(location: expected.location + 2, length: expected.length))
        storage.replaceCharacters(in: NSRange(location: expected.location + 2 + 3, length: 0), with: "XX")
        XCTAssertEqual(c.editing?.anchor, NSRange(location: expected.location + 2, length: expected.length + 2))
    }

    /// ⌘Z after Edit takes the inserted words back out: the plan reads as before Edit, so there is
    /// no edit to accept. The session ends with it; left open, Accept edited recorded an accept of
    /// an unchanged plan.
    func testUndoingTheEditInsertEndsTheSession() {
        let (c, storage, observer) = wired(plan)
        defer { NotificationCenter.default.removeObserver(observer) }
        let a = diff("Alpha beta gamma.", new: "Alpha beta gamma, changed.")
        c.update([a], in: plan)
        c.edit(a)
        let anchor = try! XCTUnwrap(c.editing).anchor
        storage.replaceCharacters(in: anchor, with: "Alpha beta gamma.")   // what undo does
        XCTAssertEqual(storage.string, plan)
        XCTAssertNil(c.editing)
        var decided = 0
        c.onDecide = { _, _, _ in decided += 1 }
        c.acceptEdited()
        XCTAssertEqual(decided, 0)
    }

    /// A paste over the edge of the inserted words (some before them, some inside): where the
    /// passage starts is no longer known, so Cancel can't put the original back by range without
    /// eating the pasted words outside it. The session ends and the text stays as typed.
    func testAPasteOverTheEdgeOfTheEditEndsTheSessionAndCancelTouchesNothing() {
        let (c, storage, observer) = wired(plan)
        defer { NotificationCenter.default.removeObserver(observer) }
        let a = diff("Alpha beta gamma.", new: "Alpha beta gamma, changed.")
        c.update([a], in: plan)
        c.edit(a)
        let anchor = try! XCTUnwrap(c.editing).anchor
        storage.replaceCharacters(in: NSRange(location: anchor.location - 2, length: 7), with: "PASTED TEXT")
        let typed = storage.string
        XCTAssertNil(c.editing)
        c.cancelEdit()
        XCTAssertEqual(storage.string, typed)
    }

    func testEditingEndsWhenTheDiffGoesAway() {
        let c = controller()
        let a = diff("Alpha beta gamma.")
        c.update([a], in: plan, checkpoint: 2)
        c.onEdit = { _, _ in }
        c.edit(a)
        XCTAssertNotNil(c.editing)
        c.update([a], in: plan, checkpoint: 2)
        XCTAssertNotNil(c.editing, "still pending: the strip stays")
        c.update([], in: plan, checkpoint: 2)   // resolved, accepted elsewhere, or withdrawn
        XCTAssertNil(c.editing)
    }

    func testEditingEndsWhenTheCheckpointChanges() {
        let c = controller()
        let a = diff("Alpha beta gamma.")
        c.update([a], in: plan, checkpoint: 2)
        c.onEdit = { _, _ in }
        c.edit(a)
        c.update([a], in: plan, checkpoint: 3)
        XCTAssertNil(c.editing)
    }

    func testEditingEndsWhenThePanelSwitchesThread() {
        let c = controller()
        let a = diff("Alpha beta gamma.")
        c.update([a], in: plan, checkpoint: 2)
        c.onEdit = { _, _ in }
        c.edit(a)
        c.panelSwitchedThread()
        XCTAssertNil(c.editing)
    }
    /// B-I4: the proposal is drawn, not text, and its toolbar comes only under a pointer. So each
    /// located diff is an accessibility element that reads the proposed words, with Accept edit,
    /// Reject edit, Edit and Open thread as custom actions: VoiceOver and keyboard users reach them.
    func testEachProposalIsAnAccessibilityElementWithItsActions() throws {
        let c = controller()
        let a = diff("Alpha beta gamma.", new: "Alpha beta gamma, revised.")
        c.update([a], in: plan)
        var decided: [Bool] = []
        var opened = 0
        c.onDecide = { _, accept, _ in decided.append(accept) }
        c.onOpenThread = { _ in opened += 1 }
        let elements = c.accessibilityElements()
        XCTAssertEqual(elements.count, 1)
        let element = try XCTUnwrap(elements.first)
        XCTAssertTrue(element.accessibilityLabel()?.contains("Alpha beta gamma, revised.") == true, element.accessibilityLabel() ?? "")
        let actions = element.accessibilityCustomActions() ?? []
        XCTAssertEqual(actions.map(\.name), ["Accept edit", "Reject edit", "Edit", "Open thread"])
        _ = actions[0].handler?()
        _ = actions[1].handler?()
        _ = actions[3].handler?()
        XCTAssertEqual(decided, [true, false])
        XCTAssertEqual(opened, 1)
    }

    /// B-I2: a refusal of a ✓ or ✗ made from the plan shows beside that diff's passage for a moment,
    /// not only in the panel's composer, which may not be on screen.
    func testARefusalFromThePlansToolbarShowsBesideTheDiff() {
        let c = controller()
        let a = diff("Alpha beta gamma."), b = diff("Delta epsilon zeta.")
        c.update([a, b], in: plan)
        ThreadPanelModel.announceRefusal(diff: b.id, words: "A round rewrote that passage.")
        XCTAssertEqual(c.refusal?.diff, b.id)
        XCTAssertEqual(c.refusal?.words, "A round rewrote that passage.")
        ThreadPanelModel.announceRefusal(diff: UUID(), words: "Not ours.")
        XCTAssertEqual(c.refusal?.diff, b.id, "a refusal for a diff not in this plan is not shown here")
        c.clearRefusal()
        XCTAssertNil(c.refusal)
    }
}
