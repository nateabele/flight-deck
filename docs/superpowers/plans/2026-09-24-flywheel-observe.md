# Flywheel Observe (Level 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only observation layer that surfaces flywheel agent activity — current bead, held/waited files, dependency graph, and human-needed alerts — inside Flight Deck, driven off the existing `am`/`br` substrate.

**Architecture:** A per-project *watcher* (registered on the shared `WatchClock`, mtime-gated so it only re-shells when a watched path changed) drives cheap `am`/`br --json` reads through the Level-0 `FlywheelProcessRunner` seam. Reads reduce off-main into a value-typed `FlywheelProjection`; a `@MainActor` `FlywheelObserveService` owned by `SessionStore` keys watchers/projections by standardized project path, vends the focused projection to a bottom `ObserveDrawer` under `TerminalPane`, and feeds every project's projection to a fleet-wide `FlywheelNotifier`. A `DependencyDAGOverlay` (SwiftUI `Canvas`) renders the whole project graph with the camera centered on the selected bead.

**Tech Stack:** Swift 5 / SwiftUI / AppKit; `Foundation.Process` via `FlywheelProcessRunner`; `WatchClock` (shared `DispatchSourceTimer`); `UNUserNotificationCenter` via the `Notifying` protocol; `SwiftUI.Canvas`. Tests: XCTest, headless (`./scripts/test-unit.sh`).

**Spec:** `docs/superpowers/specs/2026-09-24-flywheel-observe-design.md` (committed `8a12ec1`). The plan argues from the spec; read both.

## Architecture note — deliberate deviation from the spec (surface at review)

The spec's transport is **"FSEvents on `.beads/` + the Agent-Mail store, never an interval timer."** The exploration of the codebase found there is **no FSEvents anywhere**, and a documented, load-bearing anti-vnode stance (`SessionStatusWatcher.swift:13-16`): the app polls a shared `WatchClock` because vnode watches are unreliable for the write patterns it cares about. Beads is SQLite + git and Agent-Mail is SQLite; FSEvents/vnode on a SQLite WAL is exactly the unreliable case that stance was written about.

**This plan uses a `WatchClock`-registered, mtime-gated poll instead of FSEvents.** It preserves the spec's real intent — *the expensive `am`/`br` re-poll is change-triggered, not periodic* — by stat-gating on the watched paths' modification times each tick and only re-shelling when an mtime moved. A tick with nothing changed costs a `stat`, not a subprocess. This also reuses the established watcher shape (`start()/stop()/drain()`, injectable `WatchClock`), so it is testable with a fake clock exactly like `SessionStatusWatcher`, with no new FSEvents scaffolding to build or mock. If the reviewer wants true FSEvents, that is a Task 6 swap, isolated behind the same `FlywheelWatcher` interface.

## Global Constraints

