import FleetKit
import XCTest
@testable import FlightDeckMobile

@MainActor
private final class StubFetcher: IntakeFetching {
    var detailCalls: [(UUID, String?)] = []
    var detailReplies: [Result<WireIntakeDetail?, FleetRequestError>] = []
    var planCalls = 0
    var planReply: Result<WireIntakePlan, FleetRequestError> = .failure(.disconnected)
    /// Consumed first, one per call; `planReply` answers once it is empty.
    var planReplies: [Result<WireIntakePlan, FleetRequestError>] = []
    func intakeDetail(_ id: UUID, ifNot: String?, then: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void) {
        detailCalls.append((id, ifNot)); then(detailReplies.isEmpty ? .failure(.disconnected) : detailReplies.removeFirst())
    }
    func intakePlan(_ id: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void) {
        planCalls += 1; then(planReplies.isEmpty ? planReply : planReplies.removeFirst())
    }
}

@MainActor
final class FlightControlModelTests: XCTestCase {
    private func summary(_ id: UUID, attention: Bool, state: String) -> WireIntakeSummary {
        WireIntakeSummary(id: id, title: "T", state: state, needsAttention: attention, createdAt: Date())
    }
    private func fleet(_ project: UUID, _ intakes: [WireIntakeSummary]) -> FleetSnapshot {
        FleetSnapshot(projects: [WireProject(id: project, name: "larkOS", path: "/w", intakes: intakes)])
    }

    func testASnapshotBaselinesWithoutBannersAndALiveTransitionFiresOne() {
        let model = FlightControlModel(fetcher: StubFetcher())
        let project = UUID(), id = UUID()
        let waiting = [summary(id, attention: false, state: "triaging")]
        model.baseline(fleet(project, waiting))
        XCTAssertEqual(model.banners, [])
        let now = [summary(id, attention: true, state: "needsAnswers")]
        model.intakesChanged(project: project, intakes: now, fleet: fleet(project, now))
        XCTAssertEqual(model.banners.map(\.id), [id])
        model.intakesChanged(project: project, intakes: now, fleet: fleet(project, now))
        XCTAssertEqual(model.banners.count, 1, "the same state again is not a new transition")
        model.dismissBanner(id)
        XCTAssertEqual(model.banners, [])
    }

    func testDetailKeepsItsEtagAndIgnoresUnchangedReplies() {
        let fetcher = StubFetcher()
        let id = UUID()
        let d = WireIntakeDetail(etag: "e1", project: UUID(),
                                 summary: summary(id, attention: false, state: "triaging"), intent: "I", progress: [],
                                 agents: [], rounds: [], pendingNotes: 0, servedAt: Date(timeIntervalSinceReferenceDate: 110))
        fetcher.detailReplies = [.success(d), .success(nil)]
        let model = IntakeDetailModel(id: id, fetcher: fetcher, receivedAt: { Date(timeIntervalSinceReferenceDate: 100) })
        model.refresh()
        model.refresh()
        XCTAssertEqual(fetcher.detailCalls.map(\.1), [nil, "e1"])
        XCTAssertEqual(model.detail, d, "nil means unchanged: keep what we have")
        XCTAssertEqual(model.macClockOffset, 10)
    }

    func testAnUnknownIntakeSaysItIsGone() {
        let fetcher = StubFetcher()
        fetcher.detailReplies = [.failure(.server(code: "unknown_intake"))]
        let model = IntakeDetailModel(id: UUID(), fetcher: fetcher)
        model.refresh()
        XCTAssertTrue(model.gone)
    }

    func testADisconnectKeepsTheLastDetail() {
        let fetcher = StubFetcher()
        let d = WireIntakeDetail(etag: "e", project: UUID(), summary: summary(UUID(), attention: false, state: "triaging"),
                                 intent: "I", progress: [], agents: [], rounds: [], pendingNotes: 0, servedAt: Date())
        fetcher.detailReplies = [.success(d), .failure(.disconnected)]
        let model = IntakeDetailModel(id: d.summary.id, fetcher: fetcher)
        model.refresh(); model.refresh()
        XCTAssertEqual(model.detail, d)
        XCTAssertFalse(model.gone)
    }

    func testPlansAreCachedByCheckpointAndChanges() {
        let fetcher = StubFetcher()
        fetcher.planReply = .success(WireIntakePlan(checkpoint: 3, roundName: "Refine 1", editsVersion: "", markdown: "# P", outline: [], notes: []))
        let model = FlightControlModel(fetcher: fetcher)
        let id = UUID()
        model.plan(id, checkpoint: 3, changes: false) { _ in }
        model.plan(id, checkpoint: 3, changes: false) { _ in }
        XCTAssertEqual(fetcher.planCalls, 1)
        model.plan(id, checkpoint: 3, changes: true) { _ in }
        XCTAssertEqual(fetcher.planCalls, 2)
        for c in 10..<15 { model.plan(id, checkpoint: c, changes: false) { _ in } }
        model.plan(id, checkpoint: 3, changes: false) { _ in }
        XCTAssertEqual(fetcher.planCalls, 8, "LRU of 4: checkpoint 3 was evicted")
    }

    func testTheHeadIsNeverServedFromCacheAndItsReplyOverwritesTheCheckpointEntry() {
        let fetcher = StubFetcher()
        func plan(_ v: String) -> Result<WireIntakePlan, FleetRequestError> {
            .success(WireIntakePlan(checkpoint: 3, roundName: "Refine 1", editsVersion: v, markdown: "# P", outline: [], notes: []))
        }
        fetcher.planReplies = [plan("a"), plan("b")]
        let model = FlightControlModel(fetcher: fetcher)
        let id = UUID()
        model.plan(id, checkpoint: nil, changes: false) { _ in }
        model.plan(id, checkpoint: nil, changes: false) { _ in }
        XCTAssertEqual(fetcher.planCalls, 2, "a head request always goes to the Mac")
        var served: String?
        model.plan(id, checkpoint: 3, changes: false) { if case .success(let p) = $0 { served = p.editsVersion } }
        XCTAssertEqual(fetcher.planCalls, 2, "the explicit checkpoint is served from cache")
        XCTAssertEqual(served, "b", "the latest head reply replaced the older entry")
    }
}
