# Flight Control coverage × fidelity — design handoff

**For:** a fresh Claude Code session that will brainstorm → spec → plan "coverage metrics
balanced against plan fidelity" for Flight Control's planning rounds.
**Written:** 2026-09-28, from the conversation with Nate that raised it. Nothing here is built;
the job is the design.

Read `AGENTS.md` → `docs/HANDOFF.md` → this doc → the planning-UI spec
(`docs/superpowers/specs/2026-09-27-planning-ui-redesign-design.md`) and the intake/round-engine
spec (`docs/superpowers/specs/2026-09-26-flywheel-intake-design.md`, §6 rounds, §6.6 convergence).

---

## 0. The five things you must not miss

1. **The engine runs exactly one reviewer per Refine round.** `RoundConfig.reviewer` is a
   single `Slot?`, reused for every Refine round (`Sources/IntakeKit/RoundConfig.swift`).
   Capture–recapture (§3) needs two reviewers over the *same* plan. Today only the Draft stage
   runs models in parallel. The first design decision is how to get a second, independent pass
   per checkpoint: a parallel reviewer, a shadow reviewer (§4), or a different estimator.
2. **Most of the raw data is already on disk**, per intake, under
   `~/Library/Application Support/Flight Deck/intakes/<id>/` (§2). The metrics are mostly
   folds over files that exist. The gaps are issue identity across reviewers, synthesis
   provenance, and cost for codex (§2.8).
3. **Only two harnesses exist:** `Harness` is `codex | claude` (`Sources/IntakeKit/Intake.swift:24`).
   The shadow probe for Gemini, Grok or Qwen needs a new harness (§5). Build coverage metrics
   first; they work with Claude + Codex today.
4. **Everything is a suggestion, never automatic.** Nate's ruling from the planning-UI work:
   the UI shows numbers and a verdict word, and it never runs or trims rounds on its own. No
   "percent converged". Honest data only (planning-UI spec §2).
5. **Nate's fieldOS intake is live. Read it, never write it:**
   `~/Library/Application Support/Flight Deck/intakes/DF11B6D8-F216-4FE5-AB24-DF0D61F9AE0B/`.
   On 2026-09-28 it held 2 checkpoints (Draft ×4, Synthesis). Tape status was `stopped`, and a
   `runs/refine-1-reviewer` directory existed. So Refine 1 was started, then stopped, and
   nothing has been planned past it.

---

## 1. The question, in Nate's words

1. "the Agent Flywheel docs recommend a certain mix of models for working through plans. I only
   have Claude and Codex. Examine what the site actually says about it, and give me some ideas
   for metrics I could surface about it, i.e. 'model diversity', etc"
2. "the question is really more about ensuring good coverage, i.e. how do i know if i need to
   configure Grok or Gemini for best results, or what happens if i swap Gemini for Qwen?"
3. "And maybe i can balance that against plan fidelity somehow."

### What agent-flywheel.com/complete-guide says (fetched 2026-09-28; the guide is dated July 17 2026 and calls itself a starting point, not a ranking)

- **Drafts from four families with roles:** GPT = global arbiter, Claude = implementation
  realist, Gemini = coverage expander, Grok = assumption stress-test ("different blind spots").
- **Synthesis by GPT, integration** by Claude Code or Codex with a per-change agree / somewhat /
  disagree verdict — which Flight Control records (§2.3).
- **Refinement:** 4–5 rounds, each a fresh conversation (no anchoring), different families
  across rounds; models stop at ~20–25 issues unless told there are many more.
- **Convergence:** phases by round (major fixes → architecture → refinement → polish). Signals
  are shorter responses, slower change and rising similarity. The weighted score (≥0.75 ready,
  >0.90 diminishing) is labelled illustrative. Red flags: oscillation, expansion, plateau at
  low quality.
- **The guide has no metric for cross-model disagreement or coverage.** This is the gap.
- Nate has 2 of the 4 families. The Gemini and Grok *families* are missing. Their *roles* are
  not: Full plan already prompts codex as the coverage drafter and claude as the stress-tester
  (§2.1).

