# Flight Control Coverage × Fidelity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cross-check Refine rounds run Codex and Claude over the same plan. A blind integrator clusters their proposals, and a Chapman capture–recapture estimate becomes a COVERAGE band on the LCD, checked against a per-fidelity target, with suggestions only.

**Architecture:** Every fold and decision is pure `IntakeKit` code:
- `TapePlanner` flags cross-check rounds.
- `RoundExecutor.refine` runs two reviewers and a clustered integrate.
- `CoverageSeries` folds `crosscheck.json` + `verdicts.json` into readings, bands and a verdict.

The app reads the result like the convergence series: folded off-main in `IntakeService`, shown by `LCDModel` / `CoverageCellModel` / `CoverageCard`.

**Tech Stack:** Swift 5 mode (`SWIFT_VERSION: "5.0"`, deliberate), SwiftUI/AppKit, XCTest, xcodegen.

**Spec:** `docs/superpowers/specs/2026-09-29-flight-control-coverage-design.md`. Read it first; section numbers below (§N) refer to it.

## Global Constraints

- **Work in a worktree** named `coverage` (`superpowers:using-git-worktrees`). Symlink `vendor/{boringssl,ghostty,fd-abduco}-artifacts` from the main checkout, and **never commit those symlinks** (`git diff --cached --stat -- vendor` must be empty before every commit).
- **Use the built-in Edit/Write in the worktree, never the quillmap mutators.** They report success while writing to the main checkout.
- **Tests:** `./scripts/test-unit.sh` takes about 8 minutes, always runs the full suite, and **exits 0 even on failure**. Read the final `** SHARDED UNIT RUN PASSED|FAILED **` line. Run it in the **foreground**. Do not pass `-only-testing:` (ignored).
- **Every new test must fail against the unchanged code before the fix** (house rule). Never weaken an assertion to go green.
- **No live model seats in tests.** Use `ScriptedHarnessRunner` (`Tests/FlightDeckTests/Intake/RoundExecutorTests.swift`). Never touch `RoundsLiveProbeTests` or `scripts/test-codex-live.sh`.
- **Never launch any app bundle**, from DerivedData or anywhere. UI is verified by render tests only.
- **The larkOS intake is read-only:** `~/Library/Application Support/Flight Deck/intakes/7C3A9E52-4B1D-4F08-9A6E-2D5B8C1F0E47/`.
- **User-facing words:** "agent" (never seat), "task" (never bead), "Flight Control". `TerminologyGuardTests` enforces this over `Sources/FlightDeck` and `Sources/IntakeKit`.
- **Comments explain *why* and name the failure they prevent** (house style, `docs/CONVENTIONS.md`).
- **Commits:** lowercase imperative behavioral subject (`feat: cross-check refine rounds with a second reviewer family`). The body covers mechanism and rejected alternatives. Trailer: `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Commit only your files, by path.
- **Every threshold is a named placeholder** in `CoverageThresholds` / `CoverageTargets`, with a doc comment saying it has not been fitted to real tapes (the `ConvergenceThresholds` precedent).
- **Old data never reads as 0:** a missing `crosscheck.json`, `verdicts.json` or config field means "no reading" / "unmeasured" / `.off`.
- **Band words (exact):** `SATURATED`, `FEW LEFT`, `MANY LEFT`, `NO OVERLAP`, `STALLED`. Short forms: `SAT`, `FEW`, `MANY`, `NONE`, `STALL`.

## Review Focus

1. **An `intake.json` / `tape.json` written before this change** (no `crossCheck`, `crossReviewer`, `PlannedRound.crossCheck`) must decode and run exactly as before. The test lives in Task 1.
2. **An integrator that returns junk `clusters`** (an index out of range, an index in two clusters, a lone singleton, an empty array, or the key missing in a counts-only reply) must clean to a valid partition or `nil`, and never pause the round. Tests are in Task 2 (cleaning) and Task 3 (no pause).
3. **A cross-check round where one reviewer proposes nothing, or both do.** With nothing to integrate the integrator is skipped (today's rule). `crosscheck.json` is still written. The fold must treat `found == 0` as SATURATED and never divide by zero. Tests are in Task 3 and Task 5.
4. **A retry of a paused cross-check round.** Run directories are reused (`attempt` deletes and recreates them). The blind order must be the same on retry: it is seeded by checkpoint id, not by randomness. The test lives in Task 2.
5. **Extending Refine while the last planned round is running.** Round N was started as a cross-check. The new last round N+1 must also be flagged. N's flag must not change retroactively, since it comes from `roundInProgress`. The test lives in Task 1.

---

## File map

| File | Change | Responsibility |
|---|---|---|
| `Sources/IntakeKit/RoundConfig.swift` | modify | `CrossCheckPolicy`, `RoundConfig.crossReviewer` / `.crossCheck`, `ModelFamily`, preset defaults |
| `Sources/IntakeKit/Tape.swift` | modify | `PlannedRound.crossCheck` + tolerant decode |
| `Sources/IntakeKit/TapePlanner.swift` | modify | flag cross-check rounds in `sequence` |
| `Sources/IntakeKit/CrossCheck.swift` | **create** | `CrossCheckRecord`, `BlindOrder`, cluster cleaning |
| `Sources/IntakeKit/RoundPrompts.swift` | modify | `IntegrateOutput.clusters`, `RoundSchemas.integrateClustered`, `integrate(…clustered:)` |
| `Sources/IntakeKit/RoundExecutor.swift` | modify | the cross-check branch of `refine` |
| `Sources/IntakeKit/ConvergenceSeries.swift` | modify | `Fingerprint` internal + `sameIssue`; cross-check point uses the issue count |
| `Sources/IntakeKit/CoverageSeries.swift` | **create** | readings, Chapman, bands, correlation, targets, verdict, suggested action |
| `Sources/FlightDeck/Intake/IntakeService.swift` | modify | fold coverage beside convergence |
| `Sources/FlightDeck/Intake/Planning/CoverageCellModel.swift` | **create** | cell + card text |
| `Sources/FlightDeck/Intake/Planning/CoverageViews.swift` | **create** | `CoverageCard` |
| `Sources/FlightDeck/Intake/Planning/LCDModel.swift`, `ControlBar.swift`, `IntakeDetailView.swift` | modify | the COVERAGE cell and its hover card |
| `Sources/FlightDeck/Intake/Planning/BoardModel.swift`, `ConvergenceViews.swift`, `LiveCard.swift`, `FinishedRoundsModel.swift`, `UIText.swift` | modify | ×2 marks, hollow point, cross-check agent row |
| `Sources/FlightDeck/Intake/RoundConfigEditor.swift` | modify | the Cross-check inspector row + summary |
| `docs/FOLLOWUPS.md`, `docs/HANDOFF.md`, `docs/FLIGHT-CONTROL-COVERAGE-HANDOFF.md` | modify | status + deferred list |

---

### Task 1: Cross-check policy, preset defaults and planned-round flags

**Files:**
- Modify: `Sources/IntakeKit/RoundConfig.swift`, `Sources/IntakeKit/Tape.swift:180-189`, `Sources/IntakeKit/TapePlanner.swift:15-50`
- Test: `Tests/FlightDeckTests/Intake/RoundConfigTests.swift`, `Tests/FlightDeckTests/Intake/TapePlannerTests.swift`

**Interfaces:**
- Produces:
  - `public enum CrossCheckPolicy: String, Codable, Sendable, CaseIterable { case off, firstAndLast, every }`
  - `RoundConfig.crossReviewer: Slot?`, `RoundConfig.crossCheck: CrossCheckPolicy?`
  - `RoundConfig.crossChecks: Bool` (computed: policy ≠ off ∧ reviewer ∧ crossReviewer ∧ different families)
  - `public enum ModelFamily: String, Codable, Sendable { case codex, claude }` with `init(_ harness: Harness)` and `var displayName: String` ("Codex" / "Claude")
  - `PlannedRound.crossCheck: Bool` (init param `crossCheck: Bool = false`)

- [ ] **Step 1: Write the failing tests**

In `RoundConfigTests.swift`, add:

```swift
    // MARK: - Cross-check (coverage spec §3)

    func testCrossCheckDefaultsPerPreset() throws {
        let sketch = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: .defaults))
        XCTAssertEqual(sketch.crossCheck, .off)
        XCTAssertEqual(sketch.crossReviewer?.choice.harness, .claude)
        XCTAssertNil(sketch.crossReviewer?.fallback, "a same-family fallback is not a cross-check")
        for preset in [Preset.featurePlan, .fullPlan] {
            let cfg = try XCTUnwrap(PresetExpansion.config(for: preset, available: .defaults))
            XCTAssertEqual(cfg.crossCheck, .firstAndLast, "\(preset)")
            XCTAssertEqual(cfg.crossReviewer?.choice.harness, .claude, "\(preset)")
            XCTAssertTrue(cfg.crossChecks, "\(preset)")
        }
    }

    func testSingleHarnessNeverCrossChecks() throws {
        for available in [codexOnly, claudeOnly] {
            let cfg = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: available))
            XCTAssertNil(cfg.crossReviewer)
            XCTAssertNil(cfg.crossCheck)
            XCTAssertFalse(cfg.crossChecks)
        }
    }

    func testSameFamilyCrossReviewerDoesNotCrossCheck() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        cfg.crossReviewer = cfg.reviewer
        XCTAssertFalse(cfg.crossChecks)
    }

    /// An intake.json written before cross-checks existed decodes to "off" (Review Focus 1).
    func testOldConfigDecodesWithCrossCheckOff() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: IntakeJSON.encoder.encode(cfg)) as? [String: Any])
        dict.removeValue(forKey: "crossCheck"); dict.removeValue(forKey: "crossReviewer")
        let old = try IntakeJSON.decoder.decode(RoundConfig.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertNil(old.crossCheck)
        XCTAssertFalse(old.crossChecks)
    }

    func testModelFamilyFollowsHarness() {
        XCTAssertEqual(ModelFamily(.codex), .codex)
        XCTAssertEqual(ModelFamily(.claude).displayName, "Claude")
    }
