# Flywheel Intake — Phases 1–3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make project rows open a per-project view, build the pure intake engine
(`IntakeKit`), and ship the Bead-preset intake end to end. That means: you type an intent,
a headless triage agent proposes a change set, you review it with drift flags, and FD
writes the result to `br` and notifies the agents holding affected beads.

**Architecture:**
- **`IntakeKit`** is a new Swift 6, Foundation-only framework holding every piece of
  logic with no side effects: the change-set model, validation, drift, apply planning,
  harness command building and output parsing, triage schema, and intake storage.
- **Side effects stay in the app**, which remains in Swift 5:
  - `IntakeService` (`@MainActor`) owns triage runs and release.
  - `BeadWriter` shells out to `br`, and `IntakeDelivery` to `am` and `submitPrompt`.
  - Views mount in the RootView detail column when a project row is selected.
- **The runner daemon, round engine, Beads tab and branches are *not* in this plan.** A
  second rolling plan covers spec phases 4–9. In phase 3, triage runs in-process, so FD
  quitting mid-triage marks the intake *interrupted* and it can be retried. This is what
  the next plan's runner replaces.

**Tech Stack:** Swift 5 app and Swift 6 framework, SwiftUI with AppKit
(`SidebarInputMonitor`), XCTest (`scripts/test-unit.sh`), xcodegen (`project.yml`), and
the external CLIs `br` 0.6.0, `am`, `codex` 0.155.x and `claude` 2.1.x.

**Spec:** `docs/superpowers/specs/2026-09-26-flywheel-intake-design.md` (commit `1f5dc01`).

## Global Constraints

- The app target keeps `SWIFT_VERSION: "5.0"` (deliberate, per AGENTS.md). Only `IntakeKit`
  uses `"6.0"`, matching FleetKit.
- **FD is the only `br` writer.** Triage runs read-only (codex `-s read-only`, or
  `-c sandbox_mode="read-only"` on resume; claude uses a read-only `--allowedTools` list).
- **Edges from existing beads onto new beads are always held until release**, and FD
  computes the held flag itself. Background: on br 0.6.0, a `deferred` bead still blocks
  any live bead that depends on it.
- **Edge direction** matches `br dep add <ISSUE> <DEPENDS_ON>`. In `Edge(from:to:)`,
  `from` depends on (is blocked by) `to`. `br graph --json` edges are
  `[dependent, dependency]`.
- **Every headless follow-up turn passes model and effort explicitly.** Observed: `codex
  exec resume` falls back to the config default model otherwise.
- **`claude` children run with `CLAUDE_CODE_CHILD_SESSION` and `CLAUDECODE` removed from
  their environment.** Otherwise transcripts are silently not saved.
- **Intake storage:** `<stateDir>/intakes/<uuid>/intake.json`. `<stateDir>` is
  `FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory()`.
- **Tests:** `scripts/test-unit.sh` ignores `-only-testing:` and always runs the whole
  suite (about 8 minutes). Run it in the **foreground**, at most twice per task (red, then
  green).
- **Worktree hazards:**
  - Never `git add -A`. Stage explicit paths, and check `git diff --cached --stat -- vendor`
    is empty before every commit.
  - Never use qartez mutators in a worktree.
  - Never `git stash`.
- **Commits:** lowercase, behavioral, imperative subject. The body covers mechanism and
  evidence. Trailer: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- **Never launch an app bundle from `DerivedData/`.** Never run `scripts/smoke.sh`
  unattended. It takes over the display, so the controller schedules it with Nate.

## Review Focus

1. **Graph drift between triage and release, including a bead deleted in between.**
   Expected: the release review flags the op. It never writes a stale edit, and it never
   crashes on a missing id. *Pinned in Task 9 (`testDeletedTargetIsImpossible`,
   `testClaimedSinceTriageSuggestsScopeChange`).*
2. **A triage agent returns malformed or schema-violating JSON**: prose instead of JSON, an
   unknown `op`, or a dangling `new:` reference. Expected: the intake goes to *failed*, the
   raw output is kept for inspection, and nothing is written. *Pinned in Task 13
   (`testProseOutputFails`) and Task 8 (`testDanglingTempIdRejected`).*
3. **`br` fails partway through a release** (for example, the database is locked).
   Expected: the release is recorded as partial with the exact steps that were applied, and
   there is no retry loop. *Pinned in Task 14 (`testFailureMidwayRecordsPartial`).*
4. **Clicking a project row must not break drag-to-reorder, and must not collapse the
   project unless the click lands on the chevron.** Expected: dragging still reorders, a
   row click selects, and a chevron click collapses. *Pinned in Task 1 (pure rule) and
   Task 3 (UI test, run with Nate).*
5. **The holder of an in-progress bead has no FD session** (an `ntm` agent, or a closed
   tab). Expected: mail only, and the review says "no FD session — mail only". *Pinned in
   Task 15 (`testHolderWithoutSessionGetsMailOnly`).*

---

## Task 0: Branch setup and the CLI module-name build break

`master` (`f3fa374`, with Level 0 restored) cannot run `test-unit.sh` on this
case-insensitive APFS disk. The `FlightDeckCLI` target's module name defaults to its
`PRODUCT_NAME`, `flightdeck`. That collides with the app's `FlightDeck` module inside
`DerivedData`, corrupts the `.swiftdoc`/`.abi.json` files, and breaks
`@testable import FlightDeck`. This was reproduced on a clean master worktree on
2026-09-26.

**Files:**
- Modify: `project.yml` (the `FlightDeckCLI` target's `settings.base`)

**Interfaces:**
- Produces: worktree `.claude/worktrees/flywheel-intake` on branch `flywheel-intake`,
  which is `worktree-flywheel-observe` with `master` merged in, plus the module-name fix.
  The suite is green there.

- [ ] **Step 1: Create the worktree from the Observe branch.** Run each command on its own
  line; the worktree guard refuses compound commands.

```bash
cd /Users/nate/Projects/Protos-n-Tools/flight-deck
git worktree add -b flywheel-intake .claude/worktrees/flywheel-intake worktree-flywheel-observe
```
```bash
cd /Users/nate/Projects/Protos-n-Tools/flight-deck/.claude/worktrees/flywheel-intake
ln -sfn /Users/nate/Projects/Protos-n-Tools/flight-deck/vendor/boringssl-artifacts vendor/boringssl-artifacts
ln -sfn /Users/nate/Projects/Protos-n-Tools/flight-deck/vendor/ghostty-artifacts vendor/ghostty-artifacts
ln -sfn /Users/nate/Projects/Protos-n-Tools/flight-deck/vendor/fd-abduco-artifacts vendor/fd-abduco-artifacts
```

- [ ] **Step 2: Merge master in.**

```bash
git merge master --no-edit
```

Expected conflicts: `docs/FOLLOWUPS.md` (keep both sides' entries), and possibly
`SessionStore.swift` and `Preferences/ProjectSettings.swift`. For each code conflict, keep
master's later behaviour **and** the Observe additions (`observeService`, `drawerCollapsed`,
`focusedObserveAgent`, and so on). Level 0 exists on both sides now, so no Observe code
should need adapting beyond textual merging. Then run `git diff master -- vendor` and
confirm it is empty.

- [ ] **Step 3: Confirm the build break reproduces.**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: a compile failure on `@testable import FlightDeck`, or a module/`.swiftdoc`
error in FlightDeckTests. Record the message in the commit body.

- [ ] **Step 4: Give the CLI target a distinct module name.** In `project.yml`, under
  `FlightDeckCLI: settings: base:`, add one key directly below `PRODUCT_NAME: flightdeck`,
  with its comment:

```yaml
        # The module name otherwise defaults to PRODUCT_NAME ("flightdeck"), which on this
        # case-insensitive APFS volume is the same DerivedData path as the app's "FlightDeck"
        # module: the two builds overwrite each other's .swiftdoc/.abi.json and
        # `@testable import FlightDeck` stops compiling. The binary keeps its name.
        PRODUCT_MODULE_NAME: FlightDeckCLITool
```

- [ ] **Step 5: Run the suite and confirm it is green.**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: `Executed N tests, with 8 tests skipped and 0 failures` (N was about 2965 on
master; the Observe tests add more).

- [ ] **Step 6: Commit.**

```bash
git add project.yml
git diff --cached --stat -- vendor
git commit -m "fix: stop the flightdeck CLI module colliding with FlightDeck on case-insensitive disks

<body: symptom, mechanism, reproduction on clean master 2026-09-26, suite totals>

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Phase 1 — Clickable project rows

### Task 1: Chevron-only collapse rule

**Files:**
- Modify: `Sources/FlightDeck/SidebarInputMonitor.swift` (`SidebarClickIntent.togglesCollapse`
  and its caller in `finishToggleDecision`, plus the capture in `scheduleToggleDecision`)
- Modify: `Tests/FlightDeckTests/SidebarClickIntentTests.swift`

**Interfaces:**
- Produces: `SidebarClickIntent.chevronZoneWidth: CGFloat` (= 22), and
  `SidebarClickIntent.togglesCollapse(downPoint:upPoint:downRow:upRow:clickCount:pressedRowControl:inChevronZone:) -> Bool`.
  `inChevronZone` is a new required parameter.
- Produces: `SidebarInputMonitor.selectRow: ((Int) -> Void)?`. It is called for a single
  click on a project header outside the chevron zone. Task 2 wires it.

- [ ] **Step 1: Write the failing tests.** Add them to `SidebarClickIntentTests`:

```swift
func testClickOutsideChevronZoneDoesNotToggle() {
    let row = "p:A"
    XCTAssertFalse(SidebarClickIntent.togglesCollapse(
        downPoint: .init(x: 100, y: 10), upPoint: .init(x: 100, y: 10),
        downRow: row, upRow: row, clickCount: 1, pressedRowControl: false,
        inChevronZone: false))
}

func testClickInChevronZoneToggles() {
    let row = "p:A"
    XCTAssertTrue(SidebarClickIntent.togglesCollapse(
        downPoint: .init(x: 8, y: 10), upPoint: .init(x: 9, y: 10),
        downRow: row, upRow: row, clickCount: 1, pressedRowControl: false,
        inChevronZone: true))
}

func testChevronZoneDragStillDoesNotToggle() {
    let row = "p:A"
    XCTAssertFalse(SidebarClickIntent.togglesCollapse(
        downPoint: .init(x: 8, y: 10), upPoint: .init(x: 8, y: 30),
        downRow: row, upRow: row, clickCount: 1, pressedRowControl: false,
        inChevronZone: true))
}
```

Then update every existing call in that file to pass `inChevronZone: true`. They all
describe clicks that are meant to toggle.

- [ ] **Step 2: Run the suite and confirm it fails.** Run `./scripts/test-unit.sh 2>&1 |
  tail -20`. Expected: a compile error, "extra argument 'inChevronZone'".

- [ ] **Step 3: Implement the rule.** In `SidebarClickIntent`:

```swift
/// Width, from the row view's leading edge, of the strip where a header click collapses.
/// The chevron is a SwiftUI `Image`, not an `NSControl`, so there is no view to hit-test —
/// the zone is geometry. The earlier note here rejected a "reserved strip of guessed width"
/// because the WHOLE row toggled then and a strip would have shrunk the target; now the row
/// body selects the project (the per-project view) and only the chevron may collapse, so a
/// strip is the only way to tell the two apart. 22pt covers the list's leading inset plus the
/// `.imageScale(.small)` chevron with margin.
static let chevronZoneWidth: CGFloat = 22

static func togglesCollapse(downPoint: CGPoint, upPoint: CGPoint,
                            downRow: String?, upRow: String?,
                            clickCount: Int, pressedRowControl: Bool,
                            inChevronZone: Bool) -> Bool {
    guard clickCount == 1, !pressedRowControl, inChevronZone else { return false }
    guard let downRow, downRow == upRow else { return false }
    return hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) < dragThreshold
}
```

In `scheduleToggleDecision`, compute and pass the zone next to `pressedRowControl`:

```swift
let inChevronZone = rowView.convert(downPoint, from: nil).x < SidebarClickIntent.chevronZoneWidth
```

Thread it through to `finishToggleDecision`. There, after the pressed-button and drag
guards, choose the callback:

```swift
if inChevronZone {
    toggleRow?(rowIndex)
} else if clickCount == 1, !pressedRowControl, (downIdentity == rowIdentity?(rowIndex)),
          hypot(upOnScreen.x - downOnScreen.x, upOnScreen.y - downOnScreen.y) < SidebarClickIntent.dragThreshold {
    selectRow?(rowIndex)
}
```

Declare `var selectRow: ((Int) -> Void)?` next to `toggleRow`, with a doc comment saying it
fires on a completed single click on a header outside the chevron zone.

- [ ] **Step 4: Run the suite and confirm it passes.** Run `./scripts/test-unit.sh 2>&1 |
  tail -5`. Expected: 0 failures.

- [ ] **Step 5: Commit.**
  `fix: collapse a project only from its chevron so the row can select it`

### Task 2: Project selection and the project view mount

**Files:**
- Create: `Sources/FlightDeck/SidebarSelection.swift`
- Create: `Sources/FlightDeck/ProjectView.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (add `selectedProjectID`; clear it when a
  session is selected)
