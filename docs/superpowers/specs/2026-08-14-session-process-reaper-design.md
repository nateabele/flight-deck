# Session Process Reaper — Design

**Date:** 2026-08-14 · **Status:** design approved, ready for planning

## 1. Goal

Make "the tab is closed" mean "the processes it was running are dead" — definitely, with a
bounded deadline, and without stalling the main thread while it happens.

Three teardown paths are in scope: **closing a tab**, **quitting the app**, and **a previous
run that died abnormally**. Out of scope: any confirmation dialog (closing a tab stays instant
and unprompted), and any change to the vendored `vendor/ghostty` submodule.

## 2. Why today's teardown is not a guarantee

`SessionStore.closeSession` (`Sources/FlightDeck/SessionStore.swift:416`) does exactly one
process-relevant thing — `surfaces[id] = nil` at line 422. Flight Deck contains no `kill`, no
signal, and no pid of its own anywhere; process death is entirely libghostty's doing, reached
through this chain:

| Step | Location |
|---|---|
| `Ghostty.Surface.deinit` → `Task.detached { @MainActor in ghostty_surface_free(…) }` | `GhosttyEmbed/Ghostty.Surface.swift:27-36` |
| `ghostty_surface_free` → `App.closeSurface` → `Surface.deinit` | `vendor/ghostty/src/apprt/embedded.zig:1557`, `:254`, `:595` |
| core `Surface.deinit` stops and **joins** the IO thread | `vendor/ghostty/src/Surface.zig:790-795` |
| `Exec.threadExit` → `Subprocess.stop` | `vendor/ghostty/src/termio/Exec.zig:194`, `:1088` |
| `killPid`: `killpg(pgid, SIGHUP)` in a loop until the direct child is reaped | `vendor/ghostty/src/termio/Exec.zig:1152-1185` |

Four distinct holes:

**A — it is SIGHUP, and only SIGHUP.** Anything that ignores or handles it survives. The loop
re-signals the group only until `waitpid` reaps the *direct child*; once the shell is gone the
group stops being signalled, so a SIGHUP-ignoring grandchild outlives the tab.

**B — `killpg` reaches exactly one process group.** Anything that called `setsid()`/`setpgid()`
— a `setsid`-launched dev server, a tmux server — never receives the signal at all. The comment
at `Exec.zig:1160-1167` acknowledges the *race* version of this ("grandchildren survive") but
defends only against the setsid-timing case, not deliberate detachment.

**C — the free is asynchronous and refcount-dependent.** `surfaces[id] = nil` frees the view
only if nothing else retains it. For the currently-selected tab — the usual thing you close —
`TerminalHostView` still holds it as a subview until the next SwiftUI pass runs
`updateNSView` and calls `removeFromSuperview()` (`TerminalPane.swift:40-42`); `closeSession`
never detaches it explicitly. Then `ghostty_surface_free` is a detached task whose own comment
says the free "will happen sometime". Nothing verifies the process died.

**D — the failure mode is a main-thread hang, not a leak.** `Exec.zig:1162-1172` ignores a
`killpg` that fails with `EPERM` on Darwin, then spins on `waitpid(WNOHANG)` + 10 ms sleep
forever. That loop runs inside `ghostty_surface_free`, which is `@MainActor`. A child that does
not die on SIGHUP wedges the UI. This is the shape `scripts/hangwatch.sh` (commit `10fb0cd`)
exists to capture.

**E — app quit has no teardown at all.** There is no `applicationWillTerminate` and no surface
cleanup in `AppDelegate.swift`; quitting leans on the kernel SIGHUP'ing each pty's foreground
group when the master fd closes at exit — the same SIGHUP caveats, plus detached descendants
are simply reparented to launchd and keep running.

## 3. Why the fix lives in Swift, not in the vendored Zig

