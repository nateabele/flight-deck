# Handoff: Flight Control (planning and intake)

**What this covers:** the planning side of Flight Deck, from start to finish. A person types an
intent. Triage asks clarifying questions and recommends a fidelity. The person chooses one. For
a Sketch or larger plan, agents shape it in planning rounds. The plan is encoded as a change set
of tasks, the person reviews it, and it is released into the project's task tracker (`br`).
Both the Mac app and the phone companion show this flow.

**State as of 2026-10-15 (master `3416e35e`).** Every claim was checked against the code at that
commit. Where something could not be verified, the doc says so.

**Audience:** agents (and the maintainer) who will keep changing the feature and its UI. Read sections 1
and 8 before you change anything. Keep this doc current when you land a change. It replaces
`docs/HANDOFF-plan-notes.md`, which is now a pointer to section 6.

**Two meanings of "Flight Control".** In this doc, and in the coverage, mobile and FLYWHEEL
docs, the name means the planning pipeline:
- `Sources/IntakeKit/*.swift` (top level);
- `Sources/FlightDeck/Intake/`;
- the phone's intake screens.

The Level 3 docs, `FLIGHT-CONTROL-L3-CHECKLIST.md`, and the Settings pane named "Flight Control"
use it for something else: task routing, the capability index, usage and the swarm. That code is
in `Sources/IntakeKit/FlightControl/` and `Sources/FlightDeck/FlightControl/`, and this doc does
not cover it.

---

## Contents

