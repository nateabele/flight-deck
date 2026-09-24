# Spec — Flywheel Observe (Level 1)

## Context

Flight Deck (FD) is being extended, over several increments, into a visual control
center for **agent-flywheel** swarms. **Level 0** (`2026-09-18-flywheel-run-integration-design.md`,
now merged) made an FD-spawned agent a first-class participant in a project's shared
beads + Agent-Mail substrate: a per-project `flywheelEnabled` flag, a stable
`FlywheelIdentity { agentName, project }` booted via `am macros start-session`,
`AGENT_NAME` injected into the PTY env, and the pre-commit reservation guard enforcing.

Level 0 shipped **no UI**. This spec is **Level 1 "Observe"**: a **read-only**
observation layer that surfaces what flywheel agents are doing — their bead, the files
they hold and wait on, why they are blocked, and how their work depends on the rest of
the project — so a human can *supervise* a swarm without tailing terminals. The framing
that survived brainstorming: **a control tower, not a dashboard.** You watch until
something needs you, and you are told when it does.

Everything here is observation. **No authoring or dispatch** — no claiming beads,
sending Agent-Mail, or nudging agents *over the wire*. That is Level 2.

### Foundations this builds on (all verified present post-merge)

- `Session.flywheelIdentity: FlywheelIdentity?` — the join key tying an FD tab to a
  live `am`/`br` agent row (`agentName`).
- `FlywheelProcessRunner` protocol + `SystemFlywheelProcessRunner` — the
  `Process`+`Pipe` shell-out seam (read-before-wait, cancellation-bounded). Level 0 uses
  it to *write* (`start-session`); Observe reuses the **same seam to read**
  (`am … --json`, `br … --json`).
- `RootView` is `NavigationSplitView { SessionSidebar } detail: { TerminalPane }`. The
  Observe drawer lives **in the detail column, under `TerminalPane`** — the sidebar
  stays full-height and is never overlapped.

### Decisions locked (from brainstorming)

- **Intent = live supervision** (control tower). **Vantage = a per-project panel that
  follows the focused tab** — a single-agent lens, not a roster (the sidebar is already
  the roster; `Shift+Cmd+[`/`]` already navigates it).
- **Attention model = passive panel + macOS notification. No header badge.** The panel
  is ambient; the notification is the only thing that reaches for you, and only when a
  human is actually needed.
- **Panel = a bottom drawer** in the detail column, under the terminal, collapsible to a
  one-line status bar. Four lanes: **Working on · Files · Dependency · Activity.**
- **Dependency detail = a real node-link DAG**, opened as an overlay from the drawer's
  Dependency lane — **not** an indented tree (a tree duplicates shared nodes; the whole
  point is to show the diamond once).
- **The DAG shows the whole project graph, always**, with the **camera zoomed and
  centered on the selected card** (focus+context) — pan/zoom + a minimap to roam.
- **Transport = watch-then-repoll:** FSEvents on each enabled project's `.beads/` (and
  the Agent-Mail store) triggers a cheap `--json` re-poll — never an interval timer.
- **Notify fleet-wide, render focused.** Cheap headless watchers cover *every* enabled
  project so notifications fire for projects you are not looking at; the rich drawer/DAG
  renders only the focused project.

## Goal & success criteria

While supervising a flywheel project in FD:

1. The drawer under the focused tab shows, live, that agent's **current bead**, the
   **files it holds and is waiting on** (with who holds a contended file and for how
   long), its **immediate dependency edge**, and a short **activity feed** of substrate
   events — all derived from `am`/`br`, joined to the tab via `flywheelIdentity`.
2. Opening the **Dependency overlay** shows the **whole project DAG**, camera centered
   on the focused agent's bead, fusing **issue dependencies** (`br dep`) and
   **file-reservation contention** (`am`) as two visually distinct edge types, and
   surfacing a **root-cause node** — the deepest *stalled-not-blocked* agent on the
   critical path.
3. When an agent becomes **persistently blocked**, or a **reservation collision requires
   a human** (the blocker is stalled/dead, or there is a dependency deadlock cycle), a
   **macOS notification** fires — for *any* enabled project, not just the focused one.
