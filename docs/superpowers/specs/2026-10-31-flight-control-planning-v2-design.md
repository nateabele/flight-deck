# Flight Control planning v2: Ask threads, visual blocks, pluggable visual providers

Status: approved 2026-10-31 (sections in conversation, full spec in Plannotator). Canvas interfaces in §8 agreed with the canvas session. Not yet implemented.
Supersedes nothing; extends the Level 2 "Author" pipeline ([intake design](2026-09-26-flywheel-intake-design.md) and its follow-ups) and the notes rail ([HANDOFF-plan-notes.md](../../HANDOFF-plan-notes.md)).
Depends on, for comps only: the canvas ([2026-10-24-visual-companion-canvas-design.md](2026-10-24-visual-companion-canvas-design.md), branch `feat/canvas-ts-engine`).

Words: UI and anything sent to an agent says *tasks* (never "beads"), *agent* (never "seat"), *Flight Control* (never "flywheel"). Code identifiers keep their names. `TerminologyGuardTests` and `AgentVocabularyGuardTests` apply to every new string.

## 1. Intent

The person planning wants to:

1. **Interrogate the plan.** Select a passage and ask why it is the way it is. Get an answer based on what the rounds actually did and on the repo. Push back, and have the outcome come back as diffs against the plan, without waiting for a full round.
2. **See it before it is built.** Judge a UI or an interaction from a mockup or an interactive comp, and an architecture from a diagram, and adjust them now. Today they find out that it doesn't feel right only after it's built.
3. **Annotate visuals** the same way they annotate text.
4. **Compare representations** of the same thing and choose the one that fits.
5. **Keep visuals inline**, as full-width blocks between paragraphs of the plan.
6. **Answer clarifying questions by choosing** (radio buttons, checkboxes, toggles, plus free text) instead of typing prose.
7. **Bring their own generators.** A team's design-system comp kit or diagram tool plugs in without patching Flight Deck.

**Success:** on a plan with a settings screen and a multi-component flow, the person can:
- open a thread on a sentence and get a cited answer in seconds;
- accept a diff with one click;
- see a comp of the screen inline, switch its states and pin a comment on a button;
- see the released tasks cite that comp as their fidelity reference.

### Decisions made in conversation

| # | Decision |
|---|---|
| D1 | A thread is anchored to a place: a quote, a section, a visual, or one element of a visual. "Ask" is a new button on the selection toolbar. |
| D2 | A **live thread agent** answers each thread, one headless turn per message. Round-level work stays with the existing note kinds. |
| D3 | An accepted diff is treated as a human edit. The person accepts or rejects it with ✓ / ✗. |
| D4 | There is one rail. Ask cards sit beside their quote, and opening one expands a wide **thread panel** with an index of every thread. |
| D5 | The thread agent sees **provenance** (the round history) and the **repo**, and can run read-only commands. It never re-runs planning. |
| D6 | The thread agent can make every annotation a person can (diffs, Comment, Highlight, Must change, Replace, Delete) and can ask structured questions. It loads the plan lazily. |
| D7 | Notes from the agent land as pending, labelled with their thread. Diffs from the agent wait for ✓. A per-thread **auto-accept** toggle applies diffs immediately. |
| D8 | The thread agent defaults to the intake's integrator agent and model, and can be changed per thread. It goes through the adapter layer, for all five adapters. |
| D9 | Direct edits to a comp are limited to text, state, variant and size. Layout and feel go through a pinned thread. Comps can be clickable flows across several screens. |
| D10 | Visuals are separate files, versioned with the plan and rendered inline. Planning and tasks reference them. |
| D11 | Visuals come from both rounds and threads. When the plan seems to need a visual, the clarifying questions offer it as a toggle with a cost estimate. A visual requested in a thread is made without asking. |
| D12 | Alternates show as the primary plus a filmstrip of thumbnails, with a two-up Compare mode. |
| D13 | Visual generators are **visual providers** under a Flight Deck contract. A provider-authoring skill ships with Flight Deck. |
| D14 | Release exports the plan and its primary visuals into the repo. Alternates go into a clearly marked `_unused-alternates/` subfolder. |
| D15 | The phone takes part: structured questions, threads, diffs, inline visuals and live comps. It has no pins on visuals in v2. |
| D16 | Rounds can propose changes to a visual but never replace its primary. Reviewers see each visual's source plus a rendered snapshot. |
| D17 | A diff shows as a **gutter bar**: the new text reads as normal prose with a thin green bar beside it. Hovering shows the old text struck through, and the buttons. |
| D18 | **The canvas backs comps.** `comp.*` kinds are canvas documents, and there is no separate HTML comp engine. |

## 2. Scope and build order

The work is in five phases, each usable on its own. There is one spec, one implementation plan per phase and one worktree branch per phase.

| Phase | Ships | Depends on |
|---|---|---|
| **P0** Structured questions | §4 | nothing |
| **P1** Ask threads | §5, §6, and the thread parts of §10 and §11 | P0 |
| **P2a** Visual blocks and diagrams | §7, §8 (Mermaid), the visuals parts of §11, §12 export, and phone visuals | P1 |
| **P2b** Canvas comps | §8 (canvas comps) | P2a, and `feat/canvas-ts-engine` merged to master |
| **P3** Pluggable providers | §9 | P2a (and P2b if comps are to be pluggable) |

