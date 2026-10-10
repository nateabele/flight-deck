import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders the whole intake detail pane — every stage body, the shaping document scrolled far
/// enough to pin its bar, and the inspector — offscreen, dark, at 1100 and 700 pt, for design
/// review. Skipped unless `FD_PLANNING_RENDER_DIR` names an output directory. Pictures, not
/// assertions: layout can be looked at without launching the app (AGENTS.md rule 2).
///
/// Everything is driven through a real `IntakeService` over files on disk — the tape, the
/// checkpoints' plans, the seats' `activity.json` — so the pane is drawn from the same reads the
/// app makes, not from values handed to it.
@MainActor
final class PlanningRenderTests: XCTestCase {
    private var root: URL!
    private let now = Date()
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlanningRenderTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private let round1 = TriageExchange(
        questions: ["Do technicians work from a home depot, or start each day at their first job?",
                    "Is skill match a hard rule, or can a dispatcher override it?"],
        answers: ["Home depot; travel is from there.", "A dispatcher may override it, with a reason."])

    func testRenderEveryStage() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = IntakeStore(root: root)
        let intent = "Build a field-service scheduling platform: technicians, jobs, a dispatch board and mobile check-in"

        func intake(_ state: IntakeState, _ configure: (inout Intake) -> Void = { _ in }) throws -> Intake {
            var i = Intake(projectPath: "/tmp/project", intent: intent, createdAt: now.addingTimeInterval(-3600))
            i.state = state
            i.exchanges = [round1]
            configure(&i)
            try store.save(i)
            return i
        }