```

In `TapePlannerTests.swift`:
- **Update** `testFeaturePlanSequence` so refine rounds 1 and 3 carry `crossCheck: true`:
  `PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true)`, round 2 unchanged,
  `PlannedRound(stage: .refine, round: 3, major: true, crossCheck: true)`.
- **Update** `testFullPlanSequence` the same way: rounds 1 and 5 carry the flag.
- Leave `testSketchSequence` unchanged (policy off).

Then add:

```swift
    // MARK: - Cross-check flags (coverage spec §3)

    private func refineFlags(_ config: RoundConfig, extra: Int = 0) -> [Int: Bool] {
        let rounds = walk(config, extraRefinement: extra).rounds.filter { $0.stage == .refine }
        return Dictionary(uniqueKeysWithValues: rounds.map { ($0.round, $0.crossCheck) })
    }

    func testCrossCheckPolicies() throws {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertEqual(refineFlags(cfg), [1: true, 2: false, 3: true])
        cfg.crossCheck = .every
        XCTAssertEqual(refineFlags(cfg), [1: true, 2: true, 3: true])
        cfg.crossCheck = .off
        XCTAssertEqual(refineFlags(cfg), [1: false, 2: false, 3: false])
        cfg.crossCheck = nil
        XCTAssertEqual(refineFlags(cfg), [1: false, 2: false, 3: false])
        cfg.crossCheck = .firstAndLast; cfg.refinementCap = 1
        XCTAssertEqual(refineFlags(cfg), [1: true])
    }

    /// Extend moves "last": the new last round cross-checks (spec §3), and the old last does not.
    func testExtendMovesTheLastCrossCheck() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertEqual(refineFlags(cfg, extra: 1), [1: true, 2: false, 3: false, 4: true])
        XCTAssertEqual(refineFlags(cfg, extra: -1), [1: true, 2: true])
    }

    /// A round already started keeps the flag it started with: `roundInProgress` is persisted
    /// (Review Focus 5). An extend landing mid-round flags the NEW last round too.
    func testExtendMidRoundKeepsTheRunningRoundsFlag() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        var tape = walk(cfg).tape
        tape.checkpoints.removeAll { $0.stage == .refine && $0.round == 3 || [.encode, .polish].contains($0.stage) }
        let running = try XCTUnwrap(TapePlanner.next(after: tape, config: cfg))
        XCTAssertEqual(running.round, 3); XCTAssertTrue(running.crossCheck)
        tape.roundInProgress = running
        tape.extraRefinement = 1
        let data = try IntakeJSON.encoder.encode(tape)
        XCTAssertEqual(try IntakeJSON.decoder.decode(Tape.self, from: data).roundInProgress?.crossCheck, true)
        tape.checkpoints.append(Checkpoint(id: tape.checkpoints.count + 1, stage: .refine, round: 3, major: false, createdAt: Date()))
        XCTAssertEqual(TapePlanner.next(after: tape, config: cfg)?.crossCheck, true)
    }

    func testOldPlannedRoundDecodesWithoutCrossCheck() throws {
        let old = #"{"stage":"refine","round":2,"major":false}"#
        XCTAssertFalse(try IntakeJSON.decoder.decode(PlannedRound.self, from: Data(old.utf8)).crossCheck)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: a build failure (`crossCheck` / `CrossCheckPolicy` / `ModelFamily` undefined). That counts as the failing state for new API.

- [ ] **Step 3: Implement**

In `RoundConfig.swift`, add these above `RoundConfig`:

```swift
/// Which Refine rounds a second model family reviews in parallel (coverage spec §3). Synthesis
/// never does: the synthesizer merges drafts rather than searching the plan for problems, so its
/// proposals are not a review sample.
public enum CrossCheckPolicy: String, Codable, Sendable, CaseIterable { case off, firstAndLast, every }

/// A model's vendor lineage — what "cross-family" and coverage are counted over. Derived from the
/// harness today; a later harness (Gemini, Grok, Qwen) adds a case here and nothing else changes.
public enum ModelFamily: String, Codable, Sendable {
    case codex, claude
    public init(_ harness: Harness) {
        switch harness {
        case .codex: self = .codex
        case .claude: self = .claude
        }
    }
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}
```

In `RoundConfig`, add these after `customized`:

```swift
    /// The second family's reviewer on cross-check rounds. No fallback, ever: its fallback
    /// would be the primary's family, and a same-family "cross-check" is not independent.
    /// Optional so an `intake.json` written before cross-checks decodes unchanged.
    public var crossReviewer: Slot?
    /// nil reads as `.off` — every intake from before this existed, larkOS included.
    public var crossCheck: CrossCheckPolicy?

    /// Whether any round can cross-check: a policy, both reviewers, and two different families.
    public var crossChecks: Bool {
        guard let policy = crossCheck, policy != .off, let reviewer, let crossReviewer else { return false }
        return ModelFamily(reviewer.choice.harness) != ModelFamily(crossReviewer.choice.harness)
    }
```

Extend `init` with trailing `crossReviewer: Slot? = nil, crossCheck: CrossCheckPolicy? = nil` and assign both. The synthesized `Codable` decodes a missing optional as nil, so no custom decoder is needed.

In `PresetExpansion.config`, pass these to each case:
- `.sketch`: `crossReviewer: hasFallback ? Slot(b) : nil, crossCheck: hasFallback ? .off : nil`
- `.featurePlan` / `.fullPlan`: `crossReviewer: hasFallback ? Slot(b) : nil, crossCheck: hasFallback ? .firstAndLast : nil`

In `Tape.swift`, replace `PlannedRound` with:

```swift
public struct PlannedRound: Codable, Equatable, Sendable {
    public var stage: Stage
    public var round: Int
    public var major: Bool
    /// Refine only: a second model family reviews this round's plan too (coverage spec §3).
    /// Decided when the round starts and persisted in `Tape.roundInProgress`, so a later extend
    /// can't change what a running round is doing.
    public var crossCheck: Bool
    public init(stage: Stage, round: Int, major: Bool, crossCheck: Bool = false) {
        self.stage = stage
        self.round = round
        self.major = major
        self.crossCheck = crossCheck
    }

    private enum CodingKeys: String, CodingKey { case stage, round, major, crossCheck }

    /// A `roundInProgress` written before cross-checks has no `crossCheck`: it wasn't one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decode(Stage.self, forKey: .stage)
        round = try c.decode(Int.self, forKey: .round)
        major = try c.decode(Bool.self, forKey: .major)
        crossCheck = try c.decodeIfPresent(Bool.self, forKey: .crossCheck) ?? false
    }
}
```

In `TapePlanner.sequence`, replace the refine loop with:

```swift
        let refineTotal = config.reviewer != nil ? config.refinementCap + extraRefinement : 0
        if refineTotal > 0 {
            for round in 1...refineTotal {
                seq.append(PlannedRound(stage: .refine, round: round, major: round == refineTotal,
                                        crossCheck: crossChecks(round, of: refineTotal, config)))
            }
        }
```

and add:

```swift
    /// "Last" is the last round as the sequence stands now, so an extend makes the new last round
    /// a cross-check: "one more round" also means "measure coverage again" (coverage spec §3, §7).
    private static func crossChecks(_ round: Int, of total: Int, _ config: RoundConfig) -> Bool {
        guard config.crossChecks, let policy = config.crossCheck else { return false }
        switch policy {
        case .off: return false
        case .firstAndLast: return round == 1 || round == total
        case .every: return true
        }
    }
```

`IntakeRunner.startRound` persists `next`, which is already the `TapePlanner.next` value with the flag. Check `IntakeRunner.swift:326-360`: if anything rebuilds a `PlannedRound` field-by-field, pass `crossCheck` through.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `** SHARDED UNIT RUN PASSED **`. If other suites compared whole Feature/Full plan `PlannedRound` values (`rg -n "PlannedRound\(stage: .refine" Tests`), update those expectations to carry the flag. Never drop a comparison.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/RoundConfig.swift Sources/IntakeKit/Tape.swift Sources/IntakeKit/TapePlanner.swift Tests/FlightDeckTests/Intake/RoundConfigTests.swift Tests/FlightDeckTests/Intake/TapePlannerTests.swift
git diff --cached --stat -- vendor   # must print nothing
git commit -m "feat: plan cross-check refine rounds from a per-preset policy"
```

---

### Task 2: Cross-check record, blind order and the clustered integrate contract

**Files:**
- Create: `Sources/IntakeKit/CrossCheck.swift`
- Modify: `Sources/IntakeKit/RoundPrompts.swift` (`IntegrateOutput`, `RoundSchemas`, `RoundPrompts.integrate`)
- Test: create `Tests/FlightDeckTests/Intake/CrossCheckTests.swift`; modify `Tests/FlightDeckTests/Intake/RoundPromptsTests.swift`

**Interfaces:**
- Consumes: `ModelFamily` (Task 1)
- Produces:
  - `public struct CrossCheckRecord: Codable, Equatable, Sendable { proposers: [Int]; families: [ModelFamily]; clusters: [[Int]]?; blindOrderSeed: Int }` with `static let fileName = "crosscheck.json"`
  - `public enum BlindOrder { static func interleave(_ a: [ProposedChange], _ b: [ProposedChange], seed: Int) -> (changes: [ProposedChange], proposers: [Int]) }`
  - `public enum IssueClusters { static func clean(_ raw: [[Int]]?, count: Int) -> [[Int]]?; static func partition(_ clusters: [[Int]]?, count: Int) -> [[Int]] }`
  - `IntegrateOutput.clusters: [[Int]]?`, `RoundSchemas.integrateClustered`, `RoundPrompts.integrate(planFile:changesFile:humanEdits:clustered:)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/Intake/CrossCheckTests.swift`:

```swift
import XCTest
import IntakeKit

/// The pieces a cross-check round stores and hands the integrator (coverage spec §4).
final class CrossCheckTests: XCTestCase {
    private func changes(_ tag: String, _ n: Int) -> [ProposedChange] {
        (0..<n).map { ProposedChange(section: "## S", rationale: "\(tag)\($0)", edit: "e") }
    }

    func testInterleaveKeepsEveryProposalAndRecordsItsProposer() {
        let (merged, proposers) = BlindOrder.interleave(changes("a", 3), changes("b", 2), seed: 7)
        XCTAssertEqual(merged.count, 5)
        XCTAssertEqual(proposers.filter { $0 == 0 }.count, 3)
        XCTAssertEqual(proposers.filter { $0 == 1 }.count, 2)
        for (change, p) in zip(merged, proposers) { XCTAssertTrue(change.rationale.hasPrefix(p == 0 ? "a" : "b")) }
    }

    /// A retried round must hand the integrator the same order (Review Focus 4).
    func testInterleaveIsDeterministicPerSeedAndVariesAcrossSeeds() {
        let a = BlindOrder.interleave(changes("a", 6), changes("b", 6), seed: 3)
        XCTAssertEqual(a.proposers, BlindOrder.interleave(changes("a", 6), changes("b", 6), seed: 3).proposers)
        XCTAssertNotEqual(a.proposers, BlindOrder.interleave(changes("a", 6), changes("b", 6), seed: 4).proposers)
        // Blind means not grouped: A's proposals must not simply all come first.
        XCTAssertNotEqual(a.proposers, [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1])
    }

    func testInterleaveWithAnEmptySide() {
        XCTAssertEqual(BlindOrder.interleave([], changes("b", 2), seed: 1).proposers, [1, 1])
        XCTAssertEqual(BlindOrder.interleave([], [], seed: 1).changes, [])
    }

    /// Review Focus 2: junk clusters clean to a valid partition's non-singletons, or nil.
    func testCleaningClusters() {
        XCTAssertEqual(IssueClusters.clean([[0, 3], [1, 9], [3, 2], [4]], count: 5), [[0, 3]])
        XCTAssertEqual(IssueClusters.clean([[2, 1, 1]], count: 3), [[1, 2]])
        XCTAssertNil(IssueClusters.clean([], count: 3))
        XCTAssertNil(IssueClusters.clean(nil, count: 3))
        XCTAssertNil(IssueClusters.clean([[7, 8]], count: 3))
    }

    func testPartitionAddsSingletons() {
        XCTAssertEqual(IssueClusters.partition([[0, 3]], count: 5), [[0, 3], [1], [2], [4]])
        XCTAssertEqual(IssueClusters.partition(nil, count: 2), [[0], [1]])
    }

    func testRecordRoundTrips() throws {
        let r = CrossCheckRecord(proposers: [0, 1], families: [.codex, .claude], clusters: nil, blindOrderSeed: 4)
        let data = try IntakeJSON.encoder.encode(r)
        XCTAssertEqual(try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: data), r)
        XCTAssertEqual(CrossCheckRecord.fileName, "crosscheck.json")
    }
}
```

In `RoundPromptsTests.swift`, add these beside the existing integrate tests (around line 37 and line 233):

```swift
    func testIntegrateClusteredSchemaIsStrictAndRequiresClusters() throws {
        let schema = try parse(RoundSchemas.integrateClustered)
        assertStrict(schema)
        let outer = try XCTUnwrap(schema as? [String: Any])
        XCTAssertTrue((outer["required"] as? [String])?.contains("clusters") ?? false)
        XCTAssertFalse(RoundSchemas.integrate.contains("clusters"), "a normal round keeps today's exact shape")
    }

    func testClusteredIntegratePromptAsksForClustersOnlyWhenClustered() {
        let plain = RoundPrompts.integrate(planFile: "/i/plan.md", changesFile: "/i/changes.json")
        let clustered = RoundPrompts.integrate(planFile: "/i/plan.md", changesFile: "/i/changes.json", clustered: true)
        XCTAssertFalse(plain.contains("clusters"))
        XCTAssertTrue(clustered.contains("same underlying issue"))
        XCTAssertTrue(clustered.contains("Apply each issue at most once"))
        XCTAssertTrue(clustered.contains(#""clusters": [[0, 3]"#))
    }

    func testIntegrateOutputWithoutClustersDecodes() throws {
        let old = #"{"agree":1,"somewhat":0,"disagree":0,"notes":"n","verdicts":[{"index":0,"verdict":"agree"}]}"#
        XCTAssertNil(try IntakeJSON.decoder.decode(IntegrateOutput.self, from: Data(old.utf8)).clusters)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: a build failure (`BlindOrder`, `IssueClusters`, `CrossCheckRecord`, `integrateClustered` undefined).

- [ ] **Step 3: Implement**

Create `Sources/IntakeKit/CrossCheck.swift`:

```swift
import Foundation

/// `checkpoints/<n>/crosscheck.json` for a cross-check Refine round (coverage spec §4.1): who
/// proposed each entry of that checkpoint's `changes.json`, which family each proposer was as it
/// actually ran, and the integrator's issue clusters. Written only when both reviewers returned,
/// so its absence means "not a cross-check", never "found nothing".
public struct CrossCheckRecord: Codable, Equatable, Sendable {
    public static let fileName = "crosscheck.json"
    /// Per change, 0 = the primary reviewer, 1 = the cross-reviewer.
    public var proposers: [Int]
    /// The family of proposer 0 and of proposer 1. Equal when the primary fell back to the
    /// cross-reviewer's family, which the fold reports as not independent.
    public var families: [ModelFamily]
    /// Cleaned (`IssueClusters.clean`); nil when the integrator gave none usable.
    public var clusters: [[Int]]?
    public var blindOrderSeed: Int
    public init(proposers: [Int], families: [ModelFamily], clusters: [[Int]]?, blindOrderSeed: Int) {
        self.proposers = proposers; self.families = families; self.clusters = clusters
        self.blindOrderSeed = blindOrderSeed
    }
}

/// The order the integrator sees a cross-check's proposals in. Blind because the integrator is
/// usually Claude, one reviewer's own family: grouped by proposer, its verdicts could favour its
/// own family, and every per-family number would inherit that. Seeded (by checkpoint id), not
/// random, so a retried round hands the integrator exactly the same list.
public enum BlindOrder {
    public static func interleave(_ a: [ProposedChange], _ b: [ProposedChange], seed: Int)
        -> (changes: [ProposedChange], proposers: [Int]) {
        var tagged = a.map { ($0, 0) } + b.map { ($0, 1) }
        var rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed)))
        // Fisher–Yates with our own generator: `shuffle(using:)` with a seeded RNG is stable across
        // runs, `shuffled()` is not.
        if tagged.count > 1 {
            for i in stride(from: tagged.count - 1, to: 0, by: -1) {
                tagged.swapAt(i, Int(rng.next() % UInt64(i + 1)))
            }
        }
        return (tagged.map(\.0), tagged.map(\.1))
    }

    private struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// The integrator's "these proposals are one issue" groups, held to a partition.
public enum IssueClusters {
    /// Indices outside `0..<count` dropped, an index already placed dropped, members sorted,
    /// clusters left with fewer than 2 members dropped (singletons are implicit); nil when nothing
    /// is left. The same forgiving cleaning `IntegrateOutput.verdicts(forChanges:)` does: a
    /// malformed grouping is worth less, not worth pausing a round over.
    public static func clean(_ raw: [[Int]]?, count: Int) -> [[Int]]? {
        guard let raw else { return nil }
        var placed = Set<Int>()
        let out = raw.compactMap { cluster -> [Int]? in
            let members = Array(Set(cluster)).sorted().filter { (0..<count).contains($0) && !placed.contains($0) }
            guard members.count >= 2 else { return nil }
            placed.formUnion(members)
            return members
        }
        return out.isEmpty ? nil : out
    }

    /// Every index in exactly one group: the clusters, then each unclustered index alone.
    public static func partition(_ clusters: [[Int]]?, count: Int) -> [[Int]] {
        let groups = clusters ?? []
        let placed = Set(groups.flatMap { $0 })
        return groups + (0..<count).filter { !placed.contains($0) }.map { [$0] }
    }
}
```

In `RoundPrompts.swift`:
- Add `public var clusters: [[Int]]?` to `IntegrateOutput`, plus the init param `clusters: [[Int]]? = nil`. Keep the synthesized Codable, which treats the optional as absent-safe.
- Add a method:

```swift
    /// The integrator's issue groups for a cross-check round of `count` changes, cleaned.
    public func clusters(forChanges count: Int) -> [[Int]]? { IssueClusters.clean(clusters, count: count) }
```

In `RoundSchemas`, add:

```swift
    /// A cross-check round's integrate: today's shape plus the issue groups (coverage spec §4.2).
    /// A separate schema so an ordinary round's reply is exactly what it was.
    public static let integrateClustered = """
    {"type":"object","additionalProperties":false,
     "required":["agree","somewhat","disagree","notes","verdicts","clusters"],
     "properties":{"agree":{"type":"integer"},"somewhat":{"type":"integer"},
                   "disagree":{"type":"integer"},"notes":{"type":"string"},
                   "verdicts":{"type":"array","items":\(changeVerdict)},
                   "clusters":{"type":"array","items":{"type":"array","items":{"type":"integer"}}}}}
    """
```

Change `RoundPrompts.integrate` to take `clustered: Bool = false`. When it is true, insert this paragraph before the "Return only JSON" line, and use the clustered JSON example line in place of the plain one:

```swift
        let clusterBlock = clustered ? """


        Some proposals may be the same issue raised twice. Group every set of proposals that \
        address the same underlying issue in `clusters` (lists of 0-based indices; a proposal \
        in no group stands alone). Apply each issue at most once. Give every proposal a \
        verdict: a duplicate of an issue you applied gets that issue's verdict.
        """ : ""
        let example = clustered
            ? #"`{"agree": N, "somewhat": N, "disagree": N, "notes": "...", "verdicts": [{"index": 0, "verdict": "agree"}, ...], "clusters": [[0, 3], ...]}`"#
            : #"`{"agree": N, "somewhat": N, "disagree": N, "notes": "...", "verdicts": [{"index": 0, "verdict": "agree"}, ...]}`"#
```

Build the returned string with `\(clusterBlock)` after the verdicts paragraph, ending `Return only JSON matching the provided schema: \(example).` Keep the non-clustered text byte-identical to today's (the existing `RoundPromptsTests` at lines 233/240 pin it).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `** SHARDED UNIT RUN PASSED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/CrossCheck.swift Sources/IntakeKit/RoundPrompts.swift Tests/FlightDeckTests/Intake/CrossCheckTests.swift Tests/FlightDeckTests/Intake/RoundPromptsTests.swift
git diff --cached --stat -- vendor
git commit -m "feat: add the blind order and clustered integrate a cross-check round needs"
```

---

### Task 3: Run a cross-check Refine round

**Files:**
- Modify: `Sources/IntakeKit/RoundExecutor.swift` (`refine`, `integrate`, and a new `crossCheckRefine`)
- Test: `Tests/FlightDeckTests/Intake/RoundExecutorTests.swift`

**Interfaces:**
- Consumes: `PlannedRound.crossCheck`, `RoundConfig.crossReviewer` (Task 1); `BlindOrder`, `IssueClusters`, `CrossCheckRecord`, `RoundSchemas.integrateClustered`, `RoundPrompts.integrate(…clustered:)` (Task 2)
- Produces:
  - The checkpoint files `changes.json` (merged, blind order), `verdicts.json` and `crosscheck.json`.
  - A slot role `"crossReviewer"` and a run name `refine-N-crossReviewer`.

**Behavior to implement (spec §4):**
- Both reviewers run in parallel through a `TaskGroup`, with the same prompt and inputs.
- The primary goes through the existing fallback-then-pause path. Refactor `refine`'s primary call into an `attempt` + fallback like `draft`'s, *or* keep `seat` if the reviewer has no fallback; mirror `draft` exactly (`-fallback` run suffix, `.substituted` status).
- The cross-reviewer uses `attempt` directly: no fallback, and a failure is recorded as `.failed` with its diagnosis and never throws `Pause`.
- If the cross-reviewer failed, fall through to today's single-review `integrate` (plain schema), and write no `crosscheck.json`.
- Otherwise:
  - Merge with `BlindOrder.interleave(primary.changes, cross.changes, seed: checkpointID)`, where `checkpointID = (inputs.tape.head?.id ?? 0) + 1` (the same id `run` assigns).
  - Build a `ReviewOutput(changes: merged, summary: [p.summary, c.summary] joined by "\n\n")`.
  - Call `integrate(…, clustered: true)`.
  - Add `crosscheck.json` to the returned files, even when the merged list is empty (integrate's empty early-return path). Families come from `ModelFamily(slot.used.harness)` of the two recorded outcomes.
- `publishReview` is called once per reviewer with its own run name, so each seat row shows its own count.
- Slot order in `record.slots`: `reviewer`, `crossReviewer`, `integrator`.

- [ ] **Step 1: Write the failing tests**

Add these to `RoundExecutorTests.swift` after `testRefineConsumesAnnotations`:

```swift
    // MARK: - Cross-check refine (coverage spec §4)

    /// Codex reviews as the primary, Claude as the cross-reviewer, Claude integrates. Both
    /// reviewers' prompts say "refinement round", so they are told apart by harness.
    func crossConfig() -> RoundConfig {
        var c = config()
        c.reviewer = Slot(codexA)
        c.crossReviewer = Slot(claudeB)
        c.crossCheck = .firstAndLast
        return c
    }
    let crossRound = PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true)

    func reviewTagged(_ tag: String, _ n: Int) -> String {
        json(ReviewOutput(changes: (0..<n).map { ProposedChange(section: "## Scope", rationale: "\(tag)\($0)", edit: "add \(tag)\($0)") },
                          summary: "\(tag) found \(n)"))
    }

    func clusteringIntegrator(_ call: ScriptedHarnessRunner.Call, clusters: [[Int]]?) -> CommandResult {
        let plan = call.cwd.appendingPathComponent("plan.md")
        let before = (try? String(contentsOf: plan, encoding: .utf8)) ?? ""
        try! (before + "\n## Added\nnew line\n").write(to: plan, atomically: true, encoding: .utf8)
        let n = (try? IntakeJSON.decoder.decode([ProposedChange].self,
                                                from: Data(contentsOf: call.cwd.appendingPathComponent("changes.json"))))?.count ?? 0
        let verdicts = (0..<n).map { ChangeVerdict(index: $0, verdict: .agree) }
        return ok(call, "int", json(IntegrateOutput(agree: n, somewhat: 0, disagree: 0, notes: "applied",
                                                    verdicts: verdicts, clusters: clusters)))
    }

    func testCrossCheckRunsBothReviewersAndStoresTheRecord() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return call.executable == "codex" ? ok(call, "p", self.reviewTagged("a", 3)) : ok(call, "c", self.reviewTagged("b", 2))
            default: return self.clusteringIntegrator(call, clusters: [[0, 1], [9, 9]])
            }
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        XCTAssertEqual(runner.calls("reviewer").count, 2)
        XCTAssertEqual(Set(runner.calls("reviewer").map(\.executable)), ["codex", "claude"])
        XCTAssertEqual(cp.record.slots.map(\.role), ["reviewer", "crossReviewer", "integrator"])
        XCTAssertEqual(cp.record.changeCount, 5)
        let record = try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: XCTUnwrap(files[CrossCheckRecord.fileName]))
        XCTAssertEqual(record.families, [.codex, .claude])
        XCTAssertEqual(record.proposers.count, 5)
        XCTAssertEqual(record.clusters, [[0, 1]], "cleaned: the out-of-range pair is dropped")
        XCTAssertEqual(record.blindOrderSeed, cp.id)
        let stored = try IntakeJSON.decoder.decode([ProposedChange].self, from: XCTUnwrap(files["changes.json"]))
        XCTAssertEqual(stored.count, 5)
        for (change, p) in zip(stored, record.proposers) { XCTAssertTrue(change.rationale.hasPrefix(p == 0 ? "a" : "b")) }
        XCTAssertNotNil(files["verdicts.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.runDirectory("refine-1-crossReviewer").path))
    }

    /// The integrator is handed the blind list and the clustered schema; no proposer shows.
    func testCrossCheckIntegratorIsBlindAndClustered() async throws {
        let seen = LockedBox<(changes: String, schema: String)?>(nil)
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return call.executable == "codex" ? ok(call, "p", self.reviewTagged("a", 2)) : ok(call, "c", self.reviewTagged("b", 2))
            default:
                let changes = try! String(contentsOf: call.cwd.appendingPathComponent("changes.json"), encoding: .utf8)
                let schemaDir = self.store.runDirectory("refine-1-integrator")
                let schema = (try? String(contentsOf: schemaDir.appendingPathComponent("schema.json"), encoding: .utf8)) ?? ""
                seen.set((changes, schema))
                return self.clusteringIntegrator(call, clusters: nil)
            }
        }
        _ = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        let got = try XCTUnwrap(seen.value)
        XCTAssertFalse(got.changes.contains("proposer"))
        XCTAssertFalse(got.changes.contains("codex") || got.changes.contains("claude"))
        XCTAssertTrue(got.schema.contains("clusters"))
        XCTAssertTrue(try XCTUnwrap(runner.calls("integrator").first).prompt.contains("same underlying issue"))
    }

    /// Review Focus 2: an integrator that answers without clusters still lands the round.
    func testCrossCheckWithoutClustersStillLands() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return ok(call, "r", self.reviewTagged(call.executable == "codex" ? "a" : "b", 1))
            default: return self.editingIntegrator(call)   // plain IntegrateOutput, no clusters key
            }
        }
        let (_, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        XCTAssertNil(try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: XCTUnwrap(files[CrossCheckRecord.fileName])).clusters)
    }

    func testCrossReviewerFailureDegradesToASingleReview() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return call.executable == "codex" ? ok(call, "p", self.review(2)) : failed("rate limit exceeded")
            default: return self.editingIntegrator(call)
            }
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        XCTAssertNil(files[CrossCheckRecord.fileName])
        XCTAssertEqual(cp.record.slots.first { $0.role == "crossReviewer" }?.status, .failed)
        XCTAssertEqual(cp.record.changeCount, 2)
        XCTAssertFalse(try XCTUnwrap(runner.calls("integrator").first).prompt.contains("same underlying issue"))
    }

    func testPrimaryFallbackToTheOtherFamilyIsRecordedAsSameFamily() async throws {
        var cfg = crossConfig()
        cfg.reviewer = Slot(codexA, fallback: claudeB)
        let runner = ScriptedHarnessRunner { [unowned self] call in
            switch call.role {
            case "reviewer": return call.executable == "codex" ? failed("boom") : ok(call, "c", self.review(1))
            default: return self.clusteringIntegrator(call, clusters: nil)
            }
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(cfg, tape: try refineTape())))
        XCTAssertEqual(cp.record.slots.first { $0.role == "reviewer" }?.status, .substituted)
        XCTAssertEqual(try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: XCTUnwrap(files[CrossCheckRecord.fileName])).families,
                       [.claude, .claude])
    }

    /// Review Focus 3: both reviewers found nothing, so there is no integrator, but the record is kept.
    func testCrossCheckWhereNobodyFindsAnything() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "r", self.review(0)) : failed("the integrator must not run")
        }
        let (_, files) = try checkpoint(try await executor(runner).run(crossRound, inputs(crossConfig(), tape: try refineTape())))
        XCTAssertTrue(runner.calls("integrator").isEmpty)
        XCTAssertEqual(try IntakeJSON.decoder.decode(CrossCheckRecord.self, from: XCTUnwrap(files[CrossCheckRecord.fileName])).proposers, [])
    }

    func testANonCrossCheckRoundIsUnchanged() async throws {
        let runner = ScriptedHarnessRunner { [unowned self] call in
            call.role == "reviewer" ? ok(call, "r", self.review(1)) : self.editingIntegrator(call)
        }
        let (cp, files) = try checkpoint(try await executor(runner).run(PlannedRound(stage: .refine, round: 2, major: false),
                                                                        inputs(crossConfig(), tape: try refineTape())))
        XCTAssertEqual(runner.calls("reviewer").count, 1)
        XCTAssertEqual(cp.record.slots.map(\.role), ["reviewer", "integrator"])
        XCTAssertNil(files[CrossCheckRecord.fileName])
    }