**Out of scope for v2.** These go into `docs/FOLLOWUPS.md` when P1 lands:
- d2-language and image-model providers;
- pins on the phone;
- a live MCP front end for thread actions;
- re-running a planning stage from a thread;
- checking a built UI against its comp after implementation;
- moving a note forward onto text that replaced its quote.

## 3. Architecture

Architecture render: [architecture-v1.html](2026-10-31-planning-v2-renders/architecture-v1.html).

```
Flight Deck.app (Mac)                         Phone (FlightDeckMobile)
  PlanTextView                                  PlanReaderScreen
    VisualBlockView (WKWebView attachment)        inline visual (snapshot, tap → live)
  NotesRail: Ask cards · ThreadPanel + index    Thread screen · diffs ✓/✗
  StructuredQuestionView                        StructuredQuestionView
  VisualRenderHost (offscreen snapshots)        ── FleetKit wire (+ capability flags) ──
  IntakeService.send ─────┐                     FleetService · IntakePlanProjection
                          ▼
              intakes/<uuid>/commands.jsonl   (append-only; app, phone via Mac, ThreadRunner)
                 │                       │
                 ▼                       ▼
  IntakeRunner (rounds)            ThreadRunner (new, 1 per intake, fd-abduco)
   only writer of tape.json,        only writer of threads/ and visuals/
   checkpoints/                     ThreadWorkspace · ActionValidator · ProviderHost
                                    ProviderRegistry (repo › user › bundled)
  PlanExporter (at release) → repo docs/plans/<slug>/
```

**Single-writer rule (unchanged, and extended):**
- `IntakeRunner` stays the only writer of `tape.json` and `checkpoints/`.
- `ThreadRunner` is the only writer of `threads/` and `visuals/`.
- When a thread produces something that must reach the plan or a round (a note, or an accepted diff), it appends a command to `commands.jsonl`, the same way a human edit does.
- The app and the phone only append commands.

**ThreadRunner:**
- It is a detached process per intake, started through `FdAbducoRunnerSpawner` like `IntakeRunner`, so threads survive an app restart.
- It reads thread commands from `commands.jsonl`, runs turns, writes thread and visual state, and appends tape commands. It runs alongside rounds and never writes the tape.
- Turns queue per thread. Different threads run in parallel, up to the concurrency cap that rounds already use.
- It exits when the intake has no open threads and no queued visual jobs. The next thread command starts it again.

**On disk.** Everything is under `intakes/<uuid>/` and only added to, so old intakes load unchanged:

```
threads/<threadID>/thread.json      anchor, title, status, agent/model, autoAccept, session id, version followed
threads/<threadID>/turns.jsonl      one record per turn: your message, reply, actions, decision, errors
threads/<threadID>/diffs/<diffID>.json   proposed diff: target checkpoint, range, old, new, state
visuals/<visualID>/r<n>/            one immutable folder per revision (§7)
visuals/requests.jsonl              visual jobs from rounds and threads (written by ThreadRunner)
```

## 4. P0 Structured questions

**Model.** In `Sources/IntakeKit`. It adds structured fields beside the existing `[String]` questions in `TriageExchange`, without removing them:

```swift
public struct StructuredQuestion: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var kind: Kind            // single | multi | toggle | text
    public var options: [Option]     // empty for text; one for toggle
    public var recommended: [String] // option ids; empty means none
    public var allowOther: Bool      // always true for single and multi
    public var cost: Cost?           // set on visual-offer questions (§11)
    public struct Option: Codable, Equatable, Sendable { var id, label: String; var detail: String? }
}
public struct StructuredAnswer: Codable, Equatable, Sendable {
    public var questionID: String
    public var selected: [String]    // option ids
    public var other: String?        // the free-text field
}
```

- **Storage:** `TriageExchange` gains optional `structured: [StructuredQuestion]?` and `structuredAnswers: [StructuredAnswer]?`.
  - A legacy exchange (strings only) still decodes and still renders as text questions.
  - `qaTranscript` renders structured answers as `Q:` / `A: <labels>; Other: <text>`.
- **Schema:** the triage schema in `Triage.swift` gains the structured form. When a triage agent returns plain strings, they become `text` questions, so no adapter gets worse.
- **UI:** `StructuredQuestionView` on the Mac (SwiftUI), with a twin on the phone.
  - Radio rows for single, checkbox rows for multi, a switch for toggle, and a text field for text.
  - "Other…" expands into a text field.
  - The recommended option carries a "recommended" label and starts selected.
- **Wire:** `intake.answer(answers: [StructuredAnswer])`, behind the `structuredQuestions` capability flag.
- **Reuse:** the same component appears in threads (§6) and in the visual offer (§11).

## 5. P1 Ask threads: runtime

**One turn** is one headless run of the thread's agent, through the existing `HeadlessCommand` and adapter profiles. The run uses:
- `--resume <thread session id>` from the second turn on. Every planning adapter already supports resume and a schema-constrained final answer (`Sources/IntakeKit/Headless.swift`, `AgentProfile.swift`).
- The reviewer tool profile, plus **read-only Bash** (D5: planners can always interrogate the repo). The working directory is the project repo.
- From P2a on, **Write limited to the thread's current draft visual folder**, with nothing else writable. It is expressed as a path-scoped allow rule in each adapter's permission flags. An adapter that can't scope writes by path gets no Write, and its `makeVisual` actions are refused with that reason.
- The `ThreadActions` schema as the constrained final answer.
- Reply text streamed to the panel as it arrives.

