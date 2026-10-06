import XCTest
import IntakeKit
@testable import FlightDeck

/// Routes the spawn through the host's ordered event log, so one sequence shows the spawn
/// relative to every other side effect.
@MainActor
private final class OrderedSpawner: SwarmSpawner {
    let inner: FakeSwarmSpawner
    let host: FakeHandoffHost
    init(_ inner: FakeSwarmSpawner, _ host: FakeHandoffHost) { self.inner = inner; self.host = host }
    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError> {
        host.noteSpawn()
        return await inner.spawn(task: task, block: block, lease: lease, firstPrompt: firstPrompt)
    }
}

/// The driver is spec §5 steps 1–8 as a state machine. Every test scripts the four contract
/// fakes and the host, runs `evaluate` one tick at a time, and asserts the side effects — so the
/// order "spawn, then reassign, then release, then stop" and every refusal to act are pinned
/// without a terminal in sight.
@MainActor
final class HandoffDriverTests: XCTestCase {
    private var clock: UsageTestClock!
    private var planner: FakeHandoffPlanner!
    private var allocator: FakePoolAllocator!
    private var router: FakeRouter!
    private var spawner: FakeSwarmSpawner!
    private var host: FakeHandoffHost!
    private var settings = HandoffSettings(confirm: false, deadline: 600)

    private let oldID = UUID(), newID = UUID()
    private let project = URL(fileURLWithPath: "/p/proj")
    private lazy var block = ExecutionBlock(kind: "tests", harness: "claude", model: "opus", pool: "claude-default",
                                            source: AssignmentSource(by: .rule, reason: "r", at: Date(timeIntervalSince1970: 0)))
    private lazy var oldLease = AccountLease(pool: "claude-default", account: UsageRefs.work)
    private lazy var newLease = AccountLease(pool: "claude-default", account: UsageRefs.spare)
    private lazy var agent = SwarmAgentSnapshot(session: SessionRef(id: oldID, agentName: "BlueLake"), agentName: "BlueLake",
                                                block: block, lease: oldLease, task: TaskRef(id: "fd-3x9", project: project))
    private lazy var request = HandoffRequest(task: TaskRef(id: "fd-3x9", project: project), block: block, oldAgent: "BlueLake",
                                              oldSession: agent.session,
                                              transcript: TranscriptPointer(locator: .path("/t.jsonl"), format: "JSONL", howToRead: "Read the last 200 lines first."),
                                              reservedFiles: ["Sources/A.swift"], fromAccount: UsageRefs.work)

    override func setUp() {
        clock = UsageTestClock()
        planner = FakeHandoffPlanner(); allocator = FakePoolAllocator(); router = FakeRouter()
        spawner = FakeSwarmSpawner(); host = FakeHandoffHost()
        planner.requests[oldID] = request
        allocator.leases["claude-default"] = [newLease]
        spawner.results = [.success(SessionRef(id: newID, agentName: "GreenFox"))]
    }

    private func driver() -> HandoffDriver {
        let c = clock!
        return HandoffDriver(planner: planner, allocator: allocator, router: router,
                             spawner: OrderedSpawner(spawner, host), host: host,
                             settings: { [unowned self] in self.settings }, now: { c.now })
    }

