import XCTest
import IntakeKit

/// `ThreadWorkspace`: the files a thread turn reads, rebuilt from the checkpoint it follows.
final class ThreadWorkspaceTests: XCTestCase {
    private var root: URL!
    private var store: TapeStore!
    private var tape: Tape!

    static let plan = """
    Opening words.

    # Plan

    ## Storage
    Use SQLite for the queue.

    ```sh
    # not a heading
    ```

    ### Backups
    Nightly snapshots.

    ## Sync
    The client races the first sync.
    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = TapeStore(intakeDirectory: root)
        let created = Date(timeIntervalSince1970: 1_790_000_000)
        var t = Tape()
        try store.writeCheckpoint(Checkpoint(id: 1, stage: .draft, round: 0, major: false, createdAt: created),
                                  files: ["drafts/0.md": Data(Self.plan.utf8)], into: &t)
        let note = PlanNote(kind: .comment, note: "Why SQLite?",
                            anchor: NoteAnchor(checkpoint: 1, quote: "Use SQLite", section: "## Storage"))
        try store.writeCheckpoint(Checkpoint(id: 2, parent: 1, stage: .refine, round: 3, major: false, createdAt: created,
                                             record: RoundRecord(annotations: [note])),
                                  files: ["plan.md": Data(Self.plan.utf8)], into: &t)
        tape = t
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func build(_ anchor: ThreadAnchor, intake: Intake? = nil) throws -> ThreadWorkspace {
        try ThreadWorkspace.build(in: root.appendingPathComponent("threads/t/workspace"), anchor: anchor, checkpoint: 2,
                                  plan: Self.plan, tape: tape, store: store, intake: intake)
    }

    private func read(_ ws: ThreadWorkspace, _ name: String) throws -> String {
        try String(contentsOf: ws.directory.appendingPathComponent(name), encoding: .utf8)
    }

    private var storageAnchor: ThreadAnchor {
        ThreadAnchor(note: NoteAnchor(checkpoint: 2, quote: "SQLite for the queue", section: "## Storage"))
    }

    /// Sections are `s<n>` in outline order, every heading level, a preamble as `s0`, and a `#`
    /// line inside fenced code is not a heading.
    func testSectionsAreNumberedInOutlineOrder() {
        let sections = PlanOutline.sections(Self.plan)
        XCTAssertEqual(sections.map(\.id), ["s0", "s1", "s2", "s3", "s4"])
        XCTAssertEqual(sections.map(\.title), ["Preamble", "Plan", "Storage", "Backups", "Sync"])
        XCTAssertTrue(sections[2].text.contains("# not a heading"), "fenced code stays in its section")
        XCTAssertEqual(sections.map(\.text).joined(), Self.plan, "the sections tile the plan")
    }

    func testOutlineListsIDsHeadingsAndSizesAndMarksTheAnchor() throws {
        let ws = try build(storageAnchor)
        let outline = try read(ws, "outline.md")
        XCTAssertTrue(outline.contains("checkpoint 2 (Refine 3)"))
        XCTAssertTrue(outline.contains("  - s2 ## Storage — 6 lines  ← the thread's anchor"), outline)
        XCTAssertTrue(outline.contains("    - s3 ### Backups — 2 lines"), outline)
        XCTAssertEqual(ws.anchored?.id, "s2")
    }

    func testEverySectionHasItsOwnFile() throws {
        let ws = try build(storageAnchor)
        XCTAssertEqual(try read(ws, "sections/s4.md"), "## Sync\nThe client races the first sync.")
        XCTAssertTrue(ws.files.contains("sections/s0.md"))
    }

    func testAnchorFileHoldsTheQuoteAndItsSection() throws {
        let anchor = try read(try build(storageAnchor), "anchor.md")
        XCTAssertTrue(anchor.contains("> SQLite for the queue"))
        XCTAssertTrue(anchor.contains("It is in s2, “Storage”."))
        XCTAssertTrue(anchor.contains("Use SQLite for the queue."))
    }

    /// A quote that no longer appears is said to be gone, not pinned to a guess.
    func testAGoneQuoteIsSaidToBeGone() throws {
        let ws = try build(ThreadAnchor(note: NoteAnchor(checkpoint: 1, quote: "Postgres everywhere for all things")))
        XCTAssertNil(ws.anchored)
        XCTAssertTrue(try read(ws, "anchor.md").contains("not in this version of the plan any more"))
    }

    func testWholePlanAnchor() throws {
        let ws = try build(.wholePlan)
        XCTAssertNil(ws.anchored)
        XCTAssertTrue(try read(ws, "anchor.md").contains("about the whole plan"))
    }

    func testIntakeFileHoldsTheRequestAndTriage() throws {
        var intake = Intake(projectPath: "/repo", intent: "Add offline mode")
        intake.exchanges = [TriageExchange(questions: ["Which platforms?"], answers: ["iOS only"])]
        let text = try read(try build(storageAnchor, intake: intake), "intake.md")
        XCTAssertTrue(text.contains("Add offline mode"))
        XCTAssertTrue(text.contains("Q: Which platforms?\nA: iOS only"))
    }

    /// One provenance file per checkpoint up to the one followed, scoped to the anchored
    /// section, and its ids in `citations.json` for a reader in another process.
    func testProvenancePerCheckpointAndCitations() throws {
        let ws = try build(storageAnchor)
        XCTAssertTrue(try read(ws, "provenance/1.md").contains("[cite:cp1.d0] Draft 0's version"))
        XCTAssertTrue(try read(ws, "provenance/2.md").contains("[cite:cp2.n0] comment on “Use SQLite”: Why SQLite?"))
        XCTAssertEqual(ws.citationIDs, ["cp1.d0", "cp2.n0"])
        XCTAssertEqual(ThreadWorkspace.citationIDs(in: ws.directory), ["cp1.d0", "cp2.n0"])
    }

    /// Rebuilding replaces the workspace: a section the plan lost leaves no file behind.
    func testRebuildReplacesTheOldWorkspace() throws {
        let ws = try build(storageAnchor)
        try Data("stale".utf8).write(to: ws.directory.appendingPathComponent("sections/s9.md"))
        _ = try build(storageAnchor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.directory.appendingPathComponent("sections/s9.md").path))
    }
}
