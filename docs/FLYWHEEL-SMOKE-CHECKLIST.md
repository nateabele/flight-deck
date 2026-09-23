# Flywheel real-agent smoke checklist

> **⚠️ Consumes real tokens and steals GUI focus.** This drives two live `claude` tabs
> inside Flight Deck. Run it deliberately, at a moment you can babysit it — never
> unattended, never from CI, never while you're mid-task in another window.

## Purpose

The Flywheel spike (`docs/FLYWHEEL-SPIKE-FINDINGS.md`) proved the coordination
substrate works via direct CLI calls with synthetic identities. It did **not** prove
that two agents FD actually spawns get distinct `AGENT_NAME`s, or that the
reservation guard blocks a real conflicting commit between them. This checklist
closes that gap: it is the manual runbook for `scripts/flywheel-smoke.sh`, the harness
that sets up an isolated scratch repo, walks you through driving two real agents at it
in Flight Deck, and verifies the substrate afterward.

## Prerequisites

- A **Debug** Flight Deck build running the `worktree-flywheel-run-integration`
  branch (or whichever branch has this feature).
- `am`, `br`, `flywheel-new`, and `jq` on `PATH`.
- Nothing else demanding your focus for the ~5 minutes this takes — the setup and
  verify phases are quick, but the two agent tabs need your attention to drive them.

## Steps

### 1. Set up the scratch repo

```bash
FLYWHEEL_SMOKE=1 scripts/flywheel-smoke.sh setup
```

This creates an isolated repo under a temp dir (`mktemp -d`), runs `flywheel-new` in
it, installs the reservation guard (`am guard install`, which `flywheel-new` does
**not** do on its own), and creates two beads for the two agents to claim. It prints
the scratch repo path, the two bead IDs, and the manual steps below with those IDs
filled in — follow its printed output, it's the source of truth if this doc drifts.

**Expect:** a `✅ Scratch flywheel repo ready` block naming the repo path and two bead
IDs (`agent 1: <id>`, `agent 2: <id>`).

### 2. Add the scratch repo to Flight Deck and enable Flywheel

- In Flight Deck: add the printed scratch repo path as a project.
- Project header menu → since `flywheel-new` already ran in step 1, this project is
  detected as a flywheel project, so the item reads **"Enable Flywheel…"** (a plain
  repo with no `.beads`/`.agent-mail.yaml` instead shows **"Setup Flywheel…"**, which
  additionally bootstraps those before installing the guard) → confirm the setup
  dialog.

**Expect:** the confirm dialog appears and completes without error; the project now
shows as Flywheel-enabled.

### 3. Spawn two claude tabs in that project

Open two new `claude` tabs in the scratch project.

### 4. Drive agent 1 — claim, reserve, commit

Give agent 1 this one-line task (substitute the real bead ID and repo path from
step 1's output):

> claim bead `<id-1>` (`br update <id-1> --claim --actor $AGENT_NAME`), reserve
> `foo.txt` (`am file_reservations reserve <repo> $AGENT_NAME foo.txt --exclusive`),
> then edit + commit `foo.txt`.

**Expect:** the bead claim, reservation, and commit all succeed. Agent 1's commit
should go through cleanly (it holds the reservation).

### 5. Drive agent 2 — claim, then attempt the conflicting commit

Give agent 2 this one-line task, **redirecting its commit output to the log the
verifier reads**:

> claim bead `<id-2>` (`br update <id-2> --claim --actor $AGENT_NAME`), then try to
> edit + commit `foo.txt`, redirecting stdout+stderr of the commit to
> `<repo>/.smoke-agent2.log` — this must be blocked by the guard.

**Expect:** agent 2's commit is **blocked**, exit non-zero, and
`<repo>/.smoke-agent2.log` contains the marker line:

```
mcp-agent-mail: file reservation conflict detected!
```

If agent 2's commit instead **succeeds**, the guard failed open — that's the defect
this smoke test exists to catch, not something to work around by hand.

### 6. Verify

```bash
FLYWHEEL_SMOKE=1 scripts/flywheel-smoke.sh verify <scratch-repo>
```

This asserts the three PASS criteria against the substrate and prints `PASS`/`FAIL`
per check, exiting non-zero if any fail:

1. **Two distinct `AGENT_NAME`s registered** — `am agents list <repo> --json` shows
   ≥2 distinct agent names.
2. **Conflicting commit was blocked** — `<repo>/.smoke-agent2.log` contains the
   `mcp-agent-mail: file reservation conflict detected!` marker.
3. **Both bead claims visible** — `br list --status in_progress --json` (run from
   `<repo>`) shows the two beads `in_progress` with two distinct assignees.

**Expect:** `ALL CHECKS PASSED` and exit 0. Any `FAIL` line names exactly which
criterion didn't hold and what command to re-check by hand.

### 7. Teardown

```bash
FLYWHEEL_SMOKE=1 scripts/flywheel-smoke.sh teardown <scratch-repo>
```

Removes the scratch repo directory. Agent Mail's project/agent registrations are
global state keyed by path and are **not** cleaned up — they're harmless scratch left
behind once the path no longer resolves to a real repo (`am doctor` if a real cleanup
is ever needed).

Also close the two claude tabs you spawned in step 3 and remove the scratch project
from Flight Deck's project list.

## Pass criteria (summary)

- [ ] Two distinct `AGENT_NAME`s registered for the scratch project.
- [ ] Agent 2's conflicting commit was blocked with the exact guard marker.
- [ ] Both beads show `in_progress` with two distinct assignees.
