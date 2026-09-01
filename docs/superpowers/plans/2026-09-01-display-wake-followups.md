# Display-wake follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Close the three follow-ups the display-wake final review recorded but did not fix.

**Spec:** `docs/superpowers/specs/2026-08-31-display-wake-design.md` and the Follow-up / Loose ends
sections of `docs/superpowers/HANDOFF-2026-08-31-display-sleep.md`.

**Architecture:** Three independent changes, one commit each so the riskiest is revertible alone.
A is a change to the command-dispatch contract; B and C are local.

## Global Constraints

- Worktree `/Users/nate/Projects/Protos-n-Tools/flight-deck/.claude/worktrees/display-wake`,
  branch `display-wake-followups`. Never touch the parent checkout.
- Built-in Read/Edit/Write ONLY — qartez mutators silently write to the parent checkout from a
  worktree. Confirm every edit with `git diff --stat`.
- **The suite must never wake a real display.** `SessionStore.displayWaker` defaults to
  `NeverWakingDisplay()`; `DisplayWaker`'s IOKit call stays behind the injectable closure.
- `canCreateTerminal` stays a pure, side-effect-free query.
- Wake timeout `1.5`s, poll interval `0.025`s.
- `./scripts/test-unit.sh` to test. Never `scripts/smoke.sh` (steals the screen ~40s).
- Commit per task. Do not merge to master.

---

### Task 1: Let the phone's creation wake without blocking the main actor

**Why:** `ensureTerminalCreatable` blocks the main actor for up to 1.5s. Every Mac-local caller
is synchronous and must stay so (`newSession(in:)`'s own comment records that changing its shape
broke 340 tests; `seedInitialSession` runs inline inside `init`). But the phone path — the one
this feature exists for — is already asynchronous underneath, and it is the only caller that
need not block. `FleetSocketServer.onRequest`'s doc comment says commands answer synchronously
"forced rather than stylistic: a command is dispatched on the way out of the frame handler,
while a page is a file read that would otherwise block `queue`". The wake broke that premise —
this restores it.

**Files:** `Sources/FlightDeck/DisplayState.swift`, `Sources/FlightDeck/SessionStore.swift`,
`Sources/FleetKit/FleetSocketServer.swift`, `Sources/FlightDeck/Fleet/FleetService.swift`,
`Tests/FlightDeckTests/DisplayWakerTests.swift`, `Tests/FlightDeckTests/FleetServiceTests.swift`

**Interfaces produced:** `DisplayWaking.wakeAndWaitForDrawable(timeout:) async -> Bool`;
`SessionStore.awaitTerminalCreatable(_:) async -> Bool`; `onCommand` reply-callback shape.

- [ ] **Step 1: async twin on the waker.** Add to `protocol DisplayWaking`, alongside the
  existing sync method (which stays — Mac-local paths keep using it):

```swift
    /// Async twin of `wakeAndWaitForDrawable`. Same contract, but **yields** between polls
    /// instead of blocking, so a caller on the main actor releases it while the display comes
    /// up. Only the phone path uses this; every Mac-local creation path is synchronous and
    /// documented as needing to stay that way.
    func wakeAndWaitForDrawable(timeout: TimeInterval) async -> Bool
```

`DisplayWaker`'s implementation mirrors the sync one exactly, including the already-drawable
early return and the single declaration:

```swift
    func wakeAndWaitForDrawable(timeout: TimeInterval) async -> Bool {
        if display.isDrawable { return true }
        declareUserActivity()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
            if display.isDrawable { return true }
        }
        return false
    }
```

`NeverWakingDisplay`: `func wakeAndWaitForDrawable(timeout: TimeInterval) async -> Bool { false }`.

- [ ] **Step 2: async funnel on the store.** Beside `ensureTerminalCreatable(_:)`, deliberately
  a *distinct name* rather than an `async` overload — same-name sync/async overloads resolve by
  context and would make the blocking version reachable by accident from an `await` site:

```swift
    /// `ensureTerminalCreatable`, for a caller that can afford to await instead of blocking.
    /// The phone's `.newSession` is the only one. Behaviour is identical in every other
    /// respect, including the `provider == nil` short-circuit inherited from `canCreateTerminal`.
    func awaitTerminalCreatable(_ policy: DisplayWakePolicy = .wakeIfNeeded) async -> Bool {
        if canCreateTerminal { return true }
        guard policy == .wakeIfNeeded else { return false }
        return await displayWaker.wakeAndWaitForDrawable(timeout: Self.wakeTimeout)
    }
```

- [ ] **Step 3: give `onCommand` the reply shape `onRequest` already has.** In
  `Sources/FleetKit/FleetSocketServer.swift`, change the declaration to

```swift
    public var onCommand: (
        (_ client: FleetAttachment, _ cid: Int, _ command: FleetCommand,
         _ reply: @escaping (ServerFrame) -> Void) -> Void
    )?
```

and at the `case .cmd(let cid, let command):` dispatch site, replace the
`let reply = self.onCommand?(...)` / `FleetSocket.send(reply, …)` pair with the SAME
answered-once wrapper `onRequest` uses immediately below it — copy its shape exactly: the
`var answered = false`, the `dispatchPrecondition(condition: .onQueue(self.queue))`, the
`guard !answered`, and the `guard self.attached[id] != nil` staleness check. Keep the existing
`unhandled` fallback for a nil `onCommand`. Update the doc comment on `onCommand` to say a
command may now answer after an await, and why (the display wake).

- [ ] **Step 4: defer only the creation that actually needs it.** In `FleetService`:

```swift
        server.onCommand = { [weak self] client, cid, command, reply in
            guard let self else { return reply(.err(cid: cid, code: "stopped")) }
            // The ONLY command that can need to wait, and only when the display is not
            // already drawable — which is to say, almost never. Every other command, and
            // every creation on an awake Mac, still answers on the way out of the frame
            // handler exactly as before.
            if case .newSession = command, !self.store.canCreateTerminal {
                Task { @MainActor in
                    guard await self.store.awaitTerminalCreatable() else {
                        return reply(.err(cid: cid, code: "terminal_unavailable"))
                    }
                    reply(self.apply(command, from: client, cid: cid))
                }
                return
            }
            reply(self.apply(command, from: client, cid: cid))
        }
```

**Leave `apply`'s own `guard store.ensureTerminalCreatable()` exactly as it is.** After an
awaited wake the display is drawable, so it short-circuits on `canCreateTerminal` and never
blocks; it remains the safety net for every other route into that case.

- [ ] **Step 5: tests.** Add to `DisplayWakerTests` an async mirror of each existing case
  (already-drawable declares nothing; wakes then succeeds; gives up at the timeout) using
  `pollInterval: 0.001` and real `Task.sleep`. In `FleetServiceTests`, keep both existing phone
  tests passing and add one asserting that with a *slow* waker (one that flips the display only
  after an await) the phone still gets an `ack` and a tab is created. Every other call site of
  `onCommand` in tests must be updated to the new closure shape.

- [ ] **Step 6:** `./scripts/test-unit.sh` green, then commit:
  `feat: let the phone's creation await the wake instead of blocking the main actor`

---

### Task 2: Ask whether ANY display is drawable, not just the main one

**Why:** `DisplayState.isDrawable` reads `CGDisplayIsActive(CGMainDisplayID())`. On a
multi-display Mac whose *main* display has slept while a secondary is awake and in use, that
reads false — so creation blocks, and wakes a screen, in front of someone who is actively
looking at a different one. A single-display probe was deciding a machine-wide question.

**Files:** `Sources/FlightDeck/DisplayState.swift`, `Tests/FlightDeckTests/DisplayStateTests.swift`

