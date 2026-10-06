import XCTest
import IntakeKit
@testable import FlightDeck

/// `RoutingUITests` can only be as honest as the fixture under it. Real stores and the real
/// validator; only the model call, the catalogs and `br` are scripted.
@MainActor
final class RoutingUIFixtureTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingUIFixtureTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testTheFixtureProjectHasKindsAConfirmedRuleAndAHint() throws {
        let svc = RoutingUIFixture.service(preferences: PreferencesStore(persistence: nil), root: root)
        let project = try XCTUnwrap(svc.fixtureProjects?.first)
        guard case .loaded(let kinds) = svc.kinds(project: project) else { return XCTFail("fixture kinds did not load") }
        XCTAssertEqual(kinds.map(\.id), ["tests", "snapshot-tests", "golden-tests", "algorithm"])
        let rule = try XCTUnwrap(svc.rules(.project(project)).first)
        XCTAssertEqual(rule.state, .confirmed)
        XCTAssertNotNil(svc.hint(for: rule, scope: .project(project)))
    }

    func testTheFixtureCompilerGoesThroughTheRealValidator() async throws {
        let svc = RoutingUIFixture.service(preferences: PreferencesStore(persistence: nil), root: root)
        let a = try XCTUnwrap(svc.addRule("Use Codex for unit and integration tests, and for complex algorithms", to: .global))
        XCTAssertEqual(a, "r1", "RoutingUITests addresses rows by these ids")
        await svc.compile(a, in: .global)
        let compiled = try XCTUnwrap(svc.rules(.global).first?.compiled)
        XCTAssertTrue(RuleText.compiled(compiled).contains("codex · gpt-6-sol · effort high · pool codex-default"))
        let b = try XCTUnwrap(svc.addRule("Use Codex when a task needs teleportation", to: .global))
        await svc.compile(b, in: .global)
        XCTAssertEqual(svc.rules(.global).last?.failure,
                       "“teleportation” is not a skill Flight Control scores — reword the rule around a task kind or skill")
    }

    /// `RoutingUITests` clicks "Switch to gpt-6-luna" in the hint popover and reads the
    /// actionable failure line, so both need the fixture to produce them.
    func testTheFixtureHintSuggestsAModelAndAMisspelledModelFailsWithAFix() async throws {
        let svc = RoutingUIFixture.service(preferences: PreferencesStore(persistence: nil), root: root)
        let project = try XCTUnwrap(svc.fixtureProjects?.first)
        let rule = try XCTUnwrap(svc.rules(.project(project)).first)
        XCTAssertEqual(svc.hint(for: rule, scope: .project(project))?.suggested, ModelRef(harness: "codex", model: "gpt-6-luna"))
        let id = try XCTUnwrap(svc.submitNewRule("Anything UI-heavy uses Sonnet", to: .global))
        await svc.waitForCompile(id)
        XCTAssertEqual(svc.rules(.global).first?.failure,
                       "“Sonnet” matched no model in Claude's catalog — try “sonnet”, or reword the rule")
    }

    /// Only the no-flags case: the flags are launch arguments, which a unit run cannot set.
    func testTheFixtureIsOffByDefault() {
        XCTAssertFalse(RoutingUIFixture.isActive)
    }
}
