import XCTest
import IntakeKit
@testable import FlightDeck

/// `SeatRowModel.make` turns whatever the engine has written for one seat — its live
/// `SeatActivity`, its `run.json`, and (once the round lands) its `SlotOutcome` and the round's
/// `RoundRecord` — into the one status row the departures board shows (spec §6). Every case here
/// is built from real shapes: `codex`/`claude` defaults come straight from `TriageSettings`, and
/// the footprint and cost fixtures are copied from a live run's `activity.json`
/// (`runs/synthesis-0-synthesizer` and `runs/synthesis-0-integrator` under a real intake).
final class SeatRowModelTests: XCTestCase {
    private let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")
    private let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private func activity(_ harness: Harness, startedAt: Date, headline: String? = nil, action: ActivityAction? = nil,
                          footprint: [String: Int] = [:], steps: ActivitySteps? = nil, inputTokens: Int? = nil,
                          outputTokens: Int? = nil, rateLimitedAt: Date? = nil, lastEventAt: Date? = nil,
                          costUSD: Double? = nil, finished: Bool = false, error: String? = nil) -> SeatActivity {
        var a = SeatActivity(harness: harness, startedAt: startedAt)
        a.headline = headline; a.action = action; a.footprint = footprint; a.steps = steps
        a.inputTokens = inputTokens; a.outputTokens = outputTokens; a.rateLimitedAt = rateLimitedAt
        a.lastEventAt = lastEventAt; a.costUSD = costUSD; a.finished = finished; a.error = error
        return a
    }

    // MARK: - Queued

    func testQueuedBeforeAnyActivity() {
        let row = SeatRowModel.make(run: "draft-0-drafter-0", slot: nil, requested: Slot(codex, persona: .arbiter),
                                    activity: nil, record: nil, roundRecord: nil, now: epoch)
        XCTAssertEqual(row.glyph, .queued)
        XCTAssertEqual(row.role, "arbiter")
        XCTAssertEqual(row.identity, "codex · gpt-6-sol · high", "what it WILL run is already known from the config")
        XCTAssertNil(row.headline)
        XCTAssertNil(row.action)
        XCTAssertEqual(row.elapsed, 0)
        XCTAssertNil(row.exception)
        XCTAssertNil(row.result)
        XCTAssertNil(row.cost)
        XCTAssertEqual(row.footprint.count, 0)
    }

    // MARK: - Running

    func testRunningHeadlineAndAction() {
        let a = activity(.codex, startedAt: epoch, headline: "Preparing delivery-sequence insertion",
                         action: ActivityAction(verb: "Reading", object: "Sources/App.swift"))
        let row = SeatRowModel.make(run: "draft-0-drafter-1", slot: nil, requested: Slot(codex),
                                    activity: a, record: nil, roundRecord: nil, now: epoch.addingTimeInterval(12))
        XCTAssertEqual(row.glyph, .running)
        XCTAssertEqual(row.role, "drafter", "no persona set, so the run name's own role wins")
        XCTAssertEqual(row.headline, "Preparing delivery-sequence insertion")
        XCTAssertEqual(row.action, "Reading Sources/App.swift")
        XCTAssertEqual(row.elapsed, 12)
        XCTAssertNil(row.exception)
    }

    func testMissingHeadlineUsesAction() {
        let a = activity(.claude, startedAt: epoch, action: ActivityAction(verb: "Editing", object: "plan.md"))
        let row = SeatRowModel.make(run: "synthesis-0-integrator", slot: nil, requested: nil,
                                    activity: a, record: nil, roundRecord: nil, now: epoch)
        XCTAssertEqual(row.headline, "Editing plan.md", "the primary line falls back to the action when there's no reasoning yet")
        XCTAssertEqual(row.action, "Editing plan.md")
        XCTAssertEqual(row.role, "integrator", "no requested Slot at all — the run name is the only source")
    }

    // MARK: - Finished via run.json even when activity.json lags

    func testFinishedWhenRunJSONExitedEvenIfActivityUnfinished() {
        let a = activity(.codex, startedAt: epoch, finished: false) // the stream never got its closing line
        let record = RunRecord(started: epoch, finished: epoch.addingTimeInterval(40), exitCode: 0)
        let row = SeatRowModel.make(run: "encode-0-encoder", slot: nil, requested: Slot(codex),
                                    activity: a, record: record, roundRecord: nil, now: epoch.addingTimeInterval(200))
        XCTAssertEqual(row.glyph, .done, "run.json's clean exit outranks activity.json's stale unfinished flag")
        XCTAssertEqual(row.elapsed, 40, "frozen at the recorded finish, not still counting up to `now`")
        XCTAssertNil(row.exception)
    }

