import XCTest
import IntakeKit
@testable import FlightDeck

final class ShapingModelTests: XCTestCase {
    private let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")

    /// Feature plan: drafts, synthesis, R1–R3 (R3 major), encode, P1–P2 (P2 major).
    private func featureIntake() throws -> Intake {
        var intake = Intake(projectPath: "/tmp/project", intent: "per-project font size")
        intake.state = .shaping
        intake.roundConfig = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        return intake
    }

    private func cp(_ id: Int, _ stage: Stage, _ round: Int = 0, major: Bool, _ record: RoundRecord = RoundRecord()) -> Checkpoint {
        Checkpoint(id: id, parent: id > 1 ? id - 1 : nil, stage: stage, round: round, major: major,
                   createdAt: Date(timeIntervalSince1970: 1_790_000_000), record: record)
    }

    /// Paused after refinement round 2 — the mockup's worked example.
    private func pausedAtR2(status: RunnerStatus = .paused) -> Tape {
        Tape(checkpoints: [
            cp(1, .draft, major: true),
            cp(2, .synthesis, major: true),
            cp(3, .refine, 1, major: false, RoundRecord(changeCount: 41, linesAdded: 620, linesRemoved: 180,
                                                        tally: VerdictTally(agree: 33, somewhat: 6, disagree: 2))),
            cp(4, .refine, 2, major: false, RoundRecord(changeCount: 14, linesAdded: 140, linesRemoved: 95,
                                                        tally: VerdictTally(agree: 12, somewhat: 2, disagree: 0))),
        ], status: status)
    }

    // MARK: - Transport

    /// Every status, spelled out: a status whose button set drifted would either offer a
    /// command the runner ignores (⏯ while running just re-targets mid-round) or hide the one
    /// the human needs (retry after a failure).
    func testEnabledButtonsForEveryStatus() throws {
        let intake = try featureIntake()
        func enabled(_ status: RunnerStatus) -> Set<TransportButton> {
            ShapingModel(intake: intake, tape: pausedAtR2(status: status)).enabled
        }
        XCTAssertEqual(enabled(.running), [.pause, .stop, .annotate])
        XCTAssertEqual(enabled(.paused), [.step, .nextMajor, .toReview, .extend, .annotate])
        XCTAssertEqual(enabled(.idle), [.step, .nextMajor, .toReview, .extend, .annotate])
        XCTAssertEqual(enabled(.stopped), [.step, .nextMajor, .toReview, .extend, .annotate])
        XCTAssertEqual(enabled(.failed), [.step, .toReview, .annotate])
        XCTAssertEqual(enabled(.reachedReview), [])
    }

