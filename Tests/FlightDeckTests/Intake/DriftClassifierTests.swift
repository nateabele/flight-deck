import XCTest
import IntakeKit

final class DriftClassifierTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)
    func validated(_ ops: [ChangeOp], _ g: GraphSnapshot) throws -> ValidatedChangeSet {
        try ChangeSetValidator.validate(ChangeSet(graphObservedAt: t0, ops: ops), against: g).get()
    }
    let before = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "t", status: "open")])

    func testUnchangedHolds() throws {
        let v = try validated([.editBead(id: "b1", set: FieldSet(title: "x"), pre: .init(status: "open", assignee: nil), delivery: nil)], before)
        XCTAssertEqual(DriftClassifier.classify(v, current: before), [.holds])
    }
    func testDeletedTargetIsImpossible() throws {
        let v = try validated([.editBead(id: "b1", set: FieldSet(title: "x"), pre: .init(status: "open", assignee: nil), delivery: nil)], before)
        guard case .impossible = DriftClassifier.classify(v, current: GraphSnapshot()).first else { return XCTFail() }
    }
    func testClaimedSinceTriageSuggestsScopeChange() throws {
        let v = try validated([.editBead(id: "b1", set: FieldSet(title: "x"), pre: .init(status: "open", assignee: nil), delivery: nil)], before)
        let now = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "t", status: "in_progress", assignee: "BlueFalcon")])
        guard case .drifted(let reason, let suggested) = DriftClassifier.classify(v, current: now).first else { return XCTFail() }
        XCTAssertEqual(suggested, .scopeChange)
        XCTAssertTrue(reason.contains("BlueFalcon"), reason)
    }
    func testCreateAlwaysHolds() throws {
        let v = try validated([.createBead(NewBead(tempId: "n1", title: "n", description: "d"))], before)
        XCTAssertEqual(DriftClassifier.classify(v, current: GraphSnapshot()), [.holds])
    }
}
