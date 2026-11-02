# fdindex relevance evaluation harness

The harness measures whether `map`, `find` and `grep` (and any ranking variant) put the code that a change really touched near the top. It is the "evaluation harness" of [the code index research report](../research/reports/Code%20index%20research%20leads.md). Code: [`Packages/FlightIndex/src/eval.rs`](../../../Packages/FlightIndex/src/eval.rs) behind the `eval` cargo feature, and the CLI [`examples/eval.rs`](../../../Packages/FlightIndex/examples/eval.rs). The shipped `fdindex` binary does not contain it.

## Tasks
- **Source.** The newest non-merge commits of a rev (`--skip N` holds out the newest N eligible commits).
- **Filter.** The commit has exactly one parent, changes at most 25 files, and modifies at least 1 and at most 12 indexable files. Docs-only and lockfile-only commits fall out, because they modify no indexable file.
- **Task text.** The commit subject. `--message full` adds the body. Bodies in these repos often name the exact symbols, so the subject is the default to limit leakage.
- **Gold files.** The indexable files the commit modified (`M`, or the old path of a rename), that exist in the parent's index. Added files are not gold: they are not in the parent tree.
- **Gold symbols.** Function-like symbols (function, method, constructor, macro, port) in the parent tree that overlap the old side of a `git diff -U0` hunk. A pure insertion counts against the symbol that encloses it.
- **Cache.** The mined tasks are saved to `<out>/tasks-<repo>-<head>-<n>-<skip>.json` and reused.

## Index
Each task is answered from its parent commit's tree, indexed directly from git's object store: the view's listing is `git ls-tree <parent>`, blobs come from `git cat-file`, and nothing is checked out. The harness runs the engine in process with one store (`--store`). The store is blob-keyed, so each distinct blob is parsed once across all tasks and all later runs. Only the graph is rebuilt per parent commit. The harness runs no git command that writes, so a read-only repository is safe.

## Strategies
A strategy is `Fn(&Probe, &Task) -> Option<Ranking>`. `Probe` holds the parent's `ViewGraph` and runs the real tool code (`Probe::tool`, through `tools::run`) with an unlimited token budget. `Probe::ranking_from` reads the locations back out of the tool's text, so the score is for the output that an agent sees. `None` means the strategy does not apply to the task.

| name | what it does |
|---|---|
| `map` | `map top_n=20` for files, `map by=symbols top_n=20` for symbols. No seed. |
| `map_terms` | `map` with `boost_terms` = the task's terms, in lowercase. |
| `map_open` | `map` with `boost_files` = the first gold file (the simulated open file). It applies only to tasks with 2 or more gold files. The seed file is removed from the ranking and from the gold set. Since `map` personalizes on `boost_files`, this scores the shipped personalized PageRank. |
| `find` | `find name=<term>` per term, merged round-robin. |
| `grep` | `grep query=<term>` (prefix) per term, merged round-robin. |
| `bm25` | The graph's word index (`src/words.rs`, the ranking `grep` gives a sentence) queried directly: BM25F (k1 1.2, b 0.75 per field) over one document per symbol except impls and fields, with fields for the symbol's name, its parent's name, and its file path plus Elm module, all split on camelCase, snake_case and separators and lightly stemmed. Files in first-mention order of the best 200 symbols. |
| `grep_words` | `grep query=<whole task text> rank=true limit=200`: the same ranking through the tool's text, as an agent sees it. |
| `ppr_open_rev{0,1,5,20}` | Personalized PageRank (`graph/ppr.rs`) called directly, seeded at the first gold file, reverse-edge weight 0/1/5/20, every file ranked (tests included). `rev20` is what a seeded `map` ships; `rev0` is Aider's forward-only walk. Seeded tasks only. |
| `nbr_open` | Control: the seed's direct imports and importers by global rank, then the rest by global rank. What personalized PageRank must beat to earn its cost. |
| `bm25_open` | `bm25` on the seeded subset, the seed excluded, so it compares with the cells below. |
| `bm25_map_open`, `bm25_nbr_open` | Reciprocal-rank fusion (k = 60) of `bm25`'s files with the seeded `map`'s, or with `nbr_open`'s. Symbols stay `bm25`'s. |

**Terms** are the identifier-shaped words of the task text: 3 or more characters, not stopwords, de-duplicated without regard to case, at most 12.

