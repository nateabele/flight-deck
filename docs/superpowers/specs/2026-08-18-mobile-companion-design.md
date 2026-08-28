# Mobile Companion — Design

**Date:** 2026-08-18
**Status:** design, pre-implementation
**Scope of this spec:** the pairing/replication spine and the read experience (slice 1).
Later slices are sketched in §12 and get their own specs.

An iOS client that shows the fleet live, renders what each agent is doing, and — in later
slices — answers its prompts and drives it. The phone is **a thin client of Flight Deck, not
of any agent**: the Mac executes everything locally through its existing adapters and emits one
normalized stream northbound. No agent integration code ships on the phone.

## 1. Findings that constrain the design

Each was verified against this machine on 2026-08-18 rather than assumed, because two of them
overturn positions taken elsewhere.

1. **Claude approvals *are* structurally answerable.** `PermissionRequest` is a real hook event
   with a tool-name matcher. The decision contract, extracted from the `plannotator` binary
   that uses it in production, is:

   ```json
   { "hookSpecificOutput": { "hookEventName": "PermissionRequest",
       "permissionDecision": "allow" | "deny",
       "permissionDecisionReason": "…" } }
   ```

   Plannotator registers it with `matcher: "ExitPlanMode"` and `timeout: 345600` — four days —
   which is a hook deliberately blocking until a human answers in an external UI. The user's
   own global settings additionally register `PermissionRequest` with `matcher: "*"`.

   This contradicts the agent-adapter pairing document, which states three times that claude's
   waiting state is "inferred, not requested" and that approvals are "structured and answerable
   for codex; inferred and unanswerable for claude", and on that basis treats remote approval —
   "probably the single most compelling thing this pairing can do" — as codex-only. **It is
   available for both agents.** What genuinely differs is plumbing, not capability: codex
   approvals arrive as RPC requests Flight Deck already holds in-process, whereas claude's hook
   is a separate process claude spawns, so Flight Deck must ship a helper that dials back in
   (§9).

2. **A real remote terminal was ruled out on evidence, not taste.** `ghostty.h` exposes no
   byte-feed entry point: a surface's only inputs are key/text/mouse, and it always spawns its
   own child process, which iOS cannot do. Reading back out is `ghostty_surface_read_text`,
   plain text with no cell attributes — the same limitation `TextInjecting.readViewport`
   already documents. Mirroring a live terminal would therefore have meant patching the
   vendored engine. (Ghostty *does* build iOS and iOS-simulator slices in
   `GhosttyXCFramework.zig` and ships a `SurfaceView_UIKit.swift`, so the option existed; it
   just costs a fork of the thing this project deliberately does not modify.)

3. **The transcript is rich enough to render from.** A live claude transcript contains
   `assistant`, `user`, `tool_use`, `tool_result`, `thinking`, `attachment` and `text` records,
   which is the whole vocabulary a timeline needs.

4. **Fleet state is already closed to outside writers.** `repos`, `statuses` and `unreadIdle`
   are `@Published private(set)`, so every mutation is internal to `SessionStore` — which is
   what makes the event log of §5 a contained change and its eventual encapsulation affordable.

**Taken on report, not verified here:** everything about codex's app-server (approval
`ServerRequest`s, `turn/steer`, `turn/interrupt`, item streaming) comes from the adapter
workstream's document. That layer is theirs; this spec consumes its normalized output.

## 2. Slices

Each is independently shippable. This spec covers 1a and 1b.

| # | Slice | Delivers |
|---|---|---|
| **1a** | Spine + fleet | Pair a phone; see every session live with status, sub-agent count and unread. Proves identity, roaming, replication. |
| **1b** | Timeline | Open a session and read it, styled like the terminal, with drill-down into tool calls. |
| 2 | Reply | Send text, interrupt, answer permission and plan prompts (§9). |
| 3 | Notify | APNs push direct from the Mac, so a blocked session reaches you unopened. |
| 4 | Control | Start/close sessions, rename, move, projects, agent options. |

