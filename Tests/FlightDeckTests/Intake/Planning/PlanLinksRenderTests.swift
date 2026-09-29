import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The plan's links under ⌘-hover (underlined, the target named under them) and after a
/// ⌘-click on a missing file, and the churn lane's versions card open under its marker's line
/// — mid-plan, and flipped above it near the window's bottom — light and dark. Skipped unless
/// `FD_PLANNING_RENDER_DIR` names an output directory; writes `links-*.png` and `versions-*.png`.
/// Nothing is opened: the editor's opener is swapped for one that records.
@MainActor
final class PlanLinksRenderTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlanLinksRenderTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func outputDirectory() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    func testRenderLinks() throws {
        let out = try outputDirectory()
        let (service, intake) = try shapingIntake(plan: Self.linkedPlan)
        for (appearance, tone) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (name, word, missing) in [("hover", "the fold spec", false), ("missing", "old notes", true)] {
                try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {}),
                                         size: NSSize(width: 1100, height: 760),
                                         to: out.appendingPathComponent("links-\(name)-\(tone).png"),
                                         appearance: appearance,
                                         prepare: { host in
                                             PlanReadableRenderTests.scrollToPlan(host, offset: -300)
                                             guard let text = PlanReadableRenderTests.find(PlanNSTextView.self, in: host) else { return }
                                             text.linkOpener = PlanLinkOpener(open: { _ in }, reveal: { _ in }, beep: {},
                                                                              probe: { $0.hasSuffix("old-notes.md") ? nil : .file(executable: false) })
                                             RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                                             let range = (text.string as NSString).range(of: word)
                                             guard let rect = text.segmentRects(range).first,
                                                   let link = text.link(at: NSPoint(x: rect.midX, y: rect.midY)) else {
                                                 return XCTFail("no link under \(word)")
                                             }
                                             if missing { text.openLink(link) } else { text.updateLinkHover(at: NSPoint(x: rect.midX, y: rect.midY), command: true) }
                                         })
            }
        }
    }

    func testRenderVersionsCardBelowTheLine() async throws {
        let out = try outputDirectory()
        let store = IntakeStore(root: root)
        let scenario = try XCTUnwrap(ConvergenceFixture.standardScenarios(claude: claude).first { $0.name == "diverging" })
        var intake = Intake(projectPath: "/tmp/larkOS",
                            intent: "Build a field-service scheduling platform: technicians, jobs, a dispatch board and mobile check-in",
                            createdAt: now.addingTimeInterval(-7200))
        intake.state = .shaping
        intake.chosenPreset = .featurePlan
        intake.roundConfig = RoundConfig(
            drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist)], synthesizer: Slot(claude),
            reviewer: Slot(codex), integrator: codex, encoder: codex, polisher: codex,
            refinementCap: 3, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor, customized: false)
        try store.save(intake)
        try ConvergenceFixture.writeTape(scenario, for: intake.id, store: store, now: now, codex: codex, claude: claude)
        let service = IntakeService(store: store, triageSettings: TriageSettings(harness: .codex, model: "gpt-6-sol", effort: "high"),
                                    availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        await service.launchRecovery?.value
        service.pollTapes()
        await service.convergenceFold(for: intake.id)?.value

        let height: CGFloat = 1000
        let heading = "## 4. Dispatch rules"
        for (appearance, tone) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            // Mid-plan: §4's heading a third of the way down — the card hangs under it. Near the
            // bottom: the heading 90 pt above the window's edge — no room below, so it flips above.
            for (place, fromBottom) in [("mid", nil), ("bottom", 90)] as [(String, CGFloat?)] {
                try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {}),
                                         size: NSSize(width: 1100, height: height),
                                         to: out.appendingPathComponent("versions-\(place)-\(tone).png"),
                                         appearance: appearance,
                                         prepare: { host in
                                             guard let text = PlanReadableRenderTests.find(PlanNSTextView.self, in: host),
                                                   let lane = PlanReadableRenderTests.find(ChurnLaneView.self, in: host),
                                                   let scroll = PlanReadableRenderTests.outerScroll(host),
                                                   let document = scroll.documentView else { return }
                                             let at = (text.string as NSString).range(of: heading)
                                             guard let line = text.segmentRects(at).first else { return }
                                             let y = text.convert(line.origin, to: document).y
                                             let viewport = scroll.contentView.bounds.height
                                             // Mid: a quarter of the way down what the pinned block leaves showing.
                                             let covered = text.obscuredTop
                                             let target = fromBottom.map { y - (viewport - $0) } ?? y - covered - (viewport - covered) / 4
                                             scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, target)))
                                             scroll.reflectScrolledClipView(scroll.contentView)
                                             lane.needsDisplay = true
                                             // A scroll closes an open card (by design): open it once settled.
                                             RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                                             lane.presentVersions(for: heading)
                                             RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                                         })
            }
        }
    }

    // MARK: - Fixture

    /// A shaping intake, paused after its first round, whose plan is `plan`.
    private func shapingIntake(plan: String) throws -> (IntakeService, Intake) {
        let store = IntakeStore(root: root)
        var intake = Intake(projectPath: "/Users/me/Projects/work/larkOS",
                            intent: "Build a field-service scheduling platform: technicians, jobs, a dispatch board and mobile check-in",
                            createdAt: now.addingTimeInterval(-3600))
        intake.state = .shaping
        intake.chosenPreset = .fullPlan
        intake.roundConfig = RoundConfig(
            drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist)], synthesizer: Slot(claude),
            reviewer: Slot(codex), integrator: codex, encoder: codex, polisher: codex,
            refinementCap: 3, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor, customized: false)
        try store.save(intake)
        let tapes = TapeStore(intakeDirectory: store.directory(for: intake.id))
        let slot = { (role: String, used: ModelChoice) in SlotOutcome(role: role, used: used, requested: used, status: .ok) }
        var tape = Tape()
        try tapes.saveTape(tape)
        try tapes.writeCheckpoint(
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: now.addingTimeInterval(-1500),
                       record: RoundRecord(slots: [slot("drafter", codex), slot("drafter", claude)], linesAdded: 40),
                       startedAt: now.addingTimeInterval(-1800)),
            files: ["plan.md": Data(plan.utf8)], into: &tape)
        tape.status = .paused
        try tapes.saveTape(tape)
        let service = IntakeService(store: store, triageSettings: TriageSettings(harness: .codex, model: "gpt-6-sol", effort: "high"),
                                    availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        service.pollTapes()
        return (service, intake)
    }

    /// A plan section the way agents link things: a repo-relative file with a line, an absolute
    /// path, an autolink, a bare URL, and a link to a file that is gone.
    static let linkedPlan = """
    # Field-service scheduling platform

    ## 1. Context

    The folding work follows [the fold spec](docs/superpowers/specs/2026-09-27-planning-ui-redesign-design.md#L261) and the existing gutter in [PlanFolding.swift](Sources/FlightDeck/Intake/Planning/PlanEditor/PlanFolding.swift:42). The product brief lives in [README](/Users/me/Projects/work/larkOS/README.md).

    Background reading: <https://developer.apple.com/documentation/appkit/nstextlayoutmanager> and https://github.com/ghostty-org/ghostty/discussions. The [old notes](docs/old-notes.md) were folded into this plan.

    ## 2. Dispatch rules

    The board suggests the best-scoring available technician for each unassigned job. Scoring is a pure function of the job, the technician and the day's schedule, so the same inputs always give the same suggestion.

    1. Hard constraints first: availability, the travel buffer and the job's window.
    2. Skill match is a **soft** constraint: a dispatcher may override it.
    """
}
