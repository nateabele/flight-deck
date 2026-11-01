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

Shared parameters: `format` (`detailed`, `concise`; `mermaid` for `deps` and `calls`),
`token_budget` (4000), absolute or cwd-relative paths. Aliases: `file_path`/`file`/`path`,
`symbol`/`name`/`symbol_name`.

## Not available yet (analysis tier)

`qartez_context`, `qartez_unused`, `qartez_diff_impact`, `qartez_hotspots`, `qartez_clones`,
`qartez_health`, `qartez_refactor_plan`, `qartez_boundaries`, `qartez_hierarchy`, `qartez_trend`,
`qartez_blame`, `qartez_security`, `qartez_semantic`, `qartez_path`, `qartez_cochange` (its content
is the co-change section of `qartez_impact`), `qartez_project`, `qartez_wiki`, `qartez_tools` (there
are no tiers to unlock). Use git, rg, and the project's own build and test commands.

## Confidence reminders

- Prefer exact tools (`find`, `read`, `refs` by resolved reference) for critical decisions.
- A reference marked `(matched by name)` is a fallback match, not a resolved one.
- Co-change is historical correlation, not dependency.
- Swift, Python and Elixir references resolve by name within the module; treat blast radius there as
  a lower bound.
