# Flight Control Observe (Level 1) GUI verification checklist

> Agents cannot drive the real Flight Deck app (AGENTS.md rule 2: no headless host for an
> AppKit/SwiftUI surface). Every Observe view (`ObserveDrawer`, `DependencyDAGOverlay`) is
> built on pure, unit-tested models — this checklist is the only place their wiring into the
> live app is actually exercised, and it is **Nate's** to run, not an agent's.

## Purpose

Confirm the Level 1 Observe drawer and DAG overlay behave correctly against a real,
running Flight Control project — real `am`/`br` shell-outs, real `WatchClock` polling, real
SwiftUI mounting — the parts no unit test can reach.

## Prerequisites

- A scratch repo with Flight Control markers (`.beads/`, `.agent-mail.yaml`) and **at least two**
  agent-mail identities that have run `am macros start-session`, so at least one bead is
  `in_progress` and assigned, and at least one file reservation exists with a waiter (needed
  for steps 6–7 below; reservations currently only come from a real `am reservations`
  invocation outside Flight Deck — see the FOLLOWUPS note on that lane being a nil-stub in
  the app's own read path).
- Flight Deck built and run in place (never swap `/Applications` mid-session — see
  `docs/AGENT-OPERATIONS.md`).
- A way to force the block/stall/collision conditions in steps 6–7 (e.g. `am` CLI calls
  against the scratch repo from a separate terminal, or letting a real agent sit idle).

## Steps

### 1. Enable Flight Control; drawer appears only under an identity tab

Right-click the project row in the sidebar. If the repo has no Flight Control markers yet, the
item reads **"Set Up Flight Control…"**; if markers already exist, it reads **"Enable Flight Control…"**
(`ProjectHeaderRow.swift`, the two are deliberately distinct entry points — confirm the
right one is offered for the scratch repo's state). Confirm, then:

- Open a tab that booted as a registered Flight Control identity (via `am macros start-session`).
  The Observe drawer should appear directly under the terminal, expanded by default.
- Open (or create) a tab in the same project that is **not** a Flight Control identity (a plain
  shell tab). Confirm the drawer is **absent** — not collapsed, not empty, simply not
  mounted. The drawer is gated on the *tab's own* `Session.flywheelIdentity`, not on the
  project being enabled (`SessionStore.focusedObserveAgent()`).

**Expect:** drawer present under an identity tab, fully absent under a non-identity tab in
the same enabled project.

### 2. Drawer follows the focused tab; lane data

With two or more identity tabs open, switch focus with **Shift+Cmd+[** / **Shift+Cmd+]**
(`TabNavigationCommands.swift` — this is the general tab-cycle shortcut, not
Observe-specific, but it's what moves focus here). Confirm the drawer's content updates to
the newly-focused tab's agent on every switch.

Check each of the four lanes (Working on / Files / Dependency / Activity):

- **Working on** is backed by real `am agents list` + `br list --status in_progress` reads
  and should show the agent's actual assigned bead id/title, or "no assigned bead".
- **Files / Dependency / Activity** are backed by `am reservations` / `br dep list` /
  `am inbox-events` respectively. In the current build these three read commands are
  permanent nil-stubs in `FlywheelReadCommands` (unconfirmed JSON shapes — see FOLLOWUPS) and
  `FlywheelWatcher.repollNow()` never calls them, so **do not expect these three lanes to
  ever show the literal text "unavailable"** — the projection's `lanesUnavailable` set is
  computed but not threaded into `ObserveDrawer` (also see FOLLOWUPS). What you should
  actually see is each lane's own "nothing here" copy: "no held or waited-on files", "no
  blocking dependency", "no recent activity". Confirm that's what renders, and confirm
  **Working on** is the one lane with real, changing content.

**Expect:** drawer content follows the focused tab; Working on shows live data; Files/
Dependency/Activity show their empty-state copy (not "unavailable" — see note above).

### 3. Collapse/expand persists per project across relaunch

Collapse the drawer (chevron). Confirm it renders as the compact one-line bar
(`observe-drawer-collapsed`). Quit and relaunch Flight Deck (not `-FlightDeckResetState`).
Reopen the same project/tab and confirm the drawer is still collapsed. Expand it, relaunch
again, confirm it comes back expanded. This is stored in `ProjectSettings.drawerCollapsed`
via `UserDefaults`, keyed per standardized project path — confirm a **different** Flight Control
project's drawer state is independent (collapse one, leave the other expanded).

**Expect:** collapsed/expanded state survives a full app relaunch, independently per
project.

### 4. Open the DAG overlay

With an agent whose **Dependency** lane shows a blocking relationship, click that lane's
text ("blocked on `<holder>` ⤢ open graph" — this is the only way to open the DAG; there is
no separate icon button). Confirm:

- The whole project's graph renders (every bead Flight Deck has polled, not just the
  focused agent's neighborhood).
- The camera opens centered on the focused agent's own bead.
- **Pan** (click-drag) and **zoom** (pinch/magnify, clamped 0.1×–4×) both work smoothly.
- The small corner **minimap** renders a fixed overview of the whole graph and highlights
  the selected node; it is display-only (not clickable).
- Edges stay visually anchored to card edges/centers through pan and zoom — cards and
  arrows are drawn from the same camera transform, so they should never visibly separate.
- If the scratch project's dependency graph has a shared dependency (two beads both
  depending on one earlier bead — a "diamond"), confirm that shared bead renders as **one**
  card, not duplicated. (Layout ranks a multi-path node once, by its deepest reachable rank
  — this is a structural guarantee of the layout, not just something to eyeball, but worth
  a visual sanity check.)

**Note:** because `depEdges` is a nil-stub in the current build (see FOLLOWUPS), the DAG you
see today will only ever contain nodes with **no edges between them** (isolated cards, one
per known bead) — there is no live dependency data to draw arrows from. Testing the diamond
case specifically requires either a future build with `depEdges` wired up, or constructing a
`FlywheelProjection` by hand for this one check. Note which was used when running this step.

**Expect:** whole-graph render, centered camera, working pan/zoom/minimap, edge-to-card
alignment holds under pan/zoom, no duplicate diamond node (if testable).

### 5. Clicking a DAG node

Click a node that is **not** already selected. Confirm it becomes the selected/highlighted
node and the camera recenters on it — **this first click does not jump tabs.** Click the
*same* node again (now already selected). Confirm this second click jumps the focused
Flight Deck tab to that agent's session, if a live tab owns that bead
(`selectObserveSession(forBeadID:)`); if no live tab owns it (an unassigned bead, or an
agent that never booted / already closed), confirm the click is a silent no-op — the DAG
stays open, nothing happens.

There is **no separate "external node" affordance** in the DAG's hit-testing — every node
behaves identically (select-then-jump-on-repeat-click); "external" only means the
second click resolves to no live tab, which the no-op above covers. (This differs from an
earlier framing of this step as "external nodes aren't clickable" — they're clickable, they
just don't jump anywhere.)

**Expect:** first click on a node selects + recenters; second click on the already-selected
node jumps to its tab, or silently no-ops if no tab owns that bead.

### 6. Persistent block notification — dormant in Level 1, not live-verifiable

The block trigger is wired and unit-tested (`FlywheelNotifierTests`) but cannot fire against
live data in Level 1: it needs an agent whose bead has `status == "blocked"`, and the only
live bead read is `br list --status in_progress`, which by definition never returns a
blocked bead. There is no live read path that could ever produce the `.blocked` agent state
this trigger keys on — forcing an agent into `.blocked` in the scratch repo and waiting will
never notify, no matter how long you wait, and that is not a bug to chase. See FOLLOWUPS.

**Skip this step.** There is nothing to verify by hand here — the notifier path is covered
by unit tests, and live verification waits until a future level wires a bead read that can
surface `.blocked` agents.

**Expect:** N/A — not live-verifiable in Level 1 (unit-tested only; see FOLLOWUPS).

### 7. Stalled-holder collision notifies; active-holder collision does not

Force a file reservation with a waiter, where the holder has gone `.stalled` (idle past the
600s default `stallThreshold` while holding a contended file, or the holder's agent row has
disappeared entirely). Confirm a notification fires ("`<holder>` is blocking …").

Separately, force the same waiter/holder shape but keep the holder `.active`. Confirm **no**
notification fires — an actively-worked collision is deliberately silent.

Note: this path is driven by `am reservations`, which is a nil-stub in Flight Deck's own
read pipeline today (see FOLLOWUPS) — this step can only be exercised against a
hand-constructed projection, not the live polling path, until that lane is wired up. Note
which was used when running this step.

**Expect:** stalled/dead-holder collision notifies; active-holder collision stays silent.

### 8. Disable Flight Control

**Not yet testable — there is no disable control anywhere in the app.** Once a project's
`flywheelEnabled` is set `true` (via "Enable Flight Control…"/"Set Up Flight Control…"), the same context
menu item becomes a disabled, non-interactive label ("Flight Control coordination enabled") with
an empty action — it cannot be clicked, and nothing else in the UI flips
`flywheelEnabled` back to `false` or calls `FlywheelObserveService.disable(project:)` (which
exists and is unit-tested, but has no call site). See FOLLOWUPS for this as a known
limitation. Skip this step until a disable control ships; when it does, the check is: drawer
disappears from every tab in that project, and `am`/`br` no longer appear in Activity
Monitor for that project (no live `FlywheelWatcher` polling it).

## Pass criteria (summary)

- [ ] Step 1 — drawer present under an identity tab, absent under a non-identity tab
- [ ] Step 2 — drawer follows focus; Working on is live; other lanes show empty-state copy
- [ ] Step 3 — collapse/expand persists per project across relaunch
- [ ] Step 4 — DAG renders whole graph, centered camera, working pan/zoom/minimap, aligned edges
- [ ] Step 5 — first click selects/recenters, second click jumps or no-ops correctly
- [ ] Step 6 — **N/A today, block trigger dormant in Level 1** (unit-tested only; see `docs/FOLLOWUPS.md`)
- [ ] Step 7 — stalled/dead-holder collision notifies; active-holder collision silent
- [ ] Step 8 — **N/A today, no disable UI exists** (see `docs/FOLLOWUPS.md`)
