# Flight Deck — Design Spec

**Date:** 2026-07-09
**Status:** Approved design, pre-implementation
**Platform:** macOS-native (v1)

## 1. Concept

Flight Deck is a from-scratch macOS app: an **orchestration-native terminal** for running many coding agents across repos and projects. It embeds Ghostty's engine for real terminal fidelity, runs *external* agent harnesses (Claude Code, opencode) as observable workers behind a per-harness adapter, wraps them in a **context engine you own and can inspect**, and presents every agent's live status in one nested **mission-control sidebar**: session → repo/folder → project.

The bet: with frontier models converged, the value is not another agent — it's the *chrome* around any agent (fast terminal, owned context, live fleet visibility). Flight Deck owns that chrome and orchestrates the loops it doesn't own.

## 2. Core decisions (locked)

| Decision | Choice |
|---|---|
| App | From-scratch, **macOS-native**: Swift + AppKit/SwiftUI + **Metal**, linking **libghostty** (C API) |
| Agent execution | **Orchestrate external harnesses** (v1: Claude Code + opencode) via a per-harness **adapter** |
| Drive mode | **Interactive** — the harness owns its context window; Flight Deck influences it via four levers |
| Context engine | **Task-scoped auto-assembly + shared code index + persistent memory + inspectable compaction** (of Flight Deck's own layer) |
| Memory | **Auto-extracted, user-curated** (engine proposes, user approves/edits) |
| Session | **Terminal + agent + optional git worktree**; many per repo |
| Hierarchy | session → repo/folder → **project**; **layered** context inheritance |
| Project (v1) | **Grouping + shared context** (cross-repo agent orchestration deferred) |
| Sidebar | **Nested tree, inline status**; signals: attention state, run state + current action, context budget (cost optional) |
| MVP | Terminal + Claude Code adapter (observe **and** inject) + minimal index + nested sidebar |

## 3. Component architecture

Each unit has one purpose, a defined interface, and can be understood/tested independently.

| Unit | Purpose | Depends on | Owns |
|---|---|---|---|
| **Terminal Core** | Embed `libghostty`; Swift/Metal renderer; block model on OSC 133 semantic zones | libghostty | grid, scrollback, blocks, input |
| **Harness Adapter** | Per-harness driver: launch, observe, inject | Terminal Core (PTY) | normalized `AgentEvent` stream + `injectContext()` |
| **Context Engine** | Auto-assembly, memory, compaction, provenance — all inspectable | Adapter events, Index | Flight Deck's authoritative context layer |
| **Index Service** | Shared incremental code index (qartez-style), MCP-exposed | git, fs watcher | symbols, refs, call graph, embeddings |
| **Session/Project Store** | Data model + live state; single source of truth for the sidebar | Adapter events | sessions, repos, projects, status |
| **Sidebar UI** | Nested tree, inline live status | Store | rendering only |
| **App Shell** | Windows, panes, tabs, wiring | all | layout |

**Invariants:**
- The **Store** is the single source of truth; the **Sidebar** only renders it.
- The **Adapter** is the only component that talks to a harness. Adding a harness = writing one Adapter; nothing else changes.
- The **Context Engine** never reaches inside a harness's private window; it operates its own layer and the four levers below.

## 4. Context engine under interactive orchestration

Because the harness owns its context window (chosen drive mode), the engine influences it through **four levers** and inspects only its *own* layer:

1. **Inject** — per turn, assemble task-scoped context (index results + relevant memory + relevant terminal blocks) and push it via Claude Code's `UserPromptSubmit` hook / opencode's plugin hook.
2. **Serve** — expose the index, memory lookup, and an "assemble context for this task" tool as **MCP servers** the agent pulls on demand.
3. **Bootstrap** — generate per-session `CLAUDE.md` / `AGENTS.md` + MCP config from the layered scope (session → repo → project) at session start.
4. **Own** — the Adapter's event capture reconstructs the full transcript into the Store, so Flight Deck's context/memory/provenance is 100% inspectable, and its compaction is its own summarization the user can open and edit.

**Honest limit:** the harness's *internal* auto-compaction is observed, not owned. "Inspectable compaction" applies to Flight Deck's layer (what is surfaced, remembered, injected), not the harness's private window.

**Memory flow:** engine mines candidate facts/decisions from `AgentEvent`s → proposes them → **user approves/edits** → persisted → rolled up session → repo → project, with relevance scoping so unrelated repos don't bleed into a session's context.

## 5. Session / project model + sidebar

- **Session** = terminal + agent (+ optional git worktree). Many per repo.
- **Repo/folder** groups sessions. **Project** groups repos and holds shared memory/index. (v1: grouping + shared context; cross-repo agent tasks later.)
- **Layered context:** a session inherits its repo's and project's memory/index, relevance-scoped.
- **Sidebar:** nested tree, inline status. Per-row signals: **attention state** (needs-input / blocked / needs-approval), **run state + current action**, **context budget** (e.g. 34k/200k); **cost optional**.

```
▾ ◆ Payments Platform       3 run · 1⚠
  ▾ api-gateway  (repo)
    ● checkout-refactor  ▶ editing checkout.rs   34k/200k
    ⚠ rate-limit-fix     needs input
    ✓ audit-logging      done · 4 diffs
  ▾ web-dashboard  (repo)
    ● onboarding-flow    ▶ running               58k/200k
▾ ◆ Infra
  ▸ terraform-live (repo)  idle
```

## 6. Adapter mechanics (per harness)

- **Claude Code:** interactive session; hooks (`UserPromptSubmit` → inject; `PreToolUse` / `PostToolUse` / `Stop` → observe) + `--output-format stream-json` for the event stream; MCP for pull. This is the harder, closed harness — validating the abstraction against it matters.
- **opencode:** OSS; run its headless server; consume its OpenAPI + event stream; plugin hooks for inject. The easy, deep one.

Both normalize into one `AgentEvent` schema (turn-start, tool-call, tool-result, output-chunk, awaiting-input, awaiting-approval, compaction, turn-end, error) consumed by the Store and Context Engine.

## 7. Worktree lifecycle

On-demand. A session runs in the repo working dir by default. Opting a session into isolation creates a worktree + branch; its diffs are reviewed within the session; on completion the user merges or discards. Keeps v1 simple and parallel-safe only where wanted.

## 8. Known risks / honest hard parts

- **libghostty is early and unversioned** — the public C API is "coming"; v1 may ride the internal macOS C API and track churn.
- **Interactive injection depends on harness hook stability** — if Claude Code / opencode change hook contracts, adapters break; isolate that surface.
- **Harness-internal compaction is not inspectable** — mitigated by owning a parallel authoritative context layer.
- **Index as a shared service** — qartez is a strong substrate but is per-user MCP today; productizing means running it standalone and handling multi-worktree writers (single-writer SQLite WAL).

## 9. Build order (decomposition)

Six subsystems; build a vertical slice first, then layer. Each phase is independently shippable/testable.

1. **MVP (vertical spine):** Terminal Core (libghostty in a Swift/Metal window) + one repo + **Claude Code adapter (observe + inject)** + a **minimal index** feeding `UserPromptSubmit` injection + Session/Project Store + **nested sidebar** (attention + run-state + context budget). Proves the whole spine — including "intelligent" injection — end to end.
2. **Full Index Service** (qartez-style, MCP-exposed, incremental) + richer task-scoped auto-assembly + MCP pull tools.
3. **Memory** (auto-extract, user-curated) + layered session→repo→project scope + **provenance/inspection UI**.
4. **opencode adapter** (validates the harness abstraction) + **worktrees**.
5. **Compaction UI + project rollup + cost signals.**
6. **Later:** cross-repo project orchestration; additional harnesses; local-model paths.

## 10. Success criteria (MVP)

- Launch Flight Deck, open a repo, start a Claude Code session in an embedded Ghostty terminal that renders and behaves like a real terminal.
- Every user prompt is transparently enriched with index-derived context via injection, visible in a provenance view.
- The sidebar shows the session live: run state, current action, attention state, and context budget, updating in real time from the normalized event stream.
- Starting a second session in the same repo shows both under that repo, rolled up to the project.
