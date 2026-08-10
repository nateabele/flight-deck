# Flight Deck — Session Handoff

**Date:** 2026-08-10 · **Branch:** `multi-session-foundation` (off `master`) · **Tip:** `ffe4d58` · **Status:** Multi-Session Foundation COMPLETE (all 6 tasks implemented & reviewed) — smoke gate GREEN; branch ready to finish.

Start here if you're picking up Flight Deck fresh. This is the map; the linked docs have the detail.

> **✅ Multi-Session Foundation is done and green.**
> The plan is fully built and reviewed on branch `multi-session-foundation`, and the XCUITest smoke
> gate now passes (both UI tests). One subtle macOS gotcha was resolved along the way — under
> XCUITest's raw-exec launch the initial window is gated behind the window-restoration handshake that
> only LaunchServices completes; the tests now pass `-ApplePersistenceIgnoreState YES` to match
> real-user launch semantics. Full postmortem: [HANDOFF-smoke-gate.md](HANDOFF-smoke-gate.md).
> - **Plan (what was built):** [superpowers/plans/2026-08-09-multi-session-foundation.md](superpowers/plans/2026-08-09-multi-session-foundation.md) — 6 TDD tasks with full code, commands, interfaces.
> - **Design spec (the why):** [superpowers/specs/2026-08-08-multi-session-foundation-design.md](superpowers/specs/2026-08-08-multi-session-foundation-design.md).

---

## What Flight Deck is

An **orchestration-native macOS terminal**: a from-scratch app that reuses Ghostty for the terminal, will orchestrate external agent harnesses (Claude Code, opencode) behind an adapter, wrap them in a context engine you own and can inspect, and show every agent's live status in a nested `session → repo → project` sidebar.

Full vision and the locked design decisions: **[design spec](superpowers/specs/2026-07-09-flight-deck-design.md)**.

## Where things stand

The **walking skeleton is done**: the app renders a **live terminal running a real login shell**, drawing through a reused-Ghostty surface. Verified via screenshot (`nate@m5 ~ %` prompt), process tree (`FlightDeck → login → zsh`), and green unit + smoke tests.

That was deliberately the smallest self-contained slice that also retired the biggest unknown — *can we actually reuse Ghostty to render a terminal inside our own app?* Answer: **yes.** Everything else in the design (adapter, index, context engine, sidebar) is still ahead, each its own spec→plan→build cycle.

## Quickstart (this host)

```bash
cd ~/Projects/Protos-n-Tools/flight-deck
git submodule update --init          # fetch vendored Ghostty @ v1.3.1
./scripts/build-libghostty.sh        # build GhosttyKit.xcframework (~10 min first run)
./scripts/build.sh                   # generate project + build FlightDeck.app
open DerivedData/Build/Products/Debug/FlightDeck.app   # a live terminal
```

Full details, prerequisites, and troubleshooting: **[BUILD.md](BUILD.md)**.

## How the code is laid out

The spine is `FlightDeckApp → RootWindow → TerminalContainer → GhosttyApp → Ghostty.SurfaceView`. Flight Deck's own code is small; the terminal surface is adapt-copied from Ghostty and decoupled from its app shell. Component map and key files: **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## Key decisions already made (don't relitigate without reason)

From the [design spec](superpowers/specs/2026-07-09-flight-deck-design.md) and the two forced calls during the build:

- **macOS-native** (Swift + AppKit/SwiftUI + Metal), same stack as Ghostty's own app.
- **Orchestrate external harnesses** (Claude Code + opencode first) via a per-harness adapter; **interactive** drive mode (harness owns its context window; Flight Deck influences it via MCP tools / prompt injection / bootstrap files / an owned authoritative memory layer).
- **Reuse boundary = adapt-copy.** Ghostty's Swift `SurfaceView` is too coupled to its app shell to reuse by reference (it transitively needs ~82 app files). So its surface + input files are **copied into `Sources/FlightDeck/GhosttyEmbed/` as owned, editable, decoupled files** (~97% verbatim, provenance-marked), linking `GhosttyKit.xcframework`. See the spec's 2026-07-10 addendum.
- **Session = terminal + agent + optional worktree**; repos roll up to projects; layered context.

