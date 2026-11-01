import XCTest
import IntakeKit

/// `NewBead.visualRefs` is additive (P2a V0): a change set written before it decodes and
/// re-encodes to the same bytes, and `ChangeSetValidator` checks the ids it names.
final class ChangeSetVisualRefTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private let graph = GraphSnapshot(beads: [:], edges: [])

    private func create(_ refs: [VisualRef]?) -> ChangeSet {
        ChangeSet(graphObservedAt: t0, ops: [.createBead(NewBead(tempId: "t1", title: "T", description: "D", visualRefs: refs))])
    }

    func testAnOldChangeSetDecodesWithNoVisualRefs() throws {
        let old = #"{"graphObservedAt":"2026-09-26T20:00:00Z","ops":[{"op":"createTask","tempId":"t1","title":"T","type":"task","priority":2,"description":"D","labels":[]}]}"#
        let cs = try ChangeSet.decode(Data(old.utf8))
        guard case .createBead(let bead) = cs.ops[0] else { return XCTFail() }
        XCTAssertNil(bead.visualRefs)
        // And writing it back adds no key, so a tape from before visuals keeps its bytes.
        XCTAssertFalse(String(decoding: try cs.encoded(), as: UTF8.self).contains("visualRefs"))
    }

    func testVisualRefsRoundTrip() throws {
        let cs = create([VisualRef(visualID: "pairing-handshake", states: ["paired"]), VisualRef(visualID: "other")])
        XCTAssertEqual(try ChangeSet.decode(cs.encoded()), cs)
    }

    /// Ruling (V4 final review, A-I2): a ref to a visual the plan no longer has is dropped at
    /// validation with a warning, never a failure, so a block removed after encode cannot block
    /// release or pause polish.
    func testAnUnknownVisualIsDroppedWithAWarning() throws {
        let cs = create([VisualRef(visualID: "pairing-handshake"), VisualRef(visualID: "ghost")])
        let v = try ChangeSetValidator.validate(cs, against: graph, knownVisuals: ["pairing-handshake"]).get()
        guard case .createBead(let b) = v.changeSet.ops[0] else { return XCTFail() }
        XCTAssertEqual(b.visualRefs, [VisualRef(visualID: "pairing-handshake")])
        XCTAssertEqual(v.warnings, ["Task \u{201C}\(b.title)\u{201D} no longer cites ghost: the visual was removed"])
    }

    /// nil means "no check"; an empty set means the plan has no visuals, so every ref is dropped.
    func testAnEmptyKnownSetDropsEveryRef() throws {
        let v = try ChangeSetValidator.validate(create([VisualRef(visualID: "a")]), against: graph, knownVisuals: Set()).get()
        guard case .createBead(let b) = v.changeSet.ops[0] else { return XCTFail() }
        XCTAssertEqual(b.visualRefs, [])
        XCTAssertEqual(v.warnings.count, 1)
    }

    /// A-M5: a state the visual's manifest lacks is dropped from the ref, with a warning.
    func testAStateTheVisualLacksIsDroppedWithAWarning() throws {
        let cs = create([VisualRef(visualID: "a", states: ["default", "loading"])])
        let v = try ChangeSetValidator.validate(cs, against: graph, knownVisuals: ["a"], visualStates: ["a": ["default", "error"]]).get()
        guard case .createBead(let b) = v.changeSet.ops[0] else { return XCTFail() }
        XCTAssertEqual(b.visualRefs, [VisualRef(visualID: "a", states: ["default"])])
        XCTAssertEqual(v.warnings, ["Task \u{201C}\(b.title)\u{201D} cites state loading of a, which the visual does not have; it was dropped"])
    }

    func testKnownVisualsPass() {
        let cs = create([VisualRef(visualID: "a")])
        XCTAssertNoThrow(try ChangeSetValidator.validate(cs, against: graph, knownVisuals: ["a", "b"]).get())
    }

    /// Callers that predate visuals pass no set and see no new failure.
    func testWithoutAKnownSetTheVisualCheckIsSkipped() {
        let cs = create([VisualRef(visualID: "anything")])
        XCTAssertNoThrow(try ChangeSetValidator.validate(cs, against: graph).get())
    }

}

private extension Result where Failure == ValidationErrors {
    var errors: [ValidationError] { if case .failure(let e) = self { e.errors } else { [] } }
}