1a before 1b deliberately: the timeline is the part that needs a content vocabulary spanning
two very different agents, and it should land on a channel already proven by the cheaper tier.

## 3. Architecture and trust boundary

Everything runs **in the Flight Deck process** — an `NWListener` owned by the app beside
`SessionStore`. Not a helper daemon: the store, the surfaces and the `TextInjecting` seam are
all in-process, so a daemon would need IPC back in for every command it received. The
consequence is acceptable and honest — the phone works only while Flight Deck runs, which is
already true of the sessions themselves.

**Pairing is the entire authorization story.** A paired phone can run commands on the user's
Mac, so:

- The Mac **arms** pairing explicitly; it is never passively pairable.
- While armed it mints a fresh 32-byte secret and a device slot id, and displays them as a QR
  alongside its name and current endpoints. The QR is single-use and expires with the arming
  window.
- The phone scans it and stores the secret in the Keychain; the Mac keeps its copy per slot.
  From then on **every connection is TLS with that pre-shared key** — a device slot the Mac has
  no secret for cannot complete a handshake, so an unpaired peer never reaches application code.

  There is exactly one exception, and it is scoped and named: the **pairing listener**, which
  exists only while a window is armed, carries a **public bootstrap PSK** compiled into both
  binaries, and can reach no application code at all — it speaks a frame vocabulary with no
  `hello` and no `cmd` in it. It provides no confidentiality and nothing depends on it for
  any: the device key crossing it is sealed under a SPAKE2-derived key. See
  [`2026-08-21-short-pairing-code-design.md`](2026-08-21-short-pairing-code-design.md) §6.
- Preferences grows a paired-devices list; revoking is deleting that slot's secret. The Mac
  shows when a phone is attached.

This is **trust-on-first-use over the user's own screen**, and worth stating plainly rather than
dressing up: its strength is exactly that a QR displayed on an unlocked Mac, during a window the
user opened, is seen only by someone who could already use the Mac.

**Amendment (from execution, 2026-08-22).** This paragraph used to end "It is not a PAKE and
does not defend against someone photographing the screen while it is up." A PAKE now exists on
one of the two paths, so the first half stopped being true; the second half is unchanged, and it
is the half that describes the boundary. There are now two paths onto that screen, and they
differ in one respect only. The **QR path** is trust-on-first-use exactly as described: the
code carries the device key itself, and the screen it is displayed on is what secures it.
The **typed path** carries no key — twelve characters, 55 bits — and uses SPAKE2 plus a
three-guess limit to make those 55 bits safe to put on a wire. That PAKE is a prerequisite for
shortening the code, **not a strengthening of this trust boundary**: photographing a code
during the window still pairs the photographer, on either path. See
[`2026-08-21-short-pairing-code-design.md`](2026-08-21-short-pairing-code-design.md) §3.

Pre-shared keys rather than exchanged public keys is a deliberate simplification: Network
.framework supports TLS-PSK directly on both `NWListener` and `NWConnection`, whereas a
certificate-based design would require generating self-signed X.509 in Swift, which has no
first-class API. Same mutual authentication, none of the DER handling.

**Roaming falls out of key-based identity.** The key identifies the Mac; an address is only a
candidate. Bonjour `_flightdeck._tcp` finds it on the LAN; off-LAN the phone races the
endpoints it remembers — VPN address, last-successful address — in parallel, and the first to
present the paired key wins. **No stable hostname is assumed anywhere.** A future relay is a
further candidate endpoint, not a redesign.

## 4. Wire protocol

**One TLS-PSK WebSocket carries everything** — authentication, the connect-time snapshot,
live events, commands, and (in slice 1b) paginated history. There is no HTTP tier.

That corrects an earlier draft of this section, and the correction was made by reading the
SDK rather than assuming it:

