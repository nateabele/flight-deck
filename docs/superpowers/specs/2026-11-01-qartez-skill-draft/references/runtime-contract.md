# Runtime Contract

States, result shapes and environment variables of the Flight Deck index as agents see it.

## There is no status file

The qartez-era `.qartez/status.json` is gone. The daemon serves every repository and worktree on
the machine, so a per-project file would be written into each worktree and would go stale. The state
is carried by the results, and `fdindex status` describes the daemon.

## States

| State | Where you see it | Meaning |
|---|---|---|
| ready | a result whose `view:` line has no `index:` suffix | the view's index is complete |
| building | `index: building, N of M files` on the `view:` line, or `state: BUILDING` on a refusal | the view is being indexed; answers come from what is stored |
| `UNAVAILABLE` | `state: UNAVAILABLE` (MCP `isError`, CLI stderr and exit 3) | the daemon cannot be reached or started; fall back to rg |
| `BAD_REQUEST` | `state: BAD_REQUEST` | bad argument or unknown tool |
| `VERSION_MISMATCH` | `state: VERSION_MISMATCH` | client and daemon speak different protocols; `fdindex stop` and retry |
| `ERROR` | `state: ERROR` | understood and failed |

`STALE`, `INDEXING`, `CAPABILITY_MISMATCH` and `RISK_ACK_REQUIRED` as states no longer exist. A view
is read-your-writes fresh on every request. A load-bearing edit is blocked by the hook, not by a
state (see `guard.md`).

## The view header

`view: /abs/worktree (repo NAME, base 1a2b3c4, clean | dirty N files)` is the first line of every
result. `linked view: ...` and `dependent view: ...` lines follow when the answer draws on other
views. Rows from other views carry `[view: repo @ /abs/worktree]`.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `QARTEZ_GUARD_DISABLE` | unset | `1`/`true` turns the guard off (`0`, `false` and empty do not) |
| `QARTEZ_GUARD_PAGERANK_MIN` | `0.05` | load-bearing PageRank threshold |
| `QARTEZ_GUARD_BLAST_MIN` | `10` | load-bearing blast-radius threshold |
| `QARTEZ_GUARD_ACK_TTL_SECS` | `600` | how long an acknowledgement lets an edit through (`QARTEZ_ACK_TTL_SECS` also works) |
| `FLIGHTDECK_INDEX_DIR` | the platform default | the daemon's store directory |
| `FLIGHTDECK_INDEX_SOCKET` | `<store>/fdindex.sock` | the daemon's socket |
| `FLIGHTDECK_INDEX_NO_START` | unset | the MCP shim does not start a daemon; calls answer `UNAVAILABLE` |

`QARTEZ_INDEX_PATH` and `QARTEZ_STATUS_PATH` are no longer read: there is no per-project index
directory and no status file.
