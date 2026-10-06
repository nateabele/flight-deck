import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 steps 1–7 on the spawn path: cap filling in scheduler order, claim after spawn,
/// the task prompt, and the Review Focus rule that a swarm claims only what its filter admits
/// and only what is ready.
@MainActor
final class SwarmControllerFillTests: XCTestCase {
    func testFillsUpToTheCapInSchedulerOrder() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 4)
        rig.backend.ready = ["fx-1", "fx-2", "fx-3", "fx-4"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1", "fx-2", "fx-3"])
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1", "fx-2", "fx-3"])
        XCTAssertEqual(rig.backend.claims.map(\.actor), ["Agent1", "Agent2", "Agent3"])
        XCTAssertEqual(c.record.agents.map(\.state), [.working, .working, .working])
        XCTAssertEqual(c.record.agents.map(\.task), ["fx-1", "fx-2", "fx-3"])
        XCTAssertEqual(c.freeSlots, 0)
    }

    func testSpawnThenClaimThenPrompt() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1)))
        XCTAssertEqual(rig.log.entries, ["create fx-1 Agent1", "claim fx-1 Agent1", "prompt Agent1"])
    }

    func testThePromptIsTheTaskPromptFromBrShow() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let detail = TaskDetail(id: "fx-1", title: "Add tests", description: "Cover it.", acceptance: "- green",
                                status: "in_progress", assignee: "Agent1")
        rig.backend.details["fx-1"] = detail
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1)))
        XCTAssertEqual(rig.launcher.delivered.map(\.prompt), [TaskPrompt.text(for: detail)])
    }

    func testTheSpawnCarriesTheBlockAndTheLease() async {
        let rig = SwarmRig()
        let lease = rig.leases("codex-subs", 1)[0]
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1)))
        XCTAssertEqual(rig.launcher.created.first?.block, SwarmFixtures.block())
        XCTAssertEqual(rig.launcher.created.first?.lease, lease)
    }

    func testSchedulerRankOutsideFilterIsNeverClaimed() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 2)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block()), SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 2, filter: .intake(id: UUID(), tasks: ["fx-2"])))
        await rig.run(c)
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-2"], "fx-1 is ranked first but not in this intake")
    }

    func testRankedButNotReadyTaskIsNeverClaimed() async throws {
        // The real join, through the real backend: br scheduler ranks fx-z first, but br ready
        // does not list it.
        let rig = SwarmRig()
        rig.leases("codex-subs", 2)
        let runner = MultiRunner()
        runner.responses["br ready --json"] = (#"[{"id":"fx-a","title":"A","priority":2}]"#, 0)
        runner.responses["br scheduler --format"] =
            (#"{"schema":"br.scheduler.v1","recommendations":[{"rank":1,"issue":{"id":"fx-z"}},{"rank":2,"issue":{"id":"fx-a"}}]}"#, 0)
        let ctx = try ExecutionBlockCodec.encode(SwarmFixtures.block(), into: nil)
        // The context as a JSON string literal, quotes included: encode a one-element array and
        // strip the brackets.
        let quoted = String(String(data: try JSONSerialization.data(withJSONObject: [ctx]), encoding: .utf8)!
            .dropFirst().dropLast())
        runner.responses["br list --status"] = (#"{"issues":[{"id":"fx-a","agent_context":"# + quoted + "}]}", 0)
        runner.responses["br update fx-a"] = ("{}", 0)
        var deps = rig.deps
        deps.backend = BrSwarmBackend(runner: runner)
        let c = SwarmController(record: rig.record(cap: 2), store: rig.store, deps: deps, now: { SwarmFixtures.at })
        await c.tick(); await c.settle()
        let claimed = runner.argv.filter { $0.count > 3 && $0[1] == "update" && $0[3] == "--claim" }.map { $0[2] }
        XCTAssertEqual(claimed, ["fx-a"])
    }

    func testAClaimConflictLeavesAnIdleAgentAndTheNextTaskIsTaken() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 2)
        rig.backend.claimResults["fx-1"] = .conflict
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block()), SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.agents.map(\.state), [.idle])
        XCTAssertTrue(rig.launcher.delivered.isEmpty, "a conflicted agent gets no prompt")
        rig.backend.ready.removeAll { $0.id == "fx-1" }   // br: someone else holds it now
        await rig.run(c)
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1", "fx-2"])
        XCTAssertEqual(c.record.agents.filter { $0.task == "fx-2" }.map(\.state), [.working])
    }

    func testNoLeaseLeavesTheTaskWaiting() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertTrue(rig.launcher.created.isEmpty)
        XCTAssertEqual(c.record.waiting.map(\.task), ["fx-1"])
        XCTAssertFalse(c.record.waiting[0].reason.isEmpty)
    }

    func testUnroutableTasksAreSkippedAndListed() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-none", nil),
                             ReadyTask(id: "fx-bad", title: "bad", priority: 2, rank: nil,
                                       agentContext: #"{"flight_deck":{"execution":{"v":1}}}"#),
                             SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1"])
        XCTAssertEqual(c.record.unroutable, [WaitingTask(task: "fx-none", reason: "no execution block"),
                                             WaitingTask(task: "fx-bad", reason: "missing kind")])
    }

    func testASpawnFailureReleasesTheLeaseAndClaimsNothing() async {
        let rig = SwarmRig()
        let lease = rig.leases("codex-subs", 1)[0]
        rig.launcher.createResults = [.failure(.launchFailed("Agent Mail boot failed"))]
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(rig.allocator.released, [lease])
        XCTAssertTrue(rig.backend.claims.isEmpty)
        XCTAssertEqual(c.record.spawnFailures[ConfigKey(SwarmFixtures.block()).rawValue], 1)
    }

    func testAPausedOrStoppedSwarmDoesNotReadTheReadyList() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(state: .paused)))
        await rig.run(rig.controller(rig.record(state: .stopped)))
        XCTAssertEqual(rig.backend.readyCalls, 0)
    }

    func testTasksPastTheCapAreStillClassified() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 3)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block()),
                             SwarmFixtures.task("fx-2", nil),
                             SwarmFixtures.task("fx-3", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1"])
        XCTAssertEqual(c.record.unroutable, [WaitingTask(task: "fx-2", reason: "no execution block")])
        XCTAssertEqual(rig.allocator.leaseCalls.count, 1, "no lease is taken for a task with no slot")
    }

    func testTheLogRecordsSpawnClaimPrompt() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(rig.store.log(swarm: c.record.id).map(\.kind), [.spawn, .claim, .prompt])
    }
}
