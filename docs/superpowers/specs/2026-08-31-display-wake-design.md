# Design — wake the display long enough to fork a shell

Supersedes the "Direction" section of `HANDOFF-2026-08-31-display-sleep.md`. Route C
(hand libghostty our own PTY) is blocked at the API boundary and is not revisited here.

## Problem

Creating a session while the Mac's display is asleep produces an inert tab: libghostty
returns a `SurfaceView` but never forks, so there is no `login`, no agent, no status file.
Today `canCreateTerminal` catches that and *refuses*. Refusing is honest but it is not a
fix — the display is asleep precisely when you are away from the Mac and reaching for the
phone, which is the whole point of the phone.

## Spike result this design rests on

Measured on 2026-08-31, this machine, display slept with `pmset displaysleepnow` and the
condition verified held before each intervention:

| Question | Answer | n |
|---|---|---|
| Does `IOPMAssertionDeclareUserActivity(…kIOPMUserActiveLocal…)` wake a slept display? | Yes | 4 |
| How long until `CGDisplayIsActive` is true? | **0.173 / 0.194 / 0.295 / 0.342 s** | 4 |
| Does it work while the screen is **locked**? | **Yes** — and the Mac auto-locks within ~5s of display sleep, so every run above was already locked | 4 |
| With the display so woken, does libghostty actually fork? | **Yes** — `Flight Deck → /usr/bin/login → zsh → claude`, session id matching `sessions.json` | 1 |

Two facts from this drive the design:

1. **The wake is asynchronous.** `declareUserActivity()` immediately followed by
   `makeSurface()` would still find no drawable. We must **poll until drawable**, not fire
   and proceed, and not sleep a fixed interval.
2. **A single declaration is enough.** The display stayed active ≥3s after one call —
   ample to fork. No lease needs holding, so nothing needs releasing.

## Approach

**Wake synchronously, in place, only when the display is not already drawable.**

Rejected: making the creation paths `async`. Three of the four are synchronous and widely
called (menu actions, sidebar, the fleet service handler); `newSession(in:)`'s own doc
comment records that changing its shape "broke 340 tests". An `await` there would also mean
the first tab appears only after `SessionStore.init` returns, which `seedInitialSession`'s
comment explicitly rules out. The blast radius is not worth it for a wait we can bound at
under half a second.

The cost of blocking is small and lands only where the code currently **fails outright**:

- When the display is awake — every creation from the Mac itself — `isDrawable` is already
  true and **nothing blocks at all**.
- When it is asleep, nobody is looking at the Mac by definition, and the phone is already
  awaiting a network reply.
- If a wake is impossible (clamshell, no display attached) we block for the timeout **once**
  and then refuse exactly as today.

### Components

**`DisplayWaking` (new, `Sources/FlightDeck/DisplayState.swift`)** — one method:

```swift
protocol DisplayWaking: Sendable {
    /// Ask the display to wake and block until it is drawable. Returns whether it became so.
    func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool
}
```

- `DisplayWaker` — the real one. Calls `IOPMAssertionDeclareUserActivity` with
  `kIOPMUserActiveLocal`, then polls an injected `DisplayInspecting` every **25 ms** to a
  **1.5 s** timeout (>4× the slowest measured wake). Returns immediately if already
  drawable, so the awake case costs one `CGDisplayIsActive` call.
- `NeverWakingDisplay` — the **default**, returning `false` without waking or blocking.

The defaults follow `DisplayInspecting`'s existing and deliberate asymmetry: permissive,
inert defaults in the initializer, with the real implementation injected in
`SessionStore.convenience init(ghostty:…)` beside the existing `display = DisplayState()`.
That one line is load-bearing in exactly the way that comment already warns about, and gets
the same kind of detector test.

**`SessionStore.ensureTerminalCreatable(_:)` (new)** — the single place the policy lives:

```swift
enum DisplayWakePolicy { case wakeIfNeeded, never }

func ensureTerminalCreatable(_ policy: DisplayWakePolicy = .wakeIfNeeded) -> Bool {
    if canCreateTerminal { return true }
    guard policy == .wakeIfNeeded else { return false }
    return displayWaker.wakeAndWaitForDrawable(timeout: Self.wakeTimeout)
}
```

`canCreateTerminal` stays exactly as it is — a pure, cheap query with no side effects,
still `provider == nil || display.isDrawable`, so the fixture clause that keeps the suite
from deadlocking is untouched. When it is false, `provider` is necessarily non-nil, so the
waker is only ever reached on a real terminal path.

### Where the wake applies, and where it must not

The four existing guard sites all become `guard ensureTerminalCreatable() else`, keeping
their current refusal bodies verbatim:

| Site | Refusal today (unchanged) |
|---|---|
| `newSession(in:at:account:)` | un-inserted `Session` |
| `createSession(agent:in:at:account:)` | `.failure(.terminalUnavailable)` |
| `openSignInSession(for:in:using:)` | un-inserted `Session` |
| `respawnSurface(for:)` | `.displayAsleep` |

**`seedInitialSession` must opt out.** It calls `newSession(in:)` *inline inside
`SessionStore.init`*. Left alone it would light the screen up on every launch — including
an unattended relaunch at 3am — and block app startup while doing it. Seeding is not
someone asking for a terminal; it is the app starting. So `newSession(in:)` takes a
`waking:` parameter defaulting to `.wakeIfNeeded`, and `seedInitialSession` passes
`.never`, preserving today's behaviour there exactly: refuse, fork nothing.

**Out of scope:** `restore()` and `reopenClosedSession()` stay unguarded and non-waking, as
today. A relaunch with the display asleep can still bring back a deck of inert tabs, and
`respawnSurface` remains the remedy. Auto-respawn on display wake is a separate change and
is not attempted here.

**The guard is not removed.** A wake can fail, and when it does the tab must still be
refused rather than silently born inert. B changes the refusal from the routine outcome to
the exceptional one; it does not make it impossible.

## Error handling

`wakeAndWaitForDrawable` returns `Bool` and never throws. A non-success
`IOPMAssertionDeclareUserActivity` return is treated as "did not wake" and still falls
through to the poll, because the assertion failing does not prove the display is
un-drawable — something else may have woken it. Timeout is the only other outcome, and it
maps onto the existing `.terminalUnavailable(displayAsleep: true)` report, so every message
the user can already see stays correct.

## Testing

The suite must never wake a real display, which the `NeverWakingDisplay` default
guarantees: any test not deliberately injecting a waker behaves exactly as it does today.

- A `SpyDisplayWaker` recording call count and scripted result, paired with a mutable
  `DisplayInspecting` stub that flips to drawable when the waker is called — this is what
  makes "wake, then succeed" testable without a display.
- Per site: a wake is attempted when not drawable, creation then proceeds, and a session is
  really inserted with a registry entry.
- Per site: when the wake fails, the refusal is byte-identical to today's.
- Not drawable but **already** drawable: waker never called (the awake path stays free).
- `seedInitialSession` never calls the waker.
- A detector that the real `DisplayWaker` is wired into `convenience init(ghostty:)`,
  mirroring `testTheRealProbeIsWiredIn`.
- `DisplayWaker` itself: polling and timeout logic tested against a stub inspector, with no
  IOKit call — the IOKit call is the one line covered by the manual verification below.

## Verification

Unit tests plus one manual end-to-end run, because the thing that actually matters — a real
`login` forked against a real drawable — cannot be asserted in the suite. Using the
procedure the spike established: `pmset displaysleepnow`, wait for the auto-lock, confirm
`CGDisplayIsActive` false, then create from the phone and assert the new session has a
`/usr/bin/login` child of the Flight Deck pid. **Per-tab evidence — a new PID tied to the
new session id — never a net shell count, which any concurrent close corrupts.**
