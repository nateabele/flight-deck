import XCTest
import IntakeKit
@testable import FlightDeck

/// L3-R draws one hint line per rule; L3-I knows which model is better. This adapter is the
/// only place the two meet, so it pins the translation: which dimensions count, which
/// candidate wins, and that a hint carries the snapshot it came from (so a dismissal expires
/// when the index changes, not before).
final class CapabilityRuleHintSourceTests: XCTestCase {
    private let snap1 = Date(timeIntervalSince1970: 1_790_000_000)
    private let snap2 = Date(timeIntervalSince1970: 1_790_600_000)
    /// Scored with the rule's knobs: L3-I matches a knobbed assignment to that exact variant only.
    private let sol = ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"])
    private let opus = ModelRef(harness: "claude", model: "opus")

    private func rule() -> RoutingRule {
        RoutingTestData.rule("r3", .any([.dimension("test-authoring", atLeast: 0.5)]), "codex", "gpt-6-sol",
                             knobs: ["effort": "high"], pool: "codex-default")
    }

    private func catalogs() -> AdapterCatalogs { RoutingTestData.catalogs }

    private func better() -> [ModelScores] {
        IndexTestScores.make([(sol, "test-authoring", 0.60, 0.9), (opus, "test-authoring", 0.78, 0.8)])
    }

    func testHintNamesTheBetterModelAndTheSnapshot() throws {
        let scores = better(), snap = snap1
        let src = CapabilityRuleHintSource { (scores, snap) }
        let hint = try XCTUnwrap(src.hint(for: rule(), kinds: [], catalogs: catalogs()))
        XCTAssertEqual(hint.ruleID, "r3")
        XCTAssertEqual(hint.snapshotDate, snap1)
        XCTAssertTrue(hint.text.hasPrefix("opus scores 0.18 higher on test-authoring"), hint.text)
        // Bare: "Switch to opus" re-targets the rule's model, and the rule's own effort is
        // re-validated against it rather than inheriting whatever variant the index scored.
        XCTAssertEqual(hint.suggested, ModelRef(harness: "claude", model: "opus"))
    }

    func testNoHintWithoutIndexOrBelowMargin() {
        XCTAssertNil(CapabilityRuleHintSource { nil }.hint(for: rule(), kinds: [], catalogs: catalogs()))
        let close = IndexTestScores.make([(sol, "test-authoring", 0.70, 0.9), (opus, "test-authoring", 0.75, 0.9)])
        let snap = snap1
        XCTAssertNil(CapabilityRuleHintSource { (close, snap) }.hint(for: rule(), kinds: [], catalogs: catalogs()))
    }

    /// The index usually scores a model bare; a rule that pins effort=high must still get a hint.
    func testKnobbedRuleGetsHintFromBareScores() throws {
        let bare = ModelRef(harness: "codex", model: "gpt-6-sol")
        let scores = IndexTestScores.make([(bare, "test-authoring", 0.60, 0.9), (opus, "test-authoring", 0.78, 0.8)])
        let snap = snap1
        let src = CapabilityRuleHintSource { (scores, snap) }
        let hint = try XCTUnwrap(src.hint(for: rule(), kinds: [], catalogs: catalogs()))
        XCTAssertTrue(hint.text.hasPrefix("opus scores 0.18 higher on test-authoring"), hint.text)
    }

    /// A rule with only kind terms has no dimension to compare: no hint, not a crash.
    func testKindOnlyRuleGetsNoHint() {
        let r = RoutingTestData.rule("k", .any([.kind("tests")]), "codex", "gpt-6-sol", pool: "codex-default")
        let scores = better(), snap = snap1
        XCTAssertNil(CapabilityRuleHintSource { (scores, snap) }.hint(for: r, kinds: [], catalogs: catalogs()))
    }

    @MainActor
    func testDismissedHintReturnsOnNewSnapshot() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rule-hint-\(UUID())"))
        let prefs = PreferencesStore(persistence: UserDefaultsPreferencesPersistence(defaults: defaults))
        let scores = better()
        let box = SnapshotBox(snap1)
        let src = CapabilityRuleHintSource { (scores, box.date) }
        let first = try XCTUnwrap(src.hint(for: rule(), kinds: [], catalogs: catalogs()))
        prefs.dismissHint(ruleID: first.ruleID, snapshot: first.snapshotDate)
        XCTAssertTrue(prefs.isHintDismissed(ruleID: first.ruleID, snapshot: first.snapshotDate))
        box.date = snap2
        let second = try XCTUnwrap(src.hint(for: rule(), kinds: [], catalogs: catalogs()))
        XCTAssertFalse(prefs.isHintDismissed(ruleID: second.ruleID, snapshot: second.snapshotDate),
                       "a new snapshot must bring the hint back")
    }
}

/// Lets the @Sendable scores closure observe the index moving between two calls.
private final class SnapshotBox: @unchecked Sendable {
    var date: Date
    init(_ d: Date) { date = d }
}
