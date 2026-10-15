#if DEBUG
import Foundation
import IntakeKit

/// `-FlightDeckPlanningFixture shaping` (with `-FlightDeckResetState YES`): a project with
/// Flight Control on and one shaping plan, open on screen, for `PlanningInspectorUITests`.
///
/// There is no production route to a plan in a UI test — a plan comes from live planning agents
/// spending tokens — so the app writes the files a real plan leaves (the intake, its tape, one
/// draft checkpoint) into a scratch root of its own and reads them through the ordinary
/// `IntakeService` load. The test passes only the flag: the xctrunner sandbox cannot write a
/// folder the app reads, and a fixture rsynced to the UI-test Mac is one more thing to go stale.
///
/// `-FlightDeckPlanningFixture synthesized` seeds the shape of a plan a person has been through:
/// two drafts, a synthesis that read notes written on the drafts, and two refines, each version
/// a long plan of paragraphs and tables (`NotesToolbarUITests`).
///
/// Debug-only and gated on the reset flag like every other UI fixture, so a stray default can
/// never point a real launch's intakes at a scratch directory.
enum PlanningUIFixture {
    /// The scratch root, created and seeded on first read. Nil unless both flags are set.
    static let active: Root? = {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "FlightDeckResetState"),
              let state = defaults.string(forKey: "FlightDeckPlanningFixture"), ["shaping", "synthesized"].contains(state) else { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlightDeck-planning-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let fixture = Root(root: root, synthesized: state == "synthesized")
        do { try fixture.seed() } catch { return nil }
        return fixture
    }()

    struct Root {
        let root: URL
        var synthesized = false
        var project: URL { root.appendingPathComponent("planning-fixture", isDirectory: true) }
        var projectPath: String { project.standardizedFileURL.path }
        var intakesRoot: URL { root.appendingPathComponent("intakes", isDirectory: true) }

        fileprivate func seed() throws {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var intake = Intake(projectPath: projectPath, intent: "Plan the fixture feature")
            intake.state = .shaping
            intake.recommended = .featurePlan
            intake.chosenPreset = .featurePlan
            intake.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)
            let store = IntakeStore(root: intakesRoot)
            try store.save(intake)
            let tapes = TapeStore(intakeDirectory: store.directory(for: intake.id))
            var tape = tapes.loadTape()
            if synthesized { return try seedSynthesized(tapes, into: &tape) }
            try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                      files: ["drafts/0.md": Data(PlanningUIFixture.plan.utf8)], into: &tape)
            // Notes waiting for the next round, unanchored so the rail stacks them: the state a
            // plan someone has been reading is in, and the one whose cards once sized the window.
            tape.pendingNotes = (1...3).map { PlanNote(note: "Fixture note \($0): say more about the rollout and who signs it off.") }
            tape.status = .paused
            try tapes.saveTape(tape)
        }
    }

    /// What the real LarkOS intake looks like: a draft, a synthesis that consumed notes written on
    /// the draft, then refines. No pending notes, so the rail shows only consumed ones.
    private static func seedSynthesized(_ tapes: TapeStore, into tape: inout Tape) throws {
        let versions = (0..<4).map { PlanningUIFixture.longPlan(version: $0) }
        try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                  files: ["drafts/0.md": Data(versions[0].utf8), "drafts/1.md": Data(versions[0].utf8)], into: &tape)
        var record = RoundRecord()
        record.annotations = (1...4).map { n in
            let quote = "Rule \((n - 1) % 3 + 1) of section \(n + 1) holds"
            let range = versions[0].range(of: quote)!
            return PlanNote(kind: n.isMultiple(of: 2) ? .question : .comment, note: "Fixture reply \(n).",
                            anchor: NoteAnchor(checkpoint: 1, selecting: range, in: versions[0]))
        }
        try tapes.writeCheckpoint(Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: Date(), record: record),
                                  files: ["plan.md": Data(versions[1].utf8)], into: &tape)
        for (id, round) in [(3, 1), (4, 2)] {
            try tapes.writeCheckpoint(Checkpoint(id: id, parent: id - 1, stage: .refine, round: round, major: false, createdAt: Date()),
                                      files: ["plan.md": Data(versions[id - 2].utf8)], into: &tape)
        }
        tape.status = .paused
        try tapes.saveTape(tape)
    }

    /// A long plan the way a real one reads: sections of long paragraphs and a table whose cells
    /// are sentences. `version` changes the wording so each checkpoint's text differs.
    static func longPlan(version: Int) -> String {
        var text = "# Fixture implementation plan\n\nThis synthetic plan stands in for a real one and runs to several screens, so the reading position matters. Revision \(version).\n\n"
        for section in 1...12 {
            text += "## Phase \(section): fixture phase \(section)\n\n"
            for rule in 1...3 {
                text += "Rule \(rule) of section \(section) holds that the fixture owner checks the evidence before the next phase begins, and records what each check showed so that a reviewer can repeat it without asking anyone. (Revision \(version).)\n\n"
            }
            text += "| Area | First-release decision | Acceptance boundary |\n| --- | --- | --- |\n"
            for row in 1...3 {
                text += "| Area \(section).\(row) | Any eligible fixture user can create a draft and publish it after automated checks, with the visibility shown before confirmation (revision \(version)). | Guests and external accounts cannot use the result; when an owner restricts it, only listed users can. |\n"
            }
            text += "\n"
        }
        return text
    }

    /// After the store exists: a tab in the project (so the sidebar lists it), its plan
    /// selected, and the project view showing it.
    @MainActor
    static func present(in store: SessionStore, fixture: Root) {
        store.newSession(in: fixture.project)
        guard let repo = store.repos.first(where: { $0.url.standardizedFileURL.path == fixture.projectPath }) else { return }
        let service = store.intakeService
        service.select(service.intakes(forProject: fixture.projectPath).first?.id, inProject: fixture.projectPath)
        store.selectProject(repo.id)
    }

    /// Long enough to scroll several screens, so "the first heading is on screen" means the
    /// document starts at its top rather than somewhere above the window.
    static let plan: String = {
        var text = "# Fixture Plan\n\nA synthetic plan for the planning inspector UI test.\n\n"
        for section in 1...12 {
            text += "## \(section). Fixture section \(section)\n\n"
            for step in 1...5 {
                text += "\(step). Step \(step) of section \(section): do one small, checkable thing and record what it showed.\n"
            }
            text += "\n**Exit evidence:** section \(section) is done when its checks pass.\n\n"
        }
        return text
    }()
}
#endif