- **Network.framework has no HTTP server.** `NWListener` speaks TCP and TLS, and with
  `NWProtocolWebSocket` in the stack it performs the upgrade handshake itself. Serving
  `POST /v1/attach` would mean hand-rolling HTTP/1.1 on a *second* listener — a listener
  carrying the WebSocket protocol expects every connection to be an upgrade and can only
  accept or reject one, since `nw_ws_response` carries headers and no body. That is a few
  hundred lines of parser, plus a second port, to move two small JSON payloads.
- **`POST /v1/pair` was redundant.** The QR already carries the pre-shared key the Mac minted
  while armed (§3), so the Mac registered the slot before the phone connected at all. "Paired"
  *is* the first TLS-PSK handshake that completes inside the arming window; there is nothing
  left for an endpoint to do.
- **With no HTTP fetch, the ticket has no job.** Its only purpose was binding a socket to a
  snapshot fetched over a *different* connection. The snapshot now arrives on the socket that
  asked for it. An earlier draft justified moving that ticket out of an `Authorization` header
  by claiming Network.framework does not expose the upgrade request's headers to a server —
  **that claim is false.** `nw_ws_options_set_client_request_handler` and
  `nw_ws_request_enumerate_additional_headers` have both shipped since macOS 10.15. The ticket
  is gone for the reason above, not that one.

TLS-PSK mutually authenticates the connection before a byte of application data moves, so the
first frame is a resume point rather than a credential:

```jsonc
{ "t": "hello", "lastSeq": 812 }        // 0 means "I have nothing — send a snapshot"
  → { "seq": 812, "t": "snapshot", "fleet": { … } }
  → or the folded replay of 813…, then live frames
```

A socket that has not sent `hello` within a few seconds is closed, so a peer that completed a
handshake but says nothing does not hold a slot open.

Northbound frames are sequenced; southbound are correlated:

```jsonc
{ "seq": 812, "t": "session.upsert", "session": { … } }
{ "seq": 813, "t": "session.removed", "id": "…" }
{ "seq": 814, "t": "prompt.opened",  "id": "…", "sessionId": "…",
               "tool": "Bash", "input": { … }, "expiresAt": "…" }
{ "seq": 815, "t": "prompt.closed",  "id": "…", "decision": "allow" }

{ "t": "cmd", "cid": 41, "op": "session.markRead", "id": "…" }
{ "t": "ack", "cid": 41 }
{ "t": "err", "cid": 41, "code": "prompt_expired" }
```

**`ack` means dispatched, not done.** Typing into a pty has no delivery confirmation, so the
observable effect always arrives separately as a northbound event. One rule for both agents
beats commands whose meaning depends on which agent is behind them.

### Resume

`hello` carries the last sequence the client applied, and the server answers one of two ways:

```jsonc
{ "t": "hello", "lastSeq": 812 }
  → replays 813… from a bounded ring
  → or { "t": "snapshot", "reason": "seq_too_old" }
```

The explicit re-snapshot is required, not an optimization. Silently resuming from wherever the
server happens to be is how a phone ends up confidently displaying a fleet that no longer
exists.

**Replay is folded, not raw.** A phone off the network for an hour must not receive four
thousand status flaps. The fold collapses repeated `activity` changes per session to the last,
and drops events entirely for sessions removed within the gap. Folding is what makes a long gap
resumable at all rather than forcing a re-snapshot, so it belongs on the resume path, not in an
optimization pass.

## 5. Desktop replication

`SessionStore` **emits an event log**; the log is what goes on the wire.

This was chosen over deriving deltas by diffing a projection each tick, for three reasons.
Events carry *intent* where a diff carries only outcome — `renamed(origin: .user)` and
`renamedExternally` are the same diff and different facts, and the phone needs the distinction
for both the timeline and for deciding what deserves a notification. The replay ring simply
*is* the log, where diffing would have to synthesize deltas and then store them anyway, with a
lossy step in front. And it generalizes a pattern the store already has — `commitStatuses`
computes `[StatusTransition]` once per tick and hands the same list to `applyReadState`,
`deliverNotifications` and `cancelSupersededPrompts`; the replicator is a fourth consumer of the
same tick.