- [ ] **Step 1:** replace `DisplayState.isDrawable`'s body, keeping the type and its doc comment's
  existing explanation of why `CGDisplayIsActive` rather than `!CGDisplayIsAsleep`:

```swift
    /// **Any** online display being active, not just the main one. libghostty needs *a*
    /// drawable, and a Mac with a slept main display and an awake secondary has one — asking
    /// only about `CGMainDisplayID()` made a single display decide a machine-wide question and
    /// would block, and light a screen, in front of someone looking at another one.
    ///
    /// Falls back to the main display if enumeration fails: an unexpected CoreGraphics error
    /// should degrade to the previous behaviour, not to an unconditional yes.
    var isDrawable: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else {
            return CGDisplayIsActive(CGMainDisplayID()) != 0
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else {
            return CGDisplayIsActive(CGMainDisplayID()) != 0
        }
        return ids.prefix(Int(count)).contains { CGDisplayIsActive($0) != 0 }
    }
```

- [ ] **Step 2:** `DisplayStateTests` cannot script CoreGraphics, so assert only what is
  honestly assertable on the machine running the suite: that `isDrawable` agrees with "some
  online display is active", computed the same way, and that it does not crash with the real
  API. Do NOT write a test that merely restates the implementation line-for-line — if the only
  possible test is a tautology, write none and say so in the report.

- [ ] **Step 3:** suite green, then commit:
  `fix: treat any awake display as drawable, not only the main one`

---

### Task 3: Stop re-paying the full timeout on every attempt

**Why:** in clamshell, or with no display attached, a wake cannot succeed and costs the whole
1.5s. Every `+`, every menu action, every Restart Terminal pays it again.

**Files:** `Sources/FlightDeck/SessionStore.swift`, `Tests/FlightDeckTests/DisplayWakeTests.swift`

- [ ] **Step 1:** add to `SessionStore`, near `displayWaker`:

```swift
    /// When the last wake attempt failed, so a display that cannot wake is not re-attempted on
    /// every tap. **Only ever consulted when `canCreateTerminal` is already false**, so a
    /// display that comes back is never suppressed by it — it short-circuits first.
    private var lastFailedWake: Date?
    /// Long enough that a burst of taps costs one timeout, short enough that plugging a display
    /// in is noticed almost immediately. Only matters while creation is failing anyway.
    static let wakeRetryCooldown: TimeInterval = 10
    /// Injected so the cooldown is testable without sleeping.
    var now: @Sendable () -> Date = { Date() }
```

- [ ] **Step 2:** thread it through BOTH funnels — `ensureTerminalCreatable` and
  `awaitTerminalCreatable` from Task 1 — with identical logic:

```swift
        if canCreateTerminal { lastFailedWake = nil; return true }
        guard policy == .wakeIfNeeded else { return false }
        if let last = lastFailedWake, now().timeIntervalSince(last) < Self.wakeRetryCooldown {
            return false
        }
        let woken = displayWaker.wakeAndWaitForDrawable(timeout: Self.wakeTimeout)
        lastFailedWake = woken ? nil : now()
        return woken
```

(the async funnel is the same with `await` on the waker call).

- [ ] **Step 3: tests** in `DisplayWakeTests`: a second creation inside the cooldown does not
  call the waker again and still refuses; a second creation *after* the cooldown does call it
  again; and a successful wake clears the memo so a later failure is not suppressed. Drive the
  clock with the injected `now`, never by sleeping.

- [ ] **Step 4:** suite green, then commit:
  `fix: do not re-pay the wake timeout on every attempt while it cannot succeed`

---

## Verification

Unit tests plus one manual check after merge: with the Mac's display asleep and locked, tap `+`
on the phone and confirm the tab still forks (`/usr/bin/login` child of the Flight Deck pid,
tied to the new session id) — Task 1 changes the path that produced it, so the earlier
end-to-end result does not carry over unexamined.
