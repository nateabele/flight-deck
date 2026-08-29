# Surface Failure and Respawn Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a failed terminal creation from producing a silent corpse tab, and make a surfaceless tab repairable instead of permanently dead.

**Architecture:** `insertSession` currently treats `provider?.makeSurface` returning nil as benign — it creates, persists and broadcasts the tab anyway, and `surfaces[id]` is written exactly once so the tab can never recover. This adds a screen-lock seam, reports the failure through the existing launch-failure channel, rolls back the *creation* path (leaving `restore` untouched), and adds a `respawnSurface(for:)` that rebuilds a terminal for a tab that already exists.

**Tech Stack:** Swift 6, SwiftUI, AppKit, CoreGraphics, XCTest. macOS only.

**Spec:** `docs/superpowers/specs/2026-08-29-diagnostics-query-interface-design.md` (§8.1)

This is **plan 1 of 2** for that spec. It ships on its own and fixes a live bug. The HTTP
diagnostics interface (§3-§7) is a separate plan and depends on `respawnSurface(for:)` existing.

## Global Constraints

- Shared checkout, concurrent sessions: NEVER `git stash`, `git checkout .`, or revert anything you did not write. Check `git status` first.
- If working in a worktree, use ordinary file edit tools — NOT `qartez_*` mutators; in a worktree they report success while writing to the main checkout.
- `Sources/FleetKit` may import only `Foundation`, `Network`, `Security` (enforced by `build-ios.sh`). **Nothing in this plan belongs in FleetKit** — it all needs `SessionStore` and AppKit.
- Tests: `./scripts/test-unit.sh` (whole headless suite, no filter flag, ~1836 tests, ~90s). Also run `./scripts/build-ios.sh` after any FleetKit-adjacent change.
- Do NOT run `./scripts/smoke.sh` — it steals focus for ~40s a run.
- Do not modify `~/Library/Application Support/Flight Deck/sessions.json`; it is live state for ~39 running sessions.

---

### Task 1: A screen-lock seam

The cause of the live bug: `makeSurface` needs the window server, and a locked login session has none. The store must be able to ask, and tests must be able to lie.

**Files:**
- Create: `Sources/FlightDeck/ScreenLock.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (add the injected property near `processInspector`, ~`:115`)
- Test: `Tests/FlightDeckTests/ScreenLockTests.swift`

**Interfaces:**
- Produces: `protocol ScreenLockInspecting { var isLocked: Bool { get } }`, `struct ScreenLock: ScreenLockInspecting`, and `SessionStore.screenLock: ScreenLockInspecting` (a `var`, default `ScreenLock()`, so tests assign a stub). Tasks 2 and 3 both read it.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ScreenLockTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ScreenLockTests: XCTestCase {
    /// The seam exists so the store can be tested on both sides of a condition that is
    /// otherwise a property of the machine running the suite.
    func testAStubReportsWhateverItIsToldTo() {
        struct Stub: ScreenLockInspecting { var isLocked: Bool }
        XCTAssertTrue(Stub(isLocked: true).isLocked)
        XCTAssertFalse(Stub(isLocked: false).isLocked)
    }

    /// The real one must answer without throwing or hanging. Its VALUE is not asserted:
    /// the suite runs both locked (CI, no session) and unlocked (a desk), and pinning
    /// either would make this test fail on the other.
    func testTheRealInspectorAnswers() {
        _ = ScreenLock().isLocked
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `cannot find 'ScreenLockInspecting' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/FlightDeck/ScreenLock.swift`:

```swift
import CoreGraphics
import Foundation

/// Whether this login session's screen is locked.
///
/// Injected as a protocol for the same reason `ProcessInspecting` is: the answer is a
/// property of the machine running the suite, so a test that needs the other value has no
/// way to get one.
///
/// This exists because of a real failure. `Ghostty.SurfaceView` creation needs the window
/// server, and a locked session has none — so a tab created from the phone while the Mac was
/// locked got no terminal, no agent, and no error. See
/// `docs/superpowers/specs/2026-08-29-diagnostics-query-interface-design.md` §1.
protocol ScreenLockInspecting: Sendable {
    var isLocked: Bool { get }
}

