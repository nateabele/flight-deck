# qartez skill, draft for the fdindex switch-over

These files overlay `~/.claude/skills/qartez/` and `~/.claude-radify/skills/qartez/` when
`fdindex switchover --apply` runs (the old skill directory is backed up first; files not listed
here, such as the `doctrine-*.md` references, are left as they are). They are embedded in the
`fdindex` binary at build time, so editing them means rebuilding.

What changed from the qartez-era skill, and why:

- **No `.qartez/status.json`.** The daemon is machine-wide, so there is no per-project status file
  (it would litter every worktree and go stale). Every result carries its own state: the `view:`
  header line (`index: building, N of M files` while a view is being built) and, for a refusal,
  `state: BUILDING | UNAVAILABLE | BAD_REQUEST | VERSION_MISMATCH | ERROR`. `fdindex status`
  describes the daemon.
- **Tool tiers are gone.** There is no `qartez_tools` and nothing to unlock. The first cut is the
  ten read tools and seven mutators; the analysis tier does not exist yet and the skill says so.
- **Absolute paths and worktrees are first-class.** Any path resolves to the view that holds it.
  The old advice to start in the project root, register roots, and avoid worktrees is withdrawn.
- **Mutators preview by default** (`apply=true` writes) and write only into one view.
- **The guard** words, thresholds, TTL and the `qartez_impact` ack are as before; it now also
  allows the call (and says so on stderr) when the index is not available.
