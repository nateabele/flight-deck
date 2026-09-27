import XCTest
import SwiftUI
import IntakeKit
@testable import FlightDeck

final class IntakeStatePillTests: XCTestCase {
    private func intake(_ state: IntakeState, appliedSteps: Int = 3) -> Intake {
        var i = Intake(projectPath: "/tmp/project", intent: "do a thing")
        i.state = state
        if state == .released || state == .partiallyReleased {
            i.release = ReleaseRecord(releasedAt: Date(), appliedSteps: appliedSteps, idMap: [:])
        }
        return i
    }

    /// Every `IntakeState` case, spelled out per spec §Intakes list — a missing case here
    /// would leave a real state silently unlabeled in the list/detail pill.
    func testLabelCoversEveryState() {
        XCTAssertEqual(IntakeStatePill.label(for: intake(.triaging)), "triaging")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.needsAnswers)), "needs answers")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.awaitingChoice)), "choose fidelity")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.parked)), "parked")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.review)), "review")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.releasing)), "releasing")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.partiallyReleased)), "partial")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.failed)), "failed")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.interrupted)), "interrupted")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.discarded)), "discarded")
    }

    /// `released` is the one label that needs more than the state itself — the count lives on
    /// `Intake.release`. It counts STEPS, and says so: `appliedSteps` includes every recheck
    /// and edge, so "7 beads" for a release that created one bead was simply false.
    func testReleasedLabelCountsAppliedSteps() {
        XCTAssertEqual(IntakeStatePill.label(for: intake(.released, appliedSteps: 7)), "released · 7 steps")
        XCTAssertEqual(IntakeStatePill.label(for: intake(.released, appliedSteps: 1)), "released · 1 step")
    }

    /// A `.released` intake with no release record (should never happen, but the pure
    /// function must not crash on it) falls back to zero.
    func testReleasedLabelWithoutRecordFallsBackToZero() {
        XCTAssertEqual(IntakeStatePill.label(for: Intake(projectPath: "/tmp/p", intent: "x").with(state: .released)), "released · 0 steps")
    }

    /// Matches `SessionStatusIcon`'s colour language: orange means "needs your attention".
    func testTintMarksAttentionStatesOrange() {
        for state: IntakeState in [.needsAnswers, .awaitingChoice, .review, .partiallyReleased, .failed, .interrupted] {
            XCTAssertEqual(IntakeStatePill.tint(for: state), .orange, "\(state)")
        }
    }

    func testTintMarksActiveWorkAsAccent() {
        XCTAssertEqual(IntakeStatePill.tint(for: .triaging), Color.accentColor)
        XCTAssertEqual(IntakeStatePill.tint(for: .releasing), Color.accentColor)
    }

    func testTintMarksReleasedGreenAndRestingStatesSecondary() {
        XCTAssertEqual(IntakeStatePill.tint(for: .released), Color.green)
        XCTAssertEqual(IntakeStatePill.tint(for: .parked), Color.secondary)
        XCTAssertEqual(IntakeStatePill.tint(for: .discarded), Color.secondary)
    }
}

private extension Intake {
    func with(state: IntakeState) -> Intake {
        var copy = self
        copy.state = state
        return copy
    }
}
