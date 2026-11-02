# Tools Reference

Routing map and tool catalog for the Flight Deck index (`qartez_*` over MCP; `qartez <tool>` or
`fdindex <tool>` from Bash).

## Routing map

| Built-in tool | Replacement |
|---|---|
| `glob` / `ls` / find | `qartez_map` |
| `grep` / `rg` on code | `qartez_grep` (pattern search), `qartez_find` (exact symbol) |
| `read` / `cat` on source | `qartez_read`, `qartez_outline` |
| risk check before edit | `qartez_impact` |
| dead code, co-change, task context, type hierarchy, diff impact, hotspots | `qartez_analyze report=…` |

## Available now

Navigation and reading: `qartez_map` (ranked structure), `qartez_find` (definition by name),
`qartez_grep` (symbol names; `search_bodies=true` searches function bodies), `qartez_read` (a symbol
or a file range), `qartez_outline` (a file's symbols), `qartez_stats` (metrics).

Analysis and risk: `qartez_impact` (importers and co-change partners ranked together, the linked tests, blast radius, hot symbols; also
the acknowledgement for the edit guard), `qartez_deps` (imports and importers), `qartez_refs`
(usages), `qartez_calls` (callers and callees).

Edit (preview by default; `apply=true` writes; one view only): `qartez_replace_symbol`,
`qartez_insert_before_symbol`, `qartez_insert_after_symbol`, `qartez_rename`, `qartez_move`,
`qartez_safe_delete`, `qartez_rename_file`.

Hints: `qartez_add_root`, `qartez_workspace` (start a build early; they never change what a query
can see, because any path resolves).

Analysis: `qartez_analyze` with `report` = `unused` (exports nothing references or imports by
name; a word search of the source clears names the parser cannot see, such as Rust macro
arguments), `cochange` (partners of `file_path` or `files` by confidence), `context` (personalized
PageRank from `files` and the symbols matching `terms`), `hierarchy` (supertypes and subtypes of
`symbol`, transitively), `diff_impact` (importers and co-change partners of every file of the
uncommitted diff, interleaved, plus the tests to run), `hotspots` (commits x lines per file, with
the longest function). `report=help` lists every report's parameters; the per-report ones
(`direction`, `depth`, `min_support`, `kind`, `include_tests`) are accepted though the schema does
not list them.

Shared parameters: `format` (`detailed`, `concise`; `mermaid` for `deps` and `calls`),
`token_budget` (4000), absolute or cwd-relative paths. Aliases (accepted, not advertised):
`file_path`/`file`/`path`, `symbol`/`name`/`symbol_name`.

## Why one analysis tool

qartez exposed 43 tools; every schema an MCP server lists is paid for in every session, used or
not. fdindex keeps the 19 first-cut tools under their qartez names (hooks, skills and CLAUDE.md
name them) and puts the analysis tier behind one `report` enum, with the per-report parameters
documented on demand by `report=help`.

## Not available

`qartez_clones`, `qartez_health`, `qartez_refactor_plan`, `qartez_boundaries`, `qartez_trend`,
`qartez_blame`, `qartez_security`, `qartez_semantic`, `qartez_path`, `qartez_project`,
`qartez_wiki`, `qartez_tools` (there are no tiers to unlock). The per-analysis qartez names
(`qartez_unused`, `qartez_cochange`, `qartez_context`, `qartez_hierarchy`, `qartez_diff_impact`,
`qartez_hotspots`) are `qartez_analyze` reports. Use git, rg, and the project's own build and test
commands for the rest.

## Confidence reminders

- Prefer exact tools (`find`, `read`, `refs` by resolved reference) for critical decisions.
- A reference marked `(matched by name)` is a fallback match, not a resolved one.
- Co-change is historical correlation, not dependency.
- Swift, Python and Elixir references resolve by name within the module; treat blast radius there as
  a lower bound.
