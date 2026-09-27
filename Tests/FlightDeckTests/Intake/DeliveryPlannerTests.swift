import XCTest
import IntakeKit

final class DeliveryPlannerTests: XCTestCase {
    let pre = Precondition(status: "in_progress", assignee: "BlueFalcon")
    func cs(_ rating: DeliveryRating) -> ChangeSet {
        ChangeSet(graphObservedAt: .init(timeIntervalSince1970: 0), ops: [
            .editBead(id: "b1", set: FieldSet(acceptance: "more"), pre: pre, delivery: Delivery(rating: rating, reason: "why"))])
    }
    func testClarifyingIsMailOnly() {
        let a = DeliveryPlanner.plan(cs(.clarifying), ratings: [0: .clarifying], hasSession: { _ in true })
        XCTAssertEqual(a.count, 1); guard case .mail(let to, "b1", _, _, false) = a[0] else { return XCTFail() }
        XCTAssertEqual(to, "BlueFalcon")
    }
    func testScopeChangeInjectsAndMails() {
        let a = DeliveryPlanner.plan(cs(.scopeChange), ratings: [0: .scopeChange], hasSession: { _ in true })
        XCTAssertEqual(a.map(\.kindName), ["inject", "mail"])
    }
    func testInvalidatingReclaimsInjectsAndMailsUrgent() {
        let a = DeliveryPlanner.plan(cs(.invalidating), ratings: [0: .invalidating], hasSession: { _ in true })
        XCTAssertEqual(a.map(\.kindName), ["reclaim", "inject", "mail"])
        guard case .mail(_, _, _, _, true) = a[2] else { return XCTFail("invalidating mail must be urgent") }
    }
    func testHolderWithoutSessionGetsMailOnly() {
        let a = DeliveryPlanner.plan(cs(.scopeChange), ratings: [0: .scopeChange], hasSession: { _ in false })
        XCTAssertEqual(a.map(\.kindName), ["mail"])
    }
    func testUserOverrideWins() {
        let a = DeliveryPlanner.plan(cs(.invalidating), ratings: [0: .clarifying], hasSession: { _ in true })
        XCTAssertEqual(a.map(\.kindName), ["mail"])
    }
}
