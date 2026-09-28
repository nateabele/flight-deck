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
@MainActor
final class ConvergenceRenderTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ConvergenceRenderTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Lines touched per section per round; each round rewrites the next `n` lines of the
    /// section (wrapping), so a section that wraps takes back what an earlier round wrote.
    private struct Scenario {
        let name: String
        let counts: [Int]
        let agree: [Double]
        let touched: [[Int]]
        var models: [Int: ModelChoice] = [:]
        var extra = 0
        var proposals: [Int: [ProposedChange]] = [:]
    }

    func testRenderConvergenceStates() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the convergence PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        let store = IntakeStore(root: root)
        let hot = "4. Dispatch rules"
        let scenarios = [
            Scenario(name: "converging", counts: [41, 14, 5], agree: [0.70, 0.82, 0.90],
                     touched: [[4, 0, 0], [10, 3, 0], [6, 2, 0], [8, 4, 2], [6, 2, 1], [3, 0, 0], [4, 1, 1]]),
            Scenario(name: "plateau", counts: [38, 14, 12, 13], agree: [0.72, 0.74, 0.73, 0.72],
                     touched: [[3, 0, 0, 0], [8, 2, 0, 0], [5, 3, 2, 1], [6, 4, 3, 2], [4, 3, 4, 2], [2, 1, 2, 2], [3, 1, 0, 1]],
                     models: [3: claude, 4: claude], extra: 1),
            Scenario(name: "diverging", counts: [36, 15, 22, 29], agree: [0.76, 0.80, 0.57, 0.48],
                     touched: [[4, 0, 0, 0], [10, 3, 0, 0], [8, 6, 4, 3], [5, 3, 7, 11], [6, 3, 2, 1], [3, 1, 0, 0], [4, 2, 1, 1]],
                     extra: 1,
                     proposals: [
                        1: [ProposedChange(section: hot, rationale: "Unassigned jobs need an owner",
                                           edit: "A job with no candidate stays Unassigned for 24 hours, then goes to the nearest technician.")],
                        2: [ProposedChange(section: hot, rationale: "Auto-assignment surprises dispatchers",
                                           edit: "A job with no candidate stays Unassigned until a dispatcher assigns it.")],
                        3: [ProposedChange(section: hot, rationale: "Dispatchers are a bottleneck",
                                           edit: "A job with no candidate is auto-assigned after 4 hours to the least-loaded technician.")],
                        4: [ProposedChange(section: hot, rationale: "Auto-assignment surprises dispatchers",
                                           edit: "A job with no candidate stays Unassigned until a dispatcher assigns it.")],
                     ]),
        ]

        var intakes: [String: Intake] = [:]
        for scenario in scenarios {
            var intake = Intake(projectPath: "/tmp/fieldOS",
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
            try writeTape(scenario, for: intake.id, store: store)
            intakes[scenario.name] = intake
        }

        let service = IntakeService(store: store, triageSettings: TriageSettings(harness: .codex, model: "gpt-6-sol", effort: "high"),
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
                                     text.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: max(0, Self.y(of: heading, in: text) - 40)))
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

    // MARK: - Fixtures

    private static let sections: [(title: String, lines: [String])] = [
        ("1. Overview", ["fieldOS schedules field-service work for mid-size HVAC and electrical contractors.",
                         "A dispatcher assigns jobs on a live board.", "Technicians check in from the site on their phones.",
                         "Customers are told when a technician is on the way.", "The first release covers one region."]),
        ("2. Technicians", ["Each technician has skills, a home depot and working hours.",
                            "Skills are tagged by trade and certification level.", "Working hours are set per weekday.",
                            "A technician may mark a day as unavailable.", "Travel starts from the home depot.",
                            "Overtime needs a dispatcher's approval.", "A technician carries at most one van.",
                            "Vans have a stock list the job may need.", "Certifications expire and must be renewed.",
                            "Expired certifications hide the matching skill.", "Technicians see only their own jobs.",
                            "A lead technician can see the whole crew."]),
        ("3. Jobs", ["A job has a site, a window, required skills and an estimate.", "Windows are two hours long.",
                     "Estimates come from the job type.", "A job moves through new, assigned, enRoute, onSite and done.",
                     "A cancelled job keeps its history.", "Repeat visits link to the original job.",
                     "Photos attach to the job, not the technician.", "Parts used are recorded at close.",
                     "A job may need two technicians.", "Emergency jobs jump the queue.",
                     "Jobs outside the region are refused.", "Every change is logged with who made it.",
                     "A job's site can have access notes.", "Customers may reschedule once without a fee."]),
        ("4. Dispatch rules", ["A job is offered to the best-scoring available technician.",
                               "Skill match is a soft constraint: a dispatcher may override it with a reason.",
                               "Availability and the travel buffer are hard constraints.",
                               "Score = skill fit × 0.5 + proximity × 0.3 + load balance × 0.2.",
                               "A job with no candidate stays Unassigned until a dispatcher assigns it.",
                               "Auto-assignment is out of scope for v1.", "Max 6 jobs per technician per day.",
                               "The travel buffer is 20 minutes between jobs.", "Emergency jobs may break the daily cap.",
                               "A dispatcher can pin a job to a technician.", "Pinned jobs are never re-offered.",
                               "Declined offers go to the next-best technician."]),
        ("5. Mobile check-in", ["Check-ins queue in CheckInOutbox while offline.", "The outbox replays oldest-first on reconnect.",
                                "A check-in more than 200 m from the site asks for a reason.", "Check-out requires a signature.",
                                "Photos upload on Wi-Fi only by default.", "The app works for a full day offline.",
                                "A failed replay is shown to the technician.", "The dispatcher sees the last known position.",
                                "Location is sampled only during a job."]),
        ("6. Notifications", ["The customer gets an SMS when the technician is en route.", "The SMS carries a live ETA link.",
                              "A dispatcher is pushed when a job sits unassigned for 30 minutes.",
                              "Technicians get a push for a new job.", "Quiet hours hold non-urgent pushes."]),
        ("7. Testing", ["Dispatch scoring is a pure function with table tests.",
                        "Offline replay has a simulated-network suite.", "The board has one UI test per hard constraint.",
                        "Check-in distance rules are property-tested.", "Every notification has a template test."]),
    ]

    /// Round `r`'s wording for a line it rewrote.
    private static let revisions = ["", " Confirmed with the dispatch leads.", " Tightened after review.",
                                    " Reworded for the pilot.", " Revisited against the field data."]

    /// The plan after `round` rounds: each section's lines carry the wording of the last round
    /// that touched them.
    private static func plan(_ scenario: Scenario, after round: Int) -> String {
        var out = "# Field-service scheduling platform\n\n"
        for (s, section) in sections.enumerated() {
            var last = Array(repeating: 0, count: section.lines.count)
            var cursor = 0
            for r in 0..<round {
                for k in 0..<scenario.touched[s][r] { last[(cursor + k) % section.lines.count] = r + 1 }
                cursor += scenario.touched[s][r]
            }
            out += "## \(section.title)\n\n"
            for (i, line) in section.lines.enumerated() {
                out += "- " + line + (last[i] == 0 ? "" : revisions[last[i] % revisions.count].replacingOccurrences(of: ".", with: " (R\(last[i])).")) + "\n"
            }
            out += "\n"
        }
        return out
    }

    private func writeTape(_ scenario: Scenario, for id: UUID, store: IntakeStore) throws {
        let tapes = TapeStore(intakeDirectory: store.directory(for: id))
        let slot = { (role: String, used: ModelChoice) in SlotOutcome(role: role, used: used, requested: used, status: .ok) }
        var tape = Tape()
        tape.extraRefinement = scenario.extra
        try tapes.saveTape(tape)
        let rounds = scenario.counts.count
        var t = now.addingTimeInterval(-Double(600 + rounds * 300))
        let draft = Data(Self.plan(scenario, after: 0).utf8)
        try tapes.writeCheckpoint(
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: t,
                       record: RoundRecord(slots: [slot("drafter", codex), slot("drafter", claude)], linesAdded: 412),
                       startedAt: t.addingTimeInterval(-400)),
            files: ["drafts/0.md": draft], into: &tape)
        t += 180
        try tapes.writeCheckpoint(
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: t,
                       record: RoundRecord(slots: [slot("synthesizer", claude), slot("integrator", codex)], changeCount: 14,
                                           linesAdded: 30, linesRemoved: 12, tally: VerdictTally(agree: 11, somewhat: 2, disagree: 1)),
                       startedAt: t.addingTimeInterval(-180)),
            files: ["plan.md": draft], into: &tape)
        for r in 1...rounds {
            t += 290
            let agree = Int((scenario.agree[r - 1] * 100).rounded())
            let reviewer = scenario.models[r] ?? codex
            var files = ["plan.md": Data(Self.plan(scenario, after: r).utf8)]
            if let proposals = scenario.proposals[r] {
                files["changes.json"] = try IntakeJSON.encoder.encode(proposals)
                files["verdicts.json"] = try IntakeJSON.encoder.encode([ChangeVerdict(index: 0, verdict: r == 3 ? .somewhat : .agree)])
            }
            let churn = scenario.touched.map { $0[r - 1] }.reduce(0, +)
            try tapes.writeCheckpoint(
                Checkpoint(id: 2 + r, parent: 1 + r, stage: .refine, round: r, major: r == rounds, createdAt: t,
                           record: RoundRecord(slots: [slot("reviewer", reviewer), slot("integrator", codex)],
                                               changeCount: scenario.counts[r - 1], linesAdded: churn, linesRemoved: churn,
                                               tally: VerdictTally(agree: agree, somewhat: 0, disagree: 100 - agree)),
                           startedAt: t.addingTimeInterval(-280)),
                files: files, into: &tape)
        }
        tape.status = .paused
        try tapes.saveTape(tape)
    }
}
