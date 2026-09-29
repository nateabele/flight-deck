import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders the COVERAGE card in each band (SATURATED, FEW LEFT, STALLED, NO OVERLAP, same
/// family) and the control bar's LCD with the cell at full width and narrowed until the other
/// optional cells have left. Skipped unless `FD_PLANNING_RENDER_DIR` names an output directory;
/// writes `coverage-card-<band>.png` and `coverage-lcd-<width>.png`.
///
/// The card models are the engine's: each is built from a reading `CoverageSeries.reading`
/// folded and a verdict `CoverageSeries.verdict` judged, so the pictures show the real strings.
@MainActor
final class CoverageRenderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testRenderCoverageStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the coverage PNGs")
        }
        let out = URL(fileURLWithPath: dir)

        let r1 = reading(n1: 14, n2: 11, both: 5, round: 1)
        let cards: [(String, CoverageCellModel)] = [
            ("saturated", try model([r1, reading(n1: 20, n2: 18, both: 15, round: 3)], remaining: 0)),
            ("fewleft", try model([reading(n1: 12, n2: 10, both: 6, round: 1)], remaining: 2)),
            ("stalled", try model([r1, reading(n1: 20, n2: 18, both: 4, round: 3, rejected: (3, 1))], convergence: .plateau)),
            ("nooverlap", try model([reading(n1: 3, n2: 4, both: 0, round: 1)], remaining: 2)),
            ("samefamily", try model([reading(n1: 20, n2: 18, both: 15, round: 1, families: [.claude, .claude])], remaining: 2)),
            ("pending", try model([], remaining: 3)),
        ]
        for (name, card) in cards {
            try PlanningRender.write(CoverageCard(model: card).fixedSize().padding(16), size: NSSize(width: 540, height: 380),
                                     to: out.appendingPathComponent("coverage-card-\(name).png"))
        }
        try PlanningRender.write(CoverageCard(model: cards[0].1).fixedSize().padding(16), size: NSSize(width: 540, height: 380),
                                 to: out.appendingPathComponent("coverage-card-saturated-light.png"), appearance: .aqua)

        // The LCD: Refine 2 running after a cross-checked R1, every optional cell present.
        var intake = Intake(projectPath: "/tmp/project", intent: "Field-service scheduling platform")
        intake.state = .shaping
        intake.chosenPreset = .featurePlan
        let config = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        intake.roundConfig = config
        intake.exchanges = [TriageExchange(questions: ["Q?"], answers: ["A"])]
        let landed = [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: t0, record: RoundRecord(linesAdded: 412)),
            Checkpoint(id: 2, stage: .synthesis, round: 0, major: true, createdAt: t0.addingTimeInterval(180),
                       record: RoundRecord(linesAdded: 30, linesRemoved: 12)),
            Checkpoint(id: 3, stage: .refine, round: 1, major: false, createdAt: t0.addingTimeInterval(468),
                       record: RoundRecord(linesAdded: 12, linesRemoved: 5)),
        ]
        let tape = Tape(checkpoints: landed, target: .nextMajor, status: .running,
                        roundInProgress: PlannedRound(stage: .refine, round: 2, major: false),
                        roundStartedAt: t0.addingTimeInterval(468))
        let seat = { (glyph: SeatRowModel.Glyph, cost: Double?) in
            SeatRowModel(id: UUID().uuidString, glyph: glyph, role: "reviewer", identity: "claude", headline: nil,
                         action: nil, footprint: [], footprintAll: [], steps: nil, contextFraction: nil, elapsed: 0,
                         exception: nil, result: nil, cost: cost)
        }
        let seats = [seat(.done, 0.61), seat(.running, nil)]
        let convergence = ConvergenceCellModel(word: "CONVERGING ↘", latest: 9, spark: [22, 9], tone: .normal)
        let now = t0.addingTimeInterval(723)
        let board = BoardModel(intake: intake, tape: tape, config: config, now: now, selected: nil, preview: nil)
        let policy = FlapPolicy()
        for (name, coverage) in [("fewleft", cards[1].1), ("stalled", cards[2].1)] {
            let lcd = LCDModel(tape: tape, config: config, board: board, seats: seats, convergence: convergence,
                               coverage: coverage, preview: nil, now: now)
            for width: CGFloat in [1280, 1100, 1000, 900, 820] {
                let bar = ControlBar(lcd: lcd, convergence: convergence, coverage: coverage,
                                     actions: PlanningActions(enabled: ShapingModel(intake: intake, tape: tape).enabled, perform: { _ in }),
                                     status: tape.status, defaultPlay: config.defaultPlay, halting: nil, policy: policy,
                                     preview: .constant(nil), setDefaultPlay: { _ in }, onBack: {})
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(10)
                try PlanningRender.write(bar, size: NSSize(width: width + 20, height: ControlBar.barHeight + 20),
                                         to: out.appendingPathComponent("coverage-lcd-\(name)-\(Int(width)).png"))
            }
        }
    }

    private func model(_ readings: [CoverageReading], convergence: ConvergenceVerdict? = nil, remaining: Int = 0) throws -> CoverageCellModel {
        let verdict = CoverageSeries.verdict(readings: readings, preset: .featurePlan, convergence: convergence,
                                             refineRoundsRemaining: remaining, failedCrossCheckRound: nil)
        return try XCTUnwrap(CoverageCellModel(verdict: verdict, crossChecks: true, readings: readings))
    }

    /// A reading folded from proposals and verdicts, as `CoverageCellModelTests` builds them.
    private func reading(n1: Int, n2: Int, both: Int, round: Int, families: [ModelFamily] = [.codex, .claude],
                         rejected: (Int, Int) = (0, 0)) -> CoverageReading {
        var proposers: [Int] = [], changes: [ProposedChange] = [], vs: [ChangeVerdict] = [], clusters: [[Int]] = []
        func add(_ p: Int, _ t: String, _ v: Verdict = .agree) -> Int {
            proposers.append(p); changes.append(ProposedChange(section: "## \(t)", rationale: t, edit: t))
            vs.append(ChangeVerdict(index: changes.count - 1, verdict: v)); return changes.count - 1
        }
        for i in 0..<(n1 - both) { _ = add(0, "a\(i)") }
        for i in 0..<(n2 - both) { _ = add(1, "b\(i)") }
        for i in 0..<both { clusters.append([add(0, "s\(i)"), add(1, "s\(i)")]) }
        for i in 0..<rejected.0 { _ = add(0, "ra\(i)", .disagree) }
        for i in 0..<rejected.1 { _ = add(1, "rb\(i)", .disagree) }
        return CoverageSeries.reading(checkpoint: round + 2, round: round,
                                      record: CrossCheckRecord(proposers: proposers, families: families,
                                                               clusters: clusters.isEmpty ? nil : clusters, blindOrderSeed: 1),
                                      changes: changes, verdicts: vs)
    }
}
