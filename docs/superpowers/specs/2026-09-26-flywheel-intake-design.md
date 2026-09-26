# Flywheel intake and plan shaping — design

**Status:** design, awaiting review · **Date:** 2026-09-26 · **Builds on:** the Level-1
Observe branch (`worktree-flywheel-observe`, unmerged) and Level-0 run integration (merged).

## 1. Goal

One intake process for every way work enters a flywheel project. It covers a one-line
tweak added to a swarm that is already running, a small feature, and a full project plan
built with multiple models over many rounds. You describe what you want. Flight Deck (FD)
triages it against the live bead graph, shapes it at the fidelity the work needs, encodes
it into beads, fits those beads into the graph, and releases them to the swarm only after
you review the exact change.

### What Nate said (decisions in this brainstorm)

- There are two perspectives: drafting and refining plans, and adding beads to an
  existing project, whether that project is still running or finished. Both go through
  one process.
- Fidelity scales up and down continuously.
- A triage agent recommends the fidelity level and may ask clarifying questions (1).
- An intake may modify beads that are open, in progress or closed (2).
- A change to an in-progress bead gets a graduated delivery based on its triage rating,
  and you can override the rating (3).
- A change to a closed bead becomes a follow-up bead by default. It becomes a reopen when
  triage decides the closed work was wrong (4).
- A slot is harness + model + effort. The first version has native CLI slots and oracle
  slots, behind a pluggable slot-kind interface (5).
- When an oracle slot fails: draft slots switch to a substitute model, and the reviewer
  slot pauses. Both come with a diagnosis that tells you how to intervene (6).
- FD is the only thing that writes to `br` (7).
- Drift is handled by rechecking each operation's precondition at release (8).
- Intakes live in a per-project view (Intakes and Beads tabs), which opens by clicking a
  project row. Agent Mail comes later (9).
- The shaping-round engine is part of this project (10).
- A fidelity level is a preset that fills in an editable round configuration (11).
- Plan artifacts live in FD storage until release (12).
- Rounds are driven by transport controls on a tape that can branch. The branch view is
  hidden by default (13).
- Runs survive FD exiting. They are adopted through a more robust fd-abduco protocol, and
  the runner carries out the last command whether or not FD is running (14).

Numbers in parentheses are used in section 13.

### Assumptions (not stated by Nate — correct them in review)

- Intake builds on the Observe branch's `FlywheelProjection` and watcher. It does not
  replace them.
- "Bead fidelity" means one encoding pass of any size, not exactly one bead.
- Release applies the branch the playhead is on. Abandoned branches stay visible, dimmed.
- The phone app does not show intakes in this project.

## 2. Scope

**In scope:**
- The intake pipeline: capture, triage, shape, encode, integrate, polish, release.
- The change-set model and its staging and delivery rules.
- The round engine: slots, native CLI and oracle runners, detection, substitution,
  diagnosis, and snapshots.
- The tape: checkpoints, transport, branches and diffs.
- The intake runner under fd-abduco, and sidecar adoption.
- The per-project view (Intakes and Beads tabs) and the release review.
- Clickable project rows.

**Out of scope:**
- The convergence gauge. Its inputs are recorded (§6.6) so it can be added later without
  migrating data.
- The Agent Mail inbox tab.
- API and courier slot kinds. The interface allows them; they are not implemented.
- Showing intakes on the phone.
- Automatic swarm spawning from released beads.

## 3. Concepts

| Term | Meaning |
|---|---|
| **Intake** | One unit of intent, from capture to release or discard. It belongs to one project. It is persistent and has a state. |
| **Change set** | The proposed diff against the bead graph that an intake produces: new beads, new edges, edits to existing beads, reopens and follow-ups. FD owns it. `br` never sees it before release, except for materialized beads (§5.3). |
| **Fidelity preset** | Bead, Sketch, Feature plan or Full plan. Choosing one fills in a round configuration, which you can edit. |
| **Round configuration** | Drafter slots, a synthesizer slot, a reviewer slot, an integrator slot, encoder and polisher slots, a refinement cap, a polish cap, and the default play mode. |
| **Slot** | One agent seat, defined as `kind` (native CLI or oracle) + harness + model + effort + optional fallback. |
| **Tape** | A graph of checkpoints over time. A **minor** checkpoint is the end of a round. A **major** checkpoint is the end of a stage. |
| **Branch** | A path through the tape that starts by continuing from a past checkpoint. |
| **Runner** | The process that executes an intake's tape. It runs as `flightdeck intake run <id>` inside its own fd-abduco daemon. |

