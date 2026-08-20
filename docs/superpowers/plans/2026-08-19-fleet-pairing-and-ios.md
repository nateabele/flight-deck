# Fleet Pairing and the iOS Fleet List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pair a phone to a Mac by scanning a QR the Mac shows while armed, then see the whole fleet live on the phone — every session with its status, sub-agent count and unread mark — and clear an unread from either end.

**Architecture:** Pairing mints a 32-byte secret and a slot id on the Mac, displays them once in a QR, and stores them on both sides; from then on the slot's TLS pre-shared key *is* the phone's identity, so revoking is deleting a key and an unpaired peer never completes a handshake. The Mac advertises `_flightdeck._tcp` over Bonjour and the phone races every endpoint it knows in parallel — no stable hostname is assumed anywhere. The phone is a `FleetKit` client and holds no agent integration code at all.

**Tech Stack:** Swift 6 (FleetKit, iOS app) / Swift 5 (macOS app) / SwiftUI / Network.framework / AVFoundation / Security (Keychain) / XCTest / xcodegen + xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-18-mobile-companion-design.md` — read §3, §7 and §8 before Task 1.

**Prerequisite:** `docs/superpowers/plans/2026-08-19-fleet-replication-spine.md` must be complete. This plan consumes `FleetKit`'s wire types, `FleetTLS`, `FleetSocketServer`, `FleetClient` and the app's `FleetService` as they stand at the end of it.

## Global Constraints

Everything in the spine plan's Global Constraints still applies. In addition:

- **This machine cannot run the iOS app.** `xcrun simctl list runtimes` is empty and there is no provisioning profile. Every task here is verified by `./scripts/test-unit.sh` (macOS, headless) plus `./scripts/build-ios.sh` (compile-only). Running on hardware is the manual checklist in Task 11, and it is the user's call when to do it — **do not** attempt to install a simulator runtime or configure signing without being asked.
- **All logic is tested on macOS.** The pairing payload, the arming window, the paired-device store, endpoint racing and connection state are plain values and go in `Tests/FlightDeckTests`. Only SwiftUI views live in the iOS target, and they are not unit-tested.
- **The secret never reaches a URL, a log, or `UserDefaults` on iOS.** It goes in the Keychain, not synchronized, this-device-only. On the Mac it lives in the existing `preferences.v1` blob alongside the rest of Preferences, which is `UserDefaults` — that is a deliberate, stated limitation, not an oversight (see Task 3).
- **Never `defaults delete dev.flightdeck.FlightDeck`.** Paired devices live in that domain now, so deleting it silently unpairs every phone.
- **`wait(for:)` deadlocks in a `@MainActor` async XCTest method** under this repo's headless harness — it blocks the main actor's executor without suspending it, starving the very main-queue callbacks it awaits, so the test hangs rather than failing. Use `await fulfillment(of:timeout:)`. It also costs roughly 100ms per call even when it does work, and a non-isolated test class is unaffected, which is what makes the failure confusing the first time it is hit. Network.framework delivers its handlers on `.main` by default, so anything here touching a socket from a `@MainActor` test hits it immediately.
- **`FleetSocketServer.start(keys:port:)` is `async throws`** — it awaits the OS reporting the bound port rather than polling for it, because polling blocked its caller for up to five seconds and these types are main-actor. Everything funnelling into it (`FleetService.start`, `reloadKeys`, `arm`, `cancelArming`, `expireArming`) is `async` too, and their tests await them.

---

### Task 1: The pairing payload

What the QR carries, as a pure codec. Everything else in this plan depends on its exact shape, and it is the one part that must be right before a pixel is drawn.

Two deliberate choices, both about where the secret must never end up:

- **It is not a URL.** `flightdeck1:<base64url>` has no `//`, no scheme any handler claims, and no query string. A `flightdeck://pair?psk=…` would be openable from the system camera, land in a URL handler, and be exactly the sort of thing that ends up in a log — and with a relay later, someone else's log. The user must scan it *inside* the phone app, which is also the honest description of what pairing is.
- **It carries endpoints as candidates, not as an address.** The key identifies the Mac; every address is a guess to be raced (§3).

**Files:**
- Create: `Sources/FleetKit/PairingPayload.swift`
- Test: `Tests/FlightDeckTests/PairingPayloadTests.swift`

**Interfaces:**
- Consumes: `FleetDeviceKey` (spine Task 6).
- Produces: `public struct PairingPayload: Equatable, Sendable` with `version`, `key: FleetDeviceKey`, `macName: String`, `serviceName: String`, `endpoints: [String]`; `public func encoded() -> String`; `public init(decoding: String) throws`; `public enum PairingPayloadError: Error { case notAPairingCode, unsupportedVersion(Int), malformed }`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/PairingPayloadTests.swift`:

```swift
import XCTest
import FleetKit

final class PairingPayloadTests: XCTestCase {
    private func payload() -> PairingPayload {
        PairingPayload(
            key: FleetDeviceKey.mint(),
            macName: "Nate's MacBook Pro",
            serviceName: "flight-deck-a1b2",
            endpoints: ["192.168.1.20:53211", "10.8.0.3:53211"]
        )
    }

    func testAPayloadRoundTrips() throws {
        let original = payload()
        XCTAssertEqual(try PairingPayload(decoding: original.encoded()), original)
    }

    /// The code is deliberately not a URL: nothing in the system should offer to "open" it,
    /// because opening it means the secret has travelled through a URL handler and,
    /// eventually, a log.
    /// Nothing in the system should offer to "open" this, because opening it means the
    /// secret has travelled through a URL handler and, eventually, a log. Note `URL(string:)`
    /// does return non-nil for an opaque `scheme:body` URI — the protection is the absence of
    /// an authority component and a query string, not the absence of a `URL` value.
    func testTheCodeIsNotAURL() {
        let encoded = payload().encoded()
        XCTAssertTrue(encoded.hasPrefix("flightdeck1:"))
        XCTAssertFalse(encoded.contains("//"))
        XCTAssertFalse(encoded.contains("?"))
        XCTAssertNil(URL(string: encoded)?.host)
    }

    /// The base64url transform, duplicated locally on purpose. `FleetKit`'s own helper is
    /// `internal`, and widening it to `public` just so one negative assertion could reach it
    /// would put a `Data` extension into every consumer's namespace — a permanent collision
    /// risk bought for a single test. The transform is three lines of RFC 4648 §5, and this
    /// assertion only needs a string to look for rather than production's exact code path;
    /// the round-trip test above already exercises the real implementation.
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Checks both alphabets. The implementation encodes the secret as base64url *inside*
    /// the JSON before the whole body is encoded again, so only the standard-alphabet form
    /// being absent would leave the likelier bug — a body that skipped the outer wrap —
    /// undetected.
    func testTheSecretIsNotReadableFromTheCodeAsText() {
        let key = FleetDeviceKey.mint()
        let encoded = PairingPayload(
            key: key, macName: "m", serviceName: "s", endpoints: []
        ).encoded()
        XCTAssertFalse(encoded.contains(key.secret.base64EncodedString()),
                       "the body is base64url of JSON; a raw base64 secret would mean it is not")
        XCTAssertFalse(encoded.contains(base64URL(key.secret)),
                       "the inner base64url secret must not survive into the outer encoding")
    }

    func testAnArbitraryStringIsRejectedRatherThanPartlyParsed() {
        XCTAssertThrowsError(try PairingPayload(decoding: "https://example.com")) { error in
            XCTAssertEqual(error as? PairingPayloadError, .notAPairingCode)
        }
        // Asserting the specific case, not merely that something threw: the phone shows
        // different copy per case, so collapsing two of them into one is a real defect that a
        // bare `XCTAssertThrowsError` would wave through.
        XCTAssertThrowsError(try PairingPayload(decoding: "flightdeck1:not-base64!!")) { error in
            XCTAssertEqual(error as? PairingPayloadError, .malformed)
        }
    }

    /// A phone older than the Mac must say so rather than mis-parsing a newer payload into
    /// a plausible-looking wrong key.
    func testAFutureVersionIsRejectedByVersionNotByShape() throws {
        var original = payload()
        original.version = 99
        XCTAssertThrowsError(try PairingPayload(decoding: original.encoded())) { error in
            XCTAssertEqual(error as? PairingPayloadError, .unsupportedVersion(99))
        }
    }

    /// The case the previous test cannot reach, and the one that actually matters: a future
    /// payload whose *shape* differs. Decoding it under this version's schema fails, so a
    /// version check that ran after the decode would report it as damaged — sending the user
    /// to show a fresh code when the app is what needs updating. The version therefore has to
    /// be read from the prefix, before any decoding.
    func testAFutureShapeIsRejectedAsTooNewNotAsDamaged() throws {
        let alienBody = Data(#"{"v":2,"slotId":"nope","secret":"nope"}"#.utf8)
        let code = "flightdeck2:" + base64URL(alienBody)
        XCTAssertThrowsError(try PairingPayload(decoding: code)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .unsupportedVersion(2))
        }
    }

    /// A prefix version that disagrees with the body's is a hand-edited code, not a newer one.
    func testAPrefixVersionDisagreeingWithTheBodyIsMalformed() throws {
        let body = Data(#"{"v":7,"slot":"00000000-0000-0000-0000-000000000000","psk":"AAAA","name":"m","svc":"s","eps":[]}"#.utf8)
        let code = "flightdeck1:" + base64URL(body)
        XCTAssertThrowsError(try PairingPayload(decoding: code)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .malformed)
        }
    }