1. [Map: where things are](#1-map-where-things-are)
2. [The pipeline and its states](#2-the-pipeline-and-its-states)
3. [The Mac UI](#3-the-mac-ui)
4. [The phone UI and the wire](#4-the-phone-ui-and-the-wire)
5. [Agents and models](#5-agents-and-models)
6. [Plan notes](#6-plan-notes)
7. [Known open issues and in-flight work](#7-known-open-issues-and-in-flight-work)
8. [How to work on it](#8-how-to-work-on-it)
9. [Design principles](#9-design-principles)
10. [Other docs, and which are stale](#10-other-docs-and-which-are-stale)

---

## 1. Map: where things are

| Area | Where |
|---|---|
| Engine (pure, Swift 6, Foundation only) | `Sources/IntakeKit/`: `Intake.swift`, `Triage.swift`, `RoundConfig.swift`, `TapePlanner.swift`, `RoundParticipants.swift`, `RoundExecutor.swift`, `RoundPrompts.swift`, `IntakeRunner.swift`, `Tape.swift`, `TapeStore.swift`, `PlanLayers.swift`, `PlanMetrics.swift`, `ConvergenceSeries.swift`, `CoverageSeries.swift`, `CrossCheck.swift`, `ChangeSet*.swift`, `ApplyPlanner.swift`, `DeliveryPlanner.swift`, `ReleaseSummary.swift`, `PlanNote.swift`, `NoteVersion.swift` |
| Agents | `Sources/IntakeKit/AgentID.swift`, `Agents/*Profile.swift`, `Headless.swift`, `ModelOptions.swift` |
| App orchestration | `Sources/FlightDeck/Intake/IntakeService.swift` (`@MainActor`, about 2,500 lines). It is the only part of the app that starts triage, spawns runners and releases. |
| Runner process | `flightdeck intake run <id> --root` (`Sources/FlightDeckTool/main.swift`), spawned by `IntakeRunnerController.swift` |
| Mac UI | `Sources/FlightDeck/ProjectView.swift`, `Sources/FlightDeck/Intake/*.swift`, `Intake/Planning/*.swift`, `Intake/Planning/PlanEditor/*.swift` |
| Phone projection (Mac side) | `Sources/FlightDeck/Fleet/IntakeDetailProjection.swift`, `IntakePlanProjection.swift`; dispatch in `Fleet/FleetService.swift` |
| Wire | `Sources/FleetKit/IntakeWire.swift`, `Frames.swift`, `TimelineFrames.swift`, `PlanBlocks.swift` |
| Phone UI | `Sources/FlightDeckMobile/Intake*.swift`, `FlightControlModel.swift`, `RoundInspector*.swift`, `RoundEditor*.swift`, `RoundDetailScreen.swift`, `Plan{Reader,Outline}Screen.swift`, `Note{Sheet,Composer}.swift`, `BoardStrip*.swift`, `TransportKeys.swift` |
| Tests | `Tests/FlightDeckTests/Intake/` (and `Intake/Planning/`); `Tests/FlightDeckMobileTests/`; `UITests/FlightDeckUITests/PlanningInspectorUITests.swift` |
| Real user data (read-only) | `~/Library/Application Support/Flight Deck/intakes/<uuid>/` |
| Background | `docs/ARCHITECTURE.md`, section "Intake" (line 2033 onward) |

---

## 2. The pipeline and its states

### 2.1 `IntakeState` (`Sources/IntakeKit/Intake.swift`)

The 12 cases are `triaging`, `needsAnswers`, `awaitingChoice`, `parked`, `review`, `releasing`,
`released`, `partiallyReleased`, `failed`, `interrupted`, `discarded` and `shaping`.
`needsAttention` is true for `needsAnswers`, `awaitingChoice`, `review`, `partiallyReleased`,
`failed` and `interrupted`.

`IntakeService` makes every transition:

| From | Event | To |
|---|---|---|
| (new) | `capture` | `triaging`, then `runTriage(.initial)` |
| `triaging` | triage returns questions | `needsAnswers`. `answer()` runs `runTriage(.answers)`. |
| `triaging` | triage recommends Single task and returns a change set | `review` |
| `triaging` | triage recommends any other fidelity | `awaitingChoice` |
| `awaitingChoice`, `review`, `parked` | `choose(.bead)` with a change set | `review` |
| same | `choose(.bead)` without a change set | `runTriage(.encodeNow)` |
| `awaitingChoice`, `parked` | `choose(other)` then `PresetExpansion.config` then `beginShaping` | `shaping` |
| `shaping` | the runner reaches review (`finishShaping`) | `review` |
| `review` | `release` | `releasing`, then `released` or `partiallyReleased` |
| any | `fail()` | `failed`. A release refused before any write goes back to `review`. |
| `failed`, `interrupted` | `retry` | resumes `shaping` if it had a config. Otherwise triage starts again, and the Q&A is cleared. |
| `triaging`, `releasing` at launch | recovery | `interrupted` |

- `discard` is refused while `releasing`. From `shaping`, it appends `.stop` first.
- **`.parked` is never assigned by current code.** It is only read, so treat it as legacy.

### 2.2 Triage

Triage runs in the app process, not in the runner. `IntakeService.runTriage` uses `HeadlessRunner`
(`Sources/FlightDeck/Intake/HeadlessRunner.swift`), which builds its command with
`HeadlessCommand.build`.

- **Types** (`Sources/IntakeKit/Triage.swift`):
  - `TriageResult` is `.questions([String])` or `.recommendation(preset:reason:changeSet:)`.
  - `enum Triage` holds the schema and the prompts: initial, answers, correction and encodeNow.
  - `TriageExchange` (`Intake.swift`) holds one round of questions and answers.
  - `HeadlessSession` (`Intake.swift`) is stored under the JSON key `harness`. The key is legacy; do not rename it.
- **Files:** `<intake>/triage/{graph.json, bv.json, schema.json}`. Unsent answers go to
  `<intake>/answer-drafts.json`, written with a 400 ms debounce.
- **Validation:** a change set that fails validation gets one correction turn. A second failure
  sets the intake to `failed`.

### 2.3 Presets and `PresetExpansion`

`Preset` (`Intake.swift`) has the cases `bead`, `sketch`, `featurePlan` and `fullPlan`. The UI
says "Single task", "Sketch", "Feature plan" and "Full plan" (`UIText.presetName`). Agents are
offered `singleTask`, which decodes to `.bead`. Storage and the wire still write `bead`.

`PresetExpansion.config(for:available:)` (`Sources/IntakeKit/RoundConfig.swift`) builds the
starting `RoundConfig`. It returns nil for Single task.
- **Seats:** A is Codex if detected, else Claude. B is Claude if detected, else A.
- **Integrator:** `claude ?? A`. **Encoder:** always A.
- **Cross-reviewer:** Gemini, else Grok, else B (B only when two families exist).

| | Sketch | Feature plan | Full plan |
|---|---|---|---|
| Drafters | 1: A `.general` | 2: A `.arbiter`, B `.realist` | 4: A `.arbiter`, B `.realist`, Gemini (else A) `.coverage`, Grok (else B) `.stressTest` |
| Synthesizer | none | A | A |
| Reviewer / refine rounds | A / 2 | A / 3 | A / 5 |
| Polisher / polish rounds | none / 0 | `claude ?? A` / 2 | `claude ?? A` / 6 |
| Fresh eyes and dedup | no | no | yes |
| Default play | `.toReview` | `.nextMajor` | `.nextMajor` |
| Cross-check | `.off` | `.firstAndLast` | `.firstAndLast` |

- **Rotations:** these apply only when A and B are different families.
  - reviewers: `[A (fallback B), B (fallback A)]`;
  - integrators: `[B, A]`;
  - polishers: `[B, Gemini?, A]`.
- Grok never reviews and is in no rotation, because it is slow. In a live round it took 745 s
  against 42 to 73 s for the others.
- OpenCode is never seated by a preset. The Rounds editor offers it.

### 2.4 Stages

`Stage` (`Sources/IntakeKit/Tape.swift`) has the cases `draft`, `synthesis`, `refine`, `encode`,
`polish`, `freshEyes` and `dedup`, in run order. A cross-check is a flag on a refine round, not a
stage. `RoundExecutor` implements each stage:

- **draft:** the drafters run in parallel. A failed drafter gets one try with its fallback. The
  round pauses only when no draft survives. Writes `drafts/<i>.md`.
- **synthesis:** the synthesizer proposes edits to draft 0, in light of the other drafts. Integrator 0 applies them.
- **refine:** each round starts a fresh reviewer session.
  - The integrator then edits `work/plan.md` (`HeadlessAccess.writeInWork`).
  - Zero proposals skips the integrator; that is the convergence signal.
  - If the integrator claims to agree but the plan did not change, the round pauses with `invalidOutput`.
  - **Cross-check round:** the reviewer and a cross-reviewer from another family run in parallel. The cross-reviewer has no fallback and never pauses the round. Proposals are interleaved blind (`BlindOrder`), duplicates are clustered, and `crosscheck.json` is written.
- **encode:** the encoder turns the plan into a `ChangeSet` and validates it. A failure gets one correction turn.
- **polish, freshEyes, dedup:** each returns a whole revised change set, checked against encode's `graph.json`.
  - FD builds a `ShadowGraph` and runs `bv` on it itself; the agent never runs `bv`.
  - All three use the polisher rotation.

### 2.5 `RoundConfig` (`Sources/IntakeKit/RoundConfig.swift`)

- **Seats:**
  - `drafters [Slot]`, `synthesizer Slot?`, `reviewer Slot?`;
  - `integrator`, `encoder` and `polisher?`, each a `ModelChoice`.
  - A `Slot` is a `choice` plus a `persona` plus an optional `fallback`. The fallback covers availability failures, not quality.
- **Caps and flags:** `refinementCap`, `polishCap`, `freshEyesAndDedup`, `defaultPlay`
  (`PlayMode`: `step | nextMajor | toReview`) and `customized`. `customized` is set by any edit.
- **Rotations:** `reviewers`, `integrators` and `polishers`, all optional.
  - Refine round k runs `reviewers[(k-1) % n]` and `integrators[(k-1) % n]`.
  - Polish round i runs `polishers[i % n]`. Fresh eyes is index `polishTotal` and dedup is `polishTotal + 1`.
  - Synthesis uses integrator 0.
  - The single fields stay equal to entry 0, so readers from before rotations still work.
- **Cross-check:**
  - `crossReviewer` plus `crossCheck: CrossCheckPolicy?` (`off | firstAndLast | every`). nil reads as off.
  - `crossReviewer(rotation:)` swaps to another family when the round's reviewer is the same family as the cross-reviewer.
  - `RoundParticipants.crossChecks(round:of:config:)` decides which rounds cross-check. "Last" moves when the stage is extended. A round keeps its decision once it starts (`roundInProgress.crossCheck`).
- **Per-role accounts:**
  - `ModelChoice.account: AccountChoice?` is stored under the JSON key `accountOverride`. The older `account` key is deliberately ignored.
  - At each runner spawn the app resolves accounts and leases into `<intake>/accounts.json` (`RunnerAccounts`). The runner only reads that file.
  - A seat with no entry pauses rather than bill a guessed login.
- **Model menus:** `AvailableModels` lists, in order of preference:
  1. the per-account list;
  2. the project default list;
  3. the ids found at detection;
  4. the profile's aliases.

  `effortValues` and `selecting(agent:model:from:)` keep the effort valid when the model changes. `modelLabel` gives "Claude > Opus 5.5". See section 5.

### 2.6 The engine: planner, participants, executor, runner

- **`TapePlanner`** (`TapePlanner.swift`) is stateless.
  - Each call rebuilds the whole sequence: draft, synthesis?, refine 1..N, encode, polish 1..M, freshEyes, dedup. It uses the config plus the tape's `extraRefinement` and `extraPolish`.
  - It finds the head by `(stage, round)`. If the head is no longer in the sequence, `next` returns nil, which sends the tape to review rather than guessing.
  - Also: `plannedRounds` (the Rounds timeline draws from this), `upcoming`, `satisfies`, `apply`.
- **`RoundParticipants`** (`RoundParticipants.swift`) answers "who runs this round". The planner, the live card, the Rounds editor and the phone all derive it the same way through it.
- **`RoundExecutor`** (`RoundExecutor.swift`) runs one round.
  - It returns `.checkpoint` or `.paused(Diagnosis, partialRecord)`, and throws only `CancellationError`.
  - It writes only `runs/` and `work/`, never the tape.
  - `FailureDiagnosis` sorts failures into `rateLimited`, `authExpired`, `timeout`, `harnessError` and `invalidOutput`.
  - Agents with no native schema support get one `SchemaRepair` retry.
- **`IntakeRunner`** (`IntakeRunner.swift`) is a separate process. `IntakeRunnerController` spawns it detached under `fd-abduco` and judges it alive by heartbeat.
  - It holds a `flock` on `runner.lock`.
  - Its private actor `TapeKeeper` is the **only writer** of `tape.json`, `checkpoints/` and `plan.user.md`.
  - It reads `intake.json` but never writes it; the app owns that file.
- **Commands:** the app and the phone only append `TapeCommand`s to `commands.jsonl`. Each line is a `CommandEnvelope{seq, command}`, and the runner acks with `tape.ackedCommandSeq`.
  - Cases: `step`, `nextMajor`, `toReview`, `pause`, `stop`, `extend(Stage, by:)`, `trim(Stage, by:)`, `note(PlanNote)`, `removeNote(UUID)`, `setNoteKind(UUID, NoteKind)` and `editPlan(checkpoint:markdown:)`.
  - The legacy `annotate` decodes only, and maps to `note(.legacy)`.
  - A runner drops a line it does not know.
- **Optimistic UI:** `TapeOverlay` (Mac) folds unacknowledged transport commands into the published tape so a click shows at once. Nothing is written to disk.
- **Status:**
  - `RunnerStatus`: `idle`, `running`, `paused`, `failed`, `reachedReview`, `stopped`.
  - `TapeTarget`: `none`, `nextMinor`, `nextMajor`, `review`.

### 2.7 On disk

The data lives in `~/Library/Application Support/Flight Deck/intakes/<uuid>/`. A Debug build uses
"Flight Deck (Debug)", and `-FlightDeckStateDir` overrides the location.

| File | Writer |
|---|---|
| `intake.json`, `archived` (marker), `answer-drafts.json`, `accounts.json`, `triage/` | app |
| `commands.jsonl` | app and phone (append only) |
| `tape.json`, `runner.lock`, `checkpoints/<n>/` | runner |
| `checkpoints/<n>/`: `drafts/<i>.md`, `plan.md`, `plan.user.md`, `changes.json`, `verdicts.json`, `crosscheck.json`, `changeset.json`, `graph.json` | runner |
| `work/` (with `carry/`, `shadow/`), `runs/<stage>-<round>-<role>…/` (`run.json`, `stdout`, `stderr`, `activity.json`, `result.json`) | executor |
| `intakes/model-lists/<agent>-<key>.json` (shared, not per intake) | app |

`TapeStore` writes a checkpoint's files before it saves the tape.

### 2.8 Human edits (`Sources/IntakeKit/PlanLayers.swift`)

- `plan.md` is what the agents generated. Nothing modifies it. `plan.user.md` is the person's
  whole edited copy. The **effective plan** is the user copy if one exists, else the generated
  plan. The next round reads the effective plan of the head checkpoint.
- An edit equal to the generated text deletes the layer. `revert(hunk)` undoes one hunk.
- An edit made while a round runs is merged three ways onto the round's new plan
  (`carryForward`, `git merge-file -p`). A conflict leaves the edit where it was and sets
  `RoundRecord.editConflict`. After each round, `lostEditedLines` warns if the round dropped
  lines the person edited.
- All comparison goes through `MarkdownUnwrap`.

### 2.9 Convergence and coverage

- **`PlanMetrics`** computes the diffs (Myers): `delta`, `sectionChurn` (heading to changed
  lines, with renames folded), `hunks`, `unifiedDiff`, and ops and edges changed.
- **`ConvergenceSeries`** builds one `ConvergencePoint` per refine or polish round. A point holds
  changes, churn, the agree ratio, section churn, the reviewer model, repeats, reopens and the
  cross-check flag.
  - `ConvergenceVerdict` is `tooEarly`, `converging`, `plateau` or `diverging(…)`.
  - The thresholds are marked as untuned placeholders.
- **`CoverageSeries`** reads each `crosscheck.json` and applies Chapman's capture-recapture
  estimate.
  - `CoverageBand` is `saturated`, `fewLeft`, `manyLeft`, `noOverlap`, `sameFamily` or `unmeasured`.
  - `CoverageTarget`: Feature plan aims for FEW LEFT or better, and Full plan for SATURATED and independent.

### 2.10 Encode, the change set, and release

- **`ChangeSet`** (`ChangeSet.swift`) is `{graphObservedAt, ops}`. The `ChangeOp` cases are
  `createBead`, `addEdge`, `editBead`, `reopen` and `followUp`.
  - On the wire, ops are `createTask`/`editTask`, and the old names still decode.
  - `EdgeKind` is `blocks`, `related` or `parent-child`.
  - `DeliveryRating` is `clarifying`, `scopeChange` or `invalidating`.
- **`ChangeSetValidator`** checks for unknown ids, undefined or duplicate temp ids, self edges,
  cycles, missing delivery ratings and precondition mismatches. An edge from an existing task
  onto a new one is held to the end of the release (`heldOpIndices`).
- **`DriftClassifier`** compares each op's precondition with the live graph. The result is
  `holds`, `drifted` or `impossible`.
- **Release** (`IntakeService.runRelease`):
  1. Re-read the graph and classify drift.
  2. Apply the person's drift confirmations and drops, then re-validate.
  3. `ApplyPlanner.plan` orders the steps: creates, edges, edits, reopens, held edges.
  4. `BeadWriter` (`Sources/FlightDeck/Intake/BeadWriter.swift`) runs the `br` CLI with `--actor flightdeck-intake:<id>` and stops at the first failure.
  5. `DeliveryPlanner` and `IntakeDelivery` tell the holders of in-progress tasks: `am mail send`, prompt injection into a live session, or reclaim. A delivery failure is only a warning.
  6. `ReleaseRecord` is saved into the intake.

---

## 3. The Mac UI

### 3.1 `ProjectView`, the intakes list, the rail, and the composer

- **`ProjectView`** (`Sources/FlightDeck/ProjectView.swift`) is keyed by `Repo`, so its `@State`
  resets on every project switch. Anything that must survive a switch lives in `IntakeService`.
  - Layout: the intakes column on top of a detail pane. The pane shows one of `ExpandedIntakeComposer`, `IntakeDetailView(…).id(intake.id)`, or "Select an intake".
  - Toolbar: the inspector toggle, ⌥⌘I.
  - The list column is 280 to 420 pt wide and resizable. **Its width is not persisted.**
- **List** (`IntakeRow.swift`, `IntakeStatePill.swift`, `IntakeTitle.swift`):
  - Each row shows a state pill and a title. `IntakeTitle` cuts the title at 72 characters on a sentence, clause or word boundary.
  - Context menu: Archive ⌃⌘A (with undo), Move to Trash… ⌘⌫, Show in Finder. A footer has "Show Archived".
- **Collapsed rail** (`IntakeRail.swift`): one disc per intake, with a hover card. ↑/↓ move, and
  Return or Space selects. "+" opens the composer in a popover.
- **Composer:**
  - The inline composer is `IntakeComposer`, defined in `IntakeRail.swift`.
  - The expanded one is `ExpandedIntakeComposer.swift`. It takes over the detail pane, up to 820 pt wide.
  - Both use `ComposerEditor`, which wraps `PlanTextView`, so the composer is the plan editor. Triage is ⌘↩.
  - **Durable draft:** one draft per project, shared by all three surfaces. It is kept in UserDefaults `IntakeDraftByProject`. The expanded flag is in `IntakeComposerExpandedByProject`.
  - The expanded composer's scroll and caret memory is `IntakeService.composerScroll(forProject:)`, kept in memory only.

### 3.2 State and where it lives

| State | Where | Lifetime |
|---|---|---|
| Selected intake per project | `IntakeService.selectedIntake`, UserDefaults `IntakeSelectionByProject` | persisted |
| Inspector shown per project | `inspectorProjects`, `IntakeInspectorByProject` | persisted |
| List collapsed / show archived per project | `IntakeListCollapsedByProject`, `IntakeListShowArchivedByProject` | persisted |
| Composer draft / expanded per project | `IntakeDraftByProject`, `IntakeComposerExpandedByProject` | persisted |
| Inspector mode per **intake** | `InspectorModeStore` (`Planning/InspectorModeStore.swift`), `IntakeInspectorModeByIntake` | persisted; `forget` on discard |
| Unsent answers | `<intake>/answer-drafts.json` | persisted |
| Default play | `intake.roundConfig.defaultPlay` in `intake.json` | persisted |
| Rounds edits while shaping | `IntakeService.roundConfigDrafts` | memory, until Save |
| Rounds edits and chosen fidelity **before** shaping | `IntakeDetailView` `@State editedConfig`, `selectedPreset` | **lost on intake switch** |
| Folds | `IntakeService.planFoldStores[id]` (`PlanFoldStore`, `PlanOutline.swift`) | memory; dropped when shaping ends |
| Reading position and caret | `IntakeService.planScrollMemories[id]` (`PlanScrollMemory`, `PlanReadingAnchor.swift`) | memory; never pruned |
| Edit router (pending plan edit) | `IntakeService.editRouters[id]` | memory |
| Which board labels already flapped | `IntakeService.flapPolicies[id]` (`FlapPolicy`) | memory |
| Notes rail other-versions open or closed | `PlanNotesController.versionSectionChoices` (static) | memory |
| Live seat activity | `IntakeService.seats` (`SeatFeed`, a separate observable so seat beats don't redraw everything) | memory |
| Everything else in the detail view | `IntakeDetailView` `@State` | reset per intake (`.id(intake.id)`) |

`IntakeService`'s published state includes `intakes`, `archived`, `tapes` (with the overlay),
`availableModelsCache`, `modelLists`, `convergence`, `coverage`, `pending`, `halts` and
`editConflicts`.

### 3.3 `IntakeDetailView`: the board, the live card, seats and rounds

`Sources/FlightDeck/Intake/IntakeDetailView.swift` is one scrolling document. `DetailLayout.sections`
(`Planning/DetailLayout.swift`) picks which parts appear:
- the header (with the `ProgressSummary` line);
- clarifications;
- the live card;
- the stage body (questions form, fidelity picker, review counts and drift, released, failed);
- the plan;
- a pinned action bar.

When the control bar and board scroll off the top, a pinned copy appears under the toolbar, without
the heatmap.

| Piece | Files | What it shows |
|---|---|---|
| Control bar | `Planning/ControlBar.swift`, `LCDModel.swift`, `TransportRules.swift` | Transport (Back · Pause \| Step · Next major · To review \| Stop), the LCD (round, elapsed, agents done, so far, billed, convergence, coverage, stops at), Extend, Annotate. `TransportRules` is shared with the phone. |
| Run menu | `Planning/RunMenu.swift` | AppKit menu: Step ⌘', Next Major ⇧⌘', To Review ⌥⌘', Pause ⇧⌘., Stop ⌘., Extend ⌘=, Remove a Round ⌘-, Annotate ⌥⌘A, Section Heatmap |
| Departures board | `Planning/DeparturesBoard.swift`, `BoardModel.swift`, `SplitFlapText.swift`, `FlapPolicy.swift`, `LabelFit.swift` | NOW / IN THE AIR / STOPS AT / CALLING AT, then the tape of slots (CLR, DRFT, SYN, RF{n}, ENC, PL{n}, FRSH, DDUP, REV) with groups and +/− handles that send extend and trim. `LabelFit` picks the full name or the code. |
| Live card | `Planning/LiveCard.swift` | Control bar, board, pause and edit-conflict banners, "N notes queued", seat rows, finished rounds. One 1 Hz `TimelineView` drives every clock. |
| Seat rows | `Planning/SeatRow.swift`, `SeatRowModel.swift`, `AgentStack.swift` | One row per agent: role, model, headline, footprint chips, context gauge, time, result, cost |
| Round chips | `Planning/RoundChip.swift`, `RoundTimeline.swift`, `FinishedRounds*.swift` | Finished-round cards with one detail panel; the timeline chips in the Rounds editor |
| Floating cards | `Planning/FloatingCard.swift` | Hover cards in a non-activating child panel (`CardPlacement`). The notes selection toolbar uses it too. |

### 3.4 The convergence card and the section-churn heatmap

- `Planning/ConvergenceCellModel.swift`:
  - `ConvergenceCellModel` holds the verdict (TOO EARLY, CONVERGING ↘, PLATEAU →, DIVERGING ↗), the sparkline, discontinuities and hollow cross-check points.
  - `HeatmapModel` has one row per section with churn and one column per round ("R1", "R1 ×2" for a cross-check). Its title is "SECTION CHURN · REFINE ×N".
- `Planning/ConvergenceViews.swift`: `ConvergenceCard`, and `ConvergenceHeatmap`, an inline disclosure inside the board.
  - Clicking a cell selects that checkpoint and shows its Diff vs Previous, scrolled to that section's first change (see 3.7).
  - Esc closes the heatmap.
  - `ChurnLaneView` draws the churn lane beside the plan.
- **Labels on master:** `ConvergenceSeries.label` gives "§N" for a numbered heading, but the
  **whole heading** for an unnumbered one. That text goes into a 30 pt badge column. This is the
  bug the `heatmap-names` branch fixes (section 7).
- Coverage: `Planning/CoverageCellModel.swift` and `CoverageViews.swift` show the band words
  (SATURATED, FEW LEFT, MANY LEFT, NO OVERLAP, STALLED) and the target line.

### 3.5 Inspector modes

- There are two modes, in `DetailLayout.InspectorMode`: **Notes** (⌥⌘1) and **Rounds** (⌥⌘2). A
  Single task offers Notes only.
- The default is the stored mode if the plan still offers it, else Rounds, else Notes.
- `InspectorContent` is one of `roundsEditor`, `roundsRecord`, `seat` (a single agent with
  "‹ Rounds"), `notesRail`, or a placeholder.
- Files:
  - `Planning/DetailInspector.swift` (`SeatInspector`, the placeholders);
  - `InspectorMenu.swift` (View ▸ Inspector menu, `PaneMenus`);
  - `InspectorModeStore.swift` (per intake, persisted).
- The inspector column is 300 to 640 pt wide.

### 3.6 The Rounds editor

- **Editor:** `Sources/FlightDeck/Intake/RoundConfigEditor.swift`.
  - One disclosure row per stage, with a chip flow. Only one stage is open at a time.
  - **Each role is one aligned `Grid`** (since `7c6ad21c`). Rows are "Model" or "Turn N", then Account, Fallback, Account. Columns are the label, the agent badge, the model menu (one submenu per agent, plus "Other…" for a custom id), effort (only when the model has levels), and the rotation controls.
  - "Add an agent to alternate" and "Use one agent" manage rotations.
  - The cross-check picker (Off / First and last / Every round) sits under the reviewer. Refine and Polish have round steppers. Default play is at the bottom.
  - The editor also shows notes for unavailable agents and a "Check again" button.
- **Account:** a per-role picker ("Project default — X", accounts, pools), shown only where the
  agent has a real choice. Otherwise it says "Set per project in Settings → Projects."
  (`PlanningAccounts.swift`).
- **While shaping:** `ShapingRoundsPanel.swift` edits `roundConfigDrafts`, with Revert and Save.
  It says "Pause to change agents." `ShapingEdit.swift` decides what is still editable after
  rounds have run: locked slots and floors on refine and polish.
- Before shaping, the editor edits `@State editedConfig` in the detail view (see 3.2).

### 3.7 The plan editor (`Intake/Planning/PlanEditor/`)

`PlanTextView.swift` (`PlanNSTextView`, TextKit 2) is the plan editor, and the composer uses it too.

- **Typography** (`MarkdownStyler.swift`, `PlanTheme.standard`):
  - Body text is the system serif (New York) at 16 pt. Headings stay in the system sans: 24/20/17/15.
  - `lineSpacing` is 8, `paragraphSpacing` 9 and `itemSpacing` 4.5.
  - It uses `lineSpacing`, not `lineHeightMultiple`, so the caret stays the height of the text.
  - Code is 13 pt mono.
  - A comment near line 84 still quotes the old 18 pt figures.
- **Tables are always grids:**
  - `PlanTableEditing.swift` is the pure edit model. It has no views and handles mapping, edits, structure, navigation, copy and where diff marks go.
  - `PlanTable.swift` and `PlanTableGrid.swift` handle layout and cell text.
  - `PlanTableController.swift` draws the caret and selection inside cells and handles keys, mouse and the context menu (insert/delete row or column). It also covers accessibility.
  - An edit that would break the table is refused.
  - **The source is never shown under the caret.** See `PlanTextView.swift` around line 457.
- **Inline diffs in tables** (`PlanTableMarks.swift`): struck words are drawn in their cell,
  removed rows as ghost rows in place, and inserted text as row, cell or word tints.
- **Edit layer** (`EditLayer.swift`, `DecorationLayer.swift`): inserted text is tinted green. Deleted text is drawn struck through as ghosts, with gutter bars and an "N edits by you · Revert all" chip.
  - The editor commits when editing ends, or after 2 s idle.
  - `PlanEditRouter.commit` sends `editPlan(checkpoint:markdown:)`, which carries the whole Markdown.
  - If a newer head has landed, it retargets with a merge (up to 3 tries). A conflict keeps the edit on its own checkpoint.
- **Diff vs Previous** is this same editor, read-only (`PlanSection.swift`, `mode == .diff`), not a text diff:
  - It shows the round's plan in the normal typography, and the edit layer draws the round's changes over it: the base is the previous plan, instead of the generated plan under the human's edits. Marks, ghosts, gutter bars and in-grid table marks are the same as for human edits, so green and red here mean "this round changed it", and the bar above the plan names the pair ("Changes in Refine 2 since Refine 1").
  - **The base** is `ShapingModel.roundDiff`: both sides are the GENERATED plans (`planText`, never `plan.user.md`), and the previous side is the nearest earlier checkpoint that has a plan (`previousPlanCheckpoint`), so an encode or polish checkpoint is skipped. With no earlier plan there is no base, and the bar says "First version: nothing to compare". Following the head resolves to the newest checkpoint with a plan, as the Plan tab does.
  - **The jump:** a heatmap cell passes its section as a `PlanJump` (`PlanTextView.jump`). `EditLayer.firstChange` picks the first mark inside that section, else the ghost that removed its heading, else the heading, else the first mark of the plan; `Coordinator.jump(to:)` then uses the `reveal` machinery of "Show in that version", landing a margin below the pinned block. A removed passage's ghost is drawn above its anchor line, so the page goes to the line before it. Choosing a round, or switching to the tab, jumps to the round's first change; a new head landing moves nothing.
  - No reading-position memory, no churn lane, no editing. Folds are the plan's own store; notes are pinned as on any read-only version.
  - The old monospaced diff text (`coloredDiff`, `diffChunks`, `PageJump`) is gone, with no fallback to raw diff text. **Change set** mode still lists its ops as plain monospaced text (`ShapingModel.describe`); it shares none of the diff code.
- **Folding:**
  - Code: `PlanOutline.swift` (`PlanFoldKey`, which is heading text plus occurrence; `PlanFolds`; `PlanFoldStore`) and `PlanFolding.swift` (a layout-only filter and the gutter).
  - Display: a › or ⌄ chevron, and a "⋯ N lines" pill on a folded heading.
  - Keys: ⌥⌘← and ⌥⌘→. A reveal inside a fold opens it.
- **Reading-position memory** (`PlanReadingAnchor.swift`, `PlanReadingRestore.swift`):
  - The anchor is a paragraph plus an offset, and relocates on the next load.
  - It is saved 0.25 s after scrolling stops and when the editor leaves its window.
  - A restore hides the view until the position can be reached, for up to 1.5 s.
  - The caret is restored only if the editor had focus.
  - The position survives tab and project switches, but not a relaunch.
- **File drops** (`DroppedPaths.swift`):
  - On the plan, a drop inserts `[path](path)` links at the drop point as one undo step. Paths are relative to the project, or start with `~`. Several items become a list on an empty line.
  - On the new-note draft and the question answers, `.dropsFilePaths` appends plain paths.
- **Links** (`PlanLinks.swift`): ⌘-click opens a link. Holding ⌘ shows a tip with the target. `:42` and `#L42` suffixes are stripped. In-document `#anchor` links are not supported.
- **Outline and breadcrumb:** `PlanReadingPosition` shows "§ Title" in the pinned board's footer, and a click jumps there. `PlanFocus` is how a heatmap cell asks for a Diff at a section.

### 3.8 The notes rail

See section 6. Files: `PlanEditor/NotesRail.swift` and `SelectionToolbar.swift`.

### 3.9 Release review

- `ReleaseReviewView.swift` is a sheet titled "Release plan as tasks". It has three sections: New tasks, Edits and Dependencies.
  - A drifted row has Confirm and Drop buttons.
  - An edit to an in-progress task shows its holder, a rating picker and the planned delivery.
  - The footer shows "N notes carried into task notes".
  - The Release button text comes from `UIText.releaseButton`.
- `ReleaseSheetModel.swift` holds the text and counts. `ReleaseSummary.swift` (IntakeKit) holds the count line.
- The sheet closes only on `released` or `partiallyReleased`.
- Not verified: that `confirmedDrift`, `droppedOps` and `ratingOverrides` are saved to `intake.json` through `mutate`. It is likely, but `mutate` was not read.

### 3.10 Fixture for UI tests

`PlanningUIFixture.swift` is Debug only. Launch with `-FlightDeckPlanningFixture shaping
-FlightDeckResetState YES` to seed a temp state dir with one paused Feature plan that has notes.
`PlanningInspectorUITests` uses it. `-FlightDeckPlanningFixture synthesized` seeds a draft, a synthesis that
consumed notes, and two refines, each a long plan with tables (`NotesToolbarUITests`).

---

## 4. The phone UI and the wire

### 4.1 Screens (`Sources/FlightDeckMobile/`)

| Screen | Files | What it does |
|---|---|---|
| Intake row | `IntakeRow.swift` | Glyph, title, pill and one fact in the Sessions list |
| Intake screen | `IntakeScreen.swift`, `IntakeDetailModel.swift`, `IntakePresence.swift` | `BoardStrip` with transport keys (Stop asks first; a long press on a play key sets the default). Sections: questions ("Answer on your Mac for now."), clarifications, fidelity, review ("Review and release on your Mac for now."), failure, Rounds, agents, rounds (with −/+), plan. Polls every 1.5 s while visible, using an etag. |
| Fidelity chooser | `FidelityChooser` in `RoundInspectorModel.swift`, UI in `IntakeScreen.swift` | Sends `intake.choose`, or `intake.start` if the Rounds were edited |
| Round inspector and editor | `RoundInspectorScreen.swift`, `RoundInspectorModel.swift`, `RoundEditorModel.swift` (`RoundEditor`, pure), `RoundEditorView.swift` | Read-only by stage, or an editor when `RoundEditing.make` allows it. Choosing: "Start sends these rounds." Shaping: Revert and Save (`intake.rounds`). Shows provider icons and "Claude > Opus 5.5" names. |
| Round detail | `RoundDetailScreen.swift`, `RoundFacts.swift` | One landed round: facts, agents, sections changed (each links to the reader's changes), notes consumed |
| Plan outline | `PlanOutlineScreen.swift` | Sections with churn and note counts |
| Plan reader | `PlanReaderScreen.swift`, `PlanTableView.swift` (shared grid renderer) | Blocks from `PlanBlocks.split`, tables as grids, a Changes toggle, notes, other-version groups |
| Note sheet | `NoteSheet.swift`, `NoteComposer.swift` (`NoteComposer`, `NoteOutbox`) | Quote, kind chips, text. The outbox keeps sent notes visible until the plan shows them. |
| Clarifications | `ClarificationsScreen.swift` | Answered Q&A, read-only |
| Model | `FlightControlModel.swift`, `IntakeCommands.swift` | Banners, one detail and one command model per intake, a plan cache of 4. Commands time out after 10 s and reuse their token within 60 s. |

`PlanReviewScreen` and `PlanReviewModel` are the Plannotator plan gate for sessions, not Flight
Control.

### 4.2 Wire (`Sources/FleetKit/`)

- **Requests** (`TimelineFrames.swift`): `intake.detail(id, ifNot: etag)` and
  `intake.plan(id, checkpoint?, changes)`. A request is safe on any Mac: an unknown request gets
  `err unsupported`.
- **Replies:** `WireIntakeDetail` and `WireIntakePlan`.
- **Event:** `project.intakes`, which carries `WireProject.intakes`.
- **Commands** (`Frames.swift`, `FleetCommand`):

| Op | Fields | Gate |
|---|---|---|
| `intake.tape` | command, stage? | `steer` |
| `intake.defaultPlay` | mode | `steer` |
| `intake.note` | noteID, kind, text, checkpoint?, block?, quote? | `steer` |
| `intake.removeNote` | noteID | `steer` |
| `intake.setNoteKind` | noteID, kind | `noteKind` |
| `intake.choose` | preset | `choose` |
| `intake.start` | preset, config, base | `editRounds` |
| `intake.rounds` | config, base | `editRounds` |

- **Wire types** (`IntakeWire.swift`):
  - The core: `WireIntakeSummary`, `WireIntakeDetail`, `WireBoard`, `WireControls`, `WireRound`, `WireNote` (with optional `checkpoint` and `version`).
  - Rounds: `WireRoundConfig`, `WireRoundsMenu`, `WireRoundsLock`, `RoundsRefusal`.
  - Others: `WireQuestions`, `WireChoice`, `WireFailure`, `WireIntakePlan`.
- **Capability flags** are all on `WireIntakeDetail`:
  - The flags are `steer`, `choose`, `noteKind` and `editRounds`.
  - The payloads are `roundConfig`, `roundsMenu` (while choosing or shaping) and `roundsLock` (while shaping).
  - The Mac sets them in `Sources/FlightDeck/Fleet/IntakeDetailProjection.swift` (around line 148).
  - The phone checks them in `TransportKeys`, `NoteComposer.notesAllowed` and `canRetype`, `FidelityChooser.options` and `RoundEditing.make`.
- **Handlers** (`IntakeService.phone*`, about lines 1206 to 1427, dispatched from `FleetService.swift`):
  - The handlers are `phoneTape`, `phoneDefaultPlay`, `phoneChoose`, `phoneStart`, `phoneRounds`, `phoneNote`, `phoneRemoveNote` and `phoneSetNoteKind`.
  - Each returns nil (ack) or an error code. Codes: `unknown_intake`, `intake_moved_on`, `not_allowed`, `unknown_command`, `unknown_mode`, `unknown_preset`, `no_agents`, `rounds_changed`, `invalid_config`, `unknown_kind`, `empty_note`, `unknown_checkpoint`, `unknown_block`, `note_consumed`, and `refused: <sentence>`.
  - Each handler remembers the last 16 tokens, so a retry is idempotent.
  - The phone's words for each code are in `CommandCopy.message`.

### 4.3 The rule: every new op is gated

An older Mac **drops the phone's socket** on a command op it does not know:
- `FleetSocket.swift` (around line 173) ends the connection on a frame it cannot decode.
- `FleetSocketServer.onUndecodable` (around line 1013) salvages only `req` frames.

So a new phone command needs all three of these:
1. a new op;
2. a new capability flag on `WireIntakeDetail`, set by the Mac that handles the op;
3. a phone that sends the op only when the flag is true, and otherwise offers nothing or says "on your Mac".

Do this even when it looks like a field on an existing op would do. `intake.start` is a separate op
from `intake.choose` for this reason: an old Mac would otherwise start the stock config and ignore
the edit. Requests are safe, because an unknown request gets an error reply.

---

## 5. Agents and models

### 5.1 Profiles

- `AgentID` (`Sources/IntakeKit/AgentID.swift`) has the cases `claude`, `codex`, `grok`, `gemini`
  and `opencode`. The raw values are a storage format.
- `planningOrder` is codex, claude, grok, gemini, opencode.
- `AgentProfile` (`Agents/AgentProfile.swift`) is pure: it spawns nothing. It holds:
  - the binary;
  - a read-only `signInCheck`;
  - a `modelCatalog`;
  - `parseModelList`;
  - `hasNativeSchema`;
  - error classification;
  - `environment(base:account:)`.

`HeadlessCommand.build` (`Headless.swift`) builds each command line.

| Agent | Binary | Default planning model | Read-only planning seat |
|---|---|---|---|
| Claude (`ClaudeProfile`) | `claude` | `opus` / high | `--permission-mode dontAsk`, tools `Read Grep Glob Bash` with only `br list/show/graph/ready` allowed, `br` write verbs denied, `--restricted --strict-mcp-config` |
| Codex (`CodexProfile`) | `codex` | `gpt-6-sol` / high | `exec -s read-only --ignore-user-config --ignore-rules --disable hooks --output-schema` |
| Grok (`GrokProfile`) | `grok` | `grok-4.7` / medium | `--permission-mode dontAsk --tools read_file,grep,list_dir` plus `--deny` for Edit, Write, Bash, web, MCP, and reads of `.git` and the task tracker's data directory |
| Gemini (`GeminiProfile`) | `agy` (Antigravity) | `gemini-3.8-flash-high` (since `827cc205`) | `--project flight-deck-planning` (since `3416e35e`): an FD-owned agy project written by `GeminiPlanningProject.swift` to `~/.gemini/config/projects/`, never agy's own settings. It allows `read_file` anywhere plus reading commands, and denies every writer by name. No `--sandbox` (agy 1.3.6 hid outside directories under it and it was no write boundary). `--disable-slash-commands`; never `--mode plan`, never skip-permissions. Refuses any model not starting with `gemini-`. Checks sign-in before running. |
| OpenCode (`OpenCodeProfile`) | `opencode` | none (CLI default) | a generated `flightdeck-readonly` agent: `"*": deny`, with read, grep, glob and list allowed |

- **Planning seats are read-only.** Only the integrator seat may write, and only inside the work
  directory (for example, Claude `acceptEdits` with `Read Edit Write`, and Codex `workspace-write`
  with no extra roots).
- A denied Gemini tool ends the turn with no answer. `GeminiProfile` now names the refused tool in the diagnosis (`FailureDiagnosis`).

### 5.2 Detection (`IntakeService.available`, `TriageSettings.available`)

- **Codex and Claude** count as available if their binary is on the login-shell PATH. There is
  **no sign-in check**.
- **Grok, Gemini and OpenCode** must also pass `signInCheck` (20 s timeout). A failure goes into
  `AvailableModels.unavailable` with a hint that the editor shows.
- **Re-checks:** `recheckAgents()` runs at launch, on "Check again", and on app activation. The
  activation re-check runs only while an agent is signed out, and at most once a minute.
- `IntakeDetailView` re-seeds a plan's config when detection changes, unless the config is
  customized (`1136444c`).

### 5.3 Model lists (`Sources/IntakeKit/ModelOptions.swift`, `Sources/FlightDeck/Intake/ModelListRefresher.swift`)

| Agent | Source |
|---|---|
| Claude | The newest `<config dir>/cache/model-catalog/*-cc.json`. Also `claude -p /model --output-format json --no-session-persistence` from a temp directory, accepted only when it reports `local_command: model` and costs 0. Without a catalog it probes candidate ids one at a time. |
| Codex | `<CODEX_HOME>/models_cache.json` (`slug`, `display_name`, `visibility == "list"`, reasoning levels) |
| Grok | `grok models` at detection |
| Gemini | `agy models` at detection (`<id>\t<name>`) |
| OpenCode | `opencode models --verbose` at detection |

- **Per-account cache:** `ModelListStore` at `<state dir>/intakes/model-lists/<agent>-<key>.json`.
  - The key is `default` or `account_<uuid>`. A pool's list is the union of its members' lists.
  - An empty read never overwrites a stored list.
  - The `ultra` effort is always filtered out.
- **Friendly names** (`ModelNaming` in `ModelOptions.swift`):
  - `label` gives "Claude > Opus 5.5".
  - `derive` strips prefixes and dates, turns `5-5` into 5.5, puts a trailing effort word in parentheses, and turns `[1m]` into "(1M context)".
  - `aliasName` gives "Opus (latest)".
  - A name the CLI supplied always wins over a derived one.

### 5.4 Vocabulary for agents

- `AgentVocabulary.rule` is added to every prompt. It tells agents to call work items "tasks" and
  never to repeat the older name that `br` prints.
- `Tests/FlightDeckTests/Intake/AgentVocabularyGuardTests.swift` builds more than 40 prompts and
  every schema, and fails on the old word in any case. It also checks the validator messages and
  the delivery mail.
- `Tests/FlightDeckTests/Intake/Planning/TerminologyGuardTests.swift` scans string literals in
  `Sources/FlightDeck`, `Sources/FlightDeckMobile` and `Sources/IntakeKit`. It matches
  the old word for tasks, `flywheel`, and `seat`/`seats`, with a few allow-listed paths.

---

## 6. Plan notes

Notes are what a person leaves on a plan for the next planning round to read. On the Mac they
live in the notes rail beside the plan editor; on the phone, in the plan reader.

### 6.1 What a note is

A `PlanNote` (`Sources/IntakeKit/PlanNote.swift`) has three fields:
- `kind`: a `NoteKind`, one of `comment`, `question`, `mustChange`, `delete` or `replace`.
  - A comment with no words is what the UI calls a **Highlight**.
  - `replace` carries its replacement text in `note`.
  - `PlanNote.accepts(kind:)` is the rule for which kinds need words: all except `delete` and an empty comment.
- `note`: the person's words.
- `anchor`: a `NoteAnchor?`. nil means a note about the whole plan.

`NoteAnchor` is anchored like a W3C TextQuoteSelector:
- `checkpoint` is the note's **version**: the checkpoint whose plan the quote was selected in.
- `quote`, with `prefix` and `suffix` of about 32 characters (`contextLength`), and `section`.
- `locate(in:)` finds every exact occurrence, ranked by how well the context matches. Failing that,
  it searches again with whitespace collapsed (blockquote `>` counts as whitespace).
  - A quote shorter than `shortQuote` (20) must also keep `shortContext` (8) characters of context, or be in the same section.
  - nil means "not in this text". Never highlight a guess.

### 6.2 Lifecycle

1. **Written.**
   - Mac: select text, then pick a kind on the selection toolbar (`SelectionToolbar.swift`). A draft card opens in the rail. ✎ with no selection writes a whole-plan note.
   - Phone: `NoteSheet`/`NoteComposer`, anchored by the reader's block index.
2. **Sent.** The note is appended as `TapeCommand.note(PlanNote)`. The phone's path is
   `IntakeService.phoneNote` (section 4.2).
3. **Pending.** The runner folds it into `Tape.pendingNotes`. While pending, a note can be:
   - withdrawn (`removeNote`, phone `intake.removeNote`);
   - retyped (`setNoteKind`, phone `intake.setNoteKind`, gated by `noteKind`).
4. **Consumed.** The next round of **any** stage takes every pending note.
   - `RoundPrompts.steering` renders them.
   - The checkpoint lists them in `annotations`.
   - Nothing reads a consumed note again, so retyping one is refused (`note_consumed`) and shown disabled.
5. **Listed.** `TapeStore.notes(in:)` returns every note as a `TapeNote`: consumed notes oldest first, then pending ones.

### 6.3 Pinning to a version

Synthesis and every refine round rewrite the plan, so on the latest version most quotes are gone.
The rule is that **a note belongs to the version it was written on.**

- `NoteVersion.resolve` (`Sources/IntakeKit/NoteVersion.swift`) returns that checkpoint when the tape has it.
- Otherwise it infers one from the checkpoints before the consuming round: the latest whose plan contains the quote, else the latest candidate.
- It is computed on read and never saved.
- `NoteVersion.label` (via `Stage.versionName(round:)`) gives "Draft · Round 0", "Refine 1" and so on.

**Mac** (`NotesRail.swift`: `PlanNotesController`, `NotesRailModel`; `SelectionToolbar.swift`: `PlanNotesBridge`):
- A note on the version being shown sits beside its quote in the aligned lane.
- A note on another version: `PlanNotesController.pin(for:)` returns a `NotePin`. The rail lists it
  below the lane, grouped by version (latest first), with its quote.
- **That section collapses.** It is a row such as "2 notes on another version" with a pin icon.
  - It starts collapsed when the version shown has notes of its own, and open when it has none (`NotesRailModel.otherVersionsExpanded(choice:hasOwnNotes:)`).
  - The person's choice is kept per intake for the session in a static dictionary, so it survives view rebuilds.
  - When open, it is its own scroll area after the lane and never draws over it.
- "Show in that version" (`showInVersion`) sets `pendingReveal`, opens that checkpoint, scrolls to
  the quote and flashes it. The reveal is used once (`PlanNotesBridge.takeReveal`, 5 s window).
- A note from another version gets a dimmed mark only where its quote is unchanged.
- "Can't find this text anymore" now means the quote is missing **from its own version**, which
  is data damage. It is logged once (`os.Logger`, category `notes`).

**Rounds:** `RoundContext.noteVersions` (filled in `RoundExecutor`) lets the private
`RoundPrompts.anchoredNote` tell the agent that a quote is from another version and may read
differently or be gone.

**Phone:**
- `WireNote` has optional `checkpoint` and `version`.
- `PlanReaderScreen` groups notes from other versions under "Pin: On <version>", which opens that checkpoint's reader.
- `NoteOutbox` keeps sent notes and retypes visible until the plan shows them.

### 6.4 Anchoring in the editor

- `PlanNotesBridge` keeps each mark's range across keystrokes (private `located`), so the rail
  never searches the plan itself. After a text change, private `relocate` re-finds detached notes
  in a window of the new text.
- The rail lays cards out from those ranges (`NotesRailModel.cards`/`layout`). `NotesGeometry`
  redraws only the aligned lane, on scroll, resize or edit.

### 6.5 Fixed bugs (do not reintroduce them)

| What | Cause | Fix |
|---|---|---|
| Notes never came back after switching to another version and back (`18682f2e`) | `relocate`'s window started at `line.location - pad`, which is negative on a whole-text swap, and `NSIntersectionRange` treats it as unsigned | Clamp at 0. Test: `PlanReadingMemoryTests.testNotesFindTheirQuotesAgainWhenTheirVersionIsShownAgain` |
| A stale range snapshot overwrote newer ones | The async publish captured the ranges when it was scheduled | It reads them when it runs |
| A reveal was lost on the editor's first load | The bridge attached after the first load | It attaches before |
| A note's type locked when its text lost focus (`ef052221`) | Blur committed the draft | A type pop-up on every pending card; blur commits only a non-empty draft |
| The other-versions section drew over aligned cards (`6cbb0fb2`) | It sat in the rail's stack, up to 280 pt | Collapsible, with its own scroll area |
| "Can't find this text anymore" after synthesis | Notes were anchored only to the current plan | Pinning |

This was checked against real data: two LarkOS intakes hold 14 consumed notes. All 14 resolve on
their own version, and none on the current plan.

### 6.6 Notes: open items

- **The selection toolbar after synthesis (reported 2026-10-15, not reproduced even with real events): open bug.**
  - The maintainer reported that the kind buttons did nothing on a later version.
  - `NotesToolbarUITests` drives the real app through the window server (the `synthesized` fixture: a draft, a synthesis that consumed notes, two refines, long plans with tables). Each case drags to select, clicks Comment by its label, and checks a second "Add Note" button (the draft card's) appears in the rail. All pass: on the latest version, after switching tabs and back (during and after the reading restore), selecting inside a table, after switching versions in the round list, and with the inspector on Notes and on Rounds.
  - Not covered: the maintainer's own plan size (about 80 KB) and a plan whose restore runs long; other kinds than Comment; a window smaller than full screen.
  - Diagnostics (os.Logger, category `notes`, debug level) log each step. When it recurs, within a few minutes run:
    `log show --predicate 'subsystem == "dev.flightdeck.FlightDeck" AND category == "notes"' --last 5m --debug`
    and read the sequence: `toolbar shown for L,N`; `selection toolbar closed itself` (a scroll, resign-key or app deactivation closed it); `toolbar button pressed: <kind>, alive true|false` (the click reached the action; false means the editor or controller was gone); `choose <kind> on checkpoint C, range` or `choose <kind> refused: ...` (the reason: no checkpoint, or an empty range); `draft opened`; `note sent`. The first missing line is the step that fails. No "button pressed" after "shown" means the click never reached the panel.
- **No note creation time: gap.** Inference uses the consuming round as the bound. Adding a
  `createdAt` would make it exact for new notes.
- **A note on removed text does not follow its replacement: gap.**
- **Not tried in the running app: gap.** The pinned rail, "Show in that version" and the phone's
  pinned groups have only been checked with unit tests and offscreen renders.
- **Phone rule mismatch: open bug (minor).**
  - `phoneNote` allows empty text only for `comment`, but `PlanNote.accepts` also allows an empty `delete`. The phone's `canAdd` matches `phoneNote`.
  - The phone offers retyping (`canRetype`) on old checkpoints, where it offers no Delete.
  - The `intakeSetNoteKind` doc comment in `Frames.swift` says the phone falls back to delete and re-add without `noteKind`. In fact it shows "Change the type on your Mac."
- **Ideas (ask the maintainer before building any of these):**
  - each round reports what it did with each note (addressed, declined because…, answered);
  - "Move to this version" to carry a note forward (needs a new command);
  - replies and threads;
  - notes on the change set, a diff hunk, or a round record;
  - open/resolved state, independent of consumed.

  Any new phone command needs a capability flag (section 4.3).

### 6.7 Notes: tests

- Mac: `NoteVersionTests`, `NotePinningTests`, `NotesRailModelTests`, `NotesRailRenderTests` (`FD_NOTES_RENDER=<png>`), `NoteTypeAnytimeTests`, `NotesOnLaterVersionTests`, `CardPlacementTests`, `PlanReadingMemoryTests`, `RoundPromptsTests`, `IntakePhoneCommandTests`, `IntakeWireCodingTests`, `IntakePlanProjectionTests`, `TapeStoreTests`.
- Phone: `PlanNotesTests`, `NoteComposerTests`.

---

## 7. Known open issues and in-flight work

Each item is marked as an **open bug**, a **gap** (something missing or unverified) or an
**idea**.

### 7.1 In flight on unmerged branches (as of 2026-10-15)

`git log master..<branch>` is empty for both branches: their work is uncommitted, in their
worktrees under `.claude/worktrees/`. A third, `gemini-reads` (Gemini agents' reads being
rejected under agy 1.3.6), landed on master as `3416e35e` while this doc was written; see 5.1.

| Branch | What | State |
|---|---|---|
| `heatmap-names` | **Open bug:** the heatmap squeezes unnumbered section names into the 30 pt "§" badge column. **Open bug:** the reviewer seat row lists "§Phase" once per section (51 times). | Uncommitted, about 91+/15−. `HeatmapModel.title(of:)` gives a "§n" badge only to numbered headings. `nameRow` gets a tail-truncating fallback plus a tooltip. `SeatRowModel.sectionsPhrase` dedupes the sections: "across §2 §4 §7" for up to three, "in N sections" above that. Adds `FD_PLANNING_RENDER_DIR` to the remote forward list. Adds a new render test, `testRenderHeatmapWithUnnumberedHeadings`. |
| `notes-toolbar-clicks` | **Open bug:** dead note-toolbar buttons after synthesis (6.6) | Merged: `NotesToolbarUITests`, the `synthesized` fixture, and the `notes` debug logging (6.6). Not reproduced. |

Already merged; their worktrees could be removed: `rounds-timeline-editor`, `rounds-edit-paused`,
`inspector-*`, `planning-4way`, `intake-archive`, `flywheel-intake`, `tab-model-pickers`,
`unify-planning`.

### 7.2 Landed since 2026-10-13 (context for the items below)

- **Tables:**
  - always grids, with model-driven caret, selection and keys (`dcb5477d`);
  - edit marks drawn inside the grid (`80ebef90`);
  - the phone draws tables as grids (`83cb4761`).
- **Plan editor:**
  - serif typography (`3b758403`);
  - reading position and caret restored after a tab or project switch (`8fa3ae14`);
  - dropped files insert paths (`f83625fa`);
  - the arrow pointer over fold chevrons (`7d44bd6f`).
- **Notes:**
  - pinned to versions, and the switch-back bug fixed (`18682f2e`);
  - type changeable until consumed (`ef052221`);
  - collapsible other-versions section (`6cbb0fb2`).
- **Rounds:**
  - per-role model menu, effort only where a model has levels, and a per-role Account (`41ed54f0`);
  - aligned per-role grid (`7c6ad21c`);
  - reviewer, integrator and polisher rotate across families (`9f13191d`);
  - presets seat Gemini and Grok (`5008fe61`);
  - Gemini defaults to 3.8 Flash (`827cc205`);
  - a plan's config picks up agents detected after it opened (`1136444c`).
- **Phone:**
  - choose fidelity and inspect rounds (`a45e5ca2`);
  - edit rounds (`308b16f9`);
  - provider icons (`ad78cb54`).
- **Agents** are told "tasks" in every prompt and schema (`148a97ad`).
- **Gemini** read-only seats run under an FD-owned agy project, so reads work again (`3416e35e`).
- **Tests:** the unit suite runs on the UI-test Mac by default (`412f9a25`).

### 7.3 Pipeline and engine

- **Gap:** `.parked` is never assigned. Either remove it or give it a meaning.
- **Gap:** triage and release run as in-process `Task`s, so quitting the app loses them. They come back as `interrupted`.
- **Gap:** a drifted op cannot be re-triaged, and a partial release cannot be released again.
- **Gap:** the convergence and coverage thresholds are uncalibrated.
- **Open bug:** plain refine rounds ignore the reviewer's fallback (FOLLOWUPS, "Round engine").
- **Open bug:** a cross-reviewer setup I/O error pauses the round instead of failing only the cross-check.
- **Open bug:** the first live cross-check estimate was unusable, because Claude bundles issues together (a prompt or schema problem).
- **Gap:** a mid-round edit carries forward only on a clean merge.
- **Idea:** `commands.jsonl` grows without bound.
- **Gap:** there has been no live whole-tape run with Claude seats, and the main-thread cost during a run has not been measured.
- **Ideas:** branches and rewind, an oracle seat, per-round agent overrides, a task graph review tab.

### 7.4 Mac UI

- **Gap (against the state principle):**
  - Rounds edits and the chosen fidelity made **before** shaping are view state, so switching intakes loses them.
  - Shaping drafts survive a switch, but not a relaunch.
- **Gap:** folds and the reading position do not survive a relaunch, and folds are dropped when shaping ends. `planScrollMemories` is never pruned.
- **Gap:** the intakes column width is not persisted.
- **Open bug:** the collapsed rail shows archived plans undimmed under Show Archived.
- **Open bug:** at the default window size, the inspector pushes the split past the window edge.
- **Open bug (unverified):** a chip button nested in another may lose the click.
- **Open bug (unverified):** Esc may not reach the heatmap while the editor has focus.
- **Gap:** the heatmap cannot line up with a scrolled tape, and a heatmap cell opens the Diff (the read-only editor), not the editable plan.
- **Gap:** fresh eyes and dedup have no row in the Rounds timeline editor.
- **Gap:** the live slot does not grow, and BILLED covers only the current round.
- **Gap:** there is no UI to turn Flight Control off for a project (`ProjectHeaderRow.swift` has an inert button).
- **Gap:** about 13 behaviours have never been checked by a person in the GUI. They are listed under FOLLOWUPS "Unverified in the GUI", "Inspector modes" and "Rounds timeline editor". The pinned notes rail and the newer table editing are not on that list but are in the same position.
- **Gap:** stale comments.
  - `ProjectView`'s doc comment still promises a task-graph tab "with the next plan".
  - `ReleaseReviewView` quotes an old button title.
  - `MarkdownStyler` line 84 quotes old pt sizes.
  - `IntakeScreen` and `IntakeRoute` (phone) say "read-only".

### 7.5 Phone

- **Gap (against the phone principle):** the phone cannot do these yet:
  - answer triage questions;
  - review or release;
  - retry or discard;
  - start a new intake;
  - archive.

  It says "on your Mac for now". `FLIGHT-CONTROL-MOBILE-PHASE3-HANDOFF.md` scopes this work. Each item needs a new gated op.
- **Open bug (minor):** `CommandCopy` has no words for `unknown_command`, `unknown_mode`, `unknown_preset` or `unknown_kind`.
- **Gap:** there is no terminology guard for the phone's UI-test target, and `MOBILE.md` has no checklist item for retyping a note.

### 7.6 Agents and models

- **Gap:** Codex and Claude count as available when their binary is on PATH, even if signed out. A preset will seat a signed-out CLI.
- **Gap:** model lists are kept per account only for Claude and Codex. Grok and OpenCode are read once, from the built-in home.
- **Gap:** Codex has two model-list sources. Planning reads `models_cache.json`, while routing asks a live `codex app-server` (`RoutingCatalogs.swift`).
- **Gap:** Grok's and Gemini's rate-limit error texts are unverified, and Gemini's token counts look cumulative.
- **Gap:** fallback billing is not shown.
- **Gap:** re-checking agents does not re-read PATH, and a "not installed" agent has no re-check button.
- **Stale comments:**
  - `ClaudeProfile` says there is no model-list command.
  - `ModelListStore`'s comment names the wrong path and file name.
  - `AgentProfile.swift` still talks about "three parallel tracks".

### 7.7 Tooling

- **Open bug:** a full sharded run of `scripts/test-unit.sh` **exits 0 even when tests fail**. It
  prints the PASSED/FAILED banner but never runs `exit "$rc"`, and `test-unit-remote.sh` passes
  the 0 back. Read the banner, not the exit code. Filtered runs and `FD_TEST_SHARDS=1` do exit
  correctly.
- **Gap:** most render knobs are not forwarded to the UI-test Mac, and render PNGs are not copied back (section 8.2).
- **Open bug:** load flakes in `PlanEditorKeystrokeTests`, `PlanningRenderTests` (seat beat) and the inspector "settles" test. `ProjectViewInspectorLiveTests` flashes windows.

---

## 8. How to work on it

### 8.1 Tests run on the UI-test Mac

- `./scripts/test-unit.sh` builds on this Mac and runs on the UI-test Mac (`FD_UITEST_HOST` in
  the git-ignored `scripts/local.env`), via `test-unit-remote.sh`. That is the default.
  - It rsyncs the checkout to the **same absolute path** there. It shares the remote lock with the XCUITests.
  - Options:
    - `FD_TEST_FILTER=ClassA,ClassB/testX`, `FD_TEST_SHARDS=N`, `FD_SKIP_BUILD=1`, `FD_SKIP_MENUBAR=1`;
    - `FD_REMOTE_LOAD_RUNS=N` repeats the run under CPU load;
    - `FD_TRACE_BEEPS=1` finds what makes the system beep.
- **Never set `FD_TEST_LOCAL=1`**, and never run a window-opening test, an app launch or an
  XCUITest on the development Mac. Those tests take over its screen.
- XCUITests: `FD_UITEST_ONLY="-only-testing:FlightDeckUITests/PlanningInspectorUITests" ./scripts/smoke-remote.sh`.
  - Logs and `.xcresult` come back in `DerivedData/smoke-remote/`.
  - `SMOKE SKIPPED` (exit 5) means every selected case skipped.
- Read the result banner (section 7.7).

### 8.2 Render tests and viewing PNGs

- Render tests are skipped unless their environment variable names an output path.
- `test-unit-remote.sh` forwards only these on master:
  - `FD_PLAN_TABLE_RENDER_DIR` (`PlanTableRenderTests`);
  - `FD_NOTES_RENDER` (a PNG path; `NotesRailRenderTests`);
  - `FD_PLAN_TYPE_RENDER_DIR` (`PlanTypographyRenderTests`).
- To use any other knob, add it to the `for name in …` list near line 231 of
  `scripts/test-unit-remote.sh`. Otherwise the test silently skips there. The other knobs are
  `FD_PLANNING_RENDER_DIR` (`PlanningRenderTests`, `ConvergenceRenderTests`, the departures board),
  `FD_ROUNDS_RENDER_DIR`, `FD_ROUNDS_PAUSED_RENDER_DIR`, `FD_INSPECTOR_RENDER_DIR`,
  `FD_INTAKE_RENDER_DIR`, `FD_PROJECT_RENDER_DIR`, `FD_TIMELINE_RENDER_DIR`,
  `FD_EDIT_LAYER_RENDER`, `FD_PLAN_EDITOR_RENDER`, `FD_COMPOSER_RENDER_DIR` and
  `FD_AGENT_ICONS_RENDER_DIR`. `heatmap-names` adds `FD_PLANNING_RENDER_DIR`.
- The PNGs are written **on the UI-test Mac**, at the same absolute path. Only the shard logs come
  back automatically, so fetch the PNGs yourself:
  `rsync -a "$FD_UITEST_HOST:<dir>/" <dir>/`.
  Write them under `.superpowers/` (which the rsync to the remote excludes) or your scratchpad.
- Then read every PNG with the Read tool. Check both themes and both widths when the test renders
  them. A render that passed but that you did not look at proves nothing.

### 8.3 The phone

- `./scripts/test-ios.sh` runs the phone suite headless, on a throwaway simulator.
- `./scripts/deploy-phone.sh [--release] [--no-build]` builds, installs and relaunches on the device (`DEVICE`, default `Mobile3`).
- If the phone shows as `unavailable` over Wi-Fi, read `docs/MOBILE-UI.md`, section "`unavailable`
  on Wi-Fi: the phone is there, its Bonjour advert is not". The router filters multicast, so you
  query the phone's mDNS over unicast and re-advertise it from the Mac with `dns-sd -P`.
  - Check that the phone is not on cellular.
  - Redo the proxy when the uuid or `authTag` changes.

### 8.4 Release ritual

See `docs/AGENT-OPERATIONS.md` §2. **Do not build or swap a release unless the maintainer asks.** In short:
1. Run `./scripts/build-hostd-linux.sh`.
2. Do a Release `xcodebuild … -derivedDataPath DerivedData build`.
3. Run `nohup ./scripts/swap-release.sh <delay> <pid> >/dev/null 2>&1 &`, detached.
4. The swap refuses a Debug build. It backs up the old app to `…/Flight Deck/backups/<ts>/` and logs to `~/Library/Logs/flight-deck-swap.log`.

### 8.5 Worktrees, the merge lock, and the shared checkout

- **Worktrees:**
  - Use one worktree per change, under `.claude/worktrees/<name>`.
  - Symlink `vendor/*-artifacts` and copy `scripts/local.env` from the main checkout.
  - Pass `-derivedDataPath DerivedData` to every `xcodebuild`.
- **Merging to master:**
  1. Take the lock with `mkdir .superpowers/merge.lock` in the main checkout. If the directory already exists, wait.
  2. Merge `--ff-only`, or commit by path (`git commit -- <paths>`).
  3. Release the lock with `rmdir .superpowers/merge.lock`.

  This lock is not described in `AGENT-OPERATIONS.md`.
- **The main checkout is shared.**
  - Other sessions leave uncommitted edits in it. Never `git stash`, `git checkout .` or revert blind. Never push.
  - Commit only your own paths.
- **Real user data is read-only.** `~/Library/Application Support/Flight Deck/intakes/` holds
  The maintainer's real plans (for example LarkOS). Read it to diagnose, and never write to it. A test
  store must never point at it.

### 8.6 Storage rules

- **The runner is the only writer of `tape.json`, `checkpoints/` and `plan.user.md`.** The app and the phone only append commands.
  - A new operation needs a new `TapeCommand`, plus runner handling.
  - For the phone it also needs a gated op (section 4.3).
- **Storage changes are additive only.**
  - Old `intake.json`, `tape.json` and `commands.jsonl` must keep decoding. That includes pre-`PlanNote` string annotations, the JSON key `harness`, `Preset.bead`, and `createBead`.
  - Add optional fields. Never rename a key.

### 8.7 UI wording

| Say | Never |
|---|---|
| tasks | the old word for them, anywhere a person or an agent reads |
| agent | seat, harness |
| Single task | the old preset name |
| friendly model names ("Claude > Opus 5.5", from `ModelNaming`) | raw model ids |

`TerminologyGuardTests` and `AgentVocabularyGuardTests` enforce the first two rows. Code
identifiers (`SeatRow`, `BeadWriter`, `Preset.bead`) may keep their names.

---

## 9. Design principles

These principles come from the maintainer's recent requests. Apply them to new work without being asked.

1. **The plan editor never snaps to source.** A table stays a grid while you edit it. Diffs show
   inline, in the cell or row they belong to. Do not add a fallback that shows the raw Markdown.
2. **State survives switching.** Tabs, intakes and projects can switch at any time. Selection,
   inspector mode, folds, reading position, caret, drafts and unsaved edits must be where the
   person left them. Persist anything a person would miss after a relaunch.
3. **Friendly names come from authoritative sources.** Prefer the name the agent's CLI or cache
   gives. Derive a name only as a fallback, and never show a raw id.
4. **Nothing is truncated until it means nothing.** A label must stay readable. "§Phase" repeated
   51 times, or "Re…" in a badge, is a bug. Prefer wrapping, a shorter form that is still true,
   or a summary ("in 12 sections"), with the full text in a tooltip.
5. **Everything is editable from the phone too.** Every Mac action should have a phone path, gated
   by a capability flag.
6. **Prefer the agents' CLIs and local caches over vendor APIs or tokens.** Read what the CLI
   already wrote (catalog caches, `models_cache.json`) or ask the CLI. Do not add API keys or
   direct vendor HTTP calls.

---

## 10. Other docs, and which are stale

| Doc | What it is | Status |
|---|---|---|
| `docs/ARCHITECTURE.md`, "Intake" (L2033 onward) | The engine, storage, planning rounds, rotations, accounts, model menus, runner, transport, edits and notes, the planning UI file map | Mostly current. **Stale:** "Human edits and notes" (around L2256) still says "engine only — no views yet". |
| `docs/FOLLOWUPS.md` | The running list of open items. Flight Control sections start around L63, L1896, L1951, L2081, L2225, L2279, L2330, L3153 to L3241, L3502, L3520 and L3602. | Current. The "Known gaps" list at L2279 has some superseded items. |
| `docs/AGENT-OPERATIONS.md` | Running inside the app, the release ritual, remote tests, worktrees, the shared checkout | Current. It does not describe the merge lock. |
| `docs/MOBILE.md` | Phone device checklist | **Stale line 7:** "Flight Control … is not on the phone yet". Items 75 to 103 match the code. It says "hundred and two items", but there are 103. |
| `docs/MOBILE-UI.md` | How to work on phone screens; the Wi-Fi Bonjour proxy | Current. No Flight Control content. |
| `docs/FLIGHT-CONTROL-MOBILE-PHASE3-HANDOFF.md` | Phone Phase 3 scope: answers, start, retry, discard, review, release | Mostly current. Choose and start were built. The rest was not. |
| `docs/FLIGHT-CONTROL-MOBILE-HANDOFF.md` | The original terrain map for phone Flight Control | Partly stale; §0.1 is marked superseded. |
| `docs/FLIGHT-CONTROL-COVERAGE-HANDOFF.md` | Design brief for cross-check coverage | **Stale.** It says nothing is built; coverage, cross-check and rotations now exist. Historical. |
| `docs/FLYWHEEL-INTAKE-CHECKLIST.md` | Manual GUI checklist for intake, triage, release and the planning UI | Never walked. It predates inspector modes, the timeline editor, notes pinning and archive. |
| `docs/FLYWHEEL-SPIKE-FINDINGS.md` | Why Flight Deck runs its own agents over `br` and `am` | Still the architecture |
| `docs/FLYWHEEL-FLEET-MANAGEMENT.md`, `FLYWHEEL-INTEGRATION.md` | Early vision | Background only |
| `docs/FLYWHEEL-OBSERVE-CHECKLIST.md`, `FLYWHEEL-SMOKE-CHECKLIST.md` | Observe (Level 1) and smoke runbooks | Current; the disable step is still untestable |
| `docs/FLIGHT-CONTROL-LEVEL3-HANDOFF.md`, `FLIGHT-CONTROL-L3-CHECKLIST.md` | Level 3 routing and swarm (the other meaning) | The handoff is **stale** (L3 merged 2026-10-06). The checklist has never been walked. |
| `docs/HANDOFF.md` | Entry map for the whole app | Partly stale. Line 44 says coverage is not merged. Its index omits the Flight Control docs. |
| `docs/README.md` | Doc index | Omits all Flight Control and plan docs |
| `docs/superpowers/specs/`, `docs/superpowers/plans/` | Designs and plans by date (for example `2026-09-26-flywheel-intake-design.md`, `2026-09-27-planning-ui-redesign.md`, `2026-09-29-flight-control-coverage.md`) | Historical. They show why things are the way they are, not how they are now. |
| `docs/HANDOFF-plan-notes.md` | Now a pointer to section 6 | |
