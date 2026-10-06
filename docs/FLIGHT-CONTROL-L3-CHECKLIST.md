# Flight Control Level 3 — swarm checklist (L3-S)

Real tasks to try once L3-S (and the integration branch that wires L3-R/L3-U's real conformers)
is merged and a Release build is installed. Spec §12. Agents cannot drive the GUI here
(AGENTS.md rule 2); `scripts/test-ui-flight-control.sh` covers the same surfaces against stubs
only (it passed against the stub fixture backend, never against real claude/codex/am/br).

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
