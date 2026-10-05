# Flight Control Level 3 — Swarm (L3-S)

Date: 2026-10-04. Status: design approved in brainstorming; spec under review.
Depends on: L3-0 only. Builds against fakes of L3-R, L3-I and L3-U.

## 1. Goal

Flight Deck runs a swarm on a project: it claims ready tasks, gives each to an agent configured
by the task's execution block, and keeps the swarm fed. You see each agent's task, account and
conflicts on the sessions themselves, and you can pause from the Mac or the phone.

**Success criteria:**
1. From a released intake, you click **Run tasks…**, set a cap of 3, and click Launch. Three
   agents start, each with its task as its first prompt.
2. When an agent closes its task, its slot gets the next ready task. An idle agent with the same
   configuration is reused after a context reset. Otherwise a new agent is spawned.
3. Each swarm session's sidebar row shows its task and state. The project header shows the
   swarm summary and the pool meters. The Observe drawer shows the assignment and any contest.
4. When two agents want the same file, the waiting agent's row is marked contested, and the
   drawer names the holder and shows the guard's message.
5. Pause on the phone stops new claims within one tick.
6. Turning Flight Control off drains the swarm and returns FD's claims to open.

## 2. Swarm record

A swarm is a persisted record. There is at most one swarm per project.

```json
{"id": "…", "project": "/path", "cap": 3, "poolCaps": {"ollama-local": 1},
 "filter": {"intake": "<intake id>"} | {"allReady": true},
 "state": "running|paused|draining|stopped",
 "agents": [{"session": "<uuid>", "agentName": "BlueLake", "config": "<config key>",
             "task": "fd-3x9" | null, "lease": {…}, "state": "starting|working|idle|handedOff|done"}],
 "createdAt": "…"}
```

- Stored in `~/Library/Application Support/Flight Deck/swarms.json`. Every action is appended to
  `swarm-log/<swarm id>.jsonl` (claim, spawn, reuse, prompt, close, hand-off, spill, pause,
  error).
- **After an app restart, a swarm comes back `paused`**, with a banner on the project header:
  "Swarm paused after restart · Resume". The agents themselves survive (fd-abduco). FD does not
  start claiming again until you say so.
- A **config key** is `harness|model|knobs|pool`. Two agents with equal keys are interchangeable
  for reuse.

## 3. Launch

**The launch sheet** opens from a released intake (**Run tasks…**) or from the project header's
Flight Control menu (**Run ready tasks…**). It shows:
- the ready tasks (`br ready --json`, ranked by `br scheduler --format json`), joined to their
  blocks from `br list --json`. `br ready` does not carry `agent_context` (probed, br 0.6.0);
- for each task: kind, harness/model/knobs, pool, and a source chip (rule, index, default, spill,
  pinned). The router is re-run for tasks that are not pinned before the sheet opens;
- **Override** per row: an editor for harness/model/knobs/pool that sets `pinned: true` and
  writes the block back;
- unroutable tasks, greyed, with the reason;
- the **cap**, overall and per pool (local pools default to their own cap).

**Launch** creates the swarm record in `running` and starts the controller.

## 4. The controller

`SwarmController`, one per swarm, `@MainActor`. It ticks on the shared `WatchClock`, and on
events: a task closed, a session went idle, a lease freed, a hand-off finished.

**Each tick, while `running`:**
1. **Free slots** = cap minus agents that are `starting` or `working`.
2. For each free slot, take the next task in scheduler order that matches the filter, is ready,
   and is not claimed by this swarm.
3. **Resolve its config.** The block's pool → `PoolAllocator.lease`. If there is no lease, call
   L3-R `spill`. If the block is pinned, or spill finds nothing, the task is **waiting**. Record
   why and move on to the next task.
4. **Reuse or spawn:**
   - **Reuse:** an `idle` swarm agent with the same config key whose account is still under
     soft. FD releases its reservations, calls `resetContext(session)`, and moves on to step 5.
     If the agent is asleep (smart sleep), it is woken first.
   - **Spawn:** `SwarmSpawner.spawn(task, block, lease)`, which calls
     `createSession(agent:in:account:overrides:)`. `LaunchOverrides` carries the model and knobs.
     Today the model comes only from preferences. The adapter's `launchOverrides` capability maps
     them to flags or to a session parameter.
5. **Claim:** `br update <id> --claim --actor <agentName>`. br's claim is atomic (probed: a second
   claim fails with `VALIDATION_FAILED`, `retryable: true`). On conflict, drop this task for this
   tick and take the next.
   - The order is: boot the identity (spawn), then claim, then prompt. A claim that fails after a
     spawn leaves an idle agent, which the next tick can reuse.
