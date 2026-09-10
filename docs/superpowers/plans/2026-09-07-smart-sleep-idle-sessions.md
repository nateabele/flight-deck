# Smart Sleep for Idle Sessions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Freeze an idle Flight Deck session's agent process tree (`SIGSTOP`) and tear down its terminal surface to save battery, waking it losslessly (`SIGCONT` + ring replay) the instant it is focused or receives input.

**Architecture:** A pure `SleepPolicy` decides eligibility; an effectful `SessionSleepController` (registered on the shared `WatchClock`) sleeps newly-eligible sessions and wakes them through two seams (local selection, remote `injector(for:)`). Sleep = tear down the ghostty surface (existing detach path) then `kill(-agentPGID, SIGSTOP)`. Wake = `SIGCONT` then rebuild the attach surface, whose ring replay restores the terminal. Signals target the **agent's process group** (distinct from the fd-abduco daemon), resolved in Swift from the daemon pid.

**Tech Stack:** Swift 6 / SwiftUI + AppKit, XCTest, macOS. Darwin `libproc` (`proc_listchildpids`) + `getpgid`/`kill`. Builds on the fd-abduco daemon subsystem.

**Spec:** `docs/superpowers/specs/2026-09-07-smart-sleep-idle-sessions-design.md`

## Global Constraints

- **Depends on fd-abduco (branch `worktree-detach-phase1`), unmerged as of writing.** Execute only after it merges to master. The symbols `DaemonControlling` / `PosixDaemonControl` (`Sources/FlightDeck/DaemonControl.swift`), `SessionDaemon` (`.../SessionDaemon.swift`), `LaunchPlan` (`.../LaunchPlan.swift`) come from that branch.
- **Preconditions before executing (branch was moving at plan time, tip `48fa119`):** confirm the merged signatures of `DaemonControlling` (currently `isLive(_:)->Bool`, `daemonPID(_:)->pid_t?`, `terminate(_:)`), `SessionDaemon.attachCommand(for:)`, and the two `config.command` build sites in `SessionStore.swift` still match the **Interfaces** blocks below; adjust literals if they drifted.
- **Safety rail (non-negotiable):** every process-group signal is guarded on a validated `> 0` live pid, mirroring `DaemonControl.readPID`'s existing guard. A `kill(-0, …)` or `kill(-1, …)` broadcasts to Flight Deck's own group and would freeze the app.
- **Never touch the fd-abduco C sources or wire protocol in this work** (a `MSG_PID` reply is an explicit non-goal); the agent pgid is derived in Swift.
- **Test target:** `./scripts/test-unit.sh` (macOS). It ignores `-only-testing:` and runs the full suite (~8 min) — budget for that; do not investigate "extra" tests running. No `Sources/FlightDeckMobile` changes → no iOS target.
- **Concurrency:** `SessionStore` and its collaborators are `@MainActor`. New controller/policy types are `@MainActor` unless purely value-based (`SleepPolicy` is a plain value type, no isolation).

---

### Task 1: Resolve the agent process group from the daemon pid

**Files:**
- Create: `Sources/FlightDeck/AgentGroupResolver.swift`
- Test: `Tests/FlightDeckTests/AgentGroupResolverTests.swift`

**Interfaces:**
- Produces:
  - `protocol AgentGroupResolving { func agentProcessGroup(daemonPID: pid_t) -> pid_t? }`
  - `struct PosixAgentGroupResolver: AgentGroupResolving`
  - Semantics: returns the agent's pgid (a positive pid) — the daemon's sole direct child, whose pgid equals its own pid — or `nil` if the daemon has no live child.

- [ ] **Step 1: Write the failing test** (`AgentGroupResolverTests.swift`)

```swift
import XCTest
@testable import FlightDeck

final class AgentGroupResolverTests: XCTestCase {
    /// Fork a child that puts itself in its own process group and sleeps; the
    /// resolver must report that child's pgid as the "agent" group for our pid.
    func testResolvesDirectChildProcessGroup() throws {
        var pid: pid_t = 0
        // /bin/sh -c 'exec sleep 5' — setsid so it leads its own group.
        let argv: [String] = ["/usr/bin/setsid", "/bin/sleep", "5"]
        // setsid may be absent on macOS; use a helper that setpgid(0,0)s instead.
        let child = try ForkedChild.spawnOwnGroup(command: "/bin/sleep", args: ["5"])
        defer { child.terminate() }
        pid = child.pid

        let resolver = PosixAgentGroupResolver()
        let pgid = resolver.agentProcessGroup(daemonPID: getpid())
        XCTAssertNotNil(pgid, "should find the forked child of this process")
        XCTAssertEqual(pgid, child.expectedPGID)
        _ = pid
    }

    func testReturnsNilWhenNoChildren() {
        let resolver = PosixAgentGroupResolver()
        // pid 1 (launchd) is not our child; but to assert "no children" deterministically
        // use our own pid only if we truly have none. Instead assert a spawned-then-reaped case.
        let ephemeral = try? ForkedChild.spawnOwnGroup(command: "/usr/bin/true", args: [])
        ephemeral?.waitUntilExit()
        // After exit+reap there is no live child; resolver returns nil.
        XCTAssertNil(resolver.agentProcessGroup(daemonPID: getpid()))
    }
}
```

