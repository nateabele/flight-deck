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
| Ask threads (planning v2 P1) | Engine: `Sources/IntakeKit/Threads/` (`ThreadRunner`, `ThreadStore`, `ThreadCommand(Store)`, `ThreadTurnExecutor`, `ThreadWorkspace`, `ProvenanceIndex`, `ActionValidator`, `ThreadAccept`, `ThreadDecisions`). Process: `flightdeck intake threads <id> --root`, spawned by a second `IntakeRunnerController` (`kind: .threads`). App: `Intake/IntakeService+Threads.swift`, `+PhoneThreads.swift`. Mac UI: `Intake/Planning/Threads/`. Phone: `ThreadScreen.swift`, `ThreadOutbox.swift`, `PhoneDiffGutter.swift`. See 2.11. |
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
  - `TriageResult` is `.questions([StructuredQuestion])` or `.recommendation(preset:reason:changeSet:)`.
  - `enum Triage` holds the schema and the prompts: initial, answers, correction and encodeNow.
  - `TriageExchange` (`Intake.swift`) holds one round of questions and answers. `questions` and
    `answers` are the plain strings, which the rounds still read. `structured` and
    `structuredAnswers` are optional, so an old `intake.json` decodes unchanged.
  - `StructuredQuestion` (`StructuredQuestion.swift`) has `id`, `text`, `kind` (`single`,
    `multi`, `toggle` or `text`), `options` (id, label, detail), `recommended` (option ids) and
    `allowOther`. `StructuredAnswer` has `questionID`, `selected` (option ids) and `other`.
  - `presentedQuestions` is what the UI shows: `structured`, or the strings as text questions
    `q1`, `q2` and so on.
  - `questionsDigest` names a round by its questions' ids, texts, kinds and option ids (FNV-1a
    64, 16 hex digits). `retry` clears the exchanges, so a round index is not unique. Drafts and
    phone answers key on the digest.
  - `isComplete`, `accepts` and `render` check and render one answer. `accepts` refuses an
    unknown option id, a duplicate id, and a selection on a text question. A choice renders as
    its label. Other renders as `labels; Other: text`.
- **Schema:** each item of `questions` is an object with `id`, `text`, `kind`, `options`,
  `recommended` and `allowOther`. The decoder still accepts a plain string. A malformed object
  (an unknown kind, missing fields) degrades to a text question instead of failing triage. Only an
  item with no text is dropped.
- **`Triage.normalize`** makes duplicate or empty ids unique, drops `recommended` ids that are
  not options, turns a choice with too few options into text (the options become hints), and sets
  `allowOther` on every single and multi question.
- **`HeadlessSession`** (`Intake.swift`) is stored under the JSON key `harness`. The key is legacy;
  do not rename it.
- **Files:** `<intake>/triage/{graph.json, bv.json, schema.json}`. Unsent answers go to
  `<intake>/answer-drafts.json`, written with a 400 ms debounce. The file holds the round index,
  the round's digest and the `structured` answers beside the old strings. Drafts for another
  round or digest are deleted. A file without a digest or `structured` still loads while its
  round and question texts match. On load, each answer's `selected` is filtered to the
  question's own option ids, so a stray id can't make the round refuse the send.
- **A refused send is shown.** `answer(_:structured:)` returns an `AnswerRefusal`; the Mac's
  form shows it in words (`IntakeDetailView.words`) under the questions until the next edit.
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
- **polish, freshEyes, dedup:** each returns a patch (`ChangeSetPatch`) keyed by the op `index` in the numbered `work/changeset.json`. FD applies it, so an op the patch doesn't name comes through unchanged, then checks the result against encode's `graph.json` and stores the whole change set.
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
| `checkpoints/<n>/`: `drafts/<i>.md`, `plan.md`, `plan.user.md`, `plan.user.threads.json`, `changes.json`, `verdicts.json`, `crosscheck.json`, `changeset.json`, `graph.json` | runner |
| `threads/commands.jsonl` | app and phone (append only, under the same `flock` as `commands.jsonl`) |
| `threads/` (everything else: `cursor`, `runner.json`, `runner.lock`, `<thread>/thread.json`, `turns.jsonl`, `diffs/`, `activity.json`, `workspace/`, `runs/`) | ThreadRunner (2.11) |
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
  - **Visuals (planning v2 P2a).** A new task may carry `visualRefs` (`[{visualID, states}]`), the
    visuals it is built to match. Every caller passes `knownVisuals`: the head plan's stored,
    non-pending `fd-visual` ids (`PlanVisualFence.knownVisuals`). It is `Set()`, never nil, for a
    plan with none and at triage (no plan yet), so a cited id there is `unknownVisual`. The
    callers are `RoundExecutor.changeSetSeat` and `patchSeat`, triage, `reviewModel` and both
    `runRelease` checks. A visual counts only with a block state on the released (head plan)
    checkpoint, its `visuals.json` first and `block.json` as the fallback. The strict op schema (`Triage.op`) lists `visualRefs` on every op.
  - **Encode, polish, fresh eyes and dedup read the visuals catalogue** (`VisualCatalogue`,
    `RoundPrompts.visualsCatalogue`): each visual's id, kind, section, states, and its source and
    default-snapshot paths. The seat may read `visuals/`. A polish-family `replace` of a create that
    leaves `visualRefs` null keeps the refs its tempId had (`ChangeSetPatch.apply`); `[]` drops them. A plan with no visuals gets exactly the old prompt.
