# Pairing Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the window-scoped pairing channel — its own TLS listener on a public bootstrap PSK, the PAKE frames that cross it, the three-attempt limit, Bonjour discovery, and the `FleetService` wiring — so a typed 12-character code can deliver a real device key over a real socket, entirely headlessly, before any screen depends on it.

**Architecture:** A second `NWListener` (`PairingListener`) lives only while a pairing window is armed. It speaks a frame vocabulary that contains no `hello` and no `cmd`, holds no reference to `SessionStore`, and carries a bootstrap PSK compiled into both binaries. The phone side ships in `FleetKit` too — `PairingInitiator` runs one exchange, `PairingBrowser` finds armed Macs over a dedicated Bonjour service type, and `PairingRunner` sequences "try each discovered Mac in turn" — so the whole phone-side flow is testable on macOS against real sockets.

**Tech Stack:** Swift 6 (`FleetKit`), Network.framework (TLS-PSK + WebSocket + Bonjour), CryptoKit, BoringSSL SPAKE2 via `SPAKE2Session`, XCTest.

**Spec:** [`docs/superpowers/specs/2026-08-21-short-pairing-code-design.md`](../specs/2026-08-21-short-pairing-code-design.md)

**Follows:** [`2026-08-21-pairing-code-foundation.md`](2026-08-21-pairing-code-foundation.md) (Plan A — `PairingCode`, `SPAKE2Session`, `PairingSecrets`, all shipped). **Precedes:** [`2026-08-21-pairing-ui.md`](2026-08-21-pairing-ui.md), which draws the code on the Mac, packs the QR, and puts a typed-entry field on the phone. This plan ships no UI change beyond keeping the existing sheet compiling.

## Why this is its own plan

The spec is one document; this is two plans, split on the same seam Plan A was split from Plan B — headless machinery first, screens second.

- **This plan produces working, testable software on its own.** Its final task's acceptance test arms a real `FleetService`, runs a real SPAKE2 exchange over a real socket, opens a real sealed key, and connects to the fleet listener with it. That is the whole feature, minus a way for a human to type the code.
- **The two halves fail review for different reasons.** Everything here is verified by `./scripts/test-unit.sh` against real sockets. Everything in the UI plan is verified by a build, a simulator, and a manual checklist — the class of check this repo already keeps in `docs/MOBILE.md`.
- **One document covering both would be unreviewable.** Thirteen tasks, two verification regimes, and a reviewer who cannot meaningfully reject the QR's byte packing while approving the rate limiter.

## Deviations from the spec, decided here

Two of the spec's mechanisms do not survive contact with Network.framework. Both are recorded here so an executor does not "fix" them back.

1. **§7 says "advertise the port in the Bonjour TXT record". It is advertised as its own Bonjour service instead** — `_flightdeck-pair._tcp`, carried by the pairing listener itself. `NWBrowser` hands back an `NWEndpoint.service(...)` that resolves to the *advertised* port; there is no API that composes a browsed service with a different port, so a port in a TXT record could only be dialled after separately learning the Mac's address — which on this design means first connecting to the fleet listener with a bootstrap PSK it will (correctly, per invariant 1) refuse. A separate service type is simpler, dialable directly, and makes the advertisement's lifetime *equal* the window's lifetime, which is invariant 2 restated as structure. The TXT record is still used — for the Mac's display name, so a phone that discovers several armed Macs can say which is which.
2. **The seal carries the device key and the Mac's display name, and nothing else** — that is Plan A's shipped `PairingSecrets.seal(_:macName:)` and this plan does not widen it. The phone learns the Bonjour **service name** from the browse result it dialled, and stores **no endpoints at all**: §11 makes typed pairing LAN-only, and `FleetConnector` reaches a Mac with an empty `endpoints` list purely by browsing `_flightdeck._tcp` for that service name. An empty remembered-endpoint list is the correct outcome of a typed pair, not a gap.

## Global Constraints

- **`FleetKit` imports Foundation, Network, Security, CryptoKit and `BoringSSLShim` only.** No AppKit, no UIKit, no SwiftUI. The `FleetKitiOS` target compiles the same sources for iOS and is what enforces this.
- **`FleetKit` builds in Swift 6 language mode.** The rest of the project is Swift 5.
- **`wait(for:)` deadlocks in a `@MainActor` async XCTest method** under this repo's headless harness. Use `await fulfillment(of:timeout:)`. Every test in this plan that awaits a socket is in that shape.
- **TLS-PSK here is the TLS 1.2 ciphersuite family.** `TLS_PSK_WITH_AES_128_GCM_SHA256` must be appended to every set of PSK options; pinning `sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)` silently breaks it. A refused or unnegotiable handshake presents as **silence**, not `.failed` — so every refusal test in this plan concludes from a timeout and is only evidence because a positive control alongside it reaches `.ready` in milliseconds. Do not delete the controls.
- **Take the SPAKE2 transcript from `SPAKE2Session.transcript`, on both sides, always.** It is initiator-message-first whichever side you are. The natural symmetric implementation — the same `myMsg + theirMsg` line on both ends — yields opposite orders, mismatched keys, and a Mac that reports "wrong code" for a correctly typed one while spending an attempt saying so. Nothing in this plan assembles a transcript by hand.
- **The bootstrap PSK and the pairing code stay independent, permanently.** Deriving one from the other hands a passive observer an offline attack on 55 bits — the exact attack SPAKE2 is here to prevent (spec §6).
- **Never run `./scripts/smoke.sh`.** It seizes the foreground and turns the user's keystrokes into phantom failures.
- **A debug instance and a simulator may be running.** Check `pgrep -f "harness/Flight Deck.app"` before running the suite, and never launch a build to "try it".
- **Verification per task:** `./scripts/test-unit.sh` (baseline **1208**, 0 failures) and `./scripts/build-ios.sh` (three `BUILD SUCCEEDED`). Report the count after every task.
- **A fresh clone needs `git submodule update --init vendor/boringssl` then `./scripts/build-boringssl.sh`** before either script will run.
- **This branch's standing bar: a test for a named invariant must be shown to fail against the unfixed behaviour.** Seven tests have shipped on this branch unable to fail against the bug they were written for, each caught late. Every invariant task below has an explicit "prove it can fail" step naming the exact mutation, and that step is not optional.

## File Structure

**Created — `Sources/FleetKit/Pairing/`** (a new directory; `project.yml` includes `Sources/FleetKit` recursively, so no build-file change is needed for these):

| File | Responsibility |
|---|---|
| `PairingChannel.swift` | The constants both ends share: the bootstrap PSK and its identity, the two SPAKE2 names, the Bonjour service type and TXT key. Nothing behavioural. |
| `PairingFrames.swift` | `PairingClientFrame` / `PairingServerFrame` / `PairingRejection`. **Internal, not public** — nothing outside FleetKit can construct a pairing frame, which is invariant 3 expressed as visibility. |
| `PairingListener.swift` | The Mac side: a window-scoped `NWListener`, its own pending cap and deadline, the responder half of SPAKE2, the attempt counter, the seal. |
| `PairingInitiator.swift` | The phone side: one exchange against one endpoint. |
| `PairingBrowser.swift` | Finds armed Macs on `_flightdeck-pair._tcp`. |
| `PairingRunner.swift` | Policy over the two above: 0 / 1 / 2+ Macs, tried in turn. |

**Modified:**

| File | Change |
|---|---|
| `Sources/FleetKit/FleetTLS.swift` | `pairingListenerParameters()` / `pairingClientParameters()`. |
| `Sources/FleetKit/FleetSocket.swift` | Hoist `webSocketEndpoint(for:)` out of `FleetClient` so both clients share it. |
| `Sources/FleetKit/FleetClient.swift` | Call the hoisted helper. |
| `Sources/FleetKit/SPAKE2/PairingSecrets.swift` | Add `PairingSecrets.matches(_:_:)`, constant-time. |
| `Sources/FlightDeck/Fleet/PairingArmer.swift` | Mint a `PairingCode`; return `ArmedPairing`. |
| `Sources/FlightDeck/Fleet/FleetService.swift` | Own a `PairingListener`; start it on arm, stop it on every window close. |
| `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift` | The `.sheet(item:)` binds `ArmedPairing` instead of `PairingPayload`. Presentation only — the UI plan changes what is drawn. |
| `project.yml` | Add `_flightdeck-pair._tcp` to `FlightDeckMobile`'s `NSBonjourServices`. |

**Test files created:** `PairingChannelTests`, `PairingFrameCodingTests`, `PairingTestClient` (a helper, not a test class), `PairingListenerTests`, `PairingInitiatorTests`, `PairingRateLimitTests`, `PairingDiscoveryTests`, `PairingRunnerTests`, `PairingWindowTests` — all under `Tests/FlightDeckTests/`.

---

### Task 1: The bootstrap channel

**Files:**
- Create: `Sources/FleetKit/Pairing/PairingChannel.swift`
- Modify: `Sources/FleetKit/FleetTLS.swift` (add two public factories + one private builder)
- Test: `Tests/FlightDeckTests/PairingChannelTests.swift`

**Interfaces:**
- Consumes: `FleetTLS.listenerParameters(keys:)`, `FleetDeviceKey`, `Data.dispatch` (all shipped).
- Produces: `PairingChannel.bonjourType: String`, `PairingChannel.txtNameKey: String`, `PairingChannel.initiatorName: Data`, `PairingChannel.responderName: Data`, `PairingChannel.bootstrapSecret: Data`, `PairingChannel.bootstrapIdentity: Data`, `FleetTLS.pairingListenerParameters() -> NWParameters`, `FleetTLS.pairingClientParameters() -> NWParameters`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/PairingChannelTests.swift`:

```swift
import Network
import XCTest
@testable import FleetKit

/// Invariant 1 of the spec's §6, tested as a boundary rather than as a list assertion: the
/// bootstrap PSK gets a peer onto the pairing channel and gets it nowhere near the fleet
/// listener.
///
/// A refused PSK handshake presents as *silence* — Apple's PSK path drops a mismatched
/// identity rather than sending an alert — so the refusal here is concluded from a timeout,
/// and that is only evidence because `testTheBootstrapPSKCompletesAPairingHandshake` below
/// exercises the identical client parameters against a listener that does accept them and
/// reaches `.ready` in milliseconds. It is the control. Deleting it leaves the refusal test
/// passing while proving nothing.
final class PairingChannelTests: XCTestCase {
    private var listener: NWListener?

    override func tearDown() {
        listener?.cancel()
        listener = nil
        super.tearDown()
    }

    private func startListener(using parameters: NWParameters) throws -> NWEndpoint.Port {
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { $0.start(queue: .main) }
        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(listener.port)
    }

