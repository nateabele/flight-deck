# Shared code index: a retrofitted qartez as Flight Deck's Index Service

Status: design agreed in conversation with the maintainer on 2026-11-01 (session "Agent Streams"). It has had no builder check yet, and the plan has not been written. The "New Index" session owns it from here.
Implements: the **Index Service** row of the [Flight Deck design](2026-07-09-flight-deck-design.md) §2 (line 39), its open risk "Index as a shared service" (line 101), and phase 2 "Full Index Service" (line 108).
Companion: [agent work streams research](2026-11-01-agent-work-streams-research.md). It has the measurements behind this spec and the wider findings for Flight Control.

## 1. Intent

All agents on a machine share one code index. Claude sessions and their subagents, Codex streams, opencode and plain terminal sessions all use it. It replaces the current setup, where every session starts its own qartez MCP server against the folder it launched in.

Why now: agents mostly read code through `cat`, `sed -n` and `rg`, because the index fails them in worktrees and does not know Elm. In a sample of 150 Tessera subagents, Bash read and search output was 45–58% of every role's transcript (see the companion doc, §3). A working shared index is the largest single saving available.

The engine is **qartez** (kuberstar/qartez-mcp, Rust, tree-sitter, SQLite), forked and retrofitted. Flight Deck's notes call it "quillmap". The tool surface stays the same, so the existing skills, hooks and agent habits keep working.

## 2. Requirements

### Decided by the maintainer

1. **Worktrees are first-class.** A new worktree can be searched at once. Nobody registers it.
2. **Any path resolves.** An agent can name a file or repository outside its own working directory, and the lookup uses that repository's index. The common case: this repo's `elm.json` lists `../tessera/designer/src` and `../tessera/typesystem/src` as source directories.
3. **A missing index builds itself.** The first reference to an unknown repository starts its index. There is no setup step.
4. **It works when the Flight Deck app is not running.** Examples: a headless Codex run on m3, or an agent in a plain terminal.
5. **Scope:** every repository on the machine, Codex sessions, and other machines.
6. **Stretch goal:** paired hosts (m3, jeeves) and cloud infra hosts (`flightdeck infra up`) take part. Worktrees and auto-build are the minimum.

### Agreed in the playback (proposed by Claude, confirmed by the maintainer)

7. **One process owns the index on each machine.** Sessions connect to it and do not open the database themselves.
8. **Parse results are keyed by git blob.** Each version of a file is parsed once, however many worktrees hold it. A worktree is its base commit plus an overlay of its changed files.
9. **Read your own writes.** After an agent edits a file, its next query sees the edit.
10. **Elm support** is part of the retrofit.
11. **Hosts index what they receive.** Delegated execution already holds a git object store on each host. Facts keyed by blob can move between machines instead of being rebuilt.

### Decided by the maintainer in the New Index session (2026-11-01)

12. **`flightdeck index` is the command surface.** One server controls every index on the machine. Its management commands (start, stop, status, rebuild, garbage collection, vacuum) are `flightdeck index` subcommands. The query verbs are also there (`flightdeck index find|read|refs|outline|…`). A `qartez` name stays as an alias, so the existing skills, hooks and agent habits keep working.
13. **The code lives in the Flight Deck repository.** The daemon, shim and the retrofitted engine are built and shipped with Flight Deck and its host daemons. They are not kept in a separate qartez fork.
14. **Links resolve the literal path only.** `../tessera` in `elm.json` means whatever checkout is at that path. Pairing a worktree with a specific worktree of another repository is deferred.
15. **Codex intakes use the CLI only.** They keep MCP servers disabled and reach the index through `flightdeck index` (or the `qartez` alias) from Bash.
16. **A clean-room engine, not a qartez fork.** qartez is dual-licensed (`LicenseRef-Qartez-Dual`), and that license forbids bundling it into a distributed product. Flight Deck is BSD-3. So the engine is new code written for Flight Deck. No qartez source may be copied or consulted. The compatibility contract is qartez's public tool names, parameters and result shapes, as the skill docs and the MCP tool schemas describe them. "Retrofit" elsewhere in this doc means "replace with a compatible engine".
17. **The engine is in Rust.** It uses tree-sitter grammar crates and SQLite. It is a cargo workspace under `Packages/` that builds for macOS and Linux.
18. **First cut:** `map`, `find`, `grep`, `read`, `outline`, `deps`, `stats`, `impact`, `refs`, `calls`, plus the mutators (`replace_symbol`, `insert_before_symbol`, `insert_after_symbol`, `rename`, `move`, `safe_delete`, `rename_file`). The analysis tier (hotspots, clones, smells, security, wiki, semantic, trend, blame, …) comes later. Agents switch over once the first cut passes §9.
19. **The §8 step 1 vacuum runs now.** It runs against the live `formula-editor` database.

