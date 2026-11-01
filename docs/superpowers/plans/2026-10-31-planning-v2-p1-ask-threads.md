# Planning v2 P1: Ask Threads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax. **This plan runs in parallel streams.** Task 0 lands alone. Streams A–E then run in separate worktrees at the same time. Task 6, the integration task, lands last.

**Goal:** Select a passage, press ✦ Ask, and get a cited answer from a live agent. Diffs, notes and questions are acted on in the plan. This works from the Mac and the phone.

**Architecture:** A new detached `ThreadRunner` runs per intake. It is the only writer of `threads/`, and each message is one resumed headless turn that returns a `ThreadActions` answer. Anything that has to reach the plan is appended to `commands.jsonl`, which now has a lock, as a command. The app and the phone read thread state and append commands.

**Spec:** [2026-10-31-flight-control-planning-v2-design.md](../specs/2026-10-31-flight-control-planning-v2-design.md), §3, §5, §6, §10 and §11 (thread decisions). Handoff: [HANDOFF-flight-control.md](../../HANDOFF-flight-control.md).

## Rulings on contradictions between the spec and the code

The P1 code map found these. Each ruling binds every task. The spec is updated in Task 6.

| # | The spec assumed | The code has | Ruling | Cost if wrong |
|---|---|---|---|---|
| R1 | Read-only Bash for every adapter | Only codex (`-s read-only`) and gemini can run read commands. Claude allows only `br` reads, grok denies Bash, and opencode is `"*": "deny"`. | A new `HeadlessAccess.threadRead` adds a **read-command allow-list**: `rg`, `git log/show/diff/blame/grep`, `ls`, `cat`, `head`, `wc`, `find`. Claude: `Bash(rg *)`-style allow rules. OpenCode: `permission.bash` patterns. Codex and gemini keep their sandboxes. Grok gets Read/Grep/Glob only, and the thread header says "reads files only". | Grok answers are thinner on repo history |
| R2 | The reply streams | The reply lands only in the final `result` event | During a turn the card and panel show **live activity** from `ActivityParser`, such as "reading §3", "running rg …" or "thinking". The reply text appears when the turn ends. | The first reply text arrives later than the spec promised |
| R3 | The round concurrency cap is reused | Rounds have no cap | ThreadRunner has its own cap: **2 concurrent turns per intake**. It is a constant beside `CapacityPool.concurrencyCap`. | A third thread queues briefly |
| R4 | The runner rebases with `EditLayer.retarget` | `retarget` lives in the app target | Move the pure part into IntakeKit as `PlanRebase.retarget` (Task 0). `EditLayer` calls it. | None. It is a move. |
| R5 | ThreadRunner can share the runner's liveness model | Liveness is tied to `tape.json` | ThreadRunner gets its own `threads/runner.json` heartbeat, `threads-<uuid>.sock` and `threads/cursor` (its last read command seq) | None |
| R6 | Diffs locate "exactly once" with section ids | `locate` picks the best of several matches, and there are no section ids | `ActionValidator` refuses a diff whose quote matches more than once ("ambiguous: quote more context"). Section ids are `s<n>` in outline order, derived per checkpoint. | The agent is retried more often |
| R7 | A wide panel sits beside the plan | The rail lives in `.inspector`, 300–640 pt | The thread panel replaces the rail inside the inspector at up to 640 pt: index 180 pt, conversation the rest. The approved render was 560 pt, so it fits. | A cramped index on a small window |
| R8 | IntakeRunner ignores thread commands | Any unacked command wakes IntakeRunner, and its switch is exhaustive | Thread-only commands go to a **separate file**, `threads/commands.jsonl`, read only by ThreadRunner. Only `applyThreadDiff` and `note` go into the tape's `commands.jsonl`. Both files are appended under the same `flock` helper. | None |
| R9 | The canvas `IntakeThreadInbox` is conformed to in P1 | The canvas is unmerged | P1 ships `ThreadCommand.message` with optional `source`, `messageID`, `elementID` and `subjectRevision`, and ThreadRunner dedupes on `messageID`. The protocol conformance lands in P2b. | None |