### Fidelity presets (defaults)

| Preset | Drafting | Refinement (cap) | Encode | Polish (cap) | Default play mode |
|---|---|---|---|---|---|
| Bead | none | none | triage agent, one pass | 0 | ⏩ to review |
| Sketch | 1 drafter | reviewer, 2 | one pass | 0 | ⏩ to review |
| Feature plan | 2 drafters → synthesis | 3 | one pass | 2 | ⏭ (stops after synthesis) |
| Full plan | 4 drafters (arbiter / realist / coverage / stress-test roles) → synthesis | 5 | one pass | 6, then fresh-eyes + dedup | ⏭ (stops after synthesis) |

Slot defaults are filled from detected capability (§6.2). A preset you have edited is
labelled "<preset>, customized".

## 4. Pipeline

1. **Capture.** You type your intent into the Intakes tab and press ⌘↩. The intent text
   is stored unchanged and never rewritten, so moving between fidelity levels loses
   nothing.
2. **Triage.** A headless agent reads the intent against the graph. It has read-only
   access to `br` and `bv` and to the repo. It returns one of two results, checked
   against a schema:
   - `questions`: clarifying questions. The intake goes to *needs answers*. Your answers
     go back to the agent as a follow-up turn in the same session.
   - `recommendation`: a preset, a one-sentence reason, and integration hints (beads it
     overlaps, dependency candidates). At **Bead** fidelity it also returns the full
     change set.

   You accept the preset or pick another. Accepting starts the tape in the preset's
   default play mode.
3. **Shape.** Drafting, then synthesis, then refinement rounds (§6). Bead preset skips
   this stage.
4. **Encode.** An encoder agent turns the final plan into a change set. It has read-only
   access to `br` and returns change-set JSON.
5. **Integrate.** This is part of the encoder's and triage's job, and the schema enforces
   it. Every new bead is linked to existing beads where a dependency exists. Duplicates
   are checked against open **and** closed beads. Every edit to a bead that is in
   progress or closed is rated (§5.4).
6. **Polish.** Polish rounds revise the change set. At Feature plan and Full plan
   fidelity, the change set is first materialized as `deferred` beads so polishers can
   use `br` (§5.3). Full plan fidelity ends with a fresh-eyes round and a dedup round.
7. **Release review.** The change set is shown on the Beads graph and preconditions are
   rechecked (§5.5). You release it, or re-triage the operations that drifted.
8. **Release.** FD applies the change set, writes the final plan to
   `docs/planning/PLAN_<slug>.md` (Sketch and above), and delivers notices to the agents
   holding affected beads.

## 5. Change set

### 5.1 Schema (sketch)

```jsonc
{
  "intake": "<id>",
  "graphObservedAt": "<iso8601>",          // when triage/encode read the graph
  "ops": [
    { "op": "createBead", "tempId": "n1", "title": "...", "type": "task", "priority": 2,
      "description": "...", "acceptance": "...", "labels": ["..."] },
    { "op": "addEdge", "from": "n1", "to": "br-42", "kind": "blocks",
      "held": false },                               // new→existing: applied at materialize or release
    { "op": "addEdge", "from": "br-17", "to": "n1", "kind": "blocks",
      "held": true },                                // existing→new: ALWAYS held (see 5.2)
    { "op": "editBead", "id": "br-31", "set": { "description": "..." },
      "pre": { "status": "open", "assignee": null, "updatedAt": "..." } },
    { "op": "editBead", "id": "br-17", "set": { "acceptance": "..." },
      "pre": { "status": "in_progress", "assignee": "BlueFalcon" },
      "delivery": { "rating": "scopeChange", "reason": "..." } },
    { "op": "reopen",   "id": "br-9",  "reason": "acceptance never met: ...", "pre": { "status": "closed" } },
    { "op": "followUp", "tempId": "n2", "of": "br-12", "title": "...", "description": "..." }
  ]
}
```

- `tempId` values are resolved to real `br` ids at materialize or release.
- Every op that touches an existing bead carries a `pre` precondition.
- Every edit to an in-progress bead carries a `delivery` rating.

