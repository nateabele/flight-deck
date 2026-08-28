# Off-LAN endpoint discovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a QR code carry an address a phone can reach from off the LAN, and give the phone a way to refresh that list after it connects.

**Architecture:** Three independent pieces. The Mac ranks its own addresses using signals macOS supplies directly (`SCDynamicStore`'s `PrimaryInterface` for the LAN, `IFF_POINTOPOINT` for the VPN) instead of raw `getifaddrs` order. The pairing payload goes to v3 and packs up to two of them instead of exactly one. A new `mac.endpoints` request lets a connected client re-ask, answered from the same ranking.

**Tech Stack:** Swift 6, XCTest, Network.framework, SystemConfiguration, CoreImage (QR sizing assertions only).

**Spec:** `docs/superpowers/specs/2026-08-25-off-lan-endpoint-discovery.md`

**Branch:** `fleet-pairing` (master has none of this subsystem). Work in the existing worktree at `.claude/worktrees/fleet-pairing`.

## Global Constraints

- **`FleetKit` never imports AppKit or SystemConfiguration.** The same sources compile as `FleetKitiOS`. `LocalEndpoints.swift` is in `Sources/FlightDeck/Fleet/`, which is Mac-only — that is where SystemConfiguration goes.
- **A reply frame must never carry a `seq`.** `ServerFrame.macEndpoints` gets no `seq`, for the reason `page` and `newSessionOptions` both state.
- **`ServerFrame.Tag` values are undotted; `FleetEventTag` values are dotted.** The new tag is `endpoints`. Never dotted.
- **New pending table ⇒ `drainPending()` in the same commit.** Otherwise a client whose socket dies waits forever.
- **Endpoint cap in the payload is 2.** Measured, not chosen: 2 keeps the QR at extent 47, identical to v2; 3 pushes it to 51 and breaks `testThePackedPayloadProducesAMateriallySmallerQR` at its 0.75 threshold. **Do not raise the cap and do not relax that threshold.**
- **Reply cap is 4, loopback dropped.** Every stored candidate becomes a real parallel connection attempt in `race()`.
- Run `./scripts/test-unit.sh` for macOS/FleetKit, `./scripts/test-ios.sh` for phone-side. Do not run the GUI smoke tests.

---

### Task 1: Rank the Mac's addresses

**Files:**
- Modify: `Sources/FlightDeck/Fleet/LocalEndpoints.swift` (whole file)
- Test: `Tests/FlightDeckTests/LocalEndpointsTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `LocalEndpoints.Interface` (`name: String`, `address: String`, `isPointToPoint: Bool`, `isBroadcast: Bool`, `isLoopback: Bool`); `LocalEndpoints.ranked(_ interfaces: [Interface], primary: String?, port: UInt16) -> [String]`; `LocalEndpoints.current(port: UInt16) -> [String]`; `LocalEndpoints.routable(port: UInt16, limit: Int) -> [String]`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/LocalEndpointsTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class LocalEndpointsTests: XCTestCase {
    /// The exact interface shape of the Mac that could not pair, 2026-08-25.
    private func affectedMac() -> [LocalEndpoints.Interface] {
        [
            .init(name: "lo0", address: "127.0.0.1", isPointToPoint: false, isBroadcast: false, isLoopback: true),
            .init(name: "en0", address: "192.168.1.109", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "bridge100", address: "192.168.139.3", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "bridge101", address: "192.168.117.0", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "bridge102", address: "192.168.97.0", isPointToPoint: false, isBroadcast: true, isLoopback: false),
            .init(name: "utun7", address: "100.108.99.35", isPointToPoint: true, isBroadcast: false, isLoopback: false),
        ]
    }

    /// The defect, as an assertion: the tailnet address must come first and the Wi-Fi address
    /// second, so the two that fit in a QR are the two that can actually carry a connection.
    func testTheTailnetAddressOutranksWiFiAndBothBeatTheBridges() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "en0", port: 58625)
        XCTAssertEqual(
            Array(ranked.prefix(2)),
            ["100.108.99.35:58625", "192.168.1.109:58625"]
        )
    }

    func testLoopbackRanksLast() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "en0", port: 58625)
        XCTAssertEqual(ranked.last, "127.0.0.1:58625")
    }

    /// With an exit node the primary interface IS the tunnel, so the rule that fills the LAN
    /// slot names an interface the VPN rule already took. Both slots must still be populated.
    func testAnExitNodeStillLeavesALANCandidate() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "utun7", port: 58625)
        XCTAssertEqual(ranked.first, "100.108.99.35:58625")
        XCTAssertEqual(ranked.dropFirst().first, "192.168.1.109:58625")
    }

    func testWithNoVPNThePrimaryInterfaceComesFirst() {
        let withoutVPN = affectedMac().filter { $0.name != "utun7" }
        let ranked = LocalEndpoints.ranked(withoutVPN, primary: "en0", port: 58625)
        XCTAssertEqual(ranked.first, "192.168.1.109:58625")
    }

    /// No primary is a real state — no network at all — and must not trap.
    func testNoPrimaryInterfaceStillProducesAList() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: nil, port: 58625)
        XCTAssertEqual(ranked.first, "100.108.99.35:58625")
        XCTAssertEqual(ranked.count, 6)
    }

    /// Equal ranks must keep enumeration order. `Array.sorted` is NOT stable, so this fails
    /// against the obvious one-key implementation.
    func testInterfacesOfEqualRankKeepTheirEnumerationOrder() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "en0", port: 58625)
        XCTAssertEqual(
            ranked,
            ["100.108.99.35:58625", "192.168.1.109:58625", "192.168.139.3:58625",
             "192.168.117.0:58625", "192.168.97.0:58625", "127.0.0.1:58625"]
        )
    }

    /// 100.64/10, not "anything starting 100." — 100.128.0.1 is ordinary public space.
    func testOnlyTheCGNATRangeCountsAsATailnetAddress() {
        XCTAssertTrue(LocalEndpoints.isCGNAT("100.64.0.1"))
        XCTAssertTrue(LocalEndpoints.isCGNAT("100.127.255.254"))
        XCTAssertFalse(LocalEndpoints.isCGNAT("100.63.255.255"))
        XCTAssertFalse(LocalEndpoints.isCGNAT("100.128.0.1"))
        XCTAssertFalse(LocalEndpoints.isCGNAT("192.168.1.1"))
    }

    /// What the `mac.endpoints` reply sends: ranked, capped, and loopback removed — a phone
    /// dialling 127.0.0.1 is spending one of its parallel race slots on itself.
    func testRoutableDropsLoopbackAndCaps() {
        let ranked = LocalEndpoints.ranked(affectedMac(), primary: "en0", port: 58625)
        let routable = LocalEndpoints.routable(from: ranked, limit: 4)
        XCTAssertEqual(routable.count, 4)
        XCTAssertFalse(routable.contains("127.0.0.1:58625"))
        XCTAssertEqual(routable.first, "100.108.99.35:58625")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `LocalEndpoints.Interface`, `ranked`, `isCGNAT` and `routable` do not exist.

- [ ] **Step 3: Rewrite `LocalEndpoints.swift`**

Replace the whole file:

```swift
import Foundation
import SystemConfiguration

/// Every address this Mac can currently be reached on, ranked best-first, as `host:port`
/// candidates for the pairing code and for the `mac.endpoints` reply.
///
/// These are candidates, not an address. The key identifies the Mac (§3); by the time the
/// phone has left the room every one of these may be wrong, which is why the phone races
/// them rather than trusting one — and why `FleetRequest.macEndpoints` exists to ask again.
///
/// **Ranked rather than enumerated**, because only the first two reach a QR and kernel order
/// put a VM bridge ahead of the tailnet address. The two signals used are supplied by macOS
/// directly, so no interface name is ever matched: `SCDynamicStore`'s `PrimaryInterface`
/// names the real LAN interface (the one carrying the default route), and `IFF_POINTOPOINT`
/// names a tunnel. On the Mac this was written for, that separates `en0` from three
/// `bridge*` interfaces belonging to Internet Sharing and a VM, and finds `utun7` without
/// knowing what Tailscale is called.
///
/// Loopback is enumerated and ranked last. It is NOT here for the loopback tests — every one
/// of those builds its own endpoint array (`FleetConnectorTests`, `PairedMacStoreTests`) or
/// calls `FleetService.loopbackEndpoint()`. It is here so a Mac with no network at all still
/// produces a list rather than an empty one, and it costs a real phone nothing because the
/// cap drops it long before the wire.
enum LocalEndpoints {
    /// One interface as the ranking sees it.
    ///
    /// A plain struct rather than `ifaddrs`, so `ranked` is a pure function that can be
    /// tested against a machine's exact interface shape without that machine.
    struct Interface: Equatable {
        var name: String
        var address: String
        var isPointToPoint: Bool
        var isBroadcast: Bool
        var isLoopback: Bool
    }

    /// The full ranked list, loopback included and last. What the pairing code is built from.
    static func current(port: UInt16) -> [String] {
        ranked(enumerate(), primary: primaryInterfaceName(), port: port)
    }

    /// What a connected client is told: ranked, loopback dropped, capped.
    ///
    /// Capped because every candidate a phone stores becomes a real parallel connection
    /// attempt in `FleetConnector.race()` — an uncapped list would spend the race on VM
    /// bridges no phone can reach.
    static func routable(port: UInt16, limit: Int) -> [String] {
        routable(from: current(port: port), limit: limit)
    }

    /// Split out so a test can drive it without a network.
    static func routable(from ranked: [String], limit: Int) -> [String] {
        Array(ranked.filter { !$0.hasPrefix("127.") }.prefix(limit))
    }

    /// Ranks best-first. Stable within a rank.
    ///
    /// `sorted(by:)` is **not** stable in Swift, and equal ranks are the common case (three
    /// bridges here), so the enumeration offset is part of the sort key. Without it the order
    /// of same-rank candidates varies between runs and the pairing code stops being
    /// reproducible for a fixed machine.
    static func ranked(_ interfaces: [Interface], primary: String?, port: UInt16) -> [String] {
        interfaces
            .enumerated()
            .map { (rank: rank(of: $0.element, primary: primary), offset: $0.offset, interface: $0.element) }
            .sorted { ($0.rank, $0.offset) < ($1.rank, $1.offset) }
            .map { "\($0.interface.address):\(port)" }
    }

    /// 0 is best. See the type's doc comment for why these two signals and not a name.
    private static func rank(of interface: Interface, primary: String?) -> Int {
        // Checked first: a loopback interface is never a useful candidate whatever else it is.
        if interface.isLoopback { return 4 }
        // A tunnel reaches this Mac from anywhere the client is signed in, which is the whole
        // point of the change. CGNAT distinguishes Tailscale from another VPN only to order
        // two tunnels; either still outranks the LAN.
        if interface.isPointToPoint { return isCGNAT(interface.address) ? 0 : 1 }
        // macOS's own answer for "the interface that reaches the internet".
        if let primary, interface.name == primary { return 2 }
        if interface.isBroadcast { return 3 }
        // Neither a tunnel, nor primary, nor a broadcast segment. Last resort, with loopback.
        return 4
    }

    /// `100.64.0.0/10` — the shared address space Tailscale assigns from.
    ///
    /// The mask matters: `100.128.0.1` is ordinary public space and a naive `hasPrefix("100.")`
    /// would rank a public address as a tunnel.
    static func isCGNAT(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4, octets[0] == 100 else { return false }
        return (64...127).contains(octets[1])
    }

    /// The interface macOS considers primary, or nil when there is no network.
    private static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(
            nil, "dev.flightdeck.LocalEndpoints" as CFString, nil, nil
        ),
        let global = SCDynamicStoreCopyValue(
            store, "State:/Network/Global/IPv4" as CFString
        ) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }

    /// IPv4 only. A link-local IPv6 address needs a zone index to be dialable and would
    /// produce candidates that can never connect — noise in a race that is already parallel.
    private static func enumerate() -> [Interface] {
        var interfaces: [Interface] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, let raw = entry.pointee.ifa_addr,
                  raw.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                raw, socklen_t(raw.pointee.sa_len), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            interfaces.append(Interface(
                name: String(cString: entry.pointee.ifa_name),
                address: String(cString: host),
                isPointToPoint: flags & IFF_POINTOPOINT != 0,
                isBroadcast: flags & IFF_BROADCAST != 0,
                isLoopback: flags & IFF_LOOPBACK != 0
            ))
        }
        return interfaces
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: `LocalEndpointsTests` all pass; every other test still passes (nothing consumes the ordering yet).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Fleet/LocalEndpoints.swift Tests/FlightDeckTests/LocalEndpointsTests.swift
git commit -m "feat: rank local addresses so the reachable one comes first

Kernel order put a VM bridge ahead of the tailnet address, and only the
first one ever reached a QR. Rank on the two signals macOS supplies
directly - the primary interface and IFF_POINTOPOINT - rather than on
interface names."
```

---

### Task 2: Payload v3 carries up to two endpoints

**Files:**
- Modify: `Sources/FleetKit/PairingPayload.swift`
- Modify: `Tests/FlightDeckTests/PairingPayloadTests.swift`
- Modify: `Sources/FlightDeckMobile/PairingScreen.swift:121-130` (`message(for:)`)
- Test: `Tests/FlightDeckMobileTests/PairingScreenCopyTests.swift` (create)

**Interfaces:**
- Consumes: `LocalEndpoints.current(port:)` from Task 1 (already wired at `FleetService.swift:390`; no change needed there).
- Produces: `PairingPayload.currentVersion == 3`; `PairingPayload.maxEndpoints == 2`; `PairingPayload.endpoints` now round-trips up to 2 entries.

- [ ] **Step 1: Write the failing tests**

In `Tests/FlightDeckTests/PairingPayloadTests.swift`, **replace** `testOnlyTheFirstUsableEndpointSurvives` with the following, and add the rest:

```swift
    /// v2 packed exactly one endpoint, which is why a Mac on a tailnet handed out a QR
    /// carrying only its Wi-Fi address. Two is the cap — see `maxEndpoints`.
    func testUpToTwoEndpointsSurvive() throws {
        let subject = PairingPayload(
            key: .mint(), macName: "Mac", serviceName: "svc",
            endpoints: ["100.108.99.35:58625", "192.168.1.109:58625", "192.168.139.3:58625"]
        )
        let decoded = try PairingPayload(decoding: subject.encoded())
        XCTAssertEqual(decoded.endpoints, ["100.108.99.35:58625", "192.168.1.109:58625"])
    }

    func testASingleEndpointStillRoundTrips() throws {
        let subject = PairingPayload(
            key: .mint(), macName: "Mac", serviceName: "svc",
            endpoints: ["192.168.1.20:53211"]
        )
        XCTAssertEqual(try PairingPayload(decoding: subject.encoded()).endpoints,
                       ["192.168.1.20:53211"])
    }

    /// An unusable endpoint must not consume one of the two slots — under v2 it packed six
    /// zero bytes and the slot was spent whether or not anything was in it.
    func testAnUnusableEndpointDoesNotConsumeASlot() throws {
        let subject = PairingPayload(
            key: .mint(), macName: "Mac", serviceName: "svc",
            endpoints: ["not-an-address", "192.168.1.20:53211", "10.0.0.4:53211"]
        )
        let decoded = try PairingPayload(decoding: subject.encoded())
        XCTAssertEqual(decoded.endpoints, ["192.168.1.20:53211", "10.0.0.4:53211"])
    }

    /// A v2 code is now refused BY VERSION, so the phone can say "update your Mac" rather
    /// than "that code is damaged" — two messages that send the user in opposite directions.
    func testAV2CodeIsRejectedByVersionRatherThanAsDamaged() {
        let v2 = "FD2-" + String(repeating: "A", count: 160)
        XCTAssertThrowsError(try PairingPayload(decoding: v2)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .unsupportedVersion(2))
        }
    }

    /// The format's ceiling is the count byte; 2 is only the encoder's policy. A decoder that
    /// refused more would make the cap unraisable without another version bump.
    ///
    /// Hand-built, because `encoded()` caps at two by design and cannot produce this record.
    func testTheDecoderAcceptsMoreEndpointsThanTheEncoderWillWrite() throws {
        let key = FleetDeviceKey.mint()
        var bytes = Data([UInt8(PairingPayload.currentVersion)])
        bytes.append(contentsOf: withUnsafeBytes(of: key.slot.uuid) { Data($0) })
        bytes.append(key.secret)
        bytes.append(8)
        // 192.168.<i>.20:53211 — 0xCFDB is 53211.
        for index in 0..<8 {
            bytes.append(Data([192, 168, UInt8(index), 20, 0xCF, 0xDB]))
        }
        for name in ["svc", "Mac"] {
            let utf8 = Data(name.utf8)
            bytes.append(UInt8(utf8.count))
            bytes.append(utf8)
        }
        let decoded = try PairingPayload(
            decoding: "FD\(PairingPayload.currentVersion)-"
                + bytes.crockfordBase32EncodedString()
        )
        XCTAssertEqual(decoded.endpoints.count, 8)
        XCTAssertEqual(decoded.endpoints.first, "192.168.0.20:53211")
    }
