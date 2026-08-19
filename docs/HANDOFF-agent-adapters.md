# Agent Adapters — Session Handoff

**Date:** 2026-08-19 · **Branch:** `master` · **Tip:** `502d2ad` · **Tests:** 748 unit, 0 failures, 5 skipped (4 of those opt-in integration)

Flight Deck can now run **claude or codex** in any tab, and observe both. Claude's half is
complete and clean. Codex creates, resumes, renames, reads state, and — as of
2026-08-19 — observes: title, activity and unread all come from tailing the files codex
itself writes, not from app-server notifications, for a reason that is a design fact rather
than a bug. Read §2 before touching anything.

- **Spec:** [superpowers/specs/2026-08-18-agent-adapters-design.md](superpowers/specs/2026-08-18-agent-adapters-design.md)
- **Plan:** [superpowers/plans/2026-08-18-agent-adapters.md](superpowers/plans/2026-08-18-agent-adapters.md) (16 tasks, all executed)
- **Execution ledger, reports, every ruling:** `.superpowers/sdd/2026-08-18-agent-adapters/progress.md` (git-ignored; still on disk)
- **Codex observation spec (binding authority for §2-§3 below):** [superpowers/specs/2026-08-19-codex-rollout-observation-design.md](superpowers/specs/2026-08-19-codex-rollout-observation-design.md)
- **That work's execution ledger:** `.superpowers/sdd/2026-08-19-codex-rollout-observation/progress.md` (git-ignored; still on disk)

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
`CodexEventMapper` (rollout record → `AgentEvent`) + `CodexThreadStatus` (`thread/read`'s
status union), `CodexRolloutWatcher` (one per tab, tails the rollout `thread/start`
returned), `CodexNameWatcher` (one, app-wide, tails `session_index.jsonl` for renames),
`CodexRuntime` (fans both out to the right tab). See §3.

**UI** — the Claude preferences tab is now an **Agents** tab: reorderable list, per-agent
options pane. **List order is the shortcut binding**: position 1 = ⌘N, 2 = ⌘⇧N, 3 = ⌘⇧⌥N. The
sidebar button reads `New <Agent> Session` and relabels live while modifiers are held.

**Migration is additive.** A `sessions.json` with no `agent` key decodes as claude; preferences
with no agent list default to `[claude, codex]`, so ⌘N still opens claude.

---

## 2. Why codex observation tails files instead of listening for notifications

**Codex app-server notifications are scoped to the connection that made the change.** This is
the constraint the design in §3 is built around, not a bug to route around later.

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

**Consequence:** the notification path — `CodexEventMapper`'s notification decoding,
`CodexRuntime.handle`, `CodexRPC.onNotification`, and the reconcile machinery that ordered a
read against that stream — is deleted, not merely dead. Title, status and unread for codex
now come from tailing the rollout `thread/start` returns and the app-wide
`session_index.jsonl`, exactly as §3 describes. `CodexThreadStatus` survives unchanged — it
was never on the notification path, only on `thread/read`, which `rebind` and restore still
use.

This was found by the final whole-branch review asking a question nobody had tested, then
settled by experiment. It cost nothing to check and would have cost a rewrite to discover
later — instead it decided the design in §3 before any of that code shipped.

---

## 3. What ships: tailing the rollout `.jsonl` and the session index

Built 2026-08-19 against the design in
`docs/superpowers/specs/2026-08-19-codex-rollout-observation-design.md` — that spec is the
binding authority for anything below that goes stale; this section is a summary.

Codex's events are sourced from the files codex itself writes, not from notifications,
exactly as claude's `TranscriptWatcher` already does. `TailReader`
(`Sources/FlightDeck/TailReader.swift`) is the primitive underneath all three watchers now:
extracted from `TranscriptWatcher`'s `Scan.read`, pure bytes-in/lines-out, deciding where to
start (file missing → ours from byte 0; file present → tail from the end) and holding back a
partial trailing line so a read landing mid-write can't split a record.

| Watcher | Scope | Tails | Emits |
|---|---|---|---|
| `TranscriptWatcher` | one per claude tab | the claude transcript | `.title`, `.subagentCount` |
| `CodexRolloutWatcher` | one per codex tab | `binding.transcriptURL` (the rollout `thread/start` returned) | `.activity`, `.turnEnded` |
| `CodexNameWatcher` | one, app-wide | `<codex home>/session_index.jsonl` | `.title`, routed by thread id |

`CodexEventMapper.events(inRolloutLine:)` maps `event_msg` records: `task_started` →
`.activity(.busy)`; `task_complete` / `turn_aborted` → `.activity(.idle)`, `.turnEnded`;
everything else is ignored. `session_index.jsonl` carries one `{id, thread_name, updated_at}`
line per rename, from either `thread/name/set` or the TUI's own `/rename`; the name watcher
routes each line by `id` to whichever tab holds that conversation and drops ids no tab holds.

**A codex rollout file already exists, with its `session_meta` header, by the time
`thread/start` returns.** `TailReader`'s existing rule sends an existing file to the end,
which is correct here — the header is not a turn — but do not "fix" it into reading from 0.

**What this replaced.** `CodexRPC.onNotification`, `CodexRuntime.handle`, and the reconcile
machinery that used to order an async `thread/read` against that notification stream
(`reconcile`, `reconcileByReading`, `runReconcile`, `applyReconciled`, `CodexThreadState`,
and the fields that tracked an in-flight reconcile) are all deleted — not merely unused.
Ordering a read against a notification stream was only ever needed because the notification
stream existed; once events arrive as ordered lines in a file, there is nothing left to race.

**What `CodexRPC` still does**, because tailing can't: identity (`thread/start`), commit and
rename (`thread/name/set`), and `thread/read` on the two paths that predate any file — `rebind`
settling a restored tab's identity, and `resumeRestoredCodex`'s follow-up read, which applies
**only the title** (never the activity — `thread/read` reports `notLoaded` for a thread a TUI
drives) to recover a rename made while Flight Deck was closed. Both watchers start at
end-of-file, so that's the one gap a file-only design can't close on its own.

**Known limitations, stated in the code and not worked around** (spec §5): no `.waiting` for
codex — nothing is written to the rollout when codex starts waiting on approval, so a codex
tab reads busy through an approval prompt. No `.subagentCount` for codex — no `collab` record
exists in any of 492 surveyed rollouts, so there is no ground truth to map it from.

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