## 3. What is wrong with qartez today

All of this was measured or read in the source on 2026-10-31, against v0.11.0 (tag `v0.11.0`, commit 7fdb5095, released 2026-07-03). That is the newest release and the installed binary (`~/.local/bin/qartez`). Upstream issues #28 (cross-process lock) and #29 (runtime `add_root`) are closed, and their fixes are in 0.11.0. They do not fix the problems below.

| # | Problem | Where | Effect |
|---|---|---|---|
| Q1 | The index root is the folder the session started in. | per-session MCP server | Tessera controllers start in the frozen `formula-editor` repo, so their only root has 1,583 files. They cannot see `tessera/` master or any worktree. |
| Q2 | Absolute paths are refused, even under a registered root. | `src/server/mod.rs`, `safe_resolve` | Agents get "must be relative to the project root" and fall back to `cat`. |
| Q3 | `add_root` fails with "database is locked". | `src/server/tools/workspace.rs`, `add_root_inner` | It runs a full index, PageRank and co-change in one `unchecked_transaction`, under an in-process mutex only. It never takes the cross-process `RepoLock` (`src/lock.rs`) that startup, the CLI and the watcher use. About 22 qartez processes held the same `index.db` open (44 file handles) with `busy_timeout = 5000` (`src/storage/mod.rs:75`). The exact SQLite error code is inferred from the code, not captured. The Execute 4 ledger records the failure. |
| Q4 | The shared database grows and never shrinks. | `formula-editor/.qartez/index.db` | 32.6 GB. 6.83M of its 7.96M pages are free (about 28 GB). `auto_vacuum = 2` (incremental), but nothing runs the vacuum. The live data is about 4.6 GB. |
| Q5 | There is no Elm language. | `src/index/languages/` (39 modules, including `haskell.rs` with 700 lines and `ocaml.rs`) | Tessera has 1,311 `.elm` files. In a test index of master all of them were skipped, and `find traverseStep` and `find checkPartial` returned nothing. In the subagent sample, Elm reads were 27% of all Bash output. Languages qartez supports (Elixir, TS, Rust, JS) were about 25%. |
| Q6 | Mutators write to the wrong checkout. | Flight Deck `docs/AGENT-OPERATIONS.md:549` and about 15 plans | "quillmap mutators … report success while writing to the main checkout" when run from a worktree. Every Flight Deck plan bans them in worktrees. |
| Q7 | Files are keyed by path and mtime. | `src/storage/schema.rs`: `files(path UNIQUE, mtime_ns, size_bytes, …)` with autoincrement `symbols`, `symbol_refs` and `edges` per file | Two worktrees with the same file cannot share its parse. Each root is indexed in full. There are 324 Tessera worktrees. |
| Q8 | Each session runs its own server. | — | 34 qartez processes were running on this Mac. Each one watches and re-indexes the same trees. |

The per-worktree CLI works today: `qartez --root <worktree> find|read|outline|refs`. On a copy of tessera master (1,636 source files) at load average 16.8, the first index took **4.0 s**, peaked at **200 MB** RSS and wrote a **44 MB** database. Later queries took **0.29 s** each. That run gives the baseline for §9.

