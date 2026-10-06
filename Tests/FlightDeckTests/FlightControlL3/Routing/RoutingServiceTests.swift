import XCTest
import IntakeKit
@testable import FlightDeck

/// The app's owner of routing rules (spec L3-R §2–§3): the global list in preferences, the
/// project list in the repo, and the draft → compiled → confirmed path between them.
@MainActor
final class RoutingServiceTests: XCTestCase {
    private typealias D = RoutingTestData
    private var project: URL!
    private var path: String { project.path }

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingServiceTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private func make(prefs: PreferencesStore? = nil, compiler: ScriptedCompiler? = nil,
                      hints: any RuleHintSource = NoRuleHints()) -> RoutingService {
        RoutingServiceSupport.make(prefs: prefs, compiler: compiler, hints: hints)
    }

    func testAddCompileConfirmAGlobalRule() async throws {
        let prefs = PreferencesStore(persistence: nil)
        let svc = make(prefs: prefs)
        let id = try XCTUnwrap(svc.addRule("  " + D.specSentence + " ", to: .global))
        XCTAssertEqual(svc.rules(.global).first?.state, .draft)
        XCTAssertEqual(svc.rules(.global).first?.sentence, D.specSentence)
        await svc.compile(id, in: .global)
        let compiled = try XCTUnwrap(svc.rules(.global).first)
        XCTAssertEqual(compiled.state, .compiled)
        XCTAssertEqual(compiled.compiled?.assign.pool, "codex-default")
        XCTAssertEqual(compiled.compiler, CompilerRef(harness: "claude", model: "haiku"))
        XCTAssertEqual(compiled.compiledAt, D.at)
        svc.confirm(id, in: .global)
        XCTAssertEqual(prefs.globalRoutingRules.first?.state, .confirmed)
    }

    func testACompileFailureIsShownWithItsFirstError() async throws {
        var bad = RoutingServiceSupport.serviceWire
        bad.terms[0].dimension = "teleportation"
        let svc = make(compiler: ScriptedCompiler(.wire(bad)))
        let id = try XCTUnwrap(svc.addRule("Use Codex when a task needs teleportation", to: .global))
        await svc.compile(id, in: .global)
        XCTAssertEqual(svc.rules(.global).first?.state, .failed)
        XCTAssertEqual(svc.rules(.global).first?.failure,
                       "“teleportation” is not a skill Flight Control scores — reword the rule around a task kind or skill")
    }

    func testAnUnavailableCompilerLeavesTheRuleADraftAndSaysWhy() async throws {
        let svc = make(compiler: ScriptedCompiler(.unavailable("claude exited 1: Not logged in")))
        let id = try XCTUnwrap(svc.addRule("x", to: .global))
        await svc.compile(id, in: .global)
        XCTAssertEqual(svc.rules(.global).first?.state, .draft)
        XCTAssertEqual(svc.notes[id], "Compiler unavailable: claude exited 1: Not logged in")
        XCTAssertTrue(svc.compiling.isEmpty)
    }

    func testEditingTheSentenceReturnsToDraft() async throws {
        let svc = make()
        let id = try XCTUnwrap(svc.addRule(D.specSentence, to: .global))
        await svc.compile(id, in: .global)
        svc.confirm(id, in: .global)
        svc.editSentence(id, "Use Codex for tests only", in: .global)
        let rule = try XCTUnwrap(svc.rules(.global).first)
        XCTAssertEqual(rule.state, .draft)
        XCTAssertNil(rule.compiled)
    }

    func testOnlyACompiledRuleCanBeConfirmed() throws {
        let svc = make()
        let id = try XCTUnwrap(svc.addRule("x", to: .global))
        svc.confirm(id, in: .global)
        XCTAssertEqual(svc.rules(.global).first?.state, .draft)
    }

    func testProjectRulesLiveInTheRepoFile() throws {
        let svc = make()
        let id = try XCTUnwrap(svc.addRule(D.specSentence, to: .project(path)))
        XCTAssertEqual(ProjectRoutingStore().load(project: project).rules.map(\.id), [id])
        XCTAssertEqual(svc.rules(.global), [])
    }

    func testProjectRuleEditsAreRefusedWhileTheFileIsInvalid() throws {
        let url = ProjectRoutingStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("<<<<<<< HEAD\n".utf8)
        try broken.write(to: url)
        let svc = make()
        XCTAssertNil(svc.addRule("Use Claude for docs", to: .project(path)))
        XCTAssertNotNil(svc.projectRulesError(path))
        XCTAssertEqual(svc.rules(.project(path)), [])
        XCTAssertEqual(try Data(contentsOf: url), broken, "the user's file is never overwritten")
    }

