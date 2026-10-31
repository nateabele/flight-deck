# Flight Control planning v2: Ask threads, visual blocks, pluggable visual providers

Status: design approved section by section in conversation, 2026-10-31. Not yet implemented.
Supersedes nothing; extends the Level 2 "Author" pipeline ([intake design](2026-09-26-flywheel-intake-design.md) and its follow-ups) and the notes rail ([HANDOFF-plan-notes.md](../../HANDOFF-plan-notes.md)).
Depends on, for comps only: the canvas ([2026-10-24-visual-companion-canvas-design.md](2026-10-24-visual-companion-canvas-design.md), branch `feat/canvas-ts-engine`).

Words: UI and anything sent to an agent says *tasks* (never "beads"), *agent* (never "seat"), *Flight Control* (never "flywheel"). Code identifiers keep their names. `TerminologyGuardTests` and `AgentVocabularyGuardTests` apply to every new string.

## 1. Intent

The person planning wants to:

1. **Interrogate the plan.** Select a passage, ask why it is the way it is, get an answer grounded in what the rounds actually did and in the repo, push back, and have the result land as diffs against the plan, without waiting for a full round.
2. **See it before it is built.** Judge a UI or an interaction from a mockup or an interactive comp, and an architecture from a diagram, and tweak them now, instead of finding out after the system is built that it does not feel right.
3. **Annotate visuals** as they annotate text.
4. **Compare representations** of the same thing and choose the one that fits.
5. **Keep visuals inline** in the plan's flow, as full-width blocks between paragraphs.
6. **Answer clarifying questions by choosing**, with radio buttons, checkboxes or toggles plus free text, not by typing prose.
7. **Bring their own generators**: a team's design-system comp kit or diagram tool plugs in without patching Flight Deck.

Success: on a plan with a settings screen and a multi-component flow, the person can open a thread on a sentence, get a cited answer in seconds, accept a diff with one click, see a comp of the screen inline, switch its states, pin a comment on a button, and have the released tasks cite that comp as their fidelity reference.

### Decisions made in conversation

| # | Decision |
|---|---|
| D1 | Threads are anchored to a place: a quote, a section, a visual, or a visual element. "Ask" is a new button on the selection toolbar. |
| D2 | A thread is answered by a **live thread agent**, one headless turn per message. Round-level work stays with the existing note kinds. |
| D3 | An accepted diff is treated as a human edit, accepted with ✓ / ✗. |
| D4 | One rail, with Ask cards aligned beside their quote; opening one expands a wide **thread panel** with an index of every thread. |
| D5 | The thread agent sees **provenance** (round history) and the **repo**, and can run read-only commands. It never re-runs planning. |
| D6 | The thread agent can make every annotation a person can (diffs, Comment, Highlight, Must change, Replace, Delete) and ask structured questions. It loads the plan lazily. |
| D7 | Agent notes land as pending (labelled with their thread); agent diffs wait for ✓. A per-thread **auto-accept** toggle applies diffs at once. |
| D8 | The thread agent defaults to the intake's integrator agent and model, changeable per thread. It goes through the adapter layer for all five adapters. |
| D9 | Comps: direct edits are limited to text, state, variant and size; everything about layout and feel goes through a pinned thread. Comps may be clickable multi-screen flows. |
| D10 | Visuals are separate files, versioned with the plan, rendered inline. Planning and tasks reference them. |
| D11 | Visuals come from both rounds and threads. A visual the plan seems to need is offered as a toggle with a cost estimate in the clarifying questions. A visual requested in a thread is just made. |
| D12 | Alternates: primary plus a filmstrip of thumbnails, with a Compare (two-up) mode. |
| D13 | Visual generators are **visual providers** under a Flight Deck contract. A provider-authoring skill ships with Flight Deck. |
| D14 | Release exports the plan and its primary visuals into the repo; alternates go into a clearly marked `_unused-alternates/` subfolder. |
| D15 | The phone participates: structured questions, threads, diffs, inline visuals and live comps. No pins on visuals on the phone in v2. |
| D16 | Rounds propose visual changes and never replace a primary. Reviewers see a visual's source plus a rendered snapshot. |
| D17 | Diffs render as a **gutter bar** (B): new text as prose with a thin green bar; hovering shows the old text struck through and the buttons. |
| D18 | **The canvas backs comps.** `comp.*` kinds are canvas documents; there is no separate HTML comp engine. |

## 2. Scope and build order

