import XCTest
import IntakeKit

/// The engine half of editable plans and anchored notes: the `PlanNote` model and its
/// migration from free-text annotations, the plan layers (`plan.md` + `plan.user.md`), the
/// per-hunk revert, anchor re-location, and the prompt rendering every stage shares.
final class PlanEditsTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("PlanEditsTests-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }
    var store: TapeStore { TapeStore(intakeDirectory: root) }

    func write(_ text: String, _ path: String, checkpoint: Int) throws {
        let url = store.checkpointDirectory(checkpoint).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Migration

    /// A tape saved before `PlanNote` holds `pendingAnnotations` strings, and every checkpoint's
    /// record an `annotations` string list. Both come back as unanchored comments, with ids
    /// that are the same on every decode (the app and runner decode independently), and the
    /// next save writes only the new key.
    func testOldTapeMigratesAnnotationsToUnanchoredComments() throws {
        let old = #"""
        {"checkpoints":[{"id":1,"stage":"draft","round":0,"major":true,"createdAt":"2026-09-26T10:00:00.000Z",
          "record":{"slots":[],"linesAdded":0,"linesRemoved":0,"sectionsChanged":[],"annotations":["web only"]}}],
         "target":"none","status":"paused","ackedCommandSeq":3,"extraRefinement":0,"extraPolish":0,
         "pendingAnnotations":["focus on auth","and tests"]}
        """#
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: store.tapeURL)

        let tape = store.loadTape()
        XCTAssertEqual(tape.checkpoints.count, 1, "the old tape must decode, not fall back to empty")
        XCTAssertEqual(tape.pendingNotes.map(\.note), ["focus on auth", "and tests"])
        XCTAssertEqual(tape.pendingNotes.map(\.kind), [.comment, .comment])
        XCTAssertTrue(tape.pendingNotes.allSatisfy { $0.anchor == nil })
        XCTAssertEqual(tape.checkpoints[0].record.annotations.map(\.note), ["web only"])
        XCTAssertEqual(store.loadTape().pendingNotes.map(\.id), tape.pendingNotes.map(\.id), "stable ids across decodes")
        XCTAssertNotEqual(tape.pendingNotes[0].id, tape.pendingNotes[1].id)

        try store.saveTape(tape)
        let saved = try String(contentsOf: store.tapeURL, encoding: .utf8)
        XCTAssertFalse(saved.contains("pendingAnnotations"))
        XCTAssertEqual(store.loadTape(), tape)
    }

    /// A `commands.jsonl` line written by the old app — `{"kind":"annotate","text":…}` — still
    /// decodes, as the same unanchored comment `.annotate` builds today.
    func testOldAnnotateCommandLineDecodesAsUnanchoredComment() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"command":{"kind":"annotate","text":"tighten scope"},"seq":1}"#.utf8 + [0x0A]).write(to: store.commandsURL)
        let commands = store.commands(after: 0).map(\.command)
        XCTAssertEqual(commands, [.annotate("tighten scope")])
        guard case .note(let note) = commands.first else { return XCTFail("expected a note, got \(commands)") }
        XCTAssertEqual(note.kind, .comment)
        XCTAssertNil(note.anchor)
        XCTAssertEqual(note.note, "tighten scope")
    }

    func testNewCommandsRoundTripThroughCommandsFile() throws {
        let anchor = NoteAnchor(checkpoint: 2, quote: "OAuth", section: "## Auth", prefix: "Use ", suffix: " only")
        let note = PlanNote(kind: .replace, note: "passkeys", anchor: anchor)
        _ = try store.appendCommand(.note(note))
        _ = try store.appendCommand(.removeNote(note.id))
        _ = try store.appendCommand(.editPlan(checkpoint: 2, markdown: "# Plan\n\nline \"quoted\"\n"))
        XCTAssertEqual(store.commands(after: 0).map(\.command),
                       [.note(note), .removeNote(note.id), .editPlan(checkpoint: 2, markdown: "# Plan\n\nline \"quoted\"\n")])
    }

    // MARK: - Applying commands

    func testNoteAndRemoveNoteApply() {
        var tape = Tape()
        let a = PlanNote(kind: .question, note: "why sqlite?")
        let b = PlanNote(kind: .mustChange, note: "no plugins",
                         anchor: NoteAnchor(checkpoint: 1, quote: "plugin system"))
        TapePlanner.apply(.note(a), to: &tape)
        TapePlanner.apply(.note(b), to: &tape)
        XCTAssertEqual(tape.pendingNotes, [a, b])
        TapePlanner.apply(.removeNote(a.id), to: &tape)
        XCTAssertEqual(tape.pendingNotes, [b])
        TapePlanner.apply(.removeNote(UUID()), to: &tape)
        XCTAssertEqual(tape.pendingNotes, [b], "removing an unknown id changes nothing")
        TapePlanner.apply(.editPlan(checkpoint: 1, markdown: "x"), to: &tape)
        XCTAssertEqual(tape, { var t = Tape(); t.pendingNotes = [b]; return t }(), "an edit is a file, not tape state")
    }

    // MARK: - Plan layers

    func testEffectivePlanPrefersUserLayerThenPlanThenFirstDraft() throws {
        try write("draft one", "drafts/1.md", checkpoint: 1)
        try write("draft two", "drafts/2.md", checkpoint: 1)
        XCTAssertEqual(PlanLayers.effectivePlan(store.checkpointDirectory(1)), "draft one", "drafter 0 failed; 1 stands in")
        try write("generated", "plan.md", checkpoint: 2)
        XCTAssertEqual(PlanLayers.effectivePlan(store.checkpointDirectory(2)), "generated")
        try write("edited", "plan.user.md", checkpoint: 2)
        XCTAssertEqual(PlanLayers.effectivePlan(store.checkpointDirectory(2)), "edited")
        XCTAssertEqual(store.userEdits(checkpoint: 2), "edited")
        XCTAssertNil(store.userEdits(checkpoint: 1))
        XCTAssertNil(PlanLayers.effectivePlan(store.checkpointDirectory(3)))
    }

    /// Writing the human's markdown never touches `plan.md`; writing markdown identical to the
    /// generated plan clears the layer, so "reverted everything" is not "edited".
    func testWriteUserEditsKeepsGeneratedPlanAndClearsOnIdentity() throws {
        try write("# Plan\nA\n", "plan.md", checkpoint: 1)
        try store.writeUserEdits(checkpoint: 1, markdown: "# Plan\nA, edited\n")
        XCTAssertEqual(store.userEdits(checkpoint: 1), "# Plan\nA, edited\n")
        XCTAssertEqual(try String(contentsOf: store.checkpointDirectory(1).appendingPathComponent("plan.md"), encoding: .utf8),
                       "# Plan\nA\n")
        try store.writeUserEdits(checkpoint: 1, markdown: "# Plan\nA\n")
        XCTAssertNil(store.userEdits(checkpoint: 1))
    }

    func testHeadPlanCheckpointIsNewestWithAPlan() throws {
        var tape = Tape()
        tape.checkpoints = (1...3).map { Checkpoint(id: $0, stage: .refine, round: $0, major: false, createdAt: Date()) }
        XCTAssertNil(store.headPlanCheckpoint(in: tape))
        try write("d", "drafts/0.md", checkpoint: 1)
        try write("p", "plan.md", checkpoint: 2)
        XCTAssertEqual(store.headPlanCheckpoint(in: tape), 2)
    }

    let generated = """
    # Plan

    ## Auth
    Use OAuth.
    Store tokens in the keychain.

    ## Sync
    Poll every minute.
    """

    let edited = """
    # Plan

    ## Auth
    Use passkeys.
    Store tokens in the keychain.

    ## Sync
    Push over a websocket.
    Fall back to polling.
    """

    func testUserDiffHunksCarryBothSidesAndSection() {
        let hunks = PlanLayers.userDiff(generated: generated, edited: edited)
        XCTAssertEqual(hunks, [
            PlanHunk(oldStart: 3, oldLines: ["Use OAuth."], newStart: 3, newLines: ["Use passkeys."], section: "## Auth"),
            PlanHunk(oldStart: 7, oldLines: ["Poll every minute."], newStart: 7,
                     newLines: ["Push over a websocket.", "Fall back to polling."], section: "## Sync"),
        ])
        XCTAssertEqual(PlanLayers.userDiff(generated: generated, edited: generated), [])
    }

    /// Reverting one hunk leaves exactly the other; reverting both gets the generated plan back.
    /// A hunk from a stale diff (the text moved on since) is refused, not spliced over the
    /// human's newer typing.
    func testPerHunkRevertRoundTrip() throws {
        let hunks = PlanLayers.userDiff(generated: generated, edited: edited)
        let first = try XCTUnwrap(PlanLayers.revert(hunks[0], generated: generated, edited: edited))
        XCTAssertEqual(PlanLayers.userDiff(generated: generated, edited: first).map(\.newLines), [hunks[1].newLines])
        XCTAssertTrue(first.contains("Use OAuth.") && first.contains("Push over a websocket."))

        let remaining = PlanLayers.userDiff(generated: generated, edited: first)
        let both = try XCTUnwrap(PlanLayers.revert(remaining[0], generated: generated, edited: first))
        XCTAssertEqual(both, generated)

        XCTAssertNil(PlanLayers.revert(hunks[0], generated: generated, edited: generated), "stale hunk")
    }

    func testLostEditedLinesCountsOnlyVanishedInsertions() {
        let kept = edited + "\n\n## Added\nnew"
        XCTAssertEqual(PlanLayers.lostEditedLines(generated: generated, edited: edited, in: kept), 0)
        let rewritten = edited.replacingOccurrences(of: "Use passkeys.", with: "Use OAuth.")
            .replacingOccurrences(of: "Fall back to polling.", with: "")
        XCTAssertEqual(PlanLayers.lostEditedLines(generated: generated, edited: edited, in: rewritten), 2)
    }

    func testPromptDiffIsCappedWithANote() {
        let big = (0..<300).map { "line \($0)" }.joined(separator: "\n")
        let diff = PlanLayers.promptDiff(generated: "", edited: big, maxLines: 200)
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 201, "200 diff lines and the note")
        XCTAssertTrue(diff.hasSuffix("… (diff truncated: 102 more lines; the plan file has every edit)"), String(lines.last!))
        XCTAssertFalse(PlanLayers.promptDiff(generated: generated, edited: edited).contains("truncated"))
    }

    // MARK: - Anchors

    func anchor(_ markdown: String, _ quote: String, occurrence: Int = 0) -> NoteAnchor {
        var from = markdown.startIndex
        var range = markdown.range(of: quote)!
        for _ in 0..<occurrence {
            from = markdown.index(after: range.lowerBound)
            range = markdown.range(of: quote, range: from..<markdown.endIndex)!
        }
        return NoteAnchor(checkpoint: 1, selecting: range, in: markdown)
    }

    func testAnchorCapturesContextAndSection() {
        let a = anchor(generated, "Store tokens")
        XCTAssertEqual(a.quote, "Store tokens")
        XCTAssertEqual(a.section, "## Auth")
        XCTAssertEqual(a.prefix, String("# Plan\n\n## Auth\nUse OAuth.\n".suffix(32)))
        XCTAssertEqual(a.suffix, " in the keychain.\n\n## Sync\nPoll ")
        XCTAssertNil(anchor("Preamble text\n# Plan", "Preamble").section)
    }

    func testLocateExact() {
        let a = anchor(generated, "Poll every minute")
        XCTAssertEqual(a.locate(in: generated).map { String(generated[$0]) }, "Poll every minute")
    }

    /// The same phrase in two sections: the context picks the one the human highlighted.
    func testLocateDisambiguatesDuplicateQuotesByContext() throws {
        let doc = "## Web\nRetry three times.\nThen give up.\n\n## Mobile\nRetry three times.\nThen queue it.\n"
        let second = anchor(doc, "Retry three times.", occurrence: 1)
        let range = try XCTUnwrap(second.locate(in: doc))
        XCTAssertEqual(doc.distance(from: doc.startIndex, to: range.lowerBound),
                       doc.distance(from: doc.startIndex, to: doc.range(of: "## Mobile\n")!.upperBound))
        let first = anchor(doc, "Retry three times.")
        XCTAssertEqual(first.locate(in: doc)?.lowerBound, doc.range(of: "Retry three times.")?.lowerBound)
    }

    /// The document moved on around the quote — lines inserted before it, the other duplicate
    /// reworded — and the anchor still lands on its own occurrence.
    func testLocateSurvivesSurroundingEdits() throws {
        let doc = "## Web\nRetry three times.\nThen give up.\n\n## Mobile\nRetry three times.\nThen queue it.\n"
        let a = anchor(doc, "Retry three times.", occurrence: 1)
        let moved = "# Intro\nNew preamble paragraph.\n\n## Web\nRetry three times.\nThen give up loudly.\n\n## Mobile\nRetry three times.\nThen queue it.\n"
        let range = try XCTUnwrap(a.locate(in: moved))
        XCTAssertEqual(range.lowerBound, moved.range(of: "## Mobile\n")!.upperBound)

        // Reflowed: the quote now wraps across a line break with extra spaces.
        let quote = anchor(generated, "Store tokens in the keychain.")
        let reflowed = generated.replacingOccurrences(of: "Store tokens in the keychain.", with: "Store tokens\n  in the   keychain.")
        let r = try XCTUnwrap(quote.locate(in: reflowed))
        XCTAssertEqual(String(reflowed[r]), "Store tokens\n  in the   keychain.")
    }

    func testLocateNotFoundIsNil() {
        XCTAssertNil(anchor(generated, "Use OAuth.").locate(in: edited))
        XCTAssertNil(NoteAnchor(checkpoint: 1, quote: "").locate(in: generated))
    }

    // MARK: - Notes on the tape

    func testNotesListsConsumedThenPending() {
        let used = PlanNote(note: "used"), queued = PlanNote(kind: .delete, note: "")
        var tape = Tape()
        tape.checkpoints = [Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: Date()),
                            Checkpoint(id: 2, stage: .refine, round: 1, major: false, createdAt: Date(),
                                       record: RoundRecord(annotations: [used]))]
        tape.pendingNotes = [queued]
        XCTAssertEqual(store.notes(in: tape), [TapeNote(note: used, consumedBy: 2), TapeNote(note: queued, consumedBy: nil)])
    }

    // MARK: - Prompts

    func context(notes: [PlanNote] = [], edits: String? = nil) -> RoundContext {
        RoundContext(intent: "Ship it", qa: [], graphFile: "/i/graph.json", agentsFile: nil, readmeFile: nil,
                     notes: notes, humanEdits: edits, observedAt: Date(timeIntervalSince1970: 0))
    }

    /// Every plan-reading stage carries the same authoritative block and diff, and the same
    /// numbered anchored-note list — one helper, no per-stage fork.
    func testEveryPlanReadingStageCarriesEditsAndAnchoredNotes() {
        let diff = PlanLayers.promptDiff(generated: generated, edited: edited)
        let notes = [
            PlanNote(note: "keep it Mac-only"),
            PlanNote(kind: .replace, note: "Use passkeys and\nsecurity keys.",
                     anchor: NoteAnchor(checkpoint: 3, quote: "Use passkeys.", section: "## Auth")),
            PlanNote(kind: .delete, note: "", anchor: NoteAnchor(checkpoint: 3, quote: "Fall back to polling.")),
            PlanNote(kind: .question, note: "why a websocket?",
                     anchor: NoteAnchor(checkpoint: 3, quote: "Push over a websocket.", section: "## Sync")),
        ]
        let c = context(notes: notes, edits: diff)
        let prompts = [
            RoundPrompts.synthesis(c, ownDraft: "/d/0.md", otherDrafts: []),
            RoundPrompts.review(c, planFile: "/p/plan.user.md", round: 1),
            RoundPrompts.encode(c, planFile: "/p/plan.user.md"),
            RoundPrompts.polish(c, planFile: "/p/plan.user.md", changeSetFile: "/cs.json", round: 1),
            RoundPrompts.freshEyes(c, planFile: "/p/plan.user.md", changeSetFile: "/cs.json"),
            RoundPrompts.dedup(c, changeSetFile: "/cs.json"),
        ]
        for p in prompts {
            XCTAssertTrue(p.contains("The human edited this plan directly. These edits are authoritative: keep them unless a note explicitly asks otherwise."), p)
            XCTAssertTrue(p.contains("```diff\n\(diff)\n```"), p)
            XCTAssertTrue(p.contains("-Use OAuth.\n+Use passkeys."), p)
            XCTAssertTrue(p.contains("The human steering this plan says:\n- keep it Mac-only"), p)
            XCTAssertTrue(p.contains("""
            The human's notes on specific passages of the plan:
            1. [replace] in section "## Auth":
               > Use passkeys.
               Replace this passage with:
                  Use passkeys and
                  security keys.

            2. [delete]:
               > Fall back to polling.
               Delete this passage.

            3. [question] in section "## Sync":
               > Push over a websocket.
               Question (answer it in the plan): why a websocket?
            """), p)
        }
        XCTAssertTrue(RoundPrompts.integrate(planFile: "/w/plan.md", changesFile: "/w/c.json", humanEdits: diff)
            .contains("These edits are authoritative"))
    }

    func testNoEditsAndNoNotesAddNothing() {
        let p = RoundPrompts.review(context(), planFile: "/p/plan.md", round: 1)
        XCTAssertFalse(p.contains("edited this plan directly"))
        XCTAssertFalse(p.contains("The human steering"))
        XCTAssertFalse(p.contains("specific passages"))
        XCTAssertFalse(RoundPrompts.integrate(planFile: "/w/plan.md", changesFile: "/w/c.json").contains("authoritative"))
    }
}
