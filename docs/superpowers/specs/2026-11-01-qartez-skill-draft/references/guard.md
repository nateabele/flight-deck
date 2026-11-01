# Modification Guard Reference

## Purpose

`fdindex guard` is the PreToolUse hook. It sends Glob and Grep in an indexed project to the index
tools, and requires a risk acknowledgement before an edit of a load-bearing file.

## Denials

The hook answers on stdout with a `hookSpecificOutput` object whose `permissionDecisionReason` is
plain text (there is no embedded JSON payload to parse):

```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"STOP: `src/server/mod.rs` is load-bearing (PageRank 0.1200 >= 0.0500, blast radius 34 >= 10). Call `qartez_impact` with file_path=\"src/server/mod.rs\" FIRST to review direct and transitive importers, then retry the edit. Opt out for this project: `QARTEZ_GUARD_DISABLE=1`. Hot symbols in this file: serve (pr=0.210), route (pr=0.101)."}}
```

1. **Glob / Grep in a project whose index is ready**: `STOP: qartez MCP is available. Use qartez_map ...`
   (Glob, and Gemini's `grep_search`) or `... Use qartez_grep ...` (Grep). Use the named tool, or `rg`
   through Bash for non-code text.
2. **Load-bearing edit** (`Edit`, `Write`, `MultiEdit`; Gemini's `replace`, `write_file`): the file's
   PageRank is at least `QARTEZ_GUARD_PAGERANK_MIN` or its blast radius (files that transitively
   import it, in its own view) is at least `QARTEZ_GUARD_BLAST_MIN`, and no acknowledgement is
   fresh. Call `qartez_impact` with the file, then retry.

A file the index does not know (a new file, a README, an unsupported language) is never guarded.

## Acknowledgements

`qartez_impact` writes one every time it runs: `<worktree>/.qartez/acks/<fnv1a64(relative path)>`,
content `<unix seconds>\n<relative path>\n`; its age is the file's mtime and it lasts
`QARTEZ_GUARD_ACK_TTL_SECS` (600). It belongs to that file in that worktree: acknowledging a file in
one worktree does not unlock the same path in another.

## When the index is not available

The guard never blocks an agent because the index is down. If the daemon is not running or does not
answer, or the project's view is still being built, the call is allowed and a line on stderr says
why (`fdindex guard: the index daemon is not running (...); allowing Edit`). Treat that as the
`UNAVAILABLE` signal: use rg and `Read`.

## Recovery

1. Read the `permissionDecisionReason`.
2. Routing denial: use the tool it names.
3. Load-bearing denial: call `qartez_impact` for the file, then retry the edit.
4. Mutators (`qartez_replace_symbol`, `qartez_rename`, ...) are not subject to the gate.

## Environment variables and flags

`--pagerank-min`, `--blast-min`, `--ack-ttl-secs` and the `QARTEZ_GUARD_*` variables in
`runtime-contract.md`. `--db` and `--project-root` are accepted: `--db` is ignored, `--project-root`
only stands in for a missing `cwd`.
