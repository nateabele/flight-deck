# Off-LAN endpoint discovery: a QR that carries more than one address, and a way to refresh it

## The defect this fixes

A Mac and a phone, both on a tailnet, could not pair. The phone reported success, the Mac
kept showing the pairing modal, and the phone then failed to connect forever.

Neither end was lying. `FleetModel.adopt(code:)` reports success as soon as the payload
decodes and saves — it never waits for a socket. The Mac completes pairing only in
`FleetService.noteAttached`, on a real TLS-PSK attach. So "paired" and "not paired" were
answers to two different questions, and the connection in between never happened.

It never happened because of one line. `PairingPayload.encoded()` packs
`endpoints.first` — exactly one address — and `LocalEndpoints.current` returns addresses in
raw `getifaddrs` order with no preference. Measured on the affected Mac:

```
0: en0        192.168.1.109:58625   ← the QR carried this
1: bridge100  192.168.139.3:58625
2: bridge101  192.168.117.0:58625
3: bridge102  192.168.97.0:58625
4: utun7      100.108.99.35:58625   ← the tailnet address, discarded
5: lo         127.0.0.1:58625
```

The phone stored one unreachable candidate and a Bonjour service name. Bonjour does not
cross a tailnet, so `FleetConnector.race()` had nothing that could win.

This is not a regression. `docs/FOLLOWUPS.md` records it: *"No relay, so reaching the Mac
from off-LAN needs a VPN. Designed for as a further candidate endpoint (spec §3, §12), not
built in either plan."* This spec builds it.

A second consequence, worth stating because it rules out the cheapest fix:
`FleetConnector.promote()` only reorders endpoints the phone already holds. Nothing in the
system ever *adds* one. So pairing on the LAN first and roaming afterwards would not have
worked either — the tailnet address had no path into the phone at all.

## Decisions taken

1. **Initial pairing must work off-LAN.** A phone on cellular pairs with a Mac at home. This
   is what forces a payload change: a post-connect refresh cannot help a phone that cannot
   connect in the first place.