### Terminology proposed (use in UI copy and the spec)

- **model family:** vendor lineage (Claude, GPT/Codex, Gemini, Grok, Qwen).
- **cross-family review:** a model from one family reviews what another family wrote.
- **coverage:** how much of the plan's issue space reviewers have searched.
- **marginal yield / blind-spot yield:** what one family finds that the others don't.

In user-facing text, say "agent" (not seat), "task" (not bead) and "Flight Control" (not
Flywheel). The one exception is the external methodology, "agent flywheel".

---

## 2. What Flight Deck records today (verified in code, 2026-09-28, branch `flywheel-intake` @ 84835ab)

### 2.1 Who ran each seat, with which model

- **The configuration:** `RoundConfig` in `Sources/IntakeKit/RoundConfig.swift`. It holds
  `drafters: [Slot]`, `synthesizer`, `reviewer`, `integrator`, `encoder`, `polisher`,
  `refinementCap`, `polishCap` and `freshEyesAndDedup`. A `Slot` is a `ModelChoice`
  (`harness`, `model`, `effort`) plus a `DrafterPersona` (`general`, `arbiter`, `realist`,
  `coverage`, `stressTest`) and an optional availability `fallback`. It is persisted as
  `Intake.roundConfig` in `intake.json` (`Sources/IntakeKit/Intake.swift:93`).
- **What actually ran:** each checkpoint's `RoundRecord.slots: [SlotOutcome]`
  (`Sources/IntakeKit/Tape.swift`). A `SlotOutcome` has `role`, `persona`, `used`,
  `requested`, `status` (ok / substituted / failed), `diagnosis` and `sessionID`. `used` is
  the model that really ran after a fallback. This lives in `tape.json`. **This is the
  authoritative per-round model record. Read `used`, not the config.**
- `runs/<run>/run.json` (`RunRecord`, `Sources/IntakeKit/RoundExecutor.swift:33`) holds only
  pid, sessionID, start, finish and exit code. **It has no model and no harness.** Run
  directory names follow `<stage>-<round>-<role>[-<i>][-fallback]`, for example
  `draft-0-drafter-2` or `refine-1-reviewer` (`runName`, `RoundExecutor.swift:693`).
- `runs/<run>/result.json` (`SeatResult`, `Sources/IntakeKit/SeatActivity.swift:56`): outcome
  counts, no model. `runs/<run>/activity.json` (`SeatActivity`): `harness`, tokens, `costUSD`
  (claude only).
- **Personas are wired for drafters and the synthesizer only.** `RoundPrompts.lens(for:)`
  (`Sources/IntakeKit/RoundPrompts.swift:352`) adds the lens text. `refine()` passes no persona
  to the reviewer (`RoundExecutor.swift:177`).
- **The preset defaults, and why they matter for "cross-family"** (`PresetExpansion.config`,
  `RoundConfig.swift`): A = codex if installed, else claude; B = the other. The reviewer is
  always A (codex) and the integrator always claude, so every Refine round is reviewed by codex
  and written by claude: cross-family review by the "last writer" definition is already 100%,
  and diversity *among reviewers* is zero. Per-round alternation isn't expressible (one slot).
- The fieldOS intake (Full plan, `customized: true`) shows this shape: drafters codex/arbiter,
  claude/realist, codex/coverage, claude/stressTest; synthesizer codex; integrator claude;
  reviewer codex.

### 2.2 Drafts, stored by index

- The Draft round writes `checkpoints/<n>/drafts/<i>.md`. `i` is the drafter's index in
  `RoundConfig.drafters` (`RoundExecutor.swift:150-155`). Only drafters that succeeded write
  a file.
- The same checkpoint's `record.slots` lists every drafter, failed ones included, sorted by
  that index. So `slots[i]` names the model behind `drafts/i.md`. Use `slots[i].used`, since a
  fallback may have run.
- Synthesis builds on drafter 0's draft (or the first surviving one) and hands the synthesizer
  the rest (`draftFiles`, `RoundExecutor.swift:642`). **Nothing records which draft each part
  of the synthesis came from.**

