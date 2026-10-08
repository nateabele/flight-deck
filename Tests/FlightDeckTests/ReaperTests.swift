import HostKit
import XCTest
@testable import FlightDeck

/// The Reaper (spec §7.2, §7.3, §8.2) against `InfraHarness`: every destroy is `FakeTofu`'s,
/// every notification `SpyInfraNotifier`'s, and time moves only when the test advances it.
@MainActor
final class ReaperTests: XCTestCase {
    var h: InfraHarness!
    var spy: SpyInfraNotifier!
    var reaper: Reaper!

    override func setUp() async throws {
        h = try InfraHarness()
        spy = SpyInfraNotifier()
        reaper = Reaper(service: h.service, hosts: h.hosts, clock: h.clock, notifier: spy, budget: { self.h.budget })
    }

    override func tearDown() async throws {
        reaper.stop()
        reaper = nil; spy = nil; h = nil
    }

    func testWarnsTenMinutesBeforeTTLThenDestroys() async throws {
        try h.readyMachine("gpu", deadline: h.now.addingTimeInterval(9 * 60))
        await reaper.tick()
        XCTAssertTrue(spy.sent.contains { $0.body.contains("10 minutes") || $0.body.contains("9 minutes") }, "\(spy.sent)")
        XCTAssertFalse(h.tofu.destroyed.contains("gpu"))
        h.clock.advance(by: 9 * 60 + 1); await reaper.tick()
        XCTAssertTrue(h.tofu.destroyed.contains("gpu"))
        XCTAssertNil(h.registry.machine(named: "gpu"))
    }

    func testTTLWarningIsSentOnce() async throws {
        try h.readyMachine("gpu", deadline: h.now.addingTimeInterval(9 * 60))
        await reaper.tick()
        h.clock.advance(by: 60); await reaper.tick()
        XCTAssertEqual(spy.sent.filter { $0.body.contains("minutes") }.count, 1, "\(spy.sent)")
    }

    func testIdleDestroys() async throws {
        try h.readyMachine("gpu", idle: .init(seconds: 1800))
        h.hostInfo("gpu", idleSince: h.now.addingTimeInterval(-1801))
        await reaper.tick()
        XCTAssertTrue(h.tofu.destroyed.contains("gpu"))
    }

