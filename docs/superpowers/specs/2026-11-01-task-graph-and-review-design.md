# Task graph views and inline Review Tasks — design

Date: 2026-11-01 · Status: draft for review

## 1. Why

Flight Control's planning rounds turn a plan into tasks, but today you cannot *see* those tasks as a
structure anywhere:

- The planning **Task Graph** tab (`TaskGraphViews.swift`) is a long list of cards in dependency
  order. Links are plain text. At LarkOS scale (95 new tasks) you cannot see what blocks what,
  how wide the swarm can run, or where the critical path is.
- **Review Tasks…** opens `ReleaseReviewView`, a 620×520 sheet with one line of text per op. It
  does not show a new task's description, acceptance, priority or labels. Edges are listed as
  flat "A → B" lines. The only actions are Confirm and Drop, and only on drifted ops. It is a
  checkbox in front of Release, not a review.
- After release, nothing shows how the released tasks are doing.

This design adds one set of task views. They are used in three places: the planning Task Graph
tab, the review state, and after release. From review on, the task views replace the planning
view as the detail pane's main content. The plan stays one click away.

## 2. Goals

1. A real dependency graph, with wave bands behind it that show which tasks can run together.
2. Three views of the same tasks: **Graph**, **Board** (status columns) and **Outline**
   (parent/child tree). One switcher, the same in every place the views appear.
3. Click any task in any view to open its full detail in the **inspector**. Links in the detail
   can be clicked and go to that task.
4. **Review Tasks becomes the task views with editing switched on.** It is inline in the detail
   pane, not a sheet. You can:
   - drop any task or edge (dropping a task cascades, and the cascade is shown before it applies);
   - edit fields inline;
   - add and remove dependencies, in the graph or in the inspector;
   - send chosen tasks back to planning with a note.
5. From the review state on, the task views take over the detail pane. A **Tasks | Plan** toggle
   brings back the final plan.
6. After release the views show **live status** from `br`: ready, in progress, blocked and done,
   and who holds each task. A gauge sums it up. This is the "task-graph convergence gauge" (F)
   from `FLIGHT-CONTROL-LEVEL3-HANDOFF.md:173`.

## 3. Non-goals

- The phone app. It keeps its "Review and release on your Mac" placeholder. The pure model and
  layout must not depend on AppKit or SwiftUI, so the phone can use them later.
- A project-wide Beads tab that shows all of a project's tasks outside any intake.
- Editing existing tasks that the change set does not already touch. They appear as ghost
  nodes because an edge names them, and they can be selected and read, but not edited.
- Moving Flywheel Observe's DAG overlay onto the new renderer. The shared layout code may be
  generalised so that Observe consumes it, but Observe's look and behaviour must not change.
- A full re-triage path for drifted ops. They go back through the send-back round instead
  (§7.5).

## 4. Anti-goals: a failure even if it technically works

- A hairball. At 95+ tasks the graph must still be readable: ranked layers, crossing
  reduction, edge kinds that look different, and a focus mode.
- Losing information the current cards show (description, acceptance, edits, delivery, reasons,
  links). Every field must still be reachable through the inspector.
- Nodes that jump when only status changes. Layout is keyed on topology, the way
  `DependencyGraphLayout.contentHash` already works.
- An edit that is silently invalid. Every review edit is validated as it is made. An invalid
  edit (a cycle, a dangling edge) is refused, with the reason shown where you made it.
- The plan becoming hard to reach once the task views take over.
- Review edits lost by send-back, by a relaunch, or by a release that fails before anything is
  written.

## 5. Where the views appear

| Place | Views | Editing | Status source | Default view |
|---|---|---|---|---|
| Planning, **Task Graph** tab (shaping) | Graph, Board, Outline | no | planned (§6.3) | Graph |
| Planning, **Task Changes** tab | Graph, Outline, with a changes overlay | no | planned | Graph |
| **Review** (takeover) | Graph, Board, Outline | yes | planned + drift | Graph |
| **Releasing** | same as review, read-only | no | planned | last used |
| **Released / Partially released** (takeover) | Graph, Board, Outline | no | live `br` | Board |

- The view choice is remembered per intake. `IntakeService` keeps it next to the draft, because
  view `@State` is reset when you switch projects.