    // MARK: - Quiet / stalled

    func testQuietAndStalledThresholdsWithInjectedClock() {
        let a = activity(.codex, startedAt: epoch, action: ActivityAction(verb: "Running", object: "swift build"),
                         lastEventAt: epoch)
        let quiet = SeatRowModel.make(run: "refine-1-reviewer", slot: nil, requested: Slot(codex), activity: a,
                                      record: nil, roundRecord: nil, now: epoch.addingTimeInterval(31))
        XCTAssertEqual(quiet.exception, .quiet(31))

        let stalled = SeatRowModel.make(run: "refine-1-reviewer", slot: nil, requested: Slot(codex), activity: a,
                                        record: nil, roundRecord: nil, now: epoch.addingTimeInterval(105))
        XCTAssertEqual(stalled.exception, .stalled(105, last: "Running swift build"))

        let stillFresh = SeatRowModel.make(run: "refine-1-reviewer", slot: nil, requested: Slot(codex), activity: a,
                                           record: nil, roundRecord: nil, now: epoch.addingTimeInterval(29))
        XCTAssertNil(stillFresh.exception, "under both thresholds — running clean")
    }

    // MARK: - Rate limited

    func testRateLimited() {
        let a = activity(.claude, startedAt: epoch, rateLimitedAt: epoch.addingTimeInterval(10), lastEventAt: epoch)
        let row = SeatRowModel.make(run: "refine-1-reviewer", slot: nil, requested: Slot(claude), activity: a,
                                    record: nil, roundRecord: nil, now: epoch.addingTimeInterval(52))
        XCTAssertEqual(row.exception, .rateLimited(42), "counted from when the limit hit, not from the seat's start")
        XCTAssertEqual(row.glyph, .running, "rate limiting decorates the row, it isn't its own glyph")
    }

    // MARK: - Fallback

    func testFallbackIdentityAndReason() {
        let slot = Slot(claude, fallback: codex)
        let a = activity(.codex, startedAt: epoch) // the fallback attempt, already under way
        let row = SeatRowModel.make(run: "draft-0-drafter-0-fallback", slot: nil, requested: slot, activity: a,
                                    record: nil, roundRecord: nil, now: epoch.addingTimeInterval(5))
        XCTAssertEqual(row.identity, "claude → codex · gpt-6-sol")
        XCTAssertEqual(row.glyph, .fallback)
        XCTAssertEqual(row.exception, .fallback("fell back to codex"),
                       "no diagnosis exists for a fallback that's still running (or that succeeded) — never invent one")
    }

    func testFallbackReasonIncludesDiagnosisWhenTheEngineHasOne() {
        // `RoundExecutor.draft()` only ever attaches a diagnosis to a fallback attempt that
        // failed too (status .failed, `used` the fallback choice) — a successful `.substituted`
        // fallback never carries one. This seat row must still surface it when it's there, even
        // though `make` never fabricates one for the ordinary successful-fallback case.
        let outcome = SlotOutcome(role: "drafter", used: codex, requested: claude, status: .failed,
                                  diagnosis: Diagnosis(category: .authExpired, detail: "claude 401", action: "Re-authenticate."))
        let a = activity(.codex, startedAt: epoch, finished: true)
        let row = SeatRowModel.make(run: "draft-0-drafter-0-fallback", slot: outcome, requested: Slot(claude, fallback: codex),
                                    activity: a, record: nil, roundRecord: nil, now: epoch)
        XCTAssertEqual(row.glyph, .failed, "the fallback attempt itself still failed")
        XCTAssertEqual(row.identity, "claude → codex · gpt-6-sol")
    }

    // MARK: - Failed

