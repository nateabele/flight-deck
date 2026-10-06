# Subagents as first-class children of a session — design

2026-10-06. Status: approved.

## 1. Why

On 2026-10-05 a background implementer subagent, two levels below the "Flywheel Planning" session,
hit a Bash permission dialog. claude drew it in the parent's TUI and set the parent `waiting` /
"permission prompt". It wrote the `tool_use` to the subagent's own file,
`<conversation>/subagents/agent-<id>.jsonl`. Flight Deck reads only the parent transcript, so the
Mac and phone said "Still working (no response needed)" for 90 minutes. Two fixes since
(7cdecd26, f63f6650) stop that false claim by refusing `subagent_prompt`. The dialog still cannot be
answered from the phone, and subagents are still only an anonymous count.

Today's model (as-built, 2026-10-06):

- `TranscriptWatcher.outstandingAgents` folds `Agent` launches and task-notifications from the
  parent transcript into a count (`subagentCount`). It is in memory only and starts at end of
  file on attach, so agents launched before a Flight Deck relaunch are never counted. Only
  top-level agents count.
- Nothing reads `agent-<id>.meta.json`. Nothing is keyed by agent id.
- The timeline, `OpenPrompt.find`, the wire and the phone all assume one transcript per session.
- `PromptService.subagentHoldsOpenCall` treats any subagent ending on an unresolved `tool_use` as a
  possible dialog. It cannot tell a blocked call from a running one.

## 2. Goals and non-goals

Goals (Nate, 2026-10-06):

1. A subagent's permission dialog is identified (which agent, which call), shown on the phone as
   a card, and answerable from the phone exactly like a main-transcript dialog.
2. Each live subagent is a visible, named child of its session on the Mac and the phone: type,
   description, and running / blocked / done. Nested agents show as a tree, collapsed by
   default, with the path to a blocked agent expanded.
3. The count survives a Flight Deck relaunch and counts what is really running.

Non-goals:

- Reading a subagent's own conversation (a drill-in timeline). Not chosen.
- Codex. Codex has no subagent transcripts and no readable dialog today
  (`openPromptReader == nil`). The adapter capability added here returns nil for it.
- `AskUserQuestion` raised by a subagent. Claude 2.1.281+ writes that `tool_use` only at resolve
  (see memory "blocking tool_use is written at raise"), so no transcript can show it open, for
  any agent. Out of scope here as it is for the main transcript.

## 3. Facts this design rests on

Verified on the live 2026-10-05 conversation (claude 2.1.289) unless marked:

- Every subagent, at any depth, writes `subagents/agent-<id>.jsonl` and `agent-<id>.meta.json` in
  the parent conversation's folder. `meta.json` keys: `agentType`, `description`, `model`,
  `parentAgentId` (absent at depth 1), `spawnDepth`, `toolUseId`, `requestShape`,
  `requestNonInteractive`.
- Every record in a subagent file carries `"isSidechain": true`. `ClaudeTimelineMapper` drops
  those unless called with `sidechain: true` (f63f6650).
- A finished subagent's last conversational record is an `assistant` record of text blocks with
  no `tool_use` (268 of 268 finished files). A running or blocked one ends on an unresolved
  `tool_use`, or on a `user` record while the model is generating.
- `PreToolUse` hook events for a subagent's call carry `agent_id`, `agent_type` and
  `tool_use_id` (from `hook-events-release/events.ndjson`).
- The registry flipped to `waiting` 70ms after the blocked call was written.
- For a permission-gated tool the hooks fire `PreToolUse` → `PermissionRequest` → `Notification`,
  all while the dialog is open (probe 2026-09-24, main agent only).
- Denying with Esc fires no hook (probe 2026-09-19).

**Not yet verified** (Task 1 of the plan):

- What `PermissionRequest` carries for a *subagent's* dialog. In particular, does it have
  `agent_id` and `tool_use_id`?
- What a denied subagent call writes to the subagent's file (a `tool_result` with
  `is_error`, or nothing).

## 4. Design

### 4.1 `SubagentTree` (Mac, pure)