### 2.3 Proposals and the integrator's verdicts

- `ProposedChange` is `section`, `rationale` and `edit` (`RoundPrompts.swift:14`). A synthesis
  or refine checkpoint stores the round's proposals as `checkpoints/<n>/changes.json`
  (`integrate`, `RoundExecutor.swift:195-275`).
- `ChangeVerdict` is `{index, verdict: agree|somewhat|disagree}` (`RoundPrompts.swift:82-93`).
  It is stored as `checkpoints/<n>/verdicts.json` **only when the integrator returned a
  per-change list**; the counts are always in `RoundRecord.tally`. Disagreed changes are not
  applied.
- **The proposer is implicit:** each synthesis or refine round has exactly one proposer (the
  `synthesizer` or `reviewer` `SlotOutcome` in `record.slots`). So "which family raised which
  accepted change" can be recovered per round. No per-change field records it.
- **Real data gap:** fieldOS's synthesis checkpoint (`checkpoints/2/`) holds only `plan.md`,
  with no `changes.json` or `verdicts.json`. Its tape was written before those files were kept.
  Expect older tapes to lack them. The metrics must degrade to "unknown", never to 0.

### 2.4 Churn, repeats, and the convergence verdict

All of this is in `Sources/IntakeKit/ConvergenceSeries.swift`. It is folded off-main in
`IntakeService.refreshConvergence` (`Sources/FlightDeck/Intake/IntakeService.swift:861`),
once per landed round.

- `ConvergencePoint` holds, for each Refine or Polish round: `changeCount`, `linesChurned`,
  `agreeRatio` ((agree + ½·somewhat) / verdicts), `sectionsTouched`, `sectionChurn`
  (heading → lines changed, from `PlanMetrics.sectionChurn`), `reviewerModel`, `repeatCount`,
  `reopenCount` and `reopenedSections`.
- `ConvergenceSeries.sectionChurn(_:loadFile:)` returns churn per checkpoint.
  `ConvergenceVerdict` is `tooEarly | converging(settled:) | plateau | diverging(reason:)`,
  with reasons `growing | agreementFell | hotSection | reopened`.
- The thresholds are in `ConvergenceThresholds`, picked rather than fitted: `convergingRatio`
  0.6, `agreeTolerance` 0.05, `settledFloor` 5 / `settledFraction` 0.15 / `settledAgree` 0.85,
  `growRatio` 1.25 / `growMin` 3, `agreeDrop` 0.15, `hotShare` 0.3 / `hotRuns` 3,
  `reversalShare` 0.6 / `reopenRuns` 2, `wordOverlap` 0.5 / `shingleOverlap` 0.35.
- A reviewer-model change restarts the trend (`ConvergenceTrend.modelChanged`, `restartRound`).
- **Issue matching already half-exists.** `ConvergenceSeries.Fingerprint` (private, around
  `:274`) matches two proposals as "the same idea". They must have the same section tokens,
  and either a word-set Jaccard ≥ 0.5 or a word-3-shingle Jaccard ≥ 0.35 after stop words and
  crude stemming. It feeds `repeatCount` and `reopenCount` across rounds of one cycle.
  It is the obvious seed for cross-reviewer issue identity, but it has no model attribution,
  works within one cycle only, and was never checked against human judgement. Decide whether
  it is good enough, or whether the integrator should cluster proposals instead.

### 2.5 Prompts that already exist

- The review prompt already uses the guide's "lie to them" move: "at least 40 elements — find
  them" (`RoundPrompts.review`, around `RoundPrompts.swift:428`). It uses 40, not 80.
- Every Refine round is a fresh session by construction: `refine()` never resumes
  (`RoundExecutor.swift:175`). Only the single correction turn resumes the same session. So
  a "fresh-session rate" metric would be a constant 100%. Drop it, or keep it only as an
  invariant check.

### 2.6 Fidelity presets and the round sequence

- `Preset` is `bead | sketch | featurePlan | fullPlan` (`Sources/IntakeKit/Intake.swift:3`).
  The UI shows these as **Single task / Sketch / Feature plan / Full plan**
  (`Sources/FlightDeck/Intake/Planning/UIText.swift:9-15`).