struct ScreenLock: ScreenLockInspecting {
    /// `CGSessionCopyCurrentDictionary` rather than a `loginwindow` notification: this is a
    /// question asked at one instant, by a caller that is about to decide whether to create a
    /// surface, not a state worth observing continuously. A nil dictionary means there is no
    /// GUI session at all (a headless test host), which is at least as unable to make a
    /// surface as a locked one — so it reads as locked rather than as unknown.
    var isLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (info["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
```

In `SessionStore.swift`, beside `var processInspector: ProcessInspecting = ProcessTree()`:

```swift
    /// Injected for the reason `processInspector` is — see `ScreenLockInspecting`.
    var screenLock: ScreenLockInspecting = ScreenLock()
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ScreenLock.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/ScreenLockTests.swift
git commit -m "feat: add a screen-lock seam"
```

---

### Task 2: Make a failed terminal loud, and refuse to create a corpse

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexProcessTransport.swift` (the `AgentLaunchError` enum lives here)
- Modify: `Sources/FlightDeck/SessionStore.swift` — `insertSession` (~`:1624`) and `newSession(in:)` (~`:1149`)
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (~`:606`, the `.newSession` case)
- Test: `Tests/FlightDeckTests/SurfaceFailureTests.swift`

**Interfaces:**
- Consumes: `SessionStore.screenLock` (Task 1).
- Produces: `AgentLaunchError.terminalUnavailable(screenLocked: Bool)`. `newSession(in:)` and `newSession(inProject:)` keep their `-> Session?` signature but now return `nil` when no surface was created. The phone's error code for that is `"terminal_unavailable"`.

**The critical distinction:** `insertSession` is shared by creation AND `restore`. Rolling back inside it would make a restore that hits a surface failure **silently drop tabs**, which is far worse than the bug being fixed. So `insertSession` only *reports*; the rollback lives in `newSession(in:)`, which is creation-only.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/SurfaceFailureTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SurfaceFailureTests: XCTestCase {
    private final class Reporter: AgentLaunchFailureReporting {
        var reported: [AgentLaunchError] = []
        func report(_ error: AgentLaunchError) { reported.append(error) }
    }
    private struct Locked: ScreenLockInspecting { var isLocked: Bool }
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// A store with no provider cannot make surfaces — the same end state as a locked screen.
    private func makeStore(locked: Bool) -> (SessionStore, Reporter) {
        let store = SessionStore(provider: nil, persistence: nil)
        let reporter = Reporter()
        store.launchFailureReporter = reporter
        store.screenLock = Locked(isLocked: locked)
        return (store, reporter)
    }

    /// The bug: a tab was created, persisted and broadcast with no terminal and no error.
    func testCreationWithNoSurfaceReportsAndCreatesNoTab() {
        let (store, reporter) = makeStore(locked: true)
        XCTAssertNil(store.newSession(in: tmp))
        XCTAssertEqual(reporter.reported, [.terminalUnavailable(screenLocked: true)])
        XCTAssertTrue(store.repos.flatMap(\.sessions).isEmpty,
                      "a tab with no terminal must not survive creation")
    }

    /// The reason the rollback is NOT inside `insertSession`: restore shares that path, and a
    /// restore that dropped tabs on surface failure would lose the user's whole deck.
    func testRestoreKeepsTabsEvenWhenNoSurfaceCanBeMade() {
        let (store, _) = makeStore(locked: true)
        let snapshot = SessionSnapshot(
            sessions: [.init(workingDirectory: tmp.path, id: UUID(), title: "kept")],
            projects: [.init(path: tmp.path, isCollapsed: false)],
            selectedSessionID: nil, sessionCounter: 1, terminalSize: nil
        )
        _ = store.restore(from: snapshot)
        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.title), ["kept"])
    }

    /// The message has to name the cause, because the cause is invisible and the fix is
    /// physical: unlock the Mac.
    func testTheMessageNamesTheLock() {
        let locked = AgentLaunchError.terminalUnavailable(screenLocked: true).errorDescription
        XCTAssertEqual(locked, "Flight Deck could not open a terminal because the Mac is locked. "
                       + "Unlock it and try again.")
        let other = AgentLaunchError.terminalUnavailable(screenLocked: false).errorDescription
        XCTAssertEqual(other, "Flight Deck could not open a terminal for this session.")
    }
}
```

`SessionSnapshot.Entry`'s first three stored properties are `id`, `title`,
`workingDirectory`; everything after them is optional with a default, so the three-argument
form above compiles. Confirm against `Sources/FlightDeck/SessionPersistence.swift` before
relying on the argument order, and match `SessionSnapshot`'s own initialiser for the outer
literal.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — no `terminalUnavailable` case.

- [ ] **Step 3: Add the error case**

In the `AgentLaunchError` enum:

```swift
    /// No terminal could be created for this session. `screenLocked` is carried because it is
    /// the overwhelmingly common cause and the only one with a physical fix — libghostty needs
    /// the window server, and a locked login session has none.
    case terminalUnavailable(screenLocked: Bool)
```

And in `errorDescription`:

```swift
        case .terminalUnavailable(let screenLocked):
            screenLocked
                ? "Flight Deck could not open a terminal because the Mac is locked. "
                  + "Unlock it and try again."
                : "Flight Deck could not open a terminal for this session."
```

- [ ] **Step 4: Report from `insertSession`, roll back in `newSession`**

In `insertSession`, immediately after `if let surface = created { surfaces[session.id] = surface }`:

```swift
        // Loud, because this used to be silent. A nil surface means no shell was forked, so
        // this tab has no terminal and no agent — and `surfaces[session.id]` is written here
        // and nowhere else, so it never will. Reported rather than rolled back HERE because
        // `restore` shares this path: dropping tabs on surface failure would lose the deck.
        // The creation path handles its own rollback; see `newSession(in:)`.
        if created == nil {
            launchFailureReporter.report(.terminalUnavailable(screenLocked: screenLock.isLocked))
        }
```

In `newSession(in:)`, at the point it currently returns the result of `addSession(...)`, bind it and roll back:

```swift
        let session = addSession(
            /* existing arguments unchanged */
        )
        // A tab with no terminal is a corpse: it looks live on the sidebar and on the phone,
        // can never run an agent, and cannot be repaired without `respawnSurface(for:)`.
        // Creation refuses it outright; the report already went out from `insertSession`.
        guard surfaces[session.id] != nil else {
            closeSession(session.id, recordingHistory: false)
            return nil
        }
        return session
```

`newSession(in:)`'s return type must be `Session?`. If it is currently non-optional, make it
optional and fix every call site the compiler names — `newSession(inProject:)` already returns
`Session?`, so the fleet path needs no change beyond Step 5.

- [ ] **Step 5: Give the phone a truthful error code**

In `FleetService.swift`'s `.newSession` case, the nil return currently answers
`"unknown_project"`, which is now wrong for this cause. Distinguish them:

```swift
        case .newSession(let project, let agent, let accountIndex):
            guard let path = store.projectPath(project) else {
                return .err(cid: cid, code: "unknown_project")
            }
            guard let agent, let accountIndex, let picked = AgentID(rawValue: agent) else {
                // The project resolved above, so a nil here is a terminal that could not be
                // made — usually a locked Mac. Saying "unknown_project" would send the reader
                // to look for a project that is right there.
                guard store.newSession(inProject: project) != nil else {
                    return .err(cid: cid, code: "terminal_unavailable")
                }
                break
            }
```

Apply the same substitution to the agent/account branch below it.

- [ ] **Step 6: Run to verify it passes**

Run: `./scripts/test-unit.sh && ./scripts/build-ios.sh`
Expected: PASS, iOS build green.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck Tests/FlightDeckTests/SurfaceFailureTests.swift
git commit -m "fix: refuse to create a tab with no terminal, and say why"
```

---

### Task 3: `respawnSurface(for:)`

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (new method beside `insertSession`)
- Modify: `Sources/FlightDeck/SessionSidebar.swift` (~`:275-280`, the row context menu)
- Test: `Tests/FlightDeckTests/RespawnSurfaceTests.swift`

**Interfaces:**
- Consumes: `SessionStore.screenLock` (Task 1), `AgentLaunchError.terminalUnavailable` (Task 2).
- Produces: `@discardableResult func respawnSurface(for id: UUID) -> RespawnOutcome` where
  `enum RespawnOutcome: Equatable { case respawned, alreadyRunning, screenLocked, unknownSession, failed }`.
  Plan 2's `POST /tabs/{id}/respawn-surface` maps these to 200/409/409/404/500.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/RespawnSurfaceTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class RespawnSurfaceTests: XCTestCase {
    private struct Locked: ScreenLockInspecting { var isLocked: Bool }
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// Refused while locked, and refused for the RIGHT reason: retrying against a window
    /// server that cannot answer is precisely how the corpse tab was created.
    func testRefusesWhileTheScreenIsLocked() {
        let store = SessionStore(provider: nil, persistence: nil)
        store.screenLock = Locked(isLocked: true)
        let id = store.seedSurfacelessSession(in: tmp)
        XCTAssertEqual(store.respawnSurface(for: id), .screenLocked)
    }

