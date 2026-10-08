import XCTest
import IntakeKit
@testable import FlightDeck

/// The real `SwarmSpawner`. Its contract is narrow and each clause has bitten a creation path
/// before: the harness must name a real agent, a "successful" creation must have actually filed
/// a tab (claude's `newSession` returns an unfiled draft on refusal), the tab must have booted
/// an Agent Mail identity (the claim needs its name), and the claim sits between creation and
/// the prompt.
@MainActor
final class StoreSwarmSpawnerTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private let task = TaskRef(id: "fx-a", project: URL(fileURLWithPath: "/p", isDirectory: true))

    private func block(_ agent: AgentID = .claude) -> ExecutionBlock {
        ExecutionBlock(kind: "tests", agent: agent, model: "opus", knobs: ["effort": "high"], pool: "claude-subs",
                       source: AssignmentSource(by: .rule, reason: "r", at: at))
    }

    private struct Call: Equatable { let agent: AgentID; let dir: String; let account: UUID?; let overrides: LaunchOverrides }

    private func spawner(created: Result<UUID, AgentLaunchError>, exists: Bool = true, name: String? = "BlueLake",
                         calls: @escaping (Call) -> Void = { _ in },
                         deliverSucceeds: Bool = true,
                         discarded: @escaping (UUID) -> Void = { _ in }) -> StoreSwarmSpawner {
        StoreSwarmSpawner(
            create: { agent, dir, account, overrides in calls(Call(agent: agent, dir: dir, account: account, overrides: overrides)); return created },
            exists: { _ in exists }, discard: discarded,
            identity: { id in name.map { FlywheelIdentity(agentName: $0, project: "/p") } },
            session: { id in Session(id: id, title: "t", workingDirectory: "/p") },
            registry: RoutingCapabilityRegistry([FakeRoutingCapabilities()]),
            delivery: PromptDelivery(submit: { _, _, _ in deliverSucceeds ? .sent : .notRunning },
                                     pending: { _, _ in false }, withdraw: { _, _ in },
                                     sleep: { _ in }, now: { Date.distantFuture }, timeout: 0))
    }

    func testCreateAgentPassesBlockAndLeaseThrough() async throws {
        let id = UUID(); var seen: [Call] = []
        let account = UUID()
        let lease = AccountLease(pool: "claude-subs", account: AccountRef(agent: .claude, id: account, label: "Work"))
        let ref = try await spawner(created: .success(id), calls: { seen.append($0) })
            .createAgent(task: task, block: block(), lease: lease).get()
        XCTAssertEqual(ref, SessionRef(id: id, agentName: "BlueLake"))
        XCTAssertEqual(seen, [Call(agent: .claude, dir: "/p", account: account,
                                   overrides: LaunchOverrides(model: "opus", knobs: ["effort": "high"]))])
    }

    func testUnknownHarnessIsUnsupported() async {
        let r = await spawner(created: .success(UUID())).createAgent(task: task, block: block(.grok), lease: nil)
        XCTAssertEqual(r, .failure(.unsupportedAgent(.grok)))
    }

    func testAnUnfiledTabIsALaunchFailure() async {
        let r = await spawner(created: .success(UUID()), exists: false).createAgent(task: task, block: block(), lease: nil)
        XCTAssertEqual(r, .failure(.launchFailed("the tab was refused")))
    }

    func testATabWithNoAgentMailIdentityIsALaunchFailure() async {
        let r = await spawner(created: .success(UUID()), name: nil).createAgent(task: task, block: block(), lease: nil)
        XCTAssertEqual(r, .failure(.launchFailed("no Agent Mail identity — is Flight Control on for this project?")))
    }

    func testCreateFailureCarriesTheLaunchError() async {
        let r = await spawner(created: .failure(.prepareFailed("boom"))).createAgent(task: task, block: block(), lease: nil)
        XCTAssertEqual(r, .failure(.launchFailed("Could not start a Codex session: boom")))
    }

    func testContractSpawnClaimsBetweenCreateAndPrompt() async {
        var discarded: [UUID] = []
        let s = spawner(created: .success(UUID()), discarded: { discarded.append($0) })
        var order: [String] = []
        s.claim = { t, name in order.append("claim \(t.id) \(name)"); return .claimed }
        let r = await s.spawn(task: task, block: block(), lease: nil, firstPrompt: "go")
        XCTAssertEqual(r.map(\.agentName), .success("BlueLake"))
        XCTAssertEqual(order, ["claim fx-a BlueLake"])
        XCTAssertEqual(discarded, [], "a spawn that worked keeps its tab")
    }

    /// A failed hand-off spawn is retried at the next boundary; a tab left behind by each try
    /// is an orphan agent nobody prompts, one more per retry. So a spawn that fails after its
    /// tab exists closes that tab.
    func testContractSpawnReportsAClaimConflictAndClosesTheTab() async {
        let id = UUID(); var discarded: [UUID] = []
        let s = spawner(created: .success(id), discarded: { discarded.append($0) })
        s.claim = { _, _ in .conflict }
        let r = await s.spawn(task: task, block: block(), lease: nil, firstPrompt: "go")
        XCTAssertEqual(r, .failure(.claimConflict("fx-a")))
        XCTAssertEqual(discarded, [id])
    }

    func testContractSpawnReportsAComposerTimeoutAndClosesTheTab() async {
        let id = UUID(); var discarded: [UUID] = []
        let s = spawner(created: .success(id), deliverSucceeds: false, discarded: { discarded.append($0) })
        s.claim = { _, _ in .claimed }
        let r = await s.spawn(task: task, block: block(), lease: nil, firstPrompt: "go")
        XCTAssertEqual(r, .failure(.composerTimeout))
        XCTAssertEqual(discarded, [id])
    }

    /// The tab opened but booted no Agent Mail identity: still a tab the spawn opened and will
    /// never prompt.
    func testATabWithNoIdentityIsClosedBySpawn() async {
        let id = UUID(); var discarded: [UUID] = []
        let s = spawner(created: .success(id), name: nil, discarded: { discarded.append($0) })
        s.claim = { _, _ in .claimed }
        _ = await s.spawn(task: task, block: block(), lease: nil, firstPrompt: "go")
        XCTAssertEqual(discarded, [id])
    }

    /// No tab was opened, so there is nothing to close (and closing an unknown id is not this
    /// spawner's to guess at).
    func testAFailedCreateClosesNothing() async {
        var discarded: [UUID] = []
        let s = spawner(created: .failure(.prepareFailed("boom")), discarded: { discarded.append($0) })
        s.claim = { _, _ in .claimed }
        _ = await s.spawn(task: task, block: block(), lease: nil, firstPrompt: "go")
        XCTAssertEqual(discarded, [])
    }

    /// A hand-off spawn that never claims leaves the task open, and the swarm then claims it for
    /// a second agent. With no claim wired, the spawn refuses before it opens a tab.
    func testContractSpawnWithNoClaimConfiguredOpensNoTab() async {
        var seen: [Call] = []
        let s = spawner(created: .success(UUID()), calls: { seen.append($0) })
        let r = await s.spawn(task: task, block: block(), lease: nil, firstPrompt: "go")
        XCTAssertEqual(r, .failure(.launchFailed("no claim configured")))
        XCTAssertTrue(seen.isEmpty)
    }

    func testResetGoesThroughTheRegistry() async {
        let fake = FakeRoutingCapabilities(); fake.agent = .claude
        let id = UUID()
        let s = StoreSwarmSpawner(create: { _, _, _, _ in .success(id) }, exists: { _ in true }, discard: { _ in },
                                  identity: { _ in nil }, session: { Session(id: $0, title: "t", workingDirectory: "/p") },
                                  registry: RoutingCapabilityRegistry([fake]),
                                  delivery: PromptDelivery(submit: { _, _, _ in .sent }, pending: { _, _ in false },
                                                           withdraw: { _, _ in }, sleep: { _ in }, now: Date.init, timeout: 1))
        let ok = await s.resetContext(id)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.resetCalls, [id])
        fake.resetResult = .success(.unsupported(reason: "no"))
        let unsupported = await s.resetContext(id)
        XCTAssertFalse(unsupported)
    }
}
