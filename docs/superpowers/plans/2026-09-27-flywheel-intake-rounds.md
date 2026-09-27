# Flywheel Intake — Round Engine & Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a full plan from scratch work end to end. You pick Sketch, Feature plan or
Full plan. FD runs multi-model drafting, synthesis, refinement, encode and polish rounds in a
detached runner that survives FD quitting. You drive the rounds with transport controls, and
the result lands in the release review that is already built.

**Architecture:**
- **The engine lives in `IntakeKit`:**
  - round configuration and presets;
  - the tape and its planner;
  - prompts and schemas;
  - round execution;
  - the runner loop.

  The `flightdeck` CLI and the tests use the same code.
- **The runner** is `flightdeck intake run <id> --root <intakesRoot>`, running inside its own
  fd-abduco daemon (`-n`, socket `intake-<uuid>.sock`), so it outlives the app.
- **Files are split by writer, so there are no write races:**
  - The **app** owns `intake.json` and appends to `commands.jsonl`.
  - The **runner** owns `tape.json`, `checkpoints/` and `runs/`.
- **The app watches** `tape.json` on the shared `WatchClock`. When the tape reaches release
  review, the app copies the final change set into the intake and moves it to `.review`.

**Tech Stack:** Swift 5 (app), Swift 6 (IntakeKit), SwiftUI, XCTest (`scripts/test-unit.sh`),
xcodegen, fd-abduco, and the CLIs `codex` 0.155.x, `claude` 2.1.x and `br` 0.6.0.

**Spec:** `docs/superpowers/specs/2026-09-26-flywheel-intake-design.md`, phases 5, 6 and 8
of §14. The amendment below applies.

**Builds on:** branch `flywheel-intake` at `62d4c40`, which is phases 1–3 as built. The
previous plan is `docs/superpowers/plans/2026-09-26-flywheel-intake-phase1-3.md`.

### Spec amendment (Nate, 2026-09-27): polish works on the change set, not on `br`

This replaces spec §5.2's "May be materialized before release" and all of §5.3.
- A polish round receives the current change set (plus the plan and the graph) and returns a
  **revised change set**, using the same schema as triage and encode.
- FD validates the revision against the graph and keeps it.
- **Nothing is written to `br` before release, at any fidelity.**
- There is no materialization, no revert check and no un-defer step.
- Polish, fresh-eyes and dedup are all agents that are **read-only** on the repo and on `br`.
- The only write-capable agent is the integrator, and its writable directory is the intake's
  own `work/` directory.

## Global Constraints

- **Swift versions:** the app target stays `SWIFT_VERSION: "5.0"`. IntakeKit stays Swift 6,
  Foundation-only, with every public type `Sendable`.
- **FD is the only `br` writer, and only at release.**
  - Triage, drafting, synthesis, review, encode, polish, fresh-eyes and dedup all run
    read-only:
    - codex: `-s read-only`, or `-c sandbox_mode="read-only"` on resume;
    - claude: `--permission-mode dontAsk` with the read-only allow list and the `br`
      write-verb deny list.
  - The integrator may write **only** in `<intakeDir>/work/`:
    - codex: `-s workspace-write`, with `cwd` = `work/`;
    - claude: `--permission-mode acceptEdits`, `--allowedTools "Read Edit Write"`,
      `--add-dir <work>`, `cwd` = `work/`.
  - It must never be given the project directory as `cwd`.
- **Every headless run passes model and effort explicitly**, including resumes. Claude
  children run with `CLAUDE_CODE_CHILD_SESSION` and `CLAUDECODE` removed.
- **Refinement rounds** use a fresh reviewer session each round, so the reviewer never
  anchors on its own earlier output (methodology). The reviewer slot must be the same model
  every round.
- **Failure policy (spec §6.3):**
  - A failed drafter switches to its fallback slot if one is configured. Otherwise the round
    goes on without it, and the gap is recorded.
  - Any other failed role pauses the tape with a diagnosis. Those roles are never
    substituted silently.
- **Files have one writer each** (so no locks are needed):
  - the app writes `intake.json` and appends to `commands.jsonl`;
  - the runner writes `tape.json`, `checkpoints/**` and `runs/**`.

  Every JSON write is atomic (`.atomic`).
- **Intake storage:** `<root>/<UUID uppercased>/…`, as `IntakeStore.directory(for:)` already
  does. **Runner sockets:** `<SessionDaemon.defaultDirectory()>/intake-<uuid lowercased>.sock`.
  `liveSessionIDs()` ignores that name, so session reconcile never touches it.
- **Release is never a tape target.** The tape stops at release review, and the existing
  release flow takes over unchanged.
- **Tests:** `scripts/test-unit.sh` runs the whole suite (about 8 minutes) and ignores
  `-only-testing:`. Run it in the foreground, at most twice per task (red, then green).
- **Worktree hazards:**
  - Never `git add -A`. Stage explicit paths, and check `git diff --cached --stat -- vendor`
    is empty before every commit.
  - Never `git stash`.
  - Never use qartez mutators.
  - Never launch app bundles from `DerivedData/`.
  - Never run `smoke.sh`.
- **Commits:** lowercase, behavioral, imperative subject. The body covers mechanism and
  evidence. The trailer names the model that actually wrote the commit.

## Review Focus

1. **The runner dies or FD quits in the middle of a round.** Expected: on relaunch the
   runner is restarted, the unfinished round is rerun from the last checkpoint, and no
   checkpoint is half-written or duplicated. *Pinned in Task 8 (`testRestartRerunsUnfinishedRound`,
   `testCheckpointWriteIsAtomic`).*
2. **A model returns output that isn't the schema:** prose, a truncated plan, or an
   integrator that didn't change `plan.md`. Expected: the round fails with an
   `invalidOutput` diagnosis and the tape pauses. It never advances with a corrupt plan.
   *Pinned in Task 7 (`testIntegratorThatDidNotEditPausesWithDiagnosis`,
   `testReviewerProseIsInvalidOutput`).*
3. **You press ⏸ or ⏹ while a round is running.** ⏸ means the round finishes and then the
   tape stops. ⏹ means the child processes are killed, partial output is discarded, and the
   tape stays at the last checkpoint. *Pinned in Task 8 (`testPauseStopsAfterCurrentRound`,
   `testStopKillsChildrenAndDiscards`).*
4. **Every drafter fails**, for example because codex is logged out. Expected: the tape
   pauses with an `authExpired` or `harnessError` diagnosis that names the fix. The tape
   never produces an empty plan. *Pinned in Task 7 (`testAllDraftersFailPausesTape`).*
5. **A runner process is already alive for this intake when FD relaunches.** Expected: FD
   adopts it and does not start a second one (two runners would write the same `tape.json`).
   *Pinned in Task 10 (`testLiveRunnerIsAdoptedNotRespawned`).*

---

## Task 1: IntakeKit process layer

At the moment the only way to run a harness is the app's `HeadlessRunner`, and the only way
to read the graph is the app's `IntakeGraphReader`. The runner, which is a CLI process, needs
both, so their cores move into IntakeKit and the app's types become thin adapters.

**Files:**
- Create: `Sources/IntakeKit/CommandRunner.swift`
- Create: `Sources/IntakeKit/GraphReader.swift`
- Modify: `Sources/FlightDeck/Intake/HeadlessRunner.swift`. `SystemHeadlessRunner` delegates
  to `SystemCommandRunner`, with the environment from `LoginShellPath.repairing(...)`.
- Modify: `Sources/FlightDeck/Intake/IntakeGraphReader.swift`. It delegates to
  `GraphReader`, keeping `CommandFailed` and `String.firstLine` where they are used.
- Test: `Tests/FlightDeckTests/Intake/CommandRunnerTests.swift`

