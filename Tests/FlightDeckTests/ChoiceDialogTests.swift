import FleetKit
import XCTest
@testable import FlightDeck

/// The interlock in front of an irreversible keypress.
///
/// **Six of these fixtures are captured, not authored.** `permission-bash`, `permission-write`,
/// `permission-write-60col`, `question-single`, `question-multi` and `workspace-trust` are
/// verbatim renders of what claude 2.1.241 drew on a pty, with the two matching transcript
/// records beside them; `dialogs.captured.provenance.json` holds the recipe, the digests and
/// the five premises they refuted. The handful of hand-written screens below are degenerate
/// cases no capture can produce on demand: a moved cursor, a list with no marker, a list with
/// two, a list numbered out of sequence.
///
/// The bias throughout is refusal. A wrong answer here becomes Return pressed on the wrong row
/// of someone's live terminal — on a permission dialog, a decision nobody made — so a screen
/// that does not read as expected produces `nil` or `false`, and the answer path stops.
final class ChoiceDialogTests: XCTestCase {
    private func captured(_ name: String) throws -> String {
        try TimelineFixtureTests.text(name, in: "Claude")
    }

    private func viewport(_ lines: [String]) -> String { lines.joined(separator: "\n") }

    /// The three options `permission-write.captured.txt` offers, verbatim. Note what is NOT
    /// here: no "don't ask again for Bash commands in /Users/nate" row appeared in any capture,
    /// so the durable-grant shape this feature refuses to name is uncaptured as well as
    /// unreachable.
    private let writePermissionLabels = [
        "Yes",
        "Yes, and switch to accept edits (auto-approve file edits and common file commands) "
            + "for this session (shift+tab)",
        "No",
    ]

    // MARK: - Where the cursor is

    /// **Every captured dialog opens on row 0**, which is what makes Allow reachable with no
    /// text at all. It is asserted here rather than assumed in `answerPrompt`, across all six
    /// captures and all three dialog kinds, because a build that opened somewhere else would
    /// otherwise be discovered by an approval nobody gave.
    func testEveryRealDialogOpensWithTheCursorOnItsFirstRow() throws {
        for name in ["permission-bash.captured", "permission-write.captured",
                     "permission-write-60col.captured", "question-single.captured",
                     "question-multi.captured", "workspace-trust.captured"] {
            XCTAssertEqual(ChoiceDialog.focusedRow(inViewport: try captured(name)), 0,
                           "\(name) must still open on its first row")
        }
    }

    // MARK: - What the row says

    func testAPermissionDialogsRowsReadAsTheirLabelsOnARealScreen() throws {
        let screen = try captured("permission-bash.captured")
        XCTAssertTrue(ChoiceDialog.row(0, reads: "Yes", inViewport: screen))
        XCTAssertTrue(ChoiceDialog.row(1, reads: "No", inViewport: screen))
        XCTAssertFalse(ChoiceDialog.row(0, reads: "No", inViewport: screen),
                       "a label on the screen but not on THAT row is the interlock's whole job")
        XCTAssertFalse(ChoiceDialog.row(2, reads: "Yes", inViewport: screen),
                       "2.1.241 offers Bash exactly two options; a third row is not there to "
                       + "confirm and must not trap")
    }

    func testAThreeOptionPermissionDialogsRowsReadAsTheirLabels() throws {
        let screen = try captured("permission-write.captured")
        for (index, label) in writePermissionLabels.enumerated() {
            XCTAssertTrue(ChoiceDialog.row(index, reads: label, inViewport: screen),
                          "row \(index) must read as \(label.prefix(24))…")
        }
    }

    /// **The wrap case.** At 60 columns the middle option runs onto two continuation lines
    /// indented to the label column; no `…` appears anywhere in any capture, so there is no
    /// truncation to match a prefix against. The row reads as its text joined with the lines
    /// under it, and that reassembles to the label exactly.
    func testALabelWrappedByANarrowTerminalStillReads() throws {
        let screen = try captured("permission-write-60col.captured")
        for (index, label) in writePermissionLabels.enumerated() {
            XCTAssertTrue(ChoiceDialog.row(index, reads: label, inViewport: screen),
                          "row \(index) wraps but still reads as its label")
        }
    }

