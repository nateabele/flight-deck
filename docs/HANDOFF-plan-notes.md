# Handoff — plan notes

**Feature:** the notes a person leaves on a plan for the planning rounds to read: on the Mac
(the notes rail beside the plan editor) and on the phone (the plan reader).
**State as of 2026-10-15, `master` `18682f2e`:** notes are pinned to the plan version they were
written on. A layout fix for the notes rail is in flight on branch `notes-pinned-collapse` and
is not merged yet (see "Open").
**Audience:** agents extending this feature. Read it before touching notes. Claims here were
checked against the code at that commit; where something is unverified it says so.

## What a note is

A `PlanNote` (`Sources/IntakeKit/PlanNote.swift`) is:

- `kind`: `NoteKind`, one of `comment`, `question`, `mustChange`, `delete` or `replace`. A
  comment with no words is what the UI calls a **Highlight**. `replace` carries its replacement
  in `note`. `PlanNote.accepts(kind:)` is the one rule for which kinds need words (all but
  `delete`, and a comment); the Mac rail, the phone command and the tape fold all use it.
- `note`: the person's words.
- `anchor`: `NoteAnchor?`. nil means a note about the whole plan.

A `NoteAnchor` is a W3C `TextQuoteSelector`-style anchor:

- `checkpoint`: the checkpoint whose plan the quote was selected in. This is the note's
  **version** (see "Pinning").
- `quote`, plus `prefix`/`suffix` of about 32 characters (`contextLength`) and `section` (the
  nearest `#` heading above, or nil).
- `locate(in:)` re-finds the quote in a plan that may have moved on:
  1. Every exact occurrence of the quote, ranked by how much of the prefix and suffix match.
  2. Failing that, the same search with whitespace runs collapsed (and blockquote `>` markers
     at line starts treated as whitespace), mapped back to the original text.
  - A quote shorter than `shortQuote` (20) must also keep `shortContext` (8) characters of its
    context, or be in the same section. Otherwise a note whose words were deleted jumped to the
    next "the job" in the plan.
  - nil means the quote isn't in this text. Never highlight a guess.

## Lifecycle

1. **Written.**
   - Mac: select text, then a kind from the selection toolbar (Comment, Question, Must change,
     Replace, Delete, or Highlight). The Mac selection toolbar is `SelectionToolbar.swift`. A
     kind opens a draft card in the rail. ✎ with no selection writes a whole-plan note.
   - Phone: `NoteSheet` / `NoteComposer`, anchored by the reader's block index.
2. **Sent.** The app appends a `TapeCommand.note(PlanNote)` to the intake's `commands.jsonl`.
   The phone goes through `IntakeService.phoneNote`, which validates and refuses with
   `unknown_kind`, `empty_note`, `unknown_checkpoint` or `unknown_block`.
3. **Pending.** The runner (`IntakeRunner`, the only writer of `tape.json` and `checkpoints/`)
   folds the command into `Tape.pendingNotes`. While pending, a note can be:
   - withdrawn: `removeNote`, or phone `intake.removeNote`;
   - retyped: `setNoteKind`, or phone `intake.setNoteKind`. A runner that predates it drops the
     line. The phone sends it only when the Mac's detail says `noteKind == true`.
4. **Consumed.** The next round of ANY stage takes every pending note.
   - `RoundPrompts.steering` renders them for every stage: whole-plan notes as a bullet list,
     anchored ones as a numbered list of kind, section, the quote as a `>` block, then the words.
   - The round's checkpoint record lists them in `annotations`, and they leave `pendingNotes`.
   - **Nothing ever re-reads a consumed note.** That's why retyping a consumed note is refused
     (`note_consumed`) and shown disabled with a reason.
5. **Listed.** `TapeStore.notes(in:)` gives every note as a `TapeNote`: consumed ones (oldest
   first, with `consumedBy`), then pending ones (`consumedBy` nil).

## Pinning (added 2026-10-15)

**Problem:** synthesis and every refine round rewrite the plan text, so on the latest version
most quotes are simply gone. The rail used to say "Can't find this text anymore", which read as
lost data.

**Rule:** a note belongs to the version it was written on (`NoteAnchor.checkpoint`).
- `NoteVersion.resolve` (`Sources/IntakeKit/NoteVersion.swift`) returns it when the tape has
  that checkpoint.
- Otherwise it infers one. Notes have no clock of their own, so the candidates are the
  checkpoints before the round that consumed the note (every checkpoint, for a pending note).
  It picks the latest whose plan contains the quote, else the latest candidate.
