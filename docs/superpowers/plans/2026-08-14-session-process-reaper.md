# Session Process Reaper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make closing a tab, quitting the app, or recovering from a crash *definitely* terminate the processes that session was running, on a bounded deadline, without stalling the main thread.

**Architecture:** Flight Deck records each session's shell pid itself (a `proc_listchildpids` diff around `makeSurface`), then runs its own SIGHUP → SIGTERM → SIGKILL ladder from a non-main actor, walking the descendant tree captured *before* the first signal. `closeSession` reaps *before* releasing the `SurfaceView`, so libghostty's own blocking `killpg` loop — which runs on the main actor inside `ghostty_surface_free` — finds an already-dead child and returns instantly instead of spinning. Nothing under `vendor/` or `GhosttyEmbed/` is touched.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit, Swift concurrency (`actor`, `async`), libproc (`<libproc.h>`), XCTest, XcodeGen, macOS 14 target.

**Spec:** `docs/superpowers/specs/2026-08-14-session-process-reaper-design.md`

## Global Constraints

- **macOS deployment target 14.0** (`project.yml:5`). `SWIFT_VERSION: "5.0"` — Swift 5 language mode, no strict concurrency. `actor` / `async` are available and used here.
- **Every `xcodebuild`/`xcodegen`/`xcrun` invocation needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** The scripts export it themselves. **Do not run `sudo xcode-select`.**
- **Unit tests run with `./scripts/test-unit.sh`** — it runs the whole `FlightDeckTests` bundle headlessly via `xcrun xctest`. There is no per-test filter; read the named test out of the output.
- **The unit bundle runs with no host app.** Anything needing a live `ghostty_app_t` must `XCTSkip`, as `SurfaceLifecycleTests.swift:17-20` already does. No task in this plan adds a test that requires a launched app.
- **Do not run `./scripts/smoke.sh` casually.** It seizes the foreground for ~40 s and fires key events into whatever has focus; stray typing during a run reads as phantom failures. No task here requires it.
- **`Sources/FlightDeck/GhosttyEmbed/` is vendored-ish** — every file carries an `// Adapted from ghostty v1.3.1:` header. **No task modifies anything under `GhosttyEmbed/`.** Read-only.
- **`vendor/ghostty` is an upstream-pinned submodule** that `scripts/build-libghostty.sh` `git clean`s. **No task modifies anything under `vendor/`.**
- **Never touch `UNUserNotificationCenter.current()` from anything a test can reach.** It traps when the calling binary is not a signed bundle, which is exactly the unit-test bundle (`SessionNotifier.swift:12-16`). Delivery always goes behind a protocol.
- **This checkout is shared with other sessions.** Stage named paths. Never `git add -A`, never `git stash`, never revert anything you did not write.
- **New files must be added to the target by re-running `xcodegen generate`** — `project.yml` globs `Sources/FlightDeck`, so no manual project edit is needed, but `test-unit.sh` runs `xcodegen generate` itself as its first step.

---

### Task 1: Process identity and the process tree

The foundation both later stages need: a stable identity for a process that survives pid recycling, and a way to enumerate our own descendants.

**Background the implementer needs:** macOS recycles pids, so a pid alone is not an identity — this codebase already learned that lesson for the `~/.claude/sessions/<pid>.json` registry, where `ConversationPin.Anchor` pairs a pid with a `procStart` and treats a mismatch as *a different process* (`ConversationPin.swift:9-12`, `:53-55`). We reuse that doctrine because every signal we send later is gated on it. `proc_listchildpids` returns a **byte count**, not a pid count, and the process set can grow between the sizing call and the fill call — hence the headroom below.

**Files:**
- Create: `Sources/FlightDeck/ProcessIdentity.swift`
- Create: `Sources/FlightDeck/ProcessTree.swift`
- Modify: `Sources/FlightDeck/BridgingHeader.h`
- Test: `Tests/FlightDeckTests/ProcessTreeTests.swift` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `struct ProcessIdentity: Codable, Equatable, Sendable { let pid: pid_t; let procStart: UInt64 }`
  - `protocol ProcessInspecting: Sendable { func children(of ppid: pid_t) -> Set<pid_t>; func descendants(of pid: pid_t) -> [ProcessIdentity]; func startTime(of pid: pid_t) -> UInt64?; func isAlive(_ identity: ProcessIdentity) -> Bool }`
  - `struct ProcessTree: ProcessInspecting` — the real libproc implementation
  - `func ProcessTree.identity(of pid: pid_t) -> ProcessIdentity?`

- [ ] **Step 1: Add the libproc import**

Append to `Sources/FlightDeck/BridgingHeader.h`:

```objc
// libproc gives us `proc_listchildpids` and `proc_pidinfo`, which are how the session
// reaper learns which processes a tab owns. The app is not sandboxed
// (`FlightDeck.entitlements` has no `com.apple.security.app-sandbox`), so enumerating and
// signalling our own descendants needs no entitlement.
#import <libproc.h>
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/FlightDeckTests/ProcessTreeTests.swift`:

```swift
// Tests/FlightDeckTests/ProcessTreeTests.swift
import XCTest
@testable import FlightDeck

final class ProcessTreeTests: XCTestCase {
    /// Spawns `/bin/sh -c "sleep 30"` as a child of this test process and returns it.
    /// The caller must terminate it.
    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 30"]
        try p.run()
        return p
    }

    func testChildrenIncludesASpawnedChild() throws {
        let child = try spawnSleeper()
        defer { child.terminate() }

        let kids = ProcessTree().children(of: getpid())

        XCTAssertTrue(kids.contains(child.processIdentifier))
    }

    func testDescendantsIncludesAGrandchild() throws {
        // `sh` stays alive while its own `sleep` child runs, so the tree is two deep.
        let child = try spawnSleeper()
        defer { child.terminate() }

        // Give `sh` a moment to fork `sleep`.
        Thread.sleep(forTimeInterval: 0.3)
        let tree = ProcessTree().descendants(of: getpid()).map(\.pid)

        XCTAssertTrue(tree.contains(child.processIdentifier), "direct child missing")
        XCTAssertGreaterThan(tree.count, 1, "expected the grandchild `sleep` as well")
    }

    func testStartTimeIsStableAcrossReads() throws {
        let child = try spawnSleeper()
        defer { child.terminate() }
        let tree = ProcessTree()

        let first = tree.startTime(of: child.processIdentifier)
        Thread.sleep(forTimeInterval: 0.2)
        let second = tree.startTime(of: child.processIdentifier)

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    func testStartTimeOfDeadProcessIsNil() throws {
        let child = try spawnSleeper()
        let pid = child.processIdentifier
        child.terminate()
        child.waitUntilExit()

        XCTAssertNil(ProcessTree().startTime(of: pid))
    }

    /// The identity gate: a recorded identity whose start time no longer matches is a
    /// *different* process that inherited a recycled pid, and must never be signalled.
    func testIsAliveRejectsAMismatchedStartTime() throws {
        let child = try spawnSleeper()
        defer { child.terminate() }
        let tree = ProcessTree()

        let real = try XCTUnwrap(tree.identity(of: child.processIdentifier))
        let impostor = ProcessIdentity(pid: real.pid, procStart: real.procStart &+ 1)

        XCTAssertTrue(tree.isAlive(real))
        XCTAssertFalse(tree.isAlive(impostor))
    }

    func testIsAliveIsFalseForADeadProcess() throws {
        let child = try spawnSleeper()
        let tree = ProcessTree()
        let identity = try XCTUnwrap(tree.identity(of: child.processIdentifier))
        child.terminate()
        child.waitUntilExit()

        XCTAssertFalse(tree.isAlive(identity))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ProcessTree' in scope`.

- [ ] **Step 4: Write `ProcessIdentity`**

Create `Sources/FlightDeck/ProcessIdentity.swift`:

```swift
// Sources/FlightDeck/ProcessIdentity.swift
import Foundation

/// One process, identified so that a recycled pid cannot be mistaken for it.
///
/// A pid alone is not an identity — macOS recycles pids. This is the same doctrine
/// `ConversationPin.Anchor` uses for the `~/.claude/sessions/<pid>.json` registry: a
/// familiar pid carrying an unfamiliar start time is a *different* process, not the one we
/// recorded. Every signal the reaper sends is gated on this pairing still matching, which
/// is what makes the launch-time orphan sweep safe to run against a snapshot written by a
/// previous boot.
struct ProcessIdentity: Codable, Equatable, Sendable {
    let pid: pid_t
    /// Process start time in whole seconds since the epoch, from `PROC_PIDTBSDINFO`.
    let procStart: UInt64
}
```