FD validates the whole change set before storing it. Validation checks four things: the
schema, that every referenced id exists, that the new graph has no cycles, and that each
`held` flag is correct. FD **computes** the held flag itself and does not trust the value
the agent supplied.

### 5.2 Staging rules

Staging is based on an observation from br 0.6.0, made against a scratch repo. A bead
created with `-s deferred` and no date stays out of `br ready` and out of bv's top picks.
But an edge from a live bead onto a deferred bead blocks the live bead immediately.

The rules:
- **Never written before release:** edges from existing beads onto new beads,
  `editBead`, `reopen`, and any status change to an existing bead.
- **May be materialized before release** (Feature plan and Full plan only): new beads, as
  `deferred`, and edges from new beads to new beads or from new beads to existing beads.
- **Bead and Sketch presets materialize nothing.** The whole change set is written at
  release.

### 5.3 Materialization

Polish rounds at Feature plan and Full plan fidelity need real beads for the polishing
agents to work on. FD therefore creates the `createBead` ops as `deferred`, labelled
`fd-intake:<id>`, and records the mapping from `tempId` to real id.

Polishers are given `br` write access **scoped by prompt and checked afterwards**. After
every polish round, FD reads back every bead labelled `fd-intake:<id>` and diffs the
graph against the graph before the round. A change outside that label set, or any new
edge from an existing bead onto a new one, is **reverted** and recorded as a violation in
the round record.

At release, FD un-defers the beads and applies the held operations.

### 5.4 In-progress and closed beads

**Edits to an in-progress bead.** Triage or the encoder rates each one. You can override
any rating in the release review.

| Rating | Delivery at release |
|---|---|
| `clarifying` | An Agent Mail message to the holder, in a thread keyed by bead id. |
| `scopeChange` (the default) | An inject into the holder's FD session through `submitPrompt(_:token:to:)`, which queues if the agent is busy and is idempotent by token. The same text is also sent by Agent Mail. |
| `invalidating` | Reclaim the bead: set it back to open, release the holder's reservations, and inject a stop notice. |

**Closed beads.** A `followUp` op creates a new bead with a `related` edge to the closed
one. A `reopen` op is used only when triage decides the closed work was wrong, and it
must give a reason.

**Finding the holder.** The holder is found from the bead's `assignee`, matched to the
agent name and then to the FD session, as Observe does today. If the holder has no FD
session (for example, an `ntm` agent), FD sends mail only and says so in the review.

### 5.5 Drift and release

At release, FD re-reads every bead that an op references and compares it with the op's
`pre` precondition. Each op then falls into one of three groups:

- **Still holds:** the op is applied.
- **Drifted:** the op is flagged in the review, with the change explained. Example:
  "br-42 was claimed by BlueFalcon since triage — this edit is now an in-progress change,
  rated *scopeChange*." For a drifted op you can:
  - re-confirm it, optionally changing its rating;
  - drop it;
  - re-triage only the drifted ops. This is a triage turn in a new session that receives
    only those ops and the current state of the beads they touch.
- **Impossible:** the op's target bead was deleted. The op is dropped and the drop is
  shown in the review.

**Apply order.** Creates first. Then un-defer the materialized beads. Then new→\* edges,
then edits, reopens and follow-ups, and finally existing→new edges. Each op is applied
with the `--actor flightdeck-intake:<id>` flag. After applying, FD runs `br sync` so the
JSONL export matches the database.

**Known gap.** `br update` has no version-check precondition, so there is a window of
milliseconds between FD's recheck and its write. FD rechecks again right before each op
that touches an existing bead, and reports any mismatch as a post-release warning. Adding
an upstream `--if-version` flag to `br` is a follow-up item.

**Partial failure.** A `br` command that fails partway through a release stops the apply.
The release is recorded as *partial* with the exact ops that were applied. The review
reopens with the ops that remain. There are no automatic rollbacks, because other agents
may already be acting on the beads that were written.

## 6. Round engine

### 6.1 Stages and round types

| Stage | Round types | Output per round |
|---|---|---|
| Draft | one run per drafter slot, all in parallel | `drafts/<slot>.md` |
| Synthesis | synthesizer: "best-of-all-worlds" over the drafts, producing git-diff edits to its own draft; then integrator applies them | the plan, plus a verdict tally (agree / somewhat / disagree) |
| Refine | reviewer in a **fresh session** each round ("find your best revisions…" plus your annotations), then integrator | the plan, a list of changes with rationale, and a verdict tally |
| Encode | encoder | the change set |
| Polish | polisher ("reread AGENTS.md… check each bead…"), then fresh-eyes, then dedup (Full plan only) | the change set (materialized) |

