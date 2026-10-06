import XCTest
import IntakeKit
@testable import FlightDeck

/// The one test that runs Level 3 as the maintainer will: a released task routes by a confirmed rule,
/// leases the first account under soft, starts, and — when that account crosses hard — is
/// handed to a fresh agent on the next account with the transcript path in its first prompt.
/// Every sub-branch tested its piece against fakes of the others; this is the first time the
/// real pieces meet, so it asserts on the seams, not the internals.
@MainActor
final class SwarmEndToEndTests: XCTestCase {
    private var rig: L3IntegrationRig!

    override func setUp() async throws {
        let rule = RoutingRule(id: "r-tests", sentence: "Use Codex for unit and integration tests",
                               compiled: CompiledRule(match: .any([.dimension("test-authoring", atLeast: 0.5)]),
                                                      assign: RuleAssign(harness: "codex", model: "gpt-6-sol",
                                                                         knobs: ["effort": "high"], pool: "codex-default")),
                               state: .confirmed)
        rig = try L3IntegrationRig.make(accounts: ["Work", "Personal"], harness: "codex", rule: rule, readyTasks: ["fx-valid"])
    }

    override func tearDown() async throws {
        await rig?.swarm.settle()
        rig = nil
    }

    func testTaskRoutesLeasesFirstAccountAndStarts() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let spawn = try XCTUnwrap(rig.spawns.first)
        XCTAssertEqual(spawn.block.harness, "codex")
        XCTAssertEqual(spawn.block.model, "gpt-6-sol")
        XCTAssertEqual(spawn.block.source.ruleId, "r-tests", "routed by the confirmed rule, not a default")
        XCTAssertEqual(spawn.lease?.account.label, "Work", "first account in pool order under soft")
        XCTAssertTrue(rig.runner.argv.contains { $0.starts(with: ["br", "update", "fx-valid", "--claim"]) })
        XCTAssertTrue(spawn.firstPrompt.contains("Your task is fx-valid"))
    }

    func testSoftThresholdMovesNewWorkToNextAccount() async throws {
        rig.feed(account: "Work", utilization: 0.85)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        XCTAssertEqual(rig.spawns.first?.lease?.account.label, "Personal")
    }

    func testHardThresholdHandsOffWithTranscriptPointer() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        await rig.tick()
        XCTAssertEqual(rig.spawns.count, 2)
        let handoff = try XCTUnwrap(rig.spawns.dropFirst().first)
        XCTAssertEqual(handoff.lease?.account.label, "Personal")
        XCTAssertTrue(handoff.firstPrompt.contains("stopped because its account reached its usage limit"))
        XCTAssertTrue(handoff.firstPrompt.contains(rig.transcriptPath(of: first.session)), handoff.firstPrompt)
        XCTAssertTrue(rig.runner.argv.contains { $0.starts(with: ["br", "update", "fx-valid", "--assignee"]) })
        XCTAssertTrue(rig.isHandedOff(first.session))
    }

    func testPausedSwarmStillHandsOff() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        rig.swarm.pause(project: rig.project)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        await rig.tick()
        XCTAssertEqual(rig.spawns.count, 2, "pause stops new claims, not hand-offs")
    }

    func testSharedAccountRefusedInBothPools() async throws {
        rig.addPool(id: "codex-subs", accounts: ["Work"])
        rig.feed(account: "Work", utilization: 0.85)
        XCTAssertNil(rig.usage.ledger.lease(pool: "codex-subs"))
        XCTAssertNotEqual(rig.usage.ledger.lease(pool: "codex-default")?.account.label, "Work")
    }

    func testDeletedPoolMakesTaskWaitWithReason() async throws {
        rig.setBlockPool(task: "fx-valid", pool: "gone", pinned: true)
        try await rig.launch(cap: 1)
        await rig.tick()
        XCTAssertTrue(rig.spawns.isEmpty)
        XCTAssertEqual(rig.waitingReason(task: "fx-valid"), "pool gone no longer exists")
    }

    // MARK: - Composition seams (controller rulings 5, 6 and the driver's lifetime)

    /// Ruling 6: the driver and the swarm controller both used to release the old lease. The
    /// driver owns it now (it alone knows whether the old agent was actually stopped).
    func testHandoffReleasesTheOldLeaseOnce() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        let oldLease = try XCTUnwrap(first.lease)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        await rig.tick()
        XCTAssertTrue(rig.isHandedOff(first.session))
        XCTAssertEqual(rig.allocator.releases(of: oldLease), 1)
    }

    /// The old agent still holds the task in br, so the new agent's claim would be refused as a
    /// conflict: the composition gives the claim back first, then the spawn claims it.
    func testHandoffReturnsTheOldClaimBeforeTheNewAgentClaims() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        let before = rig.runner.argv.count
        await rig.tick()
        let after = Array(rig.runner.argv.dropFirst(before))
        let reopen = after.firstIndex { $0.starts(with: ["br", "update", "fx-valid", "--status", "open"]) }
        let claim = after.firstIndex { $0.starts(with: ["br", "update", "fx-valid", "--claim"]) }
        XCTAssertNotNil(reopen, "\(after)")
        XCTAssertNotNil(claim, "\(after)")
        if let reopen, let claim { XCTAssertLessThan(reopen, claim) }
    }

    /// `SwarmService.handoffDecisions` is weak: a driver nothing else retains is gone the moment
    /// install returns, and every phone confirm/decline would answer "no hand-off".
    func testTheInstalledDriverOutlivesInstall() throws {
        let decisions = try XCTUnwrap(rig.swarm.handoffDecisions, "the driver is retained by the store's graph")
        XCTAssertTrue(decisions === rig.store.flightControlGraph?.driver)
        XCTAssertNotNil(rig.swarm.onTick)
    }
}
