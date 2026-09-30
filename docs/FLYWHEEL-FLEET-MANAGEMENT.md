# Extending Flight Deck into a Flywheel fleet manager

Companion to [FLYWHEEL-INTEGRATION.md](FLYWHEEL-INTEGRATION.md), which covers cheap
bolt-on hooks (DCG, a beads badge, ⌘K via CASS). This doc is the deeper question:
what would it take for Flight Deck to become the **operating console for the
Flywheel's swarm methodology**, not just a nicer terminal for it — plus the UI
concepts that follow. Grounded in `agent-flywheel.com`'s own methodology docs and a
read of FD's `Fleet/`/`Agents/` source layout.

## The methodology, compressed

The flywheel's **core loop** is six stages: **Plan → Encode → Triage → Coordinate →
Implement → Close**. A human writes a markdown plan (competing drafts from multiple
models, synthesized); an agent **encodes** it into **beads** (self-contained,
dependency-linked tasks) via `br`; the human polishes beads over 4-6 rounds until
four **convergence signals** plateau (dependencies stabilize, revisions converge,
length delta → 0, semantic density flattens — weighted score ≥0.75 = ready, ≥0.90 =
diminishing returns); `bv` **triages** by graph centrality (PageRank/betweenness) to
find the highest-leverage ready bead; agents **coordinate** by claiming beads and
reserving files through **Agent Mail**; they **implement**; closing a bead reshapes
the graph and unblocks new work.

The **coordination trio** — beads (state) + Agent Mail (negotiation) + bv (routing)
— is explicitly a three-legged system: remove any leg and the swarm loses
determinism. Agents are **fungible generalists** (no specialists, no
single-point-of-failure ringleader) — a crash just means another agent reclaims the
`in_progress` bead. The human's job during execution is **tending**: a 10-15 minute
cadence of checking `bv` recommendations and Agent Mail threads, nudging stuck
agents ("reread AGENTS.md" after compaction is the single most common
intervention), triggering fresh-eyes reviews, and switching accounts via `caam`
when rate-limited. The stated end-state is a "puppet-master" agent driving `ntm` in
robot mode, retiring even the tending loop.

## The fork you have to decide: worktrees vs. shared-main

This is the one place FD's existing design and the flywheel's methodology actively
disagree, and it should be named rather than papered over.

- **Flight Deck, today:** per-agent git **worktrees** (`worktree-detach-phase1`,
  `worktree-fix-rename` are recent merged work) — each agent isolated on its own
  branch/tree.
- **The flywheel's methodology:** explicitly **rejects** branch-per-agent as
  "merge-hell" and mandates a **single shared branch** (`main`), with conflict
  avoidance done entirely through *advisory* mechanisms — Agent Mail file
  reservations (TTL-based, so a crashed agent can't deadlock), a pre-commit guard
  that blocks commits to files reserved by someone else, and DCG blocking
  destructive commands outright.

These are two different concurrency philosophies, not a bug in either. **Strategy:
make coordination-mode a per-project setting**, not a global rewrite:
- *Worktree mode* (existing FD behavior) — good for exploratory/divergent work,
  reviewed and merged deliberately.
- *Shared-main mode* (flywheel-native) — good for a beads-driven swarm converging
  on one plan; requires surfacing reservations and the pre-commit guard in the UI
  (see below), since without a terminal the human has no other way to see them.

## Three levels of ambition

### Level 1 — Observe (cheap, already covered)
Shell out to `br`/`am`/`bv --json` and render read-only badges. See the companion
doc. Real value, no architecture change.

### Level 2 — Author: FD becomes the Plan → Beads front-end
This is where `PlanGateClient/Service` and `PlannotatorRegistry` (already in
`Sources/FlightDeck/Fleet/`) matter — FD already has *some* notion of gating a
session on a plan being approved. Extending that machinery to natively drive the
flywheel's **Plan → Encode** stages turns the most human-intensive, highest-leverage
part of the loop (planning is "the cheapest place to buy correctness" per the
methodology — 1x rework cost vs. 25x once code exists) into a first-class FD
experience instead of something that happens in a terminal pane FD merely hosts:
- A **plan-authoring view** (not just a gate on an existing agent-driven plan):
  competing draft plans side-by-side, a synthesis step, then **Encode to beads**
  as an explicit action that shells to `br`/an encoding agent.
- A **convergence gauge** during bead polishing, rendering the methodology's own
  four signals live (dependency-churn trend, revision-similarity, length delta,
  semantic-density plateau) instead of a human eyeballing diffs across rounds —
  this is a genuinely novel visualization the CLI tools don't offer.
- A **bead graph view** (dependency DAG, ready/blocked/in-progress/done coloring) —
  `bv --export-graph .html` already emits an interactive HTML graph; embedding or
  reimplementing that view natively is a concrete, scoped starting point.

### Level 3 — Operate: FD as the swarm console
The ambitious end: FD replaces the terminal-plus-tending-discipline loop with GUI
affordances for the exact things the methodology names as recurring human actions.
This is "Flight Deck runs the fleet," not "Flight Deck watches the fleet."

## UI concepts, mapped to FD's actual seams

Each of these attaches to a surface FD already has (sidebar row, `ProjectHeaderRow`,
the detail/terminal pane, or a new sibling to the terminal view) rather than
proposing a parallel app.

- **Per-project bead-state ring**, on `ProjectHeaderRow` next to the existing
  most-demanding-state rollup: ready / in-progress / blocked / done as a small
  stacked bar or ring. Answers "is this project's swarm actually converging" at a
  glance across many collapsed projects — the same problem the sidebar already
  solves for individual agent state.
- **A "Fleet" mode alongside the terminal**, not replacing it: a structured table —
  agent × current bead × state × last-active × account (for `caam`) — click a row
  to jump to that session's live PTY. This is the GUI answer to `ntm dashboard`,
  but native and reusing FD's existing session-state plumbing (`FleetService`,
  `FleetProjection`) instead of tmux panes.
