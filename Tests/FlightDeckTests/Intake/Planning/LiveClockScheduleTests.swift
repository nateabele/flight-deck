import XCTest
import IntakeKit
@testable import FlightDeck

/// The live card's and pinned bar's clock (spec §2): 1 Hz while something runs, suspended while
/// the window is occluded or nothing counts, and — once nothing is running — 1 Hz for a minute
/// and then once a minute. A paused intake left on screen used to redraw the card, the board and
/// the LCD every second for as long as it stayed there.
final class LiveClockScheduleTests: XCTestCase {
    private func ticks(_ schedule: LiveClockSchedule, from start: TimeInterval, count: Int) -> [TimeInterval] {
        let entries = schedule.entries(from: Date(timeIntervalSinceReferenceDate: start), mode: .normal)
        return (0..<count).compactMap { _ in entries.next()?.timeIntervalSinceReferenceDate }
    }

    func testLiveTicksOnWholeSeconds() {
        XCTAssertEqual(ticks(LiveClockSchedule(mode: .live), from: 100.4, count: 4), [100.4, 101, 102, 103])
    }

    /// Idle: whole seconds until a minute after the idle clock's own origin, then on its whole
    /// minutes — so a per-minute tick reads "13:00", never a stale "12:34" held for a minute.
    func testIdleTicksEverySecondForAMinuteThenEveryMinute() {
        let since = Date(timeIntervalSinceReferenceDate: 1000)
        let fresh = ticks(LiveClockSchedule(mode: .idle(since: since)), from: 1057.5, count: 6)
        XCTAssertEqual(fresh, [1057.5, 1058, 1059, 1060, 1120, 1180])

        let old = ticks(LiveClockSchedule(mode: .idle(since: since)), from: 1000 + 3600.2, count: 3)
        XCTAssertEqual(old, [4600.2, 4660, 4720])
    }

    /// Suspension: occluded, or with nothing counting, the timeline draws one frame and stops.
    func testSuspendedClocksDrawOnceAndStop() {
        XCTAssertEqual(ticks(LiveClockSchedule(mode: .live, visible: false), from: 50, count: 3), [50])
        XCTAssertEqual(ticks(LiveClockSchedule(mode: .idle(since: .distantPast), visible: false), from: 50, count: 3), [50])
        XCTAssertEqual(ticks(LiveClockSchedule(mode: .still), from: 50, count: 3), [50])
    }

    /// Which schedule a shaping tape gets: live while a round runs or a start is pending; idle
    /// from the moment its PAUSED FOR / HALTED FOR clock counts from; still at review (its TOTAL
    /// never moves) and with no origin at all ("—" never moves either).
    func testShapingModeFollowsTheBoardsIdleClock() {
        let t0 = Date(timeIntervalSinceReferenceDate: 5000)
        var tape = Tape()
        tape.checkpoints = [Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: t0)]

        tape.status = .running
        XCTAssertEqual(LiveClockSchedule.Mode.shaping(tape: tape, pending: nil), .live)
        tape.status = .paused
        XCTAssertEqual(LiveClockSchedule.Mode.shaping(tape: tape, pending: nil), .idle(since: t0))
        XCTAssertEqual(LiveClockSchedule.Mode.shaping(tape: tape, pending: PendingStart(kind: .round(nil), since: t0)), .live)
        tape.status = .failed
        tape.failedAt = t0.addingTimeInterval(90)
        XCTAssertEqual(LiveClockSchedule.Mode.shaping(tape: tape, pending: nil), .idle(since: t0.addingTimeInterval(90)))
        tape.status = .reachedReview
        XCTAssertEqual(LiveClockSchedule.Mode.shaping(tape: tape, pending: nil), .still)
        XCTAssertEqual(LiveClockSchedule.Mode.shaping(tape: Tape(), pending: nil), .still, "nothing has landed; nothing counts")
    }
}