- Modify: `Sources/FlightDeck/SessionSidebar.swift` (the selection binding; the header
  `.tag` / `.selectionDisabled`; wire `selectRow`)
- Modify: `Sources/FlightDeck/RootView.swift` (the detail branch)
- Test: `Tests/FlightDeckTests/SidebarSelectionTests.swift`

**Interfaces:**
- Produces: `enum SidebarSelection { static func route(_ newValue: UUID?, projectIDs: Set<UUID>) -> Route }`
  with `enum Route: Equatable { case project(UUID), session(UUID?) }`.
- Produces: `SessionStore.selectedProjectID: UUID?` (`@Published`, not persisted), and
  `SessionStore.selectProject(_ id: UUID)`.
- Produces: `struct ProjectView: View { let store: SessionStore; let repo: Repo }` with
  accessibility identifier `"project-view"`. Task 17 fills in its body.

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
@testable import FlightDeck

final class SidebarSelectionTests: XCTestCase {
    func testProjectIDRoutesToProject() {
        let p = UUID()
        XCTAssertEqual(SidebarSelection.route(p, projectIDs: [p]), .project(p))
    }
    func testSessionIDRoutesToSession() {
        let s = UUID()
        XCTAssertEqual(SidebarSelection.route(s, projectIDs: [UUID()]), .session(s))
    }
    func testNilRoutesToNoSession() {
        XCTAssertEqual(SidebarSelection.route(nil, projectIDs: []), .session(nil))
    }
    @MainActor func testSelectingSessionClearsProjectSelection() {
        let store = SessionStore.makeForTesting()       // existing helper; if absent use the
        let project = UUID()                            // StubProvider init used in DaemonLifecycleTests
        store.selectProject(project)
        XCTAssertEqual(store.selectedProjectID, project)
        store.selectedSessionID = UUID()
        XCTAssertNil(store.selectedProjectID)
    }
}
```

If `SessionStore.makeForTesting()` doesn't exist, build the store the way
`DaemonLifecycleTests` does:
`SessionStore(provider: StubProvider(), persistence: nil, preferences: nil)`.

- [ ] **Step 2: Run the suite and confirm it fails.** Expected: `SidebarSelection` is not
  defined.

- [ ] **Step 3: Implement.**

`SidebarSelection.swift`:
```swift
import Foundation

/// The sidebar `List` has one `UUID?` selection, but its rows now carry two kinds of id:
/// project headers are tagged with `Repo.id`, session rows with `Session.id`. UUIDs never
/// collide, so the binding's setter routes on membership instead of widening the selection
/// type — which would ripple through every `selectedSessionID` reader (persistence, the
/// phone, the CLI, unread tracking).
enum SidebarSelection {
    enum Route: Equatable { case project(UUID), session(UUID?) }

    static func route(_ newValue: UUID?, projectIDs: Set<UUID>) -> Route {
        if let newValue, projectIDs.contains(newValue) { return .project(newValue) }
        return .session(newValue)
    }
}
```

`SessionStore`, near `selectedSessionID`:
```swift
/// The project whose per-project view fills the detail column, or nil when a session's
/// terminal does. Deliberately NOT persisted: relaunch lands on the last session, which is
/// what every existing restore path expects.
@Published private(set) var selectedProjectID: UUID?

func selectProject(_ id: UUID) { selectedProjectID = id }
```

At the top of `selectedSessionID`'s `didSet`, add `if selectedSessionID != nil {
selectedProjectID = nil }`. Keep the rest of the `didSet` unchanged.

In `SessionSidebar`, replace both branches of the selection binding with this. The DEBUG
branch keeps its `tagNextSelectionChange` call in front of the switch.

```swift
let selectionBinding = Binding<UUID?>(
    get: { store.selectedProjectID ?? store.selectedSessionID },
    set: { newValue in
        switch SidebarSelection.route(newValue, projectIDs: Set(store.repos.map(\.id))) {
        case .project(let id): store.selectProject(id)
        case .session(let id): store.selectedSessionID = id
        }
    })
```

On the `ProjectHeaderRow` row, replace `.selectionDisabled()` with `.tag(repo.id)`. Where
the monitor is configured (next to `toggleRow:`), add:

```swift
selectRow: { index in
    guard index >= 0, index < store.sidebarRows.count,
          case .project(let id) = store.sidebarRows[index] else { return }
    store.selectProject(id)
},
```

The native `List` selection already handles a click. `selectRow` is the fallback for the
case where `NSTableView` refuses to select, for example while a drag is being set up. Both
paths lead to the same `selectProject`.

`RootView` detail: add this branch **before** the surface branch:
```swift
if let projectID = store.selectedProjectID,
   let repo = store.repos.first(where: { $0.id == projectID }) {
    ProjectView(store: store, repo: repo)
} else if let surface = ...   // existing branch unchanged
```

`ProjectView.swift`, a shell that Task 17 fills in:
```swift
import SwiftUI

/// The per-project detail view a project row opens. This plan gives it the Intakes list;
/// the Beads tab arrives with the next plan.
struct ProjectView: View {
    @ObservedObject var store: SessionStore
    let repo: Repo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(repo.displayName).font(.title3.weight(.semibold))
            Text("Intakes").font(.headline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("project-view")
    }
}
```

- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: open a per-project view by clicking a project row`

### Task 3: UI tests for select vs. collapse vs. reorder (run with Nate)

**Files:**
- Modify: `UITests/FlightDeckUITests/TerminalSmokeTests.swift`:
  - `testProjectHeadingsReorderByDragging`, the "click toggles collapse" activity;
  - a new hunt case, `testProjectRowSelectAndReorderUnderChurn`.

- [ ] **Step 1: Retarget the collapse activity.** Replace the midpoint click with a
  chevron click, and add a midpoint-selects assertion:

```swift
let chevron = headers.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
    .withOffset(CGVector(dx: 10, dy: 0))
chevron.click()
XCTAssertTrue(waitFor(timeout: 5) { rows.count == 1 }, "clicking a project's chevron did not collapse it")
settle(); settle()
chevron.click()
XCTAssertTrue(waitFor(timeout: 5) { rows.count == 2 }, "clicking the chevron again did not expand it")
settle(); settle()
headers.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
XCTAssertTrue(app.descendants(matching: .any)["project-view"].waitForExistence(timeout: 5),
              "clicking a project row's body did not open the project view")
XCTAssertEqual(rows.count, 2, "clicking a project row's body collapsed it")
```

- [ ] **Step 2: Add the hunt case.** It follows `testPermissionBypassConfirmationUnderChurn`:
  gated on the bare name `FLIGHTDECK_SIDEBAR_HUNT`, 20 iterations in one launch, and each
  iteration does select → drag header 0 below header 1 → assert the order flipped → select
  again. Reuse `headingPoint`/`belowHeading` from the reorder test, and collect failures
  into an array asserted empty at the end.

- [ ] **Step 3: Compile only.** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -derivedDataPath DerivedData
  build-for-testing 2>&1 | tail -3`. Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit.**
  `test: pin chevron-only collapse and row selection alongside drag reorder`

- [ ] **Step 5 (controller + Nate).** The controller alerts Nate about 10 seconds ahead,
  then runs `./scripts/smoke.sh` once, and once more with
  `TEST_RUNNER_FLIGHTDECK_SIDEBAR_HUNT=1 FLIGHTDECK_TEST_THROTTLE=0 ./scripts/smoke.sh`.
  Both must pass before Phase 3's UI tasks start. If the hunt fails, native selection is
  interfering with drag. Apply the spec's fallback: add `.selectionDisabled()` back on
  headers and rely on `selectRow` alone.

---

## Phase 2 — IntakeKit (pure engine)

### Task 4: IntakeKit framework target

**Files:**
- Modify: `project.yml`
- Create: `Sources/IntakeKit/IntakeKit.swift`
- Test: `Tests/FlightDeckTests/Intake/IntakeKitLinkTests.swift`

**Interfaces:**
- Produces: the module `IntakeKit` (Swift 6). It is embedded in `FlightDeck`, linked by
  `FlightDeckTests`, and later by `FlightDeckCLI` (next plan).

- [ ] **Step 1: Write the failing test.**

```swift
import XCTest
import IntakeKit

final class IntakeKitLinkTests: XCTestCase {
    func testModuleLinks() { XCTAssertEqual(IntakeKit.schemaVersion, 1) }
}
```

- [ ] **Step 2: Run the suite and confirm it fails.** Expected: `no such module 'IntakeKit'`.

- [ ] **Step 3: Declare and wire the target.** Add a new target to `project.yml`, after
  `FleetKit`:

```yaml
  # Pure intake engine: change sets, validation, drift, apply planning, harness command
  # building/parsing, storage. Foundation-only so the app and the `flightdeck intake run`
  # runner (next plan) share one implementation; Swift 6 like FleetKit, since nothing in
  # it touches vendored Ghostty.
  IntakeKit:
    type: framework
    platform: macOS
    sources: [Sources/IntakeKit]
    settings:
      base:
        SWIFT_VERSION: "6.0"
        PRODUCT_MODULE_NAME: IntakeKit
        GENERATE_INFOPLIST_FILE: "YES"