A value type built per Claude session from the conversation's `subagents/` folder.

```swift
struct SubagentNode: Equatable {
    let id: String            // the agent id, "a28ad87bc9c01d113"
    let parentID: String?     // nil at depth 1
    let type: String          // meta.agentType, "implementer"
    let description: String   // meta.description, "Implement L3-S Task 14"
    var state: State
    enum State: Equatable { case running, blocked(callID: String), done }
}
```

- A node is built from its `meta.json` (read once per file) and the tail of its `.jsonl`.
- **done:** the last conversational record is an assistant record with no `tool_use`. A
  `SendMessage` resume appends a new turn, so the node returns to `running` without special
  handling.
- **running:** anything else.
- **blocked:** set only by attribution (§4.3), never from the file alone.
- **Scope:** only files modified since the tab's claude process started (the
  `PromptService.agentStartedAt` bound). That hides agents an earlier process left half-done.
  Done nodes stay until the session's next `UserPromptSubmit`, so a glance shows what just
  finished.
- A node whose parent is not in scope hangs from the root.

### 4.2 `SubagentWatcher` (Mac)

One per Claude session, owned beside `TranscriptWatcher` in `ClaudeRuntime`.

- Re-scans the folder on a parent-transcript change, on a task-notification, and on the
  registry tick while any node is non-done. A scan is one listing plus one `stat` per file; only
  files whose stamp changed are re-read (one `tailRecords` window, `sidechain: true`). Measured:
  1.2ms for a 238-file folder, plus ~1.4ms per changed 5.7MB file.
- Emits `AgentEvent.subagents(SubagentTree)` when the tree changes.
- `subagentCount` becomes the count of non-done depth-1 nodes. `outstandingAgents` stays as a
  re-scan trigger only. This fixes the relaunch undercount.

### 4.3 Attribution: which call the dialog belongs to

The plugin registers `PermissionRequest` with the same `record.sh` (record only, no output, so
it makes no decision and cannot race Plannotator's hook). `HookEventWatcher` parses it.

- On `PermissionRequest` for session S: take `agent_id` and `tool_use_id` from the payload. If
  the payload lacks `tool_use_id`, use the `tool_use_id` of the latest `PreToolUse` for S with
  the same `agent_id` (absent for the main agent) and the same `tool_name` and `tool_input`.
- That gives `pendingDialog[S] = (agentID?, callID)`.
- **The transcript confirms it.** The dialog is open while S is `waiting` AND the named file
  (subagent's, or the parent's when `agentID` is nil) still has `callID` unresolved. Otherwise
  `pendingDialog[S]` is cleared. This is what handles Esc, which fires no hook.
- A confirmed subagent dialog sets that node to `blocked(callID)`.
- **Main-agent dialogs are unchanged.** With `agentID` nil, the current main-transcript path
  stays the authority. The hook only adds a cross-check.
- **No hook seen** (plugin not loaded, older build): behavior stays exactly as today
  (`subagent_prompt`, no card).

### 4.4 Wire (FleetKit)

All additions are optional and decoded with `decodeIfPresent`, so an older Mac or phone sees
today's behavior. Each new field and every handler arm for it land in one commit (memory:
wire enum cases are atomic).

- `WireSession.subagents: [WireSubagent]?`: `{id, parent, type, description, state}`, with
  `state` one of `"running"`, `"blocked"`, `"done"`. Absent key means the Mac does not model
  subagents.
- `WireSession.openPromptAgent: String?`: the agent whose file holds `openPromptCall`. Nil means
  the parent transcript, which is today's meaning.
- `activityChanged` carries both, as it carries `openPromptCall` now.
- `timeline.page` request gains `agent: String?`. With it set, `TimelineService` pages that
  subagent's file with `sidechain: true`. It is used only for the blocked agent's tail, not for
  browsing (drill-in is a non-goal).
- `prompt.answer` gains `agent: String?`.

The prompt is still derived on both ends and never sent. The phone derives the card from the
subagent page with the same `OpenPrompt.find`. The Mac re-derives from the same file before
typing.

