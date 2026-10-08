import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// A runner the render can call live or not, so the panel draws both of its modes.
@MainActor
private final class StubRunner: IntakeRunnerControlling {
    var running: Set<UUID> = []
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError> { .success(()) }
    func isRunning(_ id: UUID, tape: Tape?) -> Bool { running.contains(id) }
    func reap(_ id: UUID) {}
    func socketPath(for id: UUID) -> String { "/nonexistent/\(id).sock" }
}

/// The shaping inspector's Rounds editor (`ShapingRoundsPanel`), paused versus running, light
/// and dark, for design review. Skipped unless `FD_ROUNDS_PAUSED_RENDER_DIR` names an output
/// directory. Pictures, not assertions, drawn through a real `IntakeService` over files on
/// disk. The panel is rendered on its own: the inspector column is an AppKit split pane that
/// `layer.render(in:)` draws blank (`PlanningRenderTests`).
@MainActor
final class RoundsEditPausedRenderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoundsEditPausedRenderTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testRenderPausedAndRunning() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_ROUNDS_PAUSED_RENDER_DIR"] else {
            throw XCTSkip("set FD_ROUNDS_PAUSED_RENDER_DIR to render the paused Rounds editor PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = IntakeStore(root: root)

        // Four families offered, as on a machine with every CLI signed in; a harness the gate
        // does not offer yet simply renders absent.
        let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
        let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")
        var available = AvailableModels(choices: [
            .claude: claude, .codex: codex,
            .grok: ModelChoice(harness: .grok, model: "grok-4.7", effort: "high"),
            .gemini: ModelChoice(harness: .gemini, model: "gemini-3.1-pro-high", effort: "high"),
        ])
        available.models[.grok] = ["grok-4.7", "grok-4.6"]
        let config = RoundConfig(
            drafters: [Slot(codex, persona: .arbiter, fallback: claude), Slot(claude, persona: .realist, fallback: codex)],
            synthesizer: Slot(codex, persona: .arbiter, fallback: claude), reviewer: Slot(codex, fallback: claude),
            integrator: claude, encoder: codex, polisher: claude, refinementCap: 3, polishCap: 2,
            freshEyesAndDedup: false, defaultPlay: .nextMajor, customized: false,
            crossReviewer: Slot(claude), crossCheck: .firstAndLast)

        /// Drafted, synthesized and one refine round in, with one + pressed on refine.
        func shaping(_ status: RunnerStatus) throws -> Intake {
            var i = Intake(projectPath: "/tmp/project", intent: "Build a field-service scheduling platform")
            i.state = .shaping
            i.chosenPreset = .featurePlan
            i.roundConfig = config
            try store.save(i)
            let at = Date().addingTimeInterval(-600)
            var tape = Tape(checkpoints: [
                Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: at),
                Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: at),
                Checkpoint(id: 3, parent: 2, stage: .refine, round: 1, major: false, createdAt: at),
            ], status: status, extraRefinement: 1)
            if status == .running { tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false) }
            try TapeStore(intakeDirectory: store.directory(for: i.id)).saveTape(tape)
            return i
        }
        let paused = try shaping(.paused)
        let edited = try shaping(.paused)
        let running = try shaping(.running)

        let runner = StubRunner()
        runner.running = [running.id]
        let service = IntakeService(store: store, triageSettings: TriageSettings(harness: .codex, model: "gpt-6-sol", effort: "high"),
                                    availableModels: available, runner: runner,
                                    inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        // An unsaved change of reviewer to Grok, as the panel shows it before Save.
        if let grok = available.choice(for: .grok) {
            var draft = config
            draft.reviewer = Slot(grok)
            draft.customized = true
            service.setRoundConfigDraft(edited.id, draft)
        }

        for (name, intake) in [("paused", paused), ("paused-unsaved", edited), ("running", running)] {
            for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let panel = ShapingRoundsPanel(service: service, intake: intake)
                    .padding(16)
                    .frame(width: 440, alignment: .topLeading)
                try PlanningRender.write(panel, size: NSSize(width: 440, height: 1080),
                                         to: out.appendingPathComponent("rounds-\(name)-\(scheme).png"), appearance: appearance)
            }
        }
    }
}
