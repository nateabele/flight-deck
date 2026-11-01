---
name: qartez
description: >-
  Code intelligence through the Flight Deck index (the `qartez_*` MCP tools and the `qartez` /
  `fdindex` CLI). Use it for code exploration, impact analysis and view-scoped refactors; treat
  built-in Glob/Grep denials as routing signals; fall back to rg when a result says
  `state: UNAVAILABLE`.
---

# Qartez - code intelligence over Flight Deck's index

One daemon per machine owns the index of every repository and worktree on it. The MCP server
(`fdindex mcp`, still named `qartez`, so tools stay `mcp__qartez__qartez_*`) and the CLI
(`qartez <tool>` or `fdindex <tool>` from Bash) are thin clients of it. Nothing is configured per
project: the first query that names a repository starts its index.

---

## 1. When the index is authoritative

Use it for all code exploration and analysis. Use built-in tools for non-code content, for reading a
file range you are about to `Edit`, and when a result says `state: UNAVAILABLE`.

| Built-in intent | Index replacement |
|---|---|
| `glob` / `ls` / find | `qartez_map` |
| `grep` / `rg` on code | `qartez_grep` or `qartez_find` |
| `read` / `cat` on source (exploration) | `qartez_read` |
| outline / API surface | `qartez_outline` |
| imports and importers | `qartez_deps` |
| who uses a symbol | `qartez_refs`, `qartez_calls` |
| risk before editing | `qartez_impact` |

Infra-as-code is code only to the extent the languages are supported (Elm, Rust, TypeScript and
JavaScript, Elixir, Swift, Python). For YAML, HCL, Dockerfiles and other manifests use `rg` and
`Read`.

`qartez_read` is for **exploration**. Before a non-symbol `Edit` (imports, partial lines, config,
multi-block edits) do a built-in `Read` of the exact range: the harness records that, and
`qartez_read` does not.

---

## 2. Tools that exist

Read: `qartez_map`, `qartez_find`, `qartez_grep`, `qartez_read`, `qartez_outline`, `qartez_deps`,
`qartez_stats`, `qartez_impact`, `qartez_refs`, `qartez_calls`.

Edit (preview unless `apply=true`): `qartez_replace_symbol`, `qartez_insert_before_symbol`,
`qartez_insert_after_symbol`, `qartez_rename`, `qartez_move`, `qartez_safe_delete`,
`qartez_rename_file`.

Hints (accepted, they only start a build early): `qartez_add_root`, `qartez_workspace`.

**Not available yet** (the analysis tier): `qartez_context`, `qartez_unused`, `qartez_diff_impact`,
`qartez_hotspots`, `qartez_clones`, `qartez_health`, `qartez_refactor_plan`, `qartez_boundaries`,
`qartez_hierarchy`, `qartez_trend`, `qartez_blame`, `qartez_security`, `qartez_semantic`,
`qartez_path`, `qartez_project`, `qartez_wiki`, `qartez_tools`. Calling one is an error. Use `git`,
`rg` and the project's own build and test commands instead. `qartez_impact` already includes the
co-change partners (from git history) that `qartez_cochange` used to give.

---

## 3. Paths, views and worktrees

- **Absolute paths work, and so do paths relative to your working directory.** Every path in a
  result is absolute. Name a file in another repository (`../tessera/...`) and it is answered from
  that repository's index.
- **Worktrees are first-class.** A new worktree is searchable at once; nobody registers it. A
  query from a worktree sees that worktree, including edits you just made (read-your-writes).
- **Every result starts with a `view:` line**:
  `view: /abs/worktree (repo name, base 1a2b3c4, clean | dirty N files)`. Check it when you work
  in a worktree: it says which checkout answered. A row from another view is tagged
  `[view: repo @ /abs/worktree]`; linked repositories (an `elm.json` that lists `../tessera/...`)
  appear as `linked view:` lines.
- **Mutators write into the view that holds the file you named** (else the view of your cwd), and
  nowhere else. If that is not your worktree the answer says `note: this is not your worktree`.
  A rename, move or delete that would break another view is refused with the sites in both views.
- The old rules (start in the project root, register roots with `add_root`, avoid mutators in
  worktrees) no longer apply.

---

## 4. States

There is no `.qartez/status.json`. The state is in the result:

