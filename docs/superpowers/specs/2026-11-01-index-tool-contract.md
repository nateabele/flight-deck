# fdindex tool contract (first cut)

The black-box compatibility contract with qartez v0.11.0. It comes from the public MCP tool schemas and from output observed on the flight-deck repo. No qartez source was read.

Every MCP tool is named `qartez_<verb>`, so existing skills, hooks and habits keep working. The CLI verb is `fdindex <verb>` (also `flightdeck index <verb>`, and `qartez <verb>` through the alias).

## Changes from qartez (required by the spec)
- **Paths.** Every path parameter accepts an absolute path or a path relative to the caller's cwd, which the shim sends. A relative path is never read against "the project root".
- **Output paths.** Every path in the output is absolute.
- **View header.** Every result starts with one line, e.g.:
  `view: /Users/me/Projects/Tessera/tessera (repo tessera, base 1a2b3c4, dirty 3 files)`.
  If a result spans several views, each row is labelled.
- **Build state.** While the view is still building, the header adds `index: building, N of M files`.
- **add_root and workspace.** `qartez_add_root` and `qartez_workspace add` are accepted as hints that start a build early. They never change scope. `workspace remove` is accepted and does nothing.
- **Daemon down.** Every tool returns `state: UNAVAILABLE` plus a one-line reason. It never answers from a private index.

## Shared params
- `format`: `detailed` (the default), `concise` or `mermaid`. Only `deps` and `calls` honour `mermaid`. Every other tool rejects it with a clear error.
- `token_budget`: about 4000 tokens by default. Truncate and add a footer naming the param to raise.
- Aliases are accepted everywhere: `file_path` = `file` = `path`; `symbol` = `name` = `symbol_name`; grep's `query` = `pattern`.

## Read-only tools
| tool | required | optional | output |
|---|---|---|---|
| map | — | top_n (20; 0 = all), all_files, boost_files[], boost_terms[], by (files\|symbols), format, token_budget, with_health | Table: `# \| File \| PageRank \| Exports \| Blast`. In detailed mode, each top file follows with its exported signatures. |
| find | name | kind, regex (case-insensitive, unanchored), limit (100, regex mode only), format | `Found N match(es) for 'X':`. Each match is a block: `X (kind)` / `File: <path> [Lstart-Lend]` / `Signature: …` / `Status: exported\|private`. |
| grep | query | kind, regex, limit (200), search_bodies, format, token_budget | Prefix match on symbol names (`Foo*`), so a file path never matches. Rows give name, kind, file, lines and export status. `search_bodies` searches the text of function bodies. |
| read | — | symbol_name \| symbols[], file_path, start_line/offset, end_line, limit, context_lines, max_bytes (25000) | The symbol's source with line numbers. With only `file_path`, the whole file or a slice. |
| outline | file_path | offset, format, token_budget | `# Outline: <path> (N symbols)`. Grouped by kind (Classes:, Methods:, Functions:, …), each row `- name [Ls-Le] — signature`. Paged with `next_offset: K (of N)`. |
| deps | file_path | format (incl. mermaid), token_budget | `# Dependencies: <path>`, then `Imports from (n):` and `Imported by (n):` lists. |
| stats | — | file_path | Files, LOC, symbols and edges by language, plus the most-imported files. With `file_path`: that file's LOC, symbol count, imports and importers. |
| impact | file_path | include_tests, format, token_budget | Direct importers, the transitive blast radius count and list, co-change partners (from git history, per repository), and hot symbols. |
| refs | symbol | transitive, include_tests (true), format, token_budget | The importing files and their reference sites, grouped by importer. `transitive=true` adds the dependent chain. |
| calls | name | direction (callers\|callees\|both; default both), depth (1, max 10, 0 = target only), file_path, kind, include_tests (false), limit (50), format (incl. mermaid), token_budget | If the name matches more than one function-like definition and no `file_path` or `kind` is given, refuse and list the candidates. |

## Mutators (preview by default; `apply=true` writes)
| tool | required | optional |
|---|---|---|
| replace_symbol | symbol, new_code (must begin with a definition introducer) | file_path, kind, apply |
| insert_before_symbol / insert_after_symbol | symbol, new_code (a trailing newline is added if missing) | file_path, kind, apply |
| rename | old_name, new_name | file_path, kind, allow_collision, apply |
| move | symbol, to_file (created if missing; importers are rewritten) | file_path, kind, apply |
| safe_delete | symbol | file_path, kind, force, apply |
| rename_file | from, to (also rewrites the Rust `mod` declaration; refuses `mod.rs`) | apply |

Rules for every mutator:
- If the name matches more than one definition, refuse and list the candidates with their files and kinds.
- Write only inside the view that answered the lookup (spec §5.5).
- Re-index the written files before returning.

## Observed qartez weaknesses not to copy
- It indexes submodules such as `vendor/boringssl` and `vendor/ghostty`, so they dominate the map and the stats. In the new engine a submodule is a separate repository.
- Swift files show 0 import edges, so deps, impact and blast all report 0 for Swift. The new engine should resolve Swift references by name within the module, so that deps and impact mean something.
- `find` reports every Swift `extension X` as a separate `class` named X. Keep extensions, but give them their own kind, `extension`.
