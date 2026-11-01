# Proposal 15: `impact pending=true` measured

Proposal 15 of the top-20 report: list the call sites that the worktree's diff has not edited yet, for every symbol whose signature the diff changed. Shipped on branch `shared-index-q15`. The contract is in `2026-11-01-index-tool-contract.md` ("impact pending=true").

## Method

- The data is a throwaway worktree of tessera at `81f973be6`. The script is `2026-11-01-q15-eval-pending.py`; it is next to this file.
- There are 10 symbols: Rust 3, TypeScript 3, Elm 2, Elixir 2. Each symbol gets three synthetic refactors:
  - **arity**: Add a parameter to the definition. Update the first half of the call sites (sorted by path and line). The other half is the ground truth of the sites that need an edit.
  - **param rename**: Rename one parameter in the definition only. No call site needs an edit.
  - **function rename** (5 of the symbols): Rename the function and update half of the call sites.
- The ground truth is found with `rg` and a call regex for each symbol, then corrected by hand. Doc comments and test names are excluded. Unqualified calls in the defining file are included.
- The baseline is what an agent has today:
  - `refs <symbol> file_path=<def>`. The agent must already know which symbol changed.
  - `impact file_path=<def> include_tests=true`, which lists files.
- A daemon ran with `--no-watch` and a store in the scratchpad.
- The load average was 40 to 155 during the runs. The machine is shared.

## Results (arity, 93 sites need an edit in total)

| | sites found | rows that need no edit |
|---|---|---|
| `refs` (baseline) | 88 / 93 | 100 (mostly the sites that are already edited) |
| `impact` files (baseline) | 16 / 22 files | 170 files |
| pending, resolved references only | 88 / 93 | 8 |
| pending, with the text scan (shipped) | **93 / 93** | **8** |

- **Text scan.** The 5 sites that the resolved references miss are calls inside Rust `assert!`/`assert_eq!` arguments (`encode_frame`, 2 sites) and calls inside TypeScript template substitutions (`actionToString`, 3 sites). The parsers do not go into these. The text scan finds all 5. It adds no false positives in these cases.
- **False positives.** All 8 come from one cause: `refs` resolves a local variable `lit` in `anode.ts` to the function `lit`. That is an index bug, and it is outside this change.
- **Text scan false positives that the guards remove:**
  - 6 calls to a local `fn eval` wrapper in `evaluator/tests/join.rs`. A file that defines its own function with the same name is not scanned.
  - 4 `lit(…)` matches inside test-name strings.
- **Param rename.** pending lists 0 rows in all 10 cases. It reports "no signature changed". On the same refactor, `refs` lists 2 to 102 rows.
- **Function rename.** pending finds 23 of 23 sites, with 0 false positives.
- **Time.** One `impact --pending` CLI call takes 55 to 209 ms, at load averages of 39 to 44. This includes `git status`, one `git cat-file` for each changed file, and the process start.

## Limits

- The ground truth is synthetic. The edits are made on the line with the call, so the line diff sees them. The `CALL_WINDOW` of 2 following lines is not stressed by these refactors.
- A view that is linked to this one (another worktree) has no diff here. Its sites are always listed as pending.
- A removed symbol is followed only in this view, through the base graph.
- The relevance eval harness (`shared-index-eval`) scores `find`/`map` ranking. pending does not change that ranking, so the harness was not run.