## Global Constraints

- **Words:** "tasks", not "beads"; "agent", not "seat"; "Flight Control", not "flywheel". The guard tests stay green.
- **Storage is additive.** New files and optional fields only. Old intakes load unchanged.
- **Wire enum cases are atomic.** Each case lands in one commit with every arm, including `ControlScope`.
- **Every phone op is gated by the `threads` capability flag.**
- **Single writers:**
  - `IntakeRunner`: `tape.json`, `checkpoints/`
  - `ThreadRunner`: `threads/`
  - app and phone: append-only, through the locked append helper.
- **TDD with a real RED for every behaviour change.** The RED and GREEN steps use `FD_TEST_FILTER=<Class>` (one class per run), or the local lane once Stream E lands. The **full** `./scripts/test-unit.sh` and `./scripts/test-ios.sh` run **once**, in Task 6. Never set `FD_TEST_LOCAL=1`. Never launch the app.
- **Hotspot files are touched only in Task 0 and Task 6:** `IntakeService.swift`, `FleetService.swift`, `Frames.swift`, `IntakeDetailView.swift`. Streams add **new files**, such as `IntakeService+Threads.swift`, and fill the stubs Task 0 created.
- **Each stream works in its own worktree:** `.claude/worktrees/p1-<stream>`, branched from Task 0's commit. Symlink the vendor artifacts (including `fd-abduco-artifacts`) and `scripts/local.env`. Commit by path. Never stage `.superpowers/`.

## Review Focus

1. **A round lands mid-turn.** The turn's diff targets the old checkpoint. It must be rebased (R4) or marked stale, never applied as a guess. (Stream A: `testRoundLandingMidTurnMakesDiffStaleOrRebased`)
2. **The same message is delivered twice** (a phone retry, or a canvas redelivery). Exactly one turn runs. (Stream A: `testDuplicateMessageIDRunsOneTurn`)
3. **Two processes append to `commands.jsonl` at the same moment.** No seq is reused and no line is torn. (Stream B: `testConcurrentAppendsFromTwoProcessesNeverReuseSeq`)
4. **The agent proposes a diff whose quote is ambiguous or missing.** It is retried with the error and gives up after 2 tries. It is never applied. (Stream A: `testAmbiguousQuoteIsRetriedThenCouldntApply`)
5. **The app quits mid-turn.** ThreadRunner finishes the turn. On relaunch the panel shows the reply, and no turn runs twice. (Stream A: `testRunnerSurvivesAppAndResumesCursor`)

---

### Task 0: Interfaces only, landed alone

**Files (the only task that touches the hotspots, besides Task 6):**
- Create:
  - `Sources/IntakeKit/Threads/ThreadModel.swift`
  - `Sources/IntakeKit/Threads/ThreadActions.swift`
  - `Sources/IntakeKit/Threads/ThreadCommand.swift`
  - `Sources/IntakeKit/PlanRebase.swift` (R4, moved from `EditLayer`)
  - `Sources/FleetKit/ThreadWire.swift`
  - `Sources/FlightDeck/Intake/IntakeService+Threads.swift` (stubs)
- Modify:
  - `Tape.swift`: `TapeCommand.applyThreadDiff`, with its decode and encode
  - `PlanNote.swift`: optional `source`
  - `TapeKeeper.applyCommands`: the arm, as a stub that throws `notYet`
  - `EditLayer.swift`: calls `PlanRebase`
  - `Frames.swift`: thread ops with all arms
  - `FleetService.swift`: dispatch to stubs that refuse `threads_unavailable`
  - `ControlScope.swift`
  - `IntakeWire.swift`: optional `threads: Bool?`, `WireIntakePlan.threads`, `pendingDiffs`