### 4.5 Answering

`PromptService.answer(session:agent:call:answer:token:)`:

1. Resolve the transcript: the subagent's file when `agent` is set, else the parent's.
2. Re-derive the open call from that file (`openPrompt(inSubagentTail:)` for a subagent).
3. Refuse `prompt_changed` unless it equals `call`. When `agent` is set, also refuse unless
   `pendingDialog[S]` names the same agent and call. That second check is what stops a tap from
   approving a subagent's *running* call that merely looks open. A main-transcript answer
   (`agent` nil) is checked exactly as today.
4. Drive the keys through the existing `SessionStore.answerPrompt`. The dialog is the same
   select list, so no new screen grammar is needed.

`subagent_prompt` stays as the refusal for an open subagent call that attribution has not
confirmed.

### 4.6 Phone

- **Timeline screen:** a "Subagents" section above the feed, shown when `subagents` is non-empty.
  It is a tree, collapsed by default. The path to a blocked node is expanded, and that node
  carries the card's accent.
- **Prompt card:** when `openPromptAgent` is set, the model fetches
  `timeline.page(agent:, anchor: .latest, limit: tailRecords)`, runs `OpenPrompt.find`, and
  shows the usual permission card under a header "From <type> — <description>". The answer
  frame carries `agent`.
- **Fleet row caption:** "Waiting for you — <type>: permission prompt".
- **Count badge:** unchanged, now fed by the tree's count.

### 4.7 Mac

- The session row's subagent count badge gets a popover with the same tree.
- The tooltip for a blocked subagent dialog reads "Waiting for you — <type>: permission prompt".

## 5. Errors and edge cases

- **Two dialogs in a row without leaving `waiting`.** Each raise is a new `PermissionRequest`,
  so `pendingDialog` moves. The phone sees `openPromptCall` change and replaces the card. A
  stale tap refuses `prompt_changed`, as today.
- **A subagent and the main agent both waiting.** claude shows one dialog at a time.
  `pendingDialog` follows the latest `PermissionRequest`, which is the one on screen.
- **Hook log rotated or late.** No `pendingDialog`, so this falls back to today's
  `subagent_prompt` path. It never guesses.
- **A meta.json without a jsonl, or the reverse.** Skip the node until both exist.
- **Cost on a large folder.** Bounded by the process-start filter and the stamp cache. Old files
  are skipped by mtime before any read.

## 6. Testing

- **Fixtures copy real record shapes** (`isSidechain`, `meta.json` keys, `stop_reason`) with
  invented content. Never real transcripts (memory: history scrubbed 2026-10-05). The f63f6650
  bug shipped because a fixture left out `isSidechain`.
- **Mac unit tests:** `SubagentTree` from fixture folders (done, running, resume, nesting,
  out-of-scope parent, process-start bound); attribution from hook-event fixtures (with and
  without `tool_use_id`, Esc with no hook, rotated log); `PromptService.answer` with `agent`
  (match, mismatch, running-not-blocked refusal).
- **Wire:** round-trip and absent-key decode for each new field.
- **Phone:** `./scripts/test-ios.sh` for the card from a subagent page and the tree's expansion
  rule.
- **Live check (Nate's, GUI):** a background subagent hits a Bash dialog. The phone shows the
  card with the agent's name; Allow from the phone resolves it.

## 7. Plan order

1. **Probe:** `PermissionRequest` payload and the deny record for a subagent's dialog, on the
   installed claude, in a throwaway project (clear `CLAUDE_CODE_CHILD_SESSION`). The result
   settles §4.3's fallback and §5.
2. `SubagentTree` + `SubagentWatcher` + count source (Mac only).
3. `PermissionRequest` registration + attribution + `blocked` state.
4. Wire fields + `timeline.page(agent:)` + `prompt.answer(agent:)`, in one commit.
5. Phone tree, card, caption.
6. Mac popover and tooltip.
7. Docs: ARCHITECTURE (subagent section), FOLLOWUPS (close the 2026-10-05 item).