    func testGlobalRulesCompileAgainstSeedKindsAndProjectRulesAgainstTheRegistry() async throws {
        let kinds = KindRegistryStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: kinds.deletingLastPathComponent(), withIntermediateDirectories: true)
        try L3Fixtures.data("kinds").write(to: kinds)
        let compiler = ScriptedCompiler(.wire(RoutingServiceSupport.serviceWire))
        let svc = make(compiler: compiler)
        let g = try XCTUnwrap(svc.addRule("x", to: .global))
        await svc.compile(g, in: .global)
        let p = try XCTUnwrap(svc.addRule("y", to: .project(path)))
        await svc.compile(p, in: .project(path))
        XCTAssertFalse(compiler.inputs[0].kinds.contains { $0.id == "snapshot-tests" })
        XCTAssertTrue(compiler.inputs[1].kinds.contains { $0.id == "snapshot-tests" })
        XCTAssertEqual(compiler.inputs[0].defaultPools["codex"], "codex-default")
    }

    func testAnEditDuringACompileWins() async throws {
        let compiler = ScriptedCompiler(.wire(RoutingServiceSupport.serviceWire))
        let svc = make(compiler: compiler)
        let id = try XCTUnwrap(svc.addRule("first words", to: .global))
        compiler.beforeReturning = { svc.editSentence(id, "second words", in: .global) }
        await svc.compile(id, in: .global)
        let rule = try XCTUnwrap(svc.rules(.global).first)
        XCTAssertEqual(rule.sentence, "second words")
        XCTAssertEqual(rule.state, .draft)
        XCTAssertNil(rule.compiled)
    }

    func testMovingARuleChangesWhichMatchesFirst() throws {
        let svc = make()
        let a = try XCTUnwrap(svc.addRule("a", to: .global))
        let b = try XCTUnwrap(svc.addRule("b", to: .global))
        svc.moveRule(b, by: -1, in: .global)
        XCTAssertEqual(svc.rules(.global).map(\.id), [b, a])
        svc.moveRule(b, by: -1, in: .global)
        XCTAssertEqual(svc.rules(.global).map(\.id), [b, a], "moving past the top is a no-op")
    }

    func testTheRouterRoutesByWhatIsConfirmedNow() async throws {
        let svc = make()
        let id = try XCTUnwrap(svc.addRule(D.specSentence, to: .global))
        await svc.compile(id, in: .global)
        XCTAssertEqual(svc.makeRouter().assign(kind: D.snapshot, project: project, catalogs: D.catalogs, now: D.at).block.source.by,
                       .default, "compiled is not confirmed")
        svc.confirm(id, in: .global)
        let a = svc.makeRouter().assign(kind: D.snapshot, project: project, catalogs: D.catalogs, now: D.at)
        XCTAssertEqual(a.block.harness, "codex")
        XCTAssertEqual(a.block.source.ruleId, id)
    }

    func testTheDefaultAgentIsTheProjectsChoice() {
        let prefs = PreferencesStore(persistence: nil)
        prefs.setProjectSettings(path, ProjectSettings(defaultAgent: .codex))
        let svc = make(prefs: prefs)
        XCTAssertEqual(svc.makeRouter().assign(kind: D.docs, project: project, catalogs: D.catalogs, now: D.at).block.harness, "codex")
        let elsewhere = URL(fileURLWithPath: "/elsewhere", isDirectory: true)
        XCTAssertEqual(svc.makeRouter().assign(kind: D.docs, project: elsewhere, catalogs: D.catalogs, now: D.at).block.harness,
                       "claude", "a project with no choice gets the first global agent")
    }

    func testHintsShowOnConfirmedRulesAndStayDismissedUntilTheSnapshotChanges() async throws {
        let prefs = PreferencesStore(persistence: nil)
        let first = RuleHint(ruleID: "r1", text: "gpt-6-luna scores 0.14 higher on test-authoring (confidence 0.8)",
                             snapshotDate: Date(timeIntervalSince1970: 1_000))
        let svc = make(prefs: prefs, hints: FixedHints(fixed: first))
        let id = try XCTUnwrap(svc.addRule(D.specSentence, to: .global))
        XCTAssertEqual(id, "r1")
        XCTAssertNil(svc.hint(for: svc.rules(.global)[0], scope: .global), "a draft shows no hint")
        await svc.compile(id, in: .global)
        svc.confirm(id, in: .global)
        XCTAssertEqual(svc.hint(for: svc.rules(.global)[0], scope: .global), first)
        svc.dismissHint(first)
        XCTAssertNil(svc.hint(for: svc.rules(.global)[0], scope: .global))

        var newer = first
        newer.snapshotDate = Date(timeIntervalSince1970: 2_000)
        let later = make(prefs: prefs, hints: FixedHints(fixed: newer))
        XCTAssertEqual(later.hint(for: prefs.globalRoutingRules[0], scope: .global), newer, "a new index snapshot brings it back")
    }
}
