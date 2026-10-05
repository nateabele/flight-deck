import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 step 3: no lease → L3-R's spill → waiting, with the reason recorded. A pinned block
/// never spills, and a spill is for one spawn — the stored block is never rewritten.
@MainActor
final class SwarmControllerWaitingTests: XCTestCase {
    private let spilled = SwarmFixtures.block("claude-subs", model: "opus", harness: "claude")

    func testAFullPoolSpillsThroughTheRouterForOneSpawn() async {
        let rig = SwarmRig()
        rig.leases("claude-subs", 1)
        rig.router.spills["tests"] = Assignment(block: spilled)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.block), [spilled])
        XCTAssertEqual(rig.router.spillCalls.map { $0.0 }, ["tests"])
        XCTAssertEqual(rig.router.spillCalls.map { $0.1 }, [["codex-subs"]])
        XCTAssertTrue(rig.backend.written.isEmpty, "a spill never rewrites the task's block")
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .spill && $0.detail.hasPrefix("codex-subs → claude-subs") })
    }

    func testAPinnedBlockNeverSpillsAndWaits() async {
        let rig = SwarmRig()
        rig.leases("claude-subs", 1)
        rig.router.spills["tests"] = Assignment(block: spilled)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block(pinned: true))]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertTrue(rig.launcher.created.isEmpty)
        XCTAssertTrue(rig.router.spillCalls.isEmpty)
        XCTAssertEqual(c.record.waiting, [WaitingTask(task: "fx-1", reason: "pinned to codex-subs, which has no account under its soft limit")])
    }

    func testNothingToSpillToWaits() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.waiting, [WaitingTask(task: "fx-1", reason: "codex-subs is full and nothing else fits")])
    }

    func testAnUnroutableSpillWaitsWithItsReasonAndNeverLeasesAnEmptyPool() async {
        let rig = SwarmRig()
        rig.leases("claude-subs", 1)
        rig.router.spills["tests"] = Assignment.unroutable(kind: "tests", reason: "x", at: SwarmFixtures.at)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertTrue(rig.launcher.created.isEmpty)
        XCTAssertEqual(rig.allocator.leaseCalls, ["codex-subs"], "only the block's own pool is asked; never pool \"\"")
        XCTAssertEqual(c.record.waiting, [WaitingTask(task: "fx-1", reason: "codex-subs is full and x")])
    }

    func testAnUnknownKindCannotSpill() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block(kind: "mystery"))]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.waiting, [WaitingTask(task: "fx-1", reason: "codex-subs is full and kind mystery is unknown")])
    }

    func testAPoolCapLimitsAgentsInThatPool() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 3)
        rig.backend.ready = ["fx-1", "fx-2", "fx-3"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3, poolCaps: ["codex-subs": 1]))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1"])
        XCTAssertEqual(c.record.waiting.map(\.task), ["fx-2", "fx-3"])
        XCTAssertEqual(rig.allocator.leaseCalls, ["codex-subs"], "a pool at its cap is not even asked for a lease")
    }

    func testTheSpillTargetsOwnCapIsRespected() async {
        let rig = SwarmRig()
        rig.leases("claude-subs", 2)
        rig.router.spills["tests"] = Assignment(block: spilled)
        rig.backend.ready = ["fx-1", "fx-2"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3, poolCaps: ["claude-subs": 1]))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.count, 1)
        XCTAssertEqual(c.record.waiting, [WaitingTask(task: "fx-2", reason: "codex-subs is full and claude-subs is full too")])
    }
}