```

Add it to FlightDeck's `dependencies` (`- target: IntakeKit` with `embed: true`) and to
FlightDeckTests' (`- target: IntakeKit` with `embed: false`).

`Sources/IntakeKit/IntakeKit.swift`:
```swift
/// Version of the on-disk intake format (`intake.json`). Bump on any incompatible change.
public enum IntakeKit { public static let schemaVersion = 1 }
```

- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `build: add the IntakeKit engine framework`

### Task 5: Change-set model and wire format

**Files:**
- Create: `Sources/IntakeKit/ChangeSet.swift`
- Create: `Tests/FlightDeckTests/Fixtures/Intake/changeset-all-ops.json`
- Test: `Tests/FlightDeckTests/Intake/ChangeSetCodingTests.swift`

**Interfaces:**
- Produces:
  - `BeadRef` (`.existing(String)` / `.new(String)`), encoded as `"br-42"` or `"new:n1"`;
  - `EdgeKind` (`blocks`, `related`, `parentChild = "parent-child"`);
  - `Precondition { status: String; assignee: String? }`;
  - `DeliveryRating` (`clarifying`, `scopeChange`, `invalidating`);
  - `Delivery { rating; reason }`;
  - `FieldSet { title, description, acceptance: String?; priority: Int? }`;
  - `NewBead { tempId, title, type, priority, description, acceptance, labels }`;
  - the `ChangeOp` cases `createBead(NewBead)`, `addEdge(from:to:kind:)`,
    `editBead(id:set:pre:delivery:)`, `reopen(id:reason:pre:)` and
    `followUp(tempId:of:title:description:pre:)`;
  - `ChangeSet { graphObservedAt: Date; ops: [ChangeOp] }`.

  All are `Codable, Equatable, Sendable`.
- **Wire format.** Each op is one **flat** object: `"op"` plus nullable fields. Strict
  structured-output schemas (Task 13) cannot express `oneOf`, so every field is present
  and non-applicable fields are `null`. The decoder ignores nulls, and the encoder writes
  only the relevant fields.

- [ ] **Step 1: Write the fixture.** `changeset-all-ops.json`:

```json
{
  "graphObservedAt": "2026-09-26T20:00:00Z",
  "ops": [
    {"op":"createBead","tempId":"n1","title":"Tooltip","type":"task","priority":2,"description":"d","acceptance":"a","labels":["ui"],
     "from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null},
    {"op":"addEdge","from":"new:n1","to":"br-42","kind":"blocks",
     "tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null},
    {"op":"editBead","id":"br-17","set":{"title":null,"description":null,"acceptance":"new ac","priority":null},
     "pre":{"status":"in_progress","assignee":"BlueFalcon"},"delivery":{"rating":"scopeChange","reason":"scope grew"},
     "tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"from":null,"to":null,"kind":null,"reason":null,"of":null},
    {"op":"reopen","id":"br-9","reason":"acceptance never met","pre":{"status":"closed","assignee":null},
     "tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"from":null,"to":null,"kind":null,"set":null,"delivery":null,"of":null},
    {"op":"followUp","tempId":"n2","of":"br-12","title":"Extend","description":"more","pre":{"status":"closed","assignee":null},
     "type":null,"priority":null,"acceptance":null,"labels":null,"from":null,"to":null,"kind":null,"id":null,"set":null,"delivery":null,"reason":null}
  ]
}
```

- [ ] **Step 2: Write the failing tests.**

```swift
import XCTest
import IntakeKit

final class ChangeSetCodingTests: XCTestCase {
    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "changeset-all-ops", withExtension: "json", subdirectory: "Fixtures/Intake"))
        return try Data(contentsOf: url)
    }

    func testDecodesEveryOpKind() throws {
        let cs = try ChangeSet.decode(try fixture())
        XCTAssertEqual(cs.ops.count, 5)
        XCTAssertEqual(cs.ops[1], .addEdge(from: .new("n1"), to: .existing("br-42"), kind: .blocks))
        guard case .editBead(let id, let set, let pre, let delivery) = cs.ops[2] else { return XCTFail() }
        XCTAssertEqual(id, "br-17")
        XCTAssertEqual(set.acceptance, "new ac")
        XCTAssertEqual(pre, Precondition(status: "in_progress", assignee: "BlueFalcon"))
        XCTAssertEqual(delivery?.rating, .scopeChange)
    }

    func testRoundTrips() throws {
        let cs = try ChangeSet.decode(try fixture())
        XCTAssertEqual(try ChangeSet.decode(try cs.encoded()), cs)
    }

    func testUnknownOpIsAnError() {
        let data = Data(#"{"graphObservedAt":"2026-09-26T20:00:00Z","ops":[{"op":"deleteEverything"}]}"#.utf8)
        XCTAssertThrowsError(try ChangeSet.decode(data))
    }

    func testBeadRefStringForm() throws {
        XCTAssertEqual(BeadRef(parsing: "new:n3"), .new("n3"))
        XCTAssertEqual(BeadRef(parsing: "br-3"), .existing("br-3"))
        XCTAssertEqual(BeadRef.new("n3").wireValue, "new:n3")
    }
}
```

- [ ] **Step 3: Run the suite and confirm it fails.**

- [ ] **Step 4: Implement `ChangeSet.swift`.**

```swift
import Foundation

public enum BeadRef: Hashable, Sendable, Codable {
    case existing(String)
    case new(String)

    public init(parsing raw: String) {
        self = raw.hasPrefix("new:") ? .new(String(raw.dropFirst(4))) : .existing(raw)
    }
    public var wireValue: String {
        switch self { case .existing(let id): id; case .new(let t): "new:\(t)" }
    }
    public init(from decoder: Decoder) throws {
        self.init(parsing: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer(); try c.encode(wireValue)
    }
}

public enum EdgeKind: String, Codable, Sendable { case blocks, related, parentChild = "parent-child" }

public struct Precondition: Codable, Equatable, Sendable {
    public var status: String
    public var assignee: String?
    public init(status: String, assignee: String?) { self.status = status; self.assignee = assignee }
}

public enum DeliveryRating: String, Codable, Sendable, CaseIterable { case clarifying, scopeChange, invalidating }

public struct Delivery: Codable, Equatable, Sendable {
    public var rating: DeliveryRating
    public var reason: String
    public init(rating: DeliveryRating, reason: String) { self.rating = rating; self.reason = reason }
}

public struct FieldSet: Codable, Equatable, Sendable {
    public var title: String?
    public var description: String?
    public var acceptance: String?
    public var priority: Int?
    public init(title: String? = nil, description: String? = nil, acceptance: String? = nil, priority: Int? = nil) {
        self.title = title; self.description = description; self.acceptance = acceptance; self.priority = priority
    }
    public var isEmpty: Bool { title == nil && description == nil && acceptance == nil && priority == nil }
}

public struct NewBead: Codable, Equatable, Sendable {
    public var tempId: String
    public var title: String
    public var type: String
    public var priority: Int
    public var description: String
    public var acceptance: String?
    public var labels: [String]
    public init(tempId: String, title: String, type: String = "task", priority: Int = 2,
                description: String, acceptance: String? = nil, labels: [String] = []) {
        self.tempId = tempId; self.title = title; self.type = type; self.priority = priority
        self.description = description; self.acceptance = acceptance; self.labels = labels
    }
}

public enum ChangeOp: Equatable, Sendable {
    case createBead(NewBead)
    case addEdge(from: BeadRef, to: BeadRef, kind: EdgeKind)
    case editBead(id: String, set: FieldSet, pre: Precondition, delivery: Delivery?)
    case reopen(id: String, reason: String, pre: Precondition)
    case followUp(tempId: String, of: String, title: String, description: String, pre: Precondition)

    /// The existing bead this op writes to, if any — what drift and release recheck.
    public var existingTarget: String? {
        switch self {
        case .createBead: nil
        case .addEdge(let from, _, _): if case .existing(let id) = from { id } else { nil }
        case .editBead(let id, _, _, _), .reopen(let id, _, _): id
        case .followUp(_, let of, _, _, _): of
        }
    }
}

extension ChangeOp: Codable {
    private enum Key: String, CodingKey {
        case op, tempId, title, type, priority, description, acceptance, labels
        case from, to, kind, id, set, pre, delivery, reason, of
    }
    public struct UnknownOp: Error, Equatable { public let op: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "createBead":
            self = .createBead(NewBead(
                tempId: try c.decode(String.self, forKey: .tempId),
                title: try c.decode(String.self, forKey: .title),
                type: try c.decodeIfPresent(String.self, forKey: .type) ?? "task",
                priority: try c.decodeIfPresent(Int.self, forKey: .priority) ?? 2,
                description: try c.decode(String.self, forKey: .description),
                acceptance: try c.decodeIfPresent(String.self, forKey: .acceptance),
                labels: try c.decodeIfPresent([String].self, forKey: .labels) ?? []))
        case "addEdge":
            self = .addEdge(from: try c.decode(BeadRef.self, forKey: .from),
                            to: try c.decode(BeadRef.self, forKey: .to),
                            kind: try c.decodeIfPresent(EdgeKind.self, forKey: .kind) ?? .blocks)
        case "editBead":
            self = .editBead(id: try c.decode(String.self, forKey: .id),
                             set: try c.decode(FieldSet.self, forKey: .set),
                             pre: try c.decode(Precondition.self, forKey: .pre),
                             delivery: try c.decodeIfPresent(Delivery.self, forKey: .delivery))
        case "reopen":
            self = .reopen(id: try c.decode(String.self, forKey: .id),
                           reason: try c.decode(String.self, forKey: .reason),
                           pre: try c.decode(Precondition.self, forKey: .pre))
        case "followUp":
            self = .followUp(tempId: try c.decode(String.self, forKey: .tempId),
                             of: try c.decode(String.self, forKey: .of),
                             title: try c.decode(String.self, forKey: .title),
                             description: try c.decode(String.self, forKey: .description),
                             pre: try c.decode(Precondition.self, forKey: .pre))
        default:
            throw UnknownOp(op: op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .createBead(let b):
            try c.encode("createBead", forKey: .op)
            try c.encode(b.tempId, forKey: .tempId); try c.encode(b.title, forKey: .title)
            try c.encode(b.type, forKey: .type); try c.encode(b.priority, forKey: .priority)
            try c.encode(b.description, forKey: .description)
            try c.encodeIfPresent(b.acceptance, forKey: .acceptance); try c.encode(b.labels, forKey: .labels)
        case .addEdge(let from, let to, let kind):
            try c.encode("addEdge", forKey: .op)
            try c.encode(from, forKey: .from); try c.encode(to, forKey: .to); try c.encode(kind, forKey: .kind)
        case .editBead(let id, let set, let pre, let delivery):
            try c.encode("editBead", forKey: .op)
            try c.encode(id, forKey: .id); try c.encode(set, forKey: .set); try c.encode(pre, forKey: .pre)
            try c.encodeIfPresent(delivery, forKey: .delivery)
        case .reopen(let id, let reason, let pre):
            try c.encode("reopen", forKey: .op)
            try c.encode(id, forKey: .id); try c.encode(reason, forKey: .reason); try c.encode(pre, forKey: .pre)
        case .followUp(let tempId, let of, let title, let description, let pre):
            try c.encode("followUp", forKey: .op)
            try c.encode(tempId, forKey: .tempId); try c.encode(of, forKey: .of)
            try c.encode(title, forKey: .title); try c.encode(description, forKey: .description)
            try c.encode(pre, forKey: .pre)
        }
    }
}

public struct ChangeSet: Codable, Equatable, Sendable {
    public var graphObservedAt: Date
    public var ops: [ChangeOp]
    public init(graphObservedAt: Date, ops: [ChangeOp]) { self.graphObservedAt = graphObservedAt; self.ops = ops }

    public static func decode(_ data: Data) throws -> ChangeSet { try IntakeJSON.decoder.decode(ChangeSet.self, from: data) }
    public func encoded() throws -> Data { try IntakeJSON.encoder.encode(self) }
}

public enum IntakeJSON {
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()
}
```

- [ ] **Step 5: Run the suite and confirm it passes.**
- [ ] **Step 6: Commit.**
  `feat: model intake change sets with a strict-schema-friendly wire format`

### Task 6: Graph snapshot from `br` JSON

**Files:**
- Create: `Sources/IntakeKit/GraphSnapshot.swift`
- Create: `Tests/FlightDeckTests/Fixtures/Intake/br-list-all.json` and `br-graph-all.json`.
  These are real captures from br 0.6.0, shown below with ids shortened.
- Test: `Tests/FlightDeckTests/Intake/GraphSnapshotTests.swift`

**Interfaces:**
- Produces:
  - `BeadSnapshot { id, title, status: String; assignee: String?; updatedAt: String?; labels: [String] }`;
  - `DepEdge { dependent: String; dependency: String }`;
  - `GraphSnapshot { beads: [String: BeadSnapshot]; edges: Set<DepEdge> }`;
  - `static func decode(list: Data, graph: Data) throws -> GraphSnapshot`.

- [ ] **Step 1: Write the fixtures.** Copy them from these real `br` 0.6.0 captures.

`br-list-all.json`:
```json
{"issues":[
 {"id":"t-5mi","title":"B","description":"desc","acceptance_criteria":"ac","status":"open","priority":2,"issue_type":"task","created_at":"2026-09-26T20:44:02.260570Z","created_by":"nate","updated_at":"2026-09-26T20:44:02.260570Z","labels":["x","y"],"dependency_count":1,"dependent_count":0},
 {"id":"t-lqw","title":"A","status":"in_progress","priority":2,"issue_type":"task","assignee":"BlueFalcon","created_at":"2026-09-26T20:44:02.107546Z","created_by":"nate","updated_at":"2026-09-26T20:44:02.195290Z","dependency_count":0,"dependent_count":1},
 {"id":"t-c1","title":"Old","status":"closed","priority":2,"issue_type":"task","created_at":"2026-09-20T10:00:00Z","created_by":"nate","updated_at":"2026-09-21T10:00:00Z","dependency_count":0,"dependent_count":0}
],"total":3,"limit":0,"offset":0,"has_more":false}
```
`br-graph-all.json`:
```json
{"components":[{"nodes":[{"id":"t-lqw","title":"A","status":"in_progress","priority":2,"depth":0},{"id":"t-5mi","title":"B","status":"open","priority":2,"depth":1}],"edges":[["t-5mi","t-lqw"]],"roots":["t-lqw"]}],"total_nodes":2,"total_components":1}
```

- [ ] **Step 2: Write the failing tests.**

```swift
import XCTest
import IntakeKit

final class GraphSnapshotTests: XCTestCase {
    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/Intake")))
    }
    func testDecodesBeadsAndEdges() throws {
        let g = try GraphSnapshot.decode(list: try load("br-list-all"), graph: try load("br-graph-all"))
        XCTAssertEqual(g.beads.count, 3)
        XCTAssertEqual(g.beads["t-lqw"]?.assignee, "BlueFalcon")
        XCTAssertEqual(g.beads["t-c1"]?.status, "closed")
        XCTAssertEqual(g.beads["t-5mi"]?.labels, ["x", "y"])
        XCTAssertEqual(g.edges, [DepEdge(dependent: "t-5mi", dependency: "t-lqw")])
    }
    func testEmptyGraphHasNoComponents() throws {
        let g = try GraphSnapshot.decode(list: Data(#"{"issues":[]}"#.utf8),
                                         graph: Data(#"{"components":[]}"#.utf8))
        XCTAssertTrue(g.beads.isEmpty); XCTAssertTrue(g.edges.isEmpty)
    }
}
```

- [ ] **Step 3: Run the suite and confirm it fails.**

- [ ] **Step 4: Implement.**

```swift
import Foundation

public struct BeadSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var status: String
    public var assignee: String?
    public var updatedAt: String?
    public var labels: [String]
    public init(id: String, title: String, status: String, assignee: String? = nil,
                updatedAt: String? = nil, labels: [String] = []) {
        self.id = id; self.title = title; self.status = status
        self.assignee = assignee; self.updatedAt = updatedAt; self.labels = labels
    }
    public var precondition: Precondition { Precondition(status: status, assignee: assignee) }
}

/// `dependent` depends on (is blocked by) `dependency` — `br dep add <dependent> <dependency>`,
/// and the `[dependent, dependency]` pairs of `br graph --json`.
public struct DepEdge: Hashable, Codable, Sendable {
    public var dependent: String
    public var dependency: String
    public init(dependent: String, dependency: String) { self.dependent = dependent; self.dependency = dependency }
}

/// Codable so triage can hand it to the agent as `graph.json` (Task 16).
public struct GraphSnapshot: Codable, Equatable, Sendable {
    public var beads: [String: BeadSnapshot]
    public var edges: Set<DepEdge>
    public init(beads: [String: BeadSnapshot] = [:], edges: Set<DepEdge> = []) { self.beads = beads; self.edges = edges }

    private struct ListEnvelope: Decodable {
        struct Issue: Decodable {
            let id: String; let title: String; let status: String
            let assignee: String?; let updated_at: String?; let labels: [String]?
        }
        let issues: [Issue]
    }
    private struct GraphEnvelope: Decodable {
        struct Component: Decodable { let edges: [[String]] }
        let components: [Component]
    }

    /// `list` is `br list --all --json` (closed included); `graph` is `br graph --all --json`.
    public static func decode(list: Data, graph: Data) throws -> GraphSnapshot {
        let issues = try JSONDecoder().decode(ListEnvelope.self, from: list).issues
        let comps = try JSONDecoder().decode(GraphEnvelope.self, from: graph).components
        var beads: [String: BeadSnapshot] = [:]
        for i in issues {
            beads[i.id] = BeadSnapshot(id: i.id, title: i.title, status: i.status,
                                       assignee: i.assignee, updatedAt: i.updated_at, labels: i.labels ?? [])
        }
        let edges = Set(comps.flatMap(\.edges).compactMap { pair -> DepEdge? in
            pair.count == 2 ? DepEdge(dependent: pair[0], dependency: pair[1]) : nil
        })
        return GraphSnapshot(beads: beads, edges: edges)
    }
}
```

- [ ] **Step 5: Run the suite and confirm it passes.**
- [ ] **Step 6: Commit.** `feat: read the bead graph from br's list and graph JSON`

### Task 8: Change-set validation and held-edge computation

**Files:**
- Create: `Sources/IntakeKit/ChangeSetValidator.swift`
- Test: `Tests/FlightDeckTests/Intake/ChangeSetValidatorTests.swift`

**Interfaces:**
- Consumes: `ChangeSet`, `GraphSnapshot` (Tasks 5 and 6).
- Produces: `ValidatedChangeSet { changeSet: ChangeSet; heldOpIndices: Set<Int> }`; the
  `ValidationError` cases `unknownBead(String)`, `undefinedTempId(String)`,
  `duplicateTempId(String)`, `selfEdge(String)`, `cycle` and `missingDelivery(String)`;
  and `ChangeSetValidator.validate(_:against:) -> Result<ValidatedChangeSet, ValidationErrors>`,
  where `ValidationErrors: Error { errors: [ValidationError] }`.

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
import IntakeKit

final class ChangeSetValidatorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)
    let graph = GraphSnapshot(
        beads: ["b1": BeadSnapshot(id: "b1", title: "one", status: "open"),
                "b2": BeadSnapshot(id: "b2", title: "two", status: "in_progress", assignee: "BlueFalcon")],
        edges: [DepEdge(dependent: "b2", dependency: "b1")])
    func new(_ t: String) -> ChangeOp { .createBead(NewBead(tempId: t, title: t, description: t)) }

    func testExistingToNewEdgeIsHeld() throws {
        let cs = ChangeSet(graphObservedAt: t0, ops: [new("n1"),
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),
            .addEdge(from: .new("n1"), to: .existing("b1"), kind: .related)])
        let v = try ChangeSetValidator.validate(cs, against: graph).get()
        XCTAssertEqual(v.heldOpIndices, [1])
    }
    func testDanglingTempIdRejected() {
        let cs = ChangeSet(graphObservedAt: t0, ops: [.addEdge(from: .new("ghost"), to: .existing("b1"), kind: .blocks)])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.undefinedTempId("ghost")])
    }
    func testUnknownBeadRejected() {
        let cs = ChangeSet(graphObservedAt: t0, ops: [.reopen(id: "nope", reason: "r", pre: .init(status: "closed", assignee: nil))])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.unknownBead("nope")])
    }
    func testCycleThroughExistingEdgeRejected() {
        // b2 → b1 already exists; adding b1 → n1 → b2 closes a loop.
        let cs = ChangeSet(graphObservedAt: t0, ops: [new("n1"),
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),
            .addEdge(from: .new("n1"), to: .existing("b2"), kind: .blocks)])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.cycle])
    }
    func testRelatedEdgesDoNotCountAsCycles() throws {
        let cs = ChangeSet(graphObservedAt: t0, ops: [
            .addEdge(from: .existing("b1"), to: .existing("b2"), kind: .related)])
        XCTAssertNoThrow(try ChangeSetValidator.validate(cs, against: graph).get())
    }
    func testInProgressEditNeedsDelivery() {
        let cs = ChangeSet(graphObservedAt: t0, ops: [
            .editBead(id: "b2", set: FieldSet(title: "x"), pre: .init(status: "in_progress", assignee: "BlueFalcon"), delivery: nil)])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.missingDelivery("b2")])
    }
    func testDuplicateTempIdRejected() {
        let cs = ChangeSet(graphObservedAt: t0, ops: [new("n1"), new("n1")])
        XCTAssertEqual(ChangeSetValidator.validate(cs, against: graph).failureErrors, [.duplicateTempId("n1")])
    }
}