## 4. Architecture

```
 Claude session ─┐   stdio MCP     ┌──────────────────────── index daemon (one per machine) ───────────────────────┐
 Codex stream  ──┼─► `qartez mcp` ─┼─► Unix socket ─► request router ─► view resolver ─► query engine (reader pool) │
 opencode      ──┤   shim (cwd)    │                          │                 │                                   │
 terminal CLI  ──┘   `qartez find` │                          ▼                 ▼                                   │
 Flight Deck app ── status/control ┤                   build scheduler ─► parser workers ─► single writer ─► store  │
                                   │                          ▲                                                     │
                                   │      fs watcher (active worktrees) + git ref watcher (all known repos)         │
 peer host daemon ◄── index channel over the HostKit link (stretch) ──────────────────────────────────────────────►│
                                   └────────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 The daemon

- **One daemon per machine** and per OS user. It is the only process that opens the store, and it has a **single writer**. Readers are WAL connections inside the same process. This removes Q3 and Q8 by construction.
- **Independent of the app** (requirement 4). On macOS it is a launchd user agent. On Linux it is a systemd user unit. If the daemon is not running, a client starts it. The Flight Deck app is a client. It shows status and can restart the daemon, but nothing depends on the app.
- **Bundled with the host daemons.** `HostDaemon` (macOS) and `HostDaemonLinux` ship the index daemon, so a paired host or an infra host has one (§7).
- Binary and process names are the builder's call. This doc says "the daemon".

### 4.2 Clients

- **MCP shim.** Each agent's MCP config launches a thin `qartez mcp` process, as it does today. It holds no index and forwards each call to the daemon over a Unix socket. With every call it sends the caller's **working directory** and a **request sequence number** (§5.4). Claude Code and Codex use the same shim.
- **CLI.** `qartez find|read|outline|refs|…` talks to the same socket. Agents can use it from Bash, and subagents that lack MCP tools can use it too.
- **Tool surface.** The tool names and result shapes stay as in qartez (`qartez_map`, `qartez_find`, `qartez_read`, `qartez_refs`, `qartez_impact`, the mutators and the rest). One change: every path parameter accepts **absolute paths** and paths relative to the caller's cwd (fixes Q2). `qartez_add_root` and `qartez_workspace add` remain but are never required. They become hints that start a build early.
- **Codex intakes** run with `--disable hooks` and no `config.toml` MCP servers (`ARCHITECTURE.md:2444`). They can still reach the index through the CLI. Whether intakes get the MCP shim is a Flight Control decision.

### 4.3 Identity: repository, worktree, view

- **Repository** = a git common dir (`git rev-parse --git-common-dir`). All of a repo's worktrees share one repository record, so all of Tessera's 324 worktrees are one repository.
- **Worktree** = a working directory with its own git dir. The daemon finds it by walking up from any path to the nearest `.git` file or directory. A `.git` *file* means a linked worktree.
- **View** = what a query reads: one worktree at one moment. It is the tree of its `HEAD` commit, plus an **overlay** of the paths that differ from it (modified, added, deleted or untracked and not ignored).
- **A directory that is not in git** becomes a repository with no commits. Its whole content is the overlay. Blob ids are still computed the way git computes them (`git hash-object`), so the content keying stays the same.

### 4.4 Storage

There are three layers. Only the first is expensive to build.

1. **Blob facts.** These are keyed by `(blob id, language, parser version)` and shared by every view on the machine. They hold what one file says about itself: symbols with kinds, line ranges, signatures, shape hashes and parents; import specifiers; unresolved outgoing references by name; and type-hierarchy facts. The data is the same as qartez's per-file rows. It loses only its `file_id` and keeps local ids within the blob. **As built (2026-11-01):** a reference's name and qualifier are stored as ids into the repository database's append-only `names` table, and the daemon holds each repository's names once, in a frozen pool every graph of that repository shares (a reference is 20 B in memory instead of 64 B plus two strings: on tessera 72 MB of references became 16 MB). The ids are scoped to one database file, so sharing parsed facts between repositories, or with another machine (below), goes through the text form (`Reader::get_facts`), not the ids. A blob's symbols, imports, references and relations are stored as one columnar chunk (schema version 3, `src/chunk.rs`), not a row each: every column is bit-packed, delta-, run-length- or dictionary-coded, whichever is smallest for that blob, and the whole body then goes through zstd. On a store of all 85 tessera worktrees (9,488 blobs) the fact tables went from 122 MB to 18 MB and the store from 181 MB to 80 MB. Loading every blob of one checkout went from 183–406 ms to 72–117 ms, and collecting 2,000 blobs from 1.28 s to 0.15 s. There is no name-to-blob postings table: the store never had a name index to replace (every name lookup is answered by the in-memory graph), and a table nothing reads would only add bytes.
2. **Trees.** For each indexed commit, a map of path → blob id. Git already stores this, so the store keeps only what it needs for fast lookup (path, blob, language).
3. **Resolved graph.** Resolved `edges` and `symbol_refs`, PageRank, clusters and unused exports, computed for one **base tree**. A worktree overlay reuses its base graph and re-resolves only the changed files and the files that import them. Co-change comes from git history, so it is computed per repository, not per view.

Retention: a blob's facts are kept while any tree, overlay or known ref names the blob. A garbage-collection pass removes the rest, and the store runs an incremental vacuum on a schedule (fixes Q4). Where the store lives and whether it is one SQLite file or one per repository are the builder's call. One file per repository makes it easy to drop a repo and limits how far one corrupted file reaches.

Embeddings (`symbol_embeddings`, the optional `semantic` feature) are keyed by blob in the same way.

## 5. Behaviour

### 5.1 Resolving a request

1. The shim sends `{cwd, seq, tool, args}`.
2. Each path argument resolves against `cwd` if it is relative. The worktree is found by walking up from the resolved path, not from `cwd`. So `../tessera/designer/src/Expression/Node.elm`, named from `formula-editor`, is answered from the `tessera` main checkout's view.
3. A symbol query with no path (`find traverseStep`) searches the **caller's view**, and then the **linked views** of that view (§5.3).
4. Each result carries absolute paths and the view it came from (repository, worktree path, base commit, dirty or clean), so the agent can tell which checkout answered.

### 5.2 Auto-build

- A request that touches an unknown repository or worktree **registers it and starts a build**. Nobody has to call `add_root`.
- **Requested paths are built first.** The scheduler parses the requested files and their direct imports before the rest of the repository. The request waits for that slice. It is answered from it, and the answer says `index: building, N of M files`. The rest of the build goes on in the background.
- **A new worktree on a known base commit is almost free.** Its base tree's blob facts and graph already exist. Only its overlay is parsed. For a fresh `git worktree add`, the overlay is empty.
- A worktree on a new commit is diffed against the nearest indexed tree. Only blobs not yet in the store are parsed.
- Removed worktrees are found when their directory goes. Their overlays are dropped, and the garbage-collection pass takes what no one references.

### 5.3 Links between repositories

Requirement 2 covers explicit paths (§5.1) and also references a manifest declares. The daemon reads the module paths that manifests declare and **links** the views:

- `elm.json` `source-directories` (for example, `formula-editor` → `tessera/designer/src`, `tessera/typesystem/src`);
- `tsconfig.json` `paths` and project references, `package.json` `file:`/`link:` and workspace deps;
- `mix.exs` `path:` deps, `Cargo.toml` `path =` deps.

A link points at a **path**, so it resolves to whatever worktree is at that path. Here `../tessera` is the `tessera` main checkout. An import that leaves the repository resolves into the linked view, and the linked view is auto-built if it is missing. `refs`, `calls`, `impact` and `deps` follow these links and label each cross-repository result.

The manifest list above is a starting set. Which ones ship first is the builder's call. `elm.json` comes first because it is today's case.

### 5.4 Freshness: read your own writes

- An **fs watcher** covers **active worktrees**: any worktree queried or written in the last N hours, plus every worktree a running Flight Deck session sits in. A **ref watcher** covers every known repository's `HEAD`s, so commits, checkouts and rebases move the base tree. macOS uses one FSEvents stream for all of them. On Linux, the watcher must stay inside inotify limits, so worktrees idle past N hours lose their watch and are re-checked on their next query.
- **Read-your-writes rule:** before the daemon answers a request, every file change made before the request in the caller's view is in the index. The shim's `seq` and the daemon's own mutator writes make this checkable. An FSEvents flush (or, failing that, a stat of the overlay paths git reports as dirty) closes the gap for edits made outside the daemon (built-in `Edit`, `sed -i`, Codex `apply_patch`). How the rule is enforced is the builder's call. That it holds is a requirement, and it needs a test (§9).
- A worktree with no watch is re-checked against `git status` on its next query, before the answer.

**As built (2026-11-01): freshness rests on `stat`, not on events.** The barrier described above (an FSEvents flush, or a cookie file written after the request and waited for) was built and measured first: over 115,000 external writes under load it missed 4, because an event for an edit made before the cookie can be delivered after the cookie's own events (traced: a finished `mv` produced events with ids higher than the cookie's creation event). That is a 1-in-30,000 chance of a stale answer after an edit, which the requirement does not allow. Every request instead `stat`s every indexed file and every non-ignored directory of the caller's view against the last sweep (measured on tessera through the daemon, p50 / p95 per request: 1.5 / 1.7 ms for the main checkout against 22.0 / 24.5 ms for `git status`; 1.3 / 1.8 ms for a fresh linked worktree against 60 / 67 ms; 1.7 / 2.2 ms with eight files edited against 200 / 217 ms; the barrier was 10 / 12 ms), treats entries changed within 2 s of being observed as unsettled and reads them again (git's "racy" rule), and asks git about new paths only. There is therefore no inotify bound to respect on Linux and no file watch to drop: "active" (the N hours, default 6, `--watch-hours`) means only that a worktree's kept view and snapshot are held in memory. FSEvents still runs the **ref watcher** on macOS, one stream over every known repository's common dir, to keep the known refs current and to prepare the new base tree of kept worktrees after a commit, checkout or rebase; a late or lost ref event costs a late warm-up, never a wrong answer, because every request reads HEAD itself.

### 5.5 Mutators

- Mutators (`qartez_replace_symbol`, `qartez_rename`, `qartez_move`, `qartez_safe_delete`, `qartez_rename_file`, the inserts) **write inside the view that answered the lookup**. That is the caller's worktree, unless the agent named a path in another one. This fixes Q6.
- A mutator re-indexes the files it wrote **before it returns**.
- A mutator never writes into a *linked* view unless the agent gave a path inside it.
- The load-bearing acknowledgement gate (`qartez_impact` before `Edit`) keeps its present behaviour. Its state is kept per view.

### 5.6 Languages

- **Elm** (fixes Q5). Model it on `haskell.rs`, using the `tree-sitter-elm` crate. Version 5.9.4 was published in July 2026. Its compatibility with qartez's `tree-sitter` 0.26.8 has not been checked. If it does not build, vendor the grammar. The module needs these facts:
  - module and exposing lists;
  - imports with `as` and `exposing`;
  - top-level functions with type annotations;
  - custom types and constructors, type aliases and ports;
  - qualified references (`List.map`, `V.Value`) resolved through the import table.
- All other languages keep their present modules. The parser version is part of the blob-facts key, so a parser change re-parses only that language.

## 6. Failure behaviour

- **The daemon is down and cannot start.** The shim says so in its result (`state: UNAVAILABLE`, as the qartez skill already defines). It does not answer from a private index. Agents fall back to `rg` and read, as they do now.
- **Store corruption.** The daemon rebuilds the affected repository from git. Blob facts are derived data and are never the only copy of anything.
- **A build is too slow for a request.** The request answers from what is ready and says `building`. It never blocks for more than a bounded time. The bound is the builder's call, about the 30 s `RepoLock` deadline at most.
- **Two clients write at once.** All writes go through the single writer in order, so "database is locked" cannot happen between clients.

## 7. Hosts and cloud (stretch)

The parts below reuse Flight Deck's hosting layer: `HostKit`, `HostDaemon` and `HostDaemonLinux`, TLS-PSK WebSocket links with SPAKE2 pairing, `ChannelMux` framed channels, delegated execution through the host's `Workspace` (git object store plus checkouts, with idle eviction), and `flightdeck infra up` (OpenTofu, AWS and GCP, auto-pairing, Tailscale, the cost ledger, the Reaper). See `docs/ARCHITECTURE.md` §Hosts (line 166), §Delegated execution (315) and §Cloud infra hosts (545).

1. **Each host runs its own daemon**, bundled with its host daemon. A host's agents use it exactly as agents on the Mac do.
2. **Delegated checkouts are views.** When `flightdeck run --on <host>` pushes a worktree snapshot, the host's `Workspace` checkout becomes a view, and the host daemon indexes it.
3. **Blob facts travel.** Facts are keyed by blob id and parser version, so they are valid on any machine with the same parser version. A new `index` channel on the existing link lets a daemon ask a peer for the facts of the blobs it is missing before it parses them. A cloud host made by `infra up` can be seeded from the Mac this way and be ready at once.
4. **Remote queries.** A query can name a view on a paired host (`host:m3 path:/…`). The local daemon forwards it over the link. This covers an agent on the Mac that refers to a checkout that exists only on m3.
5. **Eviction follows the host.** When the host's `Workspace` evicts an idle checkout, the daemon drops that view.

None of this is needed for the minimum. The minimum is §§4–6 on one machine.

## 8. Rollout

1. **Interim, with no new code** (can start now, in parallel):
   - Tessera briefs tell subagents to use `qartez --root <their worktree> …` through Bash.
   - Tessera controllers start in `tessera/` instead of `formula-editor/`.
   - Run `qartez_maintenance` incremental vacuum on `formula-editor/.qartez/index.db` to return about 28 GB.
2. **Upstream-sized fixes on the fork.** Each can also go upstream as a PR:
   - Elm language module;
   - accept absolute paths under a registered root (about 20 lines plus tests);
   - `add_root` and `workspace add` take `RepoLock` and open their transaction so it waits for the lock (about 30 lines).
3. **The daemon**, its store (§4.4) and the shim, at qartez's tool surface. Every agent config switches from the per-session server to the shim. The old per-root `.qartez/` databases are deleted after the switch.
4. **Linked views** (§5.3) and mutators scoped to views (§5.5).
5. **Flight Deck integration:** status in the app, the daemon bundled in the host daemons. Then the stretch items of §7, in their numbered order.

Steps 1 and 2 pay off before the daemon exists. Step 3 is where requirements 1–4 and 7–9 are met.

## 9. Success criteria

Measure each one on the real machine with the real Tessera repository, not on fixtures:

- `git worktree add` on an indexed commit, then `qartez find <symbol>` from inside it: the answer comes back in under 1 s, with no registration call.
- A cold index of tessera master is no slower than the 4.0 s CLI baseline (§3) at a similar load.
- A second worktree on the same commit parses **zero** blobs.
- With every Tessera worktree known, the store is smaller than one master index plus the sum of the overlays, plus a stated margin. Compare: 32.6 GB today for one 1,583-file root.
- `find traverseStep` and `find checkPartial` return their Elm definitions.
- From `formula-editor`, `qartez_find Expression.Node.toString` returns the definition in `tessera/designer/src`, and `qartez_refs Expression.Node.identifierToString` includes `src/ExprViewer.elm`. (The first draft used `refs` on `toString`, but `ExprViewer.elm` never calls `toString`, as checked on 2026-11-01.)
- `qartez_read /absolute/path/in/another/worktree.ex` works.
- Read-your-writes: an `Edit` immediately followed by `qartez_find` of a new symbol finds it, in 100 of 100 runs. The test counts results and does not use timing.
- 30 concurrent clients doing mixed reads, writes and builds produce no "database is locked" or other lock errors.
- A mutator run from a worktree changes only that worktree. `git -C <main checkout> status` stays clean.
- With the app quit, a terminal agent and a headless Codex run can both query.

## 10. Non-goals and anti-goals

**Non-goals:**
- Replacing `rg` for plain-text search over non-code files.
- A hosted, multi-user index service. This is per machine and per user, plus paired hosts.
- New analysis tools. The retrofit keeps qartez's set.

**Anti-goals.** Any of these makes the work a failure, even if it runs:
- An answer from the wrong checkout, or an edit written to the wrong checkout, with no label saying so.
- An agent that has to register, configure or warm anything before its first query works.
- An index that depends on the Flight Deck app being open.
- A store that grows without bound as worktrees come and go.

## 11. Left to the builder

- The names of the daemon, socket, store directory and protocol.
- The wire protocol between the shim and the daemon.
- One SQLite file or one per repository. The schema details of the three layers.
- How the resolver re-resolves an overlay (which dependents to recompute) and how PageRank is kept for overlays. Re-using the base ranks is acceptable if it is documented.
- The bound on how long a request waits for a build. The inactivity window N for watches.
- How far each manifest type in §5.3 is supported in the first cut, beyond `elm.json`.
- Fork mechanics: a long-lived fork, or upstream PRs plus a thin layer.

## 11a. Build order (New Index session)

Names: the crate is `Packages/FlightIndex`, and its binary is `fdindex`. `fdindex daemon` runs the server. `fdindex mcp` is the stdio shim. `fdindex <verb>` is the query CLI. `flightdeck index …` passes its arguments through to `fdindex`. The `qartez` alias is `fdindex` started under that name. It is installed only at switch-over, so running sessions keep the old qartez until then.

1. **Engine core:** git identity (repository, worktree, view), blob-keyed store, tree-sitter parsing (Elm, Rust, TypeScript/JavaScript, Elixir, Swift, Python), import resolution, and the base graph.
2. **Daemon and protocol:** Unix socket, single writer, reader pool, auto-build with requested paths first, view labels on every result.
3. **Read-only tools:** map, find, grep, read, outline, deps, stats, impact, refs, calls. They accept absolute paths and paths relative to the caller's cwd.
4. **Clients:** the MCP shim, the CLI verbs, the `flightdeck index` subcommand, and launchd install/start/stop/status.
5. **Freshness:** the fs and ref watchers, read-your-writes, and garbage collection plus vacuum.
6. **Mutators** scoped to the view.
7. **Links:** `elm.json` first.
8. **Measure §9 on the real Tessera repository, then switch over.** Switch-over means MCP configs, the `qartez` alias, skills and hooks.

## 12. Questions answered in the New Index session

The maintainer answered all three on 2026-11-01. The answers are requirements 13–15 in §2. Requirement 12 also overrides §4.2 and §11 on command names: the CLI is `flightdeck index`, with `qartez` as an alias. The original questions follow.

1. **Linked-view targets.** `../tessera` names the main checkout. If an `formula-editor` worktree should pair with a particular `tessera` worktree, something has to say which. This is probably a Flight Control project setting. Confirm with the maintainer before building anything beyond the literal path.
2. **Codex intakes.** Should Flight Control intakes get the MCP shim, given that they disable `config.toml` MCP servers on purpose?
3. **Fork or upstream.** Should the daemon live in the Flight Deck repo (as `Sources/IndexService` or a Rust crate next to `HostDaemonLinux`) or in a qartez fork?
