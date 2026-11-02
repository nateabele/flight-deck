# Agent-level A/B: fdindex vs the old qartez

Measured, not inferred: 240 headless Claude Code runs on 60 mined tasks, 2 reps per arm, $39.16 of the $60 cap (plus $1.48 for a 4-run pilot). The method is in [the eval harness spec](../../specs/2026-11-01-index-eval-harness.md#agent-level-ab). The runner is [`scripts/agent_ab.py`](../../../Packages/FlightIndex/scripts/agent_ab.py).

## Setup
- **Tasks.** 30 tessera (at master 81f973be6) and 30 flight-deck (at master 35643318), sampled with seed 20261101 from each repository's newest 100 eligible commits. The task text is the commit subject only. Gold files and gold symbols are the harness's.
- **Agent.** `claude -p --model sonnet --strict-mcp-config --setting-sources "" --no-session-persistence --tools Read`. Only the one MCP server's tools and Read are allowed. The mutators are disallowed. The agent answers in a fenced JSON block of up to 10 files and 15 function names. Every one of the 240 runs answered, and every MCP server connected.
- **Arm A.** `qartez.orig` (the old qartez, black box), with a scratch `--db-path` per worktree and a scratch HOME. It exposes 36 tools once the mutators are removed.
- **Arm B.** The `fdindex mcp` shim (this branch's master build) on a scratch daemon, store and socket. It exposes 12 tools once the mutators are removed.
- **Fairness.** Both arms indexed every worktree before any run, so neither arm's wall time includes a cold build. The runs went 4 at a time, with arms and tasks shuffled together. Load average during the runs: 77 to 560 (1-minute). The mean at run start was 128 for A and 122 for B.

## Results
95% bootstrap intervals over tasks. Reps are averaged per task first. B − A is the paired difference.

| metric | A: old qartez | B: fdindex | B − A (paired) |
|---|---|---|---|
| File top-1 (%) | 84.2 [75.8, 91.7] | 85.8 [77.5, 93.3] | +1.7 [−5.8, 9.2] |
| File recall@5 (%) | 69.3 [61.7, 76.6] | 68.7 [62.5, 74.9] | −0.6 [−6.6, 5.5] |
| Function recall (%) | 65.6 [57.2, 73.8] | 69.4 [61.4, 77.8] | +3.8 [−1.7, 9.6] |
| Tool calls | 13.8 [12.0, 15.7] | 11.7 [10.1, 13.4] | **−2.1 [−3.9, −0.5]** |
| Input tokens (k) | 438 [381, 503] | 256 [202, 325] | **−182 [−253, −114]** |
| of which cache writes (k) | 22.6 [19.7, 25.8] | 30.6 [26.4, 35.2] | **+8.0 [3.5, 12.5]** |
| of which cache reads (k) | 415 [361, 478] | 225 [175, 289] | **−190 [−257, −126]** |
| Output tokens (k) | 2.53 [2.25, 2.84] | 2.39 [2.10, 2.73] | −0.14 [−0.46, 0.17] |
| Wall time (s) | 25 [22, 29] | 27 [24, 30] | +1 [−2, 5] |
| $ per task | 0.157 [0.138, 0.179] | 0.169 [0.145, 0.197] | +0.012 [−0.015, 0.038] |

**Accuracy is a tie.** No accuracy metric moves outside its interval. B did better on 17 tasks' file recall@5, A on 15, and 28 tied. Run-to-run noise is about as large as the arms' difference: the mean absolute change in a task's file recall@5 between reps is 7.9 points for A and 13.3 for B.

**B needs fewer calls and less context.** B made 15% fewer tool calls and read 42% fewer input tokens. Most of the token saving is the tool list itself. The median first-turn prompt is 36.3k tokens in A and 11.9k in B, so A's 36 tool schemas cost about 24k more tokens on every turn. A also ran more turns (14.8 against 12.6 on average).

**Cost is a tie anyway.** B's tool results are larger: 56k characters per run against A's 45k. They are written to the cache, at the higher cache-write price (+8k tokens per task). A's saving is in cheap cache reads. So the $/task difference is +1.2 cents, with an interval that spans zero.

## Where either arm wins (file recall@5, paired)

| category | n | A | B | B − A |
|---|---|---|---|---|
| Elm gold files | 7 | 45 | 68 | **+23 [1, 47]** |
| 4+ gold files | 26 | 55 | 63 | **+8 [1, 15]** |
| Elixir gold files | 15 | 78 | 67 | −11 [−25, 2] |
| 2–3 gold files | 23 | 75 | 67 | −8 [−19, 3] |
| 1 gold file | 11 | 91 | 86 | −5 [−18, 9] |
| Swift | 14 | 68 | 72 | +3 [−3, 13] |
| Rust | 17 | 70 | 68 | −2 [−10, 4] |
| flight-deck | 30 | 68 | 70 | +2 [−2, 7] |
| tessera | 30 | 70 | 67 | −3 [−15, 8] |

- **Elm (B wins).** The old qartez indexes no Elm. Its `stats` on a tessera worktree lists elixir, typescript, javascript, rust and others, but no Elm. Arm A had to find Elm files with Read alone: it made 23 calls per Elm task against B's 9, at $0.261 against $0.110.
- **Many-file changes (B wins).** With 4 or more gold files, B finds more of them in its top 5. B also calls `refs` 4 times as often as A (38 calls against 9), and `find` 3 times as often (30 against 10).
- **Elixir and 2–3-file changes (A leads, not significant).** The per-task Elixir losses are spread out: 3 tasks where B halved A's recall, and 4 where B did better. This is a lead to follow, not a finding. A larger sample, or a harness strategy that scores `grep` on Elixir module names, would settle it.

## What this says about the tool organization
On the same tasks, a 12-tool surface answered as well as a 36-tool one, with 24k fewer prompt tokens on every turn. The agents used few tools in either arm. `grep`, `read` and `outline` made up 93.5% of A's MCP calls and 91.2% of B's. A's other 33 tools got 95 of its 1,468 MCP calls between them: `map` 57, `find` 10, `refs` 9, `deps` 8, `calls` 5, `stats` 3, `context` 3. The other 26 were never called. This supports keeping the always-loaded surface small and putting the analysis tools behind one entry point (the `tools` sibling item), not in the default tool list.

## Not measured
- Edit tasks. Every run was read-only, and the mutators were disallowed in both arms.
- Arm A on Elm-heavy repositories other than tessera, and Python.
- Cold start. Both arms were pre-indexed. Pre-indexing took 20 to 54 s per worktree for qartez, at load 90 to 550. For fdindex it took 0.2 to 1.6 s, because the shared blob store reuses parsed blobs across worktrees.