Prompt templates start from the methodology's own prompts, including its overshoot
phrasing ("I'm positive you missed…"). They live in FD's resources, and each intake can
override them. Your **annotations** (✎) are added to the next round's prompt. When a
branch forks, its annotations stay on that branch.

### 6.2 Slots, runners, detection

**The slot-kind interface.** Each kind implements four operations:
- `start(round, inputs) → RunHandle`
- `adopt(sidecar) → RunHandle`
- `result(handle) → RoundOutput | Failure`
- `cancel(handle)`

**Native CLI runners:**

| Harness | Invocation | Result | Session id |
|---|---|---|---|
| codex | `codex exec --json -m <m> -c model_reasoning_effort=<e> -s read-only` | the `item.completed{agent_message}` event | `thread.started.thread_id` |
| claude | `claude -p --output-format json --model <m> --effort <e>`, run with CLAUDE_CODE_CHILD_SESSION and CLAUDECODE unset | the `result` field | `session_id` |
| grok | `grok -p --output-format json -m <m> --reasoning-effort <e>` | JSON output | from its output |
| gemini | `gemini -p -o json -m <m>`; effort is set through `modelConfigs` aliases in a per-run settings overlay | JSON output | from its output |

Codex and Claude are verified live (2026-09-26). Grok and Gemini have not been run,
because neither is authenticated. Their adapters are built from `--help` and marked
*unverified* until probed.

**Read-only enforcement:**
- Triage, drafting, synthesis, review, encoding, fresh-eyes and dedup all run
  **read-only**. For codex this is `-s read-only`. For claude it is a read-only allowed
  tool list, plus `br`/`bv` read commands.
- The integrator writes only the plan file inside the intake directory.
- Polishers get `br` write access, with the post-round revert check from §5.3.

**Resume hazard.** `codex exec resume` ignores the model recorded in the session and
falls back to the config default. This was observed: luna fell back to terra. **Every
follow-up turn therefore passes model and effort explicitly.**

**Oracle runner:**
- Invocation: `oracle --engine browser --model <m> --browser-thinking-time <t>
  --file <bundle> --write-output <path>`, in manual-login profile mode.
- The oracle session id is recorded in the sidecar.
- Adoption and recovery use `oracle session <id>`.
- A Pro request that oracle can't confirm fails closed. FD treats that as a
  `tierUnavailable` failure, never as success.

**Detection.** Detection fills in the model and effort choices for each slot, with each
value labelled by the source it came from:
- codex: `codex app-server` `account/read` (`planType`) and `account/rateLimits/read`;
  models and efforts from `models_cache.json`.
- claude: `claude auth status` (`subscriptionType`).
- grok: `grok models`, or reported as unauthenticated.
- gemini: whether auth is present in `settings.json`.
- oracle: `oracle doctor --providers`.

**Two labelling rules:**
- Codex `ultra` is shown as **"max + delegation"**, never as Pro. It spawns subagents.
- A slot that asks for a tier the account can't reach is shown as unavailable, with the
  reason.

### 6.3 Failure policy

| Slot role | On failure |
|---|---|
| Drafter | Switch to the slot's fallback model if one is configured. The round is marked *substituted* and the diagnosis is kept. Without a fallback, the round continues without that draft, and the gap is recorded. |
| Reviewer, synthesizer, integrator, encoder, polisher | The tape pauses at this checkpoint with the diagnosis. These slots are never substituted silently. The reviewer especially: it must be the same model every round for the round series to be comparable. |

**Diagnosis.** FD sorts each failure into a category and shows a concrete action for it:

| Category | Source | Action shown |
|---|---|---|
| `challenge` | oracle challenge metadata | Complete the check in the Chrome window, then click Retry. FD never solves challenges itself. |
| `authExpired` | oracle login guidance, or a CLI auth error | Sign in again (the exact command or site). |
| `rateLimited` | oracle, or CLI rate-limit output | Retry at the reset time (from codex `account/rateLimits/read` when available), or switch to another slot. |
| `uiChanged` | oracle model-picker or DOM diagnostic | Update oracle (`npm i -g @steipete/oracle`). |
| `tierUnavailable` | a Pro request that failed closed | Change the slot or the subscription. |
| `timeout` | oracle incomplete capture, or the runner's watchdog | Recover the captured answer with `oracle session`, or retry. |
| `harnessError` | anything else | The last 40 lines of the run log, plus Retry and Change slot. |

