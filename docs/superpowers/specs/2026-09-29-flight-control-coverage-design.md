# Flight Control coverage × fidelity — design

**Status:** spec, awaiting review. **Date:** 2026-09-29.
**Source:** `docs/FLIGHT-CONTROL-COVERAGE-HANDOFF.md` (the grounding for every "the code does X"
claim below; re-verified on master @ 16aa5bf) and the brainstorming session that followed it.

---

## 1. Intent

The maintainer asked how he can tell that Claude + Codex have reviewed a plan well enough, when he would need
a Gemini or Grok, and how to balance that against plan fidelity.

**What this design delivers:** a *measured* answer, per intake, to "have the reviewers searched
this plan's issue space?" It works with only Claude + Codex. Each fidelity preset then states a
coverage target that the answer is checked against.

**Success looks like:**

- A Feature plan or Full plan tape shows a COVERAGE reading after its first Refine round and again
  after its last one. The reading is a band word, backed by raw counts that the maintainer can check.
- When the plan has converged but the coverage target is missed, the card says so and suggests a
  next step. When coverage saturates early, the card suggests trimming Refine rounds.
- Nothing runs, trims or extends on its own (planning-UI ruling: suggestions only, honest data, no
  "percent converged").

**Decisions made in brainstorming (the maintainer's answers):**

| Question | Ruling |
|---|---|
| How to get a second independent pass | **Cross-check rounds**: both families review the same checkpoint, at chosen Refine rounds only |
| Who decides two proposals are the same issue | **The integrator clusters them** in its verdict pass. `Fingerprint` runs beside it as a sanity check |
| What the LCD shows | **A band word** (SATURATED / FEW LEFT / MANY LEFT / NO OVERLAP). The ~N estimate is shown only in the card, labelled "estimate" |
| Scope | **Coverage + fidelity targets.** The shadow probe, new harnesses, the cross-tape index and reviewer rotation/persona are deferred (§10) |
| Where the second reviewer's output goes | **Approach A**: a cross-check round is one Refine round with two reviewers. The plan gains both families' finds |

**Constraint that shapes the thresholds:** only one intake exists on this machine (larkOS), and it
stopped before Refine 1. No real Refine data exists to calibrate against. Every threshold here is a
named placeholder in one struct, like `ConvergenceThresholds`, and is labelled so in its doc comment.

---

## 2. Terms (also the UI copy)

- **model family:** vendor lineage. Today it is derived from `Harness` (`codex` → Codex/GPT,
  `claude` → Claude). The family is a function of the harness, so a later harness adds a family
  without touching this design.
- **cross-check round:** a Refine round reviewed by two agents from different families, each in
  its own fresh session, over the same plan.
- **issue:** one cluster of proposals that the integrator judged to be the same idea.
- **accepted issue:** a cluster with at least one member the integrator marked `agree` or `somewhat`.
- **coverage:** how much of the plan's issue space the reviewers have searched, as estimated from a
  cross-check round.

User-facing text says "agent", "task" and "Flight Control" (`TerminologyGuardTests`).

---

## 3. Which rounds cross-check

`RoundConfig` gains two optional fields. Both are optional so that every existing `intake.json`
decodes unchanged (synthesized `Codable` reads a missing optional as nil):

```swift
public var crossReviewer: Slot?          // the second family's reviewer; no fallback (§4.3)
public var crossCheck: CrossCheckPolicy? // nil ≡ .off
public enum CrossCheckPolicy: String, Codable, Sendable { case off, firstAndLast, every }
```

- **Why not Synthesis:** the synthesizer merges drafts. It does not search the plan for problems,
  so its proposals are not a review sample. Refine 1 is the first round that reviews the
  synthesized plan.
- **`firstAndLast`** cross-checks Refine 1 and the stage's last planned Refine round. The early
  reading shows how much there is to find. The late reading is the one the stopping rule reads
  (§7). With `refinementCap == 1`, that is one round.
- **The last round is decided when the round starts,** from `TapePlanner`'s sequence as it is
  then. So `extend(.refine, by: 1)` makes the *new* last round a cross-check. "Run one more round"
  therefore means "measure again", which is the suggestion §7 makes. A `trim` that makes an
  already-landed round the last one adds no cross-check after the fact.
- `PlannedRound` gains `crossCheck: Bool` (default false; `Codable` via `decodeIfPresent`), set by
  `TapePlanner.sequence`. The board and the runner then read one answer.
- A cross-check needs two families. When `crossReviewer` is nil, or its harness equals the
  reviewer's, the policy has no effect. The inspector says so.

**Preset defaults** (`PresetExpansion.config`), applied only when both harnesses are installed
(`hasFallback`):

| Preset | `crossCheck` | `crossReviewer` |
|---|---|---|
| Sketch | `.off` | `Slot(b)` (so turning it on in the inspector is one click) |
| Feature plan | `.firstAndLast` | `Slot(b)` |
| Full plan | `.firstAndLast` | `Slot(b)` |

Existing intakes, larkOS included, decode to `.off`. The maintainer can turn it on in the inspector.

**Inspector** (`RoundConfigEditor.swift`): a "Cross-check" row in the reviewer section. It has a
picker for Off / First and last / Every round and a model row for the cross-check agent, and it
shows a note when both agents are the same family. The summary line gains "cross-check R1, R5"
(the rounds it will cross-check at the current caps). Editing either field sets `customized`, as
other edits do.

---

## 4. Running a cross-check round (`RoundExecutor.refine`)

### 4.1 Shape

When the planned round has `crossCheck == true`:

1. The reviewer and the cross-reviewer run **in parallel**, each through the existing
   `RoundPrompts.review` prompt. Each runs in its own fresh session with the same plan and inputs.
   Run names are `refine-N-reviewer` and `refine-N-crossReviewer`. The slot roles are `"reviewer"`
   and `"crossReviewer"`, so `ConvergenceSeries`' `slots.last { $0.role == "reviewer" }` still
   names the primary reviewer.
2. Both proposal lists are **merged blind**. The integrator gets one `changes.json` whose order is
   a deterministic interleave seeded by the checkpoint id. There is no proposer field in it. The
   integrator is Claude, which is one reviewer's family. If it could see who proposed what, its
   verdicts could favor its own family, and every family metric would inherit that bias.
3. The integrator runs with a **clustered** prompt and schema (§4.2). It applies each accepted
   issue once, gives every proposal a verdict and returns `clusters`.
4. The checkpoint stores `changes.json` (the merged list in presented order), `verdicts.json` (as
   today) and a new **`crosscheck.json`**:

```json
{ "proposers": [0, 1, 1, 0, …],          // per change: 0 = reviewer, 1 = crossReviewer
  "families":  ["codex", "claude"],       // family of proposer 0 and 1, as they actually ran
  "clusters":  [[0, 3], [1], [2, 5], …],  // cleaned (§4.2); null when the integrator gave none
  "blindOrderSeed": 7 }
```

`RoundRecord.changeCount` stays "proposed changes": the sum of both lists. §6 covers what
convergence reads instead.

### 4.2 The clustered integrate

- `RoundPrompts.integrate(… clustered: true)` adds these instructions: "Some proposals may be the
  same issue raised twice. Group every set of proposals that address the same underlying issue in
  `clusters` (lists of 0-based indices; a proposal in no group stands alone). Apply each issue at
  most once. Give every proposal a verdict: a duplicate of an issue you applied gets that issue's
  verdict."
- `RoundSchemas.integrateClustered` is the strict-mode schema plus a required
  `clusters: [[integer]]`. It is a separate schema, so non-cross-check rounds keep today's exact
  shape.
- `IntegrateOutput.clusters: [[Int]]?` is cleaned in the same way as `verdicts(forChanges:)`:
  - Indices outside the list are dropped.
  - An index already placed in an earlier cluster is dropped.
  - A cluster left with fewer than 2 members is dropped (singletons are implicit).
  - An empty or missing list becomes `nil`.
- A missing or unusable `clusters` never pauses the round. The plan edit is what matters.
  `crosscheck.json` records `"clusters": null`, and the fold falls back to `Fingerprint` (§5.2),
  labelled as such.

### 4.3 Failure handling

- **The primary reviewer** keeps today's behavior: its fallback, then a pause if both attempts fail.
- **The cross-reviewer has no fallback, and its failure never pauses.** Its fallback would be
  family A, and a same-family "cross-check" is not independent. When it fails, the round continues
  as a normal single-review round: `crosscheck.json` is not written, the slot is recorded as
  `.failed` with its diagnosis, and the coverage card says "cross-check agent failed at Refine N".
- **When the primary fell back** to the cross-reviewer's family, both reviews are one family.
  `crosscheck.json` is written with equal `families`, and the fold reports that round as "same
  family — not independent", with no estimate.
- **The integrator** fails the same way as today (pause). The did-it-edit check is unchanged.

### 4.4 Cost

A cross-check adds one review turn per cross-check round. The integrator reads a longer list, but
its seat count is unchanged. The inspector's summary line names the cross-check rounds, so the
cost is visible before the run. There is no new cost accounting (the handoff's codex price table
is deferred).

---

## 5. The coverage fold (`IntakeKit/CoverageSeries.swift`, new, pure)

### 5.1 Output

```swift
public struct CoverageReading: Equatable, Sendable {
    public var checkpoint: Int, round: Int
    public var familyA: ModelFamily, familyB: ModelFamily // as they ran; ModelFamily(harness:) — .codex | .claude today
    public var matcher: Matcher                         // .integrator | .textSimilarity
    public var n1: Int, n2: Int, both: Int              // accepted issues found by a, by b, by both
    public var rejectedA: Int, rejectedB: Int           // proposals the integrator disagreed with
    public var estimate: Estimate                       // see below
    public var band: CoverageBand
    public var correlated: Bool                         // §5.3
    public var textSimilarityBoth: Int?                 // Fingerprint's `both`, for the disagreement note
}
public enum CoverageBand { case saturated, fewLeft, manyLeft, noOverlap, sameFamily, unmeasured }
```

`CoverageSeries.readings(_ checkpoints:, loadFile:)` returns one reading per Refine checkpoint that
has a `crosscheck.json`. A reading is "unmeasured" when `verdicts.json` is missing, since accepted
issues can't be counted without it — unless neither family proposed anything (`proposers` empty):
no integrator runs then, so there is no `verdicts.json`, and found = 0 reads SATURATED. A checkpoint
without `crosscheck.json` yields no reading. That is how older tapes look, and they never read as 0.

### 5.2 Counting

- **Issues:** the integrator's clusters, plus every unclustered proposal as its own singleton. When
  `clusters` is null, the fold clusters with `Fingerprint`. `Fingerprint` becomes `internal` and
  gains a `sameIssue(_:_:)` entry point, and pairs are grouped transitively. The reading is then
  labelled `.textSimilarity`.
- **Accepted:** at least one member has an `agree` or `somewhat` verdict. Only accepted issues are
  counted. A family that raises junk should not inflate coverage.
- **n1 / n2 / both:** accepted issues containing a proposal from family a / from family b / from
  both.
- **Estimate (Chapman's bias-corrected Lincoln–Petersen):** it stays finite at `both == 0` and is
  less biased on small samples.
  `N̂ = (n1+1)(n2+1)/(both+1) − 1`, `found = n1 + n2 − both`, `unfound = max(0, round(N̂ − found))`.
- **Sanity check:** the fold always computes `Fingerprint`'s `both` as well. When the integrator's
  and the text matcher's `both` differ by ≥ `matcherGap` (placeholder 5) *and* by ≥ 50%, the card
  says "text matching finds X in common; the integrator found Y". It is never a verdict, only a
  note that the match was a judgement call.

### 5.3 Bands and correlation (`CoverageThresholds`, placeholders)

Evaluated in order:

| Band | Rule | Why |
|---|---|---|
| `sameFamily` | `familyA == familyB` | not independent, so no estimate |
| `saturated` | `found ≤ saturatedFound` (2) — two independent searches barely found anything | a tiny sample is itself the answer |
| `noOverlap` | `both == 0` | the families are finding disjoint things. Chapman is finite, but meaningless this far from its assumptions. This is a strong "not covered" signal |
| `saturated` | `unfound ≤ saturatedUnfound` (2) | |
| `fewLeft` | `unfound ≤ fewUnfound` (6) | |
| `manyLeft` | otherwise | |

- **`correlated`:** `min(n1, n2) ≥ 5` and `both / min(n1, n2) ≥ 0.9`. Capture–recapture assumes
  independent reviewers. Near-total overlap means the estimate is probably *low*, so a SATURATED
  reading is weak reassurance. The card says so. A correlated reading cannot meet the Full plan
  target (§7).

### 5.4 Where it runs

It runs in the same detached task as `IntakeService.refreshConvergence`, which reads the same
checkpoint files. It is keyed by the same `ConvergenceKey`, stored beside `convergence[id]` as
`coverage[id]: [CoverageReading]`, and seeded or flapped the same way (`lcd.coverage` surface).
There is no second read pass and no main-thread file I/O.

---

## 6. Convergence stays honest across a cross-check round

A cross-check round proposes roughly twice as many changes. If convergence read that total, it
would record a spike on exactly the rounds that measure coverage.

- `ConvergenceSeries.point` reads `crosscheck.json` when it is present. `changeCount` becomes the
  **number of issues** (clusters + singletons, all proposals), not the proposal count. This is the
  deduplicated count, closest to what one reviewer would have raised.
- `ConvergencePoint` gains `crossCheck: Bool`. The sparkline draws that round's point hollow, and
  the heatmap marks its column "×2". The maintainer can then see which points were measured differently.
- The trend's reviewer model is still the primary reviewer's, so a cross-check never trips
  `modelChanged`.
- `repeatCount` and `reopenCount` compare each proposal as today. The two reviewers' own
  duplicates within one round are not "repeats of an earlier round".

This is a known approximation: the union of two families is still broader than one family's
search. The hollow point is the honest disclosure. The thresholds are not re-tuned for it.

---

## 7. Fidelity targets and the stopping signal (`CoverageTargets`, placeholders)

Each preset states a target, checked against the **latest** coverage reading of the current Refine
cycle:

| Fidelity | Target | Met when |
|---|---|---|
| Single task | none | — |
| Sketch | none (loose) | the reading is shown, never judged |
| Feature plan | "FEW LEFT or better" | band ∈ {saturated, fewLeft} |
| Full plan | "SATURATED, independent" | band == saturated ∧ ¬correlated |

The target follows `Intake.preset`. A customized config keeps its preset's target.

**Coverage card suggestions:** these are text only, like `ConvergenceCycle.suggestedAction`, and
are authored in IntakeKit (`CoverageVerdict.suggestedAction`) so the cell, card and tests share one
string:

| Situation | Suggestion |
|---|---|
| Convergence is `converging(settled: true)` or `plateau`, the target is missed, and no planned cross-check Refine round (the running one included) is still to land | **"Stalled: converged, but coverage is short of the Feature plan target.** One more Refine round will cross-check again; if it stays short, the plan may need a third model family." |
| The target is met at Refine 1, and ≥ 2 Refine rounds remain (not counting the one running) | **"Saturated at Refine 1.** Consider removing the remaining N Refine rounds (Run ▸ Remove a Round, ⌘-)." |
| `noOverlap` or `manyLeft` at the last cross-check | **"Coverage is short.** Codex and Claude are finding different issues; another round, or a higher fidelity, would search more." |
| `correlated` | **"Codex and Claude found nearly the same issues.** The estimate may be low; similar models share blind spots." |
| Cross-check agent failed or same family | the fact, and that coverage is unmeasured for that round |

"Stalled" is a coverage-cell state that reads the convergence verdict. It is **not** a new
`ConvergenceVerdict` case. Convergence keeps measuring settling, coverage measures searching, and
the stall is where they disagree. This keeps `ConvergenceSeries` untouched apart from §6.

---

## 8. UI

- **LCD** (`LCDModel`): a new `LCDCell.Kind.coverage` right after `.convergence`. The value is the
  band word (SATURATED / FEW LEFT / MANY LEFT / NO OVERLAP / STALLED; "—" before the first reading
  lands). The caption is "cross-check R1" (the latest reading's round), or "unmeasured" for
  same-family or failed rounds. The short value is SAT / FEW / MANY / NONE / STALL. Tone: amber for
  STALLED and NO OVERLAP, normal otherwise. It is present only when the config cross-checks or a
  reading exists. New drop order: `[.billed, .soFar, .stopsAt, .coverage]`, then the compact set.
  The board repeats STOPS AT, but nothing repeats COVERAGE.
- **Coverage card** (`CoverageCellModel` + `CoverageCard`, beside `ConvergenceCard`): one row per
  reading ("Refine 1 · Codex 20 · Claude 18 · both 15 · ≈ 2 unfound (estimate)"), plus:
  - the fidelity target line ("Feature plan target: FEW LEFT or better · met at Refine 3" /
    "not met"),
  - rejected counts per family,
  - the correlation and matcher-disagreement notes,
  - the §7 suggestion, bold headline plus detail, as `ConvergenceCellModel` splits it.
- **Board and finished-round cards:** a cross-check Refine slot shows "×2". The detail panel lists
  the cross-check agent's row as "cross-check agent" (a `UIText` entry).
- **Renders:** the LCD at full and narrowed widths and the card in each band are added to
  `PlanningRender` (`*RenderTests`). They are reviewed as images before the UI task is called done.

---

## 9. Testing

Everything uses `CommandRunner` fakes and fixture directories. **No live model seats**
(`RoundsLiveProbeTests` untouched).

- **Math:** Chapman at the handoff's worked examples (20/18/15 → ~1 unfound; 20/18/4 → many),
  `both == 0`, tiny samples, and every band boundary and the correlation rule.
- **Cleaning:** `clusters` with out-of-range, repeated and singleton entries.
- **`CoverageSeries`** over fixture checkpoints: integrator clusters; null clusters (text-similarity
  fallback and label); missing `verdicts.json` (unmeasured); no `crosscheck.json` (no reading); and
  same family. One fixture copies larkOS's real checkpoint shapes, read-only.
- **`RoundExecutor`:**
  - Both reviewers run in parallel, and the integrator receives the blind interleave (asserted on
    the staged `changes.json`: no proposer text, seeded order).
  - The clustered schema is used only on cross-check rounds.
  - The cross-reviewer failing degrades to a single review without pausing.
  - A primary fallback to the other family is recorded as same family.
  - Stored files match §4.1.
- **`TapePlanner`:** `crossCheck` flags for `.off` / `.firstAndLast` / `.every`, after `extend` and
  after `trim`, and with `refinementCap == 1`.
- **`ConvergenceSeries`:** a cross-check point uses the issue count, carries `crossCheck`, and does
  not trip `modelChanged`.
- **Config:** an old `intake.json` without the new fields decodes to off. `PresetExpansion` defaults
  apply with one and with two harnesses.
- **UI models:** `LCDModel` cell presence, value, tone and drop order. `CoverageCellModel` text for
  every §7 row. `TerminologyGuardTests` passes.
- Must fail first against the unchanged code (house TDD rule). `./scripts/test-unit.sh`: read the
  final `SHARDED UNIT RUN` line, not the exit code.

**Docs updated in the same branch:** `docs/FOLLOWUPS.md` (close "coverage metrics" design-not-started,
and add the deferred list below), the Flight Control section of `docs/HANDOFF.md`, and a pointer
from `FLIGHT-CONTROL-COVERAGE-HANDOFF.md` to this spec.

---

## 10. Deferred (each is its own later spec)

- **The shadow probe** for Gemini / Grok / Qwen (handoff §4): score-only integrate, `probes/` beside
  `checkpoints/`. It reuses this design's clustering and `CoverageReading`.
- **An OpenAI-compatible (or per-vendor) harness** (handoff §5).
- **Cross-tape project index** ("Feature plans here usually saturate by Refine 2"), and calibrating
  `CoverageThresholds` / `CoverageTargets` from finished tapes.
- **Reviewer family rotation per round and a reviewer persona.**
- **Cost per accepted issue by family** (needs a codex price table, or tokens as the unit).
- **Draft-stage metrics** (draft overlap, unique coverage, synthesis provenance).
- **Change severity** (major/minor).