- **`DriftClassifier`** compares each op's precondition with the live graph. The result is
  `holds`, `drifted` or `impossible`.
- **Release** (`IntakeService.runRelease`):
  1. Re-read the graph and classify drift.
  2. Apply the person's drift confirmations and drops, then re-validate.
  3. **Export the plan** (D14, spec §12, V-R4; `IntakeService+Visuals.swift`). Every release of an
     intake with a plan exports it, visuals or not; an identical re-release is a no-change, not an
     error. Only Single-task intakes, which have no plan, skip it. `PlanExporter` (pure; it and
     every disk read before it run off the main actor) builds `docs/plans/<slug>/`: `plan.md` with
     each block as an image link plus a folder link, `visuals/<id>/` with the primary's files and
     a `README.md`, `_unused-alternates/<n>/README.md`, and the `.flightdeck-intake` marker. The
     slug comes from the intake's title, with `-2`, `-3`, … past a folder that is not this
     intake's. `RepoCommitter` then commits that folder only (`git commit -- <pathspec>`).
     Uncommitted, ignored or hidden changes in the folder, a symlink, or a folder this intake
     does not own refuse the release with the path named, and nothing is written, tasks included.
     So does a block whose visual has nothing stored (the export would mark it missing): the
     release is refused with the visual's id named, so no task cites a folder that is not
     written. The block states exported are the ones the plan's checkpoint recorded, with
     `block.json` as the fallback; `knownVisuals` and the catalogue use the same rule. A cancel
     after the commit would leave the plan committed with no tasks; nothing cancels a release today.
  4. `ApplyPlanner.plan` orders the steps: creates, edges, edits, reopens, held edges.
  5. `BeadWriter` (`Sources/FlightDeck/Intake/BeadWriter.swift`) runs the `br` CLI with `--actor flightdeck-intake:<id>` and stops at the first failure.
     With an export, a task with `visualRefs` gets a "Fidelity references" section in its
     description, written by code (V-R3), naming `docs/plans/<slug>/visuals/<id>/` and its states.
  6. `DeliveryPlanner` and `IntakeDelivery` tell the holders of in-progress tasks: `am mail send`, prompt injection into a live session, or reclaim. A delivery failure is only a warning.
  7. `ReleaseRecord` is saved into the intake.
- **Checkpoints record block states.** IntakeRunner writes `checkpoints/<n>/visuals.json`
  (`CheckpointBlockStates`) from `visuals/` whenever it lands a checkpoint, so an old plan shows
  its visuals as they were. An intake with no visuals gets no file.

### 2.11 Ask threads (planning v2 P1)

Spec §5, §6, §10, §11, with the plan's rulings R1–R9 and the ledger's rulings (spec "Errata").

- **One ThreadRunner per shaping intake**, `flightdeck intake threads <id> --root`, detached under
  `fd-abduco` on `threads-<uuid>.sock`, beside the round runner. `IntakeService.kickThreads`
  starts it after every thread append; `pollThreads` brings it back each tick when a command is
  past the cursor or a turn is queued, and collects its daemon once idle. The work check is
  memoized on the thread files' stamps. `threads/runner.lock` (`flock`) makes a second runner exit
  at once. It carries the intake's runner token in `FLIGHT_DECK_CALLER` and resolves no accounts:
  turns bill what the round runner's `accounts.json` says.
- **Single writers.** ThreadRunner is the only writer of `threads/` (except `commands.jsonl`). It
  appends to the tape only a thread's notes and its auto-accepted diffs. The app and the phone
  only append: thread commands to `threads/commands.jsonl` (R8), an accepted diff's
  `applyThreadDiff` to the tape's `commands.jsonl`.
- **A turn** is one resumed headless run (`ThreadTurnExecutor`) with `.threadRead` access (R1),
  cwd the repo, the workspace readable, and the `ThreadActions` schema. Its CLI carries
  `FLIGHT_DECK_CALLER = ThreadTurnExecutor.agentCaller` ("thread-agent:none"), which the socket
  reads as `.invalid`. Round seats carry the same value (`RoundExecutor`), never the runner's token.
  Grok and OpenCode read files only (`HeadlessCommand.threadReadsFilesOnly`; OpenCode has no bash).
  At most 2 turns run at once per intake (R3). Actions are validated (R6) and retried twice.
