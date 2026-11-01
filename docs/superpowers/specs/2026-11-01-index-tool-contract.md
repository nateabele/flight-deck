# fdindex tool contract (first cut)

The black-box compatibility contract with qartez v0.11.0. It comes from the public MCP tool schemas and from output observed on the flight-deck repo. No qartez source was read.

Every MCP tool is named `qartez_<verb>`, so existing skills, hooks and habits keep working. The CLI verb is `fdindex <verb>` (also `flightdeck index <verb>`, and `qartez <verb>` through the alias).

## Changes from qartez (required by the spec)
- **Paths.** Every path parameter accepts an absolute path or a path relative to the caller's cwd, which the shim sends. A relative path is never read against "the project root".
- **Output paths.** Every path in the output is absolute.
- **View header.** Every result starts with one line, e.g.:
  `view: /Users/me/Projects/Tessera/tessera (repo tessera, base 1a2b3c4, dirty 3 files)`.
  The parts: the absolute worktree; the repository's name; the first 7 characters of the base commit (`no commits` before the first commit, `not git` for a directory outside git); `clean`, or `dirty N files` where N counts the files that differ from the base.
  If a result draws on several views (see "Linked views"), each view other than the header's adds a line `linked view: <header text> via <manifest>` (or `dependent view: …`) after the header, and each row from one of them is labelled with its view.
