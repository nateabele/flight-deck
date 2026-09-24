# Observe command shapes — `am`/`br` read-lane probe (2026-09-24)

Spike findings for Flywheel Level 1 "Observe" Task 1. This is the source of truth Task
2's decoders are written against — a lane marked **unavailable** here ships as a
nil-stub, never a guess.

`am` 0.3.35, `br` 0.6.0 (`which am br` → `/Users/me/.local/bin/{am,br}`).

## REPO used for probing

The environment facts pointed at `notetaker` and `crate-runner`. Neither turned out
usable for a representative row, so `REPO = /Users/me/fw-functest` was substituted —
recorded here so Task 2 knows why the fixtures don't match the originally-suggested
repos:

- **`/Users/me/Projects/notetaker`** — a real, empty beads workspace
  (`br list --json` → `{"issues":[],...}`, confirmed zero issues ever created) with no
  Agent-Mail project registration. Good for confirming empty-envelope shape and argv,
  useless for a representative row.
- **`/Users/me/Projects/crate-runner`** (and, discovered via
  `find … -name .beads`, also `signup-app` and `project-meridian`) — **dolt-backed**
  beads databases. Every `br` read fails the same way:
  ```
  {"error":{"code":"CONFIG_ERROR","message":"Configuration error: Refusing unsafe
  configured database leaf <database-authority sha256=…>: expected a regular file,
  not a symlink or special file", ...}}
  ```
  This is a pre-existing environment defect (br refusing `.beads/dolt`'s on-disk shape
  as an "unsafe leaf"), not something this spike fixes — read-only mandate, and it hit
  3-for-3 dolt-backed repos, so it looks systemic rather than repo-specific. **All beads
  work for Observe should assume it targets a SQLite-family `.beads/beads.db`, not a
  dolt-backed workspace**, until that's separately resolved.
- **`/Users/me/fw-functest`** — found via `am list-projects --json` /
  `am doctor locks --json` (registered project id 11, human_key
  `/Users/me/fw-functest`). SQLite-backed `.beads/beads.db` (not dolt), a real
  `.agent-mail.yaml`, and **2 real registered Agent-Mail agents** (`LavenderDesert`,
  `BlueGull`). It's a leftover flywheel spike fixture (also referenced in
  `a1b80c2 docs(flywheel): record the pre-66fa004 pre-commit corruption gap`) — genuinely
  0 beads issues (`br stats --json` → `total_issues:0`), so bead-lane *rows* are still
  schema-confirmed rather than live-row-confirmed, but the agent-registration and
  reservation/inbox-events plumbing run against real, live data paths. Used as `REPO`
  for every command below that takes a project/db argument.