- Task Changes keeps today's meaning: what this round added, removed and changed compared with
  the previous checkpoint that had tasks. *(My call: it reuses the Graph and Outline views with
  a green/red/orange overlay instead of its own card list. Removed tasks appear as struck-through
  ghosts. The inspector shows the word-level field diff and the gained and lost links that
  `ChangedTaskCard` shows today. Board is left out of Task Changes because status columns say
  nothing about a diff.)*
- The existing card list (`TaskGraphView`/`TaskCard`) goes away. Its content moves into the
  inspector's task detail.

## 6. The views

All three views draw the same model (§8.1). They share the same selection, the same
search/filter field, and the same toolbar: a segmented **Graph | Board | Outline** control,
search, a filter menu, and (Graph only) zoom-to-fit.

### 6.1 Graph

- **Layout:** layered left to right, one layer per wave.
  - **Wave** = the longest path over `blocks` edges only. Wave 1 tasks have no blockers in the
    set. A task in wave *n* waits only on tasks in waves before *n*.
  - Faint alternating vertical bands behind the nodes mark each wave, labelled "Wave 1",
    "Wave 2" and so on at the top. The bands are the only wave display; there is no separate
    Waves view.
  - Order within a layer comes from barycenter crossing reduction, a few sweeps, ties broken by
    id so the order is deterministic. The current `DependencyGraphLayout` orders by id only,
    which is not good enough at this scale.
  - `parent-child` and `related` edges do not affect rank.
- **Nodes:** a card about 180×56 pt.
  - Title (up to 2 lines), then a line with id, type and priority, then badges: change origin
    (new / follow-up / edit / reopen), drift, and status.
  - **New** tasks are solid. **Existing** tasks named only by an edge are ghost nodes: dimmed,
    with a dashed outline.
  - **Edited** existing tasks have a coloured outline.
  - **Dropped** tasks (review) are struck-through ghosts, and are hidden unless "Show dropped" is
    on.
  - When zoomed out past a threshold, a node shows only its title.
- **Edges:**
  - `blocks`: solid arrow.
  - `parent-child`: thin grey line, no arrowhead.
  - `related`: dotted, hidden by default and shown from the filter menu.
  - An edge held until release (its `from` side is an existing in-progress task) is dashed,
    which matches today's "waits for release" badge.
- **Interaction:**
  - Pan, pinch or ⌘-scroll zoom, minimap, zoom to fit. Reuse or generalise `DAGCamera`, the
    hit-testing and the minimap from `Flywheel/Observe`.
  - Clicking a node selects it, and the inspector shows it.
  - **Focus mode:** with a task selected, tasks that are neither upstream nor downstream of it
    are dimmed, and its full chain stays bright. Esc clears it.
  - **Critical path:** the longest `blocks` chain is highlighted with a thicker stroke, toggled
    from the filter menu, on by default.
  - **Review editing:** each node has a small handle on its right edge. Drag from the handle to
    another node to add a `blocks` edge (the source depends on the target; the inspector shows
    the direction as "Depends on" before you commit). Click an edge to select it; Delete removes
    it. Selecting a node and pressing Delete drops the task (with cascade confirmation, §7.2).
    In any other state the graph is read-only.

### 6.2 Board

- Columns, left to right: **Ready**, **Blocked**, **In progress**, **Done**. Add **Deferred** only
  when a task in the set has that status.
- A card shows title, id, type, priority and badges, plus the holder (agent) when one exists.
- Before release, the column comes from *planned* status (§6.3). After release it comes from
  live `br` status.
- Cards are not draggable. Status belongs to the swarm, not to this view.

### 6.3 Planned status (before release)

- A new task is **Ready** if every task it depends on (by `blocks` edge) is done or is not in
  the graph. Otherwise it is **Blocked**.
- An existing task uses its status from the checkpoint's `graph.json`.

### 6.4 Outline

- A tree built from `parent-child` edges. Roots are tasks with no parent in the set, ordered by
  wave, then id.
- A row shows a disclosure triangle, title, id, type, priority, change and drift badges, wave
  number, and "⇠ n / ⇢ m" (depends on n / needed by m).
- A task with no parent and no children is a root with no triangle. Expand all / collapse all.

### 6.5 Selection, keyboard and search

- One selection is shared across views, so switching views keeps the selected task.
- ⌘1, ⌘2 and ⌘3 switch views. *(My call: the builder can pick other keys if these clash.)*
- Arrow keys move the selection:
  - Outline: up and down.
  - Board: within a column, and to the next column.
  - Graph: up and down within a wave; left and right to the nearest task in the previous or
    next wave.