**ThreadWorkspace.** It is rebuilt for every turn in `threads/<id>/workspace/`, from the checkpoint the thread follows:

| File | Contents |
|---|---|
| `outline.md` | Headings, with section ids and sizes |
| `sections/<id>.md` | One file per section of the current plan |
| `anchor.md` | The anchored quote and its section, or the visual and element |
| `provenance/<checkpoint>.md` | For each checkpoint: the drafts' positions on the anchored section, the cross-check issues and clusters that touch it, the integrator's change verdicts, and the notes the checkpoint consumed. Each item has a stable citation id. |
| `intake.md` | The request and the triage Q&A |
| `visuals.md` | The visuals catalogue and the kinds available (from P2a on) |

The repo itself is referenced by path.

The first turn's prompt holds only the outline, the anchor, the anchor's section, and an index of the other files. The agent reads the rest with its ordinary read tools when it needs them (D6).

**ThreadActions schema.** This is the final answer of each turn:

```json
{
  "reply": "markdown, with citations as [cite:<id>]",
  "decision": "0-3 lines; what was decided this turn, or empty",
  "actions": [
    {"op": "proposeDiff", "checkpoint": 12, "quote": "...", "prefix": "...", "suffix": "...", "replacement": "..."},
    {"op": "addNote", "kind": "mustChange", "anchor": {...}, "note": "..."},
    {"op": "askQuestion", "question": {StructuredQuestion}},
    {"op": "makeVisual", "kind": "diagram.sequence", "brief": "...", "anchorSection": "s3"},
    {"op": "addAlternate", "visualID": "...", "kind": "...", "brief": "...", "reason": "..."}
  ]
}
```

Diffs are anchored with the existing `NoteAnchor` scheme (quote, prefix, suffix, section), so a diff is located the same way a note is.

**ActionValidator** checks each action against the checkpoint it targets:
- a diff's quote must be found exactly once;
- kinds and anchors must be valid;
- question ids must be unique.

A failure is fed into the next turn as an error block. After **2** failed retries the card shows "couldn't apply" and the reason. A citation that doesn't match a workspace id is shown as plain text, never as a link.

**Commands.** These are new `TapeCommand` cases where they touch the tape. `ThreadRunner` reads the thread-only commands:

| Command | Writer | Effect |
|---|---|---|
| `thread.open(threadID, anchor, agent, model)` | app, phone | ThreadRunner creates the thread |
| `thread.message(threadID, text)` | app, phone | Queues a turn |
| `thread.answer(threadID, [StructuredAnswer])` | app, phone | Queues a turn with the answers |
| `thread.setAutoAccept(threadID, Bool)`, `thread.setAgent(...)`, `thread.resolve(threadID)` | app, phone | Changes thread state |
| `applyThreadDiff(threadID, diffID, text?)` | app, phone (on ✓, with optional edited text) | IntakeRunner applies it as a human edit (the `plan.user.md` layer) and records the thread as its source |
| `note(PlanNote)` with `source: thread(threadID)` | ThreadRunner | Same as today; the new optional field labels the card |

`applyThreadDiff` uses the same path as `editPlan`, including `PlanEditRouter` / `EditLayer.retarget` when a newer round has landed. An old runner drops the unknown command, as it already does with unknown commands. The Mac never offers threads to a runner that predates them: the runner advertises a `threads` capability in `tape.json`.

**Following versions:**
- A thread follows the newest checkpoint. When a round lands, the next turn's workspace is rebuilt, and the conversation shows a divider ("Now reading Refine 3").
- A pending diff keeps the checkpoint it was proposed on and is rebased with `EditLayer.retarget`.
- If the rebase fails, the diff becomes **stale**. It is never applied as a guess, and it offers a **Re-propose** action that runs one turn against the current version.
- With auto-accept on, diffs always target the newest checkpoint.

**Resolve.** A resolved thread moves to Resolved in the index. It takes no more turns until it is reopened, and it never feeds rounds. Notes it left are separate and still feed the next round.

## 6. P1 Ask threads: UX

Renders: [thread-ux-v1.html](2026-10-31-planning-v2-renders/thread-ux-v1.html) (layout) and [diff-slim-v2.html](2026-10-31-planning-v2-renders/diff-slim-v2.html) (option B, the one chosen).

**✦ Ask** is the last button on `SelectionToolbar`.
- With a selection, it opens the panel on a new thread anchored to that selection, with the composer focused.
- With no selection, it starts a thread on the whole plan.
- The *Question* note kind is removed from the toolbar (§13).

**Ask cards** sit in the notes rail's aligned lane beside their quote, the same way notes do.
- Each card shows a title, live status ("answering"), a one-line excerpt of the latest reply, counts (diffs, notes, messages) and Open ⤢.
- A stale thread shows a stale pill and Re-propose.
- Notes the agent made show "✦ from thread …" and can be withdrawn, as notes can today.

**Thread panel.** "Threads (n) ⤢" in the rail header, or opening a card, replaces the rail with a wide panel.
- **Index**, on the left:
  - a filter field;
  - three groups: **Open** (by section, in plan order), **Needs you** (the agent asked a question, or a diff is waiting) and **Resolved**;
  - "＋ New thread on whole plan".

  Selecting a thread scrolls the plan to its anchor.
