# Codex Rollout Observation — Design

Flight Deck can run codex in any tab, but a codex tab is blind: its title never syncs, its
status never moves, and it never marks itself unread. The reason is not a bug. **Codex
app-server notifications are scoped to the connection that made the change**, and Flight
Deck runs turns in a `codex resume <id>` TUI — a different process, therefore a different
connection. The app-server that created the thread is never told what the user does in it.
See `docs/HANDOFF-agent-adapters.md` §2 for the experiment that established this.

This design sources codex's events from files on disk instead, the way claude's already
are. It also deletes the machinery that existed only to make the notification path safe.

Everything in §1 was verified on 2026-08-19 against codex-cli **0.148.0**, in an isolated
`CODEX_HOME`, plus a survey of 492 real rollout files. Where a claim is reasoned rather
than measured, it says so.

## 1. Findings that constrain the design

1. **`codex resume <id>` appends to the rollout `thread/start` returned.** A thread created
   over the app-server, then resumed in a real TUI, grew its existing file from 18,568 to
   41,239 bytes and created no new one. This is the fact the whole approach rests on: the
   rollout is written by whichever process drives the turn, so it does not care that our
   app-server is not that process.

2. **Turn boundaries are `event_msg` records.** `task_started {turn_id, started_at,
   model_context_window}` opens a turn; `task_complete {turn_id, last_agent_message,
   duration_ms}` closes it; `turn_aborted` closes an interrupted one. Across the 492-file
   survey the three balance exactly (7 starts, 6 completes, 1 abort).

3. **Renames never appear in the rollout.** Not from our `thread/name/set`, not from the
   TUI's `/rename`. Zero name records in any file.

4. **Renames appear in `session_index.jsonl`, which is append-only.** One line per rename,
   `{id, thread_name, updated_at}`, at the codex home root. Verified for both writers: an
   app-server `thread/name/set` from a *second* connection appended a line, and `/rename`
   typed into the TUI appended another — three lines, one id, in order. This file is the
   only place a codex title change is observable.

5. **`thread/read` on a TUI-driven thread reports `status: notLoaded` and `turns: []`.**
   The read path recovers the thread's **name** correctly but knows nothing about activity
   in a process it does not own. A read can therefore back-fill a title, and only a title.

6. **Nothing is written when codex starts waiting on the user.** With an approval prompt
   live on screen, the rollout's last records were a `response_item/custom_tool_call` with
   no output and no `task_complete`. There is no waiting record to map.

7. **There is no schema for either file format.** `codex app-server generate-json-schema`
   covers the app-server protocol only: the checked-in
   `codex-app-server-v2.generated.json` contains zero occurrences of `task_started`,
   `EventMsg`, `RolloutItem` or `SessionMeta`. The rule this branch adopted — assert against
   codex's generated schema, never against a fixture you wrote — has no equivalent here.

8. **The record vocabulary is recent.** Only 7 `task_started` records exist across 492
   rollouts; the other 490 files predate them. Reading these records is reading a young,
   unversioned format.

9. **No sub-agent ground truth exists.** Zero `collab` records in 492 rollouts. The
   `collabAgentToolCall` shape the current mapper handles is an app-server item type, and
   nothing establishes what its rollout equivalent looks like — or that there is one.

10. **`codex exec resume --skip-git-repo-check <id> "<prompt>"` appends to the same rollout
    with the same records**, headless, in about four seconds. No pty, no TUI, no modal.
    This is the only vehicle a committed test may use to drive real codex.

11. **The rollout already exists when `thread/start` returns**, carrying an ~18 KB
    `session_meta` header. Tailing from the end is therefore correct — see §4.

## 2. Architecture

One primitive is extracted, three watchers sit on it, and one class loses half its body.

### 2.1 `TailReader` — extracted, not invented

`Scan.read` in `TranscriptWatcher.swift` already does the hard part: decide where to start
(file missing → ours from byte 0; file present → tail from the end), notice a file that
shrank, read only through the last complete newline so a read landing mid-write cannot
split a record. That logic is battle-tested and currently welded to
`ClaudeSession.events(inLine:sessionID:)`.

`TailReader` is that logic with the parse removed: bytes in, complete lines and a new
offset out. Pure and `Sendable`, so it keeps running off the main actor exactly as
`Scan.read` does today. It is extracted rather than copied because this work gives it three
consumers.

### 2.2 The three watchers

