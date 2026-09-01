# Display-Drawable Guard and Terminal Respawn Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop creating tabs that can never run, and make an already-inert tab repairable.

**Architecture:** With the display asleep libghostty has no drawable, so it returns a `SurfaceView` but never forks a shell — the tab is inert from birth and permanently so. This adds a display-drawable seam, refuses creation up front when it cannot succeed, exposes `SurfaceProcessRegistry` as the health signal, and adds a respawn that *replaces* the inert surface.

**Tech Stack:** Swift 6, SwiftUI, CoreGraphics, XCTest. macOS only.

**Spec:** `docs/superpowers/specs/2026-08-29-diagnostics-query-interface-design.md` §1.1, §5, §8.1

**Supersedes `e51c56a`**, which guarded a condition that cannot occur. Task 1 below *amends*
`f28b6b0` rather than adding to it.

## Global Constraints

- Shared parent checkout, concurrent sessions: NEVER `git stash`, `git checkout .`, or revert anything you did not write. A commit was already lost to a race here — check `git status` first.
- In a worktree use ordinary file edit tools, NOT `qartez_*` mutators; there they report success while writing to the main checkout.
- **Nothing here goes in `Sources/FleetKit`** — it may import only `Foundation`, `Network`, `Security` and compiles for iOS; `CoreGraphics` there breaks `build-ios.sh`.
- **Do NOT change `newSession(in:)`'s return type.** Making it `Session?` broke 340 tests across 43 classes, because nearly every fixture builds a store with a nil-returning `SurfaceProvider`. The file already has a refusal convention that avoids this — see Task 2.
- Tests: `./scripts/test-unit.sh` (whole suite, no filter flag, ~1950 tests, ~90s) and `./scripts/build-ios.sh`.
- Do not run `./scripts/smoke.sh` — it steals focus ~40s a run.
- Do NOT edit `~/Library/Application Support/Flight Deck/sessions.json`; it is live state for ~40 sessions.
- Line numbers drift; locate by content.

---

### Task 1: Amend the seam — ask whether the display is drawable

`f28b6b0` added `ScreenLockInspecting`, which asks the wrong question: lock is a confounder, and a tab created 19s after lock with the display on came up healthy. The predicate that actually discriminates is whether the display is drawable.

**Files:**
- Rename: `Sources/FlightDeck/ScreenLock.swift` → `Sources/FlightDeck/DisplayState.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (the `screenLock` property, ~`:130`)
- Rename: `Tests/FlightDeckTests/ScreenLockTests.swift` → `Tests/FlightDeckTests/DisplayStateTests.swift`

**Interfaces:**
- Produces: `protocol DisplayInspecting: Sendable { var isDrawable: Bool { get } }`, `struct DisplayState: DisplayInspecting`, and `SessionStore.display: DisplayInspecting` — a `var` defaulting to `DisplayState()`. Tasks 2 and 3 both read `display.isDrawable`.
- Removes: `ScreenLockInspecting`, `ScreenLock`, `SessionStore.screenLock`. Nothing else references them yet.

- [ ] **Step 1: Write the failing test**

Replace the contents of the renamed test file:

```swift
import XCTest
@testable import FlightDeck

final class DisplayStateTests: XCTestCase {
    /// The seam exists so the store can be tested on both sides of a condition that is
    /// otherwise a property of the machine running the suite.
    func testAStubReportsWhateverItIsToldTo() {
        struct Stub: DisplayInspecting { var isDrawable: Bool }
        XCTAssertTrue(Stub(isDrawable: true).isDrawable)
        XCTAssertFalse(Stub(isDrawable: false).isDrawable)
    }

