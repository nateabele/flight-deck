# Working on the wire, pairing, and discovery

`Sources/FleetKit/`, `Sources/FlightDeck/Fleet/`, and the connector half of
`Sources/FlightDeckMobile/`. [ARCHITECTURE.md](ARCHITECTURE.md), under "Fleet replication, pairing, and the phone",
describes what the spine *is*; this describes how to change it without breaking one of the
invariants the test suite defends.

## The boundary that is enforced rather than agreed

`FleetKit` imports `Foundation`, `Network` and `Security`, and never `AppKit`. That is not a
convention — the same source directory is compiled a second time as an iOS target (`FleetKitiOS`
in `project.yml`), so a stray `import AppKit` fails that build immediately instead of surfacing
weeks later as a phone-side compile error nobody was watching for. If you find yourself wanting
AppKit in FleetKit, the type belongs in `Sources/FlightDeck/Fleet/` instead.

`FleetService` is the only type that knows both a `SessionStore` and a socket. Keep it that way:
the socket server stays testable with no store, the store stays testable with no network, and
everything needing both is in one file you can read at once.

## Two shapes of traffic, and choosing between them

**Pushed, sequenced: the fleet.** A snapshot, then a `FleetEvent` per change, each carrying a
`seq`. A client hands its last `seq` back on `hello` and gets the gap replayed. This is for
state that is small and that *every* client wants all of.

**Pulled, correlated, unsequenced: everything else.** `ClientFrame.req` carries a
`FleetRequest`; the Mac answers on the same `cid`. Conversation history works this way, and so
does the New Session menu. This is for bulk only one client wants, and for questions whose
answer is not state at all.

**A reply must never carry a `seq`.** It is the rule most easily broken by accident and the
damage is invisible: a phone paging back through an hour of transcript would move the resume
point it hands back on its next `hello`, and reconnect from the wrong place. All three reply
frames say so in their own doc comments — `ServerFrame.page`, `ServerFrame.newSessionOptions`
and `ServerFrame.macEndpoints`. Say it again in the fourth, and update this count when you do.

### Which one is my new thing?

- Does it change what the fleet *is*? → an event, and the store must emit it. See the drift
  assertion below before you decide yes.
- Does it ask the Mac to *do* something? → a `FleetCommand`. `ack` means dispatched, not done.
- Does it ask the Mac to *tell* you something? → a `FleetRequest`.

The trap is the fourth case: something that looks like state, is derived from something that is
not fleet state, and therefore cannot be an event. That is the next section, and it is the one
that has actually gone wrong.

## The two invariants that break the naive implementation

Both of these are enforced by tests, and both were discovered by a working implementation
failing them. Read them before adding anything to `FleetSnapshot`.

### 1. An account id may not travel

An account **is** a config directory — `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, where that login's
credentials live. So `WireSession` carries no account field, `FleetProjection` never reads
`Session.accountID`, and `FleetAccountEmissionTests.testAnAccountsHomeNeverReachesTheWire`
asserts against the *serialized* form that neither the home path nor the opaque id that resolves
to one appears anywhere.

The id is covered explicitly because an id resolves to a home in one hop. Anything a client needs
to name an account with must therefore be opaque and non-resolving: the New Session menu
identifies a row by its agent plus that row's **position** among the agent's accounts, and the
Mac re-resolves the position when the row comes back.

That assertion decodes and unescapes before searching, because `JSONEncoder` writes `/` as `\/`
and a raw `contains(path)` would be false no matter what the snapshot held — a privacy assertion
passing vacuously is the worst available outcome. Extend it the same way for anything new.

### 2. The snapshot must be reproducible from the event log

`FleetReplicator` folds the emitted events into a mirror and, in `#if DEBUG`, asserts after every
batch that the mirror equals `FleetProjection.snapshot(of:)` taken fresh. It has caught five real
defects and must not be removed before the fleet state is properly encapsulated.

The consequence for new work: **anything derived from something that emits no events cannot go in
the snapshot.** Preferences are the live example — agent order, accounts, resolved defaults. They
change with nothing recorded, so a snapshot field built from them makes the mirror diverge and
the suite fails with "a mutation changed the fleet without recording its event". There is no
preferences-changed hook to emit from; this has been checked.