    /// Respawning a tab that already has a terminal would orphan its running agent and leave
    /// two shells writing one transcript.
    func testRefusesWhenASurfaceAlreadyExists() {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        store.screenLock = Locked(isLocked: false)
        guard let session = store.newSession(in: tmp) else {
            return XCTFail("fixture should have produced a live tab")
        }
        XCTAssertEqual(store.respawnSurface(for: session.id), .alreadyRunning)
    }

    func testUnknownSessionIsReportedAsSuch() {
        let store = SessionStore(provider: nil, persistence: nil)
        store.screenLock = Locked(isLocked: false)
        XCTAssertEqual(store.respawnSurface(for: UUID()), .unknownSession)
    }
}
```

`StubProvider` already exists in `Tests/FlightDeckTests/PhonePromptDispatchTests.swift`
(`makeSurface` returns nil, `tick()` empty) — lift it to a shared test helper rather than
writing a second one.

`seedSurfacelessSession(in:)` must produce a tab that HAS no surface, which Task 2's rollback
now prevents via `newSession`. Get one the way production does: restore a one-session snapshot
into a store whose provider is nil, then return that session's id. `restore` deliberately keeps
surfaceless tabs (Task 2, Step 4), which is precisely the state under test.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — no `respawnSurface`.

- [ ] **Step 3: Implement**

```swift
    /// The outcome of trying to give an existing tab a terminal. Distinguished rather than
    /// boolean because each sends the reader somewhere different, and plan 2 maps them onto
    /// HTTP statuses.
    enum RespawnOutcome: Equatable {
        case respawned, alreadyRunning, screenLocked, unknownSession, failed
    }

    /// Builds a terminal for a tab that already exists.
    ///
    /// Nothing else in this type can do that. `surfaces[session.id]` is written in exactly one
    /// place — `insertSession` — with no retry and no lazy creation on select, so before this
    /// existed a tab that lost `makeSurface` was dead for the life of the app. See
    /// `docs/superpowers/specs/2026-08-29-diagnostics-query-interface-design.md` §5.
    @discardableResult
    func respawnSurface(for id: UUID) -> RespawnOutcome {
        guard let at = locate(id) else { return .unknownSession }
        let session = repos[at.repo].sessions[at.session]
        // Ordered before the lock check on purpose: "it is already running" is a true and more
        // useful answer than "the screen is locked", and it is true regardless of the lock.
        guard surfaces[id] == nil else { return .alreadyRunning }
        guard !screenLock.isLocked else {
            launchFailureReporter.report(.terminalUnavailable(screenLocked: true))
            return .screenLocked
        }

        var config = Ghostty.SurfaceConfiguration()
        config.command = preferences?.resolvedShell() ?? ShellResolver.resolve()
        config.workingDirectory = session.transcriptDirectory
        // The launch command, not empty: this is a creation, not a restore. A restored tab is
        // deliberately given an empty input so the shell starts no agent, but a tab being
        // repaired has no agent to preserve and every reason to start one.
        //
        // Adapter and options resolved exactly as `newSession(in:)` does — `launchCommand`
        // takes a non-optional `AgentOptions`, and the adapter comes from the tab's instance,
        // not from `AgentID`. The project here is the tab's own working directory.
        let adapter = adapter(for: instance(for: session))
        let options = options(for: session.agent, project: session.workingDirectory)
        config.initialInput = adapter.launchCommand(adapter.binding(for: session), session, options)
        let orphaned = accountIsMissing(for: session)
        config.environmentVariables =
            preferences?.sessionEnvironment(for: orphaned ? nil : account(for: session)) ?? [:]

        let created = processRegistry.record(for: id) { provider?.makeSurface(config) }
        guard let surface = created else {
            launchFailureReporter.report(.terminalUnavailable(screenLocked: false))
            return .failed
        }
        surfaces[id] = surface
        // Same ordering and the same reason as `insertSession`: before anything is typed, so
        // the child is not talking to libghostty's placeholder 800x600 grid.
        report(terminalSize, to: id)
        provider?.tick()
        if !orphaned { startWatching(tabID: id) }
        return .respawned
    }
