import XCTest
import IntakeKit
@testable import FlightDeck

/// "An agent is routable once its adapter registers" is only true if nothing between a block
/// and a spawn knows the adapter list. These tests register a fake conformer for an agent the
/// standard registry need not carry (grok here, registered by hand) and route it end to end through the
/// registry — the same path claude and codex take.
@MainActor
final class RoutingCapabilityRegistryTests: XCTestCase {
    /// Every TAB-READY agent (unify brief R4): routing opens a tab on its target, so a stub
    /// agent is not one.
    func testStandardRegistryHasEveryTabReadyAgent() {
        let reg = RoutingCapabilityRegistry.standard()
        XCTAssertEqual(Set(reg.agents), Set(AgentID.tabReadyCases))
        XCTAssertEqual(reg.capabilities(for: .claude)?.accountModel, .login)
        XCTAssertNotNil(reg.capabilities(for: .grok), "Track G made grok tab-ready")
        XCTAssertNil(reg.capabilities(for: .gemini))
    }

    func testAFakeHarnessIsRoutableThroughTheRegistry() async {
        let fake = FakeRoutingCapabilities()
        fake.catalog = .supported([ModelEntry(id: "fake-1", displayName: "Fake One", knobs: ["mode"])])
        fake.knobSchema = ["mode": ["fast", "slow"]]
        let reg = RoutingCapabilityRegistry([fake])
        let cats = await reg.catalogs(enabled: [.grok])
        XCTAssertTrue(cats.contains(ModelRef(agent: .grok, model: "fake-1")))
        XCTAssertTrue(cats.knobsValid(ModelRef(agent: .grok, model: "fake-1", knobs: ["mode": "fast"])))
        XCTAssertEqual(cats.enabledModels, [ModelRef(agent: .grok, model: "fake-1")])
    }

    /// Rewritten by L3-R: claude's and codex's catalogs are real now, and asking the standard
    /// registry for codex's spawns `codex app-server` — never from a unit test. The behavior
    /// pinned is unchanged: an unsupported catalog is an empty, disabled one.
    func testUnsupportedCatalogYieldsAnEmptyDisabledCatalog() async {
        let stub = FakeRoutingCapabilities()
        stub.catalog = .unsupported(reason: "not yet")
        let cats = await RoutingCapabilityRegistry([stub]).catalogs(enabled: [.grok])
        XCTAssertEqual(cats.byAgent[.grok]?.models, [])
        XCTAssertEqual(cats.enabledModels, [], "an unsupported catalog must never pretend to have models")
    }

    func testFakeSpawnerRecordsAndReturnsScript() async {
        let spawner = FakeSwarmSpawner()
        let ref = SessionRef(id: UUID(), agentName: "BlueLake")
        spawner.results = [.success(ref)]
        let block = ExecutionBlock(kind: "tests", agent: .grok, model: "fake-1", pool: "p",
                                   source: AssignmentSource(by: .rule, reason: "r", at: Date()))
        let r = await spawner.spawn(task: TaskRef(id: "t1", project: URL(fileURLWithPath: "/p")), block: block,
                                    lease: nil, firstPrompt: "Your task is t1")
        XCTAssertEqual(r, .success(ref))
        XCTAssertEqual(spawner.calls.map(\.firstPrompt), ["Your task is t1"])
    }
}
