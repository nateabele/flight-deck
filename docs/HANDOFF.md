# Flight Deck — Session Handoff

**Date:** 2026-08-11 · **Branch:** `master` · **Tip:** `4684bf1` · **Status:** Multi-Session Foundation **and** Session Name Sync both merged to `master`; unit + smoke gates GREEN (66 unit tests, 4 UITests).

Start here if you're picking up Flight Deck fresh. This is the map; the linked docs have the detail.

> **▶ Agent Adapters (2026-08-19) — in progress, one decided step remaining.**
> Any tab can now run **claude or codex**. Claude's half is complete and unchanged; codex
> creates, resumes and renames, but its observation half (title sync, status, sub-agent
> counts, unread) is inert because codex's app-server notifications turn out to be scoped to
> the connection that made the change — and turns run in a separate `codex resume` process.
> The fix is decided (tail the rollout `.jsonl`) and not yet built.
> **Start at [HANDOFF-agent-adapters.md](HANDOFF-agent-adapters.md) §2 before touching codex.**

> **✅ Two phases are merged to `master` and green.**
>
> **Multi-Session Foundation** — repo-grouped session sidebar with create/switch/close, a
> single `SessionStore` as source of truth, and a process-wide `GhosttyApp`. One macOS gotcha
> was resolved along the way: under XCUITest's raw-exec launch the initial window is gated
> behind the window-restoration handshake that only LaunchServices completes, so the tests
> pass `-ApplePersistenceIgnoreState YES` to match real-user launch semantics. Full
> postmortem: [done/HANDOFF-smoke-gate.md](done/HANDOFF-smoke-gate.md).
> - **Plan:** [superpowers/plans/2026-08-09-multi-session-foundation.md](superpowers/plans/2026-08-09-multi-session-foundation.md) · **Spec:** [superpowers/specs/2026-08-08-multi-session-foundation-design.md](superpowers/specs/2026-08-08-multi-session-foundation-design.md)
>
> **Session Name Sync** — session names stay in sync with the `claude` running in each
> terminal, in both directions, and sessions now survive relaunch (each terminal reattaches to
> its own Claude conversation via `--resume`). Rename is reachable three ways: double-click,
> Return on the selected row (once the sidebar has focus — click the row you are already on),
> and the row's context menu. Double-click and Return both come from a passive event monitor
> that adds nothing to the row, because the original SwiftUI tap gesture blocked
> drag-to-reorder and an `NSViewRepresentable` made the row title unhittable; see the
> project-tabs section of [FOLLOWUPS.md](FOLLOWUPS.md).
> - **Plan:** [superpowers/plans/2026-08-10-session-name-sync.md](superpowers/plans/2026-08-10-session-name-sync.md) · **Spec:** [superpowers/specs/2026-08-10-session-name-sync-design.md](superpowers/specs/2026-08-10-session-name-sync-design.md)
>
> Also fixed: ⌘Q and any other menu shortcut were being swallowed by the terminal
> (`Sources/FlightDeck/MenuKeyEquivalents.swift`).

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
./scripts/build.sh                   # generate project + build "Flight Deck.app"
open "DerivedData/Build/Products/Debug/Flight Deck.app"   # a live terminal
```

Full details, prerequisites, and troubleshooting: **[BUILD.md](BUILD.md)**.

## How the code is laid out

The spine is `FlightDeckApp → RootWindow → TerminalPane → GhosttyApp → Ghostty.SurfaceView`. Flight Deck's own code is small; the terminal surface is adapt-copied from Ghostty and decoupled from its app shell. Component map and key files: **[ARCHITECTURE.md](ARCHITECTURE.md)**.

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

- **DONE (merged to `master`):** the **Multi-Session Foundation** — singleton `GhosttyApp` owned
  by `AppDelegate` (so a deferred `ghostty_surface_free` can never race a freed app), the
  `Session`/`Repo` model, `@MainActor SessionStore` as single source of truth, and the
  repo→session sidebar. Followed by **Session Name Sync** — bidirectional naming with `claude`
  plus session persistence/restore. Both have their plan and spec linked at the top of this file.
- **NOW — the design's phase-1 remainder**, each its own spec→plan→build: the **harness adapter** (Claude Code hooks + `stream-json`, opencode's server/events), the **shared code index** (qartez is a ready substrate, MCP-exposed), the **context engine** (auto-assembly + memory + inspectable compaction), and the **mission-control sidebar** live-status columns (needs the adapter's event stream). See [design spec §9](superpowers/specs/2026-07-09-flight-deck-design.md).
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
