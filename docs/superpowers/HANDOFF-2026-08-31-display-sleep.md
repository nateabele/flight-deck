# Handoff — sessions that cannot start while the Mac's display is asleep

## The problem, in one line

Creating a session from the phone fails whenever the Mac's display is asleep — which is
precisely when you are away from the Mac and want the phone. **What shipped today refuses
instead of failing silently. That is not a fix.**

## Root cause (confirmed, not inferred)

libghostty needs a **drawable** to back a surface. With the display asleep it still returns a
`Ghostty.SurfaceView` — the init is non-failable — but never forks the shell. So no `login`, no
`claude`, no status file, no `activity`, and `SurfaceProcessRegistry` records nothing.

Established by controlled trial: display slept with `pmset displaysleepnow`, condition verified
held, tab created from the phone with the Mac untouched.

| Display | Outcome | n |
|---|---|---|
| asleep | no shell forked, tab inert from birth | 3 |
| awake | healthy | 3 — one at `locked=1`, isolating display from lock |

CoreGraphics states it: `CGDisplayIsAsleep` is true when the display is asleep *"and is
therefore not drawable"*; `CGDisplayIsActive` means *"available for drawing"*.

**Screen lock is a confounder, not the cause.** A tab created 19s after lock with the display
still on was healthy. Two earlier diagnoses were wrong and are recorded in the spec so they are
not repeated: "`makeSurface` returned nil" (it cannot — non-optional, non-failable init) and
"the screen was locked".

## What is live in `/Applications` right now

Merged to master as `63d2268`, swapped in at 09:12 on 2026-08-31 (backup
`~/Library/Application Support/Flight Deck/backups/20260831-091211/`). **The wake described
under B below is implemented on branch `display-wake` and has NOT been swapped in** — the
build in `/Applications` still only refuses; it does not yet wake.

- `DisplayInspecting` / `DisplayState` — `CGDisplayIsActive(CGMainDisplayID()) != 0`. Defaults
  to a permissive `AlwaysDrawableDisplay()`; the real probe is injected in
  `SessionStore.convenience init(ghostty:…)`. **That injection is load-bearing** — delete it and
  the guard silently stops firing. `testTheRealProbeIsWiredIn` is the detector.
- `canCreateTerminal` = `provider == nil || display.isDrawable`. The provider clause is
  deliberate: without it a suite run started with the display asleep refuses every fixture's
  `newSession` and **deadlocks** (`GatedAdapter.waitUntilPreparing()` never fires).
- Creation refused at all four paths: `newSession(in:)`, `createSession`, `openSignInSession`,
  and the phone's `.newSession` (which answers `terminal_unavailable`).
- `hasShellProcess(for:)` + `respawnSurface(for:)` + a sidebar **Restart Terminal** item, shown
  only when the registry entry is empty. **Keyed on `SurfaceProcessRegistry`, never on
  `surfaces[id]`** — the latter is non-nil even for an inert tab, which is why two earlier
  attempts at this were dead code.

1962 unit tests, iOS build green. A cold launch 35s into real display sleep refused to seed and
forked nothing.

## Direction: spike C, fall back to B

### C — decouple the agent from the surface. **SPIKE DONE: BLOCKED at the API boundary.**

The idea: spawn `claude` on our own PTY, independent of any Ghostty surface, and attach a
surface later when a display exists. An agent should not need a *drawable* to run.

**It cannot be done through the public C API.** `ghostty_surface_config_s`
(`vendor/ghostty-artifacts/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h:444-453`) is
exactly:

```c
double scale_factor; float font_size; const char* working_directory;
const char* command; ghostty_env_var_s* env_vars; size_t env_var_count;
const char* initial_input; bool wait_after_command; ghostty_surface_context_e context;
```

No fd, no pty, no attach. Searching the whole header for `fd|pty|spawn|attach|inherit` returns
only `ghostty_surface_inherited_config`, which inherits *configuration*, not a process.
**libghostty owns the fork and exposes no way to hand it an existing PTY.**

Remaining routes, all expensive — do not start one without deciding it is worth it:
1. Patch the vendored libghostty to accept an fd. `AGENTS.md` says prefer re-pulling upstream to
   hand-editing `GhosttyEmbed/`, so this incurs permanent merge cost.
2. Upstream feature request. Right answer long-term, no help now.
3. Run the agent outside Ghostty and render it ourselves. The terminal *is* the product; this is
   a rewrite, not a fix.

**Recommendation: C is not viable on this timescale. Proceed to B.**

### B — wake the display just long enough to fork. **SPIKE DONE: ALL THREE TESTS ANSWERED, AFFIRMATIVELY. IMPLEMENTED.**