The way out is not to add an event. It is to notice the thing is not fleet state and make it a
request — which is what the New Session menu is, and why the presence badge
(`FleetEvent.viewing`) stayed out of the snapshot too.

## Adding a command or a request

The mechanical checklist, in the order the compiler will ask for it.

1. **The case.** `FleetCommand` or `FleetRequest` in `Sources/FleetKit/`, plus its `Op` raw
   string — dotted, like `session.newOptions`, which is also what keeps the command and event
   tag namespaces from colliding.
2. **Encode and decode.** New optional fields use `encodeIfPresent`, so a client that does not
   set them puts exactly the bytes on the wire it always did and an older Mac sees the frame it
   has always seen. An unrecognised `op` **throws** — a request that cannot be understood cannot
   be answered, and guessing answers the wrong question.
3. **The reply frame**, if it is a request: a case on `ServerFrame`, a `Tag`, and no `seq`.
4. **The client end.** `FleetConnector` holds one pending table per answer type — `pending`
   (pages), `pendingAcks` (commands), `pendingOptions` (menu rows), `pendingEndpoints`
   (`mac.endpoints` replies). They share a single `cid` space, because `FleetClient.send` mints
   both verbs from one `nextCID`, so a number is filed in at most one table and `apply` tries
   each in turn. Add a new table to `drainPending()` in the same commit, or a client whose
   socket dies waits forever — `pendingEndpoints` followed that rule when it was added; see the
   comment on it in `drainPending()`.
5. **The Mac end.** `FleetService.onCommand` / `onRequest`. Answer synchronously if the work is
   already on the main actor; hop through a `Task` if it is file I/O, as the timeline does, and
   note that `reply` must land back on the socket's queue.
6. **Refusals.** Return `.err(cid:code:)` with a code a client can act on. Two more arrive from
   the socket rather than from you: `unhandled` (no handler wired at all) and `unsupported` (a
   request this Mac cannot parse). **A client must treat any unrecognised code as a soft
   failure** — that is what makes an old Mac and a new phone work together.

### Compatibility, in both directions

Assume both are in the field, because they are.

- **New phone, old Mac.** The Mac answers `unsupported` or `unhandled`. The phone must have a
  designed fallback, and the fallback must be a *supported state* rather than a placeholder — the
  New Session menu falls back to a single default row, which is exactly what an old Mac produces
  forever.
- **Old phone, new Mac.** The new fields are absent, so `decodeIfPresent` yields nil, and nil
  must mean the previous behaviour. `FleetCommand.newSession` with no agent and no account index
  is a plain `+` tap, which is what it always was.
- **Hold "absent" and "empty" apart.** They usually mean opposite things. No answer yet is "ask
  again later, meanwhile assume the default"; an answer carrying nothing is "there is genuinely
  nothing here, disable the control". Collapsing them offers the user a tap that can only fail.

## Pairing

A code on an unlocked Mac — a QR, or twelve typed characters — a two-minute window, single use.
**Pairing is authorization, in full, forever, until the Mac deletes that device's slot.** There
is no second permission tier on top of the TLS-PSK handshake. Anyone who can read the code off
the screen can pair.

- The slot id **is** the TLS PSK identity, which is what lets one listener hold several devices'
  keys and still know which connected — and makes revoking a device exactly "delete this slot",
  with no other bookkeeping.
- The typed path adds SPAKE2 and a three-guess limit for one purpose: to make 55 bits safe to put
  on a wire. It does not raise the boundary above.
- `PairingCode`'s alphabet is Crockford base32 minus `I`, `L`, `O`, `U` — a code is read off one
  screen and typed into another across a room, and `1`/`I`/`l` and `0`/`O` are the errors that
  produces.
- `PairingArmer` is a pure state machine over an injected clock. The arming window, the one-slot
  limit and the attempt count are all testable without a socket, and are tested that way.

### What a cross-process pairing run does and does not prove

Worth knowing exactly, because the stronger claim was made once and was wrong.