```swift
enum FleetEvent: Equatable, Sendable { case sessionAdded(…), renamed(…), activityChanged(…), … }

@MainActor final class FleetReplicator {
    private var ring: [(seq: Int, event: FleetEvent)]   // bounded
    func record(_ events: [FleetEvent])                 // called once per tick
    func snapshot() -> FleetSnapshot                    // for /v1/attach
}
```

Southbound commands arrive as a `FleetCommand` enum applied through existing `SessionStore`
methods. Where a command has no existing method, the fix is to **add one to the store** rather
than special-case it in the replicator — anything the phone can do, the Mac's own UI should be
able to do.

### The one weakness, and its interim guard

A mutation site that changes state without appending its event leaves every client silently and
permanently wrong until the next reconnect. The structural fix — moving the storage into a
`FleetState` value type whose every mutator records, making the omission unwriteable — is
designed in
[2026-08-18-fleet-state-encapsulation-design.md](2026-08-18-fleet-state-encapsulation-design.md)
and **deliberately deferred**: it rewrites every write site in `SessionStore.swift`, the file
the agent-adapter work is most actively changing.

Until it lands, this work ships the assertion instead:

```swift
// after each tick, in tests and #if DEBUG
assert(apply(emittedEvents, to: projectionBefore) == project(store))
```

`project(_:) -> FleetProjection` is needed anyway to build the `/v1/attach` snapshot, so the
oracle is free. **This assertion is the only thing standing between a new mutation site and a
stale phone. It is not removable before the encapsulation replaces it.**

## 6. Content feed (slice 1b)

One vocabulary both agents map onto, on a **channel separate from `AgentEvent`**. `AgentEvent`
is four cases sized for a sidebar row; widening it to carry conversation content would drag
desktop code through a change it does not need.

```swift
struct TimelineItem: Identifiable, Equatable, Sendable {
    let id: String                 // stable across updates
    var kind: Kind                 // .userTurn .assistantText .thinking .toolCall .toolResult .prompt
    var status: Status             // .streaming | .complete
    var body: Body
}
```

- **codex** maps from `item/started` / `item/completed` plus streaming deltas.
- **claude** maps by parsing transcript JSONL (§1.3), extending the existing `TranscriptWatcher`
  path rather than adding a second reader.

**Two asymmetries are accepted and surfaced rather than papered over.** Codex streams tokens;
claude's transcript lands per-message, so on claude the phone shows completed messages, not a
live cursor. And sub-agents reduce to a count for claude while codex exposes per-sub-agent
state — so the richer view is agent-conditional, and the UI must not imply otherwise.

**History is paginated, and rides the same socket** as a `cid`-correlated request/response
pair (§4). A long transcript is still bulk transfer and still must not be pushed unasked — the
phone asks for the page it needs — but that is a matter of who initiates, not of which protocol
carries it. Opening a session fetches the most recent page and pages backwards on scroll.

## 7. iOS client

New targets: `FlightDeckMobile` (iOS app) and `FleetKit` — a shared module holding the wire
value types, the event fold, and snapshot application, so the phone tests delta application
against the same code that produced it.

**A trap to avoid:** `project.yml` sets `SWIFT_VERSION: "5.0"` in `settings.base` for the whole
project, deliberately, because vendored Ghostty is not Swift-6 clean. The new targets must
**not** inherit it — `FleetKit` and the iOS app want Swift 6 with `Sendable` checking, and a
Swift 6 module imports into a Swift 5 target without complaint. `FleetKit` must also import
nothing platform-bound: the wire form is a **trimmed struct**, not `Session` shared verbatim,
which carries desktop-only fields (`transcriptDirectory`, `transcriptPath`).

Three screens — fleet list → session timeline → item detail. The timeline renders in the
terminal's own idiom (monospace, the terminal palette, `⏺`/`⎿` shapes) rather than as chat
bubbles, and a tool row taps through to the full diff, full command output, or full file read.

