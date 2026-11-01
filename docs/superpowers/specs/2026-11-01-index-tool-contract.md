# fdindex tool contract (first cut)

The black-box compatibility contract with qartez v0.11.0. It comes from the public MCP tool schemas and from output observed on the flight-deck repo. No qartez source was read.

Every MCP tool is named `qartez_<verb>`, so existing skills, hooks and habits keep working. The CLI verb is `fdindex <verb>` (also `flightdeck index <verb>`, and `qartez <verb>` through the alias).

## Changes from qartez (required by the spec)
- **Paths.** Every path parameter accepts an absolute path or a path relative to the caller's cwd, which the shim sends. A relative path is never read against "the project root".
- **Output paths.** Every path in the output is absolute.
- **View header.** Every result starts with one line, e.g.:
  `view: /Users/me/Projects/Tessera/tessera (repo tessera, base 1a2b3c4, dirty 3 files)`.
  The parts: the absolute worktree; the repository's name; the first 7 characters of the base commit (`no commits` before the first commit, `not git` for a directory outside git); `clean`, or `dirty N files` where N counts the files that differ from the base.
  If a result spans several views, each row is labelled (not yet: links are step 7).
- **Build state.** While the view is still building, the header adds ` index: building, N of M files` after the closing parenthesis. N and M count files of the view whose facts are stored.
- **add_root and workspace.** `qartez_add_root` and `qartez_workspace add` are accepted as hints that start a build early. They never change scope. `workspace remove` is accepted and does nothing.
- **Daemon down.** Every tool returns `state: UNAVAILABLE` plus a one-line reason. It never answers from a private index. (The CLI prints `state: UNAVAILABLE` and the reason to stderr and exits 3.)

## Shared params
- `format`: `detailed` (the default), `concise` or `mermaid`. Only `deps` and `calls` honour `mermaid`. Every other tool rejects it with a clear error.
- `token_budget`: 4000 tokens by default, counted as 4 characters a token. The output is cut at a line and ends `… truncated: N of M lines shown (token_budget=4000); raise token_budget to see more`. The view header is not counted. `find` and `read` have their own bounds (`limit`, `max_bytes`) instead.
- Aliases are accepted everywhere: `file_path` = `file` = `path`; `symbol` = `name` = `symbol_name`; grep's `query` = `pattern`.

## Read-only tools
| tool | required | optional | output |
|---|---|---|---|
| map | — | top_n (20; 0 = all), all_files, boost_files[], boost_terms[], by (files\|symbols), format, token_budget, with_health | Table: `# \| File \| PageRank \| Exports \| Blast`. In detailed mode, each top file follows with its exported signatures. |
| find | name | kind, regex (case-insensitive, unanchored), limit (100, regex mode only), format | `Found N match(es) for 'X':`. Each match is a block: `X (kind)` / `File: <path> [Lstart-Lend]` / `Signature: …` / `Status: exported\|private`. |
| grep | query | kind, regex, limit (200), search_bodies, format, token_budget | Prefix match on symbol names (`Foo*`), so a file path never matches. Rows give name, kind, file, lines and export status. `search_bodies` searches the text of function bodies. |
| read | — | symbol_name \| symbols[], file_path, start_line/offset, end_line, limit, context_lines, max_bytes (25000) | The symbol's source with line numbers. With only `file_path`, the whole file or a slice. |
| outline | file_path | offset, format, token_budget | `# Outline: <path> (N symbols)`. Grouped under `Modules:`, `Types:`, `Impls:`, `Constructors:`, `Functions:`, `Methods:`, `Ports:`, `Macros:`, `Consts:`, `Fields:`. Each row is `+ name [L10-L20] — signature` (`+` exported, `-` private), indented under its parent, signature cut at 160 characters. 100 symbols a page, then `next_offset: K (of N)`. |
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

## As built: arguments and output the table above leaves open

