# Flight Control L3-R Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every task a routed execution block. You write routing rules as sentences, an LLM
compiles them, and you confirm the compiled form. Planning sessions classify each task into a
kind and may propose new kinds. A pure router turns kind + rules (+ the capability index) into
harness, model, knobs and pool, and spills to another pool when one is exhausted.

**Architecture:** Everything that decides is pure and lives in `IntakeKit`
(`Sources/IntakeKit/FlightControl/`): the rule model, the project rule file, the kind registry
file, the router (`RouterCore` + the contract conformer `RuleRouter`), the validator, the
compiler (behind `CommandRunner`), encode-time routing and kind re-routing. The app target owns
I/O against live things: the adapter catalogs (claude aliases, codex `model/list`), `BeadWriter`'s
`--agent-context`, `RoutingService` (the `@MainActor` owner the Settings panes and intake release
talk to) and the two Settings panes in a new Settings → Flight Control tab. Every seam to another
Level 3 branch is an L3-0 protocol or a small protocol this plan defines and flags (pools, rule
hints).

**Tech Stack:** Swift 6 (IntakeKit), Swift 5 mode (app target), SwiftUI, XCTest, XCUITest,
XcodeGen, `br` 0.6.0, `claude -p`, `codex app-server`.

**Spec:** `docs/superpowers/specs/2026-10-04-flight-control-l3-routing-design.md`
(context: `docs/superpowers/specs/2026-10-04-flight-control-l3-overview-contract-design.md`;
contract plan: `docs/superpowers/plans/2026-10-04-flight-control-l3-0-contract.md`).

## Global Constraints