        // The service's launch recovery reads a saved `.triaging` intake as interrupted (its turn
        // died with the last app), so it never polls this one's activity: the pane shows the
        // card's "Reading the repo" start. `LiveCardRenderTests` draws a triage seat mid-turn.
        let triaging = try intake(.triaging) { $0.exchanges = [] }
        let asking = try intake(.needsAnswers) {
            $0.exchanges = [self.round1, TriageExchange(questions: [
                "How many technicians does the largest customer run at once?",
                "Should check-in work offline, queueing until the phone reconnects?"])]
        }
        let choosing = try intake(.awaitingChoice) {
            $0.recommended = .fullPlan
            $0.recommendationReason = "Four subsystems with shared rules (skills, dispatch, check-in, notifications): worth a full plan with several drafters."
        }
        let config = RoundConfig(
            drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist, fallback: codex), Slot(claude, persona: .coverage)],
            synthesizer: Slot(claude), reviewer: Slot(codex), integrator: codex, encoder: codex, polisher: codex,
            refinementCap: 3, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor, customized: false)
        let shaping = try intake(.shaping) { $0.chosenPreset = .fullPlan; $0.roundConfig = config }
        let paused = try intake(.shaping) { $0.chosenPreset = .fullPlan; $0.roundConfig = config }
        let pre = Precondition(status: "open", assignee: nil)
        let review = try intake(.review) {
            $0.chosenPreset = .fullPlan
            $0.roundConfig = config
            $0.changeSet = ChangeSet(graphObservedAt: self.now, ops: [
                .createBead(NewBead(tempId: "t1", title: "Technician skills", description: "")),
                .createBead(NewBead(tempId: "t2", title: "Dispatch scoring", description: "")),
                .createBead(NewBead(tempId: "t3", title: "Offline check-in", description: "")),
                .editBead(id: "fd-12", set: FieldSet(description: "Skill match is soft."), pre: pre, delivery: nil),
                .addEdge(from: .new("t2"), to: .new("t1"), kind: .blocks),
                .addEdge(from: .new("t3"), to: .new("t1"), kind: .blocks),
            ])
        }
        let releasing = try intake(.releasing)
        let released = try intake(.released) {
            $0.release = ReleaseRecord(releasedAt: self.now, appliedSteps: 14, idMap: [:], error: nil,
                                       warnings: ["Agent Mail was not reachable; the swarm was not told about 2 tasks."])
        }
        let failed = try intake(.failed) {
            $0.failure = "codex exited 1: rate limited (429) after 3 attempts."
            $0.rawFailureOutput = "{\"type\":\"error\",\"message\":\"429 Too Many Requests\"}"
        }

        try writeTape(for: shaping.id, store: store, running: true)
        try writeTape(for: paused.id, store: store, running: false)
        // Past shaping the tape stays on disk, and the pane reads the final plan from it.
        try writeTape(for: review.id, store: store, running: false)
        try writeTape(for: released.id, store: store, running: false)

        let service = IntakeService(store: store, triageSettings: TriageSettings(agent: .codex, model: "gpt-6-sol", effort: "high"),
                                    availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        service.pollTapes()

        func render(_ name: String, _ intake: Intake, inspector: Bool = false, seat: String? = nil,
                    scrollTo: CGFloat? = nil) throws {
            for width in [1100, 700] as [CGFloat] {
                let view = IntakeDetailView(service: service, intake: intake, onOpenReview: {},
                                            showsInspector: .constant(inspector), selectedSeat: seat)
                try PlanningRender.write(view, size: NSSize(width: width, height: 900),
                                         to: out.appendingPathComponent("planning-\(name)-\(Int(width)).png"),
                                         prepare: scrollTo.map { y in { host in Self.scroll(host, to: y) } })
            }
        }

        try render("triaging", triaging)
        try render("needs-answers", asking)
        try render("awaiting-choice", choosing)
        try render("awaiting-choice-inspector", choosing, inspector: true)
        try render("shaping-running", shaping)
        try render("shaping-paused", paused)
        try render("shaping-pinned", shaping, scrollTo: 700)
        try render("shaping-seat-inspector", shaping, inspector: true, seat: "refine-2-reviewer")
        try render("review", review)
        try render("releasing", releasing)
        try render("released", released)
        try render("failed", failed)

        // The inspector column is an AppKit split pane that `layer.render(in:)` draws blank, so its
        // two contents are rendered on their own at its ideal and minimum widths.
        var edited = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        edited.refinementCap = 5
        edited.customized = true
        let tapes = TapeStore(intakeDirectory: store.directory(for: shaping.id))
        let seat = try XCTUnwrap(LiveSeats.rows(round: PlannedRound(stage: .refine, round: 2, major: false), config: config,
                                                seats: SeatFiles(activities: service.seatActivities[shaping.id] ?? [:],
                                                                 records: service.runRecords[shaping.id] ?? [:],
                                                                 results: service.seatResults[shaping.id] ?? [:]),
                                                now: now).first)
        for width in [440, 300] as [CGFloat] {
            let panel = VStack(alignment: .leading, spacing: 28) {
                RoundConfigEditor(preset: .fullPlan, config: .constant(edited), available: .defaults)
                Divider()
                SeatInspector(model: seat.model, activity: service.seatActivities[shaping.id]?[seat.model.id],
                              runDirectory: tapes.runDirectory(seat.model.id))
            }
            .padding(16)
            try PlanningRender.write(panel, size: NSSize(width: width, height: 900),
                                     to: out.appendingPathComponent("planning-inspector-panel-\(Int(width)).png"))
        }
    }

    /// Renders the release review sheet (spec §10) against a REAL `br` scratch repo — the sheet
    /// loads its own `ReleaseReview` through `SessionStore.intakeService.reviewModel`, which
    /// shells to `br list`/`br graph` with no seam `SessionStore` exposes for a fake runner, so
    /// a picture of the real layout needs the real binary. Skipped when `br` isn't resolvable,
    /// same as `BeadWriterLiveTests`. The scratch project lives under `$HOME`, never `/tmp` —
    /// AGENTS.md / the task brief.
    func testRenderReleaseReview() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
        }
        guard let brPath = Self.resolveBrPath() else {
            throw XCTSkip("br not found at ~/.local/bin/br or on PATH")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let runner = SystemFlywheelProcessRunner()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectDir = "\(home)/.fd-planning-render-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectDir) }
        let (initOut, initCode) = try await runner.run(brPath, ["init"], cwd: projectDir)
        XCTAssertEqual(initCode, 0, "br init failed to set up the scratch repo: \(initOut)")

        func create(_ title: String) async throws -> String {
            let (createOut, code) = try await runner.run(brPath, ["q", title], cwd: projectDir)
            XCTAssertEqual(code, 0, "br q failed: \(createOut)")
            return createOut.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let skillMatch = try await create("Skill match is a soft constraint")
        let dispatchBoard = try await create("Dispatch board v1")

        let store = SessionStore(provider: nil, persistence: FakePersistence(), intakesRoot: root)
        var intake = Intake(projectPath: projectDir,
                            intent: "Build a field-service scheduling platform: technicians, jobs, a dispatch board and mobile check-in",
                            createdAt: now.addingTimeInterval(-3600))
        intake.state = .review
        let pre = Precondition(status: "open", assignee: nil)
        // One of each grouping (spec §10): New tasks (a create, a follow-up), Edits (an edit, a
        // reopen), Dependencies (two edges) — every section on screen at once for review.
        intake.changeSet = ChangeSet(graphObservedAt: now, ops: [
            .createBead(NewBead(tempId: "t1", title: "Technician skills", description: "Skill tags with an expiry date.")),
            .createBead(NewBead(tempId: "t2", title: "Offline check-in", description: "Queue check-ins while offline.")),
            .followUp(tempId: "t3", of: dispatchBoard, title: "Add a v2 auto-assignment mode",
                     description: "Dispatchers asked for this after the pilot.", pre: pre),
            .editBead(id: skillMatch, set: FieldSet(description: "Skill match is soft; a dispatcher may override it with a reason."),
                     pre: pre, delivery: Delivery(rating: .clarifying, reason: "wording only")),
            .reopen(id: dispatchBoard, reason: "Needs one more pass after the dispatch-scoring change.", pre: pre),
            .addEdge(from: .new("t2"), to: .new("t1"), kind: .blocks),
            .addEdge(from: .existing(skillMatch), to: .new("t1"), kind: .blocks),
        ])
        try IntakeStore(root: root).save(intake)

        // The graph the change set was validated against at triage — `reviewModel` refuses to
        // build a `ReleaseReview` without one (`IntakeService.triageGraph`, private, file-only:
        // no injection seam either), so this writes the real `br` read straight to where it
        // looks. Nothing has changed since, so it's also the drift baseline: every op holds.
        let triageGraph = try await IntakeGraphReader(runner: runner, brPath: brPath).read(project: projectDir)
        let triageDir = IntakeStore(root: root).directory(for: intake.id).appendingPathComponent("triage", isDirectory: true)
        try FileManager.default.createDirectory(at: triageDir, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(triageGraph).write(to: triageDir.appendingPathComponent("graph.json"))

        // A checkpoint whose annotation the round consumed, so "N notes carried into task
        // notes" (spec §10) actually shows: `consumedNotesCount` counts a `TapeNote` only once
        // some checkpoint's `record.annotations` names it.
        let tapes = TapeStore(intakeDirectory: IntakeStore(root: root).directory(for: intake.id))
        var tape = Tape()
        try tapes.saveTape(tape)
        try tapes.writeCheckpoint(
            Checkpoint(id: 1, stage: .synthesis, round: 0, major: true, createdAt: now.addingTimeInterval(-900),
                       record: RoundRecord(slots: [], annotations: [PlanNote(note: "Confirm the travel buffer with the pilot region.")]),
                       startedAt: now.addingTimeInterval(-1000)),
            files: [:], into: &tape)
        tape.status = .paused
        try tapes.saveTape(tape)

        // `reviewModel()` hops off `IntakeService`'s `@MainActor` isolation for its real `br`
        // reads and back again; `PlanningRender.write`'s offscreen render only pumps
        // `RunLoop.run(until:)` synchronously, which never redelivers that hop-back (GCD's
        // main-queue drain doesn't reenter itself mid-frame), so the sheet's own `.task` would
        // spin forever on screen. Loading it here, with a real `await`, and handing the result
        // in as `previewReview` sidesteps that — `.task` still fires and reloads over it, but
        // only after the snapshot is already taken.
        let loaded = await store.intakeService.reviewModel(intake.id)
        let review = try XCTUnwrap(loaded)

        let view = ReleaseReviewView(store: store, intakeID: intake.id, onClose: {}, previewReview: review)
        try PlanningRender.write(view, size: NSSize(width: 680, height: 620),
                                 to: out.appendingPathComponent("planning-release-review.png"))
    }

    /// The shaping screen's three convergence states (`ConvergenceFixture`, shared with
    /// `ConvergenceRenderTests`) at both control-bar widths — 1100 pt is `ConvergenceRenderTests`'
    /// own focus, so this fills in the 700 pt the compact bar takes for converging and plateau
    /// too (diverging's own 700 pt render already exists there).
    func testRenderConvergenceStatesAtBothWidths() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
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
            intake.exchanges = [round1]
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
            for width in [1100, 700] as [CGFloat] {
                try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {}),
                                         size: NSSize(width: width, height: 1500),
                                         to: out.appendingPathComponent("planning-convergence-\(scenario.name)-\(Int(width)).png"))
            }
        }
    }

    /// `~/.local/bin/br` first — where `br` actually lives in this environment, and a headless
    /// `xcodebuild test` process's PATH is not guaranteed to include it — then the process's own
    /// PATH, so a host with `br` installed conventionally still finds it. Same lookup as
    /// `BeadWriterLiveTests`.
    private static func resolveBrPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let localBin = "\(home)/.local/bin/br"
        if FileManager.default.isExecutableFile(atPath: localBin) { return localBin }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/br"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private final class FakePersistence: SessionPersisting {
        func load() -> SessionSnapshot? { nil }
        func save(_ snapshot: SessionSnapshot) {}
    }

    /// What a seat beat redraws, counted (`RenderProbe`) in a real pane over a real service: the
    /// live card, and not the pane, its header, its Clarifications or its plan. And a publish
    /// the pane does observe re-evaluates the pane, but not those three, whose inputs didn't
    /// change. Before the seat maps moved to `SeatFeed`, every beat re-evaluated all of it.
    func testASeatBeatRedrawsTheLiveCardAlone() throws {
        let store = IntakeStore(root: root)
        let config = RoundConfig(
            drafters: [Slot(codex, persona: .arbiter)], synthesizer: Slot(claude), reviewer: Slot(codex), integrator: codex,
            encoder: codex, polisher: codex, refinementCap: 3, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor,
            customized: false)
        var intake = Intake(projectPath: "/tmp/project", intent: "Build the dispatch board", createdAt: now)
        intake.state = .shaping
        intake.exchanges = [round1]
        intake.chosenPreset = .fullPlan
        intake.roundConfig = config
        try store.save(intake)
        try writeTape(for: intake.id, store: store, running: true)
        let service = IntakeService(store: store, triageSettings: TriageSettings(agent: .codex, model: "gpt-6-sol", effort: "high"),
                                    availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        service.pollTapes()

        let size = NSSize(width: 1100, height: 900)
        let host = NSHostingView(rootView: IntakeDetailView(service: service, intake: intake, onOpenReview: {})
            .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // A seat beat: the integrator's activity file moves on.
        let activity = TapeStore(intakeDirectory: store.directory(for: intake.id)).runDirectory("refine-2-integrator")
            .appendingPathComponent("activity.json")
        var moved = SeatActivity(agent: .codex, startedAt: now.addingTimeInterval(-41))
        moved.headline = "Checking the ranking against §2"
        try write(moved, to: activity)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(30)], ofItemAtPath: activity.path)
        RenderProbe.reset()
        service.pollTapes()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let beat = RenderProbe.counts
        XCTAssertEqual(service.seatActivities[intake.id]?["refine-2-integrator"]?.headline, "Checking the ranking against §2")
        XCTAssertGreaterThan(beat["liveCard"] ?? 0, 0, "the card redraws with the seat: \(beat)")
        for part in ["detail", "header", "clarifications", "plan"] {
            XCTAssertEqual(beat[part] ?? 0, 0, "a seat beat redrew \(part): \(beat)")
        }

        // A publish the pane observes: the pane re-evaluates, its value-typed parts don't.
        RenderProbe.reset()
        service.select(intake.id, inProject: intake.projectPath)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        let publish = RenderProbe.counts
        XCTAssertGreaterThan(publish["detail"] ?? 0, 0, "the probe sees the pane redraw: \(publish)")
        for part in ["header", "clarifications", "plan"] {
            XCTAssertEqual(publish[part] ?? 0, 0, "unchanged inputs redrew \(part): \(publish)")
        }
    }

    /// A shaping intake whose plan runs to ~250 lines, drawn at the document's top, scrolled so
    /// the plan's middle is under the pinned block, and at the document's end — the pictures for
    /// "the plan is part of the page": one scroller, the plan's text rendered wherever the page
    /// is scrolled to, nothing clipped under the pinned block. Files are `onescroll-*`.
    func testRenderLongPlanScrollsAsOneDocument() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the planning PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let store = IntakeStore(root: root)
        let config = RoundConfig(
            drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist)], synthesizer: Slot(claude),
            reviewer: Slot(codex), integrator: codex, encoder: codex, polisher: codex,
            refinementCap: 3, polishCap: 2, freshEyesAndDedup: true, defaultPlay: .nextMajor, customized: false)
        var intake = Intake(projectPath: "/tmp/project", intent: "Build a field-service scheduling platform: technicians, jobs, a dispatch board and mobile check-in",
                            createdAt: now.addingTimeInterval(-3600))
        intake.state = .shaping
        intake.exchanges = [round1]
        intake.chosenPreset = .fullPlan
        intake.roundConfig = config
        try store.save(intake)
        try writeTape(for: intake.id, store: store, running: true, plan: Self.longPlan)
        let service = IntakeService(store: store, triageSettings: TriageSettings(agent: .codex, model: "gpt-6-sol", effort: "high"),
                                    availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        service.pollTapes()
        for (name, y) in [("top", 0), ("plan", 2400), ("end", .infinity)] as [(String, CGFloat)] {
            try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {}),
                                     size: NSSize(width: 1100, height: 900),
                                     to: out.appendingPathComponent("onescroll-\(name)-1100.png"),
                                     // One scroll, even to the end: the plan was laid out whole after
                                     // it loaded, so the page's end is where it will stay.
                                     prepare: y == 0 ? nil : { host in Self.scroll(host, to: y) })
        }
    }

    /// `plan` followed by thirty more sections — long enough that the page, not a box, is what
    /// has to scroll to reach its end.
    private static let longPlan = plan + (8...37).map { i in
        """


        ## \(i). Section \(i)
        Section \(i) of the plan. Dispatchers see every technician's next job, and the board re-ranks within a second of a change.
        - Rule \(i).a: a job keeps its technician once en route.
        - Rule \(i).b: an override needs a reason, which is kept with the job.
        """
    }.joined()

    // MARK: - Fixtures

    /// Draft, synthesis and refine 1 landed; refine 2 running with a finished reviewer and a
    /// working integrator — or, `running: false`, paused after refine 1.
    private func writeTape(for id: UUID, store: IntakeStore, running: Bool, plan: String = PlanningRenderTests.plan) throws {
        let tapes = TapeStore(intakeDirectory: store.directory(for: id))
        let slot = { (role: String, used: ModelChoice) in SlotOutcome(role: role, used: used, requested: used, status: .ok) }
        var tape = Tape()
        try tapes.saveTape(tape)
        try tapes.writeCheckpoint(
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: now.addingTimeInterval(-1500),
                       record: RoundRecord(slots: [slot("drafter", codex), slot("drafter", claude), slot("drafter", claude)],
                                           linesAdded: 212),
                       startedAt: now.addingTimeInterval(-1800)),
            files: ["drafts/0.md": Data(plan.utf8)], into: &tape)
        try tapes.writeCheckpoint(
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: now.addingTimeInterval(-1100),
                       record: RoundRecord(slots: [slot("synthesizer", claude), slot("integrator", codex)], changeCount: 14,
                                           linesAdded: 42, linesRemoved: 17, sectionsChanged: ["## 2. Technicians", "## 4. Dispatch rules"],
                                           tally: VerdictTally(agree: 11, somewhat: 2, disagree: 1)),
                       startedAt: now.addingTimeInterval(-1480)),
            files: ["plan.md": Data(plan.utf8)], into: &tape)
        try tapes.writeCheckpoint(
            Checkpoint(id: 3, parent: 2, stage: .refine, round: 1, major: false, createdAt: now.addingTimeInterval(-700),
                       record: RoundRecord(slots: [slot("reviewer", codex), slot("integrator", codex)], changeCount: 9,
                                           linesAdded: 21, linesRemoved: 8, sectionsChanged: ["## 4. Dispatch rules"],
                                           tally: VerdictTally(agree: 7, somewhat: 1, disagree: 1)),
                       startedAt: now.addingTimeInterval(-1090)),
            files: ["plan.md": Data(plan.utf8)], into: &tape)
        if running {
            tape.target = .nextMajor
            tape.status = .running
            tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
            tape.roundStartedAt = now.addingTimeInterval(-200)
            tape.heartbeat = now
            var reviewer = SeatActivity(agent: .codex, startedAt: now.addingTimeInterval(-199))
            reviewer.footprint = ["Dispatch": 7, "Core": 4, "docs": 2, "Mobile": 1, "Tests": 3]
            reviewer.inputTokens = 96_000
            reviewer.outputTokens = 7_400
            reviewer.finished = true
            var integrator = SeatActivity(agent: .codex, startedAt: now.addingTimeInterval(-41))
            integrator.headline = "Applying the §4 ranking change"
            integrator.action = ActivityAction(verb: "Editing", object: "plan.md")
            integrator.inputTokens = 52_000
            integrator.lastEventAt = now.addingTimeInterval(-3)
            try write(reviewer, to: tapes.runDirectory("refine-2-reviewer").appendingPathComponent("activity.json"))
            try write(RunRecord(started: now.addingTimeInterval(-199), finished: now.addingTimeInterval(-44), exitCode: 0),
                      to: tapes.runDirectory("refine-2-reviewer").appendingPathComponent("run.json"))
            try write(SeatResult(kind: .reviewer, changeCount: 6, sections: ["## 4. Dispatch rules", "## 5. Mobile check-in"]),
                      to: tapes.runDirectory("refine-2-reviewer").appendingPathComponent("result.json"))
            try write(integrator, to: tapes.runDirectory("refine-2-integrator").appendingPathComponent("activity.json"))
        } else {
            tape.status = .paused
        }
        try tapes.saveTape(tape)
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(value).write(to: url)
    }

    /// Scrolls the document — the outermost vertical scroll view in the pane — to `y`, or to its
    /// end for `.infinity`.
    private static func scroll(_ host: NSView, to y: CGFloat) {
        var queue: [NSView] = [host]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scroll = view as? NSScrollView, scroll.hasVerticalScroller || scroll.documentView?.frame.height ?? 0 > scroll.frame.height {
                let end = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(y, end)))
                scroll.reflectScrolledClipView(scroll.contentView)
                return
            }
            queue.append(contentsOf: view.subviews)
        }
    }

    private static let plan = """
    # Field-service scheduling platform

    ## 1. Overview
    larkOS schedules field-service work for mid-size HVAC and electrical contractors. A dispatcher assigns jobs on a live board, and technicians check in from the site on their phones.

    ## 2. Technicians
    Each technician has a skill set, a home depot and a shift. Skills are tags (`hvac.commercial`, `electrical.l2`) with an optional expiry date for certifications.

    ## 3. Jobs
    A job has a site, a time window, the skills it needs and a status: `unassigned`, `assigned`, `enRoute`, `onSite`, `done` or `cancelled`.

    ## 4. Dispatch rules
    - A job is offered to the best-scoring available technician.
    - Skill match is a **soft** constraint: a dispatcher may override it with a reason.
    - Availability and the travel buffer are hard constraints; the buffer defaults to 15 minutes.

    ## 5. Mobile check-in
    Check-ins queue in `CheckInOutbox` while offline and replay oldest-first on reconnect.

    ## 6. Notifications
    The customer gets an SMS when the technician is en route, with a live ETA link.

    ## 7. Testing
    Dispatch scoring is a pure function with table tests.
    """
}
