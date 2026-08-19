# Agent Adapters — Session Handoff

**Date:** 2026-08-19 · **Branch:** `master` · **Tip:** `502d2ad` · **Tests:** 748 unit, 0 failures, 5 skipped (4 of those opt-in integration)

Flight Deck can now run **claude or codex** in any tab. Claude's half is complete and clean.
Codex creates, resumes, renames and reads state — but its **observation half is inert**, for a
reason that is a design fact rather than a bug. That is the next piece of work, and it is
already decided. Read §2 before touching anything.

- **Spec:** [superpowers/specs/2026-08-18-agent-adapters-design.md](superpowers/specs/2026-08-18-agent-adapters-design.md)
- **Plan:** [superpowers/plans/2026-08-18-agent-adapters.md](superpowers/plans/2026-08-18-agent-adapters.md) (16 tasks, all executed)
- **Execution ledger, reports, every ruling:** `.superpowers/sdd/2026-08-18-agent-adapters/progress.md` (git-ignored; still on disk)

---

## 1. What exists

**The seam** — `Sources/FlightDeck/Agents/`

| Type | Role |
|---|---|
| `AgentID` | `.claude` / `.codex`; raw values are a storage format (they land in `sessions.json`) |
| `AgentBinding` | `{conversationID, transcriptURL?}` — what a prepared session is bound to |
| `AgentEvent` | `.title` / `.activity` / `.subagentCount` / `.turnEnded` — the only vocabulary `SessionStore` speaks |
| `AgentOptions` | `.claude(FlagSet)` / `.codex(CodexThreadOptions)` — a union, so neither agent's shape leaks into the other |
| `AgentAdapter` | identity + launch text + rename. `prepare` (async, negotiated), `binding(for:)` (sync, already-settled identity only), `rebind` (restore, defaults to `binding(for:)`) |
| `AgentRuntime` | observation. App-wide **per agent kind**, not per session — one status registry for claude, one app-server for codex, N tabs each |

**Claude** conforms over its existing machinery: mints its own UUID, derives the transcript
path from cwd, `TranscriptWatcher` + `SessionStatusWatcher`, rename by typing `/rename` into
the pty. Behaviour is unchanged — the whole-branch review found no regression in
`applyRegistry`, `commitStatuses`, the rename injection guard, or restore.

**Codex** — `Sources/FlightDeck/Agents/Codex/`: `CodexRPC` (newline-delimited JSON-RPC,
cancellation-aware), `CodexProcessTransport` (spawn, line reassembly, termination hook,
version probe), `CodexAdapter` (start→name commit transaction, `read`, `rebind`),
`CodexEventMapper` + `CodexThreadStatus`, `CodexRuntime` (per-thread routing,
reconcile-on-first-contact).

**UI** — the Claude preferences tab is now an **Agents** tab: reorderable list, per-agent
options pane. **List order is the shortcut binding**: position 1 = ⌘N, 2 = ⌘⇧N, 3 = ⌘⇧⌥N. The
sidebar button reads `New <Agent> Session` and relabels live while modifiers are held.

**Migration is additive.** A `sessions.json` with no `agent` key decodes as claude; preferences
with no agent list default to `[claude, codex]`, so ⌘N still opens claude.

---

## 2. Why codex observation is inert — read this first

**Codex app-server notifications are scoped to the connection that made the change.**

Established by experiment (`.superpowers/.../progress.md`, and reproducible in ~20 lines):

| Step | Result |
|---|---|
| Connection A creates + commits a thread, then renames it itself | A receives `thread/name/updated` ✓ |
| Connection **B** renames the same thread | **A sees nothing.** Only B is notified |
| A calls `thread/resume`, B renames again | **A still sees nothing** — resume does not subscribe |
| A calls `thread/read` | Sees the new name — **state is shared, events are not** |

Flight Deck runs turns in a `codex resume <id>` TUI, which is a **different process and
therefore a different connection**. So the app-server that created the thread never receives
`turn/*`, `item/*`, `thread/status/changed` or `thread/name/updated` for anything the user does.