    /// The real one must answer without throwing or hanging. Its VALUE is not asserted: the
    /// suite runs both with a live display and headless, and pinning either would make this
    /// fail in the other environment.
    func testTheRealInspectorAnswers() {
        _ = DisplayState().isDrawable
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `cannot find 'DisplayInspecting' in scope`.

- [ ] **Step 3: Implement**

`Sources/FlightDeck/DisplayState.swift`, replacing `ScreenLock.swift` entirely:

```swift
import CoreGraphics
import Foundation

/// Whether the main display can currently be drawn to.
///
/// Injected as a protocol for the same reason `ProcessInspecting` is: the answer is a property
/// of the machine running the suite, so a test that needs the other value has no way to get one.
///
/// **This is the precondition for creating a terminal, and it is not about the screen lock.**
/// Established by controlled trial (spec §1.1): with the display asleep libghostty returns a
/// `SurfaceView` but never forks a shell, so the tab is inert from birth — no `login`, no
/// `claude`, no status file. Lock merely correlates, because it usually precedes display sleep;
/// a tab created 19s after lock with the display still on came up healthy.
///
/// CoreGraphics says why, in its own header: `CGDisplayIsActive` means "connected, awake, and
/// available for **drawing**", and `CGDisplayIsAsleep` is true when the display is asleep "and
/// is therefore **not drawable**". libghostty needs that drawable.
protocol DisplayInspecting: Sendable {
    var isDrawable: Bool { get }
}

struct DisplayState: DisplayInspecting {
    /// `CGDisplayIsActive` rather than `!CGDisplayIsAsleep`: they are not complements. A
    /// display that is off, disconnected, or in mirroring teardown is inactive without being
    /// asleep, and every one of those is equally unable to back a surface. Active is the
    /// narrower, safer question for a caller about to decide whether creation can succeed.
    ///
    /// `boolean_t` is a `UInt32`, hence the explicit comparison.
    var isDrawable: Bool { CGDisplayIsActive(CGMainDisplayID()) != 0 }
}
```

In `SessionStore.swift`, replace the `screenLock` property:

```swift
    /// Injected for the reason `processInspector` is — see `DisplayInspecting`.
    var display: DisplayInspecting = DisplayState()
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS. Then `rg -n "ScreenLock|screenLock" Sources Tests` — expected: no hits.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/FlightDeck Tests/FlightDeckTests
git commit -m "refactor: ask whether the display is drawable, not whether the screen is locked"
```

---

### Task 2: Refuse to create a terminal that cannot fork

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexProcessTransport.swift` (the `AgentLaunchError` enum)
- Modify: `Sources/FlightDeck/SessionStore.swift` — `newSession(in:)`
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` — the `.newSession` case
- Test: `Tests/FlightDeckTests/DisplayDrawableGuardTests.swift`

**Interfaces:**
- Consumes: `SessionStore.display` (Task 1).
- Produces: `AgentLaunchError.terminalUnavailable(displayAsleep: Bool)`; `SessionStore.canCreateTerminal: Bool` — **`provider == nil || display.isDrawable`**, see Step 4 for why the provider clause is mandatory. Phone error code `"terminal_unavailable"`.
- Reuses: `StubProvider` from `Tests/FlightDeckTests/PhonePromptDispatchTests.swift`; lift it to a shared test helper rather than writing a second.

**The refusal convention already exists — use it, do not invent one.** `newSession(in:)` returns
a NON-optional `Session`, and its existing `launchAccount` failure path refuses like this:

```swift
case .failure(let error):
    launchFailureReporter.report(error)
    return Session(title: "", workingDirectory: url.path)   // never inserted
```

Refuse the same way. **Do not make the return type optional** — that broke 340 tests.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class DisplayDrawableGuardTests: XCTestCase {
    private final class Reporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }
    private struct Display: DisplayInspecting { var isDrawable: Bool }
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// A provider is REQUIRED for these tests: `canCreateTerminal` is deliberately permissive
    /// when there is none, because the drawable is libghostty's requirement and the suite's
    /// fixtures create sessions with `provider: nil`. `StubProvider` (lifted from
    /// `PhonePromptDispatchTests`) returns nil from `makeSurface` — a provider that is present
    /// but makes no surface, which is what production looks like to this guard.
    private func makeStore(drawable: Bool) -> (SessionStore, Reporter) {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        let reporter = Reporter()
        store.launchFailureReporter = reporter
        store.display = Display(isDrawable: drawable)
        return (store, reporter)
    }

    /// The bug: a tab was created, persisted and broadcast with no terminal and no error.
    /// Refused BEFORE creation, so no corpse exists to clean up.
    func testCreationIsRefusedWhenTheDisplayCannotBeDrawnTo() {
        let (store, reporter) = makeStore(drawable: false)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(reporter.reported, [.terminalUnavailable(displayAsleep: true)])
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty,
                      "a tab that cannot get a terminal must never be created")
    }