- [ ] **Step 5: Write `ProcessTree`**

Create `Sources/FlightDeck/ProcessTree.swift`:

```swift
// Sources/FlightDeck/ProcessTree.swift
import Darwin
import Foundation

/// Reads the live process table. Injected as a protocol so the reaper's logic can be tested
/// against a scripted tree instead of real processes.
protocol ProcessInspecting: Sendable {
    func children(of ppid: pid_t) -> Set<pid_t>
    /// Every descendant, depth-first, each carrying its identity at the moment of the walk.
    func descendants(of pid: pid_t) -> [ProcessIdentity]
    func startTime(of pid: pid_t) -> UInt64?
    func isAlive(_ identity: ProcessIdentity) -> Bool
}

/// The real implementation, over libproc.
struct ProcessTree: ProcessInspecting {
    /// Depth limit for the descendant walk. Terminal process trees are shallow; this only
    /// exists so a pathological or cyclic reading of the table cannot spin forever.
    private static let maxDepth = 16

    func children(of ppid: pid_t) -> Set<pid_t> {
        // proc_listchildpids reports a BYTE count, not a pid count.
        let sizing = proc_listchildpids(ppid, nil, 0)
        guard sizing > 0 else { return [] }

        // Headroom: the child set can grow between the sizing call and the fill call, and a
        // short buffer silently truncates rather than erroring.
        let capacity = Int(sizing) / MemoryLayout<pid_t>.size + 16
        var buffer = [pid_t](repeating: 0, count: capacity)
        let filled = buffer.withUnsafeMutableBytes { raw in
            proc_listchildpids(ppid, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }

        let count = min(Int(filled) / MemoryLayout<pid_t>.size, capacity)
        return Set(buffer.prefix(count).filter { $0 > 0 })
    }

    func descendants(of pid: pid_t) -> [ProcessIdentity] {
        var found: [ProcessIdentity] = []
        var seen: Set<pid_t> = [pid]
        var frontier = [(pid: pid, depth: 0)]

        while let (current, depth) = frontier.popLast() {
            guard depth < Self.maxDepth else { continue }
            for child in children(of: current) where !seen.contains(child) {
                seen.insert(child)
                if let identity = identity(of: child) { found.append(identity) }
                frontier.append((child, depth + 1))
            }
        }
        return found
    }

    func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        // A short read means the process died between the call and the copy.
        guard read == size else { return nil }
        return UInt64(info.pbi_start_tvsec)
    }

    func identity(of pid: pid_t) -> ProcessIdentity? {
        startTime(of: pid).map { ProcessIdentity(pid: pid, procStart: $0) }
    }

    /// Alive *and still the same process*. The start-time comparison is the whole point:
    /// without it this would happily report a recycled pid as our long-dead shell.
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        startTime(of: identity.pid) == identity.procStart
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all six `ProcessTreeTests` pass, rest of suite unchanged.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/ProcessIdentity.swift Sources/FlightDeck/ProcessTree.swift \
        Sources/FlightDeck/BridgingHeader.h Tests/FlightDeckTests/ProcessTreeTests.swift
git commit -m "feat: add process identity and libproc process-tree reader"
```

---

### Task 2: The escalation ladder

The reaper itself: signal escalation with deadlines, off the main actor, with every dependency injected so the sequence is assertable without real processes.

**Background the implementer needs:** libghostty sends SIGHUP and only SIGHUP (`vendor/ghostty/src/termio/Exec.zig:1152-1185`), which is why a process that ignores it survives a tab close today. Two subtleties drive the shape below:

1. **The descendant snapshot must be taken before the first signal.** Once the shell dies its children are reparented to launchd and `proc_listchildpids(shellPid)` returns nothing — a tree walked *after* the group kill is always empty, and the reaper would report success while the escapees kept running.
2. **The self-group rail.** `killpg` against our own process group would kill us. In the real app the shell has called `setsid`, so this never fires — but a `Foundation.Process` child in the test bundle lands in the *test runner's* group, and without this rail Task 7's test would kill the test runner.

**Files:**
- Create: `Sources/FlightDeck/SessionReaper.swift`
- Test: `Tests/FlightDeckTests/SessionReaperTests.swift` (create)

**Interfaces:**
- Consumes: `ProcessIdentity`, `ProcessInspecting` (Task 1).
- Produces:
  - `protocol SignalSending: Sendable { func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool; func send(_ signal: Int32, toProcess pid: pid_t) -> Bool; func ownProcessGroup() -> pid_t }`
  - `struct PosixSignals: SignalSending`
  - `protocol ReaperSleeping: Sendable { func sleep(seconds: Double) async }`
  - `struct RealSleeper: ReaperSleeping`
  - `enum ReapOutcome: Equatable { case clean, survivors([ProcessIdentity]) }`
  - `actor SessionReaper` with `init(inspector:signals:sleeper:)` and
    `func reap(shell: ProcessIdentity, pgid: pid_t) async -> ReapOutcome`
  - `SessionReaper.Ladder` — the static step table, `[(signal: Int32, budget: Double)]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/SessionReaperTests.swift`:

```swift
// Tests/FlightDeckTests/SessionReaperTests.swift
import XCTest
@testable import FlightDeck

/// A scripted process table. `aliveUntilSignal` lets a test say "this pid dies once it has
/// been sent SIGTERM", which is how the ladder's short-circuiting gets exercised.
private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    var living: Set<pid_t>
    var tree: [pid_t: [ProcessIdentity]]
    /// Descendants are only visible while the parent is alive — this mirrors reality, where
    /// children are reparented to launchd the moment their parent dies.
    init(living: Set<pid_t>, tree: [pid_t: [ProcessIdentity]] = [:]) {
        self.living = living
        self.tree = tree
    }

    func children(of ppid: pid_t) -> Set<pid_t> { Set((tree[ppid] ?? []).map(\.pid)) }

    func descendants(of pid: pid_t) -> [ProcessIdentity] {
        guard living.contains(pid) else { return [] }
        return tree[pid] ?? []
    }

    func startTime(of pid: pid_t) -> UInt64? { living.contains(pid) ? 100 : nil }
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        living.contains(identity.pid) && identity.procStart == 100
    }
}

private final class SpySignals: SignalSending, @unchecked Sendable {
    struct Sent: Equatable { let signal: Int32; let target: pid_t; let isGroup: Bool }
    var sent: [Sent] = []
    var ownGroup: pid_t = 999
    /// Called after each send so a test can script "this signal kills it".
    var onSend: ((Sent) -> Void)?

    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool {
        let s = Sent(signal: signal, target: pgid, isGroup: true)
        sent.append(s); onSend?(s); return true
    }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool {
        let s = Sent(signal: signal, target: pid, isGroup: false)
        sent.append(s); onSend?(s); return true
    }
    func ownProcessGroup() -> pid_t { ownGroup }
}

private struct InstantSleeper: ReaperSleeping {
    func sleep(seconds: Double) async {}
}

final class SessionReaperTests: XCTestCase {
    private let shell = ProcessIdentity(pid: 4242, procStart: 100)

    func testAShellThatDiesOnSIGHUPIsSignalledOnce() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        signals.onSend = { _ in inspector.living.remove(4242) }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(signals.sent, [.init(signal: SIGHUP, target: 4242, isGroup: true)])
    }

    func testAStubbornShellEscalatesAllTheWayToSIGKILL() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        signals.onSend = { sent in if sent.signal == SIGKILL { inspector.living.remove(4242) } }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertEqual(signals.sent.map(\.signal), [SIGHUP, SIGTERM, SIGKILL])
    }

    func testAnUnkillableShellIsReportedAsASurvivor() async {
        let inspector = FakeInspector(living: [4242])
        let reaper = SessionReaper(
            inspector: inspector, signals: SpySignals(), sleeper: InstantSleeper()
        )

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .survivors([shell]))
    }

    /// The ordering guarantee from the spec: the tree is captured while the shell is alive,
    /// because a tree walked after the kill is always empty.
    func testAnEscapeeIsLadderedEvenThoughTheTreeVanishesWithTheShell() async {
        let escapee = ProcessIdentity(pid: 5555, procStart: 100)
        let inspector = FakeInspector(living: [4242, 5555], tree: [4242: [escapee]])
        let signals = SpySignals()
        signals.onSend = { sent in
            // The group kill takes the shell but not the escapee, which left the group.
            if sent.isGroup { inspector.living.remove(4242) }
            if sent.target == 5555, sent.signal == SIGKILL { inspector.living.remove(5555) }
        }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

        let outcome = await reaper.reap(shell: shell, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        let perPid = signals.sent.filter { !$0.isGroup }
        XCTAssertEqual(perPid.map(\.target), [5555, 5555, 5555])
        XCTAssertEqual(perPid.map(\.signal), [SIGHUP, SIGTERM, SIGKILL])
    }

    /// Without this rail, reaping a process that shares our group kills us.
    func testNeverKillpgsItsOwnProcessGroup() async {
        let inspector = FakeInspector(living: [4242])
        let signals = SpySignals()
        signals.ownGroup = 777
        signals.onSend = { _ in inspector.living.remove(4242) }
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

        _ = await reaper.reap(shell: shell, pgid: 777)

        XCTAssertTrue(signals.sent.allSatisfy { !$0.isGroup }, "must not signal its own group")
        XCTAssertEqual(signals.sent.first?.target, 4242, "falls back to per-pid")
    }

    /// A pid that died and was recycled must not be signalled: same pid, different start time.
    func testDoesNotSignalARecycledPid() async {
        let inspector = FakeInspector(living: [4242])   // start time 100
        let stale = ProcessIdentity(pid: 4242, procStart: 55)
        let signals = SpySignals()
        let reaper = SessionReaper(inspector: inspector, signals: signals, sleeper: InstantSleeper())

        let outcome = await reaper.reap(shell: stale, pgid: 4242)

        XCTAssertEqual(outcome, .clean)
        XCTAssertTrue(signals.sent.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'SessionReaper' in scope`.