- **Agent Mail as a thread inbox**, first-class rather than terminal-only:
  messages anchored to bead IDs, surfaced the way FD already surfaces unread marks
  on sessions — an unread Agent Mail thread on a project should read the same as an
  unread session, since both mean "something needs your attention."
- **Reservation-conflict badge** on a session row when its agent tries to touch a
  file another agent holds — same visual language as the existing
  working/blocked/idle shape+color system, one more state: *contested*. In
  shared-main mode this is load-bearing UI, not decoration, since it's the only
  visibility into the advisory-lock system the methodology depends on.
- **One-click crash recovery**: a stuck/idle agent sitting on an `in_progress` bead
  gets a "Reclaim & respawn" action — reclaims the bead, launches a replacement
  agent (`ntm add PROJECT --cc=1` today; a native call if FD ever bypasses `ntm`
  for spawning). Turns a described-but-manual recovery procedure into a button.
- **"Fresh eyes" action**: send a canned review prompt to a chosen agent/pane —
  the methodology names this as a specific, repeated human intervention; it's
  currently "type the same paragraph into a terminal again."
- **A literal tend-cadence nudge**: the methodology specifies a 10-15 minute human
  check-in loop. A quiet, dismissible timer/badge ("3 projects haven't been tended
  in 14 min") operationalizes a discipline the docs currently just ask you to
  remember.
- **Rate-limit / account strip**: surface `caam`'s account state and let a click
  switch it, next to whichever agent/project is rate-limited, instead of a
  separate terminal command.

## Architecture / transport strategy

Two real options, and FD's own code suggests a preferred one:

1. **Poll-and-shell**: call `br`/`am`/`bv --json` on an interval, diff into FD's
   view models. Simple, works today, no new protocol — good for Level 1/2.
2. **`ntm serve` as a second live-fleet source**: NTM exposes an HTTP API **with
   event streaming**. FD already has a `FleetReplicator`/`FleetService` pair built
   to replicate live session/fleet state to the iPhone companion over the local
   network — structurally, consuming `ntm serve`'s event stream into that same
   `FleetProjection` model is the *same architectural shape* FD already trusts,
   just with NTM as the upstream source instead of FD's own daemon. This is the
   natural path for Level 3, and worth prototyping specifically because the
   plumbing pattern already exists and is proven (the phone sync works today).

## Suggested path

1. Ship Level 1 (companion doc) — no architecture risk, immediate value.
2. Decide the worktree-vs-shared-main question **per project**, and build the
   reservation-conflict + pre-commit-guard visibility that shared-main mode
   requires — this is a prerequisite for everything in Level 3, since without it
   the human has no visibility into why a commit was blocked.
3. Prototype `ntm serve` → `FleetProjection` as a spike, reusing the phone-sync
   pattern, before committing to it as the primary transport.
4. Build the bead-graph/convergence views (Level 2) against whichever transport
   the spike validates.
5. Layer Level 3's operational actions (reclaim/respawn, fresh-eyes, tend-nudge)
   once the state is flowing live rather than polled.

## Open questions
- Does `AgentAdapter`/`AgentKind` (already generalizing beyond Claude — a `Codex/`
  subdir exists) target the same agent-type taxonomy NTM uses (`cc`/`cod`/`gmi`/
  personas/recipes), or a narrower one? Worth reconciling before Level 3 needs both.
- Is `PlanGateService`/`PlannotatorRegistry`'s current scope (gating a single
  session) close enough to Level 2's multi-draft plan-authoring to extend, or is
  it a different enough concept to warrant new types alongside it?
- `ntm serve`'s actual event schema wasn't inspected here — needed before the
  transport spike.
