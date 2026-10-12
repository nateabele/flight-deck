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
/// Debug-only and gated on the reset flag like every other UI fixture, so a stray default can
/// never point a real launch's intakes at a scratch directory.
enum PlanningUIFixture {
    /// The scratch root, created and seeded on first read. Nil unless both flags are set.
    static let active: Root? = {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "FlightDeckResetState"),
              let state = defaults.string(forKey: "FlightDeckPlanningFixture"), state == "shaping" else { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlightDeck-planning-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let fixture = Root(root: root)
        do { try fixture.seed() } catch { return nil }
        return fixture
    }()

    struct Root {
        let root: URL
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
            try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                      files: ["drafts/0.md": Data(PlanningUIFixture.plan.utf8)], into: &tape)
            // Notes waiting for the next round, unanchored so the rail stacks them: the state a
            // plan someone has been reading is in, and the one whose cards once sized the window.
            tape.pendingNotes = (1...3).map { PlanNote(note: "Fixture note \($0): say more about the rollout and who signs it off.") }
            tape.status = .paused
            try tapes.saveTape(tape)
        }
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