- **Accepting a diff** (`ThreadAccept.append`, used by the Mac's `decideDiff` and the phone's
  `phoneDiffDecide`): `applyThreadDiff` is composed on the newest version of the head — the last
  edit still queued for it, else its effective plan — inside the commands lock
  (`TapeStore.appendCommand(composing:)`). A diff from an older checkpoint applies when its
  passage is found exactly once on the head, else it is `diff_stale`. Edit then Accept edited sends
  `editedMarkdown`, which is the `applyThreadDiff` markdown and an accept (ruling). Order: the
  tape's `applyThreadDiff` first, then the thread's `decideDiff`, so a half-failed accept leaves the
  edit and a retry adds only the decision.
- **IntakeRunner applies `applyThreadDiff`** like `editPlan` (`plan.user.md`), and records
  `{thread, diff}` in `checkpoints/<n>/plan.user.threads.json` (`TapeStore.threadEditSources`).
- **Rounds read the decisions** (spec §11): `RoundPrompts.steering` adds "What the human decided in
  ask threads since the last round" — each unresolved thread with a turn that ended after the head
  checkpoint landed: title, anchor, latest `decision`, and whether its change is among the human's
  edits (`ThreadDecisions.since`). Resolved threads never feed rounds.
- **Runner callers get least privilege** (ruling): `ControlScope` refuses an `.intakeRunner` caller
  every command and request (`out_of_scope`), its own intake's included, as on the canvas branch.
- **Tests:** `AskThreadEndToEndTests` (logic lane) runs Ask → reply → accept → next round with the
  real ThreadRunner, ThreadAccept and IntakeRunner. `ThreadRunnerTests`, `ThreadStore*Tests`,
  `ActionValidatorTests`, `IntakeThreadServiceTests`, `PhoneThreadCommandTests`. The UI flow is
  `AskThreadUITests` (`FD_UITEST_ONLY=FlightDeckUITests/AskThreadUITests ./scripts/smoke-remote.sh`)
  on `-FlightDeckPlanningFixture threads`: a seeded thread with a reply and a pending diff, and no
  ThreadRunner (a turn would spend real tokens on the UI-test Mac), so the Ask it sends stays queued.

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
  - On the new-note draft, a text question's answer and the Other field of a choice question,
    `.dropsFilePaths` appends plain paths. Option rows and toggles take no drop.
- **Visual blocks** (planning v2 P2a, `Intake/Planning/Visuals/`). A ```` ```fd-visual id=<id> ```` fence
  is a block (`MarkdownBlock.Kind.visual`). The styler hides its source lines and holds them to a
  fixed paragraph height. `VisualBlockOverlay` lays a `VisualBlockView` over them, as tables are
  laid (V-R1). The view has a header, the body, a filmstrip when there is more than one
  representation, Compare, and the states and sizes controls (`visual-sizes`). Mermaid draws in a
  `WKWebView` that loads only `fdvisual://<id>/r<n>/…` through `VisualSchemeHandler`: manifest-listed
  files, a non-persistent store, every other scheme cancelled (V-R2). Mermaid 12.2.0 is vendored
  in `Resources/Visuals/mermaid/` with its SHA-256 (V-R5). At most 3 web views are live; an
  off-screen block shows its snapshot (`VisualRenderHost`). A block whose id has no stored revision
  is a fixed-height "missing visual" placeholder; a parse error shows Mermaid's own message. An
  older checkpoint shows the block states it recorded. The open V1 items (Find inside a hidden
  block, snapshot timing and caching, one shared render host, edit marks on hidden lines) are
  being done in parallel V4b.
- **Links** (`PlanLinks.swift`): ⌘-click opens a link. Holding ⌘ shows a tip with the target. `:42` and `#L42` suffixes are stripped. In-document `#anchor` links are not supported.
- **Outline and breadcrumb:** `PlanReadingPosition` shows "§ Title" in the pinned board's footer, and a click jumps there. `PlanFocus` is how a heatmap cell asks for a Diff at a section.

### 3.8 The notes rail and ask threads

See section 6 for notes. Files: `PlanEditor/NotesRail.swift` and `SelectionToolbar.swift`.

Ask threads (spec §6, files under `Intake/Planning/Threads/`):
- **✦ Ask** is the last button on `SelectionToolbar`: on a selection it opens the panel on a new
  thread anchored there; with none, on the whole plan. The Question note kind is gone from the
  toolbar (old Question notes still read and feed rounds).
