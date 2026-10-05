# Flight Control L3-I Capability Index Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Flight Deck its own record of what each model is good at — fed by public benchmarks,
refreshed weekly by a headless agent, scored per capability dimension with a confidence — so
routing has a fallback for tasks no rule covers, rules that pick a clearly weaker model get a
hint, and a bad refresh rolls back with one click.

**Architecture:** Everything that can be pure is pure and lives in IntakeKit
(`Sources/IntakeKit/FlightControl/`, Foundation only, Swift 6): the source registry and units,
the extraction validator, the alias table and proposer, the snapshot model and config, scoring
(percentiles → dimensions → kinds), rule hints, the snapshot store (files, retention, rollback,
diff) and the extraction command builder. The app target holds only what touches processes,
the main actor or SwiftUI: `IndexRefreshRunner` (runs `claude -p` per source through the
existing `HeadlessRunner`, enforces the token cap), `CapabilityIndexService` (config, apply,
rollback, the weekly check on the shared `WatchClock`, and `LiveCapabilityIndex`, the
`CapabilityIndex` conformer integration hands to the router), and the Settings pane.

**Tech Stack:** Swift 6 (IntakeKit), Swift 5 mode (app target), SwiftUI, XCTest, XCUITest,
XcodeGen, `claude` 2.1.289 headless (`-p`, `--json-schema`, `--restricted`, `--tools`).

**Spec:** `docs/superpowers/specs/2026-10-04-flight-control-l3-capability-index-design.md`
(context: `docs/superpowers/specs/2026-10-04-flight-control-l3-overview-contract-design.md`).

**Contract (lands first, consumed exactly, never redefined):**
`docs/superpowers/plans/2026-10-04-flight-control-l3-0-contract.md` — `HarnessID`, `ModelRef`,
`Dimension`/`Dimensions` (the ten ids), `TaskKind`, `KindID.normalized`, `ModelEntry`,
`AdapterCatalog`, `AdapterCatalogs` (`order`, `byHarness`, `enabledModels`), `ScoredModel`,
the `CapabilityIndex` protocol (`rank(kind:candidates:) -> [ScoredModel]`, best first, unknown
omitted; `snapshotDate`), `RoutingCapabilityRegistry`, `AgentID.harnessID`.

**Pre-checked while planning:** every Swift block in Tasks 1–14 was compiled (IntakeKit code
in Swift 6 mode) against the L3-0 plan's code, the real `SeatActivity.swift`/`WatchClock.swift`/
`HeadlessRunner` protocol and stubs for `HarnessCommand`/`HarnessOutput`, and every unit test
in this plan passed (88 run, the live probe skipped) except two needing app-only types. Not pre-checked: the edits to
`SessionStore`, `FlightDeckApp`, `PreferencesTab`/`PreferencesView`, the terminology sweep and the XCUITest run.

## Global Constraints

- IntakeKit is Foundation-only, `SWIFT_VERSION: "6.0"`; every new IntakeKit type is `Sendable`; no stored `static` of a non-Sendable type (no `NSRegularExpression`/`DateFormatter` statics).
- The app target stays `SWIFT_VERSION: "5.0"`. Don't "fix" it.
- Depend only on L3-0. Never import or name an L3-R, L3-U or L3-S type.
- Storage root: `<state dir>/capability-index/`, where `<state dir>` is `FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory()` — `Flight Deck` (Release) or `Flight Deck (Debug)` (Debug).
- Snapshot files: `<state dir>/capability-index/<yyyy-MM-dd'T'HHmmss'Z'>.json` (UTC); keep 12; newest valid is current; rolled back = `<stamp>.rolledback.json`; settings = `config.json`.
- Refresh agent: `claude -p` only, tools exactly `WebSearch WebFetch`, `--permission-mode dontAsk`, plus `HarnessCommand.claudeStreaming` and `HarnessCommand.claudeIsolation`; default model `sonnet`, effort `medium`, token cap `1_500_000` per run.
- Weekly cadence: `CapabilityIndexService.refreshInterval = 7 * 24 * 60 * 60` seconds, measured from the last attempt.
- Rule hint thresholds: margin ≥ `0.10`, confidence ≥ `0.6`, compared with `1e-9` slack. Inherit discount default `0.85`.
- Processes run through `HeadlessRunner`/`SystemHeadlessRunner` (→ `SystemCommandRunner`, which observes exit with `terminationHandler` + semaphore). Never call `waitUntilExit()`.
- UI copy says *tasks*, *agent*, *Flight Control* — never "beads", "seat", "flywheel". `TerminologyScan` sweeps every new file.
- Comments explain *why* and name the failure they prevent (docs/CONVENTIONS.md).
- Commits: lowercase, behavioral, imperative; trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Commit by path; never `git stash`, never `git add -A`.
- Tests: TDD; confirm each new test fails first. One class: `FD_TEST_FILTER=<Class> ./scripts/test-unit.sh 2>&1 | tail -40`. The script exits 0 even on failure: read the final `SHARDED UNIT RUN PASSED|FAILED` line and `rg -n "error:"` the output. Run tests in the foreground. `test-unit.sh` runs the whole bundle build every time (~minutes); budget for it.
- Work in a worktree (`superpowers:using-git-worktrees`). Symlink `vendor/ghostty-artifacts` and `vendor/boringssl-artifacts` into it before the first build; never commit those symlinks. In a worktree, edit with built-in `Edit`/`Write`, not quillmap mutators (they write to the main checkout). Before editing `SessionStore.swift` or `FlightDeckApp.swift`, run `quillmap_impact` on the file.
- Never launch a bundle from `DerivedData/` by hand. The only app launch in this plan is the XCUITest in Task 13, under `-FlightDeckResetState YES`, run once, never looped.

**Deviations from the spec decided while planning (Task 15 records them in the spec):**
1. **Snapshot names are a UTC date-time stamp** (`2026-10-04T060000Z.json`), not a bare date: a refresh and an alias rescore on the same day must not overwrite each other; UTC so a timezone change cannot reorder them; no colons so Finder shows them intact. A write never sorts before an existing snapshot, even after the clock moves back.
2. **Rollback renames** the current file to `<stamp>.rolledback.json` rather than keeping a pointer, so "the newest valid snapshot is current" stays the only rule.
3. **Snapshots store computed scores only.** Manual and inherited scores are overlaid live from `config.json`, so editing a hand score needs no refresh and the diff shows only benchmark movement.
4. **Changing what an alias maps rescoring writes a new snapshot** from the current snapshot's rows — no agent run, no tokens — so that change is rollback-able too.
5. **One source reads one metric in one unit.** The speed-and-price tracker is two entries (`aa-speed`, `aa-price`); vendor model cards feed context windows only (prices come from `aa-price`). **SWT-bench is added** for `test-authoring`, which no listed source covers. `docs-prose` has no initial source and stays unknown unless entered by hand.
6. **A benchmark with fewer than two rows contributes nothing** (a percentile among one row is undefined), rather than an invented 0.5 or 1.0.
7. **Unmapped names stay in the percentile population** — they are real competitors on that benchmark — though they never receive a score. Two names mapped to the same `ModelRef` (knobs included) in one source keep the better row.
8. **`rank` and knobs:** a candidate with no knobs matches every scored knob variant of its model and returns the best variant's `ModelRef` (knobs included); a candidate with knobs matches exactly.
9. **Score precedence per dimension: manual > computed > inherited.** Inheritance is one level (a base's own inheritance is not followed).
10. **The refresh agent is claude only in v1** (model, effort and cap configurable). Codex `exec` web-search flags are unprobed.
11. **The first refresh is manual.** Weekly auto-refresh starts after the first attempt, so a fresh install never spends tokens unasked. Every attempt — success or failure — records `lastRefreshAttemptAt`, so a failing run waits a week instead of retrying on every 500 ms clock beat.
12. **A source that returns only rejected rows counts as failed** (keeps its previous values, marked stale).
13. **Rule hints live here and L3-R consumes them at integration:** `CapabilityHint` and `CapabilityHints.hints(for:assigned:candidates:scores:)` (IntakeKit), exposed as `hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef]) -> [CapabilityHint]` on `SnapshotCapabilityIndex`, `LiveCapabilityIndex` and `CapabilityIndexService`. Only the dictionary's keys (the rule's `match` dimensions) are compared; the values (thresholds) are accepted so L3-R can pass compiled terms directly.
14. **Settings tab (renamed to avoid a parallel-branch collision):** L3-R creates `FlightControlSettingsTab` and `PreferencesTab.flightControl`. To keep the parallel branches from colliding on the same file and enum case, this branch adds its own temporary top-level `PreferencesTab.capabilityIndex` and a `CapabilityIndexSettingsTab` container holding only the capability index. The integration plan moves `CapabilityIndexPane` into L3-R's `FlightControlSettingsTab` as a section and deletes this temporary tab. The hint type is `CapabilityHint`/`CapabilityHints`, not `RuleHint`: L3-R defines its own `RuleHint` (the drawn line) and `RuleHintSource`, and at integration a `CapabilityHints`-backed conformer of `RuleHintSource` maps one to the other.
15. **Reaching the live service:** `SessionStore.capabilityIndexService` (set by `FlightDeckApp.makeStore`) and `SessionStore.watchClock` (read-only access to the shared clock). Until L3-R fills `modelCatalog()`, the catalogs closure returns empty catalogs, so a refresh before integration proposes no aliases.

## Review Focus

- **A benchmark where lower is better** (price per million tokens, latency): the cheapest model
  must rank highest. Pinned by `testLowerIsBetterUnitInvertsPercentile` (Task 5).
- **A benchmark with one row** (a new leaderboard listing a single model): the percentile is
  degenerate and must contribute nothing, not 0 or 1. Pinned by
  `testSingleRowBenchmarkContributesNothing` (Task 5).
- **A corrupt or newer-version file as the newest snapshot** (a crash mid-write, a downgrade):
  the previous valid snapshot must stay current. Pinned by
  `testCorruptNewestSnapshotFallsBackToPreviousValid` and `testNewerVersionSnapshotIsSkipped`
  (Task 8).
- **A refresh that fails, ticking on the 500 ms `WatchClock`:** it must not retry on every beat
  and burn tokens. Pinned by `testFailedRefreshDoesNotRetryOnNextTick` (Task 11).
- **Clock and timezone in snapshot names:** a stamp must be UTC whatever the local zone, and a
  snapshot written after the clock moved back must still become current. Pinned by
  `testStampIsUTCWhateverTheLocalTimeZone` (Task 4) and
  `testWriteAfterTheClockMovedBackStillBecomesCurrent` (Task 8).

