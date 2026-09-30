# Reopen Status-Badge Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix a sidebar session that is stuck showing the `idle` status badge forever after being closed and reopened (⇧⌘T), by (a) making the badge follow the newest live process for its conversation and (b) stopping reopen from leaving a duplicate `claude` process resuming the same conversation.

**Architecture:** Two independent, additive changes. Defect 2 (the visible symptom) is a behavior change confined to the pure function `ConversationPin.resolve`: the anchored branch gains a "supersede" step so it hands the anchor off to a strictly-newer live process running the *same* conversation. Defect 1 (the underlying cause of there being two processes) adds a dedupe step to `SessionStore.resumeExisting` — the single choke point for resuming an existing conversation — which reaps any live process already resuming that conversation before the fresh one is spawned, using the app's existing reaper.

**Tech Stack:** Swift, XCTest, macOS app target (`FlightDeck`). Tests run headless via `scripts/test-unit.sh`.

**Spec:** Embedded below (Background & Root Cause). This plan is self-contained; the design was derived from live-state forensics and a full trace of the create/close/reopen and status-resolution paths.

## Global Constraints

- **Target & tests are macOS-only.** All changed files live under `Sources/FlightDeck/` (the macOS core). Do **not** touch `Sources/FlightDeckMobile/`. The test runner is `scripts/test-unit.sh`.
- **`test-unit.sh` runs the FULL unit suite** regardless of any `-only-testing:` filter, and takes ~8 minutes. Do not conclude a specific test "didn't run" — scan its output for the test name. Budget the time; do not loop it.
- **Do not use quillmap mutators to edit source in this checkout if execution happens in a git worktree** — in a worktree they silently write to the main checkout. Use built-in `Read`+`Edit` for edits. (In the main checkout, either is fine.)
- **Shared working copy.** Several sessions edit this checkout concurrently. `git add` only the exact files each task changes — never `git add -A`. There are unrelated uncommitted changes under `scripts/adapterprobe/` and `scripts/test-adapters.sh`; leave them untouched.
- **Wire/exhaustiveness:** no new enum cases here, so no cross-switch coordination needed.

---

## Background & Root Cause (the embedded spec)

**Symptom:** A named session ("Pipeline Optimization") permanently shows the faint `idle` badge and never transitions to busy/waiting, even while it is clearly doing work. It broke after the tab was closed and reopened with ⇧⌘T.

**Verified live state:** Two `claude` processes were resuming the *same* conversation id `9a702f30…`:
- pid **3404**, status file `idle`, `startedAt` Sep 11 (the pre-close process, still alive).
- pid **58313**, status file `busy`, `startedAt` Sep 13 (the process the ⇧⌘T reopen launched; actively writing the transcript).

The tab's terminal is attached to 58313, but its status **anchor** is latched on 3404, which reports idle. Its persisted record shows `id != pinnedConversationID` — the fingerprint of a resume.

**Why the badge is stuck (Defect 2 — `ConversationPin.swift`).** The idle/busy/waiting badge is not pushed per-tab; every registry tick, `SessionStore.applyRegistry` maps each tab to a live process ("anchor" = pid + procStart) via `ConversationPin.resolve`, then reads `rows[anchor.pid].activity`. `resolve` has two branches:
- **Anchored:** if `rows[anchor.pid]` exists with a matching `procStart`, it follows that pid and consults *no other row*.
- **Unanchored:** "newest process wins" among rows whose `sessionID == conversationID`.

The "newest wins" scan is reachable only when `anchor == nil`. Once anchored to pid 3404 (alive, matching procStart), the newer busy pid 58313 is invisible. Badge stays idle. `startedAt` (epoch ms, `Double`) is a monotonic per-process constant and is exactly the comparator the unanchored branch already uses.

**Why there are two processes (Defect 1 — `SessionStore`).** Closing a tab whose process was spawned in `restore()`'s synchronous batch cannot reap that process: `SurfaceProcessRegistry` files batch-spawned forks under random UUIDs (not the tab id), so `closeSession`'s `reapSession` finds `process(for: id) == nil`, skips the SIGHUP→SIGTERM→SIGKILL ladder, and teardown degrades to libghostty's SIGHUP-only, non-escalating loop — which the `setsid()`'d `claude` grandchild survives. Reopen (`resumeExisting`) then spawns a second `claude --resume` with **no check** for the live original. Two claudes writing one transcript is also a concurrent-writer hazard, independent of the badge.

