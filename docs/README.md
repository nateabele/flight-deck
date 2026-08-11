# Flight Deck — Docs

Start with **[HANDOFF.md](HANDOFF.md)** — the entry point for picking this project up.

## Index

| Doc | What it's for |
|---|---|
| **[HANDOFF.md](HANDOFF.md)** | Session handoff: current state, quickstart, decisions, what's next. Read first. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | The code as built — the spine, the `GhosttyEmbed/` reuse boundary, linkage/build config, runtime model. |
| [BUILD.md](BUILD.md) | How to build, run, and test (from a fresh clone) + troubleshooting. |
| [TOOLING.md](TOOLING.md) | Toolchain versions and the Zig/macOS-SDK linker workaround (why the build is unusual). |
| [FOLLOWUPS.md](FOLLOWUPS.md) | Known limitations and prioritized next fixes, plus a resolved-items trail. Audited against the tree. |
| [done/](done) | Hand-off and postmortem docs whose work is finished. Kept for the reasoning trail; nothing here is live. |
| [superpowers/specs/2026-07-09-flight-deck-design.md](superpowers/specs/2026-07-09-flight-deck-design.md) | The design — the full vision, subsystems, and locked decisions (the *why*). |
| [superpowers/plans/2026-07-09-flight-deck-walking-skeleton.md](superpowers/plans/2026-07-09-flight-deck-walking-skeleton.md) | The step-by-step plan that was executed to build the skeleton. |

## Reading order by goal

- **"Get it running"** → HANDOFF quickstart → BUILD.
- **"Understand the code"** → ARCHITECTURE → the spec.
- **"Know what to build next"** → HANDOFF "What to do next" → FOLLOWUPS → spec §9.
- **"Why is the build weird?"** → TOOLING.

## Not in git

The task-by-task build record (progress ledger, per-task briefs, and reviewer reports) is on
disk under `.superpowers/sdd/` (git-ignored). It's the audit trail of how the skeleton was built.
