# Session Status Indicators — Design

Date: 2026-08-11
Branch: `feat/session-status-indicators` (based on `feat/session-creation-ux` @ `58dc285`)

Sidebar rows show what each Claude session is doing: idle, working, working with N
sub-agents, blocked on a prompt, or running a background shell command. A session that
blocks for input while Flight Deck is in the background raises a system notification that
activates that session when clicked.

## 1. Where the state comes from

Claude Code maintains an **undocumented live status registry** at
`~/.claude/sessions/<pid>.json`, one file per running `claude` process:

```json
{"pid":75951,"sessionId":"a8cf5a53-…","cwd":"/Users/nate/Projects/…",
 "kind":"interactive","name":"single-window-session-creation-ux","nameSource":"derived",
 "status":"waiting","waitingFor":"permission prompt",
 "procStart":"Tue Aug 11 02:24:59 2026",
 "startedAt":1786415100341,"updatedAt":1786464881472,"statusUpdatedAt":1786464881472,
 "messagingSocketPath":"/tmp/cc-socks/75951.sock","peerProtocol":1,"version":"2.1.227"}
```

`sessionId` is the join key Flight Deck already owns — it passes `--session-id` in
`ClaudeSession.launchCommand`. No transcript parsing is needed for activity state.

### 1.1 The status derivation (verified against the 2.1.227 binary)

```js
function status(e) {
  let w = waitingFor(e);
  if (w !== undefined) return { status: "waiting", waitingFor: w };
  return { status: e.isLoading || e.delegatedActive ? "busy" : "idle" };
}
function waitingFor(e) {
  if (e.sandboxHostPrompt || e.workerSandboxPrompt) return "sandbox request";
  if (e.elicitationPrompt)                 return "input needed";
  if (e.managedSettingsSecurityPrompt)     return "dialog open";
  if (e.topDialogWaitingFor !== undefined) return e.topDialogWaitingFor; // default "permission prompt"
  if (e.pendingWorkerRequest)              return "worker request";
  if (e.pendingSandboxRequest)             return "sandbox request";
  if (e.isShowingLocalJSXCommand)          return "dialog open";
}
// at the write site:
status = (status === "idle" && anyRunningLocalBashTask) ? "shell" : status;
```

Four statuses, not three: `idle`, `busy`, `waiting`, **`shell`**. `shell` means the model
turn finished but a backgrounded Bash task is still running — visually "idle but not
finished", a genuinely distinct row state.

`waitingFor` values: `permission prompt` (most common, and the fallback for any unmapped
dialog kind), `input needed`, `dialog open`, `goal proposal`, `sandbox request`,
`worker request`. Only `permission prompt` and `input needed` were observed live; the rest
are read from the binary's label map.

### 1.2 Write mechanics that constrain the reader

The writer is `await fs.writeFile(path, …)` — a **non-atomic, in-place** read-modify-write
serialized through a promise chain. Two consequences drive the design:

1. A reader can observe a **torn file**. Parse failure must be tolerated, not treated as
   "session gone".
2. Because the write is in-place with no create/rename, a **directory vnode watch never
   fires** on a status change. Polling is the only reliable mechanism.

### 1.3 What the registry does *not* carry

Sub-agent activity. `delegatedActive` is OR'd into plain `busy`, and there is no agent
count field (confirmed against the union of keys across all live session files). Sub-agent
count needs a second source — see §4.

## 2. Model

New file `Sources/FlightDeck/SessionStatus.swift`, pure and `Equatable`:

```swift
enum SessionActivity: String, Equatable { case idle, busy, waiting, shell }

struct SessionStatus: Equatable {
    var activity: SessionActivity
    var waitingFor: String?
    var subagentCount: Int = 0
}
```

Absence of status — no `claude` running, dead process, undecodable file — is `nil` in the
store's map rather than a case. It renders no icon, which is distinct from `idle`.

## 3. Reading the registry

**`ClaudeStatusFile`** — pure decoding, zero I/O:
`decode(_ data: Data, expectedPID: pid_t) -> Entry?`.