- **Conversation**, on the right:
  - The header has the title, Resolve, the agent/model menu, the auto-accept switch, the version the thread follows, and the anchored quote.
  - Citations are chips. They open the intake, a checkpoint (through the round list navigation), a cross-check issue, or a `file:line`.
  - Structured questions appear inline (§4).
  - Actions are listed, each linked to its copy in the plan.
  - The composer sends with ⌘↩, and sends and resolves with ⌘⇧↩. While the panel has focus, ⌘[ and ⌘] move between threads.

**Diffs in the plan (D17, option B):**
- At rest, the proposed text reads as normal prose, with a 3 pt green bar in the left margin and a small ✦.
- On hover, the old text appears struck through above it, with a compact toolbar: ✓ Accept, ✗, Edit, and ✦ (open the thread).
- Edit lets the person change the new text in place before accepting.
- There is no header bar, and every diff uses this form whatever its size.

The panel's state (which thread is open, panel width) is remembered per intake for the session, like `otherVersionsExpanded`.

## 7. P2a Visual blocks: format and storage

**In the plan.** A visual is a fenced block. It is plain text, so the plan stays readable anywhere:

````
```fd-visual id=pairing-handshake
Pairing handshake: phone, Mac and hostd
```
````

The body line is the caption. An integrator can write `id=… pending` as a placeholder for a visual it has requested (§11). The block renders full width in the plan (D10).

**Revisions.** Each revision lives in `visuals/<visualID>/r<n>/`, which never changes once final:

```
manifest.json     provider id+version, kind, title, entry, states, sizes, pins scheme,
                  checkpoint made on, made by (thread|round|you), parent revision,
                  alternates [{revision, kind, reason, by}], primary: true|false
<source files>    e.g. diagram.mmd, or canvas.ref.json (P2b)
snapshot@<state>-<size>.png
pins.json         pins on this revision
```

**Block state.** `visuals/<visualID>/block.json`, written by ThreadRunner, lists the visual's representations in filmstrip order and marks the ★ primary. Every plan checkpoint records the block states it saw, so an old version of the plan shows its visuals as they were then.

**Pins.** A pin is a note anchored to an element: `{revision, target, note}`.
- The `target` is, in order of preference: a node id (diagrams), a canvas element id (comps), or an `{x, y}` position as fractions of the block (the fallback).
- Pins are `PlanNote`s with a new optional `visualAnchor`, so they go to rounds like any other note.
- If a pin's target is gone in a later revision, the pin is listed under the block's "on another revision" section, the same way notes are pinned to versions. It is never moved to a guessed target.

## 8. P2a/P2b Visual blocks: rendering, comps and editing

Renders: [visual-block-alternates-v2.html](2026-10-31-planning-v2-renders/visual-block-alternates-v2.html) (option B with Compare, the one chosen) and [visual-blocks-v1.html](2026-10-31-planning-v2-renders/visual-blocks-v1.html).

**VisualBlockView (Mac)** is an attachment in `PlanTextView`. It holds a header and a `WKWebView`:
- **Header:** the title, a chip with the primary's kind, **states** and **sizes** segmented controls (from the manifest), Pins (n), Compare, ✎ Edit (comps only) and ✦ Ask.
- **Body:** the live render.
- **Filmstrip:**
  - a thumbnail of every representation, with ★ on the primary;
  - an amber outline and its reason on an alternate that a round proposed;
  - "＋ Another view…", which opens the block's thread with a `makeVisual` request already filled in.
- **Compare** splits the body two-up, with "Make primary" on the right pane, then collapses back.
- **Off-screen blocks** show their snapshot and switch to the live view when scrolled into view, so a plan with many visuals never runs many web views.
- **Loading:** the web view loads only from the revision folder (`loadFileURL(_:allowingReadAccessTo:)` scoped to it). Networking is disabled, and navigation outside the folder is cancelled.

**Diagrams (P2a)** come from the bundled provider `fd.diagram.mermaid`:
- sequence, component (flowchart), flow, state and ER diagrams;
- rendered with a pinned, vendored `mermaid.js`;
- pins use node ids.

`fd.diagram.svg` (P3) is the hand-written fallback.

**Comps (P2b, D18).** `comp.screen` and `comp.flow` are **canvas documents**.
- **Source.** A comp revision's source is `canvas.ref.json`: the canvas document id, the document checkpoint id, viewport presets and states. The canvas journal and blobs stay in canvas storage, which the canvas service owns.
- **Generation.** The agent writes canvas NDJSON operations to the draft revision folder. `ProviderHost` streams them to the canvas engine (`flightdeck canvas stream`) and records the resulting checkpoint id. Generation is incremental and resumable, as the canvas spec defines.
- **States and sizes.** States are canvas screens or variants declared in the document. Sizes are canvas viewport presets. A clickable flow is a canvas document with several screens, and its filmstrip slot shows a storyboard strip.
- **Pins** are canvas annotations (element id plus revision). They are mirrored into `pins.json`, so rounds and export can read them without the canvas engine.
- **Edit mode** is the canvas's own editing, restricted to replacing text and switching state and size (D9). Saving creates a canvas checkpoint and a new comp revision. The edit reaches later turns and rounds as a human edit, so no agent regenerates over it.
- **Comments.** For a comp attached to an intake, the canvas's "send comments" delivery goes to that comp's thread as a `thread.message` command, not to a terminal session.
- **Rollout.** The canvas spec's rollout flag controls this. Comps appear only when the canvas is enabled. Mermaid diagrams work without it.

