# Codex reattach — strip terminal-capability queries from the fd-abduco replay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Fix codex sessions reattaching with garbage in the composer. Root cause (confirmed by tracing): the `fd-abduco` replay ring stores the child's raw output, **including the terminal-capability queries codex emits** (XTVERSION, XTGETTCAP, DA, DSR); on reattach the whole ring is replayed to a fresh ghostty, which **re-answers** those queries, and the answers are routed into codex's stdin → they land in the composer (observed: `› >|ghostty 1.3.11+…` + XTGETTCAP hex, with a subsequently-typed `hi` appended to the junk). Fix: **filter terminal-query sequences out of the bytes that enter the replay ring**, leaving the live forward untouched.

**Why this is correct & lossless:** the ring only ever captures the child's *output* (`server_read_pty`), so it holds the *queries* but never the *answers* (answers arrive as client→pty input, never appended). The original session already consumed its one legitimate answer live, so a replay that omits the queries loses nothing a reattaching client needs — it just stops provoking a duplicate answer.

**Scope:** the `fd-abduco` fork only. This is the running-state input-corruption bug. The separate **trust-prompt-state reattach failure** (cold-create + codex exit) is undiagnosed and **out of scope** here (needs its own liveness probe).

**Architecture:** Add an escape-sequence-aware filter to the capture path so recognized *host→terminal query* sequences are dropped before they enter `FdOutlog`'s ring. The filter is **stateful** (a query can split across `server_read_pty` reads) and lives in `FdOutlog`. It must **not** mutate the live-forward packet — only what is copied into the ring.

**Tech Stack:** C (the vendored `fd-abduco` fork), the existing `Tests/fd-abduco/*` C/shell harness.

**Spec/diagnosis:** root-cause trace recorded in `.superpowers/sdd/2026-09-07-detached-session-persistence-phase3-smoke-and-knob/progress.md` (ROOT CAUSE CONFIRMED section) and `task-codex-liveness-probe-report.md`.

## Global Constraints

