# `flightdeck` CLI — local read-write control of the running app

Date: 2026-09-24 · Status: design, awaiting review

## Goal

A command-line client, `flightdeck`, that reads and drives the live running Flight Deck in
real time: list the fleet, tail live changes, prompt/create/close/rename sessions, answer
prompts, resolve plan gates, page timelines, search. Primary consumer: **agents running inside
Flight Deck tabs scripting the fleet** (full reach by default), with an **optional scope
restriction**. Secondary: a human at a shell.

**Hard requirement: one interface.** The CLI speaks the phone's protocol — `ClientFrame` /
`ServerFrame` from `Sources/FleetKit/Frames.swift` — through the same `FleetSocketServer`
closures `FleetService` already wires. Only the transport and the authentication differ. Any
command or request added for the phone reaches the CLI with no extra work, and vice versa.

## Non-goals (v1)

- A second, CLI-specific verb set or protocol (JSON-RPC, HTTP+SSE). Rejected: it would have to
  be kept in sync with the phone's by hand.
- Remote (off-machine) CLI access. The phone path already covers remote.
- A security sandbox between agents. See **Scope** — it is a guardrail, and says so.
- Retiring `answer-trigger.sock`. It stays as-is; migrating `scripts/answer-trigger.sh` onto
  `flightdeck` is a follow-up.

## Approaches considered

| | Transport | Verdict |
|---|---|---|
| **A (chosen)** | Second listener on `FleetSocketServer`: unix socket, `0600`, peer-uid check, same frames | Same handlers, no pairing ceremony, trust = file permissions (the argument `AnswerTriggerSocket` already makes) |
| B | CLI pairs as a "local device" over loopback TLS-PSK | Zero new server code, but the CLI needs TLS-PSK, and a local slot pollutes arming, revocation and presence |
| C | Separate local JSON-RPC / HTTP API | Fails the one-interface requirement |

### Spike result that shapes A

Probed 2026-09-24 (throwaway, scratchpad): `NWListener` on `.unix(path:)` with plain stream
parameters connects fine; **adding `NWProtocolWebSocket` to the stack fails the client with
`ECONNABORTED` (POSIX 53)** before any message. So the local transport cannot reuse
`FleetSocket`'s WebSocket framing. It carries the same Codable frames as **newline-delimited
JSON**, framed by a small `NWProtocolFramer` so both ends still get whole messages from
`receiveMessage` — the rest of `FleetSocket`'s send/receive shape is unchanged.

## Architecture

```
flightdeck (CLI, Swift, links FleetKit)
   │  NDJSON ClientFrame/ServerFrame over unix socket
   ▼
<state dir>/control.sock  (0600, peer uid == our uid)
   │
FleetSocketServer ── second listener, same accept/attach/replay path
   │  onHello / onCommand / onRequest   (unchanged closures)
   ▼
FleetService.apply / request switch  ── + ControlScope check for local callers
   ▼
SessionStore
```

### 1. FleetKit: local transport

- `FleetLineFramer` (`NWProtocolFramer`): splits on `\n`, one JSON object per line, enforcing
  `TimelineLimits.maximumMessageSize` — without that cap a peer that never sends `\n` could
  make the reader grow a buffer indefinitely.
- `FleetSocket` gains a transport choice (`.webSocket` / `.lines`) at the one place parameters
  are built; send/receive stay one code path over `NWConnection` messages.
- `FleetSocketServer.startLocal(path:)` binds a second `NWListener` at `.unix(path:)`. Refuses
  paths over 103 bytes (same `sockaddr_un` limit and message as `AnswerTriggerSocket`).
  `unlink`s a stale file before binding, `chmod 0600` after, `unlink`s on `stop()`.
- **Peer check on accept:** read `LOCAL_PEERCRED` / `getpeereid` from the connection's socket;
  drop anything whose uid ≠ `getuid()`. Also record `LOCAL_PEERPID` for logs only.