- [ ] **Step 3: Write `SessionReaper`**

Create `Sources/FlightDeck/SessionReaper.swift`:

```swift
// Sources/FlightDeck/SessionReaper.swift
import Darwin
import Foundation
import OSLog

/// Signal delivery, behind a protocol so the ladder can be asserted without real processes.
protocol SignalSending: Sendable {
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool
    func ownProcessGroup() -> pid_t
}

struct PosixSignals: SignalSending {
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool { killpg(pgid, signal) == 0 }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool { kill(pid, signal) == 0 }
    func ownProcessGroup() -> pid_t { getpgid(0) }
}

protocol ReaperSleeping: Sendable {
    func sleep(seconds: Double) async
}

struct RealSleeper: ReaperSleeping {
    func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

enum ReapOutcome: Equatable {
    case clean
    case survivors([ProcessIdentity])
}

/// Terminates a session's process tree on a bounded deadline.
///
/// **Why this exists.** libghostty sends SIGHUP and only SIGHUP when a surface is freed
/// (`vendor/ghostty/src/termio/Exec.zig:1152-1185`), then spins waiting for the direct child
/// to be reaped — on the main actor, inside `ghostty_surface_free`. A process that ignores
/// SIGHUP therefore survives a tab close *and* wedges the UI. This type escalates properly
/// and does it off the main actor.
///
/// **Why an actor rather than `@MainActor`.** Nothing here may block the UI, and the ladder
/// deliberately sleeps between rungs.
actor SessionReaper {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "SessionReaper"
    )

    /// Signal, and how long to wait for it to work before escalating. Total 5 s.
    static let ladder: [(signal: Int32, budget: Double)] = [
        (SIGHUP, 2.0), (SIGTERM, 2.0), (SIGKILL, 1.0),
    ]
    /// How often to check whether the target died, inside a rung's budget. A shell that dies
    /// on the first SIGHUP — the overwhelming majority — finishes in one interval, not 2 s.
    static let pollInterval = 0.05

    private let inspector: ProcessInspecting
    private let signals: SignalSending
    private let sleeper: ReaperSleeping

    init(inspector: ProcessInspecting, signals: SignalSending, sleeper: ReaperSleeping) {
        self.inspector = inspector
        self.signals = signals
        self.sleeper = sleeper
    }

    /// Escalate against the shell's process group, then against anything that escaped it.
    func reap(shell: ProcessIdentity, pgid: pid_t) async -> ReapOutcome {
        guard inspector.isAlive(shell) else { return .clean }

        // Capture the tree FIRST. Once the shell dies its children are reparented to launchd
        // and this walk returns nothing, so a snapshot taken after the kill is always empty
        // and would report success while escapees kept running.
        let tree = inspector.descendants(of: shell.pid)

        await escalate(on: shell, pgid: pgid)

        var survivors: [ProcessIdentity] = []
        if inspector.isAlive(shell) { survivors.append(shell) }

        // Anything still alive left the process group (setsid), so killpg never reached it.
        for escapee in tree where inspector.isAlive(escapee) {
            await escalate(on: escapee, pgid: nil)
            if inspector.isAlive(escapee) { survivors.append(escapee) }
        }

        if !survivors.isEmpty {
            Self.logger.error("reap incomplete, \(survivors.count) process(es) survived SIGKILL")
        }
        return survivors.isEmpty ? .clean : .survivors(survivors)
    }

    /// One target through the whole ladder, stopping the moment it dies.
    private func escalate(on target: ProcessIdentity, pgid: pid_t?) async {
        for rung in Self.ladder {
            guard inspector.isAlive(target) else { return }
            deliver(rung.signal, to: target, pgid: pgid)

            var waited = 0.0
            while waited < rung.budget {
                await sleeper.sleep(seconds: Self.pollInterval)
                waited += Self.pollInterval
                if !inspector.isAlive(target) { return }
            }
        }
    }

    /// Group-first where we can, per-pid where we must.
    ///
    /// The self-group rail is load-bearing: `killpg` against our own group would kill Flight
    /// Deck itself. libghostty's child calls `setsid` immediately so this never fires in the
    /// app, but anything spawned without `setsid` — a `Foundation.Process` in the test bundle,
    /// for instance — shares our group, and upstream ghostty guards the same window from the
    /// other side (`Exec.zig:1193-1205`).
    private func deliver(_ signal: Int32, to target: ProcessIdentity, pgid: pid_t?) {
        if let pgid, pgid > 0, pgid != signals.ownProcessGroup() {
            _ = signals.send(signal, toGroup: pgid)
        } else {
            _ = signals.send(signal, toProcess: target.pid)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all six `SessionReaperTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionReaper.swift Tests/FlightDeckTests/SessionReaperTests.swift
git commit -m "feat: add SIGHUP/SIGTERM/SIGKILL session reaper with deadlines"
```

---

### Task 3: Recording each session's shell

Wire pid discovery into session creation so there is something to reap.

**Background the implementer needs:** libghostty forks the shell inside `ghostty_surface_new`, which Flight Deck reaches through `provider?.makeSurface(config)` at `SessionStore.swift:278`. The C API exposes no pid (`vendor/ghostty/include/ghostty.h` has only `ghostty_surface_process_exited`), so we infer it: `insertSession` is `@MainActor` and therefore serialized, so a `children(of: getpid())` diff around that one call isolates exactly one new child. **If the diff is not exactly one pid, record nothing** — a tab with no record simply degrades to today's behavior, which is far better than signalling a guess.

**Files:**
- Create: `Sources/FlightDeck/SurfaceProcessRegistry.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (`insertSession`, lines 254-293; `closeSession`, lines 416-443; stored properties near line 41)
- Test: `Tests/FlightDeckTests/SurfaceProcessRegistryTests.swift` (create)

**Interfaces:**
- Consumes: `ProcessIdentity`, `ProcessInspecting`, `ProcessTree` (Task 1).
- Produces:
  - `struct SessionProcess: Codable, Equatable { let identity: ProcessIdentity; let pgid: pid_t }`
  - `@MainActor final class SurfaceProcessRegistry` with:
    - `init(inspector: ProcessInspecting = ProcessTree())`
    - `func record<T>(for tabID: UUID, around make: () -> T) -> T`
    - `func process(for tabID: UUID) -> SessionProcess?`
    - `func forget(_ tabID: UUID) -> SessionProcess?`
    - `var all: [UUID: SessionProcess] { get }`
    - `func restore(_ processes: [UUID: SessionProcess])`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/SurfaceProcessRegistryTests.swift`:

```swift
// Tests/FlightDeckTests/SurfaceProcessRegistryTests.swift
import XCTest
@testable import FlightDeck

