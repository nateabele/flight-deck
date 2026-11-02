import HostKit
import XCTest
@testable import FlightDeck

/// A cloud machine belongs to a session and goes when the session closes.
@MainActor
final class InfraSessionOwnershipTests: XCTestCase {
    var h: InfraHarness!
    override func setUp() async throws { h = try InfraHarness() }
    override func tearDown() async throws { h = nil }

    let gpu = InfraConfig(source: .preset("aws-linux"), region: "us-east-1", instanceType: "t3.small", arch: nil, diskGB: nil,
                          spot: false, ttl: .init(seconds: 3600), idle: .init(seconds: 1800), autoUp: false, vars: [:], maxHourly: nil)
    private let other = UUID()

    private func gone(_ name: String) -> Bool {
        h.registry.machine(named: name).map { $0.state == .gone } ?? true
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    /// A ready machine in the harness repo, as `up` from that repo would have left it.
    @discardableResult
    private func ready(_ name: String, session: UUID?) throws -> InfraMachine {
        var m = try h.readyMachine(name, session: session)
        m.repoRoot = h.repo.standardizedFileURL.path
        try h.registry.upsert(m)
        return m
    }

    func testClosingASessionDestroysItsMachinesAndNoOthers() async throws {
        try ready("mine", session: Self.infraTab)
        try ready("also-mine", session: Self.infraTab)
        try ready("theirs", session: other)
        try ready("legacy", session: nil)
        h.service.sessionClosed(Self.infraTab)
        try await until { self.gone("mine") && self.gone("also-mine") }
        XCTAssertEqual(h.registry.machine(named: "theirs")?.state, .ready)
        XCTAssertEqual(h.registry.machine(named: "legacy")?.state, .ready)
    }

    func testClosingASessionWhoseMachineIsStillComingUpDestroysItOnceUpFinishes() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        var closed = false
        do {
            _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo, owner: Self.infraOwner) { event in
                if !closed, case .progress = event { closed = true; self.h.service.sessionClosed(Self.infraTab) }
            }
            XCTFail("the up should be refused")
        } catch InfraError.refused(let why) {
            XCTAssertTrue(why.contains("closed"), why)
        }
        XCTAssertTrue(closed)
        XCTAssertTrue(gone("gpu"), "\(String(describing: h.registry.machine(named: "gpu")))")
    }

    func testClosingATabInTheStoreDestroysItsMachine() async throws {
        let store = SessionStore(provider: nil, persistence: nil,
                                 preferences: PreferencesStore(persistence: SessionAutoResumeTests.MemoryPreferences()))
        store.infraHooks = h.service
        let session = store.newSession(in: h.repo)
        try ready("mine", session: session.id)
        try ready("theirs", session: other)
        store.closeSession(session.id)
        try await until { self.gone("mine") }
        XCTAssertEqual(h.registry.machine(named: "theirs")?.state, .ready)
    }

    /// Reopening a closed session reuses its id (`closeSession`), so a close must not bar that
    /// id from provisioning for the rest of the run: only an `up` the close overtook is undone.
    func testAReopenedSessionCanStartAMachine() async throws {
        h.tofu.outputs = TofuOutputs(address: "198.51.100.7", instanceID: "i-1", hourlyUSD: nil)
        h.hostComesOnline(after: .applied)
        h.service.sessionClosed(Self.infraTab)
        let machine = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo, owner: Self.infraOwner) { _ in }
        XCTAssertEqual(machine.session, Self.infraTab)
        XCTAssertNotEqual(h.registry.machine(named: "gpu")?.state, .gone)
    }

    func testAnotherSessionCannotTakeOverARunningMachine() async throws {
        try ready("gpu", session: other)
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo, owner: Self.infraOwner) { _ in }; XCTFail() }
        catch InfraError.nameInUse(let why) { XCTAssertTrue(why.contains("another Flight Deck session"), why) }
        XCTAssertEqual(h.registry.machine(named: "gpu")?.session, other)
        do { _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo, owner: .setupTest) { _ in }; XCTFail() }
        catch InfraError.nameInUse {}
    }

    func testTheOwnerReusesItsMachineAndALegacyOneBecomesTheAskers() async throws {
        try ready("gpu", session: Self.infraTab)
        try ready("old", session: nil)
        _ = try await h.service.up(name: "gpu", config: gpu, repoRoot: h.repo, owner: Self.infraOwner) { _ in }
        let taken = try await h.service.up(name: "old", config: gpu, repoRoot: h.repo, owner: Self.infraOwner) { _ in }
        XCTAssertEqual(taken.session, Self.infraTab)
        XCTAssertEqual(h.registry.machine(named: "old")?.session, Self.infraTab)
    }
}