- `FleetAttachment` gains `origin: .paired(slot: UUID?) | .local(pid: pid_t?)`. Local
  attachments are **excluded** from everything phone-shaped: `attachedSlots`, the "phone
  attached" UI, `phoneRequest` asks (`logs`), `viewing` presence (a local `viewing` is acked
  and ignored), and the client count passed to `promptLifecycle.observe` — without this, a
  `flightdeck tail` would count as a phone watching a prompt, which it is not.
- `ClientFrame.hello` gains an optional `caller: String?` (the scope token, below). Additive
  and optional, so every existing phone's `hello` still decodes.

### 2. App: listener, environment, scope

- `FleetService` starts the local listener at `<state dir>/control.sock` whenever it runs, and
  independently of pairing state. Preference `FlightDeckControlSocket` (default **on**) turns
  it off.
- **Tab environment** (in `SessionStore.launchEnvironment`, applied with the adapter's half so
  the Shell pane cannot override it):
  - `FLIGHT_DECK_SESSION_ID` — the tab's UUID.
  - `FLIGHT_DECK_CONTROL_SOCKET` — the absolute socket path. With this, a tab always reaches
    the app instance that launched it, even when Debug and Release share a state directory.
  - `FLIGHT_DECK_CALLER` — a random per-session token, held in memory only and regenerated at
    launch.