```

If there is no `LockedBox` test helper, add one at file scope:
`final class LockedBox<T>: @unchecked Sendable { private let l = NSLock(); private var v: T; init(_ v: T) { self.v = v }; var value: T { l.withLock { v } }; func set(_ n: T) { l.withLock { v = n } } }`
Check first with `rg -n "class LockedBox" Tests`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -60`
Expected: the new tests FAIL. Only one reviewer runs, and there is no `crosscheck.json`.

- [ ] **Step 3: Implement**

In `RoundExecutor.swift`:

1. `refine` becomes a dispatcher: `if planned.crossCheck, let cross = inputs.config.crossReviewer { return try await crossCheckRefine(planned, reviewer, cross, inputs, &record) }`, followed by today's body unchanged.
2. `integrate` gains `clustered: Bool = false`:
   - Pass `schema: clustered ? RoundSchemas.integrateClustered : RoundSchemas.integrate`.
   - Pass `clustered:` through to `RoundPrompts.integrate`.
   - Return type becomes `(files: [String: Data], integrated: IntegrateOutput?)`. The existing callers take `.files`.
   - `nil` on the empty early-return.
   - Doc-comment the reason: the cross-check caller needs the clusters it returned.
3. Add `crossCheckRefine`:

```swift
    /// Coverage spec §4: two families review the same plan at once, each in its own fresh
    /// session, and the integrator sees their proposals blind and says which are one issue. The
    /// cross-reviewer never has a fallback and never pauses the round: its fallback would be the
    /// primary's family, and a lost cross-check only costs this round's coverage reading — the
    /// round still refines the plan with the primary's review alone.
    private func crossCheckRefine(_ planned: PlannedRound, _ reviewer: Slot, _ cross: Slot, _ inputs: RoundInputs,
                                  _ record: inout RoundRecord) async throws -> [String: Data] {
        let plan = try currentPlan(inputs)
        let work = inputs.store.workDirectory()
        let ctx = context(inputs, graphFile: work.appendingPathComponent("graph.json"), observedAt: inputs.now())
        let prompt = RoundPrompts.review(ctx, planFile: plan.path, round: planned.round)
        let readable = [plan.deletingLastPathComponent(), work]
        func review(_ choice: ModelChoice, _ name: String) async throws -> Attempt<ReviewOutput> {
            try await attempt(ReviewOutput.self, name, choice, prompt: prompt, schema: RoundSchemas.review,
                              cwd: inputs.project, readable: readable, inputs: inputs)
        }
        async let crossAttempt = review(cross.choice, runName(planned, "crossReviewer"))
        // The primary, exactly as a drafter: its slot's fallback once, then a pause.
        let primaryName = runName(planned, "reviewer")
        var primary: (ReviewOutput, SlotOutcome)
        switch try await review(reviewer.choice, primaryName) {
        case .ok(let out, let session):
            primary = (out, SlotOutcome(role: "reviewer", used: reviewer.choice, requested: reviewer.choice, status: .ok, sessionID: session))
            publishReview(out, run: primaryName, inputs)
        case .failed(let first, let firstSession):
            guard let fallback = reviewer.fallback else {
                record.slots.append(SlotOutcome(role: "reviewer", used: reviewer.choice, requested: reviewer.choice,
                                                status: .failed, diagnosis: first, sessionID: firstSession))
                _ = try? await crossAttempt
                throw Pause(diagnosis: first)
            }
            switch try await review(fallback, primaryName + "-fallback") {
            case .ok(let out, let session):
                primary = (out, SlotOutcome(role: "reviewer", used: fallback, requested: reviewer.choice,
                                            status: .substituted, sessionID: session))
                publishReview(out, run: primaryName + "-fallback", inputs)
            case .failed(let diagnosis, let session):
                record.slots.append(SlotOutcome(role: "reviewer", used: fallback, requested: reviewer.choice,
                                                status: .failed, diagnosis: diagnosis, sessionID: session))
                _ = try? await crossAttempt
                throw Pause(diagnosis: diagnosis)
            }
        }
        record.slots.append(primary.1)
        let crossName = runName(planned, "crossReviewer")
        switch try await crossAttempt {
        case .failed(let diagnosis, let session):
            record.slots.append(SlotOutcome(role: "crossReviewer", used: cross.choice, requested: cross.choice,
                                            status: .failed, diagnosis: diagnosis, sessionID: session))
            return try await integrate(primary.0, base: plan, ctx: ctx, planned, inputs, &record).files
        case .ok(let out, let session):
            record.slots.append(SlotOutcome(role: "crossReviewer", used: cross.choice, requested: cross.choice,
                                            status: .ok, sessionID: session))
            publishReview(out, run: crossName, inputs)
            let seed = (inputs.tape.head?.id ?? 0) + 1
            let (merged, proposers) = BlindOrder.interleave(primary.0.changes, out.changes, seed: seed)
            let summary = [primary.0.summary, out.summary].filter { !$0.isEmpty }.joined(separator: "\n\n")
            let result = try await integrate(ReviewOutput(changes: merged, summary: summary), base: plan, ctx: ctx,
                                             planned, inputs, &record, clustered: true)
            let crossRecord = CrossCheckRecord(
                proposers: proposers,
                families: [ModelFamily(primary.1.used.harness), ModelFamily(cross.choice.harness)],
                clusters: result.integrated?.clusters(forChanges: merged.count), blindOrderSeed: seed)
            var files = result.files
            files[CrossCheckRecord.fileName] = try IntakeJSON.encoder.encode(crossRecord)
            return files
        }
    }
```

