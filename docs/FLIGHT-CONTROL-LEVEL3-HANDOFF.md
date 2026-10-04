# Flight Control Level 3 "Operate": design handoff

**For:** the next session, which will *design* Level 3 (brainstorm → spec → plan). It does not
build anything. Written 2026-10-04, against master `d85cc91`. Every code claim below was checked
in the source on that date; claims that come only from docs say so.

---

## 0. The six things you must not miss

1. **Level 3 is not designed.** `docs/FOLLOWUPS.md` ("Flight Control — next phases", "Level 3
   'Operate' — not started") lists the candidate pieces. It is a wish list, not a spec. Your job
   is to turn it into one, starting with which slice is worth building first.
2. **One ruling is already made: shared main by default** (`docs/FOLLOWUPS.md`, "Level 3 swarm:
   branch strategy"). Agents work on one main branch and coordinate through Agent Mail file
   reservations and the pre-commit guard. Worktrees with an integrator come later, as an advanced
   mode. Because of this ruling, showing *why a commit was blocked* and *which files are
   contested* is **required** UI, not polish. Design both modes to share the task, claim and
   tending surfaces and differ only in how work lands.
3. **Most of the read side Level 3 needs is a stub.** `FlywheelReadCommands.reservations`,
   `.depEdges` and `.events` return `nil` without running a command
   (`Sources/FlightDeck/Flywheel/Observe/FlywheelReadCommands.swift:80-102`). So today:
   - the "contested" state has no data;
   - all three `FlywheelNotifier` triggers are dormant on live data;
   - "Jump to root cause" does nothing.

   Any Level 3 feature that reads reservations or events **starts by capturing a real,
   positive-path `am` row shape**. The fixture in `Tests/FlightDeckTests/Flywheel/Observe/Fixtures/`
   (`am-reservations-all`) is an *empty* `all_active`.
4. **Agents can't do GUI end-to-end here** (AGENTS.md rule 2). A design that can only be checked
   by clicking needs a checklist for the maintainer, and every GUI claim needs a matching entry on it.
5. **The planning pipeline's own coverage estimate is not usable yet** (FOLLOWUPS, "First real
   cross-check (2026-10-02)"): claude bundles sub-issues per proposal and codex doesn't. This
   isn't Level 3, but don't design a Level 3 feature that leans on `CoverageSeries` readings as if
   they meant something.
6. **Words.** UI says *tasks*, never "beads". It says *agent*, never "seat". It says *Flight
   Control*; code identifiers, persisted keys and branch names keep "flywheel".
   `TerminologyGuardTests` enforces this.

---

## 1. Where the ladder stands

The levels come from `docs/FLYWHEEL-SPIKE-FINDINGS.md` (per-level breakdown) and
`docs/FLYWHEEL-FLEET-MANAGEMENT.md` (the original UI ideas).

| Level | What it is | State |
|---|---|---|
| 0 Run integration | FD spawns agents with an Agent Mail identity; repo has guard + beads-sync hook | Built, merged |
| 1 Observe | Read-only drawer under the terminal: working on / files / dependency / activity lanes, DAG overlay, notifier | Built, merged — 2 of 5 reads real |
| 2 Author ("intake") | Request → triage → shaping rounds (draft/refine/polish, cross-check) → encode → release tasks into `br` | Built, merged; phone support merged |
| **3 Operate** | **FD runs the swarm, not just watches it** | **Not designed** |

The docs disagree on one boundary: the Observe spec
(`docs/superpowers/specs/2026-09-24-flywheel-observe-design.md`) calls "nudge / send mail" a
Level 2 action. The spike and FOLLOWUPS put it in Level 3. Settle that in the spec.

---

## 2. What Level 3 can build on (verified)

### 2.1 Release is where Level 2 stops

`IntakeService.release(_:)` → `runRelease` (`Sources/FlightDeck/Intake/IntakeService.swift`
~1344-1445) does these steps:
- re-reads the live graph (`br list --all --json` + `br graph --all --json`, `IntakeKit/GraphReader.swift`);
- plans the steps (`IntakeKit/ApplyPlanner.swift`);
- writes them with `BeadWriter` (`br create` / `dep add` / `update` / `reopen`, each re-checked with
  `br show` first);
- runs `br sync --flush-only`;
- tells the holders of any in-progress task that changed, by mail, by an injected prompt, or by
  reclaiming the task (`Intake/IntakeDelivery.swift`).

It creates tasks as plain `open`. **Nothing after release picks, claims or spawns.** The intake
spec rules that out on purpose ("Automatic swarm spawning from released beads", intake design
§scope). Released tasks are not labelled with the intake that made them; `fd-intake` exists only
as a mail topic.

So the most natural first Level 3 step is to continue from a release: **released tasks → a
swarm working on them.**

### 2.2 Spawning

- `SessionStore.createSession(agent:in:at:account:selecting:) async -> Result<UUID, AgentLaunchError>`
  is the general path for claude and codex. For an enabled project it first boots the Agent Mail
  identity: `am macros start-session …`, which becomes `AGENT_NAME` / `AGENT_MAIL_*` in the env. If
  boot fails, it refuses the tab.
- **No spawn path takes a first prompt.** A swarm launch needs "spawn, then give it its task".
  Today that means `createSession` followed by `submitPrompt` (or `flightdeck send`) once the
  composer is ready, and nothing does that today.
- `flightdeck new` / wire `session.new` (`Fleet/FleetService.swift` ~1136-1198) acks *before* it
  creates, and **never returns the new session's id**. A scripted swarm launch can't address what
  it just made. That needs a wire change, and wire enum changes are atomic: a new case and its
  handlers land in one commit.
- Not used at boot even though the spike's contract allows it: `--reserve <globs>`. Reservation
  TTLs are renewed only when a tab wakes.

### 2.3 Fleet state per session

`FleetProjection` → `WireSession` (`FleetKit/Wire.swift`) has these fields:
- activity, waitingFor, subagent count, unread;
- background work, plan gate, open prompt call;
- apiError (the nearest thing to a rate-limit signal).

What a fleet table would need and **doesn't exist**:
- **last-active time:** `SessionStatus` has no timestamp;
- **account on the wire:** deliberately omitted, see `FleetAccountEmissionTests`;
- **a session ↔ task link:** the only join is Observe's `bead.assignee == agent name`
  (`FlywheelProjection`), then `SessionStore.session(project:agentName:)`.

### 2.4 Read side

`FlywheelWatcher` polls on the shared `WatchClock`, gated on the mtime of `.beads/beads.db` and
its `-wal`. It runs `am agents list` and `br list --status in_progress`, and nothing else. The
global Agent Mail database is deliberately not watched.

**Shortcut for dependency edges:** `IntakeKit/GraphReader` already decodes `br graph --all
--json` edges, and release uses it live. The Observe `depEdges` stub could reuse it rather than
the unprobed `br dep list`.

### 2.5 Agent Mail and caam

- **Agent Mail:** FD only *sends* (`mail send`, `file_reservations release`, from release delivery).
  Nothing reads inboxes, threads, events or reservations.
- **caam:** no code at all. Docs only.

### 2.6 Enabling and disabling

- **Enable:** `FlywheelSetup.enable` writes a Python chain-runner `.git/hooks/pre-commit` (via `am
  guard install`) and `hooks.d/pre-commit/60-beads-sync.sh`.
- **Set Up:** also runs `br init`, `br agents --add` (edits AGENTS.md) and
  `am projects discovery-init`.
- **Disable: no UI path.** `FlywheelObserveService.disable(project:)` exists and nothing calls
  it. Level 3 makes FD act on repos, so an "off" switch moves from nice-to-have to likely
  required. Decide it in the spec.

---

## 3. The design space

These are from FOLLOWUPS and `FLYWHEEL-FLEET-MANAGEMENT.md`, grouped by what each depends on. The
spec should pick an order and a first slice, not design everything.

**A. Launch a swarm from released tasks.** Pick tasks (with `bv`'s ready/priority output?), claim
them in `br`, spawn N agents of chosen kinds/accounts, and hand each its task.
- Needs: spawn-with-first-prompt; an id back from `session.new` if the CLI or phone can do it.
- Open:
  - Who claims, FD or the agent?
  - How many agents, and of which kind?
  - Does launch reserve files up front?

**B. Fleet table.** Agent × current task × state × last active × account, with a row jumping to the
terminal.
- Needs: a last-active timestamp, account exposure (decide whether it ever reaches the phone),
  and the session ↔ task join made first-class rather than derived through Observe.

**C. Contested state and commit-guard visibility.** Required by the shared-main ruling.
- Needs: the reservations read, with a real row shape captured first. The guard's block message
  is an exact, capturable string (spike findings).
- Open: is "contested" a new `SessionStatus` value, an Observe lane, or both?

**D. Tending actions.**
- Reclaim & respawn a stuck agent's task. Release delivery already has a reclaim step to reuse.
- "Fresh eyes": a canned review prompt to a chosen agent.
- "Reread AGENTS.md".
- A tend-cadence nudge ("3 projects not tended in 14 min").
- A caam account/rate-limit strip.

**E. Agent Mail inbox anchored to tasks**, with unread threads read like unread sessions. Needs the
events read (`am inbox-events --after <cursor>`). The spike says to use `--direct` and avoid the
~2.5 s cold path of `am status`/`am inbox`.

**F. Task-graph convergence gauge:** ready / in progress / blocked / done per project. This is
separate from the planning rounds' convergence verdict.

**Later, after shared-main works: worktree mode.**
- An integrator role that serializes merges, runs the suite, and bounces failures back to the
  owning agent.
- Infrastructure-stack options: a stack per worktree, a stack for selected worktrees only, or one
  shared stack.

---

## 4. Open questions to resolve with the maintainer

1. **The first slice.** My read: **A + C** (launch from release, plus contested visibility) is
   the smallest loop where Level 3 *does* something and the shared-main ruling holds. B and D
   follow from what A makes visible. Get the maintainer's call.
2. **The phone.** Does any Level 3 control reach the phone in the first slice, or only status? The
   phone already has intake, plan, transport and notes (mobile phases 1–2).
3. **Autonomy.** Does FD claim and spawn on a human click only, or may it act on its own (respawn
   a stalled agent, nudge)? The Observe spec was explicitly read-only, so any autonomous action is
   a new trust boundary.
4. **Agent taxonomy.** Should `AgentAdapter`/`AgentKind` (`claude | codex`) adopt `ntm`'s richer
   taxonomy (cc/cod/gmi, personas, recipes)? This is unresolved, and it is tied to the separate
   "only two harnesses" gap (an OpenAI-compatible harness, from the coverage work).
5. **`ntm serve`.** It is ruled out as FD's runner. Its event-stream schema was never inspected.
   Is a transport spike worth it, or does FD read `am`/`br` directly for good?
6. **Disable.** What does turning Flight Control off do to a repo FD has been acting on: hooks,
   AGENTS.md section, open claims, reservations?

---

## 5. Known defects in what Level 3 sits on (FOLLOWUPS, "From Flight Control Observe Level 1")

- The three nil-stub lanes and the dormant notifier triggers. `br blocked` has no assignee, so
  lighting up the block trigger needs a join.
- `ObserveDrawer` always passes `unavailable: []`, so a degraded lane reads as empty rather than
  unavailable.
- A DAG rank leak and DAGCamera divide-by-zero cases.
- `FlywheelProcessRunner` still blocks on `waitUntilExit()`.
- `br update` has no `--if-version`, so release's recheck can still race another writer.
- The guard fails open when `project.json` is missing (upstream).
- Multi-repo and worktree reservations, TTL expiry and advisory guard modes were never tested
  (spike findings).
- A repo set up before `66fa004` may have a corrupted pre-commit (FOLLOWUPS, "Flight Control
  setup/enable").

---

## 6. Tests and harnesses to lean on

- **Fakes:** `MultiRunner` in `Tests/FlightDeckTests/Flywheel/Observe/ObserveTestSupport.swift`
  (stdout keyed by exe + first two args, records argv). Per-file `FakeRunner`s in the Flywheel,
  Spawn, EnableFlow and IntakeDelivery tests.
- **Fixtures:** `Tests/FlightDeckTests/Flywheel/Observe/Fixtures/` (am/br probe captures).
- **Live, skipped by default:**
  - `Intake/BeadWriterLiveTests` (real `br` in a scratch repo);
  - `Intake/RoundsLiveProbeTests` (spends tokens);
  - `scripts/flywheel-smoke.sh` (`FLYWHEEL_SMOKE=1`, two agents plus a guard block; no recorded
    result found).
- **Fleet/control:** `FleetTestHarness`, `FleetEmissionHarness`, `FleetLocalControlTests`,
  `CLIArgumentsIntakeTests`.
- **GUI checklists:** `docs/FLYWHEEL-OBSERVE-CHECKLIST.md`, `docs/FLYWHEEL-INTAKE-CHECKLIST.md`.
- `./scripts/test-unit.sh` exits 0 on failure: read its final `SHARDED UNIT RUN PASSED|FAILED`
  line.

---

## 7. Working rules for the design session

- Plan only because the maintainer asked for one. Use `superpowers:brainstorming` → spec →
  `superpowers:writing-plans`.
- Present the spec, then the plan, through Plannotator: EnterPlanMode, write the plan file,
  ExitPlanMode. Never ask for approval in chat.
- Use AskUserQuestion only for real design forks. §4 lists the likely ones.
- Show UI options as renders; the maintainer picks layouts from images. Offscreen `layer.render(in:)` on a
  parked `NSHostingView` works here; `screencapture` is denied.
- When a visual question arises, start the visual companion; don't offer it. Its URL must be
  reachable on the network: give the maintainer the `.local` URL and every alternate URL, each with its key.
- Specs go in `docs/superpowers/specs/`, plans in `docs/superpowers/plans/`. Update FOLLOWUPS in
  the same branch.
- The checkout is shared by concurrent sessions. Work in a worktree, symlink
  `vendor/*-artifacts`, never `git stash`, and commit by path.
- Don't launch a `DerivedData` bundle. Releases go through `scripts/swap-release.sh`, detached,
  and only when asked.

## 8. Sources

- `docs/FOLLOWUPS.md`: "Level 3 swarm: branch strategy", "Flight Control — next phases", "From
  Flight Control Observe Level 1", "From Flight Control intake…".
- `docs/FLYWHEEL-SPIKE-FINDINGS.md`, `docs/FLYWHEEL-FLEET-MANAGEMENT.md`.
- `docs/superpowers/specs/2026-09-18-flywheel-run-integration-design.md` (Level 0),
  `2026-09-24-flywheel-observe-design.md` (Level 1), `2026-09-26-flywheel-intake-design.md`
  (Level 2), `2026-09-29-flight-control-coverage-design.md`,
  `2026-09-29-flight-control-mobile-design.md`.
- `docs/superpowers/notes/2026-09-24-observe-command-shapes.md`: the probed command shapes.
