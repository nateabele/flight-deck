import FleetKit
import IntakeKit
import XCTest
@testable import FlightDeck

/// The sidebar's Flight Control status: how a project's plans fold into needs-you / working /
/// idle, the words on hover, and where a click lands. Pure over `WireIntakeSummary`, the rows
/// the phone already gets, plus a few cases that build them from real intakes and tapes so the
/// state strings the derivation switches on are the ones the projection really writes.
@MainActor
final class FlightControlSidebarStatusTests: XCTestCase {
    private func row(_ title: String, _ state: IntakeState, attention: Bool = false, now: String? = nil,
                     run: RunnerStatus? = nil, id: UUID = UUID()) -> WireIntakeSummary {
        WireIntakeSummary(id: id, title: title, state: state.rawValue, needsAttention: attention, now: now,
                          runStatus: run?.rawValue, createdAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    // MARK: idle

    func testNoPlansAndOnlyFinishedPlansAreIdle() {
        XCTAssertEqual(FlightControlSidebarStatus.derive([]), .idle)
        let done = FlightControlSidebarStatus.derive([row("A", .released), row("B", .discarded)])
        XCTAssertEqual(done.kind, .idle)
        XCTAssertNil(done.target)
        XCTAssertEqual(done.accessibilityLabel, "")
    }

    // MARK: working

    func testEveryWorkingStateAndItsWords() {
        let cases: [(WireIntakeSummary, String)] = [
            (row("LarkOS plan", .triaging, now: "Triage"), "LarkOS plan: Triage running"),
            (row("LarkOS plan", .shaping, now: "Refine 2", run: .running), "LarkOS plan: Refine 2 running"),
            (row("LarkOS plan", .shaping), "LarkOS plan: Starting"),
            (row("LarkOS plan", .shaping, now: "Draft", run: .idle), "LarkOS plan: Starting"),
            (row("LarkOS plan", .releasing, now: "Review"), "LarkOS plan: Releasing"),
        ]
        for (summary, help) in cases {
            let status = FlightControlSidebarStatus.derive([summary])
            XCTAssertEqual(status.kind, .working, help)
            XCTAssertEqual(status.workingCount, 1)
            XCTAssertEqual(status.attentionCount, 0)
            XCTAssertEqual(status.help, help)
            XCTAssertEqual(status.target, summary.id)
        }
    }

    func testSeveralWorkingPlansGetALineEach() {
        let a = row("Alpha", .shaping, now: "Refine 2", run: .running)
        let b = row("Beta", .triaging, now: "Triage")
        let status = FlightControlSidebarStatus.derive([a, b])
        XCTAssertEqual(status.kind, .working)
        XCTAssertEqual(status.workingCount, 2)
        XCTAssertEqual(status.help, "Alpha: Refine 2 running\nBeta: Triage running")
        XCTAssertEqual(status.target, a.id, "the top plan of the list")
    }

    // MARK: needs you

    func testEveryAttentionStateAndItsReason() {
        let cases: [(WireIntakeSummary, String)] = [
            (row("P", .needsAnswers, attention: true, now: "Clarify 1"), "P: answer questions"),
            (row("P", .awaitingChoice, attention: true, now: "Ready"), "P: choose a fidelity"),
            (row("P", .parked, attention: true, now: "Ready"), "P: choose a fidelity"),
            (row("P", .review, attention: true, now: "Review"), "P: review the plan"),
            (row("P", .partiallyReleased, attention: true), "P: finish the release"),
            (row("P", .failed, attention: true), "P: failed"),
            (row("P", .interrupted, attention: true), "P: interrupted"),
            (row("P", .shaping, attention: true, now: "Refine 2", run: .paused), "P: paused at Refine 2"),
            (row("P", .shaping, attention: true, now: "Refine 2", run: .failed), "P: round failed at Refine 2"),
            (row("P", .shaping, attention: true, now: "Polish 1", run: .stopped), "P: stopped at Polish 1"),
            (row("P", .shaping, attention: true, run: .idle), "P: paused"),
        ]
        for (summary, help) in cases {
            let status = FlightControlSidebarStatus.derive([summary])
            XCTAssertEqual(status.kind, .needsYou, help)
            XCTAssertEqual(status.attentionCount, 1)
            XCTAssertEqual(status.help, help)
            XCTAssertEqual(status.target, summary.id)
        }
    }

    func testSeveralPlansNeedingYouAreCountedAndTheirReasonsListedOnce() {
        let rows = [row("A", .needsAnswers, attention: true), row("B", .awaitingChoice, attention: true),
                    row("C", .needsAnswers, attention: true)]
        let status = FlightControlSidebarStatus.derive(rows)
        XCTAssertEqual(status.attentionCount, 3)
        XCTAssertEqual(status.help, "3 plans need you: answer questions; choose a fidelity")
        let two = FlightControlSidebarStatus.derive([rows[0], rows[1]])
        XCTAssertEqual(two.help, "2 plans need you: answer questions; choose a fidelity")
    }

    // MARK: precedence and target

    func testNeedsYouOutranksWorkingAndBothAreSaid() {
        let running = row("LarkOS plan", .shaping, now: "Refine 2", run: .running)
        let asking = row("Crew calendar", .needsAnswers, attention: true)
        let status = FlightControlSidebarStatus.derive([running, asking])
        XCTAssertEqual(status.kind, .needsYou)
        XCTAssertEqual(status.attentionCount, 1)
        XCTAssertEqual(status.workingCount, 1)
        XCTAssertEqual(status.help, "Crew calendar: answer questions\nLarkOS plan: Refine 2 running")
        XCTAssertEqual(status.target, asking.id, "the plan that needs you, not the one listed first")
    }

    func testAPlanThatNeedsYouIsNeverAlsoCountedAsWorking() {
        // A failed triage is `failed`, but a shaping plan whose tape paused is `shaping` AND
        // needs you: it must count once, as attention.
        let paused = row("P", .shaping, attention: true, now: "Refine 1", run: .paused)
        let status = FlightControlSidebarStatus.derive([paused])
        XCTAssertEqual(status.workingCount, 0)
        XCTAssertEqual(status.attentionCount, 1)
    }

    func testTheTargetIsTheFirstPlanThatNeedsYou() {
        let first = row("A", .review, attention: true), second = row("B", .failed, attention: true)
        XCTAssertEqual(FlightControlSidebarStatus.derive([first, second]).target, first.id)
        XCTAssertEqual(FlightControlSidebarStatus.derive([second, first]).target, second.id)
    }

    // MARK: words

    func testALongTitleIsCutForTheTooltip() {
        let long = String(repeating: "long ", count: 20).trimmingCharacters(in: .whitespaces)
        let help = FlightControlSidebarStatus.derive([row(long, .needsAnswers, attention: true)]).help
        XCTAssertTrue(help.hasSuffix("…: answer questions"), help)
        XCTAssertLessThan(help.count, 70)
    }

    func testTheAccessibilityLabelSaysTheSameThingInOneBreath() {
        let status = FlightControlSidebarStatus.derive([
            row("A", .needsAnswers, attention: true), row("B", .shaping, now: "Refine 2", run: .running)])
        XCTAssertEqual(status.accessibilityLabel, "Flight Control, A: answer questions. B: Refine 2 running")
    }

    func testTheWordsNeverSayTheForbiddenOnes() {
        let all = [row("A", .needsAnswers, attention: true), row("B", .shaping, now: "Refine 2", run: .running)]
        let label = FlightControlSidebarStatus.derive(all).accessibilityLabel.lowercased()
        for banned in ["seat", "harness", "bead", "intake"] { XCTAssertFalse(label.contains(banned), banned) }
    }

    // MARK: from real intakes

    /// The derivation switches on the projection's state strings; build them the way the app
    /// does, from an intake and a tape, so a renamed case cannot silently fall through.
    func testRealProjectionsFoldTheWayTheTableSays() {
        var shaping = Intake(projectPath: "/w/p", intent: "Plan the crew calendar. Then more.")
        shaping.state = .shaping
        shaping.chosenPreset = .fullPlan
        shaping.roundConfig = PresetExpansion.config(for: .fullPlan, available: .defaults)
        var tape = Tape()
        tape.status = .running
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        let running = IntakeSummaryProjection.summary(shaping, tape: tape, seats: nil, needsAttention: false)
        XCTAssertEqual(FlightControlSidebarStatus.derive([running]).help, "Plan the crew calendar: Refine 2 running")

        tape.status = .paused
        tape.roundInProgress = nil
        let paused = IntakeSummaryProjection.summary(shaping, tape: tape, seats: nil, needsAttention: true)
        XCTAssertEqual(FlightControlSidebarStatus.derive([paused]).kind, .needsYou)

        var asking = Intake(projectPath: "/w/p", intent: "Another one")
        asking.state = .needsAnswers
        let summary = IntakeSummaryProjection.summary(asking, tape: nil, seats: nil, needsAttention: true)
        XCTAssertEqual(FlightControlSidebarStatus.derive([summary]).help, "Another one: answer questions")
    }
}