Where a lane's live data was empty, its item shape is confirmed instead via `br schema`
— the CLI's own machine-readable JSON Schema command (`br schema <target> --format
json` / `br schema commands --format json`), which is authoritative, not a guess. Both
dumps are saved as fixtures (`br-schema-all.json`, `br-schema-commands.json`).

## Beads lanes (`br`)

All run with `br --db /Users/me/fw-functest/.beads/beads.db …`. Fixtures saved to
`Tests/FlightDeckTests/Flywheel/Observe/Fixtures/`.

| Command | argv | Exit | Shape | Fixture |
|---|---|---|---|---|
| in-progress list | `br --db <db> list --status in_progress --json` | 0 | **CONFIRMED** — `{issues:[…], total, limit, offset, has_more}`, item = `IssueWithCounts` (`br schema issue-with-counts`) | `br-list-in-progress.json` |
| ready | `br --db <db> ready --json` | 0 | **CONFIRMED** — bare array `[…]` (**not** wrapped — different from `list`/`blocked`), item = `ReadyIssue` | `br-ready.json` |
| blocked | `br --db <db> blocked --json` | 0 | **CONFIRMED** — `{issues:[…], total, limit, offset, has_more}` (`BlockedPage`), item = `BlockedIssue` | `br-blocked.json` |
| graph (whole project) | `br --db <db> graph --all --json` | 0 | **CONFIRMED** — `{components:[…], total_nodes, total_components}` | `br-graph-all.json` |
| dep cycles | `br --db <db> dep cycles --json` | 0 | **CONFIRMED** — `{cycles:[…], count, active_count, archived_closed_count, total_count, blocking_only, include_closed, scope}` | `br-dep-cycles.json` |
| dep list (per-issue edges) | `br --db <db> dep list <issue> --json` | 3 on missing ID | **argv + error path CONFIRMED only.** `br dep --json` (bare, as the brief listed) **does not exist** — `dep` requires a subcommand. No positive-path row: no accessible repo has an issue ID to call it on, and `br schema commands` lists `"dep list"` as `shape:"array"` with **no `item_schema`** — the per-edge object fields are genuinely undocumented by the tool. Error envelope confirmed: `{"error":{"code":"ISSUE_NOT_FOUND","message":…,"hint":…,"retryable":false,"context":{"searched_id":…}}}`. **Mark UNAVAILABLE for the positive path; Task 2 ships this as a nil-stub decoder until a real edge can be captured.** | `br-dep-list-error.json` |
| dep tree | `br --db <db> dep tree <issue> --json` | not run (needs a real issue) | argv confirmed via `--help`; item schema **is** exposed — `TreeNode` (`id, title, depth, parent_id, priority, status, truncated`) — via `br schema tree-node`, so decode against that even though no live row was captured. | — |
| graph (single issue) | `br --db <db> graph <issue> --json` | not run (needs a real issue) | argv confirmed via `--help` (mirrors `--all`'s `{components...}` shape per the command); not exercised live. | — |

`br schema commands --format json` is the authoritative per-command envelope map (shape
+ `jq_filter` + `item_schema` for every `br` JSON command) — saved verbatim as
`br-schema-commands.json`. `br schema all --format json` is the full schema bundle
(`Issue`, `IssueWithCounts`, `ReadyIssue`, `BlockedIssue`, `BlockedPage`, `TreeNode`,
`Statistics`, `ErrorEnvelope`, …) — saved as `br-schema-all.json`. Both are supporting
fixtures, not per se "Observe reads," but they are what let every empty-live-data lane
above be schema-confirmed instead of guessed.

**Minimal fields Observe needs**, from the confirmed schemas:
- `ReadyIssue`/`IssueWithCounts`/`BlockedIssue` all share `id, title, status, priority,
  issue_type, assignee` (assignee only on `IssueWithCounts`) — that's the "Working on"
  lane.
- `BlockedIssue.blocked_by: [String]` (+ `blocked_by_count`) is the immediate-dependency
  signal for the drawer's Dependency lane without needing `dep list`.
- `TreeNode { id, title, depth, parent_id, status, priority }` is what the DAG overlay
  needs per node once `dep tree`/`graph` is exercised against real data.

## Agent-Mail lanes (`am`)

The Agent-Mail store is **global**, not per-repo (confirmed — see below), so every `am`
read below is scoped with `--project /Users/me/fw-functest` (or the positional repo
arg) to avoid reading another project's rows, matching the spec's "always the
standardized absolute project path" rule.

| Command | argv | Exit | Shape | Fixture |
|---|---|---|---|---|
| agents list | `am agents list <repo> --json` | 0 | **PROVEN, re-confirmed with 2 real rows** — bare array `[{id, name, program, model, task_description, inception_ts, last_active_ts, project_id, attachments_policy, contact_policy, retired_at}]` | `am-agents-list.json` |
| reservations (winner) | `am reservations --project <repo> --all --json` | 0 | **CONFIRMED** — object `{_meta:{command,timestamp,format,version,project}, _alerts:[…], all_active:[…], reservation_read_attestation:{state, source, database_matches_server, storage_root_matches_server, detail, action}}`. `all_active` is the reservation-row array (empty here — no active holds). `reservation_read_attestation.state` was `"unattested"` in this run because no `am` HTTP daemon was reachable — see note below. | `am-reservations-all.json` |
| inbox events (no daemon) | `am inbox-events --agent <name> --project <repo> --after 0 --json` | **1** | Fails hard with no local fallback: `{"status":"error","code":"inbox_events_unavailable","message":"transport failure calling http://127.0.0.1:8765/api/: Connection refused …","details":{}}`. **This is the "never touch the am HTTP daemon cold path" landmine the spec already calls out** — confirmed live, not theoretical. | `am-inbox-events-no-direct.json` |
| inbox events (direct) | `am inbox-events --agent <name> --project <repo> --after 0 --direct --json` | 0 | **CONFIRMED, this is the form Observe must use** — `{events:[…], next_cursor, has_more, oldest_available_cursor, tail_cursor}`. `--direct` is documented as "Allow a direct SQLite read only when no daemon is reachable" — always pass it; Observe should never assume a live `am` server process. | `am-inbox-events.json` |
| doctor locks (supporting) | `am doctor locks --json` | 0 | Not one of the brief's probe targets, but this is what located the store (below) and is genuinely read-only ("does not acquire mailbox locks" per its own `--help`). Shape: `{schema_version, inspected_at, storage_root, database_path, memory_database, disposition, owner_state, storage_root_lock:{…holder_pids, waiter_pids…}, sqlite_lock:{…}, sidecars:[{name,path,exists,open_by_pids}], processes, waiters, recommended_next_action, read_only:true}`. | `am-doctor-locks.json` |

### Reservations lane — decision

Three candidates existed; only one produces JSON:

1. **`am reservations --project <repo> --all --json`** (alias for `am robot
   reservations`) — **winner**. Real `--json`/`--format json` flags, works without a
   live daemon (falls back to a local, "unattested" read — see caveat below), reports
   `all_active` (who holds what) plus an explicit freshness attestation.
2. `am file_reservations list <PROJECT>` / `am file_reservations active <PROJECT>` —
   exist, take a **positional** project arg, but have **no `--json`/`--format` flag at
   all** (`error: unexpected argument '--json' found`). Text-only. **Unavailable** for a
   parser.
3. `am guard status <REPO>` — exists, no JSON output either, and reports **git-hook
   installation status** ("Hooks dir / Mode / Pre-commit / Pre-push"), not who holds
   which file. Wrong data for this lane even if it had `--json`. **Not applicable.**

**Caveat to carry into Task 2/3:** `am reservations --all --json` warns when no live
`am` HTTP server (`127.0.0.1:8765`) is reachable — `reservation_read_attestation.state
== "unattested"`, with `_alerts[0].summary` explaining the local read "cannot attest
freshness." The spec already has language for exactly this ("stale" hint rather than
freezing/erroring) — wire `reservation_read_attestation.state != "attested"` into that
same degraded-but-rendered path rather than treating it as a hard failure. Since this
ran with no `am` server active at all, an **attested** shape was never observed live;
its fields (`database_matches_server`, `storage_root_matches_server`) are visible in the
schema above but their populated values are unconfirmed.

### Where the Agent-Mail store actually lives

Located via `am doctor locks --json` (`storage_root_lock.path` /
`sqlite_lock.path` / `sidecars`):

- **Storage root:** `/Users/me/.local/share/mcp-agent-mail/git_mailbox_repo`
- **Database:** `/Users/me/.local/share/mcp-agent-mail/git_mailbox_repo/storage.sqlite3`
  (+ `-wal`, `-shm` sidecars)
- **Confirmed GLOBAL, not per-repo**: no `<repo>/.agent-mail/` directory exists anywhere
  probed (only an empty per-repo `.agent-mail.yaml` *config* file in `fw-functest`,
  which configures the client, not a data store). This matches the environment facts'
  hypothesis exactly. `am list-projects --json` is the registry of which repo paths have
  ever been registered against this one global store (11 rows at probe time, all
  leftover flywheel spike fixtures under `/private/tmp`, `/private/var/folders`, or
  `/Users/me/fw-*` — `crate-runner`/`notetaker`/`signup-app`/`project-meridian` are
  **not** among them, i.e. those repos have literally never talked to Agent-Mail).

## Watch targets (mtime-gate)

Per the plan's Architecture note, transport is `WatchClock`-registered + mtime-gated,
**not** FSEvents (no FSEvents anywhere in this codebase; documented anti-vnode stance in
`SessionStatusWatcher.swift:13-16`; beads is SQLite/dolt+git and Agent-Mail is SQLite —
exactly the unreliable-vnode case that stance already rejects). Nothing found here gives
a reason to revisit that default; it's confirmed correct as-is:

- **`.beads` watch target:** `<repo>/.beads/beads.db` (+ `.beads/beads.db-wal`) for a
  SQLite-family workspace (confirmed against `fw-functest`). **A dolt-backed workspace
  has no single-file equivalent** — its `.beads/dolt` is a directory — and `br` can't
  currently read those repos at all (see the dolt `CONFIG_ERROR` above), so this is
  moot for now; Observe should treat a dolt-backed `.beads` as out of scope rather than
  guess a watch path for it.
- **Agent-Mail watch target:** the global
  `/Users/me/.local/share/mcp-agent-mail/git_mailbox_repo/storage.sqlite3` (+ `-wal`).
  **This is shared across every project on the machine** — an mtime bump there means
  "something changed somewhere in Agent-Mail," not necessarily in the watched project.
  There is no cheaper per-project granularity available from the filesystem side, so the
  watcher's repoll after an Agent-Mail mtime bump must still scope its `am` reads with
  `--project <repo>` (already required anyway) rather than assume the change belongs to
  this project — it'll just sometimes repoll for nothing, which is the same cost model
  the plan already accepts for a no-op tick.
- **Read safety, confirmed by direct experiment:** running `br list`/`br ready` against
  `fw-functest`'s `beads.db` did **not** change `beads.db`'s or `beads.db-wal`'s mtime
  (`stat -f "%Fm"` before/after were byte-identical). Reads are safe to poll without the
  watcher self-triggering on its own probe.

## Transport decision

**Confirmed: `WatchClock`-mtime-gated, not FSEvents** — matches the plan's stated
default, and everything probed here (SQLite-family beads db, global SQLite Agent-Mail
store, both with WAL sidecars) is exactly the class of target the plan's rationale
already warns FSEvents/vnode is unreliable for. No finding here argues for revisiting
it.

## Summary for Task 2

| Lane | Status |
|---|---|
| `am agents list` | available, proven |
| `br list --status in_progress` | available, confirmed |
| `br ready` | available, confirmed (bare array, not wrapped) |
| `br blocked` | available, confirmed |
| `br graph --all` | available, confirmed |
| `br dep cycles` | available, confirmed |
| `br dep list <issue>` (edges) | **unavailable for the positive path** — argv + error envelope confirmed, no item schema exposed by the tool and no live row obtainable; ship as a nil-stub until real data exists |
| `br dep tree <issue>` | schema-confirmed (`TreeNode`), not live-row-exercised |
| `br graph <issue>` (single-issue) | argv-confirmed via `--help` only, not live-row-exercised |
| `am reservations --all` | available, confirmed — the reservation-lane winner |
| `am file_reservations list/active` | **unavailable** — no JSON output at all |
| `am guard status` | **unavailable/inapplicable** — no JSON, wrong data (hook install status, not holders) |
| `am inbox-events` (no `--direct`) | fails hard without a live daemon — **must always pass `--direct`** |
| `am inbox-events --direct` | available, confirmed |