- Defaults (`PresetExpansion.config`):

| Preset | Drafters (persona) | Refine cap | Polish cap | Fresh eyes + dedup | Default play |
|---|---|---|---|---|---|
| Single task | no rounds (triage encodes directly) | — | — | — | — |
| Sketch | 1 × A (general) | 2 | 0 | no | to review |
| Feature plan | A arbiter, B realist | 3 | 2 | no | next major |
| Full plan | A arbiter, B realist, A coverage, B stressTest | 5 | 6 | yes | next major |

- Synthesis runs for Feature plan and Full plan. Sketch has no synthesizer.
- The human edits the config in `Sources/FlightDeck/Intake/RoundConfigEditor.swift` (the
  inspector). Model is free text; harness is a picker over the two cases (`:358`).
- `TapePlanner.sequence(config:extraRefinement:extraPolish:)` (private,
  `Sources/IntakeKit/TapePlanner.swift:15`) expands a config into the planned rounds.
  `TapePlanner.planned(stage:round:tape:config:)` and `apply(_:to:config:)` are public.
- **Growing and shrinking a run:** `TapeCommand.extend(Stage, by:)` and `.trim(Stage, by:)`
  (`Sources/IntakeKit/Tape.swift:305`). `trim` is clamped to rounds landed plus the one in
  flight, and stored as a negative `Tape.extraRefinement` / `extraPolish`. The board's "−" is
  `handle("minus", …)` (`Sources/FlightDeck/Intake/Planning/DeparturesBoard.swift:487`); the
  Run menu has "Remove a Round" ⌘- (`PlanningCommands.swift`); `TapeOverlay` shows the click at
  once. "Saturated early → trim" should *suggest* this command, never send it.

### 2.7 Where metrics would land in the desktop UI

| Surface | Code | What it shows today |
|---|---|---|
| LCD (control bar) | `Sources/FlightDeck/Intake/Planning/LCDModel.swift`, `ControlBar.swift` | cells `round, elapsed, seatsDone ("agents done"), soFar, billed, convergence, stopsAt`; convergence is sparkline + verdict word + "N changes" |
| Convergence card | `ConvergenceCellModel.swift` (`ConvergenceCellModel`), `ConvergenceViews.swift` (`ConvergenceCard`, `ConvergenceSparkline`) | verdict, explanation line, suggested action |
| Section heatmap | `ConvergenceCellModel.swift` (`HeatmapModel`), `ConvergenceViews.swift` (`ConvergenceHeatmap`) | sections × rounds churn, agreement NN% (kept by ruling), verdict panel |
| Churn lane + versions card | `ChurnLaneModel`, `ChurnLaneView`, `SectionVersionsCard` | per-section "still since R2", "settling", flagged sections, per-round versions with integrator verdicts |
| Header progress line | `ProgressSummary.swift` | `✓ Triage 3:40 · 41 files ✓ Draft & Synthesis 9:42 · 412 lines ✓ Refine ×3` |
| Finished-round cards + detail panel | `FinishedRounds.swift`, `FinishedRoundsModel.swift` | per-round card; panel lists agents, models, outcomes ("N agents ran as asked / fell back / failed") |
| Awaiting-choice body | `RoundConfigEditor.swift` (summary line, around `:214`), `IntakeDetailView.swift` | "Full plan · 4 drafters · refine ×5 · …" — where a coverage target per fidelity would be stated |

The render harness for all of these is `Tests/FlightDeckTests/Intake/Planning/PlanningRender.swift`.
Set `FD_PLANNING_RENDER_DIR` and filter to a `*RenderTests` class (§7).

### 2.8 What is NOT recorded today, and the design needs

- **Issue identity across reviewers.** Nothing clusters two proposals from different models as
  one issue. `Fingerprint` (§2.4) works within one cycle only, has no attribution and isn't
  public.
- **Two independent reviews of one checkpoint.** There is one reviewer per round (§0.1). Rounds
  review *different* plans, so pooling them breaks capture–recapture's same-population
  assumption.
