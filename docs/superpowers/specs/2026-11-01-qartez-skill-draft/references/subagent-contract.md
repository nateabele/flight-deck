# Subagent Contract

Delegated-session expectations for sessions that use the Flight Deck index.

## Delegation detection

Treat a session as delegated when any of the following apply:

- the prompt/session contains `<!-- OMO_INTERNAL_INITIATOR -->`
- the session was created via a task/delegate mechanism

## Entry protocol

1. Run one cheap index call (`qartez_stats`, or `qartez_map` with a small `top_n`). There is no
   status file to read.
2. A normal result: proceed index-first.
3. `index: building, N of M files` on the `view:` line: use `qartez_map` and `qartez_outline`, defer
   symbol-heavy queries, ask again shortly.
4. `state: UNAVAILABLE`: report it once to the parent, then continue with rg and `Read`.
5. Check the `view:` line names **your** worktree before you rely on, or write through, a result.

## Execution protocol

- Start with the index tools; do not lead with Glob/Grep on code.
- On a denial, read the `permissionDecisionReason` and use the tool it names.
- On a load-bearing-file denial, call `qartez_impact` for the file, then retry the edit.
- Mutators preview by default; repeat with `apply=true` after reading the diff.
- Do not mark a task complete on a denial alone.

## Parent-agent responsibilities

- Include the preamble below in delegated prompts.
- Parse and enforce the execution footer.
- Tell the subagent which worktree it owns; its results will say `view: <that worktree>`.

## Suggested delegated-task preamble

```text
INDEX ROUTING: use the qartez_* tools for all code work.
glob/ls/find -> qartez_map
grep/rg on code -> qartez_grep or qartez_find
read on source -> qartez_read or qartez_outline
Absolute paths are fine. Check the `view:` line names your worktree.
If a built-in tool is denied, use the tool the message names (load-bearing edit: qartez_impact first).
If a result says `state: UNAVAILABLE`, fall back to rg and Read and say so.
End with the QARTEZ_EXECUTION_REPORT footer.
```

## Execution footer template

```md
<!-- QARTEZ_EXECUTION_REPORT
State: <READY|BUILDING|UNAVAILABLE>
Tools_used: <comma-separated list>
Builtin_denials: <count by type or none>
Recovery_actions: <retried mappings or none>
Change_mode_used: <yes|no>
Risk_ack_issued: <yes, paths|no>
Residual_uncertainty: <text or none>
Missing_capability: <text or none>
-->
```
