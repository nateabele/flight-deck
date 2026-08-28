# Background Work as a Decoration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `shell` from `SessionActivity` and re-express "a background task is running" as an orthogonal, latched decoration, fixing the prompt guards that refuse a live idle agent.

**Architecture:** `shell` is Claude Code's flattening of `idle ∧ hasBackgroundTasks` into one field. We decompose it at the decode boundary, latch the fact in `SessionStore` as a `Set<UUID>` parallel to `statuses` (mirroring `FleetService.phoneActiveSessions`), carry it over the wire as a new `WireSession` field, and render it as a badge sibling to `PhonePresenceBadge` on both platforms.

**Tech Stack:** Swift 6, SwiftUI, XCTest. macOS app + iOS companion + shared `FleetKit`.

**Spec:** `docs/superpowers/specs/2026-08-27-background-work-as-decoration-design.md`

## Global Constraints

- **Branch: `fleet-pairing`.** `Sources/FlightDeckMobile` exists only there. Work in the worktree at `.claude/worktrees/fleet-pairing`.
- **In a worktree, use the built-in `Edit`/`Write` tools, never the qartez mutators** — in a worktree they report success while writing to the main checkout.
- **This checkout is shared by concurrent sessions.** Never `git stash`, `git checkout .`, or revert blind. Check `git status` and leave changes that aren't yours alone.
- `Sources/FleetKit` may import **`Foundation`, `Network`, `Security` only**. `scripts/build-ios.sh` is what enforces this.
- Keep `Sources/FlightDeckMobile` **flat** — `build-ios.sh`'s type-check fallback globs `*.swift` only.
- macOS tests: `./scripts/test-unit.sh` (whole headless suite, no filter flag — grep its output for the test name).
- iOS tests: `./scripts/test-ios.sh`. After touching `Sources/FleetKit` or `Sources/FlightDeckMobile`, also run `./scripts/build-ios.sh`.
- **Do not run `./scripts/smoke.sh` in a loop** — it steals focus for ~40s per run.
- `FleetKitVersion.wire` stays `1`.
- Exact copy, used verbatim in several tasks: `background command running`, separator ` — ` (em dash, spaces both sides).

---

### Task 1: Decompose `shell` at the decode boundary

`ClaudeStatusFile` learns that `"shell"` is `idle` plus a fact. `SessionActivity` keeps its `.shell` case for now — nothing will produce it after this task, and it is deleted in Task 8 once every switch is gone.

**Files:**
- Modify: `Sources/FlightDeck/ClaudeStatusFile.swift:11-50` (`Entry`), `:63-84` (`decode`)
- Test: `Tests/FlightDeckTests/ClaudeStatusFileTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ClaudeStatusFile.Entry.reportsBackgroundWork: Bool` — the raw observation, `true` only when the registry said `"shell"`. `false` means *not reported*, never *known absent*. `Entry.init` gains `reportsBackgroundWork: Bool = false` as the **last** parameter, defaulted so existing call sites keep compiling.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/ClaudeStatusFileTests.swift`:

```swift
/// `"shell"` is not a fourth activity. Claude Code writes it as `idle && hasBackgroundTasks`
/// (`mb = rm === "idle" && db ? "shell" : rm`), so it decodes into both facts, not one.
func testShellDecodesAsIdlePlusBackgroundWork() throws {
    let json = """
    {"pid":2786,"sessionId":"A4C9067B-9CAF-43CB-8B75-88A145249058",
     "status":"shell","cwd":"/tmp","procStart":"Wed Aug 26 03:26:16 2026","startedAt":1}
    """.data(using: .utf8)!
    let entry = try XCTUnwrap(ClaudeStatusFile.decode(json, expectedPID: 2786))
    XCTAssertEqual(entry.activity, .idle)
    XCTAssertTrue(entry.reportsBackgroundWork)
}

/// A plain `idle` reports nothing, which is distinct from reporting absence.
func testIdleReportsNoBackgroundWork() throws {
    let json = """
    {"pid":2497,"sessionId":"3BF6A1C7-00FC-4ABF-92F5-49163B5B4FAB",
     "status":"idle","cwd":"/tmp","procStart":"Wed Aug 26 03:26:15 2026","startedAt":1}
    """.data(using: .utf8)!
    let entry = try XCTUnwrap(ClaudeStatusFile.decode(json, expectedPID: 2497))
    XCTAssertEqual(entry.activity, .idle)
    XCTAssertFalse(entry.reportsBackgroundWork)
}

