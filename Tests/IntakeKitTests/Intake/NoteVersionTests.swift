import IntakeKit
import XCTest

/// The version of the plan a note was written on (`NoteVersion`): read from the note when it
/// carries one, inferred from the tape when it does not, and named the way the app names a round.
final class NoteVersionTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// The shape of the maintainer's LarkOS tape: drafts, then synthesis, then a refine round.
    private func checkpoints() -> [Checkpoint] {
        [Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: at(0)),
         Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: at(600), startedAt: at(300)),
         Checkpoint(id: 3, parent: 2, stage: .refine, round: 1, major: false, createdAt: at(1_200), startedAt: at(900))]
    }

    private let draftPlan = "# Plan\n\n## Storage\n\nRun PostgreSQL on encrypted gp3 EBS storage as the system of record.\n"
    private let synthesisPlan = "# Plan\n\n## Storage\n\nOne SQLite file per app, on a volume the platform snapshots nightly.\n"

    private func text(_ id: Int) -> String? { [1: draftPlan, 2: synthesisPlan, 3: synthesisPlan][id] }

    private func note(on checkpoint: Int, quote: String = "Run PostgreSQL on encrypted gp3 EBS storage") -> PlanNote {
        PlanNote(kind: .comment, note: "Why not SQLite?", anchor: NoteAnchor(checkpoint: checkpoint, quote: quote, section: "## Storage"))
    }

    // MARK: Names

    func testALabelNamesTheStageAndItsRound() {
        let names = checkpoints().map(NoteVersion.label(of:))
        XCTAssertEqual(names, ["Draft · Round 0", "Synthesis · Round 0", "Refine 1"], "a name that carries its round does not say it twice")
        XCTAssertEqual(NoteVersion.label(stage: .polish, round: 2), "Polish 2")
        XCTAssertEqual(NoteVersion.label(stage: .freshEyes, round: 0), "Fresh eyes · Round 0")
    }

    // MARK: Read from the note

    /// A note records the checkpoint it was selected in; that is its version, whatever the text says now.
    func testANoteWithAVersionKeepsIt() {
        let entry = TapeNote(note: note(on: 1), consumedBy: 2)
        XCTAssertEqual(NoteVersion.resolve(entry, checkpoints: checkpoints(), planText: text), 1)
        let pending = TapeNote(note: note(on: 2, quote: "a quote nobody has"), consumedBy: nil)
        XCTAssertEqual(NoteVersion.resolve(pending, checkpoints: checkpoints(), planText: text), 2, "nothing is searched for")
    }

    func testANoteAboutTheWholePlanHasNoVersion() {
        let general = TapeNote(note: PlanNote(note: "Too long."), consumedBy: nil)
        XCTAssertNil(NoteVersion.resolve(general, checkpoints: checkpoints(), planText: text))
    }

    // MARK: Inferred

    /// An anchor that names no checkpoint on the tape: the latest checkpoint before the round that
    /// read the note whose plan holds the quote.
    func testAnOldNoteIsPlacedOnTheLatestVersionHoldingItsQuoteBeforeItWasRead() {
        let old = TapeNote(note: note(on: 0), consumedBy: 3)
        var asked: [Int] = []
        let version = NoteVersion.resolve(old, checkpoints: checkpoints()) { asked.append($0); return text($0) }
        XCTAssertEqual(version, 1, "the draft has the quote; synthesis rewrote it")
        XCTAssertEqual(asked.sorted(), [1, 2], "only what came before the reading round is a candidate")
    }

    func testTheLatestHoldingVersionWinsOverAnEarlierOne() {
        var plans = [1: draftPlan, 2: draftPlan + "\nMore.\n", 3: synthesisPlan]
        let old = TapeNote(note: note(on: 0), consumedBy: 3)
        XCTAssertEqual(NoteVersion.resolve(old, checkpoints: checkpoints(), planText: { plans[$0] }), 2)
        plans[2] = synthesisPlan
        XCTAssertEqual(NoteVersion.resolve(old, checkpoints: checkpoints(), planText: { plans[$0] }), 1)
    }

    /// No plan holds the quote: the latest checkpoint before the note was read is the best there is.
    func testAQuoteInNoVersionFallsBackToTheLatestBeforeItWasRead() {
        let old = TapeNote(note: note(on: 0, quote: "text that was never in any plan"), consumedBy: 3)
        XCTAssertEqual(NoteVersion.resolve(old, checkpoints: checkpoints(), planText: text), 2)
    }

    /// A pending note has not been read: every checkpoint came before it.
    func testAPendingNoteIsPlacedAmongAllTheVersions() {
        let pending = TapeNote(note: note(on: 0, quote: "SQLite file per app"), consumedBy: nil)
        XCTAssertEqual(NoteVersion.resolve(pending, checkpoints: checkpoints(), planText: text), 3, "the latest holding it")
    }

    /// A checkpoint written after the reading round started can't be the note's version, even if
    /// its id is lower than the reader's (ids and clocks are both consulted).
    func testACheckpointCreatedAfterTheReadingRoundStartedIsNotACandidate() {
        var cps = checkpoints()
        cps[0] = Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: at(1_000))
        let old = TapeNote(note: note(on: 0), consumedBy: 3)
        XCTAssertEqual(NoteVersion.resolve(old, checkpoints: cps, planText: text), 2, "the draft landed after the round that read the note began")
    }

    func testAnEmptyTapeHasNoVersionToInfer() {
        XCTAssertNil(NoteVersion.resolve(TapeNote(note: note(on: 0), consumedBy: nil), checkpoints: [], planText: { _ in nil }))
    }

    // MARK: Anchoring: own version vs another

    /// The text a note's quote was selected in finds it; the rewritten plan does not. The first
    /// is what the rail anchors by; the second is no longer "can't find this text".
    func testTheQuoteIsInItsOwnVersionAndNotInTheLaterOne() throws {
        let anchor = try XCTUnwrap(note(on: 1).anchor)
        XCTAssertNotNil(anchor.locate(in: draftPlan))
        XCTAssertNil(anchor.locate(in: synthesisPlan))
    }
}
