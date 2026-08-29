# A live query interface for self-diagnosis

## 1. Why

Three failures in two days, each of which took a human-plus-Claude investigation that a
single query would have answered:

| Symptom | What was actually true | What made it hard |
|---|---|---|
| Phone said "no agent running" on a live tab | `activity == "shell"`, refused by a guard written against a false premise | The status was fine; the *interpretation* was wrong, and nothing exposed it |
| A tab on a second account showed no status at all | Its `SessionStatusWatcher` reads a different `CLAUDE_CONFIG_DIR` | Per-account watchers are invisible from outside the process |
| `mobile-search` created from the phone never ran | `makeSurface` returned nil because **the screen was locked**, and the tab was created anyway | `surfaces[id]` is in-memory only. Nothing outside the app can see whether a tab has a terminal |

The through-line: **the decisive fact was always in memory and never observable.** Diagnosis
meant reading `sessions.json`, correlating `ps`, and walking status files across two config
homes — and even then, "does this tab have a surface?" could only be answered by reading source.

This spec adds a local HTTP interface that answers those questions live, and can perform a
small, closed set of repairs.

## 2. Scope

**In:** read endpoints over store state; four repairs; token auth with a one-time in-app
approval; macOS only.

**Out:** the phone (v2 at the earliest); general control (prompting, renaming, creating
sessions — `FleetRequest` already does those for the phone and duplicating them here buys
nothing); anything reachable off-host.

## 3. Where it lives, and why not FleetKit

**`Sources/FlightDeck/Diagnostics/`, not `Sources/FleetKit/`.** FleetKit may import only
`Foundation`, `Network` and `Security`, and that rule is enforced by compiling it for iOS in
`build-ios.sh`. This server needs `SessionStore` internals and AppKit (for the approval
prompt), so putting it in FleetKit would break the iOS build — which is exactly what that
constraint exists to catch.

Structure follows `FleetService`, whose doc comment states the pattern to copy: the server
stays testable without a store, and the store stays testable without a server.

```
DiagnosticsServer     NWListener on 127.0.0.1 + minimal HTTP/1.1. No store reference.
DiagnosticsService    Binds server to SessionStore. Owns auth, routing, JSON shaping.
DiagnosticsReport     Pure value type: the snapshot. Buildable from a store in tests.
DiagnosticsGrants     Token issue/verify/revoke, persisted in preferences.
```

`Network.framework` rather than a server dependency: `FleetSocketServer` already establishes
the `NWListener` pattern in this codebase, and we control both ends of this connection, so
the HTTP subset needed is a request line, one header, and a JSON body.

## 4. The report — what it exposes

One endpoint carries the diagnosis; the rest are conveniences over the same data.

```
GET /report          everything below, one object
GET /tabs            per-tab rows only
GET /tabs/{id}       one tab
GET /agents          live agents, including those matching no tab
GET /health          liveness + version, the only unauthenticated route
```

Per tab, and the first three fields are the ones no existing tool can see:

| Field | Why it is here |
|---|---|
| `hasSurface` | **The field that would have solved `mobile-search` instantly.** In-memory only today |
| `hasInjector` | The other half of the prompt guard's condition |
| `watcherPresent` | Whether *any* watcher is scanning this tab's account's config home |
| `configHome` | Which `CLAUDE_CONFIG_DIR` this tab's account resolves to |
| `activity`, `hasBackgroundWork`, `waitingFor`, `subagentCount` | The status, decomposed |
| `agentPID`, `procStart` | The process the anchor resolves to, if any |
| `accountID`, `accountAlive` | Catches a tab stamped with a removed account |
| `pinnedConversationID`, `transcriptDirectory` | Catches a pin that stopped following its thread |

Plus fleet-level rows: `orphanedAgents` (live `claude` whose session id matches no tab —
`smart-search` is in that state now), `watchers` (one per account, with last drain time), and
`screenLocked`.

`screenLocked` earns its place: it is the cause of the third failure above, and a tab created
while locked is a tab with no terminal. A report that shows a surfaceless tab *and* a locked
screen has stated the whole diagnosis in two fields.

## 5. Repairs

```
POST /tabs/{id}/respawn-surface
POST /tabs/{id}/close
POST /agents/{pid}/reap
POST /registry/tick
```