`IOPMAssertionDeclareUserActivity(… kIOPMUserActiveLocal …)` around surface creation. Measured
on 2026-08-31 on this machine, `pmset displaysleepnow` with the slept condition verified held
before each of four trials:

1. **Does the wake complete before `ghostty_surface_new` runs?** No, not immediately — it is
   asynchronous, confirming the spike's own caution. A naive declare-then-create would still find
   no drawable. The implementation polls for a drawable after declaring rather than firing and
   proceeding.
2. **Does `CGDisplayIsActive` go true, and how long does it take?** Yes — **0.173 / 0.194 / 0.295
   / 0.342 s** across four trials. Once active, the display stayed active for the ≥3s the trials
   checked, so one declaration is enough; nothing needs to be held or released around the whole
   creation path.
3. **Does it work while the screen is LOCKED? This was the crux.** Yes. The Mac auto-locks
   within ~5s of display sleep, so all four measurements above were already taken with the
   screen locked (`locked=1`) — there was never an unlocked baseline to isolate, because by the
   time the assertion could be measured, the phone's real-world case (locked) was already the
   only case there was.

**Sufficiency confirmed, n=1.** With the display woken from a locked, slept state, a session
created from the phone forked a complete, healthy tab: `Flight Deck → /usr/bin/login → zsh →
claude`, with the session id matching `sessions.json`. Not an inert tab. This is a single
observation, not a distribution — repeat before trusting it as a rate rather than a
demonstration.

**What is implemented:** a `DisplayWaking` protocol / `DisplayWaker` collaborator; an
`ensureTerminalCreatable(_:)` funnel in `SessionStore` that all four creation guard sites now
call through; the real waker injected in `convenience init(ghostty:)`. `seedInitialSession`
deliberately opts out with `.never` — it runs inline inside `SessionStore.init`, so waking there
would light the screen on an unattended relaunch and would block startup on the poll.

**The guard-site inventory is five, not four.** The spec (`docs/superpowers/specs/
2026-08-31-display-wake-design.md`) enumerated only the four inside `SessionStore` —
`newSession(in:)`, `createSession(agent:in:)`, `openSignInSession(for:in:using:)`,
`respawnSurface(for:)` — and missed `FleetService`'s `.newSession` wire handler, which read
`store.canCreateTerminal` directly rather than going through the funnel. That is the phone's
only creation command, so the miss closed the whole path this feature exists for: with the
display asleep, the phone was refused before `ensureTerminalCreatable` was ever reached, on
every phone-originated creation. Caught in a whole-branch review, fixed by routing that guard
through `ensureTerminalCreatable()` too. **`rg -n 'canCreateTerminal' Sources/` is the check**
that finds every direct reader of the pure query in seconds — run it before any future change
to this guard, so a sixth site cannot go missing the same way.

**The guard is NOT removed.** A wake can still fail — clamshell mode, no display attached — and
must still refuse rather than birth an inert tab. B makes refusal the exception instead of the
routine outcome; it does not make refusal impossible.

**Still out of scope, and still true:** `restore()` and `reopenClosedSession()` remain unguarded
and non-waking (see Loose ends below) — a relaunch with the display asleep can still bring back
a deck of inert tabs, `respawnSurface` remains the only remedy, and auto-respawn on display wake
still does not exist.

**Verified end-to-end against the shipped app, 2026-09-01 09:31.** A Release build was swapped
into `/Applications`, the display slept and the Mac auto-locked (`active=false asleep=true
locked=true`, confirmed held), and a `+` tap on the phone produced:

```
89959  Flight Deck            <- the post-swap pid
 └─ 17649  /usr/bin/login
     └─ 17650  fish
         └─ 17712  claude --session-id f15601e3-...-8486d79d4029
```

with the session id matching the new `sessions.json` entry and the display reading
`active=true locked=true` at the moment of creation. **Per-tab evidence — a new pid parented to
the post-swap app and tied to the new session id — never a net shell count.**

This also retires the one risk the code review could not: that `CGDisplayIsActive` might be
served from a per-process value refreshed on the main run loop, which a poll running with the
main thread blocked would never observe. It observes it. The spike harness polled from a
separate process; the shipped app polls from the blocked main actor, and both see the flip.

**Follow-up, done: the phone's guard is now async.** `FleetService`'s `.newSession` handler used
to block the caller's thread for up to 1.5s inside `ensureTerminalCreatable()` before either
creation branch ran. `FleetSocketServer.onCommand` gained the same deferred-`reply` shape
`onRequest` already had — `reply` is a closure passed in rather than a return value, callable
after an `await` — and `FleetService.onCommand` uses it: when the command is `.newSession`, the
named project still exists, and `canCreateTerminal` is already false, it awaits
`store.awaitTerminalCreatable()` inside a `Task` and replies from there instead of blocking the
frame-handling thread for the wake. The project check runs first and gates the whole thing: a
stale phone naming a project the Mac no longer has still gets `unknown_project` synchronously,
on the way out of the frame handler, and never wakes the screen or asks the waker anything for a
command that was going to be refused regardless. Every other command, and every `.newSession`
against an already-awake Mac, still answers exactly as before — synchronously, on the way out.
`awaitTerminalCreatable` is `ensureTerminalCreatable`'s async twin: identical policy, identical
10s failed-wake cooldown (see below), the only difference is `await`ing the waker instead of
blocking on it.