Note on the `async let`: the cross-reviewer's `attempt` runs concurrently with the primary's. Its `Attempt` never throws except on cancellation. Awaiting it on the pause paths (`_ = try? await`) keeps a child from outliving the round.

Also, `integrate`'s did-it-edit failure marks `record.slots[record.slots.count - 1]`. That is still the integrator, since it is appended last, so no change is needed there.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `** SHARDED UNIT RUN PASSED **`, with every existing `RoundExecutorTests` case unchanged.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/RoundExecutor.swift Tests/FlightDeckTests/Intake/RoundExecutorTests.swift
git diff --cached --stat -- vendor
git commit -m "feat: cross-check refine rounds with a second reviewer family"
```

---

### Task 4: Convergence reads a cross-check round's issue count

**Files:**
- Modify: `Sources/IntakeKit/ConvergenceSeries.swift` (`ConvergencePoint`, `cycles`, `point`, `Fingerprint`)
- Test: `Tests/FlightDeckTests/Intake/ConvergenceSeriesTests.swift`

**Interfaces:**
- Consumes: `CrossCheckRecord`, `IssueClusters.partition` (Task 2)
- Produces:
  - `ConvergencePoint.crossCheck: Bool` (init param `crossCheck: Bool = false`)
  - `ConvergenceSeries.textClusters(_ changes: [ProposedChange], thresholds: ConvergenceThresholds = .default) -> [[Int]]?`, an internal-to-module helper made `public` for `CoverageSeries`. It groups transitively by `Fingerprint.matches` and returns only groups of ≥ 2, or nil when there are none.

- [ ] **Step 1: Write the failing tests**

Open `ConvergenceSeriesTests.swift`. Reuse its existing helper that builds checkpoints with a `loadFile` dictionary (read the top of the file; it builds `[Int: [String: Data]]` or similar). Add:

```swift
    // MARK: - Cross-check rounds (coverage spec §6)

    func testCrossCheckPointCountsIssuesNotProposals() throws {
        // R1 is a cross-check of 6 proposals in 4 issues ([0,1], [2,3], 4, 5); R2 is a plain round of 2.
        let r1 = Checkpoint(id: 1, stage: .refine, round: 1, major: false, createdAt: Date(),
                            record: RoundRecord(slots: [
                                SlotOutcome(role: "reviewer", used: codex, requested: codex, status: .ok),
                                SlotOutcome(role: "crossReviewer", used: claude, requested: claude, status: .ok),
                                SlotOutcome(role: "integrator", used: claude, requested: claude, status: .ok)],
                                                changeCount: 6))
        let r2 = Checkpoint(id: 2, stage: .refine, round: 2, major: true, createdAt: Date(),
                            record: RoundRecord(slots: [SlotOutcome(role: "reviewer", used: codex, requested: codex, status: .ok)],
                                                changeCount: 2))
        let record = CrossCheckRecord(proposers: [0, 1, 0, 1, 0, 1], families: [.codex, .claude],
                                      clusters: [[0, 1], [2, 3]], blindOrderSeed: 1)
        let files: [Int: [String: Data]] = [1: [CrossCheckRecord.fileName: try IntakeJSON.encoder.encode(record)]]
        let cycle = try XCTUnwrap(ConvergenceSeries.cycles([r1, r2]) { files[$0]?[$1] }.first)
        XCTAssertEqual(cycle.points.map(\.changeCount), [4, 2])
        XCTAssertEqual(cycle.points.map(\.crossCheck), [true, false])
        XCTAssertFalse(cycle.trend.modelChanged, "the primary reviewer names the trend's model")
    }

    func testCrossCheckWithoutClustersFallsBackToTextClusters() throws {
        let same = ProposedChange(section: "## Auth", rationale: "tokens expire too late", edit: "shorten token expiry to 15 minutes")
        let twin = ProposedChange(section: "## Auth", rationale: "token expiry too late", edit: "shorten the token expiry to 15 minutes")
        let other = ProposedChange(section: "## Data", rationale: "no backups", edit: "add nightly backups")
        XCTAssertEqual(ConvergenceSeries.textClusters([same, other, twin]), [[0, 2]])
        XCTAssertNil(ConvergenceSeries.textClusters([same, other]))
    }
```

`codex` and `claude` here are `ModelChoice`s. Use the file's existing fixtures if it has them, else declare `let codex = ModelChoice(harness: .codex, model: "A", effort: "high")` and a matching `claude`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: a build failure (`crossCheck`, `textClusters` undefined).

- [ ] **Step 3: Implement**

- `ConvergencePoint`: add `public var crossCheck: Bool`, with the doc comment "Reviewed by two families; `changeCount` is its deduplicated issue count, the closest to one reviewer's. Drawn hollow so it reads as measured differently." Add it to `init` as `crossCheck: Bool = false`.
- `cycles`: also load `CrossCheckRecord.fileName` per checkpoint alongside `changes.json`, and pass it into `point`.
- `point`:

```swift
        // A cross-check round proposed from two families; counting every proposal would spike the
        // series on exactly the rounds that measure coverage (coverage spec §6).
        let issues: Int? = cross.map { record in
            let clusters = record.clusters ?? proposals[i].changes.flatMap { Self.textClusters($0, thresholds: t) }
            return IssueClusters.partition(clusters, count: record.proposers.count).count
        }
        ... changeCount: issues ?? r.changeCount ?? 0, ..., crossCheck: cross != nil
```

- Add `public static func textClusters(_ changes: [ProposedChange], thresholds t: ConvergenceThresholds = .default) -> [[Int]]?`. Use union-find over `Fingerprint`s: `matches` for every pair, `i < j`. Return the groups with ≥ 2 members, sorted by first index, or nil if there are none. Doc-comment it as "the same 'same idea' test `repeatCount` uses, never checked against human judgement: the fallback when the integrator gave no clusters, and the sanity check beside them."

`repeatsAndReopens` is unchanged: it compares against *earlier* rounds only, so the two reviewers' own duplicates within one round never count as repeats.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `** SHARDED UNIT RUN PASSED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/ConvergenceSeries.swift Tests/FlightDeckTests/Intake/ConvergenceSeriesTests.swift
git diff --cached --stat -- vendor
git commit -m "fix: count a cross-check round's issues, not its proposals, in convergence"
```

---

### Task 5: The coverage fold: readings, Chapman estimate, bands

**Files:**
- Create: `Sources/IntakeKit/CoverageSeries.swift`
- Test: create `Tests/FlightDeckTests/Intake/CoverageSeriesTests.swift`

**Interfaces:**
- Consumes: `CrossCheckRecord`, `IssueClusters` (Task 2); `ConvergenceSeries.textClusters` (Task 4); `ChangeVerdict`, `ProposedChange`, `Checkpoint`
- Produces (everything `public`, `Equatable`, `Sendable`):
  - `enum CoverageBand: String { case saturated, fewLeft, manyLeft, noOverlap, sameFamily, unmeasured }`
  - `enum CoverageMatcher: String { case integrator, textSimilarity }`
  - `struct CoverageThresholds { saturatedFound = 2, saturatedUnfound = 2, fewUnfound = 6, correlatedMin = 5, correlatedShare = 0.9, matcherGap = 5, matcherShare = 0.5; static let default }`
  - `struct CoverageReading { checkpoint, round: Int; familyA, familyB: ModelFamily; matcher: CoverageMatcher; n1, n2, both: Int; rejectedA, rejectedB: Int; found: Int; unfound: Int?; band: CoverageBand; correlated: Bool; textSimilarityBoth: Int?; var matchersDisagree: Bool }`
  - `enum CoverageSeries { static func chapman(n1: Int, n2: Int, both: Int) -> Double; static func readings(_ checkpoints: [Checkpoint], loadFile: (Int, String) -> Data?, thresholds: CoverageThresholds = .default) -> [CoverageReading]; static func reading(checkpoint: Int, round: Int, record: CrossCheckRecord, changes: [ProposedChange]?, verdicts: [ChangeVerdict]?, thresholds: CoverageThresholds = .default) -> CoverageReading }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// Coverage spec §5: counting accepted issues per family, Chapman's estimate and the bands.