    /// The guard must not fire in the ordinary case; the suite's own fixtures depend on it.
    func testCreationProceedsWhenTheDisplayIsDrawable() {
        let (store, reporter) = makeStore(drawable: true)
        _ = store.newSession(in: tmp)
        XCTAssertTrue(reporter.reported.isEmpty)
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }

    func testCanCreateTerminalMirrorsTheDisplayWhenAProviderExists() {
        XCTAssertFalse(makeStore(drawable: false).0.canCreateTerminal)
        XCTAssertTrue(makeStore(drawable: true).0.canCreateTerminal)
    }

    /// The escape hatch the whole suite leans on, pinned so nobody "tidies" it away: with no
    /// provider there is no libghostty, so the drawable is irrelevant and creation proceeds.
    func testWithNoProviderTheGuardDoesNotApply() {
        let store = SessionStore(provider: nil, persistence: nil)
        store.display = Display(isDrawable: false)
        XCTAssertTrue(store.canCreateTerminal)
        _ = store.newSession(in: tmp)
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 1)
    }

    /// The message names the cause, because the cause is invisible and the fix is physical.
    func testTheMessageNamesTheDisplay() {
        XCTAssertEqual(
            AgentLaunchError.terminalUnavailable(displayAsleep: true).errorDescription,
            "Flight Deck could not open a terminal because this Mac's display is asleep. "
            + "Wake it and try again.")
        XCTAssertEqual(
            AgentLaunchError.terminalUnavailable(displayAsleep: false).errorDescription,
            "Flight Deck could not open a terminal for this session.")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — no `terminalUnavailable` case, no `canCreateTerminal`.

- [ ] **Step 3: Add the error case**

In the `AgentLaunchError` enum:

```swift
    /// No terminal could be opened. `displayAsleep` is carried because it is the cause we have
    /// actually observed and the only one with a physical fix — libghostty needs a drawable,
    /// and a sleeping or inactive display is not one. See spec §1.1.
    case terminalUnavailable(displayAsleep: Bool)
```

and in `errorDescription`:

```swift
        case .terminalUnavailable(let displayAsleep):
            displayAsleep
                ? "Flight Deck could not open a terminal because this Mac's display is asleep. "
                  + "Wake it and try again."
                : "Flight Deck could not open a terminal for this session."
```

- [ ] **Step 4: Add the precondition**

In `SessionStore`, beside the other small computed helpers:

```swift
    /// Whether a terminal can be created *right now*. A precondition, deliberately: creating
    /// and then discovering the failure is what produced tabs that looked real on the sidebar
    /// and on the phone while being permanently inert.
    ///
    /// **Gated on having a provider, and that is load-bearing, not a convenience.** The
    /// drawable is a requirement of *libghostty*, which is only involved when a provider
    /// exists. Nearly every fixture in the suite builds a store with `provider: nil`, and those
    /// fixtures create sessions and assert on them; without this clause a suite run that
    /// happened to start while the display was asleep would refuse every one of them and fail
    /// wholesale — the same shape of self-inflicted breakage that the `Session?` return type
    /// caused in the superseded plan, arriving by a different route.
    var canCreateTerminal: Bool { provider == nil || display.isDrawable }
```

In `newSession(in:)`, as the FIRST statement — before `launchAccount`, before any mutation:

```swift
        guard canCreateTerminal else {
            launchFailureReporter.report(.terminalUnavailable(displayAsleep: true))
            // Un-inserted, exactly as the `launchAccount` failure path below does. The return
            // type stays non-optional on purpose: making it `Session?` broke 340 tests, because
            // nearly every fixture in the suite builds a store with a nil-returning provider.
            return Session(title: "", workingDirectory: url.path)
        }
```

- [ ] **Step 5: Give the phone a truthful refusal**

In `FleetService.swift`'s `.newSession` case, guard before delegating, in BOTH branches (the
plain `+` tap and the agent/account variant):

```swift
            guard store.canCreateTerminal else {
                return .err(cid: cid, code: "terminal_unavailable")
            }
```

Place it after the `projectPath` lookup — an unknown project should still say so.

- [ ] **Step 6: Run to verify it passes**