extension Result where Failure == ValidationErrors {
    var failureErrors: [ValidationError] { if case .failure(let e) = self { e.errors } else { [] } }
}
```

- [ ] **Step 2: Run the suite and confirm it fails.**

- [ ] **Step 3: Implement.**

```swift
import Foundation

public enum ValidationError: Equatable, Sendable {
    case unknownBead(String), undefinedTempId(String), duplicateTempId(String)
    case selfEdge(String), cycle, missingDelivery(String)
}
public struct ValidationErrors: Error, Equatable, Sendable { public let errors: [ValidationError] }

public struct ValidatedChangeSet: Equatable, Sendable {
    public let changeSet: ChangeSet
    /// Indices of `addEdge` ops whose dependent is an EXISTING bead and dependency a NEW one.
    /// Computed here, never taken from the agent: such an edge blocks a live bead the moment
    /// it is written (observed on br 0.6.0), so it waits for release.
    public let heldOpIndices: Set<Int>
}

public enum ChangeSetValidator {
    public static func validate(_ cs: ChangeSet, against graph: GraphSnapshot) -> Result<ValidatedChangeSet, ValidationErrors> {
        var errors: [ValidationError] = []
        var temps = Set<String>()
        for op in cs.ops {
            let t: String? = switch op { case .createBead(let b): b.tempId; case .followUp(let t, _, _, _, _): t; default: nil }
            if let t { if !temps.insert(t).inserted { errors.append(.duplicateTempId(t)) } }
        }
        func check(_ ref: BeadRef) {
            switch ref {
            case .existing(let id): if graph.beads[id] == nil { errors.append(.unknownBead(id)) }
            case .new(let t): if !temps.contains(t) { errors.append(.undefinedTempId(t)) }
            }
        }
        var held = Set<Int>()
        var blocking: [(String, String)] = graph.edges.map { ($0.dependent, $0.dependency) }
        for (i, op) in cs.ops.enumerated() {
            switch op {
            case .createBead: break
            case .addEdge(let from, let to, let kind):
                check(from); check(to)
                if from == to { errors.append(.selfEdge(from.wireValue)) }
                if case .existing = from, case .new = to { held.insert(i) }
                if kind != .related { blocking.append((from.wireValue, to.wireValue)) }
            case .editBead(let id, _, let pre, let delivery):
                check(.existing(id))
                if pre.status == "in_progress", delivery == nil { errors.append(.missingDelivery(id)) }
            case .reopen(let id, _, _): check(.existing(id))
            case .followUp(_, let of, _, _, _): check(.existing(of))
            }
        }
        if hasCycle(blocking) { errors.append(.cycle) }
        return errors.isEmpty ? .success(ValidatedChangeSet(changeSet: cs, heldOpIndices: held))
                              : .failure(ValidationErrors(errors: errors))
    }

    static func hasCycle(_ edges: [(String, String)]) -> Bool {
        var adj: [String: [String]] = [:]
        for (a, b) in edges { adj[a, default: []].append(b) }
        var state: [String: Int] = [:]           // 1 = on stack, 2 = done
        func visit(_ n: String) -> Bool {
            if state[n] == 1 { return true }
            if state[n] == 2 { return false }
            state[n] = 1
            for m in adj[n, default: []] where visit(m) { return true }
            state[n] = 2
            return false
        }
        return adj.keys.contains { visit($0) }
    }
}
```

- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.**
  `feat: validate change sets and hold edges that would block a live bead`

### Task 9: Drift classification

**Files:**
- Create: `Sources/IntakeKit/DriftClassifier.swift`
- Test: `Tests/FlightDeckTests/Intake/DriftClassifierTests.swift`

**Interfaces:**
- Produces: `OpDrift` (`.holds`, `.drifted(reason: String, suggested: DeliveryRating?)`,
  `.impossible(reason: String)`), and
  `DriftClassifier.classify(_:current:) -> [OpDrift]`, with one entry per op, in order.

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
import IntakeKit

final class DriftClassifierTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 0)
    func validated(_ ops: [ChangeOp], _ g: GraphSnapshot) throws -> ValidatedChangeSet {
        try ChangeSetValidator.validate(ChangeSet(graphObservedAt: t0, ops: ops), against: g).get()
    }
    let before = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "t", status: "open")])

    func testUnchangedHolds() throws {
        let v = try validated([.editBead(id: "b1", set: FieldSet(title: "x"), pre: .init(status: "open", assignee: nil), delivery: nil)], before)
        XCTAssertEqual(DriftClassifier.classify(v, current: before), [.holds])
    }
    func testDeletedTargetIsImpossible() throws {
        let v = try validated([.editBead(id: "b1", set: FieldSet(title: "x"), pre: .init(status: "open", assignee: nil), delivery: nil)], before)
        guard case .impossible = DriftClassifier.classify(v, current: GraphSnapshot()).first else { return XCTFail() }
    }
    func testClaimedSinceTriageSuggestsScopeChange() throws {
        let v = try validated([.editBead(id: "b1", set: FieldSet(title: "x"), pre: .init(status: "open", assignee: nil), delivery: nil)], before)
        let now = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "t", status: "in_progress", assignee: "BlueFalcon")])
        guard case .drifted(let reason, let suggested) = DriftClassifier.classify(v, current: now).first else { return XCTFail() }
        XCTAssertEqual(suggested, .scopeChange)
        XCTAssertTrue(reason.contains("BlueFalcon"), reason)
    }
    func testCreateAlwaysHolds() throws {
        let v = try validated([.createBead(NewBead(tempId: "n1", title: "n", description: "d"))], before)
        XCTAssertEqual(DriftClassifier.classify(v, current: GraphSnapshot()), [.holds])
    }
}
```

- [ ] **Step 2: Run the suite and confirm it fails.**

- [ ] **Step 3: Implement.**

```swift
import Foundation

public enum OpDrift: Equatable, Sendable {
    case holds
    case drifted(reason: String, suggested: DeliveryRating?)
    case impossible(reason: String)
}

public enum DriftClassifier {
    public static func classify(_ v: ValidatedChangeSet, current: GraphSnapshot) -> [OpDrift] {
        v.changeSet.ops.map { op in
            if case .addEdge(let from, let to, _) = op {
                for case .existing(let id) in [from, to] where current.beads[id] == nil {
                    return .impossible(reason: "\(id) no longer exists")
                }
                return .holds
            }
            guard let id = op.existingTarget else { return .holds }
            guard let now = current.beads[id] else { return .impossible(reason: "\(id) no longer exists") }
            let pre: Precondition? = switch op {
                case .editBead(_, _, let p, _), .reopen(_, _, let p), .followUp(_, _, _, _, let p): p
                default: nil }
            guard let pre, pre != now.precondition else { return .holds }
            let who = now.assignee.map { " by \($0)" } ?? ""
            let reason = "\(id) was \(pre.status) at triage and is \(now.status)\(who) now"
            let existing: DeliveryRating? = if case .editBead(_, _, _, let d) = op { d?.rating } else { nil }
            return .drifted(reason: reason, suggested: now.status == "in_progress" ? (existing ?? .scopeChange) : nil)
        }
    }
}
```

- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.**
  `feat: classify change-set ops against the graph as it is at release`

### Task 10: Apply planner

**Files:**
- Create: `Sources/IntakeKit/ApplyPlanner.swift`
- Test: `Tests/FlightDeckTests/Intake/ApplyPlannerTests.swift`

**Interfaces:**
- Produces:
  - `ApplyStep` with the cases `.create(NewBead)`, `.depend(dependent: BeadRef,
    dependency: BeadRef, kind: EdgeKind)`, `.recheck(id: String, pre: Precondition)`,
    `.update(id: String, set: FieldSet)` and `.reopen(id: String, reason: String)`;
  - `ApplyPlanner.plan(_:skipping:) -> [ApplyStep]`. `skipping` holds op indices the user
    dropped or that are impossible.