There is **no reattach machinery on master** (the fd-abduco/detach work is unmerged), so "adopt the existing process" is not available — a surface must fork its own child. The correct in-scope fix is therefore: at resume time, reap any live process already resuming that conversation, then spawn.

**Scope of the fix.** `resumeExisting` is the single choke point for resuming an existing conversation (reached by ⇧⌘T reopen for both `.session` and `.project`, the phone's `reopenClosedSession`, and `openConversation`). It is **not** used by `restore()` or new-session, which spawn fresh `--session-id` processes for unique conversations. Placing the dedupe there fires exactly when a duplicate is possible and never on a legitimate fresh spawn.

**Interaction.** Defect 2 makes the badge correct even during the brief window where two processes coexist; Defect 1 removes the duplicate so the window closes. They are complementary and each is independently valuable.

---

## File Structure

- `Sources/FlightDeck/ConversationPin.swift` — MODIFY `resolve` (anchored branch): add the supersede step. Pure, no interface change.
- `Sources/FlightDeck/SessionStore.swift` — ADD a pure static helper `duplicateResumePids(conversation:in:)`, ADD an `async` method `reapResumeDuplicates(_:context:)`, and WIRE a synchronous capture + fire-and-forget reap into `resumeExisting`.
- `Tests/FlightDeckTests/ConversationPinTests.swift` — ADD supersede unit tests (defect 2).
- `Tests/FlightDeckTests/ConversationRepinTests.swift` — ADD an `applyRegistry` activity assertion proving the badge follows the newest process (defect 2, end to end).
- `Tests/FlightDeckTests/ReopenDedupeTests.swift` — CREATE; defect-1 tests mirroring the injected-reaper harness in `OrphanSweepTests.swift`.

---

### Task 1: Defect 2 — supersede a stale anchor with the newest live process for the same conversation

**Files:**
- Modify: `Sources/FlightDeck/ConversationPin.swift` (the `if let anchor { … }` branch, currently lines ~83–90)
- Test: `Tests/FlightDeckTests/ConversationPinTests.swift`

**Interfaces:**
- Consumes: `ConversationPin.resolve(conversationID:transcriptDirectory:anchor:rows:)`, `ClaudeStatusFile.Entry` (fields `pid`, `sessionID`, `startedAt`, `procStart`, `cwd`), `ConversationPin.Anchor(pid:procStart:)`.
- Produces: no signature change. Same `Resolution`. Only the anchored branch's chosen row/anchor changes.

- [ ] **Step 1: Write the failing tests**

Add to `ConversationPinTests.swift` (uses the existing `row(...)` helper):

```swift
/// The reopen bug: anchored to an OLD live process for our conversation while a
/// strictly-newer live process (the reopen's own `claude --resume`) runs the same
/// conversation. The anchor must hand off to the newer process so the badge follows
/// the one actually doing the work.
func testAnchorHandsOffToAStrictlyNewerProcessForTheSameConversation() {
    let conversation = UUID()
    let resolution = ConversationPin.resolve(
        conversationID: conversation,
        transcriptDirectory: "/w",
        anchor: .init(pid: 7, procStart: "old"),
        rows: [
            7: row(pid: 7, session: conversation, procStart: "old", startedAt: 1),
            9: row(pid: 9, session: conversation, procStart: "new", startedAt: 2),
        ]
    )

    XCTAssertEqual(resolution.anchor, .init(pid: 9, procStart: "new"))
    XCTAssertEqual(resolution.conversationID, conversation)
}

/// No flapping: once anchored to the newest, it stays put — the older sibling never
/// steals the anchor back. This is the fixed point that makes the handoff converge.
func testAnchorStaysOnTheNewestProcessAndDoesNotFlapBack() {
    let conversation = UUID()
    let rows: [pid_t: ClaudeStatusFile.Entry] = [
        7: row(pid: 7, session: conversation, procStart: "old", startedAt: 1),
        9: row(pid: 9, session: conversation, procStart: "new", startedAt: 2),
    ]
    for _ in 0..<20 {
        let resolution = ConversationPin.resolve(
            conversationID: conversation,
            transcriptDirectory: "/w",
            anchor: .init(pid: 9, procStart: "new"),
            rows: rows
        )
        XCTAssertEqual(resolution.anchor, .init(pid: 9, procStart: "new"))
    }
}

/// The supersede check keys off the ANCHORED process's current conversation, not the
/// pin. A process that itself resumed into a new conversation must still repin (and must
/// NOT be abandoned for a stranger that happens to hold the old pinned id). Guards the
/// repin feature against the new code path.
func testSupersedeDoesNotHijackAProcessThatChangedConversation() {
    let pinned = UUID()
    let moved = UUID()   // the anchored process resumed into this conversation
    let resolution = ConversationPin.resolve(
        conversationID: pinned,
        transcriptDirectory: "/w",
        anchor: .init(pid: 7, procStart: "old"),
        rows: [
            // our anchored process, now on `moved`
            7: row(pid: 7, session: moved, procStart: "old", startedAt: 1),
            // a newer stranger holding the OLD pinned conversation
            9: row(pid: 9, session: pinned, procStart: "new", startedAt: 2),
        ]
    )

    XCTAssertEqual(resolution.conversationID, moved, "still a repin to our process's new conversation")
    XCTAssertEqual(resolution.anchor, .init(pid: 7, procStart: "old"), "did not jump to the stranger")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-unit.sh`
Expected: the three new tests FAIL (the anchored branch currently returns pid 7 / the moved-but-kept behavior differs), while all existing `ConversationPinTests` still pass. In particular `testAnchoredRowChangingConversationIsARepin`, `testRecycledPidLosesTheAnchorRatherThanRepinning`, and `testVanishedRowLosesTheAnchorAndKeepsThePin` must remain green after the fix (Step 4).

- [ ] **Step 3: Implement the supersede step**

In `ConversationPin.resolve`, replace the anchored branch. Current:

```swift
        if let anchor {
            // A row under our pid whose process start time differs is a *different*
            // process that inherited a recycled pid, not our session resuming.
            guard let row = rows[anchor.pid], row.procStart == anchor.procStart else {
                return unchanged
            }
            return resolution(anchor: anchor, row: row, fallback: transcriptDirectory)
        }
```

Replace with:

```swift
        if let anchor {
            // A row under our pid whose process start time differs is a *different*
            // process that inherited a recycled pid, not our session resuming.
            guard let row = rows[anchor.pid], row.procStart == anchor.procStart else {
                return unchanged
            }
            // Follow our process, unless a strictly-newer process is running the SAME
            // conversation this one currently is. That newer process is a reopen/resume
            // that superseded us (two `claude --resume` on one conversation); the badge
            // must track the process actually doing the work. Compared on `startedAt`
            // (epoch ms, a per-process constant) so the winner is stable tick-to-tick and
            // never flaps, and keyed on `row.sessionID` — the anchored process's *current*
            // conversation, not the pin — so a process that itself resumed into a new
            // conversation is not abandoned for a stranger that still holds the old pin.
            if let newer = rows.values
                .filter({ $0.sessionID == row.sessionID && $0.startedAt > row.startedAt })
                .max(by: { ($0.startedAt, $0.pid) < ($1.startedAt, $1.pid) }) {
                return resolution(
                    anchor: Anchor(pid: newer.pid, procStart: newer.procStart),
                    row: newer,
                    fallback: transcriptDirectory
                )
            }
            return resolution(anchor: anchor, row: row, fallback: transcriptDirectory)
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-unit.sh`
Expected: the three new tests PASS and the full `ConversationPinTests` suite (including the repin/recycled-pid/vanished-row cases) PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ConversationPin.swift Tests/FlightDeckTests/ConversationPinTests.swift
git commit -m "Follow the newest live process for a conversation when anchored

An anchored tab followed its pid forever, so a reopen/resume that spawned a
second claude on the same conversation left the badge latched on the stale
(idle) process. Hand the anchor off to a strictly-newer process running the
same conversation; startedAt is a per-process constant so it converges without
flapping, and keying on the anchored row's current conversation preserves repin."
```

---

### Task 2: Defect 2 — end-to-end proof the badge activity follows the newest process

**Files:**
- Test: `Tests/FlightDeckTests/ConversationRepinTests.swift` (add one test; reuse that file's `@MainActor` store setup and `row(...)`/`applyRegistry` helpers)

**Interfaces:**
- Consumes: `SessionStore.applyRegistry(_:)`, `SessionStore.status(for:)`, `SessionActivity`, the file's existing test helpers for building a store with one claude session and feeding registry rows. (Confirm the helper's `row(...)` allows distinct `startedAt`; the file currently hardcodes `startedAt: 1`, so pass explicit values — extend the helper signature if needed.)

- [ ] **Step 1: Write the failing test**

```swift
/// The reopen bug, at the SessionStore level: a tab first anchors to an idle process,
/// then a strictly-newer BUSY process appears for the same conversation. The badge must
/// report `.busy`, not stay `.idle`.
func testBadgeFollowsTheNewestProcessAfterAResumeDuplicate() {
    // (Mirror this file's existing "one claude session" setup. `conversation` is the
    // session's pinnedConversationID; `account` matches the store's applyRegistry account.)
    let session = /* the single claude session created by the harness */
    let conversation = session.pinnedConversationID

    // Tick 1: only the old idle process exists → tab anchors to it.
    store.applyRegistry([
        3404: entry(pid: 3404, session: conversation, activity: .idle, startedAt: 1),
    ])
    XCTAssertEqual(store.status(for: session.id)?.activity, .idle)

    // Tick 2: the reopen's newer busy process joins, same conversation.
    store.applyRegistry([
        3404: entry(pid: 3404, session: conversation, activity: .idle, startedAt: 1),
        58313: entry(pid: 58313, session: conversation, activity: .busy, startedAt: 2),
    ])

    XCTAssertEqual(store.status(for: session.id)?.activity, .busy,
                   "badge must track the newest live process for the conversation")
}
```

Note for the implementer: name the row-builder to match what `ConversationRepinTests` already uses (it has a `row(...)`/entry helper). Ensure `startedAt` differs between the two rows; if the existing helper hardcodes `startedAt`, add a parameter defaulting to the current value so no other test changes.

- [ ] **Step 2: Run to verify it fails BEFORE Task 1's fix / passes after**

Run: `scripts/test-unit.sh`
Expected: with Task 1 already committed, this test PASSES. To confirm it is a real guard, temporarily revert Task 1's edit locally and observe this test FAIL with `.idle` — then restore. (If Task 1 is already in, a straightforward pass is acceptable; the pure tests in Task 1 already prove the failure mode.)

- [ ] **Step 3: (no new implementation)** This task only adds a regression test over Task 1's change.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-unit.sh`
Expected: the new test PASSES; `ConversationRepinTests` and `SessionStatusTests` remain green.

- [ ] **Step 5: Commit**

```bash
git add Tests/FlightDeckTests/ConversationRepinTests.swift
git commit -m "Test: badge activity follows the newest process for a conversation"
```

---

### Task 3: Defect 1 — reap a live duplicate before resuming an existing conversation

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — add `duplicateResumePids(conversation:in:)` (pure static), `reapResumeDuplicates(_:context:)` (async), and wire a synchronous capture + fire-and-forget reap into `resumeExisting` (around the `insertSession(...)` call, currently ~line 2988).
- Test: `Tests/FlightDeckTests/ReopenDedupeTests.swift` (create; copy the `FakeInspector`/`SpySignals`/`InstantSleeper`/`FakePersistence`/`store(inspector:signals:)` scaffolding from `OrphanSweepTests.swift`).

**Interfaces:**
- Consumes: `registryRows: [UUID?: [pid_t: ClaudeStatusFile.Entry]]` (private, keyed by account), `processInspector.identity(of: pid_t) -> ProcessIdentity?`, `processInspector.pgid(of: pid_t) -> pid_t?`, `reaper.reap(shell: ProcessIdentity, pgid: pid_t?) async -> ReapOutcome`, `reapReporter?.report(_:context:)`, `Session.accountID`, `Session.pinnedConversationID`.
- Produces:
  - `static func duplicateResumePids(conversation: UUID, in rows: [pid_t: ClaudeStatusFile.Entry]) -> [pid_t]` — pids of rows whose `sessionID == conversation`.
  - `func reapResumeDuplicates(_ pids: [pid_t], context: String) async` — resolves each pid to a live `ProcessIdentity` via `processInspector` and reaps it; skips pids with no live identity.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/ReopenDedupeTests.swift`. Copy the private `FakeInspector`, `SpySignals`, `InstantSleeper`, `FakePersistence`, and the `store(inspector:signals:)` helper verbatim from `OrphanSweepTests.swift` (they are `private` there, so duplicate them in this file). Then:

```swift
@MainActor
final class ReopenDedupeTests: XCTestCase {
    /// The pure capture: which live pids are already resuming this conversation.
    func testDuplicateResumePidsPicksEveryRowOnTheConversation() {
        let conversation = UUID()
        let other = UUID()
        let rows: [pid_t: ClaudeStatusFile.Entry] = [
            3404: .init(pid: 3404, sessionID: conversation, activity: .idle, waitingFor: nil,
                        startedAt: 1, cwd: "/w", procStart: "old"),
            77: .init(pid: 77, sessionID: other, activity: .busy, waitingFor: nil,
                      startedAt: 1, cwd: "/w", procStart: "x"),
        ]
        XCTAssertEqual(
            SessionStore.duplicateResumePids(conversation: conversation, in: rows), [3404]
        )
    }

    /// The async reap: a captured, still-live duplicate pid is signalled; the reaper's
    /// identity gate is satisfied via processInspector (NOT the registry row's string time).
    func testReapResumeDuplicatesSignalsTheLiveStaleProcess() async {
        let signals = SpySignals()
        let inspector = FakeInspector(living: [3404])   // isAlive requires procStart == 100
        let store = store(inspector: inspector, signals: signals)

        await store.reapResumeDuplicates([3404], context: "reopen dedupe test")

        XCTAssertTrue(signals.targets.contains(3404),
                      "the stale duplicate process must be reaped")
    }

    /// A pid that is no longer alive is skipped, not signalled (no wrong-process kill).
    func testReapResumeDuplicatesSkipsADeadPid() async {
        let signals = SpySignals()
        let inspector = FakeInspector(living: [])   // nothing alive
        let store = store(inspector: inspector, signals: signals)

        await store.reapResumeDuplicates([3404], context: "reopen dedupe test")

        XCTAssertTrue(signals.targets.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `scripts/test-unit.sh`
Expected: FAIL to compile / resolve — `SessionStore.duplicateResumePids` and `reapResumeDuplicates` do not exist yet.

- [ ] **Step 3: Implement the helper, the reaper, and the wiring**

Add to `SessionStore` (near `reapSession`, ~line 2626):

```swift
    /// Pids of live processes already resuming `conversation`, from one registry read.
    /// Pure so the capture is unit-testable apart from the reap.
    static func duplicateResumePids(
        conversation: UUID, in rows: [pid_t: ClaudeStatusFile.Entry]
    ) -> [pid_t] {
        rows.values.filter { $0.sessionID == conversation }.map(\.pid)
    }

    /// Reap processes that were resuming a conversation we are about to resume again.
    ///
    /// The registry row gives us a pid and a *string* start time; the reaper's liveness
    /// gate needs the OS identity (whole-microsecond `procStart`), so we resolve each pid
    /// through `processInspector` right before signalling. A pid that is no longer alive
    /// resolves to `nil` and is skipped — never signalled — so a recycled pid is not a
    /// wrong-process kill. Mirrors `sweepOrphans`' reap.
    func reapResumeDuplicates(_ pids: [pid_t], context: String) async {
        for pid in pids {
            guard let identity = processInspector.identity(of: pid),
                  processInspector.isAlive(identity) else { continue }
            let livePgid = processInspector.pgid(of: pid)
            let outcome = await reaper.reap(shell: identity, pgid: livePgid)
            reapReporter?.report(outcome, context: context)
        }
    }
```

Then wire the capture + reap into `resumeExisting`, immediately BEFORE the `insertSession(...)` call (~line 2988):

```swift
        // Reap any live process already resuming this conversation before we spawn a fresh
        // `--resume` beside it. A tab whose process was started in restore()'s batch is
        // filed under a random UUID, so closing the tab could not reap it (see reapSession's
        // nil-process path); reopening then duplicates it. Two `claude --resume` on one
        // conversation also both append to one transcript, so this is a correctness fix, not
        // only a cosmetic one. Capture the doomed pids SYNCHRONOUSLY from the pre-spawn
        // registry snapshot — the fresh process has not written its status file yet, so it
        // cannot be in this snapshot and can never be self-reaped — then reap fire-and-forget
        // like closeSession does.
        let doomed = SessionStore.duplicateResumePids(
            conversation: session.pinnedConversationID,
            in: registryRows[session.accountID] ?? [:]
        )
        if !doomed.isEmpty {
            Task { [weak self] in
                await self?.reapResumeDuplicates(doomed, context: "reopen dedupe")
            }
        }

        insertSession(
            session,
            in: URL(fileURLWithPath: projectPath, isDirectory: true),
            initialInput: initialInput,
            at: index
        )
        return deferred && !orphaned
```

Notes for the implementer:
- Confirm `Session` exposes `accountID` with that spelling (seen in persisted state and used elsewhere in `SessionStore`); if the in-memory property differs, use the store's existing accessor for a session's account.
- `duplicateResumePids` is `static` and needs no `self`; `reapResumeDuplicates` is an instance `@MainActor` method (SessionStore is `@MainActor`). The `Task { }` inherits the main actor, matching `closeSession`'s reap dispatch.

- [ ] **Step 4: Run tests to verify they pass**

Run: `scripts/test-unit.sh`
Expected: the three `ReopenDedupeTests` PASS; full suite green (nothing else references the new symbols).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/ReopenDedupeTests.swift
git commit -m "Reap a live duplicate before resuming an existing conversation

Reopen (and openConversation) spawned a second claude --resume without checking
for a process already resuming that conversation — the first was often an
un-reapable restore() orphan. Two claudes on one conversation corrupts the
shared transcript and latches the badge on the stale one. Capture the live
duplicate pids from the pre-spawn registry snapshot (so the fresh process is
never self-reaped) and reap them via the existing reaper."
```

---

### Task 4: Full-suite verification & manual confirmation notes

**Files:** none (verification only).

- [ ] **Step 1: Run the whole unit suite once more**

Run: `scripts/test-unit.sh`
Expected: entire suite green. Confirm the new tests from Tasks 1–3 appear in the output.

- [ ] **Step 2: Record manual-verification steps for the human (do not execute a live swap here)**

The live fix cannot be fully proven by unit tests alone. Note for the human reviewer (per the release ritual — never swap/relaunch from inside a session that runs under Flight Deck):
- After a normal release swap, reproduce: open a claude session, close its tab, ⇧⌘T to reopen, confirm the badge tracks activity (busy/idle/waiting) rather than sticking on idle.
- Confirm `ps aux | rg 'claude --resume <conversation>'` shows a single process after reopen (the stale duplicate is reaped), not two.
- The currently-stuck "Pipeline Optimization" tab has a live orphan (pid 3404). Killing it (`kill 3404`) unsticks the existing tab immediately; the code fix prevents recurrence. This is the human's call to run.

- [ ] **Step 3: Finish the branch** per `superpowers:finishing-a-development-branch`. If executed in a worktree, before merging check `git diff <fork-point> <branch> -- vendor` to ensure no vendor build-symlinks were committed (a known worktree merge hazard), and fast-forward the master ref.

---

## Self-Review

- **Spec coverage:** Defect 2 (badge stuck) → Tasks 1 (pure) + 2 (end-to-end). Defect 1 (duplicate process) → Task 3 (pure capture + async reap + wiring). Verification → Task 4. Both defects from the Background section are covered.
- **Placeholder scan:** Task 2's test intentionally leaves the store/session construction to "mirror this file's existing setup" because that harness is `@MainActor` and file-specific; the implementer must read `ConversationRepinTests.swift`'s setup and the `row/entry` helper before writing it. This is the one spot requiring the implementer to adapt to existing local helpers rather than copy verbatim — flagged explicitly, not a hidden TODO. All code-bearing steps in Tasks 1 and 3 are complete and compile against the verified APIs.
- **Type consistency:** `duplicateResumePids(conversation:in:) -> [pid_t]` and `reapResumeDuplicates(_:context:)` are used with matching names/types in Task 3's tests and wiring. `ConversationPin.resolve` keeps its signature. `Anchor(pid:procStart:)`, `ClaudeStatusFile.Entry` fields, and `reaper.reap(shell:pgid:)` match the sources read during planning.