- **Per-change proposer on disk.** It can be derived (one proposer per round), but it is not
  stored.
- **Synthesis provenance.** Nothing records which draft each synthesized section came from.
  Draft overlap and unique-coverage metrics would diff `drafts/*.md` against each other and
  the synthesis. The inputs exist; the fold doesn't.
- **Major vs minor changes.** `ProposedChange` has no severity. The brief's "accepted changes
  by family (major/minor)" needs a schema field or a heuristic (lines churned per change).
- **Cost per round.** Claude seats keep `costUSD` in `runs/<run>/activity.json`; codex seats
  have tokens only. `Checkpoint` and `RoundRecord` carry no cost, and `LCDModel.billed` sums
  only the current round's finished seats. Cost per accepted change by family needs a codex
  price table, or tokens as the unit.
- **Wall time per seat.** It is recoverable from `run.json` (`started` / `finished`) and
  `Checkpoint.startedAt` / `createdAt`. It is not folded anywhere.
- **Cross-tape history per project.** "Feature plans in fieldOS typically leave ~4 unfound"
  needs a per-project index over finished tapes. Intakes are independent directories
  (`IntakeStore`), and nothing aggregates across them.

---

## 3. The coverage estimate (the core answer to question 2)

- **Lincoln–Petersen:** reviewer A finds n1 accepted issues, B finds n2, m found by both →
  N ≈ n1·n2/m; unfound ≈ N − (n1 + n2 − m). 20/18/15 → N ≈ 24, ~1 unfound (saturated).
  20/18/4 → N ≈ 90, ~56 unfound (add a family). Count only accepted issues (agree/somewhat).
- **It assumes independent reviewers.** Correlated models inflate m and *under*-estimate the
  unfound, so high overlap between similar models is weak reassurance and low overlap is a
  strong signal. For Full plan, require evidence of independence (the families sometimes
  disagree), not only a low unfound number.
- **Per-family marginal yield per round:** novel accepted, precision (accepted share), overlap.
  The novel-yield curve should decay. A family still high late is covering unique ground; one
  near zero from round 2 is redundant for this plan.
- **The estimator is open.** With one reviewer per round the options are: a parallel second
  reviewer (`reviewers: [Slot]`); Draft-stage capture–recapture across the 2–4 drafts (issues
  = sections or ideas); a shadow reviewer on chosen checkpoints (§4); or a depletion estimator
  over successive rounds' novel yield (fits one reviewer per round, but assumes the issue
  population doesn't shrink as it is fixed — it does).

### Other metric ideas from the conversation (all need a fold over §2's files)

- **Composition:** family mix ("2 of 4 families · Claude, Codex", naming the missing roles);
  cross-family review rate (§2.1: 100% writer-vs-reviewer by default, 0% reviewer diversity).
- **Independence:** draft overlap (pairwise similarity of `drafts/*.md`); unique coverage
  (ideas in only one draft, attributed); disagreement rate by family (zero = rubber-stamping).
- **Yield:** accepted changes by family; blind-spot yield (accepted changes no other family
  raised in any round); synthesis provenance.
- **Knobs with two families:** rotate the reviewer family per Refine round (needs a per-round
  config or a `reviewers` rotation); give the reviewer a persona (not wired, §2.1) and measure
  whether unique finds rise; vary effort; tune the issue-budget prompt (40 today, §2.5).

---

## 4. Choosing Grok or Gemini, or Gemini vs Qwen: the shadow probe

- Run the candidate as an **extra reviewer on a frozen checkpoint** (e.g. the synthesis and a
  mid-Refine one). The integrator scores its output (novel/duplicate × accept/reject) but it is
  **never applied**; the tape doesn't move.
- Same checkpoints, same prompt and role for every candidate. Compare novel accepted, overlap
  with Claude + Codex, precision, cost and time per review, and the drop in estimated unfound.
- **Judge the role, not the brand.** Gemini was the "coverage expander", so compare Qwen on
  novel yield and on unfound reduction.
