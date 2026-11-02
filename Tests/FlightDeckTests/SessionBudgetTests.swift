import FleetKit
import HostKit
import XCTest
@testable import FlightDeck

/// Session budgets (`/budget`): counted from the ledger's segments of the session's own
/// machines, checked at `up` and `extend`, and enforced by the Reaper, all over the faked cloud.
/// The harness prices every machine at $0.50/h.
@MainActor
final class SessionBudgetTests: XCTestCase {
    var h: InfraHarness!
    var spy: SpyInfraNotifier!
    var reaper: Reaper!
    let tab = UUID()
    let other = UUID()

    override func setUp() async throws {
        h = try InfraHarness()
        spy = SpyInfraNotifier()
        reaper = Reaper(service: h.service, hosts: h.hosts, clock: h.clock, notifier: spy, budget: { self.h.budget },
                        interval: 3600, pathChanges: { _ in ManualPathTrigger().watch {} })
    }

    override func tearDown() async throws {
        reaper.stop()
        reaper = nil; spy = nil; h = nil
    }

    let gpu = InfraConfig(source: .preset("aws-linux"), region: "us-east-1", instanceType: "t3.small", arch: nil, diskGB: nil,
                          spot: false, ttl: .init(seconds: 3600), idle: .init(seconds: 1800), autoUp: false, vars: [:], maxHourly: nil)

    private func up(_ name: String = "gpu", session: UUID?) async throws -> InfraMachine {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        return try await h.service.up(name: name, config: gpu, repoRoot: h.repo, owner: session.map(InfraOwner.session) ?? .setupTest) { self.h.events.append($0) }
    }

    // MARK: up

    func testUpRecordsTheSessionOnTheMachineAndItsSpend() async throws {
        let m = try await up(session: tab)
        XCTAssertEqual(m.session, tab)
        XCTAssertEqual(m.deadline, h.now.addingTimeInterval(3600), "no budget: the TTL's deadline")
        h.clock.advance(by: 1800)
        XCTAssertEqual(h.ledger.spent(session: tab, since: .distantPast, now: h.now), 0.25, accuracy: 1e-9)
        XCTAssertEqual(h.ledger.spent(session: other, since: .distantPast, now: h.now), 0)
    }

    func testUpWithinTheBudgetKeepsItsTTL() async throws {
        try h.budgets.set(tab, capUSD: 5, now: h.now)
        let m = try await up(session: tab)
        XCTAssertEqual(m.deadline, h.now.addingTimeInterval(3600))
        XCTAssertEqual(try h.tfvars("gpu")["ttl_seconds"] as? Double, 3600)
    }

    func testUpShortensTheDeadlineAndTheMachinesOwnTimerToTheBudget() async throws {
        try h.budgets.set(tab, capUSD: 0.3, now: h.now)          // 36 minutes at $0.50/h
        let m = try await up(session: tab)
        XCTAssertEqual(m.deadline.timeIntervalSince(m.createdAt), 36 * 60, accuracy: 1)
        XCTAssertEqual(m.machineDeadline, m.deadline, "extend can never outrun it")
        XCTAssertEqual(try h.tfvars("gpu")["ttl_seconds"] as? Double ?? 0, 36 * 60, accuracy: 1)
        XCTAssertTrue(h.events.contains { if case .progress(let l) = $0 { return l.contains("budget runs out in 36m") }; return false }, "\(h.events)")
    }

    func testUpIsRefusedOnceTheBudgetIsUsedUpAndNothingIsCreated() async throws {
        try h.budgets.set(tab, capUSD: 1, now: h.now.addingTimeInterval(-7200))
        try h.readyMachine("old", hourlyUSD: 1, createdAt: h.now.addingTimeInterval(-3600), session: tab)
        do { _ = try await up(session: tab); XCTFail() }
        catch InfraError.preflight(let checks) {
            XCTAssertEqual(checks.map(\.name), ["session budget"])
            XCTAssertTrue(checks[0].detail.contains("used up"), checks[0].detail)
        }
        XCTAssertEqual(h.tofu.calls, [], "nothing created")
        XCTAssertNil(h.registry.machine(named: "gpu"))
    }

    func testOnlyTheSessionsOwnMachinesCount() async throws {
        h.budget.maxConcurrent = 3
        try h.budgets.set(tab, capUSD: 1, now: h.now.addingTimeInterval(-7200))
        try h.readyMachine("theirs", hourlyUSD: 10, createdAt: h.now.addingTimeInterval(-3600), session: other)
        try h.readyMachine("shell", hourlyUSD: 10, createdAt: h.now.addingTimeInterval(-3600))
        let m = try await up(session: tab)
        XCTAssertEqual(m.deadline, h.now.addingTimeInterval(3600), "$0.50 of the $1 for the whole TTL")
    }

