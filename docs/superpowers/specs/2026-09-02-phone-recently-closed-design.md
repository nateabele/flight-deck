# Recently Closed on the phone

## The gap

`FleetCommand.closeSession` says of its own destructiveness: "The Mac records history the
same way it does for a local close, so the recovery story is the one that already exists
rather than a second one invented for the phone."

That is true and it is also unreachable. The recovery story is ⌘⇧T, and ⌘⇧T is a keyboard
chord on a Mac. A phone that closes a tab by full-swipe has no undo of any kind — not a
shortcut, not a menu item, not a toast. The one surface the phone has for creating sessions
is each project's `+`, so that is where the undo belongs.

## What is being added

The per-project `+` menu (`FleetListScreen.newSessionMenu(for:)`) gains a
`Section("Recently Closed")` below the New rows, listing up to five of that project's
recently closed sessions, most recent first. Tapping one reopens it on the Mac.

```
  New Claude Session
  New Codex Session      ›
 ─────────────────────────
  Recently Closed
  ↩  fix the pager
  ↩  spike: sqlite index
  ↩  phone-reopen
```

**Only `.session` entries, filtered by `projectPath`.** A closed *project* stays Mac-only:
it is not in the sidebar, so it has no `+` to hang off, and reopening one from a sibling
project's menu would be an action whose result appears somewhere the user was not looking.

**Only top-level entries.** Sessions nested inside a `ClosedProject` are not offered.
Taking one out would leave that project entry half-consumed, and a later ⌘⇧T on the project
would try to reinsert a tab that is already open.

## Mac: `ClosedSessionHistory` becomes addressable

Today it is a pop-stack — `record`, `takeLast`, `isEmpty`. ⌘⇧T only ever wants the top. A
menu wants to name a specific entry, so two members are added:

```swift
/// Top-level closed sessions, most recent first. Children of a `.project` entry are
/// deliberately absent — see the spec.
var sessionEntries: [ClosedSession]

/// Removes and returns the top-level `.session` entry for `id`, or nil.
mutating func takeSession(id: UUID) -> ClosedSession?
```

Removal is not a policy choice, it is forced. `reinsertClosed` rebuilds the tab from the
recorded `Session` value, **reusing its `id`** — that is what makes the rebuilt tab resume
the real conversation. Leave the entry in place and a later ⌘⇧T inserts a second tab with
the same UUID; `locate(id)` would then find one of two and the sidebar would carry a
duplicate key. So a reopen from either surface consumes, and `takeSession` removes from the
middle of the stack while `takeLast` goes on popping whatever is now on top.

### `SessionStore`

`reopenLastClosed`'s `.session` branch — reinsert, un-collapse the project, select, persist,
defer any codex resume — is extracted into a private helper. Both the existing
`reopenLastClosed` and a new entry point call it:

```swift
func reopenClosedSession(id: UUID, directoryExists: (String) -> Bool = …)
```

A no-op when the id is not in the history. Behaviour is otherwise identical to ⌘⇧T on that
entry, including selecting the reopened tab — there is no reason for the two surfaces to
disagree about what a reopen does.

## Wire

### `WireClosedSession`

```swift
public struct WireClosedSession: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID          // the tab id; what a reopen names
    public let title: String
    public let agent: String     // AgentID.rawValue, plain String for WireSession.agent's reason
    public let projectPath: String
}
```

No `pinnedConversationID`, no `transcriptDirectory`, no working directory. `FleetSnapshot`'s
doc comment gives the rule: those fields exist to derive paths on the Mac and shipping them
puts the Mac's filesystem layout on a phone's disk for no rendering benefit. `projectPath`
is already public — `WireProject.path` carries it today.

### One global request, not one per project

- `FleetRequest.recentlyClosed` (op `"session.recentlyClosed"`, no argument)
- `ServerFrame.recentlyClosed(cid:, [WireClosedSession])` — **unsequenced**, like `page` and
  `newSessionOptions`
- `FleetCommand.reopenClosed(session: UUID)`

**Why global rather than per-project.** `newSessionOptions` is per-project because each
project resolves genuinely different rows out of preferences. Here there is one stack on the
Mac; bucketing it by `projectPath` on the phone is a filter, not a second implementation of
anything. It is also one frame per refresh instead of N — which matters, because the refresh
trigger below fires on every close.

**Why not in `FleetSnapshot`.** The same reason `newSessionOptions` is not, and a sharper
one. The history is not rebuildable from fleet events: `sessionRemoved` carries an id and
nothing else — no project path, no index, no pinned conversation — so a `FleetReplicator`
replay could not reconstruct it, and its drift assertion would fail exactly as it did the
first time this mistake was made (`NewSessionOptions.swift:38`).

