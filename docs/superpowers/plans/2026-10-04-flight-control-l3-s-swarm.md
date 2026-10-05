# Flight Control L3-S Swarm Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flight Deck runs a swarm on a project: it claims ready tasks, gives each to an agent
configured by the task's execution block, keeps the swarm fed (reusing idle agents of the same
configuration), shows each agent's task, account and contested files on the sessions themselves,
lets the Mac or the phone pause it, and returns its claims to open when Flight Control is turned off.

**Architecture:** Pure records, decoders, the planner, the task prompt and the contested relation
go in `IntakeKit` (`Sources/IntakeKit/FlightControl/Swarm/`, Swift 6, Foundation only). The app
side (`Sources/FlightDeck/FlightControl/Swarm/`) holds the persisted `SwarmStore`, the `br`/`am`
command layer (`BrSwarmBackend`), the real `SwarmSpawner` conformer (`StoreSwarmSpawner`, which
also exposes the create/deliver/reset split the controller needs), one `@MainActor`
`SwarmController` per swarm, and `SwarmService`, which owns the controllers, ticks them on the
shared `WatchClock`, feeds them the Observe watcher's task set, and answers every view, the wire
and L3-U's hand-off driver. The swarm surfaces only as annotations: sidebar session rows, the
project header, a new first Observe lane, and a per-project swarm projection on the fleet wire.
Every routing/capacity question goes through the L3-0 protocols; tests use the L3-0 fakes plus
three L3-S fakes (`FakeSwarmBackend`, `FakeSwarmAgentLauncher`, `FakeSwarmHost`).

**Tech Stack:** Swift 6 (IntakeKit, FleetKit, FlightDeckMobile), Swift 5 mode (app target),
SwiftUI/AppKit, XCTest, XCUITest, XcodeGen, `br` 0.6.0, `am` 0.3.35, Python 3 (UI-test fixture stubs).

**Spec:** `docs/superpowers/specs/2026-10-04-flight-control-l3-swarm-design.md`
(overview: `docs/superpowers/specs/2026-10-04-flight-control-l3-overview-contract-design.md`;
contract plan, merged first: `docs/superpowers/plans/2026-10-04-flight-control-l3-0-contract.md`).

## Global Constraints

- **Depends on L3-0 only.** Consume exactly its names: `ExecutionBlock`, `ExecutionBlockCodec`,
  `ExecutionBlockError`, `AssignmentSource`, `KindID`, `PoolID`, `HarnessID`, `TaskKind`,
  `KindResolution`, `SeedKinds`, `AdapterCatalogs`, `Assignment`, `AccountRef`, `AccountLease`,
  `AccountHeadroom`, `HeadroomState`, `TaskRef`, `SessionRef`, `SwarmAgentSnapshot`,
  `HandoffRequest`, `SpawnError` (`launchFailed`, `composerTimeout`, `unsupportedHarness`,
  `claimConflict`), the protocols `KindRegistry`, `Router` (`assign(kind:project:catalogs:now:)`,
  `spill(_:kind:project:exhausted:catalogs:now:)`), `CapacityReader`, `PoolAllocator`,
  `HandoffPlanner`, and app-side `AgentRoutingCapabilities`, `RoutingCapability`,
  `RoutingCapabilityRegistry`, `LaunchOverrides`, `SwarmSpawner`
  (`spawn(task:block:lease:firstPrompt:)`), plus the fakes `FakeRouter`, `FakePoolAllocator`,
  `FakeCapacityReader`, `FakeHandoffPlanner`, `FakeKindRegistry`, `FakeRoutingCapabilities`,
  `FakeSwarmSpawner` and `L3Fixtures` (`fx-valid`, `fx-pinned`, `fx-invalid`, `fx-none`,
  `fx-newer`). **Never redefine a contract type.** Never import an L3-R/L3-I/L3-U concrete type.
- IntakeKit is Foundation-only, `SWIFT_VERSION: "6.0"`; every new IntakeKit type is `Sendable`.
  FleetKit is Swift 6 and compiles for iOS. The app target stays `SWIFT_VERSION: "5.0"`.
- **`FlightDeckMobile` is flat** — every new phone file goes directly in `Sources/FlightDeckMobile/`.
- **Wire enum cases are atomic.** A new `FleetEvent`/`FleetCommand` case and every switch arm
  that handles it land in the same commit (Tasks 12a). Every switch over them is exhaustive.
- **Words.** UI copy says *tasks* (never "beads"), *agent* (never "seat"), *Flight Control*
  (never "flywheel"). Code identifiers, argv, paths and persisted keys may keep "flywheel"/"bead".
  `TerminologyGuardTests` scans every literal in `Sources/FlightDeck/**` and most of IntakeKit;
  run it after every task that adds UI copy.
- Swarm state: `<state dir>/swarms.json` and `<state dir>/swarm-log/<swarm id>.jsonl`, where the
  state dir is `FileSessionPersistence.defaultDirectory()` (which already picks `Flight Deck` vs
  `Flight Deck (Debug)`) or `-FlightDeckStateDir` when given — the same root `intakes/` uses.
- Timings (exact): controller tick throttle **5 s** (`SwarmService.tickInterval`), composer-ready
  bound **120 s** (`SwarmTiming.composerTimeout`), prompt-delivery poll **1 s**, contested
  "recent" window **600 s** (`ContestedRelation.recentWindow`), spawn-failure pause threshold
  **3 in a row per config key** (`SwarmTiming.spawnFailureLimit`), default cap **3**.
- `br` argv (exact): `ready --json`; `scheduler --format json`; `list --status open --json`;
  `show <id> --json`; `update <id> --claim --actor <agentName> --json`;
  `update <id> --status open --assignee "" --actor flight-deck`;
  `update <id> --agent-context <json>`; `graph --all --json --db <project>/.beads/beads.db`.
  `am` argv (exact): `file_reservations release <project> <agentName>`;
  `reservations --project <project> --all --json`. All run with `cwd` = the project.
- Config key: `harness|model|knobs|pool`, knobs as `k=v` sorted by key and joined with `,`.
- The task prompt is exactly the spec §4 step 6 template (Task 3), at most 7,500 characters so it
  always passes `PromptText.maxCharacters` (8,000).
- Commits: lowercase, behavioral, imperative; body covers mechanism and rejected alternatives;
  trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit by path. Never
  `git stash`, never `git checkout .`.
- Tests: TDD — confirm each new test fails first. One class:
  `FD_TEST_FILTER=<Class> ./scripts/test-unit.sh 2>&1 | tail -40`. The script exits 0 on failure:
  read the final `SHARDED UNIT RUN PASSED|FAILED` line (a filtered run prints the xctest summary —
  look for `** TEST SUCCEEDED **`/`Executed N tests, with 0 failures`) and `rg -n "error:"` the
  output. If `test-unit.sh` rejects a class name in a filter (it checks every name first), find the
  real one with `rg -ln "class <Name>" Tests` and substitute it — never just drop it.
  `@MainActor` async tests use `await fulfillment(of:)`, never `wait(for:)`. Subagents run
  tests in the foreground. After touching `Sources/FleetKit` or `Sources/FlightDeckMobile`, also
  run `./scripts/build-ios.sh` and `./scripts/test-ios.sh`.
- Work in a worktree (`superpowers:using-git-worktrees`). Symlink `vendor/ghostty-artifacts` and
  `vendor/boringssl-artifacts` into it before the first build; never commit those symlinks. In a
  worktree use the built-in `Edit`, never the quillmap mutators (they write to the main checkout).
- Never launch a bundle from `DerivedData/`. Never loop `./scripts/smoke.sh`. The only GUI run in
  this plan is `scripts/test-ui-flight-control.sh` (Task 14), run once, throttled.
- Anything that runs real `br`/`am` (probe steps) runs in a scratch repo under `$HOME`
  (`~/.fd-l3s-probe-*`), never in this checkout, and is deleted afterwards.

**Deviations from the spec decided while planning (Task 15 records them in the spec):**
1. **`session.new` reuses the existing `ServerFrame.session(cid:UUID)`** (today the reply to
   `openConversation`) instead of a new frame case. Every old peer stays correct: the phone sends
   `session.new` fire-and-forget, so an unsolicited `.session` finds no pending table entry and is
   a no-op; an older `flightdeck` treats any non-`err` reply to its command as the ack. No
   capability gate is needed, and no enum changes, so this is one commit without a wire case.
2. **`lastActiveAt` is `SessionStore.lastActiveAt(for:)`, not a `SessionStatus` field.**
   `SessionStatus` is `Equatable` and compared in `commitStatuses`' change diff and in dozens of
   tests; a timestamp inside it would turn every activity tick into a change and every equality
   assertion into a clock assertion. It is still set on every activity transition, in
   `commitStatuses`, the one funnel.
3. **Reuse is checked before leasing** (spec §4 lists lease in step 3, reuse in step 4). An idle
   agent with the same config key already holds a lease on an account under soft; leasing first
   would hold two leases for one agent.
4. **`StoreSwarmSpawner` also conforms to `SwarmAgentLauncher`** (create / deliver / reset). The
   spec's order is spawn → claim → prompt, and the claim needs the agent name the spawn boots,
   so the controller drives the three steps itself. The contract's `spawn(task:block:lease:firstPrompt:)`
   composes them with an injected claim, for L3-U's hand-off.
5. **Guard capture for claude reads the transcript tail, not the hook record script.** A failed
   `git commit` is a Bash tool call that errors, and whether Claude Code's `PostToolUse` carries a
   failed call's output is unverified (a separate failure event may not be registered in
   `hooks.json`, and adding an unknown hook name risks the plugin failing validation). The
   transcript always records the `tool_result`. Codex reads its rollout tail. Both reach the store
   through one new `AgentEvent.outputSignals` case. The parser is shape-agnostic (it scans every
   string leaf of a record), so OpenCode can feed it the same way later.
6. **The UI test's "fake adapter" is the claude adapter running a stub shell**, through the
   existing `-FlightDeckFixture` shell override. Adding an `AgentID` case for a test double would
   change every exhaustive switch in the app (the same reason L3-0 deviation 4 gives).
7. **"Turn off Flight Control" lives in the project header menu only.** Preferences has no Flight
   Control control today (`ProjectSettings.flywheelEnabled` has no UI); adding a Preferences pane
   is out of scope.
8. **Pause/Resume live in the header's context menu and the swarm popover, not as an inline
   button.** `ProjectHeaderRow` documents that any control taking the mouse-down breaks the row's
   drag; the summary chip that opens the popover is a borderless button exactly like the existing
   hover-only close button.
9. **Swarm commands carry no idempotency token.** Pause/resume are idempotent by state; a repeated
   hand-off decision answers `no_handoff`.
10. **`lastActiveAt` stands in for the empty Observe events lane in stall detection** (Task 11e),
    so the collision trigger does not fire on every guard block: a holder is "stalled" only when
    its tab has been idle past the threshold.
11. **`TaskPrompt` is pure and lives in IntakeKit**, not `Sources/FlightDeck/FlightControl/Swarm/`.

## Review Focus

Five failures that are likely to bite and that the spec's own test list does not name. Each has a
named test in its owning task:

- **A task closed by a human while its agent still works.** The watcher sees the task leave
  `in_progress`, the agent goes idle, and the next tick would reuse it — typing `/clear` into a
  turn that is still running. Reuse must require the tab itself to be idle.
  Pinned by `testHumanClosedTaskDoesNotReuseABusyAgent` (Task 7d).
- **`br scheduler` ranking a task the filter excludes, or one that is not ready.** The scheduler
  ranks the whole project; an intake swarm must never claim outside its intake, and a ranked but
  blocked task must never be claimed. Pinned by `testSchedulerRankOutsideFilterIsNeverClaimed`
  and `testRankedButNotReadyTaskIsNeverClaimed` (Task 7a).
- **A crash between `br update --claim` and saving the record.** The claim landed, the record does
  not know it, and after restart the task sits `in_progress` forever under an agent that never
  received its prompt — or the swarm claims a second task for the same agent. `pendingClaim` is
  saved before the claim runs; on restore a claim that landed is returned to open (the agent never
  heard about the task) and one that did not is left alone. Pinned by
  `testRestoreReopensAClaimThatLandedBeforeTheCrash` and
  `testRestoreDropsAPendingClaimThatNeverLanded` (Task 7g).
- **A reused agent's stale reservations.** An agent that held `Sources/Foo.swift` for its last
  task still holds it when it starts the next one, and blocks every other agent's commit. Reuse
  releases reservations before the context reset. Pinned by
  `testReuseReleasesReservationsBeforeResettingContext` (Task 7b).
- **A session tab closed by the user mid-swarm.** The agent record still says `working`, its claim
  is held forever, and its slot never frees. Pinned by
  `testClosedTabReturnsItsClaimAndFreesItsSlot` (Task 7d).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/IntakeKit/FlightControl/Swarm/SwarmRecord.swift` | `SwarmState`, `SwarmAgentState`, `SwarmFilter`, `ConfigKey`, `StoredBlock`, `StoredLease`, `SwarmAgentRecord`, `WaitingTask`, `SwarmRecord`, `SwarmLogEntry` |
| `Sources/IntakeKit/FlightControl/Swarm/SwarmTasks.swift` | `ReadyTask`, `TaskDetail`, `TaskStatusReading`, `ClaimOutcome`, `SwarmTaskDecoding` (br JSON → values, join, order) |
| `Sources/IntakeKit/FlightControl/Swarm/SwarmPlanner.swift` | pure tick decisions: candidates, reuse pick, auto-stop |
| `Sources/IntakeKit/FlightControl/Swarm/TaskPrompt.swift` | the first-prompt template |
| `Sources/IntakeKit/FlightControl/Swarm/AgentOutputSignal.swift` | guard-block and `BLOCKED:` parsing from agent output records |
| `Sources/IntakeKit/FlightControl/Swarm/ContestedRelation.swift` | `Glob`, `HeldReservation`, `SessionSignals`, `Contest`, `ContestedRelation` |
| `Sources/IntakeKit/GraphSnapshot.swift` | + `decodeEdges(graph:)` (shared by release and Observe) |
| `Sources/FlightDeck/FlightControl/Swarm/SwarmStore.swift` | `swarms.json` + `swarm-log/*.jsonl`, restore-as-paused |
| `Sources/FlightDeck/FlightControl/Swarm/SwarmBackend.swift` | `SwarmBackend` protocol, `BrSwarmBackend` over `FlywheelProcessRunner` |
| `Sources/FlightDeck/FlightControl/Swarm/LaunchOverrideMapping.swift` | claude/codex `applying`, `SessionCommandSink`, `ContextReset` |
| `Sources/FlightDeck/FlightControl/Swarm/SwarmSpawner.swift` | `SwarmAgentLauncher`, `SwarmTiming`, `PromptDelivery`, `StoreSwarmSpawner` |
| `Sources/FlightDeck/FlightControl/Swarm/SwarmHost.swift` | `SwarmHost` protocol + `SessionStore` conformance |
| `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift` | one swarm's keep-it-fed state machine |
| `Sources/FlightDeck/FlightControl/Swarm/SwarmService.swift` | owns controllers, clock, store, hand-off API, contested signals |
| `Sources/FlightDeck/FlightControl/Swarm/LaunchSheet.swift` | `SwarmLaunchRequest`, `LaunchSheetModel`, `LaunchSheet` |
| `Sources/FlightDeck/FlightControl/Swarm/SwarmAnnotations.swift` | row/header/drawer models and their small views |
| `Sources/FlightDeck/FlightControl/Swarm/SwarmWire.swift` | `SwarmWireProjection` |
| `Sources/FlightDeck/FlightControl/Swarm/ObserveEnrichment.swift` | waiters/activity/blocked enrichment of an Observe snapshot |
| `Sources/FlightDeck/FlightControl/Swarm/FlightControlDisable.swift` | `FlightControlOff`, `FlightControlRepoRemoval` |
| `Sources/FlightDeck/FlightControl/Swarm/FlightControlFixtureBackend.swift` | Debug-only `-FlightControlFixtureBackend` wiring |
| `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift` | (L3-0's) claude/codex `applying` + `resetContext` bodies, `commands` property |
| `Sources/FlightDeck/SessionStore.swift` | overrides on `createSession`/`newSession`, `routingCapabilities`, `lastActiveAt`, swarm wiring, `swarmSummaries`, prompt-queue helpers |
| `Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift` | `reasoningEffort` |
| `Sources/FlightDeck/Agents/AgentKind.swift` | `AgentEvent.outputSignals` |
| `Sources/FlightDeck/TranscriptWatcher.swift`, `Agents/ClaudeRuntime.swift`, `Agents/Codex/CodexRolloutWatcher.swift` | output-signal taps |
| `Sources/FlightDeck/Flywheel/Observe/FlywheelReadCommands.swift` | real `reservations`, `depEdges` |
| `Sources/FlightDeck/Flywheel/Observe/FlywheelWatcher.swift` | reads the two new lanes |
| `Sources/FlightDeck/Flywheel/Observe/FlywheelProjection.swift` | `declaredBlocked` |
| `Sources/FlightDeck/Flywheel/Observe/FlywheelObserveService.swift` | `enrich` hook |
| `Sources/FlightDeck/Flywheel/Observe/FlywheelNotifier.swift` | cycle participants mapped to assignees |
| `Sources/FlightDeck/Flywheel/Observe/ObserveDrawer.swift` | `ObserveLane.assignment` first |
| `Sources/FlightDeck/Flywheel/FlywheelSetup.swift` | expose the beads-sync hook body |
| `Sources/FlightDeck/SessionSidebar.swift`, `ProjectHeaderRow.swift`, `RootView.swift`, `ProjectView.swift`, `Intake/IntakeDetailView.swift`, `FlightDeckApp.swift` | mounts |
| `Sources/FleetKit/SwarmWireTypes.swift` | `WireSwarm`, `WireSwarmAgent`, `WireSwarmMeter` |
| `Sources/FleetKit/Wire.swift`, `FleetEvent.swift`, `WireCoding.swift`, `FleetReplay.swift`, `SnapshotApplication.swift`, `Frames.swift`, `PhoneLogs.swift`, `FleetConnector.swift` | swarm projection event + commands, `.session` acks |
| `Sources/FlightDeck/Fleet/FleetService.swift`, `Fleet/ControlScope.swift`, `Fleet/FleetProjection.swift` | handlers, scope, projection |
| `Sources/FlightDeckCLI/CLIRunner.swift`, `CLIOutput.swift` | `flightdeck new` prints the returned id; event arm |
| `Sources/FlightDeckMobile/SwarmStyle.swift`, `SwarmCard.swift` | phone chips + project card |
| `Sources/FlightDeckMobile/FleetListScreen.swift`, `FleetModel.swift`, `UITestHarness.swift` | mounts, commands, harness |
| `Tests/FlightDeckTests/FlightControlL3/Swarm/*.swift` | unit tests + `SwarmTestSupport.swift` fakes |
| `Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm/*` | br/am fixtures (hand-written + captured) |
| `Tests/FlightDeckMobileTests/SwarmStyleTests.swift`, `Tests/FlightDeckMobileUITests/SwarmCardUITests.swift` | phone tests |
| `UITests/FlightDeckUITests/SwarmUITests.swift` | XCUITest against the fixture backend |
| `scripts/make-flight-control-fixture.py`, `scripts/test-ui-flight-control.sh` | fixture builder (stub `br`/`am`/agent) and the runner |
| `docs/FLIGHT-CONTROL-L3-CHECKLIST.md` | the maintainer's §12 tasks |

`project.yml` needs no edit: `Sources/IntakeKit`, `Sources/FlightDeck`, `UITests/FlightDeckUITests`,
`Tests/FlightDeckMobileTests` and `Tests/FlightDeckMobileUITests` are globbed, and
`Tests/FlightDeckTests/Fixtures` is a folder reference (`project.yml:150-158`). Run `xcodegen
generate` (every script does) after adding files.

**Task order** (each task leaves both suites green; later tasks consume only earlier ones and L3-0):

| # | Task | Depends on |
|---|---|---|
| 1 | Swarm record, config key, `SwarmStore` | L3-0 |
| 2 | `br`/`am` command layer + fixtures (probe) | 1 |
| 3 | Task prompt | 2 |
| 4a | `createSession` overrides; claude/codex `applying` (probe) | L3-0 |
| 4b | claude/codex `resetContext` (probe) | 4a |
| 5 | Prompt delivery + real `SwarmSpawner` | 2, 4a, 4b |
| 6 | `SessionStore.lastActiveAt(for:)` | — |
| 7a–7g | `SwarmController`: fill · reuse · waiting/spill · completion · lifecycle · failures · restart | 1–6 |
| 7h | `SwarmService` + store wiring | 7a–7g |
| 8 | Launch sheet | 7h |
| 9 | `session.new` → id (atomic) | — |
| 10a–10c | Row chips · header · drawer Assignment lane | 7h |
| 11a–11e | Reservations (probe) · depEdges · signal parsing · signal capture · enrichment + notifier | 7h, 10 |
| 12a–12b | Fleet wire (atomic) · phone | 10, 11 |
| 13 | Turn off / remove from repo (probe) | 7h |
| 14 | Fixture backend + stub agent + `SwarmUITests` + runner | all |
| 15 | Checklist, full suites, deviations, FOLLOWUPS, vendor diff | all |

**Before Task 1:** confirm L3-0 is merged — `rg -n "protocol SwarmSpawner" Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift`
must print one line, and `rg -n "final class FakeSwarmSpawner" Tests/FlightDeckTests/FlightControlL3/Fakes`
must print one line. If either is missing, stop: this plan cannot start before L3-0.

---
### Task 1: The swarm record, its config key, and the store

**Files:**
- Create: `Sources/IntakeKit/FlightControl/Swarm/SwarmRecord.swift`
- Create: `Sources/FlightDeck/FlightControl/Swarm/SwarmStore.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmRecordTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmStoreTests.swift`

**Interfaces:**
- Consumes: `ExecutionBlock`, `ExecutionBlockCodec`, `AccountLease`, `AccountRef`, `PoolID` (L3-0);
  `FileSessionPersistence.defaultDirectory(debug:)` (`Sources/FlightDeck/SessionPersistence.swift:264`).
- Produces (IntakeKit, all `public`, `Sendable`):
  - `enum SwarmState: String, Codable { running, paused, draining, stopped }`
  - `enum SwarmAgentState: String, Codable { starting, working, idle, handedOff, done }`
  - `enum SwarmFilter: Codable, Equatable { intake(id: UUID, tasks: [String]), allReady; func admits(_:) -> Bool }` — JSON `{"intake":"<id>","tasks":[…]}` or `{"allReady":true}`
  - `struct ConfigKey: RawRepresentable, Hashable, Codable, CustomStringConvertible { init(_ block: ExecutionBlock) }`
  - `struct StoredBlock: Codable, Equatable { var block: ExecutionBlock }` (encodes via `ExecutionBlockCodec`)
  - `struct StoredLease: Codable, Equatable { id; pool; account; init(_ lease: AccountLease); var lease: AccountLease }`
  - `struct SwarmAgentRecord: Codable, Equatable` (fields below)
  - `struct WaitingTask: Codable, Equatable { task: String; reason: String }`
  - `struct SwarmRecord: Codable, Equatable, Identifiable` with `agent(_:)`, `update(_:_:)`, `activeCount`, `load(of:)`, `poolCap(_:)`
  - `struct SwarmLogEntry: Codable, Equatable { at; kind: Kind; task: String?; session: UUID?; detail: String }`
- Produces (app): `@MainActor final class SwarmStore { init(root: URL); static func defaultRoot(stateDirectory: URL?) -> URL; static let restartBanner: String; func load() -> [SwarmRecord]; func restore() -> [SwarmRecord]; func save(_:); func append(_:swarm:); func log(swarm:) -> [SwarmLogEntry] }`

- [ ] **Step 1: Write the failing record tests**

```swift
import XCTest
import IntakeKit

/// The swarm record is the one thing that survives a relaunch, so its JSON has to round-trip
/// exactly, and the config key — what decides that two agents are interchangeable for reuse —
/// must not depend on the order knobs happened to be written in.
final class SwarmRecordTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func block(model: String = "gpt-6-sol", knobs: [String: String] = ["effort": "high"],
                       pool: PoolID = "codex-subs") -> ExecutionBlock {
        ExecutionBlock(kind: "tests", harness: "codex", model: model, knobs: knobs, pool: pool,
                       source: AssignmentSource(by: .rule, ruleId: "r1", reason: "r", at: at))
    }

    func testConfigKeyIsHarnessModelKnobsPool() {
        XCTAssertEqual(ConfigKey(block()).rawValue, "codex|gpt-6-sol|effort=high|codex-subs")
        XCTAssertEqual(ConfigKey(block(knobs: [:])).rawValue, "codex|gpt-6-sol||codex-subs")
    }

    func testConfigKeyIgnoresKnobOrder() {
        let a = block(knobs: ["effort": "high", "agent": "build"])
        let b = block(knobs: ["agent": "build", "effort": "high"])
        XCTAssertEqual(ConfigKey(a), ConfigKey(b))
        XCTAssertEqual(ConfigKey(a).rawValue, "codex|gpt-6-sol|agent=build,effort=high|codex-subs")
    }

    func testConfigKeyDiffersOnPoolOrModel() {
        XCTAssertNotEqual(ConfigKey(block()), ConfigKey(block(pool: "codex-team")))
        XCTAssertNotEqual(ConfigKey(block()), ConfigKey(block(model: "gpt-6-terra")))
    }

    func testFilterCodesAsSpecShapes() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let intake = try JSONEncoder().encode(SwarmFilter.intake(id: id, tasks: ["fx-a"]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: intake) as? [String: Any])
        XCTAssertEqual(obj["intake"] as? String, id.uuidString)
        XCTAssertEqual(obj["tasks"] as? [String], ["fx-a"])
        XCTAssertEqual(try JSONDecoder().decode(SwarmFilter.self, from: intake), .intake(id: id, tasks: ["fx-a"]))
        let all = try JSONEncoder().encode(SwarmFilter.allReady)
        XCTAssertEqual(String(decoding: all, as: UTF8.self), #"{"allReady":true}"#)
        XCTAssertEqual(try JSONDecoder().decode(SwarmFilter.self, from: all), .allReady)
        XCTAssertThrowsError(try JSONDecoder().decode(SwarmFilter.self, from: Data("{}".utf8)))
    }

    func testFilterAdmits() {
        XCTAssertTrue(SwarmFilter.allReady.admits("anything"))
        XCTAssertTrue(SwarmFilter.intake(id: UUID(), tasks: ["fx-a"]).admits("fx-a"))
        XCTAssertFalse(SwarmFilter.intake(id: UUID(), tasks: ["fx-a"]).admits("fx-b"))
    }

    func testRecordRoundTripsWithBlockAndLease() throws {
        let lease = AccountLease(id: UUID(), pool: "codex-subs",
                                 account: AccountRef(harness: "codex", id: UUID(), label: "Work"))
        let agent = SwarmAgentRecord(session: UUID(), agentName: "BlueLake", block: block(),
                                     lease: lease, task: "fx-a", state: .working, stateSince: at)
        let record = SwarmRecord(id: UUID(), project: "/p", cap: 3, poolCaps: ["codex-subs": 2],
                                 filter: .allReady, state: .running, agents: [agent], createdAt: at)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(SwarmRecord.self, from: enc.encode(record))
        XCTAssertEqual(back, record)
        XCTAssertEqual(back.agents.first?.lease?.lease, lease)
        XCTAssertEqual(back.agents.first?.config, ConfigKey(block()))
    }

    func testActiveCountAndPoolLoadCountOnlyStartingAndWorking() {
        func agent(_ state: SwarmAgentState, pool: PoolID = "codex-subs") -> SwarmAgentRecord {
            SwarmAgentRecord(session: UUID(), agentName: "A", block: block(pool: pool), lease: nil,
                             task: nil, state: state, stateSince: at)
        }
        let record = SwarmRecord(id: UUID(), project: "/p", cap: 3, poolCaps: [:], filter: .allReady,
                                 state: .running,
                                 agents: [agent(.starting), agent(.working), agent(.idle),
                                          agent(.done), agent(.handedOff), agent(.working, pool: "other")],
                                 createdAt: at)
        XCTAssertEqual(record.activeCount, 3)
        XCTAssertEqual(record.load(of: "codex-subs"), 2)
        XCTAssertEqual(record.load(of: "other"), 1)
        XCTAssertNil(record.poolCap("codex-subs"))
    }

    func testUpdateMutatesOneAgentInPlace() {
        let s = UUID()
        var record = SwarmRecord(id: UUID(), project: "/p", cap: 1, poolCaps: [:], filter: .allReady,
                                 state: .running,
                                 agents: [SwarmAgentRecord(session: s, agentName: "A", block: block(),
                                                           lease: nil, task: nil, state: .idle, stateSince: at)],
                                 createdAt: at)
        record.update(s) { $0.task = "fx-a"; $0.state = .working }
        XCTAssertEqual(record.agent(s)?.task, "fx-a")
        XCTAssertEqual(record.agent(s)?.state, .working)
        record.update(UUID()) { $0.task = "nope" }   // unknown session: a no-op, not a crash
        XCTAssertEqual(record.agents.count, 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmRecordTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'ConfigKey' in scope`.

- [ ] **Step 3: Implement `SwarmRecord.swift`**

```swift
import Foundation

/// One swarm's lifecycle. `paused` and `draining` both stop new claims; `draining` additionally
/// becomes `stopped` when the last working agent goes idle. A swarm restored after a relaunch is
/// always `paused` (spec §2) — FD never resumes claiming on its own.
public enum SwarmState: String, Codable, Sendable, Equatable { case running, paused, draining, stopped }

/// `done` is an agent that has left the swarm for good (its tab closed, or the swarm stopped);
/// `handedOff` is one whose work moved to a fresh agent (L3-U).
public enum SwarmAgentState: String, Codable, Sendable, Equatable { case starting, working, idle, handedOff, done }

/// Which ready tasks a swarm may claim. An intake swarm carries the task ids its release
/// created, resolved once at launch, so the controller never needs the intake store to tick.
public enum SwarmFilter: Equatable, Sendable {
    case intake(id: UUID, tasks: [String])
    case allReady

    public func admits(_ task: String) -> Bool {
        switch self {
        case .allReady: true
        case .intake(_, let tasks): tasks.contains(task)
        }
    }
}

extension SwarmFilter: Codable {
    private enum Keys: String, CodingKey { case intake, tasks, allReady }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let id = try c.decodeIfPresent(UUID.self, forKey: .intake) {
            self = .intake(id: id, tasks: try c.decodeIfPresent([String].self, forKey: .tasks) ?? [])
        } else if try c.decodeIfPresent(Bool.self, forKey: .allReady) == true {
            self = .allReady
        } else {
            // Refused rather than defaulted to `allReady`: a filter that lost its intake and
            // silently widened to the whole project would claim work nobody released.
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "filter names neither an intake nor allReady"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .intake(let id, let tasks):
            try c.encode(id, forKey: .intake)
            try c.encode(tasks, forKey: .tasks)
        case .allReady:
            try c.encode(true, forKey: .allReady)
        }
    }
}

/// `harness|model|knobs|pool`. Two agents with equal keys are interchangeable for reuse (spec §2).
/// Knobs are sorted so a block written `{effort, agent}` and one written `{agent, effort}` are the
/// same configuration — a map's iteration order must never decide whether an agent is reused.
public struct ConfigKey: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ block: ExecutionBlock) {
        let knobs = block.knobs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        rawValue = [block.harness.rawValue, block.model, knobs, block.pool.rawValue].joined(separator: "|")
    }
    public var description: String { rawValue }
}

/// An execution block persisted through the same codec br's `agent_context` uses, so a stored
/// block and a task's block can never disagree about a field.
public struct StoredBlock: Codable, Equatable, Sendable {
    public var block: ExecutionBlock
    public init(_ block: ExecutionBlock) { self.block = block }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        switch ExecutionBlockCodec.decode(agentContext: text) {
        case .success(let block?): self.block = block
        case .success(nil):
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no execution block"))
        case .failure(let error):
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.message))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(try ExecutionBlockCodec.encode(block, into: nil))
    }
}

/// `AccountLease` is not `Codable` in the contract; this is its persisted shape.
public struct StoredLease: Codable, Equatable, Sendable {
    public var id: UUID
    public var pool: PoolID
    public var account: AccountRef
    public init(_ lease: AccountLease) { id = lease.id; pool = lease.pool; account = lease.account }
    public var lease: AccountLease { AccountLease(id: id, pool: pool, account: account) }
}

public struct SwarmAgentRecord: Codable, Equatable, Sendable {
    public var session: UUID
    public var agentName: String
    public var config: ConfigKey
    public var block: StoredBlock
    public var lease: StoredLease?
    public var task: String?
    public var state: SwarmAgentState
    /// Written and saved BEFORE `br update --claim` runs, cleared once its outcome is recorded.
    /// A crash between the claim landing and the record being saved leaves this set, which is
    /// how a restore finds out whether to adopt the claim (Review Focus: crash mid-claim).
    public var pendingClaim: String?
    /// Set when this agent must never be reused again: its context reset failed, or it never
    /// showed a composer (spec §10).
    public var excludedFromReuse: Bool
    /// A short human note for the row: "stuck at start", "reset failed", "tab closed".
    public var marker: String?
    /// The last task this agent closed — what the row's *done* marker names.
    public var lastTask: String?
    public var stateSince: Date
    public var handedOffFrom: UUID?
    public var handedOffTo: UUID?

    public init(session: UUID, agentName: String, block: ExecutionBlock, lease: AccountLease?,
                task: String?, state: SwarmAgentState, stateSince: Date) {
        self.session = session; self.agentName = agentName
        self.config = ConfigKey(block); self.block = StoredBlock(block)
        self.lease = lease.map(StoredLease.init); self.task = task; self.state = state
        self.pendingClaim = nil; self.excludedFromReuse = false; self.marker = nil
        self.lastTask = nil; self.stateSince = stateSince
        self.handedOffFrom = nil; self.handedOffTo = nil
    }
}

public struct WaitingTask: Codable, Equatable, Sendable {
    public var task: String
    public var reason: String
    public init(task: String, reason: String) { self.task = task; self.reason = reason }
}

/// At most one per project (spec §2).
public struct SwarmRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// The standardized project path (`FlywheelObserveService.key`).
    public var project: String
    public var cap: Int
    /// Pool id → its own cap. A dictionary keyed by `String` rather than `PoolID` so it encodes
    /// as a JSON object: `JSONEncoder` writes a non-`String`-keyed dictionary as an array.
    public var poolCaps: [String: Int]
    public var filter: SwarmFilter
    public var state: SwarmState
    public var agents: [SwarmAgentRecord]
    public var createdAt: Date
    /// The header banner: the restart notice, or why the swarm paused itself.
    public var banner: String?
    /// Tasks the last fill could not start, with why (spec §4 step 3).
    public var waiting: [WaitingTask]
    /// Ready tasks whose block cannot be routed (spec §10). Kept apart from `waiting` because
    /// they never count against auto-stop: a swarm whose only ready work is unroutable is done.
    public var unroutable: [WaitingTask]
    /// Config key → consecutive spawn failures (spec §10: three in a row pause the swarm).
    public var spawnFailures: [String: Int]

    public init(id: UUID, project: String, cap: Int, poolCaps: [String: Int], filter: SwarmFilter,
                state: SwarmState, agents: [SwarmAgentRecord], createdAt: Date) {
        self.id = id; self.project = project; self.cap = cap; self.poolCaps = poolCaps
        self.filter = filter; self.state = state; self.agents = agents; self.createdAt = createdAt
        self.banner = nil; self.waiting = []; self.unroutable = []; self.spawnFailures = [:]
    }

    public func agent(_ session: UUID) -> SwarmAgentRecord? { agents.first { $0.session == session } }

    public mutating func update(_ session: UUID, _ change: (inout SwarmAgentRecord) -> Void) {
        guard let i = agents.firstIndex(where: { $0.session == session }) else { return }
        change(&agents[i])
    }

    /// Agents that fill a slot: the spec's free-slot count is `cap` minus these.
    public var activeCount: Int { agents.filter { $0.state == .starting || $0.state == .working }.count }

    public func load(of pool: PoolID) -> Int {
        agents.filter { ($0.state == .starting || $0.state == .working) && $0.block.block.pool == pool }.count
    }

    public func poolCap(_ pool: PoolID) -> Int? { poolCaps[pool.rawValue] }
}

/// One line of `swarm-log/<swarm id>.jsonl` (spec §2).
public struct SwarmLogEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case launch, claim, conflict, spawn, spawnFailed, reuse, resetFailed, prompt, stuck
        case close, reopen, released, handoff, spill, pause, resume, drain, stop, error
    }
    public var at: Date
    public var kind: Kind
    public var task: String?
    public var session: UUID?
    public var detail: String
    public init(at: Date, kind: Kind, task: String? = nil, session: UUID? = nil, detail: String = "") {
        self.at = at; self.kind = kind; self.task = task; self.session = session; self.detail = detail
    }
}
```

- [ ] **Step 4: Run the record tests**

Run: `FD_TEST_FILTER=SwarmRecordTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 7 tests, with 0 failures`, no `error:` lines.

- [ ] **Step 5: Write the failing store tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// swarms.json is what a relaunch reads, and the one rule it carries is spec §2's: a swarm that
/// was running comes back paused, with a banner, and claims nothing until a human resumes it.
@MainActor
final class SwarmStoreTests: XCTestCase {
    private var root: URL!
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-store-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func record(_ state: SwarmState, project: String = "/p") -> SwarmRecord {
        SwarmRecord(id: UUID(), project: project, cap: 3, poolCaps: [:], filter: .allReady,
                    state: state, agents: [], createdAt: at)
    }

    func testSaveThenLoadRoundTrips() {
        let store = SwarmStore(root: root)
        let records = [record(.running), record(.stopped, project: "/q")]
        store.save(records)
        XCTAssertEqual(SwarmStore(root: root).load(), records)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("swarms.json").path))
    }

    func testRestoreBringsRunningAndDrainingBackPausedWithBanner() {
        let store = SwarmStore(root: root)
        store.save([record(.running, project: "/a"), record(.draining, project: "/b"),
                    record(.paused, project: "/c"), record(.stopped, project: "/d")])
        let restored = SwarmStore(root: root).restore()
        XCTAssertEqual(restored.map(\.state), [.paused, .paused, .paused, .stopped])
        XCTAssertEqual(restored.map(\.banner), [SwarmStore.restartBanner, SwarmStore.restartBanner, nil, nil])
        XCTAssertEqual(SwarmStore.restartBanner, "Swarm paused after restart · Resume")
    }

    func testMissingOrCorruptFileLoadsEmpty() throws {
        XCTAssertEqual(SwarmStore(root: root).load(), [])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("swarms.json"))
        XCTAssertEqual(SwarmStore(root: root).load(), [], "a corrupt file must not crash the app at launch")
    }

    func testLogAppendsOneLinePerEntryPerSwarm() throws {
        let store = SwarmStore(root: root)
        let a = UUID(), b = UUID()
        store.append(SwarmLogEntry(at: at, kind: .launch, detail: "cap 3"), swarm: a)
        store.append(SwarmLogEntry(at: at, kind: .claim, task: "fx-a", detail: "BlueLake"), swarm: a)
        store.append(SwarmLogEntry(at: at, kind: .pause), swarm: b)
        XCTAssertEqual(store.log(swarm: a).map(\.kind), [.launch, .claim])
        XCTAssertEqual(store.log(swarm: b).map(\.kind), [.pause])
        let text = try String(contentsOf: root.appendingPathComponent("swarm-log/\(a.uuidString).jsonl"), encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testDefaultRootFollowsTheStateDirectoryHelper() {
        XCTAssertEqual(SwarmStore.defaultRoot(stateDirectory: nil), FileSessionPersistence.defaultDirectory())
        let custom = URL(fileURLWithPath: "/tmp/custom-state", isDirectory: true)
        XCTAssertEqual(SwarmStore.defaultRoot(stateDirectory: custom), custom)
    }
}
```

- [ ] **Step 6: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmStoreTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'SwarmStore' in scope`.

- [ ] **Step 7: Implement `SwarmStore.swift`**

```swift
import Foundation
import IntakeKit
import OSLog

/// Persists every swarm and its action log beside `sessions.json`.
///
/// `root` is the same directory `intakes/` lives in — `FileSessionPersistence.defaultDirectory()`,
/// which already separates `Flight Deck` from `Flight Deck (Debug)`, or `-FlightDeckStateDir`. A
/// Debug build writing the live swarms file would resume a release build's swarm from a second
/// app, which is the duplicate-agent collision `AGENTS.md` rule 2 is about.
@MainActor
final class SwarmStore {
    static let restartBanner = "Swarm paused after restart · Resume"
    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "swarm")

    private struct File: Codable { var v: Int; var swarms: [SwarmRecord] }

    let root: URL
    var fileURL: URL { root.appendingPathComponent("swarms.json") }
    var logDirectory: URL { root.appendingPathComponent("swarm-log", isDirectory: true) }

    init(root: URL) { self.root = root }

    static func defaultRoot(stateDirectory: URL?) -> URL {
        stateDirectory ?? FileSessionPersistence.defaultDirectory()
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// Empty on a missing or unreadable file. A corrupt swarms file must never stop the app from
    /// launching; the log names it once so a lost swarm is diagnosable.
    func load() -> [SwarmRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let file = try? Self.decoder.decode(File.self, from: data) else {
            Self.logger.error("swarms.json did not decode; starting with no swarms")
            return []
        }
        return file.swarms
    }

    /// `load()` with spec §2's relaunch rule applied: a running or draining swarm comes back
    /// paused with the restart banner. The agents survive in their tabs (fd-abduco); FD does not.
    func restore() -> [SwarmRecord] {
        load().map { record in
            var r = record
            if r.state == .running || r.state == .draining {
                r.state = .paused
                r.banner = Self.restartBanner
            }
            return r
        }
    }

    func save(_ records: [SwarmRecord]) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.encoder.encode(File(v: 1, swarms: records)).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("could not save swarms.json: \(String(describing: error), privacy: .public)")
        }
    }

    func append(_ entry: SwarmLogEntry, swarm: UUID) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        let url = logDirectory.appendingPathComponent("\(swarm.uuidString).jsonl")
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url)
            }
        } catch {
            Self.logger.error("could not append to \(url.lastPathComponent, privacy: .public)")
        }
    }

    func log(swarm: UUID) -> [SwarmLogEntry] {
        let url = logDirectory.appendingPathComponent("\(swarm.uuidString).jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(SwarmLogEntry.self, from: Data($0.utf8)) }
    }
}
```

- [ ] **Step 8: Run both test classes**

Run: `FD_TEST_FILTER=SwarmRecordTests,SwarmStoreTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 12 tests, with 0 failures`.

- [ ] **Step 9: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Swarm/SwarmRecord.swift Sources/FlightDeck/FlightControl/Swarm/SwarmStore.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmRecordTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmStoreTests.swift
git commit -m "feat: persist swarm records and restore a running swarm as paused" -m "A swarm is one record per project in swarms.json beside sessions.json, with an append-only action log per swarm. The config key (harness|model|knobs|pool, knobs sorted) decides reuse. A relaunch never resumes claiming: running and draining swarms come back paused with a banner." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The `br`/`am` command layer for the swarm

**Files:**
- Create: `Sources/IntakeKit/FlightControl/Swarm/SwarmTasks.swift`
- Create: `Sources/FlightDeck/FlightControl/Swarm/SwarmBackend.swift`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm/br-ready.json`, `br-scheduler.json`, `br-list-open.json`, `br-show.json`, `br-claim-conflict.json`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmTaskDecodingTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/BrSwarmBackendTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/BrSwarmLiveTests.swift` (skipped by default)

**Interfaces:**
- Consumes: `ExecutionBlock`, `ExecutionBlockCodec`, `ExecutionBlockError` (L3-0); `FlywheelProcessRunner`
  (`Sources/FlightDeck/Flywheel/FlywheelProcessRunner.swift:6`); `MultiRunner`
  (`Tests/FlightDeckTests/Flywheel/Observe/ObserveTestSupport.swift`, keyed by exe + first two args).
- Produces (IntakeKit):
  - `struct ReadyTask: Equatable, Identifiable { id; title; priority: Int; rank: Int?; agentContext: String?; var block: Result<ExecutionBlock?, ExecutionBlockError> }`
  - `struct TaskDetail: Equatable { id; title; description; acceptance; status; assignee: String? }`
  - `struct TaskStatusReading: Equatable { status: String; assignee: String? }`
  - `enum ClaimOutcome: Equatable { claimed, conflict, failed(String) }`
  - `enum SwarmTaskDecoding { readyRows(_:) -> [ReadyRow]?; schedulerRanks(_:) -> [String: Int]?; listContexts(_:) -> [String: String]?; detail(_:) -> TaskDetail?; join(ready:ranks:contexts:) -> [ReadyTask]; claimOutcome(exitCode:stdout:) -> ClaimOutcome }`, `struct ReadyRow`
- Produces (app):
  - `struct SwarmBackendError: Error, Equatable { message: String }`
  - `@MainActor protocol SwarmBackend: AnyObject` with `readyTasks(project:)`, `taskDetail(_:project:)`, `status(_:project:)`, `claim(_:actor:project:)`, `returnToOpen(_:project:)`, `writeBlock(_:task:existingContext:project:)`, `releaseReservations(agent:project:)` (exact signatures in Step 9)
  - `@MainActor final class BrSwarmBackend: SwarmBackend { init(runner: FlywheelProcessRunner, brPath: String = "br", amPath: String = "am") }`

- [ ] **Step 1: Probe the real `br` shapes in a scratch repo** (read-only for this checkout)

```bash
P=~/.fd-l3s-probe-br && rm -rf "$P" && mkdir -p "$P" && cd "$P" && git init -q && br init --prefix probe >/dev/null
A=$(br create "first task" -t task -p 1 -d "Do the first thing." --silent)
B=$(br create "second task" -t task -p 2 --silent)
br update "$A" --agent-context '{"flight_deck":{"execution":{"v":1,"kind":"tests","harness":"claude","model":"opus","knobs":{},"pool":"p","source":{"by":"rule","reason":"r","at":"2026-10-04T18:00:00Z"},"pinned":false,"host":null}}}'
br ready --json > ready.json; echo "ready exit $?"
br scheduler --format json > scheduler.json; echo "scheduler exit $?"
br list --status open --json > list.json; echo "list exit $?"
br show "$A" --json > show.json; echo "show exit $?"
br update "$A" --claim --actor ProbeOne --json > claim1.json; echo "claim1 exit $?"
br update "$A" --claim --actor ProbeTwo --json > claim2.out 2> claim2.err; echo "claim2 exit $?"
br update "$A" --status open --assignee "" --actor flight-deck > reopen.out 2>&1; echo "reopen exit $?"
br show "$A" --json > show-after-reopen.json
br list --help | rg -n -- "--limit|has_more" ; rg -n '"has_more"' list.json
```

Record each exit code. Compare with the hand-written fixtures in Step 2 and apply exactly one of:
- **Shapes match** (ready is a bare array with `id/title/priority`; scheduler has
  `schema:"br.scheduler.v1"` and `recommendations[].{rank, issue.id}`; list is `{issues:[…]}` with
  `agent_context` as a string; show is an array or object carrying `description`,
  `acceptance_criteria`, `status`, `assignee`; the second claim exits non-zero and
  `VALIDATION_FAILED` appears in `claim2.out`): keep Step 2's fixtures as written.
- **A field name differs** (for example `acceptance` instead of `acceptance_criteria`): change that
  key in both the fixture and the decoder in Step 7, and add the difference to the deviations
  list in Task 15.
- **`VALIDATION_FAILED` appears only in `claim2.err`**: `FlywheelProcessRunner` discards stderr, so
  `claimOutcome` cannot see it. Keep the decoder as written — a non-zero exit with no recognizable
  code is `.failed`, and the controller treats `.failed` exactly like `.conflict` (drop the task for
  this tick, take the next). Note it in Task 15's deviations.
- **`list.json` has `has_more: true` with fewer rows than `br stats` reports open**: add the
  `--limit` flag `br list --help` names (for example `--limit 0`) to Step 9's `list` argv and to
  the MultiRunner key in Step 10.

Copy the real outputs next to the fixtures as `*.captured.json` (they are evidence, not test
inputs): `cp ready.json scheduler.json list.json show.json claim1.json "$OLDPWD/Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm/"` after renaming each to `br-<name>.captured.json`. Then
`cd "$OLDPWD" && rm -rf "$P"`.

- [ ] **Step 2: Write the hand-written fixtures**

`br-ready.json`:
```json
[
 {"id":"fx-a","title":"Add snapshot tests","status":"open","priority":1,"issue_type":"task","assignee":null},
 {"id":"fx-b","title":"Rewrite the scheduler","status":"open","priority":2,"issue_type":"task","assignee":null},
 {"id":"fx-c","title":"Fix the parser","status":"open","priority":0,"issue_type":"task","assignee":null}
]
```

`br-scheduler.json` (ranks `fx-z`, which is not ready, and leaves `fx-c` unranked):
```json
{"schema":"br.scheduler.v1","generated_at":"2026-10-04T18:00:00Z",
 "recommendations":[
  {"rank":1,"issue":{"id":"fx-b","title":"Rewrite the scheduler"},"score":0.9},
  {"rank":2,"issue":{"id":"fx-z","title":"Blocked elsewhere"},"score":0.8},
  {"rank":3,"issue":{"id":"fx-a","title":"Add snapshot tests"},"score":0.7}
 ]}
```

`br-list-open.json`:
```json
{"issues":[
 {"id":"fx-a","title":"Add snapshot tests","status":"open","priority":1,
  "agent_context":"{\"flight_deck\":{\"execution\":{\"harness\":\"codex\",\"host\":null,\"kind\":\"tests\",\"knobs\":{\"effort\":\"high\"},\"model\":\"gpt-6-sol\",\"pinned\":false,\"pool\":\"codex-subs\",\"source\":{\"at\":\"2026-10-04T18:00:00Z\",\"by\":\"rule\",\"reason\":\"r\",\"ruleId\":\"r1\"},\"v\":1}}}"},
 {"id":"fx-b","title":"Rewrite the scheduler","status":"open","priority":2},
 {"id":"fx-c","title":"Fix the parser","status":"open","priority":0,"agent_context":"{\"instructions\":\"keep\"}"}
],"total":3,"limit":0,"offset":0,"has_more":false}
```

`br-show.json`:
```json
[{"id":"fx-a","title":"Add snapshot tests","status":"in_progress","assignee":"BlueLake",
  "description":"Cover the parser with snapshot tests.","acceptance_criteria":"- every fixture has a snapshot\n- CI passes"}]
```

`br-claim-conflict.json`:
```json
{"error":{"code":"VALIDATION_FAILED","message":"issue fx-a is already claimed by BlueLake","retryable":true}}
```

- [ ] **Step 3: Write the failing decoding tests**

```swift
import XCTest
import IntakeKit

/// The swarm reads four br outputs and joins them. These pin the join's order — the scheduler's
/// rank first, then priority — and the two rules the Review Focus calls out: a ranked task that is
/// not ready is dropped, and `br ready`'s rows carry no `agent_context`, so blocks come from
/// `br list` (probed, br 0.6.0).
final class SwarmTaskDecodingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/FlightControlL3/Swarm")))
    }

    func testReadyRowsDecodeBareArray() throws {
        let rows = try XCTUnwrap(SwarmTaskDecoding.readyRows(fixture("br-ready")))
        XCTAssertEqual(rows.map(\.id), ["fx-a", "fx-b", "fx-c"])
        XCTAssertEqual(rows.map(\.priority), [1, 2, 0])
    }

    func testSchedulerRanksByIssueID() throws {
        let ranks = try XCTUnwrap(SwarmTaskDecoding.schedulerRanks(fixture("br-scheduler")))
        XCTAssertEqual(ranks, ["fx-b": 1, "fx-z": 2, "fx-a": 3])
    }

    func testSchedulerRefusesAnotherSchemaMajor() {
        XCTAssertNil(SwarmTaskDecoding.schedulerRanks(Data(#"{"schema":"br.scheduler.v2","recommendations":[]}"#.utf8)))
    }

    func testListContextsAcceptEnvelopeAndBareArray() throws {
        let contexts = try XCTUnwrap(SwarmTaskDecoding.listContexts(fixture("br-list-open")))
        XCTAssertNotNil(contexts["fx-a"])
        XCTAssertNil(contexts["fx-b"], "a row with no agent_context has no entry")
        XCTAssertEqual(contexts["fx-c"], #"{"instructions":"keep"}"#)
        let bare = try XCTUnwrap(SwarmTaskDecoding.listContexts(Data(#"[{"id":"x","agent_context":"{}"}]"#.utf8)))
        XCTAssertEqual(bare, ["x": "{}"])
    }

    func testJoinOrdersByRankThenPriorityAndDropsRankedButNotReady() throws {
        let tasks = SwarmTaskDecoding.join(
            ready: try XCTUnwrap(SwarmTaskDecoding.readyRows(fixture("br-ready"))),
            ranks: try XCTUnwrap(SwarmTaskDecoding.schedulerRanks(fixture("br-scheduler"))),
            contexts: try XCTUnwrap(SwarmTaskDecoding.listContexts(fixture("br-list-open"))))
        XCTAssertEqual(tasks.map(\.id), ["fx-b", "fx-a", "fx-c"], "fx-z is ranked but not ready")
        XCTAssertEqual(tasks.map(\.rank), [1, 3, nil])
        XCTAssertEqual(try tasks[1].block.get()?.model, "gpt-6-sol")
        XCTAssertNil(try tasks[0].block.get(), "no agent_context is no block")
    }

    func testJoinWithoutRanksFallsBackToPriority() throws {
        let tasks = SwarmTaskDecoding.join(ready: try XCTUnwrap(SwarmTaskDecoding.readyRows(fixture("br-ready"))),
                                           ranks: [:], contexts: [:])
        XCTAssertEqual(tasks.map(\.id), ["fx-c", "fx-a", "fx-b"])
    }

    func testDetailReadsArrayOrObject() throws {
        let d = try XCTUnwrap(SwarmTaskDecoding.detail(fixture("br-show")))
        XCTAssertEqual(d, TaskDetail(id: "fx-a", title: "Add snapshot tests",
                                     description: "Cover the parser with snapshot tests.",
                                     acceptance: "- every fixture has a snapshot\n- CI passes",
                                     status: "in_progress", assignee: "BlueLake"))
        XCTAssertEqual(SwarmTaskDecoding.detail(Data(#"{"id":"x","title":"t","status":"open"}"#.utf8))?.description, "")
    }

    func testClaimOutcome() throws {
        let conflict = String(decoding: try fixture("br-claim-conflict"), as: UTF8.self)
        XCTAssertEqual(SwarmTaskDecoding.claimOutcome(exitCode: 0, stdout: "{}"), .claimed)
        XCTAssertEqual(SwarmTaskDecoding.claimOutcome(exitCode: 1, stdout: conflict), .conflict)
        XCTAssertEqual(SwarmTaskDecoding.claimOutcome(exitCode: 3, stdout: "boom\nmore"), .failed("exit 3: boom"))
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmTaskDecodingTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'SwarmTaskDecoding' in scope`.

- [ ] **Step 5: Implement `SwarmTasks.swift`**

```swift
import Foundation

/// A task the swarm may claim: `br ready`'s row joined to its scheduler rank and its block.
public struct ReadyTask: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var priority: Int
    public var rank: Int?
    public var agentContext: String?
    public init(id: String, title: String, priority: Int, rank: Int?, agentContext: String?) {
        self.id = id; self.title = title; self.priority = priority; self.rank = rank; self.agentContext = agentContext
    }
    /// Decoded on demand, so an invalid block is reported per task and never repaired (L3-0 §4).
    public var block: Result<ExecutionBlock?, ExecutionBlockError> { ExecutionBlockCodec.decode(agentContext: agentContext) }
}

public struct TaskDetail: Equatable, Sendable {
    public var id: String
    public var title: String
    public var description: String
    public var acceptance: String
    public var status: String
    public var assignee: String?
    public init(id: String, title: String, description: String, acceptance: String, status: String, assignee: String?) {
        self.id = id; self.title = title; self.description = description; self.acceptance = acceptance
        self.status = status; self.assignee = assignee
    }
}

public struct TaskStatusReading: Equatable, Sendable {
    public var status: String
    public var assignee: String?
    public init(status: String, assignee: String?) { self.status = status; self.assignee = assignee }
}

/// br's claim is atomic (probed: a second claim fails `VALIDATION_FAILED`, `retryable: true`).
/// `failed` is every other non-zero exit; the controller treats it like a conflict for this tick.
public enum ClaimOutcome: Equatable, Sendable { case claimed, conflict, failed(String) }

public struct ReadyRow: Equatable, Sendable {
    public var id: String
    public var title: String
    public var priority: Int
}

public enum SwarmTaskDecoding {
    private static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// The rows of an envelope `{issues:[…]}` or a bare array — `br ready` is bare, `br list` is
    /// wrapped (observe-command-shapes notes), and the L3-0 fixture is bare.
    private static func rows(_ data: Data) -> [[String: Any]]? {
        switch json(data) {
        case let array as [[String: Any]]: array
        case let object as [String: Any]: object["issues"] as? [[String: Any]]
        default: nil
        }
    }

    public static func readyRows(_ data: Data) -> [ReadyRow]? {
        rows(data)?.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return ReadyRow(id: id, title: row["title"] as? String ?? id, priority: row["priority"] as? Int ?? 2)
        }
    }

    /// `br scheduler --format json`: `{schema:"br.scheduler.v1", recommendations:[{rank, issue:{id}}]}`.
    /// A different schema major is refused (nil) so the caller falls back to priority order rather
    /// than trusting fields it does not know.
    public static func schedulerRanks(_ data: Data) -> [String: Int]? {
        guard let object = json(data) as? [String: Any] else { return nil }
        if let schema = object["schema"] as? String, !schema.hasPrefix("br.scheduler.v1") { return nil }
        guard let recs = object["recommendations"] as? [[String: Any]] else { return nil }
        var ranks: [String: Int] = [:]
        for (index, rec) in recs.enumerated() {
            guard let issue = rec["issue"] as? [String: Any], let id = issue["id"] as? String else { continue }
            ranks[id] = rec["rank"] as? Int ?? index + 1
        }
        return ranks
    }

    /// Task id → its raw `agent_context` string. Rows without one have no entry.
    public static func listContexts(_ data: Data) -> [String: String]? {
        guard let rows = rows(data) else { return nil }
        var out: [String: String] = [:]
        for row in rows {
            if let id = row["id"] as? String, let ctx = row["agent_context"] as? String { out[id] = ctx }
        }
        return out
    }

    public static func detail(_ data: Data) -> TaskDetail? {
        let object: [String: Any]?
        switch json(data) {
        case let array as [[String: Any]]: object = array.first
        case let single as [String: Any]: object = (single["issue"] as? [String: Any]) ?? single
        default: object = nil
        }
        guard let o = object, let id = o["id"] as? String else { return nil }
        return TaskDetail(id: id, title: o["title"] as? String ?? id,
                          description: o["description"] as? String ?? "",
                          acceptance: o["acceptance_criteria"] as? String ?? "",
                          status: o["status"] as? String ?? "unknown",
                          assignee: (o["assignee"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Ready rows in scheduler order. Only READY rows are ever returned: the scheduler ranks the
    /// whole project, and a ranked task that is not ready (blocked, claimed) must never be claimed.
    /// Unranked rows follow, by priority then id, so the order is total and stable.
    public static func join(ready: [ReadyRow], ranks: [String: Int], contexts: [String: String]) -> [ReadyTask] {
        ready.map { ReadyTask(id: $0.id, title: $0.title, priority: $0.priority, rank: ranks[$0.id], agentContext: contexts[$0.id]) }
            .sorted { a, b in
                switch (a.rank, b.rank) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return (a.priority, a.id) < (b.priority, b.id)
                }
            }
    }

    public static func claimOutcome(exitCode: Int32, stdout: String) -> ClaimOutcome {
        if exitCode == 0 { return .claimed }
        if stdout.contains("VALIDATION_FAILED") { return .conflict }
        let first = stdout.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "(no output)"
        return .failed("exit \(exitCode): \(first)")
    }
}
```

- [ ] **Step 6: Run the decoding tests**

Run: `FD_TEST_FILTER=SwarmTaskDecodingTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 7: Write the failing backend tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The backend is argv and nothing else, so these pin the exact argv each swarm action runs — a
/// claim that dropped `--actor` would claim as whoever br thinks the shell is — and that every
/// read degrades rather than throws.
@MainActor
final class BrSwarmBackendTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/tmp/p", isDirectory: true)

    private func fixture(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/FlightControlL3/Swarm"))), as: UTF8.self)
    }

    func testReadyTasksJoinsThreeReads() async throws {
        let fake = MultiRunner()
        fake.responses["br ready --json"] = (try fixture("br-ready"), 0)
        fake.responses["br scheduler --format"] = (try fixture("br-scheduler"), 0)
        fake.responses["br list --status"] = (try fixture("br-list-open"), 0)
        let tasks = try await BrSwarmBackend(runner: fake).readyTasks(project: project).get()
        XCTAssertEqual(tasks.map(\.id), ["fx-b", "fx-a", "fx-c"])
        XCTAssertTrue(fake.argv.contains(["br", "scheduler", "--format", "json"]))
        XCTAssertTrue(fake.argv.contains(["br", "list", "--status", "open", "--json"]))
    }

    func testSchedulerFailureDegradesToPriorityOrder() async throws {
        let fake = MultiRunner()
        fake.responses["br ready --json"] = (try fixture("br-ready"), 0)
        fake.responses["br list --status"] = (try fixture("br-list-open"), 0)
        let tasks = try await BrSwarmBackend(runner: fake).readyTasks(project: project).get()
        XCTAssertEqual(tasks.map(\.id), ["fx-c", "fx-a", "fx-b"])
    }

    func testReadyFailureIsAnError() async {
        let result = await BrSwarmBackend(runner: MultiRunner()).readyTasks(project: project)
        guard case .failure = result else { return XCTFail("no ready list is not an empty ready list") }
    }

    func testClaimArgvAndConflict() async throws {
        let fake = MultiRunner()
        fake.responses["br update fx-a"] = (try fixture("br-claim-conflict"), 1)
        let outcome = await BrSwarmBackend(runner: fake).claim("fx-a", actor: "GreenFox", project: project)
        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(fake.argv.last, ["br", "update", "fx-a", "--claim", "--actor", "GreenFox", "--json"])
    }

    func testReturnToOpenClearsAssignee() async {
        let fake = MultiRunner()
        fake.responses["br update fx-a"] = ("{}", 0)
        let ok = await BrSwarmBackend(runner: fake).returnToOpen("fx-a", project: project)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.argv.last, ["br", "update", "fx-a", "--status", "open", "--assignee", "", "--actor", "flight-deck"])
    }

    func testStatusAndDetailComeFromShow() async throws {
        let fake = MultiRunner()
        fake.responses["br show fx-a"] = (try fixture("br-show"), 0)
        let backend = BrSwarmBackend(runner: fake)
        let status = await backend.status("fx-a", project: project)
        XCTAssertEqual(status, TaskStatusReading(status: "in_progress", assignee: "BlueLake"))
        let detail = await backend.taskDetail("fx-a", project: project)
        XCTAssertEqual(detail?.acceptance, "- every fixture has a snapshot\n- CI passes")
        XCTAssertEqual(fake.argv.last, ["br", "show", "fx-a", "--json"])
    }

    func testWriteBlockMergesIntoExistingContext() async throws {
        let fake = MultiRunner()
        fake.responses["br update fx-c"] = ("{}", 0)
        let block = ExecutionBlock(kind: "tests", harness: "claude", model: "opus", pool: "claude-subs",
                                   source: AssignmentSource(by: .manual, reason: "override", at: Date(timeIntervalSince1970: 1_790_000_000)),
                                   pinned: true)
        let ok = await BrSwarmBackend(runner: fake).writeBlock(block, task: "fx-c",
                                                               existingContext: #"{"instructions":"keep"}"#, project: project)
        XCTAssertTrue(ok)
        let argv = try XCTUnwrap(fake.argv.last)
        XCTAssertEqual(Array(argv.prefix(4)), ["br", "update", "fx-c", "--agent-context"])
        XCTAssertTrue(argv[4].contains(#""instructions":"keep""#))
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: argv[4]).get(), block)
    }

    func testReleaseReservationsArgv() async {
        let fake = MultiRunner()
        fake.responses["am file_reservations release"] = ("", 0)
        _ = await BrSwarmBackend(runner: fake).releaseReservations(agent: "BlueLake", project: project)
        XCTAssertEqual(fake.argv.last, ["am", "file_reservations", "release", "/tmp/p", "BlueLake"])
    }
}
```

- [ ] **Step 8: Run to verify it fails**

Run: `FD_TEST_FILTER=BrSwarmBackendTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'BrSwarmBackend' in scope`.

- [ ] **Step 9: Implement `SwarmBackend.swift`**

```swift
import Foundation
import IntakeKit

struct SwarmBackendError: Error, Equatable { let message: String }

/// Everything the swarm asks of br and am. A protocol so the controller is tested against a
/// scripted fake (`FakeSwarmBackend`) and the argv is tested once, here, against `MultiRunner`.
@MainActor
protocol SwarmBackend: AnyObject {
    func readyTasks(project: URL) async -> Result<[ReadyTask], SwarmBackendError>
    func taskDetail(_ id: String, project: URL) async -> TaskDetail?
    func status(_ id: String, project: URL) async -> TaskStatusReading?
    func claim(_ id: String, actor: String, project: URL) async -> ClaimOutcome
    func returnToOpen(_ id: String, project: URL) async -> Bool
    func writeBlock(_ block: ExecutionBlock, task: String, existingContext: String?, project: URL) async -> Bool
    func releaseReservations(agent: String, project: URL) async -> Bool
}

/// `br`/`am` through the same `FlywheelProcessRunner` seam Observe and release use. Every call
/// runs with `cwd` = the project, which is how br finds `.beads` and how am scopes nothing by
/// accident (the project path is also passed explicitly to `am`, which is one global store).
@MainActor
final class BrSwarmBackend: SwarmBackend {
    private let runner: FlywheelProcessRunner
    private let brPath: String
    private let amPath: String

    init(runner: FlywheelProcessRunner, brPath: String = "br", amPath: String = "am") {
        self.runner = runner; self.brPath = brPath; self.amPath = amPath
    }

    private func run(_ exe: String, _ args: [String], _ project: URL) async -> (stdout: String, exitCode: Int32)? {
        try? await runner.run(exe, args, cwd: project.path)
    }

    func readyTasks(project: URL) async -> Result<[ReadyTask], SwarmBackendError> {
        guard let ready = await run(brPath, ["ready", "--json"], project), ready.exitCode == 0,
              let rows = SwarmTaskDecoding.readyRows(Data(ready.stdout.utf8)) else {
            return .failure(SwarmBackendError(message: "br ready failed"))
        }
        // A scheduler that fails or changes schema degrades to priority order rather than
        // stopping the swarm: the ready set is what must be right, the order is a preference.
        let scheduler = await run(brPath, ["scheduler", "--format", "json"], project)
        let ranks = scheduler.flatMap { $0.exitCode == 0 ? SwarmTaskDecoding.schedulerRanks(Data($0.stdout.utf8)) : nil } ?? [:]
        // `br ready` does not carry `agent_context` (probed, br 0.6.0), so blocks come from here.
        let list = await run(brPath, ["list", "--status", "open", "--json"], project)
        let contexts = list.flatMap { $0.exitCode == 0 ? SwarmTaskDecoding.listContexts(Data($0.stdout.utf8)) : nil } ?? [:]
        return .success(SwarmTaskDecoding.join(ready: rows, ranks: ranks, contexts: contexts))
    }

    func taskDetail(_ id: String, project: URL) async -> TaskDetail? {
        guard let out = await run(brPath, ["show", id, "--json"], project), out.exitCode == 0 else { return nil }
        return SwarmTaskDecoding.detail(Data(out.stdout.utf8))
    }

    func status(_ id: String, project: URL) async -> TaskStatusReading? {
        await taskDetail(id, project: project).map { TaskStatusReading(status: $0.status, assignee: $0.assignee) }
    }

    func claim(_ id: String, actor: String, project: URL) async -> ClaimOutcome {
        guard let out = await run(brPath, ["update", id, "--claim", "--actor", actor, "--json"], project) else {
            return .failed("br did not run")
        }
        return SwarmTaskDecoding.claimOutcome(exitCode: out.exitCode, stdout: out.stdout)
    }

    /// The same argv release delivery's reclaim uses (`IntakeDelivery.swift:96`); `--assignee ""`
    /// was probed to clear the assignee to null.
    func returnToOpen(_ id: String, project: URL) async -> Bool {
        await run(brPath, ["update", id, "--status", "open", "--assignee", "", "--actor", "flight-deck"], project)?.exitCode == 0
    }

    /// Read-merge-write: the block is merged into whatever `agent_context` already holds, so br's
    /// own governing instructions in the same field survive an override.
    func writeBlock(_ block: ExecutionBlock, task: String, existingContext: String?, project: URL) async -> Bool {
        guard let json = try? ExecutionBlockCodec.encode(block, into: existingContext) else { return false }
        return await run(brPath, ["update", task, "--agent-context", json], project)?.exitCode == 0
    }

    func releaseReservations(agent: String, project: URL) async -> Bool {
        await run(amPath, ["file_reservations", "release", project.path, agent], project)?.exitCode == 0
    }
}
```

- [ ] **Step 10: Run the backend tests**

Run: `FD_TEST_FILTER=BrSwarmBackendTests,SwarmTaskDecodingTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 16 tests, with 0 failures`.

- [ ] **Step 11: Add the live probe test (skipped by default)**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Re-runs Step 1's probe through the real backend, so a br upgrade that changes ready/scheduler/
/// show/claim shapes fails here instead of in a swarm. Skipped unless `BR_LIVE=1` or
/// `TEST_RUNNER_BR_LIVE=1`, and when br is not at ~/.local/bin/br.
@MainActor
final class BrSwarmLiveTests: XCTestCase {
    func testClaimRaceAndReadyJoinAgainstRealBr() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BR_LIVE"] == "1" || env["TEST_RUNNER_BR_LIVE"] == "1" else { throw XCTSkip("set BR_LIVE=1") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let br = home.appendingPathComponent(".local/bin/br").path
        guard FileManager.default.isExecutableFile(atPath: br) else { throw XCTSkip("br not at ~/.local/bin/br") }
        let dir = home.appendingPathComponent(".fd-l3s-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = SystemFlywheelProcessRunner()
        _ = try await runner.run("/usr/bin/git", ["init", "-q"], cwd: dir.path)
        _ = try await runner.run(br, ["init", "--prefix", "live"], cwd: dir.path)
        let id = try await runner.run(br, ["create", "live task", "-t", "task", "--silent"], cwd: dir.path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = BrSwarmBackend(runner: runner, brPath: br)
        XCTAssertEqual(try await backend.readyTasks(project: dir).get().map(\.id), [id])
        let first = await backend.claim(id, actor: "LiveOne", project: dir)
        XCTAssertEqual(first, .claimed)
        let second = await backend.claim(id, actor: "LiveTwo", project: dir)
        XCTAssertNotEqual(second, .claimed, "br's claim must be atomic")
        let status = await backend.status(id, project: dir)
        XCTAssertEqual(status, TaskStatusReading(status: "in_progress", assignee: "LiveOne"))
        let reopened = await backend.returnToOpen(id, project: dir)
        XCTAssertTrue(reopened)
        let after = await backend.status(id, project: dir)
        XCTAssertEqual(after?.status, "open")
        XCTAssertNil(after?.assignee)
    }
}
```

Run: `BR_LIVE=1 FD_TEST_FILTER=BrSwarmLiveTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 1 test, with 0 failures` and the test not skipped. If `test-unit.sh` does not forward
`BR_LIVE`, rerun with `TEST_RUNNER_BR_LIVE=1`. Then the default run:
`FD_TEST_FILTER=BrSwarmLiveTests ./scripts/test-unit.sh 2>&1 | tail -5` → `1 skipped`.

- [ ] **Step 12: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Swarm/SwarmTasks.swift Sources/FlightDeck/FlightControl/Swarm/SwarmBackend.swift Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmTaskDecodingTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/BrSwarmBackendTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/BrSwarmLiveTests.swift
git commit -m "feat: read ready tasks in scheduler order and claim them through br" -m "The swarm joins br ready (the ready set), br scheduler (the order) and br list (the blocks, which br ready does not carry). A ranked task that is not ready is dropped. Claims run br update --claim --actor <agent>; a VALIDATION_FAILED is a conflict, any other non-zero exit a failure the controller skips for one tick." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The task prompt

**Files:**
- Create: `Sources/IntakeKit/FlightControl/Swarm/TaskPrompt.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/TaskPromptTests.swift`

**Interfaces:**
- Consumes: `TaskDetail` (Task 2).
- Produces: `public enum TaskPrompt { static let budget = 7_500; static func text(for: TaskDetail) -> String }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
import FleetKit

/// The first prompt is typed into a live agent through the same gate a phone prompt uses
/// (`PromptText`), so it must always pass that gate — a description pasted with a carriage return
/// or a ten-thousand-character spec would otherwise be refused and the agent would sit idle.
final class TaskPromptTests: XCTestCase {
    func testTemplateIsTheSpecs() {
        let text = TaskPrompt.text(for: TaskDetail(id: "fd-3x9", title: "Add snapshot tests",
                                                   description: "Cover the parser.",
                                                   acceptance: "- every fixture has a snapshot",
                                                   status: "in_progress", assignee: "BlueLake"))
        XCTAssertEqual(text, """
            Your task is fd-3x9: Add snapshot tests.

            Cover the parser.

            Acceptance criteria:
            - every fixture has a snapshot

            Reserve the files you will edit with Agent Mail before you edit them.
            When the acceptance criteria hold and your work is committed, run `br close fd-3x9`.
            If you are blocked, say so in one line that starts with BLOCKED:, then stop.
            """)
    }

    func testEmptySectionsAreOmitted() {
        let text = TaskPrompt.text(for: TaskDetail(id: "a", title: "T", description: "  ", acceptance: "",
                                                   status: "open", assignee: nil))
        XCTAssertFalse(text.contains("Acceptance criteria:"))
        XCTAssertTrue(text.hasPrefix("Your task is a: T.\n\nReserve the files"))
    }

    func testControlCharactersAreStrippedSoThePromptPassesTheGate() {
        let text = TaskPrompt.text(for: TaskDetail(id: "a", title: "T", description: "line1\r\nline2\u{1B}[0m\u{07}",
                                                   acceptance: "ok\tfine", status: "open", assignee: nil))
        XCTAssertNil(PromptText.rejection(for: text))
        XCTAssertTrue(text.contains("line1\nline2[0m"))
        XCTAssertTrue(text.contains("ok\tfine"))
    }

    func testLongBodiesAreCutToTheBudgetWithAPointer() {
        let long = String(repeating: "word ", count: 4_000)
        let text = TaskPrompt.text(for: TaskDetail(id: "fd-1", title: "T", description: long, acceptance: long,
                                                   status: "open", assignee: nil))
        XCTAssertLessThanOrEqual(text.count, TaskPrompt.budget)
        XCTAssertNil(PromptText.rejection(for: text))
        XCTAssertTrue(text.contains("run `br show fd-1` for the rest"))
        XCTAssertTrue(text.hasSuffix("If you are blocked, say so in one line that starts with BLOCKED:, then stop."))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=TaskPromptTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'TaskPrompt' in scope`.

- [ ] **Step 3: Implement `TaskPrompt.swift`**

```swift
import Foundation

/// The first prompt a swarm agent gets (spec §4 step 6). Agent-facing text: it names `br`
/// commands verbatim, which is why it is built here and not as UI copy.
public enum TaskPrompt {
    /// Under `PromptText.maxCharacters` (8,000) with room to spare, so the prompt always passes
    /// the gate `SessionStore.submitPrompt` applies to every typed prompt.
    public static let budget = 7_500

    public static func text(for task: TaskDetail) -> String {
        let head = "Your task is \(task.id): \(clean(task.title))."
        let tail = """
            Reserve the files you will edit with Agent Mail before you edit them.
            When the acceptance criteria hold and your work is committed, run `br close \(task.id)`.
            If you are blocked, say so in one line that starts with BLOCKED:, then stop.
            """
        var description = clean(task.description).trimmingCharacters(in: .whitespacesAndNewlines)
        var acceptance = clean(task.acceptance).trimmingCharacters(in: .whitespacesAndNewlines)
        let pointer = "… (cut; run `br show \(task.id)` for the rest)"

        func assemble() -> String {
            var parts = [head]
            if !description.isEmpty { parts.append(description) }
            if !acceptance.isEmpty { parts.append("Acceptance criteria:\n" + acceptance) }
            parts.append(tail)
            return parts.joined(separator: "\n\n")
        }

        // Cut the description first (the agent can `br show` it), then the criteria, never the
        // instructions: those are what make the swarm work at all.
        var text = assemble()
        if text.count > budget {
            let over = text.count - budget
            if description.count > over + pointer.count {
                description = String(description.prefix(description.count - over - pointer.count)) + pointer
            } else {
                description = pointer
            }
            text = assemble()
        }
        if text.count > budget {
            let over = text.count - budget
            acceptance = acceptance.count > over + pointer.count
                ? String(acceptance.prefix(acceptance.count - over - pointer.count)) + pointer
                : pointer
            text = assemble()
        }
        return text
    }

    /// CRLF to LF, and every C0 control but newline and tab dropped, with DEL — the set
    /// `PromptText.rejection` refuses. An escape sequence inside a paste can close the bracketed
    /// paste early and turn the rest into keystrokes.
    private static func clean(_ s: String) -> String {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(normalized.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F)
        }))
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `FD_TEST_FILTER=TaskPromptTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 4 tests, with 0 failures`. Also run `FD_TEST_FILTER=TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
→ 0 failures (the prompt names no banned word).

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Swarm/TaskPrompt.swift Tests/FlightDeckTests/FlightControlL3/Swarm/TaskPromptTests.swift
git commit -m "feat: compose a swarm agent's first prompt from its task" -m "The template is spec §4's: the task line, description, acceptance criteria, then the reserve/close/BLOCKED instructions. Control characters are stripped and long bodies are cut to 7,500 characters so the prompt always passes the PromptText gate submitPrompt applies." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 4a: Launch overrides reach `createSession`, and claude/codex map them

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Swarm/LaunchOverrideMapping.swift`
- Modify: `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift` (the two `applying` bodies)
- Modify: `Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift` (`reasoningEffort`)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`routingCapabilities`, `launchOptions`, `createSession`, `newSession`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/LaunchOverrideMappingTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/CreateSessionOverridesTests.swift`

**Interfaces:**
- Consumes: `LaunchOverrides`, `RoutingCapability`, `RoutingCapabilityRegistry`, `AgentID.harnessID` (L3-0);
  `FlagSet.values` (`Preferences/FlagSet.swift:19`), `CodexThreadOptions` (`Agents/Codex/CodexThreadOptions.swift:5`),
  `AgentLaunchError.prepareFailed` (`Agents/Codex/CodexProcessTransport.swift:14`).
- Produces:
  - `enum ClaudeLaunchOverrides { static func apply(_: LaunchOverrides, to: AgentOptions) -> RoutingCapability<AgentOptions> }`
  - `enum CodexLaunchOverrides { static func apply(_: LaunchOverrides, to: AgentOptions) -> RoutingCapability<AgentOptions> }`
  - `CodexThreadOptions.reasoningEffort: String?` → `thread/start` `config.model_reasoning_effort`
  - `SessionStore.routingCapabilities: RoutingCapabilityRegistry` (lazy, `.standard()`; settable for tests and integration)
  - `SessionStore.launchOptions(for:project:overrides:) -> Result<AgentOptions, AgentLaunchError>`
  - `SessionStore.createSession(agent:in:at:account:selecting:overrides:) async -> Result<UUID, AgentLaunchError>` (new trailing `overrides: LaunchOverrides? = nil`)
  - `SessionStore.newSession(in:at:account:waking:selecting:flywheelIdentity:overrides:)` (new trailing `overrides: LaunchOverrides? = nil`)

- [ ] **Step 1: Verify the codex config key before writing code**

```bash
S=$(mktemp -d "$HOME/.fd-l3s-codex-schema.XXXX")
codex app-server generate-json-schema --out "$S" >/dev/null 2>&1; echo "exit $?"
rg -n '"config"' "$S" | rg -i "ThreadStart" | head -3
rg -n -i "model_reasoning_effort|reasoning_effort|\"effort\"" "$S" | head -10
rm -rf "$S"
```

Apply exactly one:
- **`ThreadStartParams` has a `config` object** (expected; `CodexThreadOptions.asThreadStartParams`
  already sends `config` for `addDirs`): implement Step 5 as written — effort travels as
  `config["model_reasoning_effort"]`, codex's own `config.toml` key.
- **`ThreadStartParams` has a top-level `effort` field**: change Step 5's
  `asThreadStartParams` line to `params["effort"] = reasoningEffort` instead of the config key,
  change Step 1's expected dictionary in `testCodexEffortTravelsAsConfig` to `params["effort"]`,
  and record it in Task 15's deviations.
- **Neither, or `generate-json-schema` fails**: keep the config route (it is the `-c` override
  mechanism and codex ignores unknown keys rather than failing), and record "codex effort unverified" in Task 15.

- [ ] **Step 2: Write the failing mapping tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// A block's model and knobs reach a launch only through the agent's own capability, so these pin
/// the one translation each agent does — claude to command-line flags, codex to thread params — and
/// that a knob an agent does not have is refused, never dropped: a task routed to "effort=max" that
/// launched at the default would be the silent wrong-model failure routing exists to prevent.
@MainActor
final class LaunchOverrideMappingTests: XCTestCase {
    func testClaudeModelAndEffortBecomeFlags() throws {
        let result = ClaudeLaunchOverrides.apply(LaunchOverrides(model: "opus", knobs: ["effort": "high"]),
                                                 to: .claude(FlagSet(values: ["--verbose": .on])))
        guard case .supported(.claude(let flags)) = result else { return XCTFail("expected claude flags") }
        XCTAssertEqual(flags.values["--model"], .value("opus"))
        XCTAssertEqual(flags.values["--effort"], .value("high"))
        XCTAssertEqual(flags.values["--verbose"], .on, "preferences under the override survive")
    }

    func testClaudeRefusesAnUnknownKnob() {
        guard case .unsupported(let reason) = ClaudeLaunchOverrides.apply(
            LaunchOverrides(model: nil, knobs: ["agent": "build"]), to: .claude(FlagSet())) else {
            return XCTFail("an unknown knob must be refused")
        }
        XCTAssertTrue(reason.contains("agent"))
    }

    func testCodexModelAndEffortBecomeThreadOptions() {
        let result = CodexLaunchOverrides.apply(LaunchOverrides(model: "gpt-6-sol", knobs: ["effort": "high"]),
                                                to: .codex(CodexThreadOptions(sandbox: "read-only")))
        guard case .supported(.codex(let options)) = result else { return XCTFail("expected codex options") }
        XCTAssertEqual(options.model, "gpt-6-sol")
        XCTAssertEqual(options.reasoningEffort, "high")
        XCTAssertEqual(options.sandbox, "read-only")
    }

    func testCodexEffortTravelsAsConfig() {
        let params = CodexThreadOptions(model: "m", addDirs: ["/x"], reasoningEffort: "high")
            .asThreadStartParams(cwd: "/p", historyMode: nil)
        let config = params["config"] as? [String: Any]
        XCTAssertEqual(config?["model_reasoning_effort"] as? String, "high")
        XCTAssertNotNil(config?["sandbox_workspace_write"], "the addDirs override still rides along")
        XCTAssertNil(CodexThreadOptions(model: "m").asThreadStartParams(cwd: "/p", historyMode: nil)["config"],
                     "no override means no config key — an empty one would replace config.toml's")
    }

    func testWrongOptionsShapeIsRefused() {
        guard case .unsupported = ClaudeLaunchOverrides.apply(LaunchOverrides(model: "x", knobs: [:]),
                                                              to: .codex(CodexThreadOptions())) else {
            return XCTFail("claude must not accept codex options")
        }
    }

    func testStandardRegistryNowSupportsOverridesForBothAgents() {
        let registry = RoutingCapabilityRegistry.standard()
        for id in AgentID.allCases {
            let base: AgentOptions = id == .claude ? .claude(FlagSet()) : .codex(CodexThreadOptions())
            guard case .supported = registry.capabilities(for: id.harnessID)!
                .applying(LaunchOverrides(model: "m", knobs: [:]), to: base) else {
                return XCTFail("\(id) should map a model override")
            }
        }
    }
}
```

L3-0's `RoutingCapabilityRegistryTests.testStubsSayUnsupportedRatherThanFake` asserts the opposite
of the last test. Delete that one test method from
`Tests/FlightDeckTests/FlightControlL3/RoutingCapabilityRegistryTests.swift` in this step (it was
written for the stubs this task replaces; `testStandardRegistryNowSupportsOverridesForBothAgents`
supersedes it).

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=LaunchOverrideMappingTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'ClaudeLaunchOverrides' in scope`.

- [ ] **Step 4: Implement `LaunchOverrideMapping.swift`**

```swift
import Foundation
import IntakeKit

/// Claude's half of `AgentRoutingCapabilities.applying`: a model and knobs become command-line
/// flags laid over the project's resolved `FlagSet`. Only `effort` is a claude knob today
/// (`ClaudeFlagCatalog`'s `--effort`); any other knob is refused rather than dropped.
enum ClaudeLaunchOverrides {
    static func apply(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        guard case .claude(var flags) = options else { return .unsupported(reason: "claude was handed codex options") }
        if let model = overrides.model { flags.values["--model"] = .value(model) }
        for (knob, value) in overrides.knobs.sorted(by: { $0.key < $1.key }) {
            switch knob {
            case "effort": flags.values["--effort"] = .value(value)
            default: return .unsupported(reason: "claude has no knob \(knob)")
            }
        }
        return .supported(.claude(flags))
    }
}

/// Codex's half: typed `thread/start` params. `effort` becomes `reasoningEffort`, which
/// `CodexThreadOptions.asThreadStartParams` sends as codex's own `model_reasoning_effort` key.
enum CodexLaunchOverrides {
    static func apply(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        guard case .codex(var thread) = options else { return .unsupported(reason: "codex was handed claude options") }
        if let model = overrides.model { thread.model = model }
        for (knob, value) in overrides.knobs.sorted(by: { $0.key < $1.key }) {
            switch knob {
            case "effort": thread.reasoningEffort = value
            default: return .unsupported(reason: "codex has no knob \(knob)")
            }
        }
        return .supported(.codex(thread))
    }
}
```

- [ ] **Step 5: Add `reasoningEffort` to `CodexThreadOptions`**

In `Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift`, add the property after `addDirs`,
extend the initializer with a trailing defaulted parameter, merge it, and send it:

```swift
    var addDirs: [String]
    /// A swarm task's `effort` knob (L3-S). Sent as codex's own `model_reasoning_effort` config
    /// key, never a param of ours; nil sends nothing, so `config.toml` keeps deciding.
    var reasoningEffort: String?

    init(model: String? = nil, sandbox: String? = nil, approvalPolicy: String? = nil, addDirs: [String] = [],
         reasoningEffort: String? = nil) {
        self.model = model
        self.sandbox = sandbox
        self.approvalPolicy = approvalPolicy
        self.addDirs = addDirs
        self.reasoningEffort = reasoningEffort
    }
```

Replace the body of `asThreadStartParams(cwd:historyMode:)` with:

```swift
        var params: [String: Any] = ["cwd": cwd]
        if let model { params["model"] = model }
        if let sandbox { params["sandbox"] = sandbox }
        if let approvalPolicy { params["approvalPolicy"] = approvalPolicy }
        if let historyMode { params["historyMode"] = historyMode }
        var config: [String: Any] = [:]
        if !addDirs.isEmpty {
            params["addDirs"] = addDirs
            // `sandbox_workspace_write.writable_roots` is codex's own config key — see
            // `SandboxWorkspaceWrite` in the generated schema. Only sent when there is
            // something to say: an empty override is still an override, and would replace
            // whatever the user's `config.toml` set.
            config["sandbox_workspace_write"] = ["writable_roots": addDirs]
        }
        if let reasoningEffort { config["model_reasoning_effort"] = reasoningEffort }
        if !config.isEmpty { params["config"] = config }
        return params
```

and in `merge(global:project:)` add `reasoningEffort: project.reasoningEffort ?? global.reasoningEffort`
as the last argument of the `CodexThreadOptions(...)` call.

- [ ] **Step 6: Fill the two `applying` stubs**

In `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift`, replace the `applying` line in
`ClaudeRoutingCapabilities` with:

```swift
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        ClaudeLaunchOverrides.apply(overrides, to: options)
    }
```

and in `CodexRoutingCapabilities` with:

```swift
    func applying(_ overrides: LaunchOverrides, to options: AgentOptions) -> RoutingCapability<AgentOptions> {
        CodexLaunchOverrides.apply(overrides, to: options)
    }
```

(L3-R fills `modelCatalog`/`knobSchema` and L3-U fills the meter/transcript lines in the same two
classes; those are adjacent lines, so expect a trivial textual merge at integration.)

- [ ] **Step 7: Run the mapping tests**

Run: `FD_TEST_FILTER=LaunchOverrideMappingTests,RoutingCapabilityRegistryTests,CodexThreadOptionsTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. If `CodexThreadOptionsTests` does not exist, `test-unit.sh` names the
misspelled class — drop it from the filter (`rg -ln "CodexThreadOptions" Tests` lists the real ones;
run those instead).

- [ ] **Step 8: Write the failing store-level override tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// What a swarm spawn types at the shell. The launch command is the only observable evidence that
/// an override reached the agent, so it is asserted directly, through the real `createSession`.
@MainActor
final class CreateSessionOverridesTests: XCTestCase {
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { configs.append(config); return nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }
    private var retained: [RecordingProvider] = []
    override func tearDown() { retained = [] }

    private func makeStore() -> (SessionStore, RecordingProvider) {
        let provider = RecordingProvider(); retained.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store.transcriptsRootOverride = root.appendingPathComponent("projects")
        store.statusRootOverride = root.appendingPathComponent("status")
        return (store, provider)
    }

    func testClaudeSpawnLaunchesWithTheBlocksModelAndEffort() async throws {
        let (store, provider) = makeStore()
        let id = try await store.createSession(agent: .claude, in: "/tmp/p", selecting: false,
                                               overrides: LaunchOverrides(model: "opus", knobs: ["effort": "high"])).get()
        XCTAssertTrue(store.sessionExists(id))
        let input = try XCTUnwrap(provider.configs.last?.initialInput)
        XCTAssertTrue(input.contains("--model opus"), input)
        XCTAssertTrue(input.contains("--effort high"), input)
    }

    func testNoOverridesLaunchesExactlyAsBefore() async throws {
        let (store, provider) = makeStore()
        _ = try await store.createSession(agent: .claude, in: "/tmp/p", selecting: false).get()
        XCTAssertFalse(try XCTUnwrap(provider.configs.last?.initialInput).contains("--model"))
    }

    func testAnUnmappableOverrideRefusesTheTabBeforeCreatingIt() async {
        let (store, provider) = makeStore()
        let result = await store.createSession(agent: .claude, in: "/tmp/p", selecting: false,
                                               overrides: LaunchOverrides(model: nil, knobs: ["persona": "x"]))
        guard case .failure(.prepareFailed(let why)) = result else { return XCTFail("expected a refusal") }
        XCTAssertTrue(why.contains("persona"))
        XCTAssertTrue(provider.configs.isEmpty, "a refused override must not open a tab")
    }

    func testLaunchOptionsAppliesThroughTheRegistry() throws {
        let (store, _) = makeStore()
        let fake = FakeRoutingCapabilities(); fake.harness = "claude"
        fake.overridesResult = .unsupported(reason: "nope")
        store.routingCapabilities = RoutingCapabilityRegistry([fake])
        guard case .failure(.prepareFailed("nope")) = store.launchOptions(
            for: .claude, project: "/tmp/p", overrides: LaunchOverrides(model: "m", knobs: [:])) else {
            return XCTFail("the registry's answer must decide")
        }
        XCTAssertEqual(fake.overrideCalls, [LaunchOverrides(model: "m", knobs: [:])])
    }
}
```

- [ ] **Step 9: Run to verify it fails**

Run: `FD_TEST_FILTER=CreateSessionOverridesTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `extra argument 'overrides' in call`.

- [ ] **Step 10: Thread overrides through `SessionStore`**

1. Add the registry next to `flywheelNotifier` (`rg -n "var flywheelNotifier: FlywheelNotifier\?" Sources/FlightDeck/SessionStore.swift`):

```swift
    /// Every agent's Level 3 capabilities, keyed by harness. Lazily the standard set; settable so
    /// a test can register a fake harness and the integration branch can swap in real conformers.
    lazy var routingCapabilities: RoutingCapabilityRegistry = .standard()
```

2. Add `launchOptions` directly below the private `options(for:project:)` (`SessionStore.swift:488`):

```swift
    /// The options a tab launches with: the project's resolved preferences, with a swarm task's
    /// overrides laid on top by the agent's own routing capability. Overrides the agent cannot
    /// apply refuse the launch — a task routed to a model must never quietly run on another.
    func launchOptions(for agent: AgentID, project: String, overrides: LaunchOverrides?) -> Result<AgentOptions, AgentLaunchError> {
        let base = options(for: agent, project: project)
        guard let overrides, overrides.model != nil || !overrides.knobs.isEmpty else { return .success(base) }
        guard let capabilities = routingCapabilities.capabilities(for: agent.harnessID) else {
            return .failure(.prepareFailed("\(agent.displayName) has no routing capabilities"))
        }
        switch capabilities.applying(overrides, to: base) {
        case .supported(let applied): return .success(applied)
        case .unsupported(let reason): return .failure(.prepareFailed(reason))
        }
    }
```

3. `newSession` (`SessionStore.swift:2217`): add `overrides: LaunchOverrides? = nil` as the last
   parameter, and replace its line `let options = options(for: session.agent, project: url.path)`
   with:

```swift
        // `createSession` has already refused an override this agent cannot apply, so a failure
        // here is unreachable from it; the plain preferences are the right answer for any other
        // caller that passed overrides directly.
        let options = (try? launchOptions(for: session.agent, project: url.path, overrides: overrides).get())
            ?? options(for: session.agent, project: url.path)
```

4. `createSession` (`SessionStore.swift:2278`): add `overrides: LaunchOverrides? = nil` as the last
   parameter. Directly after the `launchAccount` switch (before `guard agent.negotiatesIdentity`),
   insert:

```swift
        // Checked before anything is created on either branch, so an override the agent cannot
        // apply refuses the tab rather than launching it on the project's defaults.
        let launchOptions: AgentOptions
        switch self.launchOptions(for: agent, project: directory, overrides: overrides) {
        case .success(let resolved): launchOptions = resolved
        case .failure(let error):
            launchFailureReporter.report(error)
            return .failure(error)
        }
```

   In the claude branch's `newSession(...)` call add `overrides: overrides`. In the codex branch,
   replace `let options = options(for: agent, project: directory)` with `let options = launchOptions`.

- [ ] **Step 11: Run the override tests and the existing creation suites**

Run: `FD_TEST_FILTER=CreateSessionOverridesTests,LaunchOverrideMappingTests,AccountLaunchTests,AccountSignInTests,CodexLaunchFailureTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 12: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/LaunchOverrideMapping.swift Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/FlightControlL3/Swarm/LaunchOverrideMappingTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/CreateSessionOverridesTests.swift Tests/FlightDeckTests/FlightControlL3/RoutingCapabilityRegistryTests.swift
git commit -m "feat: launch a session with a task's model and knobs" -m "createSession and newSession take LaunchOverrides and lay them over the project's preferences through the agent's routing capability: claude gets --model/--effort flags, codex gets thread/start model and config.model_reasoning_effort. An override the agent cannot apply refuses the tab before anything is created, rather than launching it on defaults." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4b: `resetContext` for claude and codex

**Files:**
- Modify: `Sources/FlightDeck/FlightControl/Swarm/LaunchOverrideMapping.swift` (append `SessionCommandSink`, `CommandSinkAttachable`, `ContextReset`)
- Modify: `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift` (`commands` property + `resetContext` bodies)
- Modify: `Sources/FlightDeck/SessionStore.swift` (attach the sink; conformance)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/ContextResetTests.swift`

**Interfaces:**
- Consumes: `SessionStore.submitPrompt(_:token:to:) -> PromptDispatch` (`SessionStore.swift:5699`).
- Produces:
  - `@MainActor protocol SessionCommandSink: AnyObject { func submitCommand(_ text: String, to session: UUID) -> SessionStore.PromptDispatch }` — `SessionStore` conforms
  - `@MainActor protocol CommandSinkAttachable: AnyObject { var commands: SessionCommandSink? { get set } }` — claude/codex capability classes conform
  - `extension RoutingCapabilityRegistry { func attachCommandSink(_:) }`
  - `enum ContextResetError: Error, Equatable { refused(String) }`
  - `enum ContextReset { static let claudeCommand = "/clear"; static let codexCommand = "/new"; static func typing(_:into:via:) throws -> RoutingCapability<Void> }`

- [ ] **Step 1: Verify codex's reset command**

```bash
CODEX_REAL=$(realpath "$(command -v codex)")
NATIVE=$(find "$(dirname "$CODEX_REAL")/.." -type f -perm -u+x \( -name codex -o -name 'codex-*' \) 2>/dev/null | head -5)
echo "$NATIVE"
for f in $NATIVE; do strings -a "$f" 2>/dev/null | rg -m3 -i "start a new chat|/new\b"; done
```

- **A line naming `/new` (for example "start a new chat during a conversation") is printed:** keep
  `ContextReset.codexCommand = "/new"` as written. Codex starts a new thread on it; the existing
  `CodexPinReconciler` re-pins the tab within its 5 s throttle, as it does for any thread change.
- **Nothing is printed:** change `CodexRoutingCapabilities.resetContext` in Step 4 to
  `return .unsupported(reason: "codex has no verified reset command")`, change
  `testCodexResetTypesNew` to assert `.unsupported`, and note it in Task 15. The controller treats
  an unsupported reset as a failed one and spawns a fresh agent (spec §10), so codex swarms still
  work, just without reuse.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Reuse depends on one property: the reset is typed through the same gated channel a phone
/// prompt is, so it lands only into a real composer and queues behind a running turn instead of
/// being pasted into a dialog. A refusal must throw — a reset that "succeeded" without typing
/// would hand the next task an agent still holding the last task's context.
@MainActor
final class ContextResetTests: XCTestCase {
    private final class Sink: SessionCommandSink {
        var answer: SessionStore.PromptDispatch = .queued
        private(set) var typed: [(String, UUID)] = []
        func submitCommand(_ text: String, to session: UUID) -> SessionStore.PromptDispatch {
            typed.append((text, session)); return answer
        }
    }

    func testClaudeResetTypesClear() async throws {
        let sink = Sink(); let caps = ClaudeRoutingCapabilities(); caps.commands = sink
        let session = Session(title: "t", workingDirectory: "/p")
        guard case .supported = try await caps.resetContext(session) else { return XCTFail("expected supported") }
        XCTAssertEqual(sink.typed.map { $0.0 }, ["/clear"])
        XCTAssertEqual(sink.typed.map { $0.1 }, [session.id])
    }

    func testCodexResetTypesNew() async throws {
        let sink = Sink(); let caps = CodexRoutingCapabilities(); caps.commands = sink
        guard case .supported = try await caps.resetContext(Session(title: "t", workingDirectory: "/p", agent: .codex)) else {
            return XCTFail("expected supported")
        }
        XCTAssertEqual(sink.typed.map { $0.0 }, ["/new"])
    }

    func testARefusedTypeThrows() async {
        let sink = Sink(); sink.answer = .notRunning
        let caps = ClaudeRoutingCapabilities(); caps.commands = sink
        do {
            _ = try await caps.resetContext(Session(title: "t", workingDirectory: "/p"))
            XCTFail("a refusal must throw")
        } catch {
            XCTAssertEqual(error as? ContextResetError, .refused("not_running"))
        }
    }

    func testNoSinkIsUnsupportedNotSuccess() async throws {
        guard case .unsupported = try await ClaudeRoutingCapabilities().resetContext(Session(title: "t", workingDirectory: "/p")) else {
            return XCTFail("an unattached capability must say it cannot reset")
        }
    }

    func testTheStoreAttachesItselfToTheStandardRegistry() async throws {
        let store = SessionStore(provider: nil, persistence: nil)
        let claude = try XCTUnwrap(store.routingCapabilities.capabilities(for: "claude") as? ClaudeRoutingCapabilities)
        XCTAssertTrue(claude.commands === store)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=ContextResetTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find type 'SessionCommandSink' in scope`.

- [ ] **Step 4: Implement**

Append to `LaunchOverrideMapping.swift`:

```swift
/// The one way a routing capability may type into a tab: the store's own prompt gate, which
/// waits for a real composer and queues behind a running turn.
@MainActor
protocol SessionCommandSink: AnyObject {
    func submitCommand(_ text: String, to session: UUID) -> SessionStore.PromptDispatch
}

/// Capabilities are built by `RoutingCapabilityRegistry.standard()` with no arguments, so the
/// sink is attached afterwards rather than injected.
@MainActor
protocol CommandSinkAttachable: AnyObject {
    var commands: SessionCommandSink? { get set }
}

extension RoutingCapabilityRegistry {
    func attachCommandSink(_ sink: SessionCommandSink) {
        for harness in harnesses { (capabilities(for: harness) as? CommandSinkAttachable)?.commands = sink }
    }
}

enum ContextResetError: Error, Equatable { case refused(String) }

/// A context reset is a slash command typed into the agent's own composer: `/clear` for claude,
/// `/new` for codex (a new thread, which `CodexPinReconciler` follows).
enum ContextReset {
    static let claudeCommand = "/clear"
    static let codexCommand = "/new"

    static func typing(_ command: String, into session: Session, via sink: SessionCommandSink?) throws -> RoutingCapability<Void> {
        guard let sink else { return .unsupported(reason: "no command channel attached") }
        let dispatch = sink.submitCommand(command, to: session.id)
        if let code = dispatch.errorCode { throw ContextResetError.refused(code) }
        return .supported(())
    }
}
```

In `AgentRoutingCapabilities.swift`, add to both `ClaudeRoutingCapabilities` and
`CodexRoutingCapabilities`, directly under `let accountModel`:

```swift
    /// Attached by `SessionStore` (`attachCommandSink`); weak because the store owns the registry.
    weak var commands: SessionCommandSink?
```

and replace their `resetContext` lines with, respectively:

```swift
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> {
        try ContextReset.typing(ContextReset.claudeCommand, into: session, via: commands)
    }
```

```swift
    func resetContext(_ session: Session) async throws -> RoutingCapability<Void> {
        try ContextReset.typing(ContextReset.codexCommand, into: session, via: commands)
    }
```

Below both classes add:

```swift
extension ClaudeRoutingCapabilities: CommandSinkAttachable {}
extension CodexRoutingCapabilities: CommandSinkAttachable {}
```

In `SessionStore.swift`, change the registry from Task 4a to attach itself:

```swift
    lazy var routingCapabilities: RoutingCapabilityRegistry = {
        let registry = RoutingCapabilityRegistry.standard()
        registry.attachCommandSink(self)
        return registry
    }()
```

and add, beside `submitPrompt` (`rg -n "func submitPrompt\(_ raw: String" Sources/FlightDeck/SessionStore.swift`):

```swift
    /// A capability's slash command (a context reset), typed through `submitPrompt`'s gate with a
    /// fresh token — each reset is its own message, never a retry of the last one.
    func submitCommand(_ text: String, to session: UUID) -> PromptDispatch {
        submitPrompt(text, token: UUID(), to: session)
    }
```

and at the end of the file:

```swift
extension SessionStore: SessionCommandSink {}
```

- [ ] **Step 5: Run the tests**

Run: `FD_TEST_FILTER=ContextResetTests,RoutingCapabilityRegistryTests,LaunchOverrideMappingTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/LaunchOverrideMapping.swift Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/FlightControlL3/Swarm/ContextResetTests.swift
git commit -m "feat: reset an agent's context by typing its own clear command" -m "resetContext types /clear (claude) or /new (codex) through submitPrompt's gate, so it lands only in a real composer and queues behind a running turn. A refused type throws, an unattached capability says unsupported; neither ever reports a reset that did not happen." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The real spawner and first-prompt delivery

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Swarm/SwarmSpawner.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (`isPromptQueued`, `withdrawQueuedPrompt`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/PromptDeliveryTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/StoreSwarmSpawnerTests.swift`

**Interfaces:**
- Consumes: `SwarmSpawner`, `SpawnError`, `TaskRef`, `SessionRef`, `ExecutionBlock`, `AccountLease`,
  `LaunchOverrides` (L3-0); `ClaimOutcome` (Task 2); `SessionStore.createSession(…overrides:)` (Task 4a).
- Produces:
  - `enum SwarmTiming { static let composerTimeout: TimeInterval = 120; static let deliveryPoll: Duration = .seconds(1); static let spawnFailureLimit = 3 }`
  - `@MainActor protocol SwarmAgentLauncher: AnyObject { func createAgent(task:block:lease:) async -> Result<SessionRef, SpawnError>; func deliver(_:to:) async -> Result<Void, SpawnError>; func resetContext(_:) async -> Bool }`
  - `@MainActor struct PromptDelivery { init(submit:pending:withdraw:sleep:now:timeout:); func deliver(_:to:) async -> Result<Void, SpawnError> }`
  - `@MainActor final class StoreSwarmSpawner: SwarmSpawner, SwarmAgentLauncher` with `init(create:exists:identity:session:registry:delivery:)`, `var claim: ((TaskRef, String) async -> ClaimOutcome)?`, `static func live(store:) -> StoreSwarmSpawner`
  - `SessionStore.isPromptQueued(_ token: UUID, for: UUID) -> Bool`, `SessionStore.withdrawQueuedPrompt(_ token: UUID, from: UUID)`

- [ ] **Step 1: Write the failing delivery tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// "Composer-ready" is not an event FD receives — it is `submitPrompt` stopping saying
/// `notRunning`, and then the queued prompt leaving the queue. These pin both phases and the
/// 2-minute bound, and that a timed-out prompt is WITHDRAWN: left queued, it would be typed into
/// the agent minutes later, after its claim had already been returned to open.
@MainActor
final class PromptDeliveryTests: XCTestCase {
    private final class Clock { var now = Date(timeIntervalSince1970: 1_790_000_000) }

    /// `Result<Void, _>` is not `Equatable` (`Void` is not), so failures are compared through this.
    private func failure(_ r: Result<Void, SpawnError>) -> SpawnError? {
        if case .failure(let e) = r { return e }
        return nil
    }

    private func delivery(answers: [SessionStore.PromptDispatch], queuedFor ticks: Int = 0,
                          clock: Clock, withdrawn: @escaping (UUID) -> Void = { _ in }) -> PromptDelivery {
        var answers = answers
        var remaining = ticks
        return PromptDelivery(
            submit: { _, _, _ in answers.isEmpty ? .notRunning : answers.removeFirst() },
            pending: { _, _ in defer { remaining -= 1 }; return remaining > 0 },
            withdraw: { token, _ in withdrawn(token) },
            sleep: { clock.now += Double($0.components.seconds) },
            now: { clock.now }, timeout: 120)
    }

    func testSentImmediatelyIsSuccess() async {
        let r = await delivery(answers: [.sent], clock: Clock()).deliver("go", to: UUID())
        XCTAssertNoThrow(try r.get())
    }

    func testNotRunningThenSentWaitsForTheComposer() async {
        let clock = Clock()
        let r = await delivery(answers: [.notRunning, .notRunning, .sent], clock: clock).deliver("go", to: UUID())
        XCTAssertNoThrow(try r.get())
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1_790_000_002)
    }

    func testQueuedWaitsUntilTyped() async {
        let clock = Clock()
        let r = await delivery(answers: [.queued], queuedFor: 3, clock: clock).deliver("go", to: UUID())
        XCTAssertNoThrow(try r.get())
        XCTAssertEqual(clock.now.timeIntervalSince1970, 1_790_000_003)
    }

    func testNoComposerWithinTwoMinutesTimesOut() async {
        let r = await delivery(answers: [], clock: Clock()).deliver("go", to: UUID())
        XCTAssertEqual(failure(r), .composerTimeout)
    }

    func testAQueuedPromptStillUntypedAtTheDeadlineIsWithdrawn() async {
        var withdrawn: [UUID] = []
        let r = await delivery(answers: [.queued], queuedFor: 1_000, clock: Clock(),
                               withdrawn: { withdrawn.append($0) }).deliver("go", to: UUID())
        XCTAssertEqual(failure(r), .composerTimeout)
        XCTAssertEqual(withdrawn.count, 1)
    }

    func testRefusalsAreLaunchFailures() async {
        let gone = await delivery(answers: [.unknownSession], clock: Clock()).deliver("go", to: UUID())
        XCTAssertEqual(failure(gone), .launchFailed("the tab is gone"))
        let rejected = await delivery(answers: [.rejected(.tooLong)], clock: Clock()).deliver("go", to: UUID())
        XCTAssertEqual(failure(rejected), .launchFailed("the prompt was refused: prompt_too_long"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=PromptDeliveryTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'PromptDelivery' in scope`.

- [ ] **Step 3: Write the failing spawner tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The real `SwarmSpawner`. Its contract is narrow and each clause has bitten a creation path
/// before: the harness must name a real agent, a "successful" creation must have actually filed
/// a tab (claude's `newSession` returns an unfiled draft on refusal), the tab must have booted
/// an Agent Mail identity (the claim needs its name), and the claim sits between creation and
/// the prompt.
@MainActor
final class StoreSwarmSpawnerTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private let task = TaskRef(id: "fx-a", project: URL(fileURLWithPath: "/p", isDirectory: true))

    private func block(_ harness: HarnessID = "claude") -> ExecutionBlock {
        ExecutionBlock(kind: "tests", harness: harness, model: "opus", knobs: ["effort": "high"], pool: "claude-subs",
                       source: AssignmentSource(by: .rule, reason: "r", at: at))
    }

    private struct Call: Equatable { let agent: AgentID; let dir: String; let account: UUID?; let overrides: LaunchOverrides }

    private func spawner(created: Result<UUID, AgentLaunchError>, exists: Bool = true, name: String? = "BlueLake",
                         calls: @escaping (Call) -> Void = { _ in },
                         deliverSucceeds: Bool = true) -> StoreSwarmSpawner {
        StoreSwarmSpawner(
            create: { agent, dir, account, overrides in calls(Call(agent: agent, dir: dir, account: account, overrides: overrides)); return created },
            exists: { _ in exists },
            identity: { id in name.map { FlywheelIdentity(agentName: $0, project: "/p") } },
            session: { id in Session(id: id, title: "t", workingDirectory: "/p") },
            registry: RoutingCapabilityRegistry([FakeRoutingCapabilities()]),
            delivery: PromptDelivery(submit: { _, _, _ in deliverSucceeds ? .sent : .notRunning },
                                     pending: { _, _ in false }, withdraw: { _, _ in },
                                     sleep: { _ in }, now: { Date.distantFuture }, timeout: 0))
    }

    func testCreateAgentPassesBlockAndLeaseThrough() async throws {
        let id = UUID(); var seen: [Call] = []
        let account = UUID()
        let lease = AccountLease(pool: "claude-subs", account: AccountRef(harness: "claude", id: account, label: "Work"))
        let ref = try await spawner(created: .success(id), calls: { seen.append($0) })
            .createAgent(task: task, block: block(), lease: lease).get()
        XCTAssertEqual(ref, SessionRef(id: id, agentName: "BlueLake"))
        XCTAssertEqual(seen, [Call(agent: .claude, dir: "/p", account: account,
                                   overrides: LaunchOverrides(model: "opus", knobs: ["effort": "high"]))])
    }

    func testUnknownHarnessIsUnsupported() async {
        let r = await spawner(created: .success(UUID())).createAgent(task: task, block: block("fake"), lease: nil)
        XCTAssertEqual(r, .failure(.unsupportedHarness("fake")))
    }

    func testAnUnfiledTabIsALaunchFailure() async {
        let r = await spawner(created: .success(UUID()), exists: false).createAgent(task: task, block: block(), lease: nil)
        XCTAssertEqual(r, .failure(.launchFailed("the tab was refused")))
    }

    func testATabWithNoAgentMailIdentityIsALaunchFailure() async {
        let r = await spawner(created: .success(UUID()), name: nil).createAgent(task: task, block: block(), lease: nil)
        XCTAssertEqual(r, .failure(.launchFailed("no Agent Mail identity — is Flight Control on for this project?")))
    }

    func testCreateFailureCarriesTheLaunchError() async {
        let r = await spawner(created: .failure(.prepareFailed("boom"))).createAgent(task: task, block: block(), lease: nil)
        XCTAssertEqual(r, .failure(.launchFailed("Could not start a Codex session: boom")))
    }

    func testContractSpawnClaimsBetweenCreateAndPrompt() async {
        let s = spawner(created: .success(UUID()))
        var order: [String] = []
        s.claim = { t, name in order.append("claim \(t.id) \(name)"); return .claimed }
        let r = await s.spawn(task: task, block: block(), lease: nil, firstPrompt: "go")
        XCTAssertEqual(r.map(\.agentName), .success("BlueLake"))
        XCTAssertEqual(order, ["claim fx-a BlueLake"])
    }

    func testContractSpawnReportsAClaimConflict() async {
        let s = spawner(created: .success(UUID()))
        s.claim = { _, _ in .conflict }
        let r = await s.spawn(task: task, block: block(), lease: nil, firstPrompt: "go")
        XCTAssertEqual(r, .failure(.claimConflict("fx-a")))
    }

    func testContractSpawnReportsAComposerTimeout() async {
        let r = await spawner(created: .success(UUID()), deliverSucceeds: false)
            .spawn(task: task, block: block(), lease: nil, firstPrompt: "go")
        XCTAssertEqual(r, .failure(.composerTimeout))
    }

    func testResetGoesThroughTheRegistry() async {
        let fake = FakeRoutingCapabilities(); fake.harness = "claude"
        let id = UUID()
        let s = StoreSwarmSpawner(create: { _, _, _, _ in .success(id) }, exists: { _ in true },
                                  identity: { _ in nil }, session: { Session(id: $0, title: "t", workingDirectory: "/p") },
                                  registry: RoutingCapabilityRegistry([fake]),
                                  delivery: PromptDelivery(submit: { _, _, _ in .sent }, pending: { _, _ in false },
                                                           withdraw: { _, _ in }, sleep: { _ in }, now: Date.init, timeout: 1))
        let ok = await s.resetContext(id)
        XCTAssertTrue(ok)
        XCTAssertEqual(fake.resetCalls, [id])
        fake.resetResult = .success(.unsupported(reason: "no"))
        let unsupported = await s.resetContext(id)
        XCTAssertFalse(unsupported)
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `FD_TEST_FILTER=StoreSwarmSpawnerTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'StoreSwarmSpawner' in scope`.

- [ ] **Step 5: Add the two prompt-queue helpers to `SessionStore`**

Directly below `submitPrompt` (`SessionStore.swift:5699`):

```swift
    /// Whether a prompt accepted as `.queued` is still waiting to be typed. The swarm's first
    /// prompt waits on this rather than on an event, because "typed" is the queue letting go.
    func isPromptQueued(_ token: UUID, for id: UUID) -> Bool {
        promptQueue[id]?.contains { $0.token == token } == true
    }

    /// Takes back a queued prompt nobody should receive any more — a swarm agent that never
    /// showed a composer has had its claim returned to open, and its task prompt must not be
    /// typed into it minutes later.
    func withdrawQueuedPrompt(_ token: UUID, from id: UUID) {
        promptQueue[id]?.removeAll { $0.token == token }
        if promptQueue[id]?.isEmpty == true { promptQueue[id] = nil }
    }
```

- [ ] **Step 6: Implement `SwarmSpawner.swift`**

```swift
import Foundation
import IntakeKit

enum SwarmTiming {
    /// Spec §10: no composer within two minutes is "stuck at start".
    static let composerTimeout: TimeInterval = 120
    static let deliveryPoll: Duration = .seconds(1)
    /// Spec §10: three spawn failures in a row on one config pause the swarm.
    static let spawnFailureLimit = 3
}

/// The three steps of starting work on an agent, split so the controller can claim between the
/// spawn (which boots the Agent Mail identity the claim names) and the prompt — spec §4's order.
@MainActor
protocol SwarmAgentLauncher: AnyObject {
    func createAgent(task: TaskRef, block: ExecutionBlock, lease: AccountLease?) async -> Result<SessionRef, SpawnError>
    /// Types `prompt` once the tab has a composer. `.composerTimeout` after `SwarmTiming.composerTimeout`.
    func deliver(_ prompt: String, to session: UUID) async -> Result<Void, SpawnError>
    func resetContext(_ session: UUID) async -> Bool
}

/// Waits for a composer by asking the same gate a phone prompt goes through: `submitPrompt`
/// answers `notRunning` until the tab has a live status and a surface, then `sent` or `queued`;
/// a queued prompt is typed when the inject gate sees a real composer box. Polling, because
/// nothing announces "composer ready" — the gate IS the definition.
@MainActor
struct PromptDelivery {
    let submit: (String, UUID, UUID) -> SessionStore.PromptDispatch
    let pending: (UUID, UUID) -> Bool
    let withdraw: (UUID, UUID) -> Void
    let sleep: (Duration) async -> Void
    let now: () -> Date
    let timeout: TimeInterval

    func deliver(_ text: String, to session: UUID) async -> Result<Void, SpawnError> {
        let token = UUID()
        let deadline = now().addingTimeInterval(timeout)
        var queued = false
        while !queued {
            switch submit(text, token, session) {
            case .sent: return .success(())
            case .queued, .duplicate: queued = true
            case .notRunning:
                if now() >= deadline { return .failure(.composerTimeout) }
                await sleep(SwarmTiming.deliveryPoll)
            case .unknownSession: return .failure(.launchFailed("the tab is gone"))
            case .unsupportedAgent: return .failure(.launchFailed("this agent has no text channel"))
            case .rejected(let reason): return .failure(.launchFailed("the prompt was refused: \(reason.rawValue)"))
            }
        }
        while pending(token, session) {
            if now() >= deadline {
                withdraw(token, session)
                return .failure(.composerTimeout)
            }
            await sleep(SwarmTiming.deliveryPoll)
        }
        return .success(())
    }
}

/// L3-S's `SwarmSpawner`: creates a tab through `createSession(agent:in:account:overrides:)`,
/// which boots the Agent Mail identity for a Flight Control project, and types the first prompt
/// once the tab can take it. Built from closures so the contract is testable without a GUI;
/// `live(store:)` binds them to the store.
@MainActor
final class StoreSwarmSpawner: SwarmSpawner, SwarmAgentLauncher {
    typealias Create = (AgentID, String, UUID?, LaunchOverrides) async -> Result<UUID, AgentLaunchError>

    private let create: Create
    private let exists: (UUID) -> Bool
    private let identity: (UUID) -> FlywheelIdentity?
    /// Named apart from the `session` locals below, which would otherwise shadow it.
    private let lookupSession: (UUID) -> Session?
    private let registry: RoutingCapabilityRegistry
    private let delivery: PromptDelivery
    /// Used by the contract's `spawn` only (L3-U's hand-off path). The controller claims itself.
    var claim: ((TaskRef, String) async -> ClaimOutcome)?

    init(create: @escaping Create, exists: @escaping (UUID) -> Bool, identity: @escaping (UUID) -> FlywheelIdentity?,
         session: @escaping (UUID) -> Session?, registry: RoutingCapabilityRegistry, delivery: PromptDelivery) {
        self.create = create; self.exists = exists; self.identity = identity; self.lookupSession = session
        self.registry = registry; self.delivery = delivery
    }

    static func live(store: SessionStore) -> StoreSwarmSpawner {
        StoreSwarmSpawner(
            create: { [weak store] agent, dir, account, overrides in
                guard let store else { return .failure(.prepareFailed("the app is shutting down")) }
                // `selecting: false`: a swarm spawn must never move the desk's selection.
                return await store.createSession(agent: agent, in: dir, account: account, selecting: false, overrides: overrides)
            },
            exists: { [weak store] in store?.sessionExists($0) ?? false },
            identity: { [weak store] id in store?.repos.flatMap(\.sessions).first { $0.id == id }?.flywheelIdentity },
            session: { [weak store] id in store?.repos.flatMap(\.sessions).first { $0.id == id } },
            registry: store.routingCapabilities,
            delivery: PromptDelivery(
                submit: { [weak store] text, token, id in store?.submitPrompt(text, token: token, to: id) ?? .unknownSession },
                pending: { [weak store] token, id in store?.isPromptQueued(token, for: id) ?? false },
                withdraw: { [weak store] token, id in store?.withdrawQueuedPrompt(token, from: id) },
                sleep: { try? await Task.sleep(for: $0) },
                now: Date.init, timeout: SwarmTiming.composerTimeout))
    }

    func createAgent(task: TaskRef, block: ExecutionBlock, lease: AccountLease?) async -> Result<SessionRef, SpawnError> {
        guard let agent = AgentID(rawValue: block.harness.rawValue) else { return .failure(.unsupportedHarness(block.harness)) }
        let overrides = LaunchOverrides(model: block.model, knobs: block.knobs)
        switch await create(agent, task.project.path, lease?.account.id, overrides) {
        case .failure(let error):
            return .failure(.launchFailed(error.errorDescription ?? String(describing: error)))
        case .success(let id):
            // `newSession` returns an unfiled draft when it refuses, and `createSession` passes
            // that draft's id back as a success; the tab has to actually exist.
            guard exists(id) else { return .failure(.launchFailed("the tab was refused")) }
            guard let name = identity(id)?.agentName else {
                return .failure(.launchFailed("no Agent Mail identity — is Flight Control on for this project?"))
            }
            return .success(SessionRef(id: id, agentName: name))
        }
    }

    func deliver(_ prompt: String, to session: UUID) async -> Result<Void, SpawnError> {
        await delivery.deliver(prompt, to: session)
    }

    func resetContext(_ id: UUID) async -> Bool {
        guard let session = lookupSession(id), let capabilities = registry.capabilities(for: session.agent.harnessID),
              let result = try? await capabilities.resetContext(session), case .supported = result else { return false }
        return true
    }

    /// The contract's one-call spawn (L3-0): create → claim → prompt. A hand-off driver returns
    /// the old agent's claim to open first, so this claim does not race the agent it replaces.
    func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError> {
        let created = await createAgent(task: task, block: block, lease: lease)
        guard case .success(let ref) = created else { return created }
        if let claim {
            switch await claim(task, ref.agentName ?? "") {
            case .claimed: break
            case .conflict, .failed: return .failure(.claimConflict(task.id))
            }
        }
        switch await deliver(firstPrompt, to: ref.id) {
        case .success: return .success(ref)
        case .failure(let error): return .failure(error)
        }
    }
}
```

- [ ] **Step 7: Run both classes**

Run: `FD_TEST_FILTER=PromptDeliveryTests,StoreSwarmSpawnerTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 15 tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/SwarmSpawner.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/FlightControlL3/Swarm/PromptDeliveryTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/StoreSwarmSpawnerTests.swift
git commit -m "feat: spawn a swarm agent and hand it its first prompt once its composer is up" -m "StoreSwarmSpawner creates the tab through createSession with the block's overrides, requires the tab to be filed and to have booted an Agent Mail identity, and delivers the first prompt through submitPrompt's gate, polling until the gate takes it and the queue lets it go. Two minutes without a composer is composerTimeout, and the queued prompt is withdrawn so it is never typed after the claim has been returned." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 6: `SessionStore.lastActiveAt(for:)`

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`commitStatuses`, `closeSession`, new accessor)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/LastActiveAtTests.swift`

**Interfaces:**
- Consumes: `commitStatuses(_:backgroundWork:)` (`SessionStore.swift:8108`), `now` (`:1854`), `applyRegistryForTesting` (`:5224`).
- Produces: `SessionStore.lastActiveAt(for id: UUID) -> Date?` — set on every activity transition (deviation 2).

Ordered before the controller because `SwarmHost` (Task 7a) requires it.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlightDeck

/// "Active 4 min ago" on a row and in the drawer, and the stall clock contested detection leans
/// on (Task 11e). Stamped in `commitStatuses`, the one funnel every status write goes through, so
/// claude's registry tick and codex's runtime events stamp it the same way.
@MainActor
final class LastActiveAtTests: XCTestCase {
    func testEveryActivityTransitionStampsTheTab() {
        let store = SessionStore(provider: nil, persistence: nil)
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        store.now = { clock }
        let s = store.newSession(in: URL(fileURLWithPath: "/tmp/p", isDirectory: true))
        XCTAssertNil(store.lastActiveAt(for: s.id))

        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy)])
        XCTAssertEqual(store.lastActiveAt(for: s.id), clock)

        clock += 60
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy, waitingFor: nil, subagentCount: 0)])
        XCTAssertEqual(store.lastActiveAt(for: s.id), clock - 60, "no transition, no stamp")

        clock += 60
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .idle)])
        XCTAssertEqual(store.lastActiveAt(for: s.id), clock)
    }

    func testClosingTheTabForgetsIt() {
        let store = SessionStore(provider: nil, persistence: nil)
        let s = store.newSession(in: URL(fileURLWithPath: "/tmp/p", isDirectory: true))
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy)])
        store.closeSession(s.id)
        XCTAssertNil(store.lastActiveAt(for: s.id))
    }

    func testStatusEqualityIsUntouched() {
        XCTAssertEqual(SessionStatus(activity: .idle), SessionStatus(activity: .idle),
                       "the timestamp lives beside SessionStatus, never inside it (deviation 2)")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=LastActiveAtTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `value of type 'SessionStore' has no member 'lastActiveAt'`.

- [ ] **Step 3: Implement**

Beside `statuses` (`rg -n "private\(set\) var statuses" Sources/FlightDeck/SessionStore.swift`), add:

```swift
    /// When each tab last changed activity. Beside `statuses`, not inside `SessionStatus`: that
    /// type is compared for equality in `commitStatuses`' change diff and across the suite, and a
    /// timestamp in it would make every tick a change. Plain, not `@Published` — every write
    /// coincides with a `statuses` change, which already republishes.
    private var lastActiveAtByID: [UUID: Date] = [:]

    func lastActiveAt(for id: UUID) -> Date? { lastActiveAtByID[id] }
```

In `commitStatuses(_:backgroundWork:)`, directly after `let previousOpenPromptCalls = openPromptCalls`:

```swift
        // Stamped before any early return below: an activity transition is news for the row's
        // "active N min ago" even on a tick whose published fields end up equal.
        let stamp = now()
        for (id, status) in next where previous[id]?.activity != status.activity {
            lastActiveAtByID[id] = stamp
        }
```

In `closeSession(_:recordingHistory:)`, beside the other per-tab cleanups (find
`acceptedPromptTokens[id] = nil` or `acceptedPromptTokens.removeValue(forKey: id)` with
`rg -n "acceptedPromptTokens" Sources/FlightDeck/SessionStore.swift`), add
`lastActiveAtByID[id] = nil`.

- [ ] **Step 4: Run the tests and the status suites**

Run: `FD_TEST_FILTER=LastActiveAtTests,SessionStatusTests,FleetAccountEmissionTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. (If `SessionStatusTests` is not a class name, `test-unit.sh` says so — use
`rg -ln "SessionStatus\(activity" Tests | head -3` to pick two real status suites instead.)

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/FlightControlL3/Swarm/LastActiveAtTests.swift
git commit -m "feat: remember when each tab last changed activity" -m "commitStatuses stamps lastActiveAt on every activity transition. Kept beside SessionStatus rather than in it, so status equality and the change diff stay clock-free." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7a: `SwarmController` — fill free slots by spawning, claiming and prompting

**Files:**
- Create: `Sources/IntakeKit/FlightControl/Swarm/SwarmPlanner.swift`
- Create: `Sources/FlightDeck/FlightControl/Swarm/SwarmHost.swift`
- Create: `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmTestSupport.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerFillTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6; L3-0 `Router`, `KindRegistry`, `PoolAllocator`, `CapacityReader`,
  `AdapterCatalogs`, fakes `FakeRouter`, `FakeKindRegistry`, `FakePoolAllocator`, `FakeCapacityReader`.
- Produces:
  - IntakeKit: `enum SwarmPlanner { static func candidates(_:filter:excluding:) -> [ReadyTask] }` (Tasks 7b/7e add two more)
  - App: `@MainActor protocol SwarmHost: AnyObject { sessionExists(_:); isAgentIdle(_:); wakeIfAsleep(_:); lastActiveAt(for:); flywheelAgents(inProject:) -> [(session: UUID, agentName: String)] }`
  - App: `@MainActor final class SwarmController` with `struct Dependencies { backend, launcher, host, router, kinds, allocator, capacity, catalogs }`, `enum LaunchPlan { spawn(block:lease:), reuse(session:), waiting(String) }`, `init(record:store:deps:now:)`, `var record`, `var onChange: (SwarmRecord) -> Void`, `var freeSlots`, `func tick() async`, `func settle() async`, `func plan(_:block:allowReuse:) async -> LaunchPlan`
  - Test support: `SwarmCallLog`, `FakeSwarmBackend`, `FakeSwarmAgentLauncher`, `FakeSwarmHost`, `SwarmFixtures`, `SwarmRig`

- [ ] **Step 1: Write the test support**

`Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmTestSupport.swift`:

```swift
import Foundation
import IntakeKit
@testable import FlightDeck

/// One ordered log shared by the L3-S fakes, so a test can assert the ORDER of side effects
/// across the backend and the launcher — "release" before "reset" is a Review Focus item.
@MainActor
final class SwarmCallLog {
    private(set) var entries: [String] = []
    func add(_ entry: String) { entries.append(entry) }
    func index(of entry: String) -> Int? { entries.firstIndex(of: entry) }
}

/// br/am as a scripted table. A successful claim takes the task out of `ready`, as br does.
@MainActor
final class FakeSwarmBackend: SwarmBackend {
    let log: SwarmCallLog
    var ready: [ReadyTask] = []
    var readyFails = false
    var claimResults: [String: ClaimOutcome] = [:]
    var statuses: [String: TaskStatusReading] = [:]
    var details: [String: TaskDetail] = [:]
    struct ClaimCall: Equatable { let task: String; let actor: String }
    struct WriteCall: Equatable { let task: String; let block: ExecutionBlock }
    private(set) var readyCalls = 0
    private(set) var claims: [ClaimCall] = []
    private(set) var returned: [String] = []
    private(set) var released: [String] = []
    private(set) var written: [WriteCall] = []

    init(log: SwarmCallLog) { self.log = log }

    func readyTasks(project: URL) async -> Result<[ReadyTask], SwarmBackendError> {
        readyCalls += 1
        return readyFails ? .failure(SwarmBackendError(message: "br ready failed")) : .success(ready)
    }
    func taskDetail(_ id: String, project: URL) async -> TaskDetail? { details[id] }
    func status(_ id: String, project: URL) async -> TaskStatusReading? { statuses[id] }
    func claim(_ id: String, actor: String, project: URL) async -> ClaimOutcome {
        claims.append(ClaimCall(task: id, actor: actor)); log.add("claim \(id) \(actor)")
        let outcome = claimResults[id] ?? .claimed
        if outcome == .claimed {
            statuses[id] = TaskStatusReading(status: "in_progress", assignee: actor)
            ready.removeAll { $0.id == id }
        }
        return outcome
    }
    func returnToOpen(_ id: String, project: URL) async -> Bool {
        returned.append(id); log.add("open \(id)")
        statuses[id] = TaskStatusReading(status: "open", assignee: nil)
        return true
    }
    func writeBlock(_ block: ExecutionBlock, task: String, existingContext: String?, project: URL) async -> Bool {
        written.append(WriteCall(task: task, block: block)); return true
    }
    func releaseReservations(agent: String, project: URL) async -> Bool {
        released.append(agent); log.add("release \(agent)"); return true
    }
}

/// The spawner as a script. With nothing scripted, a creation succeeds as `Agent<n>`.
@MainActor
final class FakeSwarmAgentLauncher: SwarmAgentLauncher {
    let log: SwarmCallLog
    var createResults: [Result<SessionRef, SpawnError>] = []
    var deliverFailures: [UUID: SpawnError] = [:]
    var resetResults: [UUID: Bool] = [:]
    var onCreate: ((SessionRef) -> Void)?
    /// Structs rather than tuples so tests can map them with key paths.
    struct CreateCall { let task: String; let block: ExecutionBlock; let lease: AccountLease? }
    struct DeliverCall { let session: UUID; let prompt: String }
    private(set) var created: [CreateCall] = []
    private(set) var delivered: [DeliverCall] = []
    private(set) var resets: [UUID] = []
    private var names: [UUID: String] = [:]

    init(log: SwarmCallLog) { self.log = log }

    /// A session the test placed in the record itself, so the log can name it.
    func register(_ ref: SessionRef) { names[ref.id] = ref.agentName }
    func name(_ id: UUID) -> String { names[id] ?? "?" }

    func createAgent(task: TaskRef, block: ExecutionBlock, lease: AccountLease?) async -> Result<SessionRef, SpawnError> {
        created.append(CreateCall(task: task.id, block: block, lease: lease))
        let result = createResults.isEmpty
            ? .success(SessionRef(id: UUID(), agentName: "Agent\(created.count)"))
            : createResults.removeFirst()
        if case .success(let ref) = result {
            register(ref); onCreate?(ref); log.add("create \(task.id) \(ref.agentName ?? "?")")
        } else {
            log.add("create-failed \(task.id)")
        }
        return result
    }
    func deliver(_ prompt: String, to session: UUID) async -> Result<Void, SpawnError> {
        delivered.append(DeliverCall(session: session, prompt: prompt)); log.add("prompt \(name(session))")
        if let error = deliverFailures[session] { return .failure(error) }
        return .success(())
    }
    func resetContext(_ session: UUID) async -> Bool {
        resets.append(session); log.add("reset \(name(session))")
        return resetResults[session] ?? true
    }
}

@MainActor
final class FakeSwarmHost: SwarmHost {
    let log: SwarmCallLog
    var existing: Set<UUID> = []
    var busy: Set<UUID> = []
    var activity: [UUID: Date] = [:]
    var agentsByProject: [String: [(session: UUID, agentName: String)]] = [:]
    private(set) var woken: [UUID] = []
    init(log: SwarmCallLog) { self.log = log }
    func sessionExists(_ id: UUID) -> Bool { existing.contains(id) }
    func isAgentIdle(_ id: UUID) -> Bool { existing.contains(id) && !busy.contains(id) }
    func wakeIfAsleep(_ id: UUID) { woken.append(id); log.add("wake") }
    func lastActiveAt(for id: UUID) -> Date? { activity[id] }
    func flywheelAgents(inProject project: String) -> [(session: UUID, agentName: String)] { agentsByProject[project] ?? [] }
}

enum SwarmFixtures {
    static let at = Date(timeIntervalSince1970: 1_790_000_000)
    static let project = "/tmp/swarm-project"

    static func block(_ pool: PoolID = "codex-subs", model: String = "gpt-6-sol", kind: KindID = "tests",
                      pinned: Bool = false, harness: HarnessID = "codex") -> ExecutionBlock {
        ExecutionBlock(kind: kind, harness: harness, model: model, pool: pool,
                       source: AssignmentSource(by: pinned ? .manual : .rule, reason: "fixture", at: at), pinned: pinned)
    }

    static func task(_ id: String, _ block: ExecutionBlock?, title: String? = nil) -> ReadyTask {
        ReadyTask(id: id, title: title ?? "Task \(id)", priority: 2, rank: nil,
                  agentContext: block.flatMap { try? ExecutionBlockCodec.encode($0, into: nil) })
    }

    static func lease(_ pool: PoolID, _ label: String, harness: HarnessID = "codex") -> AccountLease {
        AccountLease(pool: pool, account: AccountRef(harness: harness, id: UUID(), label: label))
    }
}

/// Everything a controller needs, wired to fakes, with a settable clock.
@MainActor
final class SwarmRig {
    let log = SwarmCallLog()
    let backend: FakeSwarmBackend
    let launcher: FakeSwarmAgentLauncher
    let host: FakeSwarmHost
    let router = FakeRouter()
    let kinds = FakeKindRegistry()
    let allocator = FakePoolAllocator()
    let capacity = FakeCapacityReader()
    let store: SwarmStore
    var now = SwarmFixtures.at
    var catalogs = AdapterCatalogs([])
    var projectURL: URL { URL(fileURLWithPath: SwarmFixtures.project, isDirectory: true) }

    init() {
        backend = FakeSwarmBackend(log: log)
        launcher = FakeSwarmAgentLauncher(log: log)
        host = FakeSwarmHost(log: log)
        store = SwarmStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("swarm-rig-\(UUID().uuidString)"))
        kinds.byProject[projectURL] = SeedKinds.all(createdAt: SwarmFixtures.at)
        launcher.onCreate = { [host] ref in host.existing.insert(ref.id) }
    }

    var deps: SwarmController.Dependencies {
        let catalogs = self.catalogs
        return .init(backend: backend, launcher: launcher, host: host, router: router, kinds: kinds,
                     allocator: allocator, capacity: capacity, catalogs: { catalogs })
    }

    @discardableResult
    func leases(_ pool: PoolID, _ count: Int) -> [AccountLease] {
        let made = (1...count).map { SwarmFixtures.lease(pool, "Acct \($0)") }
        allocator.leases[pool, default: []] += made
        return made
    }

    func record(cap: Int = 3, poolCaps: [String: Int] = [:], filter: SwarmFilter = .allReady,
                state: SwarmState = .running, agents: [SwarmAgentRecord] = []) -> SwarmRecord {
        SwarmRecord(id: UUID(), project: SwarmFixtures.project, cap: cap, poolCaps: poolCaps, filter: filter,
                    state: state, agents: agents, createdAt: SwarmFixtures.at)
    }

    func controller(_ record: SwarmRecord) -> SwarmController {
        SwarmController(record: record, store: store, deps: deps, now: { [unowned self] in self.now })
    }

    /// An agent already in the swarm whose tab exists.
    func agent(_ name: String, block: ExecutionBlock = SwarmFixtures.block(), lease: AccountLease? = nil,
               state: SwarmAgentState = .idle, task: String? = nil) -> SwarmAgentRecord {
        let id = UUID()
        host.existing.insert(id)
        launcher.register(SessionRef(id: id, agentName: name))
        return SwarmAgentRecord(session: id, agentName: name, block: block, lease: lease, task: task,
                                state: state, stateSince: SwarmFixtures.at)
    }

    /// One tick plus every launch it started.
    func run(_ controller: SwarmController) async {
        await controller.tick()
        await controller.settle()
    }
}
```

- [ ] **Step 2: Write the failing fill tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 steps 1–7 on the spawn path: cap filling in scheduler order, claim after spawn,
/// the task prompt, and the Review Focus rule that a swarm claims only what its filter admits
/// and only what is ready.
@MainActor
final class SwarmControllerFillTests: XCTestCase {
    func testFillsUpToTheCapInSchedulerOrder() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 4)
        rig.backend.ready = ["fx-1", "fx-2", "fx-3", "fx-4"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1", "fx-2", "fx-3"])
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1", "fx-2", "fx-3"])
        XCTAssertEqual(rig.backend.claims.map(\.actor), ["Agent1", "Agent2", "Agent3"])
        XCTAssertEqual(c.record.agents.map(\.state), [.working, .working, .working])
        XCTAssertEqual(c.record.agents.map(\.task), ["fx-1", "fx-2", "fx-3"])
        XCTAssertEqual(c.freeSlots, 0)
    }

    func testSpawnThenClaimThenPrompt() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1)))
        XCTAssertEqual(rig.log.entries, ["create fx-1 Agent1", "claim fx-1 Agent1", "prompt Agent1"])
    }

    func testThePromptIsTheTaskPromptFromBrShow() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let detail = TaskDetail(id: "fx-1", title: "Add tests", description: "Cover it.", acceptance: "- green",
                                status: "in_progress", assignee: "Agent1")
        rig.backend.details["fx-1"] = detail
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1)))
        XCTAssertEqual(rig.launcher.delivered.map(\.prompt), [TaskPrompt.text(for: detail)])
    }

    func testTheSpawnCarriesTheBlockAndTheLease() async {
        let rig = SwarmRig()
        let lease = rig.leases("codex-subs", 1)[0]
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1)))
        XCTAssertEqual(rig.launcher.created.first?.block, SwarmFixtures.block())
        XCTAssertEqual(rig.launcher.created.first?.lease, lease)
    }

    func testSchedulerRankOutsideFilterIsNeverClaimed() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 2)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block()), SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 2, filter: .intake(id: UUID(), tasks: ["fx-2"])))
        await rig.run(c)
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-2"], "fx-1 is ranked first but not in this intake")
    }

    func testRankedButNotReadyTaskIsNeverClaimed() async throws {
        // The real join, through the real backend: br scheduler ranks fx-z first, but br ready
        // does not list it.
        let rig = SwarmRig()
        rig.leases("codex-subs", 2)
        let runner = MultiRunner()
        runner.responses["br ready --json"] = (#"[{"id":"fx-a","title":"A","priority":2}]"#, 0)
        runner.responses["br scheduler --format"] =
            (#"{"schema":"br.scheduler.v1","recommendations":[{"rank":1,"issue":{"id":"fx-z"}},{"rank":2,"issue":{"id":"fx-a"}}]}"#, 0)
        let ctx = try ExecutionBlockCodec.encode(SwarmFixtures.block(), into: nil)
        // The context as a JSON string literal, quotes included: encode a one-element array and
        // strip the brackets.
        let quoted = String(String(data: try JSONSerialization.data(withJSONObject: [ctx]), encoding: .utf8)!
            .dropFirst().dropLast())
        runner.responses["br list --status"] = (#"{"issues":[{"id":"fx-a","agent_context":"# + quoted + "}]}", 0)
        runner.responses["br update fx-a"] = ("{}", 0)
        var deps = rig.deps
        deps.backend = BrSwarmBackend(runner: runner)
        let c = SwarmController(record: rig.record(cap: 2), store: rig.store, deps: deps, now: { SwarmFixtures.at })
        await c.tick(); await c.settle()
        let claimed = runner.argv.filter { $0.count > 3 && $0[1] == "update" && $0[3] == "--claim" }.map { $0[2] }
        XCTAssertEqual(claimed, ["fx-a"])
    }

    func testAClaimConflictLeavesAnIdleAgentAndTheNextTaskIsTaken() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 2)
        rig.backend.claimResults["fx-1"] = .conflict
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block()), SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.agents.map(\.state), [.idle])
        XCTAssertTrue(rig.launcher.delivered.isEmpty, "a conflicted agent gets no prompt")
        rig.backend.ready.removeAll { $0.id == "fx-1" }   // br: someone else holds it now
        await rig.run(c)
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1", "fx-2"])
        XCTAssertEqual(c.record.agents.filter { $0.task == "fx-2" }.map(\.state), [.working])
    }

    func testNoLeaseLeavesTheTaskWaiting() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertTrue(rig.launcher.created.isEmpty)
        XCTAssertEqual(c.record.waiting.map(\.task), ["fx-1"])
        XCTAssertFalse(c.record.waiting[0].reason.isEmpty)
    }

    func testUnroutableTasksAreSkippedAndListed() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-none", nil),
                             ReadyTask(id: "fx-bad", title: "bad", priority: 2, rank: nil,
                                       agentContext: #"{"flight_deck":{"execution":{"v":1}}}"#),
                             SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1"])
        XCTAssertEqual(c.record.unroutable, [WaitingTask(task: "fx-none", reason: "no execution block"),
                                             WaitingTask(task: "fx-bad", reason: "missing kind")])
    }

    func testASpawnFailureReleasesTheLeaseAndClaimsNothing() async {
        let rig = SwarmRig()
        let lease = rig.leases("codex-subs", 1)[0]
        rig.launcher.createResults = [.failure(.launchFailed("Agent Mail boot failed"))]
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(rig.allocator.released, [lease])
        XCTAssertTrue(rig.backend.claims.isEmpty)
        XCTAssertEqual(c.record.spawnFailures[ConfigKey(SwarmFixtures.block()).rawValue], 1)
    }

    func testAPausedOrStoppedSwarmDoesNotReadTheReadyList() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(state: .paused)))
        await rig.run(rig.controller(rig.record(state: .stopped)))
        XCTAssertEqual(rig.backend.readyCalls, 0)
    }

    func testTheLogRecordsSpawnClaimPrompt() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(rig.store.log(swarm: c.record.id).map(\.kind), [.spawn, .claim, .prompt])
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmControllerFillTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find type 'SwarmHost' in scope`.

- [ ] **Step 4: Implement `SwarmPlanner.swift`**

```swift
import Foundation

/// The pure decisions inside a controller tick, kept apart from the side effects so each rule is
/// one function with one test.
public enum SwarmPlanner {
    /// Ready tasks this swarm may claim, in the order given (scheduler order), minus the ones it
    /// is already holding or launching. The filter is applied HERE, after ranking: the scheduler
    /// ranks the whole project, and an intake swarm must never claim outside its intake.
    public static func candidates(_ ready: [ReadyTask], filter: SwarmFilter, excluding taken: Set<String>) -> [ReadyTask] {
        ready.filter { filter.admits($0.id) && !taken.contains($0.id) }
    }
}
```

- [ ] **Step 5: Implement `SwarmHost.swift`**

```swift
import Foundation

/// What a swarm needs from the session store, and nothing more. `SessionStore` conforms (Task 7h).
@MainActor
protocol SwarmHost: AnyObject {
    func sessionExists(_ id: UUID) -> Bool
    /// The tab's agent is idle right now. Reuse requires it: a `/clear` typed into a running turn
    /// queues behind work that was supposed to be finished (Review Focus: human-closed task).
    func isAgentIdle(_ id: UUID) -> Bool
    func wakeIfAsleep(_ id: UUID)
    func lastActiveAt(for id: UUID) -> Date?
    /// Every tab in `project` (a standardized path) that booted an Agent Mail identity.
    func flywheelAgents(inProject project: String) -> [(session: UUID, agentName: String)]
}
```

- [ ] **Step 6: Implement `SwarmController.swift`**

```swift
import Foundation
import IntakeKit

/// One swarm's keep-it-fed loop (spec §4). Ticked by `SwarmService` on the shared `WatchClock`
/// and on events. Launches run as their own tasks so a two-minute composer wait never holds the
/// tick; `settle()` lets a test wait for them.
@MainActor
final class SwarmController {
    struct Dependencies {
        var backend: SwarmBackend
        var launcher: SwarmAgentLauncher
        var host: SwarmHost
        var router: any Router
        var kinds: any KindRegistry
        var allocator: any PoolAllocator
        var capacity: any CapacityReader
        var catalogs: () async -> AdapterCatalogs
    }

    enum LaunchPlan: Equatable {
        case spawn(block: ExecutionBlock, lease: AccountLease?)
        case reuse(session: UUID)
        case waiting(String)
    }

    private(set) var record: SwarmRecord
    private let deps: Dependencies
    private let store: SwarmStore
    private let now: () -> Date
    /// The service persists `swarms.json` (every swarm in one file) and republishes.
    var onChange: (SwarmRecord) -> Void = { _ in }

    /// Task id → its launch. A launch owns the task from slot to prompt.
    private var launches: [String: Task<Void, Never>] = [:]
    /// Spawns whose agent record does not exist yet, per pool — they hold a slot and pool load.
    private var pendingSpawns: [PoolID: Int] = [:]
    private var isTicking = false

    init(record: SwarmRecord, store: SwarmStore, deps: Dependencies, now: @escaping () -> Date = Date.init) {
        self.record = record; self.store = store; self.deps = deps; self.now = now
    }

    var project: URL { URL(fileURLWithPath: record.project, isDirectory: true) }
    private var pendingSpawnCount: Int { pendingSpawns.values.reduce(0, +) }
    var freeSlots: Int { max(0, record.cap - record.activeCount - pendingSpawnCount) }
    var inFlightTasks: Set<String> { Set(launches.keys) }

    func settle() async {
        while let next = launches.values.first { await next.value }
    }

    func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        switch record.state {
        case .running: await fillSlots()
        case .draining, .paused, .stopped: break
        }
        changed()
    }

    private func fillSlots() async {
        guard freeSlots > 0 else { return }
        let ready: [ReadyTask]
        switch await deps.backend.readyTasks(project: project) {
        case .success(let tasks): ready = tasks
        case .failure(let error): log(.error, detail: error.message); return
        }
        let taken = Set(record.agents.compactMap(\.task))
            .union(record.agents.compactMap(\.pendingClaim))
            .union(inFlightTasks)
        let candidates = SwarmPlanner.candidates(ready, filter: record.filter, excluding: taken)
        var waiting: [WaitingTask] = []
        var unroutable: [WaitingTask] = []
        for task in candidates {
            guard record.state == .running, freeSlots > 0 else { break }
            let block: ExecutionBlock
            switch task.block {
            case .success(let decoded?): block = decoded
            case .success(nil):
                unroutable.append(WaitingTask(task: task.id, reason: "no execution block")); continue
            case .failure(let error):
                unroutable.append(WaitingTask(task: task.id, reason: error.message)); continue
            }
            let plan = await plan(task, block: block)
            if case .waiting(let reason) = plan {
                waiting.append(WaitingTask(task: task.id, reason: reason))
                continue
            }
            start(plan, for: task)
        }
        record.waiting = waiting
        record.unroutable = unroutable
    }

    /// Where a task's agent comes from. Tasks 7b and 7c replace this body (reuse, spill, caps).
    func plan(_ task: ReadyTask, block: ExecutionBlock, allowReuse: Bool = true) async -> LaunchPlan {
        if let lease = deps.allocator.lease(pool: block.pool) { return .spawn(block: block, lease: lease) }
        return .waiting("no account in \(block.pool) is under its soft limit")
    }

    private func start(_ plan: LaunchPlan, for task: ReadyTask) {
        switch plan {
        case .waiting: return
        case .reuse(let session):
            record.update(session) { $0.state = .starting; $0.stateSince = now(); $0.marker = nil }
        case .spawn(let block, _):
            pendingSpawns[block.pool, default: 0] += 1
        }
        let id = task.id
        launches[id] = Task { [weak self] in
            guard let self else { return }
            await self.run(plan, for: task)
            self.launches[id] = nil
            self.changed()
        }
    }

    private func run(_ plan: LaunchPlan, for task: ReadyTask) async {
        switch plan {
        case .waiting, .reuse: return
        case .spawn(let block, let lease): await spawn(block, lease: lease, for: task)
        }
    }

    private func spawn(_ block: ExecutionBlock, lease: AccountLease?, for task: ReadyTask) async {
        let key = ConfigKey(block)
        let created = await deps.launcher.createAgent(task: TaskRef(id: task.id, project: project), block: block, lease: lease)
        pendingSpawns[block.pool] = max(0, (pendingSpawns[block.pool] ?? 1) - 1)
        switch created {
        case .failure(let error):
            if let lease { deps.allocator.release(lease) }
            noteSpawnFailure(key, error: error)
        case .success(let ref):
            record.spawnFailures[key.rawValue] = nil
            record.agents.append(SwarmAgentRecord(session: ref.id, agentName: ref.agentName ?? "", block: block,
                                                  lease: lease, task: nil, state: .starting, stateSince: now()))
            log(.spawn, task: task.id, session: ref.id, detail: "\(ref.agentName ?? "?") on \(key)")
            await claimAndPrompt(task, session: ref.id)
        }
    }

    /// Spec §4 steps 5–7. The claim comes after the spawn because it names the agent the spawn
    /// booted; a claim that fails leaves an idle agent the next tick can reuse.
    private func claimAndPrompt(_ task: ReadyTask, session: UUID) async {
        guard let agent = record.agent(session) else { return }
        // Saved BEFORE the claim runs (Review Focus: a crash mid-claim).
        record.update(session) { $0.pendingClaim = task.id }
        changed()
        switch await deps.backend.claim(task.id, actor: agent.agentName, project: project) {
        case .claimed:
            record.update(session) { $0.pendingClaim = nil; $0.task = task.id }
            log(.claim, task: task.id, session: session, detail: agent.agentName)
        case .conflict:
            becomeIdle(session)
            log(.conflict, task: task.id, session: session, detail: "claimed elsewhere; the next tick takes another task")
            return
        case .failed(let why):
            becomeIdle(session)
            log(.error, task: task.id, session: session, detail: "claim failed: \(why)")
            return
        }
        let detail = await deps.backend.taskDetail(task.id, project: project)
            ?? TaskDetail(id: task.id, title: task.title, description: "", acceptance: "",
                          status: "in_progress", assignee: agent.agentName)
        switch await deps.launcher.deliver(TaskPrompt.text(for: detail), to: session) {
        case .success:
            record.update(session) { $0.state = .working; $0.stateSince = now() }
            log(.prompt, task: task.id, session: session)
        case .failure(let error):
            await deliveryFailed(session, task: task.id, error: error)
        }
    }

    /// Task 7f replaces this body with the spec §10 stuck-at-start handling.
    private func deliveryFailed(_ session: UUID, task: String, error: SpawnError) async {
        _ = await deps.backend.returnToOpen(task, project: project)
        becomeIdle(session)
        log(.error, task: task, session: session, detail: Self.describe(error))
    }

    /// Task 7f replaces this body with the three-in-a-row pause.
    private func noteSpawnFailure(_ key: ConfigKey, error: SpawnError) {
        record.spawnFailures[key.rawValue, default: 0] += 1
        log(.spawnFailed, detail: "\(key): \(Self.describe(error))")
    }

    private func becomeIdle(_ session: UUID) {
        record.update(session) { $0.pendingClaim = nil; $0.task = nil; $0.state = .idle; $0.stateSince = now() }
    }

    static func describe(_ error: SpawnError) -> String {
        switch error {
        case .launchFailed(let why): why
        case .composerTimeout: "no composer within two minutes"
        case .unsupportedHarness(let harness): "no adapter named \(harness)"
        case .claimConflict(let task): "\(task) was claimed elsewhere"
        }
    }

    func log(_ kind: SwarmLogEntry.Kind, task: String? = nil, session: UUID? = nil, detail: String = "") {
        store.append(SwarmLogEntry(at: now(), kind: kind, task: task, session: session, detail: detail), swarm: record.id)
    }

    private func changed() { onChange(record) }
}
```

- [ ] **Step 7: Run the fill tests**

Run: `FD_TEST_FILTER=SwarmControllerFillTests ./scripts/test-unit.sh 2>&1 | tail -30`
Expected: `Executed 12 tests, with 0 failures`. If `testUnroutableTasksAreSkippedAndListed` fails
only on the second reason string, print it (`XCTAssertEqual` shows both): it is
`ExecutionBlockError.message` for a block with `v` but no `kind`, which L3-0 spells
`missing kind` — adjust the expected string to what L3-0's `message` actually returns, never the code.

- [ ] **Step 8: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Swarm/SwarmPlanner.swift Sources/FlightDeck/FlightControl/Swarm/SwarmHost.swift Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmTestSupport.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerFillTests.swift
git commit -m "feat: fill a swarm's free slots by spawning, claiming and prompting" -m "Each tick takes ready tasks in scheduler order that the filter admits and nothing in the swarm holds, leases an account in the block's pool, spawns an agent, claims the task under the agent's name, and types the task prompt. A conflict leaves the agent idle for the next tick; a spawn failure releases the lease; unroutable blocks are listed, never launched." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7b: Reuse an idle agent of the same configuration

**Files:**
- Modify: `Sources/IntakeKit/FlightControl/Swarm/SwarmPlanner.swift` (append `reuseCandidate`)
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift` (`plan`, `run`, new `reuse`, `headroom`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerReuseTests.swift`

**Interfaces:**
- Produces: `SwarmPlanner.reuseCandidate(for:in:isAvailable:headroom:) -> SwarmAgentRecord?`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 step 4 and §10: reuse before spawn, the config-key match, the soft-limit check, and
/// the reset-failure fallback. The ordering test is a Review Focus item.
@MainActor
final class SwarmControllerReuseTests: XCTestCase {
    func testAnIdleAgentWithTheSameConfigIsReusedAfterAReset() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake")
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1, agents: [a]))
        await rig.run(c)
        XCTAssertTrue(rig.launcher.created.isEmpty, "reuse, not spawn")
        XCTAssertEqual(rig.launcher.resets, [a.session])
        XCTAssertEqual(rig.backend.claims.map(\.actor), ["BlueLake"])
        XCTAssertEqual(c.record.agent(a.session)?.state, .working)
        XCTAssertEqual(c.record.agent(a.session)?.task, "fx-1")
    }

    func testReuseReleasesReservationsBeforeResettingContext() async throws {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake")
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1, agents: [a])))
        let release = try XCTUnwrap(rig.log.index(of: "release BlueLake"))
        let reset = try XCTUnwrap(rig.log.index(of: "reset BlueLake"))
        let claim = try XCTUnwrap(rig.log.index(of: "claim fx-1 BlueLake"))
        let prompt = try XCTUnwrap(rig.log.index(of: "prompt BlueLake"))
        XCTAssertLessThan(release, reset, "stale reservations must go before the next task starts")
        XCTAssertLessThan(reset, claim)
        XCTAssertLessThan(claim, prompt)
    }

    func testASleepingAgentIsWokenBeforeItsReset() async throws {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake")
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 1, agents: [a])))
        XCTAssertEqual(rig.host.woken, [a.session])
        XCTAssertLessThan(try XCTUnwrap(rig.log.index(of: "wake")), try XCTUnwrap(rig.log.index(of: "reset BlueLake")))
    }

    func testADifferentConfigIsNotReused() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let other = rig.agent("BlueLake", block: SwarmFixtures.block(model: "gpt-6-terra"))
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 2, agents: [other])))
        XCTAssertTrue(rig.launcher.resets.isEmpty)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1"])
    }

    func testAnAgentWhoseAccountIsPastSoftIsNotReused() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let lease = SwarmFixtures.lease("codex-subs", "Busy")
        rig.capacity.byPool["codex-subs"] = [AccountHeadroom(account: lease.account, worstUtilization: 0.85, state: .overSoft, resetsAt: nil)]
        let a = rig.agent("BlueLake", lease: lease)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 2, agents: [a])))
        XCTAssertTrue(rig.launcher.resets.isEmpty)
        XCTAssertEqual(rig.launcher.created.count, 1)
    }

    func testAnExcludedAgentIsNotReused() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        var a = rig.agent("BlueLake"); a.excludedFromReuse = true
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        await rig.run(rig.controller(rig.record(cap: 2, agents: [a])))
        XCTAssertTrue(rig.launcher.resets.isEmpty)
    }

    func testAResetFailureSpawnsAFreshAgentAndRetiresTheOldOne() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let a = rig.agent("BlueLake")
        rig.launcher.resetResults[a.session] = false
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1, agents: [a]))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1"])
        XCTAssertEqual(c.record.agent(a.session)?.state, .idle)
        XCTAssertEqual(c.record.agent(a.session)?.excludedFromReuse, true)
        XCTAssertEqual(c.record.agent(a.session)?.marker, "reset failed")
        XCTAssertEqual(rig.backend.claims.map(\.actor), ["Agent1"])
    }

    func testTheLongestIdleAgentIsPickedFirst() {
        let at = SwarmFixtures.at
        var older = SwarmAgentRecord(session: UUID(), agentName: "Old", block: SwarmFixtures.block(), lease: nil,
                                     task: nil, state: .idle, stateSince: at)
        older.stateSince = at.addingTimeInterval(-600)
        let newer = SwarmAgentRecord(session: UUID(), agentName: "New", block: SwarmFixtures.block(), lease: nil,
                                     task: nil, state: .idle, stateSince: at)
        let pick = SwarmPlanner.reuseCandidate(for: ConfigKey(SwarmFixtures.block()), in: [newer, older],
                                               isAvailable: { _ in true }, headroom: { _ in .underSoft })
        XCTAssertEqual(pick?.agentName, "Old")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmControllerReuseTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `type 'SwarmPlanner' has no member 'reuseCandidate'`.

- [ ] **Step 3: Append to `SwarmPlanner`**

```swift
extension SwarmPlanner {
    /// Spec §4 step 4: an idle agent with the same config key whose account is still under soft
    /// (`unknown` counts, as the allocator's own order does). The agent that has waited longest
    /// goes first, so work spreads instead of piling onto the most recently finished tab.
    public static func reuseCandidate(for key: ConfigKey, in agents: [SwarmAgentRecord],
                                      isAvailable: (UUID) -> Bool,
                                      headroom: (SwarmAgentRecord) -> HeadroomState) -> SwarmAgentRecord? {
        agents
            .filter { $0.state == .idle && !$0.excludedFromReuse && $0.config == key && isAvailable($0.session) }
            .filter { [HeadroomState.underSoft, .unknown].contains(headroom($0)) }
            .min { $0.stateSince < $1.stateSince }
    }
}
```

- [ ] **Step 4: Update the controller**

Replace `plan(_:block:allowReuse:)` with:

```swift
    /// Reuse is checked before leasing (deviation 3): an idle agent already holds a lease on an
    /// account under soft, and leasing first would hold two for one agent.
    func plan(_ task: ReadyTask, block: ExecutionBlock, allowReuse: Bool = true) async -> LaunchPlan {
        if allowReuse, let agent = SwarmPlanner.reuseCandidate(
            for: ConfigKey(block), in: record.agents,
            isAvailable: { [deps] id in deps.host.sessionExists(id) && deps.host.isAgentIdle(id) },
            headroom: { [weak self] in self?.headroom(of: $0) ?? .unknown }) {
            return .reuse(session: agent.session)
        }
        if let lease = deps.allocator.lease(pool: block.pool) { return .spawn(block: block, lease: lease) }
        return .waiting("no account in \(block.pool) is under its soft limit")
    }
```

Replace `run(_:for:)` with:

```swift
    private func run(_ plan: LaunchPlan, for task: ReadyTask) async {
        switch plan {
        case .waiting: return
        case .reuse(let session): await reuse(session, for: task)
        case .spawn(let block, let lease): await spawn(block, lease: lease, for: task)
        }
    }
```

Add below `spawn(_:lease:for:)`:

```swift
    private func reuse(_ session: UUID, for task: ReadyTask) async {
        guard let agent = record.agent(session) else { return }
        log(.reuse, task: task.id, session: session, detail: agent.agentName)
        // Reservations first (Review Focus): a reused agent still holds its last task's files, and
        // would block every other agent's commit on them.
        if !(await deps.backend.releaseReservations(agent: agent.agentName, project: project)) {
            log(.error, session: session, detail: "could not release \(agent.agentName)'s reservations")
        }
        deps.host.wakeIfAsleep(session)
        guard await deps.launcher.resetContext(session) else {
            record.update(session) {
                $0.state = .idle; $0.stateSince = now(); $0.excludedFromReuse = true; $0.marker = "reset failed"
            }
            log(.resetFailed, task: task.id, session: session, detail: "spawning a fresh agent instead")
            // Spec §10: spawn a new agent instead. The task is still unclaimed.
            if case .spawn(let block, let lease) = await plan(task, block: agent.block.block, allowReuse: false) {
                pendingSpawns[block.pool, default: 0] += 1
                await spawn(block, lease: lease, for: task)
            }
            return
        }
        await claimAndPrompt(task, session: session)
    }

    func headroom(of agent: SwarmAgentRecord) -> HeadroomState {
        guard let lease = agent.lease else { return .unknown }
        return deps.capacity.headroom(pool: lease.pool).first { $0.account == lease.account }?.state ?? .unknown
    }
```

- [ ] **Step 5: Run reuse + fill**

Run: `FD_TEST_FILTER=SwarmControllerReuseTests,SwarmControllerFillTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. (`testAClaimConflictLeavesAnIdleAgentAndTheNextTaskIsTaken` now reuses the
idle agent for `fx-2`; it asserts only which tasks were claimed, so it stays green.)

- [ ] **Step 6: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Swarm/SwarmPlanner.swift Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerReuseTests.swift
git commit -m "feat: reuse an idle swarm agent of the same configuration before spawning" -m "An idle, existing, idle-tabbed agent with the same config key on an account still under soft gets the next task: its reservations are released, it is woken if smart sleep stopped it, its context is reset, then the task is claimed and prompted. A failed reset retires the agent from reuse and spawns a fresh one for the same task." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7c: Waiting, spill, pinned blocks and pool caps

**Files:**
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift` (`plan`, `leaseIfRoom`, `resolveKind`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerWaitingTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 step 3: no lease → L3-R's spill → waiting, with the reason recorded. A pinned block
/// never spills, and a spill is for one spawn — the stored block is never rewritten.
@MainActor
final class SwarmControllerWaitingTests: XCTestCase {
    private let spilled = SwarmFixtures.block("claude-subs", model: "opus", harness: "claude")

    func testAFullPoolSpillsThroughTheRouterForOneSpawn() async {
        let rig = SwarmRig()
        rig.leases("claude-subs", 1)
        rig.router.spills["tests"] = Assignment(block: spilled)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.block), [spilled])
        XCTAssertEqual(rig.router.spillCalls.map { $0.0 }, ["tests"])
        XCTAssertEqual(rig.router.spillCalls.map { $0.1 }, [["codex-subs"]])
        XCTAssertTrue(rig.backend.written.isEmpty, "a spill never rewrites the task's block")
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .spill && $0.detail.hasPrefix("codex-subs → claude-subs") })
    }

    func testAPinnedBlockNeverSpillsAndWaits() async {
        let rig = SwarmRig()
        rig.leases("claude-subs", 1)
        rig.router.spills["tests"] = Assignment(block: spilled)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block(pinned: true))]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertTrue(rig.launcher.created.isEmpty)
        XCTAssertTrue(rig.router.spillCalls.isEmpty)
        XCTAssertEqual(c.record.waiting, [WaitingTask(task: "fx-1", reason: "pinned to codex-subs, which has no account under its soft limit")])
    }

    func testNothingToSpillToWaits() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.waiting, [WaitingTask(task: "fx-1", reason: "codex-subs is full and nothing else fits")])
    }

    func testAnUnknownKindCannotSpill() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block(kind: "mystery"))]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.waiting, [WaitingTask(task: "fx-1", reason: "codex-subs is full and kind mystery is unknown")])
    }

    func testAPoolCapLimitsAgentsInThatPool() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 3)
        rig.backend.ready = ["fx-1", "fx-2", "fx-3"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3, poolCaps: ["codex-subs": 1]))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1"])
        XCTAssertEqual(c.record.waiting.map(\.task), ["fx-2", "fx-3"])
        XCTAssertEqual(rig.allocator.leaseCalls, ["codex-subs"], "a pool at its cap is not even asked for a lease")
    }

    func testTheSpillTargetsOwnCapIsRespected() async {
        let rig = SwarmRig()
        rig.leases("claude-subs", 2)
        rig.router.spills["tests"] = Assignment(block: spilled)
        rig.backend.ready = ["fx-1", "fx-2"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3, poolCaps: ["claude-subs": 1]))
        await rig.run(c)
        XCTAssertEqual(rig.launcher.created.count, 1)
        XCTAssertEqual(c.record.waiting, [WaitingTask(task: "fx-2", reason: "codex-subs is full and claude-subs is full too")])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmControllerWaitingTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: failures — `testAFullPoolSpillsThroughTheRouterForOneSpawn` (nothing created) and the reason strings.

- [ ] **Step 3: Replace `plan` and add the helpers**

```swift
    /// Reuse is checked before leasing (deviation 3). Then: a lease in the block's pool if the
    /// pool is under its own cap; else, unless the block is pinned, L3-R's spill for this one
    /// spawn; else the task waits, with why.
    func plan(_ task: ReadyTask, block: ExecutionBlock, allowReuse: Bool = true) async -> LaunchPlan {
        if allowReuse, let agent = SwarmPlanner.reuseCandidate(
            for: ConfigKey(block), in: record.agents,
            isAvailable: { [deps] id in deps.host.sessionExists(id) && deps.host.isAgentIdle(id) },
            headroom: { [weak self] in self?.headroom(of: $0) ?? .unknown }) {
            return .reuse(session: agent.session)
        }
        if let lease = leaseIfRoom(block.pool) { return .spawn(block: block, lease: lease) }
        // A pinned block is a human's decision; L3-0 says it never spills.
        if block.pinned { return .waiting("pinned to \(block.pool), which has no account under its soft limit") }
        guard let kind = resolveKind(block.kind) else {
            return .waiting("\(block.pool) is full and kind \(block.kind) is unknown")
        }
        let catalogs = await deps.catalogs()
        guard let spilled = deps.router.spill(block, kind: kind, project: project, exhausted: [block.pool],
                                              catalogs: catalogs, now: now())?.block else {
            return .waiting("\(block.pool) is full and nothing else fits")
        }
        guard let lease = leaseIfRoom(spilled.pool) else {
            return .waiting("\(block.pool) is full and \(spilled.pool) is full too")
        }
        log(.spill, task: task.id, detail: "\(block.pool) → \(spilled.pool) (\(spilled.model))")
        return .spawn(block: spilled, lease: lease)
    }

    /// A pool at its own cap is full without asking the allocator: the cap is about concurrency
    /// (a local model serves one agent at a time), which no account's headroom can answer.
    private func leaseIfRoom(_ pool: PoolID) -> AccountLease? {
        if let cap = record.poolCap(pool), record.load(of: pool) + (pendingSpawns[pool] ?? 0) >= cap { return nil }
        return deps.allocator.lease(pool: pool)
    }

    private func resolveKind(_ id: KindID) -> TaskKind? {
        guard let kinds = try? deps.kinds.kinds(project: project) else { return nil }
        return KindResolution.resolve(id, in: kinds)
    }
```

- [ ] **Step 4: Run all controller tests so far**

Run: `FD_TEST_FILTER=SwarmControllerWaitingTests,SwarmControllerReuseTests,SwarmControllerFillTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerWaitingTests.swift
git commit -m "feat: spill a task to another pool or leave it waiting with a reason" -m "A pool at its own cap or with no lease spills through L3-R's Router.spill for that one spawn (the stored block is untouched); a pinned block never spills. When nothing fits, the task is recorded as waiting with the reason the header popover shows." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7d: Completion, reopened tasks and closed tabs

**Files:**
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift` (`taskSetChanged`, `sweepClosedTabs`, `tick`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerCompletionTests.swift`

**Interfaces:**
- Produces: `SwarmController.taskSetChanged(inProgress: Set<String>) async`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 "Completion": the watcher's in-progress set drives it; `br show` decides what a
/// disappearance means. Two Review Focus items live here.
@MainActor
final class SwarmControllerCompletionTests: XCTestCase {
    private func working(_ rig: SwarmRig) async -> (SwarmController, UUID) {
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        return (c, c.record.agents[0].session)
    }

    func testAClosedTaskFreesTheSlotAndTheAgentIsReusedForTheNext() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        rig.backend.ready = [SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        await c.taskSetChanged(inProgress: [])
        await c.settle()
        XCTAssertEqual(c.record.agent(a)?.lastTask, "fx-1")
        XCTAssertEqual(rig.launcher.resets, [a])
        XCTAssertEqual(c.record.agent(a)?.task, "fx-2")
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .close && $0.task == "fx-1" })
    }

    func testATaskStillInProgressIsLeftAlone() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        await c.taskSetChanged(inProgress: ["fx-1"])
        XCTAssertEqual(c.record.agent(a)?.state, .working)
    }

    func testATaskMissingFromTheWatcherButStillOursIsLeftAlone() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)   // the fake's claim set fx-1 in_progress by Agent1
        await c.taskSetChanged(inProgress: [])
        XCTAssertEqual(c.record.agent(a)?.state, .working, "a watcher snapshot older than the claim is not a completion")
    }

    func testATaskBackToOpenIsLoggedAndTheAgentTreatedAsIdle() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "open", assignee: nil)
        // A task on another config with no lease waits, which keeps the swarm from stopping
        // itself (Task 7e) once the agent goes idle.
        rig.backend.ready = [SwarmFixtures.task("fx-9", SwarmFixtures.block("other"))]
        await c.taskSetChanged(inProgress: [])
        XCTAssertEqual(c.record.agent(a)?.state, .idle)
        XCTAssertNil(c.record.agent(a)?.task)
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .reopen && $0.task == "fx-1" })
    }

    func testHumanClosedTaskDoesNotReuseABusyAgent() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        rig.host.busy.insert(a)                          // its turn is still running
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        await c.taskSetChanged(inProgress: [])
        await c.settle()
        XCTAssertTrue(rig.launcher.resets.isEmpty, "no /clear into a running turn")
        XCTAssertEqual(rig.launcher.created.map(\.task), ["fx-1", "fx-2"])
    }

    func testClosedTabReturnsItsClaimAndFreesItsSlot() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        let lease = c.record.agent(a)?.lease?.lease
        rig.host.existing.remove(a)                      // the user closed the tab
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        await rig.run(c)
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        XCTAssertEqual(c.record.agent(a)?.state, .done)
        XCTAssertEqual(c.record.agent(a)?.marker, "tab closed")
        XCTAssertTrue(rig.allocator.released.contains(lease!))
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1", "fx-2"], "the freed slot is filled in the same tick")
    }

    func testAClosedTabWhoseTaskIsAlreadyClosedReturnsNothing() async {
        let rig = SwarmRig()
        let (c, a) = await working(rig)
        rig.host.existing.remove(a)
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        await rig.run(c)
        XCTAssertTrue(rig.backend.returned.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmControllerCompletionTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `value of type 'SwarmController' has no member 'taskSetChanged'`.

- [ ] **Step 3: Implement**

Add to the controller:

```swift
    /// Called with the Observe watcher's in-progress task ids for this project. A working agent
    /// whose task left that set is asked about through `br show`, because "left in_progress"
    /// means closed, reopened, or merely a watcher snapshot that predates the claim.
    func taskSetChanged(inProgress: Set<String>) async {
        var freed = false
        for agent in record.agents where agent.state == .working {
            guard let task = agent.task, !inProgress.contains(task),
                  let reading = await deps.backend.status(task, project: project) else { continue }
            if reading.status == "closed" {
                record.update(agent.session) { $0.state = .idle; $0.lastTask = task; $0.task = nil; $0.stateSince = now() }
                log(.close, task: task, session: agent.session, detail: agent.agentName)
                freed = true
            } else if reading.status == "in_progress", reading.assignee == agent.agentName {
                continue
            } else {
                // Spec §4: back to open (or taken over) while its agent still held it.
                record.update(agent.session) { $0.state = .idle; $0.task = nil; $0.stateSince = now() }
                let who = reading.assignee.map { " · \($0)" } ?? ""
                log(.reopen, task: task, session: agent.session, detail: "now \(reading.status)\(who) while \(agent.agentName) held it")
                freed = true
            }
        }
        changed()
        if freed { await tick(); await settle() }
    }

    /// A tab the user closed (Review Focus): its claim goes back to open unless the task is
    /// already closed or someone else holds it, its lease is released, and it leaves the swarm.
    private func sweepClosedTabs() async {
        for agent in record.agents where [.starting, .working, .idle].contains(agent.state)
            && !deps.host.sessionExists(agent.session) {
            for task in Set([agent.task, agent.pendingClaim].compactMap { $0 }) {
                let reading = await deps.backend.status(task, project: project)
                let ours = reading?.assignee == nil || reading?.assignee == agent.agentName
                if reading?.status != "closed", ours {
                    _ = await deps.backend.returnToOpen(task, project: project)
                    log(.released, task: task, session: agent.session, detail: "\(agent.agentName)'s tab was closed")
                }
            }
            if let lease = agent.lease { deps.allocator.release(lease.lease) }
            record.update(agent.session) {
                $0.state = .done; $0.task = nil; $0.pendingClaim = nil; $0.marker = "tab closed"; $0.stateSince = now()
            }
        }
    }
```

In `tick()`, insert `await sweepClosedTabs()` as the first line after `defer { isTicking = false }`.

`taskSetChanged` awaits `settle()` after its own tick so a caller (and a test) sees the reuse it
started finish. A caller on the clock does not mind: the launches it waits for are the ones it began.

- [ ] **Step 4: Run all controller tests**

Run: `FD_TEST_FILTER=SwarmControllerCompletionTests,SwarmControllerWaitingTests,SwarmControllerReuseTests,SwarmControllerFillTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerCompletionTests.swift
git commit -m "feat: free a swarm slot when its task closes, reopens, or its tab is closed" -m "The Observe watcher's in-progress set drives completion; br show decides whether a task that left it was closed (agent idle, next task), reopened or taken over (logged, agent idle), or is simply newer than the snapshot. A tab the user closed returns its claim to open, releases its lease and leaves the swarm, and its slot is filled in the same tick. A busy agent is never reused." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7e: Pause, resume, drain, stop and auto-stop

**Files:**
- Modify: `Sources/IntakeKit/FlightControl/Swarm/SwarmPlanner.swift` (append `isFinished`)
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerLifecycleTests.swift`

**Interfaces:**
- Produces: `SwarmPlanner.isFinished(claimable:waiting:active:launching:) -> Bool`;
  `SwarmController.pause()`, `resume() async`, `drain()`, `stop(reason:)`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4 "Stopping". Pause must take effect before the next claim; drain ends in stopped only
/// when the last working agent goes idle; a swarm with nothing left stops itself.
@MainActor
final class SwarmControllerLifecycleTests: XCTestCase {
    func testPauseStopsNewClaimsOnTheNextTick() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 2)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 2))
        c.pause()
        await rig.run(c)
        XCTAssertTrue(rig.backend.claims.isEmpty)
        XCTAssertEqual(c.record.state, .paused)
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .pause })
    }

    func testResumeClaimsAgainAndClearsTheBannerAndFailureCount() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        var record = rig.record(cap: 1, state: .paused)
        record.banner = SwarmStore.restartBanner
        record.spawnFailures = ["k": 3]
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(record)
        await c.resume(); await c.settle()
        XCTAssertEqual(c.record.state, .running)
        XCTAssertNil(c.record.banner)
        XCTAssertEqual(c.record.spawnFailures, [:])
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1"])
    }

    func testDrainStopsWhenTheLastWorkingAgentGoesIdle() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        c.drain()
        XCTAssertEqual(c.record.state, .draining)
        rig.backend.ready = [SwarmFixtures.task("fx-2", SwarmFixtures.block())]
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        await c.taskSetChanged(inProgress: [])
        XCTAssertEqual(c.record.state, .stopped)
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1"], "draining claims nothing new")
        XCTAssertEqual(c.record.agents.map(\.state), [.done])
        XCTAssertEqual(rig.allocator.released.count, 1)
    }

    func testAutoStopsWhenNothingIsReadyWaitingOrWorking() async {
        let rig = SwarmRig()
        let c = rig.controller(rig.record(cap: 2))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .stopped)
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .stop && $0.detail == "nothing left to do" })
    }

    func testAWaitingTaskKeepsTheSwarmRunning() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .running)
    }

    func testOnlyUnroutableWorkStopsTheSwarm() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-none", nil)]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .stopped)
    }

    func testAWorkingAgentKeepsTheSwarmRunning() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 2))
        await rig.run(c)
        await rig.run(c)            // fx-1 claimed; ready is now empty
        XCTAssertEqual(c.record.state, .running)
    }

    func testStopReleasesLeasesAndRetiresAgents() async {
        let rig = SwarmRig()
        let lease = SwarmFixtures.lease("codex-subs", "A")
        let a = rig.agent("BlueLake", lease: lease, state: .working, task: "fx-1")
        let c = rig.controller(rig.record(agents: [a]))
        c.stop(reason: "stopped from the menu")
        XCTAssertEqual(c.record.state, .stopped)
        XCTAssertEqual(c.record.agents.map(\.state), [.done])
        XCTAssertEqual(rig.allocator.released, [lease])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmControllerLifecycleTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `value of type 'SwarmController' has no member 'pause'`.

- [ ] **Step 3: Append to `SwarmPlanner`**

```swift
extension SwarmPlanner {
    /// Spec §4: a swarm stops on its own when nothing is ready, nothing is waiting and no agent is
    /// working. Unroutable tasks are not "ready" here — nothing will ever start them.
    public static func isFinished(claimable: Int, waiting: Int, active: Int, launching: Int) -> Bool {
        claimable == 0 && waiting == 0 && active == 0 && launching == 0
    }
}
```

- [ ] **Step 4: Add the lifecycle to the controller**

Change `tick()`'s switch to:

```swift
        switch record.state {
        case .running: await fillSlots()
        case .draining: finishDrainIfIdle()
        case .paused, .stopped: break
        }
```

At the end of `fillSlots()` (after `record.unroutable = unroutable`) add:

```swift
        let claimable = candidates.count - unroutable.count
        if record.state == .running, SwarmPlanner.isFinished(claimable: claimable, waiting: waiting.count,
                                                              active: record.activeCount,
                                                              launching: launches.count + pendingSpawnCount) {
            stop(reason: "nothing left to do")
        }
```

and, because `fillSlots` returns early when there are no free slots, that early return already
implies active agents, so no auto-stop is needed there.

Add the controls:

```swift
    /// No new claims or spawns; running agents continue (spec §4).
    func pause() {
        guard record.state == .running || record.state == .draining else { return }
        record.state = .paused
        log(.pause)
        changed()
    }

    func resume() async {
        guard record.state == .paused || record.state == .draining else { return }
        record.state = .running
        record.banner = nil
        record.spawnFailures = [:]
        log(.resume)
        changed()
        await tick()
    }

    /// Like pause, and the swarm becomes stopped when the last working agent goes idle.
    func drain() {
        guard record.state == .running || record.state == .paused else { return }
        record.state = .draining
        log(.drain)
        finishDrainIfIdle()
        changed()
    }

    /// The swarm keeps nothing running: leases are released and agents leave it. Their tabs stay
    /// open, and their claims stay with them — turning Flight Control off is what returns claims.
    func stop(reason: String) {
        guard record.state != .stopped else { return }
        record.state = .stopped
        for agent in record.agents where agent.state != .done && agent.state != .handedOff {
            if let lease = agent.lease { deps.allocator.release(lease.lease) }
            record.update(agent.session) { $0.state = .done; $0.stateSince = now() }
        }
        log(.stop, detail: reason)
        changed()
    }

    private func finishDrainIfIdle() {
        guard record.state == .draining, record.activeCount == 0, launches.isEmpty, pendingSpawnCount == 0 else { return }
        stop(reason: "drained")
    }
```

- [ ] **Step 5: Run all controller tests**

Run: `FD_TEST_FILTER=SwarmControllerLifecycleTests,SwarmControllerCompletionTests,SwarmControllerWaitingTests,SwarmControllerReuseTests,SwarmControllerFillTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. If a Task 7a–7d test now fails because a single-tick test swarm auto-stopped,
the failing test ran with an empty ready list and no agents; add a second ready task with no lease
(it waits) to that test rather than weakening the auto-stop rule.

- [ ] **Step 6: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Swarm/SwarmPlanner.swift Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerLifecycleTests.swift
git commit -m "feat: pause, resume, drain and stop a swarm, and stop it when it runs out of work" -m "Pause stops claims before the next tick; resume clears the banner and the failure count; drain becomes stopped when the last working agent goes idle; stop releases leases and retires agents while their tabs and claims stay. A swarm with nothing ready, nothing waiting and nothing working stops itself; unroutable tasks do not keep it alive." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7f: Spawn failures and stuck-at-start

**Files:**
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift` (`noteSpawnFailure`, `deliveryFailed`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerFailureTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §10. A config that keeps failing pauses the swarm with a banner instead of burning
/// through every ready task; an agent that never shows a composer gives its claim back and is
/// never typed into again.
@MainActor
final class SwarmControllerFailureTests: XCTestCase {
    func testThreeSpawnFailuresInARowOnOneConfigPauseTheSwarm() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 3)
        rig.launcher.createResults = Array(repeating: .failure(.launchFailed("Agent Mail boot failed")), count: 3)
        rig.backend.ready = ["fx-1", "fx-2", "fx-3"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .paused)
        XCTAssertEqual(c.record.banner,
                       "Paused: 3 launches in a row failed for codex|gpt-6-sol||codex-subs — Agent Mail boot failed")
        XCTAssertTrue(rig.backend.claims.isEmpty)
    }

    func testASuccessResetsTheCount() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 3)
        rig.launcher.createResults = [.failure(.launchFailed("x")), .failure(.launchFailed("x"))]
        rig.backend.ready = ["fx-1", "fx-2", "fx-3"].map { SwarmFixtures.task($0, SwarmFixtures.block()) }
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .running)
        XCTAssertNil(c.record.spawnFailures[ConfigKey(SwarmFixtures.block()).rawValue])
    }

    func testFailuresOnDifferentConfigsDoNotAddUp() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 2); rig.leases("other", 1)
        rig.launcher.createResults = Array(repeating: .failure(.launchFailed("x")), count: 3)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block()),
                             SwarmFixtures.task("fx-2", SwarmFixtures.block()),
                             SwarmFixtures.task("fx-3", SwarmFixtures.block("other"))]
        let c = rig.controller(rig.record(cap: 3))
        await rig.run(c)
        XCTAssertEqual(c.record.state, .running)
    }

    func testNoComposerWithinTwoMinutesReturnsTheClaimAndMarksStuck() async {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        let ref = SessionRef(id: UUID(), agentName: "BlueLake")
        rig.launcher.createResults = [.success(ref)]
        rig.launcher.deliverFailures[ref.id] = .composerTimeout
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(rig.record(cap: 1))
        await rig.run(c)
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        let agent = c.record.agent(ref.id)
        XCTAssertEqual(agent?.state, .idle)
        XCTAssertEqual(agent?.marker, "stuck at start")
        XCTAssertEqual(agent?.excludedFromReuse, true)
        XCTAssertTrue(rig.store.log(swarm: c.record.id).contains { $0.kind == .stuck && $0.task == "fx-1" })
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmControllerFailureTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `testThreeSpawnFailuresInARowOnOneConfigPauseTheSwarm` and
`testNoComposerWithinTwoMinutesReturnsTheClaimAndMarksStuck` fail.

- [ ] **Step 3: Replace the two bodies**

```swift
    private func noteSpawnFailure(_ key: ConfigKey, error: SpawnError) {
        let count = (record.spawnFailures[key.rawValue] ?? 0) + 1
        record.spawnFailures[key.rawValue] = count
        log(.spawnFailed, detail: "\(key): \(Self.describe(error))")
        // Spec §10: three in a row on one config pause the swarm, so a broken login or a missing
        // Agent Mail does not chew through every ready task.
        guard count >= SwarmTiming.spawnFailureLimit, record.state == .running else { return }
        record.state = .paused
        record.banner = "Paused: \(count) launches in a row failed for \(key) — \(Self.describe(error))"
        log(.pause, detail: record.banner ?? "")
    }

    private func deliveryFailed(_ session: UUID, task: String, error: SpawnError) async {
        // Spec §10: the claim goes back to open and the agent is left alone (not killed), but a
        // tab that never showed a composer is never typed into again.
        _ = await deps.backend.returnToOpen(task, project: project)
        becomeIdle(session)
        record.update(session) {
            $0.excludedFromReuse = true
            $0.marker = error == .composerTimeout ? "stuck at start" : "prompt failed"
        }
        log(error == .composerTimeout ? .stuck : .error, task: task, session: session, detail: Self.describe(error))
    }
```

- [ ] **Step 4: Run all controller tests**

Run: `FD_TEST_FILTER=SwarmControllerFailureTests,SwarmControllerLifecycleTests,SwarmControllerCompletionTests,SwarmControllerWaitingTests,SwarmControllerReuseTests,SwarmControllerFillTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerFailureTests.swift
git commit -m "feat: pause a swarm after three failed launches and give back a stuck agent's claim" -m "Three spawn failures in a row on one config key pause the swarm with a banner naming the config and the cause. An agent with no composer after two minutes returns its claim to open, is marked stuck at start, and is never reused; it is not killed." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7g: Restart restores paused and reconciles claims made before a crash

**Files:**
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift` (`reconcileAfterRestart`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerRestartTests.swift`

**Interfaces:**
- Produces: `SwarmController.reconcileAfterRestart() async`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §2 and the crash-mid-claim Review Focus item. A launch the crash interrupted never
/// reached its prompt, so the agent never heard about the task: whatever claim landed goes back
/// to open, and the agent is idle and reusable.
@MainActor
final class SwarmControllerRestartTests: XCTestCase {
    func testRestoreReopensAClaimThatLandedBeforeTheCrash() async {
        let rig = SwarmRig()
        var a = rig.agent("BlueLake", state: .starting)
        a.pendingClaim = "fx-1"
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        XCTAssertEqual(c.record.agent(a.session)?.state, .idle)
        XCTAssertNil(c.record.agent(a.session)?.pendingClaim)
    }

    func testRestoreDropsAPendingClaimThatNeverLanded() async {
        let rig = SwarmRig()
        var a = rig.agent("BlueLake", state: .starting)
        a.pendingClaim = "fx-1"
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "open", assignee: nil)
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertTrue(rig.backend.returned.isEmpty, "a claim another agent holds is never touched")
        XCTAssertEqual(c.record.agent(a.session)?.state, .idle)
    }

    func testAClaimedButUnpromptedStarterAlsoGivesItsClaimBack() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .starting, task: "fx-1")
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        XCTAssertNil(c.record.agent(a.session)?.task)
    }

    func testWorkingAgentsAreLeftWorking() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        let c = rig.controller(rig.record(state: .paused, agents: [a]))
        await c.reconcileAfterRestart()
        XCTAssertEqual(c.record.agent(a.session)?.state, .working)
        XCTAssertTrue(rig.backend.returned.isEmpty)
    }

    func testARestoredSwarmClaimsNothingUntilResumed() async throws {
        let rig = SwarmRig()
        rig.leases("codex-subs", 1)
        rig.store.save([rig.record(cap: 1, state: .running)])
        let restored = try XCTUnwrap(rig.store.restore().first)
        XCTAssertEqual(restored.banner, SwarmStore.restartBanner)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let c = rig.controller(restored)
        await rig.run(c)
        XCTAssertTrue(rig.backend.claims.isEmpty)
        await c.resume(); await c.settle()
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmControllerRestartTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `value of type 'SwarmController' has no member 'reconcileAfterRestart'`.

- [ ] **Step 3: Implement**

```swift
    /// Run once for a swarm restored from disk (`SwarmService` calls it). A `starting` agent or one
    /// with a `pendingClaim` was cut off before its prompt landed: any claim it holds goes back
    /// to open, because the agent never heard about the task, and the agent becomes idle.
    func reconcileAfterRestart() async {
        for agent in record.agents where agent.state == .starting || agent.pendingClaim != nil {
            for task in Set([agent.pendingClaim, agent.task].compactMap { $0 }) {
                let reading = await deps.backend.status(task, project: project)
                if reading?.status == "in_progress", reading?.assignee == agent.agentName {
                    _ = await deps.backend.returnToOpen(task, project: project)
                    log(.released, task: task, session: agent.session, detail: "claimed before a restart but never prompted")
                }
            }
            becomeIdle(agent.session)
        }
        changed()
    }
```

- [ ] **Step 4: Run all controller tests**

Run: `FD_TEST_FILTER=SwarmControllerRestartTests,SwarmControllerFailureTests,SwarmControllerLifecycleTests,SwarmControllerCompletionTests,SwarmControllerWaitingTests,SwarmControllerReuseTests,SwarmControllerFillTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmControllerRestartTests.swift
git commit -m "feat: give back claims a crash left unprompted when a swarm is restored" -m "pendingClaim is saved before every br claim. On restore, an agent cut off mid-launch returns whatever claim it holds to open — it never received the task — and becomes idle; a claim that never landed is left alone; working agents keep working. A restored swarm stays paused until a human resumes it." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 7h: `SwarmService` and its wiring into `SessionStore`

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Swarm/SwarmService.swift`
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift` (`recordHandoff`)
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmHost.swift` (`SessionStore` conformance)
- Modify: `Sources/FlightDeck/SessionStore.swift` (both inits, `swarmService`, projections hook, launch-time restore)
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (`swarmsRoot`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmServiceTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmStoreWiringTests.swift`

**Interfaces:**
- Consumes: Tasks 1–7g; `WatchClock.add/fire` (`WatchClock.swift`); `FlywheelObserveService.key` (`FlywheelObserveService.swift:35`).
- Produces (the hand-off API L3-U's `HandoffDriver` consumes is marked ★):
  - `struct FlywheelToolPaths: Equatable { am; br; static let system }`
  - `struct SwarmDependencies { router; kinds; allocator; capacity }`
  - `@MainActor protocol HandoffDecisionSink: AnyObject { var pendingHandoffs: Set<UUID>; func confirmHandoff(session:) -> Bool; func declineHandoff(session:) -> Bool }` ★ (L3-U conforms)
  - `@MainActor final class SwarmService: ObservableObject` with `static let tickInterval: TimeInterval = 5`, `revision`, `onChange`, `weak var handoffDecisions` ★, `dependencies`, `store`, `backend`, `launcher`, `spawner: SwarmSpawner?` ★, `host`, `registry`, `record(forProject:)`, `controller(forProject:)`, `allRecords`, `launch(project:cap:poolCaps:filter:) -> SwarmRecord?`, `pause/resume/drain/stop(project:) -> Bool`, `projectionsChanged(_:)`, `applyProjections(_:) async`, `settle() async`, `agentSnapshots(project:) -> [SwarmAgentSnapshot]` ★, `recordHandoff(project:from:to:block:lease:) -> Bool` ★, `returnClaimToOpen(project:task:) async -> Bool` ★, `confirmHandoff(session:) -> Bool`, `declineHandoff(session:) -> Bool`
  - `SwarmController.recordHandoff(from:to:block:lease:) -> Bool`
  - `SessionStore`: `flywheelTools`, `resolvedSwarmsRoot`, `swarmService`, `swarmServiceIfBuilt`, `swarmDependencies`; both inits gain `flywheelTools: FlywheelToolPaths = .system, swarmsRoot: URL? = nil`

- [ ] **Step 1: Write the failing service tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The service is the swarm's single owner: one swarm per project, restored swarms reconciled
/// once, clock ticks throttled, the Observe task set routed to the right controller, and the
/// record updates L3-U's hand-off driver needs.
@MainActor
final class SwarmServiceTests: XCTestCase {
    private func service(_ rig: SwarmRig, clock: WatchClock? = nil) -> SwarmService {
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher,
                                   spawner: FakeSwarmSpawner(), host: rig.host,
                                   registry: RoutingCapabilityRegistry([]), clock: clock,
                                   now: { [unowned rig] in rig.now })
        service.dependencies = SwarmDependencies(router: rig.router, kinds: rig.kinds,
                                                 allocator: rig.allocator, capacity: rig.capacity)
        return service
    }

    func testLaunchCreatesARunningSwarmAndFillsIt() async throws {
        let rig = SwarmRig(); rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let s = service(rig)
        let record = try XCTUnwrap(s.launch(project: SwarmFixtures.project, cap: 2, poolCaps: [:], filter: .allReady))
        await s.settle()
        XCTAssertEqual(record.state, .running)
        XCTAssertEqual(rig.backend.claims.map(\.task), ["fx-1"])
        XCTAssertEqual(rig.store.load().first?.agents.count, 1, "every change is persisted")
    }

    func testAtMostOneLiveSwarmPerProject() {
        let rig = SwarmRig(); rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let s = service(rig)
        XCTAssertNotNil(s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady))
        XCTAssertNil(s.launch(project: SwarmFixtures.project + "/", cap: 1, poolCaps: [:], filter: .allReady),
                     "the same project by another spelling is still the same project")
    }

    func testARelaunchAfterStopReplacesTheStoppedSwarm() async throws {
        let rig = SwarmRig()
        let s = service(rig)
        let first = try XCTUnwrap(s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady))
        await s.settle()
        XCTAssertEqual(s.record(forProject: SwarmFixtures.project)?.state, .stopped, "nothing ready: it stopped itself")
        let second = try XCTUnwrap(s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady))
        XCTAssertNotEqual(first.id, second.id)
    }

    func testWithoutDependenciesNothingLaunches() {
        let rig = SwarmRig()
        let s = service(rig); s.dependencies = nil
        XCTAssertNil(s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady))
    }

    func testRestoredSwarmsArePausedAndReconciledOnce() async {
        let rig = SwarmRig()
        var a = rig.agent("BlueLake", state: .starting); a.pendingClaim = "fx-1"
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        rig.store.save([rig.record(state: .running, agents: [a])])
        let s = service(rig)
        await s.settle()
        XCTAssertEqual(s.record(forProject: SwarmFixtures.project)?.state, .paused)
        XCTAssertEqual(s.record(forProject: SwarmFixtures.project)?.banner, SwarmStore.restartBanner)
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
        s.dependencies = s.dependencies   // a re-set must not reconcile again
        await s.settle()
        XCTAssertEqual(rig.backend.returned, ["fx-1"])
    }

    func testProjectionsDriveCompletion() async throws {
        let rig = SwarmRig(); rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let s = service(rig)
        _ = s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady)
        await s.settle()
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "closed", assignee: "Agent1")
        let projection = FlywheelProjection.project(
            FlywheelSnapshot(agents: [], beads: [], reservations: nil, depEdges: nil, events: nil),
            now: rig.now, stallThreshold: 600, previous: nil)
        await s.applyProjections([FlywheelObserveService.key(SwarmFixtures.project): projection])
        XCTAssertEqual(s.record(forProject: SwarmFixtures.project)?.agents.first?.lastTask, "fx-1")
    }

    func testClockTicksAreThrottled() async {
        let rig = SwarmRig()
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]   // no lease: waits, keeps running
        let clock = WatchClock(appIsActive: { true })
        let s = service(rig, clock: clock)
        _ = s.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady)
        await s.settle()
        let afterLaunch = rig.backend.readyCalls
        clock.fire(); await s.settle()
        clock.fire(); await s.settle()
        XCTAssertEqual(rig.backend.readyCalls, afterLaunch + 1, "two beats inside five seconds tick once")
        rig.now += SwarmService.tickInterval
        clock.fire(); await s.settle()
        XCTAssertEqual(rig.backend.readyCalls, afterLaunch + 2)
    }

    func testHandoffMovesTheTaskToTheNewAgent() async throws {
        let rig = SwarmRig()
        let lease = SwarmFixtures.lease("codex-subs", "Old")
        let a = rig.agent("BlueLake", lease: lease, state: .working, task: "fx-1")
        rig.store.save([rig.record(state: .paused, agents: [a])])
        let s = service(rig)
        await s.settle()
        let new = SessionRef(id: UUID(), agentName: "GreenFox")
        XCTAssertTrue(s.recordHandoff(project: SwarmFixtures.project, from: a.session, to: new,
                                      block: SwarmFixtures.block(), lease: nil))
        let record = try XCTUnwrap(s.record(forProject: SwarmFixtures.project))
        XCTAssertEqual(record.agent(a.session)?.state, .handedOff)
        XCTAssertEqual(record.agent(a.session)?.handedOffTo, new.id)
        XCTAssertEqual(record.agent(new.id)?.task, "fx-1")
        XCTAssertEqual(record.agent(new.id)?.handedOffFrom, a.session)
        XCTAssertEqual(rig.allocator.released, [lease])
    }

    func testAgentSnapshotsListWorkingAgents() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        let b = rig.agent("GreenFox", state: .idle)
        rig.store.save([rig.record(state: .paused, agents: [a, b])])
        let s = service(rig)
        await s.settle()
        let snapshots = s.agentSnapshots(project: SwarmFixtures.project)
        XCTAssertEqual(snapshots.map(\.agentName), ["BlueLake"])
        XCTAssertEqual(snapshots.first?.task?.id, "fx-1")
    }

    func testHandoffDecisionsGoToTheSink() async {
        final class Sink: HandoffDecisionSink {
            var pendingHandoffs: Set<UUID> = []
            var confirmed: [UUID] = []
            func confirmHandoff(session: UUID) -> Bool { confirmed.append(session); return true }
            func declineHandoff(session: UUID) -> Bool { false }
        }
        let rig = SwarmRig(); let s = service(rig)
        XCTAssertFalse(s.confirmHandoff(session: UUID()), "no driver wired: nothing to confirm")
        let sink = Sink(); s.handoffDecisions = sink
        let id = UUID()
        XCTAssertTrue(s.confirmHandoff(session: id))
        XCTAssertEqual(sink.confirmed, [id])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmServiceTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'SwarmService' in scope`.

- [ ] **Step 3: Add `recordHandoff` to the controller**

```swift
    /// L3-U's hand-off (spec §4): the old agent is marked handed off and its lease released (its
    /// account is past hard), and the new agent carries the same task forward.
    @discardableResult
    func recordHandoff(from old: UUID, to new: SessionRef, block: ExecutionBlock, lease: AccountLease?) -> Bool {
        guard let previous = record.agent(old), previous.state == .working || previous.state == .idle else { return false }
        record.update(old) {
            $0.state = .handedOff; $0.handedOffTo = new.id; $0.lastTask = $0.task; $0.task = nil; $0.stateSince = now()
        }
        if let held = previous.lease { deps.allocator.release(held.lease) }
        var next = SwarmAgentRecord(session: new.id, agentName: new.agentName ?? "", block: block, lease: lease,
                                    task: previous.task, state: .working, stateSince: now())
        next.handedOffFrom = old
        record.agents.append(next)
        log(.handoff, task: previous.task, session: new.id, detail: "\(previous.agentName) → \(new.agentName ?? "?")")
        changed()
        return true
    }
```

- [ ] **Step 4: Implement `SwarmService.swift`**

```swift
import Combine
import Foundation
import IntakeKit

/// Where `am` and `br` are. `system` resolves them on PATH; the UI-test fixture backend points
/// them at its stubs (Task 14).
struct FlywheelToolPaths: Equatable {
    var am: String
    var br: String
    static let system = FlywheelToolPaths(am: "am", br: "br")
}

/// The L3-R/L3-U conformers a swarm routes and leases through. Nil until the integration branch
/// (or the Debug fixture backend) supplies them; without them nothing launches.
struct SwarmDependencies {
    var router: any Router
    var kinds: any KindRegistry
    var allocator: any PoolAllocator
    var capacity: any CapacityReader
}

/// L3-U's hand-off driver answers these; L3-S only routes the phone's decision to it.
@MainActor
protocol HandoffDecisionSink: AnyObject {
    var pendingHandoffs: Set<UUID> { get }
    func confirmHandoff(session: UUID) -> Bool
    func declineHandoff(session: UUID) -> Bool
}

/// Owns every project's swarm: the records (`swarms.json`), one controller per live swarm, the
/// clock subscription, and the API every view, the wire and L3-U's hand-off driver use.
@MainActor
final class SwarmService: ObservableObject {
    /// A tick reads three br commands; the clock beats twice a second. Five seconds is quick
    /// enough to feel fed and cheap enough for a background Mac.
    static let tickInterval: TimeInterval = 5

    @Published private(set) var revision = 0
    var onChange: (() -> Void)?
    weak var handoffDecisions: HandoffDecisionSink?

    let store: SwarmStore
    let backend: SwarmBackend
    let launcher: SwarmAgentLauncher
    let spawner: SwarmSpawner?
    let host: SwarmHost
    let registry: RoutingCapabilityRegistry
    private let now: () -> Date
    private weak var clock: WatchClock?

    private(set) var records: [String: SwarmRecord] = [:]
    private var controllers: [String: SwarmController] = [:]
    private var needsReconcile: Set<String> = []
    private var lastClockTick = Date.distantPast
    private var work: [Task<Void, Never>] = []

    var dependencies: SwarmDependencies? {
        didSet { rebuildControllers() }
    }

    init(store: SwarmStore, backend: SwarmBackend, launcher: SwarmAgentLauncher, spawner: SwarmSpawner?,
         host: SwarmHost, registry: RoutingCapabilityRegistry, clock: WatchClock?, now: @escaping () -> Date = Date.init) {
        self.store = store; self.backend = backend; self.launcher = launcher; self.spawner = spawner
        self.host = host; self.registry = registry; self.clock = clock; self.now = now
        for record in store.restore() {
            let key = Self.key(record.project)
            records[key] = record
            if record.state != .stopped { needsReconcile.insert(key) }
        }
        clock?.add(self) { [weak self] in self?.clockTick() }
    }

    static func key(_ path: String) -> String { FlywheelObserveService.key(path) }

    func record(forProject path: String) -> SwarmRecord? { records[Self.key(path)] }
    func controller(forProject path: String) -> SwarmController? { controllers[Self.key(path)] }
    var allRecords: [SwarmRecord] { records.values.sorted { $0.createdAt < $1.createdAt } }

    /// At most one swarm per project (spec §2): a stopped one is replaced, a live one refuses.
    @discardableResult
    func launch(project: String, cap: Int, poolCaps: [String: Int], filter: SwarmFilter) -> SwarmRecord? {
        guard dependencies != nil else { return nil }
        let key = Self.key(project)
        if let existing = records[key], existing.state != .stopped { return nil }
        let record = SwarmRecord(id: UUID(), project: key, cap: max(1, cap), poolCaps: poolCaps, filter: filter,
                                 state: .running, agents: [], createdAt: now())
        guard let controller = makeController(record) else { return nil }
        records[key] = record
        controllers[key] = controller
        store.append(SwarmLogEntry(at: now(), kind: .launch, detail: "cap \(record.cap)"), swarm: record.id)
        persist(); publish()
        track { await controller.tick() }
        return record
    }

    @discardableResult func pause(project: String) -> Bool {
        guard let c = controller(forProject: project) else { return false }
        c.pause(); return true
    }
    @discardableResult func resume(project: String) -> Bool {
        guard let c = controller(forProject: project) else { return false }
        track { await c.resume() }; return true
    }
    @discardableResult func drain(project: String) -> Bool {
        guard let c = controller(forProject: project) else { return false }
        c.drain(); return true
    }
    @discardableResult func stop(project: String) -> Bool {
        guard let c = controller(forProject: project) else { return false }
        c.stop(reason: "stopped from the menu"); return true
    }

    /// The Observe watcher's projections. Only in-progress ids matter: a claimed task leaving
    /// that set is what `SwarmController.taskSetChanged` investigates.
    func projectionsChanged(_ projections: [String: FlywheelProjection]) {
        track { await self.applyProjections(projections) }
    }

    func applyProjections(_ projections: [String: FlywheelProjection]) async {
        for (key, projection) in projections {
            guard let controller = controllers[key] else { continue }
            let inProgress = Set(projection.beadsByID.values.filter { $0.status == "in_progress" }.map(\.id))
            await controller.taskSetChanged(inProgress: inProgress)
        }
    }

    /// Waits for every task this service started and every launch its controllers started.
    func settle() async {
        while !work.isEmpty {
            let pending = work; work = []
            for task in pending { await task.value }
        }
        for controller in controllers.values { await controller.settle() }
    }

    // MARK: Hand-off (consumed by L3-U's HandoffDriver)

    func agentSnapshots(project: String) -> [SwarmAgentSnapshot] {
        guard let record = record(forProject: project) else { return [] }
        let url = URL(fileURLWithPath: record.project, isDirectory: true)
        return record.agents.filter { $0.state == .working }.map { agent in
            SwarmAgentSnapshot(session: SessionRef(id: agent.session, agentName: agent.agentName), agentName: agent.agentName,
                               block: agent.block.block, lease: agent.lease?.lease,
                               task: agent.task.map { TaskRef(id: $0, project: url) })
        }
    }

    @discardableResult
    func recordHandoff(project: String, from old: UUID, to new: SessionRef, block: ExecutionBlock, lease: AccountLease?) -> Bool {
        controller(forProject: project)?.recordHandoff(from: old, to: new, block: block, lease: lease) ?? false
    }

    /// A hand-off driver returns the old agent's claim before `spawner.spawn` claims for the new one.
    func returnClaimToOpen(project: String, task: String) async -> Bool {
        await backend.returnToOpen(task, project: URL(fileURLWithPath: Self.key(project), isDirectory: true))
    }

    func confirmHandoff(session: UUID) -> Bool { handoffDecisions?.confirmHandoff(session: session) ?? false }
    func declineHandoff(session: UUID) -> Bool { handoffDecisions?.declineHandoff(session: session) ?? false }

    // MARK: Internals

    private func clockTick() {
        guard now().timeIntervalSince(lastClockTick) >= Self.tickInterval else { return }
        lastClockTick = now()
        for controller in controllers.values where controller.record.state == .running || controller.record.state == .draining {
            track { await controller.tick() }
        }
    }

    /// Controllers are rebuilt from the records whenever the dependencies change — the records,
    /// not the controllers, are the source of truth. A restored swarm is reconciled once.
    private func rebuildControllers() {
        controllers = [:]
        guard dependencies != nil else { return }
        for (key, record) in records where record.state != .stopped {
            guard let controller = makeController(record) else { continue }
            controllers[key] = controller
            if needsReconcile.remove(key) != nil { track { await controller.reconcileAfterRestart() } }
        }
    }

    private func makeController(_ record: SwarmRecord) -> SwarmController? {
        guard let deps = dependencies else { return nil }
        let registry = self.registry
        let controller = SwarmController(
            record: record, store: store,
            deps: .init(backend: backend, launcher: launcher, host: host, router: deps.router, kinds: deps.kinds,
                        allocator: deps.allocator, capacity: deps.capacity,
                        catalogs: { await registry.catalogs(enabled: Set(registry.harnesses)) }),
            now: now)
        controller.onChange = { [weak self] updated in
            guard let self else { return }
            self.records[Self.key(updated.project)] = updated
            self.persist()
            self.publish()
        }
        return controller
    }

    private func track(_ body: @escaping @MainActor () async -> Void) {
        work.append(Task { await body() })
    }

    private func persist() { store.save(allRecords) }

    private func publish() {
        revision += 1
        onChange?()
    }
}
```

- [ ] **Step 5: Run the service tests**

Run: `FD_TEST_FILTER=SwarmServiceTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 6: Write the failing wiring tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The store is the swarm's host and the owner of its service. A swarm on disk must come back
/// paused at launch, and the store must answer the host questions from its real state.
@MainActor
final class SwarmStoreWiringTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("swarm-wiring-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTheStoreRestoresSwarmsFromItsRoot() {
        SwarmStore(root: root).save([SwarmRecord(id: UUID(), project: "/tmp/p", cap: 2, poolCaps: [:],
                                                 filter: .allReady, state: .running, agents: [],
                                                 createdAt: Date(timeIntervalSince1970: 1_790_000_000))])
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        XCTAssertEqual(store.swarmService.record(forProject: "/tmp/p")?.state, .paused)
    }

    func testAStoreWithNoSwarmsDoesNotBuildTheService() {
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        XCTAssertNil(store.swarmServiceIfBuilt)
    }

    func testDependenciesReachTheService() {
        let store = SessionStore(provider: nil, persistence: nil, swarmsRoot: root)
        let service = store.swarmService
        XCTAssertNil(service.dependencies)
        store.swarmDependencies = SwarmDependencies(router: FakeRouter(), kinds: FakeKindRegistry(),
                                                    allocator: FakePoolAllocator(), capacity: FakeCapacityReader())
        XCTAssertNotNil(service.dependencies)
    }

    func testTheStoreAnswersAsASwarmHost() {
        let store = SessionStore(provider: nil, persistence: nil)
        let identity = FlywheelIdentity(agentName: "BlueLake", project: "/tmp/p")
        let s = store.newSession(in: URL(fileURLWithPath: "/tmp/p", isDirectory: true), flywheelIdentity: identity)
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .idle)])
        XCTAssertTrue(store.isAgentIdle(s.id))
        store.applyRegistryForTesting([s.id: SessionStatus(activity: .busy)])
        XCTAssertFalse(store.isAgentIdle(s.id))
        let agents = store.flywheelAgents(inProject: "/tmp/p/")
        XCTAssertEqual(agents.map(\.agentName), ["BlueLake"])
        XCTAssertEqual(agents.map(\.session), [s.id])
    }
}
```

- [ ] **Step 7: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmStoreWiringTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `extra argument 'swarmsRoot' in call`.

- [ ] **Step 8: Wire `SessionStore`**

1. Designated `init(provider:...)` (`SessionStore.swift:1973`): append parameters
   `flywheelTools: FlywheelToolPaths = .system, swarmsRoot: URL? = nil` after `intakesRoot`, and in
   the body add `self.flywheelTools = flywheelTools` and `self.swarmsRoot = swarmsRoot` beside
   `self.intakesRoot = intakesRoot`.

2. Convenience `init(ghostty:...)` (`SessionStore.swift:2060`): append the same two parameters
   after `intakesRoot`, and change its `self.init(...)` call to:

```swift
        self.init(
            provider: ghostty,
            persistence: persistence,
            preferences: preferences,
            daemon: daemon,
            flywheelCoordinator: FlywheelCoordinator(amPath: flywheelTools.am),
            flywheelSetup: FlywheelSetup(amPath: flywheelTools.am, brPath: flywheelTools.br),
            flywheelObserveReads: FlywheelReadCommands(amPath: flywheelTools.am, brPath: flywheelTools.br),
            intakesRoot: intakesRoot,
            flywheelTools: flywheelTools,
            swarmsRoot: swarmsRoot
        )
```

   At the end of that convenience init (after `clock.add(self) { [weak self] in self?.maintenanceTick() }`):

```swift
        // A swarm on disk shows its "paused after restart" banner at launch, so the service is
        // built now when there is something to restore — and not otherwise, so a Mac that never
        // ran a swarm never builds one.
        if FileManager.default.fileExists(atPath: resolvedSwarmsRoot.appendingPathComponent("swarms.json").path) {
            _ = swarmService
        }
```

3. Beside `intakesRoot`/`resolvedIntakesRoot` (`SessionStore.swift:1296-1302`):

```swift
    /// The `am`/`br` executables every flywheel command runs. `system` except under the Debug
    /// fixture backend.
    let flywheelTools: FlywheelToolPaths

    /// Where `swarms.json` lives, as handed to `init` — nil for every store but the app's own,
    /// for the reason `intakesRoot` gives: a test must never restore the developer's swarms.
    private let swarmsRoot: URL?

    lazy var resolvedSwarmsRoot: URL = swarmsRoot
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("FlightDeck-swarms-\(UUID().uuidString)", isDirectory: true)

    private var swarmServiceStorage: SwarmService?
    private var swarmChangeForward: AnyCancellable?

    /// The routing/capacity conformers (L3-R/L3-U), set by the integration branch or the Debug
    /// fixture backend. Forwarded to the service whenever it changes.
    var swarmDependencies: SwarmDependencies? {
        didSet { swarmServiceStorage?.dependencies = swarmDependencies }
    }

    /// Built on first use. Its changes are forwarded as this store's, because the sidebar and
    /// header observe only the store.
    var swarmService: SwarmService {
        if let built = swarmServiceStorage { return built }
        let spawner = StoreSwarmSpawner.live(store: self)
        let service = SwarmService(
            store: SwarmStore(root: resolvedSwarmsRoot),
            backend: BrSwarmBackend(runner: SystemFlywheelProcessRunner(), brPath: flywheelTools.br, amPath: flywheelTools.am),
            launcher: spawner, spawner: spawner, host: self, registry: routingCapabilities, clock: clock)
        service.dependencies = swarmDependencies
        swarmChangeForward = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        swarmServiceStorage = service
        return service
    }

    var swarmServiceIfBuilt: SwarmService? { swarmServiceStorage }
```

4. In the `observeService` lazy initializer (`SessionStore.swift:1282`), extend the closure:

```swift
        service.onProjectionsChanged = { [weak self] projections in
            self?.flywheelNotifier?.evaluate(projectsByKey: projections)
            // Completion detection (spec §4): the swarm reads the same polls Observe does.
            self?.swarmServiceStorage?.projectionsChanged(projections)
        }
```

5. Append to `SwarmHost.swift`:

```swift
extension SessionStore: SwarmHost {
    func isAgentIdle(_ id: UUID) -> Bool { status(for: id)?.activity == .idle }

    func flywheelAgents(inProject project: String) -> [(session: UUID, agentName: String)] {
        let key = FlywheelObserveService.key(project)
        return repos.flatMap(\.sessions).compactMap { session in
            guard let identity = session.flywheelIdentity, FlywheelObserveService.key(identity.project) == key else { return nil }
            return (session.id, identity.agentName)
        }
    }
}
```

   (`sessionExists(_:)`, `wakeIfAsleep(_:)` and `lastActiveAt(for:)` already exist with the
   protocol's signatures.)

6. In `FlightDeckApp.makeStore` (`FlightDeckApp.swift`), add to the `SessionStore(...)` call after
   `intakesRoot:`:

```swift
            // Beside `intakes/`, honouring `-FlightDeckStateDir` the same way. A reset run gets a
            // scratch root (nil), so a UI test never restores the developer's swarms.
            swarmsRoot: resetState ? nil : (Self.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
```

- [ ] **Step 9: Run the swarm suites and the store suites that construct stores**

Run: `FD_TEST_FILTER=SwarmStoreWiringTests,SwarmServiceTests,ObserveServiceWiringTests,SessionPersistenceTests,StateDirectoryOverrideTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 10: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/SwarmService.swift Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift Sources/FlightDeck/FlightControl/Swarm/SwarmHost.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/FlightDeckApp.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmServiceTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmStoreWiringTests.swift
git commit -m "feat: own every project's swarm in one service ticked on the shared clock" -m "SwarmService restores swarms.json at launch (paused, reconciled once), keeps at most one live swarm per project, ticks controllers at most every five seconds, routes the Observe watcher's in-progress set to completion detection, and exposes the record updates L3-U's hand-off driver needs. SessionStore owns it, is its host, and builds it at launch only when a swarm is on disk." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The launch sheet

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Swarm/LaunchSheet.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (`swarmLaunchRequest`, `requestSwarmLaunch`)
- Modify: `Sources/FlightDeck/RootView.swift` (sheet), `Sources/FlightDeck/ProjectHeaderRow.swift` (menu item),
  `Sources/FlightDeck/Intake/IntakeDetailView.swift` (`onRunTasks`), `Sources/FlightDeck/ProjectView.swift` (pass it)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/LaunchSheetModelTests.swift`

**Interfaces:**
- Consumes: `SwarmBackend.readyTasks/writeBlock`, `SwarmService.launch`, `RoutingCapabilityRegistry.catalogs`,
  `Router.assign`, `KindRegistry.kinds`, `CapacityReader.headroom`, `L3Fixtures.brRows()/kinds()`.
- Produces:
  - `struct SwarmLaunchRequest: Identifiable, Equatable { id: UUID; project: String; filter: SwarmFilter; title: String }`
  - `@MainActor final class LaunchSheetModel: ObservableObject` with `enum SourceChip`, `struct Row`, `rows`, `cap`, `poolCaps`, `error`, `pools`, `canLaunch`, `load() async`, `override(_:harness:model:knobs:pool:) async -> Bool`, `launch() async -> SwarmRecord?`, `static func parseKnobs(_:) -> [String: String]?`
  - `struct LaunchSheet: View` (accessibility ids: `swarm-launch-sheet`, `launch-row-<id>`, `launch-cap`, `launch-swarm`, `launch-cancel`, `launch-override-<id>`)
  - `SessionStore.swarmLaunchRequest: SwarmLaunchRequest?` (`@Published`), `requestSwarmLaunch(project:filter:title:)`

- [ ] **Step 1: Write the failing model tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// What the sheet shows before Launch (spec §3): every admitted ready task with its routing, the
/// router re-run for unpinned blocks, pinned ones untouched, unroutable ones greyed with a
/// reason, and an override that pins and writes the block back.
@MainActor
final class LaunchSheetModelTests: XCTestCase {
    private let project = "/tmp/launch-project"
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    private func rig() throws -> (SwarmRig, SwarmService, LaunchSheetModel, FakeRouter) {
        let rig = SwarmRig()
        rig.backend.ready = try L3Fixtures.brRows().map { row in
            ReadyTask(id: row["id"] as! String, title: row["title"] as! String, priority: 2, rank: nil,
                      agentContext: row["agent_context"] as? String)
        }
        rig.kinds.byProject[URL(fileURLWithPath: project, isDirectory: true)] = try L3Fixtures.kinds().kinds
        let routed = ExecutionBlock(kind: "snapshot-tests", harness: "codex", model: "gpt-6-terra", pool: "codex-subs",
                                    source: AssignmentSource(by: .index, reason: "index", at: at))
        rig.router.assignments["snapshot-tests"] = Assignment(block: routed)
        let codex = FakeRoutingCapabilities(); codex.harness = "codex"
        let claude = FakeRoutingCapabilities(); claude.harness = "claude"
        let registry = RoutingCapabilityRegistry([codex, claude])
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: registry, clock: nil, now: { [unowned rig] in rig.now })
        service.dependencies = SwarmDependencies(router: rig.router, kinds: rig.kinds, allocator: rig.allocator, capacity: rig.capacity)
        let model = LaunchSheetModel(request: SwarmLaunchRequest(project: project, filter: .allReady, title: "p"),
                                     backend: rig.backend, service: service, registry: registry, now: { [unowned rig] in rig.now })
        return (rig, service, model, rig.router)
    }

    func testUnpinnedBlocksAreReroutedAndPinnedOnesKept() async throws {
        let (_, _, model, router) = try rig()
        await model.load()
        let valid = try XCTUnwrap(model.rows.first { $0.id == "fx-valid" })
        XCTAssertEqual(valid.block?.model, "gpt-6-terra")
        XCTAssertEqual(valid.chip, .index)
        XCTAssertTrue(valid.changed)
        let pinned = try XCTUnwrap(model.rows.first { $0.id == "fx-pinned" })
        XCTAssertEqual(pinned.chip, .pinned)
        XCTAssertEqual(pinned.block?.model, "opus")
        XCTAssertFalse(pinned.changed)
        XCTAssertEqual(router.assignCalls, ["snapshot-tests"], "the router never sees a pinned block")
    }

    func testUnroutableRowsCarryTheirReason() async throws {
        let (_, _, model, _) = try rig()
        await model.load()
        func reason(_ id: String) -> String? { model.rows.first { $0.id == id }?.unroutable }
        XCTAssertEqual(reason("fx-invalid"), "missing model")
        XCTAssertEqual(reason("fx-none"), "no execution block")
        XCTAssertEqual(reason("fx-newer"), "written by a newer Flight Deck (v2)")
        XCTAssertNil(reason("fx-valid"))
    }

    func testTheIntakeFilterLimitsTheRows() async throws {
        let (rig, service, _, _) = try rig()
        let model = LaunchSheetModel(request: SwarmLaunchRequest(project: project, filter: .intake(id: UUID(), tasks: ["fx-pinned"]), title: "p"),
                                     backend: rig.backend, service: service, registry: service.registry, now: { rig.now })
        await model.load()
        XCTAssertEqual(model.rows.map(\.id), ["fx-pinned"])
    }

    func testOverridePinsAndWritesTheBlock() async throws {
        let (rig, _, model, _) = try rig()
        await model.load()
        let ok = await model.override("fx-valid", harness: "claude", model: "opus", knobs: ["effort": "high"], pool: "claude-subs")
        XCTAssertTrue(ok)
        let written = try XCTUnwrap(rig.backend.written.last)
        XCTAssertEqual(written.task, "fx-valid")
        XCTAssertTrue(written.block.pinned)
        XCTAssertEqual(written.block.source.by, .manual)
        XCTAssertEqual(written.block.kind, "snapshot-tests", "an override keeps the task's kind")
        XCTAssertEqual(model.rows.first { $0.id == "fx-valid" }?.chip, .pinned)
    }

    func testLaunchWritesBackReroutedBlocksThenStartsTheSwarm() async throws {
        let (rig, service, model, _) = try rig()
        await model.load()
        model.cap = 2
        let record = await model.launch()
        XCTAssertEqual(record?.cap, 2)
        XCTAssertEqual(rig.backend.written.map(\.task), ["fx-valid"], "only the re-routed block is written")
        XCTAssertNotNil(service.record(forProject: project))
    }

    func testALocalPoolDefaultsToItsOwnSlotCount() async throws {
        let (rig, _, model, _) = try rig()
        rig.capacity.byPool["codex-subs"] = [
            AccountHeadroom(account: AccountRef(harness: "codex", id: nil, label: "slot 1"), worstUtilization: nil, state: .underSoft, resetsAt: nil),
            AccountHeadroom(account: AccountRef(harness: "codex", id: nil, label: "slot 2"), worstUtilization: nil, state: .underSoft, resetsAt: nil),
        ]
        await model.load()
        XCTAssertEqual(model.poolCaps["codex-subs"], 2)
        XCTAssertNil(model.poolCaps["claude-subs"], "an account pool is bounded by the overall cap")
    }

    func testWithoutRoutingTheSheetSaysSoAndCannotLaunch() async throws {
        let (_, service, model, _) = try rig()
        service.dependencies = nil
        await model.load()
        XCTAssertEqual(model.error, "Flight Control routing is not connected yet.")
        XCTAssertFalse(model.canLaunch)
    }

    func testParseKnobs() {
        XCTAssertEqual(LaunchSheetModel.parseKnobs("effort=high, agent=build"), ["effort": "high", "agent": "build"])
        XCTAssertEqual(LaunchSheetModel.parseKnobs(""), [:])
        XCTAssertNil(LaunchSheetModel.parseKnobs("effort"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=LaunchSheetModelTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'LaunchSheetModel' in scope`.

- [ ] **Step 3: Implement `LaunchSheet.swift`**

```swift
import IntakeKit
import SwiftUI

/// Opens the launch sheet for one project: from a released intake (`.intake`) or the project
/// header's menu (`.allReady`).
struct SwarmLaunchRequest: Identifiable, Equatable {
    let id = UUID()
    let project: String
    let filter: SwarmFilter
    let title: String
}

@MainActor
final class LaunchSheetModel: ObservableObject {
    enum SourceChip: String, Equatable {
        case rule, index, `default`, spill, manual, pinned
        init(_ kind: AssignmentSourceKind) {
            switch kind {
            case .rule: self = .rule
            case .index: self = .index
            case .default: self = .default
            case .spill: self = .spill
            case .manual: self = .manual
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        var block: ExecutionBlock?
        var chip: SourceChip?
        /// Why this task cannot run, shown greyed. Nil for a routable row.
        var unroutable: String?
        var existingContext: String?
        /// Re-routed here and so written back on Launch, so the controller (which reads blocks
        /// from br) runs exactly what the sheet showed.
        var changed: Bool

        var summary: String {
            guard let b = block else { return "—" }
            let knobs = b.knobs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
            return [b.harness.rawValue, b.model, knobs.isEmpty ? nil : knobs, b.pool.rawValue].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var cap: Int = 3
    @Published var poolCaps: [String: Int] = [:]

    let request: SwarmLaunchRequest
    private let backend: SwarmBackend
    private let service: SwarmService
    private let registry: RoutingCapabilityRegistry
    private let now: () -> Date
    private var projectURL: URL { URL(fileURLWithPath: request.project, isDirectory: true) }

    init(request: SwarmLaunchRequest, backend: SwarmBackend, service: SwarmService,
         registry: RoutingCapabilityRegistry, now: @escaping () -> Date = Date.init) {
        self.request = request; self.backend = backend; self.service = service; self.registry = registry; self.now = now
    }

    var pools: [String] { Set(rows.compactMap { $0.unroutable == nil ? $0.block?.pool.rawValue : nil }).sorted() }
    var canLaunch: Bool { service.dependencies != nil && rows.contains { $0.unroutable == nil } }

    func load() async {
        loading = true
        defer { loading = false }
        guard let deps = service.dependencies else { error = "Flight Control routing is not connected yet."; return }
        let tasks: [ReadyTask]
        switch await backend.readyTasks(project: projectURL) {
        case .success(let ready): tasks = ready
        case .failure(let failure): error = failure.message; return
        }
        let kinds = (try? deps.kinds.kinds(project: projectURL)) ?? []
        let catalogs = await registry.catalogs(enabled: Set(registry.harnesses))
        rows = tasks.filter { request.filter.admits($0.id) }
            .map { route($0, router: deps.router, kinds: kinds, catalogs: catalogs) }
        // Spec §3: a local pool (every slot has no account) defaults to its own slot count.
        for pool in pools where poolCaps[pool] == nil {
            let slots = deps.capacity.headroom(pool: PoolID(pool))
            if !slots.isEmpty, slots.allSatisfy({ $0.account.id == nil }) { poolCaps[pool] = slots.count }
        }
    }

    private func route(_ task: ReadyTask, router: any Router, kinds: [TaskKind], catalogs: AdapterCatalogs) -> Row {
        var row = Row(id: task.id, title: task.title, block: nil, chip: nil, unroutable: nil,
                      existingContext: task.agentContext, changed: false)
        switch task.block {
        case .failure(let failure):
            row.unroutable = failure.message
        case .success(nil):
            row.unroutable = "no execution block"
        case .success(let block?):
            if block.pinned {
                row.block = block; row.chip = .pinned
            } else if let kind = KindResolution.resolve(block.kind, in: kinds) {
                let routed = router.assign(kind: kind, project: projectURL, catalogs: catalogs, now: now()).block
                row.block = routed
                row.chip = SourceChip(routed.source.by)
                row.changed = routed != block
            } else {
                row.unroutable = "unknown kind \(block.kind)"
            }
            if let routed = row.block, registry.capabilities(for: routed.harness) == nil {
                row.unroutable = "no adapter named \(routed.harness)"
            }
        }
        return row
    }

    /// Spec §3 "Override": sets `pinned`, writes the block back, keeps the task's kind (a task
    /// with no block yet gets the seed `implement-simple`).
    func override(_ rowID: String, harness: HarnessID, model: String, knobs: [String: String], pool: PoolID) async -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return false }
        let block = ExecutionBlock(kind: rows[index].block?.kind ?? "implement-simple", harness: harness, model: model,
                                   knobs: knobs, pool: pool,
                                   source: AssignmentSource(by: .manual, reason: "set in the launch sheet", at: now()),
                                   pinned: true)
        guard await backend.writeBlock(block, task: rowID, existingContext: rows[index].existingContext, project: projectURL) else {
            error = "Could not save the override for \(rowID)."
            return false
        }
        rows[index].existingContext = try? ExecutionBlockCodec.encode(block, into: rows[index].existingContext)
        rows[index].block = block
        rows[index].chip = .pinned
        rows[index].changed = false
        rows[index].unroutable = registry.capabilities(for: harness) == nil ? "no adapter named \(harness)" : nil
        return true
    }

    func launch() async -> SwarmRecord? {
        for row in rows where row.changed && row.unroutable == nil {
            guard let block = row.block else { continue }
            _ = await backend.writeBlock(block, task: row.id, existingContext: row.existingContext, project: projectURL)
        }
        return service.launch(project: request.project, cap: cap, poolCaps: poolCaps, filter: request.filter)
    }

    /// `effort=high, agent=build` → knobs. Nil on a fragment with no `=`.
    static func parseKnobs(_ text: String) -> [String: String]? {
        var knobs: [String: String] = [:]
        for part in text.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, !pair[0].isEmpty, !pair[1].isEmpty else { return nil }
            knobs[pair[0]] = pair[1]
        }
        return knobs
    }
}

struct LaunchSheet: View {
    @StateObject var model: LaunchSheetModel
    let harnesses: [HarnessID]
    let onClose: () -> Void
    @State private var editing: String?
    @State private var draftHarness: HarnessID = "claude"
    @State private var draftModel = ""
    @State private var draftKnobs = ""
    @State private var draftPool = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run tasks — \(model.request.title)").font(.headline)
            if let error = model.error { Text(error).foregroundStyle(.red) }
            List(model.rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.id) · \(row.title)")
                        Text(row.unroutable.map { "unroutable: \($0)" } ?? "\(row.block?.kind.rawValue ?? "—") · \(row.summary)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let chip = row.chip { Text(chip.rawValue).font(.caption2).padding(.horizontal, 6).background(Capsule().fill(.quaternary)) }
                    Button("Override…") {
                        editing = row.id
                        draftHarness = row.block?.harness ?? "claude"
                        draftModel = row.block?.model ?? ""
                        draftKnobs = row.block.map { $0.knobs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") } ?? ""
                        draftPool = row.block?.pool.rawValue ?? ""
                    }
                    .accessibilityIdentifier("launch-override-\(row.id)")
                }
                .opacity(row.unroutable == nil ? 1 : 0.45)
                .accessibilityIdentifier("launch-row-\(row.id)")
            }
            .frame(minHeight: 220)
            if let id = editing { overrideEditor(id) }
            HStack {
                Stepper("Agents at once: \(model.cap)", value: $model.cap, in: 1...16)
                    .accessibilityIdentifier("launch-cap")
                ForEach(model.pools, id: \.self) { pool in
                    Stepper("\(pool): \(model.poolCaps[pool].map(String.init) ?? "—")",
                            value: Binding(get: { model.poolCaps[pool] ?? model.cap },
                                           set: { model.poolCaps[pool] = $0 }), in: 1...16)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onClose).accessibilityIdentifier("launch-cancel")
                Button("Launch") { Task { if await model.launch() != nil { onClose() } } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canLaunch)
                    .accessibilityIdentifier("launch-swarm")
            }
        }
        .padding(16)
        .frame(minWidth: 620, minHeight: 420)
        .task { await model.load() }
        .accessibilityIdentifier("swarm-launch-sheet")
    }

    private func overrideEditor(_ id: String) -> some View {
        HStack {
            Picker("Agent", selection: $draftHarness) {
                ForEach(harnesses, id: \.self) { Text($0.rawValue).tag($0) }
            }.frame(width: 140)
            TextField("Model", text: $draftModel).frame(width: 140)
            TextField("Knobs, e.g. effort=high", text: $draftKnobs).frame(width: 180)
            TextField("Pool", text: $draftPool).frame(width: 120)
            Button("Save") {
                guard let knobs = LaunchSheetModel.parseKnobs(draftKnobs), !draftModel.isEmpty, !draftPool.isEmpty else { return }
                Task { if await model.override(id, harness: draftHarness, model: draftModel, knobs: knobs, pool: PoolID(draftPool)) { editing = nil } }
            }
            Button("Close") { editing = nil }
        }
        .font(.caption)
    }
}
```

- [ ] **Step 4: Mount it**

In `SessionStore.swift`, beside `observeDAGPresented` (`:354`):

```swift
    /// The launch sheet `RootView` presents. Set from the project header's "Run Ready Tasks…"
    /// and a released intake's "Run Tasks…".
    @Published var swarmLaunchRequest: SwarmLaunchRequest?

    func requestSwarmLaunch(project: String, filter: SwarmFilter, title: String) {
        swarmLaunchRequest = SwarmLaunchRequest(project: project, filter: filter, title: title)
    }
```

In `RootView.swift`, after the `.sheet(isPresented: $store.observeDAGPresented …) { … }` modifier:

```swift
        .sheet(item: $store.swarmLaunchRequest) { request in
            LaunchSheet(model: LaunchSheetModel(request: request, backend: store.swarmService.backend,
                                                service: store.swarmService, registry: store.routingCapabilities),
                        harnesses: store.routingCapabilities.harnesses,
                        onClose: { store.swarmLaunchRequest = nil })
        }
```

In `ProjectHeaderRow.swift`'s `.contextMenu`, directly after `Button("Flight Control coordination enabled") {}.disabled(true)` inside the `if isFlywheelEnabled {` branch:

```swift
                Button("Run Ready Tasks…") {
                    store.requestSwarmLaunch(project: repo.url.standardizedFileURL.path, filter: .allReady,
                                             title: repo.displayName)
                }
```

In `IntakeDetailView.swift`, add a stored property after `onOpenReview`:

```swift
    /// Opens the launch sheet for the tasks this intake released (L3-S). Nil hides the button.
    var onRunTasks: (([String]) -> Void)? = nil
```

and in `releasedBody`, after the `if let record = intake.release { … }` block's closing brace,
inside the `VStack`:

```swift
            if let record = intake.release, let onRunTasks, !record.idMap.isEmpty {
                Button("Run Tasks…") { onRunTasks(record.idMap.values.sorted()) }
                    .accessibilityIdentifier("intake-run-tasks")
            }
```

In `ProjectView.swift`, change the `IntakeDetailView(...)` call (`:181`) to pass:

```swift
                    IntakeDetailView(service: intakeService, intake: intake, onOpenReview: { reviewIntakeID = id },
                                     onRunTasks: { tasks in
                                         store.requestSwarmLaunch(project: repo.url.standardizedFileURL.path,
                                                                  filter: .intake(id: intake.id, tasks: tasks),
                                                                  title: repo.displayName)
                                     },
                                     showsInspector: inspectorBinding)
```

(The memberwise initializer takes the parameters in declaration order; `onRunTasks` is declared
after `onOpenReview` and before `showsInspector`, so this argument order compiles. If
`IntakeDetailView` has an explicit `init`, add `onRunTasks: (([String]) -> Void)? = nil` to it in
the same position and assign it.)

- [ ] **Step 5: Run the model tests and the terminology guard**

Run: `FD_TEST_FILTER=LaunchSheetModelTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. Then `./scripts/build.sh 2>&1 | tail -5` → `** BUILD SUCCEEDED **` (the views compile).

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/LaunchSheet.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/RootView.swift Sources/FlightDeck/ProjectHeaderRow.swift Sources/FlightDeck/Intake/IntakeDetailView.swift Sources/FlightDeck/ProjectView.swift Tests/FlightDeckTests/FlightControlL3/Swarm/LaunchSheetModelTests.swift
git commit -m "feat: launch a swarm from a released intake or the project menu" -m "The launch sheet lists the admitted ready tasks with kind, harness/model/knobs, pool and where the routing came from; unpinned blocks are re-routed through L3-R before it opens and written back on Launch, pinned blocks are untouched, unroutable ones are greyed with the reason. Override pins a block and writes it to br. Caps are set overall and per pool; a local pool defaults to its own slot count." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: `session.new` replies with the new session's id (atomic)

**Files:**
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (`handleCommand`, new `createSession(_:cid:)`, `apply`'s `.newSession` arm)
- Modify: `Sources/FleetKit/FleetConnector.swift` (`.session` resolves a pending ack)
- Modify: `Sources/FlightDeckCLI/CLIRunner.swift` (`launch`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SessionNewReplyTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/CLINewSessionIDTests.swift`

**Interfaces:**
- Consumes: `ServerFrame.session(cid:UUID)` (`Frames.swift`, existing — deviation 1).
- Produces: `session.new` answers `.session(cid:, <new id>)` after the tab exists, or `.err(cid:, "unknown_project" | "terminal_unavailable" | "launch_failed")`; `flightdeck new` prints that id.

No enum case is added, so there is no exhaustive switch to update; the Mac handler, the
connector and the CLI still land in this one commit so no build ever answers `.session` to a
client that cannot read it.

- [ ] **Step 1: Write the failing loopback tests**

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Spec §5: `session.new` used to ack before creating and never named the tab. It now answers
/// after creation with the tab's id, which is what lets the CLI and the phone address what they
/// started. Driven over the real local socket.
@MainActor
final class SessionNewReplyTests: XCTestCase {
    private var harness: FleetTestHarness!
    private var client: FleetClient?
    private var path = ""

    override func setUp() async throws {
        harness = FleetTestHarness()
        path = "/tmp/fdsn-\(UUID().uuidString.prefix(8)).sock"
        try await harness.service.startLocal(at: URL(fileURLWithPath: path))
    }
    override func tearDown() async throws {
        client?.disconnect(); harness.service.stop(); harness = nil
    }

    private func send(_ command: FleetCommand) async -> ServerFrame? {
        let client = FleetClient(localCaller: nil); self.client = client
        let ready = expectation(description: "snapshot")
        let replied = expectation(description: "reply")
        var cid = 0
        var reply: ServerFrame?
        client.onFrame = { frame in
            if case .snapshot = frame { ready.fulfill() }
            if frame.correlationID == cid, cid != 0 { reply = frame; replied.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [ready], timeout: 5)
        cid = client.send(command)
        await fulfillment(of: [replied], timeout: 5)
        return reply
    }

    func testSessionNewAnswersWithTheNewTabsID() async throws {
        let existing = harness.store.newSession(in: URL(fileURLWithPath: "/w/alpha", isDirectory: true))
        let project = try XCTUnwrap(harness.store.repos.first { $0.sessions.contains { $0.id == existing.id } }?.id)
        guard case .session(_, let id)? = await send(.newSession(project: project)) else {
            return XCTFail("expected a .session reply")
        }
        XCTAssertNotEqual(id, existing.id)
        XCTAssertTrue(harness.store.sessionExists(id))
    }

    func testAnUnknownProjectIsStillRefused() async {
        guard case .err(_, "unknown_project")? = await send(.newSession(project: UUID())) else {
            return XCTFail("expected unknown_project")
        }
    }
}
```

- [ ] **Step 2: Write the failing CLI test**

```swift
import FleetKit
import XCTest

/// `flightdeck new` prints the id the Mac names, not the first tab that happens to appear in the
/// project — which, with a swarm spawning in the same project, is often somebody else's.
@MainActor
final class CLINewSessionIDTests: XCTestCase {
    func testNewPrintsTheIDTheMacReturns() async throws {
        let server = FleetSocketServer()
        let path = "/tmp/fdnew-\(UUID().uuidString.prefix(8)).sock"
        let project = UUID(), created = UUID(), decoy = UUID()
        let fleet = FleetSnapshot(projects: [WireProject(id: project, name: "a", path: "/w/a", sessions: [])])
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onCommand = { _, cid, _, reply in
            // A swarm's tab lands in the same project first; the CLI must not print it.
            server.broadcast(.event(seq: 2, .sessionAdded(WireSession(id: decoy, title: "swarm", agent: "claude"), project: project, at: 0)))
            reply(.session(cid: cid, created))
        }
        try await server.startLocal(path: path)
        defer { server.stop(); unlink(path) }

        let transport = LocalFleetTransport(path: path, caller: nil)
        let finished = expectation(description: "runner finished")
        var printed: [String] = []
        var code: Int32?
        let runner = CLIRunner(
            invocation: try CLIArguments.parse(["new", "a"]),
            transport: transport,
            // A terminal, so `new` prints the bare id (a pipe would get JSON).
            context: CLIContext(selfID: nil, cwd: "/w/a", json: false, isTTY: true),
            out: { printed.append($0) }, err: { _ in },
            finish: { code = $0; finished.fulfill() },
            schedule: { delay, action in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action) })
        runner.run()
        await fulfillment(of: [finished], timeout: 5)
        transport.disconnect()
        XCTAssertEqual(code, 0)
        XCTAssertEqual(printed, [created.uuidString])
    }
}
```

(`FleetSocketServer.broadcast(_:requiring:)` takes a `ServerFrame` — `FleetSocketServer.swift:638` —
and `CLIContext.selfID` is optional — `CLIRunner.swift:8`; both checked while planning.)

- [ ] **Step 3: Run to verify they fail**

Run: `FD_TEST_FILTER=SessionNewReplyTests,CLINewSessionIDTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `testSessionNewAnswersWithTheNewTabsID` fails (`expected a .session reply` — today it is
`.ack`), and `testNewPrintsTheIDTheMacReturns` fails (it prints the decoy, or times out).

- [ ] **Step 4: Answer after creation in `FleetService`**

In `handleCommand`, replace the whole `if case .newSession(let project, _, _) = command, … { Task { … }; return }`
block with:

```swift
        // `session.new` answers AFTER the tab exists, with its id (spec §5), so the CLI and the
        // phone can address what they started. The one command whose reply waits.
        if case .newSession = command {
            Task { @MainActor in reply(await self.createSession(command, cid: cid)) }
            return
        }
```

Replace `apply`'s entire `case .newSession(let project, let agent, let accountIndex):` arm with:

```swift
        case .newSession:
            // Routed to `createSession(_:cid:)` by `handleCommand` before `apply` is ever reached.
            assertionFailure("session.new is answered by createSession(_:cid:)")
            return .err(cid: cid, code: "unhandled")
```

Add the method next to `apply`:

```swift
    /// The old `apply` arm, now awaited to the end so the reply can name the tab. The checks and
    /// their order are unchanged: project first (a stale phone gets `unknown_project` without the
    /// Mac waking its display), then the display, then the menu row re-resolved against today's
    /// menu, falling back to the project's defaults rather than an account nobody chose.
    private func createSession(_ command: FleetCommand, cid: Int) async -> ServerFrame {
        guard case .newSession(let project, let agent, let accountIndex) = command else {
            return .err(cid: cid, code: "unhandled")
        }
        guard let path = store.projectPath(project) else { return .err(cid: cid, code: "unknown_project") }
        if !store.canCreateTerminal, !(await store.awaitTerminalCreatable()) {
            return .err(cid: cid, code: "terminal_unavailable")
        }
        guard store.ensureTerminalCreatable() else { return .err(cid: cid, code: "terminal_unavailable") }

        if let agent, let accountIndex, let picked = AgentID(rawValue: agent),
           let account = NewSessionOptionsProjection.account(forAgent: agent, index: accountIndex,
                                                             in: menuEntries(forProjectAt: path)) {
            // `selecting: false`: a client's `+` must not move the desk's selection.
            switch await store.createSession(agent: picked, in: path, account: account, selecting: false) {
            case .success(let id) where store.sessionExists(id):
                return .session(cid: cid, id)
            case .success:
                return .err(cid: cid, code: "launch_failed")
            case .failure(let error):
                Self.logger.error("new session from a client failed to launch: \(String(describing: error), privacy: .public)")
                return .err(cid: cid, code: "launch_failed")
            }
        }
        // A plain `+`, or a menu row that no longer matches: the project's defaults.
        guard let session = store.newSession(inProject: project) else { return .err(cid: cid, code: "unknown_project") }
        // `newSession` returns an unfiled draft when it refuses a launch; that is not a tab.
        guard store.sessionExists(session.id) else { return .err(cid: cid, code: "launch_failed") }
        return .session(cid: cid, session.id)
    }
```

(`NewSessionOptionsProjection.account(forAgent:index:in:)` returns `UUID?` —
`Fleet/NewSessionOptionsProjection.swift:60` — so the `if let` binds it.)

- [ ] **Step 5: Let the connector hear `.session` as an ack**

In `Sources/FleetKit/FleetConnector.swift`, change the `.session` case of the frame switch to:

```swift
        case .session(let cid, let sessionID):
            // `session.new` now answers with the tab it made; a caller that filed it with
            // `send(_:then:)` hears that as its ack. Unsequenced, like every reply here.
            if resolveAck(cid, with: .success(())) { return }
            resolveSession(cid, with: .success(sessionID))
            return
```

- [ ] **Step 6: Print the returned id in the CLI**

Replace `launch(_:agent:account:)` in `Sources/FlightDeckCLI/CLIRunner.swift` with:

```swift
    private func launch(_ projectID: UUID, agent: String?, account: Int?) {
        // The Mac names the tab it made (`.session`, spec §5). Its row arrives as `sessionAdded`,
        // possibly before the reply; only `--json` needs the row. An older Mac acks before it
        // creates and names nothing: then the first tab in this project is the best answer left,
        // which is what this command always printed.
        var created: UUID?
        var legacyAcked = false
        var firstAdded: WireSession?
        var added: [UUID: WireSession] = [:]
        let settle = {
            guard let id = created ?? (legacyAcked ? firstAdded?.id : nil) else { return }
            if !self.wantsJSON {
                self.out(id.uuidString)
                return self.finish(0)
            }
            guard let session = added[id] ?? self.session(id) else { return }
            self.out(CLIOutput.json(session))
            self.finish(0)
        }
        onEvent = { event in
            guard case .sessionAdded(let session, projectID, _) = event else { return }
            added[session.id] = session
            if firstAdded == nil { firstAdded = session }
            settle()
        }
        let cid = transport.send(.newSession(project: projectID, agent: agent, accountIndex: account))
        replies[cid] = { frame in
            switch frame {
            case .err(_, let code): self.fail(code)
            case .session(_, let id): created = id; settle()
            default: legacyAcked = true; settle()
            }
        }
        schedule(Self.launchTimeout) { self.fail("launch_unconfirmed") }
    }
```

- [ ] **Step 7: Run the new tests, the fleet suites and the CLI suites**

Run: `FD_TEST_FILTER=SessionNewReplyTests,CLINewSessionIDTests,FleetLocalControlTests,FleetServiceTests,CLIEndToEndTests,CLIRunnerTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. A `FleetServiceTests` case that asserted `.ack` for `session.new` is the old
behaviour this task changes: update its expected frame to `.session(cid:, <id>)` and say so in
the commit body. (`rg -n "newSession" Tests/FlightDeckTests/FleetServiceTests.swift` finds them.)
Then `./scripts/build-ios.sh 2>&1 | tail -5` → succeeds (FleetConnector compiles for iOS), and
`./scripts/test-ios.sh 2>&1 | tail -15` → `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/Fleet/FleetService.swift Sources/FleetKit/FleetConnector.swift Sources/FlightDeckCLI/CLIRunner.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SessionNewReplyTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/CLINewSessionIDTests.swift Tests/FlightDeckTests/FleetServiceTests.swift
git commit -m "feat: answer session.new with the id of the tab it created" -m "The Mac used to ack session.new before creating the tab and never named it, so the CLI printed the first tab that appeared in the project. It now replies after creation with the existing .session frame, or an error (unknown_project, terminal_unavailable, launch_failed). The phone sends session.new fire-and-forget, so an unsolicited .session is a no-op there; a send(_:then:) caller hears it as its ack. flightdeck new prints the returned id." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 10a: Swarm annotations — the model and the sidebar row chips

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Swarm/SwarmAnnotations.swift`
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmService.swift` (`isContested` seam)
- Modify: `Sources/FlightDeck/SessionSidebar.swift` (`SessionRow` gets `swarm:`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmAnnotationTests.swift`

**Interfaces:**
- Produces:
  - `struct SwarmSessionAnnotation: Equatable { taskChip: String?; contested: Bool; meter: Double?; marker: String?; lastActive: String? }`
  - `struct SwarmHeaderSummary: Equatable { text: String; banner: String?; state: SwarmState; canPause; canResume; chipText }`
  - `enum SwarmAnnotations { static func activeAgo(_:now:) -> String?; static func session(_:headroom:contested:lastActive:now:) -> SwarmSessionAnnotation; static func header(_:contested:) -> SwarmHeaderSummary }`
  - `SwarmService.isContested: (UUID) -> Bool` (default `{ _ in false }`; Task 11d sets it), `SwarmService.agentRecord(_:) -> (SwarmRecord, SwarmAgentRecord)?`, `annotation(for:now:)`, `summary(forProject:)`
  - `struct SwarmRowChips: View`, `struct MinimalMeter: View` (accessibility ids `swarm-task-chip`, `swarm-contested`, `swarm-meter`, `swarm-marker`, `swarm-last-active`)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §6. The sidebar is the roster, so everything a swarm row says is derived here, as
/// values, where it can be tested without a window.
@MainActor
final class SwarmAnnotationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func agent(_ state: SwarmAgentState, task: String? = nil, lastTask: String? = nil,
                       marker: String? = nil) -> SwarmAgentRecord {
        var a = SwarmAgentRecord(session: UUID(), agentName: "BlueLake",
                                 block: SwarmFixtures.block(kind: "snapshot-tests"), lease: nil,
                                 task: task, state: state, stateSince: now)
        a.lastTask = lastTask; a.marker = marker
        return a
    }

    func testTheTaskChipNamesTaskAndKind() {
        let a = SwarmAnnotations.session(agent(.working, task: "fd-3x9"), headroom: nil, contested: false, lastActive: nil, now: now)
        XCTAssertEqual(a.taskChip, "fd-3x9 · snapshot-tests")
        XCTAssertNil(a.marker)
    }

    func testMarkersPerState() {
        func marker(_ a: SwarmAgentRecord) -> String? {
            SwarmAnnotations.session(a, headroom: nil, contested: false, lastActive: nil, now: now).marker
        }
        XCTAssertEqual(marker(agent(.idle)), "waiting")
        XCTAssertEqual(marker(agent(.idle, lastTask: "fd-1")), "done fd-1")
        XCTAssertEqual(marker(agent(.idle, marker: "stuck at start")), "stuck at start")
        XCTAssertEqual(marker(agent(.handedOff)), "handed off →")
        XCTAssertEqual(marker(agent(.done)), "done")
        XCTAssertEqual(marker(agent(.starting)), "starting")
    }

    func testTheMeterShowsOnlyPastSoft() {
        let account = AccountRef(harness: "codex", id: UUID(), label: "Work")
        func meter(_ state: HeadroomState, _ u: Double?) -> Double? {
            SwarmAnnotations.session(agent(.working, task: "t"),
                                     headroom: AccountHeadroom(account: account, worstUtilization: u, state: state, resetsAt: nil),
                                     contested: false, lastActive: nil, now: now).meter
        }
        XCTAssertNil(meter(.underSoft, 0.4))
        XCTAssertEqual(meter(.overSoft, 0.82), 0.82)
        XCTAssertEqual(meter(.overHard, nil), 1)
    }

    func testActiveAgo() {
        XCTAssertNil(SwarmAnnotations.activeAgo(nil, now: now))
        XCTAssertEqual(SwarmAnnotations.activeAgo(now.addingTimeInterval(-20), now: now), "active just now")
        XCTAssertEqual(SwarmAnnotations.activeAgo(now.addingTimeInterval(-240), now: now), "active 4 min ago")
    }

    func testHeaderSummaryText() {
        var record = SwarmRecord(id: UUID(), project: "/p", cap: 3, poolCaps: [:], filter: .allReady, state: .running,
                                 agents: [agent(.working, task: "a"), agent(.working, task: "b"), agent(.starting)],
                                 createdAt: now)
        record.waiting = [WaitingTask(task: "c", reason: "r"), WaitingTask(task: "d", reason: "r")]
        XCTAssertEqual(SwarmAnnotations.header(record, contested: 1).text, "swarm 3/3 · 2 waiting · 1 contested")
        record.state = .paused; record.waiting = []
        let paused = SwarmAnnotations.header(record, contested: 0)
        XCTAssertEqual(paused.text, "swarm paused · 3/3")
        XCTAssertTrue(paused.canResume)
        XCTAssertFalse(paused.canPause)
        record.banner = SwarmStore.restartBanner
        XCTAssertEqual(SwarmAnnotations.header(record, contested: 0).chipText, "Swarm paused after restart · Resume")
    }

    func testTheServiceAnnotatesOnlySwarmSessions() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        rig.host.activity[a.session] = rig.now.addingTimeInterval(-300)
        rig.store.save([rig.record(state: .paused, agents: [a])])
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
        XCTAssertEqual(service.annotation(for: a.session, now: rig.now)?.taskChip, "fx-1 · tests")
        XCTAssertEqual(service.annotation(for: a.session, now: rig.now)?.lastActive, "active 5 min ago")
        XCTAssertNil(service.annotation(for: UUID(), now: rig.now))
        service.isContested = { $0 == a.session }
        XCTAssertEqual(service.annotation(for: a.session, now: rig.now)?.contested, true)
        XCTAssertEqual(service.summary(forProject: SwarmFixtures.project)?.text, "swarm paused · 1/3 · 1 contested")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmAnnotationTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'SwarmAnnotations' in scope`.

- [ ] **Step 3: Add the seam to `SwarmService`**

Inside the class, after `weak var handoffDecisions: HandoffDecisionSink?`:

```swift
    /// Whether a session is contested right now. Set by contested detection (Task 11d); until
    /// then nothing is contested, which is the truth for a swarm with no guard blocks.
    var isContested: (UUID) -> Bool = { _ in false }
```

- [ ] **Step 4: Implement `SwarmAnnotations.swift`**

```swift
import IntakeKit
import SwiftUI

struct SwarmSessionAnnotation: Equatable {
    /// `fd-3x9 · snapshot-tests` (spec §6).
    var taskChip: String?
    var contested: Bool
    /// The account's worst-window utilization, only once it is past soft.
    var meter: Double?
    /// waiting / done <task> / handed off → / a failure note.
    var marker: String?
    var lastActive: String?
}

struct SwarmHeaderSummary: Equatable {
    var text: String
    var banner: String?
    var state: SwarmState
    var canPause: Bool { state == .running || state == .draining }
    var canResume: Bool { state == .paused || state == .draining }
    /// The header chip shows the banner when there is one — it is what needs the human.
    var chipText: String { banner ?? text }
}

/// Pure builders for every swarm annotation. Views below only render their output.
enum SwarmAnnotations {
    static func activeAgo(_ date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes <= 0 ? "active just now" : "active \(minutes) min ago"
    }

    static func session(_ agent: SwarmAgentRecord, headroom: AccountHeadroom?, contested: Bool,
                        lastActive: Date?, now: Date) -> SwarmSessionAnnotation {
        let marker: String?
        switch agent.state {
        case .working: marker = nil
        case .starting: marker = "starting"
        case .idle: marker = agent.marker ?? agent.lastTask.map { "done \($0)" } ?? "waiting"
        case .handedOff: marker = "handed off →"
        case .done: marker = agent.marker == "tab closed" ? nil : "done"
        }
        let meter: Double?
        switch headroom?.state {
        case .overSoft?, .overHard?: meter = headroom?.worstUtilization ?? 1
        default: meter = nil
        }
        return SwarmSessionAnnotation(
            taskChip: agent.task.map { "\($0) · \(agent.block.block.kind)" },
            contested: contested, meter: meter, marker: marker,
            lastActive: activeAgo(lastActive, now: now))
    }

    static func header(_ record: SwarmRecord, contested: Int) -> SwarmHeaderSummary {
        let counts = "\(record.activeCount)/\(record.cap)"
        var parts = [record.state == .running ? "swarm \(counts)" : "swarm \(record.state.rawValue) · \(counts)"]
        if !record.waiting.isEmpty { parts.append("\(record.waiting.count) waiting") }
        if contested > 0 { parts.append("\(contested) contested") }
        return SwarmHeaderSummary(text: parts.joined(separator: " · "), banner: record.banner, state: record.state)
    }
}

extension SwarmService {
    func agentRecord(_ session: UUID) -> (SwarmRecord, SwarmAgentRecord)? {
        for record in allRecords {
            if let agent = record.agent(session) { return (record, agent) }
        }
        return nil
    }

    func headroom(of agent: SwarmAgentRecord) -> AccountHeadroom? {
        guard let lease = agent.lease else { return nil }
        return dependencies?.capacity.headroom(pool: lease.pool).first { $0.account == lease.account }
    }

    func annotation(for session: UUID, now: Date = Date()) -> SwarmSessionAnnotation? {
        guard let (_, agent) = agentRecord(session) else { return nil }
        return SwarmAnnotations.session(agent, headroom: headroom(of: agent), contested: isContested(session),
                                        lastActive: host.lastActiveAt(for: session), now: now)
    }

    func summary(forProject path: String) -> SwarmHeaderSummary? {
        guard let record = record(forProject: path) else { return nil }
        let contested = record.agents.filter { $0.state == .working || $0.state == .idle }
            .filter { isContested($0.session) }.count
        return SwarmAnnotations.header(record, contested: contested)
    }
}

/// The chips after a swarm session's title. Plain text and shapes only: anything that takes a
/// mouse-down here breaks the row's drag and rename (see `SessionRow`'s comments).
struct SwarmRowChips: View {
    let annotation: SwarmSessionAnnotation

    var body: some View {
        HStack(spacing: 4) {
            if let chip = annotation.taskChip {
                Text(chip)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(.quaternary))
                    .accessibilityIdentifier("swarm-task-chip")
            }
            if annotation.contested {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(.orange)
                    .help("Waiting on a file another agent holds")
                    .accessibilityLabel("contested")
                    .accessibilityIdentifier("swarm-contested")
            }
            if let meter = annotation.meter {
                MinimalMeter(value: meter)
                    .frame(width: 22, height: 4)
                    .help("Account at \(Int(meter * 100))%")
                    .accessibilityLabel("account at \(Int(meter * 100)) percent")
                    .accessibilityIdentifier("swarm-meter")
            }
            if let marker = annotation.marker {
                Text(marker).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("swarm-marker")
            }
            if let ago = annotation.lastActive {
                Text(ago).font(.caption2).foregroundStyle(.tertiary)
                    .accessibilityIdentifier("swarm-last-active")
            }
        }
    }
}

/// A placeholder-free minimal meter drawn from `AccountHeadroom`. Integration swaps in L3-U's
/// standalone meter view; this exists so L3-S's own UI and UI tests have something real to show.
struct MinimalMeter: View {
    let value: Double
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(value >= 1 ? Color.red : .orange)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }
    }
}
```

- [ ] **Step 5: Mount the chips on `SessionRow`**

In `Sources/FlightDeck/SessionSidebar.swift`'s `SessionRow`, add after `var hasBackgroundWork: Bool = false`:

```swift
    /// The swarm annotation when this tab is a swarm agent (L3-S), else nil — non-swarm rows
    /// are unchanged.
    var swarm: SwarmSessionAnnotation? = nil
```

and directly after `Text(session.title).accessibilityIdentifier("session-row-title")`:

```swift
                if let swarm {
                    SwarmRowChips(annotation: swarm)
                }
```

In `SessionSidebar.body`'s `SessionRow(...)` call, add the argument after `hasBackgroundWork:`:

```swift
                            hasBackgroundWork: store.backgroundWorkSessions.contains(session.id),
                            swarm: store.swarmServiceIfBuilt?.annotation(for: session.id)
```

- [ ] **Step 6: Run the tests, the guard and a build**

Run: `FD_TEST_FILTER=SwarmAnnotationTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. Then `./scripts/build.sh 2>&1 | tail -3` → `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/SwarmAnnotations.swift Sources/FlightDeck/FlightControl/Swarm/SwarmService.swift Sources/FlightDeck/SessionSidebar.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmAnnotationTests.swift
git commit -m "feat: show a swarm agent's task, state and account on its sidebar row" -m "A swarm session's row gains a task chip (id · kind), a contested badge, a small account meter once the account is past soft, a state marker (waiting, done, handed off →, stuck at start) and 'active N min ago'. All of it is built as values by SwarmAnnotations; the row draws text and shapes only, so its drag and rename hit-testing are untouched." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10b: The project header — summary, controls, popover, restart banner

**Files:**
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmAnnotations.swift` (append `SwarmHeaderChip`, `SwarmPopover`)
- Modify: `Sources/FlightDeck/ProjectHeaderRow.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmHeaderTests.swift`

**Interfaces:**
- Produces: `struct SwarmMeterRow: Hashable { pool; label; value: Double?; state: HeadroomState }`, `SwarmService.meters(forProject:) -> [SwarmMeterRow]`, `struct SwarmHeaderChip: View` (id `swarm-header-chip`), `struct SwarmPopover: View` (ids `swarm-popover`, `swarm-pause`, `swarm-resume`); header context-menu items **Swarm Details…**, **Pause Swarm**, **Resume Swarm**, **Drain Swarm**, **Stop Swarm**; `ProjectHeaderRow.swarmAccessibilityParts(_:) -> [String]` (static, pure)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The header row is one combined accessibility element (`ProjectHeaderRow`), so the swarm's
/// summary and banner reach VoiceOver only through its label. (XCUITest reads that label as ""
/// — `TerminalSmokeTests` notes it — so the UI test reads the popover instead.)
@MainActor
final class SwarmHeaderTests: XCTestCase {
    func testTheSummaryAndBannerJoinTheHeaderLabel() {
        let summary = SwarmHeaderSummary(text: "swarm paused · 1/3", banner: SwarmStore.restartBanner, state: .paused)
        XCTAssertEqual(ProjectHeaderRow.swarmAccessibilityParts(summary),
                       ["swarm paused · 1/3", "Swarm paused after restart · Resume"])
        XCTAssertEqual(ProjectHeaderRow.swarmAccessibilityParts(nil), [])
    }

    func testThePopoverListsWaitingTasksWithReasons() {
        var record = SwarmRecord(id: UUID(), project: "/p", cap: 2, poolCaps: [:], filter: .allReady, state: .running,
                                 agents: [], createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        record.waiting = [WaitingTask(task: "fx-2", reason: "codex-subs is full and nothing else fits")]
        record.unroutable = [WaitingTask(task: "fx-9", reason: "no execution block")]
        XCTAssertEqual(SwarmPopover.lines(for: record),
                       ["fx-2 — codex-subs is full and nothing else fits", "fx-9 — unroutable: no execution block"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmHeaderTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `type 'ProjectHeaderRow' has no member 'swarmAccessibilityParts'`.

- [ ] **Step 3: Append the header views to `SwarmAnnotations.swift`**

```swift
/// The header's swarm summary. Text, not a button: `ProjectHeaderRow` keeps every mouse-down
/// for its drag (see that file). Its popover opens from the header's context menu.
struct SwarmHeaderChip: View {
    let summary: SwarmHeaderSummary
    var body: some View {
        Text(summary.chipText)
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .background(Capsule().fill(summary.banner == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.orange.opacity(0.25))))
            .accessibilityIdentifier("swarm-header-chip")
    }
}

/// Pool meters (from capacity headroom — L3-U's meter view replaces `MinimalMeter` at
/// integration) and the tasks the swarm cannot start, with why.
struct SwarmPopover: View {
    let record: SwarmRecord
    let meters: [SwarmMeterRow]
    let summary: SwarmHeaderSummary
    let onPause: () -> Void
    let onResume: () -> Void

    static func lines(for record: SwarmRecord) -> [String] {
        record.waiting.map { "\($0.task) — \($0.reason)" } + record.unroutable.map { "\($0.task) — unroutable: \($0.reason)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary.text).font(.headline)
            if let banner = summary.banner { Text(banner).foregroundStyle(.orange) }
            ForEach(meters, id: \.self) { meter in
                HStack {
                    Text("\(meter.pool) · \(meter.label)").font(.caption)
                    Spacer()
                    if let value = meter.value {
                        MinimalMeter(value: value).frame(width: 80, height: 5)
                        Text("\(Int(value * 100))%").font(.caption.monospacedDigit())
                    } else {
                        Text("no reading").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            let waiting = Self.lines(for: record)
            if !waiting.isEmpty {
                Text("Waiting").font(.subheadline)
                ForEach(waiting, id: \.self) { Text($0).font(.caption) }
            }
            HStack {
                if summary.canPause { Button("Pause", action: onPause).accessibilityIdentifier("swarm-pause") }
                if summary.canResume { Button("Resume", action: onResume).accessibilityIdentifier("swarm-resume") }
            }
        }
        .padding(12)
        .frame(minWidth: 320)
        .accessibilityIdentifier("swarm-popover")
    }
}

/// One account row of a pool meter: the popover's and the phone's.
struct SwarmMeterRow: Hashable {
    let pool: String
    let label: String
    let value: Double?
    let state: HeadroomState
}

extension SwarmService {
    /// One row per account in every pool the swarm's agents lease from.
    func meters(forProject path: String) -> [SwarmMeterRow] {
        guard let record = record(forProject: path), let capacity = dependencies?.capacity else { return [] }
        let pools = Set(record.agents.compactMap { $0.lease?.pool }).sorted { $0.rawValue < $1.rawValue }
        return pools.flatMap { pool in
            capacity.headroom(pool: pool).map {
                SwarmMeterRow(pool: pool.rawValue, label: $0.account.label, value: $0.worstUtilization, state: $0.state)
            }
        }
    }
}
```

- [ ] **Step 4: Mount it in `ProjectHeaderRow`**

1. Add state after `@State private var probedFlywheelStatus: FlywheelStatus?`:

```swift
    @State private var showingSwarmPopover = false
```

2. Add helpers next to `intakeAttentionCount`:

```swift
    private var swarmSummary: SwarmHeaderSummary? {
        store.swarmServiceIfBuilt?.summary(forProject: repo.url.standardizedFileURL.path)
    }

    /// The summary and banner as VoiceOver words — the only route, since this row is one
    /// combined accessibility element.
    static func swarmAccessibilityParts(_ summary: SwarmHeaderSummary?) -> [String] {
        guard let summary else { return [] }
        return [summary.text] + (summary.banner.map { [$0] } ?? [])
    }
```

3. In `body`, directly after `Spacer(minLength: 4)`:

```swift
            if let summary = swarmSummary {
                SwarmHeaderChip(summary: summary)
            }
```

4. In `.contextMenu`, inside `if isFlywheelEnabled {`, after the "Run Ready Tasks…" button (Task 8):

```swift
                if let summary = swarmSummary {
                    Button("Swarm Details…") { showingSwarmPopover = true }
                    if summary.canPause {
                        Button("Pause Swarm") { store.swarmService.pause(project: repo.url.standardizedFileURL.path) }
                    }
                    if summary.canResume {
                        Button("Resume Swarm") { store.swarmService.resume(project: repo.url.standardizedFileURL.path) }
                    }
                    if summary.state == .running || summary.state == .paused {
                        Button("Drain Swarm") { store.swarmService.drain(project: repo.url.standardizedFileURL.path) }
                    }
                    if summary.state != .stopped {
                        Button("Stop Swarm") { store.swarmService.stop(project: repo.url.standardizedFileURL.path) }
                    }
                }
```

5. After `.flywheelEnableConfirmations(...)`:

```swift
        .popover(isPresented: $showingSwarmPopover, arrowEdge: .trailing) {
            if let service = store.swarmServiceIfBuilt,
               let record = service.record(forProject: repo.url.standardizedFileURL.path),
               let summary = swarmSummary {
                SwarmPopover(record: record, meters: service.meters(forProject: record.project), summary: summary,
                             onPause: { service.pause(project: record.project) },
                             onResume: { service.resume(project: record.project) })
            }
        }
```

6. In `accessibilityLabel`, before `return parts.joined(separator: ", ")`:

```swift
        parts.append(contentsOf: Self.swarmAccessibilityParts(swarmSummary))
```

- [ ] **Step 5: Run the tests, the guard, a build**

Run: `FD_TEST_FILTER=SwarmHeaderTests,TerminologyGuardTests,SidebarSelectionTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. `./scripts/build.sh 2>&1 | tail -3` → `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/SwarmAnnotations.swift Sources/FlightDeck/ProjectHeaderRow.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmHeaderTests.swift
git commit -m "feat: show the swarm summary and its controls on the project header" -m "The header shows 'swarm 3/3 · 2 waiting · 1 contested', or the restart/failure banner when there is one. Pause, Resume, Drain, Stop and a details popover (pool meters, waiting and unroutable tasks with reasons) live in the header's context menu, because a control inside the row would take the mouse-down its drag needs. The summary and banner join the row's combined accessibility label." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10c: The Observe drawer's Assignment lane

**Files:**
- Modify: `Sources/FlightDeck/Flywheel/Observe/ObserveDrawer.swift`
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmAnnotations.swift` (append `SwarmAssignmentDetail`, builder, service accessor)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`focusedSwarmAssignment()`), `Sources/FlightDeck/RootView.swift` (pass it)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/ObserveAssignmentLaneTests.swift`

**Interfaces:**
- Produces:
  - `ObserveLane.assignment` (first case), `struct ObserveLaneLink: Equatable, Sendable { title: String; session: UUID }`, `ObserveLaneRow.links: [ObserveLaneLink]` (defaulted)
  - `ObserveLaneModel.lanes(for:assignment:unavailable:)` (assignment defaulted nil — existing calls unchanged)
  - `struct SwarmAssignmentDetail: Equatable { lines: [String]; links: [ObserveLaneLink] }`
  - `SwarmAnnotations.assignment(agent:headroom:previous:next:lastActive:now:) -> SwarmAssignmentDetail`
  - `SwarmService.assignment(for:now:) -> SwarmAssignmentDetail?`, `SessionStore.focusedSwarmAssignment() -> SwarmAssignmentDetail?`
  - `ObserveDrawer(…, assignment:onJumpToSession:)` (both defaulted)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §6: a new Assignment lane, first, with the task, kind, harness/model/knobs, the routing
/// source and reason, the account, and the hand-off history with links to the other tabs.
@MainActor
final class ObserveAssignmentLaneTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let agent = FlywheelProjection.Agent(name: "BlueLake", bead: nil, status: .active, holds: [], waitsOn: [],
                                                 lastEventAt: nil, stalledSince: nil)

    func testWithoutAnAssignmentTheLanesAreUnchanged() {
        XCTAssertEqual(ObserveLaneModel.lanes(for: agent, unavailable: []).map(\.lane),
                       [.workingOn, .files, .dependency, .activity])
    }

    func testTheAssignmentLaneComesFirstWithItsLinks() {
        let prev = UUID()
        let detail = SwarmAssignmentDetail(lines: ["task fx-1"], links: [ObserveLaneLink(title: "← GreenFox", session: prev)])
        let rows = ObserveLaneModel.lanes(for: agent, assignment: detail, unavailable: [])
        XCTAssertEqual(rows.map(\.lane), [.assignment, .workingOn, .files, .dependency, .activity])
        XCTAssertEqual(rows[0].title, "Assignment")
        XCTAssertEqual(rows[0].detail, "task fx-1")
        XCTAssertEqual(rows[0].links, [ObserveLaneLink(title: "← GreenFox", session: prev)])
    }

    func testTheDetailLines() {
        var block = SwarmFixtures.block(kind: "snapshot-tests")
        block.knobs = ["effort": "high"]
        block.source = AssignmentSource(by: .rule, ruleId: "r3", reason: "test-authoring 0.8 → codex", at: now)
        let lease = AccountLease(pool: "codex-subs", account: AccountRef(harness: "codex", id: UUID(), label: "Work"))
        var me = SwarmAgentRecord(session: UUID(), agentName: "BlueLake", block: block, lease: lease, task: "fx-1",
                                  state: .working, stateSince: now)
        let previous = SwarmAgentRecord(session: UUID(), agentName: "GreenFox", block: block, lease: nil, task: nil,
                                        state: .handedOff, stateSince: now)
        me.handedOffFrom = previous.session
        let detail = SwarmAnnotations.assignment(
            agent: me, headroom: AccountHeadroom(account: lease.account, worstUtilization: 0.62, state: .underSoft, resetsAt: nil),
            previous: previous, next: nil, lastActive: now.addingTimeInterval(-240), now: now)
        XCTAssertEqual(detail.lines, [
            "task fx-1 · kind snapshot-tests",
            "codex · gpt-6-sol · effort=high · pool codex-subs",
            "routed by rule r3 — test-authoring 0.8 → codex",
            "account Work · 62%",
            "handed off from GreenFox",
            "active 4 min ago",
        ])
        XCTAssertEqual(detail.links, [ObserveLaneLink(title: "← GreenFox", session: previous.session)])
    }

    func testAPinnedBlockSaysSo() {
        let block = SwarmFixtures.block(pinned: true)
        let me = SwarmAgentRecord(session: UUID(), agentName: "A", block: block, lease: nil, task: nil, state: .idle, stateSince: now)
        let lines = SwarmAnnotations.assignment(agent: me, headroom: nil, previous: nil, next: nil, lastActive: nil, now: now).lines
        XCTAssertTrue(lines.contains("pinned by hand — fixture"))
        XCTAssertTrue(lines.contains("no account lease"))
        XCTAssertEqual(lines.first, "no task · kind tests")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=ObserveAssignmentLaneTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `type 'ObserveLane' has no member 'assignment'`.

- [ ] **Step 3: Extend the drawer model**

In `ObserveDrawer.swift`:

```swift
/// The fixed rows of the per-tab Observe drawer, in display order. `assignment` (L3-S) is
/// first and appears only for a swarm agent.
enum ObserveLane: Equatable, Sendable {
    case assignment, workingOn, files, dependency, activity
}

/// A jump to another tab — the assignment lane's previous/next hand-off agents.
struct ObserveLaneLink: Equatable, Sendable {
    let title: String
    let session: UUID
}
```

Add to `ObserveLaneRow` a fourth stored property, defaulted so every existing construction compiles:

```swift
    var links: [ObserveLaneLink] = []
```

In `unavailableKeys(for:)` add `case .assignment: return []`.

Replace `lanes(for:unavailable:)`'s signature and opening with:

```swift
    static func lanes(for agent: FlywheelProjection.Agent?, assignment: SwarmAssignmentDetail? = nil,
                      unavailable: Set<String>) -> [ObserveLaneRow] {
        guard let agent else { return [] }
        let head = assignment.map {
            [ObserveLaneRow(lane: .assignment, title: "Assignment", detail: $0.lines.joined(separator: "\n"),
                            isUnavailable: false, links: $0.links)]
        } ?? []
        return head + [
```

(the existing four `row(...)` entries follow unchanged, and the closing `]` stays).

In `ObserveDrawer` (the view), add after `let onOpenDAG: () -> Void`:

```swift
    var assignment: SwarmAssignmentDetail? = nil
    var onJumpToSession: (UUID) -> Void = { _ in }
```

change the `ForEach` to `ForEach(ObserveLaneModel.lanes(for: agent, assignment: assignment, unavailable: []), id: \.lane)`,
and in `laneRow(_:)` add a branch before the `.dependency` one:

```swift
            if row.lane == .assignment {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.detail).font(.caption).textSelection(.enabled)
                    HStack {
                        ForEach(row.links, id: \.session) { link in
                            Button(link.title) { onJumpToSession(link.session) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
                .accessibilityIdentifier("observe-lane-assignment")
            } else if row.lane == .dependency {
```

(keeping the existing `.dependency` and `else` branches after it).

- [ ] **Step 4: Append the builder to `SwarmAnnotations.swift`**

```swift
struct SwarmAssignmentDetail: Equatable {
    var lines: [String]
    var links: [ObserveLaneLink]
}

extension SwarmAnnotations {
    static func assignment(agent: SwarmAgentRecord, headroom: AccountHeadroom?, previous: SwarmAgentRecord?,
                           next: SwarmAgentRecord?, lastActive: Date?, now: Date) -> SwarmAssignmentDetail {
        let block = agent.block.block
        var lines = ["\(agent.task.map { "task \($0)" } ?? "no task") · kind \(block.kind)"]
        let knobs = block.knobs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        lines.append([block.harness.rawValue, block.model, knobs.isEmpty ? nil : knobs, "pool \(block.pool)"]
            .compactMap { $0 }.joined(separator: " · "))
        if block.pinned {
            lines.append("pinned by hand — \(block.source.reason)")
        } else {
            let rule = block.source.ruleId.map { " \($0)" } ?? ""
            lines.append("routed by \(block.source.by.rawValue)\(rule) — \(block.source.reason)")
        }
        if let lease = agent.lease?.lease {
            let percent = headroom?.worstUtilization.map { " · \(Int(($0 * 100).rounded()))%" } ?? ""
            lines.append("account \(lease.account.label)\(percent)")
        } else {
            lines.append("no account lease")
        }
        var links: [ObserveLaneLink] = []
        if let previous {
            lines.append("handed off from \(previous.agentName)")
            links.append(ObserveLaneLink(title: "← \(previous.agentName)", session: previous.session))
        }
        if let next {
            lines.append("handed off to \(next.agentName)")
            links.append(ObserveLaneLink(title: "\(next.agentName) →", session: next.session))
        }
        if let ago = activeAgo(lastActive, now: now) { lines.append(ago) }
        return SwarmAssignmentDetail(lines: lines, links: links)
    }
}

extension SwarmService {
    func assignment(for session: UUID, now: Date = Date()) -> SwarmAssignmentDetail? {
        guard let (record, agent) = agentRecord(session) else { return nil }
        return SwarmAnnotations.assignment(
            agent: agent, headroom: headroom(of: agent),
            previous: agent.handedOffFrom.flatMap { record.agent($0) },
            next: agent.handedOffTo.flatMap { record.agent($0) },
            lastActive: host.lastActiveAt(for: session), now: now)
    }
}
```

- [ ] **Step 5: Mount it**

In `SessionStore.swift`, next to `focusedObserveAgent()`:

```swift
    /// The drawer's Assignment lane for the focused tab, when it is a swarm agent.
    func focusedSwarmAssignment() -> SwarmAssignmentDetail? {
        guard let id = selectedSessionID else { return nil }
        return swarmServiceIfBuilt?.assignment(for: id)
    }
```

In `RootView.swift`, change the `ObserveDrawer(...)` call to:

```swift
                        ObserveDrawer(agent: agent,
                                      collapsed: store.observeDrawerCollapsed,
                                      onToggleCollapse: { store.toggleObserveDrawer() },
                                      onJumpToRootCause: { store.jumpToObserveRootCause() },
                                      onOpenDAG: { store.presentObserveDAG() },
                                      assignment: store.focusedSwarmAssignment(),
                                      onJumpToSession: { store.selectedSessionID = $0 })
```

- [ ] **Step 6: Run the tests**

Run: `FD_TEST_FILTER=ObserveAssignmentLaneTests,ObserveDrawerModelTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. `./scripts/build.sh 2>&1 | tail -3` → `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Flywheel/Observe/ObserveDrawer.swift Sources/FlightDeck/FlightControl/Swarm/SwarmAnnotations.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/RootView.swift Tests/FlightDeckTests/FlightControlL3/Swarm/ObserveAssignmentLaneTests.swift
git commit -m "feat: add an Assignment lane to the Observe drawer for swarm agents" -m "The lane comes first and names the task and kind, harness/model/knobs and pool, how the block was routed (or that it was pinned), the account and its utilization, the hand-off history with links to the previous and next tab, and when the agent was last active. Non-swarm tabs see the drawer exactly as before." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 11a: Capture a real reservation row and implement the reservations read

**Files:**
- Create (captured): `Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm/am-reservations-held.json`, `guard-block.txt`, `probe-names.json`
- Modify: `Sources/FlightDeck/Flywheel/Observe/FlywheelReadCommands.swift` (`reservations`, `ReservationRows`, `AgentMailTime`)
- Modify: `Tests/FlightDeckTests/Flywheel/Observe/FlywheelReadCommandsTests.swift` (the nil-stub test)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/ReservationsReadTests.swift`

**Interfaces:**
- Consumes: `FlywheelReadCommands.RawReservation` (`FlywheelReadCommands.swift:27`).
- Produces: `FlywheelReadCommands.reservations(project:) async -> [RawReservation]?` (real; `waiters` always `[]` from `am` — Task 11e fills them),
  `enum ReservationRows { static func decode(_:) -> [RawReservation]? }`, `enum AgentMailTime { static func parse(_:) -> Date? }`

- [ ] **Step 1: Capture the positive-path shapes** (scratch repo under `$HOME`; nothing in this checkout)

```bash
P=~/.fd-l3s-probe-am && rm -rf "$P" && mkdir -p "$P" && cd "$P" && git init -q && br init --prefix probe >/dev/null
am projects discovery-init "$P"; echo "discovery exit $?"
am guard install "$P" "$P"; echo "guard exit $?"
am file_reservations reserve --help | head -20
am macros start-session --project "$P" --program claude-code --model probe -n GreenFox --json > green.json; echo "green exit $?"
am macros start-session --project "$P" --program codex-cli --model probe -n BlueLake --json > blue.json; echo "blue exit $?"
GREEN=$(python3 -c 'import json;print(json.load(open("green.json"))["agent"]["name"])')
BLUE=$(python3 -c 'import json;print(json.load(open("blue.json"))["agent"]["name"])')
echo "names: $GREEN $BLUE"
am file_reservations reserve "$P" "$GREEN" 'Sources/*.swift' --exclusive; echo "reserve green exit $?"
am file_reservations reserve "$P" "$BLUE" 'Sources/Foo.swift' --exclusive > blue-reserve.txt 2>&1; echo "reserve blue exit $?"
am reservations --project "$P" --all --json > am-reservations-held.json; echo "reservations exit $?"
python3 -c 'import json;d=json.load(open("am-reservations-held.json"));print(json.dumps(d["all_active"][:2],indent=1))'
mkdir -p Sources && echo "x" > Sources/Foo.swift && git add Sources/Foo.swift
AGENT_NAME="$BLUE" AGENT_MAIL_AGENT="$BLUE" AGENT_MAIL_PROJECT="$P" git commit -qm probe > guard-block.txt 2>&1; echo "commit exit $?"
cat guard-block.txt
printf '{"green":"%s","blue":"%s","pattern":"Sources/*.swift","file":"Sources/Foo.swift"}\n' "$GREEN" "$BLUE" > probe-names.json
F="$OLDPWD/Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm"
cp am-reservations-held.json guard-block.txt probe-names.json "$F/"
am file_reservations release "$P" "$GREEN"; am file_reservations release "$P" "$BLUE"
cd "$OLDPWD" && rm -rf "$P"
```

Apply exactly one, per outcome:
- **`-n GreenFox` is refused** (am assigns its own adjective-noun names): drop `-n …` from both
  `start-session` lines and rerun; `probe-names.json` records whatever names were assigned, and
  every test below reads names from it, never literals.
- **`all_active` has a row for the green agent** (expected): continue. Read the printed row and
  note its keys; Step 3's decoder reads the path from the first of
  `path_pattern|path|pattern|file`, the holder from `agent_name|agent|holder|holder_name` (or
  `agent.name` when `agent` is an object), and the time from `created_ts|created_at|acquired_ts|since`.
  **If the row uses a key not in those lists, add it to the matching list in Step 3** and note it
  in Task 15.
- **`all_active` is still empty after `reserve green exit 0`**: the local read cannot see live
  reservations (the "unattested" path). Leave `reservations` returning nil (unchanged), skip
  Steps 2–5, record "reservations lane still unconfirmed: all_active empty after a successful
  reserve" in `docs/FOLLOWUPS.md` in Task 15, and continue to Task 11b: contested detection still
  works from guard blocks, whose message names the holder (Task 11c).
- **The commit was not blocked** (`commit exit 0`): the guard did not enforce (see the spike's
  fail-open note). Rerun after `am guard status "$P"`; if it still passes, keep `guard-block.txt`
  empty, and in Task 11c use the spike's recorded message instead:
  `mcp-agent-mail: file reservation conflict detected! widget.py conflicts with reservation 'widget.py' held by BlueFalcon`
  (`docs/FLYWHEEL-SPIKE-FINDINGS.md:66-67`).

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
@testable import FlightDeck

/// The reservations lane was a nil stub because no positive-path row had ever been seen
/// (observe-command-shapes notes). It is decoded now against the row captured in Task 11a, and
/// still degrades to nil — never a guess — on anything it cannot read.
final class ReservationsReadTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String = "json") throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: ext, subdirectory: "Fixtures/FlightControlL3/Swarm")))
    }
    private struct Names: Decodable { let green: String; let blue: String; let pattern: String; let file: String }

    func testTheCapturedHeldReservationDecodes() throws {
        let names = try JSONDecoder().decode(Names.self, from: fixture("probe-names"))
        let rows = try XCTUnwrap(ReservationRows.decode(fixture("am-reservations-held")))
        let held = try XCTUnwrap(rows.first { $0.holder == names.green })
        XCTAssertEqual(held.file, names.pattern)
        XCTAssertNotEqual(held.since, .distantPast, "the row's timestamp must parse")
        XCTAssertEqual(held.waiters, [], "am names holders, never waiters")
    }

    func testAnEmptyAllActiveIsEmptyNotNil() {
        XCTAssertEqual(ReservationRows.decode(Data(#"{"all_active":[]}"#.utf8)), [])
    }

    func testUnreadableIsNil() {
        XCTAssertNil(ReservationRows.decode(Data("nope".utf8)))
        XCTAssertNil(ReservationRows.decode(Data(#"{"other":[]}"#.utf8)))
    }

    func testTheReadRunsTheProvenArgv() async throws {
        let fake = MultiRunner()
        fake.responses["am reservations --project"] = (String(decoding: try fixture("am-reservations-held"), as: UTF8.self), 0)
        let rows = await FlywheelReadCommands(runner: fake).reservations(project: "/tmp/p")
        XCTAssertNotNil(rows)
        XCTAssertEqual(fake.argv.last, ["am", "reservations", "--project", "/tmp/p", "--all", "--json"])
    }

    func testAgentMailTimes() {
        XCTAssertNotNil(AgentMailTime.parse("2026-09-22T16:57:34.483761Z"))
        XCTAssertNotNil(AgentMailTime.parse("2026-09-24T22:27:17.716028+00:00"))
        XCTAssertEqual(AgentMailTime.parse("2026-10-04T18:00:00Z"), Date(timeIntervalSince1970: 1_791_136_800))
        XCTAssertNil(AgentMailTime.parse("yesterday"))
    }
}
```

(`1_791_136_800` is `2026-10-04T18:00:00Z` — `date -u -j -f "%Y-%m-%dT%H:%M:%SZ" 2026-10-04T18:00:00Z +%s`.)

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=ReservationsReadTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'ReservationRows' in scope`.

- [ ] **Step 4: Implement the read**

Replace the `reservations(project:)` stub and its doc comment in `FlywheelReadCommands.swift` with:

```swift
    /// `am reservations --project <project> --all --json`. The row shape was captured live in
    /// L3-S Task 11a (`Fixtures/FlightControlL3/Swarm/am-reservations-held.json`). `waiters` is
    /// always empty here: am knows who holds, not who is waiting — the swarm's guard-block capture
    /// fills that in (Task 11e).
    func reservations(project: String) async -> [RawReservation]? {
        await read(amPath, ["reservations", "--project", project, "--all", "--json"], project: project) {
            ReservationRows.decode($0)
        }
    }
```

and add at the end of the file:

```swift
/// Decodes `am reservations --all --json`'s `all_active` rows. Field names are read from short
/// candidate lists because the robot output has renamed fields between am releases; a row with
/// no recognizable path or holder is dropped rather than guessed.
enum ReservationRows {
    static let pathKeys = ["path_pattern", "path", "pattern", "file"]
    static let holderKeys = ["agent_name", "agent", "holder", "holder_name"]
    static let timeKeys = ["created_ts", "created_at", "acquired_ts", "since"]

    static func decode(_ data: Data) -> [FlywheelReadCommands.RawReservation]? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = object["all_active"] as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let path = pathKeys.lazy.compactMap({ row[$0] as? String }).first,
                  let holder = holderKeys.lazy.compactMap({ holderName(row[$0]) }).first else { return nil }
            let since = timeKeys.lazy.compactMap { (row[$0] as? String).flatMap(AgentMailTime.parse) }.first ?? .distantPast
            return FlywheelReadCommands.RawReservation(file: path, holder: holder, since: since, waiters: [])
        }
    }

    private static func holderName(_ value: Any?) -> String? {
        if let name = value as? String, !name.isEmpty { return name }
        if let object = value as? [String: Any], let name = object["name"] as? String { return name }
        return nil
    }
}

/// am writes microsecond timestamps (`2026-09-22T16:57:34.483761Z`, `…+00:00`), which
/// `JSONDecoder.iso8601` refuses. Fractions are cut to milliseconds before parsing.
enum AgentMailTime {
    static func parse(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
```

In `FlywheelReadCommandsTests.swift`, `testUnconfirmedShapesDegradeToNilStub` asserts the stub this
task replaces (and Task 11b replaces `depEdges`). Replace it with:

```swift
    /// `events` is still unconfirmed at the row level (observe-command-shapes notes), so it stays
    /// a nil-stub. `reservations` and `depEdges` are real since L3-S (ReservationsReadTests,
    /// DepEdgesReadTests).
    func testEventsStayANilStub() async {
        let fake = MultiRunner()
        fake.responses["am inbox-events --agent"] = (#"{"events":[],"next_cursor":0,"has_more":false}"#, 0)
        let rc = FlywheelReadCommands(runner: fake, amPath: "am", brPath: "br")
        let events = await rc.events(project: "/tmp/p", after: "0")
        XCTAssertNil(events)
    }
```

- [ ] **Step 5: Run the read tests**

Run: `FD_TEST_FILTER=ReservationsReadTests,FlywheelReadCommandsTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Flywheel/Observe/FlywheelReadCommands.swift Tests/FlightDeckTests/Flywheel/Observe/FlywheelReadCommandsTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/ReservationsReadTests.swift Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm/am-reservations-held.json Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm/guard-block.txt Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm/probe-names.json
git commit -m "feat: read Agent Mail reservations from a captured real row shape" -m "Two agents reserved overlapping globs in a scratch repo; the all_active row and the guard's block message were recorded as fixtures. The reservations lane, a nil stub since Observe, now decodes those rows (holder, path pattern, microsecond timestamp) and still degrades to nil on anything it cannot read." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11b: Dependency edges from `br graph`

**Files:**
- Modify: `Sources/IntakeKit/GraphSnapshot.swift` (`decodeEdges(graph:)`)
- Modify: `Sources/FlightDeck/Flywheel/Observe/FlywheelReadCommands.swift` (`depEdges`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/DepEdgesReadTests.swift`

**Interfaces:**
- Produces: `GraphSnapshot.decodeEdges(graph: Data) throws -> Set<DepEdge>` (public);
  `FlywheelReadCommands.depEdges(project:)` real — `br graph --all --json --db <project>/.beads/beads.db`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The handoff's shortcut: release already decodes `br graph --all --json` live, so Observe's
/// dependency lane reuses that decoder instead of the never-probed `br dep list`.
final class DepEdgesReadTests: XCTestCase {
    private func graph() throws -> String {
        String(decoding: try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "br-graph-all", withExtension: "json", subdirectory: "Fixtures/Intake"))), as: UTF8.self)
    }

    func testDecodeEdgesIsTheGraphHalfOfTheSnapshot() throws {
        XCTAssertEqual(try GraphSnapshot.decodeEdges(graph: Data(try graph().utf8)),
                       [DepEdge(dependent: "t-5mi", dependency: "t-lqw")])
    }

    func testDepEdgesReadsGraphAll() async throws {
        let fake = MultiRunner()
        fake.responses["br graph --all"] = (try graph(), 0)
        let edges = await FlywheelReadCommands(runner: fake).depEdges(project: "/tmp/p")
        XCTAssertEqual(edges, [FlywheelReadCommands.RawDepEdge(from: "t-5mi", to: "t-lqw")])
        XCTAssertEqual(fake.argv.last, ["br", "graph", "--all", "--json", "--db", "/tmp/p/.beads/beads.db"])
    }

    func testAFailingGraphDegradesToNil() async {
        let edges = await FlywheelReadCommands(runner: MultiRunner()).depEdges(project: "/tmp/p")
        XCTAssertNil(edges)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=DepEdgesReadTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `type 'GraphSnapshot' has no member 'decodeEdges'`.

- [ ] **Step 3: Implement**

In `GraphSnapshot.swift`, add inside `GraphSnapshot` and make `decode` use it:

```swift
    /// `br graph --all --json`'s `[dependent, dependency]` pairs, on their own — Observe's
    /// dependency lane needs the edges without the full bead list.
    public static func decodeEdges(graph: Data) throws -> Set<DepEdge> {
        let comps = try JSONDecoder().decode(GraphEnvelope.self, from: graph).components
        return Set(comps.flatMap(\.edges).compactMap { pair -> DepEdge? in
            pair.count == 2 ? DepEdge(dependent: pair[0], dependency: pair[1]) : nil
        })
    }
```

and in `decode(list:graph:)` replace the two lines that build `comps` and `edges` with
`let edges = try decodeEdges(graph: graph)` (keeping `issues` and `beads` as they are).

In `FlywheelReadCommands.swift`, add `import IntakeKit` at the top and replace the `depEdges` stub
and its comment with:

```swift
    /// `br graph --all --json --db <db>` — the same command release reads live
    /// (`IntakeKit/GraphReader`), decoded by the same `GraphSnapshot.decodeEdges`. `from` is the
    /// dependent, `to` its dependency. Sorted so a repoll with the same graph is equal.
    func depEdges(project: String) async -> [RawDepEdge]? {
        await read(brPath, ["graph", "--all", "--json", "--db", beadsDBPath(project: project)], project: project) { data in
            (try? GraphSnapshot.decodeEdges(graph: data)).map { edges in
                edges.map { RawDepEdge(from: $0.dependent, to: $0.dependency) }
                    .sorted { ($0.from, $0.to) < ($1.from, $1.to) }
            }
        }
    }
```

- [ ] **Step 4: Run**

Run: `FD_TEST_FILTER=DepEdgesReadTests,GraphSnapshotTests,FlywheelReadCommandsTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/GraphSnapshot.swift Sources/FlightDeck/Flywheel/Observe/FlywheelReadCommands.swift Tests/FlightDeckTests/FlightControlL3/Swarm/DepEdgesReadTests.swift
git commit -m "feat: read Observe's dependency edges from br graph --all" -m "The depEdges lane reuses the br graph decoder release already runs live, instead of the unprobed br dep list, which needs an issue id and exposes no row schema." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11c: Parse guard blocks and `BLOCKED:` lines; the contested relation

**Files:**
- Create: `Sources/IntakeKit/FlightControl/Swarm/AgentOutputSignal.swift`
- Create: `Sources/IntakeKit/FlightControl/Swarm/ContestedRelation.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/AgentOutputSignalTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/ContestedRelationTests.swift`

**Interfaces:**
- Produces (IntakeKit):
  - `struct GuardBlock: Codable, Equatable { file; pattern; holder; message }`
  - `enum AgentOutputSignal: Equatable { guardBlock(GuardBlock), blocked(String) }`
  - `enum AgentOutputScan { static let guardMarker; static func signals(line:record:) -> [AgentOutputSignal]; static func guardBlocks(in:) -> [GuardBlock]; static func blockedLines(in:) -> [String] }`
  - `enum Glob { static func matches(_ pattern: String, _ path: String) -> Bool }`
  - `struct HeldReservation: Equatable { pattern; holder; since: Date? }`
  - `struct SessionSignals: Equatable { guardBlock: GuardBlock?; guardBlockAt: Date?; blocked: String?; blockedAt: Date? }`
  - `struct Contest: Equatable { file; holder; heldSince: Date?; message: String; at: Date }`
  - `enum ContestedRelation { static let recentWindow: TimeInterval = 600; static func contest(agent:signals:reservations:now:) -> Contest? }`

- [ ] **Step 1: Write the failing signal tests**

```swift
import XCTest
import IntakeKit

/// The guard's block message is an exact, capturable string (spike findings), and it reaches FD
/// inside an agent's own records — claude's transcript tool_result, codex's rollout exec output.
/// The scan reads every string leaf of a record, so it does not care which shape carries it; and
/// `BLOCKED:` counts only in text the AGENT wrote, never in the prompt that asked for it.
final class AgentOutputSignalTests: XCTestCase {
    private func capturedMessage() throws -> String {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "guard-block", withExtension: "txt",
                                                           subdirectory: "Fixtures/FlightControlL3/Swarm"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let line = text.split(separator: "\n").first { $0.contains(AgentOutputScan.guardMarker) }
        return line.map(String.init)
            ?? "mcp-agent-mail: file reservation conflict detected! widget.py conflicts with reservation 'widget.py' held by BlueFalcon"
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testTheCapturedGuardMessageParses() throws {
        let blocks = AgentOutputScan.guardBlocks(in: try capturedMessage())
        XCTAssertEqual(blocks.count, 1)
        XCTAssertFalse(blocks[0].file.isEmpty)
        XCTAssertFalse(blocks[0].pattern.isEmpty)
        XCTAssertFalse(blocks[0].holder.isEmpty)
    }

    func testTheSpikeMessageParsesExactly() {
        XCTAssertEqual(AgentOutputScan.guardBlocks(in: "Exit code 1\nmcp-agent-mail: file reservation conflict detected! widget.py conflicts with reservation 'widget.py' held by BlueFalcon\n"),
                       [GuardBlock(file: "widget.py", pattern: "widget.py", holder: "BlueFalcon",
                                   message: "mcp-agent-mail: file reservation conflict detected! widget.py conflicts with reservation 'widget.py' held by BlueFalcon")])
    }

    func testAClaudeToolResultCarriesIt() throws {
        let msg = "mcp-agent-mail: file reservation conflict detected! Sources/Foo.swift conflicts with reservation 'Sources/*.swift' held by GreenFox"
        let record: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "Exit code 1\n" + msg]]]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        XCTAssertEqual(AgentOutputScan.signals(line: line, record: record),
                       [.guardBlock(GuardBlock(file: "Sources/Foo.swift", pattern: "Sources/*.swift", holder: "GreenFox", message: msg))])
    }

    func testACodexExecEndCarriesItOnceEvenInTwoFields() throws {
        let msg = "mcp-agent-mail: file reservation conflict detected! a.swift conflicts with reservation 'a.swift' held by RedStone"
        let record: [String: Any] = ["type": "event_msg", "payload": ["type": "exec_command_end", "stderr": msg, "aggregated_output": msg]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        XCTAssertEqual(AgentOutputScan.signals(line: line, record: record).count, 1)
    }

    func testBlockedCountsOnlyInTheAgentsOwnText() throws {
        let claude = try object(#"{"type":"assistant","message":{"content":[{"type":"text","text":"Working.\nBLOCKED: Sources/Foo.swift is reserved by GreenFox"}]}}"#)
        XCTAssertEqual(AgentOutputScan.signals(line: "BLOCKED:", record: claude), [.blocked("Sources/Foo.swift is reserved by GreenFox")])
        let prompt = try object(#"{"type":"user","message":{"content":"If you are blocked, say so in one line that starts with BLOCKED:, then stop."}}"#)
        XCTAssertEqual(AgentOutputScan.signals(line: "BLOCKED:", record: prompt), [], "the task prompt is not the agent")
        let codex = try object(#"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"BLOCKED: waiting on a.swift"}]}}"#)
        XCTAssertEqual(AgentOutputScan.signals(line: "BLOCKED:", record: codex), [.blocked("waiting on a.swift")])
    }

    func testALineWithoutAMarkerIsNotParsed() throws {
        XCTAssertEqual(AgentOutputScan.signals(line: #"{"type":"assistant"}"#, record: ["type": "assistant"]), [])
    }
}
```

- [ ] **Step 2: Write the failing relation tests**

```swift
import XCTest
import IntakeKit

/// Spec §7.5: contested is a relation, not a status — an agent is contested when it has a recent
/// guard block, or when it said BLOCKED: on a file another agent holds.
final class ContestedRelationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let held = [HeldReservation(pattern: "Sources/*.swift", holder: "GreenFox",
                                        since: Date(timeIntervalSince1970: 1_790_000_000 - 360))]
    private let block = GuardBlock(file: "Sources/Foo.swift", pattern: "Sources/*.swift", holder: "GreenFox",
                                   message: "mcp-agent-mail: file reservation conflict detected! Sources/Foo.swift conflicts with reservation 'Sources/*.swift' held by GreenFox")

    func testARecentGuardBlockIsAContestNamingTheHolderAndSince() {
        let c = ContestedRelation.contest(agent: "BlueLake",
                                          signals: SessionSignals(guardBlock: block, guardBlockAt: now - 30),
                                          reservations: held, now: now)
        XCTAssertEqual(c, Contest(file: "Sources/Foo.swift", holder: "GreenFox", heldSince: held[0].since,
                                  message: block.message, at: now - 30))
    }

    func testAnOldGuardBlockIsNotAContest() {
        XCTAssertNil(ContestedRelation.contest(agent: "BlueLake",
                                               signals: SessionSignals(guardBlock: block, guardBlockAt: now - 601),
                                               reservations: held, now: now))
    }

    func testAGuardBlockWorksWithoutReservationRows() {
        let c = ContestedRelation.contest(agent: "BlueLake", signals: SessionSignals(guardBlock: block, guardBlockAt: now),
                                          reservations: [], now: now)
        XCTAssertEqual(c?.holder, "GreenFox")
        XCTAssertNil(c?.heldSince)
    }

    func testBlockedOnAFileAnotherAgentHolds() {
        let c = ContestedRelation.contest(agent: "BlueLake",
                                          signals: SessionSignals(blocked: "need Sources/Foo.swift, it is reserved", blockedAt: now),
                                          reservations: held, now: now)
        XCTAssertEqual(c?.file, "Sources/Foo.swift")
        XCTAssertEqual(c?.holder, "GreenFox")
        XCTAssertEqual(c?.message, "BLOCKED: need Sources/Foo.swift, it is reserved")
    }

    func testBlockedOnSomethingElseIsNotContested() {
        XCTAssertNil(ContestedRelation.contest(agent: "BlueLake",
                                               signals: SessionSignals(blocked: "the API key is missing", blockedAt: now),
                                               reservations: held, now: now))
    }

    func testAnAgentIsNeverContestedByItself() {
        XCTAssertNil(ContestedRelation.contest(agent: "GreenFox",
                                               signals: SessionSignals(blocked: "Sources/Foo.swift", blockedAt: now),
                                               reservations: held, now: now))
    }

    func testGlob() {
        XCTAssertTrue(Glob.matches("Sources/*.swift", "Sources/Foo.swift"))
        XCTAssertFalse(Glob.matches("Sources/*.swift", "Sources/Sub/Foo.swift"))
        XCTAssertTrue(Glob.matches("Sources/**", "Sources/Sub/Foo.swift"))
        XCTAssertTrue(Glob.matches("a?.c", "ab.c"))
        XCTAssertTrue(Glob.matches("x.swift", "x.swift"))
        XCTAssertFalse(Glob.matches("x.swift", "xxswift"), "a dot is literal")
    }
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `FD_TEST_FILTER=AgentOutputSignalTests,ContestedRelationTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'AgentOutputScan' in scope`.

- [ ] **Step 4: Implement `AgentOutputSignal.swift`**

```swift
import Foundation

/// One pre-commit guard refusal, as the guard prints it:
/// `mcp-agent-mail: file reservation conflict detected! <file> conflicts with reservation '<pattern>' held by <holder>`.
public struct GuardBlock: Codable, Equatable, Sendable {
    public var file: String
    public var pattern: String
    public var holder: String
    public var message: String
    public init(file: String, pattern: String, holder: String, message: String) {
        self.file = file; self.pattern = pattern; self.holder = holder; self.message = message
    }
}

public enum AgentOutputSignal: Equatable, Sendable {
    case guardBlock(GuardBlock)
    /// The text after `BLOCKED:` in a line the agent wrote (the task prompt asks for exactly that).
    case blocked(String)
}

/// Scans one transcript/rollout record for the two things contested detection needs. A cheap
/// substring check on the raw line gates the parse, so ordinary records cost one `contains`.
public enum AgentOutputScan {
    public static let guardMarker = "file reservation conflict detected"
    private static let blockedMarker = "BLOCKED:"

    public static func signals(line: String, record: [String: Any]) -> [AgentOutputSignal] {
        var out: [AgentOutputSignal] = []
        if line.contains(guardMarker) {
            for text in strings(in: record) {
                for block in guardBlocks(in: text) where !out.contains(.guardBlock(block)) { out.append(.guardBlock(block)) }
            }
        }
        if line.contains(blockedMarker) {
            for text in assistantTexts(in: record) {
                for blocked in blockedLines(in: text) where !out.contains(.blocked(blocked)) { out.append(.blocked(blocked)) }
            }
        }
        return out
    }

    public static func guardBlocks(in text: String) -> [GuardBlock] {
        let pattern = #"mcp-agent-mail: file reservation conflict detected! (.+?) conflicts with reservation '([^']+)' held by ([A-Za-z0-9_.-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let whole = Range(match.range, in: text), let file = Range(match.range(at: 1), in: text),
                  let pat = Range(match.range(at: 2), in: text), let holder = Range(match.range(at: 3), in: text) else { return nil }
            return GuardBlock(file: String(text[file]), pattern: String(text[pat]), holder: String(text[holder]),
                              message: String(text[whole]))
        }
    }

    public static func blockedLines(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(blockedMarker) else { return nil }
            let rest = trimmed.dropFirst(blockedMarker.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
    }

    /// Every string leaf, so the guard message is found in whatever field a harness puts tool
    /// output in.
    static func strings(in value: Any) -> [String] {
        switch value {
        case let s as String: return [s]
        case let d as [String: Any]: return d.values.flatMap(strings(in:))
        case let a as [Any]: return a.flatMap(strings(in:))
        default: return []
        }
    }

    /// Text the agent itself wrote: claude `assistant` records; codex assistant `message` items
    /// and `agent_message` events. Never a user record — the task prompt contains "BLOCKED:".
    static func assistantTexts(in record: [String: Any]) -> [String] {
        if record["type"] as? String == "assistant",
           let message = record["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
            return content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
        }
        if let payload = record["payload"] as? [String: Any] {
            if payload["type"] as? String == "message", payload["role"] as? String == "assistant",
               let content = payload["content"] as? [[String: Any]] {
                return content.compactMap { $0["text"] as? String }
            }
            if payload["type"] as? String == "agent_message", let message = payload["message"] as? String { return [message] }
        }
        return []
    }
}
```

If Task 11a captured a message whose wording differs from the spike's (for example a different
lead-in than `mcp-agent-mail: file reservation conflict detected!`), change `guardMarker` and the
regex's literal prefix to the captured wording; `testTheCapturedGuardMessageParses` pins it.

- [ ] **Step 5: Implement `ContestedRelation.swift`**

```swift
import Foundation

public struct HeldReservation: Equatable, Sendable {
    public var pattern: String
    public var holder: String
    public var since: Date?
    public init(pattern: String, holder: String, since: Date?) { self.pattern = pattern; self.holder = holder; self.since = since }
}

/// The last guard block and the last BLOCKED: line one session produced (spec §7.4: "store the
/// last block per session").
public struct SessionSignals: Equatable, Sendable {
    public var guardBlock: GuardBlock?
    public var guardBlockAt: Date?
    public var blocked: String?
    public var blockedAt: Date?
    public init(guardBlock: GuardBlock? = nil, guardBlockAt: Date? = nil, blocked: String? = nil, blockedAt: Date? = nil) {
        self.guardBlock = guardBlock; self.guardBlockAt = guardBlockAt; self.blocked = blocked; self.blockedAt = blockedAt
    }
}

public struct Contest: Equatable, Sendable {
    public var file: String
    public var holder: String
    public var heldSince: Date?
    /// The guard's message, or the agent's BLOCKED: line, quoted in the drawer.
    public var message: String
    public var at: Date
    public init(file: String, holder: String, heldSince: Date?, message: String, at: Date) {
        self.file = file; self.holder = holder; self.heldSince = heldSince; self.message = message; self.at = at
    }
}

/// `*` and `?` stop at `/`; `**` crosses it. Everything else is literal.
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        var chars = Array(pattern)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            switch c {
            case "*":
                if chars.first == "*" { chars = chars.dropFirst(); regex += ".*" } else { regex += "[^/]*" }
            case "?": regex += "[^/]"
            default: regex += NSRegularExpression.escapedPattern(for: String(c))
            }
        }
        regex += "$"
        return path.range(of: regex, options: .regularExpression) != nil
    }
}

/// Spec §7.5. Not a `SessionStatus`: a contested agent can be busy (retrying) or idle (stopped
/// after BLOCKED:), and that status keeps meaning what it means.
public enum ContestedRelation {
    public static let recentWindow: TimeInterval = 600

    public static func contest(agent: String, signals: SessionSignals, reservations: [HeldReservation], now: Date) -> Contest? {
        if let block = signals.guardBlock, let at = signals.guardBlockAt,
           now.timeIntervalSince(at) <= recentWindow, block.holder != agent {
            let held = reservations.first {
                $0.holder == block.holder && ($0.pattern == block.pattern || Glob.matches($0.pattern, block.file))
            }
            return Contest(file: block.file, holder: block.holder, heldSince: held?.since, message: block.message, at: at)
        }
        if let text = signals.blocked, let at = signals.blockedAt, now.timeIntervalSince(at) <= recentWindow {
            for token in pathTokens(text) {
                if let held = reservations.first(where: { $0.holder != agent && ($0.pattern == token || Glob.matches($0.pattern, token)) }) {
                    return Contest(file: token, holder: held.holder, heldSince: held.since, message: "BLOCKED: " + text, at: at)
                }
            }
        }
        return nil
    }

    /// Words that look like paths: they contain `/` or `.`, with surrounding punctuation removed.
    static func pathTokens(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;()\"'`")))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".:")) }
            .filter { !$0.isEmpty && ($0.contains("/") || $0.contains(".")) }
    }
}
```

- [ ] **Step 6: Run both**

Run: `FD_TEST_FILTER=AgentOutputSignalTests,ContestedRelationTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Swarm/AgentOutputSignal.swift Sources/IntakeKit/FlightControl/Swarm/ContestedRelation.swift Tests/FlightDeckTests/FlightControlL3/Swarm/AgentOutputSignalTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/ContestedRelationTests.swift
git commit -m "feat: recognise guard blocks and BLOCKED lines, and derive contested files" -m "AgentOutputScan finds the guard's exact refusal in any string field of a transcript or rollout record and BLOCKED: only in text the agent wrote. ContestedRelation turns a recent block (ten minutes) or a BLOCKED: line naming a file another agent holds into a contest naming the file, the holder and how long they have held it." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11d: Capture signals from claude and codex output and mark sessions contested

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentKind.swift` (`AgentEvent.outputSignals`)
- Modify: `Sources/FlightDeck/TranscriptWatcher.swift` (`Scan.signals`, `onSignals`)
- Modify: `Sources/FlightDeck/Agents/ClaudeRuntime.swift` (pass `onSignals`)
- Modify: `Sources/FlightDeck/Agents/Codex/CodexRolloutWatcher.swift` (`CodexScan` emits `.outputSignals`)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`apply(_:to:)` arm)
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmService.swift` (`signals`, `recordSignals`, `reservationsLookup`, `contest(for:)`, `contests(project:)`, `isContested` wiring)
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmAnnotations.swift` (contest lines in the assignment)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/OutputSignalWiringTests.swift`

**Interfaces:**
- Produces: `AgentEvent.outputSignals([AgentOutputSignal])`; `TranscriptWatcher(…, onSignals:)` (defaulted nil);
  `SwarmService.signals: [UUID: SessionSignals]`, `recordSignals(_:session:)`,
  `reservationsLookup: (String) -> [HeldReservation]`, `contest(for:) -> Contest?`,
  `contests(project:) -> [String: Contest]`, `declaredBlocked(project:) -> Set<String>`;
  `SwarmAnnotations.contestLines(_:now:) -> [String]`

- [ ] **Step 1: Find every exhaustive switch over `AgentEvent`**

Run: `rg -n "case \.turnAborted" Sources/FlightDeck`
Expected today: `SessionStore.swift` (the `apply(_:to:)` switch) and possibly runtime code. Every
hit that is a `switch` over `AgentEvent` without `default` gets an `.outputSignals` arm in Step 5.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// End to end from an agent's own file to a contested row: claude's transcript tail and codex's
/// rollout tail both surface the guard block, the store hands it to the swarm, and the swarm
/// relates it to the project's reservations.
@MainActor
final class OutputSignalWiringTests: XCTestCase {
    private var dir: URL!
    private let msg = "mcp-agent-mail: file reservation conflict detected! Sources/Foo.swift conflicts with reservation 'Sources/*.swift' held by GreenFox"
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("signals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func append(_ record: [String: Any], to url: URL) throws {
        var data = try JSONSerialization.data(withJSONObject: record); data.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) { try h.seekToEnd(); try h.write(contentsOf: data); try h.close() }
        else { try data.write(to: url) }
    }

    func testClaudesTranscriptTailReportsTheGuardBlock() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [AgentOutputSignal] = []
        let watcher = TranscriptWatcher(sessionID: UUID(), url: url, onTitle: { _ in },
                                        onSignals: { seen += $0 })
        watcher.drain()   // no file yet: the start is chosen at 0
        try append(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t", "is_error": true, "content": "Exit code 1\n" + msg]]]], to: url)
        watcher.drain()
        XCTAssertEqual(seen.count, 1)
        guard case .guardBlock(let block)? = seen.first else { return XCTFail("expected a guard block") }
        XCTAssertEqual(block.holder, "GreenFox")
    }

    func testCodexsRolloutTailReportsTheGuardBlock() throws {
        let url = dir.appendingPathComponent("r.jsonl")
        var events: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: url, conversationID: UUID(), onEvent: { events.append($0) })
        watcher.drain()
        try append(["type": "event_msg", "payload": ["type": "exec_command_end", "stderr": msg]], to: url)
        watcher.drain()
        XCTAssertTrue(events.contains { if case .outputSignals(let s) = $0 { return s.count == 1 }; return false })
    }

    func testTheStoreHandsSignalsToTheSwarmAndTheRowBecomesContested() throws {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        rig.store.save([rig.record(state: .paused, agents: [a])])
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
        let store = SessionStore(provider: nil, persistence: nil)
        store.useSwarmService(service)
        // After `useSwarmService`, which (from Task 11e) points the lookup at Observe's projection.
        service.reservationsLookup = { _ in [HeldReservation(pattern: "Sources/*.swift", holder: "GreenFox", since: rig.now - 360)] }
        let block = try XCTUnwrap(AgentOutputScan.guardBlocks(in: msg).first)
        store.apply(.outputSignals([.guardBlock(block)]), to: a.session)
        XCTAssertEqual(service.signals[a.session]?.guardBlock, block)
        XCTAssertEqual(service.contest(for: a.session)?.holder, "GreenFox")
        XCTAssertEqual(service.annotation(for: a.session, now: rig.now)?.contested, true)
        XCTAssertTrue(service.summary(forProject: SwarmFixtures.project)?.text.contains("1 contested") == true)
        let lines = try XCTUnwrap(service.assignment(for: a.session, now: rig.now)).lines
        XCTAssertTrue(lines.contains("waits on Sources/Foo.swift, held by GreenFox · 6 min"))
        XCTAssertTrue(lines.contains("“\(msg)”"))
    }

    func testDeclaredBlockedNamesIdleAgentsThatSaidBlocked() {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        rig.host.agentsByProject[FlywheelObserveService.key(SwarmFixtures.project)] = [(a.session, "BlueLake")]
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
        service.recordSignals([.blocked("waiting on the API key")], session: a.session)
        XCTAssertEqual(service.declaredBlocked(project: SwarmFixtures.project), ["BlueLake"])
        rig.host.busy.insert(a.session)
        XCTAssertEqual(service.declaredBlocked(project: SwarmFixtures.project), [], "busy again: no longer blocked")
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=OutputSignalWiringTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `extra argument 'onSignals' in call`.

- [ ] **Step 4: Add the event case and the taps**

In `AgentKind.swift`, add `import IntakeKit` and, as the last case of `AgentEvent`:

```swift
    /// Guard blocks and `BLOCKED:` lines found in the agent's own output (L3-S contested
    /// detection). Carried as an event so claude's transcript tail and codex's rollout tail reach
    /// the store through the one channel every agent report already takes.
    case outputSignals([AgentOutputSignal])
```

In `TranscriptWatcher.swift`:
- add `import IntakeKit`;
- add a stored `private let onSignals: (([AgentOutputSignal]) -> Void)?` and an init parameter
  `onSignals: (([AgentOutputSignal]) -> Void)? = nil` (last), assigned in `init`;
- in `struct Scan`, add `var signals: [AgentOutputSignal] = []`, and inside `Scan.read`'s loop, after
  `result.events += ClaudeSession.events(inObject: obj, sessionID: sessionID)`:

```swift
            result.signals += AgentOutputScan.signals(line: line, record: obj)
```

- at the end of `apply(_ scan:)`: `if !scan.signals.isEmpty { onSignals?(scan.signals) }`.

In `ClaudeRuntime.swift`'s `TranscriptWatcher(...)` call, add after `onAPIError:`:

```swift
                onSignals: { subscribers.emit(.outputSignals($0)) },
```

(keeping `onMessages:` last; reorder the init's parameters so `onSignals` sits before `onMessages`
if Swift requires the call order to match — it does, so declare `onSignals` before `onMessages`
in the init.)

In `CodexRolloutWatcher.swift`, add `import IntakeKit`, and inside `CodexScan.read`'s loop after
`result.events += CodexEventMapper.events(inRecord: record)`:

```swift
            let signals = AgentOutputScan.signals(line: line, record: record)
            if !signals.isEmpty { result.events.append(.outputSignals(signals)) }
```

(`CodexRolloutWatcher.apply` already forwards every `scan.events` entry through `onEvent`.)

- [ ] **Step 5: Route it in the store and add the swarm side**

In `SessionStore.apply(_:to:)`, add the arm (and the same arm to any other switch Step 1 found):

```swift
        case .outputSignals(let signals):
            // Contested detection (L3-S §7). Every flywheel tab's signals are kept, swarm or not:
            // the Observe enrichment reads them for any agent in the project.
            swarmService.recordSignals(signals, session: tabID)
```

Add a test seam beside `swarmServiceIfBuilt`:

```swift
    /// Installs a service built elsewhere — tests, and the Debug fixture backend.
    func useSwarmService(_ service: SwarmService) {
        swarmServiceStorage = service
        // Only when it has none: re-assigning rebuilds every controller, which would orphan a
        // reconcile or launch the service already started.
        if service.dependencies == nil, let swarmDependencies { service.dependencies = swarmDependencies }
        swarmChangeForward = service.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
```

In `SwarmService`, add stored properties after `isContested`:

```swift
    /// The last guard block and BLOCKED: line per session (spec §7.4).
    private(set) var signals: [UUID: SessionSignals] = [:]
    /// The project's held reservations, from the Observe projection (wired by `SessionStore`).
    var reservationsLookup: (String) -> [HeldReservation] = { _ in [] }
```

and at the end of `init`:

```swift
        isContested = { [weak self] in self?.contest(for: $0) != nil }
```

Append to `SwarmService` (in `SwarmService.swift`):

```swift
extension SwarmService {
    func recordSignals(_ new: [AgentOutputSignal], session: UUID) {
        guard !new.isEmpty else { return }
        var current = signals[session] ?? SessionSignals()
        for signal in new {
            switch signal {
            case .guardBlock(let block): current.guardBlock = block; current.guardBlockAt = now()
            case .blocked(let text): current.blocked = text; current.blockedAt = now()
            }
        }
        signals[session] = current
        objectWillChange.send()
        onChange?()
    }

    /// The agent name a session runs as, from its swarm record or its flywheel identity.
    private func agentName(of session: UUID) -> (name: String, project: String)? {
        if let (record, agent) = agentRecord(session) { return (agent.agentName, record.project) }
        return nil
    }

    func contest(for session: UUID) -> Contest? {
        guard let signals = signals[session], let (name, project) = agentName(of: session) else { return nil }
        return ContestedRelation.contest(agent: name, signals: signals, reservations: reservationsLookup(Self.key(project)), now: currentTime)
    }

    /// Agent name → contest, for every flywheel tab in the project — the Observe enrichment's input.
    func contests(project: String) -> [String: Contest] {
        let key = Self.key(project)
        var out: [String: Contest] = [:]
        for (session, name) in host.flywheelAgents(inProject: key) {
            guard let s = signals[session],
                  let c = ContestedRelation.contest(agent: name, signals: s, reservations: reservationsLookup(key), now: currentTime)
            else { continue }
            out[name] = c
        }
        return out
    }

    /// Agents that said BLOCKED: and have not started working since — the notifier's block trigger.
    func declaredBlocked(project: String) -> Set<String> {
        Set(host.flywheelAgents(inProject: Self.key(project)).compactMap { session, name in
            guard signals[session]?.blocked != nil, host.isAgentIdle(session) else { return nil }
            return name
        })
    }
}
```

`now` is private to the class; add `var currentTime: Date { now() }` inside the class body (next
to `allRecords`) so the extension can read it.

In `SwarmAnnotations.swift`, append:

```swift
extension SwarmAnnotations {
    /// Spec §7.5's drawer sentence and the quoted message.
    static func contestLines(_ contest: Contest, now: Date) -> [String] {
        let minutes = Int(now.timeIntervalSince(contest.heldSince ?? contest.at) / 60)
        return ["waits on \(contest.file), held by \(contest.holder) · \(minutes) min", "“\(contest.message)”"]
    }
}
```

and in `SwarmService.assignment(for:now:)`, return the detail with the contest lines appended:

```swift
        var detail = SwarmAnnotations.assignment(
            agent: agent, headroom: headroom(of: agent),
            previous: agent.handedOffFrom.flatMap { record.agent($0) },
            next: agent.handedOffTo.flatMap { record.agent($0) },
            lastActive: host.lastActiveAt(for: session), now: now)
        if let contest = contest(for: session) { detail.lines += SwarmAnnotations.contestLines(contest, now: now) }
        return detail
```

- [ ] **Step 6: Run the wiring tests and the watcher suites**

Run: `FD_TEST_FILTER=OutputSignalWiringTests,TranscriptWatcherTests,CodexRolloutWatcherTests,SwarmAnnotationTests,ObserveAssignmentLaneTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures (if a watcher class name differs, `test-unit.sh` says so — `rg -ln "TranscriptWatcher\(" Tests | head` finds the real one).

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentKind.swift Sources/FlightDeck/TranscriptWatcher.swift Sources/FlightDeck/Agents/ClaudeRuntime.swift Sources/FlightDeck/Agents/Codex/CodexRolloutWatcher.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/FlightControl/Swarm/SwarmService.swift Sources/FlightDeck/FlightControl/Swarm/SwarmAnnotations.swift Tests/FlightDeckTests/FlightControlL3/Swarm/OutputSignalWiringTests.swift
git commit -m "feat: mark a swarm agent contested when the guard blocks its commit" -m "Claude's transcript tail and codex's rollout tail scan each record for the guard's refusal and for BLOCKED: lines the agent wrote, and report them as AgentEvent.outputSignals. The swarm keeps the last of each per session and relates them to the project's reservations: the row shows the contested badge, the header counts it, and the drawer says which file waits on whom for how long, quoting the guard. Claude is read from the transcript rather than the hook log because a failed tool call's output there is unverified." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11e: Read the new lanes live, enrich Observe, and light up the notifier

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Swarm/ObserveEnrichment.swift`
- Modify: `Sources/FlightDeck/Flywheel/Observe/FlywheelWatcher.swift` (four reads)
- Modify: `Sources/FlightDeck/Flywheel/Observe/FlywheelProjection.swift` (`declaredBlocked`)
- Modify: `Sources/FlightDeck/Flywheel/Observe/FlywheelObserveService.swift` (`enrich` hook)
- Modify: `Sources/FlightDeck/Flywheel/Observe/FlywheelNotifier.swift` (cycle owner)
- Modify: `Sources/FlightDeck/SessionStore.swift` (wire `enrich` and `reservationsLookup`)
- Modify: `Tests/FlightDeckTests/Flywheel/Observe/FlywheelWatcherTests.swift` (`expectedReadsPerPoll`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/ObserveEnrichmentTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/FlywheelNotifierLightUpTests.swift`

**Interfaces:**
- Produces: `FlywheelSnapshot.declaredBlocked: Set<String>` (defaulted `[]`);
  `FlywheelObserveService.enrich: ((String, FlywheelSnapshot) -> FlywheelSnapshot)?`;
  `enum ObserveEnrichment { static func enrich(_:contests:activity:blocked:) -> FlywheelSnapshot }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Observe's projection gets three facts it could not read for itself: who waits on a reservation
/// (from guard blocks), when each agent was last active (from its tab), and who declared BLOCKED:.
final class ObserveEnrichmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let reservation = FlywheelReadCommands.RawReservation(file: "Sources/*.swift", holder: "GreenFox",
                                                                  since: Date(timeIntervalSince1970: 1_790_000_000 - 360), waiters: [])

    func testAContestBecomesAWaiterOnTheMatchingReservation() {
        let contest = Contest(file: "Sources/Foo.swift", holder: "GreenFox", heldSince: nil, message: "m", at: now)
        let snapshot = ObserveEnrichment.enrich(
            FlywheelSnapshot(agents: [], beads: [], reservations: [reservation], depEdges: [], events: nil),
            contests: ["BlueLake": contest], activity: [:], blocked: [])
        XCTAssertEqual(snapshot.reservations?.first?.waiters, ["BlueLake"])
    }

    func testActivityStandsInForAMissingEventsLane() {
        let snapshot = ObserveEnrichment.enrich(
            FlywheelSnapshot(agents: [], beads: [], reservations: [], depEdges: [], events: nil),
            contests: [:], activity: ["GreenFox": now - 1_200], blocked: ["BlueLake"])
        XCTAssertEqual(snapshot.events, [FlywheelReadCommands.RawEvent(agent: "GreenFox", kind: "activity", at: now - 1_200)])
        XCTAssertEqual(snapshot.declaredBlocked, ["BlueLake"])
    }

    func testARealEventsLaneIsLeftAlone() {
        let real = [FlywheelReadCommands.RawEvent(agent: "A", kind: "x", at: now)]
        let snapshot = ObserveEnrichment.enrich(
            FlywheelSnapshot(agents: [], beads: [], reservations: [], depEdges: [], events: real),
            contests: [:], activity: ["A": now - 9_999], blocked: [])
        XCTAssertEqual(snapshot.events, real)
    }
}
```

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The three FlywheelNotifier triggers were wired but dormant on live data (Level 1 caveat). With
/// real reservations, guard-block waiters, activity and BLOCKED: they fire — and only when a human
/// is needed.
@MainActor
final class FlywheelNotifierLightUpTests: XCTestCase {
    private final class Recording: Notifying {
        var notified: [(UUID, String)] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, subtitle: String, body: String) { notified.append((sessionID, title)) }
        func withdraw(sessionID: UUID) {}
    }
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func projection(holderActiveAt: Date, blocked: Set<String> = [], edges: [FlywheelReadCommands.RawDepEdge] = [],
                            beads: [FlywheelReadCommands.RawBead] = []) -> FlywheelProjection {
        let raw = FlywheelSnapshot(
            agents: [.init(name: "GreenFox"), .init(name: "BlueLake")], beads: beads,
            reservations: [.init(file: "Sources/*.swift", holder: "GreenFox", since: now - 3_600, waiters: [])],
            depEdges: edges, events: nil)
        let contest = Contest(file: "Sources/Foo.swift", holder: "GreenFox", heldSince: nil, message: "m", at: now)
        let enriched = ObserveEnrichment.enrich(raw, contests: ["BlueLake": contest],
                                                activity: ["GreenFox": holderActiveAt, "BlueLake": now], blocked: blocked)
        return FlywheelProjection.project(enriched, now: now, stallThreshold: 600, previous: nil)
    }

    private func notifier(_ recording: Recording, ids: [String: UUID]) -> FlywheelNotifier {
        let n = FlywheelNotifier(notifier: recording, blockThreshold: 120, now: { [now] in now })
        n.route = { _, agent in ids[agent] }
        return n
    }

    func testAStalledHolderOfAContestedFileNotifies() {
        let recording = Recording(); let green = UUID()
        notifier(recording, ids: ["GreenFox": green]).evaluate(projectsByKey: ["/p": projection(holderActiveAt: now - 1_200)])
        XCTAssertEqual(recording.notified.map { $0.0 }, [green])
    }

    func testAnActiveHolderDoesNotNotify() {
        let recording = Recording()
        notifier(recording, ids: ["GreenFox": UUID()]).evaluate(projectsByKey: ["/p": projection(holderActiveAt: now - 30)])
        XCTAssertTrue(recording.notified.isEmpty)
    }

    func testABlockedDeclarationNotifiesOnlyPastTheThreshold() {
        let recording = Recording(); let blue = UUID()
        var clock = now
        let n = FlywheelNotifier(notifier: recording, blockThreshold: 120, now: { clock })
        n.route = { _, agent in agent == "BlueLake" ? blue : nil }
        n.evaluate(projectsByKey: ["/p": projection(holderActiveAt: now, blocked: ["BlueLake"])])
        XCTAssertTrue(recording.notified.isEmpty, "a fresh block is not yet persistent")
        clock = now + 121
        n.evaluate(projectsByKey: ["/p": projection(holderActiveAt: now, blocked: ["BlueLake"])])
        XCTAssertEqual(recording.notified.map { $0.0 }, [blue])
    }

    func testADependencyCycleRoutesToTheTaskOwner() {
        let recording = Recording(); let blue = UUID()
        let p = projection(holderActiveAt: now,
                           edges: [.init(from: "t-1", to: "t-2"), .init(from: "t-2", to: "t-1")],
                           beads: [.init(id: "t-1", title: "a", status: "in_progress", assignee: "BlueLake"),
                                   .init(id: "t-2", title: "b", status: "in_progress", assignee: "GreenFox")])
        notifier(recording, ids: ["BlueLake": blue]).evaluate(projectsByKey: ["/p": p])
        XCTAssertEqual(recording.notified.map { $0.0 }, [blue])
        XCTAssertEqual(recording.notified.map { $0.1 }, ["Dependency cycle involving t-1"])
    }
}
```

(`Recording` implements `Notifying` exactly as `SessionNotifier.swift:17-21` declares it.)

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=ObserveEnrichmentTests,FlywheelNotifierLightUpTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'ObserveEnrichment' in scope`.

- [ ] **Step 3: Implement the projection, service and notifier changes**

`FlywheelProjection.swift`: add to `FlywheelSnapshot` (last, defaulted, so the memberwise init
keeps compiling):

```swift
    /// Agents that declared `BLOCKED:` and have not resumed (L3-S). Not a br status — br's
    /// in-progress list never says blocked — but what the block trigger needs.
    var declaredBlocked: Set<String> = []
```

and in `project(_:now:stallThreshold:previous:)` change `let blocked = bead?.status == "blocked"` to:

```swift
            let blocked = bead?.status == "blocked" || snapshot.declaredBlocked.contains(raw.name)
```

`FlywheelObserveService.swift`: add after `onProjectionsChanged`:

```swift
    /// Adds what Observe cannot read itself — guard-block waiters, tab activity, BLOCKED:
    /// declarations — before the projection is computed. Set by `SessionStore` (L3-S).
    var enrich: ((String, FlywheelSnapshot) -> FlywheelSnapshot)?
```

and in `enable`'s watcher closure, replace `let projection = FlywheelProjection.project(snapshot,`
with:

```swift
            let enriched = self.enrich?(key, snapshot) ?? snapshot
            let projection = FlywheelProjection.project(enriched,
```

`FlywheelNotifier.swift`: in `evaluateDependencyCycle`, replace everything after the `guard … else { return }` line with:

```swift
        // `br graph` edges name tasks, not agents (L3-S): route to the agent holding the leader
        // task so the notification lands on a tab, and name the task in the text.
        let owner = projection.beadsByID[leader]?.assignee ?? leader
        let key = causeKey(projectKey: projectKey, agentName: owner, cause: .depCycle)
        observedKeys.insert(key)
        guard fired[key] == nil else { return }

        fire(key: key, projectKey: projectKey, agentName: owner,
             title: "Dependency cycle involving \(leader)",
             subtitle: projectKey,
             body: "A dependency cycle needs a human to break it: \(cycleParticipants.sorted().joined(separator: ", ")).")
```

Also update the type's "Level 1 caveat" doc comment to say the triggers are live since L3-S
(reservations, `br graph` edges, and the swarm's guard-block/BLOCKED:/activity enrichment).

`FlywheelWatcher.swift`: in `repollNow()`, read the two new lanes:

```swift
        async let agents = reads.agents(project: project)
        async let beads = reads.inProgressBeads(project: project)
        async let reservations = reads.reservations(project: project)
        async let depEdges = reads.depEdges(project: project)
        let snapshot = await FlywheelSnapshot(
            agents: agents, beads: beads, reservations: reservations, depEdges: depEdges, events: nil
        )
```

and update its doc comment ("Only two lanes are live… exactly two shell-outs") to four lanes and
four shell-outs. In `FlywheelWatcherTests.swift`, set `let expectedReadsPerPoll = 4` and update the
comment above it to name the four lanes.

- [ ] **Step 4: Implement `ObserveEnrichment.swift` and wire it**

```swift
import Foundation
import IntakeKit

/// Folds the swarm's knowledge into an Observe snapshot before it is projected. Pure.
enum ObserveEnrichment {
    static func enrich(_ snapshot: FlywheelSnapshot, contests: [String: Contest], activity: [String: Date],
                       blocked: Set<String>) -> FlywheelSnapshot {
        var out = snapshot
        // am knows holders, not waiters; a guard block names both.
        out.reservations = snapshot.reservations?.map { reservation in
            let waiters = contests.filter { _, contest in
                contest.holder == reservation.holder
                    && (Glob.matches(reservation.file, contest.file) || reservation.file == contest.file)
            }.map(\.key).sorted()
            return FlywheelReadCommands.RawReservation(file: reservation.file, holder: reservation.holder,
                                                       since: reservation.since, waiters: waiters)
        }
        // Without an events lane (still a stub) every holder of a contended file read as stalled
        // and the collision trigger fired on every block. A tab's own activity is the stand-in.
        if snapshot.events == nil, !activity.isEmpty {
            out.events = activity.sorted { $0.key < $1.key }.map {
                FlywheelReadCommands.RawEvent(agent: $0.key, kind: "activity", at: $0.value)
            }
        }
        out.declaredBlocked = blocked
        return out
    }
}
```

In `SessionStore.swift`'s `observeService` lazy initializer, before `return service`:

```swift
        service.enrich = { [weak self] key, snapshot in
            guard let self, let swarm = self.swarmServiceStorage else { return snapshot }
            // A busy agent is active now, whatever its last transition said: a long turn makes
            // no transitions, and must not read as stalled.
            var activity: [String: Date] = [:]
            for (session, name) in self.flywheelAgents(inProject: key) {
                activity[name] = self.isAgentIdle(session) ? (self.lastActiveAt(for: session) ?? .distantPast) : self.now()
            }
            return ObserveEnrichment.enrich(snapshot, contests: swarm.contests(project: key), activity: activity,
                                            blocked: swarm.declaredBlocked(project: key))
        }
```

and in the `swarmService` builder (and `useSwarmService`), after `service.dependencies = …`:

```swift
        service.reservationsLookup = { [weak self] key in
            (self?.observeService.projection(forProject: key)?.reservations ?? []).map {
                HeldReservation(pattern: $0.file, holder: $0.holder, since: $0.since == .distantPast ? nil : $0.since)
            }
        }
```

- [ ] **Step 5: Run every Observe suite and the new tests**

Run: `FD_TEST_FILTER=ObserveEnrichmentTests,FlywheelNotifierLightUpTests,FlywheelNotifierTests,FlywheelWatcherTests,FlywheelProjectionTests,FlywheelObserveServiceTests,ObserveServiceWiringTests,ObserveDrawerModelTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. A `FlywheelProjectionTests`/`ObserveServiceWiringTests` case that counted
exactly two reads or asserted `reservations`/`depEdges` lanes unavailable now sees them read:
update that expectation to the four-lane reality and name the change in the commit body (never
loosen an assertion that is about something else).

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/ObserveEnrichment.swift Sources/FlightDeck/Flywheel/Observe/FlywheelWatcher.swift Sources/FlightDeck/Flywheel/Observe/FlywheelProjection.swift Sources/FlightDeck/Flywheel/Observe/FlywheelObserveService.swift Sources/FlightDeck/Flywheel/Observe/FlywheelNotifier.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/Flywheel/Observe/FlywheelWatcherTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/ObserveEnrichmentTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/FlywheelNotifierLightUpTests.swift
git commit -m "feat: light up Observe's reservation and dependency lanes and its notifications" -m "The watcher now reads reservations and br graph edges on every repoll. Before projecting, the swarm adds waiters from guard blocks, each tab's last activity in place of the still-stubbed events lane, and BLOCKED: declarations. With that data the dormant notifier triggers fire: a stalled holder of a contested file, a persistent declared block, and a dependency cycle, routed to the agent that holds the cycle's task." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 12a: The swarm projection and swarm commands on the fleet wire (atomic)

**Files:**
- Create: `Sources/FleetKit/SwarmWireTypes.swift`
- Create: `Sources/FlightDeck/FlightControl/Swarm/SwarmWire.swift`
- Modify (FleetKit): `Wire.swift` (`WireProject.swarm`), `FleetEvent.swift` (`.projectSwarm` + `sessionID`/`projectID` arms),
  `WireCoding.swift` (tag, key, both arms), `FleetReplay.swift` (fold key), `SnapshotApplication.swift` (arm),
  `PhoneLogs.swift` (`FleetCapability.swarm`), `Frames.swift` (four `FleetCommand` cases, `Op`, both arms)
- Modify (app): `Fleet/FleetService.swift` (`requiredCapability`, four `apply` arms, `startSwarmSummaries()` call),
  `Fleet/ControlScope.swift` (arms), `Fleet/FleetProjection.swift` (`swarm:`), `SessionStore.swift` (`swarmSummaries`,
  `refreshSwarmSummaries`, `startSwarmSummaries`, `scheduleSwarmRefresh`, `onChange` hook)
- Modify (CLI): `Sources/FlightDeckCLI/CLIOutput.swift` (`eventSession` arm)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmWireTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmWireEmissionTests.swift`

**Interfaces:**
- Produces (FleetKit, `public`):
  - `struct WireSwarm: Codable, Equatable, Sendable { state; summary; banner: String?; agents: [WireSwarmAgent]; meters: [WireSwarmMeter]; waiting: Int }`
  - `struct WireSwarmAgent: Codable, Equatable, Hashable, Sendable, Identifiable { session; task: String?; kind; model; accountName: String?; state; marker: String?; contested: Bool; handoffPending: Bool }`
  - `struct WireSwarmMeter: Codable, Equatable, Hashable, Sendable { pool; accountName; utilization: Double?; state }`
  - `WireProject.swarm: WireSwarm?` (init param `swarm: WireSwarm? = nil`, last)
  - `FleetEvent.projectSwarm(project: UUID, swarm: WireSwarm?)` — tag `project.swarm`, requires `FleetCapability.swarm`
  - `FleetCommand.swarmPause(project:)` `"swarm.pause"`, `.swarmResume(project:)` `"swarm.resume"`, `.handoffConfirm(id:)` `"handoff.confirm"`, `.handoffDecline(id:)` `"handoff.decline"`
  - `FleetCapability.swarm = "swarm"` (in `supported`)
- Produces (app): `enum SwarmWireProjection { static func wire(_:service:now:) -> WireSwarm?; static func changes(from:to:) -> [FleetEvent] }`;
  `SessionStore.swarmSummaries`, `refreshSwarmSummaries()`, `startSwarmSummaries()`; error codes `no_swarm`, `no_handoff`.

Every piece below lands in ONE commit: each switch over `FleetEvent`/`FleetCommand` is exhaustive,
and a build with the case but not its handler does not compile.

- [ ] **Step 1: List every exhaustive switch site**

Run: `rg -n "case \.projectIntakes|case \.intakeRemoveNote|\.projectIntakes:" Sources | rg -v "^Sources/FlightDeckMobile/PlanReaderScreen"`
Expected sites: `FleetKit/FleetEvent.swift` (2), `FleetKit/WireCoding.swift` (2), `FleetKit/FleetReplay.swift`,
`FleetKit/SnapshotApplication.swift`, `FleetKit/Frames.swift` (encode + decode), `FlightDeck/Fleet/FleetService.swift`
(`requiredCapability`, `apply`), `FlightDeck/Fleet/ControlScope.swift`, `FlightDeckCLI/CLIOutput.swift`,
`FlightDeckMobile/FleetModel.swift` (has a `default:` — no arm needed). Any additional site in the
output also gets an arm in this task.

- [ ] **Step 2: Write the failing wire tests**

```swift
import XCTest
import FleetKit
@testable import FlightDeck

/// The swarm's phone surface (spec §8): one projection per project and four commands, each with
/// a fixed wire spelling, and an older Mac's snapshot (no `swarm` key) still decodes.
final class SwarmWireTests: XCTestCase {
    private let swarm = WireSwarm(state: "running", summary: "swarm 2/3 · 1 waiting", banner: nil,
                                  agents: [WireSwarmAgent(session: UUID(), task: "fx-1", kind: "tests", model: "opus",
                                                          accountName: "Work", state: "working", marker: nil,
                                                          contested: true, handoffPending: false)],
                                  meters: [WireSwarmMeter(pool: "claude-subs", accountName: "Work", utilization: 0.4, state: "underSoft")],
                                  waiting: 1)

    func testTheProjectionEventRoundTrips() throws {
        let project = UUID()
        let data = try JSONEncoder().encode(FleetEvent.projectSwarm(project: project, swarm: swarm))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["t"] as? String, "project.swarm")
        XCTAssertEqual(try JSONDecoder().decode(FleetEvent.self, from: data), .projectSwarm(project: project, swarm: swarm))
        let cleared = try JSONEncoder().encode(FleetEvent.projectSwarm(project: project, swarm: nil))
        XCTAssertNil((try JSONSerialization.jsonObject(with: cleared) as? [String: Any])?["swarm"], "nil is absent, not null")
    }

    func testAnOlderMacsProjectDecodesWithoutASwarm() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"p","path":"/p","isCollapsed":false,"sessions":[]}"#
        XCTAssertNil(try JSONDecoder().decode(WireProject.self, from: Data(json.utf8)).swarm)
    }

    func testTheCommandsHaveTheirWireSpellings() throws {
        let project = UUID(), session = UUID()
        let cases: [(FleetCommand, String)] = [(.swarmPause(project: project), "swarm.pause"),
                                               (.swarmResume(project: project), "swarm.resume"),
                                               (.handoffConfirm(id: session), "handoff.confirm"),
                                               (.handoffDecline(id: session), "handoff.decline")]
        for (command, op) in cases {
            let data = try JSONEncoder().encode(command)
            XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["op"] as? String, op)
            XCTAssertEqual(try JSONDecoder().decode(FleetCommand.self, from: data), command)
        }
    }

    func testTheSnapshotFoldsTheEvent() {
        let project = UUID()
        var fleet = FleetSnapshot(projects: [WireProject(id: project, name: "p", path: "/p")])
        fleet.apply(.projectSwarm(project: project, swarm: swarm))
        XCTAssertEqual(fleet.projects[0].swarm, swarm)
        fleet.apply(.projectSwarm(project: project, swarm: nil))
        XCTAssertNil(fleet.projects[0].swarm)
    }

    @MainActor
    func testOnlyAPeerThatClaimsSwarmIsSentTheEvent() {
        XCTAssertEqual(FleetService.requiredCapability(for: .projectSwarm(project: UUID(), swarm: nil)), FleetCapability.swarm)
        XCTAssertTrue(FleetCapability.supported.contains("swarm"))
    }

    @MainActor
    func testAScopedAgentCannotSteerTheSwarm() {
        let me = UUID()
        XCTAssertFalse(ControlScope.permits(.swarmPause(project: UUID()), level: .ownSession, caller: .session(me)))
        XCTAssertFalse(ControlScope.permits(.handoffConfirm(id: me), level: .ownSession, caller: .session(me)))
        XCTAssertTrue(ControlScope.permits(.swarmResume(project: UUID()), level: .full, caller: .session(me)))
    }
}
```

- [ ] **Step 3: Write the failing emission tests**

```swift
import XCTest
import FleetKit
import IntakeKit
@testable import FlightDeck

/// The swarm projection is fleet state, so it goes through the replicator's drift check like
/// every other field — and it is the only place an account's display name reaches the wire.
@MainActor
final class SwarmWireEmissionTests: XCTestCase {
    private func setUp(_ rig: SwarmRig) -> (SessionStore, SwarmService, UUID) {
        let store = SessionStore(provider: nil, persistence: nil)
        let session = store.newSession(in: URL(fileURLWithPath: SwarmFixtures.project, isDirectory: true))
        let repo = store.repos.first { $0.sessions.contains { $0.id == session.id } }!.id
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
        service.dependencies = SwarmDependencies(router: rig.router, kinds: rig.kinds, allocator: rig.allocator, capacity: rig.capacity)
        store.useSwarmService(service)
        return (store, service, repo)
    }

    func testLaunchingASwarmIsAnEventAndLeavesNoDrift() async {
        let rig = SwarmRig(); rig.leases("codex-subs", 1)
        rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block()), SwarmFixtures.task("fx-2", SwarmFixtures.block("other"))]
        let (store, service, repo) = setUp(rig)
        let replicator = attachedReplicator(to: store)
        store.startSwarmSummaries()
        _ = service.launch(project: SwarmFixtures.project, cap: 2, poolCaps: [:], filter: .allReady)
        await service.settle()
        store.refreshSwarmSummaries()
        XCTAssertTrue(replicator.recorded.contains {
            if case .projectSwarm(repo, let swarm?) = $0 { return swarm.agents.count == 1 && swarm.waiting == 1 }
            return false
        })
        XCTAssertEqual(replicator.snapshot().fleet, FleetProjection.snapshot(of: store))
    }

    func testTheAccountNameTravelsButNeverItsID() async throws {
        let rig = SwarmRig()
        let accountID = UUID()
        let lease = AccountLease(pool: "codex-subs", account: AccountRef(harness: "codex", id: accountID, label: "Work Account"))
        let agent = rig.agent("BlueLake", lease: lease, state: .working, task: "fx-1")
        rig.store.save([rig.record(state: .paused, agents: [agent])])
        let (store, _, _) = setUp(rig)
        store.startSwarmSummaries()
        let encoded = String(decoding: try JSONEncoder().encode(FleetProjection.snapshot(of: store)), as: UTF8.self)
        XCTAssertTrue(encoded.contains("Work Account"))
        XCTAssertFalse(encoded.contains(accountID.uuidString), "an account id resolves to a home and may not travel")
    }

    func testPauseResumeAndHandoffOverTheLocalSocket() async throws {
        let rig = SwarmRig(); rig.backend.ready = [SwarmFixtures.task("fx-1", SwarmFixtures.block())]
        let (store, service, repo) = setUp(rig)
        _ = service.launch(project: SwarmFixtures.project, cap: 1, poolCaps: [:], filter: .allReady)
        await service.settle()
        let harness = FleetTestHarness(store: store)
        let path = "/tmp/fdsw-\(UUID().uuidString.prefix(8)).sock"
        try await harness.service.startLocal(at: URL(fileURLWithPath: path))
        defer { harness.service.stop() }
        let client = FleetClient(localCaller: nil)
        defer { client.disconnect() }
        var replies: [Int: ServerFrame] = [:]
        let ready = expectation(description: "snapshot")
        let three = expectation(description: "three replies"); three.expectedFulfillmentCount = 3
        client.onFrame = { frame in
            if case .snapshot = frame { ready.fulfill() }
            if let cid = frame.correlationID { replies[cid] = frame; three.fulfill() }
        }
        client.connect(toLocal: path, lastSeq: 0)
        await fulfillment(of: [ready], timeout: 5)
        let pause = client.send(FleetCommand.swarmPause(project: repo))
        let unknown = client.send(FleetCommand.swarmResume(project: UUID()))
        let handoff = client.send(FleetCommand.handoffConfirm(id: UUID()))
        await fulfillment(of: [three], timeout: 5)
        XCTAssertEqual(replies[pause], .ack(cid: pause))
        XCTAssertEqual(service.record(forProject: SwarmFixtures.project)?.state, .paused)
        XCTAssertEqual(replies[unknown], .err(cid: unknown, code: "unknown_project"))
        XCTAssertEqual(replies[handoff], .err(cid: handoff, code: "no_handoff"))
    }
}
```

- [ ] **Step 4: Run to verify they fail**

Run: `FD_TEST_FILTER=SwarmWireTests,SwarmWireEmissionTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'WireSwarm' in scope`.

- [ ] **Step 5: FleetKit — types, event, coding, fold, snapshot, capability**

`Sources/FleetKit/SwarmWireTypes.swift`:

```swift
import Foundation

/// One project's swarm as a client sees it (L3-S §8). This is the only place an account's
/// display name travels on the fleet wire — never its id, never its home, which is what keeps
/// `FleetAccountEmissionTests` true for everything else.
public struct WireSwarm: Codable, Equatable, Sendable {
    public var state: String
    public var summary: String
    public var banner: String?
    public var agents: [WireSwarmAgent]
    public var meters: [WireSwarmMeter]
    public var waiting: Int
    public init(state: String, summary: String, banner: String?, agents: [WireSwarmAgent], meters: [WireSwarmMeter], waiting: Int) {
        self.state = state; self.summary = summary; self.banner = banner; self.agents = agents
        self.meters = meters; self.waiting = waiting
    }
}

public struct WireSwarmAgent: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var session: UUID
    public var task: String?
    public var kind: String
    public var model: String
    public var accountName: String?
    public var state: String
    public var marker: String?
    public var contested: Bool
    public var handoffPending: Bool
    public var id: UUID { session }
    public init(session: UUID, task: String?, kind: String, model: String, accountName: String?, state: String,
                marker: String?, contested: Bool, handoffPending: Bool) {
        self.session = session; self.task = task; self.kind = kind; self.model = model; self.accountName = accountName
        self.state = state; self.marker = marker; self.contested = contested; self.handoffPending = handoffPending
    }
}

public struct WireSwarmMeter: Codable, Equatable, Hashable, Sendable {
    public var pool: String
    public var accountName: String
    public var utilization: Double?
    public var state: String
    public init(pool: String, accountName: String, utilization: Double?, state: String) {
        self.pool = pool; self.accountName = accountName; self.utilization = utilization; self.state = state
    }
}
```

`Wire.swift` — in `WireProject`, after `intakes`:

```swift
    /// This project's swarm (L3-S §8), or nil when it has none. Optional so a snapshot from a Mac
    /// that predates it decodes.
    public var swarm: WireSwarm?
```

add `swarm: WireSwarm? = nil` as the last init parameter and `self.swarm = swarm` in its body.

`FleetEvent.swift` — after `projectIntakes`:

```swift
    /// One project's swarm, replacing the previous one (nil: no swarm, or it stopped). Sent only
    /// to peers that advertise `FleetCapability.swarm`, for the reason `projectIntakes` gives.
    case projectSwarm(project: UUID, swarm: WireSwarm?)
```

and add `.projectSwarm` to the `return nil` list in `sessionID`, and `.projectSwarm(let id, _)` to
the project-id list in `projectID`.

`WireCoding.swift` — `case projectSwarm = "project.swarm"` in `FleetEventTag`; `swarm` in
`CodingKeys`; encode arm:

```swift
        case .projectSwarm(let project, let swarm):
            try c.encode(FleetEventTag.projectSwarm, forKey: .t)
            try c.encode(project, forKey: .project)
            // Absent, not `null`, for nil — the `projectIntakes` rule.
            try c.encodeIfPresent(swarm, forKey: .swarm)
```

decode arm:

```swift
        case .projectSwarm:
            self = .projectSwarm(project: try c.decode(UUID.self, forKey: .project),
                                 swarm: try c.decodeIfPresent(WireSwarm.self, forKey: .swarm))
```

`FleetReplay.swift` — add `swarm(UUID)` to `FoldKey` and, in `key(_:)`:

```swift
        // Same rationale as `.intakes`: only the last swarm summary inside a resume gap is real.
        case .projectSwarm(let id, _): return .swarm(id)
```

`SnapshotApplication.swift`:

```swift
        case .projectSwarm(let id, let swarm):
            guard let p = projects.firstIndex(where: { $0.id == id }) else { return }
            projects[p].swarm = swarm
```

`PhoneLogs.swift` — in `FleetCapability`:

```swift
    /// This peer decodes the `project.swarm` event (L3-S). Withheld from peers without it.
    public static let swarm = "swarm"
```

and `public static let supported = [logs, flightControl, swarm]`.

- [ ] **Step 6: FleetKit — the four commands**

In `Frames.swift`'s `FleetCommand`, after `intakeRemoveNote`:

```swift
    /// Pause or resume project `project`'s swarm (L3-S §8). Idempotent by state, so no token.
    /// Sent only for a project whose snapshot carries `swarm`, which an older Mac never sends —
    /// an unknown `op` would end the socket.
    case swarmPause(project: UUID)
    case swarmResume(project: UUID)
    /// Confirm or decline a pending hand-off on session `id` (L3-U's driver decides; L3-S routes).
    case handoffConfirm(id: UUID)
    case handoffDecline(id: UUID)
```

`Op`: `case swarmPause = "swarm.pause"`, `case swarmResume = "swarm.resume"`,
`case handoffConfirm = "handoff.confirm"`, `case handoffDecline = "handoff.decline"`.
Encode arms:

```swift
        case .swarmPause(let project):
            try c.encode(Op.swarmPause, forKey: .op); try c.encode(project, forKey: .project)
        case .swarmResume(let project):
            try c.encode(Op.swarmResume, forKey: .op); try c.encode(project, forKey: .project)
        case .handoffConfirm(let id):
            try c.encode(Op.handoffConfirm, forKey: .op); try c.encode(id, forKey: .id)
        case .handoffDecline(let id):
            try c.encode(Op.handoffDecline, forKey: .op); try c.encode(id, forKey: .id)
```

Decode arms:

```swift
        case .swarmPause: self = .swarmPause(project: try c.decode(UUID.self, forKey: .project))
        case .swarmResume: self = .swarmResume(project: try c.decode(UUID.self, forKey: .project))
        case .handoffConfirm: self = .handoffConfirm(id: try c.decode(UUID.self, forKey: .id))
        case .handoffDecline: self = .handoffDecline(id: try c.decode(UUID.self, forKey: .id))
```

- [ ] **Step 7: The app — projection, emission, handlers, scope, CLI**

`SwarmWire.swift`:

```swift
import FleetKit
import Foundation
import IntakeKit

/// Builds the phone's view of one swarm and the events that keep it current. Read only from the
/// store's `swarmSummaries` cache by `FleetProjection`, so the replicator's drift oracle sees
/// exactly what was last recorded.
enum SwarmWireProjection {
    @MainActor
    static func wire(_ record: SwarmRecord, service: SwarmService, now: Date = Date()) -> WireSwarm? {
        guard record.state != .stopped, let summary = service.summary(forProject: record.project) else { return nil }
        let pending = service.handoffDecisions?.pendingHandoffs ?? []
        let agents = record.agents.filter { $0.state != .done }.map { agent in
            WireSwarmAgent(session: agent.session, task: agent.task ?? agent.lastTask,
                           kind: agent.block.block.kind.rawValue, model: agent.block.block.model,
                           accountName: agent.lease?.account.label, state: agent.state.rawValue,
                           marker: service.annotation(for: agent.session, now: now)?.marker,
                           contested: service.isContested(agent.session),
                           handoffPending: pending.contains(agent.session))
        }
        let meters = service.meters(forProject: record.project).map {
            WireSwarmMeter(pool: $0.pool, accountName: $0.label, utilization: $0.value, state: $0.state.rawValue)
        }
        return WireSwarm(state: record.state.rawValue, summary: summary.text, banner: record.banner,
                         agents: agents, meters: meters, waiting: record.waiting.count)
    }

    /// One `projectSwarm` per project whose summary changed, sorted by uuid string for tests —
    /// the same contract `IntakeSummaryProjection.changes` keeps.
    static func changes(from old: [UUID: WireSwarm?], to new: [UUID: WireSwarm?]) -> [FleetEvent] {
        new.keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let next = new[id] ?? nil
            return next == (old[id] ?? nil) ? nil : .projectSwarm(project: id, swarm: next)
        }
    }
}
```

`SessionStore.swift` — next to `intakeSummaries`:

```swift
    /// The swarm summaries last RECORDED on the fleet wire, per project — the `intakeSummaries`
    /// rule: `FleetProjection` reads this cache, never the service, so a swarm change that reached
    /// the projection without an event cannot exist.
    private(set) var swarmSummaries: [Repo.ID: WireSwarm?] = [:]
    private var swarmSummariesStarted = false
    private var swarmRefreshScheduled = false

    func refreshSwarmSummaries() {
        var next: [Repo.ID: WireSwarm?] = [:]
        for repo in repos {
            next[repo.id] = swarmServiceStorage.flatMap { service in
                service.record(forProject: repo.url.path).flatMap { SwarmWireProjection.wire($0, service: service) }
            }
        }
        let events = SwarmWireProjection.changes(from: swarmSummaries, to: next)
        swarmSummaries = next
        emit(events)
    }

    /// Called by `FleetService` after it installs the replicator, beside `startIntakeSummaries`.
    func startSwarmSummaries() {
        swarmSummariesStarted = true
        refreshSwarmSummaries()
    }

    /// Coalesces a burst of swarm changes into one refresh on the next main-queue turn.
    private func scheduleSwarmRefresh() {
        guard swarmSummariesStarted, !swarmRefreshScheduled else { return }
        swarmRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.swarmRefreshScheduled = false
            self?.refreshSwarmSummaries()
        }
    }
```

In both the `swarmService` builder and `useSwarmService(_:)`, add
`service.onChange = { [weak self] in self?.scheduleSwarmRefresh() }`.

`FleetProjection.swift` — add `swarm: store.swarmSummaries[$0.id] ?? nil` to the `project(...)` call
in `snapshot(of:)`, a `swarm: WireSwarm? = nil` parameter (last) to `project(_ repo:…)`, and
`swarm: swarm` to its `WireProject(...)`.

`FleetService.swift`:
- `requiredCapability(for:)`: add `if case .projectSwarm = event { return FleetCapability.swarm }`.
- where `store.startIntakeSummaries()` is called (`FleetService.swift:184`), add `store.startSwarmSummaries()` on the next line.
- `apply`, after the `intakeRemoveNote` arm:

```swift
        case .swarmPause(let project):
            guard let path = store.projectPath(project) else { return .err(cid: cid, code: "unknown_project") }
            guard store.swarmServiceIfBuilt?.pause(project: path) == true else { return .err(cid: cid, code: "no_swarm") }
        case .swarmResume(let project):
            guard let path = store.projectPath(project) else { return .err(cid: cid, code: "unknown_project") }
            guard store.swarmServiceIfBuilt?.resume(project: path) == true else { return .err(cid: cid, code: "no_swarm") }
        case .handoffConfirm(let id):
            guard store.swarmServiceIfBuilt?.confirmHandoff(session: id) == true else { return .err(cid: cid, code: "no_handoff") }
        case .handoffDecline(let id):
            guard store.swarmServiceIfBuilt?.declineHandoff(session: id) == true else { return .err(cid: cid, code: "no_handoff") }
```

`ControlScope.swift` — in `permits(_ command:…)`'s switch:

```swift
        case .swarmPause, .swarmResume, .handoffConfirm, .handoffDecline:
            // A swarm and its hand-offs are a project's, not the asking session's.
            return false
```

`CLIOutput.swift` — add `.projectSwarm` to `eventSession`'s `return nil` list.

- [ ] **Step 8: Run the wire tests, the fleet suites, the account test, then iOS**

Run: `FD_TEST_FILTER=SwarmWireTests,SwarmWireEmissionTests,FleetAccountEmissionTests,FleetWireTests,FleetServiceTests,FleetLocalControlTests,ControlScopeTests,CLIOutputTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures (drop any class name `test-unit.sh` reports as unknown, after checking with
`rg -ln "class <Name>" Tests`). Then:
`./scripts/build-ios.sh 2>&1 | tail -5` → succeeds; `./scripts/test-ios.sh 2>&1 | tail -15` → `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Sources/FleetKit/SwarmWireTypes.swift Sources/FleetKit/Wire.swift Sources/FleetKit/FleetEvent.swift Sources/FleetKit/WireCoding.swift Sources/FleetKit/FleetReplay.swift Sources/FleetKit/SnapshotApplication.swift Sources/FleetKit/PhoneLogs.swift Sources/FleetKit/Frames.swift Sources/FlightDeck/FlightControl/Swarm/SwarmWire.swift Sources/FlightDeck/Fleet/FleetService.swift Sources/FlightDeck/Fleet/ControlScope.swift Sources/FlightDeck/Fleet/FleetProjection.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeckCLI/CLIOutput.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmWireTests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/SwarmWireEmissionTests.swift
git commit -m "feat: put each project's swarm on the fleet wire with pause, resume and hand-off commands" -m "A project.swarm event carries the swarm summary, each agent's task, kind, model, account display name, state and contested flag, and the pool meters — the one place an account name travels, never its id or home. It is cached and emitted like intake summaries, so the replicator's drift check covers it, and is sent only to peers that claim the swarm capability. swarm.pause, swarm.resume, handoff.confirm and handoff.decline land with every handler arm in this one commit." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12b: The phone — row chips and the project swarm card

**Files:**
- Create: `Sources/FlightDeckMobile/SwarmStyle.swift`
- Create: `Sources/FlightDeckMobile/SwarmCard.swift`
- Modify: `Sources/FlightDeckMobile/FleetListScreen.swift` (card in each project section, chips on rows)
- Modify: `Sources/FlightDeckMobile/FleetModel.swift` (`setSwarmPaused`, `decideHandoff`, `swarmInFlight`)
- Modify: `Sources/FlightDeckMobile/UITestHarness.swift` (`swarmCard` harness)
- Test: `Tests/FlightDeckMobileTests/SwarmStyleTests.swift`
- Test: `Tests/FlightDeckMobileUITests/SwarmCardUITests.swift`

**Interfaces:**
- Consumes: `WireSwarm`, `WireSwarmAgent`, `WireSwarmMeter`, `FleetCommand.swarmPause/swarmResume/handoffConfirm/handoffDecline` (Task 12a).
- Produces: `enum SwarmStyle { agent(for:in:); chip(_:); detail(_:); cardTitle(_:); canPause(_:); canResume(_:); meterText(_:) }`;
  `struct SwarmCard: View` (ids `swarm-card`, `swarm-card-title`, `swarm-card-pause`, `swarm-card-resume`, `swarm-card-meter`);
  `FleetModel.setSwarmPaused(_:project:)`, `decideHandoff(_:session:)`, `swarmInFlight: Set<UUID>`;
  `UITestHarness.swarmCard = "swarmCard"`.

Every new phone file is flat in `Sources/FlightDeckMobile/` (`build-ios.sh` type-checks `*.swift` only).

- [ ] **Step 1: Write the failing style tests**

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

/// The phone draws a swarm agent's chips on its existing row and a card per project (spec §8);
/// every string the views show comes from here.
final class SwarmStyleTests: XCTestCase {
    private let session = UUID()
    private var swarm: WireSwarm {
        WireSwarm(state: "paused", summary: "swarm paused · 1/3", banner: "Swarm paused after restart · Resume",
                  agents: [WireSwarmAgent(session: session, task: "fx-1", kind: "tests", model: "opus", accountName: "Work",
                                          state: "working", marker: nil, contested: true, handoffPending: false)],
                  meters: [WireSwarmMeter(pool: "claude-subs", accountName: "Work", utilization: 0.835, state: "overSoft"),
                           WireSwarmMeter(pool: "local", accountName: "slot 1", utilization: nil, state: "unknown")],
                  waiting: 0)
    }

    func testAProjectionFrameDecodesAndFolds() throws {
        let project = UUID()
        let frame = try JSONEncoder().encode(ServerFrame.event(seq: 4, .projectSwarm(project: project, swarm: swarm)))
        guard case .event(_, let event) = try JSONDecoder().decode(ServerFrame.self, from: frame) else { return XCTFail() }
        var fleet = FleetSnapshot(projects: [WireProject(id: project, name: "p", path: "/p")])
        fleet.apply(event)
        XCTAssertEqual(SwarmStyle.agent(for: session, in: fleet.projects[0])?.task, "fx-1")
        XCTAssertNil(SwarmStyle.agent(for: UUID(), in: fleet.projects[0]))
    }

    func testChipsAndCard() throws {
        let agent = try XCTUnwrap(swarm.agents.first)
        XCTAssertEqual(SwarmStyle.chip(agent), "fx-1 · tests")
        XCTAssertEqual(SwarmStyle.detail(agent), "opus · Work")
        XCTAssertEqual(SwarmStyle.cardTitle(swarm), "Swarm paused after restart · Resume")
        XCTAssertTrue(SwarmStyle.canResume(swarm))
        XCTAssertFalse(SwarmStyle.canPause(swarm))
        XCTAssertEqual(swarm.meters.map(SwarmStyle.meterText), ["claude-subs · Work · 84%", "local · slot 1 · no reading"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-ios.sh 2>&1 | tail -30`
Expected: a build failure naming `SwarmStyle`.

- [ ] **Step 3: Implement `SwarmStyle.swift` and `SwarmCard.swift`**

```swift
import FleetKit
import SwiftUI

/// Every string the phone's swarm views show. Pure, so the decode and the copy are tested
/// without a simulator screen.
enum SwarmStyle {
    static func agent(for session: UUID, in project: WireProject) -> WireSwarmAgent? {
        project.swarm?.agents.first { $0.session == session }
    }
    static func chip(_ agent: WireSwarmAgent) -> String? { agent.task.map { "\($0) · \(agent.kind)" } }
    static func detail(_ agent: WireSwarmAgent) -> String { [agent.model, agent.accountName].compactMap { $0 }.joined(separator: " · ") }
    static func cardTitle(_ swarm: WireSwarm) -> String { swarm.banner ?? swarm.summary }
    static func canPause(_ swarm: WireSwarm) -> Bool { swarm.state == "running" || swarm.state == "draining" }
    static func canResume(_ swarm: WireSwarm) -> Bool { swarm.state == "paused" || swarm.state == "draining" }
    static func meterText(_ meter: WireSwarmMeter) -> String {
        "\(meter.pool) · \(meter.accountName) · " + (meter.utilization.map { "\(Int(($0 * 100).rounded()))%" } ?? "no reading")
    }
}
```

```swift
import FleetKit
import SwiftUI

/// A project's swarm on the phone: the summary (or banner), the pool meters, and Pause/Resume.
/// Launch and rule editing stay on the Mac (spec §8).
struct SwarmCard: View {
    let swarm: WireSwarm
    let inFlight: Bool
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SwarmStyle.cardTitle(swarm))
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("swarm-card-title")
            ForEach(swarm.meters, id: \.self) { meter in
                Text(SwarmStyle.meterText(meter))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(meter.state == "overSoft" || meter.state == "overHard" ? .orange : .secondary)
                    .accessibilityIdentifier("swarm-card-meter")
            }
            HStack {
                if SwarmStyle.canPause(swarm) {
                    Button("Pause", action: onPause).accessibilityIdentifier("swarm-card-pause")
                }
                if SwarmStyle.canResume(swarm) {
                    Button("Resume", action: onResume).accessibilityIdentifier("swarm-card-resume")
                }
            }
            .buttonStyle(.bordered)
            .disabled(inFlight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("swarm-card")
    }
}
```

- [ ] **Step 4: Mount it and add the commands**

`FleetModel.swift` — beside `sendIntake`:

```swift
    /// Projects with a pause/resume on the way, so the card cannot send a second one before the
    /// Mac answers the first.
    private(set) var swarmInFlight: Set<UUID> = []

    func setSwarmPaused(_ paused: Bool, project: UUID) {
        guard !swarmInFlight.contains(project) else { return }
        swarmInFlight.insert(project)
        sendIntake(paused ? .swarmPause(project: project) : .swarmResume(project: project)) { [weak self] _ in
            self?.swarmInFlight.remove(project)
        }
    }

    func decideHandoff(_ confirm: Bool, session: UUID) {
        sendIntake(confirm ? .handoffConfirm(id: session) : .handoffDecline(id: session)) { _ in }
    }
```

`FleetListScreen.swift`:
- inside each project `Section`, before `ForEach(Self.intakeRows(project))`:

```swift
                            if let swarm = project.swarm {
                                SwarmCard(swarm: swarm, inFlight: model.swarmInFlight.contains(project.id),
                                          onPause: { model.setSwarmPaused(true, project: project.id) },
                                          onResume: { model.setSwarmPaused(false, project: project.id) })
                                    .listRowInsets(Self.rowInsets)
                            }
```

- change `sessionRow(session)` (`:82`) to `sessionRow(session, swarm: SwarmStyle.agent(for: session.id, in: project))`;
  change `private func sessionRow(_ session: WireSession)` to take `swarm: WireSwarmAgent? = nil` and
  call `Self.row(session, swarm: swarm)`;
- change `static func row(_ session: WireSession, highlighted ranges: [Range<String.Index>] = [])` to
  `static func row(_ session: WireSession, swarm: WireSwarmAgent? = nil, highlighted ranges: [Range<String.Index>] = [])`
  (existing callers pass `highlighted:` by label, so they compile), and inside its title `VStack`,
  after the waiting caption:

```swift
                if let swarm, let chip = SwarmStyle.chip(swarm) {
                    HStack(spacing: 4) {
                        Text(chip).font(.caption2.monospaced())
                        if swarm.contested {
                            Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                                .accessibilityLabel("contested")
                        }
                        if let marker = swarm.marker { Text(marker).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .accessibilityIdentifier("swarm-row-chip")
                }
```

`UITestHarness.swift` — add `static let swarmCard = "swarmCard"` and a `case swarmCard:` arm in
`view(for:)` that returns `SwarmCardHarness()`, defined in the same file:

```swift
/// The swarm card with fixture data and a local pause state — no fleet, no Mac — so the UI test
/// exercises the card's layout and its Pause/Resume swap in isolation.
private struct SwarmCardHarness: View {
    @State private var paused = false
    private var swarm: WireSwarm {
        WireSwarm(state: paused ? "paused" : "running", summary: paused ? "swarm paused · 2/3" : "swarm 2/3 · 1 waiting",
                  banner: nil, agents: [],
                  meters: [WireSwarmMeter(pool: "claude-subs", accountName: "Work", utilization: 0.62, state: "underSoft")],
                  waiting: 1)
    }
    var body: some View {
        List { SwarmCard(swarm: swarm, inFlight: false, onPause: { paused = true }, onResume: { paused = false }) }
    }
}
```

(`UITestHarness.swift` needs `import FleetKit` for `WireSwarm`; add it if it is not there.)

- [ ] **Step 5: Write the phone UI test**

```swift
import XCTest

/// The swarm card's Pause/Resume swap, on the simulator, with fixture data (spec §11 "Phone").
final class SwarmCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testPauseSwapsToResume() {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestHarness", "swarmCard"]
        app.launch()
        let title = app.staticTexts["swarm-card-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertEqual(title.label, "swarm 2/3 · 1 waiting")
        XCTAssertEqual(app.staticTexts["swarm-card-meter"].label, "claude-subs · Work · 62%")
        add(XCTAttachment(screenshot: app.screenshot()))
        app.buttons["swarm-card-pause"].tap()
        XCTAssertTrue(app.buttons["swarm-card-resume"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["swarm-card-title"].label, "swarm paused · 2/3")
        add(XCTAttachment(screenshot: app.screenshot()))
    }
}
```

- [ ] **Step 6: Run the phone suites**

Run: `./scripts/build-ios.sh 2>&1 | tail -5` → succeeds.
Run: `./scripts/test-ios.sh 2>&1 | tail -30` → `** TEST SUCCEEDED **`, with `SwarmStyleTests` and
`SwarmCardUITests` among the executed tests (`rg -n "SwarmStyleTests|SwarmCardUITests"` the log path
the script prints). Also `FD_TEST_FILTER=TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -5`
(the guard scans `Sources/FlightDeck` only; read the new phone strings by eye for "beads"/"seat"/"flywheel").

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeckMobile/SwarmStyle.swift Sources/FlightDeckMobile/SwarmCard.swift Sources/FlightDeckMobile/FleetListScreen.swift Sources/FlightDeckMobile/FleetModel.swift Sources/FlightDeckMobile/UITestHarness.swift Tests/FlightDeckMobileTests/SwarmStyleTests.swift Tests/FlightDeckMobileUITests/SwarmCardUITests.swift
git commit -m "feat: show swarm agents and pause or resume a swarm from the phone" -m "Each fleet row of a swarm agent shows its task chip, contested lock and marker; each project with a swarm gets a card with the summary or banner, the pool meters and Pause/Resume, sent as swarm.pause/swarm.resume and held disabled until the Mac answers. Launch and rule editing stay on the Mac." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 13: Turn Flight Control off, and remove it from a repo

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Swarm/FlightControlDisable.swift`
- Modify: `Sources/FlightDeck/FlightControl/Swarm/SwarmService.swift` (`turnOff(project:)`)
- Modify: `Sources/FlightDeck/Flywheel/FlywheelSetup.swift` (expose the hook body)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`turnOffFlightControl(project:)`, `removeFlightControl(from:)`)
- Modify: `Sources/FlightDeck/ProjectHeaderRow.swift` (two menu items, two confirmations)
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/FlightControlDisableTests.swift`

**Interfaces:**
- Consumes: `FlywheelObserveService.disable(project:)` (`FlywheelObserveService.swift:76`, unused until now),
  `FlywheelProjectProbe.status(of:)`, `FlywheelSetup`.
- Produces:
  - `SwarmService.turnOff(project:) async -> [String]` (task ids returned to open)
  - `@MainActor struct FlightControlOff { struct Report: Equatable { reopened; released }; func run(project:) async -> Report }`
  - `struct FlightControlRepoRemoval { static let agentsSectionStart; static let agentsSectionEnd: String?; static let guardUninstallArgs: [String]?; func plannedChanges(repo:) -> [String]; func remove(repo:) async -> [String] }`
  - `FlywheelSetup.beadsSyncHookContents: String` (static), `FlywheelSetup.beadsSyncHookPath(in:) -> URL` (static)
  - `SessionStore.turnOffFlightControl(project:) async -> FlightControlOff.Report`, `removeFlightControl(from:) async -> [String]`
  - Header menu: **Turn Off Flight Control…** (when enabled), **Remove Flight Control from Repo…** (when off and the guard or hook is installed)

- [ ] **Step 1: Probe what `br agents --add` writes and how to undo the guard** (scratch, under `$HOME`)

```bash
P=~/.fd-l3s-probe-agents && rm -rf "$P" && mkdir -p "$P" && cd "$P" && git init -q
printf '# Mine\n\nKeep this.\n' > AGENTS.md
br init --prefix probe >/dev/null && br agents --add --force >/dev/null; echo "agents exit $?"
cat AGENTS.md
br agents --help | rg -n -- "--remove|--uninstall|--delete"
am guard --help | rg -n -i "uninstall|remove"
cd "$OLDPWD" && rm -rf "$P"
```

Set the three constants in Step 4 from what this prints, exactly one choice each:
- `agentsSectionEnd`: the closing marker line printed after the section (for example
  `<!-- end-br-agent-instructions-v1 -->`) → that string. **No closing marker** (the section runs
  to end of file) → `nil`, and the remover strips from the start marker to end of file.
- **`br agents` lists a remove flag**: add `static let brAgentsRemoveArgs: [String]? = ["agents", "<that flag>"]`
  and have `remove(repo:)` run it instead of the string surgery (keep the surgery as the fallback
  when the command exits non-zero). Otherwise `nil`.
- `guardUninstallArgs`: `am guard uninstall` exists → `["guard", "uninstall"]` (the repo path is
  appended). It does not → `nil`, and `plannedChanges` says to remove the guard by hand.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §9. Turning Flight Control off stops FD acting on the repo and gives back what FD took;
/// it never edits the repo. Removing it from the repo is separate, shows what it will change, and
/// never touches `.beads`.
@MainActor
final class FlightControlDisableTests: XCTestCase {
    private var repo: URL!
    override func setUpWithError() throws {
        repo = FileManager.default.temporaryDirectory.appendingPathComponent("fc-off-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".beads"), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: repo.appendingPathComponent(".beads/beads.db"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: repo) }

    func testTurnOffStopsTheSwarmAndReturnsOnlyUnclosedClaims() async {
        let rig = SwarmRig()
        let a = rig.agent("BlueLake", state: .working, task: "fx-1")
        var c = rig.agent("RedStone", state: .starting); c.pendingClaim = "fx-3"
        rig.backend.statuses["fx-1"] = TaskStatusReading(status: "in_progress", assignee: "BlueLake")
        rig.backend.statuses["fx-3"] = TaskStatusReading(status: "closed", assignee: "RedStone")
        rig.store.save([rig.record(state: .paused, agents: [a, c])])
        let service = SwarmService(store: rig.store, backend: rig.backend, launcher: rig.launcher, spawner: nil,
                                   host: rig.host, registry: RoutingCapabilityRegistry([]), clock: nil, now: { rig.now })
        service.dependencies = SwarmDependencies(router: rig.router, kinds: rig.kinds, allocator: rig.allocator, capacity: rig.capacity)
        await service.settle()
        let reopened = await service.turnOff(project: SwarmFixtures.project)
        XCTAssertEqual(reopened, ["fx-1"])
        XCTAssertEqual(service.record(forProject: SwarmFixtures.project)?.state, .stopped)
    }

    func testOffReleasesEveryBootedAgentStopsWatchingAndClearsTheFlag() async {
        let rig = SwarmRig()
        var stopped: [String] = []
        var flag: [String: Bool] = [:]
        let off = FlightControlOff(swarm: nil, backend: rig.backend,
                                   agents: { _ in [(UUID(), "BlueLake"), (UUID(), "GreenFox")] },
                                   stopObserving: { stopped.append($0) },
                                   setEnabled: { flag[$0] = $1 })
        let report = await off.run(project: "/tmp/p/")
        XCTAssertEqual(report, FlightControlOff.Report(reopened: [], released: ["BlueLake", "GreenFox"]))
        XCTAssertEqual(rig.backend.released, ["BlueLake", "GreenFox"])
        XCTAssertEqual(stopped, ["/tmp/p"])
        XCTAssertEqual(flag, ["/tmp/p": false])
    }

    func testTheStoreTurnsTheProjectOff() async {
        let preferences = PreferencesStore(persistence: nil)
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences,
                                 flywheelObserveReads: FlywheelReadCommands(runner: MultiRunner()))
        var settings = preferences.projectSettings(repo.path); settings.flywheelEnabled = true
        preferences.setProjectSettings(repo.path, settings)
        _ = await store.turnOffFlightControl(project: repo.path)
        XCTAssertNotEqual(preferences.projectSettings(repo.path).flywheelEnabled, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".beads/beads.db").path),
                      "turning off never edits the repo")
    }

    func testRemovalListsAndRemovesOnlyWhatFlightDeckWrote() async throws {
        let hook = FlywheelSetup.beadsSyncHookPath(in: repo)
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FlywheelSetup.beadsSyncHookContents.write(to: hook, atomically: true, encoding: .utf8)
        let section = FlightControlRepoRemoval.agentsSectionStart + "\nUse br.\n"
            + (FlightControlRepoRemoval.agentsSectionEnd.map { $0 + "\n" } ?? "")
        try ("# Mine\n\nKeep this.\n\n" + section).write(to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let fake = MultiRunner(); fake.responses["am guard uninstall"] = ("", 0)
        let removal = FlightControlRepoRemoval(runner: fake)

        let planned = removal.plannedChanges(repo: repo)
        XCTAssertTrue(planned.contains("Delete the task-sync commit hook"))
        XCTAssertTrue(planned.contains("Remove the task-tracker section from AGENTS.md"))
        XCTAssertEqual(planned.last, "Keep the task data in the repo")

        _ = await removal.remove(repo: repo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hook.path))
        let agents = try String(contentsOf: repo.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        XCTAssertTrue(agents.contains("Keep this."))
        XCTAssertFalse(agents.contains(FlightControlRepoRemoval.agentsSectionStart))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(".beads/beads.db").path))
    }

    func testAHookSomeoneElseEditedIsLeftAlone() async throws {
        let hook = FlywheelSetup.beadsSyncHookPath(in: repo)
        try FileManager.default.createDirectory(at: hook.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho mine\n".write(to: hook, atomically: true, encoding: .utf8)
        let removal = FlightControlRepoRemoval(runner: MultiRunner())
        XCTAssertFalse(removal.plannedChanges(repo: repo).contains("Delete the task-sync commit hook"))
        _ = await removal.remove(repo: repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hook.path))
    }
}
```

`SessionStore(provider:persistence:preferences:flywheelObserveReads:)` uses the designated init's
labels (`SessionStore.swift:1973`); `MultiRunner` keeps it from spawning real `am`/`br`.

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=FlightControlDisableTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'FlightControlOff' in scope`.

- [ ] **Step 4: Implement**

`FlywheelSetup.swift` — expose the hook so removal can recognize exactly what enable wrote:

```swift
    /// The beads-sync hook `enable` installs, and its path — public to removal (L3-S), which
    /// deletes the file only when it still holds exactly this.
    static let beadsSyncHookContents = "#!/bin/sh\nbr sync --flush-only\ngit add -A .beads\n"
    static func beadsSyncHookPath(in repo: URL) -> URL {
        repo.appendingPathComponent(".git/hooks/hooks.d/pre-commit").appendingPathComponent("60-beads-sync.sh")
    }
```

and in `installBeadsSyncHook(repo:)` use them: `let hooksDDir = Self.beadsSyncHookPath(in: repo).deletingLastPathComponent()`,
`let scriptURL = Self.beadsSyncHookPath(in: repo)`, `let contents = Self.beadsSyncHookContents`.

`SwarmService.swift` — append:

```swift
extension SwarmService {
    /// Spec §9 steps 1–2: drain then stop the project's swarm, then return to open every task it
    /// claimed that is not closed. Returns those ids. Agents keep running in their tabs.
    func turnOff(project: String) async -> [String] {
        guard let controller = controller(forProject: project) else { return [] }
        let url = URL(fileURLWithPath: Self.key(project), isDirectory: true)
        let held = Set(controller.record.agents.flatMap { [$0.task, $0.pendingClaim].compactMap { $0 } })
        controller.drain()
        controller.stop(reason: "Flight Control turned off")
        var reopened: [String] = []
        for task in held.sorted() {
            if await backend.status(task, project: url)?.status == "closed" { continue }
            if await backend.returnToOpen(task, project: url) { reopened.append(task) }
        }
        controller.log(.released, detail: "returned to open: \(reopened.joined(separator: ", "))")
        return reopened
    }
}
```

`FlightControlDisable.swift`:

```swift
import Foundation
import IntakeKit

/// Spec §9 "Turn off Flight Control": FD stops acting on the repo and gives back what it took.
/// Hooks, AGENTS.md and `.beads` stay exactly as they are.
@MainActor
struct FlightControlOff {
    struct Report: Equatable {
        var reopened: [String]
        var released: [String]
    }

    let swarm: SwarmService?
    let backend: SwarmBackend
    /// Every FD-booted agent in the project (sessions with an Agent Mail identity).
    let agents: (String) -> [(session: UUID, agentName: String)]
    let stopObserving: (String) -> Void
    let setEnabled: (String, Bool) -> Void

    func run(project: String) async -> Report {
        let key = FlywheelObserveService.key(project)
        let reopened = await swarm?.turnOff(project: key) ?? []
        var released: [String] = []
        for (_, name) in agents(key) {
            if await backend.releaseReservations(agent: name, project: URL(fileURLWithPath: key, isDirectory: true)) {
                released.append(name)
            }
        }
        stopObserving(key)
        setEnabled(key, false)
        return Report(reopened: reopened, released: released)
    }
}

/// Spec §9 "Remove from repo…": undoes what Flight Control setup wrote, after a confirmation that
/// lists it. Never touches `.beads`.
struct FlightControlRepoRemoval {
    /// `br agents --add`'s fence (`FlywheelSetup.agentsSectionMarker`).
    static let agentsSectionStart = "<!-- br-agent-instructions-v1 -->"
    /// Set from Task 13 Step 1's probe. Nil means the section runs to the end of the file.
    static let agentsSectionEnd: String? = "<!-- end-br-agent-instructions-v1 -->"
    /// Set from Task 13 Step 1's probe. Nil means am has no uninstall, and the guard is left for
    /// the human (the confirmation says so).
    static let guardUninstallArgs: [String]? = ["guard", "uninstall"]

    let runner: FlywheelProcessRunner
    var amPath = "am"

    func plannedChanges(repo: URL) -> [String] {
        var lines: [String] = []
        if FlywheelProjectProbe.status(of: repo).guardInstalled {
            lines.append(Self.guardUninstallArgs == nil
                         ? "The Agent Mail commit guard stays: remove it by hand"
                         : "Uninstall the Agent Mail commit guard")
        }
        if hookIsOurs(repo) { lines.append("Delete the task-sync commit hook") }
        if agentsSectionRange(repo) != nil { lines.append("Remove the task-tracker section from AGENTS.md") }
        lines.append("Keep the task data in the repo")
        return lines
    }

    @discardableResult
    func remove(repo: URL) async -> [String] {
        var done: [String] = []
        if let args = Self.guardUninstallArgs, FlywheelProjectProbe.status(of: repo).guardInstalled,
           (try? await runner.run(amPath, args + [repo.path], cwd: repo.path))?.exitCode == 0 {
            done.append("guard")
        }
        if hookIsOurs(repo), (try? FileManager.default.removeItem(at: FlywheelSetup.beadsSyncHookPath(in: repo))) != nil {
            done.append("hook")
        }
        let agentsURL = repo.appendingPathComponent("AGENTS.md")
        if let range = agentsSectionRange(repo), var text = try? String(contentsOf: agentsURL, encoding: .utf8) {
            text.removeSubrange(range)
            while text.hasSuffix("\n\n") { text.removeLast() }
            if (try? text.write(to: agentsURL, atomically: true, encoding: .utf8)) != nil { done.append("agents") }
        }
        return done
    }

    /// Only a hook still holding exactly what `enable` wrote is ours to delete.
    private func hookIsOurs(_ repo: URL) -> Bool {
        (try? String(contentsOf: FlywheelSetup.beadsSyncHookPath(in: repo), encoding: .utf8)) == FlywheelSetup.beadsSyncHookContents
    }

    private func agentsSectionRange(_ repo: URL) -> Range<String.Index>? {
        guard let text = try? String(contentsOf: repo.appendingPathComponent("AGENTS.md"), encoding: .utf8),
              let start = text.range(of: Self.agentsSectionStart) else { return nil }
        guard let endMarker = Self.agentsSectionEnd else { return start.lowerBound..<text.endIndex }
        guard let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) else { return nil }
        let afterNewline = text[end.upperBound...].first == "\n" ? text.index(after: end.upperBound) : end.upperBound
        return start.lowerBound..<afterNewline
    }
}
```

(If Step 1 set `agentsSectionEnd = nil`, an AGENTS.md whose section is followed by user text loses
that text too — say so in the confirmation by appending " (and everything after it)" to that line.)

`SessionStore.swift` — beside `enableFlywheel(for:)`:

```swift
    /// Spec §9: drain and stop the project's swarm, give back its claims and every FD-booted
    /// agent's reservations, stop watching, and clear the flag. The repo is not edited.
    @discardableResult
    func turnOffFlightControl(project path: String) async -> FlightControlOff.Report {
        let backend: SwarmBackend = swarmServiceStorage?.backend
            ?? BrSwarmBackend(runner: SystemFlywheelProcessRunner(), brPath: flywheelTools.br, amPath: flywheelTools.am)
        let off = FlightControlOff(
            swarm: swarmServiceStorage, backend: backend,
            agents: { [weak self] in self?.flywheelAgents(inProject: $0) ?? [] },
            stopObserving: { [weak self] in self?.observeService.disable(project: $0) },
            setEnabled: { [weak self] project, enabled in
                guard let self else { return }
                var settings = self.preferences?.projectSettings(project) ?? ProjectSettings()
                settings.flywheelEnabled = enabled ? true : nil
                self.preferences?.setProjectSettings(project, settings)
            })
        return await off.run(project: path)
    }

    func removeFlightControl(from repo: URL) async -> [String] {
        await FlightControlRepoRemoval(runner: SystemFlywheelProcessRunner(), amPath: flywheelTools.am).remove(repo: repo)
    }
```

`ProjectHeaderRow.swift`:
- state: `@State private var showingTurnOff = false` and `@State private var showingRemoval = false`;
- in the context menu's `if isFlywheelEnabled {` branch, last: `Button("Turn Off Flight Control…") { showingTurnOff = true }`;
- in the `else` branches (not enabled), after the Enable/Set Up button:

```swift
                if flywheelStatus.guardInstalled || flywheelStatus.beadsSyncHooksInstalled {
                    Button("Remove Flight Control from Repo…") { showingRemoval = true }
                }
```

- after the `.popover(...)` from Task 10b:

```swift
        .confirmationDialog("Turn off Flight Control for \(repo.displayName)?", isPresented: $showingTurnOff) {
            Button("Turn Off") { Task { await store.turnOffFlightControl(project: repo.url.standardizedFileURL.path) } }
        } message: {
            Text("The swarm drains and stops, tasks it claimed go back to open, agents' file reservations are released, and Flight Deck stops watching. Hooks, AGENTS.md and the task data stay as they are.")
        }
        .confirmationDialog("Remove Flight Control from \(repo.displayName)?", isPresented: $showingRemoval) {
            Button("Remove", role: .destructive) { Task { _ = await store.removeFlightControl(from: repo.url.standardizedFileURL) } }
        } message: {
            Text(FlightControlRepoRemoval(runner: SystemFlywheelProcessRunner()).plannedChanges(repo: repo.url.standardizedFileURL)
                .joined(separator: "\n"))
        }
```

- [ ] **Step 5: Run the tests, the guard, a build**

Run: `FD_TEST_FILTER=FlightControlDisableTests,FlywheelSetupTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. If `TerminologyGuardTests` flags `beadsSyncHookContents` (its literal contains
`.beads`, now on a new line), add that literal's template to `TerminologyScan.internalAllowList`
with the comment "FlywheelSetup.beadsSyncHookContents: the hook script written to disk, never
rendered" — the same reason the existing `.beads` entries give. `./scripts/build.sh 2>&1 | tail -3`
→ `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Swarm/FlightControlDisable.swift Sources/FlightDeck/FlightControl/Swarm/SwarmService.swift Sources/FlightDeck/Flywheel/FlywheelSetup.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/ProjectHeaderRow.swift Tests/FlightDeckTests/FlightControlL3/Swarm/FlightControlDisableTests.swift Tests/FlightDeckTests/Intake/Planning/TerminologyGuardTests.swift
git commit -m "feat: turn Flight Control off for a project, and remove it from a repo" -m "Turn Off drains and stops the project's swarm, returns every unclosed task it claimed to open, releases every FD-booted agent's reservations, stops the Observe watcher (finally calling FlywheelObserveService.disable) and clears the flag, without editing the repo. Remove from Repo is separate and confirmed with the list of changes: it uninstalls the guard, deletes the task-sync hook only if it is still exactly what setup wrote, and cuts the AGENTS.md section br agents --add added. The task data is never touched." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(Drop `TerminologyGuardTests.swift` from `git add` if Step 5 needed no allow-list entry.)

---
### Task 14: The fixture backend, the stub agent, `SwarmUITests` and its runner

**Files:**
- Create: `scripts/make-flight-control-fixture.py`
- Create: `scripts/test-ui-flight-control.sh`
- Create: `Sources/FlightDeck/FlightControl/Swarm/FlightControlFixtureBackend.swift` (`#if DEBUG`)
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (Debug-only wiring)
- Create: `UITests/FlightDeckUITests/SwarmUITests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Swarm/FixtureBackendTests.swift`
- Modify: `AGENTS.md` (Commands block: one line)

**Interfaces:**
- Consumes: `-FlightDeckFixture` (`SessionFixture`: `sessions.json`, `status/`, `projects/`, `shell`), `-FlightDeckResetState`,
  `-FlightDeckDaemonDir`; every L3-S surface's accessibility id.
- Produces: launch argument `-FlightControlFixtureBackend <dir>` (Debug + reset only);
  `struct FlightControlFixtureBackend { root; static func fromDefaults(_:) ; tools; projectPath; swarmsRoot; dependencies() -> SwarmDependencies? }`,
  `FixtureRouter`, `FixtureKinds`, `FixtureSlots`; `scripts/test-ui-flight-control.sh` (prints `FLIGHT CONTROL UI PASS|FAIL`, screenshots in `DerivedData/flight-control-ui/`).

**Why a stub agent satisfies the real gates.** A tab's prompt is typed only when
`status(for:)?.activity != nil` and `ClaudeTextChannel.isComposerBox` sees a `─` rule directly above
a `❯` line and another rule below it (`ClaudeTextChannel.swift`). The stub writes a claude status
file into the fixture's `status/` (read in place of `~/.claude/sessions`, with liveness believed —
`FlightDeckApp.makeStore`'s `statusIsAlive`), draws exactly that box, and reads prompts in cooked
mode. No `claude` is ever run: the fixture's `shell` replaces the login shell for every tab.

- [ ] **Step 1: Write the fixture builder**

`scripts/make-flight-control-fixture.py` (make it executable):

```python
#!/usr/bin/env python3
"""Builds the fixture backend SwarmUITests drives (L3-S Task 14).

Run by scripts/test-ui-flight-control.sh, never by the test: the UI-test bundle is sandboxed and
cannot write anywhere the app can read (see scripts/make-screenshot-fixture.py, which hit the same
wall).

<root>/
  project/             the Flight Control project; .beads/beads.db is touched on every br write
  bin/br, bin/am       stubs over <root>/state.json (one lock, one file)
  shell                the stub agent every tab runs instead of the login shell
  status/ projects/    claude's status registry and transcripts, read in place of ~/.claude
  sessions.json        one project with one plain tab (--seeded: plus a handed-off pair)
  state/               the swarms root (--seeded: a paused swarm with a hand-off)
  swarm-deps.json      fixture routing and pool slots
  reservations-held.json, guard-message.txt, contested-task   the contested scenario
  stub.log             every stub's actions
"""
import json
import os
import shutil
import stat
import sys
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPTURED = os.path.join(REPO, "Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm")
SPIKE_MESSAGE = ("mcp-agent-mail: file reservation conflict detected! Sources/Foo.swift conflicts with "
                 "reservation 'Sources/*.swift' held by GreenFox")
AT = "2026-10-04T18:00:00Z"


def block(kind="tests"):
    return {"v": 1, "kind": kind, "harness": "claude", "model": "opus", "knobs": {}, "pool": "claude-local",
            "source": {"by": "rule", "reason": "fixture routing", "at": AT}, "pinned": False, "host": None}


def context(kind="tests"):
    return json.dumps({"flight_deck": {"execution": block(kind)}}, sort_keys=True)


TASKS = {
    "fx-a": {"title": "Add the parser tests", "priority": 1, "description": "Cover the parser.",
             "acceptance": "- tests pass"},
    "fx-b": {"title": "Edit Sources/Foo.swift", "priority": 2, "description": "Change Foo.",
             "acceptance": "- Foo changed"},
    "fx-c": {"title": "Write the changelog", "priority": 3, "description": "Note the change.",
             "acceptance": "- changelog updated"},
}

BR = r'''#!/usr/bin/env python3
import fcntl, json, os, sys, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def opt(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None

def row(tid, t):
    r = {"id": tid, "title": t["title"], "status": t["status"], "priority": t["priority"],
         "issue_type": "task", "assignee": t.get("assignee")}
    if t.get("agent_context"):
        r["agent_context"] = t["agent_context"]
    return r

def run(state, argv):
    tasks = state["tasks"]
    cmd = argv[0] if argv else ""
    if cmd == "ready":
        return json.dumps([row(i, t) for i, t in tasks.items() if t["status"] == "open" and not t.get("assignee")]), 0, False
    if cmd == "scheduler":
        recs = [{"rank": n + 1, "issue": {"id": i}} for n, i in enumerate(state["order"])]
        return json.dumps({"schema": "br.scheduler.v1", "recommendations": recs}), 0, False
    if cmd == "list":
        status = opt(argv, "--status")
        rows = [row(i, t) for i, t in tasks.items() if status is None or t["status"] == status]
        return json.dumps({"issues": rows, "total": len(rows), "limit": 0, "offset": 0, "has_more": False}), 0, False
    if cmd == "graph":
        return json.dumps({"components": [], "total_nodes": 0, "total_components": 0}), 0, False
    if cmd == "show" and len(argv) > 1 and argv[1] in tasks:
        t = tasks[argv[1]]
        r = row(argv[1], t)
        r["description"] = t.get("description", "")
        r["acceptance_criteria"] = t.get("acceptance", "")
        return json.dumps([r]), 0, False
    if cmd == "update" and len(argv) > 1 and argv[1] in tasks:
        t = tasks[argv[1]]
        if "--claim" in argv:
            actor = opt(argv, "--actor")
            if t.get("assignee") and t["assignee"] != actor:
                return json.dumps({"error": {"code": "VALIDATION_FAILED", "message": "already claimed", "retryable": True}}), 1, False
            t["assignee"] = actor
            t["status"] = "in_progress"
            return "{}", 0, True
        if opt(argv, "--status") is not None:
            t["status"] = opt(argv, "--status")
        if "--assignee" in argv:
            t["assignee"] = opt(argv, "--assignee") or None
        if opt(argv, "--agent-context") is not None:
            t["agent_context"] = opt(argv, "--agent-context")
        return "{}", 0, True
    if cmd == "close" and len(argv) > 1 and argv[1] in tasks:
        tasks[argv[1]]["status"] = "closed"
        return "{}", 0, True
    return "{}", 0, False

def main(argv):
    with open(os.path.join(ROOT, "state.json"), "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        state = json.load(f)
        out, code, wrote = run(state, argv)
        if wrote:
            f.seek(0); f.truncate(); json.dump(state, f)
    if wrote:
        db = os.path.join(ROOT, "project/.beads/beads.db")
        with open(db, "a"):
            pass
        os.utime(db, None)   # the Observe watcher repolls on this mtime
    with open(os.path.join(ROOT, "stub.log"), "a") as log:
        log.write("%s br %s -> %d\n" % (time.strftime("%H:%M:%S"), " ".join(argv), code))
    print(out)
    return code

sys.exit(main(sys.argv[1:]))
'''

AM = r'''#!/usr/bin/env python3
import fcntl, json, os, sys, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def run(state, argv):
    if argv[:2] == ["macros", "start-session"]:
        name = state["names"].pop(0) if state["names"] else "Agent%d" % (len(state["booted"]) + 1)
        state["booted"].append(name)
        return json.dumps({"agent": {"name": name}}), 0, True
    if argv[:2] == ["agents", "list"]:
        return json.dumps([{"name": n} for n in state["booted"]]), 0, False
    if argv[:1] == ["reservations"]:
        held = os.path.join(ROOT, "reservations-held.json")
        if state.get("contested") and os.path.exists(held):
            return open(held).read(), 0, False
        return json.dumps({"all_active": []}), 0, False
    return "{}", 0, False

def main(argv):
    with open(os.path.join(ROOT, "state.json"), "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        state = json.load(f)
        out, code, wrote = run(state, argv)
        if wrote:
            f.seek(0); f.truncate(); json.dump(state, f)
    with open(os.path.join(ROOT, "stub.log"), "a") as log:
        log.write("%s am %s -> %d\n" % (time.strftime("%H:%M:%S"), " ".join(argv), code))
    print(out)
    return code

sys.exit(main(sys.argv[1:]))
'''

SHELL = r'''#!/bin/bash
# The stub agent every fixture tab runs in place of the login shell. It draws claude's composer
# box (a rule, a ❯ line, a rule — ClaudeTextChannel.isComposerBox), reports a claude status file,
# echoes each prompt, closes its task through the stub br, or — for the contested task — writes
# the guard's refusal into its transcript the way a failed `git commit` tool call would.
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/stub.log"
stty dsusp undef 2>/dev/null || true   # ^Y yanks in claude; on BSD it is delayed-suspend
IFS= read -r LAUNCH                    # the claude launch/resume line FD types as initial input
SID=$(printf '%s' "$LAUNCH" | sed -nE 's/.*(--session-id|--resume) ([0-9a-f-]{36}).*/\2/p' | head -1)
echo "$(date +%T) agent $$ ${AGENT_NAME:-?} sid=$SID" >> "$LOG"
ENC=$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')
TRANSCRIPT="$DIR/projects/$ENC/$SID.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")" "$DIR/status"
status() {
  printf '{"pid":%d,"sessionId":"%s","status":"%s","startedAt":%s000,"cwd":"%s","procStart":"Mon Oct  5 09:00:00 2026"}' \
    $$ "$SID" "$1" "$(date +%s)" "$PWD" > "$DIR/status/$$.json.tmp" && mv "$DIR/status/$$.json.tmp" "$DIR/status/$$.json"
}
W=$(tput cols 2>/dev/null || echo 80); case "$W" in ''|*[!0-9]*) W=80;; esac
RULE=$(printf '─%.0s' $(seq 1 "$W"))
box() { printf '%s\n❯ \n%s\n' "$RULE" "$RULE"; printf '\033[2A\033[2C'; }
status idle; box
while IFS= read -r FIRST; do
  TEXT="$FIRST"
  while IFS= read -r -t 0.5 MORE; do TEXT="$TEXT"$'\n'"$MORE"; done
  printf '\n'
  echo "$(date +%T) agent ${AGENT_NAME:-?} prompt: ${TEXT%%$'\n'*}" >> "$LOG"
  case "$TEXT" in
    /clear*|/new*) printf '\033[2J\033[H'; status idle; box; continue ;;
  esac
  TASK=$(printf '%s' "$TEXT" | sed -nE 's/^Your task is ([^:]+):.*/\1/p' | head -1)
  status busy
  printf '⏺ %s\n' "${TEXT%%$'\n'*}"
  if [ -n "$TASK" ]; then
    sleep 2
    if [ "$TASK" = "$(cat "$DIR/contested-task" 2>/dev/null)" ]; then
      python3 - "$TRANSCRIPT" "$DIR/guard-message.txt" <<'PY'
import json, sys
msg = open(sys.argv[2]).read().strip()
rec = {"type": "user", "message": {"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": "fixture", "is_error": True, "content": "Exit code 1\n" + msg}]}}
open(sys.argv[1], "a").write(json.dumps(rec) + "\n")
PY
      printf 'commit blocked by the reservation guard\n'
    else
      "$DIR/bin/br" close "$TASK" >/dev/null
      printf 'closed %s\n' "$TASK"
    fi
  fi
  status idle; box
done
'''


def write_executable(path, body):
    with open(path, "w") as handle:
        handle.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def guard_message():
    path = os.path.join(CAPTURED, "guard-block.txt")
    if os.path.exists(path):
        for line in open(path):
            if "file reservation conflict detected" in line:
                return line.strip()
    return SPIKE_MESSAGE


def session(sid, title, cwd):
    return {"id": sid, "title": title, "workingDirectory": cwd, "transcriptDirectory": cwd,
            "pinnedConversationID": sid, "activity": "idle", "unread": False}


def main(root, seeded):
    if os.path.exists(root):
        shutil.rmtree(root)
    project = os.path.join(root, "project")
    for d in ("bin", "status", "projects", "state", "project/.beads"):
        os.makedirs(os.path.join(root, d))
    open(os.path.join(project, ".beads/beads.db"), "w").close()
    with open(os.path.join(project, "AGENTS.md"), "w") as handle:
        handle.write("# Fixture project\n")

    tasks = {}
    for tid, t in TASKS.items():
        tasks[tid] = dict(t, status="open", assignee=None, agent_context=context())
    names = ["BlueLake", "RedStone", "GoldViper", "SilverPine"]
    state = {"tasks": tasks, "order": list(TASKS), "names": names, "booted": [], "contested": True}

    sessions = [session(str(uuid.uuid4()), "planning", project)]
    if seeded:
        old, new = str(uuid.uuid4()), str(uuid.uuid4())
        sessions += [session(old, "swarm old", project), session(new, "swarm new", project)]
        state["booted"] = ["BlueLake", "GreenFox"]
        tasks["fx-a"]["status"] = "in_progress"
        tasks["fx-a"]["assignee"] = "GreenFox"
        state["contested"] = False

        def agent(sid, name, st, task, frm=None, to=None):
            a = {"session": sid, "agentName": name, "config": "claude|opus||claude-local", "block": context(),
                 "state": st, "excludedFromReuse": False, "stateSince": AT}
            if task: a["task"] = task
            if st == "handedOff": a["lastTask"] = "fx-a"
            if frm: a["handedOffFrom"] = frm
            if to: a["handedOffTo"] = to
            return a
        swarm = {"id": str(uuid.uuid4()), "project": project, "cap": 2, "poolCaps": {}, "filter": {"allReady": True},
                 "state": "paused", "createdAt": AT, "waiting": [], "unroutable": [], "spawnFailures": {},
                 "agents": [agent(old, "BlueLake", "handedOff", None, to=new),
                            agent(new, "GreenFox", "working", "fx-a", frm=old)]}
        with open(os.path.join(root, "state/swarms.json"), "w") as handle:
            json.dump({"v": 1, "swarms": [swarm]}, handle)

    with open(os.path.join(root, "state.json"), "w") as handle:
        json.dump(state, handle)
    with open(os.path.join(root, "sessions.json"), "w") as handle:
        json.dump({"sessions": sessions, "projects": [{"path": project, "isCollapsed": False}],
                   "selectedSessionID": sessions[0]["id"], "sessionCounter": len(sessions)}, handle)
    with open(os.path.join(root, "swarm-deps.json"), "w") as handle:
        json.dump({"pools": {"claude-local": 3}, "routing": {"harness": "claude", "model": "opus", "pool": "claude-local"}}, handle)

    held = os.path.join(CAPTURED, "am-reservations-held.json")
    if os.path.exists(held):
        shutil.copy(held, os.path.join(root, "reservations-held.json"))
    with open(os.path.join(root, "guard-message.txt"), "w") as handle:
        handle.write(guard_message() + "\n")
    with open(os.path.join(root, "contested-task"), "w") as handle:
        handle.write("fx-b")

    write_executable(os.path.join(root, "bin/br"), BR)
    write_executable(os.path.join(root, "bin/am"), AM)
    write_executable(os.path.join(root, "shell"), SHELL)
    print("fixture at %s (%s)" % (root, "seeded" if seeded else "live"))


if __name__ == "__main__":
    main(sys.argv[1], "--seeded" in sys.argv[2:])
```

Smoke-check it by hand, without the app:

```bash
F=$(mktemp -d "$HOME/.fd-l3s-fixture.XXXX")/live && python3 scripts/make-flight-control-fixture.py "$F"
"$F/bin/br" ready --json | python3 -m json.tool | head -5
"$F/bin/am" macros start-session --project "$F/project" --program claude-code --model opus --json
"$F/bin/br" update fx-a --claim --actor BlueLake --json; "$F/bin/br" update fx-a --claim --actor RedStone --json; echo "exit $?"
"$F/bin/br" show fx-a --json
rm -rf "$(dirname "$F")"
```

Expected: three ready rows; `{"agent": {"name": "BlueLake"}}`; the second claim prints
`VALIDATION_FAILED` with `exit 1`; `show` reports `in_progress` / `BlueLake`.

- [ ] **Step 2: Write the failing fixture-backend test**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The Debug-only fixture backend's routing and slots are what the UI test's swarm runs on, so
/// their rules are pinned here, headless.
@MainActor
final class FixtureBackendTests: XCTestCase {
    func testTheBackendReadsItsTableAndHandsOutLocalSlots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fcfb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try #"{"pools":{"claude-local":2},"routing":{"harness":"claude","model":"opus","pool":"claude-local"}}"#
            .write(to: root.appendingPathComponent("swarm-deps.json"), atomically: true, encoding: .utf8)
        let backend = FlightControlFixtureBackend(root: root)
        XCTAssertEqual(backend.tools.br, root.appendingPathComponent("bin/br").path)
        XCTAssertEqual(backend.swarmsRoot, root.appendingPathComponent("state", isDirectory: true))
        let deps = try XCTUnwrap(backend.dependencies())
        let a = try XCTUnwrap(deps.allocator.lease(pool: "claude-local"))
        let b = try XCTUnwrap(deps.allocator.lease(pool: "claude-local"))
        XCTAssertNil(deps.allocator.lease(pool: "claude-local"), "two slots")
        XCTAssertNil(a.account.id, "a local slot has no account")
        deps.allocator.release(b)
        XCTAssertNotNil(deps.allocator.lease(pool: "claude-local"))
        XCTAssertEqual(deps.capacity.headroom(pool: "claude-local").count, 2)
        let kind = try XCTUnwrap(KindResolution.resolve("tests", in: deps.kinds.kinds(project: root)))
        let routed = deps.router.assign(kind: kind, project: root, catalogs: AdapterCatalogs([]), now: Date()).block
        XCTAssertEqual(routed.model, "opus")
        XCTAssertEqual(routed.pool, "claude-local")
        XCTAssertNil(deps.router.spill(routed, kind: kind, project: root, exhausted: ["claude-local"],
                                       catalogs: AdapterCatalogs([]), now: Date()))
    }

    func testOnlyTheLaunchArgumentTurnsItOn() {
        let defaults = UserDefaults(suiteName: "fcfb-\(UUID().uuidString)")!
        XCTAssertNil(FlightControlFixtureBackend.fromDefaults(defaults))
        defaults.set("/tmp/x", forKey: "FlightControlFixtureBackend")
        XCTAssertEqual(FlightControlFixtureBackend.fromDefaults(defaults)?.root.path, "/tmp/x")
    }
}
```

Run: `FD_TEST_FILTER=FixtureBackendTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'FlightControlFixtureBackend' in scope`. (`test-unit.sh` builds
Debug, so the `#if DEBUG` type is visible to the test.)

- [ ] **Step 3: Implement `FlightControlFixtureBackend.swift`**

```swift
#if DEBUG
import Foundation
import IntakeKit

/// `-FlightControlFixtureBackend <dir>` — Debug builds only, and only with
/// `-FlightDeckResetState` (`FlightDeckApp`). Points `am`/`br` at the stubs
/// `scripts/make-flight-control-fixture.py` built, the swarms root at its `state/`, and routing
/// and capacity at deterministic stand-ins, so SwarmUITests drives the real app with no real
/// br, am, account or agent. Never compiled into Release.
struct FlightControlFixtureBackend {
    let root: URL

    static func fromDefaults(_ defaults: UserDefaults = .standard) -> FlightControlFixtureBackend? {
        guard let path = defaults.string(forKey: "FlightControlFixtureBackend"), !path.isEmpty else { return nil }
        return FlightControlFixtureBackend(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    var tools: FlywheelToolPaths {
        FlywheelToolPaths(am: root.appendingPathComponent("bin/am").path, br: root.appendingPathComponent("bin/br").path)
    }
    var projectPath: String { root.appendingPathComponent("project", isDirectory: true).standardizedFileURL.path }
    var swarmsRoot: URL { root.appendingPathComponent("state", isDirectory: true) }

    private struct Table: Decodable {
        struct Routing: Decodable { let harness: String; let model: String; let pool: String }
        let pools: [String: Int]
        let routing: Routing
    }

    func dependencies() -> SwarmDependencies? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("swarm-deps.json")),
              let table = try? JSONDecoder().decode(Table.self, from: data) else { return nil }
        let slots = FixtureSlots(pools: table.pools)
        return SwarmDependencies(
            router: FixtureRouter(harness: HarnessID(table.routing.harness), model: table.routing.model,
                                  pool: PoolID(table.routing.pool)),
            kinds: FixtureKinds(), allocator: slots, capacity: slots)
    }
}

/// Routes every kind to one model and never spills — the UI test asserts on routing it can predict.
final class FixtureRouter: Router, @unchecked Sendable {
    let harness: HarnessID, model: String, pool: PoolID
    init(harness: HarnessID, model: String, pool: PoolID) { self.harness = harness; self.model = model; self.pool = pool }
    func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment {
        Assignment(block: ExecutionBlock(kind: kind.id, harness: harness, model: model, pool: pool,
                                         source: AssignmentSource(by: .rule, ruleId: "fixture", reason: "fixture routing", at: now)))
    }
    func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>,
               catalogs: AdapterCatalogs, now: Date) -> Assignment? { nil }
}

final class FixtureKinds: KindRegistry, @unchecked Sendable {
    func kinds(project: URL) throws -> [TaskKind] { SeedKinds.all(createdAt: Date(timeIntervalSince1970: 1_791_136_800)) }
    func propose(_ kind: TaskKind, project: URL) throws -> TaskKind { kind }
}

/// Local slots: a pool of N accountless slots, each leased once until released, all under soft.
final class FixtureSlots: PoolAllocator, CapacityReader, @unchecked Sendable {
    private let lock = NSLock()
    private let pools: [String: Int]
    private var taken: [PoolID: Set<Int>] = [:]
    init(pools: [String: Int]) { self.pools = pools }

    private func account(_ index: Int) -> AccountRef { AccountRef(harness: "claude", id: nil, label: "local \(index)") }

    func lease(pool: PoolID) -> AccountLease? {
        lock.withLock {
            guard let count = pools[pool.rawValue], count > 0 else { return nil }
            for index in 1...count where !(taken[pool]?.contains(index) ?? false) {
                taken[pool, default: []].insert(index)
                return AccountLease(pool: pool, account: account(index))
            }
            return nil
        }
    }

    func release(_ lease: AccountLease) {
        lock.withLock {
            if let index = Int(lease.account.label.split(separator: " ").last ?? "") { taken[lease.pool]?.remove(index) }
        }
    }

    func headroom(pool: PoolID) -> [AccountHeadroom] {
        guard let count = pools[pool.rawValue], count > 0 else { return [] }
        return (1...count).map { AccountHeadroom(account: account($0), worstUtilization: 0.3, state: .underSoft, resetsAt: nil) }
    }
}
#endif
```

- [ ] **Step 4: Wire it into `FlightDeckApp` (Debug only)**

In `init()`, directly after the `if Self.isResettingState, let fixture = Self.fixture { … }` block:

```swift
        #if DEBUG
        // L3-S UI tests: Flight Control on for the fixture project, in the hermetic (nil
        // persistence) preferences a reset run uses — so nothing reaches `preferences.v1`.
        if Self.isResettingState, let backend = FlightControlFixtureBackend.fromDefaults() {
            var settings = preferences.projectSettings(backend.projectPath)
            settings.flywheelEnabled = true
            preferences.setProjectSettings(backend.projectPath, settings)
        }
        #endif
```

In `makeStore(preferences:)`, replace Task 7h's `swarmsRoot:` argument with a computed pair defined
just before `let store = SessionStore(`:

```swift
        var flywheelTools = FlywheelToolPaths.system
        // Beside `intakes/`, honouring `-FlightDeckStateDir`; a reset run gets a scratch root.
        var swarmsRoot: URL? = resetState ? nil : (Self.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
        #if DEBUG
        let flightControlFixture = resetState ? FlightControlFixtureBackend.fromDefaults() : nil
        if let flightControlFixture {
            flywheelTools = flightControlFixture.tools
            swarmsRoot = flightControlFixture.swarmsRoot
        }
        #endif
```

pass `flywheelTools: flywheelTools, swarmsRoot: swarmsRoot` to `SessionStore(...)`, and after the
store is built (before `return store`):

```swift
        #if DEBUG
        if let flightControlFixture { store.swarmDependencies = flightControlFixture.dependencies() }
        #endif
```

Run: `FD_TEST_FILTER=FixtureBackendTests,StateDirectoryOverrideTests ./scripts/test-unit.sh 2>&1 | tail -20` → 0 failures.
Run: `./scripts/build.sh 2>&1 | tail -3` → `** BUILD SUCCEEDED **`, and confirm Release excludes the type:
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -configuration Release -derivedDataPath DerivedData build 2>&1 | tail -3` → `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Write `SwarmUITests`**

`UITests/FlightDeckUITests/SwarmUITests.swift`:

```swift
import AppKit
import XCTest

/// L3-S's UI suite (spec §11), against the fixture backend `scripts/test-ui-flight-control.sh`
/// builds: stub br/am over one state file, a stub agent drawing claude's composer box and closing
/// its task, deterministic routing. Skipped unless that script set the fixture paths, so
/// `scripts/smoke.sh` (which runs this whole bundle) never runs it.
///
/// Header text is read from the Swarm Details popover, never the header row: the row is one
/// combined accessibility element and XCUITest reads its label as "" (`TerminalSmokeTests`).
final class SwarmUITests: XCTestCase {
    private func environmentValue(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[name] ?? environment["TEST_RUNNER_\(name)"]
    }

    override func setUp() { continueAfterFailure = false }

    private func launch(_ fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckFixture", fixture, "-FlightControlFixtureBackend", fixture,
                                "-FlightDeckDaemonDir", fixture + "/daemons"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "no window appeared")
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "swarm-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func text(_ element: XCUIElement) -> String { (element.value as? String) ?? element.label }

    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "project-header").firstMatch
    }

    private func menu(_ app: XCUIApplication, _ item: String) {
        header(app).rightClick()
        let entry = app.menuItems[item]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no \(item) in the project menu")
        entry.click()
    }

    private func popoverTexts(_ app: XCUIApplication) -> [String] {
        menu(app, "Swarm Details…")
        let popover = app.descendants(matching: .any).matching(identifier: "swarm-popover").firstMatch
        XCTAssertTrue(popover.waitForExistence(timeout: 5), "no swarm popover")
        let texts = popover.staticTexts.allElementsBoundByIndex.map(text)
        app.typeKey(.escape, modifierFlags: [])
        return texts
    }

    private func chips(_ app: XCUIApplication) -> [String] {
        app.staticTexts.matching(identifier: "swarm-task-chip").allElementsBoundByIndex.map(text)
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return condition()
    }

    func testLaunchReuseContestedPauseResumeAndRestart() throws {
        guard let fixture = environmentValue("FLIGHT_CONTROL_FIXTURE") else {
            throw XCTSkip("run scripts/test-ui-flight-control.sh")
        }
        var app = launch(fixture)
        XCTAssertTrue(header(app).waitForExistence(timeout: 20))

        // Launch from the sheet with a cap of 2.
        menu(app, "Run Ready Tasks…")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "swarm-launch-sheet").firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["launch-row-fx-a"].waitForExistence(timeout: 10))
        shot(app, "1-launch-sheet")
        app.steppers["launch-cap"].decrementArrows.firstMatch.click()
        app.buttons["launch-swarm"].click()

        // Two agents start, each with its task chip; the header says 2/2.
        XCTAssertTrue(waitUntil(60) { chips(app).count >= 2 }, "chips: \(chips(app))")
        XCTAssertTrue(chips(app).contains { $0.hasPrefix("fx-a") })
        shot(app, "2-rows")
        XCTAssertTrue(popoverTexts(app).contains { $0.hasPrefix("swarm 2/2") })

        // fx-a closes; its agent is reused (same config) for fx-c.
        XCTAssertTrue(waitUntil(90) { chips(app).contains { $0.hasPrefix("fx-c") } }, "chips: \(chips(app))")
        shot(app, "3-reuse")

        // fx-b's agent hit the guard: the row is contested and the drawer names the holder.
        XCTAssertTrue(app.images["swarm-contested"].waitForExistence(timeout: 60), "no contested badge")
        app.staticTexts.matching(identifier: "swarm-task-chip")
            .matching(NSPredicate(format: "value BEGINSWITH 'fx-b' OR label BEGINSWITH 'fx-b'")).firstMatch.click()
        let lane = app.descendants(matching: .any)["observe-lane-assignment"]
        XCTAssertTrue(lane.waitForExistence(timeout: 20), "no Assignment lane")
        XCTAssertTrue(waitUntil(20) { lane.staticTexts.allElementsBoundByIndex.contains { text($0).contains("held by") } })
        shot(app, "4-contested")

        // Pause and resume from the header.
        menu(app, "Pause Swarm")
        XCTAssertTrue(popoverTexts(app).contains { $0.hasPrefix("swarm paused") })
        shot(app, "5-paused")
        menu(app, "Resume Swarm")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(popoverTexts(app).contains { $0.hasPrefix("swarm paused") })

        // Relaunch: the swarm comes back paused, with the banner.
        app.terminate()
        app = launch(fixture)
        XCTAssertTrue(header(app).waitForExistence(timeout: 20))
        XCTAssertTrue(popoverTexts(app).contains("Swarm paused after restart · Resume"))
        shot(app, "6-restart-banner")
    }

    func testHandOffMarkerFromASeededSwarm() throws {
        guard let fixture = environmentValue("FLIGHT_CONTROL_SEEDED") else {
            throw XCTSkip("run scripts/test-ui-flight-control.sh")
        }
        let app = launch(fixture)
        let markers = app.staticTexts.matching(identifier: "swarm-marker")
        XCTAssertTrue(waitUntil(20) { markers.allElementsBoundByIndex.contains { text($0) == "handed off →" } })
        XCTAssertTrue(waitUntil(20) { chips(app).contains("fx-a · tests") })
        shot(app, "handed-off")
    }
}
```

- [ ] **Step 6: Write `scripts/test-ui-flight-control.sh`** (make it executable)

```bash
#!/usr/bin/env bash
# Runs SwarmUITests against the Flight Control fixture backend (L3-S Task 14).
#
# NOT scripts/smoke.sh, and never looped. It launches Flight Deck (Debug) and takes the
# foreground for a few minutes, so it warns first and honours the same one-run-per-120s throttle
# as smoke.sh. Touches no live state: -FlightDeckResetState gives preferences a nil persistence,
# -FlightDeckFixture redirects sessions/status/transcripts and replaces the login shell with a
# stub agent (no `claude` ever runs), -FlightControlFixtureBackend points am/br at stubs, and
# -FlightDeckDaemonDir keeps the fixture's fd-abduco daemons apart from every real one.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

. scripts/throttle.sh

echo "[flight-control-ui] Flight Deck (Debug) takes the foreground in 10 seconds — stop typing."
osascript -e 'display notification "Flight Deck UI test takes the foreground in 10 s" with title "Flight Control UI test"' >/dev/null 2>&1 || true
sleep 10

for key in "NSWindow Frame main" "NSSplitView Subview Frames main, SidebarNavigationSplitView"; do
  defaults delete dev.flightdeck.FlightDeck "$key" 2>/dev/null || true
done

LOG="scripts/.flight-control-ui.log"
: > "$LOG"
ROOT="$PWD/DerivedData/flight-control-fixture"
cleanup() {
  # The fixture's tabs run under detached daemons that outlive the app; reap them by path.
  pkill -f "$ROOT" 2>/dev/null || true
}
trap cleanup EXIT
python3 scripts/make-flight-control-fixture.py "$ROOT/live" >>"$LOG" 2>&1
python3 scripts/make-flight-control-fixture.py "$ROOT/seeded" --seeded >>"$LOG" 2>&1
xcodegen generate >>"$LOG" 2>&1

RESULTS="$PWD/DerivedData/flight-control-ui.xcresult"
rm -rf "$RESULTS"
echo "[flight-control-ui] running SwarmUITests… (full output → $LOG)"
set +e
TEST_RUNNER_FLIGHT_CONTROL_FIXTURE="$ROOT/live" TEST_RUNNER_FLIGHT_CONTROL_SEEDED="$ROOT/seeded" \
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' \
  -derivedDataPath DerivedData -resultBundlePath "$RESULTS" \
  test -only-testing:FlightDeckUITests/SwarmUITests >>"$LOG" 2>&1
rc=$?
set -e

grep -E "Test Case '.*' (passed|failed|skipped)|XCTAssert|error:|\*\* TEST (SUCCEEDED|FAILED)" "$LOG" | tail -n 40 || true

OUT="$PWD/DerivedData/flight-control-ui"
rm -rf "$OUT"; mkdir -p "$OUT"
xcrun xcresulttool export attachments --path "$RESULTS" --output-path "$OUT" >/dev/null 2>&1 || true
echo "[flight-control-ui] screenshots → $OUT ; stub log → $ROOT/live/stub.log"

if [ "$rc" -ne 0 ]; then
  echo "FLIGHT CONTROL UI FAIL (rc=$rc) — $LOG"
  exit "$rc"
fi
echo "FLIGHT CONTROL UI PASS"
```

- [ ] **Step 7: Run it — at most three times**

Run: `./scripts/test-ui-flight-control.sh 2>&1 | tail -30`
Expected: `FLIGHT CONTROL UI PASS`, both `SwarmUITests` cases `passed` (not `skipped`), and PNGs under
`DerivedData/flight-control-ui/`. Read them (Read tool) and check each state looks right.

If it fails, diagnose before rerunning — never rerun blind (AGENTS.md rule 4), and the throttle
allows one run per 120 s:
- **No chips appear**: read `$ROOT/live/stub.log`. No `am macros start-session` line → the launch
  never spawned (look for `spawnFailed` in `$ROOT/live/state/swarm-log/*.jsonl`). A `sid=` that is
  empty → the stub did not see the launch line; print `$LAUNCH` to the log and fix the `sed`.
  Status files present but no prompt typed → `log show --last 5m --predicate 'subsystem == "dev.flightdeck.FlightDeck"' | rg -i "prompt|typing|composer"`;
  `composer=viewportEmpty`/`boxNonEmpty` points at the drawn box.
- **Chips but no reuse**: `br close` must touch `project/.beads/beads.db`; check the log has
  `br close fx-a -> 0` and the swarm log a `close` entry.
- **No contested badge**: confirm `$ROOT/live/projects/*/*.jsonl` holds the guard record and that
  `guard-message.txt` names the same holder `reservations-held.json` does.
After three runs, if a case still fails: keep the test (it is skipped without the fixture env, so it
never breaks `smoke.sh`), record exactly which assertion fails, with the screenshot path and the
stub log excerpt, in `docs/FOLLOWUPS.md` (Task 15), and add the failing step to the maintainer's checklist.

- [ ] **Step 8: Document the runner and commit**

In `AGENTS.md`'s Commands block, after the `./scripts/smoke.sh` line:

```bash
./scripts/test-ui-flight-control.sh  # SwarmUITests on a stub br/am/agent fixture; takes the foreground, throttled like smoke.sh — never loop it
```

```bash
git add scripts/make-flight-control-fixture.py scripts/test-ui-flight-control.sh Sources/FlightDeck/FlightControl/Swarm/FlightControlFixtureBackend.swift Sources/FlightDeck/FlightDeckApp.swift UITests/FlightDeckUITests/SwarmUITests.swift Tests/FlightDeckTests/FlightControlL3/Swarm/FixtureBackendTests.swift AGENTS.md
git commit -m "test: drive a swarm end to end in the real app against a stub backend" -m "A Debug-only -FlightControlFixtureBackend points am and br at stubs over one state file and routing at deterministic stand-ins; every tab runs a stub agent that draws claude's composer box, writes a claude status file, closes its task through the stub br, or writes the guard's refusal into its transcript. SwarmUITests covers launch from the sheet, row chips, the header summary, reuse, the contested badge and drawer detail, pause/resume, the restart banner and the hand-off marker, with a screenshot at each state. scripts/test-ui-flight-control.sh runs it; it warns before taking the foreground and shares smoke.sh's throttle." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: the maintainer's checklist, full suites, spec deviations, FOLLOWUPS, merge readiness

**Files:**
- Create: `docs/FLIGHT-CONTROL-L3-CHECKLIST.md`
- Modify: `docs/superpowers/specs/2026-10-04-flight-control-l3-swarm-design.md` (deviations section)
- Modify: `docs/FOLLOWUPS.md` (the Level 3 entry)

- [ ] **Step 1: Write the checklist**

`docs/FLIGHT-CONTROL-L3-CHECKLIST.md`:

```markdown
# Flight Control Level 3 — swarm checklist (L3-S)

Real tasks to try once L3-S (and the integration branch that wires L3-R/L3-U's real conformers)
is merged and a Release build is installed. Spec §12. Agents cannot drive the GUI here
(AGENTS.md rule 2); `scripts/test-ui-flight-control.sh` covers the same surfaces against stubs.

Use a scratch project with Flight Control on (`Set Up Flight Control…` on a throwaway repo under
your home directory).

1. **Launch.** Release a small intake (3–4 tasks). On the released intake, click **Run Tasks…**.
   Check every task shows a kind, a model and a source chip, and any unroutable task is greyed with
   a reason. Set **Agents at once** to 2 and click **Launch**.
   - Two new tabs open, each starting with "Your task is <id>: …".
   - Each tab's sidebar row shows `<id> · <kind>`.
   - Right-click the project → **Swarm Details…** shows `swarm 2/2`.
2. **Keep fed, and reuse.** Watch one agent finish (`br close`). Within a few seconds its slot takes
   the next ready task. If the next task has the same harness/model/pool, it lands in the SAME tab,
   after `/clear` (or `/new` for codex) — the row's chip changes, no new tab opens.
3. **Contested.** Give two tasks the same file on purpose. When the second agent's commit is
   refused, its row shows the lock badge, and its Observe drawer's **Assignment** lane says
   "waits on <file>, held by <agent> · N min" and quotes the guard.
4. **Phone pause.** On the phone, the project card shows the summary and meters. Tap **Pause**;
   no new task is claimed (watch `br list --status in_progress` stay put when an agent finishes).
   Tap **Resume**; claiming continues.
5. **Off.** Right-click the project → **Turn Off Flight Control…** → **Turn Off**. Check
   `br list --status in_progress --json` lists none of the swarm's tasks (they went back to open),
   and the repo's hooks, AGENTS.md and `.beads` are unchanged (`git status`).

Also look at, once each:
- Quit and reopen Flight Deck mid-swarm: the header shows "Swarm paused after restart · Resume";
  nothing is claimed until **Resume Swarm**.
- **Remove Flight Control from Repo…** on a project that has it off: the confirmation lists the
  guard, the task-sync hook and the AGENTS.md section, and says the task data stays.
```

- [ ] **Step 2: Run the whole unit suite**

Run: `./scripts/test-unit.sh 2>&1 | tee "$TMPDIR/l3s-unit.log" | tail -5; rg -n "error:" "$TMPDIR/l3s-unit.log" | head`
Expected: `** SHARDED UNIT RUN PASSED` and no `error:` lines. A failure in a test this branch did
not touch: check it on master first (`git stash` is forbidden — use a second worktree on master)
before blaming this branch.

- [ ] **Step 3: Run both iOS scripts**

Run: `./scripts/build-ios.sh 2>&1 | tail -5` → succeeds; `./scripts/test-ios.sh 2>&1 | tail -15` → `** TEST SUCCEEDED **`.

- [ ] **Step 4: Record the deviations in the spec**

Append to `docs/superpowers/specs/2026-10-04-flight-control-l3-swarm-design.md`:

```markdown
## 15. Deviations recorded while planning and building

From `docs/superpowers/plans/2026-10-04-flight-control-l3-s-swarm.md`:

1. `session.new` replies with the existing `ServerFrame.session(cid:UUID)` after creation (or an
   `err`), not a new frame case; old phones send it fire-and-forget, old CLIs treat any non-err as
   the ack.
2. `lastActiveAt` is `SessionStore.lastActiveAt(for:)`, stamped in `commitStatuses`, not a
   `SessionStatus` field (status equality stays clock-free).
3. Reuse is checked before leasing; a reused agent keeps its own lease.
4. `StoreSwarmSpawner` also exposes create/deliver/reset (`SwarmAgentLauncher`) so the controller
   can claim between spawn and prompt; the contract `spawn` composes them with an injected claim.
5. Claude guard blocks are read from the transcript tail, not the hook record script; codex from
   its rollout tail; both through `AgentEvent.outputSignals`.
6. The UI test's fake adapter is the claude adapter running a stub shell (`-FlightDeckFixture`).
7. Turn Off lives in the project header menu; Preferences has no Flight Control control.
8. Pause/Resume/Drain/Stop and the details popover live in the header's context menu.
9. Swarm commands carry no idempotency token.
10. Tab activity stands in for the empty Observe events lane in stall detection.
11. `TaskPrompt` lives in IntakeKit.
```

Add any probe-driven change from Tasks 2, 4a, 4b, 11a, 13 and 14 as further numbered items
(field renames, `/new` unsupported, reservations still unconfirmed, a missing AGENTS.md end
marker, UI-test steps that still fail) — each with the probe output that forced it.

- [ ] **Step 5: Update FOLLOWUPS**

In `docs/FOLLOWUPS.md`'s "Level 3 'Operate'" entry, add:

```markdown
- **L3-S swarm built** (branch <name>, <sha>). Integration must: set `SessionStore.swarmDependencies`
  to L3-R's `Router`/`KindRegistry` and L3-U's `PoolAllocator`/`CapacityReader`; set
  `SwarmService.handoffDecisions` to L3-U's driver and give that driver `SwarmService.spawner`,
  `agentSnapshots(project:)`, `recordHandoff(project:from:to:block:lease:)` and
  `returnClaimToOpen(project:task:)`; replace `MinimalMeter` with L3-U's meter view; merge the
  adjacent edits to `ClaudeRoutingCapabilities`/`CodexRoutingCapabilities` (L3-R catalog, L3-U
  meter/transcript, L3-S overrides/reset). Then run `scripts/test-ui-flight-control.sh` against the
  real stack and the maintainer's `docs/FLIGHT-CONTROL-L3-CHECKLIST.md`.
- Open from L3-S: the Observe events lane is still a nil stub (activity stands in); the hook log's
  failed-tool event for claude is unverified (transcript used instead); OpenCode feeds
  `AgentOutputScan` once its adapter lands.
```

plus every unresolved probe outcome from Step 4, and the UI-test status from Task 14 Step 7.

- [ ] **Step 6: Check the vendor diff and the terminology guard**

Run: `git diff master...HEAD -- vendor` → empty output.
Run: `git status --short vendor` → nothing staged or untracked under `vendor/` that this branch added
(the artifact symlinks must not be committed).
Run: `FD_TEST_FILTER=TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -5` → 0 failures.

- [ ] **Step 7: Commit**

```bash
git add docs/FLIGHT-CONTROL-L3-CHECKLIST.md docs/superpowers/specs/2026-10-04-flight-control-l3-swarm-design.md docs/FOLLOWUPS.md
git commit -m "docs: record the swarm as built, its deviations and the maintainer's checklist" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Then finish per `superpowers:finishing-a-development-branch`. L3-S merges into the Level 3
integration branch, not straight to master, unless the integration plan says otherwise.

---

## Self-review against the spec

| Spec § | Covered by |
|---|---|
| §1 success 1 (Run tasks…, cap 3, three agents with first prompts) | Tasks 7a, 8, 14 |
| §1 success 2 (next task; reuse after reset; else spawn) | Tasks 7b, 7d |
| §1 success 3 (rows, header, drawer) | Tasks 10a–10c |
| §1 success 4 (contested badge, holder, guard message) | Tasks 11a–11e |
| §1 success 5 (phone pause within one tick) | Tasks 7e, 12a, 12b |
| §1 success 6 (off drains and returns claims) | Task 13 |
| §2 record, `swarms.json`, log, restore paused + banner, config key | Tasks 1, 7g, 7h |
| §3 launch sheet (ready/scheduler/list join, re-route, override, unroutable, caps) | Tasks 2, 8 |
| §4 controller (slots, order, lease→spill→waiting, reuse, spawn, claim, prompt, completion, hand-off record, pause/drain/stop, auto-stop) | Tasks 7a–7h |
| §5 `session.new` → id, `flightdeck new` prints it, atomic | Task 9 |
| §6 annotations, `lastActiveAt` | Tasks 6, 10a–10c |
| §7 reservations capture/read, depEdges via GraphReader, guard capture, contested relation, notifier | Tasks 11a–11e |
| §8 phone projection (account name only there), commands, card, chips | Tasks 12a, 12b |
| §9 disable + remove from repo | Task 13 |
| §10 error handling | Tasks 7a (conflict), 7c (unroutable/waiting), 7f (spawn ×3, stuck), 7b (reset failure) |
| §11 testing (state machine on fakes, MultiRunner fixtures, captured reservations, recorded tool outputs, wire harnesses, XCUITest with screenshots, script, phone tests) | Tasks 1–14 |
| §12 the maintainer's tasks | Task 15 |