```

> **Correction to the spec.** §2 says `testAFullSizedPayloadStillEncodes` "becomes a real
> ceiling test" under v3. It does not: the cap is applied in `encoded()`, so that test's
> 8-endpoint payload still encodes only 2. Leave it as-is — it remains a useful assertion that
> a maximal record encodes — and let `testTheDecoderAcceptsMoreEndpointsThanTheEncoderWillWrite`
> above be the actual ceiling test.

Update `testAPayloadWithNoUsableEndpointStillRoundTrips` to assert `decoded.endpoints == []`
(it previously round-tripped to `[]` via six zero bytes; now the count byte is 0).

In the iOS target, create `Tests/FlightDeckMobileTests/PairingScreenCopyTests.swift`:

```swift
import XCTest
import FleetKit
@testable import FlightDeckMobile

final class PairingScreenCopyTests: XCTestCase {
    /// Until v3 only "too new" was reachable, so one message covered it. A newer phone can
    /// now meet an older Mac, and telling that user to update their phone sends them the
    /// wrong way entirely.
    func testATooOldCodeBlamesTheMacAndATooNewOneBlamesThePhone() {
        let older = PairingScreen.message(for: .unsupportedVersion(2))
        let newer = PairingScreen.message(for: .unsupportedVersion(99))
        XCTAssertTrue(older.localizedCaseInsensitiveContains("Mac"), older)
        XCTAssertFalse(older.localizedCaseInsensitiveContains("phone"), older)
        XCTAssertTrue(newer.localizedCaseInsensitiveContains("phone"), newer)
        XCTAssertNotEqual(older, newer)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh` then `./scripts/test-ios.sh`
Expected: macOS — `testUpToTwoEndpointsSurvive` fails (only one endpoint survives) and `testAV2CodeIsRejectedByVersionRatherThanAsDamaged` fails (v2 IS the current version). iOS — `testATooOldCodeBlamesTheMacAndATooNewOneBlamesThePhone` fails, both messages identical.

- [ ] **Step 3: Bump the version and pack a counted list**

In `Sources/FleetKit/PairingPayload.swift`:

Change the version and add the cap beside `maxNameBytes`:

```swift
    public static let currentVersion = 3
```

```swift
    /// One byte of count, so 255 is the format's ceiling. **2 is the policy**, and it is
    /// measured rather than chosen: at correction level `M` a two-endpoint record renders to
    /// 47 modules — byte for byte what v2 produces today — and a three-endpoint one to 51,
    /// which breaks `PairingCodeImageTests.testThePackedPayloadProducesAMateriallySmallerQR`
    /// against its 0.75 threshold. Two is also exactly the requirement: one address that
    /// works off the LAN and one that works on it. Any *further* LAN address is Bonjour's
    /// job, which is the one thing Bonjour can do that a QR cannot. Do not raise this to buy
    /// robustness the browser already provides.
    private static let maxEndpoints = 2
```

Replace the endpoint line in `encoded()`:

```swift
        // Was `packedEndpoint(endpoints.first)` — one address, unconditionally, which is why
        // a Mac on a tailnet handed out a code carrying only its Wi-Fi address.
        let packed = endpoints.prefix(Self.maxEndpoints).compactMap(Self.packedEndpoint)
        bytes.append(UInt8(packed.count))
        for endpoint in packed { bytes.append(endpoint) }
```

Replace `packedEndpoint` so an unusable entry yields nil rather than six zero bytes — under a
count byte, a zero-filled slot is indistinguishable from a real one and wastes a slot:

```swift
    /// IPv4 and port, or nil when there is nothing usable to pack.
    ///
    /// IPv4 only, matching `LocalEndpoints`: a link-local IPv6 address needs a zone index to
    /// be dialable and would pack a candidate that can never connect. A Mac with no routable
    /// v4 address still produces a scannable code carrying zero endpoints — the phone finds
    /// it over Bonjour.
    private static func packedEndpoint(_ text: String) -> Data? {
        guard let colon = text.lastIndex(of: ":"),
              let port = UInt16(text[text.index(after: colon)...])
        else { return nil }
        let octets = text[..<colon].split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return Data(octets) + Data([UInt8(port >> 8), UInt8(port & 0xFF)])
    }

    private static func unpackedEndpoint(_ bytes: Data) -> String? {
        let octets = [UInt8](bytes.prefix(4))
        let port = UInt16(bytes[bytes.startIndex + 4]) << 8 | UInt16(bytes[bytes.startIndex + 5])
        guard octets.contains(where: { $0 != 0 }) || port != 0 else { return nil }
        return "\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3]):\(port)"
    }
```

In `init(decoding:)`, replace the fixed-offset endpoint read. The minimum is now 50 bytes
(version + slot + secret + count) rather than 56:

```swift
        guard let bytes = Data(crockfordBase32: String(trimmed[trimmed.index(after: dash)...])),
              bytes.count >= 50
        else { throw PairingPayloadError.malformed }
```

and, after `secret`:

```swift
        // `Data(...)` on every slice, not the bare slice: a slice of `bytes` keeps a non-zero
        // `startIndex`, and an endpoint indexed from 0 inside `unpackedEndpoint` is a trap.
        let count = Int(bytes[49])
        var cursor = 50
        var endpoints: [String] = []
        for _ in 0..<count {
            guard cursor + 6 <= bytes.count else { throw PairingPayloadError.malformed }
            if let endpoint = Self.unpackedEndpoint(Data(bytes[cursor..<(cursor + 6)])) {
                endpoints.append(endpoint)
            }
            cursor += 6
        }
```

Delete the old `var cursor = 55` line — `cursor` is now established above. The
`cursor == bytes.count` guard after the two names is unchanged and still load-bearing.

- [ ] **Step 4: Split the phone's version copy**

In `Sources/FlightDeckMobile/PairingScreen.swift`, replace the `.unsupportedVersion` arm of
`message(for:)`:

```swift
        // Both directions are reachable from v3 onward: a phone that has been updated can meet
        // a Mac that has not. "Update the app" would send half of those users the wrong way.
        case .unsupportedVersion(let version):
            return version < PairingPayload.currentVersion
                ? "This code is from an older version of Flight Deck. Update the app on your Mac."
                : "This code is from a newer version of Flight Deck. Update the app on your phone."
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` then `./scripts/test-ios.sh`
Expected: all pass, **including `PairingCodeImageTests.testThePackedPayloadProducesAMateriallySmallerQR` unmodified**. If that test fails, the cap or the record layout is wrong — fix the code, do not touch the threshold.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/PairingPayload.swift Tests/FlightDeckTests/PairingPayloadTests.swift \
        Sources/FlightDeckMobile/PairingScreen.swift Tests/FlightDeckMobileTests/PairingScreenCopyTests.swift
git commit -m "feat: pack two endpoints into the pairing code

One address, chosen by kernel order, is why a phone and a Mac on the same
tailnet could not pair. A count byte and a cap of two - measured to leave
the QR exactly the size v2 produced - carry one address that works off the
LAN and one that works on it.

v2 is dropped rather than dual-decoded, as v1 was. Both directions of
version mismatch are now reachable, so the phone's copy names which end
needs updating."
```

---

### Task 3: The `mac.endpoints` request — wire and Mac end

**Files:**
- Modify: `Sources/FleetKit/TimelineFrames.swift` (`FleetRequest`)
- Modify: `Sources/FleetKit/Frames.swift` (`ServerFrame`)
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift:141-176` (`onRequest`)
- Test: `Tests/FlightDeckTests/EndpointRefreshLoopbackTests.swift` (create)

**Interfaces:**
- Consumes: `LocalEndpoints.routable(port:limit:)` from Task 1.
- Produces: `FleetRequest.macEndpoints` (op `mac.endpoints`); `ServerFrame.macEndpoints(cid: Int, [String])` (tag `endpoints`).

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/EndpointRefreshLoopbackTests.swift`, modelled on
`AnswerLoopbackTests` — real service, real socket, real client:

```swift
import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// The refresh channel over a real TLS-PSK socket on loopback: a connected client asks the
/// Mac where it can be reached and gets an answer it could actually dial.
///
/// `FleetTestHarness` and this setup/teardown shape are copied from `AnswerLoopbackTests`.
@MainActor
final class EndpointRefreshLoopbackTests: XCTestCase {
    private var harness: FleetTestHarness?
    private var client: FleetClient?

    override func tearDown() async throws {
        client?.disconnect()
        harness?.service.stop()
        client = nil
        harness = nil
    }

    func testAConnectedClientCanAskTheMacForItsAddresses() async throws {
        let harness = FleetTestHarness()
        self.harness = harness
        _ = try await harness.start()

        let client = FleetClient(key: harness.key)
        self.client = client

        let answered = expectation(description: "endpoints")
        // `nonisolated(unsafe)` is not needed: the box is only read after `fulfillment`.
        let received = FrameBox()
        client.onFrame = { frame in
            if case .macEndpoints(_, let list) = frame {
                received.endpoints = list
                answered.fulfill()
            }
        }
        client.connect(to: try harness.service.loopbackEndpoint(), lastSeq: 0)
        client.send(FleetRequest.macEndpoints)

        await fulfillment(of: [answered], timeout: 5)
        let endpoints = received.endpoints
        XCTAssertFalse(endpoints.isEmpty, "a listening Mac always has at least one address")
        XCTAssertTrue(endpoints.allSatisfy { $0.contains(":") })
        XCTAssertFalse(
            endpoints.contains { $0.hasPrefix("127.") },
            "loopback is dropped — a phone dialling it spends a race slot on itself"
        )
        XCTAssertLessThanOrEqual(endpoints.count, 4)
    }

    /// The rule the whole reply-frame family obeys. A `seq` here would let a client that
    /// refreshed its endpoints move the resume point it hands back on its next `hello`.
    func testTheReplyCarriesNoSeqAndItsTagIsUndotted() throws {
        let encoded = try JSONEncoder().encode(ServerFrame.macEndpoints(cid: 7, ["100.64.0.1:1234"]))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertNil(json["seq"])
        let tag = try XCTUnwrap(json["t"] as? String)
        XCTAssertEqual(tag, "endpoints")
        // Undotted, so it cannot collide with the dotted `FleetEventTag` namespace that
        // `ServerFrame`'s decoder falls through to when no frame tag matches.
        XCTAssertFalse(tag.contains("."))
    }

    /// Round-trips, so a client and a Mac built from these sources agree on the shape.
    func testTheReplyRoundTrips() throws {
        let frame = ServerFrame.macEndpoints(cid: 3, ["100.64.0.1:1", "192.168.1.5:1"])
        let decoded = try JSONDecoder().decode(
            ServerFrame.self, from: try JSONEncoder().encode(frame)
        )
        XCTAssertEqual(decoded, frame)
    }

    /// Mutable state shared with a socket-queue callback, read only after `fulfillment`.
    private final class FrameBox: @unchecked Sendable {
        var endpoints: [String] = []
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `FleetRequest.macEndpoints` and `ServerFrame.macEndpoints` do not exist.

- [ ] **Step 3: Add the request case**

In `Sources/FleetKit/TimelineFrames.swift`, `FleetRequest`:

```swift
    /// Every address this Mac can currently be reached on, best-first.
    ///
    /// **A request rather than snapshot state**, for the reason `newSessionOptions` records:
    /// addresses come from the network, the network emits no fleet events, and a snapshot
    /// that changes with nothing recorded is what `FleetReplicator`'s drift check exists to
    /// catch. It is also what the pairing code cannot do on its own — a QR is scanned once
    /// and its addresses are true only on the day it was drawn.
    case macEndpoints
```

```swift
    private enum Op: String, Codable {
        case timeline = "timeline.page"
        case newSessionOptions = "session.newOptions"
        case macEndpoints = "mac.endpoints"
    }
```

Encode — no payload beyond the op:

```swift
        case .macEndpoints:
            try c.encode(Op.macEndpoints, forKey: .op)
```

Decode:

```swift
        case .macEndpoints:
            self = .macEndpoints
```

- [ ] **Step 4: Add the reply frame**

In `Sources/FleetKit/Frames.swift`, `ServerFrame`:

```swift
    /// The reply to `FleetRequest.macEndpoints`. Unsequenced for the same reason `page` and
    /// `newSessionOptions` are: a list of addresses is not fleet state, and giving it a `seq`
    /// would move the resume point a client hands back on its next `hello`.
    case macEndpoints(cid: Int, [String])
```

Add `endpoints` to `CodingKeys`, and `endpoints` to `Tag`:

```swift
    enum CodingKeys: String, CodingKey {
        case t, seq, fleet, reason, cid, code, page, options, endpoints
    }

    private enum Tag: String, Codable { case snapshot, ack, err, page, options, endpoints }
```

Encode:

```swift
        case .macEndpoints(let cid, let list):
            try c.encode(Tag.endpoints, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(list, forKey: .endpoints)
```

Decode, inside the existing `switch tag`:

```swift
            case .endpoints:
                self = .macEndpoints(
                    cid: try c.decode(Int.self, forKey: .cid),
                    try c.decode([String].self, forKey: .endpoints)
                )
```

- [ ] **Step 5: Answer it on the Mac**

In `Sources/FlightDeck/Fleet/FleetService.swift`, add a third arm to `onRequest`'s switch,
after `.newSessionOptions`:

```swift
            case .macEndpoints:
                // Answered synchronously: enumerating interfaces is a syscall, not file I/O,
                // so there is nothing to hop a `Task` for and `reply` lands on `queue` as
                // `onRequest` requires.
                //
                // Nothing here writes and nothing enters `FleetSnapshot` — addresses change
                // with no event recorded, which is exactly the shape `FleetReplicator`'s
                // drift assertion catches.
                guard let boundPort else {
                    return reply(.err(cid: cid, code: "not_listening"))
                }
                reply(.macEndpoints(
                    cid: cid,
                    LocalEndpoints.routable(port: boundPort.rawValue, limit: 4)
                ))
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: `EndpointRefreshLoopbackTests` passes; everything else still passes.

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/TimelineFrames.swift Sources/FleetKit/Frames.swift \
        Sources/FlightDeck/Fleet/FleetService.swift Tests/FlightDeckTests/EndpointRefreshLoopbackTests.swift
git commit -m "feat: let a connected client ask the Mac for its addresses

A QR is scanned once and its addresses are true only that day. This is the
refresh channel - a request rather than snapshot state, because addresses
change with no fleet event to record them."
```

---

### Task 4: The client end — ask on every snapshot, adopt, drain

**Files:**
- Modify: `Sources/FleetKit/FleetConnector.swift` (pending table ~line 116, `apply` ~393, `err` arm ~427, `drainPending` ~585)
- Modify: `Sources/FleetKit/PairedMac.swift:7-17` (the `endpoints` doc comment is now false)
- Test: `Tests/FlightDeckTests/FleetConnectorEndpointTests.swift` (create)

**Interfaces:**
- Consumes: `FleetRequest.macEndpoints`, `ServerFrame.macEndpoints` from Task 3.
- Produces: `FleetConnector.requestMacEndpoints(then:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/FleetConnectorEndpointTests.swift`. Copy the connector harness
from `Tests/FlightDeckTests/FleetConnectorTests.swift` — read that file first and reuse its
`connector(key:endpoints:store:)` helper rather than writing a new one.

```swift
import Network
import XCTest
import FleetKit

/// The refresh as the client sees it. Harness shape copied from `FleetConnectorTests`.
@MainActor
final class FleetConnectorEndpointTests: XCTestCase {
    private var servers: [FleetSocketServer] = []
    private var connector: FleetConnector?

    override func tearDown() {
        connector?.stop()
        servers.forEach { $0.stop() }
        servers = []
        connector = nil
        super.tearDown()
    }

    /// The answer is set AFTER `start()` returns, because a realistic answer has to name the
    /// port the server just bound.
    private final class Answer: @unchecked Sendable {
        var endpoints: [String] = []
        var code: String?
    }

    private func snapshot() -> FleetSnapshot {
        FleetSnapshot(projects: [
            WireProject(id: UUID(), name: "fd", path: "/w/fd", sessions: [])
        ])
    }

    private func startServer(key: FleetDeviceKey, answer: Answer) async throws -> NWEndpoint.Port {
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, cid, request, reply in
            guard case .macEndpoints = request else {
                return reply(.err(cid: cid, code: "unhandled"))
            }
            if let code = answer.code { reply(.err(cid: cid, code: code)) }
            else { reply(.macEndpoints(cid: cid, answer.endpoints)) }
        }
        servers.append(server)
        return try await server.start(keys: [key], port: nil)
    }

    private func connect(
        key: FleetDeviceKey, endpoints: [String], store: InMemoryPairedMacStore
    ) async -> FleetConnector {
        let mac = PairedMac(
            key: key, macName: "Mac", serviceName: "none-\(UUID().uuidString)",
            endpoints: endpoints
        )
        store.save(mac)
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        let up = expectation(description: "connected")
        up.assertForOverFulfill = false
        connector.onState = { if case .connected = $0 { up.fulfill() } }
        connector.start()
        await fulfillment(of: [up], timeout: 5)
        return connector
    }

    /// Every snapshot is every connect, and it is the only hook the refresh has — addresses
    /// have no push path.
    func testTheConnectorAsksForEndpointsOnSnapshotArrival() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        let asked = expectation(description: "asked")
        asked.assertForOverFulfill = false
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, cid, request, reply in
            if case .macEndpoints = request { asked.fulfill() }
            reply(.macEndpoints(cid: cid, ["100.64.0.1:9"]))
        }
        servers.append(server)
        let port = try await server.start(keys: [key], port: nil)
        _ = answer
        _ = await connect(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: InMemoryPairedMacStore())
        await fulfillment(of: [asked], timeout: 5)
    }

    /// The Mac enumerated its own interfaces, so its answer is authoritative for membership:
    /// an address it no longer claims is exactly the stale candidate this request removes.
    func testAReplyReplacesTheStoredEndpoints() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        let port = try await startServer(key: key, answer: answer)
        let live = "127.0.0.1:\(port.rawValue)"
        answer.endpoints = ["100.64.0.1:9", live]

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: [live, "192.0.2.1:9"], store: store)