    /// A third dialog kind, with the marker back at column 2 and no echoed prompt above it at
    /// all. Nothing in this feature drives folder-trust; it is here because it is the one
    /// capture whose layout differs from both of the ones this was written for.
    func testAFolderTrustDialogsRowsRead() throws {
        let screen = try captured("workspace-trust.captured")
        XCTAssertTrue(ChoiceDialog.row(0, reads: "Yes, I trust this folder", inViewport: screen))
        XCTAssertTrue(ChoiceDialog.row(1, reads: "No, exit", inViewport: screen))
    }

    /// **The bug the capture exercise existed to catch, and the end-to-end claim the answer
    /// path rests on**, made across one session rather than across two files written by the
    /// same hand. `question-single.captured.jsonl` is the very `tool_use` record that produced
    /// `question-single.captured.txt`, so this checks the Mac's own labels — read from the
    /// transcript exactly as `answerPrompt` will read them — against the screen claude drew
    /// from them.
    ///
    /// `AskUserQuestion`'s options are numbered on screen (`❯ 1. Rust`). A rule that compared
    /// the whole row against the label would see `1. Rust` where it wants `Rust`, confirm
    /// nothing ever, and the feature would ship and silently never work.
    func testAQuestionsRowsReadAsTheLabelsItsTranscriptNames() throws {
        let screen = try captured("question-single.captured")
        let labels = try transcriptLabels("question-single.captured")
        XCTAssertEqual(labels, ["Rust", "Go", "Swift"])
        for (index, label) in labels.enumerated() {
            XCTAssertTrue(ChoiceDialog.row(index, reads: label, inViewport: screen),
                          "row \(index) must read as the transcript's \(label)")
        }
    }

    /// **The property that makes claude's appended rows safe**, and the reason this is an
    /// interlock rather than a counter. The transcript names three options; the screen draws
    /// five, adding `Type something.` and `Chat about this` at display time. Today they land
    /// after the real options so index and row agree — nothing guarantees that, so every pair
    /// is checked: a label confirms on its own row and on no other, and the two appended rows
    /// confirm nothing the transcript names.
    func testARowConfirmsItsOwnLabelAndNoOther() throws {
        let screen = try captured("question-single.captured")
        let labels = try transcriptLabels("question-single.captured")
        for row in 0..<5 {
            for (index, label) in labels.enumerated() {
                XCTAssertEqual(
                    ChoiceDialog.row(row, reads: label, inViewport: screen), row == index,
                    "row \(row) vs \(label): if these ever stop lining up one-to-one, blind "
                    + "counting would select the wrong option and this is where that is found"
                )
            }
        }
    }

    /// A multi-select numbers AND checkboxes each row — `❯ 1. [ ] Trail mix`. This feature
    /// refuses to answer one upstream (`PromptQuestion.multiSelectReason`), so the interlock
    /// declines to confirm the screen it cannot drive rather than quietly reading past the box.
    func testAMultiSelectsCheckboxedRowConfirmsNothing() throws {
        let screen = try captured("question-multi.captured")
        let labels = try transcriptLabels("question-multi.captured")
        XCTAssertEqual(labels, ["Trail mix", "Dark chocolate", "Beef jerky", "Fresh fruit"])
        for (index, label) in labels.enumerated() {
            XCTAssertFalse(ChoiceDialog.row(index, reads: label, inViewport: screen),
                           "\(label) is drawn behind a checkbox on a list this build cannot "
                           + "answer; confirming it would be confirming the wrong screen")
        }
    }

    /// A description is not a label. `question-single`'s rows carry their descriptions on the
    /// same continuation lines this reader uses to reassemble a *wrapped* label — the screen
    /// does not distinguish the two — so the rule keeping them apart is that a row reads as its
    /// text, or its text *joined with* what follows, never as what follows alone.
    func testAnOptionsDescriptionIsNotItsRowsLabel() throws {
        let screen = try captured("question-single.captured")
        XCTAssertFalse(ChoiceDialog.row(
            1, reads: "Simple, fast-compiling language with a large standard library and "
            + "effortless cross-compilation to static binaries.", inViewport: screen
        ))
    }