- **find.** `limit` (default 100) applies to the exact search as well as the regex search, because an exact `view` in an Elm repository matches a thousand modules. A cut ends `… N more match(es); pass limit=… to see all`. A match block adds `Module:` (Elm) and `In:` (the enclosing type) lines when they apply. A qualified name (`Expression.Node.toString`, `store::open`) matches by module, enclosing type or file stem.
- **grep.** `query` is a case-insensitive prefix match on symbol names (`Foo` and `Foo*` are the same); `regex=true` makes it an unanchored case-insensitive regex. Rows: `name  kind  path [Ls-Le]  exported|private`. `search_bodies=true` reads the files of the view from disk and reports lines inside function-like bodies: `path:Lline in function (kind): text`.
- **read.** `symbol_name` / `symbols[]` (with an optional `file_path`) print each definition as `// name kind @ path:Ls-Le` followed by `N | source` lines; `context_lines` adds lines around it; an ambiguous name prints a warning and up to 5 definitions. With only `file_path` the file is read from disk (no index needed, so it works on any file under any path and never waits for a build): `start_line` (alias `offset`, `start`), `end_line` (alias `end`), `limit`, header `// path [L2-L9 of 120]`. Output is cut at `max_bytes` (25000).
- **deps.** `# Dependencies: <path> (blast →N)`, then `Imports from (n):` rows `-> path (import: spec)` and `Imported by (n):` rows `<- path (import: spec)`. `concise` drops the specifiers. An import that leaves the worktree through a manifest is marked `external`. `mermaid` prints `graph LR` with absolute paths as labels.
- **stats.** Without `file_path`: `files=N (src=A/test=B) loc=L syms=S edges=E`, a `languages:` list and the `most imported:` files. With `file_path`: `path`, `LOC | Symbols (n exported) | Imports | Importers`, `Language | PageRank`.
- **impact.** `include_tests` defaults to **false** (a file is a test by its path: a `test`/`tests`/`spec`/`__tests__` directory, `x_test`, `x.test.ts`, `XTests.swift`). Sections: `Direct importers`, `Transitive blast radius` (most important first, with depth), `Co-change partners`, `Hot symbols in this file`. Each list shows 30 rows and then `… N more`. Co-change counts commits that touched both files among the last 2000 non-merge commits reachable from the view's base commit, skipping commits of more than 40 files and files no language module handles, and lists partners that changed together at least twice.
- **refs.** `symbol` (aliases `name`, `symbol_name`), optional `file_path` and `kind` to narrow, `include_tests` (default true), `transitive`. Each candidate definition prints `Symbol:`, `Defined in:`, then references grouped by file as `L144 call in enclosing_fn`; a reference matched only by a unique name is marked `(matched by name)`. `transitive=true` appends `Transitive dependents`.
- **calls.** `depth` defaults to 1. More than one function-like definition and neither `file_path` nor `kind` gives the refusal with `candidates:`. Output is `Callers (n):` / `Callees (n):` rows `[d2] name (kind) path:Lline via parent`. `mermaid` prints `graph LR` of the same edges.
- **map.** `Codebase: <name> (N files, M symbols indexed)`, then `# | File | PageRank | Exports | Blast` rows, then (detailed) each file's exported signatures, six at most. Test files and files without symbols are left out unless `all_files`. `by=symbols` ranks symbols. `boost_files` multiplies a file's rank by 10; `boost_terms` multiplies by 5 the rank of files whose path or symbol names contain a term. `with_health` is accepted and ignored.
- **add_root / workspace.** `path` (aliases `root`, `dir`, `file_path`; default the cwd) starts a build without waiting. `workspace action=remove` replies that there is nothing to remove.
- **Admin tools** (not part of the qartez surface): `status` (also as `data`), `hello`, `shutdown`, `build <path>` (waits for the whole build, up to 10 minutes), `gc <path>` (garbage-collect and vacuum that repository's store).

## When a request waits for a build

An unknown view is registered and built with the requested paths first (the files and their direct imports). `outline` and `read` of a symbol are answered as soon as that slice is stored. Every other tool needs to know who imports or calls what, and a partial graph would answer "no importers" for a file whose importers are not parsed yet, so it waits for the whole view. Both waits stop at 10 seconds (configurable with `--build-wait-ms`; a request may ask for less with `build_wait_ms`; never more than 30 seconds). After that the request is answered from what is stored, with `index: building` in the header. A request that names a file that is not parsed yet gets `state: BUILDING` instead of a "no such file" error. The build carries on in the background and concurrent requests for the same worktree share it.

## Wire protocol

Newline-delimited JSON over a Unix socket (mode 0600). Default path: `<store>/fdindex.sock`, where the store is `~/Library/Application Support/FlightDeck/index` on macOS and `$XDG_DATA_HOME/flightdeck/index` on Linux (the Linux default socket is `$XDG_RUNTIME_DIR/fdindex.sock`). `--store`, `--socket`, `FLIGHTDECK_INDEX_DIR` and `FLIGHTDECK_INDEX_SOCKET` override them. The path must fit a Unix socket (about 100 bytes); a longer one is refused with that message.

```
-> {"v":1,"id":7,"cwd":"/abs/cwd","seq":12,"tool":"find","args":{"name":"update"}}
<- {"id":7,"ok":true,"text":"view: …\nFound 2 match(es) for 'update':\n…"}
<- {"id":7,"ok":false,"error":"…","state":"BUILDING"}
```

- `v` is the protocol version the client speaks (now 1). A daemon that does not speak it answers `state: VERSION_MISMATCH`. `tool: "hello"` returns `data: {version, protocol, pid}`; clients call it first.
- `cwd` is required and absolute for every tool that reads code. `seq` is recorded per cwd (the watcher step will use it for read-your-writes). `id` is echoed.
- Tool names may carry the `qartez_` prefix.
- `state` is one of `UNAVAILABLE` (client-generated: the daemon cannot be reached or started), `BUILDING`, `BAD_REQUEST`, `VERSION_MISMATCH`, `ERROR`.
- A connection answers in order. Two requests in flight need two connections. A request line over 4 MiB is refused and the connection closed.
- `status` returns `text` and `data`: pid, uptime, RSS, request and error counts, blobs parsed, the views known (worktree, repo, base, dirty files, requests, idle seconds), builds in progress (phase, done, total), graph cache (count, charged bytes, facts bytes, budget, evictions) and each repository's store file size.
- `shutdown` answers and exits.

## CLI

`fdindex [--store DIR] [--socket PATH] [--cwd DIR] [--json] <tool> [first-arg] [--flag value]…`. Flags become arguments as written (`--file-path x` is `file_path`, `--build-wait-ms` is `build_wait_ms`). A flag without a value is `true`; the boolean flags (`--regex`, `--transitive`, `--include-tests`, `--all-files`, `--search-bodies`, …) never consume the next word. A repeated flag becomes a list. The first positional argument fills `name` (find, calls), `symbol` (refs), `query` (grep), `file_path` (outline, deps, impact, stats, build, gc, add_root); `read` takes a file if the argument contains `/` or is a file, else a symbol. If no daemon answers, the CLI starts `fdindex daemon` detached and retries. `fdindex status`, `fdindex stop` (returns when the daemon has exited) and `fdindex daemon [--graph-budget-mb N] [--build-wait-ms N]` manage it.