    func testEndpointsSurviveInTheOrderTheMacListedThem() throws {
        let original = payload()
        XCTAssertEqual(
            try PairingPayload(decoding: original.encoded()).endpoints,
            ["192.168.1.20:53211", "10.8.0.3:53211"]
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'PairingPayload' in scope`.

- [ ] **Step 3: Write the payload**

Create `Sources/FleetKit/PairingPayload.swift`:

```swift
import Foundation

public enum PairingPayloadError: Error, Equatable {
    case notAPairingCode
    case unsupportedVersion(Int)
    case malformed
}

/// What the QR on the Mac's screen carries, and the only thing that ever crosses between
/// the two devices out of band.
///
/// `flightdeck1:` + base64url of a small JSON object. Not a URL, deliberately — see the
/// plan's Task 1. The digits in the prefix are the version, and they are checked before any
/// base64 or JSON decoding happens, so a code from a newer Mac is refused *as* too-new rather
/// than as damaged.
public struct PairingPayload: Equatable, Sendable {
    public static let currentVersion = 1
    /// The scheme half of the code. The version is spelled into the prefix — `flightdeck1:` —
    /// and that is load-bearing, not cosmetic: a payload from a newer Mac may rename or retype
    /// fields, so decoding it under this version's schema would fail as *damaged*. The phone
    /// shows different copy for damaged ("show a new code on your Mac") and too-new ("update
    /// the app"), which send the user in opposite directions — so the version has to be
    /// readable without decoding anything.
    private static let scheme = "flightdeck"

    public var version: Int
    public var key: FleetDeviceKey
    /// Shown on the phone so the user can tell two Macs apart. Cosmetic; identity is the key.
    public var macName: String
    /// The Bonjour instance name to look for on a LAN.
    public var serviceName: String
    /// Every address the Mac could see for itself when the QR was drawn, best first. These
    /// are *candidates* to race, not an address to trust: the key identifies the Mac, and by
    /// the time the phone leaves the room every one of these may be wrong.
    public var endpoints: [String]

    public init(
        version: Int = PairingPayload.currentVersion,
        key: FleetDeviceKey, macName: String, serviceName: String, endpoints: [String]
    ) {
        self.version = version
        self.key = key
        self.macName = macName
        self.serviceName = serviceName
        self.endpoints = endpoints
    }

    private struct Body: Codable {
        var v: Int
        var slot: UUID
        var psk: String
        var name: String
        var svc: String
        var eps: [String]
    }

    public func encoded() -> String {
        let body = Body(
            v: version, slot: key.slot, psk: key.secret.base64URLEncodedString(),
            name: macName, svc: serviceName, eps: endpoints
        )
        // `try!` is honest here: `Body` is all `Codable` primitives with no custom encoding,
        // so a throw would be a compiler bug rather than a runtime condition to handle.
        let json = try! JSONEncoder().encode(body)
        return "\(Self.scheme)\(version):" + json.base64URLEncodedString()
    }

    public init(decoding code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.scheme), let colon = trimmed.firstIndex(of: ":")
        else { throw PairingPayloadError.notAPairingCode }

        let digits = trimmed[
            trimmed.index(trimmed.startIndex, offsetBy: Self.scheme.count)..<colon
        ]
        // Digits only, not merely `Int`-parseable: `Int` accepts a leading `-` or `+`, so
        // without this `flightdeck+1:` would sail past the gate as version 1, and
        // `flightdeck-1:` would be reported as an unsupported version rather than as not a
        // pairing code at all. `encoded()` never emits either, so both are malformed input.
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let version = Int(digits)
        else { throw PairingPayloadError.notAPairingCode }
        // Before a byte is decoded. A future payload may not parse under this schema at all,
        // and failing it as "damaged" would send the user to show a fresh code when what they
        // actually need is to update the app.
        guard version == Self.currentVersion else {
            throw PairingPayloadError.unsupportedVersion(version)
        }

        guard let json = Data(base64URLEncoded: String(trimmed[trimmed.index(after: colon)...])),
              let body = try? JSONDecoder().decode(Body.self, from: json),
              let secret = Data(base64URLEncoded: body.psk)
        else { throw PairingPayloadError.malformed }
        // The body repeats the version so a hand-edited prefix cannot walk a mismatched body
        // past the gate above.
        guard body.v == version else { throw PairingPayloadError.malformed }

        self.init(
            version: body.v,
            key: FleetDeviceKey(slot: body.slot, secret: secret),
            macName: body.name, serviceName: body.svc, endpoints: body.eps
        )
    }
}

extension Data {
    /// base64url (RFC 4648 §5): no `+`, `/` or `=`, so the whole code survives being typed,
    /// pasted, or read aloud without escaping.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        self = data
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/PairingPayload.swift Tests/FlightDeckTests/PairingPayloadTests.swift
git commit -m "feat: carry a pairing secret in a code nothing will offer to open"
```

---

### Task 2: The paired-device record and the arming window

Pairing is the entire authorization story (§3), so the rules about *when* a key is accepted are the security model and belong in a pure, tested type rather than in a view's state.

Three rules, and each one is a hole if it is missing: the Mac is never passively pairable, an armed window expires on its own, and a code is single-use.

**Files:**
- Create: `Sources/FlightDeck/Fleet/PairedDevice.swift`
- Create: `Sources/FlightDeck/Fleet/PairingArmer.swift`
- Test: `Tests/FlightDeckTests/PairingArmerTests.swift`

**Interfaces:**
- Consumes: `FleetDeviceKey`, `PairingPayload` (Task 1).
- Produces:
  - `struct PairedDevice: Codable, Equatable, Identifiable { let slot: UUID; var name: String; var secret: Data; var pairedAt: Date?; var lastSeenAt: Date?; var armedUntil: Date? }` with `var id: UUID { slot }`, `var isProvisional: Bool`, and `func key() -> FleetDeviceKey`.
  - `@MainActor final class PairingArmer` — `init(now:)`, `arm(macName:serviceName:endpoints:) -> PairingPayload`, `cancel()`, `claim(slot:) -> Bool`, `expire()`, `var pending: PairedDevice?`, `static let window: TimeInterval`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/PairingArmerTests.swift`:

```swift
import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class PairingArmerTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000_000)

    private func armer() -> PairingArmer {
        PairingArmer(now: { self.now })
    }

    private func arm(_ armer: PairingArmer) -> PairingPayload {
        armer.arm(macName: "mac", serviceName: "svc", endpoints: ["127.0.0.1:1"])
    }

    /// The Mac is never passively pairable. Nothing exists to claim until the user opens a
    /// window, which is the whole difference between this and a machine anyone on the LAN
    /// can adopt.
    func testNothingIsPendingUntilTheUserArms() {
        XCTAssertNil(armer().pending)
        XCTAssertFalse(armer().claim(slot: UUID()))
    }

    func testArmingMintsAFreshSecretEveryTime() {
        let armer = armer()
        let first = arm(armer)
        let second = arm(armer)
        XCTAssertNotEqual(first.key.secret, second.key.secret)
        XCTAssertNotEqual(first.key.slot, second.key.slot)
        XCTAssertEqual(armer.pending?.slot, second.key.slot,
                       "re-arming replaces the window; two codes must never be live at once")
    }

    func testAClaimInsideTheWindowPairsTheDevice() {
        let armer = armer()
        let payload = arm(armer)
        now += 30
        XCTAssertTrue(armer.claim(slot: payload.key.slot))
        XCTAssertNil(armer.pending, "a claimed window is closed")
    }

    /// Single-use. A QR left on screen and photographed after the fact must not pair a
    /// second device.
    func testACodeCannotBeClaimedTwice() {
        let armer = armer()
        let payload = arm(armer)
        XCTAssertTrue(armer.claim(slot: payload.key.slot))
        XCTAssertFalse(armer.claim(slot: payload.key.slot))
    }

    func testAClaimAfterTheWindowIsRefused() {
        let armer = armer()
        let payload = arm(armer)
        now += PairingArmer.window + 1
        XCTAssertFalse(armer.claim(slot: payload.key.slot))
    }

    func testAClaimForADifferentSlotIsRefused() {
        let armer = armer()
        _ = arm(armer)
        XCTAssertFalse(armer.claim(slot: UUID()))
    }

    func testExpiringDropsAStaleWindowSoItsKeyStopsBeingAccepted() {
        let armer = armer()
        _ = arm(armer)
        now += PairingArmer.window + 1
        armer.expire()
        XCTAssertNil(armer.pending)
    }

    func testExpiringLeavesALiveWindowAlone() {
        let armer = armer()
        _ = arm(armer)
        now += 5
        armer.expire()
        XCTAssertNotNil(armer.pending)
    }

    func testCancellingClosesTheWindowImmediately() {
        let armer = armer()
        _ = arm(armer)
        armer.cancel()
        XCTAssertNil(armer.pending)
    }

    func testTheProvisionalRecordCarriesTheSameKeyAsTheQR() {
        let armer = armer()
        let payload = arm(armer)
        let pending = armer.pending
        XCTAssertEqual(pending?.key(), payload.key)
        XCTAssertEqual(pending?.isProvisional, true)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'PairingArmer' in scope`.

- [ ] **Step 3: Write the device record**

Create `Sources/FlightDeck/Fleet/PairedDevice.swift`:

```swift
import FleetKit
import Foundation

/// One slot in the paired-devices list.
///
/// A *provisional* device is a window the user has opened and nobody has walked through
/// yet: its key is already live on the listener — it has to be, or the phone could not
/// complete a handshake — but it expires on its own and is discarded if unclaimed. That is
/// what keeps "armed" a moment rather than a state the machine can be left in.
struct PairedDevice: Codable, Equatable, Identifiable {
    let slot: UUID
    /// What the user calls this phone. Named on the Mac, because that is where the list is
    /// managed and where revoking happens.
    var name: String
    var secret: Data
    /// When the first successful handshake happened. `nil` while provisional.
    var pairedAt: Date?
    var lastSeenAt: Date?
    /// Set only while provisional; the instant after which this slot must be discarded.
    var armedUntil: Date?

    var id: UUID { slot }
    var isProvisional: Bool { pairedAt == nil }

    func key() -> FleetDeviceKey { FleetDeviceKey(slot: slot, secret: secret) }
}
```

- [ ] **Step 4: Write the armer**

Create `Sources/FlightDeck/Fleet/PairingArmer.swift`:

```swift
import FleetKit
import Foundation

/// The pairing window: one provisional slot at a time, expiring on its own, claimable once.
///
/// A pure state machine over an injected clock, so the three rules that constitute the
/// authorization model are assertable without a listener, a camera or a timer. The UI's job
/// is to call `arm`, show the payload, and stop — it holds no policy.
@MainActor
final class PairingArmer {
    /// Long enough to walk to the phone and open the app; short enough that a QR left on a
    /// screen stops being a key almost immediately.
    static let window: TimeInterval = 120

    private let now: () -> Date
    private(set) var pending: PairedDevice?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Opens a window, replacing any window already open — two live codes at once would
    /// mean a code the user has forgotten about is still a key.
    func arm(macName: String, serviceName: String, endpoints: [String]) -> PairingPayload {
        let key = FleetDeviceKey.mint()
        pending = PairedDevice(
            slot: key.slot, name: "New device", secret: key.secret,
            pairedAt: nil, lastSeenAt: nil, armedUntil: now().addingTimeInterval(Self.window)
        )
        return PairingPayload(
            key: key, macName: macName, serviceName: serviceName, endpoints: endpoints
        )
    }

    func cancel() { pending = nil }

    /// A device completed a handshake on `slot`. Returns whether that closes the window —
    /// i.e. whether this is the device the user just armed for.
    func claim(slot: UUID) -> Bool {
        guard let pending, pending.slot == slot else { return false }
        guard let armedUntil = pending.armedUntil, now() <= armedUntil else { return false }
        self.pending = nil
        return true
    }

    /// Drops a window that has run out. Called on a timer by the UI, and again before every
    /// listener restart, so an expired slot's key stops being accepted rather than merely
    /// stopping being displayed.
    func expire() {
        guard let armedUntil = pending?.armedUntil, now() > armedUntil else { return }
        pending = nil
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Fleet/PairedDevice.swift Sources/FlightDeck/Fleet/PairingArmer.swift \
        Tests/FlightDeckTests/PairingArmerTests.swift
git commit -m "feat: make pairing a window the user opens, not a state the Mac sits in"
```

---

### Task 3: Paired devices in Preferences

Where the list lives, and how a device is revoked. Follows the existing `Preferences` rules exactly, and one of them is load-bearing enough to repeat: **every field added to `Preferences` must be Optional or carry a custom decoder.** `UserDefaultsPreferencesPersistence.load()` decodes with `try?`, and synthesized `Codable` throws on a missing key — so a non-optional field would fail to decode every existing `preferences.v1` blob and silently reset every flag, override and shell setting the user has.

**Honest limitation, to be written into the docs rather than glossed:** these secrets sit in `UserDefaults`, which is a plist in the user's home directory readable by anything running as them. That is the same trust level as `sessions.json` and as the agents' own credentials, and it is consistent with §3's "a QR on an unlocked Mac is seen only by someone who could already use the Mac" — but it is *not* Keychain-grade, and someone will eventually ask.

**Files:**
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift`
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift`
- Test: `Tests/FlightDeckTests/PairedDeviceStoreTests.swift`

**Interfaces:**
- Consumes: `PairedDevice` (Task 2).
- Produces: `Preferences.pairedDevices: [PairedDevice]?` and `Preferences.installID: UUID?`; `PreferencesStore.pairedDevices: [PairedDevice]`, `.installSuffix: String`, `.deviceKeys() -> [FleetDeviceKey]`, `.upsert(_ device: PairedDevice)`, `.revokeDevice(slot: UUID)`, `.renameDevice(slot: UUID, to: String)`, `.noteDeviceSeen(slot: UUID, at: Date)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/PairedDeviceStoreTests.swift`:

```swift
import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class PairedDeviceStoreTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private func device(_ name: String) -> PairedDevice {
        let key = FleetDeviceKey.mint()
        return PairedDevice(
            slot: key.slot, name: name, secret: key.secret,
            pairedAt: Date(), lastSeenAt: nil, armedUntil: nil
        )
    }

    func testADeviceSurvivesASaveAndReload() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        let phone = device("Nate's iPhone")
        store.upsert(phone)

        let reloaded = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reloaded.pairedDevices, [phone])
    }

    /// Revocation is deleting the secret, and this is the assertion that says so: the key is
    /// gone from what the listener will be started with, not merely hidden from a list.
    func testRevokingRemovesTheKeyTheListenerWouldAccept() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        let phone = device("phone")
        let tablet = device("tablet")
        store.upsert(phone)
        store.upsert(tablet)
        store.revokeDevice(slot: phone.slot)
        XCTAssertEqual(store.deviceKeys().map(\.slot), [tablet.slot])
    }

    func testUpsertingTheSameSlotReplacesRatherThanDuplicates() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        var phone = device("phone")
        store.upsert(phone)
        phone.name = "renamed"
        store.upsert(phone)
        XCTAssertEqual(store.pairedDevices.count, 1)
        XCTAssertEqual(store.pairedDevices.first?.name, "renamed")
    }

    func testRenamingAndNotingASightingDoNotDisturbTheSecret() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        let phone = device("phone")
        store.upsert(phone)
        store.renameDevice(slot: phone.slot, to: "Nate's iPhone")
        let seen = Date(timeIntervalSince1970: 2_000_000)
        store.noteDeviceSeen(slot: phone.slot, at: seen)
        XCTAssertEqual(store.pairedDevices.first?.name, "Nate's iPhone")
        XCTAssertEqual(store.pairedDevices.first?.lastSeenAt, seen)
        XCTAssertEqual(store.pairedDevices.first?.secret, phone.secret)
    }

    /// The rule every field in `Preferences` obeys: a blob written before this feature
    /// existed must still decode, or the first launch after an upgrade silently resets every
    /// flag, override and shell setting the user has.
    func testAPreferencesBlobWithNoPairedDevicesKeyStillDecodes() throws {
        let json = Data(#"{"globalFlags":{"flags":[]},"projectFlags":{},"shell":{"environment":{},"clearChildSessionMarker":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertNil(decoded.pairedDevices)
    }

    func testNoDevicesMeansNoKeysRatherThanACrash() {
        XCTAssertTrue(PreferencesStore(persistence: MemoryPersistence()).deviceKeys().isEmpty)
    }

    /// The Bonjour instance name has to survive a relaunch, or a phone that remembers which
    /// Mac it paired with stops recognising it after a restart.
    func testTheInstallSuffixIsMintedOnceAndThenStable() {
        let persistence = MemoryPersistence()
        let first = PreferencesStore(persistence: persistence).installSuffix
        XCTAssertEqual(first.count, 4)
        XCTAssertEqual(PreferencesStore(persistence: persistence).installSuffix, first)
    }

    func testTwoInstallsDoNotShareASuffix() {
        XCTAssertNotEqual(
            PreferencesStore(persistence: MemoryPersistence()).installSuffix,
            PreferencesStore(persistence: MemoryPersistence()).installSuffix
        )
    }
}
```

If the literal in `testAPreferencesBlobWithNoPairedDevicesKeyStillDecodes` does not match `FlagSet`'s actual `Codable` shape, encode an empty `Preferences()`, strip the key you are testing for, and use that — do **not** relax the test to `try?`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `value of type 'Preferences' has no member 'pairedDevices'`.

- [ ] **Step 3: Add the field**

In `Sources/FlightDeck/Preferences/Preferences.swift`, inside `struct Preferences`:

```swift
    /// Phones paired to this Mac, each holding the secret its TLS handshake is authenticated
    /// with. Optional for exactly the reason `confirmations` is — see that property's
    /// comment; a non-optional field here would fail to decode every existing
    /// `preferences.v1` blob.
    ///
    /// These are secrets in `UserDefaults`, which is a plist readable by anything running as
    /// this user. That is the same exposure as `sessions.json` and as the agents' own
    /// credentials, and it matches the trust model in the mobile companion spec §3 — but it
    /// is deliberately not Keychain-grade, and it is recorded in docs/FOLLOWUPS.md rather
    /// than left to be discovered.
    var pairedDevices: [PairedDevice]?

    /// Minted once per install, and used only to make this Mac's Bonjour instance name
    /// unique. Optional for the same reason as everything else here — see `confirmations`.
    var installID: UUID?
```

- [ ] **Step 4: Add the store's accessors**

In `PreferencesStore`, in a `// MARK: Paired devices` section:

```swift
    var pairedDevices: [PairedDevice] { preferences.pairedDevices ?? [] }

    /// Four hex characters disambiguating this Mac's advertised service name. Minted on
    /// first read and written back, so the name a phone remembers keeps resolving after a
    /// relaunch — a suffix regenerated each launch would make Bonjour rediscovery fail in
    /// exactly the case it exists for.
    var installSuffix: String {
        if let existing = preferences.installID {
            return String(existing.uuidString.prefix(4)).lowercased()
        }
        let minted = UUID()
        preferences.installID = minted
        return String(minted.uuidString.prefix(4)).lowercased()
    }

    /// What `FleetService` starts its listener with. A revoked device is absent here, which
    /// is the entirety of what revocation means.
    func deviceKeys() -> [FleetDeviceKey] { pairedDevices.map { $0.key() } }

    func upsert(_ device: PairedDevice) {
        var devices = pairedDevices
        if let at = devices.firstIndex(where: { $0.slot == device.slot }) {
            devices[at] = device
        } else {
            devices.append(device)
        }
        preferences.pairedDevices = devices
    }

    func revokeDevice(slot: UUID) {
        preferences.pairedDevices = pairedDevices.filter { $0.slot != slot }
    }

    func renameDevice(slot: UUID, to name: String) {
        mutateDevice(slot) { $0.name = name }
    }

    func noteDeviceSeen(slot: UUID, at date: Date) {
        mutateDevice(slot) { $0.lastSeenAt = date }
    }

    private func mutateDevice(_ slot: UUID, _ body: (inout PairedDevice) -> Void) {
        var devices = pairedDevices
        guard let at = devices.firstIndex(where: { $0.slot == slot }) else { return }
        body(&devices[at])
        preferences.pairedDevices = devices
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS — including the existing `PreferencesStoreTests`, which is the regression net for not having broken decoding.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Preferences/Preferences.swift \
        Sources/FlightDeck/Preferences/PreferencesStore.swift \
        Tests/FlightDeckTests/PairedDeviceStoreTests.swift
git commit -m "feat: keep paired devices where revoking one is deleting its key"
```

---

### Task 4: Knowing which device connected, and promoting it

Two gaps between the spine and a real pairing flow.

**First: the server does not know *who* attached.** `FleetSocketServer` generates a per-connection id and nothing more, so "phone paired" and "which phone is watching" are both unanswerable. The TLS layer knows — the PSK identity it negotiated is the slot id — and `sec_protocol_metadata_access_pre_shared_keys` (`Security/SecProtocolMetadata.h:283`, macOS 10.15+) is how to read it back.

> **If the metadata does not carry the identity**, fall back to the client naming its own slot in `hello`. That is weaker only in a narrow way: TLS has already proved the peer holds *a* paired key, so a lying client can mislabel which of the user's own phones is attached and nothing more. Record it in `docs/FOLLOWUPS.md` if you take it.

**Second: nothing promotes a provisional slot.** `PairingArmer.claim` decides; this task calls it at the one moment it can be called — the first successful `hello` on that slot.

**Files:**
- Modify: `Sources/FleetKit/FleetSocketServer.swift` (attachment identity)
- Create: `Sources/FlightDeck/Fleet/LocalEndpoints.swift`
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift`
- Test: `Tests/FlightDeckTests/FleetPairingFlowTests.swift`

**Interfaces:**
- Produces:
  - `public struct FleetAttachment: Equatable, Sendable { public let id: UUID; public let slot: UUID? }`, and `FleetSocketServer.onHello`/`onCommand` re-typed to take it.
  - `enum LocalEndpoints { static func current(port: UInt16) -> [String] }`.
  - `FleetService.init(store:preferences:armer:)`, `func arm() throws -> PairingPayload`, `func cancelArming() throws`, `@Published private(set) var attachedSlots: Set<UUID>`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetPairingFlowTests.swift`:

```swift
import Network
import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class FleetPairingFlowTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private var service: FleetService?
    private var client: FleetClient?
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func tearDown() async throws {
        client?.disconnect()
        service?.stop()
        client = nil
        service = nil
    }

    private func standUp() throws -> (SessionStore, PreferencesStore, FleetService) {
        let store = SessionStore(provider: nil, persistence: nil)
        let preferences = PreferencesStore(persistence: MemoryPersistence())
        let service = FleetService(
            store: store, preferences: preferences,
            armer: PairingArmer(now: { self.now })
        )
        self.service = service
        _ = try await service.start(port: nil)
        return (store, preferences, service)
    }

    /// The moment pairing actually completes. Nothing on the wire announces it — a
    /// successful handshake followed by a `hello` *is* the announcement.
    func testTheFirstHelloOnAnArmedSlotPairsTheDevice() async throws {
        let (_, preferences, service) = try standUp()
        let payload = try await service.arm()
        XCTAssertEqual(preferences.pairedDevices.first?.isProvisional, true)

        let attached = expectation(description: "paired")
        let client = FleetClient(key: payload.key)
        self.client = client
        client.onFrame = { if case .snapshot = $0 { attached.fulfill() } }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [attached], timeout: 10)

        let device = try XCTUnwrap(preferences.pairedDevices.first)
        XCTAssertEqual(device.slot, payload.key.slot)
        XCTAssertFalse(device.isProvisional, "a connected device is no longer provisional")
        XCTAssertNotNil(device.pairedAt)
        XCTAssertNil(device.armedUntil)
    }

    func testTheServerLearnsWhichSlotConnected() async throws {
        let (_, _, service) = try standUp()
        let payload = try await service.arm()
        let seen = expectation(description: "slot observed")
        let client = FleetClient(key: payload.key)
        self.client = client
        client.onFrame = { _ in
            MainActor.assumeIsolated {
                if service.attachedSlots.contains(payload.key.slot) { seen.fulfill() }
            }
        }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [seen], timeout: 10)
    }

    /// A code that was never claimed must stop being a key, not just stop being displayed.
    func testAnUnclaimedWindowExpiresOutOfTheAcceptedKeys() async throws {
        let (_, preferences, service) = try standUp()
        let payload = try await service.arm()
        now += PairingArmer.window + 1
        try await service.expireArming()
        XCTAssertTrue(preferences.pairedDevices.isEmpty)
        XCTAssertFalse(preferences.deviceKeys().contains { $0.slot == payload.key.slot })
    }

    /// Revoking is deleting the key, and the listener must stop honouring it — not merely
    /// stop listing it.
    func testARevokedDeviceCanNoLongerConnect() async throws {
        let (_, preferences, service) = try standUp()
        let payload = try await service.arm()
        preferences.revokeDevice(slot: payload.key.slot)
        try await service.reloadKeys()

        let refused = expectation(description: "refused")
        let client = FleetClient(key: payload.key)
        self.client = client
        client.onFrame = { _ in XCTFail("a revoked device reached the application layer") }
        client.onDisconnect = { _ in refused.fulfill() }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        _ = XCTWaiter().await fulfillment(of: [refused], timeout: 8)
    }

    func testArmingTwiceLeavesOnlyTheNewestCodeLive() async throws {
        let (_, preferences, service) = try standUp()
        let first = try await service.arm()
        let second = try await service.arm()
        XCTAssertEqual(preferences.pairedDevices.map(\.slot), [second.key.slot])
        XCTAssertFalse(preferences.deviceKeys().contains { $0.slot == first.key.slot })
    }

    func testThePairingCodeAdvertisesTheListenersRealPort() async throws {
        let (_, _, service) = try standUp()
        let payload = try await service.arm()
        let port = try XCTUnwrap(service.boundPort)
        XCTAssertFalse(payload.endpoints.isEmpty, "a code with no candidates cannot be raced")
        XCTAssertTrue(payload.endpoints.allSatisfy { $0.hasSuffix(":\(port.rawValue)") })
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `FleetService` has no `arm()`, and its initializer does not take a `PreferencesStore`.

- [ ] **Step 3: Give the server an attachment identity**

In `Sources/FleetKit/FleetSocketServer.swift`, add and re-type:

```swift
/// Who is on the other end of one socket.
public struct FleetAttachment: Equatable, Sendable {
    /// This connection. Unique per socket, so two phones sharing a slot are still distinct.
    public let id: UUID
    /// The paired slot the TLS layer negotiated, when it will say. `nil` means the identity
    /// could not be read back — the connection is still authenticated (it could not have
    /// completed a handshake otherwise), it just cannot be attributed to a named device.
    public let slot: UUID?
}
```

`onHello` becomes `((FleetAttachment, Int) -> [ServerFrame])?` and `onCommand` becomes `((FleetAttachment, Int, FleetCommand) -> ServerFrame)?`. In `accept(_:)`, resolve the slot once the connection is ready and build the attachment from it:

```swift
    /// Recovers the PSK identity TLS negotiated, which is the paired slot's UUID.
    ///
    /// The alternative — having the client name its own slot in `hello` — would let a
    /// client mislabel which of the user's phones is attached. It cannot forge access
    /// either way (TLS already proved it holds a paired key), so this is about attribution,
    /// not authorization.
    private func slot(of connection: NWConnection) -> UUID? {
        guard
            let tls = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata
        else { return nil }
        var identity: Data?
        sec_protocol_metadata_access_pre_shared_keys(tls.securityProtocolMetadata) { _, pskIdentity in
            identity = Data(pskIdentity as DispatchData)
        }
        guard let identity else { return nil }
        return UUID(uuidString: String(decoding: identity, as: UTF8.self))
    }
```

`import Security` at the top of that file.

- [ ] **Step 4: Enumerate the Mac's own addresses**

Create `Sources/FlightDeck/Fleet/LocalEndpoints.swift`:

```swift
import Foundation

/// Every address this Mac can currently be reached on, as `host:port` candidates for the
/// pairing code.
///
/// These are candidates, not an address. The key identifies the Mac (§3); by the time the
/// phone has left the room every one of these may be wrong, which is why the phone races
/// them rather than trusting one. Loopback is included deliberately — it is what the
/// loopback tests use, and it costs one failed race attempt in production.
enum LocalEndpoints {
    static func current(port: UInt16) -> [String] {
        var addresses: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let raw = interface.pointee.ifa_addr else { continue }
            let family = raw.pointee.sa_family
            // IPv4 only. A link-local IPv6 address needs a zone index to be dialable and
            // would produce candidates that can never connect — noise in a race that is
            // already parallel.
            guard family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                raw, socklen_t(raw.pointee.sa_len), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            addresses.append("\(String(cString: host)):\(port)")
        }
        // Loopback last: a phone will never reach it, but the tests will, and putting it
        // first would make every real pairing wait out one dead candidate.
        addresses.append("127.0.0.1:\(port)")
        return addresses
    }
}
```

- [ ] **Step 5: Rewrite `FleetService`'s ownership of keys**

Replace the `keys:` closure with the preferences store and the armer, and add the pairing lifecycle:

```swift
    private let preferences: PreferencesStore
    private let armer: PairingArmer
    private(set) var boundPort: NWEndpoint.Port?
    @Published private(set) var attachedSlots: Set<UUID> = []

    /// The Bonjour instance name this Mac advertises under, and the name the phone stores so
    /// it can prefer the Mac it paired with.
    ///
    /// Sanitized and suffixed rather than used raw: a Bonjour instance name cannot carry
    /// arbitrary characters (an apostrophe in "Nate's MacBook" is enough), and two Macs whose
    /// owners both left the default name would otherwise advertise identically — a phone
    /// would then race a machine that will refuse its key. The suffix comes from a stable
    /// per-install id so it survives relaunches.
    let serviceName: String

    init(store: SessionStore, preferences: PreferencesStore, armer: PairingArmer) {
        self.store = store
        self.preferences = preferences
        self.armer = armer
        self.server = FleetSocketServer()
        self.replicator = FleetReplicator { [weak store] in
            guard let store else { return .empty }
            return FleetProjection.snapshot(of: store)
        }
        self.serviceName = Self.derivedServiceName(preferences: preferences)
        store.replicator = replicator
        wireHandlers()
    }

    private static func derivedServiceName(preferences: PreferencesStore) -> String {
        let raw = Host.current().localizedName ?? "Mac"
        let cleaned = raw.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        let trimmed = cleaned.prefix(24).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(trimmed.isEmpty ? "flightdeck" : trimmed.lowercased())-\(preferences.installSuffix)"
    }

    /// Everything the socket calls back into. One method so the initializer reads as
    /// "own these three things, then connect them", rather than as forty lines of closures.
    private func wireHandlers() {
        replicator.onEvents = { [weak self] batch in
            for entry in batch {
                self?.server.broadcast(.event(seq: entry.seq, entry.event))
            }
        }
        server.onHello = { [weak self] attachment, lastSeq in
            guard let self else { return [] }
            self.noteAttached(attachment)
            return self.frames(resumingFrom: lastSeq)
        }
        server.onCommand = { [weak self] _, cid, command in
            self?.apply(command, cid: cid) ?? .err(cid: cid, code: "stopped")
        }
        server.onAttachedCountChanged = { [weak self] count in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.attachedDeviceCount = count
                if count == 0 { self.attachedSlots.removeAll() }
            }
        }
    }