Four phases, each usable on its own. One spec; one implementation plan per phase; one worktree branch per phase.

| Phase | Ships | Depends on |
|---|---|---|
| **P0** Structured questions | §4 | none |
| **P1** Ask threads | §5, §6, the thread parts of §10 and §11 | P0 |
| **P2a** Visual blocks and diagrams | §7, §8 (Mermaid), §11 rounds visuals, §12 export, phone visuals | P1 |
| **P2b** Canvas comps | §8 (canvas comps) | P2a, and `feat/canvas-ts-engine` merged to master |
| **P3** Pluggable providers | §9 | P2a (P2b if comps are to be pluggable) |

Out of scope for v2 (recorded in `docs/FOLLOWUPS.md` when P1 lands): D2 and image-model providers; pins on the phone; a live MCP front end for thread actions; re-running a planning stage from a thread; checking a built UI against its comp after implementation; mapping a note forward onto replaced text.

## 3. Architecture

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

**Single-writer rule (unchanged and extended).** `IntakeRunner` remains the only writer of `tape.json` and `checkpoints/`. `ThreadRunner` is the only writer of `threads/` and `visuals/`. Anything a thread does that must reach the plan or a round (a note, an accepted diff) is a command appended to `commands.jsonl`, exactly like a human edit. The app and the phone only append commands.

**ThreadRunner.** A detached process per intake, started through `FdAbducoRunnerSpawner` like `IntakeRunner`, so threads survive an app restart. It reads `commands.jsonl` for thread commands, runs turns, writes thread and visual state, and appends tape commands. It runs concurrently with rounds and never writes the tape. Turns are queued per thread; different threads run in parallel up to the concurrency cap rounds already use. It exits when the intake has no open threads and no queued visual jobs, and is restarted on the next thread command.

**On disk** (all under `intakes/<uuid>/`, additive; old intakes load unchanged):

```
threads/<threadID>/thread.json      anchor, title, status, agent/model, autoAccept, session id, version followed
threads/<threadID>/turns.jsonl      one record per turn: your message, reply, actions, decision, errors
threads/<threadID>/diffs/<diffID>.json   proposed diff: target checkpoint, range, old, new, state
visuals/<visualID>/r<n>/            one immutable folder per revision (§7)
visuals/requests.jsonl              visual jobs from rounds and threads (written by ThreadRunner)
```

## 4. P0 Structured questions

**Model** (`Sources/IntakeKit`, replacing the `[String]` questions in `TriageExchange` additively):

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

- `TriageExchange` gains optional `structured: [StructuredQuestion]?` and `structuredAnswers: [StructuredAnswer]?`. A legacy exchange (strings only) still decodes and still renders as text questions. `qaTranscript` renders structured answers as `Q:` / `A: <labels>; other: <text>`.
- The triage schema (`Triage.swift`) gains the structured form. A triage agent that returns plain strings is mapped to `text` questions, so no adapter regresses.
- **UI:** `StructuredQuestionView` (Mac, SwiftUI) and its phone twin. Radio rows for single, checkbox rows for multi, a switch for toggle, a text field for text. "Other…" expands a field. The recommended option carries a "recommended" label and is preselected.
- **Wire:** `intake.answer(answers: [StructuredAnswer])`, gated by the `structuredQuestions` capability flag.
- The same component is used in threads (§6) and for visual offers (§11).

## 5. P1 Ask threads: runtime

**One turn** = one headless run of the thread's agent through the existing `HeadlessCommand` / adapter profiles, with:
- `--resume <thread session id>` after the first turn (every planning adapter already supports resume and a schema-constrained final answer, `Sources/IntakeKit/Headless.swift`, `AgentProfile.swift`);
- the reviewer tool profile plus **read-only Bash** (D5: planners can always interrogate the repo), cwd = the project repo;
- the `ThreadActions` schema as the constrained final answer;
- the reply text streamed to the panel as it arrives.

**ThreadWorkspace** (built per turn, in `threads/<id>/workspace/`, from the checkpoint the thread follows):
- `outline.md`: headings with section ids and sizes;
- `sections/<id>.md`: one file per section of the current plan;
- `anchor.md`: the anchored quote with its section, or the visual and element;
- `provenance/<checkpoint>.md`: per checkpoint, the drafts' positions on the anchored section, cross-check issues and clusters touching it, the integrator's change verdicts, and the notes it consumed (§1 of the notes handoff), each with a stable citation id;
- `intake.md`: the request and the triage Q&A;
- `visuals.md`: the visuals catalogue and kinds available (P2a on);
- the repo, by path.