### 6.4 The tape

A tape is a graph of checkpoints. Each checkpoint stores:
- its stage, round index and parent checkpoint;
- a snapshot (the plan file, or the change set once past Encode);
- the round record: the change list, `+/-` line counts, the verdict tally, slot outcomes
  (normal / substituted / failed), your annotations, and timestamps.

**Transport commands.** Each command sets the runner's target:

| Command | Target |
|---|---|
| ⏯ step | the next minor checkpoint |
| ⏭ next major | the next major checkpoint |
| ⏩ | release review |
| ⏸ | pause at the next minor checkpoint; the round in progress finishes |
| ⏹ | cancel the round in progress; its partial output is discarded |
| ⏮ | rewind: move the playhead to an earlier checkpoint |

- **Extend** raises the cap for the current stage.
- **Release is never a tape target.** It is a separate button in the review.
- **The runner carries out the most recent command until it reaches that command's
  target.** It does this whether or not FD is running. Starting an intake applies the
  preset's default play mode.

**Branches:**
- **Creating one.** A branch starts when you play forward from a checkpoint that already
  has a later checkpoint. The earlier branch is kept; nothing is ever deleted.
- **Round series.** Each branch's series is its lineage: from the root, through the fork,
  to its tip. This is what the future gauge will read.
- **Plan branches and the graph.** At Feature plan and Full plan fidelity, forking from a
  point *before* Encode drops the old branch's materialized beads, which are re-deferred
  and relabelled `fd-intake:<id>:<branch>`. Only the branch at the playhead has live
  materialized beads. Switching the playhead across branches that are past Encode swaps
  which label set is materialized.

**Diffs.** You can diff any two checkpoints:
- plan against plan, by section (headings) and by hunk;
- change set against change set, by bead (added, removed, changed fields);
- across stages: the plan diff up to Encode, then the bead diff.

### 6.5 Storage

```
~/Library/Application Support/Flight Deck/intakes/<id>/
  intake.json        # project, intent, preset, round configuration, state, playhead, target
  tape.json          # checkpoint graph + branches
  checkpoints/<cp>/  # plan.md | changeset.json, round.json, drafts/ (draft stage)
  runs/<run>/        # per-slot: sidecar copy, stdout/jsonl, session id, log
  control            # the runner's command input (see §7)
```

`sessions.json` is untouched. Intakes are not sessions.

### 6.6 Gauge readiness

The convergence gauge is not built here. Every piece of data it needs is already in the
round records: the change lists, the plan or change-set snapshots, the dependency-edge
sets, and the verdict tallies.

## 7. Runner and fd-abduco adoption

- **What the runner is.** `flightdeck intake run <id>` is a new subcommand of the merged
  `flightdeck` CLI. It runs inside its own fd-abduco daemon, spawned the same way terminal
  sessions are. It executes the tape: it starts slot runs, writes checkpoints, and carries
  out commands.
- **Where its logic lives.** The runner shares the engine code with FD. The engine is a
  library target with no dependency on the GUI.
- **Commands from FD.** FD sends ⏯, ⏸ and the other commands as JSON lines appended to
  `intakes/<id>/control`. The runner acknowledges each command in `intake.json`.
- **Progress to FD.** FD watches `intake.json` and the checkpoints on the shared
  `WatchClock`, the same way the Observe watcher does. There is no socket protocol for
  progress.
- **Slot runs.** The runner starts each one in its own process group, with its output
  written to `runs/<run>/`. Each run has a run sidecar recording its pid, its harness
  session id (or oracle session id) and its output paths. A slot run therefore outlives a
  runner crash, and the runner lives in a daemon that outlives FD.
- **Sidecar metadata.** Every fd-abduco daemon, sessions included, gets a
  `<sock>.meta.json` next to its socket. It records the kind (`session` | `intakeRunner`),
  the owner id, the FD build channel (`release` | `debug`), the creating pid and the start
  time.