    /// A replay when the ring can serve it, a snapshot when it cannot. The explicit
    /// re-snapshot is the point: silently resuming from wherever the server happens to be is
    /// how a phone ends up confidently displaying a fleet that no longer exists.
    private func frames(resumingFrom lastSeq: Int) -> [ServerFrame] {
        switch replicator.resume(from: lastSeq) {
        case .replay(let events):
            return events.map { .event(seq: $0.seq, $0.event) }
        case .resnapshot(let reason):
            let current = replicator.snapshot()
            return [.snapshot(seq: current.seq, fleet: current.fleet, reason: reason)]
        }
    }

    /// Opens a pairing window and returns the code to display.
    ///
    /// The provisional slot is written to Preferences *before* the listener restarts,
    /// because the phone cannot complete a handshake against a key the listener does not
    /// hold — "armed" and "the key is live" are the same instant by construction.
    func arm() async throws -> PairingPayload {
        armer.cancel()
        preferences.pairedDevices
            .filter(\.isProvisional)
            .forEach { preferences.revokeDevice(slot: $0.slot) }

        let port = boundPort?.rawValue ?? 0
        let payload = armer.arm(
            macName: Host.current().localizedName ?? "Mac",
            serviceName: serviceName,
            endpoints: LocalEndpoints.current(port: port)
        )
        if let pending = armer.pending { preferences.upsert(pending) }
        try await reloadKeys()
        return payload
    }

