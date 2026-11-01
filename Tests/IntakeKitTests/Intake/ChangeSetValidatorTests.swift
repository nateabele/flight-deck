import XCTest
import IntakeKit

final class ChangeSetValidatorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)
    let graph = GraphSnapshot(
        beads: ["b1": BeadSnapshot(id: "b1", title: "one", status: "open"),
                "b2": BeadSnapshot(id: "b2", title: "two", status: "in_progress", assignee: "BlueFalcon")],
        edges: [DepEdge(dependent: "b2", dependency: "b1")])
    func new(_ t: String) -> ChangeOp { .createBead(NewBead(tempId: t, title: t, description: t)) }

    func testExistingToNewEdgeIsHeld() throws {
        let cs = ChangeSet(graphObservedAt: t0, ops: [new("n1"),
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),
            .addEdge(from: .new("n1"), to: .existing("b1"), kind: .related)])
        let v = try ChangeSetValidator.validate(cs, against: graph).get()
        XCTAssertEqual(v.heldOpIndices, [1])
    }
    func testDanglingTempIdRejected() {
        let cs = ChangeSet(graphObservedAt: t0, ops: [.addEdge(from: .new("ghost"), to: .existing("b1"), kind: .blocks)])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.undefinedTempId("ghost")])
    }
    func testUnknownBeadRejected() {
        let cs = ChangeSet(graphObservedAt: t0, ops: [.reopen(id: "nope", reason: "r", pre: .init(status: "closed", assignee: nil))])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.unknownBead("nope")])
    }
    func testCycleThroughExistingEdgeRejected() {
        // b2 → b1 already exists; adding b1 → n1 → b2 closes a loop.
        let cs = ChangeSet(graphObservedAt: t0, ops: [new("n1"),
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),
            .addEdge(from: .new("n1"), to: .existing("b2"), kind: .blocks)])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.cycle])
    }
    func testRelatedEdgesDoNotCountAsCycles() throws {
        let cs = ChangeSet(graphObservedAt: t0, ops: [
            .addEdge(from: .existing("b1"), to: .existing("b2"), kind: .related)])
        XCTAssertNoThrow(try ChangeSetValidator.validate(cs, against: graph).get())
    }
    func testInProgressEditNeedsDelivery() {
        let cs = ChangeSet(graphObservedAt: t0, ops: [
            .editBead(id: "b2", set: FieldSet(title: "x"), pre: .init(status: "in_progress", assignee: "BlueFalcon"), delivery: nil)])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.missingDelivery("b2")])
    }
    func testDuplicateTempIdRejected() {
        let cs = ChangeSet(graphObservedAt: t0, ops: [new("n1"), new("n1")])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.duplicateTempId("n1")])
    }
    func testInProgressInGraphRequiresDeliveryEvenIfPreClaimsOpen() {
        // Agent wrote pre: open for b2, but graph shows in_progress; needs delivery + must reject the mismatch
        let cs = ChangeSet(graphObservedAt: t0, ops: [
            .editBead(id: "b2", set: FieldSet(title: "x"), pre: .init(status: "open", assignee: nil), delivery: nil)])
        let errors = ChangeSetValidator.validate(cs, against: graph).failureErrors
        XCTAssert(errors.contains(where: { if case .missingDelivery("b2") = $0 { true } else { false } }))
        XCTAssert(errors.contains(where: { if case .preconditionMismatch("b2") = $0 { true } else { false } }))
    }
    func testMatchingPreconditionIsValid() throws {
        // Agent wrote pre: in_progress for b2, which matches the graph, and provided a delivery rating
        let cs = ChangeSet(graphObservedAt: t0, ops: [
            .editBead(id: "b2", set: FieldSet(title: "x"), pre: .init(status: "in_progress", assignee: "BlueFalcon"), delivery: Delivery(rating: .scopeChange, reason: "r"))])
        XCTAssertNoThrow(try ChangeSetValidator.validate(cs, against: graph).get())
    }
}

extension Result where Failure == ValidationErrors {
    var failureErrors: [ValidationError] { if case .failure(let e) = self { e.errors } else { [] } }
}