- [ ] **Step 2: Add the `ForkedChild` test helper** (`Tests/FlightDeckTests/Support/ForkedChild.swift`)

```swift
import Foundation

/// Minimal fork/exec helper for signal/pgid tests: spawns a command in its OWN
/// process group (setpgid(0,0) in the child before exec) so the parent can assert
/// group-targeted behavior. Uses posix_spawn with POSIX_SPAWN_SETPGROUP.
struct ForkedChild {
    let pid: pid_t
    /// With POSIX_SPAWN_SETPGROUP + pgroup 0, the child leads its own group == its pid.
    var expectedPGID: pid_t { pid }

    static func spawnOwnGroup(command: String, args: [String]) throws -> ForkedChild {
        var attr = posix_spawnattr_t(nil)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0) // 0 => new group led by the child
        var pid: pid_t = 0
        let argv = ([command] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let rc = posix_spawn(&pid, command, nil, &attr, argv, environ)
        guard rc == 0 else { throw NSError(domain: "spawn", code: Int(rc)) }
        return ForkedChild(pid: pid)
    }

    func waitUntilExit() { var s: Int32 = 0; waitpid(pid, &s, 0) }
    func terminate() { kill(pid, SIGKILL); var s: Int32 = 0; waitpid(pid, &s, 0) }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `./scripts/test-unit.sh` (full suite; look for `AgentGroupResolverTests`).
Expected: FAIL — `PosixAgentGroupResolver` / `AgentGroupResolving` not defined.

- [ ] **Step 4: Implement `AgentGroupResolver.swift`**

```swift
import Darwin
import Foundation

protocol AgentGroupResolving {
    /// The process group of the agent under `daemonPID` (the daemon's sole direct
    /// child), or nil if the daemon currently has no live child. Always > 0 when non-nil.
    func agentProcessGroup(daemonPID: pid_t) -> pid_t?
}