- It's computed on read and never saved back.
- `NoteVersion.label` gives "Draft · Round 0", "Synthesis · Round 0", "Refine 1" and so on,
  through `Stage.versionName`.

**Mac** (`NotesRail.swift`: `PlanNotesController`, `NotesRailModel`; `SelectionToolbar.swift`:
`PlanNotesBridge`):
- On its own version, a note sits beside its quote in the aligned lane.
- On any other version, `PlanNotesController.pin(for:)` returns a `NotePin`, and the rail lists
  the note in a section below the lane, grouped by version, latest first, with its quote. That
  is its context without the plan.
- "Show in that version" (`showInVersion`) sets a `pendingReveal`, opens that checkpoint through
  the same navigation as the round list, then scrolls to the quote under the pinned block and
  flashes it. It is used once (`PlanNotesBridge.takeReveal`).
- A note from another version gets a dimmed mark in the text only where its quote is found
  unchanged.
- "Can't find this text anymore" now means only that a quote is missing **from its own
  version**, which is data damage. Each case is logged once (`os.Logger` category `notes`).

**Rounds:** `RoundContext.noteVersions` (filled in `RoundExecutor`) gives a note's version label
when it isn't the plan the round reads. `anchoredNote` then adds after the quote: "(Quoted from
the Draft · Round 0 version of the plan, not the one you are reading; the passage may read
differently here, or be gone.)"

**Phone:**
- `WireNote` (`Sources/FleetKit/IntakeWire.swift`) has optional `checkpoint` and `version`
  fields, so an older payload still decodes.
- `PlanReaderScreen` lists notes from other versions that have no block in the shown text under
  a "Pin: On <version>" row. That row opens that checkpoint's reader.
- `NoteOutbox` (`NoteComposer.swift`) keeps sent-but-unacknowledged notes, and their local
  retypes, showing until the plan agrees.

## How anchoring works in the editor

- `PlanNotesBridge` keeps each mark's located range across keystrokes (`located`), so the rail
  never searches the plan itself.
- After a text change it re-finds detached notes by searching a window of the new text
  (`relocate`).
- The rail lays cards out from those ranges (`NotesRailModel.cards` / `layout`). `NotesGeometry`
  redraws only the aligned lane on scroll, resize or edit beats.

## Bugs fixed this week (don't reintroduce them)

| What | Cause | Fix |
|---|---|---|
| Notes never came back after switching to another version and back to their own (`18682f2e`) | `relocate`'s search window started at `line.location - pad`. For a whole-text swap that's negative, and `NSIntersectionRange` treats `NSRange` as unsigned, so nothing matched, ever. | Clamp the window start at 0. Test: `PlanReadingMemoryTests.testNotesFindTheirQuotesAgainWhenTheirVersionIsShownAgain` (fails with the fix reverted). |
| A stale range snapshot overwrote newer ones after a text change | The async publish captured the ranges at schedule time | It reads them when it runs. |
| A reveal was lost on an editor's first load | The bridge attached after the first load | It attaches before. |
| The note type locked as soon as the note text lost focus (`ef052221`) | Blur committed the draft, and a committed card showed its kind as a static label | A type pop-up on every pending card. Blur commits only a non-empty draft. |
| Notes said "Can't find this text anymore" after synthesis | The design: anchored only to the current plan | Pinning, above. |

Checked against real data: the maintainer's two LarkOS intakes hold 14 consumed notes. All 14 quotes
resolve on their own version and 0 of 14 on the current plan. So the "can't find" after
synthesis was expected; the switch-back failure was the bug.

## Open

- **Rail layout, in flight on branch `notes-pinned-collapse`:** the other-versions section
  could cover cards in the aligned lane, cutting off a card on a short window. The fix being
  made: the section is collapsible, collapsed by default when it would overlap, and scrolls on
  its own when expanded. Also on that branch: checking a blank gap above the editor in one render
  (probably a fixture artifact), and rendering the phone's pinned groups.
- **Note creation time:** notes have no clock, so version inference uses the consuming round's
  start as the bound. Adding a `createdAt` would make inference exact for new notes.
- **No note for removed text:** a note about a passage that was removed doesn't follow its
  replacement. Pinning shows it on its version; nothing maps it forward.
- **Not tried in the running app:** the pinned rail, "Show in that version", and the phone's
  pinned groups were verified with unit tests and offscreen renders only.

## Directions for broadening (ideas, not decided)

Ask the maintainer before building any of these.

- **What the round did with each note.** A round consumes notes silently. Having each round
  report per note "addressed", "declined, because…" or "question answered: …" (in its record,
  shown on the card) would close the loop. That needs a schema change in the round's output and
  prompt changes for every stage.
