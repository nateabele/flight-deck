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
        XCTAssertEqual(a.count, 1); guard case .mail(let to, "b1", .clarifying, "why") = a[0] else { return XCTFail() }
        XCTAssertEqual(to, "BlueFalcon")
    }
    func testScopeChangeInjectsAndMails() {
        let a = DeliveryPlanner.plan(cs(.scopeChange), ratings: [0: .scopeChange], hasSession: { _ in true })
        XCTAssertEqual(a.map(\.kindName), ["inject", "mail"])
    }
    func testInvalidatingReclaimsInjectsAndMailsUrgent() {
        let a = DeliveryPlanner.plan(cs(.invalidating), ratings: [0: .invalidating], hasSession: { _ in true })
        XCTAssertEqual(a.map(\.kindName), ["reclaim", "inject", "mail"])
        guard case .mail(_, _, .invalidating, _) = a[2] else { return XCTFail("invalidating mail must be urgent") }
        XCTAssertTrue(DeliveryPlanner.isUrgent(.invalidating))
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
        guard case .mail(_, _, .invalidating, _) = a[0] else { return XCTFail("invalidating mail must be urgent even without a session") }
    }

    func testOnlyInvalidatingMailIsUrgent() {
        XCTAssertFalse(DeliveryPlanner.isUrgent(.clarifying))
        XCTAssertFalse(DeliveryPlanner.isUrgent(.scopeChange))
        XCTAssertTrue(DeliveryPlanner.isUrgent(.invalidating))
    }

    // Every mail body must name the bead, the reason, and give the reader somewhere to go
    // (`br show` + the Agent Mail thread) — regardless of rating or what actually happened
    // to the inject/reclaim underneath it.
    func testMailBodyNamesTheBeadReasonAndWhereToGo() {
        for rating in DeliveryRating.allCases {
            for outcome: DeliveryOutcome in [.notAttempted, .succeeded, .failed] {
                let body = DeliveryPlanner.mailBody(for: rating, bead: "b1", reason: "why", outcome: outcome)
                XCTAssertTrue(body.contains("b1"), "\(rating)/\(outcome): \(body)")
                XCTAssertTrue(body.contains("why"), "\(rating)/\(outcome): \(body)")
                XCTAssertTrue(body.contains("br show b1"), "\(rating)/\(outcome): \(body)")
                XCTAssertTrue(body.contains("bead:b1"), "\(rating)/\(outcome): \(body)")
            }
        }
    }
    func testInvalidatingMailLeadsWithStopWork() {
        let body = DeliveryPlanner.mailBody(for: .invalidating, bead: "b1", reason: "why", outcome: .succeeded)
        XCTAssertTrue(body.hasPrefix("Stop work"), body)
        XCTAssertTrue(body.contains("has been reclaimed"), body)
    }

    // A holder with no FD session never had a prompt injected or a reclaim performed, and
    // one whose inject/reclaim failed didn't either — the mail must not claim otherwise.
    func testScopeChangeMailClaimsAPromptOnlyWhenOneWasSent() {
        XCTAssertTrue(DeliveryPlanner.mailBody(for: .scopeChange, bead: "b1", reason: "why", outcome: .succeeded)
            .contains("prompt has been sent"))
        for outcome: DeliveryOutcome in [.notAttempted, .failed] {
            let body = DeliveryPlanner.mailBody(for: .scopeChange, bead: "b1", reason: "why", outcome: outcome)
            XCTAssertFalse(body.contains("prompt has been sent"), "\(outcome): \(body)")
        }
    }
    func testInvalidatingMailClaimsAReclaimOnlyWhenOneHappened() {
        for outcome: DeliveryOutcome in [.notAttempted, .failed] {
            let body = DeliveryPlanner.mailBody(for: .invalidating, bead: "b1", reason: "why", outcome: outcome)
            XCTAssertFalse(body.contains("reclaimed"), "\(outcome): \(body)")
            XCTAssertTrue(body.contains("could not reclaim"), "\(outcome): \(body)")
        }
    }
}