Run: `./scripts/test-unit.sh && ./scripts/build-ios.sh`
Expected: PASS, iOS build green. **Run this at least once with the display actually asleep**
(`pmset displaysleepnow`, then leave the Mac alone) — that is the condition the provider clause
exists to survive, and a run with the display awake cannot prove it. If any pre-existing test
fails, report it rather than mass-editing fixtures: it means the guard is reaching fixtures it
should not.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck Tests/FlightDeckTests/DisplayDrawableGuardTests.swift
git commit -m "fix: refuse a terminal the display cannot back, and say why"
```

---

### Task 3: Registry-backed health, and respawn

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Modify: `Sources/FlightDeck/SessionSidebar.swift` (row `.contextMenu`, ~`:275`)
- Test: `Tests/FlightDeckTests/RespawnSurfaceTests.swift`

**Interfaces:**
- Consumes: `SessionStore.display`, `canCreateTerminal`, `AgentLaunchError.terminalUnavailable`.
- Produces: `SessionStore.hasShellProcess(for: UUID) -> Bool`; `enum RespawnOutcome: Equatable { case respawned, alreadyRunning, displayAsleep, unknownSession, failed }`; `@discardableResult func respawnSurface(for id: UUID) -> RespawnOutcome`. Plan 2 maps the outcomes onto HTTP statuses.

**The health signal is the registry, not the surface.** `SurfaceProcessRegistry.process(for:)`
returns the shell libghostty forked. It is empty for all three observed failures and populated
for all three healthy tabs. `surfaces[id]` is useless here: it is non-nil even for an inert tab,
because `makeSurfaceView` returns a non-optional and its init is non-failable.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class RespawnSurfaceTests: XCTestCase {
    private struct Display: DisplayInspecting { var isDrawable: Bool }
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    private func store(drawable: Bool) -> SessionStore {
        let s = SessionStore(provider: nil, persistence: nil)
        s.display = Display(isDrawable: drawable)
        return s
    }

    /// Refused while the display cannot be drawn to — retrying there is exactly how the inert
    /// tab was produced in the first place.
    func testRefusesWhenTheDisplayCannotBeDrawnTo() {
        let s = store(drawable: false)
        let id = s.seedInertSession(in: tmp)
        XCTAssertEqual(s.respawnSurface(for: id), .displayAsleep)
    }

    func testUnknownSessionIsReportedAsSuch() {
        XCTAssertEqual(store(drawable: true).respawnSurface(for: UUID()), .unknownSession)
    }

    /// The discrimination that matters, and the one no existing test makes: an inert tab HAS a
    /// surface. Only the registry tells the two apart.
    func testHealthIsTheRegistryNotTheSurface() {
        let s = store(drawable: true)
        let id = s.seedInertSession(in: tmp)
        XCTAssertFalse(s.hasShellProcess(for: id))
    }
}
```

`seedInertSession(in:)` must produce a tab with no registry entry. Build it via `restore` of a
one-session snapshot into a store whose provider is nil — `restore` deliberately keeps such
tabs, and Task 2's guard does not apply to it. Match `SessionSnapshot`'s real initialiser in
`Sources/FlightDeck/SessionPersistence.swift`; its `Entry`'s first three stored properties are
`id`, `title`, `workingDirectory`, and the rest default.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — no `respawnSurface`, no `hasShellProcess`.

- [ ] **Step 3: Implement**

