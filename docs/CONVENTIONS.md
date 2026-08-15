# Flight Deck — Conventions

How code, comments, commits, and process work here. Match this; it is consistent across the
tree and deliberate.

---

## Comments explain *why*, and name the failure they prevent

This is the single most distinctive thing about the codebase. Comments are not restatements of
the code — they are the reasoning trail, usually written so the next reader doesn't re-derive a
decision or "clean up" something load-bearing. From `smoke.sh`:

> Delete ONLY the window-geometry keys. This script used to `defaults delete` the whole domain,
> which also destroyed `sessions.snapshot.v1` and `preferences.v1` — i.e. every real session,
> project and preference the user had, on every smoke run.

Write comments in that register: what breaks otherwise, what was tried, what was rejected. A
comment that only says *what* the line does is noise here; one that says *why it can't be the
obvious thing* is the point.

Corollary: when you change behavior, **audit stale comments repo-wide.** Several commits exist
purely to fix comments that outlived their code (`fix: correct stale explicit-project-lifetime
comments…`, `fix: widen the stale project-lifetime comment audit repo-wide`).

## Commit messages

Format: `<type>: <lowercase behavioral subject>` — `feat:`, `fix:`, `docs:`, `refactor:`, or a
bare `merge <branch>` for merges.

- The subject says **what changes for the user or the system**, in the imperative, not what code
  moved: `fix: stop the unread dot marking every session at launch`, not `fix: update
  SessionNotificationPolicy`. Subjects run long (70–90 chars is normal); clarity beats a 50-char rule.
- The body explains the mechanism, the evidence, and the alternatives rejected. Wrap at ~76.
  State when a finding was measured rather than reasoned ("Measured rather than inferred: …").
- Trailer on every commit:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```

## Tests

- TDD: write the failing test first and **confirm it fails against the broken code** before
  fixing. Reports routinely record this ("confirmed the new test fails without the guard (RED)
  and passes with it (GREEN)"). A test that would have passed against the bug is worthless — say
  so and aim it better.
- Keep logic pure and SwiftUI-free where it can be, so it is testable without instantiating a
  view: `SidebarReorder.apply`, `ClaudeFlagParser`/`Serializer`/`Merge`, `SessionReadPolicy`,
  `SessionNotificationPolicy`, `ProcessTree`, `ShellResolver`.
- Put seams behind protocols so tests can substitute: `SessionPersisting`, `TextInjecting`,
  `SurfaceProvider`, `Notifying`, `ProjectCloseConfirmer`. `SessionNotifier` is behind `Notifying`
  because `UNUserNotificationCenter.current()` **traps** outside a signed bundle and would take
  the whole test bundle down.
- Never weaken or delete an assertion to make a suite green. Fix the root cause, or say the
  test was wrong about the feature and replace it deliberately (with reasoning in the message).

## Swift / project constraints

- **`SWIFT_VERSION: "5.0"`** (Swift 5 mode, Swift 6.3 compiler). Required so the vendored
  Ghostty sources compile without strict-concurrency breakage. Don't "fix" the resulting
  actor-isolation inconsistencies into Swift 6 — that's a separate migration, tracked in
  [FOLLOWUPS.md](FOLLOWUPS.md).
- **Deployment target macOS 14.0.**
- The `.xcodeproj` is **generated** from `project.yml` by XcodeGen and is git-ignored. Edit
  `project.yml`; never hand-edit the project, and re-run `xcodegen generate` after changes.
- `Sources/FlightDeck/GhosttyEmbed/` is **adapt-copied Ghostty** (MIT, provenance-marked
  `// Adapted from ghostty v1.3.1: <path>`). Treat as vendored-ish: prefer re-pulling upstream
  over hand-editing, except for deliberate decoupling. See [ARCHITECTURE.md](ARCHITECTURE.md).
- Follow Apple HIG for UI work; prefer system semantic colors/symbols over hand-picked values.

## Workflow: spec → plan → subagent-driven build

Non-trivial work follows the superpowers cycle, and its artifacts are committed:

- Spec → `docs/superpowers/specs/YYYY-MM-DD-<slug>-design.md` (the *why* and the locked decisions)
- Plan → `docs/superpowers/plans/YYYY-MM-DD-<slug>.md` (the ordered tasks)
- Build → a fresh implementer subagent per task, each followed by a spec-compliance + quality
  review, then a whole-branch review before merge.
- The task-by-task ledger, briefs, and reviewer reports land under `.superpowers/sdd/`
  (**git-ignored** — audit trail, not history).

Feature work happens on a branch (`feat/<slug>`), merged to `master` with a `merge <branch>`
commit. Keep the tree clean: merge, then delete the branch and its worktree.

## Docs are part of the change

`docs/` is kept current, not archaeological:

- **[FOLLOWUPS.md](FOLLOWUPS.md)** — known limitations and next fixes. It is *audited against the
  tree*, with a date. Resolved items stay, marked FIXED, for the reasoning trail. Record
  deliberate non-fixes too, with the ruling, so nobody re-derives them.
- **[HANDOFF.md](HANDOFF.md)** — current state; the entry point for picking the project up.
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — as-built structure. Update it when the shape changes.
- `docs/done/` — finished handoffs/postmortems, kept for reasoning, nothing live.

If a change alters behavior described in a doc, update the doc **in the same commit or branch**.