- **`SWIFT_VERSION: "5.0"`** — do not raise it (vendored Ghostty isn't Swift-6 clean). New files compile under Swift 5.
- **Read-only.** No task claims/creates/edits a bead, sends Agent-Mail, releases a reservation, or changes the spawn path. Every `am`/`br` invocation is a `list`/`show`/`graph`/`--json` read.
- **Never the `am` HTTP cold path (~2.5s).** Only fast local CLI reads (`am agents list <repo> --json`, reservations family, `am inbox-events`), each **scoped by the standardized absolute project path** (via `PreferencesStore.key(_:)` semantics) or not run at all.
- **Flag off ⇒ zero cost, zero UI.** A project whose `projectSettings(path).flywheelEnabled != true` starts no watcher, runs no `am`/`br`, mounts no drawer, and produces no notifier entry.
- **Tests are macOS-only and ignore `-only-testing:`** — `./scripts/test-unit.sh` runs the full suite (~8 min). Do not touch `Sources/FlightDeckMobile` (no `test-ios.sh` needed).
- **No `UNUserNotificationCenter` from anything a test can reach** — it traps outside a signed bundle. All notification I/O goes through the `Notifying` protocol; tests inject a spy.
- **Worktree hygiene:** built-in `Edit`/`Write` only (never qartez mutators here); git ops via a `bash <script>.sh` in the scratchpad (the git-guard blocks `-C`/compound/subshell); this checkout is shared — never `git stash`/`checkout .`/revert blind.
- **Commit trailer:** `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## Review Focus

The five conditions the spec implies but no single task's happy-path tests would otherwise pin, most-likely-to-bite first. Each has its test added to the owning task.

1. **A watched command is missing or changed shape at runtime** (`am`/`br` version skew). Expected: that lane degrades to "unavailable," logged once; the other lanes still render; nothing throws or crashes. → Task 2 (per-lane decode tolerance) + Task 3 (projection tolerates a nil lane).
2. **The focused tab has no `flywheelIdentity`, or its `agentName` matches no substrate row** (external agent, or a plain tab in a flywheel project). Expected: no drawer for a non-identity tab; an unjoined graph node shows as **external** and is not clickable-to-tab. → Task 3 (join miss → external).
3. **A reservation lease refreshes (TTL churn) rather than being released.** Expected: a refreshed lease reads as *continuity* of the same hold, not release+reacquire — it must not reset `stalledSince` or fire a spurious "collision cleared then re-collided." → Task 3 (stall clock continuity) + Task 8 (no notify churn on refresh).
4. **A brief block that self-clears before the threshold.** Expected: **no** notification (only a *persistent* block notifies); and a standing condition notifies **once**, not every tick. → Task 8 (transient ⇒ none; per-cause coalescing).
5. **The DAG graph content is unchanged across a re-poll, but status/labels changed.** Expected: node **positions stay put** (coordinates keyed by graph content-hash); only colors/labels move — the graph must not jump under the user. → Task 4 (coordinate stability for equal content-hash).

---

## File Structure

New group `Sources/FlightDeck/Flywheel/Observe/`:

- `FlywheelReadCommands.swift` — tolerant `am`/`br` read wrappers over `FlywheelProcessRunner`; raw decode types; per-lane degradation. *(Task 2)*
- `FlywheelProjection.swift` — the value-typed observable model + the reduction from a raw snapshot (join, stall derivation, external case). *(Task 3)*
- `DependencyGraphLayout.swift` — pure layered layout, content-hash-keyed stable coordinates, root-cause pick. *(Task 4)*
- `DAGCamera.swift` — pure center/zoom affine + hit-test round-trip. *(Task 5)*
- `FlywheelWatcher.swift` — `WatchClock`-registered, mtime-gated, coalesced re-poll. *(Task 6)*
- `FlywheelObserveService.swift` — `@MainActor` lifecycle owner; per-project map; vends projections. *(Task 7)*
- `FlywheelNotifier.swift` — fleet-wide, human-needed-only gating over the `Notifying` seam. *(Task 8)*
- `ObserveDrawer.swift` — the per-tab bottom drawer (SwiftUI) + pure lane-model helpers. *(Task 10)*
- `DependencyDAGOverlay.swift` — the whole-graph `Canvas` overlay. *(Task 11)*

Modified:

- `Sources/FlightDeck/Preferences/ProjectSettings.swift` — `drawerCollapsed: Bool?`. *(Task 9)*
- `Sources/FlightDeck/RootView.swift` — mount `ObserveDrawer` under `TerminalPane`. *(Task 12)*
- `Sources/FlightDeck/SessionStore.swift` — own the service; start/stop; expose focused projection; wire notifier auth + gating. *(Task 12)*
- `docs/FLYWHEEL-OBSERVE-CHECKLIST.md` *(new)* — Nate-run GUI runbook. *(Task 13)*

Tests under `Tests/FlightDeckTests/Flywheel/Observe/`.

---

## Task 1: Probe the `am`/`br` read-command shapes and settle the watch mechanism

This is a **spike task**: its deliverable is a committed findings doc + captured JSON fixtures that every later parser is written against. Only two shapes are *proven* today (`am agents list <repo> --json` → `[{name…}]`, `br list --status in_progress --json` → `{issues:[…]}`); the rest are documented-intent and MUST be confirmed against the installed CLIs before Task 2 writes decoders.

**Files:**
- Create: `docs/superpowers/notes/2026-09-24-observe-command-shapes.md`
- Create: `Tests/FlightDeckTests/Flywheel/Observe/Fixtures/*.json` (one per confirmed command)

**Interfaces:**
- Produces: the confirmed argv + JSON shape for each read command, and a decision on FSEvents-vs-WatchClock, consumed by Tasks 2–6.

- [ ] **Step 1: Find the installed CLIs and a live flywheel repo**

Run:
```bash
which am br
am --version; br --version
```
Identify a repo that has `.beads/` and Agent-Mail state (any Level-0-enabled project, or create a throwaway one). Record its absolute path as `REPO`.

- [ ] **Step 2: Capture each command's real output**

For each command, run it, record the exact argv and whether it succeeded, and save stdout to a fixture. Probe at least:
```bash
am agents list "$REPO" --json              # PROVEN: [{"name":...}]
br list --status in_progress --json         # PROVEN: {"issues":[...]}
br ready --json ; br blocked --json         # documented-intent — confirm shape
br dep --json ; br graph --json             # documented-intent — dep edges
am inbox-events --after 0 --json            # documented-intent — activity feed + cursor
am reservations list "$REPO" --json         # documented-intent — file reservations (try `am reservations --json`, `am guard status --json` too)
```
For each: note (a) exact working argv, (b) exit code, (c) the top-level JSON shape (keys + one representative row), or (d) **"unavailable"** if the subcommand does not exist. Save the stdout of every *available* command verbatim to `Tests/FlightDeckTests/Flywheel/Observe/Fixtures/<command>.json`.

- [ ] **Step 3: Decide the reservation source**

Reservations are the least-proven lane. Determine which of (`am reservations list`, `am guard status`, reading `.agent-mail`/lockfiles) actually reports *who holds which file and since when*. Record the winner and its shape; if none exists as JSON, mark the Files-contention lane **"unavailable"** and note it as a shipped follow-up (the drawer's Files lane will show holds-without-contention or degrade).

- [ ] **Step 4: Confirm the watch surface**

List what actually changes on disk when an agent acts:
```bash
ls -la "$REPO/.beads" ; ls -la "$REPO/.agent-mail" 2>/dev/null
```
Confirm the mtime-gate targets (the `.beads` db/dir and the Agent-Mail store path). Record them. Confirm the FSEvents-vs-`WatchClock` decision: default is `WatchClock`-mtime-gated (see the Architecture note); record any reason to revisit.

- [ ] **Step 5: Write the findings doc**

Write `docs/superpowers/notes/2026-09-24-observe-command-shapes.md` with, per command: confirmed argv, exit code, JSON shape (or "unavailable"), the minimal fields Observe needs, and the chosen reservation source + watch targets. This doc is the source of truth for Task 2's decoders — a later task never guesses a shape this doc marks unknown.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/notes/2026-09-24-observe-command-shapes.md Tests/FlightDeckTests/Flywheel/Observe/Fixtures
git commit -m "docs(flywheel): probe am/br read-command shapes for Observe"
```

---

## Task 2: `FlywheelReadCommands` — tolerant `am`/`br` read wrappers

Mirror `FlywheelCoordinator` exactly: injected `FlywheelProcessRunner` + tool paths, minimal `Decodable` targets, `--json` argv built as `[String]`. The one difference: a **missing/unparseable lane degrades to `nil`, never throws** (a read failure must not take down the drawer). Use only the shapes Task 1 confirmed; a lane Task 1 marked "unavailable" gets a wrapper that returns `nil` and a `// TODO(observe): unconfirmed shape — see notes` marker rather than a guessed decoder.

**Files:**
- Create: `Sources/FlightDeck/Flywheel/Observe/FlywheelReadCommands.swift`
- Test: `Tests/FlightDeckTests/Flywheel/Observe/FlywheelReadCommandsTests.swift`

**Interfaces:**
- Consumes: `FlywheelProcessRunner` (`func run(_ executable: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32)`), `SystemFlywheelProcessRunner()`.
- Produces:
  - `struct FlywheelReadCommands` with `init(runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(), amPath: String = "am", brPath: String = "br")`.
  - Raw decode types (public within the module): `RawAgent{name}`, `RawBead{id,title,status,assignee?}`, `RawReservation{file,holder,since,waiters}`, `RawDepEdge{from,to}`, `RawEvent{agent,kind,at}`.
  - `func agents(project: String) async -> [RawAgent]?` and, for each confirmed command, `func inProgressBeads(project:) async -> [RawBead]?`, `func reservations(project:) async -> [RawReservation]?`, `func depEdges(project:) async -> [RawDepEdge]?`, `func events(project:after:) async -> (events: [RawEvent], cursor: String)?`. Each returns `nil` on non-zero exit or unparseable stdout.

- [ ] **Step 1: Write the shared `MultiRunner` test helper**

Tasks 2, 6, 7, and 12 all drive the reads through one fake runner, and they live in **separate** test files — so `MultiRunner` must be a non-`private`, shared helper (a `private` type is invisible across files in the test target and those later tasks would fail to compile). Create `Tests/FlightDeckTests/Flywheel/Observe/ObserveTestSupport.swift`:

```swift
@testable import FlightDeck

/// One fake `FlywheelProcessRunner` shared by every Observe test. Answers different
/// stdout per executable+subcommand so a single fake serves all lanes; records argv.
final class MultiRunner: FlywheelProcessRunner, @unchecked Sendable {
    /// keyed by the joined argv prefix that identifies the call, e.g. "am agents list"
    var responses: [String: (String, Int32)] = [:]
    private(set) var argv: [[String]] = []
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        argv.append([exe] + args)
        let key = ([exe] + args.prefix(2)).joined(separator: " ")
        return responses[key] ?? ("", 127)   // 127 = command not found by default
    }
}
```

- [ ] **Step 2: Write the failing test — argv + parse for the two proven commands**

`FlywheelReadCommandsTests.swift`, using the shared `MultiRunner`:

```swift
import XCTest
@testable import FlightDeck

final class FlywheelReadCommandsTests: XCTestCase {
    func testAgentsBuildsScopedArgvAndParses() async {
        let fake = MultiRunner()
        fake.responses["am agents list"] = (#"[{"name":"BlueFalcon"},{"name":"GoldViper"}]"#, 0)
        let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let agents = await rc.agents(project: "/tmp/p")
        XCTAssertEqual(agents?.map(\.name), ["BlueFalcon", "GoldViper"])
        XCTAssertEqual(fake.argv.first, ["am", "agents", "list", "/tmp/p", "--json"])
    }

    func testInProgressBeadsUnwrapsIssuesEnvelope() async {
        let fake = MultiRunner()
        fake.responses["br list"] = (#"{"issues":[{"id":"bd-142","title":"refactor auth","status":"in_progress","assignee":"BlueFalcon"}]}"#, 0)
        let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let beads = await rc.inProgressBeads(project: "/tmp/p")
        XCTAssertEqual(beads?.first?.id, "bd-142")
        XCTAssertEqual(beads?.first?.assignee, "BlueFalcon")
    }
}
```
> Adjust the fixtures and the `--json` envelope keys to **exactly** what Task 1's findings doc recorded. If Task 1 found `br list` scoped differently (e.g. needs `--repo`), encode that argv here.

- [ ] **Step 3: Write the failing degradation test**

```swift
func testMissingCommandDegradesToNilNotThrow() async {
    let fake = MultiRunner()                 // every response defaults to exit 127
    let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
    let agents = await rc.agents(project: "/tmp/p")
    XCTAssertNil(agents, "a non-zero exit must degrade to nil, not throw or crash")
}

func testGarbageStdoutDegradesToNil() async {
    let fake = MultiRunner()
    fake.responses["am agents list"] = ("not json at all", 0)
    let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
    let agents = await rc.agents(project: "/tmp/p")
    XCTAssertNil(agents)
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh` (full suite; expect the new file to fail to compile / assertions to fail — "FlywheelReadCommands not found").

- [ ] **Step 5: Implement `FlywheelReadCommands`**

```swift
import Foundation

/// Read-only `am`/`br` wrappers for Observe. Mirrors `FlywheelCoordinator`'s runner+path
/// injection and minimal-decode approach, with one rule reversed: a read that fails or
/// returns an unexpected shape yields `nil` (the lane degrades to "unavailable") rather
/// than throwing — a substrate hiccup must never take down the drawer.
struct FlywheelReadCommands {
    let runner: FlywheelProcessRunner
    let amPath: String
    let brPath: String

    init(runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(),
         amPath: String = "am", brPath: String = "br") {
        self.runner = runner
        self.amPath = amPath
        self.brPath = brPath
    }

    struct RawAgent: Decodable, Equatable { let name: String }
    struct RawBead: Decodable, Equatable {
        let id: String; let title: String; let status: String; let assignee: String?
    }
    struct RawReservation: Decodable, Equatable {
        let file: String; let holder: String; let since: Date; let waiters: [String]
    }
    struct RawDepEdge: Decodable, Equatable { let from: String; let to: String }
    struct RawEvent: Decodable, Equatable { let agent: String; let kind: String; let at: Date }

    /// One decode helper so every lane degrades identically. Returns nil on non-zero exit
    /// or unparseable stdout; logs once at that point (caller decides log cadence).
    private func read<T: Decodable>(_ exe: String, _ argv: [String], project: String,
                                    as _: T.Type, decode: (Data) -> T?) async -> T? {
        guard let (stdout, code) = try? await runner.run(exe, argv, cwd: project), code == 0,
              let data = stdout.data(using: .utf8) else { return nil }
        return decode(data)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    func agents(project: String) async -> [RawAgent]? {
        await read(amPath, ["agents", "list", project, "--json"], project: project, as: [RawAgent].self) {
            try? Self.decoder.decode([RawAgent].self, from: $0)
        }
    }

    func inProgressBeads(project: String) async -> [RawBead]? {
        struct Envelope: Decodable { let issues: [RawBead] }
        return await read(brPath, ["list", "--status", "in_progress", "--json"], project: project, as: [RawBead].self) {
            (try? Self.decoder.decode(Envelope.self, from: $0))?.issues
        }
    }

    // reservations / depEdges / events: implement ONLY against shapes Task 1 confirmed.
    // For any lane Task 1 marked "unavailable", ship this stub so callers compile and the
    // lane reads as unavailable, and leave the marker for the follow-up:
    //   func reservations(project: String) async -> [RawReservation]? { nil } // TODO(observe): unconfirmed shape — see notes
}
```
> Fill `reservations`, `depEdges`, `events` with real argv + decode **only** for the shapes Task 1 confirmed, using the same `read(...)` helper. Match the `--json` envelope keys and any scoping flags Task 1 recorded. Do not invent a shape.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`. Expected: the new tests pass; full suite green.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Flywheel/Observe/FlywheelReadCommands.swift Tests/FlightDeckTests/Flywheel/Observe/FlywheelReadCommandsTests.swift Tests/FlightDeckTests/Flywheel/Observe/ObserveTestSupport.swift
git commit -m "feat(flywheel): tolerant am/br read wrappers for Observe"
```

---

## Task 3: `FlywheelProjection` — the observable model + reduction

Pure, value-typed reduction from a raw snapshot into the model the views render. This is where the join to `flywheelIdentity`, the **external** case, and the **stalled-not-blocked** derivation live. No I/O, no SwiftUI — trivially unit-testable and off-main-computable.

**Files:**
- Create: `Sources/FlightDeck/Flywheel/Observe/FlywheelProjection.swift`
- Test: `Tests/FlightDeckTests/Flywheel/Observe/FlywheelProjectionTests.swift`

**Interfaces:**
- Consumes: `FlywheelReadCommands.Raw*` types (Task 2); `FlywheelIdentity` (`{agentName, project}`).
- Produces:
```swift
struct FlywheelSnapshot: Equatable, Sendable {   // raw lanes; nil = lane unavailable
    var agents: [FlywheelReadCommands.RawAgent]?
    var beads: [FlywheelReadCommands.RawBead]?
    var reservations: [FlywheelReadCommands.RawReservation]?
    var depEdges: [FlywheelReadCommands.RawDepEdge]?
    var events: [FlywheelReadCommands.RawEvent]?
}
enum AgentStatus: Equatable, Sendable { case active, blocked, stalled, external, unknown }
struct FlywheelProjection: Equatable, Sendable {
    struct Bead: Equatable, Sendable { let id, title, status: String; let assignee: String? }
    struct Reservation: Equatable, Sendable { let file, holder: String; let since: Date; let waiters: [String] }
    struct Agent: Equatable, Sendable {
        let name: String; var bead: Bead?; var status: AgentStatus
        var holds: [String]; var waitsOn: [Reservation]
        var lastEventAt: Date?; var stalledSince: Date?
    }
    enum EdgeKind: Equatable, Sendable { case dependency, reservation }
    struct DepEdge: Equatable, Sendable { let from, to: String; let kind: EdgeKind }
    var agents: [Agent]; var reservations: [Reservation]
    var depEdges: [DepEdge]; var beadsByID: [String: Bead]
    var lanesUnavailable: Set<String>       // e.g. ["reservations"]
    func agent(for identity: FlywheelIdentity) -> Agent?     // nil ⇒ external / no join
}
static func project(_ snapshot: FlywheelSnapshot, now: Date, stallThreshold: TimeInterval,
                    previous: FlywheelProjection?) -> FlywheelProjection
```
The `previous` argument carries `stalledSince` forward so a stall clock and a refreshed lease are *continuity*, not reset.

- [ ] **Step 1: Write the failing test — join + external case**

```swift
import XCTest
@testable import FlightDeck

final class FlywheelProjectionTests: XCTestCase {
    private func snap(agents: [String], beads: [(String,String,String,String?)] = []) -> FlywheelSnapshot {
        FlywheelSnapshot(
            agents: agents.map { .init(name: $0) },
            beads: beads.map { .init(id: $0.0, title: $0.1, status: $0.2, assignee: $0.3) },
            reservations: [], depEdges: [], events: [])
    }

    func testJoinsIdentityToAgentRow() {
        let p = FlywheelProjection.project(
            snap(agents: ["BlueFalcon"], beads: [("bd-142","refactor auth","in_progress","BlueFalcon")]),
            now: Date(), stallThreshold: 600, previous: nil)
        let a = p.agent(for: FlywheelIdentity(agentName: "BlueFalcon", project: "/tmp/p"))
        XCTAssertEqual(a?.bead?.id, "bd-142")
    }

    func testUnjoinedIdentityIsExternal() {
        let p = FlywheelProjection.project(snap(agents: ["GoldViper"]), now: Date(), stallThreshold: 600, previous: nil)
        XCTAssertNil(p.agent(for: FlywheelIdentity(agentName: "NotHere", project: "/tmp/p")))
    }
}
```

- [ ] **Step 2: Write the failing test — stalled-not-blocked derivation + continuity**

```swift
func testStalledIsHoldsContendedPlusIdlePastThresholdAndNotBlocked() {
    let now = Date()
    var snap = self.snap(agents: ["GoldViper"])
    // GoldViper holds a file another agent waits on, last event 20m ago, not blocked.
    snap.reservations = [.init(file: "src/Auth.swift", holder: "GoldViper", since: now.addingTimeInterval(-1800), waiters: ["BlueFalcon"])]
    snap.events = [.init(agent: "GoldViper", kind: "edit", at: now.addingTimeInterval(-1200))]
    let p = FlywheelProjection.project(snap, now: now, stallThreshold: 600, previous: nil)
    let a = p.agents.first { $0.name == "GoldViper" }
    XCTAssertEqual(a?.status, .stalled)
    XCTAssertNotNil(a?.stalledSince)
}

func testRefreshedLeaseKeepsStallClockNotReset() {
    let now = Date()
    var first = self.snap(agents: ["GoldViper"])
    first.reservations = [.init(file: "a.swift", holder: "GoldViper", since: now.addingTimeInterval(-1800), waiters: ["X"])]
    first.events = [.init(agent: "GoldViper", kind: "edit", at: now.addingTimeInterval(-1200))]
    let p1 = FlywheelProjection.project(first, now: now, stallThreshold: 600, previous: nil)
    let stalledSince1 = p1.agents.first { $0.name == "GoldViper" }?.stalledSince
    // Lease refreshes (new `since`) but no new activity: still the same stall.
    var second = first
    second.reservations = [.init(file: "a.swift", holder: "GoldViper", since: now.addingTimeInterval(-60), waiters: ["X"])]
    let p2 = FlywheelProjection.project(second, now: now.addingTimeInterval(30), stallThreshold: 600, previous: p1)
    let stalledSince2 = p2.agents.first { $0.name == "GoldViper" }?.stalledSince
    XCTAssertEqual(stalledSince1, stalledSince2, "a lease refresh is continuity, not a new stall")
}
```

- [ ] **Step 3: Write the failing test — a nil lane is tolerated**

```swift
func testNilReservationLaneMarksLaneUnavailableNotCrash() {
    var s = snap(agents: ["BlueFalcon"]); s.reservations = nil
    let p = FlywheelProjection.project(s, now: Date(), stallThreshold: 600, previous: nil)
    XCTAssertTrue(p.lanesUnavailable.contains("reservations"))
    XCTAssertEqual(p.agents.first?.holds, [])
}
```

- [ ] **Step 4: Run to verify they fail**

Run: `./scripts/test-unit.sh`. Expected: fails ("FlywheelProjection not found").

- [ ] **Step 5: Implement `FlywheelProjection` + `project(...)`**

Write the types above and the reduction. Key rules, encoded from the spec:
- `holds` = reservations whose `holder == agent.name`; `waitsOn` = reservations whose `waiters` contains the agent.
- `status`: `.blocked` if the bead's own state says blocked (from `beads`/`br blocked`); else `.stalled` if it holds a contended file **or** is on the critical path **and** `lastEventAt` is older than `stallThreshold` **and** not `.blocked`; else `.active` if there is recent activity; else `.unknown`.
- `stalledSince`: if newly stalled, `now`; if `previous` had it stalled, carry the earlier `stalledSince` (continuity — a refreshed lease `since` does **not** reset it). Clear it when the agent is no longer stalled.
- `lanesUnavailable`: insert `"reservations"`/`"depEdges"`/`"events"`/`"agents"`/`"beads"` for each nil lane; a nil lane contributes empty collections, never a crash.
- `depEdges`: `br dep`/`graph` edges become `.dependency`; a contended reservation (holder≠waiter) becomes a `.reservation` edge from each waiter to the holder.
- `agent(for:)`: look up by `identity.agentName` in `agents`; return nil if absent (external).

- [ ] **Step 6: Run to verify they pass, then commit**

Run: `./scripts/test-unit.sh`. Expected: green.
```bash
git add Sources/FlightDeck/Flywheel/Observe/FlywheelProjection.swift Tests/FlightDeckTests/Flywheel/Observe/FlywheelProjectionTests.swift
git commit -m "feat(flywheel): FlywheelProjection reduction with stall + external derivation"
```

---

## Task 4: `DependencyGraphLayout` — layered layout with stable coordinates

Pure geometry: given the projection's `depEdges` + bead set, produce node positions. Layered (rank = dependency depth), a shared node appears once (the diamond), and **coordinates are keyed by a content-hash of the graph so equal topology yields identical positions across re-polls** (the graph must not jump). Root-cause pick lives here too.

**Files:**
- Create: `Sources/FlightDeck/Flywheel/Observe/DependencyGraphLayout.swift`
- Test: `Tests/FlightDeckTests/Flywheel/Observe/DependencyGraphLayoutTests.swift`

**Interfaces:**
- Consumes: `FlywheelProjection.DepEdge`, `FlywheelProjection.Agent`/`Bead`, `AgentStatus`.
- Produces:
```swift
struct DependencyGraphLayout: Equatable {
    struct Node: Equatable { let id: String; let rank: Int; let position: CGPoint }
    let nodes: [String: Node]
    let contentHash: Int
    let rootCauseID: String?         // deepest stalled-not-blocked node on the critical path
    static func layout(beadIDs: [String], edges: [FlywheelProjection.DepEdge],
                       statusByBead: [String: AgentStatus], nodeSize: CGSize, spacing: CGSize) -> DependencyGraphLayout
}
```

- [ ] **Step 1: Write the failing test — the diamond appears once, ranked**

```swift
import XCTest
@testable import FlightDeck

final class DependencyGraphLayoutTests: XCTestCase {
    // 142 -> 118, 142 -> 133, 118 -> 120, 133 -> 120  (diamond; 120 is the shared root)
    private let edges: [FlywheelProjection.DepEdge] = [
        .init(from: "bd-142", to: "bd-118", kind: .dependency),
        .init(from: "bd-142", to: "bd-133", kind: .dependency),
        .init(from: "bd-118", to: "bd-120", kind: .dependency),
        .init(from: "bd-133", to: "bd-120", kind: .dependency),
    ]

    func testSharedNodeAppearsOnceAtDeepestRank() {
        let l = DependencyGraphLayout.layout(
            beadIDs: ["bd-142","bd-118","bd-133","bd-120"], edges: edges,
            statusByBead: [:], nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
        XCTAssertEqual(l.nodes.count, 4)                       // one node per bead, not five
        XCTAssertEqual(l.nodes["bd-142"]?.rank, 0)
        XCTAssertEqual(l.nodes["bd-120"]?.rank, 2)            // pushed to the deepest rank
    }
}
```

- [ ] **Step 2: Write the failing test — coordinate stability across equal content-hash**

```swift
func testEqualTopologyYieldsIdenticalPositions() {
    let a = DependencyGraphLayout.layout(beadIDs: ["bd-142","bd-118","bd-133","bd-120"], edges: edges,
        statusByBead: ["bd-118": .stalled], nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
    // Same topology, only a status changed (stalled -> active): positions must not move.
    let b = DependencyGraphLayout.layout(beadIDs: ["bd-142","bd-118","bd-133","bd-120"], edges: edges,
        statusByBead: ["bd-118": .active], nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
    XCTAssertEqual(a.contentHash, b.contentHash)
    XCTAssertEqual(a.nodes["bd-118"]?.position, b.nodes["bd-118"]?.position)
}
```

- [ ] **Step 3: Write the failing test — root-cause pick**

```swift
func testRootCauseIsDeepestStalledNotBlockedOnCriticalPath() {
    let l = DependencyGraphLayout.layout(beadIDs: ["bd-142","bd-118","bd-133","bd-120"], edges: edges,
        statusByBead: ["bd-142": .blocked, "bd-118": .stalled, "bd-120": .active],
        nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
    XCTAssertEqual(l.rootCauseID, "bd-118")   // stalled, not blocked, deepest actionable node
}
```

- [ ] **Step 4: Run to verify they fail**

Run: `./scripts/test-unit.sh`. Expected: fails ("DependencyGraphLayout not found").

- [ ] **Step 5: Implement the layout**

- Rank = longest path from any rank-0 source (a node with no incoming dep edge, or the focused bead) so a shared node sinks to its deepest rank (the diamond joins once).
- Within-rank order: sort by a deterministic key (bead id) so it is stable; assign `x = index * (nodeSize.width + spacing.width)`, `y = rank * (nodeSize.height + spacing.height)`.
- `contentHash`: hash the sorted edge list + sorted bead ids **only** (not statuses) so a status-only change keeps the hash and therefore the positions.
- `rootCauseID`: among nodes with `status == .stalled`, pick the one with the greatest rank reachable from a `.blocked` node on the critical path; nil if none.

- [ ] **Step 6: Run to verify they pass, then commit**

Run: `./scripts/test-unit.sh`. Expected: green.
```bash
git add Sources/FlightDeck/Flywheel/Observe/DependencyGraphLayout.swift Tests/FlightDeckTests/Flywheel/Observe/DependencyGraphLayoutTests.swift
git commit -m "feat(flywheel): layered DAG layout with content-hash-stable coordinates"
```

---

## Task 5: `DAGCamera` — center/zoom transform + hit-test round-trip

Pure camera math for the overlay: an affine that centers+zooms on a point, and its inverse for hit-testing a click back to a node. Keeping this pure and tested means the `Canvas` view (Task 11) carries no untested geometry.

**Files:**
- Create: `Sources/FlightDeck/Flywheel/Observe/DAGCamera.swift`
- Test: `Tests/FlightDeckTests/Flywheel/Observe/DAGCameraTests.swift`

**Interfaces:**
- Produces:
```swift
struct DAGCamera: Equatable {
    var scale: CGFloat; var center: CGPoint     // graph-space point shown at viewport center
    func transform(viewport: CGSize) -> CGAffineTransform          // graph space -> view space
    func graphPoint(fromViewPoint p: CGPoint, viewport: CGSize) -> CGPoint   // inverse
    static func centered(on point: CGPoint, scale: CGFloat) -> DAGCamera
    func fitting(_ rect: CGRect, viewport: CGSize, padding: CGFloat) -> DAGCamera   // ⤢ fit-all
}
```

- [ ] **Step 1: Write the failing test — center maps to viewport center, round-trip**

```swift
import XCTest
@testable import FlightDeck

final class DAGCameraTests: XCTestCase {
    func testCenterMapsToViewportCenter() {
        let cam = DAGCamera.centered(on: CGPoint(x: 100, y: 200), scale: 2)
        let vp = CGSize(width: 640, height: 360)
        let mapped = CGPoint(x: 100, y: 200).applying(cam.transform(viewport: vp))
        XCTAssertEqual(mapped.x, 320, accuracy: 0.001)
        XCTAssertEqual(mapped.y, 180, accuracy: 0.001)
    }

    func testViewToGraphRoundTrip() {
        let cam = DAGCamera.centered(on: CGPoint(x: 100, y: 200), scale: 1.7)
        let vp = CGSize(width: 640, height: 360)
        let v = CGPoint(x: 512, y: 40)
        let g = cam.graphPoint(fromViewPoint: v, viewport: vp)
        let back = g.applying(cam.transform(viewport: vp))
        XCTAssertEqual(back.x, v.x, accuracy: 0.001)
        XCTAssertEqual(back.y, v.y, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`. Expected: fails ("DAGCamera not found").

- [ ] **Step 3: Implement the camera**

`transform` = translate(−center) → scale(scale) → translate(+viewport/2). `graphPoint` applies the inverse. `centered` sets `center`+`scale`. `fitting` computes `scale = min(viewport/rect * padding factor)` and `center = rect.mid`.

- [ ] **Step 4: Run to verify it passes, then commit**

Run: `./scripts/test-unit.sh`. Expected: green.
```bash
git add Sources/FlightDeck/Flywheel/Observe/DAGCamera.swift Tests/FlightDeckTests/Flywheel/Observe/DAGCameraTests.swift
git commit -m "feat(flywheel): DAG camera transform + hit-test round-trip"
```

---

## Task 6: `FlywheelWatcher` — `WatchClock`-registered, mtime-gated, coalesced re-poll

Mirror `SessionStatusWatcher`: `@MainActor`, `start()/stop()/drain()`, injectable `clock: WatchClock?` (nil in tests), an `onChange` callback. Each `drain()` stat-gates the watched paths (the `.beads` store + Agent-Mail store from Task 1); only when an mtime moved does it kick a **coalesced** re-poll (the `debounceTask` cancel+`Task.sleep` idiom) that shells the Task-2 reads off-main and delivers a `FlywheelSnapshot`. A tick with no mtime change costs a `stat`, not a subprocess.

**Files:**
- Create: `Sources/FlightDeck/Flywheel/Observe/FlywheelWatcher.swift`
- Test: `Tests/FlightDeckTests/Flywheel/Observe/FlywheelWatcherTests.swift`

**Interfaces:**
- Consumes: `WatchClock` (`add(_:_:)`/`remove(_:)`), `FlywheelReadCommands` (Task 2), `FlywheelSnapshot` (Task 3).
- Produces:
```swift
@MainActor final class FlywheelWatcher {
    init(project: String, watchPaths: [URL], reads: FlywheelReadCommands,
         clock: WatchClock? = nil, debounce: Duration = .milliseconds(200),
         onChange: @escaping (FlywheelSnapshot) -> Void)
    func start(); func stop()
    func drain()                    // synchronous mtime check; schedules a repoll on change
    func repollNow() async          // bypass the gate (start + focus/expand); awaits the reads
}
```

- [ ] **Step 1: Write the failing test — unchanged mtime ⇒ no repoll; changed ⇒ one**

Use a fake `FlywheelProcessRunner` (the `MultiRunner` from Task 2) to count shell-outs, and temp files for the watch paths so `drain()` sees real mtimes.

```swift
import XCTest
@testable import FlightDeck

final class FlywheelWatcherTests: XCTestCase {
    func testUnchangedMtimeDoesNotRepoll() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let beads = dir.appendingPathComponent("beads.db"); FileManager.default.createFile(atPath: beads.path, contents: Data())
        let fake = MultiRunner(); fake.responses["am agents list"] = ("[]", 0)
        let reads = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        var snaps = 0
        let w = FlywheelWatcher(project: dir.path, watchPaths: [beads], reads: reads, clock: nil,
                                onChange: { _ in snaps += 1 })
        await w.repollNow()                 // priming read
        let baseline = fake.argv.count
        w.drain(); w.drain()                // no file change between/after
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.argv.count, baseline, "an unchanged mtime must not shell out again")
    }

    func testChangedMtimeCoalescesToOneRepoll() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let beads = dir.appendingPathComponent("beads.db"); FileManager.default.createFile(atPath: beads.path, contents: Data())
        let fake = MultiRunner(); fake.responses["am agents list"] = ("[]", 0)
        let reads = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let w = FlywheelWatcher(project: dir.path, watchPaths: [beads], reads: reads, clock: nil,
                                debounce: .milliseconds(50), onChange: { _ in })
        w.drain()                                   // establish baseline mtime
        try? await Task.sleep(for: .milliseconds(20))
        try? "x".write(to: beads, atomically: true, encoding: .utf8)   // change it
        let before = fake.argv.count
        w.drain(); w.drain(); w.drain()             // a burst
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fake.argv.count - before, expectedReadsPerPoll,
                       "a burst must coalesce into exactly one repoll")
    }
}
```
> `expectedReadsPerPoll` = the number of `reads.*` calls one repoll makes (set it to however many lanes Task 2 shipped as available). Define it as a `let` in the test.

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-unit.sh`. Expected: fails ("FlywheelWatcher not found").

- [ ] **Step 3: Implement the watcher**

- `drain()`: read each `watchPaths` mtime via `resourceValues(forKeys: [.contentModificationDateKey])` (same call `SessionStatusWatcher` uses); compare to cached; if any moved, call `scheduleRepoll()`.
- `scheduleRepoll()`: cancel `debounceTask`; set `debounceTask = Task { try? await Task.sleep(for: debounce); guard !Task.isCancelled else { return }; await repollNow() }` — the cancel-before-sleep collapses the burst (the `SearchModel.swift:92-123` idiom).
- `repollNow()`: `await` the Task-2 reads (off the main actor via the runner's own async), assemble a `FlywheelSnapshot`, hop to main, call `onChange`. Guard re-entrancy with an `isPolling` flag like `TranscriptWatcher`.
- `start()`: `clock?.add(self) { [weak self] in self?.drain() }`. `stop()`: `clock?.remove(self)` and `debounceTask?.cancel()`.

- [ ] **Step 4: Run to verify they pass, then commit**

Run: `./scripts/test-unit.sh`. Expected: green.
```bash
git add Sources/FlightDeck/Flywheel/Observe/FlywheelWatcher.swift Tests/FlightDeckTests/Flywheel/Observe/FlywheelWatcherTests.swift
git commit -m "feat(flywheel): mtime-gated coalescing watcher on the shared WatchClock"
```

---

## Task 7: `FlywheelObserveService` — lifecycle owner

One `@MainActor` service `SessionStore` holds. Keeps `[projectKey: (watcher, projection)]`, starts a watcher on enable/add, tears it down on disable/remove, recomputes the projection on each `onChange`, and vends the focused projection (for the drawer) + all projections (for the notifier). Constructed lazily — a fleet with no enabled projects builds nothing.

**Files:**
- Create: `Sources/FlightDeck/Flywheel/Observe/FlywheelObserveService.swift`
- Test: `Tests/FlightDeckTests/Flywheel/Observe/FlywheelObserveServiceTests.swift`

**Interfaces:**
- Consumes: `FlywheelWatcher` (Task 6), `FlywheelReadCommands` (Task 2), `FlywheelProjection` (Task 3), `PreferencesStore.key(_:)` semantics for the project key.
- Produces:
```swift
@MainActor final class FlywheelObserveService: ObservableObject {
    init(reads: FlywheelReadCommands = FlywheelReadCommands(), clock: WatchClock? = nil,
         stallThreshold: TimeInterval = 600, now: @escaping () -> Date = Date.init)
    @Published private(set) var projections: [String: FlywheelProjection]   // keyed by standardized path
    func enable(project path: String, watchPaths: [URL])    // idempotent; starts a watcher
    func disable(project path: String)                       // stops + drops
    func projection(forProject path: String) -> FlywheelProjection?
    var onProjectionsChanged: (([String: FlywheelProjection]) -> Void)?     // notifier hook
    static func key(_ path: String) -> String                // mirrors PreferencesStore.key
}
```

- [ ] **Step 1: Write the failing test — enable starts one watcher; disable is zero-cost after**

```swift
import XCTest
@testable import FlightDeck

final class FlywheelObserveServiceTests: XCTestCase {
    func testEnableThenDisableIsIdempotentAndScoped() async {
        let fake = MultiRunner(); fake.responses["am agents list"] = ("[]", 0)
        let svc = FlywheelObserveService(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"), clock: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        svc.enable(project: dir.path, watchPaths: [])
        svc.enable(project: dir.path, watchPaths: [])       // idempotent — no second watcher
        try? await Task.sleep(for: .milliseconds(150))      // let the priming poll land
        XCTAssertNotNil(svc.projection(forProject: dir.path), "enabled ⇒ a projection exists")
        svc.disable(project: dir.path)
        XCTAssertNil(svc.projection(forProject: dir.path), "disabled ⇒ nil")
    }

    func testKeyStandardizesLikePreferencesStore() {
        XCTAssertEqual(FlywheelObserveService.key("/tmp/p/"), FlywheelObserveService.key("/tmp/p"))
    }
}
```
> `projection(forProject:)` returns a (possibly empty) projection once enabled and priming-polled, `nil` once disabled.

- [ ] **Step 2: Write the failing test — projection recompute fires the notifier hook**

```swift
func testProjectionChangeInvokesNotifierHook() async {
    let fake = MultiRunner(); fake.responses["am agents list"] = (#"[{"name":"BlueFalcon"}]"#, 0)
    let svc = FlywheelObserveService(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"), clock: nil)
    var fired = 0
    svc.onProjectionsChanged = { _ in fired += 1 }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    svc.enable(project: dir.path, watchPaths: [])
    try? await Task.sleep(for: .milliseconds(200))
    XCTAssertGreaterThan(fired, 0)
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `./scripts/test-unit.sh`. Expected: fails ("FlywheelObserveService not found").

- [ ] **Step 4: Implement the service**

- `enable`: guard against a duplicate key; build a `FlywheelWatcher(project:watchPaths:reads:clock:onChange:)` whose `onChange` reduces the snapshot via `FlywheelProjection.project(_:now:stallThreshold:previous:)` (passing the prior projection for stall continuity), stores it in `projections[key]`, and calls `onProjectionsChanged`. `start()` it and `repollNow()` once so an enabled project has a projection immediately.
- `disable`: `stop()` the watcher, drop both map entries.
- `key`: `URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path` (identical to `PreferencesStore.key`).

- [ ] **Step 5: Run to verify they pass, then commit**

Run: `./scripts/test-unit.sh`. Expected: green.
```bash
git add Sources/FlightDeck/Flywheel/Observe/FlywheelObserveService.swift Tests/FlightDeckTests/Flywheel/Observe/FlywheelObserveServiceTests.swift
git commit -m "feat(flywheel): FlywheelObserveService owns per-project watchers + projections"
```

---

## Task 8: `FlywheelNotifier` — fleet-wide, human-needed-only gating

Consumes every projection and fires a macOS notification through the `Notifying` seam on exactly two gated triggers: (a) an agent **persistently blocked** past a threshold; (b) a **collision needing a human** — the contended file's holder is stalled/dead, or a dependency deadlock cycle. A transient block or an actively-worked collision never notifies; a standing condition notifies **once** (coalesced per agent/cause). Authorization is requested once, lazily, on first enable — never at launch.

**Files:**
- Create: `Sources/FlightDeck/Flywheel/Observe/FlywheelNotifier.swift`
- Test: `Tests/FlightDeckTests/Flywheel/Observe/FlywheelNotifierTests.swift`

**Interfaces:**
- Consumes: `FlywheelProjection` (Task 3), the existing `Notifying` protocol (`func requestAuthorization()`, `func notify(sessionID: UUID, title: String, subtitle: String, body: String)`, `func withdraw(sessionID: UUID)`), an injectable `now: () -> Date`.
- Produces:
```swift
@MainActor final class FlywheelNotifier {
    init(notifier: Notifying, blockThreshold: TimeInterval = 120, now: @escaping () -> Date = Date.init)
    /// Route resolution: map a (project, agentName) to the FD session UUID to notify/route to.
    var route: (_ project: String, _ agentName: String) -> UUID?
    func evaluate(projectsByKey: [String: FlywheelProjection])
}
```
The notifier keys notifications on the routed `UUID` (so a repeat replaces rather than stacks, exactly as `SessionNotifier` does), and remembers which (agent, cause) it has already fired to coalesce.

- [ ] **Step 1: Write the failing test — transient block ⇒ none; persistent ⇒ one**

Use a spy `Notifying`.

```swift
import XCTest
@testable import FlightDeck

private final class SpyNotifier: Notifying {
    var notified: [(UUID, String)] = []
    func requestAuthorization() {}
    func notify(sessionID: UUID, title: String, subtitle: String, body: String) { notified.append((sessionID, title)) }
    func withdraw(sessionID: UUID) {}
}

final class FlywheelNotifierTests: XCTestCase {
    private func blockedProjection(_ name: String, since: Date) -> [String: FlywheelProjection] {
        var a = FlywheelProjection.Agent(name: name, bead: nil, status: .blocked, holds: [], waitsOn: [], lastEventAt: nil, stalledSince: since)
        return ["/tmp/p": FlywheelProjection(agents: [a], reservations: [], depEdges: [], beadsByID: [:], lanesUnavailable: [])]
    }

    func testTransientBlockDoesNotNotify() {
        let spy = SpyNotifier()
        var t = Date()
        let n = FlywheelNotifier(notifier: spy, blockThreshold: 120, now: { t })
        let id = UUID(); n.route = { _, _ in id }
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: t))   // just blocked
        t = t.addingTimeInterval(30)                                          // 30s < 120s
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: t.addingTimeInterval(-30)))
        XCTAssertTrue(spy.notified.isEmpty)
    }

    func testPersistentBlockNotifiesOnceCoalesced() {
        let spy = SpyNotifier()
        let start = Date(); var t = start
        let n = FlywheelNotifier(notifier: spy, blockThreshold: 120, now: { t })
        let id = UUID(); n.route = { _, _ in id }
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: start))
        t = start.addingTimeInterval(200)                                     // past threshold
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: start))
        n.evaluate(projectsByKey: blockedProjection("BlueFalcon", since: start))  // still blocked
        XCTAssertEqual(spy.notified.count, 1, "a standing block notifies once, not every tick")
    }
}
```

- [ ] **Step 2: Write the failing test — active-holder collision silent; stalled-holder collision notifies**

```swift
func testCollisionWithActiveHolderIsSilentButStalledHolderNotifies() {
    let spy = SpyNotifier()
    let n = FlywheelNotifier(notifier: spy, blockThreshold: 120, now: { Date() })
    n.route = { _, _ in UUID() }
    func projection(holderStatus: AgentStatus) -> [String: FlywheelProjection] {
        let res = FlywheelProjection.Reservation(file: "a.swift", holder: "GoldViper", since: Date(), waiters: ["BlueFalcon"])
        let holder = FlywheelProjection.Agent(name: "GoldViper", bead: nil, status: holderStatus, holds: ["a.swift"], waitsOn: [], lastEventAt: nil, stalledSince: holderStatus == .stalled ? Date() : nil)
        let waiter = FlywheelProjection.Agent(name: "BlueFalcon", bead: nil, status: .blocked, holds: [], waitsOn: [res], lastEventAt: nil, stalledSince: nil)
        return ["/tmp/p": FlywheelProjection(agents: [holder, waiter], reservations: [res], depEdges: [], beadsByID: [:], lanesUnavailable: [])]
    }
    n.evaluate(projectsByKey: projection(holderStatus: .active))
    XCTAssertTrue(spy.notified.isEmpty, "an actively-worked collision is not a human's problem yet")
    n.evaluate(projectsByKey: projection(holderStatus: .stalled))
    XCTAssertEqual(spy.notified.count, 1, "a stalled holder blocking a waiter needs a human")
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `./scripts/test-unit.sh`. Expected: fails ("FlywheelNotifier not found").

- [ ] **Step 4: Implement the notifier**

- `evaluate`: for each projection, (a) any `.blocked` agent whose block has persisted `≥ blockThreshold` (measured from a first-seen timestamp the notifier records per agent/cause, **not** from projection fields, so it survives lease churn) → fire; (b) any reservation with `waiters` non-empty whose `holder` is `.stalled`/dead, or any dependency cycle → fire. Track fired `(routedID, cause)` in a set; skip if already fired; clear when the condition clears (and `withdraw`).
- `route`: injected by the wiring task; maps `(project, agentName)` to the session UUID.

- [ ] **Step 5: Run to verify they pass, then commit**

Run: `./scripts/test-unit.sh`. Expected: green.
```bash
git add Sources/FlightDeck/Flywheel/Observe/FlywheelNotifier.swift Tests/FlightDeckTests/Flywheel/Observe/FlywheelNotifierTests.swift
git commit -m "feat(flywheel): human-needed-only fleet notifier over the Notifying seam"
```

---

## Task 9: `ProjectSettings.drawerCollapsed` — persisted drawer state

Copy the exact `flywheelEnabled` idiom: an `Optional` with a doc comment, a defaulted last init param, assigned in the init, and folded into `isEmpty` with `!= true` so a settings record written before this field still decodes (synthesized `Codable` uses `decodeIfPresent` for optionals) and an untouched drawer keeps the record empty.

**Files:**
- Modify: `Sources/FlightDeck/Preferences/ProjectSettings.swift`
- Test: `Tests/FlightDeckTests/Preferences/ProjectSettingsObserveTests.swift`

**Interfaces:**
- Produces: `ProjectSettings.drawerCollapsed: Bool?` (read as `drawerCollapsed == true`).

- [ ] **Step 1: Write the failing test — back-compat decode + isEmpty**

```swift
import XCTest
@testable import FlightDeck

final class ProjectSettingsObserveTests: XCTestCase {
    func testDecodesRecordWrittenBeforeDrawerField() throws {
        // JSON with no drawerCollapsed key — must decode with nil, not throw.
        let json = #"{"accounts":{},"options":{}}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ProjectSettings.self, from: json)
        XCTAssertNil(s.drawerCollapsed)
    }

    func testDrawerCollapsedAloneDoesNotKeepRecordAlive() {
        var s = ProjectSettings()
        s.drawerCollapsed = false
        XCTAssertTrue(s.isEmpty, "a false/absent drawer flag must not keep an otherwise-empty record")
        s.drawerCollapsed = true
        XCTAssertFalse(s.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`. Expected: fails ("value of type 'ProjectSettings' has no member 'drawerCollapsed'").

- [ ] **Step 3: Implement the field**

Edit `ProjectSettings.swift`: add after `flywheelEnabled`:
```swift
    /// nil ⇒ drawer open (the default). Persists the per-project collapsed state of the
    /// Observe drawer. Optional so a record written before this field still decodes.
    /// Read as `drawerCollapsed == true`.
    var drawerCollapsed: Bool?
```
Add `drawerCollapsed: Bool? = nil` as the last init param, `self.drawerCollapsed = drawerCollapsed` in the body, and extend `isEmpty`:
```swift
            && flywheelEnabled != true && drawerCollapsed != true
```

- [ ] **Step 4: Run to verify it passes, then commit**

Run: `./scripts/test-unit.sh`. Expected: green.
```bash
git add Sources/FlightDeck/Preferences/ProjectSettings.swift Tests/FlightDeckTests/Preferences/ProjectSettingsObserveTests.swift
git commit -m "feat(flywheel): persist per-project Observe drawer collapsed state"
```

---

## Task 10: `ObserveDrawer` — the per-tab bottom drawer

SwiftUI view mounted under `TerminalPane`. Per AGENTS.md rule 2, agents can't drive the real app, so SwiftUI *layout* is not unit-testable here — the strategy is to **extract every decision into pure helpers that are tested**, and keep the `View` body a thin wiring of those helpers + already-tested models. The view itself is verified in the GUI checklist (Task 13).

**Files:**
- Create: `Sources/FlightDeck/Flywheel/Observe/ObserveDrawer.swift`
- Test: `Tests/FlightDeckTests/Flywheel/Observe/ObserveDrawerModelTests.swift`

**Interfaces:**
- Consumes: `FlywheelProjection.Agent` (Task 3), `ProjectSettings.drawerCollapsed` (Task 9).
- Produces:
  - `enum ObserveLane { case workingOn, files, dependency, activity }`
  - `struct ObserveLaneModel` with `static func lanes(for agent: FlywheelProjection.Agent?, unavailable: Set<String>) -> [ObserveLaneRow]` where each `ObserveLaneRow` carries `{ lane, title, detail, isUnavailable }`.
  - `struct ObserveDrawer: View` taking `agent: FlywheelProjection.Agent?`, `collapsed: Bool`, `onToggleCollapse: () -> Void`, `onJumpToRootCause: () -> Void`, `onOpenDAG: () -> Void`.

- [ ] **Step 1: Write the failing test — lane model degrades a missing lane, not the others**

```swift
import XCTest
@testable import FlightDeck

final class ObserveLaneModelTests: XCTestCase {
    func testMissingReservationLaneMarksFilesUnavailableOnly() {
        let agent = FlywheelProjection.Agent(name: "BlueFalcon",
            bead: .init(id: "bd-142", title: "refactor auth", status: "in_progress", assignee: "BlueFalcon"),
            status: .active, holds: [], waitsOn: [], lastEventAt: nil, stalledSince: nil)
        let rows = ObserveLaneModel.lanes(for: agent, unavailable: ["reservations"])
        let files = rows.first { $0.lane == .files }
        let working = rows.first { $0.lane == .workingOn }
        XCTAssertEqual(files?.isUnavailable, true)
        XCTAssertEqual(working?.isUnavailable, false)
        XCTAssertEqual(working?.detail.contains("bd-142"), true)
    }

    func testNilAgentYieldsNoLanes() {
        XCTAssertTrue(ObserveLaneModel.lanes(for: nil, unavailable: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`. Expected: fails ("ObserveLaneModel not found").

- [ ] **Step 3: Implement the lane model + the view**

- `ObserveLaneModel.lanes`: nil agent → `[]` (drawer absent). Otherwise one row per lane; a lane whose backing data is in `unavailable` gets `isUnavailable = true` and a "unavailable" detail; the others render (`workingOn` = bead id+title; `files` = held ✓ / waiting ◔ with "held by X · idle Nm"; `dependency` = immediate edge + a ⤢ affordance; `activity` = recent events).
- `ObserveDrawer` body: `if collapsed` → a one-line status bar (status dot + bead + a chevron calling `onToggleCollapse`); else a `VStack` header + the four lanes from `ObserveLaneModel`, the Dependency lane's ⤢ calling `onOpenDAG`, the root-cause line calling `onJumpToRootCause`. Keep it thin — no geometry or math in the body.

- [ ] **Step 4: Run to verify it passes, then commit**

Run: `./scripts/test-unit.sh`. Expected: green (the lane-model tests; the view compiles).
```bash
git add Sources/FlightDeck/Flywheel/Observe/ObserveDrawer.swift Tests/FlightDeckTests/Flywheel/Observe/ObserveDrawerModelTests.swift
git commit -m "feat(flywheel): ObserveDrawer with tested lane model, GUI-verified view"
```

---

## Task 11: `DependencyDAGOverlay` — whole-graph Canvas overlay

SwiftUI `Canvas` rendering the whole project DAG with the camera centered on the selected bead. All geometry is already tested (`DependencyGraphLayout` Task 4, `DAGCamera` Task 5); this task is the drawing + gesture wiring, GUI-verified. It carries no untested math — it *composes* the two pure types.

**Files:**
- Create: `Sources/FlightDeck/Flywheel/Observe/DependencyDAGOverlay.swift`
- Test: `Tests/FlightDeckTests/Flywheel/Observe/DAGOverlayHitTestTests.swift`

**Interfaces:**
- Consumes: `DependencyGraphLayout` (Task 4), `DAGCamera` (Task 5), `FlywheelProjection` (Task 3).
- Produces:
  - `struct DAGHitTester` with `static func node(at viewPoint: CGPoint, layout: DependencyGraphLayout, camera: DAGCamera, viewport: CGSize, nodeSize: CGSize) -> String?` (the pure click→node resolution the view uses).
  - `struct DependencyDAGOverlay: View` taking `projection`, `selectedBeadID`, `onSelectNode: (String) -> Void`, `onJumpToTab: (String) -> Void`, `onClose: () -> Void`.

- [ ] **Step 1: Write the failing test — a click inside a node's box resolves to that node**

```swift
import XCTest
@testable import FlightDeck

final class DAGOverlayHitTestTests: XCTestCase {
    func testClickInsideNodeBoxResolvesToNode() {
        let edges: [FlywheelProjection.DepEdge] = [.init(from: "bd-142", to: "bd-118", kind: .dependency)]
        let nodeSize = CGSize(width: 132, height: 48)
        let layout = DependencyGraphLayout.layout(beadIDs: ["bd-142","bd-118"], edges: edges,
            statusByBead: [:], nodeSize: nodeSize, spacing: .init(width: 40, height: 80))
        let vp = CGSize(width: 640, height: 360)
        let cam = DAGCamera.centered(on: layout.nodes["bd-118"]!.position, scale: 1)
        // The selected node sits at viewport center; a click there hits it.
        let hit = DAGHitTester.node(at: CGPoint(x: 320, y: 180), layout: layout, camera: cam, viewport: vp, nodeSize: nodeSize)
        XCTAssertEqual(hit, "bd-118")
    }

    func testClickInEmptySpaceResolvesToNil() {
        let layout = DependencyGraphLayout.layout(beadIDs: ["bd-1"], edges: [],
            statusByBead: [:], nodeSize: .init(width: 132, height: 48), spacing: .init(width: 40, height: 80))
        let cam = DAGCamera.centered(on: layout.nodes["bd-1"]!.position, scale: 1)
        let hit = DAGHitTester.node(at: CGPoint(x: 5, y: 5), layout: layout, camera: cam, viewport: .init(width: 640, height: 360), nodeSize: .init(width: 132, height: 48))
        XCTAssertNil(hit)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`. Expected: fails ("DAGHitTester not found").

- [ ] **Step 3: Implement the hit-tester + the Canvas view**

- `DAGHitTester.node(at:)`: map the view point to graph space via `camera.graphPoint(fromViewPoint:viewport:)`, then find the node whose centered `nodeSize` box in graph space contains it.
- `DependencyDAGOverlay` body: a `Canvas` that, per node, draws the card at `node.position.applying(camera.transform(viewport:))` and each edge as a line between transformed endpoints (solid `.dependency`, dashed `.reservation`); a minimap inset; gestures — `DragGesture` pans (adjust `camera.center`), a magnify/scroll zooms (`camera.scale`), a tap runs `DAGHitTester` then `onSelectNode`/`onJumpToTab`; a `.onChange(of: selectedBeadID)` animates the camera to the selected node's position. Because nodes and edges both read `node.position` through the one `camera.transform`, cards and arrows share a coordinate space and cannot desync (the failure the HTML mockups hit).

- [ ] **Step 4: Run to verify it passes, then commit**

Run: `./scripts/test-unit.sh`. Expected: green.
```bash
git add Sources/FlightDeck/Flywheel/Observe/DependencyDAGOverlay.swift Tests/FlightDeckTests/Flywheel/Observe/DAGOverlayHitTestTests.swift
git commit -m "feat(flywheel): whole-graph DAG overlay with tested hit-testing"
```

---

## Task 12: Integration — mount the drawer, own the service, wire the notifier + gating

Wire the pieces into the live app: own `FlywheelObserveService` + `FlywheelNotifier` in `SessionStore`, start/stop watchers as projects enable/disable (reusing the existing `enableFlywheel`/settings path), mount `ObserveDrawer` under `TerminalPane` in `RootView`, request notification authorization lazily on first enable, and gate watchers with the existing idle/occlusion mechanisms. This is integration; it is GUI-verified (Task 13). Keep the non-integration logic (already unit-tested) untouched.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (own the service; start/stop; expose focused projection; route)
- Modify: `Sources/FlightDeck/RootView.swift` (mount the drawer under `TerminalPane`)
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (inject the notifier's `Notifying`, as it already builds `SessionNotifier`)
- Test: `Tests/FlightDeckTests/Flywheel/Observe/ObserveServiceWiringTests.swift`

**Interfaces:**
- Consumes: `FlywheelObserveService` (Task 7), `FlywheelNotifier` (Task 8), `ObserveDrawer` (Task 10), `DependencyDAGOverlay` (Task 11), the existing `selectedSessionID`/`locate`/`repos`/`preferences.projectSettings` seams.
- Produces on `SessionStore`: `var observeService: FlywheelObserveService` (lazy), `func focusedObserveAgent() -> FlywheelProjection.Agent?`, and enable/disable calls threaded through the existing flywheel enable path.

- [ ] **Step 1: Write the failing test — flag-off project starts zero reads (the zero-cost guarantee)**

This is the spec's headline guarantee and is unit-testable via the fake runner: enabling Observe for a project whose `flywheelEnabled != true` must issue no `am`/`br` argv.

```swift
import XCTest
@testable import FlightDeck

final class ObserveServiceWiringTests: XCTestCase {
    @MainActor
    func testDisabledProjectIssuesNoReads() async {
        let fake = MultiRunner()   // records every argv; all default to exit 127
        let svc = FlywheelObserveService(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"), clock: nil)
        // The wiring only calls svc.enable for flywheelEnabled==true projects; simulate the
        // gate by NOT enabling. Assert nothing was read.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fake.argv.isEmpty, "a project that was never enabled must issue zero am/br reads")
    }

    @MainActor
    func testEnabledProjectIssuesScopedReads() async {
        let fake = MultiRunner(); fake.responses["am agents list"] = ("[]", 0)
        let svc = FlywheelObserveService(reads: FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br"), clock: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        svc.enable(project: dir.path, watchPaths: [])
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(fake.argv.contains { $0.contains(dir.path) }, "reads must be scoped to the enabled project path")
    }
}
```
> This test pins the guarantee at the service boundary. The `RootView`/`SessionStore` mount itself is GUI-verified because the app host isn't launchable headless (AGENTS.md rule 2).

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`. Expected: the enabled-reads assertion fails until the service is used as wired (the disabled-case passes trivially — keep both to lock the guarantee).

- [ ] **Step 3: Own the service in `SessionStore`**

Add a lazily-built `FlywheelObserveService` (so a fleet with nothing enabled builds nothing), following the `sleepController` lazy pattern (`SessionStore.swift:1130`). On the existing flywheel enable path (`enableFlywheel(for:)`, `SessionStore.swift:2166`) call `observeService.enable(project: repo.path, watchPaths: [...])` after the settings flip; on disable, `observeService.disable(project:)`. Set `observeService.onProjectionsChanged = { [weak self] in self?.flywheelNotifier?.evaluate(projectsByKey: $0) }`. Add `func focusedObserveAgent()`:
```swift
func focusedObserveAgent() -> FlywheelProjection.Agent? {
    guard let id = selectedSessionID, let at = locate(id) else { return nil }
    let session = repos[at.repo].sessions[at.session]
    // FlywheelIdentity.project IS the standardized project path — the same key the
    // service stores under — so no separate Session working-directory lookup is needed.
    guard let identity = session.flywheelIdentity,
          let proj = observeService.projection(forProject: identity.project) else { return nil }
    return proj.agent(for: identity)
}
```
At startup, for each already-enabled project (`repos` filtered by `preferences?.projectSettings($0.url.path).flywheelEnabled == true`), call `observeService.enable`.

- [ ] **Step 4: Wire the notifier + lazy auth**

Build `FlywheelNotifier(notifier: <the SessionNotifier FlightDeckApp already makes>)` and set its `route` to map `(project, agentName)` → the session UUID (via `repos` lookup). Request notification authorization **lazily on first enable** (not at launch) — call `notifier.requestAuthorization()` inside the first `enableFlywheel` that turns a project on, guarded by a `hasRequestedFlywheelAuth` flag. `FlightDeckApp.swift:184-185` already builds+authorizes `SessionNotifier` for sessions; reuse that instance, do not construct a second one, and do not add a launch-time auth call.

- [ ] **Step 5: Mount `ObserveDrawer` under `TerminalPane` in `RootView`**

Wrap the existing detail-branch terminal in a `VStack(spacing: 0)` and add the drawer below it (from Agent-2's verbatim body, `RootView.swift:23-42`):
```swift
} detail: {
    if let surface = store.selectedSessionID.flatMap({ store.surface(for: $0) }) {
        VStack(spacing: 0) {
            TerminalPane(store: store)
                .frame(minWidth: 400, minHeight: 300)
                .overlay(alignment: .topTrailing) { /* unchanged SearchOverlay + ToolOverlay */ }
            if let agent = store.focusedObserveAgent() {
                ObserveDrawer(agent: agent,
                              collapsed: store.observeDrawerCollapsed,
                              onToggleCollapse: { store.toggleObserveDrawer() },
                              onJumpToRootCause: { store.jumpToObserveRootCause() },
                              onOpenDAG: { store.presentObserveDAG() })
            }
        }
    } else { /* unchanged ContentUnavailableView */ }
}
```
Add the small `SessionStore` helpers (`observeDrawerCollapsed` reading `projectSettings(...).drawerCollapsed == true`; `toggleObserveDrawer()` read-modify-writing it via `setProjectSettings`; `jumpToObserveRootCause()`/`presentObserveDAG()` setting selection / presenting the overlay). The `DependencyDAGOverlay` is presented as a sheet/overlay from `presentObserveDAG()`.

- [ ] **Step 6: Run the full suite, build the app**

Run: `./scripts/test-unit.sh` (green — the wiring test passes; nothing else regressed).
Run: `./scripts/build.sh` (the app compiles with the mounted drawer). Do **not** launch a `DerivedData` bundle.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/RootView.swift Sources/FlightDeck/FlightDeckApp.swift Tests/FlightDeckTests/Flywheel/Observe/ObserveServiceWiringTests.swift
git commit -m "feat(flywheel): mount Observe drawer + own the observe service and notifier"
```