### Refresh timing

`newSessionOptions` refreshes on list-appear, reconnect and foreground. Recently-closed
needs those three **plus every `sessionRemoved` fleet event**. That is the precise signal —
a close at either end emits one — and without it a session the phone itself just closed
would not appear in its own `+` menu until the app was backgrounded and brought back.
`FleetListScreen` already rebuilds search candidates on every fleet event, so the hook is
there.

### Version skew

A new phone asking an old Mac for `recentlyClosed` is already handled and needs no new
mechanism: `FleetRequest` throws on an unknown op, and `FleetSocketServer`'s `onUndecodable`
salvages a `req` into an `err` on its own `cid` rather than letting the throw take the socket
down. The phone's completion fails, `closedSessions` stays empty, and the section never
renders.

**That ordering is load-bearing.** `FleetCommand` also throws on an unknown op, and a `cmd`
is *not* salvaged — sending `reopenClosed` to an old Mac would drop the connection. It is
safe only because the command is unreachable until the request has succeeded: no answer, no
section, no row to tap. No `FleetCapability` entry is needed (that mechanism exists for the
Mac→phone direction, where an unknown `ServerFrame` tag throws on the phone), but the
dependency is written down here because a future refactor that renders the section
optimistically would break it.

### Stale taps

Between fetch and tap an entry can go: ⌘⇧T consumed it, or it aged past `depth`. The Mac
re-checks by id and no-ops. No alert — the tab is in the fleet list either way, so there is
nothing to tell the user. Same shape as `newSession`'s stale-`accountIndex` fallback.

## Phone UI

`newSessionMenu(for:)` gains, after the New rows:

- `Section("Recently Closed")` containing up to five rows, each
  `Label(title, systemImage: "arrow.uturn.backward")`.
- **Cap of 5 applied on the phone**, via `prefix(5)` — the Mac's stack depth is its own
  business, and a second cap on the wire would be a number to keep in sync.
- No entries → no section, no header, no disabled row.

**The `+`'s disabled rule does not change.** It stays
`.disabled(newSessionOptions[project.id]?.isEmpty == true)`, even though such a project might
have closed sessions to offer. Two reasons: the `Menu` uses `primaryAction`, so enabling it
would make a plain tap fire `newSession` — a guaranteed refusal, which is what the disable
exists to prevent; and a project with no live account for any agent is one whose closed tabs
`resumeExisting` would mark orphaned and never launch anyway. The row would promise a reopen
that does not happen.

## Testing

Both `scripts/test-unit.sh` and `scripts/test-ios.sh` — `Sources/FlightDeckMobile` is
touched, and the macOS run does not cover it.

**macOS (`Tests/FlightDeckTests`)**
- `ClosedSessionHistoryTests` — `sessionEntries` is most-recent-first and top-level only;
  `takeSession` removes from the middle and leaves the rest in order; a nested child's id
  returns nil.
- `ReopenClosedSessionTests` — reopening by id rebuilds the tab at its recorded index and
  un-collapses its project; a following ⌘⇧T pops the next-newest rather than the consumed
  entry; an unknown id is a no-op.
- `FleetFrameCodingTests` / `TimelineFrameCodingTests` — the request, reply frame and command
  round-trip; the reply is unsequenced.
- `FleetRequestPlumbingTests` / `FleetConnectorRequestTests` — the connector correlates the
  reply on its `cid` and resolves exactly once; a `req` an old Mac cannot parse comes back as
  `err` without dropping the socket.
- `FleetAccountEmissionTests` — no account id or home path reaches an encoded
  `WireClosedSession`.
- `NewSessionOptionsProjectionTests` (or a sibling) — the projection from
  `ClosedSessionHistory` to `[WireClosedSession]` drops nested children.

**iOS (`Tests/FlightDeckMobileTests`)**
- `FleetListScreenTests` — the section renders only with entries, below the New rows,
  filtered by `projectPath`, capped at 5.
- `FleetModelTests` — the refresh fires on `sessionRemoved`, and on the three moments
  `refreshNewSessionOptions` already uses.

## Out of scope

- Reopening closed *projects* from the phone.
- Persisting the history across a Mac relaunch — `ClosedSessionHistory`'s doc comment argues
  against it and nothing here changes that argument.
- Navigating to the reopened session. `newSession` is fire-and-forget and the tab appears in
  the list; a reopen behaves the same.