final class CoverageSeriesTests: XCTestCase {
    /// `a` issues only family A raised, `b` only B, `shared` raised by both, all accepted; plus
    /// `rejected` proposals from A the integrator disagreed with.
    private func reading(a: Int, b: Int, shared: Int, rejected: Int = 0, clusters given: Bool = true,
                         families: [ModelFamily] = [.codex, .claude], verdicts: Bool = true) -> CoverageReading {
        var proposers: [Int] = [], clusters: [[Int]] = [], changes: [ProposedChange] = [], vs: [ChangeVerdict] = []
        func add(_ p: Int, _ text: String, _ v: Verdict) -> Int {
            proposers.append(p); changes.append(ProposedChange(section: "## \(text)", rationale: text, edit: text))
            vs.append(ChangeVerdict(index: changes.count - 1, verdict: v)); return changes.count - 1
        }
        for i in 0..<a { _ = add(0, "a\(i)", .agree) }
        for i in 0..<b { _ = add(1, "b\(i)", .somewhat) }
        for i in 0..<shared { clusters.append([add(0, "s\(i)", .agree), add(1, "s\(i)", .agree)]) }
        for i in 0..<rejected { _ = add(0, "r\(i)", .disagree) }
        let record = CrossCheckRecord(proposers: proposers, families: families,
                                      clusters: given ? (clusters.isEmpty ? nil : clusters) : nil, blindOrderSeed: 1)
        return CoverageSeries.reading(checkpoint: 3, round: 1, record: record, changes: changes, verdicts: verdicts ? vs : nil)
    }

    func testChapman() {
        XCTAssertEqual(CoverageSeries.chapman(n1: 20, n2: 18, both: 15), 21.0 * 19.0 / 16.0 - 1, accuracy: 1e-9)
        XCTAssertEqual(CoverageSeries.chapman(n1: 3, n2: 4, both: 0), 19, accuracy: 1e-9, "finite at no overlap")
    }

    /// The handoff's worked examples: 20/18/15 is saturated, 20/18/4 is far from it.
    func testWorkedExamples() {
        let sat = reading(a: 5, b: 3, shared: 15)
        XCTAssertEqual([sat.n1, sat.n2, sat.both, sat.found], [20, 18, 15, 23])
        XCTAssertEqual(sat.unfound, 1)   // N̂ = 21·19/16 − 1 ≈ 23.9, found 23
        XCTAssertEqual(sat.band, .saturated)
        let far = reading(a: 16, b: 14, shared: 4)
        XCTAssertEqual(far.band, .manyLeft)
        XCTAssertGreaterThan(far.unfound ?? 0, 6)
    }

    func testBandBoundariesInOrder() {
        XCTAssertEqual(reading(a: 1, b: 1, shared: 0).band, .saturated, "found ≤ 2 beats no-overlap")
        XCTAssertEqual(reading(a: 0, b: 0, shared: 0).band, .saturated, "nothing found by either (Review Focus 3)")
        XCTAssertEqual(reading(a: 3, b: 3, shared: 0).band, .noOverlap)
        XCTAssertEqual(reading(a: 6, b: 6, shared: 6).band, .fewLeft)   // 12/12/6: N̂ = 169/7 − 1 ≈ 23.1, found 18 → 5
        XCTAssertEqual(reading(a: 5, b: 3, shared: 15, families: [.claude, .claude]).band, .sameFamily)
        XCTAssertNil(reading(a: 5, b: 3, shared: 15, families: [.claude, .claude]).unfound)
        XCTAssertEqual(reading(a: 5, b: 3, shared: 15, verdicts: false).band, .unmeasured)
    }

    func testRejectedProposalsAreNotCoverage() {
        let r = reading(a: 2, b: 2, shared: 6, rejected: 4)
        XCTAssertEqual(r.n1, 8); XCTAssertEqual(r.rejectedA, 4); XCTAssertEqual(r.rejectedB, 0)
    }

    func testCorrelated() {
        XCTAssertTrue(reading(a: 0, b: 1, shared: 10).correlated)
        XCTAssertFalse(reading(a: 2, b: 2, shared: 3).correlated, "3 of 5 overlap is not near-total")
        XCTAssertFalse(reading(a: 5, b: 3, shared: 15).correlated)
    }

    func testTextSimilarityFallbackIsLabelled() {
        let r = reading(a: 1, b: 1, shared: 3, clusters: false)
        XCTAssertEqual(r.matcher, .textSimilarity)
        XCTAssertEqual(r.both, 3, "identical texts cluster by similarity")
        XCTAssertEqual(reading(a: 1, b: 1, shared: 3).matcher, .integrator)
    }

    func testMatcherDisagreement() {
        // The integrator paired 12 issues whose texts share nothing: the text matcher finds 0.
        var proposers: [Int] = [], changes: [ProposedChange] = [], vs: [ChangeVerdict] = [], clusters: [[Int]] = []
        for i in 0..<12 {
            proposers += [0, 1]
            changes += [ProposedChange(section: "## X\(i)", rationale: "alpha\(i)", edit: "one"),
                        ProposedChange(section: "## Y\(i)", rationale: "omega\(i)", edit: "two")]
            vs += [ChangeVerdict(index: 2 * i, verdict: .agree), ChangeVerdict(index: 2 * i + 1, verdict: .agree)]
            clusters.append([2 * i, 2 * i + 1])
        }
        let r = CoverageSeries.reading(checkpoint: 1, round: 1,
                                       record: CrossCheckRecord(proposers: proposers, families: [.codex, .claude], clusters: clusters, blindOrderSeed: 1),
                                       changes: changes, verdicts: vs)
        XCTAssertEqual(r.textSimilarityBoth, 0)
        XCTAssertTrue(r.matchersDisagree)
    }