    func testFailedReason() {
        let a = activity(.codex, startedAt: epoch, finished: true, error: "turn failed")
        let row = SeatRowModel.make(run: "refine-1-reviewer", slot: nil, requested: Slot(codex), activity: a,
                                    record: nil, roundRecord: nil, now: epoch)
        XCTAssertEqual(row.glyph, .failed)
        XCTAssertEqual(row.exception, .failed("turn failed"))

        // No error on the stream, but run.json shows a non-zero exit.
        let quiet = activity(.codex, startedAt: epoch, finished: false)
        let crashed = RunRecord(started: epoch, finished: epoch.addingTimeInterval(3), exitCode: 137)
        let row2 = SeatRowModel.make(run: "refine-1-reviewer", slot: nil, requested: Slot(codex), activity: quiet,
                                     record: crashed, roundRecord: nil, now: epoch.addingTimeInterval(10))
        XCTAssertEqual(row2.exception, .failed("exited 137"))
    }

    // MARK: - Clock skew

    func testNoNegativeElapsedOnClockSkew() {
        let a = activity(.codex, startedAt: epoch)
        let row = SeatRowModel.make(run: "draft-0-drafter-0", slot: nil, requested: Slot(codex), activity: a,
                                    record: nil, roundRecord: nil, now: epoch.addingTimeInterval(-2),
                                    thresholds: .default)
        XCTAssertEqual(row.elapsed, 0)
    }

    // MARK: - Footprint

    func testFootprintTopFourPlusMore() {
        // Shaped after a real run's footprint, widened past four buckets: "." (project root)
        // and "work"/"drafts" are FD's own scratch and the intake's own work dir.
        let raw = ["Dispatch": 7, "Core": 4, "docs": 2, "Tests": 2, "Scripts": 1, ".": 3, "work": 2, "drafts": 4,
                   "checkpoints": 1]
        let a = activity(.codex, startedAt: epoch, footprint: raw)
        let row = SeatRowModel.make(run: "draft-0-drafter-0", slot: nil, requested: Slot(codex), activity: a,
                                    record: nil, roundRecord: nil, now: epoch)
        let dirs = row.footprint.map(\.dir)
        XCTAssertEqual(dirs, ["Dispatch", "Core", "root", "docs", "+2"])
        XCTAssertEqual(row.footprint.map(\.count), [7, 4, 3, 2, 3], "the +2 chip's count is Tests(2) + Scripts(1)")
    }

    func testFootprintUnderFourHasNoOverflowChip() {
        let a = activity(.claude, startedAt: epoch, footprint: ["work": 2, "workspace": 1])
        let row = SeatRowModel.make(run: "synthesis-0-integrator", slot: nil, requested: nil, activity: a,
                                    record: nil, roundRecord: nil, now: epoch)
        XCTAssertEqual(row.footprint.map(\.dir), ["workspace"], "\"work\" is the intake's own scratch, dropped entirely")
    }

    // MARK: - Cost

    func testCostOnlyWhenReported() {
        let stillRunning = activity(.claude, startedAt: epoch, costUSD: 0.487, finished: false)
        XCTAssertNil(SeatRowModel.make(run: "synthesis-0-integrator", slot: nil, requested: nil, activity: stillRunning,
                                       record: nil, roundRecord: nil, now: epoch).cost,
                    "cost only ever lands with claude's final result, alongside `finished`")

        let claudeDone = activity(.claude, startedAt: epoch, costUSD: 0.487, finished: true)
        XCTAssertEqual(SeatRowModel.make(run: "synthesis-0-integrator", slot: nil, requested: nil, activity: claudeDone,
                                         record: nil, roundRecord: nil, now: epoch).cost, 0.487)

        let codexDone = activity(.codex, startedAt: epoch, finished: true) // codex never reports one
        XCTAssertNil(SeatRowModel.make(run: "synthesis-0-synthesizer", slot: nil, requested: nil, activity: codexDone,
                                       record: nil, roundRecord: nil, now: epoch).cost)
    }

    // MARK: - Result strings