    /// ＋ only offers a stage the tape hasn't finished: `TapePlanner` ignores an extend for a
    /// stage the head is already past, so the menu item would be a silent no-op.
    func testExtendOffersOnlyUnfinishedStagesTheConfigRuns() throws {
        let intake = try featureIntake()
        XCTAssertEqual(ShapingModel(intake: intake, tape: pausedAtR2()).extendStages, [.refine, .polish])
        var encoded = pausedAtR2()
        encoded.checkpoints.append(cp(5, .refine, 3, major: true))
        encoded.checkpoints.append(cp(6, .encode, major: true))
        XCTAssertEqual(ShapingModel(intake: intake, tape: encoded).extendStages, [.polish])

        var sketch = intake
        sketch.roundConfig = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: .defaults))
        XCTAssertEqual(ShapingModel(intake: sketch, tape: pausedAtR2()).extendStages, [.refine],
                       "sketch has no polisher, so +1 polish round would never run")
    }

    // MARK: - Status line

    func testStatusLinePausedMidRefinement() throws {
        let model = ShapingModel(intake: try featureIntake(), tape: pausedAtR2())
        XCTAssertEqual(model.statusLine,
                       "Paused at R2 · 14 changes (R1: 41) — ⏯ runs R3 · ⏭ runs R3 → plan final · ⏩ runs to review")
    }

    func testStatusLineSpansTheRoundsToTheNextMajor() throws {
        var tape = pausedAtR2()
        tape.checkpoints.removeLast()
        XCTAssertEqual(ShapingModel(intake: try featureIntake(), tape: tape).statusLine,
                       "Paused at R1 · 41 changes — ⏯ runs R2 · ⏭ runs R2–R3 → plan final · ⏩ runs to review")
    }

    func testStatusLineNotStarted() throws {
        XCTAssertEqual(ShapingModel(intake: try featureIntake(), tape: .empty).statusLine,
                       "Not started — ⏯ runs drafts · ⏭ runs drafts · ⏩ runs to review")
    }

    func testStatusLineRunningNamesTheRoundAndWhereItStops() throws {
        var tape = pausedAtR2(status: .running)
        tape.roundInProgress = PlannedRound(stage: .refine, round: 3, major: true)
        tape.target = .review
        XCTAssertEqual(ShapingModel(intake: try featureIntake(), tape: tape).statusLine, "Running R3 · runs to review")
        tape.target = .nextMajor
        XCTAssertEqual(ShapingModel(intake: try featureIntake(), tape: tape).statusLine, "Running R3 · stops at plan final")
        tape.target = .nextMinor
        XCTAssertEqual(ShapingModel(intake: try featureIntake(), tape: tape).statusLine, "Running R3 · stops after R3")
        tape.target = .none
        XCTAssertEqual(ShapingModel(intake: try featureIntake(), tape: tape).statusLine, "Running R3 · pausing after R3")
    }

    func testStatusLineFailedOffersRetry() throws {
        var tape = pausedAtR2(status: .failed)
        tape.pauseDiagnosis = Diagnosis(category: .rateLimited, detail: "429 from codex", action: "Wait 5 minutes, then retry")
        XCTAssertEqual(ShapingModel(intake: try featureIntake(), tape: tape).statusLine,
                       "R3 failed — ⏯ retries R3 · ⏩ runs to review")
    }

    func testStatusLineReachedReview() throws {
        var tape = pausedAtR2(status: .reachedReview)
        tape.checkpoints.append(cp(5, .refine, 3, major: true))
        XCTAssertEqual(ShapingModel(intake: try featureIntake(), tape: tape).statusLine, "Reached release review")
    }

    // MARK: - Strip

    /// Done markers are the tape's checkpoints; pending ones are what `TapePlanner` would run
    /// next, so the strip shows the whole road to review with the playhead part-way along it.
    func testStagesCoverDoneAndPlannedRounds() throws {
        let model = ShapingModel(intake: try featureIntake(), tape: pausedAtR2())
        XCTAssertEqual(model.stages.map(\.label), ["drafts", "synthesis", "R1", "R2", "R3", "encoded", "P1", "P2"])
        XCTAssertEqual(model.stages.map(\.done), [true, true, true, true, false, false, false, false])
        XCTAssertEqual(model.stages.map(\.major), [true, true, false, false, true, true, false, true])
        XCTAssertEqual(model.stages.map(\.checkpointID), [1, 2, 3, 4, nil, nil, nil, nil])
        XCTAssertEqual(model.stages.map(\.order), Array(0..<8))
        XCTAssertEqual(model.playheadIndex, 3)
    }

    func testStagesMarkTheRoundInProgress() throws {
        var tape = pausedAtR2(status: .running)
        tape.roundInProgress = PlannedRound(stage: .refine, round: 3, major: true)
        let model = ShapingModel(intake: try featureIntake(), tape: tape)
        XCTAssertEqual(model.stages.filter(\.inProgress).map(\.label), ["R3"])
    }

    // MARK: - Round cards

    func testRoundCardSummarisesTheRecord() throws {
        let card = try XCTUnwrap(ShapingModel(intake: try featureIntake(), tape: pausedAtR2()).roundCards.first { $0.checkpointID == 3 })
        XCTAssertEqual(card.title, "R1")
        XCTAssertEqual(card.changes, "41 changes")
        XCTAssertEqual(card.lines, "+620/−180")
        XCTAssertEqual(card.tally, "agreed 33 · somewhat 6 · declined 2", "the seat row's wording, so the two never disagree")
    }

    /// The record's `note` (reviewer summary, integrator notes, a fallback remark) and the
    /// sections a round touched were recorded and never shown — the card is where the human
    /// decides whether another round is worth it.
    func testRoundCardShowsTheNoteAndTheSectionsChanged() throws {
        var tape = pausedAtR2()
        tape.checkpoints[2].record.note = "Tightened the rollout.\n\nApplied 39 of 41."
        tape.checkpoints[2].record.sectionsChanged = ["## Scope", "## Rollout", "## Risks", "## Testing"]
        tape.checkpoints[3].record.sectionsChanged = ["## Scope"]
        let cards = ShapingModel(intake: try featureIntake(), tape: tape).roundCards
        let r1 = try XCTUnwrap(cards.first { $0.checkpointID == 3 })
        XCTAssertEqual(r1.note, "Tightened the rollout.\n\nApplied 39 of 41.")
        XCTAssertEqual(r1.sections, "Scope, Rollout, Risks +1")
        let r2 = try XCTUnwrap(cards.first { $0.checkpointID == 4 })
        XCTAssertNil(r2.note)
        XCTAssertEqual(r2.sections, "Scope")
        XCTAssertNil(try XCTUnwrap(cards.first { $0.checkpointID == 1 }).sections)
    }

    func testRoundCardSlotBadgesCarryTheDiagnosis() throws {
        var tape = pausedAtR2()
        tape.checkpoints[0].record.slots = [
            SlotOutcome(role: "drafter", persona: .arbiter, used: codex, requested: codex, status: .ok),
            SlotOutcome(role: "drafter", persona: .realist, used: codex, requested: claude, status: .substituted,
                        diagnosis: Diagnosis(category: .authExpired, detail: "claude login expired",
                                             action: "Run `claude /login`")),
            SlotOutcome(role: "drafter", persona: .coverage, used: claude, requested: claude, status: .failed,
                        diagnosis: Diagnosis(category: .timeout, detail: "no output for 20 minutes", action: "Retry the round")),
        ]
        let card = try XCTUnwrap(ShapingModel(intake: try featureIntake(), tape: tape).roundCards.first)
        XCTAssertEqual(card.title, "drafts")
        XCTAssertEqual(card.changes, "2 drafts", "the drafters that produced one — the failed coverage seat did not")
        XCTAssertNil(card.lines, "a draft is written from nothing, so +N/−0 against nothing says nothing")
        XCTAssertNil(card.tally)
        XCTAssertEqual(card.slots.map(\.status), [.ok, .substituted, .failed])
        XCTAssertEqual(card.slots.map(\.label), ["drafter · arbiter", "drafter · realist", "drafter · coverage"])
        XCTAssertEqual(card.slots[0].diagnosis, nil)
        XCTAssertEqual(card.slots[1].diagnosis,
                       "Ran codex gpt-6-sol instead of claude opus — auth expired: claude login expired. Run `claude /login`")
        XCTAssertEqual(card.slots[2].diagnosis,
                       "Failed — timed out: no output for 20 minutes. Retry the round")
    }

    func testOneRoundCardPerCheckpointInTapeOrder() throws {
        let cards = ShapingModel(intake: try featureIntake(), tape: pausedAtR2()).roundCards
        XCTAssertEqual(cards.map(\.checkpointID), [1, 2, 3, 4])
        XCTAssertEqual(cards.map(\.title), ["drafts", "synthesis", "R1", "R2"])
    }

    // MARK: - Pause banner

    func testPauseBannerFromAFailedTape() throws {
        var tape = pausedAtR2(status: .failed)
        tape.pauseDiagnosis = Diagnosis(category: .rateLimited, detail: "429 from codex", action: "Wait 5 minutes, then retry")
        let banner = try XCTUnwrap(ShapingModel(intake: try featureIntake(), tape: tape).pauseBanner)
        XCTAssertEqual(banner.title, "Rate limited: 429 from codex")
        XCTAssertEqual(banner.action, "Wait 5 minutes, then retry")
    }

    func testNoPauseBannerWithoutADiagnosis() throws {
        XCTAssertNil(ShapingModel(intake: try featureIntake(), tape: pausedAtR2()).pauseBanner)
    }

    // MARK: - Pill

    func testPillLabelFollowsTheRunner() {
        XCTAssertEqual(ShapingModel.pillLabel(for: .empty), "shaping")
        XCTAssertEqual(ShapingModel.pillLabel(for: pausedAtR2()), "paused · R2")
        XCTAssertEqual(ShapingModel.pillLabel(for: pausedAtR2(status: .idle)), "paused · R2")
        XCTAssertEqual(ShapingModel.pillLabel(for: pausedAtR2(status: .stopped)), "stopped · R2")
        XCTAssertEqual(ShapingModel.pillLabel(for: pausedAtR2(status: .reachedReview)), "review ready")
        var running = pausedAtR2(status: .running)
        running.roundInProgress = PlannedRound(stage: .refine, round: 3, major: true)
        XCTAssertEqual(ShapingModel.pillLabel(for: running), "running · R3")
        var failed = running
        failed.status = .failed
        XCTAssertEqual(ShapingModel.pillLabel(for: failed), "failed · R3")
    }

    // MARK: - Plan viewer

    private func files(_ map: [String: String]) -> (Int, String) -> Data? {
        { id, path in map["\(id)/\(path)"].map { Data($0.utf8) } }
    }

    func testPlanSourcePrefersPlanThenFallsBackToTheFirstDraft() {
        let load = files(["1/drafts/0.md": "draft zero", "2/plan.md": "synthesised", "2/drafts/0.md": "stale"])
        let tape = pausedAtR2()
        XCTAssertEqual(ShapingModel.planText(checkpoint: 2, in: tape, loadFile: load), "synthesised")
        XCTAssertEqual(ShapingModel.planText(checkpoint: 1, in: tape, loadFile: load), "draft zero")
        XCTAssertNil(ShapingModel.planText(checkpoint: 3, in: tape, loadFile: load))
    }

    /// A draft round writes only the drafters that succeeded, so with drafter 0 failed there is
    /// no `drafts/0.md` — the lowest-numbered draft that exists is the plan, the same one
    /// synthesis and Sketch's refine build on.
    func testPlanSourceFallsBackToTheLowestNumberedDraft() {
        var tape = pausedAtR2()
        tape.checkpoints[0].record.slots = [
            SlotOutcome(role: "drafter", persona: .arbiter, used: codex, requested: codex, status: .failed),
            SlotOutcome(role: "drafter", persona: .realist, used: codex, requested: codex, status: .ok),
            SlotOutcome(role: "drafter", persona: .coverage, used: claude, requested: claude, status: .ok),
        ]
        let load = files(["1/drafts/1.md": "draft one", "1/drafts/2.md": "draft two"])
        XCTAssertEqual(ShapingModel.planText(checkpoint: 1, in: tape, loadFile: load), "draft one")
    }

    /// The diff base is the nearest EARLIER checkpoint that has a plan — an encode checkpoint
    /// (change set only) between two plans must be skipped, not diffed against as empty.
    func testDiffBaseSkipsCheckpointsWithoutAPlan() {
        let tape = pausedAtR2()
        let load = files(["1/drafts/0.md": "a\nb\n", "2/plan.md": "a\nB\n", "4/plan.md": "a\nB\nc\n"])
        XCTAssertEqual(ShapingModel.previousPlanCheckpoint(before: 4, in: tape, loadFile: load), 2)
        XCTAssertEqual(ShapingModel.previousPlanCheckpoint(before: 2, in: tape, loadFile: load), 1)
        XCTAssertNil(ShapingModel.previousPlanCheckpoint(before: 1, in: tape, loadFile: load))
        XCTAssertEqual(ShapingModel.viewerText(.diff, checkpoint: 4, tape: tape, loadFile: load),
                       PlanMetrics.unifiedDiff(from: "a\nB\n", to: "a\nB\nc\n"))
        XCTAssertEqual(ShapingModel.viewerText(.diff, checkpoint: 1, tape: tape, loadFile: load),
                       "No earlier plan to compare with.")
    }

    func testViewerTextForMissingFiles() {
        let tape = pausedAtR2()
        let load = files([:])
        XCTAssertEqual(ShapingModel.viewerText(.plan, checkpoint: 3, tape: tape, loadFile: load), "No plan at this checkpoint.")
        XCTAssertEqual(ShapingModel.viewerText(.changeSet, checkpoint: 3, tape: tape, loadFile: load),
                       "No change set at this checkpoint.")
    }

    /// The viewer memoizes on this key, so it must change exactly when the text could: a new
    /// head (a following viewer moves with it), a new selection, a new mode — and NOT on the
    /// runner churn (status, heartbeat, queued notes) that re-renders the view constantly.
    func testViewerKeyChangesOnlyWithWhatTheTextDependsOn() {
        let tape = pausedAtR2()
        let key = ShapingModel.viewerKey(selected: nil, mode: .plan, tape: tape)
        XCTAssertEqual(key.checkpoint, 4, "no selection follows the head")

        var churned = tape
        churned.status = .running
        churned.heartbeat = Date(timeIntervalSince1970: 1_790_000_100)
        churned.pendingNotes = [PlanNote(note: "no plugin system")]
        XCTAssertEqual(ShapingModel.viewerKey(selected: nil, mode: .plan, tape: churned), key)

        var advanced = tape
        advanced.checkpoints.append(cp(5, .refine, 3, major: true))
        XCTAssertNotEqual(ShapingModel.viewerKey(selected: nil, mode: .plan, tape: advanced), key)
        XCTAssertEqual(ShapingModel.viewerKey(selected: nil, mode: .plan, tape: advanced).checkpoint, 5)
        XCTAssertNotEqual(ShapingModel.viewerKey(selected: 3, mode: .plan, tape: tape), key)
        XCTAssertNotEqual(ShapingModel.viewerKey(selected: nil, mode: .diff, tape: tape), key)
    }

    func testViewerContentFollowsTheKey() {
        let tape = pausedAtR2()
        let load = files(["2/plan.md": "a\n", "4/plan.md": "a\nb\n"])
        XCTAssertEqual(ShapingModel.viewerContent(ShapingModel.viewerKey(selected: nil, mode: .diff, tape: tape),
                                                  tape: tape, loadFile: load),
                       PlanMetrics.unifiedDiff(from: "a\n", to: "a\nb\n"))
        XCTAssertEqual(ShapingModel.viewerContent(ShapingModel.viewerKey(selected: 2, mode: .plan, tape: tape),
                                                  tape: tape, loadFile: load), "a\n")
        XCTAssertEqual(ShapingModel.viewerContent(ShapingModel.viewerKey(selected: nil, mode: .plan, tape: .empty),
                                                  tape: .empty, loadFile: load), "No rounds yet.")
    }

    func testChangeSetIsListedReadably() throws {
        let set = ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 0), ops: [
            .createBead(NewBead(tempId: "t1", title: "Store font size per project", description: "d")),
            .addEdge(from: .new("t1"), to: .existing("fd-12"), kind: .blocks),
            .editBead(id: "fd-9", set: FieldSet(title: "Resolve font at surface init", priority: 1),
                      pre: Precondition(status: "open", assignee: nil), delivery: nil),
            .reopen(id: "fd-3", reason: "regressed", pre: Precondition(status: "closed", assignee: nil)),
            .followUp(tempId: "t2", of: "fd-4", title: "Migrate prefs", description: "d",
                      pre: Precondition(status: "closed", assignee: nil)),
        ])
        let data = try set.encoded()
        let text = ShapingModel.viewerText(.changeSet, checkpoint: 6, tape: pausedAtR2(),
                                           loadFile: { id, path in id == 6 && path == "changeset.json" ? data : nil })
        XCTAssertEqual(text, """
            1. New task new:t1 — Store font size per project
            2. Edge new:t1 → fd-12 (blocks)
            3. Edit fd-9 — title: Resolve font at surface init; priority: 1
            4. Reopen fd-3 — regressed
            5. Follow-up new:t2 on fd-4 — Migrate prefs
            """)
    }

    func testUnreadableChangeSetSaysSo() {
        let text = ShapingModel.viewerText(.changeSet, checkpoint: 6, tape: pausedAtR2(),
                                           loadFile: { _, _ in Data("not json".utf8) })
        XCTAssertEqual(text, "The change set at this checkpoint couldn't be read.")
    }
}