- **`ControlScope`** — a pure value type, unit-tested on its own:
  - Preference `FlightDeckAgentControlScope`: `full` (default) · `ownSession` · `readOnly`.
  - Applies only to local connections whose `hello` presented a known `caller` token. The
    token resolves to the calling session. A local connection with no token (a human's shell)
    is always `full`.
  - `full`: everything. `ownSession`: requests are allowed; commands are allowed only when the
    target `id` is the caller's own session; `newSession`, `reopenClosed`, `openConversation`
    and `setProjectCollapsed` are refused. `readOnly`: every `cmd` is refused.
  - Refusal is `err(cid, "out_of_scope")`, checked in `FleetService` before `apply`, so there is
    one enforcement point and `apply` itself is unchanged.
  - **This is a guardrail, not a sandbox, and the preference UI says so.** Any process running
    as the user can leave out the token or read another process's environment. What it stops
    is a well-behaved agent reaching past its own tab by mistake.
- **Selection rule:** local commands follow the client-selection rule, as the phone's do:
  `newSession` and `openConversation` never move the desk's selection
  (`selecting: false`).

### 3. The CLI

- New `tool` target `flightdeck` in `project.yml`. Swift, links `FleetKit`, installed at
  `Flight Deck.app/Contents/MacOS/flightdeck` with rpath `@executable_path/../Frameworks`.
  `Contents/MacOS` is already on every tab's `PATH` (it is `GHOSTTY_BIN_DIR`). The binary name
  differs from `Flight Deck`, so running the CLI never boots the app (AGENTS.md rule 2).
- **Socket resolution:** `--socket` → `$FLIGHT_DECK_CONTROL_SOCKET` →
  `$FLIGHT_DECK_STATE_DIR/control.sock` → the default state dir. It sends `FLIGHT_DECK_CALLER`
  in `hello` when that variable is set.
- **`self`** resolves to `$FLIGHT_DECK_SESSION_ID` wherever a session is expected. Sessions are
  also accepted by UUID prefix or exact title; an ambiguous match fails and lists the
  candidates.
- **Output:** a table on a TTY, JSON when stdout is not a TTY or with `--json`. `tail` always
  writes NDJSON.
- **Exit codes:** `0` ok · `1` refused by the app (the wire `err` code on stderr, e.g.
  `unknown_session`, `out_of_scope`) · `2` usage error · `69` (`EX_UNAVAILABLE`) cannot
  connect.

| Command | Wire |
|---|---|
| `flightdeck ls [--project P]` | `hello(lastSeq: 0)` → `snapshot`, then disconnect |
| `flightdeck tail [--session S] [--since SEQ] [--no-snapshot]` | `hello(lastSeq:)`, stream `event(seq,…)` as NDJSON until killed; reconnects and resumes from the last seq it printed |
| `flightdeck wait S --for idle\|waiting\|gone [--timeout D]` | `tail`, folded with FleetKit's event fold; exits when the condition holds |
| `flightdeck send S "text"` | `cmd session.prompt` (fresh token) |
| `flightdeck new P [--agent A] [--account N]` | `cmd session.new` |
| `flightdeck close S` · `reopen S` · `rename S "t"` · `read S` · `unread S` · `collapse P [--off]` | the matching `cmd` |
| `flightdeck answer S '[[0,1],[2]]' [--call C]` | `cmd prompt.answer` |
| `flightdeck abort S` | `cmd prompt.abort` |
| `flightdeck plan approve\|reject S [--feedback F]` · `plan annotate S "text" [--block N]` | `cmd plan.resolve` / `plan.annotate` |
| `flightdeck timeline S [--before N\|--after N\|--around N] [--limit N]` (default `latest`) | `req timeline` |
| `flightdeck search "q" [--limit N]` · `open CONVO --project PATH` | `req search` / `req openConversation` |
| `flightdeck closed` · `options P` | `req recentlyClosed` / `req newSessionOptions` |
| `flightdeck raw '<ClientFrame JSON>'` | sends one frame and prints every reply frame for its `cid`. Covers any op that has no verb yet |

`wait` is the only command built from others. It is in v1 because orchestrating agents need
"block until that tab is idle", and without it every script would re-implement the event fold
badly.

## Error handling

- A frame the app cannot decode: the existing salvage path answers `err` by `cid` where it
  can; otherwise the connection drops and the CLI exits `1` with `undecodable`.
- App not running or socket disabled: exit `69`, and the message names the path it tried.
- `tail` survives an app restart by reconnecting with backoff and resuming from its last seq.
  If the app answers with a fresh `snapshot` (for example, replay is no longer available),
  `tail` emits it as a `{"type":"snapshot",…}` line so a consumer can tell the stream reset.
- Version skew: the CLI ships inside the app bundle, so skew only happens after a swap while
  a CLI process is still running. No check in v1: `FleetKitVersion.wire` is sent in no frame
  yet, and adding it to the wire is its own change. A skewed `tail` sees an undecodable frame,
  exits `1`, and the next invocation runs the new binary.

## Testing

All headless, in `test-unit.sh`. No GUI, no smoke run.
- `FleetLineFramer`: split lines, partial reads, oversize rejection.
- `FleetSocketServer` local listener, in-process: bind under a short temp path, hello → snapshot
  → event replay, a peer from a wrong uid (seam) is dropped, a stale socket file is replaced,
  the 103-byte limit is enforced.
- `FleetAttachment.origin`: local attachments are absent from `attachedSlots`, phone presence,
  `phoneRequest` routing, and the prompt-lifecycle client count. Confirm each test fails
  against the unguarded code first.
- `ControlScope`: the whole matrix of scope × command × own/other session, and "no token ⇒
  full".
- CLI: argument parsing and session resolution (`self`, prefix, title, ambiguity) as pure
  functions; one end-to-end in-process test of CLI client against a server with stub closures.
- Tab environment: a launched session's environment carries the three variables, and
  Shell-pane values cannot override them.

## Docs

Same branch: `docs/ARCHITECTURE.md` (a second transport on the fleet server),
`docs/HANDOFF.md` (CLI quickstart), `AGENTS.md` Commands table, and the preferences
explanation of the scope guardrail.

## Follow-ups (not v1)

- Per-session and per-project scope overrides (the sidebar context menu).
- Move `answer-trigger.sh` onto `flightdeck` and retire `answer-trigger.sock`.
- A `flightdeck` agent skill/plugin, so agents discover the CLI without being told.
