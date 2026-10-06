# Flight Control Level 3 — swarm checklist (L3-S)

Real tasks to try once the `l3-integration` branch (which wires L3-R/L3-I/L3-U's real conformers
into the swarm) is merged and a Release build is installed. Spec §12. Agents cannot drive the GUI
here (AGENTS.md rule 2); the UI suites (`scripts/test-ui-flight-control.sh` and the others) run
under `-FlightControlFixtureBackend`, which skips `FlightControlComposition`, so they passed
without ever touching the real joined graph or real claude/codex/am/br. These tasks are the only
real-stack check.

Use a scratch project with Flight Control on ("Set Up Flight Control…" in the project header's
context menu, on a throwaway repo under your home directory).

1. **Launch.** Release a small intake (3–4 tasks). On the released intake, click **Run Tasks…**
   (the project's context menu also has **Run Ready Tasks…**). Check every row shows a kind, a
   model and a source chip, and any unroutable task reads "unroutable: <reason>". Set
   **Agents at once** to 2 and click **Launch**.
   - Two new tabs open, each starting with "Your task is <id>: …".
   - Each tab's sidebar row shows `<id> · <kind>`.
   - Right-click the project → **Swarm Details…** shows the counts (`swarm 2/2` in the header).
2. **Keep fed, and reuse.** Watch one agent finish (`br close`). Within a few seconds its slot takes
   the next ready task. If the next task has the same harness/model/pool, it lands in the SAME tab,
   after `/clear` (or `/new` for codex; unverified live) — the row's chip changes, no new tab opens.
3. **Contested.** Give two tasks the same file on purpose. When the second agent's commit is
   refused, its row shows the lock badge, and its Observe drawer's **Assignment** lane says
   "waits on <file>, held by <agent> · N min" and quotes the guard. (The lane needs the tab to have
   an Observe agent row.)
4. **Phone pause.** On the phone, the project card shows the summary and meters. Tap **Pause**;
   no new task is claimed (watch `br list --status in_progress` stay put when an agent finishes).
   Tap **Resume**; claiming continues. On the Mac, **Pause Swarm** / **Resume Swarm** /
   **Drain Swarm** / **Stop Swarm** are in the project's context menu.
5. **Off.** Right-click the project → **Turn Off Flight Control…** → **Turn Off**. Check
   `br list --status in_progress --json` lists none of the swarm's tasks (they went back to open),
   and the repo's hooks, AGENTS.md and `.beads` are unchanged (`git status`).

Also look at, once each:
- Quit and reopen Flight Deck mid-swarm: the header shows "Swarm paused after restart · Resume";
  nothing is claimed until **Resume Swarm** (project context menu).
- **Remove Flight Control from Repo…** on a project that has it off (offered only while the guard
  or task-sync hook is still installed): the confirmation lists the guard, the task-sync hook and
  the AGENTS.md section, and says the task data stays. Afterwards expect an `AGENTS.md.bak` next to
  `AGENTS.md`: `br agents --remove` writes it, and Flight Deck does not delete it.

Level 3 integration checks (routing, capacity and capability index, joined by
`FlightControlComposition`):

6. **Routing rule.** In Settings → Flight Control → Routing, write "Use Codex for unit and
   integration tests" and confirm it. Release an intake with a test task, and check that the
   task's routing chip says *rule*.
7. **Capacity and spill.** In Settings → Flight Control → Capacity, put two claude accounts in one
   pool. Run a swarm agent on the first until its bar passes the soft tick. Check that the next
   task starts on the second account. If "Confirm hand-offs" is on, the confirmation arrives on
   the phone only; the old tab then shows "handed off →" and is no longer driven.
8. **Capability index.** In Settings → Flight Control → Capability index, click **Refresh now**
   (this spends tokens). Check that the heatmap fills in and each cell links to its source.
