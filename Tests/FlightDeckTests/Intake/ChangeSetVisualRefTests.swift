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

    func testAnUnknownVisualIsRejectedWhenTheKnownSetIsGiven() {
        let cs = create([VisualRef(visualID: "pairing-handshake"), VisualRef(visualID: "ghost")])
        let errors = ChangeSetValidator.validate(cs, against: graph, knownVisuals: ["pairing-handshake"]).failureErrors
        XCTAssertEqual(errors, [.unknownVisual("ghost")])
        XCTAssertTrue(ValidationError.unknownVisual("ghost").message.contains("ghost"))
        XCTAssertTrue(ValidationError.unknownVisual("ghost").userMessage.contains("ghost"))
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
