# Agent Adapters — Design

Flight Deck is welded to `claude`. This introduces an adapter layer so a tab can run
any coding agent, and lands `codex` as the second one. Cursor is explicitly deferred:
`cursor-agent` is not installed on this machine, so nothing about it has been verified
and nothing here is designed for it.

The abstraction is built against exactly two implementations. Some of it will be wrong
until a third agent arrives. That is accepted — the alternative (a `switch` on agent
kind inside `SessionStore`) defers the actual ask.

## 1. What already exists

`ClaudeSession` is a static-only enum with a ~10-member call surface used at ~20 sites:

    5  transcriptURL      2  shellQuoted       1  events
    3  sanitizedName      2  lockedPrefix      1  customTitle
    2  resumeCommand      1  launchCommand     1  encodedProjectDirName

That is the whole seam. `TranscriptWatcher` is already agent-neutral apart from calling
`ClaudeSession.events(inLine:sessionID:)`. `SessionStatusWatcher` polls `~/.claude/sessions`
(pid-keyed, one instance for the app). `Session` already separates tab identity (`id`)
from conversation identity (`pinnedConversationID`), which is exactly the split codex needs.

### 1.1 Findings that constrain the design

Every claim below was verified empirically against `codex` 0.142.4 (npm) and 0.147.0
(standalone) on 2026-08-17/18. They are the reason the codex path looks nothing like
the claude path.

1. **`codex app-server` speaks newline-delimited JSON-RPC on stdio.** No daemon, no
   `--remote`, no standalone install. The protocol is present in the npm build already
   installed, so this adds no install burden. A version probe guards older builds.

2. **`thread/start {cwd}` returns the thread synchronously**, including `id` and `path`
   (the rollout `.jsonl`). Identity and transcript location are known before the terminal
   exists — the claude invariant, obtained by return value instead of by minting.

3. **`thread/start` does not persist the thread.** No `threads` row and no rollout file,
   even after 5s with the app-server alive. `thread/name/set` commits it immediately, and
   must be issued to the *same* app-server process that created it. A thread that is never
   named evaporates, and `codex resume <id>` on it fails with
   `ERROR: No saved session found with ID …`.

4. **`codex resume <id>` attaches a visible TUI to an RPC-created thread.** Verified by
   disambiguation: resuming an older thread offers *its* recorded cwd, not the newest one,
   so it resolves the id it is given.

5. **Launching in the thread's own cwd suppresses the working-directory picker.** Verified
   directly: picker absent, no resume error, TUI alive.

6. **Rename is bidirectional and durable.** `thread/name/set` → OK, emits
   `thread/name/updated {threadId, threadName}`, and writes through to the state DB.

7. **Sub-agents are notified, not inferred.** `item/started` / `item/completed` carry
   `{item, threadId, turnId, startedAtMs}`. Two item types matter: `collabAgentToolCall`
   (`tool ∈ {spawnAgent, sendInput, resumeAgent, wait, closeAgent}`, `status ∈
   {inProgress, completed, failed}`, `senderThreadId`, `receiverThreadIds`, `agentsStates`)
   and `subAgentActivity` (`{agentThreadId, agentPath, kind ∈ {started, interacted,
   interrupted}}`).

8. **Codex's transcript path is date+UUID based, not cwd-derived**, so a `cd` does not move
   it. The retargeting `SessionStore.retarget` performs for claude has no codex analogue.
   Project *filing* by reported cwd is agent-neutral and unchanged.

## 2. The protocol

    protocol AgentAdapter {
        static var id: AgentID           // .claude | .codex
        static var displayName: String   // "Claude" | "Codex"

        func prepare(for: Session, options: AgentOptions) async throws -> AgentBinding
        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String
        func attach(_: AgentBinding, onEvent: @escaping (AgentEvent) -> Void)
        func detach(_: AgentBinding)
        func rename(_: AgentBinding, to: String) async throws
    }

    struct AgentBinding { let conversationID: UUID; let transcriptURL: URL? }

    // Per-agent settings payload. Claude's options are a command line; codex's are
    // typed `thread/start` params (§6). The protocol carries the union so neither
    // agent's shape leaks into the other's.
    enum AgentOptions {
        case claude(FlagSet)
        case codex(CodexThreadOptions)
    }

    enum AgentEvent {
        case title(String)
        case activity(SessionActivity)
        case subagentCount(Int)
        case turnEnded
    }