**Produces (exact names; every stream codes against these):**
```swift
// IntakeKit
public struct ThreadID: Hashable, Codable, Sendable { public var raw: UUID }
public enum ThreadStatus: String, Codable, Sendable { case open, answering, needsYou, stale, resolved }
public struct ThreadAnchor: Codable, Equatable, Sendable { public var note: NoteAnchor?; public var visualID: String?; public var elementID: String? }   // nil note = whole plan
public struct ThreadRecord: Codable, Equatable, Sendable { id, title, anchor, status, agent: AgentID, model: String, effort: String, autoAccept: Bool, sessionID: String?, followsCheckpoint: Int, createdAt: Date }
public struct ThreadTurn: Codable, Equatable, Sendable { seq: Int, messageID: String, you: String?, answers: [StructuredAnswer]?, reply: String?, decision: String?, actions: [ThreadAction], errors: [String], checkpoint: Int, startedAt: Date, endedAt: Date? }
public struct ThreadDiff: Codable, Equatable, Sendable { id: UUID, thread: ThreadID, checkpoint: Int, anchor: NoteAnchor, old: String, new: String, state: DiffState }   // DiffState: pending | accepted | rejected | stale
public enum ThreadAction: Codable, Equatable, Sendable { case proposeDiff(ProposedThreadDiff), addNote(PlanNote), askQuestion(StructuredQuestion) }   // makeVisual/addAlternate arrive in P2a
public enum ThreadActions { public static let schemaJSON: String; public static func decode(_ data: Data) throws -> ThreadAnswer }   // ThreadAnswer{reply, decision, actions}
public enum ThreadCommand: Codable, Equatable, Sendable {   // threads/commands.jsonl (R8)
    case open(ThreadID, ThreadAnchor, title: String, agent: AgentID, model: String, effort: String)
    case message(ThreadID, text: String, messageID: String, source: String?, elementID: String?, subjectRevision: String?)
    case answer(ThreadID, [StructuredAnswer], messageID: String)
    case setAutoAccept(ThreadID, Bool), setAgent(ThreadID, AgentID, model: String, effort: String), resolve(ThreadID), reopen(ThreadID), repropose(ThreadID, diff: UUID)
}
public protocol ThreadStoreReading { func threads() -> [ThreadRecord]; func turns(_ id: ThreadID) -> [ThreadTurn]; func diffs(_ id: ThreadID) -> [ThreadDiff] }
public enum PlanRebase { public static func retarget(markdown: String, typedOn: Int, base: String, head: Int, headPlan: String, runner: …) async -> Retarget }   // signature moved verbatim from EditLayer
// TapeCommand: case applyThreadDiff(thread: ThreadID, diff: UUID, checkpoint: Int, markdown: String)   — the full edited plan, like editPlan
// PlanNote: public var source: NoteSource?   // .thread(ThreadID)
// FleetKit — FleetCommand: intakeThreadSend(id:token:threadID:anchor:text:), intakeThreadGet(id:threadID:since:), intakeThreadResolve(id:token:threadID:), intakeDiffDecide(id:token:threadID:diffID:accept:)
//   WireThreadSummary{id,title,anchor,status,counts,excerpt}, WireThreadTurn, WirePendingDiff{id,thread,checkpoint,quote,old,new,state}
```

- [ ] Write failing round-trip and legacy-decode tests:
  - `ThreadModelCodingTests`;
  - `TapeCommandThreadTests`, including that an old `commands.jsonl` decodes and an old runner drops `applyThreadDiff`;
  - `ThreadWireCodingTests`, including an old-Mac payload with no `threads`;
  - `PlanRebaseTests`, the moved retarget tests, still green.
- [ ] Run `FD_TEST_FILTER` for each class. Expected: compile RED.
- [ ] Implement the types, schema, decoders and stubs. The stubs refuse with `threads_unavailable`, the flag stays off, and nothing runs.
- [ ] Run each class GREEN, then `./scripts/build.sh` and `./scripts/build-ios.sh`.
- [ ] Commit: `feat: the shapes of ask threads, with every op refused until threads ship`.

---

**Streams A–E run in parallel from Task 0's commit. Each owns its files.**

### Stream A: the engine (ThreadRunner, workspace, validator)

