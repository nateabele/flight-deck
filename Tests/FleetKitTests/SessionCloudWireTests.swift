import XCTest
import FleetKit

/// `WireSessionCloud` and the `session.cloud` event: the coding contract an older phone relies
/// on (absent when nil), the fold, the mirror, and the extrapolation a client draws spend from.
final class SessionCloudWireTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func machine(_ name: String = "gpu", state: String = "ready", spent: Double = 1) -> WireCloudMachine {
        WireCloudMachine(name: name, cloud: "aws", instanceType: "g6.xlarge", region: "us-east-1", state: state,
                         network: "tailnet", hourlyUsd: 0.8, spentUsd: spent, createdAt: t0.addingTimeInterval(-3600),
                         deadline: t0.addingTimeInterval(7200), machineDeadline: t0.addingTimeInterval(10_800))
    }

    private func cloud(machines: [WireCloudMachine]? = nil, spent: Double = 4, hourly: Double = 2,
                       cap: Double? = 10) -> WireSessionCloud {
        WireSessionCloud(asOf: t0, machines: machines ?? [machine()], spentUsd: spent, hourlyUsd: hourly,
                         budgetCapUsd: cap, budgetSince: cap == nil ? nil : t0.addingTimeInterval(-7200),
                         budgetExhaustsAt: cap == nil ? nil : t0.addingTimeInterval(10_800),
                         monthUsd: 14.2, monthCapUsd: 50)
    }

    // MARK: Coding

    func testSessionWithoutCloudWritesNoKeyAndDecodesToNil() throws {
        let data = try JSONEncoder().encode(WireSession(id: UUID(), title: "t", agent: "claude"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["cloud"], "absent, not null: an older phone sees the bytes it always saw")
        XCTAssertNil(try JSONDecoder().decode(WireSession.self, from: data).cloud)
    }

    func testSessionWithCloudRoundTrips() throws {
        let s = WireSession(id: UUID(), title: "t", agent: "claude", cloud: cloud())
        let back = try JSONDecoder().decode(WireSession.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.cloud, s.cloud)
        XCTAssertEqual(back, s)
    }

    func testAReshapedCloudCostsTheIconNotTheSession() throws {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(WireSession(id: UUID(), title: "t", agent: "claude"))) as? [String: Any])
        object["cloud"] = ["machines": "nope"]
        let data = try JSONSerialization.data(withJSONObject: object)
        let s = try JSONDecoder().decode(WireSession.self, from: data)
        XCTAssertNil(s.cloud)
        XCTAssertEqual(s.title, "t")
    }

    func testCloudChangedEventRoundTripsAndNilIsAbsent() throws {
        let id = UUID()
        for event in [FleetEvent.sessionCloudChanged(id: id, cloud: cloud()), .sessionCloudChanged(id: id, cloud: nil)] {
            let data = try JSONEncoder().encode(event)
            XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), event)
        }
        let cleared = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(FleetEvent.sessionCloudChanged(id: id, cloud: nil))) as? [String: Any]
        XCTAssertEqual(cleared?["t"] as? String, "session.cloud")
        XCTAssertNil(cleared?["cloud"])
    }

    // MARK: Fold and mirror

    private let a = UUID(), projectID = UUID()
    private func base() -> FleetSnapshot {
        FleetSnapshot(projects: [WireProject(id: projectID, name: "p", path: "/p",
                                             sessions: [WireSession(id: a, title: "a", agent: "claude")])])
    }

    func testFoldKeepsTheLastCloudPerSession() {
        let events: [FleetEvent] = [.sessionCloudChanged(id: a, cloud: cloud(spent: 1)),
                                    .sessionCloudChanged(id: a, cloud: nil),
                                    .sessionCloudChanged(id: a, cloud: cloud(spent: 3))]
        XCTAssertEqual(FleetReplay.fold(events), [.sessionCloudChanged(id: a, cloud: cloud(spent: 3))])
        XCTAssertEqual(base().applying(FleetReplay.fold(events)), base().applying(events))
    }

    func testApplyingSetsAndClearsTheCloud() {
        let set = base().applying([.sessionCloudChanged(id: a, cloud: cloud())])
        XCTAssertEqual(set.projects[0].sessions[0].cloud, cloud())
        XCTAssertNil(set.applying([.sessionCloudChanged(id: a, cloud: nil)]).projects[0].sessions[0].cloud)
    }

    // MARK: Figures a client draws

    func testSpentExtrapolatesAtTheRateAndNeverBackwards() {
        let c = cloud(spent: 4, hourly: 2)
        XCTAssertEqual(c.spent(at: t0.addingTimeInterval(1800)), 5, accuracy: 1e-9)
        XCTAssertEqual(c.spent(at: t0.addingTimeInterval(-600)), 4, accuracy: 1e-9)
    }

    func testRemainingIsNilWithoutABudgetAndNeverNegative() {
        XCTAssertNil(cloud(cap: nil).remaining(at: t0))
        XCTAssertEqual(try XCTUnwrap(cloud(spent: 4, hourly: 2, cap: 10).remaining(at: t0.addingTimeInterval(3600))), 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(cloud(spent: 4, hourly: 2, cap: 10).remaining(at: t0.addingTimeInterval(36_000))), 0)
    }

    func testMachineSpendStopsAtItsDeadlineAndWhenGone() {
        let m = machine(spent: 1)
        XCTAssertEqual(m.spent(asOf: t0, at: t0.addingTimeInterval(3600)), 1.8, accuracy: 1e-9)
        XCTAssertEqual(m.spent(asOf: t0, at: t0.addingTimeInterval(100 * 3600)), 1 + 0.8 * 2, accuracy: 1e-9)
        XCTAssertEqual(machine(state: "gone", spent: 1).spent(asOf: t0, at: t0.addingTimeInterval(3600)), 1)
    }

    func testStructureIgnoresOnlyTheClockDrivenFigures() {
        var moved = cloud(spent: 4)
        moved.asOf = t0.addingTimeInterval(60)
        moved.spentUsd = 4.5
        moved.monthUsd = 15
        moved.machines[0].spentUsd = 1.2
        XCTAssertEqual(moved.structure, cloud(spent: 4).structure)
        XCTAssertNotEqual(cloud(machines: [machine(state: "failed")]).structure, cloud().structure)
        XCTAssertNotEqual(cloud(hourly: 3).structure, cloud(hourly: 2).structure)
        XCTAssertNotEqual(cloud(cap: nil).structure, cloud().structure)
    }

    func testBadgeIsTheWorstMachineOrAnExhaustedBudget() {
        XCTAssertEqual(cloud().badge, .ready)
        XCTAssertEqual(cloud(machines: [machine(), machine("b", state: "idle")]).badge, .ready)
        XCTAssertEqual(cloud(machines: [machine(), machine("b", state: "provisioning")]).badge, .busy)
        XCTAssertEqual(cloud(machines: [machine(state: "provisioning"), machine("b", state: "failed")]).badge, .failed)
        XCTAssertEqual(cloud(machines: [machine(state: "orphaned")]).badge, .failed)
        var used = cloud()
        used.budgetExhaustsAt = t0
        XCTAssertEqual(used.badge, .failed)
    }
}