**It catches caller-side asymmetry**: the two ends disagreeing about which is the SPAKE2
initiator, about the two names passed to `SPAKE2Session`, or about the order they assemble the
transcript. Those live in `PairingListener.handle` and `PairingInitiator.start` — different
files, different hands — and a disagreement produces confirmations that never match, which
presents to the user as "wrong code" for a correctly typed one, three times, until lockout.

**It does not catch a consistent role or name swap inside `SPAKE2Session`.** Both ends compile
the same FleetKit, so a swap in the wrapper applies identically to both sides and survives a
cross-process run exactly as it survives an in-process one. This was demonstrated, not argued:
two mutants — roles swapped, names swapped — each passed all seventeen SPAKE2 and
`PairingSecrets` tests.

What closes that is a second implementation of the *caller*, not a second process:
`SPAKE2SessionTests.testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder` drives one side
through BoringSSL's raw C API with a literal `spake2_role_alice` and the argument order
`curve25519.h` declares, the other through `SPAKE2Session`, and requires the derived keys to
agree. Both mutants fail it. Do not weaken that test, and do not reintroduce the claim that a
cross-process run replaces it.

## Discovery and reconnection

The phone finds the Mac by browsing Bonjour and racing remembered addresses; the first client to
complete a handshake wins and the losers are torn down.

**iOS destroys an app's sockets when it suspends and does not tell the app.** The connector comes
back believing it is connected to a socket that no longer exists, so nothing retries, no backoff
fires, and the fleet list sits there stale until a force-quit "fixes" it — force-quit being the
tell, since it is the only path that rebuilds the connector. `FlightDeckMobileApp` therefore
redials unconditionally on `.background` → `.active`.

Two details of that are load-bearing:

- **Unconditional, not gated on the connector's own state**, precisely because that state is what
  cannot be trusted here. It describes a socket iOS deleted.
- **Keyed on `.background` → `.active`**, not on `.active` alone: a notification banner or the app
  switcher passes through `.inactive` without suspending, and redialling on those churns the
  socket every time a banner appears.

That redial is also the only moment anything preference-derived gets refreshed, since preferences
have no push path. Hang such refreshes off the connector reporting `.connected` — see the next
section for why "snapshot arrival" is not the same thing.

### The endpoint refresh

`FleetRequest.macEndpoints` is exactly that: a refresh hung off the connection rather than off
the app-suspend redial above, so it also covers reconnects the redial never touches — a Mac
restarting, a Wi-Fi drop and rejoin, first pairing itself — none of which need the phone app to
have backgrounded at all.

**It is fired from `FleetConnector.accept()`, where `.connected` is reported, and not from
`apply`'s `.snapshot` arm.** That distinction is the whole of it, and the first implementation
got it wrong: a snapshot is *not* every connect. `FleetReplicator.resume(from:)` resnapshots
only for a first connection, for a Mac whose `seq` went backwards (a restart), or for a client
that fell off the 4096-entry ring. Every other reconnect is answered with a replay — events, or
nothing at all. So a phone that drops Wi-Fi and rejoins, or is backgrounded and foregrounded
against a Mac that has been up a while, resumed by replay and never refreshed — the roaming
case the feature exists for. `.connected` covers snapshot and replay alike, once per connection.
It is not, incidentally, the hook the New Session menu uses; that is `onFleet`, which fires on
snapshots *and* on every event.

From there the mechanics are unchanged: `FleetService.onRequest`'s `.macEndpoints` case answers
with `LocalEndpoints.routable`; and `adoptEndpoints` takes the answer as authoritative, keeping
the address `promote()` last put in front when the Mac still claims it, and ignoring an empty
answer outright — empty means the Mac could not enumerate, never that it has none, and erasing a
working candidate on that strength would be worse than leaving the list stale.

It is a request rather than a `FleetSnapshot` field for the reason "2. The snapshot must be
reproducible from the event log" gives in general: an address changes with the network, not with
a store mutation, so nothing ever emits a `FleetEvent` to record it — a snapshot field built from
it would diverge from the replayed mirror on the very next connect and trip `FleetReplicator`'s
drift assertion. `FleetService.onRequest`'s `.macEndpoints` case says exactly this at the call
site, in case this section ever drifts from it.

### Two endpoints, not more