    /// Returns whether a connection built from `parameters` reaches `.ready` against `port`.
    private func reaches(
        _ port: NWEndpoint.Port, using parameters: NWParameters, timeout: TimeInterval = 2
    ) -> Bool {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: parameters)
        let settled = expectation(description: "settled")
        var ready = false
        var hasSettled = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                guard !hasSettled else { return }
                hasSettled = true
                if case .ready = state { ready = true }
                settled.fulfill()
            default:
                break
            }
        }
        connection.start(queue: .main)
        let outcome = XCTWaiter().wait(for: [settled], timeout: timeout)
        connection.cancel()
        return outcome == .completed && ready
    }

    func testTheBootstrapPSKCompletesAPairingHandshake() throws {
        let port = try startListener(using: FleetTLS.pairingListenerParameters())
        XCTAssertTrue(reaches(port, using: FleetTLS.pairingClientParameters()))
    }

    /// Invariant 1. The bootstrap PSK is in every copy of both binaries, so a fleet listener
    /// that accepted it would accept everyone — and would do it *before* any pairing had
    /// happened, which is the one thing the fleet listener's whole trust story rests on.
    func testTheBootstrapPSKIsRefusedByTheFleetListener() throws {
        let port = try startListener(using: FleetTLS.listenerParameters(keys: [.mint()]))
        XCTAssertFalse(
            reaches(port, using: FleetTLS.pairingClientParameters()),
            "the bootstrap PSK reached the fleet listener"
        )
    }

    /// `FleetSocketServer.slot(of:)` turns a PSK identity into a slot with
    /// `UUID(uuidString:)`. A bootstrap identity that happened to parse as a UUID would be
    /// attributable to a paired device, so it is deliberately not shaped like one.
    func testTheBootstrapIdentityCannotBeMistakenForASlot() {
        let text = String(decoding: PairingChannel.bootstrapIdentity, as: UTF8.self)
        XCTAssertNil(UUID(uuidString: text))
    }

    /// The spec's §6, stated as a test because it is the "improvement" someone will propose:
    /// deriving the channel's key from the code gives a passive observer an offline attack on
    /// 55 bits, which is precisely what SPAKE2 is here to prevent.
    func testTheBootstrapSecretIsIndependentOfAnyPairingCode() {
        let first = PairingCode.mint()
        let second = PairingCode.mint()
        XCTAssertNotEqual(PairingChannel.bootstrapSecret, first.secret)
        XCTAssertNotEqual(PairingChannel.bootstrapSecret, second.secret)
        XCTAssertEqual(PairingChannel.bootstrapSecret.count, 32)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -40`

Expected: compile failure — `cannot find 'PairingChannel' in scope`, `value of type 'FleetTLS' has no member 'pairingListenerParameters'`.

- [ ] **Step 3: Write the constants**

Create `Sources/FleetKit/Pairing/PairingChannel.swift`:

```swift
import CryptoKit
import Foundation

/// The constants the two ends of a pairing exchange must agree on byte for byte.
///
/// One file, shared by both binaries, because every value here is a place where "the Mac and
/// the phone each wrote their own" produces a failure that looks like a wrong code: a
/// different name reaches the SPAKE2 transcript, a different service type finds nothing, a
/// different PSK never completes a handshake. None of those announce themselves as what they
/// are.
public enum PairingChannel {
    /// The pairing listener's own Bonjour service, distinct from the fleet's
    /// `_flightdeck._tcp`. It exists only while a window is armed, so its presence *is* the
    /// "this Mac is pairable right now" signal — see the plan's "Deviations from the spec".
    public static let bonjourType = "_flightdeck-pair._tcp"

    /// The TXT key carrying the Mac's display name, so a phone that discovers two armed Macs
    /// can name them. Cosmetic, and treated as such: it is unauthenticated text from the
    /// network until the exchange completes and the seal delivers the real name.
    public static let txtNameKey = "name"

    /// The SPAKE2 names, fixed by role rather than taken from either device.
    ///
    /// SPAKE2 binds both names into its transcript to stop one exchange being replayed into a
    /// different context. Device names cannot serve that here: on the typed path the phone
    /// has not learned the Mac's name yet — that is what the seal delivers — so any
    /// name-derived scheme would have the two sides guessing at each other. Fixed role labels
    /// give a fixed, agreed context, which is all the binding needs to be.
    public static let initiatorName = Data("flightdeck-phone".utf8)
    public static let responderName = Data("flightdeck-mac".utf8)

    /// The bootstrap PSK's identity. Deliberately not a UUID string: `FleetSocketServer`
    /// turns a PSK identity into a paired slot with `UUID(uuidString:)`, and an identity that
    /// parsed would be attributable to a device that does not exist.
    public static let bootstrapIdentity = Data("flightdeck-pairing-bootstrap-v1".utf8)

    /// **Public by design and by construction.** Anyone holding either binary has this, so it
    /// provides no confidentiality whatsoever and nothing in the pairing exchange may depend
    /// on the channel for secrecy — the device key is sealed under the SPAKE2-derived key and
    /// would be equally safe in the clear.
    ///
    /// What it buys is narrower and still worth having: no plaintext frames on the wire for a
    /// passive capture, an IDS or a network log to collect, and no unauthenticated frame
    /// parser reachable with nothing in front of it.
    ///
    /// **It must never be derived from the pairing code** (spec §6). That derivation is the
    /// obvious future "improvement" and it would let a passive observer attack the TLS
    /// handshake offline to recover 55 bits — reintroducing exactly the offline attack SPAKE2
    /// exists to prevent. A hash of a fixed string rather than a 32-byte literal only so the
    /// constant is readable; it is no more secret for being hashed.
    public static let bootstrapSecret = Data(
        SHA256.hash(data: Data("dev.flightdeck.pairing.bootstrap.v1".utf8))
    )
}
```

- [ ] **Step 4: Add the TLS factories**

In `Sources/FleetKit/FleetTLS.swift`, add to the `FleetTLS` enum, directly after `clientParameters(key:)`:

```swift
    /// The pairing listener's parameters: exactly one PSK, the public bootstrap one.
    ///
    /// A separate function rather than `listenerParameters(keys:)` with the bootstrap key
    /// folded into the array, and that is invariant 1 made structural: there is no argument
    /// anyone can pass to the fleet listener that puts the bootstrap PSK on it.
    public static func pairingListenerParameters() -> NWParameters {
        let parameters = bootstrapParameters()
        // Same narrow purpose as on the fleet listener: a socket the OS is still draining
        // from a previous run of this process. The pairing listener always takes a fresh
        // OS-assigned port, so it never rebinds one of its own.
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    /// The phone's side of the same channel.
    public static func pairingClientParameters() -> NWParameters {
        bootstrapParameters()
    }

    private static func bootstrapParameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(
            sec,
            PairingChannel.bootstrapSecret.dispatch,
            PairingChannel.bootstrapIdentity.dispatch
        )
        // Required, for the same trap documented in `parameters(keys:identities:)`:
        // Network.framework's PSK support is the TLS **1.2** PSK ciphersuite family. Without
        // this append the handshake offers nothing the peer can agree to and simply hangs,
        // and pinning a 1.3 minimum breaks it identically. Do not add that pin.
        sec_protocol_options_append_tls_ciphersuite(
            sec, tls_ciphersuite_t(rawValue: numericCast(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        // No `multipathServiceType` and no PSK-selection block, unlike the fleet parameters.
        // A pairing exchange is four frames on one LAN inside a two-minute window — it has no
        // roaming to survive — and with exactly one registered PSK there is no identity to
        // attribute a connection to.
        return NWParameters(tls: tls)
    }
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1212** tests, 0 failures (1208 + 4).

- [ ] **Step 6: Prove the invariant test can fail**

This is the standing bar and it is not optional. Temporarily edit `pairingListenerParameters()`'s caller side instead — in the test, change

```swift
        let port = try startListener(using: FleetTLS.listenerParameters(keys: [.mint()]))
```

to a listener that registers the bootstrap PSK the way a careless refactor would:

```swift
        let port = try startListener(using: FleetTLS.listenerParameters(keys: [
            .mint(),
            FleetDeviceKey(slot: UUID(), secret: PairingChannel.bootstrapSecret)
        ]))
```

Run: `./scripts/test-unit.sh 2>&1 | grep -A3 testTheBootstrapPSKIsRefusedByTheFleetListener`

Expected: **FAIL** — "the bootstrap PSK reached the fleet listener". (The identity differs, but the PSK *secret* is what the handshake proves, and a listener holding it will complete one.) Then revert the edit and re-run to green.

If it does *not* fail, stop. The test is not testing what it claims and must be fixed before the task is complete.

- [ ] **Step 7: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

Expected: three successes, no errors. `PairingChannel` imports CryptoKit and Foundation only, so the `FleetKitiOS` boundary holds.

- [ ] **Step 8: Commit**

```bash
git add Sources/FleetKit/Pairing/PairingChannel.swift Sources/FleetKit/FleetTLS.swift Tests/FlightDeckTests/PairingChannelTests.swift
git commit -m "feat: a bootstrap channel the fleet listener will not accept"
```

---

### Task 2: PAKE frames and a constant-time compare

**Files:**
- Create: `Sources/FleetKit/Pairing/PairingFrames.swift`
- Modify: `Sources/FleetKit/SPAKE2/PairingSecrets.swift` (add `matches(_:_:)`)
- Test: `Tests/FlightDeckTests/PairingFrameCodingTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 but the module.
- Produces (all **internal** to FleetKit except `matches`): `PairingClientFrame` with cases `.pake(msg: Data)` and `.confirm(mac: Data)`; `PairingServerFrame` with cases `.pake(msg: Data)`, `.sealed(mac: Data, box: Data)` and `.reject(PairingRejection)`; `PairingRejection` with cases `.badCode`, `.attemptsExhausted`, `.malformed`; `PairingSecrets.matches(_ lhs: Data, _ rhs: Data) -> Bool` (public, static).

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/PairingFrameCodingTests.swift`:

```swift
import Foundation
import XCTest
@testable import FleetKit

/// `@testable`, deliberately: the pairing frames are internal to FleetKit. Nothing outside
/// the module can construct one, which is the visibility half of invariant 3 — a caller in
/// the app cannot accidentally hand a `hello` to the pairing socket because it cannot express
/// one in this vocabulary at all.
final class PairingFrameCodingTests: XCTestCase {
    private func roundTrip<Frame: Codable & Equatable>(_ frame: Frame) throws -> Frame {
        try JSONDecoder().decode(Frame.self, from: JSONEncoder().encode(frame))
    }

    func testEveryClientFrameRoundTrips() throws {
        let pake = PairingClientFrame.pake(msg: Data(repeating: 0xAB, count: 32))
        let confirm = PairingClientFrame.confirm(mac: Data(repeating: 0xCD, count: 32))
        XCTAssertEqual(try roundTrip(pake), pake)
        XCTAssertEqual(try roundTrip(confirm), confirm)
    }

    func testEveryServerFrameRoundTrips() throws {
        let pake = PairingServerFrame.pake(msg: Data(repeating: 0x11, count: 32))
        let sealed = PairingServerFrame.sealed(
            mac: Data(repeating: 0x22, count: 32), box: Data(repeating: 0x33, count: 80)
        )
        XCTAssertEqual(try roundTrip(pake), pake)
        XCTAssertEqual(try roundTrip(sealed), sealed)
        for reason in [PairingRejection.badCode, .attemptsExhausted, .malformed] {
            XCTAssertEqual(try roundTrip(PairingServerFrame.reject(reason)), .reject(reason))
        }
    }

    /// A frame this vocabulary does not contain must throw rather than decode to something
    /// nearby. `FleetSocket.receive` turns a decode failure into `onEnd`, which is what drops
    /// the connection — so "unparseable" is the mechanism by which a `hello` sent at a
    /// pairing socket goes nowhere.
    func testAFleetHelloIsNotDecodableAsAPairingFrame() throws {
        let hello = try JSONEncoder().encode(ClientFrame.hello(lastSeq: 0, device: "iPhone"))
        XCTAssertThrowsError(try JSONDecoder().decode(PairingClientFrame.self, from: hello))
    }

    func testAnUnknownTagIsRejected() {
        let json = Data(#"{"t":"cmd","cid":1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PairingClientFrame.self, from: json))
    }

    /// `==` on `Data` stops at the first differing byte, and with three attempts per window
    /// "how many leading bytes did I get right" is exactly the signal that makes guessing
    /// cheaper than the limit intends. This pins behaviour, not timing — the constant-time
    /// property is by construction, and a timing assertion in a unit suite is noise.
    func testConstantTimeComparisonAgreesWithEqualityOnEveryShape() {
        let value = Data(repeating: 0x5A, count: 32)
        var flipped = value
        flipped[31] ^= 0x01
        var flippedFirst = value
        flippedFirst[0] ^= 0x80

        XCTAssertTrue(PairingSecrets.matches(value, value))
        XCTAssertFalse(PairingSecrets.matches(value, flipped))
        XCTAssertFalse(PairingSecrets.matches(value, flippedFirst))
        XCTAssertFalse(PairingSecrets.matches(value, value.dropLast()))
        XCTAssertFalse(PairingSecrets.matches(Data(), value))
        XCTAssertTrue(PairingSecrets.matches(Data(), Data()))
    }

    /// The comparison must not be fooled by a slice whose `startIndex` is not zero —
    /// `AES.GCM.open` and every `Data` subscript in this module produce those routinely.
    func testComparisonIsIndexOriginAgnostic() {
        let padded = Data(repeating: 0x00, count: 8) + Data(repeating: 0x7F, count: 32)
        let slice = padded[8...]
        XCTAssertEqual(slice.startIndex, 8)
        XCTAssertTrue(PairingSecrets.matches(slice, Data(repeating: 0x7F, count: 32)))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: compile failure — `cannot find 'PairingClientFrame' in scope`.

- [ ] **Step 3: Write the frames**

Create `Sources/FleetKit/Pairing/PairingFrames.swift`:

```swift
import Foundation

/// Why the Mac stopped. Sent in the clear, so it says only what the phone needs to choose its
/// next screen — never how close a guess was.
enum PairingRejection: String, Codable, Equatable, Sendable {
    /// The confirmation did not verify. From the Mac's side that is indistinguishable from a
    /// typo, and it costs one of three attempts.
    case badCode
    /// This window's three attempts are gone. A different message from `badCode` because it
    /// sends the user somewhere different: back to the Mac to arm again, not back to the
    /// keyboard.
    case attemptsExhausted
    /// The frame did not make sense at all — a message that is not a curve point, a
    /// confirmation before a PAKE. Not a code guess, so it costs no attempt.
    case malformed
}

/// Phone → Mac, on the pairing channel only.
///
/// **Internal, and that is invariant 3 (spec §6) expressed as visibility.** This vocabulary
/// contains no `hello` and no `cmd`, and no code outside FleetKit can construct any pairing
/// frame at all — so "a bootstrap connection must never reach `SessionStore`" is a property of
/// what can be said on this socket rather than a check somebody has to remember to write.
enum PairingClientFrame: Codable, Equatable, Sendable {
    /// The phone's SPAKE2 message, 32 bytes. First frame on the connection.
    case pake(msg: Data)
    /// `PairingSecrets.initiatorConfirmation`, 32 bytes. Only frame after the Mac's `pake`.
    case confirm(mac: Data)

    enum CodingKeys: String, CodingKey { case t, msg, mac }

    private enum Tag: String, Codable { case pake, confirm }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pake(let msg):
            try c.encode(Tag.pake, forKey: .t)
            try c.encode(msg, forKey: .msg)
        case .confirm(let mac):
            try c.encode(Tag.confirm, forKey: .t)
            try c.encode(mac, forKey: .mac)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .pake: self = .pake(msg: try c.decode(Data.self, forKey: .msg))
        case .confirm: self = .confirm(mac: try c.decode(Data.self, forKey: .mac))
        }
    }
}

/// Mac → phone, on the pairing channel only.
enum PairingServerFrame: Codable, Equatable, Sendable {
    /// The Mac's SPAKE2 message, 32 bytes.
    case pake(msg: Data)
    /// `PairingSecrets.responderConfirmation` plus the sealed device key. Both in one frame
    /// because they are one statement — "here is proof I knew the code, and here is what that
    /// proof was for" — and a phone that received the box without the proof would have to
    /// decide what to do with a key from a Mac that had proved nothing.
    case sealed(mac: Data, box: Data)
    case reject(PairingRejection)

    enum CodingKeys: String, CodingKey { case t, msg, mac, box, reason }

    private enum Tag: String, Codable { case pake, sealed, reject }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pake(let msg):
            try c.encode(Tag.pake, forKey: .t)
            try c.encode(msg, forKey: .msg)
        case .sealed(let mac, let box):
            try c.encode(Tag.sealed, forKey: .t)
            try c.encode(mac, forKey: .mac)
            try c.encode(box, forKey: .box)
        case .reject(let reason):
            try c.encode(Tag.reject, forKey: .t)
            try c.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Tag.self, forKey: .t) {
        case .pake:
            self = .pake(msg: try c.decode(Data.self, forKey: .msg))
        case .sealed:
            self = .sealed(
                mac: try c.decode(Data.self, forKey: .mac),
                box: try c.decode(Data.self, forKey: .box)
            )
        case .reject:
            self = .reject(try c.decode(PairingRejection.self, forKey: .reason))
        }
    }
}
```

- [ ] **Step 4: Add the constant-time compare**

In `Sources/FleetKit/SPAKE2/PairingSecrets.swift`, add inside `struct PairingSecrets`, directly above `initiatorConfirmation`:

```swift
    /// Constant-time equality for confirmation values.
    ///
    /// `==` on `Data` short-circuits at the first differing byte. That leaks how many leading
    /// bytes of a confirmation an attacker got right — and against a three-attempt budget,
    /// "how far did I get" is precisely the feedback the budget exists to deny. The loop below
    /// always walks the whole length.
    ///
    /// Length is compared up front and non-constant-time on purpose: the length of a
    /// confirmation is fixed by the protocol and public, so it is not a secret being leaked.
    ///
    /// `zip` over two `Data` values rather than any index arithmetic, so a slice whose
    /// `startIndex` is not zero — what every `AES.GCM.open` result and every subscript in this
    /// module produces — compares by content rather than by position.
    public static func matches(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1218** tests, 0 failures (1212 + 6).

- [ ] **Step 6: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/Pairing/PairingFrames.swift Sources/FleetKit/SPAKE2/PairingSecrets.swift Tests/FlightDeckTests/PairingFrameCodingTests.swift
git commit -m "feat: a frame vocabulary with no hello in it"
```

---

### Task 3: The pairing listener

**Files:**
- Create: `Sources/FleetKit/Pairing/PairingListener.swift`
- Modify: `Sources/FleetKit/FleetSocket.swift` (hoist `webSocketEndpoint(for:)`)
- Modify: `Sources/FleetKit/FleetClient.swift` (call the hoisted helper)
- Create: `Tests/FlightDeckTests/PairingTestClient.swift` (helper, no test methods)
- Test: `Tests/FlightDeckTests/PairingListenerTests.swift`

**Interfaces:**
- Consumes: `PairingChannel.*`, `FleetTLS.pairingListenerParameters()`, `PairingClientFrame`, `PairingServerFrame`, `PairingRejection`, `PairingSecrets.matches(_:_:)`, and from Plan A: `SPAKE2Session(role:myName:theirName:)`, `.message(for:)`, `.keyMaterial(from:)`, `.transcript`, `PairingSecrets(keyMaterial:transcript:)`, `.initiatorConfirmation`, `.responderConfirmation`, `.seal(_:macName:)`.
- Produces: `PairingListener` — `init(queue: DispatchQueue = .main)`; `static let maxAttempts = 3`; `var authDeadline: TimeInterval`; `static let maxPending = 4`; `public private(set) var attemptsSpent: Int`; `var onPaired: (() -> Void)?`; `var onAttemptsExhausted: (() -> Void)?`; `func start(code:key:macName:serviceName:port:) async throws -> NWEndpoint.Port`; `func stop()`. Also `FleetSocket.webSocketEndpoint(for:) -> NWEndpoint` (internal).
- Produces for tests: `PairingTestClient` — `init(endpoint: NWEndpoint)`, `var onFrame: ((PairingServerFrame) -> Void)?`, `var onEnd: (() -> Void)?`, `func start()`, `func send(_ frame: PairingClientFrame)`, `func stop()`.

- [ ] **Step 1: Hoist the WebSocket endpoint translation**

`PairingInitiator` and the test client both dial with WebSocket framing, so both hit the trap `FleetClient` already documents: `NWProtocolWebSocket` needs a URL to build its Upgrade request from and aborts a bare `.hostPort` with `ECONNABORTED` before `.ready`. Move the helper rather than copy it.

Cut this method out of `Sources/FleetKit/FleetClient.swift` (including its whole doc comment) and paste it into `enum FleetSocket` in `Sources/FleetKit/FleetSocket.swift`, changing `private static func` to `static func`:

```swift
    /// `NWProtocolWebSocket`'s automatic HTTP-upgrade handshake needs a URL to build its
    /// Upgrade request from. Handed a bare `.hostPort` endpoint instead — what most callers
    /// here pass — it aborts the connection (`ECONNABORTED`, silently, before `.ready`)
    /// rather than falling back to something host/port alone could satisfy; a plain TLS-PSK
    /// connection built from the identical parameters, minus the WebSocket layer, completes
    /// in single-digit milliseconds, which is what isolates this to the WebSocket handshake
    /// rather than to TLS-PSK or to loopback itself. So `.hostPort` is translated to a `wss`
    /// URL here rather than pushing the workaround onto every call site.
    ///
    /// A `.service` endpoint from an `NWBrowser` is passed through untouched, and that is the
    /// shipped behaviour rather than an assumption: `FleetConnector` has always dialled
    /// browsed services this way, over these same WebSocket parameters. The pairing path
    /// relies on it too — its whole typed flow dials `.service` endpoints.
    static func webSocketEndpoint(for endpoint: NWEndpoint) -> NWEndpoint {
        guard case .hostPort(let host, let port) = endpoint else { return endpoint }
        // IPv6 literals need bracketing to be valid inside a URL authority; every other
        // host form's description is already URL-safe as-is.
        let hostText: String
        switch host {
        case .ipv6:
            hostText = "[\(host)]"
        default:
            hostText = "\(host)"
        }
        guard let url = URL(string: "wss://\(hostText):\(port.rawValue)/") else { return endpoint }
        return .url(url)
    }
```

Then in `FleetClient.connect(to:lastSeq:)` change the one call site:

```swift
        let connection = NWConnection(to: FleetSocket.webSocketEndpoint(for: endpoint), using: parameters)
```

Run: `./scripts/test-unit.sh 2>&1 | tail -5` — expected **1218**, 0 failures. A pure move, so nothing changes.

- [ ] **Step 2: Write the test client**

Create `Tests/FlightDeckTests/PairingTestClient.swift`:

```swift
import Foundation
import Network
@testable import FleetKit

/// A hand-written phone side, used by `PairingListenerTests` before `PairingInitiator` exists.
///
/// It stays after `PairingInitiator` lands rather than being replaced by it, and that is the
/// point of it: the spec's §5 amendment is explicit that a *consistent* role or name swap
/// inside `SPAKE2Session` survives any exchange where both ends run the same code, and what
/// catches caller-side mistakes is a second implementation of the **caller**. This one drives
/// the initiator half from the protocol description rather than from `PairingInitiator`, so a
/// listener that answered the wrong role, or assembled its transcript the other way round,
/// fails here rather than agreeing with a mirror of itself.
///
/// Frame plumbing only: it holds no SPAKE2 state. The tests own that, which is what lets them
/// send a confirmation the protocol would never produce.
final class PairingTestClient: @unchecked Sendable {
    var onFrame: ((PairingServerFrame) -> Void)?
    var onEnd: (() -> Void)?

    private let endpoint: NWEndpoint
    private var connection: NWConnection?
    private var ended = false

    init(endpoint: NWEndpoint) {
        self.endpoint = endpoint
    }

    func start() {
        let parameters = FleetSocket.webSocketParameters(FleetTLS.pairingClientParameters())
        let connection = NWConnection(
            to: FleetSocket.webSocketEndpoint(for: endpoint), using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        FleetSocket.receive(PairingServerFrame.self, from: connection) { [weak self] frame in
            guard let self, !self.ended else { return }
            self.onFrame?(frame)
        } onEnd: { [weak self] _ in
            self?.finish()
        }
        connection.start(queue: .main)
    }

    func send(_ frame: PairingClientFrame) {
        guard let connection else { return }
        FleetSocket.send(frame, over: connection)
    }

    func stop() {
        ended = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        onEnd?()
    }
}
```

- [ ] **Step 3: Write the failing tests**

Create `Tests/FlightDeckTests/PairingListenerTests.swift`:

```swift
import Foundation
import Network
import XCTest
@testable import FleetKit

@MainActor
final class PairingListenerTests: XCTestCase {
    private var listener: PairingListener?
    private var clients: [PairingTestClient] = []
    private var fleet: FleetSocketServer?

    override func tearDown() async throws {
        for client in clients { client.stop() }
        clients.removeAll()
        listener?.stop()
        listener = nil
        fleet?.stop()
        fleet = nil
    }

    private func arm(
        code: PairingCode = .mint(), key: FleetDeviceKey = .mint(), macName: String = "Test Mac"
    ) async throws -> (listener: PairingListener, endpoint: NWEndpoint) {
        let listener = PairingListener()
        self.listener = listener
        let port = try await listener.start(
            code: code, key: key, macName: macName,
            serviceName: "flightdeck-test-\(UUID().uuidString.prefix(8))", port: nil
        )
        return (listener, .hostPort(host: "127.0.0.1", port: port))
    }

    private func client(_ endpoint: NWEndpoint) -> PairingTestClient {
        let client = PairingTestClient(endpoint: endpoint)
        clients.append(client)
        return client
    }

    /// The exchange, driven from the protocol rather than from `PairingInitiator` — see
    /// `PairingTestClient`'s doc comment for why that distinction is the whole value of this
    /// test. The initiator role, the two names, and the transcript all come from
    /// `PairingChannel` and `SPAKE2Session`, so a listener that disagreed about any of them
    /// produces a confirmation that does not verify and this fails.
    func testAnHonestExchangeDeliversTheSealedDeviceKey() async throws {
        let code = PairingCode.mint()
        let key = FleetDeviceKey.mint()
        let (_, endpoint) = try await arm(code: code, key: key, macName: "Nate's MacBook")

        let session = SPAKE2Session(
            role: .initiator,
            myName: PairingChannel.initiatorName, theirName: PairingChannel.responderName
        )
        let opened = expectation(description: "sealed key opened")
        nonisolated(unsafe) var delivered: (key: FleetDeviceKey, macName: String)?
        nonisolated(unsafe) var secrets: PairingSecrets?

        let client = client(endpoint)
        client.onFrame = { frame in
            MainActor.assumeIsolated {
                switch frame {
                case .pake(let peer):
                    do {
                        let material = try session.keyMaterial(from: peer)
                        // `session.transcript`, never `myMsg + peer` — it is initiator-first
                        // on both sides, and assembling it here is the mistake the property
                        // exists to make unavailable.
                        let derived = try PairingSecrets(
                            keyMaterial: material, transcript: session.transcript
                        )
                        secrets = derived
                        client.send(.confirm(mac: derived.initiatorConfirmation))
                    } catch {
                        XCTFail("initiator half failed: \(error)")
                    }
                case .sealed(let mac, let box):
                    guard let secrets else { return XCTFail("sealed before pake") }
                    XCTAssertTrue(
                        PairingSecrets.matches(mac, secrets.responderConfirmation),
                        "the Mac's own confirmation did not verify"
                    )
                    delivered = try? secrets.open(box)
                    opened.fulfill()
                case .reject(let reason):
                    XCTFail("rejected: \(reason)")
                }
            }
        }
        client.start()
        // The first frame cannot go before `.ready`, and `PairingTestClient` does not queue —
        // so the PAKE message is sent from the state handler's stead here: give the socket a
        // moment, then send. `onFrame` drives everything after it.
        try await Task.sleep(for: .milliseconds(300))
        client.send(.pake(msg: try session.message(for: code)))

        await fulfillment(of: [opened], timeout: 15)
        let result = try XCTUnwrap(delivered)
        XCTAssertEqual(result.key.slot, key.slot)
        XCTAssertEqual(result.key.secret, key.secret)
        XCTAssertEqual(result.macName, "Nate's MacBook")
    }

    /// Invariant 4, first half: the pairing listener's pending pool is its own. Filling it
    /// must not consume anything the fleet listener needs, and the proof of that is a real
    /// paired device attaching to a real fleet listener while the pairing pool is full.
    func testFillingThePairingListenersPendingPoolLeavesTheFleetListenerServing() async throws {
        let (_, endpoint) = try await arm()

        let key = FleetDeviceKey.mint()
        let fleet = FleetSocketServer()
        fleet.onHello = { _, _ in [.snapshot(seq: 1, fleet: .empty, reason: .initial)] }
        self.fleet = fleet
        let fleetPort = try await fleet.start(keys: [key], port: nil)

        // Silent connections, twice the pairing listener's cap. None of them ever speaks, so
        // each occupies a pending slot until its deadline.
        for _ in 0..<(PairingListener.maxPending * 2) {
            let filler = client(endpoint)
            filler.start()
        }
        try await Task.sleep(for: .milliseconds(500))

        let served = expectation(description: "fleet still serving")
        let fleetClient = FleetClient(key: key)
        fleetClient.onFrame = { if case .snapshot = $0 { served.fulfill() } }
        fleetClient.connect(to: .hostPort(host: "127.0.0.1", port: fleetPort), lastSeq: 0)
        await fulfillment(of: [served], timeout: 15)
        fleetClient.disconnect()
    }

    /// Invariant 4, second half: its own deadline. A peer that completes the bootstrap
    /// handshake and then says nothing is dropped, so a window cannot be held open by silence.
    func testASilentPairingConnectionIsDroppedOnItsOwnDeadline() async throws {
        let listener = PairingListener()
        self.listener = listener
        listener.authDeadline = 0.5
        let port = try await listener.start(
            code: .mint(), key: .mint(), macName: "Test Mac",
            serviceName: "flightdeck-test-\(UUID().uuidString.prefix(8))", port: nil
        )

        let dropped = expectation(description: "dropped")
        let silent = client(.hostPort(host: "127.0.0.1", port: port))
        silent.onEnd = { dropped.fulfill() }
        silent.start()
        await fulfillment(of: [dropped], timeout: 10)
    }

    /// A message that is not a curve point is a protocol error, not a code guess: it must be
    /// refused without touching the attempt budget, or a stranger could burn a window with
    /// three malformed frames and no knowledge of anything.
    func testAMalformedPakeMessageCostsNoAttempt() async throws {
        let (listener, endpoint) = try await arm()
        let rejected = expectation(description: "rejected")
        let client = client(endpoint)
        client.onFrame = { frame in
            if case .reject(let reason) = frame {
                XCTAssertEqual(reason, .malformed)
                rejected.fulfill()
            }
        }
        client.start()
        try await Task.sleep(for: .milliseconds(300))
        // 32 bytes, right length, deliberately not a point: little-endian y = 2, for which
        // decompression has no x. Random bytes decode about half the time, which is not a test.
        var notAPoint = Data(repeating: 0, count: 32)
        notAPoint[0] = 2
        client.send(.pake(msg: notAPoint))
        await fulfillment(of: [rejected], timeout: 10)
        XCTAssertEqual(listener.attemptsSpent, 0)
    }

    /// A confirmation before any PAKE has nothing to check itself against. It must drop the
    /// connection rather than spend an attempt — there is no guess in it.
    func testAConfirmationBeforeAPakeIsRefusedWithoutSpendingAnAttempt() async throws {
        let (listener, endpoint) = try await arm()
        let ended = expectation(description: "connection ended")
        let client = client(endpoint)
        client.onEnd = { ended.fulfill() }
        client.start()
        try await Task.sleep(for: .milliseconds(300))
        client.send(.confirm(mac: Data(repeating: 0x00, count: 32)))
        await fulfillment(of: [ended], timeout: 10)
        XCTAssertEqual(listener.attemptsSpent, 0)
    }

    /// `stop()` is the mechanism every one of invariant 2's four routes uses, so it has to do
    /// the whole job: the port stops answering and live connections go away.
    func testStoppingTheListenerClosesThePortAndItsConnections() async throws {
        let (listener, endpoint) = try await arm()
        let live = client(endpoint)
        let ended = expectation(description: "live connection ended")
        live.onEnd = { ended.fulfill() }
        live.start()
        try await Task.sleep(for: .milliseconds(300))

        listener.stop()
        await fulfillment(of: [ended], timeout: 10)

        let afterwards = client(endpoint)
        let refused = expectation(description: "refused")
        afterwards.onFrame = { _ in XCTFail("a stopped listener answered a frame") }
        afterwards.onEnd = { refused.fulfill() }
        afterwards.start()
        try await Task.sleep(for: .milliseconds(300))
        afterwards.send(.pake(msg: Data(repeating: 0x01, count: 32)))
        await fulfillment(of: [refused], timeout: 10)
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: compile failure — `cannot find 'PairingListener' in scope`.

- [ ] **Step 5: Write the listener**

Create `Sources/FleetKit/Pairing/PairingListener.swift`:

```swift
import Foundation
import Network
import Security

/// The Mac's half of a pairing window: a listener that exists only while one is open.
///
/// **Why this is not the fleet listener** (spec §6). A PAKE necessarily runs *before* any
/// shared secret exists, so carrying it on the fleet listener means accepting unauthenticated
/// handshakes there — letting anyone on the LAN consume that listener's pending pool during
/// every window, and turning "a bootstrap connection must never send `hello`" into a check
/// somebody has to write rather than a fact about the socket. Here, application code is not
/// reachable because it is not there: this type imports no store, holds no callback into one,
/// and speaks a vocabulary (`PairingClientFrame`) with no `hello` in it.
///
/// **The channel provides no confidentiality.** Its PSK is in every copy of both binaries.
/// The device key is safe because it is sealed under the SPAKE2-derived key, and would be
/// equally safe in the clear.
///
/// `@unchecked Sendable`, with every mutation confined to `queue` — the same discipline
/// `FleetSocketServer` and `FleetConnector` use, and for the same reason: Network.framework's
/// handlers are typed `@Sendable` but every one of them runs on `queue`, so the state they
/// touch is confined rather than shared. `stop()` asserts
/// `dispatchPrecondition(condition: .onQueue(queue))` as its first line, and every
/// caller-supplied closure is invoked on `queue` under the same assertion. `start()` cannot
/// use that assertion — it is a plain `nonisolated async` method, and Swift's concurrency
/// runtime does not preserve a caller's queue across one — so it forces its whole body onto
/// `queue` with a single `queue.async`, exactly as `FleetSocketServer.start` does. See that
/// method's doc comment for why the more obvious fixes do not work.
public final class PairingListener: @unchecked Sendable {
    /// Three guesses against 55 bits, per Mac, per window (spec §7). The limit is the security
    /// boundary here, not the code's length.
    public static let maxAttempts = 3

    /// This listener's own pending cap, deliberately unrelated to `FleetSocketServer`'s 16.
    /// Every entry here is *unauthenticated* — the bootstrap PSK proves nothing about who is
    /// on the other end — where the fleet listener's pending entries have all completed a
    /// handshake with a paired key. Different populations, different bound; a window expects
    /// one phone, and four is generous for retries.
    public static let maxPending = 4

    /// How long a peer may hold a bootstrap connection without completing an exchange.
    /// Settable so a test need not wait the production value. Independent of
    /// `FleetSocketServer.authDeadline` (invariant 4) and longer, because a human is typing
    /// twelve characters inside this one.
    public var authDeadline: TimeInterval = 30

    /// Fired once, on `queue`, the moment a sealed key has been handed over. The consumer's
    /// job is to close the window; this type does not close itself, because "the window is
    /// open" is `FleetService`'s fact, not this listener's.
    public var onPaired: (() -> Void)?
    /// Fired once, on `queue`, when the third attempt is spent. The window is burned and the
    /// user must re-arm.
    public var onAttemptsExhausted: (() -> Void)?

    /// Read by tests and by nothing in production. Confined to `queue` like everything else.
    public private(set) var attemptsSpent = 0

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    /// One SPAKE2 session per connection, and never reused: the C context is single-use, so a
    /// retry is a new connection with a new session. Held only to keep the transcript
    /// reachable; `PairingSecrets` is what the exchange actually consults.
    private var sessions: [UUID: SPAKE2Session] = [:]
    private var secrets: [UUID: PairingSecrets] = [:]

    private var code: PairingCode?
    private var key: FleetDeviceKey?
    private var macName = ""

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    /// Binds an OS-assigned port and advertises it on `PairingChannel.bonjourType`.
    ///
    /// No `releaseListenerOnQueue` dance, unlike `FleetSocketServer.start`: that exists
    /// because key rotation rebinds the fleet listener on the *same* port on every arm, expiry
    /// and revocation. This listener always takes a fresh port and is never rebound, so there
    /// is no cancellation in flight for a bind to race.
    @discardableResult
    public func start(
        code: PairingCode, key: FleetDeviceKey, macName: String,
        serviceName: String, port: NWEndpoint.Port?
    ) async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                dispatchPrecondition(condition: .onQueue(queue))
                self.code = code
                self.key = key
                self.macName = macName
                self.attemptsSpent = 0
                bind(
                    port: port, serviceName: serviceName, macName: macName,
                    continuation: continuation
                )
            }
        }
    }

    private func bind(
        port: NWEndpoint.Port?, serviceName: String, macName: String,
        continuation: CheckedContinuation<NWEndpoint.Port, Error>
    ) {
        let parameters = FleetSocket.webSocketParameters(FleetTLS.pairingListenerParameters())
        let listener: NWListener
        do {
            listener = try port.map { try NWListener(using: parameters, on: $0) }
                ?? NWListener(using: parameters)
        } catch {
            continuation.resume(throwing: error)
            return
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        self.listener = listener
        // The advertisement's lifetime IS the window's lifetime — this service exists only
        // while the listener does, which is why a phone that finds nothing can say "that Mac
        // isn't pairable right now" rather than guessing. The TXT record carries the Mac's
        // display name so a phone that finds two can tell them apart; it is unauthenticated
        // text from the network, for display only, until the seal delivers the real name.
        listener.service = NWListener.Service(
            name: serviceName, type: PairingChannel.bonjourType,
            txtRecord: NWTXTRecord([PairingChannel.txtNameKey: macName])
        )

        // Same single-resume hazard, and same fix, as `FleetSocketServer.bind`: the state
        // handler fires repeatedly and the continuation must be resumed exactly once or the
        // program traps. `nonisolated(unsafe)` because both this flag and the work item are
        // touched only from handlers Network.framework delivers serially on `queue`.
        nonisolated(unsafe) var resumed = false
        nonisolated(unsafe) let timeout = DispatchWorkItem { [weak listener] in
            guard !resumed else { return }
            resumed = true
            listener?.cancel()
            continuation.resume(throwing: FleetSocketError.didNotBind)
        }
        listener.stateUpdateHandler = { state in
            guard !resumed else { return }
            switch state {
            case .ready:
                // `.any` (0) is the placeholder `listener.port` reports in the moment before
                // the OS assigns a real ephemeral port; resuming there hands back a port
                // nothing can connect to.
                guard let port = listener.port, port != .any else { return }
                resumed = true
                timeout.cancel()
                continuation.resume(returning: port)
            case .failed(let error):
                resumed = true
                timeout.cancel()
                continuation.resume(throwing: error)
            case .cancelled:
                resumed = true
                timeout.cancel()
                continuation.resume(throwing: FleetSocketError.didNotBind)
            default:
                break
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    /// Tears the window down. Called by every route that closes one — success, expiry, cancel,
    /// app termination (invariant 2) — so it must leave nothing behind that could answer.
    ///
    /// `cancel()`, never `forceCancel()`: `NWConnection.cancel` completes queued sends before
    /// disconnecting, and the success path calls `onPaired` immediately after queueing the
    /// sealed frame. A forced cancel would truncate the one frame the whole exchange exists to
    /// deliver.
    public func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        sessions.removeAll()
        secrets.removeAll()
        code = nil
        key = nil
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard connections.count < Self.maxPending else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: queue)

        // A peer that completes the bootstrap handshake and then says nothing holds a slot in
        // a pool of four. Its own deadline, not the fleet listener's (invariant 4).
        queue.asyncAfter(deadline: .now() + authDeadline) { [weak self] in
            self?.drop(id)
        }

        FleetSocket.receive(PairingClientFrame.self, from: connection) { [weak self] frame in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.handle(frame, id: id, connection: connection)
        } onEnd: { [weak self] _ in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.drop(id)
        }
    }

    private func handle(_ frame: PairingClientFrame, id: UUID, connection: NWConnection) {
        guard let code, let key, connections[id] != nil else { return drop(id) }
        guard attemptsSpent < Self.maxAttempts else {
            // Answered rather than silently dropped so a phone can say "ask your Mac for a new
            // code" instead of "the network went away". The window is already burned; there is
            // nothing left to protect by staying quiet.
            FleetSocket.send(PairingServerFrame.reject(.attemptsExhausted), over: connection)
            return drop(id)
        }

        switch frame {
        case .pake(let peerMessage):
            // One PAKE per connection. `SPAKE2Session` is single-use in the C library and
            // would throw, but dropping here says why.
            guard sessions[id] == nil else { return drop(id) }
            let session = SPAKE2Session(
                role: .responder,
                myName: PairingChannel.responderName, theirName: PairingChannel.initiatorName
            )
            do {
                // Generate before processing: the C context requires that order, and
                // `transcript` needs both halves before it will answer.
                let mine = try session.message(for: code)
                let material = try session.keyMaterial(from: peerMessage)
                sessions[id] = session
                // `session.transcript`, never assembled here. It is initiator-first on both
                // sides; the same `myMsg + theirMsg` line written on both ends yields opposite
                // orders, mismatched keys, and a Mac that reports "wrong code" for a correctly
                // typed one while spending an attempt saying so.
                secrets[id] = PairingSecrets(
                    keyMaterial: material, transcript: try session.transcript
                )
                FleetSocket.send(PairingServerFrame.pake(msg: mine), over: connection)
            } catch {
                // Not a guess — a frame that is not a curve point at all — so no attempt is
                // spent. The pending cap and the deadline are what bound this, not the budget.
                FleetSocket.send(PairingServerFrame.reject(.malformed), over: connection)
                drop(id)
            }

        case .confirm(let claimed):
            guard let derived = secrets[id] else {
                // A confirmation with no exchange behind it contains no guess to charge for.
                return drop(id)
            }
            guard PairingSecrets.matches(claimed, derived.initiatorConfirmation) else {
                attemptsSpent += 1
                let exhausted = attemptsSpent >= Self.maxAttempts
                FleetSocket.send(
                    PairingServerFrame.reject(exhausted ? .attemptsExhausted : .badCode),
                    over: connection
                )
                drop(id)
                if exhausted { onAttemptsExhausted?() }
                return
            }
            do {
                // `seal` takes the key and reads the slot out of it, never a slot passed
                // alongside — see its own doc comment for why that is the shape.
                let box = try derived.seal(key, macName: macName)
                FleetSocket.send(
                    PairingServerFrame.sealed(mac: derived.responderConfirmation, box: box),
                    over: connection
                )
            } catch {
                FleetSocket.send(PairingServerFrame.reject(.malformed), over: connection)
                drop(id)
                return
            }
            // The consumer closes the window from here. The sealed frame is already queued and
            // `stop()`'s graceful `cancel()` will flush it — see `stop()`'s doc comment.
            onPaired?()
        }
    }

    private func drop(_ id: UUID) {
        dispatchPrecondition(condition: .onQueue(queue))
        connections.removeValue(forKey: id)?.cancel()
        sessions.removeValue(forKey: id)
        secrets.removeValue(forKey: id)
    }
}
```

- [ ] **Step 6: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1224** tests, 0 failures (1218 + 6).

- [ ] **Step 7: Prove the invariant-4 tests can fail**

Both halves, one at a time.

*Pending cap.* In `PairingListener.accept`, change the guard to `guard connections.count < 64 else`. Run:

`./scripts/test-unit.sh 2>&1 | grep -B2 -A4 testFillingThePairingListenersPendingPoolLeaves`

Expected: still passes — a larger cap does not starve the *fleet* listener, and this test is about isolation, not the number. So also delete the guard entirely and confirm the same. **This is the point:** the test proves isolation, and the number itself is pinned by `testASilentPairingConnectionIsDroppedOnItsOwnDeadline` plus the constant. Record that reading in the commit message rather than pretending the cap test is something it is not. Revert.

*Deadline.* Change `queue.asyncAfter(deadline: .now() + authDeadline)` to `.now() + 3600`. Run:

`./scripts/test-unit.sh 2>&1 | grep -A4 testASilentPairingConnectionIsDroppedOnItsOwnDeadline`

Expected: **FAIL** — the expectation times out after 10s. Revert and re-run to green.

- [ ] **Step 8: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

- [ ] **Step 9: Commit**

```bash
git add Sources/FleetKit/Pairing/PairingListener.swift Sources/FleetKit/FleetSocket.swift Sources/FleetKit/FleetClient.swift Tests/FlightDeckTests/PairingTestClient.swift Tests/FlightDeckTests/PairingListenerTests.swift
git commit -m "feat: a listener that lives only as long as the window"
```

---

### Task 4: The phone's side of one exchange

**Files:**
- Create: `Sources/FleetKit/Pairing/PairingInitiator.swift`
- Test: `Tests/FlightDeckTests/PairingInitiatorTests.swift`

**Interfaces:**
- Consumes: `PairingListener` (Task 3), `PairingChannel.*`, `PairingClientFrame`/`PairingServerFrame`, `FleetTLS.pairingClientParameters()`, `FleetSocket.webSocketEndpoint(for:)`, `PairingSecrets.matches(_:_:)`, `SPAKE2Session`, `PairingSecrets.open(_:)`.
- Produces: `PairingInitiator` — `init(queue: DispatchQueue = .main)`; `enum Failure: Error, Equatable { case wrongCode, attemptsExhausted, connectionFailed, malformedResponse }`; `var onPaired: ((_ key: FleetDeviceKey, _ macName: String) -> Void)?`; `var onFailure: ((Failure) -> Void)?`; `func start(code: PairingCode, endpoint: NWEndpoint)`; `func cancel()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/PairingInitiatorTests.swift`:

```swift
import Foundation
import Network
import XCTest
@testable import FleetKit

@MainActor
final class PairingInitiatorTests: XCTestCase {
    private var listener: PairingListener?
    private var initiator: PairingInitiator?

    override func tearDown() async throws {
        initiator?.cancel()
        initiator = nil
        listener?.stop()
        listener = nil
    }

    private func arm(
        code: PairingCode, key: FleetDeviceKey = .mint(), macName: String = "Nate's MacBook"
    ) async throws -> NWEndpoint {
        let listener = PairingListener()
        self.listener = listener
        let port = try await listener.start(
            code: code, key: key, macName: macName,
            serviceName: "flightdeck-test-\(UUID().uuidString.prefix(8))", port: nil
        )
        return .hostPort(host: "127.0.0.1", port: port)
    }

    private func run(
        code: PairingCode, endpoint: NWEndpoint
    ) async -> Result<(key: FleetDeviceKey, macName: String), PairingInitiator.Failure> {
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var outcome:
            Result<(key: FleetDeviceKey, macName: String), PairingInitiator.Failure>?
        let initiator = PairingInitiator()
        self.initiator = initiator
        initiator.onPaired = { key, macName in
            MainActor.assumeIsolated {
                outcome = .success((key, macName))
                settled.fulfill()
            }
        }
        initiator.onFailure = { failure in
            MainActor.assumeIsolated {
                outcome = .failure(failure)
                settled.fulfill()
            }
        }
        initiator.start(code: code, endpoint: endpoint)
        await fulfillment(of: [settled], timeout: 15)
        return outcome ?? .failure(.connectionFailed)
    }

    /// The whole phone side against the whole Mac side, over a real socket. Both halves come
    /// out of `FleetKit`, so this cannot catch a *consistent* role or name swap inside
    /// `SPAKE2Session` — that is pinned in process by
    /// `testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder`, and no wire test of any kind
    /// can reach it (spec §5's amendment). What it does catch is the two callers disagreeing:
    /// both claiming `.initiator`, passing the names in opposite orders, or assembling the
    /// transcript differently.
    func testTheCorrectCodeDeliversTheKeyAndTheMacsName() async throws {
        let code = PairingCode.mint()
        let key = FleetDeviceKey.mint()
        let endpoint = try await arm(code: code, key: key, macName: "Nate's MacBook")

        guard case .success(let paired) = await run(code: code, endpoint: endpoint) else {
            return XCTFail("the correct code did not pair")
        }
        XCTAssertEqual(paired.key.slot, key.slot)
        XCTAssertEqual(paired.key.secret, key.secret)
        XCTAssertEqual(paired.macName, "Nate's MacBook")
    }

    /// A code the Mac never minted must come back as `wrongCode` and not as a connection
    /// problem — those two send the user to different places, which is the whole reason the
    /// checksum exists on the phone as well.
    func testAWrongCodeFailsAsAWrongCodeRatherThanAsANetworkError() async throws {
        let endpoint = try await arm(code: .mint())
        guard case .failure(let failure) = await run(code: .mint(), endpoint: endpoint) else {
            return XCTFail("a wrong code paired")
        }
        XCTAssertEqual(failure, .wrongCode)
    }

    /// Mutual, not one-way. Without checking the Mac's own confirmation, anything that could
    /// speak the frames could walk a phone all the way to a sealed blob it would then try to
    /// open — and the phone would report "damaged" for what is really "that was not your Mac".
    /// Driven by a fake responder that never knew the code.
    func testAMacThatCannotProveItKnewTheCodeIsRefused() async throws {
        let impostor = try ImpostorMac()
        defer { impostor.stop() }
        guard case .failure(let failure) = await run(
            code: .mint(), endpoint: await impostor.endpoint()
        ) else {
            return XCTFail("an impostor Mac paired")
        }
        XCTAssertEqual(failure, .wrongCode)
    }

    /// A dead address must not hang the pairing screen forever with no verdict.
    func testAnUnreachableEndpointFailsRatherThanHanging() async throws {
        // Bound and immediately released, so nothing is listening on it.
        let dead = PairingListener()
        let port = try await dead.start(
            code: .mint(), key: .mint(), macName: "Gone",
            serviceName: "flightdeck-test-gone", port: nil
        )
        dead.stop()

        let initiator = PairingInitiator()
        self.initiator = initiator
        initiator.connectTimeout = 1
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var failure: PairingInitiator.Failure?
        initiator.onPaired = { _, _ in XCTFail("paired with nothing") }
        initiator.onFailure = { value in
            MainActor.assumeIsolated {
                failure = value
                settled.fulfill()
            }
        }
        initiator.start(code: .mint(), endpoint: .hostPort(host: "127.0.0.1", port: port))
        await fulfillment(of: [settled], timeout: 15)
        XCTAssertEqual(failure, .connectionFailed)
    }

    /// A responder that answers the frames but never knew the code. Its SPAKE2 half is real —
    /// it just runs on a different password, which is exactly the position an attacker who
    /// spoofed the Bonjour advertisement would be in.
    @MainActor
    private final class ImpostorMac {
        private let listener: NWListener
        private var connection: NWConnection?

        init() throws {
            listener = try NWListener(
                using: FleetSocket.webSocketParameters(FleetTLS.pairingListenerParameters())
            )
        }

        func endpoint() async -> NWEndpoint {
            let ready = expectation()
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = self.listener.port, port != .any {
                    ready.resume(port)
                }
            }
            listener.start(queue: .main)
            return .hostPort(host: "127.0.0.1", port: await ready.value)
        }

        private func serve(_ connection: NWConnection) {
            self.connection = connection
            connection.start(queue: .main)
            let session = SPAKE2Session(
                role: .responder,
                myName: PairingChannel.responderName, theirName: PairingChannel.initiatorName
            )
            FleetSocket.receive(PairingClientFrame.self, from: connection) { frame in
                MainActor.assumeIsolated {
                    guard case .pake(let peer) = frame else { return }
                    // A different code: everything is well-formed, nothing verifies.
                    guard let mine = try? session.message(for: .mint()),
                          let material = try? session.keyMaterial(from: peer),
                          let transcript = try? session.transcript
                    else { return }
                    let secrets = PairingSecrets(
                        keyMaterial: material, transcript: transcript
                    )
                    FleetSocket.send(PairingServerFrame.pake(msg: mine), over: connection)
                    // Answer the confirmation it cannot verify with a seal it cannot open.
                    let key = FleetDeviceKey.mint()
                    if let box = try? secrets.seal(key, macName: "Not Your Mac") {
                        FleetSocket.send(
                            PairingServerFrame.sealed(
                                mac: secrets.responderConfirmation, box: box
                            ),
                            over: connection
                        )
                    }
                }
            } onEnd: { _ in }
        }

        func stop() {
            connection?.cancel()
            listener.cancel()
        }

        /// A one-shot continuation, because `XCTestExpectation` cannot carry a value out.
        private final class Expectation: @unchecked Sendable {
            private var continuation: CheckedContinuation<NWEndpoint.Port, Never>?
            private var pending: NWEndpoint.Port?
            var value: NWEndpoint.Port {
                get async {
                    await withCheckedContinuation { continuation in
                        if let pending {
                            continuation.resume(returning: pending)
                        } else {
                            self.continuation = continuation
                        }
                    }
                }
            }
            func resume(_ port: NWEndpoint.Port) {
                guard pending == nil else { return }
                pending = port
                continuation?.resume(returning: port)
                continuation = nil
            }
        }

        private func expectation() -> Expectation { Expectation() }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: compile failure — `cannot find 'PairingInitiator' in scope`.

- [ ] **Step 3: Write the initiator**

Create `Sources/FleetKit/Pairing/PairingInitiator.swift`:

```swift
import Foundation
import Network

/// One pairing attempt against one endpoint: the phone's half of the exchange.
///
/// Callback-shaped rather than `async`, matching `FleetClient`, because the caller is a
/// `PairingRunner` walking a list of Macs and a SwiftUI screen showing progress — both want to
/// be told, not to await.
///
/// **This ships in FleetKit rather than in the phone app**, for the reason `FleetClient`'s own
/// doc gives: the loopback tests drive the real thing, and a second, test-only initiator would
/// prove nothing about the one that ships.
///
/// `@unchecked Sendable` with every mutation confined to `queue` — the same discipline as
/// `FleetClient`. `start()` and `cancel()` assert `dispatchPrecondition(condition:
/// .onQueue(queue))` as their first line.
public final class PairingInitiator: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// The Mac rejected our confirmation, or its own did not verify, or the sealed blob
        /// did not open. All three mean the same thing to the user — the code did not match
        /// this Mac — and only one of them costs an attempt on the Mac's counter.
        case wrongCode
        /// This Mac's window is burned. The user must arm again, not retype.
        case attemptsExhausted
        /// Never reached the Mac at all. Distinct from `wrongCode` because it sends the user
        /// to the network, not to the keyboard.
        case connectionFailed
        /// The Mac spoke, and what it said was not this protocol.
        case malformedResponse
    }

    public var onPaired: ((_ key: FleetDeviceKey, _ macName: String) -> Void)?
    public var onFailure: ((Failure) -> Void)?

    /// How long to wait for a socket that never becomes usable. `NWConnection` will retry a
    /// dead address well past any patience a pairing screen has, and a runner walking three
    /// discovered Macs cannot spend a TCP timeout on each.
    public var connectTimeout: TimeInterval = 8

    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var session: SPAKE2Session?
    private var secrets: PairingSecrets?
    /// Guards `onPaired`/`onFailure` so exactly one fires, once. Three paths reach a verdict —
    /// a frame, a state change, the timeout — and one dropped socket trips at least two of
    /// them, because `receiveMessage` errors at the same moment the state goes `.failed`.
    private var settled = false
    /// Invalidates a timeout that outlived its attempt: `asyncAfter` cannot be cancelled, so
    /// the block recognises staleness instead. A runner starts several attempts in a row on
    /// one initiator's lifetime, and an earlier timeout firing into a later attempt would
    /// abandon a live exchange.
    private var generation = 0

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func start(code: PairingCode, endpoint: NWEndpoint) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        settled = false
        generation += 1
        let generation = self.generation

        let session = SPAKE2Session(
            role: .initiator,
            myName: PairingChannel.initiatorName, theirName: PairingChannel.responderName
        )
        self.session = session

        let parameters = FleetSocket.webSocketParameters(FleetTLS.pairingClientParameters())
        let connection = NWConnection(
            to: FleetSocket.webSocketEndpoint(for: endpoint), using: parameters
        )
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                do {
                    // The first frame goes the instant the socket is usable. The bootstrap PSK
                    // has established nothing about who is on the other end — that is what the
                    // next three frames are for.
                    FleetSocket.send(
                        PairingClientFrame.pake(msg: try session.message(for: code)),
                        over: connection
                    )
                } catch {
                    self.fail(.malformedResponse)
                }
            case .failed, .cancelled:
                self.fail(.connectionFailed)
            default:
                break
            }
        }

        FleetSocket.receive(PairingServerFrame.self, from: connection) { [weak self] frame in
            guard let self, !self.settled else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.handle(frame)
        } onEnd: { [weak self] _ in
            self?.fail(.connectionFailed)
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            guard let self, generation == self.generation else { return }
            self.fail(.connectionFailed)
        }
    }

    public func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        settled = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        session = nil
        secrets = nil
    }

    private func handle(_ frame: PairingServerFrame) {
        guard let session, let connection else { return }
        switch frame {
        case .pake(let peerMessage):
            do {
                let material = try session.keyMaterial(from: peerMessage)
                // `session.transcript`, never `mine + peerMessage`. It is initiator-first on
                // both sides precisely so neither caller gets to choose — see that property's
                // doc comment for the failure the choice produces.
                let derived = PairingSecrets(
                    keyMaterial: material, transcript: try session.transcript
                )
                secrets = derived
                FleetSocket.send(
                    PairingClientFrame.confirm(mac: derived.initiatorConfirmation),
                    over: connection
                )
            } catch {
                fail(.malformedResponse)
            }

        case .sealed(let mac, let box):
            guard let secrets else { return fail(.malformedResponse) }
            // Checked BEFORE the box is opened, and that ordering is the point: a peer that
            // cannot prove it knew the code has not earned an attempt at handing this phone a
            // device key. `matches` is constant-time.
            guard PairingSecrets.matches(mac, secrets.responderConfirmation) else {
                return fail(.wrongCode)
            }
            guard let opened = try? secrets.open(box) else { return fail(.wrongCode) }
            finish(key: opened.key, macName: opened.macName)

        case .reject(let reason):
            switch reason {
            case .badCode, .malformed: fail(.wrongCode)
            case .attemptsExhausted: fail(.attemptsExhausted)
            }
        }
    }

    private func finish(key: FleetDeviceKey, macName: String) {
        guard !settled else { return }
        settled = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onPaired?(key, macName)
    }

    private func fail(_ failure: Failure) {
        guard !settled else { return }
        settled = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onFailure?(failure)
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1228** tests, 0 failures (1224 + 4).

- [ ] **Step 5: Prove the mutual-authentication test can fail**

In `PairingInitiator.handle`, delete the `PairingSecrets.matches(mac, secrets.responderConfirmation)` guard (keep the `open` below it). Run:

`./scripts/test-unit.sh 2>&1 | grep -A4 testAMacThatCannotProveItKnewTheCodeIsRefused`

Expected: still **FAIL**, because `open` also fails on an impostor's box — but the *reported* failure is now reached through the wrong path. To see the guard itself matter, additionally change the impostor to seal under the initiator's own derived key… which it cannot, since it does not have one. Record the honest reading: the confirmation check and the AEAD both refuse an impostor, the check refuses it *first and without touching the box*, and that ordering is what the guard buys. Revert both edits.

- [ ] **Step 6: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/Pairing/PairingInitiator.swift Tests/FlightDeckTests/PairingInitiatorTests.swift
git commit -m "feat: the phone's half of a pairing exchange"
```

---

### Task 5: Three attempts, per Mac, per window

**Files:**
- Test: `Tests/FlightDeckTests/PairingRateLimitTests.swift`
- (No source change is expected. The behaviour was built in Task 3; this task is where it is proved, and where any gap it exposes is fixed.)

**Interfaces:**
- Consumes: `PairingListener` (`maxAttempts`, `attemptsSpent`, `start`, `stop`, `onAttemptsExhausted`), `PairingInitiator` (`start`, `onPaired`, `onFailure`, `Failure`), `PairingCode`.
- Produces: nothing new.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/PairingRateLimitTests.swift`:

```swift
import Foundation
import Network
import XCTest
@testable import FleetKit

/// Spec §7: "Rate limiting is per-Mac, per-window. … It is explicitly *not* a global counter:
/// a phone legitimately trying three discovered Macs must not exhaust the budget on the right
/// one. A failed *checksum* is not an attempt — it never reaches the Mac."
@MainActor
final class PairingRateLimitTests: XCTestCase {
    private var listeners: [PairingListener] = []
    private var initiators: [PairingInitiator] = []

    override func tearDown() async throws {
        for initiator in initiators { initiator.cancel() }
        for listener in listeners { listener.stop() }
        initiators.removeAll()
        listeners.removeAll()
    }

    private func arm(code: PairingCode) async throws -> (PairingListener, NWEndpoint) {
        let listener = PairingListener()
        listeners.append(listener)
        let port = try await listener.start(
            code: code, key: .mint(), macName: "Mac \(listeners.count)",
            serviceName: "flightdeck-test-\(UUID().uuidString.prefix(8))", port: nil
        )
        return (listener, .hostPort(host: "127.0.0.1", port: port))
    }

    @discardableResult
    private func attempt(
        code: PairingCode, endpoint: NWEndpoint
    ) async -> Result<FleetDeviceKey, PairingInitiator.Failure> {
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var outcome: Result<FleetDeviceKey, PairingInitiator.Failure>?
        let initiator = PairingInitiator()
        initiators.append(initiator)
        initiator.onPaired = { key, _ in
            MainActor.assumeIsolated { outcome = .success(key); settled.fulfill() }
        }
        initiator.onFailure = { failure in
            MainActor.assumeIsolated { outcome = .failure(failure); settled.fulfill() }
        }
        initiator.start(code: code, endpoint: endpoint)
        await fulfillment(of: [settled], timeout: 15)
        return outcome ?? .failure(.connectionFailed)
    }

    func testThreeWrongCodesBurnTheWindowAndTheFourthIsRefusedEvenWhenCorrect() async throws {
        let code = PairingCode.mint()
        let (listener, endpoint) = try await arm(code: code)
        let exhausted = expectation(description: "exhausted")
        listener.onAttemptsExhausted = { exhausted.fulfill() }

        for index in 1...PairingListener.maxAttempts {
            let outcome = await attempt(code: .mint(), endpoint: endpoint)
            guard case .failure(let failure) = outcome else {
                return XCTFail("a wrong code paired on attempt \(index)")
            }
            XCTAssertEqual(
                failure,
                index < PairingListener.maxAttempts ? .wrongCode : .attemptsExhausted,
                "attempt \(index) reported the wrong verdict"
            )
        }
        await fulfillment(of: [exhausted], timeout: 5)
        XCTAssertEqual(listener.attemptsSpent, PairingListener.maxAttempts)

        // The correct code, after the budget is gone. The listener is still up — closing it is
        // `FleetService`'s job, proved in Task 8 — so this is the listener refusing on its own
        // terms rather than the port simply being closed.
        guard case .failure(let afterwards) = await attempt(code: code, endpoint: endpoint) else {
            return XCTFail("the correct code paired after the window was burned")
        }
        XCTAssertEqual(afterwards, .attemptsExhausted)
        XCTAssertEqual(
            listener.attemptsSpent, PairingListener.maxAttempts,
            "a refusal after exhaustion must not increment the counter further"
        )
    }

    /// The isolation the spec calls out by name. A phone that types the right code but reaches
    /// the wrong Mac first must not arrive at the right one with a spent budget.
    func testAWrongMacSpendsAnAttemptOnlyOnItself() async throws {
        let wrongCode = PairingCode.mint()
        let rightCode = PairingCode.mint()
        let (wrongMac, wrongEndpoint) = try await arm(code: wrongCode)
        let (rightMac, rightEndpoint) = try await arm(code: rightCode)

        guard case .failure = await attempt(code: rightCode, endpoint: wrongEndpoint) else {
            return XCTFail("the wrong Mac accepted a code it never minted")
        }
        XCTAssertEqual(wrongMac.attemptsSpent, 1)
        XCTAssertEqual(rightMac.attemptsSpent, 0, "an attempt landed on the wrong Mac's budget")

        guard case .success = await attempt(code: rightCode, endpoint: rightEndpoint) else {
            return XCTFail("the right Mac refused the right code")
        }
        XCTAssertEqual(rightMac.attemptsSpent, 0)
    }

    /// A mistyped code is rejected on the phone and never reaches the Mac (spec §4, §7).
    ///
    /// Two things carry this, and only one of them is a runtime check. `PairingInitiator.start`
    /// takes a `PairingCode`, not a `String`, so a code that failed its checksum cannot be
    /// handed to it at all — the type is the enforcement. This exercises the other half: that
    /// a single-character typo really does fail `PairingCode(normalizing:)`, across the whole
    /// alphabet and every position, so the type-level guarantee is reachable in practice. The
    /// Mac's counter never moves.
    func testASingleCharacterTypoNeverReachesTheMac() async throws {
        let code = PairingCode.mint()
        let (listener, _) = try await arm(code: code)
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var symbols = Array(code.formatted.filter { $0 != "-" })

        for position in symbols.indices {
            let original = symbols[position]
            for replacement in alphabet where replacement != original {
                symbols[position] = replacement
                let typo = String(symbols)
                if PairingCode(normalizing: typo) != nil {
                    // 5 bits of checksum: roughly one typo in 32 collides, by construction.
                    // Those are the ones that DO reach the Mac and spend an attempt, which is
                    // the tradeoff the spec accepts. Not a failure — just not a local catch.
                    continue
                }
            }
            symbols[position] = original
        }
        XCTAssertEqual(
            listener.attemptsSpent, 0,
            "validating typos locally must not touch the network at all"
        )
    }

    /// The checksum catches the overwhelming majority of single-character typos, which is what
    /// makes "that code doesn't look right" a useful thing for the phone to say. Pinned as a
    /// rate rather than as "every typo", because 5 bits cannot catch every one.
    func testTheChecksumCatchesNearlyEverySingleCharacterTypo() {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var caught = 0
        var total = 0
        for _ in 0..<20 {
            let code = PairingCode.mint()
            var symbols = Array(code.formatted.filter { $0 != "-" })
            for position in symbols.indices {
                let original = symbols[position]
                for replacement in alphabet where replacement != original {
                    symbols[position] = replacement
                    total += 1
                    if PairingCode(normalizing: String(symbols)) == nil { caught += 1 }
                }
                symbols[position] = original
            }
        }
        // 5 bits of checksum ⇒ ~1/32 collide ⇒ ~96.9% caught. The floor is loose enough not to
        // flake and tight enough that a checksum that stopped working would fail it.
        XCTAssertGreaterThan(Double(caught) / Double(total), 0.9)
    }
}
```

- [ ] **Step 2: Run the tests and see where they stand**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: **1232** tests, 0 failures (1228 + 4), all four new tests passing on Task 3's implementation. If any fails, that is a real gap in `PairingListener` — fix `PairingListener`, not the test.

- [ ] **Step 3: Prove the per-Mac isolation test can fail**

In `PairingListener`, change `public private(set) var attemptsSpent = 0` to a process-wide counter, which is the "obvious" implementation the spec explicitly rules out:

```swift
    private static var globalAttempts = 0
    public private(set) var attemptsSpent: Int {
        get { Self.globalAttempts }
        set { Self.globalAttempts = newValue }
    }
```

Run: `./scripts/test-unit.sh 2>&1 | grep -A4 testAWrongMacSpendsAnAttemptOnlyOnItself`

Expected: **FAIL** — `rightMac.attemptsSpent` is 1, "an attempt landed on the wrong Mac's budget". Revert and re-run to green.

- [ ] **Step 4: Prove the exhaustion test can fail**

In `PairingListener.handle`, change `guard attemptsSpent < Self.maxAttempts else` to `guard attemptsSpent < 99 else`. Run:

`./scripts/test-unit.sh 2>&1 | grep -A4 testThreeWrongCodesBurnTheWindow`

Expected: **FAIL** — the fourth attempt pairs. Revert and re-run to green.

- [ ] **Step 5: Commit**

```bash
git add Tests/FlightDeckTests/PairingRateLimitTests.swift
git commit -m "test: three guesses, and only against the Mac that was guessed at"
```

---

### Task 6: Finding an armed Mac

**Files:**
- Create: `Sources/FleetKit/Pairing/PairingBrowser.swift`
- Modify: `project.yml` (`FlightDeckMobile` → `info.properties.NSBonjourServices`)
- Test: `Tests/FlightDeckTests/PairingDiscoveryTests.swift`

**Interfaces:**
- Consumes: `PairingChannel.bonjourType`, `PairingChannel.txtNameKey`, `PairingListener.start(...)`'s advertisement.
- Produces: `PairingBrowser` — `struct DiscoveredMac: Equatable, Sendable { let serviceName: String; let displayName: String; let endpoint: NWEndpoint; init(serviceName:displayName:endpoint:) }`; `var onResults: (([DiscoveredMac]) -> Void)?`; `init(queue: DispatchQueue = .main)`; `func start()`; `func stop()`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/PairingDiscoveryTests.swift`:

```swift
import Foundation
import Network
import XCTest
@testable import FleetKit

@MainActor
final class PairingDiscoveryTests: XCTestCase {
    private var listener: PairingListener?
    private var browser: PairingBrowser?

    override func tearDown() async throws {
        browser?.stop()
        browser = nil
        listener?.stop()
        listener = nil
    }

    func testThePairingServiceTypeIsNotTheFleetsAndIsWhatTheBrowserLooksFor() {
        XCTAssertEqual(PairingChannel.bonjourType, "_flightdeck-pair._tcp")
        XCTAssertNotEqual(PairingChannel.bonjourType, FleetSocketServer.bonjourType)
    }

    /// An armed Mac is findable, and it says who it is. If this hangs on a first run, macOS is
    /// asking for local-network permission — answer it once and re-run.
    ///
    /// Asserts the expected name is *among* the results rather than that it is the only one:
    /// a development machine may have a real Flight Deck armed on the same LAN, and a test
    /// that failed for that reason would be testing the network rather than the code.
    func testAnArmedMacIsDiscoverableWithItsDisplayName() async throws {
        let serviceName = "flightdeck-test-\(UUID().uuidString.prefix(8))"
        let listener = PairingListener()
        self.listener = listener
        _ = try await listener.start(
            code: .mint(), key: .mint(), macName: "Nate's MacBook",
            serviceName: serviceName, port: nil
        )

        let found = expectation(description: "discovered")
        let browser = PairingBrowser()
        self.browser = browser
        browser.onResults = { macs in
            guard let mine = macs.first(where: { $0.serviceName == serviceName }) else { return }
            XCTAssertEqual(mine.displayName, "Nate's MacBook")
            found.fulfill()
        }
        browser.start()
        await fulfillment(of: [found], timeout: 20)
    }

    /// Invariant 2, discovery half: the advertisement's lifetime is the window's lifetime, so
    /// a Mac that is no longer armed is not merely unreachable — it is not offered.
    func testAMacThatStoppedArmingLeavesTheBrowseResults() async throws {
        let serviceName = "flightdeck-test-\(UUID().uuidString.prefix(8))"
        let listener = PairingListener()
        self.listener = listener
        _ = try await listener.start(
            code: .mint(), key: .mint(), macName: "Briefly Armed",
            serviceName: serviceName, port: nil
        )

        let appeared = expectation(description: "appeared")
        let vanished = expectation(description: "vanished")
        nonisolated(unsafe) var hasAppeared = false
        let browser = PairingBrowser()
        self.browser = browser
        browser.onResults = { macs in
            let present = macs.contains { $0.serviceName == serviceName }
            if present, !hasAppeared {
                hasAppeared = true
                appeared.fulfill()
            } else if !present, hasAppeared {
                vanished.fulfill()
            }
        }
        browser.start()
        await fulfillment(of: [appeared], timeout: 20)
        listener.stop()
        await fulfillment(of: [vanished], timeout: 20)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: compile failure — `cannot find 'PairingBrowser' in scope`.

- [ ] **Step 3: Write the browser**

Create `Sources/FleetKit/Pairing/PairingBrowser.swift`:

```swift
import Foundation
import Network

/// Finds Macs that are armed for pairing right now.
///
/// Browses `PairingChannel.bonjourType`, not the fleet's `_flightdeck._tcp`, and the
/// difference is the whole design: the pairing service exists only while a window is open, so
/// an empty result set means "no Mac on this network is offering to pair" rather than "no Mac
/// on this network", which are different sentences to put in front of a user.
///
/// `@unchecked Sendable`, state confined to `queue`, entry points asserting it — the same
/// idiom as `FleetConnector`, which browses the fleet's service the same way.
public final class PairingBrowser: @unchecked Sendable {
    public struct DiscoveredMac: Equatable, Sendable {
        /// The Bonjour instance name. This is the identifier that matters: the Mac advertises
        /// the *same* instance name on `_flightdeck._tcp`, so remembering it is what lets a
        /// phone that paired by typing find the same Mac again afterwards.
        public let serviceName: String
        /// From the TXT record, for display only. Unauthenticated text from the network until
        /// the seal delivers the Mac's real name — show it, never decide on it.
        public let displayName: String
        public let endpoint: NWEndpoint

        public init(serviceName: String, displayName: String, endpoint: NWEndpoint) {
            self.serviceName = serviceName
            self.displayName = displayName
            self.endpoint = endpoint
        }
    }

    /// Fired on `queue` with the *full* current set on every change, never a delta. A phone
    /// showing "2 Macs found" needs the set, and patching a local copy per event is how that
    /// count goes stale.
    public var onResults: (([DiscoveredMac]) -> Void)?

    private let queue: DispatchQueue
    private var browser: NWBrowser?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        stop()
        let browser = NWBrowser(
            for: .bonjour(type: PairingChannel.bonjourType, domain: nil), using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            dispatchPrecondition(condition: .onQueue(self.queue))
            self.onResults?(results.compactMap(Self.discovered))
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    public func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        browser?.cancel()
        browser = nil
    }

    private static func discovered(_ result: NWBrowser.Result) -> DiscoveredMac? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        // The TXT record is optional in both directions: a Mac may advertise before the record
        // propagates, and a future Mac may add keys this one does not read. Fall back to the
        // instance name rather than dropping a Mac the user can see is armed.
        var displayName = name
        if case .bonjour(let txt) = result.metadata,
           let value = txt[PairingChannel.txtNameKey], !value.isEmpty {
            displayName = value
        }
        return DiscoveredMac(
            serviceName: name, displayName: displayName, endpoint: result.endpoint
        )
    }
}
```

- [ ] **Step 4: Declare the service on iOS**

iOS 14+ refuses to browse a service type an app has not declared, and it does so **silently** — the browser simply never returns a result, which reads as "my Mac isn't on the network". In `project.yml`, under `targets.FlightDeckMobile.info.properties.NSBonjourServices`, add the second entry:

```yaml
        NSBonjourServices:
          - _flightdeck._tcp
          - _flightdeck-pair._tcp
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1235** tests, 0 failures (1232 + 3).

If `testAnArmedMacIsDiscoverableWithItsDisplayName` times out on the first run, macOS is showing the local-network prompt. Answer it and re-run; if it times out twice, that is a real failure.

- [ ] **Step 6: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

`project.yml` changed, so `xcodegen generate` (which both scripts run first) must succeed too — check for no YAML error above the build output.

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/Pairing/PairingBrowser.swift project.yml Tests/FlightDeckTests/PairingDiscoveryTests.swift
git commit -m "feat: an advertisement that exists only while the window does"
```

---

### Task 7: Trying each discovered Mac in turn

**Files:**
- Create: `Sources/FleetKit/Pairing/PairingRunner.swift`
- Test: `Tests/FlightDeckTests/PairingRunnerTests.swift`

**Interfaces:**
- Consumes: `PairingBrowser` (Task 6), `PairingInitiator` (Task 4), `PairingCode`, `FleetDeviceKey`.
- Produces: `PairingRunner` — `init(queue: DispatchQueue = .main)`; `enum Progress: Equatable, Sendable { case searching, trying(displayName: String), noMacsFound, failed(PairingInitiator.Failure), paired }`; `var onProgress: ((Progress) -> Void)?`; `var onPaired: ((_ key: FleetDeviceKey, _ serviceName: String, _ macName: String) -> Void)?`; `var discoveryWindow: TimeInterval`; `func start(code: PairingCode)`; `func start(code: PairingCode, candidates: [PairingBrowser.DiscoveredMac])`; `func cancel()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/PairingRunnerTests.swift`:

```swift
import Foundation
import Network
import XCTest
@testable import FleetKit

/// Spec §7's discovery arm: 0 Macs, 1 Mac, 2+ Macs.
///
/// Every ordering test drives `start(code:candidates:)` with a list built by hand rather than
/// `start(code:)` with a real browse, and that is deliberate rather than a shortcut: a
/// development machine has a real Flight Deck on it, so a browse-driven ordering test would
/// depend on what else is armed on the LAN. Real discovery is proved once, in
/// `PairingDiscoveryTests`, and wired in `testABrowseWithNothingArmedReportsNoMacsFound`.
@MainActor
final class PairingRunnerTests: XCTestCase {
    private var listeners: [PairingListener] = []
    private var runner: PairingRunner?

    override func tearDown() async throws {
        runner?.cancel()
        runner = nil
        for listener in listeners { listener.stop() }
        listeners.removeAll()
    }

    private func arm(
        code: PairingCode, macName: String
    ) async throws -> (PairingListener, PairingBrowser.DiscoveredMac) {
        let listener = PairingListener()
        listeners.append(listener)
        let serviceName = "flightdeck-test-\(UUID().uuidString.prefix(8))"
        let port = try await listener.start(
            code: code, key: .mint(), macName: macName, serviceName: serviceName, port: nil
        )
        return (listener, PairingBrowser.DiscoveredMac(
            serviceName: serviceName, displayName: macName,
            endpoint: .hostPort(host: "127.0.0.1", port: port)
        ))
    }

    private struct Outcome {
        var key: FleetDeviceKey?
        var serviceName: String?
        var macName: String?
        var progress: [PairingRunner.Progress] = []
    }

    private func run(
        code: PairingCode, candidates: [PairingBrowser.DiscoveredMac]
    ) async -> Outcome {
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var outcome = Outcome()
        let runner = PairingRunner()
        self.runner = runner
        runner.onProgress = { progress in
            MainActor.assumeIsolated {
                outcome.progress.append(progress)
                switch progress {
                case .noMacsFound, .failed, .paired: settled.fulfill()
                default: break
                }
            }
        }
        runner.onPaired = { key, serviceName, macName in
            MainActor.assumeIsolated {
                outcome.key = key
                outcome.serviceName = serviceName
                outcome.macName = macName
            }
        }
        runner.start(code: code, candidates: candidates)
        await fulfillment(of: [settled], timeout: 30)
        return outcome
    }

    func testOneArmedMacPairsAndReportsTheNameItWasDiscoveredUnder() async throws {
        let code = PairingCode.mint()
        let (_, mac) = try await arm(code: code, macName: "Nate's MacBook")
        let outcome = await run(code: code, candidates: [mac])

        XCTAssertNotNil(outcome.key)
        // The Bonjour instance name, not the display name: it is what `FleetConnector` matches
        // on to find this Mac again, and a typed pair stores no endpoints at all.
        XCTAssertEqual(outcome.serviceName, mac.serviceName)
        // The display name comes out of the *seal*, not out of the TXT record — the TXT
        // record is unauthenticated until this point.
        XCTAssertEqual(outcome.macName, "Nate's MacBook")
        XCTAssertEqual(outcome.progress.last, .paired)
    }

    /// Two Macs armed, the code belonging to the second. The first is tried, refuses, and the
    /// runner moves on — spending exactly one attempt on the wrong Mac and none on the right
    /// one. That last clause is the spec's per-Mac rule seen from the phone's side.
    func testTheRunnerWalksPastAWrongMacAndPairsWithTheRightOne() async throws {
        let wrongCode = PairingCode.mint()
        let rightCode = PairingCode.mint()
        let (wrongMac, wrongCandidate) = try await arm(code: wrongCode, macName: "Other Mac")
        let (rightMac, rightCandidate) = try await arm(code: rightCode, macName: "Nate's MacBook")

        let outcome = await run(code: rightCode, candidates: [wrongCandidate, rightCandidate])

        XCTAssertNotNil(outcome.key)
        XCTAssertEqual(outcome.macName, "Nate's MacBook")
        XCTAssertEqual(wrongMac.attemptsSpent, 1)
        XCTAssertEqual(rightMac.attemptsSpent, 0)
        XCTAssertEqual(
            outcome.progress.prefix(3).map(String.init(describing:)),
            [
                PairingRunner.Progress.searching,
                .trying(displayName: "Other Mac"),
                .trying(displayName: "Nate's MacBook")
            ].map(String.init(describing:)),
            "the runner must try candidates in the order it was given them"
        )
    }

    /// Everything refused. The verdict the user sees is the last Mac's, not a generic one —
    /// "no Mac accepted that code" and "that Mac's window is burned" send them to different
    /// places.
    func testWhenEveryMacRefusesTheLastVerdictIsReported() async throws {
        let (_, first) = try await arm(code: .mint(), macName: "One")
        let (_, second) = try await arm(code: .mint(), macName: "Two")
        let outcome = await run(code: .mint(), candidates: [first, second])

        XCTAssertNil(outcome.key)
        XCTAssertEqual(outcome.progress.last, .failed(.wrongCode))
    }

    func testNoCandidatesReportsNoMacsFoundRatherThanAFailure() async throws {
        let outcome = await run(code: .mint(), candidates: [])
        XCTAssertNil(outcome.key)
        XCTAssertEqual(outcome.progress.last, .noMacsFound)
        XCTAssertFalse(
            outcome.progress.contains { if case .failed = $0 { return true } else { return false } },
            "an empty network is not a pairing failure and must not be reported as one"
        )
    }

    /// The browse-driven entry point, exercised once end to end. Nothing is armed by this
    /// test, so the only correct answer after the discovery window is `noMacsFound` — unless a
    /// real Flight Deck on the LAN happens to be armed, in which case this is skipped rather
    /// than failed, because the network is not the thing under test.
    func testABrowseWithNothingArmedReportsNoMacsFound() async throws {
        let settled = expectation(description: "settled")
        nonisolated(unsafe) var last: PairingRunner.Progress?
        let runner = PairingRunner()
        self.runner = runner
        runner.discoveryWindow = 2
        runner.onProgress = { progress in
            MainActor.assumeIsolated {
                last = progress
                switch progress {
                case .noMacsFound, .failed, .paired: settled.fulfill()
                default: break
                }
            }
        }
        runner.start(code: .mint())
        await fulfillment(of: [settled], timeout: 30)
        if case .failed = last {
            throw XCTSkip("another Flight Deck on this LAN is armed for pairing")
        }
        XCTAssertEqual(last, .noMacsFound)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: compile failure — `cannot find 'PairingRunner' in scope`.

- [ ] **Step 3: Write the runner**

Create `Sources/FleetKit/Pairing/PairingRunner.swift`:

```swift
import Foundation
import Network

/// The typed path, from a validated code to a device key: browse, then try each armed Mac in
/// turn until one accepts.
///
/// **Sequential, where `FleetConnector` races in parallel**, and the difference is not a
/// preference. A fleet connection is authenticated by a key, so the first candidate to
/// complete a handshake is by definition the right Mac and racing costs nothing. Here every
/// wrong Mac tried *charges an attempt against that Mac's own three-guess budget* — so a
/// parallel fan-out would burn a guess on every armed Mac on the LAN simultaneously, for a
/// user who typed their code correctly. One at a time, stopping at the first success.
///
/// **It takes a `PairingCode`, never a `String`.** A code that failed its checksum cannot be
/// expressed as one, so there is no path from a typo to the network — which is what makes
/// "a failed checksum is not an attempt" (spec §7) structural rather than a rule someone has
/// to remember.
///
/// `@unchecked Sendable`, state confined to `queue`, entry points asserting it.
public final class PairingRunner: @unchecked Sendable {
    public enum Progress: Equatable, Sendable {
        case searching
        /// About to try this Mac. The name is the TXT record's, i.e. unauthenticated — it is
        /// for a progress line, not for a decision.
        case trying(displayName: String)
        /// Nothing on this network is offering to pair. Deliberately not a `failed`: the user
        /// needs "show the code on your Mac / use the QR", not "wrong code".
        case noMacsFound
        /// Every discovered Mac refused, and this is the last one's verdict.
        case failed(PairingInitiator.Failure)
        case paired
    }

    public var onProgress: ((Progress) -> Void)?
    /// `serviceName` is the Bonjour instance name of the Mac that accepted — what a phone
    /// stores so `FleetConnector` can find the same Mac again. `macName` comes out of the
    /// **seal**, so unlike the TXT record it is authenticated by the exchange.
    public var onPaired: ((_ key: FleetDeviceKey, _ serviceName: String, _ macName: String) -> Void)?

    /// How long to collect browse results before trying any of them. A Bonjour browse has no
    /// "that is all of them" signal, so this is the cost of finding the *second* Mac before
    /// spending an attempt on the first — paid once, behind a spinner, on a screen the user
    /// has just finished typing on.
    public var discoveryWindow: TimeInterval = 5

    private let queue: DispatchQueue
    private let browser: PairingBrowser
    private var initiator: PairingInitiator?
    private var code: PairingCode?
    private var remaining: [PairingBrowser.DiscoveredMac] = []
    private var discovered: [PairingBrowser.DiscoveredMac] = []
    private var running = false
    /// Same role as `FleetConnector.generation`: `asyncAfter` cannot be cancelled, so the
    /// discovery-window block recognises that it is stale instead of being stopped.
    private var generation = 0

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
        self.browser = PairingBrowser(queue: queue)
    }

    /// Browse, then try what was found.
    public func start(code: PairingCode) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        running = true
        self.code = code
        generation += 1
        let generation = self.generation
        report(.searching)

        discovered = []
        browser.onResults = { [weak self] macs in
            guard let self, self.running else { return }
            self.discovered = macs
        }
        browser.start()
        queue.asyncAfter(deadline: .now() + discoveryWindow) { [weak self] in
            guard let self, self.running, generation == self.generation else { return }
            self.browser.stop()
            self.remaining = self.discovered
            self.tryNext()
        }
    }

    /// The same walk over a list somebody else assembled. Used by the tests, and available to
    /// a screen that already knows which Macs it found.
    public func start(code: PairingCode, candidates: [PairingBrowser.DiscoveredMac]) {
        dispatchPrecondition(condition: .onQueue(queue))
        cancel()
        running = true
        self.code = code
        generation += 1
        report(.searching)
        remaining = candidates
        tryNext()
    }

    public func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        running = false
        generation += 1
        browser.onResults = nil
        browser.stop()
        initiator?.cancel()
        initiator = nil
        remaining = []
        discovered = []
        code = nil
    }

    private func tryNext() {
        guard running, let code else { return }
        guard !remaining.isEmpty else {
            running = false
            report(.noMacsFound)
            return
        }
        let candidate = remaining.removeFirst()
        report(.trying(displayName: candidate.displayName))

        let initiator = PairingInitiator(queue: queue)
        self.initiator = initiator
        initiator.onPaired = { [weak self] key, macName in
            guard let self, self.running else { return }
            self.running = false
            self.initiator = nil
            self.onPaired?(key, candidate.serviceName, macName)
            self.report(.paired)
        }
        initiator.onFailure = { [weak self] failure in
            guard let self, self.running else { return }
            self.initiator = nil
            guard self.remaining.isEmpty else { return self.tryNext() }
            self.running = false
            // The last Mac's verdict, not a summarised one: "that Mac's window is burned" and
            // "wrong code" send the user to different places.
            self.report(.failed(failure))
        }
        initiator.start(code: code, endpoint: candidate.endpoint)
    }

    private func report(_ progress: Progress) {
        dispatchPrecondition(condition: .onQueue(queue))
        onProgress?(progress)
    }
}
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1240** tests, 0 failures (1235 + 5).

