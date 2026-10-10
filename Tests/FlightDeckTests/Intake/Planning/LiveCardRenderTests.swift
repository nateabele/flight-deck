import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `LiveCard` offscreen to PNGs for design review — skipped by default. Set
/// `FD_INTAKE_RENDER_DIR` to an output directory to run it; it writes `pui-livecard-*.png` at
/// 1100 pt, dark. A picture rather than an assertion, like `SplitFlapTextRenderTests`: the rows
/// can be looked at without launching the app (AGENTS.md rule 2). The control bar and board are
/// placeholders — they are separate views the card only positions.
@MainActor
final class LiveCardRenderTests: XCTestCase {
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")
    private let now = Date()

    private func dir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_INTAKE_RENDER_DIR"] else {
            throw XCTSkip("set FD_INTAKE_RENDER_DIR to render the live-card PNGs")
        }
        return URL(fileURLWithPath: dir)
    }

    private func activity(_ agent: AgentID, ago: TimeInterval, headline: String? = nil, verb: String? = nil,
                          object: String? = nil, footprint: [String: Int] = [:], steps: ActivitySteps? = nil,
                          tokens: Int? = nil, quietFor: TimeInterval = 2) -> SeatActivity {
        var a = SeatActivity(agent: agent, startedAt: now.addingTimeInterval(-ago))
        a.headline = headline
        a.action = verb.map { ActivityAction(verb: $0, object: object) }
        a.footprint = footprint
        a.steps = steps
        a.inputTokens = tokens
        a.lastEventAt = now.addingTimeInterval(-quietFor)
        return a
    }

    func testRenderTriage() throws {
        let out = try dir()
        var intake = Intake(projectPath: "/tmp/project", intent: "Scheduling platform for field technicians")
        intake.triage = HeadlessSession(agent: .codex, sessionID: "s", model: "gpt-6-sol", effort: "high")
        let running = activity(.codex, ago: 134, headline: "Checking whether dispatch already has a notion of skills",
                               verb: "Reading", object: "Sources/Dispatch/Assigner.swift",
                               footprint: ["Sources": 14, "Tests": 6, "docs": 3, ".": 2, "scripts": 1, "work": 4],
                               steps: ActivitySteps(done: 2, total: 5, current: "Map the job lifecycle"), tokens: 118_000)
        var answered = intake
        answered.state = .triaging
        let view = VStack(alignment: .leading, spacing: 18) {
            caption("Triage · running")
            LiveCard.triage(intake: intake, activity: running, pending: nil)
            caption("Triage · just sent answers (pending, 0:03)")
            LiveCard.triage(intake: answered, activity: nil,
                            pending: PendingStart(kind: .triage, since: now.addingTimeInterval(-3)))
            caption("Triage · silent 17 s (queued)")
            LiveCard.triage(intake: answered, activity: nil,
                            pending: PendingStart(kind: .triage, since: now.addingTimeInterval(-17), queued: true))
        }
        try render(view, to: out.appendingPathComponent("pui-livecard-triage.png"))
    }

    /// Draft round: one seat running, one fallen back (amber), one finished with its result. A
    /// draft round has no finished rounds before it, so the cards are in the refine render below.
    func testRenderShapingDraftSeats() throws {
        let out = try dir()
        let intake = try shapingIntake()
        let tape = Tape(target: .nextMajor, status: .running, roundInProgress: PlannedRound(stage: .draft, round: 0, major: true),
                        roundStartedAt: now.addingTimeInterval(-252))
        var failed = SeatActivity(agent: .claude, startedAt: now.addingTimeInterval(-252))
        failed.finished = true; failed.error = "exited 1"
        var done = activity(.claude, ago: 250, footprint: ["Sources": 9, "docs": 2, "Tests": 3])
        done.finished = true; done.costUSD = 0.61
        let activities: [String: SeatActivity] = [
            "draft-0-drafter-0": activity(.codex, ago: 252, headline: "Tightening §4 so skill match is a soft constraint",
                                          verb: "Editing", object: "drafts/0.md",
                                          footprint: ["Dispatch": 9, "Core": 4, "docs": 2, "Mobile": 1, "Tests": 3, "Sync": 1],
                                          steps: ActivitySteps(done: 2, total: 6, current: "Rewrite the §4 ranking rule"),
                                          tokens: 118_000),
            "draft-0-drafter-1": failed,
            "draft-0-drafter-1-fallback": activity(.codex, ago: 172, headline: "Questioning whether offline replay can reorder check-ins",
                                                   verb: "Searching", object: "\"retryQueue\"",
                                                   footprint: ["Mobile": 6, "Core": 3], tokens: 64_000),
            "draft-0-drafter-2": done,
        ]
        let records = ["draft-0-drafter-2": RunRecord(started: now.addingTimeInterval(-250), finished: now.addingTimeInterval(-39),
                                                      exitCode: 0)]
        let results = ["draft-0-drafter-2": SeatResult(kind: .draft, linesAdded: 212)]
        let view = LiveCard.shaping(intake: intake, tape: tape, activities: activities, records: records, results: results,
                                    pending: nil,
                                    controlBar: { _ in AnyView(self.placeholder("Control bar", height: 44)) },
                                    board: { _ in AnyView(self.placeholder("Departures board", height: 120)) })
        try render(view.padding(20), to: out.appendingPathComponent("pui-livecard-shaping.png"))
    }

    /// Refine 1 after draft and synthesis landed: a finished reviewer with its result, a running
    /// integrator (quiet), the two finished rounds as cards and a queued note.
    func testRenderShapingRefineWithFinishedRounds() throws {
        let out = try dir()
        let intake = try shapingIntake()
        let slot = { (role: String, status: SlotStatus) in
            SlotOutcome(role: role, used: self.codex, requested: self.codex, status: status)
        }
        let tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: now.addingTimeInterval(-900),
                       record: RoundRecord(slots: [slot("drafter", .ok), slot("drafter", .substituted), slot("drafter", .ok)],
                                           note: "Three drafts; the realist fell back to codex."),
                       startedAt: now.addingTimeInterval(-1200)),
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: now.addingTimeInterval(-500),
                       record: RoundRecord(slots: [slot("synthesizer", .ok), slot("integrator", .ok)], changeCount: 14,
                                           linesAdded: 42, linesRemoved: 17,
                                           sectionsChanged: ["## 2. Scope", "## 4. Dispatch", "## 7. Rollout", "## 8. Risks"],
                                           tally: VerdictTally(agree: 11, somewhat: 2, disagree: 1)),
                       startedAt: now.addingTimeInterval(-880)),
        ], target: .nextMajor, status: .running, pendingNotes: [PlanNote.legacy("Keep the dispatcher override", index: 0)],
           // crossCheck: true (coverage spec §3) — Refine 1 is firstAndLast's first round, so the
           // seat list carries the cross-check agent row between reviewer and integrator.
           roundInProgress: PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true),
           roundStartedAt: now.addingTimeInterval(-200))
        var reviewer = activity(.codex, ago: 200, footprint: ["Dispatch": 7, "Core": 4, "docs": 2])
        reviewer.finished = true
        let activities: [String: SeatActivity] = [
            "refine-1-reviewer": reviewer,
            "refine-1-crossReviewer": activity(.claude, ago: 200, headline: "Checking §4 against the mobile check-in flow",
                                               verb: "Reading", object: "plan.md", footprint: ["Mobile": 5, "Dispatch": 2],
                                               tokens: 71_000, quietFor: 12),
            "refine-1-integrator": activity(.codex, ago: 41, headline: "Applying the §4 ranking change",
                                            verb: "Editing", object: "plan.md", footprint: ["work": 1], tokens: 52_000,
                                            quietFor: 36),
        ]
        let records = ["refine-1-reviewer": RunRecord(started: now.addingTimeInterval(-200), finished: now.addingTimeInterval(-44),
                                                      exitCode: 0)]
        let results = ["refine-1-reviewer": SeatResult(kind: .reviewer, changeCount: 14,
                                                       sections: ["## 2. Scope", "## 4. Dispatch", "## 7. Rollout"])]
        let view = LiveCard.shaping(intake: intake, tape: tape, activities: activities, records: records, results: results,
                                    pending: nil,
                                    controlBar: { _ in AnyView(self.placeholder("Control bar", height: 44)) },
                                    board: { _ in AnyView(self.placeholder("Departures board", height: 120)) })
        try render(view.padding(20), to: out.appendingPathComponent("pui-livecard-shaping-refine.png"))
    }

    private func shapingIntake() throws -> Intake {
        var intake = Intake(projectPath: "/tmp/project", intent: "Scheduling platform for field technicians")
        intake.state = .shaping
        intake.roundConfig = RoundConfig(
            drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist, fallback: codex), Slot(claude, persona: .coverage)],
            synthesizer: Slot(claude), reviewer: Slot(codex), integrator: codex, encoder: codex, polisher: codex,
            refinementCap: 3, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor, customized: false,
            crossReviewer: Slot(claude), crossCheck: .firstAndLast)
        return intake
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
    }

    private func placeholder(_ label: String, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.35))
            .overlay(Text(label).font(.caption).foregroundStyle(.tertiary))
            .frame(height: height)
    }

    /// Parked offscreen `NSHostingView` + `layer.render(in:)` — screencapture is denied here,
    /// and `cacheDisplay` drops layer-backed SwiftUI content. Height is whatever the card needs
    /// at 1100 pt.
    private func render(_ view: some View, to url: URL) throws {
        let width: CGFloat = 1100
        let sized = view.frame(width: width, alignment: .topLeading)
            .padding(.vertical, 20)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: sized)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let height = ceil(host.fittingSize.height)
        let size = NSSize(width: width, height: height)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        // Bitmap contexts are bottom-left origin and the hosting view is flipped.
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(host.layer).render(in: context)
        window.orderOut(nil)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