## The two blockers we hit (and how they're resolved)

Both are documented in **[TOOLING.md](TOOLING.md)**:

1. **Zig 0.15.2's linker is broken on the macOS 26.5 SDK** (upstream [zig#31658](https://codeberg.org/ziglang/zig/issues/31658); fixed only in Zig 0.16.0, which Ghostty rejects). Resolved **self-contained, no `sudo`**: `scripts/build-libghostty.sh` shims `xcrun` to build against the locally-present `MacOSX15.4.sdk`, which Zig 0.15.2 parses correctly. It fails fast with a clear error if that SDK is absent.
2. **Ghostty's `SurfaceView` isn't cleanly separable** → the adapt-copy decision above.

## What to do next

Immediate + phased next steps live in **[FOLLOWUPS.md](FOLLOWUPS.md)**. The short version:

- **NOW (planned & approved — just execute):** the **Multi-Session Foundation**. This is the design's
  phase-1 continuation *before* the harness adapter. It folds the teardown-lifetime (UAF) fix into
  building real multi-session support — an app-wide singleton `GhosttyApp` owned by an `AppDelegate`
  (so the deferred `ghostty_surface_free` can never race a freed app), a `Session`/`Repo` model, a
  `@MainActor SessionStore` as single source of truth, and a repo→session sidebar with
  create/switch/close where surfaces are Store-retained and re-parented on switch (only close frees).
  The full breakdown is in the
  **[plan](superpowers/plans/2026-08-09-multi-session-foundation.md)** (6 TDD tasks, ready to run
  subagent-driven); the rationale and scope in/out is in the
  **[design spec](superpowers/specs/2026-08-08-multi-session-foundation-design.md)**.
- **Then the design's phase-1 remainder**, each its own spec→plan→build: the **harness adapter** (Claude Code hooks + `stream-json`, opencode's server/events), the **shared code index** (qartez is a ready substrate, MCP-exposed), the **context engine** (auto-assembly + memory + inspectable compaction), and the **mission-control sidebar** live-status columns (needs the adapter's event stream). See [design spec §9](superpowers/specs/2026-07-09-flight-deck-design.md).
- **Known limitation:** CI / other-host builds are blocked on the upstream Zig fix (see TOOLING.md / FOLLOWUPS.md).

## How this was built (process record)

Built subagent-driven (a fresh implementer per task + a spec/quality review after each + a whole-branch review). The full task-by-task record — the progress ledger, per-task briefs, and reports — is on disk under `.superpowers/sdd/` (git-ignored). The executed plan is **[the walking-skeleton plan](superpowers/plans/2026-07-09-flight-deck-walking-skeleton.md)**.

## Doc index

See **[docs/README.md](README.md)** for the full index. In short:
- [ARCHITECTURE.md](ARCHITECTURE.md) — as-built code structure & reuse boundary
- [BUILD.md](BUILD.md) — build / run / test / troubleshoot
- [TOOLING.md](TOOLING.md) — toolchain versions + the SDK-shim workaround
- [FOLLOWUPS.md](FOLLOWUPS.md) — known limitations & prioritized next fixes
- [superpowers/specs/2026-07-09-flight-deck-design.md](superpowers/specs/2026-07-09-flight-deck-design.md) — the overall design (why)
- [superpowers/plans/2026-07-09-flight-deck-walking-skeleton.md](superpowers/plans/2026-07-09-flight-deck-walking-skeleton.md) — the executed walking-skeleton plan
- [superpowers/specs/2026-08-08-multi-session-foundation-design.md](superpowers/specs/2026-08-08-multi-session-foundation-design.md) — **next phase** design spec
- [superpowers/plans/2026-08-09-multi-session-foundation.md](superpowers/plans/2026-08-09-multi-session-foundation.md) — **next phase** implementation plan (ready to execute)
