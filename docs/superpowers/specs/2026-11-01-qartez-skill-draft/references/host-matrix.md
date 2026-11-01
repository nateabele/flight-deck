# Host Matrix

Where the guard and the index tools run.

| Behavior | Claude Code hook (`fdindex guard`) | Gemini hook (`fdindex guard`) | Codex (CLI from Bash) |
|---|---|---|---|
| Deny `Glob`/`Grep` in an indexed project | Yes | Yes (`glob`, `grep_search`) | n/a (no hook) |
| Load-bearing edit acknowledgement | Yes (`Edit`, `Write`, `MultiEdit`) | Yes (`replace`, `write_file`) | n/a |
| `QARTEZ_GUARD_DISABLE` and `QARTEZ_GUARD_*` | Yes | Yes | n/a |
| Allows the call when the index is unavailable | Yes, with a stderr note | Yes | n/a |
| Index tools | MCP server `qartez` (`fdindex mcp`) | MCP | `qartez <tool>` / `fdindex <tool>` |

The guard does not deny `Read` of source files (the installed qartez-guard never did, whatever its
older docs said), and there is no `INDEX_NOT_READY` denial: an index that is not ready allows the
call and says so.

## Delegation compatibility

| Path | Status | Notes |
|---|---|---|
| Claude direct session | Supported | PreToolUse + SessionStart hooks (`fdindex guard`, `fdindex session-start`) |
| Delegated Claude/Codex session | Supported | the same daemon answers every session; check the `view:` line for your worktree |
| Codex intakes with MCP disabled | Supported | CLI from Bash |
| Paired hosts | Not yet | each host runs its own daemon; remote queries come later |

## Remediation notes

- Keep the guard's denial wording stable: agents are trained on it.
- Keep `state: UNAVAILABLE` the single signal for "use rg".