`AgentEvent` is today's `ClaudeSession.TranscriptEvent` promoted and widened.
`SessionStore` consumes only this enum and never learns which agent produced it.

`prepare` is the load-bearing addition: it establishes conversation identity *before*
anything is typed into a pty. Claude satisfies it by minting a UUID; codex by asking.

### 2.1 AgentRuntime

`attach`/`detach` live on an app-wide `AgentRuntime` per agent kind, owned by
`SessionStore` — not on a per-session object. This preserves the existing "one poller
serves N tabs" property and gives codex one `app-server` subprocess for the whole app.
Per-session runtimes would be wrong for both agents: claude's status registry is a single
flat directory, and a per-call codex app-server loses every thread it creates (§1.1.3).

Claude's runtime creates a `TranscriptWatcher` per attachment and shares the one
`SessionStatusWatcher`. Codex's runtime owns one long-lived `app-server` subprocess and
routes notifications by `threadId`.

## 3. Claude conformance

Behaviour is unchanged. The adapter is a thin shell over code that already works:

- `prepare` — mint a UUID (equal to the tab id, as today); derive `transcriptURL` via
  `encodedProjectDirName`. `encodedProjectDirName` becomes private to this adapter; it is
  a claude implementation detail and does not belong on the protocol.
- `launchCommand` / `resumeCommand` — today's `ClaudeSession` functions verbatim.
- `attach` — `TranscriptWatcher` events plus `SessionStatusWatcher` entries, merged into
  `AgentEvent`.
- `rename` — inject `/rename <name>`, with today's sanitizer and loop guard.

The existing unit suite is the regression net for this refactor and must stay green at
every step.

## 4. Codex conformance

### 4.1 prepare is a three-step transaction

    1. thread/start {cwd}            → { id, path }
    2. thread/name/set {id, title}   → commits the thread (§1.1.3)
    3. binding = { conversationID: id, transcriptURL: path }

Only then is `codex resume <id>` typed into the pty. Naming is not overhead: the tab
already has a title, and the call doubles as the commit. If the app-server dies between
steps 1 and 2 the thread evaporates, so `prepare` is treated as one transaction and a
failure inside it is a no-tab error (§4.6).

`launchCommand` and `resumeCommand` are both `codex resume <id>`, run with the pty's cwd
set to the thread's own cwd so the working-directory picker never fires (§1.1.5).

### 4.2 Status mapping

| Codex notification                        | `SessionActivity`                  |
|-------------------------------------------|------------------------------------|
| `turn/started`                            | `.busy`                            |
| `turn/completed`                          | `.idle` + `.turnEnded`             |
| `thread/status/changed`                   | authoritative override             |
| approval `ServerRequest` (exec / permissions) | `.waiting`                     |
| no process running                        | `nil` — same "nothing running" as claude |

`.turnEnded` drives unread marking through the existing `SessionReadPolicy`, unchanged.

### 4.3 Sub-agent count

Recomputed, not accumulated. `collabAgentToolCall.agentsStates` carries the full current
state of the target agents on every notification, so the count is derived from the latest
payload rather than incremented and decremented. This is strictly more robust than claude's
`outstandingAgents` set, which needs turn-boundary clearing to correct drift; codex needs
no such correction.

### 4.4 Rename

Outbound `thread/name/set`, inbound `thread/name/updated`. The loop guard in
`applyExternalTitle` stays and is now trivially satisfied — the echo is byte-identical
because there is no shell round-trip to mangle it. The sanitizer still runs (titles are
displayed), but its shell-metacharacter stripping is inert on this path.

### 4.5 Auto-resume and re-pinning

Mirrors claude's `--resume || --session-id` fallback: `thread/read` the persisted id; if
the thread is gone (deleted or archived), run `prepare` again and re-pin. An app-server
crash is recovered the same way — restart it and re-`attach`, since all durable state
lives in codex's own DB.

### 4.6 Launch gates and failure

Three gates exist; the decision is to suppress only the one that has a single sane answer.

- **Working-directory picker** — structurally avoided by launching in the thread's cwd.
- **Directory trust** and **hooks review** — rendered in the terminal for the user. Both
  are decisions about running code outside the sandbox; Flight Deck does not answer them.

Failure splits by whether a terminal exists:

- **Hard failure** (not logged in, spawn failure, version too old): no tab is created and
  an alert names the cause. Creating a tab that silently degrades to a local-only title is
  the exact class of bug this codebase has been fixing.