/// Unchanged: an unrecognised status still fails closed.
func testUnknownStatusStillDecodesToNil() {
    let json = """
    {"pid":1,"sessionId":"3BF6A1C7-00FC-4ABF-92F5-49163B5B4FAB",
     "status":"teleporting","cwd":"/tmp","procStart":"x","startedAt":1}
    """.data(using: .utf8)!
    XCTAssertNil(ClaudeStatusFile.decode(json, expectedPID: 1))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `value of type 'ClaudeStatusFile.Entry' has no member 'reportsBackgroundWork'`.

- [ ] **Step 3: Add the field to `Entry`**

In `Sources/FlightDeck/ClaudeStatusFile.swift`, add after the `procStart` property (line 28):

```swift
        /// Whether the registry reported a background task running under this agent.
        ///
        /// The **observation**, not a conclusion. Claude Code can only report this while the
        /// session is idle — it writes `"shell"` for `idle && hasBackgroundTasks` and plain
        /// `busy`/`waiting` otherwise — so `false` here means *not reported*, never *known
        /// absent*. `SessionStore` owns turning these observations into durable state.
        let reportsBackgroundWork: Bool
```

Add the parameter to `init` as the **last** one, defaulted, and assign it:

```swift
            procStart: String = "",
            reportsBackgroundWork: Bool = false
        ) {
            ...
            self.procStart = procStart
            self.reportsBackgroundWork = reportsBackgroundWork
        }
```

- [ ] **Step 4: Split `"shell"` in `decode`**

Replace the `rawStatus`/`activity` pair in the `guard` (lines 69-70) — drop `activity` from the guard, keeping only `rawStatus`:

```swift
              let rawStatus = obj["status"] as? String,
```

Then between the `guard`'s closing `else { return nil }` and the `return Entry(`:

```swift
        // `"shell"` is not a fourth activity: Claude Code writes it for `idle &&
        // hasBackgroundTasks` and reports the two facts through one field. Split here so
        // nothing downstream has to know the encoding — and note the asymmetry, which is
        // upstream's and not ours: during a turn it reports `busy` and drops the background
        // fact entirely, so `false` below is "not reported", not "no background work".
        let activity: SessionActivity
        let reportsBackgroundWork: Bool
        if rawStatus == "shell" {
            activity = .idle
            reportsBackgroundWork = true
        } else {
            guard let parsed = SessionActivity(rawValue: rawStatus) else { return nil }
            activity = parsed
            reportsBackgroundWork = false
        }
```

Add `reportsBackgroundWork: reportsBackgroundWork` as the last argument of the `return Entry(...)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, whole suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/ClaudeStatusFile.swift Tests/FlightDeckTests/ClaudeStatusFileTests.swift
git commit -m "feat: decode \`shell\` as idle plus a background-work observation"
```

---

### Task 2: Latch the fact in `SessionStore`

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — near `statuses` (`:31`), in `applyRegistry` (`:3680-3710`), in `commitStatuses` (`:3704-3755`)
- Test: `Tests/FlightDeckTests/SessionStatusTests.swift` (new cases) or a new `Tests/FlightDeckTests/BackgroundWorkLatchTests.swift`

**Interfaces:**
- Consumes: `ClaudeStatusFile.Entry.reportsBackgroundWork` (Task 1).
- Produces: `SessionStore.backgroundWorkSessions: Set<UUID>` — `@Published private(set)`. `commitStatuses` becomes `commitStatuses(_ next: [UUID: SessionStatus], backgroundWork: Set<UUID>)`.

The latch, because upstream cannot report the fact during a turn:

| observed | action |
|---|---|
| `reportsBackgroundWork == true` | insert |
| `.idle` and not reported | **remove** — idle without `shell` proves it ended |
| `.busy` / `.waiting` | carry forward — unknowable |
| no status this tick | remove — the agent is gone, so its children are |

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/BackgroundWorkLatchTests.swift`. The store/registry fixture is
lifted from `PhonePromptDispatchTests.makeStore` — note that a registry row's `sessionID` is the
tab's **`pinnedConversationID`**, not its `id`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class BackgroundWorkLatchTests: XCTestCase {
    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    /// One registry row. `reportsBackgroundWork` is what `"shell"` decodes to (Task 1).
    private func row(
        _ conversation: UUID, _ activity: SessionActivity, background: Bool = false
    ) -> [pid_t: ClaudeStatusFile.Entry] {
        [1: .init(pid: 1, sessionID: conversation, activity: activity, waitingFor: nil,
                  startedAt: 1, cwd: tmp.path, procStart: "start-a",
                  reportsBackgroundWork: background)]
    }

    private func makeStore() -> (SessionStore, Session) {
        let store = SessionStore(provider: nil, persistence: nil)
        return (store, store.newSession(in: tmp))
    }

    /// `shell` sets it; a later plain `idle` is the only thing that clears it.
    func testShellSetsAndIdleClears() {
        let (store, session) = makeStore()
        let cid = session.pinnedConversationID

        store.applyRegistry(row(cid, .idle, background: true))
        XCTAssertTrue(store.backgroundWorkSessions.contains(session.id))

        store.applyRegistry(row(cid, .idle))
        XCTAssertFalse(store.backgroundWorkSessions.contains(session.id))
    }

    /// The whole reason for the latch: upstream stops reporting the fact during a turn, so a
    /// `busy` tick must not read as "the dev server stopped".
    func testBusyCarriesTheFactForward() {
        let (store, session) = makeStore()
        let cid = session.pinnedConversationID

        store.applyRegistry(row(cid, .idle, background: true))
        store.applyRegistry(row(cid, .busy))
        XCTAssertTrue(store.backgroundWorkSessions.contains(session.id))

        store.applyRegistry(row(cid, .waiting))
        XCTAssertTrue(store.backgroundWorkSessions.contains(session.id))

        store.applyRegistry(row(cid, .idle))
        XCTAssertFalse(store.backgroundWorkSessions.contains(session.id))
    }

    /// An agent that exits takes its children with it.
    func testEmptyRegistryClears() {
        let (store, session) = makeStore()
        store.applyRegistry(row(session.pinnedConversationID, .idle, background: true))
        store.applyRegistry([:])
        XCTAssertFalse(store.backgroundWorkSessions.contains(session.id))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `value of type 'SessionStore' has no member 'backgroundWorkSessions'`.

- [ ] **Step 3: Add the published set**

In `Sources/FlightDeck/SessionStore.swift`, immediately after the `statuses` declaration (line 31):

```swift
    /// Tabs with a background task running under their agent.
    ///
    /// A **decoration**, orthogonal to `statuses` — the same shape and lifetime as
    /// `FleetService.phoneActiveSessions`, and for the same reason: it is a fact *about* a
    /// tab, not a state the tab is in. Kept beside `statuses` rather than inside
    /// `SessionStatus` so that no consumer has to switch on it, and so the activity enum
    /// stays a total ordering of one axis.
    ///
    /// Latched. Upstream reports this only while idle (see `ClaudeStatusFile.Entry
    /// .reportsBackgroundWork`), so a `busy` tick carries the last known value forward and
    /// only a plain `idle` — or a vanished agent — clears it.
    @Published private(set) var backgroundWorkSessions: Set<UUID> = []
```

- [ ] **Step 4: Compute the next set in `applyRegistry`**

In `applyRegistry`, alongside the `var next: [UUID: SessionStatus] = [:]` rebuild loop, add a parallel accumulator. Inside the existing `for session in repos.flatMap(\.sessions)` loop, in the branch that already has `entry` in hand (right where `next[session.id] = SessionStatus(...)` is assigned):

```swift
            // Latched, not rebuilt: `false` from the registry means "not reported", and only
            // an idle tick is proof the task ended. See `backgroundWorkSessions`.
            if entry.reportsBackgroundWork {
                nextBackgroundWork.insert(session.id)
            } else if entry.activity != .idle, backgroundWorkSessions.contains(session.id) {
                nextBackgroundWork.insert(session.id)
            }
```

Declare `var nextBackgroundWork: Set<UUID> = []` next to `var next`. Sessions with no `entry` this tick fall through both branches and so are absent from the new set — which is the "agent gone, children gone" rule, for free.

Change the call at the end of `applyRegistry` from `commitStatuses(next)` to:

```swift
        commitStatuses(next, backgroundWork: nextBackgroundWork)
```

- [ ] **Step 5: Widen `commitStatuses`**

Change the signature and the early-return guard:

```swift
    private func commitStatuses(_ next: [UUID: SessionStatus], backgroundWork: Set<UUID>) {
        // BOTH, not just `statuses`. A task starting or ending under an otherwise-idle tab
        // moves this set and nothing else — guarding on `statuses` alone swallowed that tick
        // entirely, so the badge never lit and no event ever reached the phone.
        guard next != statuses || backgroundWork != backgroundWorkSessions else { return }
```

Assign the set next to `statuses = next`:

```swift
        let previous = statuses
        let previousBackgroundWork = backgroundWorkSessions
        statuses = next
        backgroundWorkSessions = backgroundWork
```

Widen the transition set so a background-only change still produces a transition to emit:

```swift
        let touched = Set(previous.keys)
            .union(next.keys)
            .union(previousBackgroundWork.symmetricDifference(backgroundWork))
        let transitions = touched.map {
            StatusTransition(id: $0, old: previous[$0], new: next[$0])
        }
```

Find every other caller of `commitStatuses(` (there is at least the test seam around `:2591-2595`) and pass `backgroundWork: backgroundWorkSessions` to preserve current behaviour.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/BackgroundWorkLatchTests.swift
git commit -m "feat: latch background work as a set beside statuses"
```

---

### Task 3: Persist the flag and keep auto-resume working

Task 1 turned `shell` into `idle`, so a tab with a live dev server now persists as `.idle` and would stop being auto-resumed. This task closes that, and teaches the reader to migrate the `"shell"` values already sitting in `sessions.json` on every machine.

**Files:**
- Modify: `Sources/FlightDeck/SessionPersistence.swift:31-70` (the snapshot's session record)
- Modify: `Sources/FlightDeck/SessionStore.swift:1776-1782` (restore predicate), `:2291-2293` (`resumableActivities`), `:1949` (the write)
- Test: `Tests/FlightDeckTests/SessionAutoResumeTests.swift`

**Interfaces:**
- Consumes: `SessionStore.backgroundWorkSessions` (Task 2).
- Produces: `SessionPersistence.Snapshot.<SessionRecord>.hasBackgroundWork: Bool?` — optional, `nil` omitted from the file for the common case. `SessionStore.resumableActivities` is **deleted** and replaced by `SessionStore.isResumable(activity:hasBackgroundWork:) -> Bool`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/SessionAutoResumeTests.swift`:

```swift
/// A tab that went away with a dev server running was working, and must still be resumed
/// now that `shell` decodes as `idle`.
func testIdleWithBackgroundWorkIsResumable() {
    XCTAssertTrue(SessionStore.isResumable(activity: .idle, hasBackgroundWork: true))
    XCTAssertTrue(SessionStore.isResumable(activity: .busy, hasBackgroundWork: false))
    XCTAssertFalse(SessionStore.isResumable(activity: .idle, hasBackgroundWork: false))
    // Unchanged: what a waiting tab was blocked on does not survive the restart.
    XCTAssertFalse(SessionStore.isResumable(activity: .waiting, hasBackgroundWork: true))
}

/// Every `sessions.json` written before this change stores `"shell"`. Reading one back must
/// not lose the status — `SessionActivity(rawValue: "shell")` is nil now.
func testLegacyShellInSnapshotRestoresAsIdleWithBackgroundWork() {
    let restored = SessionStore.restoredActivity(fromPersisted: "shell")
    XCTAssertEqual(restored.activity, .idle)
    XCTAssertTrue(restored.hasBackgroundWork)

    let plain = SessionStore.restoredActivity(fromPersisted: "idle")
    XCTAssertEqual(plain.activity, .idle)
    XCTAssertFalse(plain.hasBackgroundWork)

    XCTAssertNil(SessionStore.restoredActivity(fromPersisted: nil).activity)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — no `isResumable` / `restoredActivity` members.

- [ ] **Step 3: Add the persisted field**

In `Sources/FlightDeck/SessionPersistence.swift`, beside `var activity: String?` (line 37):

```swift
        /// Whether a background task was running under this agent when the snapshot was
        /// written. Optional, and `nil` rather than `false` for the common case, so the file
        /// stays readable — the same reason `unread` is optional.
        var hasBackgroundWork: Bool?
```

Add it to the memberwise `init` as a defaulted parameter (`hasBackgroundWork: Bool? = nil`) beside `activity`, and assign it.

- [ ] **Step 4: Write it, and read it back**

In `SessionStore.swift:1949`, beside the `activity:` argument in the snapshot builder:

```swift
                    // `nil` rather than `false` so the common case adds no noise, matching
                    // `unread` directly below.
                    hasBackgroundWork: backgroundWorkSessions.contains($0.id) ? true : nil,
```

Replace `resumableActivities` (`:2291-2293`) with:

```swift
    /// Whether a restored tab was working when we went away.
    ///
    /// `waiting` is excluded: what it was blocked on does not survive the restart. Background
    /// work counts even at `.idle`, and that is not a special case — it is the same rule as
    /// before, now that `shell` is decomposed. A tab with a dev server up *was* working.
    static func isResumable(activity: SessionActivity, hasBackgroundWork: Bool) -> Bool {
        activity == .busy || hasBackgroundWork
    }

    /// Reads a persisted `activity` string, migrating the pre-decomposition `"shell"`.
    ///
    /// Permanent, not transitional: every `sessions.json` on every machine holds `"shell"`
    /// today, and `SessionActivity(rawValue:)` returns nil for it now. Dropping this read
    /// would blank the status of every backgrounded tab on first launch after the upgrade.
    static func restoredActivity(
        fromPersisted raw: String?
    ) -> (activity: SessionActivity?, hasBackgroundWork: Bool) {
        guard let raw else { return (nil, false) }
        if raw == "shell" { return (.idle, true) }
        return (SessionActivity(rawValue: raw), false)
    }
```

Rewrite the restore gate at `:1776-1782`:

```swift
            if autoResume, !orphaned, session.agent.textChannel != nil {
                let restored = Self.restoredActivity(fromPersisted: entry.activity)
                let hasBackgroundWork = entry.hasBackgroundWork ?? restored.hasBackgroundWork
                if let activity = restored.activity,
                   Self.isResumable(activity: activity, hasBackgroundWork: hasBackgroundWork) {
                    pendingPrompts[entry.id] = DeferredPrompt(
                        text: Self.resumePrompt, deadline: promptDeadline
                    )
                }
            }
```

Seed `backgroundWorkSessions` from the same restore loop so the badge survives a relaunch: where the loop already applies `entry.activity` to the restored session, insert `session.id` into `backgroundWorkSessions` when `hasBackgroundWork` is true.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionPersistence.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionAutoResumeTests.swift
git commit -m "feat: persist background work and migrate legacy \`shell\` snapshots"
```

---

### Task 4: Carry the flag over the wire

**Files:**
- Modify: `Sources/FleetKit/Wire.swift:41-70` (`WireSession`), `Sources/FleetKit/FleetEvent.swift:34`, `Sources/FleetKit/WireCoding.swift:25` (keys), `:67-75` (encode), `:118-124` (decode)
- Modify: `Sources/FlightDeck/Fleet/FleetProjection.swift:33-48`, `Sources/FlightDeck/SessionStore.swift:3798-3810` (`emitActivity`), `:812`, `:1553`, `:2416`, `:4016` (projection call sites)
- Test: `Tests/FlightDeckTests/` — the existing wire/replicator suite (grep for `activityChanged` in `Tests/`)

**Interfaces:**
- Consumes: `SessionStore.backgroundWorkSessions` (Task 2).
- Produces: `WireSession.hasBackgroundWork: Bool` (last init parameter, `= false`); `FleetEvent.activityChanged(id:activity:waitingFor:subagentCount:hasBackgroundWork:)`; `FleetProjection.project(_:status:unread:hasBackgroundWork:)` and `project(_:statuses:unread:backgroundWork:)`.

- [ ] **Step 1: Write the failing test**

Add to the existing wire-coding suite:

```swift
/// An older Mac sends no such key. The phone must decode that as `false`, not throw — a
/// throw here takes the entire snapshot down, not one field.
func testWireSessionDecodesWithoutBackgroundWorkKey() throws {
    let json = """
    {"id":"A4C9067B-9CAF-43CB-8B75-88A145249058","title":"frontend-state",
     "agent":"claude","activity":"idle","subagentCount":0,"isUnread":false}
    """.data(using: .utf8)!
    let session = try JSONDecoder().decode(WireSession.self, from: json)
    XCTAssertFalse(session.hasBackgroundWork)
}

func testActivityChangedRoundTripsBackgroundWork() throws {
    let event = FleetEvent.activityChanged(
        id: UUID(), activity: "idle", waitingFor: nil,
        subagentCount: 0, hasBackgroundWork: true
    )
    let data = try JSONEncoder().encode(event)
    let decoded = try JSONDecoder().decode(FleetEvent.self, from: data)
    XCTAssertEqual(decoded, event)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — no `hasBackgroundWork` member.

- [ ] **Step 3: Extend `WireSession`**

In `Sources/FleetKit/Wire.swift`, after `isUnread` (line 58):

```swift
    /// A background task is running under this tab's agent. Orthogonal to `activity`, not a
    /// value of it: the Mac reports `activity: "idle"` and this together for a tab sitting at
    /// its prompt with a dev server up.
    public var hasBackgroundWork: Bool
```

Add `hasBackgroundWork: Bool = false` as the last `init` parameter and assign it. Then give the type an explicit decoder so a missing key is `false` rather than a throw — synthesized `Codable` does **not** apply property defaults to absent keys:

```swift
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        agent = try c.decode(String.self, forKey: .agent)
        activity = try c.decodeIfPresent(String.self, forKey: .activity)
        waitingFor = try c.decodeIfPresent(String.self, forKey: .waitingFor)
        subagentCount = try c.decode(Int.self, forKey: .subagentCount)
        isUnread = try c.decode(Bool.self, forKey: .isUnread)
        // Absent from an older Mac's snapshot, and that is a meaningful value, not an error.
        hasBackgroundWork = try c.decodeIfPresent(Bool.self, forKey: .hasBackgroundWork) ?? false
    }
```

- [ ] **Step 4: Extend the event and its coding**

`FleetEvent.swift:34`:

```swift
    case activityChanged(id: UUID, activity: String?, waitingFor: String?,
                         subagentCount: Int, hasBackgroundWork: Bool)
```

`WireCoding.swift:25` — add `hasBackgroundWork` to the `CodingKeys`. In the encode arm (`:67`) bind the new payload and add `try c.encode(hasBackgroundWork, forKey: .hasBackgroundWork)`. In the decode arm (`:118`) add:

```swift
                hasBackgroundWork: try c.decodeIfPresent(
                    Bool.self, forKey: .hasBackgroundWork) ?? false
```

Update the pattern matches at `FleetEvent.swift:59` and `:76` to bind one more `_`.

- [ ] **Step 5: Extend the projection and the emitter**

`FleetProjection.project(_:status:unread:)` gains `hasBackgroundWork: Bool` and passes it into `WireSession`. `project(_:statuses:unread:)` gains `backgroundWork: Set<UUID>` and passes `backgroundWork.contains($0.id)` per session. `snapshot(of:)` passes `store.backgroundWorkSessions`. Update every call site listed in **Files**.

In `emitActivity` (`:3798`), add:

```swift
                hasBackgroundWork: backgroundWorkSessions.contains(transition.id)
```

- [ ] **Step 6: Prove the projection and the fold agree**

`FleetReplicator` compares its event-fold mirror against `FleetProjection` on every batch — a
field learned by one and not the other is exactly what that oracle exists to catch. Add to the
existing replicator suite (grep `Tests/` for `FleetReplicator`):

```swift
/// The oracle: folding `activityChanged` must land on the same `WireSession` the projection
/// builds. A field added to one side and not the other fails here, by design.
func testBackgroundWorkSurvivesTheFold() throws {
    let store = SessionStore(provider: nil, persistence: nil)
    let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))
    store.applyRegistry([1: .init(
        pid: 1, sessionID: session.pinnedConversationID, activity: .idle, waitingFor: nil,
        startedAt: 1, cwd: NSTemporaryDirectory(), procStart: "a",
        reportsBackgroundWork: true)])

    let projected = FleetProjection.snapshot(of: store)
    let wire = try XCTUnwrap(projected.projects.flatMap(\.sessions)
        .first { $0.id == session.id })
    XCTAssertTrue(wire.hasBackgroundWork)
    XCTAssertEqual(wire.activity, "idle")
}
```

- [ ] **Step 7: Run to verify it passes**

Run: `./scripts/test-unit.sh && ./scripts/build-ios.sh`
Expected: PASS, and the iOS slice still builds (this is what enforces FleetKit's import limit).

- [ ] **Step 8: Commit**

```bash
git add Sources/FleetKit Sources/FlightDeck/Fleet/FleetProjection.swift Sources/FlightDeck/SessionStore.swift Tests/
git commit -m "feat: carry background work on the wire, tolerating its absence"
```

---

### Task 5: The Mac badge, icon and composed tooltip

**Files:**
- Modify: `Sources/FlightDeck/SessionStatus.swift:46-77` (tooltip), `Sources/FlightDeck/SessionStatusIcon.swift:36-42`, `:83-84`
- Modify: `Sources/FlightDeck/SessionSidebar.swift` (new badge, `SessionRow` field, threading at `:355-366`)
- Test: `Tests/FlightDeckTests/SessionStatusTests.swift`

**Interfaces:**
- Consumes: `SessionStore.backgroundWorkSessions` (Task 2).
- Produces: `SessionStatus.tooltip(unread:backgroundWork:) -> String` (`backgroundWork` defaulted `false`, so existing `tooltip(unread:)` calls still compile); `SessionRow.hasBackgroundWork: Bool = false`; `private struct BackgroundWorkBadge`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/SessionStatusTests.swift`:

```swift
/// The two axes are independent, so one label has to carry both. The background clause is
/// always last, which is what lets the iOS literals be a suffix of the macOS ones.
func testTooltipComposesBackgroundWork() {
    XCTAssertEqual(
        SessionStatus(activity: .idle).tooltip(unread: false, backgroundWork: true),
        "Idle — background command running"
    )
    XCTAssertEqual(
        SessionStatus(activity: .idle).tooltip(unread: true, backgroundWork: true),
        "Finished — not yet viewed — background command running"
    )
    XCTAssertEqual(
        SessionStatus(activity: .busy, subagentCount: 2)
            .tooltip(unread: false, backgroundWork: true),
        "Working — 2 subagents — background command running"
    )
    XCTAssertEqual(
        SessionStatus(activity: .waiting, waitingFor: "permission prompt")
            .tooltip(unread: false, backgroundWork: true),
        "Waiting for you — permission prompt — background command running"
    )
}

/// Without the flag nothing changes — every pre-existing string is byte-identical.
func testTooltipUnchangedWithoutBackgroundWork() {
    XCTAssertEqual(SessionStatus(activity: .idle).tooltip(unread: false), "Idle")
    XCTAssertEqual(SessionStatus(activity: .busy).tooltip(unread: false), "Working")
}
```

Delete the now-obsolete `SessionStatus(activity: .shell).tooltip` case at `SessionStatusTests.swift:38-42`.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `tooltip(unread:backgroundWork:)` does not exist.

- [ ] **Step 3: Compose the tooltip**

Replace `func tooltip(unread: Bool) -> String` in `SessionStatus.swift` with:

```swift
    /// The background clause is appended, never substituted, and always last. Every string
    /// this produced before the flag existed is unchanged when `backgroundWork` is false —
    /// which is what lets `SessionStatusGlyph.label(for:)` on iOS pin the same literals.
    func tooltip(unread: Bool, backgroundWork: Bool = false) -> String {
        let base = unread && activity == .idle ? "Finished — not yet viewed" : tooltip
        guard backgroundWork else { return base }
        return base + " — background command running"
    }
```

Delete the `case .shell:` arm from `var tooltip` (`:59-60`) — it is unreachable after Task 1 and its case disappears in Task 8. Leave `var tooltip` itself alone; `ProjectHeaderRow` and the notifier use it.

- [ ] **Step 4: Add the badge and thread the flag**

In `Sources/FlightDeck/SessionSidebar.swift`, beside `PhonePresenceBadge`:

```swift
/// A background task is running under this tab's agent.
///
/// Static, deliberately, where `PhonePresenceBadge` pulses: presence is someone *watching*
/// and wants the eye, whereas this is a fact about the tab that is true for hours at a time.
/// A second pulsing glyph in the same row would turn the sidebar into a christmas tree.
private struct BackgroundWorkBadge: View {
    var body: some View {
        Image(systemName: "terminal.fill")
            .font(.caption2.weight(.semibold))
            // The same green the status glyph used for `.shell` before this became a
            // decoration, so nothing about the sidebar's vocabulary changed — only what the
            // colour is attached to.
            .foregroundStyle(.green)
            .accessibilityHidden(true)   // the row's status label already says it
    }
}
```

Add to `SessionRow`, beside `isPhoneActive` (`:64`):

```swift
    /// A background task is running under this tab's agent. A decoration, not a state — see
    /// `SessionStore.backgroundWorkSessions`.
    var hasBackgroundWork: Bool = false
```

Render it in the same `HStack` as `PhonePresenceBadge` (`:133`), immediately after that `if`:

```swift
                if hasBackgroundWork {
                    BackgroundWorkBadge()
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
```

Thread it at `:355-366` next to `isPhoneActive`:

```swift
                            hasBackgroundWork: store.backgroundWorkSessions.contains(session.id)
```

and add a second `.animation(...)` keyed on `store.backgroundWorkSessions.contains(session.id)` — on the container, for the reason the existing comment at `:362-364` gives.

- [ ] **Step 5: Feed the composed tooltip to the icon**

In `SessionStatusIcon.swift`, add a `var hasBackgroundWork: Bool = false` property, pass it from `SessionRow`, and change `:38` and `:40` to `status.tooltip(unread: unread, backgroundWork: hasBackgroundWork)`. Delete the `case .shell:` arm at `:83-84`.

- [ ] **Step 6: Run to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck Tests/FlightDeckTests/SessionStatusTests.swift
git commit -m "feat: draw background work as a sidebar badge, not an activity glyph"
```

---

### Task 6: The phone glyph and label

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionStatusGlyph.swift:55-130`
- Test: `Tests/FlightDeckMobileTests/SessionStatusGlyphTests.swift`

**Interfaces:**
- Consumes: `WireSession.hasBackgroundWork` (Task 4).
- Produces: no new API — `label(for:)` keeps its signature and reads the flag off the session.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckMobileTests/SessionStatusGlyphTests.swift`, mirroring the macOS literals exactly:

```swift
/// Must equal `SessionStatus.tooltip(unread:backgroundWork:)` on macOS, character for
/// character. `SessionStatusTests.testTooltipComposesBackgroundWork` is the other end.
func testLabelComposesBackgroundWork() {
    XCTAssertEqual(
        SessionStatusGlyph.label(for: session(activity: "idle", hasBackgroundWork: true)),
        "Idle — background command running"
    )
    XCTAssertEqual(
        SessionStatusGlyph.label(for: session(activity: "busy", hasBackgroundWork: true)),
        "Working — background command running"
    )
    XCTAssertEqual(
        SessionStatusGlyph.label(for: session(activity: "idle")),
        "Idle"
    )
}

/// `nil` still means no accessibility element at all — a dead tab must not be a VoiceOver
/// stop, and a background flag cannot resurrect one.
func testNoAgentStillHasNoLabel() {
    XCTAssertNil(SessionStatusGlyph.label(for: session(activity: nil, hasBackgroundWork: true)))
}
```

`SessionStatusGlyphTests.swift:75` already has `session(activity:waitingFor:subagentCount:isUnread:)`.
Widen it with `hasBackgroundWork: Bool = false` and forward it to `WireSession`; do not add a
second fixture.

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-ios.sh`
Expected: FAIL — labels lack the clause.

- [ ] **Step 3: Compose the label and drop the `"shell"` glyph**

In `label(for:)`, delete the `case "shell":` arm and wrap the result:

```swift
    static func label(for session: WireSession) -> String? {
        guard let base = baseLabel(for: session) else { return nil }
        guard session.hasBackgroundWork else { return base }
        return base + " — background command running"
    }
```

Rename the existing switch body to `private static func baseLabel(for:) -> String?`, keeping every existing string, minus the `"shell"` arm.

In the glyph `switch` (`:55-85`), delete the `case "shell":` arm — `"shell"` no longer reaches the phone. Render the badge beside the glyph, in the same `HStack` the caller uses for a row, when `session.hasBackgroundWork`:

```swift
        if session.hasBackgroundWork {
            Image(systemName: "terminal.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityHidden(true)   // `label` already says it
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/build-ios.sh && ./scripts/test-ios.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeckMobile Tests/FlightDeckMobileTests
git commit -m "feat: show background work as a badge on the phone, not an activity"
```

---

### Task 7: Fix both prompt guards — the bug that started this

The refusal that made a phone say "There's no agent running in this tab right now" about a live agent. Both sides, in one task, because they are deliberately the same refusal worded once.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift:2949-2956`, `:3336-3343`, `:3444-3447`
- Modify: `Sources/FlightDeckMobile/PromptComposer.swift:73-80`
- Test: `Tests/FlightDeckTests/PhonePromptDispatchTests.swift`, `Tests/FlightDeckMobileTests/PromptComposerTests.swift` — widen the existing `session(agent:activity:)` helper at `PromptComposerTests.swift:12` with `hasBackgroundWork: Bool = false`

**Interfaces:**
- Consumes: everything above. Produces: no new API.

- [ ] **Step 1: Write the failing tests**

macOS, in `PhonePromptDispatchTests.swift`. Its `makeStore(activity:)` and `entry(_:_:cwd:)`
already exist in that file — widen `entry` with a `background: Bool = false` parameter that it
forwards as `reportsBackgroundWork`, and add a matching `makeStore(background:)` overload:

```swift
/// The regression. `shell` means the model turn has FINISHED with a background task still
/// running — the readiest state there is — and it was the one state we refused.
func testIdleTabWithBackgroundWorkAcceptsAPrompt() {
    let (store, spy, id) = makeStore(activity: .idle, background: true)
    XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .sent)
    XCTAssertEqual(spy.events, [.killLine, .text("ship it"), .ret])
}

/// Still refused, and now this is the only reason: no agent process at all.
func testATabWithNoStatusIsStillRefused() {
    let (store, _, id) = makeStore()
    store.applyRegistry([:])
    XCTAssertEqual(store.submitPrompt("ship it", token: UUID(), to: id), .notRunning)
    XCTAssertEqual(SessionStore.PromptDispatch.notRunning.errorCode, "not_running")
}
```

iOS, in `PromptComposerTests.swift`:

```swift
/// The phone's early refusal must agree with the Mac's late one. Both used to reject a live
/// idle agent because `"shell"` was read as "a bare prompt".
func testIdleWithBackgroundWorkIsSendable() {
    XCTAssertNil(PromptComposer.unavailable(
        for: session(activity: "idle", hasBackgroundWork: true)))
}

/// Still refused, and this is the only remaining reason: no agent process at all.
func testNoAgentIsStillRefused() {
    XCTAssertEqual(
        PromptComposer.unavailable(for: session(activity: nil)),
        "There's no agent running in this tab right now."
    )
}
```

- [ ] **Step 2: Run both to verify they fail**

Run: `./scripts/test-unit.sh` then `./scripts/test-ios.sh`
Expected: FAIL — both refuse.

- [ ] **Step 3: Fix the Mac guard**

`SessionStore.swift:2949-2956` — replace the comment and guard:

```swift
        // A tab with no status and no surface has nothing to type into. That is now the only
        // reason to refuse: `.shell` used to be refused here as "a bare prompt where the text
        // would be RUN rather than read", which was simply wrong — Claude Code writes it for
        // `idle && hasBackgroundTasks`, so it meant the turn had *finished*. Background work
        // is a decoration now and is deliberately not consulted.
        guard status(for: id)?.activity != nil, injector(for: id) != nil
        else { return .notRunning }
```

At `:3336-3343`, delete the sentence about `.shell` from the comment; the `.idle || .busy` whitelist is unchanged and correct.

At `:3444-3447`, `case .idle, .shell, nil:` → `case .idle, nil:`.

- [ ] **Step 4: Fix the phone guard**

`PromptComposer.swift:73-80`:

```swift
        // `nil` is "no agent process registered" and is NOT `idle` — a statusless tab has no
        // input box. `"shell"` used to be refused alongside it on the theory that it was a
        // bare prompt; it is not, and never was: it is `idle` with a background task, which
        // is a tab at its prompt waiting for exactly this.
        guard session.activity != nil else {
            return "There's no agent running in this tab right now."
        }
```

- [ ] **Step 5: Run both to verify they pass**

Run: `./scripts/test-unit.sh` then `./scripts/build-ios.sh && ./scripts/test-ios.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Sources/FlightDeckMobile/PromptComposer.swift Tests/
git commit -m "fix: stop refusing prompts to an idle agent with a background task"
```

---

### Task 8: Delete the `.shell` case

Nothing produces or matches it any more. This task is the proof of that.

**Files:**
- Modify: `Sources/FlightDeck/SessionStatus.swift:8`, `:23`
- Test: existing suites

**Interfaces:** Consumes everything above. Produces the final `SessionActivity`.

- [ ] **Step 1: Delete the case and its rank**

```swift
/// What a Claude session is doing. Raw values match the `status` field written by `claude`
/// to `~/.claude/sessions/<pid>.json` — except `shell`, which is not an activity at all:
/// `claude` writes it for `idle && hasBackgroundTasks`, and `ClaudeStatusFile.decode` splits
/// it into `.idle` plus `Entry.reportsBackgroundWork`. See `SessionStore.backgroundWorkSessions`.
enum SessionActivity: String, Equatable {
    case idle, busy, waiting
}
```

Delete `case .shell: return 2` from `summaryRank`. The remaining order is `idle 0 < busy 1 < waiting 3`; renumber `waiting` to `2` so the ranks stay contiguous, and update the doc comment, which currently explains a background command outranking work in progress — that sentence describes a case that no longer exists.

- [ ] **Step 2: Compile and run everything**

Run: `./scripts/test-unit.sh && ./scripts/build-ios.sh && ./scripts/test-ios.sh`
Expected: PASS. Any compile error here names a `.shell` reference an earlier task was supposed to remove — fix it in place rather than restoring the case.

- [ ] **Step 3: Check for stragglers**

Run: `rg -n '\.shell\b|"shell"' Sources Tests UITests`
Expected: only unrelated hits — `ShellPreferences`/`shellOverride`/`ShellResolver`, `TimelineStyle.swift:98`'s tool-icon mapping, and `SessionFixture.shellURL`. No `SessionActivity.shell`.

- [ ] **Step 4: Commit**

```bash
git add Sources/FlightDeck/SessionStatus.swift
git commit -m "refactor: delete the \`shell\` activity case"
```

---

### Task 9: Verify against the live fleet

Not a code change. The fleet currently contains the exact fixture this plan was written from.

- [ ] **Step 1: Confirm the fixture still exists**

```bash
ps -p 2786 -o pid,command          # claude --resume a4c9067b… (frontend-state, ogolvy-app)
cat ~/.claude-fieldwealth/sessions/2786.json | python3 -m json.tool | grep status
pgrep -P 214                        # the npm/vite background task under it
```

If pid 2786 is gone, reproduce it: open any tab, run a long-lived command in the background (`npm run dev`, or `sleep 9999 &`), and wait for its status file to read `"status":"shell"`.

- [ ] **Step 2: Build and launch in place**

```bash
./scripts/build.sh
```

Launch the built Debug app **in place** from `DerivedData` — do **not** swap `/Applications`, which kills every other session's app.

- [ ] **Step 3: Check the three things**

1. The `frontend-state` row shows an **idle dot plus the green terminal badge**, not a terminal glyph instead of the dot.
2. Its tooltip reads `Idle — background command running`.
3. From the phone (`scripts/deploy-phone.sh`, pair, open the tab) the composer accepts a prompt instead of showing "There's no agent running in this tab right now."

- [ ] **Step 4: Confirm the badge survives a turn**

Send a prompt and watch the row while the turn runs: the dot becomes a spinner, and the **badge stays**. That is the latch. It clears only once the turn ends and the background task is actually gone.
