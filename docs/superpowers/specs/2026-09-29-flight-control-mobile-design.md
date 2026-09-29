# Flight Control on the phone: design

**Status:** screens approved in the visual companion 2026-09-28/29 (navigation → shaping →
waiting states → round + plan → new intake); this document is the written form for review.
**Builds on:** `docs/FLIGHT-CONTROL-MOBILE-HANDOFF.md` (terrain, constraints — read it first),
`2026-09-27-planning-ui-redesign-design.md` (the desktop surfaces this adapts),
`2026-08-29-plan-review-on-the-phone-design.md` (the plan-on-the-phone precedent).
**Visual reference (git-ignored):** `.superpowers/brainstorm/6490-1790681651/content/` —
`shaping-hybrid-v2.html` (the running screen), `needs-you.html`, `round-and-plan.html`,
`round-detail-compact.html`, `new-intake.html`; `.superpowers/brainstorm/56234-1790649785/content/nav-placement.html`.

## 1. Intent

Flight Control (triage → clarifying Q&A → fidelity → multi-model planning rounds on a tape →
release as tasks) exists only on the Mac. The phone knows nothing about it: no intake data
crosses the wire. The maintainer tends runs on a 10–15 minute cadence and wants to do that from his
pocket.

The phone does **all four jobs** (the maintainer, 2026-09-28):

1. **Watch** a running tape — where it is, what the agents are doing, how long, convergence.
2. **Unblock** it — answer triage's questions, pick fidelity and start, retry a failure.
3. **Steer** it — transport, add/remove rounds, read the plan, leave notes for the next round.
4. **Start and finish** — capture a new intake; release the reviewed plan as tasks.

**Success:** the maintainer can take an intake from a dictated intent to released tasks without touching
the Mac, and at any moment can tell from the Sessions list whether any run needs him.

## 2. Decisions (all the maintainer's, 2026-09-28/29)

| # | Decision | Rejected |
|---|---|---|
| D1 | Intakes live **inline at the top of their project's section** in the existing Sessions list; the section header carries an orange "N needs you" badge | A separate Flight Control tab (global count, but a tab bar on every screen); a project screen with segments (most taps) |
| D2 | The intake screen is a **compact board strip with the transport built into its bottom edge**, pinned, over native iOS rows | The desktop instrument compacted (~40% of the screen); stock iOS with a bottom toolbar (loses the journey) |
| D3 | **Tapping a board dot opens that round's detail** | Read-only strip |
| D4 | Attention is **in-app only**: badge + banner while the app is open and connected. No APNs, no local notifications, no Live Activity | Local notifications (miss most events: the socket dies seconds after backgrounding); APNs relay (new infrastructure — its own future spec) |
| D5 | **iPad uses the iPhone layout** | A desktop-like split view |
| D6 | **Released intakes stay in the list 3 days**, then leave it (they remain on the Mac) | Forever (list fills up); one day |
| D7 | **Summary synced, detail fetched**: intake summaries ride the sequenced snapshot + one new event; the intake screen polls a detail request while open; plans are fetched per checkpoint and cached | Everything sequenced (agent activity every ≤2 s would flood the replay ring and drift check); everything fetched (no live pills or reliable banner) |

## 3. Global rules

Inherited from the desktop spec §2 and the handoff §5, restated because the phone has broken
them before:

- **Words.** Tasks, never beads. Flight Control, never Flywheel. Agent, never seat. The Bead
  preset reads **Single task**. Identifiers, persisted keys and wire field names may keep the
  old words; nothing a person reads may. §10.4 adds the guard that enforces it.