**Interfaces:**
- Produces:
```swift
public struct CommandResult: Sendable { public let stdout: Data; public let stderr: String; public let exitCode: Int32 }
public protocol CommandRunner: Sendable {
    /// `environment` is the COMPLETE child environment (the caller resolves PATH).
    func run(executable: String, arguments: [String], cwd: URL,
             environment: [String: String]) async throws -> CommandResult
}
public struct SystemCommandRunner: CommandRunner { public init() }
public struct GraphReader: Sendable {
    public init(runner: CommandRunner, brPath: String = "br", environment: [String: String])
    public func read(project: String) async throws -> GraphSnapshot
}
public struct GraphReadFailed: Error, Equatable, Sendable { public let command: String; public let exitCode: Int32; public let detail: String }
```
- `SystemCommandRunner` has exactly `SystemHeadlessRunner`'s current behavior:
  - it runs through `/usr/bin/env`;
  - stdin is `/dev/null`;
  - stdout and stderr each drain on a GCD thread;
  - on task cancellation it calls `terminate()` and then throws `CancellationError`;
  - a child killed by any other signal returns `128+sig` with "terminated by signal N" in
    stderr.

  Move the code; don't rewrite it. Also add `processGroup: Bool`, default `false`. When it is
  true, the child is started with `posix_spawnattr_setpgroup(0)` through
  `Process`'s `qualityOfService`/`launch`. If `Process` can't do that, use `posix_spawn`
  directly and report the choice. Task 7 needs it so ⏹ can kill a whole process group.

- [ ] **Step 1: Write the failing tests.** Real processes, cheap:

```swift
import XCTest
import IntakeKit

final class CommandRunnerTests: XCTestCase {
    let env = ["PATH": "/usr/bin:/bin"]
    func testCapturesStdoutStderrAndExitCode() async throws {
        let r = try await SystemCommandRunner().run(executable: "sh", arguments: ["-c", "printf out; printf err >&2; exit 3"],
                                                    cwd: URL(fileURLWithPath: "/tmp"), environment: env)
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "out"); XCTAssertEqual(r.stderr, "err"); XCTAssertEqual(r.exitCode, 3)
    }
    func testEnvironmentIsExactlyWhatWasPassed() async throws {
        let r = try await SystemCommandRunner().run(executable: "sh", arguments: ["-c", "printf \"$FOO|$CLAUDECODE\""],
                                                    cwd: URL(fileURLWithPath: "/tmp"), environment: env.merging(["FOO": "x"]) { $1 })
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "x|")
    }
    func testCancellationThrows() async {
        let t = Task { try await SystemCommandRunner().run(executable: "sleep", arguments: ["30"], cwd: URL(fileURLWithPath: "/tmp"), environment: env) }
        try? await Task.sleep(nanoseconds: 200_000_000); t.cancel()
        do { _ = try await t.value; XCTFail("expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testLargeOutputDoesNotDeadlock() async throws {
        let r = try await SystemCommandRunner().run(executable: "sh", arguments: ["-c", "head -c 2000000 /dev/zero | tr '\\0' a"],
                                                    cwd: URL(fileURLWithPath: "/tmp"), environment: env)
        XCTAssertEqual(r.stdout.count, 2_000_000)
    }
}
```
  Also add a `GraphReader` test with a fake `CommandRunner` that returns the fixtures
  `br-list-all.json` and `br-graph-all.json`. They already exist in
  `Tests/FlightDeckTests/Fixtures/Intake/`. Assert on the decoded snapshot.
- [ ] **Step 2: Run the suite and confirm it fails.** Expected: `SystemCommandRunner` is not in
  scope.
- [ ] **Step 3: Implement.** Move the process code out of
  `Sources/FlightDeck/Intake/HeadlessRunner.swift` into `SystemCommandRunner`. The app's
  `SystemHeadlessRunner.run` becomes a call to
  `SystemCommandRunner().run(executable:arguments:cwd:environment:)`, with `environment` =
  `LoginShellPath.repairing(ProcessInfo.processInfo.environment)` minus
  `command.unsetEnvironment`. `GraphReader.read` runs `br list --all --json` and then
  `br graph --all --json` with `cwd` = project, throws `GraphReadFailed` on a non-zero exit,
  and returns `GraphSnapshot.decode(list:graph:)`. The app's `IntakeGraphReader.read` maps
  `GraphReadFailed` to its existing `CommandFailed`.
- [ ] **Step 4: Run the suite and confirm it passes.** All existing `IntakeServiceTests` and
  `HeadlessRunner` tests must be unchanged and green.
- [ ] **Step 5: Commit.** `refactor: move the intake process runner and graph reader into IntakeKit`

## Task 2: Round configuration and presets

**Files:**
- Create: `Sources/IntakeKit/RoundConfig.swift`
- Modify: `Sources/IntakeKit/Intake.swift`:
  - new fields `chosenPreset: Preset?` and `roundConfig: RoundConfig?`, both read with
    `decodeIfPresent` and omitted when nil;
  - a new state `.shaping`.
- Test: `Tests/FlightDeckTests/Intake/RoundConfigTests.swift`

**Interfaces:**
- Produces:
```swift
public enum DrafterPersona: String, Codable, Sendable, CaseIterable { case general, arbiter, realist, coverage, stressTest }
public struct ModelChoice: Codable, Equatable, Sendable {
    public var harness: Harness; public var model: String; public var effort: String
    public init(harness: Harness, model: String, effort: String)
}
public struct Slot: Codable, Equatable, Sendable {
    public var choice: ModelChoice; public var persona: DrafterPersona; public var fallback: ModelChoice?
    public init(_ choice: ModelChoice, persona: DrafterPersona = .general, fallback: ModelChoice? = nil)
}
public enum PlayMode: String, Codable, Sendable { case step, nextMajor, toReview }
public struct RoundConfig: Codable, Equatable, Sendable {
    public var drafters: [Slot]          // ≥1
    public var synthesizer: Slot?        // nil when drafters.count == 1
    public var reviewer: Slot?           // nil ⇒ no refinement stage
    public var integrator: ModelChoice
    public var encoder: ModelChoice
    public var polisher: ModelChoice?    // nil ⇒ no polish stage
    public var refinementCap: Int
    public var polishCap: Int
    public var freshEyesAndDedup: Bool
    public var defaultPlay: PlayMode
    public var customized: Bool
}
public struct AvailableModels: Sendable, Equatable {
    public var codex: ModelChoice?   // nil when codex isn't installed
    public var claude: ModelChoice?
    public init(codex: ModelChoice?, claude: ModelChoice?)
    /// codex gpt-6-sol/high and claude opus/high when both are present.
    public static let defaults: AvailableModels
}
public enum PresetExpansion {
    /// nil for `.bead` — Bead has no shaping stages.
    public static func config(for preset: Preset, available: AvailableModels) -> RoundConfig?
}
```
- **Expansion rules.** "A" is the first available model, codex if present, else claude. "B"
  is the other one if present, else A.

  | Preset | Drafters | Synthesizer | Reviewer | Refinement cap | Polisher | Polish cap | Fresh-eyes + dedup | Default play |
  |---|---|---|---|---|---|---|---|---|
  | Sketch | `[A(.general, fallback B)]` | nil | A | 2 | nil | 0 | false | `.toReview` |
  | Feature plan | `[A(.arbiter, fallback B), B(.realist, fallback A)]` | A (.arbiter) | A | 3 | claude if present, else A | 2 | false | `.nextMajor` |
  | Full plan | `[A(.arbiter), B(.realist), A(.coverage), B(.stressTest)]`, each with the other model as fallback | A (.arbiter) | A | 5 | claude if present, else A | 6 | true | `.nextMajor` |

  For every preset, `integrator` = claude if present, else A, and `encoder` = A.
  `customized` starts false.

  Why the polisher defaults to claude: the methodology polishes with Claude Opus. The
  arbiter is always drafter 0, and synthesis edits drafter 0's draft.

- [ ] **Step 1: Write the failing tests.** Cover the table above for each preset:
  - both models present, codex only, and claude only;
  - `.bead` gives nil;
  - the drafter count per preset;
  - Full plan's four personas in order;
  - fallbacks set to the other model when both exist, and nil when only one exists;
  - JSON round-trip.

  Also: an `Intake` saved **before** this change (a JSON fixture with no
  `chosenPreset`/`roundConfig`) still decodes, and a `.shaping` intake round-trips.

