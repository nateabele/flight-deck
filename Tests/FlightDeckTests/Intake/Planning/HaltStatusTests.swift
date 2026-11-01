import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// What the halt panel says and offers, on desktop and phone alike. Actions are pinned against
/// `TransportRules` so the phone is never offered a key the Mac would refuse.
final class HaltStatusTests: XCTestCase {
    private let config = PresetExpansion.config(for: .fullPlan, available: .defaults)
    private let failedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func shaping() -> Intake {
        var i = Intake(projectPath: "/p", intent: "Plan the thing")
        i.state = .shaping
        i.roundConfig = config
        return i
    }

    /// A tape that landed everything through polish 4, then failed polish 5's polisher.
    private func failedTape() -> Tape {
        let cfg = config!
        var tape = Tape()
        var next = TapePlanner.upcoming(after: tape, config: cfg).first
        while let round = next, !(round.stage == .polish && round.round == 5) {
            tape.checkpoints.append(Checkpoint(id: tape.checkpoints.count + 1, stage: round.stage, round: round.round,
                                               major: round.major, createdAt: failedAt))
            next = TapePlanner.upcoming(after: tape, config: cfg).first
        }
        tape.status = .failed
        tape.failedAt = failedAt
        tape.pauseDiagnosis = Diagnosis(category: .harnessError, detail: "network down", action: "Retry, or change this slot.")
        return tape
    }

    private func make(_ intake: Intake, _ tape: Tape?, output: String? = nil, role: String? = nil,
                      rateLimitedAt: Date? = nil) -> HaltStatus? {
        HaltStatus.make(intake: intake, tape: tape, config: intake.roundConfig, failedSeatOutput: output,
                        rateLimitedAt: rateLimitedAt, available: .defaults, failedRole: role)
    }

    func testAFailedRoundSaysWhyAndOffersRetryAnotherModelReviewAndOutput() throws {
        let tape = failedTape()
        XCTAssertEqual(tape.pauseDiagnosis?.category, .harnessError)
        let halt = try XCTUnwrap(make(shaping(), tape, output: "boom", role: "polisher"))
        XCTAssertEqual(halt.kind, .roundFailed)
        XCTAssertEqual(halt.title, "Polish 5 failed")
        XCTAssertEqual(halt.reason, "Agent error: network down")
        XCTAssertEqual(halt.whatToDo, "Retry, or change this slot.")
        XCTAssertEqual(halt.since, failedAt)
        XCTAssertEqual(halt.output, "boom")
        XCTAssertEqual(halt.actions, [.retry, .retryOther, .toReview, .showOutput])
        let slot = try XCTUnwrap(halt.slot)
        XCTAssertEqual(slot.role, "polisher")
        XCTAssertEqual(slot.stage, .polish)
        XCTAssertEqual(slot.slotIndex, 4 % max(1, config!.polisherRotation.count))
        XCTAssertEqual(slot.harness, config?.polisher(rotation: 4)?.agent.rawValue)
    }

    func testTheActionsAreExactlyWhatTransportRulesWouldAccept() throws {
        let tape = failedTape()
        let rules = TransportRules.make(tape: tape, config: config)
        let halt = try XCTUnwrap(make(shaping(), tape))
        XCTAssertEqual(halt.actions.contains(.retry), rules.enabled.contains(.step))
        XCTAssertEqual(halt.actions.contains(.toReview), rules.enabled.contains(.toReview))
        XCTAssertFalse(halt.actions.contains(.showOutput), "no output, nothing to show")
    }

    func testAMultiSeatRoundWithoutAFailedRoleHasNoSlotToChange() throws {
        var tape = Tape()
        tape.status = .failed
        tape.pauseDiagnosis = Diagnosis(category: .timeout, detail: "slow", action: "Retry.")
        let halt = try XCTUnwrap(make(shaping(), tape))
        XCTAssertEqual(halt.title, "Draft failed")
        XCTAssertNil(halt.slot)
        XCTAssertFalse(halt.actions.contains(.retryOther))
        XCTAssertEqual(try XCTUnwrap(make(shaping(), tape, role: "drafter")).slot?.slotIndex, 0)
    }

    func testPausedOffersResumeAndReview() throws {
        var tape = failedTape()
        tape.status = .paused
        tape.pauseDiagnosis = nil
        let halt = try XCTUnwrap(make(shaping(), tape))
        XCTAssertEqual(halt.kind, .paused)
        XCTAssertEqual(halt.actions, [.resume, .toReview])
        XCTAssertEqual(try XCTUnwrap(make(shaping(), { var t = tape; t.status = .stopped; return t }())).kind, .stopped)
    }

    func testAnIntakeThatFailedOffersRetryAndItsOutput() throws {
        var i = Intake(projectPath: "/p", intent: "x")
        i.state = .failed
        i.failure = "Triage failed"
        i.rawFailureOutput = "stack trace"
        let halt = try XCTUnwrap(make(i, nil))
        XCTAssertEqual(halt.kind, .intakeFailed)
        XCTAssertEqual(halt.reason, "Triage failed")
        XCTAssertEqual(halt.actions, [.retry, .showOutput])
        i.state = .interrupted
        i.rawFailureOutput = nil
        let interrupted = try XCTUnwrap(make(i, nil))
        XCTAssertEqual(interrupted.kind, .interrupted)
        XCTAssertEqual(interrupted.actions, [.retry])
    }

    func testARunningOrFinishedTapeIsNotHalted() {
        var tape = failedTape()
        tape.status = .running
        XCTAssertNil(make(shaping(), tape))
        tape.status = .reachedReview
        XCTAssertNil(make(shaping(), tape))
        var done = shaping()
        done.state = .released
        XCTAssertNil(make(done, tape))
    }

    func testARateLimitedSeatWhileRunningIsAHaltWithNoActions() throws {
        var tape = failedTape()
        tape.status = .running
        tape.roundInProgress = PlannedRound(stage: .polish, round: 5, major: false)
        let halt = try XCTUnwrap(make(shaping(), tape, rateLimitedAt: failedAt))
        XCTAssertEqual(halt.kind, .rateLimited)
        XCTAssertEqual(halt.actions, [])
    }

    func testTheOutputKeepsItsEnd() throws {
        let long = String(repeating: "a", count: 10_000) + "THE END"
        let halt = try XCTUnwrap(make(shaping(), failedTape(), output: long, role: "polisher"))
        XCTAssertLessThanOrEqual(halt.output?.utf8.count ?? .max, HaltStatus.outputLimit)
        XCTAssertTrue(halt.output?.hasSuffix("THE END") == true)
    }

    func testTheWireCarriesTheSameWords() throws {
        let halt = try XCTUnwrap(make(shaping(), failedTape(), output: "boom", role: "polisher"))
        let wire = halt.wire
        XCTAssertEqual(wire.kind, "roundFailed")
        XCTAssertEqual(wire.title, halt.title)
        XCTAssertEqual(wire.reason, halt.reason)
        XCTAssertEqual(wire.actions, ["retry", "retryOther", "toReview", "showOutput"])
        XCTAssertEqual(wire.slot?.stage, "polish")
        XCTAssertEqual(wire.slot?.role, "polisher")
    }
}