| Type | Scope | Tails | Emits |
|---|---|---|---|
| `TranscriptWatcher` | one per claude tab | the claude transcript | `.title`, `.subagentCount` |
| `CodexRolloutWatcher` | one per codex tab | `binding.transcriptURL` | `.activity`, `.turnEnded` |
| `CodexNameWatcher` | **one, app-wide** | `<codex home>/session_index.jsonl` | `.title`, routed by thread id |

Each folds lines its own way — claude tracks outstanding sub-agent tool ids, the rollout
watcher tracks turn boundaries, the name watcher routes by id — and shares only the byte
handling. `TranscriptWatcher`'s observable behaviour does not change.

The name watcher is app-wide for the same reason `SessionStatusWatcher` is: one file
carries every thread, so scanning it per tab would read the same bytes N times. It resolves
its path from `CODEX_HOME` when set, falling back to `~/.codex`, and that path is injectable
so tests never touch the real one.

### 2.3 `CodexRuntime` after

`CodexRuntime` ends up the shape `ClaudeRuntime` already has: N per-tab watchers plus one
shared source fanned out by conversation id.

- `attach` starts a `CodexRolloutWatcher` for the binding's `transcriptURL` and registers
  the tab with the shared `CodexNameWatcher`, creating it on first attach.
- `detach` stops that watcher and unregisters the tab, following `ClaudeRuntime`'s rule of
  stopping explicitly rather than relying on the replaced value being released.
- Both are driven by the app's single `WatchClock`, so N codex tabs cost one wakeup.
  `CodexStack` gains the clock it currently does not take.

### 2.4 What is deleted

The whole notification path, and the ordering machinery that existed only to make it safe:

- `CodexRPC.onNotification` wiring in `CodexRuntime.init`, and `handle(method:params:)`.
- `reconcile`, `reconcileByReading`, `runReconcile`, `beginReconcile`, `finishReconcile`,
  `applyReconciled`, the `deliveringReconcile` task-local, `reconcileAttempts`, and the
  `version` / `reconcilingAt` / `reconcileToken` / `reconcileScheduled` /
  `reconcilesRemaining` fields.
- `CodexThreadState` and `CodexEventMapper.liveStates`, together with every notification
  case in the mapper.
- `SessionStore`'s `reconcileByReading` wiring in `CodexStack`.

That apparatus orders an `async` read against a synchronous notification stream. Both sides
of that race are gone: events now arrive as ordered lines in a file, and the read that
raced them is no longer issued on the observation path. Deleting it is the point of the
change, not a side effect — roughly 150 lines whose only purpose was to be careful about a
hazard that no longer exists.

### 2.5 What stays, and why it covers the one gap

`CodexAdapter.read` and `CodexThreadStatus` survive because `rebind` still needs them, and
they turn out to close the only hole tailing leaves. Both watchers start at end-of-file, so
a rename made while Flight Deck was **closed** is invisible to the name watcher. `rebind`
already round-trips `thread/read` on restore, and finding 5 says that read returns the
correct name even for a thread it reports as `notLoaded`. Restore gets its title from the
read; everything live gets it from the tail. One gap, already plugged, and still no polling.

## 3. Mapping

### 3.1 Rollout → `AgentEvent`

One JSON object per line. Only `type == "event_msg"` is consulted.

| `payload.type` | Emits |
|---|---|
| `task_started` | `.activity(.busy)` |
| `task_complete` | `.activity(.idle)`, `.turnEnded` |
| `turn_aborted` | `.activity(.idle)`, `.turnEnded` |
| anything else | nothing |

This is deliberately the same pair `turn/completed` emits today, so nothing downstream
moves. `SessionStore.applyTurnEnded` is `applyActivity(.idle)`, and that redundancy is
already documented there as intentional.

### 3.2 Index → `.title`

Each line is `{id, thread_name, updated_at}`. Route by `id` to the tab holding that
conversation; drop ids no tab holds — the file is app-wide and carries threads Flight Deck
never created. Our own `thread/name/set` echoes back through it; that is idempotent, since
the echoed string is the title the tab already shows.

### 3.3 One policy split in `TailReader`

Today a file that shrinks means "replaced — re-read from 0". That is right for a
per-conversation transcript and **wrong for the shared index**: every replayed line is a
stale title, so a compaction would walk every tab's name backwards through its own history.
The name watcher therefore takes a `resumeAtEnd` truncation policy; claude's transcript and
the codex rollout keep `restartFromZero`. Whether codex ever compacts the index has not
been observed — the policy is chosen so that it does not matter.

## 4. Starting position