- L3-0 is merged to master before Task 1 starts. Consume its names exactly; never redefine a contract type.
- Do not import or reference any type from L3-I, L3-U or L3-S. Only L3-0 protocols, values and fakes.
- IntakeKit is Foundation-only, `SWIFT_VERSION: "6.0"`; every new IntakeKit type is `Sendable`.
- App target stays `SWIFT_VERSION: "5.0"`. Don't "fix" it.
- New IntakeKit code: `Sources/IntakeKit/FlightControl/`. New app code: `Sources/FlightDeck/FlightControl/` and `Sources/FlightDeck/Preferences/UI/`.
- New tests: `Tests/FlightDeckTests/FlightControlL3/Routing/`. New fixtures: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/`.
- Test classes are declared `final class Name: XCTestCase` on one line (`test-unit.sh` finds classes with a regex).
- Run one class: `FD_TEST_FILTER=<Class> ./scripts/test-unit.sh 2>&1 | tail -40`. A filtered run ends with xctest's own `Executed N tests, with M failures` line, **not** the `SHARDED UNIT RUN` banner (that line is printed only by an unfiltered run). The script exits 0 even on failure: read the `Executed` line and `rg -n "error:"` the output.
- Subagents run tests in the foreground. Never loop a UI test; `scripts/test-routing-ui.sh` runs at most once per task step that names it.
- No unit test may call `RoutingCapabilityRegistry.standard().catalogs(enabled:)` or `CodexRoutingCatalog.shared.models()`: from Task 9 on they spawn `codex app-server`.
- Live tests that spend tokens or spawn real CLIs are skipped unless `ROUTING_LIVE=1` (`test-unit.sh` runs `xctest` directly, so the variable reaches the test process as is).
- UI copy says *tasks* (never "beads"), *agent* (never "seat"), *Flight Control* (never "flywheel"). `TerminologyGuardTests` scans every `Sources/FlightDeck/**` and `Sources/IntakeKit/**` literal.
- Comments explain *why* and name the failure they prevent (`docs/CONVENTIONS.md`).
- Commits: lowercase, behavioral, imperative; trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit by path (`git add <paths>`); never `git add -A`, never `git stash`.
- Work in a worktree (`superpowers:using-git-worktrees`). Symlink `vendor/ghostty-artifacts` and `vendor/boringssl-artifacts` into it before the first build and never commit those symlinks.
- Never launch a bundle from `DerivedData/`. Never `defaults delete dev.flightdeck.FlightDeck` (only the window-geometry keys `smoke.sh` already deletes).
- The project files are `<project>/.flightdeck/kinds.json` and `<project>/.flightdeck/routing.json`, written pretty-printed with sorted keys and ISO-8601 dates so they diff cleanly in the user's repo.

**Deviations from the spec decided while planning (Task 22 records them in the spec):**
1. **The task kind travels as `taskKind`, not `kind`, on the create op.** The change-set op schema
   is one flat object, and `kind` is already `addEdge`'s edge kind with a closed enum
   (`blocks|related|parent-child`). Reusing it would make every kind id fail the schema.
2. **`kindProposal.dimensions` is an array of `{dimension, weight}` on the wire.** Strict-mode
   output schemas (both CLIs) cannot describe an open-keyed object. `KindProposal` decodes it
   into `[String: Double]`.
3. **CONTRACT GAP — pools.** L3-0 has no pool list. This branch defines `PoolSummary`,
   `PoolDirectory` and `DefaultPoolDirectory` (one `<harness>-default` pool per harness, as L3-U
   §2 names them) in `Sources/IntakeKit/FlightControl/RoutingSeams.swift`. At integration L3-U's
   pool store conforms to `PoolDirectory` and replaces `DefaultPoolDirectory`.
4. **CONTRACT GAP — rule hints.** L3-0's `CapabilityIndex` has no hint call. This branch defines
   `RuleHint`, `RuleHintSource` and `NoRuleHints` (same file). L3-R draws the hint; at
   integration L3-I's hint computation conforms to `RuleHintSource`. `NullCapabilityIndex` stands
   in for L3-I's index until then.
5. **An unroutable task through the contract's `Router.assign`.** The protocol returns a
   non-optional `Assignment`, so `RuleRouter.assign` returns a block with empty
   harness/model/pool and the reason `unroutable: …`. `ExecutionBlockCodec` refuses to decode an
   empty field, so nothing can launch it. `RouterCore.assign` returns `RouteOutcome` for callers
   that can fail, and encode-time routing never writes an unroutable block.
6. **Global rules compile against the seed kinds.** The kind registry is per project; a global
   rule's `{kind}` term may name only a seed kind. Project rules compile against the project's
   registry.
7. **Unclassified creates route as `implement-simple`.** A create with no `taskKind`, an unknown
   id, or a proposal whose name normalizes to nothing gets the seed kind `implement-simple`, and
   its block's reason starts `no kind from planning;`. Failing validation instead would break
   every intake already in review when this ships.
8. **Claude's catalog is its aliases only** (`ClaudeFlagCatalog`'s `--model` choices, `opus`
   first). Claude has no model-list command, so full ids are not listed.
9. **Codex's catalog comes from a short-lived `codex app-server` `model/list`** (probed live on
   codex-cli 0.160.0), cached for the launch. Its knob schema is the union of the models'
   `supportedReasoningEfforts`.
10. **A compiled rule always has a pool.** A sentence that names none gets the adapter's default
    pool at validation time, and the compiled text shows it.
11. **Storage key `Preferences.flightControlRouting`.** Not a shared `flightControl` struct, so
    L3-U's pools field lands beside it without a same-line conflict. This branch creates the
    Settings → Flight Control tab (section buttons: Routing, Task kinds); L3-I and L3-U add
    their sections at integration.
12. **Rules can be reordered** (up/down buttons). First-match-wins makes order load-bearing.
13. **Re-route on kind change runs for merge and re-weight only, over `open` tasks**
    (`br list --status open --json`). Released tasks' `editBead` ops carry no kind; a polish or
    cross-check round's kind change is picked up because routing runs at release, on the final
    change set.
14. **L3-0's `testUnsupportedCatalogYieldsAnEmptyDisabledCatalog` is rewritten against a fake.**
    Claude and codex catalogs are now real, and calling the standard registry's catalogs spawns
    `codex app-server`.
15. **The encode fixture is written in the shape of an encode output**, not recorded from a live
    round with the new schema (that would spend a full planning round).
16. **Routing UI tests skip unless `TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1`** and run from
    `scripts/test-routing-ui.sh`, because `smoke.sh` runs the whole UI bundle.
17. **Spill reasons say "exhausted"** (`codex-subs exhausted → claude-subs/opus`): the router
    only knows the pool was excluded, not which threshold L3-U applied.

## Review Focus

- **`br` refuses an `agent_context` write that keeps less than half the old length** (probed on
  br 0.6.0: exit 4, `VALIDATION_FAILED … without --force`). A re-route that shortens a block's
  reason would silently fail. Pinned by `testWriteBlockForcesOnlyWhenTheContextShrinksBelowHalf`
  (Task 13).
- **A confirmed rule whose model left the catalog** (codex retired a model, an adapter was
  disabled, a pool was deleted). The router must skip that rule, never emit a block nothing can
  launch. Pinned by `testRuleWhoseModelLeftTheCatalogIsSkipped` (Task 4).
- **Merge direction in kind terms.** `{kind: snapshot-tests}` must match `golden-tests` (merged
  into it); `{kind: golden-tests}` must not match `snapshot-tests`. Pinned by
  `testKindTermMatchesMergedKindsButNotTheReverse` (Task 4).
- **An invalid `.flightdeck/routing.json` is the user's file.** Routing treats it as empty, but an
  edit in Settings must never overwrite it. Pinned by
  `testProjectRuleEditsAreRefusedWhileTheFileIsInvalid` (Task 16) and
  `testSaveRefusesToOverwriteAnInvalidFile` (Task 2).
- **A proposal whose name normalizes to nothing** (`"!!!"`). It must not write an empty kind id
  into the registry. Pinned by `testProposalNamedOnlyPunctuationFallsBackAndWritesNothing`
  (Task 12).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/IntakeKit/FlightControl/RoutingRule.swift` | `MatchTerm`, `RuleMatch`, `RuleAssign`, `CompiledRule`, `RuleState`, `CompilerRef`, `RuleCompilerSettings`, `RoutingRule`, `RoutingRuleFile`, `RuleText` |
| `Sources/IntakeKit/FlightControl/ProjectRoutingStore.swift` | `.flightdeck/routing.json` read/write; `ProjectRulesLoad` |
| `Sources/IntakeKit/FlightControl/KindRegistryStore.swift` | `.flightdeck/kinds.json`; the real `KindRegistry`; rename/re-weight/merge |
| `Sources/IntakeKit/FlightControl/RoutingSeams.swift` | `PoolSummary`, `PoolDirectory`, `DefaultPoolDirectory`, `NullCapabilityIndex`, `RuleHint`, `RuleHintSource`, `NoRuleHints`, `RuleLists`, `RoutingRuleSource`, `StaticRuleSource`, `ProjectFileRuleSource` |
| `Sources/IntakeKit/FlightControl/Router.swift` | `KindChain`, `RoutingContext`, `RouteOutcome`, `RouterCore` (assign, spill), `RuleRouter: Router` |
| `Sources/IntakeKit/FlightControl/RuleValidator.swift` | `RuleCompilerWire`, `RuleCompilerInput`, `RuleValidationError`, `RuleValidator` |
| `Sources/IntakeKit/FlightControl/RuleCompiler.swift` | `RuleProposal`, `RuleCompileOutcome`, `RuleCompiling`, `RuleCompilation`, `RuleCompiler`, `RoutingRule.record` |
| `Sources/IntakeKit/FlightControl/RuleCompilerPrompt.swift` | the compiler prompt and its strict schema |
| `Sources/IntakeKit/FlightControl/EncodeRouting.swift` | encode-time classification → registry proposals → router → `agent_context` per temp id |
| `Sources/IntakeKit/FlightControl/KindReroute.swift` | `TaskContextRow` (br list parsing), `KindReroute.plan` |
| `Sources/IntakeKit/ChangeSet.swift` (modify) | `KindProposal`; `NewBead.taskKind`/`kindProposal`; op coding |
| `Sources/IntakeKit/Triage.swift` (modify) | schema gains `taskKind`/`kindProposal`; kinds text in change-set rules; `initialPrompt(kinds:)` |
| `Sources/IntakeKit/RoundPrompts.swift` (modify) | `RoundContext.kinds`; change-set prompts pass kinds |
| `Sources/IntakeKit/RoundExecutor.swift` (modify) | reads the project's kinds into the round context |
| `Sources/FlightDeck/FlightControl/RoutingPreferences.swift` | `RoutingPreferences`; `PreferencesStore` routing accessors |
| `Sources/FlightDeck/Preferences/Preferences.swift` (modify) | `flightControlRouting` field |
| `Sources/FlightDeck/FlightControl/RoutingCatalogs.swift` | `ClaudeRoutingCatalog`, `CodexRoutingCatalog` |
| `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift` (modify, L3-0's file) | claude/codex `modelCatalog()` and `knobSchema` |
| `Sources/FlightDeck/Intake/BeadWriter.swift` (modify) | `--agent-context` on create; `writeBlock`; `BlockWriting` |
| `Sources/FlightDeck/FlightControl/EncodeRoutingProviding.swift` | the seam intake release asks for agent contexts |
| `Sources/FlightDeck/Intake/IntakeService.swift` (modify) | release passes routed contexts; triage prompt gets kinds |
| `Sources/FlightDeck/FlightControl/OpenTaskReader.swift` | `OpenTaskReading`, `BrOpenTaskReader` |
| `Sources/FlightDeck/FlightControl/RoutingService.swift` | rules CRUD/compile/confirm, router snapshot, hints |
| `Sources/FlightDeck/FlightControl/RoutingService+Kinds.swift` | kinds, new badges, rename/re-weight/merge + re-route, counts, encode provider |
| `Sources/FlightDeck/FlightControl/RoutingService+Live.swift` | `live`/`make`: the real launch's wiring, or the UI-test fixture |
| `Sources/FlightDeck/FlightControl/RoutingPresentation.swift` | `RuleRowPresentation`, `KindRowPresentation` |
| `Sources/FlightDeck/Preferences/UI/FlightControlSettingsTab.swift` | the Flight Control tab, section buttons, project picker |
| `Sources/FlightDeck/Preferences/UI/FlightControlRoutingPane.swift` | Routing pane, `RuleRow` |
| `Sources/FlightDeck/Preferences/UI/TaskKindsPane.swift` | Task kinds pane |
| `Sources/FlightDeck/FlightControl/RoutingUIFixture.swift` | `-FlightDeckRoutingFixture` service for XCUITest |
| `Sources/FlightDeck/Preferences/PreferencesTab.swift`, `UI/PreferencesView.swift`, `FlightDeckApp.swift`, `SessionStore.swift` (modify) | wiring |
| `UITests/FlightDeckUITests/RoutingUITests.swift` | XCUITest with screenshots |
| `scripts/test-routing-ui.sh` | the one runnable invocation for the routing UI tests |
| `Tests/FlightDeckTests/FlightControlL3/Routing/*.swift` | unit tests below |
| `Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/*` | compiler output, codex model list, encode output, br list |

`project.yml` needs no edit: both source roots and `Tests/FlightDeckTests` are globbed recursively,
and `Tests/FlightDeckTests/Fixtures` is a folder reference (subdirectories survive into the bundle).

---

### Task 1: The rule model and its plain-words form

**Files:**
- Create: `Sources/IntakeKit/FlightControl/RoutingRule.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingRuleTests.swift`

**Interfaces:**
- Consumes (L3-0): `HarnessID`, `PoolID`, `KindID`, `Harness` (IntakeKit, `Intake.swift:24`).
- Produces:
  - `public enum MatchTerm: Codable, Hashable, Sendable { case dimension(String, atLeast: Double); case kind(KindID) }`
  - `public enum RuleMatch: Codable, Equatable, Sendable { case any([MatchTerm]), all([MatchTerm]); var terms: [MatchTerm]; func holds(weights: [String: Double], chain: [KindID]) -> Bool }`
  - `public struct RuleAssign: Codable, Equatable, Sendable { harness: HarnessID; model: String; knobs: [String: String]; pool: PoolID; fallbackPool: PoolID?; modelDefaulted: Bool }`
  - `public struct CompiledRule: Codable, Equatable, Sendable { match: RuleMatch; assign: RuleAssign }`
  - `public enum RuleState: String, Codable, Sendable { draft, compiled, confirmed, failed }`
  - `public struct CompilerRef: Codable, Equatable, Sendable { harness: HarnessID; model: String }`
  - `public struct RuleCompilerSettings: Codable, Equatable, Sendable { harness: Harness; model: String; effort: String; static let default; var ref: CompilerRef }`
  - `public struct RoutingRule: Codable, Equatable, Sendable, Identifiable { id; sentence; compiled; state; failure; compiledAt; compiler; mutating func edit(sentence:); mutating func confirm() -> Bool }`
  - `public struct RoutingRuleFile: Codable, Equatable, Sendable { v: Int; rules: [RoutingRule] }`
  - `public enum RuleText { static func number(_:) -> String; static func compiled(_:) -> String }`

- [ ] **Step 0: Set up the worktree and confirm L3-0 is on master**

Use `superpowers:using-git-worktrees` to create the worktree (branch `flight-control-l3-routing`).
In the worktree, symlink the vendor build outputs (never commit them):

```bash
ln -s /Users/me/Projects/flight-deck/vendor/ghostty-artifacts vendor/ghostty-artifacts
ln -s /Users/me/Projects/flight-deck/vendor/boringssl-artifacts vendor/boringssl-artifacts
```

Confirm the contract is present:

```bash
rg -n "public protocol Router|public protocol KindRegistry|public protocol CapabilityIndex" Sources/IntakeKit/FlightControl/ContractProtocols.swift
rg -n "final class FakeKindRegistry|final class FakeCapabilityIndex|final class FakeRouter" Tests/FlightDeckTests/FlightControlL3/Fakes/ContractFakes.swift
rg -n "final class ClaudeRoutingCapabilities|final class CodexRoutingCapabilities" Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift
```

Expected: three, three and two matches. If any is missing, L3-0 has not merged: stop and report;
do not recreate contract types here.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// A rule is two things that must never drift apart: the sentence you wrote and the compiled
/// form that routes. These tests pin the JSON both storage places use (spec L3-R §2), the
/// rule that editing the sentence throws the compiled form away, and the plain-words line
/// Settings shows under each rule.
final class RoutingRuleTests: XCTestCase {
    private let specJSON = #"""
    {"id": "r3", "sentence": "Use Codex for unit and integration tests, and for complex algorithms",
     "compiled": {
       "match": {"any": [
         {"dimension": "test-authoring", "atLeast": 0.5},
         {"dimension": "algorithmic-reasoning", "atLeast": 0.6},
         {"kind": "tests"}]},
       "assign": {"harness": "codex", "model": "gpt-6-sol", "knobs": {"effort": "high"},
                  "pool": "codex-subs", "fallbackPool": null}},
     "state": "confirmed", "compiledAt": "2026-10-04T18:00:00Z", "compiler": {"harness": "claude", "model": "haiku"}}
    """#

    private var specRule: RoutingRule {
        RoutingRule(id: "r3", sentence: "Use Codex for unit and integration tests, and for complex algorithms",
                    compiled: CompiledRule(
                        match: .any([.dimension("test-authoring", atLeast: 0.5),
                                     .dimension("algorithmic-reasoning", atLeast: 0.6),
                                     .kind("tests")]),
                        assign: RuleAssign(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"],
                                           pool: "codex-subs")),
                    state: .confirmed, compiledAt: Date(timeIntervalSince1970: 1_790_964_000),
                    compiler: CompilerRef(harness: "claude", model: "haiku"))
    }

    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

    func testTheSpecsExampleDecodes() throws {
        let rule = try decoder().decode(RoutingRule.self, from: Data(specJSON.utf8))
        XCTAssertEqual(rule.compiled, specRule.compiled)
        XCTAssertEqual(rule.state, .confirmed)
        XCTAssertEqual(rule.compiler, CompilerRef(harness: "claude", model: "haiku"))
        XCTAssertFalse(rule.compiled?.assign.modelDefaulted ?? true)
    }

    func testRoundTripsThroughTheRuleFile() throws {
        let file = RoutingRuleFile(rules: [specRule, RoutingRule(id: "r4", sentence: "Use Claude for docs")])
        let back = try decoder().decode(RoutingRuleFile.self, from: encoder().encode(file))
        XCTAssertEqual(back, file)
        XCTAssertEqual(back.v, 1)
    }

    func testAKindTermEncodesOnlyItsKind() throws {
        let data = try JSONEncoder().encode(MatchTerm.kind("tests"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"kind":"tests"}"#)
    }

    func testCompiledTextIsTheSpecsSentence() {
        XCTAssertEqual(RuleText.compiled(specRule.compiled!),
                       "matches test-authoring ≥ 0.5, algorithmic-reasoning ≥ 0.6, or kind *tests* → codex · gpt-6-sol · effort high · pool codex-subs")
    }

    func testCompiledTextForAllWithADefaultedModelAndFallback() {
        let c = CompiledRule(match: .all([.dimension("debugging", atLeast: 0.7), .kind("investigate")]),
                             assign: RuleAssign(harness: "claude", model: "opus", pool: "claude-default",
                                                fallbackPool: "codex-default", modelDefaulted: true))
        XCTAssertEqual(RuleText.compiled(c),
                       "matches debugging ≥ 0.7 and kind *investigate* → claude · opus (default model) · pool claude-default · else pool codex-default")
    }

    func testEditingTheSentenceReturnsToDraftAndDropsTheCompiledForm() {
        var rule = specRule
        rule.edit(sentence: "Use Codex for tests only")
        XCTAssertEqual(rule.state, .draft)
        XCTAssertNil(rule.compiled); XCTAssertNil(rule.compiledAt); XCTAssertNil(rule.compiler); XCTAssertNil(rule.failure)
        var same = specRule
        same.edit(sentence: specRule.sentence)
        XCTAssertEqual(same, specRule, "re-entering the same sentence is not an edit")
    }

    func testOnlyACompiledRuleCanBeConfirmed() {
        var draft = RoutingRule(id: "r1", sentence: "x")
        XCTAssertFalse(draft.confirm()); XCTAssertEqual(draft.state, .draft)
        var compiled = specRule; compiled.state = .compiled
        XCTAssertTrue(compiled.confirm()); XCTAssertEqual(compiled.state, .confirmed)
        var failed = specRule; failed.state = .failed; failed.compiled = nil
        XCTAssertFalse(failed.confirm())
    }

    func testMatchHoldsOverWeightsAndTheMergeChain() {
        let any = RuleMatch.any([.dimension("test-authoring", atLeast: 0.5), .kind("tests")])
        XCTAssertTrue(any.holds(weights: ["test-authoring": 0.5], chain: ["x"]), "the threshold is inclusive")
        XCTAssertTrue(any.holds(weights: [:], chain: ["golden-tests", "tests"]))
        XCTAssertFalse(any.holds(weights: ["test-authoring": 0.49], chain: ["x"]))
        let all = RuleMatch.all([.dimension("test-authoring", atLeast: 0.5), .dimension("debugging", atLeast: 0.5)])
        XCTAssertFalse(all.holds(weights: ["test-authoring": 0.9], chain: []))
        XCTAssertTrue(all.holds(weights: ["test-authoring": 0.9, "debugging": 0.5], chain: []))
    }

    func testEmptyMatchesNeverHold() {
        XCTAssertFalse(RuleMatch.any([]).holds(weights: ["test-authoring": 1], chain: ["tests"]))
        XCTAssertFalse(RuleMatch.all([]).holds(weights: ["test-authoring": 1], chain: ["tests"]))
    }

    func testCompilerDefaultsToHeadlessHaiku() {
        XCTAssertEqual(RuleCompilerSettings.default, RuleCompilerSettings(harness: .claude, model: "haiku", effort: "low"))
        XCTAssertEqual(RuleCompilerSettings.default.ref, CompilerRef(harness: "claude", model: "haiku"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=RoutingRuleTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'RoutingRule' in scope`.

- [ ] **Step 3: Implement `RoutingRule.swift`**

```swift
import Foundation

/// One condition of a compiled rule (spec L3-R §2).
///
/// A dimension term holds when the task kind's weight on that dimension is at least `atLeast`;
/// a kind term holds when the task's kind is that kind or was merged into it. Dimension terms
/// are what let a rule route a kind that did not exist when the rule was written (success
/// criterion 2) — a rule made only of kind names would need recompiling for every new kind.
public enum MatchTerm: Codable, Hashable, Sendable {
    case dimension(String, atLeast: Double)
    case kind(KindID)

    private enum Key: String, CodingKey { case dimension, atLeast, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let kind = try c.decodeIfPresent(KindID.self, forKey: .kind) {
            self = .kind(kind)
        } else {
            self = .dimension(try c.decode(String.self, forKey: .dimension),
                              atLeast: try c.decode(Double.self, forKey: .atLeast))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .dimension(let d, let atLeast):
            try c.encode(d, forKey: .dimension)
            try c.encode(atLeast, forKey: .atLeast)
        case .kind(let k):
            try c.encode(k, forKey: .kind)
        }
    }
}

/// `{"any": [...]}` or `{"all": [...]}`.
public enum RuleMatch: Codable, Equatable, Sendable {
    case any([MatchTerm])
    case all([MatchTerm])

    public var terms: [MatchTerm] {
        switch self {
        case .any(let t): return t
        case .all(let t): return t
        }
    }

    private enum Key: String, CodingKey { case any, all }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let t = try c.decodeIfPresent([MatchTerm].self, forKey: .any) {
            self = .any(t)
        } else if let t = try c.decodeIfPresent([MatchTerm].self, forKey: .all) {
            self = .all(t)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "a match needs `any` or `all`"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .any(let t): try c.encode(t, forKey: .any)
        case .all(let t): try c.encode(t, forKey: .all)
        }
    }

    /// `chain` is the task's kind followed by every kind it was merged into (`KindChain`).
    ///
    /// An empty `any` and an empty `all` both fail. `all` of nothing is vacuously true in logic,
    /// and a rule that compiled to no conditions would then route every task in the project.
    public func holds(weights: [String: Double], chain: [KindID]) -> Bool {
        func one(_ term: MatchTerm) -> Bool {
            switch term {
            case .dimension(let d, let atLeast): return (weights[d] ?? 0) >= atLeast
            case .kind(let k): return chain.contains(k)
            }
        }
        switch self {
        case .any(let t): return t.contains(where: one)
        case .all(let t): return !t.isEmpty && t.allSatisfy(one)
        }
    }
}

/// Where a matching rule sends the task.
public struct RuleAssign: Codable, Equatable, Sendable {
    public var harness: HarnessID
    public var model: String
    public var knobs: [String: String]
    /// Never absent once validated: a sentence that names no pool gets the adapter's default
    /// pool at compile time, so the compiled text says where the work will go.
    public var pool: PoolID
    /// The explicit spill target a sentence names ("…, else claude-subs"). Tried first by spill.
    public var fallbackPool: PoolID?
    /// The sentence named no model and the compiler took the adapter's default. Shown in the
    /// compiled form so a later change of default is not a silent re-route.
    public var modelDefaulted: Bool

    public init(harness: HarnessID, model: String, knobs: [String: String] = [:], pool: PoolID,
                fallbackPool: PoolID? = nil, modelDefaulted: Bool = false) {
        self.harness = harness; self.model = model; self.knobs = knobs; self.pool = pool
        self.fallbackPool = fallbackPool; self.modelDefaulted = modelDefaulted
    }

    private enum CodingKeys: String, CodingKey { case harness, model, knobs, pool, fallbackPool, modelDefaulted }

    /// `knobs` and `modelDefaulted` are optional on read: the spec's own example omits
    /// `modelDefaulted`, and a hand-edited `routing.json` should not stop decoding over it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        harness = try c.decode(HarnessID.self, forKey: .harness)
        model = try c.decode(String.self, forKey: .model)
        knobs = try c.decodeIfPresent([String: String].self, forKey: .knobs) ?? [:]
        pool = try c.decode(PoolID.self, forKey: .pool)
        fallbackPool = try c.decodeIfPresent(PoolID.self, forKey: .fallbackPool)
        modelDefaulted = try c.decodeIfPresent(Bool.self, forKey: .modelDefaulted) ?? false
    }
}

public struct CompiledRule: Codable, Equatable, Sendable {
    public var match: RuleMatch
    public var assign: RuleAssign
    public init(match: RuleMatch, assign: RuleAssign) { self.match = match; self.assign = assign }
}

/// `draft` → `compiled` (waiting for you) → `confirmed`, or `failed`. Only `confirmed` routes.
public enum RuleState: String, Codable, Sendable { case draft, compiled, confirmed, failed }

/// Which model compiled a rule — recorded so a surprising compile can be traced to its compiler.
public struct CompilerRef: Codable, Equatable, Sendable {
    public var harness: HarnessID
    public var model: String
    public init(harness: HarnessID, model: String) { self.harness = harness; self.model = model }
}

/// The headless call that compiles a sentence. A cheap model by default: the output is a small,
/// schema-constrained object that a validator checks anyway (spec §3).
public struct RuleCompilerSettings: Codable, Equatable, Sendable {
    public var harness: Harness
    public var model: String
    public var effort: String
    public init(harness: Harness = .claude, model: String = "haiku", effort: String = "low") {
        self.harness = harness; self.model = model; self.effort = effort
    }
    public static let `default` = RuleCompilerSettings()
    public var ref: CompilerRef { CompilerRef(harness: HarnessID(harness.rawValue), model: model) }
}

public struct RoutingRule: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sentence: String
    public var compiled: CompiledRule?
    public var state: RuleState
    /// The first validation error of the last compile, shown inline when `state == .failed`.
    public var failure: String?
    public var compiledAt: Date?
    public var compiler: CompilerRef?

    public init(id: String, sentence: String, compiled: CompiledRule? = nil, state: RuleState = .draft,
                failure: String? = nil, compiledAt: Date? = nil, compiler: CompilerRef? = nil) {
        self.id = id; self.sentence = sentence; self.compiled = compiled; self.state = state
        self.failure = failure; self.compiledAt = compiledAt; self.compiler = compiler
    }

    /// Editing the sentence moves the rule back to draft (spec §2). The compiled form is dropped,
    /// not kept: a confirmed form compiled from the old words must not keep routing under new ones.
    public mutating func edit(sentence new: String) {
        guard new != sentence else { return }
        sentence = new
        compiled = nil; state = .draft; failure = nil; compiledAt = nil; compiler = nil
    }

    /// Only a compiled rule that is waiting for you can be confirmed.
    @discardableResult
    public mutating func confirm() -> Bool {
        guard state == .compiled, compiled != nil else { return false }
        state = .confirmed
        return true
    }
}

/// `.flightdeck/routing.json`.
public struct RoutingRuleFile: Codable, Equatable, Sendable {
    public var v: Int
    public var rules: [RoutingRule]
    public init(v: Int = 1, rules: [RoutingRule]) { self.v = v; self.rules = rules }
}

/// The compiled form in plain words, as Settings shows it under the sentence (spec §3). Kind
/// names are wrapped in `*…*` so the pane can render them italic through Markdown.
public enum RuleText {
    /// `%g`, so thresholds read `0.5`, not `0.500000`.
    public static func number(_ x: Double) -> String { String(format: "%g", x) }

    public static func compiled(_ c: CompiledRule) -> String {
        let parts = c.match.terms.map { term -> String in
            switch term {
            case .dimension(let d, let atLeast): return "\(d) ≥ \(number(atLeast))"
            case .kind(let k): return "kind *\(k.rawValue)*"
            }
        }
        let joiner: String
        if case .all = c.match { joiner = "and" } else { joiner = "or" }
        let lhs: String
        switch parts.count {
        case 0: lhs = "nothing"
        case 1: lhs = parts[0]
        case 2: lhs = "\(parts[0]) \(joiner) \(parts[1])"
        default: lhs = parts.dropLast().joined(separator: ", ") + ", \(joiner) " + parts[parts.count - 1]
        }
        var rhs = [c.assign.harness.rawValue, c.assign.model + (c.assign.modelDefaulted ? " (default model)" : "")]
        rhs += c.assign.knobs.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        rhs.append("pool \(c.assign.pool.rawValue)")
        if let fallback = c.assign.fallbackPool { rhs.append("else pool \(fallback.rawValue)") }
        return "matches \(lhs) → " + rhs.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=RoutingRuleTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 10 tests, with 0 failures` and no `error:` lines.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/RoutingRule.swift Tests/FlightDeckTests/FlightControlL3/Routing/RoutingRuleTests.swift
git commit -m "feat: add routing rules with a compiled form and a plain-words reading" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Rule storage — project file and global preferences

**Files:**
- Create: `Sources/IntakeKit/FlightControl/ProjectRoutingStore.swift`
- Create: `Sources/FlightDeck/FlightControl/RoutingPreferences.swift`
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift` (the `Preferences` struct, its `init`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingStorageTests.swift`

**Interfaces:**
- Consumes: Task 1 (`RoutingRule`, `RoutingRuleFile`, `RuleCompilerSettings`); `PreferencesStore`, `PreferencesPersisting`.
- Produces:
  - `public enum ProjectRulesLoad: Equatable, Sendable { case missing, loaded(RoutingRuleFile), invalid(String); var rules: [RoutingRule] }`
  - `public struct ProjectRoutingStore: Sendable { init(); static func fileURL(project: URL) -> URL; func load(project: URL) -> ProjectRulesLoad; func save(_ rules: [RoutingRule], project: URL) throws }`
  - `public struct ProjectRulesUnwritable: Error, Equatable { let why: String }`
  - `struct RoutingPreferences: Codable, Equatable { globalRules; compiler: RuleCompilerSettings?; seenKinds: [String: [String]]?; dismissedHints: [String: Date]? }`
  - `Preferences.flightControlRouting: RoutingPreferences?`
  - `extension PreferencesStore { var globalRoutingRules: [RoutingRule]; var routingCompilerSettings: RuleCompilerSettings; func seenKinds(project:) -> Set<KindID>; func markKindsSeen(_:project:); func isHintDismissed(ruleID:snapshot:) -> Bool; func dismissHint(ruleID:snapshot:) }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Global rules live in preferences, project rules in the repo (spec L3-R §2). The repo file is
/// the user's: it may be hand-edited, merged badly, or written by a newer Flight Deck. Routing
/// then treats it as empty (spec §8), and nothing here may overwrite it.
@MainActor
final class RoutingStorageTests: XCTestCase {
    private var project: URL!

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingStorageTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        var saves = 0
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences; saves += 1 }
    }

    private let rule = RoutingRule(id: "r1", sentence: "Use Claude for docs")

    func testAMissingFileIsNoRules() {
        XCTAssertEqual(ProjectRoutingStore().load(project: project), .missing)
        XCTAssertEqual(ProjectRoutingStore().load(project: project).rules, [])
    }

    func testSaveCreatesTheFileAndLoadReadsItBack() throws {
        try ProjectRoutingStore().save([rule], project: project)
        let url = ProjectRoutingStore.fileURL(project: project)
        XCTAssertEqual(url.path, project.appendingPathComponent(".flightdeck/routing.json").path)
        XCTAssertEqual(ProjectRoutingStore().load(project: project), .loaded(RoutingRuleFile(rules: [rule])))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "pretty-printed, so the repo file diffs line by line")
    }

    func testAnInvalidFileRoutesAsEmptyAndSaysWhy() throws {
        let url = ProjectRoutingStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let load = ProjectRoutingStore().load(project: project)
        guard case .invalid(let why) = load else { return XCTFail("\(load)") }
        XCTAssertFalse(why.isEmpty)
        XCTAssertEqual(load.rules, [])
    }

    func testANewerFileIsInvalidNotPartlyRead() throws {
        let url = ProjectRoutingStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"v":2,"rules":[]}"#.utf8).write(to: url)
        XCTAssertEqual(ProjectRoutingStore().load(project: project), .invalid("written by a newer Flight Deck (v2)"))
    }

    func testSaveRefusesToOverwriteAnInvalidFile() throws {
        let url = ProjectRoutingStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("<<<<<<< HEAD\n".utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try ProjectRoutingStore().save([rule], project: project)) {
            XCTAssertTrue($0 is ProjectRulesUnwritable)
        }
        XCTAssertEqual(try Data(contentsOf: url), broken, "the user's file is untouched")
    }

    func testGlobalRulesAndCompilerSurviveARelaunch() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.globalRoutingRules = [rule]
        store.routingCompilerSettings = RuleCompilerSettings(harness: .codex, model: "gpt-6-luna", effort: "low")
        let reopened = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reopened.globalRoutingRules, [rule])
        XCTAssertEqual(reopened.routingCompilerSettings.model, "gpt-6-luna")
    }

    func testAnUnconfiguredStoreHasNoRulesAndTheDefaultCompiler() {
        let store = PreferencesStore(persistence: nil)
        XCTAssertEqual(store.globalRoutingRules, [])
        XCTAssertEqual(store.routingCompilerSettings, .default)
    }

    func testAPreferencesBlobFromBeforeRoutingStillDecodes() throws {
        let old = try JSONEncoder().encode(Preferences())
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        obj.removeValue(forKey: "flightControlRouting")
        let back = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(back.flightControlRouting)
    }

    func testSeenKindsAreKeyedByStandardizedPathAndWriteOnlyWhenNew() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.markKindsSeen(["snapshot-tests"], project: "/w/p/")
        XCTAssertEqual(store.seenKinds(project: "/w/p"), ["snapshot-tests"])
        let saves = persistence.saves
        store.markKindsSeen(["snapshot-tests"], project: "/w/p")
        XCTAssertEqual(persistence.saves, saves, "re-marking a seen kind must not rewrite preferences")
    }

    func testADismissedHintStaysDismissedOnlyForItsSnapshot() {
        let store = PreferencesStore(persistence: nil)
        let d1 = Date(timeIntervalSince1970: 1_000), d2 = Date(timeIntervalSince1970: 2_000)
        XCTAssertFalse(store.isHintDismissed(ruleID: "r3", snapshot: d1))
        store.dismissHint(ruleID: "r3", snapshot: d1)
        XCTAssertTrue(store.isHintDismissed(ruleID: "r3", snapshot: d1))
        XCTAssertFalse(store.isHintDismissed(ruleID: "r3", snapshot: d2), "a new index snapshot brings the hint back")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=RoutingStorageTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'ProjectRoutingStore' in scope`.

- [ ] **Step 3: Implement `ProjectRoutingStore.swift`**

```swift
import Foundation

/// What `.flightdeck/routing.json` holds right now.
public enum ProjectRulesLoad: Equatable, Sendable {
    case missing
    case loaded(RoutingRuleFile)
    case invalid(String)

    /// What routes. A missing or invalid file routes as no project rules (spec L3-R §8); the
    /// global list still applies.
    public var rules: [RoutingRule] {
        if case .loaded(let file) = self { return file.rules }
        return []
    }
}

public struct ProjectRulesUnwritable: Error, Equatable, Sendable {
    public let why: String
}

/// `.flightdeck/routing.json`: a project's rules, in the repo so they are versioned with it.
public struct ProjectRoutingStore: Sendable {
    public init() {}

    public static func fileURL(project: URL) -> URL {
        project.appendingPathComponent(".flightdeck", isDirectory: true).appendingPathComponent("routing.json")
    }

    public func load(project: URL) -> ProjectRulesLoad {
        let url = Self.fileURL(project: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .invalid("routing.json could not be read") }
        // `v` first, on its own: a newer file must be reported as newer, not as whatever
        // decoding error its new fields happen to trip.
        struct Version: Decodable { let v: Int? }
        if let v = (try? JSONDecoder().decode(Version.self, from: data))?.v, v > 1 {
            return .invalid("written by a newer Flight Deck (v\(v))")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return .loaded(try decoder.decode(RoutingRuleFile.self, from: data)) }
        catch { return .invalid("\(error)") }
    }

    /// Refuses while the current file is invalid. That file is the user's to fix — a merge
    /// conflict, a hand edit, a newer version — and replacing it with Settings' view of "no
    /// rules plus one" would destroy whatever they had.
    public func save(_ rules: [RoutingRule], project: URL) throws {
        if case .invalid(let why) = load(project: project) { throw ProjectRulesUnwritable(why: why) }
        let url = Self.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(RoutingRuleFile(rules: rules)).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Add the preferences field**

In `Sources/FlightDeck/Preferences/Preferences.swift`, in `struct Preferences`, after the
`terminalFontSize` property add:

```swift
    /// Flight Control routing (L3-R): the global rule list, the rule compiler, which planning
    /// kinds you have seen and which rule hints you dismissed. Optional for exactly the reason
    /// `confirmations` is — see that property's comment.
    var flightControlRouting: RoutingPreferences?
```

Add the init parameter after `terminalFontSize: Float? = nil` (keep the comma on the line before):

```swift
        terminalFontSize: Float? = nil,
        flightControlRouting: RoutingPreferences? = nil
```

and the assignment after `self.terminalFontSize = terminalFontSize`:

```swift
        self.flightControlRouting = flightControlRouting
```

- [ ] **Step 5: Implement `RoutingPreferences.swift`**

```swift
import Foundation
import IntakeKit

/// The global half of routing state. Project rules are not here: they live in the project's
/// own `.flightdeck/routing.json` so they travel with the repo.
struct RoutingPreferences: Codable, Equatable {
    var globalRules: [RoutingRule]
    var compiler: RuleCompilerSettings?
    /// Standardized project path → kind ids you have opened. Per-user, so not in `kinds.json`.
    var seenKinds: [String: [String]]?
    /// Rule id → the index snapshot date whose hint you dismissed (spec §7).
    var dismissedHints: [String: Date]?

    init(globalRules: [RoutingRule] = [], compiler: RuleCompilerSettings? = nil,
         seenKinds: [String: [String]]? = nil, dismissedHints: [String: Date]? = nil) {
        self.globalRules = globalRules; self.compiler = compiler
        self.seenKinds = seenKinds; self.dismissedHints = dismissedHints
    }
}

extension PreferencesStore {
    /// The spelling `PreferencesStore.key` uses for project settings, so `/p/` and `/p` are one project.
    private static func routingKey(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private var routing: RoutingPreferences { preferences.flightControlRouting ?? RoutingPreferences() }

    /// Writes only on a real change: `preferences`' didSet persists every assignment, and the
    /// Task kinds pane marks kinds seen from view callbacks.
    private func mutateRouting(_ body: (inout RoutingPreferences) -> Void) {
        var next = routing
        body(&next)
        guard next != routing else { return }
        preferences.flightControlRouting = next
    }

    var globalRoutingRules: [RoutingRule] {
        get { routing.globalRules }
        set { mutateRouting { $0.globalRules = newValue } }
    }

    var routingCompilerSettings: RuleCompilerSettings {
        get { routing.compiler ?? .default }
        set { mutateRouting { $0.compiler = newValue } }
    }

    func seenKinds(project: String) -> Set<KindID> {
        Set((routing.seenKinds?[Self.routingKey(project)] ?? []).map(KindID.init(rawValue:)))
    }

    func markKindsSeen(_ ids: [KindID], project: String) {
        let key = Self.routingKey(project)
        let seen = seenKinds(project: project)
        let fresh = ids.filter { !seen.contains($0) }
        guard !fresh.isEmpty else { return }
        mutateRouting { r in
            var map = r.seenKinds ?? [:]
            map[key, default: []] += fresh.map(\.rawValue)
            r.seenKinds = map
        }
    }

    func isHintDismissed(ruleID: String, snapshot: Date) -> Bool {
        routing.dismissedHints?[ruleID] == snapshot
    }

    func dismissHint(ruleID: String, snapshot: Date) {
        mutateRouting { r in
            var map = r.dismissedHints ?? [:]
            map[ruleID] = snapshot
            r.dismissedHints = map
        }
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=RoutingStorageTests,PreferencesTabTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 14 tests, with 0 failures` (10 new + 4 existing) and no `error:` lines.

- [ ] **Step 7: Commit**

```bash
git add Sources/IntakeKit/FlightControl/ProjectRoutingStore.swift Sources/FlightDeck/FlightControl/RoutingPreferences.swift Sources/FlightDeck/Preferences/Preferences.swift Tests/FlightDeckTests/FlightControlL3/Routing/RoutingStorageTests.swift
git commit -m "feat: keep global routing rules in preferences and project rules in the repo" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The kind registry, backed by `.flightdeck/kinds.json`

**Files:**
- Create: `Sources/IntakeKit/FlightControl/KindRegistryStore.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/KindRegistryStoreTests.swift`

**Interfaces:**
- Consumes (L3-0): `KindRegistry`, `TaskKind`, `KindStatus`, `KindOrigin`, `KindValidationError`, `KindRegistryFile`, `SeedKinds`, `KindID.normalized`.
- Produces:
  - `public enum KindRegistryError: Error, Equatable, Sendable { unreadable(String), newerVersion(Int), unknownKind(KindID), invalid(KindValidationError), mergeIntoSelf(KindID), mergeIntoMerged(KindID); var message: String }`
  - `public final class KindRegistryStore: KindRegistry, @unchecked Sendable { init(now:); static func fileURL(project:) -> URL; static func promptKinds(project:) -> [TaskKind]; func kinds(project:) throws -> [TaskKind]; func propose(_:project:) throws -> TaskKind; func rename(_:to:project:) throws; func reweight(_:dimensions:project:) throws; func merge(_:into:project:) throws }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// The registry is a repo file planning agents read and planning releases write. These tests
/// pin what routing leans on: a new project sees the seed set without a write, a proposal that
/// names an existing kind reuses it, and a file the store cannot read is never overwritten.
final class KindRegistryStoreTests: XCTestCase {
    private var project: URL!
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private var store: KindRegistryStore!

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("KindRegistryStoreTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let at = self.at
        store = KindRegistryStore(now: { at })
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private var file: URL { KindRegistryStore.fileURL(project: project) }

    private func proposal(_ name: String, _ dims: [String: Double] = ["test-authoring": 0.8, "agentic-coding": 0.3]) -> TaskKind {
        TaskKind(id: KindID.normalized(name), name: name, description: "Write or update snapshot/golden-file tests",
                 dimensions: dims, origin: .planning, status: .active, createdAt: at)
    }

    func testANewProjectSeesTheSeedSetWithoutAWrite() throws {
        XCTAssertEqual(try store.kinds(project: project).map(\.id), SeedKinds.all(createdAt: at).map(\.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAProposalIsWrittenBesideTheSeeds() throws {
        let added = try store.propose(proposal("Snapshot Tests"), project: project)
        XCTAssertEqual(added.id, "snapshot-tests")
        XCTAssertEqual(added.origin, .planning)
        let kinds = try store.kinds(project: project)
        XCTAssertEqual(kinds.count, SeedKinds.all(createdAt: at).count + 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(file.path, project.appendingPathComponent(".flightdeck/kinds.json").path)
    }

    func testAProposalWhoseNameNormalizesToAnExistingKindReusesIt() throws {
        _ = try store.propose(proposal("Snapshot Tests"), project: project)
        let again = try store.propose(proposal("snapshot   tests!!"), project: project)
        XCTAssertEqual(again.id, "snapshot-tests")
        XCTAssertEqual(try store.kinds(project: project).filter { $0.id == "snapshot-tests" }.count, 1)
        let seed = try store.propose(proposal("TESTS"), project: project)
        XCTAssertEqual(seed.origin, .seed, "a proposal named like a seed kind is that seed kind")
    }

    func testAProposalWithNoUsableNameIsRefusedAndWritesNothing() {
        XCTAssertThrowsError(try store.propose(proposal("!!!"), project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .invalid(.emptyName))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAProposalWithAnUnknownDimensionIsRefused() {
        XCTAssertThrowsError(try store.propose(proposal("Vibes", ["vibes": 0.9]), project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .invalid(.unknownDimension("vibes")))
        }
    }

    func testRenameKeepsTheId() throws {
        try store.rename("algorithm", to: "Algorithms and data structures", project: project)
        let k = try XCTUnwrap(try store.kinds(project: project).first { $0.id == "algorithm" })
        XCTAssertEqual(k.name, "Algorithms and data structures")
        XCTAssertThrowsError(try store.rename("nope", to: "x", project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .unknownKind("nope"))
        }
    }

    func testReweightValidates() throws {
        try store.reweight("docs", dimensions: ["docs-prose": 0.7], project: project)
        XCTAssertEqual(try store.kinds(project: project).first { $0.id == "docs" }?.dimensions, ["docs-prose": 0.7])
        XCTAssertThrowsError(try store.reweight("docs", dimensions: ["docs-prose": 1.4], project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .invalid(.weightOutOfRange("docs-prose", 1.4)))
        }
    }

    func testMergeMarksTheKindMergedAndRefusesBadTargets() throws {
        _ = try store.propose(proposal("Snapshot Tests"), project: project)
        try store.merge("snapshot-tests", into: "tests", project: project)
        let kinds = try store.kinds(project: project)
        XCTAssertEqual(kinds.first { $0.id == "snapshot-tests" }?.status, .merged(into: "tests"))
        XCTAssertEqual(KindResolution.resolve("snapshot-tests", in: kinds)?.id, "tests")
        XCTAssertThrowsError(try store.merge("tests", into: "tests", project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .mergeIntoSelf("tests"))
        }
        XCTAssertThrowsError(try store.merge("docs", into: "snapshot-tests", project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .mergeIntoMerged("snapshot-tests"))
        }
    }

    func testAnUnreadableFileThrowsAndIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("{\"v\":1,\"kinds\":[".utf8)
        try broken.write(to: file)
        XCTAssertThrowsError(try store.kinds(project: project))
        XCTAssertThrowsError(try store.propose(proposal("Snapshot Tests"), project: project))
        XCTAssertEqual(try Data(contentsOf: file), broken)
    }

    func testANewerFileIsRefused() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"v":2,"kinds":[]}"#.utf8).write(to: file)
        XCTAssertThrowsError(try store.kinds(project: project)) {
            XCTAssertEqual($0 as? KindRegistryError, .newerVersion(2))
        }
    }

    func testTheSharedFixtureReads() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try L3Fixtures.data("kinds").write(to: file)
        let kinds = try store.kinds(project: project)
        XCTAssertEqual(kinds.map(\.id), ["tests", "snapshot-tests", "golden-tests", "algorithm"])
    }

    func testPromptKindsIsSeedsForANewProjectAndEmptyForABrokenFile() throws {
        XCTAssertEqual(KindRegistryStore.promptKinds(project: project).count, SeedKinds.all(createdAt: at).count)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: file)
        XCTAssertEqual(KindRegistryStore.promptKinds(project: project), [])
    }

    func testItIsTheContractsKindRegistry() throws {
        let registry: any KindRegistry = store
        XCTAssertFalse(try registry.kinds(project: project).isEmpty)
    }
}
```

`L3Fixtures` is L3-0's loader, declared in the test target itself
(`Tests/FlightDeckTests/FlightControlL3/L3Fixtures.swift`), so `import IntakeKit` is enough here.

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=KindRegistryStoreTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'KindRegistryStore' in scope`.

- [ ] **Step 3: Implement `KindRegistryStore.swift`**

```swift
import Foundation

public enum KindRegistryError: Error, Equatable, Sendable {
    case unreadable(String)
    case newerVersion(Int)
    case unknownKind(KindID)
    case invalid(KindValidationError)
    case mergeIntoSelf(KindID)
    case mergeIntoMerged(KindID)

    /// Shown in Settings → Task kinds.
    public var message: String {
        switch self {
        case .unreadable(let why): return "kinds.json could not be read: \(why)"
        case .newerVersion(let v): return "kinds.json was written by a newer Flight Deck (v\(v))"
        case .unknownKind(let id): return "unknown task kind \(id.rawValue)"
        case .invalid(let e):
            switch e {
            case .emptyName: return "a kind needs a name"
            case .unknownDimension(let d): return "unknown dimension \(d)"
            case .weightOutOfRange(let d, let w): return "\(d) weight \(RuleText.number(w)) is outside 0–1"
            }
        case .mergeIntoSelf(let id): return "\(id.rawValue) cannot be merged into itself"
        case .mergeIntoMerged(let id): return "\(id.rawValue) has itself been merged; merge into the kind it points to"
        }
    }
}

/// The project's kind registry, `.flightdeck/kinds.json` (L3-0 §6) — the real `KindRegistry`.
///
/// In the repo on purpose: it is versioned with the project, and planning agents read it. A
/// project with no file sees the seed set and nothing is written until something changes, so
/// opening Settings on a repo never dirties its working tree.
///
/// The lock serializes read-modify-write within this process. The only other writer is a
/// person editing the file; a file this store cannot read is reported and never overwritten.
public final class KindRegistryStore: KindRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    public static func fileURL(project: URL) -> URL {
        project.appendingPathComponent(".flightdeck", isDirectory: true).appendingPathComponent("kinds.json")
    }

    /// The kinds a planning prompt offers. Empty when the file is unreadable: a broken registry
    /// must not stop a round, and its tasks then route by the fallback kind.
    public static func promptKinds(project: URL) -> [TaskKind] {
        (try? KindRegistryStore().kinds(project: project)) ?? []
    }

    public func kinds(project: URL) throws -> [TaskKind] {
        try lock.withLock { try read(project).kinds }
    }

    /// Adds `kind` under the id its name normalizes to, or returns the kind that id already
    /// names. Reusing by normalized name is what stops "Snapshot Tests" and "snapshot tests"
    /// from becoming two kinds that each route on their own.
    public func propose(_ kind: TaskKind, project: URL) throws -> TaskKind {
        try lock.withLock {
            var file = try read(project)
            let id = KindID.normalized(kind.name)
            guard !id.rawValue.isEmpty else { throw KindRegistryError.invalid(.emptyName) }
            if let existing = file.kinds.first(where: { $0.id == id }) { return existing }
            var added = kind
            added.id = id
            try Self.validate(added)
            file.kinds.append(added)
            try write(file, project)
            return added
        }
    }

    public func rename(_ id: KindID, to name: String, project: URL) throws {
        try mutate(project) { file in
            guard let i = file.kinds.firstIndex(where: { $0.id == id }) else { throw KindRegistryError.unknownKind(id) }
            var k = file.kinds[i]
            k.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            try Self.validate(k)
            file.kinds[i] = k
        }
    }

    public func reweight(_ id: KindID, dimensions: [String: Double], project: URL) throws {
        try mutate(project) { file in
            guard let i = file.kinds.firstIndex(where: { $0.id == id }) else { throw KindRegistryError.unknownKind(id) }
            var k = file.kinds[i]
            k.dimensions = dimensions
            try Self.validate(k)
            file.kinds[i] = k
        }
    }

    /// Marks `id` as `merged:<target>`. No task is rewritten: blocks keep naming `id`, and
    /// resolution follows the link. The target must be live — merging into a kind that was
    /// itself merged would build a chain someone has to read twice to follow.
    public func merge(_ id: KindID, into target: KindID, project: URL) throws {
        try mutate(project) { file in
            guard id != target else { throw KindRegistryError.mergeIntoSelf(id) }
            guard let i = file.kinds.firstIndex(where: { $0.id == id }) else { throw KindRegistryError.unknownKind(id) }
            guard let t = file.kinds.first(where: { $0.id == target }) else { throw KindRegistryError.unknownKind(target) }
            if case .merged = t.status { throw KindRegistryError.mergeIntoMerged(target) }
            file.kinds[i].status = .merged(into: target)
        }
    }

    // MARK: - File

    private static func validate(_ kind: TaskKind) throws {
        do { try kind.validate() } catch let e as KindValidationError { throw KindRegistryError.invalid(e) }
    }

    private func mutate(_ project: URL, _ body: (inout KindRegistryFile) throws -> Void) throws {
        try lock.withLock {
            var file = try read(project)
            try body(&file)
            try write(file, project)
        }
    }

    private func read(_ project: URL) throws -> KindRegistryFile {
        let url = Self.fileURL(project: project)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return KindRegistryFile(kinds: SeedKinds.all(createdAt: now()))
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw KindRegistryError.unreadable("\(error)") }
        struct Version: Decodable { let v: Int? }
        if let v = (try? JSONDecoder().decode(Version.self, from: data))?.v, v > 1 {
            throw KindRegistryError.newerVersion(v)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(KindRegistryFile.self, from: data) }
        catch { throw KindRegistryError.unreadable("\(error)") }
    }

    private func write(_ file: KindRegistryFile, _ project: URL) throws {
        let url = Self.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=KindRegistryStoreTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 13 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/KindRegistryStore.swift Tests/FlightDeckTests/FlightControlL3/Routing/KindRegistryStoreTests.swift
git commit -m "feat: store each project's task kinds in .flightdeck/kinds.json, seeded on first read" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 4: The router — first match, index fallback, default

**Files:**
- Create: `Sources/IntakeKit/FlightControl/RoutingSeams.swift`
- Create: `Sources/IntakeKit/FlightControl/Router.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingTestData.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RouterTests.swift`

**Interfaces:**
- Consumes (L3-0): `CapabilityIndex`, `ScoredModel`, `ModelRef`, `AdapterCatalogs`, `Assignment`, `ExecutionBlock`, `AssignmentSource`, `KindResolution`, `TaskKind`; test fake `FakeCapabilityIndex`. Task 1 (`RoutingRule`, `RuleMatch`, `RuleAssign`, `RuleText`), Task 2 (`ProjectRoutingStore`).
- Produces:
  - `public struct PoolSummary: Codable, Hashable, Sendable { id: PoolID; harness: HarnessID; label: String }`
  - `public protocol PoolDirectory: Sendable { func pools() -> [PoolSummary]; func defaultPool(for: HarnessID) -> PoolID? }`, `public struct DefaultPoolDirectory: PoolDirectory { init(harnesses: [HarnessID]) }`
  - `public struct NullCapabilityIndex: CapabilityIndex`
  - `public struct RuleHint: Equatable, Sendable { ruleID: String; text: String; snapshotDate: Date }`, `public protocol RuleHintSource: Sendable { func hint(for: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? }`, `public struct NoRuleHints: RuleHintSource`
  - `public struct RuleLists`, `public protocol RoutingRuleSource: Sendable { func rules(project: URL) -> RuleLists }`, `public struct StaticRuleSource`, `public struct ProjectFileRuleSource`
  - `public enum KindChain { static func ids(from: KindID, in: [TaskKind]) -> [KindID] }`
  - `public struct RoutingContext: Sendable` (fields below), `public enum RouteOutcome: Equatable, Sendable { routed(Assignment), unroutable(String) }`
  - `public enum RouterCore { static let defaultConfidenceFloor = 0.5; static func assign(kind: TaskKind, _ ctx: RoutingContext) -> RouteOutcome }`
  - Test support `enum RoutingTestData` (kinds, catalogs, pools, `rule(...)`, `r3(...)`, `context(...)`).

- [ ] **Step 1: Write the shared test data**

`Tests/FlightDeckTests/FlightControlL3/Routing/RoutingTestData.swift`:

```swift
import Foundation
import IntakeKit

/// The routing inputs every L3-R table test routes against, in one place, so each test's own
/// lines are only the case it pins.
enum RoutingTestData {
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    static func kind(_ id: KindID, _ dims: [String: Double], origin: KindOrigin = .seed,
                     status: KindStatus = .active) -> TaskKind {
        TaskKind(id: id, name: id.rawValue, description: "d", dimensions: dims, origin: origin, status: status, createdAt: at)
    }

    static let tests = kind("tests", ["test-authoring": 0.9, "agentic-coding": 0.4])
    static let snapshot = kind("snapshot-tests", ["test-authoring": 0.8, "agentic-coding": 0.3], origin: .planning)
    static let golden = kind("golden-tests", ["test-authoring": 0.8], origin: .planning, status: .merged(into: "snapshot-tests"))
    static let algorithm = kind("algorithm", ["algorithmic-reasoning": 0.9, "agentic-coding": 0.3])
    static let docs = kind("docs", ["docs-prose": 0.9])
    static let kinds = [tests, snapshot, golden, algorithm, docs]

    static let catalogs = AdapterCatalogs([
        AdapterCatalog(harness: "codex",
                       models: [ModelEntry(id: "gpt-6-sol", displayName: "GPT-6-Sol", knobs: ["effort"]),
                                ModelEntry(id: "gpt-6-luna", displayName: "GPT-6-Luna", knobs: ["effort"])],
                       knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "gpt-6-sol", enabled: true),
        AdapterCatalog(harness: "claude",
                       models: [ModelEntry(id: "opus", displayName: "Opus", knobs: ["effort"]),
                                ModelEntry(id: "haiku", displayName: "Haiku", knobs: ["effort"])],
                       knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "opus", enabled: true),
    ])

    /// `catalogs` with the named harnesses switched off.
    static func catalogsDisabling(_ off: Set<HarnessID>) -> AdapterCatalogs {
        AdapterCatalogs(catalogs.order.compactMap { h -> AdapterCatalog? in
            guard var c = catalogs.byHarness[h] else { return nil }
            if off.contains(h) { c.enabled = false }
            return c
        })
    }

    static let pools = [
        PoolSummary(id: "codex-default", harness: "codex", label: "codex"),
        PoolSummary(id: "codex-subs", harness: "codex", label: "codex subscriptions"),
        PoolSummary(id: "claude-default", harness: "claude", label: "claude"),
        PoolSummary(id: "claude-subs", harness: "claude", label: "claude subscriptions"),
    ]
    static let defaultPools: [HarnessID: PoolID] = ["codex": "codex-default", "claude": "claude-default"]

    static func rule(_ id: String, _ match: RuleMatch, _ harness: HarnessID, _ model: String,
                     knobs: [String: String] = [:], pool: PoolID, fallbackPool: PoolID? = nil,
                     state: RuleState = .confirmed) -> RoutingRule {
        RoutingRule(id: id, sentence: "rule \(id)",
                    compiled: CompiledRule(match: match, assign: RuleAssign(harness: harness, model: model, knobs: knobs,
                                                                            pool: pool, fallbackPool: fallbackPool)),
                    state: state)
    }

    /// The spec's example (L3-R §2): codex for tests and hard algorithms.
    static func r3(pool: PoolID = "codex-subs", fallbackPool: PoolID? = nil, state: RuleState = .confirmed) -> RoutingRule {
        rule("r3", .any([.dimension("test-authoring", atLeast: 0.5), .dimension("algorithmic-reasoning", atLeast: 0.6),
                         .kind("tests")]),
             "codex", "gpt-6-sol", knobs: ["effort": "high"], pool: pool, fallbackPool: fallbackPool, state: state)
    }

    static func context(project: [RoutingRule] = [], global: [RoutingRule] = [], kinds: [TaskKind] = RoutingTestData.kinds,
                        catalogs: AdapterCatalogs = RoutingTestData.catalogs, pools: [PoolSummary] = RoutingTestData.pools,
                        defaultPools: [HarnessID: PoolID] = RoutingTestData.defaultPools,
                        defaultHarness: HarnessID? = "claude",
                        index: any CapabilityIndex = NullCapabilityIndex()) -> RoutingContext {
        RoutingContext(projectRules: project, globalRules: global, kinds: kinds, catalogs: catalogs, pools: pools,
                       defaultPools: defaultPools, defaultHarness: defaultHarness, index: index, now: at)
    }
}
```

- [ ] **Step 2: Write the failing router tests**

```swift
import XCTest
import IntakeKit

/// Table tests over (rules × registry × index × catalogs × pools), spec L3-R §9. The router is a
/// pure function of its context, so every case builds the context it needs and reads the block.
final class RouterTests: XCTestCase {
    private typealias D = RoutingTestData

    private func block(_ outcome: RouteOutcome, file: StaticString = #filePath, line: UInt = #line) -> ExecutionBlock? {
        guard case .routed(let a) = outcome else { XCTFail("unroutable: \(outcome)", file: file, line: line); return nil }
        return a.block
    }

    func testFirstConfirmedRuleMatchesAndRecordsWhy() throws {
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [D.r3()]))))
        XCTAssertEqual(b.kind, "snapshot-tests")
        XCTAssertEqual(b.harness, "codex"); XCTAssertEqual(b.model, "gpt-6-sol")
        XCTAssertEqual(b.knobs, ["effort": "high"]); XCTAssertEqual(b.pool, "codex-subs")
        XCTAssertEqual(b.source, AssignmentSource(by: .rule, ruleId: "r3", reason: "test-authoring 0.8 → codex", at: D.at))
        XCTAssertFalse(b.pinned); XCTAssertNil(b.host)
    }

    func testProjectRulesAreCheckedBeforeGlobalRules() throws {
        let p1 = D.rule("p1", .any([.dimension("test-authoring", atLeast: 0.5)]), "claude", "opus", pool: "claude-subs")
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(project: [p1], global: [D.r3()]))))
        XCTAssertEqual(b.source.ruleId, "p1"); XCTAssertEqual(b.pool, "claude-subs")
    }

    func testTheFirstMatchWinsWithinAList() throws {
        let rA = D.rule("rA", .any([.dimension("docs-prose", atLeast: 0.5)]), "claude", "haiku", pool: "claude-default")
        let rB = D.rule("rB", .any([.dimension("test-authoring", atLeast: 0.5)]), "claude", "opus", pool: "claude-default")
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [rA, rB, D.r3()]))))
        XCTAssertEqual(b.source.ruleId, "rB")
    }

    func testOnlyConfirmedRulesRoute() throws {
        for state in [RuleState.draft, .compiled, .failed] {
            let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [D.r3(state: state)]))))
            XCTAssertEqual(b.source.by, .default, "\(state)")
        }
    }

    func testAllNeedsEveryTerm() throws {
        let both = D.rule("both", .all([.dimension("test-authoring", atLeast: 0.5), .dimension("algorithmic-reasoning", atLeast: 0.5)]),
                          "codex", "gpt-6-sol", pool: "codex-default")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [both])))).source.by, .default)
        let fuzz = D.kind("property-tests", ["test-authoring": 0.7, "algorithmic-reasoning": 0.8])
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: fuzz, D.context(global: [both])))).source.ruleId, "both")
    }

    func testAnEmptyMatchNeverMatches() throws {
        let anyNothing = D.rule("e1", .any([]), "codex", "gpt-6-sol", pool: "codex-default")
        let allNothing = D.rule("e2", .all([]), "codex", "gpt-6-sol", pool: "codex-default")
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.tests, D.context(global: [anyNothing, allNothing]))))
        XCTAssertEqual(b.source.by, .default)
    }

    func testKindTermMatchesMergedKindsButNotTheReverse() throws {
        let toSnapshot = D.rule("k1", .any([.kind("snapshot-tests")]), "codex", "gpt-6-sol", pool: "codex-default")
        let golden = try XCTUnwrap(block(RouterCore.assign(kind: D.golden, D.context(global: [toSnapshot]))))
        XCTAssertEqual(golden.source.ruleId, "k1", "golden-tests was merged into snapshot-tests")
        XCTAssertEqual(golden.source.reason, "kind snapshot-tests → codex")
        XCTAssertEqual(golden.kind, "golden-tests", "the block keeps the task's own kind; resolution happens on read")

        let toGolden = D.rule("k2", .any([.kind("golden-tests")]), "codex", "gpt-6-sol", pool: "codex-default")
        let snapshot = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [toGolden]))))
        XCTAssertEqual(snapshot.source.by, .default, "a merge points one way only")
    }

    func testANewKindRoutesByDimensionWithoutARecompile() throws {
        let proposed = D.kind("property-tests", ["test-authoring": 0.85], origin: .planning)
        let b = try XCTUnwrap(block(RouterCore.assign(kind: proposed, D.context(global: [D.r3()], kinds: D.kinds + [proposed]))))
        XCTAssertEqual(b.source.ruleId, "r3"); XCTAssertEqual(b.harness, "codex")
    }

    func testRuleWhoseModelLeftTheCatalogIsSkipped() throws {
        let retired = D.rule("old", .any([.dimension("test-authoring", atLeast: 0.5)]), "codex", "gpt-5-retired", pool: "codex-default")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [retired, D.r3()])))).source.ruleId, "r3")

        let noPool = D.rule("np", .any([.dimension("test-authoring", atLeast: 0.5)]), "codex", "gpt-6-sol", pool: "deleted-pool")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [noPool, D.r3()])))).source.ruleId, "r3")

        let badKnob = D.rule("bk", .any([.dimension("test-authoring", atLeast: 0.5)]), "codex", "gpt-6-sol",
                             knobs: ["effort": "max"], pool: "codex-default")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, D.context(global: [badKnob, D.r3()])))).source.ruleId, "r3")

        let off = D.context(global: [D.r3()], catalogs: D.catalogsDisabling(["codex"]))
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.snapshot, off)))
        XCTAssertEqual(b.source.by, .default); XCTAssertEqual(b.harness, "claude")
    }

    private func index(_ rows: [(HarnessID, String, Double, Double)]) -> FakeCapabilityIndex {
        let i = FakeCapabilityIndex()
        for (h, m, score, confidence) in rows {
            let ref = ModelRef(harness: h, model: m)
            i.scores[ref] = ScoredModel(model: ref, score: score, confidence: confidence)
        }
        return i
    }

    func testTheIndexTakesTheBestModelAboveTheFloor() throws {
        let i = index([("claude", "haiku", 0.9, 0.4), ("codex", "gpt-6-luna", 0.8, 0.7), ("claude", "opus", 0.7, 0.9)])
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(index: i))))
        XCTAssertEqual(b.harness, "codex"); XCTAssertEqual(b.model, "gpt-6-luna"); XCTAssertEqual(b.pool, "codex-default")
        XCTAssertEqual(b.knobs, [:])
        XCTAssertEqual(b.source, AssignmentSource(by: .index, reason: "index: codex/gpt-6-luna scores 0.8 for docs (confidence 0.7)", at: D.at))
    }

    func testAnIndexBelowTheFloorFallsToTheDefault() throws {
        let i = index([("codex", "gpt-6-luna", 0.8, 0.4), ("claude", "opus", 0.7, 0.49)])
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(index: i))))
        XCTAssertEqual(b.harness, "claude"); XCTAssertEqual(b.model, "opus"); XCTAssertEqual(b.pool, "claude-default")
        XCTAssertEqual(b.source, AssignmentSource(by: .default, reason: "default agent claude: no rule matched and the index had no confident answer", at: D.at))
    }

    func testTheFloorIsTheContextsToSet() throws {
        var ctx = D.context(index: index([("claude", "haiku", 0.9, 0.4)]))
        ctx.confidenceFloor = 0.3
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.docs, ctx))).model, "haiku")
    }

    func testOnlyAgentsWithAPoolAreIndexCandidates() throws {
        let i = index([("codex", "gpt-6-luna", 0.95, 0.9), ("claude", "opus", 0.7, 0.9)])
        let b = try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(defaultPools: ["claude": "claude-default"], index: i))))
        XCTAssertEqual(b.model, "opus", "codex has no pool, so its score is never asked for")
    }

    func testTheDefaultPrefersTheProjectsAgentThenCatalogOrder() throws {
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(defaultHarness: "codex")))).model, "gpt-6-sol")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.docs, D.context(defaultHarness: nil)))).harness, "codex")
        let claudeOff = D.context(catalogs: D.catalogsDisabling(["claude"]), defaultHarness: "claude")
        XCTAssertEqual(try XCTUnwrap(block(RouterCore.assign(kind: D.docs, claudeOff))).harness, "codex")
    }

    func testNothingRunnableIsUnroutable() {
        let none = D.context(catalogs: D.catalogsDisabling(["codex", "claude"]))
        XCTAssertEqual(RouterCore.assign(kind: D.docs, none), .unroutable("no enabled agent has a model and a pool"))
    }

    func testKindChainFollowsMergesAndStopsOnACycle() {
        XCTAssertEqual(KindChain.ids(from: "golden-tests", in: D.kinds), ["golden-tests", "snapshot-tests"])
        XCTAssertEqual(KindChain.ids(from: "unknown", in: D.kinds), ["unknown"])
        let loop = [D.kind("a", [:], status: .merged(into: "b")), D.kind("b", [:], status: .merged(into: "a"))]
        XCTAssertEqual(KindChain.ids(from: "a", in: loop), ["a", "b"])
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=RouterTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find type 'RoutingContext' in scope`.

- [ ] **Step 4: Implement `RoutingSeams.swift`**

```swift
import Foundation

// CONTRACT GAP (L3-R deviation 3). L3-0 names pools (`PoolID`) but has no list of them, and the
// router and the compiler's validator both need one: which pools exist, which agent each
// belongs to, and each agent's default. L3-U owns pools; at integration its pool store conforms
// to `PoolDirectory` and replaces `DefaultPoolDirectory`.

public struct PoolSummary: Codable, Hashable, Sendable {
    public var id: PoolID
    public var harness: HarnessID
    public var label: String
    public init(id: PoolID, harness: HarnessID, label: String) { self.id = id; self.harness = harness; self.label = label }
}

public protocol PoolDirectory: Sendable {
    func pools() -> [PoolSummary]
    func defaultPool(for harness: HarnessID) -> PoolID?
}

/// One `<harness>-default` pool per agent — L3-U §2's default pools, which exist before anyone
/// configures capacity. Enough for routing to run end to end before L3-U lands.
public struct DefaultPoolDirectory: PoolDirectory {
    public let harnesses: [HarnessID]
    public init(harnesses: [HarnessID]) { self.harnesses = harnesses }

    public func pools() -> [PoolSummary] {
        harnesses.map { PoolSummary(id: PoolID("\($0.rawValue)-default"), harness: $0, label: "\($0.rawValue) — all accounts") }
    }

    public func defaultPool(for harness: HarnessID) -> PoolID? {
        harnesses.contains(harness) ? PoolID("\(harness.rawValue)-default") : nil
    }
}

/// The index with no data: every task falls through to the default (spec §5 step 4). Stands in
/// for L3-I's index until integration.
public struct NullCapabilityIndex: CapabilityIndex {
    public init() {}
    public func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel] { [] }
    public var snapshotDate: Date? { nil }
}

// CONTRACT GAP (L3-R deviation 4). L3-0's `CapabilityIndex` has no hint call. L3-R draws the
// hint (spec §7); L3-I computes it (its §6) and conforms to `RuleHintSource` at integration.

/// One dismissible line under a confirmed rule. `snapshotDate` is the index snapshot it came
/// from: a dismissal holds until that changes.
public struct RuleHint: Equatable, Sendable {
    public var ruleID: String
    public var text: String
    public var snapshotDate: Date
    public init(ruleID: String, text: String, snapshotDate: Date) {
        self.ruleID = ruleID; self.text = text; self.snapshotDate = snapshotDate
    }
}

public protocol RuleHintSource: Sendable {
    func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint?
}

public struct NoRuleHints: RuleHintSource {
    public init() {}
    public func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? { nil }
}

/// The two lists a project routes by, project first.
public struct RuleLists: Equatable, Sendable {
    public var project: [RoutingRule]
    public var global: [RoutingRule]
    public init(project: [RoutingRule], global: [RoutingRule]) { self.project = project; self.global = global }
}

public protocol RoutingRuleSource: Sendable {
    func rules(project: URL) -> RuleLists
}

/// Rules held in memory, keyed by standardized project path.
public struct StaticRuleSource: RoutingRuleSource {
    public let global: [RoutingRule]
    public let byProject: [String: [RoutingRule]]

    public init(global: [RoutingRule], byProject: [String: [RoutingRule]] = [:]) {
        self.global = global
        self.byProject = Dictionary(byProject.map { (URL(fileURLWithPath: $0.key, isDirectory: true).standardizedFileURL.path, $0.value) },
                                    uniquingKeysWith: { a, _ in a })
    }

    public func rules(project: URL) -> RuleLists {
        RuleLists(project: byProject[project.standardizedFileURL.path] ?? [], global: global)
    }
}

/// The app's source: a snapshot of the global list, and each project's `routing.json` read at
/// routing time, so a rule confirmed in another window applies at the next launch of a task.
public struct ProjectFileRuleSource: RoutingRuleSource {
    public let global: [RoutingRule]
    public let store: ProjectRoutingStore
    public init(global: [RoutingRule], store: ProjectRoutingStore = ProjectRoutingStore()) {
        self.global = global; self.store = store
    }
    public func rules(project: URL) -> RuleLists {
        RuleLists(project: store.load(project: project).rules, global: global)
    }
}
```

- [ ] **Step 5: Implement `Router.swift` (assign)**

```swift
import Foundation

public enum KindChain {
    /// `id`, then every kind it was merged into, in order. Bounded by the registry size and by
    /// repeats, so a hand-edited cycle ends instead of spinning.
    public static func ids(from id: KindID, in kinds: [TaskKind]) -> [KindID] {
        var out = [id]
        var current = id
        for _ in 0..<kinds.count {
            guard let k = kinds.first(where: { $0.id == current }),
                  case .merged(let next) = k.status,
                  !out.contains(next) else { break }
            out.append(next)
            current = next
        }
        return out
    }
}

/// Everything one routing decision reads. A value, so the router is a pure function of it.
public struct RoutingContext: Sendable {
    public var projectRules: [RoutingRule]
    public var globalRules: [RoutingRule]
    public var kinds: [TaskKind]
    public var catalogs: AdapterCatalogs
    public var pools: [PoolSummary]
    public var defaultPools: [HarnessID: PoolID]
    /// The project's default agent (its Projects-pane agent, else the first global agent).
    public var defaultHarness: HarnessID?
    public var index: any CapabilityIndex
    public var confidenceFloor: Double
    public var now: Date

    public init(projectRules: [RoutingRule], globalRules: [RoutingRule], kinds: [TaskKind], catalogs: AdapterCatalogs,
                pools: [PoolSummary], defaultPools: [HarnessID: PoolID], defaultHarness: HarnessID?,
                index: any CapabilityIndex, confidenceFloor: Double = RouterCore.defaultConfidenceFloor, now: Date) {
        self.projectRules = projectRules; self.globalRules = globalRules; self.kinds = kinds; self.catalogs = catalogs
        self.pools = pools; self.defaultPools = defaultPools; self.defaultHarness = defaultHarness
        self.index = index; self.confidenceFloor = confidenceFloor; self.now = now
    }
}

public enum RouteOutcome: Equatable, Sendable {
    case routed(Assignment)
    case unroutable(String)
}

/// The router (spec L3-R §5), as a pure function over a `RoutingContext`.
public enum RouterCore {
    public static let defaultConfidenceFloor = 0.5

    /// 1. Resolve the kind. 2. First confirmed matching rule, project list then global.
    /// 3. Else the index's best candidate at or above the floor. 4. Else the default agent's
    /// default model. 5. The pool is the rule's, else the agent's default.
    ///
    /// The block keeps `kind.id`, not the resolved id: a merge must never require rewriting
    /// tasks, so resolution happens on every read instead.
    public static func assign(kind: TaskKind, _ ctx: RoutingContext) -> RouteOutcome {
        let live = KindResolution.resolve(kind.id, in: ctx.kinds) ?? kind
        let chain = KindChain.ids(from: kind.id, in: ctx.kinds)

        for rule in ctx.projectRules + ctx.globalRules where rule.state == .confirmed {
            guard let compiled = rule.compiled,
                  compiled.match.holds(weights: live.dimensions, chain: chain),
                  let a = usable(compiled.assign, ctx) else { continue }
            let reason = ruleReason(compiled.match, live: live, chain: chain, harness: a.harness)
            return .routed(Assignment(block: ExecutionBlock(
                kind: kind.id, harness: a.harness, model: a.model, knobs: a.knobs, pool: a.pool,
                source: AssignmentSource(by: .rule, ruleId: rule.id, reason: reason, at: ctx.now))))
        }

        let candidates = ctx.catalogs.enabledModels.filter { ctx.defaultPools[$0.harness] != nil }
        if !candidates.isEmpty,
           let best = ctx.index.rank(kind: live, candidates: candidates).first(where: { $0.confidence >= ctx.confidenceFloor }),
           candidates.contains(where: { $0.harness == best.model.harness && $0.model == best.model.model }),
           let pool = ctx.defaultPools[best.model.harness] {
            let reason = "index: \(best.model.harness.rawValue)/\(best.model.model) scores \(RuleText.number(best.score))"
                + " for \(live.id.rawValue) (confidence \(RuleText.number(best.confidence)))"
            return .routed(Assignment(block: ExecutionBlock(
                kind: kind.id, harness: best.model.harness, model: best.model.model, pool: pool,
                source: AssignmentSource(by: .index, reason: reason, at: ctx.now))))
        }

        guard let choice = defaultChoice(ctx) else { return .unroutable("no enabled agent has a model and a pool") }
        return .routed(Assignment(block: ExecutionBlock(
            kind: kind.id, harness: choice.harness, model: choice.model, pool: choice.pool,
            source: AssignmentSource(by: .default,
                                     reason: "default agent \(choice.harness.rawValue): no rule matched and the index had no confident answer",
                                     at: ctx.now))))
    }

    /// The rule's assignment if it can still run: agent enabled, model listed, knobs accepted,
    /// pool present and the agent's. A rule written for a model that has since left the catalog
    /// is skipped — routing to it would hand the swarm a block nothing can launch.
    static func usable(_ a: RuleAssign, _ ctx: RoutingContext) -> RuleAssign? {
        guard ctx.catalogs.byHarness[a.harness]?.enabled == true else { return nil }
        let ref = ModelRef(harness: a.harness, model: a.model, knobs: a.knobs)
        guard ctx.catalogs.contains(ref), ctx.catalogs.knobsValid(ref) else { return nil }
        guard ctx.pools.contains(where: { $0.id == a.pool && $0.harness == a.harness }) else { return nil }
        return a
    }

    static func defaultChoice(_ ctx: RoutingContext) -> (harness: HarnessID, model: String, pool: PoolID)? {
        var order = ctx.catalogs.order
        if let preferred = ctx.defaultHarness { order.insert(preferred, at: 0) }
        for h in order {
            guard let cat = ctx.catalogs.byHarness[h], cat.enabled, let pool = ctx.defaultPools[h],
                  let model = cat.defaultModel ?? cat.models.first?.id,
                  cat.models.contains(where: { $0.id == model }) else { continue }
            return (h, model, pool)
        }
        return nil
    }

    /// The terms that held, with the kind's actual weight — "test-authoring 0.8 → codex".
    static func ruleReason(_ match: RuleMatch, live: TaskKind, chain: [KindID], harness: HarnessID) -> String {
        let held = match.terms.compactMap { term -> String? in
            switch term {
            case .dimension(let d, let atLeast):
                let w = live.dimensions[d] ?? 0
                return w >= atLeast ? "\(d) \(RuleText.number(w))" : nil
            case .kind(let k):
                return chain.contains(k) ? "kind \(k.rawValue)" : nil
            }
        }
        return held.joined(separator: " + ") + " → \(harness.rawValue)"
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=RouterTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 16 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/IntakeKit/FlightControl/RoutingSeams.swift Sources/IntakeKit/FlightControl/Router.swift Tests/FlightDeckTests/FlightControlL3/Routing/RoutingTestData.swift Tests/FlightDeckTests/FlightControlL3/Routing/RouterTests.swift
git commit -m "feat: route a task kind by the first confirmed rule, then the capability index, then the default agent" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Spill, and the contract's `Router` conformer

**Files:**
- Modify: `Sources/IntakeKit/FlightControl/Router.swift` (add `RouterCore.spill`, `RuleRouter`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/SpillTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RuleRouterTests.swift`

**Interfaces:**
- Consumes: Task 4; L3-0 `Router` protocol (`assign(kind:project:catalogs:now:)`, `spill(_:kind:project:exhausted:catalogs:now:)`), `KindRegistry`; fake `FakeKindRegistry`.
- Produces:
  - `RouterCore.spill(_ block: ExecutionBlock, kind: TaskKind, exhausted: Set<PoolID>, _ ctx: RoutingContext) -> Assignment?`
  - `public struct RuleRouter: Router { init(rules:kinds:index:pools:defaultHarness:confidenceFloor:); func context(project:catalogs:now:) -> RoutingContext; func route(kind:project:catalogs:now:) -> RouteOutcome }`

- [ ] **Step 1: Write the failing tests**

`SpillTests.swift`:

```swift
import XCTest
import IntakeKit

/// Spill (spec L3-R §5) re-routes ONE spawn around exhausted pools. The rule's own fallback pool
/// goes first, a pinned block waits, and the result always says it was a spill.
final class SpillTests: XCTestCase {
    private typealias D = RoutingTestData

    private func r3Block(pool: PoolID = "codex-subs", pinned: Bool = false) -> ExecutionBlock {
        ExecutionBlock(kind: "snapshot-tests", harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"], pool: pool,
                       source: AssignmentSource(by: .rule, ruleId: "r3", reason: "test-authoring 0.8 → codex", at: D.at),
                       pinned: pinned)
    }

    func testTheRulesFallbackPoolIsTriedFirst() throws {
        let rule = D.r3(fallbackPool: "claude-subs")
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context(global: [rule])))
        XCTAssertEqual(s.block.pool, "claude-subs"); XCTAssertEqual(s.block.harness, "claude")
        XCTAssertEqual(s.block.model, "opus", "another agent's pool runs that agent's default model")
        XCTAssertEqual(s.block.knobs, [:])
        XCTAssertEqual(s.block.source, AssignmentSource(by: .spill, ruleId: "r3", reason: "codex-subs exhausted → claude-subs/opus", at: D.at))
    }

    func testAFallbackPoolOfTheSameAgentKeepsTheRulesModelAndKnobs() throws {
        let rule = D.r3(fallbackPool: "codex-default")
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context(global: [rule])))
        XCTAssertEqual(s.block.pool, "codex-default"); XCTAssertEqual(s.block.model, "gpt-6-sol")
        XCTAssertEqual(s.block.knobs, ["effort": "high"])
    }

    func testWithoutAFallbackPoolTheRulesRunAgainWithoutTheExhaustedPool() throws {
        let r4 = D.rule("r4", .any([.dimension("test-authoring", atLeast: 0.5)]), "claude", "opus", pool: "claude-default")
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context(global: [D.r3(), r4])))
        XCTAssertEqual(s.block.source, AssignmentSource(by: .spill, ruleId: "r4", reason: "codex-subs exhausted → claude-default/opus", at: D.at))
    }

    func testWhenNoRuleFitsTheDefaultTakesIt() throws {
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context(global: [D.r3()])))
        XCTAssertEqual(s.block.pool, "claude-default"); XCTAssertEqual(s.block.source.by, .spill); XCTAssertNil(s.block.source.ruleId)
    }

    func testAnExhaustedFallbackPoolIsPassedOver() throws {
        let rule = D.r3(fallbackPool: "claude-subs")
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs", "claude-subs"],
                                               D.context(global: [rule])))
        XCTAssertEqual(s.block.pool, "claude-default")
    }

    func testAPinnedBlockNeverSpills() {
        XCTAssertNil(RouterCore.spill(r3Block(pinned: true), kind: D.snapshot, exhausted: ["codex-subs"],
                                      D.context(global: [D.r3(fallbackPool: "claude-subs")])))
    }

    func testNothingLeftIsNil() {
        let all: Set<PoolID> = ["codex-default", "codex-subs", "claude-default", "claude-subs"]
        XCTAssertNil(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: all, D.context(global: [D.r3()])))
    }

    func testSpillKeepsTheTasksKind() throws {
        let s = try XCTUnwrap(RouterCore.spill(r3Block(), kind: D.snapshot, exhausted: ["codex-subs"], D.context()))
        XCTAssertEqual(s.block.kind, "snapshot-tests")
    }
}
```

`RuleRouterTests.swift`:

```swift
import XCTest
import IntakeKit

/// `RuleRouter` is what L3-S calls through the contract's `Router`. These tests drive it only
/// through that protocol and L3-0's fakes, the way the other branches will.
final class RuleRouterTests: XCTestCase {
    private typealias D = RoutingTestData
    private let project = URL(fileURLWithPath: "/w/project", isDirectory: true)

    private func router(global: [RoutingRule] = [], projectRules: [RoutingRule] = []) -> RuleRouter {
        let kinds = FakeKindRegistry()
        kinds.byProject[project] = D.kinds
        return RuleRouter(rules: StaticRuleSource(global: global, byProject: ["/w/project": projectRules]), kinds: kinds,
                          index: NullCapabilityIndex(), pools: DefaultPoolDirectory(harnesses: ["codex", "claude"]),
                          defaultHarness: { _ in "claude" })
    }

    func testAssignRoutesThroughTheContractProtocol() {
        let r: any Router = router(global: [D.r3(pool: "codex-default")])
        let a = r.assign(kind: D.snapshot, project: project, catalogs: D.catalogs, now: D.at)
        XCTAssertEqual(a.block.source.ruleId, "r3"); XCTAssertEqual(a.block.pool, "codex-default")
    }

    func testProjectRulesComeFromTheSourceForThatProject() {
        let p1 = D.rule("p1", .any([.dimension("test-authoring", atLeast: 0.5)]), "claude", "opus", pool: "claude-default")
        let a = router(global: [D.r3(pool: "codex-default")], projectRules: [p1])
            .assign(kind: D.snapshot, project: project, catalogs: D.catalogs, now: D.at)
        XCTAssertEqual(a.block.source.ruleId, "p1")
    }

    func testMergedKindsResolveThroughTheRegistry() {
        let k1 = D.rule("k1", .any([.kind("snapshot-tests")]), "codex", "gpt-6-sol", pool: "codex-default")
        let a = router(global: [k1]).assign(kind: D.golden, project: project, catalogs: D.catalogs, now: D.at)
        XCTAssertEqual(a.block.source.ruleId, "k1")
    }

    func testAnUnroutableTaskGetsABlockTheCodecRefuses() throws {
        let a = router().assign(kind: D.docs, project: project, catalogs: D.catalogsDisabling(["codex", "claude"]), now: D.at)
        XCTAssertEqual(a.block.model, "")
        XCTAssertEqual(a.block.source.reason, "unroutable: no enabled agent has a model and a pool")
        let json = try ExecutionBlockCodec.encode(a.block, into: nil)
        XCTAssertEqual(ExecutionBlockCodec.decode(agentContext: json), .failure(.invalidField("harness", "empty")))
    }

    func testSpillGoesThroughTheProtocolAndRefusesPinned() {
        let r: any Router = router(global: [D.r3(pool: "codex-default", fallbackPool: "claude-default")])
        let b = ExecutionBlock(kind: "snapshot-tests", harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"],
                               pool: "codex-default", source: AssignmentSource(by: .rule, ruleId: "r3", reason: "r", at: D.at))
        XCTAssertEqual(r.spill(b, kind: D.snapshot, project: project, exhausted: ["codex-default"], catalogs: D.catalogs, now: D.at)?.block.pool,
                       "claude-default")
        var pinned = b
        pinned.pinned = true
        XCTAssertNil(r.spill(pinned, kind: D.snapshot, project: project, exhausted: ["codex-default"], catalogs: D.catalogs, now: D.at))
    }

    func testDefaultPoolDirectoryNamesOnePoolPerAgent() {
        let d = DefaultPoolDirectory(harnesses: ["codex", "claude"])
        XCTAssertEqual(d.pools().map(\.id), ["codex-default", "claude-default"])
        XCTAssertEqual(d.defaultPool(for: "claude"), "claude-default")
        XCTAssertNil(d.defaultPool(for: "fake"))
    }

    func testTheFileRuleSourceReadsTheProjectFileAtRoutingTime() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RuleRouterTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = ProjectFileRuleSource(global: [])
        XCTAssertEqual(source.rules(project: dir).project, [])
        try ProjectRoutingStore().save([D.r3()], project: dir)
        XCTAssertEqual(source.rules(project: dir).project.map(\.id), ["r3"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=SpillTests,RuleRouterTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build errors `type 'RouterCore' has no member 'spill'` and `cannot find 'RuleRouter' in scope`.

- [ ] **Step 3: Add `spill` to `RouterCore`**

Inside `public enum RouterCore`, after `assign`:

```swift
    /// Re-routes ONE spawn with `exhausted` pools removed (spec §5). Called by L3-S at spawn,
    /// never by encode, and the caller never writes the result back to the task: a spill is a
    /// detour for this spawn, not a new decision about the task.
    ///
    /// The rule's `fallbackPool` goes first — it is the spill target the sentence named. A
    /// pinned block never spills: a manual choice waits for its pool rather than being undone.
    public static func spill(_ block: ExecutionBlock, kind: TaskKind, exhausted: Set<PoolID>,
                             _ ctx: RoutingContext) -> Assignment? {
        guard !block.pinned else { return nil }
        var open = ctx
        open.pools = ctx.pools.filter { !exhausted.contains($0.id) }
        open.defaultPools = ctx.defaultPools.filter { !exhausted.contains($0.value) }

        func spilled(_ b: ExecutionBlock, ruleId: String?) -> Assignment {
            var out = b
            out.kind = block.kind
            out.source = AssignmentSource(by: .spill, ruleId: ruleId,
                                          reason: "\(block.pool.rawValue) exhausted → \(b.pool.rawValue)/\(b.model)", at: ctx.now)
            return Assignment(block: out)
        }

        if let ruleId = block.source.ruleId,
           let rule = (ctx.projectRules + ctx.globalRules).first(where: { $0.id == ruleId }),
           let compiled = rule.compiled, let fallback = compiled.assign.fallbackPool,
           let pool = open.pools.first(where: { $0.id == fallback }),
           let cat = open.catalogs.byHarness[pool.harness], cat.enabled {
            let sameAgent = pool.harness == compiled.assign.harness
            let model = sameAgent ? compiled.assign.model : (cat.defaultModel ?? cat.models.first?.id)
            let knobs = sameAgent ? compiled.assign.knobs : [:]
            if let model, open.catalogs.contains(ModelRef(harness: pool.harness, model: model)) {
                let b = ExecutionBlock(kind: block.kind, harness: pool.harness, model: model, knobs: knobs,
                                       pool: pool.id, source: block.source)
                return spilled(b, ruleId: ruleId)
            }
        }

        guard case .routed(let a) = assign(kind: kind, open) else { return nil }
        return spilled(a.block, ruleId: a.block.source.ruleId)
    }
```

- [ ] **Step 4: Add `RuleRouter` at the end of `Router.swift`**

```swift
/// The contract's `Router` (L3-0 §7): reads its context from injected sources, then defers to
/// `RouterCore`. L3-S calls `assign` at launch and `spill` at spawn through the protocol.
public struct RuleRouter: Router {
    public let rules: any RoutingRuleSource
    public let kinds: any KindRegistry
    public let index: any CapabilityIndex
    public let pools: any PoolDirectory
    public let defaultHarness: @Sendable (URL) -> HarnessID?
    public let confidenceFloor: Double

    public init(rules: any RoutingRuleSource, kinds: any KindRegistry, index: any CapabilityIndex,
                pools: any PoolDirectory, defaultHarness: @escaping @Sendable (URL) -> HarnessID?,
                confidenceFloor: Double = RouterCore.defaultConfidenceFloor) {
        self.rules = rules; self.kinds = kinds; self.index = index; self.pools = pools
        self.defaultHarness = defaultHarness; self.confidenceFloor = confidenceFloor
    }

    /// An unreadable registry routes with no kinds: the task's own weights still decide, and
    /// a broken `kinds.json` must not stop the swarm.
    public func context(project: URL, catalogs: AdapterCatalogs, now: Date) -> RoutingContext {
        let lists = rules.rules(project: project)
        var defaults: [HarnessID: PoolID] = [:]
        for h in catalogs.order { if let p = pools.defaultPool(for: h) { defaults[h] = p } }
        return RoutingContext(projectRules: lists.project, globalRules: lists.global,
                              kinds: (try? kinds.kinds(project: project)) ?? [],
                              catalogs: catalogs, pools: pools.pools(), defaultPools: defaults,
                              defaultHarness: defaultHarness(project), index: index,
                              confidenceFloor: confidenceFloor, now: now)
    }

    public func route(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> RouteOutcome {
        RouterCore.assign(kind: kind, context(project: project, catalogs: catalogs, now: now))
    }

    /// The contract's `assign` cannot fail (deviation 5), so an unroutable task gets a block with
    /// empty harness, model and pool. `ExecutionBlockCodec` refuses to decode an empty field, so
    /// nothing downstream can launch it; callers that can fail use `route` instead.
    public func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment {
        switch route(kind: kind, project: project, catalogs: catalogs, now: now) {
        case .routed(let a):
            return a
        case .unroutable(let why):
            return Assignment(block: ExecutionBlock(kind: kind.id, harness: "", model: "", pool: "",
                                                    source: AssignmentSource(by: .default, reason: "unroutable: \(why)", at: now)))
        }
    }

    public func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>,
                      catalogs: AdapterCatalogs, now: Date) -> Assignment? {
        RouterCore.spill(block, kind: kind, exhausted: exhausted, context(project: project, catalogs: catalogs, now: now))
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=SpillTests,RuleRouterTests,RouterTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 31 tests, with 0 failures` (8 + 7 + 16).

- [ ] **Step 6: Commit**

```bash
git add Sources/IntakeKit/FlightControl/Router.swift Tests/FlightDeckTests/FlightControlL3/Routing/SpillTests.swift Tests/FlightDeckTests/FlightControlL3/Routing/RuleRouterTests.swift
git commit -m "feat: spill a spawn around exhausted pools, rule fallback first, and route through the contract" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The rule validator

**Files:**
- Create: `Sources/IntakeKit/FlightControl/RuleValidator.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Routing/RuleWireTestData.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RuleValidatorTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 4 (`PoolSummary`); L3-0 `Dimensions`, `AdapterCatalogs.knobsValid`, `TaskKind`.
- Produces:
  - `public struct RuleCompilerWire: Codable, Equatable, Sendable { struct Term { dimension: String?; atLeast: Double?; kind: String? }; struct Knob { name; value }; ok; reason; mode; terms; harness; model; modelDefaulted; knobs; pool; fallbackPool }`
  - `public struct RuleCompilerInput: Equatable, Sendable { sentence; kinds; catalogs; pools: [PoolSummary]; defaultPools: [HarnessID: PoolID] }`
  - `public enum RuleValidationError: Error, Equatable, Sendable { … ; var message: String }`
  - `public enum RuleValidator { static func validate(_ w: RuleCompilerWire, input: RuleCompilerInput) -> Result<CompiledRule, RuleValidationError> }`
  - Test support: `RoutingTestData.specSentence`, `.specWire`, `.input(_:catalogs:)`.

- [ ] **Step 1: Write the test data and the failing tests**

`RuleWireTestData.swift`:

```swift
import Foundation
import IntakeKit

extension RoutingTestData {
    static let specSentence = "Use Codex for unit and integration tests, and for complex algorithms"

    /// What a compiler should answer for `specSentence`: spec L3-R §2's compiled form.
    static let specWire = RuleCompilerWire(
        ok: true, reason: nil, mode: "any",
        terms: [.init(dimension: "test-authoring", atLeast: 0.5, kind: nil),
                .init(dimension: "algorithmic-reasoning", atLeast: 0.6, kind: nil),
                .init(dimension: nil, atLeast: nil, kind: "tests")],
        harness: "codex", model: "gpt-6-sol", modelDefaulted: false,
        knobs: [.init(name: "effort", value: "high")], pool: "codex-subs", fallbackPool: nil)

    static func input(_ sentence: String = RoutingTestData.specSentence,
                      catalogs: AdapterCatalogs = RoutingTestData.catalogs) -> RuleCompilerInput {
        RuleCompilerInput(sentence: sentence, kinds: kinds, catalogs: catalogs, pools: pools, defaultPools: defaultPools)
    }
}
```

`RuleValidatorTests.swift`:

```swift
import XCTest
import IntakeKit

/// The validator is the only thing standing between a model's answer and a confirmable rule
/// (spec L3-R §3). Every check is named, and only the first failure is reported.
final class RuleValidatorTests: XCTestCase {
    private typealias D = RoutingTestData

    private func validate(_ input: RuleCompilerInput = RoutingTestData.input(),
                          _ change: (inout RuleCompilerWire) -> Void) -> Result<CompiledRule, RuleValidationError> {
        var w = D.specWire
        change(&w)
        return RuleValidator.validate(w, input: input)
    }

    func testTheSpecRuleValidates() {
        XCTAssertEqual(validate { _ in }, .success(D.r3().compiled!))
    }

    func testANamelessModelTakesTheAgentsDefaultAndSaysSo() throws {
        let c = try validate { $0.model = nil }.get()
        XCTAssertEqual(c.assign.model, "gpt-6-sol")
        XCTAssertTrue(c.assign.modelDefaulted)
    }

    func testANamelessPoolTakesTheAgentsDefaultPool() throws {
        XCTAssertEqual(try validate { $0.pool = nil }.get().assign.pool, "codex-default")
    }

    func testAllModeCompilesToAll() throws {
        let compiled = try validate { $0.mode = "all" }.get()
        guard case .all(let terms) = compiled.match else { return XCTFail("\(compiled.match)") }
        XCTAssertEqual(terms.count, 3)
    }

    func testEveryInvalidInputIsNamed() {
        let cases: [(String, (inout RuleCompilerWire) -> Void, RuleValidationError)] = [
            ("dimension", { $0.terms[0].dimension = "teleportation" }, .unknownDimension("teleportation")),
            ("threshold", { $0.terms[0].atLeast = 1.5 }, .thresholdOutOfRange("test-authoring")),
            ("no threshold", { $0.terms[0].atLeast = nil }, .thresholdOutOfRange("test-authoring")),
            ("kind", { $0.terms[2].kind = "astrology" }, .unknownKind("astrology")),
            ("both in one term", { $0.terms[2].dimension = "debugging" }, .malformedTerm),
            ("no terms", { $0.terms = [] }, .emptyMatch),
            ("mode", { $0.mode = "some" }, .unknownMode("some")),
            ("no agent", { $0.harness = nil }, .missingHarness),
            ("agent", { $0.harness = "gemini" }, .unknownHarness("gemini")),
            ("model", { $0.model = "gpt-9" }, .unknownModel("codex", "gpt-9")),
            ("knob value", { $0.knobs = [.init(name: "effort", value: "max")] }, .knobRejected("codex", "gpt-6-sol", "effort", "max")),
            ("knob name", { $0.knobs = [.init(name: "agent", value: "build")] }, .knobRejected("codex", "gpt-6-sol", "agent", "build")),
            ("pool", { $0.pool = "nowhere" }, .unknownPool("nowhere")),
            ("pool owner", { $0.pool = "claude-subs" }, .poolBelongsElsewhere("claude-subs", owner: "claude", harness: "codex")),
            ("fallback pool", { $0.fallbackPool = "nowhere" }, .unknownPool("nowhere")),
            ("fallback is the pool", { $0.fallbackPool = "codex-subs" }, .fallbackIsPrimary("codex-subs")),
            ("declined", { $0.ok = false; $0.reason = "that is not a routing rule" }, .declined("that is not a routing rule")),
        ]
        for (name, change, expected) in cases {
            XCTAssertEqual(validate(D.input(), change), .failure(expected), name)
        }
    }

    func testADisabledAgentIsNamed() {
        let input = D.input(catalogs: D.catalogsDisabling(["codex"]))
        XCTAssertEqual(validate(input) { _ in }, .failure(.harnessDisabled("codex")))
    }

    func testTheFirstErrorWins() {
        XCTAssertEqual(validate { $0.terms[0].dimension = "teleportation"; $0.harness = "gemini" },
                       .failure(.unknownDimension("teleportation")))
    }

    func testADeclinedSentenceWithoutAReasonGetsOne() {
        XCTAssertEqual(validate { $0.ok = false; $0.reason = nil },
                       .failure(.declined("the compiler could not read this sentence as a rule")))
    }

    func testMessagesReadAsSentences() {
        XCTAssertEqual(RuleValidationError.unknownDimension("teleportation").message, "unknown dimension teleportation")
        XCTAssertEqual(RuleValidationError.poolBelongsElsewhere("claude-subs", owner: "claude", harness: "codex").message,
                       "pool claude-subs belongs to claude, not codex")
        XCTAssertEqual(RuleValidationError.unknownModel("codex", "gpt-9").message, "gpt-9 is not in codex's model list")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=RuleValidatorTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find type 'RuleCompilerWire' in scope`.

- [ ] **Step 3: Implement `RuleValidator.swift`**

```swift
import Foundation

/// The compiler's raw answer, in the strict shape `RuleCompilerPrompt.schemaJSON` forces. Flat
/// and nullable because strict-mode schemas cannot express "one of two term shapes" or an
/// open-keyed knob object; `RuleValidator` turns it into a `CompiledRule`.
public struct RuleCompilerWire: Codable, Equatable, Sendable {
    public struct Term: Codable, Equatable, Sendable {
        public var dimension: String?
        public var atLeast: Double?
        public var kind: String?
        public init(dimension: String?, atLeast: Double?, kind: String?) {
            self.dimension = dimension; self.atLeast = atLeast; self.kind = kind
        }
    }
    public struct Knob: Codable, Equatable, Sendable {
        public var name: String
        public var value: String
        public init(name: String, value: String) { self.name = name; self.value = value }
    }

    public var ok: Bool
    public var reason: String?
    public var mode: String
    public var terms: [Term]
    public var harness: String?
    public var model: String?
    public var modelDefaulted: Bool
    public var knobs: [Knob]
    public var pool: String?
    public var fallbackPool: String?

    public init(ok: Bool, reason: String?, mode: String, terms: [Term], harness: String?, model: String?,
                modelDefaulted: Bool, knobs: [Knob], pool: String?, fallbackPool: String?) {
        self.ok = ok; self.reason = reason; self.mode = mode; self.terms = terms; self.harness = harness
        self.model = model; self.modelDefaulted = modelDefaulted; self.knobs = knobs; self.pool = pool
        self.fallbackPool = fallbackPool
    }
}

/// Everything the compiler is told and the validator checks against (spec §3).
public struct RuleCompilerInput: Equatable, Sendable {
    public var sentence: String
    public var kinds: [TaskKind]
    public var catalogs: AdapterCatalogs
    public var pools: [PoolSummary]
    public var defaultPools: [HarnessID: PoolID]
    public init(sentence: String, kinds: [TaskKind], catalogs: AdapterCatalogs, pools: [PoolSummary],
                defaultPools: [HarnessID: PoolID]) {
        self.sentence = sentence; self.kinds = kinds; self.catalogs = catalogs; self.pools = pools
        self.defaultPools = defaultPools
    }
}

public enum RuleValidationError: Error, Equatable, Sendable {
    case declined(String)
    case malformedTerm
    case unknownDimension(String)
    case thresholdOutOfRange(String)
    case unknownKind(String)
    case emptyMatch
    case unknownMode(String)
    case missingHarness
    case unknownHarness(String)
    case harnessDisabled(String)
    case noDefaultModel(String)
    case unknownModel(String, String)
    case knobRejected(String, String, String, String)
    case noPool(String)
    case unknownPool(String)
    case poolBelongsElsewhere(String, owner: String, harness: String)
    case fallbackIsPrimary(String)

    /// Shown inline under a failed rule (spec §2: "failed (shown inline with the reason)").
    public var message: String {
        switch self {
        case .declined(let why): return why
        case .malformedTerm: return "a condition names neither one dimension nor one kind"
        case .unknownDimension(let d): return "unknown dimension \(d)"
        case .thresholdOutOfRange(let d): return "\(d) needs a threshold between 0 and 1"
        case .unknownKind(let k): return "unknown task kind \(k)"
        case .emptyMatch: return "the rule has no conditions"
        case .unknownMode(let m): return "unknown match mode \(m)"
        case .missingHarness: return "the rule names no agent"
        case .unknownHarness(let h): return "\(h) is not a registered agent"
        case .harnessDisabled(let h): return "\(h) is not enabled"
        case .noDefaultModel(let h): return "\(h) has no default model to fall back to"
        case .unknownModel(let h, let m): return "\(m) is not in \(h)'s model list"
        case .knobRejected(let h, let m, let k, let v): return "\(h) · \(m) does not accept \(k) \(v)"
        case .noPool(let h): return "\(h) has no pool"
        case .unknownPool(let p): return "unknown pool \(p)"
        case .poolBelongsElsewhere(let p, let owner, let h): return "pool \(p) belongs to \(owner), not \(h)"
        case .fallbackIsPrimary(let p): return "the fallback pool \(p) is the rule's own pool"
        }
    }
}

/// Checks a compiler answer against the dimensions, the project's kinds, the registered
/// adapters' catalogs and knob schemas, and the pools (spec §3). The first error wins: the rule
/// shows one reason, and fixing it and recompiling is the loop, not a wall of errors.
public enum RuleValidator {
    public static func validate(_ w: RuleCompilerWire, input: RuleCompilerInput) -> Result<CompiledRule, RuleValidationError> {
        guard w.ok else { return .failure(.declined(w.reason ?? "the compiler could not read this sentence as a rule")) }

        var terms: [MatchTerm] = []
        for t in w.terms {
            switch (t.dimension, t.kind) {
            case (let d?, nil):
                guard Dimensions.isKnown(d) else { return .failure(.unknownDimension(d)) }
                guard let atLeast = t.atLeast, (0...1).contains(atLeast) else { return .failure(.thresholdOutOfRange(d)) }
                terms.append(.dimension(d, atLeast: atLeast))
            case (nil, let k?):
                guard input.kinds.contains(where: { $0.id.rawValue == k }) else { return .failure(.unknownKind(k)) }
                terms.append(.kind(KindID(k)))
            default:
                return .failure(.malformedTerm)
            }
        }
        guard !terms.isEmpty else { return .failure(.emptyMatch) }
        let match: RuleMatch
        switch w.mode {
        case "any": match = .any(terms)
        case "all": match = .all(terms)
        default: return .failure(.unknownMode(w.mode))
        }

        guard let harnessName = w.harness, !harnessName.isEmpty else { return .failure(.missingHarness) }
        let harness = HarnessID(harnessName)
        guard let catalog = input.catalogs.byHarness[harness] else { return .failure(.unknownHarness(harnessName)) }
        guard catalog.enabled else { return .failure(.harnessDisabled(harnessName)) }

        var defaulted = w.modelDefaulted
        var modelName = w.model
        if modelName?.isEmpty ?? true {
            modelName = catalog.defaultModel
            defaulted = true
        }
        guard let model = modelName else { return .failure(.noDefaultModel(harnessName)) }
        guard catalog.models.contains(where: { $0.id == model }) else { return .failure(.unknownModel(harnessName, model)) }

        var knobs: [String: String] = [:]
        for k in w.knobs { knobs[k.name] = k.value }
        for (k, v) in knobs.sorted(by: { $0.key < $1.key })
        where !input.catalogs.knobsValid(ModelRef(harness: harness, model: model, knobs: [k: v])) {
            return .failure(.knobRejected(harnessName, model, k, v))
        }

        let pool: PoolID
        if let p = w.pool, !p.isEmpty {
            guard let summary = input.pools.first(where: { $0.id.rawValue == p }) else { return .failure(.unknownPool(p)) }
            guard summary.harness == harness else {
                return .failure(.poolBelongsElsewhere(p, owner: summary.harness.rawValue, harness: harnessName))
            }
            pool = summary.id
        } else {
            guard let d = input.defaultPools[harness] else { return .failure(.noPool(harnessName)) }
            pool = d
        }

        var fallback: PoolID?
        if let f = w.fallbackPool, !f.isEmpty {
            guard input.pools.contains(where: { $0.id.rawValue == f }) else { return .failure(.unknownPool(f)) }
            guard f != pool.rawValue else { return .failure(.fallbackIsPrimary(f)) }
            fallback = PoolID(f)
        }

        return .success(CompiledRule(match: match, assign: RuleAssign(harness: harness, model: model, knobs: knobs, pool: pool,
                                                                      fallbackPool: fallback, modelDefaulted: defaulted)))
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=RuleValidatorTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/RuleValidator.swift Tests/FlightDeckTests/FlightControlL3/Routing/RuleWireTestData.swift Tests/FlightDeckTests/FlightControlL3/Routing/RuleValidatorTests.swift
git commit -m "feat: validate a compiled routing rule against dimensions, kinds, catalogs, knobs and pools" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The rule compiler

**Files:**
- Create: `Sources/IntakeKit/FlightControl/RuleCompilerPrompt.swift`
- Create: `Sources/IntakeKit/FlightControl/RuleCompiler.swift`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/compiler-valid.claude.jsonl`
- Create: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingFixtures.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RuleCompilerTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 6; IntakeKit `CommandRunner`, `CommandResult`, `HarnessRequest`, `HarnessCommand.build(_:home:)`, `HarnessCommand.environment(for:base:home:)`, `HarnessOutput.parse(_:stdout:)`.
- Produces:
  - `public enum RuleProposal: Equatable, Sendable { wire(RuleCompilerWire), unavailable(String), malformed(String) }`
  - `public enum RuleCompileOutcome: Equatable, Sendable { compiled(CompiledRule), failed(String), unavailable(String) }`
  - `public protocol RuleCompiling: Sendable { var ref: CompilerRef { get }; func propose(_ input: RuleCompilerInput) async -> RuleProposal }`
  - `public enum RuleCompilation { static func finish(_ proposal: RuleProposal, input: RuleCompilerInput) -> RuleCompileOutcome }`
  - `extension RoutingRule { mutating func record(_ outcome: RuleCompileOutcome, by: CompilerRef, at: Date) }`
  - `public struct RuleCompiler: RuleCompiling { init(runner:settings:workDirectory:home:baseEnvironment:) }`
  - `public enum RuleCompilerPrompt { static let schemaJSON: String; static func text(_ input: RuleCompilerInput) -> String }`
  - Test support: `enum RoutingFixtures { static func data(_ name: String) throws -> Data }`

- [ ] **Step 1: Write the fixture and the loader**

`Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/compiler-valid.claude.jsonl` (two lines,
the `claude -p --output-format stream-json` shape `HarnessOutput.parse` already reads; the
`structured_output` is what `--json-schema` returns):

```
{"type":"system","subtype":"init","session_id":"rc-fixture-1","model":"claude-haiku"}
{"type":"result","subtype":"success","is_error":false,"session_id":"rc-fixture-1","result":"","structured_output":{"ok":true,"reason":null,"mode":"any","terms":[{"dimension":"test-authoring","atLeast":0.5,"kind":null},{"dimension":"algorithmic-reasoning","atLeast":0.6,"kind":null},{"dimension":null,"atLeast":null,"kind":"tests"}],"harness":"codex","model":"gpt-6-sol","modelDefaulted":false,"knobs":[{"name":"effort","value":"high"}],"pool":"codex-subs","fallbackPool":null}}
```

`RoutingFixtures.swift`:

```swift
import Foundation
import XCTest

/// Loads L3-R's fixtures from the test bundle's `Fixtures/FlightControlL3/Routing` folder.
enum RoutingFixtures {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Token.self).url(forResource: name, withExtension: nil,
                                                             subdirectory: "Fixtures/FlightControlL3/Routing"),
                                "missing fixture \(name)")
        return try Data(contentsOf: url)
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit

private final class CannedRunner: CommandRunner, @unchecked Sendable {
    struct Call { let executable: String; let arguments: [String]; let cwd: URL; let environment: [String: String] }
    var result: Result<CommandResult, Error>
    private(set) var calls: [Call] = []
    init(_ result: Result<CommandResult, Error>) { self.result = result }
    func run(executable: String, arguments: [String], cwd: URL, environment: [String: String],
             processGroup: Bool, onSpawn: (@Sendable (Int32) -> Void)?) async throws -> CommandResult {
        calls.append(Call(executable: executable, arguments: arguments, cwd: cwd, environment: environment))
        return try result.get()
    }
}

/// One cheap headless call per sentence, constrained by a schema, then validated (spec L3-R §3).
/// The model output is a fixture; each validation failure is that fixture with one field swapped.
final class RuleCompilerTests: XCTestCase {
    private typealias D = RoutingTestData
    private var work: URL!

    override func setUp() {
        super.setUp()
        work = FileManager.default.temporaryDirectory.appendingPathComponent("RuleCompilerTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: work); super.tearDown() }

    private func compiler(_ runner: CannedRunner, settings: RuleCompilerSettings = .default) -> RuleCompiler {
        // `home: work` so `HarnessCommand` never reads the operator's own codex/claude settings.
        RuleCompiler(runner: runner, settings: settings, workDirectory: work, home: work,
                     baseEnvironment: { ["PATH": "/usr/bin", "CLAUDECODE": "1"] })
    }

    private func ok(_ stdout: Data) -> CannedRunner { CannedRunner(.success(CommandResult(stdout: stdout, stderr: "", exitCode: 0))) }

    private func stream(_ wire: RuleCompilerWire) throws -> Data {
        let structured = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire))
        let result: [String: Any] = ["type": "result", "subtype": "success", "is_error": false,
                                     "session_id": "rc-fixture-1", "result": "", "structured_output": structured]
        let initLine = #"{"type":"system","subtype":"init","session_id":"rc-fixture-1"}"#
        let resultLine = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        return Data((initLine + "\n" + resultLine + "\n").utf8)
    }

    private func recordedWire() throws -> RuleCompilerWire {
        let parsed = try HarnessOutput.parse(.claude, stdout: RoutingFixtures.data("compiler-valid.claude.jsonl"))
        return try JSONDecoder().decode(RuleCompilerWire.self, from: parsed.structured)
    }

    private func outcome(_ runner: CannedRunner, settings: RuleCompilerSettings = .default) async -> RuleCompileOutcome {
        let input = D.input()
        let proposal = await compiler(runner, settings: settings).propose(input)
        return RuleCompilation.finish(proposal, input: input)
    }

    func testTheRecordedOutputCompilesToTheSpecRule() async throws {
        let result = await outcome(ok(try RoutingFixtures.data("compiler-valid.claude.jsonl")))
        XCTAssertEqual(result, .compiled(D.r3().compiled!))
    }

    func testItRunsHeadlessClaudeHaikuWithTheStrictSchema() async throws {
        let runner = ok(try RoutingFixtures.data("compiler-valid.claude.jsonl"))
        _ = await compiler(runner).propose(D.input())
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, "claude")
        XCTAssertEqual(call.arguments.first, "-p")
        XCTAssertEqual(call.arguments[try XCTUnwrap(call.arguments.firstIndex(of: "--model")) + 1], "haiku")
        XCTAssertEqual(call.arguments[try XCTUnwrap(call.arguments.firstIndex(of: "--json-schema")) + 1], RuleCompilerPrompt.schemaJSON)
        XCTAssertEqual(call.cwd, work)
        XCTAssertNil(call.environment["CLAUDECODE"], "a claude spawned from inside Claude Code must not inherit the child marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.appendingPathComponent("rule-schema.json").path))
    }

    func testCodexCanBeTheCompiler() async throws {
        let text = String(decoding: try JSONEncoder().encode(D.specWire), as: UTF8.self)
        let msg = try JSONSerialization.data(withJSONObject: ["type": "item.completed", "item": ["type": "agent_message", "text": text]])
        let stdout = Data((#"{"type":"thread.started","thread_id":"T1"}"# + "\n" + String(decoding: msg, as: UTF8.self) + "\n").utf8)
        let runner = ok(stdout)
        let result = await outcome(runner, settings: RuleCompilerSettings(harness: .codex, model: "gpt-6-luna", effort: "low"))
        XCTAssertEqual(result, .compiled(D.r3().compiled!))
        XCTAssertEqual(runner.calls.first?.executable, "codex")
        XCTAssertTrue(runner.calls.first?.arguments.contains("--output-schema") == true)
    }

    func testEveryValidationFailureFailsWithItsMessage() async throws {
        let base = try recordedWire()
        let cases: [(String, (inout RuleCompilerWire) -> Void, RuleValidationError)] = [
            ("dimension", { $0.terms[0].dimension = "teleportation" }, .unknownDimension("teleportation")),
            ("kind", { $0.terms[2].kind = "astrology" }, .unknownKind("astrology")),
            ("agent", { $0.harness = "gemini" }, .unknownHarness("gemini")),
            ("model", { $0.model = "gpt-9" }, .unknownModel("codex", "gpt-9")),
            ("knob", { $0.knobs = [.init(name: "effort", value: "max")] }, .knobRejected("codex", "gpt-6-sol", "effort", "max")),
            ("pool", { $0.pool = "nowhere" }, .unknownPool("nowhere")),
            ("pool owner", { $0.pool = "claude-subs" }, .poolBelongsElsewhere("claude-subs", owner: "claude", harness: "codex")),
            ("declined", { $0.ok = false; $0.reason = "that is not a routing rule" }, .declined("that is not a routing rule")),
        ]
        for (name, change, expected) in cases {
            var w = base
            change(&w)
            let result = await outcome(ok(try stream(w)))
            XCTAssertEqual(result, .failed(expected.message), name)
        }
    }

    func testANonZeroExitIsUnavailable() async {
        let runner = CannedRunner(.success(CommandResult(stdout: Data(), stderr: "Not logged in\nmore", exitCode: 1)))
        let result = await outcome(runner)
        XCTAssertEqual(result, .unavailable("claude exited 1: Not logged in"))
    }

    func testAProcessThatCannotStartIsUnavailable() async {
        struct NoSpawn: Error {}
        let result = await outcome(CannedRunner(.failure(NoSpawn())))
        guard case .unavailable(let why) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(why.hasPrefix("could not start claude"), why)
    }

    func testProseInsteadOfJSONFails() async {
        let prose = Data((#"{"type":"system","subtype":"init","session_id":"s"}"# + "\n"
            + #"{"type":"result","subtype":"success","is_error":false,"session_id":"s","result":"Sure! Here is your rule."}"# + "\n").utf8)
        let result = await outcome(ok(prose))
        guard case .failed(let why) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(why.hasPrefix("the compiler gave no usable answer"), why)
    }

    func testRecordingMovesTheRuleThroughItsStates() {
        let ref = CompilerRef(harness: "claude", model: "haiku")
        var rule = RoutingRule(id: "r1", sentence: D.specSentence)
        rule.record(.unavailable("offline"), by: ref, at: D.at)
        XCTAssertEqual(rule.state, .draft); XCTAssertNil(rule.compiledAt)
        rule.record(.failed("unknown dimension teleportation"), by: ref, at: D.at)
        XCTAssertEqual(rule.state, .failed); XCTAssertEqual(rule.failure, "unknown dimension teleportation"); XCTAssertNil(rule.compiled)
        rule.record(.compiled(D.r3().compiled!), by: ref, at: D.at)
        XCTAssertEqual(rule.state, .compiled); XCTAssertNil(rule.failure)
        XCTAssertEqual(rule.compiler, ref); XCTAssertEqual(rule.compiledAt, D.at)
    }

    func testThePromptCarriesEveryInput() {
        let p = RuleCompilerPrompt.text(D.input())
        XCTAssertTrue(p.contains(D.specSentence))
        for d in Dimensions.all { XCTAssertTrue(p.contains(d.id), d.id) }
        XCTAssertTrue(p.contains("snapshot-tests"))
        XCTAssertFalse(p.contains("golden-tests"), "merged kinds are not offered for new conditions")
        XCTAssertTrue(p.contains("gpt-6-luna"))
        XCTAssertTrue(p.contains("effort = low | medium | high"))
        XCTAssertTrue(p.contains("- codex-subs (codex)"))
        XCTAssertTrue(p.contains("Default model: opus"))
    }

    func testTheSchemaIsStrict() throws {
        func strict(_ node: Any) {
            guard let obj = node as? [String: Any] else { return }
            if let props = obj["properties"] as? [String: Any] {
                XCTAssertEqual(obj["additionalProperties"] as? Bool, false)
                XCTAssertEqual(Set(obj["required"] as? [String] ?? []), Set(props.keys))
                props.values.forEach(strict)
            }
            if let items = obj["items"] { strict(items) }
        }
        strict(try JSONSerialization.jsonObject(with: Data(RuleCompilerPrompt.schemaJSON.utf8)))
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=RuleCompilerTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'RuleCompiler' in scope`.

- [ ] **Step 4: Implement `RuleCompilerPrompt.swift`**

```swift
import Foundation

/// The compiler's prompt and its output schema (spec L3-R §3).
public enum RuleCompilerPrompt {
    /// Strict mode for both `claude --json-schema` and `codex exec --output-schema`: every object
    /// lists every property in `required`, optional values typed `[<type>, "null"]`.
    public static let schemaJSON = """
    {"type":"object","additionalProperties":false,
     "required":["ok","reason","mode","terms","harness","model","modelDefaulted","knobs","pool","fallbackPool"],
     "properties":{
      "ok":{"type":"boolean"},
      "reason":{"type":["string","null"]},
      "mode":{"type":"string","enum":["any","all"]},
      "terms":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["dimension","atLeast","kind"],
               "properties":{"dimension":{"type":["string","null"]},"atLeast":{"type":["number","null"]},"kind":{"type":["string","null"]}}}},
      "harness":{"type":["string","null"]},
      "model":{"type":["string","null"]},
      "modelDefaulted":{"type":"boolean"},
      "knobs":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","value"],
               "properties":{"name":{"type":"string"},"value":{"type":"string"}}}},
      "pool":{"type":["string","null"]},
      "fallbackPool":{"type":["string","null"]}}}
    """

    public static func text(_ input: RuleCompilerInput) -> String {
        let dimensions = Dimensions.all.map { "- \($0.id): \($0.summary)" }.joined(separator: "\n")
        // Merged kinds are left out: a new condition on a kind that no longer exists would only
        // ever match through its merge target, which the agent should name instead.
        let live = input.kinds.filter { kind in
            if case .merged = kind.status { return false }
            return true
        }
        let kinds = live.map { k -> String in
            let weights = k.dimensions.sorted { $0.key < $1.key }.map { "\($0.key) \(RuleText.number($0.value))" }
            return "- \(k.id.rawValue) (\(k.name)): \(k.description). Weights: \(weights.isEmpty ? "none" : weights.joined(separator: ", "))"
        }.joined(separator: "\n")
        let agents = input.catalogs.order.compactMap { input.catalogs.byHarness[$0] }.map { c -> String in
            let models = c.models.map { "\($0.id) (\($0.displayName))" }.joined(separator: ", ")
            let knobs = c.knobSchema.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value.joined(separator: " | "))" }
            return "- \(c.harness.rawValue) (\(c.enabled ? "enabled" : "not enabled")). Default model: \(c.defaultModel ?? "none"). "
                + "Models: \(models.isEmpty ? "none" : models). Options: \(knobs.isEmpty ? "none" : knobs.joined(separator: "; "))"
        }.joined(separator: "\n")
        let pools = input.pools.map { "- \($0.id.rawValue) (\($0.harness.rawValue))" }.joined(separator: "\n")

        return """
        You compile one routing rule for Flight Deck. A routing rule says which coding agent, \
        model, options and capacity pool run some kind of task.

        Sentence:
        \(input.sentence)

        Capability dimensions (every task kind weighs each one from 0 to 1):
        \(dimensions)

        Task kinds:
        \(kinds.isEmpty ? "- none" : kinds)

        Agents:
        \(agents.isEmpty ? "- none" : agents)

        Pools:
        \(pools.isEmpty ? "- none" : pools)

        How to answer:
        - Turn what the sentence describes into conditions. A condition is either \
        {dimension, atLeast} — the task kind weighs at least atLeast on that dimension — or \
        {kind} — the task is that kind or a kind merged into it. Set the unused fields of a \
        condition to null.
        - Prefer dimension conditions for general descriptions ("tests", "complex algorithms"), \
        so kinds added later match too. Add a kind condition when the sentence names a listed kind.
        - mode is "any" when any one condition is enough, "all" when every condition must hold.
        - harness is the agent the sentence names. model is the model it names, matched to that \
        agent's list; if it names none, use that agent's default model and set modelDefaulted to true.
        - knobs: only options the agent lists, with a listed value. An empty list when the \
        sentence names none.
        - pool is the pool the sentence names, or null for the agent's default pool. fallbackPool \
        is a second pool the sentence names as an "else", or null.
        - If the sentence is not a routing rule, set ok to false and say why in reason. \
        Otherwise ok is true and reason is null.

        Return only JSON matching the provided schema.
        """
    }
}
```

- [ ] **Step 5: Implement `RuleCompiler.swift`**

```swift
import Foundation

/// What the compiler handed back, before validation.
public enum RuleProposal: Equatable, Sendable {
    case wire(RuleCompilerWire)
    /// The compiler could not run (no CLI, not logged in, no network). The rule stays a draft.
    case unavailable(String)
    /// It ran, but the answer was not the schema's shape. The rule fails with this reason.
    case malformed(String)
}

public enum RuleCompileOutcome: Equatable, Sendable {
    case compiled(CompiledRule)
    case failed(String)
    case unavailable(String)
}

/// The seam the app compiles through, so Settings and the UI-test fixture can swap the model
/// call while keeping the real validation.
public protocol RuleCompiling: Sendable {
    var ref: CompilerRef { get }
    func propose(_ input: RuleCompilerInput) async -> RuleProposal
}

public enum RuleCompilation {
    /// No automatic retry (spec §3): a failed rule shows its first error and waits for you.
    public static func finish(_ proposal: RuleProposal, input: RuleCompilerInput) -> RuleCompileOutcome {
        switch proposal {
        case .unavailable(let why):
            return .unavailable(why)
        case .malformed(let why):
            return .failed("the compiler gave no usable answer: \(why)")
        case .wire(let wire):
            switch RuleValidator.validate(wire, input: input) {
            case .success(let compiled): return .compiled(compiled)
            case .failure(let error): return .failed(error.message)
            }
        }
    }
}

extension RoutingRule {
    /// An unavailable compiler changes nothing: confirmed rules keep routing and drafts stay
    /// drafts (spec §8).
    public mutating func record(_ outcome: RuleCompileOutcome, by compiler: CompilerRef, at date: Date) {
        switch outcome {
        case .compiled(let c):
            compiled = c; state = .compiled; failure = nil; compiledAt = date; self.compiler = compiler
        case .failed(let why):
            compiled = nil; state = .failed; failure = why; compiledAt = date; self.compiler = compiler
        case .unavailable:
            break
        }
    }
}

/// One headless model call per sentence (spec §3) — `claude -p` haiku by default — through the
/// same `HarnessCommand` every planning round uses, read-only, in a scratch directory.
public struct RuleCompiler: RuleCompiling {
    public let runner: any CommandRunner
    public let settings: RuleCompilerSettings
    public let workDirectory: URL
    /// Where `HarnessCommand` reads the user's codex/claude settings from. A test passes a
    /// scratch directory so it never reads the operator's own.
    public let home: URL
    public let baseEnvironment: @Sendable () -> [String: String]

    public init(runner: any CommandRunner, settings: RuleCompilerSettings, workDirectory: URL,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                baseEnvironment: @escaping @Sendable () -> [String: String]) {
        self.runner = runner; self.settings = settings; self.workDirectory = workDirectory
        self.home = home; self.baseEnvironment = baseEnvironment
    }

    public var ref: CompilerRef { settings.ref }

    public func propose(_ input: RuleCompilerInput) async -> RuleProposal {
        let schemaFile = workDirectory.appendingPathComponent("rule-schema.json")
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try Data(RuleCompilerPrompt.schemaJSON.utf8).write(to: schemaFile, options: .atomic)
        } catch {
            return .unavailable("could not prepare \(workDirectory.path): \(error)")
        }
        let request = HarnessRequest(harness: settings.harness, model: settings.model, effort: settings.effort,
                                     cwd: workDirectory, readableDirs: [], prompt: RuleCompilerPrompt.text(input),
                                     schemaFile: schemaFile, schemaJSON: RuleCompilerPrompt.schemaJSON, resumeSessionID: nil)
        let command = HarnessCommand.build(request, home: home)
        let environment = HarnessCommand.environment(for: command, base: baseEnvironment(), home: home)
        let result: CommandResult
        do {
            result = try await runner.run(executable: command.executable, arguments: command.arguments, cwd: workDirectory,
                                          environment: environment, processGroup: false, onSpawn: nil)
        } catch {
            return .unavailable("could not start \(command.executable): \(error)")
        }
        guard result.exitCode == 0 else {
            let line = result.stderr.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return .unavailable("\(command.executable) exited \(result.exitCode)" + (line.isEmpty ? "" : ": \(line)"))
        }
        let structured: Data
        do { structured = try HarnessOutput.parse(settings.harness, stdout: result.stdout).structured }
        catch { return .malformed("\(error)") }
        do { return .wire(try JSONDecoder().decode(RuleCompilerWire.self, from: structured)) }
        catch { return .malformed("not the rule shape: \(error)") }
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=RuleCompilerTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 10 tests, with 0 failures`.

- [ ] **Step 7: Run the terminology guard over the new IntakeKit strings**

Run: `FD_TEST_FILTER=TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures`. (The prompt is scanned like every other IntakeKit file; it must say
"task", never "bead".)

- [ ] **Step 8: Commit**

```bash
git add Sources/IntakeKit/FlightControl/RuleCompilerPrompt.swift Sources/IntakeKit/FlightControl/RuleCompiler.swift Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/compiler-valid.claude.jsonl Tests/FlightDeckTests/FlightControlL3/Routing/RoutingFixtures.swift Tests/FlightDeckTests/FlightControlL3/Routing/RuleCompilerTests.swift
git commit -m "feat: compile a routing sentence with one schema-constrained headless call, then validate it" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The compiler's live probe (skipped by default)

**Files:**
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RuleCompilerLiveTests.swift`

**Interfaces:**
- Consumes: Task 7; `SystemCommandRunner` (IntakeKit), `LoginShellPath.repairing(_:)` (app).
- Produces: nothing.

- [ ] **Step 1: Write the live test**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The fixture in `RuleCompilerTests` is only as good as its claim to look like real output.
/// This spends one haiku call to prove the real CLI accepts the schema and that the spec's
/// sentence compiles to a rule that routes tests to codex. Skipped unless `ROUTING_LIVE=1`.
final class RuleCompilerLiveTests: XCTestCase {
    func testHaikuCompilesTheSpecSentence() async throws {
        guard ProcessInfo.processInfo.environment["ROUTING_LIVE"] == "1" else {
            throw XCTSkip("set ROUTING_LIVE=1 — this spends tokens")
        }
        // Under $HOME, never /tmp (see BeadWriterLiveTests).
        let work = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".fd-routing-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let compiler = RuleCompiler(runner: SystemCommandRunner(), settings: .default, workDirectory: work,
                                    baseEnvironment: { LoginShellPath.repairing(ProcessInfo.processInfo.environment) })
        let input = RoutingTestData.input()
        let proposal = await compiler.propose(input)
        let outcome = RuleCompilation.finish(proposal, input: input)
        guard case .compiled(let rule) = outcome else { return XCTFail("\(outcome) — proposal: \(proposal)") }
        XCTAssertEqual(rule.assign.harness, "codex")
        XCTAssertTrue(rule.match.terms.contains { term in
            if case .dimension("test-authoring", _) = term { return true }
            return false
        }, "\(rule.match)")
    }
}
```

- [ ] **Step 2: Run it skipped, then once live**

Run: `FD_TEST_FILTER=RuleCompilerLiveTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 1 test, with 1 test skipped and 0 failures`.

Run (once; spends one haiku call): `ROUTING_LIVE=1 FD_TEST_FILTER=RuleCompilerLiveTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 1 test, with 0 failures` and no `skipped`.
- If it fails with `.unavailable`, `claude` is not on the login PATH or not logged in: record that
  in the task report, leave the test as is, and move on (the hermetic suite already covers the logic).
- If it fails with `.failed("…")`, the message names the field the real model got wrong. Copy the
  printed proposal into the report. If the model chose a different but sensible pool or model,
  that is a prompt problem: tighten the matching bullet in `RuleCompilerPrompt.text` and re-run
  once. Never loosen the assertions.

- [ ] **Step 3: Commit**

```bash
git add Tests/FlightDeckTests/FlightControlL3/Routing/RuleCompilerLiveTests.swift
git commit -m "test: probe the rule compiler against real headless haiku when ROUTING_LIVE=1" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 9: Real model catalogs and knob schemas for claude and codex

**Files:**
- Create: `Sources/FlightDeck/FlightControl/RoutingCatalogs.swift`
- Modify: `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift` (L3-0's file: the two stub classes)
- Modify: `Tests/FlightDeckTests/FlightControlL3/RoutingCapabilityRegistryTests.swift` (L3-0's test, one method)
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/codex-model-list.json`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingCatalogsTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingCatalogsLiveTests.swift`

**Interfaces:**
- Consumes (L3-0): `AgentRoutingCapabilities`, `RoutingCapability`, `RoutingCapabilityRegistry`, `ClaudeRoutingCapabilities`, `CodexRoutingCapabilities`, `ModelEntry`; fake `FakeRoutingCapabilities`. App: `ClaudeFlagCatalog.all` (`Sources/FlightDeck/Preferences/ClaudeFlagCatalog.swift:74`, `FlagSpec.canonical`, `.kind`), `CodexProcessTransport` (`start()`, `stop()`, `onTerminate`, `static verifyHandshake(_:)`), `CodexRPC` (`init(transport:)`, `request(_:_:)`, `transportClosed()`), `CodexRPCError.timeout`.
- Produces:
  - `enum ClaudeRoutingCatalog { static var models: [ModelEntry]; static var knobSchema: [String: [String]] }`
  - `@MainActor final class CodexRoutingCatalog { static let shared; init(fetch:); func models() async -> RoutingCapability<[ModelEntry]>; private(set) var knobSchema; func invalidate(); nonisolated static func parse(_:) -> ([ModelEntry], [String: [String]]); static func liveFetch() async throws -> [String: Any] }`
  - `ClaudeRoutingCapabilities` / `CodexRoutingCapabilities`: `modelCatalog()` and `knobSchema` now real.

Facts this task relies on, probed 2026-10-04 while planning: `codex app-server` (codex-cli
0.160.0) answers `model/list` `{"includeHidden": false}` with `{"data": [Model], "nextCursor": null}`,
eight models, `gpt-6.1-sol` the one with `isDefault: true`, efforts per model under
`supportedReasoningEfforts[].reasoningEffort`. Claude has no model-list command; `ClaudeFlagCatalog`
lists `--model` aliases `fable, opus, sonnet, haiku` and `--effort` `low, medium, high, xhigh, max`.

- [ ] **Step 1: Verify L3-0's stub lines and test are as planned**

```bash
rg -n -F 'func modelCatalog() async -> RoutingCapability<[ModelEntry]> { .unsupported(reason: "filled in by L3-R") }' Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift
rg -n -F 'var knobSchema: [String: [String]] { [:] }' Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift
rg -n "func testUnsupportedCatalogYieldsAnEmptyDisabledCatalog" -A6 Tests/FlightDeckTests/FlightControlL3/RoutingCapabilityRegistryTests.swift
```

Expected: two matches each for the first two (one per class), and the L3-0 test body calling
`RoutingCapabilityRegistry.standard()`. If L3-0 merged with different stub text, make the
equivalent edit in Step 5 (same two members, same replacement bodies); if the test's body differs,
replace whatever it is with the Step 5 body — the point is that no unit test may ask the standard
registry for catalogs once codex's spawns a process.

- [ ] **Step 2: Write the fixture**

`Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/codex-model-list.json` — the live
`model/list` result, trimmed to the fields Flight Deck reads (descriptions emptied):

```json
{"data":[{"id":"gpt-6.1-sol","model":"gpt-6.1-sol","displayName":"GPT-6.1-Sol","hidden":false,"isDefault":true,"defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""},{"reasoningEffort":"xhigh","description":""},{"reasoningEffort":"max","description":""},{"reasoningEffort":"ultra","description":""}]},{"id":"gpt-6-astra","model":"gpt-6-astra","displayName":"GPT-6-Astra","hidden":false,"isDefault":false,"defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""},{"reasoningEffort":"xhigh","description":""},{"reasoningEffort":"max","description":""},{"reasoningEffort":"ultra","description":""}]},{"id":"gpt-6-sol","model":"gpt-6-sol","displayName":"GPT-6-Sol","hidden":false,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""},{"reasoningEffort":"xhigh","description":""},{"reasoningEffort":"max","description":""},{"reasoningEffort":"ultra","description":""}]},{"id":"gpt-6-luna","model":"gpt-6-luna","displayName":"GPT-6-Luna","hidden":false,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""},{"reasoningEffort":"xhigh","description":""},{"reasoningEffort":"max","description":""}]},{"id":"gpt-5.6-sol","model":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","hidden":false,"isDefault":false,"defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""},{"reasoningEffort":"xhigh","description":""},{"reasoningEffort":"max","description":""},{"reasoningEffort":"ultra","description":""}]},{"id":"gpt-5.6-terra","model":"gpt-5.6-terra","displayName":"GPT-5.6-Terra","hidden":false,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""},{"reasoningEffort":"xhigh","description":""},{"reasoningEffort":"max","description":""},{"reasoningEffort":"ultra","description":""}]},{"id":"gpt-5.6-luna","model":"gpt-5.6-luna","displayName":"GPT-5.6-Luna","hidden":false,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""},{"reasoningEffort":"xhigh","description":""},{"reasoningEffort":"max","description":""}]},{"id":"gpt-5.5","model":"gpt-5.5","displayName":"GPT-5.5","hidden":false,"isDefault":false,"defaultReasoningEffort":"medium","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""},{"reasoningEffort":"medium","description":""},{"reasoningEffort":"high","description":""},{"reasoningEffort":"xhigh","description":""}]}],"nextCursor":null}
```

- [ ] **Step 3: Write the failing tests**

`RoutingCatalogsTests.swift`:

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The validator and the router can only be as right as the catalogs they check against. Claude's
/// comes from the flag catalog Settings already uses; codex's from its own app-server. Nothing
/// here spawns codex: the fetch is injected.
@MainActor
final class RoutingCatalogsTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: RoutingFixtures.data("codex-model-list.json")) as? [String: Any])
    }

    func testClaudeOffersItsAliasesWithOpusFirstAndAnEffortKnob() async throws {
        let caps = try XCTUnwrap(RoutingCapabilityRegistry.standard().capabilities(for: "claude"))
        let catalog = await caps.modelCatalog()
        let models = try XCTUnwrap(catalog.value)
        XCTAssertEqual(models.first?.id, "opus", "opus is Flight Deck's default claude model everywhere else")
        XCTAssertEqual(Set(models.map(\.id)), ["fable", "opus", "sonnet", "haiku"])
        XCTAssertTrue(models.allSatisfy { $0.knobs == ["effort"] })
        XCTAssertEqual(caps.knobSchema, ["effort": ["low", "medium", "high", "xhigh", "max"]])
    }

    func testCodexParsesTheLiveModelListWithTheDefaultFirst() throws {
        let (models, schema) = CodexRoutingCatalog.parse(try fixture())
        XCTAssertEqual(models.map(\.id), ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
                                          "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5"])
        XCTAssertEqual(models.first?.displayName, "GPT-6.1-Sol")
        XCTAssertEqual(schema, ["effort": ["low", "medium", "high", "xhigh", "max", "ultra"]])
    }

    func testHiddenModelsAreLeftOutAndTheDefaultMovesFirst() {
        let result: [String: Any] = ["data": [
            ["id": "a", "displayName": "A", "hidden": false, "isDefault": false,
             "supportedReasoningEfforts": [["reasoningEffort": "low", "description": ""]]],
            ["id": "secret", "displayName": "S", "hidden": true, "isDefault": false, "supportedReasoningEfforts": []],
            ["id": "b", "displayName": "B", "hidden": false, "isDefault": true, "supportedReasoningEfforts": []],
        ]]
        let (models, schema) = CodexRoutingCatalog.parse(result)
        XCTAssertEqual(models.map(\.id), ["b", "a"])
        XCTAssertEqual(models.first?.knobs, [], "a model that lists no efforts accepts no effort knob")
        XCTAssertEqual(schema, ["effort": ["low"]])
    }

    func testCodexFetchesOnceAndCaches() async throws {
        let data = try fixture()
        var fetches = 0
        let catalog = CodexRoutingCatalog(fetch: { fetches += 1; return data })
        let first = await catalog.models()
        let second = await catalog.models()
        XCTAssertEqual(first.value?.count, 8)
        XCTAssertEqual(second.value?.count, 8)
        XCTAssertEqual(fetches, 1, "one app-server spawn per launch, not per compile")
        XCTAssertEqual(catalog.knobSchema["effort"]?.last, "ultra")
    }

    func testAFailedFetchIsUnsupportedAndRetriedNextTime() async throws {
        struct Down: Error {}
        let data = try fixture()
        var fail = true
        let catalog = CodexRoutingCatalog(fetch: { if fail { throw Down() }; return data })
        let first = await catalog.models()
        guard case .unsupported(let why) = first else { return XCTFail("a failed fetch must not look like an empty catalog") }
        XCTAssertTrue(why.hasPrefix("codex model list unavailable"), why)
        XCTAssertEqual(catalog.knobSchema, [:])
        fail = false
        let second = await catalog.models()
        XCTAssertEqual(second.value?.first?.id, "gpt-6.1-sol")
    }

    func testAnEmptyListIsUnsupportedNotAnEmptyCatalog() async {
        let catalog = CodexRoutingCatalog(fetch: { ["data": [[String: Any]]()] })
        let result = await catalog.models()
        guard case .unsupported = result else { return XCTFail("an empty list must not route as 'codex has no models'") }
    }

    func testTheRegistryCombinesRealClaudeWithAnyOtherAgent() async {
        let codex = FakeRoutingCapabilities()
        codex.harness = "codex"
        codex.catalog = .supported([ModelEntry(id: "gpt-6-sol", displayName: "GPT-6-Sol", knobs: ["effort"])])
        codex.knobSchema = ["effort": ["low", "high"]]
        let cats = await RoutingCapabilityRegistry([ClaudeRoutingCapabilities(), codex]).catalogs(enabled: ["claude", "codex"])
        XCTAssertEqual(cats.byHarness["claude"]?.defaultModel, "opus")
        XCTAssertTrue(cats.knobsValid(ModelRef(harness: "claude", model: "haiku", knobs: ["effort": "xhigh"])))
        XCTAssertTrue(cats.contains(ModelRef(harness: "codex", model: "gpt-6-sol")))
    }
}
```

`RoutingCatalogsLiveTests.swift`:

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spawns a real `codex app-server` and asks for `model/list` — the shape the fixture was
/// trimmed from. Skipped unless `ROUTING_LIVE=1`; spends no tokens.
@MainActor
final class RoutingCatalogsLiveTests: XCTestCase {
    func testCodexListsModelsWithEfforts() async throws {
        guard ProcessInfo.processInfo.environment["ROUTING_LIVE"] == "1" else { throw XCTSkip("set ROUTING_LIVE=1") }
        let (models, schema) = CodexRoutingCatalog.parse(try await CodexRoutingCatalog.liveFetch())
        XCTAssertFalse(models.isEmpty)
        XCTAssertNotNil(schema["effort"])
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `FD_TEST_FILTER=RoutingCatalogsTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'CodexRoutingCatalog' in scope`.

- [ ] **Step 5: Implement `RoutingCatalogs.swift`, point the stubs at it, and rewrite L3-0's test**

`Sources/FlightDeck/FlightControl/RoutingCatalogs.swift`:

```swift
import Foundation
import IntakeKit

/// Claude's routable models: the aliases `ClaudeFlagCatalog` offers for `--model`, `opus` first
/// because it is Flight Deck's default claude model everywhere else (`AvailableModels.defaults`).
///
/// Aliases only. Claude has no model-list command, and a hand-kept list of full ids goes stale
/// silently — the failure a rule validated against it would then hide.
enum ClaudeRoutingCatalog {
    static var knobSchema: [String: [String]] { ["effort": choices("--effort")] }

    static var models: [ModelEntry] {
        let aliases = choices("--model")
        let ordered = aliases.filter { $0 == "opus" } + aliases.filter { $0 != "opus" }
        return ordered.map { ModelEntry(id: $0, displayName: $0.capitalized, knobs: ["effort"]) }
    }

    private static func choices(_ flag: String) -> [String] {
        guard let spec = ClaudeFlagCatalog.all.first(where: { $0.canonical == flag }),
              case .choice(let values, _) = spec.kind else { return [] }
        return values
    }
}

/// Codex's routable models, from the app-server's own `model/list` — the list codex itself
/// offers, so a model it retires leaves routing the same day.
///
/// A short-lived app-server rather than a session's per-account one: the list does not depend on
/// the account, and routing must work with no codex tab open. Cached for the launch, because
/// every compile and every release asks, and each ask would otherwise spawn a process. A failed
/// fetch is not cached: the next ask tries again.
@MainActor
final class CodexRoutingCatalog {
    static let shared = CodexRoutingCatalog()
    typealias Fetch = @MainActor () async throws -> [String: Any]

    private let fetch: Fetch
    private var cached: [ModelEntry]?
    /// The union of every listed model's efforts. Empty until a fetch succeeds, so a knob can
    /// never validate against a schema nobody has read.
    private(set) var knobSchema: [String: [String]] = [:]

    init(fetch: @escaping Fetch = CodexRoutingCatalog.liveFetch) { self.fetch = fetch }

    func models() async -> RoutingCapability<[ModelEntry]> {
        if let cached { return .supported(cached) }
        do {
            let (models, schema) = Self.parse(try await fetch())
            guard !models.isEmpty else { return .unsupported(reason: "codex listed no models") }
            cached = models
            knobSchema = schema
            return .supported(models)
        } catch {
            return .unsupported(reason: "codex model list unavailable: \(error)")
        }
    }

    func invalidate() {
        cached = nil
        knobSchema = [:]
    }

    /// Hidden models are left out; the `isDefault` model goes first, because
    /// `RoutingCapabilityRegistry.catalogs` takes the first model as the adapter's default.
    nonisolated static func parse(_ result: [String: Any]) -> ([ModelEntry], [String: [String]]) {
        var models: [ModelEntry] = []
        var efforts: [String] = []
        var defaultIndex: Int?
        for m in result["data"] as? [[String: Any]] ?? [] where (m["hidden"] as? Bool) != true {
            guard let id = m["id"] as? String, !id.isEmpty else { continue }
            let supported = (m["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            for e in supported where !efforts.contains(e) { efforts.append(e) }
            if m["isDefault"] as? Bool == true, defaultIndex == nil { defaultIndex = models.count }
            models.append(ModelEntry(id: id, displayName: m["displayName"] as? String ?? id,
                                     knobs: supported.isEmpty ? [] : ["effort"]))
        }
        if let i = defaultIndex, i > 0 { models.insert(models.remove(at: i), at: 0) }
        return (models, efforts.isEmpty ? [:] : ["effort": efforts])
    }

    /// One app-server, handshake, every page of `model/list`, stop. Each page is raced against a
    /// timer: a wedged app-server must fail the compile, not hang the Settings pane forever.
    static func liveFetch() async throws -> [String: Any] {
        let transport = CodexProcessTransport()
        let rpc = CodexRPC(transport: transport)
        transport.onTerminate = { [weak rpc] in rpc?.transportClosed() }
        try transport.start()
        defer { transport.stop() }
        try await CodexProcessTransport.verifyHandshake(rpc)
        var all: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<20 {
            let after = cursor
            let page: [String: Any] = try await withThrowingTaskGroup(of: [String: Any]?.self) { group in
                group.addTask {
                    var params: [String: Any] = ["includeHidden": false]
                    if let after { params["cursor"] = after }
                    return try await rpc.request("model/list", params)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw CodexRPCError.timeout
                }
                defer { group.cancelAll() }
                return (try await group.next() ?? nil) ?? [:]
            }
            all += page["data"] as? [[String: Any]] ?? []
            cursor = page["nextCursor"] as? String
            if cursor == nil { break }
        }
        return ["data": all]
    }
}
```

In `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift`, inside
`final class ClaudeRoutingCapabilities`, replace:

```swift
    var knobSchema: [String: [String]] { [:] }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { .unsupported(reason: "filled in by L3-R") }
```

with:

```swift
    var knobSchema: [String: [String]] { ClaudeRoutingCatalog.knobSchema }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { .supported(ClaudeRoutingCatalog.models) }
```

and inside `final class CodexRoutingCapabilities`, replace the same two lines with:

```swift
    var knobSchema: [String: [String]] { CodexRoutingCatalog.shared.knobSchema }
    func modelCatalog() async -> RoutingCapability<[ModelEntry]> { await CodexRoutingCatalog.shared.models() }
```

(Edit each with the class's own `let harness: HarnessID = AgentID.<agent>.harnessID` line included
in `old_string`, so each replacement is unique.) In the doc comment above the two classes, replace
"Stubs until L3-R (catalog, knobs, overrides), L3-U (meter, transcript) and L3-S (reset) fill
them in." with "Catalog and knobs are real (L3-R, `RoutingCatalogs.swift`); the rest stay stubs
until L3-U (meter, transcript) and L3-S (reset, overrides) fill them in."

In `Tests/FlightDeckTests/FlightControlL3/RoutingCapabilityRegistryTests.swift`, replace the whole
`testUnsupportedCatalogYieldsAnEmptyDisabledCatalog` method with:

```swift
    /// Rewritten by L3-R: claude's and codex's catalogs are real now, and asking the standard
    /// registry for codex's spawns `codex app-server` — never from a unit test. The behavior
    /// pinned is unchanged: an unsupported catalog is an empty, disabled one.
    func testUnsupportedCatalogYieldsAnEmptyDisabledCatalog() async {
        let stub = FakeRoutingCapabilities()
        stub.catalog = .unsupported(reason: "not yet")
        let cats = await RoutingCapabilityRegistry([stub]).catalogs(enabled: ["fake"])
        XCTAssertEqual(cats.byHarness["fake"]?.models, [])
        XCTAssertEqual(cats.enabledModels, [], "an unsupported catalog must never pretend to have models")
    }
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=RoutingCatalogsTests,RoutingCatalogsLiveTests,RoutingCapabilityRegistryTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 13 tests, with 1 test skipped and 0 failures` (7 + 1 skipped + 5).

Run once, live (spawns `codex app-server`, no tokens):
`ROUTING_LIVE=1 FD_TEST_FILTER=RoutingCatalogsLiveTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 1 test, with 0 failures`. If codex is not installed it fails with
`notInstalled`; record that in the report and continue.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/FlightControl/RoutingCatalogs.swift Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift Tests/FlightDeckTests/FlightControlL3/RoutingCapabilityRegistryTests.swift Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/codex-model-list.json Tests/FlightDeckTests/FlightControlL3/Routing/RoutingCatalogsTests.swift Tests/FlightDeckTests/FlightControlL3/Routing/RoutingCatalogsLiveTests.swift
git commit -m "feat: route against claude's model aliases and codex's own model list" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: The create op carries a task kind or a kind proposal

**Files:**
- Modify: `Sources/IntakeKit/ChangeSet.swift` (`NewBead` at :48-61, `ChangeOp` coding at :81-151)
- Modify: `Sources/IntakeKit/Triage.swift` (`op` schema at :17-34)
- Modify: `Tests/FlightDeckTests/Fixtures/Intake/triage-schema.json` (regenerated)
- Modify: `Tests/FlightDeckTests/Intake/RoundPromptsTests.swift` (doc comment of `testTriageSchemaJSONUnchangedByTheRefactor`, :108-110)
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/ChangeSetKindTests.swift`

**Interfaces:**
- Consumes (L3-0): `KindID`.
- Produces:
  - `public struct KindProposal: Codable, Equatable, Sendable { name: String; description: String; dimensions: [String: Double] }` — wire form `{"name","description","dimensions":[{"dimension","weight"}]}`
  - `NewBead.taskKind: KindID?`, `NewBead.kindProposal: KindProposal?`; `NewBead.init(…, taskKind: KindID? = nil, kindProposal: KindProposal? = nil)`
  - JSON keys `taskKind` and `kindProposal` on every op (null except on `createBead`).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// Planning classifies each created task (spec L3-R §4). The key is `taskKind`, not `kind`: the
/// op schema is one flat object and `kind` is `addEdge`'s edge kind, whose closed enum would reject
/// every kind id (deviation 1). Intakes saved before this existed must keep decoding.
final class ChangeSetKindTests: XCTestCase {
    private func create(_ extra: String) -> String {
        #"{"op":"createBead","tempId":"n1","title":"T","type":"task","priority":2,"description":"d","acceptance":null,"labels":[],"from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null"#
            + extra + "}"
    }

    private func bead(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> NewBead? {
        let op = try IntakeJSON.decoder.decode(ChangeOp.self, from: Data(json.utf8))
        guard case .createBead(let b) = op else { XCTFail("not a create: \(op)", file: file, line: line); return nil }
        return b
    }

    func testACreateCarriesAKindId() throws {
        let b = try XCTUnwrap(try bead(create(#","taskKind":"tests","kindProposal":null"#)))
        XCTAssertEqual(b.taskKind, "tests")
        XCTAssertNil(b.kindProposal)
    }

    func testACreateCarriesAProposalWithWeightsAsAnArray() throws {
        let b = try XCTUnwrap(try bead(create(#","taskKind":null,"kindProposal":{"name":"Snapshot Tests","description":"Golden files","dimensions":[{"dimension":"test-authoring","weight":0.8},{"dimension":"agentic-coding","weight":0.3}]}"#)))
        XCTAssertNil(b.taskKind)
        XCTAssertEqual(b.kindProposal, KindProposal(name: "Snapshot Tests", description: "Golden files",
                                                    dimensions: ["test-authoring": 0.8, "agentic-coding": 0.3]))
    }

    func testAnOpFromBeforeKindsStillDecodes() throws {
        let b = try XCTUnwrap(try bead(create("")))
        XCTAssertNil(b.taskKind); XCTAssertNil(b.kindProposal)
    }

    func testAnEmptyKindIdIsNoKind() throws {
        XCTAssertNil(try XCTUnwrap(try bead(create(#","taskKind":"","kindProposal":null"#))).taskKind)
    }

    func testEncodingOmitsAbsentKindsAndRoundTrips() throws {
        let plain = ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 1_790_000_000),
                              ops: [.createBead(NewBead(tempId: "n1", title: "T", description: "d"))])
        XCTAssertFalse(String(decoding: try plain.encoded(), as: UTF8.self).contains("taskKind"),
                       "a change set with no kinds encodes exactly as before")
        let kinded = ChangeSet(graphObservedAt: Date(timeIntervalSince1970: 1_790_000_000), ops: [
            .createBead(NewBead(tempId: "n1", title: "T", description: "d", taskKind: "tests")),
            .createBead(NewBead(tempId: "n2", title: "U", description: "e",
                                kindProposal: KindProposal(name: "Snapshot Tests", description: "x", dimensions: ["test-authoring": 0.8]))),
        ])
        XCTAssertEqual(try ChangeSet.decode(kinded.encoded()), kinded)
    }

    func testTheEdgeKindIsUntouched() throws {
        let edge = #"{"op":"addEdge","tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"from":"new:n1","to":"b1","kind":"blocks","id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null,"taskKind":null,"kindProposal":null}"#
        XCTAssertEqual(try IntakeJSON.decoder.decode(ChangeOp.self, from: Data(edge.utf8)),
                       .addEdge(from: .new("n1"), to: .existing("b1"), kind: .blocks))
    }

    func testTheSchemaOffersBothFieldsOnTheOp() throws {
        let fragment = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Triage.changeSetSchemaFragment.utf8)) as? [String: Any])
        let ops = try XCTUnwrap((fragment["properties"] as? [String: Any])?["ops"] as? [String: Any])
        let op = try XCTUnwrap(ops["items"] as? [String: Any])
        let required = Set(op["required"] as? [String] ?? [])
        XCTAssertTrue(required.isSuperset(of: ["taskKind", "kindProposal"]))
        let props = try XCTUnwrap(op["properties"] as? [String: Any])
        XCTAssertEqual(Set(props.keys), required, "strict mode: every property required")
        let edgeKinds = try XCTUnwrap((props["kind"] as? [String: Any])?["enum"] as? [Any])
        XCTAssertEqual(edgeKinds.compactMap { $0 as? String }, ["blocks", "related", "parent-child"], "the edge kind's enum is untouched")
        let proposal = try XCTUnwrap(props["kindProposal"] as? [String: Any])
        XCTAssertEqual(proposal["type"] as? [String], ["object", "null"])
        XCTAssertEqual(proposal["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(proposal["required"] as? [String] ?? []), ["name", "description", "dimensions"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=ChangeSetKindTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build errors `cannot find 'KindProposal' in scope` / `extra argument 'taskKind' in call`.

- [ ] **Step 3: Add `KindProposal` and the two fields to `ChangeSet.swift`**

Above `public struct NewBead`, add:

```swift
/// A new task kind a planning agent proposes when no listed kind fits (spec L3-R §4). Its
/// weights travel as `[{dimension, weight}]`: strict-mode output schemas cannot describe an
/// open-keyed object, so the dictionary exists only on this side of the wire.
public struct KindProposal: Codable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var dimensions: [String: Double]

    public init(name: String, description: String, dimensions: [String: Double]) {
        self.name = name; self.description = description; self.dimensions = dimensions
    }

    private struct Weight: Codable { let dimension: String; let weight: Double }
    private enum Key: String, CodingKey { case name, description, dimensions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        var dims: [String: Double] = [:]
        for w in try c.decodeIfPresent([Weight].self, forKey: .dimensions) ?? [] { dims[w.dimension] = w.weight }
        dimensions = dims
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(dimensions.sorted { $0.key < $1.key }.map { Weight(dimension: $0.key, weight: $0.value) }, forKey: .dimensions)
    }
}
```

Replace `public struct NewBead` with:

```swift
public struct NewBead: Codable, Equatable, Sendable {
    public var tempId: String
    public var title: String
    public var type: String
    public var priority: Int
    public var description: String
    public var acceptance: String?
    public var labels: [String]
    /// The kind planning classified this task as — an id in the project's kind registry.
    public var taskKind: KindID?
    /// Planning's new kind, when no listed one fits. Wins over `taskKind` when both are set.
    public var kindProposal: KindProposal?
    public init(tempId: String, title: String, type: String = "task", priority: Int = 2,
                description: String, acceptance: String? = nil, labels: [String] = [],
                taskKind: KindID? = nil, kindProposal: KindProposal? = nil) {
        self.tempId = tempId; self.title = title; self.type = type; self.priority = priority
        self.description = description; self.acceptance = acceptance; self.labels = labels
        self.taskKind = taskKind; self.kindProposal = kindProposal
    }
}
```

In `extension ChangeOp: Codable`, extend the key enum's first case line to:

```swift
        case op, tempId, title, type, priority, description, acceptance, labels, taskKind, kindProposal
```

In `init(from:)`'s `case "createBead":`, replace the `labels:` argument line with:

```swift
                labels: try c.decodeIfPresent([String].self, forKey: .labels) ?? [],
                // `""` is no kind: a model that cannot classify sometimes answers an empty string
                // rather than null, and an empty id would route as an unknown kind.
                taskKind: try c.decodeIfPresent(KindID.self, forKey: .taskKind).flatMap { $0.rawValue.isEmpty ? nil : $0 },
                kindProposal: try c.decodeIfPresent(KindProposal.self, forKey: .kindProposal)))
```

In `encode(to:)`'s `case .createBead(let b):`, after the line that encodes `acceptance` and
`labels`, add:

```swift
            try c.encodeIfPresent(b.taskKind, forKey: .taskKind)
            try c.encodeIfPresent(b.kindProposal, forKey: .kindProposal)
```

- [ ] **Step 4: Extend the op schema in `Triage.swift`**

Above `private static let op`, add:

```swift
    /// `kindProposal` (spec L3-R §4). A static literal, not built from `Dimensions.all`, so the
    /// schema stays byte-stable for `triage-schema.json`; an unknown dimension is dropped when
    /// the proposal is registered instead of rejected by the CLI.
    private static let kindProposal = #"{"type":["object","null"],"additionalProperties":false,"required":["name","description","dimensions"],"properties":{"name":{"type":"string"},"description":{"type":"string"},"dimensions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["dimension","weight"],"properties":{"dimension":{"type":"string"},"weight":{"type":"number"}}}}}}"#
```

In `op`, change the `"required"` line's tail from `"delivery","reason","of"],` to
`"delivery","reason","of","taskKind","kindProposal"],`, and replace the last property line

```
      "reason":\(nullableString),"of":\(nullableString)}}
```

with

```
      "reason":\(nullableString),"of":\(nullableString),
      "taskKind":\(nullableString),"kindProposal":\(kindProposal)}}
```

- [ ] **Step 5: Run the new tests, then see the pinned schema fixture fail**

Run: `FD_TEST_FILTER=ChangeSetKindTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 7 tests, with 0 failures`.

Run: `FD_TEST_FILTER=RoundPromptsTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: exactly one failure, `testTriageSchemaJSONUnchangedByTheRefactor` (the fixture pins the
old bytes).

- [ ] **Step 6: Regenerate the pinned schema with the same two edits**

Write this script with the Write tool to `<scratchpad>/regen_triage_schema.py` (your session's
scratchpad directory), then run `python3 <scratchpad>/regen_triage_schema.py` from the worktree root:

```python
from pathlib import Path

p = Path("Tests/FlightDeckTests/Fixtures/Intake/triage-schema.json")
s = p.read_text()
kp = ('{"type":["object","null"],"additionalProperties":false,"required":["name","description","dimensions"],'
      '"properties":{"name":{"type":"string"},"description":{"type":"string"},"dimensions":{"type":"array",'
      '"items":{"type":"object","additionalProperties":false,"required":["dimension","weight"],'
      '"properties":{"dimension":{"type":"string"},"weight":{"type":"number"}}}}}}')
required_old = '"delivery","reason","of"]'
last_old = '"of":{"type":["string","null"]}}'
assert s.count(required_old) == 1, s.count(required_old)
assert s.count(last_old) == 1, s.count(last_old)
s = s.replace(required_old, '"delivery","reason","of","taskKind","kindProposal"]')
s = s.replace(last_old, '"of":{"type":["string","null"]},\n  "taskKind":{"type":["string","null"]},"kindProposal":' + kp + '}')
p.write_text(s)
print("ok")
```

Expected output: `ok`. Then in `Tests/FlightDeckTests/Intake/RoundPromptsTests.swift`, replace the
doc comment of `testTriageSchemaJSONUnchangedByTheRefactor`:

```swift
    /// `Triage.schemaJSON` must stay byte-identical after the refactor that extracted
    /// `changeSetSchemaFragment` out of it — this compares against a copy captured from the
    /// pre-refactor source (see task-4-report.md for how it was captured).
```

with:

```swift
    /// `Triage.schemaJSON` byte for byte. Captured from the source when `changeSetSchemaFragment`
    /// was extracted (see task-4-report.md), then deliberately regenerated when L3-R added
    /// `taskKind` and `kindProposal` to the op. A change to the schema must be a change to this
    /// file too: both CLIs were probed against exactly these bytes.
```

- [ ] **Step 7: Run every schema and change-set test**

Run: `FD_TEST_FILTER=ChangeSetKindTests,RoundPromptsTests,TriageTests,ChangeSetCodingTests,ChangeSetValidatorTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add Sources/IntakeKit/ChangeSet.swift Sources/IntakeKit/Triage.swift Tests/FlightDeckTests/Fixtures/Intake/triage-schema.json Tests/FlightDeckTests/Intake/RoundPromptsTests.swift Tests/FlightDeckTests/FlightControlL3/Routing/ChangeSetKindTests.swift
git commit -m "feat: let planning classify each created task by kind or propose a new kind" -m "The op schema gains taskKind and kindProposal. Not \"kind\": the op is one flat object and \"kind\" is addEdge's edge kind, whose enum would reject every kind id. Proposal weights travel as an array because strict-mode schemas cannot describe open-keyed objects. triage-schema.json is regenerated with exactly these two edits." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Planning prompts carry the project's kinds

**Files:**
- Modify: `Sources/IntakeKit/Triage.swift` (`changeSetRulesText`, `initialPrompt`)
- Modify: `Sources/IntakeKit/RoundPrompts.swift` (`RoundContext` at :189-210; `encode`, `polish`, `freshEyes`, `dedup`)
- Modify: `Sources/IntakeKit/RoundExecutor.swift` (`context(_:graphFile:observedAt:)` at :695-706)
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/EncodePromptKindsTests.swift`

**Interfaces:**
- Consumes: Task 3 (`KindRegistryStore.promptKinds(project:)`); L3-0 `Dimensions`, `TaskKind`.
- Produces:
  - `Triage.kindsRulesText(_ kinds: [TaskKind]) -> String` (empty for no live kinds)
  - `Triage.changeSetRulesText(observedAt: Date, kinds: [TaskKind] = []) -> String`
  - `Triage.initialPrompt(…, observedAt: Date, kinds: [TaskKind] = []) -> String`
  - `RoundContext.kinds: [TaskKind]`; `RoundContext.init(…, observedAt: Date, kinds: [TaskKind] = [])`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// The encode step gets the project's kind registry — ids, descriptions, weights (spec L3-R §4) —
/// and every round that hands back a change set gets the same words, because a polish or
/// cross-check round may change a task's kind.
final class EncodePromptKindsTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)
    private var kinds: [TaskKind] { RoutingTestData.kinds }

    func testWithNoKindsTheRulesSayNothingNew() {
        let t = Triage.changeSetRulesText(observedAt: at)
        XCTAssertFalse(t.contains("taskKind"))
        XCTAssertEqual(Triage.kindsRulesText([]), "")
    }

    func testKindsAreListedWithWeightsAndHowToClassify() {
        let t = Triage.changeSetRulesText(observedAt: at, kinds: kinds)
        XCTAssertTrue(t.contains("- `snapshot-tests` — snapshot-tests: d (agentic-coding 0.3, test-authoring 0.8)"), t)
        XCTAssertTrue(t.contains("`taskKind`"))
        XCTAssertTrue(t.contains("`kindProposal`"))
        XCTAssertFalse(t.contains("`golden-tests`"), "a merged kind is not offered: classify into its target")
        for d in Dimensions.all { XCTAssertTrue(t.contains(d.id), d.id) }
    }

    func testEveryChangeSetRoundCarriesTheKinds() {
        let c = RoundContext(intent: "x", qa: [], graphFile: "/g", agentsFile: nil, readmeFile: nil, observedAt: at, kinds: kinds)
        let prompts = [RoundPrompts.encode(c, planFile: "/p.md"),
                       RoundPrompts.polish(c, planFile: "/p.md", changeSetFile: "/c.json", round: 1),
                       RoundPrompts.freshEyes(c, planFile: "/p.md", changeSetFile: "/c.json"),
                       RoundPrompts.dedup(c, changeSetFile: "/c.json")]
        for p in prompts { XCTAssertTrue(p.contains("`snapshot-tests`")) }
    }

    func testTriageAtSingleTaskFidelityCarriesTheKinds() {
        let p = Triage.initialPrompt(intent: "I", graphFile: "/g", triageFile: "/t", agentsFile: nil, readmeFile: nil,
                                     observedAt: at, kinds: kinds)
        XCTAssertTrue(p.contains("- `tests` — tests"))
    }

    func testAContextBuiltWithoutKindsHasNone() {
        XCTAssertEqual(RoundContext(intent: "x", qa: [], graphFile: "/g", agentsFile: nil, readmeFile: nil, observedAt: at).kinds, [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=EncodePromptKindsTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build errors `extra argument 'kinds' in call` / `type 'Triage' has no member 'kindsRulesText'`.

- [ ] **Step 3: Implement the kinds text in `Triage.swift`**

Change the signature `public static func changeSetRulesText(observedAt: Date) -> String {` to
`public static func changeSetRulesText(observedAt: Date, kinds: [TaskKind] = []) -> String {`, and
change its body's final line from `- \`followUp\`: \`tempId\`, \`of\`, \`title\`, \`description\`, and \`pre\`.`
followed by the closing `"""` so that the closing becomes:

```swift
        - `followUp`: `tempId`, `of`, `title`, `description`, and `pre`.
        """ + kindsRulesText(kinds)
```

Add, after `changeSetRulesText`:

```swift
    /// The project's kinds, for every round that creates tasks (spec L3-R §4). Empty when there
    /// are none, so a project without a registry gets exactly the rules it always had. Merged
    /// kinds are left out: a new task classified into one would only ever resolve to its target.
    public static func kindsRulesText(_ kinds: [TaskKind]) -> String {
        let live = kinds.filter { kind in
            if case .merged = kind.status { return false }
            return true
        }
        guard !live.isEmpty else { return "" }
        let list = live.map { k -> String in
            let weights = k.dimensions.sorted { $0.key < $1.key }.map { "\($0.key) \(RuleText.number($0.value))" }
            return "- `\(k.id.rawValue)` — \(k.name): \(k.description) (\(weights.joined(separator: ", ")))"
        }.joined(separator: "\n")
        let dimensions = Dimensions.all.map(\.id).joined(separator: ", ")
        return """


        Task kinds. Classify every task a `createBead` op creates:
        - Set `taskKind` to the id of the kind below that fits it best.
        - When none fits, set `taskKind` to null and fill `kindProposal`: a short `name`, a \
        one-line `description`, and `dimensions` as `[{"dimension": <id>, "weight": 0 to 1}]` over \
        these dimensions: \(dimensions).
        - Every other op sets both `taskKind` and `kindProposal` to null.
        \(list)
        """
    }
```

Change `initialPrompt`'s signature to add `kinds: [TaskKind] = []` after `observedAt: Date`, and
its `\(changeSetRulesText(observedAt: observedAt))` line to
`\(changeSetRulesText(observedAt: observedAt, kinds: kinds))`.

- [ ] **Step 4: Carry kinds through `RoundContext` and the four change-set prompts**

In `RoundPrompts.swift`'s `RoundContext`, add after `public var observedAt: Date`:

```swift
    /// The project's task kinds, offered to every round that creates tasks (spec L3-R §4).
    public var kinds: [TaskKind]
```

change the initializer's last parameter line to
`readmeFile: String?, notes: [PlanNote] = [], humanEdits: String? = nil, observedAt: Date, kinds: [TaskKind] = []) {`
and add `self.kinds = kinds` after `self.observedAt = observedAt`.

In `encode`, `polish`, `freshEyes` and `dedup`, replace
`\(Triage.changeSetRulesText(observedAt: c.observedAt))` with
`\(Triage.changeSetRulesText(observedAt: c.observedAt, kinds: c.kinds))` (four occurrences; check
with `rg -n "changeSetRulesText\(observedAt: c.observedAt\)" Sources/IntakeKit/RoundPrompts.swift`
before — expect 4 — and after — expect 0).

- [ ] **Step 5: Read the project's kinds into each round**

In `RoundExecutor.swift`'s `context(_:graphFile:observedAt:)`, change the final argument
`observedAt: observedAt)` to:

```swift
                            observedAt: observedAt,
                            // Read fresh every round, like AGENTS.md: a kind proposed and released
                            // by another intake is offered to this one's next round.
                            kinds: KindRegistryStore.promptKinds(project: inputs.project))
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=EncodePromptKindsTests,RoundPromptsTests,TriageTests,RoundExecutorTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/IntakeKit/Triage.swift Sources/IntakeKit/RoundPrompts.swift Sources/IntakeKit/RoundExecutor.swift Tests/FlightDeckTests/FlightControlL3/Routing/EncodePromptKindsTests.swift
git commit -m "feat: tell every task-creating planning round the project's task kinds" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Encode-time routing — classify, propose, route

**Files:**
- Create: `Sources/IntakeKit/FlightControl/EncodeRouting.swift`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/encode-with-kinds.json`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/EncodeRoutingTests.swift`

**Interfaces:**
- Consumes: Tasks 3, 5, 10; L3-0 `Router`, `KindRegistry`, `ExecutionBlockCodec`, `SeedKinds`, `KindID.normalized`, `Dimensions`; IntakeKit `ApplyStep`, `ApplyPlanner`, `ChangeSetValidator`, `RoundPrompts.decode`, `ChangeSetOutput`, `GraphSnapshot`.
- Produces:
  - `public enum EncodeRouting { static let fallbackKind: KindID; struct Outcome { contexts: [String: String]; blocks: [String: ExecutionBlock]; unroutable: [String: String]; proposed: [KindID] }; static func route(_ steps: [ApplyStep], project: URL, registry: any KindRegistry, router: any Router, catalogs: AdapterCatalogs, now: Date) -> Outcome }`
  - Test support: `extension RoutingFixtures { static func encodeSteps() throws -> [ApplyStep] }`

- [ ] **Step 1: Write the fixture**

`Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/encode-with-kinds.json` — an encode
round's `{"changeSet", "summary"}` in the strict shape (one existing kind, one proposal, one
unclassified task, one edge):

```json
{"changeSet":{"graphObservedAt":"2026-10-04T18:00:00Z","ops":[
 {"op":"createBead","tempId":"n1","title":"Unit tests for the parser","type":"task","priority":2,"description":"Cover the tokenizer edge cases","acceptance":"All parser tests pass","labels":[],"from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null,"taskKind":"tests","kindProposal":null},
 {"op":"createBead","tempId":"n2","title":"Snapshot tests for the renderer","type":"task","priority":2,"description":"Golden-file tests for every view","acceptance":null,"labels":[],"from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null,"taskKind":null,"kindProposal":{"name":"Snapshot Tests","description":"Write or update snapshot/golden-file tests","dimensions":[{"dimension":"test-authoring","weight":0.8},{"dimension":"agentic-coding","weight":0.3}]}},
 {"op":"createBead","tempId":"n3","title":"Wire the settings toggle","type":"task","priority":3,"description":"Add the toggle","acceptance":null,"labels":[],"from":null,"to":null,"kind":null,"id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null,"taskKind":null,"kindProposal":null},
 {"op":"addEdge","tempId":null,"title":null,"type":null,"priority":null,"description":null,"acceptance":null,"labels":null,"from":"new:n2","to":"new:n1","kind":"blocks","id":null,"set":null,"pre":null,"delivery":null,"reason":null,"of":null,"taskKind":null,"kindProposal":null}]},
 "summary":"three tasks"}
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit

extension RoutingFixtures {
    /// The fixture encode output, validated and planned exactly as release does.
    static func encodeSteps() throws -> [ApplyStep] {
        let out = try RoundPrompts.decode(ChangeSetOutput.self, data("encode-with-kinds.json"))
        let validated = try ChangeSetValidator.validate(out.changeSet, against: GraphSnapshot()).get()
        return ApplyPlanner.plan(validated, skipping: [])
    }
}

/// Spec L3-R §9 "Encode": a recorded-shape encode output with a kind and a kind proposal; assert
/// the registry write and the block each create will carry (the argv half is in
/// `BeadWriterBlockTests.testTheEncodeOutputLandsAsAgentContextArgv`).
final class EncodeRoutingTests: XCTestCase {
    private typealias D = RoutingTestData
    private var project: URL!

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("EncodeRoutingTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private var registry: KindRegistryStore { KindRegistryStore(now: { RoutingTestData.at }) }

    private func router(_ global: [RoutingRule] = [RoutingTestData.r3(pool: "codex-default")]) -> RuleRouter {
        RuleRouter(rules: StaticRuleSource(global: global), kinds: registry, index: NullCapabilityIndex(),
                   pools: DefaultPoolDirectory(harnesses: ["codex", "claude"]), defaultHarness: { _ in "claude" })
    }

    private func route(_ steps: [ApplyStep], catalogs: AdapterCatalogs = RoutingTestData.catalogs) -> EncodeRouting.Outcome {
        EncodeRouting.route(steps, project: project, registry: registry, router: router(), catalogs: catalogs, now: D.at)
    }

    private func create(_ bead: NewBead) -> [ApplyStep] { [.create(bead)] }

    func testTheEncodeOutputClassifiesProposesAndRoutes() throws {
        let out = route(try RoutingFixtures.encodeSteps())

        let kinds = try KindRegistryStore().kinds(project: project)
        let snapshot = try XCTUnwrap(kinds.first { $0.id == "snapshot-tests" })
        XCTAssertEqual(snapshot.origin, .planning)
        XCTAssertEqual(snapshot.status, .active)
        XCTAssertEqual(snapshot.dimensions, ["test-authoring": 0.8, "agentic-coding": 0.3])
        XCTAssertEqual(out.proposed, ["snapshot-tests"])

        let n1 = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: out.contexts["n1"]).get())
        XCTAssertEqual(n1.kind, "tests"); XCTAssertEqual(n1.harness, "codex"); XCTAssertEqual(n1.source.ruleId, "r3")

        let n2 = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: out.contexts["n2"]).get())
        XCTAssertEqual(n2.kind, "snapshot-tests"); XCTAssertEqual(n2.model, "gpt-6-sol")
        XCTAssertEqual(n2.knobs, ["effort": "high"], "the proposal routes by the same rule, no recompile")

        let n3 = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: out.contexts["n3"]).get())
        XCTAssertEqual(n3.kind, "implement-simple"); XCTAssertEqual(n3.harness, "claude"); XCTAssertEqual(n3.source.by, .default)
        XCTAssertTrue(n3.source.reason.hasPrefix("no kind from planning; "), n3.source.reason)

        XCTAssertEqual(Set(out.contexts.keys), ["n1", "n2", "n3"])
        XCTAssertEqual(out.unroutable, [:])
    }

    func testAProposalNamedLikeAnExistingKindReusesIt() throws {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d",
                                       kindProposal: KindProposal(name: "TESTS!!", description: "x", dimensions: ["docs-prose": 0.9]))))
        XCTAssertEqual(out.proposed, [])
        XCTAssertEqual(out.blocks["n1"]?.kind, "tests")
        XCTAssertFalse(FileManager.default.fileExists(atPath: KindRegistryStore.fileURL(project: project).path),
                       "reusing a seed kind writes nothing")
    }

    func testProposalNamedOnlyPunctuationFallsBackAndWritesNothing() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d",
                                       kindProposal: KindProposal(name: "!!!", description: "x", dimensions: ["test-authoring": 0.9]))))
        XCTAssertEqual(out.blocks["n1"]?.kind, EncodeRouting.fallbackKind)
        XCTAssertFalse(FileManager.default.fileExists(atPath: KindRegistryStore.fileURL(project: project).path))
        XCTAssertEqual(out.proposed, [])
    }

    func testAnUnknownKindIdFallsBack() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d", taskKind: "astrology")))
        XCTAssertEqual(out.blocks["n1"]?.kind, "implement-simple")
        XCTAssertTrue(out.blocks["n1"]?.source.reason.hasPrefix("no kind from planning; ") == true)
    }

    func testAKindIdIsNormalizedBeforeLookup() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d", taskKind: "Tests")))
        XCTAssertEqual(out.blocks["n1"]?.kind, "tests")
    }

    func testAProposalDropsUnknownDimensionsAndClampsWeights() throws {
        _ = route(create(NewBead(tempId: "n1", title: "T", description: "d",
                                 kindProposal: KindProposal(name: "Fuzzing", description: "x",
                                                            dimensions: ["test-authoring": 1.4, "vibes": 0.5]))))
        let fuzz = try XCTUnwrap(try KindRegistryStore().kinds(project: project).first { $0.id == "fuzzing" })
        XCTAssertEqual(fuzz.dimensions, ["test-authoring": 1.0])
    }

    func testAnUnroutableTaskGetsNoContext() {
        let out = route(create(NewBead(tempId: "n1", title: "T", description: "d", taskKind: "tests")),
                        catalogs: D.catalogsDisabling(["codex", "claude"]))
        XCTAssertEqual(out.contexts, [:])
        XCTAssertTrue(out.unroutable["n1"]?.hasPrefix("unroutable: ") == true)
    }

    func testOnlyCreatesAreRouted() {
        let out = route([.update(id: "b1", set: FieldSet(title: "x")), .reopen(id: "b2", reason: "r")])
        XCTAssertEqual(out, EncodeRouting.Outcome())
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=EncodeRoutingTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'EncodeRouting' in scope`.

- [ ] **Step 4: Implement `EncodeRouting.swift`**

```swift
import Foundation

/// Encode-time classification and routing (spec L3-R §4). Every task a release creates gets a
/// kind — the one planning named, or its proposal, registered as `origin: planning` and usable at
/// once — and the router's block, as the `agent_context` its `br create` writes.
public enum EncodeRouting {
    /// What an unclassified create routes as (deviation 7). Failing validation instead would
    /// break every intake already in review when L3-R ships.
    public static let fallbackKind: KindID = "implement-simple"

    public struct Outcome: Equatable, Sendable {
        /// Temp id → the whole `agent_context` JSON for `br create --agent-context`.
        public var contexts: [String: String] = [:]
        public var blocks: [String: ExecutionBlock] = [:]
        /// Temp id → why it has no block. Such a task is written without one; the launch-time
        /// re-route (L3-S) tries again, and the swarm skips it until something routes it.
        public var unroutable: [String: String] = [:]
        /// Kinds this release added to the registry.
        public var proposed: [KindID] = []
        public init() {}
    }

    public static func route(_ steps: [ApplyStep], project: URL, registry: any KindRegistry, router: any Router,
                             catalogs: AdapterCatalogs, now: Date) -> Outcome {
        var outcome = Outcome()
        for step in steps {
            guard case .create(let bead) = step else { continue }
            let (kind, classified) = classify(bead, project: project, registry: registry, now: now, proposed: &outcome.proposed)
            var block = router.assign(kind: kind, project: project, catalogs: catalogs, now: now).block
            // `RuleRouter` reports an unroutable task as a block with an empty model (deviation 5).
            guard !block.model.isEmpty else {
                outcome.unroutable[bead.tempId] = block.source.reason
                continue
            }
            if !classified { block.source.reason = "no kind from planning; " + block.source.reason }
            guard let json = try? ExecutionBlockCodec.encode(block, into: nil) else { continue }
            outcome.blocks[bead.tempId] = block
            outcome.contexts[bead.tempId] = json
        }
        return outcome
    }

    /// The task's kind, and whether planning classified it. A proposal wins over an id; a
    /// proposal whose name normalizes to nothing, an unknown id, or nothing at all is the fallback.
    static func classify(_ bead: NewBead, project: URL, registry: any KindRegistry, now: Date,
                         proposed: inout [KindID]) -> (TaskKind, Bool) {
        let known = (try? registry.kinds(project: project)) ?? SeedKinds.all(createdAt: now)
        if let p = bead.kindProposal {
            let id = KindID.normalized(p.name)
            if !id.rawValue.isEmpty {
                // Unknown dimensions are dropped and weights clamped rather than the proposal
                // refused: the agent's classification is still the best signal this task has.
                let dims = p.dimensions.filter { Dimensions.isKnown($0.key) }.mapValues { min(max($0, 0), 1) }
                let candidate = TaskKind(id: id, name: p.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                         description: p.description, dimensions: dims, origin: .planning,
                                         status: .active, createdAt: now)
                if let added = try? registry.propose(candidate, project: project) {
                    if !known.contains(where: { $0.id == added.id }), !proposed.contains(added.id) { proposed.append(added.id) }
                    return (added, true)
                }
            }
        }
        if let id = bead.taskKind,
           let k = known.first(where: { $0.id == id }) ?? known.first(where: { $0.id == KindID.normalized(id.rawValue) }) {
            return (k, true)
        }
        let fallback = known.first { $0.id == fallbackKind }
            ?? SeedKinds.all(createdAt: now).first { $0.id == fallbackKind }
            ?? TaskKind(id: fallbackKind, name: "Simple implementation", description: "Small, well-specified code changes",
                        dimensions: [:], origin: .seed, createdAt: now)
        return (fallback, false)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=EncodeRoutingTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/IntakeKit/FlightControl/EncodeRouting.swift Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/encode-with-kinds.json Tests/FlightDeckTests/FlightControlL3/Routing/EncodeRoutingTests.swift
git commit -m "feat: classify, register and route every task a release creates" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: `BeadWriter` writes the block — on create, and on re-route

**Files:**
- Modify: `Sources/FlightDeck/Intake/BeadWriter.swift` (`apply` at :41, `run` at :63, the `.create` arm at :66-84; new `BlockWriting` extension at the end)
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/BeadWriterBlockTests.swift`

**Interfaces:**
- Consumes: Task 12; L3-0 `ExecutionBlockCodec`, `ExecutionBlockError`; test double `RecordingRunner` (`Tests/FlightDeckTests/Intake/BeadWriterTests.swift:9`, keyed `"<exe> <arg0>"`).
- Produces:
  - `BeadWriter.apply(_ steps: [ApplyStep], project: String, agentContexts: [String: String] = [:]) async -> Outcome`
  - `enum BlockWriteOutcome: Equatable, Sendable { written, skippedPinned, failed(String) }`
  - `protocol BlockWriting: Sendable { func writeBlock(_ block: ExecutionBlock, id: String, project: String) async -> BlockWriteOutcome }`
  - `extension BeadWriter: BlockWriting`; `static func shrinksBelowHalf(old: String?, new: String) -> Bool`

Probed on br 0.6.0 while planning: `br create --agent-context <json>` stores the JSON;
`br show <id> --json` returns a one-element array whose row has `agent_context`; `br update <id>
--agent-context <json>` exits 4 with `VALIDATION_FAILED … keeps less than half its length …
without --force` when the new value is under half the old length.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The block reaches br two ways: whole, on `br create`, and merged into whatever `agent_context`
/// already holds, on a re-route. Other keys are br's governing instructions and must survive
/// (L3-0 §4); a pinned block is never touched; and br's own shrink guard must not make a
/// re-route fail silently.
@MainActor
final class BeadWriterBlockTests: XCTestCase {
    private typealias D = RoutingTestData

    private func block(model: String = "gpt-6-sol", reason: String = "test-authoring 0.8 → codex",
                       pinned: Bool = false) -> ExecutionBlock {
        ExecutionBlock(kind: "snapshot-tests", harness: "codex", model: model, knobs: ["effort": "high"], pool: "codex-default",
                       source: AssignmentSource(by: .rule, ruleId: "r3", reason: reason, at: D.at), pinned: pinned)
    }

    private func show(_ context: String?) throws -> String {
        var row: [String: Any] = ["id": "b1", "title": "T", "status": "open"]
        if let context { row["agent_context"] = context }
        return String(decoding: try JSONSerialization.data(withJSONObject: [row]), as: UTF8.self)
    }

    private func argument(_ flag: String, in call: [String]) -> String? {
        call.firstIndex(of: flag).map { call[$0 + 1] }
    }

    func testACreateCarriesItsRoutedContext() async throws {
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)])
        let ctx = try ExecutionBlockCodec.encode(block(), into: nil)
        let out = await BeadWriter(runner: r, brPath: "br", actor: "a")
            .apply([.create(NewBead(tempId: "n1", title: "T", description: "d"))], project: "/p", agentContexts: ["n1": ctx])
        XCTAssertNil(out.error)
        let create = try XCTUnwrap(r.calls.first)
        XCTAssertEqual(argument("--agent-context", in: create), ctx)
        XCTAssertLessThan(try XCTUnwrap(create.firstIndex(of: "--agent-context")), try XCTUnwrap(create.firstIndex(of: "--actor")))
    }

    func testACreateWithoutAContextIsUnchanged() async {
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)])
        _ = await BeadWriter(runner: r, brPath: "br", actor: "a")
            .apply([.create(NewBead(tempId: "n1", title: "T", description: "d"))], project: "/p")
        XCTAssertEqual(r.calls.first, ["br", "create", "--title", "T", "-t", "task", "-p", "2", "--description", "d",
                                       "--actor", "a", "--json"])
    }

    func testWriteBlockMergesIntoTheExistingContext() async throws {
        let old = try ExecutionBlockCodec.encode(block(model: "gpt-6-luna"),
                                                 into: #"{"instructions":"keep me","flight_deck":{"notes":"keep"}}"#)
        let r = RecordingRunner(replies: ["br show": (try show(old), 0), "br update": ("", 0)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "flightdeck-routing").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertEqual(result, .written)
        let update = try XCTUnwrap(r.calls.last)
        XCTAssertEqual(Array(update.prefix(3)), ["br", "update", "b1"])
        let written = try XCTUnwrap(argument("--agent-context", in: update))
        XCTAssertEqual(try ExecutionBlockCodec.decode(agentContext: written).get()?.model, "gpt-6-sol")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(written.utf8)) as? [String: Any])
        XCTAssertEqual(obj["instructions"] as? String, "keep me")
        XCTAssertEqual((obj["flight_deck"] as? [String: Any])?["notes"] as? String, "keep")
        XCTAssertEqual(argument("--actor", in: update), "flightdeck-routing")
        XCTAssertFalse(update.contains("--force"))
    }

    func testWriteBlockLeavesAPinnedBlockAlone() async throws {
        let r = RecordingRunner(replies: ["br show": (try show(try ExecutionBlockCodec.encode(block(pinned: true), into: nil)), 0)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(model: "gpt-6-luna"), id: "b1", project: "/p")
        XCTAssertEqual(result, .skippedPinned)
        XCTAssertEqual(r.calls.count, 1, "no update after reading a pinned block")
    }

    func testWriteBlockForcesOnlyWhenTheContextShrinksBelowHalf() async throws {
        let long = try ExecutionBlockCodec.encode(block(reason: String(repeating: "a very long reason ", count: 40)), into: nil)
        let r = RecordingRunner(replies: ["br show": (try show(long), 0), "br update": ("", 0)])
        _ = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertTrue(try XCTUnwrap(r.calls.last).contains("--force"), "br refuses a write under half the old length without it")

        let same = try ExecutionBlockCodec.encode(block(model: "gpt-6-luna"), into: nil)
        let r2 = RecordingRunner(replies: ["br show": (try show(same), 0), "br update": ("", 0)])
        _ = await BeadWriter(runner: r2, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertFalse(try XCTUnwrap(r2.calls.last).contains("--force"), "--force also bypasses br's blocked-task guard; only when needed")

        XCTAssertTrue(BeadWriter.shrinksBelowHalf(old: "1234567890", new: "1234"))
        XCTAssertFalse(BeadWriter.shrinksBelowHalf(old: "12345678", new: "1234"), "exactly half passes br's guard")
        XCTAssertFalse(BeadWriter.shrinksBelowHalf(old: nil, new: "x"))
    }

    func testWriteBlockRefusesAContextThatIsNotAnObject() async throws {
        let r = RecordingRunner(replies: ["br show": (try show(#""a bare string""#), 0)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertEqual(result, .failed("route b1: agent_context is not a JSON object"))
        XCTAssertEqual(r.calls.count, 1)
    }

    func testWriteBlockRefusesABlockFromANewerFlightDeck() async throws {
        let r = RecordingRunner(replies: ["br show": (try show(#"{"flight_deck":{"execution":{"v":2}}}"#), 0)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertEqual(result, .failed("route b1: written by a newer Flight Deck (v2)"))
    }

    func testAShowFailureIsReported() async {
        let r = RecordingRunner(replies: ["br show": ("database is locked", 1)])
        let result = await BeadWriter(runner: r, brPath: "br", actor: "a").writeBlock(block(), id: "b1", project: "/p")
        XCTAssertEqual(result, .failed("route b1: exit 1: database is locked"))
    }

    func testTheEncodeOutputLandsAsAgentContextArgv() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BeadWriterBlockTests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let steps = try RoutingFixtures.encodeSteps()
        let router = RuleRouter(rules: StaticRuleSource(global: [D.r3(pool: "codex-default")]), kinds: KindRegistryStore(),
                                index: NullCapabilityIndex(), pools: DefaultPoolDirectory(harnesses: ["codex", "claude"]),
                                defaultHarness: { _ in "claude" })
        let routed = EncodeRouting.route(steps, project: dir, registry: KindRegistryStore(), router: router, catalogs: D.catalogs, now: D.at)
        let r = RecordingRunner(replies: ["br create": (#"{"id":"b9"}"#, 0), "br dep": ("", 0), "br sync": ("", 0)])
        let out = await BeadWriter(runner: r, brPath: "br", actor: "a").apply(steps, project: dir.path, agentContexts: routed.contexts)
        XCTAssertNil(out.error)
        let creates = r.calls.filter { $0.prefix(2) == ["br", "create"] }
        XCTAssertEqual(creates.count, 3)
        XCTAssertTrue(creates.allSatisfy { $0.contains("--agent-context") })
        let renderer = try XCTUnwrap(creates.first { $0.contains("Snapshot tests for the renderer") })
        let written = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: argument("--agent-context", in: renderer)).get())
        XCTAssertEqual(written.kind, "snapshot-tests")
        XCTAssertEqual(written.harness, "codex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: KindRegistryStore.fileURL(project: dir).path),
                      "the proposal reached the project's kinds.json")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=BeadWriterBlockTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build errors `extra argument 'agentContexts' in call` and `value of type 'BeadWriter' has no member 'writeBlock'`.

- [ ] **Step 3: Pass contexts through `apply` to the create step**

In `BeadWriter.swift`:
- `func apply(_ steps: [ApplyStep], project: String) async -> Outcome {` →
  `func apply(_ steps: [ApplyStep], project: String, agentContexts: [String: String] = [:]) async -> Outcome {`
- `switch await run(step, idMap: outcome.idMap, project: project) {` →
  `switch await run(step, idMap: outcome.idMap, project: project, agentContexts: agentContexts) {`
- `private func run(_ step: ApplyStep, idMap: [String: String], project: String) async -> StepOutcome {` →
  `private func run(_ step: ApplyStep, idMap: [String: String], project: String, agentContexts: [String: String]) async -> StepOutcome {`
- In the `.create` arm, after `if !bead.labels.isEmpty { args += ["-l", bead.labels.joined(separator: ",")] }`, add:

```swift
            // L3-R §4: the routed execution block. A new task has no other `agent_context` to
            // keep, so this is the whole value (`ExecutionBlockCodec.encode(_, into: nil)`).
            if let context = agentContexts[bead.tempId] { args += ["--agent-context", context] }
```

- [ ] **Step 4: Add `writeBlock` at the end of `BeadWriter.swift`**

```swift
/// What `writeBlock` did to one task.
enum BlockWriteOutcome: Equatable, Sendable {
    case written
    case skippedPinned
    case failed(String)
}

/// Writes one task's execution block after a re-route (spec L3-R §5: "when a kind is merged or
/// re-weighted"). A protocol so `RoutingService`'s tests never run `br`.
protocol BlockWriting: Sendable {
    func writeBlock(_ block: ExecutionBlock, id: String, project: String) async -> BlockWriteOutcome
}

extension BeadWriter: BlockWriting {
    /// Reads the task's `agent_context`, replaces only `flight_deck.execution`, writes the whole
    /// value back. Never over a pinned block, a newer block, an invalid block or a context that
    /// is not a JSON object: each of those belongs to someone else, and is reported instead.
    func writeBlock(_ block: ExecutionBlock, id: String, project: String) async -> BlockWriteOutcome {
        let description = "route \(id)"
        let existing: String?
        switch await exec(["show", id, "--json"], description: description, project: project) {
        case .failure(let error):
            return .failed(error.message)
        case .success(let stdout):
            guard let data = stdout.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let row = rows.first else {
                return .failed("\(description): task not found: \(stdout.firstLine)")
            }
            existing = row["agent_context"] as? String
        }
        switch ExecutionBlockCodec.decode(agentContext: existing) {
        case .success(let old?) where old.pinned: return .skippedPinned
        case .failure(let error): return .failed("\(description): \(error.message)")
        default: break
        }
        let merged: String
        do { merged = try ExecutionBlockCodec.encode(block, into: existing) }
        catch let error as ExecutionBlockError { return .failed("\(description): \(error.message)") }
        catch { return .failed("\(description): \(error)") }
        var args = ["update", id, "--agent-context", merged]
        // br 0.6.0 refuses a write that keeps less than half the old length (exit 4) unless
        // forced — a shorter reason would otherwise make the re-route fail. Only then: `--force`
        // also bypasses br's blocked-task guard, which this write has no business overriding.
        if Self.shrinksBelowHalf(old: existing, new: merged) { args.append("--force") }
        args += ["--actor", actor]
        switch await exec(args, description: description, project: project) {
        case .failure(let error): return .failed(error.message)
        case .success: return .written
        }
    }

    /// Both measures, because br counts characters and an emoji-heavy reason makes the two disagree.
    static func shrinksBelowHalf(old: String?, new: String) -> Bool {
        guard let old, !old.isEmpty else { return false }
        return new.count * 2 < old.count || new.utf8.count * 2 < old.utf8.count
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=BeadWriterBlockTests,BeadWriterTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures` (9 new tests plus the existing `BeadWriterTests`).

- [ ] **Step 6: Confirm the shadow graph needs no change**

Run: `rg -n '"create", "--title"' Sources/IntakeKit/ShadowGraph.swift`
Expected: one match (`ShadowGraph.create`, ~line 193). Leave it: the shadow graph is a scratch copy
for `bv` analytics during polish rounds, never launched from, so a block there would only be
noise. Say so in the task report.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Intake/BeadWriter.swift Tests/FlightDeckTests/FlightControlL3/Routing/BeadWriterBlockTests.swift
git commit -m "feat: write each task's execution block into agent_context, merging on re-route" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: Intake release asks for routed contexts; triage hears the kinds

**Files:**
- Create: `Sources/FlightDeck/FlightControl/EncodeRoutingProviding.swift`
- Modify: `Sources/FlightDeck/Intake/IntakeService.swift` (stored property block near :200-320; `runRelease` at :1405-1407; `initialPrompt(_:files:observedAt:)` at :1745-1752)
- Modify: `Tests/FlightDeckTests/Intake/IntakeServiceTests.swift` (append at the end of the file)

**Interfaces:**
- Consumes: Task 13 (`apply(_:project:agentContexts:)`), Task 3 (`promptKinds`), Task 11 (`initialPrompt(…kinds:)`).
- Produces:
  - `@MainActor protocol EncodeRoutingProviding: AnyObject { func agentContexts(for steps: [ApplyStep], project: String) async -> [String: String] }`
  - `IntakeService.encodeRouting: () -> (any EncodeRoutingProviding)?` (default `{ nil }`)

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/Intake/IntakeServiceTests.swift` (same file, so the existing
private helpers `makeService`, `capture`, `intake`, `MutableRunner`, `FakeHeadlessRunner` are in
reach):

```swift
@MainActor
private final class FakeEncodeRouting: EncodeRoutingProviding {
    var contexts: [String: String] = [:]
    private(set) var calls: [(steps: [ApplyStep], project: String)] = []
    func agentContexts(for steps: [ApplyStep], project: String) async -> [String: String] {
        calls.append((steps, project))
        return contexts
    }
}

/// L3-R §4: release asks routing for each created task's block and hands it to the writer, and
/// triage — which encodes at single-task fidelity — is told the project's kinds.
extension IntakeServiceTests {
    func testReleaseWritesTheRoutedAgentContextOnCreate() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph).merging(
            ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)]) { $1 })
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.createOp))]), br: br)
        let routing = FakeEncodeRouting()
        routing.contexts = ["n1": #"{"flight_deck":{"execution":{"v":1}}}"#]
        svc.encodeRouting = { routing }
        let id = await capture(svc)
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .released)
        XCTAssertEqual(routing.calls.first?.project, "/p")
        let create = br.calls.first { $0.prefix(2) == ["br", "create"] }!
        XCTAssertEqual(create[create.firstIndex(of: "--agent-context")! + 1], #"{"flight_deck":{"execution":{"v":1}}}"#)
    }

    func testReleaseWithoutRoutingWritesNoAgentContext() async {
        let br = MutableRunner(Self.brReplies(Self.openGraph).merging(
            ["br create": (#"{"id":"b9"}"#, 0), "br sync": ("", 0)]) { $1 })
        let svc = makeService(headless: FakeHeadlessRunner([Self.codex(Self.beadRec(Self.createOp))]), br: br)
        let id = await capture(svc)
        await svc.release(id)
        XCTAssertEqual(intake(svc, id).state, .released)
        XCTAssertFalse(br.calls.first { $0.prefix(2) == ["br", "create"] }!.contains("--agent-context"))
    }

    func testTriageIsToldTheProjectsKinds() async {
        let headless = FakeHeadlessRunner([Self.codex(Self.questions)])
        let svc = makeService(headless: headless, br: MutableRunner(Self.brReplies(Self.openGraph)))
        _ = await capture(svc)
        let prompt = headless.commands.first?.arguments.last ?? ""
        XCTAssertTrue(prompt.contains("- `implement-simple` — "), "a project with no kinds.json is offered the seed set")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=IntakeServiceTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find type 'EncodeRoutingProviding' in scope`.

- [ ] **Step 3: Add the seam**

`Sources/FlightDeck/FlightControl/EncodeRoutingProviding.swift`:

```swift
import Foundation
import IntakeKit

/// What intake release asks for before it writes tasks: each created task's routed
/// `agent_context`, keyed by temp id (spec L3-R §4). `RoutingService` conforms. A host with no
/// routing — every store a test builds — releases exactly as before Level 3.
@MainActor
protocol EncodeRoutingProviding: AnyObject {
    func agentContexts(for steps: [ApplyStep], project: String) async -> [String: String]
}
```

In `IntakeService`, after the `private let announce: (String) -> Void` property, add:

```swift
    /// L3-R: who routes the tasks a release creates. Resolved at release time rather than passed
    /// to `init`: `SessionStore` builds this service lazily, and its routing is attached by
    /// `FlightDeckApp` after the store exists. nil releases tasks with no block; the launch-time
    /// re-route (L3-S) routes them then.
    var encodeRouting: () -> (any EncodeRoutingProviding)? = { nil }
```

In `runRelease`, replace:

```swift
        let steps = ApplyPlanner.plan(validated, skipping: [])
        let outcome = await BeadWriter(runner: processRunner, brPath: brPath, actor: actor)
            .apply(steps, project: i.projectPath)
```

with:

```swift
        let steps = ApplyPlanner.plan(validated, skipping: [])
        // Routed before the first write, so a create lands with its block in one `br create`
        // instead of a create plus an update that a failure between them could split.
        let contexts = await encodeRouting()?.agentContexts(for: steps, project: i.projectPath) ?? [:]
        let outcome = await BeadWriter(runner: processRunner, brPath: brPath, actor: actor)
            .apply(steps, project: i.projectPath, agentContexts: contexts)
```

In `initialPrompt(_:files:observedAt:)`, replace
`agentsFile: existing("AGENTS.md"), readmeFile: existing("README.md"), observedAt: observedAt)` with:

```swift
            agentsFile: existing("AGENTS.md"), readmeFile: existing("README.md"), observedAt: observedAt,
            kinds: KindRegistryStore.promptKinds(project: URL(fileURLWithPath: i.projectPath, isDirectory: true)))
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=IntakeServiceTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures` (the three new tests plus the existing class).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightControl/EncodeRoutingProviding.swift Sources/FlightDeck/Intake/IntakeService.swift Tests/FlightDeckTests/Intake/IntakeServiceTests.swift
git commit -m "feat: route the tasks a release creates before writing them, and tell triage the kinds" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 15: Re-route planning and the open-task reader

**Files:**
- Create: `Sources/IntakeKit/FlightControl/KindReroute.swift`
- Create: `Sources/FlightDeck/FlightControl/OpenTaskReader.swift`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/br-list-open.json`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/KindRerouteTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/OpenTaskReaderTests.swift`

**Interfaces:**
- Consumes: Tasks 4–5 (`KindChain`); L3-0 `Router`, `ExecutionBlockCodec`, fixture loader `L3Fixtures`, fake `FakeRouter`; app `FlywheelProcessRunner`, `SystemFlywheelProcessRunner`, `String.firstLine`.
- Produces:
  - `public struct TaskContextRow: Equatable, Sendable { id: String; agentContext: String?; static func parse(brList: Data) throws -> [TaskContextRow] }`, `public struct TaskListUnreadable: Error`
  - `public enum KindReroute { struct Change { id; block }; struct Plan { changes; skippedPinned; unroutable; invalid }; static func plan(rows:affected:project:kinds:router:catalogs:now:) -> Plan }`
  - `struct OpenTaskReadError: Error, Equatable, Sendable { let message: String }`
  - `protocol OpenTaskReading: Sendable { func openTasks(project: String) async -> Result<[TaskContextRow], OpenTaskReadError> }`
  - `struct BrOpenTaskReader: OpenTaskReading { init(runner:brPath:) }`

Probed on br 0.6.0 while planning: `br list --json` (and `--status open --json`) prints an
envelope `{"issues": [...], "total": N, "limit": 0, "offset": 0, "has_more": false}`, not a bare
array; each issue carries `agent_context` as a string when set. L3-0's shared fixture
`br-list-with-blocks.json` is a bare array, so the parser accepts both.

- [ ] **Step 1: Write the fixture**

`Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/br-list-open.json` (the probed envelope):

```json
{"issues":[{"id":"fx-a","title":"Snapshot tests","status":"open","priority":2,"issue_type":"task","created_at":"2026-10-05T01:06:15.371109Z","created_by":"fixture","updated_at":"2026-10-05T01:06:15.371109Z","agent_context":"{\"flight_deck\":{\"execution\":{\"harness\":\"claude\",\"kind\":\"snapshot-tests\",\"knobs\":{},\"model\":\"opus\",\"pinned\":false,\"pool\":\"claude-default\",\"source\":{\"at\":\"2026-10-04T18:00:00Z\",\"by\":\"default\",\"reason\":\"r\"},\"v\":1}},\"instructions\":\"keep\"}","compaction_level":0,"original_size":0,"dependency_count":0,"dependent_count":0},{"id":"fx-b","title":"No block yet","status":"open","priority":3,"issue_type":"task","created_at":"2026-10-05T01:06:15.371109Z","created_by":"fixture","updated_at":"2026-10-05T01:06:15.371109Z","compaction_level":0,"original_size":0,"dependency_count":0,"dependent_count":0}],"total":2,"limit":0,"offset":0,"has_more":false}
```

- [ ] **Step 2: Write the failing tests**

`KindRerouteTests.swift`:

```swift
import XCTest
import IntakeKit

/// When a kind is merged or re-weighted, its open, unpinned tasks are re-routed (spec L3-R §5).
/// The plan is pure; the router is L3-0's `FakeRouter`, so these pin only what gets re-routed.
final class KindRerouteTests: XCTestCase {
    private typealias D = RoutingTestData
    private let project = URL(fileURLWithPath: "/w/project", isDirectory: true)

    private func row(_ id: String, kind: KindID, harness: HarnessID = "claude", model: String = "opus",
                     knobs: [String: String] = [:], pool: PoolID = "claude-default", pinned: Bool = false) throws -> TaskContextRow {
        let b = ExecutionBlock(kind: kind, harness: harness, model: model, knobs: knobs, pool: pool,
                               source: AssignmentSource(by: .default, reason: "r", at: D.at), pinned: pinned)
        return TaskContextRow(id: id, agentContext: try ExecutionBlockCodec.encode(b, into: #"{"instructions":"keep"}"#))
    }

    private func codexRouter() -> FakeRouter {
        let r = FakeRouter()
        r.defaultAssignment = Assignment(block: ExecutionBlock(
            kind: "x", harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"], pool: "codex-default",
            source: AssignmentSource(by: .rule, ruleId: "r3", reason: "test-authoring 0.8 → codex", at: D.at)))
        return r
    }

    private func plan(_ rows: [TaskContextRow], affected: KindID, router: FakeRouter) -> KindReroute.Plan {
        KindReroute.plan(rows: rows, affected: affected, project: project, kinds: D.kinds, router: router, catalogs: D.catalogs, now: D.at)
    }

    func testOnlyUnpinnedTasksOfTheAffectedKindAreReRouted() throws {
        let r = codexRouter()
        let p = plan([try row("t1", kind: "snapshot-tests"), try row("t2", kind: "snapshot-tests", pinned: true),
                      try row("t3", kind: "algorithm")], affected: "snapshot-tests", router: r)
        XCTAssertEqual(p.changes.map(\.id), ["t1"])
        XCTAssertEqual(p.changes.first?.block.kind, "snapshot-tests", "the task keeps its own kind")
        XCTAssertEqual(p.changes.first?.block.harness, "codex")
        XCTAssertEqual(p.skippedPinned, ["t2"])
        XCTAssertEqual(r.assignCalls, ["snapshot-tests"], "a pinned task is never even routed")
    }

    func testKindsMergedIntoTheAffectedKindComeAlong() throws {
        let p = plan([try row("t1", kind: "golden-tests")], affected: "snapshot-tests", router: codexRouter())
        XCTAssertEqual(p.changes.map(\.id), ["t1"])
        XCTAssertEqual(p.changes.first?.block.kind, "golden-tests")
    }

    func testAnUnchangedAssignmentIsNotRewritten() throws {
        let same = try row("t1", kind: "snapshot-tests", harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"], pool: "codex-default")
        XCTAssertEqual(plan([same], affected: "snapshot-tests", router: codexRouter()).changes, [])
    }

    func testInvalidBlocksAreReportedNotRepaired() {
        let p = plan([TaskContextRow(id: "t9", agentContext: #"{"flight_deck":{"execution":{"v":1,"kind":"snapshot-tests"}}}"#),
                      TaskContextRow(id: "t0", agentContext: nil)], affected: "snapshot-tests", router: codexRouter())
        XCTAssertEqual(p.invalid, ["t9": "missing harness"])
        XCTAssertEqual(p.changes, [])
    }

    func testAnUnroutableTaskIsReported() throws {
        let r = FakeRouter()
        r.defaultAssignment = Assignment(block: ExecutionBlock(kind: "x", harness: "", model: "", pool: "",
            source: AssignmentSource(by: .default, reason: "unroutable: no enabled agent has a model and a pool", at: D.at)))
        let p = plan([try row("t1", kind: "snapshot-tests")], affected: "snapshot-tests", router: r)
        XCTAssertEqual(p.unroutable, ["t1": "unroutable: no enabled agent has a model and a pool"])
        XCTAssertEqual(p.changes, [])
    }

    func testBrListParsesTheEnvelopeAndABareArray() throws {
        let rows = try TaskContextRow.parse(brList: RoutingFixtures.data("br-list-open.json"))
        XCTAssertEqual(rows.map(\.id), ["fx-a", "fx-b"])
        XCTAssertNotNil(rows[0].agentContext); XCTAssertNil(rows[1].agentContext)
        XCTAssertEqual(try TaskContextRow.parse(brList: L3Fixtures.data("br-list-with-blocks")).count, 5)
        XCTAssertThrowsError(try TaskContextRow.parse(brList: Data(#""nope""#.utf8)))
    }
}
```

`OpenTaskReaderTests.swift`:

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

@MainActor
final class OpenTaskReaderTests: XCTestCase {
    func testItListsOpenTasksAsJSON() async throws {
        let list = String(decoding: try RoutingFixtures.data("br-list-open.json"), as: UTF8.self)
        let r = RecordingRunner(replies: ["br list": (list, 0)])
        let result = await BrOpenTaskReader(runner: r, brPath: "br").openTasks(project: "/p")
        XCTAssertEqual(r.calls.first, ["br", "list", "--status", "open", "--json"])
        XCTAssertEqual(try result.get().map(\.id), ["fx-a", "fx-b"])
    }

    func testAFailureSaysWhy() async {
        let r = RecordingRunner(replies: ["br list": ("no database here", 1)])
        let result = await BrOpenTaskReader(runner: r, brPath: "br").openTasks(project: "/p")
        XCTAssertEqual(result, .failure(OpenTaskReadError(message: "br list exited 1: no database here")))
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=KindRerouteTests,OpenTaskReaderTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build errors `cannot find 'TaskContextRow' in scope` / `cannot find 'BrOpenTaskReader' in scope`.

- [ ] **Step 4: Implement `KindReroute.swift`**

```swift
import Foundation

/// One open task and its `agent_context`.
public struct TaskContextRow: Equatable, Sendable {
    public var id: String
    public var agentContext: String?
    public init(id: String, agentContext: String?) { self.id = id; self.agentContext = agentContext }

    /// `br list --json` is an `{"issues": [...]}` envelope on br 0.6.0 (probed 2026-10-04). A bare
    /// array is accepted too — L3-0's shared fixture is one — so a br that drops the envelope
    /// does not read as "no open tasks".
    public static func parse(brList data: Data) throws -> [TaskContextRow] {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let rows: [[String: Any]]
        if let envelope = json as? [String: Any], let issues = envelope["issues"] as? [[String: Any]] {
            rows = issues
        } else if let array = json as? [[String: Any]] {
            rows = array
        } else {
            throw TaskListUnreadable()
        }
        return rows.compactMap { row in
            (row["id"] as? String).map { TaskContextRow(id: $0, agentContext: row["agent_context"] as? String) }
        }
    }
}

public struct TaskListUnreadable: Error, Equatable, Sendable { public init() {} }

/// Which open tasks a kind change re-routes, and to what (spec L3-R §5: "when a kind is merged or
/// re-weighted, for the open tasks of that kind that are not pinned").
public enum KindReroute {
    public struct Change: Equatable, Sendable {
        public var id: String
        public var block: ExecutionBlock
        public init(id: String, block: ExecutionBlock) { self.id = id; self.block = block }
    }

    public struct Plan: Equatable, Sendable {
        public var changes: [Change] = []
        public var skippedPinned: [String] = []
        public var unroutable: [String: String] = [:]
        /// Blocks that do not decode. Reported, never repaired (L3-0 §4): re-routing over one would
        /// hide whatever wrote it.
        public var invalid: [String: String] = [:]
        public init() {}
    }

    /// `affected` is the kind that changed. A task is affected when its kind's merge chain passes
    /// through it — the kind itself, or a kind merged into it.
    public static func plan(rows: [TaskContextRow], affected: KindID, project: URL, kinds: [TaskKind],
                            router: any Router, catalogs: AdapterCatalogs, now: Date) -> Plan {
        var plan = Plan()
        for row in rows {
            switch ExecutionBlockCodec.decode(agentContext: row.agentContext) {
            case .failure(let error):
                plan.invalid[row.id] = error.message
            case .success(nil):
                continue
            case .success(let old?):
                guard KindChain.ids(from: old.kind, in: kinds).contains(affected) else { continue }
                if old.pinned { plan.skippedPinned.append(row.id); continue }
                let record = kinds.first { $0.id == old.kind }
                    ?? TaskKind(id: old.kind, name: old.kind.rawValue, description: "", dimensions: [:], origin: .planning, createdAt: now)
                var block = router.assign(kind: record, project: project, catalogs: catalogs, now: now).block
                if block.model.isEmpty { plan.unroutable[row.id] = block.source.reason; continue }
                if block.harness == old.harness, block.model == old.model, block.knobs == old.knobs, block.pool == old.pool { continue }
                block.kind = old.kind
                plan.changes.append(Change(id: row.id, block: block))
            }
        }
        return plan
    }
}
```

- [ ] **Step 5: Implement `OpenTaskReader.swift`**

```swift
import Foundation
import IntakeKit

struct OpenTaskReadError: Error, Equatable, Sendable {
    let message: String
}

/// Open tasks with their `agent_context` — what a kind change re-routes and what the Task kinds
/// pane counts. A protocol so `RoutingService`'s tests never run `br`.
protocol OpenTaskReading: Sendable {
    func openTasks(project: String) async -> Result<[TaskContextRow], OpenTaskReadError>
}

/// `br list --status open --json`. Never `br ready`: it does not carry `agent_context`
/// (L3-0 §4, probed on br 0.6.0).
struct BrOpenTaskReader: OpenTaskReading {
    let runner: FlywheelProcessRunner
    let brPath: String

    init(runner: FlywheelProcessRunner = SystemFlywheelProcessRunner(), brPath: String = "br") {
        self.runner = runner
        self.brPath = brPath
    }

    func openTasks(project: String) async -> Result<[TaskContextRow], OpenTaskReadError> {
        guard let (stdout, code) = try? await runner.run(brPath, ["list", "--status", "open", "--json"], cwd: project) else {
            return .failure(OpenTaskReadError(message: "br could not be started"))
        }
        guard code == 0 else { return .failure(OpenTaskReadError(message: "br list exited \(code): \(stdout.firstLine)")) }
        do { return .success(try TaskContextRow.parse(brList: Data(stdout.utf8))) }
        catch { return .failure(OpenTaskReadError(message: "br list printed JSON Flight Deck cannot read")) }
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=KindRerouteTests,OpenTaskReaderTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 7: Commit**

```bash
git add Sources/IntakeKit/FlightControl/KindReroute.swift Sources/FlightDeck/FlightControl/OpenTaskReader.swift Tests/FlightDeckTests/Fixtures/FlightControlL3/Routing/br-list-open.json Tests/FlightDeckTests/FlightControlL3/Routing/KindRerouteTests.swift Tests/FlightDeckTests/FlightControlL3/Routing/OpenTaskReaderTests.swift
git commit -m "feat: plan the re-route of open, unpinned tasks when their kind changes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: `RoutingService` — rules, compile, confirm, router, hints

**Files:**
- Create: `Sources/FlightDeck/FlightControl/RoutingService.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingServiceSupport.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 1–7, 13, 15; `PreferencesStore` (+ Task 2 accessors, `setProjectSettings`, `preferences.agents`, `preferences.projectSettings`), `AgentID.harnessID` (L3-0).
- Produces:
  - `enum RuleScope: Hashable { case global; case project(String) }`
  - `@MainActor final class RoutingService: ObservableObject` with `init(preferences:kindStore:projectStore:makeCompiler:loadCatalogs:pools:index:hints:tasks:writer:fixtureProjects:makeRuleID:now:)`; published `revision`, `compiling`, `notes`, `kindNote`; `rules(_:)`, `projectRulesError(_:)`, `addRule(_:to:) -> String?`, `editSentence(_:_:in:)`, `deleteRule(_:in:)`, `moveRule(_:by:in:)`, `confirm(_:in:)`, `compile(_:in:) async`, `compilerInput(sentence:scope:) async`, `kinds(for:)`, `catalogs() async`, `defaultPools(_:)`, `makeRouter() -> RuleRouter`, `hint(for:scope:)`, `dismissHint(_:)`, `url(_:)`, `bump()`
  - Test support: `ScriptedCompiler`, `FakeOpenTasks`, `RecordingBlockWriter`, `FixedHints`, `RoutingServiceSupport.make(...)`, `RoutingServiceSupport.serviceWire`

- [ ] **Step 1: Write the test support**

`RoutingServiceSupport.swift`:

```swift
import Foundation
import IntakeKit
@testable import FlightDeck

/// A compiler that answers from a script and records what it was asked.
final class ScriptedCompiler: RuleCompiling, @unchecked Sendable {
    var proposal: RuleProposal
    /// Runs on the main actor just before the answer — lets a test edit a rule mid-compile.
    var beforeReturning: (@MainActor () -> Void)?
    private(set) var inputs: [RuleCompilerInput] = []
    let ref = CompilerRef(harness: "claude", model: "haiku")
    init(_ proposal: RuleProposal) { self.proposal = proposal }
    func propose(_ input: RuleCompilerInput) async -> RuleProposal {
        inputs.append(input)
        if let hook = beforeReturning { await MainActor.run { hook() } }
        return proposal
    }
}

final class FakeOpenTasks: OpenTaskReading, @unchecked Sendable {
    var result: Result<[TaskContextRow], OpenTaskReadError> = .success([])
    func openTasks(project: String) async -> Result<[TaskContextRow], OpenTaskReadError> { result }
}

final class RecordingBlockWriter: BlockWriting, @unchecked Sendable {
    private(set) var writes: [(id: String, block: ExecutionBlock, project: String)] = []
    var outcome: BlockWriteOutcome = .written
    func writeBlock(_ block: ExecutionBlock, id: String, project: String) async -> BlockWriteOutcome {
        writes.append((id, block, project))
        return outcome
    }
}

struct FixedHints: RuleHintSource {
    var fixed: RuleHint?
    func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? {
        rule.id == fixed?.ruleID ? fixed : nil
    }
}

@MainActor
enum RoutingServiceSupport {
    /// The spec wire with no pool named, so it compiles to the agent's default pool — the only
    /// pools `DefaultPoolDirectory` has.
    static var serviceWire: RuleCompilerWire {
        var w = RoutingTestData.specWire
        w.pool = nil
        return w
    }

    static func make(prefs: PreferencesStore? = nil, compiler: ScriptedCompiler? = nil,
                     hints: any RuleHintSource = NoRuleHints(), tasks: FakeOpenTasks? = nil,
                     writer: RecordingBlockWriter? = nil,
                     loadCatalogs: (@MainActor () async -> AdapterCatalogs)? = nil) -> RoutingService {
        let compiler = compiler ?? ScriptedCompiler(.wire(serviceWire))
        var next = 0
        return RoutingService(preferences: prefs ?? PreferencesStore(persistence: nil),
                              kindStore: KindRegistryStore(now: { RoutingTestData.at }),
                              makeCompiler: { compiler },
                              loadCatalogs: loadCatalogs ?? { RoutingTestData.catalogs },
                              pools: DefaultPoolDirectory(harnesses: ["codex", "claude"]),
                              hints: hints, tasks: tasks ?? FakeOpenTasks(), writer: writer ?? RecordingBlockWriter(),
                              makeRuleID: { next += 1; return "r\(next)" }, now: { RoutingTestData.at })
    }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The app's owner of routing rules (spec L3-R §2–§3): the global list in preferences, the
/// project list in the repo, and the draft → compiled → confirmed path between them.
@MainActor
final class RoutingServiceTests: XCTestCase {
    private typealias D = RoutingTestData
    private var project: URL!
    private var path: String { project.path }

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingServiceTests-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private func make(prefs: PreferencesStore? = nil, compiler: ScriptedCompiler? = nil,
                      hints: any RuleHintSource = NoRuleHints()) -> RoutingService {
        RoutingServiceSupport.make(prefs: prefs, compiler: compiler, hints: hints)
    }

    func testAddCompileConfirmAGlobalRule() async throws {
        let prefs = PreferencesStore(persistence: nil)
        let svc = make(prefs: prefs)
        let id = try XCTUnwrap(svc.addRule("  " + D.specSentence + " ", to: .global))
        XCTAssertEqual(svc.rules(.global).first?.state, .draft)
        XCTAssertEqual(svc.rules(.global).first?.sentence, D.specSentence)
        await svc.compile(id, in: .global)
        let compiled = try XCTUnwrap(svc.rules(.global).first)
        XCTAssertEqual(compiled.state, .compiled)
        XCTAssertEqual(compiled.compiled?.assign.pool, "codex-default")
        XCTAssertEqual(compiled.compiler, CompilerRef(harness: "claude", model: "haiku"))
        XCTAssertEqual(compiled.compiledAt, D.at)
        svc.confirm(id, in: .global)
        XCTAssertEqual(prefs.globalRoutingRules.first?.state, .confirmed)
    }

    func testACompileFailureIsShownWithItsFirstError() async throws {
        var bad = RoutingServiceSupport.serviceWire
        bad.terms[0].dimension = "teleportation"
        let svc = make(compiler: ScriptedCompiler(.wire(bad)))
        let id = try XCTUnwrap(svc.addRule("Use Codex when a task needs teleportation", to: .global))
        await svc.compile(id, in: .global)
        XCTAssertEqual(svc.rules(.global).first?.state, .failed)
        XCTAssertEqual(svc.rules(.global).first?.failure, "unknown dimension teleportation")
    }

    func testAnUnavailableCompilerLeavesTheRuleADraftAndSaysWhy() async throws {
        let svc = make(compiler: ScriptedCompiler(.unavailable("claude exited 1: Not logged in")))
        let id = try XCTUnwrap(svc.addRule("x", to: .global))
        await svc.compile(id, in: .global)
        XCTAssertEqual(svc.rules(.global).first?.state, .draft)
        XCTAssertEqual(svc.notes[id], "Compiler unavailable: claude exited 1: Not logged in")
        XCTAssertTrue(svc.compiling.isEmpty)
    }

    func testEditingTheSentenceReturnsToDraft() async throws {
        let svc = make()
        let id = try XCTUnwrap(svc.addRule(D.specSentence, to: .global))
        await svc.compile(id, in: .global)
        svc.confirm(id, in: .global)
        svc.editSentence(id, "Use Codex for tests only", in: .global)
        let rule = try XCTUnwrap(svc.rules(.global).first)
        XCTAssertEqual(rule.state, .draft)
        XCTAssertNil(rule.compiled)
    }

    func testOnlyACompiledRuleCanBeConfirmed() throws {
        let svc = make()
        let id = try XCTUnwrap(svc.addRule("x", to: .global))
        svc.confirm(id, in: .global)
        XCTAssertEqual(svc.rules(.global).first?.state, .draft)
    }

    func testProjectRulesLiveInTheRepoFile() throws {
        let svc = make()
        let id = try XCTUnwrap(svc.addRule(D.specSentence, to: .project(path)))
        XCTAssertEqual(ProjectRoutingStore().load(project: project).rules.map(\.id), [id])
        XCTAssertEqual(svc.rules(.global), [])
    }

    func testProjectRuleEditsAreRefusedWhileTheFileIsInvalid() throws {
        let url = ProjectRoutingStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = Data("<<<<<<< HEAD\n".utf8)
        try broken.write(to: url)
        let svc = make()
        XCTAssertNil(svc.addRule("Use Claude for docs", to: .project(path)))
        XCTAssertNotNil(svc.projectRulesError(path))
        XCTAssertEqual(svc.rules(.project(path)), [])
        XCTAssertEqual(try Data(contentsOf: url), broken, "the user's file is never overwritten")
    }

    func testGlobalRulesCompileAgainstSeedKindsAndProjectRulesAgainstTheRegistry() async throws {
        let kinds = KindRegistryStore.fileURL(project: project)
        try FileManager.default.createDirectory(at: kinds.deletingLastPathComponent(), withIntermediateDirectories: true)
        try L3Fixtures.data("kinds").write(to: kinds)
        let compiler = ScriptedCompiler(.wire(RoutingServiceSupport.serviceWire))
        let svc = make(compiler: compiler)
        let g = try XCTUnwrap(svc.addRule("x", to: .global))
        await svc.compile(g, in: .global)
        let p = try XCTUnwrap(svc.addRule("y", to: .project(path)))
        await svc.compile(p, in: .project(path))
        XCTAssertFalse(compiler.inputs[0].kinds.contains { $0.id == "snapshot-tests" })
        XCTAssertTrue(compiler.inputs[1].kinds.contains { $0.id == "snapshot-tests" })
        XCTAssertEqual(compiler.inputs[0].defaultPools["codex"], "codex-default")
    }

    func testAnEditDuringACompileWins() async throws {
        let compiler = ScriptedCompiler(.wire(RoutingServiceSupport.serviceWire))
        let svc = make(compiler: compiler)
        let id = try XCTUnwrap(svc.addRule("first words", to: .global))
        compiler.beforeReturning = { svc.editSentence(id, "second words", in: .global) }
        await svc.compile(id, in: .global)
        let rule = try XCTUnwrap(svc.rules(.global).first)
        XCTAssertEqual(rule.sentence, "second words")
        XCTAssertEqual(rule.state, .draft)
        XCTAssertNil(rule.compiled)
    }

    func testMovingARuleChangesWhichMatchesFirst() throws {
        let svc = make()
        let a = try XCTUnwrap(svc.addRule("a", to: .global))
        let b = try XCTUnwrap(svc.addRule("b", to: .global))
        svc.moveRule(b, by: -1, in: .global)
        XCTAssertEqual(svc.rules(.global).map(\.id), [b, a])
        svc.moveRule(b, by: -1, in: .global)
        XCTAssertEqual(svc.rules(.global).map(\.id), [b, a], "moving past the top is a no-op")
    }

    func testTheRouterRoutesByWhatIsConfirmedNow() async throws {
        let svc = make()
        let id = try XCTUnwrap(svc.addRule(D.specSentence, to: .global))
        await svc.compile(id, in: .global)
        XCTAssertEqual(svc.makeRouter().assign(kind: D.snapshot, project: project, catalogs: D.catalogs, now: D.at).block.source.by,
                       .default, "compiled is not confirmed")
        svc.confirm(id, in: .global)
        let a = svc.makeRouter().assign(kind: D.snapshot, project: project, catalogs: D.catalogs, now: D.at)
        XCTAssertEqual(a.block.harness, "codex")
        XCTAssertEqual(a.block.source.ruleId, id)
    }

    func testTheDefaultAgentIsTheProjectsChoice() {
        let prefs = PreferencesStore(persistence: nil)
        prefs.setProjectSettings(path, ProjectSettings(defaultAgent: .codex))
        let svc = make(prefs: prefs)
        XCTAssertEqual(svc.makeRouter().assign(kind: D.docs, project: project, catalogs: D.catalogs, now: D.at).block.harness, "codex")
        let elsewhere = URL(fileURLWithPath: "/elsewhere", isDirectory: true)
        XCTAssertEqual(svc.makeRouter().assign(kind: D.docs, project: elsewhere, catalogs: D.catalogs, now: D.at).block.harness,
                       "claude", "a project with no choice gets the first global agent")
    }

    func testHintsShowOnConfirmedRulesAndStayDismissedUntilTheSnapshotChanges() async throws {
        let prefs = PreferencesStore(persistence: nil)
        let first = RuleHint(ruleID: "r1", text: "gpt-6-luna scores 0.14 higher on test-authoring (confidence 0.8)",
                             snapshotDate: Date(timeIntervalSince1970: 1_000))
        let svc = make(prefs: prefs, hints: FixedHints(fixed: first))
        let id = try XCTUnwrap(svc.addRule(D.specSentence, to: .global))
        XCTAssertEqual(id, "r1")
        XCTAssertNil(svc.hint(for: svc.rules(.global)[0], scope: .global), "a draft shows no hint")
        await svc.compile(id, in: .global)
        svc.confirm(id, in: .global)
        XCTAssertEqual(svc.hint(for: svc.rules(.global)[0], scope: .global), first)
        svc.dismissHint(first)
        XCTAssertNil(svc.hint(for: svc.rules(.global)[0], scope: .global))

        var newer = first
        newer.snapshotDate = Date(timeIntervalSince1970: 2_000)
        let later = make(prefs: prefs, hints: FixedHints(fixed: newer))
        XCTAssertEqual(later.hint(for: prefs.globalRoutingRules[0], scope: .global), newer, "a new index snapshot brings it back")
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=RoutingServiceTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'RoutingService' in scope`.

- [ ] **Step 4: Implement `RoutingService.swift`**

```swift
import Foundation
import IntakeKit

/// Where a routing rule lives (spec L3-R §2): the global list in preferences, or one project's
/// `.flightdeck/routing.json`, which is checked first.
enum RuleScope: Hashable {
    case global
    case project(String)
}

/// L3-R's moving parts for the app: both rule lists and the draft → compiled → confirmed path,
/// the kind registry (see `RoutingService+Kinds.swift`), and a router built from what is
/// confirmed right now.
///
/// `@MainActor` because global rules live in `PreferencesStore`. The router it hands out is a
/// value snapshot, so routing itself never waits on the main actor.
@MainActor
final class RoutingService: ObservableObject {
    /// Bumped on every write. Rules live in two stores (preferences and a repo file), and a view
    /// observing only this service must still redraw when either changes.
    @Published private(set) var revision = 0
    @Published private(set) var compiling: Set<String> = []
    /// Rule id → why the compiler could not run. Spec §8: the rule stays a draft, and says why.
    @Published private(set) var notes: [String: String] = [:]
    /// The last kind change's re-route summary, shown under the Task kinds list.
    @Published var kindNote: String?

    let preferences: PreferencesStore
    let kindStore: KindRegistryStore
    let projectStore: ProjectRoutingStore
    /// A closure, not a compiler: the compiler settings can change between compiles.
    let makeCompiler: @MainActor () -> any RuleCompiling
    let loadCatalogs: @MainActor () async -> AdapterCatalogs
    let pools: any PoolDirectory
    let index: any CapabilityIndex
    let hints: any RuleHintSource
    let tasks: any OpenTaskReading
    let writer: any BlockWriting
    /// Projects the panes offer with no session open: the UI-test fixture's. nil in a real launch.
    let fixtureProjects: [String]?
    private let makeRuleID: () -> String
    let now: () -> Date
    /// What the last catalog load saw — hints are drawn from it, because a view cannot await.
    private(set) var lastCatalogs = AdapterCatalogs([])

    init(preferences: PreferencesStore, kindStore: KindRegistryStore,
         projectStore: ProjectRoutingStore = ProjectRoutingStore(),
         makeCompiler: @escaping @MainActor () -> any RuleCompiling,
         loadCatalogs: @escaping @MainActor () async -> AdapterCatalogs,
         pools: any PoolDirectory, index: any CapabilityIndex = NullCapabilityIndex(),
         hints: any RuleHintSource = NoRuleHints(), tasks: any OpenTaskReading, writer: any BlockWriting,
         fixtureProjects: [String]? = nil, makeRuleID: @escaping () -> String = RoutingService.randomRuleID,
         now: @escaping () -> Date = Date.init) {
        self.preferences = preferences; self.kindStore = kindStore; self.projectStore = projectStore
        self.makeCompiler = makeCompiler; self.loadCatalogs = loadCatalogs; self.pools = pools
        self.index = index; self.hints = hints; self.tasks = tasks; self.writer = writer
        self.fixtureProjects = fixtureProjects; self.makeRuleID = makeRuleID; self.now = now
    }

    nonisolated static func randomRuleID() -> String { "r-" + UUID().uuidString.prefix(8).lowercased() }

    func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    func bump() { revision += 1 }

    // MARK: - Rules

    func rules(_ scope: RuleScope) -> [RoutingRule] {
        switch scope {
        case .global: return preferences.globalRoutingRules
        case .project(let path): return projectStore.load(project: url(path)).rules
        }
    }

    /// Why the project's `routing.json` cannot be read, or nil. Shown above its list (spec §8).
    func projectRulesError(_ path: String) -> String? {
        if case .invalid(let why) = projectStore.load(project: url(path)) { return why }
        return nil
    }

    @discardableResult
    func addRule(_ sentence: String, to scope: RuleScope) -> String? {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rule = RoutingRule(id: makeRuleID(), sentence: trimmed)
        return mutate(scope) { $0.append(rule) } ? rule.id : nil
    }

    func editSentence(_ id: String, _ sentence: String, in scope: RuleScope) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(scope) { rules in
            if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].edit(sentence: trimmed) }
        }
        notes[id] = nil
    }

    func deleteRule(_ id: String, in scope: RuleScope) {
        mutate(scope) { $0.removeAll { $0.id == id } }
        notes[id] = nil
    }

    /// First match wins (spec §2), so order is routing behavior, not presentation.
    func moveRule(_ id: String, by offset: Int, in scope: RuleScope) {
        mutate(scope) { rules in
            guard let i = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(i + offset) else { return }
            rules.swapAt(i, i + offset)
        }
    }

    func confirm(_ id: String, in scope: RuleScope) {
        mutate(scope) { rules in
            if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].confirm() }
        }
    }

    func compile(_ id: String, in scope: RuleScope) async {
        guard !compiling.contains(id), let rule = rules(scope).first(where: { $0.id == id }) else { return }
        compiling.insert(id)
        defer { compiling.remove(id) }
        let input = await compilerInput(sentence: rule.sentence, scope: scope)
        let compiler = makeCompiler()
        let proposal = await compiler.propose(input)
        let outcome = RuleCompilation.finish(proposal, input: input)
        mutate(scope) { rules in
            // An edit made while the compiler ran wins: its words are not the ones compiled.
            guard let i = rules.firstIndex(where: { $0.id == id }), rules[i].sentence == rule.sentence else { return }
            rules[i].record(outcome, by: compiler.ref, at: now())
        }
        if case .unavailable(let why) = outcome { notes[id] = "Compiler unavailable: \(why)" } else { notes[id] = nil }
    }

    func compilerInput(sentence: String, scope: RuleScope) async -> RuleCompilerInput {
        let catalogs = await self.catalogs()
        return RuleCompilerInput(sentence: sentence, kinds: kinds(for: scope), catalogs: catalogs,
                                 pools: pools.pools(), defaultPools: defaultPools(catalogs))
    }

    /// Global rules compile against the seed kinds (deviation 6): the registry is per project.
    func kinds(for scope: RuleScope) -> [TaskKind] {
        switch scope {
        case .global: return SeedKinds.all(createdAt: now())
        case .project(let path): return (try? kindStore.kinds(project: url(path))) ?? SeedKinds.all(createdAt: now())
        }
    }

    func catalogs() async -> AdapterCatalogs {
        let loaded = await loadCatalogs()
        lastCatalogs = loaded
        return loaded
    }

    func defaultPools(_ catalogs: AdapterCatalogs) -> [HarnessID: PoolID] {
        var out: [HarnessID: PoolID] = [:]
        for h in catalogs.order { if let p = pools.defaultPool(for: h) { out[h] = p } }
        return out
    }

    /// The one write path for both lists. A project whose `routing.json` is invalid is refused:
    /// that file is the user's to fix, and saving Settings' view over it would destroy it.
    @discardableResult
    private func mutate(_ scope: RuleScope, _ body: (inout [RoutingRule]) -> Void) -> Bool {
        switch scope {
        case .global:
            var rules = preferences.globalRoutingRules
            body(&rules)
            preferences.globalRoutingRules = rules
        case .project(let path):
            let load = projectStore.load(project: url(path))
            if case .invalid = load { return false }
            var rules = load.rules
            body(&rules)
            do { try projectStore.save(rules, project: url(path)) } catch { return false }
        }
        bump()
        return true
    }

    // MARK: - Routing

    /// A snapshot of what routes right now, through the contract's `Router`: what release,
    /// re-route and (at integration) the swarm's launch and spill call. Project rules are read
    /// from the repo file at routing time; the global list and default agents are copied here.
    func makeRouter() -> RuleRouter {
        let fallback = preferences.preferences.agents.first?.id.harnessID
        var byProject: [String: HarnessID] = [:]
        for (path, settings) in preferences.preferences.projectSettings {
            if let agent = settings.defaultAgent { byProject[path] = agent.harnessID }
        }
        let defaults = byProject
        return RuleRouter(rules: ProjectFileRuleSource(global: preferences.globalRoutingRules, store: projectStore),
                          kinds: kindStore, index: index, pools: pools,
                          defaultHarness: { project in defaults[project.standardizedFileURL.path] ?? fallback })
    }

    // MARK: - Hints (spec §7)

    /// Only confirmed rules carry a hint. A dismissed hint stays dismissed until the index
    /// snapshot it came from changes. Hints never change routing.
    func hint(for rule: RoutingRule, scope: RuleScope) -> RuleHint? {
        guard rule.state == .confirmed,
              let hint = hints.hint(for: rule, kinds: kinds(for: scope), catalogs: lastCatalogs) else { return nil }
        return preferences.isHintDismissed(ruleID: rule.id, snapshot: hint.snapshotDate) ? nil : hint
    }

    func dismissHint(_ hint: RuleHint) {
        preferences.dismissHint(ruleID: hint.ruleID, snapshot: hint.snapshotDate)
        bump()
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=RoutingServiceTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 13 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/RoutingService.swift Tests/FlightDeckTests/FlightControlL3/Routing/RoutingServiceSupport.swift Tests/FlightDeckTests/FlightControlL3/Routing/RoutingServiceTests.swift
git commit -m "feat: add, compile, confirm and order routing rules, and route by what is confirmed" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 17: `RoutingService` — kinds, re-route on change, counts, and release routing

**Files:**
- Create: `Sources/FlightDeck/FlightControl/RoutingService+Kinds.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingServiceKindsTests.swift`

**Interfaces:**
- Consumes: Tasks 3, 12, 14 (`EncodeRoutingProviding`), 15, 16.
- Produces:
  - `enum KindsLoad: Equatable { case loaded([TaskKind]); case unreadable(String) }`
  - `extension RoutingService { func kinds(project:) -> KindsLoad; func isNew(_:project:) -> Bool; func markSeen(_:project:); func rename(_:to:project:) -> String?; func reweight(_:dimensions:project:) async -> String?; func merge(_:into:project:) async -> String?; func openCounts(project:) async -> [KindID: Int]; func reroute(project:affected:) async -> String }`
  - `extension RoutingService: EncodeRoutingProviding`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Settings → Task kinds (spec L3-R §6) through the service: new badges, rename, re-weight and
/// merge — the last two re-routing the kind's open, unpinned tasks (§5) — and the release seam.
@MainActor
final class RoutingServiceKindsTests: XCTestCase {
    private typealias D = RoutingTestData
    private var project: URL!
    private var path: String { project.path }

    override func setUp() {
        super.setUp()
        project = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingServiceKindsTests-\(UUID())", isDirectory: true)
        let file = KindRegistryStore.fileURL(project: project)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? L3Fixtures.data("kinds").write(to: file)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: project); super.tearDown() }

    private func row(_ id: String, kind: KindID, pinned: Bool = false) throws -> TaskContextRow {
        let b = ExecutionBlock(kind: kind, harness: "claude", model: "opus", pool: "claude-default",
                               source: AssignmentSource(by: .default, reason: "r", at: D.at), pinned: pinned)
        return TaskContextRow(id: id, agentContext: try ExecutionBlockCodec.encode(b, into: nil))
    }

    private func loaded(_ svc: RoutingService) -> [TaskKind] {
        guard case .loaded(let kinds) = svc.kinds(project: path) else { XCTFail("kinds did not load"); return [] }
        return kinds
    }

    func testPlanningKindsAreNewUntilSeen() throws {
        let svc = RoutingServiceSupport.make()
        let kinds = loaded(svc)
        let snapshot = try XCTUnwrap(kinds.first { $0.id == "snapshot-tests" })
        let tests = try XCTUnwrap(kinds.first { $0.id == "tests" })
        XCTAssertTrue(svc.isNew(snapshot, project: path))
        XCTAssertFalse(svc.isNew(tests, project: path), "seed kinds are never new")
        svc.markSeen("snapshot-tests", project: path)
        XCTAssertFalse(svc.isNew(snapshot, project: path))
    }

    func testRenameKeepsTheIdAndReportsErrors() {
        let svc = RoutingServiceSupport.make()
        XCTAssertNil(svc.rename("algorithm", to: "Algorithms and data structures", project: path))
        XCTAssertEqual(loaded(svc).first { $0.id == "algorithm" }?.name, "Algorithms and data structures")
        XCTAssertEqual(svc.rename("nope", to: "x", project: path), "unknown task kind nope")
    }

    func testMergeReRoutesUnpinnedOpenTasksOfThatKind() async throws {
        let prefs = PreferencesStore(persistence: nil)
        prefs.globalRoutingRules = [D.rule("g1", .any([.kind("tests")]), "codex", "gpt-6-sol", knobs: ["effort": "high"], pool: "codex-default")]
        let tasks = FakeOpenTasks()
        tasks.result = .success([try row("t1", kind: "snapshot-tests"), try row("t2", kind: "snapshot-tests", pinned: true),
                                 try row("t3", kind: "algorithm")])
        let writer = RecordingBlockWriter()
        let svc = RoutingServiceSupport.make(prefs: prefs, tasks: tasks, writer: writer)
        let error = await svc.merge("snapshot-tests", into: "tests", project: path)
        XCTAssertNil(error)
        XCTAssertEqual(loaded(svc).first { $0.id == "snapshot-tests" }?.status, .merged(into: "tests"))
        XCTAssertEqual(writer.writes.map(\.id), ["t1"])
        XCTAssertEqual(writer.writes.first?.block.harness, "codex")
        XCTAssertEqual(writer.writes.first?.block.kind, "snapshot-tests")
        XCTAssertEqual(writer.writes.first?.project, path)
        XCTAssertEqual(svc.kindNote, "Re-routed 1 open task; 1 pinned left alone")
    }

    func testReweightReRoutesTheKindAndKindsMergedIntoIt() async throws {
        let prefs = PreferencesStore(persistence: nil)
        prefs.globalRoutingRules = [D.rule("g3", .any([.dimension("docs-prose", atLeast: 0.5)]), "codex", "gpt-6-sol", pool: "codex-default")]
        let tasks = FakeOpenTasks()
        tasks.result = .success([try row("t1", kind: "golden-tests"), try row("t3", kind: "algorithm")])
        let writer = RecordingBlockWriter()
        let svc = RoutingServiceSupport.make(prefs: prefs, tasks: tasks, writer: writer)
        let error = await svc.reweight("snapshot-tests", dimensions: ["docs-prose": 0.9], project: path)
        XCTAssertNil(error)
        XCTAssertEqual(writer.writes.map(\.id), ["t1"], "golden-tests is merged into snapshot-tests; algorithm is untouched")
    }

    func testAFailedReadIsReportedNotSwallowed() async {
        let tasks = FakeOpenTasks()
        tasks.result = .failure(OpenTaskReadError(message: "br list exited 1: x"))
        let svc = RoutingServiceSupport.make(tasks: tasks)
        let error = await svc.merge("snapshot-tests", into: "tests", project: path)
        XCTAssertNil(error, "the merge itself succeeded")
        XCTAssertEqual(svc.kindNote, "Could not read open tasks: br list exited 1: x")
    }

    func testAMergeTheRegistryRefusesChangesNothing() async {
        let writer = RecordingBlockWriter()
        let svc = RoutingServiceSupport.make(writer: writer)
        let error = await svc.merge("tests", into: "tests", project: path)
        XCTAssertEqual(error, "tests cannot be merged into itself")
        XCTAssertTrue(writer.writes.isEmpty)
        XCTAssertNil(svc.kindNote)
    }

    func testOpenCountsResolveMergedKinds() async throws {
        let tasks = FakeOpenTasks()
        tasks.result = .success([try row("t1", kind: "golden-tests"), try row("t2", kind: "snapshot-tests"),
                                 try row("t3", kind: "tests"), TaskContextRow(id: "t4", agentContext: nil)])
        let svc = RoutingServiceSupport.make(tasks: tasks)
        let counts = await svc.openCounts(project: path)
        XCTAssertEqual(counts, ["snapshot-tests": 2, "tests": 1])
    }

    func testReleaseRoutesThroughTheService() async throws {
        let prefs = PreferencesStore(persistence: nil)
        prefs.globalRoutingRules = [D.r3(pool: "codex-default")]
        let svc = RoutingServiceSupport.make(prefs: prefs)
        let contexts = await svc.agentContexts(for: try RoutingFixtures.encodeSteps(), project: path)
        XCTAssertEqual(Set(contexts.keys), ["n1", "n2", "n3"])
        let n2 = try XCTUnwrap(ExecutionBlockCodec.decode(agentContext: contexts["n2"]).get())
        XCTAssertEqual(n2.kind, "snapshot-tests")
        XCTAssertEqual(n2.harness, "codex")
    }

    func testAnEditOnlyReleaseNeverLoadsCatalogs() async {
        var loads = 0
        let svc = RoutingServiceSupport.make(loadCatalogs: { loads += 1; return RoutingTestData.catalogs })
        let contexts = await svc.agentContexts(for: [.update(id: "b1", set: FieldSet(title: "x"))], project: path)
        XCTAssertEqual(contexts, [:])
        XCTAssertEqual(loads, 0, "codex's catalog spawns a process; a release with no creates must not pay for it")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=RoutingServiceKindsTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build errors `value of type 'RoutingService' has no member 'kinds(project:)'` / `… 'agentContexts'`.

- [ ] **Step 3: Implement `RoutingService+Kinds.swift`**

```swift
import Foundation
import IntakeKit

/// A project's kinds as the Task kinds pane shows them.
enum KindsLoad: Equatable {
    case loaded([TaskKind])
    case unreadable(String)
}

extension RoutingService {
    func kinds(project: String) -> KindsLoad {
        do { return .loaded(try kindStore.kinds(project: url(project))) }
        catch let error as KindRegistryError { return .unreadable(error.message) }
        catch { return .unreadable("\(error)") }
    }

    /// *New* until you open it (spec §6): only planning proposals, which arrive unasked.
    func isNew(_ kind: TaskKind, project: String) -> Bool {
        kind.origin == .planning && !preferences.seenKinds(project: project).contains(kind.id)
    }

    func markSeen(_ id: KindID, project: String) {
        guard !preferences.seenKinds(project: project).contains(id) else { return }
        preferences.markKindsSeen([id], project: project)
        bump()
    }

    /// Renaming changes only the label; the id every block names stays put, so nothing re-routes.
    func rename(_ id: KindID, to name: String, project: String) -> String? {
        do { try kindStore.rename(id, to: name, project: url(project)) }
        catch let error as KindRegistryError { return error.message }
        catch { return "\(error)" }
        bump()
        return nil
    }

    func reweight(_ id: KindID, dimensions: [String: Double], project: String) async -> String? {
        do { try kindStore.reweight(id, dimensions: dimensions, project: url(project)) }
        catch let error as KindRegistryError { return error.message }
        catch { return "\(error)" }
        bump()
        kindNote = await reroute(project: project, affected: id)
        return nil
    }

    func merge(_ id: KindID, into target: KindID, project: String) async -> String? {
        do { try kindStore.merge(id, into: target, project: url(project)) }
        catch let error as KindRegistryError { return error.message }
        catch { return "\(error)" }
        bump()
        kindNote = await reroute(project: project, affected: id)
        return nil
    }

    /// Open tasks per live kind: a task whose kind was merged counts toward the kind it resolves to.
    func openCounts(project: String) async -> [KindID: Int] {
        guard case .success(let rows) = await tasks.openTasks(project: project) else { return [:] }
        let kinds = (try? kindStore.kinds(project: url(project))) ?? []
        var counts: [KindID: Int] = [:]
        for row in rows {
            guard case .success(let block?) = ExecutionBlockCodec.decode(agentContext: row.agentContext) else { continue }
            counts[KindResolution.resolve(block.kind, in: kinds)?.id ?? block.kind, default: 0] += 1
        }
        return counts
    }

    /// Re-routes `affected`'s open, unpinned tasks (spec §5) and says what happened. A read
    /// failure is reported, not swallowed: "re-routed 0" would claim the tasks were checked.
    func reroute(project: String, affected: KindID) async -> String {
        let rows: [TaskContextRow]
        switch await tasks.openTasks(project: project) {
        case .failure(let error): return "Could not read open tasks: \(error.message)"
        case .success(let read): rows = read
        }
        let catalogs = await catalogs()
        let kinds = (try? kindStore.kinds(project: url(project))) ?? []
        let plan = KindReroute.plan(rows: rows, affected: affected, project: url(project), kinds: kinds,
                                    router: makeRouter(), catalogs: catalogs, now: now())
        var written = 0
        var failures: [String] = []
        for change in plan.changes {
            switch await writer.writeBlock(change.block, id: change.id, project: project) {
            case .written: written += 1
            case .skippedPinned: break
            case .failed(let why): failures.append(why)
            }
        }
        var note = "Re-routed \(written) open task\(written == 1 ? "" : "s")"
        if !plan.skippedPinned.isEmpty { note += "; \(plan.skippedPinned.count) pinned left alone" }
        if !plan.invalid.isEmpty { note += "; \(plan.invalid.count) with an invalid block skipped" }
        if !plan.unroutable.isEmpty { note += "; \(plan.unroutable.count) unroutable" }
        if let first = failures.first { note += "; \(failures.count) failed: \(first)" }
        return note
    }
}

extension RoutingService: EncodeRoutingProviding {
    func agentContexts(for steps: [ApplyStep], project: String) async -> [String: String] {
        // An edit-only release has nothing to route, and loading catalogs spawns codex's
        // app-server on first use — so it never loads them.
        let creates = steps.contains { step in
            if case .create = step { return true }
            return false
        }
        guard creates else { return [:] }
        let catalogs = await catalogs()
        let outcome = EncodeRouting.route(steps, project: url(project), registry: kindStore, router: makeRouter(),
                                          catalogs: catalogs, now: now())
        if !outcome.proposed.isEmpty { bump() }
        return outcome.contexts
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=RoutingServiceKindsTests,RoutingServiceTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 22 tests, with 0 failures` (9 + 13).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightControl/RoutingService+Kinds.swift Tests/FlightDeckTests/FlightControlL3/Routing/RoutingServiceKindsTests.swift
git commit -m "feat: rename, re-weight and merge task kinds, re-routing their open tasks" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 18: Row presentation and the Routing pane

**Files:**
- Create: `Sources/FlightDeck/FlightControl/RoutingPresentation.swift`
- Create: `Sources/FlightDeck/Preferences/UI/FlightControlRoutingPane.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingPresentationTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 16 (`RoutingService`, `RuleScope`, `hint(for:scope:)`), 2 (`routingCompilerSettings`).
- Produces:
  - `struct RuleRowPresentation: Equatable { stateLabel; compiledText: String?; failureText: String?; note: String?; canCompile; canConfirm; init(rule:compiling:note:) }`
  - `struct KindRowPresentation: Equatable { struct Bar { dimension; weight }; id; name; originLabel; statusLabel; isNew; openCount; bars; init(kind:isNew:openCount:); static func mergeTargets(for:in:) -> [TaskKind] }`
  - `struct FlightControlRoutingPane: View { init(routing:preferences:project:) }`, `struct RuleRow: View`
  - Accessibility identifiers: `routing-add-field-{global|project}`, `routing-add-{global|project}`, `routing-project-error`, `routing-rule-<id>`, `routing-sentence-<id>`, `routing-state-<id>`, `routing-compiled-<id>`, `routing-failure-<id>`, `routing-note-<id>`, `routing-hint-<id>`, `routing-hint-dismiss-<id>`, `routing-compile-<id>`, `routing-confirm-<id>`, `routing-up-<id>`, `routing-down-<id>`, `routing-delete-<id>`, `routing-compiler-agent`, `routing-compiler-model`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// What a rule row and a kind row show and allow, decided outside SwiftUI so it is tested here;
/// the views only lay it out (and `RoutingUITests` drives them).
final class RoutingPresentationTests: XCTestCase {
    private typealias D = RoutingTestData

    func testADraftCanCompileButNotConfirm() {
        let p = RuleRowPresentation(rule: RoutingRule(id: "r1", sentence: "x"), compiling: false, note: nil)
        XCTAssertEqual(p.stateLabel, "Draft")
        XCTAssertTrue(p.canCompile); XCTAssertFalse(p.canConfirm)
        XCTAssertNil(p.compiledText); XCTAssertNil(p.failureText)
    }

    func testACompiledRuleShowsItsFormAndWaitsForConfirm() {
        let rule = D.r3(state: .compiled)
        let p = RuleRowPresentation(rule: rule, compiling: false, note: nil)
        XCTAssertEqual(p.stateLabel, "Compiled — confirm to use")
        XCTAssertEqual(p.compiledText, RuleText.compiled(rule.compiled!))
        XCTAssertTrue(p.canConfirm); XCTAssertFalse(p.canCompile)
    }

    func testAConfirmedRuleOffersNeitherUntilItsSentenceChanges() {
        let p = RuleRowPresentation(rule: D.r3(), compiling: false, note: nil)
        XCTAssertEqual(p.stateLabel, "Confirmed")
        XCTAssertFalse(p.canCompile); XCTAssertFalse(p.canConfirm)
        XCTAssertNotNil(p.compiledText)
    }

    func testAFailedRuleSaysWhyAndCanBeRecompiled() {
        let rule = RoutingRule(id: "r1", sentence: "x", state: .failed, failure: "unknown dimension teleportation")
        let p = RuleRowPresentation(rule: rule, compiling: false, note: nil)
        XCTAssertEqual(p.stateLabel, "Failed")
        XCTAssertEqual(p.failureText, "Failed: unknown dimension teleportation")
        XCTAssertTrue(p.canCompile)
    }

    func testWhileCompilingNothingIsOffered() {
        let p = RuleRowPresentation(rule: RoutingRule(id: "r1", sentence: "x"), compiling: true, note: nil)
        XCTAssertEqual(p.stateLabel, "Compiling…")
        XCTAssertFalse(p.canCompile); XCTAssertFalse(p.canConfirm)
    }

    func testTheCompilerNoteRidesAlong() {
        let p = RuleRowPresentation(rule: RoutingRule(id: "r1", sentence: "x"), compiling: false, note: "Compiler unavailable: offline")
        XCTAssertEqual(p.note, "Compiler unavailable: offline")
    }

    func testKindRowsLabelOriginStatusAndBars() {
        let golden = KindRowPresentation(kind: D.golden, isNew: true, openCount: 3)
        XCTAssertEqual(golden.originLabel, "Planning")
        XCTAssertEqual(golden.statusLabel, "Merged into snapshot-tests")
        XCTAssertEqual(golden.bars.map(\.dimension), Dimensions.all.map(\.id), "one bar per dimension, in a fixed order, so rows compare")
        XCTAssertEqual(golden.bars.first { $0.dimension == "test-authoring" }?.weight, 0.8)
        XCTAssertEqual(golden.openCount, 3); XCTAssertTrue(golden.isNew)
        let tests = KindRowPresentation(kind: D.tests, isNew: false, openCount: 0)
        XCTAssertEqual(tests.originLabel, "Seed"); XCTAssertEqual(tests.statusLabel, "Active")
    }

    func testMergeTargetsAreOtherLiveKinds() {
        XCTAssertEqual(KindRowPresentation.mergeTargets(for: D.snapshot, in: D.kinds).map(\.id), ["tests", "algorithm", "docs"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=RoutingPresentationTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'RuleRowPresentation' in scope`.

- [ ] **Step 3: Implement `RoutingPresentation.swift`**

```swift
import Foundation
import IntakeKit

/// What one rule row shows and which buttons it enables.
struct RuleRowPresentation: Equatable {
    var stateLabel: String
    var compiledText: String?
    var failureText: String?
    var note: String?
    var canCompile: Bool
    var canConfirm: Bool

    /// A confirmed rule offers no Compile: recompiling the same words could silently change what
    /// routes. Editing the sentence is the way back to draft (spec §2).
    init(rule: RoutingRule, compiling: Bool, note: String?) {
        if compiling {
            stateLabel = "Compiling…"
        } else {
            switch rule.state {
            case .draft: stateLabel = "Draft"
            case .compiled: stateLabel = "Compiled — confirm to use"
            case .confirmed: stateLabel = "Confirmed"
            case .failed: stateLabel = "Failed"
            }
        }
        compiledText = rule.compiled.map(RuleText.compiled)
        failureText = rule.state == .failed ? rule.failure.map { "Failed: \($0)" } : nil
        self.note = note
        canCompile = !compiling && (rule.state == .draft || rule.state == .failed)
        canConfirm = !compiling && rule.state == .compiled
    }
}

/// What one kind row shows (spec §6).
struct KindRowPresentation: Equatable {
    struct Bar: Equatable {
        var dimension: String
        var weight: Double
    }

    var id: String
    var name: String
    var originLabel: String
    var statusLabel: String
    var isNew: Bool
    var openCount: Int
    var bars: [Bar]

    init(kind: TaskKind, isNew: Bool, openCount: Int) {
        id = kind.id.rawValue
        name = kind.name
        switch kind.origin {
        case .seed: originLabel = "Seed"
        case .planning: originLabel = "Planning"
        case .user: originLabel = "You"
        }
        switch kind.status {
        case .active: statusLabel = "Active"
        case .proposed: statusLabel = "Proposed"
        case .merged(let target): statusLabel = "Merged into \(target.rawValue)"
        }
        self.isNew = isNew
        self.openCount = openCount
        bars = Dimensions.all.map { Bar(dimension: $0.id, weight: kind.dimensions[$0.id] ?? 0) }
    }

    /// Live kinds other than this one. Not a merged kind: merging into one would build a chain
    /// (the registry refuses it anyway); not itself, which is meaningless.
    static func mergeTargets(for kind: TaskKind, in kinds: [TaskKind]) -> [TaskKind] {
        kinds.filter { other in
            guard other.id != kind.id else { return false }
            if case .merged = other.status { return false }
            return true
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=RoutingPresentationTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Implement `FlightControlRoutingPane.swift`**

```swift
import IntakeKit
import SwiftUI

/// Settings → Flight Control → Routing (spec L3-R §2, §3, §7): the project's rules — checked
/// first — then the global list. Each rule shows its sentence, its state, its compiled form in
/// plain words, and the buttons that move it on. `RoutingUITests` drives this pane.
struct FlightControlRoutingPane: View {
    @ObservedObject var routing: RoutingService
    @ObservedObject var preferences: PreferencesStore
    let project: String?
    @State private var newGlobal = ""
    @State private var newProject = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let project {
                    ruleList(title: "This project — checked first", scope: .project(project), draft: $newProject,
                             suffix: "project", error: routing.projectRulesError(project))
                }
                ruleList(title: "All projects", scope: .global, draft: $newGlobal, suffix: "global", error: nil)
                compilerFooter
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Loads the catalogs on open, so rule hints have something to compare against. Codex's
        // costs one app-server spawn per launch and is cached after that.
        .task { _ = await routing.catalogs() }
    }

    private func ruleList(title: String, scope: RuleScope, draft: Binding<String>, suffix: String, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let error {
                Text("routing.json could not be read, so these rules are not routing: \(error)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("routing-project-error")
            }
            let rules = routing.rules(scope)
            if rules.isEmpty && error == nil {
                Text("No rules yet.").foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                RuleRow(routing: routing, rule: rule, scope: scope)
            }
            HStack {
                TextField("Use Codex for unit and integration tests, and for complex algorithms", text: draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(draft, to: scope) }
                    .accessibilityIdentifier("routing-add-field-\(suffix)")
                Button("Add") { add(draft, to: scope) }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || error != nil)
                    .accessibilityIdentifier("routing-add-\(suffix)")
            }
        }
    }

    private func add(_ draft: Binding<String>, to scope: RuleScope) {
        if routing.addRule(draft.wrappedValue, to: scope) != nil { draft.wrappedValue = "" }
    }

    /// Which headless model compiles sentences (spec §3: "default `claude -p` haiku, configurable").
    private var compilerFooter: some View {
        HStack(spacing: 8) {
            Text("Rules compile with").foregroundStyle(.secondary)
            Picker("Agent", selection: Binding(get: { preferences.routingCompilerSettings.harness },
                                               set: { preferences.routingCompilerSettings.harness = $0 })) {
                Text("Claude").tag(Harness.claude)
                Text("Codex").tag(Harness.codex)
            }
            .labelsHidden()
            .frame(width: 110)
            .accessibilityIdentifier("routing-compiler-agent")
            TextField("Model", text: Binding(get: { preferences.routingCompilerSettings.model },
                                             set: { preferences.routingCompilerSettings.model = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .accessibilityIdentifier("routing-compiler-model")
            Spacer()
        }
        .font(.callout)
    }
}

/// One rule: its editable sentence, state, compiled form, failure or compiler note, hint, and
/// actions. The sentence commits on Return, which sends the rule back to draft (spec §2).
struct RuleRow: View {
    @ObservedObject var routing: RoutingService
    let rule: RoutingRule
    let scope: RuleScope
    @State private var editing: String?

    var body: some View {
        let p = RuleRowPresentation(rule: rule, compiling: routing.compiling.contains(rule.id), note: routing.notes[rule.id])
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Sentence", text: Binding(get: { editing ?? rule.sentence }, set: { editing = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                    .accessibilityIdentifier("routing-sentence-\(rule.id)")
                Text(p.stateLabel)
                    .font(.caption)
                    .foregroundStyle(color(rule.state))
                    .accessibilityIdentifier("routing-state-\(rule.id)")
            }
            if let text = p.compiledText {
                Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("routing-compiled-\(rule.id)")
            }
            if let failure = p.failureText {
                Text(failure).font(.callout).foregroundStyle(.red).accessibilityIdentifier("routing-failure-\(rule.id)")
            }
            if let note = p.note {
                Text(note).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("routing-note-\(rule.id)")
            }
            if let hint = routing.hint(for: rule, scope: scope) {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb")
                    Text(hint.text).accessibilityIdentifier("routing-hint-\(rule.id)")
                    Button("Dismiss") { routing.dismissHint(hint) }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("routing-hint-dismiss-\(rule.id)")
                }
                .font(.caption)
            }
            HStack {
                Button("Compile") { Task { await routing.compile(rule.id, in: scope) } }
                    .disabled(!p.canCompile)
                    .accessibilityIdentifier("routing-compile-\(rule.id)")
                Button("Confirm") { routing.confirm(rule.id, in: scope) }
                    .disabled(!p.canConfirm)
                    .accessibilityIdentifier("routing-confirm-\(rule.id)")
                Spacer()
                Button { routing.moveRule(rule.id, by: -1, in: scope) } label: { Image(systemName: "arrow.up") }
                    .help("Check this rule earlier")
                    .accessibilityIdentifier("routing-up-\(rule.id)")
                Button { routing.moveRule(rule.id, by: 1, in: scope) } label: { Image(systemName: "arrow.down") }
                    .help("Check this rule later")
                    .accessibilityIdentifier("routing-down-\(rule.id)")
                Button("Delete", role: .destructive) { routing.deleteRule(rule.id, in: scope) }
                    .accessibilityIdentifier("routing-delete-\(rule.id)")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routing-rule-\(rule.id)")
    }

    private func commit() {
        guard let edited = editing else { return }
        routing.editSentence(rule.id, edited, in: scope)
        editing = nil
    }

    private func color(_ state: RuleState) -> Color {
        switch state {
        case .draft: return .secondary
        case .compiled: return .orange
        case .confirmed: return .green
        case .failed: return .red
        }
    }
}
```

- [ ] **Step 6: Build and run the terminology guard**

Run: `FD_TEST_FILTER=TerminologyGuardTests,RoutingPresentationTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures` (the build compiles the pane; the guard scans its literals).

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/FlightControl/RoutingPresentation.swift Sources/FlightDeck/Preferences/UI/FlightControlRoutingPane.swift Tests/FlightDeckTests/FlightControlL3/Routing/RoutingPresentationTests.swift
git commit -m "feat: show routing rules with their compiled form, state and confirm button" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 19: The Task kinds pane and the Flight Control tab

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/TaskKindsPane.swift`
- Create: `Sources/FlightDeck/Preferences/UI/FlightControlSettingsTab.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/FlightControlTabTests.swift`

**Interfaces:**
- Consumes: Tasks 17 (`kinds(project:)`, `isNew`, `markSeen`, `rename`, `reweight`, `merge`, `openCounts`, `kindNote`), 18 (`KindRowPresentation`, `FlightControlRoutingPane`); `SessionStore.repos`.
- Produces:
  - `struct TaskKindsPane: View { init(routing:project:) }`
  - `struct FlightControlSettingsTab: View { enum Section: String, CaseIterable { routing = "Routing", kinds = "Task kinds"; var identifier } ; init(preferences:sessions:routing:) }`
  - Accessibility identifiers: `fc-section-routing`, `fc-section-kinds`, `fc-project-picker`, `kinds-error`, `kind-new-<id>`, `kind-status-<id>`, `kind-count-<id>`, `kind-rename-field`, `kind-rename-apply`, `kind-weight-<dimension>`, `kind-reweight-apply`, `kind-merge-picker`, `kind-merge-apply`, `kind-note`, `kind-error`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import FlightDeck

/// The tab's sections are what `RoutingUITests` clicks by identifier; renaming one silently
/// breaks every UI test, so the names are pinned here, where a rename fails fast and headless.
final class FlightControlTabTests: XCTestCase {
    func testTheTabHasRoutingThenTaskKinds() {
        XCTAssertEqual(FlightControlSettingsTab.Section.allCases.map(\.rawValue), ["Routing", "Task kinds"])
        XCTAssertEqual(FlightControlSettingsTab.Section.allCases.map(\.identifier), ["fc-section-routing", "fc-section-kinds"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=FlightControlTabTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'FlightControlSettingsTab' in scope`.

- [ ] **Step 3: Implement `TaskKindsPane.swift`**

```swift
import IntakeKit
import SwiftUI

/// Settings → Flight Control → Task kinds (spec L3-R §6), per project: each kind's origin,
/// status, weights as small bars and open-task count, with Rename, Re-weight and Merge into….
/// A planning-proposed kind is marked *new* until you open it. Re-weight and merge re-route the
/// kind's open, unpinned tasks; the summary shows under the list.
struct TaskKindsPane: View {
    @ObservedObject var routing: RoutingService
    let project: String?
    @State private var selection: KindID?
    @State private var renameText = ""
    @State private var weights: [String: Double] = [:]
    @State private var mergeTarget: KindID?
    @State private var counts: [KindID: Int] = [:]
    @State private var error: String?

    var body: some View {
        if let project {
            content(project)
        } else {
            ContentUnavailableView("No Project Selected", systemImage: "folder",
                                   description: Text("Pick a project to see its task kinds."))
        }
    }

    @ViewBuilder
    private func content(_ project: String) -> some View {
        switch routing.kinds(project: project) {
        case .unreadable(let why):
            Text(why)
                .foregroundStyle(.red)
                .padding(16)
                .accessibilityIdentifier("kinds-error")
        case .loaded(let kinds):
            VStack(alignment: .leading, spacing: 0) {
                HSplitView {
                    List(kinds, selection: $selection) { kind in
                        row(KindRowPresentation(kind: kind, isNew: routing.isNew(kind, project: project),
                                                openCount: counts[kind.id] ?? 0))
                    }
                    .frame(minWidth: 300, idealWidth: 340)
                    detail(kinds, project: project)
                        .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                footer
            }
            .onChange(of: selection) { _, new in
                guard let new, let kind = kinds.first(where: { $0.id == new }) else { return }
                routing.markSeen(new, project: project)
                renameText = kind.name
                weights = kind.dimensions
                mergeTarget = nil
                error = nil
            }
            .task(id: project) { counts = await routing.openCounts(project: project) }
        }
    }

    private func row(_ p: KindRowPresentation) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.name)
                    if p.isNew {
                        Text("new")
                            .font(.caption2.bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .accessibilityIdentifier("kind-new-\(p.id)")
                    }
                }
                Text("\(p.id) · \(p.originLabel) · \(p.statusLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("kind-status-\(p.id)")
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(p.bars, id: \.dimension) { bar in
                    Capsule()
                        .fill(Color.accentColor.opacity(bar.weight > 0 ? 0.75 : 0.15))
                        .frame(width: 4, height: max(2, 18 * bar.weight))
                        .help("\(bar.dimension) \(RuleText.number(bar.weight))")
                }
            }
            .frame(height: 18, alignment: .bottom)
            .accessibilityHidden(true)
            Text("\(p.openCount) open")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("kind-count-\(p.id)")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func detail(_ kinds: [TaskKind], project: String) -> some View {
        if let id = selection, let kind = kinds.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(kind.name).font(.headline)
                    Text(kind.description).font(.callout).foregroundStyle(.secondary)
                    GroupBox("Rename") {
                        HStack {
                            TextField("Name", text: $renameText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("kind-rename-field")
                            Button("Rename") { error = routing.rename(kind.id, to: renameText, project: project) }
                                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || renameText == kind.name)
                                .accessibilityIdentifier("kind-rename-apply")
                        }
                    }
                    GroupBox("Re-weight") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Dimensions.all, id: \.id) { d in
                                HStack {
                                    Text(d.id).font(.caption).frame(width: 170, alignment: .leading)
                                    Slider(value: weight(d.id), in: 0...1, step: 0.05)
                                        .accessibilityIdentifier("kind-weight-\(d.id)")
                                    Text(RuleText.number(weights[d.id] ?? 0))
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 34, alignment: .trailing)
                                }
                            }
                            Button("Re-weight") {
                                let next = weights.filter { $0.value > 0 }
                                Task {
                                    error = await routing.reweight(kind.id, dimensions: next, project: project)
                                    counts = await routing.openCounts(project: project)
                                }
                            }
                            .disabled(weights.filter { $0.value > 0 } == kind.dimensions)
                            .accessibilityIdentifier("kind-reweight-apply")
                        }
                    }
                    GroupBox("Merge into…") {
                        HStack {
                            Picker("Merge into", selection: $mergeTarget) {
                                Text("Choose…").tag(KindID?.none)
                                ForEach(KindRowPresentation.mergeTargets(for: kind, in: kinds)) { target in
                                    Text(target.name).tag(KindID?.some(target.id))
                                }
                            }
                            .labelsHidden()
                            .accessibilityIdentifier("kind-merge-picker")
                            Button("Merge") {
                                guard let target = mergeTarget else { return }
                                Task {
                                    error = await routing.merge(kind.id, into: target, project: project)
                                    mergeTarget = nil
                                    counts = await routing.openCounts(project: project)
                                }
                            }
                            .disabled(mergeTarget == nil)
                            .accessibilityIdentifier("kind-merge-apply")
                        }
                    }
                }
                .padding(16)
            }
        } else {
            Text("Select a kind to rename, re-weight or merge it.")
                .foregroundStyle(.secondary)
                .padding(16)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("kind-error")
            }
            if let note = routing.kindNote {
                Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("kind-note")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func weight(_ dimension: String) -> Binding<Double> {
        Binding(get: { weights[dimension] ?? 0 }, set: { weights[dimension] = $0 })
    }
}
```

- [ ] **Step 4: Implement `FlightControlSettingsTab.swift`**

```swift
import IntakeKit
import SwiftUI

/// Settings → Flight Control. L3-R's Routing and Task kinds live here; L3-I's Capability index
/// and L3-U's Capacity join them at integration. Sections are buttons along the top rather than
/// a nested `TabView`: a tab strip inside the Settings tab strip reads as two windows' chrome.
struct FlightControlSettingsTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case routing = "Routing"
        case kinds = "Task kinds"
        var id: String { rawValue }
        /// What `RoutingUITests` clicks.
        var identifier: String { self == .routing ? "fc-section-routing" : "fc-section-kinds" }
    }

    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @ObservedObject var routing: RoutingService
    @State private var section: Section = .routing
    @State private var project: String?

    /// Open projects (standardized the way the Projects pane spells them) plus the fixture's.
    private var paths: [String] {
        let open = sessions.repos.map(\.url.standardizedFileURL.path)
        return Array(Set(open).union(routing.fixtureProjects ?? [])).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ForEach(Section.allCases) { s in
                    Button(s.rawValue) { section = s }
                        .buttonStyle(.bordered)
                        .tint(section == s ? Color.accentColor : nil)
                        .accessibilityIdentifier(s.identifier)
                }
                Spacer()
                Picker("Project", selection: $project) {
                    Text("No project").tag(String?.none)
                    ForEach(paths, id: \.self) { p in
                        Text(URL(fileURLWithPath: p).lastPathComponent).tag(String?.some(p))
                    }
                }
                .frame(maxWidth: 260)
                .accessibilityIdentifier("fc-project-picker")
            }
            .padding(12)
            Divider()
            switch section {
            case .routing: FlightControlRoutingPane(routing: routing, preferences: preferences, project: project)
            case .kinds: TaskKindsPane(routing: routing, project: project)
            }
        }
        .onAppear {
            if project == nil { project = routing.fixtureProjects?.first ?? paths.first }
        }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=FlightControlTabTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/TaskKindsPane.swift Sources/FlightDeck/Preferences/UI/FlightControlSettingsTab.swift Tests/FlightDeckTests/FlightControlL3/Routing/FlightControlTabTests.swift
git commit -m "feat: add a Task kinds pane with rename, re-weight, merge and new badges" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 20: Wire routing into the app

**Files:**
- Create: `Sources/FlightDeck/FlightControl/RoutingService+Live.swift`
- Modify: `Sources/FlightDeck/Preferences/PreferencesTab.swift`
- Modify: `Sources/FlightDeck/Preferences/UI/PreferencesView.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (the lazy `intakeService` at ~:1321-1340)
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (properties :5-9; `init` :129-180; `makeStore` :214-298; `Settings` :311-313)
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingWiringTests.swift`

**Interfaces:**
- Consumes: Tasks 9, 13–19; L3-0 `RoutingCapabilityRegistry.standard()`, `.harnesses`, `.catalogs(enabled:)`; `LoginShellPath.repairing(_:)`, `SystemCommandRunner`.
- Produces:
  - `extension RoutingService { static func live(preferences:) -> RoutingService; static func make(preferences:) -> RoutingService }`
  - `PreferencesTab.flightControl`
  - `SessionStore.flightControlRouting: RoutingService?`
  - `PreferencesView(preferences:sessions:fleet:routing:)`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The app owns one `RoutingService`: Settings draws it, and intake release asks it for blocks
/// through the store. A store a test builds has none, and releases exactly as before Level 3.
@MainActor
final class RoutingWiringTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingWiringTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testTheStoresRoutingIsWhatIntakeReleaseAsks() {
        let store = SessionStore(provider: nil, persistence: nil, intakesRoot: root)
        XCTAssertNil(store.intakeService.encodeRouting())
        let routing = RoutingService.live(preferences: PreferencesStore(persistence: nil))
        store.flightControlRouting = routing
        XCTAssertTrue(store.intakeService.encodeRouting() === routing,
                      "resolved at release time, so routing attached after the service was built still counts")
    }

    func testFlightControlIsASettingsPane() {
        XCTAssertTrue(PreferencesTab.allCases.contains(.flightControl))
    }

    func testALiveServiceStartsEmptyAndIsNotTheFixture() {
        let svc = RoutingService.make(preferences: PreferencesStore(persistence: nil))
        XCTAssertEqual(svc.rules(.global), [])
        XCTAssertNil(svc.fixtureProjects)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=RoutingWiringTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build errors `type 'RoutingService' has no member 'live'` and `value of type 'SessionStore' has no member 'flightControlRouting'`.

- [ ] **Step 3: Implement `RoutingService+Live.swift`**

```swift
import Foundation
import IntakeKit

extension RoutingService {
    /// The routing a real launch runs: the standard adapter registry's catalogs for the agents in
    /// preferences, `<agent>-default` pools until L3-U's land, no capability index until L3-I's,
    /// the headless compiler preferences name, and `br` for re-routes. Building it spawns
    /// nothing; codex's catalog is fetched on first use.
    static func live(preferences: PreferencesStore) -> RoutingService {
        let registry = RoutingCapabilityRegistry.standard()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("FlightDeck-rule-compiler", isDirectory: true)
        return RoutingService(
            preferences: preferences,
            kindStore: KindRegistryStore(),
            makeCompiler: { [weak preferences] in
                RuleCompiler(runner: SystemCommandRunner(),
                             settings: preferences?.routingCompilerSettings ?? .default,
                             workDirectory: work,
                             baseEnvironment: { LoginShellPath.repairing(ProcessInfo.processInfo.environment) })
            },
            loadCatalogs: { [weak preferences] in
                await registry.catalogs(enabled: Set((preferences?.preferences.agents ?? []).map(\.id.harnessID)))
            },
            pools: DefaultPoolDirectory(harnesses: registry.harnesses),
            tasks: BrOpenTaskReader(),
            writer: BeadWriter(actor: "flightdeck-routing"))
    }

    /// The service `FlightDeckApp` builds.
    static func make(preferences: PreferencesStore) -> RoutingService {
        live(preferences: preferences)
    }
}
```

- [ ] **Step 4: Add the Settings tab**

In `PreferencesTab.swift`, add `case flightControl` after `case devices`.

In `PreferencesView.swift`, add after `@ObservedObject var fleet: FleetService`:

```swift
    @ObservedObject var routing: RoutingService
```

and after the Devices tab (before the `TabView`'s closing brace):

```swift
            FlightControlSettingsTab(preferences: preferences, sessions: sessions, routing: routing)
                .tabItem { Label("Flight Control", systemImage: "airplane") }
                .accessibilityIdentifier("prefs-flight-control")
                .tag(PreferencesTab.flightControl)
```

- [ ] **Step 5: Give the store its routing**

In `SessionStore.swift`, directly above `private(set) lazy var intakeService: IntakeService = {`, add:

```swift
    /// L3-R routing: rules, kinds, the compiler and the router. Attached by
    /// `FlightDeckApp.makeStore` right after this store is built; nil in every store a test builds
    /// directly, whose releases then write tasks with no execution block, as before Level 3.
    var flightControlRouting: RoutingService?
```

Inside that lazy closure, after the `let service = IntakeService(…)` statement and before
`intakeChangeForward = …`, add:

```swift
        // Resolved at each release, not captured now: this service is built lazily — often
        // before `FlightDeckApp` attaches routing — and must still see it.
        service.encodeRouting = { [weak self] in self?.flightControlRouting }
```

- [ ] **Step 6: Build it once in `FlightDeckApp`**

In `FlightDeckApp`:
- After `@StateObject private var fleet: FleetService`, add `@StateObject private var routing: RoutingService`.
- In `init()`, after `_preferences = StateObject(wrappedValue: preferences)`, add:

```swift
        // Eager like `preferences`, for the same reason: the Settings scene and the store need
        // the same instance. Building it spawns nothing.
        let routing = RoutingService.make(preferences: preferences)
        _routing = StateObject(wrappedValue: routing)
```

- Change `let deferredStore = DeferredOnce { Self.makeStore(preferences: preferences) }` to
  `let deferredStore = DeferredOnce { Self.makeStore(preferences: preferences, routing: routing) }`.
- Change `private static func makeStore(preferences: PreferencesStore) -> SessionStore {` to
  `private static func makeStore(preferences: PreferencesStore, routing: RoutingService) -> SessionStore {`,
  and directly before that function's final `return store`, add:

```swift
        // Intake release asks the store's routing for each created task's block (L3-R §4).
        store.flightControlRouting = routing
```

- Change the Settings scene's `PreferencesView(preferences: preferences, sessions: store, fleet: fleet)` to
  `PreferencesView(preferences: preferences, sessions: store, fleet: fleet, routing: routing)`.

- [ ] **Step 7: Run to verify it passes**

Run: `FD_TEST_FILTER=RoutingWiringTests,PreferencesTabTests,SessionStoreIntakeWiringTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/FlightControl/RoutingService+Live.swift Sources/FlightDeck/Preferences/PreferencesTab.swift Sources/FlightDeck/Preferences/UI/PreferencesView.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/FlightDeckApp.swift Tests/FlightDeckTests/FlightControlL3/Routing/RoutingWiringTests.swift
git commit -m "feat: route released tasks through the app's routing service and add Settings → Flight Control" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 21: UI-test fixture, XCUITests with screenshots, and their runner

**Files:**
- Create: `Sources/FlightDeck/FlightControl/RoutingUIFixture.swift`
- Modify: `Sources/FlightDeck/FlightControl/RoutingService+Live.swift` (`make`)
- Create: `UITests/FlightDeckUITests/RoutingUITests.swift`
- Create: `scripts/test-routing-ui.sh`
- Modify: `.gitignore` (add `scripts/.routing-ui.log`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Routing/RoutingUIFixtureTests.swift`

**Interfaces:**
- Consumes: Tasks 16–20; `ClaudeRoutingCatalog` (Task 9).
- Produces:
  - `@MainActor enum RoutingUIFixture { static var isActive: Bool; static func service(preferences:root:) -> RoutingService; static var catalogs: AdapterCatalogs }`
  - `struct FixtureRuleCompiler: RuleCompiling`, `struct FixtureHints: RuleHintSource`, `struct FixtureOpenTasks: OpenTaskReading`, `struct FixtureBlockWriter: BlockWriting`
  - Launch argument `-FlightDeckRoutingFixture YES` (honored only with `-FlightDeckResetState YES`)
  - `scripts/test-routing-ui.sh`

- [ ] **Step 1: Write the failing unit test for the fixture**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// `RoutingUITests` can only be as honest as the fixture under it. Real stores and the real
/// validator; only the model call, the catalogs and `br` are scripted.
@MainActor
final class RoutingUIFixtureTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingUIFixtureTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    func testTheFixtureProjectHasKindsAConfirmedRuleAndAHint() throws {
        let svc = RoutingUIFixture.service(preferences: PreferencesStore(persistence: nil), root: root)
        let project = try XCTUnwrap(svc.fixtureProjects?.first)
        guard case .loaded(let kinds) = svc.kinds(project: project) else { return XCTFail("fixture kinds did not load") }
        XCTAssertEqual(kinds.map(\.id), ["tests", "snapshot-tests", "golden-tests", "algorithm"])
        let rule = try XCTUnwrap(svc.rules(.project(project)).first)
        XCTAssertEqual(rule.state, .confirmed)
        XCTAssertNotNil(svc.hint(for: rule, scope: .project(project)))
    }

    func testTheFixtureCompilerGoesThroughTheRealValidator() async throws {
        let svc = RoutingUIFixture.service(preferences: PreferencesStore(persistence: nil), root: root)
        let a = try XCTUnwrap(svc.addRule("Use Codex for unit and integration tests, and for complex algorithms", to: .global))
        XCTAssertEqual(a, "r1", "RoutingUITests addresses rows by these ids")
        await svc.compile(a, in: .global)
        let compiled = try XCTUnwrap(svc.rules(.global).first?.compiled)
        XCTAssertTrue(RuleText.compiled(compiled).contains("codex · gpt-6-sol · effort high · pool codex-default"))
        let b = try XCTUnwrap(svc.addRule("Use Codex when a task needs teleportation", to: .global))
        await svc.compile(b, in: .global)
        XCTAssertEqual(svc.rules(.global).last?.failure, "unknown dimension teleportation")
    }

    func testTheFixtureIsOffUnlessBothFlagsAreSet() {
        XCTAssertFalse(RoutingUIFixture.isActive)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=RoutingUIFixtureTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'RoutingUIFixture' in scope`.

- [ ] **Step 3: Implement `RoutingUIFixture.swift`**

```swift
import Foundation
import IntakeKit

/// `-FlightDeckRoutingFixture YES`: Settings → Flight Control against fixed data, for
/// `RoutingUITests`. Honored only together with `-FlightDeckResetState YES`, whose nil
/// preferences persistence keeps the run hermetic, so a stray default cannot pose a project.
///
/// Real stores and the real validator; scripted I/O. The kinds and the project's rules are
/// written to a scratch project under the app's own temporary directory (the UI-test runner's
/// sandbox cannot write anywhere the app can read, so the app writes it). The compiler answers
/// from a script, the catalogs are fixed, and neither `br` nor a model ever runs.
@MainActor
enum RoutingUIFixture {
    static var isActive: Bool {
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "FlightDeckResetState") && defaults.bool(forKey: "FlightDeckRoutingFixture")
    }

    static func service(preferences: PreferencesStore,
                        root: URL = FileManager.default.temporaryDirectory
                            .appendingPathComponent("FlightDeck-routing-fixture", isDirectory: true)) -> RoutingService {
        try? FileManager.default.removeItem(at: root)
        let project = root.appendingPathComponent("fixture-project", isDirectory: true)
        try? FileManager.default.createDirectory(at: project.appendingPathComponent(".flightdeck", isDirectory: true),
                                                 withIntermediateDirectories: true)
        try? Data(kindsJSON.utf8).write(to: KindRegistryStore.fileURL(project: project))
        try? Data(routingJSON.utf8).write(to: ProjectRoutingStore.fileURL(project: project))
        var next = 0
        return RoutingService(preferences: preferences, kindStore: KindRegistryStore(),
                              makeCompiler: { FixtureRuleCompiler() },
                              loadCatalogs: { catalogs },
                              pools: DefaultPoolDirectory(harnesses: ["claude", "codex"]),
                              hints: FixtureHints(), tasks: FixtureOpenTasks(), writer: FixtureBlockWriter(),
                              fixtureProjects: [project.path],
                              makeRuleID: { next += 1; return "r\(next)" })
    }

    static var catalogs: AdapterCatalogs {
        AdapterCatalogs([
            AdapterCatalog(harness: "claude", models: ClaudeRoutingCatalog.models, knobSchema: ClaudeRoutingCatalog.knobSchema,
                           defaultModel: "opus", enabled: true),
            AdapterCatalog(harness: "codex",
                           models: [ModelEntry(id: "gpt-6.1-sol", displayName: "GPT-6.1-Sol", knobs: ["effort"]),
                                    ModelEntry(id: "gpt-6-sol", displayName: "GPT-6-Sol", knobs: ["effort"]),
                                    ModelEntry(id: "gpt-6-luna", displayName: "GPT-6-Luna", knobs: ["effort"])],
                           knobSchema: ["effort": ["low", "medium", "high", "xhigh", "max", "ultra"]],
                           defaultModel: "gpt-6.1-sol", enabled: true),
        ])
    }

    /// The same four kinds as L3-0's shared `kinds.json` fixture.
    static let kindsJSON = """
    {"v":1,"kinds":[
     {"id":"tests","name":"Tests","description":"Unit and integration tests","dimensions":{"test-authoring":0.9,"agentic-coding":0.4},"origin":"seed","status":"active","createdAt":"2026-10-04T18:00:00Z"},
     {"id":"snapshot-tests","name":"Snapshot tests","description":"Write or update snapshot/golden-file tests","dimensions":{"test-authoring":0.8,"agentic-coding":0.3},"origin":"planning","status":"active","createdAt":"2026-10-04T18:00:00Z"},
     {"id":"golden-tests","name":"Golden tests","description":"Duplicate of snapshot tests","dimensions":{"test-authoring":0.8},"origin":"planning","status":"merged:snapshot-tests","createdAt":"2026-10-04T18:00:00Z"},
     {"id":"algorithm","name":"Algorithm","description":"Non-trivial algorithms","dimensions":{"algorithmic-reasoning":0.9,"agentic-coding":0.3},"origin":"seed","status":"active","createdAt":"2026-10-04T18:00:00Z"}
    ]}
    """

    static let routingJSON = """
    {"v":1,"rules":[{"id":"p1","sentence":"Use Claude for docs","compiled":{"match":{"any":[{"dimension":"docs-prose","atLeast":0.5}]},"assign":{"harness":"claude","model":"opus","knobs":{},"pool":"claude-default"}},"state":"confirmed","compiledAt":"2026-10-04T18:00:00Z","compiler":{"harness":"claude","model":"haiku"}}]}
    """
}

/// Answers the way a compiler would; the real validator then decides. "teleport" names a
/// dimension that does not exist, which is how the UI test sees a failed rule.
struct FixtureRuleCompiler: RuleCompiling {
    var ref: CompilerRef { CompilerRef(harness: "claude", model: "haiku") }

    func propose(_ input: RuleCompilerInput) async -> RuleProposal {
        func term(_ d: String, _ t: Double) -> RuleCompilerWire.Term { .init(dimension: d, atLeast: t, kind: nil) }
        if input.sentence.localizedCaseInsensitiveContains("teleport") {
            return .wire(RuleCompilerWire(ok: true, reason: nil, mode: "any", terms: [term("teleportation", 0.5)],
                                          harness: "codex", model: "gpt-6-sol", modelDefaulted: false, knobs: [],
                                          pool: nil, fallbackPool: nil))
        }
        if input.sentence.localizedCaseInsensitiveContains("codex") {
            return .wire(RuleCompilerWire(ok: true, reason: nil, mode: "any",
                                          terms: [term("test-authoring", 0.5), term("algorithmic-reasoning", 0.6),
                                                  .init(dimension: nil, atLeast: nil, kind: "tests")],
                                          harness: "codex", model: "gpt-6-sol", modelDefaulted: false,
                                          knobs: [.init(name: "effort", value: "high")], pool: nil, fallbackPool: nil))
        }
        return .unavailable("the fixture compiler has no answer for this sentence")
    }
}

struct FixtureHints: RuleHintSource {
    private static let snapshot = Date(timeIntervalSince1970: 1_790_000_000)
    func hint(for rule: RoutingRule, kinds: [TaskKind], catalogs: AdapterCatalogs) -> RuleHint? {
        guard rule.id == "p1" else { return nil }
        return RuleHint(ruleID: "p1", text: "gpt-6-luna scores 0.14 higher on docs-prose (confidence 0.8)",
                        snapshotDate: Self.snapshot)
    }
}

struct FixtureOpenTasks: OpenTaskReading {
    func openTasks(project: String) async -> Result<[TaskContextRow], OpenTaskReadError> {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        func row(_ id: String, _ kind: KindID, _ harness: HarnessID, _ model: String, _ pool: PoolID) -> TaskContextRow {
            let block = ExecutionBlock(kind: kind, harness: harness, model: model, pool: pool,
                                       source: AssignmentSource(by: .default, reason: "fixture", at: at))
            return TaskContextRow(id: id, agentContext: try? ExecutionBlockCodec.encode(block, into: nil))
        }
        return .success([row("fx-1", "snapshot-tests", "claude", "opus", "claude-default"),
                         row("fx-2", "tests", "codex", "gpt-6-sol", "codex-default")])
    }
}

struct FixtureBlockWriter: BlockWriting {
    func writeBlock(_ block: ExecutionBlock, id: String, project: String) async -> BlockWriteOutcome { .written }
}
```

In `RoutingService+Live.swift`, replace `make`'s body with:

```swift
        RoutingUIFixture.isActive ? RoutingUIFixture.service(preferences: preferences) : live(preferences: preferences)
```

and its doc comment with "`live`, or the UI-test fixture under `-FlightDeckResetState YES -FlightDeckRoutingFixture YES`."

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=RoutingUIFixtureTests,RoutingWiringTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `with 0 failures`.

- [ ] **Step 5: Write the UI tests**

`UITests/FlightDeckUITests/RoutingUITests.swift`:

```swift
import XCTest

/// Settings → Flight Control against the app's routing fixture (`RoutingUIFixture`): add,
/// compile, confirm and fail a rule; dismiss a hint; the *new* badge, merge and rename on task
/// kinds — each with a screenshot attached (spec L3-R §9).
///
/// Skipped unless `TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1`. `scripts/smoke.sh` runs this whole UI
/// bundle, and these seize the foreground for a minute that gate should not pay. Run them with
/// `scripts/test-routing-ui.sh`, once — never in a loop.
final class RoutingUITests: XCTestCase {
    override func setUpWithError() throws {
        // Both spellings: `xcodebuild` forwards only `TEST_RUNNER_`-prefixed variables, and
        // whether the prefix survives depends on the toolchain (see `ScreenshotTests`).
        let env = ProcessInfo.processInfo.environment
        guard env["FLIGHTDECK_ROUTING_UI"] == "1" || env["TEST_RUNNER_FLIGHTDECK_ROUTING_UI"] == "1" else {
            throw XCTSkip("set TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1 (scripts/test-routing-ui.sh) to run")
        }
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckRoutingFixture", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared")
        return app
    }

    /// Located by content, like `TerminalSmokeTests.preferencesWindow`: the window holding the
    /// Agents tab button, because macOS titles the Settings window differently across releases.
    private func openFlightControl(_ app: XCUIApplication) -> XCUIElement {
        app.typeKey(",", modifierFlags: .command)
        let prefs = app.windows.containing(.button, identifier: "Agents").firstMatch
        XCTAssertTrue(prefs.waitForExistence(timeout: 10), "Settings never opened")
        prefs.buttons["Flight Control"].click()
        XCTAssertTrue(prefs.buttons["fc-section-routing"].waitForExistence(timeout: 5), "the Flight Control tab did not open")
        return prefs
    }

    private func shot(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitFor(_ element: XCUIElement, labelContains text: String, timeout: TimeInterval = 5,
                         file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "never showed \"\(text)\"; shows \"\(element.exists ? element.label : "nothing")\"",
                       file: file, line: line)
    }

    private func waitUntilGone(_ element: XCUIElement, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 5), .completed, message, file: file, line: line)
    }

    private func addGlobalRule(_ sentence: String, in prefs: XCUIElement) {
        prefs.buttons["fc-section-routing"].click()
        let field = prefs.textFields["routing-add-field-global"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(sentence)
        prefs.buttons["routing-add-global"].click()
    }

    func testAddCompileAndConfirmARule() {
        let prefs = openFlightControl(launch())
        addGlobalRule("Use Codex for unit and integration tests, and for complex algorithms", in: prefs)
        let state = prefs.staticTexts["routing-state-r1"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        waitFor(state, labelContains: "Draft")
        prefs.buttons["routing-compile-r1"].click()
        waitFor(state, labelContains: "Compiled")
        waitFor(prefs.staticTexts["routing-compiled-r1"], labelContains: "codex · gpt-6-sol · effort high · pool codex-default")
        shot(prefs, "routing-compiled")
        prefs.buttons["routing-confirm-r1"].click()
        waitFor(state, labelContains: "Confirmed")
        shot(prefs, "routing-confirmed")
    }

    func testACompileFailureShowsItsReason() {
        let prefs = openFlightControl(launch())
        addGlobalRule("Use Codex when a task needs teleportation", in: prefs)
        XCTAssertTrue(prefs.buttons["routing-compile-r1"].waitForExistence(timeout: 5))
        prefs.buttons["routing-compile-r1"].click()
        waitFor(prefs.staticTexts["routing-state-r1"], labelContains: "Failed")
        waitFor(prefs.staticTexts["routing-failure-r1"], labelContains: "unknown dimension teleportation")
        shot(prefs, "routing-failed")
    }

    func testARuleHintCanBeDismissed() {
        let prefs = openFlightControl(launch())
        prefs.buttons["fc-section-routing"].click()
        let hint = prefs.staticTexts["routing-hint-p1"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "the fixture project's confirmed rule carries a hint")
        waitFor(hint, labelContains: "gpt-6-luna")
        shot(prefs, "routing-hint")
        prefs.buttons["routing-hint-dismiss-p1"].click()
        waitUntilGone(hint, "a dismissed hint stays gone")
    }

    func testTaskKindsNewBadgeMergeAndRename() {
        let prefs = openFlightControl(launch())
        prefs.buttons["fc-section-kinds"].click()
        let badge = prefs.staticTexts["kind-new-snapshot-tests"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5), "a planning-proposed kind starts out new")
        shot(prefs, "kinds-new")
        prefs.staticTexts["Snapshot tests"].click()
        waitUntilGone(badge, "opening a kind clears its badge")

        prefs.popUpButtons["kind-merge-picker"].click()
        prefs.menuItems["Tests"].click()
        prefs.buttons["kind-merge-apply"].click()
        waitFor(prefs.staticTexts["kind-status-snapshot-tests"], labelContains: "Merged into tests")
        waitFor(prefs.staticTexts["kind-note"], labelContains: "Re-routed")
        shot(prefs, "kinds-merged")

        prefs.staticTexts["Algorithm"].click()
        let rename = prefs.textFields["kind-rename-field"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5))
        rename.click()
        rename.typeKey("a", modifierFlags: .command)
        rename.typeText("Algorithms and data structures")
        prefs.buttons["kind-rename-apply"].click()
        XCTAssertTrue(prefs.staticTexts["Algorithms and data structures"].waitForExistence(timeout: 5))
        shot(prefs, "kinds-renamed")
    }
}
```

- [ ] **Step 6: Write the runner script**

`scripts/test-routing-ui.sh` (then `chmod +x scripts/test-routing-ui.sh`):

```bash
#!/usr/bin/env bash
# Runs RoutingUITests ONLY: Settings → Flight Control against the routing fixture.
#
# Not part of smoke.sh, and that is deliberate — smoke.sh runs the whole UI bundle, and these
# tests skip there unless TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1. Like every UI test they seize the
# foreground and read keystrokes, so: one run per 120 s (throttle.sh), a 10 s warning first, and
# never in a loop. Screenshots land in DerivedData/routing-ui-shots.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

. scripts/throttle.sh

LOG="scripts/.routing-ui.log"
RESULT="DerivedData/routing-ui.xcresult"
SHOTS="DerivedData/routing-ui-shots"
: > "$LOG"
rm -rf "$RESULT" "$SHOTS"

# Window geometry only, exactly as smoke.sh does; never the whole defaults domain.
for key in "NSWindow Frame main" "NSWindow Frame com_apple_SwiftUI_Settings_window"; do
  defaults delete dev.flightdeck.FlightDeck "$key" 2>/dev/null || true
done

echo "[routing-ui] building… (full output → $LOG)"
if ! ./scripts/build.sh >>"$LOG" 2>&1; then
  echo "ROUTING UI FAIL: build failed — see $LOG"
  tail -n 30 "$LOG"
  exit 1
fi
xcodegen generate >>"$LOG" 2>&1

osascript -e 'display notification "Routing UI tests take the foreground in 10 seconds" with title "Flight Deck"' || true
echo "[routing-ui] taking the foreground in 10 s…"
sleep 10

set +e
TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1 xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -destination 'platform=macOS' -derivedDataPath DerivedData -resultBundlePath "$RESULT" \
  test -only-testing:FlightDeckUITests/RoutingUITests >>"$LOG" 2>&1
rc=$?
set -e

grep -E "Test Case '.*' (passed|failed|skipped)|XCTAssert|error:|\*\* TEST (SUCCEEDED|FAILED)" "$LOG" | tail -n 40 || true
if xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SHOTS" >>"$LOG" 2>&1; then
  echo "[routing-ui] screenshots → $SHOTS"
else
  echo "[routing-ui] could not export screenshots — see $LOG"
fi

if [ "$rc" -ne 0 ]; then
  echo "ROUTING UI FAIL (rc=$rc) — full log: $LOG"
  exit "$rc"
fi
echo "ROUTING UI PASS"
```

Add `scripts/.routing-ui.log` to `.gitignore`, beside `scripts/.smoke.log`.

- [ ] **Step 7: Run the UI tests once**

This takes the foreground for about a minute; the script warns 10 s ahead. Run it once:
`./scripts/test-routing-ui.sh`
Expected: four `Test Case '-[FlightDeckUITests.RoutingUITests test…]' passed` lines and
`ROUTING UI PASS`, then `[routing-ui] screenshots → DerivedData/routing-ui-shots`.

Then open each exported PNG with the Read tool (`ls DerivedData/routing-ui-shots/*.png`; the
names follow `manifest.json`) and check: the compiled line sits under its sentence, the failed
reason is red and readable, the hint row is one line, the kind rows show bars and counts, and
nothing is clipped at the 720×560 Settings size.

- If a query finds no element (SwiftUI sometimes exposes a `Picker` as `menuButtons` rather than
  `popUpButtons`, or a `Text` inside a list row under `cells`), add `print(prefs.debugDescription)`
  just before the failing line, run the script once more, fix the query's element type, and
  remove the print. Never change what a test asserts to get it green.
- Cap: three runs for this task. If it still fails, stop and report the failing line and the
  element tree.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/FlightControl/RoutingUIFixture.swift Sources/FlightDeck/FlightControl/RoutingService+Live.swift UITests/FlightDeckUITests/RoutingUITests.swift scripts/test-routing-ui.sh .gitignore Tests/FlightDeckTests/FlightControlL3/Routing/RoutingUIFixtureTests.swift
git commit -m "test: drive the Routing and Task kinds panes with XCUITest and attach screenshots" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 22: Full suite, spec deviations, FOLLOWUPS, merge readiness

**Files:**
- Modify: `docs/superpowers/specs/2026-10-04-flight-control-l3-routing-design.md` (append §12)
- Modify: `docs/FOLLOWUPS.md` (the "Level 3 'Operate'" entry)

- [ ] **Step 1: Run the whole unit suite**

Run: `./scripts/test-unit.sh 2>&1 | tee DerivedData/l3-r-unit.log | tail -5; rg -n "error:" DerivedData/l3-r-unit.log | head`
Expected: `** SHARDED UNIT RUN PASSED` and no `error:` lines. A failure in a test this branch did not
touch: run that class on master before blaming this branch, and report it either way.

- [ ] **Step 2: Run the terminology guard once more on its own**

Run: `FD_TEST_FILTER=TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -10`
Expected: `with 0 failures`.

- [ ] **Step 3: Record the deviations in the spec**

Append to `docs/superpowers/specs/2026-10-04-flight-control-l3-routing-design.md`:

```markdown
## 12. As built (deviations recorded while planning, 2026-10-04)

Plan: `docs/superpowers/plans/2026-10-04-flight-control-l3-r-routing.md`.

1. The create op carries the kind as `taskKind` (not `kind`, which is `addEdge`'s edge kind in the
   same flat op schema) and `kindProposal`; proposal weights travel as `[{dimension, weight}]`.
2. Contract gaps filled in this branch and flagged for integration: `PoolSummary` /
   `PoolDirectory` / `DefaultPoolDirectory` (`<agent>-default` pools until L3-U's store conforms)
   and `RuleHint` / `RuleHintSource` / `NoRuleHints` (until L3-I conforms). `NullCapabilityIndex`
   stands in for L3-I's index.
3. `RuleRouter.assign` (the contract's non-optional `Router.assign`) returns an empty-model block
   reading `unroutable: …` for an unroutable task; the codec refuses it. `RouterCore.assign`
   returns `RouteOutcome`; encode never writes an unroutable block.
4. Global rules compile against the seed kinds; project rules against the project registry.
5. An unclassified create (no kind, unknown id, or a proposal named only punctuation) routes as
   `implement-simple`, its reason prefixed `no kind from planning;`.
6. Claude's catalog is its `--model` aliases (opus first); codex's is `model/list` from a
   short-lived app-server, cached per launch; codex's knob schema is the union of its models'
   efforts.
7. A compiled rule always names a pool (the agent's default when the sentence names none).
8. Global rules are stored at `Preferences.flightControlRouting`; Settings gains a Flight Control
   tab with Routing and Task kinds sections. Rules can be reordered.
9. Kind re-routing runs on merge and re-weight over `br list --status open --json`; released
   tasks' edits carry no kind. `br update --agent-context` gets `--force` only when the new value
   is under half the old length (br 0.6.0 refuses that otherwise).
10. Routing UI tests run from `scripts/test-routing-ui.sh` and skip under `smoke.sh`.
11. Spill reasons say "exhausted", not "over hard limit": the router knows only that a pool was excluded.
```

- [ ] **Step 4: Update FOLLOWUPS**

In `docs/FOLLOWUPS.md`'s "**Level 3 "Operate" — DESIGNED (2026-10-04), not built.**" entry, add a
line after its first sentence:

```markdown
  **L3-R routing BUILT on branch `flight-control-l3-routing` (<sha>), not merged.** Rules →
  compile → confirm in Settings → Flight Control → Routing; encode-time kinds and proposals; the
  real `Router` and `KindRegistry`; Task kinds pane. Integration owes: L3-U's pool store
  conforming to `PoolDirectory`, L3-I's hints to `RuleHintSource` and its index replacing
  `NullCapabilityIndex`, and one Settings → Flight Control tab holding every branch's sections.
  The maintainer's checklist: compile a real sentence with haiku from Settings; release a planned intake and
  read one created task's `agent_context` with `br show`; merge a kind with an open task and see it
  re-routed. Not done: claude full model ids (aliases only).
```

Replace `<sha>` with the branch head's short sha before this commit (`git rev-parse --short HEAD`):
the last code commit, which is what integration will pick up.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-10-04-flight-control-l3-routing-design.md docs/FOLLOWUPS.md
git commit -m "docs: record the level 3 routing build and what integration still owes" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Merge readiness**

Run: `git diff master...HEAD -- vendor`
Expected: empty. If it is not, the worktree's vendor symlinks were committed; remove them from the
branch (`git rm --cached vendor/ghostty-artifacts vendor/boringssl-artifacts`, commit) before any
merge. Then follow `superpowers:finishing-a-development-branch`. Integration with L3-I/L3-U/L3-S is
its own branch (L3-0 §2); do not merge sibling branches here.

---

## Self-Review

**Spec coverage** (spec section → task):

| Spec | Where |
|---|---|
| §1 criterion 1 (sentence → compiled → confirm → routes) | Tasks 1, 6, 7, 16, 18, 21 (`testAddCompileAndConfirmARule`) |
| §1 criterion 2 (new kind routes without recompile) | Task 4 `testANewKindRoutesByDimensionWithoutARecompile`, Task 12 (n2) |
| §1 criterion 3 (block `source` says why) | Tasks 4–5 (reasons), 12 (`no kind from planning;`) |
| §1 criterion 4 (pinned never changed) | Task 5 `testAPinnedBlockNeverSpills`, Task 13 `testWriteBlockLeavesAPinnedBlockAlone`, Task 15 |
| §2 rule shape, `any`/`all`, merged kind terms, default model, `fallbackPool`, states, storage | Tasks 1, 2, 4, 6, 16 |
| §3 compiler (headless haiku, schema, inputs, validator, no auto-retry, plain-words, Confirm) | Tasks 6, 7, 8, 9, 18 |
| §4 encode (kinds in prompt, `taskKind`/`kindProposal`, proposal → registry, router, `--agent-context` merge) | Tasks 10, 11, 12, 13, 14 |
| §5 router steps 1–5, confidence floor, pool assignment | Task 4 |
| §5 when it runs: encode / launch (L3-S via `Router`) / merge+re-weight | Tasks 14, 5 (`RuleRouter`), 15, 17 |
| §5 spill (fallback first, never pinned, never rewrites) | Task 5 |
| §6 Task kinds pane (origin, status, bars, counts, rename, re-weight, merge, new badge) | Tasks 17, 18, 19, 21 |
| §7 hints (one dismissible, until snapshot changes) | Tasks 2, 4 (seam), 16, 18, 21 |
| §8 unroutable, compiler unavailable, invalid `routing.json` | Tasks 5, 7, 16, 2 |
| §9 router table tests, compiler fixtures + live, encode, UI with screenshots | Tasks 4–5, 7–8, 12–14, 21 |
| §10 provides at integration | Tasks 5, 3, 13, 18–20 |

**Placeholder scan:** every step carries the code or command it needs; the only deferred value is
the commit sha in Task 22 Step 4, which the step tells how to fill. No "TBD", no "similar to".

**Type consistency vs L3-0:** used exactly as the contract plan defines them — `HarnessID`,
`PoolID`, `KindID` (+ `normalized`), `ExecutionBlock` (`kind`/`source` mutable), `AssignmentSource`
(`by`, `ruleId`, `reason`, `at`), `ExecutionBlockCodec.decode(agentContext:)` /
`encode(_:into:)`, `ExecutionBlockError.message`, `TaskKind`, `KindStatus.merged(into:)`,
`KindOrigin`, `KindValidationError`, `KindResolution.resolve`, `SeedKinds.all(createdAt:)`,
`KindRegistryFile`, `Dimensions.all/isKnown`, `ModelEntry`, `AdapterCatalog`, `AdapterCatalogs`
(`byHarness`, `order`, `contains`, `knobsValid`, `enabledModels`), `ModelRef`, `Assignment`,
`ScoredModel`, `KindRegistry` (`kinds(project:) throws`, `propose(_:project:) throws -> TaskKind`),
`Router` (`assign(kind:project:catalogs:now:)`, `spill(_:kind:project:exhausted:catalogs:now:)`),
`CapabilityIndex` (`rank(kind:candidates:)`, `snapshotDate`), `RoutingCapability`,
`AgentRoutingCapabilities`, `RoutingCapabilityRegistry` (`standard()`, `harnesses`,
`catalogs(enabled:)`), `AgentID.harnessID`, and the fakes `FakeKindRegistry` (`byProject`),
`FakeCapabilityIndex` (`scores`), `FakeRouter` (`defaultAssignment`, `assignCalls`),
`FakeRoutingCapabilities` (`harness`, `catalog`, `knobSchema`), `L3Fixtures.data(_:)`. No contract
type is redefined. New L3-R-only types are named in each task's Interfaces and defined in that task.

**Facts verified while planning:** `br list --json` envelope shape and `br show --json` array
shape, `br update --agent-context` shrink refusal (exit 4) on br 0.6.0; codex-cli 0.160.0
`model/list` shape and contents; `test-unit.sh`'s filtered-run output. **Not verified:** that the
real `claude -p --json-schema` haiku answer carries `structured_output` for this schema (Task 8
probes it); the exact XCUITest element types SwiftUI exposes for the merge `Picker` and list-row
`Text` (Task 21 Step 7 says how to adjust); that L3-0 merged with the stub text Task 9 Step 1
greps for.