        let done = expectation(description: "refreshed")
        connector.requestMacEndpoints { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        // "192.0.2.1:9" is gone — the Mac never claimed it.
        XCTAssertEqual(Set(store.load()?.endpoints ?? []), Set(["100.64.0.1:9", live]))
    }

    /// `promote()` keeps whichever address last won a race at the front. A refresh must not
    /// throw that away when the Mac still claims the address.
    func testTheLastSuccessfulEndpointStaysAtTheFrontWhenTheMacStillClaimsIt() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        let port = try await startServer(key: key, answer: answer)
        let live = "127.0.0.1:\(port.rawValue)"
        // The Mac ranks the tunnel first; the client has just proved `live` works.
        answer.endpoints = ["100.64.0.1:9", live]

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: [live], store: store)

        let done = expectation(description: "refreshed")
        connector.requestMacEndpoints { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(store.load()?.endpoints.first, live,
                       "promotion must survive a refresh that still contains the address")
    }

    /// "Absent" and "empty" mean opposite things. We are reading this frame over one of the
    /// Mac's addresses, so a reply saying it has none must not erase the one that is working.
    func testAnEmptyReplyIsIgnored() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        let port = try await startServer(key: key, answer: answer)
        let live = "127.0.0.1:\(port.rawValue)"
        answer.endpoints = []

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: [live], store: store)

        let done = expectation(description: "answered")
        connector.requestMacEndpoints { _ in done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertEqual(store.load()?.endpoints, [live])
    }

    /// An older Mac answers `unsupported`/`unhandled`. That must be a soft failure that
    /// leaves the phone exactly as it was — the compatibility rule the whole wire obeys.
    func testAnErrReplyLeavesTheStoredListIntact() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        answer.code = "unsupported"
        let port = try await startServer(key: key, answer: answer)
        let live = "127.0.0.1:\(port.rawValue)"

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: [live], store: store)

        let failed = expectation(description: "failed")
        var received: FleetRequestError?
        connector.requestMacEndpoints { result in
            if case .failure(let error) = result { received = error }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)

        XCTAssertEqual(received, .server(code: "unsupported"))
        XCTAssertEqual(store.load()?.endpoints, [live])
    }

    /// The fourth pending table has to drain with the other three, or a client whose socket
    /// dies with a refresh outstanding waits forever.
    func testADeadSocketFailsAnOutstandingEndpointRequest() async throws {
        let key = FleetDeviceKey.mint()
        let answer = Answer()
        // Never answered: the server holds the request while the client tears down.
        let server = FleetSocketServer()
        let fleet = snapshot()
        server.onHello = { _, _ in [.snapshot(seq: 1, fleet: fleet, reason: .initial)] }
        server.onRequest = { _, _, _, _ in }
        servers.append(server)
        let port = try await server.start(keys: [key], port: nil)

        let store = InMemoryPairedMacStore()
        let connector = await connect(key: key, endpoints: ["127.0.0.1:\(port.rawValue)"], store: store)

        let drained = expectation(description: "drained")
        var received: FleetRequestError?
        connector.requestMacEndpoints { result in
            if case .failure(let error) = result { received = error }
            drained.fulfill()
        }
        connector.stop()
        await fulfillment(of: [drained], timeout: 5)
        XCTAssertEqual(received, .disconnected)
    }
}
```

> **Executor note:** `testTheConnectorAsksForEndpointsOnSnapshotArrival` has an unused
> `answer` — drop that local when writing the file. If `InMemoryPairedMacStore.load()` has a
> different name in this tree, use whatever `FleetConnectorTests` calls to read stored state.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `requestMacEndpoints` does not exist.

- [ ] **Step 3: Add the table, the ask, and the adopt**

In `Sources/FleetKit/FleetConnector.swift`, beside `pendingOptions`:

```swift
    /// A fourth answer type, on the same reasoning `pendingAcks` and `pendingOptions` give:
    /// one table per answer shape, all four sharing the single `cid` space `FleetClient.send`
    /// mints from, so a number is filed in at most one and `apply` tries each in turn.
    private var pendingEndpoints: [Int: (Result<[String], FleetRequestError>) -> Void] = [:]