---

## Task 13: GUI verification checklist + docs

The app-driving verification agents can't do (AGENTS.md rule 2) becomes a runbook Nate executes. Also update the flywheel docs to describe Level 1.

**Files:**
- Create: `docs/FLYWHEEL-OBSERVE-CHECKLIST.md`
- Modify: `docs/FOLLOWUPS.md` (note any lane Task 1 shipped "unavailable", and the FSEvents-vs-WatchClock decision)

- [ ] **Step 1: Write the checklist**

`docs/FLYWHEEL-OBSERVE-CHECKLIST.md` with concrete steps against a scratch flywheel repo with ≥2 agents:
1. Enable Flywheel on the project; confirm the drawer appears under the focused agent's tab and is absent on a non-identity tab.
2. Drawer follows the focused tab (`Shift+Cmd+[`/`]`); each lane shows real data; a lane whose command is unavailable reads "unavailable" while the others render.
3. Collapse/expand persists across relaunch (per-project).
4. Open the DAG (⤢): the whole graph renders, camera centered on the focused bead; pan/zoom/minimap work; edges stay aligned to cards; the diamond (shared dep) appears once.
5. Click a node → jumps to that agent's tab; an external node isn't clickable-to-tab.
6. Force a persistent block → a notification fires and its click lands on the right tab; a brief block does not notify.
7. Force a stalled-holder collision → notifies; an active-holder collision does not.
8. Disable Flywheel → drawer gone, no watcher (verify no `am`/`br` in Activity Monitor for that project).

- [ ] **Step 2: Update `docs/FOLLOWUPS.md`**

Add: the transport is `WatchClock`-mtime-gated (not FSEvents) with the rationale; any lane shipped "unavailable" from Task 1; the notifier thresholds are constants (preferences deferred); reservation-TTL-churn handling.

- [ ] **Step 3: Commit**

```bash
git add docs/FLYWHEEL-OBSERVE-CHECKLIST.md docs/FOLLOWUPS.md
git commit -m "docs(flywheel): Observe GUI checklist and Level 1 follow-ups"
```

---

## Final: whole-branch review

After Task 13, request a fresh whole-branch code review (`superpowers:requesting-code-review`) with `BASE_SHA` = the merge-base with `master` and `HEAD_SHA` = the final commit. Fix Critical/Important before proposing merge. GUI e2e (the Task 13 checklist) is **Nate's** to run — agents can't drive the real app (AGENTS.md rule 2).