## Metrics
File@1/5/10 and Function@5/10 for each task: the fraction of the gold set in the top k, divided by `min(k, |gold|)`, so a perfect ranking scores 100. The table gives the means. `tasks` counts the tasks that the strategy answered. `ftasks` counts those with at least 1 gold symbol, which are the only tasks that Function@k uses. `ms/task` is the strategy's own time per task.

## Run it
```
cd Packages/FlightIndex
cargo build --release --features eval --example eval
./target/release/examples/eval \
  --repo tessera=/Users/me/Projects/Tessera/tessera@master \
  --repo fd=/Users/me/Projects/flight-deck@master \
  --tasks 200 --store <scratch>/store --out <scratch>/out --label baseline
```
`--gate [REPO:]STRATEGY=MIN` fails the run (exit 1) when a strategy's File@10 is under MIN percent, or it scored no task. The seeded map's regression gate is `--gate tessera:map_open=20 --gate fd:map_open=40` (measured 32.2 and 57.2 at tessera@81f973be69fb and fd@9c49d8260c1d).

The output files are `<out>/<label>-summary.json` (repo → strategy → means) and `<out>/<label>-tasks.jsonl` (one row per task and strategy: gold files, top 10 files, scores).

## Score a variant without editing the harness
1. **Behind a tool argument.** Add the variant to the tool behind a new argument, such as `map`'s `ppr: true`. Then run `--only map_terms --args 'map_terms={"ppr":true}' --label ppr --compare <out>/baseline-summary.json`. `--args` merges the JSON into every tool call that the strategy makes. `--compare` prints each score with its delta from the earlier summary.
2. **As a function.** Write `examples/eval_<name>.rs` with `required-features = ["eval"]`. It calls `flightindex::eval::main_with(vec![("<name>".into(), Arc::new(|p, t| { … Some(ranking) }))])`. The new strategy runs next to the built-ins, and the same flags apply.

`examples/eval_grep_order.rs` does both: it scores each ordering of `grep`'s prefix rows (`src/tools/grep_order.rs`, chosen with the eval-only argument `order_eval`) as a strategy `grep_<policy>`, all over one graph per task.

Run the variant from your own worktree's build against the same `--store` and `--out`. The cached tasks and parsed blobs are reused, so the only cost of a rerun is the per-commit graph and the strategies.

## Scoring `near` with leak-free seeds
[`examples/eval_near.rs`](../../../Packages/FlightIndex/examples/eval_near.rs) scores `find`, `grep`, `refs` and `impact` with `near` off and on. A seed must be something an agent could hold at the start of the task, so no seed may come from the task's own diff. `Probe::tool_recent` hands the seeds to the tool as `Ctx::recent`, the service's default seed set, so a cell scores the tool's default behaviour, not an explicit `near`.
- **`auth1`, `auth3`** (`eval::seeds::author_files`): the files touched by the same author's previous 1 or 3 non-merge commits among the parent's ancestors (looking back 200 commits), newest first. This stands in for "what the agent was just working on". Every task is answered; an author with no earlier commit gets no seed, which is the `off` answer.
- **`open`**: the first gold file, on tasks with 2 or more gold files, left out of the ranking and the gold set. `openoff` is the same task set and exclusion with no seed.
- **`impact`** asks about the first gold file (2+ gold files, that file excluded), with co-change from the parent's history. `impact_*` reads the whole main text, `impactrad_*` only the `Direct importers` and `Transitive blast radius` lists, and `impact_{auth3,open}x` pass the seeds as an explicit `near`.

The results and the per-tool defaults they set are in the tool contract, under "near". Compare cells pairwise per task (each `on` cell against its `off` cell on the same commits) from `<label>-tasks.jsonl`; the means alone hide how many tasks moved.

## Known limits (first version)
- `map` skips test files unless `all_files` is set, so a gold test file is never found by `map`. The scores keep this, because it is the tool's real behaviour.
- `grep search_bodies` and `read` read from the worktree on disk, which is not the parent tree. No built-in strategy uses them.
- `impact` is scored by `examples/eval_impact.rs` and `examples/eval_near.rs`, not by a built-in strategy.
- Tasks run one after another. Each graph takes 0.3 s (flight-deck) to about 1 s (tessera) at load 10–16.
