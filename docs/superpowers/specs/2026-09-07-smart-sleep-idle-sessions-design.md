# Smart sleep for idle sessions — design

**Goal: an idle Flight Deck session stops consuming battery — its agent process tree is frozen
and its terminal surface is torn down — and wakes losslessly the instant it is touched, resuming
the exact same process with the exact same screen. Nothing is killed; you pick up precisely where
you left off.**

## The problem

A running fleet is dominated, energetically, not by Flight Deck's own code (already power-tuned:
one coalesced `WatchClock` poll with leeway, background throttling, animations that avoid
`TimelineView`) but by the *count* of persistent child processes it keeps alive. Measured on a
live fleet: ~58 `claude` + ~43 `node` processes at ~200% aggregate CPU and ~23 GB RAM, versus the
app itself at ~27% CPU / ~4 GB. Even a `waiting` session that does no visible work keeps a process
resident and periodically waking, which prevents the CPU package from reaching deep idle states —
the thing that actually preserves battery. The lever is therefore: **stop idle sessions from
running at all, without losing them.**

## Why this is possible now: the fd-abduco substrate

This design depends on the detached-session-persistence work
(`2026-09-03-detached-session-persistence-design.md`, branch `worktree-detach-phase1`, Phase 2
complete). That work already solved the hard half of "sleep without loss":

- Each session's agent runs inside a small **`fd-abduco` daemon** in its own session/process group
  (`setsid` via `forkpty`), decoupled from the ghostty surface. The surface is merely an
  attach-client over a Unix socket.
- The daemon holds an **in-memory ring buffer** of the agent's PTY output and **replays it on
  attach**, so a fresh ghostty surface reconstructs the full screen + scrollback natively.
- The agent keeps a **stable pid** for its whole life.

fd-abduco keeps every process fully running — it never addressed energy. Smart sleep is the
additive layer that does, and it reuses fd-abduco's isolation and replay wholesale. **Smart sleep
should land after fd-abduco merges to master, and builds on its `DaemonControlling` seam.**

## A slept session, precisely

Sleep acts on two axes; wake reverses both.

- **Axis A — freeze the process tree.** `kill(-agentPGID, SIGSTOP)` freezes `claude` and its
  `node`/MCP descendants: zero CPU, zero timer wakeups. This is the dominant battery win.
- **Axis B — tear down the terminal surface.** Drop the attach-client (the existing detach path),
  freeing the ghostty Metal renderer and the surface/scrollback RAM.

The daemon itself is **not** stopped: at rest it blocks in `select()` with a NULL timeout
(`vendor/fd-abduco/server.c` mainloop) at ~0% CPU, and must stay live to service the wake attach.
Freezing is transparent to it — a *stopped* (not exited) child does not trigger the daemon's
`waitpid` reaper.

Because `SIGSTOP` freezes process memory intact and `SIGCONT` resumes the identical process, and
because the daemon's ring replay rebuilds the terminal exactly, wake is **lossless by
construction** — the literal meaning of "pick up where you left off, no changes."

## Signaling the right target (and the safety rail)

The `<socket>.pid` sidecar names the **daemon**, not the agent. We must signal the **agent's
process group**, which is distinct:

- The daemon `forkpty`s the agent as a new session leader, so **`agentPGID == agentPID`**, and the
  daemon already signals it as a group (`kill(-server.pid, SIGWINCH)` on resize proves a negative
  pgid reaches the agent tree — including node/MCP children — but not the daemon).
- **Discovering `agentPID`/`agentPGID` (v1): derive it in Swift** from the daemon pid via the
  existing `ProcessInspecting`/`ProcessTree` abstraction. The agent is the daemon's child and its
  own group leader, and `claude`'s `node`/MCP descendants **inherit that same process group** — so
  `getpgid()` of *any* descendant of the daemon yields `agentPGID` (no dependence on there being
  exactly one direct child). No C change, no coordination with the actively-developed wire protocol.
  The daemon-forks-child race exists only at startup; a sleep-eligible session's child is minutes
  old. *(Future hardening: add a `MSG_PID` reply to the fd-abduco protocol for a race-free pid —
  deferred; a new protocol case and its handler must land together.)*
- **Safety rail (non-negotiable):** the freeze/wake signals must reuse the existing `readPID`
  discipline that **rejects a pid ≤ 0 before signaling**. A `kill(-0, SIGSTOP)` broadcasts to
  Flight Deck's *own* process group and would freeze the whole app. Every negative-pgid `kill` is
  guarded on a validated, `> 0`, live pid.

## Eligibility — when a session may sleep

A pure predicate (`SleepPolicy`), evaluated per candidate. A session is eligible iff **all** hold:

