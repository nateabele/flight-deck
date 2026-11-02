import FleetKit
import HostKit
import XCTest
@testable import FlightDeck

/// The session cloud summary on its way to the fleet wire: how `InfraService` is read into it,
/// when `SessionCloudMonitor` lets a new one through, and that the store records it as an event
/// the mirror folds back into the projection (`attachedReplicator` fails on any drift).
@MainActor
final class SessionCloudMonitorTests: XCTestCase {
    private var h: InfraHarness!
    private var store: SessionStore!
    private var session: Session!
    private let t0 = InfraMachine.fixtureNow

    override func setUp() async throws {
        h = try InfraHarness()
        store = SessionStore(provider: nil, persistence: nil)
        session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
    }

    /// A machine `session` owns, billing from `at` with the ledger agreeing.
    @discardableResult
    private func own(_ name: String, hourly: Double = 0.5, state: InfraState = .ready, at: Date? = nil,
                     createdAt: Date? = nil, deadline: TimeInterval = 3600, machineDeadline: TimeInterval? = nil,
                     session: UUID? = nil) throws -> InfraMachine {
        var m = InfraMachine.fixture(name: name, state: state, hourlyUSD: hourly, createdAt: createdAt ?? t0,
                                     deadline: t0.addingTimeInterval(deadline),
                                     machineDeadline: machineDeadline.map(t0.addingTimeInterval))
        m.session = session ?? self.session.id
        try h.registry.upsert(m)
        try h.ledger.open(name: name, hourlyUSD: hourly, at: at ?? t0, session: m.session)
        return m
    }

    // MARK: Building

    func testBuildsOnlyForSessionsWithMachinesThatStillExist() throws {
        try own("gpu")
        try own("dead", state: .gone)
        var orphaned = InfraMachine.fixture(name: "shell")
        orphaned.session = nil
        try h.registry.upsert(orphaned)
        let other = UUID()
        try own("theirs", session: other)
        let built = h.service.sessionClouds(now: t0)
        XCTAssertEqual(Set(built.keys), [session.id, other])
        XCTAssertEqual(built[session.id]?.machines.map(\.name), ["gpu"])
    }

    func testMachinesAreOldestFirstWithTheirOwnSpend() throws {
        try own("late", hourly: 1, at: t0.addingTimeInterval(1800), createdAt: t0.addingTimeInterval(1800), deadline: 36_000)
        try own("early", hourly: 2, at: t0, createdAt: t0, deadline: 36_000)
        let c = try XCTUnwrap(h.service.sessionClouds(now: t0.addingTimeInterval(3600))[session.id])
        XCTAssertEqual(c.machines.map(\.name), ["early", "late"])
        XCTAssertEqual(c.machines[0].spentUsd, 2, accuracy: 1e-9)
        XCTAssertEqual(c.machines[1].spentUsd, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.spentUsd, 2.5, accuracy: 1e-9)
        XCTAssertEqual(c.hourlyUsd, 3, accuracy: 1e-9)
        XCTAssertEqual(c.monthUsd, 2.5, accuracy: 1e-9)
        XCTAssertEqual(c.monthCapUsd, h.budget.monthlyCapUSD)
        XCTAssertNil(c.budgetCapUsd)
    }

    func testABudgetCarriesItsCapWindowAndExhaustion() throws {
        try own("gpu", hourly: 2, deadline: 36_000)
        try h.budgets.set(session.id, capUSD: 4, now: t0)
        let c = try XCTUnwrap(h.service.sessionClouds(now: t0)[session.id])
        XCTAssertEqual(c.budgetCapUsd, 4)
        XCTAssertEqual(c.budgetSince, t0)
        XCTAssertEqual(try XCTUnwrap(c.budgetExhaustsAt).timeIntervalSince(t0), 7200, accuracy: 1)
    }

    // MARK: Re-send policy

    private func cloud(asOf: Date, spent: Double = 1, hourly: Double = 2, state: String = "ready",
                       exhausts: Date? = nil) -> WireSessionCloud {
        WireSessionCloud(
            asOf: asOf,
            machines: [WireCloudMachine(name: "gpu", cloud: "aws", instanceType: "t", region: "r", state: state, network: "public",
                                        hourlyUsd: hourly, spentUsd: spent, createdAt: t0, deadline: t0.addingTimeInterval(3600))],
            spentUsd: spent, hourlyUsd: hourly, budgetCapUsd: exhausts == nil ? nil : 10, budgetSince: exhausts == nil ? nil : t0,
            budgetExhaustsAt: exhausts, monthUsd: spent)
    }

