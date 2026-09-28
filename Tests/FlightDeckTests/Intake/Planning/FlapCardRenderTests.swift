import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders the board's hover card for design review — skipped unless `FD_PLANNING_RENDER_DIR`
/// names an output directory. Writes `flapcard-<slot>-<appearance>.png` (the control bar over the
/// board, as the pane stacks them, with one slot's card open above it — a mid-tape slot and the
/// tape's first and last slots, where the card has to slide in from the window's side) and `flapcard-reveal.png` (the card's split-flap held at instants
/// through its reveal). Pictures, not assertions (AGENTS.md rule 2).
@MainActor
final class FlapCardRenderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testRenderHoverCardPlacementAndReveal() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the hover card PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var intake = Intake(projectPath: "/tmp/project", intent: "per-project font size")
        intake.state = .shaping
        let config = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        intake.roundConfig = config
        intake.exchanges = [TriageExchange(questions: ["Q?"], answers: ["A"])]
        func cp(_ id: Int, _ stage: Stage, _ round: Int = 0, major: Bool, at seconds: TimeInterval) -> Checkpoint {
            Checkpoint(id: id, parent: id > 1 ? id - 1 : nil, stage: stage, round: round, major: major,
                       createdAt: t0.addingTimeInterval(seconds), startedAt: t0.addingTimeInterval(seconds - 170))
        }
        let tape = Tape(checkpoints: [cp(1, .draft, major: true, at: 0), cp(2, .synthesis, major: true, at: 182),
                                      cp(3, .refine, 1, major: false, at: 470)],
                        target: .nextMajor, status: .running,
                        roundInProgress: PlannedRound(stage: .refine, round: 2, major: false),
                        roundStartedAt: t0.addingTimeInterval(470))
        let now = t0.addingTimeInterval(724)
        let model = BoardModel(intake: intake, tape: tape, config: config, now: now, selected: nil, preview: nil)
        let lcd = LCDModel(tape: tape, config: config, board: model, seats: [], convergence: nil, preview: nil, now: now)

        let edges = try (XCTUnwrap(model.slots.first?.id), XCTUnwrap(model.slots.last?.id))
        for (slot, name) in [("refine-1", "mid"), (edges.0, "leading"), (edges.1, "trailing")] {
            for (appearance, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                let policy = FlapPolicy()
                for (surface, text) in model.flapTexts { policy.seed(surface: surface, text: text) }
                let pane = VStack(spacing: 10) {
                    ControlBar(lcd: lcd, convergence: nil, actions: PlanningActions(enabled: [], perform: { _ in }),
                               status: tape.status, defaultPlay: config.defaultPlay, halting: nil, policy: policy,
                               preview: .constant(nil), setDefaultPlay: { _ in }, onBack: {})
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    DeparturesBoard(model: model, policy: policy, preview: .constant(nil), onSelect: { _ in },
                                    onExtend: { _ in }, openCardSlotID: slot)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(16)
                try PlanningRender.write(pane, size: NSSize(width: 700, height: 400),
                                         to: out.appendingPathComponent("flapcard-\(name)-\(suffix).png"), appearance: appearance)
            }
        }

        let instants: [TimeInterval] = [0, 0.05, 0.1, 0.15, 0.2, 0.25, CardReveal.duration(count: 8)]
        let reveal = VStack(alignment: .leading, spacing: 14) {
            ForEach(instants, id: \.self) { t in
                HStack(spacing: 16) {
                    Text(String(format: "%3.0f ms", t * 1000)).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    SplitFlapCard(full: "Refine 2", detail: "landed 3:02", revealAt: t).fixedSize()
                }
            }
        }
        .padding(24)
        try PlanningRender.write(reveal, size: NSSize(width: 360, height: 620), to: out.appendingPathComponent("flapcard-reveal.png"))
    }
}