/// Returns a scripted child set per call, so a test can stage "before" and "after".
private final class ScriptedInspector: ProcessInspecting, @unchecked Sendable {
    var snapshots: [Set<pid_t>]
    init(snapshots: [Set<pid_t>]) { self.snapshots = snapshots }

    func children(of ppid: pid_t) -> Set<pid_t> {
        snapshots.isEmpty ? [] : snapshots.removeFirst()
    }
    func descendants(of pid: pid_t) -> [ProcessIdentity] { [] }
    func startTime(of pid: pid_t) -> UInt64? { 100 }
    func isAlive(_ identity: ProcessIdentity) -> Bool { true }
}

@MainActor
final class SurfaceProcessRegistryTests: XCTestCase {
    private let tab = UUID()

    func testRecordsTheOneNewChild() {
        let registry = SurfaceProcessRegistry(
            inspector: ScriptedInspector(snapshots: [[10, 11], [10, 11, 12]])
        )

        let made = registry.record(for: tab) { "surface" }

        XCTAssertEqual(made, "surface")
        XCTAssertEqual(registry.process(for: tab)?.identity.pid, 12)
    }

    /// No new child (surface creation failed) records nothing rather than guessing.
    func testRecordsNothingWhenNoChildAppeared() {
        let registry = SurfaceProcessRegistry(
            inspector: ScriptedInspector(snapshots: [[10], [10]])
        )

        registry.record(for: tab) { () }

        XCTAssertNil(registry.process(for: tab))
    }

    /// Two new children is ambiguous — which one is the shell? Record nothing.
    func testRecordsNothingWhenTheDiffIsAmbiguous() {
        let registry = SurfaceProcessRegistry(
            inspector: ScriptedInspector(snapshots: [[10], [10, 11, 12]])
        )

        registry.record(for: tab) { () }

        XCTAssertNil(registry.process(for: tab))
    }

    func testForgetReturnsAndRemovesTheRecord() {
        let registry = SurfaceProcessRegistry(
            inspector: ScriptedInspector(snapshots: [[], [7]])
        )
        registry.record(for: tab) { () }

        let forgotten = registry.forget(tab)

        XCTAssertEqual(forgotten?.identity.pid, 7)
        XCTAssertNil(registry.process(for: tab))
        XCTAssertNil(registry.forget(tab))
    }

