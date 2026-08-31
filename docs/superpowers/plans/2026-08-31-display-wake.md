# Display Wake Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a session is requested and the Mac's display is asleep, wake it and wait until it is drawable, so libghostty forks a real shell instead of the request being refused.

**Architecture:** A new injected `DisplayWaking` collaborator beside the existing `DisplayInspecting`. The real `DisplayWaker` calls `IOPMAssertionDeclareUserActivity` and then polls the display probe until drawable or a 1.5s timeout. `SessionStore` gains one funnel, `ensureTerminalCreatable(_:)`, which the four existing guard sites call instead of reading `canCreateTerminal` directly. `canCreateTerminal` itself is unchanged and stays side-effect-free.

**Tech Stack:** Swift 6, `@MainActor` `SessionStore`, XCTest, IOKit power-management (`IOKit.pwr_mgt`), CoreGraphics.

**Spec:** `docs/superpowers/specs/2026-08-31-display-wake-design.md`

## Global Constraints

- **Working directory is the worktree** `/Users/nate/Projects/Protos-n-Tools/flight-deck/.claude/worktrees/display-wake`, on branch `display-wake`. Do not touch the parent checkout — other sessions are live in it.
- **Use built-in `Read`/`Edit`/`Write` only.** qartez structural mutators silently write to the parent checkout from inside a worktree. Verify every edit landed with `git diff --stat`.
- **The suite must never wake a real display.** `SessionStore.displayWaker` defaults to `NeverWakingDisplay()`, and `DisplayWaker`'s IOKit call is behind an injectable closure. Any test that constructs a real `DisplayWaker` must inject `declareUserActivity`.
- **Timeout: `1.5` seconds. Poll interval: `0.025` seconds.** Measured wake latencies were 0.173 / 0.194 / 0.295 / 0.342 s (n=4).
- **Never change the refusal bodies** at the four guard sites. Only the condition changes.
- Run tests with `./scripts/test-unit.sh`. Do not run `scripts/smoke.sh` — it steals focus for ~40s.
- Commit after each task. Do not merge to master; that is handled at the end.

---

### Task 1: The `DisplayWaking` collaborator

**Files:**
- Modify: `Sources/FlightDeck/DisplayState.swift` (append; leave existing types untouched)
- Test: `Tests/FlightDeckTests/DisplayWakerTests.swift` (create)

