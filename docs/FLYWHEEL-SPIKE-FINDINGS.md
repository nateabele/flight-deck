# Flight Control integration — spike findings & architecture verdict

*Evidence-based follow-up to [FLYWHEEL-INTEGRATION.md](FLYWHEEL-INTEGRATION.md) and
[FLYWHEEL-FLEET-MANAGEMENT.md](FLYWHEEL-FLEET-MANAGEMENT.md). Four technical spikes
run 2026-09-17 to resolve the open questions those docs flagged before committing to
a build. Each finding below is backed by captured output (exact exit codes/messages,
JSON envelopes, timing samples, error logs) from isolated scratch environments — no
real beads/Agent-Mail/ntm state was touched.*

## The verdict: who runs the swarm

**Flight Deck runs its own agents (existing `fd-abduco` PTY engine) and reads/writes
the shared on-disk beads + Agent-Mail substrate directly. NTM is not in the loop.**

This resolves the pivotal fork the docs named. Three spikes converge on it:

- **Spike A** proved the coordination substrate (`br` beads + `am` reservations/guard)
  is architecturally **spawner-agnostic** — pure CLI binaries keyed by project path +
  explicit identity args, with a concrete spawn-time contract (below). FD-launched
  plain processes participate fully; no tmux/ntm required.
- **Spike C** proved the alternative — observing an NTM swarm via `ntm serve` — is a
  **dead end for FD's own agents**, on two independent grounds: (1) the installed
  `ntm` binary is built `CGO_ENABLED=0`, so its sqlite driver is a stub and
  `ntm serve` **cannot start at all**; (2) even working, NTM discovers agents by
  enumerating **tmux sessions**, and FD's agents are plain PTYs that never enter
  tmux — so NTM would see nothing of them regardless.
- **Spike B** proved reading the substrate directly is **cheap** (sub-200ms JSON,
  FSEvents-watchable), so "FD reads the substrate" carries no performance penalty.

"Observe an NTM-run swarm" is therefore not a distinct FD product — if that's ever
wanted, the read surface is `ntm --robot-status`/`--robot-snapshot` (CLI, which work
despite the broken state store), not `serve`.

---

## Spike A — Is the substrate spawner-agnostic? *(the crux — YES, conditionally)*

**Answer: yes, architecturally** — but `flywheel-new`'s bootstrap is incomplete and
the correct per-agent boot call is non-obvious. Get it wrong and the guard **fails
open** (silently allows conflicting commits) instead of enforcing.

**What `flywheel-new` does:** `git init` → `br init` (project-local `.beads/`) →
`br agents --add` (writes a *generic* `AGENTS.md` — ready/claim/work/close; it does
**not** mention the flywheel's Plan→Encode vocabulary) → `ntm init` (installs
`pre-commit`/`post-checkout` hooks for **beads-JSONL sync + UBS scan**, *not* the
reservation guard) → `flywheel-guard` (installs **DCG** PreToolUse hooks per agent
config) → `am projects discovery-init` (writes an `.agent-mail.yaml` marker only).

**The gaps FD must close (the spawn-time contract):**

1. **Per repo, once:** run `am guard install <path> <path>` — `flywheel-new` skips it,
   so reservation enforcement is *off by default*. (It composes cleanly with ntm's
   hook: moves it to `pre-commit.orig` and chains.)
2. **Per agent, at spawn:** run `am macros start-session --project <abs-repo-path>
   --program <claude-code|codex-cli> --model <model> -n <AdjNoun> [--reserve <globs>]`.
   This is the canonical boot call — **not** raw `am agents register`, which leaves
   out the `projects/<slug>/project.json` metadata the guard needs to resolve the
   archive unambiguously (its absence is what makes the guard fail open).
3. **Inject `AGENT_NAME=<returned agent.name>`** (ideally also `AGENT_MAIL_AGENT`/
   `AGENT_MAIL_PROJECT`) into the spawned process's environment. The pre-commit guard
   reads `AGENT_NAME` to know who is committing; the tmux-pane auto-identity fallback
   is the *only* ntm/tmux-specific mechanism, and `AGENT_NAME` fully substitutes for
   it. **Without it, with any active reservation, every commit blocks (fails closed).**

