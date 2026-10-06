import XCTest
import IntakeKit
@testable import FlightDeck

/// What the sheet shows before Launch (spec §3): every admitted ready task with its routing, the
/// router re-run for unpinned blocks, pinned ones untouched, unroutable ones greyed with a
/// reason, and an override that pins and writes the block back.
@MainActor
final class LaunchSheetModelTests: XCTestCase {
    private let project = "/tmp/launch-project"
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private let pools = FakePoolDirectory()
    private final class Counter { var n = 0 }
    private let routerCalls = Counter()

    private func rig() throws -> (SwarmRig, SwarmService, LaunchSheetModel, FakeRouter) {
        let rig = SwarmRig()
        rig.backend.ready = try L3Fixtures.brRows().map { row in
            ReadyTask(id: row["id"] as! String, title: row["title"] as! String, priority: 2, rank: nil,
                      agentContext: row["agent_context"] as? String)
        }
        rig.kinds.byProject[URL(fileURLWithPath: project, isDirectory: true)] = try L3Fixtures.kinds().kinds
        let routed = ExecutionBlock(kind: "snapshot-tests", harness: "codex", model: "gpt-6-terra", pool: "codex-subs",
                                    source: AssignmentSource(by: .index, reason: "index", at: at))
        rig.router.assignments["snapshot-tests"] = Assignment(block: routed)
        let codex = FakeRoutingCapabilities(); codex.harness = "codex"
        let claude = FakeRoutingCapabilities(); claude.harness = "claude"
        let registry = RoutingCapabilityRegistry([codex, claude])
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: registry, clock: nil, now: { [rig] in rig.now })
        service.dependencies = SwarmDependencies(makeRouter: { [router = rig.router, calls = routerCalls] in
            calls.n += 1; return router
        }, kinds: rig.kinds, allocator: rig.allocator, capacity: rig.capacity, pools: pools)
        let model = LaunchSheetModel(request: SwarmLaunchRequest(project: project, filter: .allReady, title: "p"),
                                     backend: rig.backend, service: service, registry: registry, now: { [rig] in rig.now })
        return (rig, service, model, rig.router)
    }

    func testUnpinnedBlocksAreReroutedAndPinnedOnesKept() async throws {
        let (_, _, model, router) = try rig()
        await model.load()
        let valid = try XCTUnwrap(model.rows.first { $0.id == "fx-valid" })
        XCTAssertEqual(valid.block?.model, "gpt-6-terra")
        XCTAssertEqual(valid.chip, .index)
        XCTAssertTrue(valid.changed)
        let pinned = try XCTUnwrap(model.rows.first { $0.id == "fx-pinned" })
        XCTAssertEqual(pinned.chip, .pinned)
        XCTAssertEqual(pinned.block?.model, "opus")
        XCTAssertFalse(pinned.changed)
        XCTAssertEqual(router.assignCalls, ["snapshot-tests"], "the router never sees a pinned block")
    }

    func testUnroutableRowsCarryTheirReason() async throws {
        let (_, _, model, _) = try rig()
        await model.load()
        func reason(_ id: String) -> String? { model.rows.first { $0.id == id }?.unroutable }
        XCTAssertEqual(reason("fx-invalid"), "missing model")
        XCTAssertEqual(reason("fx-none"), "no execution block")
        XCTAssertEqual(reason("fx-newer"), "written by a newer Flight Deck (v2)")
        XCTAssertNil(reason("fx-valid"))
    }

    func testTheIntakeFilterLimitsTheRows() async throws {
        let (rig, service, _, _) = try rig()
        let model = LaunchSheetModel(request: SwarmLaunchRequest(project: project, filter: .intake(id: UUID(), tasks: ["fx-pinned"]), title: "p"),
                                     backend: rig.backend, service: service, registry: service.registry, now: { rig.now })
        await model.load()
        XCTAssertEqual(model.rows.map(\.id), ["fx-pinned"])
    }

    func testOverridePinsAndWritesTheBlock() async throws {
        let (rig, _, model, _) = try rig()
        await model.load()
        let ok = await model.override("fx-valid", harness: "claude", model: "opus", knobs: ["effort": "high"], pool: "claude-subs")
        XCTAssertTrue(ok)
        let written = try XCTUnwrap(rig.backend.written.last)
        XCTAssertEqual(written.task, "fx-valid")
        XCTAssertTrue(written.block.pinned)
        XCTAssertEqual(written.block.source.by, .manual)
        XCTAssertEqual(written.block.kind, "snapshot-tests", "an override keeps the task's kind")
        XCTAssertEqual(model.rows.first { $0.id == "fx-valid" }?.chip, .pinned)
    }

    func testLaunchWritesBackReroutedBlocksThenStartsTheSwarm() async throws {
        let (rig, service, model, _) = try rig()
        await model.load()
        model.cap = 2
        let record = await model.launch()
        XCTAssertEqual(record?.cap, 2)
        XCTAssertEqual(rig.backend.written.map(\.task), ["fx-valid"], "only the re-routed block is written")
        XCTAssertNotNil(service.record(forProject: project))
    }

    func testALocalPoolDefaultsToItsOwnSlotCount() async throws {
        let (rig, _, model, _) = try rig()
        rig.capacity.byPool["codex-subs"] = [
            AccountHeadroom(account: AccountRef(harness: "codex", id: nil, label: "slot 1"), worstUtilization: nil, state: .underSoft, resetsAt: nil),
            AccountHeadroom(account: AccountRef(harness: "codex", id: nil, label: "slot 2"), worstUtilization: nil, state: .underSoft, resetsAt: nil),
        ]
        await model.load()
        XCTAssertEqual(model.poolCaps["codex-subs"], 2)
        XCTAssertNil(model.poolCaps["claude-subs"], "an account pool is bounded by the overall cap")
    }

    func testWithoutRoutingTheSheetSaysSoAndCannotLaunch() async throws {
        let (_, service, model, _) = try rig()
        service.dependencies = nil
        await model.load()
        XCTAssertEqual(model.error, "Flight Control routing is not connected yet.")
        XCTAssertFalse(model.canLaunch)
    }

    func testAnUnroutableAssignmentIsShownWithItsReasonAndNeverLaunched() async throws {
        let (rig, _, model, _) = try rig()
        rig.router.assignments["snapshot-tests"] = Assignment.unroutable(kind: "snapshot-tests", reason: "no account under its limit", at: at)
        await model.load()
        let row = try XCTUnwrap(model.rows.first { $0.id == "fx-valid" })
        XCTAssertEqual(row.unroutable, "no account under its limit")
        XCTAssertNil(row.block)
        XCTAssertNil(row.chip)
        XCTAssertFalse(row.changed)
        _ = await model.launch()
        XCTAssertTrue(rig.backend.written.isEmpty, "an unroutable row is never written")
    }

    func testReroutingToTheSameBlockWithADifferentTimestampIsNotAChange() async throws {
        let (rig, _, model, _) = try rig()
        await model.load()
        _ = await model.launch()
        XCTAssertEqual(rig.backend.written.map(\.task), ["fx-valid"])
        // The router now answers with the block the sheet already wrote, stamped a minute later.
        let written = try XCTUnwrap(rig.backend.written.last).block
        var later = written
        later.source = AssignmentSource(by: written.source.by, ruleId: written.source.ruleId,
                                        reason: "a different reason", at: at.addingTimeInterval(60))
        rig.router.assignments["snapshot-tests"] = Assignment(block: later)
        rig.backend.ready = rig.backend.ready.map { task in
            guard task.id == "fx-valid" else { return task }
            return ReadyTask(id: task.id, title: task.title, priority: 2, rank: nil,
                             agentContext: try? ExecutionBlockCodec.encode(written, into: nil))
        }
        await model.load()
        XCTAssertFalse(try XCTUnwrap(model.rows.first { $0.id == "fx-valid" }).changed)
        let before = rig.backend.written.count
        _ = await model.launch()
        XCTAssertEqual(rig.backend.written.count, before, "an unchanged row is not rewritten")
    }

    func testOverridePickerOffersTheDirectorysPoolsForTheHarness() async throws {
        let (_, _, model, _) = try rig()
        pools.summaries = [PoolSummary(id: "claude-subs", harness: "claude", label: "Claude subs"),
                           PoolSummary(id: "codex-subs", harness: "codex", label: "Codex subs"),
                           PoolSummary(id: "claude-team", harness: "claude", label: "Claude team")]
        pools.defaults = ["claude": "claude-team"]
        await model.load()
        XCTAssertEqual(model.poolOptions(for: "claude").map(\.id), ["claude-subs", "claude-team"])
        XCTAssertEqual(model.defaultPool(for: "claude"), "claude-team")
        XCTAssertTrue(model.poolOptions(for: "opencode").isEmpty, "no listed pool means the sheet falls back to free text")
        XCTAssertNil(model.defaultPool(for: "opencode"))
    }

    func testOverrideIsDisabledOnABlockFromANewerFlightDeck() async throws {
        let (rig, _, model, _) = try rig()
        await model.load()
        let newer = try XCTUnwrap(model.rows.first { $0.id == "fx-newer" })
        XCTAssertFalse(newer.canOverride)
        XCTAssertTrue(try XCTUnwrap(model.rows.first { $0.id == "fx-invalid" }).canOverride, "a merely invalid block can be repaired")
        let ok = await model.override("fx-newer", harness: "claude", model: "opus", knobs: [:], pool: "claude-subs")
        XCTAssertFalse(ok)
        XCTAssertTrue(rig.backend.written.isEmpty, "a newer Flight Deck's block is never overwritten")
    }

    func testEachLoadAsksForAFreshRouter() async throws {
        let (_, _, model, _) = try rig()
        await model.load()
        await model.load()
        XCTAssertEqual(routerCalls.n, 2)
    }

    func testAFailedWriteBackAbortsTheLaunch() async throws {
        let (rig, service, model, _) = try rig()
        await model.load()
        rig.backend.writeFails = ["fx-valid"]
        let record = await model.launch()
        XCTAssertNil(record)
        XCTAssertEqual(model.error, "Could not save the routing for fx-valid")
        XCTAssertNil(service.record(forProject: project), "the swarm never runs a block the sheet did not save")
    }

    func testASecondLaunchWhileOneIsRunningDoesNothing() async throws {
        let (rig, _, model, _) = try rig()
        await model.load()
        async let first = model.launch()
        async let second = model.launch()
        let results = await [first, second]
        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        XCTAssertEqual(rig.backend.written.map(\.task), ["fx-valid"])
    }

    func testASuccessfulLoadClearsAStaleError() async throws {
        let (rig, _, model, _) = try rig()
        rig.backend.readyFails = true
        await model.load()
        XCTAssertNotNil(model.error)
        rig.backend.readyFails = false
        await model.load()
        XCTAssertNil(model.error)
    }

    func testChangingTheHarnessResetsThePoolToItsDefaultThenFirstOptionThenEmpty() async throws {
        let (_, _, model, _) = try rig()
        pools.summaries = [PoolSummary(id: "claude-subs", harness: "claude", label: "C"),
                           PoolSummary(id: "claude-team", harness: "claude", label: "C2"),
                           PoolSummary(id: "codex-subs", harness: "codex", label: "X")]
        pools.defaults = ["claude": "claude-team"]
        await model.load()
        XCTAssertEqual(model.pool(afterChangingTo: "claude"), "claude-team")
        XCTAssertEqual(model.pool(afterChangingTo: "codex"), "codex-subs", "no default: the first option")
        XCTAssertEqual(model.pool(afterChangingTo: "opencode"), "", "nothing listed: free text, cleared")
    }

    func testSaveNeedsAPoolFromTheListWhenTheDirectoryHasOne() async throws {
        let (_, _, model, _) = try rig()
        pools.summaries = [PoolSummary(id: "claude-subs", harness: "claude", label: "C")]
        await model.load()
        XCTAssertTrue(model.isValidPool("claude-subs", for: "claude"))
        XCTAssertFalse(model.isValidPool("codex-subs", for: "claude"), "another harness's pool cannot be pinned")
        XCTAssertFalse(model.isValidPool("", for: "claude"))
        XCTAssertTrue(model.isValidPool("anything", for: "opencode"), "free text when the directory lists none")
        XCTAssertFalse(model.isValidPool("", for: "opencode"))
    }

    func testParseKnobs() {
        XCTAssertEqual(LaunchSheetModel.parseKnobs("effort=high, agent=build"), ["effort": "high", "agent": "build"])
        XCTAssertEqual(LaunchSheetModel.parseKnobs(""), [:])
        XCTAssertNil(LaunchSheetModel.parseKnobs("effort"))
    }

    /// The Override picker offers the agents Settings has enabled — the catalogs routing uses —
    /// not every registered harness: an override to a disabled agent would launch something
    /// the user turned off.
    func testTheOverridePickerOffersOnlyEnabledAgents() async throws {
        let (_, service, model, _) = try rig()
        let deps = try XCTUnwrap(service.dependencies)
        service.dependencies = SwarmDependencies(
            makeRouter: deps.makeRouter, kinds: deps.kinds, allocator: deps.allocator, capacity: deps.capacity, pools: deps.pools,
            catalogs: {
                AdapterCatalogs([AdapterCatalog(harness: "codex", models: [], knobSchema: [:], defaultModel: nil, enabled: false),
                                 AdapterCatalog(harness: "claude", models: [], knobSchema: [:], defaultModel: nil, enabled: true)])
            })
        await model.load()
        XCTAssertEqual(model.harnesses, ["claude"])
    }
}