```swift
func testFullPlanPersonasAndFallbacks() throws {
    let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
    XCTAssertEqual(cfg.drafters.map(\.persona), [.arbiter, .realist, .coverage, .stressTest])
    XCTAssertEqual(cfg.drafters.map(\.choice.harness), [.codex, .claude, .codex, .claude])
    XCTAssertEqual(cfg.drafters[0].fallback?.harness, .claude)
    XCTAssertEqual(cfg.refinementCap, 5); XCTAssertEqual(cfg.polishCap, 6); XCTAssertTrue(cfg.freshEyesAndDedup)
    XCTAssertEqual(cfg.polisher?.harness, .claude); XCTAssertEqual(cfg.integrator.harness, .claude)
}
func testSketchSingleModelHasNoFallback() throws {
    let cfg = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: AvailableModels(codex: nil, claude: .init(harness: .claude, model: "opus", effort: "high"))))
    XCTAssertEqual(cfg.drafters.count, 1); XCTAssertNil(cfg.drafters[0].fallback); XCTAssertNil(cfg.synthesizer)
    XCTAssertNil(cfg.polisher); XCTAssertEqual(cfg.defaultPlay, .toReview)
}
```
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.** Add `.shaping` to `IntakeState`. `needsAttention` stays false
  for `.shaping`, because the tape's own status drives attention (Task 11). Keep `Intake`'s
  custom `Codable` backward compatible.
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: expand fidelity presets into editable round configurations`

## Task 3: The tape, its planner and its store

**Files:**
- Create: `Sources/IntakeKit/Tape.swift` (the model)
- Create: `Sources/IntakeKit/TapePlanner.swift`
- Create: `Sources/IntakeKit/TapeStore.swift`
- Test: `Tests/FlightDeckTests/Intake/TapePlannerTests.swift` and `TapeStoreTests.swift`

**Interfaces:**
- Produces:
```swift
public enum Stage: String, Codable, Sendable { case draft, synthesis, refine, encode, polish, freshEyes, dedup }
public struct VerdictTally: Codable, Equatable, Sendable { public var agree: Int; public var somewhat: Int; public var disagree: Int }
public enum DiagnosisCategory: String, Codable, Sendable { case rateLimited, authExpired, timeout, harnessError, invalidOutput }
public struct Diagnosis: Codable, Equatable, Sendable { public var category: DiagnosisCategory; public var detail: String; public var action: String }
public enum SlotStatus: String, Codable, Sendable { case ok, substituted, failed }
public struct SlotOutcome: Codable, Equatable, Sendable {
    public var role: String            // "drafter", "synthesizer", "reviewer", "integrator", "encoder", "polisher"
    public var persona: DrafterPersona?
    public var used: ModelChoice; public var requested: ModelChoice
    public var status: SlotStatus; public var diagnosis: Diagnosis?; public var sessionID: String?
}
public struct RoundRecord: Codable, Equatable, Sendable {
    public var slots: [SlotOutcome]
    public var changeCount: Int?        // proposed changes (review/synthesis) or ops changed (polish)
    public var linesAdded: Int; public var linesRemoved: Int
    public var sectionsChanged: [String]
    public var tally: VerdictTally?
    public var annotations: [String]    // consumed by this round
    public var note: String?
}
public struct Checkpoint: Codable, Equatable, Sendable, Identifiable {
    public var id: Int; public var parent: Int?; public var stage: Stage; public var round: Int
    public var major: Bool; public var createdAt: Date; public var record: RoundRecord
}
public enum TapeTarget: String, Codable, Sendable { case none, nextMinor, nextMajor, review }
public enum RunnerStatus: String, Codable, Sendable { case idle, running, paused, failed, reachedReview, stopped }
public struct Tape: Codable, Equatable, Sendable {
    public var checkpoints: [Checkpoint]
    public var target: TapeTarget
    public var status: RunnerStatus
    public var pauseDiagnosis: Diagnosis?
    public var ackedCommandSeq: Int
    public var extraRefinement: Int; public var extraPolish: Int
    public var pendingAnnotations: [String]
    public var runnerPID: Int32?; public var heartbeat: Date?
    public var roundInProgress: PlannedRound?
    public static let empty: Tape
    public var head: Checkpoint? { checkpoints.last }   // linear this plan; branches later
}
public struct PlannedRound: Codable, Equatable, Sendable { public var stage: Stage; public var round: Int; public var major: Bool }
public enum TapeCommand: Codable, Equatable, Sendable {
    case step, nextMajor, toReview, pause, stop, annotate(String), extend(Stage, by: Int)
}
public struct CommandEnvelope: Codable, Equatable, Sendable { public var seq: Int; public var command: TapeCommand }
public enum TapePlanner {
    /// The next round to run given what exists, or nil when the tape has reached release review.
    public static func next(after tape: Tape, config: RoundConfig) -> PlannedRound?
    /// Whether stopping right after `checkpoint` satisfies `target`.
    public static func satisfies(_ target: TapeTarget, after checkpoint: Checkpoint, nextRound: PlannedRound?) -> Bool
    /// Fold one command into the tape (target / pause / extend / annotations). `.stop` is handled by the runner.
    public static func apply(_ c: TapeCommand, to tape: inout Tape)
}
public struct TapeStore: Sendable {
    public init(intakeDirectory: URL)
    public var tapeURL: URL { get }; public var commandsURL: URL { get }
    public func checkpointDirectory(_ id: Int) -> URL
    public func workDirectory() -> URL
    public func runDirectory(_ name: String) -> URL
    public func loadTape() -> Tape                       // .empty when absent/corrupt
    public func saveTape(_ t: Tape) throws               // atomic
    public func appendCommand(_ c: TapeCommand) throws -> Int   // app side; returns seq (max existing + 1)
    public func commands(after seq: Int) -> [CommandEnvelope]  // runner side; skips a torn last line
    public func writeCheckpoint(_ cp: Checkpoint, files: [String: Data], into tape: inout Tape) throws
}
```
- **Planner sequence:**
  1. Draft (round 0, major).
  2. Synthesis (major), only if `synthesizer != nil`.
  3. Refine, rounds 1…(`refinementCap` + `extraRefinement`). Only the last refine round is
     major. The stage is skipped entirely when `reviewer == nil` or the cap total is 0.
  4. Encode (major).
  5. Polish, rounds 1…(`polishCap` + `extraPolish`). Only the last is major. Skipped when
     `polisher == nil` or the total is 0.
  6. If `freshEyesAndDedup`: freshEyes (minor), then dedup (major).
  7. Then nil, which means release review.
- **`satisfies`:**
  - `.nextMinor` is satisfied after any checkpoint.
  - `.nextMajor` is satisfied after a major checkpoint.
  - `.review` is satisfied only when `nextRound == nil`.
  - `.none` is always satisfied (nothing to run).
- **`apply`:**
  - `.step`, `.nextMajor` and `.toReview` set `target` to `.nextMinor`, `.nextMajor` and
    `.review`, and clear `.paused`/`.stopped`/`.failed` back to `.idle`.
  - `.pause` sets `target = .none` (the runner finishes the round in progress, then stops).
  - `.annotate(s)` appends `s` to `pendingAnnotations`.
  - `.extend(.refine, n)` adds to `extraRefinement`, and `.extend(.polish, n)` adds to
    `extraPolish`. Other stages are ignored.
- **`writeCheckpoint`** writes the files into `checkpoints/<id>/` first. Only then does it
  append the checkpoint to the tape and save the tape atomically. A crash between those two
  steps leaves an orphan directory that `loadTape` ignores, never a checkpoint with missing
  files.

- [ ] **Step 1: Write the failing tests.**
  - **TapePlannerTests** — a table of full sequences:
    - Sketch: draft, refine1, refine2(major), encode(major), nil.
    - Feature plan: draft, synth, r1, r2, r3(major), encode, p1, p2(major), nil.
    - Full plan: …, p6(major), freshEyes, dedup(major), nil.
    - `extraRefinement = 1` turns r3 minor and adds a major r4.
    - `satisfies` for each target.
    - `apply` for each command.
  - **TapeStoreTests:**
    - save then load round-trips;
    - a corrupt `tape.json` loads as `.empty`;
    - `appendCommand` assigns seq 1, 2, …;
    - `commands(after: 1)` returns seq 2 onward;
    - a torn final line (no trailing newline, invalid JSON) is skipped and not fatal;
    - `testCheckpointWriteIsAtomic`: files are written before the tape changes, and an orphan
      `checkpoints/7/` with no tape entry is ignored.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.** Every type is Codable with synthesized conformance, except
  `TapeCommand`, which uses a `{"kind": …, "text"?: …, "stage"?: …, "by"?: …}` shape.
  `commands.jsonl` holds one `CommandEnvelope` per line.
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: model the intake tape, its round planner and its on-disk store`

