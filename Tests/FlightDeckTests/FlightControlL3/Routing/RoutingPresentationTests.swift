import XCTest
import IntakeKit
@testable import FlightDeck

/// What a rule row and a kind row show and allow, decided outside SwiftUI so it is tested here;
/// the views only lay it out (and `RoutingUITests` drives them).
final class RoutingPresentationTests: XCTestCase {
    private typealias D = RoutingTestData

    func testADraftCanCompileButNotConfirm() {
        let p = RuleRowPresentation(rule: RoutingRule(id: "r1", sentence: "x"), compiling: false, note: nil)
        XCTAssertEqual(p.stateLabel, "Draft")
        XCTAssertTrue(p.canCompile); XCTAssertFalse(p.canConfirm)
        XCTAssertNil(p.compiledText); XCTAssertNil(p.failureText)
    }

    func testACompiledRuleShowsItsFormAndWaitsForConfirm() {
        let rule = D.r3(state: .compiled)
        let p = RuleRowPresentation(rule: rule, compiling: false, note: nil)
        XCTAssertEqual(p.stateLabel, "Compiled — confirm to use")
        XCTAssertEqual(p.compiledText, RuleText.compiled(rule.compiled!))
        XCTAssertTrue(p.canConfirm); XCTAssertFalse(p.canCompile)
    }

    func testAConfirmedRuleOffersNeitherUntilItsSentenceChanges() {
        let p = RuleRowPresentation(rule: D.r3(), compiling: false, note: nil)
        XCTAssertEqual(p.stateLabel, "Confirmed")
        XCTAssertFalse(p.canCompile); XCTAssertFalse(p.canConfirm)
        XCTAssertNotNil(p.compiledText)
    }

    func testAFailedRuleSaysWhyAndCanBeRecompiled() {
        let rule = RoutingRule(id: "r1", sentence: "x", state: .failed, failure: "unknown dimension teleportation")
        let p = RuleRowPresentation(rule: rule, compiling: false, note: nil)
        XCTAssertEqual(p.stateLabel, "Failed")
        XCTAssertEqual(p.failureText, "Failed: unknown dimension teleportation")
        XCTAssertTrue(p.canCompile)
    }

    func testWhileCompilingNothingIsOffered() {
        let p = RuleRowPresentation(rule: RoutingRule(id: "r1", sentence: "x"), compiling: true, note: nil)
        XCTAssertEqual(p.stateLabel, "Compiling…")
        XCTAssertFalse(p.canCompile); XCTAssertFalse(p.canConfirm)
    }

    func testTheCompilerNoteRidesAlong() {
        let p = RuleRowPresentation(rule: RoutingRule(id: "r1", sentence: "x"), compiling: false, note: "Compiler unavailable: offline")
        XCTAssertEqual(p.note, "Compiler unavailable: offline")
    }

    func testKindRowsLabelOriginStatusAndBars() {
        let golden = KindRowPresentation(kind: D.golden, isNew: true, openCount: 3)
        XCTAssertEqual(golden.originLabel, "Planning")
        XCTAssertEqual(golden.statusLabel, "Merged into snapshot-tests")
        XCTAssertEqual(golden.bars.map(\.dimension), Dimensions.all.map(\.id), "one bar per dimension, in a fixed order, so rows compare")
        XCTAssertEqual(golden.bars.first { $0.dimension == "test-authoring" }?.weight, 0.8)
        XCTAssertEqual(golden.openCount, 3); XCTAssertTrue(golden.isNew)
        let tests = KindRowPresentation(kind: D.tests, isNew: false, openCount: 0)
        XCTAssertEqual(tests.originLabel, "Seed"); XCTAssertEqual(tests.statusLabel, "Active")
    }

    func testMergeTargetsAreOtherLiveKinds() {
        XCTAssertEqual(KindRowPresentation.mergeTargets(for: D.snapshot, in: D.kinds).map(\.id), ["tests", "algorithm", "docs"])
    }
}