6. **First prompt:** wait for the adapter's composer-ready signal (the existing inject gate), then
   `submitPrompt`. The task prompt template:
   - "Your task is <id>: <title>."
   - the description and acceptance criteria, from `br show`;
   - "Reserve the files you will edit with Agent Mail before you edit them."
   - "When the acceptance criteria hold and your work is committed, run `br close <id>`."
   - "If you are blocked, say so in one line that starts with BLOCKED:, then stop."
7. The agent becomes `working`.

**Completion.** `FlywheelWatcher` already polls on `.beads/beads.db` changes. The controller
watches its claimed task ids. When one becomes `closed`, the agent becomes `idle` and its slot is
free. If a task goes back to `open` while its agent still holds it, the controller logs it and
treats the agent as idle.

**Hand-off** is driven by L3-U's `HandoffDriver`. The controller supplies the spawner and updates
the record (`handedOff` on the old agent, a new agent for the new tab).

**Stopping.**
- **Pause:** no new claims or spawns. Running agents continue.
- **Drain:** like pause, and the swarm becomes `stopped` when the last working agent goes idle.
- **Stopped:** the swarm keeps nothing running. Its tabs stay open.
- The swarm also stops on its own when nothing is ready, nothing is waiting, and no agent is
  working.

## 5. Session id from `session.new`

`flightdeck new` and the wire's `session.new` (`FleetService.swift`, about lines 1136–1198) ack
**before** they create the session and never return its id. L3-S changes `session.new` to reply
**after** creation with `{sessionId}` or an error. The new frame case and every handler arm land
in **one commit** (wire enum cases are atomic). `flightdeck new` prints the id. This is what
lets the CLI and the phone address what they started.

## 6. Annotations on existing surfaces

There is no separate swarm view (the Observe spec ruled out a roster: the sidebar is the
roster).

- **Sidebar session row** (swarm sessions only):
  - a task chip `fd-3x9 · snapshot-tests`;
  - a contested badge;
  - a small account meter when the account is past soft;
  - markers: *waiting*, *handed off →*, *done*.
- **`ProjectHeaderRow`:**
  - the summary `swarm 3/3 · 2 waiting · 1 contested`;
  - Pause/Resume;
  - a popover with the pool meters (from L3-U) and the waiting tasks with their reasons;
  - the restart banner (§2).
- **Observe drawer:** a new `ObserveLane.assignment`, first in order. It shows:
  - the task;
  - the kind;
  - harness/model/knobs;
  - the routing source and reason;
  - the account and its meter;
  - the hand-off history, with links to the previous and next tab;
  - **contested detail** (§7).
- **`SessionStatus.lastActiveAt`:** a new timestamp, set on every activity transition. The row
  and the drawer show "active 4 min ago".

## 7. Contested visibility

1. **Capture the real row shape first.** In a scratch repo, two agents reserve overlapping globs.
   Record `am`'s reservations output as a fixture. The existing `am-reservations-all` fixture is
   an empty `all_active`, which is not enough.
2. **Implement `FlywheelReadCommands.reservations`** against that shape. This replaces the nil
   stub at `FlywheelReadCommands.swift:80-102`.
3. **Implement `depEdges`** by reusing `IntakeKit/GraphReader` (`br graph --all --json`), as the
   handoff suggests, instead of the unprobed `br dep list`.
4. **Guard blocks.** Capture the guard's exact block message (spike findings) from the agent's
   output. For claude, the hook record script sees tool results. For codex and OpenCode, use the
   adapter's tool-output stream. Store the last block per session.
5. **Contested is a relation, not a status.** An agent is contested when it has a recent guard
   block, or when it said BLOCKED: on a file another agent holds. The drawer says "waits on
   `Sources/Foo.swift`, held by GreenFox · 6 min" and quotes the guard message. `SessionStatus`
   is not changed. The Observe files lane shows the holders.
6. The dormant `FlywheelNotifier` triggers light up on this data. This is a side effect, and the
   tests cover it.

## 8. Phone

New wire cases, each landing atomically with its handlers:
- **Swarm projection** per project: the summary, each swarm session's annotation (task, kind,
  model, account display name, state, contested), and the pool meters.
  - Account names go **only** through this projection, never through the general fleet wire. This
    keeps `FleetAccountEmissionTests` true for the fleet wire.
- **Commands:** `swarm.pause`, `swarm.resume`, `handoff.confirm`, `handoff.decline`.

The phone draws the chips on its existing fleet rows, plus a project-level card with
Pause/Resume and the meters. Launch and rule editing stay on the Mac.

## 9. Disable

- **Turn off Flight Control** (project settings and the header menu):
  1. Drain every swarm on the project, then stop it.
  2. Set FD-held claims back to open (`br update <id> --status open --assignee ""` for tasks that
     this swarm claimed and that are not closed).
  3. Release the reservations of FD-booted agents.
  4. Stop the watcher. Hooks, AGENTS.md and `.beads` stay as they are.

  This finally calls the unused `FlywheelObserveService.disable(project:)`.