    private func resend(_ previous: WireSessionCloud?, _ built: WireSessionCloud?, now: Date) -> WireSessionCloud? {
        let id = session.id
        return SessionCloudMonitor.resend(previous: previous.map { [id: $0] } ?? [:], built: built.map { [id: $0] } ?? [:],
                                          now: now)[id]
    }

    func testAFirstValueAlwaysGoesThrough() {
        let fresh = cloud(asOf: t0)
        XCTAssertEqual(resend(nil, fresh, now: t0), fresh)
    }

    func testOnlyTheBaselineMovingKeepsThePreviousValue() {
        let old = cloud(asOf: t0, spent: 1)
        XCTAssertEqual(resend(old, cloud(asOf: t0.addingTimeInterval(60), spent: 1.03), now: t0.addingTimeInterval(60)), old)
        XCTAssertEqual(resend(old, cloud(asOf: t0.addingTimeInterval(299), spent: 1.2), now: t0.addingTimeInterval(299)), old)
    }

    func testAStructuralChangeGoesThroughAtOnce() {
        let old = cloud(asOf: t0)
        for fresh in [cloud(asOf: t0.addingTimeInterval(5), state: "destroying"),
                      cloud(asOf: t0.addingTimeInterval(5), hourly: 3),
                      cloud(asOf: t0.addingTimeInterval(5), exhausts: t0.addingTimeInterval(7200))] {
            XCTAssertEqual(resend(old, fresh, now: t0.addingTimeInterval(5)), fresh)
        }
    }

    func testAStaleBaselineIsReanchoredOnlyWhileMoneyIsSpent() {
        let old = cloud(asOf: t0)
        let fresh = cloud(asOf: t0.addingTimeInterval(300), spent: 1.17)
        XCTAssertEqual(resend(old, fresh, now: t0.addingTimeInterval(300)), fresh)

        let idle = cloud(asOf: t0, hourly: 0)
        XCTAssertEqual(resend(idle, cloud(asOf: t0.addingTimeInterval(900), hourly: 0), now: t0.addingTimeInterval(900)), idle,
                       "a session spending nothing has nothing to re-anchor")
    }

    func testTheExhaustionInstantWobblesButADifferentOneDoesNot() {
        let old = cloud(asOf: t0, exhausts: t0.addingTimeInterval(7200))
        let wobble = cloud(asOf: t0.addingTimeInterval(5), exhausts: t0.addingTimeInterval(7200.4))
        XCTAssertEqual(resend(old, wobble, now: t0.addingTimeInterval(5)), old)
        let moved = cloud(asOf: t0.addingTimeInterval(5), exhausts: t0.addingTimeInterval(9000))
        XCTAssertEqual(resend(old, moved, now: t0.addingTimeInterval(5)), moved)
    }

    func testAUsedUpBudgetDoesNotResendAsItsInstantAdvancesWithTheClock() {
        let old = cloud(asOf: t0, exhausts: t0)
        let later = cloud(asOf: t0.addingTimeInterval(5), exhausts: t0.addingTimeInterval(5))
        XCTAssertEqual(resend(old, later, now: t0.addingTimeInterval(5)), old)
        let soon = cloud(asOf: t0, exhausts: t0.addingTimeInterval(10))
        XCTAssertEqual(resend(soon, cloud(asOf: t0.addingTimeInterval(11), exhausts: t0.addingTimeInterval(11)),
                              now: t0.addingTimeInterval(11))?.budgetExhaustsAt, t0.addingTimeInterval(11),
                       "running out is a change")
    }

    func testASessionThatLostItsMachinesIsRemoved() {
        XCTAssertNil(resend(cloud(asOf: t0), nil, now: t0))
    }

    // MARK: The monitor

    private func emitted(_ r: FleetReplicator) -> [WireSessionCloud?] {
        r.recorded.compactMap { if case .sessionCloudChanged(_, let c) = $0 { c } else { nil } }
    }

