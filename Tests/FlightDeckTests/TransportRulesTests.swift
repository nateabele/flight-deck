import XCTest
import IntakeKit
@testable import FlightDeck

/// The one transport rule the desktop's bar, its Run menu and the phone all read — a key the
/// phone offers that the Mac would refuse (⏭ after a failure, + on a finished stage) is pinned
/// here rather than discovered by a refusal on the handset.
final class TransportRulesTests: XCTestCase {
    private func config() -> RoundConfig? { PresetExpansion.config(for: .fullPlan, available: .defaults) }

    func testRunningAllowsOnlyPauseStopAndAnnotate() {
        var tape = Tape(); tape.status = .running
        tape.roundInProgress = PlannedRound(stage: .refine, round: 1, major: false)
        XCTAssertEqual(TransportRules.make(tape: tape, config: config()).enabled, [.pause, .stop, .annotate])
    }

    func testPausedAllowsPlaysAndRoundEdits() {
        var tape = Tape(); tape.status = .paused
        let rules = TransportRules.make(tape: tape, config: config())
        XCTAssertTrue(rules.enabled.isSuperset(of: [.step, .nextMajor, .toReview, .annotate]))
        XCTAssertEqual(rules.extendStage, .refine, "before refine has run, + lengthens refine")
    }

    func testFailedWithholdsNextMajor() {
        var tape = Tape(); tape.status = .failed
        XCTAssertEqual(TransportRules.make(tape: tape, config: config()).enabled, [.step, .toReview, .annotate])
    }

    func testReviewAllowsNothing() {
        var tape = Tape(); tape.status = .reachedReview
        XCTAssertEqual(TransportRules.make(tape: tape, config: config()).enabled, [])
    }

    func testExtendAndTrimDropOutWhenNoStageQualifies() {
        var tape = Tape(); tape.status = .paused
        let rules = TransportRules.make(tape: tape, config: nil)
        XCTAssertFalse(rules.enabled.contains(.extend))
        XCTAssertFalse(rules.enabled.contains(.trim))
    }

    /// The desktop reads the same rule the wire carries: `ShapingModel.enabled` (what the bar
    /// and `PlanningActions` light) must equal `TransportRules` for every status, so the phone
    /// can never be offered a set the Mac's own bar doesn't show.
    func testTheDesktopBarReadsTheSameRule() throws {
        var intake = Intake(projectPath: "/tmp/project", intent: "the thing")
        intake.state = .shaping
        intake.roundConfig = try XCTUnwrap(config())
        for status: RunnerStatus in [.running, .paused, .idle, .stopped, .failed, .reachedReview] {
            var tape = Tape(); tape.status = status
            XCTAssertEqual(ShapingModel(intake: intake, tape: tape).enabled,
                           TransportRules.make(tape: tape, config: intake.roundConfig).enabled, "\(status)")
        }
    }
}
