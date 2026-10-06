import XCTest
import IntakeKit
@testable import FlightDeck

/// "Harness is any registered adapter" is only true if nothing between a block and a spawn
/// knows the adapter list. These tests register a third, fake harness and route it end to end
/// through the registry — the same path claude and codex take.
@MainActor
final class RoutingCapabilityRegistryTests: XCTestCase {
    func testStandardRegistryHasEveryAgentID() {
        let reg = RoutingCapabilityRegistry.standard()
        XCTAssertEqual(Set(reg.harnesses), Set(AgentID.allCases.map(\.harnessID)))
        XCTAssertEqual(reg.capabilities(for: "claude")?.accountModel, .login)
        XCTAssertNil(reg.capabilities(for: "nope"))
    }

    func testAFakeHarnessIsRoutableThroughTheRegistry() async {
        let fake = FakeRoutingCapabilities()
        fake.catalog = .supported([ModelEntry(id: "fake-1", displayName: "Fake One", knobs: ["mode"])])
        fake.knobSchema = ["mode": ["fast", "slow"]]
        let reg = RoutingCapabilityRegistry([fake])
        let cats = await reg.catalogs(enabled: ["fake"])
        XCTAssertTrue(cats.contains(ModelRef(harness: "fake", model: "fake-1")))
        XCTAssertTrue(cats.knobsValid(ModelRef(harness: "fake", model: "fake-1", knobs: ["mode": "fast"])))
        XCTAssertEqual(cats.enabledModels, [ModelRef(harness: "fake", model: "fake-1")])
    }

    /// Rewritten by L3-R: claude's and codex's catalogs are real now, and asking the standard
    /// registry for codex's spawns `codex app-server` — never from a unit test. The behavior
    /// pinned is unchanged: an unsupported catalog is an empty, disabled one.
    func testUnsupportedCatalogYieldsAnEmptyDisabledCatalog() async {
        let stub = FakeRoutingCapabilities()
        stub.catalog = .unsupported(reason: "not yet")
        let cats = await RoutingCapabilityRegistry([stub]).catalogs(enabled: ["fake"])
        XCTAssertEqual(cats.byHarness["fake"]?.models, [])
        XCTAssertEqual(cats.enabledModels, [], "an unsupported catalog must never pretend to have models")
    }

    func testStubsSayUnsupportedRatherThanFake() {
        for h in AgentID.allCases.map(\.harnessID) {
            let caps = RoutingCapabilityRegistry.standard().capabilities(for: h)!
            if case .supported = caps.applying(LaunchOverrides(model: "x", knobs: [:]), to: .codex(.init())) {
                XCTFail("\(h) stub claimed launch overrides")
            }
        }
    }

    func testFakeSpawnerRecordsAndReturnsScript() async {
        let spawner = FakeSwarmSpawner()
        let ref = SessionRef(id: UUID(), agentName: "BlueLake")
        spawner.results = [.success(ref)]
        let block = ExecutionBlock(kind: "tests", harness: "fake", model: "fake-1", pool: "p",
                                   source: AssignmentSource(by: .rule, reason: "r", at: Date()))
        let r = await spawner.spawn(task: TaskRef(id: "t1", project: URL(fileURLWithPath: "/p")), block: block,
                                    lease: nil, firstPrompt: "Your task is t1")
        XCTAssertEqual(r, .success(ref))
        XCTAssertEqual(spawner.calls.map(\.firstPrompt), ["Your task is t1"])
    }
}