The pairing code (see "Pairing" above) now packs up to two of `LocalEndpoints`' ranked addresses
instead of one — one that works off the LAN, one that works on it. The cap is measured, not
chosen: at QR correction level `M`, `PairingPayload`'s packed record renders to **45 modules**
with two endpoints, identical to what v2's one-endpoint record produced, and to **49** with
three — which fails `PairingCodeImageTests.testThePackedPayloadProducesAMateriallySmallerQR`
against its 0.75 threshold. Those are module *counts*, not what
`PairingCodeImageTests.modules(of:)` returns: that helper reports the CoreImage *extent*, which
is the module count plus a two-module quiet zone, so the same two shapes measure 47 and 51
there. Keep the two units apart when citing this — an earlier revision of
`PairingPayload.maxEndpoints`'s own comment conflated them and had to be corrected.

Which list the code is built from is a separate decision from the cap, and getting it wrong
costs a slot rather than a byte: `FleetService.arm()` calls `LocalEndpoints.routable(port:limit:)`
with `PairingPayload.maxEndpoints` as the limit — **not** `current`. `current` includes loopback,
ranked last, and `127.0.0.1:<port>` packs into the record exactly as well as any other IPv4:port,
so a Wi-Fi-only Mac (`lo0` and `en0` and nothing else) shipped a QR whose second slot was a dial
the phone made to itself. The filter has to run before the cap, not after it. Both paths that
reach a client — the QR and the `mac.endpoints` reply — therefore go through `routable`;
`LocalEndpointsTests.testWhatTheQRCarriesForAPlainMacBookAndForATailnettedOne` drives interfaces
all the way through to a decoded code, which is the seam neither side's tests covered.

`LocalEndpoints.ranked` decides which two survive by rank, not by sorting, and matches no
interface name. `SCDynamicStore`'s `PrimaryInterface` key names whichever interface carries the
default route — the LAN, ordinarily — and the kernel's `IFF_POINTOPOINT` flag names a tunnel;
among tunnels, the CGNAT range `100.64.0.0/10` picks out Tailscale specifically, so a second VPN
can still be ranked below it. The ranked list itself is built by concatenating one `filter`ed
bucket per rank rather than by `Array.sorted(by:)`: `filter` preserves relative order by
definition, and `sorted(by:)` promises no such thing, so ordering equal-rank candidates through
a sort would rest on an incidental stdlib behaviour a later toolchain is free to withdraw —
measured stable on the toolchain this was written against, which is precisely the problem.

## Concurrency

`FleetClient` and `FleetConnector` are `@unchecked Sendable`, and it is a promise rather than a
check. Everything they touch is confined to one `DispatchQueue`, and every public method asserts
`dispatchPrecondition(condition: .onQueue(queue))`. **Do not silence a concurrency diagnostic
here with `nonisolated(unsafe)`.** If something needs to touch that state off the queue, that is
a design change. The confinement holds only because callers obey the documented queue — `init`
accepts any queue, and a caller supplying a custom one while calling `start()`/`stop()`/`send()`
from `@MainActor` gets real races with zero compiler signal.

## Testing

```
./scripts/test-unit.sh     # macOS: the whole spine, real sockets, in process
./scripts/test-ios.sh      # the phone's own logic
```

The macOS suite runs real listeners and real clients — a handshake, a snapshot of a live store,
mutations followed, a drop resumed, a page read off a real file on disk. The loopback tests
(`TimelineLoopbackTests`, `AnswerLoopbackTests`, `PhonePromptLoopbackTests`) are the end-to-end
proofs and are the model to copy for anything new that crosses the wire: a real service, a real
socket, a real client, asserting on what came out the far end.

`scripts/test-unit.sh` loads the test bundle by hand rather than using `xcodebuild test`, because
the macOS test host is a real AppKit app whose launch needs a GUI login session and dies with
`DVTAssertions: Assertion failed: childPID > 0` in any automated context. That workaround is
macOS-specific; the iOS side does not need it.

For anything a socket cannot prove — a real code read off a real screen, a real network, two real
devices — the checklist is [MOBILE.md](MOBILE.md), particularly "A second checklist: the iOS
plumbing" and "The cross-process check, and exactly what it proves".
