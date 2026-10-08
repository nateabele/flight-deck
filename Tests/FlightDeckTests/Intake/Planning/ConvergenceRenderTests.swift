import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders the shaping screen in the three convergence states — converging, plateau (with a
/// reviewer swap and an Extend), diverging (§4 reopened) — each with the heatmap collapsed (the
/// CONVERGENCE card open) and expanded, at 1100 pt, and the compact bar at 700 pt. Skipped
/// unless `FD_PLANNING_RENDER_DIR` names an output directory; writes `pui-convergence-*.png`.
///
/// Driven through a real `IntakeService` over checkpoint files on disk: every plan is a real
/// `plan.md` whose round-to-round diffs produce the section churn, so the verdict, the heatmap
/// and the churn lane are the engine's fold of those files, not numbers handed to the views.
///
/// The three scenarios' fixture (`ConvergenceFixture`, `ConvergenceScenarios.swift`) is shared
/// with `PlanningRenderTests`, which renders the same states at the control bar's two widths.
@MainActor
final class ConvergenceRenderTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ConvergenceRenderTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testRenderConvergenceStates() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the convergence PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        let store = IntakeStore(root: root)
        let scenarios = ConvergenceFixture.standardScenarios(claude: claude)

        var intakes: [String: Intake] = [:]
        for scenario in scenarios {
            var intake = Intake(projectPath: "/tmp/larkOS",
                                intent: "Build a field-service scheduling platform: technicians, jobs, a dispatch board and mobile check-in",
                                createdAt: now.addingTimeInterval(-7200))
            intake.state = .shaping
            intake.chosenPreset = .featurePlan
            intake.exchanges = [TriageExchange(questions: ["Is skill match a hard rule?"], answers: ["A dispatcher may override it."])]
            intake.roundConfig = RoundConfig(
                drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist)], synthesizer: Slot(claude),
                reviewer: Slot(codex), integrator: codex, encoder: codex, polisher: codex,
                refinementCap: 3, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor, customized: false)
            try store.save(intake)
            try ConvergenceFixture.writeTape(scenario, for: intake.id, store: store, now: now, codex: codex, claude: claude)
            intakes[scenario.name] = intake
        }

        let service = IntakeService(store: store, triageSettings: TriageSettings(agent: .codex, model: "gpt-6-sol", effort: "high"),
                                    availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        await service.launchRecovery?.value
        service.pollTapes()
        for intake in intakes.values { await service.convergenceFold(for: intake.id)?.value }

        for scenario in scenarios {
            let intake = try XCTUnwrap(intakes[scenario.name])
            let cycle = try XCTUnwrap(service.convergence[intake.id]?.last)
            print("CONVERGENCE-RENDER \(scenario.name): \(cycle.verdict) · \(cycle.explanation)")
            let hotSection = ConvergenceCellModel(cycles: [cycle])?.hotSection
            try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {}, opensConvergenceCard: true),
                                     size: NSSize(width: 1100, height: 1500),
                                     to: out.appendingPathComponent("pui-convergence-\(scenario.name)-collapsed-1100.png"))
            try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {},
                                                      heatmap: HeatmapFocus(section: hotSection)),
                                     size: NSSize(width: 1100, height: 1700),
                                     to: out.appendingPathComponent("pui-convergence-\(scenario.name)-expanded-1100.png"))
        }
        let diverging = try XCTUnwrap(intakes["diverging"])
        // The plan's churn lane at §4: the plan scrolled to §4, and the amber marker's versions card open as a hover would open it.
        try PlanningRender.write(IntakeDetailView(service: service, intake: diverging, onOpenReview: {}),
                                 size: NSSize(width: 1100, height: 1500),
                                 to: out.appendingPathComponent("pui-convergence-diverging-churn-lane-1100.png"),
                                 prepare: { host in
                                     let views = Self.all(host)
                                     guard let text = views.compactMap({ $0 as? NSTextView }).first,
                                           let lane = views.compactMap({ $0 as? ChurnLaneView }).first else { return }
                                     let heading = (text.string as NSString).range(of: "## 4. Dispatch rules")
                                     // The page scrolls the plan: §4's heading just under the pinned block.
                                     let covered = (text as? PlanNSTextView)?.obscuredTop ?? 0
                                     text.scroll(NSPoint(x: 0, y: max(0, Self.y(of: heading, in: text) - 40 - covered)))
                                     lane.needsDisplay = true
                                     // Opened once the scroll has settled (a scroll closes an open card, by
                                     // design), then given time to draw: its panel's hosting view renders on
                                     // its own display cycle.
                                     RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                                     lane.presentVersions(for: "## 4. Dispatch rules")
                                     RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                                 })
        try PlanningRender.write(IntakeDetailView(service: service, intake: diverging, onOpenReview: {}),
                                 size: NSSize(width: 700, height: 1500),
                                 to: out.appendingPathComponent("pui-convergence-diverging-compact-700.png"))
    }

    private static func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }

    /// A character range's top in its text view, from TextKit 2's layout.
    private static func y(of range: NSRange, in text: NSTextView) -> CGFloat {
        guard let layout = text.textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: range.location) else { return 0 }
        var y: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: location, options: [.ensuresLayout]) { y = $0.layoutFragmentFrame.minY; return false }
        return y
    }

}