`vendor/ghostty` is a **submodule pinned to upstream** (`.gitmodules`, `docs/BUILD.md:25`), and
`scripts/build-libghostty.sh` `git clean`s it after staging the xcframework
(`docs/BUILD.md:37`) — so a local edit to `Exec.zig` is wiped by the next build unless the
build script grows a patch-apply step. The C API also exposes no child pid; the only
process-related export is `ghostty_surface_process_exited` (`vendor/ghostty/include/ghostty.h:1082`).

So Flight Deck discovers the pid itself, and owns the escalation itself. Nothing under
`vendor/` and nothing under `Sources/FlightDeck/GhosttyEmbed/` changes.

## 4. Discovering the pid

`libproc` gives us our own children. Surface creation is `@MainActor` and therefore serialized,
so a snapshot taken immediately before and after the `makeSurface` call in `insertSession`
(`SessionStore.swift:278`) isolates exactly one new child — the shell libghostty just forked:

```swift
let before = inspector.children(of: getpid())
let view   = provider?.makeSurface(config)
let after  = inspector.children(of: getpid())
let new    = after.subtracting(before)
```

If `new` holds exactly one pid, that is the session's shell and we record
`ProcessIdentity(pid:procStart:)` plus its `pgid`. **If it holds zero or more than one, we
record nothing and log.** No guessing: a tab with no recorded identity simply degrades to
today's behavior rather than risking a signal at the wrong process.

`#import <libproc.h>` goes in `Sources/FlightDeck/BridgingHeader.h`. The app is not sandboxed
(`FlightDeck.entitlements` carries no `com.apple.security.app-sandbox`), so enumerating and
signalling our own descendants needs no entitlement.

### 4.1 `ProcessIdentity`

```swift
struct ProcessIdentity: Codable, Equatable {
    let pid: pid_t
    /// Start time in seconds since the epoch, from `proc_pidinfo(PROC_PIDTBSDINFO)`.
    let procStart: UInt64
}
```

A pid alone is not an identity — macOS recycles pids. This is the same doctrine
`ConversationPin.Anchor` already establishes for the `~/.claude/sessions/<pid>.json` registry
(`ConversationPin.swift:9-12`, `:53-55`): a familiar pid with an unfamiliar start time is a
*different process*, not the one we recorded. **Every signal in this design is gated on the
start time still matching.** That gate is what makes the launch-time sweep (§7) safe.

## 5. The escalation ladder

`SessionReaper` is an `actor` — deliberately not `@MainActor`, so no part of the ladder can
stall the UI:

```
tree = descendants(of: shellPid)   ← captured FIRST, while the shell is alive
killpg(pgid, SIGHUP)    → poll to 2s
killpg(pgid, SIGTERM)   → poll to 2s
killpg(pgid, SIGKILL)   → poll to 1s
survivors = tree.filter(isAlive)   ← identity-checked against the recorded procStart
  → repeat the same ladder per-pid on each
→ ReapOutcome.clean | .survivors([ProcessIdentity])
```

**The descendant snapshot must be taken before the first signal, not after.** Once the shell
dies its children are reparented to launchd and `proc_listchildpids(shellPid)` returns nothing
— walking the tree after the group kill would find an empty set every time and silently report
success while the escapees kept running. Capturing the tree up front also captures the setsid
escapees of Hole B, which are invisible to `killpg` but are still *children* of the shell
(`setsid` changes session and process group, not parentage).

Each recorded survivor carries its own `ProcessIdentity`, so the per-pid ladder re-checks
`procStart` before every signal — between the snapshot and the escalation a pid may have died
and been recycled, and the identity gate is what stops us signalling its replacement.

Polling short-circuits: a shell that dies on the first SIGHUP — the overwhelmingly common case
— completes the whole reap in one poll interval, not 2 seconds. The group is escalated first
because that is the cheap common path. A process reparented to launchd *before* the snapshot is
genuinely unreachable from here, and is reported rather than silently missed.

Signal delivery sits behind a `SignalSending` protocol so the ladder's sequence and deadlines
can be asserted in tests without a single real process. The clock is injected the same way the
rest of the codebase does it (`WatchClock`).