- [ ] **Step 5: Prove the ordering test can fail**

In `PairingRunner.tryNext`, change `remaining.removeFirst()` to `remaining.removeLast()`. Run:

`./scripts/test-unit.sh 2>&1 | grep -A6 testTheRunnerWalksPastAWrongMacAndPairsWithTheRightOne`

Expected: **FAIL** — "the runner must try candidates in the order it was given them", and `wrongMac.attemptsSpent` is 0 while the right Mac paired first. Revert and re-run to green.

- [ ] **Step 6: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/Pairing/PairingRunner.swift Tests/FlightDeckTests/PairingRunnerTests.swift
git commit -m "feat: try each armed Mac in turn, one attempt each"
```

---

### Task 8: Wire the window to the app

**Files:**
- Modify: `Sources/FlightDeck/Fleet/PairingArmer.swift` (mint a code, return `ArmedPairing`)
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (own the pairing listener)
- Modify: `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift` (sheet binds `ArmedPairing`)
- Test: `Tests/FlightDeckTests/PairingWindowTests.swift`
- Modify: `Tests/FlightDeckTests/PairingArmerTests.swift` (follow the return type)
- Modify: `Tests/FlightDeckTests/FleetPairingFlowTests.swift` (follow the return type)

**Interfaces:**
- Consumes: `PairingListener`, `PairingRunner`, `PairingBrowser.DiscoveredMac`, `PairingCode`, `FleetClient`, `FleetSocketServer`, and the shipped `PairingArmer`/`FleetService`/`PreferencesStore` surface.
- Produces: `struct ArmedPairing: Identifiable { let payload: PairingPayload; let code: PairingCode; var id: UUID { payload.key.slot } }`; `PairingArmer.arm(macName:serviceName:endpoints:) -> ArmedPairing`; `FleetService.arm() async throws -> ArmedPairing`; `FleetService.pairingPort: NWEndpoint.Port?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/PairingWindowTests.swift`:

```swift
import Network
import XCTest
import FleetKit
@testable import FlightDeck

