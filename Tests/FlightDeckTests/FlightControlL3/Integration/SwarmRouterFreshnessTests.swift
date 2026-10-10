import XCTest
import IntakeKit
@testable import FlightDeck

/// `RoutingService.makeRouter()` snapshots the global rules and default agents, so a router built
/// once at install would route every later launch and spill on the rules of install time: the
/// user edits a rule in Settings and the running swarm silently ignores it.
///
/// `RuleRouter` is a struct, so the brief's `!==` identity check between two `makeRouter()` calls
/// does not apply (value types have no identity); what matters is behavior, asserted below.
@MainActor
final class SwarmRouterFreshnessTests: XCTestCase {
    private var rig: L3IntegrationRig!

    override func setUp() async throws { rig = try L3IntegrationRig.standard() }
    override func tearDown() async throws {
        await rig?.swarm.settle()
        rig = nil
    }

    /// A rule that did not exist at install: tests go to Claude Haiku.
    private let lateRule = RoutingRule(
        id: "r-late", sentence: "Use Haiku for tests",
        compiled: CompiledRule(match: .any([.dimension("test-authoring", atLeast: 0.5)]),
                               assign: RuleAssign(agent: .claude, model: "haiku",
                                                  knobs: ["effort": "low"], pool: "claude-default")),
        state: .confirmed)

    func testSpillUsesRulesChangedAfterInstall() async throws {
        // Installed with r-tests (codex). Now the user replaces it.
        rig.preferences.globalRoutingRules = [lateRule]
        // Every codex account is over soft, and the block may spill.
        rig.setBlockPool(task: "fx-valid", pool: "codex-default", pinned: false)
        rig.feed(account: "Work", utilization: 0.85)
        rig.feed(account: "Personal", utilization: 0.85)
        try await rig.launch(cap: 1)
        await rig.tick()
        let spawn = try XCTUnwrap(rig.spawns.first, "the task spilled to another pool: \(String(describing: rig.waitingReason(task: "fx-valid")))")
        XCTAssertEqual(spawn.block.source.by, .spill)
        XCTAssertEqual(spawn.block.source.ruleId, "r-late", "the spill read the rule in force now, not at install")
        XCTAssertEqual(spawn.block.agent, .claude)
        XCTAssertEqual(spawn.block.model, "haiku")
    }

    func testEachLaunchAsksForAFreshRouter() throws {
        let makeRouter = try XCTUnwrap(rig.store.swarmDependencies?.makeRouter)
        let kinds = try rig.routing.kindStore.kinds(project: rig.projectURL)
        let tests = try XCTUnwrapRig(KindResolution.resolve("tests", in: kinds))
        func route() -> ExecutionBlock {
            makeRouter().assign(kind: tests, project: rig.projectURL, catalogs: RoutingTestData.catalogs, now: rig.clock.now).block
        }
        XCTAssertEqual(route().source.ruleId, "r-tests")
        rig.preferences.globalRoutingRules = [lateRule]
        XCTAssertEqual(route().source.ruleId, "r-late", "the same dependency closure, asked again, sees the edit")
    }

    // MARK: - Spill catalogs follow Settings

    /// A task released onto the claude pool, which is full: the confirmed rule says codex, so a
    /// spill lands there if codex is an enabled agent.
    private func spillFromAFullClaudePool() async throws {
        rig.setBlockPool(task: "fx-valid", pool: "claude-default", pinned: false)
        rig.feed(account: "Rig Claude", utilization: 0.85)
        try await rig.launch(cap: 1)
        await rig.tick()
    }

    func testSpillTargetsCodexWhileItIsEnabled() async throws {
        try await spillFromAFullClaudePool()
        let spawn = try XCTUnwrap(rig.spawns.first, "\(String(describing: rig.waitingReason(task: "fx-valid")))")
        XCTAssertEqual(spawn.block.agent, .codex, "control: with codex enabled the spill goes there")
    }

    /// Spill catalogs used to be `registry.catalogs(enabled: every harness)`, so an agent switched
    /// off in Settings still received spilled work.
    func testSpillNeverTargetsADisabledAgent() async throws {
        rig.preferences.preferences.agents.removeAll { $0.id == .codex }
        try await spillFromAFullClaudePool()
        XCTAssertTrue(rig.spawns.isEmpty, "nothing may start on a disabled agent: \(rig.spawns.map(\.block.agent))")
        XCTAssertNotNil(rig.waitingReason(task: "fx-valid"), "the task waits, with a reason")
    }
}