    func cancelArming() async throws {
        if let pending = armer.pending { preferences.revokeDevice(slot: pending.slot) }
        armer.cancel()
        try await reloadKeys()
    }

    /// Drops a window that ran out. Called on a timer by the pairing sheet, and again before
    /// the sheet closes, so an expired code stops being a key rather than merely stopping
    /// being drawn.
    func expireArming() async throws {
        guard let pending = armer.pending else { return }
        armer.expire()
        guard armer.pending == nil else { return }
        preferences.revokeDevice(slot: pending.slot)
        try await reloadKeys()
    }

    /// Convenience for the tests and for nothing else — production dials a discovered or
    /// remembered endpoint, never a hard-coded host.
    func loopbackEndpoint() throws -> NWEndpoint {
        guard let boundPort else { throw FleetSocketError.didNotBind }
        return .hostPort(host: "127.0.0.1", port: boundPort)
    }
```

`start(port:)` records `boundPort`, and `reloadKeys()` restarts on it so the advertised port survives:

```swift
    /// `async` because `FleetSocketServer.start` awaits the OS reporting its bound port
    /// rather than polling for it — the polling version blocked its caller for up to five
    /// seconds, and this type is main-actor, so that was a visible stall.
    @discardableResult
    func start(port: NWEndpoint.Port? = nil) async throws -> NWEndpoint.Port {
        let bound = try await server.start(keys: preferences.deviceKeys(), port: port ?? boundPort)
        boundPort = bound
        return bound
    }