```

Verified against `AgentAdapter.launchCommand(_:_:_:)` and `newSession(in:)`: the signature is
`(AgentBinding, Session, AgentOptions) -> String` — `options` is **not** optional — and
`SessionStore.launchFailureReporter` is a settable `var` (`SessionStore.swift:850`), which is
what lets the tests inject a spy.

- [ ] **Step 4: Add the context-menu item**

In `SessionSidebar.swift`'s row `.contextMenu`, above `Button("Close Session")`:

```swift
            // Shown only for a tab that has no terminal — which is the only tab it can help,
            // and a menu item that is usually a no-op teaches people to ignore it.
            if store.surface(for: session.id) == nil {
                Button("Restart Terminal") { store.respawnSurface(for: session.id) }
            }
```

- [ ] **Step 5: Run to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck Tests/FlightDeckTests/RespawnSurfaceTests.swift
git commit -m "feat: give a surfaceless tab a way back"
```

---

### Task 4: Repair the live fixture

Not a code change. `mobile-search` (`0F1AADD6-5C9F-48A2-A2E4-354092D8FAB2`) in the flight-deck
project is surfaceless right now and is the reason this plan exists.

- [ ] **Step 1: Confirm it is still in that state**

```bash
python3 -c "
import json, os
d=json.load(open(os.path.expanduser('~/Library/Application Support/Flight Deck/sessions.json')))
s=[x for x in d['sessions'] if x['title']=='mobile-search']
print(s[0] if s else 'already gone — create a replacement from the phone while the Mac is locked')
"
```

- [ ] **Step 2: Build and launch in place**

```bash
./scripts/build.sh
```

Launch the Debug build **from `DerivedData`**. Do NOT run `scripts/swap-release.sh` — it
SIGKILLs the running app and every session under it.

- [ ] **Step 3: Check the three behaviours**

1. With the Mac **locked**, create a session from the phone: it is refused with a message
   naming the lock, and **no tab appears**.
2. `mobile-search`'s context menu offers **Restart Terminal**; other tabs do not.
3. Unlocked, Restart Terminal gives it a terminal and an agent; its status glyph appears within
   one registry tick.
