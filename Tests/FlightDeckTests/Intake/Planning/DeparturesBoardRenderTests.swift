import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `DeparturesBoard` offscreen in the four states of mock M2 — running Refine 2, paused
/// at Encode with R2 selected, failed, and done at Review — each at 1100 pt (full names) and
/// 700 pt (codes, with one card open). Skipped by default; set `FD_INTAKE_RENDER_DIR` to an
/// output directory to write `pui-board-<state>-<width>.png`. A picture rather than an assertion,
/// like `SplitFlapTextRenderTests`: the board can be looked at without launching the app
/// (AGENTS.md rule 2).
@MainActor
final class DeparturesBoardRenderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testRenderFourStatesAtTwoWidths() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_INTAKE_RENDER_DIR"] else {
            throw XCTSkip("set FD_INTAKE_RENDER_DIR to render the departures board PNGs")
        }
        var intake = Intake(projectPath: "/tmp/project", intent: "per-project font size")
        intake.state = .shaping
        let config = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        intake.roundConfig = config
        intake.exchanges = (0..<2).map { TriageExchange(questions: ["Q\($0)?"], answers: ["A\($0)"]) }

        let draft = cp(1, .draft, major: true, at: 0, started: -400)
        let syn = cp(2, .synthesis, major: true, at: 182)
        var rf1 = cp(3, .refine, 1, major: false, at: 470)
        rf1.record.annotations = [.legacy("tighten the rollout", index: 0)]
        // A landed crossReviewer slot (coverage spec §3) so the paused/failed/done states show
        // the board's "×2" mark on RF1 without depending on the planner's own crossCheck policy.
        let codexChoice = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
        rf1.record.slots = [SlotOutcome(role: "reviewer", used: codexChoice, requested: codexChoice, status: .ok),
                            SlotOutcome(role: "crossReviewer", used: codexChoice, requested: codexChoice, status: .ok),
                            SlotOutcome(role: "integrator", used: codexChoice, requested: codexChoice, status: .ok)]
        let rf2 = cp(4, .refine, 2, major: false, at: 758)
        let rf3 = cp(5, .refine, 3, major: true, at: 1000)
        let enc = cp(6, .encode, major: true, at: 1164)

        let running = Tape(checkpoints: [draft, syn, rf1], target: .nextMajor, status: .running,
                           // crossCheck: true so the running slot's live seat list carries the
                           // cross-check agent row (coverage spec §3), not just the board mark.
                           roundInProgress: PlannedRound(stage: .refine, round: 2, major: false, crossCheck: true),
                           roundStartedAt: t0.addingTimeInterval(470))
        let paused = Tape(checkpoints: [draft, syn, rf1, rf2, rf3, enc], status: .paused,
                          pendingNotes: [.legacy("cut the migration step", index: 0)])
        let failed = Tape(checkpoints: [draft, syn, rf1], status: .failed,
                          pauseDiagnosis: Diagnosis(category: .rateLimited, detail: "2 of 4 seats failed after 3 retries (529)",
                                                    action: "Retry"),
                          roundStartedAt: t0.addingTimeInterval(470), failedAt: t0.addingTimeInterval(513))
        let done = Tape(checkpoints: [draft, syn, rf1, rf2, rf3, enc,
                                      cp(7, .polish, 1, major: false, at: 1400), cp(8, .polish, 2, major: true, at: 1690)],
                        status: .reachedReview)

        // (name, tape, clock, selected checkpoint, card opened at 700 pt)
        let states: [(String, Tape, TimeInterval, Int?, String)] = [
            ("running", running, 724, nil, "refine-2"),
            ("paused", paused, 1291, 4, "refine-2"),
            ("failed", failed, 554, nil, "refine-2"),
            ("done", done, 1800, nil, "synthesis-0"),
        ]
        for (name, tape, clock, selected, card) in states {
            let model = BoardModel(intake: intake, tape: tape, config: config, now: t0.addingTimeInterval(clock),
                                   selected: selected, preview: nil)
            for width in [1100, 700] as [CGFloat] {
                let policy = FlapPolicy()
                for (surface, text) in model.flapTexts { policy.seed(surface: surface, text: text) }
                let board = DeparturesBoard(model: model, policy: policy, preview: .constant(nil),
                                            onSelect: { _ in }, onExtend: { _ in },
                                            openCardSlotID: width < 1000 ? card : nil)
                    .padding(16)
                try PlanningRender.write(board, size: NSSize(width: width, height: 300),
                                         to: URL(fileURLWithPath: dir).appendingPathComponent("pui-board-\(name)-\(Int(width)).png"))
            }
        }
    }

    /// The bracket handles: − beside + while a cycle has a scheduled round, + alone once the
    /// only round left is the one in flight, and both over a cycle trimmed down to one round.
    /// Writes `trim-<state>-<width>.png` under the same `FD_INTAKE_RENDER_DIR`.
    func testRenderTrimHandles() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_INTAKE_RENDER_DIR"] else {
            throw XCTSkip("set FD_INTAKE_RENDER_DIR to render the departures board PNGs")
        }
        var intake = Intake(projectPath: "/tmp/project", intent: "per-project font size")
        intake.state = .shaping
        let config = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        intake.roundConfig = config
        intake.exchanges = [TriageExchange(questions: ["Q?"], answers: ["A"])]
        let draft = cp(1, .draft, major: true, at: 0, started: -400)
        let syn = cp(2, .synthesis, major: true, at: 182)
        let rf1 = cp(3, .refine, 1, major: false, at: 470)

        let fresh = Tape()
        var lastInFlight = Tape(checkpoints: [draft, syn, rf1], target: .nextMajor, status: .running,
                                roundInProgress: PlannedRound(stage: .refine, round: 2, major: false),
                                roundStartedAt: t0.addingTimeInterval(470))
        lastInFlight.extraRefinement = -1
        var oneRound = Tape(checkpoints: [draft], status: .paused)
        oneRound.extraRefinement = -2
        oneRound.extraPolish = -1

        for (name, tape) in [("fresh", fresh), ("last-in-flight", lastInFlight), ("one-round", oneRound)] {
            let model = BoardModel(intake: intake, tape: tape, config: config, now: t0.addingTimeInterval(724),
                                   selected: nil, preview: nil)
            for width in [1100, 700] as [CGFloat] {
                let policy = FlapPolicy()
                for (surface, text) in model.flapTexts { policy.seed(surface: surface, text: text) }
                let board = DeparturesBoard(model: model, policy: policy, preview: .constant(nil),
                                            onSelect: { _ in }, onExtend: { _ in }, onTrim: { _ in })
                    .padding(16)
                try PlanningRender.write(board, size: NSSize(width: width, height: 300),
                                         to: URL(fileURLWithPath: dir).appendingPathComponent("trim-\(name)-\(Int(width)).png"))
            }
        }
    }

    /// Checkpoint `id` landing `at` seconds after `t0`, started `started` seconds after it.
    private func cp(_ id: Int, _ stage: Stage, _ round: Int = 0, major: Bool, at seconds: TimeInterval,
                    started: TimeInterval? = nil) -> Checkpoint {
        Checkpoint(id: id, parent: id > 1 ? id - 1 : nil, stage: stage, round: round, major: major,
                   createdAt: t0.addingTimeInterval(seconds), startedAt: started.map { t0.addingTimeInterval($0) })
    }
}
