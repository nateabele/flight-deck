import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The plan as a reader sees it — a long, real-looking plan in the shaping pane at 1100 pt, light
/// and dark, at the plan's start and scrolled into its middle under the pinned block — for
/// judging the editor's typography, its folded sections and its outline cues by eye. Skipped
/// unless `FD_PLANNING_RENDER_DIR` names an output directory; `FD_READABLE_TAG` prefixes the
/// files (`readable-<tag>-…`, default `after`) so a before/after pair can sit side by side.
@MainActor
final class PlanReadableRenderTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlanReadableRenderTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testRenderReadablePlan() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
        }
        let tag = ProcessInfo.processInfo.environment["FD_READABLE_TAG"] ?? "after"
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (service, intake) = try shapingIntake()
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for width in [1100, 1600] as [CGFloat] {
                for (place, offset) in [("top", -380), ("code", 500)] as [(String, CGFloat)] {
                    try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {}),
                                             size: NSSize(width: width, height: 900),
                                             to: out.appendingPathComponent("readable-\(tag)-\(Int(width))-\(place)-\(name).png"),
                                             appearance: appearance,
                                             prepare: { host in Self.scrollToPlan(host, offset: offset) })
                }
            }
        }
    }

    /// The outline cue: scrolled into §5, whose heading is under the pinned block, so the pinned
    /// board's footer names it. (The rejected variants' pictures are kept beside these:
    /// `readable-cue-rail-*`, `readable-cue-marker-*`, and the in-text `readable-cue-breadcrumb-*`.)
    func testRenderOutlineCue() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        let (service, intake) = try shapingIntake()
        for (appearance, tone) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {}),
                                     size: NSSize(width: 1100, height: 900),
                                     to: out.appendingPathComponent("readable-cue-footer-\(tone).png"),
                                     appearance: appearance,
                                     prepare: { host in Self.scrollToPlan(host, offset: 1250) })
        }
    }

    /// Folds two sections through the editor itself, then renders them folded.
    func testRenderFoldedSections() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        let (service, intake) = try shapingIntake()
        let store = service.planFolds(intake.id)
        let headings = PlanOutline.headings(MarkdownStyler.blocks(Self.plan), in: Self.plan as NSString)
        for line in ["## 2. Technicians", "## 3. Jobs"] {
            store.folds.set(headings.first { $0.key.text == line }!.key, folded: true)
        }
        for (appearance, tone) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {}),
                                     size: NSSize(width: 1100, height: 900),
                                     to: out.appendingPathComponent("readable-folded-\(tone).png"),
                                     appearance: appearance,
                                     prepare: { host in Self.scrollToPlan(host, offset: -330) })
        }
    }

    // MARK: - Fixture

    /// A shaping intake, paused after its first refine, whose plan is `Self.plan`.
    private func shapingIntake() throws -> (IntakeService, Intake) {
        let store = IntakeStore(root: root)
        let config = RoundConfig(
            drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist)], synthesizer: Slot(claude),
            reviewer: Slot(codex), integrator: codex, encoder: codex, polisher: codex,
            refinementCap: 3, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor, customized: false)
        var intake = Intake(projectPath: "/tmp/project",
                            intent: "Build a field-service scheduling platform: technicians, jobs, a dispatch board and mobile check-in",
                            createdAt: now.addingTimeInterval(-3600))
        intake.state = .shaping
        intake.chosenPreset = .fullPlan
        intake.roundConfig = config
        try store.save(intake)
        let tapes = TapeStore(intakeDirectory: store.directory(for: intake.id))
        let slot = { (role: String, used: ModelChoice) in SlotOutcome(role: role, used: used, requested: used, status: .ok) }
        var tape = Tape()
        try tapes.saveTape(tape)
        try tapes.writeCheckpoint(
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: now.addingTimeInterval(-1500),
                       record: RoundRecord(slots: [slot("drafter", codex), slot("drafter", claude)], linesAdded: 212),
                       startedAt: now.addingTimeInterval(-1800)),
            files: ["drafts/0.md": Data(Self.plan.utf8)], into: &tape)
        try tapes.writeCheckpoint(
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: now.addingTimeInterval(-1100),
                       record: RoundRecord(slots: [slot("synthesizer", claude), slot("integrator", codex)], changeCount: 14,
                                           linesAdded: 42, linesRemoved: 17, sectionsChanged: ["## 4. Dispatch rules"],
                                           tally: VerdictTally(agree: 11, somewhat: 2, disagree: 1)),
                       startedAt: now.addingTimeInterval(-1480)),
            files: ["plan.md": Data(Self.plan.utf8)], into: &tape)
        tape.status = .paused
        try tapes.saveTape(tape)
        let service = IntakeService(store: store, triageSettings: TriageSettings(agent: .codex, model: "gpt-6-sol", effort: "high"),
                                    availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        service.pollTapes()
        return (service, intake)
    }

    /// Scrolls the document so the plan's text starts `offset` points above the viewport's top
    /// (negative: below it).
    static func scrollToPlan(_ host: NSView, offset: CGFloat) {
        guard let text = find(PlanNSTextView.self, in: host), let scroll = outerScroll(host),
              let document = scroll.documentView else { return }
        let top = text.convert(NSPoint.zero, to: document).y
        let end = max(0, document.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(top + offset, 0), end)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    static func outerScroll(_ host: NSView) -> NSScrollView? {
        var queue: [NSView] = [host]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller || scroll.documentView?.frame.height ?? 0 > scroll.frame.height {
                return scroll
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    /// A plan the way the rounds write it now: one line per paragraph (no hard wraps), headings
    /// two and three deep, lists that wrap, a code fence holding a `#` comment, a quote, a table.
    static let plan = """
    # Field-service scheduling platform

    larkOS schedules field-service work for mid-size HVAC and electrical contractors. A dispatcher assigns jobs on a live board, technicians check in from the site on their phones, and customers are told when someone is on the way. This plan covers the first release: the data model, the dispatch rules, mobile check-in and the notifications that tie them together.

    ## 1. Overview

    The platform replaces a whiteboard and a group chat. Every job is a row on the dispatch board with its site, its time window and the skills it needs; every technician is a lane with their shift, their home depot and the jobs already on it. A dispatcher drags a job onto a lane, or accepts the board's suggestion, and the technician's phone shows it within a second.

    > Out of scope for this release: invoicing, parts inventory and customer self-booking. Each is a later plan of its own.

    ## 2. Technicians

    Each technician has a skill set, a home depot and a shift. Skills are tags such as `hvac.commercial` or `electrical.l2`, each with an optional expiry date for certifications that lapse.

    - A technician whose certification has expired keeps the tag but loses it for matching until it is renewed, so history still shows what they were qualified for at the time.
    - Shifts repeat weekly and can be overridden for a single day without touching the pattern.
    - A technician may belong to more than one depot; travel is always measured from the depot of the day.

    ### 2.1 Availability

    A technician is available for a job when the job's window fits inside their shift, no other job overlaps it once the travel buffer is added, and they are not marked off sick. Availability is recomputed on every change to either side, never cached past the change.

    ## 3. Jobs

    A job has a site, a time window, the skills it needs and a status: `unassigned`, `assigned`, `enRoute`, `onSite`, `done` or `cancelled`. Status moves forward only, except that a dispatcher may move an `assigned` job back to `unassigned` with a reason.

    | Status | Set by | Visible to customer |
    |---|---|---|
    | assigned | dispatcher | no |
    | enRoute | technician | yes, with ETA |
    | onSite | technician | yes |
    | done | technician | yes |

    ## 4. Dispatch rules

    The board suggests the best-scoring available technician for each unassigned job. Scoring is a pure function of the job, the technician and the day's schedule, so the same inputs always give the same suggestion and it can be tested with tables.

    1. Hard constraints first: availability, the travel buffer (15 minutes by default) and the job's window. A technician who fails one is never suggested.
    2. Skill match is a **soft** constraint: a dispatcher may override it, and the override's reason is kept with the job.
    3. Among the rest, the shortest travel from the previous job wins; ties go to the technician with fewer jobs that day.

    ```swift
    # A heading-looking line inside a fence is code, not a section.
    func score(_ job: Job, _ tech: Technician, on day: Schedule) -> Double? {
        guard day.isAvailable(tech, for: job.window, buffer: .minutes(15)) else { return nil }
        return travel(from: day.previousSite(tech, before: job), to: job.site).minutes
    }
    ```

    ### 4.1 Overrides

    An override is recorded with who made it, when, and why. The board shows an overridden assignment with a small mark so a second dispatcher does not undo it by accident.

    ## 5. Mobile check-in

    Check-ins queue in `CheckInOutbox` while the phone is offline and replay oldest-first on reconnect. A replayed check-in keeps the time it was made, not the time it was sent, so the job's history reads the way the day happened.

    - The phone shows today's jobs in order, with the next one expanded.
    - Tapping *On my way* sets `enRoute` and starts sharing an ETA with the customer.
    - Tapping *Arrived* sets `onSite`; *Done* asks for a note and an optional photo.

    ## 6. Notifications

    The customer gets an SMS when the technician is en route, with a live ETA link that expires when the job is done. Dispatchers get a banner when a job's window is at risk: when the assigned technician's ETA runs past the window's start.

    ## 7. Testing

    Dispatch scoring is a pure function with table tests covering every hard constraint and each tie-break. Check-in replay is tested against a fake outbox with the clock passed in. The board's drag and drop is covered by one UI test per status transition.

    ## 8. Rollout

    Two contractors run the first release for four weeks alongside their whiteboard. The release ships when both have gone a full week without using the whiteboard for anything the board can do.
    """
}
