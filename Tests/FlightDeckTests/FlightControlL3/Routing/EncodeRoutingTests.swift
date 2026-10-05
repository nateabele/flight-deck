import XCTest
import IntakeKit

extension RoutingFixtures {
    /// The fixture encode output, validated and planned exactly as release does.
    static func encodeSteps() throws -> [ApplyStep] {
        let out = try RoundPrompts.decode(ChangeSetOutput.self, data("encode-with-kinds.json"))
        let validated = try ChangeSetValidator.validate(out.changeSet, against: GraphSnapshot()).get()
        return ApplyPlanner.plan(validated, skipping: [])
    }
}

/// Spec L3-R §9 "Encode": a recorded-shape encode output with a kind and a kind proposal; assert
/// the registry write and the block each create will carry (the argv half is in
/// `BeadWriterBlockTests.testTheEncodeOutputLandsAsAgentContextArgv`).
final class EncodeRoutingTests: XCTestCase {
    private typealias D = RoutingTestData
    private var project: URL!

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("EncodeRoutingTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private var registry: KindRegistryStore { KindRegistryStore(now: { RoutingTestData.at }) }

    private func router(_ global: [RoutingRule] = [RoutingTestData.r3(pool: "codex-default")]) -> RuleRouter {
        RuleRouter(rules: StaticRuleSource(global: global), kinds: registry, index: NullCapabilityIndex(),
                   pools: DefaultPoolDirectory(harnesses: ["codex", "claude"]), defaultHarness: { _ in "claude" })
    }

    private func route(_ steps: [ApplyStep], catalogs: AdapterCatalogs = RoutingTestData.catalogs) -> EncodeRouting.Outcome {
        EncodeRouting.route(steps, project: project, registry: registry, router: router(), catalogs: catalogs, now: D.at)
    }

    private func create(_ bead: NewBead) -> [ApplyStep] { [.create(bead)] }

    func testTheEncodeOutputClassifiesProposesAndRoutes() throws {
        let out = route(try RoutingFixtures.encodeSteps())

        let kinds = try KindRegistryStore().kinds(project: project)
        let snapshot = try XCTUnwrap(kinds.first { $0.id == "snapshot-tests" })
        XCTAssertEqual(snapshot.origin, .planning)
        XCTAssertEqual(snapshot.status, .active)
        XCTAssertEqual(snapshot.dimensions, ["test-authoring": 0.8, "agentic-coding": 0.3])
        XCTAssertEqual(out.proposed, ["snapshot-tests"])

        let n1 = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: out.contexts["n1"]).get())
        XCTAssertEqual(n1.kind, "tests"); XCTAssertEqual(n1.harness, "codex"); XCTAssertEqual(n1.source.ruleId, "r3")

        let n2 = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: out.contexts["n2"]).get())
        XCTAssertEqual(n2.kind, "snapshot-tests"); XCTAssertEqual(n2.model, "gpt-6-sol")
        XCTAssertEqual(n2.knobs, ["effort": "high"], "the proposal routes by the same rule, no recompile")

        let n3 = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: out.contexts["n3"]).get())
        XCTAssertEqual(n3.kind, "implement-simple"); XCTAssertEqual(n3.harness, "claude"); XCTAssertEqual(n3.source.by, .default)
        XCTAssertTrue(n3.source.reason.hasPrefix("no kind from planning; "), n3.source.reason)

        XCTAssertEqual(Set(out.contexts.keys), ["n1", "n2", "n3"])
        XCTAssertEqual(out.unroutable, [:])
    }

    func testAProposalNamedLikeAnExistingKindReusesIt() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d",
                                       kindProposal: KindProposal(name: "TESTS!!", description: "x", dimensions: ["docs-prose": 0.9]))))
        XCTAssertEqual(out.proposed, [])
        XCTAssertEqual(out.blocks["n1"]?.kind, "tests")
        XCTAssertFalse(FileManager.default.fileExists(atPath: KindRegistryStore.fileURL(project: project).path),
                       "reusing a seed kind writes nothing")
    }

    func testProposalNamedOnlyPunctuationFallsBackAndWritesNothing() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d",
                                       kindProposal: KindProposal(name: "!!!", description: "x", dimensions: ["test-authoring": 0.9]))))
        XCTAssertEqual(out.blocks["n1"]?.kind, EncodeRouting.fallbackKind)
        XCTAssertFalse(FileManager.default.fileExists(atPath: KindRegistryStore.fileURL(project: project).path))
        XCTAssertEqual(out.proposed, [])
    }

    func testProposalWithEmptyNameFallsBackAndWritesNothing() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d",
                                       kindProposal: KindProposal(name: "", description: "x", dimensions: ["test-authoring": 0.9]))))
        XCTAssertEqual(out.blocks["n1"]?.kind, EncodeRouting.fallbackKind)
        XCTAssertFalse(FileManager.default.fileExists(atPath: KindRegistryStore.fileURL(project: project).path))
        XCTAssertEqual(out.proposed, [])
    }

    func testAnUnknownKindIdFallsBack() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d", taskKind: "astrology")))
        XCTAssertEqual(out.blocks["n1"]?.kind, "implement-simple")
        XCTAssertTrue(out.blocks["n1"]?.source.reason.hasPrefix("no kind from planning; ") == true)
    }

    func testAKindIdIsNormalizedBeforeLookup() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d", taskKind: "Tests")))
        XCTAssertEqual(out.blocks["n1"]?.kind, "tests")
    }

    func testAProposalDropsUnknownDimensionsAndClampsWeights() throws {
        _ = route(create(NewBead(tempId: "n1", title: "T", description: "d",
                                 kindProposal: KindProposal(name: "Fuzzing", description: "x",
                                                            dimensions: ["test-authoring": 1.4, "vibes": 0.5]))))
        let fuzz = try XCTUnwrap(try KindRegistryStore().kinds(project: project).first { $0.id == "fuzzing" })
        XCTAssertEqual(fuzz.dimensions, ["test-authoring": 1.0])
    }

    func testAnUnroutableTaskGetsNoContext() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d", taskKind: "tests")),
                        catalogs: D.catalogsDisabling(["codex", "claude"]))
        XCTAssertEqual(out.contexts, [:])
        XCTAssertEqual(out.blocks, [:])
        XCTAssertTrue(out.unroutable["n1"]?.hasPrefix("unroutable: ") == true)
    }

    func testOnlyCreatesAreRouted() {
        let out = route([.update(id: "b1", set: FieldSet(title: "x")), .reopen(id: "b2", reason: "r")])
        XCTAssertEqual(out, EncodeRouting.Outcome())
    }
}