## Task 4: Round prompts and schemas

**Files:**
- Create: `Sources/IntakeKit/RoundPrompts.swift`
- Modify: `Sources/IntakeKit/Triage.swift`. Expose the op schema fragment as
  `public static let changeSetSchemaFragment: String` (the `changeSet` object), so encode and
  polish reuse it exactly. `Triage.schemaJSON` is built from it and stays byte-identical.
- Test: `Tests/FlightDeckTests/Intake/RoundPromptsTests.swift`

**Interfaces:**
- Produces:
```swift
public struct DraftOutput: Codable, Sendable { public var plan: String }
public struct ProposedChange: Codable, Equatable, Sendable { public var section: String; public var rationale: String; public var edit: String }
public struct ReviewOutput: Codable, Sendable { public var changes: [ProposedChange]; public var summary: String }
public struct IntegrateOutput: Codable, Sendable { public var agree: Int; public var somewhat: Int; public var disagree: Int; public var notes: String }
public struct ChangeSetOutput: Codable, Sendable { public var changeSet: ChangeSet; public var summary: String }
public enum RoundSchemas {
    public static let draft: String       // {"plan": string}
    public static let review: String      // {"changes":[{section,rationale,edit}], "summary"}
    public static let integrate: String   // {"agree","somewhat","disagree": integer, "notes": string}
    public static let changeSet: String   // {"changeSet": <Triage.changeSetSchemaFragment>, "summary": string}
}
public struct RoundContext: Sendable {
    public var intent: String; public var qa: [TriageExchange]
    public var graphFile: String; public var agentsFile: String?; public var readmeFile: String?
    public var annotations: [String]; public var observedAt: Date
    public init(intent: String, qa: [TriageExchange], graphFile: String, agentsFile: String?,
                readmeFile: String?, annotations: [String], observedAt: Date)
}
public enum RoundPrompts {
    public static func draft(_ c: RoundContext, persona: DrafterPersona) -> String
    public static func synthesis(_ c: RoundContext, ownDraft: String, otherDrafts: [String]) -> String   // file paths
    public static func review(_ c: RoundContext, planFile: String, round: Int) -> String
    public static func integrate(planFile: String, changesFile: String) -> String
    public static func encode(_ c: RoundContext, planFile: String) -> String
    public static func polish(_ c: RoundContext, planFile: String, changeSetFile: String, round: Int) -> String
    public static func freshEyes(_ c: RoundContext, planFile: String, changeSetFile: String) -> String
    public static func dedup(_ c: RoundContext, changeSetFile: String) -> String
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T   // IntakeJSON.decoder; throws Triage.Malformed-style error
}
```
- **All schemas are strict:** every object has `additionalProperties: false`, and every key
  is `required`. Build them with the same helpers `Triage` uses.
- **What each prompt must say.** Adapt the methodology's prompts; each prompt is plain words.
  - **Draft:**
    - the role, and "write a complete, detailed, granular markdown plan";
    - the intent;
    - the Q&A transcript, if any;
    - the input files by path, with the graph shape explained the same way the triage prompt
      does;
    - the persona's lens:
      - arbiter: global coherence;
      - realist: implementability and sequencing;
      - coverage: every feature, edge case and workflow;
      - stressTest: challenge every assumption;
    - read-only; return only `{"plan": …}`.
  - **Synthesis:** "I asked competing models to do the same thing; be intellectually honest
    about what they did better than your plan", followed by the draft paths. Return the edits
    to *your own* draft (`ownDraft`) as `changes[]`, each with section, rationale, and `edit`
    written as a git-diff-style hunk or exact replacement instructions.
  - **Review (round N):** "Carefully review this entire plan and come up with your best
    revisions … I am positive you missed or got wrong at least 40 elements" (the overshoot
    phrasing). Also the annotations, prefixed "The human steering this plan says:".
    Return `changes[]` and a `summary`.
  - **Integrate:** "Integrate these revisions into `<planFile>` in place; be meticulous; edit
    only that file". Then report counts for the changes you wholeheartedly agree with,
    somewhat agree with, and disagree with (the ones you disagreed with are not applied), and
    return `{agree, somewhat, disagree, notes}`.
  - **Encode:** the triage prompt's change-set rules, verbatim from `Triage` (per-op required
    fields, `new:` refs, `from` depends on `to`, `pre` copied exactly, ratings, followUp,
    dedup against open and closed beads). Plus: "turn ALL of the plan into a comprehensive
    and granular set of beads … each self-contained and self-documenting … include unit and
    e2e test obligations … never lose a feature". Return `{changeSet, summary}`.
    `graphObservedAt` must be exactly `observedAt`'s ISO string.
  - **Polish (round N):** "Reread AGENTS.md. Check over each proposed bead super carefully:
    does it make sense, is it optimal, could it be better? Revise it. DO NOT OVERSIMPLIFY.
    DO NOT LOSE FEATURES. Merge duplicates, fill empty descriptions, fix dependencies,
    cross-check every bead against the plan." Return the **complete revised** change set
    (not a diff), under the same rules as encode. Existing-bead ops (`editBead`, `reopen`,
    `followUp`) may be revised but must keep `pre` exactly.
  - **Fresh-eyes:** the same shape as polish, framed as a first-time reviewer who reads the
    plan and the beads fresh.
  - **Dedup:** "Check over ALL proposed beads; none may be duplicative or excessively
    overlapping; merge into canonical beads, keeping the richer tests and dependencies."
    Return the complete revised change set.

