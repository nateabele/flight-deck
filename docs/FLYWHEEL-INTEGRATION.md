# Integrating the Agentic Flywheel

*Light-touch spec based on a structural pass (README, AGENTS.md, docs/, vendor/, Sources/ layout) — not a full code read. Flagged assumptions should be verified before implementation.*

## What Flight Deck already is

A native macOS orchestration cockpit: `project → session → pane`, one real PTY per
session (Ghostty), agents currently modeled around Claude Code (`ClaudeSession.swift`,
`ClaudeFlagQuoting.swift`) with `docs/HANDOFF-agent-adapters.md` suggesting active work
toward other agent CLIs. Sessions persist across relaunch via a vendored, forked
`abduco` (`vendor/fd-abduco`) rather than tmux. Cross-session/transcript search
(⌘K), worktree support (already merged), and an iPhone companion (FleetKit/SPAKE2
pairing) round it out.

The **Agentic Flywheel** (installed natively on this Mac — see `larkOS/`) is the
opposite shape: a terminal/tmux-first cockpit (**NTM**) with the same `project →
session → pane → agent` model, plus a coordination substrate Flight Deck doesn't
have — **beads** (shared task graph), **Agent Mail** (inter-agent messaging + file
reservations), **CASS**/**CM** (session search + memory), and **DCG** (a
destructive-command guard hook).

They're structurally the same cockpit with different substrates. The integration
case: let Flight Deck be the **GUI front-end for the flywheel's coordination
tools**, without replacing FD's own PTY/session engine (`fd-abduco` stays; no
reason to run NTM's tmux underneath a native app that already solves that problem).

## Integration surfaces, cheapest first

### 1. DCG guard — zero engineering, already works
Flight Deck's PTYs run the same agent CLI binaries (`claude`, `codex`, …) as a
terminal would. Since DCG hooks are installed **per-agent-config**, not per-launcher,
any project bootstrapped with `flywheel-new`/`flywheel-guard` is already guarded
inside Flight Deck — the guard fires on the CLI, regardless of what spawned it.
**Action: none.** Just document it (a line in `docs/AGENT-OPERATIONS.md`).

### 2. Beads → sidebar task/status signal
FD's sidebar already computes a per-row "what is this agent doing" state (working /
blocked / idle) and a most-demanding-state rollup per collapsed project. Beads
(`br --json`, `br ready`, `br blocked`) is a natural second signal: a badge showing
open/ready/blocked bead counts per project, refreshed by shelling out to `br` (now a
plain native binary — no daemon needed) or watching `.beads/issues.jsonl`.

### 3. Agent Mail → cross-session file-reservation
FD already supports per-agent git worktrees (recent `worktree-detach-phase1` /
`worktree-fix-rename` work) — i.e., it already has the *problem* Agent Mail's file
reservations solve (avoiding two agents editing the same file in parallel branches).
Rather than building FD-native locking, shell out to `am file_reservations` when a
session starts editing, and surface a warning row when a reservation conflicts —
this is `ntm conflicts`/`ntm lock`'s job, reimplemented as a sidebar affordance
instead of a CLI command.

### 4. CASS/CM → richer ⌘K
FD's search already does "session and project names... transcript history... matched
terms in context." CASS does this same job today for terminal-based agent sessions,
plus cross-session context injection (`ntm spawn --context`, "automatically finds
relevant past sessions"). Two options, increasing depth: (a) call `cass search
--json` as one more source blended into ⌘K, or (b) point CASS's indexer at FD's own
transcript storage so history captured *only* through the GUI still becomes
queryable/replayable via the terminal-side tools (`cass tui`, `cass export-html`).
(b) needs to know FD's transcript-on-disk format — flag for follow-up.

### 5. Agent-CLI generalization ↔ NTM's typed-agent model
`docs/HANDOFF-agent-adapters.md` (not read in this pass) implies FD is already
moving from Claude-specific to a general agent-adapter model. NTM's `--cc/--cod/--gmi/
--persona/--recipe` vocabulary is a proven version of exactly that abstraction and
worth reading as prior art before finalizing FD's own adapter interface, purely to
avoid re-deriving the same taxonomy (agent type, persona, recipe/template, worktree
option).

### Not recommended
- **Don't route FD's session engine through NTM/tmux.** `fd-abduco` is FD's own
  answer to session persistence and is more native (real PTY, no terminal-multiplexer
  scrollback impedance mismatch) than shelling through tmux panes.
- **Don't adopt NTM's swarm/tiered-allocation logic wholesale.** That's aimed at
  headless server fleets scanning `projects_base`; FD's unit is "what the user is
  looking at," a different operating mode. Beads-driven *badges* are useful; beads-driven
  *auto-spawn* probably isn't, for a GUI a human is actively driving.

## Suggested sequencing
1. Document DCG coverage (free).
2. Beads badge in the sidebar (read-only, low risk, high signal-to-effort).
3. Agent Mail reservation surfacing alongside existing worktree UI.
4. CASS as a ⌘K source.
5. Revisit agent-adapter design against NTM's vocabulary once `HANDOFF-agent-adapters.md`'s
   plan is settled.

## Open questions
- Where do FD's transcripts live on disk, and could CASS index them without a
  format-specific adapter?
- Is `am`/`cass`/`br` invoked per-call (simple, some latency) or should FD keep a
  long-lived helper process (each tool is a fast native binary, so per-call is
  probably fine — worth a quick benchmark before assuming otherwise).
- Multi-machine: FD's iPhone companion pairs directly with the Mac; the flywheel's
  coordination stores (beads DB, agent-mail mailbox) are local-machine-only today —
  no conflict, but worth naming so nobody assumes cross-device bead sync exists.
