import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The finished-rounds strip and its detail panel, offscreen, for design review — skipped unless
/// `FD_PLANNING_RENDER_DIR` names an output directory. Writes `rounds-*.png`, light and dark, at
/// 1100 and 700 pt: the strip closed; open on the first card; open mid-strip on a long detail
/// (capped, scrolling inside); open on a short one; and the long one with the strip scrolled, to
/// show the caret staying on its card. Drawn through `LiveCard.shaping`, the way the pane draws it.
@MainActor
final class FinishedRoundsRenderTests: XCTestCase {
    private let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")
    private let now = Date()

    private func dir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the finished-rounds PNGs")
        }
        return URL(fileURLWithPath: dir)
    }

    func testRenderFinishedRounds() throws {
        let out = try dir()
        let cases: [(name: String, open: Int?, height: CGFloat, scroll: CGFloat?)] = [
            ("closed", nil, 330, nil),
            ("open-first", 1, 720, nil),
            ("open-long", 4, 760, nil),
            ("open-short", 6, 640, nil),
            ("open-long-scrolled", 4, 760, 160),
        ]
        for width: CGFloat in [1100, 700] {
            for (appearance, tag) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
                for c in cases {
                    let view = card(open: c.open).padding(20)
                    let url = out.appendingPathComponent("rounds-\(c.name)-\(Int(width))-\(tag).png")
                    try PlanningRender.write(view, size: NSSize(width: width, height: c.height), to: url,
                                             appearance: appearance, prepare: c.scroll.map { dx in { host in
                                                 Self.scrollStrip(in: host, by: dx)
                                             } })
                }
            }
        }
    }

    /// Scrolls the strip's horizontal scroll view left by `dx` from where it settled.
    private static func scrollStrip(in view: NSView, by dx: CGFloat) {
        for sub in view.subviews {
            if let scroll = sub as? NSScrollView, let doc = scroll.documentView,
               doc.frame.width > scroll.contentView.bounds.width + 1 {
                var origin = scroll.contentView.bounds.origin
                origin.x = max(0, origin.x - dx)
                scroll.contentView.scroll(to: origin)
                scroll.reflectScrolledClipView(scroll.contentView)
                return
            }
            scrollStrip(in: sub, by: dx)
        }
    }

    private func card(open: Int?) -> some View {
        var intake = Intake(projectPath: "/tmp/project", intent: "Scheduling platform for field technicians")
        intake.state = .shaping
        intake.roundConfig = RoundConfig(
            drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist, fallback: codex), Slot(claude, persona: .coverage)],
            synthesizer: Slot(claude), reviewer: Slot(codex), integrator: codex, encoder: codex, polisher: codex,
            refinementCap: 3, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor, customized: false)
        let ok = { (role: String) in SlotOutcome(role: role, used: self.codex, requested: self.codex, status: .ok) }
        let at = { (s: TimeInterval) in self.now.addingTimeInterval(s - 20_000) }
        let longNote = """
            Tightened the rollout section so the dispatcher override is staged behind a flag for the first two \
            regions, and rewrote §4's ranking rule so skill match is a soft constraint with an explicit reason code.

            Applied 39 of 41 proposed changes. Declined two: moving offline replay into the sync service (it \
            would couple the mobile client's release train to the backend's) and dropping the travel-time cache, \
            which the reviewer flagged as premature but the load numbers in §7 still justify.

            Open questions carried forward: whether a technician's skills can change mid-day (the plan assumes \
            not), who owns the reason codes once dispatch ships, and whether the override audit trail belongs in \
            the dispatch service or the shared audit log. Each is noted in §9 with the owner the plan proposes.

            The integrator re-numbered §5–§8 after splitting Scheduling into Assignment and Travel; every \
            cross-reference in the plan was updated to match, and the task sketch in §10 now names both halves.
            """
        let tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: at(900),
                       record: RoundRecord(slots: [ok("drafter"),
                                                   SlotOutcome(role: "drafter", persona: .realist, used: codex, requested: claude,
                                                               status: .substituted,
                                                               diagnosis: Diagnosis(category: .authExpired, detail: "claude login expired",
                                                                                    action: "Run `claude /login`")),
                                                   ok("drafter")],
                                           note: "Three drafts; the realist fell back to codex.")),
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: at(1400),
                       record: RoundRecord(slots: [ok("synthesizer"), ok("integrator")], changeCount: 14,
                                           linesAdded: 42, linesRemoved: 17,
                                           sectionsChanged: ["## 2. Scope", "## 4. Dispatch", "## 7. Rollout", "## 8. Risks"]),
                       startedAt: at(920)),
            Checkpoint(id: 3, parent: 2, stage: .refine, round: 1, major: false, createdAt: at(2100),
                       record: RoundRecord(slots: [ok("reviewer"), ok("integrator")], changeCount: 22, linesAdded: 310,
                                           linesRemoved: 96, sectionsChanged: ["## 4. Dispatch"],
                                           tally: VerdictTally(agree: 18, somewhat: 3, disagree: 1),
                                           note: "Reworked dispatch ranking."),
                       startedAt: at(1410)),
            Checkpoint(id: 4, parent: 3, stage: .refine, round: 2, major: false, createdAt: at(2900),
                       record: RoundRecord(slots: [ok("reviewer"),
                                                   SlotOutcome(role: "integrator", used: codex, requested: codex, status: .failed,
                                                               diagnosis: Diagnosis(category: .timeout, detail: "no output for 20 minutes",
                                                                                    action: "Retry the round"))],
                                           changeCount: 41, linesAdded: 620, linesRemoved: 180,
                                           sectionsChanged: ["## 2. Scope", "## 4. Dispatch", "## 5. Assignment", "## 6. Travel",
                                                             "## 7. Rollout", "## 8. Risks", "## 9. Open questions"],
                                           tally: VerdictTally(agree: 33, somewhat: 6, disagree: 2),
                                           annotations: [PlanNote(note: "Keep the dispatcher override"),
                                                         PlanNote(note: "Offline replay must never reorder check-ins")],
                                           note: longNote),
                       startedAt: at(2110)),
            Checkpoint(id: 5, parent: 4, stage: .refine, round: 3, major: true, createdAt: at(3300),
                       record: RoundRecord(slots: [ok("reviewer"), ok("integrator")], changeCount: 3, linesAdded: 12,
                                           linesRemoved: 4, tally: VerdictTally(agree: 3, somewhat: 0, disagree: 0)),
                       startedAt: at(2910)),
            Checkpoint(id: 6, parent: 5, stage: .encode, round: 0, major: true, createdAt: at(3500),
                       record: RoundRecord(slots: [ok("encoder")], changeCount: 27), startedAt: at(3310)),
            Checkpoint(id: 7, parent: 6, stage: .polish, round: 1, major: false, createdAt: at(3800),
                       record: RoundRecord(slots: [ok("polisher")], changeCount: 6, edgesChanged: 2), startedAt: at(3510)),
        ], target: .nextMajor, status: .paused)
        return LiveCard.shaping(intake: intake, tape: tape, activities: [:], records: [:], pending: nil,
                                selectedRound: .constant(nil), openRound: .constant(open),
                                controlBar: { _ in AnyView(self.placeholder("Control bar", height: 44)) },
                                board: { _ in AnyView(self.placeholder("Departures board", height: 90)) })
    }

    private func placeholder(_ label: String, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.12))
            .overlay(Text(label).font(.caption).foregroundStyle(.tertiary))
            .frame(height: height)
    }
}