- **Ask cards** (`AskCard.swift`) sit in the rail's aligned lane beside their quote: title, live
  activity, excerpt, counts, Open ⤢, and a stale pill with Re-propose.
- **The thread panel** (`ThreadPanel.swift`, `ThreadPanelModel.swift`) replaces the rail in the
  inspector (R7): an index (Open by section, Needs you, Resolved; a filter; "＋ New thread on
  whole plan") and the conversation. The header has the title, Resolve, the agent menu, the
  auto-accept switch, the version followed, and "reads files only" for grok and opencode. ⌘↩
  sends, ⌘⇧↩ sends and resolves, ⌘[ ⌘] move between threads. The model polls the binding's reader
  (`IntakeThreadBinding`), and its refusals read as words (`ThreadPanelModel.words`).
- **Diffs in the plan** (`DiffGutter.swift`, D17 option B): the proposed text drawn in place of
  its paragraph (`PlanProposal`) with a green bar; on hover the old text struck through and ✓ ✗ Edit
  ✦. Edit puts the words in the plan; Accept edited sends the whole plan as the accept, Cancel
  restores the passage by range. Undoing the insert, or a paste over the passage's edge, ends the
  edit session (words left as typed). Switching thread in the panel lets the edit go.
- The panel's open thread and width are remembered per intake for the session.

### 3.9 Release review

- `ReleaseReviewView.swift` is a sheet titled "Release plan as tasks". It has three sections: New tasks, Edits and Dependencies.
  - A drifted row has Confirm and Drop buttons.
  - An edit to an in-progress task shows its holder, a rating picker and the planned delivery.
  - The footer shows "N notes carried into task notes".
  - The Release button text comes from `UIText.releaseButton`.
- `ReleaseSheetModel.swift` holds the text and counts. `ReleaseSummary.swift` (IntakeKit) holds the count line.
- For a plan with visuals, the sheet lists what release writes to the repo, what a re-release
  removes, and the commit (`ReleaseReview.export`, from `RepoCommitter.preview`; spec §12
  "Confirmation").
- The sheet closes only on `released` or `partiallyReleased`.
- Not verified: that `confirmedDrift`, `droppedOps` and `ratingOverrides` are saved to `intake.json` through `mutate`. It is likely, but `mutate` was not read.

### 3.10 Fixture for UI tests

`PlanningUIFixture.swift` is Debug only. Launch with `-FlightDeckPlanningFixture shaping
-FlightDeckResetState YES` to seed a temp state dir with one paused Feature plan that has notes.
`PlanningInspectorUITests` uses it. `-FlightDeckPlanningFixture synthesized` seeds a draft, a synthesis that
consumed notes, and two refines, each a long plan with tables (`NotesToolbarUITests`).
`-FlightDeckPlanningFixture visuals` seeds the shaping plan with one Mermaid `fd-visual` block
stored `wide` and `narrow`, and no ThreadRunner (`VisualSizeUITests`:
`FD_UITEST_ONLY=FlightDeckUITests/VisualSizeUITests ./scripts/smoke-remote.sh`).

### 3.11 The sidebar status

A project's row in the sidebar shows what its Flight Control is doing, at the **trailing** edge.
Session tabs show their own status at the leading edge, in a different shape, so a plan never
reads as a tab.

| State | Shows |
|---|---|
| Needs you (a plan in a `needsAttention` state) | an orange clipboard in a capsule, with the count when more than one |
| Working (a plan triaging, releasing, or shaping with no stop) | an accent clipboard that pulses; still under Reduce Motion |
| Idle, or only released plans | nothing |

Needs you outranks working. It shows on collapsed and expanded rows alike. Hover and VoiceOver
say it in words: "LarkOS plan: Refine 2 running", "2 plans need you: answer questions; choose a
fidelity". Several working plans get a line each.

- **Derivation:** `Intake/FlightControlSidebarStatus.swift` folds the phone's
  `WireIntakeSummary` rows (`IntakeSummaryProjection`), so the attention rule and the "now"
  wording are the phone's. It is pure and has the table of reasons.
- **Click:** a tap on the glyph calls `FlightControlSidebarModel.open`. It selects the project
  and selects, in its Intakes list, the first plan that needs you, else the first working one.
  It is a tap gesture, not a `Button`: a control in the row would take the mouse-down that the
  list's drag needs (see `ProjectHeaderRow`). A drag that starts exactly on the glyph does not
  reorder.
- **Redraws:** `FlightControlSidebarModel` (one per header, a `@StateObject`) absorbs the
  service's publishes, re-derives and publishes only when the status changed.
  `FlightControlSidebarIndicator` is `Equatable` on the status. `RenderProbe` counts
  "projectHeader" and "fcIndicator"; `FlightControlSidebarModelTests` asserts five publishes
  that change nothing shown redraw the indicator zero times. The header still re-evaluates on
  every publish, because it observes the whole store; that cost was there before.
- **Only while Flight Control is on for the project.** The model is attached only then, so a plain
  project never builds `IntakeService`.
- **What was removed:** the orange question mark that the header drew while expanded, and the
  fold of plans into `SessionStore.collapsedStatus` as a synthetic "waiting" session. Both
  made a plan needing you look like a tab needing you.
- **Not covered:** an edit conflict (`editConflicts`) does not count as needing you, because
  `IntakeService.needsAttention` does not. Add it there, and the sidebar and phone follow.
- **Renders:** `FlightControlSidebarRenderTests`, `FD_FC_SIDEBAR_RENDER_DIR` (forwarded to the
  UI-test Mac, and the PNGs are copied back by `test-unit-remote.sh`). The sidebar picture is a
  replica column built from the real glyph views, because a running plan in a real store makes
  its runner controller try to resume it; the `fc-header-*` pictures are the real header.

---

## 4. The phone UI and the wire

### 4.1 Screens (`Sources/FlightDeckMobile/`)

| Screen | Files | What it does |
|---|---|---|
| Intake row | `IntakeRow.swift` | Glyph, title, pill and one fact in the Sessions list |
| Intake screen | `IntakeScreen.swift`, `IntakeDetailModel.swift`, `IntakePresence.swift` | `BoardStrip` with transport keys (Stop asks first; a long press on a play key sets the default). Sections: questions (`StructuredQuestionForm.swift`: choose, then Send; "Answer on your Mac for now." when the Mac does not set `structuredQuestions`), clarifications, fidelity, review ("Review and release on your Mac for now."), failure, Rounds, agents, rounds (with −/+), plan. Polls every 1.5 s while visible, using an etag. |
| Fidelity chooser | `FidelityChooser` in `RoundInspectorModel.swift`, UI in `IntakeScreen.swift` | Sends `intake.choose`, or `intake.start` if the Rounds were edited |
| Round inspector and editor | `RoundInspectorScreen.swift`, `RoundInspectorModel.swift`, `RoundEditorModel.swift` (`RoundEditor`, pure), `RoundEditorView.swift` | Read-only by stage, or an editor when `RoundEditing.make` allows it. Choosing: "Start sends these rounds." Shaping: Revert and Save (`intake.rounds`). Shows provider icons and "Claude > Opus 5.5" names. |
| Round detail | `RoundDetailScreen.swift`, `RoundFacts.swift` | One landed round: facts, agents, sections changed (each links to the reader's changes), notes consumed |
| Plan outline | `PlanOutlineScreen.swift` | Sections with churn and note counts |
| Plan reader | `PlanReaderScreen.swift`, `PlanTableView.swift` (shared grid renderer) | Blocks from `PlanBlocks.split`, tables as grids, a Changes toggle, notes, other-version groups |
| Visual blocks | `VisualBlockCard.swift`, `VisualViewerScreen.swift`, `VisualCache.swift`, `VisualLoader.swift` | An `fd-visual` block is a card: the snapshot, a filmstrip of states and alternates, the caption, sized from `WireVisualRef.aspect` before its bytes arrive. Tapping opens a full-screen live viewer built from the cached, hash-checked files, with networking off. Only when the detail's `visuals` flag is true; otherwise the block is plan text. |
| Note sheet | `NoteSheet.swift`, `NoteComposer.swift` (`NoteComposer`, `NoteOutbox`) | Quote, kind chips, text. The outbox keeps sent notes visible until the plan shows them. |
| Clarifications | `ClarificationsScreen.swift` | Answered Q&A, read-only |
| Model | `FlightControlModel.swift`, `IntakeCommands.swift` | Banners, one detail and one command model per intake, a plan cache of 4. Commands time out after 10 s and reuse their token within 60 s. |
| Answer form | `AnswerFormModel.swift`, `AnswerDraftStore.swift` | One per intake. Decides when the form shows, when it reads "Sending…", and when it starts again, all keyed on the round's digest. Chosen answers persist per intake and digest in UserDefaults until a send is acked. The intake screen settles the sent marker on every appearance (`observe` in `onAppear`), so a round that moved on while the screen was popped does not stay "Sending…". |
| Ask threads | `ThreadScreen.swift`, `ThreadOutbox.swift`, `PhoneDiffGutter.swift`, `ThreadGate` | Ask in the reader's selection menu (and "Ask about the whole plan") opens a thread; the thread screen shows the conversation (fetched with `intake.thread.get`, polled while open), inline questions, "reads files only" for grok and opencode, and a composer. Pending diffs draw as a green bar beside the proposed text (in the plan's serif); a diff that can't be placed is a tinted card under its block. Tapping shows the old text struck through with Accept / ✗. Unsent notes and asks sit full width under their passage. The fleet row shows a "needs you" count. All of it only when the detail's `threads` flag is true. |

`PlanReviewScreen` and `PlanReviewModel` are the Plannotator plan gate for sessions, not Flight
Control.

### 4.2 Wire (`Sources/FleetKit/`)

- **Requests** (`TimelineFrames.swift`): `intake.detail(id, ifNot: etag)`,
  `intake.plan(id, checkpoint?, changes)`, `intake.thread.get(id, threadID, since?)` (answered
  by `ServerFrame.intakeThread` with a `WireThreadPage`) and `intake.visualFetch(id, visualID,
  revision, part, offset, limit)` (V-R6; answered with `fileChunk`). `part` is `file:<path>` or
  `snapshot[@<state>-<size>]`; `VisualFetch.serve` serves only manifest-listed files, off the main
  actor, and refuses `visuals_unavailable`, `unknown_visual`, `unknown_revision`, `bad_part`,
  `bad_range`, `unknown_file`, `too_large`, `bad_manifest` or `unreadable`. A request is safe on any Mac: an unknown
  request gets `err unsupported`.
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
| `intake.answer` | id, token, round, digest, answers | `structuredQuestions` |
| `intake.thread.send` | id, token, threadID?, anchor?, text | `threads` |
| `intake.thread.answer` | id, token, threadID, answers | `threads` |
| `intake.thread.resolve` | id, token, threadID | `threads` |
| `intake.diff.decide` | id, token, threadID, diffID, accept | `threads` |

- **Wire types** (`IntakeWire.swift`):
  - The core: `WireIntakeSummary`, `WireIntakeDetail`, `WireBoard`, `WireControls`, `WireRound`, `WireNote` (with optional `checkpoint` and `version`).
  - Rounds: `WireRoundConfig`, `WireRoundsMenu`, `WireRoundsLock`, `RoundsRefusal`.
  - Questions: `WireQuestions` (with `round`, `structured` and `digest` for the open round), `WireStructuredQuestion`, `WireOption`, `WireStructuredAnswer`.
  - Others: `WireChoice`, `WireFailure`, `WireIntakePlan` (with `threads`, `pendingDiffs` and
    `visuals`).
  - Visuals (`VisualWire.swift`): `WireVisualRef` (id, primary `revision`, `kinds`, `alternates`,
    `states`, `sizes`, `aspect`, `files` with size and SHA-256), `WireVisualAlternate`,
    `WireVisualFile`, `WireVisualPart`. `IntakeVisualProjection` fills `WireIntakePlan.visuals`
    from the same read the Mac editor makes (`VisualBlockModel.load`), as the checkpoint
    recorded it; `aspect` comes from the default snapshot's PNG header. A plan with no block
    carries no list.
  - Threads (`ThreadWire.swift`): `WireThreadSummary` (with `readsFilesOnly`), `WireThreadAnchor`,
    `WireThreadCounts`, `WireThreadTurn`, `WirePendingDiff`, `WireThreadPage`;
    `WireIntakeSummary.threadsNeedingYou`.
- **Capability flags** are all on `WireIntakeDetail`:
  - The flags are `steer`, `choose`, `noteKind`, `editRounds`, `structuredQuestions`, `threads`
    and `visuals` (on while `VisualFetch.gateOpen`).
  - The payloads are `roundConfig`, `roundsMenu` (while choosing or shaping) and `roundsLock` (while shaping).
  - The Mac sets them in `Sources/FlightDeck/Fleet/IntakeDetailProjection.swift` (the flags at lines 155 to 166; `structuredQuestions` and `threads` at 163 to 166).
  - The phone checks them in `TransportKeys`, `NoteComposer.notesAllowed` and `canRetype`, `FidelityChooser.options`, `RoundEditing.make`, `AnswerFormModel.openRound` and `ThreadGate`.
- **Handlers** (`IntakeService.phone*`, about lines 1332 to 1524, dispatched from `FleetService.swift`;
  the thread ops are `IntakeService+PhoneThreads.swift`):
  - The handlers are `phoneTape`, `phoneDefaultPlay`, `phoneChoose`, `phoneStart`, `phoneRounds`, `phoneNote`, `phoneRemoveNote`, `phoneSetNoteKind` and `phoneAnswer`.
  - `phoneAnswer` refuses `stale_questions` when the round or digest is not the open round's, or the round is already answered. Otherwise it passes on `answer(_:structured:)`'s code: `unknown_question` (a missing, unknown or repeated question id) or `invalid_answer` (an incomplete answer, or one `accepts` refuses). An unknown intake is `unknown_intake`.
  - Each returns nil (ack) or an error code. Codes: `unknown_intake`, `intake_moved_on`, `not_allowed`, `unknown_command`, `unknown_mode`, `unknown_preset`, `no_agents`, `rounds_changed`, `invalid_config`, `unknown_kind`, `empty_note`, `unknown_checkpoint`, `unknown_block`, `note_consumed`, `stale_questions`, `unknown_question`, `invalid_answer`, and `refused: <sentence>`.
  - The thread ops add `empty_message`, `unknown_thread`, `thread_resolved`, `no_agent`, `unknown_diff`, `diff_stale`, `diff_decided` and `write_failed`. A new thread from the phone is named by its token (`ThreadID.opened(byToken:)`), so a retry opens no second thread. No shipped Mac answers `threads_unavailable` (the stubs never reached master): a Mac without threads has no `threads` flag, so the phone never sends it a thread op, and if one did arrive the older Mac would drop the socket (§4.3). The code stays as the app's own "no service" answer, and the phone still has words for it. `intake.thread.answer` carries an optional `turn`; a mismatch is `stale_questions`.
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

### 5.5 Visual providers (P3 core)

A visual provider is a folder with a `provider.toml` that tells Flight Control which kinds of
picture it can make. P3 core ships the loader, the trust gate, the sandbox, the checker, the
Settings list and the authoring skill. Nothing in planning calls a provider yet (see
`docs/FOLLOWUPS.md`, "Visual providers").

**Where the code lives:**
- `Packages/HostKit/Sources/HostKit/Providers/`: `ProviderManifest` and `ProviderManifestParser`.
  They sit in HostKit beside `DelegateConfigParser` because the TOML reader is internal to HostKit.
- `Sources/ProviderKit/`: `ProviderRegistry` (resolution), `ProviderTrust` (digest and approvals),
  `ProviderSandbox` (generator runs), `ProviderCheck`. This folder is compiled into both the app
  target and the CLI target in `project.yml`.
- `flightdeck provider check DIR [--run-samples]`: local, not over the socket. It is caught in
  `Sources/FlightDeckTool/main.swift` before the transport, like `intake run`.
- Settings → Flight Control → Providers: `Sources/FlightDeck/Preferences/UI/ProvidersPane.swift` and
  `ProvidersSettingsModel.swift`.
- The skill: `Resources/ClaudePlugin/skills/visual-provider/`. Claude reaches it through the plugin.
  Codex gets a copy from `Sources/FlightDeck/Agents/Codex/CodexBundledSkill.swift`, which copies a
  whole folder and also installs `delegate` and `peer-messaging`.

**Trust model.** A repo is untrusted input.
- A repo provider with no `[generator]` is data only. It is used with no approval.
- A repo provider with a generator needs a one-time Approve. The approval stores the SHA-256 of the
  folder (path, NUL, length, owner-exec bit, bytes, in sorted path order). Any change asks again.
- The Approve button takes the digest the row showed. If the folder changed since, it refuses.
- Bundled and user providers are trusted, but are re-checked against the folder at run time.
- Links are refused anywhere in a provider folder. xattrs are not hashed.
- Size caps, because Settings reads every repo provider: `provider.toml` at most 256 KiB (read
  through one descriptor, refused from its size); the digest refuses a file over 10 MiB or a folder
  over 50 MiB before it reads a byte, then streams. Settings resolves off the main actor.
- The digest does not hide `.DS_Store` or editor swap files. They change the digest and ask again.
- Approvals live in `~/Library/Application Support/Flight Deck/provider-trust.json`. If that file is
  corrupt, Approve is off and the pane offers "Move damaged file aside".

**Sandbox.** A generator runs only in `ProviderSandbox`, never in the agent. It runs from a private
copy of the folder, re-hashed against the approval. It has no network, writes only to its output and
temp folders, and cannot read the home folder. It has a timeout, output caps and a small
environment. If `/usr/bin/sandbox-exec` is missing, the generator is refused. The summary is in
`docs/ARCHITECTURE.md`, "Visual providers".

**`--run-samples`.** `provider check` validates the manifest, kinds, instruction files and assets.
It checks only the path of `entry`: the agent writes that file in the draft folder (spec §9 step 5),
so a provider does not ship one. A linked provider folder is refused. By default it does not run a generator. With `--run-samples` it first prints the
argv, then runs the generator in the sandbox on `samples/<kind>/`, once per kind. This is intent, not
a security boundary: an agent can already run shell. The skill tells agents to pass the flag only
when the author asked for a sample run. Exit codes: 0 valid (warnings print), 1 problems or a failed
sample, 2 usage error.

**The disabled switch.** The on/off switch is stored in `UserDefaults` under
`visualProviders.disabled.v2`. Each entry is `<source>:<id>`, with source `repo`, `user` or
`bundled`. A bundled switch must not reach a repo override of the same id. The old key
`visualProviders.disabled.v1` (ids only) is migrated on first read. Nothing reads the key yet:
P3-integration must.

**Skill installs.** Codex gets the skill folder under `~/.codex/skills/` with a
`.flightdeck-managed` digest sidecar. The installer never follows a link and swaps a refresh in
whole. A folder that holds a `.git` counts as edited by the user and is left frozen, so it never
auto-upgrades.

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
- **Planning v2 P0, structured questions** (branch `planning-v2-p0`):
  - question model and schema (`ff2c81f4`, `4efd40ab`);
  - triage asks choices and still reads strings (`17c0f5b2`, `08842183`);
  - the Mac takes structured answers (`59ddd44b`) and answers by choosing (`49d97c84`);
  - `intake.answer` and the phone form (`4348e14d`, `5d792468`);
  - fixes: option ids checked (`86dc144e`); rounds named by digest on the Mac (`3d1d9709`) and on the wire (`570e90d4`); phone token, form and drafts per round (`24b0114f`); refusal words (`ecfaefdf`); Other takes file drops (`ff9478c4`).
- **Planning v2 P1, ask threads** (branch `planning-v2-p1`, 2.11, 3.8, 4.1): the shapes and the
  locked append (Task 0, Stream B), ThreadRunner (Stream A), the Mac UI (Stream C), the phone
  (Stream D), the window-free logic test lane (Stream E), and the integration: the runner is
  spawned and kept alive, the stubs are gone, accepted diffs carry their thread, rounds read the
  decisions, and runner tokens reach nothing on the socket.
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
- **Gap (threads):** a ThreadRunner resolves no accounts. Its turns bill whatever the round runner's
  `accounts.json` says, an agent the round config does not use runs on its built-in home, and no
  pool lease is held for a turn while no round runner is live.
- **Gap (threads):** a pending diff is carried onto a newer round only by its thread's next turn. Until
  then an accept lands it on the head when its passage is still there exactly once, and refuses it
  `diff_stale` otherwise.
- **Gap (threads):** codex and gemini thread agents, like round seats, can read files anywhere
  (FOLLOWUPS, "Ask threads"). Triage agents, which the app spawns, carry no `FLIGHT_DECK_CALLER` and
  read as the human on the socket.

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
- **Gap:** the ask-thread UI (P1) is unverified in the GUI: `FLIGHT-CONTROL-PLANNING-V2-CHECKLIST.md`, P1.
- **Gap:** about 13 behaviours have never been checked by a person in the GUI. They are listed under FOLLOWUPS "Unverified in the GUI", "Inspector modes" and "Rounds timeline editor". The pinned notes rail and the newer table editing are not on that list but are in the same position.
- **Gap:** stale comments.
  - `ProjectView`'s doc comment still promises a task-graph tab "with the next plan".
  - `ReleaseReviewView` quotes an old button title.
  - `MarkdownStyler` line 84 quotes old pt sizes.
  - `IntakeScreen` and `IntakeRoute` (phone) say "read-only".

### 7.5 Phone

- **Gap (against the phone principle):** the phone cannot do these yet:
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

- **Which lane:**
  - A test that imports only XCTest, Foundation, `IntakeKit` and/or `FleetKit` (no `@testable import FlightDeck`,
    no window, no `Network` socket or Bonjour) goes in `Tests/IntakeKitTests` or `Tests/FleetKitTests`.
    Run it with `./scripts/test-logic.sh`.
  - Any other test stays in `Tests/FlightDeckTests` and runs through `test-unit.sh`.
  - Put every new pure test file in the first group. It then runs in seconds, in parallel across
    worktrees, with no wait for the remote lock.
- `./scripts/test-logic.sh` runs on this Mac. It never uses the UI-test Mac or its lock, and it
  exits non-zero on any failure. It takes `FD_TEST_FILTER=ClassA,ClassB/testX`, with the same comma form
  as `test-unit.sh`, and `FD_SKIP_BUILD=1`. The two bundles have no test host, so xctest does not launch the app.
  - Pure helpers that both lanes use stay in `Tests/FlightDeckTests` and are listed under the logic
    targets in `project.yml`, so each bundle compiles its own copy.
  - A new test in `IntakeKitTests` or `FleetKitTests` that uses a shared helper from `Tests/FlightDeckTests`
    must have that helper listed in `project.yml` first, or the logic lane does not compile.
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
| `docs/FLIGHT-CONTROL-MOBILE-PHASE3-HANDOFF.md` | Phone Phase 3 scope: answers, start, retry, discard, review, release | Mostly current. Choose, start and answers were built (answers as `intake.answer`, Planning v2 P0). The rest was not. |
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