/// Invariants 2 and 3 of the spec's §6, plus the acceptance test the whole plan exists for.
@MainActor
final class PairingWindowTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private var service: FleetService?
    private var runner: PairingRunner?
    private var client: FleetClient?
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func tearDown() async throws {
        runner?.cancel()
        client?.disconnect()
        service?.stop()
        runner = nil
        client = nil
        service = nil
    }

    private func standUp() async throws -> (PreferencesStore, FleetService) {
        let preferences = PreferencesStore(persistence: MemoryPersistence())
        let service = FleetService(
            store: SessionStore(provider: nil, persistence: nil),
            preferences: preferences,
            armer: PairingArmer(now: { self.now })
        )
        self.service = service
        _ = try await service.start(port: nil)
        return (preferences, service)
    }

    /// Whether anything is listening on `port` and willing to speak the pairing protocol.
    /// Concluded from a *reply*, never from a connection state: a refused PSK handshake and a
    /// closed port both present as silence, and only an answered frame distinguishes a live
    /// pairing listener from either.
    private func pairingListenerAnswers(on port: NWEndpoint.Port) async -> Bool {
        nonisolated(unsafe) var replied = false
        let probe = PairingProbe(port: port)
        probe.onAnyFrame = { MainActor.assumeIsolated { replied = true } }
        probe.start()
        // Polled rather than awaited on an `XCTestExpectation`: this helper answers a
        // question, and half its call sites expect the answer to be `false`. An expectation
        // that timed out would record a test failure on the way to returning it.
        //
        // A wrong code is enough to draw *an* answer — the responder cannot know a code is
        // wrong until the confirmation, so it replies with its own `pake` regardless. This
        // probe therefore never spends an attempt against the window's three.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if replied { break }
        }
        probe.stop()
        return replied
    }

    private func armedPort(_ service: FleetService) throws -> NWEndpoint.Port {
        try XCTUnwrap(service.pairingPort, "arming did not open a pairing listener")
    }

    /// Invariant 2, the positive half: a window that is open is reachable.
    func testArmingOpensThePairingListener() async throws {
        let (_, service) = try await standUp()
        _ = try await service.arm()
        let port = try armedPort(service)
        let answers = await pairingListenerAnswers(on: port)
        XCTAssertTrue(answers, "an armed Mac did not answer on its pairing port")
    }

    /// Invariant 2, all four closing routes. Each is asserted against the *same* port the
    /// window was opened on, because "the listener is gone" and "the port moved" are different
    /// facts and only the first one is the invariant.
    func testEveryRouteThatClosesTheWindowClosesThePairingListener() async throws {
        // Route 1: explicit cancel.
        let (_, cancelService) = try await standUp()
        _ = try await cancelService.arm()
        let cancelPort = try armedPort(cancelService)
        try await cancelService.cancelArming()
        var answers = await pairingListenerAnswers(on: cancelPort)
        XCTAssertFalse(answers, "cancelling the window left the pairing listener up")
        cancelService.stop()

        // Route 2: expiry.
        let (_, expiryService) = try await standUp()
        _ = try await expiryService.arm()
        let expiryPort = try armedPort(expiryService)
        now += PairingArmer.window + 1
        try await expiryService.expireArming()
        answers = await pairingListenerAnswers(on: expiryPort)
        XCTAssertFalse(answers, "an expired window left the pairing listener up")
        expiryService.stop()

        // Route 3: app termination.
        let (_, stopService) = try await standUp()
        _ = try await stopService.arm()
        let stopPort = try armedPort(stopService)
        stopService.stop()
        answers = await pairingListenerAnswers(on: stopPort)
        XCTAssertFalse(answers, "stopping the service left the pairing listener up")

        // Route 4: success. Covered by the acceptance test below, which asserts the same
        // property after a real pairing rather than re-deriving one here.
    }

    /// Invariant 3. A `hello` is not in the pairing vocabulary, so it cannot be parsed, so the
    /// connection ends — and nothing reaches the session layer. Asserted three ways, because
    /// "no reply" alone would also be true of a listener that quietly ignored it.
    func testAHelloOnThePairingSocketReachesNothing() async throws {
        let (_, service) = try await standUp()
        _ = try await service.arm()
        let port = try armedPort(service)

        let ended = expectation(description: "connection ended")
        let probe = PairingProbe(port: port)
        probe.onAnyFrame = { XCTFail("the pairing listener answered a fleet frame") }
        probe.onEnd = { ended.fulfill() }
        probe.start()
        try await Task.sleep(for: .milliseconds(300))
        probe.sendRawFleetHello()
        await fulfillment(of: [ended], timeout: 10)

        XCTAssertTrue(
            service.attachedSlots.isEmpty,
            "a bootstrap connection was attributed as an attached device"
        )
    }

    /// The acceptance test this plan exists for, and route 4 of invariant 2 in the same run:
    /// a real armed Mac, a real Bonjour-shaped candidate, a real SPAKE2 exchange over a real
    /// socket, a real sealed key — and then that key completing a TLS-PSK handshake against
    /// the fleet listener and receiving a snapshot, which is the moment pairing is actually
    /// finished.
    func testATypedCodePairsAndTheDeliveredKeyReachesTheFleet() async throws {
        let (preferences, service) = try await standUp()
        let armed = try await service.arm()
        let port = try armedPort(service)
        XCTAssertEqual(preferences.pairedDevices.first?.isProvisional, true)

        let paired = expectation(description: "paired")
        nonisolated(unsafe) var delivered: FleetDeviceKey?
        nonisolated(unsafe) var deliveredService: String?
        nonisolated(unsafe) var deliveredName: String?
        let runner = PairingRunner()
        self.runner = runner
        runner.onPaired = { key, serviceName, macName in
            MainActor.assumeIsolated {
                delivered = key
                deliveredService = serviceName
                deliveredName = macName
                paired.fulfill()
            }
        }
        runner.onProgress = { progress in
            if case .failed(let failure) = progress { XCTFail("pairing failed: \(failure)") }
            if case .noMacsFound = progress { XCTFail("the armed Mac was not offered") }
        }
        runner.start(code: armed.code, candidates: [
            PairingBrowser.DiscoveredMac(
                serviceName: service.serviceName, displayName: "Test Mac",
                endpoint: .hostPort(host: "127.0.0.1", port: port)
            )
        ])
        await fulfillment(of: [paired], timeout: 30)

        let key = try XCTUnwrap(delivered)
        XCTAssertEqual(key.slot, armed.payload.key.slot)
        XCTAssertEqual(key.secret, armed.payload.key.secret)
        // What a phone stores: the instance name it found the Mac under, and the Mac's own
        // name out of the seal. No endpoints — typed pairing is LAN-only by design (§11) and
        // `FleetConnector` finds the Mac by browsing for this service name.
        XCTAssertEqual(deliveredService, service.serviceName)
        XCTAssertEqual(deliveredName, Host.current().localizedName ?? "Mac")

        // Invariant 2, route 4: success closed the window's listener.
        let stillAnswering = await pairingListenerAnswers(on: port)
        XCTAssertFalse(stillAnswering, "a completed pairing left the pairing listener up")

        // And the delivered key is a real fleet credential, which is the only proof that
        // matters — the seal round-tripping is not the same claim.
        let snapshot = expectation(description: "snapshot")
        let client = FleetClient(key: key, deviceName: "Test Phone")
        self.client = client
        client.onFrame = { if case .snapshot = $0 { snapshot.fulfill() } }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [snapshot], timeout: 15)

        let device = try XCTUnwrap(preferences.pairedDevices.first)
        XCTAssertEqual(device.slot, armed.payload.key.slot)
        XCTAssertFalse(device.isProvisional, "a device that reached the fleet is still provisional")
        XCTAssertNotNil(device.pairedAt)
    }
}
```

- [ ] **Step 2: Write the probe helper**

`PairingWindowTests` needs to speak raw frames at the pairing port, including one the pairing vocabulary cannot express. Append to `Tests/FlightDeckTests/PairingTestClient.swift`:

```swift
/// A bootstrap connection that can say things the pairing protocol does not contain.
///
/// `PairingTestClient` sends `PairingClientFrame`s, which by construction have no `hello` in
/// them — that is the point of the type. Proving invariant 3 needs the opposite: a peer that
/// puts a *fleet* frame on the pairing socket, which is what a mis-wired client or a hostile
/// one would do. So this encodes `ClientFrame.hello` itself and writes it as a raw WebSocket
/// text message.
final class PairingProbe: @unchecked Sendable {
    /// Fired for any well-formed pairing frame that comes back. The invariant-3 test fails on
    /// this being called at all; the liveness probe succeeds on it.
    var onAnyFrame: (() -> Void)?
    var onEnd: (() -> Void)?