### 5.1 The self-group rail

**The reaper must refuse to `killpg` a group equal to its own `getpgid(0)`, and fall back to
signalling each pid individually.** In the real app this never fires: libghostty's child calls
`setsid` as its first act, so its group is its own. But a process spawned by anything that does
*not* setsid — notably `Foundation.Process` inside the test bundle — lands in the *test
runner's* process group, and a `killpg` there would take down the test runner (and, in a
development build launched from a shell, the terminal that launched it). Upstream ghostty worries
about the same window from the other direction, retrying while `pgid == my_pgid`
(`Exec.zig:1193-1205`).

This rail is also what makes the real-process acceptance test in §9 possible at all.

## 6. Ordering: reap before free

**`closeSession` must complete the reap before releasing the `SurfaceView`, not after.**

Today the release leads to `ghostty_surface_free` → `io_thr.join()` → libghostty's blocking
`killpg` loop *on the main actor* — Hole D. If the child is already dead when that loop runs,
it reaps instantly and the stall disappears. Reaping afterwards, or concurrently, leaves the
main thread blocked for however long our own escalation takes; on exactly the pathological
process this work exists to handle, that is a multi-second beachball.

So `closeSession`:

1. removes the view from `surfaces` and calls `removeFromSuperview()` on it **explicitly**, so
   the tab closes visually at once and the eventual free is not gated on a SwiftUI pass (Hole C);
2. parks the view in a pending-teardown holder — a strong reference held by the store — so it
   is not deallocated yet;
3. kicks off the reap;
4. releases the parked view when the reap finishes or the budget expires, letting the existing
   deferred-free path run against an already-dead child.

Everything else in `closeSession` (watchers, statuses, `notifier?.withdraw`, selection, persist)
stays exactly where it is and stays synchronous. The tab disappears from the sidebar
immediately; only the invisible surface teardown is deferred.

During that window libghostty may notice the child exited and post `ghosttyCloseSurface` for a
surface that is no longer in `surfaces`. `observeSurfaceClose` (`SessionStore.swift:657-670`)
looks the view up by identity and returns on a miss, so this is already safe — but it is a real
new interleaving and §9 pins it with a test.

## 7. The three entry points

**Tab close** — `closeSession`, per §6, with a ~5 s per-session budget.

**App quit** — `applicationShouldTerminate` returns `.terminateLater`, reaps every live session
concurrently under one capped **total** budget (~8 s, not 5 s × sessions), then calls
`reply(toApplicationShouldTerminate: true)`. The cap is what keeps quit from ever hanging: when
it expires, we reply `true` regardless and let the survivors be reported on next launch.

**Launch sweep** — `SessionSnapshot` gains two optional fields:

```swift
var processes: [UUID: ProcessIdentity]?   // tab id → its shell
var owner: ProcessIdentity?               // the Flight Deck run that wrote this snapshot
```

Both optional, because `SessionSnapshot.Entry` already documents why
(`SessionPersistence.swift:12-17`): synthesized `Codable` decodes optionals with
`decodeIfPresent`, so every existing `sessions.json` still decodes and no launch wipes a user's
tabs. Non-optional fields would throw on the first launch after this change.

On startup, before `restore()`: if `owner` is set and that process is **no longer alive**, every
recorded identity that *is* still alive with a matching `procStart` gets the ladder — including
a walk of its live descendants, which is available here precisely because the orphaned shell is
still running. The `owner` check is what prevents a second concurrent Flight Deck instance from
killing the first instance's children — without it, two instances sharing `sessions.json` would
reap each other. Restored tabs always get brand-new shells, so any identity in a loaded snapshot
written by a dead owner is by definition an orphan.