    /// **The dialog answered on the Mac a moment ago.** The ordinary outcome, because this is
    /// asked on every answer and the screen may have moved on between the tap and the read: the
    /// list is simply gone, and what is left is the scrollback and the input bar. A label that
    /// was valid a second earlier must confirm nothing now, and — the part that matters — the
    /// absence of a list must not read as "sure, whatever you say".
    func testALabelFromADialogThatHasClosedIsRefused() {
        let afterwards = viewport([
            "⏺ I'll run that command.",
            "  ⎿  $ ls /",
            "",
            "❯ ",
            "────────────────────────────────────────────",
        ])
        XCTAssertFalse(ChoiceDialog.row(0, reads: "Yes", inViewport: afterwards))
        XCTAssertNil(ChoiceDialog.focusedRow(inViewport: afterwards))
    }

    // MARK: - The echoed prompt

    /// **The trap AMENDMENT 2 recorded, from a live screen.** claude echoes the user's own
    /// prompt with a `❯` at column 1 and **no number after it**, so every capture that has an
    /// echo carries two markers. Keying on the marker alone finds the echo and reports a row
    /// nobody is on — and then arrows are counted from the wrong place.
    ///
    /// Asserted on the screens that actually carry an echo, and then on the case no capture
    /// holds, because the AX grant that would have sent a keystroke lapsed mid-capture: **a
    /// cursor moved off row 0.** That is where reading the wrong marker stops being merely
    /// lucky and starts reporting `0` for a screen sitting on row 1.
    func testTheEchoedPromptsBareMarkerIsNotAnOptionRow() throws {
        for name in ["permission-bash.captured", "permission-write.captured",
                     "question-single.captured", "question-multi.captured"] {
            let screen = try captured(name)
            XCTAssertEqual(screen.filter { $0 == ChoiceDialog.marker }.count, 2,
                           "\(name) must still carry both markers — the prompt echo and the "
                           + "focused row — or it no longer exercises the trap")
            XCTAssertEqual(ChoiceDialog.focusedRow(inViewport: screen), 0,
                           "\(name): the dialog's marker is read, not the echo's")
        }
        XCTAssertEqual(
            ChoiceDialog.focusedRow(inViewport: viewport([
                "❯ Run this exact bash command and show me the output: ls /",
                "",
                " Do you want to proceed?",
                "   1. Yes",
                " ❯ 2. No",
                "",
                " Esc to cancel · Tab to amend · ctrl+e to explain",
            ])),
            1, "the cursor is on row 2; the marker at column 1 is claude quoting the human "
            + "back at them and is not a row at all"
        )
    }

    // MARK: - Degenerate screens the captures cannot produce

    func testAListWithNoMarkerHasNoFocusedRow() {
        XCTAssertNil(ChoiceDialog.focusedRow(inViewport: viewport(["   1. Yes", "   2. No"])),
                     "a list nobody is on is not a dialog being offered")
    }

    func testTwoMarkedRowsHaveNoFocusedRow() {
        XCTAssertNil(ChoiceDialog.focusedRow(inViewport: viewport([" ❯ 1. Yes", " ❯ 2. No"])))
    }

    /// The scrollback holds an echo of an earlier, identical dialog. The LAST occurrence is the
    /// live one — the same rule, and the same reason, as `InputBar.read` taking the last box.
    func testTheLastListOnScreenWins() {
        let screen = viewport([
            " ❯ 1. Yes",
            "   2. No",
            "",
            "   1. Keep going",
            " ❯ 2. Stop",
        ])
        XCTAssertEqual(ChoiceDialog.focusedRow(inViewport: screen), 1)
        XCTAssertTrue(ChoiceDialog.row(0, reads: "Keep going", inViewport: screen))
        XCTAssertFalse(ChoiceDialog.row(0, reads: "Yes", inViewport: screen),
                       "the frozen dialog above is scrollback, not a choice anyone has")
    }