The first turn's prompt contains only the outline, the anchor, its section, and an index of the other files. The agent reads the rest with its ordinary read tools as needed (D6).

**ThreadActions schema** (final answer of each turn):

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

Diffs are anchored with the existing `NoteAnchor` scheme (quote, prefix, suffix, section), so they locate the same way notes do.

**ActionValidator** checks each action against the checkpoint it targets: the diff's quote locates uniquely, kinds and anchors are valid, question ids are unique. A failure is fed into the next turn as an error block; after **2** failed retries the card shows "couldn't apply" with the reason. Citations that do not resolve to a workspace id are shown as plain text, never as links.

**Commands** (new `TapeCommand` cases where they touch the tape; thread-only commands are read by `ThreadRunner`):

| Command | Writer | Effect |
|---|---|---|
| `thread.open(threadID, anchor, agent, model)` | app, phone | ThreadRunner creates the thread |
| `thread.message(threadID, text)` | app, phone | queues a turn |
| `thread.answer(threadID, [StructuredAnswer])` | app, phone | queues a turn with the answers |
| `thread.setAutoAccept(threadID, Bool)`, `thread.setAgent(...)`, `thread.resolve(threadID)` | app, phone | thread state |
| `applyThreadDiff(threadID, diffID, text?)` | app, phone (on ✓, with optional edited text) | IntakeRunner applies it as a human edit (`plan.user.md` layer), recording the thread as its source |
| `note(PlanNote)` with `source: thread(threadID)` | ThreadRunner | as today; the new optional field labels the card |

`applyThreadDiff` goes through the same path as `editPlan`, including `PlanEditRouter` / `EditLayer.retarget` when a newer round has landed. An old runner drops the unknown command (existing behaviour); the Mac never offers threads to a runner that predates them (the runner advertises a `threads` capability in `tape.json`).

**Following versions.** A thread follows the newest checkpoint. When a round lands, the next turn's workspace is rebuilt and the conversation shows a divider ("Now reading Refine 3"). A pending diff keeps the checkpoint it was proposed on; it is rebased with `EditLayer.retarget`. If that fails the diff becomes **stale**: never applied as a guess, with a **Re-propose** action that runs one turn against the current version. With auto-accept on, diffs always target the newest checkpoint.

**Resolve.** A resolved thread moves to Resolved in the index, takes no more turns until reopened, and never feeds rounds. Notes it left are independent and still feed the next round.

## 6. P1 Ask threads: UX

Renders: [thread-ux-v1.html](2026-10-31-planning-v2-renders/thread-ux-v1.html) (layout), [diff-slim-v2.html](2026-10-31-planning-v2-renders/diff-slim-v2.html) (option B chosen).

- **✦ Ask** is the last button on `SelectionToolbar`. With a selection it opens the panel on a new thread anchored to it, composer focused. With no selection it starts a whole-plan thread. The *Question* note kind is removed from the toolbar (§13).
- **Ask cards** sit in the notes rail's aligned lane beside their quote, like notes: title, live status ("answering"), a one-line excerpt of the latest reply, counts (diffs, notes, messages), Open ⤢. A stale thread shows a stale pill and Re-propose. Agent-made notes show "✦ from thread …" and can be withdrawn as today.
- **Thread panel.** "Threads (n) ⤢" in the rail header, or opening a card, replaces the rail with a wide panel:
  - **Index** (left): filter field; groups **Open** (by section, plan order), **Needs you** (the agent asked a question, or a diff is waiting), **Resolved**; "＋ New thread on whole plan". Selecting a thread scrolls the plan to its anchor.
  - **Conversation** (right): header with title, Resolve, agent/model menu, auto-accept switch, the version followed, and the anchored quote. Messages; citations as chips that open the intake, a checkpoint (through the round list navigation), a cross-check issue, or `file:line`. Structured questions inline (§4). Actions listed and linked to their inline copies. Composer: ⌘↩ send, ⌘⇧↩ send and resolve; ⌘[ / ⌘] move between threads while the panel has focus.
- **Diffs in the plan (D17, option B).** At rest the proposed text renders as normal prose with a 3 pt green bar in the left margin and a small ✦. On hover: the old text appears struck through above it, and a compact toolbar shows ✓ Accept, ✗, Edit, ✦ (open thread). Edit makes the new text editable in place before accepting. No header bar. The same form is used for every diff size.
- Thread state (which thread is open, panel width) is remembered per intake for the session, like `otherVersionsExpanded`.