**How this maps onto the canvas plan's Task 10.** Task 10 is owned by the Visual Companion 2 session. That session has confirmed the shapes below against `feat/canvas-ts-engine`, and it treats them as proposed until you approve this spec.
- **`CanvasArtifact`** is the native model of `canvas.ref.json`: `{canvasID, documentID, branchID, checkpointID, screens: [id], viewports: [id], createdBy: thread|round|you, intakeID, visualID, revision}`. It is a durable reference, never a URL.
  - There is one document per canvas, rooted at scope `"root"`, and `{canvasID, documentID}` is the durable identity.
  - `branchID` is needed because a restore followed by an edit continues on a new branch.
  - **States are the comp's screen-scope node ids.** A multi-screen flow is several screen nodes. **Sizes are kit viewport profiles.** Task 10 declares both lists in the document root props, and `checkpoint.inspect` returns them.
- **`CanvasProvider`** is the native side of the bundled `fd.comp.canvas` provider (§9). `ProviderHost` calls it through the app's local control socket (`flightdeck canvas …`), because the canvas engine lives in the app's WKWebView.
  - **Create:** `flightdeck canvas create --intake <uuid> --visual <id>`. This is a canvas owned by the intake: its authority comes from the intake, not from a tab, because a detached ThreadRunner has no tab. Task 10 adds it.
  - **Stream:** `canvas stream` takes NDJSON, with a durable acknowledgement per line. `engine_not_ready` is retried with the original eventId. This exists today.
  - **Checkpoint:** `checkpoint.create` takes a checkpointId the caller chooses, which is **`<visualID>-r<n>`**. It is idempotent on the eventId. This exists today.
  - **Export one checkpoint:** `canvas export-checkpoint <canvasID> <checkpointID> --out <dir>` writes static HTML plus the pinned kit CSS and fonts, with no engine and no scripts. Release export and the phone bundle both use it. Task 10 adds it.
  - **Pins:** `annotation.list` is the source for the `pins.json` mirror. This exists today.
  - If the app isn't running, the visual job fails with "open Flight Deck to make comps". It never waits silently.
- **`CanvasAttachmentView`** is the body of `VisualBlockView` for a comp revision. Task 10 adds it, with:
  - a **read-only mount at an exact checkpointID** that never moves a branch head;
  - the restricted edit mode (text plus screen/viewport switching), where saving creates the next `<visualID>-r<n>` checkpoint;
  - annotation mode for pins.

  Element ids survive text edits, and annotations attach to node ids. Confirmed.
- **Annotations** on an intake comp use a new canvas outbox destination type, `intakeThread`. Swift appends `thread.message(threadID, text, elementId, subjectRevision)` to `intakes/<uuid>/commands.jsonl` together with the outbox receipt.
- **Snapshots of comps** come from the canvas: in Task 10, `WKWebView.takeSnapshot` on the offscreen engine view, one PNG per screen and per viewport. VisualRenderHost asks the canvas for comps instead of rendering them itself. This is unmeasured: the offscreen view suspends rAF, so layout has to be confirmed final before each capture.
- **Phone:** the live engine is macOS only. Until Task 10 shows on the simulator that an `export-checkpoint` bundle loads offline in an iOS WKWebView, **the phone shows only snapshots for comps**.

Spike questions (1), (3) and part of (2) below are already answered. P2b's spike now confirms (2), the read-only mount, and (4), iOS, on the merged branch.

**Integration spike (the first task of P2b).** On the merged canvas, confirm that:
1. a document can be created and streamed headlessly from `ProviderHost`;
2. a document checkpoint can be rendered read-only at a given checkpoint id inside `VisualBlockView`;
3. element ids stay the same across the text-only edits allowed here;
4. a static export of one checkpoint renders offline on iOS.

If (4) fails, the phone shows only snapshots for comps until it is fixed.

**VisualRenderHost** lives in the app, because WebKit needs it.
- When a revision becomes final, it renders `snapshot@<state>-<size>.png` offscreen: every declared state at the default size, plus the default state at every size.
- Snapshots exist only while the app is running. A round that runs while the app is closed gets source only, and its record says so.
- Running WebKit inside the detached runner was considered and rejected, because it would add a new kind of fragility.

## 9. P3 Visual providers

A **provider** is a folder with a `provider.toml`, which is TOML like `delegate.toml` and `[infra.*]`:

```toml
id = "fd.diagram.mermaid"
name = "Mermaid diagrams"
version = "1.0.0"
contract = 1

[[kind]]
id = "diagram.sequence"
summary = "Message order between named participants"
output = "mermaid"          # html | svg | png | mermaid | canvas
entry = "diagram.mmd"
pins = "nodes"              # nodes | canvas | dom | xy
states = []
sizes = ["default"]
cost = { seconds = 20, tokens = 6000 }
instructions = "kinds/diagram.sequence.md"
assets = []

[generator]                 # optional; omit for a data-only provider
command = ["./bin/render", "{source}", "{out}"]
timeout = "60s"
network = false
```