2. **Both halves get built** — a QR carrying several endpoints *and* a request that refreshes
   them after connecting. The QR gets the first connection; the request keeps the list true
   afterwards. `LocalEndpoints`' own doc comment already takes the position that endpoints
   are candidates that go stale ("by the time the phone has left the room every one of these
   may be wrong"), and a QR scanned once on pairing day is otherwise a permanent snapshot.

## 1. Endpoint selection on the Mac

`LocalEndpoints.current` keeps returning every candidate, but ranked best-first instead of in
kernel order. The ranking is driven by two signals that macOS supplies directly, so no
interface-name matching is involved.

**The LAN interface** is whatever `SCDynamicStoreCopyValue(store,
"State:/Network/Global/IPv4")["PrimaryInterface"]` names — macOS's own answer for the primary
interface, and the same thing that carries the default route. Verified on the affected Mac:
returns `en0`, while the three `bridge*` interfaces (Internet Sharing / VM host networks, which
a phone can never reach) are not primary and demote themselves without being named.

**The VPN interface** is `IFF_POINTOPOINT`. Verified on the affected Mac: among IPv4
interfaces, `utun7` is the only point-to-point one, and its address is in `100.64.0.0/10`,
which independently confirms it is Tailscale.

```
name       p2p   bcast  loop  address
lo0        -     -      yes   127.0.0.1
en0        -     yes    -     192.168.1.109     ← PrimaryInterface
bridge100  -     yes    -     192.168.139.3
bridge101  -     yes    -     192.168.117.0
bridge102  -     yes    -     192.168.97.0
utun7      yes   -      -     100.108.99.35     ← IFF_POINTOPOINT, CGNAT
```

Rank order:

| rank | rule | rationale |
|---|---|---|
| 0 | point-to-point **and** in `100.64.0.0/10` | the tailnet address; reachable from anywhere the phone is signed in |
| 1 | point-to-point, any other routable v4 | another VPN, same purpose |
| 2 | the `PrimaryInterface` address, if not already taken above | the real LAN path when the VPN is off or the phone is not on it |
| 3 | any other broadcast, non-loopback address | bridges and secondary interfaces |
| 4 | loopback | tests only |

The VPN outranks the LAN because an off-LAN phone's first candidate should be the one that
works. On-LAN this costs nothing: `race()` dials all candidates in parallel and the first
completed handshake wins, so the LAN address wins on latency by itself, and `promote()` then
pins it to the front for next time.

**Exit-node case.** With a Tailscale exit node enabled the `PrimaryInterface` *is* the tunnel,
so rank 2 would name the interface rank 0 already took. It is skipped, and the LAN slot falls
through to rank 3. Both slots stay populated.

**Shape, for testability.** The ranking is a pure function over injected data — the whole point
is that it can be tested without real interfaces:

```swift
struct Interface { var name, address: String; var isPointToPoint, isBroadcast, isLoopback: Bool }

static func ranked(_ interfaces: [Interface], primary: String?, port: UInt16) -> [String]
static func current(port: UInt16) -> [String]   // getifaddrs + SCDynamicStore, then ranked()
```

`LocalEndpoints.swift` lives in `Sources/FlightDeck/Fleet/`, not FleetKit, so importing
SystemConfiguration is fine and does not touch the iOS build of FleetKit.

**A stale comment to correct while here.** The file claims loopback "is included deliberately —
it is what the loopback tests use". It is not: every loopback test either builds its own
endpoint array (`FleetConnectorTests`, `PairedMacStoreTests`) or calls
`service.loopbackEndpoint()` (`FleetPairingFlowTests`). Nothing depends on loopback reaching a
payload. Loopback stays, ranked last; the comment gets the true reason.

## 2. Payload v3

`FD3-`, the same packed record with a count byte before the endpoint block:

```
[0]       version = 3
[1..17]   slot (16)
[17..49]  secret (32)
[49]      N                              ← new
[50..]    N × 6 bytes (IPv4 octets + port, big-endian)
          serviceName  (1-byte length + UTF-8)
          macName      (1-byte length + UTF-8)
```

Everything else is unchanged, including the `cursor == bytes.count` trailing-byte rejection —
which keeps "a string this decoder accepts" and "a string this encoder writes" the same set,
and is the reason a future field cannot be appended silently.

**Format ceiling 255, policy cap 2.** This mirrors the split the file already uses for
`maxNameBytes` (255 in the format, 64 by policy). The cap of 2 is load-bearing and was
measured, not estimated — module counts from `CIQRCodeGenerator` at correction level `M`,
against the v1 baseline `testThePackedPayloadProducesAMateriallySmallerQR` compares to:

| N | bytes | chars | extent | ratio vs v1 | assertion |
|---|---|---|---|---|---|
| 1 | 99 | 163 | 47 | 0.701 | passes |
| **2** | **105** | **172** | **47** | **0.701** | **passes** |
| 3 | 111 | 182 | 51 | 0.761 | FAILS |
| 8 | 141 | 230 | 55 | 0.821 | FAILS |

Two endpoints are free — extent 47, identical to what v2 produces today, so that assertion
holds untouched at its current threshold. Three costs a QR version and breaks it.

Two is also exactly the right number rather than a number the budget forced: one off-LAN
address and one on-LAN address is the whole requirement, and any *further* LAN address is
reachable by Bonjour, which is the one job Bonjour can do and the QR cannot.

`testAFullSizedPayloadStillEncodes` already builds a payload with 8 endpoints. Under v2 only
the first was ever packed, so it never tested what its name claims; under v3 it becomes a real
ceiling test and should keep asserting only that the code still encodes.

## 3. The version break

v2 is dropped rather than dual-decoded, following how v1 was dropped when v2 landed: the gate
stays `version == currentVersion`.

One thing must be added. Until now only "too new" was reachable, so both directions collapsed
into one message. With v3 a newer *phone* can meet an older *Mac* for the first time, and the
two cases send the user in opposite directions:

- `version > currentVersion` → "Update Flight Deck on your phone."
- `version < currentVersion` → "Update Flight Deck on your Mac."

`PairingPayloadError.unsupportedVersion(Int)` already carries the number, so this is copy in
`PairingScreen`, not a new error case. This is precisely the distinction the `prefix` doc
comment says the version-in-prefix exists to preserve.

**Consequence to state plainly:** the QR on an updated Mac will not scan into the phone build
currently installed. The Mac and the phone must be updated together.

## 4. The refresh request

Straight down the checklist in `docs/NETWORKING.md`, "Adding a command or a request".

- **Case.** `FleetRequest.macEndpoints`, op `mac.endpoints`. A request rather than an event or
  a snapshot field: addresses are derived from the network, which emits no fleet events, so a
  snapshot field built from them would make `FleetReplicator`'s mirror diverge and fail the
  drift assertion. This is the same reasoning that kept the New Session menu and the presence
  badge out of the snapshot.
- **Reply.** `ServerFrame.macEndpoints(cid: Int, [String])`, tag `endpoints` — undotted, so it
  cannot collide with the dotted `FleetEventTag` namespace that `ServerFrame`'s decoder falls
  through to. **No `seq`**, for the reason `page` and `newSessionOptions` both give: a reply
  carrying a `seq` would move the resume point the client hands back on its next `hello`.
- **Mac end.** `FleetService.onRequest` answers synchronously from
  `LocalEndpoints.current(port: boundPort)`, capped at 4 and with loopback dropped. Capped
  because every candidate the phone stores becomes a real parallel connection attempt in
  `race()`; 4 covers VPN + primary + two others.
- **Client end.** A fourth pending table, `pendingEndpoints`, on `FleetConnector` — added to
  `drainPending()` **in the same commit**, or a phone whose socket dies waits forever. It
  shares the one `cid` space with the other three, so `apply` tries each table in turn.
- **When.** On snapshot arrival, which happens on every connect. `docs/NETWORKING.md` already
  names this as the hook for anything with no push path.

## 5. Merging on the phone

The Mac enumerated its own interfaces, so its reply is authoritative for membership:

- Replace `PairedMac.endpoints` with the reply.
- If the last-successful endpoint appears in the reply, promote it to the front — `promote()`'s
  existing benefit, preserved across a refresh.
- If it does not appear, drop it. The Mac has just said that address is no longer its; a stale
  candidate is exactly what this request exists to remove.
- **An empty reply is ignored and the existing list kept.** "Absent" and "empty" mean opposite
  things (`docs/NETWORKING.md`), and here they would both be self-harm: we are connected to
  this Mac as we read the frame, so a list saying "no addresses" must not be allowed to erase
  the one that is currently working.

No separate stored cap is needed: the reply is already capped at 4 and it replaces rather than
accumulates.

## 6. Compatibility

| | old Mac | new Mac |
|---|---|---|
| **old phone** | works, unchanged | QR refused as `unsupportedVersion(3)` → "update your phone". Deliberate. |
| **new phone** | QR refused as `unsupportedVersion(2)` → "update your Mac". `mac.endpoints` answered `unhandled`/`unsupported`, phone keeps its QR list — a soft failure, per the rule that a client must treat any unrecognised code as one. | works |

## 7. Testing

Unit and loopback, `./scripts/test-unit.sh` and `./scripts/test-ios.sh`:

- **`LocalEndpointsTests`** (new). Ranking over injected interfaces: the affected Mac's exact
  shape yields `[100.108.99.35, 192.168.1.109]` at the cap; exit-node shape (primary is the
  tunnel) still yields both slots; no VPN yields primary first; no primary does not crash;
  loopback ranks last.
- **`PairingPayloadTests`.** Round-trip at N = 0, 1, 2, 8; trailing bytes still throw
  `.malformed`; a v2 code now throws `.unsupportedVersion(2)`; encoding the same payload twice
  is still byte-identical.
- **`PairingCodeImageTests`.** The existing size assertion re-run with a 2-endpoint payload —
  it must still pass at its current 0.75 threshold, unmodified. Changing that threshold in this
  work would defeat the measurement the cap is derived from.
- **A loopback test for the request**, modelled on `AnswerLoopbackTests`: real service, real
  socket, real client. Asserts the reply carries the Mac's addresses, and that the frame has no
  `seq`.
- **`FleetConnectorTests`.** A dead socket drains `pendingEndpoints`; an `err` reply leaves the
  stored list intact; a reply promotes the last-successful endpoint; an empty reply is ignored.
- **Privacy.** `FleetAccountEmissionTests` is unaffected — no account home or id enters any of
  these frames — but the new reply is asserted to carry addresses and nothing else.

Manual, since no single machine can automate it: `docs/MOBILE.md` gains an off-LAN pairing item
— Mac on Wi-Fi with Tailscale up, phone on cellular, scan, expect attach — which is the
scenario that produced this defect.

## Out of scope

- **A relay.** Off-LAN still means a VPN. This spec makes the VPN address *reachable*; it does
  not remove the need for one.
- **IPv6 endpoints.** The packed format stays IPv4-only, matching the existing reasoning that a
  link-local v6 address needs a zone index to be dialable. Tailscale hands out a v6 address per
  node, and carrying it would be a v4 fallback removal, not an addition — a separate change.
- **Manual host entry on the phone.** Not needed once the QR carries a working address.
- **Persisting the snapshot**, which `FleetModel` discusses at the `lastSeq = 0` reset. Untouched.