    func testRestoreRepopulatesFromASnapshot() {
        let registry = SurfaceProcessRegistry(inspector: ScriptedInspector(snapshots: []))
        let stored = SessionProcess(
            identity: ProcessIdentity(pid: 88, procStart: 5), pgid: 88
        )

        registry.restore([tab: stored])

        XCTAssertEqual(registry.all, [tab: stored])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'SurfaceProcessRegistry' in scope`.

- [ ] **Step 3: Write `SurfaceProcessRegistry`**

Create `Sources/FlightDeck/SurfaceProcessRegistry.swift`:

```swift
// Sources/FlightDeck/SurfaceProcessRegistry.swift
import Darwin
import Foundation
import OSLog

/// A session's shell, plus the group to signal for it.
struct SessionProcess: Codable, Equatable {
    let identity: ProcessIdentity
    let pgid: pid_t
}

/// Remembers which process each tab owns.
///
/// **Why a diff and not an API call.** libghostty forks the shell inside
/// `ghostty_surface_new` and exposes no pid for it — the only process-related export is
/// `ghostty_surface_process_exited` (`vendor/ghostty/include/ghostty.h:1082`). Patching the
/// vendored submodule to add one is not an option: it is pinned to upstream and
/// `scripts/build-libghostty.sh` `git clean`s it after every build. So we bracket the call
/// and take the difference.
///
/// **Why that is sound.** Surface creation is `@MainActor` and therefore serialized, so
/// exactly one fork happens between the two snapshots. When it does not — zero new children,
/// or more than one — we record nothing at all. A tab with no record degrades to libghostty's
/// own SIGHUP-only teardown, which is what every tab does today; a *wrong* record would send
/// SIGKILL to an unrelated process.
@MainActor
final class SurfaceProcessRegistry {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "SurfaceProcessRegistry"
    )

    private let inspector: ProcessInspecting
    private var processes: [UUID: SessionProcess] = [:]

    init(inspector: ProcessInspecting = ProcessTree()) {
        self.inspector = inspector
    }

    var all: [UUID: SessionProcess] { processes }

    /// Runs `make`, recording whatever child it forked.
    @discardableResult
    func record<T>(for tabID: UUID, around make: () -> T) -> T {
        let before = inspector.children(of: getpid())
        let result = make()
        let after = inspector.children(of: getpid())

        let new = after.subtracting(before)
        guard new.count == 1, let pid = new.first else {
            Self.logger.warning(
                "no shell recorded for tab: expected 1 new child, saw \(new.count). "
                + "This tab falls back to libghostty's SIGHUP-only teardown."
            )
            return result
        }
        guard let start = inspector.startTime(of: pid) else { return result }

        // The shell calls setsid, so its group is its own — but read it rather than assume,
        // and fall back to the pid if the read fails.
        let pgid = getpgid(pid)
        processes[tabID] = SessionProcess(
            identity: ProcessIdentity(pid: pid, procStart: start),
            pgid: pgid > 0 ? pgid : pid
        )
        return result
    }

    func process(for tabID: UUID) -> SessionProcess? { processes[tabID] }

    @discardableResult
    func forget(_ tabID: UUID) -> SessionProcess? { processes.removeValue(forKey: tabID) }

    func restore(_ restored: [UUID: SessionProcess]) { processes = restored }
}
```

- [ ] **Step 4: Wire it into `SessionStore`**

Add the stored property next to `surfaces` (`SessionStore.swift:41`):

```swift
    /// Which OS process each tab owns, for teardown. See `SurfaceProcessRegistry`.
    let processRegistry = SurfaceProcessRegistry()
```

In `insertSession` (`SessionStore.swift:278-280`), bracket the surface creation:

```swift
        // Bracketed so the registry can identify the shell libghostty forks inside
        // `makeSurface`; libghostty exposes no pid of its own.
        let created = processRegistry.record(for: session.id) { provider?.makeSurface(config) }
        if let surface = created {
            surfaces[session.id] = surface
        }
```

In `closeSession`, drop the record alongside the other per-tab state (next to
`anchors.removeValue(forKey: id)` at `SessionStore.swift:427`) — Task 4 replaces this line with
the actual reap, but leaving the registry to grow unbounded in the meantime is a leak:

```swift
        processRegistry.forget(id)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: `SurfaceProcessRegistryTests` pass; existing `SessionStoreTests`, `SessionCreationTests`, `SurfaceLifecycleTests` still pass (the stub providers return `nil` surfaces, which the registry handles as "no new child").

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SurfaceProcessRegistry.swift \
        Tests/FlightDeckTests/SurfaceProcessRegistryTests.swift \
        Sources/FlightDeck/SessionStore.swift
git commit -m "feat: record each session's shell pid at surface creation"
```

---

### Task 4: Reap before free on tab close

The core behavior change: `closeSession` kills the tree *before* letting the surface go.

**Background the implementer needs:** dropping the `SurfaceView` leads to `ghostty_surface_free` → `Surface.deinit` → `io_thr.join()` → libghostty's blocking `killpg` loop, and that loop runs on the main actor (`vendor/ghostty/src/Surface.zig:790-795`, `Exec.zig:1152-1185`). If we reap first, that loop finds a dead child and returns immediately; if we reap after — or concurrently — the main thread blocks for the duration. That is the difference between a fix and a beachball.

Two related details: today `closeSession` never calls `removeFromSuperview()`, so a *selected* tab's surface stays retained by `TerminalHostView` until SwiftUI's next `updateNSView` pass (`TerminalPane.swift:40-42`); and while the reap runs, libghostty may post `ghosttyCloseSurface` for a surface no longer in `surfaces` — `observeSurfaceClose` (`SessionStore.swift:657-670`) already returns on a miss, and the test below pins that.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`closeSession`, lines 416-443; stored properties near line 41)
- Test: `Tests/FlightDeckTests/SessionCloseReapTests.swift` (create)

**Interfaces:**
- Consumes: `SessionReaper`, `ReapOutcome`, `PosixSignals`, `RealSleeper` (Task 2); `SurfaceProcessRegistry`, `SessionProcess` (Task 3).
- Produces:
  - `protocol ReapReporting: AnyObject { func report(_ outcome: ReapOutcome, context: String) }`
  - `final class LoggingReapReporter: ReapReporting` (the default)
  - `SessionStore.reaper: SessionReaper` (injectable via a new `init` parameter defaulting to the real one)
  - `SessionStore.reapReporter: ReapReporting?`
  - `func SessionStore.reapSession(_ id: UUID, process: SessionProcess?, context: String) async` — the shared teardown used by close and quit

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/SessionCloseReapTests.swift`:

```swift
// Tests/FlightDeckTests/SessionCloseReapTests.swift
import XCTest
@testable import FlightDeck

private final class StubProvider: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
    func tick() {}
}

private final class SpyReporter: ReapReporting, @unchecked Sendable {
    var reported: [ReapOutcome] = []
    var sweeps: [Int] = []
    func report(_ outcome: ReapOutcome, context: String) { reported.append(outcome) }
    func reportSweep(cleaned: Int) { sweeps.append(cleaned) }
}

@MainActor
final class SessionCloseReapTests: XCTestCase {
    private func store() -> SessionStore {
        SessionStore(provider: StubProvider(), persistence: nil)
    }

    /// A tab with no recorded process must still close cleanly — this is every tab created
    /// by a stub provider, and every tab whose pid diff came back ambiguous.
    func testClosingATabWithNoRecordedProcessStillCloses() {
        let s = store()
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))

        s.closeSession(session.id)

        XCTAssertTrue(s.repos.flatMap(\.sessions).isEmpty)
    }

    func testClosingForgetsTheProcessRecord() {
        let s = store()
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))
        s.processRegistry.restore([
            session.id: SessionProcess(
                identity: ProcessIdentity(pid: 31337, procStart: 1), pgid: 31337
            )
        ])

        s.closeSession(session.id)

        XCTAssertNil(s.processRegistry.process(for: session.id))
    }

    /// The row must vanish synchronously; only the invisible surface teardown is deferred.
    func testTheRowDisappearsImmediatelyEvenThoughTheReapIsAsync() {
        let s = store()
        let first = s.newSession(in: URL(fileURLWithPath: "/tmp"))
        let second = s.newSession(in: URL(fileURLWithPath: "/tmp"))

        s.closeSession(first.id)

        XCTAssertEqual(s.repos.flatMap(\.sessions).map(\.id), [second.id])
        XCTAssertEqual(s.selectedSessionID, second.id)
    }

    /// A close notification for a surface the store no longer knows about must be a no-op,
    /// not a crash or a second close — this interleaving is new with parked surfaces.
    func testCloseNotificationForAnUnknownSurfaceIsIgnored() {
        let s = store()
        let session = s.newSession(in: URL(fileURLWithPath: "/tmp"))

        // No object at all: `observeSurfaceClose` casts `note.object` to a `SurfaceView` and
        // returns on failure, which is the same path a parked surface's late close takes.
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyCloseSurface, object: nil
        )

        XCTAssertEqual(s.repos.flatMap(\.sessions).map(\.id), [session.id])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ReapReporting' in scope` / `value of type 'SessionStore' has no member 'processRegistry'` is already satisfied by Task 3, so the failure is on `ReapReporting` and `SpyReporter`.

- [ ] **Step 3: Add the reporting seam**

Append to `Sources/FlightDeck/SessionReaper.swift`:

```swift
/// Where reap outcomes go.
///
/// A protocol rather than a direct call for the reason `Notifying` documents
/// (`SessionNotifier.swift:12-16`): the real reporter posts a user notification, and
/// `UNUserNotificationCenter.current()` traps when the calling binary is not a signed
/// bundle — exactly the case inside the unit-test bundle. Nothing a test can reach may
/// touch it.
protocol ReapReporting: AnyObject {
    func report(_ outcome: ReapOutcome, context: String)
    /// A launch-time sweep found and killed orphans from a previous run. Separate from
    /// `report` because this one is worth telling the user about on *success* — it is the
    /// only evidence they get that a previous run leaked, whereas a clean tab close is
    /// deliberately silent.
    func reportSweep(cleaned: Int)
}

/// The default: the log and nothing else. Task 7 adds the user-facing reporter.
final class LoggingReapReporter: ReapReporting {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "ReapReporter"
    )

    func report(_ outcome: ReapOutcome, context: String) {
        switch outcome {
        case .clean:
            Self.logger.debug("\(context): process tree terminated")
        case .survivors(let survivors):
            let pids = survivors.map { String($0.pid) }.joined(separator: ", ")
            Self.logger.error("\(context): survived SIGKILL: \(pids)")
        }
    }

    func reportSweep(cleaned: Int) {
        Self.logger.info("orphan sweep cleaned \(cleaned) process tree(s) from a previous run")
    }
}
```

- [ ] **Step 4: Rewrite `closeSession`**

Add these stored properties next to `processRegistry` in `SessionStore`:

```swift
    /// Off-main-actor process teardown. See `SessionReaper`.
    private let reaper: SessionReaper
    var reapReporter: ReapReporting? = LoggingReapReporter()

    /// Surfaces whose tab is gone but whose process is still being killed.
    ///
    /// Holding the view here is what orders the teardown correctly: releasing it runs
    /// `ghostty_surface_free`, which joins libghostty's IO thread and spins in its own
    /// `killpg` loop *on the main actor*. Reaping first means that loop finds a dead child
    /// and returns at once instead of blocking the UI.
    private var parkedSurfaces: [UUID: Ghostty.SurfaceView] = [:]
```

Initialize `reaper` in both inits (the designated one at `SessionStore.swift:95` and the
convenience one at `:142`) — add a parameter to the designated init with a real default:

```swift
        reaper: SessionReaper = SessionReaper(
            inspector: ProcessTree(), signals: PosixSignals(), sleeper: RealSleeper()
        ),
```

Replace the body of `closeSession` (`SessionStore.swift:416-443`). Everything through
`persist()` stays synchronous and in the same order; the surface handling changes:

```swift
    func closeSession(_ id: UUID) {
        guard let (repoIndex, sessionIndex) = locate(id) else { return }
        repos[repoIndex].sessions.remove(at: sessionIndex)

        // Detach and park rather than release. Two reasons this is not just `= nil`:
        //
        // 1. `closeSession` never removed the view from its superview, so a *selected*
        //    tab's surface stayed retained by `TerminalHostView` until SwiftUI's next
        //    `updateNSView` pass (`TerminalPane.swift:40-42`). Detaching here makes the
        //    close immediate and independent of that pass.
        // 2. Releasing the view runs `ghostty_surface_free` on the main actor, which joins
        //    the IO thread and spins in libghostty's SIGHUP-only `killpg` loop
        //    (`vendor/ghostty/src/termio/Exec.zig:1152-1185`). We hold the view until our
        //    own reap has killed the tree, so that loop finds a dead child and returns.
        if let surface = surfaces.removeValue(forKey: id) {
            surface.removeFromSuperview()
            parkedSurfaces[id] = surface
        }
        let doomed = processRegistry.forget(id)

        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        statuses.removeValue(forKey: id)
        subagentCounts.removeValue(forKey: id)
        anchors.removeValue(forKey: id)
        // Closing the row is the most literal case of "a prompt that will never resolve",
        // and applyRegistry cannot observe the waiting -> gone edge here because both its
        // before and after snapshots already lack this id.
        notifier?.withdraw(sessionID: id)
        if repos[repoIndex].sessions.isEmpty {
            repos.remove(at: repoIndex)
        }
        if selectedSessionID == id {
            // The first *session*, not the first repo's first session: `moveSession`
            // deliberately leaves an emptied source project standing, so `repos.first` can
            // be empty while live tabs sit in a later section. Reading through it would
            // clear the selection and drop the whole app to the "No Session" empty state.
            selectedSessionID = repos.flatMap(\.sessions).first?.id
        }
        persist()

        Task { [weak self] in
            await self?.reapSession(id, process: doomed, context: "tab close")
        }
    }

    /// Kill a tab's process tree, then release its parked surface. Shared by tab close and
    /// app quit, which differ only in their budget and in who waits for them.
    func reapSession(_ id: UUID, process: SessionProcess?, context: String) async {
        if let process {
            let outcome = await reaper.reap(shell: process.identity, pgid: process.pgid)
            reapReporter?.report(outcome, context: context)
        }
        // Releasing last: the deferred `ghostty_surface_free` this triggers now has nothing
        // left to wait for.
        parkedSurfaces.removeValue(forKey: id)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all four `SessionCloseReapTests` pass; `SurfaceLifecycleTests` still passes (it drains the main queue, which now also drains the parked-surface release).

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/SessionReaper.swift \
        Tests/FlightDeckTests/SessionCloseReapTests.swift
git commit -m "feat: reap a session's process tree before freeing its surface"
```

---

### Task 5: Persist the records and sweep orphans at launch

Covers the crash path: Flight Deck dies, its shells keep running, the next launch cleans up.

**Background the implementer needs:** `SessionSnapshot.Entry` documents the migration rule this task must follow (`SessionPersistence.swift:12-17`) — synthesized `Codable` decodes optionals with `decodeIfPresent`, so **new fields must be optional** or the first launch after this change throws and wipes every tab. The `owner` field is the safety interlock: without it, two Flight Deck instances sharing `sessions.json` would reap each other's children on launch.

**Files:**
- Modify: `Sources/FlightDeck/SessionPersistence.swift` (`SessionSnapshot`, lines 7-36)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`persist`, lines 351-366; `restore`, lines 307-348)
- Test: `Tests/FlightDeckTests/OrphanSweepTests.swift` (create)