**Key mobile state on the tab `id`, never `conversationId`**: the latter is not stable across a
re-pin, and for codex it differs from the tab id from birth.

## 8. Unread and notifications

Unread is **one fleet-wide fact**, not per-device. Reading a session on the phone clears the dot
on the Mac and the reverse, which is what the mark means — "finished while you weren't
looking" — and it means nothing is ever dismissed twice. `markRead` is an ordinary command
writing through the existing `applyReadState`, which stays the single writer.

**Only the device not currently showing that session notifies.** An active phone suppresses the
Mac's alert and vice versa.

## 9. Prompt bridging (designed here, built in slice 2)

Designed now because it shapes the protocol (§4's `prompt.opened` / `prompt.closed`).

A `PromptBroker` normalizes both agents into one `PendingPrompt`. Codex's approval requests are
already in-process. Claude's arrive through a small hook helper shipped in the app bundle:
claude spawns it, it dials a unix socket in the app container, blocks until Flight Deck returns
a decision, and prints the JSON of §1.1.

Two things this must get right:

- **A prompt outlives the connection.** A phone that disappears mid-prompt must not leave the
  hook blocking forever; the prompt stays answerable on the Mac, and the helper carries a
  timeout after which it declines to decide (returning no decision, so claude falls back to its
  own TUI prompt) rather than guessing.
- **Registering the hook writes to claude's settings**, which is a side effect on the user's
  environment. Global vs. per-project vs. a Flight Deck plugin is an open question (§11).

## 10. Testing

Pure and testable without a network, a device, or an agent: the event fold, snapshot
application, the ring's resume-and-resnapshot logic, `FleetCommand` dispatch, and both agents'
mapping into `TimelineItem` — the latter from recorded fixtures, which is both house style and
why `Tests/FlightDeckTests/Fixtures` is now a folder reference.

A `FakeFleetTransport` on both sides mirrors the existing `SpyInjector` / `FakeAgentRuntime`
seams. The hook helper gets a test that runs the real binary against a stub socket and asserts
the JSON it prints, so it is covered with claude out of the loop. Pairing, Bonjour and roaming
are manual, plus a loopback test with listener and client in one process.

**None of this goes near `UITests`**, which is throttled GUI territory (AGENTS.md rule 4).

## 11. Risks and open questions

- **The `PermissionRequest` matcher's true breadth is inferred.** `matcher: "*"` is registered
  in the user's settings and `ExitPlanMode` is proven in production by plannotator; that every
  tool's permission request is interceptable and decidable follows but was not exercised
  tool-by-tool. Verify before slice 2 commits to it.
- **Where the hook is registered** — global settings, per-project, or a Flight Deck plugin —
  is undecided, and it is a change to the user's environment either way.
- **APNs direct from the Mac** (slice 3) assumes the Mac can reach Apple's push service and hold
  a provider key. Standard, but unverified in this context.
- **Hooks and app-server are both moving targets.** Codex's app-server is flagged experimental
  and ships often; claude's hook contract is undocumented and was read out of a binary. Both
  need a version probe and a clear failure path.
- **The phone is fully privileged once paired.** Revocation and the attached-device indicator
  are not polish; they are the only user-visible control over that.

## 12. Out of scope

- A real terminal on the phone (§1.2).
- Anything the phone would do while disconnected beyond displaying a stale cached snapshot,
  clearly marked as stale. There is nothing to merge: the Mac owns live processes.
- A relay. Designed for as a candidate endpoint (§3); not built.
- **Implementing** slices 2–4, which get their own specs. §9 is designed here only because the
  prompt frames in §4 would otherwise have to be invented twice; nothing in it is built by this
  spec's plan.
- Splitting 1a and 1b across plans is left to the plan, not decided here: they share every
  mechanism in §3–§5 and differ only in §6, so whether that is one staged plan or two is a
  sequencing call best made with the task list in front of you.