The rollout exists, with its `session_meta` header, before any terminal does (finding 11).
`TailReader`'s existing rule sends an existing file to the end, which is what we want: the
header is not a turn. **Do not "fix" this into reading from byte 0.** The same rule applied
to claude for the opposite reason, and the comment in `Scan.read` explaining it should
survive the extraction intact.

A tab created in this session therefore sees its first `task_started` live. A restored tab
starts at the end of whatever accumulated while the app was closed and takes its title from
`rebind`'s read, per §2.5.

## 5. What codex does not get

Both of these are stated as limitations rather than approximated, and both should be
written into the code as comments naming the evidence:

- **`.waiting`.** No record is written when codex starts waiting on approval (finding 6), so
  a codex tab reads *busy* while an approval prompt is up. A `custom_tool_call` with no
  matching output is an available heuristic for it. It is rejected: it infers a user-visible
  state from the absence of a record, and inference from a shape nobody measured is how this
  branch produced three of its worst defects.
- **`.subagentCount`.** Nothing to map (finding 9). The mapper emits none. `AgentEvent`
  keeps the case — claude uses it.

## 6. Testing

**Unit.** `TailReader` (start position for missing and existing files, a partial trailing
line held back, both truncation policies); the mapper (one case per record type, plus lines
it must ignore); `CodexRolloutWatcher` and `CodexNameWatcher` folds; `CodexRuntime` fan-out
(right tab, unknown ids dropped, detach stops the watcher). All hermetic, all against temp
files, no process.

**Captured fixtures, never authored.** A real rollout and a real `session_index.jsonl`
segment produced by codex 0.148.0 during this design's probe, trimmed and checked in beside
the existing schema with a provenance file recording the version and how they were made.
Finding 7 means there is no schema to assert against; a captured artefact is the closest
honest substitute, and the distinction that matters is that no human typed its contents.

**Opt-in integration.** Behind `FLIGHT_DECK_CODEX_INTEGRATION=1`, alongside the existing
`CodexIntegrationTests`: create a thread, drive one turn with `codex exec resume
--skip-git-repo-check`, and assert the vocabulary still appears and the watcher still emits
`.busy` then `.idle`. This is the only test that can catch codex changing the format, and
finding 10 makes it cheap and modal-free. It must run against an isolated `CODEX_HOME`.

**What the deletion also removes.** Four `CodexSchemaConformanceTests` cases only make
sense for the notification path and go with it: `testEveryNotificationTheMapperHandlesExists`,
`testTurnAbortedIsNotAThingAndTheMapperNoLongerPretendsItIs`,
`testCollabAgentStateIsAnObjectWithAStatus`, and `testEveryLiveStateIsARealCollabAgentStatus`.
The nine `CodexEventMapperTests` cases are rewritten against rollout records, and the six
reconcile-ordering cases in `CodexResumeTests` are deleted outright. The status-variant cases
(`testEveryThreadStatusVariantIsAccountedFor`, `testEveryThreadActiveFlagMeansWaiting`) stay:
`CodexThreadStatus` is still on the `thread/read` path.

This is a real loss and should be stated as one. Codex's own generated schema was asserting
those four; nothing generated can assert their replacements. Coverage moves from
schema-asserted to capture-asserted, which is weaker — it verifies what codex *did* on one
day rather than what it *declares*. It is the strongest available option given finding 7,
not a good one.

## 7. Risks

1. **An unversioned format, now with less coverage.** Deleting the notification path also
   deletes the four conformance cases codex's schema was checking (§6).
   Findings 7 and 8: no schema, and the records are recent
   enough that 490 of 492 surveyed files predate them. A codex release can rename
   `task_complete` and nothing will fail to compile. The opt-in integration test is the
   only alarm; the failure mode if it is not run is silent — tabs stop moving, exactly the
   symptom this work exists to fix.
2. **Index compaction is unobserved.** Mitigated by policy (§3.3) rather than by knowledge.
3. **Approval prompts read as busy** (§5). User-visible, and a regression against nothing —
   codex tabs show no status at all today.
4. **`CODEX_HOME`.** The name watcher must honour it or it will tail a file codex is not
   writing. Injectable path, asserted in tests.

The items parked in `docs/HANDOFF-agent-adapters.md` §5 stay parked; none of them is on this
path.

## 8. Out of scope

Sub-agent counts for codex (nothing to map). `.waiting` for codex (nothing to read).
Any change to claude's observable behaviour. Any change to `CodexRPC`'s request/response
half, which keeps `thread/start`, `thread/name/set` and `thread/read`.