| You see | Meaning | Do |
|---|---|---|
| a normal result | the view's index is complete | work normally |
| `index: building, N of M files` on the `view:` line | the view is being indexed; the answer is from what is stored | use `qartez_map`/`outline`, ask again shortly; a missing file may just not be parsed yet |
| `state: BUILDING` (error) | the thing you asked about is not indexed yet | retry shortly |
| `state: UNAVAILABLE` | the daemon cannot be reached or started | **fall back to `rg` and `Read`**, tell the user once; `fdindex status` says why |
| `state: BAD_REQUEST` | a bad argument or an unknown tool | fix the call |
| `state: VERSION_MISMATCH` | an old client and a new daemon | `fdindex stop`, then retry |
| `state: ERROR` | the request was understood and failed (path not indexed, git error) | read the message |

`fdindex status` (or `flightdeck index status`) shows the daemon, its views and builds.

---

## 5. Denied-tool recovery

The hook (`fdindex guard`) denies `Glob` and `Grep` in a project whose index is ready, and an
`Edit`/`Write`/`MultiEdit` of a load-bearing file. A denial is a **routing signal**, not completion.
The hook output is a `permissionDecisionReason` in plain text:

- `STOP: qartez MCP is available. Use qartez_map ... / qartez_grep ...`: use the named tool; for
  non-code text search use `rg` through Bash.
- ``STOP: `src/x.rs` is load-bearing (PageRank 0.12 >= 0.05, blast radius 34 >= 10). Call qartez_impact ...``:
  call `qartez_impact` with that `file_path`, read the blast radius, retry the edit. The
  acknowledgement lasts 10 minutes, belongs to that file in that worktree, and is written by
  `qartez_impact` itself.

If the index is not available the hook **allows** the call and prints a note on stderr; that is the
signal to use rg, not an error to work around.

---

## 6. Operating modes

**Explore (read-only):** `qartez_map`, `qartez_find`, `qartez_grep`, `qartez_read`,
`qartez_outline`, `qartez_refs`, `qartez_calls`, `qartez_deps`, `qartez_stats`.

**Change (edit-authorised):** `qartez_impact` first, then a mutator.

Prefer the mutators for structural changes (replace a symbol, add a sibling, rename, move, delete):
they need no prior `Read`, are not subject to the load-bearing gate, and re-index what they write
before answering. They **preview by default**: read the diff, then repeat the call with
`apply=true`. Use built-in `Edit` for import blocks, partial lines, config values and multi-block
changes inside one symbol, after a `Read` of the range.

---

## 7. Workflows

- Explore: `qartez_map -> qartez_find -> qartez_outline -> qartez_read -> qartez_refs/calls -> qartez_deps`
- Debug: `qartez_find -> qartez_calls -> qartez_refs -> qartez_read -> qartez_deps`
- Review before edit: `qartez_outline -> qartez_impact -> qartez_deps`
- Refactor: `qartez_find -> qartez_refs -> qartez_impact -> qartez_rename/move (preview, then apply) -> re-run qartez_refs`
- Pre-merge: `git diff --stat`, then `qartez_impact` on each changed load-bearing file

---

## 8. CLI from Bash

`qartez find update --kind function`, `qartez --root /abs/worktree map`, `fdindex impact src/a.rs`
and `flightdeck index ...` are the same thing as the MCP tools; use them where MCP is disabled
(Codex intakes). `--json` prints the raw reply. Exit status 3 plus `state: UNAVAILABLE` on stderr
means the daemon could not be reached.

---

## 9. Subagent / delegated sessions

1. Start with the index tools directly.
2. Treat a denial as a routing signal and recover with the named tool.
3. If the tools are visible but every call says `state: UNAVAILABLE`, report `UNAVAILABLE` and
   continue with rg.
4. End with the footer below.

```md
<!-- QARTEZ_EXECUTION_REPORT
State: <READY|BUILDING|UNAVAILABLE>
Tools_used: <comma-separated list>
Builtin_denials: <count by type or none>
Recovery_actions: <what was retried or none>
Change_mode_used: <yes|no>
Risk_ack_issued: <yes, file list|no>
Residual_uncertainty: <text or none>
Missing_capability: <text or none>
-->
```

---

## 10. References

- `references/runtime-contract.md`
- `references/subagent-contract.md`
- `references/host-matrix.md`
- `references/confidence-model.md`
- `references/doctrine-explore.md`, `doctrine-debug.md`, `doctrine-review.md`, `doctrine-refactor.md`, `doctrine-premerge.md` (these name analysis-tier tools that are not available yet; see Section 2)
- `references/tools.md`
- `references/guard.md`