**This changes reply ordering, and that is safe by construction, not by luck.** A `.newSession`
reply can now land after replies to commands the phone sent later, because the deferred branch
answers from inside a `Task` rather than on the way out of the frame handler. Nothing in this
codebase orders replies by arrival — every client correlates a reply to its request by `cid`,
independent of when it arrives — so a reordered reply is indistinguishable from a slow one. See
`docs/NETWORKING.md` for where this is recorded for a phone-side implementer.

**Caveat on the end-to-end verification above.** The "Verified end-to-end against the shipped
app" run earlier in this document exercised the *synchronous*, main-actor-blocking waker — the
code path this follow-up just replaced. That evidence does not carry over unexamined to the
async path introduced here; a fresh manual run against a build with this follow-up is still
owed.

### A — rejected

Holding `PreventUserIdleDisplaySleep` while a phone is paired (one line beside the existing
`.idleSystemSleepDisabled` assertion in `FleetService.holdSleepAwake`) would work, but means the
display never sleeps while the phone is connected. Rejected as a solution.

## Must fix regardless of C or B

**The phone's `+` is silent on failure.**
`FleetModel.newSession(inProject:)` is `connector?.send(.newSession(project: id))` —
fire-and-forget. It never reads the reply, so **every** `err` frame is dropped, not just
`terminal_unavailable`. From the phone, a refusal is indistinguishable from a dead connection.

Two changes: give it a `cid` and handle the reply (`newSessionOptions` already does this
correctly and is the model to copy), and map `terminal_unavailable` in
`Sources/FlightDeckMobile` — it currently has no mapping anywhere, so even a handled error would
render as a generic fallback.

## Loose ends

- **`session 169`** (`AF1340C0-19FA-435C-B6AD-19DCFFE7B654`) is the live inert specimen:
  `activity: idle`, no registry entry. **Restart Terminal on it has never been clicked** — that
  is the one behaviour in the whole change with no verification.
- **Plan 2** (`docs/superpowers/specs/2026-08-29-diagnostics-query-interface-design.md`, the
  local HTTP diagnostics interface) is unbuilt. Its design decisions stand: read + four repairs,
  localhost HTTP + issued token, pair once unlocked, desktop only.
- **The tab-birth detector** classified every new tab HEALTHY / NO-AGENT / NO-SHELL and found
  the reproduction. It lives in this session's scratchpad only and dies with it; rebuild from
  the description in the spec if wanted. Two defects were found *by running it* — a false
  positive from a partial state read, and a classifier that trusted a net shell count that any
  concurrent close corrupts. Check per-tab evidence, never a net count.
- **`restore()` and `reopenClosedSession()` are deliberately unguarded.** Refusing to restore
  would lose the deck. So a relaunch with the display asleep can bring back a whole deck of
  inert tabs, and `respawnSurface` is the only remedy. An auto-respawn on display wake would
  close this properly and does not exist.
- **DONE — `DisplayState.isDrawable` used to ask about `CGMainDisplayID()` only.** On a Mac with
  more than one display, a main display that had slept while a secondary stayed awake and in
  active use read as not-drawable, and the guard blocked in front of someone who was actively
  looking at a screen — just not the main one. It now enumerates every online display with
  `CGGetOnlineDisplayList` and answers true if **any** of them is active, falling back to
  `CGMainDisplayID()` alone if enumeration itself fails — an unexpected CoreGraphics error
  degrades to the previous behaviour rather than to an unconditional yes.
- **DONE — no memoisation of a recently-failed wake.** Each `+` used to pay the full
  attempted-wake cost independently — up to 1.5s — with nothing remembering that the last
  attempt, moments ago, timed out. A failed wake is now memoised in `lastFailedWake` and
  consulted for `SessionStore.wakeRetryCooldown` (10s): `ensureTerminalCreatable` and
  `awaitTerminalCreatable` both check it, but only after `canCreateTerminal` has already
  answered false, so a display that comes back on its own inside the cooldown is never
  suppressed by a stale memo — the very next `canCreateTerminal` check sees it and clears
  `lastFailedWake`. In clamshell mode or with no display attached, this still leaves the first
  tap in every 10s window paying the full wake cost; it is the repeats within that window that
  are now cheap.
