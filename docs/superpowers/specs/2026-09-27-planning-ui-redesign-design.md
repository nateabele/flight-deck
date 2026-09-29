# Planning UI redesign: design

**Status:** approved in the visual companion 2026-09-27 (directions → timeline → convergence); this
document is the written form for review.
**Builds on:** `2026-09-26-flywheel-intake-design.md` and its round-engine plan
(`plans/2026-09-27-flywheel-intake-rounds.md`), branch `flywheel-intake` @ `212432a`.
**Visual reference:** `.superpowers/brainstorm/57736-1790549157/content/` — `convergence-combo.html`
(the combined design), `mashup.html` (M2 Departures board), `dir-d-hybrid.html` (the base document),
`timeline-options.html`. Research: `planning-ui-research.md` (HIG checklist §1, live activity §4).

## 1. Intent

The planning UI (triage → Q&A → fidelity → shaping rounds → release review) works, but it reads as
a stack of stock controls, and while agents work it looks idle. Nate wants it redone to the standard
of an Apple Design Award app, following the macOS HIG, with four things it lacks today:

1. **Visible work.** Whenever an agent runs, the screen shows who, what they are doing now, and how
   far they have got, using only what the agents actually emit.
2. **A plan you can read and shape.** The plan renders as Markdown and is editable in place; your
   edits sit as a layer over the generated plan; you can highlight and annotate text for the next round.
3. **A sense of convergence.** Whether refinement is settling, plateauing or going in circles, and
   which section is still moving.
4. **Instrument-grade controls.** A Logic-style transport and LCD readout over a departures-board
   timeline.

Success: Nate can take a Full plan from intent to released tasks without ever wondering whether
anything is happening, what it is, or whether another round is worth it.

## 2. Global rules

- **"Tasks", never "beads".** No user-visible string says bead or beads — labels, buttons, status
  lines, in-app error text, empty states, the Enable Flight Control copy, Observe lanes, the release review.
  Internals (`br`, `.beads/`, `BeadWriter`, schemas, agent prompts, logs) keep the word. The Bead
  fidelity preset is shown as **Single task**. A test scans the view layer's string literals.
- **"Flight Control", never "Flywheel".** The feature is rebranded (Nate, 2026-09-27): every
  user-visible string says Flight Control ("Enable Flight Control…", "Set Up Flight Control…",
  "Flight Control Not Enabled"). Kept as flywheel: Swift type/file/folder names, branch names,
  persisted keys and on-disk paths (renaming them would orphan existing state), accessibility
  identifiers, and the external methodology's proper name (agent-flywheel.com). The same guard test
  covers both rules.