    private let port: NWEndpoint.Port
    private var connection: NWConnection?
    private var ended = false

    init(port: NWEndpoint.Port) {
        self.port = port
    }

    func start() {
        let parameters = FleetSocket.webSocketParameters(FleetTLS.pairingClientParameters())
        let connection = NWConnection(
            to: FleetSocket.webSocketEndpoint(for: .hostPort(host: "127.0.0.1", port: port)),
            using: parameters
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                // An honest PAKE message under a code this probe invents. The responder
                // answers with its own message either way — it cannot know the code is wrong
                // until the confirmation that never comes — so this draws a reply out of a
                // live listener without spending an attempt.
                guard let self else { return }
                let session = SPAKE2Session(
                    role: .initiator,
                    myName: PairingChannel.initiatorName,
                    theirName: PairingChannel.responderName
                )
                if let message = try? session.message(for: .mint()) {
                    FleetSocket.send(PairingClientFrame.pake(msg: message), over: connection)
                }
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        FleetSocket.receive(PairingServerFrame.self, from: connection) { [weak self] _ in
            guard let self, !self.ended else { return }
            self.onAnyFrame?()
        } onEnd: { [weak self] _ in
            self?.finish()
        }
        connection.start(queue: .main)
    }

    /// The frame the pairing vocabulary cannot express, written straight onto the socket.
    func sendRawFleetHello() {
        guard let connection,
              let data = try? JSONEncoder().encode(ClientFrame.hello(lastSeq: 0, device: "iPhone"))
        else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(
            content: data, contentContext: context, isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }

    func stop() {
        ended = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        onEnd?()
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: compile failure — `value of type 'FleetService' has no member 'pairingPort'`, and `armed.code` unresolved.

- [ ] **Step 4: Mint the code in the armer**

In `Sources/FlightDeck/Fleet/PairingArmer.swift`, add above `final class PairingArmer`:

```swift
/// What one open window consists of: the QR's payload and the short code, minted together.
///
/// One value rather than two returns, because they are one fact — the same window, presented
/// two ways — and a sheet that received them separately could draw a code from one window
/// beside a QR from another.
///
/// `Identifiable` on the slot so `DevicesSettingsTab` can drive its `.sheet(item:)` from the
/// window itself. See that call site for why `.sheet(item:)` and not `.sheet(isPresented:)`.
struct ArmedPairing: Identifiable {
    let payload: PairingPayload
    let code: PairingCode

    var id: UUID { payload.key.slot }
}
```

Then change `arm(macName:serviceName:endpoints:)`'s signature and return:

```swift
    func arm(macName: String, serviceName: String, endpoints: [String]) -> ArmedPairing {
        let key = FleetDeviceKey.mint()
        // Minted here, beside the device key, and from the same CSPRNG. The two are
        // independent secrets for independent jobs — the key is what the phone keeps, the code
        // is only ever a password for one SPAKE2 exchange inside this window — and neither is
        // derived from the other.
        let code = PairingCode.mint()
        pending = PairedDevice(
            slot: key.slot, name: "New device", secret: key.secret,
            pairedAt: nil, lastSeenAt: nil, armedUntil: now().addingTimeInterval(Self.window)
        )
        return ArmedPairing(
            payload: PairingPayload(
                key: key, macName: macName, serviceName: serviceName, endpoints: endpoints
            ),
            code: code
        )
    }
```

- [ ] **Step 5: Own the listener in the service**

In `Sources/FlightDeck/Fleet/FleetService.swift`:

Add the stored properties beside `boundPort`:

```swift
    /// The window's own listener, and the port it is on. Both are `nil` whenever no window is
    /// open, which is invariant 2 stated as a field rather than as a comment.
    private let pairing = PairingListener()
    private(set) var pairingPort: NWEndpoint.Port?
```

Replace the body of `arm()` with:

```swift
    func arm() async throws -> ArmedPairing {
        armer.cancel()
        // Before anything else: a second `arm()` must not leave the previous window's listener
        // answering on its old port with its old code.
        closePairingListener()
        preferences.pairedDevices
            .filter(\.isProvisional)
            .forEach { preferences.revokeDevice(slot: $0.slot) }

        guard let boundPort else { throw FleetSocketError.didNotBind }
        let port = boundPort.rawValue
        let macName = Host.current().localizedName ?? "Mac"
        let armed = armer.arm(
            macName: macName,
            serviceName: serviceName,
            endpoints: LocalEndpoints.current(port: port)
        )
        if let pending = armer.pending {
            preferences.upsert(pending)
            if let armedUntil = pending.armedUntil { scheduleExpiry(at: armedUntil) }
        }
        try await reloadKeys()

        pairing.onPaired = { [weak self] in
            // `PairingListener` invokes this on its queue, which is `.main` — the same
            // `assumeIsolated` premise `onAttachedSlotsChanged` already relies on.
            MainActor.assumeIsolated {
                // Deferred by one turn on purpose: this fires from inside the listener's own
                // frame handler, and `stop()` cancels the very connection that handler is
                // still holding. `NWConnection.cancel` flushes queued sends, so the sealed
                // frame still goes out either way — but tearing the socket down from under
                // its own callback is a shape not worth relying on.
                Task { @MainActor [weak self] in self?.closePairingListener() }
            }
        }
        pairing.onAttemptsExhausted = { [weak self] in
            MainActor.assumeIsolated {
                // Three failures burn the window (§7): the provisional key is revoked and the
                // user re-arms. `cancelArming` is the same path the Cancel button takes.
                Task { @MainActor [weak self] in try? await self?.cancelArming() }
            }
        }
        pairingPort = try await pairing.start(
            code: armed.code, key: armed.payload.key, macName: macName,
            serviceName: serviceName, port: nil
        )
        return armed
    }
```

Add the helper directly below `arm()`:

```swift
    /// The one place the pairing listener is torn down, so every route that closes a window
    /// closes it identically (invariant 2). `pairingPort` is cleared with it because the two
    /// are one fact: a port with no listener behind it is exactly the state that made
    /// "is a window open?" answerable two ways.
    private func closePairingListener() {
        pairing.stop()
        pairingPort = nil
    }
```

Then add `closePairingListener()` to the other three routes:

- `stop()` — as its first line, before `server.stop()`.
- `cancelArming()` — after `expiryTask?.cancel()`.
- `expireArming()` — after `armer.expire()`'s `guard armer.pending == nil else { return }`, before `preferences.revokeDevice`.

And update `reloadKeys()`'s doc comment with one sentence: *"It restarts the fleet listener only — the pairing listener's lifetime is the window's, not the key set's, and rebinding it here would move a port a phone is mid-exchange on."*

- [ ] **Step 6: Follow the return type through the UI and the existing tests**

In `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift`, change the state and the sheet:

```swift
    @State private var pairingWindow: ArmedPairing?
```

```swift
        .sheet(item: $pairingWindow) { window in
            PairingCodeSheet(
                service: service, preferences: preferences, payload: window.payload
            )
        }
```

and in `arm()`, `pairingWindow = try await service.arm()`.

(The sheet still draws only the QR. Showing `window.code` is the UI plan's first job; this task's only obligation is that the app compiles and behaves exactly as it did.)

In `Tests/FlightDeckTests/PairingArmerTests.swift` and `Tests/FlightDeckTests/FleetPairingFlowTests.swift`, every `let payload = ... .arm()` becomes `let armed = ... .arm()` with `payload.key` → `armed.payload.key` and `payload.endpoints` → `armed.payload.endpoints`. Add one assertion to `PairingArmerTests.testArmingMintsAFreshSecretEveryTime`:

```swift
        XCTAssertNotEqual(
            first.code.secret, second.code.secret,
            "two windows must not share a code"
        )
```

- [ ] **Step 7: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1244** tests, 0 failures (1240 + 4).

- [ ] **Step 8: Prove the invariant-2 test can fail**

Delete the `closePairingListener()` call from `cancelArming()` only. Run:

`./scripts/test-unit.sh 2>&1 | grep -A6 testEveryRouteThatClosesTheWindowClosesThePairingListener`

Expected: **FAIL** — "cancelling the window left the pairing listener up". Restore it, then repeat once for `expireArming()` and once for `stop()`, confirming each produces its own message. Three separate demonstrations, because one shared teardown call passing for the wrong reason is exactly how this test would rot. Revert all and re-run to green.

- [ ] **Step 9: Prove the invariant-3 test can fail**

In `PairingListener.accept`, change the receive to decode fleet frames instead, which is the mis-wiring the invariant exists to forbid:

```swift
        FleetSocket.receive(ClientFrame.self, from: connection) { [weak self] frame in
            guard let self else { return }
            FleetSocket.send(ServerFrame.ack(cid: 0), over: connection)
        } onEnd: { [weak self] _ in self?.drop(id) }
```

Run: `./scripts/test-unit.sh 2>&1 | grep -A6 testAHelloOnThePairingSocketReachesNothing`

Expected: **FAIL** — the `hello` parses and is answered, so `onEnd` never fires and the expectation times out. Revert and re-run to green.

- [ ] **Step 10: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

- [ ] **Step 11: Commit**

```bash
git add Sources/FlightDeck/Fleet/PairingArmer.swift Sources/FlightDeck/Fleet/FleetService.swift Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift Tests/FlightDeckTests/PairingWindowTests.swift Tests/FlightDeckTests/PairingTestClient.swift Tests/FlightDeckTests/PairingArmerTests.swift Tests/FlightDeckTests/FleetPairingFlowTests.swift
git commit -m "feat: a pairing window that opens and closes with its listener"
```

---

## Acceptance

The plan is done when all of the following hold.

1. `./scripts/test-unit.sh` reports **1244** tests, 0 failures.
2. `./scripts/build-ios.sh` reports three successes.
3. `testATypedCodePairsAndTheDeliveredKeyReachesTheFleet` passes — a real armed Mac, a real SPAKE2 exchange over a real socket, a real sealed key, and that key completing a TLS-PSK handshake against the fleet listener.
4. **Each of the spec's four §6 invariants has a test, and each has been demonstrated to fail against the unfixed behaviour** — Task 1 Step 6, Task 3 Step 7, Task 5 Steps 3–4, Task 8 Steps 8–9. A task whose demonstration step was skipped is not complete, whatever its tests report.

### The cross-process check, and where it lives

The spec's §10 also asks for a **cross-process macOS-against-iOS pairing exchange**. It is not in this plan, because there is nothing in this plan for a person to type a code into: it is stated in full, as an acceptance criterion, in [`2026-08-21-pairing-ui.md`](2026-08-21-pairing-ui.md), which builds the screens that make it performable.

What matters here is what that check is *for*, because this plan is the half that can get it wrong. It catches **caller-side asymmetry** — the two ends disagreeing about which is the initiator, about the two names they pass to `SPAKE2Session`, or about the order in which they assemble the transcript. Those are decisions made in `PairingListener.handle` and `PairingInitiator.start`, and a wire test between two processes is a real check on them.

It does **not** catch a consistent role or name swap *inside* `SPAKE2Session`. Both ends compile the same `FleetKit`, so such a swap is applied identically on both sides and crosses the wire intact — demonstrated rather than argued in `docs/FOLLOWUPS.md`, where two mutants each passed all seventeen SPAKE2 and `PairingSecrets` tests. What closes that is a second implementation of the *caller*, not a second process: `testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder` drives one side through the raw C API with a literal `spake2_role_alice`, and both mutants fail it. That is already in place, in process. Getting this distinction backwards is what `docs/FOLLOWUPS.md` had to be corrected for; do not reintroduce the stronger claim.

Within this plan, the nearest available check is `PairingTestClient` — a second implementation of the *initiator caller*, written from the protocol rather than from `PairingInitiator`, which `PairingListenerTests` drives against the real listener.

## Self-Review

Run against the spec with fresh eyes.

**Spec coverage.**

| Spec | Where |
|---|---|
| §4 the code, checksum load-bearing | Plan A (`PairingCode`); reached here by Task 5's typo tests and by `PairingRunner` taking a `PairingCode`, not a `String` |
| §5 SPAKE2 via BoringSSL, agreement not conformance | Plan A; consumed unchanged in Tasks 3–4 |
| §6 separate listener, not the fleet listener | Task 3 |
| §6 public bootstrap PSK, independent of the code | Task 1 |
| §6 invariant 1 | Task 1, Steps 1 + 6 |
| §6 invariant 2 | Task 8, Steps 1 + 8; discovery half in Task 6 |
| §6 invariant 3 | Task 2 (visibility) + Task 8, Steps 1 + 9 |
| §6 invariant 4 | Task 3, Steps 3 + 7 |
| §7 flow: mint, open listener, advertise, exchange, seal, reconnect | Tasks 3, 4, 6, 8 |
| §7 0 / 1 / 2+ Macs | Task 7 |
| §7 rate limit, per-Mac per-window | Task 5 |
| §7 a failed checksum is not an attempt | Task 5, plus `PairingRunner`'s signature |
| §8 packed QR payload | **UI plan** — no wire dependency, and it changes what the sheet draws |
| §9 amendments to the mobile-companion spec | **UI plan** |
| §10 loopback pairing end to end | Task 8, Step 1 |
| §10 cross-process macOS-against-iOS | **UI plan**; scope and limits recorded above |
| §11 not in this slice | Honoured: the QR path is untouched here, steady-state transport is untouched, nothing migrates |

No gap. Two rows point at the sibling plan by design, and both are stated there.

**Placeholder scan.** No "TBD", no "add error handling", no "similar to Task N", no test described without its code. Every code step is a complete block. Task 5 deliberately contains no source change — it is a proof task over Task 3's implementation, and says so rather than inventing work.

**Type consistency.** Checked across tasks: `PairingChannel.initiatorName`/`responderName` (Task 1) are the names passed in Tasks 3 and 4 and in both test helpers. `PairingSecrets.matches(_:_:)` (Task 2) is called in Tasks 3, 4 and the Task 3 tests. `PairingListener.maxAttempts`/`maxPending`/`attemptsSpent`/`authDeadline`/`onPaired`/`onAttemptsExhausted` (Task 3) are used with those exact names in Tasks 5, 7 and 8. `PairingInitiator.Failure`'s four cases (Task 4) are matched exhaustively in Tasks 5 and 7 and surfaced through `PairingRunner.Progress.failed` in Task 7. `PairingBrowser.DiscoveredMac(serviceName:displayName:endpoint:)` (Task 6) is constructed by hand in Tasks 7 and 8 with those labels. `ArmedPairing.payload`/`.code` (Task 8) is what Task 8's own tests and the UI plan's Task 2 both read.

**One thing the self-review changed.** The first draft had `PairingRunner` browsing in every test. That makes the ordering tests depend on what else is armed on the developer's LAN — and a debug Flight Deck is running on this machine. Split into `start(code:candidates:)` for the deterministic tests and one browse-driven test that skips rather than fails when the network is busy.
