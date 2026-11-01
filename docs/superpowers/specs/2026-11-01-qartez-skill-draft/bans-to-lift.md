# Bans on quillmap/qartez mutators in worktrees, to lift after the switch-over

Found in the main checkout (`/Users/me/Projects/flight-deck`, master) on 2026-11-01. Listed only; nothing there was edited. After the switch, mutators write only into the view that holds the file they name, so these rules are obsolete (a plain `Edit` still works). Line numbers are the main checkout's.

## docs/AGENT-OPERATIONS.md

- line 549: **quillmap mutators are unsafe in a worktree** — they report success while writing to the main
  (the sentence continues on line 550: "Use the built-in `Edit` there.")

## docs/superpowers/plans/

- 2026-09-29-flight-control-mobile-steer.md line 24: - **Work in a worktree** off current master (symlink `vendor/{boringssl,ghostty,fd-abduco}-artifacts`; `xcodegen generate`); commit by path; empty `git diff --cached --stat -- vendor`; built-i
- 2026-08-30-display-drawable-and-respawn.md line 19: - In a worktree use ordinary file edit tools, NOT `quillmap_*` mutators; there they report success while writing to the main checkout.
- 2026-09-24-flightdeck-cli.md line 28: - Use built-in `Edit`/`Write` inside the worktree. **Never quillmap mutators**: in a worktree they
- 2026-09-27-tab-history-and-shortcut-overlay.md line 896: Check `ls /Users/me/Projects/flight-deck/vendor/` for the exact artifact directory names first. Use built-in Edit (not quillmap mutators — they write to the main checkout from a worktree
- 2026-09-24-flywheel-observe.md line 27: - **Worktree hygiene:** built-in `Edit`/`Write` only (never quillmap mutators here); git ops via a `bash <script>.sh` in the scratchpad (the git-guard blocks `-C`/compound/subshell); this checkout is sha
- 2026-10-04-flight-control-l3-u-usage-rollover.md line 79:   first build; never commit them. In a worktree use built-in `Edit`, not the quillmap mutators
- 2026-09-27-flywheel-intake-rounds.md line 89:   - Never use quillmap mutators.
- 2026-09-01-display-wake-followups.md line 17: - Built-in Read/Edit/Write ONLY — quillmap mutators silently write to the parent checkout from a
- 2026-08-27-background-work-as-decoration.md line 16: - **In a worktree, use the built-in `Edit`/`Write` tools, never the quillmap mutators** — in a worktree they report success while writing to the main checkout.
- 2026-09-13-reopen-status-badge.md line 17: - **Do not use quillmap mutators to edit source in this checkout if execution happens in a git worktree** — in a worktree they silently write to the main checkout. Use built-in `Read`+`Edit` for edits
- 2026-10-04-flight-control-l3-s-swarm.md line 83:   worktree use the built-in `Edit`, never the quillmap mutators (they write to the main checkout).
- 2026-08-31-display-wake.md line 16: - **Use built-in `Read`/`Edit`/`Write` only.** quillmap structural mutators silently write to the parent checkout from inside a worktree. Verify every edit landed with `git diff --stat`.
- 2026-08-29-surface-failure-and-respawn.md line 19: - If working in a worktree, use ordinary file edit tools — NOT `quillmap_*` mutators; in a worktree they report success while writing to the main checkout.
- 2026-09-29-flight-control-mobile-watch.md line 25: - **Shared checkout.** Work in a worktree (`superpowers:using-git-worktrees`); symlink `vendor/{boringssl,ghostty,fd-abduco}-artifacts` from the main checkout before building. Commit only your
- 2026-09-29-flight-control-coverage.md line 21: - **Use the built-in Edit/Write in the worktree, never the quillmap mutators.** They report success while writing to the main checkout.
- 2026-10-04-flight-control-l3-i-capability-index.md line 54: - Work in a worktree (`superpowers:using-git-worktrees`). Symlink `vendor/ghostty-artifacts` and `vendor/boringssl-artifacts` into it before the first build; never commit those symlin
- 2026-09-18-flywheel-run-integration.md line 441: *Executed in a git worktree (per project worktree norms — symlink `vendor/*-artifacts` so it builds; use built-in `Edit`, not quillmap mutators, in the worktree); the spec + this plan commit on 
- 2026-09-26-flywheel-intake-phase1-3.md line 53:   - Never use quillmap mutators in a worktree.