## 7. P2a Visual blocks: format and storage

**In the plan.** A fenced block, plain text so the plan stays readable anywhere:

````
```fd-visual id=pairing-handshake
Pairing handshake: phone, Mac and hostd
```
````

The body line is the caption. An integrator may write `id=… pending` as a placeholder for a requested visual (§11). The block renders full width in the flow (D10).

**Revisions.** `visuals/<visualID>/r<n>/` is immutable once final:

```
manifest.json     provider id+version, kind, title, entry, states, sizes, pins scheme,
                  checkpoint made on, made by (thread|round|you), parent revision,
                  alternates [{revision, kind, reason, by}], primary: true|false
<source files>    e.g. diagram.mmd, or canvas.ref.json (P2b)
snapshot@<state>-<size>.png
pins.json         pins on this revision
```

A visual's **block state** (`visuals/<visualID>/block.json`, written by ThreadRunner) lists its representations in filmstrip order and which is ★ primary. Every plan checkpoint records the block states it saw, so viewing an old version renders its visuals as they were.

**Pins.** A pin is a note anchored to an element: `{revision, target, note}` where `target` is, in order of preference, a node id (diagram), a canvas element id (comp), or an `{x, y}` fraction fallback. Pins are `PlanNote`s with a new optional `visualAnchor`; they flow to rounds like any note. A pin whose target is gone in a later revision is listed under the block's "on another revision" section, mirroring note pinning; it is never moved to a guess.

## 8. P2a/P2b Visual blocks: rendering, comps and editing

Renders: [visual-block-alternates-v2.html](2026-10-31-planning-v2-renders/visual-block-alternates-v2.html) (option B + Compare chosen), [visual-blocks-v1.html](2026-10-31-planning-v2-renders/visual-blocks-v1.html). These are brainstorm fragments; they render best inside the Visual Companion frame.