**Interfaces:**
- Consumes: `ProcessIdentity`, `ProcessInspecting`, `ProcessTree` (Task 1); `SessionReaper` (Task 2); `SessionProcess`, `SurfaceProcessRegistry` (Task 3); `ReapReporting` (Task 4).
- Produces:
  - `SessionSnapshot.processes: [String: SessionProcess]?` (keys are `UUID.uuidString` — `[UUID: …]` encodes as an array in JSON, which is a worse thing to read on disk)
  - `SessionSnapshot.owner: ProcessIdentity?`
  - `@MainActor func SessionStore.sweepOrphans(from snapshot: SessionSnapshot) async`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/OrphanSweepTests.swift`:

```swift
// Tests/FlightDeckTests/OrphanSweepTests.swift
import XCTest
@testable import FlightDeck

private final class StubProvider: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
    func tick() {}
}

private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    var living: Set<pid_t>
    init(living: Set<pid_t>) { self.living = living }
    func children(of ppid: pid_t) -> Set<pid_t> { [] }
    func descendants(of pid: pid_t) -> [ProcessIdentity] { [] }
    func startTime(of pid: pid_t) -> UInt64? { living.contains(pid) ? 100 : nil }
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        living.contains(identity.pid) && identity.procStart == 100
    }
}

private final class SpySignals: SignalSending, @unchecked Sendable {
    var targets: [pid_t] = []
    var onSend: ((pid_t) -> Void)?
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool {
        targets.append(pgid); onSend?(pgid); return true
    }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool {
        targets.append(pid); onSend?(pid); return true
    }
    func ownProcessGroup() -> pid_t { 999 }
}

private struct InstantSleeper: ReaperSleeping {
    func sleep(seconds: Double) async {}
}

@MainActor
final class OrphanSweepTests: XCTestCase {
    private func snapshot(
        owner: ProcessIdentity?, processes: [String: SessionProcess]
    ) -> SessionSnapshot {
        var s = SessionSnapshot()
        s.owner = owner
        s.processes = processes
        return s
    }