**Proof it works once wired:** holder `BlueFalcon` reserved `widget.py`; a second
identity's conflicting commit was **blocked, exit 1** (`mcp-agent-mail: file
reservation conflict detected! widget.py conflicts with reservation 'widget.py' held
by BlueFalcon`); the holder's own commit succeeded, exit 0.

**Also:** `br` is fully self-contained/project-scoped (`no_automatic_git_operations`);
`br coordination status --json` even has a `blocked_by_active_reservation` counter, so
beads is *designed* to cross-reference Agent-Mail reservation state. DCG is orthogonal
and automatic (any `claude`/`codex` picks it up via normal config discovery).

**FD consequence:** FD must also own the **beads-sync** step (`ntm init`'s hooks do it
for ntm-spawned agents; FD-spawned agents need `br sync --flush-only` + committing
`.beads/`, FD-driven).

---

## Spike B — Read model, watchability, latency *(cheap; watch-then-poll)*

- **`br`/`bv` are direct-SQLite, fast, versioned JSON:** clean envelopes
  (`br.coordination.v1`, `br.scheduler.v1`), a `data_hash` for cheap change-detection.
  `br ready --json` ~40–60ms; `bv --robot-plan/priority/insights -f json` ~70–180ms.
  No daemon exists in this build (`daemon_fallback_reason:"no-daemon"`) and none is
  needed.
- **Watchability = watch-then-repoll, not push:** every mutation synchronously
  rewrites `.beads/issues.jsonl` (full-file snapshot export) and touches `beads.db`.
  An **FSEvents watch on each project's `.beads/` dir** reliably fires on every write
  → trigger a cheap re-poll instead of a blind interval timer.
- **Agent Mail is different — a single *global* shared SQLite**
  (`~/.local/share/mcp-agent-mail/…/storage.sqlite3`), projects distinguished by key
  (not workspace-local like beads). FD must be careful with **project-key scoping**.
  `am inbox-events --after <cursor>` is a genuine durable event-tail; `am robot
  timeline --since` supports incremental polling.
- **The `am` cold-path tax:** `am status`/`am inbox` cost **~2.5s each** — they probe a
  non-running HTTP daemon (`127.0.0.1:8765`), eat a connection-refused, then fall back
  to SQLite. The reservations-family commands skip this and stay fast. **Mitigation:**
  use the fast/`--direct` commands + `am inbox-events` cursor tailing, or run a small
  `am serve-http` daemon (which also unlocks its HTTP event surface).

**All six proposed read views are feasible:** bead-state ring (`br count --by status`),
dependency DAG (`br graph`/`dep tree`), ready/blocked (`br ready`/`blocked`), triage
ranking (`bv --robot-*`), reservations badge (fast `am` path), mail inbox
(`am inbox-events`).

**Transport decision:** FSEvents-triggered polling of the substrate. No FD-side
long-lived helper needed for `br`/`bv`; one optional `am serve-http` for Agent Mail.

---

## Spike C — `ntm serve` as a live source *(not viable — see verdict)*

- Installed `ntm` is `CGO_ENABLED=0`; `ntm serve --port …` fails immediately: *"go-sqlite3
  requires cgo to work. This is a stub."* No live REST/SSE could be captured.
- NTM discovery is **tmux-scoped** (enumerates any tmux session machine-wide,
  content-sniffs pane type) — **not** process-scoped. FD's non-tmux PTY agents are
  invisible to it under all circumstances.
- `ntm --robot-status`/`--robot-snapshot` (CLI) *do* work without the state store
  (read tmux + filesystem live) — the only usable NTM read surface, and only for
  NTM's own tmux world.

**Consequence:** do not build FD's Flight Control integration on `ntm serve`. (Caveat: this
is the *installed* build; a cgo-enabled rebuild would fix `serve`, but the tmux-scope
limitation would remain, so the conclusion holds.)

---

## Spike D — Level-2 novelty sizing *(both components are heavy)*

- **Convergence gauge → mostly must-compute.** No tool emits the four signals
  (dependency-churn, revision-similarity, length-delta, semantic-density) or a
  readiness score. `issues.jsonl` is **last-write-wins** (no text-revision log,
  confirmed empirically). Only **signal 1 (dependency-churn) is cheap** — the SQLite
  `events` table logs `dependency_added`/`status_changed` with old/new values (queryable
  via `br audit log`). Signals 2–4 need FD to **snapshot and diff bead text across
  rounds itself**, via `.beads/.br_history/*.jsonl` (whole-file, only written on
  `br sync`, default-pruned to last 100) or git-log of `.beads/issues.jsonl`. Fidelity
  is bounded by sync/commit cadence. → FD owns a signal-computation pipeline.
- **Encode button → agent-orchestration.** No `encode` verb exists in `br`/`bv`/`ntm`.
  The only primitive is `br create -f <plan.md>` — a naive splitter (`## Title` → issue,
  first paragraph → description; no dependency/type/priority/acceptance-criteria
  inference). Real encoding requires an LLM agent driving a sequence of `br` mutators.
  → FD's Encode button must drive an **agent task**, with `br create -f` only as a
  literal-import fallback.

**Consequence:** Level 2 (Author) is the expensive tier — neither piece is a thin CLI
wrapper. Size accordingly and sequence it after Level 1.

---

## What needs to be built, per level (evidence-based)

**Level 0 — Run-integration enabler (foundational; nothing else works without it).**
FD's agent-spawn path must fulfill the Spike-A contract: add `am guard install` to
project bootstrap; call `am macros start-session` per agent and capture `agent.name`;
inject `AGENT_NAME` into the spawned PTY environment; own the `br sync`/`.beads/`
commit step. This is what turns "FD hosts terminals" into "FD runs the swarm."

**Level 1 — Observe (cheap, high signal).** FSEvents watch on `.beads/` → repoll
`br`/`bv` JSON. Per-project bead-state ring on `ProjectHeaderRow`; ready/blocked/DAG/
triage views in the `RootView` `detail:` column (sibling to `TerminalPane`);
reservations badge + a new *contested* state in `SessionStatusIcon`; Agent-Mail inbox
via `am inbox-events`. Mind the `am` cold-path tax.

**Level 2 — Author (heavy).** Convergence gauge (FD-owned signal pipeline) and Encode
button (agent-orchestration). Leans on the already-multi-session `PlanGateService`/
Plannotator machinery (whose unimplemented `"verdict"` tier is the nearest seam).

**Level 3 — Operate (actions on live state).** Reclaim-&-respawn, fresh-eyes prompt,
tend-cadence nudge, `caam` account strip. Guard-block visibility is achievable — the
pre-commit guard emits an exact, capturable conflict message (Spike A).

## Open items / follow-ups

- **Live-agent smoke test:** Spike A simulated the agent's shell steps; a real
  `claude`/`codex` committing mid-session (same git-hook path) is the strongest
  confirmation, and should also exercise the **MCP-tool path** (`am serve-http`/stdio)
  a real agent uses instead of raw CLI.
- **Upstream flags:** `flywheel-new` skipping `am guard install`; the guard's
  slug-collision **fail-open** (its source cites GH#228 intending fail-closed). FD
  should never rely on a bootstrap path that skips `am macros start-session`.
- **`am` global-DB project-key scoping** must be handled carefully in FD code.
- **`ntm` cgo build** — the installed binary's broken `serve`/state-store; not on FD's
  path given the verdict, but worth noting to whoever maintains the ntm install.
- Not tested: multi-repo/worktree reservation scenarios, reservation TTL expiry/renewal,
  `am guard` advisory/warn modes, deep CASS integration (⌘K source / indexing FD
  transcripts — a separate later spike).

## Next step

Brainstorm → spec the **first build increment** (recommended: Level 0 run-integration
enabler + Level 1 Observe together, since Observe is only meaningful once FD can spawn
agents correctly into the substrate), then `writing-plans`.