- **Reconcile rules.** At launch, `reconcileDaemons` does four things:
  - adopts `session` daemons listed in `sessions.json` (unchanged from today);
  - adopts `intakeRunner` daemons whose intake exists;
  - reaps a daemon **only if** its owner is gone;
  - **never touches a daemon whose channel doesn't match its own.** This also fixes the
    known hazard where debug and release share `/tmp/flight-deck-<uid>`.

  A daemon with no sidecar is treated the old way (a session, keyed by socket name), so
  the upgrade is backward compatible.
- **Runner crash recovery.** At launch, FD restarts the runner for any intake whose
  target is not yet reached. The restarted runner resumes from the last checkpoint and
  re-adopts slot runs through their sidecars (the oracle session id, or the CLI session id
  plus the output file). A round that can't be recovered is marked *interrupted*.

## 8. UI

### 8.1 Clickable project rows

A click on a project row selects it and opens the project view. **Only the chevron
collapses** the project.

Constraint: today the whole row is a collapse toggle, done through
`SidebarInputMonitor`, *because any Button or tap gesture on the row breaks
drag-to-reorder* (`ProjectHeaderRow.swift:26`). The plan is to make header rows native
selectable `List` rows, which NSTableView selects without taking the drag. This must be
tested against reordering **before** anything else is built on it. If it fails, the
fallback is to extend `SidebarInputMonitor` so it separates a chevron hit from a row
click.

The project rollup and the unread state count intakes that are in *needs answers*,
*needs review* or *paused on a failure*.

### 8.2 Project view

The project view mounts in the RootView detail column when a project row is selected. It
has two tabs:

- **Intakes:**
  - A list of intakes with state pills (triaging, needs answers, running, paused,
    review, released · N beads, discarded).
  - An intent field (⌘↩ to triage).
  - Selecting an intake opens its detail: the intent, triage questions and answers, the
    tape and transport, and the ⑂ branch toggle.
- **Beads:** the project's beads grouped as ready / in progress / blocked / deferred /
  closed, with the Observe DAG embedded. It needs `br graph --all --json`, which is a
  stub in Observe today (`FlywheelReadCommands.swift:80-102`).

### 8.3 Tape and branch view

This follows the mockups in `.superpowers/brainstorm/…/transport-branches-v2.html`.

**Collapsed (the default).** A single tape shows the current branch's lineage, with fork
marks, the playhead, and the transport bar: ⏮ ⏯ ⏭ ⏩ ⏸ ⏹ ＋ ✎. A status line says what
each button would run.

**Expanded:**
- A left-to-right network view with one lane per branch, split into stage columns.
- Click a node to jump there. ⌘-click two nodes to mark them A and B.
- A diff pane shows a per-section summary and the hunk for the section you pick.
- Actions: Jump, Continue from here (fork), Swap.
- Collapse returns to the single tape.
- Abandoned branches are dimmed.

Each round card shows its change count, `+/-` lines, verdict tally, and slot outcomes.
A substituted slot is marked, and hovering the mark shows the diagnosis.

### 8.4 Release review

The review opens as a sheet over the Beads graph:
- **New beads** are ghost nodes.
- **Held edges** are dashed.
- **Edited beads** are outlined, and each one's field diff is available.
- **Drifted ops** are highlighted, with an explanation and the actions re-confirm / drop /
  re-triage.
- **In-progress edits** show the holder, the rating (editable) and the delivery that will
  happen.
- **Closed-bead ops** show whether each is a follow-up or a reopen, and the reason.

The footer summarizes the release: "Release 7 beads · 3 held edges · 2 notices
(1 inject, 1 mail)". The **Release** button is disabled while any drifted op is
unresolved.

## 9. Triage details

- **Inputs:**
  - the intent;
  - `br list --json` (all statuses) and `br graph --all --json`;
  - `bv --robot-triage`;
  - the project's AGENTS.md and README.
- **How it runs.** Headless, read-only, as the default triage slot (configurable per
  project; defaults to the strongest detected native model at high effort).
- **Output.** `questions` or `recommendation`. At Bead fidelity, a `recommendation`
  includes the change set, as §4 describes.
- **Answers.** Each answer is sent as a follow-up turn in the same session, with model
  and effort passed explicitly.
- **Changing fidelity.** Moving up or down re-enters Shape with the original intent plus
  the transcript so far. The change set produced so far is kept as a checkpoint, so you
  can diff it.

## 10. Agent Mail identity

FD sends messages as its own agent, named `FlightDeck`, registered in each project on
first use with `am macros start-session`. Its sender token is stored where `am` persists
identities. Messages use `--thread-id bead:<id>` and `--topic fd-intake`.
`invalidating` notices are sent with `--importance high --ack-required`.