Also pinned, because they bite quietly: a 0.10 margin that float arithmetic makes 0.0999…
(`testExactlyTenPointMarginHintsDespiteFloatError`, Task 7), two benchmark names for one model
(`testTwoNamesForOneModelKeepTheBestRow`, Task 5), and an unreadable `config.json` that must
not be overwritten in place (`testUnreadableConfigIsMovedAsideAndReported`, Task 4).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/IntakeKit/FlightControl/IndexSources.swift` | `IndexUnit` (with direction), `IndexSource`, `IndexSourceRegistry` (initial set, `problems`) |
| `Sources/IntakeKit/FlightControl/ExtractionValidator.swift` | `ExtractedRow`, `ExtractionPayload`, `AcceptedRow`, `RejectedRow`, `ExtractionValidator` |
| `Sources/IntakeKit/FlightControl/AliasTable.swift` | `AliasStatus`, `AliasEntry`, `UnmappedName`, `AliasTable`, `IndexKeys`, `AliasProposer` |
| `Sources/IntakeKit/FlightControl/IndexSnapshot.swift` | `IndexStamp`, `SourceResult`, `ScoreOrigin`, `DimensionScore`, `ModelScores`, `IndexSnapshot`, `ManualModelScores`, `IndexAgentSettings`, `IndexConfig` |
| `Sources/IntakeKit/FlightControl/CapabilityScoring.swift` | percentiles, dimension scores, overlay, `assemble`, kind score, `rank`, citations, `SnapshotCapabilityIndex` |
| `Sources/IntakeKit/FlightControl/CapabilityHints.swift` | `CapabilityHint`, `CapabilityHints`, `SnapshotCapabilityIndex.hints` |
| `Sources/IntakeKit/FlightControl/IndexSnapshotStore.swift` | `SnapshotRef`, `IndexStoreError`, `IndexSnapshotStore`, `ScoreChange`, `SnapshotDiff` |
| `Sources/IntakeKit/FlightControl/IndexExtraction.swift` | the extraction prompt, JSON schema, `claude -p` command, output parse |
| `Sources/FlightDeck/FlightControl/IndexRefreshRunner.swift` | `IndexRefreshPlan`, `IndexRefreshOutcome`, `IndexRefreshError`, `IndexTokenMeter`, `IndexRefreshRunner` |
| `Sources/FlightDeck/FlightControl/CapabilityIndexService.swift` | `LiveCapabilityIndex`, `CapabilityIndexService` |
| `Sources/FlightDeck/Preferences/UI/CapabilityIndexPane.swift` | the pane, `ManualScoresEditor` |
| `Sources/FlightDeck/Preferences/UI/CapabilityIndexSettingsTab.swift` | the Flight Control tab container |
| `Sources/FlightDeck/Preferences/PreferencesTab.swift`, `Preferences/UI/PreferencesView.swift` | modify: the new tab |
| `Sources/FlightDeck/SessionStore.swift`, `FlightDeckApp.swift` | modify: hold and build the service |
| `Tests/FlightDeckTests/FlightControlL3/Index/*.swift` | unit tests, `IndexFixtures`, `ScriptedIndexHeadless` |
| `Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/` | recorded extraction outputs; `ui/` snapshots for the UI test |
| `UITests/FlightDeckUITests/CapabilityIndexUITests.swift` | heatmap, citations, diff, rollback, with screenshots |

`project.yml` needs no edit: `Sources/IntakeKit`, `Sources/FlightDeck`, `Tests/FlightDeckTests`
and `UITests/FlightDeckUITests` are globbed recursively, and `Tests/FlightDeckTests/Fixtures` is
a folder reference (`project.yml`, `FlightDeckTests.sources`).

---

### Task 1: Probe the sources live and ship the registry

**Files:**
- Create: `Sources/IntakeKit/FlightControl/IndexSources.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/IndexSourceRegistryTests.swift`

**Interfaces:**
- Consumes: `Dimensions.isKnown`, `Dimensions.ids` (L3-0).
- Produces:
  - `public enum IndexUnit: String, Codable, Sendable, CaseIterable { percent, score, elo, tokensPerSecond = "tokens-per-second", seconds, usdPerMillionTokens = "usd-per-million-tokens", contextTokens = "context-tokens"; var higherIsBetter: Bool }`
  - `public struct IndexSource: Codable, Equatable, Sendable, Identifiable { id, name, url: String; dimensions: [String: Double]; howToRead: String; unit: String; machineReadable: Bool; enabled: Bool; var indexUnit: IndexUnit?; init(id:name:url:dimensions:howToRead:unit: IndexUnit, machineReadable:enabled: = true) }`
  - `public enum IndexSourceRegistry { static let initial: [IndexSource]; static func problems(_ sources: [IndexSource]) -> [String] }`

- [ ] **Step 1: Confirm L3-0 has landed on this branch's base**

Run: `rg -n "public protocol CapabilityIndex|public struct AdapterCatalogs|public struct ScoredModel|public static func normalized" Sources/IntakeKit/FlightControl/`
Expected: four hits (`ContractProtocols.swift`, `ContractValues.swift` twice, `TaskKind.swift`).
If any is missing, stop: L3-0 is not merged into this base. Rebase onto a master that has it.

- [ ] **Step 2: Probe every candidate URL (read-only, no tokens)**

Run:

```bash
for u in \
  https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json \
  https://scale.com/leaderboard/swe_bench_pro_public \
  https://www.tbench.ai/leaderboard \
  https://raw.githubusercontent.com/Aider-AI/aider/main/aider/website/_data/polyglot_leaderboard.yml \
  https://livecodebench.github.io/leaderboard.html \
  https://swtbench.com/ \
  https://lmarena.ai/leaderboard/webdev \
  https://artificialanalysis.ai/leaderboards/models \
  https://docs.anthropic.com/en/docs/about-claude/models/overview \
  https://platform.openai.com/docs/models; do
  printf "%s " "$u"; curl -sS -L -o /dev/null -m 20 -w "%{http_code} %{content_type}\n" "$u"
done
curl -sS -m 20 https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json | head -c 300; echo
curl -sS -m 20 https://raw.githubusercontent.com/Aider-AI/aider/main/aider/website/_data/polyglot_leaderboard.yml | head -8
```

Expected (probed while planning, 2026-10-04): every URL `200`; the SWE-bench file is JSON with a
`leaderboards` array; the Aider file is a YAML list whose entries have `model:` and
`pass_rate_2:`; every other URL is `text/html`. So `machineReadable` is true for exactly
`swe-bench-verified` and `aider-polyglot`.

Per outcome:
- A URL that is not `200`: find its current address (the site's own navigation, via `curl -sSL <home> | rg -o 'href="[^"]*leaderboard[^"]*"'`), use that in Step 4, and add a line to the deviations list in Task 15.
- A page URL that now serves `application/json`/`text/yaml`: set its `machineReadable` to `true` in Step 4 and add its id to the set in `testMachineReadableMatchesTheProbe`.
- If the SWE-bench JSON no longer has a leaderboard named `Verified` (`curl … | rg -c '"name": "Verified"'` prints `0`), keep the URL but change its `howToRead` to name the leaderboard that replaced it.

- [ ] **Step 3: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// The registry is user-editable data, so the only things worth pinning are the ones that make
/// a source silently contribute nothing: a unit nobody knows (its rows all reject), a weight on
/// a dimension that does not exist (scores nothing), a URL that is not a web address. Plus the
/// probe's result, so a source that stops being a data file is a test change, not a surprise.
final class IndexSourceRegistryTests: XCTestCase {
    func testInitialSetCoversTheSpecsSources() {
        XCTAssertEqual(IndexSourceRegistry.initial.map(\.id), [
            "swe-bench-verified", "swe-bench-pro", "terminal-bench", "aider-polyglot", "livecodebench",
            "swt-bench", "webdev-arena", "aa-speed", "aa-price", "anthropic-models", "openai-models"])
    }

    func testInitialSetHasNoProblems() {
        XCTAssertEqual(IndexSourceRegistry.problems(IndexSourceRegistry.initial), [])
    }

    func testMachineReadableMatchesTheProbe() {
        XCTAssertEqual(Set(IndexSourceRegistry.initial.filter(\.machineReadable).map(\.id)),
                       ["swe-bench-verified", "aider-polyglot"])
    }

    func testEveryDimensionButDocsProseHasASource() {
        let fed = Set(IndexSourceRegistry.initial.flatMap { s in s.dimensions.filter { $0.value > 0 }.keys })
        XCTAssertEqual(Dimensions.ids.subtracting(fed), ["docs-prose"])
    }

    func testLowerIsBetterUnits() {
        XCTAssertFalse(IndexUnit.usdPerMillionTokens.higherIsBetter)
        XCTAssertFalse(IndexUnit.seconds.higherIsBetter)
        for unit in [IndexUnit.percent, .score, .elo, .tokensPerSecond, .contextTokens] {
            XCTAssertTrue(unit.higherIsBetter, unit.rawValue)
        }
    }

    func testProblemsNameEachBadField() {
        func src(_ id: String, url: String = "https://x.test", dims: [String: Double] = ["speed": 1],
                 how: String = "read it", unit: String = "percent") -> IndexSource {
            var s = IndexSource(id: id, name: id, url: url, dimensions: dims, howToRead: how,
                                unit: .percent, machineReadable: false)
            s.unit = unit
            return s
        }
        XCTAssertEqual(IndexSourceRegistry.problems([
            src("a", url: "ftp://x"), src("b", dims: ["vibes": 1]), src("c", dims: ["speed": 2]),
            src("d", how: " "), src("e", unit: "stars"), src("e")]), [
            "a: url is not a web address",
            "b: unknown dimension vibes", "b: feeds no dimension",
            "c: weight 2.0 for speed is outside 0...1", "c: feeds no dimension",
            "d: no reading instructions",
            "e: unknown unit stars",
            "e: duplicate id"])
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `FD_TEST_FILTER=IndexSourceRegistryTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'IndexSourceRegistry' in scope`.

- [ ] **Step 5: Implement `IndexSources.swift`**

```swift
import Foundation

/// The unit a benchmark reports in. A source reads exactly one.
///
/// Direction lives on the unit, not on the source entry, so a price can never be ranked as if
/// more were better: a hand-added source that reads dollars inherits "lower wins" from its unit
/// instead of from a flag someone has to remember to set.
public enum IndexUnit: String, Codable, Sendable, CaseIterable {
    case percent
    case score
    case elo
    case tokensPerSecond = "tokens-per-second"
    case seconds
    case usdPerMillionTokens = "usd-per-million-tokens"
    case contextTokens = "context-tokens"

    /// False where a smaller figure is the better model (latency, price).
    public var higherIsBetter: Bool {
        switch self {
        case .seconds, .usdPerMillionTokens: false
        case .percent, .score, .elo, .tokensPerSecond, .contextTokens: true
        }
    }
}

/// One public benchmark the capability index reads, as the user edits it in Settings.
///
/// One entry reads ONE metric in ONE unit. A page that publishes two metrics (a speed and price
/// tracker) is two entries with the same `url`: percentiles only mean something among rows that
/// measure the same thing, and ranking tokens-per-second against dollars in one table would make
/// the fastest model look the most expensive.
///
/// `unit` is stored as a string, not an `IndexUnit`, so a config edited by hand with an unknown
/// unit still loads and is reported by `IndexSourceRegistry.problems` rather than failing to
/// decode and taking every other source down with it.
public struct IndexSource: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    /// Dimension id → how strongly this source speaks to it, in 0...1.
    public var dimensions: [String: Double]
    /// Which table or metric the extractor reads, handed to it verbatim.
    public var howToRead: String
    /// An `IndexUnit` raw value. Every row from this source must carry it.
    public var unit: String
    /// Whether `url` serves data (JSON, YAML) rather than a rendered page, as last probed.
    public var machineReadable: Bool
    public var enabled: Bool

    public init(id: String, name: String, url: String, dimensions: [String: Double], howToRead: String,
                unit: IndexUnit, machineReadable: Bool, enabled: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.dimensions = dimensions
        self.howToRead = howToRead; self.unit = unit.rawValue
        self.machineReadable = machineReadable; self.enabled = enabled
    }

    public var indexUnit: IndexUnit? { IndexUnit(rawValue: unit) }
}

public enum IndexSourceRegistry {
    /// The initial set. URLs and `machineReadable` were probed live on 2026-10-04 (plan Task 1).
    /// SWT-bench is beyond the spec's list: without it nothing feeds `test-authoring`, and the
    /// seed kind `tests` weighs that dimension 0.9.
    public static let initial: [IndexSource] = [
        IndexSource(id: "swe-bench-verified", name: "SWE-bench Verified",
                    url: "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json",
                    dimensions: ["agentic-coding": 1.0, "debugging": 0.6],
                    howToRead: "A JSON file. Use the leaderboard whose \"name\" is \"Verified\". Each result is one submission: report the model it ran (from its name, tags or folder) and its resolved percentage. Report every submission; Flight Deck keeps each model's best.",
                    unit: .percent, machineReadable: true),
        IndexSource(id: "swe-bench-pro", name: "SWE-bench Pro",
                    url: "https://scale.com/leaderboard/swe_bench_pro_public",
                    dimensions: ["agentic-coding": 1.0, "large-context-refactor": 0.6],
                    howToRead: "The public leaderboard table: each model's resolve rate in percent.",
                    unit: .percent, machineReadable: false),
        IndexSource(id: "terminal-bench", name: "Terminal-Bench",
                    url: "https://www.tbench.ai/leaderboard",
                    dimensions: ["tool-use-reliability": 1.0, "agentic-coding": 0.5],
                    howToRead: "The leaderboard table: each entry's accuracy in percent. Name the model the entry ran, with its setting in brackets when the table gives one.",
                    unit: .percent, machineReadable: false),
        IndexSource(id: "aider-polyglot", name: "Aider Polyglot",
                    url: "https://raw.githubusercontent.com/Aider-AI/aider/main/aider/website/_data/polyglot_leaderboard.yml",
                    dimensions: ["agentic-coding": 0.5, "algorithmic-reasoning": 0.5],
                    howToRead: "A YAML list. Each entry's `model` is the model name and `pass_rate_2` its score in percent.",
                    unit: .percent, machineReadable: true),
        IndexSource(id: "livecodebench", name: "LiveCodeBench",
                    url: "https://livecodebench.github.io/leaderboard.html",
                    dimensions: ["algorithmic-reasoning": 1.0],
                    howToRead: "The main leaderboard's overall Pass@1 column for the most recent time window.",
                    unit: .percent, machineReadable: false),
        IndexSource(id: "swt-bench", name: "SWT-bench",
                    url: "https://swtbench.com/",
                    dimensions: ["test-authoring": 1.0],
                    howToRead: "The leaderboard's success rate for generating tests that reproduce an issue, in percent.",
                    unit: .percent, machineReadable: false),
        IndexSource(id: "webdev-arena", name: "WebDev Arena",
                    url: "https://lmarena.ai/leaderboard/webdev",
                    dimensions: ["frontend-ui": 1.0],
                    howToRead: "The arena score (an Elo rating) column.",
                    unit: .elo, machineReadable: false),
        IndexSource(id: "aa-speed", name: "Artificial Analysis: speed",
                    url: "https://artificialanalysis.ai/leaderboards/models",
                    dimensions: ["speed": 1.0],
                    howToRead: "Each model's median output speed in tokens per second.",
                    unit: .tokensPerSecond, machineReadable: false),
        IndexSource(id: "aa-price", name: "Artificial Analysis: price",
                    url: "https://artificialanalysis.ai/leaderboards/models",
                    dimensions: ["cost-efficiency": 1.0],
                    howToRead: "Each model's blended price in US dollars per million tokens.",
                    unit: .usdPerMillionTokens, machineReadable: false),
        IndexSource(id: "anthropic-models", name: "Anthropic model overview",
                    url: "https://docs.anthropic.com/en/docs/about-claude/models/overview",
                    dimensions: ["large-context-refactor": 0.4],
                    howToRead: "Each model's context window, in tokens.",
                    unit: .contextTokens, machineReadable: false),
        IndexSource(id: "openai-models", name: "OpenAI model list",
                    url: "https://platform.openai.com/docs/models",
                    dimensions: ["large-context-refactor": 0.4],
                    howToRead: "Each model's context window, in tokens.",
                    unit: .contextTokens, machineReadable: false),
    ]

    /// Everything that would make a source silently contribute nothing, one line each, in source
    /// order. Shown in Settings; never auto-repaired, since the user owns this list.
    public static func problems(_ sources: [IndexSource]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for s in sources {
            if !seen.insert(s.id).inserted { out.append("\(s.id): duplicate id") }
            if s.indexUnit == nil { out.append("\(s.id): unknown unit \(s.unit)") }
            if !(s.url.hasPrefix("https://") || s.url.hasPrefix("http://")) { out.append("\(s.id): url is not a web address") }
            if s.howToRead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("\(s.id): no reading instructions") }
            for (d, w) in s.dimensions.sorted(by: { $0.key < $1.key }) {
                if !Dimensions.isKnown(d) { out.append("\(s.id): unknown dimension \(d)") }
                else if !(0...1).contains(w) { out.append("\(s.id): weight \(w) for \(d) is outside 0...1") }
            }
            if !s.dimensions.contains(where: { Dimensions.isKnown($0.key) && $0.value > 0 && $0.value <= 1 }) {
                out.append("\(s.id): feeds no dimension")
            }
        }
        return out
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=IndexSourceRegistryTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED` and no `error:` lines.

- [ ] **Step 7: Commit**

```bash
git add Sources/IntakeKit/FlightControl/IndexSources.swift Tests/FlightDeckTests/FlightControlL3/Index/IndexSourceRegistryTests.swift
git commit -m "feat: add the capability index source registry with live-probed urls" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Validate extraction rows, with shared test fixtures

**Files:**
- Create: `Sources/IntakeKit/FlightControl/ExtractionValidator.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Index/IndexFixtures.swift`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/extraction-valid.json`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/extraction-mixed.json`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/ExtractionValidatorTests.swift`

**Interfaces:**
- Consumes: `IndexSource`, `IndexUnit`, `IndexSourceRegistry` (Task 1); `AdapterCatalogs`, `AdapterCatalog`, `ModelEntry`, `ModelRef` (L3-0).
- Produces:
  - `public struct ExtractedRow: Codable, Equatable, Sendable { benchmarkModel: String; score: Double; unit: String; url: String?; retrievedAt: String?; quotedFigure: String? }`
  - `public struct ExtractionPayload: Codable, Equatable, Sendable { source: String; rows: [ExtractedRow] }`
  - `public struct AcceptedRow: Codable, Equatable, Sendable { benchmarkModel: String; score: Double; unit: IndexUnit; url: String; retrievedAt: String?; quotedFigure: String }`
  - `public struct RejectedRow: Codable, Equatable, Sendable { row: ExtractedRow; reason: String }`
  - `public enum ExtractionValidator { static func validate(_:for:) -> (accepted: [AcceptedRow], rejected: [RejectedRow]); static func rejection(_:payloadSource:source:) -> String?; static func parseFigure(_:) -> (value: Double, decimals: Int)?; static func figureMatches(_:score:) -> Bool }`
  - Test helper `enum IndexFixtures` with `data(_:ext:)`, `payload(_:)`, `uiDirectory()`, `scratch()`, `catalogs()`, `sol`, `opus`, `sonnet`, `bare(_:)`, `source(_:_:enabled:)`, `payloadJSON(_:_:)`, `stream(_:input:output:isError:)`.

- [ ] **Step 1: Write the recorded extraction outputs**

`extraction-valid.json` — a clean answer, as the agent returns it:

```json
{"source":"terminal-bench","rows":[
 {"benchmarkModel":"GPT-6 Sol (high)","score":61.3,"unit":"percent","url":"https://www.tbench.ai/leaderboard","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"61.3%"},
 {"benchmarkModel":"Opus 5 (high)","score":58.0,"unit":"percent","url":"https://www.tbench.ai/leaderboard","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"58.0%"},
 {"benchmarkModel":"Sonnet 5","score":49.75,"unit":"percent","url":"https://www.tbench.ai/leaderboard","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"49.75 %"}
]}
```

`extraction-mixed.json` — one good row and one of each rejection:

```json
{"source":"terminal-bench","rows":[
 {"benchmarkModel":"GPT-6 Sol (high)","score":61.3,"unit":"percent","url":"https://www.tbench.ai/leaderboard","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"61.3%"},
 {"benchmarkModel":"No Citation","score":40.0,"unit":"percent","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"40.0%"},
 {"benchmarkModel":"Figure Mismatch","score":71.0,"unit":"percent","url":"https://www.tbench.ai/leaderboard","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"17.0%"},
 {"benchmarkModel":"Odd Unit","score":3.0,"unit":"stars","url":"https://www.tbench.ai/leaderboard","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"3 stars"},
 {"benchmarkModel":"Wrong Unit","score":1200,"unit":"elo","url":"https://www.tbench.ai/leaderboard","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"1200"},
 {"benchmarkModel":"Empty Url","score":30.0,"unit":"percent","url":"","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"30%"}
]}
```

- [ ] **Step 2: Write `IndexFixtures.swift` (shared by every later test in this branch)**

```swift
import Foundation
import IntakeKit

/// Fixtures and builders for the capability index tests. Fixture files come from the test
/// bundle's `Fixtures/FlightControlL3/Index` folder reference (subfolders survive, see
/// project.yml). Builders are here, not per test file, so every test speaks about the same
/// three models and the same catalog.
enum IndexFixtures {
    private final class Token {}
    static let subdirectory = "Fixtures/FlightControlL3/Index"

    static func data(_ name: String, ext: String = "json") throws -> Data {
        guard let url = Bundle(for: Token.self).url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            throw NSError(domain: "IndexFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).\(ext)"])
        }
        return try Data(contentsOf: url)
    }

    static func payload(_ name: String) throws -> ExtractionPayload {
        try JSONDecoder().decode(ExtractionPayload.self, from: data(name))
    }

    /// The UI test's snapshot folder, as the unit-test bundle carries it.
    static func uiDirectory() throws -> URL {
        guard let root = Bundle(for: Token.self).resourceURL?
                .appendingPathComponent("\(subdirectory)/ui", isDirectory: true),
              FileManager.default.fileExists(atPath: root.path) else {
            throw NSError(domain: "IndexFixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing fixture folder ui"])
        }
        return root
    }

    /// A path under the temporary directory that does not exist yet. Callers remove it.
    static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("fd-index-\(UUID().uuidString)", isDirectory: true)
    }

    static func catalogs() -> AdapterCatalogs {
        AdapterCatalogs([
            AdapterCatalog(harness: "codex", models: [ModelEntry(id: "gpt-6-sol", displayName: "GPT-6 Sol", knobs: ["effort"])],
                           knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "gpt-6-sol", enabled: true),
            AdapterCatalog(harness: "claude", models: [ModelEntry(id: "opus", displayName: "Opus 5", knobs: ["effort"]),
                                                       ModelEntry(id: "sonnet", displayName: "Sonnet 5", knobs: ["effort"])],
                           knobSchema: ["effort": ["low", "medium", "high"]], defaultModel: "opus", enabled: true),
        ])
    }

    static let sol = ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "high"])
    static let opus = ModelRef(harness: "claude", model: "opus", knobs: ["effort": "high"])
    static let sonnet = ModelRef(harness: "claude", model: "sonnet")

    /// The catalog's view of a model: no knobs.
    static func bare(_ ref: ModelRef) -> ModelRef { ModelRef(harness: ref.harness, model: ref.model) }

    static func source(_ id: String, _ dims: [String: Double] = ["agentic-coding": 1], unit: IndexUnit = .percent,
                       enabled: Bool = true) -> IndexSource {
        IndexSource(id: id, name: id, url: "https://\(id).test", dimensions: dims, howToRead: "the table",
                    unit: unit, machineReadable: false, enabled: enabled)
    }

    /// An agent answer for source `id`, one valid percent row per `(name, score)`.
    static func payloadJSON(_ id: String, _ rows: [(String, Double)]) -> String {
        let body = rows.map {
            #"{"benchmarkModel":"\#($0.0)","score":\#($0.1),"unit":"percent","url":"https://\#(id).test","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"\#($0.1)%"}"#
        }.joined(separator: ",")
        return #"{"source":"\#(id)","rows":[\#(body)]}"#
    }

    /// A `claude -p --output-format stream-json` transcript: the init line, then a `result`
    /// carrying `payloadJSON` as `structured_output` and the given usage (what the token meter
    /// counts).
    static func stream(_ payloadJSON: String, input: Int = 1000, output: Int = 200, isError: Bool = false) -> Data {
        let result = isError
            ? #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s1","result":"boom","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}"#
            : #"{"type":"result","subtype":"success","is_error":false,"session_id":"s1","usage":{"input_tokens":\#(input),"output_tokens":\#(output)},"structured_output":\#(payloadJSON)}"#
        return Data((#"{"type":"system","subtype":"init","session_id":"s1"}"# + "\n" + result + "\n").utf8)
    }
}
```

- [ ] **Step 3: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// The index only ever believes a figure it can cite. These tests run the validator over
/// recorded agent answers and pin the three rejections the spec names — no url, a quoted
/// figure that is not the score, an unknown unit — plus the two that would otherwise let a row
/// in under false pretences: a unit other than the source's, and an answer for another source.
final class ExtractionValidatorTests: XCTestCase {
    private var terminalBench: IndexSource { IndexSourceRegistry.initial.first { $0.id == "terminal-bench" }! }

    func testRecordedValidOutputIsAcceptedWhole() throws {
        let result = ExtractionValidator.validate(try IndexFixtures.payload("extraction-valid"), for: terminalBench)
        XCTAssertEqual(result.rejected, [])
        XCTAssertEqual(result.accepted.map(\.benchmarkModel), ["GPT-6 Sol (high)", "Opus 5 (high)", "Sonnet 5"])
        XCTAssertEqual(result.accepted.first?.unit, .percent)
        XCTAssertEqual(result.accepted.first?.url, "https://www.tbench.ai/leaderboard")
    }

    func testRecordedMixedOutputRejectsEachBadRowWithItsReason() throws {
        let result = ExtractionValidator.validate(try IndexFixtures.payload("extraction-mixed"), for: terminalBench)
        XCTAssertEqual(result.accepted.map(\.benchmarkModel), ["GPT-6 Sol (high)"])
        XCTAssertEqual(result.rejected.map(\.reason), [
            "missing url",
            "quoted figure \"17.0%\" does not match score 71.0",
            "unknown unit stars",
            "unit elo but terminal-bench reads percent",
            "missing url"])
    }

    func testAnAnswerForAnotherSourceIsRejectedWhole() throws {
        var payload = try IndexFixtures.payload("extraction-valid")
        payload.source = "aider-polyglot"
        let result = ExtractionValidator.validate(payload, for: terminalBench)
        XCTAssertEqual(result.accepted, [])
        XCTAssertEqual(Set(result.rejected.map(\.reason)), ["payload is for aider-polyglot, not terminal-bench"])
    }

    func testFigureParsing() {
        XCTAssertTrue(ExtractionValidator.figureMatches("61.3%", score: 61.3))
        XCTAssertTrue(ExtractionValidator.figureMatches("61.3%", score: 61.33), "within half the quoted precision")
        XCTAssertFalse(ExtractionValidator.figureMatches("61.3%", score: 61.36))
        XCTAssertTrue(ExtractionValidator.figureMatches("1,234 Elo", score: 1234))
        XCTAssertTrue(ExtractionValidator.figureMatches("$3.00 / 1M tokens", score: 3))
        XCTAssertTrue(ExtractionValidator.figureMatches("0.42s", score: 0.42))
        XCTAssertFalse(ExtractionValidator.figureMatches("about sixty", score: 60))
        XCTAssertFalse(ExtractionValidator.figureMatches("61.3%", score: 0.613), "a fraction is not the percent it was quoted as")
        XCTAssertNil(ExtractionValidator.parseFigure(""))
        XCTAssertEqual(ExtractionValidator.parseFigure("49.75 %")?.decimals, 2)
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `FD_TEST_FILTER=ExtractionValidatorTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find type 'ExtractionPayload' in scope`.

- [ ] **Step 5: Implement `ExtractionValidator.swift`**

```swift
import Foundation

/// One row as the extraction agent reported it, before validation. `url`, `retrievedAt` and
/// `quotedFigure` are optional HERE so a row missing one is rejected with a reason, instead of
/// failing the whole answer's decode and losing every good row beside it.
public struct ExtractedRow: Codable, Equatable, Sendable {
    public var benchmarkModel: String
    public var score: Double
    public var unit: String
    public var url: String?
    public var retrievedAt: String?
    public var quotedFigure: String?
    public init(benchmarkModel: String, score: Double, unit: String, url: String?, retrievedAt: String?, quotedFigure: String?) {
        self.benchmarkModel = benchmarkModel; self.score = score; self.unit = unit
        self.url = url; self.retrievedAt = retrievedAt; self.quotedFigure = quotedFigure
    }
}

/// The agent's whole answer for one source: `{"source": …, "rows": […]}`.
public struct ExtractionPayload: Codable, Equatable, Sendable {
    public var source: String
    public var rows: [ExtractedRow]
    public init(source: String, rows: [ExtractedRow]) { self.source = source; self.rows = rows }
}

/// A row that passed: it names a model, cites where it was read, and its quoted figure is its
/// score. Only these are ever scored or stored as a snapshot's raw rows.
public struct AcceptedRow: Codable, Equatable, Sendable {
    public var benchmarkModel: String
    public var score: Double
    public var unit: IndexUnit
    public var url: String
    public var retrievedAt: String?
    public var quotedFigure: String
    public init(benchmarkModel: String, score: Double, unit: IndexUnit, url: String, retrievedAt: String?, quotedFigure: String) {
        self.benchmarkModel = benchmarkModel; self.score = score; self.unit = unit
        self.url = url; self.retrievedAt = retrievedAt; self.quotedFigure = quotedFigure
    }
}

public struct RejectedRow: Codable, Equatable, Sendable {
    public var row: ExtractedRow
    public var reason: String
    public init(row: ExtractedRow, reason: String) { self.row = row; self.reason = reason }
}

/// Decides which extracted rows the index may believe.
///
/// The quoted-figure check is the one that catches a model inventing numbers: the agent must
/// copy the figure character for character, and the figure must parse back to the score it
/// claims. A hallucinated score rarely comes with a matching quotation of the page.
public enum ExtractionValidator {
    public static func validate(_ payload: ExtractionPayload, for source: IndexSource)
        -> (accepted: [AcceptedRow], rejected: [RejectedRow]) {
        var accepted: [AcceptedRow] = []
        var rejected: [RejectedRow] = []
        for row in payload.rows {
            if let reason = rejection(row, payloadSource: payload.source, source: source) {
                rejected.append(RejectedRow(row: row, reason: reason))
            } else if let unit = IndexUnit(rawValue: row.unit) {
                accepted.append(AcceptedRow(benchmarkModel: row.benchmarkModel.trimmingCharacters(in: .whitespaces),
                                            score: row.score, unit: unit,
                                            url: (row.url ?? "").trimmingCharacters(in: .whitespaces),
                                            retrievedAt: row.retrievedAt, quotedFigure: row.quotedFigure ?? ""))
            }
        }
        return (accepted, rejected)
    }

    /// Why `row` is rejected, or nil. Checked in this order so the reason names the most basic
    /// fault first: provenance before units before the figure.
    public static func rejection(_ row: ExtractedRow, payloadSource: String, source: IndexSource) -> String? {
        if payloadSource != source.id { return "payload is for \(payloadSource), not \(source.id)" }
        guard let url = row.url?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return "missing url" }
        guard url.hasPrefix("https://") || url.hasPrefix("http://") else { return "url is not a web address: \(url)" }
        guard IndexUnit(rawValue: row.unit) != nil else { return "unknown unit \(row.unit)" }
        guard row.unit == source.unit else { return "unit \(row.unit) but \(source.id) reads \(source.unit)" }
        if row.benchmarkModel.trimmingCharacters(in: .whitespaces).isEmpty { return "missing benchmarkModel" }
        guard row.score.isFinite else { return "score is not a number" }
        guard let figure = row.quotedFigure, figureMatches(figure, score: row.score) else {
            let quoted = row.quotedFigure.map { "\"\($0)\"" } ?? "missing"
            return "quoted figure \(quoted) does not match score \(row.score)"
        }
        return nil
    }

    /// The first number in `text`, and how many decimals it was written with. Thousands commas
    /// are skipped. Hand-rolled rather than a regex: IntakeKit is Swift 6, and a shared
    /// `NSRegularExpression` is not `Sendable`.
    public static func parseFigure(_ text: String) -> (value: Double, decimals: Int)? {
        let chars = Array(text)
        func isDigit(_ i: Int) -> Bool { i < chars.count && chars[i].isASCII && chars[i].isNumber }
        var digits = ""
        var decimals = 0
        var seenDot = false
        var i = 0
        while i < chars.count, !isDigit(i) { i += 1 }
        guard i < chars.count else { return nil }
        while i < chars.count {
            let c = chars[i]
            if isDigit(i) {
                digits.append(c)
                if seenDot { decimals += 1 }
            } else if c == ",", !seenDot, isDigit(i + 1) {
                // A thousands separator: "1,234".
            } else if c == ".", !seenDot, isDigit(i + 1) {
                seenDot = true
                digits.append(".")
            } else {
                break
            }
            i += 1
        }
        guard let value = Double(digits) else { return nil }
        return (value, decimals)
    }

    /// True when `score` lies within half a unit of the quoted figure's last written digit — the
    /// figure, at the precision it was quoted, contains the score. "61.3%" admits 61.25…61.35.
    public static func figureMatches(_ figure: String, score: Double) -> Bool {
        guard let (value, decimals) = parseFigure(figure) else { return false }
        let halfStep = 0.5 / pow(10, Double(decimals))
        return abs(score - value) <= halfStep + 1e-9
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=ExtractionValidatorTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED` and no `error:` lines.

- [ ] **Step 7: Commit**

```bash
git add Sources/IntakeKit/FlightControl/ExtractionValidator.swift Tests/FlightDeckTests/FlightControlL3/Index/IndexFixtures.swift Tests/FlightDeckTests/FlightControlL3/Index/ExtractionValidatorTests.swift Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/extraction-valid.json Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/extraction-mixed.json
git commit -m "feat: reject benchmark rows without a citation, a matching figure or a known unit" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The alias table and alias proposals

**Files:**
- Create: `Sources/IntakeKit/FlightControl/AliasTable.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/AliasTableTests.swift`

**Interfaces:**
- Consumes: `ModelRef`, `HarnessID`, `AdapterCatalogs`, `KindID.normalized` (L3-0).
- Produces:
  - `public enum AliasStatus: String, Codable, Sendable { confirmed, pending, rejected }`
  - `public struct AliasEntry: Codable, Equatable, Sendable { source: String; benchmarkModel: String; model: ModelRef; status: AliasStatus }`
  - `public struct UnmappedName: Codable, Hashable, Comparable, Sendable { source: String; benchmarkModel: String }`
  - `public struct AliasTable: Codable, Equatable, Sendable { entries; init(entries:); model(source:benchmarkModel:) -> ModelRef?; entry(source:benchmarkModel:) -> AliasEntry?; confirmed; pending; addProposals(_:); set(source:benchmarkModel:model:status:); confirm(source:benchmarkModel:) -> Bool; reject(source:benchmarkModel:) -> Bool; remove(source:benchmarkModel:) }`
  - `public enum IndexKeys { static func key(_: ModelRef) -> String; static func label(_: ModelRef) -> String }`
  - `public enum AliasProposer { static func propose(_: [UnmappedName], table: AliasTable, catalogs: AdapterCatalogs) -> [AliasEntry]; static func split(_: String) -> (base: String, setting: String?) }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// "An unmapped model is ignored, never guessed" (spec §5). The table is the only bridge from a
/// leaderboard's name to a model Flight Deck can run, so these tests pin that only a confirmed
/// entry maps, that a proposal is only ever an exact normalized match, and that a name the user
/// rejected is never proposed again.
final class AliasTableTests: XCTestCase {
    private let sol = IndexFixtures.sol, opus = IndexFixtures.opus

    func testOnlyConfirmedAliasesMap() {
        var t = AliasTable()
        t.set(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (high)", model: sol, status: .pending)
        XCTAssertNil(t.model(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (high)"))
        XCTAssertTrue(t.confirm(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (high)"))
        XCTAssertEqual(t.model(source: "terminal-bench", benchmarkModel: " GPT-6 Sol (high) "), sol)
        XCTAssertNil(t.model(source: "aider-polyglot", benchmarkModel: "GPT-6 Sol (high)"), "an alias belongs to one source")
    }

    func testProposalMatchesDisplayNameAndCarriesTheSetting() {
        let p = AliasProposer.propose([UnmappedName(source: "terminal-bench", benchmarkModel: "Opus 5 (high)"),
                                       UnmappedName(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (low)")],
                                      table: AliasTable(), catalogs: IndexFixtures.catalogs())
        XCTAssertEqual(p.map(\.model), [ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "low"]), opus])
        XCTAssertEqual(Set(p.map(\.status)), [.pending])
    }

    func testProposalNeverGuesses() {
        XCTAssertEqual(AliasProposer.propose([UnmappedName(source: "s", benchmarkModel: "Mystery-1"),
                                              UnmappedName(source: "s", benchmarkModel: "Opus 4")],
                                             table: AliasTable(), catalogs: IndexFixtures.catalogs()), [])
    }

    func testRejectedNameIsNeverReproposed() {
        var t = AliasTable()
        t.addProposals([AliasEntry(source: "s", benchmarkModel: "Opus 5 (high)", model: opus, status: .pending)])
        XCTAssertTrue(t.reject(source: "s", benchmarkModel: "Opus 5 (high)"))
        XCTAssertEqual(AliasProposer.propose([UnmappedName(source: "s", benchmarkModel: "Opus 5 (high)")],
                                             table: t, catalogs: IndexFixtures.catalogs()), [])
        t.addProposals([AliasEntry(source: "s", benchmarkModel: "Opus 5 (high)", model: opus, status: .pending)])
        XCTAssertEqual(t.entries.map(\.status), [.rejected])
    }

    func testOneModelAtTwoSettingsKeepsBothKnobs() {
        var t = AliasTable()
        t.set(source: "s", benchmarkModel: "GPT-6 Sol (high)", model: sol, status: .confirmed)
        t.set(source: "s", benchmarkModel: "GPT-6 Sol (low)",
              model: ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "low"]), status: .confirmed)
        XCTAssertEqual(t.model(source: "s", benchmarkModel: "GPT-6 Sol (low)")?.knobs, ["effort": "low"])
        XCTAssertEqual(t.model(source: "s", benchmarkModel: "GPT-6 Sol (high)")?.knobs, ["effort": "high"])
    }

    func testSetReplacesAnExistingMapping() {
        var t = AliasTable()
        t.set(source: "s", benchmarkModel: "X", model: sol, status: .confirmed)
        t.set(source: "s", benchmarkModel: "X", model: opus, status: .confirmed)
        XCTAssertEqual(t.entries.count, 1)
        XCTAssertEqual(t.model(source: "s", benchmarkModel: "X"), opus)
        t.remove(source: "s", benchmarkModel: "X")
        XCTAssertEqual(t.entries, [])
    }

    func testKeyIsStableAcrossKnobOrder() {
        XCTAssertEqual(IndexKeys.key(ModelRef(harness: "codex", model: "m", knobs: ["b": "2", "a": "1"])), "codex/m[a=1,b=2]")
        XCTAssertEqual(IndexKeys.key(IndexFixtures.sonnet), "claude/sonnet")
        XCTAssertEqual(IndexKeys.label(sol), "codex · gpt-6-sol (effort high)")
        XCTAssertEqual(AliasProposer.split("GPT-6 Sol (High)").base, "gpt-6-sol")
        XCTAssertEqual(AliasProposer.split("GPT-6 Sol (High)").setting, "high")
        XCTAssertNil(AliasProposer.split("Sonnet 5").setting)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=AliasTableTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'AliasTable' in scope`.

- [ ] **Step 3: Implement `AliasTable.swift`**

```swift
import Foundation

public enum AliasStatus: String, Codable, Sendable { case confirmed, pending, rejected }

/// `(source, benchmarkModel)` → a model Flight Deck can run, with the knobs that benchmark ran
/// it at ("GPT-6 Sol (high)" → codex gpt-6-sol, effort high).
public struct AliasEntry: Codable, Equatable, Sendable {
    public var source: String
    public var benchmarkModel: String
    public var model: ModelRef
    public var status: AliasStatus
    public init(source: String, benchmarkModel: String, model: ModelRef, status: AliasStatus) {
        self.source = source; self.benchmarkModel = benchmarkModel; self.model = model; self.status = status
    }
}

/// A benchmark name no confirmed alias covers. Kept on the snapshot so Settings can offer to map it.
public struct UnmappedName: Codable, Hashable, Comparable, Sendable {
    public var source: String
    public var benchmarkModel: String
    public init(source: String, benchmarkModel: String) { self.source = source; self.benchmarkModel = benchmarkModel }
    public static func < (a: UnmappedName, b: UnmappedName) -> Bool {
        (a.source, a.benchmarkModel) < (b.source, b.benchmarkModel)
    }
}

/// The alias table. Matching is exact on the source and on the trimmed name — never fuzzy: a
/// guessed mapping would silently credit one model with another's score, and nothing downstream
/// could tell. Proposals exist to make confirming cheap, not to skip it.
public struct AliasTable: Codable, Equatable, Sendable {
    public var entries: [AliasEntry]
    public init(entries: [AliasEntry] = []) { self.entries = entries }

    private static func same(_ e: AliasEntry, _ source: String, _ name: String) -> Bool {
        e.source == source
            && e.benchmarkModel.trimmingCharacters(in: .whitespaces) == name.trimmingCharacters(in: .whitespaces)
    }

    /// The model a name maps to — confirmed entries only.
    public func model(source: String, benchmarkModel: String) -> ModelRef? {
        entries.first { $0.status == .confirmed && Self.same($0, source, benchmarkModel) }?.model
    }

    public func entry(source: String, benchmarkModel: String) -> AliasEntry? {
        entries.first { Self.same($0, source, benchmarkModel) }
    }

    public var confirmed: [AliasEntry] { entries.filter { $0.status == .confirmed } }
    public var pending: [AliasEntry] { entries.filter { $0.status == .pending } }

    /// Adds proposals for names the table has never seen, as pending. A name the user rejected
    /// keeps its `.rejected` entry, which is what stops the next refresh proposing it again.
    public mutating func addProposals(_ proposals: [AliasEntry]) {
        for p in proposals where entry(source: p.source, benchmarkModel: p.benchmarkModel) == nil {
            var e = p
            e.status = .pending
            entries.append(e)
        }
    }

    public mutating func set(source: String, benchmarkModel: String, model: ModelRef, status: AliasStatus) {
        entries.removeAll { Self.same($0, source, benchmarkModel) }
        entries.append(AliasEntry(source: source, benchmarkModel: benchmarkModel, model: model, status: status))
    }

    @discardableResult
    public mutating func confirm(source: String, benchmarkModel: String) -> Bool {
        guard let i = entries.firstIndex(where: { Self.same($0, source, benchmarkModel) }) else { return false }
        entries[i].status = .confirmed
        return true
    }

    @discardableResult
    public mutating func reject(source: String, benchmarkModel: String) -> Bool {
        guard let i = entries.firstIndex(where: { Self.same($0, source, benchmarkModel) }) else { return false }
        entries[i].status = .rejected
        return true
    }

    public mutating func remove(source: String, benchmarkModel: String) {
        entries.removeAll { Self.same($0, source, benchmarkModel) }
    }
}

/// A `ModelRef` as one stable string (`codex/gpt-6-sol[effort=high]`) and as words for the UI.
/// Knobs are sorted, so two refs that differ only in dictionary order are one key.
public enum IndexKeys {
    public static func key(_ ref: ModelRef) -> String {
        let knobs = ref.knobs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        let base = "\(ref.harness.rawValue)/\(ref.model)"
        return knobs.isEmpty ? base : "\(base)[\(knobs)]"
    }

    public static func label(_ ref: ModelRef) -> String {
        let knobs = ref.knobs.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let base = "\(ref.harness.rawValue) · \(ref.model)"
        return knobs.isEmpty ? base : "\(base) (\(knobs))"
    }
}

/// Proposes aliases for names a refresh could not map. A proposal is only ever an EXACT match
/// after normalization (`KindID.normalized`) against a catalog model's id or display name; a
/// bracketed setting becomes a knob only when the catalog's knob schema allows that value. Every
/// proposal is pending until the user confirms it in Settings.
public enum AliasProposer {
    public static func propose(_ names: [UnmappedName], table: AliasTable, catalogs: AdapterCatalogs) -> [AliasEntry] {
        var out: [AliasEntry] = []
        for name in names.sorted() {
            guard table.entry(source: name.source, benchmarkModel: name.benchmarkModel) == nil,
                  !out.contains(where: { $0.source == name.source && $0.benchmarkModel == name.benchmarkModel }),
                  let ref = match(name.benchmarkModel, catalogs: catalogs) else { continue }
            out.append(AliasEntry(source: name.source, benchmarkModel: name.benchmarkModel, model: ref, status: .pending))
        }
        return out
    }

    /// "GPT-6 Sol (High)" → ("gpt-6-sol", "high").
    public static func split(_ name: String) -> (base: String, setting: String?) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else {
            return (KindID.normalized(trimmed).rawValue, nil)
        }
        let inner = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .trimmingCharacters(in: .whitespaces).lowercased()
        return (KindID.normalized(String(trimmed[..<open])).rawValue, inner.isEmpty ? nil : inner)
    }

    static func match(_ name: String, catalogs: AdapterCatalogs) -> ModelRef? {
        let (base, setting) = split(name)
        guard !base.isEmpty else { return nil }
        for harness in catalogs.order {
            guard let cat = catalogs.byHarness[harness] else { continue }
            for entry in cat.models where KindID.normalized(entry.id).rawValue == base
                || KindID.normalized(entry.displayName).rawValue == base {
                var knobs: [String: String] = [:]
                if let setting, let knob = entry.knobs.sorted().first(where: { cat.knobSchema[$0]?.contains(setting) == true }) {
                    knobs[knob] = setting
                }
                return ModelRef(harness: harness, model: entry.id, knobs: knobs)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=AliasTableTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/AliasTable.swift Tests/FlightDeckTests/FlightControlL3/Index/AliasTableTests.swift
git commit -m "feat: map benchmark model names to runnable models only through confirmed aliases" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The snapshot model, stamps and the index config

**Files:**
- Create: `Sources/IntakeKit/FlightControl/IndexSnapshot.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/IndexSnapshotCodingTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3; `ModelRef` (L3-0).
- Produces:
  - `public enum IndexStamp { static func string(_: Date) -> String; static func date(_: String) -> Date? }` — UTC `yyyy-MM-dd'T'HHmmss'Z'`
  - `public struct SourceResult: Codable, Equatable, Sendable { sourceID; rows: [AcceptedRow]; rejected: [RejectedRow]; stale: Bool; error: String?; refreshedAt: Date?; tokens: Int }`
  - `public enum ScoreOrigin: String, Codable, Sendable { computed, manual, inherited }`
  - `public struct DimensionScore: Codable, Equatable, Sendable { score; confidence; origin; inheritedFrom: ModelRef?; sources: [String] }`
  - `public struct ModelScores: Codable, Equatable, Sendable { model: ModelRef; dimensions: [String: DimensionScore] }`
  - `public struct IndexSnapshot: Codable, Equatable, Sendable { static currentVersion = 1; v; createdAt; sources: [SourceResult]; aliases: [AliasEntry]; scores: [ModelScores]; unmapped: [UnmappedName]; static encoder(); static decoder() }`
  - `public struct ManualModelScores: Codable, Equatable, Sendable { static defaultDiscount = 0.85; model; dimensions: [String: Double]; inheritFrom: ModelRef?; discount: Double }`
  - `public struct IndexAgentSettings: Codable, Equatable, Sendable { model; effort; tokenCap: Int; static standard }`
  - `public struct IndexConfig: Codable, Equatable, Sendable { v; sources; aliases; manual; agent; lastRefreshAttemptAt: Date?; static initial(); static load(from:) -> (config: IndexConfig, problem: String?); func save(to:) throws }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// Snapshots and the config are the index's only state on disk. These tests pin that a snapshot
/// round-trips exactly, that its file stamp is UTC whatever zone the Mac is in (a zone change
/// must never reorder which snapshot is newest), and that a config Flight Deck cannot read is
/// moved aside rather than overwritten — it holds the user's confirmed aliases and hand scores.
final class IndexSnapshotCodingTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21T14:13:20Z

    static func sample(at: Date) -> IndexSnapshot {
        let row = AcceptedRow(benchmarkModel: "GPT-6 Sol (high)", score: 61.3, unit: .percent,
                              url: "https://www.tbench.ai/leaderboard", retrievedAt: "2026-09-21T14:13:20Z", quotedFigure: "61.3%")
        return IndexSnapshot(
            createdAt: at,
            sources: [SourceResult(sourceID: "terminal-bench", rows: [row], refreshedAt: at, tokens: 1200),
                      SourceResult(sourceID: "aider-polyglot", rows: [], stale: true, error: "token cap reached", refreshedAt: nil)],
            aliases: [AliasEntry(source: "terminal-bench", benchmarkModel: "GPT-6 Sol (high)", model: IndexFixtures.sol, status: .confirmed)],
            scores: [ModelScores(model: IndexFixtures.sol, dimensions: [
                "tool-use-reliability": DimensionScore(score: 1, confidence: 0.5, sources: ["terminal-bench"])])],
            unmapped: [UnmappedName(source: "terminal-bench", benchmarkModel: "Mystery-1")])
    }

    func testSnapshotRoundTrips() throws {
        let s = Self.sample(at: at)
        let data = try IndexSnapshot.encoder().encode(s)
        XCTAssertEqual(try IndexSnapshot.decoder().decode(IndexSnapshot.self, from: data), s)
    }

    func testStampIsUTCWhateverTheLocalTimeZone() {
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        NSTimeZone.default = TimeZone(identifier: "Pacific/Kiritimati")!   // UTC+14
        XCTAssertEqual(IndexStamp.string(at), "2026-09-21T141320Z")
        XCTAssertEqual(IndexStamp.date("2026-09-21T141320Z"), at)
        XCTAssertNil(IndexStamp.date("2026-09-21"), "a bare date is not a stamp")
        XCTAssertNil(IndexStamp.date("config"))
        XCTAssertLessThan(IndexStamp.string(at), IndexStamp.string(at.addingTimeInterval(1)), "stamps sort as time does")
    }

    func testConfigMissingKeysFallBackToDefaults() throws {
        let c = try IndexSnapshot.decoder().decode(IndexConfig.self, from: Data(#"{"v":1}"#.utf8))
        XCTAssertEqual(c.sources, IndexSourceRegistry.initial)
        XCTAssertEqual(c.agent, .standard)
        XCTAssertEqual(c.aliases, AliasTable())
        XCTAssertNil(c.lastRefreshAttemptAt)
    }

    func testConfigRoundTripsThroughDisk() throws {
        let dir = IndexFixtures.scratch()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var c = IndexConfig.initial()
        c.manual = [ManualModelScores(model: ModelRef(harness: "opencode", model: "ollama/qwen"), dimensions: ["debugging": 0.7],
                                      inheritFrom: IndexFixtures.sol)]
        c.lastRefreshAttemptAt = at
        let url = dir.appendingPathComponent("config.json")
        try c.save(to: url)
        let (loaded, problem) = IndexConfig.load(from: url)
        XCTAssertEqual(loaded, c)
        XCTAssertNil(problem)
        XCTAssertEqual(loaded.manual.first?.discount, 0.85)
    }

    func testUnreadableConfigIsMovedAsideAndReported() throws {
        let dir = IndexFixtures.scratch()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data("{ not json".utf8).write(to: url)
        let (config, problem) = IndexConfig.load(from: url)
        XCTAssertEqual(config, IndexConfig.initial())
        XCTAssertNotNil(problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the unreadable file must not stay where the next save would overwrite it")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("config.unreadable-") }.count, 1)
    }

    func testMissingConfigIsInitialWithoutAProblem() {
        let (config, problem) = IndexConfig.load(from: IndexFixtures.scratch().appendingPathComponent("config.json"))
        XCTAssertEqual(config, IndexConfig.initial())
        XCTAssertNil(problem)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=IndexSnapshotCodingTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'IndexSnapshot' in scope`.

- [ ] **Step 3: Implement `IndexSnapshot.swift`**

```swift
import Foundation

/// A snapshot's file stamp: `2026-10-04T060000Z`.
///
/// UTC so a timezone change (travel, a DST edge) can never reorder which snapshot is newest —
/// "newest" is decided by sorting these strings. Date AND time so two refreshes on one day (or
/// a refresh and an alias rescore) never overwrite each other. No colons, so Finder shows the
/// name as written instead of turning `:` into `/`. A fresh formatter per call: `DateFormatter`
/// is not `Sendable`, so IntakeKit cannot keep one in a static.
public enum IndexStamp {
    private static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return f
    }

    public static func string(_ date: Date) -> String { formatter().string(from: date) }

    /// Nil unless `stamp` is exactly what `string` would write — so `config.json` or a
    /// hand-made `2026-10-04.json` is never mistaken for a snapshot.
    public static func date(_ stamp: String) -> Date? {
        let f = formatter()
        guard let d = f.date(from: stamp), f.string(from: d) == stamp else { return nil }
        return d
    }
}

/// What one refresh got from one source. `stale` means the rows are the PREVIOUS snapshot's,
/// carried forward because this refresh could not read the source (`error` says why) — the
/// index keeps scoring with them rather than dropping a model's data on one bad run.
public struct SourceResult: Codable, Equatable, Sendable {
    public var sourceID: String
    public var rows: [AcceptedRow]
    public var rejected: [RejectedRow]
    public var stale: Bool
    public var error: String?
    /// When `rows` were read. A carried-forward result keeps the original read time.
    public var refreshedAt: Date?
    public var tokens: Int
    public init(sourceID: String, rows: [AcceptedRow], rejected: [RejectedRow] = [], stale: Bool = false,
                error: String? = nil, refreshedAt: Date?, tokens: Int = 0) {
        self.sourceID = sourceID; self.rows = rows; self.rejected = rejected; self.stale = stale
        self.error = error; self.refreshedAt = refreshedAt; self.tokens = tokens
    }
}

public enum ScoreOrigin: String, Codable, Sendable { case computed, manual, inherited }

/// One model's score on one dimension, 0...1, with the share of that dimension's source weight
/// that stood behind it. Absent — never zero — when nothing did.
public struct DimensionScore: Codable, Equatable, Sendable {
    public var score: Double
    public var confidence: Double
    public var origin: ScoreOrigin
    public var inheritedFrom: ModelRef?
    /// Source ids whose rows produced this score.
    public var sources: [String]
    public init(score: Double, confidence: Double, origin: ScoreOrigin = .computed,
                inheritedFrom: ModelRef? = nil, sources: [String] = []) {
        self.score = score; self.confidence = confidence; self.origin = origin
        self.inheritedFrom = inheritedFrom; self.sources = sources
    }
}

public struct ModelScores: Codable, Equatable, Sendable {
    public var model: ModelRef
    public var dimensions: [String: DimensionScore]
    public init(model: ModelRef, dimensions: [String: DimensionScore]) { self.model = model; self.dimensions = dimensions }
}

/// One refresh's result, as written to `capability-index/<stamp>.json`: raw rows per source,
/// the confirmed aliases they were scored with, the computed scores, and the names nobody has
/// mapped. Manual and inherited scores are NOT stored here — they are overlaid live from the
/// config (`CapabilityScoring.overlay`), so editing one never needs a refresh and the diff
/// between two snapshots shows only what the benchmarks moved.
public struct IndexSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var v: Int
    public var createdAt: Date
    public var sources: [SourceResult]
    public var aliases: [AliasEntry]
    public var scores: [ModelScores]
    public var unmapped: [UnmappedName]

    public init(v: Int = IndexSnapshot.currentVersion, createdAt: Date, sources: [SourceResult],
                aliases: [AliasEntry], scores: [ModelScores], unmapped: [UnmappedName]) {
        self.v = v; self.createdAt = createdAt; self.sources = sources
        self.aliases = aliases; self.scores = scores; self.unmapped = unmapped
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Hand-entered scores for a model no benchmark lists (a local model). A hand score has
/// confidence 1 and is labelled manual. `inheritFrom` copies a base model's scores at
/// `discount` for every dimension that has neither a hand score nor a computed one.
public struct ManualModelScores: Codable, Equatable, Sendable {
    public static let defaultDiscount = 0.85
    public var model: ModelRef
    public var dimensions: [String: Double]
    public var inheritFrom: ModelRef?
    public var discount: Double
    public init(model: ModelRef, dimensions: [String: Double], inheritFrom: ModelRef? = nil,
                discount: Double = ManualModelScores.defaultDiscount) {
        self.model = model; self.dimensions = dimensions; self.inheritFrom = inheritFrom; self.discount = discount
    }
}

/// The refresh agent. claude only in v1: it is the harness whose web tools and `--restricted`
/// isolation were probed (claude 2.1.289 `--help`: `--restricted` removes WebFetch "unless
/// --tools names them").
public struct IndexAgentSettings: Codable, Equatable, Sendable {
    public var model: String
    public var effort: String
    /// Input plus output tokens for one whole refresh, all sources together.
    public var tokenCap: Int
    public init(model: String, effort: String, tokenCap: Int) { self.model = model; self.effort = effort; self.tokenCap = tokenCap }
    public static let standard = IndexAgentSettings(model: "sonnet", effort: "medium", tokenCap: 1_500_000)
}

/// `capability-index/config.json`: everything the user edits in Settings.
public struct IndexConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var v: Int
    public var sources: [IndexSource]
    public var aliases: AliasTable
    public var manual: [ManualModelScores]
    public var agent: IndexAgentSettings
    /// Set at the START of every refresh attempt, success or failure. The weekly check reads it,
    /// so a run that fails waits a week instead of retrying on every clock beat.
    public var lastRefreshAttemptAt: Date?

    public init(v: Int = IndexConfig.currentVersion, sources: [IndexSource], aliases: AliasTable,
                manual: [ManualModelScores], agent: IndexAgentSettings, lastRefreshAttemptAt: Date?) {
        self.v = v; self.sources = sources; self.aliases = aliases; self.manual = manual
        self.agent = agent; self.lastRefreshAttemptAt = lastRefreshAttemptAt
    }

    public static func initial() -> IndexConfig {
        IndexConfig(sources: IndexSourceRegistry.initial, aliases: AliasTable(), manual: [], agent: .standard,
                    lastRefreshAttemptAt: nil)
    }

    private enum CodingKeys: String, CodingKey { case v, sources, aliases, manual, agent, lastRefreshAttemptAt }

    /// Every key optional: a config written before a key existed must load with that key's
    /// default, not fail and be moved aside with the user's aliases in it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? IndexConfig.currentVersion
        sources = try c.decodeIfPresent([IndexSource].self, forKey: .sources) ?? IndexSourceRegistry.initial
        aliases = try c.decodeIfPresent(AliasTable.self, forKey: .aliases) ?? AliasTable()
        manual = try c.decodeIfPresent([ManualModelScores].self, forKey: .manual) ?? []
        agent = try c.decodeIfPresent(IndexAgentSettings.self, forKey: .agent) ?? .standard
        lastRefreshAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastRefreshAttemptAt)
    }

    /// A missing file is a first launch: the initial config, no problem. A file that exists but
    /// does not decode (or is from a newer Flight Deck) is moved aside to
    /// `config.unreadable-<stamp>.json` before the initial config is returned — the next save
    /// would otherwise overwrite the user's aliases and hand scores in place.
    public static func load(from url: URL) -> (config: IndexConfig, problem: String?) {
        guard let data = try? Data(contentsOf: url) else { return (initial(), nil) }
        if let config = try? IndexSnapshot.decoder().decode(IndexConfig.self, from: data), config.v <= currentVersion {
            return (config, nil)
        }
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("config.unreadable-\(IndexStamp.string(Date())).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        return (initial(), "Capability index settings could not be read. They were moved to \(aside.lastPathComponent) and the defaults loaded.")
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try IndexSnapshot.encoder().encode(self).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=IndexSnapshotCodingTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/IndexSnapshot.swift Tests/FlightDeckTests/FlightControlL3/Index/IndexSnapshotCodingTests.swift
git commit -m "feat: add capability index snapshots, utc stamps and a config that never overwrites an unreadable file" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Scoring — percentiles, dimensions, hand and inherited scores

**Files:**
- Create: `Sources/IntakeKit/FlightControl/CapabilityScoring.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/CapabilityScoringTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4; `Dimensions.isKnown` (L3-0).
- Produces:
  - `public enum CapabilityScoring { static func percentiles(_ values: [Double], higherIsBetter: Bool) -> [Double]?; static func computeScores(results: [SourceResult], sources: [IndexSource], aliases: AliasTable) -> (scores: [ModelScores], unmapped: [UnmappedName]); static func overlay(_ computed: [ModelScores], manual: [ManualModelScores]) -> [ModelScores] }`
  - `extension IndexSnapshot { static func assemble(results:sources:aliases:createdAt:) -> IndexSnapshot }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// Spec §6, rule by rule: a benchmark ranks models by percentile; a dimension is the weighted
/// mean over the benchmarks present, with confidence the present weight's share; no data is
/// unknown, never zero; hand scores win with confidence 1; an inherited score is discounted.
/// Every table here is small enough to check by hand — the expected values are worked in the
/// comments.
final class CapabilityScoringTests: XCTestCase {
    private let sol = IndexFixtures.sol, opus = IndexFixtures.opus, sonnet = IndexFixtures.sonnet

    private func row(_ name: String, _ score: Double, unit: IndexUnit = .percent) -> AcceptedRow {
        AcceptedRow(benchmarkModel: name, score: score, unit: unit, url: "https://x.test", retrievedAt: nil, quotedFigure: "\(score)")
    }
    private func result(_ id: String, _ rows: [AcceptedRow], stale: Bool = false) -> SourceResult {
        SourceResult(sourceID: id, rows: rows, stale: stale, refreshedAt: nil)
    }
    private func aliases(_ pairs: [(String, String, ModelRef)]) -> AliasTable {
        var t = AliasTable()
        for (s, n, m) in pairs { t.set(source: s, benchmarkModel: n, model: m, status: .confirmed) }
        return t
    }
    private func dim(_ scores: [ModelScores], _ ref: ModelRef, _ d: String) -> DimensionScore? {
        scores.first { $0.model == ref }?.dimensions[d]
    }

    func testPercentileRanksWorstToZeroAndBestToOne() {
        XCTAssertEqual(CapabilityScoring.percentiles([10, 20, 30], higherIsBetter: true), [0, 0.5, 1])
    }

    func testTiesShareTheirMiddle() {
        XCTAssertEqual(CapabilityScoring.percentiles([10, 10, 30], higherIsBetter: true), [0.25, 0.25, 1])
    }

    func testLowerIsBetterUnitInvertsPercentile() {
        XCTAssertEqual(CapabilityScoring.percentiles([1.0, 3.0], higherIsBetter: false), [1, 0])
        let price = IndexFixtures.source("price", ["cost-efficiency": 1], unit: .usdPerMillionTokens)
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("price", [row("Cheap", 1.0, unit: .usdPerMillionTokens), row("Dear", 15.0, unit: .usdPerMillionTokens)])],
            sources: [price], aliases: aliases([("price", "Cheap", sonnet), ("price", "Dear", opus)]))
        XCTAssertEqual(dim(scores, sonnet, "cost-efficiency")?.score, 1, "the cheaper model must score higher on cost-efficiency")
        XCTAssertEqual(dim(scores, opus, "cost-efficiency")?.score, 0)
    }

    func testSingleRowBenchmarkContributesNothing() {
        XCTAssertNil(CapabilityScoring.percentiles([42], higherIsBetter: true))
        let (scores, unmapped) = CapabilityScoring.computeScores(
            results: [result("a", [row("GPT-6 Sol (high)", 42)])],
            sources: [IndexFixtures.source("a")], aliases: aliases([("a", "GPT-6 Sol (high)", sol)]))
        XCTAssertEqual(scores, [], "one row ranks against nothing; it must read neither as best nor as middling")
        XCTAssertEqual(unmapped, [])
    }

    func testDimensionIsWeightedMeanAndConfidenceIsPresentWeightShare() {
        let a = IndexFixtures.source("a", ["agentic-coding": 1.0])
        let b = IndexFixtures.source("b", ["agentic-coding": 0.5])
        let c = IndexFixtures.source("c", ["agentic-coding": 0.5])
        let (scores, unmapped) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 30), row("Opus", 10)]),
                      result("b", [row("Sol", 5), row("Opus", 10)]),
                      result("c", [row("Opus", 1), row("X", 2)])],
            sources: [a, b, c],
            aliases: aliases([("a", "Sol", sol), ("a", "Opus", opus), ("b", "Sol", sol), ("b", "Opus", opus), ("c", "Opus", opus)]))
        // sol: a → 1 (weight 1.0), b → 0 (weight 0.5): (1×1 + 0.5×0) / 1.5; present 1.5 of 2.0.
        XCTAssertEqual(dim(scores, sol, "agentic-coding")!.score, 1.0 / 1.5, accuracy: 1e-12)
        XCTAssertEqual(dim(scores, sol, "agentic-coding")!.confidence, 0.75, accuracy: 1e-12)
        XCTAssertEqual(dim(scores, sol, "agentic-coding")!.sources, ["a", "b"])
        // opus: a → 0, b → 1, c → 0 (X beats it): 0.5 / 2.0; every source present.
        XCTAssertEqual(dim(scores, opus, "agentic-coding")!.score, 0.25, accuracy: 1e-12)
        XCTAssertEqual(dim(scores, opus, "agentic-coding")!.confidence, 1, accuracy: 1e-12)
        XCTAssertEqual(unmapped, [UnmappedName(source: "c", benchmarkModel: "X")])
    }

    func testUnknownIsAbsentNeverZero() {
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 30), row("Opus", 10)])],
            sources: [IndexFixtures.source("a", ["agentic-coding": 1])], aliases: aliases([("a", "Sol", sol)]))
        XCTAssertNotNil(dim(scores, sol, "agentic-coding"))
        XCTAssertNil(dim(scores, sol, "debugging"), "no data is unknown, not zero")
    }

    func testUnmappedRowsAreIgnoredButStillCompete() {
        let (scores, unmapped) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 10), row("Better Unknown", 20)])],
            sources: [IndexFixtures.source("a")], aliases: aliases([("a", "Sol", sol)]))
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.score, 0, "an unmapped model that beats sol still beats it")
        XCTAssertEqual(scores.map(\.model), [sol], "the unmapped model itself is never scored")
        XCTAssertEqual(unmapped, [UnmappedName(source: "a", benchmarkModel: "Better Unknown")])
    }

    func testTwoNamesForOneModelKeepTheBestRow() {
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol A", 10), row("Sol B", 30), row("Opus", 20)])],
            sources: [IndexFixtures.source("a")],
            aliases: aliases([("a", "Sol A", sol), ("a", "Sol B", sol), ("a", "Opus", opus)]))
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.score, 1)
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.sources, ["a"], "one source counts once, however many names map to the model")
    }

    func testDisabledSourceIsLeftOutOfScoreAndConfidence() {
        let a = IndexFixtures.source("a", ["agentic-coding": 1])
        let off = IndexFixtures.source("off", ["agentic-coding": 1], enabled: false)
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 30), row("Opus", 10)]), result("off", [row("Sol", 1), row("Opus", 10)])],
            sources: [a, off], aliases: aliases([("a", "Sol", sol), ("off", "Sol", sol)]))
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.score, 1)
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.confidence, 1)
    }

    func testStaleRowsStillScore() {
        let (scores, _) = CapabilityScoring.computeScores(
            results: [result("a", [row("Sol", 30), row("Opus", 10)], stale: true)],
            sources: [IndexFixtures.source("a")], aliases: aliases([("a", "Sol", sol)]))
        XCTAssertEqual(dim(scores, sol, "agentic-coding")?.score, 1)
    }

    func testManualScoresWinWithConfidenceOne() {
        let computed = [ModelScores(model: sol, dimensions: ["debugging": DimensionScore(score: 0.2, confidence: 0.5)])]
        let local = ModelRef(harness: "opencode", model: "ollama/qwen")
        let out = CapabilityScoring.overlay(computed, manual: [
            ManualModelScores(model: local, dimensions: ["debugging": 0.7, "vibes": 1]),
            ManualModelScores(model: sol, dimensions: ["debugging": 0.9])])
        XCTAssertEqual(dim(out, local, "debugging"), DimensionScore(score: 0.7, confidence: 1, origin: .manual))
        XCTAssertNil(dim(out, local, "vibes"), "a hand score on an unknown dimension is dropped")
        XCTAssertEqual(dim(out, sol, "debugging")?.origin, .manual, "a hand score beats a computed one")
    }

    func testInheritedScoresAreDiscountedAndLabelled() {
        let computed = [ModelScores(model: sol, dimensions: [
            "agentic-coding": DimensionScore(score: 0.8, confidence: 0.75, sources: ["a"]),
            "debugging": DimensionScore(score: 0.4, confidence: 1, sources: ["b"])])]
        let local = ModelRef(harness: "opencode", model: "ollama/qwen")
        let out = CapabilityScoring.overlay(computed, manual: [
            ManualModelScores(model: local, dimensions: ["debugging": 0.9], inheritFrom: sol)])
        let inherited = dim(out, local, "agentic-coding")!
        XCTAssertEqual(inherited.score, 0.68, accuracy: 1e-12)   // 0.8 × 0.85
        XCTAssertEqual(inherited.confidence, 0.75)
        XCTAssertEqual(inherited.origin, .inherited)
        XCTAssertEqual(inherited.inheritedFrom, sol)
        XCTAssertEqual(dim(out, local, "debugging")?.origin, .manual, "a hand score beats an inherited one")
    }

    func testComputedBeatsInherited() {
        let local = ModelRef(harness: "opencode", model: "ollama/qwen")
        let computed = [ModelScores(model: sol, dimensions: ["agentic-coding": DimensionScore(score: 0.8, confidence: 1)]),
                        ModelScores(model: local, dimensions: ["agentic-coding": DimensionScore(score: 0.3, confidence: 0.2)])]
        let out = CapabilityScoring.overlay(computed, manual: [ManualModelScores(model: local, dimensions: [:], inheritFrom: sol)])
        XCTAssertEqual(dim(out, local, "agentic-coding")?.score, 0.3)
        XCTAssertEqual(dim(out, local, "agentic-coding")?.origin, .computed)
    }

    func testAssembleKeepsOnlyConfirmedAliasesAndScoresTheRows() {
        var table = aliases([("a", "Sol", sol)])
        table.addProposals([AliasEntry(source: "a", benchmarkModel: "Opus", model: opus, status: .pending)])
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let snap = IndexSnapshot.assemble(results: [result("a", [row("Sol", 30), row("Opus", 10)])],
                                          sources: [IndexFixtures.source("a")], aliases: table, createdAt: at)
        XCTAssertEqual(snap.aliases.map(\.benchmarkModel), ["Sol"])
        XCTAssertEqual(snap.scores.map(\.model), [sol])
        XCTAssertEqual(snap.unmapped, [UnmappedName(source: "a", benchmarkModel: "Opus")])
        XCTAssertEqual(snap.createdAt, at)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=CapabilityScoringTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'CapabilityScoring' in scope`.

- [ ] **Step 3: Implement `CapabilityScoring.swift`**

```swift
import Foundation

/// Turns benchmark rows into per-dimension scores (spec §6). Pure: every rule is a table test.
public enum CapabilityScoring {
    /// Each value's percentile among `values`: worst 0, best 1, ties sharing the middle of the
    /// places they span. Nil below two values — one row ranks against nothing, and calling it
    /// 1.0 (or 0.5) would invent a signal the benchmark never gave.
    public static func percentiles(_ values: [Double], higherIsBetter: Bool) -> [Double]? {
        guard values.count >= 2 else { return nil }
        let span = Double(values.count - 1)
        return values.map { v in
            var worse = 0
            var equal = 0
            for w in values {
                if w == v { equal += 1 } else if (higherIsBetter ? (w < v) : (w > v)) { worse += 1 }
            }
            return (Double(worse) + Double(equal - 1) / 2) / span
        }
    }

    private struct Sum {
        var num = 0.0
        var den = 0.0
        var sources: [String] = []
    }

    /// Known dimensions with a weight in (0, 1], sorted. A bad weight in a hand-edited config
    /// contributes nothing rather than skewing a mean (`IndexSourceRegistry.problems` reports it).
    static func usableWeights(_ s: IndexSource) -> [(String, Double)] {
        s.dimensions.filter { Dimensions.isKnown($0.key) && $0.value > 0 && $0.value <= 1 }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Per benchmark: percentile among ALL that source's accepted rows — unmapped names included,
    /// since they are real competitors on that benchmark. Per dimension: the weighted mean over
    /// the sources present for the model; confidence = present weight / the dimension's total
    /// weight across enabled sources. Two names mapped to one model in one source keep the better
    /// row. Disabled sources and sources with a unit nobody knows are left out entirely.
    public static func computeScores(results: [SourceResult], sources: [IndexSource], aliases: AliasTable)
        -> (scores: [ModelScores], unmapped: [UnmappedName]) {
        let enabled = sources.filter(\.enabled)
        var total: [String: Double] = [:]
        for s in enabled where s.indexUnit != nil {
            for (d, w) in usableWeights(s) { total[d, default: 0] += w }
        }

        var sums: [ModelRef: [String: Sum]] = [:]
        var unmapped: Set<UnmappedName> = []
        for result in results {
            guard let source = enabled.first(where: { $0.id == result.sourceID }), let unit = source.indexUnit else { continue }
            let ranks = percentiles(result.rows.map(\.score), higherIsBetter: unit.higherIsBetter)
            var best: [ModelRef: Double] = [:]
            for (i, row) in result.rows.enumerated() {
                guard let ref = aliases.model(source: source.id, benchmarkModel: row.benchmarkModel) else {
                    unmapped.insert(UnmappedName(source: source.id, benchmarkModel: row.benchmarkModel))
                    continue
                }
                guard let ranks else { continue }
                best[ref] = max(best[ref] ?? -1, ranks[i])
            }
            for (ref, p) in best {
                for (d, w) in usableWeights(source) {
                    var cell = sums[ref, default: [:]][d] ?? Sum()
                    cell.num += w * p
                    cell.den += w
                    cell.sources.append(source.id)
                    sums[ref, default: [:]][d] = cell
                }
            }
        }

        let scores = sums.map { ref, dims in
            ModelScores(model: ref, dimensions: Dictionary(uniqueKeysWithValues: dims.map { d, s in
                (d, DimensionScore(score: s.num / s.den, confidence: min(1, s.den / (total[d] ?? s.den)),
                                   origin: .computed, sources: s.sources.sorted()))
            }))
        }
        return (scores.sorted { IndexKeys.key($0.model) < IndexKeys.key($1.model) }, unmapped.sorted())
    }

    /// Computed scores with the config's hand-entered and inherited scores laid over them.
    /// Per dimension: manual > computed > inherited. A hand score has confidence 1. Inheritance
    /// copies the base's computed-plus-manual scores (not the base's own inheritance, so a chain
    /// or a cycle cannot form) at `discount`, keeping the base's confidence.
    public static func overlay(_ computed: [ModelScores], manual: [ManualModelScores]) -> [ModelScores] {
        var byKey: [String: ModelScores] = [:]
        for m in computed { byKey[IndexKeys.key(m.model)] = m }
        let computedByKey = byKey
        var manualByKey: [String: ManualModelScores] = [:]
        for m in manual { manualByKey[IndexKeys.key(m.model)] = m }

        for m in manual {
            let key = IndexKeys.key(m.model)
            var dims = computedByKey[key]?.dimensions ?? [:]
            if let base = m.inheritFrom {
                let baseKey = IndexKeys.key(base)
                var baseDims = computedByKey[baseKey]?.dimensions ?? [:]
                if let baseManual = manualByKey[baseKey] { baseDims.merge(handEntered(baseManual)) { _, hand in hand } }
                for (d, s) in baseDims where dims[d] == nil {
                    dims[d] = DimensionScore(score: s.score * m.discount, confidence: s.confidence,
                                             origin: .inherited, inheritedFrom: base, sources: s.sources)
                }
            }
            dims.merge(handEntered(m)) { _, hand in hand }
            byKey[key] = ModelScores(model: m.model, dimensions: dims)
        }
        return byKey.values.sorted { IndexKeys.key($0.model) < IndexKeys.key($1.model) }
    }

    static func handEntered(_ m: ManualModelScores) -> [String: DimensionScore] {
        var out: [String: DimensionScore] = [:]
        for (d, v) in m.dimensions where Dimensions.isKnown(d) {
            out[d] = DimensionScore(score: min(1, max(0, v)), confidence: 1, origin: .manual)
        }
        return out
    }
}

extension IndexSnapshot {
    /// The one place a snapshot is built from source results — for a refresh and for an alias
    /// rescore alike — so the two can never score the same rows differently.
    public static func assemble(results: [SourceResult], sources: [IndexSource], aliases: AliasTable,
                                createdAt: Date) -> IndexSnapshot {
        let (scores, unmapped) = CapabilityScoring.computeScores(results: results, sources: sources, aliases: aliases)
        return IndexSnapshot(createdAt: createdAt, sources: results, aliases: aliases.confirmed,
                             scores: scores, unmapped: unmapped)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=CapabilityScoringTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/CapabilityScoring.swift Tests/FlightDeckTests/FlightControlL3/Index/CapabilityScoringTests.swift
git commit -m "feat: score models per capability dimension from benchmark percentiles with confidence" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `rank`, citations and the snapshot `CapabilityIndex`

**Files:**
- Modify: `Sources/IntakeKit/FlightControl/CapabilityScoring.swift` (append)
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/CapabilityRankTests.swift`

**Interfaces:**
- Consumes: Task 5; `TaskKind`, `ScoredModel`, `CapabilityIndex` (L3-0).
- Produces:
  - `CapabilityScoring.kindScore(_ kind: TaskKind, _ dimensions: [String: DimensionScore]) -> (score: Double, confidence: Double)?`
  - `CapabilityScoring.matches(candidate: ModelRef, scored: ModelRef) -> Bool`
  - `CapabilityScoring.rank(kind: TaskKind, candidates: [ModelRef], scores: [ModelScores]) -> [ScoredModel]`
  - `CapabilityScoring.dimensionScore(_ ref: ModelRef, _ dimension: String, in: [ModelScores]) -> (model: ModelRef, score: DimensionScore)?`
  - `CapabilityScoring.citations(for: ModelRef, dimension: String, snapshot: IndexSnapshot, sources: [IndexSource]) -> [Citation]`
  - `public struct Citation: Equatable, Sendable, Identifiable { sourceID, sourceName, benchmarkModel: String; score: Double; unit: IndexUnit; url, quotedFigure: String; retrievedAt: String?; stale: Bool; id: String }`
  - `public struct SnapshotCapabilityIndex: CapabilityIndex { scores: [ModelScores]; snapshotDate: Date?; static empty; rank(kind:candidates:) }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// `rank` is what the router asks when no rule matches (L3-R §5 step 3), so its contract is the
/// contract's: best first, unknown models omitted (never scored zero), ties in catalog order.
/// The numbers are worked by hand in `testRankBlendsKindWeightsOverDimensionsWithData`.
final class CapabilityRankTests: XCTestCase {
    private let sol = IndexFixtures.sol, opus = IndexFixtures.opus, sonnet = IndexFixtures.sonnet
    private let tests = TaskKind(id: "tests", name: "Tests", description: "d",
                                 dimensions: ["test-authoring": 0.9, "agentic-coding": 0.3], origin: .seed,
                                 createdAt: Date(timeIntervalSince1970: 0))

    private var scores: [ModelScores] {
        [ModelScores(model: sol, dimensions: ["test-authoring": DimensionScore(score: 0.8, confidence: 1),
                                              "agentic-coding": DimensionScore(score: 0.6, confidence: 1)]),
         ModelScores(model: opus, dimensions: ["test-authoring": DimensionScore(score: 0.6, confidence: 1),
                                               "agentic-coding": DimensionScore(score: 0.9, confidence: 1)]),
         ModelScores(model: sonnet, dimensions: ["agentic-coding": DimensionScore(score: 0.5, confidence: 1)])]
    }

    func testRankBlendsKindWeightsOverDimensionsWithData() {
        let ranked = CapabilityScoring.rank(kind: tests, candidates: [IndexFixtures.bare(sonnet), IndexFixtures.bare(opus),
                                                                      IndexFixtures.bare(sol)], scores: scores)
        XCTAssertEqual(ranked.map(\.model), [sol, opus, sonnet], "a bare catalog candidate resolves to its scored knob variant")
        XCTAssertEqual(ranked[0].score, 0.75, accuracy: 1e-12)          // (0.3×0.6 + 0.9×0.8) / 1.2
        XCTAssertEqual(ranked[0].confidence, 1, accuracy: 1e-12)
        XCTAssertEqual(ranked[1].score, 0.675, accuracy: 1e-12)         // (0.3×0.9 + 0.9×0.6) / 1.2
        XCTAssertEqual(ranked[2].score, 0.5, accuracy: 1e-12)           // only agentic-coding had data
        XCTAssertEqual(ranked[2].confidence, 0.25, accuracy: 1e-12, "0.3 of the kind's 1.2 weight had data")
    }

    func testUnknownModelIsOmittedNeverZero() {
        let ranked = CapabilityScoring.rank(kind: tests, candidates: [ModelRef(harness: "codex", model: "gpt-6-terra"),
                                                                      IndexFixtures.bare(sol)], scores: scores)
        XCTAssertEqual(ranked.map(\.model), [sol])
    }

    func testTiesGoToCatalogOrder() {
        let a = ModelRef(harness: "fake", model: "a"), b = ModelRef(harness: "fake", model: "b")
        let tied = [ModelScores(model: a, dimensions: ["agentic-coding": DimensionScore(score: 0.5, confidence: 1)]),
                    ModelScores(model: b, dimensions: ["agentic-coding": DimensionScore(score: 0.5, confidence: 1)])]
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [b, a], scores: tied).map(\.model), [b, a])
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [a, b], scores: tied).map(\.model), [a, b])
    }

    func testCandidateWithKnobsMatchesExactly() {
        let low = ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "low"])
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [low], scores: scores), [])
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [sol], scores: scores).map(\.model), [sol])
    }

    func testBareCandidatePicksTheBestKnobVariant() {
        let low = ModelRef(harness: "codex", model: "gpt-6-sol", knobs: ["effort": "low"])
        let variants = [ModelScores(model: low, dimensions: ["test-authoring": DimensionScore(score: 0.4, confidence: 1)]),
                        ModelScores(model: sol, dimensions: ["test-authoring": DimensionScore(score: 0.8, confidence: 1)])]
        XCTAssertEqual(CapabilityScoring.rank(kind: tests, candidates: [IndexFixtures.bare(sol)], scores: variants).map(\.model), [sol])
    }

    func testKindWithNoUsableWeightsRanksNothing() {
        let empty = TaskKind(id: "x", name: "X", description: "d", dimensions: [:], origin: .user,
                             createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(CapabilityScoring.rank(kind: empty, candidates: [sol], scores: scores), [])
    }

    func testSnapshotIndexConformsAndReportsItsDate() {
        let date = Date(timeIntervalSince1970: 1_791_093_600)
        let index: any CapabilityIndex = SnapshotCapabilityIndex(scores: scores, snapshotDate: date)
        XCTAssertEqual(index.snapshotDate, date)
        XCTAssertEqual(index.rank(kind: tests, candidates: [IndexFixtures.bare(sol)]).first?.model, sol)
        XCTAssertNil(SnapshotCapabilityIndex.empty.snapshotDate)
    }

    func testCitationsAreTheRowsBehindACell() {
        let snap = IndexSnapshotCodingTests.sample(at: Date(timeIntervalSince1970: 1_790_000_000))
        let rows = CapabilityScoring.citations(for: sol, dimension: "tool-use-reliability", snapshot: snap,
                                               sources: IndexSourceRegistry.initial)
        XCTAssertEqual(rows.map(\.url), ["https://www.tbench.ai/leaderboard"])
        XCTAssertEqual(rows.first?.quotedFigure, "61.3%")
        XCTAssertEqual(rows.first?.sourceName, "Terminal-Bench")
        XCTAssertEqual(CapabilityScoring.citations(for: sol, dimension: "docs-prose", snapshot: snap,
                                                   sources: IndexSourceRegistry.initial), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=CapabilityRankTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `type 'CapabilityScoring' has no member 'rank'`.

- [ ] **Step 3: Append to `CapabilityScoring.swift`**

```swift
extension CapabilityScoring {
    /// A kind's score from one model's dimensions: Σ weight × score over the dimensions that have
    /// data, divided by the weight that had data; confidence is that weight's share of the kind's
    /// total. Nil when no weighted dimension has data. Summed in sorted dimension order:
    /// dictionary order changes run to run, and a float sum taken in another order can differ in
    /// its last bit — enough to flip a tie between two models.
    public static func kindScore(_ kind: TaskKind, _ dimensions: [String: DimensionScore]) -> (score: Double, confidence: Double)? {
        let weights = kind.dimensions.filter { Dimensions.isKnown($0.key) && $0.value > 0 }
        let order = weights.keys.sorted()
        let total = order.reduce(0.0) { $0 + (weights[$1] ?? 0) }
        guard total > 0 else { return nil }
        var num = 0.0
        var present = 0.0
        for d in order {
            guard let s = dimensions[d], let w = weights[d] else { continue }
            num += w * s.score
            present += w
        }
        guard present > 0 else { return nil }
        return (num / present, present / total)
    }

    /// A catalog candidate has no knobs and stands for every scored knob variant of its model; a
    /// candidate that names knobs (a rule's assignment) matches only that exact variant.
    public static func matches(candidate: ModelRef, scored: ModelRef) -> Bool {
        candidate.harness == scored.harness && candidate.model == scored.model
            && (candidate.knobs.isEmpty || candidate.knobs == scored.knobs)
    }

    /// Best first; models with no data for the kind are omitted, never scored zero; equal scores
    /// keep the candidates' (catalog) order. A bare candidate returns its best variant's
    /// `ModelRef`, knobs included, so the router can write those knobs into the block.
    public static func rank(kind: TaskKind, candidates: [ModelRef], scores: [ModelScores]) -> [ScoredModel] {
        var ranked: [(order: Int, model: ScoredModel)] = []
        for (i, candidate) in candidates.enumerated() {
            var best: ScoredModel?
            for variant in scores where matches(candidate: candidate, scored: variant.model) {
                guard let r = kindScore(kind, variant.dimensions) else { continue }
                let s = ScoredModel(model: variant.model, score: r.score, confidence: r.confidence)
                if let b = best, b.score > s.score || (b.score == s.score && b.confidence >= s.confidence) { continue }
                best = s
            }
            if let best { ranked.append((i, best)) }
        }
        return ranked.sorted {
            $0.model.score != $1.model.score ? $0.model.score > $1.model.score : $0.order < $1.order
        }.map(\.model)
    }

    /// One model's score on one dimension, resolving a bare ref to its best variant there.
    public static func dimensionScore(_ ref: ModelRef, _ dimension: String, in scores: [ModelScores])
        -> (model: ModelRef, score: DimensionScore)? {
        var best: (model: ModelRef, score: DimensionScore)?
        for variant in scores where matches(candidate: ref, scored: variant.model) {
            guard let s = variant.dimensions[dimension] else { continue }
            if let b = best, b.score.score >= s.score { continue }
            best = (variant.model, s)
        }
        return best
    }

    /// The rows behind one heatmap cell: every row, in sources feeding `dimension`, that the
    /// snapshot's own aliases map to exactly `model`. Uses the snapshot's aliases, not today's
    /// config, so a cell cites what its score was computed from.
    public static func citations(for model: ModelRef, dimension: String, snapshot: IndexSnapshot,
                                 sources: [IndexSource]) -> [Citation] {
        let aliases = AliasTable(entries: snapshot.aliases)
        var out: [Citation] = []
        for result in snapshot.sources {
            guard let source = sources.first(where: { $0.id == result.sourceID }),
                  (source.dimensions[dimension] ?? 0) > 0 else { continue }
            for row in result.rows where aliases.model(source: source.id, benchmarkModel: row.benchmarkModel) == model {
                out.append(Citation(sourceID: source.id, sourceName: source.name, benchmarkModel: row.benchmarkModel,
                                    score: row.score, unit: row.unit, url: row.url, quotedFigure: row.quotedFigure,
                                    retrievedAt: row.retrievedAt, stale: result.stale))
            }
        }
        return out
    }
}

/// One cited row, as the Settings click-through shows it.
public struct Citation: Equatable, Sendable, Identifiable {
    public var sourceID: String
    public var sourceName: String
    public var benchmarkModel: String
    public var score: Double
    public var unit: IndexUnit
    public var url: String
    public var quotedFigure: String
    public var retrievedAt: String?
    public var stale: Bool
    public var id: String { "\(sourceID)|\(benchmarkModel)|\(url)" }
    public init(sourceID: String, sourceName: String, benchmarkModel: String, score: Double, unit: IndexUnit,
                url: String, quotedFigure: String, retrievedAt: String?, stale: Bool) {
        self.sourceID = sourceID; self.sourceName = sourceName; self.benchmarkModel = benchmarkModel
        self.score = score; self.unit = unit; self.url = url; self.quotedFigure = quotedFigure
        self.retrievedAt = retrievedAt; self.stale = stale
    }
}

/// The `CapabilityIndex` conformer: one snapshot's scores (with hand scores overlaid), frozen.
/// A value, so a router holding one never sees it change under a ranking; the app swaps in a
/// new one through `LiveCapabilityIndex` when a snapshot applies.
public struct SnapshotCapabilityIndex: CapabilityIndex {
    public let scores: [ModelScores]
    public let snapshotDate: Date?
    public init(scores: [ModelScores], snapshotDate: Date?) { self.scores = scores; self.snapshotDate = snapshotDate }
    public static let empty = SnapshotCapabilityIndex(scores: [], snapshotDate: nil)

    public func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel] {
        CapabilityScoring.rank(kind: kind, candidates: candidates, scores: scores)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=CapabilityRankTests,CapabilityScoringTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/CapabilityScoring.swift Tests/FlightDeckTests/FlightControlL3/Index/CapabilityRankTests.swift
git commit -m "feat: rank candidate models for a task kind from the capability index" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Rule hints

**Files:**
- Create: `Sources/IntakeKit/FlightControl/CapabilityHints.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/CapabilityHintsTests.swift`

**Interfaces:**
- Consumes: `CapabilityScoring.dimensionScore` (Task 6), `SnapshotCapabilityIndex` (Task 6).
- Produces:
  - `public struct CapabilityHint: Equatable, Sendable { dimension: String; assigned: ModelRef; assignedScore: Double; better: ModelRef; betterScore: Double; confidence: Double; sources: [String]; var margin: Double; var message: String }`
  - `public enum CapabilityHints { static let minimumMargin = 0.10; static let minimumConfidence = 0.6; static func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef], scores: [ModelScores]) -> [CapabilityHint] }`
  - `extension SnapshotCapabilityIndex { func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef]) -> [CapabilityHint] }` — the call L3-R makes at integration.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// Spec §6: "If some model scores at least 0.10 higher with confidence at least 0.6, the rule
/// gets a hint." A table over the cases that decide whether a hint shows, plus the float edge
/// that would hide a hint the user can see is due.
final class CapabilityHintsTests: XCTestCase {
    private func scores(_ rows: [(ModelRef, String, Double, Double)]) -> [ModelScores] {
        var by: [ModelRef: [String: DimensionScore]] = [:]
        for (m, d, s, c) in rows { by[m, default: [:]][d] = DimensionScore(score: s, confidence: c, sources: ["src-\(d)"]) }
        return by.map { ModelScores(model: $0.key, dimensions: $0.value) }.sorted { IndexKeys.key($0.model) < IndexKeys.key($1.model) }
    }

    private struct Case {
        let name: String
        let rows: [(ModelRef, String, Double, Double)]
        let dims: [String: Double]
        let expect: [String]
    }

    func testTable() {
        let sol = IndexFixtures.sol, opus = IndexFixtures.opus, sonnet = IndexFixtures.sonnet
        let cases: [Case] = [
            Case(name: "clearly better and confident hints",
                 rows: [(sol, "test-authoring", 0.6, 1), (opus, "test-authoring", 0.74, 0.8)],
                 dims: ["test-authoring": 0.5],
                 expect: ["opus scores 0.14 higher on test-authoring (confidence 0.8)"]),
            Case(name: "below the margin is quiet",
                 rows: [(sol, "test-authoring", 0.6, 1), (opus, "test-authoring", 0.69, 1)],
                 dims: ["test-authoring": 0.5], expect: []),
            Case(name: "low confidence is quiet",
                 rows: [(sol, "test-authoring", 0.5, 1), (opus, "test-authoring", 0.9, 0.5)],
                 dims: ["test-authoring": 0.5], expect: []),
            Case(name: "dimensions outside the rule are ignored",
                 rows: [(sol, "debugging", 0.1, 1), (opus, "debugging", 0.9, 1),
                        (sol, "test-authoring", 0.8, 1), (opus, "test-authoring", 0.8, 1)],
                 dims: ["test-authoring": 0.5], expect: []),
            Case(name: "an assigned model with no score cannot be judged",
                 rows: [(opus, "test-authoring", 0.9, 1)],
                 dims: ["test-authoring": 0.5], expect: []),
            Case(name: "largest margin first",
                 rows: [(sol, "test-authoring", 0.3, 1), (sol, "algorithmic-reasoning", 0.5, 1),
                        (opus, "test-authoring", 0.5, 1), (opus, "algorithmic-reasoning", 0.9, 1),
                        (sonnet, "test-authoring", 0.9, 0.7)],
                 dims: ["test-authoring": 0.5, "algorithmic-reasoning": 0.6],
                 expect: ["sonnet scores 0.60 higher on test-authoring (confidence 0.7)",
                          "opus scores 0.40 higher on algorithmic-reasoning (confidence 1.0)",
                          "opus scores 0.20 higher on test-authoring (confidence 1.0)"]),
        ]
        for c in cases {
            let got = CapabilityHints.hints(for: c.dims, assigned: sol,
                                      candidates: [IndexFixtures.bare(sol), IndexFixtures.bare(opus), sonnet, IndexFixtures.bare(opus)],
                                      scores: scores(c.rows)).map(\.message)
            XCTAssertEqual(got, c.expect, c.name)
        }
    }

    func testExactlyTenPointMarginHintsDespiteFloatError() {
        XCTAssertLessThan(0.7 - 0.6, 0.1, "the premise: in floating point this margin is just under 0.10")
        let rows = scores([(IndexFixtures.sol, "debugging", 0.6, 1), (IndexFixtures.opus, "debugging", 0.7, 0.6)])
        XCTAssertEqual(CapabilityHints.hints(for: ["debugging": 0.5], assigned: IndexFixtures.sol,
                                       candidates: [IndexFixtures.opus], scores: rows).count, 1)
    }

    func testIndexExposesHintsOverItsScores() {
        let index = SnapshotCapabilityIndex(scores: scores([(IndexFixtures.sol, "debugging", 0.2, 1),
                                                            (IndexFixtures.opus, "debugging", 0.9, 1)]), snapshotDate: nil)
        let hint = index.hints(for: ["debugging": 0.5], assigned: IndexFixtures.sol, candidates: [IndexFixtures.opus]).first
        XCTAssertEqual(hint?.better, IndexFixtures.opus)
        XCTAssertEqual(hint?.sources, ["src-debugging"])
        XCTAssertEqual(hint?.margin ?? 0, 0.7, accuracy: 1e-12)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=CapabilityHintsTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'CapabilityHints' in scope`.

- [ ] **Step 3: Implement `CapabilityHints.swift`**

```swift
import Foundation

/// "opus scores 0.14 higher on test-authoring (confidence 0.8)": one dimension where a rule's
/// assigned model looks clearly weaker than another candidate. L3-R draws it on the rule;
/// it never changes routing — rules always win.
public struct CapabilityHint: Equatable, Sendable {
    public var dimension: String
    public var assigned: ModelRef
    public var assignedScore: Double
    public var better: ModelRef
    public var betterScore: Double
    /// The better model's confidence on this dimension.
    public var confidence: Double
    /// Source ids behind the better model's score, so the hint can say where it came from.
    public var sources: [String]

    public init(dimension: String, assigned: ModelRef, assignedScore: Double, better: ModelRef,
                betterScore: Double, confidence: Double, sources: [String]) {
        self.dimension = dimension; self.assigned = assigned; self.assignedScore = assignedScore
        self.better = better; self.betterScore = betterScore; self.confidence = confidence; self.sources = sources
    }

    public var margin: Double { betterScore - assignedScore }

    public var message: String {
        "\(better.model) scores \(String(format: "%.2f", margin)) higher on \(dimension) (confidence \(String(format: "%.1f", confidence)))"
    }
}

public enum CapabilityHints {
    public static let minimumMargin = 0.10
    public static let minimumConfidence = 0.6
    /// Float slack: 0.7 − 0.6 is 0.0999…98, and a margin the user reads as "0.10" must hint.
    static let epsilon = 1e-9

    /// Compares `assigned` with every candidate on each dimension the rule matches on.
    /// `ruleDimensions` is the rule's compiled `{dimension: atLeast}` terms; only the KEYS are
    /// used — the thresholds decide whether the rule matches a kind, not how good a model is.
    /// A dimension where the assigned model has no score is skipped: there is nothing to be
    /// weaker than. Largest margin first, then dimension, then candidate order.
    public static func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef],
                             scores: [ModelScores]) -> [CapabilityHint] {
        var found: [(order: Int, hint: CapabilityHint)] = []
        for d in ruleDimensions.keys.sorted() where Dimensions.isKnown(d) {
            guard let mine = CapabilityScoring.dimensionScore(assigned, d, in: scores) else { continue }
            for (i, candidate) in candidates.enumerated() {
                guard let theirs = CapabilityScoring.dimensionScore(candidate, d, in: scores),
                      theirs.model != mine.model,
                      theirs.score.score - mine.score.score >= minimumMargin - epsilon,
                      theirs.score.confidence >= minimumConfidence - epsilon,
                      !found.contains(where: { $0.hint.dimension == d && $0.hint.better == theirs.model }) else { continue }
                found.append((i, CapabilityHint(dimension: d, assigned: mine.model, assignedScore: mine.score.score,
                                          better: theirs.model, betterScore: theirs.score.score,
                                          confidence: theirs.score.confidence, sources: theirs.score.sources)))
            }
        }
        return found.sorted {
            if abs($0.hint.margin - $1.hint.margin) > epsilon { return $0.hint.margin > $1.hint.margin }
            if $0.hint.dimension != $1.hint.dimension { return $0.hint.dimension < $1.hint.dimension }
            return $0.order < $1.order
        }.map(\.hint)
    }
}

extension SnapshotCapabilityIndex {
    /// The call L3-R makes for each confirmed rule (L3-R §7). Not on the `CapabilityIndex`
    /// protocol: the contract is frozen, and only the index's owner needs to offer it.
    public func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef]) -> [CapabilityHint] {
        CapabilityHints.hints(for: ruleDimensions, assigned: assigned, candidates: candidates, scores: scores)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=CapabilityHintsTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/CapabilityHints.swift Tests/FlightDeckTests/FlightControlL3/Index/CapabilityHintsTests.swift
git commit -m "feat: hint when a routing rule assigns a clearly weaker model" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The snapshot store — current, retention, rollback, diff

**Files:**
- Create: `Sources/IntakeKit/FlightControl/IndexSnapshotStore.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/IndexSnapshotStoreTests.swift`

**Interfaces:**
- Consumes: `IndexSnapshot`, `IndexStamp` (Task 4), `IndexKeys` (Task 3).
- Produces:
  - `public struct SnapshotRef: Equatable, Hashable, Sendable { url: URL; stamp: String; date: Date; rolledBack: Bool }`
  - `public enum IndexStoreError: Error, Equatable, Sendable { nothingToRollBackTo }`
  - `public struct IndexSnapshotStore: Sendable { static let keep = 12; let directory: URL; init(directory:); list() -> [SnapshotRef]; load(_:) -> IndexSnapshot?; current() -> (ref: SnapshotRef, snapshot: IndexSnapshot)?; previous(before:) -> (ref:, snapshot:)?; write(_:) throws -> SnapshotRef; rollBack() throws -> (ref:, snapshot:); prune(keep:) throws }`
  - `public struct ScoreChange: Equatable, Sendable { model: ModelRef; dimension: String; before: Double?; after: Double?; var delta: Double? }`
  - `public enum SnapshotDiff { static func changes(from: IndexSnapshot?, to: IndexSnapshot, minimumChange: Double = 0.01) -> [ScoreChange] }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// "The newest valid snapshot is current" is the whole storage model, so these tests attack
/// "newest" (clock moved back, two writes in one second) and "valid" (a torn write, a file from
/// a newer Flight Deck), then rollback and retention, then the diff Settings shows.
final class IndexSnapshotStoreTests: XCTestCase {
    private var dir: URL!
    private var store: IndexSnapshotStore!
    private let t0: TimeInterval = 1_790_000_000

    override func setUpWithError() throws {
        dir = IndexFixtures.scratch()
        store = IndexSnapshotStore(directory: dir)
        let d = dir!
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
    }

    private func snapshot(_ t: TimeInterval, score: Double = 0.5, v: Int = IndexSnapshot.currentVersion) -> IndexSnapshot {
        IndexSnapshot(v: v, createdAt: Date(timeIntervalSince1970: t), sources: [], aliases: [],
                      scores: [ModelScores(model: IndexFixtures.sol, dimensions: ["debugging": DimensionScore(score: score, confidence: 1)])],
                      unmapped: [])
    }
    private func score(_ s: IndexSnapshot?) -> Double? { s?.scores.first?.dimensions["debugging"]?.score }

    func testNewestValidIsCurrent() throws {
        try store.write(snapshot(t0, score: 0.4))
        try store.write(snapshot(t0 + 60, score: 0.6))
        XCTAssertEqual(score(store.current()?.snapshot), 0.6)
        XCTAssertEqual(store.current()?.ref.stamp, IndexStamp.string(Date(timeIntervalSince1970: t0 + 60)))
        XCTAssertEqual(score(store.previous(before: store.current()!.ref)?.snapshot), 0.4)
    }

    func testCorruptNewestSnapshotFallsBackToPreviousValid() throws {
        try store.write(snapshot(t0, score: 0.4))
        try Data("{ truncated".utf8).write(to: dir.appendingPathComponent(IndexStamp.string(Date(timeIntervalSince1970: t0 + 60)) + ".json"))
        XCTAssertEqual(score(store.current()?.snapshot), 0.4)
    }

    func testNewerVersionSnapshotIsSkipped() throws {
        try store.write(snapshot(t0, score: 0.4))
        let newer = snapshot(t0 + 60, score: 0.9, v: IndexSnapshot.currentVersion + 1)
        try IndexSnapshot.encoder().encode(newer)
            .write(to: dir.appendingPathComponent(IndexStamp.string(Date(timeIntervalSince1970: t0 + 60)) + ".json"))
        XCTAssertEqual(score(store.current()?.snapshot), 0.4, "a snapshot from a newer Flight Deck is not read as this version")
    }

    func testWriteAfterTheClockMovedBackStillBecomesCurrent() throws {
        try store.write(snapshot(t0, score: 0.4))
        let ref = try store.write(snapshot(t0 - 3600, score: 0.9))
        XCTAssertEqual(ref.stamp, IndexStamp.string(Date(timeIntervalSince1970: t0 + 1)))
        XCTAssertEqual(score(store.current()?.snapshot), 0.9)
    }

    func testTwoWritesInOneSecondBothSurvive() throws {
        try store.write(snapshot(t0, score: 0.4))
        try store.write(snapshot(t0, score: 0.5))
        XCTAssertEqual(store.list().count, 2)
        XCTAssertEqual(score(store.current()?.snapshot), 0.5)
    }

    func testRollBackMakesThePreviousCurrentAndKeepsTheFile() throws {
        try store.write(snapshot(t0, score: 0.4))
        try store.write(snapshot(t0 + 60, score: 0.6))
        XCTAssertEqual(score(try store.rollBack().snapshot), 0.4)
        XCTAssertEqual(score(store.current()?.snapshot), 0.4)
        XCTAssertEqual(store.list().map(\.rolledBack), [false, true])
        try store.write(snapshot(t0 + 120, score: 0.7))
        XCTAssertEqual(score(store.current()?.snapshot), 0.7, "a refresh after a rollback is current again")
    }

    func testRollBackWithNothingOlderThrows() throws {
        try store.write(snapshot(t0))
        XCTAssertThrowsError(try store.rollBack()) { XCTAssertEqual($0 as? IndexStoreError, .nothingToRollBackTo) }
        XCTAssertNotNil(store.current(), "a refused rollback leaves the current snapshot alone")
    }

    func testPruneKeepsTwelveNewestValid() throws {
        for i in 0..<14 { try store.write(snapshot(t0 + Double(i) * 60)) }
        try store.prune()
        XCTAssertEqual(store.list().count, 12)
        XCTAssertEqual(store.list().first?.stamp, IndexStamp.string(Date(timeIntervalSince1970: t0 + 120)))
    }

    func testForeignFilesAreIgnored() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["config.json", "notes.txt", "2026-10-04.json"] { try Data("{}".utf8).write(to: dir.appendingPathComponent(name)) }
        try store.write(snapshot(t0))
        XCTAssertEqual(store.list().count, 1)
        try store.prune()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path), "prune never touches the config")
    }

    func testDiffReportsMovedAppearedAndDisappeared() {
        let sol = IndexFixtures.sol, opus = IndexFixtures.opus, sonnet = IndexFixtures.sonnet
        let old = IndexSnapshot(createdAt: Date(timeIntervalSince1970: t0), sources: [], aliases: [], scores: [
            ModelScores(model: sol, dimensions: ["debugging": DimensionScore(score: 0.4, confidence: 1),
                                                 "docs-prose": DimensionScore(score: 0.5, confidence: 1)]),
            ModelScores(model: opus, dimensions: ["debugging": DimensionScore(score: 0.7, confidence: 1)])], unmapped: [])
        let new = IndexSnapshot(createdAt: Date(timeIntervalSince1970: t0 + 60), sources: [], aliases: [], scores: [
            ModelScores(model: sol, dimensions: ["debugging": DimensionScore(score: 0.6, confidence: 1)]),
            ModelScores(model: opus, dimensions: ["debugging": DimensionScore(score: 0.705, confidence: 1)]),
            ModelScores(model: sonnet, dimensions: ["speed": DimensionScore(score: 0.3, confidence: 1)])], unmapped: [])
        let changes = SnapshotDiff.changes(from: old, to: new)
        XCTAssertEqual(changes.map { "\(IndexKeys.key($0.model)) \($0.dimension)" },
                       ["claude/sonnet speed", "codex/gpt-6-sol[effort=high] docs-prose", "codex/gpt-6-sol[effort=high] debugging"])
        XCTAssertEqual(changes[2].delta ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertNil(changes[0].before)
        XCTAssertNil(changes[1].after)
        XCTAssertEqual(SnapshotDiff.changes(from: nil, to: new), [], "nothing to compare with is no change, not everything new")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=IndexSnapshotStoreTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'IndexSnapshotStore' in scope`.

- [ ] **Step 3: Implement `IndexSnapshotStore.swift`**

```swift
import Foundation

public struct SnapshotRef: Equatable, Hashable, Sendable {
    public var url: URL
    public var stamp: String
    public var date: Date
    public var rolledBack: Bool
    public init(url: URL, stamp: String, date: Date, rolledBack: Bool) {
        self.url = url; self.stamp = stamp; self.date = date; self.rolledBack = rolledBack
    }
}

public enum IndexStoreError: Error, Equatable, Sendable { case nothingToRollBackTo }

/// `capability-index/`: one `<stamp>.json` per snapshot. The newest one that loads is current —
/// the only rule. Rollback renames the current file to `<stamp>.rolledback.json` instead of
/// keeping a "current" pointer, so there is no second source of truth to disagree with the
/// files; a later refresh is simply newer again.
public struct IndexSnapshotStore: Sendable {
    public static let keep = 12
    static let rolledBackSuffix = ".rolledback.json"
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// Every snapshot file, oldest first. Anything whose name is not a canonical stamp
    /// (`config.json`, a hand-made `2026-10-04.json`) is not a snapshot and is never touched.
    public func list() -> [SnapshotRef] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> SnapshotRef? in
            let rolled = name.hasSuffix(Self.rolledBackSuffix)
            let stem: String
            if rolled { stem = String(name.dropLast(Self.rolledBackSuffix.count)) }
            else if name.hasSuffix(".json") { stem = String(name.dropLast(5)) }
            else { return nil }
            guard let date = IndexStamp.date(stem) else { return nil }
            return SnapshotRef(url: directory.appendingPathComponent(name), stamp: stem, date: date, rolledBack: rolled)
        }.sorted { $0.stamp < $1.stamp }
    }

    /// Nil for a file that does not decode (a torn write) or that a newer Flight Deck wrote —
    /// either way it is skipped, never half-read.
    public func load(_ ref: SnapshotRef) -> IndexSnapshot? {
        guard let data = try? Data(contentsOf: ref.url),
              let snapshot = try? IndexSnapshot.decoder().decode(IndexSnapshot.self, from: data),
              snapshot.v <= IndexSnapshot.currentVersion else { return nil }
        return snapshot
    }

    public func current() -> (ref: SnapshotRef, snapshot: IndexSnapshot)? {
        for ref in list().reversed() where !ref.rolledBack {
            if let s = load(ref) { return (ref, s) }
        }
        return nil
    }

    public func previous(before ref: SnapshotRef) -> (ref: SnapshotRef, snapshot: IndexSnapshot)? {
        for r in list().reversed() where !r.rolledBack && r.stamp < ref.stamp {
            if let s = load(r) { return (r, s) }
        }
        return nil
    }

    /// Writes `snapshot` under a stamp strictly newer than every existing file. Usually that is
    /// its `createdAt`; when the clock has moved back, or a second write lands in the same
    /// second, it is one second past the newest — a new snapshot must become current, and a
    /// stamp that sorted older would silently leave the previous one in charge.
    @discardableResult
    public func write(_ snapshot: IndexSnapshot) throws -> SnapshotRef {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var date = snapshot.createdAt
        if let newest = list().last, IndexStamp.string(date) <= newest.stamp {
            date = newest.date.addingTimeInterval(1)
        }
        let stamp = IndexStamp.string(date)
        let url = directory.appendingPathComponent(stamp + ".json")
        try IndexSnapshot.encoder().encode(snapshot).write(to: url, options: .atomic)
        return SnapshotRef(url: url, stamp: stamp, date: IndexStamp.date(stamp) ?? date, rolledBack: false)
    }

    /// Makes the previous valid snapshot current by renaming the current one aside. Throws, and
    /// changes nothing, when there is no earlier valid snapshot.
    @discardableResult
    public func rollBack() throws -> (ref: SnapshotRef, snapshot: IndexSnapshot) {
        guard let cur = current(), let prev = previous(before: cur.ref) else { throw IndexStoreError.nothingToRollBackTo }
        try FileManager.default.moveItem(at: cur.ref.url,
                                         to: directory.appendingPathComponent(cur.ref.stamp + Self.rolledBackSuffix))
        return prev
    }

    /// Keeps the newest `keep` valid snapshots and deletes every snapshot file — valid, corrupt
    /// or rolled back — older than the oldest one kept. Counting only VALID ones means a run of
    /// torn writes can never push the last good snapshots out.
    public func prune(keep: Int = IndexSnapshotStore.keep) throws {
        let all = list()
        let valid = all.filter { !$0.rolledBack && load($0) != nil }
        guard let oldestKept = valid.suffix(keep).first?.stamp else { return }
        for ref in all where ref.stamp < oldestKept {
            try FileManager.default.removeItem(at: ref.url)
        }
    }
}

/// One model × dimension that moved between two snapshots. `before` nil: it appeared;
/// `after` nil: it went unknown.
public struct ScoreChange: Equatable, Sendable {
    public var model: ModelRef
    public var dimension: String
    public var before: Double?
    public var after: Double?
    public init(model: ModelRef, dimension: String, before: Double?, after: Double?) {
        self.model = model; self.dimension = dimension; self.before = before; self.after = after
    }
    public var delta: Double? {
        guard let before, let after else { return nil }
        return after - before
    }
}

public enum SnapshotDiff {
    /// What Settings shows above Roll back: every computed score that moved by at least
    /// `minimumChange`, appeared or disappeared — largest movement first (an appearance or a
    /// disappearance counts as 1), then by model key and dimension.
    public static func changes(from old: IndexSnapshot?, to new: IndexSnapshot, minimumChange: Double = 0.01) -> [ScoreChange] {
        guard let old else { return [] }
        func table(_ s: IndexSnapshot) -> [String: (model: ModelRef, scores: [String: Double])] {
            var out: [String: (model: ModelRef, scores: [String: Double])] = [:]
            for m in s.scores { out[IndexKeys.key(m.model)] = (m.model, m.dimensions.mapValues(\.score)) }
            return out
        }
        let before = table(old), after = table(new)
        var out: [ScoreChange] = []
        for key in Set(before.keys).union(after.keys).sorted() {
            guard let model = after[key]?.model ?? before[key]?.model else { continue }
            let b = before[key]?.scores ?? [:], a = after[key]?.scores ?? [:]
            for d in Set(b.keys).union(a.keys).sorted() {
                let change = ScoreChange(model: model, dimension: d, before: b[d], after: a[d])
                if let delta = change.delta, abs(delta) < minimumChange { continue }
                out.append(change)
            }
        }
        return out.sorted { lhs, rhs in
            let l = abs(lhs.delta ?? 1), r = abs(rhs.delta ?? 1)
            if l != r { return l > r }
            return (IndexKeys.key(lhs.model), lhs.dimension) < (IndexKeys.key(rhs.model), rhs.dimension)
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=IndexSnapshotStoreTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/IndexSnapshotStore.swift Tests/FlightDeckTests/FlightControlL3/Index/IndexSnapshotStoreTests.swift
git commit -m "feat: keep twelve capability index snapshots with one-step rollback and a score diff" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: The extraction prompt, schema and `claude -p` command

**Files:**
- Create: `Sources/IntakeKit/FlightControl/IndexExtraction.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/IndexExtractionTests.swift`

**Interfaces:**
- Consumes: `IndexSource` (Task 1), `ExtractionPayload` (Task 2), `IndexAgentSettings` (Task 4), `AdapterCatalogs` (L3-0); `HarnessCommand.claudeStreaming`, `HarnessCommand.claudeIsolation`, `HarnessOutput.parse` (`Sources/IntakeKit/Harness.swift`).
- Produces: `public enum IndexExtraction { static let webTools; static let deniedTools; static let schemaJSON: String; static func prompt(source:catalogs:) -> String; static func command(prompt:settings:) -> (executable: String, arguments: [String], unsetEnvironment: [String]); static func parse(stdout: Data) throws -> ExtractionPayload }`

- [ ] **Step 1: Verify the flags this command relies on (read-only, no tokens)**

Run: `claude --help | rg -n -- "--restricted|--tools <|--json-schema|--effort|--allowedTools|--permission-mode"`
Expected (claude 2.1.289 when planned): all six present, and the `--restricted` text says it
removes "WebFetch unless --tools names them". Then:
Run: `rg -n "public static let claudeStreaming|public static let claudeIsolation|public static func parse" Sources/IntakeKit/Harness.swift`
Expected: three hits.
If `--restricted` no longer mentions WebFetch, keep the command as written (naming both tools
in `--tools` is what keeps them either way) and note it for the Task 14 live probe. If
`HarnessCommand.claudeStreaming` or `claudeIsolation` was renamed, use the new names here and in
the test below.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// The refresh agent reads the open web, so its command is the one place to get isolation
/// right: web search and fetch exist, nothing that runs code or touches files does, no MCP
/// server loads, and nobody is asked a question. Its answer is schema-bound JSON parsed the
/// same way every other headless claude run's is.
final class IndexExtractionTests: XCTestCase {
    private var terminalBench: IndexSource { IndexSourceRegistry.initial.first { $0.id == "terminal-bench" }! }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    func testCommandGrantsOnlyWebTools() {
        let cmd = IndexExtraction.command(prompt: "P", settings: IndexAgentSettings(model: "haiku", effort: "low", tokenCap: 10))
        XCTAssertEqual(cmd.executable, "claude")
        XCTAssertEqual(value(after: "-p", in: cmd.arguments), "P")
        XCTAssertEqual(value(after: "--model", in: cmd.arguments), "haiku")
        XCTAssertEqual(value(after: "--effort", in: cmd.arguments), "low")
        XCTAssertEqual(value(after: "--tools", in: cmd.arguments), "WebSearch WebFetch")
        XCTAssertEqual(value(after: "--allowedTools", in: cmd.arguments), "WebSearch WebFetch")
        XCTAssertEqual(value(after: "--permission-mode", in: cmd.arguments), "dontAsk")
        XCTAssertEqual(value(after: "--json-schema", in: cmd.arguments), IndexExtraction.schemaJSON)
        XCTAssertEqual(value(after: "--output-format", in: cmd.arguments), "stream-json")
        for flag in ["--restricted", "--strict-mcp-config", "--verbose"] { XCTAssertTrue(cmd.arguments.contains(flag), flag) }
        XCTAssertTrue(value(after: "--disallowedTools", in: cmd.arguments)?.contains("Bash") == true)
        XCTAssertEqual(cmd.unsetEnvironment, ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"])
    }

    func testSchemaRequiresEveryRowField() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(IndexExtraction.schemaJSON.utf8)) as? [String: Any])
        let rows = try XCTUnwrap((schema["properties"] as? [String: Any])?["rows"] as? [String: Any])
        let items = try XCTUnwrap(rows["items"] as? [String: Any])
        XCTAssertEqual(Set(items["required"] as? [String] ?? []),
                       ["benchmarkModel", "score", "unit", "url", "retrievedAt", "quotedFigure"])
    }

    func testPromptCarriesTheSourceAndTheCatalog() {
        let prompt = IndexExtraction.prompt(source: terminalBench, catalogs: IndexFixtures.catalogs())
        XCTAssertTrue(prompt.contains("(id terminal-bench)"))
        XCTAssertTrue(prompt.contains(terminalBench.url))
        XCTAssertTrue(prompt.contains(terminalBench.howToRead))
        XCTAssertTrue(prompt.contains(#"Unit: report every score in "percent"."#))
        XCTAssertTrue(prompt.contains("- codex/gpt-6-sol (GPT-6 Sol)"))
        XCTAssertTrue(IndexExtraction.prompt(source: terminalBench, catalogs: AdapterCatalogs([])).contains("(none listed yet)"))
    }

    func testParseReadsStructuredOutputFromTheStream() throws {
        let json = IndexFixtures.payloadJSON("terminal-bench", [("GPT-6 Sol (high)", 61.3)])
        let payload = try IndexExtraction.parse(stdout: IndexFixtures.stream(json))
        XCTAssertEqual(payload.source, "terminal-bench")
        XCTAssertEqual(payload.rows.first?.quotedFigure, "61.3%")
    }

    func testParseRejectsAnErrorResult() {
        XCTAssertThrowsError(try IndexExtraction.parse(stdout: IndexFixtures.stream("{}", isError: true)))
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=IndexExtractionTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'IndexExtraction' in scope`.

- [ ] **Step 4: Implement `IndexExtraction.swift`**

```swift
import Foundation

/// One source's refresh as a headless claude run.
///
/// The isolation reuses `HarnessCommand`'s, for the reasons documented there: `--restricted`
/// ignores the user's settings files (a standing `Bash(git add *)` allow would otherwise
/// apply), `--strict-mcp-config` loads no MCP server, `dontAsk` denies anything not
/// pre-approved because nobody can answer a prompt under `-p`. On top of that, `--tools` makes
/// WebSearch and WebFetch the ONLY tools that exist — claude 2.1.289's `--help` says
/// `--restricted` removes WebFetch "unless --tools names them", so naming them here is what
/// keeps them.
public enum IndexExtraction {
    public static let webTools = "WebSearch WebFetch"
    /// Defense in depth behind `--tools`: denied by name, since deny rules beat allow rules from
    /// any source.
    public static let deniedTools = "Bash Edit Write NotebookEdit Task"

    public static let schemaJSON = #"""
    {"type":"object","additionalProperties":false,"required":["source","rows"],"properties":{"source":{"type":"string"},"rows":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["benchmarkModel","score","unit","url","retrievedAt","quotedFigure"],"properties":{"benchmarkModel":{"type":"string"},"score":{"type":"number"},"unit":{"type":"string"},"url":{"type":"string"},"retrievedAt":{"type":"string"},"quotedFigure":{"type":"string"}}}}}}
    """#

    /// The agent gets the source entry and the catalog models (spec §4). It is told to report
    /// the benchmark's own names — mapping them is the alias table's job, and an agent asked to
    /// map would guess.
    public static func prompt(source: IndexSource, catalogs: AdapterCatalogs) -> String {
        let models = catalogs.order.compactMap { catalogs.byHarness[$0] }.flatMap { cat in
            cat.models.map { "- \(cat.harness.rawValue)/\($0.id) (\($0.displayName))" }
        }
        let list = models.isEmpty ? "- (none listed yet)" : models.joined(separator: "\n")
        return """
        You are reading one public benchmark for Flight Deck's capability index.

        Source: \(source.name) (id \(source.id))
        Address: \(source.url)
        What to read: \(source.howToRead)
        Unit: report every score in "\(source.unit)".

        Read the address with WebFetch. Use WebSearch only if the address has moved.
        Report one row per model in that table:
        - benchmarkModel: the model's name exactly as the source writes it, with any setting in brackets.
        - score: the figure as a number, in the unit above.
        - quotedFigure: the figure copied character for character from the source, for example "61.3%".
        - url: the address you read the figure on.
        - retrievedAt: the current time in ISO 8601.
        - unit: "\(source.unit)".
        Do not estimate, convert from another table, or fill a gap. Leave out any model you cannot read a figure for.
        Set "source" to "\(source.id)".

        Flight Deck can run these models. Report every row you can read, not only these:
        \(list)
        """
    }

    public static func command(prompt: String, settings: IndexAgentSettings)
        -> (executable: String, arguments: [String], unsetEnvironment: [String]) {
        let args = ["-p", prompt, "--model", settings.model, "--effort", settings.effort]
            + HarnessCommand.claudeStreaming
            + ["--json-schema", schemaJSON, "--permission-mode", "dontAsk",
               "--tools", webTools, "--allowedTools", webTools, "--disallowedTools", deniedTools]
            + HarnessCommand.claudeIsolation
        // Unset for the reason `HarnessCommand.build` gives: a claude spawned from inside Claude
        // Code otherwise skips saving its transcript, and the live probe runs from inside one.
        return ("claude", args, ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE"])
    }

    /// The stream's final `result.structured_output`, decoded. Throws on an error result, a
    /// stream that never finished, or an answer that is not the row format.
    public static func parse(stdout: Data) throws -> ExtractionPayload {
        let parsed = try HarnessOutput.parse(.claude, stdout: stdout)
        return try JSONDecoder().decode(ExtractionPayload.self, from: parsed.structured)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=IndexExtractionTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/IntakeKit/FlightControl/IndexExtraction.swift Tests/FlightDeckTests/FlightControlL3/Index/IndexExtractionTests.swift
git commit -m "feat: build the web-only claude run that extracts one benchmark's rows" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: The refresh runner — cap, failures, stale marking

**Files:**
- Create: `Sources/FlightDeck/FlightControl/IndexRefreshRunner.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Index/IndexTestDoubles.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/IndexRefreshRunnerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–9; `HeadlessRunner`, `SystemHeadlessRunner` (`Sources/FlightDeck/Intake/HeadlessRunner.swift`); `ActivityParser`, `SeatActivity` (`Sources/IntakeKit/SeatActivity.swift`); `HarnessOutput.ParseError`.
- Produces:
  - `struct IndexRefreshPlan: Sendable { sources: [IndexSource]; aliases: AliasTable; catalogs: AdapterCatalogs; agent: IndexAgentSettings; previous: IndexSnapshot?; workDirectory: URL }`
  - `struct IndexRefreshOutcome: Sendable { snapshot: IndexSnapshot; proposals: [AliasEntry]; log: [String]; tokensUsed: Int }`
  - `enum IndexRefreshError: Error, Equatable { overCap(used: Int), harness(String), noValidRows(Int) }`
  - `final class IndexTokenMeter: @unchecked Sendable { init(cwd:budget:); feed(_:); whenOver(_:); var total: Int; var isOver: Bool }`
  - `struct IndexRefreshRunner: Sendable { init(headless: HeadlessRunner = SystemHeadlessRunner(), now: @escaping @Sendable () -> Date = { Date() }); func refresh(_ plan: IndexRefreshPlan) async -> IndexRefreshOutcome; static func rescore(_:sources:aliases:now:) -> IndexSnapshot; static func describe(_ error: Error) -> String }`
  - Test double `final class ScriptedIndexHeadless: HeadlessRunner, @unchecked Sendable { answers: [String: (stdout: Data, stderr: String, exitCode: Int32)]; ran: [String]; prompts: [String]; commands: [[String]] }` — answers keyed by source id, matched by `(id <source>)` in the prompt.

- [ ] **Step 1: Verify the runner seam this task builds on**

Run: `rg -n "protocol HeadlessRunner|cwd: URL, onStdout|struct SystemHeadlessRunner" Sources/FlightDeck/Intake/HeadlessRunner.swift`
Expected: three hits — the protocol, its streaming `run(_:cwd:onStdout:)` requirement, and the
system conformer (which goes through `SystemCommandRunner`'s `terminationHandler` path).
If the streaming requirement is gone, call `run(_:cwd:)` instead and rely on the post-exit cap
check in `extract` (the test fake exercises that path either way).

- [ ] **Step 2: Write `IndexTestDoubles.swift`**

```swift
import Foundation
import IntakeKit
@testable import FlightDeck

/// A `HeadlessRunner` that answers per source. The source is recognised by the `(id <source>)`
/// line the extraction prompt carries; an unscripted source exits 1, which the runner must
/// treat as a failed source, not a crash. Implements only `run(_:cwd:)`, so the streaming
/// overload falls back to the protocol extension and delivers stdout once, at exit — the path
/// on which the token cap is enforced after the fact.
final class ScriptedIndexHeadless: HeadlessRunner, @unchecked Sendable {
    private let lock = NSLock()
    var answers: [String: (stdout: Data, stderr: String, exitCode: Int32)] = [:]
    private(set) var ran: [String] = []
    private(set) var prompts: [String] = []
    private(set) var commands: [[String]] = []

    func run(_ command: (executable: String, arguments: [String], unsetEnvironment: [String]),
             cwd: URL) async throws -> (stdout: Data, stderr: String, exitCode: Int32) {
        let prompt = command.arguments.count > 1 ? command.arguments[1] : ""
        return lock.withLock {
            commands.append(command.arguments)
            prompts.append(prompt)
            guard let id = answers.keys.sorted().first(where: { prompt.contains("(id \($0))") }),
                  let answer = answers[id] else {
                return (Data(), "no script for this source", 1)
            }
            ran.append(id)
            return answer
        }
    }
}
```

- [ ] **Step 3: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Spec §4's failure rules against a fake headless runner: the cap stops the run and leaves the
/// rest of the sources on their previous values, marked stale; a failing source keeps its
/// previous values, marked stale with the error; rejected rows are logged with their reason.
final class IndexRefreshRunnerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_093_600)   // 2026-10-04T06:00:00Z
    private let earlier = Date(timeIntervalSince1970: 1_790_488_800) // 2026-09-27T06:00:00Z
    private var work: URL!

    override func setUp() {
        work = IndexFixtures.scratch()
        let w = work!
        addTeardownBlock { try? FileManager.default.removeItem(at: w) }
    }

    private func runner(_ h: ScriptedIndexHeadless) -> IndexRefreshRunner {
        let t = now
        return IndexRefreshRunner(headless: h, now: { t })
    }

    private func plan(_ sources: [IndexSource], cap: Int = 1_000_000, previous: IndexSnapshot? = nil) -> IndexRefreshPlan {
        var aliases = AliasTable()
        aliases.set(source: "a", benchmarkModel: "GPT-6 Sol (high)", model: IndexFixtures.sol, status: .confirmed)
        return IndexRefreshPlan(sources: sources, aliases: aliases, catalogs: IndexFixtures.catalogs(),
                                agent: IndexAgentSettings(model: "sonnet", effort: "medium", tokenCap: cap),
                                previous: previous, workDirectory: work)
    }

    private func oldRow(_ name: String) -> AcceptedRow {
        AcceptedRow(benchmarkModel: name, score: 1, unit: .percent, url: "https://old.test", retrievedAt: nil, quotedFigure: "1")
    }

    private func previous(_ ids: [String]) -> IndexSnapshot {
        IndexSnapshot(createdAt: earlier,
                      sources: ids.map { SourceResult(sourceID: $0, rows: [oldRow("Old \($0)")], refreshedAt: earlier, tokens: 5) },
                      aliases: [], scores: [], unmapped: [])
    }

    func testValidSourceScoresAndProposesAliasesForCatalogNames() async {
        let h = ScriptedIndexHeadless()
        h.answers["a"] = (IndexFixtures.stream(IndexFixtures.payloadJSON("a", [("GPT-6 Sol (high)", 61.3), ("Opus 5 (high)", 58.0),
                                                                               ("Mystery-1", 40.0)])), "", 0)
        let outcome = await runner(h).refresh(plan([IndexFixtures.source("a")]))
        XCTAssertEqual(outcome.snapshot.sources.map(\.stale), [false])
        XCTAssertEqual(outcome.snapshot.scores.map(\.model), [IndexFixtures.sol], "only a confirmed alias scores")
        XCTAssertEqual(outcome.snapshot.scores.first?.dimensions["agentic-coding"]?.score, 1)
        XCTAssertEqual(outcome.proposals.map(\.model), [IndexFixtures.opus], "Mystery-1 is never guessed")
        XCTAssertEqual(outcome.snapshot.unmapped.map(\.benchmarkModel), ["Mystery-1", "Opus 5 (high)"])
        XCTAssertEqual(outcome.tokensUsed, 1200)
        XCTAssertEqual(outcome.snapshot.createdAt, now)
        XCTAssertEqual(outcome.snapshot.sources.first?.refreshedAt, now)
    }

    func testCapReachedMarksTheRestStaleAndKeepsTheirPreviousRows() async {
        let h = ScriptedIndexHeadless()
        for id in ["a", "b", "c"] {
            h.answers[id] = (IndexFixtures.stream(IndexFixtures.payloadJSON(id, [("X", 1.0), ("Y", 2.0)])), "", 0)
        }
        let sources = ["a", "b", "c"].map { IndexFixtures.source($0) }
        let prior = previous(["b", "c"])
        let outcome = await runner(h).refresh(plan(sources, cap: 1500, previous: prior))
        // a spends 1200 of 1500; b is handed the remaining 300, spends 1200 and is stopped; c never runs.
        XCTAssertEqual(h.ran, ["a", "b"])
        XCTAssertEqual(outcome.snapshot.sources.map(\.stale), [false, true, true])
        XCTAssertEqual(outcome.snapshot.sources.map(\.error), [nil, "token cap reached", "token cap reached"])
        XCTAssertEqual(outcome.snapshot.sources[1].rows, prior.sources[0].rows)
        XCTAssertEqual(outcome.snapshot.sources[2].rows, prior.sources[1].rows)
        XCTAssertEqual(outcome.snapshot.sources[2].refreshedAt, earlier, "carried rows keep the time they were read")
        XCTAssertEqual(outcome.tokensUsed, 2400)
    }

    func testFailingSourceKeepsPreviousValuesMarkedStale() async {
        let h = ScriptedIndexHeadless()
        h.answers["a"] = (Data(), "auth failed", 1)
        let prior = previous(["a"])
        let outcome = await runner(h).refresh(plan([IndexFixtures.source("a")], previous: prior))
        XCTAssertEqual(outcome.snapshot.sources.first?.stale, true)
        XCTAssertEqual(outcome.snapshot.sources.first?.error, "claude exited 1: auth failed")
        XCTAssertEqual(outcome.snapshot.sources.first?.rows, prior.sources[0].rows)
        XCTAssertTrue(outcome.log.contains("a: failed: claude exited 1: auth failed"))
    }

    func testSourceWithOnlyRejectedRowsKeepsPreviousValues() async {
        let h = ScriptedIndexHeadless()
        let bad = #"{"source":"a","rows":[{"benchmarkModel":"X","score":50,"unit":"percent","url":"https://a.test","retrievedAt":"2026-10-04T06:00:00Z","quotedFigure":"5%"}]}"#
        h.answers["a"] = (IndexFixtures.stream(bad), "", 0)
        let prior = previous(["a"])
        let outcome = await runner(h).refresh(plan([IndexFixtures.source("a")], previous: prior))
        XCTAssertEqual(outcome.snapshot.sources.first?.stale, true)
        XCTAssertEqual(outcome.snapshot.sources.first?.error, "no valid rows (1 rejected)")
        XCTAssertEqual(outcome.snapshot.sources.first?.rows, prior.sources[0].rows)
        XCTAssertTrue(outcome.log.contains(#"a: rejected "X": quoted figure "5%" does not match score 50.0"#))
    }

    func testDisabledSourceIsNeverRun() async {
        let h = ScriptedIndexHeadless()
        h.answers["a"] = (IndexFixtures.stream(IndexFixtures.payloadJSON("a", [("X", 1.0), ("Y", 2.0)])), "", 0)
        h.answers["b"] = h.answers["a"]
        let outcome = await runner(h).refresh(plan([IndexFixtures.source("a"), IndexFixtures.source("b", enabled: false)]))
        XCTAssertEqual(h.ran, ["a"])
        XCTAssertEqual(outcome.snapshot.sources.map(\.sourceID), ["a"])
    }

    func testEachSourceRunsTheWebOnlyExtractionCommand() async {
        let h = ScriptedIndexHeadless()
        _ = await runner(h).refresh(plan([IndexFixtures.source("a")]))
        let args = h.commands.first ?? []
        XCTAssertTrue(args.contains("WebSearch WebFetch"))
        XCTAssertTrue(args.contains("--restricted"))
        XCTAssertTrue(h.prompts.first?.contains("(id a)") == true)
    }

    func testRescoreUsesNewAliasesWithoutRunningAnything() {
        let snap = IndexSnapshot(createdAt: earlier, sources: [SourceResult(sourceID: "a", rows: [
            AcceptedRow(benchmarkModel: "GPT-6 Sol (high)", score: 61.3, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "61.3%"),
            AcceptedRow(benchmarkModel: "Opus 5 (high)", score: 58.0, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "58.0%")],
            refreshedAt: earlier)], aliases: [], scores: [], unmapped: [])
        var aliases = AliasTable()
        aliases.set(source: "a", benchmarkModel: "Opus 5 (high)", model: IndexFixtures.opus, status: .confirmed)
        let rescored = IndexRefreshRunner.rescore(snap, sources: [IndexFixtures.source("a")], aliases: aliases, now: now)
        XCTAssertEqual(rescored.scores.map(\.model), [IndexFixtures.opus])
        XCTAssertEqual(rescored.sources, snap.sources, "a rescore re-reads nothing")
        XCTAssertEqual(rescored.createdAt, now)
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `FD_TEST_FILTER=IndexRefreshRunnerTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'IndexRefreshRunner' in scope`.

- [ ] **Step 5: Implement `IndexRefreshRunner.swift`**

```swift
import Foundation
import IntakeKit

/// Everything one refresh needs, captured on the main actor and handed off whole, so the run
/// never reads the service's state while the user edits it in Settings.
struct IndexRefreshPlan: Sendable {
    var sources: [IndexSource]
    var aliases: AliasTable
    var catalogs: AdapterCatalogs
    var agent: IndexAgentSettings
    var previous: IndexSnapshot?
    var workDirectory: URL
}

struct IndexRefreshOutcome: Sendable {
    var snapshot: IndexSnapshot
    var proposals: [AliasEntry]
    var log: [String]
    var tokensUsed: Int
}

enum IndexRefreshError: Error, Equatable {
    case overCap(used: Int)
    case harness(String)
    case noValidRows(Int)
}

/// Counts one run's tokens from its stream as it arrives — `ActivityParser` already folds
/// claude's per-message usage without double counting — and fires once when the run's budget is
/// crossed, so the process can be stopped mid-run rather than allowed to finish over the cap.
final class IndexTokenMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var parser: ActivityParser
    private let budget: Int
    private var over = false
    private var onOver: (() -> Void)?

    init(cwd: URL, budget: Int) {
        parser = ActivityParser(harness: .claude, project: cwd, now: { Date() })
        self.budget = budget
    }

    private static func total(_ a: SeatActivity) -> Int { (a.inputTokens ?? 0) + (a.outputTokens ?? 0) }

    var total: Int { lock.withLock { Self.total(parser.activity) } }
    var isOver: Bool { lock.withLock { over } }

    func feed(_ chunk: Data) {
        let fire: (() -> Void)? = lock.withLock {
            parser.feed(chunk)
            guard !over, Self.total(parser.activity) > budget else { return nil }
            over = true
            return onOver
        }
        fire?()
    }

    /// Registers the stop action; runs it at once if the budget was already crossed — a fast
    /// run can cross it before the caller gets to register.
    func whenOver(_ action: @escaping () -> Void) {
        let alreadyOver: Bool = lock.withLock {
            onOver = action
            return over
        }
        if alreadyOver { action() }
    }
}

/// The refresh (spec §4): one headless claude run per enabled source, in registry order, each
/// answer validated before anything is scored. Runs sequentially on purpose — the token cap is
/// a running total, and parallel runs could each start under it and finish far over it.
///
/// A source that fails, is cut off by the cap, or returns no valid row keeps its PREVIOUS rows,
/// marked stale with the reason: one bad week must not erase a model's data.
struct IndexRefreshRunner: Sendable {
    let headless: HeadlessRunner
    let now: @Sendable () -> Date

    init(headless: HeadlessRunner = SystemHeadlessRunner(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.headless = headless
        self.now = now
    }

    func refresh(_ plan: IndexRefreshPlan) async -> IndexRefreshOutcome {
        var used = 0
        var results: [SourceResult] = []
        var log: [String] = []
        try? FileManager.default.createDirectory(at: plan.workDirectory, withIntermediateDirectories: true)

        for source in plan.sources where source.enabled {
            let prior = plan.previous?.sources.first { $0.sourceID == source.id }
            guard used < plan.agent.tokenCap else {
                results.append(Self.stale(source, prior, "token cap reached"))
                log.append("\(source.id): skipped, token cap reached (\(used) of \(plan.agent.tokenCap))")
                continue
            }
            do {
                let (payload, tokens) = try await extract(source, plan: plan, budget: plan.agent.tokenCap - used)
                used += tokens
                let checked = ExtractionValidator.validate(payload, for: source)
                for r in checked.rejected { log.append("\(source.id): rejected \"\(r.row.benchmarkModel)\": \(r.reason)") }
                guard !checked.accepted.isEmpty else { throw IndexRefreshError.noValidRows(checked.rejected.count) }
                results.append(SourceResult(sourceID: source.id, rows: checked.accepted, rejected: checked.rejected,
                                            refreshedAt: now(), tokens: tokens))
                log.append("\(source.id): \(checked.accepted.count) rows, \(tokens) tokens")
            } catch IndexRefreshError.overCap(let spent) {
                used += spent
                results.append(Self.stale(source, prior, "token cap reached"))
                log.append("\(source.id): stopped at the token cap after \(spent) tokens")
            } catch {
                results.append(Self.stale(source, prior, Self.describe(error)))
                log.append("\(source.id): failed: \(Self.describe(error))")
            }
        }

        let snapshot = IndexSnapshot.assemble(results: results, sources: plan.sources, aliases: plan.aliases, createdAt: now())
        let proposals = AliasProposer.propose(snapshot.unmapped, table: plan.aliases, catalogs: plan.catalogs)
        return IndexRefreshOutcome(snapshot: snapshot, proposals: proposals, log: log, tokensUsed: used)
    }

    /// Re-scores a snapshot's rows under a changed alias table or source list — no agent run, no
    /// tokens. Used when the user confirms or edits an alias, so the change is a new snapshot
    /// that rollback can undo.
    static func rescore(_ snapshot: IndexSnapshot, sources: [IndexSource], aliases: AliasTable, now: Date) -> IndexSnapshot {
        IndexSnapshot.assemble(results: snapshot.sources, sources: sources, aliases: aliases, createdAt: now)
    }

    private func extract(_ source: IndexSource, plan: IndexRefreshPlan, budget: Int) async throws -> (ExtractionPayload, Int) {
        let command = IndexExtraction.command(prompt: IndexExtraction.prompt(source: source, catalogs: plan.catalogs),
                                              settings: plan.agent)
        let meter = IndexTokenMeter(cwd: plan.workDirectory, budget: budget)
        let headless = self.headless
        let cwd = plan.workDirectory
        let run = Task { try await headless.run(command, cwd: cwd, onStdout: { meter.feed($0) }) }
        // Cancelling the task terminates the process (`SystemCommandRunner`'s cancellation
        // handler sends SIGTERM), which is how a run is stopped at the cap.
        meter.whenOver { run.cancel() }
        let result: (stdout: Data, stderr: String, exitCode: Int32)
        do {
            result = try await run.value
        } catch {
            if meter.isOver { throw IndexRefreshError.overCap(used: meter.total) }
            throw error
        }
        // A runner that cannot stream hands stdout over at exit, too late to stop it — the cap
        // still applies: over is over, whether or not the process could be stopped early.
        if meter.isOver { throw IndexRefreshError.overCap(used: meter.total) }
        guard result.exitCode == 0 else {
            throw IndexRefreshError.harness("claude exited \(result.exitCode): \(result.stderr.prefix(200))")
        }
        return (try IndexExtraction.parse(stdout: result.stdout), meter.total)
    }

    static func stale(_ source: IndexSource, _ prior: SourceResult?, _ why: String) -> SourceResult {
        SourceResult(sourceID: source.id, rows: prior?.rows ?? [], stale: true, error: why,
                     refreshedAt: prior?.refreshedAt, tokens: 0)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? IndexRefreshError {
            switch e {
            case .harness(let why): return why
            case .noValidRows(let n): return "no valid rows (\(n) rejected)"
            case .overCap(let used): return "token cap reached after \(used) tokens"
            }
        }
        if let e = error as? HarnessOutput.ParseError { return "unreadable answer: \(e)" }
        if error is DecodingError { return "the answer did not match the row format" }
        return String(describing: error)
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=IndexRefreshRunnerTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/FlightControl/IndexRefreshRunner.swift Tests/FlightDeckTests/FlightControlL3/Index/IndexTestDoubles.swift Tests/FlightDeckTests/FlightControlL3/Index/IndexRefreshRunnerTests.swift
git commit -m "feat: refresh the capability index per source under a token cap, keeping stale values on failure" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: The service — apply, rollback, aliases, hand scores, the weekly check

**Files:**
- Create: `Sources/FlightDeck/FlightControl/CapabilityIndexService.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/CapabilityIndexServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 1–10; `WatchClock` (`Sources/FlightDeck/WatchClock.swift`: `add(_:_:)`, `remove(_:)`, `isRegistered(_:)`, `init(appIsActive:)`).
- Produces:
  - `final class LiveCapabilityIndex: CapabilityIndex, @unchecked Sendable { update(_:); current: SnapshotCapabilityIndex; rank(kind:candidates:); snapshotDate; hints(for:assigned:candidates:) }`
  - `@MainActor final class CapabilityIndexService: ObservableObject` with `static refreshInterval`, `static directory(stateRoot:) -> URL`, `init(directory:runner:catalogs:now:)`, published `config`, `currentRef`, `current`, `previous`, `changes`, `scores`, `isRefreshing`, `lastLog`, `problem`, `knownCatalogs`; `live: LiveCapabilityIndex`; `refreshTask`; `isDue`; `canRollBack`; `reload()`; `startScheduling(clock:)`; `stopScheduling()`; `tick()`; `startRefresh() -> Task<Void, Never>?`; `refreshNow() async`; `rollBack()`; `confirmAlias/rejectAlias/removeAlias(source:benchmarkModel:)`; `mapAlias(source:benchmarkModel:to:)`; `setManual(_:replacing:)`; `removeManual(_:)`; `setSourceEnabled(_:_:)`; `setAgent(_:)`; `citations(model:dimension:) -> [Citation]`; `hints(for:assigned:candidates:) -> [CapabilityHint]`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The service is where the index meets time and the user: a new snapshot applies the moment
/// it is written, rollback is one call, the weekly check never fires before a first manual
/// refresh, and — the expensive failure — a refresh that fails must not be retried on every
/// beat of the 500 ms clock.
@MainActor
final class CapabilityIndexServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_093_600)
    private var dir: URL!

    override func setUp() {
        dir = IndexFixtures.scratch()
        let d = dir!
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
    }

    private func make(_ h: ScriptedIndexHeadless) -> CapabilityIndexService {
        let t = now
        return CapabilityIndexService(directory: dir, runner: IndexRefreshRunner(headless: h, now: { t }),
                                      catalogs: { IndexFixtures.catalogs() }, now: { t })
    }

    private func seedConfig(_ change: (inout IndexConfig) -> Void = { _ in }) throws {
        var c = IndexConfig.initial()
        c.sources = [IndexFixtures.source("a")]
        c.aliases.set(source: "a", benchmarkModel: "GPT-6 Sol (high)", model: IndexFixtures.sol, status: .confirmed)
        change(&c)
        try c.save(to: dir.appendingPathComponent("config.json"))
    }

    private let kind = TaskKind(id: "k", name: "K", description: "d", dimensions: ["agentic-coding": 1], origin: .user,
                                createdAt: Date(timeIntervalSince1970: 0))

    private func answerA(_ h: ScriptedIndexHeadless) {
        h.answers["a"] = (IndexFixtures.stream(IndexFixtures.payloadJSON("a", [("GPT-6 Sol (high)", 61.3), ("Opus 5 (high)", 58.0)])), "", 0)
    }

    func testRefreshWritesAndAppliesTheSnapshot() async throws {
        try seedConfig()
        let h = ScriptedIndexHeadless()
        answerA(h)
        let service = make(h)
        await service.refreshNow()
        XCTAssertEqual(service.current?.createdAt, now)
        XCTAssertEqual(service.live.snapshotDate, now)
        XCTAssertEqual(service.live.rank(kind: kind, candidates: [IndexFixtures.bare(IndexFixtures.sol)]).first?.model, IndexFixtures.sol)
        XCTAssertEqual(service.config.aliases.pending.map(\.model), [IndexFixtures.opus], "proposals land as pending aliases")
        XCTAssertFalse(service.isRefreshing)
        XCTAssertEqual(IndexSnapshotStore(directory: dir).list().count, 1)
    }

    func testFirstRefreshIsNeverAutomatic() throws {
        try seedConfig()
        let h = ScriptedIndexHeadless()
        let service = make(h)
        XCTAssertFalse(service.isDue)
        service.tick()
        XCTAssertNil(service.refreshTask, "a fresh install must not spend tokens until someone clicks Refresh now")
    }

    func testFailedRefreshDoesNotRetryOnNextTick() async throws {
        try seedConfig { $0.lastRefreshAttemptAt = self.now.addingTimeInterval(-8 * 86_400) }
        let h = ScriptedIndexHeadless()   // no answers: every source fails
        let service = make(h)
        XCTAssertTrue(service.isDue)
        service.tick()
        await service.refreshTask?.value
        XCTAssertEqual(h.prompts.count, 1)
        service.tick()
        service.tick()
        await service.refreshTask?.value
        XCTAssertEqual(h.prompts.count, 1, "a failed run waits a week; it must not retry on every 500 ms beat")
        XCTAssertEqual(service.config.lastRefreshAttemptAt, now)
        XCTAssertFalse(service.isDue)
    }

    func testDueAWeekAfterTheLastSnapshot() throws {
        try seedConfig()
        try IndexSnapshotStore(directory: dir).write(IndexSnapshot(createdAt: now.addingTimeInterval(-7 * 86_400), sources: [],
                                                                   aliases: [], scores: [], unmapped: []))
        XCTAssertTrue(make(ScriptedIndexHeadless()).isDue)
    }

    func testRollBackMakesThePreviousCurrentAndRepublishes() throws {
        try seedConfig()
        let store = IndexSnapshotStore(directory: dir)
        let older = now.addingTimeInterval(-86_400)
        try store.write(IndexSnapshot(createdAt: older, sources: [], aliases: [], scores: [], unmapped: []))
        try store.write(IndexSnapshot(createdAt: now, sources: [], aliases: [], scores: [], unmapped: []))
        let service = make(ScriptedIndexHeadless())
        XCTAssertTrue(service.canRollBack)
        service.rollBack()
        XCTAssertEqual(service.current?.createdAt, older)
        XCTAssertEqual(service.live.snapshotDate, older)
        XCTAssertFalse(service.canRollBack)
        service.rollBack()
        XCTAssertEqual(service.problem, "There is no earlier snapshot to roll back to.")
        XCTAssertEqual(service.current?.createdAt, older)
    }

    func testConfirmingAnAliasRescoresWithoutAnAgentRun() throws {
        try seedConfig { $0.aliases.addProposals([AliasEntry(source: "a", benchmarkModel: "Opus 5 (high)", model: IndexFixtures.opus, status: .pending)]) }
        let rows = [AcceptedRow(benchmarkModel: "GPT-6 Sol (high)", score: 61.3, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "61.3%"),
                    AcceptedRow(benchmarkModel: "Opus 5 (high)", score: 58.0, unit: .percent, url: "https://a.test", retrievedAt: nil, quotedFigure: "58.0%")]
        try IndexSnapshotStore(directory: dir).write(IndexSnapshot(createdAt: now.addingTimeInterval(-60),
                                                                   sources: [SourceResult(sourceID: "a", rows: rows, refreshedAt: nil)],
                                                                   aliases: [], scores: [], unmapped: []))
        let h = ScriptedIndexHeadless()
        let service = make(h)
        service.confirmAlias(source: "a", benchmarkModel: "Opus 5 (high)")
        XCTAssertEqual(service.scores.first { $0.model == IndexFixtures.opus }?.dimensions["agentic-coding"]?.score, 0)
        XCTAssertEqual(h.prompts, [], "a rescore never runs the agent")
        XCTAssertEqual(IndexSnapshotStore(directory: dir).list().count, 2, "the rescore is its own snapshot, so it can be rolled back")
        service.rejectAlias(source: "a", benchmarkModel: "GPT-6 Sol (high)")
        XCTAssertNil(service.scores.first { $0.model == IndexFixtures.sol }, "rejecting a confirmed mapping unscores it")
    }

    func testManualScoresReachTheLiveIndex() throws {
        try seedConfig()
        let service = make(ScriptedIndexHeadless())
        let local = ModelRef(harness: "opencode", model: "ollama/qwen")
        service.setManual(ManualModelScores(model: local, dimensions: ["agentic-coding": 0.9]))
        XCTAssertEqual(service.live.rank(kind: kind, candidates: [local]).first?.score, 0.9)
        XCTAssertEqual(service.scores.first { $0.model == local }?.dimensions["agentic-coding"]?.origin, .manual)
        let renamed = ModelRef(harness: "opencode", model: "ollama/qwen3")
        service.setManual(ManualModelScores(model: renamed, dimensions: ["agentic-coding": 0.8]), replacing: local)
        XCTAssertEqual(service.config.manual.map(\.model), [renamed])
        XCTAssertEqual(IndexConfig.load(from: dir.appendingPathComponent("config.json")).config.manual.map(\.model), [renamed], "hand scores persist")
    }

    func testUnreadableConfigIsReportedNotOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: dir.appendingPathComponent("config.json"))
        let service = make(ScriptedIndexHeadless())
        XCTAssertNotNil(service.problem)
        XCTAssertEqual(service.config, IndexConfig.initial())
    }

    func testSchedulingRegistersOnTheSharedClock() throws {
        try seedConfig()
        let clock = WatchClock(appIsActive: { true })
        let service = make(ScriptedIndexHeadless())
        service.startScheduling(clock: clock)
        XCTAssertTrue(clock.isRegistered(service))
        service.stopScheduling()
        XCTAssertFalse(clock.isRegistered(service))
    }

    func testHintsComeFromTheLiveIndex() throws {
        try seedConfig()
        let service = make(ScriptedIndexHeadless())
        service.setManual(ManualModelScores(model: IndexFixtures.sol, dimensions: ["debugging": 0.2]))
        service.setManual(ManualModelScores(model: IndexFixtures.opus, dimensions: ["debugging": 0.9]))
        XCTAssertEqual(service.hints(for: ["debugging": 0.5], assigned: IndexFixtures.sol, candidates: [IndexFixtures.opus]).first?.better,
                       IndexFixtures.opus)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=CapabilityIndexServiceTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'CapabilityIndexService' in scope`.

- [ ] **Step 3: Implement `CapabilityIndexService.swift`**

```swift
import Foundation
import IntakeKit

/// The `CapabilityIndex` the router holds (integration passes this to L3-R). A lock-guarded
/// box: the protocol is nonisolated and `Sendable`, so the router may read it from any context,
/// while the service swaps in a new frozen `SnapshotCapabilityIndex` on the main actor
/// whenever a snapshot applies, a rollback happens or a hand score changes.
final class LiveCapabilityIndex: CapabilityIndex, @unchecked Sendable {
    private let lock = NSLock()
    private var index = SnapshotCapabilityIndex.empty

    func update(_ new: SnapshotCapabilityIndex) { lock.withLock { index = new } }
    var current: SnapshotCapabilityIndex { lock.withLock { index } }

    func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel] { current.rank(kind: kind, candidates: candidates) }
    var snapshotDate: Date? { current.snapshotDate }

    func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef]) -> [CapabilityHint] {
        current.hints(for: ruleDimensions, assigned: assigned, candidates: candidates)
    }
}

/// Owns the capability index: its config, its snapshots, the weekly refresh and the live index.
///
/// A new snapshot applies the moment it is written (spec §7) — safe because the index only
/// drives fallback routing and hints, never a rule. Rollback is one call. Built and scheduled
/// only by `FlightDeckApp.makeStore`; every test builds its own with a scratch directory and a
/// scripted runner, so no test can start a refresh that spends tokens.
@MainActor
final class CapabilityIndexService: ObservableObject {
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    @Published private(set) var config: IndexConfig
    @Published private(set) var currentRef: SnapshotRef?
    @Published private(set) var current: IndexSnapshot?
    @Published private(set) var previous: IndexSnapshot?
    @Published private(set) var changes: [ScoreChange] = []
    /// The current snapshot's scores with hand and inherited scores laid over them — what the
    /// heatmap draws and what `live` ranks.
    @Published private(set) var scores: [ModelScores] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastLog: [String] = []
    @Published private(set) var problem: String?
    /// The catalogs the last refresh saw, for the alias "Map to…" menu.
    @Published private(set) var knownCatalogs = AdapterCatalogs([])

    let live = LiveCapabilityIndex()
    let directory: URL
    /// The refresh in flight, if any — exposed so tests (and nothing else) can await it.
    private(set) var refreshTask: Task<Void, Never>?

    private let store: IndexSnapshotStore
    private let runner: IndexRefreshRunner
    private let catalogs: @MainActor () async -> AdapterCatalogs
    private let now: () -> Date
    private weak var clock: WatchClock?

    init(directory: URL, runner: IndexRefreshRunner = IndexRefreshRunner(),
         catalogs: @escaping @MainActor () async -> AdapterCatalogs = { AdapterCatalogs([]) },
         now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.store = IndexSnapshotStore(directory: directory)
        self.runner = runner
        self.catalogs = catalogs
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loaded = IndexConfig.load(from: directory.appendingPathComponent("config.json"))
        config = loaded.config
        problem = loaded.problem
        reload()
    }

    /// `<state dir>/capability-index`. The state dir already differs between Debug and Release
    /// (`FileSessionPersistence.defaultDirectory`), so a Debug build never applies, rolls back
    /// or overwrites the installed app's index.
    static func directory(stateRoot: URL) -> URL {
        stateRoot.appendingPathComponent("capability-index", isDirectory: true)
    }

    private var configURL: URL { directory.appendingPathComponent("config.json") }

    var canRollBack: Bool { previous != nil }

    /// Re-reads the snapshots and republishes everything derived from them, `live` included.
    func reload() {
        let cur = store.current()
        currentRef = cur?.ref
        current = cur?.snapshot
        previous = cur.flatMap { store.previous(before: $0.ref)?.snapshot }
        changes = current.map { SnapshotDiff.changes(from: previous, to: $0) } ?? []
        scores = CapabilityScoring.overlay(current?.scores ?? [], manual: config.manual)
        live.update(SnapshotCapabilityIndex(scores: scores, snapshotDate: current?.createdAt))
    }

    // MARK: - The weekly check

    /// Due a week after the last attempt (or, failing that, the current snapshot). Never due
    /// before either exists: the first refresh is the user's "Refresh now", so a fresh install
    /// never spends tokens nobody asked for.
    var isDue: Bool {
        guard let last = config.lastRefreshAttemptAt ?? current?.createdAt else { return false }
        return now().timeIntervalSince(last) >= Self.refreshInterval
    }

    /// Registers on the app's one `WatchClock` rather than owning a weekly timer: a beat costs a
    /// date comparison, and a second timer would be a second wakeup source.
    func startScheduling(clock: WatchClock) {
        self.clock = clock
        clock.add(self) { [weak self] in self?.tick() }
    }

    func stopScheduling() { clock?.remove(self) }

    func tick() {
        guard isDue else { return }
        startRefresh()
    }

    // MARK: - Refresh

    /// Starts a refresh unless one is running. `lastRefreshAttemptAt` is written HERE, before
    /// the run, not when it succeeds: a run that fails would otherwise leave the index due, and
    /// the next clock beat 500 ms later would start another — a token-burning retry loop.
    @discardableResult
    func startRefresh() -> Task<Void, Never>? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
        mutateConfig { $0.lastRefreshAttemptAt = now() }
        let task = Task { await self.performRefresh() }
        refreshTask = task
        return task
    }

    func refreshNow() async {
        await startRefresh()?.value
    }

    private func performRefresh() async {
        let cats = await catalogs()
        knownCatalogs = cats
        let plan = IndexRefreshPlan(sources: config.sources, aliases: config.aliases, catalogs: cats, agent: config.agent,
                                    previous: current, workDirectory: directory.appendingPathComponent("work", isDirectory: true))
        let outcome = await runner.refresh(plan)
        mutateConfig { $0.aliases.addProposals(outcome.proposals) }
        lastLog = outcome.log
        do {
            try store.write(outcome.snapshot)
            try store.prune()
        } catch {
            problem = "Could not save the snapshot: \(error.localizedDescription)"
        }
        reload()
        isRefreshing = false
    }

    // MARK: - Rollback

    func rollBack() {
        do {
            try store.rollBack()
            problem = nil
        } catch IndexStoreError.nothingToRollBackTo {
            problem = "There is no earlier snapshot to roll back to."
        } catch {
            problem = "Could not roll back: \(error.localizedDescription)"
        }
        reload()
    }

    // MARK: - Aliases, sources, hand scores, agent

    func confirmAlias(source: String, benchmarkModel: String) {
        mutateAliases { $0.confirm(source: source, benchmarkModel: benchmarkModel) }
    }

    func rejectAlias(source: String, benchmarkModel: String) {
        mutateAliases { $0.reject(source: source, benchmarkModel: benchmarkModel) }
    }

    func removeAlias(source: String, benchmarkModel: String) {
        mutateAliases { $0.remove(source: source, benchmarkModel: benchmarkModel) }
    }

    func mapAlias(source: String, benchmarkModel: String, to model: ModelRef) {
        mutateAliases { $0.set(source: source, benchmarkModel: benchmarkModel, model: model, status: .confirmed) }
    }

    func setSourceEnabled(_ id: String, _ enabled: Bool) {
        mutateConfig { c in
            if let i = c.sources.firstIndex(where: { $0.id == id }) { c.sources[i].enabled = enabled }
        }
        rescoreCurrent()
    }

    /// Saves a hand-entered entry; `replacing` drops the entry it was edited from, so renaming a
    /// local model in the editor does not leave its old name behind.
    func setManual(_ entry: ManualModelScores, replacing old: ModelRef? = nil) {
        mutateConfig { c in
            c.manual.removeAll { $0.model == entry.model || $0.model == old }
            c.manual.append(entry)
        }
        reload()
    }

    func removeManual(_ model: ModelRef) {
        mutateConfig { $0.manual.removeAll { $0.model == model } }
        reload()
    }

    func setAgent(_ settings: IndexAgentSettings) {
        mutateConfig { $0.agent = settings }
    }

    func citations(model: ModelRef, dimension: String) -> [Citation] {
        guard let current else { return [] }
        return CapabilityScoring.citations(for: model, dimension: dimension, snapshot: current, sources: config.sources)
    }

    func hints(for ruleDimensions: [String: Double], assigned: ModelRef, candidates: [ModelRef]) -> [CapabilityHint] {
        live.hints(for: ruleDimensions, assigned: assigned, candidates: candidates)
    }

    /// Only a change to what MAPS rescoring: a new pending proposal or a rejected one that was
    /// never confirmed changes no score, and writing a snapshot for it would push a real one out
    /// of the twelve kept.
    private func mutateAliases(_ change: (inout AliasTable) -> Void) {
        let before = config.aliases.confirmed
        mutateConfig { change(&$0.aliases) }
        guard config.aliases.confirmed != before else { return }
        rescoreCurrent()
    }

    private func rescoreCurrent() {
        guard let current else { reload(); return }
        let rescored = IndexRefreshRunner.rescore(current, sources: config.sources, aliases: config.aliases, now: now())
        do {
            try store.write(rescored)
            try store.prune()
        } catch {
            problem = "Could not save the rescored snapshot: \(error.localizedDescription)"
        }
        reload()
    }

    private func mutateConfig(_ change: (inout IndexConfig) -> Void) {
        var c = config
        change(&c)
        config = c
        do { try c.save(to: configURL) }
        catch { problem = "Could not save capability index settings: \(error.localizedDescription)" }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=CapabilityIndexServiceTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED` and no `error:` lines. If `testSchedulingRegistersOnTheSharedClock`
leaves a timer running, it is cancelled by `remove` (`WatchClock.reschedule` cancels when no
subscriber is left) — no extra teardown needed.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightControl/CapabilityIndexService.swift Tests/FlightDeckTests/FlightControlL3/Index/CapabilityIndexServiceTests.swift
git commit -m "feat: apply, roll back and weekly-refresh the capability index without retrying a failed run" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: The Settings pane and its wiring

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/CapabilityIndexPane.swift`
- Create: `Sources/FlightDeck/Preferences/UI/CapabilityIndexSettingsTab.swift`
- Modify: `Sources/FlightDeck/Preferences/PreferencesTab.swift` (add `case capabilityIndex`)
- Modify: `Sources/FlightDeck/Preferences/UI/PreferencesView.swift` (add the tab)
- Modify: `Sources/FlightDeck/SessionStore.swift` (two members after `private var intakeChangeForward: AnyCancellable?`)
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (build the service in `makeStore`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Index/CapabilityIndexPaneTests.swift`

**Interfaces:**
- Consumes: `CapabilityIndexService` (Task 11); `RoutingCapabilityRegistry.standard()`, `AgentID.harnessID` (L3-0); `TerminologyScan.offenders(under:allow:skipping:)`, `TerminologyScan.internalAllowList` (`Tests/FlightDeckTests/Intake/Planning/TerminologyGuardTests.swift`); `FlightDeckApp.stateDirectory()`, `FileSessionPersistence.defaultDirectory()`.
- Produces:
  - `struct CapabilityIndexPane: View` with pure statics `cellIdentifier(model:dimension:) -> String`, `cellValue(_: DimensionScore?) -> String`, `cellOpacity(confidence:) -> Double`, `describe(_: ScoreChange) -> String`, `utc(_: Date) -> String`, `shortName(_: String) -> String`
  - `struct ManualScoresEditor: View` with `static func parse(_: [String: String]) -> [String: Double]`
  - `struct CapabilityIndexSettingsTab: View { let index: CapabilityIndexService? }`
  - `PreferencesTab.capabilityIndex`
  - `SessionStore.capabilityIndexService: CapabilityIndexService?`, `SessionStore.watchClock: WatchClock`
  - launch argument `-FlightDeckCapabilityIndexFixture <dir>` (honoured only under `-FlightDeckResetState YES`)
  - accessibility identifiers: `prefs-flight-control`, `index-heatmap`, `index-cell-<key>-<dimension>`, `index-last-refresh`, `index-refresh-now`, `index-rollback`, `index-diff`, `index-diff-row`, `index-citation-url`, `index-citations-done`, `index-source-<id>`, `index-alias-pending`, `index-manual-add`, `index-problem`

- [ ] **Step 1: Verify the anchors this task edits (read-only)**

Run: `rg -n "private var intakeChangeForward: AnyCancellable\?|private lazy var clock = WatchClock" Sources/FlightDeck/SessionStore.swift`
Expected: two hits. If the `intakeChangeForward` line moved or was renamed, insert the two new
members directly after the `intakeService` lazy property instead.
Run: `rg -n "switch .*selectedTab|case \.devices" Sources Tests`
Expected: no hit. If an exhaustive `switch` over `PreferencesTab` now exists, add a
`case .capabilityIndex:` arm there that does what its `.devices` arm does.
Run: `rg -n "if resetState, Self.isSeedingSecondProject" Sources/FlightDeck/FlightDeckApp.swift`
Expected: one hit (the insertion point in `makeStore`).
Then run `quillmap_impact` on `Sources/FlightDeck/SessionStore.swift` and
`Sources/FlightDeck/FlightDeckApp.swift` (load-bearing; CLAUDE.md) and read its output before
editing.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The pane's words and identifiers are what the UI test and VoiceOver read, so their pure
/// parts are pinned here, headless: a cell says its score, confidence and where the score came
/// from; a diff row says what moved and by how much; times are UTC so a screenshot means the
/// same thing in every zone. And the new copy obeys the house words.
final class CapabilityIndexPaneTests: XCTestCase {
    func testFlightControlIsASettingsPane() {
        XCTAssertTrue(PreferencesTab.allCases.contains(.capabilityIndex))
    }

    func testCellIdentifierIsStable() {
        XCTAssertEqual(CapabilityIndexPane.cellIdentifier(model: IndexFixtures.sol, dimension: "test-authoring"),
                       "index-cell-codex/gpt-6-sol[effort=high]-test-authoring")
    }

    func testCellValueSaysScoreConfidenceAndOrigin() {
        XCTAssertEqual(CapabilityIndexPane.cellValue(DimensionScore(score: 0.82, confidence: 0.75)), "0.82, confidence 0.75, computed")
        XCTAssertEqual(CapabilityIndexPane.cellValue(DimensionScore(score: 0.5, confidence: 1, origin: .manual)), "0.50, confidence 1.00, manual")
        XCTAssertEqual(CapabilityIndexPane.cellValue(DimensionScore(score: 0.68, confidence: 0.75, origin: .inherited, inheritedFrom: IndexFixtures.sol)),
                       "0.68, confidence 0.75, inherited from codex · gpt-6-sol (effort high)")
        XCTAssertEqual(CapabilityIndexPane.cellValue(nil), "unknown")
    }

    func testOpacityTracksConfidenceButNeverVanishes() {
        XCTAssertEqual(CapabilityIndexPane.cellOpacity(confidence: 0), 0.2, accuracy: 1e-12)
        XCTAssertEqual(CapabilityIndexPane.cellOpacity(confidence: 1), 1, accuracy: 1e-12)
        XCTAssertEqual(CapabilityIndexPane.cellOpacity(confidence: 7), 1, accuracy: 1e-12)
    }

    func testDiffRowWording() {
        XCTAssertEqual(CapabilityIndexPane.describe(ScoreChange(model: IndexFixtures.sol, dimension: "test-authoring", before: 0.6, after: 0.8)),
                       "codex · gpt-6-sol (effort high) — test-authoring 0.60 → 0.80 (+0.20)")
        XCTAssertEqual(CapabilityIndexPane.describe(ScoreChange(model: IndexFixtures.sonnet, dimension: "speed", before: nil, after: 0.3)),
                       "claude · sonnet — speed new 0.30")
        XCTAssertEqual(CapabilityIndexPane.describe(ScoreChange(model: IndexFixtures.sonnet, dimension: "docs-prose", before: 0.5, after: nil)),
                       "claude · sonnet — docs-prose 0.50 → unknown")
    }

    func testTimesAreUTC() {
        XCTAssertEqual(CapabilityIndexPane.utc(Date(timeIntervalSince1970: 1_791_093_600)), "2026-10-04 06:00 UTC")
    }

    func testManualEditorKeepsOnlyScoresInRange() {
        XCTAssertEqual(ManualScoresEditor.parse(["debugging": "0.7", "speed": " 1 ", "docs-prose": "", "frontend-ui": "1.5", "x": "abc"]),
                       ["debugging": 0.7, "speed": 1])
    }

    func testNewCopyUsesTheHouseWords() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // …/Tests/FlightDeckTests/FlightControlL3/Index
            .appendingPathComponent("../../../../").standardized
        for dir in ["Sources/FlightDeck/FlightControl", "Sources/IntakeKit/FlightControl", "Sources/FlightDeck/Preferences/UI"] {
            let offenders = try TerminologyScan.offenders(under: root.appendingPathComponent(dir), allow: TerminologyScan.internalAllowList)
            XCTAssertEqual(offenders, [], offenders.joined(separator: "\n"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/FlightDeck/Preferences/UI/CapabilityIndexPane.swift").path),
                      "the sweep must actually reach the pane")
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=CapabilityIndexPaneTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `type 'PreferencesTab' has no member 'capabilityIndex'`.

- [ ] **Step 4: Add the tab case**

In `Sources/FlightDeck/Preferences/PreferencesTab.swift`, replace

```swift
    case devices
}
```

with

```swift
    case devices
    /// Flight Control's Level 3 settings: the capability index here; routing and pools join it
    /// at integration.
    case capabilityIndex
}
```

- [ ] **Step 5: Write `CapabilityIndexSettingsTab.swift`**

```swift
import SwiftUI

/// Settings → Flight Control. This branch ships its one section, the capability index; L3-R
/// (routing, task kinds) and L3-U (pools) add theirs here at integration.
///
/// Takes the service, not the store: observing `SessionStore` would redraw the whole pane on
/// every session tick.
struct CapabilityIndexSettingsTab: View {
    let index: CapabilityIndexService?

    var body: some View {
        if let index {
            CapabilityIndexPane(service: index)
        } else {
            Text("The capability index is not running in this window.")
                .foregroundStyle(.secondary)
                .padding()
        }
    }
}
```

- [ ] **Step 6: Write `CapabilityIndexPane.swift`**

```swift
import IntakeKit
import SwiftUI

/// Settings → Flight Control → Capability index (spec §8): the heatmap (color is the score,
/// strength is the confidence), click-through to the cited rows, the diff with Roll back, the
/// sources, the alias table with pending proposals, hand-entered scores and the refresh agent.
///
/// Times are shown in UTC on purpose: snapshot names are UTC, and a screenshot or a bug report
/// should name the same snapshot whatever zone it was taken in.
struct CapabilityIndexPane: View {
    @ObservedObject var service: CapabilityIndexService
    @State private var selectedCell: CellSelection?
    @State private var editing: ManualDraft?

    struct CellSelection: Identifiable {
        let model: ModelRef
        let dimension: String
        var id: String { CapabilityIndexPane.cellIdentifier(model: model, dimension: dimension) }
    }

    struct ManualDraft: Identifiable {
        let id = UUID()
        var entry: ManualModelScores
        var original: ModelRef?
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let problem = service.problem {
                    Text(problem).foregroundStyle(.red).accessibilityIdentifier("index-problem")
                }
                heatmap
                diff
                sourcesSection
                aliasesSection
                manualSection
                agentSection
                logSection
            }
            .padding(20)
        }
        .sheet(item: $selectedCell) { cell in citationsSheet(cell) }
        .sheet(item: $editing) { draft in
            ManualScoresEditor(entry: draft.entry, knownModels: knownModels) { saved in
                service.setManual(saved, replacing: draft.original)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Capability index").font(.title3.bold())
                Text(snapshotLine)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("index-last-refresh")
            }
            Spacer()
            Button(service.isRefreshing ? "Refreshing…" : "Refresh now") { service.startRefresh() }
                .disabled(service.isRefreshing)
                .accessibilityIdentifier("index-refresh-now")
            Button("Roll back") { service.rollBack() }
                .disabled(!service.canRollBack || service.isRefreshing)
                .help("Make the previous snapshot current")
                .accessibilityIdentifier("index-rollback")
        }
    }

    private var snapshotLine: String {
        guard let current = service.current else {
            return "No snapshot yet. Refresh now reads every enabled source; after that the index refreshes weekly."
        }
        let attempt = service.config.lastRefreshAttemptAt.map { " · last attempt \(Self.utc($0))" } ?? ""
        return "Current snapshot \(Self.utc(current.createdAt))\(attempt)"
    }

    // MARK: Heatmap

    private var heatmap: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scores").font(.headline)
            if service.scores.isEmpty {
                Text("No model has a score yet.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 2, verticalSpacing: 2) {
                        GridRow {
                            Text("Model").font(.caption.bold())
                            ForEach(Dimensions.all, id: \.id) { d in
                                Text(Self.shortName(d.id)).font(.caption2).frame(width: 52).help(d.summary)
                            }
                        }
                        ForEach(service.scores, id: \.model) { row in
                            GridRow {
                                Text(IndexKeys.label(row.model)).font(.caption).lineLimit(1)
                                    .frame(width: 190, alignment: .leading)
                                ForEach(Dimensions.all, id: \.id) { d in
                                    cell(row.model, d.id, row.dimensions[d.id])
                                }
                            }
                        }
                    }
                }
            }
            Text("Color is the score; strength is the confidence. M is entered by hand, I is inherited. Click a cell to see the rows behind it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("index-heatmap")
    }

    private func cell(_ model: ModelRef, _ dimension: String, _ score: DimensionScore?) -> some View {
        Button {
            selectedCell = CellSelection(model: model, dimension: dimension)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(score.map { Self.color(for: $0.score).opacity(Self.cellOpacity(confidence: $0.confidence)) }
                          ?? Color.secondary.opacity(0.08))
                Text(score.map { String(format: "%.2f", $0.score) + Self.originMark($0.origin) } ?? "—")
                    .font(.caption2.monospacedDigit())
            }
            .frame(width: 52, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(score == nil)
        .accessibilityLabel(Self.cellValue(score))
        .accessibilityIdentifier(Self.cellIdentifier(model: model, dimension: dimension))
    }

    // MARK: Diff

    private var diff: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Changes since the previous snapshot").font(.headline)
            if service.previous == nil {
                Text("No earlier snapshot to compare with.").foregroundStyle(.secondary)
            } else if service.changes.isEmpty {
                Text("No score moved by 0.01 or more.").foregroundStyle(.secondary)
            } else {
                ForEach(Array(service.changes.enumerated()), id: \.offset) { _, change in
                    Text(Self.describe(change))
                        .font(.callout.monospacedDigit())
                        .accessibilityIdentifier("index-diff-row")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("index-diff")
    }

    // MARK: Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sources").font(.headline)
            ForEach(service.config.sources) { source in
                HStack(alignment: .firstTextBaseline) {
                    Toggle(isOn: Binding(get: { source.enabled }, set: { service.setSourceEnabled(source.id, $0) })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.name)
                            Text("\(source.url) · \(source.unit)\(source.machineReadable ? " · data file" : "")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if let result = service.current?.sources.first(where: { $0.sourceID == source.id }), result.stale {
                        Text("stale: \(result.error ?? "not refreshed")").font(.caption).foregroundStyle(.orange)
                    }
                }
                .accessibilityIdentifier("index-source-\(source.id)")
            }
            ForEach(IndexSourceRegistry.problems(service.config.sources), id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: Aliases

    private var aliasesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model names").font(.headline)
            Text("Benchmarks name models their own way. A name scores only once it maps to a model here; an unmapped name is ignored.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(service.config.aliases.pending.enumerated()), id: \.offset) { _, e in
                HStack {
                    Text("\(e.source): \"\(e.benchmarkModel)\" → \(IndexKeys.label(e.model))?")
                    Spacer()
                    Button("Confirm") { service.confirmAlias(source: e.source, benchmarkModel: e.benchmarkModel) }
                    Button("Reject") { service.rejectAlias(source: e.source, benchmarkModel: e.benchmarkModel) }
                }
                .accessibilityIdentifier("index-alias-pending")
            }
            ForEach(Array(service.config.aliases.confirmed.enumerated()), id: \.offset) { _, e in
                HStack {
                    Text("\(e.source): \"\(e.benchmarkModel)\" → \(IndexKeys.label(e.model))")
                    Spacer()
                    Button {
                        service.removeAlias(source: e.source, benchmarkModel: e.benchmarkModel)
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this mapping")
                }
            }
            if !unmappedWithoutEntry.isEmpty {
                DisclosureGroup("Unmapped names (\(unmappedWithoutEntry.count))") {
                    ForEach(unmappedWithoutEntry, id: \.self) { name in
                        HStack {
                            Text("\(name.source): \"\(name.benchmarkModel)\"")
                            Spacer()
                            Menu("Map to…") {
                                ForEach(knownModels, id: \.self) { m in
                                    Button(IndexKeys.label(m)) {
                                        service.mapAlias(source: name.source, benchmarkModel: name.benchmarkModel, to: m)
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }

    private var unmappedWithoutEntry: [UnmappedName] {
        (service.current?.unmapped ?? []).filter {
            service.config.aliases.entry(source: $0.source, benchmarkModel: $0.benchmarkModel) == nil
        }
    }

    private var knownModels: [ModelRef] {
        var seen: [ModelRef] = []
        for m in service.knownCatalogs.enabledModels + service.scores.map(\.model) where !seen.contains(m) { seen.append(m) }
        return seen
    }

    // MARK: Hand-entered scores

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Hand-entered scores").font(.headline)
                Spacer()
                Button("Add…") {
                    editing = ManualDraft(entry: ManualModelScores(model: ModelRef(harness: "opencode", model: ""), dimensions: [:]),
                                          original: nil)
                }
                .accessibilityIdentifier("index-manual-add")
            }
            Text("For local models no benchmark lists. A hand-entered score has confidence 1. Inheriting copies a base model's scores at a discount (0.85 by default).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(service.config.manual.enumerated()), id: \.offset) { _, m in
                HStack {
                    Text(IndexKeys.label(m.model))
                    if let base = m.inheritFrom {
                        Text("inherits \(IndexKeys.label(base)) × \(String(format: "%.2f", m.discount))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { editing = ManualDraft(entry: m, original: m.model) }
                    Button { service.removeManual(m.model) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: Refresh agent

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Refresh agent").font(.headline)
            HStack {
                TextField("Model", text: Binding(get: { service.config.agent.model },
                                                 set: { var a = service.config.agent; a.model = $0; service.setAgent(a) }))
                    .frame(width: 160)
                Picker("Effort", selection: Binding(get: { service.config.agent.effort },
                                                    set: { var a = service.config.agent; a.effort = $0; service.setAgent(a) })) {
                    ForEach(["low", "medium", "high"], id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 180)
                TextField("Token cap", value: Binding(get: { service.config.agent.tokenCap },
                                                      set: { var a = service.config.agent; a.tokenCap = max(0, $0); service.setAgent(a) }),
                          format: .number)
                    .frame(width: 120)
            }
            Text("Runs claude -p with web search and fetch only, once per enabled source. Sources left when the token cap is reached keep their previous values and are marked stale.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Log

    @ViewBuilder private var logSection: some View {
        if !service.lastLog.isEmpty {
            DisclosureGroup("Last refresh log") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(service.lastLog.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: Citations

    private func citationsSheet(_ cell: CellSelection) -> some View {
        let score = service.scores.first { $0.model == cell.model }?.dimensions[cell.dimension]
        let rows = service.citations(model: cell.model, dimension: cell.dimension)
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(IndexKeys.label(cell.model)) — \(cell.dimension)").font(.headline)
            Text(Self.cellValue(score)).foregroundStyle(.secondary)
            if rows.isEmpty {
                Text(score?.origin == .computed ? "No cited rows remain for this score."
                                                : "Entered by hand or inherited; no benchmark row stands behind it.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(c.sourceName): \"\(c.benchmarkModel)\" \(c.quotedFigure)\(c.stale ? " (stale)" : "")")
                        Text(c.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("index-citation-url")
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { selectedCell = nil }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("index-citations-done")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: Pure helpers (tested in CapabilityIndexPaneTests)

    static func cellIdentifier(model: ModelRef, dimension: String) -> String {
        "index-cell-\(IndexKeys.key(model))-\(dimension)"
    }

    static func cellValue(_ s: DimensionScore?) -> String {
        guard let s else { return "unknown" }
        let origin: String
        switch s.origin {
        case .computed: origin = "computed"
        case .manual: origin = "manual"
        case .inherited: origin = "inherited from \(s.inheritedFrom.map(IndexKeys.label) ?? "another model")"
        }
        return String(format: "%.2f, confidence %.2f, ", s.score, s.confidence) + origin
    }

    /// Never fully transparent: a low-confidence score must still be visibly a score, not a gap.
    static func cellOpacity(confidence: Double) -> Double { 0.2 + 0.8 * max(0, min(1, confidence)) }

    static func color(for score: Double) -> Color {
        Color(hue: 0.33 * max(0, min(1, score)), saturation: 0.65, brightness: 0.85)
    }

    static func originMark(_ origin: ScoreOrigin) -> String {
        switch origin {
        case .computed: ""
        case .manual: " M"
        case .inherited: " I"
        }
    }

    static func describe(_ c: ScoreChange) -> String {
        let name = "\(IndexKeys.label(c.model)) — \(c.dimension)"
        switch (c.before, c.after) {
        case let (b?, a?): return name + String(format: " %.2f → %.2f (%+.2f)", b, a, a - b)
        case let (nil, a?): return name + String(format: " new %.2f", a)
        case let (b?, nil): return name + String(format: " %.2f → unknown", b)
        case (nil, nil): return name
        }
    }

    static func utc(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return f.string(from: date)
    }

    static func shortName(_ dimension: String) -> String {
        [
            "agentic-coding": "Agentic", "algorithmic-reasoning": "Algo", "test-authoring": "Tests",
            "frontend-ui": "UI", "large-context-refactor": "Refactor", "debugging": "Debug", "docs-prose": "Docs",
            "tool-use-reliability": "Tools", "speed": "Speed", "cost-efficiency": "Cost",
        ][dimension] ?? dimension
    }
}

/// Adds or edits one model's hand-entered scores. A blank or out-of-range field is no score —
/// never zero — for the same reason the index never turns unknown into zero.
struct ManualScoresEditor: View {
    let knownModels: [ModelRef]
    let save: (ManualModelScores) -> Void
    private let knobs: [String: String]
    @Environment(\.dismiss) private var dismiss
    @State private var harness: String
    @State private var model: String
    @State private var texts: [String: String]
    @State private var inherit: ModelRef?
    @State private var discount: Double

    init(entry: ManualModelScores, knownModels: [ModelRef], save: @escaping (ManualModelScores) -> Void) {
        self.knownModels = knownModels
        self.save = save
        self.knobs = entry.model.knobs
        _harness = State(initialValue: entry.model.harness.rawValue)
        _model = State(initialValue: entry.model.model)
        _texts = State(initialValue: entry.dimensions.mapValues { String(format: "%.2f", $0) })
        _inherit = State(initialValue: entry.inheritFrom)
        _discount = State(initialValue: entry.discount)
    }

    var body: some View {
        Form {
            TextField("Harness", text: $harness)
            TextField("Model", text: $model)
            Picker("Inherit from", selection: $inherit) {
                Text("Nothing").tag(ModelRef?.none)
                ForEach(knownModels, id: \.self) { Text(IndexKeys.label($0)).tag(ModelRef?.some($0)) }
            }
            TextField("Discount", value: $discount, format: .number)
            Section("Scores (0 to 1, blank for none)") {
                ForEach(Dimensions.all, id: \.id) { d in
                    TextField(d.id, text: Binding(get: { texts[d.id] ?? "" }, set: { texts[d.id] = $0 }))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    save(ManualModelScores(model: ModelRef(harness: HarnessID(trimmed(harness)), model: trimmed(model), knobs: knobs),
                                           dimensions: Self.parse(texts), inheritFrom: inherit, discount: discount))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed(harness).isEmpty || trimmed(model).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    static func parse(_ texts: [String: String]) -> [String: Double] {
        var out: [String: Double] = [:]
        for (d, t) in texts {
            if let v = Double(t.trimmingCharacters(in: .whitespaces)), (0...1).contains(v) { out[d] = v }
        }
        return out
    }
}
```

The test asserts `parse` keeps `"x": "abc"` out because it does not parse; an unknown dimension
key that DOES parse would be kept here and dropped later by `CapabilityScoring.handEntered`,
which filters on `Dimensions.isKnown` — the editor only ever offers known dimensions anyway.

- [ ] **Step 7: Add the tab to `PreferencesView.swift`**

Replace

```swift
            DevicesSettingsTab(preferences: preferences, service: fleet)
                .tabItem { Label("Devices", systemImage: "iphone.and.arrow.forward") }
                .accessibilityIdentifier("prefs-devices")
                .tag(PreferencesTab.devices)
        }
```

with

```swift
            DevicesSettingsTab(preferences: preferences, service: fleet)
                .tabItem { Label("Devices", systemImage: "iphone.and.arrow.forward") }
                .accessibilityIdentifier("prefs-devices")
                .tag(PreferencesTab.devices)

            CapabilityIndexSettingsTab(index: sessions.capabilityIndexService)
                .tabItem { Label("Flight Control", systemImage: "airplane") }
                .accessibilityIdentifier("prefs-flight-control")
                .tag(PreferencesTab.capabilityIndex)
        }
```

- [ ] **Step 8: Add the two members to `SessionStore.swift`**

Replace

```swift
    private var intakeChangeForward: AnyCancellable?
```

with

```swift
    private var intakeChangeForward: AnyCancellable?

    /// The capability index (Flight Control L3-I), built and scheduled by `FlightDeckApp.makeStore`
    /// right after this store. Nil in every store a test builds, so no test can start a refresh
    /// that spends tokens.
    var capabilityIndexService: CapabilityIndexService?

    /// The shared poll clock, for services built after the store (the capability index's weekly
    /// check). A second `WatchClock` would be a second wakeup source — the thing it exists to avoid.
    var watchClock: WatchClock { clock }
```

- [ ] **Step 9: Build the service in `FlightDeckApp.makeStore`**

In `Sources/FlightDeck/FlightDeckApp.swift`, replace

```swift
        if resetState, Self.isSeedingSecondProject {
```

with

```swift
        store.capabilityIndexService = Self.makeCapabilityIndexService(store: store, resetState: resetState)

        if resetState, Self.isSeedingSecondProject {
```

and add this method directly after `makeStore`'s closing brace:

```swift
    /// The capability index. A UITest reset run gets a scratch directory — seeded from
    /// `-FlightDeckCapabilityIndexFixture <dir>` when given, copied so a rollback in the test
    /// never edits the fixture in the repo — and is NEVER scheduled, so no UI test can start a
    /// refresh that spends tokens. A real launch uses `<state dir>/capability-index`, which
    /// already differs between Debug and Release builds.
    @MainActor
    private static func makeCapabilityIndexService(store: SessionStore, resetState: Bool) -> CapabilityIndexService {
        if resetState {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("FlightDeck-capability-index-\(UUID().uuidString)", isDirectory: true)
            if let path = UserDefaults.standard.string(forKey: "FlightDeckCapabilityIndexFixture"), !path.isEmpty {
                try? FileManager.default.copyItem(at: URL(fileURLWithPath: path, isDirectory: true), to: scratch)
            }
            return CapabilityIndexService(directory: scratch)
        }
        let root = Self.stateDirectory() ?? FileSessionPersistence.defaultDirectory()
        let service = CapabilityIndexService(
            directory: CapabilityIndexService.directory(stateRoot: root),
            // Every registered harness. Until L3-R fills `modelCatalog()` these are the L3-0
            // stubs' empty catalogs, so a refresh proposes no aliases before integration.
            catalogs: { await RoutingCapabilityRegistry.standard().catalogs(enabled: Set(AgentID.allCases.map(\.harnessID))) })
        service.startScheduling(clock: store.watchClock)
        return service
    }
```

- [ ] **Step 10: Run to verify it passes**

Run: `FD_TEST_FILTER=CapabilityIndexPaneTests,PreferencesTabTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -30`
Expected: `** SHARDED UNIT RUN PASSED` and no `error:` lines. A `TerminologyGuardTests` failure
naming one of this task's files means a literal says "seat", "bead" or "flywheel": reword it.

- [ ] **Step 11: Build the app**

Run: `./scripts/build.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. Do not launch the product.

- [ ] **Step 12: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/CapabilityIndexPane.swift Sources/FlightDeck/Preferences/UI/CapabilityIndexSettingsTab.swift Sources/FlightDeck/Preferences/PreferencesTab.swift Sources/FlightDeck/Preferences/UI/PreferencesView.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/FlightDeckApp.swift Tests/FlightDeckTests/FlightControlL3/Index/CapabilityIndexPaneTests.swift
git commit -m "feat: show the capability index in settings with citations, diff and one-click rollback" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: UI fixtures and the XCUITest — heatmap, citations, diff, rollback

**Files:**
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/ui/2026-09-27T060000Z.json`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/ui/2026-10-04T060000Z.json`
- Create: `Tests/FlightDeckTests/FlightControlL3/Index/IndexUIFixtureTests.swift`
- Create: `UITests/FlightDeckUITests/CapabilityIndexUITests.swift`

**Interfaces:**
- Consumes: Task 12's identifiers and `-FlightDeckCapabilityIndexFixture`; `IndexSnapshotStore`, `SnapshotDiff`, `IndexSnapshot.assemble` (Tasks 5, 8).
- Produces: two fixture snapshots — older: `codex/gpt-6-sol[effort=high]` test-authoring 0.60, `claude/opus[effort=high]` 0.80; newer: 0.80 and 0.60, with `terminal-bench` stale ("token cap reached"). The diff between them is exactly those two rows.

- [ ] **Step 1: Write the failing fixture check (headless; catches a broken fixture before the GUI run)**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The UI test steals the screen for a minute, so its fixture is proven sound here first:
/// both snapshots decode, the newer is current, their stored scores are exactly what the
/// scorer computes from their rows (so the heatmap shows real arithmetic), the diff is the two
/// rows the UI test expects, and the cell it clicks has a citation.
final class IndexUIFixtureTests: XCTestCase {
    func testUIFixtureSnapshotsAreSoundAndDiffAsTheUITestExpects() throws {
        let copy = IndexFixtures.scratch()
        try FileManager.default.copyItem(at: try IndexFixtures.uiDirectory(), to: copy)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy) }
        let store = IndexSnapshotStore(directory: copy)

        let current = try XCTUnwrap(store.current())
        XCTAssertEqual(current.ref.stamp, "2026-10-04T060000Z")
        let previous = try XCTUnwrap(store.previous(before: current.ref))
        XCTAssertEqual(previous.ref.stamp, "2026-09-27T060000Z")

        for snap in [current.snapshot, previous.snapshot] {
            let recomputed = IndexSnapshot.assemble(results: snap.sources, sources: IndexSourceRegistry.initial,
                                                    aliases: AliasTable(entries: snap.aliases), createdAt: snap.createdAt)
            XCTAssertEqual(recomputed.scores, snap.scores, "stored scores must be what the scorer computes")
            XCTAssertEqual(recomputed.unmapped, snap.unmapped)
        }

        let changes = SnapshotDiff.changes(from: previous.snapshot, to: current.snapshot)
        XCTAssertEqual(changes.map(CapabilityIndexPane.describe), [
            "claude · opus (effort high) — test-authoring 0.80 → 0.60 (-0.20)",
            "codex · gpt-6-sol (effort high) — test-authoring 0.60 → 0.80 (+0.20)"])

        let cited = CapabilityScoring.citations(for: IndexFixtures.sol, dimension: "test-authoring",
                                                snapshot: current.snapshot, sources: IndexSourceRegistry.initial)
        XCTAssertEqual(cited.map(\.url), ["https://swtbench.com/"])
        XCTAssertEqual(current.snapshot.sources.first { $0.sourceID == "terminal-bench" }?.stale, true)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=IndexUIFixtureTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: the test fails with `missing fixture folder ui` (no fixture files yet).

- [ ] **Step 3: Write the older fixture snapshot**

`ui/2026-09-27T060000Z.json` (scores are what `IndexSnapshot.assemble` computes from these rows
under the initial registry — `IndexUIFixtureTests` checks that):

```json
{
  "v": 1,
  "createdAt": "2026-09-27T06:00:00Z",
  "sources": [
    {"sourceID": "swt-bench", "stale": false, "refreshedAt": "2026-09-27T06:00:00Z", "tokens": 12000, "rejected": [], "rows": [
      {"benchmarkModel": "Model A", "score": 30.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "30.0%"},
      {"benchmarkModel": "Model B", "score": 35.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "35.0%"},
      {"benchmarkModel": "Model C", "score": 38.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "38.0%"},
      {"benchmarkModel": "GPT-6 Sol (high)", "score": 41.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "41.0%"},
      {"benchmarkModel": "Opus 5 (high)", "score": 45.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "45.0%"},
      {"benchmarkModel": "Model D", "score": 50.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "50.0%"}]},
    {"sourceID": "terminal-bench", "stale": false, "refreshedAt": "2026-09-27T06:00:00Z", "tokens": 15000, "rejected": [], "rows": [
      {"benchmarkModel": "GPT-6 Sol (high)", "score": 55.0, "unit": "percent", "url": "https://www.tbench.ai/leaderboard", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "55.0%"},
      {"benchmarkModel": "Opus 5 (high)", "score": 58.0, "unit": "percent", "url": "https://www.tbench.ai/leaderboard", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "58.0%"},
      {"benchmarkModel": "Sonnet 5", "score": 40.0, "unit": "percent", "url": "https://www.tbench.ai/leaderboard", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "40.0%"}]}
  ],
  "aliases": [
    {"source": "swt-bench", "benchmarkModel": "GPT-6 Sol (high)", "status": "confirmed", "model": {"harness": "codex", "model": "gpt-6-sol", "knobs": {"effort": "high"}}},
    {"source": "swt-bench", "benchmarkModel": "Opus 5 (high)", "status": "confirmed", "model": {"harness": "claude", "model": "opus", "knobs": {"effort": "high"}}},
    {"source": "terminal-bench", "benchmarkModel": "GPT-6 Sol (high)", "status": "confirmed", "model": {"harness": "codex", "model": "gpt-6-sol", "knobs": {"effort": "high"}}},
    {"source": "terminal-bench", "benchmarkModel": "Opus 5 (high)", "status": "confirmed", "model": {"harness": "claude", "model": "opus", "knobs": {"effort": "high"}}},
    {"source": "terminal-bench", "benchmarkModel": "Sonnet 5", "status": "confirmed", "model": {"harness": "claude", "model": "sonnet", "knobs": {}}}
  ],
  "scores": [
    {"model": {"harness": "claude", "model": "opus", "knobs": {"effort": "high"}}, "dimensions": {
      "test-authoring": {"score": 0.8, "confidence": 1.0, "origin": "computed", "sources": ["swt-bench"]},
      "tool-use-reliability": {"score": 1.0, "confidence": 1.0, "origin": "computed", "sources": ["terminal-bench"]},
      "agentic-coding": {"score": 1.0, "confidence": 0.16666666666666666, "origin": "computed", "sources": ["terminal-bench"]}}},
    {"model": {"harness": "claude", "model": "sonnet", "knobs": {}}, "dimensions": {
      "tool-use-reliability": {"score": 0.0, "confidence": 1.0, "origin": "computed", "sources": ["terminal-bench"]},
      "agentic-coding": {"score": 0.0, "confidence": 0.16666666666666666, "origin": "computed", "sources": ["terminal-bench"]}}},
    {"model": {"harness": "codex", "model": "gpt-6-sol", "knobs": {"effort": "high"}}, "dimensions": {
      "test-authoring": {"score": 0.6, "confidence": 1.0, "origin": "computed", "sources": ["swt-bench"]},
      "tool-use-reliability": {"score": 0.5, "confidence": 1.0, "origin": "computed", "sources": ["terminal-bench"]},
      "agentic-coding": {"score": 0.5, "confidence": 0.16666666666666666, "origin": "computed", "sources": ["terminal-bench"]}}}
  ],
  "unmapped": [
    {"source": "swt-bench", "benchmarkModel": "Model A"},
    {"source": "swt-bench", "benchmarkModel": "Model B"},
    {"source": "swt-bench", "benchmarkModel": "Model C"},
    {"source": "swt-bench", "benchmarkModel": "Model D"}
  ]
}
```

- [ ] **Step 4: Write the newer fixture snapshot**

`ui/2026-10-04T060000Z.json` — identical to the older file except: `createdAt` is
`"2026-10-04T06:00:00Z"`; in `swt-bench` the `refreshedAt` and every row's `retrievedAt` are
`"2026-10-04T06:00:00Z"`, and the `GPT-6 Sol (high)` row is now
`{"benchmarkModel": "GPT-6 Sol (high)", "score": 47.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-10-04T06:00:00Z", "quotedFigure": "47.0%"}`
placed after the `Opus 5 (high)` row; `terminal-bench` keeps its rows and `refreshedAt`
(`2026-09-27`) but has `"stale": true, "error": "token cap reached", "tokens": 0`; and the two
`test-authoring` scores swap: opus `0.6`, sol `0.8`. Written out in full:

```json
{
  "v": 1,
  "createdAt": "2026-10-04T06:00:00Z",
  "sources": [
    {"sourceID": "swt-bench", "stale": false, "refreshedAt": "2026-10-04T06:00:00Z", "tokens": 12500, "rejected": [], "rows": [
      {"benchmarkModel": "Model A", "score": 30.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-10-04T06:00:00Z", "quotedFigure": "30.0%"},
      {"benchmarkModel": "Model B", "score": 35.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-10-04T06:00:00Z", "quotedFigure": "35.0%"},
      {"benchmarkModel": "Model C", "score": 38.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-10-04T06:00:00Z", "quotedFigure": "38.0%"},
      {"benchmarkModel": "Opus 5 (high)", "score": 45.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-10-04T06:00:00Z", "quotedFigure": "45.0%"},
      {"benchmarkModel": "GPT-6 Sol (high)", "score": 47.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-10-04T06:00:00Z", "quotedFigure": "47.0%"},
      {"benchmarkModel": "Model D", "score": 50.0, "unit": "percent", "url": "https://swtbench.com/", "retrievedAt": "2026-10-04T06:00:00Z", "quotedFigure": "50.0%"}]},
    {"sourceID": "terminal-bench", "stale": true, "error": "token cap reached", "refreshedAt": "2026-09-27T06:00:00Z", "tokens": 0, "rejected": [], "rows": [
      {"benchmarkModel": "GPT-6 Sol (high)", "score": 55.0, "unit": "percent", "url": "https://www.tbench.ai/leaderboard", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "55.0%"},
      {"benchmarkModel": "Opus 5 (high)", "score": 58.0, "unit": "percent", "url": "https://www.tbench.ai/leaderboard", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "58.0%"},
      {"benchmarkModel": "Sonnet 5", "score": 40.0, "unit": "percent", "url": "https://www.tbench.ai/leaderboard", "retrievedAt": "2026-09-27T06:00:00Z", "quotedFigure": "40.0%"}]}
  ],
  "aliases": [
    {"source": "swt-bench", "benchmarkModel": "GPT-6 Sol (high)", "status": "confirmed", "model": {"harness": "codex", "model": "gpt-6-sol", "knobs": {"effort": "high"}}},
    {"source": "swt-bench", "benchmarkModel": "Opus 5 (high)", "status": "confirmed", "model": {"harness": "claude", "model": "opus", "knobs": {"effort": "high"}}},
    {"source": "terminal-bench", "benchmarkModel": "GPT-6 Sol (high)", "status": "confirmed", "model": {"harness": "codex", "model": "gpt-6-sol", "knobs": {"effort": "high"}}},
    {"source": "terminal-bench", "benchmarkModel": "Opus 5 (high)", "status": "confirmed", "model": {"harness": "claude", "model": "opus", "knobs": {"effort": "high"}}},
    {"source": "terminal-bench", "benchmarkModel": "Sonnet 5", "status": "confirmed", "model": {"harness": "claude", "model": "sonnet", "knobs": {}}}
  ],
  "scores": [
    {"model": {"harness": "claude", "model": "opus", "knobs": {"effort": "high"}}, "dimensions": {
      "test-authoring": {"score": 0.6, "confidence": 1.0, "origin": "computed", "sources": ["swt-bench"]},
      "tool-use-reliability": {"score": 1.0, "confidence": 1.0, "origin": "computed", "sources": ["terminal-bench"]},
      "agentic-coding": {"score": 1.0, "confidence": 0.16666666666666666, "origin": "computed", "sources": ["terminal-bench"]}}},
    {"model": {"harness": "claude", "model": "sonnet", "knobs": {}}, "dimensions": {
      "tool-use-reliability": {"score": 0.0, "confidence": 1.0, "origin": "computed", "sources": ["terminal-bench"]},
      "agentic-coding": {"score": 0.0, "confidence": 0.16666666666666666, "origin": "computed", "sources": ["terminal-bench"]}}},
    {"model": {"harness": "codex", "model": "gpt-6-sol", "knobs": {"effort": "high"}}, "dimensions": {
      "test-authoring": {"score": 0.8, "confidence": 1.0, "origin": "computed", "sources": ["swt-bench"]},
      "tool-use-reliability": {"score": 0.5, "confidence": 1.0, "origin": "computed", "sources": ["terminal-bench"]},
      "agentic-coding": {"score": 0.5, "confidence": 0.16666666666666666, "origin": "computed", "sources": ["terminal-bench"]}}}
  ],
  "unmapped": [
    {"source": "swt-bench", "benchmarkModel": "Model A"},
    {"source": "swt-bench", "benchmarkModel": "Model B"},
    {"source": "swt-bench", "benchmarkModel": "Model C"},
    {"source": "swt-bench", "benchmarkModel": "Model D"}
  ]
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=IndexUIFixtureTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`. If the recompute assertion fails on a confidence in the last
digit, the stored literal must be `0.16666666666666666` exactly (0.5 ÷ 3.0); fix the fixture, not the
assertion.

- [ ] **Step 6: Write `CapabilityIndexUITests.swift`**

```swift
import XCTest

/// Drives Settings → Flight Control → Capability index against two fixture snapshots and keeps
/// a screenshot of each state. Not part of `scripts/smoke.sh`; run on its own (plan Task 13
/// gives the command). Hermetic: `-FlightDeckResetState YES` gives the app nil persistence, and
/// `-FlightDeckCapabilityIndexFixture` makes it COPY the fixture into a scratch directory, so the
/// rollback below never edits the repo — and a reset run never schedules a refresh, so nothing
/// spends tokens. The runner only passes the fixture's path; it never reads the folder itself
/// (the xctrunner sandbox cannot reach the repo; see ScreenshotTests).
final class CapabilityIndexUITests: XCTestCase {
    private var fixturePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // UITests/FlightDeckUITests
            .deletingLastPathComponent()   // UITests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/ui", isDirectory: true).path
    }

    private func preferencesWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.containing(.button, identifier: "Agents").firstMatch
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: preferencesWindow(app).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testHeatmapCitationsDiffAndRollback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-FlightDeckResetState", "YES",
                                "-FlightDeckCapabilityIndexFixture", fixturePath]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "no window appeared")

        app.typeKey(",", modifierFlags: .command)
        let prefs = preferencesWindow(app)
        XCTAssertTrue(prefs.waitForExistence(timeout: 10), "Settings never opened")
        prefs.buttons["Flight Control"].click()

        let heatmap = prefs.descendants(matching: .any)["index-heatmap"]
        XCTAssertTrue(heatmap.waitForExistence(timeout: 10), "the capability index pane never appeared")
        let header = prefs.descendants(matching: .any)["index-last-refresh"]
        XCTAssertTrue(header.label.contains("2026-10-04 06:00 UTC"), "current snapshot should be the newer fixture: \(header.label)")

        let cell = prefs.descendants(matching: .any)["index-cell-codex/gpt-6-sol[effort=high]-test-authoring"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        XCTAssertTrue(cell.label.hasPrefix("0.80"), "cell label: \(cell.label)")
        shoot(app, "1-heatmap")

        cell.click()
        let citation = app.descendants(matching: .any)["index-citation-url"].firstMatch
        XCTAssertTrue(citation.waitForExistence(timeout: 5), "clicking a cell must show its cited rows")
        shoot(app, "2-citations")
        app.descendants(matching: .any)["index-citations-done"].firstMatch.click()

        let diffRow = prefs.descendants(matching: .any).matching(identifier: "index-diff-row").firstMatch
        XCTAssertTrue(diffRow.waitForExistence(timeout: 5), "the diff against the previous snapshot is missing")
        shoot(app, "3-diff")

        prefs.descendants(matching: .any)["index-rollback"].firstMatch.click()
        let rolledBack = expectation(for: NSPredicate(format: "label CONTAINS %@", "2026-09-27 06:00 UTC"),
                                     evaluatedWith: header)
        wait(for: [rolledBack], timeout: 10)
        XCTAssertTrue(cell.label.hasPrefix("0.60"), "after rollback the cell shows the older score: \(cell.label)")
        shoot(app, "4-after-rollback")
    }
}
```

- [ ] **Step 7: Verify the Settings tab is reachable as written (read-only)**

Run: `rg -n 'buttons\["|preferencesWindow' UITests/FlightDeckUITests/TerminalSmokeTests.swift | head`
Expected: tabs are reached as buttons named by their label (the helper matches the "Agents"
button). If the existing suite reaches tabs some other way (`toolbars.buttons[...]`,
`radioButtons[...]`), use that form for "Flight Control" in Step 6.

- [ ] **Step 8: Run the UI test once (it takes the foreground for about a minute — do not loop it)**

Warn the maintainer first if he is at the machine (the run steals keyboard focus). Then:

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  test -only-testing:FlightDeckUITests/CapabilityIndexUITests > /tmp/l3-i-ui.log 2>&1; echo "rc=$?"
rg -n "Test Case '.*' (passed|failed)|error:|\*\* TEST (SUCCEEDED|FAILED)" /tmp/l3-i-ui.log | tail -20
```

Expected: `rc=0`, `Test Case '-[FlightDeckUITests.CapabilityIndexUITests testHeatmapCitationsDiffAndRollback]' passed`, `** TEST SUCCEEDED **`.
Per outcome:
- `the capability index pane never appeared` with a pane saying "not running in this window": the service was not built — check Task 12 Step 9's insertion ran before the Settings scene.
- `cell label:` shows `unknown`: the fixture did not load — confirm the launch argument name matches `FlightDeckCapabilityIndexFixture` in both files.
- A failure caused by typing elsewhere during the run is not a code failure; rerun once, with the machine idle. Never loop it.

- [ ] **Step 9: Extract and look at the screenshots**

```bash
RESULT=$(ls -td DerivedData/Logs/Test/*.xcresult | head -1)
mkdir -p /tmp/l3-i-shots
xcrun xcresulttool export attachments --path "$RESULT" --output-path /tmp/l3-i-shots
ls /tmp/l3-i-shots
```

Expected: four PNGs named from `1-heatmap` … `4-after-rollback` (plus a `manifest.json`). If
`export attachments` is not a subcommand on this Xcode, run `xcrun xcresulttool help export`
and use the attachment export form it lists. Open each PNG with the Read tool and check: the
heatmap's sol test-authoring cell reads 0.80 and is strong (confidence 1); the agentic-coding
cells are faint (confidence 0.17); the citation sheet lists `https://swtbench.com/`; the diff
shows the two rows; after rollback the header says 2026-09-27 and Roll back is disabled.

- [ ] **Step 10: Commit**

```bash
git add Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/ui Tests/FlightDeckTests/FlightControlL3/Index/IndexUIFixtureTests.swift UITests/FlightDeckUITests/CapabilityIndexUITests.swift
git commit -m "test: drive the capability index heatmap, citations, diff and rollback against fixture snapshots" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: The live probe (skipped by default; spends real tokens)

**Files:**
- Create: `Tests/FlightDeckTests/FlightControlL3/Index/IndexLiveProbeTests.swift`

**Interfaces:**
- Consumes: `IndexRefreshRunner` with the real `SystemHeadlessRunner` (Task 10), `IndexSourceRegistry.initial` (Task 1).
- Produces: nothing new; it is the only check that the command, flags, schema and validator work against a real `claude` and a real page.

- [ ] **Step 1: Write the probe**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// One real refresh of one real source. Everything else in this branch runs against recorded
/// answers; this is the check that `--restricted` still lets WebFetch through when `--tools`
/// names it, that the schema-bound answer parses, and that a real page's rows pass the
/// citation rules. Spends real tokens — skipped unless `INDEX_LIVE=1` (or
/// `TEST_RUNNER_INDEX_LIVE=1`). Never loop it.
final class IndexLiveProbeTests: XCTestCase {
    func testOneRealSourceYieldsCitedRows() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["INDEX_LIVE"] == "1" || env["TEST_RUNNER_INDEX_LIVE"] == "1" else {
            throw XCTSkip("set INDEX_LIVE=1 to run; it spends real tokens")
        }
        // A data file, so the probe tests the pipeline rather than one site's page layout.
        let source = try XCTUnwrap(IndexSourceRegistry.initial.first { $0.id == "aider-polyglot" })
        let work = IndexFixtures.scratch()
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let plan = IndexRefreshPlan(sources: [source], aliases: AliasTable(), catalogs: IndexFixtures.catalogs(),
                                    agent: IndexAgentSettings(model: "sonnet", effort: "low", tokenCap: 400_000),
                                    previous: nil, workDirectory: work)
        let outcome = await IndexRefreshRunner().refresh(plan)
        print(outcome.log.joined(separator: "\n"))
        let result = try XCTUnwrap(outcome.snapshot.sources.first)
        XCTAssertFalse(result.stale, "the live run failed: \(result.error ?? "?")")
        XCTAssertGreaterThan(result.rows.count, 5)
        for row in result.rows {
            XCTAssertTrue(row.url.hasPrefix("http"), row.benchmarkModel)
            XCTAssertTrue(ExtractionValidator.figureMatches(row.quotedFigure, score: row.score), row.benchmarkModel)
        }
        XCTAssertGreaterThan(outcome.tokensUsed, 0)
    }
}
```

- [ ] **Step 2: Run it skipped (the default)**

Run: `FD_TEST_FILTER=IndexLiveProbeTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED` with the test skipped.

- [ ] **Step 3: Run it live, once**

Run: `INDEX_LIVE=1 FD_TEST_FILTER=IndexLiveProbeTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: passed, not skipped (`Executed 1 test, with 0 failures`, no "skipped"), and the
printed log shows `aider-polyglot: N rows, T tokens`. Per outcome:
- Still skipped: `test-unit.sh` did not forward the variable; use `TEST_RUNNER_INDEX_LIVE=1`.
- `claude exited …` mentioning WebFetch or permissions: `--restricted` no longer keeps a tool `--tools` names. Re-read `claude --help` for `--restricted`, adjust `IndexExtraction.command`, re-run Task 9's tests, then this probe once.
- Rows rejected for figure mismatch: read the log lines, tighten that source's `howToRead` (Task 1's registry), and re-run once.
Record the outcome (rows, tokens, claude version from `claude --version`) for Task 15's notes.

- [ ] **Step 4: Commit**

```bash
git add Tests/FlightDeckTests/FlightControlL3/Index/IndexLiveProbeTests.swift
git commit -m "test: add a live capability index probe behind INDEX_LIVE" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Full suite, spec as built, FOLLOWUPS, vendor check

**Files:**
- Modify: `docs/superpowers/specs/2026-10-04-flight-control-l3-capability-index-design.md` (append §12)
- Modify: `docs/FOLLOWUPS.md` (the "Level 3 'Operate'" entry)

- [ ] **Step 1: Run every class this branch added, then the whole unit suite**

Run: `FD_TEST_FILTER=IndexSourceRegistryTests,ExtractionValidatorTests,AliasTableTests,IndexSnapshotCodingTests,CapabilityScoringTests,CapabilityRankTests,CapabilityHintsTests,IndexSnapshotStoreTests,IndexExtractionTests,IndexRefreshRunnerTests,CapabilityIndexServiceTests,CapabilityIndexPaneTests,IndexUIFixtureTests,IndexLiveProbeTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.
Run: `./scripts/test-unit.sh 2>&1 | tee /tmp/l3-i-unit.log | tail -5; rg -n "error:" /tmp/l3-i-unit.log | head`
Expected: `** SHARDED UNIT RUN PASSED` and no `error:` lines. A failure in a test this branch did not
touch: run that class alone on master (`git stash` is forbidden — use a clean worktree of
master) before blaming this branch.

- [ ] **Step 2: Record the build as built in the spec**

Append to `docs/superpowers/specs/2026-10-04-flight-control-l3-capability-index-design.md`:

```markdown
## 12. As built (plan `2026-10-04-flight-control-l3-i-capability-index.md`)

- **Snapshot names** are a UTC date-time stamp, `capability-index/2026-10-04T060000Z.json`, not a bare date: two snapshots a day must not overwrite each other, and a timezone change must not reorder them. A write never sorts before an existing snapshot, even after the clock moves back.
- **Rollback** renames the current file to `<stamp>.rolledback.json`; the newest valid snapshot stays the only definition of current.
- **Snapshots hold computed scores only.** Hand-entered and inherited scores are overlaid live from `capability-index/config.json`. Precedence per dimension: manual > computed > inherited; inheritance is one level.
- **Confirming, rejecting or editing an alias** rescoring writes a new snapshot from the current rows (no agent run), so it can be rolled back.
- **One source = one metric in one unit.** The speed and price tracker is two sources; vendor model cards feed context windows only. SWT-bench was added for `test-authoring`. `docs-prose` has no source and stays unknown unless entered by hand. Machine-readable as probed on 2026-10-04: SWE-bench Verified (JSON) and Aider Polyglot (YAML); the rest are pages.
- **A benchmark with fewer than two rows contributes nothing.** Unmapped names still count in a benchmark's percentile population. Two names mapped to one model in one source keep the better row.
- **`rank`:** a candidate without knobs matches every scored knob variant of its model and returns the best one, knobs included.
- **The refresh agent is claude only** (`-p`, tools exactly WebSearch and WebFetch, `--restricted`, `--strict-mcp-config`, `dontAsk`); model, effort and the token cap (default 1,500,000) are settings. A source that returns only rejected rows counts as failed.
- **The first refresh is manual**; the weekly check (on the shared `WatchClock`) starts after the first attempt, and every attempt is recorded so a failing run waits a week.
- **Rule hints** are `hints(for:assigned:candidates:) -> [CapabilityHint]` on `SnapshotCapabilityIndex`, `LiveCapabilityIndex` and `CapabilityIndexService`; L3-R calls it at integration. Only the rule's dimension keys are compared.
- **Integration hands L3-R `SessionStore.capabilityIndexService?.live`** as its `CapabilityIndex`. Until L3-R fills `modelCatalog()`, refreshes see empty catalogs and propose no aliases.
- **Settings:** a temporary top-level `PreferencesTab.capabilityIndex` / `CapabilityIndexSettingsTab`; integration moves `CapabilityIndexPane` into L3-R's `FlightControlSettingsTab` and deletes the temporary tab.
```

Then add one final bullet to that section, written from what Task 14 Step 3 recorded: the
date, the output of `claude --version`, the number of rows accepted and the tokens used —
or, if the live probe was not run, the words "Live probe not run" and the reason.

Then in §11 Files, add `CapabilityHints.swift`, `IndexSnapshotStore.swift`, `IndexSources.swift`,
`IndexExtraction.swift` to the IntakeKit line and `CapabilityIndexSettingsTab.swift` to the UI line.

- [ ] **Step 3: Update FOLLOWUPS**

In `docs/FOLLOWUPS.md`, in the "**Level 3 "Operate" — DESIGNED (2026-10-04), not built.**" entry,
add directly after its first paragraph:

```markdown
  - **L3-I capability index — built** on its own branch (2026-10-04 plan
    `superpowers/plans/2026-10-04-flight-control-l3-i-capability-index.md`), not merged.
    Pure scoring/validation/storage in `Sources/IntakeKit/FlightControl/`, service and runner in
    `Sources/FlightDeck/FlightControl/`, pane under Settings → Flight Control. Open for
    integration: hand `capabilityIndexService.live` to L3-R's router and its `hints(for:…)` to
    L3-R's rule list; move `CapabilityIndexPane` into L3-R's `FlightControlSettingsTab`; real catalogs
    arrive with L3-R's `modelCatalog()`. The UI test runs on its own (plan Task 13 Step 8), not
    in `smoke.sh`. The live probe is `INDEX_LIVE=1 FD_TEST_FILTER=IndexLiveProbeTests ./scripts/test-unit.sh`.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-10-04-flight-control-l3-capability-index-design.md docs/FOLLOWUPS.md
git commit -m "docs: record the capability index as built" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Vendor and scope check before handing back**

Run: `git diff master...HEAD --stat -- vendor; git diff master...HEAD --name-only | rg -v '^(Sources/IntakeKit/FlightControl/|Sources/FlightDeck/FlightControl/|Sources/FlightDeck/Preferences/|Sources/FlightDeck/SessionStore.swift|Sources/FlightDeck/FlightDeckApp.swift|Tests/FlightDeckTests/FlightControlL3/Index/|Tests/FlightDeckTests/Fixtures/FlightControlL3/Index/|UITests/FlightDeckUITests/CapabilityIndexUITests.swift|docs/)'`
Expected: both print nothing — no vendor change (the worktree's `vendor/*-artifacts` symlinks
must never be committed) and no file outside this plan's scope. A vendor hit: `git rm --cached`
the symlink and amend that commit. Then finish per `superpowers:finishing-a-development-branch`
(this branch merges only after L3-0; it does not depend on L3-R/U/S).

---

## Spec coverage

| Spec | Where |
|---|---|
| §1 success 1 (cited scores per catalog model) | Tasks 2, 5, 10, 14 |
| §1 success 2 (unmatched kind → best-scoring model, score in reason) | Task 6 `rank` (+ `ScoredModel.score` for L3-R's reason) |
| §1 success 3 (rule hint) | Task 7 |
| §1 success 4 (one-click rollback) | Tasks 8, 11, 12, 13 |
| §2 dimensions | consumed from L3-0; unchanged here |
| §3 sources, live URL check, machine-readable | Task 1 |
| §4 refresh: weekly/on demand, claude -p web tools, model configurable, strict JSON, validation, cap, failure → stale | Tasks 2, 9, 10, 11 |
| §5 alias table, proposals confirmed, unmapped ignored, knobs | Tasks 3, 11, 12 |
| §6 percentiles, weighted mean, confidence, unknown ≠ 0, manual, inherit 0.85, rank, ties, hints | Tasks 5, 6, 7 |
| §7 storage path, keep 12, newest valid current, auto-apply, diff, rollback | Tasks 4, 8, 11 |
| §8 heatmap + confidence opacity + click-through, sources, aliases + pending, manual, last refresh, Refresh now, diff, Roll back | Task 12 |
| §9 pure tests on recorded outputs, hint tables, fake runner (cap, failure, stale), live probe, XCUITest + screenshots | Tasks 2–11, 13, 14 |
| §10 conformer, scheduler, pane at integration | Tasks 11, 12; Task 15 notes |
| §11 files | Task 15 Step 2 |
