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
| **A (chosen)** | Second `FleetSocketServer` instance in local mode: unix socket, `0600`, same frames | Same handlers, no pairing ceremony, trust = file permissions (the argument `AnswerTriggerSocket` already makes) |
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
<state dir>/control.sock  (0600; control-debug.sock for Debug)
   │
FleetSocketServer (local instance) ── same accept/attach/replay code
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
- `FleetSocketServer.startLocal(path:)` starts an instance in **local mode**: one `NWListener`
  at `.unix(path:)` over line parameters. **A separate instance, not a second listener on the
  phone's.** The phone instance's `stop()`, which every arm, expiry and revocation calls
  through `reloadKeys`, cancels every connection it holds. Sharing it would drop every
  `flightdeck tail` whenever a phone paired.
  - It refuses paths over 103 bytes (the `sockaddr_un` limit `AnswerTriggerSocket` enforces).
  - It probes an existing file by connecting to it. **A live socket is refused
    (`FleetSocketError.inUse`), never unlinked**, so a second app instance sharing the state
    directory cannot take over the first one's socket. A dead file is unlinked.
  - It sets the file to `chmod 0600` after binding and unlinks the file on `stop()`.
- **No peer-uid check.** `NWConnection` does not expose its socket descriptor, so
  `getpeereid` cannot be called. Authorization is the file mode inside the user's
  `~/Library`, the same argument `AnswerTriggerSocket` makes.
- `FleetAttachment` gains `isLocal: Bool` and `caller: String?`. The local instance sets both.
  The phone instance ignores any `caller` a peer sends. `FleetService` keeps local attachments
  out of everything phone-shaped:
  - `attachedSlots` and the prompt-lifecycle client counts. These come only from the phone
    instance, so this holds by construction.
  - `phoneRequest` asks. Same: they go only through the phone instance.
  - `viewing` presence. A local `viewing` is acked and ignored. Otherwise a
    `flightdeck tail` would light the phone badge.
- `ClientFrame.hello` gains an optional `caller: String?` (the scope token, below). Additive
  and optional, so every existing phone's `hello` still decodes.

### 2. App: listener, environment, scope

- `FleetService` owns a second `FleetSocketServer` for local mode and starts it at
  `<state dir>/control.sock` (`control-debug.sock` in a Debug build, so the two builds never
  compete for one path). It runs independently of pairing state. Preference
  `FlightDeckControlSocket` (default **on**) turns it off. Replicator events are broadcast to
  both instances, and both share the same `onHello`/`onCommand`/`onRequest` closures.
- **Tab environment** (in `SessionStore.launchEnvironment`, applied with the adapter's half so
  the Shell pane cannot override it):
  - `FLIGHT_DECK_SESSION_ID` — the tab's UUID.
  - `FLIGHT_DECK_CONTROL_SOCKET` — the absolute socket path. With this, a tab always reaches
    the app instance that launched it, even when Debug and Release share a state directory.
  - `FLIGHT_DECK_CALLER` — `<session-uuid>.<hex HMAC-SHA256(install secret, session-uuid)>`.
    **Derived, not stored or regenerated.** Detached sessions (fd-abduco) outlive an app
    relaunch and keep the environment they were launched with, so a token minted per launch
    would be stale in every surviving tab after a restart. The install secret is 32 random
    bytes kept in `FlightDeckControlSecret` in the app's defaults, and verifying a token needs
    no registry.
- **`ControlScope`** — a pure value type, unit-tested on its own:
  - Preference `FlightDeckAgentControlScope`: `full` (default) · `ownSession` · `readOnly`.
  - At level `full`, everything is permitted, whoever the caller is.
  - Otherwise: a valid token scopes the connection to its session. **No token means a human's
    shell and is `full`.** A token that is present but fails verification **fails closed**:
    every command and every writing request is refused.
  - `ownSession`: read requests are allowed. Commands are allowed only when their target
    session is the caller's own. `newSession`, `reopenClosed`, `setProjectCollapsed` and the
    `openConversation` request are refused, because the last one opens a tab. `viewing` is
    always acked. `readOnly`: every command except `viewing` is refused, and so is
    `openConversation`.
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
- `FleetSocketServer` local mode, in-process: bind under a short temp path, hello → snapshot
  → event replay, a dead socket file is replaced, a live one is refused, the file mode is
  `0600`, and the 103-byte limit is enforced.
- Local attachments are absent from `attachedSlots` and phone presence, and a phone key
  reload does not drop a local connection. Confirm each test fails against the unguarded code
  first.
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