**Making a visual** (`makeVisual`, from a thread or from a round's request):
1. The agent chooses a kind from the catalogue in its workspace. The catalogue lists every enabled provider's kinds with their summaries, and lists unavailable kinds with the reason.
2. ThreadRunner creates a draft revision folder, copies in the kind's `assets`, and gives the agent the kind's `instructions` and the folder path.
3. In the same turn, the agent writes the source and a small `visual.json` (title, caption, states) with its scoped Write (§5). It's only files and instructions, so it works on all five adapters.
4. If the provider declares a `[generator]`, `ProviderHost` runs it inside ThreadRunner, never inside the agent:
   - the working directory is the draft folder;
   - it has a timeout and no network;
   - it runs under `sandbox-exec` where available;
   - its output must stay inside the folder.

   With `output = "canvas"`, the built-in canvas streamer (§8) is used instead.
5. **Validation:** the entry file exists, the declared states exist, there are no external URLs, and the folder is at most 10 MB. Then `manifest.json` is written, the revision is final, and VisualRenderHost renders its snapshots.
6. A validation failure goes back to the agent in its next turn, with up to 2 retries. After that, the block shows "couldn't make this visual" and the reason.

**Where providers come from, in order of precedence:**
1. the repo, `.flightdeck/visual-providers/`;
2. the user, `~/Library/Application Support/Flight Deck/visual-providers/`;
3. bundled with Flight Deck.

A repo provider with the same `id` overrides the others in that repo. Settings → Planning lists providers with their source and an on/off switch.

**Repo trust gate:**
- A repo provider with no `[generator]` is data only and is used without asking.
- A repo provider with a generator needs a one-time approval. The approval is recorded against a SHA-256 of the provider folder, so any change to the folder asks again.
- Until it is approved, its kinds are listed to the agent as unavailable, with the reason.

**Contract versioning.** Providers declare `contract = 1`. A provider with a higher contract number shows "needs a newer Flight Deck" and is never partly loaded. Within one contract version, fields can only be added.

**Bundled set:**
- `fd.diagram.mermaid`, rewritten as a contract-1 folder in P3, which tests the contract on a real provider;
- `fd.diagram.svg`;
- `fd.comp.canvas` (`output = "canvas"`), once P2b has landed.

**Provider-authoring skill.** `flight-deck:visual-provider` ships in the bundled plugin. It reaches claude through `--plugin-dir` and codex through the `CODEX_HOME` skill path, following the existing patterns in `ClaudePluginLocation` and `CodexDelegateSkill`.
- It writes a provider folder in one of two ways:
  - from a description;
  - by wrapping an existing skill, where the skill's body becomes a kind's `instructions` and its assets become `assets`.
- It then runs **`flightdeck provider check <dir>`**. That validates the manifest and its kinds, then makes one sample visual per kind with a cheap model, validated exactly as `ProviderHost` would validate it.
- A provider that passes `check` loads in planning.

## 10. Phone and wire

**Capability flags** in the Mac's intake detail: `structuredQuestions` (P0), `threads` (P1), `visuals` (P2a), `comps` (P2b).
- The phone shows a feature only when its flag is present, so an old Mac never receives an op that would make it drop the socket.
- New projection fields are optional, so an old phone ignores them.

**Ops.** Each new case lands in one commit with every handler arm, because wire enum cases are atomic.

| Op | Purpose |
|---|---|
| `intake.answer(answers)` | §4 |
| `intake.thread.send(threadID?, anchor?, text)` | Reply to a thread, or open one when `threadID` is nil. The anchor is the reader's block index plus a quote, as for phone notes. |
| `intake.thread.get(threadID, since?)` | Fetch messages on demand; they are never pushed |
| `intake.thread.resolve(threadID)` | Resolve a thread |
| `intake.diff.decide(threadID, diffID, accept)` | Accept or reject a diff; refused with `diff_stale` when the diff is stale |
| `visual.fetch(visualID, revision, part: snapshot\|bundle)` | Sent in chunks. A revision never changes, so it is cached by `(visualID, revision)` indefinitely. At most 10 MB. |

**Projection** (`IntakePlanProjection`) carries:
- thread summaries: title, anchor, status (open, needsYou, stale, resolved), counts, and the latest excerpt;
- pending diffs in full;
- open questions;
- visual references (id, revision, kinds, alternates, states), so the reader can lay out blocks before their bytes arrive.

**Phone UI.** Files stay flat in `Sources/FlightDeckMobile/`.
- **Plan reader:** a visual shows inline as its snapshot with the filmstrip. Tapping opens a full-screen live `WKWebView` from the cached bundle, with networking off and state and size switches. No pins in v2.
- **Diffs:** the same gutter-bar form. Tapping shows the old text, with Accept / ✗.
- **Ask:** added to the reader's selection menu beside Note. It opens a thread screen with the conversation, inline structured questions and a composer.
- **`StructuredQuestionView`:** shared by triage and threads.
- **Needs you:** the intake's row in the fleet list shows a count badge, reusing the unread mechanism.
- **Sending:** sends go through an outbox like `NoteOutbox` and show as pending until the projection agrees.

## 11. Rounds integration

**What rounds see** (additions to `RoundPrompts.steering`):
- **Thread decisions since the last round.** For each thread touched, its title, its anchor and its latest `decision` line. Accepted diffs already arrive as human edits. The decision line carries the reason behind them, so a refine round doesn't quietly undo them.
- **Visuals.** For each block: id, kind, anchor section, the primary's source path, the default snapshot path, and its pins.
  - Agents read snapshots with their image-capable read tool.
  - An adapter that can't read images in headless mode gets source only, and the round record says so.
  - A new `image.read` cell in `test-adapters.sh` establishes which adapters can. Claude's Read opens PNGs; the other four are unverified.

**What rounds may do** (schema additions):
- The integrator can add a ` ```fd-visual id=… pending``` ` placeholder together with a `visualRequest {id, kind, brief, reason}`.
- The integrator can propose an alternate: `{visualID, kind, brief, reason}`.
- Reviewers can aim an issue at a visual: `{visualID, pin target, issue}`. Cross-check clusters treat it like any other issue.

**What rounds may not do:** change a primary, delete a block, or edit a revision (D16).

**Visual requests from rounds** are recorded in the round's checkpoint record. ThreadRunner picks them up:
- If the kind was approved in triage, or has already been approved for this intake, it is generated at once, and the placeholder shows "Generating…".
- Otherwise it shows as a **suggested visual** chip, with its cost and a "Make it" button. Nothing is spent until the person clicks it.
- Proposed alternates land in the filmstrip with the amber outline.

**Triage visual offer (D11).** When triage judges that a plan calls for visuals, it returns a `multi` structured question that lists candidate visuals plus "Other…".
- Each option carries a `cost`: approximate seconds and tokens from the provider manifest, scaled by the chosen model's price.
- The kinds the person checks are approved for the intake in advance.

## 12. Encode and release export

**Encode.** The encode prompt receives the visuals catalogue. For each task, it cites the visuals that task implements, by id and state. Each task body gains:

```
Fidelity references (implement to match; don't redesign):
- docs/plans/<slug>/visuals/<id>/ — states: default, empty, error
```

Citing an id that doesn't exist fails encode validation, as a broken dependency edge does.

**PlanExporter** runs during release, before `br create`, so every cited path already exists. It writes:
- **`docs/plans/<slug>/plan.md`.** Each `fd-visual` block becomes an image link to its default snapshot, plus a link to its folder.
- **`visuals/<id>/`.** The primary's files, its snapshots, `pins.json`, and a `README.md` giving the kind, the states and how to open it. A canvas comp is exported through the canvas's export path, as an offline bundle of its checkpoint.
- **`visuals/<id>/_unused-alternates/<n>/`.** Each has a one-line `README.md`: "Not chosen. Do not implement from these."

Rules for the export:
- **Slug:** taken from the intake title, made unique with `-2` and so on. Releasing the same intake again overwrites its own folder, and git keeps the history.
- **Commit:** **it commits those paths only**, with a message in the house style (`docs: plan <slug> for release`). It never touches other changes in the shared working copy.
- **Confirmation:** the release confirmation sheet lists the files and the commit.
- **Safety:** uncommitted changes under `docs/plans/<slug>/` block the release with a message, and nothing is overwritten.

## 13. Migration and compatibility

- **Storage is only added to:** new optional fields, new files, new commands. Old `tape.json`, `commands.jsonl`, `intake.json` and checkpoint folders load unchanged, and an old runner drops unknown command lines.
- **The *Question* note kind** is removed from the toolbar and from the phone composer.
  - Existing Question notes stay readable and still feed rounds.
  - An old phone that sends `question` is still accepted.
  - No data is rewritten.
- **New optional fields:** `PlanNote` gains `source` (thread) and `visualAnchor`; `TriageExchange` gains the structured fields; `WireNote` and the intake detail gain optional fields.

## 14. Testing

**Rules:**
- TDD: each test is seen failing against the code it targets before the fix.
- No assertion is weakened.
- **Nothing that opens a window, launches the app or runs XCUITest runs on the development Mac.**

| Layer | How |
|---|---|
| Pure logic | Unit tests via `./scripts/test-unit.sh`, which runs on the UI-test Mac. See the list below. |
| Runner end to end | `ThreadRunner` against a scripted fake agent, following `scripts/opencodeprobe/fake_llm.py`. Cases: one turn, a retry after a bad diff, two threads in parallel, a round landing mid-turn, and a visual job with a generator. No tokens spent. |
| Live adapters | New `thread.turn`, `image.read` and `write.scoped` cells in `./scripts/test-adapters.sh`, cheap tier by default. |
| Wire | `IntakeWireCodingTests` round trips for every op and projection field, and decoding between old and new Mac and phone builds in both directions. |
| Rendering | Offscreen `layer.render(in:)` renders of Ask cards, the panel, the diff bar and the visual header, inspected as PNGs. WebKit snapshot tests in the hosted unit suite on the UI-test Mac. |
| Phone | `./scripts/test-ios.sh`: `StructuredQuestionView` logic, the thread outbox and the visual cache. |
| UI flows | Only through `FD_UITEST_ONLY=… ./scripts/smoke-remote.sh`. P1: Ask → reply → accept diff. P2: open a visual → switch state → pin. |
| Maintainer GUI checklist | A new `docs/FLIGHT-CONTROL-PLANNING-V2-CHECKLIST.md`, with one section per phase. Every GUI claim in a phase report has an entry. |

The pure-logic unit tests cover:
- decoding structured questions, including legacy `[String]` questions;
- parsing `ThreadActions` for each adapter, from fixtures **captured from real CLI output**;
- `ActionValidator`: a diff applies, a diff is stale, and a rebase through `EditLayer.retarget`;
- `ThreadWorkspace`: splitting the outline and sections, and building a provenance index from a scrubbed real checkpoint folder;
- the order in which pins are resolved;
- manifest parsing and the trust hash;
- `PlanExporter`'s paths and the scope of its commit;
- loading old files;
- an old runner tolerating the new commands.

## 15. Docs updated in each phase's branch

- `docs/ARCHITECTURE.md`: threads and visuals sections, and the single-writer table.
- `docs/HANDOFF-plan-notes.md`: Ask cards beside notes, and the Question kind retired.
- A new `docs/HANDOFF-planning-v2.md`.
- `docs/FOLLOWUPS.md`: the out-of-scope list from §2.
- The GUI checklist from §14.

## 16. Risks and open verifications

1. **Image reading per adapter** is unverified for codex, grok, gemini and opencode in headless mode (§11). Mitigation: a capability cell, and source only as the fallback.
2. **Canvas readiness gates P2b.** Mitigation: P2a ships diagrams independently, and the P2b spike (§8) answers the four integration questions before any comp UI is built. The canvas is being built in parallel by the Visual Companion 2 session.
3. **Snapshots need the app running** (§8). Accepted; the round record notes it.
4. **Thread agents' tools are wider than reviewers' tools.** They get read-only Bash, under the same restricted-command policy reviewers already run with, plus Write limited to the current draft visual folder (§5). The `write.scoped` cell checks that each adapter enforces the path limit. An adapter that can't enforce it cannot make visuals from threads.
5. **Comps need the app running**, as snapshots do, because the canvas engine runs inside the app (§8). Accepted; a comp job fails visibly when the app is closed.
6. **Live threads cost tokens.** Each message is a resumed headless turn. The thread header shows the agent and model. The default is the integrator's, and the person can choose a cheaper one per thread.

## Errata: P3 core (2026-11-01)

What was built differs from §9 in these ways. The code and `docs/ARCHITECTURE.md` ("Visual providers") are the truth.

- **K-R1, parser.** `provider.toml` is parsed by `ProviderManifestParser` inside HostKit, beside `DelegateConfigParser`, because the TOML reader is internal to HostKit and IntakeKit cannot import it. Problems come back as `ProviderManifestIssue` values.
- **K-R2, trust.** `Sources/ProviderKit/` is compiled into the app and the CLI. The digest is SHA-256 over sorted relative paths, each with a NUL, an 8-byte length, the owner-exec bit and the bytes. Links, FIFOs and devices are refused. A failed permission read throws. Approvals are `{repoPath, providerID, digest, approvedAt}` in `provider-trust.json`. Approve must be given the digest the UI showed and refuses on a mismatch or over a corrupt file. xattrs are not hashed. `.DS_Store` and swap files are hashed, so they ask again. A data-only repo provider skips the digest.
- **K-R3, sandbox.** Generators run under `sandbox-exec`, and are refused when it is missing. Network is denied. `network = true` parses and is refused at run time. This goes beyond §9's "no network, timeout, folder only":
  - the generator runs from a private copy of the folder, re-hashed against the approval;
  - the profile also denies reads of the home folder and shared scratch folders, and denies `lsopen`, `appleevent-send`, `mach-lookup` and signals outside the sandbox;
  - fds are closed on spawn, and stdout, `out/`, `tmp/` and single files have size caps;
  - the whole process group is killed on timeout.
- **xcrun seed.** Each run starts with a copy of a Flight Deck-owned xcrun cache, never the user's `T/xcrun_db`, and the copy is never saved back. This keeps `git` and `swift` shims at about 0.15 s without exposing path history.
- **Pipe-holder kill.** `CommandRunner` now kills every holder of a run's pipes after a 1 s grace (SIGTERM, then SIGKILL) for every `processGroup` run in the app, not only providers. The old behaviour was a hang in the same cases. A late write from a same-group child is lost, and is reported on stderr.
- **K-R4, Settings.** The list is in the **Flight Control** tab, not "Planning". The on/off switch is per (source, id): `UserDefaults` key `visualProviders.disabled.v2`, entries `<source>:<id>`. §9 says a repo override wins only in that repo, so a bundled switch must not reach it. The `v1` key (ids only) is migrated. Approve is off while the trust file is unreadable, and "Move damaged file aside" is offered. Rows are keyed by source and folder.
- **K-R5, skill install.** `CodexDelegateSkill` is generalized to `CodexBundledSkill(name:)`, which copies a folder with a `.flightdeck-managed` digest sidecar and installs `delegate`, `peer-messaging` and `visual-provider`. It never follows a link and swaps a refresh in whole. A `.git` inside an installed skill folder counts as a user edit and freezes the folder, because a refresh would destroy a repo. Such a folder gets no auto-upgrade.
- **K-R6, `provider check`.** It is local, intercepted before the transport. It also checks that each `entry` exists. A generator runs only with an explicit **`--run-samples`**, and the argv is printed first, against `samples/<kind>/`. It does not make a sample visual with a cheap model (§9, last bullet): that step needs ProviderHost and is deferred. Exit codes are 0 valid, 1 problems, 2 usage.
- **Deferred from §9:** `ProviderHost` (providers are not called by planning yet), the bundled provider folder and `fd.comp.canvas`.
