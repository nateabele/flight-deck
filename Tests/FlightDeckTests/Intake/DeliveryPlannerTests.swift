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
    func testInvalidatingWithoutSessionGetsMailOnly() {
        let a = DeliveryPlanner.plan(cs(.invalidating), ratings: [0: .invalidating], hasSession: { _ in false })
        XCTAssertEqual(a.map(\.kindName), ["mail"])
        guard case .mail(_, _, _, _, true) = a[0] else { return XCTFail("invalidating mail must be urgent even without a session") }
    }

    // Every mail body must name the bead, the reason, and give the reader somewhere to go
    // (`br show` + the Agent Mail thread) — regardless of rating or whether a session/reclaim
    // actually happened underneath it.
    func testMailBodyNamesTheBeadReasonAndWhereToGo() {
        for rating: DeliveryRating in [.clarifying, .scopeChange, .invalidating] {
            let a = DeliveryPlanner.plan(cs(rating), ratings: [0: rating], hasSession: { _ in true })
            guard case .mail(_, _, _, let body, _) = a.last else { return XCTFail("\(rating): no mail action") }
            XCTAssertTrue(body.contains("b1"), "\(rating): \(body)")
            XCTAssertTrue(body.contains("why"), "\(rating): \(body)")
            XCTAssertTrue(body.contains("br show b1"), "\(rating): \(body)")
            XCTAssertTrue(body.contains("bead:b1"), "\(rating): \(body)")
        }
    }
    func testInvalidatingMailLeadsWithStopWork() {
        let a = DeliveryPlanner.plan(cs(.invalidating), ratings: [0: .invalidating], hasSession: { _ in true })
        guard case .mail(_, _, _, let body, _) = a.last else { return XCTFail() }
        XCTAssertTrue(body.hasPrefix("Stop work"), body)
    }

    // A holder with no FD session never had a prompt injected or a reclaim performed —
    // the mail telling them about the change must not claim either happened.
    func testNoSessionScopeChangeMailMakesNoFalseClaim() {
        let a = DeliveryPlanner.plan(cs(.scopeChange), ratings: [0: .scopeChange], hasSession: { _ in false })
        guard case .mail(_, _, _, let body, _) = a[0] else { return XCTFail() }
        XCTAssertFalse(body.contains("prompt has been sent"), body)
    }
    func testNoSessionInvalidatingMailMakesNoFalseClaim() {
        let a = DeliveryPlanner.plan(cs(.invalidating), ratings: [0: .invalidating], hasSession: { _ in false })
        guard case .mail(_, _, _, let body, _) = a[0] else { return XCTFail() }
        XCTAssertFalse(body.contains("reclaimed"), body)
        XCTAssertTrue(body.contains("could not reclaim"), body)
    }
}