**Consequence:** `CodexEventMapper`'s notification decoding is correct but is dead code in
production, and `CodexRuntime.handle` never fires. Title sync, status, sub-agent counts and
unread are all inert for codex today. `CodexThreadStatus` is *not* dead — it is also on the
`thread/read` path and stays live either way.

This was found by the final whole-branch review asking a question nobody had tested, then
settled by experiment. It cost nothing to check and would have cost a rewrite to discover later.

---

## 3. The decided next step: tail the rollout `.jsonl`

**Approved direction.** Source codex's events from its rollout file rather than from
notifications, exactly as claude's `TranscriptWatcher` already does.

Why this over the alternatives:
- `thread/start` already returns the rollout path as `thread.path` — no discovery needed.
- The path is date+UUID based (`~/.codex/sessions/YYYY/MM/DD/rollout-<ISO>-<uuid>.jsonl`), so
  unlike claude's it is **not** cwd-derived. *(Reasoned from the path shape and from the
  `retarget` analysis in spec §1.1.8 — not directly tested. Worth confirming with one `cd`.)*
- It works regardless of which process drives the turn, which is the property the notification
  route lacks.
- It reuses `TranscriptWatcher` and `WatchClock` — the most battle-tested machinery in the app.

**What changes**
1. `CodexRuntime`'s event source moves from `CodexRPC.onNotification` to a `TranscriptWatcher`
   over `binding.transcriptURL`.
2. `CodexEventMapper` is re-pointed from app-server notification payloads to **rollout record
   shapes**, which are entirely different:

   | Record `type` | Carries |
   |---|---|
   | `session_meta` | `id`, `cwd`, `git`, `cli_version` — written at thread creation |
   | `event_msg` | `payload.type`: `task_started`, `task_complete`, `turn_aborted`, `agent_message`, `user_message`, `token_count`, `mcp_tool_call_end`, `patch_apply_end`, `context_compacted`, `thread_rolled_back` |
   | `response_item` | message/tool records |
   | `turn_context`, `compacted` | context bookkeeping |

   So busy/idle comes from `task_started` / `task_complete` / `turn_aborted`, and `.turnEnded`
   (which drives unread) from `task_complete`.
3. **Sub-agent counts need re-deriving from rollout records** — the `collabAgentToolCall`
   shape is an app-server item type, and the rollout equivalent has not been surveyed. Do that
   first; it may be the piece that decides how much of §4.3 survives.
4. `CodexRPC` stays for what it is genuinely good at: identity (`thread/start`), commit and
   rename (`thread/name/set`), and authoritative reads (`thread/read`). Keep it.

**One subtlety when reusing `TranscriptWatcher`:** it decides where to start reading on its
first look — file *missing* means "ours from byte 0", file *present* means "tail from the end"
(this is deliberate; see `Scan.read`). A codex rollout file **already exists** when
`thread/start` returns, carrying `session_meta`. Tailing from the end is therefore correct —
you want turns, not the header — but do not "fix" it into reading from 0.

---

## 4. Verified facts about codex — do not re-derive these

All established empirically against `codex-cli` 0.142.4 / 0.147.0. The schema is ground truth
and is checked in: `Tests/FlightDeckTests/Fixtures/Codex/codex-app-server-v2.generated.json`
(with a provenance file), asserted by `CodexSchemaConformanceTests`.

1. **`thread/start` does not persist a thread.** No `state_5.sqlite` row, no rollout file, even
   seconds later with the app-server alive. **`thread/name/set` commits it**, and must be
   issued to the *same* app-server process. An unnamed thread cannot be resumed.
2. **A thread belongs to the app-server process that created it** — one long-lived app-server
   for the whole app.