**VisualBlockView (Mac).** An attachment in `PlanTextView` hosting a header and a `WKWebView`:
- header: title, primary's kind chip, **states** and **sizes** segmented controls (from the manifest), Pins (n), Compare, ✎ Edit (comps), ✦ Ask;
- body: the live render;
- filmstrip: thumbnails of every representation, ★ on the primary, amber outline on a round-proposed alternate with its reason, "＋ Another view…" (opens the block's thread with a `makeVisual` request prefilled);
- **Compare** splits the body two-up with "Make primary" on the right pane, then collapses back;
- off-screen blocks show their snapshot and switch to live when scrolled into view, so a plan with many visuals never runs many web views;
- the web view loads only from the revision folder (`loadFileURL(_:allowingReadAccessTo:)` scoped to it) with networking disabled; navigation outside the folder is cancelled.

**Diagrams (P2a).** Bundled provider `fd.diagram.mermaid`: sequence, component (flowchart), flow, state and ER diagrams, rendered with a pinned, vendored `mermaid.js`. Pins use node ids. `fd.diagram.svg` (P3) is the hand-written fallback.

**Comps (P2b, D18).** `comp.screen` and `comp.flow` are **canvas documents**:
- a comp revision's source is `canvas.ref.json`: canvas document id, document checkpoint id, viewport presets, states; the canvas journal and blobs stay in canvas storage, owned by the canvas service;
- the agent produces a comp by writing canvas NDJSON operations to the draft revision folder; `ProviderHost` streams them to the canvas engine (`flightdeck canvas stream`), then records the resulting checkpoint id. Generation is incremental and resumable as the canvas spec defines;
- states are canvas screens/variants declared in the document; sizes are canvas viewport presets; a clickable flow is a multi-screen canvas document, with a storyboard strip in the filmstrip slot;
- pins are canvas annotations (element id + revision), mirrored into `pins.json` so rounds and export read them without the canvas engine;
- **edit mode** is the canvas's own editing restricted to text replacement and state/size switching (D9). Saving creates a canvas checkpoint and a new comp revision; the edit reaches later turns and rounds as a human edit, so no agent regenerates over it;
- the canvas's "send comments" delivery for a comp attached to an intake targets that comp's thread (a `thread.message` command), not a terminal session;
- the canvas spec's rollout flag governs this: comps appear only when the canvas is enabled, and Mermaid diagrams work without it.

**Mapping onto the canvas plan's Task 10** (`docs/superpowers/plans/2026-10-24-visual-companion-canvas.md` on `feat/canvas-ts-engine`):
- `CanvasArtifact` is the native model of `canvas.ref.json`: `{canvasID, documentID, checkpointID, viewports: [id], states: [id], createdBy: thread|round|you, intakeID, visualID, revision}`. It is a durable reference, never a URL.
- `CanvasProvider` is the native side of the bundled `fd.comp.canvas` provider (§9): create a document for an intake visual, stream a draft's NDJSON operations, create a document checkpoint, export one checkpoint offline. `ProviderHost` calls it through the app's local control socket (`flightdeck canvas …`), because the canvas engine lives in the app's WKWebView. `engine_not_ready` is retried with backoff; the app not running fails the visual job with "open Flight Deck to make comps", never a silent wait.
- `CanvasAttachmentView` is the body of `VisualBlockView` for a comp revision: read-only at `checkpointID`, plus the restricted edit mode, state and size switching, and annotation mode for pins.
- Canvas annotations on an intake comp are delivered as `thread.message(threadID, …)` commands to the comp's thread, with element id and `subjectRevision` in the message, instead of a session delivery.

Integration spike (first task of P2b): confirm on the merged canvas that (1) a document can be created and streamed headlessly from `ProviderHost`, (2) a document checkpoint can be rendered read-only at a given checkpoint id inside `VisualBlockView`, (3) element ids are stable across the text-only edits allowed here, and (4) a static export of one checkpoint renders offline on iOS. A "no" on (4) means the phone shows snapshots only for comps until resolved.

**VisualRenderHost.** In the app, because WebKit needs it. When a revision becomes final it renders `snapshot@<state>-<size>.png` offscreen for each declared state at the default size, plus the default state at each size. Snapshots exist only while the app runs; a round that runs while the app is closed gets source only, and its record says so. Running WebKit inside the detached runner is rejected as a new class of fragility.

## 9. P3 Visual providers

**Provider** = a folder with `provider.toml` (TOML, as `delegate.toml` and `[infra.*]`):

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

**Making a visual** (`makeVisual` from a thread or a round request):
1. The agent picks a kind from the catalogue in its workspace (every enabled provider's kinds with summaries; unavailable kinds listed with the reason).
2. ThreadRunner creates a draft revision folder, copies the kind's `assets`, and hands the agent the kind's `instructions` and the path. The agent writes the source and a small `visual.json` (title, caption, states) with its normal Write tool, in the same turn. Files and instructions only, so it works on all five adapters.
3. If the provider declares a `[generator]`, `ProviderHost` runs it in ThreadRunner (never in the agent): cwd the draft folder, timeout, no network, `sandbox-exec` where available, output confined to the folder. `output = "canvas"` uses the built-in canvas streamer instead (§8).
4. Validation: entry exists; declared states exist; no external URLs; folder ≤ 10 MB. Then `manifest.json` is written, the revision is final, and VisualRenderHost renders snapshots.
5. A validation failure goes back to the agent's next turn (≤ 2 retries), then the block shows "couldn't make this visual" with the reason.

**Sources and precedence:** repo `.flightdeck/visual-providers/` › per-user `~/Library/Application Support/Flight Deck/visual-providers/` › bundled. A repo provider with the same `id` overrides the others in that repo. Settings → Planning lists providers with source and an on/off switch.

**Repo trust gate:** a repo provider without `[generator]` is data only and used without asking. One with a generator needs a one-time approval recorded against a SHA-256 of the provider folder; any change to the folder asks again. Until approved, its kinds are listed to the agent as unavailable with the reason.

**Contract versioning:** `contract = 1`. A provider with a higher contract shows "needs a newer Flight Deck" and is never half-loaded. Within a contract, fields are only added.

**Bundled set:** `fd.diagram.mermaid` (rewritten as a contract-1 folder in P3, which proves the contract on a real provider), `fd.diagram.svg`, and `fd.comp.canvas` (`output = "canvas"`) once P2b has landed.

**Provider-authoring skill.** `flight-deck:visual-provider`, shipped in the bundled plugin (claude via `--plugin-dir`, codex via the `CODEX_HOME` skill path, per the existing patterns in `ClaudePluginLocation` and `CodexDelegateSkill`). It writes a provider folder either from a description or by wrapping an existing skill (the skill body becomes a kind's `instructions`, its assets become `assets`), then runs **`flightdeck provider check <dir>`**: manifest and kind validation, then one sample visual per kind with a cheap model, validated exactly as `ProviderHost` would. A provider that passes `check` loads in planning.

## 10. Phone and wire

**Capability flags** in the Mac's intake detail: `structuredQuestions` (P0), `threads` (P1), `visuals` (P2a), `comps` (P2b). The phone shows a feature only when its flag is present; an old Mac never receives an op it would drop the socket on. New projection fields are optional; an old phone ignores them.

**Ops** (each new case lands in one commit with every handler arm; wire enum cases are atomic):

| Op | Purpose |
|---|---|
| `intake.answer(answers)` | §4 |
| `intake.thread.send(threadID?, anchor?, text)` | reply, or open a thread when `threadID` is nil; anchor = reader block index + quote, as phone notes |
| `intake.thread.get(threadID, since?)` | messages on demand, never pushed |
| `intake.thread.resolve(threadID)` | |
| `intake.diff.decide(threadID, diffID, accept)` | refused with `diff_stale` when stale |
| `visual.fetch(visualID, revision, part: snapshot\|bundle)` | chunked; immutable, cached by `(visualID, revision)` indefinitely; ≤ 10 MB |

**Projection** (`IntakePlanProjection`): thread summaries (title, anchor, status open/needsYou/stale/resolved, counts, latest excerpt); pending diffs in full; open questions; visual refs (id, revision, kinds, alternates, states) so the reader lays out blocks before bytes arrive.

**Phone UI** (files stay flat in `Sources/FlightDeckMobile/`):
- plan reader: inline snapshot + filmstrip; tap opens a full-screen live `WKWebView` from the cached bundle, network off, with state/size switches; no pins in v2;
- diffs: the same gutter-bar form; tap shows the old text and Accept / ✗;
- "Ask" in the reader's selection menu beside Note; a thread screen with conversation, inline structured questions and a composer;
- `StructuredQuestionView` shared by triage and threads;
- the fleet list's intake row shows a "needs you" count badge, reusing the unread mechanism;
- sends go through an outbox like `NoteOutbox`, shown pending until the projection agrees.

## 11. Rounds integration

**Rounds see** (additions to `RoundPrompts.steering`):
- **Thread decisions since the last round:** per touched thread, title, anchor and its latest `decision` line. Accepted diffs already arrive as human edits; the decision line carries the why, so a refine round does not quietly undo it.
- **Visuals:** per block, id, kind, anchor section, primary source path, default snapshot path, pins. Snapshots are read with the agent's image-capable read tool. An adapter that cannot read images in headless mode gets source only, recorded in the round record. A new `image.read` cell in `test-adapters.sh` establishes which adapters can (claude's Read opens PNGs; the other four are unverified).

**Rounds may** (schema additions):
- integrator: add a ` ```fd-visual id=… pending``` ` placeholder plus `visualRequest {id, kind, brief, reason}`; propose an alternate `{visualID, kind, brief, reason}`;
- reviewers: target an issue at a visual `{visualID, pin target, issue}`; cross-check clusters treat it like any issue.

**Rounds may not** change a primary, delete a block, or edit a revision (D16).

**Round visual requests** are recorded in the round's checkpoint record. ThreadRunner picks them up:
- kind approved in triage, or already approved for this intake → generated at once; the placeholder renders "Generating…";
- otherwise → a **suggested visual** chip with its cost and a "Make it" button; nothing is spent until clicked;
- proposed alternates land in the filmstrip with the amber outline.

**Triage visual offer (D11).** When triage judges that a plan calls for visuals, it returns a `multi` structured question listing candidate visuals, each option with `cost` (≈ seconds and tokens from the provider manifest, scaled by the chosen model's price) and "Other…". Checked kinds are pre-approved for the intake.

## 12. Encode and release export

**Encode.** The encode prompt gets the visuals catalogue and cites, per task, the visuals it implements by id and state. Each task body gains:

```
Fidelity references (implement to match; don't redesign):
- docs/plans/<slug>/visuals/<id>/ — states: default, empty, error
```

A citation of a missing id fails encode validation, as a broken dependency edge does.

**PlanExporter** runs during release before `br create`, so every cited path exists:
- `docs/plans/<slug>/plan.md`: each `fd-visual` block becomes an image link to its default snapshot plus a link to its folder;
- `visuals/<id>/`: the primary's files, snapshots, `pins.json`, and a `README.md` (kind, states, how to open it). A canvas comp is exported through the canvas's export path as an offline bundle of its checkpoint;
- `visuals/<id>/_unused-alternates/<n>/` with a one-line `README.md`: "Not chosen. Do not implement from these.";
- slug from the intake title, made unique with `-2`…; releasing the same intake again overwrites its own folder; git keeps history;
- **commits those paths only**, with a house-style message (`docs: plan <slug> for release`), never touching other changes in the shared working copy. The release confirmation sheet lists the files and the commit. Uncommitted changes under `docs/plans/<slug>/` block release with a message; nothing is overwritten.

## 13. Migration and compatibility

- All storage is additive: new optional fields, new files, new commands. Old `tape.json`, `commands.jsonl`, `intake.json` and checkpoint folders load unchanged; an old runner drops unknown command lines.
- The *Question* note kind is retired from the toolbar and the phone composer. Existing Question notes stay readable and still feed rounds; an old phone that sends `question` is still accepted. No data is rewritten.
- `PlanNote` gains optional `source` (thread) and `visualAnchor`; `TriageExchange` gains optional structured fields; `WireNote` and the intake detail gain optional fields.

## 14. Testing

Rules: TDD; each test is seen failing against the code it targets before the fix; no assertion is weakened; **nothing that opens a window, launches the app or runs XCUITest runs on the development Mac**.

| Layer | How |
|---|---|
| Pure logic | Unit tests via `./scripts/test-unit.sh` (runs on the UI-test Mac): structured question decoding including legacy `[String]`; `ThreadActions` parsing per adapter from fixtures **captured from real CLI output**; `ActionValidator` (applies, stale, rebase via `EditLayer.retarget`); `ThreadWorkspace` outline/section split and a provenance index built from a scrubbed real checkpoint folder; pin resolution order; manifest parsing and trust hash; `PlanExporter` paths and commit scope; storage compatibility of old files; old-runner tolerance of new commands. |
| Runner end to end | `ThreadRunner` against a scripted fake agent (pattern of `scripts/opencodeprobe/fake_llm.py`): one turn, retry after a bad diff, two threads in parallel, a round landing mid-turn, a visual job with a generator. No tokens. |
| Live adapters | New `thread.turn` and `image.read` cells in `./scripts/test-adapters.sh` (cheap tier by default). |
| Wire | `IntakeWireCodingTests` round trips for every op and projection field; old-Mac/old-phone decoding in both directions. |
| Rendering | Offscreen `layer.render(in:)` renders of Ask cards, the panel, the diff bar and the visual header, inspected as PNGs. WebKit snapshot tests in the hosted unit suite on the UI-test Mac. |
| Phone | `./scripts/test-ios.sh`: `StructuredQuestionView` logic, thread outbox, visual cache. |
| UI flows | `FD_UITEST_ONLY=… ./scripts/smoke-remote.sh` only: P1 Ask → reply → accept diff; P2 open a visual → switch state → pin. |
| Maintainer GUI checklist | New `docs/FLIGHT-CONTROL-PLANNING-V2-CHECKLIST.md`, one section per phase; every GUI claim in a phase report has an entry. |

## 15. Docs updated in each phase's branch

`docs/ARCHITECTURE.md` (threads and visuals sections; the single-writer table), `docs/HANDOFF-plan-notes.md` (Ask cards beside notes; Question retired), a new `docs/HANDOFF-planning-v2.md`, `docs/FOLLOWUPS.md` (the out-of-scope list in §2), and the checklist above.

## 16. Risks and open verifications

1. **Image reading per adapter** is unverified for codex, grok, gemini and opencode in headless mode (§11). Mitigation: capability cell; source-only fallback.
2. **Canvas readiness** gates P2b. Mitigation: P2a ships diagrams independently; the P2b spike (§8) answers the four integration questions before any comp UI is built.
3. **Snapshots need the app running** (§8). Accepted; recorded in round records.
4. **Read-only Bash for thread agents** widens the reviewer profile. It uses the same restricted-command policy reviewers already run with; a thread agent never gets Edit or Write outside its draft visual folder.
5. **Comps need the app running**, as snapshots do: the canvas engine is app-hosted (§8). Accepted; a comp job fails visibly when the app is closed.
6. **Cost of live threads.** Each message is a resumed headless turn. The thread header shows the agent and model; the default is the integrator's, which the person can lower per thread.