struct PosixAgentGroupResolver: AgentGroupResolving {
    func agentProcessGroup(daemonPID: pid_t) -> pid_t? {
        guard daemonPID > 0 else { return nil }
        // Direct children only: the daemon forkpty's exactly one child (the agent),
        // which setsid's itself into its own session/group (pgid == pid). node/MCP
        // grandchildren inherit that group, so the direct child's pid IS agentPGID.
        let count = proc_listchildpids(daemonPID, nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let filled = proc_listchildpids(daemonPID, &pids, count * Int32(MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        for raw in pids.prefix(Int(filled)) where raw > 0 {
            // Confirm liveness and read its group; getpgid == pid for a group leader.
            guard kill(raw, 0) == 0 else { continue }
            let pgid = getpgid(raw)
            if pgid > 0 { return pgid }
        }
        return nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS for `AgentGroupResolverTests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/AgentGroupResolver.swift Tests/FlightDeckTests/AgentGroupResolverTests.swift Tests/FlightDeckTests/Support/ForkedChild.swift
git commit -m "feat: resolve agent process group from daemon pid for smart sleep"
```

---

### Task 2: Add `stop`/`cont` to `DaemonControlling` (freeze/wake the agent group)

**Files:**
- Modify: `Sources/FlightDeck/DaemonControl.swift` (protocol `DaemonControlling` ~:11-26; `PosixDaemonControl` ~:31; reuse `readPID` `> 0` guard ~:174)
- Test: `Tests/FlightDeckTests/DaemonControlTests.swift` (extend)

**Interfaces:**
- Consumes: `AgentGroupResolving` (Task 1); existing `readPID(_:) -> pid_t?`, `daemonPID(_:) -> pid_t?`.
- Produces (added to `DaemonControlling`):
  - `func stop(_ id: UUID)` — freeze the agent group: `kill(-agentPGID, SIGSTOP)`.
  - `func cont(_ id: UUID)` — resume: `kill(-agentPGID, SIGCONT)`.
  - Both no-op silently if the daemon pid is missing/`≤ 0`/dead or no agent group resolves.
- `PosixDaemonControl` gains an injected `agentGroupResolver: AgentGroupResolving` (default `PosixAgentGroupResolver()`), and a testable `kill` seam `signal: (pid_t, Int32) -> Int32` (default `Darwin.kill`).

- [ ] **Step 1: Write the failing tests** (append to `DaemonControlTests.swift`)

```swift
func testStopSignalsNegativeAgentGroupWithSIGSTOP() {
    let sig = SignalSpy()
    let control = PosixDaemonControl(
        directory: tempDir,                              // existing test ctor arg
        agentGroupResolver: FixedResolver(pgid: 4242),
        signal: sig.record
    )
    writePidfile(for: idA, pid: 999)                     // existing test helper; daemon alive

    control.stop(idA)

    XCTAssertEqual(sig.calls, [.init(pid: -4242, signal: SIGSTOP)])
}

func testContSignalsNegativeAgentGroupWithSIGCONT() {
    let sig = SignalSpy()
    let control = PosixDaemonControl(directory: tempDir,
                                     agentGroupResolver: FixedResolver(pgid: 4242),
                                     signal: sig.record)
    writePidfile(for: idA, pid: 999)
    control.cont(idA)
    XCTAssertEqual(sig.calls, [.init(pid: -4242, signal: SIGCONT)])
}

func testStopRefusesWhenPgidResolvesNonPositive() {
    let sig = SignalSpy()
    let control = PosixDaemonControl(directory: tempDir,
                                     agentGroupResolver: FixedResolver(pgid: 0),   // the rail
                                     signal: sig.record)
    writePidfile(for: idA, pid: 999)
    control.stop(idA)
    XCTAssertTrue(sig.calls.isEmpty, "must never kill(-0)/kill group 0 — would freeze the app")
}

func testStopNoOpWhenDaemonDead() {
    let sig = SignalSpy()
    let control = PosixDaemonControl(directory: tempDir,
                                     agentGroupResolver: FixedResolver(pgid: 4242),
                                     signal: sig.record)
    // no pidfile written => daemonPID nil
    control.stop(idA)
    XCTAssertTrue(sig.calls.isEmpty)
}

// --- test doubles ---
private struct FixedResolver: AgentGroupResolving {
    let pgid: pid_t
    func agentProcessGroup(daemonPID: pid_t) -> pid_t? { pgid }
}
private final class SignalSpy {
    struct Call: Equatable { let pid: pid_t; let signal: Int32 }
    var calls: [Call] = []
    func record(_ pid: pid_t, _ signal: Int32) -> Int32 { calls.append(.init(pid: pid, signal: signal)); return 0 }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh` (look for the four new `DaemonControl` tests).
Expected: FAIL — `stop`/`cont` not declared; ctor has no `agentGroupResolver`/`signal`.

- [ ] **Step 3: Implement in `DaemonControl.swift`**

Add to the protocol:

```swift
protocol DaemonControlling {
    func isLive(_ id: UUID) -> Bool
    func daemonPID(_ id: UUID) -> pid_t?
    func terminate(_ id: UUID)
    func stop(_ id: UUID)   // freeze agent group
    func cont(_ id: UUID)   // resume agent group
}
```

Add the injected seams to `PosixDaemonControl` (keep existing stored props/init args; add these with defaults):

```swift
private let agentGroupResolver: AgentGroupResolving
private let signal: (pid_t, Int32) -> Int32

init(directory: URL,
     agentGroupResolver: AgentGroupResolving = PosixAgentGroupResolver(),
     signal: @escaping (pid_t, Int32) -> Int32 = { Darwin.kill($0, $1) }) {
    self.directory = directory
    self.agentGroupResolver = agentGroupResolver
    self.signal = signal
}

func stop(_ id: UUID) { signalAgentGroup(id, SIGSTOP) }
func cont(_ id: UUID) { signalAgentGroup(id, SIGCONT) }

/// Resolve the agent pgid from the (validated, live) daemon pid and signal the
/// NEGATIVE pgid so the whole agent tree (claude + node/MCP) is hit but not the daemon.
private func signalAgentGroup(_ id: UUID, _ sig: Int32) {
    guard let daemon = daemonPID(id), daemon > 0 else { return }      // reuses the > 0 rail
    guard let pgid = agentGroupResolver.agentProcessGroup(daemonPID: daemon), pgid > 0 else { return }
    _ = signal(-pgid, sig)
}
```

(If the existing `init` has other stored properties, extend it in place rather than replacing — keep every current argument.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS for the four new tests and all existing `DaemonControlTests`.

- [ ] **Step 5: Live-daemon integration test** (append)

```swift
/// End-to-end against a real forked child in its own group: SIGSTOP then read the
/// process state ('T' = stopped) via `ps`, then SIGCONT and confirm it runs ('S'/'R').
func testStopThenContAgainstLiveChild() throws {
    let child = try ForkedChild.spawnOwnGroup(command: "/bin/sleep", args: ["30"])
    defer { child.terminate() }
    let control = PosixDaemonControl(directory: tempDir,
                                     agentGroupResolver: FixedResolver(pgid: child.expectedPGID))
    writePidfile(for: idA, pid: getpid())   // daemon "alive"
    control.stop(idA)
    XCTAssertEqual(processState(child.pid), "T")   // stopped
    control.cont(idA)
    XCTAssertNotEqual(processState(child.pid), "T")
}

private func processState(_ pid: pid_t) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "state=", "-p", "\(pid)"]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return String(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1))
}
```

- [ ] **Step 6: Run + commit**

```bash
./scripts/test-unit.sh
git add Sources/FlightDeck/DaemonControl.swift Tests/FlightDeckTests/DaemonControlTests.swift
git commit -m "feat: DaemonControl.stop/cont freeze the agent group with the >0 rail"
```

---

### Task 3: `SleepPolicy` — pure eligibility

**Files:**
- Create: `Sources/FlightDeck/SleepPolicy.swift`
- Test: `Tests/FlightDeckTests/SleepPolicyTests.swift`

**Interfaces:**
- Produces:
  - `struct SleepCandidate { let id: UUID; let activity: SessionActivity; let isSelected: Bool; let reportsBackgroundWork: Bool; let hasLiveDescendants: Bool; let idleSince: Date?; let isDaemonized: Bool; let isAsleep: Bool }`
  - `enum SleepDecision: Equatable { case sleep; case ineligible(String) }`
  - `struct SleepPolicy { let idleThreshold: TimeInterval; func evaluate(_ c: SleepCandidate, now: Date) -> SleepDecision }`
- Consumes: `SessionActivity` (`Sources/FlightDeck/SessionStatus.swift`, cases `.idle/.busy/.waiting`).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlightDeck

final class SleepPolicyTests: XCTestCase {
    let policy = SleepPolicy(idleThreshold: 600)
    let now = Date()
    func base(_ f: (inout SleepCandidate) -> Void) -> SleepCandidate {
        var c = SleepCandidate(id: UUID(), activity: .idle, isSelected: false,
                               reportsBackgroundWork: false, hasLiveDescendants: false,
                               idleSince: now.addingTimeInterval(-3600),
                               isDaemonized: true, isAsleep: false)
        f(&c); return c
    }

    func testEligibleWhenIdleLongEnoughUnfocusedNoBgWork() {
        XCTAssertEqual(policy.evaluate(base { _ in }, now: now), .sleep)
    }
    func testBusyNeverSleeps() {
        XCTAssertEqual(policy.evaluate(base { $0.activity = .busy }, now: now), .ineligible("busy"))
    }
    func testWaitingIsEligible() {
        XCTAssertEqual(policy.evaluate(base { $0.activity = .waiting }, now: now), .sleep)
    }
    func testSelectedNeverSleeps() {
        XCTAssertEqual(policy.evaluate(base { $0.isSelected = true }, now: now), .ineligible("selected"))
    }
    func testReportedBackgroundWorkBlocks() {
        XCTAssertEqual(policy.evaluate(base { $0.reportsBackgroundWork = true }, now: now), .ineligible("background-work"))
    }
    func testLiveDescendantsBlock() {
        XCTAssertEqual(policy.evaluate(base { $0.hasLiveDescendants = true }, now: now), .ineligible("background-work"))
    }
    func testBelowThresholdWaits() {
        let c = base { $0.idleSince = now.addingTimeInterval(-60) }
        XCTAssertEqual(policy.evaluate(c, now: now), .ineligible("not-idle-long-enough"))
    }
    func testNilIdleSinceIneligible() {
        XCTAssertEqual(policy.evaluate(base { $0.idleSince = nil }, now: now), .ineligible("not-idle-long-enough"))
    }
    func testNonDaemonizedIneligible() {
        XCTAssertEqual(policy.evaluate(base { $0.isDaemonized = false }, now: now), .ineligible("no-daemon"))
    }
    func testAlreadyAsleepIsNoOp() {
        XCTAssertEqual(policy.evaluate(base { $0.isAsleep = true }, now: now), .ineligible("already-asleep"))
    }
}
```

- [ ] **Step 2: Run to verify fail** — `./scripts/test-unit.sh` → FAIL (types undefined).

- [ ] **Step 3: Implement `SleepPolicy.swift`**

```swift
import Foundation

struct SleepCandidate {
    let id: UUID
    let activity: SessionActivity
    let isSelected: Bool
    let reportsBackgroundWork: Bool
    let hasLiveDescendants: Bool
    let idleSince: Date?
    let isDaemonized: Bool
    let isAsleep: Bool
}

enum SleepDecision: Equatable { case sleep; case ineligible(String) }

/// Pure eligibility. Order of checks is stable so the `ineligible` reason is deterministic
/// (useful in logs and tests). All predicates must pass for `.sleep`.
struct SleepPolicy {
    let idleThreshold: TimeInterval

    func evaluate(_ c: SleepCandidate, now: Date) -> SleepDecision {
        if c.isAsleep { return .ineligible("already-asleep") }
        if !c.isDaemonized { return .ineligible("no-daemon") }
        if c.isSelected { return .ineligible("selected") }
        if c.activity == .busy { return .ineligible("busy") }
        if c.reportsBackgroundWork || c.hasLiveDescendants { return .ineligible("background-work") }
        guard let since = c.idleSince, now.timeIntervalSince(since) >= idleThreshold else {
            return .ineligible("not-idle-long-enough")
        }
        return .sleep
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./scripts/test-unit.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SleepPolicy.swift Tests/FlightDeckTests/SleepPolicyTests.swift
git commit -m "feat: SleepPolicy pure eligibility for idle-session sleep"
```

---

### Task 4: `SessionSleepController` — idle tracking + sleep action

**Files:**
- Create: `Sources/FlightDeck/SessionSleepController.swift`
- Test: `Tests/FlightDeckTests/SessionSleepControllerTests.swift`

**Interfaces:**
- Consumes: `SleepPolicy` (Task 3), `DaemonControlling.stop` (Task 2), `AgentGroupResolving` (Task 1, for the live-descendants check), and small provider closures so it is testable without `SessionStore`.
- Produces:
  - `@MainActor final class SessionSleepController`
  - `init(policy:daemonControl:inspector:providers:tearDownSurface:now:)`
  - `func tick()` — one evaluation beat: refresh `idleSince`, sleep newly-eligible sessions.
  - `func wake(_ id: UUID)` — placeholder in this task (calls `daemonControl.cont` only); surface rebuild wired in Task 5.
  - `var asleep: Set<UUID>` — sessions currently frozen.

**Providers struct (the `SessionStore`-facing seam):**

```swift
struct SleepInputs {
    var candidates: () -> [UUID]                        // known sessions
    var activity: (UUID) -> SessionActivity?            // from statuses map (nil => no live agent)
    var selectedID: () -> UUID?
    var reportsBackgroundWork: (UUID) -> Bool           // backgroundWorkSessions.contains
    var daemonPID: (UUID) -> pid_t?                     // DaemonControlling.daemonPID
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionSleepControllerTests: XCTestCase {
    func makeController(activity: SessionActivity,
                        selected: UUID? = nil,
                        bgWork: Bool = false,
                        descendants: [ProcessIdentity] = [],
                        daemonPID: pid_t? = 111) -> (SessionSleepController, DaemonSpy, UUID) {
        let id = UUID()
        let daemon = DaemonSpy()
        let inputs = SleepInputs(
            candidates: { [id] },
            activity: { _ in activity },
            selectedID: { selected },
            reportsBackgroundWork: { _ in bgWork },
            daemonPID: { _ in daemonPID }
        )
        var torn: [UUID] = []
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 0),        // idle-threshold 0 => eligible immediately
            daemonControl: daemon,
            inspector: FixedInspector(descendants: descendants),
            resolver: FixedResolver(pgid: 222),
            inputs: inputs,
            tearDownSurface: { torn.append($0) },
            now: { Date() }
        )
        ctrl._tornRef = { torn }
        return (ctrl, daemon, id)
    }

    func testSleepsAnIdleUnfocusedSession() {
        let (ctrl, daemon, id) = makeController(activity: .idle)
        ctrl.tick()                                      // first tick sets idleSince
        ctrl.tick()                                      // second tick: threshold 0 => sleeps
        XCTAssertTrue(ctrl.asleep.contains(id))
        XCTAssertEqual(daemon.stopped, [id])
        XCTAssertEqual(ctrl._tornRef?(), [id])
    }

    func testDoesNotSleepBusy() {
        let (ctrl, daemon, id) = makeController(activity: .busy)
        ctrl.tick(); ctrl.tick()
        XCTAssertFalse(ctrl.asleep.contains(id))
        XCTAssertTrue(daemon.stopped.isEmpty)
    }

    func testLiveDescendantsBlockSleep() {
        let (ctrl, daemon, _) = makeController(activity: .idle,
            descendants: [ProcessIdentity(pid: 900, startTime: 1)])
        ctrl.tick(); ctrl.tick()
        XCTAssertTrue(daemon.stopped.isEmpty)
    }

    func testBusyResetsIdleClock() {
        // idle -> busy -> idle should restart the idleSince clock (no stale eligibility).
        let id = UUID()
        var act: SessionActivity = .idle
        let daemon = DaemonSpy()
        let ctrl = SessionSleepController(
            policy: SleepPolicy(idleThreshold: 10),
            daemonControl: daemon,
            inspector: FixedInspector(descendants: []),
            resolver: FixedResolver(pgid: 222),
            inputs: SleepInputs(candidates: { [id] }, activity: { _ in act },
                                selectedID: { nil }, reportsBackgroundWork: { _ in false },
                                daemonPID: { _ in 111 }),
            tearDownSurface: { _ in },
            now: { Date() }
        )
        ctrl.tick()
        act = .busy; ctrl.tick()          // clears idleSince
        act = .idle; ctrl.tick()          // restarts clock; not >= 10s yet
        XCTAssertFalse(ctrl.asleep.contains(id))
    }

    // doubles
    final class DaemonSpy: DaemonControlling {
        var stopped: [UUID] = []; var conted: [UUID] = []
        func isLive(_ id: UUID) -> Bool { true }
        func daemonPID(_ id: UUID) -> pid_t? { 111 }
        func terminate(_ id: UUID) {}
        func stop(_ id: UUID) { stopped.append(id) }
        func cont(_ id: UUID) { conted.append(id) }
    }
    struct FixedInspector: ProcessInspecting { let descendants: [ProcessIdentity]
        func descendants(of pid: pid_t) -> [ProcessIdentity] { descendants } }
    struct FixedResolver: AgentGroupResolving { let pgid: pid_t
        func agentProcessGroup(daemonPID: pid_t) -> pid_t? { pgid } }
}
```

*(Note: match `ProcessInspecting` / `ProcessIdentity` to their real definitions in `Sources/FlightDeck/ProcessTree.swift`; the `FixedInspector` conformance may need the exact method name/signature confirmed at execute time.)*

- [ ] **Step 2: Run to verify fail** — `./scripts/test-unit.sh` → FAIL (controller undefined).

- [ ] **Step 3: Implement `SessionSleepController.swift`**

```swift
import Foundation

@MainActor
final class SessionSleepController {
    private let policy: SleepPolicy
    private let daemonControl: DaemonControlling
    private let inspector: ProcessInspecting
    private let resolver: AgentGroupResolving
    private let inputs: SleepInputs
    private let tearDownSurface: (UUID) -> Void
    private let now: () -> Date

    private(set) var asleep: Set<UUID> = []
    private var idleSince: [UUID: Date] = [:]

    // test hook only
    var _tornRef: (() -> [UUID])?

    init(policy: SleepPolicy, daemonControl: DaemonControlling, inspector: ProcessInspecting,
         resolver: AgentGroupResolving, inputs: SleepInputs,
         tearDownSurface: @escaping (UUID) -> Void, now: @escaping () -> Date) {
        self.policy = policy; self.daemonControl = daemonControl; self.inspector = inspector
        self.resolver = resolver; self.inputs = inputs; self.tearDownSurface = tearDownSurface; self.now = now
    }

    func tick() {
        let t = now()
        for id in inputs.candidates() where !asleep.contains(id) {
            let activity = inputs.activity(id)
            // Track continuous idle/waiting; any other state clears the clock.
            if activity == .idle || activity == .waiting {
                if idleSince[id] == nil { idleSince[id] = t }
            } else {
                idleSince[id] = nil
                continue
            }
            let candidate = SleepCandidate(
                id: id, activity: activity!,
                isSelected: inputs.selectedID() == id,
                reportsBackgroundWork: inputs.reportsBackgroundWork(id),
                hasLiveDescendants: hasLiveDescendants(id),
                idleSince: idleSince[id],
                isDaemonized: inputs.daemonPID(id) != nil,
                isAsleep: false
            )
            if policy.evaluate(candidate, now: t) == .sleep { sleep(id) }
        }
        // forget vanished sessions
        let known = Set(inputs.candidates())
        idleSince = idleSince.filter { known.contains($0.key) }
    }

    private func hasLiveDescendants(_ id: UUID) -> Bool {
        guard let daemon = inputs.daemonPID(id),
              let pgid = resolver.agentProcessGroup(daemonPID: daemon) else { return false }
        // Walk the AGENT tree (daemon's child), not the attach-client surface shell.
        return !inspector.descendants(of: pgid).isEmpty
    }

    private func sleep(_ id: UUID) {
        tearDownSurface(id)             // Axis B: drop the attach client (detach path)
        daemonControl.stop(id)          // Axis A: SIGSTOP the agent group
        asleep.insert(id)
        idleSince[id] = nil
    }

    /// Wake (Task 5 wires the surface rebuild). Idempotent.
    func wake(_ id: UUID) {
        guard asleep.contains(id) else { return }
        daemonControl.cont(id)
        asleep.remove(id)
    }
}
```

- [ ] **Step 4: Run to verify pass** — `./scripts/test-unit.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionSleepController.swift Tests/FlightDeckTests/SessionSleepControllerTests.swift
git commit -m "feat: SessionSleepController idle tracking + sleep action"
```

---

### Task 5: `makeAttachSurface(id:)` extraction + wire wake to rebuild the surface

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — factor the two `config.command = daemon.attachCommand(...)` build sites (~`:1050-1061` relaunch, ~`:1953-1972` create/restore) into one `@MainActor func makeAttachSurface(id:) -> <surface>`; own a `SessionSleepController`; implement its `tearDownSurface`/`wake` against the real store.
- Modify: `Sources/FlightDeck/SessionSleepController.swift` — allow injecting a real `rebuildSurface: (UUID) -> Void` used by `wake`.
- Test: `Tests/FlightDeckTests/SessionSleepControllerTests.swift` (add wake-rebuild test) + a store-level wiring test if a seam exists.

**Interfaces:**
- Consumes: existing `SessionDaemon.attachCommand(for:)`, `processRegistry.record(for:)`, `provider?.makeSurface(config)` (from the two build sites).
- Produces: `SessionStore.makeAttachSurface(id:)`; `SessionSleepController.wake` now `cont` → `rebuildSurface(id)`.

- [ ] **Step 1: Write the failing test** (controller: wake rebuilds + conts, in order)

```swift
func testWakeContsThenRebuilds() {
    let id = UUID(); let daemon = DaemonSpy(); var order: [String] = []
    let ctrl = SessionSleepController(
        policy: SleepPolicy(idleThreshold: 0), daemonControl: daemon,
        inspector: FixedInspector(descendants: []), resolver: FixedResolver(pgid: 222),
        inputs: SleepInputs(candidates: { [id] }, activity: { _ in .idle }, selectedID: { nil },
                            reportsBackgroundWork: { _ in false }, daemonPID: { _ in 111 }),
        tearDownSurface: { _ in order.append("teardown") },
        rebuildSurface: { _ in order.append("rebuild") },
        now: { Date() }
    )
    daemon.contHook = { order.append("cont") }
    ctrl.tick(); ctrl.tick()                       // sleeps
    ctrl.wake(id)
    XCTAssertEqual(order.suffix(2), ["cont", "rebuild"])   // CONT before attach
    XCTAssertFalse(ctrl.asleep.contains(id))
}
```

- [ ] **Step 2: Run to verify fail** — FAIL: `rebuildSurface:` arg absent.

- [ ] **Step 3: Add `rebuildSurface` to the controller**

Add stored `private let rebuildSurface: (UUID) -> Void` (default `{ _ in }` so Task 4 tests still compile), set in `init`, and in `wake`:

```swift
func wake(_ id: UUID) {
    guard asleep.contains(id) else { return }
    daemonControl.cont(id)          // ensure running FIRST
    asleep.remove(id)
    rebuildSurface(id)              // then re-attach; ring replay restores the screen
}
```

- [ ] **Step 4: Extract `makeAttachSurface(id:)` in `SessionStore.swift`**

Read `SessionStore.swift:1040-1075` and `:1945-1975`. Extract the shared body (build `Ghostty.SurfaceConfiguration()`, set `config.command = daemon.attachCommand(for: id)` with the bare-shell fallback, then `processRegistry.record(for: id) { provider?.makeSurface(config) }`) into:

```swift
@MainActor
func makeAttachSurface(id: UUID) -> Ghostty.SurfaceView? {
    // (moved verbatim from the two call sites; both now call this)
    var config = Ghostty.SurfaceConfiguration()
    config.command = daemon.attachCommand(for: id)   // fallback to resolvedShell if unresolvable
    // ... existing initialInput / size / env setup that both sites shared ...
    return processRegistry.record(for: id) { provider?.makeSurface(config) }
}
```

Replace both original blocks with `let surface = makeAttachSurface(id: id)`. Wire the store's `SessionSleepController` with `tearDownSurface: { [weak self] in self?.tearDownSurface(for: $0) }` and `rebuildSurface: { [weak self] in _ = self?.makeAttachSurface(id: $0) }`, where `tearDownSurface(for:)` drops `surfaces[id]` (the detach — the daemon keeps the frozen agent).

- [ ] **Step 5: Run tests + manual build** — `./scripts/test-unit.sh` (controller tests pass; store compiles). If a store wiring seam exists, assert `makeAttachSurface` is called by both former sites via an existing surface-provider spy.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/SessionSleepController.swift Tests/FlightDeckTests/SessionSleepControllerTests.swift
git commit -m "refactor: makeAttachSurface helper; wake conts then rebuilds surface"
```

---

### Task 6: Wake seams — selection (local) and `injector(for:)` (remote/programmatic)

**Files:**
- Modify: `Sources/FlightDeck/TerminalPane.swift:61-108` (`updateNSView`) — before attaching the selected surface, if that id is asleep call `sleepController.wake(id)`.
- Modify: `Sources/FlightDeck/SessionStore.swift:5450-5452` (`injector(for:)`) — if `id` is asleep, wake it (rebuild surface + cont) before resolving, so `surfaces[id]` is non-nil and the `notRunning` guard in `inject`/`submitPrompt` does not fire.
- Test: `Tests/FlightDeckTests/SessionStoreWakeTests.swift` (new) exercising `injector(for:)` on a slept id.

**Interfaces:**
- Consumes: `SessionSleepController.wake`, `SessionSleepController.asleep`.

- [ ] **Step 1: Write the failing test** (injector wakes a slept session)

```swift
@MainActor
func testInjectorWakesSleptSessionBeforeResolving() throws {
    let store = makeStore()                       // existing test factory
    let id = store.debugAddDaemonizedSession()    // helper: a session with a live daemon + surface
    store.sleepController.tick(); store.sleepController.tick()   // force sleep (threshold 0 in test)
    XCTAssertTrue(store.sleepController.asleep.contains(id))
    XCTAssertNil(store.surfacesForTest[id])       // surface torn down

    let injector = store.injectorForTest(id)      // exposes injector(for:)
    XCTAssertNotNil(injector, "waking must re-materialize the surface")
    XCTAssertFalse(store.sleepController.asleep.contains(id))
}
```

- [ ] **Step 2: Run to verify fail** — FAIL: injector returns nil for a slept (surface-less) session.

- [ ] **Step 3: Implement the two hooks**

`injector(for:)`:

```swift
private func injector(for id: UUID) -> TextInjecting? {
    if sleepController.asleep.contains(id) { sleepController.wake(id) }  // rebuilds surface + cont
    return injectorOverride ?? surfaces[id]
}
```

`TerminalPane.updateNSView` (in the attach branch for `selectedSessionID`):

```swift
if let sel = store.selectedSessionID, store.sleepController.asleep.contains(sel) {
    store.sleepController.wake(sel)   // cont + rebuild before we attach/focus it
}
// ... existing surface(for: sel) + moveFocus ...
```

- [ ] **Step 4: Run to verify pass** — `./scripts/test-unit.sh` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/TerminalPane.swift Tests/FlightDeckTests/SessionStoreWakeTests.swift
git commit -m "feat: wake slept sessions on selection and on programmatic input"
```

---

### Task 7: `closeSession`/`terminate` — CONT before TERM

**Files:**
- Modify: `Sources/FlightDeck/DaemonControl.swift` `terminate(_:)` (~:115-143) — `SIGCONT` the agent group before `SIGTERM`, so a *stopped* agent processes the term instead of hanging.
- Test: `Tests/FlightDeckTests/DaemonControlTests.swift` (append).

- [ ] **Step 1: Write the failing test**

```swift
func testTerminateContsBeforeTermWhenStopped() {
    let sig = SignalSpy()
    let control = PosixDaemonControl(directory: tempDir,
                                     agentGroupResolver: FixedResolver(pgid: 4242),
                                     signal: sig.record)
    writePidfile(for: idA, pid: getpid())
    control.terminate(idA)
    // First signal to the agent group must be SIGCONT, before any SIGTERM path.
    XCTAssertEqual(sig.calls.first, .init(pid: -4242, signal: SIGCONT))
}
```

- [ ] **Step 2: Run to verify fail** — FAIL (no CONT emitted today).

- [ ] **Step 3: Implement** — at the top of `terminate`, after resolving a valid daemon pid, emit `cont(id)` (or inline `signalAgentGroup(id, SIGCONT)`) before the existing `SIGTERM`→poll→`SIGKILL` ladder. Keep the ladder unchanged.

- [ ] **Step 4: Run to verify pass** — `./scripts/test-unit.sh` → PASS (new test + all existing terminate tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/DaemonControl.swift Tests/FlightDeckTests/DaemonControlTests.swift
git commit -m "fix: SIGCONT a stopped agent before SIGTERM so closing a slept tab can't hang"
```

---

### Task 8: `idleThreshold` preference

**Files:**
- Modify: the preferences model/UI (follow `2026-08-11-preferences-design.md`; locate the existing prefs store — likely `Sources/FlightDeck/Preferences/…`). Add `sleepIdleThreshold` (default 600s), surfaced as a labeled control ("Sleep idle sessions after …") with an "Off" sentinel that disables sleep.
- Modify: `SessionStore` — construct `SleepPolicy(idleThreshold:)` from the pref; when "Off", the controller's `tick()` early-returns.
- Test: preferences round-trip test (match the existing prefs test pattern).

- [ ] **Step 1: Write the failing test** — assert the pref persists and maps to the policy threshold; "Off" ⇒ controller does not sleep. (Model on an existing preference test in `Tests/FlightDeckTests/…Preferences…`.)
- [ ] **Step 2: Run to verify fail.**
- [ ] **Step 3: Implement** the pref + wiring; feed it into the policy and a `sleepEnabled` gate on `tick()`.
- [ ] **Step 4: Run to verify pass.**
- [ ] **Step 5: Commit** — `feat: preference for idle-sleep threshold (with Off)`.

---

### Task 9: End-to-end smoke test

**Files:**
- Modify/Create: `Tests/…/TerminalSmokeTests.swift` (the layer that drives a real ghostty surface + real fd-abduco daemon, per the detach spec's E2E test).

- [ ] **Step 1: Write the test** — start a daemonized session, produce known output, drive the controller to sleep it (threshold 0 / force), assert: agent process state is `T` (stopped) and ~0% CPU; then wake (selection path), assert the pane shows the prior scrollback and the agent pid is unchanged (same live process).
- [ ] **Step 2: Run** the smoke target; confirm PASS. This is the only layer exercising real replay.
- [ ] **Step 3: Commit** — `test: end-to-end smart-sleep freeze + lossless wake`.

---

### Task 10: Render gating (measure-first — independent)

**Files:**
- Create: a small timing instrument around the tab-switch/attach path (reuse existing diagnostics if `2026-08-29-diagnostics-query-interface-design.md` provides a seam).
- Modify: the surface/window lifecycle to gate rendering on `NSWindowOcclusionState` for a foreground surface whose window is occluded; confirm non-selected tabs are already non-rendering.

- [ ] **Step 1:** Instrument and **measure** the tab-switch cost of occlusion-gated rendering (attach/detach round-trip).
- [ ] **Step 2 (decision, not code):** If **< 300 ms** → ship unconditionally (gate every occluded-window foreground surface). If **≥ 300 ms** → gate only surfaces whose session has been idle **> 1 hour** (reuse the controller's `idleSince`).
- [ ] **Step 3:** Implement the chosen rollout; add a test asserting an occluded-window foreground surface stops rendering (and resumes on de-occlusion).
- [ ] **Step 4:** Run + commit — `feat: gate terminal rendering on window occlusion (<300ms) / >1h-idle fallback`.

---

## Self-Review

- **Spec coverage:** Axis A freeze (Tasks 1–2), Axis B teardown (Tasks 4–5), eligibility incl. background-work gate & topology note (Tasks 3–4), triggers via WatchClock (Task 4 + store wiring in Task 5/8), both wake seams + attach⇒CONT (Tasks 5–6), CONT-before-TERM (Task 7), threshold preference (Task 8), notifications invariant (no code — asserted by design, no new StatusTransition from a frozen process), E2E (Task 9), render gating measure-first (Task 10). The `> 0` rail is enforced in Tasks 1–2 and tested (`testStopRefusesWhenPgidResolvesNonPositive`). All spec sections map to a task.
- **Placeholder scan:** no TBD/TODO in steps; the two "confirm the real signature at execute time" notes (ProcessInspecting method name; existing `PosixDaemonControl.init` args) are Global-Constraint preconditions driven by the still-moving dependency, not in-step placeholders.
- **Type consistency:** `SleepCandidate`/`SleepDecision`/`SleepPolicy` identical across Tasks 3–4; `DaemonControlling.stop/cont` signatures identical across Tasks 2/4/7; `SessionSleepController` init gains `rebuildSurface` in Task 5 with a default so Task 4 tests still compile; `AgentGroupResolving.agentProcessGroup(daemonPID:)` identical across Tasks 1/2/4.

## WatchClock registration (store wiring, folded into Task 5)

In `SessionStore`, after constructing the controller, register it on the shared clock exactly like the other watchers: `clock.add(sleepController) { [weak sleepController] in sleepController?.tick() }`. It inherits the 500 ms/2 s cadence and weak auto-pruning. The `SleepInputs` closures read `statuses`, `selectedSessionID`, `backgroundWorkSessions`, and `daemonControl.daemonPID` off the store.