    func testTheSessionsRunningMachinesShortenANewOnesLife() async throws {
        // $0.75 left; `old` bills $0.50/h for 4h more, and with `gpu` the pair burns $1/h.
        try h.budgets.set(tab, capUSD: 0.75, now: h.now)
        try h.readyMachine("old", hourlyUSD: 0.5, session: tab)
        let m = try await up(session: tab)
        XCTAssertEqual(m.deadline.timeIntervalSince(h.now), 45 * 60, accuracy: 1)
    }

    func testRenewStartsTheSpendAgain() async throws {
        try h.budgets.set(tab, capUSD: 1, now: h.now.addingTimeInterval(-7200))
        try h.readyMachine("old", hourlyUSD: 1, createdAt: h.now.addingTimeInterval(-3600), session: tab)
        try h.service.registry.remove(name: "old")
        try h.ledger.close(name: "old", at: h.now)
        do { _ = try await up(session: tab); XCTFail("used up") } catch InfraError.preflight {}
        _ = try h.service.budget(.renew(usd: nil), session: tab)
        let m = try await up(session: tab)
        XCTAssertEqual(m.deadline, h.now.addingTimeInterval(3600))
    }

    func testTheSetupTestMachineHasNoSessionAndIgnoresEveryBudget() async throws {
        try h.budgets.set(tab, capUSD: 0.01, now: h.now)
        let m = try await up(session: nil)
        XCTAssertNil(m.session)
        XCTAssertEqual(m.deadline, h.now.addingTimeInterval(3600))
    }

    // MARK: extend

    func testExtendIsRefusedPastWhenTheBudgetRunsOut() async throws {
        try h.budgets.set(tab, capUSD: 2, now: h.now)
        var m = try h.readyMachine("gpu", deadline: h.now.addingTimeInterval(3600), hourlyUSD: 1, session: tab)
        m.machineDeadline = h.now.addingTimeInterval(8 * 3600)
        try h.registry.upsert(m)
        _ = try await h.service.extend(name: "gpu", by: .init(seconds: 3600))
        do { _ = try await h.service.extend(name: "gpu", by: .init(seconds: 60)); XCTFail() }
        catch InfraError.refused(let why) { XCTAssertTrue(why.contains("runs out in 2h"), why) }
    }

    // MARK: infra.budget

    func testBudgetActions() async throws {
        var b = try h.service.budget(.show, session: tab)
        XCTAssertNil(b.capUsd)
        XCTAssertTrue(b.line.hasPrefix("no cloud budget for this session"), b.line)

        b = try h.service.budget(.set(usd: 20), session: tab)
        XCTAssertEqual(b.capUsd, 20); XCTAssertEqual(b.remainingUsd, 20)
        try h.readyMachine("gpu", hourlyUSD: 2, session: tab)
        h.clock.advance(by: 3600)
        b = try h.service.budget(.set(usd: 10), session: tab)
        XCTAssertEqual(b.spentUsd, 2, accuracy: 1e-9, "set keeps the window")
        XCTAssertEqual(b.hourlyUsd, 2)
        XCTAssertEqual(b.exhaustsIn, nil, "$2/h for the 3h left is $6, under the $8 left")
        XCTAssertEqual(b.machines, ["gpu"])
        XCTAssertTrue(b.line.contains("lasts past every machine's TTL"), b.line)

        b = try h.service.budget(.renew(usd: 4), session: tab)
        XCTAssertEqual(b.spentUsd, 0); XCTAssertEqual(b.capUsd, 4)
        XCTAssertEqual(b.exhaustsIn, 2 * 3600)
        XCTAssertTrue(b.line.contains("runs out in 2h"), b.line)

        b = try h.service.budget(.clear, session: tab)
        XCTAssertNil(b.capUsd)
        XCTAssertNil(h.budgets.budget(for: tab))
    }

    func testBudgetRefusals() throws {
        do { _ = try h.service.budget(.renew(usd: nil), session: tab); XCTFail() }
        catch InfraError.refused(let why) { XCTAssertTrue(why.contains("no budget to renew"), why) }
        for bad in [0, -1, .infinity, .nan] {
            do { _ = try h.service.budget(.set(usd: bad), session: tab); XCTFail("\(bad)") }
            catch InfraError.refused {}
        }
    }

    func testBudgetsPersist() throws {
        try h.budgets.set(tab, capUSD: 7, now: h.now)
        let again = SessionBudgets(fileURL: h.root.appendingPathComponent("infra-budgets.json"))
        XCTAssertEqual(again.budget(for: tab), SessionBudget(session: tab, capUSD: 7, since: h.now))
    }