- [ ] **Step 1: Write the failing tests.**
  - Each schema parses as JSON and is strict: `additionalProperties == false` at every
    object level, and `required` equals the key set. Assert it by walking the schema.
  - `RoundSchemas.changeSet` embeds `Triage.changeSetSchemaFragment`, and `Triage.schemaJSON`
    is unchanged. Compare it to a stored copy taken **before** the refactor:
    `Tests/FlightDeckTests/Fixtures/Intake/triage-schema.json`.
  - Each prompt contains its input paths, the annotations (review), the persona lens (draft),
    the overshoot phrase (review), "DO NOT OVERSIMPLIFY" (polish), the observedAt string
    (encode and polish), and "edit only that file" (integrate).
  - `decode` rejects prose and accepts a valid object.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Live schema probe.** Run once; it costs cents. From a scratch directory
  outside the repo, run codex (`gpt-5.6-luna`, low) and claude (`haiku`) once each against
  `RoundSchemas.review` and `RoundSchemas.changeSet`, with a tiny prompt ("return one
  change" / "return an empty changeSet"). Both must exit 0 and decode. If strict mode rejects
  a schema, fix the schema. Save the four outputs as fixtures
  `round-{review,changeset}-{codex,claude}-live.*` with a decode test.
- [ ] **Step 6: Commit.** `feat: define the round prompts and their strict output schemas`

## Task 5: Integrator commands and failure diagnosis

**Files:**
- Modify: `Sources/IntakeKit/Harness.swift`
- Create: `Sources/IntakeKit/FailureDiagnosis.swift`
- Test: `Tests/FlightDeckTests/Intake/HarnessWriteModeTests.swift` and
  `FailureDiagnosisTests.swift`

**Interfaces:**
- Produces:
  - `HarnessRequest.access: HarnessAccess`, with a default of `.readOnly` so existing callers
    are unchanged.
  - `public enum HarnessAccess: Sendable, Equatable { case readOnly; case writeInWork(URL) }`.
  - `HarnessCommand.build` with `.writeInWork(dir)`:
    - codex fresh: identical except `-s workspace-write` instead of `-s read-only`. `cwd`
      must be `dir`; the caller sets it. Assert `request.cwd == dir` with a
      `precondition`, because a write sandbox rooted anywhere else is a bug.
    - claude: `--permission-mode acceptEdits --allowedTools "Read Edit Write"`, no
      `--disallowedTools`, and `--add-dir <dir>`.
    - resume is not supported for write mode: the integrator always starts fresh.
  - `public enum FailureDiagnosis { static func classify(exitCode: Int32, stdout: Data, stderr: String, parseError: Error?) -> Diagnosis }`.
    Rules are checked in order and are case-insensitive:

    | Category | Matched when | Action text |
    |---|---|---|
    | `rateLimited` | "rate limit", "429" or "usage limit" | "Wait for the limit to reset, or switch this slot to another model." |
    | `authExpired` | "not logged in", "authentication", "unauthorized", "401", "please run `claude /login`" or "`codex login`" | the exact login command for the harness |
    | `timeout` | exit code 124, or stderr "timed out" | "Retry the round." |
    | `invalidOutput` | exit 0 but `parseError != nil` | "The model returned something other than the schema — retry, or switch this slot's model." |
    | `harnessError` | anything else | the last 3 lines of stderr, plus "Retry, or change this slot." |

- [ ] **Step 1: Write the failing tests.**
  - The exact argv for the codex and claude write modes.
  - The `precondition` fires when `cwd != dir`, tested through a pure helper
    `HarnessCommand.validate(_:)` that returns an error rather than trapping.
  - One classification test per rule, using realistic stderr strings.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: let the integrator write only in the intake work dir and classify harness failures`

## Task 6: Plan metrics

**Files:**
- Create: `Sources/IntakeKit/PlanMetrics.swift`
- Test: `Tests/FlightDeckTests/Intake/PlanMetricsTests.swift`

**Interfaces:**
- Produces:
```swift
public struct PlanDelta: Equatable, Sendable { public var added: Int; public var removed: Int; public var sectionsChanged: [String] }
public enum PlanMetrics {
    /// Line-level diff (LCS over lines) — counts, plus the markdown headings (#…) whose section bodies changed, in document order.
    public static func delta(from old: String, to new: String) -> PlanDelta
    /// Unified-diff text for the plan viewer (3 lines of context).
    public static func unifiedDiff(from old: String, to new: String) -> String
    /// Ops changed between two change sets (added + removed + modified, matched by tempId / existing id).
    public static func opsChanged(from old: ChangeSet, to new: ChangeSet) -> Int
}
```
- Keep it O(n·m) in memory for plans up to about 6k lines. Use Hunt–Szymanski or a banded
  LCS if the plain approach is too slow: the test with 6,000 lines must finish in under 2
  seconds.

- [ ] **Step 1: Write the failing tests.**
  - `delta` counts added and removed lines exactly on a small example.
  - `sectionsChanged` names the headings whose bodies changed, and a heading renamed with an
    unchanged body counts as a change.
  - `unifiedDiff` output matches an expected string.
  - `opsChanged` for one added op, one removed op and one modified op gives 3.
  - Performance: two 6,000-line plans differing in 200 lines finish in under 2 seconds
    (`measure` isn't needed; assert on the clock).
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: measure how much a plan or change set changed per round`

## Task 7: Round executor

**Files:**
- Create: `Sources/IntakeKit/RoundExecutor.swift`
- Test: `Tests/FlightDeckTests/Intake/RoundExecutorTests.swift`, using a scripted fake
  `CommandRunner` keyed by role that returns codex- or claude-shaped outputs.

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces:
```swift
public struct RoundInputs: Sendable {
    public var intake: Intake; public var config: RoundConfig; public var tape: Tape
    public var store: TapeStore; public var project: URL; public var environment: [String: String]
    public var now: @Sendable () -> Date
}
public enum RoundResult: Sendable {
    case checkpoint(Checkpoint, files: [String: Data])   // files keyed by relative path inside checkpoints/<id>/
    case paused(Diagnosis, partialRecord: RoundRecord)
}
public struct RoundExecutor: Sendable {
    public init(runner: CommandRunner, graphReader: GraphReader)
    public func run(_ planned: PlannedRound, _ inputs: RoundInputs) async throws -> RoundResult   // throws CancellationError on ⏹
}
```
- **Files each stage writes** (relative paths inside the checkpoint):
  - draft: `drafts/<i>.md` for each successful drafter;
  - synthesis and refine: `plan.md`;
  - encode, polish, freshEyes and dedup: `changeset.json`, plus a copy of `plan.md`, so any
    checkpoint is self-contained for the viewer.
- **Where the current plan and change set come from.** The *current plan* is the latest
  checkpoint's `plan.md`, or, when there is no synthesis (Sketch), `drafts/0.md` of the draft
  checkpoint. The *current change set* is the latest `changeset.json`.
- **Run layout.** Every harness run gets `runs/<stage>-<round>-<role>[-<i>]/`, containing:
  - `stdout`, `stderr`;
  - `run.json`: `{pid, sessionID?, started, finished?, exitCode?}`, written before the
    process starts and updated when it ends.

  Children run with `processGroup: true`.
- **Stage behavior:**
  - **draft:** every drafter runs concurrently (`withThrowingTaskGroup`), read-only, with
    schema `draft`. On failure, try `fallback` once, recorded as `.substituted`. If that fails
    too, record `.failed` with its diagnosis and continue. If **every** drafter failed, return
    `.paused(diagnosis of drafter 0)`. The draft checkpoint needs at least one draft.
  - **synthesis:**
    1. Run the synthesizer, read-only, with schema `review`.
    2. Write the changes to `work/changes.json`, and copy drafter 0's draft to `work/plan.md`.
    3. Run the integrator with `writeInWork(work)`, schema `integrate`.
    4. Verify that `work/plan.md` changed, unless zero changes were agreed.
    5. Compute the delta against drafter 0's draft.
  - **refine:** the same as synthesis, except the reviewer runs in a **fresh session**, with
    `review(planFile:)` and the pending annotations, and the plan is the current plan. The
    record's `annotations` = the pending annotations this round consumed.
  - **encode:**
    1. Read the graph fresh with `GraphReader`, and write `work/graph.json`.
    2. Run the encoder with schema `changeSet`.
    3. Overwrite `graphObservedAt` with `now()`.
    4. Validate against the graph. On failure, send one correction turn by **resuming** the
       encoder session with `Triage.correctionPrompt`. A second failure returns
       `.paused(invalidOutput …)` with the errors listed.
  - **polish, freshEyes and dedup:** the current change set goes in `work/changeset.json`.
    The polisher returns a full revised change set, with the same observedAt overwrite, the
    same validation and the same single correction turn. The record's `changeCount` =
    `PlanMetrics.opsChanged`.
  - **Failure in any non-drafter role:** return `.paused(diagnosis)`. No substitution.
  - **Integrator safety:** if the integrator exits 0 but `work/plan.md` is byte-identical
    while `agree + somewhat > 0`, return `.paused(invalidOutput, "integrator reported
    changes but did not edit the plan")`.

- [ ] **Step 1: Write the failing tests** with the fake runner:
  - `testDraftRoundWritesEachDraft`
  - `testDrafterFallsBackOnce` (drafter 0 fails with 401 and the fallback succeeds; status
    `.substituted`)
  - `testAllDraftersFailPausesTape` (authExpired diagnosis)
  - `testSynthesisAppliesViaIntegratorAndCountsDelta` (the fake integrator really edits
    `work/plan.md`)
  - `testIntegratorThatDidNotEditPausesWithDiagnosis`
  - `testReviewerProseIsInvalidOutput`
  - `testRefineUsesFreshSessionEachRound` (argv never contains `resume`)
  - `testRefineConsumesAnnotations`
  - `testEncodeValidatesAndRetriesOnce`
  - `testEncodeSecondFailurePauses`
  - `testPolishKeepsExistingOpPreconditionsOrFails`
  - `testSketchCurrentPlanIsDraftZero`
  - `testEveryRunHasRunJSONWithPid`
  - `testCancellationKillsChildren`: a real `sleep 30` child through `SystemCommandRunner`
    with `processGroup: true`. Cancel, then assert with `kill(pid, 0)` that the pid is gone
    within 1 second.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: execute draft, synthesis, refine, encode and polish rounds`

## Task 7b: A shadow graph so polishers can run `bv` on the proposed beads

Nate asked what polishing a change set loses compared with materializing in `br`. The answer
is `bv`'s computed graph analytics over the proposed beads: bottlenecks, critical path, the
width of the ready set, and cycle and chain insights. Those matter most when polishing a large
plan for swarm throughput. This task recovers them without touching the real bead database.

**Files:**
- Create: `Sources/IntakeKit/ShadowGraph.swift`
- Modify: `Sources/IntakeKit/RoundExecutor.swift` (polish, freshEyes and dedup)
- Modify: `Sources/IntakeKit/Harness.swift` (an extra allowed tool for claude polishers)
- Modify: `Sources/IntakeKit/RoundPrompts.swift` (polish prompts mention the shadow `bv`)
- Test: `Tests/FlightDeckTests/Intake/ShadowGraphTests.swift`

**Interfaces:**
- Produces:
```swift
public struct ShadowGraph: Sendable {
    public init(runner: CommandRunner, brPath: String = "br", environment: [String: String])
    /// Copy <project>/.beads to <dir>/.beads (replacing any previous copy), then apply the change set's
    /// creates and new→* / held edges to THAT copy with `br --db <dir>/.beads/beads.db …`. Existing-bead
    /// edits are applied too so metrics reflect them. Returns the shadow `.beads` path.
    public func build(project: URL, changeSet: ChangeSet, in dir: URL) async throws -> URL
}
```
- Every `br` invocation passes `--db <dir>/.beads/beads.db` explicitly. The shadow directory
  is `work/shadow/` under the intake. **Never** use `cwd` = project for these commands,
  because `br` auto-discovers `.beads` from `cwd`.
- **Polish rounds** build the shadow first. If building it fails, the round still runs
  without the `bv` guidance, and the record notes it. The shadow is an aid, not a gate.
- **Tool access:**
  - codex polishers: nothing changes (read-only sandbox, `bv` runnable).
  - claude polishers: add `Bash(bv --db <shadowPath> *)` to the allowed tools.
- **The prompt** says: "`bv --db <shadowPath> --robot-insights` / `--robot-plan` /
  `--robot-priority` analyse the graph AS IF your current change set were applied: use them
  to find bottlenecks, long serial chains, and narrow ready fronts, and restructure
  dependencies for parallel work where it doesn't lose correctness."

- [ ] **Step 1: Write the failing tests.** A **real `br`** test, skipped when `br` isn't on
  PATH, in a scratch repo under `$HOME`:
  - `br init`, plus 2 beads with an edge;
  - build a shadow with a change set that creates 2 beads and 1 held edge;
  - assert that `br --db <shadow> list --all --json` shows 4 beads and the held edge;
  - assert that `br list` in the **real** repo still shows 2 beads (the real graph is
    untouched);
  - rebuilding replaces the old shadow.

  Also a fake-runner test: every argv contains `--db` pointing inside `dir`, and none runs
  with `cwd` = project.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.** Reuse `ApplyPlanner.plan` to order the shadow writes. Only
  `create`, `depend` and `update` steps apply; rechecks are skipped for the shadow.
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: let polishers analyse proposed beads with bv on a shadow graph`

## Task 8: The runner loop

**Files:**
- Create: `Sources/IntakeKit/IntakeRunner.swift`
- Test: `Tests/FlightDeckTests/Intake/IntakeRunnerTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3 and 7, plus `IntakeStore`.
- Produces:
```swift
public struct IntakeRunner: Sendable {
    public init(root: URL, intakeID: UUID, executor: RoundExecutor, environment: [String: String],
                pollInterval: Duration = .seconds(1), now: @escaping @Sendable () -> Date = Date.init)
    /// Runs until the target is satisfied, the tape pauses/fails/stops, or reaches review. Returns the final status.
    public func run() async -> RunnerStatus
}
```
- **Loop:**
  1. Load the intake (read-only) and its `roundConfig`. If the config is missing, set status
     `.failed` with a diagnosis and exit.
  2. Load the tape and set `runnerPID = getpid()`.
  3. **Adoption and recovery.** If `tape.roundInProgress != nil`, the previous runner died
     mid-round.
     - For each `runs/*/run.json` in that round whose pid is alive (`kill(pid, 0) == 0`),
       kill its process group.
     - Clear `roundInProgress`. The round is **rerun from scratch**, since outputs from a dead
       parent aren't trusted.
     - Record a `note` on the next checkpoint: "rerun after interruption".
  4. Apply the new commands (`commands(after: ackedCommandSeq)`) with `TapePlanner.apply`,
     and update `ackedCommandSeq`. A `.stop` command while idle sets `.stopped`.
  5. `next = TapePlanner.next(after:config:)`. If it is nil, set `.reachedReview`, save and
     return.
  6. If the target is `.none`, or the target is already satisfied after the head, set
     `.paused` (or `.idle` for a new tape with target `.none`), save and return.
  7. Set `.running`, `roundInProgress = next` and the heartbeat, then save. Run
     `executor.run(next, inputs)` **concurrently with a command watcher** that polls
     `commands.jsonl` every `pollInterval` and bumps the heartbeat:
     - `.stop` cancels the executor task. The children are killed and nothing is
       checkpointed. Clear `roundInProgress`, set `.stopped`, save and return.
     - `.pause` sets target `.none`, and the round runs to completion.
     - `annotate` and `extend` are applied as they arrive.
  8. On `.checkpoint`, call `writeCheckpoint`. Consume the annotations the round used (remove
     them from `pendingAnnotations`), clear `roundInProgress`, and go back to step 4. The
     target is re-checked there.
  9. On `.paused(diag)`, set `.failed` with `pauseDiagnosis = diag` and return.
- **The runner never writes `intake.json`.**

- [ ] **Step 1: Write the failing tests.** Use a fake executor built from a `RoundExecutor`
  with a scripted runner, and run `IntakeRunner.run()` directly:
  - `testRunsSketchToReview` (target `.review`: 4 checkpoints, then `.reachedReview`)
  - `testStepStopsAfterOneRound`
  - `testNextMajorStopsAtMajor`
  - `testPauseStopsAfterCurrentRound`: a slow fake round; append `.pause` while it runs; the
    round completes and the status is `.paused`.
  - `testStopKillsChildrenAndDiscards`: append `.stop`, then no new checkpoint and status
    `.stopped`.
  - `testRestartRerunsUnfinishedRound`: a tape with `roundInProgress` and a stale `run.json`
    reruns that round.
  - `testCommandsAreAckedOnce`
  - `testAnnotationsReachNextReviewRound`
  - `testExtendAddsRefineRound`
  - `testFailedRoundSetsFailedWithDiagnosis`
  - `testCheckpointWriteIsAtomic`: inject a failure after the files are written and before
    the tape is saved; reloading shows no new checkpoint.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: run an intake's tape to its target in a restartable loop`

## Task 9: The `flightdeck intake run` subcommand

**Files:**
- Modify: `project.yml`. Add `- target: IntakeKit` / `embed: false` to `FlightDeckCLI`.
- Modify: `Sources/FlightDeckTool/main.swift`. Intercept `intake run` right after the
  `.help` check (≈:57) and before any socket or transport code.
- Modify: `Sources/FlightDeckCLI/CLIArguments.swift`:
  - add `case intakeRun(id: UUID, root: String)`;
  - add `"--root"` to `valueFlags`;
  - add `parseIntake`, modelled on `parsePlan`.
- Modify: `Sources/FlightDeckCLI/CLIRunner.swift`. Add a `case .intakeRun: break` arm with a
  comment that main handles it before the runner exists.
- Test: `Tests/FlightDeckTests/CLIArgumentsIntakeTests.swift`

**Interfaces:**
- **Usage line:** `flightdeck intake run ID --root DIR   run an intake's planning rounds (started by Flight Deck)`.
- **In `main.swift`:**
  ```swift
  if case .intakeRun(let id, let root) = invocation.command {
      let env = ProcessInfo.processInfo.environment
      let runner = IntakeRunner(root: URL(fileURLWithPath: root), intakeID: id,
          executor: RoundExecutor(runner: SystemCommandRunner(), graphReader: GraphReader(runner: SystemCommandRunner(), environment: env)),
          environment: env)
      let sem = DispatchSemaphore(value: 0); var status: RunnerStatus = .idle
      Task { status = await runner.run(); sem.signal() }
      sem.wait()
      exit(status == .failed ? 1 : 0)
  }
  ```
  The environment is inherited as-is, because the app builds it (Task 10).

- [ ] **Step 1: Write the failing tests.** Parse `intake run <uuid> --root /x`. Missing ID,
  a bad UUID, and a missing `--root` each give a usage error. An unknown subcommand gives a
  usage error.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.** Build the app with `./scripts/build.sh` and confirm
  `Flight Deck.app/Contents/MacOS/flightdeck` links IntakeKit
  (`otool -L … | rg IntakeKit`).
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: add flightdeck intake run as the detached round runner`

## Task 10: App-side runner controller

**Files:**
- Create: `Sources/FlightDeck/Intake/IntakeRunnerController.swift`
- Modify: `Sources/FlightDeck/DaemonControl.swift`. Add path-based
  `isLive(socketPath:) -> Bool` and `terminate(socketPath:)`. The UUID-based methods delegate
  to them, so session behavior is unchanged.
- Test: `Tests/FlightDeckTests/Intake/IntakeRunnerControllerTests.swift`

**Interfaces:**
- Produces:
```swift
protocol RunnerSpawning { func spawn(executable: String, arguments: [String], environment: [String: String]) throws }
struct FdAbducoRunnerSpawner: RunnerSpawning   // Process(fd-abduco -n <sock> <flightdeck> intake run <id> --root <root>), waits for the launcher to exit
@MainActor final class IntakeRunnerController {
    init(daemon: SessionDaemon, control: DaemonControlling, spawner: RunnerSpawning,
         flightdeckPath: () -> String?, intakesRoot: URL, environment: () -> [String: String])
    func socketPath(for id: UUID) -> String            // <daemon.directory>/intake-<lowercased>.sock
    func isRunning(_ id: UUID) -> Bool
    /// Start a runner unless one is already live for this intake (Review Focus 5). Returns false with a reason if it can't.
    func ensureRunning(_ id: UUID) -> Result<Void, RunnerStartError>
    /// Collect a finished runner's daemon (fd-abduco keeps its socket until something attaches — see vendor notes).
    func reap(_ id: UUID)
}
enum RunnerStartError: Error, Equatable { case noBundledCLI, noFdAbduco, spawnFailed(String) }
```
- **`flightdeckPath`** defaults to
  `Bundle.main.url(forAuxiliaryExecutable: "flightdeck")?.path`. In a test host it is nil,
  which gives `.noBundledCLI`.
- **`environment`** defaults to `LoginShellPath.repairing(ProcessInfo.processInfo.environment)`
  with `CLAUDE_CODE_CHILD_SESSION` and `CLAUDECODE` removed, plus
  `FLIGHT_DECK_STATE_DIR` = the intakes root's parent. The runner therefore inherits a login
  PATH and nothing tying it to this tab's Claude session.
- **fd-abduco quirks:** the launcher for `-n` exits once the grandchild has exec'd, and the
  real daemon pid only appears in `<sock>.pid`. A runner that has exited still reports as
  live until something attaches. So "running" means
  `isLive(socket) && tape.status == .running || tape heartbeat < 10 s old`, and a finished
  tape (`status != .running`) whose socket is live gets `reap`ed.

- [ ] **Step 1: Write the failing tests** with a fake spawner and a fake control:
  - `testSpawnArguments` (exact argv, socket name, root, env has the repaired PATH and no
    `CLAUDECODE`)
  - `testLiveRunnerIsAdoptedNotRespawned`
  - `testMissingCLIReportsNoBundledCLI`
  - `testFinishedRunnerIsReaped`
  - `testSocketNameIsInvisibleToSessionReconcile`: `SessionDaemon.liveSessionIDs()` over a
    directory holding `intake-<uuid>.sock` returns `[]`.

  Also one **real fd-abduco integration test**, skipped when the binary isn't built. It
  spawns `fd-abduco -n <tmpsock> sh -c 'sleep 30'` through `FdAbducoRunnerSpawner`, asserts
  that `isLive(socketPath:)` becomes true, then calls `terminate(socketPath:)` and asserts it
  becomes false. Model it on `DaemonControlTests.spawnDaemon`/`waitForPidfile`.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: spawn and adopt intake runners under fd-abduco`

## Task 11: IntakeService integration

**Files:**
- Modify: `Sources/FlightDeck/Intake/IntakeService.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift`. Pass `clock` and a controller into
  `IntakeService`, mirroring the lazy `observeService` wiring.
- Test: `Tests/FlightDeckTests/Intake/IntakeServiceShapingTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 3 and 10.
- Produces, on `IntakeService`:
  - `@Published private(set) var tapes: [UUID: Tape]`
  - `func beginShaping(_ id: UUID, preset: Preset, config: RoundConfig)`. From
    `.awaitingChoice`:
    1. set `chosenPreset` and `roundConfig`, and state `.shaping`;
    2. save;
    3. append the config's `defaultPlay` as a command (`.toReview` → `.toReview`,
       `.nextMajor` → `.nextMajor`, `.step` → `.step`);
    4. call `controller.ensureRunning`. If that fails, mark the intake `.failed` with the
       reason.
  - `func send(_ id: UUID, _ command: TapeCommand)`. Appends the command, then calls
    `ensureRunning` unless the command is `.pause` or `.stop` (a paused runner has exited,
    so play means relaunch).
  - `func availableModels() -> AvailableModels`. Built from `TriageSettings.detect`'s PATH
    probe: codex and claude defaults for whichever are installed.
  - `choose(_:preset:)` is changed:
    - `.bead` keeps today's behavior;
    - any other preset calls `beginShaping(id, preset:, config: PresetExpansion.config(…)!)`,
      unless the UI has already called `beginShaping` with an edited config (Task 12). The
      `.parked` path is removed for new choices, and existing parked intakes can be resumed
      through `choose`.
- **Watching the tape.** Register one `WatchClock` tick. For every `.shaping` intake, reload
  its `tape.json` when the file's modification date changed, and publish `tapes[id]`. When
  `tape.status == .reachedReview`:
  1. load the latest checkpoint's `changeset.json`;
  2. set `intake.changeSet`;
  3. set state `.review` and save;
  4. call `controller.reap`.
- **Launch recovery changes.** A `.shaping` intake is **not** turned into `.interrupted`. If
  its tape is `.running` and the runner isn't live, call `ensureRunning`; the runner then
  reruns the unfinished round.
- **Attention.** `attentionCount` also counts `.shaping` intakes whose tape status is
  `.paused`, `.failed`, `.stopped` or `.idle`. Those are waiting for you.
- **`discard` while `.shaping`** sends `.stop`, then reaps, then discards.

- [ ] **Step 1: Write the failing tests** with a fake controller that records `ensureRunning`
  and `reap`, and a temp store:
  - `testChooseFeaturePlanBeginsShapingWithDefaultCommand`
  - `testSendPlayRelaunchesRunner`
  - `testReachedReviewMovesIntakeToReviewWithFinalChangeSet`
  - `testShapingSurvivesRelaunchAndRespawnsRunner`
  - `testPausedTapeCountsForAttention`
  - `testDiscardWhileShapingStopsRunner`
  - `testBeadChoiceUnchanged`
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: drive planning rounds from the intake service`

## Task 12: Round configuration editor

**Files:**
- Create: `Sources/FlightDeck/Intake/RoundConfigEditor.swift`
- Modify: `Sources/FlightDeck/Intake/IntakeDetailView.swift` (the `.awaitingChoice` body)
- Test: `Tests/FlightDeckTests/Intake/RoundConfigEditorTests.swift` (pure helpers)

**Interfaces:**
- **`.awaitingChoice`:**
  - It shows the recommendation, reason, and the preset Picker, as today.
  - When the chosen preset isn't `.bead`, a **disclosure** "Rounds" shows the expanded
    `RoundConfig`, one row per slot:
    - role and persona;
    - a harness Picker (limited to the available models);
    - a model TextField;
    - an effort Picker: `low`, `medium`, `high`, `xhigh` and `max`. **`ultra` is excluded**,
      because it enables delegation and isn't Pro;
    - a fallback Picker ("none" or the other model).
  - Also steppers for the refinement cap (0–12) and polish cap (0–12), a toggle for
    fresh-eyes + dedup, and a default-play Picker.
  - Editing any field sets `customized = true`, and the label becomes "<Preset>, customized".
  - "Start" calls `service.beginShaping(id, preset:, config:)`. "Continue" (Bead) keeps
    today's behavior.
- **Pure helpers:**
  - `RoundConfigEditor.label(preset:config:) -> String`;
  - `RoundConfigEditor.effortChoices` = `["low","medium","high","xhigh","max"]`;
  - `RoundConfigEditor.slots(of:) -> [(role: String, persona: DrafterPersona?, keyPath)]`.

- [ ] **Step 1: Write the failing tests.** The label (customized or not). `effortChoices`
  excludes "ultra". `slots(of:)` lists drafters, synthesizer, reviewer, integrator, encoder
  and polisher in order for Full plan.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.** Build with `./scripts/build.sh`; don't launch it.
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: let the user tune the planning rounds before starting`

## Task 13: The shaping view (tape, transport, rounds, plan)

**Files:**
- Create: `Sources/FlightDeck/Intake/ShapingView.swift`
- Create: `Sources/FlightDeck/Intake/TapeStrip.swift`
- Modify: `IntakeDetailView.swift` (add a `.shaping` body)
- Modify: `IntakeStatePill.swift` (the `.shaping` label reflects the tape status)
- Test: `Tests/FlightDeckTests/Intake/ShapingModelTests.swift` (pure view-model)

**Interfaces:**
- **Pure view-model:**
  ```swift
  struct ShapingModel {
      init(intake: Intake, tape: Tape)
      var stages: [StageMarker]          // for the strip: stage name, x-order, major flag, done/pending
      var statusLine: String             // e.g. "Paused at R2 · 14 changes (R1: 41) — ⏯ runs R3 · ⏭ runs R3 → plan final · ⏩ runs to review"
      var roundCards: [RoundCard]        // per checkpoint: title, change count, +/- lines, tally, slot badges (ok/substituted/failed + diagnosis text)
      var enabled: Set<TransportButton>  // step, nextMajor, toReview, pause, stop, extend, annotate
      var pauseBanner: (title: String, action: String)?  // from tape.pauseDiagnosis
  }
  enum TransportButton { case step, nextMajor, toReview, pause, stop, extend, annotate }
  ```
  Which buttons are enabled:
  - While `.running`: pause, stop and annotate.
  - While `.paused`/`.idle`/`.stopped`: step, nextMajor, toReview, extend and annotate.
  - While `.failed`: step (retry the round), toReview and annotate.
  - Never during `.reachedReview`.
- **`ShapingView`:**
  - `TapeStrip` at the top: stage columns with tick marks for minor and major checkpoints,
    and the playhead at the head.
  - The transport bar ⏯ ⏭ ⏩ ⏸ ⏹ ＋ ✎, each calling `service.send`:
    - ＋ opens a small menu ("+1 refine round", "+1 polish round");
    - ✎ opens a sheet with a TextEditor that sends `.annotate`.
  - The status line.
  - The pause banner with its action text when failed.
  - A horizontal list of round cards; a failed or substituted slot badge shows the diagnosis
    on hover.
  - A **plan viewer**:
    - a segmented control, "Plan" / "Diff vs previous" / "Change set";
    - it shows the selected checkpoint's `plan.md` (monospaced, scrollable, selectable), or
      `PlanMetrics.unifiedDiff` against the previous plan checkpoint, or a readable list of
      the change set's ops;
    - clicking a round card selects its checkpoint.

  Accessibility identifiers: `"shaping-view"`, `"transport-step"`, `"transport-next-major"`,
  `"transport-to-review"`, `"transport-pause"`, `"transport-stop"`, `"plan-viewer"`.

- [ ] **Step 1: Write the failing tests** for `ShapingModel`: the enabled buttons for every
  status, the `statusLine` examples, the round card content from a checkpoint (including a
  substituted slot's diagnosis text), and the `pauseBanner` from a failed tape.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.** Build with `./scripts/build.sh`; don't launch it.
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: drive and watch planning rounds from a tape with transport controls`

## Task 14: Docs, checklist and a live end-to-end probe

**Files:**
- Modify: `docs/ARCHITECTURE.md` (Intake section: runner, tape, file ownership, rounds)
- Modify: `docs/FOLLOWUPS.md`:
  - remove "triage/rounds lost on quit" for shaping;
  - add: branches and rewind, the Beads tab and graph review, oracle/grok/gemini slots,
    detection UI, and the convergence gauge. All of these are next.
- Modify: `docs/FLYWHEEL-INTAKE-CHECKLIST.md`. Add a section "Full plan from scratch":
  1. On a real non-temp project, type an intent, choose **Feature plan**, and look at the
     Rounds editor.
  2. Start. It stops after synthesis (⏭ default).
  3. Read the plan.
  4. ✎ annotate, then ⏯ one refine round, and check that the annotation shaped it.
  5. ⏩ to review.
  6. Quit Flight Deck mid-round and relaunch. The runner kept going or was respawned, and the
     round completed.
  7. ⏹ mid-round. Nothing is checkpointed.
  8. Release review, then release.
- Create: `Tests/FlightDeckTests/Intake/RoundsLiveProbeTests.swift`. Skipped unless
  `FLIGHTDECK_ROUNDS_LIVE=1`.

**The live probe** (run once by the implementer; don't loop it):
1. Create a scratch project under `$HOME` (`~/.fd-rounds-live-<uuid>`): git init, `br init`,
   and 2 beads.
2. Create an intake whose `roundConfig` is a **Sketch** using codex `gpt-5.6-luna`/`low`
   (or claude `haiku`) for every slot, with refinement cap 1.
3. Run `IntakeRunner.run()` in-process with the real `SystemCommandRunner` and
   `GraphReader`, target `.review`.
4. Assert:
   - the status is `.reachedReview`;
   - the draft, refine and encode checkpoints exist;
   - the final `changeset.json` validates against the graph;
   - every run has a `run.json`.
5. Remove the scratch directory.

Record the outcome, the cost and the timings in the report. A failure here is a prompt or
schema finding: report it, don't paper over it.

- [ ] **Step 1: Update the docs.**
- [ ] **Step 2: Write the probe test.** Run it once with `FLIGHTDECK_ROUNDS_LIVE=1` through
  `xctest` filtering on the probe class. `test-unit.sh` ignores `-only-testing:`, so run the
  built bundle's probe directly, the way earlier tasks did for single tests. Confirm it is
  skipped in a normal `test-unit.sh` run.
- [ ] **Step 3: Run the full suite once.**
- [ ] **Step 4: Commit.** `docs: document the round engine and add a live full-plan probe`

---

## Execution notes

- **Order:** 1 → 2 → 3, then 4, 5 and 6 (pure; may be parallel worktrees), then 7, 7b, 8,
  9, 10 and 11 in sequence, then 12 and 13 (parallel worktrees), then 14.
- **After merging:** a Release build and swap, then Nate walks the "Full plan from scratch"
  checklist section.