**Files:**
- Create:
  - `Sources/IntakeKit/Threads/ThreadRunner.swift`
  - `ThreadStore.swift` (the writer; conforms to `ThreadStoreReading`)
  - `ThreadWorkspace.swift`
  - `ProvenanceIndex.swift`
  - `ActionValidator.swift`
  - `ThreadTurnExecutor.swift`
- Modify:
  - `Headless.swift`: `HeadlessAccess.threadRead` with the R1 per-adapter allow-lists
  - `Sources/FlightDeckTool/main.swift`: the `intake threads <uuid> --root` entry, mirroring `intake run`
- Tests: `ThreadWorkspaceTests`, `ProvenanceIndexTests` (from a scrubbed real checkpoint fixture), `ActionValidatorTests`, `HeadlessThreadReadTests` (argv per adapter), `ThreadRunnerTests` (the fake agent, following `scripts/opencodeprobe/fake_llm.py`), and a `thread.turn` cell in `scripts/test-adapters.sh`.

**Behaviour:**
- **Workspace:** `outline.md` lists `s<n>` ids, headings and sizes. Then `sections/s<n>.md`, `anchor.md` and `intake.md`. `provenance/<cp>.md` collects, for the anchored section: the drafts' positions, the cross-check clusters from `crosscheck.json`, the verdicts from `verdicts.json`, and the consumed notes from `RoundRecord.annotations`, each with a `[cite:<id>]`.
- **First-turn prompt:** the outline, the anchor, its section, and an index of the other files only.
- **Turn:** resume `sessionID`; `threadRead` access; working directory = the repo; the `ThreadActions` schema.
- **Validation:** check each action (R6). A failure goes into the next turn as an error block. After 2 retries, the turn ends in "couldn't apply".
- **Cap:** at most 2 concurrent turns (R3). Turns queue per thread.
- **Dedupe:** by `messageID`.
- **Cursor and heartbeat:** `threads/cursor` and `threads/runner.json` (R5).
- **Exit:** the runner exits when idle, after a late-command recheck, the same pattern as `IntakeRunner.run`.
- **Accepted diff:** the app appends `applyThreadDiff`. ThreadRunner never writes the tape.
- **Auto-accept:** ThreadRunner appends `applyThreadDiff` itself, through the locked helper, always against the newest checkpoint.
- **New round:** the workspace is rebuilt. Pending diffs are rebased with `PlanRebase` or marked `stale`. A divider turn records "Now reading <label>".

**Steps:** each behaviour gets a failing test (RED via `FD_TEST_FILTER`), then its implementation, then GREEN, then a commit. Include all the Review Focus tests for 1, 2, 4 and 5.

### Stream B: commands lock and runner tokens

**Files:**
- Create: `Sources/IntakeKit/LockedAppend.swift` (moved from `OpenCodeMirror.withLockedFile`, which now calls it).
- Modify:
  - `TapeStore.appendCommand`: takes the lock
  - `Fleet/ControlEnvironment.swift`: `intakeRunner(forToken:)`, an HMAC over `"intake-runner:<uuid>"`
  - `ControlScope.swift`: `ControlCaller.intakeRunner(UUID)`, allowed only for its own intake
  - `IntakeRunnerController.swift`: injects `FLIGHT_DECK_CALLER` for both runners
  - `SessionStore.swift:2503`: passes the secret
- Tests:
  - `LockedAppendTests`, which spawns two processes appending 500 lines each and finds 1000 distinct seqs and no torn lines;
  - `RunnerTokenTests`: a tab token never verifies as a runner, and a runner token for intake X is refused for intake Y with `out_of_scope`.

### Stream C: Mac UI

**Files:**
- Create, under `Sources/FlightDeck/Intake/Planning/Threads/`:
  - `AskCard.swift`
  - `ThreadPanel.swift` (index + conversation)
  - `ThreadPanelModel.swift`
  - `DiffGutter.swift` (gutter bar + hover toolbar, D17)
  - `ThreadCitationChip.swift`
- Modify:
  - `SelectionToolbar.swift`: ✦ Ask last, and the Question kind removed from `NoteStyle.kinds`
  - `NotesRail.swift`: Ask cards in the lane, and "Threads (n) ⤢" in the header
  - `PlanTextView.swift`: draws `DiffGutter` for pending diffs
