import XCTest
import IntakeKit
@testable import FlightDeck

/// `LiveSeats` decides which seat rows a shaping round shows and which run speaks for each —
/// the live card's only logic that isn't already `SeatRowModel`'s.
final class LiveSeatsTests: XCTestCase {
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")
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

    /// A cross-check round runs a second reviewer between the usual two, so the seat list has
    /// three rows instead of two, and a non-cross-check round of the same stage keeps its own.
    func testCrossCheckRefineListsTheCrossCheckAgent() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        cfg.crossCheck = .firstAndLast
        let rows = LiveSeats.expected(PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true), config: cfg)
        XCTAssertEqual(rows.map(\.base), ["refine-1-reviewer", "refine-1-crossReviewer", "refine-1-integrator"])
        XCTAssertEqual(rows[1].requested?.choice.agent, .claude)
        XCTAssertEqual(LiveSeats.expected(PlannedRound(stage: .refine, round: 2, major: false), config: cfg).count, 2)
    }

    /// A drafter that fell back is ONE row, keyed by its seat, drawn from the newest attempt — and
    /// drafter 10's runs never land on drafter 1's row.
    func testFallbackRunSpeaksForItsSeat() {
        var failed = SeatActivity(agent: .claude, startedAt: t0)
        failed.finished = true; failed.error = "exited 1"
        var fallback = SeatActivity(agent: .codex, startedAt: t0.addingTimeInterval(80))
        fallback.headline = "Questioning whether offline replay can reorder check-ins"
        fallback.lastEventAt = t0.addingTimeInterval(100)
        let stray = SeatActivity(agent: .codex, startedAt: t0)
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
        var failed = SeatActivity(agent: .claude, startedAt: t0)
        failed.finished = true; failed.error = "exited 1"
        var done = SeatActivity(agent: .codex, startedAt: t0.addingTimeInterval(80))
        done.finished = true
        let rows = LiveSeats.rows(round: PlannedRound(stage: .draft, round: 0, major: true), config: config,
                                  seats: SeatFiles(activities: ["draft-0-drafter-1": failed, "draft-0-drafter-1-fallback": done],
                                                   results: ["draft-0-drafter-1-fallback": SeatResult(kind: .draft, linesAdded: 212)]),
                                  now: t0.addingTimeInterval(300))
        XCTAssertEqual(rows[1].model.result, "Draft · 212 lines")
    }

    /// A pending start's seat files are the PREVIOUS round's, still on disk: the card, the LCD
    /// and the seat inspector all draw none of them (`LiveSeats.files`). The inspector once read
    /// them straight, and said "Running" beside a row that said the seat had not started.
    func testPendingStartHidesTheOldSeatFilesEverywhere() {
        var files = SeatFiles()
        files.activities["refine-2-reviewer"] = SeatActivity(agent: .codex, startedAt: t0)
        XCTAssertEqual(LiveSeats.files(files, pending: nil).activities.count, 1)
        XCTAssertTrue(LiveSeats.files(files, pending: PendingStart(kind: .round(nil), since: t0)).activities.isEmpty)
    }

    /// The seat inspector reads the row's held headline (`DwellBank.peek`) rather than the raw
    /// one, so the two never disagree mid-dwell — and peeking never drops the other seats'
    /// schedulers, as `settle` over a one-seat list would.
    @MainActor
    func testPeekShowsTheRowsHeldValueWithoutDisturbingIt() {
        let bank = DwellBank()
        func seat(_ id: String, _ headline: String) -> LiveSeat {
            var model = LiveSeats.rows(round: PlannedRound(stage: .refine, round: 2, major: false), config: config,
                                       seats: SeatFiles(), now: t0)[0].model
            model.headline = headline
            return LiveSeat(id: id, model: model)
        }
        _ = bank.settle([seat("a", "Reading"), seat("b", "Writing")])
        _ = bank.settle([seat("a", "Editing"), seat("b", "Writing")])
        XCTAssertEqual(bank.peek(seat("a", "Editing")).model.headline, "Reading", "held for its dwell, as the row is")
        XCTAssertEqual(bank.peek(seat("c", "New")).model.headline, "New", "an unknown seat shows as it is")
        XCTAssertEqual(bank.settle([seat("a", "Editing"), seat("b", "Writing")]).map(\.model.headline),
                       ["Reading", "Writing"], "peek left both schedulers in place")
    }
}
