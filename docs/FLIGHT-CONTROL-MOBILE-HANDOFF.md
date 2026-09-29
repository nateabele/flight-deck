# Flight Control on the phone — design handoff

**For:** a fresh Claude Code session whose job is to **design** (brainstorm → spec → plan) the
Flight Control planning experience for the iOS companion, `FlightDeckMobile`. **Not to build it.**
**Written:** 2026-09-28, against `master` = `flywheel-intake` @ `ceac717`. Every claim below was
checked against that tree; anything not checked is marked **(unverified)**.

This doc maps the terrain. It does not design the mobile UI — that is your job, with Nate.

---

## 0. The five things you must not miss

1. **No Flight Control data crosses the wire today. None.** `rg -i 'intake|flywheel|tape|checkpoint'`
   over `Sources/FleetKit`, `Sources/FlightDeck/Fleet` and `Sources/FlightDeckMobile` returns
   nothing. `WireProject` is `id, name, path, isCollapsed, sessions` (`Sources/FleetKit/Wire.swift`);
   the desktop's intake-aware project rollup (`SessionStore.collapsedStatus`, which counts
   `intakeService.attentionCount`) is not projected. The phone does not know intakes exist.
2. **The engine cannot run on iOS as-is.** `IntakeKit` is a `platform: macOS` target
   (`project.yml`), and it spawns processes. Its model types (`Tape`, `Checkpoint`, `SeatActivity`,
   `PlanNote`, `ConvergenceSeries`…) are pure Foundation, but the phone cannot import them today.
   Deciding where the shared wire shapes live (new FleetKit types vs. an iOS-compiled slice of
   IntakeKit) is a real design decision.
3. **The phone has no notifications of any kind.** No `UserNotifications`, no APNs, no
   `UIBackgroundModes` in `Sources/FlightDeckMobile` or `project.yml`. The phone only knows what
   it hears while foregrounded and connected. "Tell me when the plan reaches Review" needs a new
   tier (APNs relay / CloudKit), which `phone-pairing-not-ip-based.md` records as deliberately
   out of scope and not cheap. Desktop intake code posts no `UNUserNotification` either
   (`rg` over `Sources/FlightDeck/Intake` finds none); attention there is the sidebar rollup,
   the Intakes rail's orange discs and VoiceOver announcements.
4. **A wire enum case and all its handler arms land in one commit** (`wire-enum-cases-are-atomic.md`).
   Every switch is exhaustive; `Codable` is hand-rolled, so a case missing from the *encode* arm
   silently never ships.
5. **Terminology is enforced on the Mac and not on the phone.** UI says *tasks* (never beads),
   *Flight Control* (never Flywheel), *agent* (never seat). `TerminologyGuardTests` scans
   `Sources/FlightDeck` and `Sources/IntakeKit` only — `Sources/FlightDeckMobile` has no guard yet.

---

## 1. What Flight Control is

**Name rule.** The UI and current docs say **Flight Control**. Code, file and folder names,
branch names, persisted keys, on-disk paths and accessibility identifiers keep **flywheel**; so
does the external methodology (agent-flywheel.com). See `flywheel-rebranded-flight-control.md`.

### The methodology (external)

From `docs/FLYWHEEL-FLEET-MANAGEMENT.md` (untracked in the main checkout — read it at
`/Users/nate/Projects/Protos-n-Tools/flight-deck/docs/`):

- **Plan → Encode → Triage → Coordinate → Implement → Close.** Humans + several models write a
  markdown plan; an agent encodes it into dependency-linked tasks (internally **beads**, via the
  `br` CLI, stored in `.beads/`); `bv` ranks ready tasks by graph centrality; agents claim tasks
  and reserve files through **Agent Mail** (`am`); closing a task unblocks others.
- The human's role in execution is "tending" on a 10–15 minute cadence.
- Convergence of plan refinement is the methodology's own idea (four signals plateauing).

### What Flight Deck has built