- ⌘F focuses search. Search filters by title, id and label substring. Matches are highlighted
  and everything else is dimmed; nothing is hidden. Esc clears search, then selection.
- Multi-select (⇧/⌘-click) exists only for send-back (§7.5).

## 7. Review Tasks (inline)

### 7.1 Layout

From `.review` on, the detail pane has three parts:

```
┌ [Tasks | Plan] ─────────── Graph│Board│Outline  🔍  ⏷ ┐
├──────────────────────────────────────┬─────────────────┤
│ ·wave 1·    ·wave 2·    ·wave 3·      │ Inspector:      │
│   ○──────────○──────────●             │ selected task   │
│    ╲─────────○                        │ (editable)      │
├──────────────────────────────────────┴─────────────────┤
│ 12 new · 3 edits · 9 deps · 1 drifted · ⚠ export  [Send Back…] [Release] │
└────────────────────────────────────────────────────────┘
```

- **Tasks | Plan** toggle at the top. Tasks is the default from review on. Plan shows the final
  plan exactly as `planIsFinal` renders it today, with the inspector's Notes and Rounds as today.
- `DetailLayout.sections(for:)` changes so that from `.review` on the content is
  `[.header, .tasksOrPlan, .reviewBar/.releasedBar]` instead of `[.stageBody, .plan]`. The
  Tasks/Plan choice belongs to the view; `DetailLayout` stays pure logic with tests.
- The **review bar** (pinned at the bottom, in the control-bar position) holds:
  - the counts line, and the drift count, which can be clicked to select the next drifted task;
  - a disclosure for the export file list, the export refusal, visual warnings and carried
    notes;
  - **Send Back…** and **Release**. When Release is disabled its help says why, as today
    (`ffe376cc`).
- The primary action "Review Tasks…" and `ReleaseReviewView`'s sheet are removed. Release moves
  to the review bar. Cancel no longer exists, because nothing is modal.

### 7.2 Dropping

- Any task or edge can be dropped: from the inspector, with Delete on the selection, or from a
  context menu.