4. **Clicking any node** in the DAG (or the drawer's root-cause line) **jumps to that
   agent's FD tab** — read-only navigation, the Level-1 form of "act on it."
5. **Flag off ⇒ zero cost and zero UI.** A non-flywheel project shows no drawer, starts
   no watcher, and runs no `am`/`br` probe.

## Non-goals (this increment)

- **No authoring/dispatch.** No claiming/creating beads, no sending Agent-Mail, no
  reservation release, no message-send "Nudge." (See *Resolved ambiguity: Nudge* — in
  Level 1, "Nudge" is jump-to-tab navigation only.)
- **No convergence gauge / Encode** (Level 2); no operate actions (Level 3).
- **No editing** of beads/reservations/graph — strictly read.
- **No cross-machine / fleet-to-phone** surfacing of Observe (the iOS companion is
  untouched; `Sources/FlightDeckMobile` not built here).
- **No persisted history** of substrate events beyond the in-memory activity feed and
  the notification the OS keeps — Observe reflects live state, it is not a log store.
- **No new spawn-path behavior.** Observe only *reads*; it never changes how agents boot
  or what env they get.

## Architecture overview

A new `Sources/FlightDeck/Flywheel/Observe/` group: pure-ish read/model/notify services
behind protocols, plus SwiftUI views for the drawer and DAG overlay, mounted in the
detail column. A per-project **watcher** drives everything; a per-project **projection**
is the observable model the views render; a fleet-wide **notifier** consumes the same
projections.

```
                 (enabled project P)
 FSEvents on P/.beads + P/.agent-mail ─▶ FlywheelWatcher(P)  ── coalesced ─▶ repoll
                                                                              │
   SystemFlywheelProcessRunner ◀── am/br --json (fast paths only) ◀───────────┘
                                                                              │
                                                 FlywheelProjection(P)  ◀──────┘
                                                  (agents, beads, reservations,
                                                   dep edges, stall clocks)
                                        ┌────────────────────────┴───────────────┐
                        focused-project projection                    all-project projections
                                        │                                         │
                            join to Session.flywheelIdentity          FlywheelNotifier
                                        │                             (block / collision → macOS)
                          ObserveDrawer (4 lanes) ── Dependency lane ⤢ ── DependencyDAGOverlay
                                                                          (whole graph,
                                                                           camera on selection)
```

`FlywheelObserveService` (one, `@MainActor`, owned by `SessionStore`) owns the set of
per-project watchers/projections keyed by standardized project path, starts/stops them
as projects are enabled/added/removed, and vends the focused projection to the views and
all projections to the notifier.

## Components

### 1. `FlywheelWatcher` — watch-then-repoll, per project

Given an enabled project's absolute path, watches `<repo>/.beads/` and the Agent-Mail
store with a macOS `FSEventStream` (via a small `DispatchSource`/`FSEvents` wrapper),
**coalesces** bursts (a short debounce, ~150–250ms) into a single re-poll, and re-polls
on change plus once at start. **No polling timer.** Emits a raw substrate snapshot.

**Transport landmines (from the integration spike — must be honored):**
- **Never touch the `am` HTTP daemon cold path** (~2.5s probing a dead
  `127.0.0.1:8765`). Use only fast local-DB paths: the `am` reservations family and
  `am agents list <repo> --json`; for inbox activity, `am inbox-events --after <cursor>`
  with a persisted cursor.
- **`am` is one global SQLite keyed by project.** Every read passes the **standardized
  absolute project path** as the `--project` human_key (matching
  `PreferencesStore.key(_:)`), or it reads another project's rows.
- Beads: `br list --status in_progress --json`, `br ready --json`, `br blocked --json`,
  and `br dep`/`br graph --json` for edges. All are sub-200ms local reads.

> **Command-shape caveat (carried into the plan):** the *proven* shapes are
> `am agents list <repo> --json` → bare `[{name…}]` and `br list --status in_progress
> --json` → `{issues:[{assignee…}]}`. The others (`br ready/blocked/dep/graph`,
> `am inbox-events --after`, reservations `--json`) are **documented-intent** and MUST be
> probed against the installed `am`/`br` before the parser is written — each decoder
> tolerates a missing/renamed command by degrading that lane, never crashing (see Error
> handling). This is a hard first task in the plan, not an assumption.

### 2. `FlywheelProjection` — the observable model

A value-typed reduction of a watcher snapshot into what the UI needs, computed off the
main actor and published on it:
- `agents: [ObservedAgent]` — `{ name, bead?, status, holds:[File], waitsOn:[File],
  lastEventAt, stalledSince? }`.
- `reservations: [Reservation]` — `{ file, holder, since, waiters:[name] }`.
- `depEdges: [DepEdge]` — `{ from: bead, to: bead, kind: .dependency | .reservation }`
  (the two fused edge types), plus per-bead `{ assignee, status }`.
- `stallClocks` — per agent, "no substrate event for ≥ T" (drives stalled-not-blocked).

**Stall detection is an input, not an output.** "Stalled" = an agent that holds a
contended resource (or sits on the critical path) and has produced no substrate event
for ≥ a threshold, while **not** itself `blocked`. It feeds both the DAG root-cause pick
and the collision-notify gate.

### 3. `ObserveDrawer` — the per-tab lens (SwiftUI)

Mounted in `RootView`'s detail column, **below `TerminalPane`**, in a `VStack` so the
terminal gives height back when the drawer collapses. Follows the focused tab: reads
`store.selectedSessionID → Session.flywheelIdentity.agentName`, finds that agent in the
focused project's projection.

- **Expanded:** a one-line status header (agent name, live dot, big status —
  e.g. `⛔ BLOCKED · 6m`) + four lanes:
  - **Working on** — current bead id + title + `in_progress` age.
  - **Files** — `✓` held / `◔` waiting; for a contended wait, "held by X · idle 22m"
    and a **Nudge** affordance (= *jump to X's tab*; see Resolved ambiguity).
  - **Dependency** — the immediate edge (`bd-142 → bd-118`, "waits on X (stalled?)"),
    with a **⤢** control that opens the DAG overlay.
  - **Activity** — the last few substrate events (reservation denied/granted, bead
    claimed, session start), newest first.
- **Collapsed:** a single status bar (name · status · "wants Auth.swift · held by X" ·
  Nudge · ▸) that reclaims height for the terminal.
- **Empty/degraded states:** focused tab has no `flywheelIdentity` (non-flywheel or
  pre-boot) ⇒ drawer absent; projection lane unavailable (command missing) ⇒ that lane
  shows a quiet "unavailable," others still render.

Toggle + collapse state persist per project (small addition to `ProjectSettings`, using
the Optional + `decodeIfPresent` idiom so old JSON decodes).

### 4. `DependencyDAGOverlay` — whole graph, camera on selection (SwiftUI `Canvas`)

Opened from the drawer's Dependency lane. **The whole project DAG is the scene**; the
node set does not change with selection — the **camera** does.

- **Layout** (computed once per graph-version, cached, **stable across re-polls** so it
  never jumps): layered — rank = dependency depth — with within-rank crossing reduction;
  a **shared node appears once** (the diamond). Coordinates are keyed by graph
  content-hash so a re-poll that doesn't change edges reuses the exact layout; re-polls
  move dot colors/labels, never geometry.
- **Camera:** selecting a tab (or clicking a node) animates an affine transform to
  **center + zoom** that bead; drag to pan, scroll/± to zoom, **⤢ fit-all** frames the
  whole graph, and a **minimap** (downscaled same layout + viewport rect) shows where
  you are.
- **Two fused edge types:** solid = issue dependency (`br dep`); dashed = file-
  reservation contention (`am`). Critical path highlighted.
- **Root-cause pick:** the **deepest node on the critical path that is stalled, not
  blocked** — the one a human can actually unstick. Badged, with the same jump-to-tab
  Nudge inline.
- **Interaction:** click node → **jump to that agent's FD tab** (mark external if it has
  no tab); hover → full title/timestamps.
- **Data:** `br graph`/`br dep --json` for edges + per-bead assignee/status, **joined to
  agents via `flywheelIdentity.agentName`**; `am` reservations overlay the dashed edges.

Rendering is `Canvas` (nodes + edges + minimap drawn from the one cached layout, so
edges and cards share a coordinate space and cannot desync — the failure the mockups
hit). Hit-testing maps canvas points back through the camera transform.

### 5. `FlywheelNotifier` — fleet-wide, human-needed only

Consumes **every** enabled project's projection (the watchers run fleet-wide even though
only the focused project is rendered). Fires a macOS `UNUserNotification` on exactly two
triggers, each gated to avoid transient noise:

- **Agent persistently blocked** — an agent enters `blocked` and stays blocked past a
  short persistence threshold (a brief block that clears on its own never notifies).
- **Reservation collision that requires a human** — a contended reservation where the
  **holder is stalled/dead**, or a **dependency deadlock cycle** exists. A plain
  collision where the holder is actively working is *not* notified (it will resolve
  itself); stall-detection (§2) is the gate.

Notifications are **coalesced per agent/cause** (no repeat-spam for the same standing
condition) and **click-through to the relevant tab/project**. Requesting notification
authorization happens once, lazily, when the first project is enabled — never at launch.

### 6. `FlywheelObserveService` — lifecycle owner

One `@MainActor` service held by `SessionStore`. Maintains `[projectKey:
(watcher, projection)]`. Starts a watcher when a project is enabled (or an
already-enabled project is added) and stops/tears it down when disabled/removed or when
the app enters the background under the existing occlusion/sleep gating (reuse the
smart-sleep hooks so Observe doesn't burn battery watching idle projects). Vends the
focused projection to the drawer/DAG and all projections to the notifier. **Constructed
lazily** — a fleet with no enabled projects builds nothing.

## Data flow

**Focused rendering:** focus a tab → `flywheelIdentity.agentName` + its project key →
`FlywheelObserveService` returns that project's `FlywheelProjection` → drawer renders the
agent's lanes; ⤢ opens the DAG centered on the agent's bead.

**Watch → repoll → project:** substrate file change → `FlywheelWatcher` debounce →
fast-path `am`/`br --json` reads (project-scoped) → snapshot → `FlywheelProjection`
recompute (off-main) → publish (main) → SwiftUI diffs the drawer/DAG.

**Notify (fleet-wide):** each project's projection recompute → `FlywheelNotifier`
evaluates block-persistence + human-needed-collision → fires/coalesces a macOS
notification → click routes to that project/tab.

## Error handling & degradation

- **Missing/renamed `am`/`br` subcommand:** the first plan task probes the installed
  CLIs; each lane's decoder degrades that lane to "unavailable" and logs once — never
  crashes, never blocks other lanes. A projection with, say, no `depEdges` still renders
  Working-on/Files/Activity; the DAG shows what edges it has.
- **`am` cold-path / slow read:** reads are fast-path only and run off-main with the
  cancellation-bounded runner; a read that exceeds a short deadline is abandoned and the
  lane keeps its last value with a subtle "stale" hint rather than freezing the UI.
- **Project-key mismatch:** always the standardized absolute path; a read that can't be
  scoped is skipped, not run unscoped (which would surface another project's rows).
- **Watcher failure** (FSEvents unavailable): fall back to a **single** lazy re-poll on
  focus/expand — degraded but not a busy timer.
- **Flag off / non-flywheel:** no watcher, no probe, no drawer, no notifier entry —
  byte-for-byte the current app.
- **Join miss:** an `am`/`br` agent with no matching FD tab renders as **external**
  (shown, not clickable-to-tab) — expected for agents started outside FD.

## Testing

**Unit (`./scripts/test-unit.sh`, macOS — runs the full suite, ~8 min; it ignores
`-only-testing:`, budget for it):**
- **Projection reduction:** fixture `am`/`br --json` blobs → expected
  `ObservedAgent`/`Reservation`/`DepEdge`; the join to `flywheelIdentity`; external-agent
  case; stalled-not-blocked derivation from event clocks.
- **Decoder tolerance:** a missing/renamed subcommand degrades one lane, others intact
  (asserts no throw, lane = unavailable).
- **DAG layout:** layered ranks from a fixture graph; the **diamond** (shared node once);
  **coordinate stability** — same graph content-hash ⇒ identical coordinates across two
  reductions; root-cause pick = deepest stalled-not-blocked on the critical path.
- **Camera math:** center/zoom transform for a selected node; hit-testing round-trips a
  canvas point back to the node under the current transform.
- **Notifier gates:** transient block ⇒ no notification; block past threshold ⇒ one;
  collision with active holder ⇒ none; collision with stalled holder / deadlock cycle ⇒
  one; per-cause coalescing (no duplicate for a standing condition).
- **Watcher coalescing:** a burst of change events ⇒ one debounced re-poll (fake clock +
  fake runner asserting call count).
- **Flag-off negative:** disabled project ⇒ service builds no watcher, issues zero
  `am`/`br` reads (fake runner asserts zero argv).

**GUI (the maintainer-run, per AGENTS.md rule 2 — agents can't drive the real app):** a checklist
doc — enable two agents in a scratch flywheel repo, confirm the drawer follows the
focused tab, the DAG centers on selection and pans/zooms with an aligned graph, a
persistent block raises a notification whose click lands on the right tab, and a stalled
holder collision notifies while an active one doesn't. (This is the same class of
manual-verification gap as multi-agent search; scripted where possible, the GUI e2e is
The maintainer's.)

## Risks & follow-ups

- **`am`/`br` read-command reality** is the top risk: several shapes are documented-
  intent. Mitigation: the probe-first task + per-lane degradation. If a needed command is
  absent, that lane ships "unavailable" and the gap is a noted follow-up, not a blocker.
- **DAG scale:** a very large project graph could stress layout/render. Mitigation:
  layout is cached per graph-version and the camera is a cheap transform; if a real graph
  is pathologically large, a node cap with "N more" collapse is a follow-up (the whole-
  graph default is what the maintainer asked for and is correct for realistic swarm sizes).
- **Fleet-wide watchers cost:** N enabled projects = N FSEvents watchers + debounced
  reads. Cheap by design (no timers, fast-path reads, occlusion/sleep gating), but worth
  watching; a cap or coalescing across projects is a follow-up if N grows large.
- **Notifier tuning:** the persistence/stall thresholds are guesses; expose them as
  constants first, make them preferences only if they prove fiddly.
- **Reservation TTL churn** (Level-0 follow-up) can make a held file flicker; the
  projection should treat a lease refresh as continuity, not a release+reacquire event.

## Resolved ambiguity: "Nudge"

The mockups show a **Nudge** control on the stalled/holder agent. Sending a message to
an agent is **authoring — Level 2**. For **Level 1, "Nudge" = jump to that agent's FD
tab** (read-only navigation), so the supervisor intervenes by hand at the terminal. The
message-send form is explicitly deferred. This keeps Observe strictly read-only while
the affordance still does something useful. *(Flagged here so it can be corrected at
review if the intent was the message-send form — that would pull a slice of Level 2
forward.)*

## Files touched (representative)

- `Sources/FlightDeck/Flywheel/Observe/FlywheelWatcher.swift` *(new)*
- `Sources/FlightDeck/Flywheel/Observe/FlywheelProjection.swift` *(new)* — model +
  reduction from `am`/`br --json`
- `Sources/FlightDeck/Flywheel/Observe/FlywheelObserveService.swift` *(new)* — lifecycle,
  `@MainActor`, owned by `SessionStore`
- `Sources/FlightDeck/Flywheel/Observe/FlywheelNotifier.swift` *(new)*
- `Sources/FlightDeck/Flywheel/Observe/DependencyGraphLayout.swift` *(new)* — layered
  layout + stable coords + root-cause
- `Sources/FlightDeck/Flywheel/Observe/ObserveDrawer.swift` *(new, SwiftUI)*
- `Sources/FlightDeck/Flywheel/Observe/DependencyDAGOverlay.swift` *(new, SwiftUI Canvas
  + camera + minimap)*
- `Sources/FlightDeck/Flywheel/FlywheelReadCommands.swift` *(new)* — the probed, tolerant
  `am`/`br` read wrappers over the existing `FlywheelProcessRunner`
- `Sources/FlightDeck/RootView.swift` — mount `ObserveDrawer` under `TerminalPane` in the
  detail column
- `Sources/FlightDeck/SessionStore.swift` — own `FlywheelObserveService`; start/stop
  watchers on enable/add/remove; expose focused projection; wire occlusion/sleep gating
- `Sources/FlightDeck/Preferences/ProjectSettings.swift` — drawer visible/collapsed
  state (Optional + `decodeIfPresent`)
- `docs/FLYWHEEL-OBSERVE-CHECKLIST.md` *(new)* — the the maintainer-run GUI verification runbook
- Tests under `Tests/FlightDeckTests/Flywheel/Observe*`