**Interfaces:**
- Consumes: `DisplayInspecting` (existing, in the same file).
- Produces: `protocol DisplayWaking: Sendable { func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool }`; `struct DisplayWaker: DisplayWaking` with settable `display`, `pollInterval`, `sleep`, `declareUserActivity`; `struct NeverWakingDisplay: DisplayWaking`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/DisplayWakerTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// The IOKit call is injected out in every test here. A real
/// `IOPMAssertionDeclareUserActivity` would wake the machine running the suite.
final class DisplayWakerTests: XCTestCase {
    /// Drawable after `flipsAfter` polls, so "wake, then become drawable" is expressible
    /// without a display. A class because the waker holds it by value.
    private final class Probe: DisplayInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var polls = 0
        var flipsAfter: Int
        init(flipsAfter: Int) { self.flipsAfter = flipsAfter }
        var isDrawable: Bool {
            lock.lock(); defer { lock.unlock() }
            polls += 1
            return polls > flipsAfter
        }
    }

    /// A class, not a captured `var`: `declareUserActivity` is `@Sendable`, and capturing a
    /// mutable local in one is a compile error under Swift 6.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeWaker(probe: Probe, declared: Counter) -> DisplayWaker {
        DisplayWaker(
            display: probe,
            pollInterval: 0.001,
            sleep: { _ in },
            declareUserActivity: { declared.increment() }
        )
    }

    /// The awake case must cost nothing: no assertion, no sleeping. Every creation from the
    /// Mac itself takes this path.
    func testAlreadyDrawableReturnsImmediatelyWithoutDeclaringActivity() {
        let declarations = Counter()
        let waker = makeWaker(probe: Probe(flipsAfter: 0), declared: declarations)
        XCTAssertTrue(waker.wakeAndWaitForDrawable(timeout: 1.5))
        XCTAssertEqual(declarations.count, 0, "an awake display must not be poked")
    }

    /// The measured behaviour: the wake is asynchronous, so the drawable arrives some polls
    /// after the declaration rather than with it.
    func testWakesAndWaitsUntilDrawable() {
        let declarations = Counter()
        let waker = makeWaker(probe: Probe(flipsAfter: 3), declared: declarations)
        XCTAssertTrue(waker.wakeAndWaitForDrawable(timeout: 1.5))
        XCTAssertEqual(declarations.count, 1)
    }

    /// A display that cannot wake — clamshell, none attached — must be given up on, not
    /// waited for forever, because this blocks the main actor.
    func testGivesUpAtTheTimeout() {
        let waker = makeWaker(probe: Probe(flipsAfter: .max), declared: Counter())
        XCTAssertFalse(waker.wakeAndWaitForDrawable(timeout: 0.05))
    }

    /// The default must be inert: this is what keeps the suite from waking a real display.
    func testNeverWakingDisplayDoesNothing() {
        XCTAssertFalse(NeverWakingDisplay().wakeAndWaitForDrawable(timeout: 1.5))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'DisplayWaker' in scope`, `cannot find 'NeverWakingDisplay' in scope`.

- [ ] **Step 3: Implement**

Append to `Sources/FlightDeck/DisplayState.swift`, and add `import IOKit.pwr_mgt` to the existing imports at the top:

```swift
/// Asks a sleeping display to wake, and waits for it to become drawable.
///
/// Separate from `DisplayInspecting` because the two answer different questions and only one
/// of them has a side effect: `isDrawable` is a cheap pure query that `canCreateTerminal`
/// leans on, and lighting up the user's screen must never be something a property getter can
/// do by accident.
protocol DisplayWaking: Sendable {
    /// Wake the display if needed and block until it is drawable. Returns whether it is.
    func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool
}

/// The real one.
///
/// **The wake is asynchronous, which is the whole reason this type exists.** Measured on
/// 2026-08-31: `IOPMAssertionDeclareUserActivity` returns at once, but `CGDisplayIsActive`
/// only goes true 0.173-0.342s later (n=4, locked Mac). Declaring activity and proceeding
/// straight to `ghostty_surface_new` would therefore still find no drawable and still fork
/// nothing — the exact bug this is meant to fix, arriving 200ms later. So: declare, then poll.
///
/// **One declaration is enough and nothing needs releasing.** The display stayed active for
/// at least 3s after a single call, which is ample to fork a shell. This deliberately does
/// not hold an assertion open: the screen should go back to sleep on its own schedule.
struct DisplayWaker: DisplayWaking {
    /// The probe to poll. Injected so the polling and timeout logic is testable without a
    /// display; the IOKit call below is the only part that cannot be.
    var display: DisplayInspecting = DisplayState()
    /// 25ms against a 173-342ms wake is 7-14 samples across the expected range.
    var pollInterval: TimeInterval = 0.025
    var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    /// Injected so no test can wake the machine running the suite.
    var declareUserActivity: @Sendable () -> Void = DisplayWaker.declareLocalUserActivity

    /// `kIOPMUserActiveLocal` — activity at *this* machine, which is what wakes its display.
    ///
    /// The return code is deliberately discarded. A failed assertion does not prove the
    /// display is un-drawable (something else may be waking it), and the poll below is a
    /// direct observation, which beats an inference either way.
    static func declareLocalUserActivity() {
        var assertion: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity(
            "Flight Deck is opening a terminal" as CFString, kIOPMUserActiveLocal, &assertion
        )
    }

    func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool {
        // Checked first so the common case — every creation on a Mac someone is looking at —
        // costs one `CGDisplayIsActive` call and never sleeps.
        if display.isDrawable { return true }
        declareUserActivity()
        var waited: TimeInterval = 0
        while waited < timeout {
            sleep(pollInterval)
            waited += pollInterval
            if display.isDrawable { return true }
        }
        return false
    }
}

/// `SessionStore.displayWaker`'s default: never wakes, never blocks, always reports failure.
///
/// Inert for the same reason `AlwaysDrawableDisplay` is permissive — the suite must not
/// depend on the machine running it. Here the stakes are higher than a wrong answer: a real
/// `DisplayWaker` in a test would physically wake the developer's screen, once per call.
struct NeverWakingDisplay: DisplayWaking {
    func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool { false }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, and no other test newly failing.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/DisplayState.swift Tests/FlightDeckTests/DisplayWakerTests.swift
git commit -m "feat: a display waker that declares activity and waits for the drawable

The wake is asynchronous - 0.173-0.342s on a locked Mac (n=4) - so
declaring activity and proceeding straight to surface creation would
still find no drawable. Declare, then poll.

The IOKit call is behind an injectable closure and the store's default
is NeverWakingDisplay, so no test can wake the machine running the suite."
```

---

### Task 2: The funnel, and `newSession(in:)`

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (property near `display` at ~line 135; `canCreateTerminal` region ~line 871; `newSession(in:)` ~line 1240; `seedInitialSession` ~line 1208)
- Test: `Tests/FlightDeckTests/DisplayWakeTests.swift` (create)

**Interfaces:**
- Consumes: `DisplayWaking`, `NeverWakingDisplay` from Task 1.
- Produces: `SessionStore.displayWaker: DisplayWaking`; `SessionStore.DisplayWakePolicy` (`.wakeIfNeeded`, `.never`); `SessionStore.ensureTerminalCreatable(_ policy: DisplayWakePolicy = .wakeIfNeeded) -> Bool`; `newSession(in:at:account:waking:)` with `waking` defaulting to `.wakeIfNeeded`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/DisplayWakeTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// Companion to `DisplayDrawableGuardTests`, which pins what happens when the display cannot
/// be woken. This pins what happens when it can.
@MainActor
final class DisplayWakeTests: XCTestCase {
    private final class Reporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }

    /// Starts un-drawable and becomes drawable the moment the waker is used, which is the
    /// real sequence compressed: declare activity, then the display comes up.
    private final class Waker: DisplayWaking, @unchecked Sendable {
        let succeeds: Bool
        private let onWake: @Sendable () -> Void
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        init(succeeds: Bool, onWake: @escaping @Sendable () -> Void = {}) {
            self.succeeds = succeeds
            self.onWake = onWake
        }
        func wakeAndWaitForDrawable(timeout: TimeInterval) -> Bool {
            lock.lock(); _calls += 1; lock.unlock()
            if succeeds { onWake() }
            return succeeds
        }
    }

    private final class MutableDisplay: DisplayInspecting, @unchecked Sendable {
        private let lock = NSLock()
        private var _drawable: Bool
        init(_ drawable: Bool) { _drawable = drawable }
        var isDrawable: Bool { lock.lock(); defer { lock.unlock() }; return _drawable }
        func set(_ v: Bool) { lock.lock(); _drawable = v; lock.unlock() }
    }

    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }
    // `SessionStore.provider` is weak; an unretained stub would deallocate immediately and
    // silently turn these into "no provider" tests. Same reason as `DisplayDrawableGuardTests`.
    private var retainedProviders: [StubProvider] = []

    private func makeStore(
        drawable: Bool, wakeSucceeds: Bool
    ) -> (SessionStore, Reporter, Waker) {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        let reporter = Reporter()
        let display = MutableDisplay(drawable)
        let waker = Waker(succeeds: wakeSucceeds, onWake: { display.set(true) })
        store.launchFailureReporter = reporter
        store.display = display
        store.displayWaker = waker
        return (store, reporter, waker)
    }

    /// The point of the whole change: asleep is no longer a refusal.
    func testASleepingDisplayIsWokenAndTheSessionIsCreated() {
        let (store, reporter, waker) = makeStore(drawable: false, wakeSucceeds: true)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(waker.calls, 1)
        XCTAssertTrue(reporter.reported.isEmpty, "a woken display must not report a failure")
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }

    /// The guard is not removed, only made exceptional. A wake that fails must refuse exactly
    /// as before rather than birth an inert tab.
    func testAFailedWakeStillRefusesExactlyAsBefore() {
        let (store, reporter, waker) = makeStore(drawable: false, wakeSucceeds: false)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(waker.calls, 1)
        XCTAssertEqual(reporter.reported, [.terminalUnavailable(displayAsleep: true)])
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty)
    }

    /// The awake path must stay free — no assertion, no blocking, on every ordinary creation.
    func testAnAwakeDisplayIsNeverWoken() {
        let (store, _, waker) = makeStore(drawable: true, wakeSucceeds: true)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(waker.calls, 0)
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }

    /// Seeding runs inline inside `SessionStore.init`. Waking there would light the screen up
    /// on an unattended relaunch and block startup while doing it.
    func testSeedingNeverWakesTheDisplay() {
        let (store, _, waker) = makeStore(drawable: false, wakeSucceeds: true)
        store.seedInitialSession(homeURL: tmp)
        XCTAssertEqual(waker.calls, 0, "app launch is not someone asking for a terminal")
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty)
    }

    /// With no provider there is no libghostty, so there is no drawable to need and nothing
    /// to wake. Pinned so the suite's fixtures never start poking the display.
    func testWithNoProviderNothingIsWoken() {
        let store = SessionStore(provider: nil, persistence: nil)
        let waker = Waker(succeeds: true)
        store.display = MutableDisplay(false)
        store.displayWaker = waker
        _ = store.newSession(in: tmp)
        XCTAssertEqual(waker.calls, 0)
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `value of type 'SessionStore' has no member 'displayWaker'`.

- [ ] **Step 3: Implement**

**3a.** In `Sources/FlightDeck/SessionStore.swift`, immediately after the `var display: DisplayInspecting = AlwaysDrawableDisplay()` declaration (~line 135), add:

```swift
    /// How a sleeping display is brought back before a terminal is created. Injected on the
    /// same seam and for the same reason as `display`, but defaulting to the **inert**
    /// `NeverWakingDisplay()`: a real waker in a test would physically wake the developer's
    /// screen. `convenience init(ghostty:...)` assigns the real one.
    var displayWaker: DisplayWaking = NeverWakingDisplay()
```

**3b.** Immediately after `var canCreateTerminal: Bool { provider == nil || display.isDrawable }` (~line 871), add:

```swift
    /// Whether the wake should be attempted, for callers where it would be wrong.
    enum DisplayWakePolicy { case wakeIfNeeded, never }

    /// How long to block waiting for a woken display. 1.5s is more than four times the
    /// slowest wake measured on this hardware (0.342s); past that the display is not coming
    /// (clamshell, none attached) and blocking the main actor further buys nothing.
    static let wakeTimeout: TimeInterval = 1.5

    /// `canCreateTerminal`, but allowed to *make* it true.
    ///
    /// The four creation paths call this instead of reading `canCreateTerminal` directly, so
    /// the wake happens in exactly one place. `canCreateTerminal` itself stays a pure query —
    /// it is read in contexts that must not light up a screen, and a property getter with a
    /// 350ms side effect would be a trap.
    ///
    /// **Blocking is deliberate.** Three of the four callers are synchronous and widely used;
    /// `newSession(in:)`'s own comment records that changing its shape broke 340 tests. The
    /// block only ever happens where the code currently fails outright, and only while the
    /// display is asleep — which is to say, while nobody is looking at this Mac.
    func ensureTerminalCreatable(_ policy: DisplayWakePolicy = .wakeIfNeeded) -> Bool {
        if canCreateTerminal { return true }
        // Reaching here means `provider != nil` (see `canCreateTerminal`), so the waker is
        // only ever consulted on a path that genuinely needs libghostty.
        guard policy == .wakeIfNeeded else { return false }
        return displayWaker.wakeAndWaitForDrawable(timeout: Self.wakeTimeout)
    }
```

**3c.** Change `newSession(in:)`'s signature and guard (~line 1240). The signature becomes:

```swift
    func newSession(
        in url: URL, at index: Int? = nil, account explicit: UUID? = nil,
        waking: DisplayWakePolicy = .wakeIfNeeded
    ) -> Session {
        guard ensureTerminalCreatable(waking) else {
```

Everything below that line, including the refusal body, is unchanged.

**3d.** In `seedInitialSession` (~line 1208), change `newSession(in: homeURL)` to:

```swift
        // `.never`: this runs inline inside `SessionStore.init`, so waking here would light
        // the screen up on every unattended relaunch and block app startup while it waited.
        // Seeding is the app starting, not someone asking for a terminal.
        newSession(in: homeURL, waking: .never)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS. `DisplayDrawableGuardTests` must still pass untouched — its stores use the `NeverWakingDisplay` default, so its refusals are unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/DisplayWakeTests.swift
git commit -m "feat: wake a sleeping display before creating a session

ensureTerminalCreatable is the one place the wake happens.
canCreateTerminal stays a pure query - it is read where lighting up a
screen would be wrong, and a getter with a 350ms side effect is a trap.

seedInitialSession opts out: it runs inline inside SessionStore.init, so
waking there would light the screen on an unattended relaunch."
```

---

### Task 3: The remaining three creation paths

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`respawnSurface` ~line 900, `createSession` ~line 1298, `openSignInSession` ~line 1409)
- Test: `Tests/FlightDeckTests/DisplayWakeTests.swift` (extend)

**Interfaces:**
- Consumes: `ensureTerminalCreatable(_:)` from Task 2.
- Produces: nothing new; three call sites converted.

- [ ] **Step 1: Write the failing tests**

Append these to `DisplayWakeTests` (inside the class, before the closing brace):

```swift
    /// codex does not route through `newSession(in:)`, so it needs its own guard — and
    /// therefore its own wake. R1 of the original guard missed this path.
    func testCreateSessionWakesASleepingDisplay() async {
        let (store, _, waker) = makeStore(drawable: false, wakeSucceeds: true)
        _ = await store.createSession(agent: .claude, in: tmp.path)
        XCTAssertEqual(waker.calls, 1)
    }

    func testCreateSessionStillFailsWhenTheWakeFails() async {
        let (store, _, waker) = makeStore(drawable: false, wakeSucceeds: false)
        let result = await store.createSession(agent: .claude, in: tmp.path)
        XCTAssertEqual(waker.calls, 1)
        guard case .failure(let error) = result else {
            return XCTFail("a display that will not wake must still refuse")
        }
        XCTAssertEqual(error, .terminalUnavailable(displayAsleep: true))
    }

    /// Signing in bypasses `createSession` entirely, so it too needs its own wake.
    func testOpenSignInSessionWakesASleepingDisplay() {
        let (store, _, waker) = makeStore(drawable: false, wakeSucceeds: true)
        let account = AgentAccount(
            agent: .claude, displayName: "Work",
            home: URL(fileURLWithPath: "/tmp/claude-work")
        )
        _ = store.openSignInSession(
            for: account, in: tmp.path,
            using: LoginInvocation(command: "claude", inject: nil)
        )
        XCTAssertEqual(waker.calls, 1)
    }

    /// Restart Terminal on an inert tab. Reachable while the display is asleep — that is
    /// precisely the state that produced the inert tab in the first place.
    func testRespawnWakesASleepingDisplay() {
        let (store, _, waker) = makeStore(drawable: true, wakeSucceeds: true)
        let session = store.newSession(in: tmp)
        (store.display as? MutableDisplay)?.set(false)
        _ = store.respawnSurface(for: session.id)
        XCTAssertEqual(waker.calls, 1)
    }

    func testRespawnStillReportsDisplayAsleepWhenTheWakeFails() {
        let provider = StubProvider()
        retainedProviders.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        let display = MutableDisplay(true)
        store.display = display
        store.displayWaker = Waker(succeeds: false)
        let session = store.newSession(in: tmp)
        display.set(false)
        XCTAssertEqual(store.respawnSurface(for: session.id), .displayAsleep)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `XCTAssertEqual failed: ("0") is not equal to ("1")` on each wake assertion, because those sites still read `canCreateTerminal`.

- [ ] **Step 3: Implement**

Three single-line condition changes. In each case **only** the `guard` condition changes; the body stays exactly as it is.

- `respawnSurface(for:)`: `guard canCreateTerminal else {` → `guard ensureTerminalCreatable() else {`
- `createSession(agent:in:at:account:)`: `guard canCreateTerminal else {` → `guard ensureTerminalCreatable() else {`
- `openSignInSession(for:in:using:)`: `guard canCreateTerminal else {` → `guard ensureTerminalCreatable() else {`

Verify with `rg -n 'guard canCreateTerminal' Sources/` that **no** occurrences remain.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/DisplayWakeTests.swift
git commit -m "feat: wake the display on the remaining three creation paths

codex and sign-in each bypass newSession(in:) and need their own wake,
the same way they each needed their own guard. Respawn too: a display
asleep is exactly the state that produced the inert tab being restarted."
```

---

### Task 4: Wire the real waker in, and detect its removal

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`convenience init(ghostty:...)` ~line 1176, beside `display = DisplayState()`)
- Test: `Tests/FlightDeckTests/DisplayWakeTests.swift` (extend)

**Interfaces:**
- Consumes: `DisplayWaker` from Task 1, `displayWaker` from Task 2.
- Produces: the feature, live in production.

- [ ] **Step 1: Write the failing test**

Append to `DisplayWakeTests`:

```swift
    /// The wiring that makes the wake real, mirroring `testTheRealProbeIsWiredIn`. Deleting
    /// the assignment in `convenience init` is otherwise undetectable: the inert default
    /// silently turns every sleeping display back into a refusal, and no test fails.
    func testTheRealWakerIsWiredIn() {
        let store = SessionStore(ghostty: nil, persistence: nil)
        XCTAssertTrue(store.displayWaker is DisplayWaker)
    }

    /// The waker must poll the same probe the guard reads. Wired to a default-constructed
    /// `DisplayState()` instead, it would answer about a different display on a multi-display
    /// Mac, and the two could disagree indefinitely.
    func testTheWiredWakerPollsTheStoresOwnProbe() throws {
        let store = SessionStore(ghostty: nil, persistence: nil)
        let waker = try XCTUnwrap(store.displayWaker as? DisplayWaker)
        XCTAssertTrue(waker.display is DisplayState)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `XCTAssertTrue failed`, because `displayWaker` is still `NeverWakingDisplay`.

- [ ] **Step 3: Implement**

In `convenience init(ghostty:...)`, immediately after the existing `display = DisplayState()` line, add:

```swift
        // Beside `display` and load-bearing in the same way: the default waker is inert, so
        // without this line every sleeping display is a refusal again and no test notices.
        // `DisplayWakerTests` covers the waker; `testTheRealWakerIsWiredIn` covers this line.
        // Built around the probe just assigned, so the thing that decides "drawable" and the
        // thing that waits for it can never be asking about different displays.
        displayWaker = DisplayWaker(display: display)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, whole suite green (~1962 tests plus the new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/DisplayWakeTests.swift
git commit -m "feat: wire the real display waker into the production store

Built around the store's own probe so the thing that decides drawable and
the thing that waits for it cannot disagree on a multi-display Mac.

testTheRealWakerIsWiredIn is the detector, mirroring the one that guards
the display probe's own injection."
```

---

### Task 5: Build for iOS, and record the outcome

**Files:**
- Modify: `docs/superpowers/HANDOFF-2026-08-31-display-sleep.md`

- [ ] **Step 1: Confirm both platforms build**

Run: `./scripts/build.sh 2>&1 | tail -5` then `./scripts/build-ios.sh 2>&1 | tail -5`
Expected: both succeed. Nothing here touches `Sources/FlightDeckMobile`, but the handoff's own bar was "unit tests plus iOS build green".

- [ ] **Step 2: Update the handoff**

Replace the "Direction: spike C, fall back to B" section's **B** subsection with the measured outcome: the spike's four latencies, that a locked Mac wakes and forks, that B is implemented, and that the guard remains for wakes that fail. Leave the C subsection as the record of why C is blocked. Update "What is live in `/Applications` right now" to note the wake is on `display-wake`, not yet swapped in.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/HANDOFF-2026-08-31-display-sleep.md
git commit -m "docs: record the display-wake outcome in the handoff"
```

---

## Manual verification (run with Nate — not by a subagent)

The one thing the suite cannot assert is a real `login` forked against a real drawable.

1. `./scripts/build.sh`, then swap in via `scripts/swap-release.sh` **detached** — it SIGKILLs the app, so it must not run in the foreground of a session that needs to survive.
2. **Send a `PushNotification` ~10s before sleeping the display.**
3. `pmset displaysleepnow`; wait ~5s for the auto-lock; confirm `CGDisplayIsActive` is false.
4. Tap `+` on the phone.
5. Assert **per-tab**: the new session id in `sessions.json` has a `/usr/bin/login` child of the Flight Deck pid, with `zsh` and the agent beneath it. **Never a net shell count** — a concurrent close corrupts it.

Expect the screen to light up for a moment as the tab is created. That is the feature.
