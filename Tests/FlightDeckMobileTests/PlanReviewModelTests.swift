import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The phone's half. Logic only — the view is exercised by `scripts/smoke.sh`.
@MainActor
final class PlanReviewModelTests: XCTestCase {

    private func model(plan: String) -> PlanReviewModel {
        PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: plan,
                               startedAt: "2026-08-29T17:40:36.186Z", annotationCount: 0),
            send: { _ in }
        )
    }

    /// **Both ends split identically.** The phone draws a tap target per target block; the Mac
    /// resolves the index it is sent. A disagreement here is a comment on the wrong phrase.
    func testTheSameBlocksTheMacWouldCompute() {
        let plan = "# Title\n\nFirst.\n\n---\n\nSecond."
        XCTAssertEqual(model(plan: plan).blocks, PlanBlocks.split(plan).blocks)
    }

    func testOnlyTargetsAreTappable() {
        let model = model(plan: "A.\n\n---\n\nB.")
        XCTAssertEqual(model.blocks.filter(\.isTarget).count, 2)
        XCTAssertFalse(model.canComment(on: model.blocks.first { !$0.isTarget }!.index))
        XCTAssertTrue(model.canComment(on: 0))
    }

    func testACommentSendsAnnotateWithItsBlockIndex() {
        var sent: [FleetCommand] = []
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: "A.\n\nB.",
                               startedAt: "t", annotationCount: 0),
            send: { sent.append($0) }
        )
        model.comment(on: 1, text: "needs a rollback")
        guard case .annotatePlan(_, _, let call, let text, let block) = sent.first else {
            return XCTFail("expected annotatePlan, got \(String(describing: sent.first))")
        }
        XCTAssertEqual(call, "c")
        XCTAssertEqual(text, "needs a rollback")
        XCTAssertEqual(block, 1)
    }

    func testAGlobalCommentCarriesNoBlock() {
        var sent: [FleetCommand] = []
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: "A.",
                               startedAt: "t", annotationCount: 0),
            send: { sent.append($0) }
        )
        model.comment(on: nil, text: "missing a rollback section")
        guard case .annotatePlan(_, _, _, _, let block) = sent.first else {
            return XCTFail("expected annotatePlan")
        }
        XCTAssertNil(block)
    }

    /// Approving with notes is one action, not "send notes, then approve" — `POST /api/approve`
    /// takes the feedback itself, so the reader's words and their verdict cannot separate.
    func testApproveCarriesTheTypedFeedback() {
        var sent: [FleetCommand] = []
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: "A.",
                               startedAt: "t", annotationCount: 0),
            send: { sent.append($0) }
        )
        model.feedback = "ship it, but rename X"
        model.resolve(approve: true)
        guard case .resolvePlan(_, _, _, let approve, let feedback) = sent.last else {
            return XCTFail("expected resolvePlan")
        }
        XCTAssertTrue(approve)
        XCTAssertEqual(feedback, "ship it, but rename X")
    }

    /// One tap, one verdict. A double tap on Approve must not send two.
    func testResolvingTwiceSendsOneCommand() {
        var sent: [FleetCommand] = []
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "annotate", plan: "A.",
                               startedAt: "t", annotationCount: 0),
            send: { sent.append($0) }
        )
        model.resolve(approve: true)
        model.resolve(approve: false)
        XCTAssertEqual(sent.filter { if case .resolvePlan = $0 { return true }; return false }.count, 1)
    }

    /// In the `verdict` tier the gate carries no plan and pinning is impossible. The screen
    /// must say so rather than draw taps that go nowhere.
    func testVerdictTierOffersNoInlineComments() {
        let model = PlanReviewModel(
            session: UUID(),
            gate: WirePlanGate(callID: "c", tier: "verdict", plan: nil,
                               startedAt: "t", annotationCount: 0),
            transcriptPlan: "A.\n\nB.",
            send: { _ in }
        )
        XCTAssertFalse(model.canComment(on: 0))
        XCTAssertEqual(model.blocks.count, 2, "it still renders, it just takes no taps")
    }
}
