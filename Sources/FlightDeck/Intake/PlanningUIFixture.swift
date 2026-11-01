#if DEBUG
import CryptoKit
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
/// `-FlightDeckPlanningFixture threads` seeds the `shaping` plan with one ask thread that has
/// already answered with a pending diff on the plan's opening sentence (`AskThreadUITests`). No
/// ThreadRunner is started under it (`startsThreadRunner`): a turn would run a real agent CLI on
/// the UI-test Mac and spend tokens, so an Ask sent in the test stays queued.
///
/// `-FlightDeckPlanningFixture visuals` seeds the `shaping` plan with one Mermaid `fd-visual` block
/// near its top, stored in two sizes (`VisualSizeUITests`). The fixture writes the block's
/// `visuals/` folder itself, the one writer of it besides ThreadRunner, because no ThreadRunner
/// makes visuals yet; it is a UI-test seed, like the rest of this file.
///
/// Debug-only and gated on the reset flag like every other UI fixture, so a stray default can
/// never point a real launch's intakes at a scratch directory.
enum PlanningUIFixture {
    /// The scratch root, created and seeded on first read. Nil unless both flags are set.
    static let active: Root? = {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "FlightDeckResetState"),
              let state = defaults.string(forKey: "FlightDeckPlanningFixture"), ["shaping", "synthesized", "threads", "visuals"].contains(state) else { return nil }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlightDeck-planning-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        let fixture = Root(root: root, synthesized: state == "synthesized", threads: state == "threads",
                           visuals: state == "visuals")
        do { try fixture.seed() } catch { return nil }
        return fixture
    }()

    struct Root {
        let root: URL
        var synthesized = false
        var threads = false
        var visuals = false
        /// False under the `threads` fixture: see the type's comment.
        var startsThreadRunner: Bool { !threads && !visuals }
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
            let text = visuals ? PlanningUIFixture.visualPlan : PlanningUIFixture.plan
            try tapes.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                                      files: ["drafts/0.md": Data(text.utf8)], into: &tape)
            if visuals { try PlanningUIFixture.seedVisual(tapes) }
            // Notes waiting for the next round, unanchored so the rail stacks them: the state a
            // plan someone has been reading is in, and the one whose cards once sized the window.
            tape.pendingNotes = (1...3).map { PlanNote(note: "Fixture note \($0): say more about the rollout and who signs it off.") }
            tape.status = .paused
            try tapes.saveTape(tape)
            if threads { try PlanningUIFixture.seedThread(in: tapes.intakeDirectory) }
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

    static let threadTitle = "Is the opening sentence right?"
    static let threadReply = "It undersells the fixture. I propose saying what the plan is for."
    static let threadOld = "A synthetic plan for the planning inspector UI test."
    static let threadNew = "A synthetic plan that an ask thread has edited."

    /// One thread, as ThreadRunner leaves it after a turn: the record, one answered turn, and a
    /// pending diff on the plan's opening sentence (which occurs once).
    private static func seedThread(in intake: URL) throws {
        let store = ThreadStore(intakeDirectory: intake)
        let id = ThreadID()
        let anchor = NoteAnchor(checkpoint: 1, selecting: plan.range(of: threadOld)!, in: plan)
        let record = ThreadRecord(id: id, title: threadTitle, anchor: ThreadAnchor(note: anchor), status: .needsYou,
                                  agent: .claude, model: "fixture", effort: "high", followsCheckpoint: 1, createdAt: Date())
        let dir = store.directory(id)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("diffs"), withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(record).write(to: dir.appendingPathComponent("thread.json"), options: .atomic)
        let line = JSONEncoder()
        line.dateEncodingStrategy = IntakeJSON.encoder.dateEncodingStrategy
        let turn = ThreadTurn(seq: 1, messageID: "fixture-1", you: "Is this the right way to open the plan?", reply: threadReply,
                              decision: "Say what the plan is for.",
                              actions: [.proposeDiff(ProposedThreadDiff(checkpoint: 1, quote: threadOld, replacement: threadNew))],
                              checkpoint: 1, startedAt: Date(), endedAt: Date())
        try (line.encode(turn) + Data("\n".utf8)).write(to: dir.appendingPathComponent("turns.jsonl"), options: .atomic)
        let diff = ThreadDiff(thread: id, turn: 1, checkpoint: 1, anchor: anchor, old: threadOld, new: threadNew)
        try IntakeJSON.encoder.encode(diff).write(to: dir.appendingPathComponent("diffs/\(diff.id.uuidString).json"), options: .atomic)
    }

    static let visualID = "fixture-flow"
    static let visualSizes = ["wide", "narrow"]

    /// `plan` with a Mermaid block after its opening sentence, so the block is on screen first.
    static let visualPlan: String = plan.replacingOccurrences(
        of: "\(threadOld)\n\n",
        with: "\(threadOld)\n\n```fd-visual id=\(visualID)\nHow a fixture request flows\n```\n\n")

    /// One Mermaid revision in two sizes, primary, as ThreadRunner will leave it.
    private static func seedVisual(_ tapes: TapeStore) throws {
        let id = VisualID(rawValue: visualID)!
        let dir = tapes.revisionDirectory(id, r: 1)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = Data("flowchart LR\n  phone[Phone] --> mac[Mac]\n  mac --> host[hostd]\n  host --> mac\n".utf8)
        try source.write(to: dir.appendingPathComponent("diagram.mmd"), options: .atomic)
        let hash = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
        let manifest = VisualManifest(provider: "mermaid", providerVersion: "12.2.0", kind: "flowchart", title: "Fixture flow",
                                      entry: "diagram.mmd", states: ["default"], sizes: visualSizes, madeOnCheckpoint: 1,
                                      madeBy: .you, primary: true,
                                      files: [VisualFileEntry(path: "diagram.mmd", size: Int64(source.count), sha256: hash)])
        try IntakeJSON.encoder.encode(manifest).write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        let ref = RevisionRef(visualID: id, r: 1)
        try IntakeJSON.encoder.encode(BlockState(representations: [ref], primary: ref))
            .write(to: tapes.visualsDirectory(id).appendingPathComponent("block.json"), options: .atomic)
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
