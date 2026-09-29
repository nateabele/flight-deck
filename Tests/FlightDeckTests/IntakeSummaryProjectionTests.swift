import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

@MainActor
final class IntakeSummaryProjectionTests: XCTestCase {
    private func intake(_ state: IntakeState, intent: String = "Add a crew calendar. Then more.") -> Intake {
        var i = Intake(projectPath: "/w/larkOS", intent: intent, createdAt: Date(timeIntervalSinceReferenceDate: 1_000))
        i.state = state
        return i
    }

    func testTheTitleIsTheDesktopsLead() {
        let s = IntakeSummaryProjection.summary(intake(.triaging), tape: nil, seats: nil, needsAttention: false)
        XCTAssertEqual(s.title, IntakeTitle(intent: "Add a crew calendar. Then more.").lead)
        XCTAssertEqual(s.state, "triaging")
        XCTAssertEqual(s.now, "Triage")
    }

    func testNeedsAnswersCarriesTheOpenQuestionCount() {
        var i = intake(.needsAnswers)
        i.exchanges = [TriageExchange(questions: ["a", "b"], answers: ["x", "y"]),
                       TriageExchange(questions: ["c", "d", "e"])]
        let s = IntakeSummaryProjection.summary(i, tape: nil, seats: nil, needsAttention: true)
        XCTAssertEqual(s.questionCount, 3)
        XCTAssertEqual(s.now, "Clarify 2")
        XCTAssertTrue(s.needsAttention)
    }

    func testShapingCarriesTheRoundInFlightAndItsStart() {
        var i = intake(.shaping)
        i.chosenPreset = .fullPlan
        i.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        var tape = Tape()
        tape.status = .running
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        tape.roundStartedAt = Date(timeIntervalSinceReferenceDate: 5_000)
        let s = IntakeSummaryProjection.summary(i, tape: tape, seats: nil, needsAttention: false)
        XCTAssertEqual(s.now, "Refine 2")
        XCTAssertEqual(s.runStatus, "running")
        XCTAssertEqual(s.clockSince, tape.roundStartedAt)
        XCTAssertEqual(s.preset, "fullPlan")
    }

    func testReleasedIntakesAreListedForThreeDaysThenLeave() {
        var i = intake(.released)
        let released = Date(timeIntervalSinceReferenceDate: 10_000)
        i.release = ReleaseRecord(releasedAt: released, appliedSteps: 1, idMap: ["a": "fd-1", "b": "fd-2"])
        XCTAssertTrue(IntakeSummaryProjection.isListed(i, now: released.addingTimeInterval(3 * 24 * 3600 - 1)))
        XCTAssertFalse(IntakeSummaryProjection.isListed(i, now: released.addingTimeInterval(3 * 24 * 3600 + 1)))
        XCTAssertEqual(IntakeSummaryProjection.summary(i, tape: nil, seats: nil, needsAttention: false).releasedTaskCount, 2)
    }

    func testDiscardedIntakesAreNeverListed() {
        XCTAssertFalse(IntakeSummaryProjection.isListed(intake(.discarded), now: Date()))
    }

    func testChangesEmitOnlyForProjectsWhoseListDiffers() {
        let a = UUID(), b = UUID()
        let s = IntakeSummaryProjection.summary(intake(.triaging), tape: nil, seats: nil, needsAttention: false)
        let events = IntakeSummaryProjection.changes(from: [a: [s], b: nil], to: [a: [s], b: []])
        XCTAssertEqual(events, [.projectIntakes(project: b, intakes: [])])
    }

    /// An absent key is exactly nil — the projection reads a missing cache entry as nil too, so
    /// the mirror and the oracle agree without a forced first event, and startup (which
    /// refreshes every project) records nothing for a Mac with Flight Control off everywhere.
    func testAnAbsentProjectReadsAsNil() {
        let a = UUID()
        XCTAssertEqual(IntakeSummaryProjection.changes(from: [:], to: [a: nil]), [])
        XCTAssertEqual(IntakeSummaryProjection.changes(from: [:], to: [a: []]),
                       [.projectIntakes(project: a, intakes: [])])
        XCTAssertEqual(IntakeSummaryProjection.changes(from: [a: nil], to: [a: nil]), [])
    }
}