- **Build state.** While the view is still building, the header adds ` index: building, N of M files` after the closing parenthesis. N and M count files of the view whose facts are stored.
- **add_root and workspace.** `qartez_add_root` and `qartez_workspace add` are accepted as hints that start a build early. They never change scope. `workspace remove` is accepted and does nothing.
- **Daemon down.** Every tool returns `state: UNAVAILABLE` plus a one-line reason. It never answers from a private index. (The CLI prints `state: UNAVAILABLE` and the reason to stderr and exits 3.)
- **Sandboxed client (Codex).** Under `codex exec -s read-only` and `-s workspace-write` (macOS seatbelt) `connect()` to the daemon socket fails with EPERM. A client treats `PermissionDenied` as a sandbox, not a missing daemon: it does not spawn one and reports `state: UNAVAILABLE` with `cannot connect to <socket>: Operation not permitted - a sandbox is blocking Unix sockets (for Codex: -s workspace-write -c sandbox_workspace_write.network_access=true, or run outside the sandbox); fall back to rg`. The MCP shim and `fdindex guard` (which still allows) say the same. `--no-start` / `FLIGHTDECK_INDEX_NO_START` is honoured by every client verb (query verbs, `mcp`, `session-start`); `status` never starts.

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
- **Admin tools** (not part of the qartez surface): `status` (also as `data`), `hello`, `shutdown`, `build <path>` (waits for the whole build, up to 10 minutes), `gc` (collect and vacuum every repository's store: queued for the maintenance thread, or run before it answers with `--now`; `gc <path>` does that path's repository only and waits).

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
- `status` returns `text` and `data`: pid, uptime, RSS, request and error counts, blobs parsed, the views known (worktree, repo, base, dirty files, requests, idle seconds, whether the view is kept between requests and swept by stat, with the files and directories swept, the last sweep's milliseconds and how long ago it last found a change), builds in progress (phase, done, total), graph cache (count, charged bytes, facts bytes, budget, evictions) each repository's store file size and free pages, the ref watcher (repositories watched, events seen) and the garbage collector (runs, bytes reclaimed in total, and the last run's repositories, worktree rows, trees and facts collected, pages vacuumed, bytes before and after).
- `shutdown` answers and exits.

## CLI

`fdindex [--store DIR] [--socket PATH] [--cwd DIR] [--json] <tool> [first-arg] [--flag value]…`. Flags become arguments as written (`--file-path x` is `file_path`, `--build-wait-ms` is `build_wait_ms`). A flag without a value is `true`; the boolean flags (`--regex`, `--transitive`, `--include-tests`, `--all-files`, `--search-bodies`, …) never consume the next word. A repeated flag becomes a list. The first positional argument fills `name` (find, calls), `symbol` (refs), `query` (grep), `file_path` (outline, deps, impact, stats, build, gc, add_root); `read` takes a file if the argument contains `/` or is a file, else a symbol. If no daemon answers, the CLI starts `fdindex daemon` detached and retries. `fdindex status`, `fdindex stop` (returns when the daemon has exited) and `fdindex daemon [--memory-mb N] [--graph-budget-mb N] [--build-wait-ms N] [--watch-hours N] [--no-watch]` manage it (`--watch-hours`, default 6: how long an idle worktree keeps its in-memory view; `--no-watch`: every request reads `git status` and no ref watcher runs).

Management verbs (top level, and `fdindex service <verb>`): `status` (the daemon's report, exit 3 when it is not running; **never starts it**, unlike every query verb; `--json` prints the raw reply), `stop`, `start`, `restart`, `install`, `uninstall`. `fdindex mcp [--no-start]` is the MCP shim.

## MCP shim (`fdindex mcp`)

A stdio MCP server, newline-delimited JSON-RPC 2.0 (`initialize`, `notifications/initialized`, `tools/list`, `tools/call`, `ping`; empty answers for `resources/list`, `prompts/list`). It holds no index and opens no database. Server name `flightdeck-index`; its `instructions` say, truthfully, that this is Flight Deck's machine-wide index, that paths may be absolute or relative to the launch directory, that results carry a `view:` line, and that `state: UNAVAILABLE` means fall back to `rg`.

- **cwd and seq.** The shim's launch directory is sent as `cwd` on every daemon request, with a `seq` that grows by one per `tools/call`. Under the `qartez` name, `--root DIR` sets that directory instead.
- **Tools.** The qartez v0.11.0 names and JSON schemas, captured from the installed binary over MCP: `qartez_map, find, grep, read, outline, deps, stats, impact, refs, calls`; the mutators `qartez_replace_symbol, insert_before_symbol, insert_after_symbol, rename, move, safe_delete, rename_file`; and the build hints `qartez_add_root`, `qartez_workspace`. Not exposed (not in the first cut): `qartez_tools` and the 23 analysis, meta and refactor tools outside this list. Schemas are in `src/mcp_tools.json`. They differ from qartez's in wording only: path parameters say "absolute, or relative to the caller's working directory", and `add_root` / `workspace` are described as build hints and make `path` / `alias` optional (so `add_root` requires nothing, `workspace` requires `action`).
- **Results.** A daemon answer is one text content block (the `view:` header included). A refusal is the same block with `isError: true`, reading `state: <STATE>` then the message. An unknown tool name is a JSON-RPC `-32602` error.
- **Daemon down.** If the daemon cannot be reached and cannot be started, the call returns `isError: true` and `state: UNAVAILABLE` plus one line of reason, e.g. `the index daemon is not running (…) and auto-start is disabled`. After a failed start, further calls answer the same at once for 5 s instead of each waiting out a start. `--no-start` (or `FLIGHTDECK_INDEX_NO_START`) disables the start; the default is to start the daemon, as every client does.
- **Reconnect.** A dead connection (the daemon restarted or was killed) is replaced and the call sent again. An applied edit (`apply=true` on a mutator) is never replayed: the shim first asks the daemon `hello` on the existing connection, so a stale one is found before the edit is sent, and a connection lost after the edit was sent is reported as UNAVAILABLE with a note that the file may have been written.

## The `qartez` name

`fdindex` behaves as the qartez alias when `argv[0]`'s basename is `qartez` (a symlink to `fdindex`; `fdindex switchover --apply` installs it, and `qartez-mcp` is accepted as the same name). `qartez mcp` is `fdindex mcp`; `qartez` with no verb starts the MCP server, as qartez does; `qartez find …` is `fdindex find …`; `--root DIR` (first one wins, anywhere on the line) is `--cwd DIR`. Qartez's indexing options before the verb (`--reindex`, `--no-watch`, `--git-depth`, `--db-path`, `--log-level`, `--wiki`, `--leiden-resolution`) are accepted and dropped; `--format json` before the verb is `--json`.

## Service (`fdindex service install|uninstall|start|stop|status|restart`)

Keeps `fdindex daemon` running at login. Nothing about it needs the Flight Deck app.

- **macOS.** A launchd user agent, `~/Library/LaunchAgents/dev.flightdeck.index.plist` (`--label` or `FLIGHTDECK_INDEX_LABEL` changes the label, for tests), loaded into `gui/<uid>` with `launchctl bootstrap`. `ProgramArguments` is the real path of the running `fdindex` (symlinks resolved) plus `daemon`, and `--store` / `--socket` only when they are not the defaults. `RunAtLoad`; `KeepAlive` is `SuccessfulExit=false`, so a crash is restarted (launchd waits its 10 s throttle) and a clean exit (`stop`, or a second daemon finding the lock held) is final. Output goes to `<store>/launchd.log`; the daemon's own log is `<store>/daemon.log`. `PATH` is set to include Homebrew's bin for `git`.
- **Linux.** A systemd user unit, `~/.config/systemd/user/<label>.service`, `ExecStart` as above, `Restart=on-failure`, `WantedBy=default.target`, installed with `systemctl --user daemon-reload` and `enable --now`. Rendered and unit-tested here, not run on Linux yet.
- **install** is idempotent: an unchanged unit that is loaded is left alone; a changed one is unloaded and reloaded. It stops a daemon a client started earlier so the unit's daemon owns the lock and is the one that gets restarted; sessions reconnect on their next call. **uninstall** unloads, removes the unit and stops any daemon left, and is a no-op when not installed.
- **start** runs the unit when installed (`launchctl kickstart`), else starts the daemon unsupervised and says so. **stop** asks the daemon to exit and waits until it has. **restart** is both.
- **status** prints the service (installed, loaded, unit path), the binary, socket and store paths, then from the daemon's `status`: pid, version and protocol, uptime, resident memory and graph-cache use against its budget, the size of the repository stores, request counts, every view (worktree, repository, base, dirty files, requests, idle time) and every build in progress. A stopped daemon is `daemon:   not running` and exit status 3.

## `flightdeck index …`

The `flightdeck` CLI's `index` verb passes everything after `index` to `fdindex` and becomes that process (`execv`): stdio and exit status are fdindex's, and `--json`, `--socket` and `--help` after `index` are fdindex's, not flightdeck's. `fdindex` is found at `$FLIGHTDECK_FDINDEX` (an override that points nowhere is an error, not a fallback), then beside the running `flightdeck` (`Flight Deck.app/Contents/MacOS/fdindex`, where the build puts it), then on `PATH`; none is exit 127 with a message. It does not use the app's control socket, so it works with the app closed. `flightdeck index` alone or `--help` prints the verb's help page.
## Linked views

A manifest that points outside its repository links the repository it lands in (spec §5.3). The link is the **literal path**: `../tessera/designer/src` is whatever worktree sits at that path (the `tessera` main checkout), never a worktree of it paired with this one (requirement 14).

- **Manifests read.** `elm.json` `source-directories`; `tsconfig.json` `compilerOptions.paths` targets (against `baseUrl`, comments and trailing commas allowed) and `references`; `package.json` `file:`/`link:` dependencies (not tarballs) and `workspaces` (up to the first glob); `mix.exs` `path:`; `Cargo.toml` `path =` in a dependency, `[patch]` or `[replace]` table. A target inside the worktree, one that does not exist, and one in a directory that is neither a repository nor a recognised project are not links. Links are recorded per view and re-read when a manifest's content (git blob id) changes, so editing `elm.json` takes effect on the next query.
- **Cross-view resolution.** Elm imports (any source directory outside the worktree) and TypeScript/JavaScript relative imports that climb out of it resolve into the linked view's file. A reference through such an import is looked up in the linked view (`Expression.Node.toString`, `Node.decode`, constructors exposed with `Type(..)` or `(..)`). TypeScript `paths` aliases, `package.json` dependency names and Cargo/mix path dependencies are linked (a pathless search finds their symbols, a mutation is guarded) but their imports are not yet resolved across the link, so `refs`, `calls`, `deps` and `impact` do not follow them.
- **Where it applies.** `find`, `grep` (symbol search) and `read` by symbol with no `file_path` search the caller's view, then the linked views, inside the directories the manifests name (`tessera` is searched in `designer/src` and `typesystem/src`, not whole). `refs`, `calls`, `deps` and `impact` follow imports across views in both directions: from `formula-editor`, `refs Expression.Node.identifierToString` lists the references in `formula-editor` and in `tessera`; `deps`/`impact` on `../tessera/designer/src/Expression/Node.elm` list the `formula-editor` importers. The views on the other side of a link are the ones the answering view's manifests point into (*linked*) and the ones whose manifests point into it (*dependent*): the caller's own checkout when the query named a path elsewhere, plus any view seen before and already indexed. `outline`, `map`, `stats` and `read` of a file range use one view.
- **Labels.** Rows from a view other than the header's carry `[view: <repo> @ <worktree>]` (`find` prints a `View:` line). Lists that span views keep at most 40 rows per view, so a long list in one view does not push the cross-view rows out of the token budget.
- **Build.** A linked or dependent-and-asked-for view that is not indexed builds as part of the request, in parallel with the answering view, and a cold first query from `formula-editor` builds both. One still building at the bound answers from what is stored and says `index: building, N of M files` on its `linked view:` line. Graphs of linked views live in the same cache and under the same budget as any other; nothing is loaded twice.
- **Location.** A resolved graph is shared by the clean worktrees of one commit, but `../lib` is a different directory from each. A graph whose resolution looked outside its root is re-resolved for a worktree that stands elsewhere.

### Mutators and links

A mutator writes into the view that answers the lookup and nowhere else.

- No `file_path`, symbol defined only in a linked view: refused (`'x' is not defined in your view …, but a linked view defines it; … never writes into a linked view unless you name a path inside it`), listing the definitions with their views. Nothing is written, preview or apply.
- `file_path` inside the linked view: the mutator plans and writes there as for any view (the answer notes it is not the caller's worktree), **unless** the change would break another view. `rename`, `move`, `safe_delete` and `rename_file` are refused when views that link into the target (the caller's checkout, and views seen before that are indexed) use the symbol or import the file. The refusal lists the files the change would touch in the target view and the sites (`path:line`) in each other view. The first cut does not also rewrite the other checkout: that would edit a view the agent did not name (§5.5), and a half-applied cross-repository rename is worse than a refused one. The agent makes the change in each view, dependent view first.
- A rename of a symbol no other view uses goes ahead. A dependent view that is known but not indexed is not checked; the preview says so in a `warning:`.

## Mutators as built

Arguments beyond the table: `file_path`/`file`/`path` and `kind` narrow the symbol; `rename` takes `old_name`/`new_name` (a qualified `Type::name` also selects); `rename_file` takes `from`/`to`; `move` takes `to_file`; the CLI maps positionals in order (`fdindex rename old new --apply`, `fdindex move sym to/file.rs`). `token_budget` bounds the diff of a preview.

- **Preview by default.** The answer is the view header, `preview: …; nothing written, pass apply=true to write`, notes, `warning:` lines, then `diff -u` per file with absolute paths (created files diff against `/dev/null`).
- **Apply** answers with the header, `applied: …`, one `modified|created|deleted <absolute path>` line per file, and `view updated: N blob(s) re-parsed and the graph recomputed; the next query from <cwd> sees the change`.
- **Which view.** The view containing `file_path` (for `rename_file`, `from`), else the caller's cwd. A name that is defined only in another checkout is refused ("no definition named …", or, for a linked view, the refusal under "Mutators and links"), never a write there. If the path the agent named is in a different worktree from the cwd, the answer adds `note: this is not your worktree (…): the path you named is in …, so that is where the change lands`.
- **Safety.** Every written path must resolve under the view's worktree (symlinks resolved; a symlink target is refused). Files are written temp+rename with their permissions, and each file's bytes are re-checked against what the plan read; if one write fails the earlier ones are put back. A file whose bytes no longer hash to the blob the index parsed is refused (`stale index:`; the daemon replans from a fresh view up to 3 times first). A per-worktree reader/writer gate means a concurrent query sees the worktree before or after a mutation, never between two of its writes. A mutator waits for the complete index (never works from a partial graph) and answers `state: BUILDING` if the wait bound passes.
- **Selection.** Several definitions of the name: refuse and list `kind  /abs/path [Ls-Le] in Parent`. `impl` blocks are not candidates. Rename refuses fields (their uses are not indexed) and Rust modules (use `rename_file`).
- **replace_symbol** replaces the symbol's own line range (attributes and doc comments above it are kept). A symbol that shares lines with other code (`impl X { fn f() {} }`) is replaced by columns. `new_code` must start with a definition introducer for the language (after attributes and comments), or be a member/variant for kinds that have none.
- **rename** rewrites the definition, every reference the graph resolved to it (line + name + qualifier), import lists naming it (following re-exports), the Elm `module … exposing` header, and members reached through a renamed type (`Store::new`). Aliased imports keep their alias. Occurrences in strings and comments are never touched. Files involved that still contain the old name afterwards are listed as a warning (a shadowing local, a template literal, a destructured dynamic import).
- **move** (Elm, TypeScript/JavaScript, Rust): cuts the definition with its doc comment and attributes, adds it to `to_file` (created if missing: Elm module header and name from the source directory, Rust `mod` line in the parent module file), copies the imports the moved code needs, repoints every importer (exposing lists, qualified uses, `import { x } from`, `use` paths), imports it back into the source if the source still uses it, and exposes what the moved code reaches back for. Refused: Elm moves whose code needs a sibling the source uses back from it (an import cycle); non-exported siblings in TS/Rust; non-top-level symbols.
- **rename_file** (Elm, TypeScript/JavaScript, Rust): Elm rewrites the `module` line, `import`s, and unaliased qualified uses, and `exposed-modules` in `elm.json`; TS/JS rewrites relative specifiers in importers and in the moved file's own imports; Rust rewrites the parent `mod` line and `use`/qualified paths, within one directory, refusing `mod.rs`, `lib.rs`, `main.rs` and modules with child directories.
- **Other languages**: `rename`, `replace_symbol`, `insert_*` and `safe_delete` work from index facts; `move` and `rename_file` refuse naming the gap.
- **safe_delete** counts references from outside the symbol (and its constructors) plus import lists naming it, refuses unless `force`, takes doc comments with it, and removes the name from an Elm module's `exposing` list.

## The acknowledgement gate (for the switch-over step)

Today's gate is the `qartez-guard` binary, registered as a `PreToolUse` hook on `Edit|Write|MultiEdit` and `Glob|Grep` in `~/.claude/settings.json` and `~/.claude-radify/settings.json`. Observed as a black box:

- It denies an `Edit` of a file whose PageRank or blast radius is over `--pagerank-min` / `--blast-min` (env `QARTEZ_GUARD_PAGERANK_MIN`, `QARTEZ_GUARD_BLAST_MIN`) unless an ack for that file is younger than the TTL (`--ack-ttl-secs`, env `QARTEZ_GUARD_ACK_TTL_SECS`; the default is between 5 and 10 minutes, probably 600).
- Acks live in `<project_root>/.qartez/acks/` where `project_root` is `$CLAUDE_PROJECT_DIR` or auto-detected (`--project-root`). A linked worktree has its own `.qartez/` (for example `flight-deck-worktrees/canvas/.qartez/acks`), so acks are per worktree today.
- One file per path. Name: the FNV-1a 64-bit hash (offset `0xcbf29ce484222325`, prime `0x100000001b3`, over the UTF-8 bytes of the path relative to the project root, no newline), as 16 lowercase hex digits. Content: `<unix seconds>\n<relative path>\n`. All 40 files in the flight-deck checkout match that name rule.
- Age is the file's **mtime**, not the epoch in its content (an ack with a 5000 s old epoch and a fresh mtime was accepted; one with a fresh epoch and an old mtime was denied).
- The guard also reads PageRank and blast radius from `<project_root>/.qartez/index.db` (`--db`), so the guard itself must be replaced or pointed at the daemon at switch-over; writing compatible acks alone does not retire it.

To stay compatible per view, the new `impact` tool writes `<view worktree>/.qartez/acks/<fnv1a64(relative path)>` with that content on every call. The view's worktree is the right root: it is what `$CLAUDE_PROJECT_DIR` is for a session started in that worktree.


## Switch-over (spec §11a step 8), as built

`fdindex guard`, `fdindex session-start` and `fdindex switchover` replace `qartez-guard`, `qartez-setup --session-start` and the hand edits of every agent config. Sources: `src/guard.rs`, `src/session_start.rs`, `src/switchover.rs`, `src/ack.rs`, `src/textedit.rs`.

### `fdindex guard` (PreToolUse hook)

Same observable contract as the installed `qartez-guard`, characterised black-box: Claude Code's PreToolUse JSON on stdin; stdout is empty to allow or `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"…"}}` plus a newline to deny; the exit status is always 0. `scripts/guard-parity.sh` runs both on the same inputs (31 cases, all matching in decision and wording).

- `Glob`/`glob`, `Grep`/`grep` and Gemini's `grep_search` are denied in a project whose index is ready, whatever the pattern (the old hook words `grep_search` like `Glob`). Messages are the old ones, naming `qartez_map`, `qartez_find`, `qartez_grep`.
- `Edit`, `Write`, `MultiEdit`, `replace`, `write_file` of a file whose PageRank is at least `--pagerank-min` / `QARTEZ_GUARD_PAGERANK_MIN` (0.05) or whose blast radius is at least `--blast-min` / `QARTEZ_GUARD_BLAST_MIN` (10) are denied unless an ack is no older than `--ack-ttl-secs` / `QARTEZ_GUARD_ACK_TTL_SECS` (600; `QARTEZ_ACK_TTL_SECS` also works). The message lists the exceeded thresholds (PageRank first) and the file's three top symbols. A file the index does not know is not guarded. `QARTEZ_GUARD_DISABLE` other than empty, `0` or `false` turns it off. `--db` is accepted and ignored.
- Facts come from the daemon through an internal `guard` request (`{"state":"NONE|BUILDING|READY","worktree","in_index","rel","pagerank","blast","hot":[…]}`): the view that holds the file, ranks from its graph, blast radius within that view. The old hook looked for `.qartez/index.db` upward from the file; this one does not need a project directory at all, so `$CLAUDE_PROJECT_DIR` and `--project-root` only stand in for a missing `cwd`.
- **The index never blocks an agent.** Daemon not running or not answering (2.5 s), or the view still building (1.5 s wait): the call is allowed and stderr says why. The hook never starts a daemon.
- Acks are written by `impact` (`src/ack.rs`) into `<view worktree>/.qartez/acks/`, in the format above, so the old guard and the new one accept each other's.
- One deliberate difference: a relative `file_path` is resolved against the call's `cwd`; the old hook resolved it against its own working directory (Claude Code always sends absolute paths).

### `fdindex session-start`

`qartez-setup --session-start` prints nothing and, in the background, indexes the session's project and checks GitHub for a newer qartez (observed in a temp HOME: `~/.qartez/last-update-check`, `~/.cache/qartez-mcp/session-index.log`). `session-start` keeps the useful half: it starts the daemon if needed and starts the cwd view's build without waiting (the `guard` request with no file does that, and answers `NONE` for a directory that is no project, so a session in `~` indexes nothing). It prints only when an agent should act: the daemon could not be started or did not answer within 4 s (`state: UNAVAILABLE`, fall back to rg), or the view is still building. Exit status 0 always.

### No `.qartez/status.json`

The daemon is machine-wide, so a per-project status file would be written into every worktree and go stale; the results carry the state instead (`view:` header with `index: building, N of M files`; `state: BUILDING|UNAVAILABLE|…` on refusals), and `fdindex status` describes the daemon. The skill draft says so.

### `fdindex switchover`

`--dry-run` (the default) prints every file and change, `--apply` does it, `--rollback` undoes the last apply, `--list-old-dbs [root…]` lists `.qartez/index.db` files with sizes (default root `~/Projects`) and deletes nothing. `--home`, `--store` and `--no-service` exist for rehearsal. See the module comment of `src/switchover.rs` for exactly what changes, and `scripts/switchover-rehearsal.sh` for the round trip on copies of the real files.

## Memory

`--memory-mb N` (default 1536) is the RSS the daemon aims to stay under. It maps to a limit on live heap, `(N - 192 MB) / 1.2`, and to the default graph budget of the same size; `--graph-budget-mb` alone raises the target to fit it. `status` reports `rss_bytes`, `memory_target`, `heap_bytes`, `heap_peak_bytes`, `vm` (macOS: resident, internal, reusable, footprint) and `graphs.heap_limit`. The default is the figure the graph budget used to be: 1.5 GB holds about 30 tessera-size graphs, one hot worktree per agent for thirty agents; 1 GiB holds 19 and cycles its cache under that load.

Measured on tessera (86 to 93 worktrees, the count grew while measuring): every worktree queried one after another, twice; then 30 clients (reads, builds, applies in throwaway worktrees) for 90 s. The host's load average was 80 to 165 throughout, so latencies compare roughly:

| | RSS after sweep | RSS peak, 30 clients | live heap peak | graphs cached | evictions (sweep x2 / mixed) | find p50 sweep 1 / 2 / mixed |
|---|---|---|---|---|---|---|
| before: 1.5 GB graph budget | 1803 / 1816 MB | 2636 MB | 2071 MB (earlier run) | 41 | 155 / 1982 | 568 / 297 / 682 ms |
| `--memory-mb 1536` (default) | 1424 / 1441 MB | 1660 MB | 1206 MB | 30 | 178 / 742 | 814 / 319 / 3601 ms |
| `--memory-mb 1024` | 1023 / 1038 MB | 1165 MB | 810 MB | 19 | 197 / 452 | 834 / 340 / 8781 ms |

Reading the latency: a hot find is 7 ms either way, and the second sweep is within noise. What costs is the mixed run, where 30 clients pick among about 95 worktrees at random: with fewer graphs cached more requests rebuild one (0.2 to 0.4 s on a quiet machine, seconds on this loaded one), and builds now queue for four slots instead of all running at once. Machines that want the old latency under that load can pass `--memory-mb 3072`.

Where the memory went (before): 1327 MB live heap at 1512 MB charged (graphs and their facts, 12.4 million allocations); kept views of 85 worktrees 93 MB; 130 to 190 MB resident that is not live heap at all (a daemon holding one graph is at 440 MB RSS with 200 MB live); and, under concurrency, 700 MB of transient peak from builds running together plus graphs evicted from the cache while requests still held them, which freed nothing and were not counted. Allocator retention is real but not recoverable from inside the process on macOS: `malloc_zone_pressure_relief` ran 83 times without changing RSS, swapping in mimalloc (with `mi_collect`) was 200 MB worse at one graph, and the kernel's own accounting (`vm`) marks 85% of the resident pages reusable, which is why an RSS-triggered eviction loop would evict everything and free nothing.