- **Data:** read from a `ThreadStoreReading` fake, and send through the `IntakeService+Threads` API from Task 0, which is stubbed.
- **Tests:**
  - `ThreadPanelModelTests`: the index groups (Open by section / Needs you / Resolved), the stale pill, the auto-accept switch, and the per-intake session memory of the open thread;
  - `DiffGutterRenderTests`: a render, saved via `FD_INTAKE_RENDER_DIR`, that **you look at**.
- **Keys:** ⌘↩ sends, ⌘⇧↩ sends and resolves, ⌘[ and ⌘] move between threads.

### Stream D: phone

**Files:**
- Create:
  - `Sources/FlightDeck/Fleet/IntakeThreadProjection.swift`
  - `Sources/FlightDeck/Intake/IntakeService+PhoneThreads.swift` (fills the Task 0 stubs: `phoneThreadSend` / `Get` / `Resolve`, `phoneDiffDecide`; token-idempotent; `diff_stale`)
  - `Sources/FlightDeckMobile/ThreadScreen.swift`
  - `ThreadOutbox.swift`
  - `PhoneDiffGutter.swift`
- Modify:
  - `PlanReaderScreen.swift`: Ask in the selection menu, and gutter diffs
  - `FleetListScreen.swift`: the "needs you" badge
- **Tests:** `IntakeThreadProjectionTests`, `PhoneThreadCommandTests`, `ThreadOutboxTests`, and a phone render through `RENDER_INTAKE` (temporary scheme env, never committed) that **you look at**.

### Stream E: local logic test lane (the maintainer: "alongside P1")

**Files:**
- `project.yml`: non-hosted `IntakeKitTests` and `FleetKitTests` targets.
- `scripts/test-logic.sh`: runs on THIS Mac with no app host, no windows and no remote lock.
- Move the pure test files into those targets, by `git mv`, starting with IntakeKit model, triage, structured question and tape tests and FleetKit wire tests.
- Docs: `docs/HANDOFF-flight-control.md` §8.1 and `AGENTS.md` "Commands".

**Proof:** `scripts/test-logic.sh` runs the moved tests green with no window, and `FD_TEST_FILTER`/`test-unit.sh` no longer runs them. The total test count across both lanes equals the old count.

---

### Task 6: Integration, last and alone

**Files:**
- Modify:
  - `IntakeService.swift`: start and ensure ThreadRunner, using Stream B's tokens
  - `RoundPrompts.steering`: thread decisions since the last round (spec §11)
  - `TapeKeeper.applyCommands`: the real `applyThreadDiff` arm (`writeUserEdits` + provenance)
  - `IntakeDetailProjection`: `threads: true`
  - remove the stubs
- Also fix the parked P0 items:
  - the Mac `answerDrafts` filters loaded `selected` to option ids;
  - `performPrimary` shows `AnswerRefusal`;
  - the phone resets the sent marker on `onAppear`;
  - the HANDOFF §2.2 nesting and the §4.2 line range.
- **Docs:**
  - HANDOFF-flight-control (§2, §3.8 notes and threads, §4, §7);
  - ARCHITECTURE: the threads section and the single-writer table;
  - FOLLOWUPS: the spec's out-of-scope list;
  - spec: R1–R9 errata;
  - CHECKLIST: the P1 section, unverified.
- **Tests:**
  - an end-to-end test with the fake agent: Ask → reply → accept diff → the next round sees the decision line;
  - **the full** `./scripts/test-unit.sh` and `./scripts/test-ios.sh`;
  - `FD_UITEST_ONLY=… ./scripts/smoke-remote.sh` for one UI flow (Ask → reply → accept);
  - `build.sh` and `build-ios.sh`.

## Verification

Run the full Mac and iOS suites once (Task 6), plus one XCUITest flow on the UI-test Mac, and look at every render. Each stream gets a task review, then there is one final whole-branch review on Opus. Merge with `--ff-only` under `.superpowers/merge.lock`. The GUI checklist stays unverified until the maintainer runs it.