- **Fork-only, shared branch.** Touch ONLY `vendor/fd-abduco/*` and `Tests/fd-abduco/*`. Do NOT touch `DaemonControl.swift`/`SessionStore.swift`/`TerminalPane.swift`/Preferences (another session owns those). Retain the ISC/provenance headers. Never `git clean`.
- **Live behavior unchanged.** The filter affects ONLY the bytes appended to the ring (`fd_outlog_append` path fed at `server.c:264-265`). The live forward to currently-attached clients (`server_send_packet(c, &server_packet)`) must see the **unmodified** stream, so the live ghostty still answers the query exactly once, correctly. Do not mutate `server_packet` in place.
- **Query set to strip** (host→terminal *requests* only — never responses, never normal SGR/cursor/paint sequences):
  - XTVERSION: `ESC [ > q` and `ESC [ > 0 q`
  - XTGETTCAP: DCS `ESC P + q … ST` (ST = `ESC \` or BEL)
  - Primary DA (DA1): `ESC [ c`, `ESC [ 0 c`
  - Secondary DA (DA2): `ESC [ > c`, `ESC [ > 0 c`
  - Tertiary DA (DA3): `ESC [ = c`
  - DSR: `ESC [ 5 n`, `ESC [ 6 n`
  - Kitty keyboard query: `ESC [ ? u`
  These are unambiguously requests (a program emits them to solicit a reply); none has a legitimate render meaning, so dropping them from *replay* is safe.
- **Conservative:** when a sequence starting with `ESC` cannot be classified as one of the above by the time it completes (or exceeds a small cap, e.g. 32 bytes), emit it **verbatim** into the ring. Never drop bytes you haven't positively identified as one of the listed queries. Better to under-strip (a stray bleed) than over-strip (corrupt scrollback).
- **Partial across chunks:** a query may be split across two `fd_outlog_append` calls. Hold an unterminated candidate in `FdOutlog` scanner state; resolve it on the next append. On `fd_outlog_trim`/finalize, flush any pending candidate verbatim.
- Keep all existing `Tests/fd-abduco/run_all.sh` tests green (baseline, outlog, replay, replay_busy, trim, pidfile).

---

### Task 1: Terminal-query filter in `FdOutlog` (pure C, unit-tested)

**Files:**
- Modify: `vendor/fd-abduco/fd_outlog.h`, `vendor/fd-abduco/fd_outlog.c` (add scanner state + filtering append).
- Modify: `vendor/fd-abduco/server.c` (capture call site ~264-265, if a signature/wrapper change is needed) — ONLY the ring-append path, not the live forward.
- Test: `Tests/fd-abduco/test_outlog_queries.c` + `Tests/fd-abduco/run_outlog_queries_test.sh`; add to `run_all.sh`.

**Interfaces:**
- Produces: `fd_outlog_append` (same call site) now drops the listed query sequences from what it stores, statefully; a `fd_outlog_trim`/finalize flushes any pending candidate verbatim. `FdOutlog` gains a small scanner state (pending-escape buffer + cap). No change to the live-forward path.

- [ ] **Step 1: Write failing unit tests** (`test_outlog_queries.c`) against `FdOutlog` directly (compile with `fd_outlog.c`, like `test_outlog.c`):

```c
/* helper: append then trim, return the ring contents */
// 1. XTVERSION mid-stream is stripped:
//    append "abc\x1b[>qdef"; expect ring == "abcdef"
// 2. XTGETTCAP DCS is stripped:
//    append "x\x1bP+q544e\x1b\\y"; expect ring == "xy"
// 3. DA1 / DSR stripped: "\x1b[c" , "\x1b[6n" -> gone
// 4. Query SPLIT across two appends is stripped:
//    append "ab\x1b[>"; append "qcd"; expect ring == "abcd"
// 5. Normal output is untouched (not over-stripped):
//    append "\x1b[1;31mred\x1b[0m\x1b[2J\x1b[H"; expect ring identical
//    (SGR, cursor home, clear — none are in the query set)
// 6. Ambiguous/incomplete escape at end flushes verbatim:
//    append "hi\x1b[>"; trim/finalize; expect ring == "hi\x1b[>"
//    (an unresolved candidate must not be silently dropped)
```

- [ ] **Step 2: Run, verify fail** (`bash Tests/fd-abduco/run_outlog_queries_test.sh` → compile/assert failure).
- [ ] **Step 3: Implement the filter** in `fd_outlog.c`: a small state machine invoked from `fd_outlog_append`. States: NORMAL → on `ESC` enter CANDIDATE, buffer bytes; classify as the sequence completes (CSI `ESC [` … final byte in `@`–`~`; DCS `ESC P` … `ST`); if it matches a listed query, DROP the buffered candidate; otherwise EMIT it verbatim; on a byte that can't extend a valid sequence, or on exceeding the cap, EMIT verbatim and return to NORMAL. Persist an unresolved candidate across calls in `FdOutlog`. `fd_outlog_trim`/free must flush any pending candidate first. Keep the existing screen-clear-marker trim behavior intact (it operates on the already-filtered ring bytes).
- [ ] **Step 4: Run, verify pass** (`run_outlog_queries_test.sh` green).
- [ ] **Step 5: Wire + regress** — ensure the `server.c` capture site feeds the filter (ring only; live forward untouched). Rebuild (`scripts/build-fd-abduco.sh`), then `bash Tests/fd-abduco/run_all.sh` — all green (baseline/outlog/replay/replay_busy/trim/pidfile), and add `run_outlog_queries_test.sh` to it.
- [ ] **Step 6: Commit** (`fix(fd-abduco): strip terminal-capability queries from the replay ring`).

---

## Verification (whole fix)
- `bash Tests/fd-abduco/run_all.sh` green incl. the new query-strip tests.
- App builds; `fd-abduco` bundled.
- **Manual (gated on Nate's display):** re-run `testCodexReattachDaemonLivenessProbe` (or the codex reattach test) — the POST-REATTACH composer must be **clean** (no `>|ghostty…`/XTGETTCAP bleed), and a flushed command must land as clean input. This is the payoff check for the running state.

## Non-goals
- The **trust-prompt-state** reattach failure (cold-create + codex exit) — separate, undiagnosed; needs its own liveness probe (detach *at* the trust prompt). Not addressed here.
- Verifying claude actually emits no such queries (inferred, not byte-checked) — the filter is a no-op for a stream that contains no query sequences, so it's safe regardless.