    func testCostLineCarriesTheSessionBudget() throws {
        try h.budgets.set(tab, capUSD: 5, now: h.now)
        let m = try h.readyMachine("gpu", hourlyUSD: 1, session: tab)
        h.clock.advance(by: 3600)
        XCTAssertTrue(h.service.costLine(for: m, now: h.now).hasSuffix("session ~$1.00 of $5.00"), h.service.costLine(for: m, now: h.now))
    }

    // MARK: Reaper

    func testReaperDestroysEverySessionMachineOnceTheBudgetIsUsedUp() async throws {
        h.budget.perMachineCapUSD = nil; h.budget.monthlyCapUSD = nil
        try h.budgets.set(tab, capUSD: 1, now: h.now)
        try h.readyMachine("a", hourlyUSD: 0.5, session: tab)
        try h.readyMachine("b", hourlyUSD: 0.5, session: tab)
        try h.readyMachine("theirs", hourlyUSD: 0.5, session: other)
        h.clock.advance(by: 50 * 60); await reaper.tick()
        XCTAssertTrue(spy.sent.contains { $0.body.contains("runs out in 10 minutes") }, "\(spy.sent)")
        XCTAssertTrue(h.tofu.destroyed.isEmpty)
        h.clock.advance(by: 10 * 60); await reaper.tick()
        XCTAssertEqual(Set(h.tofu.destroyed), ["a", "b"], "the session's machines, at once, and no one else's")
        XCTAssertNotNil(h.registry.machine(named: "theirs"))
        XCTAssertTrue(spy.sent.contains { $0.body.contains("$1.00 cloud budget is used up") }, "\(spy.sent)")
    }

    func testRaisingTheBudgetKeepsTheMachines() async throws {
        h.budget.perMachineCapUSD = nil; h.budget.monthlyCapUSD = nil
        try h.budgets.set(tab, capUSD: 1, now: h.now)
        try h.readyMachine("a", hourlyUSD: 1, session: tab)
        h.clock.advance(by: 3600)
        try h.budgets.set(tab, capUSD: 10, now: h.now)
        await reaper.tick()
        XCTAssertTrue(h.tofu.destroyed.isEmpty)
    }

    // MARK: control socket

    func testBudgetOverTheSocketNeedsATab() async throws {
        let none = await frames(.budget(.show), session: nil)
        guard case .err(_, let code, _)? = none.last else { return XCTFail("\(none)") }
        XCTAssertEqual(code, "infra_no_session")
        let mine = await frames(.budget(.set(usd: 3)), session: tab)
        guard case .infraBudget(7, let b)? = mine.last else { return XCTFail("\(mine)") }
        XCTAssertEqual(b.session, tab.uuidString); XCTAssertEqual(b.capUsd, 3)
    }

    private func frames(_ request: InfraRequest, session: UUID?) async -> [ServerFrame] {
        var frames: [ServerFrame] = []
        let done = XCTestExpectation(description: "terminal frame")
        h.service.handle(request, session: session, cid: 7) { frame in
            frames.append(frame)
            if !frame.continuesStream { done.fulfill() }
        }
        await fulfillment(of: [done], timeout: 10)
        return frames
    }

    // MARK: wire

    func testBudgetRequestsAndReplyRoundTrip() throws {
        for action: InfraRequest.BudgetAction in [.show, .set(usd: 20), .renew(usd: nil), .renew(usd: 5.5), .clear] {
            let r = FleetRequest.infra(.budget(action))
            let data = try JSONEncoder().encode(r)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"infra.budget\""))
            XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: data), r)
        }
        let reply = ServerFrame.infraBudget(cid: 3, WireSessionBudget(
            session: tab.uuidString, capUsd: 5, since: "2026-10-24T00:00:00Z", spentUsd: 1, remainingUsd: 4, hourlyUsd: 0.5,
            exhaustsIn: 28_800, machines: ["gpu"], line: "x"))
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(reply)), reply)
        XCTAssertEqual(reply.correlationID, 3)
        XCTAssertFalse(reply.continuesStream)
    }

    func testOnlyBudgetShowIsReadOnlyAndATabMayChangeItsOwnUnderOwnSession() {
        XCTAssertTrue(InfraRequest.budget(.show).isReadOnly)
        XCTAssertFalse(InfraRequest.budget(.set(usd: 1)).isReadOnly)
        let set = FleetRequest.infra(.budget(.set(usd: 1)))
        XCTAssertTrue(ControlScope.permits(set, level: .ownSession, caller: .session(tab)))
        XCTAssertFalse(ControlScope.permits(set, level: .readOnly, caller: .session(tab)))
        XCTAssertFalse(ControlScope.permits(set, level: .ownSession, caller: .invalid))
        XCTAssertFalse(ControlScope.permits(.infra(.up(name: "gpu", cwd: "/")), level: .ownSession, caller: .session(tab)))
    }
}