- **Order:** creates (including follow-up beads) → non-held edges (including the follow-up
  `related` edge) → recheck+update → recheck+reopen → recheck+held edges.

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
import IntakeKit

final class ApplyPlannerTests: XCTestCase {
    func testOrderIsCreatesEdgesEditsReopensThenHeldEdges() throws {
        let g = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "t", status: "open"),
                                      "c1": BeadSnapshot(id: "c1", title: "c", status: "closed")])
        let pre = Precondition(status: "open", assignee: nil)
        let cs = ChangeSet(graphObservedAt: .init(timeIntervalSince1970: 0), ops: [
            .addEdge(from: .existing("b1"), to: .new("n1"), kind: .blocks),          // held
            .reopen(id: "c1", reason: "r", pre: .init(status: "closed", assignee: nil)),
            .editBead(id: "b1", set: FieldSet(title: "x"), pre: pre, delivery: nil),
            .addEdge(from: .new("n1"), to: .existing("b1"), kind: .related),
            .createBead(NewBead(tempId: "n1", title: "n", description: "d")),
            .followUp(tempId: "n2", of: "c1", title: "f", description: "fd", pre: .init(status: "closed", assignee: nil)),
        ])
        let v = try ChangeSetValidator.validate(cs, against: g).get()
        XCTAssertEqual(ApplyPlanner.plan(v, skipping: []), [
            .create(NewBead(tempId: "n1", title: "n", description: "d")),
            .create(NewBead(tempId: "n2", title: "f", description: "fd")),
            .depend(dependent: .new("n1"), dependency: .existing("b1"), kind: .related),
            .depend(dependent: .new("n2"), dependency: .existing("c1"), kind: .related),
            .recheck(id: "b1", pre: pre), .update(id: "b1", set: FieldSet(title: "x")),
            .recheck(id: "c1", pre: .init(status: "closed", assignee: nil)), .reopen(id: "c1", reason: "r"),
            .recheck(id: "b1", pre: pre), .depend(dependent: .existing("b1"), dependency: .new("n1"), kind: .blocks),
        ])
    }
    func testSkippedOpsAreOmitted() throws {
        let g = GraphSnapshot(beads: ["b1": BeadSnapshot(id: "b1", title: "t", status: "open")])
        let cs = ChangeSet(graphObservedAt: .init(timeIntervalSince1970: 0), ops: [
            .editBead(id: "b1", set: FieldSet(title: "x"), pre: .init(status: "open", assignee: nil), delivery: nil)])
        let v = try ChangeSetValidator.validate(cs, against: g).get()
        XCTAssertEqual(ApplyPlanner.plan(v, skipping: [0]), [])
    }
}
```

`recheck` before a held edge uses the **dependent's** precondition. The planner takes it
from the edit/reopen op on the same bead when there is one (here b1 is also edited, so it
is `pre`). Otherwise it records `nil`, and `BeadWriter` only checks that the bead still
exists. So `ApplyStep.recheck`'s `pre` is `Precondition?`.

- [ ] **Step 2: Run the suite and confirm it fails.**

- [ ] **Step 3: Implement.**

```swift
import Foundation

public enum ApplyStep: Equatable, Sendable {
    case create(NewBead)
    case depend(dependent: BeadRef, dependency: BeadRef, kind: EdgeKind)
    /// Re-read `id` right before writing to it; abort the release if it no longer matches.
    /// `pre == nil` means "must still exist" only.
    case recheck(id: String, pre: Precondition?)
    case update(id: String, set: FieldSet)
    case reopen(id: String, reason: String)
}

public enum ApplyPlanner {
    public static func plan(_ v: ValidatedChangeSet, skipping: Set<Int>) -> [ApplyStep] {
        let ops = v.changeSet.ops.enumerated().filter { !skipping.contains($0.offset) }
        var creates: [ApplyStep] = [], edges: [ApplyStep] = [], edits: [ApplyStep] = []
        var reopens: [ApplyStep] = [], held: [ApplyStep] = []
        var knownPre: [String: Precondition] = [:]
        for (_, op) in ops {
            switch op {
            case .editBead(let id, _, let p, _), .reopen(let id, _, let p): knownPre[id] = p
            default: break
            }
        }
        for (i, op) in ops {
            switch op {
            case .createBead(let b): creates.append(.create(b))
            case .followUp(let t, let of, let title, let d, _):
                creates.append(.create(NewBead(tempId: t, title: title, description: d)))
                edges.append(.depend(dependent: .new(t), dependency: .existing(of), kind: .related))
            case .addEdge(let from, let to, let kind):
                if v.heldOpIndices.contains(i), case .existing(let id) = from {
                    held += [.recheck(id: id, pre: knownPre[id]), .depend(dependent: from, dependency: to, kind: kind)]
                } else {
                    edges.append(.depend(dependent: from, dependency: to, kind: kind))
                }
            case .editBead(let id, let set, let p, _): edits += [.recheck(id: id, pre: p), .update(id: id, set: set)]
            case .reopen(let id, let r, let p): reopens += [.recheck(id: id, pre: p), .reopen(id: id, reason: r)]
            }
        }
        return creates + edges + edits + reopens + held
    }
}
```

- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: plan change-set application in a safe write order`

### Task 11: Intake model and store

**Files:**
- Create: `Sources/IntakeKit/Intake.swift`
- Create: `Sources/IntakeKit/IntakeStore.swift`
- Test: `Tests/FlightDeckTests/Intake/IntakeStoreTests.swift`

**Interfaces:**
- Produces:
  - `Preset` (`bead`, `sketch`, `featurePlan`, `fullPlan`);
  - `IntakeState` (`triaging`, `needsAnswers`, `awaitingChoice`, `parked`, `review`,
    `releasing`, `released`, `partiallyReleased`, `failed`, `interrupted`, `discarded`),
    each with `needsAttention: Bool`;
  - `Harness` (`codex`, `claude`);
  - `HarnessSession { harness, sessionID, model, effort }`;
  - `TriageExchange { questions: [String]; answers: [String]? }`;
  - `ReleaseRecord { releasedAt: Date; appliedSteps: Int; idMap: [String: String]; error: String? }`;
  - `Intake`, which is `Codable, Identifiable, Equatable, Sendable`, with fields `id: UUID`,
    `projectPath: String`, `intent: String`, `createdAt: Date`, `state: IntakeState`,
    `recommended: Preset?`, `recommendationReason: String?`, `triage: HarnessSession?`,
    `exchanges: [TriageExchange]`, `changeSet: ChangeSet?`, `failure: String?`,
    `rawFailureOutput: String?`, `release: ReleaseRecord?`, `ratingOverrides: [Int: DeliveryRating]`,
    `droppedOps: Set<Int>`, `confirmedDrift: Set<Int>`;
  - `IntakeStore(root: URL)` with `save(_:) throws`, `load(id:) throws -> Intake`,
    `all() -> [Intake]` (newest first; unreadable files are skipped),
    `directory(for:) -> URL` and `delete(id:) throws`.

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
import IntakeKit

final class IntakeStoreTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("intakes-\(UUID())") }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testSaveLoadRoundTrip() throws {
        let store = IntakeStore(root: root)
        var i = Intake(projectPath: "/p", intent: "add a tooltip")
        i.state = .needsAnswers
        i.exchanges = [TriageExchange(questions: ["Mac only?"], answers: nil)]
        try store.save(i)
        XCTAssertEqual(try store.load(id: i.id), i)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory(for: i.id).appendingPathComponent("intake.json").path))
    }
    func testAllSkipsCorruptFilesAndSortsNewestFirst() throws {
        let store = IntakeStore(root: root)
        let a = Intake(projectPath: "/p", intent: "a", createdAt: Date(timeIntervalSince1970: 1))
        let b = Intake(projectPath: "/p", intent: "b", createdAt: Date(timeIntervalSince1970: 2))
        try store.save(a); try store.save(b)
        let bad = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: bad.appendingPathComponent("intake.json"))
        XCTAssertEqual(store.all().map(\.intent), ["b", "a"])
    }
    func testAttentionStates() {
        XCTAssertTrue(IntakeState.needsAnswers.needsAttention)
        XCTAssertTrue(IntakeState.review.needsAttention)
        XCTAssertTrue(IntakeState.failed.needsAttention)
        XCTAssertFalse(IntakeState.triaging.needsAttention)
        XCTAssertFalse(IntakeState.released.needsAttention)
    }
}
```

- [ ] **Step 2: Run the suite and confirm it fails.**

- [ ] **Step 3: Implement.** For `Intake.swift`, put the enums and structs above in one
  file with `public init`s. `Intake.init(projectPath:intent:createdAt: = Date())` sets
  `id = UUID()`, `state = .triaging`, and empty collections everywhere else.
  `needsAttention` is true for `.needsAnswers`, `.awaitingChoice`, `.review`,
  `.partiallyReleased`, `.failed` and `.interrupted`.

`IntakeStore.swift`:
```swift
import Foundation