- Rejects a pid/filename mismatch (Claude's own reader does this, and unlinks the file).
- An **unrecognized `status` string yields `nil`**, not a guessed case. This is the
  graceful-degradation path if a fifth status is added upstream.
- `Entry` carries `pid`, `sessionID`, `activity`, `waitingFor`, `kind`, `startedAt`.

**`SessionStatusWatcher`** — one instance for the whole app, not one per session. A 500 ms
`DispatchSourceTimer` (matching `TranscriptWatcher`'s existing cadence) scans
`~/.claude/sessions/*.json`, `stat`s each, and re-reads only files whose mtime moved.
Emits `[UUID: Entry]` keyed by `sessionId`.

Three guards:

- **Torn reads** — a decode failure keeps the last known status rather than dropping to
  "gone". Given §1.2 this will happen occasionally.
- **Dead processes** — `kill(pid, 0)` filters files leaked by a crash. Claude unlinks only
  on clean exit. Full `procStart` PID-reuse verification is deliberately *not* implemented:
  lookups are keyed by `sessionId`, so a reused PID would also have to carry our exact
  session UUID to mislead us.
- **Duplicates** — if two files claim one `sessionId` (crash, then resume), take the
  highest `startedAt`.

The projects root is already injectable on `SessionStore` for tests; the sessions root gets
the same treatment so tests point at a temp directory.

## 4. Sub-agent count

`TranscriptWatcher` already tails the right file and discards everything that isn't a
title. Widen the parse to a `ClaudeSession.TranscriptEvent` enum — `.title(String)`,
`.agentStarted(id)`, `.agentFinished(id)`, `.turnEnded` — keeping all parsing in the pure
`ClaudeSession` namespace.

Record shapes:

- **start** — `assistant` record, `message.content[]` element with
  `{"type":"tool_use","name":"Agent","id":"toolu_…"}`.
- **finish** — `user` record, `message.content[]` element with
  `{"type":"tool_result","tool_use_id":"toolu_…"}`.
- **turn end** — `{"type":"system","subtype":"turn_duration"}`.

The watcher holds a `Set<String>` of outstanding `Agent` tool_use IDs: insert on tool_use,
remove on matching tool_result, **clear on `turn_duration`**. That clear is the self-heal —
a miscount from attaching mid-turn corrects itself at the next turn boundary instead of
sticking.

Count is reported only alongside `busy`; `waiting` and `idle` render their own icon.

### 4.1 Accepted limitations

- Agents launched before Flight Deck attaches are uncounted until the next turn boundary.
- Backgrounded agents (`run_in_background: true`) receive an immediate
  `{"status":"async_launched"}` tool_result, so they stop counting while still running.
- Nested agents live in the sub-agent's own transcript, so only top-level agents count —
  which is the intent.

Neither of the first two affects this repo's workflow, which uses foreground agents.

## 5. Store integration

`SessionStore` gains:

```swift
@Published private(set) var statuses: [UUID: SessionStatus] = [:]
func status(for id: UUID) -> SessionStatus?
```

The store owns the single `SessionStatusWatcher` alongside its existing per-session
transcript watchers. The status watcher writes `activity`/`waitingFor`; the transcript
watcher writes `subagentCount`; the store merges. Rows read `store.status(for:)`, so the
existing `@ObservedObject` wiring drives redraw with no new plumbing.

`closeSession` clears the session's entry so a closed row leaves no residue.

## 6. Row UI

New `SessionStatusIcon` view. Real SF Symbols via `Image(systemName:)` and a real
`ProgressView` — no emoji, no unicode glyphs.

| State | Renderer | Tint | Tooltip |
|---|---|---|---|
| `idle` | `circle.fill` | `.secondary` | "Idle" |
| `busy` | `ProgressView` `.circular` `.mini` | accent | "Working" |
| `busy` + N | above + `Text("\(n)")` `.caption2` `.monospacedDigit()` | accent | "Working — N subagents" |
| `waiting` | `questionmark.circle.fill` | `.orange` | "Waiting for you — \(waitingFor)" |
| `shell` | `terminal.fill` | `.green` | "Background command running" |
| `nil` | nothing rendered | — | — |

All three symbols ship in SF Symbols 1.0 and are safe on the macOS 14 deployment target.
Icons get `.imageScale(.small)` and `.symbolRenderingMode(.hierarchical)`. Each carries
`.help(…)` for the tooltip and a matching `.accessibilityLabel(…)`, plus a stable
`.accessibilityIdentifier("session-status")`.

The close button, currently unconditional in `SessionRow`, becomes hover-gated. The "slide
left" falls out of layout rather than a manual offset — inserting the close button after
the icon pushes the icon left on its own:

```swift
HStack(spacing: 4) {
    titleOrEditor
    Spacer()
    SessionStatusIcon(status: store.status(for: session.id))
    if isHovered { closeButton }
}
.onHover { isHovered = $0 }
.animation(.easeOut(duration: 0.12), value: isHovered)
```

The idle dot stays put and slides with the rest, so row geometry never changes shape
between states.

**Known wart:** `.onHover` does not fire during trackpad scrolling, so a row can retain a
stale hover state after a scroll. Out of scope; the fix is a tracking-area
`NSViewRepresentable`.

## 7. Notification

`SessionNotifier`, behind a `Notifying` protocol. The protocol seam is load-bearing:
instantiating `UNUserNotificationCenter.current()` outside a signed bundle traps, which
would take the unit-test bundle down.

Policy is a **pure function** over `(old: SessionStatus?, new: SessionStatus?, appActive: Bool)`
so the interesting logic is testable with no notification framework:

- Fire on a transition **into** `waiting` while Flight Deck is not frontmost.
- Never re-fire while the session stays `waiting`.
- **Withdraw** the delivered notification when the session leaves `waiting`, so returning
  to the machine doesn't show a banner for a prompt that already resolved.

Content: title = session title, body = the `waitingFor` text. `userInfo["sessionID"]`
carries the UUID. The **request identifier is the session UUID string**, so a second prompt
for the same session replaces its banner rather than stacking, and withdrawal targets
exactly one notification. The `UNUserNotificationCenterDelegate` lives on `AppDelegate` and
must be registered before launch completes; the click handler calls
`NSApp.activate(ignoringOtherApps:)`, selects the session, and orders the window front.

**Scope:** notifications fire only for sessions present in the store. The registry lists
*every* `claude` process on the machine, including ones the user runs in other terminals;
those are ignored entirely — both for notifications and for icons.

Authorization is requested once at first launch. Denial degrades silently to icons-only.

## 8. Testing

Unit tests target the three pure cores:

- **`ClaudeStatusFile`** — each of the four statuses; unknown status → `nil`; torn/partial
  JSON → `nil`; pid/filename mismatch → `nil`; missing `waitingFor` on a `waiting` entry;
  duplicate `sessionId` resolution by `startedAt`.
- **Sub-agent set machine** — start, finish, interleaved starts, unmatched result,
  `turn_duration` reset, a tool_result for an unknown id.
- **Notification policy** — the transition table, including suppression while active,
  no re-fire on `waiting`→`waiting`, and withdrawal on `waiting`→`busy`.

`SessionStatusWatcher` gets an integration test against a temp sessions root: write a file,
drain, assert the mapped status; rewrite it, drain, assert the change.

A UI test asserts the status icon exists by identifier and that hovering a row reveals
`close-session`.

## 9. Documentation

`docs/ARCHITECTURE.md` still describes the pre-sidebar walking skeleton and does not
mention `SessionStore`, `SessionSidebar`, or `TranscriptWatcher`. This work adds the status
pipeline to it. Retroactively documenting the multi-session refactor is explicitly out of
scope.

## 10. Risks

- **Undocumented, unversioned surface.** The registry has a `peerProtocol` field, but it
  governs the socket, not the file schema. A Claude Code update could rename fields or add
  a status. Mitigations: unknown status → `nil`, decode failure → last-known, and the
  sidebar degrades to no icon rather than a wrong one. Everything else in Flight Deck keeps
  working.
- **`messagingSocketPath` is not a status channel.** It is the peer-messaging transport for
  `SendMessage`/`ListAgents`. Do not reach for it here.
- **Notification entitlement.** Requires a signed bundle; the release build is signed, but
  a raw `swift build` binary is not. The protocol seam keeps that out of the test path.