- **Carrying a note forward.** When a later version still contains the quote (or a close match),
  offer "Move to this version" instead of only "Show in that version". That re-pins the note,
  which needs its own command, since the runner is the only tape writer.
- **Replies and threads.** Let a person, or the round, answer a note under it, instead of
  writing a new note.
- **Notes on other surfaces:** the change set (tasks), a diff hunk, or a round's record. Today a
  note anchors only to plan text.
- **Resolution state:** open or resolved, independent of consumed, with a filter in the rail.
- **Phone parity:** retyping exists; withdrawing, versions and reveal exist; carrying forward and
  threads would need new commands. Every new command must be gated by a capability flag, because
  an older Mac drops the socket on an unknown op.

## Where things are

| Area | Files |
|---|---|
| Model, anchoring, versions | `Sources/IntakeKit/PlanNote.swift`, `NoteVersion.swift`, `Tape.swift` (`pendingNotes`, `TapeCommand`), `TapeStore.swift` (`notes(in:)`, `TapeNote`) |
| Runner and prompts | `Sources/IntakeKit/IntakeRunner.swift`, `RoundExecutor.swift` (`noteVersions`), `RoundPrompts.swift` (`steering`, `anchoredNote`) |
| Mac UI | `Sources/FlightDeck/Intake/Planning/PlanEditor/NotesRail.swift`, `SelectionToolbar.swift` (`PlanNotesBridge`, toolbar), `PlanTextView.swift` (bridge wiring), `PlanSection.swift`, `PlanReadingAnchor.swift` / `PlanReadingRestore.swift` (scroll and reveal) |
| Service and phone commands | `Sources/FlightDeck/Intake/IntakeService.swift` (`phoneNote`, `phoneRemoveNote`, `phoneSetNoteKind`), `Sources/FleetKit/Frames.swift` (`intake.note`, `intake.removeNote`, `intake.setNoteKind`), `IntakeWire.swift` (`WireNote`), `Sources/FlightDeck/Fleet/IntakePlanProjection.swift` |
| Phone UI | `Sources/FlightDeckMobile/PlanReaderScreen.swift`, `NoteSheet.swift`, `NoteComposer.swift` (`NoteOutbox`) |
| Tests | `NoteVersionTests`, `NotePinningTests`, `NotesRailModelTests`, `NotesRailRenderTests`, `NoteTypeAnytimeTests`, `PlanReadingMemoryTests`, `RoundPromptsTests`, `IntakePhoneCommandTests`, `IntakeWireCodingTests`, `IntakePlanProjectionTests`, `TapeStoreTests`; phone `PlanNotesTests` |
| Background | `docs/ARCHITECTURE.md`: "Human edits and notes", and the tape and runner sections |

## Working rules for this feature

- **The runner is the only writer of `tape.json` and `checkpoints/`.** The app and the phone
  only append commands. A new note operation is a new `TapeCommand` plus runner handling plus,
  for the phone, a new op gated by a capability flag. Old runners and old phones must fail
  safely: a runner drops unknown lines, but an old Mac drops the phone's socket on an unknown op.
- **Storage is additive.** Old `tape.json` and `commands.jsonl` files must keep decoding,
  including pre-`PlanNote` string annotations, which map to `PlanNote.legacy` with stable ids.
  Add optional fields; never rename keys.
- **Wording:** in UI and in anything sent to an agent, say "tasks", never "beads", and "agent",
  never "seat" or "harness". `AgentVocabularyGuardTests` and `TerminologyGuardTests` enforce it.
- **Tests:**
  - `./scripts/test-unit.sh` builds here and runs on the UI-test Mac. Never set
    `FD_TEST_LOCAL=1`, and run no window-opening test, app launch or XCUITest on the
    development Mac.
  - XCUITests go through `FD_UITEST_ONLY=… ./scripts/smoke-remote.sh`.
  - The phone suite is `./scripts/test-ios.sh`, headless.
  - Look at your renders: copy the PNGs under `.superpowers/` and read them.
- **Real data is read-only.** `~/Library/Application Support/Flight Deck/intakes/` holds the maintainer's
  real plans (for example LarkOS). Read it to diagnose; never write it.
- **Workflow:** a worktree per change; vendor symlinks and `scripts/local.env` from the main
  checkout; merge through `.superpowers/merge.lock` with `--ff-only`; commit by path; no
  `git stash`, no push; and don't build or swap a release unless asked. See
  `docs/AGENT-OPERATIONS.md`.