- **Honest data only.** No invented percentages, ETAs or cost. Determinate fractions only where
  real (agents done/total, round N of M, the agent's own steps). Clocks count up. Cost only when a
  harness reported it.
- **Colour for exceptions only.** Accent = live/selected; amber = needs you / fallback / quiet too
  long; red = failure. Verdict counts are uncoloured (a declined change is not a failure).
- **Motion.** Everything respects Reduce Motion. Clocks tick at 1 Hz from a local timer; idle
  clocks (PAUSED FOR) drop to once a minute after 60 s. The split-flap plays once when a value
  first appears, never on re-render or scroll; Reduce Motion: none.
- **HIG.** Primary action at the thumb (a full-width button) and never destructive. Destructive
  actions (Stop, Discard, Release) always confirm. No labelled spinners, except the
  acknowledgement of the maintainer's own press ("Pausing…", "Stopping…").
- **No dead moments.** Every tap that starts agent work changes the screen within 100 ms,
  before the Mac replies (§8).
- **Stale honesty.** Disconnected, the phone shows what it last heard at the existing stale
  opacity. A running clock **freezes** at the value it had when the connection dropped and gains a
  stale mark; it never keeps counting against data it can no longer confirm.

## 4. Screens

All screens live in the existing `NavigationStack`. Everything below is phone and iPad alike
(D5). `Sources/FlightDeckMobile/` stays flat (AGENTS.md).

### 4.1 Sessions list (changed)

- In each project section, intakes come **first**, above that project's sessions, in the order
  needs-you → running/paused → others, newest first within each.
- **Intake row:** a 26 pt glyph tile (✈ live, orange-filled for needs-you with a state glyph:
  `?` answers, `◇` review/choice, `!` failed/interrupted; grey for paused/released), the
  intake's title (`IntakeTitle.lead` — the Mac computes it), and a subtitle of a state pill plus
  one fact: "Refine 2 · 4:12 · 1 of 2 agents", "3 questions", "Released 6 tasks".
- **Section header:** the project name, an orange **"N needs you"** badge when N > 0, and a
  **+** when Flight Control is enabled for that project (opens §4.10). No + on a project without
  Flight Control.
- A project collapsed on the Mac hides its intakes too (the Mac owns `isCollapsed`); the badge
  still shows on the collapsed header.
- **Retention (D6):** released intakes are listed for 3 days after release; discarded intakes
  leave at once. Enforced on the Mac, in the projection (§6.1), so every client agrees.
- Search is unchanged (intakes are not searchable in this spec).

### 4.2 Attention banner (new)

- Fires when an intake **transitions into** a needs-you state — `needsAnswers`, `awaitingChoice`,
  `review`, `partiallyReleased`, `failed`, `interrupted` (`IntakeState.needsAttention`, the
  Mac's own list) — **as heard in a live `project.intakes` event**. Never for state found in a
  snapshot (a connect or a resync would otherwise fire a banner for everything already waiting).
- Drops in at the top over any screen except that intake's own, holds ~4 s, swipe up to dismiss;
  a tap opens the intake. Title "<intake title> needs answers" / "is ready for review" /
  "failed" …; subtitle "<project> · <one fact>". Several at once queue, newest last.
- VoiceOver: posted as an announcement with the same words.

### 4.3 Intake screen: the board strip (new)

Navigation title = intake title; subtitle "<preset> · <state word>". A `⋯` menu holds
**Discard…** (confirmed) and nothing else in this spec.

The **strip** is pinned under the navigation bar in every state; rows scroll under it.

- **Top line:** NOW on the leading side ("REFINE 2 OF 5", "CLARIFY 1 · YOUR TURN", "REVIEW ·
  READY FOR YOU", "REFINE 3 · PAUSED"), the clock trailing (IN THE AIR, or PAUSED FOR when
  paused). Phosphor mono, tabular digits.
- **Tape:** one dot per slot from `CLR` to `REV`, as the Mac's `TapePlanner` plans it: landed
  dots filled, the live dot wider and glowing, scheduled dots hollow, the stop target ringed in
  accent, a failed round red. Each dot is a button (D3) → §4.6 for a landed or failed round;
  scheduled dots take no tap. VoiceOver reads each dot in full words ("Refine 1, landed, 6
  minutes 31").
- **Bottom line:** "→ STOPS AT <stop>" leading, the convergence word trailing (CONVERGING ↘ ·
  PLATEAU → · DIVERGING ↗ · TOO EARLY). DIVERGING is amber.
- **Colour by state:** accent/phosphor while running; grey (no glow) while paused or stopped;
  amber in needs-you states; red NOW text when failed. State changes recolour, never re-lay out.
- **Transport** (shaping states only) is the strip's bottom row, five keys split by hairlines:
  **Pause · Step · Next major · To review · Stop**, each a symbol over a tiny mono caption.
  - A dot over one play key marks the default play mode; **long-press** a play key to make it
    the default (`setDefaultPlay`), with a haptic.
  - A key whose command is in flight shows the acknowledgement in place of its symbol
    ("Pausing…", "Stopping…") until the Mac's detail shows the runner reached its safe point.
  - Keys that cannot act are dimmed (e.g. play keys while a Stop is pending).
  - **Stop** always asks first: an action sheet "Stop the run?", message naming the round whose
    work is discarded ("Refine 3's work in progress is discarded. Landed rounds and your notes are
    kept."), **Stop Run** destructive, Cancel. Pause acts at once.

### 4.4 Intake screen: shaping body

Under the strip, native inset-grouped sections:

1. **Agents · k of n done** — one row per agent in the round in flight: status glyph (pulsing
   while running, grey when done, amber ⇄ fallback, red ✕ failed); **headline** (primary; dwell ≥
   3 s as on the Mac); action as verb + object ("Reading `beacon/oauth/broker.ts`", path middle-
   truncated); identity line "Reviewer · codex gpt-6-sol · high"; a thin context gauge when the
   harness reported input tokens; count-up clock. A finished row collapses to its outcome ("14
   changes across §3 §5 §7", "+140 −95 · $0.49"). **Exceptions** as on the Mac (quiet ≥ 30 s
   secondary text; stalled ≥ 90 s amber "No output for 1:45 · last: <action>"; rate-limited amber;
   fallback amber sub-line; failed red + reason). Footprint chips and steps are shown when present.
   Tapping a row does nothing in this spec.
2. **Rounds** — header "Rounds" with, trailing, the active cycle's **"Refine ×5 − +"** (or Polish)
   control: − sends `trim(stage, by: 1)`, + sends `extend(stage, by: 1)`, each shown only when the
   Mac says it can act (§6.2 `canTrim`/`canExtend`); neither confirms (the other undoes it). Rows,
   newest first: round name, one fact line (changes · verdicts, or +/− lines, or "4 drafts · 1
   fell back ⇄"), duration trailing, chevron → §4.6.
3. **Plan** — one row "Plan · 12 sections" with "N notes ›" trailing → §4.7.

Triaging uses the same layout with one agent row ("Reading the repo" until its first event) and
no Rounds or Plan section.

### 4.5 Intake screen: waiting states

The strip is amber; the body is the state's form; the primary action is a full-width button over
a bottom fade, at the thumb.

- **Needs answers.** Section "Round N · k questions" with "j of k answered" trailing; each
  question numbered, its text, and a multi-line field (dictation via the keyboard mic — no custom
  recorder). Earlier rounds sit above as a collapsed "✓ Clarifications · …" row that pushes a
  read-only Q&A list. Drafts persist **on the phone** per intake and question round, surviving
  navigation and relaunch. **Send Answers** enables once every field has non-blank text.
- **Awaiting choice.** "✓ Clarifications" row; the recommendation as a tinted card ("Recommended:
  Full plan." + the Mac's reason); a four-way segmented **Single task / Sketch / Feature / Full
  plan** preselected to the recommendation (or the Mac's current choice); a read-only **Rounds**
  summary (drafters, refine cap, polish cap, fresh eyes + dedup, plays to; "customized" when the
  Mac's config was edited); the note "Models, efforts and fallbacks are edited on the Mac." Switching
  preset shows that preset's default summary — the phone never edits a `RoundConfig`. **Start
  Planning** (Single task: **Continue**, matching the Mac).
- **Review.** A summary line ("9 new tasks · 2 edits · 4 dependencies · 2 notices (1 session
  message, 1 mail)"), then:
  - **Needs a decision · N** — each drifted op: an amber DRIFTED tag, its title, the reason, and
    **Re-confirm** / **Drop**. (The mockup's "Re-triage" does not exist on the Mac and is not in this
    spec.) An op the Mac classified impossible is shown struck with its reason and is dropped
    automatically, as on the Mac.
  - **New tasks · N**, **Edits · N**, **Dependencies · N** — rows by task title (id in the
    accessibility hint), priority and dependency facts; an existing task waiting on a new one is
    badged "waits for release". Swipe to **Drop**; a dropped row shows struck with **Undo**. Tapping a
    row pushes its full text. An in-progress task's delivery rating shows as a menu when the Mac
    reports one.
  - **Release N New Tasks** ("Release Changes" when there are none) — disabled while any drift is
    undecided; then a confirmation alert naming what it writes and whom it messages ("Writes 9
    tasks and messages 1 live session and 1 mailbox."): **Release** (the intended action, so not
    styled destructive) and Cancel. Counts come from the Mac's one rule (`ReleaseCounts`), never recomputed on the phone.
- **Releasing / Released.** Progress line; then the result and any delivery warnings. No button.
- **Failed / Interrupted.** Red NOW; the Mac's reason; a "Show output" disclosure with the
  Mac-trimmed tail of the failing run's output (§6.2, capped); **Retry**.

### 4.6 Round detail (new)

Pushed from a board dot or a Rounds row. Title "Refine 1", subtitle "Landed · 6:31" (or
"Failed · 2:10"). Trailing **‹ ›** step to the neighbouring landed round, stopping at the ends.

- **Facts strip** (compact, one row ~46 pt, hairlines between): **Time · Changes · Lines ·
  Verdicts**. The same four for every round; a missing value is "—" on screen and said in words
  to VoiceOver. Verdicts read "33 · 6 · 2" (agreed · somewhat · declined), uncoloured.
- **Note** — the round's note, whole.
- **Agents** — each agent with the model that ran, fallback ("fell back to codex · claude 401",
  amber), failure (red + reason), duration.
- **Sections changed · N** — rows with +/− lines; tap → §4.8 at that section, showing
  **Changes since previous** at this round.
- **Notes consumed · N** — each note's kind, quote and text.

### 4.7 Plan outline (new)

Title "Plan", subtitle "after <round>". Segments **Plan · Changes since previous**. A search
button (⌕) filters the outline by heading text.

- One row per section (the plan's `##` headings; `#` title excluded; nested headings indented one
  level, deeper levels folded into their parent). Trailing: a yellow **note count chip** when
  The maintainer's notes anchor there, and a **churn lane** — one tiny bar per round in the current cycle,
  height = that section's lines changed (from `ConvergenceSeries.sectionChurn`).
- Sub-line: "still since R2" (tertiary) for a settled section; **amber** "still moving · same
  sentence 3×" for a section the convergence verdict flags.
- Pinned footer: "N notes for the next round" leading, **Whole plan ›** trailing.
- Tap a section → §4.8 scrolled to it.

### 4.8 Plan reader and annotation (new)

Title "§7 · <heading>", subtitle "N notes"; trailing **⌃⌄** steps to the previous/next section.
The whole plan is one scroll; the title follows the section whose heading last passed the top.

- **Rendering:** `TimelineMarkdown.theme` + `TimelineProseText` (selectable prose), split into
  blocks by **`PlanBlocks.split`** — the same shared split the plan-gate review uses, so a block
  index means the same thing on both ends.
- **Existing notes** render as a yellow highlight wash under their quote (located by the Mac,
  §6.3); tapping one opens it in the note sheet with **Delete** (`removeNote`). A note already
  consumed by a round is fainter and read-only.
- **Changes since previous:** added lines tinted, removed lines struck and dimmed, per block, from
  the Mac's diff (§6.3).
- **Annotating a phrase:** select text → the edit menu gains **Note…** → a half sheet: the quote
  (italic, accent bar), six kind chips **Comment · Question · Must change · Replace · Delete ·
  Highlight**, a text field, **Cancel / Add**. Highlight sends at once with empty text (the Mac's
  toolbar does the same). Add enables when the text is non-blank, except for Highlight.
- **Annotating a block:** tapping a paragraph without a selection opens the same sheet quoting the
  whole block (the plan-gate precedent).
- **Plan-wide note:** the footer's "N notes" row opens the sheet with no quote.
- **No editing on the phone.** The Mac's edit layer stays desktop-only; Must change / Replace
  notes carry that intent.

### 4.9 Clarifications history (new, small)

Pushed from "✓ Clarifications": each round's questions and answers, selectable, read-only.

### 4.10 New intake (new)

A sheet from a project header's **+**: **Cancel · New Intake · Triage** bar; a Project row
(preselected to the header tapped; a menu of Flight Control–enabled projects); one large
multi-line field ("Describe the outcome…"); the hint "Triage runs on the Mac, reads the repo and
asks what it needs to know. Your draft is kept if you leave." The draft persists on the phone per
project. **Triage** enables with non-blank text; on tap the sheet closes onto the new intake's
screen, strip at TRIAGE 0:00 with a queued agent row (§8). A refusal reopens the sheet with the
draft and the reason.

## 5. What the phone can do, and what stays on the Mac

| Phone | Mac only (this spec) |
|---|---|
| Everything in §4 | Editing the plan (edit layer, revert hunks); the Rounds editor (harness × model × effort × fallback grid); heatmap; ⌘-clicking plan links; selecting a checkpoint to view an older plan (the phone reads the head, and a round's diff); Back (rewind); per-agent Stop; the convergence hover card's suggested action text beyond the state word |

## 6. Wire (FleetKit)

New wire types live **in FleetKit** as `Wire*` structs, projected on the Mac from IntakeKit's
models. IntakeKit is not made to compile for iOS: its persisted shapes are the runner's and the
app's single-writer files, and letting the phone depend on them would make every engine field a
wire contract. (Rejected: an iOS-compiled IntakeKit slice.) Codable is hand-rolled where the
existing neighbours are; all new optionals decode with `decodeIfPresent`; state-like values are
`String`s so an unknown value renders degraded instead of throwing.

**Compatibility, measured from the code:** an unknown `FleetEvent` tag throws in the phone's
decoder and ends the socket; the phone does not check sequence gaps (`FleetConnector` just
advances to each event's `seq`); an unknown `FleetCommand` gets `err "unsupported"` from the Mac's
salvage path; synthesized `Codable` on `WireProject` ignores unknown keys. Therefore:

- The phone advertises **`FleetCapability.flightControl = "flightControl"`** in `hello.caps`.
- The Mac sends the new event **only to peers with that capability**; others skip it (safe:
  no gap check). Every other new frame is a reply to something only a capable phone asks.
- A new phone against an old Mac sees no `intakes` field and shows no Flight Control at all.
- `FleetKitVersion.wire` is not bumped.

### 6.1 Sequenced state

`WireProject` gains `intakes: [WireIntakeSummary]?` — **nil** when Flight Control is not enabled
for the project (so no + and no rows), `[]` when enabled with nothing to show.

```
WireIntakeSummary
  id: UUID
  title: String            // IntakeTitle.lead, computed on the Mac
  state: String            // IntakeState raw value
  needsAttention: Bool     // the Mac's rule, never re-derived on the phone
  preset: String?          // Preset raw value; label mapping on the phone ("Single task")
  now: String?             // "Refine 2", "Clarify 1", "Review" — the board's NOW name
  runStatus: String?       // RunnerStatus: idle | running | paused | failed | reachedReview | stopped
  clockSince: Date?        // when the current in-the-air or paused-for interval started
  agentsDone: Int?, agentsTotal: Int?   // round in flight only
  questionCount: Int?      // needsAnswers only
  releasedTaskCount: Int?  // released/partiallyReleased only
  version: Int             // bumps on every summary change; the detail poll's cheap check
```

The summary is deliberately **coarse**: nothing in it moves at agent-activity rate. It changes on
a state transition, a round starting or landing, an agent finishing, pause/resume, and release.

**Event:** `FleetEvent.projectIntakes(project: UUID, intakes: [WireIntakeSummary])`, tag
`project.intakes` — the whole list for one project, replacing the previous one. Emitted by
`FleetService` when `IntakeProjection` of a project differs from the last emitted value
(`IntakeService` publishes; `FleetService` compares and records). `FleetProjection` projects
`intakes` too, so the replicator's drift check covers it. Retention (D6) is applied in
`IntakeProjection`, keyed on `ReleaseRecord.releasedAt`, re-evaluated on the existing tick so an
intake ages out without any other change.

### 6.2 Detail by request

`FleetRequest.intakeDetail(id: UUID, ifNot: String?)` → `ServerFrame.intakeDetail(cid,
WireIntakeDetail?)`; `nil` means "unchanged since the `etag` you sent". Refusal:
`unknown_intake`.

```
WireIntakeDetail
  etag: String                       // Mac-side: tape mtime + seat-file mtimes + intake version
  summary: WireIntakeSummary
  intent: String
  progress: String                   // the Mac's ProgressSummary line
  board: WireBoard?                  // shaping and later
  agents: [WireAgent]                // the round (or triage) in flight
  rounds: [WireRound]                // landed/failed checkpoints, newest first
  questions: WireQuestions?          // needsAnswers: open round + answered rounds
  choice: WireChoice?                // awaitingChoice: recommended, reason, current preset,
                                     //   per-preset rounds summary lines, customized flag
  failure: WireFailure?              // reason + output tail (≤ 4 KB, trimmed on the Mac)
  release: WireReleaseResult?        // releasing/released: progress, counts, warnings
  pendingNotes: [WireNote]
  halt: String?                      // "pausing" | "stopping" — the Mac's `halts`
  headCheckpoint: Int?, sectionCount: Int?

WireBoard
  slots: [WireSlot]                  // TapePlanner replay on the Mac, incl. TapeOverlay
    WireSlot: name, code, stage, round, status(landed|live|scheduled|failed),
              major, isStopTarget, checkpoint: Int?, duration: TimeInterval?
  stopsAt: String, callingAt: [String]
  convergence: WireConvergence?      // verdict word + changes-per-round series
  defaultPlay: String                // PlayMode raw value
  cycle: WireCycle?                  // stage, planned count, canTrim, canExtend

WireAgent                            // from SeatActivity + run.json + result.json
  role, harness, model, effort, fallback: String?, headline: String?,
  actionVerb: String?, actionObject: String?, footprint: [String: Int], steps: WireSteps?,
  inputTokens: Int?, contextWindow: Int?, startedAt: Date?, lastEventAt: Date?,
  finished: Bool, outcome: String?, error: String?, costUSD: Double?

WireRound                            // from Checkpoint + RoundRecord
  checkpoint, stage, round, startedAt?, landedAt, failed: Bool, changeCount?, linesAdded,
  linesRemoved, tally?, note?, sectionsChanged: [WireSectionChange], agents: [WireAgent],
  notesConsumed: [WireNote]
```

- **Polling.** The intake screen requests on appear, then every **1.5 s** while it is visible and
  the app is active — the timeline's cadence — sending the last `etag`. The Mac answers `nil`
  when nothing changed, so an idle poll is a few dozen bytes. The Mac's `etag` comes from the
  mtimes `IntakeService` already tracks; computing it costs a `stat` per file, as the existing
  tick does. Polling stops on disappear, background, and disconnect.
- **Size discipline.** Never raw `stdout`; never drafts; never a whole plan. `failure.output` is
  capped at 4 KB. Agent `footprint` is the top-level counts only.
- **Exceptions on the phone.** Quiet/stalled are judged against `lastEventAt` with the phone's
  clock and the same named thresholds the Mac uses — `SeatThresholds` (quiet 30 s, stalled 90 s)
  and the dwell rule move from `SeatRowModel.swift` into FleetKit (`AgentActivityRules`) so both
  ends share one definition. The Mac's call sites keep their behaviour.

### 6.3 Plan by request

`FleetRequest.intakePlan(id: UUID, checkpoint: Int, changes: Bool)` → `ServerFrame.intakePlan(cid,
WireIntakePlan)`. Refusals: `unknown_intake`, `unknown_checkpoint`.

```
WireIntakePlan
  checkpoint: Int
  editsVersion: String       // hash of plan.user.md; part of the phone's cache key
  markdown: String           // the EFFECTIVE plan (PlanLayers — the maintainer's Mac edits included)
  outline: [WireSection]     // heading, level, blockIndex, churn: [Int], diverging: Bool,
                             //   settledSince: String?
  notes: [WireNote]          // pending + consumed, each with blockIndex? located by the Mac
  changes: [WireBlockChange]? // when changes == true: per blockIndex, added/removed line text
                             //   vs the parent checkpoint, from the diff the desktop uses
```

- The phone caches by `(intake, checkpoint, editsVersion, changes)` in memory (LRU of 4 plans);
  a checkpoint's agent plan never changes, so a re-open is free unless the maintainer edited on the Mac.
- Block indices are `PlanBlocks.split(markdown)` on the Mac, the same function the phone runs.
- 30–50 KB per plan is fetched only when the maintainer opens the outline or reader, never polled.

### 6.4 Review by request

`FleetRequest.intakeReview(id: UUID)` → `ServerFrame.intakeReview(cid, WireReleaseReview)` —
the Mac's `reviewModel(_:)` projected: summary line, counts (`ReleaseCounts`), ops (index, kind,
task title, id, priority, dependency facts, `waitsForRelease`, dropped, rating?), drift per op
(`holds` | `drifted(reason)` | `impossible(reason)`), `canRelease`, notice counts by channel.
Re-requested after every review command's ack.

### 6.5 Commands

New `FleetCommand` cases. Every one carries a `token: UUID` for idempotency (a repeated token is
acked without re-applying, as `prompt` does). Each is applied in `FleetService.apply` by calling
**one `IntakeService` method** — no validation in the service (the rule at `.prompt`); where a
check is needed, it is added to `IntakeService`. Every refusal returns a named `err` code **and**
logs a line with `check=<code> intake=<id>` (answer-drive-fails-silently).

| Command | IntakeService | Refusals |
|---|---|---|
| `intakeCapture(id, token, project, intent)` | `capture(intent:project:id:)` — the phone supplies the id so it can navigate before the ack | `unknown_project`, `flight_control_disabled`, `empty_intent` |
| `intakeAnswer(id, token, round, answers)` | `answer(_:answers:)` after checking state and round | `intake_moved_on`, `answer_count` |
| `intakeStart(id, token, preset)` | new `start(_:preset:)` = `choose` + `beginShaping` with that preset's config (the Mac's customized config when the preset is unchanged) | `intake_moved_on` |
| `intakeTape(id, token, command)` | `send(_:_:)` — `command` is `WireTapeCommand`: step, nextMajor, toReview, pause, stop, extend(stage), trim(stage) | `intake_moved_on`, `not_shaping` |
| `intakeDefaultPlay(id, token, mode)` | `setDefaultPlay` | `not_shaping` |
| `intakeNote(id, token, noteID, kind, text, anchor)` | `send(_:.note(PlanNote))`; `anchor` = `{checkpoint, blockIndex, quote}?` → the Mac builds the `NoteAnchor` (§6.6) | `intake_moved_on`, `unknown_checkpoint` |
| `intakeRemoveNote(id, token, noteID)` | `send(_:.removeNote)` | `note_consumed` |
| `intakeRetry(id, token)` | `retry` | `intake_moved_on` |
| `intakeDiscard(id, token)` | `discard` | `intake_moved_on` |
| `intakeReviewOp(id, token, op, action)` | `confirmDrift` / `drop` / undo-drop / `setRating` | `intake_moved_on`, `unknown_op` |
| `intakeRelease(id, token)` | `release` | `intake_moved_on`, `release_blocked` |

Every command goes through `IntakeService`, never by writing `commands.jsonl` from
`FleetService`, so `TapeOverlay` folds it and the Mac's own board moves too.

Each new case (tag, encode, decode, every exhaustive-switch arm, the `FleetService.apply` arm, the
round-trip test) lands **in one commit** (wire-enum-cases-are-atomic).

### 6.6 Anchoring a phone note

The phone sends the block index and the **rendered** quote it selected; the Mac turns that into a
`NoteAnchor` against the effective plan at that checkpoint: it takes the block's source text,
finds the quote in it with inline Markdown markers (`**`, `*`, `` ` ``, `[text](url)` → text)
ignored and whitespace runs collapsed, maps the match back to a source range, and calls
`NoteAnchor(checkpoint:selecting:in:)`. If the quote cannot be found, the note anchors to the
**whole block** and the Mac logs `check=note_anchor_fallback`. A whole-block tap sends the block's
rendered text as the quote. The mapping is a pure function in IntakeKit (`RenderedQuoteLocator`),
unit-tested against real plans.

## 7. Phone architecture

- **`FlightControlModel`** (new, owned by `FleetModel`, like the timeline models): holds the
  current detail per open intake, runs the 1.5 s poll, the plan cache, answer and intent drafts,
  pending acknowledgements, and the banner queue. Screens talk only to it.
- **Pure decision types, unit-tested** (MOBILE-UI's rule — decisions apart from views):
  `IntakeRowStyle` (row glyph, pill, fact line, ordering, badge count), `BoardStripModel`
  (NOW/clock/stop/convergence text, dot states, colour state, which keys are enabled),
  `AgentRowStyle` (headline/action/identity/outcome text, exceptions via `AgentActivityRules`
  with an injected clock), `RoundFacts` (the four facts, "—", VoiceOver words), `OutlineStyle`,
  `BannerPolicy` (transition-in only; never from a snapshot; suppressed on that intake's screen),
  `ClockPolicy` (count-up, freeze on disconnect, idle minute ticks), `AcknowledgementState`.
- **Views**, flat files: `IntakeRow`, `AttentionBanner`, `IntakeScreen`, `BoardStrip`,
  `AgentRow`, `RoundsSection`, `AnswersForm`, `FidelityChoice`, `PhoneReleaseReviewScreen`,
  `RoundDetailScreen`, `PlanOutlineScreen`, `PlanReaderScreen`,
  `NoteSheet`, `ClarificationsScreen`, `NewIntakeSheet`.
- **Mac side:** `Sources/FlightDeck/Fleet/IntakeProjection.swift` (pure: `Intake` + `Tape` +
  activities → wire types, retention, etag); `FleetService` gains the event emission, the three
  request handlers and the command arms; `IntakeService` gains `capture(…id:)`, `start(_:preset:)`,
  undo-drop, and the checks the refusal table names.

## 8. No dead moments over a network

The Mac's own board moves in the same turn a command is sent (`TapeOverlay`); the phone is a
round trip away. So:

1. **On tap**, the phone updates local state at once: a transport key shows its acknowledgement
   ("Pausing…"); Send Answers collapses the form and shows the triage row at 0:00; Start Planning
   shows the strip at the first draft slot at 0:00; Triage (new intake) navigates to the new
   intake with a queued row; a note appears in the reader as pending; a dropped op strikes through.
2. **On ack**, the phone re-requests the detail immediately (not waiting for the next 1.5 s tick),
   which already reflects `TapeOverlay` on the Mac.
3. **On err**, the optimistic change is rolled back and an inline message says why, in words from
   the refusal code ("This intake has moved on — it's now in Review."). Drafts are never lost.
4. **Timeout** (no ack in 10 s): rolled back with "Couldn't reach your Mac"; the token makes a
   retry safe.

## 9. Error handling

- **Disconnected:** screens stay at stale opacity; clocks freeze with a stale mark; every
  command-bearing control is disabled with the existing connection banner explaining why.
- **Intake gone** (discarded on the Mac, or aged out): the open screen says "This intake is no
  longer on your Mac" instead of a blank page (the session screen's precedent).
- **State moved under the phone** (answered on the Mac while the phone's form is open): the next
  detail replaces the form; the phone's draft is kept but not sent; `intake_moved_on` covers a
  race.
- **Refusals** are logged on the Mac with a named `check=` (§6.5); the phone's log records the
  code, so a failed drive is diagnosable from logs, not by the maintainer retrying.

## 10. Testing

### 10.1 FleetKit (macOS + iOS)
Round-trip encode/decode for every new type, case and tag, including an unknown state string and
an unknown slot status decoding degraded; `hello.caps` includes `flightControl`; an old-shape
`WireProject` without `intakes` decodes to nil.

### 10.2 Mac (`test-unit.sh`)
`IntakeProjection` against fixture intakes in every state (retention at 3 days ± 1 s, nil vs `[]`,
summary coarseness: an activity-only change does not change the summary); event emitted only on a
changed projection and only to capable peers; drift check passes with intakes; every command arm
calls its `IntakeService` method and every refusal code is produced and logged;
`RenderedQuoteLocator` against the real larkOS plan (bold, code, links, wrapped paragraphs,
not-found → whole block); `etag` stable across idle ticks and changed by a seat-file write.

### 10.3 Phone (`test-ios.sh`)
Every pure type in §7 to the edge cases: row ordering and badge counts; banner transition-in only,
never from a snapshot, suppressed on its own screen; clock freeze on disconnect; board dot states
and enabled keys per state; agent exceptions with an injected clock; round facts "—" and
VoiceOver words; optimistic apply/rollback per command; plan cache keying. Copy asserted verbatim.

### 10.4 Terminology guard
`TerminologyGuardTests` extends its scan to `Sources/FlightDeckMobile` (bead/beads, Flywheel,
seat in user-visible literals), with the existing allowances for identifiers.

### 10.5 Renders
Offscreen renders (env-gated, skipped by default, `ProseRenderHarness` technique) of the intake
screen in running, paused, needs answers, awaiting choice, review, failed; the round detail; the
outline; the reader with a note sheet — at 393 pt, both themes, and at
`.accessibilityExtraExtraExtraLarge`.

### 10.6 Device checklist (MOBILE.md, the maintainer)
Numbered items naming failures, e.g. "Start a Full plan on the Mac, open it on the phone, Pause from
the phone: the key reads Pausing… within a moment of the tap and the Mac's board shows paused
within 2 s"; "Answer questions on the phone with the Mac's display asleep: the Mac's intake leaves
Needs answers within a few seconds"; "Leave the phone on the Sessions list, trigger Needs answers on the Mac: the banner
drops in once, and does not fire again after backgrounding and returning"; the keyboard over the
answer form and the note sheet (ios-keyboard-tracking-lessons); VoiceOver across the strip.

## 11. Phasing

One spec, three plans, each shippable and each leaving the phone coherent:

1. **Watch** — §6.1, §6.2, §6.3 (read-only), the list rows, badge, banner, intake screen with the
   strip (no transport keys), agents, rounds, round detail, outline and reader (no annotation).
2. **Steer** — transport, default play, extend/trim, notes (§6.5 tape/note commands, §6.6, the
   note sheet), §8.
3. **Unblock, start and finish** — answers, fidelity + start, retry, discard, new intake, review
   and release (§6.4, remaining commands).

### 11.1 Phase 1 as built (2026-09-29)

Built on branch `fc-mobile-watch` from `docs/superpowers/plans/2026-09-29-flight-control-mobile-watch.md`.
Where the build and this spec differ, the build is right and these are the corrections:

1. `WireIntakeSummary` has no `version` field — the detail etag gives the poll its cheap check.
2. The detail etag is SHA-256 over the encoded detail (etag and `servedAt` blanked), not file
   mtimes.
3. `WireAgent` carries display strings the Mac computes (`SeatRowModel` built at `.distantPast`)
   plus dates; the quiet/stalled thresholds are shared via FleetKit `AgentActivityRules`.
4. A round that failed without landing a checkpoint is not tappable on the board; its failure
   shows in the intake screen's Failure section.
5. Phase 1 waiting states are read-only ("… on your Mac for now"); the forms are Phase 3.
6. The detail carries `servedAt`; the phone keeps `macClockOffset = servedAt − receivedAt`, so
   Mac/phone clock skew never shows.
7. Summaries are cached store-side (`SessionStore.intakeSummaries`) and `FleetProjection` reads the
   cache, so the drift oracle and the event log agree by construction. An absent cache key means
   nil; there is no forced first emission (startup emits nothing).
8. Summary refresh triggers: any store change (coalesced to the next main turn), a
   `SeatFeed.onSettled` hook when an agent's records or results change (an agent finishing), and
   a 60 s tick for the 3-day retention.
9. `project.intakes` is withheld from peers without the `flightControl` capability, both live and
   in the hello replay; the local `flightdeck` CLI claims no capabilities, so it does not see
   intake events.
10. "Changes since previous" is a whole-block, verbatim-text set diff (`added: [Int]`,
    `removed: [WireRemovedBlock]`) against the previous checkpoint that HAS a plan (the desktop's
    `previousPlanCheckpoint`) — not per-line text, and not `parent`.
11. Outline churn comes from the cycle containing the requested checkpoint if it has per-section
    numbers, else the Mac's `sectionCycle` rule (shared as `HeatmapModel.sectionCycle`), so the
    phone agrees with the Mac's churn lane during polish.
12. Plan cache contract: the head is always requested with `checkpoint: nil` (never served from
    cache; its reply refreshes the entry); explicit checkpoints are older rounds and are cached
    (LRU, 4). `editsVersion` is not a lookup key — the phone cannot know it before fetching.
13. The round detail's "Sections changed" opens the reader at that round's checkpoint (nil when it
    is the head) with changes on, at the top — not at the section. Landing on the section needs a
    section→block map on `WireRound`; Phase 2.
14. Intake presence (banner suppression and the 1.5 s poll) is one shared view modifier applied to
    every screen of an intake (intake, round detail, clarifications, outline, reader),
    reference-counted so pushing a child keeps the intake "on screen".
15. Idle clocks tick once a minute after 60 s (`ClockPolicy.tickInterval`, via a `TimelineView`
    schedule).
16. Unpairing resets the navigation path and all Flight Control state (banners, presence, caches).
17. The plan reader never shows a stale plan as a diff: a failed load shows an inline message with
    Retry, and a reply is applied only if it answers the latest request.

## 12. Non-goals

Push of any kind (APNs, local notifications, Live Activities, widgets) — D4; iPad split view — D5;
editing the plan; the Rounds editor; rewinding (Back); per-agent Stop; searching intakes; the
Level 3 swarm console; the `flightdeck` CLI growing Flight Control verbs (it can use the same
frames later, unplanned here).
