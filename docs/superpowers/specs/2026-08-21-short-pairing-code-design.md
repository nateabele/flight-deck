# Short pairing code — design

**Status:** proposed
**Supersedes nothing.** Amends §3 of
[`2026-08-18-mobile-companion-design.md`](2026-08-18-mobile-companion-design.md) — see
[§9](#9-what-this-changes-in-the-original-spec).

## 1. The problem, measured

Slice 1a pairs a phone by showing a QR on the Mac and scanning it. The code behind that QR is
`flightdeck1:` followed by base64url of a JSON object carrying the version, the slot UUID, the
32-byte secret, the Mac's display name, its Bonjour service name, and every candidate endpoint.

That is roughly **300 characters**, and it fails in two ways that only became visible once a
person used it:

- **Typed entry is not usable.** The pairing screen has a "Can't scan? Type the code instead"
  field, specified as the fallback for a refused camera. Nobody types 300 characters on a
  phone. Making the code copyable does not help: on the Mac the code is on the screen you are
  pairing *away from*, and in production there is no clipboard shared between the two devices.
- **The QR is denser than it needs to be.** ~300 bytes lands around QR version 13 — roughly 69
  modules across — drawn at 240pt, so each module is about 3.5pt. That decodes, but it wants a
  steady hand and a close phone, and it degrades with screen glare.

Most of that payload does not need to be in the code at all. The phone learns the Mac's name
from the first snapshot; the service name is derivable; JSON plus base64url inflates the whole
thing by roughly a third before it reaches the QR.

**Two of those three claims are false** — the phone learns neither name from anywhere — and the
third is what actually paid. See [§8](#8-the-qr-payload-packed)'s amendment; the shortening
happened, on the encoding alone.

## 2. What this builds

Two paths to the same result, sharing nothing but their outcome:

| Path | Carries | Secured by | Works |
|---|---|---|---|
| **QR** | The 32-byte device key itself, packed | The screen it is displayed on | Anywhere, including off-LAN |
| **Typed code** | 55 bits of entropy, no key | SPAKE2 + a 3-guess limit | LAN only, via Bonjour |

The QR path is what ships today, with a smaller payload. The typed path is new.

## 3. What the PAKE does and does not buy

§3 of the original spec says the design "is not a PAKE and does not defend against someone
photographing the screen while it is up." **That remains true**, and it is worth being exact
about why, because "we added a PAKE" reads like a security upgrade and this is not one.

Photographing a 12-character code during the window still pairs the photographer. The trust
model is unchanged: *a code displayed on an unlocked Mac, during a window the user opened, is
seen only by someone who could already use the Mac.*

What SPAKE2 buys is narrower and entirely necessary: **it makes a low-entropy code safe to put
on the wire.** Without it, a 60-bit code used as a transport credential is recoverable offline
by anyone who captures the handshake — 2⁶⁰ is expensive, not impossible, and the attacker gets
unlimited time after the fact. SPAKE2 makes every guess cost an online interaction, which the
3-attempt limit then bounds.

So: the PAKE is a prerequisite for shortening the code, not a strengthening of the trust
boundary. The spec should say so where someone will read it.

## 4. The code

**12 characters, uppercase, Crockford base32** (`0123456789ABCDEFGHJKMNPQRSTVWXYZ` — no `I`,
`L`, `O` or `U`, which is what makes it survive being read aloud, handwritten, or typed by
someone who cannot see the Mac from where they are standing).

- **11 characters of entropy — 55 bits.** Minted from `SecRandomCopyBytes`, the same source as
  the device key, and trapped on failure rather than degraded.
- **1 check character.** A 5-bit checksum over the 55 bits, encoded in the same alphabet.
- **Displayed grouped `XXXX-XXXX-XXXX`.** The hyphens are presentation only: input strips them,
  along with whitespace, and uppercases before validating, so a code read aloud and typed in
  lowercase still works.

**The checksum is load-bearing, not cosmetic.** With three attempts, a typo that reaches the
network costs a third of the budget. The checksum catches it on the phone, before anything is
sent, and lets the phone say "that code doesn't look right" rather than "pairing failed" —
which are different problems and send the user to different places.

**Entropy math.** 55 bits against 3 online guesses per window is roughly 1 in 10¹⁶ per window,
with no offline path. The limit does the work here, not the length; 55 bits is comfortable
margin rather than a tuned minimum.

## 5. The PAKE

**SPAKE2, via BoringSSL, vendored as an xcframework** for macOS, iOS device and iOS simulator —
the same shape Ghostty is already vendored in this repo.

Not hand-rolled. SPAKE2 over CryptoKit's primitives is perhaps 200 lines, and the places it
goes wrong — point validation, transcript binding, constant-time comparison — do not announce
themselves in tests. BoringSSL's implementation is the one Chrome and Android ship.

Not a Swift package: no Swift PAKE library has comparable review, and a C dependency builds for
every platform we need without adding a Swift module to `FleetKit`, whose
Foundation/Network/Security-only boundary is enforced by the `FleetKitiOS` target.

**Validation is against published test vectors, not just round-trips.** A PAKE that agrees with
itself proves nothing; the wrapper must agree with the specification. A round-trip-only test
would pass over an implementation that is deterministically wrong in the same way on both ends.

**Amendment (from execution, 2026-08-21): this requirement is not satisfiable, and not for the
mundane reason.** It is not that upstream never got around to writing vectors — it is that
**BoringSSL's SPAKE2 implements no published specification for a vector to conform to.**
Verified in `vendor/boringssl/crypto/curve25519/spake25519.cc`: its `M` and `N` are BoringSSL's
own generated points (line 47, "These points and their precomputation tables are generated
with..."), not RFC 9382's published constants; `password_scalar_hack` (checked at line 400) is
a unilateral fix for a BoringSSL bug that is baked permanently into the wire format —
`disable_password_scalar_hack` exists only to test compatibility with older, buggy BoringSSL,
not as an interop switch; and the transcript hashes `password_hash` (SHA-512 of the password,
line 374), not RFC 9382's derived scalar `w`, with the ephemeral's cofactor multiplied in —
see `update_with_length_prefix` and the final `SHA512_Final` around lines 451-518. SPAKE2+
(RFC 9383, which does ship test vectors) is not in this vendored tag. And even setting the
math aside, there is nothing to drive a vector through:
`vendor/boringssl/crypto/curve25519/spake25519_test.cc` line 29 carries an open
`// TODO(agl): add tests with fixed vectors once SPAKE2 is nailed down`, and
`SPAKE2_generate_msg`'s public API gives no way to fix the ephemeral scalar from outside.

So a conforming vector would not validate this implementation, and a conforming
implementation would not interoperate with it — there is no specification for this variant to
be checked against, in either direction. **The property that replaces conformance is
agreement:** both ends of a pairing exchange run this same BoringSSL, so what needs proving is
that this wrapper's two ends agree with each other, not that either agrees with a standard that
does not describe them. `SPAKE2SessionTests` is what checks that, and does.

The residual risk that leaves is narrower than "is the algorithm right": it is about this
wrapper's marshalling, not BoringSSL's math — a wrapper that swapped `.initiator`/`.responder`,
or the two name arguments, would be wrong identically on both ends and pass every round-trip
test. This amendment first said a cross-process macOS-against-iOS exchange was what would catch
that; **that was wrong, and is corrected here.** Both ends compile the same `FleetKit`, so a
consistent swap crosses the wire intact. What catches it is a second implementation of the
*caller*: `testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder` drives one side through
BoringSSL's raw C API with a literal `spake2_role_alice` and the argument order the header
declares, the other through `SPAKE2Session`, and requires the derived keys to agree. That is
in place, in process, and both mutants fail it.

Note also that a *consistent* swap would have been unconventional rather than insecure — both
names still reach the transcript, in a fixed order, still distinguishing devices — so the gap
was smaller than the original wording suggested. A cross-process exchange still belongs in [§10](#10-testing)'s
bar for the plan that wires this to a socket, but for **caller-side asymmetry**
(the two ends disagreeing about roles, names, or transcript order), which is what that plan can
actually get wrong. See docs/FOLLOWUPS.md's "Pairing crypto foundation" entry.

## 6. The pairing channel

A **separate `NWListener`, alive only while armed**, carrying a **public bootstrap PSK**.

Both halves of that are deliberate, and each was chosen against a plausible alternative:

**Why a separate listener rather than the fleet listener.** The fleet listener's security
property is that a device slot the Mac has no secret for cannot complete a handshake, so an
unpaired peer never reaches application code. A PAKE necessarily runs *before* any shared secret
exists, so carrying it on that listener means accepting unauthenticated handshakes there. That
would (a) let anyone on the LAN consume the fleet listener's pending-connection pool during
every window, a denial of service that does not exist today, and (b) make "a bootstrap
connection must never send `hello`" an invariant enforced by a check rather than by structure —
in code whose slot attribution was wrong until the day before this was written. A separate
socket makes it structural: application code is not reachable because it is not there.

**Why a public PSK rather than plaintext.** SPAKE2 is safe on a public channel, so plaintext
would not leak the device key. But plaintext is visible to any passive capture, IDS or network
logging, some networks flag it, and it puts an unauthenticated frame parser directly on the wire
with nothing in front of it. A bootstrap PSK compiled into both binaries costs nothing and
removes all three.

**It provides no confidentiality.** Anyone holding either binary has that PSK. Nothing in this
exchange may depend on the channel for secrecy — the device key is sealed under the
SPAKE2-derived key and would be equally safe in the clear.

**The bootstrap PSK must not be derived from the code.** This is the obvious future
"improvement" and it would destroy the design: a passive observer could attack the TLS handshake
offline to recover a 55-bit code, reintroducing precisely the offline attack SPAKE2 exists to
prevent. The channel's key is independent of the code, permanently.

### Named invariants

These are requirements, not implementation notes. Each gets a test.

1. The bootstrap PSK is **never** registered on the fleet listener.
2. The pairing listener exists **only** while a window is armed, and is torn down when the
   window closes by any route — success, expiry, cancel, or app termination.
3. A connection on the pairing listener may carry **only** PAKE frames. It cannot send `hello`
   or `cmd`, and there is no code path by which it reaches `SessionStore`.
4. The pairing listener has its **own** pending-connection cap and deadline, independent of the
   fleet listener's.

## 7. Flow

```
Mac arms:
  mint device key K (32 bytes)  +  code C (55 bits + check)
  open pairing listener L on an OS-assigned port, bootstrap PSK
  advertise the port in the Bonjour TXT record
  display: QR of packed(K, slot, endpoints)  and  C as XXXX-XXXX-XXXX

Phone, typed path:
  validate C's checksum locally        → fail here costs no attempt
  browse _flightdeck._tcp
    0 Macs   → "Can't find that Mac on this network. Scan the QR instead."
    1 Mac    → connect to its pairing port
    2+ Macs  → try each in turn; a wrong Mac spends an attempt on that Mac only
  SPAKE2 with C over L
  on confirmation: Mac sends seal(S, K ‖ slot ‖ macName)
  phone stores K in the Keychain, closes L's connection,
  reconnects to the fleet listener over TLS-PSK with K — the existing path, unchanged
```

**Rate limiting is per-Mac, per-window.** Three failed confirmations burn the window; the Mac
closes the pairing listener and the user re-arms. It is explicitly *not* a global counter: a
phone legitimately trying three discovered Macs must not exhaust the budget on the right one.
A failed *checksum* is not an attempt — it never reaches the Mac.

## 8. The QR payload, packed

The QR keeps carrying the key directly. It stops carrying JSON.

Packed as raw bytes: version, slot (16), key (32), and one endpoint (IPv4 + port, 6) — about
**55 bytes**, roughly QR version 4 at ~33 modules. At the same 240pt that is close to double the
module size and four times the area of today's code.

Dropped from the payload, because the phone learns them anyway: the Mac's display name (it
arrives with the first snapshot), the Bonjour service name (derivable from the slot), and the
endpoint list beyond the first (Bonjour supplies the rest, and the remembered-endpoint race
exists for reconnects, not for pairing).

**Amendment (from execution, 2026-08-22): both names stayed, because both reasons for dropping
them are false.** Kept here rather than deleted, because the claim is the reason the ~55-byte
target was written down and a reader who remembers it needs to find out where it went.

- **The display name does not arrive with the first snapshot.** `FleetSnapshot`
  (`Sources/FleetKit/Wire.swift`) is one field, `projects`, and carries no Mac identity at all.
  Nothing else on the wire ever tells the phone what to call the machine it paired with, so
  dropping the name from the code would leave the phone's own UI with no name to show.
- **The service name is not derivable from the slot.** `FleetService.derivedServiceName` is a
  sanitised local host name, capped at 24 characters, plus the per-install suffix — stable per
  Mac and unrelated to any slot UUID. `FleetConnector.startBrowsing` matches Bonjour results
  against exactly that string (`name == self.mac.serviceName`), so a phone that did not receive
  it browses `_flightdeck._tcp` and matches nothing. Dropping it to save bytes would cost
  reconnection, which is the thing pairing exists to set up.
- **The endpoint list beyond the first was genuinely dropped**, for the reason given. That part
  of the paragraph above stands.

**What carrying them costs, and what the packing still bought.** Both names are length-prefixed,
one byte each. For the payload the density test uses — `Nate's MacBook Pro` and
`flightdeck-macbook-a1b2` — the record is **98 bytes**, of which the two names are 43; the
~55-byte figure above was never reachable while they are in it. The QR prediction misses in the
same direction and the shipped code still wins comfortably: measured through
`CIQRCodeGenerator` at correction level `M`, the packed code is **45 modules** against v1's
**65**, not the ~33 predicted here. Drawn at 240pt that is 5.1pt per module against 3.6 — 1.4×
the module size and 2.0× the area, where this section promised 2× and 4×.

Read those numbers out of
`PairingCodeImageTests.testThePackedPayloadProducesAMateriallySmallerQR`'s failure message
rather than from this paragraph, and read `modules(of:)`'s doc comment before scaling anything:
three different module counts were reported while this was being built, and the first two were
CoreImage *extents* — module count plus the one-module quiet zone per side — mistaken for module
counts. The test compares extents deliberately, which makes its threshold stricter than the
shrink it is measuring, not looser.

**The cheaper route, if the density ever matters more than it does now:** add `macName` and
`serviceName` to `FleetSnapshot`, decoded with `decodeIfPresent` so already-paired phones are
unaffected, then drop both from the payload and make this section's claim true. That is a wire
change and wants its own slice; it is recorded in `docs/FOLLOWUPS.md`.

## 9. What this changes in the original spec

§3 of `2026-08-18-mobile-companion-design.md` needs two amendments:

- The sentence "It is not a PAKE" becomes accurate-but-incomplete once a PAKE exists on one
  path. Replace it with the distinction in [§3](#3-what-the-pake-does-and-does-not-buy) above:
  the QR path is trust-on-first-use over the user's screen, the typed path adds a PAKE, and
  neither defends against someone photographing the screen.
- The claim that every connection is TLS with the device key gains one exception, scoped and
  named: the pairing listener, during the window, with a public PSK.

**Both were applied on 2026-08-22**, in place and marked, in §3 of that spec: the first as an
amendment under the trust-on-first-use paragraph, quoting the sentence it replaces; the second
appended to the TLS-with-the-device-key bullet itself, where the reader who needs the exception
is already standing.

## 10. Testing

- **SPAKE2 agreement between two independent sessions.** Not a published test vector — see the
  amendment in [§5](#5-the-pake): this vendored variant has no specification for a vector to
  conform to, so agreement between the two ends is the property that is checked instead.
- **The wrapper's role and name marshalling, against BoringSSL's raw C API.** Agreement between
  two `SPAKE2Session`s cannot catch a consistent role or name swap, and neither can a
  cross-process exchange — both ends run the same code. One side driven through the C API with
  a literal `spake2_role_alice` can; see §5's amendment.
- **Cross-process macOS-against-iOS pairing**, for **caller-side asymmetry**: the two ends
  disagreeing about which is the initiator, about the names they pass, or about the order in
  which they assemble the transcript. That last one is why `SPAKE2Session.transcript` exists —
  it is initiator-first on both sides so a caller cannot pick — but the check still belongs here.
- **Loopback pairing, end to end**: a real pairing listener, a real SPAKE2 exchange, a real
  sealed key, and a subsequent fleet connection authenticated with the delivered key. The same
  shape as the existing pairing-flow tests, which open real sockets and assert refusal at the
  transport rather than in a list.
- **Each invariant in [§6](#named-invariants) has a test**, and each must be shown to fail
  against the unfixed behaviour. Three tests on this branch have shipped unable to fail against
  the bug they were written for; that is the standing bar.
- **Rate limiting**: three failures burn the window; a fourth attempt is refused even with the
  correct code; per-Mac isolation holds when several are armed.
- **Checksum**: a single-character typo is rejected locally and does not reach the network.

## 11. Not in this slice

- **Replacing the QR.** It stays, and stays the off-LAN path.
- **Off-LAN typed pairing.** Bonjour-only is a stated limit, not an oversight.
- **Any change to steady-state transport.** Once paired, everything is exactly as it is today.
- **Migration.** Devices paired before this ships already hold their key and are unaffected;
  there is nothing to migrate.
