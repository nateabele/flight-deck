import XCTest
import IntakeKit

final class ApplyPlannerTests: XCTestCase {
    func testOrderIsCreatesEdgesEditsReopensThenHeldEdges() throws {
        let g = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "t", status: "open"),
                                      "c1": BeadSnapshot(id: "c1", title: "c", status: "closed")])
        let pre = Precondition(status: "open", assignee: nil)
        let cs = ChangeSet(graphObservedAt: .init(timeIntervalSince1970: 0), ops: [
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),          // held
            .reopen(id: "c1", reason: "r", pre: .init(status: "closed", assignee: nil)),
            .editBead(id: "b1", set: FieldSet(title: "x"), pre: pre, delivery: nil),
            .addEdge(from: .new("n1"), to: .existing("b1"), kind: .related),
            .createBead(NewBead(tempId: "n1", title: "n", description: "d")),
            .followUp(tempId: "n2", of: "c1", title: "f", description: "fd", pre: .init(status: "closed", assignee: nil)),
        ])
        let v = try ChangeSetValidator.validate(cs, against: g).get()
        XCTAssertEqual(ApplyPlanner.plan(v, skipping: []), [
            .create(NewBead(tempId: "n1", title: "n", description: "d")),
            .create(NewBead(tempId: "n2", title: "f", description: "fd")),
            .depend(dependent: .new("n1"), dependency: .existing("b1"), kind: .related),
            .depend(dependent: .new("n2"), dependency: .existing("c1"), kind: .related),
            .recheck(id: "b1", pre: pre), .update(id: "b1", set: FieldSet(title: "x")),
            .recheck(id: "c1", pre: .init(status: "closed", assignee: nil)), .reopen(id: "c1", reason: "r"),
            .recheck(id: "b1", pre: pre), .depend(dependent: .existing("b1"), dependency: .new("n1"), kind: .blocks),
        ])
    }
    func testSkippedOpsAreOmitted() throws {
        let g = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "t", status: "open")])
        let cs = ChangeSet(graphObservedAt: .init(timeIntervalSince1970: 0), ops: [
            .editBead(id: "b1", set: FieldSet(title: "x"), pre: .init(status: "open", assignee: nil), delivery: nil)])
        let v = try ChangeSetValidator.validate(cs, against: g).get()
        XCTAssertEqual(ApplyPlanner.plan(v, skipping: [0]), [])
    }
    func testSkippedCreateBeadAlsoSkipsItsDependentEdges() throws {
        let g = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "t", status: "open")])
        let cs = ChangeSet(graphObservedAt: .init(timeIntervalSince1970: 0), ops: [
            .createBead(NewBead(tempId: "n1", title: "n", description: "d")),              // idx 0 (skipped)
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),               // idx 1 (should also skip)
            .addEdge(from: .new("n1"), to: .existing("b1"), kind: .related)])             // idx 2 (should also skip)
        let v = try ChangeSetValidator.validate(cs, against: g).get()
        XCTAssertEqual(ApplyPlanner.plan(v, skipping: [0]), [])
    }
}