| Level | What | Spec | State |
|---|---|---|---|
| 0 — Run | FD-spawned agents join the substrate: per-project `flywheelEnabled`, `am macros start-session`, `AGENT_NAME` in the PTY env, the pre-commit reservation guard | `docs/superpowers/specs/2026-09-18-flywheel-run-integration-design.md` | on master |
| 1 — Observe | Read-only: per-tab Observe drawer (Working on · Files · Dependency · Activity), DAG overlay, `FlywheelNotifier` (human-needed-only macOS notifications) — `Sources/FlightDeck/Flywheel/Observe/` | `…/2026-09-24-flywheel-observe-design.md` | on master |
| 2 — Author | **Intake → triage + clarifying Q&A → fidelity choice + round config → multi-model planning rounds on a tape with checkpoints → encode into tasks → polish → release review → write to `br`** | `…/2026-09-26-flywheel-intake-design.md` (+ 2026-09-27 amendment), `…/2026-09-27-planning-ui-redesign-design.md` | on master since 2026-09-28 (merge `8cf70b6`) |
| 3 — Operate | Swarm console (fleet table, reclaim, tend nudges) | not specced; branch ruling in `swarm-branch-strategy.md` | not built |

Supporting docs: `docs/FLYWHEEL-INTAKE-CHECKLIST.md` (GUI checklist — Nate's; its "Planning UI"
section is the best tour of the desktop surfaces), `docs/FLYWHEEL-INTEGRATION.md` (untracked,
early light-touch integration ideas), `docs/ARCHITECTURE.md` § "Intake" (line ~1034).

### The intake pipeline in one screen

- **States** (`IntakeState`, `Sources/IntakeKit/Intake.swift`): `triaging, needsAnswers,
  awaitingChoice, parked, shaping, review, releasing, released, partiallyReleased, failed,
  interrupted, discarded`. `needsAttention` is true for `needsAnswers, awaitingChoice, review,
  partiallyReleased, failed, interrupted`.
- **Fidelity presets** (`Preset`): `bead` (shown as **Single task**), `sketch`, `featurePlan`,
  `fullPlan`. A preset expands into an editable `RoundConfig` (drafters, synthesizer, reviewer,
  integrator, encoder, polishers, caps, default play mode).
- **Stages** (`Stage`, `Tape.swift`): `draft, synthesis, refine, encode, polish, freshEyes, dedup`,
  then Review. A **checkpoint** is written at the end of each round; stage ends are *major*.
- **Runner:** `flightdeck intake run <id> --root <dir>`, detached under its own `fd-abduco`
  daemon (`IntakeRunnerController`), so a run outlives the app. It carries out the most recent
  command until its target is reached, whether or not FD is running.
- **Transport** (`TapeCommand`): `step, nextMajor, toReview, pause, stop, extend(stage, by:),
  trim(stage, by:), note(PlanNote), removeNote(UUID), editPlan(checkpoint:, markdown:)`.
  Release is never a tape target; it is a button in the review.
- **Nothing touches `br` before release** at any fidelity (2026-09-27 amendment). Polishers work
  on a shadow copy (`ShadowGraph`, `bv --db`).

---

## 2. The desktop planning UI as built (reference to adapt, not copy)

Everything is in `Sources/FlightDeck/Intake/` and `Intake/Planning/`. The spec for all of it is
`2026-09-27-planning-ui-redesign-design.md`. Mockups (git-ignored) are in the main checkout at
`.superpowers/brainstorm/57736-1790549157/content/` (`convergence-combo.html`, `mashup.html`,
`dir-d-hybrid.html`, `shaping-running.png`).