A crash where the shell itself already died (the common case: the pty master closed, the kernel
SIGHUP'd the foreground group) leaves nothing for the sweep to find, and nothing for it to do.
The sweep exists for the shells that *survived* that SIGHUP — the same population as Hole A.

## 8. Reporting

Closing a tab reports nothing on the happy path — no dialog, no banner, no change to the
existing one-click close. The user hears about it in exactly two cases: a tree that survives the
full SIGKILL deadline, and a launch sweep that cleaned something up.

Delivery goes through a `ReapReporting` protocol, and that seam is **load-bearing rather than
ceremony**, for the reason `Notifying` already documents (`SessionNotifier.swift:12-16`):
`UNUserNotificationCenter.current()` traps when the calling binary is not a signed bundle,
which is exactly the case inside the unit-test bundle. Nothing reachable from a test may touch
it. Every outcome is also `os_log`ged unconditionally.

## 9. Testing

| What | How |
|---|---|
| Ladder sequence and deadlines | Fake `SignalSending` + injected clock. Asserts SIGHUP → SIGTERM → SIGKILL with the right waits, and that an early death short-circuits the rest. No real processes. |
| Early exit | A target that dies during the first poll must produce exactly one signal. |
| Snapshot-before-signal | A fake inspector that returns the tree only while the shell is "alive" and an empty set afterwards. The reaper must still find and ladder the escapee — this pins §5's ordering, which is invisible to every other test. |
| `ProcessTree` | Real short-lived `/bin/sleep` children spawned by the test; assert children, recursive descendants, and start-time reads. |
| **Pid recycling** | A recorded identity whose `procStart` no longer matches must **not** be signalled. This is the test that keeps the launch sweep from killing an innocent process. |
| Launch sweep gating | Snapshot with a *live* `owner` → sweep is a no-op. Snapshot with a dead owner and a live matching identity → laddered. |
| Snapshot compatibility | A v1 `sessions.json` with neither new field decodes, restores every tab, and sweeps nothing. |
| Close interleaving | `ghosttyCloseSurface` posted for a parked, already-removed surface is a no-op (§6). |
| Self-group rail | A target whose pgid equals `getpgid(0)` must produce **zero** `killpg` calls and per-pid signals instead (§5.1). |
| **Proof of fix (real processes)** | Spawn `/bin/sh -c "trap '' HUP; sleep 300 & sleep 300"`, run the real reaper against it, assert both pids are gone within budget. Real signals, real libproc, no fakes. **This is the test that fails against today's behavior** — SIGHUP alone never kills that tree. |

`test-unit.sh` runs the bundle headlessly through `xcrun xctest` with **no host app launched**,
which is why the proof test is written against a self-spawned process tree rather than a real
surface: anything needing a live `ghostty_app_t` has to `XCTSkip` there, exactly as
`SurfaceLifecycleTests` already does. A surface-level close test is still worth having in that
skip-guarded style, but it cannot be the proof.

## 10. Files

**New:** `ProcessIdentity.swift`, `ProcessTree.swift`, `SessionReaper.swift`,
`SurfaceProcessRegistry.swift`.

**Modified:** `SessionStore.swift` (`insertSession`, `closeSession`), `AppDelegate.swift`,
`SessionPersistence.swift`, `BridgingHeader.h`.

**Untouched:** everything under `vendor/` and everything under
`Sources/FlightDeck/GhosttyEmbed/`.

## 11. Risks

- **SIGKILL is destructive by design.** Closing a tab now reliably kills a running build or dev
  server that previously survived. That is the requested behavior, but it is a real change in
  what a misclick costs, and there is deliberately no confirmation dialog to soften it.
- **The pid diff can come back ambiguous.** Zero or multiple new children means no record and
  no escalation for that tab — a silent degradation to today's behavior, visible only in the log.
- **Reparented processes are unreachable.** Anything already adopted by launchd before we walk
  the tree cannot be found from our pid, only reported.
- **Sandboxing would break this.** The design depends on the app not being sandboxed. If
  `com.apple.security.app-sandbox` is ever added, libproc enumeration and cross-process
  signalling both need revisiting.
- **The parked-surface window is new.** A closed tab's surface now outlives the row by up to the
  reap budget. It is off-screen and out of `surfaces`, but it is a state that did not previously
  exist.
