import XCTest
import IntakeKit
@testable import FlightDeck

/// `LiveSeats` decides which seat rows a shaping round shows and which run speaks for each —
/// the live card's only logic that isn't already `SeatRowModel`'s.
final class LiveSeatsTests: XCTestCase {
    private let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private var config: RoundConfig {
        RoundConfig(drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist, fallback: codex),
                               Slot(codex, persona: .coverage)],
                    synthesizer: Slot(claude), reviewer: Slot(codex, persona: .stressTest), integrator: codex,
                    encoder: codex, polisher: codex, refinementCap: 3, polishCap: 2, freshEyesAndDedup: true,
                    defaultPlay: .nextMajor, customized: false)
    }

    /// Every seat is on the list from the moment the round starts — queued — so rows never
    /// appear under the reader mid-round.
    func testRoundSeatsAreQueuedFromTheConfig() {
        let refine = LiveSeats.rows(round: PlannedRound(stage: .refine, round: 2, major: false), config: config,
                                    seats: SeatFiles(), now: t0)
        XCTAssertEqual(refine.map(\.id), ["refine-2-reviewer", "refine-2-integrator"])
        XCTAssertEqual(refine.map(\.model.glyph), [.queued, .queued])
        XCTAssertEqual(refine.map(\.model.role), ["reviewer", "integrator"],
                       "the reviewer runs with no persona, so the row claims none")

        let draft = LiveSeats.rows(round: PlannedRound(stage: .draft, round: 0, major: true), config: config,
                                   seats: SeatFiles(), now: t0)
        XCTAssertEqual(draft.map(\.id), ["draft-0-drafter-0", "draft-0-drafter-1", "draft-0-drafter-2"])
        XCTAssertEqual(draft.map(\.model.role), ["arbiter", "realist", "coverage"])
    }

    /// A drafter that fell back is ONE row, keyed by its seat, drawn from the newest attempt — and
    /// drafter 10's runs never land on drafter 1's row.
    func testFallbackRunSpeaksForItsSeat() {
        var failed = SeatActivity(harness: .claude, startedAt: t0)
        failed.finished = true; failed.error = "exited 1"
        var fallback = SeatActivity(harness: .codex, startedAt: t0.addingTimeInterval(80))
        fallback.headline = "Questioning whether offline replay can reorder check-ins"
        fallback.lastEventAt = t0.addingTimeInterval(100)
        let stray = SeatActivity(harness: .codex, startedAt: t0)
        let rows = LiveSeats.rows(round: PlannedRound(stage: .draft, round: 0, major: true), config: config,
                                  seats: SeatFiles(activities: ["draft-0-drafter-1": failed,
                                                                "draft-0-drafter-1-fallback": fallback,
                                                                "draft-0-drafter-10": stray]),
                                  now: t0.addingTimeInterval(110))
        XCTAssertEqual(rows.map(\.id), ["draft-0-drafter-0", "draft-0-drafter-1", "draft-0-drafter-2", "draft-0-drafter-10"],
                       "a run the config doesn't predict is still shown, after the expected seats")
        let seat = rows[1].model
        XCTAssertEqual(seat.glyph, .fallback)
        XCTAssertEqual(seat.identity, "claude → codex · gpt-6-sol")
        XCTAssertEqual(seat.headline, "Questioning whether offline replay can reorder check-ins")
        XCTAssertEqual(seat.elapsed, 30, "the fallback's own clock, not the failed attempt's")
    }

    /// A finished seat's row reads its own run's result.json — the fallback's, not the
    /// failed attempt's — before the round lands.
    func testFinishedSeatShowsItsOwnResult() {
        var failed = SeatActivity(harness: .claude, startedAt: t0)
        failed.finished = true; failed.error = "exited 1"
        var done = SeatActivity(harness: .codex, startedAt: t0.addingTimeInterval(80))
        done.finished = true
        let rows = LiveSeats.rows(round: PlannedRound(stage: .draft, round: 0, major: true), config: config,
                                  seats: SeatFiles(activities: ["draft-0-drafter-1": failed, "draft-0-drafter-1-fallback": done],
                                                   results: ["draft-0-drafter-1-fallback": SeatResult(kind: .draft, linesAdded: 212)]),
                                  now: t0.addingTimeInterval(300))
        XCTAssertEqual(rows[1].model.result, "Draft · 212 lines")
    }
}