    /// A numbered list is a *run*. `1.` with no `2.` under it is a citation, a footnote or a
    /// diff hunk — and confirming one would let Return be pressed on a paragraph.
    func testASingleRowIsNotAList() {
        let screen = viewport([" ❯ 1. Continue"])
        XCTAssertNil(ChoiceDialog.focusedRow(inViewport: screen))
        XCTAssertFalse(ChoiceDialog.row(0, reads: "Continue", inViewport: screen))
    }

    /// And it is a run with no gap in it. Rows numbered 1 and 3 are two lists of one, not one
    /// list of two.
    func testRowsNumberedOutOfSequenceAreNotOneList() {
        let screen = viewport([" ❯ 1. Yes", "   3. No"])
        XCTAssertNil(ChoiceDialog.focusedRow(inViewport: screen))
        XCTAssertFalse(ChoiceDialog.row(0, reads: "Yes", inViewport: screen))
    }

    /// A blank line between two rows ends the list. Nothing claude draws splits a list that
    /// way, so a "list" spanning one is two things that happen to be numbered.
    func testABlankLineEndsTheList() {
        XCTAssertNil(ChoiceDialog.focusedRow(inViewport: viewport([" ❯ 1. Yes", "", "   2. No"])))
    }

    /// **Where an `AskUserQuestion`'s list ends.** claude draws `Chat about this` *below* the
    /// closing rule, so the run on screen is broken in two — and the row past the end confirms
    /// nothing rather than reaching across the break for it.
    func testAQuestionsListStopsAtTheRuleDrawnBelowIt() throws {
        let screen = try captured("question-single.captured")
        XCTAssertTrue(ChoiceDialog.row(3, reads: "Type something.", inViewport: screen),
                      "the row above the rule is still in the list")
        XCTAssertFalse(ChoiceDialog.row(4, reads: "Chat about this", inViewport: screen),
                       "the row below it is not")
    }

    func testAnEmptyViewportConfirmsNothing() {
        XCTAssertNil(ChoiceDialog.focusedRow(inViewport: ""))
        XCTAssertFalse(ChoiceDialog.row(0, reads: "Yes", inViewport: ""))
    }

    /// An index the screen does not have is a refusal, not a trap. A list shorter than the
    /// caller expected is exactly the state a stale answer arrives in.
    func testAnIndexOutsideTheListConfirmsNothing() throws {
        let screen = try captured("permission-bash.captured")
        XCTAssertFalse(ChoiceDialog.row(9, reads: "Yes", inViewport: screen))
        XCTAssertFalse(ChoiceDialog.row(-1, reads: "Yes", inViewport: screen))
    }

    /// A terminal lays text out on a grid, so the gap between two words on screen is however
    /// many cells claude decided to leave. Both sides of the comparison are normalized, which
    /// is also what makes the U+00A0 claude draws after a marker survive the trip.
    func testSpacingOnTheGridDoesNotDefeatAMatch() {
        XCTAssertTrue(ChoiceDialog.row(
            0, reads: "Yes, I trust this folder",
            inViewport: viewport([" ❯ 1. Yes,\u{a0}I  trust this   folder", "   2. No, exit"])
        ))
    }

    // MARK: -

    /// The option labels the Mac itself would use: read out of the capture's own `tool_use`
    /// record, through the mapper and `PromptQuestion`, which is the path `answerPrompt` takes.
    private func transcriptLabels(_ name: String) throws -> [String] {
        let lines = try TimelineFixtureTests.lines(name, in: "Claude")
        XCTAssertEqual(lines.count, 1, "\(name).jsonl is one lifted record")
        let items = ClaudeTimelineMapper.items(inLine: try XCTUnwrap(lines.first), at: 0)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, .prompt)
        let question = try XCTUnwrap(PromptQuestion(toolInput: item.body.text),
                                     "\(name).jsonl must still hold an AskUserQuestion")
        return question.options.map(\.label)
    }
}