1. **Idle status.** `statuses[id]?.activity ∈ {.idle, .waiting}`. Never `.busy` — a busy session has
   a running turn (open API stream / in-flight tool); freezing it would stall the stream to a
   server-side timeout and freeze mid-tool-call.
2. **Not focused.** `id != selectedSessionID`. The visible tab is never slept.
3. **No live background work** (honors "never disturb a session with an attached background
   process"), checked two ways, both must be clear:
   - `!backgroundWorkSessions.contains(id)` — the reported signal, latched from `claude`'s `shell`
     status. (Known to under-report during a turn — hence the second, authoritative check.)
   - `processInspector.descendants(of: agentPID).isEmpty` — the **authoritative** live check: any
     surviving dev server, `Monitor`, or long build under the agent makes it ineligible. **Topology
     note:** under fd-abduco the tab's *recorded* shell (`SurfaceProcessRegistry`) is the thin
     **attach-client**, not the agent — the agent and its background work live under the daemon's
     child in a separate tree. So this check walks `agentPID` (the same pid resolved for signaling),
     **not** the recorded surface shell pid, which would find nothing.
4. **Idle long enough.** In `.idle`/`.waiting` continuously for ≥ `idleThreshold` (default **10
   min**, a preference). Long enough that flipping between a few active tabs never thrashes; short
   enough to reclaim a large idle fleet.
5. **Daemonized and awake.** Has a live daemon and is not already asleep.

## Triggers — entering sleep

The `SessionSleepController` registers on the shared `WatchClock` (same seam as
`SessionStatusWatcher` et al.; inherits 500 ms foreground / 2 s background cadence and weak
auto-pruning). Each beat it evaluates candidates through `SleepPolicy` and sleeps the newly
eligible: **tear down the surface, then `kill(-agentPGID, SIGSTOP)`.** No new timer.

## Waking

Wake = **`SIGCONT` the agent group, then (re)attach a fresh surface** that replays the ring. There
is no single chokepoint for both input paths, because local keystrokes never enter Swift — so two
seams both funnel into `controller.wake(id)`:

- **Local — selection.** `TerminalPane.updateNSView` already attaches the surface for
  `selectedSessionID` and detaches the rest. When the selected id is asleep, wake it *before*
  building/attaching its surface.
- **Remote / programmatic — `injector(for:)`** (the funnel for phone prompts, dialog answers,
  restore, `/login`, `/rename`, and self-scheduled loop/cron injections). A slept session has
  `surfaces[id] == nil`, which would trip the existing `notRunning` guard; the wake hook must
  re-materialize the surface here first, then return the fresh injector.

**Unifying invariant: attach ⇒ ensure running.** The attach/rebuild helper always `SIGCONT`s first.
This makes wake, and app-restart reconcile, one path: on relaunch the user's selected session is
attached (→ CONT), while unopened slept agents stay frozen and cheap until touched.

## Components

**New:**
- `SleepPolicy` — pure. `evaluate(candidate) -> Decision` over `(status, selectedID,
  backgroundWorkSessions, liveDescendants, idleSince, now, threshold)`. Fully unit-testable, no
  sockets, no ghostty. Mirrors the pure/effect split of `LaunchPlan`/`DaemonProbing`.
- `SessionSleepController` — effectful. Owns the `WatchClock` subscription, per-session
  `idleSince` bookkeeping, and drives surface teardown + `DaemonControlling` signals. Exposes
  `wake(id)` for both seams.

**Touched:**
- `DaemonControlling` (+`PosixDaemonControl`) — add `stop(_:)` / `cont(_:)` (resolve agent pgid,
  reuse the `> 0` guard, `kill(-pgid, …)`).
- `SessionStore` — factor the two `config.command = daemon.attachCommand(...)` build sites into one
  `makeAttachSurface(id:)` helper shared by relaunch and wake; own the controller; expose
  `idleSince`/selection to it.
- `injector(for:)` and `TerminalPane.updateNSView` — the two wake hooks.
- `closeSession` / `terminate` — **`SIGCONT` a stopped agent before `SIGTERM`**, or closing a
  sleeping tab hangs (a stopped process can't process the term).

## Error handling & edge cases

- **kill(-0) rail** — covered above; the single most dangerous failure, gated at the source.
- **pid recycle** — the `ProcessIdentity` (pid + start-time) recycle guard from the reaper design
  applies before any signal; never signal a recycled pid.
- **Close while asleep** — CONT-before-TERM in teardown.
- **Daemon died while agent stopped** — probe reports not-live → treat as a dead session (cold
  resume path), exactly as detach already handles a dead daemon.
- **Self-scheduled loops / cron / `ScheduleWakeup`** — a session actively looping keeps re-entering
  `.busy` (or reports background work) and never accumulates `idleThreshold`, so it is not slept;
  when its scheduled injection arrives it comes through `injector(for:)` → wakes. A loop frozen
  exactly at its fire instant is delayed until the next wake trigger — acceptable, and documented.
- **Status frozen at sleep** — a stopped agent stops rewriting `<pid>.json`; the watcher keeps its
  last value and `kill(pid,0)` still reports alive, so the row neither vanishes nor goes stale-wrong
  (it *is* idle). No notification is produced or lost (next section).

## Notifications invariant

`SessionNotificationPolicy` is edge-triggered into `wantsYou` (`.waiting || planGate`) and only
notifies when the app is inactive. A session becomes sleep-eligible only *after* it is already
`.waiting`/`.idle` — i.e. after the entering-`waiting` edge already fired. A frozen process emits no
further status writes, hence no new `StatusTransition`, hence nothing to notify or withdraw.
**Sleeping a waiting session loses no notification.** (Plan-gate notifications come from a separate
path driven by the same clock; a frozen process opens no new gate either.)

## Render gating (secondary, measure-first — the standalone ask)

For *slept* sessions the surface is gone, so rendering cost is already zero; and `TerminalPane`
already **detaches non-selected surfaces** while their shells run off-screen. The residual target is
therefore narrow: a *foreground* surface still rendering while **the whole Flight Deck window is
occluded** by another app.

Handle it exactly as specified: **measure first.** Instrument the tab-switch / attach path.
- If gating rendering on `NSWindowOcclusionState` (and confirming non-foreground tabs are truly not
  rendering) costs **< 300 ms** on switch → ship unconditionally.
- If it costs **≥ 300 ms** → apply it only to surfaces whose session has been idle **> 1 hour**, so
  the latency is never paid on an active tab.

This is a self-contained follow-on, not on the critical path of the sleep subsystem.

## Testing

- **`SleepPolicy` (pure):** the eligibility matrix — busy never sleeps; selected never sleeps; each
  background-work signal independently blocks; threshold boundary; already-asleep is a no-op.
- **`DaemonControl` (signals):** `stop`/`cont` resolve the agent pgid (not the daemon), signal the
  negative pgid, and **refuse a pid ≤ 0** (the app-freeze rail) — asserted against a test double and
  a live daemon harness (fork a stub child, assert `SIGSTOP` state via `kill(pid,0)`/`ps` state, then
  `SIGCONT`).
- **Wake seams:** slept session + selection → surface rebuilt and agent running; slept session +
  `submitPrompt`/phone → woken before the `notRunning` guard; CONT-before-TERM on close.
- **End-to-end (`TerminalSmokeTests`):** produce output, let a session sleep, assert zero agent CPU
  while stopped, then wake and assert the pane shows prior scrollback and the *same* live pid.

## Phasing

1. **Signals:** `DaemonControlling.stop/cont` + agent-pgid resolution + the `> 0` rail; unit tests.
2. **Controller + policy:** `SleepPolicy`, `SessionSleepController`, `WatchClock` registration,
   `idleSince` tracking, surface teardown on sleep. Sleep works; wake still manual.
3. **Wake wiring:** `makeAttachSurface` helper; the selection and `injector(for:)` hooks;
   CONT-before-TERM in close; the attach⇒CONT reconcile.
4. **End-to-end smoke test** + the `idleThreshold` preference.
5. **Render gating** (measure-first, per above) — independent, can proceed in parallel.

## Non-goals (for now)

- **Surviving a Mac reboot.** Inherited from detach's non-goals; a reboot loses the daemons.
- **Selectively freezing only the agent while a background process keeps serving** (the "sleep
  agent, keep bg alive" option). v1 simply doesn't sleep sessions with live background work.
- **`MSG_PID` protocol change.** v1 derives the agent pid in Swift; the wire change is deferred.
- **Sleeping the focused session or a busy session.** Out of scope by eligibility.

## Risks

- **Signaling the wrong target** — mitigated by the `> 0` rail + pgid-not-daemon resolution + recycle
  guard; the highest-severity risk, gated in one place with a direct test.
- **Wake latency perceptible** — `SIGCONT` is instant; the only cost is ring replay, bounded to
  scrollback. Target < 300 ms; asserted in the smoke test.
- **A frozen agent holds RAM indefinitely if never reopened** — same shape as detach's persistent
  daemons; the orphan reaper handles sessions removed from `sessions.json`. Acceptable.
- **Coordination with the live detach branch** — build on it after merge; v1 deliberately avoids
  touching the fd-abduco C/protocol to keep the surfaces independent.