```swift
    /// Whether this tab's terminal actually forked a shell.
    ///
    /// **Not `surfaces[id] != nil`.** `makeSurfaceView` returns a non-optional and its init is
    /// non-failable, so a surface always exists — including for a tab that is inert because the
    /// display was asleep when it was born. The registry is what knows a child was forked, and
    /// it discriminates every observed case correctly. See spec §1.1.
    func hasShellProcess(for id: UUID) -> Bool { processRegistry.process(for: id) != nil }

    /// The outcome of trying to give an existing tab a working terminal. Distinguished rather
    /// than boolean because each sends the reader somewhere different, and plan 2 maps them
    /// onto HTTP statuses.
    enum RespawnOutcome: Equatable {
        case respawned, alreadyRunning, displayAsleep, unknownSession, failed
    }

    /// Replaces an inert terminal with a working one.
    ///
    /// *Replaces*, not fills: the broken tab already holds a `SurfaceView`: it just has no
    /// drawable behind it and never forked a child. Discarding it is safe precisely because
    /// there is no child process to orphan.
    @discardableResult
    func respawnSurface(for id: UUID) -> RespawnOutcome {
        guard let at = locate(id) else { return .unknownSession }
        let session = repos[at.repo].sessions[at.session]
        // Ordered before the display check deliberately: "it is already working" is true and
        // more useful regardless of what the display is doing.
        guard !hasShellProcess(for: id) else { return .alreadyRunning }
        guard canCreateTerminal else {
            launchFailureReporter.report(.terminalUnavailable(displayAsleep: true))
            return .displayAsleep
        }

        // Drop the inert view and its (absent) registry record before rebuilding, so the new
        // fork is contested by exactly one claimant.
        surfaces[id] = nil
        _ = processRegistry.forget(id)

        var config = Ghostty.SurfaceConfiguration()
        config.command = preferences?.resolvedShell() ?? ShellResolver.resolve()
        config.workingDirectory = session.transcriptDirectory
        // Adapter and options resolved exactly as `newSession(in:)` does: `launchCommand` takes
        // a NON-optional `AgentOptions`, and the adapter comes from the tab's instance, not
        // from `AgentID`.
        let adapter = adapter(for: instance(for: session))
        let options = options(for: session.agent, project: session.workingDirectory)
        config.initialInput = adapter.launchCommand(adapter.binding(for: session), session, options)
        let orphaned = accountIsMissing(for: session)
        config.environmentVariables =
            preferences?.sessionEnvironment(for: orphaned ? nil : account(for: session)) ?? [:]

        guard let surface = processRegistry.record(for: id, around: { provider?.makeSurface(config) })
        else {
            launchFailureReporter.report(.terminalUnavailable(displayAsleep: false))
            return .failed
        }
        surfaces[id] = surface
        // Same ordering and reason as `insertSession`: before anything is typed, so the child
        // is not left talking to libghostty's placeholder 800x600 grid.
        report(terminalSize, to: id)
        provider?.tick()
        if !orphaned { startWatching(tabID: id) }
        return .respawned
    }
```

- [ ] **Step 4: Add the context-menu item**

In `SessionSidebar.swift`'s row `.contextMenu`, above `Button("Close Session")`:

```swift
            // Shown only for a tab whose terminal never forked a shell — the only tab it can
            // help. A menu item that is usually a no-op teaches people to ignore it.
            if !store.hasShellProcess(for: session.id) {
                Button("Restart Terminal") { store.respawnSurface(for: session.id) }
            }
```

- [ ] **Step 5: Run to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck Tests/FlightDeckTests/RespawnSurfaceTests.swift
git commit -m "feat: give an inert terminal a way back, keyed on the shell registry"
```

---

### Task 4: Verify against the live specimen

Not a code change. `session 169` (`AF1340C0-19FA-435C-B6AD-19DCFFE7B654`) in the flight-deck
project is inert right now and is the reason this plan exists.

- [ ] **Step 1: Confirm it is still in that state**

```bash
python3 -c "
import json, os
d=json.load(open(os.path.expanduser('~/Library/Application Support/Flight Deck/sessions.json')))
t=[s for s in d['sessions'] if s['id']=='AF1340C0-19FA-435C-B6AD-19DCFFE7B654']
print(t[0] if t else 'gone — reproduce: pmset displaysleepnow, then create from the phone')
print('registry entry:', d.get('processes',{}).get('AF1340C0-19FA-435C-B6AD-19DCFFE7B654'))
"
```

- [ ] **Step 2: Build and launch in place**

```bash
./scripts/build.sh
```

Launch the Debug build **from `DerivedData`**. Do NOT run `scripts/swap-release.sh` — it
SIGKILLs the running app and every session under it, including the one doing this work.

- [ ] **Step 3: Check four behaviours**

1. `session 169`'s context menu offers **Restart Terminal**; healthy tabs do not.
2. With the display asleep, Restart Terminal refuses and reports the display, creating nothing.
3. With the display awake, Restart Terminal replaces the inert surface: a shell forks, an agent
   appears, and the status glyph shows within one registry tick.
4. With the display asleep, creating a session from the phone is refused with
   `terminal_unavailable` and **no tab appears**.