- **Spawned but blocked on a gate**: the session is created and the terminal shows the
  prompt. Title and status arrive via **reconcile-on-first-contact** — the first
  notification of any kind for that thread triggers a `thread/read` whose authoritative
  title and status are applied. No polling.

## 5. Model and persistence

- `Session.agent: AgentID`, defaulted to `.claude` when decoding. Old snapshots migrate by
  omission; no version bump.
- `pinnedConversationID` holds the codex thread id unchanged — codex ids are UUIDv7 and
  parse as `UUID`, and the field already tolerates diverging from `id` (that is what
  re-pinning does). For claude `id == pinnedConversationID` at birth; for codex they differ
  from the start.
- `transcriptDirectory` stays claude's (it is the input to path derivation). A new
  `transcriptPath: String?` carries an absolute path for agents that report one.
- `retarget` stays claude-only (§1.1.8).

## 6. Preferences and the Agents tab

`Preferences.agents: [AgentSettings]` is an ordered array whose position *is* the hotkey
mapping. `AgentSettings = { id: AgentID, options: AgentOptions }` (§2). Migration: today's
`globalFlags` becomes the claude entry's `.claude(FlagSet)`; `projectFlags: [String: FlagSet]`
becomes `[String: [AgentID: AgentOptions]]` with existing values landing under claude.

**Codex needs no flag machinery.** Its interesting options — model, sandbox, approval
policy, cwd, add-dir, personality, config overrides — are all `ThreadStartParams` fields,
so they are typed RPC params, not a command line — carried as `CodexThreadOptions` in
`AgentOptions.codex`. No catalog, no parser, no serializer, no shell quoting. `ClaudeFlagCatalog`, `ClaudeFlagParser`, `ClaudeFlagSerializer` and
`ClaudeFlagQuoting` stay exactly as they are, scoped to claude.

`ClaudeSettingsTab` becomes `AgentsSettingsTab`: a reorderable list on the left
(`.onMove`), the selected agent's options on the right. Claude's pane is today's
`FlagEditor`; codex's is a small typed form.

### 6.1 Hotkeys and the New Session button

Order in the list defines the shortcut: position 1 is ⌘N, position 2 ⌘⇧N, position 3 ⌘⇧⌥N.

Menu items are static — three items, one per position, each with its own
`.keyboardShortcut` and a label bound to whichever agent occupies that slot.

The sidebar button is the dynamic one. It reads `New <Agent> Session`, defaulting to the
first agent, and **both its label and its displayed shortcut change while modifiers are
held**. An `NSEvent` `.flagsChanged` monitor feeds a published modifier state that the
button renders from. The button already switches label and shortcut between Add Project
and New Session, so the pattern exists.

## 7. Testing

- Adapter conformances get pure-logic tests in the style of `ClaudeSessionTests`: command
  construction and event mapping, no processes.
- A `FakeAgentRuntime`, mirroring `SpyInjector`, lets `SessionStore` tests cover both
  agents without spawning anything.
- The codex JSON-RPC client is tested against **recorded fixtures** of real notification
  payloads captured during the spike — not a live `codex`.
- One opt-in integration test against a real `app-server`, skipped by default like the
  existing skipped test.
- The claude suite must stay green at every step of the refactor; it is the only thing
  standing between this change and a regression in the path that already works.

## 8. Risks

- **The abstraction has two data points.** Codex is push-based and RPC-driven; claude is
  poll-based and text-driven. If a third agent is neither, `AgentEvent` is the piece most
  likely to need widening.
- **`app-server` and the v2 protocol are marked experimental** and codex ships often. The
  protocol is generated (`generate-json-schema`, `generate-ts`), which is a good stability
  signal, but a version probe and a clear failure path are required, not optional.
- **Thread commit is undocumented behaviour.** §1.1.3 was found by experiment, not from
  docs. If codex changes when a thread is persisted, `prepare` breaks. The integration
  test exists mainly to catch that.

## 9. Out of scope

- Cursor. Nothing about `cursor-agent` has been verified.
- A codex flag *catalog* in the claude sense; codex options are RPC params.
- Worktree/cwd retargeting for codex (§1.1.8).
- The `app-server daemon` / `--remote` hybrid. Unnecessary: `thread/start` plus
  `codex resume` gives both identity and a visible TUI without it.