    func testReadingsSkipRoundsWithoutARecord() throws {
        let cps = [Checkpoint(id: 1, stage: .synthesis, round: 0, major: true, createdAt: Date()),
                   Checkpoint(id: 2, stage: .refine, round: 1, major: false, createdAt: Date()),
                   Checkpoint(id: 3, stage: .refine, round: 2, major: true, createdAt: Date())]
        let record = CrossCheckRecord(proposers: [0, 1], families: [.codex, .claude], clusters: [[0, 1]], blindOrderSeed: 3)
        let files: [Int: [String: Data]] = [3: [
            CrossCheckRecord.fileName: try IntakeJSON.encoder.encode(record),
            "changes.json": try IntakeJSON.encoder.encode([ProposedChange(section: "s", rationale: "r", edit: "e"),
                                                           ProposedChange(section: "s", rationale: "r", edit: "e")]),
            "verdicts.json": try IntakeJSON.encoder.encode([ChangeVerdict(index: 0, verdict: .agree), ChangeVerdict(index: 1, verdict: .agree)]),
        ]]
        let readings = CoverageSeries.readings(cps) { files[$0]?[$1] }
        XCTAssertEqual(readings.map(\.checkpoint), [3], "old rounds with no crosscheck.json read as no reading, never as 0")
        XCTAssertEqual(readings.first?.round, 2)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: a build failure (`CoverageSeries` undefined).

- [ ] **Step 3: Implement** `Sources/IntakeKit/CoverageSeries.swift`

```swift
import Foundation

// Coverage: how much of a plan's issue space two independent reviewers have searched, estimated
// from a cross-check round by capture–recapture (coverage spec §5). Like convergence, every
// number is a signal: the estimate assumes independent reviewers, and two model families are
// only partly independent — correlated reviewers make it read LOW, which is why a near-total
// overlap is flagged rather than trusted.

public enum CoverageBand: String, Equatable, Sendable { case saturated, fewLeft, manyLeft, noOverlap, sameFamily, unmeasured }
public enum CoverageMatcher: String, Equatable, Sendable { case integrator, textSimilarity }

/// Placeholders, not measurements: no real Refine tape existed to fit them against when they were
/// chosen (2026-09-29, one intake on disk, stopped before Refine 1). Tune them from finished tapes.
public struct CoverageThresholds: Equatable, Sendable {
    /// Two independent searches that between them found at most this many accepted issues: the
    /// small sample is itself the answer.
    public var saturatedFound = 2
    public var saturatedUnfound = 2
    public var fewUnfound = 6
    /// Correlated: the smaller family found at least this many, and this share of them overlap.
    public var correlatedMin = 5
    public var correlatedShare = 0.9
    /// The integrator's and the text matcher's overlap differ by at least this many AND this share.
    public var matcherGap = 5
    public var matcherShare = 0.5
    public static let `default` = CoverageThresholds()
    public init() {}
}

public struct CoverageReading: Equatable, Sendable {
    public var checkpoint: Int
    public var round: Int
    public var familyA: ModelFamily
    public var familyB: ModelFamily
    public var matcher: CoverageMatcher
    /// Accepted issues (a cluster with any agree/somewhat member) raised by A, by B, by both.
    public var n1: Int
    public var n2: Int
    public var both: Int
    /// Proposals the integrator disagreed with, per family: precision, not coverage.
    public var rejectedA: Int
    public var rejectedB: Int
    public var found: Int
    /// Chapman's estimate minus what was found; nil when there is no estimate (same family, unmeasured).
    public var unfound: Int?
    public var band: CoverageBand
    public var correlated: Bool
    /// The text matcher's `both`, computed beside the integrator's as a sanity check.
    public var textSimilarityBoth: Int?
    public var matchersDisagree: Bool
}

public enum CoverageSeries {
    /// Chapman's bias-corrected Lincoln–Petersen: finite at no overlap, less biased on small samples.
    public static func chapman(n1: Int, n2: Int, both: Int) -> Double {
        Double((n1 + 1) * (n2 + 1)) / Double(both + 1) - 1
    }

    /// One reading per Refine checkpoint with a `crosscheck.json`, oldest first.
    public static func readings(_ checkpoints: [Checkpoint], loadFile: (Int, String) -> Data?,
                                thresholds: CoverageThresholds = .default) -> [CoverageReading] {
        checkpoints.filter { $0.stage == .refine }.compactMap { cp in
            guard let record = loadFile(cp.id, CrossCheckRecord.fileName)
                .flatMap({ try? IntakeJSON.decoder.decode(CrossCheckRecord.self, from: $0) }) else { return nil }
            let changes = loadFile(cp.id, "changes.json").flatMap { try? IntakeJSON.decoder.decode([ProposedChange].self, from: $0) }
            let verdicts = loadFile(cp.id, "verdicts.json").flatMap { try? IntakeJSON.decoder.decode([ChangeVerdict].self, from: $0) }
            return reading(checkpoint: cp.id, round: cp.round, record: record, changes: changes, verdicts: verdicts,
                           thresholds: thresholds)
        }
    }

    public static func reading(checkpoint: Int, round: Int, record: CrossCheckRecord, changes: [ProposedChange]?,
                               verdicts: [ChangeVerdict]?, thresholds t: CoverageThresholds = .default) -> CoverageReading {
        let count = record.proposers.count
        let a = record.families.first ?? .codex, b = record.families.dropFirst().first ?? a
        let textClusters = changes.flatMap { $0.count == count ? ConvergenceSeries.textClusters($0) : nil }
        let matcher: CoverageMatcher = record.clusters == nil ? .textSimilarity : .integrator
        let clusters = record.clusters ?? textClusters
        var out = CoverageReading(checkpoint: checkpoint, round: round, familyA: a, familyB: b, matcher: matcher,
                                  n1: 0, n2: 0, both: 0, rejectedA: 0, rejectedB: 0, found: 0, unfound: nil,
                                  band: .unmeasured, correlated: false, textSimilarityBoth: nil, matchersDisagree: false)
        // Accepted issues can't be counted without per-change verdicts: unmeasured, never 0.
        guard let verdicts else { return out }
        let verdict = Dictionary(verdicts.map { ($0.index, $0.verdict) }, uniquingKeysWith: { first, _ in first })
        func counts(_ clusters: [[Int]]?) -> (n1: Int, n2: Int, both: Int) {
            var n1 = 0, n2 = 0, both = 0
            for issue in IssueClusters.partition(clusters, count: count) {
                guard issue.contains(where: { verdict[$0] == .agree || verdict[$0] == .somewhat }) else { continue }
                let byA = issue.contains { record.proposers[$0] == 0 }, byB = issue.contains { record.proposers[$0] == 1 }
                if byA { n1 += 1 }
                if byB { n2 += 1 }
                if byA && byB { both += 1 }
            }
            return (n1, n2, both)
        }
        (out.n1, out.n2, out.both) = counts(clusters)
        out.rejectedA = (0..<count).filter { record.proposers[$0] == 0 && verdict[$0] == .disagree }.count
        out.rejectedB = (0..<count).filter { record.proposers[$0] == 1 && verdict[$0] == .disagree }.count
        out.found = out.n1 + out.n2 - out.both
        if matcher == .integrator, changes?.count == count {
            let text = counts(textClusters).both
            out.textSimilarityBoth = text
            let gap = abs(text - out.both)
            out.matchersDisagree = gap >= t.matcherGap && Double(gap) >= t.matcherShare * Double(max(text, out.both))
        }
        let smaller = min(out.n1, out.n2)
        out.correlated = smaller >= t.correlatedMin && Double(out.both) / Double(smaller) >= t.correlatedShare
        guard a != b else { out.band = .sameFamily; return out }
        out.unfound = max(0, Int((chapman(n1: out.n1, n2: out.n2, both: out.both) - Double(out.found)).rounded()))
        out.band = switch true {
        case out.found <= t.saturatedFound: .saturated
        case out.both == 0: .noOverlap
        case out.unfound! <= t.saturatedUnfound: .saturated
        case out.unfound! <= t.fewUnfound: .fewLeft
        default: .manyLeft
        }
        return out
    }
}
```

If the Swift 5 mode rejects `switch true` with boolean cases, replace it with an `if / else if` chain in the same order.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `** SHARDED UNIT RUN PASSED **`. If a band assertion fails, recompute that case by hand from the formulas above and fix the *fixture numbers* (never the band rule) until the fixture really exercises the band it names.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/CoverageSeries.swift Tests/FlightDeckTests/Intake/CoverageSeriesTests.swift
git diff --cached --stat -- vendor
git commit -m "feat: estimate plan coverage from cross-check rounds"
```

---

### Task 6: Fidelity targets, the coverage verdict and its suggested action

**Files:**
- Modify: `Sources/IntakeKit/CoverageSeries.swift` (append)
- Test: `Tests/FlightDeckTests/Intake/CoverageSeriesTests.swift` (append)

**Interfaces:**
- Consumes: `CoverageReading`, `CoverageBand` (Task 5); `ConvergenceVerdict` (`ConvergenceSeries.swift`); `Preset`
- Produces:
  - `public enum CoverageTarget: Equatable, Sendable { case none, fewLeftOrBetter, saturatedIndependent; init(_ preset: Preset); var label: String?; func met(by: CoverageReading) -> Bool? }`
  - `public enum CoverageState: Equatable, Sendable { case awaiting, reading(CoverageBand), stalled }`
  - `public struct CoverageVerdict: Equatable, Sendable { var state: CoverageState; var latest: CoverageReading?; var target: CoverageTarget; var targetMet: Bool?; var suggestedAction: String; var failedCrossCheckRound: Int? }`
  - `CoverageSeries.verdict(readings: [CoverageReading], preset: Preset, convergence: ConvergenceVerdict?, refineRoundsRemaining: Int, failedCrossCheckRound: Int?) -> CoverageVerdict`

**Suggestion strings (exact; spec §7):**

| When | `suggestedAction` |
|---|---|
| stalled (convergence `.converging(settled: true)` or `.plateau`, target missed) | `"Stalled: converged, but coverage is short of the \(presetName) target. One more Refine round will cross-check again; if it stays short, the plan may need a third model family."` |
| target met at Refine 1 and `refineRoundsRemaining >= 2` | `"Saturated at Refine 1. Consider removing the remaining \(n) Refine rounds (Run ▸ Remove a Round, ⌘-)."` |
| latest band `.noOverlap` or `.manyLeft` | `"Coverage is short. \(A) and \(B) are finding different issues; another round, or a higher fidelity, would search more."` |
| latest `correlated` | `"\(A) and \(B) found nearly the same issues. The estimate may be low; similar models share blind spots."` |
| latest `.sameFamily` | `"Both reviews at Refine \(r) ran as \(A), so coverage is unmeasured there."` |
| `failedCrossCheckRound` set and newer than the latest reading | `"The cross-check agent failed at Refine \(r), so coverage is unmeasured there."` |
| otherwise | `""` |

`presetName` is spelled "Feature plan" / "Full plan" (IntakeKit can't see `UIText`; define a private `name(_ preset:)` with those words and a doc comment pointing at `UIText.presetName` as the copy it mirrors). The rows are checked in table order, and the first match wins.

- [ ] **Step 1: Write the failing tests** (append to `CoverageSeriesTests`)

```swift
    // MARK: - Targets and verdict (coverage spec §7)

    func testTargetsPerPreset() {
        XCTAssertEqual(CoverageTarget(.bead), .none)
        XCTAssertEqual(CoverageTarget(.sketch), .none)
        XCTAssertEqual(CoverageTarget(.featurePlan), .fewLeftOrBetter)
        XCTAssertEqual(CoverageTarget(.fullPlan), .saturatedIndependent)
        XCTAssertNil(CoverageTarget.none.met(by: reading(a: 16, b: 14, shared: 4)))
        XCTAssertEqual(CoverageTarget.fewLeftOrBetter.met(by: reading(a: 6, b: 6, shared: 6)), true)
        XCTAssertEqual(CoverageTarget.saturatedIndependent.met(by: reading(a: 6, b: 6, shared: 6)), false)
        XCTAssertEqual(CoverageTarget.saturatedIndependent.met(by: reading(a: 0, b: 1, shared: 10)), false, "correlated")
    }

    func testStalledWhenConvergedButShort() {
        let v = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .featurePlan,
                                       convergence: .converging(settled: true), refineRoundsRemaining: 0, failedCrossCheckRound: nil)
        XCTAssertEqual(v.state, .stalled)
        XCTAssertEqual(v.targetMet, false)
        XCTAssertTrue(v.suggestedAction.hasPrefix("Stalled: converged, but coverage is short of the Feature plan target."))
        let plateau = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .featurePlan,
                                             convergence: .plateau, refineRoundsRemaining: 0, failedCrossCheckRound: nil)
        XCTAssertEqual(plateau.state, .stalled)
    }

    func testNotStalledWhileStillConverging() {
        let v = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .featurePlan,
                                       convergence: .converging(settled: false), refineRoundsRemaining: 2, failedCrossCheckRound: nil)
        XCTAssertEqual(v.state, .reading(.manyLeft))
        XCTAssertTrue(v.suggestedAction.hasPrefix("Coverage is short. Codex and Claude are finding different issues"))
    }

    func testSaturatedEarlySuggestsTrimming() {
        let v = CoverageSeries.verdict(readings: [reading(a: 5, b: 3, shared: 15)], preset: .fullPlan,
                                       convergence: .tooEarly, refineRoundsRemaining: 4, failedCrossCheckRound: nil)
        XCTAssertEqual(v.suggestedAction,
                       "Saturated at Refine 1. Consider removing the remaining 4 Refine rounds (Run ▸ Remove a Round, ⌘-).")
    }

    func testSketchIsShownNeverJudged() {
        let v = CoverageSeries.verdict(readings: [reading(a: 16, b: 14, shared: 4)], preset: .sketch,
                                       convergence: .plateau, refineRoundsRemaining: 0, failedCrossCheckRound: nil)
        XCTAssertEqual(v.state, .reading(.manyLeft))
        XCTAssertNil(v.targetMet)
    }

    func testAwaitingAndFailedCrossCheck() {
        let none = CoverageSeries.verdict(readings: [], preset: .featurePlan, convergence: nil, refineRoundsRemaining: 3,
                                          failedCrossCheckRound: nil)
        XCTAssertEqual(none.state, .awaiting)
        XCTAssertEqual(none.suggestedAction, "")
        let failed = CoverageSeries.verdict(readings: [], preset: .featurePlan, convergence: nil, refineRoundsRemaining: 2,
                                            failedCrossCheckRound: 1)
        XCTAssertEqual(failed.suggestedAction, "The cross-check agent failed at Refine 1, so coverage is unmeasured there.")
    }

    func testCorrelatedAndSameFamilyWording() {
        let corr = CoverageSeries.verdict(readings: [reading(a: 0, b: 1, shared: 10)], preset: .sketch, convergence: nil,
                                          refineRoundsRemaining: 0, failedCrossCheckRound: nil)
        XCTAssertTrue(corr.suggestedAction.hasPrefix("Codex and Claude found nearly the same issues."))
        let same = CoverageSeries.verdict(readings: [reading(a: 5, b: 3, shared: 15, families: [.claude, .claude])], preset: .fullPlan,
                                          convergence: nil, refineRoundsRemaining: 0, failedCrossCheckRound: nil)
        XCTAssertEqual(same.suggestedAction, "Both reviews at Refine 1 ran as Claude, so coverage is unmeasured there.")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: a build failure (`CoverageTarget`, `CoverageSeries.verdict` undefined).

- [ ] **Step 3: Implement.** Append to `CoverageSeries.swift`:
  - `CoverageTarget` (with a doc comment: placeholders, and "a customized config keeps its preset's target").
    `met(by:)` returns nil for `.none`, and nil when the reading's band is `.sameFamily` or `.unmeasured`.
    `fewLeftOrBetter` → band ∈ {saturated, fewLeft}. `saturatedIndependent` → band == .saturated ∧ !correlated.
    `label`: nil / `"FEW LEFT or better"` / `"SATURATED, independent"`.
  - `CoverageState`, `CoverageVerdict`.
  - `CoverageSeries.verdict`:
    - `latest = readings.last`, `targetMet = latest.flatMap(target.met)`.
    - `stalled` iff `targetMet == false` ∧ convergence ∈ {`.converging(settled: true)`, `.plateau`}.
    - The state is `.awaiting` when there are no readings, else `.stalled`, else `.reading(latest.band)`.
    - `suggestedAction` walks the table above in order. The "saturated early" row requires `latest.round == 1 && targetMet == true`.
    - The failed row applies when `failedCrossCheckRound` > `latest?.round ?? 0`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `** SHARDED UNIT RUN PASSED **`, with `TerminologyGuardTests` still green (no "bead"/"seat" in the new strings).

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/CoverageSeries.swift Tests/FlightDeckTests/Intake/CoverageSeriesTests.swift
git diff --cached --stat -- vendor
git commit -m "feat: judge coverage against each fidelity's target and suggest the next step"
```

---

### Task 7: Fold coverage in IntakeService beside convergence

**Files:**
- Modify: `Sources/FlightDeck/Intake/IntakeService.swift:245-290, 750-770, 857-905`
- Test: `Tests/FlightDeckTests/Intake/IntakeServiceLiveTests.swift` (next to the convergence refold test around line 650)

**Interfaces:**
- Consumes: `CoverageSeries.readings` (Task 5)
- Produces: `@Published private(set) var coverage: [UUID: [CoverageReading]]`. It is set in the same detached fold as `convergence`, cleared with it on intake removal, and seeded on the `lcd.coverage` flap surface when first landed. The test hook stays `convergenceFold(for:)`, which now covers both.

- [ ] **Step 1: Write the failing test**

Find the test around `IntakeServiceLiveTests.swift:640` that writes checkpoints then `await svc.convergenceFold(for:)`. Add a sibling test in the same style:

```swift
    func testCoverageIsFoldedWithConvergence() async throws {
        // Build the service and a shaping intake exactly as the convergence refold test above does,
        // then land one cross-check refine checkpoint:
        let record = CrossCheckRecord(proposers: [0, 1], families: [.codex, .claude], clusters: [[0, 1]], blindOrderSeed: 2)
        try store.writeCheckpoint(Checkpoint(id: 2, stage: .refine, round: 1, major: false, createdAt: clockNow),
                                  files: ["plan.md": Data("# Plan\n\nround 1\n".utf8),
                                          CrossCheckRecord.fileName: try IntakeJSON.encoder.encode(record),
                                          "changes.json": try IntakeJSON.encoder.encode([ProposedChange(section: "s", rationale: "r", edit: "e"),
                                                                                         ProposedChange(section: "s", rationale: "r", edit: "e")]),
                                          "verdicts.json": try IntakeJSON.encoder.encode([ChangeVerdict(index: 0, verdict: .agree),
                                                                                          ChangeVerdict(index: 1, verdict: .agree)])],
                                  into: &tape)
        svc.pollTapes()
        await svc.convergenceFold(for: i.id)?.value
        XCTAssertEqual(svc.coverage[i.id]?.map(\.round), [1])
        XCTAssertEqual(svc.coverage[i.id]?.first?.both, 1)
    }
```

Copy the setup lines (`svc`, `i`, `store`, `tape`, the first checkpoint) verbatim from the neighboring convergence test. The block above is the part that differs.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: a build failure (`coverage` undefined on `IntakeService`).

- [ ] **Step 3: Implement**
  - Declare `@Published private(set) var coverage: [UUID: [CoverageReading]] = [:]` beside `convergence`, with the doc comment "Each shaping intake's cross-check readings (coverage spec §5.4), folded with `convergence` from the same files."
  - Clear `coverage[gone] = nil` in the removal sweep (around line 765), and add `coverage.keys` to the union at line 756.
  - In `refreshConvergence`'s detached task, compute `let readings = CoverageSeries.readings(checkpoints) { readFile(store.checkpointDirectory($0).appendingPathComponent($1)) }` beside `cycles`.
  - In the main-actor hop, assign `self.coverage[id] = readings` when it changed.
  - Seed `lcd.coverage` the first time, the same way the convergence word is seeded. The seeded text is the band word from `CoverageCellModel` (Task 8). Until Task 8 exists, leave a one-line call site to add there, and do the seed in Task 8's commit.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: `** SHARDED UNIT RUN PASSED **`. The existing "no new checkpoint, no recompute" read-count assertions stay green, because coverage reads through the same `readFile` in the same fold, keyed by the same `ConvergenceKey`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Intake/IntakeService.swift Tests/FlightDeckTests/Intake/IntakeServiceLiveTests.swift
git diff --cached --stat -- vendor
git commit -m "feat: fold cross-check coverage alongside the convergence series"
```

---

### Task 8: The COVERAGE LCD cell and its card

**Files:**
- Create: `Sources/FlightDeck/Intake/Planning/CoverageCellModel.swift`, `Sources/FlightDeck/Intake/Planning/CoverageViews.swift`
- Modify: `Sources/FlightDeck/Intake/Planning/LCDModel.swift`, `Sources/FlightDeck/Intake/Planning/ControlBar.swift` (`LCDCellView`), `Sources/FlightDeck/Intake/IntakeDetailView.swift:344-400`, `Sources/FlightDeck/Intake/IntakeService.swift` (the flap seed from Task 7)
- Test: create `Tests/FlightDeckTests/Intake/Planning/CoverageCellModelTests.swift`; modify `Tests/FlightDeckTests/Intake/Planning/LCDModelTests.swift`; create `Tests/FlightDeckTests/Intake/Planning/CoverageRenderTests.swift`

**Interfaces:**
- Consumes: `CoverageVerdict`, `CoverageReading`, `CoverageSeries.verdict` (Task 6); `IntakeService.coverage` (Task 7); `ConvergenceCycle.verdict`
- Produces:
  - `struct CoverageCellModel: Equatable { var word: String; var shortWord: String; var caption: String; var tone: LCDCell.Tone; var rows: [String]; var notes: [String]; var targetLine: String?; var action: String; var actionHeadline: String?; var actionDetail: String?; init?(verdict: CoverageVerdict, crossChecks: Bool) }`
  - `LCDCell.Kind.coverage`
  - `LCDModel.init(… convergence:, coverage: CoverageCellModel? = nil, …)`
  - `CoverageCard(model:)`

**Text rules (spec §8):**
- `word`: `.awaiting` → `"—"`; `.stalled` → `"STALLED"`; `.reading(b)` → `SATURATED` / `FEW LEFT` / `MANY LEFT` / `NO OVERLAP`, and `"—"` for `.sameFamily` / `.unmeasured`.
- `shortWord`: `SAT` / `FEW` / `MANY` / `NONE` / `STALL` / `—`.
- `caption`: `"cross-check R\(latest.round)"`. It is `"unmeasured"` when the latest band is sameFamily or unmeasured. When awaiting, it is `"cross-check pending"`.
- `tone`: `.amber` for STALLED and NO OVERLAP, else `.normal`.
- `rows`: one per reading, oldest first: `"Refine \(r) · \(A) \(n1) · \(B) \(n2) · both \(both) · ≈ \(unfound) unfound (estimate)"`. Same-family rows end `· same family, not independent`. For unmeasured rows, drop the estimate clause.
- `notes`: rejected counts `"Integrator declined: \(A) \(rejectedA) · \(B) \(rejectedB)"`; when the matcher is text, `"Matched by text similarity: the integrator gave no groups"`; when matchers disagree, `"Text matching finds \(textSimilarityBoth) in common; the integrator found \(both)"`.
- `targetLine`: `"\(presetName) target: \(label) · met at Refine \(r)"` or `"… · not met"`, and nil for target `.none`. Use `UIText.presetName`.
- `action` / `actionHeadline` / `actionDetail`: the verdict's `suggestedAction`, split at the first `". "` exactly as `ConvergenceCellModel.actionParts` does. Extract that splitter into a shared `static func splitAction(_:)` on `ConvergenceCellModel` and reuse it. Don't copy it.
- `init?` returns nil when `!crossChecks && verdict.latest == nil`, so the cell is absent.

- [ ] **Step 1: Write the failing tests**

`CoverageCellModelTests.swift`:

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

final class CoverageCellModelTests: XCTestCase {
    private func verdict(_ readings: [CoverageReading], _ preset: Preset = .featurePlan,
                         convergence: ConvergenceVerdict? = nil, remaining: Int = 0) -> CoverageVerdict {
        CoverageSeries.verdict(readings: readings, preset: preset, convergence: convergence,
                               refineRoundsRemaining: remaining, failedCrossCheckRound: nil)
    }
    private func reading(n1: Int, n2: Int, both: Int, round: Int = 1, families: [ModelFamily] = [.codex, .claude]) -> CoverageReading {
        // Build through CoverageSeries.reading so the numbers are the fold's, not hand-set.
        var proposers: [Int] = [], changes: [ProposedChange] = [], vs: [ChangeVerdict] = [], clusters: [[Int]] = []
        func add(_ p: Int, _ t: String) -> Int {
            proposers.append(p); changes.append(ProposedChange(section: "## \(t)", rationale: t, edit: t))
            vs.append(ChangeVerdict(index: changes.count - 1, verdict: .agree)); return changes.count - 1
        }
        for i in 0..<(n1 - both) { _ = add(0, "a\(i)") }
        for i in 0..<(n2 - both) { _ = add(1, "b\(i)") }
        for i in 0..<both { clusters.append([add(0, "s\(i)"), add(1, "s\(i)")]) }
        return CoverageSeries.reading(checkpoint: round + 2, round: round,
                                      record: CrossCheckRecord(proposers: proposers, families: families,
                                                               clusters: clusters.isEmpty ? nil : clusters, blindOrderSeed: 1),
                                      changes: changes, verdicts: vs)
    }

    func testAbsentWithoutCrossChecksOrReadings() {
        XCTAssertNil(CoverageCellModel(verdict: verdict([]), crossChecks: false))
        XCTAssertEqual(CoverageCellModel(verdict: verdict([]), crossChecks: true)?.word, "—")
        XCTAssertEqual(CoverageCellModel(verdict: verdict([]), crossChecks: true)?.caption, "cross-check pending")
    }

    func testSaturatedCell() throws {
        let m = try XCTUnwrap(CoverageCellModel(verdict: verdict([reading(n1: 20, n2: 18, both: 15)]), crossChecks: true))
        XCTAssertEqual([m.word, m.shortWord, m.caption], ["SATURATED", "SAT", "cross-check R1"])
        XCTAssertEqual(m.tone, .normal)
        XCTAssertEqual(m.rows, ["Refine 1 · Codex 20 · Claude 18 · both 15 · ≈ 1 unfound (estimate)"])
        XCTAssertEqual(m.targetLine, "Feature plan target: FEW LEFT or better · met at Refine 1")
    }

    func testStalledIsAmberWithTheEnginesAction() throws {
        let m = try XCTUnwrap(CoverageCellModel(verdict: verdict([reading(n1: 20, n2: 18, both: 4)], convergence: .plateau),
                                                crossChecks: true))
        XCTAssertEqual([m.word, m.shortWord], ["STALLED", "STALL"])
        XCTAssertEqual(m.tone, .amber)
        XCTAssertEqual(m.actionHeadline, "Stalled: converged, but coverage is short of the Feature plan target")
        XCTAssertEqual(m.targetLine, "Feature plan target: FEW LEFT or better · not met")
    }

    func testNoOverlapIsAmberAndSameFamilyIsUnmeasured() throws {
        XCTAssertEqual(CoverageCellModel(verdict: verdict([reading(n1: 3, n2: 3, both: 0)]), crossChecks: true)?.tone, .amber)
        let same = try XCTUnwrap(CoverageCellModel(verdict: verdict([reading(n1: 20, n2: 18, both: 15, families: [.claude, .claude])]),
                                                   crossChecks: true))
        XCTAssertEqual([same.word, same.caption], ["—", "unmeasured"])
        XCTAssertTrue(same.rows[0].hasSuffix("same family, not independent"))
    }
}
```

In `LCDModelTests.swift`, add:

```swift
    func testCoverageCellFollowsConvergenceAndLeavesLast() throws {
        let i = try intake(.featurePlan)
        let tape = afterR1(.running)
        let config = try XCTUnwrap(i.roundConfig)
        let board = BoardModel(intake: i, tape: tape, config: config, now: t0.addingTimeInterval(500), selected: nil, preview: nil)
        let cov = CoverageCellModel(word: "FEW LEFT", shortWord: "FEW", caption: "cross-check R1", tone: .normal)
        let conv = ConvergenceCellModel(word: "TOO EARLY", latest: 3, spark: [3], tone: .normal)
        let lcd = LCDModel(tape: tape, config: config, board: board, seats: [], convergence: conv, coverage: cov,
                           preview: nil, now: t0.addingTimeInterval(500))
        let kinds = lcd.cells.map(\.kind)
        XCTAssertEqual(kinds.firstIndex(of: .coverage), kinds.firstIndex(of: .convergence).map { $0 + 1 })
        let c = try XCTUnwrap(lcd.cells.first { $0.kind == .coverage })
        XCTAssertEqual([c.value, c.shortValue, c.caption], ["FEW LEFT", "FEW", "cross-check R1"])
        XCTAssertEqual(LCDModel.dropOrder, [.billed, .soFar, .stopsAt, .coverage])
        XCTAssertEqual(LCDModel.flapSurface(.coverage), "lcd.coverage")
    }
```

This test uses a memberwise `CoverageCellModel(word:shortWord:caption:tone:)`. Give the struct defaults for every other field (`rows: [String] = []`, …), as `ConvergenceCellModel` does, so a render fixture can build one by hand. **Declare `init?(verdict:crossChecks:)` in an `extension`, not in the struct body.** A custom init in the body suppresses the memberwise init this test and the render fixtures rely on.

`CoverageRenderTests.swift`: copy `ConvergenceRenderTests`' skip-unless-`FD_PLANNING_RENDER_DIR` shape. Render these to PNGs:
- `CoverageCard` for SATURATED, FEW LEFT, STALLED, NO OVERLAP and same-family models;
- the `ControlBar` LCD at full width, and narrowed until COVERAGE is the only optional cell left.

Name the files `coverage-card-<band>.png` and `coverage-lcd-<width>.png`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: a build failure (`CoverageCellModel`, `.coverage` undefined).

- [ ] **Step 3: Implement**
  - `CoverageCellModel.swift`, per the text rules above. Its doc comment says every string comes from the engine's `CoverageVerdict`, never re-derived.
  - `LCDModel`:
    - Add `.coverage` to `Kind`, and a `coverage: CoverageCellModel? = nil` init param.
    - Append the cell right after the convergence one: `LCDCell(kind: .coverage, value: coverage.word, shortValue: coverage.shortWord, caption: coverage.caption, tone: coverage.tone)`.
    - Set `dropOrder = [.billed, .soFar, .stopsAt, .coverage]`, and update the doc comment: "STOPS AT is repeated by the board below; nothing repeats COVERAGE".
    - `flapSurface(.coverage) = "lcd.coverage"`.
    - Update the "Full order" comment.
  - `CoverageViews.swift`: `CoverageCard` uses the same card chrome as `ConvergenceCard` (read `ConvergenceViews.swift` and reuse its container/typography helpers; don't restyle). Contents, in order: the target line, rows, notes, and the action as a bold headline plus detail. When there are no readings it shows "Coverage is measured on cross-check rounds: R1 and the last Refine round."
  - `ControlBar.LCDCellView`:
    - Add `coverage: CoverageCellModel?`.
    - When `cell.kind == .coverage`, attach the same hover/focus `FloatingCard` with `CoverageCard(model:)`.
    - It has no click action (there is no coverage heatmap).
    - Thread `coverage` through `ControlBar`'s init the way `convergence` is threaded.
  - `IntakeDetailView.controlBar`: build `coverageCell` from `service.coverage[intake.id] ?? []`:
    - `convergence` is `cycles.last { $0.stage == .refine }?.verdict`.
    - `refineRoundsRemaining` is planned refine rounds (`TapePlanner` via `config.refinementCap + tape.extraRefinement`) minus refine checkpoints landed.
    - `failedCrossCheckRound` is the newest refine checkpoint whose `record.slots` has a `crossReviewer` with `.failed`.
    - `preset` is `intake.chosenPreset ?? .featurePlan`.
    - `crossChecks` is `config.crossChecks`.
    - Pass it to `LCDModel` and `ControlBar`.
  - `IntakeService`: add the first-fold seed of `lcd.coverage` left from Task 7, and pass `coverage:` in `seedFlapsIfNeeded`'s `LCDModel` (around line 902).

- [ ] **Step 4: Run the tests, then render**

Run: `./scripts/test-unit.sh 2>&1 | tail -40` and expect `** SHARDED UNIT RUN PASSED **`.
Then render: `FD_PLANNING_RENDER_DIR=<scratchpad>/renders ./scripts/test-unit.sh 2>&1 | tail -5`. Open every `coverage-*.png` with the Read tool and check it:
- no clipping;
- the band words are whole at full width;
- short forms appear only in the compact set;
- amber only on STALLED and NO OVERLAP;
- both light and dark, if `PlanningRender` renders both.

Fix and re-render until clean. Report the PNG paths in the task summary.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Intake/Planning/CoverageCellModel.swift Sources/FlightDeck/Intake/Planning/CoverageViews.swift Sources/FlightDeck/Intake/Planning/LCDModel.swift Sources/FlightDeck/Intake/Planning/ControlBar.swift Sources/FlightDeck/Intake/Planning/ConvergenceCellModel.swift Sources/FlightDeck/Intake/IntakeDetailView.swift Sources/FlightDeck/Intake/IntakeService.swift Tests/FlightDeckTests/Intake/Planning/CoverageCellModelTests.swift Tests/FlightDeckTests/Intake/Planning/LCDModelTests.swift Tests/FlightDeckTests/Intake/Planning/CoverageRenderTests.swift
git diff --cached --stat -- vendor
git commit -m "feat: show plan coverage as a band on the LCD with its card"
```

---

### Task 9: Mark cross-check rounds on the board, sparkline, heatmap and seat lists

**Files:**
- Modify: `Sources/FlightDeck/Intake/Planning/BoardModel.swift` (`TapeSlot`, markers ~line 110-125 and 343), `Sources/FlightDeck/Intake/Planning/ConvergenceCellModel.swift` (`hollow: [Int]`), `Sources/FlightDeck/Intake/Planning/ConvergenceViews.swift` (sparkline + heatmap column), `Sources/FlightDeck/Intake/Planning/LiveCard.swift:313-331` (`LiveSeats.expected`), `Sources/FlightDeck/Intake/Planning/FinishedRoundsModel.swift` (role label), `Sources/FlightDeck/Intake/Planning/UIText.swift`
- Test: `BoardModelTests.swift`, `ConvergenceCellModelTests.swift`, `LiveSeatsTests.swift`, `FinishedRoundsModelTests.swift` (all under `Tests/FlightDeckTests/Intake/Planning/`)

**Interfaces:**
- Consumes: `PlannedRound.crossCheck`, `ConvergencePoint.crossCheck`, the slot role `"crossReviewer"`
- Produces:
  - `TapeSlot.crossCheck: Bool`
  - `ConvergenceCellModel.hollow: [Int]` (indices into `spark`)
  - `UIText.roleName(_ role: String) -> String`, which maps `"crossReviewer"` → `"cross-check agent"` and returns other roles unchanged

**Behavior:**
- **Board.** A planned refine slot's `crossCheck` comes from its `PlannedRound`. A landed one's comes from its checkpoint (`record.slots.contains { $0.role == "crossReviewer" }`). The slot view draws a small "×2" after the code. Follow how the board draws other slot adornments, and don't change `code`, since label fitting measures it.
- **Sparkline.** Points with `crossCheck` are drawn hollow (stroke only). `cardLines` gains `"R\(r) was a cross-check: two reviewers, counted as issues"` for each.
- **Heatmap.** A cross-check column header reads `R\(r) ×2`.
- **`LiveSeats.expected(.refine)`.** When `round.crossCheck`, the rows are reviewer, `(base: "\(p)crossReviewer", requested: c.crossReviewer.map { Slot($0.choice) })`, then integrator.
- **Finished-round detail panel.** It shows role names through `UIText.roleName`. Find where `FinishedRoundsModel` renders `role` today (`rg -n "role" Sources/FlightDeck/Intake/Planning/FinishedRoundsModel.swift`) and route it through the helper.

- [ ] **Step 1: Write the failing tests**

In each test file, next to the closest existing case, add:

```swift
// LiveSeatsTests
func testCrossCheckRefineListsTheCrossCheckAgent() throws {
    var cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
    cfg.crossCheck = .firstAndLast
    let rows = LiveSeats.expected(PlannedRound(stage: .refine, round: 1, major: false, crossCheck: true), config: cfg)
    XCTAssertEqual(rows.map(\.base), ["refine-1-reviewer", "refine-1-crossReviewer", "refine-1-integrator"])
    XCTAssertEqual(rows[1].requested?.choice.harness, .claude)
    XCTAssertEqual(LiveSeats.expected(PlannedRound(stage: .refine, round: 2, major: false), config: cfg).count, 2)
}

// FinishedRoundsModelTests
func testCrossReviewerReadsAsCrossCheckAgent() {
    XCTAssertEqual(UIText.roleName("crossReviewer"), "cross-check agent")
    XCTAssertEqual(UIText.roleName("reviewer"), "reviewer")
}

// ConvergenceCellModelTests — build a cycle through ConvergenceSeries.assess with points where
// the first has crossCheck: true.
func testCrossCheckPointsAreHollowAndExplained() throws {
    let points = [ConvergencePoint(checkpoint: 3, stage: .refine, round: 1, changeCount: 8, linesChurned: 40, crossCheck: true),
                  ConvergencePoint(checkpoint: 4, stage: .refine, round: 2, changeCount: 4, linesChurned: 20)]
    let m = try XCTUnwrap(ConvergenceCellModel(cycles: [ConvergenceSeries.assess(.refine, points)]))
    XCTAssertEqual(m.hollow, [0])
    XCTAssertTrue(m.cardLines.contains("R1 was a cross-check: two reviewers, counted as issues"))
}

// BoardModelTests — a Feature plan board before any refine: REF1 and REF3 slots are cross-checks.
func testCrossCheckSlotsAreMarked() throws {
    // Build `BoardModel` for a Feature plan intake with draft + synthesis landed (reuse the file's
    // existing intake/tape helpers), then:
    // XCTAssertEqual(board.slots.filter(\.crossCheck).map(\.code), ["REF1", "REF3"])
}
```

For the board test, fill in the body with the file's existing Feature plan fixture helper. Read the top of `BoardModelTests.swift` first. The assertion must be the one shown in the comment. Verify the refine code format in `BoardModel.code(stage:round:)` (line 413): if it is not `REF1`, use whatever it produces.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build failures or assertion failures on the new cases.

- [ ] **Step 3: Implement** the behavior list above.

- [ ] **Step 4: Run the tests and renders**

Run: `./scripts/test-unit.sh 2>&1 | tail -40` and expect PASSED. Re-run the board and convergence render tests (`DeparturesBoardRenderTests`, `ConvergenceRenderTests`) with `FD_PLANNING_RENDER_DIR` set. Open the PNGs and check that the ×2 fits beside `REF1` and the hollow point is visible in both themes.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Intake/Planning/BoardModel.swift Sources/FlightDeck/Intake/Planning/ConvergenceCellModel.swift Sources/FlightDeck/Intake/Planning/ConvergenceViews.swift Sources/FlightDeck/Intake/Planning/LiveCard.swift Sources/FlightDeck/Intake/Planning/FinishedRoundsModel.swift Sources/FlightDeck/Intake/Planning/UIText.swift Tests/FlightDeckTests/Intake/Planning/
git diff --cached --stat -- vendor
git commit -m "feat: mark cross-check rounds on the board, sparkline, heatmap and seat lists"
```

---

### Task 10: The Cross-check row in the Rounds inspector, and the docs

**Files:**
- Modify: `Sources/FlightDeck/Intake/RoundConfigEditor.swift` (`Seat` enum line 13, rows ~232-330, `summary` line 218), `docs/FOLLOWUPS.md` (entry at ~1868), `docs/HANDOFF.md` (Flight Control section), `docs/FLIGHT-CONTROL-COVERAGE-HANDOFF.md` (top)
- Test: `Tests/FlightDeckTests/Intake/RoundConfigEditorTests.swift`, `RoundConfigEditorRenderTests.swift`

**Interfaces:**
- Consumes: `CrossCheckPolicy`, `RoundConfig.crossReviewer` / `.crossCheck` / `.crossChecks`, `TapePlanner` (Task 1)
- Produces:
  - `RoundConfigEditor.Seat.crossReviewer`
  - `static func crossCheckRounds(_ config: RoundConfig) -> [Int]` (the refine rounds that would cross-check at the current caps)

**Behavior:**
- A **"Cross-check"** picker row sits directly under the reviewer row, with the labels Off / First and last / Every round.
- When the policy is not off, a **"cross-check agent"** model row appears with a harness picker and a model field, exactly like the reviewer row but with no fallback control (`hasFallback` → false for `.crossReviewer`). If `crossReviewer` is nil when the policy is turned on, seed it with the other harness's `AvailableModels` choice.
- When `crossReviewer`'s family equals the reviewer's, a caption appears under the row: `"Same family as the reviewer, so rounds won't cross-check."`
- Every edit goes through `Self.setting(config)`, which sets `customized`.
- `summary` appends `"cross-check R1, R3"` from `crossCheckRounds` when it is non-empty. `crossCheckRounds` uses `refinementCap` alone, since the editor sees no tape, with the same first/last/every rule as `TapePlanner`.

- [ ] **Step 1: Write the failing tests**

```swift
    func testSummaryNamesCrossCheckRounds() throws {
        let cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        XCTAssertTrue(RoundConfigEditor.summary(preset: .featurePlan, config: cfg).contains("cross-check R1, R3"))
        var off = cfg; off.crossCheck = .off
        XCTAssertFalse(RoundConfigEditor.summary(preset: .featurePlan, config: off).contains("cross-check"))
        var same = cfg; same.crossReviewer = cfg.reviewer
        XCTAssertEqual(RoundConfigEditor.crossCheckRounds(same), [])
        var every = cfg; every.crossCheck = .every
        XCTAssertEqual(RoundConfigEditor.crossCheckRounds(every), [1, 2, 3])
    }
```

Also add to the rows test (find the one asserting the reviewer row, near `rows.append(("reviewer", …`) that the Feature plan preset lists `crossReviewer` right after `reviewer`, and that `.sketch` (policy off) doesn't. Add a render case for the inspector with cross-check on, and one with the same-family caption.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`
Expected: a build failure (`crossCheckRounds` undefined).

- [ ] **Step 3: Implement** the behavior list above, following the reviewer row's existing code paths (`choice(for:)`, `fallback(for:)`, `hasFallback`, `mutate`).

- [ ] **Step 4: Update the docs**
  - `docs/FOLLOWUPS.md`: replace the "Coverage metrics balanced against fidelity. Design not started…" entry (~line 1868) with a status line pointing at the spec and this plan. Add one entry per spec §10 deferred item. Note that every `CoverageThresholds` / `CoverageTargets` value is an uncalibrated placeholder, and that the GUI check of the LCD cell is the maintainer's (agents can't drive the GUI).
  - `docs/HANDOFF.md`: one paragraph in the Flight Control section covering cross-check rounds, the COVERAGE cell, and where the thresholds live.
  - `docs/FLIGHT-CONTROL-COVERAGE-HANDOFF.md`: a first-line note, "Designed: see `docs/superpowers/specs/2026-09-29-flight-control-coverage-design.md`."

- [ ] **Step 5: Run the tests and renders, then commit**

Run: `./scripts/test-unit.sh 2>&1 | tail -40` and expect PASSED. Render `RoundConfigEditorRenderTests` and look at the PNGs.

```bash
git add Sources/FlightDeck/Intake/RoundConfigEditor.swift Tests/FlightDeckTests/Intake/RoundConfigEditorTests.swift Tests/FlightDeckTests/Intake/RoundConfigEditorRenderTests.swift docs/FOLLOWUPS.md docs/HANDOFF.md docs/FLIGHT-CONTROL-COVERAGE-HANDOFF.md
git diff --cached --stat -- vendor
git commit -m "feat: let the Rounds inspector turn cross-checks on and name their rounds"
```

---

## Verification (end to end, after Task 10)

1. `./scripts/test-unit.sh`, then read the final `** SHARDED UNIT RUN PASSED **` line.
2. `./scripts/build.sh` succeeds (a Debug build; **do not launch it**).
3. Open every `coverage-*.png`, board and inspector render from the last render run, and confirm the §8 wording.
4. `git diff master --stat -- vendor` is empty.
5. Hand the maintainer the GUI checklist in the branch summary. Agents cannot drive the GUI (AGENTS.md rule 2):
   - Turn cross-check on for the larkOS intake in the inspector, then continue Refine 1.
   - Confirm that two reviewer rows run, the COVERAGE cell appears with a band, and the card's counts match `checkpoints/<n>/crosscheck.json`.