- Late polish rounds make useless probes, because every model looks the same there.
- **Engine shape:** the integrator's scoring pass must write nothing to the plan. Today
  `integrate` always edits `work/plan.md` (`RoundExecutor.swift:195`). A score-only integrate
  mode, or a separate classifier seat, is new.
- **Where results live:** a sibling of `checkpoints/` (for example
  `probes/<checkpoint>/<candidate>/`), so `ConvergenceSeries` never mistakes a probe for a round.

---

## 5. What adding an OpenAI-compatible harness would touch

`Harness` is `enum Harness: String, Codable { case codex, claude }`
(`Sources/IntakeKit/Intake.swift:24`). Adding a case (for example `openAICompatible`, with an
endpoint and a key reference) touches:

- **`Sources/IntakeKit/Harness.swift`:** `HarnessCommand.build` (argv, isolation, read-only vs
  write sandbox — codex gets `codexIsolation` + `CodexUserConfig.arguments`, claude gets
  `claudeIsolation` `--restricted --strict-mcp-config` + `ClaudeUserEnv`), `HarnessOutput.parse`
  (session id, structured output) and `HarnessCommand.environment(for:)`. A plain HTTP endpoint
  has no tools: it can review a plan passed inline but can't `br list` or read the repo — decide
  whether a shadow reviewer needs repo access at all.
- **`Sources/IntakeKit/SeatActivity.swift:163`:** `ActivityParser` folds each harness's stream
  (headline, tokens, cost). A new stream format needs its own fold, or the seat row has no
  live headline.
- **`Sources/IntakeKit/FailureDiagnosis.swift:34`:** the login and rate-limit actions per
  harness.
- **`Sources/IntakeKit/RoundConfig.swift`:** `AvailableModels` has hard `codex` / `claude`
  fields, and `PresetExpansion` assumes A/B.
- **`Sources/FlightDeck/Intake/RoundConfigEditor.swift:358`:** the harness picker.
- **`IntakeService.availableModels()`** (around `IntakeService.swift:678`): detection only
  probes PATH for the two CLIs.
- **Credentials:** agents must never type keys (safety rules). Use keychain or env
  references, and never commit anything.
- **Isolation discipline is the precedent:** every existing flag was probed live and its
  comment says so. Prove a new harness can't write outside `work/`, reach MCP servers, or pick
  up the user's allows.
- The round-engine FOLLOWUPS already list "Oracle, grok and gemini slots" and a detection UI
  as *next*. Link the new design to that entry; don't design around it.

---

## 6. Balancing coverage against fidelity (question 3)

Fidelity presets become **coverage budgets**, not fixed scripts. The targets below are
placeholders. Calibrate them on real tapes.

| Fidelity | Coverage target | Families | If missed |
|---|---|---|---|
| Single task | none | 1 | — |
| Sketch | loose, ≲10 estimated unfound | 1–2 | say so; don't escalate |
| Feature plan | moderate, ≲5 unfound + cross-family review each round | 2 | suggest another round or a shadow third family |
| Full plan | tight, ≲2 unfound + latest-round novel yield ≈0 for every family + independence evidence | 2+ | suggest adding a family or upgrading reviewers |

- **The stopping rule is convergence AND coverage.** A plateau with a high unfound count is
  *stalled*, not converged. This is the guide's "plateau at low quality" red flag, now
  measurable. It likely becomes a new `ConvergenceVerdict` case, or a second axis beside it.
