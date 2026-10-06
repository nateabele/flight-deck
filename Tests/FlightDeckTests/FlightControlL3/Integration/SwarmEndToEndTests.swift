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

    /// The unpinned case is the one that matters: a pinned block never spills anyway, so only
    /// an unpinned one proves a deleted pool is not quietly spilled around.
    func testDeletedPoolMakesAnUnpinnedTaskWaitInsteadOfSpilling() async throws {
        rig.feed(account: "Work", utilization: 0.10)
        rig.setBlockPool(task: "fx-valid", pool: "gone", pinned: false)
        try await rig.launch(cap: 1)
        await rig.tick()
        XCTAssertTrue(rig.spawns.isEmpty, "no spill: \(rig.spawns.map(\.block.pool))")
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

    /// Nothing can answer a hand-off confirmation yet: the phone shows no Confirm/Decline and
    /// the Mac has no action. A stored "Confirm hand-offs" must not park the agent on its
    /// over-hard account, burning it while it waits for an answer that never comes.
    func testAStoredConfirmFlagNeverParksAnAgent() async throws {
        rig.preferences.updateCapacity { $0.confirmHandoffs = true }
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        await rig.tick()
        let driver = try XCTUnwrap(rig.store.flightControlGraph?.driver)
        XCTAssertTrue(driver.pendingHandoffs.isEmpty, "nobody can answer, so nobody is asked")
        XCTAssertEqual(rig.spawns.count, 2)
        XCTAssertTrue(rig.isHandedOff(first.session))
    }

    // MARK: - Fix round 1

    /// The driver prunes every agent missing from what it is given. Called once per project,
    /// project A's pass wiped project B's pending confirmation (and a `.stopFailed`, or a
    /// decline), so B was re-asked forever and a phone "confirm" for it answered false.
    func testTwoProjectsKeepEachOthersHandoffState() async throws {
        // The driver's confirmation machinery, which production keeps off until a confirm
        // surface exists (see `testAStoredConfirmFlagNeverParksAnAgent`).
        rig.store.flightControlGraph?.confirmSurfaceExists = true
        rig.preferences.updateCapacity { $0.confirmHandoffs = true }
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        try await rig.launch(cap: 1, project: rig.secondProjectURL.path)
        await rig.tick()
        XCTAssertEqual(rig.spawns.count, 2)
        let a = try XCTUnwrap(rig.spawns.first?.session)
        let b = try XCTUnwrap(rig.spawns.dropFirst().first?.session)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(a); rig.markIdle(b)
        await rig.tick()
        await rig.tick()
        let driver = try XCTUnwrap(rig.store.flightControlGraph?.driver)
        XCTAssertEqual(driver.pendingHandoffs, [a.id, b.id], "each project's pending question survives the other's pass")
        XCTAssertTrue(rig.swarm.confirmHandoff(session: a.id))
        XCTAssertTrue(rig.swarm.confirmHandoff(session: b.id))
    }

    /// Between the old claim going back to open and the new agent's claim, br reads the task as
    /// open. The Observe watcher reporting that must not reset the old agent (which would leave
    /// the new one recorded with no task) or let the swarm claim the task for someone else.
    func testTaskInHandoffIsNotReclaimedWhenItReadsOpen() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        rig.brShows("fx-valid", status: "open", assignee: nil)
        rig.spawner.onSpawn = { [rig] in
            rig?.spawner.onSpawn = nil
            await rig?.watcherSeesNothingInProgress()
        }
        let before = rig.runner.argv.count
        await rig.tick()
        let claims = rig.runner.argv.dropFirst(before).filter { $0.starts(with: ["br", "update", "fx-valid", "--claim"]) }
        XCTAssertEqual(claims.count, 1, "only the hand-off's own claim: \(claims)")
        XCTAssertTrue(rig.isHandedOff(first.session))
        let successor = rig.swarm.record(forProject: rig.project)?.agents.first { $0.handedOffFrom == first.session.id }
        XCTAssertEqual(successor?.task, "fx-valid", "the new agent carries the task forward")
    }

    /// A hand-off spawn that fails after the old claim went back to open gives it back to the
    /// old agent, which is still running and still recorded as holding it.
    func testAFailedHandoffSpawnClaimsTheTaskBackForTheOldAgent() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        let oldName = try XCTUnwrap(first.session.agentName)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        rig.failNextCreate = true
        let before = rig.runner.argv.count
        await rig.tick()
        let after = Array(rig.runner.argv.dropFirst(before))
        let reopen = after.firstIndex { $0.starts(with: ["br", "update", "fx-valid", "--status", "open"]) }
        let claimBack = after.firstIndex { $0.starts(with: ["br", "update", "fx-valid", "--claim", "--actor", oldName]) }
        XCTAssertNotNil(reopen, "\(after)")
        XCTAssertNotNil(claimBack, "\(after)")
        if let reopen, let claimBack { XCTAssertLessThan(reopen, claimBack) }
        XCTAssertFalse(rig.isHandedOff(first.session))
    }

    // MARK: - Final review fix wave

    /// The hand-off spawn's own claim landed, then its first prompt never did. The new tab must
    /// not stay behind (each retry would leave one more agent nobody prompts), and the task must
    /// go back to the old agent: the never-prompted agent's claim is returned to open first,
    /// or claiming back for the old agent conflicts and the task stays with the orphan.
    func testAFailedHandoffDeliveryLeavesNoTabAndClaimsTheTaskBack() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        let oldName = try XCTUnwrap(first.session.agentName)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        rig.launcher.onCreate = { [rig] ref in
            rig?.launcher.deliverFailures[ref.id] = .composerTimeout
            rig?.launcher.onCreate = nil
        }
        let before = rig.runner.argv.count
        await rig.tick()
        let fresh = try XCTUnwrap(rig.spawns.dropFirst().first?.session)
        XCTAssertFalse(rig.store.sessionExists(fresh.id), "the never-prompted tab is closed")
        let after = Array(rig.runner.argv.dropFirst(before))
        let newClaim = after.firstIndex { $0.starts(with: ["br", "update", "fx-valid", "--claim", "--actor", fresh.agentName ?? "?"]) }
        let reopenAfterNewClaim = newClaim.flatMap { c in
            after.indices.first { $0 > c && after[$0].starts(with: ["br", "update", "fx-valid", "--status", "open"]) }
        }
        let claimBack = after.lastIndex { $0.starts(with: ["br", "update", "fx-valid", "--claim", "--actor", oldName]) }
        XCTAssertNotNil(newClaim, "\(after)")
        XCTAssertNotNil(reopenAfterNewClaim, "the orphan's claim goes back to open first: \(after)")
        XCTAssertNotNil(claimBack, "\(after)")
        if let reopenAfterNewClaim, let claimBack { XCTAssertLessThan(reopenAfterNewClaim, claimBack) }
        XCTAssertFalse(rig.isHandedOff(first.session))
        let old = rig.swarm.agentRecord(first.session.id)?.1
        XCTAssertEqual(old?.state, .working, "the old agent is still recorded as working it")
        XCTAssertEqual(old?.task, "fx-valid")
        XCTAssertNil(rig.swarm.agentRecord(fresh.id), "the swarm never recorded the failed agent")
    }

    /// The old agent's exit command could not be typed. The new agent already holds the task, so
    /// the swarm must own it: recorded (its lease released by the swarm like any agent's, and
    /// handed off again if its own account crosses). The old lease stays held while the old tab
    /// runs on that account, and is released once that tab is gone.
    func testAStopFailedHandoffRecordsTheNewAgentAndReleasesTheOldLeaseWhenItsTabCloses() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        let oldLease = try XCTUnwrap(first.lease)
        rig.feed(account: "Work", utilization: 0.97)
        rig.clearStatus(first.session)
        await rig.tick()
        let fresh = try XCTUnwrap(rig.spawns.dropFirst().first)
        let newLease = try XCTUnwrap(fresh.lease)
        XCTAssertEqual(rig.handoffLog.map(\.outcome), [.stopFailed])
        let recorded = rig.swarm.agentRecord(fresh.session.id)?.1
        XCTAssertEqual(recorded?.state, .working, "the swarm owns the new agent")
        XCTAssertEqual(recorded?.task, "fx-valid")
        XCTAssertEqual(rig.allocator.releases(of: newLease), 0, "the new agent's lease is held by its record")
        XCTAssertEqual(rig.allocator.releases(of: oldLease), 0, "the old tab still runs on that account")

        rig.store.closeSession(first.session.id)
        await rig.tick()
        XCTAssertEqual(rig.allocator.releases(of: oldLease), 1)
        await rig.tick()
        XCTAssertEqual(rig.allocator.releases(of: oldLease), 1, "released once")
    }

    /// The swarm refuses to record the new agent (here: it has no name). Nothing would ever
    /// release the lease it was spawned on, so the composition releases it, logs the hand-off
    /// as unrecorded and tells the user. (Deferred from Task 5: this path had no test.)
    func testARefusedRecordHandoffReleasesTheNewLeaseLogsAndNotifies() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        rig.nextAgentName = ""
        await rig.tick()
        let fresh = try XCTUnwrap(rig.spawns.dropFirst().first)
        let newLease = try XCTUnwrap(fresh.lease)
        XCTAssertNil(rig.swarm.agentRecord(fresh.session.id), "refused: a nameless agent cannot be recorded")
        XCTAssertEqual(rig.allocator.releases(of: newLease), 1)
        XCTAssertTrue(rig.handoffLog.contains { $0.outcome == .unrecorded && $0.newSession == fresh.session.id },
                      "\(rig.handoffLog.map(\.outcome))")
        XCTAssertTrue(rig.notifier.notes.contains { $0.title == "Hand-off not recorded" && $0.session == fresh.session.id },
                      "\(rig.notifier.notes.map(\.title))")
    }

    /// Turn Off (or Stop) lands after the pass took its snapshot but before the hand-off spawns.
    /// The swarm let its agents go; a new agent must not be started for it, nor the old one
    /// retired for a hand-off that no longer has a swarm to record it.
    func testAStoppedSwarmIsNotHandedOffMidPass() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        rig.clock.advance(SwarmService.tickInterval)
        rig.watch.fire()            // the pass is scheduled with the working agent in its snapshot
        rig.swarm.stop(project: rig.project)
        await rig.swarm.settle()
        XCTAssertEqual(rig.spawns.count, 1, "no new agent for a stopped swarm")
        XCTAssertFalse(rig.isHandedOff(first.session))
        XCTAssertFalse(rig.handoffLog.contains { $0.outcome == .handedOff || $0.outcome == .unrecorded },
                       "no hand-off ran: \(rig.handoffLog.map(\.outcome))")
    }

    /// Pause still hands off (see `testPausedSwarmStillHandsOff`); a drain lets running agents
    /// finish their work, so it hands off too.
    func testADrainingSwarmStillHandsOff() async throws {
        rig.feed(account: "Work", utilization: 0.30)
        rig.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.spawns.first)
        rig.swarm.drain(project: rig.project)
        rig.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        await rig.tick()
        XCTAssertEqual(rig.spawns.count, 2)
        XCTAssertTrue(rig.isHandedOff(first.session))
    }
}