- **"Agent", never "seat".** A seat is one model run doing one role in a round (e.g. "reviewer ·
  codex gpt-6"); every user-visible string calls it an agent instead — labels, LCD cells ("SEATS
  DONE" → "AGENTS DONE"), inspector placeholders ("No Seat Selected" → "No Agent Selected"), the
  finished-round detail panel's "SEATS" header, help text, failure/diagnosis text, accessibility
  labels/values/hints and VoiceOver announcements. Kept as seat: Swift type/property names
  (`SeatRow`, `SeatActivity`…), file names, persisted keys/paths (`runs/<run>`, `seatResults`),
  accessibility IDENTIFIERS, test names, and IntakeKit's agent-facing prompts. The same guard test
  covers this rule too.
- **HIG:** primary action at the trailing edge and the default button; destructive actions never
  default, always confirmed; no controls or critical information only at a window's bottom; panels,
  not sheets, for repeated input (Rounds editor, notes); no labelled spinners; count up, never an ETA;
  colour only for exceptions (accent = live/selected, amber = attention/fallback, red = failure).
  A transitional acknowledgement of the human's own click — §4's "Pausing…"/"Stopping…" until the
  runner reaches its safe point — is exempt from "no labelled spinners": it is not a progress
  indicator, it says the press was heard (final-review ruling #18).
- **Honest data only.** No invented percentages, ETAs or live cost estimates. A determinate fraction
  appears only where it is real: agents done/total, the agent's own plan steps, round N of M.
- **Motion:** every animation respects Reduce Motion (cross-fade or none). Clocks tick at 1 Hz from a
  local timer, independent of agent events; 1 Hz timers suspend when the window is occluded. Once
  nothing is running (paused, stopped, failed), the idle clocks (PAUSED FOR, HALTED FOR) tick at 1 Hz
  for 60 s and then once a minute, on their own whole minutes (final-review ruling #9).
- **Full names first.** Every label renders its proper name when it fits its measured slot and falls
  back to a short code otherwise (§5.3).

## 3. Layout (Direction D)

The project view keeps its Intakes list on the leading side. Each row (`IntakeRow`) is the state
pill as a caption over the intent wrapped to three lines, `IntakeTitle.lead` in semibold running
into the rest in secondary — Mail's subject-into-preview, one flowing paragraph. The selected intake's detail pane is one
calm scrolling document, top to bottom:

1. **Header** — "INTAKE · <state>", a short title cut from the intent (`IntakeTitle`: its first
   sentence; a long one cut at its first clause break, else its last comma in reach, else a word,
   those two with "…" — never mid-word; `.title3` semibold), and a one-line **progress summary** of
   finished phases (`✓ Triage 3:40 · 41 files   ✓ Draft & Synthesis 9:42 · 412 lines   ✓ Refine ×3`).
   The title is itself the disclosure: a chevron beside it, and opened, the same line runs on into
   the rest of the intent in regular secondary text (the first sentence is not repeated); no
   chevron when the title already is the whole intent. Its open state is kept per intake like the
   Clarifications rounds. (As built first: the whole intent as a `.title2` bold title towered over
   the page once it ran to a paragraph; then a separate "Request · Full text" section under the
   title read as a redundant second heading.)
2. **Clarifications** — each answered Q&A round is a collapsed "Round N · k questions" disclosure
   (question in secondary semibold, answer in primary, selectable). Present in every later state.
3. **The live card** — the stage-specific body (below). While shaping, it opens with the control bar
   (§4) and the departures board (§5), which pin under the toolbar when the document scrolls.
4. **Plan** — the plan viewer/editor (§7) with Plan · Diff vs Previous · Change set segments.
5. **Action bar** — pinned, below a divider: Discard (confirmed) on the leading edge; the state's
   primary action trailing, as the default button. Shaping has no primary here (the transport is it).

**Inspector (trailing, hidden by default, ⌥⌘I):** the Rounds editor grid for the chosen fidelity and
the selected seat's details. The notes rail (§7.3) occupies it while the plan is focused. Its
toggle (`sidebar.trailing`, `.primaryAction`) is the toolbar's far-right item — over the inspector
column when that is open — so the two sides mirror each other.

**Intakes rail (leading, ⌥⌘S):** the Intakes list collapses to a ~52 pt rail, per project
(`IntakeService.intakeListCollapsed`, persisted as `IntakeListCollapsedByProject`). The toggle is a
`sidebar.leading` button at the column's top-right, riding the column's edge in both states — in
the column rather than the toolbar because the toolbar's leading end already holds the window's
own sidebar toggle. The rail draws one disc per intake (`IntakeRailMark`): the pill's colour, a
glyph per state, and a solid orange disc with a white glyph for exactly the `needsAttention`
states; the selection is a neutral tile with an accent ring. Hover (the board's `HoverIntent`
rules: 350 ms rest, warm switching) or keyboard focus opens a `FloatingCard` beside the rail with
the pill and the request; click, Return or Space selects; ↑/↓ walk the selection. The composer
moves into a popover from a + at the rail's foot (Cancel/Esc, Triage ⌘↩), sharing one draft with
the expanded list's. The width animates 0.25 s ease-in-out (instant under Reduce Motion), and the
column draws over the detail pane rather than beside it: the detail takes its final width once,
at the start, so the animation never re-lays the detail or restarts the plan editor's whole-plan
pass per frame. The expanded list stays drag-resizable (280–420 pt) at its trailing edge.
⌃⌘S is left to the session sidebar's standard Show Sidebar; ⌥⌘S is Notes' chord for its folder
list and unbound in Ghostty's macOS defaults.

### 3.1 Stage bodies

| State | Live card body | Primary action |
|---|---|---|
| Triaging | Triage live card: one seat row (§6), elapsed, "Reading the repo" until the first event | — |
| Needs answers | The open round as a numbered form; multi-line answers; drafts persist | **Send Answers** ⌘↩ |
| Awaiting choice | Recommendation + reason; fidelity picker (**Single task** / Sketch / Feature plan / Full plan); the Rounds editor summary with "Edit in Inspector" | **Continue** / **Start Planning** |
| Shaping | Control bar + departures board + seat rows for the round in progress; finished rounds as cards with a detail panel (§3.2) | (transport) |
| Review | Summary of the change set; drift status | **Review Tasks…** ⌘↩ |
| Releasing / Released | Progress line; result + delivery warnings | **Dismiss** |
| Failed / Interrupted | Reason + raw output disclosure | **Retry** |

**No dead moments.** Every user action that starts agent work gives feedback within 100 ms: Send
Answers collapses the round, opens the triage live card with its clock at 0:00 and a queued seat row,
and updates the intake pill and the sidebar in the same state change. Start Planning and every
transport command do the same for the next round.

### 3.2 Finished rounds

The rounds already on the tape sit under the seat rows as a horizontal strip of cards (soft
leading/trailing fade), with a detail panel that opens below it — the Finder Quick Look strip's
shape (`FinishedRounds`, pure parts in `FinishedRoundsModel`).

- **Every card one size, the same fields in the same places**, whatever kind of round:
  stage group and duration; round name and one outcome glyph (the worst seat: failed ✕ red,
  fell back ⇄ amber, ran ✓); what it made ("14 changes" / "3 drafts") and lines; Verdicts as
  agreed · somewhat · declined numbers. A field the round has no value for shows a quiet "—"
  (a draft's lines and verdicts, a round without timestamps' duration) — never omitted, never
  invented. The full values are the card's hover text and VoiceOver label, which says missing
  fields in words, never a dash.
- **Click a card** → the panel opens below the strip, spanning the section, with a caret on its
  top edge pointing at the card; the round also shows in the plan, as a card click always has.
  The open card again, the panel's ✕, or Esc closes it; another card switches it in place. With
  the panel open, ←/→ step to the neighbouring round (stopping at the ends). An open panel
  follows the plan's round when the board or Back moves it; a round that leaves the tape closes
  it. Open state is per intake and held by the pane, so the live card's 1 Hz redraws never
  touch it (`FinishedRounds` is an `Equatable` boundary).
- **Panel content**: the facts (Duration, Changes, Lines, Verdicts in words — the same four for
  every round), the whole note, every seat with the model that ran and what went wrong, every
  section changed, and the notes the round consumed. Two columns (note | seats + sections) once
  the section is 760 pt wide; one column below that.
- **Height**: the panel is its content's height up to 360 pt; beyond that the content scrolls
  inside the panel. Switching cards animates the height from the old content's to the new
  (the window onto the content animates, not a re-layout) and slides the caret to the new card
  in the same beat; the caret tracks the strip's horizontal scroll unanimated, clamped clear of
  the panel's corners. Open/close animate. Reduce Motion: every change is instant.

## 4. Control bar (from Direction B)

At the top edge of the live card (in the content, not the window toolbar — it controls this run).

- **Transport**, three clusters: Back · Pause | Step ▶| · Next major ▶▶| · To review ▶▶◇ | Stop ■.
  A dot under a play button marks the default play mode; clicking a play button makes it the default.
  Hovering a play button previews its stop on the board and in the LCD (label becomes WOULD STOP).
  Each has a Run menu command: Step ⌘', Next Major ⇧⌘', To Review ⌥⌘', Pause ⇧⌘., Stop ⌘..
  "Pausing…"/"Stopping…" swap the button label with an inline spinner until the safe point.
  Stop ⌘. follows the OS-wide "period stops" convention. Stop discards the round in flight, so the
  key and ⌘. both ask first — "Stop the run?", naming the round whose work is discarded, Stop
  destructive and never the default (final-review ruling #6); Pause loses nothing and acts at once.
  Annotate is ⌥⌘A, since ⇧⌘A was already claimed by Add Project (T6 ruling). The Run menu also
  carries Show/Hide Section Heatmap (no chord), the keyboard's way to §8.3.
- **LCD readout**, one dark-glass instrument, monospaced phosphor values, tabular numerals, cells:
  `ROUND · OF N` · `ELAPSED` · `AGENTS DONE` · `SO FAR` (+/−) · `BILLED` · **`CONVERGENCE`** (§8.1) ·
  `STOPS AT`. States recolour only the relevant cell (PAUSED; FAILED red with the diagnosis replacing
  SO FAR; REVIEW amber "ready for you").
- **Round tools** at the trailing end: Extend (⌘=) and Annotate (⌥⌘A). The Run menu also carries
  Extend's mirror, **Remove a Round** (⌘-, unbound in `GhosttyDefaults.conf`), with no bar key of its
  own: it takes one unstarted round off the current cycle and is dark when no cycle has one (§5.2).
- **Width:** cells drop in a fixed order as space runs out — BILLED, then SO FAR, then STOPS AT (the
  board repeats it) — and every remaining cell applies the full-name/short-code rule. A narrow pane
  gets the compact bar (transport + ROUND + ELAPSED + CONVERGENCE).

## 5. Departures board (timeline, M2)

Directly under the control bar, in the same glass.

### 5.1 Board fields

`NOW` (current round + state chip, e.g. "Refine 3 · PAUSED", with a one-line status under it) ·
`IN THE AIR` / `PAUSED FOR` (elapsed) · `STOPS AT` (where the current play mode stops) ·
`CALLING AT` (the remaining major stops, e.g. "2 · Dedup · Review").

### 5.2 The tape

A row of stage slots, departure `DEP · CLR` to arrival `ARR · REV`: Clarify 1…n, Draft, Synthesis,
Refine 1…N (bracketed "REFINE ×N" with − and + handles), Encode, Polish 1…N (bracketed, − and +),
Fresh eyes, Dedup, Review. Each finished slot shows its duration; the live slot shows the playhead
and grows; future slots are empty frames; major checkpoints carry taller ruler ticks; flags mark
annotated rounds; the stop target is outlined in accent. A failed round is red with its duration.
Clicking a finished slot selects that checkpoint (the plan below shows it); hover shows a card with
the round's result.

**Adding and removing rounds.** The bracket's **+** (`TapeCommand.extend(stage, by: 1)`, "Add another
Refine round") lengthens the cycle while the head hasn't moved past it; the **−** beside it
(`TapeCommand.trim(stage, by: 1)`, "Remove a Refine round") takes one off the end while the cycle has
a *scheduled* round — not landed, not in the air, and not a failed one the next play reruns. Same
16 pt box, hover help and keyboard reach as +; VoiceOver hears the help text in words. Neither asks
first: an unrun round costs nothing, and the other handle undoes it.

`trim` is its own command kind rather than a negative `by`, so an older build reading
`commands.jsonl` drops it as an unknown kind (as it does a torn line) instead of folding it
unclamped; the unknown line's `seq` still counts when the next command is numbered. The runner folds
it against `RoundConfig` (`TapePlanner.apply(_:to:config:)`), storing the result as a negative
`extraRefinement`/`extraPolish`, clamped so the cycle never plans fewer rounds than have landed plus
the one in flight. Trimming to exactly that count ends the cycle after the current round; trimming a
cycle to zero before it starts drops it from the sequence (refine → Encode; polish → Fresh eyes, else
Review), and its bracket leaves the board. Because the board replays the planner, STOPS AT and CALLING
AT move off a trimmed round on their own; the runner matches that by taking a landing checkpoint's
`major` from the sequence as it stands (`TapePlanner.planned`), not as it was when the round started —
so ⏭ stops at the round the board marks as the new last, after an extend or a trim mid-round.

### 5.3 Names, codes and the split-flap card

- Every label (board fields, tape slots, LCD cells) is **measured** against its slot — text width
  from the actual font metrics, re-measured on resize — never a hard-coded breakpoint. It shows its
  full proper name ("Synthesis", "Refine 2", "Fresh eyes") when it fits, else its code (SYN, RF2,
  FRSH, DDUP, ENC, PL1, REV, CLR1).
- An abbreviated label is focusable and carries a subtle dotted underline. Hover or keyboard focus
  shows a **split-flap card** styled as part of the board (phosphor mono): full name, status and
  duration ("Synthesis · landed 3:02").
- **The card stays out of the way** (revised 2026-09-28 — it covered neighbouring slots and got in
  the way of moving the pointer along the tape). Hover opens it tooltip-style: only after the
  pointer rests on an item ~350 ms, never while it is just passing across the tape; once a card is
  up, the next item's card opens at once, until ~500 ms after the pointer leaves the last one.
  Keyboard focus opens it at once. It opens **above** its label, centred, with a small nub pointing
  at it and a ~7 pt gap, clamped inside the window's visible frame with an 8 pt margin; it flips
  below only when there is no room above, and opens below a field (NOW) rather than over the
  pinned control bar. It never takes the mouse, and closes on pointer exit, scroll, click, Esc,
  and the window losing key or minimising. The LCD's CONVERGENCE card keeps opening below (the
  bar is at the top of the live card), and the churn lane's versions card beside its marker.
- **The split-flap animation plays once, when the text first appears** — a board value changing to
  new text (NOW moving to Refine 3). It never replays on re-render, scroll, resize, or an unchanged
  value. Reduce Motion: no flap.
- **The hover card is the exception** (revised 2026-09-28; it was "the first time that card is
  shown", and in practice never animated — the board seeded every slot's card as already shown).
  Opening a card is a reveal, so its full name flips in as tiles **every time it opens**: quick,
  ~250–320 ms end to end, staggered left to right, with the card fading and scaling in over
  ~120 ms and fading out on close. Reduce Motion: no flap and no scale, a plain fade.

## 6. Live seat activity

Source: `runs/<run>/activity.json` (`SeatActivity`, written by the runner ≤ every 2 s) and
`triage/activity.json`, both already produced by the engine.

**Seat row** (one per seat in the round in progress):

| Field | Source / rule |
|---|---|
| Glyph | running (pulsing), queued, done, failed, fallback, needs-you — SF Symbols with Replace transitions |
| Identity | role (persona) · `harness · model · effort`; after a fallback `claude → codex` + reason line |
| **Headline** (primary) | `headline`: the agent's latest reasoning/thinking summary. Dwell ≥ 3 s |
| Action (secondary) | `action` as verb + object: Reading `Board.swift`, Searching "JobStatus", Running swift build, Editing plan.md. Dwell ≥ 1.5 s; paths middle-truncated |
| Footprint | `footprint` as chips by top-level directory (`Dispatch 7 · Core 4 · docs 2`); expands to the file list |
| Steps | `steps`: "Step 3 of 7 · <current step>" when the agent keeps a plan; hidden otherwise |
| Context | thin gauge of input tokens against the model's window |
| Elapsed | count-up m:ss, 1 Hz, monospaced digits |
| Cost | only when real (claude's final result), on finished rows and the round total |

**Exceptions** (the only colour): quiet ≥ 30 s (secondary "quiet 0:34"); stalled ≥ 90 s (amber, "No
output for 1:45 · last: Running swift build", Stop seat); rate-limited (amber, "Waiting on rate limit ·
0:42"); fallback (amber sub-line, "fell back to codex · claude 401"); failed (red + reason). A row
whose `activity.json` says unfinished while its `run.json` shows an exit is treated as finished.
Thresholds are named constants to be tuned against real runs.

**Results as they land:** a finished row collapses to its outcome — "14 changes across §2 §4 §7",
"agreed 11 · somewhat 2 · declined 1", "+42 −17 in 3 sections". The round's SO FAR builds up from
finished seats only.

## 7. Plan viewer and editor

### 7.1 Live-preview Markdown (Obsidian-style)

The plan renders as formatted Markdown (headings, lists, code, tables, inline code) and is editable
in place. The block holding the caret reveals its raw syntax (`## `, `**`, list markers); every other
block stays rendered. There is no separate edit mode. Implemented on AppKit `NSTextView` (TextKit 2)
wrapped for SwiftUI — styling by attributes over the source text, so the stored plan stays plain
Markdown. Edits are sent as `editPlan` when the field ends editing or after 2 s idle, never per
keystroke (`commands.jsonl` never compacts).

A new head arriving while the editor is focused replaces the text only when nothing is uncommitted
(`EditPolicy.shouldReplace(editing: true, dirty: false) == true`, final-review ruling #20): with
every keystroke already committed there is nothing to lose, and holding the head behind a banner
would only make the human click for a plan they would have taken anyway. With uncommitted typing,
the head is held and offered.

**Reading typography** (`PlanTheme`). Set for reading, not density: a 15 pt system body at a
1.5 line pitch (`lineSpacing` 4.5 — not `lineHeightMultiple` or a minimum line height, which on
TextKit 2 grow the caret to the padded line; the caret stays the text's own height), 6 pt after a
paragraph, 4 pt between list items with a hanging indent; headings 24 bold / 20 / 17 semibold with
24 pt above an H2 and 4 below; a Markdown blank line drawn as a ~9 pt gap, not a whole empty line.
Code fences are a padded rounded box (13 pt mono), drawn behind the lines by the layout fragment;
`>` quotes are indented with a quiet bar.

**Wraps to the pane.** No readable-measure cap: the text runs from the gutter lanes to a 32 pt
trailing margin at any width, and reflows live on resize — a fixed 720 pt measure broke every long
single-line paragraph at the same column, which read as hard line breaks in the plan. A resize tick
re-wraps only the viewport (~3 ms on 2,000 lines) and restarts the sliced whole-plan layout, which
a burst of ticks coalesces into one pass.

**Folding.** A disclosure chevron sits in the gutter beside each heading with something under it,
shown while the pointer is on the heading's line and always while folded; a click folds the section
(to the next heading of the same or a higher level; a `#` inside a code fence is not a heading), and
a folded heading shows "⋯ N lines", which opens it again. ⌥⌘← folds the caret's section (again: its
parent) and ⌥⌘→ opens it, only while the editor has focus — no menu item uses the chord, and
Ghostty's ⌥⌘← (goto_split) acts only in a focused terminal. Folding is a **view state**: TextKit 2's
content-storage delegate skips the folded paragraphs, so the stored plan, edits, note anchors and
diffs are untouched (tested byte-identical). The caret or a Find match landing in a folded section
opens it; a note anchored inside one sits in the rail beside its heading. Folds are kept per intake
for the session (`IntakeService.planFolds`) by heading text plus occurrence, follow a heading
through typing on it, and survive a new round by heading text (a fold whose heading vanished is
dropped).

**Links.** `[text](target)`, `<https://…>` autolinks and bare `http(s)://` URLs are tinted,
never underlined, and a plain click on one is a click in an editor — the caret goes there.
⌘-click opens it: web and `mailto:` targets in the default browser or mail app; file targets
(absolute, `~`, `file://`, or relative to the intake's project, with any `:line[:col]`, `#L42`
or `#fragment` stripped). Source, scripts and other text (`.py`, `.js`, `.ts`, `.sh`, `.command`,
`.json`, `.txt`…) open in the default text **editor** — never the file's own handler, which may run
it (Python Launcher, Terminal): a plan is agent-written text, and a ⌘-click must never be how it
executes code. A directory, and what can't be read and would run (an app, `.pkg`, `.dmg`,
`.terminal`, `.workflow`, `.scpt`, a binary), is revealed in Finder. Everything else (Markdown,
PDF, images) opens in its default app. A missing file beeps and says "Not found: …" under
the link for a moment, no alert; any other scheme is ignored. While ⌘ is held over a link the
pointer is a pointing hand, the link is underlined and a tip under it names the resolved
target — tracked by mouse moves and modifier changes only, never per keystroke. The target is
read from the Markdown parse, not the glyphs (off the caret block the `(target)` is hidden).
Links carry `.link`, so VoiceOver finds them as links and its press opens them.

**Where you are.** Once the section being read has scrolled its heading under the pinned block,
its name shows in the pinned board's footer between DEP · CLR and ARR · REV, in the board's caption
("§ 5. MOBILE CHECK-IN"); a click brings the heading back under the block. Nothing shows while the
heading is on screen, nothing animates. Chosen over a trailing tick rail and a leading-margin bar
(both rendered; the rail read as dashes beside the text, the bar said nothing without a label) and
over the same breadcrumb drawn in the text (it covered the first line under the block). VoiceOver
has a Headings rotor on the editor for the outline.

### 7.2 Your edits as a layer

Built on `PlanLayers` (engine, landed): `plan.md` is the agents' plan, `plan.user.md` your edited
version; the effective plan feeds the next round with an "edits are authoritative" block.

- Your insertions: subtle green-tinted background; deletions struck through, dimmed, red-tinted; a
  green bar in the **edit gutter lane**.
- Header chip: "N edits by you · Revert all"; per-hunk hover offers Revert (`PlanLayers.revert`).
- "Your edits are kept; the next round treats them as fixed." shown once per plan.
- The agents' round-to-round changes use a separate, neutral treatment in *Diff vs Previous*.
- Edits made mid-round carry forward by three-way merge (engine, landed). A conflict shows an amber
  banner on the new head — "Your edits to Refine 2 conflicted with this round · Open Refine 2" — from
  `PlanLayers.conflictedEdits`.

**Plan text is stored unwrapped.** Every paragraph and every list item is ONE line; blank lines
separate blocks. The seats hard-wrap prose at ~80–100 columns out of habit, and a wrapped paragraph
edits badly (the editor soft-wraps it again at its own width, leaving ragged half-lines). Two
layers keep it out: every prompt that writes plan text (draft, synthesis's and refine's `edit`s,
the integrator) carries the same rule (`RoundPrompts.planTextRule`), and the engine joins whatever
comes back anyway (`MarkdownUnwrap`) before a draft, an integrated plan, or an encode/polish copy
is recorded — code blocks, tables, headings, HTML, front matter, hard breaks, link definitions and
list structure keep their breaks. `plan.user.md` is stored unwrapped too.

Checkpoints already recorded wrapped are never rewritten. Instead every *comparison* reads both
sides unwrapped (`PlanLayers.readPlan` — the layer reads, the edit-layer base in the app,
`writeUserEdits`' identity check, the carry-forward merge, section churn): so a reflow is never an
edit, never churn, and never a merge conflict, and the first round over a wrapped checkpoint
counts only what it changed. Notes quoted across a former line break still locate, since
`NoteAnchor.locate` treats whitespace runs — and a blockquote's `>` opening a line — as one space.

**What "lines" means.** Line counts (`+N −M`, a draft's "N lines", section churn, the heatmap) stay
counts of Markdown source lines, now one per paragraph, list item, heading, table row or code line
— i.e. roughly per block for prose. Nothing is converted: records written before this change keep
the wrapped counts they were measured with, so an older intake's cards can show larger numbers
for rounds before the change than after it. No UI label changes.

### 7.3 Highlight and annotate (Plannotator-style)

- Selecting text shows a floating toolbar: **Comment · Question · Must change · Replace · Delete ·
  Highlight**.
- An annotated range gets a system-highlight tint; its card sits in the **notes rail** (the trailing
  inspector while the plan is focused), aligned to its anchor: quoted snippet, kind tag, note text,
  trash. Writing a note happens in the card, never a modal.
- A summary chip: "4 notes for the next round"; the next-round transport button's tooltip says
  "sends your 3 edits and 4 notes".
- Notes are `PlanNote` with a `NoteAnchor` (quote + prefix/suffix + section); `NoteAnchor.locate`
  re-finds them after edits; a note that can no longer be located shows detached at the top of the
  rail with its quote.
- ✎ Annotate without a selection creates an unanchored note in the rail.

## 8. Convergence

Data: `ConvergenceSeries` (engine, landed): per Refine/Polish cycle, points of proposed changes,
agreement, lines churned and sections touched; a verdict `tooEarly | converging | plateau |
diverging` with an explanation and a suggested action; `sectionChurn` per checkpoint. Always "a
signal, not a promise"; never a notification.

### 8.1 LCD sparkline (A)

The `CONVERGENCE` cell, beside `STOPS AT` (evidence, then action): a phosphor sparkline of changes
per round for the current cycle ending at the latest point, the latest count, and a state word —
`CONVERGING ↘` · `PLATEAU →` · `DIVERGING ↗` (amber) · `TOO EARLY`. Hover shows a board-style card:
the series ("41 → 14 → 5 changes · agreement 70% → 90% · 4 of 7 sections still since R2") and the
action ("Converged: ⏭ to encode", "Plateau: consider annotating §4 or stopping", "Diverging: §4 keeps
changing — decide it yourself"). Click toggles the heatmap.

### 8.2 Gutter churn (E)

In the plan, each heading gets a **churn lane** in the margin, separate from the edit lane: one small
bar per round in the current cycle, height = that section's lines changed. Settled sections read
"still since R2" in tertiary text. A section flagged diverging turns amber, its repeatedly-changed
sentence gets a subtle amber highlight, and hovering the marker shows that sentence's version per
round (from the checkpoints' kept `changes.json` + `verdicts.json`). The versions card hangs just
under the marked heading's line, left edge on the text's, with a small pointer up at the line; it
flips above only when the visible page has no room below, and never covers the heading line (it
used to open beside the text, which wrapped to the pane left no room for). Clicking a churn tick opens the
heatmap at that section.

### 8.3 Heatmap on click (D)

An inline disclosure in the board's glass, directly under the tape (not a popover: it must survive
clicks into the plan and must not cover what it describes). Rows = plan sections; columns = rounds
R1…Rn aligned under the tape's slots, each with an agreement mini-bar; cell luminance = lines
changed; an amber outline on sections the verdict names. Clicking a cell scrolls the plan to that
section and switches to *Diff vs Previous* at that round. Closes with the same control or Esc.

## 9. Fidelity choice and Rounds editor

The awaiting-choice body shows the recommendation and a segmented fidelity picker. The Rounds
configuration lives in the inspector as the existing aligned grid (Role · Harness · Model · Effort ·
Fallback; leading-aligned fallback column), caps and default play; the body shows a one-line summary
("Full plan · 4 drafters · refine ×5 · polish ×6 · customized") and **Edit in Inspector**, whose help
says that is where a stage's round count changes. A cap of 0 is the pre-run way to remove refine or
polish: the stage drops out of the summary line and of the board. Fresh eyes + dedup and the polish
cap are disabled with an explanation when there is no polisher.

## 10. Release review

The existing sheet, renamed throughout to tasks: "Release plan as tasks", sections **New tasks /
Edits / Dependencies**, primary **Release 3 New Tasks** (default, trailing), Cancel leading. It
carries forward the notes a round consumed ("1 note carried into task notes").

As built (final review): the button, the summary line and the header count the same things, from
one rule (`ReleaseCounts` over the ops not dropped or impossible). The summary reads "3 new tasks ·
2 edits · 2 dependencies · 2 notices (1 session message, 1 mail)" and the button carries its new-task
count ("Release Changes" when there is none). The header says "2 dropped" once something is left
out, in place of "14 of 14 selected" — rows can only be dropped, never selected. Rows name tasks by
title (the id is in the help tag); an existing task waiting on a new one is badged "waits for
release", never "held".

## 11. What is already built vs. what this adds

Landed on `flywheel-intake` (engine only): `SeatActivity`/`ActivityParser` + `activity.json` for
seats and triage; claude `stream-json`; incremental run output; `PlanLayers`, `PlanNote`/`NoteAnchor`,
`editPlan`, mid-round three-way carry-forward; `ConvergenceSeries`, kept proposals and per-change
verdicts, section churn; the HIG action bar and collapsible Clarifications (interim styling).

This design adds, app-side:
- `IntakeService` publishing per-seat `SeatActivity` for the round in progress (mtime-gated on the
  existing tick) and `ConvergenceSeries` for shaping intakes.
- The control bar, departures board (with the measured-label and split-flap components), seat rows,
  round result cards, the header progress summary, and the no-dead-moments transitions.
- The live-preview Markdown editor, edit layer rendering, notes rail and floating toolbar.
- The convergence cell, churn lane and heatmap.
- The inspector (Rounds editor, seat details, notes rail) and Run menu commands.
- The "tasks" terminology pass and its guard test.

## 12. Non-goals (this spec)

Branches and rewind; the Tasks tab / graph review; oracle, grok and gemini slots; a menu-bar extra;
notifications beyond needs-you and complete; tuning of the quiet/stall/convergence thresholds (they
ship as named constants and get tuned against real runs later).

## 13. Testing

- **Pure models, unit-tested:** the board/tape model (slots, majors, stop target, codes), label fit
  (full vs code given widths), the split-flap "plays once per new text" rule, seat-row formatting from
  `SeatActivity` (verb/object, exceptions by thresholds with an injected clock), convergence cell and
  heatmap models from `ConvergenceSeries`, edit-layer hunk rendering, note placement from anchors, the
  terminology guard (no user-visible "bead" literal in `Sources/FlightDeck`).
- **Offscreen renders** (env-gated, skipped by default) of every stage body and the combined shaping
  screen in converging / plateau / diverging, at full and narrow widths, for review.
- **GUI checklist** (Nate): a real Feature plan and a Full plan end to end; editing the plan
  mid-round; annotating; the convergence heatmap; Reduce Motion; VoiceOver labels on the board and
  seat rows; keyboard: every transport command and the split-flap card on focus.

## 14. Accessibility

Every board slot, LCD cell and seat row has an accessibility label in full words (never a code);
the split-flap card's text is the label, not a separate announcement. Live regions announce state
changes (round landed, failed, needs you), never per-second clocks or action-line churn. All
interactions reachable by keyboard; focus rings on the tape and heatmap cells.