    /// The same fake feeds both the reaper (which decides when a target has died) and the
    /// store's own liveness checks (which decide what is worth signalling at all).
    private func store(
        inspector: ProcessInspecting, signals: SignalSending
    ) -> SessionStore {
        let s = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: inspector, signals: signals, sleeper: InstantSleeper()
            )
        )
        s.processInspector = inspector
        return s
    }

    /// A v1 snapshot has neither field. It must decode and sweep nothing.
    func testALegacySnapshotDecodesAndSweepsNothing() async throws {
        let legacy = #"{"sessions":[],"sessionCounter":0}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: legacy)
        XCTAssertNil(decoded.processes)
        XCTAssertNil(decoded.owner)

        let signals = SpySignals()
        await store(inspector: FakeInspector(living: []), signals: signals)
            .sweepOrphans(from: decoded)

        XCTAssertTrue(signals.targets.isEmpty)
    }

    /// The interlock: the writing instance is still running, so those are its live children.
    func testDoesNotSweepWhenTheOwnerIsStillAlive() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)
        let orphan = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100), pgid: 600
        )
        let signals = SpySignals()

        await store(inspector: FakeInspector(living: [500, 600]), signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: orphan]))

        XCTAssertTrue(signals.targets.isEmpty)
    }

    func testSweepsALiveOrphanWhenTheOwnerIsGone() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)   // not in `living`
        let orphan = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 100), pgid: 600
        )
        let inspector = FakeInspector(living: [600])
        let signals = SpySignals()
        signals.onSend = { _ in inspector.living.remove(600) }

        await store(inspector: inspector, signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: orphan]))

        XCTAssertEqual(signals.targets, [600])
    }

    /// The recorded pid was recycled by an unrelated process. Never signal it.
    func testDoesNotSweepARecycledPid() async {
        let owner = ProcessIdentity(pid: 500, procStart: 100)
        let stale = SessionProcess(
            identity: ProcessIdentity(pid: 600, procStart: 42), pgid: 600
        )
        let signals = SpySignals()

        await store(inspector: FakeInspector(living: [600]), signals: signals)
            .sweepOrphans(from: snapshot(owner: owner, processes: [UUID().uuidString: stale]))

        XCTAssertTrue(signals.targets.isEmpty)
    }

    func testSnapshotRoundTripsTheNewFields() throws {
        let s = snapshot(
            owner: ProcessIdentity(pid: 1, procStart: 2),
            processes: ["tab": SessionProcess(
                identity: ProcessIdentity(pid: 3, procStart: 4), pgid: 5
            )]
        )

        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(back, s)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'SessionSnapshot' has no member 'owner'`.

- [ ] **Step 3: Add the snapshot fields**

In `Sources/FlightDeck/SessionPersistence.swift`, add to `SessionSnapshot` (after
`sessionCounter`, line 35):

```swift
    /// Each tab's shell, so a run that dies without teardown can be cleaned up on the next
    /// launch. Keyed by `UUID.uuidString` because a `[UUID: …]` dictionary encodes as a flat
    /// array in JSON, and this file is meant to stay readable.
    ///
    /// Optional for the same load-bearing reason as `Entry.pinnedConversationID` above:
    /// synthesized `Codable` decodes an optional with `decodeIfPresent`, so every existing
    /// `sessions.json` still decodes. A non-optional field would throw and wipe every tab on
    /// the first launch after this change.
    var processes: [String: SessionProcess]?

    /// The Flight Deck run that wrote this snapshot.
    ///
    /// The launch-time sweep only runs when this process is *gone*. Without the check, a
    /// second concurrent instance would read the first instance's records and kill its live
    /// children.
    var owner: ProcessIdentity?
```

- [ ] **Step 4: Write the fields**

`persist()` (`SessionStore.swift:351-366`) currently builds the snapshot inline as one
expression. Rewrite it to build a `var` so the two new fields can be set:

```swift
    private func persist() {
        var snapshot = SessionSnapshot(
            sessions: repos.flatMap(\.sessions).map {
                .init(
                    id: $0.id,
                    title: $0.title,
                    workingDirectory: $0.workingDirectory,
                    pinnedConversationID: $0.pinnedConversationID
                )
            },
            selectedSessionID: selectedSessionID,
            sessionCounter: sessionCounter
        )
        snapshot.processes = Dictionary(
            uniqueKeysWithValues: processRegistry.all.map { ($0.key.uuidString, $0.value) }
        )
        // Stamped on every save so the next launch can tell "this run is still going" from
        // "this run died and left its children behind".
        snapshot.owner = ProcessTree().identity(of: getpid())
        persistence?.save(snapshot)
    }
```

- [ ] **Step 5: Sweep at launch**

**Not** inside `restore()`. That method returns early when the snapshot has no sessions
(`SessionStore.swift:311-313`), and it calls `persist()` at the end — which would overwrite
`sessions.json` with *this* run's owner before an async sweep ever read the old one. Instead
capture the previous snapshot in the convenience init, before anything writes, and sweep from
that captured value.

In the convenience init (`SessionStore.swift:142-157`), between `self.notifier = notifier` and
the restore line:

```swift
        // Captured BEFORE `restore()`, which persists at the end and would otherwise replace
        // the previous run's records with this one's. The sweep itself is async and may land
        // well after that write; it works from this snapshot, not from disk.
        let previousRun = persistence?.load()
```

and after `startStatusWatching()`:

```swift
        if let previousRun {
            Task { [weak self] in await self?.sweepOrphans(from: previousRun) }
        }
```

- [ ] **Step 6: Add the sweep**

Add to `SessionStore`, next to `processRegistry`. The inspector is a settable property rather
than a `ProcessTree()` created inside the sweep because the sweep's own liveness checks are
what the tests below drive — with a hard-coded real inspector, "sweeps a live orphan" would
never fire (pid 601 is not alive on the test machine) and "does not sweep a recycled pid" would
pass for the wrong reason:

```swift
    /// The process table the orphan sweep reads. Settable so tests can script it.
    var processInspector: ProcessInspecting = ProcessTree()
```

and the sweep itself:

```swift
    /// Terminate processes recorded by a previous run that outlived it.
    ///
    /// Gated twice over: the recording instance must be gone (otherwise these are somebody
    /// else's live children, and killing them would be a second Flight Deck instance
    /// sabotaging the first), and each identity's start time must still match (otherwise the
    /// pid has been recycled and now belongs to an unrelated process).
    func sweepOrphans(from snapshot: SessionSnapshot) async {
        guard let recorded = snapshot.processes, !recorded.isEmpty else { return }
        if let owner = snapshot.owner, processInspector.isAlive(owner) { return }

        var cleaned = 0
        for (_, process) in recorded where processInspector.isAlive(process.identity) {
            let outcome = await reaper.reap(shell: process.identity, pgid: process.pgid)
            reapReporter?.report(outcome, context: "orphan sweep")
            cleaned += 1
        }
        if cleaned > 0 { reapReporter?.reportSweep(cleaned: cleaned) }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all five `OrphanSweepTests` pass, and `SessionPersistenceTests` still passes
(proving the v1 snapshot still decodes).

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionPersistence.swift Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/OrphanSweepTests.swift
git commit -m "feat: persist session pids and sweep orphans left by a dead run"
```

---

### Task 6: Reap on app quit

**Background the implementer needs:** `AppDelegate` currently has no termination hook at all — quitting exits and leans on the kernel SIGHUP'ing each pty's foreground group when the master fd closes, which has the same SIGHUP-ignoring hole. The `.terminateLater` contract requires `reply(toApplicationShouldTerminate:)` to be called exactly once, and if it is never called the app hangs on quit forever. The total budget below is what makes that impossible: when it expires we reply `true` regardless and let the survivors be reported by the next launch's sweep.

`AppDelegate` does not own the store (`AppDelegate.swift:4-13` is explicit that it owns nothing), so the store announces itself through a notification, matching how `flightDeckActivateSession` already bridges the same gap.

**Files:**
- Modify: `Sources/FlightDeck/AppDelegate.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (add `reapAllForQuit`)
- Test: `Tests/FlightDeckTests/QuitReapTests.swift` (create)

**Interfaces:**
- Consumes: `SessionProcess`, `SurfaceProcessRegistry` (Task 3); `SessionStore.reapSession` (Task 4).
- Produces:
  - `@MainActor func SessionStore.reapAllForQuit(budget: Double) async` — returns when every session is reaped or the budget expires, whichever comes first
  - `SessionStore.quitBudget: Double` (static, 8.0)

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/QuitReapTests.swift`:

```swift
// Tests/FlightDeckTests/QuitReapTests.swift
import XCTest
@testable import FlightDeck

private final class StubProvider: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
    func tick() {}
}

private final class FakeInspector: ProcessInspecting, @unchecked Sendable {
    var living: Set<pid_t>
    init(living: Set<pid_t>) { self.living = living }
    func children(of ppid: pid_t) -> Set<pid_t> { [] }
    func descendants(of pid: pid_t) -> [ProcessIdentity] { [] }
    func startTime(of pid: pid_t) -> UInt64? { living.contains(pid) ? 100 : nil }
    func isAlive(_ identity: ProcessIdentity) -> Bool {
        living.contains(identity.pid) && identity.procStart == 100
    }
}

private final class SpySignals: SignalSending, @unchecked Sendable {
    var targets: [pid_t] = []
    var onSend: ((pid_t) -> Void)?
    func send(_ signal: Int32, toGroup pgid: pid_t) -> Bool {
        targets.append(pgid); onSend?(pgid); return true
    }
    func send(_ signal: Int32, toProcess pid: pid_t) -> Bool {
        targets.append(pid); onSend?(pid); return true
    }
    func ownProcessGroup() -> pid_t { 999 }
}

private struct InstantSleeper: ReaperSleeping {
    func sleep(seconds: Double) async {}
}

@MainActor
final class QuitReapTests: XCTestCase {
    func testQuitReapsEveryLiveSession() async {
        let inspector = FakeInspector(living: [601, 602])
        let signals = SpySignals()
        signals.onSend = { pid in inspector.living.remove(pid) }
        let store = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: inspector, signals: signals, sleeper: InstantSleeper()
            )
        )
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        let b = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100), pgid: 601),
            b.id: SessionProcess(identity: .init(pid: 602, procStart: 100), pgid: 602),
        ])

        await store.reapAllForQuit(budget: 5)

        XCTAssertEqual(Set(signals.targets), [601, 602])
    }

    /// Quit must return even when nothing can be killed — the budget is the guarantee.
    func testQuitReturnsEvenWhenNothingDies() async {
        let store = SessionStore(
            provider: StubProvider(),
            persistence: nil,
            reaper: SessionReaper(
                inspector: FakeInspector(living: [601]),
                signals: SpySignals(),
                sleeper: InstantSleeper()
            )
        )
        let a = store.newSession(in: URL(fileURLWithPath: "/tmp"))
        store.processRegistry.restore([
            a.id: SessionProcess(identity: .init(pid: 601, procStart: 100), pgid: 601)
        ])

        await store.reapAllForQuit(budget: 1)

        XCTAssertTrue(true, "returned rather than hanging")
    }

    func testQuitWithNoSessionsIsANoOp() async {
        let store = SessionStore(provider: StubProvider(), persistence: nil)
        await store.reapAllForQuit(budget: 1)
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'SessionStore' has no member 'reapAllForQuit'`.

- [ ] **Step 3: Add `reapAllForQuit`**

Add to `SessionStore`:

```swift
    /// Total wall-clock budget for reaping every session at quit. Not per-session: quitting
    /// with twelve tabs open must not take twelve times as long.
    static let quitBudget: Double = 8.0

    /// Reap every live session concurrently, returning when they are all done or the budget
    /// expires — whichever comes first. Survivors are left for the next launch's sweep.
    func reapAllForQuit(budget: Double = SessionStore.quitBudget) async {
        let live = processRegistry.all
        guard !live.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for (id, process) in live {
                group.addTask { [weak self] in
                    await self?.reapSession(id, process: process, context: "app quit")
                }
            }
            // The deadline task makes the cap real: whichever finishes first wins, and the
            // group is cancelled either way, so quit can never hang on a stuck child.
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            }
            await group.next()
            group.cancelAll()
        }
        processRegistry.restore([:])
    }
```

- [ ] **Step 4: Hook up `AppDelegate`**

Add to `Sources/FlightDeck/AppDelegate.swift`:

```swift
extension Notification.Name {
    /// Posted by `SessionStore.init` so the delegate can find the store it does not own.
    /// A notification hop for the same reason `flightDeckActivateSession` is one: the
    /// delegate is created by `@NSApplicationDelegateAdaptor` and the store by
    /// `FlightDeckApp.init`, with no ordering guarantee between them.
    static let flightDeckStoreReady = Notification.Name("FlightDeckStoreReady")
}
```

In `AppDelegate`:

```swift
    private weak var store: SessionStore?

    /// Registered here rather than in `applicationDidFinishLaunching` so a store created
    /// before launch completes is still seen.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NotificationCenter.default.addObserver(
            forName: .flightDeckStoreReady, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.store = note.object as? SessionStore }
        }
    }

    /// Quitting used to kill nothing: the app just exited and left the kernel to SIGHUP each
    /// pty's foreground group, which anything ignoring SIGHUP survives. Now every session's
    /// tree is reaped first, under one total budget so quit cannot hang.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task { @MainActor in
            await store.reapAllForQuit()
            // Exactly once, on every path: not calling this hangs the quit forever.
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
```

At the end of `SessionStore`'s designated `init` (`SessionStore.swift:95-105`), announce it:

```swift
        NotificationCenter.default.post(name: .flightDeckStoreReady, object: self)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all three `QuitReapTests` pass, whole suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/AppDelegate.swift Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/QuitReapTests.swift
