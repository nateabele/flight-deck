import XCTest
import IntakeKit
@testable import FlightDeck

/// The validator and the router can only be as right as the catalogs they check against. Claude's
/// comes from the flag catalog Settings already uses; codex's from its own app-server. Nothing
/// here spawns codex: the fetch is injected.
@MainActor
final class RoutingCatalogsTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: RoutingFixtures.data("codex-model-list.json")) as? [String: Any])
    }

    func testClaudeOffersItsAliasesWithOpusFirstAndAnEffortKnob() async throws {
        let caps = try XCTUnwrap(RoutingCapabilityRegistry.standard().capabilities(for: .claude))
        let catalog = await caps.modelCatalog()
        let models = try XCTUnwrap(catalog.value)
        XCTAssertEqual(models.first?.id, "opus", "opus is Flight Deck's default claude model everywhere else")
        XCTAssertEqual(Set(models.map(\.id)), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertTrue(models.allSatisfy { $0.knobs == ["effort"] })
        XCTAssertEqual(caps.knobSchema, ["effort": ["low", "medium", "high", "xhigh", "max"]])
    }

    func testCodexParsesTheLiveModelListWithTheDefaultFirst() throws {
        let (models, schema) = CodexRoutingCatalog.parse(try fixture())
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
                                          "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
        XCTAssertEqual(models.first?.displayName, "GPT-6.1-Sol")
        XCTAssertEqual(schema, ["effort": ["low", "medium", "high", "xhigh", "max", "ultra"]])
    }

    func testHiddenModelsAreLeftOutAndTheDefaultMovesFirst() {
        let result: [String: Any] = ["data": [
            ["id": "a", "displayName": "A", "hidden": false, "isDefault": false,
             "supportedReasoningEfforts": [["reasoningEffort": "low", "description": ""]]],
            ["id": "secret", "displayName": "S", "hidden": true, "isDefault": false, "supportedReasoningEfforts": []],
            ["id": "b", "displayName": "B", "hidden": false, "isDefault": true, "supportedReasoningEfforts": []],
        ]]
        let (models, schema) = CodexRoutingCatalog.parse(result)
        XCTAssertEqual(models.map(\.id), ["b", "a"])
        XCTAssertEqual(models.first?.knobs, [], "a model that lists no efforts accepts no effort knob")
        XCTAssertEqual(schema, ["effort": ["low"]])
    }

    func testCodexFetchesOnceAndCaches() async throws {
        let data = try fixture()
        var fetches = 0
        let catalog = CodexRoutingCatalog(fetch: { fetches += 1; return data })
        let first = await catalog.models()
        let second = await catalog.models()
        XCTAssertEqual(first.value?.count, 8)
        XCTAssertEqual(second.value?.count, 8)
        XCTAssertEqual(fetches, 1, "one app-server spawn per launch, not per compile")
        XCTAssertEqual(catalog.knobSchema["effort"]?.last, "ultra")
    }

    func testAFailedFetchIsUnsupportedAndRetriedNextTime() async throws {
        struct Down: Error {}
        let data = try fixture()
        var fail = true
        let catalog = CodexRoutingCatalog(fetch: { if fail { throw Down() }; return data })
        let first = await catalog.models()
        guard case .unsupported(let why) = first else { return XCTFail("a failed fetch must not look like an empty catalog") }
        XCTAssertTrue(why.hasPrefix("codex model list unavailable"), why)
        XCTAssertEqual(catalog.knobSchema, [:])
        fail = false
        let second = await catalog.models()
        XCTAssertEqual(second.value?.first?.id, "gpt-6.1-sol")
    }

    func testAnEmptyListIsUnsupportedNotAnEmptyCatalog() async {
        let catalog = CodexRoutingCatalog(fetch: { ["data": [[String: Any]]()] })
        let result = await catalog.models()
        guard case .unsupported = result else { return XCTFail("an empty list must not route as 'codex has no models'") }
    }

    func testTheRegistryCombinesRealClaudeWithAnyOtherAgent() async {
        let codex = FakeRoutingCapabilities()
        codex.agent = .codex
        codex.catalog = .supported([ModelEntry(id: "gpt-6-sol", displayName: "GPT-6-Sol", knobs: ["effort"])])
        codex.knobSchema = ["effort": ["low", "high"]]
        let cats = await RoutingCapabilityRegistry([ClaudeRoutingCapabilities(), codex]).catalogs(enabled: [.claude, .codex])
        XCTAssertEqual(cats.byAgent[.claude]?.defaultModel, "opus")
        XCTAssertTrue(cats.knobsValid(ModelRef(agent: .claude, model: "haiku", knobs: ["effort": "xhigh"])))
        XCTAssertTrue(cats.contains(ModelRef(agent: .codex, model: "gpt-6-sol")))
    }
}