/// One directory per intake under `root` (`<stateDir>/intakes`), `intake.json` inside it. The
/// directory — not a single index file — is the unit, because the next plan's runner writes
/// checkpoints and run output beside `intake.json` from another process.
public struct IntakeStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }

    public func save(_ intake: Intake) throws {
        let dir = directory(for: intake.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(intake).write(to: dir.appendingPathComponent("intake.json"), options: .atomic)
    }
    public func load(id: UUID) throws -> Intake {
        try IntakeJSON.decoder.decode(Intake.self, from: Data(contentsOf: directory(for: id).appendingPathComponent("intake.json")))
    }
    public func all() -> [Intake] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? load(id: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func delete(id: UUID) throws { try FileManager.default.removeItem(at: directory(for: id)) }
}
```

- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: persist intakes as one directory each`

---

## Phase 3 — Bead-preset pipeline

### Task 12: Headless harness commands and output parsing

**Files:**
- Create: `Sources/IntakeKit/Harness.swift`
- Create: `Tests/FlightDeckTests/Fixtures/Intake/codex-exec-schema.jsonl` and
  `claude-p-schema.json`. These are real captures from 2026-09-26, shown below.
- Test: `Tests/FlightDeckTests/Intake/HarnessTests.swift`

**Interfaces:**
- Produces:
  - `HarnessRequest { harness: Harness; model: String; effort: String; cwd: URL;
    readableDirs: [URL]; prompt: String; schemaFile: URL; schemaJSON: String;
    resumeSessionID: String? }`;
  - `HarnessCommand.build(_:) -> (executable: String, arguments: [String], unsetEnvironment: [String])`;
  - `HarnessOutput.parse(_ harness: Harness, stdout: Data) throws -> (sessionID: String, structured: Data)`;
  - `HarnessOutput.ParseError` (`noSession`, `noResult`, `notJSON(String)`).

- [ ] **Step 1: Write the fixtures** (real, captured 2026-09-26).

`codex-exec-schema.jsonl`:
```
{"type":"thread.started","thread_id":"01a0df75-9981-7bd0-9ac1-6c8eed40c469"}
{"type":"turn.started"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\"answer\":\"PONG\"}"}}
{"type":"turn.completed","usage":{"input_tokens":13244,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":16,"reasoning_output_tokens":0}}
```
`claude-p-schema.json`:
```json
{"type":"result","subtype":"success","is_error":false,"num_turns":2,"session_id":"a4861836-f024-45f3-9f11-f3a2d366e96f","result":"{\"answer\":\"PONG\"}","structured_output":{"answer":"PONG"},"stop_reason":"tool_use","total_cost_usd":0.1295}
```

- [ ] **Step 2: Write the failing tests.**

```swift
import XCTest
import IntakeKit

final class HarnessTests: XCTestCase {
    private func load(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext, subdirectory: "Fixtures/Intake")))
    }
    func req(_ h: Harness, resume: String? = nil) -> HarnessRequest {
        HarnessRequest(harness: h, model: "m", effort: "high", cwd: URL(fileURLWithPath: "/proj"),
                       readableDirs: [URL(fileURLWithPath: "/intake")], prompt: "P",
                       schemaFile: URL(fileURLWithPath: "/intake/schema.json"), schemaJSON: "{}", resumeSessionID: resume)
    }
    func testCodexParse() throws {
        let out = try HarnessOutput.parse(.codex, stdout: try load("codex-exec-schema", "jsonl"))
        XCTAssertEqual(out.sessionID, "01a0df75-9981-7bd0-9ac1-6c8eed40c469")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["answer": "PONG"])
    }
    func testClaudeParsePrefersStructuredOutput() throws {
        let out = try HarnessOutput.parse(.claude, stdout: try load("claude-p-schema", "json"))
        XCTAssertEqual(out.sessionID, "a4861836-f024-45f3-9f11-f3a2d366e96f")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: out.structured) as? [String: String], ["answer": "PONG"])
    }
    func testCodexFreshIsReadOnlyWithSchema() {
        let c = HarnessCommand.build(req(.codex))
        XCTAssertEqual(c.executable, "codex")
        XCTAssertEqual(c.arguments, ["exec", "--json", "-m", "m", "-c", "model_reasoning_effort=high",
                                     "-s", "read-only", "--skip-git-repo-check",
                                     "--output-schema", "/intake/schema.json", "P"])
    }
    func testCodexResumePinsModelAndSandbox() {
        let c = HarnessCommand.build(req(.codex, resume: "T1"))
        XCTAssertEqual(c.arguments, ["exec", "resume", "--json", "-m", "m", "-c", "model_reasoning_effort=high",
                                     "-c", "sandbox_mode=\"read-only\"", "--skip-git-repo-check",
                                     "--output-schema", "/intake/schema.json", "T1", "P"])
    }
    func testClaudeIsReadOnlyAndUnsetsChildSessionEnv() {
        let c = HarnessCommand.build(req(.claude, resume: "S1"))
        XCTAssertEqual(c.executable, "claude")
        XCTAssertEqual(c.unsetEnvironment, ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"])
        XCTAssertEqual(c.arguments, ["-p", "P", "--model", "m", "--effort", "high", "--output-format", "json",
                                     "--json-schema", "{}", "--allowedTools", HarnessCommand.claudeReadOnlyTools,
                                     "--add-dir", "/intake", "--resume", "S1"])
    }
    func testProseOutputIsNotJSON() {
        let prose = Data(#"{"type":"thread.started","thread_id":"T"}\n{"type":"item.completed","item":{"type":"agent_message","text":"Sure! Here you go"}}"#.utf8)
        XCTAssertThrowsError(try HarnessOutput.parse(.codex, stdout: prose))
    }
}
```

- [ ] **Step 3: Run the suite and confirm it fails.**

- [ ] **Step 4: Implement.**

```swift
import Foundation

public struct HarnessRequest: Sendable {
    public var harness: Harness, model: String, effort: String
    public var cwd: URL, readableDirs: [URL], prompt: String
    public var schemaFile: URL, schemaJSON: String, resumeSessionID: String?
    public init(harness: Harness, model: String, effort: String, cwd: URL, readableDirs: [URL],
                prompt: String, schemaFile: URL, schemaJSON: String, resumeSessionID: String?) {
        self.harness = harness; self.model = model; self.effort = effort; self.cwd = cwd
        self.readableDirs = readableDirs; self.prompt = prompt; self.schemaFile = schemaFile
        self.schemaJSON = schemaJSON; self.resumeSessionID = resumeSessionID
    }
}

public enum HarnessCommand {
    /// Read-only tool set for triage under `claude -p`: file reading plus `br`/`bv` READ verbs.
    /// FD is the only `br` writer (spec §5) — no `br create/update/dep` here.
    public static let claudeReadOnlyTools =
        "Read Grep Glob Bash(br list *) Bash(br show *) Bash(br graph *) Bash(br ready *) Bash(bv *)"

    public static func build(_ r: HarnessRequest) -> (executable: String, arguments: [String], unsetEnvironment: [String]) {
        switch r.harness {
        case .codex:
            let effort = ["-m", r.model, "-c", "model_reasoning_effort=\(r.effort)"]
            let tail = ["--skip-git-repo-check", "--output-schema", r.schemaFile.path]
            if let s = r.resumeSessionID {
                // `exec resume` has no -s flag, and IGNORES the session's recorded model unless
                // -m is passed again (observed 2026-09-26: luna → terra). Pin both.
                return ("codex", ["exec", "resume", "--json"] + effort + ["-c", "sandbox_mode=\"read-only\""] + tail + [s, r.prompt], [])
            }
            return ("codex", ["exec", "--json"] + effort + ["-s", "read-only"] + tail + [r.prompt], [])
        case .claude:
            var args = ["-p", r.prompt, "--model", r.model, "--effort", r.effort, "--output-format", "json",
                        "--json-schema", r.schemaJSON, "--allowedTools", claudeReadOnlyTools]
            for d in r.readableDirs { args += ["--add-dir", d.path] }
            if let s = r.resumeSessionID { args += ["--resume", s] }
            // Without these unset, a claude spawned from inside Claude Code silently skips
            // saving its transcript — and then `--resume` has nothing to resume.
            return ("claude", args, ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"])
        }
    }
}

public enum HarnessOutput {
    public enum ParseError: Error, Equatable { case noSession, noResult, notJSON(String) }

    public static func parse(_ harness: Harness, stdout: Data) throws -> (sessionID: String, structured: Data) {
        switch harness {
        case .codex:
            var session: String?, text: String?
            for line in stdout.split(separator: UInt8(ascii: "\n")) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if obj["type"] as? String == "thread.started" { session = obj["thread_id"] as? String }
                if obj["type"] as? String == "item.completed",
                   let item = obj["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                    text = item["text"] as? String
                }
            }
            guard let session else { throw ParseError.noSession }
            guard let text else { throw ParseError.noResult }
            let data = Data(text.utf8)
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw ParseError.notJSON(text) }
            return (session, data)
        case .claude:
            guard let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
                throw ParseError.notJSON(String(decoding: stdout.prefix(400), as: UTF8.self))
            }
            guard let session = obj["session_id"] as? String else { throw ParseError.noSession }
            if let structured = obj["structured_output"] {
                return (session, try JSONSerialization.data(withJSONObject: structured))
            }
            guard let text = obj["result"] as? String else { throw ParseError.noResult }
            let data = Data(text.utf8)
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { throw ParseError.notJSON(text) }
            return (session, data)
        }
    }
}
```

- [ ] **Step 5: Run the suite and confirm it passes.**
- [ ] **Step 6: Commit.**
  `feat: build read-only headless codex and claude runs and parse their output`

### Task 13: Triage prompt, schema and result

**Files:**
- Create: `Sources/IntakeKit/Triage.swift`
- Test: `Tests/FlightDeckTests/Intake/TriageTests.swift`

**Interfaces:**
- Produces:
  - `TriageResult` (`.questions([String])`,
    `.recommendation(preset: Preset, reason: String, changeSet: ChangeSet?)`);
  - `Triage.schemaJSON: String`;
  - `Triage.initialPrompt(intent:graphFile:triageFile:agentsFile:readmeFile:) -> String`;
  - `Triage.answersPrompt(questions:answers:) -> String`;
  - `Triage.encodeNowPrompt() -> String`;
  - `Triage.decode(_ data: Data) throws -> TriageResult`.

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
import IntakeKit

final class TriageTests: XCTestCase {
    func testDecodesQuestions() throws {
        let d = Data(#"{"kind":"questions","questions":["Mac only?"],"preset":null,"reason":null,"changeSet":null}"#.utf8)
        XCTAssertEqual(try Triage.decode(d), .questions(["Mac only?"]))
    }
    func testDecodesBeadRecommendationWithChangeSet() throws {
        let d = Data(#"""
        {"kind":"recommendation","questions":null,"preset":"bead","reason":"one file",
         "changeSet":{"graphObservedAt":"2026-09-26T20:00:00Z","ops":[
          {"op":"createBead","tempId":"n1","title":"T","type":"task","priority":2,"description":"d","acceptance":null,"labels":[],
           "from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null}]}}
        """#.utf8)
        guard case .recommendation(let p, _, let cs) = try Triage.decode(d) else { return XCTFail() }
        XCTAssertEqual(p, .bead); XCTAssertEqual(cs?.ops.count, 1)
    }
    func testProseOutputFails() {
        XCTAssertThrowsError(try Triage.decode(Data("Sure, here's my plan".utf8)))
    }
    func testQuestionsKindWithoutQuestionsFails() {
        XCTAssertThrowsError(try Triage.decode(Data(#"{"kind":"questions","questions":null,"preset":null,"reason":null,"changeSet":null}"#.utf8)))
    }
    func testSchemaIsValidJSONAndStrict() throws {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(Triage.schemaJSON.utf8)) as? [String: Any])
        XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(obj["required"] as? [String] ?? []), ["kind", "questions", "preset", "reason", "changeSet"])
    }
    func testPromptNamesTheInputFiles() {
        let p = Triage.initialPrompt(intent: "I", graphFile: "/i/graph.json", triageFile: "/i/bv.json",
                                     agentsFile: "/p/AGENTS.md", readmeFile: nil)
        XCTAssertTrue(p.contains("/i/graph.json")); XCTAssertTrue(p.contains("/p/AGENTS.md"))
        XCTAssertTrue(p.contains("new:"))           // teaches the temp-id reference form
    }
}
```

- [ ] **Step 2: Run the suite and confirm it fails.**

- [ ] **Step 3: Implement `Triage.swift`.** The schema is **strict**: every object has
  `additionalProperties: false`, every property is in `required`, and optional values are
  typed `[<type>, "null"]`. Codex's `--output-schema` and Claude's `--json-schema` both
  accept this shape, which Step 5 verifies live.

```swift
import Foundation

public enum TriageResult: Equatable, Sendable {
    case questions([String])
    case recommendation(preset: Preset, reason: String, changeSet: ChangeSet?)
}

public enum Triage {
    public struct Malformed: Error, Equatable { public let why: String }

    private static let nullableString = #"{"type":["string","null"]}"#
    private static let pre = #"{"type":["object","null"],"additionalProperties":false,"required":["status","assignee"],"properties":{"status":{"type":"string"},"assignee":{"type":["string","null"]}}}"#
    private static let op = """
    {"type":"object","additionalProperties":false,
     "required":["op","tempId","title","type","priority","description","acceptance","labels","from","to","kind","id","set","pre","delivery","reason","of"],
     "properties":{
      "op":{"type":"string","enum":["createBead","addEdge","editBead","reopen","followUp"]},
      "tempId":\(nullableString),"title":\(nullableString),"type":\(nullableString),
      "priority":{"type":["integer","null"]},"description":\(nullableString),"acceptance":\(nullableString),
      "labels":{"type":["array","null"],"items":{"type":"string"}},
      "from":\(nullableString),"to":\(nullableString),
      "kind":{"type":["string","null"],"enum":["blocks","related","parent-child",null]},
      "id":\(nullableString),
      "set":{"type":["object","null"],"additionalProperties":false,"required":["title","description","acceptance","priority"],
             "properties":{"title":\(nullableString),"description":\(nullableString),"acceptance":\(nullableString),"priority":{"type":["integer","null"]}}},
      "pre":\(pre),
      "delivery":{"type":["object","null"],"additionalProperties":false,"required":["rating","reason"],
                  "properties":{"rating":{"type":"string","enum":["clarifying","scopeChange","invalidating"]},"reason":{"type":"string"}}},
      "reason":\(nullableString),"of":\(nullableString)}}
    """

    public static let schemaJSON = """
    {"type":"object","additionalProperties":false,
     "required":["kind","questions","preset","reason","changeSet"],
     "properties":{
      "kind":{"type":"string","enum":["questions","recommendation"]},
      "questions":{"type":["array","null"],"items":{"type":"string"}},
      "preset":{"type":["string","null"],"enum":["bead","sketch","featurePlan","fullPlan",null]},
      "reason":\(nullableString),
      "changeSet":{"type":["object","null"],"additionalProperties":false,"required":["graphObservedAt","ops"],
                   "properties":{"graphObservedAt":{"type":"string"},"ops":{"type":"array","items":\(op)}}}}}
    """

    private struct Wire: Decodable {
        let kind: String; let questions: [String]?; let preset: Preset?; let reason: String?; let changeSet: ChangeSet?
    }

    public static func decode(_ data: Data) throws -> TriageResult {
        let w: Wire
        do { w = try IntakeJSON.decoder.decode(Wire.self, from: data) }
        catch { throw Malformed(why: "not triage JSON: \(error)") }
        switch w.kind {
        case "questions":
            guard let q = w.questions, !q.isEmpty else { throw Malformed(why: "questions kind with no questions") }
            return .questions(q)
        case "recommendation":
            guard let p = w.preset, let r = w.reason else { throw Malformed(why: "recommendation without preset/reason") }
            return .recommendation(preset: p, reason: r, changeSet: w.changeSet)
        default:
            throw Malformed(why: "unknown kind \(w.kind)")
        }
    }
}
```

  Also add `public static func initialPrompt(...)`, `answersPrompt(...)` and
  `encodeNowPrompt()` as described below. `Preset` must be `Codable` with raw values
  `bead`, `sketch`, `featurePlan` and `fullPlan` (Task 11).

  The initial prompt must state, in plain words:
  1. its role: triage an intent against a live bead graph;
  2. the read-only rule: never run `br` commands that write;
  3. the input files by absolute path;
  4. the decision rule: ask questions **only** when an answer would change the change set;
  5. the four presets, with one line each from spec §3;
  6. at Bead fidelity, return the full change set;
  7. change-set rules:
     - reference new beads as `new:<tempId>`;
     - edge direction: `from` depends on `to`;
     - include `pre` copied exactly from the graph for every existing bead touched;
     - rate every edit to an `in_progress` bead as clarifying, scopeChange or invalidating,
       with a reason;
     - for work on a closed bead, use `followUp`, unless the closed work was wrong, in which
       case use `reopen` with the reason;
     - check for duplicates against open **and** closed beads.

  `answersPrompt` restates the questions with the user's answers and asks for a
  recommendation. `encodeNowPrompt` says: "Encode this intent now at Bead fidelity as a
  single pass, regardless of your recommended preset; return kind=recommendation, preset=bead
  with the full changeSet."

- [ ] **Step 4: Run the suite and confirm it passes.**

- [ ] **Step 5: Live schema probe.** Run once; it costs a few cents. Write
  `Triage.schemaJSON` to a scratch file, then in a scratch git repo run:
  - `codex exec --json -m gpt-5.6-luna -c model_reasoning_effort=low -s read-only
    --skip-git-repo-check --output-schema <file> "Intent: add a README badge. There is no
    graph; return kind=questions with one question."`
  - The same with `env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE claude -p ... --model
    haiku --output-format json --json-schema "$(cat <file>)"`.

  Both must exit 0, and `HarnessOutput.parse` + `Triage.decode` must accept their stdout.
  If codex rejects the schema as non-strict, fix the schema, not the parser. Save the two
  outputs as fixtures `triage-codex-live.jsonl` and `triage-claude-live.json`, and add a test
  that decodes both.

- [ ] **Step 6: Commit.** `feat: define the triage prompt and its strict output schema`

### Task 14: BeadWriter (release to `br`)

**Files:**
- Create: `Sources/FlightDeck/Intake/BeadWriter.swift`
- Create: `Sources/FlightDeck/Intake/IntakeGraphReader.swift`
- Test: `Tests/FlightDeckTests/Intake/BeadWriterTests.swift` (fake runner), plus
  `Tests/FlightDeckTests/Intake/BeadWriterLiveTests.swift` (real `br`; skipped when `br`
  isn't on PATH)

**Interfaces:**
- Consumes: `FlywheelProcessRunner` (`Sources/FlightDeck/Flywheel/FlywheelProcessRunner.swift`,
  signature `run(_:_:cwd:) async throws -> (stdout: String, exitCode: Int32)`), and
  `ApplyStep` / `GraphSnapshot`.
- Produces:
  - `IntakeGraphReader(runner:brPath:)` with `.read(project:) async throws -> GraphSnapshot`,
    which runs `br list --all --json` and `br graph --all --json` in the project directory;
  - `BeadWriter(runner:brPath:actor:)` with
    `.apply(_ steps: [ApplyStep], project: String) async -> BeadWriter.Outcome`;
  - `Outcome { applied: Int; idMap: [String: String]; error: String? }`. `error` is non-nil
    when a step failed or a recheck no longer matches, and nothing after that step runs.

- [ ] **Step 1: Write the failing tests** (fake runner). Model the fake on `MultiRunner`
  from the Observe branch (`Tests/FlightDeckTests/Flywheel/Observe/ObserveTestSupport.swift`).
  It records argv and returns canned replies keyed by `[exe] + args.prefix(2)`.

```swift
@MainActor
final class BeadWriterTests: XCTestCase {
    func testCreateThenDependResolvesTempIds() async {
        let r = RecordingRunner(replies: [
            "br create": (#"{"id":"b9"}"#, 0), "br dep": ("", 0)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "flightdeck-intake:X")
        let out = await w.apply([.create(NewBead(tempId: "n1", title: "T", description: "d")),
                                 .depend(dependent: .new("n1"), dependency: .existing("b1"), kind: .blocks)], project: "/p")
        XCTAssertNil(out.error); XCTAssertEqual(out.applied, 2); XCTAssertEqual(out.idMap, ["n1": "b9"])
        XCTAssertEqual(r.calls[1], ["br", "dep", "add", "b9", "b1", "--type", "blocks", "--actor", "flightdeck-intake:X"])
    }
    func testFailureMidwayRecordsPartial() async {
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br dep": ("database is locked", 1)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "a")
        let out = await w.apply([.create(NewBead(tempId: "n1", title: "T", description: "d")),
                                 .depend(dependent: .new("n1"), dependency: .existing("b1"), kind: .blocks),
                                 .update(id: "b1", set: FieldSet(title: "x"))], project: "/p")
        XCTAssertEqual(out.applied, 1)
        XCTAssertTrue(out.error?.contains("dep") == true)
        XCTAssertEqual(r.calls.count, 2)                // stopped; never reached update
    }
    func testRecheckMismatchStops() async {
        let r = RecordingRunner(replies: ["br show": (#"[{"id":"b1","title":"t","status":"in_progress","assignee":"X"}]"#, 0)])
        let w = BeadWriter(runner: r, brPath: "br", actor: "a")
        let out = await w.apply([.recheck(id: "b1", pre: Precondition(status: "open", assignee: nil)),
                                 .update(id: "b1", set: FieldSet(title: "x"))], project: "/p")
        XCTAssertEqual(out.applied, 0); XCTAssertNotNil(out.error)
    }
}
```

Define `RecordingRunner` in the test file as a class conforming to `FlywheelProcessRunner`
and `@unchecked Sendable`. It holds `calls: [[String]]` and `replies: [String: (String, Int32)]`,
keyed by `"\(exe) \(args[0])"`, and returns `("", 127)` when there's no reply.

The live test (`BeadWriterLiveTests`) skips unless `which br` succeeds. It creates a scratch
repo **under `$HOME`** (`~/.fd-intake-test-<uuid>`, removed in `tearDown`) and runs
`br init`. It then applies create → depend → update → reopen, and asserts the result with
`IntakeGraphReader.read`.

- [ ] **Step 2: Run the suite and confirm it fails.**

- [ ] **Step 3: Implement.** For each step, `BeadWriter.apply` runs `br` with `cwd:
  project`, appending `--actor <actor>` to every write:
  - `.create(b)` → `br create --title <t> -t <type> -p <prio> --description <d>
    [--acceptance <a>] [-l <labels,joined>] --json`, decoding `{"id":...}` into
    `idMap[b.tempId]`;
  - `.depend` → `br dep add <resolved dependent> <resolved dependency> --type <kind.rawValue>`;
  - `.update(id, set)` → `br update <id>` plus only the non-nil flags (`--title`,
    `--description`, `--acceptance-criteria`, `-p`);
  - `.reopen(id, reason)` → `br reopen <id>`, then `br comments add <id> "Reopened by Flight
    Deck intake: <reason>"`. Before this is written, check `br comments add --help`; if
    that verb doesn't exist, fall back to appending the reason to the description with
    `br update --description`;
  - `.recheck(id, pre)` → `br show <id> --json`, decoded as `[BeadSnapshot-shaped]`. It
    fails when the bead is missing or when `pre` is non-nil and doesn't match.

  The first non-zero exit or mismatch ends the loop, and the error text is `"<step
  description>: <first line of stdout>"`. After a fully successful apply, run
  `br sync --flush-only` (check the exact flag with `br sync --help` first). Don't count it
  as a step.

  The runner discards stderr, so an error message may be empty. If it is, the error text
  still names the step and the exit code.

- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.** `feat: write released change sets to br in plan order`

### Task 15: Delivery to holders of affected beads

**Files:**
- Create: `Sources/IntakeKit/DeliveryPlanner.swift` (pure)
- Create: `Sources/FlightDeck/Intake/IntakeDelivery.swift` (side effects)
- Test: `Tests/FlightDeckTests/Intake/DeliveryPlannerTests.swift`

**Interfaces:**
- Produces, in IntakeKit:
  - `DeliveryAction`, with the cases:
    - `.mail(to: String, bead: String, subject: String, body: String, urgent: Bool)`
    - `.inject(agent: String, bead: String, text: String)`
    - `.reclaim(bead: String, agent: String)`
  - `DeliveryPlanner.plan(_:ratings:hasSession:) -> [DeliveryAction]`. `ratings` is the
    final rating for each edit-op index (agent rating plus user override). `hasSession` is
    `(String) -> Bool`, keyed by agent name.
- Produces, in the app: `IntakeDelivery(runner:amPath:brPath:store:)` with
  `.deliver(_ actions: [DeliveryAction], project: String, intakeID: UUID) async -> [String]`,
  which returns one human-readable warning per action that failed.

- [ ] **Step 1: Write the failing tests.**

```swift
import XCTest
import IntakeKit

final class DeliveryPlannerTests: XCTestCase {
    let pre = Precondition(status: "in_progress", assignee: "BlueFalcon")
    func cs(_ rating: DeliveryRating) -> ChangeSet {
        ChangeSet(graphObservedAt: .init(timeIntervalSince1970: 0), ops: [
            .editBead(id: "b1", set: FieldSet(acceptance: "more"), pre: pre, delivery: Delivery(rating: rating, reason: "why"))])
    }
    func testClarifyingIsMailOnly() {
        let a = DeliveryPlanner.plan(cs(.clarifying), ratings: [0: .clarifying], hasSession: { _ in true })
        XCTAssertEqual(a.count, 1); guard case .mail(let to, "b1", _, _, false) = a[0] else { return XCTFail() }
        XCTAssertEqual(to, "BlueFalcon")
    }
    func testScopeChangeInjectsAndMails() {
        let a = DeliveryPlanner.plan(cs(.scopeChange), ratings: [0: .scopeChange], hasSession: { _ in true })
        XCTAssertEqual(a.map(\.kindName), ["inject", "mail"])
    }
    func testInvalidatingReclaimsInjectsAndMailsUrgent() {
        let a = DeliveryPlanner.plan(cs(.invalidating), ratings: [0: .invalidating], hasSession: { _ in true })
        XCTAssertEqual(a.map(\.kindName), ["reclaim", "inject", "mail"])
        guard case .mail(_, _, _, _, true) = a[2] else { return XCTFail("invalidating mail must be urgent") }
    }
    func testHolderWithoutSessionGetsMailOnly() {
        let a = DeliveryPlanner.plan(cs(.scopeChange), ratings: [0: .scopeChange], hasSession: { _ in false })
        XCTAssertEqual(a.map(\.kindName), ["mail"])
    }
    func testUserOverrideWins() {
        let a = DeliveryPlanner.plan(cs(.invalidating), ratings: [0: .clarifying], hasSession: { _ in true })
        XCTAssertEqual(a.map(\.kindName), ["mail"])
    }
}
```

- [ ] **Step 2: Run the suite and confirm it fails.**

- [ ] **Step 3: Implement.** `DeliveryAction.kindName` returns `"mail"`, `"inject"` or
  `"reclaim"`.

  **Planner.** Only `editBead` ops whose `pre.status == "in_progress"` and whose
  `pre.assignee` is non-nil produce actions. Reclaim is only planned when `hasSession` is
  true; for an agent with no FD session there is no way to stop it, so it's mail only.
  - **Inject text:** "Flight Deck intake changed <bead> while you are working on it
    (<rating>): <reason>. Run `br show <bead>`, compare it with what you have done, and
    adjust — or reply on the Agent Mail thread bead:<bead> explaining why not."
  - **Reclaim + inject text:** "Stop work on <bead>: <reason>. It has been reclaimed and
    returned to open."

  **`IntakeDelivery`:**
  - It gets FD's Agent Mail name from `FlywheelCoordinator.boot(project:program:model:name:)`,
    with program `flightdeck` and model `n/a`, on first use per project. It caches the
    result in `<intakes root>/agent-mail-identities.json` as `{projectPath: agentName}`, and
    never passes a name, so `am` assigns a valid one.
  - `.mail` → `am mail send --project <p> --from <fd> --to <agent> --subject <s> --body <b>
    --thread-id bead:<id> --topic fd-intake [--importance high --ack-required]`.
  - `.inject` → through a closure `(agentName, text) -> Bool` supplied by `IntakeService`,
    which calls `SessionStore.submitPrompt(_:token:to:)`. The token is deterministic, so a
    retried release doesn't inject twice (`submitPrompt` returns `.duplicate`):

```swift
import CryptoKit
static func injectToken(intake: UUID, bead: String) -> UUID {
    let d = Array(SHA256.hash(data: Data("\(intake.uuidString)|\(bead)".utf8)))
    return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                       d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
}
```
  - `.reclaim` → `br update <bead> --status open --assignee "" --actor
    flightdeck-intake:<id>`, then `am file_reservations release <project> <agent>`.

  A reservation-release failure is a warning, not an error. `am` may refuse to release
  another agent's reservations; the warning text quotes the first line of its output.

- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Commit.**
  `feat: tell the holders of changed beads, graded by how much the change matters`

### Task 16: IntakeService (orchestration)

**Files:**
- Create: `Sources/FlightDeck/Intake/IntakeService.swift`
- Create: `Sources/FlightDeck/Intake/HeadlessRunner.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift`. Add a lazy `intakeService`, mirroring
  the lazy `observeService` (`private(set) lazy var observeService: FlywheelObserveService`).
- Test: `Tests/FlightDeckTests/Intake/IntakeServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 8–15.
- Produces:
  - `HeadlessRunner` (protocol) with `run(_ command: (executable: String, arguments:
    [String], unsetEnvironment: [String]), cwd: URL) async throws -> (stdout: Data,
    stderr: String, exitCode: Int32)`, and `SystemHeadlessRunner`. The latter is like
    `SystemFlywheelProcessRunner`, but it captures stderr, applies `unsetEnvironment` to
    `ProcessInfo.processInfo.environment`, sets stdin to `/dev/null`, and cancels on
    `Task` cancellation.
  - `@MainActor final class IntakeService: ObservableObject`, with:
    - `@Published private(set) var intakes: [Intake]` (all projects);
    - `func intakes(forProject path: String) -> [Intake]`;
    - `func attentionCount(forProject path: String) -> Int`;
    - `func capture(intent: String, project: String)`, which creates, saves and starts
      triage;
    - `func answer(_ id: UUID, answers: [String])`;
    - `func choose(_ id: UUID, preset: Preset)`: `.bead` → an encode-now turn when there's
      no change set yet, otherwise go to `.review`; any other preset → `.parked`;
    - `func reviewModel(_ id: UUID) async -> ReleaseReview?`, which reads the current graph
      and classifies drift;
    - `func setRating(_ id: UUID, op: Int, _ r: DeliveryRating)`, `func drop(_ id: UUID, op:
      Int)` and `func confirmDrift(_ id: UUID, op: Int)`;
    - `func release(_ id: UUID) async`;
    - `func retry(_ id: UUID)`;
    - `func discard(_ id: UUID)`.
  - `ReleaseReview { intake; drift: [OpDrift]; summary: String; canRelease: Bool }`.
    `canRelease` is false while any `.drifted` op is neither confirmed nor dropped.
- **Triage settings** for this plan: the harness is codex when `which codex` succeeds,
  otherwise claude. The model/effort defaults are codex `gpt-6-sol`/`high` and claude
  `opus`/`high`. Detection-driven defaults come in the next plan (spec §6.2); leave a
  `// Detection-driven defaults: next plan (spec §6.2).` comment.
- **Inputs per triage run.** Written into `store.directory(for: id)/triage/`:
  - `graph.json`, the encoded `GraphSnapshot` (add `Codable` conformance in IntakeKit);
  - `bv.json`, the stdout of `bv --robot-triage`, or `{}` if it fails;
  - `schema.json`, which is `Triage.schemaJSON`.
- **Launch recovery:** any intake found in `.triaging` or `.releasing` becomes
  `.interrupted`.

- [ ] **Step 1: Write the failing tests** with fakes: a `FakeHeadlessRunner` returning
  canned stdout per call; the `RecordingRunner` from Task 14 for `br`/`am`; and a
  temp-directory `IntakeStore`.
  - `testCaptureRunsTriageAndStoresQuestions`: triage returns `kind=questions`, so the
    state becomes `.needsAnswers` with one exchange.
  - `testAnswerResumesSameSessionWithModelPinned`: the second call's argv contains
    `resume` and the first call's session id, plus `-m`.
  - `testBeadRecommendationGoesToReview`.
  - `testNonBeadChoiceParks`.
  - `testMalformedTriageFailsAndKeepsRawOutput`: prose stdout leads to `.failed`, with
    `rawFailureOutput` set.
  - `testInvalidChangeSetFails`: a change set with a dangling `new:` ref leads to
    `.failed`, and the failure names the validation error.
  - `testReleaseBlockedUntilDriftResolved`: the current graph differs from `pre`, so
    `canRelease` is false; after `confirmDrift` it's true.
  - `testInterruptedOnRelaunch`: a saved `.triaging` intake is `.interrupted` after a new
    service is built on the same store.

- [ ] **Step 2: Run the suite and confirm it fails.**

- [ ] **Step 3: Implement.** Each intake gets at most one live `Task`, kept in
  `[UUID: Task<Void, Never>]`. Every state change goes through `save(_:)`, which writes to
  the store and then republishes `intakes`.

  **`release`:**
  1. Re-read the graph and re-validate the change set against the *current* graph. An
     `unknownBead` error becomes a drop, and the review shows it as impossible.
  2. `ApplyPlanner.plan(v, skipping: droppedOps ∪ impossible)`.
  3. Set the state to `.releasing` and save.
  4. `BeadWriter.apply`.
  5. `DeliveryPlanner.plan` with the ratings (overrides applied), and `hasSession` checking
     `store.session(project:agentName:) != nil`.
  6. `IntakeDelivery.deliver`.
  7. Record a `ReleaseRecord`. The state becomes `.released`, or `.partiallyReleased` if
     the writer returned an error.

- [ ] **Step 4: Run the suite and confirm it passes.**

- [ ] **Step 5: Wire it into `SessionStore`.** Add the lazy `intakeService`, built with the
  store root `(FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
  .appendingPathComponent("intakes")`, the system runners, and an inject closure calling
  `submitPrompt`. Construct it lazily, so a test host that never touches intakes never
  creates the directory.

- [ ] **Step 6: Commit.**
  `feat: orchestrate intake triage, review and release`

### Task 17: The Intakes list and detail in ProjectView

**Files:**
- Modify: `Sources/FlightDeck/ProjectView.swift`
- Create: `Sources/FlightDeck/Intake/IntakeDetailView.swift`
- Create: `Sources/FlightDeck/Intake/IntakeStatePill.swift`
- Test: `Tests/FlightDeckTests/Intake/IntakeStatePillTests.swift` (the pure label and
  colour mapping)

**Interfaces:**
- Consumes: `IntakeService` (Task 16).
- Produces:
  - `IntakeStatePill.label(for: IntakeState) -> String`, returning "triaging", "needs
    answers", "choose fidelity", "parked", "review", "releasing", "released · N beads",
    "partial", "failed", "interrupted" or "discarded";
  - `IntakeStatePill.tint(for:) -> Color`: attention states are orange, triaging and
    releasing are accent, released is green, and the rest are secondary. This matches
    `SessionStatusIcon`'s language (waiting = orange).

- [ ] **Step 1: Write the failing pill-mapping test.** Cover every case of
  `IntakeState` and assert each label. `released` interpolates `release.appliedSteps`
  as N.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.**
  - **`ProjectView`:** the header, a `List` of `store.intakeService.intakes(forProject:
    repo.url.path)` rows (pill + intent, one line, truncated), then a multi-line
    `TextEditor` "Describe what you want…". ⌘↩ (`.keyboardShortcut(.return, modifiers:
    .command)` on a Triage button) calls `capture`. Selecting a row shows
    `IntakeDetailView` in the right half of an `HSplitView`.
  - **`IntakeDetailView`, by state:**

    | State | Shows |
    |---|---|
    | `.triaging` | A spinner plus the harness/model |
    | `.needsAnswers` | One `TextField` per question, and a "Send answers" button |
    | `.awaitingChoice` | The recommendation and reason, a preset `Picker`, and "Continue" (Bead encodes; others park with the note "Planning rounds arrive with the round engine") |
    | `.review` | "Open release review" |
    | `.failed` / `.interrupted` | The failure text, a `DisclosureGroup` holding `rawFailureOutput`, and Retry / Discard |
    | `.released` / `.partiallyReleased` | The record summary and any delivery warnings |

  - Accessibility identifiers: `"intake-intent-field"`, `"intake-row"`,
    `"intake-detail"`.
- [ ] **Step 4: Run the suite and confirm it passes.** Then build the app with
  `./scripts/build.sh`; expected: it succeeds. **Do not launch it.**
- [ ] **Step 5: Commit.** `feat: list and drive intakes from the project view`

### Task 18: Release review sheet

**Files:**
- Create: `Sources/FlightDeck/Intake/ReleaseReviewView.swift`
- Create: `Sources/IntakeKit/ReleaseSummary.swift` (a pure summary string)
- Test: `Tests/FlightDeckTests/Intake/ReleaseSummaryTests.swift`

**Interfaces:**
- Produces: `ReleaseSummary.text(_ v: ValidatedChangeSet, drift: [OpDrift], dropped:
  Set<Int>, ratings: [Int: DeliveryRating], hasSession: (String) -> Bool) -> String`. Its
  shape is `"Release 3 beads · 1 held edge · 2 notices (1 inject, 1 mail)"`. Words are
  singular or plural by count, and zero-count segments are omitted.

- [ ] **Step 1: Write the failing tests.** Cover three cases: one create with a held edge
  and a scopeChange edit whose holder has a session (expected `"Release 1 bead · 1 held
  edge · 2 notices (1 inject, 1 mail)"`), a change set that is entirely dropped (expected
  `"Nothing to release"`), and the singular and plural wording.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement the summary.** Then build the view. It is a sheet on `ProjectView`
  (`.sheet(item:)` bound to a selected `ReleaseReview`), and it lists ops grouped by kind:
  - **New beads:** title and tempId.
  - **Edges:** `dependent → dependency`, drawn dashed with the tag "held" when the op is
    in `heldOpIndices`.
  - **Edits:** a field diff of set values against the current bead.
  - **In-progress edits:** the holder, a rating `Picker` (`setRating`), and the planned
    delivery. When there's no session, it reads "no FD session — mail only".
  - **Reopens / follow-ups:** the reason.

  Rows with `.drifted` are highlighted orange, with the reason and "Confirm" / "Drop"
  buttons. `.impossible` rows are struck through with the reason. The footer shows
  `ReleaseSummary.text` and a **Release** button that is disabled unless `canRelease`, and
  which calls `service.release`. The accessibility identifier is `"release-review"`. A
  graph rendering of the change set arrives with the Beads tab in the next plan; add a
  `// Graph view: next plan (spec §8.4, phase 4).` comment.
- [ ] **Step 4: Run the suite and confirm it passes.** Build with `./scripts/build.sh`.
- [ ] **Step 5: Commit.** `feat: review a change set's drift and deliveries before release`

### Task 19: Project rollup, docs, GUI checklist

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`collapsedStatus(forProjectAt:)`)
- Modify: `Sources/FlightDeck/ProjectHeaderRow.swift`. Show the status icon when an intake
  needs attention even while expanded: an orange `questionmark.circle.fill` with a tooltip
  "N intake(s) need you".
- Modify: `docs/ARCHITECTURE.md` (a new "Intake" section), `docs/FOLLOWUPS.md`
  (in-process triage is lost on quit, which the next plan's runner fixes; `br` has no
  `--if-version`; the Beads tab and graph review come next).
- Create: `docs/FLYWHEEL-INTAKE-CHECKLIST.md` (Nate's GUI checklist)
- Test: `Tests/FlightDeckTests/Intake/IntakeRollupTests.swift`

**Interfaces:**
- Consumes: `IntakeService.attentionCount(forProject:)`.

- [ ] **Step 1: Write the failing test.** Given a store whose `intakeService` holds one
  `.needsAnswers` intake for project P and no busy sessions, `collapsedStatus(forProjectAt:
  P)` returns `.waiting`, with `waitingFor` containing `"1 intake"`.
- [ ] **Step 2: Run the suite and confirm it fails.**
- [ ] **Step 3: Implement.** In `collapsedStatus`, if `attentionCount > 0`, include the
  synthetic status `SessionStatus(activity: .waiting, waitingFor: "\(n) intake\(n == 1 ?
  "" : "s") need\(n == 1 ? "s" : "") you", subagentCount: 0, answerless: false)` among the
  candidates before the `max`.
- [ ] **Step 4: Run the suite and confirm it passes.**
- [ ] **Step 5: Write the checklist.** Each item is a numbered action with the expected
  result:
  1. Click a project row, and the Intakes view opens.
  2. Click the chevron, and the project collapses without selecting.
  3. Drag a header, and it reorders.
  4. Type an intent in `~/fw-functest` (a real non-temp flywheel project).
  5. Answer the triage questions.
  6. Accept Bead.
  7. Open the review.
  8. In another terminal, `br update <bead> --assignee X --status in_progress` on a bead
     the change set edits, then reopen the review. The op is flagged, and Release is
     disabled until you confirm.
  9. Release. `br list` shows the beads, and the edges are correct with `br graph`.
  10. For a scopeChange op, the holder's tab gets the inject and `am inbox` shows the
      mail.
  11. Quit FD mid-triage and relaunch. The intake is interrupted, and Retry works.
- [ ] **Step 6: Commit** the code, docs and checklist:
  `feat: surface intakes that need you in the project rollup`

---

## Next plan (not in scope here)

Spec phases 4–9: the Beads tab and graph review, the runner under fd-abduco
(`intake-<uuid>.sock`, which is invisible to today's `liveSessionIDs` because it only
parses `<uuid>.sock`, plus a `.json` sidecar), the round engine and tape, branches,
materialization and the polish revert check, and the oracle/grok/gemini runners and
detection.

Correction to spec §7: Debug and Release **already** use separate daemon directories
(`/tmp/flight-deck-debug-<uid>` vs `/tmp/flight-deck-<uid>`, `SessionDaemon.defaultDirectory`),
so the "channel" reconcile rule is unnecessary.
