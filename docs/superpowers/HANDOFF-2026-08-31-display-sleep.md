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
`~/Library/Application Support/Flight Deck/backups/20260831-091211/`).

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

### B — wake the display just long enough to fork

`IOPMAssertionDeclareUserActivity(… kIOPMUserActiveLocal …)` around surface creation, released
straight after. Cost: the screen lights for a second or two when you tap `+`.

**Test these in order — the third is the one that decides it:**
1. Does the wake complete *before* `ghostty_surface_new` runs? It is asynchronous; a naive call
   followed immediately by `makeSurface` may still find no drawable. Measure, don't assume.
2. Does `CGDisplayIsActive` go true, and how long does it take?
3. **Does it work while the screen is LOCKED?** Waking a locked Mac shows the login window. Does
   that provide a drawable to a background app's surface? **Unknown, and it is the crux** — the
   phone case is almost always locked. If a locked wake yields no drawable, B does not solve the
   real scenario either, and the honest answer becomes C-via-upstream or accepting the
   limitation.

Keep the existing guard under B. It stays correct for the cases a wake cannot rescue; it just
stops being the routine outcome.

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