    func testBusyMachineIsNotIdle() async throws {
        try h.readyMachine("gpu", idle: .init(seconds: 1800))
        h.hostInfo("gpu", idleSince: nil)
        await reaper.tick()
        XCTAssertFalse(h.tofu.destroyed.contains("gpu"))
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .ready)
    }

    /// Idle but not yet for long enough: shown as idle, and back to ready once work arrives.
    func testIdleStateFollowsTheHost() async throws {
        try h.readyMachine("gpu", idle: .init(seconds: 1800))
        h.hostInfo("gpu", idleSince: h.now.addingTimeInterval(-60))
        await reaper.tick()
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .idle)
        XCTAssertFalse(h.tofu.destroyed.contains("gpu"))
        h.hostInfo("gpu", idleSince: nil)
        await reaper.tick()
        XCTAssertEqual(h.registry.machine(named: "gpu")?.state, .ready)
    }

    /// An unreachable host says nothing about idleness, so it is never reaped on idle.
    func testOfflineHostIsNotReapedOnIdle() async throws {
        let m = try h.readyMachine("gpu", idle: .init(seconds: 1800))
        h.hostInfo("gpu", idleSince: h.now.addingTimeInterval(-7200))
        h.dialer.takeDown(m.slot!)
        await reaper.tick()
        XCTAssertFalse(h.tofu.destroyed.contains("gpu"))
    }

    func testBudgetDestroyAfterFiveMinuteWarning() async throws {
        h.budget.perMachineCapUSD = 1
        try h.readyMachine("gpu", hourlyUSD: 1, createdAt: h.now.addingTimeInterval(-3600))
        await reaper.tick()
        XCTAssertFalse(h.tofu.destroyed.contains("gpu")); XCTAssertTrue(spy.sent.contains { $0.title.contains("budget") }, "\(spy.sent)")
        h.clock.advance(by: 301); await reaper.tick()
        XCTAssertTrue(h.tofu.destroyed.contains("gpu"))
    }

    /// Spec §8.2: raising the cap is the one thing that saves a machine over budget.
    func testRaisingTheCapCancelsTheBudgetDestroy() async throws {
        h.budget.perMachineCapUSD = 1
        try h.readyMachine("gpu", hourlyUSD: 1, createdAt: h.now.addingTimeInterval(-3600))
        await reaper.tick()
        h.budget.perMachineCapUSD = 100
        h.clock.advance(by: 120); await reaper.tick()
        h.clock.advance(by: 240); await reaper.tick()
        XCTAssertFalse(h.tofu.destroyed.contains("gpu"))
    }

    func testBudgetWarningIsSentOncePerThreshold() async throws {
        h.budget.perMachineCapUSD = 10
        try h.readyMachine("gpu", hourlyUSD: 8.5, createdAt: h.now.addingTimeInterval(-3600))
        await reaper.tick()
        h.clock.advance(by: 60); await reaper.tick()
        XCTAssertEqual(spy.sent.filter { $0.title.contains("budget") }.count, 1, "\(spy.sent)")
        XCTAssertFalse(h.tofu.destroyed.contains("gpu"))
    }

    func testDriftMarksGone() async throws {
        try h.readyMachine("gpu"); h.tofu.goneOnRefresh.insert("gpu")
        await reaper.tick()
        XCTAssertNil(h.registry.machine(named: "gpu")); XCTAssertTrue(h.hosts.registry.hosts.isEmpty)
    }

    func testDriftIsCheckedAtMostEveryTenMinutes() async throws {
        try h.readyMachine("gpu")
        await reaper.tick()
        h.clock.advance(by: 300); await reaper.tick()
        XCTAssertEqual(h.tofu.calls.filter { $0 == "refresh" }.count, 1)
        h.clock.advance(by: 301); await reaper.tick()
        XCTAssertEqual(h.tofu.calls.filter { $0 == "refresh" }.count, 2)
    }

    /// Review Focus 5.
    func testPublicIPChangeReappliesFirewall() async throws {
        try h.readyMachine("gpu", network: .public, allowCIDR: "203.0.113.9/32")
        h.publicIP = "203.0.113.77"
        await reaper.linkLost(name: "gpu")
        XCTAssertEqual(try h.tfvars("gpu")["fd_allow_cidr"] as? String, "203.0.113.77/32")
        XCTAssertEqual(h.tofu.calls.last, "apply")
        XCTAssertEqual(h.registry.machine(named: "gpu")?.allowCIDR, "203.0.113.77/32")
    }

    func testSameIPDoesNotReapply() async throws {
        try h.readyMachine("gpu", network: .public, allowCIDR: "203.0.113.9/32")
        h.publicIP = "203.0.113.9"; let before = h.tofu.calls
        await reaper.linkLost(name: "gpu")
        XCTAssertEqual(h.tofu.calls, before)
    }

    func testTailnetMachineNeverReapplies() async throws {
        try h.readyMachine("gpu", network: .tailnet)
        h.publicIP = "203.0.113.77"
        await reaper.linkLost(name: "gpu")
        XCTAssertEqual(h.tofu.calls, [])
        XCTAssertEqual(h.publicIPCalls, 0)
    }

    /// A public machine whose link stays down for 30 s has its firewall re-checked; one that
    /// comes back inside the window does not.
    func testOfflineLinkTriggersLinkLostAfterDebounce() async throws {
        let m = try h.readyMachine("gpu", network: .public, allowCIDR: "203.0.113.9/32")
        h.publicIP = "203.0.113.77"
        reaper.start()
        h.dialer.takeDown(m.slot!)
        h.clock.advance(by: 29)
        XCTAssertEqual(h.publicIPCalls, 0, "not before the debounce")
        h.clock.advance(by: 2)
        try await waitUntil { self.h.registry.machine(named: "gpu")?.allowCIDR == "203.0.113.77/32" }
        XCTAssertEqual(h.tofu.calls.last, "apply")
    }

    func testLinkBackWithinTheDebounceDoesNothing() async throws {
        let m = try h.readyMachine("gpu", network: .public, allowCIDR: "203.0.113.9/32")
        h.publicIP = "203.0.113.77"
        reaper.start()
        h.dialer.takeDown(m.slot!)
        h.clock.advance(by: 10)
        h.dialer.bringUp(m.slot!)
        h.clock.advance(by: 1)    // the link's backoff redial, which now finds the host up
        XCTAssertEqual(h.hosts.statuses[m.slot!], .online(hostName: "cloud"))
        h.clock.advance(by: 40)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(h.publicIPCalls, 0)
    }

    func testStartTicksOnTheInterval() async throws {
        reaper = Reaper(service: h.service, hosts: h.hosts, clock: h.clock, notifier: spy, budget: { self.h.budget }, interval: 60)
        try h.readyMachine("gpu", deadline: h.now.addingTimeInterval(90))
        reaper.start()
        h.clock.advance(by: 61)
        try await waitUntil { self.spy.sent.contains { $0.body.contains("minute") } }
        h.clock.advance(by: 61)
        try await waitUntil { self.h.tofu.destroyed.contains("gpu") }
        reaper.stop()
    }

    /// Polls the main actor until `condition` holds: a timer-driven pass runs in its own task.
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition never held", file: file, line: line)
    }
}
