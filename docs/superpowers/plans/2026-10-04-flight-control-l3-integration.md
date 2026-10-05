# Flight Control Level 3 Integration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Join the four parallel Level 3 branches (L3-R routing, L3-I capability index, L3-U usage
and rollover, L3-S swarm) into one working Flight Control: real conformers in place of the
fakes, one Settings tab, meters mounted on the swarm surfaces, and an end-to-end test that runs
a swarm through routing, leasing and a hand-off.

**Architecture:** An `l3-integration` branch off master (L3-0 already merged). Each sub-branch
merges into it in a fixed order, and conflicts are resolved by the rules below. Then a small
`FlightControlComposition` type builds the real object graph once and hands it to `SessionStore`,
replacing each branch's stand-in (`NullCapabilityIndex`, `NoRuleHints`, `DefaultPoolDirectory`,
`MinimalMeter`, the unset `swarmDependencies`/hand-off hooks). One merge to master at the end.

**Tech Stack:** Swift 6 (IntakeKit), Swift 5 mode (app), SwiftUI, XCTest, XCUITest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-04-flight-control-l3-overview-contract-design.md` §2
("Integration"), plus each sub-spec's "Provides at integration" section. The sub-plans are
`2026-10-04-flight-control-l3-{r-routing,i-capability-index,u-usage-rollover,s-swarm}.md`; each
ends with a "Provided at integration" note in its spec and FOLLOWUPS that this plan consumes.

## Global Constraints

- Start only when L3-0 is on master and all four sub-branches have finished their own final task
  (full suite green, spec "as built" notes written).
- The sub-branches merge into `l3-integration`, never directly into master.
- Merge order: L3-R, L3-I, L3-U, L3-S. Routing first because it owns the Settings tab and the
  `PoolDirectory`/`RuleHintSource` seams the others plug into.
- **The names in this plan come from the sub-plans.** A sub-branch may have deviated while it was
  built; the "as built" section of its spec is authoritative. Each task starts with an `rg` step
  that confirms the names it uses; when one differs, use the built name and say so in the commit.
- Conflicts are resolved by **keeping every branch's additions**, never by picking a side, except
  where a task below says to delete a stand-in.
- After every merge: `./scripts/test-unit.sh 2>&1 | tee /tmp/l3-int.log | tail -3` must end
  `** SHARDED UNIT RUN PASSED`, and `rg -n "error:" /tmp/l3-int.log` must print nothing. A filtered
  run (`FD_TEST_FILTER=…`) ends with xctest's `Executed N tests, with 0 failures` instead.
- FleetKit or FlightDeckMobile changed → also `./scripts/build-ios.sh` and `./scripts/test-ios.sh`.
- UI test scripts take the foreground. Before each one, warn the maintainer with a PushNotification about
  10 s ahead. Run each script once; never loop one (AGENTS.md rule 4).
- Never launch a bundle from `DerivedData/`. Never swap `/Applications` (release is the maintainer's call).
- UI copy: *tasks*, *agent*, *Flight Control*. `TerminologyGuardTests` must stay green.
- Commits: lowercase, behavioral, imperative; trailer
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`; commit by path; never `git stash`.
- `git diff master...HEAD -- vendor` must be empty before the final merge.

## Review Focus

- **A pool deleted in Settings while a task's block still names it.** The swarm must show that
  task as waiting with "pool <id> no longer exists" and must not crash or spill silently. Pinned by
  `testDeletedPoolMakesTaskWaitWithReason` in Task 5.
- **The index snapshot changes while a hint is dismissed.** The hint must come back once, and only
  for the new snapshot. Pinned by `testDismissedHintReturnsOnNewSnapshot` in Task 3.
- **A hand-off fires while the swarm is paused.** Pause stops new claims, not hand-offs: a paused
  swarm must still hand off an agent that crosses hard. Pinned by
  `testPausedSwarmStillHandsOff` in Task 5.
- **Settings opened on a machine with no `br`/`am`/`codex`.** Every section must render with its
  "unavailable" text, not a blank pane. Pinned by `testFlightControlTabRendersEverySectionWithNoTools`
  in Task 2.