| Surface | What it is | Files | Data source |
|---|---|---|---|
| Project view | Opens by clicking a project row; Intakes list leading, detail pane, inspector trailing | `Sources/FlightDeck/ProjectView.swift`, `DetailLayout.swift` | `IntakeService.intakes`, `selectedIntake` |
| Intakes list / rail | Rows: state pill over a 3-line request (`IntakeRow`, `IntakeTitle`). Collapses (⌥⌘S) to a ~52 pt rail of discs, orange for `needsAttention`, hover card, + composer popover | `IntakeRow.swift`, `IntakeRail.swift`, `IntakeStatePill.swift` | `intakes`, `collapsedListProjects` |
| Header | "INTAKE · state", title cut from the intent that discloses the rest, one-line progress summary (`✓ Triage 3:40 · …`) | `IntakeDetailView.swift`, `ProgressSummary.swift`, `IntakeTitle.swift` | `Intake`, `Tape` |
| Clarifications | Each Q&A round a collapsed disclosure; the open round is a numbered form, **Send Answers ⌘↩** | `IntakeDetailView.swift` | `Intake.exchanges` (`TriageExchange`) |
| Fidelity choice | Recommendation + reason, segmented picker, Rounds summary + "Edit in Inspector" | `IntakeDetailView.swift`, `RoundConfigEditor.swift` | `Intake.recommended`, `roundConfig`, `AvailableModels` |
| Control bar + LCD | Transport (Back · Pause · Step · Next major · To review · Stop), LCD cells ROUND · ELAPSED · AGENTS DONE · SO FAR · BILLED · CONVERGENCE · STOPS AT; Extend/Annotate | `ControlBar.swift`, `LCDModel.swift`, `PlanningCommands.swift`, `ShapingModel.swift` | `tapes`, `pending`, `halts`, seat results |
| Departures board | NOW · IN THE AIR/PAUSED FOR · STOPS AT · CALLING AT, over a tape of stage slots; REFINE ×N / POLISH ×N brackets with − and + (trim/extend); measured labels fall back to codes; split-flap cards | `DeparturesBoard.swift`, `BoardModel.swift`, `SplitFlapText.swift`, `LabelFit.swift`, `FlapPolicy.swift`, `FloatingCard.swift`, `HoverIntent.swift` | `Tape` replayed through `TapePlanner`; `TapeOverlay` for optimistic commands |
| Live card + agent rows | One row per agent in the round in flight: glyph, role · harness · model · effort, headline (dwell ≥3 s), action verb+object, footprint chips, steps, context gauge, count-up clock; exceptions (quiet 30 s, stalled 90 s, rate-limited, fallback, failed) are the only colour | `LiveCard.swift`, `SeatRow.swift`, `SeatRowModel.swift` | `runs/<run>/activity.json` (`SeatActivity`, ≤ every 2 s), `run.json`, `result.json` (`SeatResult`); `triage/activity.json` |
| Finished rounds | Horizontal strip of equal cards (stage, duration, outcome glyph, changes, lines, verdicts) + a detail panel below (note, agents, sections changed, notes consumed) | `FinishedRounds.swift`, `FinishedRoundsModel.swift` | `Checkpoint.record` (`RoundRecord`), seat results |
| Plan editor | Obsidian-style live-preview Markdown (TextKit 2), edit layer (your insertions green, deletions struck), notes rail + selection toolbar (Comment · Question · Must change · Replace · Delete · Highlight), folding, ⌘-click links, "§ section" cue in the board footer; Plan · Diff vs Previous · Change set segments | `Planning/PlanEditor/*` (`PlanTextView` 1568 lines, `EditLayer`, `NotesRail`, `SelectionToolbar`, `PlanFolding`, `PlanOutline`, `PlanLinks`, `MarkdownStyler`), `PlanSection.swift` | `plan.md` + `plan.user.md` via `PlanLayers`; `PlanNote`/`NoteAnchor`; `editConflicts`; `planFolds` |
| Convergence | LCD sparkline + state word (CONVERGING ↘ / PLATEAU → / DIVERGING ↗ / TOO EARLY), churn lane per heading, heatmap (sections × rounds) under the tape | `ConvergenceCellModel.swift`, `ConvergenceViews.swift` | `IntakeService.convergence` (`ConvergenceSeries` over checkpoints' `changes.json`, `verdicts.json`) |
| Inspector | Rounds editor grid, selected agent's details, or the notes rail while the plan is focused (⌥⌘I) | `DetailInspector.swift`, `RoundConfigEditor.swift` | `roundConfig`, `SeatActivity` |
| Release review | Sheet: New tasks / Edits / Dependencies, drift per op (re-confirm / drop / re-triage), in-progress ratings, primary **Release N New Tasks** | `ReleaseReviewView.swift`, `ReleaseSheetModel.swift` | `ChangeSet`, `DriftClassifier`, `ReleaseSummary`/`ReleaseCounts` |

**`IntakeService` (`Sources/FlightDeck/Intake/IntakeService.swift`, 1605 lines, `@MainActor`)**
publishes: `intakes`, `selectedIntake`, `inspectorProjects`, `collapsedListProjects`, `tapes`,
`triageActivities`, `convergence`, `pending` (a start the runner hasn't shown yet), `halts`
("Pausing…/Stopping…"), `editConflicts`. It polls on a ~500 ms tick, gated by file mtimes
(`tapeDates`, seat-file mtimes), so an idle tick is one `stat` per shaping intake.
`send(_:_:)` (line ~636) appends to `commands.jsonl` and folds the command into `TapeOverlay`
so the board moves in the same main-actor turn (0.4–1.3 s otherwise, measured).

---

## 3. Where the data lives, and how it would reach a phone

### On disk (Mac only)

Root: `<state dir>/intakes/`, normally `~/Library/Application Support/Flight Deck/intakes/`
(`FlightDeckApp.makeStore`; debug and release share it — `debug-release-share-sessions-json.md`).

```
intakes/<uuid>/
  intake.json      # Intake: intent, state, preset, roundConfig, exchanges… — the APP's file
  tape.json        # Tape: checkpoints, status, target, ackedCommandSeq, pendingNotes — the RUNNER's file
  commands.jsonl   # append-only TapeCommand queue (app writes, runner drains; never compacts)
  runner.lock
  triage/          # activity.json, schema.json, graph.json, bv.json
  checkpoints/<n>/ # plan.md | plan.user.md | drafts/<i>.md | changes.json | verdicts.json | changeset
  runs/<run>/      # run.json, schema.json, stdout (live JSONL), stderr, activity.json, result.json
  work/            # a round's scratch
```

Single-writer rules matter: `intake.json` is the app's, `tape.json` is the runner's
(`IntakeRunner.swift`, `TapeStore.swift` header comments).

**Measured on Nate's real intake `DF11B6D8-F216-4FE5-AB24-DF0D61F9AE0B` (fieldOS, Full plan,
status `stopped`, 2 checkpoints) — read-only:** whole directory 2.0 MB; `plan.md` 30 KB;
drafts 24–52 KB each (4 of them); `runs/*` 16 KB–896 KB each (stdout dominates);
`commands.jsonl` 64 KB for 28 commands — two `editPlan`s carry the *whole* plan each;
`tape.json` 9 KB; `activity.json` ~300 B. Do not modify this directory.

### The phone link today

| Layer | Where | What it does |
|---|---|---|
| Wire types | `Sources/FleetKit/` (Swift 6; Foundation, Network, Security, CryptoKit only; also compiled as `FleetKitiOS`) | `FleetSnapshot`/`WireProject`/`WireSession`, `FleetEvent`, `ClientFrame`/`ServerFrame` (`Frames.swift`), `FleetCommand` (`Frames.swift`), `FleetRequest` (`TimelineFrames.swift`), pairing, sockets |
| Projection | `Sources/FlightDeck/Fleet/FleetProjection.swift` | Pure read of `SessionStore` into wire shape; also the **oracle** `FleetReplicator`'s drift check compares against |
| Replication | `FleetReplicator.swift` | Folds the store's event log into a mirror + a bounded replay ring; drift check after every batch is load-bearing |
| Service | `FleetService.swift` (1253 lines) | The only type that knows the store and the socket; `server.onCommand` / `server.onRequest` (~line 379); `apply(_ command:…)` |
| Phone | `Sources/FlightDeckMobile/FleetModel.swift` | Owns the connector and store; every screen talks only to it. Timeline polls every 1.5 s while open |

**Three channels, and which fits what:**

- **Sequenced state** (`snapshot` + `FleetEvent`): anything that must survive a reconnect by
  replay. Adding intake state here means `FleetProjection` must project it *and* every mutation
  must record an event, or the drift check fails.
- **Unsequenced request/reply** (`ClientFrame.req` → `ServerFrame.page` / `newSessionOptions` /
  `recentlyClosed` / `conversations` / `searchHits`…): menus, history, catalogues — "not fleet
  state", so they don't move the resume point. The natural home for fetching a plan body, a
  checkpoint, or a round's detail.
- **Commands** (`ClientFrame.cmd` → `ack`/`err` on the `cid`): phone → Mac actions.

**How phone actions are applied today** (the pattern to follow): `FleetCommand.prompt(id:token:text:)`
→ `FleetService.apply` → `store.submitPrompt(_:token:to:)`, refusals returned as `.err(code:)`;
tokens make it idempotent. `answerPrompt` → `PromptService`; `annotatePlan`/`resolvePlan` →
`PlanGateService`. The comment at `.prompt` states the rule: **no validation in the service —
add a store method instead.** For intakes the analogue is an `IntakeService` method (e.g. its
existing `send(_:_:)` for transport).

**The closest precedent — plan review on the phone** (`2026-08-29-plan-review-on-the-phone-design.md`):
`WirePlanGate` rides on `WireSession` and *carries* the plan markdown (the one place the wire
carries rather than derives, with the reason documented in `Wire.swift`); `PlanBlocks` (FleetKit)
is the shared block-split so a phone comment pins to the same phrase on the Mac;
`PlanReviewScreen`/`PlanReviewModel` render with `TimelineMarkdown.theme`. Read it before
designing plan reading/annotation on the phone.

**Versioning:** `FleetKitVersion.wire = 1` exists but is "sent in no frame yet and bumped by
nothing yet". Compatibility so far is additive: optional fields decoded with `decodeIfPresent`,
string-typed tiers so a new value degrades rather than throws, and `hello.caps` capability
strings (`FleetCapability`, `PhoneLogs.swift`). Decide whether Flight Control needs a real
version handshake or a capability string.

**Free rider:** the `flightdeck` CLI speaks the same protocol over a local socket
(`docs/HANDOFF.md`, "Driving Flight Deck from a shell"), so whatever crosses the wire for the
phone is also reachable by an agent in a tab. Note it; don't design around it.

---

## 4. Hard-won constraints (memory: `~/.claude/projects/-Users-nate-Projects-Protos-n-Tools-flight-deck/memory/`)

| Rule | Why | File |
|---|---|---|
| A new `FleetRequest` / `ServerFrame` / `FleetCommand` case, its tag, encode, decode and every handler arm are **one task, one commit** | Exhaustive switches; a split plan leaves an unbuildable commit. Missing encode arm = silent non-delivery; round-trip tests catch it | `wire-enum-cases-are-atomic.md` |
| Anything the phone must *react* to must change something on the wire | The open prompt is derived on both ends; a superseded prompt with unchanged `activity` left the phone on a dead card | `prompt-never-on-the-wire.md` |
| Touching `Sources/FlightDeckMobile` means running `./scripts/test-ios.sh`, not just `test-unit.sh` | Two targets; a green macOS suite once hid a red phone suite. Mobile tests assert copy verbatim | `two-test-targets-not-one.md` |
| No per-event refetch; measure on device | Per-event refetch cost 50–114 KB + 0.16 s CPU; fixed in `4dbdd9e` by refresh-on-connect. Busy-timeline CPU after the fix was never measured | `phone-perf-measured-findings.md` |
| Derived state is computed in one funnel, never in `body` | `SessionTimelineModel.rebuild()` is the only place; the old per-render fold caused the long-session lag. Spill cache, LRU of 8 timeline models | `mobile-timeline-perf-architecture.md` |
| Keyboard: use the root view's layout guide, apply drags as `.offset`, commit padding when settled; plan an on-device check | `window.keyboardLayoutGuide` never moves on device; per-frame padding jerks the `List` | `ios-keyboard-tracking-lessons.md` |
| When a phone-driven action fails, read the Mac's logs before asking Nate to retry | Silent aborts made Nate the diagnostic instrument; he asked not to be. Log a named `check=` on every refusal | `answer-drive-fails-silently.md` |
| `deploy-phone.sh` exits 0 on failure; verify `App installed:` and `Launched application…` in the output | A green run once installed nothing | `deploy-phone-exits-zero-on-failure.md` |
| Pairing is identity-based (SPAKE2 + TLS-PSK), Bonjour + Tailscale CGNAT handle addresses; off-LAN without a tunnel is unsolved (needs relay/CloudKit + APNs) | Don't budget "phone gets notified away from home" as cheap | `phone-pairing-not-ip-based.md` |
| Agent features surfaced in UI go through the adapter, for **every** adapter | Planning agents are claude *and* codex; a phone surface must not be claude-only | `agent-features-via-adapter-for-all-adapters.md` |
| UI says "tasks", never "bead(s)" | Nate, 2026-09-27 | `ui-says-tasks-not-beads.md` |
| UI says "Flight Control"; identifiers keep "flywheel" | Nate, 2026-09-27; renaming persisted keys orphans state | `flywheel-rebranded-flight-control.md` |
| UI says "agent", never "seat" | Nate, 2026-09-28 — "seat" is jargon | `ui-says-agent-not-seat.md` |
| Level 3 swarm: shared main now, worktrees + integrator later | Nate, 2026-09-28; affects what a phone "operate" surface would show later | `swarm-branch-strategy.md` |
| Show UI options as rendered images | Nate picks from renders; a render once reversed a prose-based choice | `show-ui-options-as-renders.md` |
| Never offer the visual companion — just open it when a question is visual | "don't ever ask that question again, just ship it" | `never-offer-visual-companion.md` |
| Rendering: `screencapture` is denied on this Mac | Mac: `layer.render(in:)` on a parked `NSHostingView`. Phone: `simctl io screenshot`, or an offscreen `UIWindow` + `drawHierarchy` (see `docs/MOBILE-UI.md` § "An offscreen render") | `offscreen-render-technique.md` |

From the docs: `docs/MOBILE-UI.md` — the phone suite has no window, so decisions are pure
functions apart from views and appearance is never asserted; the simulator can be screenshotted
but **not driven** (no Accessibility permission); `MOBILE.md` is the device checklist. Keep
`Sources/FlightDeckMobile/` **flat** (AGENTS.md: `build-ios.sh`'s fallback globs `*.swift` only).

---

## 5. Terminology and product rules

- **Words:** tasks (not beads) · Flight Control (not Flywheel) · agent (not seat) · "Single task"
  for the Bead preset. Internals, prompts, `br`, persisted keys keep the old words.
  **Mobile has no guard:** `Tests/FlightDeckTests/Intake/Planning/TerminologyGuardTests.swift`
  scans `Sources/FlightDeck` and `Sources/IntakeKit`. A mobile equivalent belongs in the plan.
- **Honest data only:** no invented percentages, ETAs or live cost. Determinate fractions only
  where real (agents done/total, the agent's own steps, round N of M). Clocks count up. Cost
  (`BILLED`) only when a harness reported it.
- **Colour for exceptions only:** accent = live/selected, amber = attention/fallback, red = failure.
- **Motion:** every animation respects Reduce Motion. 1 Hz clocks from a local timer; idle clocks
  slow to once a minute after 60 s.
- **Split-flap:** plays once, when a value first appears; never on re-render/scroll/resize. The
  hover card is the exception (flips every time it opens). Hover itself doesn't exist on a
  phone — decide what replaces it (long-press? a detail push?).
- **HIG:** primary action trailing and default; destructive never default, always confirmed
  (Stop discards the round in flight — desktop asks "Stop the run?"); no labelled spinners except
  the acknowledgement "Pausing…/Stopping…".
- **Chords are irrelevant on the phone** (⌘', ⌘=, ⌥⌘A…), as is Ghostty's shortcut contention.
- **No dead moments:** every action that starts agent work shows feedback within 100 ms — the
  desktop does this with `TapeOverlay`; a phone over the network needs its own optimistic story.

---

## 6. Nate's working rules for your session

From `~/.claude/CLAUDE.md` and `AGENTS.md`:

- **Process:** `superpowers:brainstorming` → spec → `superpowers:writing-plans`. Specs and plans go
  in `docs/superpowers/specs|plans/`.
- **Presenting:** the spec, then the plan, each via `EnterPlanMode` → write it into the plan file
  → `ExitPlanMode` (Plannotator fires). **Never** ask for approval in chat prose ("sound good?",
  "shall I proceed?"). Substantive design questions via `AskUserQuestion` are fine.
- **After approval:** execute subagent-driven automatically, no "ready?" gate. (Your remit ends
  at the plan unless Nate says otherwise.)
- **Renders, not prose:** show UI options as images — simulator screenshots, or SwiftUI previews
  rendered offscreen. Open the visual companion without asking.
- **Never publish Artifacts** unless Nate asks explicitly.
- **Search:** `rg`, never `grep`. qartez tools are fine for reading; its mutators corrupt worktrees.
- **Shared checkout:** other sessions edit it concurrently. Never `git stash`, `git checkout .`,
  or revert blind; commit only your files by path; check `git diff --cached --stat -- vendor` is empty.
- **Worktrees** need `vendor/{boringssl,ghostty,fd-abduco}-artifacts` symlinked from the main
  checkout, and `xcodegen generate` before `deploy-phone.sh` (`flight-deck-worktree-setup-and-merge.md`).
- **Never launch a bundle from `DerivedData/`** — it forks the fleet with duplicate agents that
  outlive it. Only `/Applications/Flight Deck.app`.
- **iOS:** `./scripts/build-ios.sh` (read which branch it took — real build vs type-check),
  `./scripts/test-ios.sh` (throwaway simulator), `./scripts/deploy-phone.sh` (verify the output;
  `--no-build` can ship a stale bundle).
- **Don't loop** `./scripts/smoke.sh`; it steals the foreground.

---

## 7. Open design questions (resolve with Nate — options listed, not answered)

**Purpose — what is the phone FOR in Flight Control?** Candidates, not exclusive:

1. Monitor a running tape (board / NOW / agents at work / elapsed).
2. Answer triage's clarifying questions (`needsAnswers`).
3. Pick fidelity and start planning (`awaitingChoice`).
4. Transport: pause / stop / step / next major / to review; extend / trim rounds.
5. Read the plan (with folding / a section outline) and annotate it (`PlanNote`s for the next round).
6. Approve the release (`review`) — or deliberately desktop-only because it writes to `br` and
   delivers notices to live agents.
7. Capture a new intake from the phone (dictate an intent; triage runs on the Mac).
8. Be told when something needs you (see notifications below).

**Scope and phasing**

- Read-only first (one wire addition, low risk) vs interactive from the start?
- Which `needsAttention` states warrant phone surfacing, and how does it show in the existing
  fleet list (a project-row badge like the desktop rollup? a separate Flight Control tab?)
- Where does it live in navigation: under each project in `FleetListScreen`, or a top-level tab?

**Surface translation** — which desktop surfaces translate, and in what form?

| Desktop | Likely candidates to discuss |
|---|---|
| Departures board + LCD | Compressed "NOW · IN THE AIR · STOPS AT"? Keep the instrument idiom or go native iOS? |
| Agent rows | Headline + action + clock per agent fits a list row; footprint/context gauge? |
| Finished rounds strip + panel | Cards → list rows + a detail push? |
| Plan reading | Folding/outline, section jump, Diff vs Previous? Size: 30–50 KB markdown per plan |
| Plan editing with the edit layer | Probably not — but annotating via `PlanNote` might be (precedent: `PlanBlocks` on the plan gate) |
| Convergence sparkline / heatmap | Sparkline + state word plausible; heatmap likely not |
| Rounds editor | Probably desktop-only (harness/model/effort grid) |
| Release review | Read-only summary? Full drift resolution? |

**Notifications** — round landed / needs answers / reached Review / failed / stalled. Given §0.3:
in-app only while foregrounded? Local notifications when the socket is alive? An APNs relay tier
(new infrastructure, key management, off-LAN)? Live Activities / Dynamic Island for a running tape
(also needs push to update while backgrounded **(unverified — check ActivityKit's update paths)**)?

**Wire design**

- Snapshot/event state (sequenced, survives reconnect) vs request/reply (fetch on demand) —
  e.g. a small per-project/per-intake summary in the snapshot, plan bodies and checkpoints by request?
- Bandwidth: plans ~30 KB, drafts up to ~50 KB each, `editPlan` sends a whole plan, `runs/*/stdout`
  up to ~900 KB (never send that). Seat activity changes every ≤2 s per agent.
- Where do the shared types live — new FleetKit wire types, or make IntakeKit's pure models
  compile for iOS (it imports only Foundation + Darwin, but spawns processes)?
- How is phone → runner command applied — through `IntakeService.send` (so `TapeOverlay` and the
  desktop board see it), never by writing `commands.jsonl` from `FleetService` directly?
- Versioning: bump `FleetKitVersion.wire`, or a `hello.caps` capability for an older phone/Mac?
- Idempotency and refusals: tokens like `prompt`; named `err` codes (`intake_moved_on`, etc.) and a
  log line for each refusal (see `answer-drive-fails-silently.md`).

**Honesty when stale** — the phone shows "last said" when disconnected. How does a paused-for or
in-the-air clock behave on stale data? Count up from the last known start, or freeze with a stale mark?

**Devices** — `TARGETED_DEVICE_FAMILY: "1,2"` (iPhone and iPad) in `project.yml`. Does iPad get a
desktop-like split view (board + plan), or the same compact design?

---

## 8. Suggested first steps

1. Read, in order: `AGENTS.md` → `docs/HANDOFF.md` → this doc → `docs/MOBILE.md` (top +
   "The trust model") → `docs/MOBILE-UI.md` → `docs/ARCHITECTURE.md` § "Fleet replication…" (≈line
   501) and § "Intake" (≈line 1034) → the four specs in §1 (the planning-UI redesign fully) →
   `2026-08-29-plan-review-on-the-phone-design.md` → `docs/FLYWHEEL-INTAKE-CHECKLIST.md` § "Planning UI".
2. Read the memory files named in §4.
3. Look at the desktop Flight Control in the **installed** app (`/Applications/Flight Deck.app` —
   never a DerivedData build): click a Flight Control project row, open the fieldOS intake. Or
   ask Nate for a screenshot; the Mac's screen can't be captured from a session.
4. Inspect the real tape **read-only**:
   `~/Library/Application Support/Flight Deck/intakes/DF11B6D8-F216-4FE5-AB24-DF0D61F9AE0B/`
   (`tape.json`, `checkpoints/2/plan.md`, `runs/*/activity.json`). Never write there — the runner
   and app own those files.
5. Look at the phone as it is: `FleetListScreen.swift`, `SessionTimelineScreen.swift`,
   `PlanReviewScreen.swift`, `FleetModel.swift`; screenshot it on a simulator
   (`docs/MOBILE-UI.md` § "The simulator").
6. Then brainstorm with Nate — open with §7's "what is the phone for", render candidate layouts,
   and present the spec and plan through `ExitPlanMode`.