    func testResultStrings() {
        let finishedActivity = activity(.codex, startedAt: epoch, finished: true)

        // Reviewer: proposed changes + the sections they touched.
        let reviewRecord = RoundRecord(changeCount: 14, sectionsChanged: ["## 2. Scope", "## 4. Rollout", "## 7. Risks"])
        let reviewRow = SeatRowModel.make(run: "refine-1-reviewer", slot: nil, requested: Slot(codex),
                                          activity: finishedActivity, record: nil, roundRecord: reviewRecord, now: epoch)
        XCTAssertEqual(reviewRow.result, "14 changes across §2 §4 §7")

        // Synthesizer reads the same way.
        let synthRow = SeatRowModel.make(run: "synthesis-0-synthesizer", slot: nil, requested: nil,
                                         activity: finishedActivity, record: nil, roundRecord: reviewRecord, now: epoch)
        XCTAssertEqual(synthRow.result, "14 changes across §2 §4 §7")

        // Zero proposed changes reads as a sentence, not "0 changes".
        let quietRound = RoundRecord(changeCount: 0)
        let quietRow = SeatRowModel.make(run: "refine-2-reviewer", slot: nil, requested: Slot(codex),
                                         activity: finishedActivity, record: nil, roundRecord: quietRound, now: epoch)
        XCTAssertEqual(quietRow.result, "No changes proposed")

        // Integrator: the tally, spelled out exactly as spec §6's example.
        let integrateRecord = RoundRecord(tally: VerdictTally(agree: 11, somewhat: 2, disagree: 1))
        let integratorRow = SeatRowModel.make(run: "refine-1-integrator", slot: nil, requested: nil,
                                              activity: finishedActivity, record: nil, roundRecord: integrateRecord, now: epoch)
        XCTAssertEqual(integratorRow.result, "agreed 11 · somewhat 2 · declined 1")

        // Polish/encode: never "bead".
        let polishRecord = RoundRecord(changeCount: 3)
        let polishRow = SeatRowModel.make(run: "polish-1-polisher", slot: nil, requested: nil,
                                          activity: finishedActivity, record: nil, roundRecord: polishRecord, now: epoch)
        XCTAssertEqual(polishRow.result, "3 task changes")
        XCTAssertFalse(polishRow.result?.lowercased().contains("bead") ?? false)

        let encodeRow = SeatRowModel.make(run: "encode-0-encoder", slot: nil, requested: nil,
                                          activity: finishedActivity, record: nil, roundRecord: RoundRecord(changeCount: 1),
                                          now: epoch)
        XCTAssertEqual(encodeRow.result, "1 task change")

        // A drafter has no round-level tally of its own.
        let draftRow = SeatRowModel.make(run: "draft-0-drafter-0", slot: nil, requested: Slot(codex),
                                         activity: finishedActivity, record: nil,
                                         roundRecord: RoundRecord(changeCount: nil), now: epoch)
        XCTAssertNil(draftRow.result)

        // No checkpoint yet (the round isn't fully landed) — no result, even though this seat's
        // own process already finished.
        let noRoundYet = SeatRowModel.make(run: "refine-1-reviewer", slot: nil, requested: Slot(codex),
                                           activity: finishedActivity, record: nil, roundRecord: nil, now: epoch)
        XCTAssertNil(noRoundYet.result)
    }

    // MARK: - DwellScheduler

    @MainActor
    func testDwellHoldsHeadline3sAndAction1_5s() {
        var now = epoch
        let scheduler = DwellScheduler(clock: { now })

        // First values on either channel show immediately — nothing to hold yet.
        var shown = scheduler.offer(headline: "H1", action: "A1")
        XCTAssertEqual(shown.headline, "H1")
        XCTAssertEqual(shown.action, "A1")

        // +1s: under both dwells — both hold.
        now = epoch.addingTimeInterval(1)
        shown = scheduler.offer(headline: "H2", action: "A2")
        XCTAssertEqual(shown.headline, "H1")
        XCTAssertEqual(shown.action, "A1")

        // +2s: action's 1.5 s dwell has elapsed (adopts the LATEST offered, "A2", never "A2"
        // twice) but headline's 3 s has not.
        now = epoch.addingTimeInterval(2)
        shown = scheduler.offer(headline: "H3", action: "A2")
        XCTAssertEqual(shown.headline, "H1")
        XCTAssertEqual(shown.action, "A2")

        // +3.5s from the start: headline's dwell has now elapsed. It jumps straight to "H4" —
        // "H2" and "H3" were coalesced away and never shown.
        now = epoch.addingTimeInterval(3.5)
        shown = scheduler.offer(headline: "H4", action: "A2")
        XCTAssertEqual(shown.headline, "H4")
        XCTAssertEqual(shown.action, "A2")
    }

    @MainActor
    func testDwellFirstOfferShowsBothChannelsWithNothingToHold() {
        let scheduler = DwellScheduler(clock: { self.epoch })
        let shown = scheduler.offer(headline: nil, action: "Reading Board.swift")
        XCTAssertNil(shown.headline)
        XCTAssertEqual(shown.action, "Reading Board.swift")
    }
}