    func testAnIdleAgentIsHandedOffAtOnceInSpecOrder() async {
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(spawner.calls.first?.lease, newLease)
        XCTAssertEqual(spawner.calls.first?.block, block)
        XCTAssertEqual(spawner.calls.first?.firstPrompt, HandoffPrompt.render(request))
        XCTAssertEqual(host.reassigned.map { $0.agent }, ["GreenFox"])
        XCTAssertEqual(host.released, ["BlueLake"])
        XCTAssertEqual(host.stopped, [oldID])
        XCTAssertEqual(host.marked.map { $0.new }, [newID])
        XCTAssertEqual(allocator.released, [oldLease], "the old lease goes back only after the new agent exists")
        XCTAssertEqual(host.log.map(\.outcome), [.handedOff])
        XCTAssertEqual(host.log.first?.fromAccount, "Work"); XCTAssertEqual(host.log.first?.toAccount, "Spare")
        XCTAssertEqual(d.phases[oldID], .done(SessionRef(id: newID, agentName: "GreenFox")))
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1, "a finished hand-off never runs twice")
    }

    /// Spec §5 order, as ONE sequence: nothing touches the old agent before the new one exists.
    func testTheSuccessfulHandoffRunsInExactlySpecOrder() async {
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertEqual(host.events, ["spawn", "reassign", "release", "stop", "mark", "record:handedOff"])
    }

    func testABusyAgentWaitsForItsTurnToEnd() async {
        host.activities[oldID] = .busy
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 0)
        clock.advance(60); host.activities[oldID] = .idle
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(host.interrupted, [])
    }

    func testTheDeadlineInterruptsABusyAgent() async {
        host.activities[oldID] = .busy
        let d = driver()
        await d.evaluate([agent])
        clock.advance(599); await d.evaluate([agent])
        XCTAssertEqual(host.interrupted, [])
        clock.advance(1); await d.evaluate([agent])
        XCTAssertEqual(host.interrupted, [oldID])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(host.log.map(\.outcome), [.interrupted, .handedOff])
    }

    func testARefusedInterruptIsNotLogged() async {
        host.activities[oldID] = .busy
        host.interruptSucceeds = false
        let d = driver()
        await d.evaluate([agent])
        clock.advance(600); await d.evaluate([agent])
        XCTAssertEqual(host.interrupted, [oldID], "the driver still tried")
        XCTAssertEqual(host.log.map(\.outcome), [.handedOff], "no .interrupted entry for an Escape that was never sent")
    }

    /// Review focus: Escape in a permission dialog is a denial, and a denial restarts a turn on
    /// the exhausted account. At the deadline the agent is handed off as it stands.
    func testDeadlineDuringAPermissionDialogHandsOffWithoutEscape() async {
        host.activities[oldID] = .waiting
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 0, "a dialog is not a turn boundary")
        clock.advance(600); await d.evaluate([agent])
        XCTAssertEqual(host.interrupted, [], "Escape in a dialog is a denial: it must never be sent")
        XCTAssertFalse(host.events.contains("interrupt"))
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(host.stopped, [oldID])
    }

    func testARateLimitRejectionIsABoundary() async {
        host.activities[oldID] = .busy; host.rateLimited = [oldID]
        await driver().evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(host.interrupted, [])
    }

    func testConfirmOnAsksOnceThenProceeds() async {
        settings.confirm = true
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertEqual(host.confirmations.count, 1)
        XCTAssertEqual(spawner.calls.count, 1)
    }

    func testDeclineLeavesTheAgentAndDoesNotAskAgainThisCrossing() async {
        settings.confirm = true; host.confirmAnswer = false
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent]); await d.evaluate([agent])
        XCTAssertEqual(host.confirmations.count, 1)
        XCTAssertEqual(spawner.calls.count, 0)
        XCTAssertEqual(host.stopped, [])
        XCTAssertEqual(d.phases[oldID], .declined)
        XCTAssertEqual(host.log.map(\.outcome), [.declined])
    }

    func testANewCrossingAsksAgain() async {
        settings.confirm = true; host.confirmAnswer = false
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        planner.requests[oldID] = nil
        await d.evaluate([agent])
        XCTAssertNil(d.phases[oldID], "below hard: the crossing is over")
        planner.requests[oldID] = request
        await d.evaluate([agent])
        XCTAssertEqual(host.confirmations.count, 2)
    }

    func testNoAccountFreeSpillsThroughTheRouter() async {
        allocator.leases["claude-default"] = []
        let spilled = ExecutionBlock(kind: "tests", harness: "codex", model: "gpt-6-sol", pool: "codex-default",
                                     source: AssignmentSource(by: .spill, reason: "claude-default exhausted", at: Date(timeIntervalSince1970: 0)))
        let kind = TaskKind(id: "tests", name: "Tests", description: "d", dimensions: ["test-authoring": 0.9], origin: .seed, createdAt: Date(timeIntervalSince1970: 0))
        host.kinds["tests"] = kind
        router.spills["tests"] = Assignment(block: spilled)
        let codexLease = AccountLease(pool: "codex-default", account: UsageRefs.codex)
        allocator.leases["codex-default"] = [codexLease]
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertEqual(router.spillCalls.map { $0.1 }, [["claude-default"]])
        XCTAssertEqual(spawner.calls.first?.block, spilled)
        XCTAssertEqual(spawner.calls.first?.lease, codexLease)
    }

    /// An unroutable spill is the router's "nothing fits", not a block: leasing from its empty
    /// pool or spawning on its empty harness would launch nothing and strand the task.
    func testAnUnroutableSpillWaitsAndNeverLeasesOrSpawns() async {
        allocator.leases["claude-default"] = []
        let kind = TaskKind(id: "tests", name: "Tests", description: "d", dimensions: [:], origin: .seed, createdAt: Date(timeIntervalSince1970: 0))
        host.kinds["tests"] = kind
        router.spills["tests"] = Assignment.unroutable(kind: "tests", reason: "no model scores above the floor", at: Date(timeIntervalSince1970: 0))
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 0)
        XCTAssertEqual(allocator.leaseCalls, ["claude-default"], "only the original pool is asked; the empty pool never is")
        XCTAssertEqual(host.stopped, [])
        guard case .waitingForCapacity(let reason)? = d.phases[oldID] else { return XCTFail("\(String(describing: d.phases[oldID]))") }
        XCTAssertTrue(reason.contains("no model scores above the floor"), reason)
    }

    func testAPinnedBlockWaitsAndTheAgentStays() async {
        var pinned = block; pinned.pinned = true
        var pinnedAgent = agent; pinnedAgent.block = pinned
        allocator.leases["claude-default"] = []
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([pinnedAgent]); await d.evaluate([pinnedAgent])
        XCTAssertEqual(spawner.calls.count, 0)
        XCTAssertEqual(host.stopped, [])
        XCTAssertEqual(router.spillCalls.count, 0, "a pinned block never spills")
        guard case .waitingForCapacity(let reason)? = d.phases[oldID] else { return XCTFail("\(String(describing: d.phases[oldID]))") }
        XCTAssertTrue(reason.contains("pinned"))
        XCTAssertEqual(host.log.map(\.outcome), [.waitingForCapacity], "logged once, not every tick")

        allocator.leases["claude-default"] = [newLease]
        await d.evaluate([pinnedAgent])
        XCTAssertEqual(spawner.calls.count, 1, "capacity came back: the next boundary hands off")
    }

    func testSpillFindingNothingWaits() async {
        allocator.leases["claude-default"] = []
        host.kinds["tests"] = TaskKind(id: "tests", name: "Tests", description: "d", dimensions: [:], origin: .seed, createdAt: Date(timeIntervalSince1970: 0))
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 0)
        guard case .waitingForCapacity? = d.phases[oldID] else { return XCTFail() }
    }

    func testASpawnFailureKeepsTheOldAgentAndRetriesAtTheNextBoundary() async {
        spawner.results = [.failure(.launchFailed("no composer")), .success(SessionRef(id: newID, agentName: "GreenFox"))]
        allocator.leases["claude-default"] = [newLease, AccountLease(pool: "claude-default", account: UsageRefs.spare)]
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(allocator.released, [newLease], "the lease taken for the failed spawn goes back")
        XCTAssertEqual(host.stopped, []); XCTAssertEqual(host.reassigned.count, 0)
        XCTAssertEqual(host.notices, ["Hand-off failed"])
        XCTAssertEqual(d.phases[oldID], .failed)

        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1, "still idle: not a new boundary")
        host.activities[oldID] = .busy; await d.evaluate([agent])
        host.activities[oldID] = .idle; await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 2)
        XCTAssertEqual(host.stopped, [oldID])
    }

    func testAMissingTranscriptStillHandsOff() async {
        var bare = request; bare.transcript = nil
        planner.requests[oldID] = bare
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertTrue(spawner.calls.first?.firstPrompt.contains("Its transcript is not available.") ?? false)
    }

    func testTheHostsReservationListWins() async {
        host.reserved = ["Sources/B.swift"]
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertTrue(spawner.calls.first?.firstPrompt.contains("Re-reserve these files before editing: Sources/B.swift.") ?? false)
    }

    func testAnUnnamedNewAgentSkipsReassignAndSaysWhy() async {
        spawner.results = [.success(SessionRef(id: newID, agentName: nil))]
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertEqual(host.reassigned.count, 0)
        XCTAssertTrue(host.log.first?.detail?.contains("assignee") ?? false)
    }

    /// An agent that leaves the snapshot and returns is on a new crossing: the old deadline must
    /// not interrupt it at once.
    func testAnOldWaitDoesNotSurviveTheAgentLeavingTheList() async {
        host.activities[oldID] = .busy
        let d = driver()
        await d.evaluate([agent])
        clock.advance(1000)
        await d.evaluate([])
        XCTAssertNil(d.phases[oldID])
        await d.evaluate([agent])
        XCTAssertEqual(host.interrupted, [], "the deadline restarts: the old `since` is gone")
        XCTAssertEqual(d.phases[oldID], .waitingForBoundary(since: clock.now))
    }

    func testAnOldDeclineAndConfirmationDoNotSurviveTheAgentLeavingTheList() async {
        settings.confirm = true; host.confirmAnswer = false
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(d.phases[oldID], .declined)
        await d.evaluate([])
        await d.evaluate([agent])
        XCTAssertEqual(host.confirmations.count, 2, "a new crossing asks again")
    }

    func testARateLimitedBusyAgentIsRetriedAfterAFailedSpawn() async {
        spawner.results = [.failure(.launchFailed("no composer")), .success(SessionRef(id: newID, agentName: "GreenFox"))]
        allocator.leases["claude-default"] = [newLease, newLease]
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(d.phases[oldID], .failed)
        host.activities[oldID] = .busy; host.rateLimited = [oldID]
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 2, "a refusal is a boundary even while the agent reads busy")
    }
}