    /// Restarts the listener so a changed key set takes effect. Every arm, expiry and
    /// revocation calls this, so it runs far more often than "revocation is rare" suggests —
    /// see the note on `FleetSocketServer.stop()` in Task 4.
    func reloadKeys() async throws { try await start() }
```

`wireHandlers` above already routes `onHello` through `noteAttached`, which is where pairing
completes:

```swift
    /// A device said hello. If it is the one the user just armed for, this is the instant
    /// pairing completes — there is no separate pairing exchange, because a completed
    /// TLS-PSK handshake already proved everything a pairing exchange would have.
    private func noteAttached(_ attachment: FleetAttachment) {
        guard let slot = attachment.slot else { return }
        attachedSlots.insert(slot)
        let now = Date()
        if armer.claim(slot: slot), var device = preferences.pairedDevices.first(where: { $0.slot == slot }) {
            device.pairedAt = now
            device.armedUntil = nil
            device.lastSeenAt = now
            preferences.upsert(device)
        } else {
            preferences.noteDeviceSeen(slot: slot, at: now)
        }
    }
```

- [ ] **Step 6: Close the three listener-lifetime gaps the spine's final review deferred to here**

These were found reviewing the spine and deliberately left for this plan, because all three
become reachable the moment pairing starts calling `reloadKeys()` — which `arm`, `expireArming`
and every revocation now do. They were one moment's work then and are one moment's work now;
do them together.

**(a) The bind timeout leaks a listener for five seconds after every successful start.**
`FleetSocketServer.start`'s timeout is a bare closure handed to `queue.asyncAfter`, so there is
nothing to cancel when the bind succeeds immediately. It fires five seconds later, no-ops
against the `resumed` guard, and until then keeps that listener and its continuation alive. With
`reloadKeys()` now running on every arm, expiry and revocation, those overlap. Convert it to a
`DispatchWorkItem` held in a local, and `cancel()` it on the success and failure paths:

```swift
            let timeout = DispatchWorkItem { [weak listener] in
                guard !resumed else { return }
                resumed = true
                listener?.cancel()
                continuation.resume(throwing: FleetSocketError.didNotBind)
            }
            queue.asyncAfter(deadline: .now() + 5, execute: timeout)
```

…and call `timeout.cancel()` immediately before each `continuation.resume` in the state
handler. **Re-derive resume-exactly-once afterwards** against all four interleavings
(timer-then-ready, ready-then-timer, failed-then-timer, timer-then-failed) — the guard still
carries the correctness; cancellation only stops the retention. Both closures run on the same
serial `queue`, which is what makes the flag safe, and that must stay true.

**(b) Nothing caps concurrent unauthenticated connections.** Each peer that completes a
handshake holds a `pending` slot for `authDeadline` before being dropped. Bounded in time,
unbounded in width. Add a modest cap in `accept(_:)` — reject beyond, say, 16 pending — and say
in the comment that this is about a peer that can complete a TLS-PSK handshake, so it bounds a
paired-but-misbehaving device rather than a stranger.

**(c) `FleetReplicator.reset()` tells attached clients nothing.** It clears the ring and bumps
the sequence, so a client that reconnects is correctly re-snapshotted — but one that is
*currently attached* stays silently stale until it happens to drop. Unreachable in the spine
(`restore()` runs inside `SessionStore.init`, before any service exists) and still unreachable
here, but this plan is the first to hold a live service across configuration changes. Add one
sentence to `reset()`'s doc comment saying it does not notify, and that a caller who invokes it
while clients are attached must broadcast a fresh snapshot itself.

Add a test for (a) proving the work item is cancelled — assert that a successful `start` does
not leave the listener retained after resume — or, if that proves awkward to observe, say so in
your report and cover (a) by inspection instead. Do **not** invent a flaky timing test.

- [ ] **Step 7: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, including the spine's `FleetServiceTests` (update its `FleetService(store:keys:)` call sites to the new initializer — that is expected churn, not a regression).

If `testTheServerLearnsWhichSlotConnected` is the only failure, take the fallback documented at the top of this task.

- [ ] **Step 8: Commit**

```bash
git add Sources/FleetKit/FleetSocketServer.swift Sources/FlightDeck/Fleet/LocalEndpoints.swift \
        Sources/FlightDeck/Fleet/FleetService.swift Tests/FlightDeckTests/FleetPairingFlowTests.swift \
        Tests/FlightDeckTests/FleetServiceTests.swift
git commit -m "feat: complete pairing on the first handshake, and name the device that made it"
```

---

### Task 5: The Mac's pairing UI

Where the user arms, sees the code, and revokes. A new Preferences tab, following `AgentsSettingsTab` / `ShellSettingsTab` exactly.

The revocation list and the attached indicator are not polish. §11 of the spec is explicit: *the phone is fully privileged once paired*, and these two are the only user-visible control over that.

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift`
- Create: `Sources/FlightDeck/Preferences/UI/PairingCodeView.swift`
- Modify: `Sources/FlightDeck/Preferences/UI/PreferencesView.swift`
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (own a `FleetService`, start it)
- Test: `Tests/FlightDeckTests/PairingCodeImageTests.swift`

**Interfaces:**
- Consumes: `FleetService` (Task 4), `PairingPayload` (Task 1), `PreferencesStore` (Task 3).
- Produces: `enum PairingCodeImage { static func cgImage(for code: String, size: CGFloat) -> CGImage? }`; SwiftUI views.

- [ ] **Step 1: Write the failing test**

Only the code *rendering* is unit-testable; the views are not, and this repo does not put views under `UITests` for a feature like this (AGENTS.md rule 4).

Create `Tests/FlightDeckTests/PairingCodeImageTests.swift`:

```swift
import CoreImage
import XCTest
import FleetKit
@testable import FlightDeck

final class PairingCodeImageTests: XCTestCase {
    private func code() -> String {
        PairingPayload(
            key: .mint(), macName: "Nate's MacBook Pro",
            serviceName: "flightdeck", endpoints: ["192.168.1.20:53211"]
        ).encoded()
    }

    func testACodeRendersToAnImage() throws {
        let image = try XCTUnwrap(PairingCodeImage.cgImage(for: code(), size: 320))
        XCTAssertGreaterThanOrEqual(image.width, 320)
        XCTAssertEqual(image.width, image.height)
    }

    /// The generator has to survive a payload at the size we actually produce — a QR that
    /// silently fails to encode would show an empty box at exactly the moment the user is
    /// trying to pair.
    func testAFullSizedPayloadStillEncodes() throws {
        let long = PairingPayload(
            key: .mint(), macName: String(repeating: "M", count: 64),
            serviceName: "flightdeck",
            endpoints: (0..<8).map { "192.168.\($0).200:53211" }
        ).encoded()
        XCTAssertNotNil(PairingCodeImage.cgImage(for: long, size: 320))
    }

    /// Round-trips through the actual detector, so this proves the pairing code is
    /// *scannable* rather than merely that some image came back.
    func testTheRenderedCodeDecodesBackToTheSameString() throws {
        let original = code()
        let image = try XCTUnwrap(PairingCodeImage.cgImage(for: original, size: 640))
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode, context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))
        let features = detector.features(in: CIImage(cgImage: image)).compactMap {
            ($0 as? CIQRCodeFeature)?.messageString
        }
        XCTAssertEqual(features.first, original)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'PairingCodeImage' in scope`.

- [ ] **Step 3: Render the code**

Create `Sources/FlightDeck/Preferences/UI/PairingCodeView.swift` with the generator and the sheet. The generator:

```swift
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum PairingCodeImage {
    /// `.medium` error correction, not `.high`: the payload is near a QR version boundary
    /// and higher correction pushes it over, producing a denser code that scans *worse* on
    /// a phone held at arm's length. Scaled with nearest-neighbour so the modules stay
    /// crisp — an interpolated QR is a QR that takes three tries to read.
    static func cgImage(for code: String, size: CGFloat) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, size / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
```

The sheet shows: the QR, the Mac's name, a countdown built from `PairingArmer.window`, the code as selectable text for the phone's manual-entry field, and Cancel. It calls `service.expireArming()` on a 1-second timer and on dismiss.

Copy is exact — write it as given, because it is the only place the trust model is explained to the user:

- Title: **"Pair a device"**
- Body: **"Scan this in Flight Deck on your iPhone. Anyone who can see this code can control this Mac's sessions until you revoke the device. It expires in 2 minutes."**
- The countdown label: **"Expires in 1:47"**
- Manual-entry disclosure: **"Can't scan? Type this code instead"**

- [ ] **Step 4: Write the Devices tab**

Create `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift`:

- **"Pair a Device…"** button → arms and presents the sheet.
- A `List` of `preferences.pairedDevices` that are not provisional, each row showing the name (editable inline, `renameDevice`), "Connected" when `service.attachedSlots.contains(slot)` else a relative last-seen date, and a **Revoke** button.
- Revoke asks first — copy: **"Revoke \(name)? It will stop receiving your sessions immediately and will have to be paired again."** — then calls `revokeDevice` and `reloadKeys()`.
- An empty state: **"No devices paired. Flight Deck is not reachable from any other device."**

Add the tab to `PreferencesView` beside the existing ones, labelled **Devices**, SF Symbol `iphone.and.arrow.forward`.

- [ ] **Step 5: Own the service in the app**

In `FlightDeckApp`, construct `FleetService(store:preferences:armer:)` alongside the store and `try? service.start()`. Log a failure to bind rather than trapping — a Mac that cannot open a listener must still run every session it has:

```swift
    // A listener that will not bind is a mobile companion that does not work, which is very
    // different from an app that does not work. Log and carry on.
```

Under `-FlightDeckResetState`, do **not** start it: the UITest gate is hermetic, and a listener advertising during a GUI test would be a real service on the user's LAN.

- [ ] **Step 6: Run the tests and build**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

Run: `./scripts/build.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`. **Do not launch the built bundle** (AGENTS.md rule 2); visual verification is Task 11's manual checklist.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift \
        Sources/FlightDeck/Preferences/UI/PairingCodeView.swift \
        Sources/FlightDeck/Preferences/UI/PreferencesView.swift \
        Sources/FlightDeck/FlightDeckApp.swift \
        Tests/FlightDeckTests/PairingCodeImageTests.swift
git commit -m "feat: arm pairing from Preferences, and show what is attached"
```

---

### Task 6: Bonjour, and the permission the OS now asks for

The QR's endpoints are a snapshot of one moment; Bonjour is how the phone finds the Mac again after either of them has moved. Advertising it also crosses a line macOS draws: since macOS 15, a process that browses or advertises on the local network needs `NSLocalNetworkUsageDescription`, and without it the listener runs and is simply never found — silently.

**Files:**
- Modify: `Sources/FleetKit/FleetSocketServer.swift` (advertise on start)
- Modify: `project.yml` (Info.plist keys for the macOS app)
- Test: `Tests/FlightDeckTests/FleetAdvertisementTests.swift`

**Interfaces:**
- Produces: `FleetSocketServer.start(keys: [FleetDeviceKey], port: NWEndpoint.Port?, serviceName: String? = nil) throws -> NWEndpoint.Port` — the new parameter **must** carry a `nil` default so every existing call site in the spine plan still compiles; `public static let bonjourType = "_flightdeck._tcp"`.

- [ ] **Step 1: Write the failing test**

Bonjour resolution across a real network is manual (§10), but *advertising* and *browsing* within one machine is testable and catches the two mistakes that actually happen: a mistyped service type, and a listener that binds without advertising at all.

Create `Tests/FlightDeckTests/FleetAdvertisementTests.swift`:

```swift
import Network
import XCTest
import FleetKit

final class FleetAdvertisementTests: XCTestCase {
    private var server: FleetSocketServer?
    private var browser: NWBrowser?

    override func tearDown() {
        browser?.cancel()
        server?.stop()
        browser = nil
        server = nil
        super.tearDown()
    }

    func testTheServiceTypeIsTheOneTheClientBrowsesFor() {
        XCTAssertEqual(FleetSocketServer.bonjourType, "_flightdeck._tcp")
    }