- **Scale both ways:** saturated early → suggest trimming the remaining Refine rounds (the
  board's "−", `TapeCommand.trim`); poor coverage → suggest a round, a third family, or a
  higher fidelity than triage recommended.
- **Triage evidence:** once a project has finished tapes, show the coverage each fidelity
  achieved there. This needs the cross-tape index (§2.8).
- **UI sketch:** an LCD cell beside CONVERGENCE ("COVERAGE ~3 LEFT" / "SATURATED"); a round
  summary line ("target ≲5 unfound · met at Refine 2", or "not met — Codex and Claude still
  split on §4, §7"). The LCD drops cells as it narrows (`LCDModel`, around `:44`); decide
  where coverage ranks in that order.

**Suggested order:** coverage metrics first (they work with Claude + Codex today) → fidelity
targets and the stopping rule → the shadow probe (needs the new harness).

---

## 7. Nate's working rules for your session

From `~/.claude/CLAUDE.md`, `AGENTS.md` and memory
(`~/.claude/projects/-Users-nate-Projects-Protos-n-Tools-flight-deck/memory/`):

- **Process:** `superpowers:brainstorming` → spec → `superpowers:writing-plans`. Specs go in
  `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`.
- **Presenting:** the spec, then the plan, each through `EnterPlanMode` → write it into the
  named plan file → `ExitPlanMode` (Plannotator fires). **Never** ask for approval in chat
  prose ("sound good?", "shall I proceed?"); a genuine design question goes through
  `AskUserQuestion`.
- **After approval:** execute subagent-driven, automatically, with no "ready?" gate.
- **Show UI options as renders, not prose** (`show-ui-options-as-renders.md`).
  `screencapture` is denied. Use `layer.render(in:)` on a parked `NSHostingView`
  (`offscreen-render-technique.md`); `PlanningRender.swift` already does this. Parked
  *titled* windows leak onto the screen unless they are a `ParkedWindow`
  (`ProjectViewIntakeListLiveTests.swift:188`).
- **Never offer the visual companion.** Start it when a visual question comes up
  (`never-offer-visual-companion.md`).
- **Never publish Artifacts** unless Nate asks explicitly.
- **Search with `rg`, never `grep`.** qartez tools are fine for reading. Its mutators corrupt
  worktrees; use the built-in Edit there.
- **Shared checkout:** other sessions edit it at once. Never `git stash`, `git checkout .` or
  revert blind; commit only your files, by path; `git diff --cached --stat -- vendor` is empty.
- **Worktrees** need `vendor/{boringssl,ghostty,fd-abduco}-artifacts` symlinked from the main
  checkout (`flight-deck-worktree-setup-and-merge.md`). Never commit those symlinks
  (`worktree-vendor-symlinks-pollute-merge.md`).
- **Never launch a bundle from `DerivedData/`.** It forks the fleet with duplicate agents that
  outlive it. Only `/Applications/Flight Deck.app`, and agents can't drive the GUI.
- **`./scripts/test-unit.sh` exits 0 even when the sharded run fails.** Read its final
  `** SHARDED UNIT RUN PASSED|FAILED **` line. Budget about 8 minutes for a full run, and
  run it in the foreground from subagents.
- **Never run real model seats in tests.** Use the `CommandRunner` fakes. `RoundsLiveProbeTests`
  and `./scripts/test-codex-live.sh` spend real tokens; don't loop them.
- **The fieldOS intake is read-only** (§0.5). Copy files into a fixture to test against real
  shapes.
- **Terminology** in user-facing text: Flight Control, tasks, agents (§1).
  `TerminologyGuardTests` enforces this for `Sources/FlightDeck` and `Sources/IntakeKit`.

---

## 8. Open questions to resolve with Nate

1. **How do we get a second independent pass per checkpoint?** Options: parallel reviewers
   every round (doubles cost), a shadow reviewer on selected checkpoints only, or estimating
   from drafts and depletion.
2. **Who decides that two proposals are the same issue?** Options: `Fingerprint` made public
   and cross-model, the integrator clustering in its verdict pass, or a separate cheap
   classifier seat. The cost and trust trade-off is Nate's call.
3. Is "unfound issues" the number to show, or is it too precise for honest data? Alternatives:
   a band ("few / some / many left"), or "SATURATED / NOT YET".
4. Should the reviewer rotate families by default, and get a persona? That changes the Feature
   plan and Full plan presets.
5. Are the coverage targets per fidelity fixed, per project, or learned from finished tapes?
6. Cost: is claude's `costUSD` plus codex tokens enough for the probe comparison, or is a
   codex price table needed?
7. Which harness comes first for the shadow probe: an OpenAI-compatible HTTP endpoint (covers
   Gemini, Grok and Qwen through one adapter), or per-vendor CLIs?