Three reuse existing store paths — `closeSession(_:recordingHistory:)`,
`reapSession(_:process:context:)` and the per-account `SessionStatusWatcher.drain()`. They are
endpoints over machinery that already works.

**`respawn-surface` is new code, and is the substantive part of this spec.** Nothing today can
build a terminal for an existing tab: `surfaces[session.id] = surface` in `insertSession` is
the only write to that dictionary, there is no retry, and selecting a tab does not create one.
A tab that loses `makeSurface` is dead permanently. Respawn does what `insertSession` does —
build the config, call `provider.makeSurface`, register the process, report the size, type the
launch command, start watching — for a session that already exists.

Two rules it must honour, both learned from the failure it exists to repair:

1. **Refuse when the screen is locked** (`409`, with `screenLocked` as the reason). A locked
   session has no window server; retrying there is how the corpse was created.
2. **Refuse when the tab already has a surface** (`409`). Respawning a live tab would orphan a
   running agent and leave two shells writing one transcript.

## 6. Auth

**A token, issued once, after an in-app approval.**

```
first call, no token   -> 401 + a pending grant; the Mac shows an approval sheet
approve                -> token minted, returned in that call's retry, stored by the client
every later call       -> Authorization: Bearer <token>, works locked or unlocked
```

Grants live in preferences with a label and issue date, and are revocable in Settings. The app
stores a hash, never the token.

**Three limits, stated plainly rather than implied:**

- **The client name in the prompt is self-asserted.** A TCP socket cannot read peer
  credentials, so the sheet displays whatever the caller sent. Any local process could claim to
  be `claude (debug)`. A Unix socket would fix this; HTTP was chosen for client simplicity, and
  this is the price.
- **The prompt gates issuance, not possession.** The client must keep its token somewhere
  readable — a `0600` file — so on a single-user Mac any process running as that user can
  eventually read it. The security value here is "one deliberate approval, revocable, no
  accidental access", not isolation.
- **First approval requires an unlocked screen.** Accepted deliberately: you pair once at the
  desk, and every later query works locked, which is when diagnosis is actually wanted.

## 7. Discovery and lifecycle

Default port 7777, settable in preferences. On bind failure the app does **not** silently pick
another port — it reports the failure the same way a launch failure is reported, because a
diagnostics interface that quietly isn't listening is worse than one that is absent.

The live port and pid are written to
`~/Library/Application Support/Flight Deck/diagnostics.json` so a client never guesses. That
file carries no secret.

Listener runs for the app's lifetime, bound to `127.0.0.1` only.

## 8. Testing

- `DiagnosticsReport` is a pure value built from a store: assert `hasSurface` false for a tab
  whose `makeSurface` returned nil, and true for one it did not — the exact discrimination no
  existing test makes.
- Auth: no token → 401 and a pending grant; approved token → 200; revoked token → 401;
  `/health` reachable unauthenticated.
- `respawn-surface`: refuses with `screenLocked` when locked; refuses when a surface exists;
  on success the tab gains a surface and an agent appears in the next report.
- Orphan detection: a status file whose session id matches no tab appears in `orphanedAgents`.
- The server parses a request and rejects a malformed one without wedging the listener.
- `build-ios.sh` still succeeds — the guard that this code did not drift into FleetKit.

## 8.1 Sequencing — two pieces should land first, and independently

The bug that prompted this spec has a fix that does not need a server, and shipping it behind
one would be backwards:

1. **Make a nil surface loud.** `insertSession` treats `makeSurface` returning nil as benign —
   it creates, persists and broadcasts the tab anyway. Report it through the existing
   `AgentLaunchFailureReporting` path and either refuse to create the tab or mark it visibly
   broken. Small, and it converts every future instance of this from an investigation into an
   alert.
2. **`respawn-surface` as a store method**, reachable from the sidebar's context menu. It is
   the substantive new capability here, it is useful with no HTTP anywhere near it, and the
   endpoint in §5 then becomes a thin call over an already-tested method.

The server, auth and report can follow. Both items above are prerequisites for §5 regardless,
so this is ordering rather than added scope.

## 9. Deliberately not in v1

- Phone access. It would put the desktop's trust path through the phone, which contradicts
  "desktop only for now".
- Streaming or subscriptions. Polling `/report` is sufficient for diagnosis and avoids a second
  replication mechanism next to `FleetReplicator`.
- Transcript content. Paths yes, contents no — that is what the phone's history channel is for.