git commit -m "feat: reap every session's process tree before the app quits"
```

---

### Task 7: The proof, and the user-facing report

The acceptance test that fails against the old behavior, plus the notification the spec promises.

**Background the implementer needs:** this test spawns a real shell that *ignores SIGHUP* and runs the real reaper against it — real signals, real libproc, no fakes. It is the only test that proves the original hole is closed, because everything else stubs the process table. It works headlessly (no host app) precisely because it never touches a ghostty surface. The self-group rail from Task 2 is what makes it safe: `Foundation.Process` children share the test runner's process group, so without that rail the reaper would `killpg` the test runner itself.

**Files:**
- Modify: `Sources/FlightDeck/SessionReaper.swift` (add the user-facing reporter)
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (install it — check where `notifier` is assigned and follow that pattern)
- Test: `Tests/FlightDeckTests/ReaperAcceptanceTests.swift` (create)

**Interfaces:**
- Consumes: everything from Tasks 1-4; the convenience init's parameter list
  (`SessionStore.swift:142-157`), which gains `reapReporter` between `notifier` and
  `persistence` — Swift call sites must keep that order.
- Produces:
  - `final class UserNotificationReapReporter: ReapReporting`
  - `SessionStore.init(ghostty:resetState:preferences:notifier:reapReporter:persistence:)`

- [ ] **Step 1: Write the failing acceptance test**

Create `Tests/FlightDeckTests/ReaperAcceptanceTests.swift`:

```swift
// Tests/FlightDeckTests/ReaperAcceptanceTests.swift
import XCTest
@testable import FlightDeck

/// End-to-end against real processes. No fakes: real signals, real libproc, real waiting.
///
/// This is the test that fails against the behavior this work replaces — libghostty sends
/// SIGHUP and only SIGHUP, and the tree below is built specifically to survive that.
final class ReaperAcceptanceTests: XCTestCase {
    private func reaper() -> SessionReaper {
        SessionReaper(inspector: ProcessTree(), signals: PosixSignals(), sleeper: RealSleeper())
    }

    /// `trap '' HUP` makes the shell ignore SIGHUP entirely, and it forks a child that
    /// outlives a naive single-signal teardown.
    func testKillsAShellThatIgnoresSIGHUPAlongWithItsChild() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "trap '' HUP; sleep 300 & sleep 300"]
        try shell.run()
        defer { if shell.isRunning { kill(shell.processIdentifier, SIGKILL) } }

        // Let `sh` install the trap and fork its child.
        try await Task.sleep(nanoseconds: 500_000_000)

        let tree = ProcessTree()
        let identity = try XCTUnwrap(tree.identity(of: shell.processIdentifier))
        let descendants = tree.descendants(of: identity.pid)
        XCTAssertFalse(descendants.isEmpty, "expected the shell to have forked a child")

        // Confirm the premise: SIGHUP alone does not kill this tree.
        XCTAssertEqual(kill(identity.pid, SIGHUP), 0)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(tree.isAlive(identity), "premise broken: SIGHUP killed a trapping shell")

        let outcome = await reaper().reap(shell: identity, pgid: getpgid(identity.pid))

        XCTAssertEqual(outcome, .clean)
        XCTAssertFalse(tree.isAlive(identity), "the shell survived the ladder")
        for child in descendants {
            XCTAssertFalse(tree.isAlive(child), "child \(child.pid) survived the ladder")
        }
    }

    /// The rail that keeps the line above from killing this very test process.
    func testNeverSignalsTheTestRunnersOwnGroup() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 30"]
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }

        let tree = ProcessTree()
        let identity = try XCTUnwrap(tree.identity(of: child.processIdentifier))
        // `Process` does not setsid, so this child shares our group. A killpg here would
        // take down the test runner.
        XCTAssertEqual(getpgid(identity.pid), getpgid(0))

        _ = await reaper().reap(shell: identity, pgid: getpgid(identity.pid))

        XCTAssertFalse(tree.isAlive(identity))
        // Reaching this line at all is the assertion: we are still running.
    }
}
```

- [ ] **Step 2: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: both `ReaperAcceptanceTests` **pass** — Tasks 1-2 already built what they exercise. This is the one place the plan does not expect a red first run; the test's job is to prove the ladder works end to end, and its `XCTAssertTrue(tree.isAlive(identity))` mid-test assertion is what pins the premise that SIGHUP alone was never enough.

- [ ] **Step 3: Add the user-facing reporter**

Append to `Sources/FlightDeck/SessionReaper.swift`:

```swift
/// Tells the user when a teardown did not finish. Silent on success by design: closing a tab
/// stays a one-click, no-dialog gesture, and the only things worth interrupting someone for
/// are a process that survived SIGKILL and an orphan sweep that found work to do.
///
/// Never construct this from a test — see the note on `ReapReporting`.
final class UserNotificationReapReporter: ReapReporting {
    private let fallback = LoggingReapReporter()

    func report(_ outcome: ReapOutcome, context: String) {
        fallback.report(outcome, context: context)
        guard case .survivors(let survivors) = outcome, !survivors.isEmpty else { return }

        let content = UNMutableNotificationContent()
        content.title = "Processes still running"
        let pids = survivors.map { String($0.pid) }.joined(separator: ", ")
        content.body = survivors.count == 1
            ? "One process (pid \(pids)) could not be terminated after \(context)."
            : "\(survivors.count) processes (pids \(pids)) could not be terminated after \(context)."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: "reap.\(context).\(pids)", content: content, trigger: nil
            )
        )
    }

    func reportSweep(cleaned: Int) {
        fallback.reportSweep(cleaned: cleaned)

        let content = UNMutableNotificationContent()
        content.title = "Cleaned up after a previous session"
        content.body = cleaned == 1
            ? "One process left running by an earlier launch was terminated."
            : "\(cleaned) processes left running by an earlier launch were terminated."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "reap.sweep", content: content, trigger: nil)
        )
    }
}
```

Add `import UserNotifications` to the top of `SessionReaper.swift`.

- [ ] **Step 4: Install it**

The reporter must be constructed in `FlightDeckApp.makeStore` and **passed into** the store,
not assigned afterwards — for both reasons that file already documents for `notifier`
(`FlightDeckApp.swift:41-49`): `UNUserNotificationCenter` traps outside a signed bundle and
`makeStore` is the one construction path tests cannot reach, and the launch-time orphan sweep
fires from the convenience init, so a reporter assigned after construction would miss it.

Add the parameter to the convenience init (`SessionStore.swift:142-157`), alongside `notifier`:

```swift
        reapReporter: ReapReporting? = nil,
```

and assign it in the body immediately after `self.notifier = notifier`, before the
`previousRun` capture from Task 5:

```swift
        // Before the sweep below, which reports through it.
        if let reapReporter { self.reapReporter = reapReporter }
```

Then in `FlightDeckApp.makeStore` (`FlightDeckApp.swift:60-66`), pass it:

```swift
        return SessionStore(
            ghostty: GhosttyApp.shared,
            resetState: resetState,
            preferences: preferences,
            notifier: notifier,
            reapReporter: UserNotificationReapReporter(),
            persistence: resetState ? nil : FileSessionPersistence()
        )
```

- [ ] **Step 5: Run the full suite**

Run: `./scripts/test-unit.sh`
Expected: entire suite green, including every test from Tasks 1-6.

- [ ] **Step 6: Verify the fix by hand**

Build and run the app, then in a session run:

```sh
trap '' HUP; sleep 600 &
echo $!
```

Note the pid, close the tab, and check within ~6 seconds:

```sh
ps -p <pid>
```

Expected: no such process. Before this work, that pid survived indefinitely.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionReaper.swift Sources/FlightDeck/FlightDeckApp.swift \
        Tests/FlightDeckTests/ReaperAcceptanceTests.swift
git commit -m "feat: report unkillable processes and prove the ladder end to end"
```