- **The same account in two pools, one over soft.** A lease from the other pool must also refuse
  it: the meter is per account. Pinned by `testSharedAccountRefusedInBothPools` in Task 5.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/FlightDeck/FlightControl/FlightControlComposition.swift` | builds the real Level 3 object graph once and installs it on `SessionStore` |
| `Sources/FlightDeck/FlightControl/CapabilityRuleHintSource.swift` | L3-R `RuleHintSource` backed by L3-I `CapabilityHints` |
| `Sources/FlightDeck/FlightControl/CapacityPoolDirectory.swift` | L3-R `PoolDirectory` backed by L3-U's pools |
| `Sources/FlightDeck/Preferences/UI/FlightControlSettingsTab.swift` | gains the Capability index and Capacity sections |
| `Tests/FlightDeckTests/FlightControlL3/Integration/*.swift` | composition, adapters, end-to-end |
| `docs/FLIGHT-CONTROL-L3-CHECKLIST.md` | the maintainer's task list, updated for the joined build |

---

### Task 1: Create the branch and merge the four sub-branches

**Files:** whatever the merges touch. Expected conflicts (from the sub-plans' file lists):
`Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift`, `Sources/FlightDeck/SessionStore.swift`,
`Sources/FlightDeck/FlightDeckApp.swift`, `Sources/FlightDeck/Preferences/Preferences.swift`,
`Sources/FlightDeck/Preferences/PreferencesTab.swift`, `Sources/FlightDeck/Preferences/UI/PreferencesView.swift`,
`docs/FOLLOWUPS.md`, `.gitignore`.

- [ ] **Step 1: Create the worktree and branch**

Use `superpowers:using-git-worktrees` to create `l3-integration` from master. Symlink
`vendor/ghostty-artifacts` and `vendor/boringssl-artifacts` into it. Confirm
`git log --oneline -1 master` contains the L3-0 merge (`rg -n "ExecutionBlockCodec" Sources/IntakeKit/FlightControl/ExecutionBlockCodec.swift` prints a match).

- [ ] **Step 2: Merge L3-R**

Run: `git merge --no-ff <l3-r branch>`. It should merge cleanly (it is first). Run the full suite.

- [ ] **Step 3: Merge L3-I and resolve**

Run: `git merge --no-ff <l3-i branch>`. Resolve:
- `PreferencesTab.swift`: keep L3-R's `case flightControl` and L3-I's temporary `case capabilityIndex` for now (Task 2 removes the temporary one).
- `PreferencesView.swift`: keep both tab arms.
- `SessionStore.swift`: keep both sets of additions (`routingCapabilities`, `routing`-service members from L3-R; `capabilityIndexService`, `watchClock` from L3-I).
- `FlightDeckApp.swift`: keep both.
- `docs/FOLLOWUPS.md`: keep both bullets under the Level 3 entry.

Run the full suite. Commit the merge.

- [ ] **Step 4: Merge L3-U and resolve**

Run: `git merge --no-ff <l3-u branch>`. Resolve:
- `AgentRoutingCapabilities.swift`: for `ClaudeRoutingCapabilities` and `CodexRoutingCapabilities`, keep L3-R's `modelCatalog()`/`knobSchema` bodies **and** L3-U's `usageMeterSource(account:)`/`transcriptPointer(for:)` bodies. No member may be left returning `.unsupported(reason: "filled in by L3-R")` or `"…L3-U"`. Check with `rg -n 'filled in by L3-(R|U)' Sources/` → no output.
- `PreferencesTab.swift` / `PreferencesView.swift`: keep L3-U's `case capacity` and its arm for now (Task 2 removes it).
- `Preferences.swift`: keep L3-R's `flightControlRouting` and L3-U's `capacity` fields, both decoded with defaults so an old preferences blob still loads (`rg -n "decodeIfPresent" Sources/FlightDeck/Preferences/Preferences.swift` shows both).
- `SessionStore.swift`, `FlightDeckApp.swift`, `.gitignore`, FOLLOWUPS: keep both sides.

Run the full suite, then the targeted classes that assert the exact launch environment, which L3-U changed: `FD_TEST_FILTER=AgentAccountEnvironmentTests,ToolContextTests ./scripts/test-unit.sh 2>&1 | tail -3` → `with 0 failures`. Commit the merge.

- [ ] **Step 5: Merge L3-S and resolve**

Run: `git merge --no-ff <l3-s branch>`. Resolve:
- `AgentRoutingCapabilities.swift`: keep L3-S's `resetContext(_:)` and `applying(_:to:)` bodies as well. Check with `rg -n 'filled in by L3-' Sources/` → no output.
- `SessionStore.swift`: keep L3-S's `swarmDependencies`, `lastActiveAt(for:)`, `createSession(…, overrides:)` and the swarm service members together with the others.
- Everything else: keep both sides.

Run the full suite, `./scripts/build-ios.sh` and `./scripts/test-ios.sh` (L3-S touched FleetKit and FlightDeckMobile). Commit the merge.

---

### Task 2: One Flight Control settings tab

**Files:**
- Modify: `Sources/FlightDeck/Preferences/UI/FlightControlSettingsTab.swift`
- Modify: `Sources/FlightDeck/Preferences/PreferencesTab.swift`, `Sources/FlightDeck/Preferences/UI/PreferencesView.swift`
- Delete: `Sources/FlightDeck/Preferences/UI/CapabilityIndexSettingsTab.swift`
- Modify: `UITests/FlightDeckUITests/CapabilityIndexUITests.swift`, `UITests/FlightDeckUITests/CapacityUITests.swift` (navigation only)
- Test: `Tests/FlightDeckTests/FlightControlL3/Integration/FlightControlTabIntegrationTests.swift`

**Interfaces:**
- Consumes: L3-R `FlightControlSettingsTab` with `enum Section { routing, kinds }` and identifiers `fc-section-routing`/`fc-section-kinds`; L3-I `CapabilityIndexPane(service:)`; L3-U's Capacity pane view (confirm its name with `rg -n "struct \w+: View" Sources/FlightDeck/Preferences/UI/Capacity*.swift`).
- Produces: `FlightControlSettingsTab.Section` gains `.capabilityIndex` (identifier `fc-section-index`) and `.capacity` (identifier `fc-section-capacity`); `PreferencesTab` loses `.capabilityIndex` and `.capacity`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

/// Three branches each needed a Settings home and, built in parallel, each made a temporary one.
/// The joined build has exactly one: Flight Control, with four sections. A leftover top-level
/// tab would show the same pane twice and leave one copy unmaintained.
@MainActor
final class FlightControlTabIntegrationTests: XCTestCase {
    func testOneTabFourSections() {
        XCTAssertEqual(FlightControlSettingsTab.Section.allCases.map(\.identifier),
                       ["fc-section-routing", "fc-section-kinds", "fc-section-index", "fc-section-capacity"])
        let raw = PreferencesTab.allCases.map { "\($0)" }
        XCTAssertTrue(raw.contains("flightControl"))
        XCTAssertFalse(raw.contains("capabilityIndex"))
        XCTAssertFalse(raw.contains("capacity"))
    }

    func testFlightControlTabRendersEverySectionWithNoTools() throws {
        // PATH without br/am/codex: each section must still build a body.
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "fc-int-\(UUID())")!)
        let store = SessionStore(provider: nil, persistence: nil)
        for section in FlightControlSettingsTab.Section.allCases {
            let view = FlightControlSettingsTab(preferences: prefs, sessions: store, routing: store.routing,
                                                initialSection: section)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 0, "\(section) drew nothing")
        }
    }
}
```

Before running, confirm the constructor names: `rg -n "init\(|@ObservedObject|let routing|var routing" Sources/FlightDeck/Preferences/UI/FlightControlSettingsTab.swift`, `rg -n "PreferencesStore\(" Tests/FlightDeckTests | head -3`, and `rg -n "var routing|let routing" Sources/FlightDeck/SessionStore.swift`. Adjust the test's initializer calls to the built names; keep the assertions.

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=FlightControlTabIntegrationTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: build error — `Section` has no `.capabilityIndex`, and `initialSection:` is not a parameter.

- [ ] **Step 3: Add the sections**

In `FlightControlSettingsTab.swift`, replace the `Section` enum and add the initializer parameter:

```swift
    enum Section: String, CaseIterable, Identifiable {
        case routing = "Routing"
        case kinds = "Task kinds"
        case capabilityIndex = "Capability index"
        case capacity = "Capacity"
        var id: String { rawValue }
        /// What the UI tests click.
        var identifier: String {
            switch self {
            case .routing: "fc-section-routing"
            case .kinds: "fc-section-kinds"
            case .capabilityIndex: "fc-section-index"
            case .capacity: "fc-section-capacity"
            }
        }
    }

    @State private var section: Section

    init(preferences: PreferencesStore, sessions: SessionStore, routing: RoutingService,
         initialSection: Section = .routing) {
        self.preferences = preferences; self.sessions = sessions; self.routing = routing
        _section = State(initialValue: initialSection)
    }
```

In the tab's section switch (`rg -n "switch section" Sources/FlightDeck/Preferences/UI/FlightControlSettingsTab.swift`), add:

```swift
        case .capabilityIndex:
            if let index = sessions.capabilityIndexService {
                CapabilityIndexPane(service: index)
            } else {
                Text("The capability index is not running in this window.").foregroundStyle(.secondary).padding()
            }
        case .capacity:
            CapacityPane(preferences: preferences, sessions: sessions)   // use the built name and init from Step 1's rg
```

Remove the `@State private var section: Section = .routing` line the branch had (the initializer now sets it).

- [ ] **Step 4: Remove the temporary tabs**

In `PreferencesTab.swift`, delete `case capabilityIndex` and `case capacity`. In `PreferencesView.swift`, delete their arms and tab items. Delete `CapabilityIndexSettingsTab.swift`. Run `rg -n "CapabilityIndexSettingsTab|\.capabilityIndex\b|PreferencesTab\.capacity" Sources Tests UITests` and fix every hit to go through `.flightControl` plus the section.

- [ ] **Step 5: Update the UI tests' navigation**

In `CapabilityIndexUITests.swift` and `CapacityUITests.swift`, replace the step that clicks the old top-level tab with: click the Flight Control tab, then the section button by identifier (`app.buttons["fc-section-index"]` / `app.buttons["fc-section-capacity"]`). Copy the exact tab-click idiom `RoutingUITests.swift` uses (`rg -n "fc-section-routing" -B6 UITests/FlightDeckUITests/RoutingUITests.swift`). Do not change any assertion.

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=FlightControlTabIntegrationTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -5` → `with 0 failures`. Then the full suite.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Preferences UITests/FlightDeckUITests/CapabilityIndexUITests.swift UITests/FlightDeckUITests/CapacityUITests.swift Tests/FlightDeckTests/FlightControlL3/Integration/FlightControlTabIntegrationTests.swift
git rm Sources/FlightDeck/Preferences/UI/CapabilityIndexSettingsTab.swift
git commit -m "feat: fold routing, task kinds, the capability index and capacity into one flight control tab" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Rule hints from the capability index

**Files:**
- Create: `Sources/FlightDeck/FlightControl/CapabilityRuleHintSource.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Integration/CapabilityRuleHintSourceTests.swift`

**Interfaces:**
- Consumes: L3-R `protocol RuleHintSource { func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? }`, `struct RuleHint { ruleID: String; text: String; snapshotDate: Date }`, `RoutingRule` with `compiled?.match` and `compiled?.assign`; L3-I `CapabilityHints.hints(for: [String: Double], assigned: ModelRef, candidates: [ModelRef], scores: [ModelScores]) -> [CapabilityHint]`, `CapabilityHint.message`, and the service's current scores and snapshot date (confirm: `rg -n "func hints|var current|snapshotDate|scores" Sources/FlightDeck/FlightControl/CapabilityIndexService.swift Sources/IntakeKit/FlightControl/CapabilityHints.swift`).
- Produces: `struct CapabilityRuleHintSource: RuleHintSource { init(scores: @escaping @Sendable () -> (scores: [ModelScores], snapshotDate: Date)?) }`.

- [ ] **Step 1: Confirm the built names**

Run the `rg` above and `rg -n "struct RoutingRule|enum MatchTerm|struct CompiledRule|dimension|atLeast" Sources/IntakeKit/FlightControl/Rules*.swift Sources/IntakeKit/FlightControl/Routing*.swift | head -20`. Use the built names in Steps 2–3.

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// L3-R draws one hint line per rule; L3-I knows which model is better. This adapter is the
/// only place the two meet, so it pins the translation: which dimensions count, which
/// candidate wins, and that a hint carries the snapshot it came from (so a dismissal expires
/// when the index changes, not before).
final class CapabilityRuleHintSourceTests: XCTestCase {
    private let snap1 = Date(timeIntervalSince1970: 1_790_000_000)
    private let snap2 = Date(timeIntervalSince1970: 1_790_600_000)

    private func rule() -> RoutingRule {
        RoutingTestRules.confirmed(id: "r3", dimensions: ["test-authoring": 0.5],
                                   assign: ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"]),
                                   pool: "codex-default")
    }

    private func catalogs() -> AdapterCatalogs {
        AdapterCatalogs([
            AdapterCatalog(harness: "codex", models: [ModelEntry(id: "gpt-6-sol", displayName: "Sol", knobs: ["effort"])],
                           knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "gpt-6-sol", enabled: true),
            AdapterCatalog(harness: "claude", models: [ModelEntry(id: "opus", displayName: "Opus", knobs: [])],
                           knobSchema: [:], defaultModel: "opus", enabled: true)])
    }

    func testHintNamesTheBetterModelAndTheSnapshot() throws {
        let scores = IndexTestScores.make([
            (ModelRef(harness: "codex", model: "gpt-6-sol"), "test-authoring", 0.60, 0.9),
            (ModelRef(harness: "claude", model: "opus"), "test-authoring", 0.78, 0.8)])
        let src = CapabilityRuleHintSource { (scores, self.snap1) }
        let hint = try XCTUnwrap(src.hint(for: rule(), kinds: [], catalogs: catalogs()))
        XCTAssertEqual(hint.ruleID, "r3")
        XCTAssertEqual(hint.snapshotDate, snap1)
        XCTAssertTrue(hint.text.hasPrefix("opus scores 0.18 higher on test-authoring"), hint.text)
    }

    func testNoHintWithoutIndexOrBelowMargin() {
        XCTAssertNil(CapabilityRuleHintSource { nil }.hint(for: rule(), kinds: [], catalogs: catalogs()))
        let close = IndexTestScores.make([
            (ModelRef(harness: "codex", model: "gpt-6-sol"), "test-authoring", 0.70, 0.9),
            (ModelRef(harness: "claude", model: "opus"), "test-authoring", 0.75, 0.9)])
        XCTAssertNil(CapabilityRuleHintSource { (close, self.snap1) }.hint(for: rule(), kinds: [], catalogs: catalogs()))
    }

    func testDismissedHintReturnsOnNewSnapshot() throws {
        let scores = IndexTestScores.make([
            (ModelRef(harness: "codex", model: "gpt-6-sol"), "test-authoring", 0.60, 0.9),
            (ModelRef(harness: "claude", model: "opus"), "test-authoring", 0.78, 0.8)])
        var current = (scores, snap1)
        let src = CapabilityRuleHintSource { current }
        let first = try XCTUnwrap(src.hint(for: rule(), kinds: [], catalogs: catalogs()))
        var dismissals = RuleHintDismissals()
        dismissals.dismiss(first)
        XCTAssertTrue(dismissals.isDismissed(first))
        current = (scores, snap2)
        let second = try XCTUnwrap(src.hint(for: rule(), kinds: [], catalogs: catalogs()))
        XCTAssertFalse(dismissals.isDismissed(second), "a new snapshot must bring the hint back")
    }
}
```

`RoutingTestRules.confirmed(…)` and `IndexTestScores.make(…)`: before writing the test, check whether the sub-branches already ship equivalent helpers (`rg -n "static func (confirmed|make)\(" Tests/FlightDeckTests/FlightControlL3`). If they do, use them. If they do not, add them to `Tests/FlightDeckTests/FlightControlL3/Integration/IntegrationTestHelpers.swift`, building a confirmed `RoutingRule` and `[ModelScores]` with the initializers Step 1 found. `RuleHintDismissals` is L3-R's dismissal store (`rg -n "Dismiss" Sources/FlightDeck/FlightControl Sources/IntakeKit/FlightControl`); if L3-R stores dismissals elsewhere, assert through that type instead and keep the assertion's meaning.

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=CapabilityRuleHintSourceTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: build error `cannot find 'CapabilityRuleHintSource' in scope`.

- [ ] **Step 4: Implement**

```swift
import Foundation
import IntakeKit

/// L3-R's rule list asks "is there a better model for this rule?"; L3-I's index answers in its
/// own terms. This is the one translation: the rule's dimension terms become the dimensions to
/// compare, every enabled catalog model is a candidate, and the largest-margin hint wins.
/// The snapshot date rides along so a dismissed hint stays dismissed only until the index moves.
struct CapabilityRuleHintSource: RuleHintSource {
    let scores: @Sendable () -> (scores: [ModelScores], snapshotDate: Date)?

    init(scores: @escaping @Sendable () -> (scores: [ModelScores], snapshotDate: Date)?) { self.scores = scores }

    func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? {
        guard let current = scores(), let compiled = rule.compiled else { return nil }
        let dims = compiled.match.dimensionThresholds   // [String: Double] of the rule's {dimension, atLeast} terms
        guard !dims.isEmpty else { return nil }
        let assigned = ModelRef(harness: compiled.assign.harness, model: compiled.assign.model, knobs: compiled.assign.knobs)
        let candidates = catalogs.enabledModels.filter { $0.harness != assigned.harness || $0.model != assigned.model }
        guard let best = CapabilityHints.hints(for: dims, assigned: assigned, candidates: candidates,
                                               scores: current.scores).first else { return nil }
        return RuleHint(ruleID: rule.id, text: best.message, snapshotDate: current.snapshotDate)
    }
}
```

If `compiled.match` has no `dimensionThresholds`, add this extension in the same file, written against the built match type (Step 1):

```swift
extension RuleMatch {
    /// The `{dimension, atLeast}` terms of an `any`/`all` match, flattened; kind-name terms are skipped.
    var dimensionThresholds: [String: Double] {
        var out: [String: Double] = [:]
        for term in terms { if case .dimension(let id, let atLeast) = term { out[id] = atLeast } }
        return out
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=CapabilityRuleHintSourceTests ./scripts/test-unit.sh 2>&1 | tail -5` → `with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/CapabilityRuleHintSource.swift Tests/FlightDeckTests/FlightControlL3/Integration
git commit -m "feat: draw rule hints from the capability index" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Pools from Capacity settings feed routing

**Files:**
- Create: `Sources/FlightDeck/FlightControl/CapacityPoolDirectory.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Integration/CapacityPoolDirectoryTests.swift`

**Interfaces:**
- Consumes: L3-R `protocol PoolDirectory: Sendable { func pools() -> [PoolSummary]; func defaultPool(for: HarnessID) -> PoolID? }`, `PoolSummary(id:harness:label:)`; L3-U `CapacityPool { id, label, harness, kind, accounts, … }` and its default-pool rule `<adapter>-default` (confirm: `rg -n "static func defaults|defaultPool|-default" Sources/IntakeKit/FlightControl/CapacityPool*.swift Sources/FlightDeck/FlightControl/Usage/*.swift`).
- Produces: `struct CapacityPoolDirectory: PoolDirectory { init(pools: @escaping @Sendable () -> [CapacityPool]) }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Routing validates a rule's pool and picks a harness's default pool; Capacity is where pools
/// are defined. Until integration routing used a stand-in that only knew `<harness>-default`.
/// This pins that a user-made pool becomes routable and the default stays the default.
final class CapacityPoolDirectoryTests: XCTestCase {
    func testUserPoolsAndDefaultsAreVisibleToRouting() {
        let work = CapacityPool.hosted(id: "codex-subs", label: "Codex subscriptions", harness: "codex", accounts: [UUID()])
        let dflt = CapacityPool.hosted(id: "codex-default", label: "codex — all accounts", harness: "codex", accounts: [])
        let local = CapacityPool.local(id: "ollama-local", label: "Ollama", harness: "opencode", endpoint: "http://localhost:11434", cap: 1)
        let dir = CapacityPoolDirectory { [work, dflt, local] }
        XCTAssertEqual(dir.pools().map(\.id), ["codex-subs", "codex-default", "ollama-local"])
        XCTAssertEqual(dir.defaultPool(for: "codex"), "codex-default")
        XCTAssertNil(dir.defaultPool(for: "claude"), "no claude pool configured → no default")
    }
}
```

Before running, confirm `CapacityPool`'s constructors (`rg -n "static func (hosted|local)|init\(" Sources/IntakeKit/FlightControl/CapacityPool.swift`) and use them; if there are no `hosted`/`local` factories, call the memberwise init with the fields L3-U defined.

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=CapacityPoolDirectoryTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: build error `cannot find 'CapacityPoolDirectory' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import IntakeKit

/// Routing's view of the pools Settings → Flight Control → Capacity defines. Read through a
/// closure on every call, so a pool added in Settings is routable without rebuilding the router.
struct CapacityPoolDirectory: PoolDirectory {
    let source: @Sendable () -> [CapacityPool]
    init(pools: @escaping @Sendable () -> [CapacityPool]) { source = pools }

    func pools() -> [PoolSummary] {
        source().map { PoolSummary(id: $0.id, harness: $0.harness, label: $0.label) }
    }

    /// `<harness>-default` when it exists — L3-U creates one per adapter — else nil, so the
    /// validator says "no pool for claude" instead of inventing one.
    func defaultPool(for harness: HarnessID) -> PoolID? {
        let wanted = PoolID("\(harness.rawValue)-default")
        return source().first { $0.id == wanted }?.id
    }
}
```

- [ ] **Step 4: Run to verify it passes, then commit**

Run: `FD_TEST_FILTER=CapacityPoolDirectoryTests ./scripts/test-unit.sh 2>&1 | tail -5` → `with 0 failures`.

```bash
git add Sources/FlightDeck/FlightControl/CapacityPoolDirectory.swift Tests/FlightDeckTests/FlightControlL3/Integration/CapacityPoolDirectoryTests.swift
git commit -m "feat: route to the pools defined in capacity settings" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Compose the real graph and run a swarm end to end

**Files:**
- Create: `Sources/FlightDeck/FlightControl/FlightControlComposition.swift`
- Modify: `Sources/FlightDeck/AppDelegate.swift` (or wherever `SessionStore` is built for the app — confirm with `rg -n "SessionStore\(" Sources/FlightDeck/AppDelegate.swift Sources/FlightDeck/FlightDeckApp.swift`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Integration/SwarmEndToEndTests.swift`

**Interfaces:**
- Consumes (confirm each with `rg` before Step 1; names are from the sub-plans):
  - L3-R: `RoutingService` (owns `Router`/`KindRegistry` conformers; its setters for the index, hint source and pool directory — `rg -n "var (index|hints|pools|poolDirectory|hintSource)" Sources/FlightDeck/FlightControl/RoutingService.swift`).
  - L3-I: `SessionStore.capabilityIndexService` with `.live: CapabilityIndex` and current scores.
  - L3-U: `UsageService.shared` (`ledger` is `CapacityReader` + `PoolAllocator`; `planner` is `HandoffPlanner`; `setSwarmPredicate(_:)`), `HandoffDriver(planner:allocator:router:spawner:host:settings:now:)`, `StoreHandoffHost(store:commands:logURL:)` with hooks `confirmer`, `kindLookup`, `catalogProvider`, `reservationLookup`, `onHandedOff`, `BrAmHandoffCommands`.
  - L3-S: `SessionStore.swarmDependencies: SwarmDependencies?` (`router`, `kinds`, `allocator`, `capacity`), `SwarmService` with `spawner`, `handoffDecisions: HandoffDecisionSink?`, `agentSnapshots(project:)`, `recordHandoff(project:from:to:block:lease:)`, `returnClaimToOpen(project:task:)`, `isSwarmSession(_:)`, and its tick hook.
- Produces: `@MainActor enum FlightControlComposition { static func install(on store: SessionStore, preferences: PreferencesStore, usage: UsageService = .shared) }`.

- [ ] **Step 1: Confirm every consumed name**

Run each `rg` listed above. Write the built names into this task's code as you go; record any difference in the commit body.

- [ ] **Step 2: Write the failing end-to-end tests**

These run the real `Router`, real `CapacityLedger`, real `HandoffDriver` and real `SwarmController`, with only the process boundary faked: `MultiRunner` for `br`/`am` (`Tests/FlightDeckTests/Flywheel/Observe/ObserveTestSupport.swift`), `FakeSwarmAgentLauncher` from L3-S for tab creation, the L3-0 fixtures, and a fake clock.

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The one test that runs Level 3 as the maintainer will: a released task routes by a confirmed rule,
/// leases the first account under soft, starts, and — when that account crosses hard — is
/// handed to a fresh agent on the next account with the transcript path in its first prompt.
/// Every sub-branch tested its piece against fakes of the others; this is the first time the
/// real pieces meet, so it asserts on the seams, not the internals.
@MainActor
final class SwarmEndToEndTests: XCTestCase {
    private var rig: L3IntegrationRig!

    override func setUp() async throws {
        rig = try L3IntegrationRig.make(accounts: ["Work", "Personal"], harness: "codex",
                                        rule: "Use Codex for unit and integration tests",
                                        compiled: .dimension("test-authoring", atLeast: 0.5, assign: "codex/gpt-6-sol/high", pool: "codex-default"),
                                        readyTasks: ["fx-valid"])
    }

    func testTaskRoutesLeasesFirstAccountAndStarts() async throws {
        rig.usage.feed(account: "Work", utilization: 0.30)
        rig.usage.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let spawn = try XCTUnwrap(rig.launcher.spawns.first)
        XCTAssertEqual(spawn.block.harness, "codex")
        XCTAssertEqual(spawn.block.model, "gpt-6-sol")
        XCTAssertEqual(spawn.lease?.account.label, "Work", "first account in pool order under soft")
        XCTAssertTrue(rig.runner.argv.contains { $0.starts(with: ["br", "update", "fx-valid", "--claim"]) })
        XCTAssertTrue(spawn.firstPrompt.contains("Your task is fx-valid"))
    }

    func testSoftThresholdMovesNewWorkToNextAccount() async throws {
        rig.usage.feed(account: "Work", utilization: 0.85)
        rig.usage.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        XCTAssertEqual(rig.launcher.spawns.first?.lease?.account.label, "Personal")
    }

    func testHardThresholdHandsOffWithTranscriptPointer() async throws {
        rig.usage.feed(account: "Work", utilization: 0.30)
        rig.usage.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.launcher.spawns.first)
        rig.usage.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        await rig.tick()
        XCTAssertEqual(rig.launcher.spawns.count, 2)
        let handoff = rig.launcher.spawns[1]
        XCTAssertEqual(handoff.lease?.account.label, "Personal")
        XCTAssertTrue(handoff.firstPrompt.contains("stopped because its account reached its usage limit"))
        XCTAssertTrue(handoff.firstPrompt.contains(rig.transcriptPath(of: first.session)))
        XCTAssertTrue(rig.runner.argv.contains { $0.starts(with: ["br", "update", "fx-valid", "--assignee"]) })
        XCTAssertTrue(rig.swarm.isHandedOff(first.session))
    }

    func testPausedSwarmStillHandsOff() async throws {
        rig.usage.feed(account: "Work", utilization: 0.30)
        rig.usage.feed(account: "Personal", utilization: 0.10)
        try await rig.launch(cap: 1)
        await rig.tick()
        let first = try XCTUnwrap(rig.launcher.spawns.first)
        rig.swarm.pause(project: rig.project)
        rig.usage.feed(account: "Work", utilization: 0.97)
        rig.markIdle(first.session)
        await rig.tick()
        XCTAssertEqual(rig.launcher.spawns.count, 2, "pause stops new claims, not hand-offs")
    }

    func testSharedAccountRefusedInBothPools() async throws {
        rig.addPool(id: "codex-subs", accounts: ["Work"])
        rig.usage.feed(account: "Work", utilization: 0.85)
        XCTAssertNil(rig.usage.ledger.lease(pool: "codex-subs"))
        XCTAssertNotEqual(rig.usage.ledger.lease(pool: "codex-default")?.account.label, "Work")
    }

    func testDeletedPoolMakesTaskWaitWithReason() async throws {
        rig.setBlockPool(task: "fx-valid", pool: "gone", pinned: true)
        try await rig.launch(cap: 1)
        await rig.tick()
        XCTAssertTrue(rig.launcher.spawns.isEmpty)
        XCTAssertEqual(rig.swarm.waitingReason(task: "fx-valid", project: rig.project), "pool gone no longer exists")
    }
}
```

`L3IntegrationRig` goes in `Tests/FlightDeckTests/FlightControlL3/Integration/L3IntegrationRig.swift`. It builds a `SessionStore(provider: nil, persistence: nil)`, a `PreferencesStore` on a throwaway `UserDefaults` suite with the two accounts and the default pool, a `MultiRunner` scripted from `L3Fixtures` (`br ready`, `br scheduler`, `br list` returning the envelope with only the named ready tasks, `br update --claim` success, `br update --assignee` success, `am file_reservations release` success), a `UsageService` built with `init(environment:ledger:now:)` on the fake clock, and L3-S's `FakeSwarmAgentLauncher`. It then calls `FlightControlComposition.install(on:preferences:usage:)`. `feed(account:utilization:)` ingests a `UsageReading` through `UsageService.ingest(_:)`. `markIdle` sets the session's status to idle through `applyRegistryForTesting`. `transcriptPath(of:)` returns what `UsageService.transcriptPointer(for:)` returns for that session. Write each helper against the built names Step 1 found; each helper is a few lines, and none may contain assertions.

If `waitingReason`'s built wording for a missing pool differs, keep the test's meaning (the task waits and the reason names the pool) and assert on the built wording. If L3-S has no "pool no longer exists" case at all, add it in `SwarmController`'s lease step: when `capacity.headroom(pool:)` is empty **and** the pool is not in the pool directory, the reason is `"pool \(id) no longer exists"`.

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=SwarmEndToEndTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: build error `cannot find 'FlightControlComposition' in scope`.

- [ ] **Step 4: Implement `FlightControlComposition.swift`**

```swift
import Foundation
import IntakeKit

/// Builds the real Level 3 graph once and installs it on the store. Each branch shipped with a
/// stand-in for its siblings (`NullCapabilityIndex`, `NoRuleHints`, `DefaultPoolDirectory`,
/// a nil `swarmDependencies`, no hand-off driver); this is the only place those stand-ins are
/// replaced, so "which real thing talks to which" can be read in one file.
@MainActor
enum FlightControlComposition {
    static func install(on store: SessionStore, preferences: PreferencesStore, usage: UsageService = .shared) {
        // Routing: the real index, hints and pools.
        let indexService = store.capabilityIndexService
        if let indexService { store.routing.index = indexService.live }
        store.routing.hintSource = CapabilityRuleHintSource { [weak indexService] in
            MainActor.assumeIsolated { indexService?.currentScoresAndDate }
        }
        store.routing.poolDirectory = CapacityPoolDirectory { [weak preferences] in
            MainActor.assumeIsolated { preferences?.preferences.capacity.pools ?? [] }
        }

        // Swarm: routes through L3-R, leases through L3-U.
        store.swarmDependencies = SwarmDependencies(router: store.routing.router, kinds: store.routing.kinds,
                                                    allocator: usage.ledger, capacity: usage.ledger)

        // Usage: which tabs are swarm agents (manual tabs are never handed off).
        let swarm = store.swarm
        usage.setSwarmPredicate { [weak swarm] id in swarm?.isSwarmSession(id) ?? false }

        // Hand-off: L3-U's driver, L3-S's spawner and record updates.
        let host = StoreHandoffHost(store: store, commands: BrAmHandoffCommands.system, logURL: StoreHandoffHost.defaultLogURL)
        host.kindLookup = { [weak store] task, project in store?.routing.kind(for: task, project: project) }
        host.catalogProvider = { [weak store] in await store?.routing.catalogs() ?? AdapterCatalogs([]) }
        host.reservationLookup = { [weak swarm] agent, project in await swarm?.reservedFiles(of: agent, project: project) }
        host.onHandedOff = { [weak swarm] from, to, block, lease, project in
            swarm?.recordHandoff(project: project, from: from, to: to, block: block, lease: lease)
        }
        let driver = HandoffDriver(planner: usage.planner, allocator: usage.ledger, router: store.routing.router,
                                   spawner: swarm.spawner, host: host,
                                   settings: { [weak preferences] in preferences?.preferences.capacity.handoffSettings ?? .default },
                                   now: Date.init)
        host.confirmer = swarm.handoffConfirmer
        swarm.handoffDecisions = driver
        swarm.onTick = { [weak swarm, weak driver] project in
            guard let swarm, let driver else { return }
            await driver.evaluate(swarm.agentSnapshots(project: project))
        }
    }
}
```

Every member name here is from the sub-plans' Produces lists. For each one Step 1 found spelled differently, use the built spelling. Where a hook does not exist as built, add it in the owning type as the smallest change that compiles: for example, `SwarmService.onTick` if L3-S calls the driver some other way, or `RoutingService.kind(for:project:)` as a lookup over its `KindRegistry` plus `ExecutionBlockCodec` on `br show`. Each such addition gets its own test in the owning type's existing test class. If `HandoffDriver` does not conform to L3-S's `HandoffDecisionSink`, add the conformance in this file as an extension that forwards to the driver's confirm/decline API.

In the app's startup (Step 1 found the file), call `FlightControlComposition.install(on: store, preferences: preferences)` once, right after `SessionStore` and `PreferencesStore` exist, and only when not running under `-FlightControlFixtureBackend`, which installs its own fixture graph (`rg -n "FlightControlFixtureBackend" Sources/FlightDeck`).

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=SwarmEndToEndTests ./scripts/test-unit.sh 2>&1 | tail -5` → `Executed 6 tests, with 0 failures`. Then the full suite.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/FlightControlComposition.swift Sources/FlightDeck/AppDelegate.swift Tests/FlightDeckTests/FlightControlL3/Integration
git commit -m "feat: run swarms through real routing, capacity and hand-off" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(Add the startup file Step 1 found instead of `AppDelegate.swift` if it differs, and any owning-type files Step 4 touched.)

---

### Task 6: Mount the real meters on the swarm surfaces

**Files:**
- Modify: L3-S's header popover, sidebar row and Observe assignment lane (`rg -n "MinimalMeter" Sources/FlightDeck` lists every use)
- Delete: L3-S's `MinimalMeter` type
- Modify: L3-S's swarm wire projection, so the phone gets real headroom (`rg -n "headroom|AccountHeadroom" Sources/FlightDeck/Fleet Sources/FleetKit`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Integration/MeterMountTests.swift`

**Interfaces:**
- Consumes: L3-U views `PoolMeterList(pools:)` (identifier `pool-meter-<pool id>`), `RowMiniMeter(model:)` (identifier `row-mini-meter`), `AccountMeterBar(model:)` (identifier `meter-bar`), `MeterFormatter.rowMeter(account:ledger:now:)`, and the models `PoolMeterModel`.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// L3-S drew a stand-in meter so its UI tests had something to see; L3-U built the real one.
/// After integration the stand-in must be gone everywhere — two meters that disagree about an
/// account would be worse than none.
@MainActor
final class MeterMountTests: XCTestCase {
    func testNoStandInMeterRemainsInSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/FlightDeck")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("MinimalMeter"), "\(url.lastPathComponent) still uses the stand-in meter")
        }
    }

    func testSwarmRowShowsRealMeterPastSoft() throws {
        let rig = try L3IntegrationRig.make(accounts: ["Work"], harness: "codex", rule: nil, compiled: nil, readyTasks: [])
        rig.usage.feed(account: "Work", utilization: 0.85)
        let model = MeterFormatter.rowMeter(account: rig.accountRef("Work"), ledger: rig.usage.ledger, now: rig.now)
        XCTAssertNotNil(model, "past soft → the row draws a mini meter")
        rig.usage.feed(account: "Work", utilization: 0.40)
        XCTAssertNil(MeterFormatter.rowMeter(account: rig.accountRef("Work"), ledger: rig.usage.ledger, now: rig.now))
    }
}
```

`rig.accountRef(_:)` and `rig.now`: add them to `L3IntegrationRig` if Task 5 did not.

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=MeterMountTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `testNoStandInMeterRemainsInSources` fails, naming the files that use `MinimalMeter`.

- [ ] **Step 3: Replace the stand-in**

At each `MinimalMeter` use:
- **Header popover:** `PoolMeterList(pools: MeterFormatter.pools(ledger: UsageService.shared.ledger, preferences: preferences, now: Date()))`. Use the built factory: `rg -n "static func" Sources/FlightDeck/FlightControl/Usage/MeterFormatter.swift`.
- **Sidebar row:** `RowMiniMeter(model: MeterFormatter.rowMeter(account: account, ledger: UsageService.shared.ledger, now: Date()))`.
- **Observe assignment lane:** `AccountMeterBar(model:)` with the account's model from the same formatter, plus the hand-off history read from `StoreHandoffHost.defaultLogURL` (`HandoffLogEntry`, one per line), filtered to this session as `oldSession` or `newSession`.

Keep the accessibility identifiers L3-S's UI tests query (`rg -n "meter" UITests/FlightDeckUITests/SwarmUITests.swift`). Where L3-S's identifier differs from L3-U's, wrap the L3-U view in `.accessibilityIdentifier(<L3-S's id>)` rather than editing either test. Delete the `MinimalMeter` type.

In the swarm wire projection, fill the pool meters from `UsageService.shared.ledger.headroom(pool:)` for each pool the project's swarm uses. Run `./scripts/build-ios.sh` and `./scripts/test-ios.sh` afterwards.

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=MeterMountTests ./scripts/test-unit.sh 2>&1 | tail -5` → `with 0 failures`. Then the full suite, `./scripts/build-ios.sh` and `./scripts/test-ios.sh`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck Sources/FleetKit Tests/FlightDeckTests/FlightControlL3/Integration
git commit -m "feat: show capacity meters on swarm rows, the project header, the drawer and the phone" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: OpenCode, when its adapter is on master

**Files (only if `rg -n "case opencode" Sources/FlightDeck/Agents/AgentKind.swift` matches on master):**
- Create: `Sources/FlightDeck/FlightControl/OpenCodeRoutingCapabilities.swift`
- Modify: `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift` (`standard()` switch)
- Test: `Tests/FlightDeckTests/FlightControlL3/Integration/OpenCodeRoutingCapabilitiesTests.swift`

- [ ] **Step 1: Check whether the adapter has merged**

Run: `git log master --oneline | rg -i opencode | head -3; rg -n "case opencode" Sources/FlightDeck/Agents/AgentKind.swift`.
- **No match:** skip to Step 6. Record in FOLLOWUPS: "OpenCode routing capabilities wait for the opencode-adapter merge; `RoutingCapabilityRegistry.standard()` will fail to compile until it states them, which is intended."
- **Match:** continue. Merge master into `l3-integration` first (`git merge master`) and run the full suite.

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// OpenCode differs from claude and codex in exactly the ways Level 3 cares about: models are
/// `provider/model` from opencode.json, the knob is an agent name, local providers have no
/// account, and there is no usage meter — only errors. These pin those answers.
@MainActor
final class OpenCodeRoutingCapabilitiesTests: XCTestCase {
    func testDeclaresProviderModelsAndAgentKnob() async throws {
        let caps = OpenCodeRoutingCapabilities(configuredModels: { ["ollama/qwen3-coder:32k", "anthropic/claude-sonnet"] },
                                               agents: { ["build", "plan"] })
        let models = try XCTUnwrap(await caps.modelCatalog().value)
        XCTAssertEqual(models.map(\.id), ["ollama/qwen3-coder:32k", "anthropic/claude-sonnet"])
        XCTAssertEqual(caps.knobSchema, ["agent": ["build", "plan"]])
        XCTAssertEqual(caps.accountModel, .providerKeys)
    }

    func testRegistryIncludesOpenCode() {
        XCTAssertNotNil(RoutingCapabilityRegistry.standard().capabilities(for: "opencode"))
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=OpenCodeRoutingCapabilitiesTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: build error. `RoutingCapabilityRegistry.standard()`'s switch is non-exhaustive, and `OpenCodeRoutingCapabilities` is not defined.

- [ ] **Step 4: Implement**

Read the merged adapter's API first: `rg -n "struct OpenCodeOptions|var model|var agent|func export|prompt_async|class OpenCode\w+" Sources/FlightDeck/Agents/OpenCode`. Then write `OpenCodeRoutingCapabilities: AgentRoutingCapabilities`:
- `harness = "opencode"`, `accountModel = .providerKeys`.
- `modelCatalog()` returns `.supported` with the configured `provider/model` ids. They come from an injected closure; the app passes one that reads opencode.json the way the adapter already does.
- `knobSchema = ["agent": <configured agents>]`.
- `usageMeterSource(account:)` returns `.supported(OpenCodeErrorUsageSource(...))` (L3-U's type) for the account's server.
- `transcriptPointer(for:)` returns `.supported(TranscriptPointers.openCode(sessionID:serverURL:))` (L3-U).
- `resetContext(_:)` creates a new OpenCode session for the tab through the adapter's HTTP client.
- `applying(_:to:)` maps `model`/`agent` onto `OpenCodeOptions`.

Add the `case .opencode: OpenCodeRoutingCapabilities(...)` arm to `standard()`. Add a `local` pool for any `ollama/` model in the Capacity defaults, if L3-U's defaults do not already create one (`rg -n "local" Sources/IntakeKit/FlightControl/CapacityPool*.swift`).

- [ ] **Step 5: Run to verify it passes, then commit**

Run: `FD_TEST_FILTER=OpenCodeRoutingCapabilitiesTests ./scripts/test-unit.sh 2>&1 | tail -5` → `with 0 failures`. Then the full suite.

```bash
git add Sources/FlightDeck/FlightControl Tests/FlightDeckTests/FlightControlL3/Integration/OpenCodeRoutingCapabilitiesTests.swift
git commit -m "feat: route level 3 tasks to opencode agents" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: (No-merge path) record and continue**

Add the FOLLOWUPS line from Step 1 and commit it with the docs in Task 8.

---

### Task 8: UI suites against the joined build, docs, merge

**Files:**
- Modify: `docs/FLIGHT-CONTROL-L3-CHECKLIST.md`
- Modify: `docs/FOLLOWUPS.md`
- Modify: the five Level 3 specs' "as built" sections

- [ ] **Step 1: Run each UI script once**

Before each run, send a PushNotification ("Flight Deck UI tests take the screen in 10 s — about N min") and wait about 10 s with a background `until` command, never a foreground `sleep`. Run each in the foreground, once:
- `scripts/test-routing-ui.sh`
- the L3-I UI test invocation from its plan (Task 13), using the Flight Control tab navigation from Task 2;
- `scripts/test-ui-capacity.sh`
- `scripts/test-ui-flight-control.sh`

Record each result (pass/fail, and the screenshots' location in the `.xcresult`). If a script fails, diagnose from its log and screenshots and fix the cause. Re-running the same script after a fix is allowed. Re-running it to "see if it passes" is not (AGENTS.md rule 4).

- [ ] **Step 2: Update the maintainer's checklist**

In `docs/FLIGHT-CONTROL-L3-CHECKLIST.md` (written by L3-S), keep the five basic tasks and add these three. Each must be a real thing to do, not a test step:
6. In Settings → Flight Control → Routing, write "Use Codex for unit and integration tests" and confirm it. Release an intake with a test task, and check that the task's routing chip says *rule*.
7. In Settings → Flight Control → Capacity, put two claude accounts in one pool. Run a swarm agent on the first until its bar passes the soft tick. Check that the next task starts on the second account.
8. In Settings → Flight Control → Capability index, click **Refresh now** (this spends tokens). Check that the heatmap fills in and each cell links to its source.

- [ ] **Step 3: Update FOLLOWUPS and the specs**

In `docs/FOLLOWUPS.md`, change the Level 3 entry's headline to "**Level 3 'Operate' — BUILT (2026-10-<dd>), merged <sha>, GUI-unverified.**" Collapse the per-branch "built" bullets into one list of what is still open. Each sub-branch's FOLLOWUPS bullet lists its unresolved probe outcomes; carry those over. Add the UI-script results from Step 1. In each spec's "as built" section, add one line naming the integration commit.

- [ ] **Step 4: Final checks**

Run, in order:
- `./scripts/test-unit.sh 2>&1 | tee /tmp/l3-int.log | tail -3` → `** SHARDED UNIT RUN PASSED`; `rg -n "error:" /tmp/l3-int.log` → nothing.
- `./scripts/build-ios.sh && ./scripts/test-ios.sh` → both succeed.
- `./scripts/build.sh` → the Debug app builds. **Do not launch it.**
- `git diff master...HEAD -- vendor` → empty.
- `rg -n 'filled in by L3-|NullCapabilityIndex\(\)|NoRuleHints\(\)|DefaultPoolDirectory\(' Sources/FlightDeck` → no output outside tests. The stand-ins may stay as types for tests, but nothing in the app may construct them.

- [ ] **Step 5: Commit and merge**

```bash
git add docs/FLIGHT-CONTROL-L3-CHECKLIST.md docs/FOLLOWUPS.md docs/superpowers/specs/2026-10-04-flight-control-l3-*.md
git commit -m "docs: record level 3 as integrated and what is left for me to check" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Then merge `l3-integration` to master per `superpowers:finishing-a-development-branch`. Master is often checked out nowhere; fast-forward the ref if so (see the worktree-merge memory). Do **not** run `swap-release.sh`. Releasing is the maintainer's call.