- **Remove from repo…** (separate, with a confirmation that lists what it changes): uninstall the
  guard and the beads-sync hook, and remove the AGENTS.md section that `br agents --add` wrote.
  It leaves `.beads` data alone.

## 10. Error handling

- **Spawn fails** (for example the Agent Mail boot fails and `createSession` refuses the tab):
  the task stays unclaimed and the failure is logged. After 3 failures in a row on one config,
  the swarm pauses with a banner.
- **The claim races:** the next task is taken (§4).
- **No composer-ready within 2 min:** the agent is marked *stuck at start* and its claim is
  returned to open. The agent is not killed.
- **`resetContext` fails:** spawn a new agent instead. The old agent stays idle and is not reused
  again.
- **An unroutable block:** skipped, shown in the launch sheet and the header popover.

## 11. Testing

UI coverage is automated as far as it can be.

- **Controller:** a state machine driven by fake br, fake spawner, fake allocator, fake router
  and a fake clock. It covers:
  - cap filling;
  - reuse versus spawn, and the config-key match;
  - claim conflict;
  - waiting, spill and pinned;
  - completion, pause, drain, auto-stop;
  - restart restoring as paused;
  - the stuck-at-start and reset-failure paths.
- **`MultiRunner` fixtures** for `br ready`, `br scheduler`, `br list` with blocks, and
  `br update --claim` (success and conflict).
- **Reservations:** the captured real shape. **Guard capture:** recorded tool outputs.
- **Wire:** `FleetTestHarness` and `FleetEmissionHarness` for `session.new` → id, the swarm
  projection, and the commands. `FleetAccountEmissionTests` stays green.
- **XCUITest** (`UITests/FlightDeckUITests/SwarmUITests.swift`):
  - drives the real app with a **fixture backend**, selected by the launch argument
    `-FlightControlFixtureBackend <dir>` together with `-FlightDeckResetState YES`. The backend
    serves recorded `br`/`am` output;
  - the fake adapter's launch command runs a small stub agent script that draws a composer box and
    echoes prompts. Debug builds only;
  - covers launch from the sheet, the row chips, the header summary, the drawer's Assignment lane,
    pause/resume, the contested badge, the restart banner, and the hand-off marker;
  - attaches a `XCUIScreenshot` at each state;
  - runs from `scripts/test-ui-flight-control.sh`, not `smoke.sh`. It warns before taking the
    foreground and honors the same throttle.
- **Phone:** `FlightDeckMobileTests` for the projection decode and the chips' styling.
  `FlightDeckMobileUITests` for the swarm card with fixture frames.

## 12. Basic tasks for the maintainer

A short set of real tasks to try once it is merged:
1. Release a small intake (3–4 tasks) on a scratch project with Flight Control on. Click
   **Run tasks…**, set the cap to 2, launch.
2. Watch one agent finish and its slot pick up the next task. One of them should be a reuse
   (same tab, cleared context).
3. Give two tasks the same file on purpose. Check that the contested badge and the drawer detail
   appear.
4. Pause from the phone. Check that no new claim happens. Resume.
5. Turn Flight Control off on the project. Check that open claims went back to open.

## 13. Provides at integration

`SwarmController`, `SwarmSpawner`, the launch sheet, the annotations, the contested read side,
the wire changes, the phone views, and disable.

## 14. Files

- `Sources/FlightDeck/FlightControl/Swarm/SwarmController.swift`, `SwarmStore.swift`,
  `SwarmSpawner.swift`, `TaskPrompt.swift`, `LaunchSheet.swift`, `SwarmAnnotations.swift`
- `Sources/FlightDeck/SessionStore.swift`: `createSession(…, overrides:)`, `lastActiveAt`
- `Sources/FlightDeck/Flywheel/Observe/FlywheelReadCommands.swift`: reservations and depEdges
- `Sources/FlightDeck/Flywheel/Observe/ObserveDrawer.swift`: the assignment lane
- `Sources/FlightDeck/ProjectHeaderRow.swift`, `SidebarRow.swift`
- `Sources/FleetKit/Frames.swift`, `Wire.swift`: `session.new` reply, swarm projection, commands
- `Sources/FlightDeck/Fleet/FleetService.swift`, `Sources/FlightDeckCLI/…`
- `Sources/FlightDeckMobile/…`: flat, per the mobile rule
- `Tests/FlightDeckTests/FlightControlL3/Swarm/…`, `UITests/FlightDeckUITests/SwarmUITests.swift`,
  `scripts/test-ui-flight-control.sh`