3. **Identity is returned, never minted.** `ThreadStartParams` has no `threadId`.
4. **`initialize` requires real `clientInfo`.** Sending empty params omits the key entirely and
   codex answers `-32600 missing field 'params'`. This broke every codex launch end-to-end and
   was invisible to 708 hermetic tests, because stub transports validate nothing.
5. **Notifications are connection-scoped** (§2).
6. **`-32600` is also codex's "no such thread" answer** — so error *codes* cannot discriminate
   "gone" from "malformed". `CodexAdapter.isThreadGone` matches on the message plus an id echo.
   Brittle across releases by necessity; the conformance test cannot cover error strings.
7. **`addDirs` is not a `ThreadStartParams` field.** It is sent via
   `config.sandbox_workspace_write.writable_roots`; `config` is unvalidated, so acceptance is
   not proof of effect. **Unverified — see §5.**
8. **Launching `codex resume <id>` outside the thread's own cwd** raises a modal
   working-directory picker. Launch in the thread's cwd.
9. **`ThreadStatus` is `notLoaded | idle | systemError | active`** — no `running`, no `busy`.
   `active` carries `activeFlags: waitingOnApproval | waitingOnUserInput`, which is where
   `.waiting` comes from. `CollabAgentStatus` is
   `pendingInit | running | interrupted | completed | errored | shutdown | notFound`.

---

## 5. Parked — known, deliberately not fixed

1. **`CodexAdapter.rename` has no deadline.** The only RPC in the layer without one, and the
   rename dispatch fix made it reachable. After an app-server crash its continuation never
   resumes and leaks for the life of the store. Fire-and-forget, so nothing user-facing blocks.
   *The last reviewer would fix this before merge, and so would I.*
2. **`writable_roots` may clobber sibling sandbox settings** if codex merges `config` at table
   granularity rather than per key — it would drop `network_access` and friends from the user's
   `config.toml`. Fails safe (more restrictive) and only for users who set add-dirs. The
   follow-up is "verify merge granularity", not just "verify the roots work".
3. **`isThreadGone`'s phrase list is wider than what was probed** — `"no such thread"` was never
   observed. Tightening to the observed phrases costs nothing.
4. **`defaultRun`'s watchdog** is a check-then-act across threads. Harmless.

Sixteen further minor findings are triaged in the ledger (`rg "minor \(deferred\)"`), each
marked fix-before-merge / follow-up / non-issue by the whole-branch review. None are blocking.

---

## 6. How to work in here

- **Tests:** `./scripts/test-unit.sh` — 748, ~9s, headless. It runs `xcodegen generate`, so new
  files under `Sources/` and `Tests/` are picked up automatically.
- **Do not loop `scripts/smoke.sh`** — it steals focus for ~40s and your typing lands as fake
  test failures.
- **No committed test may spawn `codex` or pop a modal.** Real-codex tests live in
  `CodexIntegrationTests` behind `FLIGHT_DECK_CODEX_INTEGRATION=1`; run them with
  `FLIGHT_DECK_CODEX_INTEGRATION=1 ./scripts/test-unit.sh`. Every store built in a test injects
  a spy `launchFailureReporter` and a temp `projectsRoot`.
- **Never touch live state:** `~/Library/Application Support/Flight Deck/sessions.json`,
  `UserDefaults`, `~/.claude`, or `~/.codex` beyond reads and threads your own test created.
- **This checkout is shared** — several Claude sessions commit to `master` concurrently. Commit
  by explicit path; never `git add -A`, `checkout .`, `stash`, `rebase` or `pull`.
- **`Tests/FlightDeckTests/Fixtures/` is a folder reference with `buildPhase: resources`.** A
  `.swift` file placed there is copied, not compiled, and its symbols silently vanish.

**The lesson worth carrying:** three of this branch's worst defects — the empty-params
handshake, the wrong `agentsStates` type, and the wrong status vocabulary — were assumptions
validated against fixtures the author wrote. `CodexSchemaConformanceTests` exists to stop that
recurring. **When adding anything that touches codex's wire format, assert it against the
generated schema, not against a fixture you wrote.**