    func testRecordsAMachineOnceThenQuietUntilItIsGone() throws {
        let replicator = attachedReplicator(to: store)
        let monitor = SessionCloudMonitor(service: h.service, store: store, clock: h.clock)
        try own("gpu")

        monitor.start()
        XCTAssertEqual(emitted(replicator).count, 1)
        XCTAssertEqual(FleetProjection.snapshot(of: store).projects[0].sessions[0].cloud?.machines.map(\.name), ["gpu"])

        h.clock.advance(by: 120)
        XCTAssertEqual(emitted(replicator).count, 1, "spend growing is not an event")

        h.clock.advance(by: 200)
        XCTAssertEqual(emitted(replicator).count, 2, "the baseline is re-anchored after 5 minutes")
        XCTAssertEqual(emitted(replicator).last??.asOf, t0.addingTimeInterval(300), "re-anchored at the tick that fired")

        try h.registry.remove(name: "gpu")
        h.clock.advance(by: 5)
        XCTAssertEqual(emitted(replicator).count, 3)
        XCTAssertNil(emitted(replicator).last!)
        XCTAssertNil(FleetProjection.snapshot(of: store).projects[0].sessions[0].cloud)
        monitor.stop()
    }

    func testAStateChangeIsSentWithoutWaitingForTheReanchor() throws {
        let replicator = attachedReplicator(to: store)
        let monitor = SessionCloudMonitor(service: h.service, store: store, clock: h.clock)
        var m = try own("gpu", state: .provisioning)
        monitor.start()
        m.state = .ready
        try h.registry.upsert(m)
        h.clock.advance(by: 5)
        XCTAssertEqual(emitted(replicator).compactMap { $0?.machines[0].state }, ["provisioning", "ready"])
        monitor.stop()
    }

    func testNothingIsComputedOrRecordedWithoutMachines() {
        let replicator = attachedReplicator(to: store)
        let monitor = SessionCloudMonitor(service: h.service, store: store, clock: h.clock)
        monitor.start()
        h.clock.advance(by: 600)
        XCTAssertTrue(replicator.recorded.isEmpty)
        XCTAssertTrue(store.sessionClouds.isEmpty)
        monitor.stop()
    }

    func testASessionTheStoreDoesNotHoldIsDropped() throws {
        let replicator = attachedReplicator(to: store)
        try own("ghost", session: UUID())
        SessionCloudMonitor(service: h.service, store: store, clock: h.clock).refresh()
        XCTAssertTrue(replicator.recorded.isEmpty, "an event for an unknown tab would fold into nothing")
    }

    func testAnOperationFinishingRefreshesAtOnce() async throws {
        let monitor = SessionCloudMonitor(service: h.service, store: store, clock: h.clock)
        try own("gpu", machineDeadline: 7200)
        monitor.start()
        let before = try XCTUnwrap(store.sessionClouds[session.id])

        let done = XCTestExpectation(description: "extend answered")
        h.service.handle(.extend(name: "gpu", seconds: 600), cid: 1) { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 10)
        await Task.yield()

        let after = try XCTUnwrap(store.sessionClouds[session.id])
        XCTAssertEqual(after.machines[0].deadline, before.machines[0].deadline.addingTimeInterval(600),
                       "the new deadline reached the store without waiting for the 5 s tick")
        monitor.stop()
    }

    // MARK: The store

    func testRecordingTheSameCloudTwiceEmitsOnce() {
        let replicator = attachedReplicator(to: store)
        let c = cloud(asOf: t0)
        store.recordSessionClouds([session.id: c])
        store.recordSessionClouds([session.id: c])
        XCTAssertEqual(emitted(replicator), [c])
        store.recordSessionClouds([:])
        XCTAssertEqual(emitted(replicator).count, 2)
        XCTAssertNil(store.sessionClouds[session.id])
    }

    /// A phone that never claimed `cloud` throws on the `session.cloud` tag, so neither the live
    /// broadcast nor a resume replay may carry it.
    func testOnlyCloudCapablePeersGetTheEvent() {
        let event = FleetEvent.sessionCloudChanged(id: session.id, cloud: cloud(asOf: t0))
        XCTAssertEqual(FleetService.requiredCapability(for: event), FleetCapability.cloud)
        let frames: [ServerFrame] = [.event(seq: 1, .projectCollapsed(id: UUID(), isCollapsed: true)), .event(seq: 2, event)]
        XCTAssertEqual(FleetService.deliverable(frames, caps: []).count, 1)
        XCTAssertEqual(FleetService.deliverable(frames, caps: [FleetCapability.cloud]).count, 2)
    }
}