## 11. Error handling (summary)

| Failure | Handling |
|---|---|
| A slot fails | §6.3 |
| Validation fails | An invalid change set from an agent triggers one automatic retry with the validation errors in the prompt. A second failure pauses the tape with the errors shown. |
| Violation in a polish round | The out-of-scope change is reverted and recorded, and the tape continues. If a round needs more than 3 reverts, the tape pauses. |
| The runner dies | FD restarts it at launch (§7). While FD is running, a runner whose daemon disappears is restarted once; if it disappears again, the intake is *interrupted*. |
| A `br` or `am` error at release | The release is recorded as partial (§5.5). |
| The project is closed or its flywheel is disabled with intakes still open | The intakes are kept. Their runners pause, and the runners are reaped only when you discard the intakes. |

## 12. Testing

- **Pure unit tests** (`test-unit.sh`):
  - change-set validation;
  - the held-flag computation;
  - precondition diffing and drift sorting;
  - the apply order;
  - preset expansion;
  - the tape graph (targets, branch creation, lineage);
  - both kinds of diff;
  - failure categorization, against captured oracle and CLI failure fixtures;
  - the sidecar reconcile rules.

  Every test is confirmed failing against the unfixed code first.
- **Engine integration.** Fake harness binaries emit the recorded `codex exec --json` and
  `claude -p` output shapes. These tests exercise: the runner under a real fd-abduco
  daemon, the control file, adoption after the parent is killed, and crash recovery.
- **`br` integration** runs against scratch repos **under `$HOME`, not `/tmp`**, because
  `am` treats temp paths as ephemeral and silently skips enforcement. Covered: staging,
  materialization, the post-polish revert check, release, and partial failure.
- **Live probes**, run on demand and never looped:
  - `scripts/test-adapters.sh` gains cheap rows for the four harness invocations.
  - One opt-in oracle probe.
- **Sidebar regression.** A UI-test hunt case for project-row selection plus
  drag-to-reorder, gated on `TEST_RUNNER_…` (AGENTS.md rule 4).
- **GUI end to end is Nate's**, from a checklist added to `docs/`.

## 13. Risks and open items

1. **Observe is unmerged.** Intake depends on its projection and watcher. Merge it
   first, or build intake on that branch.
2. **Sidebar selection vs. drag-to-reorder** (§8.1). This is prototyped first, because
   everything in the project view depends on it.
3. **`br` has no version-check precondition.** The race window is documented, and an
   upstream flag is proposed.
4. **Oracle is not installed, and the accounts don't include Pro or Deep Think.** The
   oracle runner is built and tested against fixtures and one live probe. Until the
   subscriptions change it only reaches Plus-tier models, and a Pro request fails closed
   by design.
5. **Grok and Gemini are unauthenticated.** Their runners stay marked *unverified* until
   probed.
6. **Changing fd-abduco's reconcile rules** touches the code that keeps every live
   session alive. Sidecars must be written before any rule that reads them is shipped,
   and a daemon with no sidecar must keep today's behaviour exactly.
7. **The polisher's `br` access is enforced after the fact, not prevented.** A polisher
   can briefly write an existing→new edge that blocks a live bead until the round ends.
   Mitigation: the revert check runs at every polish *checkpoint*, and also on a
   mid-round poll whenever the Observe watcher sees a change to a bead outside the
   intake's label set.

## 14. Phasing (for the implementation plan)

1. Sidecar metadata and the new reconcile rules in fd-abduco, fully backward compatible.
   Clickable project rows, with the reorder hunt case.
2. The engine library: the models, the change set, validation, the tape, and storage.
   Pure and fully unit-tested.
3. The Bead-preset pipeline end to end: the triage slot (codex and claude runners), the
   project view with the Intakes tab, the release review, `br` release, and Agent Mail
   and inject delivery.
4. The Beads tab with the DAG (`br graph`), and ghost-node rendering in the review.
5. The runner under fd-abduco: the control file, adoption and crash recovery.
6. The round engine: drafting, synthesis, refinement and the integrator; transport;
   annotations.
7. Branches: forking, the network view and diffs.
8. Encode and polish at Feature plan and Full plan fidelity: materialization and the
   revert check.
9. The oracle runner and diagnosis; grok and gemini runners; the detection UI.