- Dropping a task also drops every edge that names it, plus any follow-up whose `of` is that
  task *(my call)*. A confirmation popover lists exactly what will go ("Also drops 3
  dependencies") before it applies.
- Dropped items stay in the model as struck-through ghosts. "Restore" in the inspector undoes a
  drop, and restoring a task restores whatever its drop cascaded to.
- ⌘Z / ⇧⌘Z undo and redo every review edit (drop, field edit, edge add/remove) through the
  window's `UndoManager`. Undo history only needs to last for the session; the edits themselves
  are saved (§8.3).

### 7.3 Editing fields

- In review, the inspector's fields for a selected `createTask` / `followUp` / `editBead` op can
  be edited:
  - `createTask`: title, description, acceptance, priority, labels, type.
  - `followUp`: title, description.
  - `editBead`: the fields in its `FieldSet`.
- Text fields commit when they lose focus or on ⌘↩. Each commit is one undo step.
- Description and acceptance are multi-line Markdown text fields with a preview toggle.
  *(My call.)*
- An edited field is marked "edited in review" with a small revert button. The original
  planning value is kept until release.

### 7.4 Editing dependencies

- **Graph:** drag from a node's handle to add an edge; select an edge and press Delete to remove
  it (§6.1).
- **Inspector:** the Depends on / Needed by / Parent / Children / Related groups each have a "+"
  that opens a task picker (search over tasks in the set *and* existing tasks in `graph.json`).
  Each row has a "−".
- Every add is validated against the triage graph plus the amended change set with
  `ChangeSetValidator` before it applies. A cycle or duplicate is refused inline with the
  validator's message, and the drag snaps back.

### 7.5 Send back with a note

- Choose one or more tasks (multi-select, or the current selection). Then use **Send Back…**
  in the review bar or "Send back…" in the inspector. A sheet asks for a note. The note is
  required.
- **A new round type: Revise** (the maintainer's decision). It is a new `Stage` case after `dedup` and is
  never part of a planned sequence. It is appended after the head only by send-back.
  - Send-back is a new `TapeCommand`, for example `.revise(note:, taskRefs:)`. The intake goes
    from `.review` back to `.shaping`, and the runner runs exactly one Revise round. When it
    finishes, the tape reaches review again through `finishShaping`, as it does today.
  - Fresh eyes and dedup **do not** run again.
  - **Seat:** the polisher. With no polisher (Sketch), the encoder.
  - **Contract:** like polish, Revise returns a `ChangeSetPatch` against the change set it was
    given, never the whole set. The prompt carries a "Reviewer requests" section: the note,
    plus the chosen tasks' ids, titles and full fields.
- **The reviewer's edits are locked, and the scope is the chosen tasks** (the maintainer's decision).
  - The patch may replace or remove only the chosen tasks' ops and the edges that name them. It
    may add new tasks and edges, for example to split a chosen task.
  - It may not touch anything the reviewer dropped or edited, which includes edits on a chosen
    task.
  - A patch that breaks these rules is refused with a `ChangeSetPatch.Problem`-style message,
    and the round gets the same repair turn a bad polish patch gets today. A second refusal
    fails the round, leaving the intake in review with the amended set intact.
  - The next review marks every task the round changed ("revised"). Task Changes compares the
    new checkpoint with the review checkpoint below, so it shows only the round's changes.
- **How the amended set reaches the round:**
  - Before running Revise, the runner writes a **review checkpoint**. It is a checkpoint no
    agent produced, with the amended change set as its `changeset.json` and the same
    `graph.json`. This is the precedent of `editPlan`, which writes human content into a
    checkpoint.
  - The review checkpoint shows in the rounds strip and the Rounds inspector as "Your review"
    (edits, drops and the note).
  - Revise reads it as its input, the way polish reads the newest `changeset.json`.
  - Because the review checkpoint already contains the amendments, `finishShaping` clearing
    `reviewPatch` loses nothing.
- **Drift:** a drifted op's inspector also offers **Send back**. It prefills the note with the
  drift reason and suggested fix, and the drifted task is chosen. This replaces a re-triage
  path (FOLLOWUPS:1931) for v1.
- **Single-task intakes** (preset `.bead`: no tape, no rounds, no plan) *(my call)*:
  - Send Back is hidden.
  - The Tasks | Plan toggle is hidden and only Tasks shows.
  - Field and edge editing and drops still work.

### 7.6 Drift and in-progress edits

- Drifted ops are computed as today (`reviewModel` / `DriftClassifier`).
  - They are drawn with an orange outline and a drift badge in every view.
  - The inspector shows the reason, the suggested fix, and **Confirm** / **Drop** /
    **Send back**.
  - Release stays disabled until every drifted op is confirmed or dropped.
- An in-progress existing task being edited shows its holder, the Rating picker and the planned
  delivery in the inspector, which carries over today's sheet rows.
- `reviewModel` is re-run whenever the amended change set changes, debounced. FOLLOWUPS:2567
  notes the export preview is re-read on every change; debounce that too.

## 8. Model and code shape

### 8.1 `TaskSet`: one model for every view

- A pure, platform-neutral value type in **IntakeKit**, so the phone target can use it later. It
  is built from:
  - a change set, which may already have review amendments applied;
  - the checkpoint's `graph.json` (existing task titles and statuses);
  - optionally a drift map;
  - optionally a diff (`TaskGraphDiff`);
  - optionally live status keyed by bead id.
- It holds nodes (today's `TaskGraphModel.Task` fields plus wave, planned/live status, drift and
  drop state, and change tone) and typed edges.
- `TaskGraphModel` and `TaskGraphDiff` move into or behind it. Their tests
  (`TaskGraphModelTests`) are kept and extended.

### 8.2 Layout

- `TaskGraphLayout` is pure and lives next to `TaskSet`.
  - Input: nodes and typed edges.
  - Output: positions, wave bands, edge routes (straight or with one bend), and a topology hash.
  - Ranks come from `blocks` only, with barycenter crossing reduction.
  - The result must be deterministic for the same input, and a status-only change must not
    change the hash.
- Generalise `Flywheel/Observe/DependencyGraphLayout.swift` into it, or write it new and point
  Observe's layout at it. Either way Observe's tests must still pass. The camera (`DAGCamera`),
  hit testing and minimap are reused from Observe.
- Drawing uses SwiftUI `Canvas` (as Observe does). Do not add a package dependency.

### 8.3 Review amendments: persisted

- `Intake` gets `reviewPatch: ChangeSetPatch?` (`Sources/IntakeKit/ChangeSetPatch.swift`). This
  is the same patch shape polish rounds already return:
  - remove → drops, replacing today's `droppedOps`;
  - replace → field edits;
  - add → new edges.
- The **amended change set** = `changeSet` with `reviewPatch` applied. It is what these use:
  - `reviewModel`, drift, the export preview and `release(_:)`;
  - the views;
  - the send-back round's input.
- Migration: an `intake.json` with `droppedOps` but no `reviewPatch` decodes into an equivalent
  patch. `confirmedDrift` and `ratingOverrides` stay as they are, keyed by the *amended* op
  index. *(My call. The builder may re-key them by op identity if indices prove fragile.)*
- Removing an edge that planning created goes in `remove`, by op index. Removing an edge added in
  review deletes it from `add`.
- `finishShaping` clears `reviewPatch` along with the other review state, as it clears them
  today.

### 8.4 Live status after release

- The released task ids are `ReleaseRecord.idMap.values` plus the existing task ids the change
  set touched.
- A `ReleasedTaskWatcher` is shaped like `FlywheelWatcher`:
  - mtime-gated on the project's `.beads` store, on the shared `WatchClock`;
  - it polls only while a released intake's task view is on screen;
  - one `br list --all --json` per real change, filtered to the released ids.
- Board columns map from `br` status. "Blocked" = open with an open blocker.
- In the graph, nodes are coloured by status and show the holder.
- **Gauge**: a strip under the toggle reading "12 ready · 3 in progress · 2 blocked · 40 done",
  with a segmented progress bar. It is in the released bar with **Run Tasks…**, which stays
  where it is now, and **Dismiss**.
- For `.partiallyReleased`, ops that were not applied appear as "not released" ghosts. The bar
  shows the existing error text.

### 8.5 Removed or replaced

- `ReleaseReviewView` (sheet) and `ProjectView.reviewIntakeID`. `ReleaseSheetModel` logic that
  is still needed (line text, field diff, the "can release" reason) moves to the review bar or
  inspector models.
- `TaskGraphView`, `TaskCard`, `TaskChangesView`, `ChangedTaskCard` as list views. Their pieces
  move into the inspector's task detail.
- `IntakeDetailView.reviewBody` / `releasedBody` become the review and released bars.
- Stale comments: `ProjectView.swift:11` ("Beads tab arrives with the next plan") and
  `ReleaseReviewView.swift:77`.

## 9. Constraints

- macOS SwiftUI, native `Canvas`. No new packages (`project.yml` has only MarkdownUI and HostKit).
- Performance:
  - Pan and zoom stay smooth (60 fps) at 150 nodes / 300 edges.
  - Layout for that size takes under 50 ms on the main thread, or runs off-main.
  - Measure this live on a real LarkOS-sized change set; the CLAUDE.md perf rule applies.
- Users see the words "task" and "Flight Control", never "bead" (the UIText guard test).
- `DetailLayout` stays pure logic with unit tests. The new view and state logic gets the same
  treatment (pure models, unit-tested); views are thin.
- Tests run with `./scripts/test-unit.sh`. Render tests follow `TaskGraphRenderTests`.
- Accessibility: every node, card and row has a label (title, id, status, wave). Keyboard
  navigation is as in §6.5.

## 10. Left to the builder

- Exact visual styling: node sizes, colours, band tint, and the zoom threshold.
- Edge routing details, and how many crossing-reduction sweeps.
- Whether `TaskGraphLayout` generalises Observe's layout or replaces it, as long as Observe's
  behaviour and tests hold.
- The phasing of the work. A sensible order: model + layout → read-only views in the planning
  tab → takeover and Tasks | Plan → review editing → send-back → live status.
- Debounce intervals and the watcher's poll cadence.

## 11. Calls I made (please check)

1. Task Changes reuses Graph and Outline with a diff overlay, not its own list (§5).
2. Dropping a task also drops follow-ups of it (§7.2).
3. Revise, the round type and scope you chose, works through a **review checkpoint**. The
   checkpoint holds the amended set, shows as "Your review" in the rounds strip, and is the base
   for Task Changes (§7.5).
9. Single-task intakes hide Send Back and the Plan toggle, and keep editing (§7.5).
4. Drifted ops are sent back through planning, not re-triaged (§3, §7.5).
5. Review edits are persisted as a `ChangeSetPatch` on the intake (§8.3).
6. Existing tasks that the change set does not touch are read-only (§3).
7. After release the default view is Board; everywhere else it is Graph (§5).
8. ⌘1, ⌘2 and ⌘3 switch views (§6.5).