    /// Finds our own advertisement on this machine. If this hangs on a first run, macOS is
    /// asking for local-network permission — that is the prompt Task 6 exists to make sure
    /// the app can even receive, and answering it once fixes the run.
    func testAStartedServerIsDiscoverable() async throws {
        let name = "flightdeck-test-\(UUID().uuidString.prefix(8))"
        let server = FleetSocketServer()
        server.onHello = { _, _ in [] }
        self.server = server
        _ = try await server.start(keys: [.mint()], port: nil, serviceName: name)

        let found = expectation(description: "browsed")
        let browser = NWBrowser(
            for: .bonjour(type: FleetSocketServer.bonjourType, domain: nil),
            using: .tcp
        )
        self.browser = browser
        browser.browseResultsChangedHandler = { results, _ in
            let names = results.compactMap { result -> String? in
                if case .service(let service, _, _, _) = result.endpoint { return service }
                return nil
            }
            if names.contains(name) { found.fulfill() }
        }
        browser.start(queue: .main)
        await fulfillment(of: [found], timeout: 20)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `start(keys:port:serviceName:)` does not exist.

- [ ] **Step 3: Advertise from the listener**

In `FleetSocketServer`:

```swift
    /// The service the phone browses for. One constant, referenced by both ends, because a
    /// service type that differs by a character between advertiser and browser fails by
    /// finding nothing — which is indistinguishable from being on the wrong network.
    public static let bonjourType = "_flightdeck._tcp"
```

and in `start`, before `listener.start`:

```swift
        if let serviceName {
            // Bonjour is a *rediscovery* mechanism, not the address of record: the pairing
            // code's endpoints get the phone connected the first time, and this is how it
            // finds the Mac again after either of them moved. The instance name is stable
            // per Mac so a phone can prefer the one it paired with.
            listener.service = NWListener.Service(name: serviceName, type: Self.bonjourType)
        }
```

`FleetService` already derives that name in Task 4 (`derivedServiceName`), and already puts it in the pairing payload — so this step is only `try await server.start(keys:port:serviceName: serviceName)` in `FleetService.start`.

`PreferencesStore.installSuffix` is the one new piece: four hex characters from a UUID minted on first read and stored in `Preferences`, so the advertised name is stable across relaunches. It follows the same Optional rule as every other field there.

- [ ] **Step 4: Declare the local-network usage**

In `project.yml`, under the `FlightDeck` target's `settings.base`:

```yaml
        # macOS 15+ gates local-network access behind a user prompt, and an app with no
        # usage description never gets to show it — the listener binds, advertises, and is
        # simply never discovered. The failure is silent, which is why this is here rather
        # than added when someone reports "my phone can't find my Mac".
        INFOPLIST_KEY_NSLocalNetworkUsageDescription: Flight Deck uses the local network to let your paired iPhone see your sessions.
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS. **On the first run macOS may prompt for local-network access** — that prompt is the feature working; approve it and re-run.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/FleetSocketServer.swift Sources/FlightDeck/Fleet/FleetService.swift \
        project.yml Tests/FlightDeckTests/FleetAdvertisementTests.swift
git commit -m "feat: advertise the fleet listener so a phone can find the Mac again"
```

---

### Task 7: The iOS app target

Scaffolding only — an app that launches, shows "Not paired", and links `FleetKit`. It exists as its own task because the build wiring is where the time goes (a second platform, an Info.plist with three privacy keys, a scheme that must not disturb the macOS one), and finding a signing or plist problem here is much cheaper than finding it inside the pairing task.

**Files:**
- Create: `Sources/FlightDeckMobile/FlightDeckMobileApp.swift`
- Create: `Sources/FlightDeckMobile/Info.plist` (generated by xcodegen from `project.yml`)
- Modify: `project.yml`
- Modify: `scripts/build-ios.sh`

**Interfaces:**
- Produces: target `FlightDeckMobile`, bundle id `dev.flightdeck.FlightDeckMobile`, linking `FleetKitiOS`.

- [ ] **Step 1: Add the target**

In `project.yml`:

```yaml
  FlightDeckMobile:
    type: application
    platform: iOS
    productName: Flight Deck
    sources: [Sources/FlightDeckMobile]
    dependencies:
      - target: FleetKitiOS
        embed: true
    settings:
      base:
        SWIFT_VERSION: "6.0"
        PRODUCT_MODULE_NAME: FlightDeckMobile
        PRODUCT_BUNDLE_IDENTIFIER: dev.flightdeck.FlightDeckMobile
        TARGETED_DEVICE_FAMILY: "1,2"
        # No DEVELOPMENT_TEAM: there is no provisioning profile on this machine, and pinning
        # a team would break the simulator compile check that is this target's only
        # automated verification. Set it when installing on hardware.
        CODE_SIGN_STYLE: Automatic
    info:
      path: Sources/FlightDeckMobile/Info.plist
      properties:
        CFBundleDisplayName: Flight Deck
        UILaunchScreen: {}
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationPortrait
        # The camera is for one thing only, and the string says so — a vague reason is what
        # gets an app rejected and, worse, what makes a user decline.
        NSCameraUsageDescription: Flight Deck scans the pairing code shown on your Mac.
        NSLocalNetworkUsageDescription: Flight Deck connects to your Mac over the local network to show your sessions.
        # Required to browse at all on iOS 14+. A missing entry here does not error — the
        # browser simply never returns a result, which reads as "my Mac isn't on the network".
        NSBonjourServices:
          - _flightdeck._tcp
```

- [ ] **Step 2: Write the app entry point**

Create `Sources/FlightDeckMobile/FlightDeckMobileApp.swift`:

```swift
import FleetKit
import SwiftUI

@main
struct FlightDeckMobileApp: App {
    var body: some Scene {
        WindowGroup {
            // Replaced in Task 10. Referencing FleetKit here on purpose: it is what makes
            // this scaffold prove the module actually links for iOS rather than merely that
            // a target was added.
            Text("Not paired — wire \(FleetKitVersion.wire)")
        }
    }
}
```

- [ ] **Step 3: Build both iOS targets**

Extend `scripts/build-ios.sh` to build the app as well as the framework:

```bash
for target in FleetKitiOS FlightDeckMobile; do
  xcodebuild -project FlightDeck.xcodeproj -target "$target" \
    -configuration Debug -sdk iphonesimulator \
    -derivedDataPath DerivedData build
done
```

- [ ] **Step 4: Verify**

Run: `./scripts/build-ios.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` twice.

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS — the macOS suite is untouched, which is the thing to confirm.

- [ ] **Step 5: Commit**

```bash
git add project.yml scripts/build-ios.sh Sources/FlightDeckMobile/FlightDeckMobileApp.swift
git commit -m "build: add the iOS companion app, compiled against the shared wire module"
```

---

### Task 8: What the phone remembers

The paired Mac, on the phone: its key, its name, its candidate endpoints, and the last sequence applied. All of it in one Keychain item, because the secret must not be in `UserDefaults` and splitting the record across two stores creates a state where the phone has half a pairing.

Two Keychain attributes are load-bearing and both are about the secret not spreading: **not synchronizable** (an iCloud-synced key would silently grant a second device access the user never paired) and **this-device-only** (so it does not travel in an encrypted backup restored onto different hardware).

**Files:**
- Create: `Sources/FleetKit/PairedMac.swift`
- Create: `Sources/FleetKit/PairedMacStore.swift`
- Test: `Tests/FlightDeckTests/PairedMacStoreTests.swift`

**Interfaces:**
- Consumes: `PairingPayload` (Task 1), `FleetDeviceKey`.
- Produces:
  - `public struct PairedMac: Codable, Equatable, Sendable { public var key: FleetDeviceKey; public var macName: String; public var serviceName: String; public var endpoints: [String]; public var lastSeq: Int }` with `public init(adopting: PairingPayload)`.
  - `public protocol PairedMacStoring: AnyObject { func load() -> PairedMac?; func save(_: PairedMac); func clear() }`
  - `public final class KeychainPairedMacStore: PairedMacStoring` and `public final class InMemoryPairedMacStore: PairedMacStoring`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/PairedMacStoreTests.swift`:

```swift
import XCTest
import FleetKit

final class PairedMacStoreTests: XCTestCase {
    private func payload() -> PairingPayload {
        PairingPayload(
            key: .mint(), macName: "Nate's MacBook Pro", serviceName: "flightdeck-a1b2",
            endpoints: ["192.168.1.20:53211", "127.0.0.1:53211"]
        )
    }

    func testAdoptingAPayloadKeepsEverythingNeededToReconnect() {
        let payload = payload()
        let mac = PairedMac(adopting: payload)
        XCTAssertEqual(mac.key, payload.key)
        XCTAssertEqual(mac.macName, payload.macName)
        XCTAssertEqual(mac.serviceName, payload.serviceName)
        XCTAssertEqual(mac.endpoints, payload.endpoints)
        XCTAssertEqual(mac.lastSeq, 0, "a freshly paired phone has applied nothing")
    }

    func testTheRecordRoundTripsThroughItsCodableForm() throws {
        var mac = PairedMac(adopting: payload())
        mac.lastSeq = 812
        let data = try JSONEncoder().encode(mac)
        XCTAssertEqual(try JSONDecoder().decode(PairedMac.self, from: data), mac)
    }

    func testSavingReplacesRatherThanAccumulating() {
        let store = InMemoryPairedMacStore()
        store.save(PairedMac(adopting: payload()))
        let second = PairedMac(adopting: payload())
        store.save(second)
        XCTAssertEqual(store.load(), second)
    }

    /// Unpairing on the phone must destroy the secret, not merely stop showing the fleet.
    func testClearingDestroysTheRecord() {
        let store = InMemoryPairedMacStore()
        store.save(PairedMac(adopting: payload()))
        store.clear()
        XCTAssertNil(store.load())
    }

    /// The two attributes that keep the secret on one device. Asserted against the query the
    /// store builds rather than against the Keychain itself, because a test bundle cannot
    /// reach the app's keychain — the live path is verified by hand in Task 11.
    func testTheKeychainQueryRefusesToSyncOrTravel() {
        let query = KeychainPairedMacStore.attributes(for: Data())
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'PairedMac' in scope`.

- [ ] **Step 3: Write the record**

Create `Sources/FleetKit/PairedMac.swift`:

```swift
import Foundation

/// The Mac this phone is paired to, as the phone remembers it.
public struct PairedMac: Codable, Equatable, Sendable {
    public var key: FleetDeviceKey
    public var macName: String
    public var serviceName: String
    /// Every address that has ever worked, best-first. Updated as the phone learns better
    /// ones — the endpoint from the QR is stale the moment the Mac changes network, and a
    /// phone that only remembered the original would need re-pairing to follow it.
    public var endpoints: [String]
    /// The highest sequence this phone has applied. Persisted so a relaunch resumes instead
    /// of re-downloading the fleet.
    public var lastSeq: Int

    public init(
        key: FleetDeviceKey, macName: String, serviceName: String,
        endpoints: [String], lastSeq: Int = 0
    ) {
        self.key = key
        self.macName = macName
        self.serviceName = serviceName
        self.endpoints = endpoints
        self.lastSeq = lastSeq
    }

    public init(adopting payload: PairingPayload) {
        self.init(
            key: payload.key, macName: payload.macName,
            serviceName: payload.serviceName, endpoints: payload.endpoints
        )
    }
}

extension FleetDeviceKey: Codable {
    enum CodingKeys: String, CodingKey { case slot, secret }
}
```

- [ ] **Step 4: Write the stores**

Create `Sources/FleetKit/PairedMacStore.swift` with the protocol, an in-memory implementation, and:

```swift
/// One Keychain item holding the whole pairing as JSON.
///
/// One item rather than a secret here and the metadata there: two stores can disagree, and
/// a phone holding a key with no endpoints — or endpoints with no key — is a state with no
/// recovery short of re-pairing.
public final class KeychainPairedMacStore: PairedMacStoring {
    private static let service = "dev.flightdeck.pairedMac"
    private static let account = "primary"

    public init() {}

    /// Exposed so the two attributes that matter are assertable without a keychain — see
    /// `PairedMacStoreTests`.
    public static func attributes(for data: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Never synced. An iCloud-synced pairing key would silently grant access to a
            // device the user never pointed at the QR, which is the one thing the whole
            // trust-on-first-use story rests on not happening.
            kSecAttrSynchronizable as String: false,
            // Survives a reboot without the phone being unlocked first (so a reconnect can
            // happen in the background) but never leaves this hardware in a backup.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }

    /// Delete-then-add rather than `SecItemUpdate`. An update against an item that is not
    /// there fails silently, leaving the phone believing it saved a pairing it did not — and
    /// the symptom is a relaunch that has forgotten the Mac for no visible reason.
    public func save(_ mac: PairedMac) {
        guard let data = try? JSONEncoder().encode(mac) else { return }
        SecItemDelete(Self.identityQuery as CFDictionary)
        SecItemAdd(Self.attributes(for: data) as CFDictionary, nil)
    }

    public func load() -> PairedMac? {
        var query = Self.identityQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    public func clear() {
        SecItemDelete(Self.identityQuery as CFDictionary)
    }

    /// The subset that identifies the item, for lookup and deletion. Deliberately without
    /// `kSecAttrAccessible`/`kSecAttrSynchronizable`: those are attributes of the stored
    /// item, and including them in a *query* narrows the match in ways that make a delete
    /// silently miss.
    private static var identityQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

Run: `./scripts/build-ios.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/PairedMac.swift Sources/FleetKit/PairedMacStore.swift \
        Tests/FlightDeckTests/PairedMacStoreTests.swift
git commit -m "feat: keep the phone's pairing in one keychain item that cannot sync"
```

---

### Task 9: Finding the Mac — the endpoint race

The phone has several guesses about where the Mac is and no way to rank them: the address from the QR, whichever addresses have worked since, and whatever Bonjour reports right now. **Racing them in parallel is the design** (§3) — the key identifies the Mac, so the first candidate to complete a handshake is by definition the right one, and there is nothing to choose between them beforehand.

This lives in `FleetKit` and is therefore tested on macOS, against real listeners. That is worth insisting on: connection management is where a mobile client's bugs live, and it is the part that would otherwise only ever be exercised by hand on a device.

**Files:**
- Create: `Sources/FleetKit/FleetConnector.swift`
- Test: `Tests/FlightDeckTests/FleetConnectorTests.swift`

**Interfaces:**
- Consumes: `FleetClient`, `PairedMac`, `FleetSnapshot`, `ServerFrame`.
- Produces: `public final class FleetConnector` — `init(mac:store:browse:)`, `start()`, `stop()`, `send(_: FleetCommand)`, `public enum State { case idle, searching, connected(macName: String), lost(retryingIn: TimeInterval) }`, `var onState: ((State) -> Void)?`, `var onFleet: ((FleetSnapshot) -> Void)?`, `var retryDelays: [TimeInterval]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetConnectorTests.swift`:

```swift
import Network
import XCTest
import FleetKit

final class FleetConnectorTests: XCTestCase {
    private var servers: [FleetSocketServer] = []
    private var connector: FleetConnector?

    override func tearDown() {
        connector?.stop()
        servers.forEach { $0.stop() }
        servers = []
        connector = nil
        super.tearDown()
    }

    private let sessionID = UUID()

    private func fleet(_ title: String) -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "fd", path: "/w/fd", sessions: [
                WireSession(id: sessionID, title: title, agent: "claude")
            ])
        ])
    }

    @discardableResult
    private func startServer(
        key: FleetDeviceKey, fleet: FleetSnapshot
    ) async throws -> NWEndpoint.Port {
        let server = FleetSocketServer()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onCommand = { _, cid, _ in .ack(cid: cid) }
        servers.append(server)
        return try await server.start(keys: [key], port: nil)
    }

    private func connector(
        key: FleetDeviceKey, endpoints: [String], store: PairedMacStoring = InMemoryPairedMacStore()
    ) -> FleetConnector {
        let mac = PairedMac(
            key: key, macName: "Mac", serviceName: "none-\(UUID().uuidString)",
            endpoints: endpoints
        )
        store.save(mac)
        // Bonjour is disabled in these tests — the browser is injected, and here it never
        // reports anything, so what is under test is purely the remembered-endpoint race.
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        return connector
    }

    func testTheFirstReachableCandidateWins() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))

        let connected = expectation(description: "connected")
        var seen: FleetSnapshot?
        // Two dead candidates ahead of the live one — the ordinary case for a phone that
        // has moved networks, and the reason this is a race rather than a fallback chain.
        let connector = connector(key: key, endpoints: [
            "192.0.2.1:9", "198.51.100.7:9", "127.0.0.1:\(port.rawValue)"
        ])
        connector.onFleet = { seen = $0; connected.fulfill() }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        XCTAssertEqual(seen, fleet("one"))
    }

    func testTheStateReachesConnectedAndNamesTheMac() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let connected = expectation(description: "state")
        let connector = connector(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"])
        connector.onState = { if case .connected("Mac") = $0 { connected.fulfill() } }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
    }

    /// The endpoint that worked is remembered first, so the next launch connects on its
    /// first attempt instead of racing three dead addresses again.
    func testTheWinningEndpointIsPromotedForNextTime() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let store = InMemoryPairedMacStore()
        let winner = "127.0.0.1:\(port.rawValue)"
        let connected = expectation(description: "connected")
        let connector = connector(key: key, endpoints: ["192.0.2.1:9", winner], store: store)
        connector.onFleet = { _ in connected.fulfill() }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        XCTAssertEqual(store.load()?.endpoints.first, winner)
    }

    func testTheAppliedSequenceIsRememberedSoARelaunchResumes() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let store = InMemoryPairedMacStore()
        let connected = expectation(description: "connected")
        let connector = connector(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store)
        connector.onFleet = { _ in connected.fulfill() }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        XCTAssertEqual(store.load()?.lastSeq, 1)
    }

    func testLiveEventsAreAppliedToTheHeldSnapshot() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let renamed = expectation(description: "renamed")
        let connector = connector(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"])
        connector.onFleet = { snapshot in
            if snapshot.projects.first?.sessions.first?.title == "two" { renamed.fulfill() }
        }
        connector.start()
        // Give the race a moment to settle before broadcasting; the server holds nothing
        // for a client that has not attached.
        let attached = expectation(description: "attached")
        servers[0].onAttachedCountChanged = { if $0 == 1 { attached.fulfill() } }
        await fulfillment(of: [attached], timeout: 20)
        servers[0].broadcast(.event(seq: 2, .renamed(id: sessionID, title: "two", origin: .user)))
        await fulfillment(of: [renamed], timeout: 20)
    }

    /// A Mac that goes away must produce a visible "lost" state, not a fleet frozen at
    /// whatever it last said. A stale fleet that looks live is the single most misleading
    /// thing this app could show.
    func testLosingTheMacIsReportedRatherThanLeavingAStaleFleetLookingLive() async throws {
        let key = FleetDeviceKey.mint()
        let port = try await startServer(key: key, fleet: fleet("one"))
        let connected = expectation(description: "connected")
        let lost = expectation(description: "lost")
        let connector = connector(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"])
        connector.retryDelays = [0.2]
        connector.onState = { state in
            switch state {
            case .connected: connected.fulfill()
            case .lost: lost.fulfill()
            default: break
            }
        }
        connector.start()
        await fulfillment(of: [connected], timeout: 20)
        servers[0].stop()
        await fulfillment(of: [lost], timeout: 20)
    }

    func testNoReachableCandidateEndsInLostRatherThanSearchingForever() async throws {
        let connector = connector(key: .mint(), endpoints: ["192.0.2.1:9"])
        connector.retryDelays = [0.2]
        let lost = expectation(description: "lost")
        connector.onState = { if case .lost = $0 { lost.fulfill() } }
        connector.start()
        await fulfillment(of: [lost], timeout: 30)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FleetConnector' in scope`.

- [ ] **Step 3: Write the connector**

Create `Sources/FleetKit/FleetConnector.swift`:

```swift
import Foundation
import Network

/// Finds the paired Mac and keeps a fleet in sync with it.
public final class FleetConnector {
    public enum State: Equatable {
        case idle
        case searching
        case connected(macName: String)
        case lost(retryingIn: TimeInterval)
    }

    public var onState: ((State) -> Void)?
    public var onFleet: ((FleetSnapshot) -> Void)?
    /// Backoff between races; the last value repeats. Settable so tests do not wait it out.
    public var retryDelays: [TimeInterval] = [1, 2, 5, 15, 30]
    /// How long a race may run before it is abandoned and retried. Well short of a TCP
    /// connect timeout on purpose — a stale candidate must not hold the whole race open for
    /// a minute when a live one might appear on the next attempt.
    public var raceTimeout: TimeInterval = 8

    private struct Candidate {
        let description: String
        let endpoint: NWEndpoint
        /// Whether this candidate belongs in the remembered list. A Bonjour result does not:
        /// it is rediscovered every time and has no stable text form worth storing.
        let isRemembered: Bool
    }

    private var mac: PairedMac
    private let store: any PairedMacStoring
    private let browse: Bool
    private let queue: DispatchQueue

    private var racers: [String: FleetClient] = [:]
    private var winner: FleetClient?
    private var browser: NWBrowser?
    private var fleet = FleetSnapshot.empty
    private var attempt = 0
    private var running = false

    public init(
        mac: PairedMac, store: any PairedMacStoring,
        browse: Bool = true, queue: DispatchQueue = .main
    ) {
        self.mac = mac
        self.store = store
        self.browse = browse
        self.queue = queue
    }

    public func start() {
        running = true
        attempt = 0
        race()
    }

    public func stop() {
        running = false
        teardown()
        report(.idle)
    }

    /// `ack` means dispatched, not done — the effect arrives as a northbound event.
    public func send(_ command: FleetCommand) {
        _ = winner?.send(command)
    }

    // MARK: The race

    /// Parallel, not sequential. The key identifies the Mac, so the first candidate to
    /// complete a handshake is by definition the right one and there is nothing to rank
    /// beforehand — while trying them in order means a phone that has changed networks waits
    /// out a TCP timeout per stale address before reaching the one that works.
    private func race() {
        guard running else { return }
        teardown()
        report(.searching)
        for candidate in remembered() { dial(candidate) }
        if browse { startBrowsing() }
        queue.asyncAfter(deadline: .now() + raceTimeout) { [weak self] in
            guard let self, self.running, self.winner == nil else { return }
            self.scheduleRetry()
        }
    }

    private func remembered() -> [Candidate] {
        mac.endpoints.compactMap { text in
            Self.endpoint(from: text).map {
                Candidate(description: text, endpoint: $0, isRemembered: true)
            }
        }
    }

    private func dial(_ candidate: Candidate) {
        guard running, winner == nil, racers[candidate.description] == nil else { return }
        let client = FleetClient(key: mac.key, queue: queue)
        racers[candidate.description] = client
        client.onFrame = { [weak self] frame in
            self?.accept(frame, from: candidate, client: client)
        }
        client.onDisconnect = { [weak self] _ in
            self?.noteDisconnect(candidate, client: client)
        }
        client.connect(to: candidate.endpoint, lastSeq: mac.lastSeq)
    }

    private func startBrowsing() {
        let browser = NWBrowser(
            for: .bonjour(type: FleetSocketServer.bonjourType, domain: nil), using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      // Only the Mac we paired with. Another Flight Deck on the same LAN
                      // would refuse our key anyway, but dialling it is noise in the race.
                      name == self.mac.serviceName
                else { continue }
                self.dial(Candidate(
                    description: "bonjour:\(name)", endpoint: result.endpoint,
                    isRemembered: false
                ))
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func accept(_ frame: ServerFrame, from candidate: Candidate, client: FleetClient) {
        if winner == nil {
            winner = client
            for (description, other) in racers where other !== client {
                other.disconnect()
                racers.removeValue(forKey: description)
            }
            browser?.cancel()
            browser = nil
            attempt = 0
            if candidate.isRemembered { promote(candidate.description) }
            report(.connected(macName: mac.macName))
        }
        guard client === winner else { return }
        apply(frame)
    }

    private func apply(_ frame: ServerFrame) {
        switch frame {
        case .snapshot(let seq, let snapshot, _):
            fleet = snapshot
            advance(to: seq)
        case .event(let seq, let event):
            fleet.apply(event)
            advance(to: seq)
        case .ack, .err:
            // Command replies change no fleet state; the effect arrives as its own event.
            return
        }
        onFleet?(fleet)
    }

    /// `lastSeq` advances only on frames actually applied, and is persisted immediately.
    /// Advancing it optimistically would let a phone claim to have applied an event it
    /// dropped, and the resume path would then never send it again — a fleet permanently
    /// missing one change, with nothing to indicate it.
    ///
    /// Note a gap the spine's review left here deliberately: when a resuming client is already
    /// current, the server answers `.replay([])` and therefore sends *nothing*. The connector
    /// cannot distinguish "you are up to date" from "your hello was ignored", so it must treat
    /// reaching `.ready` and sending `hello` as the success signal — not the arrival of a
    /// frame. Do not add a receive-timeout that assumes a frame always follows `hello`.
    private func advance(to seq: Int) {
        guard seq > mac.lastSeq else { return }
        mac.lastSeq = seq
        store.save(mac)
    }

    /// The address that worked goes to the front, so the next launch connects on its first
    /// attempt instead of racing the same dead candidates again.
    private func promote(_ description: String) {
        var endpoints = mac.endpoints.filter { $0 != description }
        endpoints.insert(description, at: 0)
        mac.endpoints = endpoints
        store.save(mac)
    }

    private func noteDisconnect(_ candidate: Candidate, client: FleetClient) {
        racers.removeValue(forKey: candidate.description)
        guard client === winner else {
            // A losing racer failing is expected and uninteresting — unless every candidate
            // has now failed with nothing left to discover, which is "cannot find the Mac".
            if winner == nil, racers.isEmpty, browser == nil { scheduleRetry() }
            return
        }
        winner = nil
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard running else { return }
        teardown()
        let delay = retryDelays[min(attempt, retryDelays.count - 1)]
        attempt += 1
        report(.lost(retryingIn: delay))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.race() }
    }

    private func teardown() {
        for client in racers.values { client.disconnect() }
        racers.removeAll()
        winner?.disconnect()
        winner = nil
        browser?.cancel()
        browser = nil
    }

    private func report(_ state: State) { onState?(state) }

    private static func endpoint(from text: String) -> NWEndpoint? {
        guard
            let colon = text.lastIndex(of: ":"),
            let port = NWEndpoint.Port(String(text[text.index(after: colon)...])),
            !text[..<colon].isEmpty
        else { return nil }
        return .hostPort(host: NWEndpoint.Host(String(text[..<colon])), port: port)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS. These are network tests with real timeouts — expect this file to take ~30–60s.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/FleetConnector.swift Tests/FlightDeckTests/FleetConnectorTests.swift
git commit -m "feat: find the paired Mac by racing every address at once"
```

---

### Task 10: The phone's three screens

Pairing, the fleet list, and a not-paired empty state. The list renders **in the terminal's own idiom** — monospace, the terminal palette, the sidebar's status glyphs — rather than as a generic iOS list, because the phone is a window onto the same fleet and a different visual language would make the two look like different products.

Two constraints from the spec that are easy to get wrong:

- **Key everything on the session's tab `id`, never `conversationId`** — the latter is not stable across a re-pin and, for codex, differs from the tab id from birth.
- **A disconnected fleet must be visibly stale.** `FleetConnector.State.lost` dims the list and shows when it was last live; it never silently keeps rendering.

**Files:**
- Create: `Sources/FlightDeckMobile/FleetModel.swift`
- Create: `Sources/FlightDeckMobile/PairingScreen.swift`
- Create: `Sources/FlightDeckMobile/FleetListScreen.swift`
- Create: `Sources/FlightDeckMobile/SessionStatusGlyph.swift`
- Modify: `Sources/FlightDeckMobile/FlightDeckMobileApp.swift`

**Interfaces:**
- Consumes: `FleetConnector`, `PairedMac`, `KeychainPairedMacStore`, `PairingPayload`, `FleetSnapshot`.
- Produces: `@MainActor @Observable final class FleetModel` — `var mac: PairedMac?`, `var fleet: FleetSnapshot`, `var state: FleetConnector.State`, `func adopt(code: String) throws`, `func unpair()`, `func markRead(_ id: UUID)`.

- [ ] **Step 1: Write the model**

Create `Sources/FlightDeckMobile/FleetModel.swift`:

```swift
import FleetKit
import Foundation
import Observation

/// Everything both screens talk to, and nothing more.
///
/// Deliberately thin: it owns a store and a connector, both of which are already tested in
/// `FleetKit` against real sockets on macOS. The iOS target has no test host on this
/// machine, so anything here that would be worth testing belongs in `FleetKit` instead —
/// keeping this file glue is what keeps that true.
@MainActor
@Observable
final class FleetModel {
    private(set) var mac: PairedMac?
    private(set) var fleet = FleetSnapshot.empty
    private(set) var state = FleetConnector.State.idle

    @ObservationIgnored private let store: any PairedMacStoring
    @ObservationIgnored private var connector: FleetConnector?

    init(store: any PairedMacStoring = KeychainPairedMacStore()) {
        self.store = store
        self.mac = store.load()
        if mac != nil { connect() }
    }

    /// Throws `PairingPayloadError`, which the pairing screen turns into copy.
    func adopt(code: String) throws {
        let payload = try PairingPayload(decoding: code)
        let mac = PairedMac(adopting: payload)
        store.save(mac)
        self.mac = mac
        connect()
    }

    func unpair() {
        connector?.stop()
        connector = nil
        // Destroying the secret, not just hiding the fleet: a phone that "unpaired" while
        // keeping a working key is a device the user believes is revoked and is not.
        store.clear()
        mac = nil
        fleet = .empty
        state = .idle
    }

    func markRead(_ id: UUID) { connector?.send(.markRead(id: id)) }

    func reconnect() {
        connector?.stop()
        connect()
    }

    private func connect() {
        guard let mac else { return }
        let connector = FleetConnector(mac: mac, store: store)
        connector.onFleet = { [weak self] in self?.fleet = $0 }
        connector.onState = { [weak self] in self?.state = $0 }
        self.connector = connector
        connector.start()
    }

    var isLive: Bool {
        if case .connected = state { return true }
        return false
    }

    var macName: String { mac?.macName ?? "your Mac" }
}
```

- [ ] **Step 2: Write the pairing screen**

`PairingScreen` offers two ways in, and the second is not optional: **a simulator has no camera**, and a manual field is the only way this screen can be exercised without hardware.

Create `Sources/FlightDeckMobile/PairingScreen.swift`:

```swift
import AVFoundation
import FleetKit
import SwiftUI

struct PairingScreen: View {
    let model: FleetModel

    @State private var typed = ""
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 24) {
            Text("Pair with your Mac")
                .font(.title2.weight(.semibold))
            Text("Open Flight Deck on your Mac, then Settings → Devices → Pair a Device.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            QRScannerView { adopt($0) }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            DisclosureGroup("Can't scan? Type the code instead") {
                TextField("flightdeck1:…", text: $typed, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
                Button("Pair") { adopt(typed) }
                    .disabled(typed.isEmpty)
            }

            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }

    private func adopt(_ code: String) {
        do {
            try model.adopt(code: code)
            failure = nil
        } catch let error as PairingPayloadError {
            failure = Self.message(for: error)
        } catch {
            failure = "That code could not be used."
        }
    }

    /// Each failure says what to do next. "Invalid code" for all three would leave a user
    /// rescanning a code that will never work.
    static func message(for error: PairingPayloadError) -> String {
        switch error {
        case .notAPairingCode:
            return "That isn't a Flight Deck pairing code."
        case .unsupportedVersion:
            return "This code is from a newer version of Flight Deck. Update the app on your phone."
        case .malformed:
            return "That code is damaged. Show a new one on your Mac."
        }
    }
}
```

`QRScannerView` is a `UIViewRepresentable` over `AVCaptureSession` with an `AVCaptureMetadataOutput` restricted to `[.qr]`, calling its closure once per distinct string. When authorization is denied it renders, instead of a preview:

**"Flight Deck needs the camera to scan the code on your Mac. You can enter the code by hand instead."**

— never a dead end, because the manual field below it still works.

- [ ] **Step 3: Write the fleet list**

Create `Sources/FlightDeckMobile/SessionStatusGlyph.swift` and `Sources/FlightDeckMobile/FleetListScreen.swift`.

**Read `Sources/FlightDeck/SessionStatusIcon.swift` before writing the glyph** and match its meanings exactly — two devices disagreeing about what a glyph means is worse than the phone having no glyph at all.

```swift
import FleetKit
import SwiftUI

/// The sidebar's status vocabulary, on the phone.
///
/// `nil` activity renders **nothing**, which is not the same as idle: no glyph means no
/// agent process is registered for that tab, while a dot means one is running and quiet.
/// Collapsing the two would make every dead tab look alive.
struct SessionStatusGlyph: View {
    let session: WireSession

    var body: some View {
        switch session.activity {
        case nil:
            Color.clear.frame(width: 14, height: 14)
        case "idle":
            Circle().fill(.secondary).frame(width: 6, height: 6).frame(width: 14)
        case "busy":
            HStack(spacing: 2) {
                ProgressView().controlSize(.mini)
                if session.subagentCount > 0 {
                    Text("\(session.subagentCount)").font(.caption2.monospacedDigit())
                }
            }
        case "shell":
            Image(systemName: "terminal.fill").font(.caption)
        case "waiting":
            Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(.orange)
        default:
            // An activity this build does not know about still renders as *something*,
            // for the same reason `WireSession.agent` is a String: the Mac may be newer.
            Image(systemName: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

```swift
import FleetKit
import SwiftUI

struct FleetListScreen: View {
    let model: FleetModel
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                if !model.isLive { staleBanner }
                ForEach(model.fleet.projects) { project in
                    Section {
                        // Keyed on the session's tab id, never its conversation id — the
                        // latter is not stable across a re-pin and, for codex, differs from
                        // the tab id from birth.
                        ForEach(project.sessions) { session in
                            row(session)
                                .onTapGesture { model.markRead(session.id) }
                        }
                    } header: {
                        HStack {
                            Text(project.name).font(.footnote.monospaced())
                            Spacer()
                            Text("\(project.sessions.count)").font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .opacity(model.isLive ? 1 : 0.5)
            .refreshable { model.reconnect() }
            .navigationTitle(model.macName)
            .toolbar {
                Button("Unpair", role: .destructive) { confirmingUnpair = true }
            }
            .confirmationDialog(
                "Unpair from \(model.macName)? This phone will stop receiving your sessions.",
                isPresented: $confirmingUnpair, titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { model.unpair() }
            }
        }
    }

    private func row(_ session: WireSession) -> some View {
        HStack(spacing: 8) {
            SessionStatusGlyph(session: session)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                if let waitingFor = session.waitingFor {
                    Text(waitingFor).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if session.isUnread {
                Circle().fill(.tint).frame(width: 8, height: 8)
            }
        }
    }

    /// A disconnected fleet must look disconnected. A list that keeps rendering the last
    /// thing it heard, indistinguishable from a live one, is the single most misleading
    /// thing this app could show.
    private var staleBanner: some View {
        Label(
            "Not connected to \(model.macName) — showing what it last said.",
            systemImage: "wifi.slash"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
```

- [ ] **Step 4: Route between them**

Replace the body of `Sources/FlightDeckMobile/FlightDeckMobileApp.swift`:

```swift
import SwiftUI

@main
struct FlightDeckMobileApp: App {
    @State private var model = FleetModel()

    var body: some Scene {
        WindowGroup {
            if model.mac == nil {
                PairingScreen(model: model)
            } else {
                FleetListScreen(model: model)
            }
        }
    }
}
```

- [ ] **Step 5: Verify**

Run: `./scripts/build-ios.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeckMobile/
git commit -m "feat: show the fleet on the phone in the terminal's own idiom"
```

---

### Task 11: Manual verification and documentation

Everything automatable is automated; what is left genuinely needs two devices on a network (§10). This task writes the checklist down and hands it over — **do not attempt to run it.** Installing on hardware needs a development team and a provisioning profile that this machine does not have, and it is the user's decision when to set that up.

**Files:**
- Create: `docs/MOBILE.md`
- Modify: `docs/ARCHITECTURE.md`, `AGENTS.md`, `docs/FOLLOWUPS.md`, `README.md`

- [ ] **Step 1: Write `docs/MOBILE.md`**

Covering, in the house voice:

- **Running it at all**: install an iOS Simulator runtime *or* set `DEVELOPMENT_TEAM` and a bundle id you own, then `xcodebuild -target FlightDeckMobile -sdk iphoneos`. Say plainly that neither is configured in the repo and why (no profile on the build machine; a hard-coded team is a merge conflict waiting to happen).
- **The manual checklist**, each item stated as an observable outcome:
  1. Pair by scanning; the Mac's Devices tab shows the phone as Connected.
  2. Pair by typing the code; same outcome. (The simulator path.)
  3. Rename a session on the Mac — the phone's row changes within a second.
  4. Let a session finish while looking elsewhere — the unread dot appears on both.
  5. Tap the row on the phone — the dot clears on the Mac. Unread is one fleet-wide fact (§8).
  6. Close a project on the Mac — its section leaves the phone.
  7. Put the phone on cellular, then back on Wi-Fi — it reconnects without re-pairing.
  8. Quit Flight Deck — the phone shows "Not connected", dimmed, not a frozen live-looking fleet.
  9. Leave the phone off the network for ten minutes, then return — it resumes rather than re-downloading (check the Mac's log for a replay rather than a snapshot).
  10. Revoke the device on the Mac — the phone disconnects and cannot reconnect.
  11. Let a pairing code expire unscanned, then scan it — it is refused.
- **The trust model**, restated in one paragraph for whoever reads this doc first: a QR on an unlocked Mac, a 2-minute window, single use, and a paired phone is fully privileged until revoked.

- [ ] **Step 2: Update the other docs**

- `docs/ARCHITECTURE.md`: extend the fleet section from the spine plan with pairing, Bonjour, and the phone.
- `AGENTS.md`: add `Sources/FlightDeckMobile/` to the Layout table and `./scripts/build-ios.sh` to Commands, with the one-line reason it exists.
- `README.md`: one short paragraph under the existing status text — it runs, it is early, it needs your own signing to install.
- `docs/FOLLOWUPS.md`: a dated section recording, honestly:
  - **Paired secrets live in `UserDefaults` on the Mac** (Task 3), which is not Keychain-grade, and what that does and does not expose.
  - **A key change restarts the listener**, dropping attached clients for a reconnect.
  - **Bonjour resolution, roaming and off-LAN reachability are manually verified only** — there is no automated coverage and there cannot be on one machine.
  - **No relay**, so off-LAN needs a VPN. Designed for as a further candidate endpoint (§3), not built.
  - Whichever fallbacks were taken in spine Task 6 or this plan's Task 4, if any.

- [ ] **Step 3: Final verification**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

Run: `./scripts/build.sh 2>&1 | tail -5` and `./scripts/build-ios.sh 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add docs/MOBILE.md docs/ARCHITECTURE.md AGENTS.md docs/FOLLOWUPS.md README.md
git commit -m "docs: describe pairing, the phone, and what only a device can prove"
```

---

## Done when

- `./scripts/test-unit.sh` passes, including the pairing flow tests: a device pairs on its first handshake inside an armed window, a revoked device cannot reconnect, an unclaimed code expires out of the accepted keys, and a connector finds its Mac by racing dead endpoints alongside a live one.
- `./scripts/build-ios.sh` builds `FleetKitiOS` and `FlightDeckMobile`.
- The Mac's Preferences has a Devices tab that arms pairing, lists paired devices, shows which are connected, and revokes.
- `docs/MOBILE.md` carries the eleven-item manual checklist, unrun, for the user to work through when they set up signing.

## Not in this plan

- **The timeline** (slice 1b) — opening a session and reading it. Needs its own spec section's `TimelineItem` vocabulary and both agents' mappings.
- **Replying, interrupting, and answering prompts** (slice 2). §9 of the spec designs the prompt bridge; nothing here builds it.
- **APNs** (slice 3). The phone only learns about a blocked session while it is attached.
- **"Only the device not currently showing that session notifies"** (§8). The suppression rule
  needs the phone to report *which session it is looking at*, and in slice 1a there is no
  session screen to look at — the phone shows a list. It becomes buildable with the timeline
  (1b) and belongs with the notification work (slice 3); until then the Mac notifies as it
  always has, and the phone does not notify at all.
- **A relay** (§12). Off-LAN means a VPN, as a further candidate endpoint.