```

Beside `requestNewSessionOptions`:

```swift
    /// Ask the Mac which addresses it can currently be reached on. Same contract as
    /// `request(_:then:)` — exactly one answer, `.disconnected` synchronously when there is
    /// nothing to ask.
    ///
    /// The answer is adopted by `adoptEndpoints` before the completion runs, so a caller that
    /// only wants the refresh can pass an empty closure and ignore the value.
    public func requestMacEndpoints(
        then completion: @escaping (Result<[String], FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(FleetRequest.macEndpoints)
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pendingEndpoints[cid] = completion
    }

    private func resolveEndpoints(
        _ cid: Int, with result: Result<[String], FleetRequestError>
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let completion = pendingEndpoints.removeValue(forKey: cid) else { return }
        completion(result)
    }

    /// Takes the Mac's list as authoritative for membership, keeping the promoted address in
    /// front when the Mac still claims it.
    private func adoptEndpoints(_ list: [String]) {
        dispatchPrecondition(condition: .onQueue(queue))
        // Empty means "this Mac could not enumerate", never "this Mac has no addresses" — we
        // are reading the frame over one of them. Erasing a working candidate on the strength
        // of an empty answer is the one outcome worse than a stale list.
        guard !list.isEmpty else { return }
        var next = list
        // `promote()` puts whichever address last won a race at the front. Preserve that
        // across a refresh; drop it when the Mac no longer claims it, which is precisely the
        // stale candidate this request exists to remove.
        if let promoted = mac.endpoints.first, let index = next.firstIndex(of: promoted) {
            next.remove(at: index)
            next.insert(promoted, at: 0)
        }
        guard next != mac.endpoints else { return }
        mac.endpoints = next
        try? store.save(mac)
    }
```

In `apply`, add the reply arm beside `newSessionOptions`:

```swift
        case .macEndpoints(let cid, let list):
            // Unsequenced, exactly like `page` and `newSessionOptions` and for the same
            // reason — addresses are not fleet state and must not move the resume point.
            adoptEndpoints(list)
            resolveEndpoints(cid, with: .success(list))
            return
```

In `apply`'s `.snapshot` arm, ask — this is the only hook needed, and it covers first dial,
reconnect and the background redial without any of them having their own:

```swift
        case .snapshot(let seq, let snapshot, _):
            fleet = snapshot
            adopt(seq)
            // **Every snapshot, which is every connect.** Addresses have no push path — the
            // network emits no fleet events — so this is the moment they get refreshed, the
            // same hook the New Session menu hangs off on the phone. The answer is adopted in
            // the reply arm above; nothing here needs the value.
            requestMacEndpoints { _ in }
```

In the `.err` arm, insert before the final `resolve(...)` and update the existing comment,
which says "a future third table":

```swift
            if pendingEndpoints[cid] != nil {
                resolveEndpoints(cid, with: .failure(.server(code: code)))
                return
            }
```

In `drainPending()`:

```swift
        // And the endpoint refresh. Added the moment the table was, per the rule in
        // docs/NETWORKING.md: a client whose socket dies with a request outstanding waits
        // forever otherwise.
        let outstandingEndpoints = pendingEndpoints
        pendingEndpoints.removeAll()
        for completion in outstandingEndpoints.values { completion(.failure(.disconnected)) }
```

- [ ] **Step 4: Correct `PairedMac.endpoints`' doc comment**

It currently says the list is "seeded once from the pairing payload's QR and never grown after
that" and that `promote` "never adds an address that was not already here". Both are now false.
Replace with:

```swift
    /// Every REMEMBERED address, best-first — seeded from the pairing payload's QR, then
    /// replaced wholesale whenever `FleetRequest.macEndpoints` answers, which is on every
    /// connect. `FleetConnector.promote` still only REORDERS, moving whichever address won a
    /// race to the front; `FleetConnector.adoptEndpoints` is what changes the membership, and
    /// it keeps the promoted address in front when the Mac still claims it.
    ///
    /// Bonjour rediscovery remains deliberately absent from this list (it is retried on every
    /// launch rather than remembered — see `FleetConnector.Candidate.isRemembered`), so a Mac
    /// reachable only by a brand-new address on a LAN is still found by the browser. What the
    /// refresh adds is the off-LAN case, where there is no browser to help.
    public var endpoints: [String]
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: `FleetConnectorEndpointTests` passes; all existing connector tests still pass.

- [ ] **Step 6: Run the iOS suite**

Run: `./scripts/test-ios.sh`
Expected: passes. The phone needed no change — the connector asks for itself.

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/FleetConnector.swift Sources/FleetKit/PairedMac.swift \
        Tests/FlightDeckTests/FleetConnectorEndpointTests.swift
git commit -m "feat: refresh remembered addresses on every snapshot

The connector asks on snapshot arrival - every connect - and takes the
Mac's answer as authoritative, keeping the promoted address in front when
the Mac still claims it. An empty answer is ignored: we are reading it over
one of the addresses it would erase."
```

---

### Task 5: Documentation

**Files:**
- Modify: `docs/NETWORKING.md`
- Modify: `docs/MOBILE.md`
- Modify: `docs/FOLLOWUPS.md:532-533`

- [ ] **Step 1: Record the request in NETWORKING.md**

Under "Discovery and reconnection", add a subsection covering: that the QR carries two
endpoints and why the cap is 2 (with the measured module counts), that `mac.endpoints` is the
refresh and fires on snapshot arrival, and that `LocalEndpoints` ranks on `PrimaryInterface`
and `IFF_POINTOPOINT` rather than interface names. Add `pendingEndpoints` to the list of
pending tables named in "Adding a command or a request", item 4 — it currently says three.

- [ ] **Step 2: Add the manual check to MOBILE.md**

In the manual checklist, add the scenario that produced this defect, since no single machine
can automate it: Mac on Wi-Fi with Tailscale up, phone on cellular (Wi-Fi off), scan the QR,
expect the Mac's pairing modal to dismiss and the phone's fleet list to populate.

- [ ] **Step 3: Update the FOLLOWUPS entry**

The bullet reading "**No relay**, so reaching the Mac from off-LAN needs a VPN. Designed for
as a further candidate endpoint (spec §3, §12), not built in either plan." is now half-built.
Rewrite it to say a relay is still absent — off-LAN still requires a VPN — but that the VPN
address is now carried and refreshed, citing this plan's spec.

- [ ] **Step 4: Commit**

```bash
git add docs/NETWORKING.md docs/MOBILE.md docs/FOLLOWUPS.md
git commit -m "docs: the endpoint list, its cap, and the check only two devices can make"
```

---

## Verification

After Task 5:

- [ ] `./scripts/test-unit.sh` — all green, `testThePackedPayloadProducesAMateriallySmallerQR` **unmodified**.
- [ ] `./scripts/test-ios.sh` — all green.
- [ ] Confirm the real QR now carries the tailnet address. With the app running, arm pairing from Preferences → Devices and check the log:
  `log show --predicate 'subsystem == "dev.flightdeck.FlightDeck"' --last 5m --info --style compact`
- [ ] **End-to-end, requires the phone.** Rebuild the Mac app and swap it in with `scripts/swap-release.sh` (run detached; it SIGKILLs the app). Build and install the phone app over USB. Then: Mac on Wi-Fi with Tailscale up, phone on **cellular with Wi-Fi off**, scan the QR — the Mac's pairing modal should dismiss and the phone's fleet list should populate.

**Both ends must be updated together** — v2 codes no longer decode, so the QR on the rebuilt Mac will not scan into the phone build currently installed.
