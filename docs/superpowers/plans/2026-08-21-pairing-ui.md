# Pairing UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the short code in front of a person — packed into a QR that is half the density it was, drawn on the Mac as `XXXX-XXXX-XXXX`, and typed into a phone that validates it locally, finds the Mac over Bonjour, and pairs.

**Architecture:** No new protocol. The Mac's sheet draws `ArmedPairing.code.formatted` beside a QR whose payload is now raw packed bytes in Crockford base32 rather than base64url'd JSON. The phone's typed field feeds `PairingCode(normalizing:)` — which is where a typo dies, before any socket exists — and a validated code goes to `PairingRunner`, which already owns discovery and the try-each-Mac walk. `FleetModel` gains one method and one published progress value; everything else it needs was built in FleetKit.

**Tech Stack:** SwiftUI (macOS and iOS), CoreImage's QR generator, `FleetKit` (`PairingCode`, `PairingPayload`, `PairingRunner`), XCTest.

**Spec:** [`docs/superpowers/specs/2026-08-21-short-pairing-code-design.md`](../specs/2026-08-21-short-pairing-code-design.md)

**Follows:** [`2026-08-21-pairing-channel.md`](2026-08-21-pairing-channel.md), which must be complete first — this plan consumes `ArmedPairing`, `PairingRunner`, `PairingBrowser.DiscoveredMac` and `PairingInitiator.Failure` as they exist there.

## Why this is its own plan

Split from the channel plan on the same seam Plan A was split from Plan B. The channel is proved by `./scripts/test-unit.sh` against real sockets; this is proved by a build, a simulator, and a checklist a person runs — the regime `docs/MOBILE.md` already keeps, for the reason it already states: the phone's screens are the least-verifiable code in the repo, and pretending otherwise is what let three camera-lifecycle defects ship in a row. Both halves stand alone: the channel pairs without a screen, and this plan is nothing but screens over machinery that already works.

## What the spec gets wrong here, and what this plan does instead

§8 says the QR can drop the Mac's display name "because it arrives with the first snapshot", and the Bonjour service name because it is "derivable from the slot". **Neither is true of the shipped code**, and an executor who takes them on faith ships a phone that cannot name its Mac or find it again:

- `FleetSnapshot` (`Sources/FleetKit/Wire.swift`) carries projects and sessions and **no Mac identity at all**. Nothing in a snapshot names the Mac.
- `FleetService.serviceName` is `<sanitised host name>-<per-install suffix>`. It is stable per *Mac*, not per slot, and nothing about a slot UUID produces it. `FleetConnector.startBrowsing` matches Bonjour results against exactly this string, so a phone without it cannot rediscover its Mac after either of them moves — which is most of what roaming is.

So this plan keeps both names in the payload, length-prefixed, and pays for them: **~97 bytes** for typical names instead of §8's ~55. The arithmetic is in Task 1, and the density test asserts a measured improvement rather than the spec's predicted QR version. The cheaper route — putting `macName` and `serviceName` into `FleetSnapshot` so §8's claim becomes true — is a wire change and belongs in its own slice; it is recorded in `docs/FOLLOWUPS.md` by Task 5, not attempted here.

## Global Constraints

- **`FleetKit` imports Foundation, Network, Security, CryptoKit and `BoringSSLShim` only.** `PairingPayload` lives there, so Task 1 stays inside that boundary; the `FleetKitiOS` target enforces it.
- **`FleetKit` builds in Swift 6 language mode.** So do `FlightDeckMobile` and `FleetKitiOS`. `FlightDeck` (macOS) is Swift 5.
- **`wait(for:)` deadlocks in a `@MainActor` async XCTest method.** Use `await fulfillment(of:timeout:)`.
- **`./scripts/build-ios.sh`'s type-check fallback never reaches SIL.** Region-based isolation errors — "sending '…' risks causing data races" — pass a type-check and fail a real build. A green type-check means "it parses and the types line up", no more. If an iOS runtime is installed, the app target really builds and this caveat does not apply; check which of the two the script reported.
- **A simulator has no camera.** Typed entry is not a lesser path there — it is the only pairing route that works at all, which is what makes Task 3 the one the simulator can actually exercise.
- **Never run `./scripts/smoke.sh`.**
- **A debug instance and a simulator may be running.** Check `pgrep -f "harness/Flight Deck.app"` before running the suite, and never launch a build to "try it".
- **Verification per task:** `./scripts/test-unit.sh` (baseline **1244** after the channel plan, 0 failures) and `./scripts/build-ios.sh` (three successes).
- **UI copy says what to do next.** Three failures that all read "pairing failed" send the user to three wrong places; the existing `PairingScreen.message(for:)` is the shape to follow.

## File Structure

| File | Change |
|---|---|
| `Sources/FleetKit/PairingPayload.swift` | Rewrite: packed bytes + Crockford base32, version 2. The `PairingPayloadError` cases and their meanings are unchanged, so the phone's copy still works. |
| `Sources/FlightDeck/Preferences/UI/PairingCodeView.swift` | The sheet takes an `ArmedPairing` and draws `code.formatted` where the 300-character string was. |
| `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift` | Pass the whole window to the sheet. |
| `Sources/FlightDeckMobile/PairingScreen.swift` | Typed field becomes a 12-character code field: uppercase-forced, autocorrect off, validated locally. |
| `Sources/FlightDeckMobile/FleetModel.swift` | `pair(typedCode:)` over `PairingRunner`; publish progress. |
| `docs/superpowers/specs/2026-08-18-mobile-companion-design.md` | §9's two amendments. |
| `docs/MOBILE.md` | The typed-path checklist items and the cross-process criterion. |
| `docs/FOLLOWUPS.md` | The `FleetSnapshot`-identity follow-up, and what the QR did and did not shrink to. |
| `Tests/FlightDeckTests/PairingPayloadTests.swift` | Rewritten for v2. |
| `Tests/FlightDeckTests/PairingCodeImageTests.swift` | Adds the density assertion. |

---

### Task 1: Pack the QR payload

**Files:**
- Modify: `Sources/FleetKit/PairingPayload.swift` (rewrite `encoded()`/`init(decoding:)`, add a Crockford base32 codec)
- Test: `Tests/FlightDeckTests/PairingPayloadTests.swift` (rewritten)
- Test: `Tests/FlightDeckTests/PairingCodeImageTests.swift` (density)

**Interfaces:**
- Consumes: `FleetDeviceKey`, `PairingPayloadError` (both shipped).
- Produces: `PairingPayload.currentVersion == 2`; `encoded() -> String` of the form `"FD2-"` + Crockford base32; `init(decoding:) throws`; the same four stored properties (`version`, `key`, `macName`, `serviceName`, `endpoints`) with the same types, so every existing caller compiles unchanged.

**The layout, fixed here so nothing has to re-derive it:**

| Offset | Bytes | Field |
|---|---|---|
| 0 | 1 | version (2) |
| 1 | 16 | slot UUID, raw |
| 17 | 32 | device key secret |
| 49 | 4 | IPv4 address of the first usable endpoint, or all zeroes |
| 53 | 2 | port, big-endian, or zero |
| 55 | 1 | service-name length *n* (≤ 64) |
| 56 | *n* | service name, UTF-8 |
| 56+*n* | 1 | Mac-name length *m* (≤ 64) |
| 57+*n* | *m* | Mac name, UTF-8 |

With a typical `flightdeck-macbook-a1b2` (22) and `Nate's MacBook Pro` (19) that is **97 bytes**, which is 156 base32 symbols plus the 4-character `FD2-` prefix: **160 characters**, all from QR's alphanumeric charset. Today's payload is ~230 characters of base64url, which is byte mode. Whether CoreImage picks alphanumeric mode is not documented, so the test measures the result rather than asserting a QR version.

- [ ] **Step 1: Write the failing tests**

Replace `Tests/FlightDeckTests/PairingPayloadTests.swift` entirely. Four of the old tests described the v1 JSON encoding specifically and do not survive the format change — `testAPrefixVersionDisagreeingWithTheBodyIsMalformed`, `testASignedVersionIsNotAVersion` (both about the `flightdeck±1:` prefix grammar), `testTheSecretIsNotReadableFromTheCodeAsText` (about base64url of JSON) and `testEndpointsSurviveInTheOrderTheMacListedThem` (v2 carries one endpoint by design). Their properties are re-expressed below where they still mean something.

```swift
import XCTest
import FleetKit

final class PairingPayloadTests: XCTestCase {
    private func payload(
        macName: String = "Nate's MacBook Pro",
        serviceName: String = "flightdeck-macbook-a1b2",
        endpoints: [String] = ["192.168.1.20:53211"]
    ) -> PairingPayload {
        PairingPayload(
            key: .mint(), macName: macName, serviceName: serviceName, endpoints: endpoints
        )
    }

    /// Byte-stability, kept from v1 and still load-bearing for the same reason: the sheet
    /// encodes once at init and redraws the QR only when the code changes. An encoding that
    /// varied would churn the image in front of the user once a second.
    func testEncodingTheSamePayloadTwiceGivesTheSameString() {
        let subject = payload()
        let encodings = Set((0..<50).map { _ in subject.encoded() })
        XCTAssertEqual(encodings.count, 1)
    }

    func testAPayloadRoundTrips() throws {
        let original = payload()
        let decoded = try PairingPayload(decoding: original.encoded())
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.key.slot, original.key.slot)
        XCTAssertEqual(decoded.key.secret, original.key.secret)
        XCTAssertEqual(decoded.macName, original.macName)
        XCTAssertEqual(decoded.serviceName, original.serviceName)
        XCTAssertEqual(decoded.endpoints, original.endpoints)
    }

    /// The whole point of the repack. Not asserted as a QR version — CoreImage does not
    /// document which encoding mode it picks — but as a length, against the v1 shape measured
    /// on the same payload.
    func testThePackedCodeIsFarShorterThanTheJSONOneItReplaces() {
        let subject = payload()
        let packed = subject.encoded()
        // The v1 encoding, reconstructed here rather than kept alive in the source: JSON with
        // the same six fields, base64url'd, prefixed.
        let v1Body = #"{"eps":["192.168.1.20:53211"],"name":"Nate's MacBook Pro","psk":"\#(subject.key.secret.base64EncodedString())","slot":"\#(subject.key.slot.uuidString)","svc":"flightdeck-macbook-a1b2","v":1}"#
        let v1 = "flightdeck1:" + Data(v1Body.utf8).base64EncodedString()
        XCTAssertLessThan(
            Double(packed.count), Double(v1.count) * 0.75,
            "the packed payload is \(packed.count) characters against v1's \(v1.count)"
        )
    }

    /// Uppercase and alphanumeric throughout, which is what lets a QR encoder use its
    /// alphanumeric mode and what keeps the string readable if it is ever shown as text.
    func testTheCodeUsesOnlyTheCrockfordAlphabetAndItsPrefix() {
        let allowed = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZFD-")
        XCTAssertTrue(payload().encoded().allSatisfy { allowed.contains($0) })
        XCTAssertTrue(payload().encoded().hasPrefix("FD2-"))
    }

    /// Kept from v1, and still the reason the version lives in the prefix: a payload from a
    /// newer Mac may pack fields this version cannot parse, and reporting it as "damaged"
    /// sends the user to show a fresh code when what they need is to update the app.
    func testAFutureVersionIsRejectedByVersionNotByShape() {
        let code = payload().encoded().replacingOccurrences(of: "FD2-", with: "FD9-")
        XCTAssertThrowsError(try PairingPayload(decoding: code)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .unsupportedVersion(9))
        }
    }

    /// The version is checked twice — once in the prefix, before a byte is decoded, and once
    /// in the packed body — so a hand-edited prefix cannot walk a mismatched body past the
    /// gate. This is v1's `testAPrefixVersionDisagreeingWithTheBodyIsMalformed`, re-expressed.
    func testAPrefixVersionDisagreeingWithThePackedVersionIsMalformed() throws {
        var bytes = try XCTUnwrap(Data(crockfordBase32: String(payload().encoded().dropFirst(4))))
        bytes[0] = 3
        let code = "FD2-" + bytes.crockfordBase32EncodedString()
        XCTAssertThrowsError(try PairingPayload(decoding: code)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .malformed)
        }
    }

    func testAnArbitraryStringIsRejectedRatherThanPartlyParsed() {
        for text in ["", "hello", "FD", "FD2", "FD2-", "flightdeck1:abc", "https://example.com"] {
            XCTAssertThrowsError(try PairingPayload(decoding: text), "accepted \(text)") { error in
                XCTAssertNotNil(error as? PairingPayloadError)
            }
        }
    }

    /// A symbol outside the alphabet — `I`, `L`, `O`, `U` are the ones a person substitutes —
    /// is damaged, not a different version.
    func testAnOutOfAlphabetSymbolIsMalformed() {
        let code = payload().encoded()
        let broken = String(code.dropLast()) + "U"
        XCTAssertThrowsError(try PairingPayload(decoding: broken)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .malformed)
        }
    }

    /// Truncation must fail rather than yield a short secret that would authenticate against
    /// nothing — the same ruling `PairedMac`'s decoder already makes for a corrupt secret.
    func testATruncatedCodeIsMalformedRatherThanAShortKey() {
        let code = payload().encoded()
        XCTAssertThrowsError(try PairingPayload(decoding: String(code.dropLast(20)))) { error in
            XCTAssertEqual(error as? PairingPayloadError, .malformed)
        }
    }

    /// v1's `testTheCodeIsNotAURL`, kept: a scanner that treated this as a link would hand it
    /// to Safari instead of to the app.
    func testTheCodeIsNotAURL() {
        XCTAssertNil(URL(string: payload().encoded())?.scheme)
    }

    /// The QR carries one endpoint. The rest are Bonjour's job, and the remembered-endpoint
    /// race exists for reconnects rather than for pairing (§8).
    func testOnlyTheFirstUsableEndpointSurvives() throws {
        let subject = payload(endpoints: ["10.0.0.5:5000", "192.168.1.20:53211", "127.0.0.1:9"])
        let decoded = try PairingPayload(decoding: subject.encoded())
        XCTAssertEqual(decoded.endpoints, ["10.0.0.5:5000"])
    }

    /// A Mac with no routable address still produces a scannable code — the phone will find it
    /// over Bonjour. An encoder that refused here would fail pairing on a machine that is
    /// perfectly pairable.
    func testAPayloadWithNoUsableEndpointStillRoundTrips() throws {
        let subject = payload(endpoints: [])
        let decoded = try PairingPayload(decoding: subject.encoded())
        XCTAssertEqual(decoded.endpoints, [])
        XCTAssertEqual(decoded.key.secret, subject.key.secret)
    }

    /// Names are length-prefixed, so a long one must be bounded rather than overflowing a
    /// single length byte and silently corrupting everything after it.
    func testAnOverlongNameIsTruncatedRatherThanCorruptingThePayload() throws {
        let subject = payload(
            macName: String(repeating: "M", count: 200),
            serviceName: String(repeating: "s", count: 200)
        )
        let decoded = try PairingPayload(decoding: subject.encoded())
        XCTAssertEqual(decoded.macName.count, 64)
        XCTAssertEqual(decoded.serviceName.count, 64)
        XCTAssertEqual(decoded.key.secret, subject.key.secret)
    }

    /// Non-ASCII names are routine — a Mac is named by its owner — and truncating UTF-8 by
    /// bytes can split a scalar. It must not produce a payload that fails to decode.
    func testANonASCIINameSurvives() throws {
        let subject = payload(macName: "Mac de Renée 🇫🇷")
        let decoded = try PairingPayload(decoding: subject.encoded())
        XCTAssertEqual(decoded.macName, "Mac de Renée 🇫🇷")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: compile failure — `value of type 'Data' has no member 'crockfordBase32EncodedString'` — and, once that resolves, `testTheCodeUsesOnlyTheCrockfordAlphabetAndItsPrefix` failing on the `flightdeck1:` prefix.

- [ ] **Step 3: Write the codec and the new encoding**

Replace everything in `Sources/FleetKit/PairingPayload.swift` from `public func encoded()` through the end of `init(decoding:)`, and replace the file's `Data` extension. Keep the type's stored properties, `id`, and `PairingPayloadError` exactly as they are.

```swift
    public static let currentVersion = 2
    /// The scheme half of the code, with the version spelled into it — `FD2-`.
    ///
    /// Two letters and a digit rather than `flightdeck2:`, and that is not brevity for its own
    /// sake: `F`, `D`, the digits and `-` are all in QR's *alphanumeric* charset, where
    /// lowercase letters and `:` are not. A single lowercase character forces the whole code
    /// into byte mode, which is roughly a third more modules for the same content.
    ///
    /// The version stays in the prefix, and that is load-bearing exactly as it was in v1: a
    /// payload from a newer Mac may pack fields this version cannot parse, so decoding it
    /// under this schema would fail as *damaged*. The phone shows different copy for damaged
    /// ("show a new code on your Mac") and too-new ("update the app"), which send the user in
    /// opposite directions.
    private static let prefix = "FD"
    /// One byte of length prefix per name, so 255 is the format's ceiling. 64 is the policy:
    /// `FleetService.derivedServiceName` already caps at 24 plus a suffix, and a Mac name
    /// longer than 64 bytes is being displayed on a phone, where it will be truncated anyway.
    private static let maxNameBytes = 64

    public func encoded() -> String {
        var bytes = Data()
        bytes.append(UInt8(version))
        bytes.append(contentsOf: withUnsafeBytes(of: key.slot.uuid) { Data($0) })
        bytes.append(key.secret)
        bytes.append(Self.packedEndpoint(endpoints.first))
        bytes.append(Self.packedName(serviceName))
        bytes.append(Self.packedName(macName))
        // No sorted-keys hazard here, unlike v1's JSON: this walks a fixed field order, so two
        // encodings of one payload are identical by construction rather than by a serializer
        // option somebody has to remember. `testEncodingTheSamePayloadTwiceGivesTheSameString`
        // still guards it, because the property matters more than the mechanism.
        return "\(Self.prefix)\(version)-" + bytes.crockfordBase32EncodedString()
    }

    /// IPv4 and port, or six zero bytes when there is nothing usable to pack.
    ///
    /// IPv4 only, matching `LocalEndpoints`: a link-local IPv6 address needs a zone index to
    /// be dialable and would pack a candidate that can never connect. A Mac with no routable
    /// v4 address still produces a scannable code — the phone finds it over Bonjour.
    private static func packedEndpoint(_ text: String?) -> Data {
        guard let text,
              let colon = text.lastIndex(of: ":"),
              let port = UInt16(text[text.index(after: colon)...])
        else { return Data(repeating: 0, count: 6) }
        let octets = text[..<colon].split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return Data(repeating: 0, count: 6) }
        return Data(octets) + Data([UInt8(port >> 8), UInt8(port & 0xFF)])
    }

    private static func unpackedEndpoint(_ bytes: Data) -> [String] {
        let octets = [UInt8](bytes.prefix(4))
        let port = UInt16(bytes[bytes.startIndex + 4]) << 8 | UInt16(bytes[bytes.startIndex + 5])
        guard octets.contains(where: { $0 != 0 }) || port != 0 else { return [] }
        return ["\(octets[0]).\(octets[1]).\(octets[2]).\(octets[3]):\(port)"]
    }

    /// A one-byte length followed by UTF-8, truncated on a *scalar* boundary.
    ///
    /// `String.prefix(_:)` counts characters, not bytes, so it cannot overflow the length byte
    /// on its own — but a 64-character name of emoji is 256 bytes. Truncating the UTF-8 by
    /// bytes instead would split a scalar and produce a name that fails to decode. So this
    /// drops whole characters until the encoding fits.
    private static func packedName(_ name: String) -> Data {
        var trimmed = String(name.prefix(maxNameBytes))
        while Data(trimmed.utf8).count > 255 { trimmed = String(trimmed.dropLast()) }
        let utf8 = Data(trimmed.utf8)
        return Data([UInt8(utf8.count)]) + utf8
    }

    public init(decoding code: String) throws {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.hasPrefix(Self.prefix), let dash = trimmed.firstIndex(of: "-")
        else { throw PairingPayloadError.notAPairingCode }

        let digits = trimmed[
            trimmed.index(trimmed.startIndex, offsetBy: Self.prefix.count)..<dash
        ]
        // Digits only, not merely `Int`-parseable: `Int` accepts a leading `-` or `+`, so
        // without this `FD+2-…` would sail past the gate as version 2.
        guard !digits.isEmpty,
              digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let version = Int(digits)
        else { throw PairingPayloadError.notAPairingCode }
        // Before a byte is decoded — see `prefix`.
        guard version == Self.currentVersion else {
            throw PairingPayloadError.unsupportedVersion(version)
        }

        guard let bytes = Data(crockfordBase32: String(trimmed[trimmed.index(after: dash)...])),
              bytes.count >= 56
        else { throw PairingPayloadError.malformed }
        // The body repeats the version so a hand-edited prefix cannot walk a mismatched body
        // past the gate above.
        guard Int(bytes[0]) == version else { throw PairingPayloadError.malformed }

        let slotBytes = [UInt8](bytes[1..<17])
        let slot = UUID(uuid: (
            slotBytes[0], slotBytes[1], slotBytes[2], slotBytes[3],
            slotBytes[4], slotBytes[5], slotBytes[6], slotBytes[7],
            slotBytes[8], slotBytes[9], slotBytes[10], slotBytes[11],
            slotBytes[12], slotBytes[13], slotBytes[14], slotBytes[15]
        ))
        // `Data(...)`, not the bare slice: a slice of `bytes` keeps a non-zero `startIndex`,
        // and a 32-byte secret indexed from 17 is a trap for the next caller who subscripts it.
        let secret = Data(bytes[17..<49])
        let endpoints = Self.unpackedEndpoint(bytes[49..<55])

        var cursor = 55
        guard let serviceName = Self.readName(from: bytes, cursor: &cursor),
              let macName = Self.readName(from: bytes, cursor: &cursor)
        else { throw PairingPayloadError.malformed }

        self.init(
            version: version, key: FleetDeviceKey(slot: slot, secret: secret),
            macName: macName, serviceName: serviceName, endpoints: endpoints
        )
    }

    /// One length-prefixed name, advancing `cursor`. `nil` for a length that runs off the end
    /// or bytes that are not UTF-8 — both of which mean the code is damaged rather than short.
    private static func readName(from bytes: Data, cursor: inout Int) -> String? {
        guard cursor < bytes.count else { return nil }
        let length = Int(bytes[cursor])
        cursor += 1
        guard cursor + length <= bytes.count else { return nil }
        let name = String(data: Data(bytes[cursor..<(cursor + length)]), encoding: .utf8)
        cursor += length
        return name
    }
```

Then replace the file's trailing `Data` extension with:

```swift
extension Data {
    /// Crockford base32 — `0123456789ABCDEFGHJKMNPQRSTVWXYZ`, the same alphabet
    /// `PairingCode` uses, and for a different reason worth naming: there it survives being
    /// read aloud; here it keeps the QR inside its *alphanumeric* encoding mode, which is
    /// roughly a third denser than byte mode for the same content. base64url would not — it
    /// has lowercase in it.
    ///
    /// No padding character. The final symbol carries whatever bits are left, shifted up, so
    /// the length of the string determines the length of the data and nothing has to be
    /// stripped on the way back.
    func crockfordBase32EncodedString() -> String {
        var out = ""
        out.reserveCapacity((count * 8 + 4) / 5)
        var buffer = 0
        var bits = 0
        for byte in self {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(Data.crockfordAlphabet[(buffer >> bits) & 0x1F])
                // Masked every drain, so `buffer` never accumulates high bits it will not use
                // — over a long payload an unmasked accumulator overflows `Int`.
                buffer &= (1 << bits) - 1
            }
        }
        if bits > 0 { out.append(Data.crockfordAlphabet[(buffer << (5 - bits)) & 0x1F]) }
        return out
    }

    init?(crockfordBase32 text: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count * 5 / 8)
        var buffer = 0
        var bits = 0
        for character in text {
            guard let value = Data.crockfordAlphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        self = Data(bytes)
    }

    fileprivate static let crockfordAlphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
}
```

`PairedMac` and `PairingPayload` both used `base64URLEncodedString()`/`init(base64URLEncoded:)`; `PairedMac` still does, so **keep those two methods** — add the base32 pair alongside them rather than replacing them.

The tests reach `crockfordBase32EncodedString()` and `init(crockfordBase32:)` from `Tests`, so both must be `public` on the extension (the alphabet stays `fileprivate`).

- [ ] **Step 4: Add the density assertion**

In `Tests/FlightDeckTests/PairingCodeImageTests.swift`, replace the `code()` helper's payload with a v2 one (it already builds a `PairingPayload`, so only the comment changes) and append:

```swift
    /// The measurement §8 is actually about. The QR's extent is its module count, so this
    /// compares the generated code against the same content in v1's shape — rather than
    /// asserting a QR version, which depends on an encoding-mode choice CoreImage does not
    /// document.
    func testThePackedPayloadProducesAMateriallySmallerQR() throws {
        let subject = PairingPayload(
            key: .mint(), macName: "Nate's MacBook Pro",
            serviceName: "flightdeck-macbook-a1b2", endpoints: ["192.168.1.20:53211"]
        )
        let v1Body = #"{"eps":["192.168.1.20:53211"],"name":"Nate's MacBook Pro","psk":"\#(subject.key.secret.base64EncodedString())","slot":"\#(subject.key.slot.uuidString)","svc":"flightdeck-macbook-a1b2","v":1}"#
        let v1 = "flightdeck1:" + Data(v1Body.utf8).base64EncodedString()

        let packedModules = try XCTUnwrap(modules(of: subject.encoded()))
        let legacyModules = try XCTUnwrap(modules(of: v1))
        XCTAssertLessThan(
            packedModules, Int(Double(legacyModules) * 0.75),
            "packed QR is \(packedModules) modules against v1's \(legacyModules)"
        )
    }

    /// The generator's output is one point per module plus a quiet zone, so its extent is the
    /// module count. Read before scaling.
    private func modules(of code: String) -> Int? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        return filter.outputImage.map { Int($0.extent.width) }
    }
```

`PairingCodeImageTests` already imports `CoreImage`; add `import CoreImage.CIFilterBuiltins` if it is not there.

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1249** tests, 0 failures. (The old `PairingPayloadTests` had 10 methods; the new one has 14, and `PairingCodeImageTests` gains 1 — net +5 on 1244.)

If `testThePackedPayloadProducesAMateriallySmallerQR` fails, read the two numbers in its message before changing anything. A ratio around 0.6 means CoreImage chose alphanumeric mode; around 0.75–0.8 means byte mode and the packing is still worth having. **Do not loosen the threshold to make it pass** — if it lands above 0.75, record the measured numbers in `docs/FOLLOWUPS.md` (Task 5 already opens that entry) and raise it with the user, because that is the spec's §8 claim not being met.

- [ ] **Step 6: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/PairingPayload.swift Tests/FlightDeckTests/PairingPayloadTests.swift Tests/FlightDeckTests/PairingCodeImageTests.swift
git commit -m "feat: a QR that carries bytes instead of JSON"
```

---

### Task 2: Show the code on the Mac

**Files:**
- Modify: `Sources/FlightDeck/Preferences/UI/PairingCodeView.swift`
- Modify: `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift`
- Test: `Tests/FlightDeckTests/PairingCodeSheetTests.swift` (new)

**Interfaces:**
- Consumes: `ArmedPairing` (channel plan, Task 8) — `.payload: PairingPayload`, `.code: PairingCode`; `PairingCode.formatted`.
- Produces: `PairingCodeSheet(service:preferences:window:)` — the `payload:` label is replaced by `window:`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/PairingCodeSheetTests.swift`:

```swift
import XCTest
import FleetKit
@testable import FlightDeck

/// The sheet's own logic, which is the part a screenshot cannot check: that the string put in
/// front of the user is the code the listener is actually holding, in the grouped form.
///
/// SwiftUI rendering is not asserted here — `UITests` and the manual checklist cover what the
/// user sees. What is asserted is the value, because the failure mode worth catching is a
/// sheet that displays one window's code beside another window's QR.
@MainActor
final class PairingCodeSheetTests: XCTestCase {
    private func window() -> ArmedPairing {
        PairingArmer().arm(
            macName: "Nate's MacBook Pro",
            serviceName: "flightdeck-macbook-a1b2",
            endpoints: ["192.168.1.20:53211"]
        )
    }

    func testTheDisplayedCodeIsTheWindowsCodeInGroupedForm() {
        let armed = window()
        let displayed = PairingCodeSheet.displayedCode(for: armed)
        XCTAssertEqual(displayed, armed.code.formatted)
        XCTAssertEqual(displayed.count, 14)
        XCTAssertEqual(displayed.filter { $0 == "-" }.count, 2)
    }

    /// The two halves of one window must come from one value. A sheet handed a code and a
    /// payload separately can draw a code from one window beside a QR from another, and the
    /// user would have no way to tell.
    func testTheQRAndTheCodeComeFromTheSameWindow() {
        let armed = window()
        let sheetCode = PairingCodeSheet.displayedCode(for: armed)
        let qrPayload = PairingCodeSheet.qrCode(for: armed)
        XCTAssertEqual(sheetCode, armed.code.formatted)
        XCTAssertEqual(qrPayload, armed.payload.encoded())
        XCTAssertTrue(qrPayload.contains(armed.payload.key.slot.uuidString) == false)
    }

    /// Every character on screen is from the code's alphabet, so the four symbols a person
    /// substitutes — `I`, `L`, `O`, `U` — never appear in something they are asked to read
    /// aloud and type.
    func testTheDisplayedCodeContainsNoAmbiguousCharacters() {
        for _ in 0..<50 {
            let displayed = PairingCodeSheet.displayedCode(for: window())
            XCTAssertFalse(displayed.contains { "ILOU".contains($0) })
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: compile failure — `type 'PairingCodeSheet' has no member 'displayedCode'`.

- [ ] **Step 3: Rework the sheet**

In `Sources/FlightDeck/Preferences/UI/PairingCodeView.swift`, change `PairingCodeSheet` to take the window, and expose the two derivations as static functions so they are assertable without rendering:

```swift
struct PairingCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var service: FleetService
    @ObservedObject var preferences: PreferencesStore
    let window: ArmedPairing

    /// Both halves of what is on screen, derived from one value.
    ///
    /// Static, and exposed, because this is the part worth testing: a sheet that drew a code
    /// from one window beside a QR from another would look completely normal, and the user
    /// would find out by typing a code that does not work.
    static func displayedCode(for window: ArmedPairing) -> String { window.code.formatted }
    static func qrCode(for window: ArmedPairing) -> String { window.payload.encoded() }

    private let code: String
    private let typedCode: String
    private let codeImage: CGImage?

    init(service: FleetService, preferences: PreferencesStore, window: ArmedPairing) {
        self.service = service
        self.preferences = preferences
        self.window = window
        // Encoded once, at init, for the reason the old comment gives: `body` re-runs every
        // second for the countdown, and rebuilding a 320px bitmap per tick redraws a QR that
        // has not changed.
        let code = Self.qrCode(for: window)
        self.code = code
        self.typedCode = Self.displayedCode(for: window)
        self.codeImage = PairingCodeImage.cgImage(for: code, size: 320)
    }
```

Change `armedUntil` to read `window.payload.key.slot`, and `Text(payload.macName)` to `Text(window.payload.macName)`.

Then replace the `DisclosureGroup` with the code itself, promoted out of the disclosure — it is no longer a 300-character wall to hide, it is the second way to pair:

```swift
            // Promoted out of a `DisclosureGroup`. It was hidden because it was 300 characters
            // of base64 that nobody would type; twelve grouped symbols are a peer of the QR,
            // and burying the only route that works without a camera behind a disclosure
            // triangle is how a simulator user concludes the app cannot pair at all.
            VStack(spacing: 4) {
                Text("Or type this code")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(typedCode)
                    // Monospaced and large: this is read off one screen and typed into
                    // another, often from across a room.
                    .font(.system(.title2, design: .monospaced).weight(.medium))
                    .tracking(2)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("pairing-typed-code")
                Text("Only works on this Wi-Fi network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320)
            .fixedSize(horizontal: false, vertical: true)
```

The `.fixedSize(horizontal: false, vertical: true)` is the same fix the explanatory `Text` above it already carries: a sheet is sized once from its content's *ideal* height, and a wrapping label's ideal height is one line, so without it the sheet comes out short and truncates.

- [ ] **Step 4: Pass the window through**

In `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift`:

```swift
        .sheet(item: $pairingWindow) { window in
            PairingCodeSheet(service: service, preferences: preferences, window: window)
        }
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1252** tests, 0 failures (1249 + 3).

- [ ] **Step 6: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/PairingCodeView.swift Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift Tests/FlightDeckTests/PairingCodeSheetTests.swift
git commit -m "feat: twelve symbols on the Mac, beside the QR rather than under it"
```

---

### Task 3: Type the code on the phone

**Files:**
- Modify: `Sources/FleetKit/PairingCode.swift` (add `grouped(partial:)`)
- Modify: `Sources/FlightDeckMobile/PairingScreen.swift`
- Test: `Tests/FlightDeckTests/PairingCodeTests.swift` (append)

**Interfaces:**
- Consumes: `PairingCode.init?(normalizing:)`, `.formatted` (both shipped).
- Produces: `PairingCode.grouped(partial: String) -> String` — a format-as-you-type helper, and the only piece of the phone's typed field that can be tested on this machine.

**Verification gap, stated up front.** `PairingScreen` is iOS-only SwiftUI: `./scripts/build-ios.sh` compiles it and nothing on this machine runs it. So everything worth asserting is pushed into `PairingCode.grouped(partial:)`, in FleetKit, where the macOS suite reaches it — the same discipline `FleetModel`'s doc comment already states. What is left over is genuinely unverifiable here and goes on the checklist in Task 5, not into a test that pretends otherwise.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/PairingCodeTests.swift`:

```swift
    /// The field rewrites what the user types as they type it, so the string on screen always
    /// looks like the string on the Mac. Without this the two are compared by eye across a
    /// room while one of them has hyphens and the other does not.
    func testGroupingInsertsTheHyphensAsYouType() {
        XCTAssertEqual(PairingCode.grouped(partial: ""), "")
        XCTAssertEqual(PairingCode.grouped(partial: "AB"), "AB")
        XCTAssertEqual(PairingCode.grouped(partial: "ABCD"), "ABCD")
        XCTAssertEqual(PairingCode.grouped(partial: "ABCDE"), "ABCD-E")
        XCTAssertEqual(PairingCode.grouped(partial: "ABCDEFGH"), "ABCD-EFGH")
        XCTAssertEqual(PairingCode.grouped(partial: "ABCDEFGHJKMN"), "ABCD-EFGH-JKMN")
    }

    /// `.textInputAutocapitalization(.characters)` asks the keyboard to send uppercase; a
    /// hardware keyboard, a paste, and dictation all ignore it. The rewrite is what actually
    /// guarantees it, which is why the field cannot rely on the modifier alone.
    func testGroupingUppercasesWhateverArrives() {
        XCTAssertEqual(PairingCode.grouped(partial: "abcdefgh"), "ABCD-EFGH")
    }

    /// Crockford's own substitutions, applied on input rather than rejected. The alphabet
    /// omits `I`, `L` and `O` precisely because a person reading a code aloud produces them —
    /// so typing one is the expected mistake, and the expected mistake should work.
    func testGroupingMapsTheAmbiguousLettersRatherThanRejectingThem() {
        XCTAssertEqual(PairingCode.grouped(partial: "OIL"), "011")
        XCTAssertEqual(PairingCode.grouped(partial: "oil"), "011")
    }

    /// `U` is dropped rather than mapped: Crockford excludes it to avoid accidental
    /// obscenity, and it has no digit to stand for. Everything else outside the alphabet —
    /// spaces, the hyphens the user retypes, punctuation — is dropped for the same reason
    /// `init(normalizing:)` strips them: they are presentation, not content.
    func testGroupingDropsWhatItCannotMap() {
        XCTAssertEqual(PairingCode.grouped(partial: "AB CD-EF!GH"), "ABCD-EFGH")
        XCTAssertEqual(PairingCode.grouped(partial: "ABUCD"), "ABCD")
    }

    /// Twelve symbols and no more. Without the cap the field grows past the code's length and
    /// the user's own extra keystroke silently invalidates something that was already correct.
    func testGroupingStopsAtTwelveSymbols() {
        let long = PairingCode.grouped(partial: "ABCDEFGHJKMNPQRSTV")
        XCTAssertEqual(long, "ABCD-EFGH-JKMN")
        XCTAssertEqual(long.filter { $0 != "-" }.count, 12)
    }

    /// The formatter and the parser have to agree, or the field shows a string the phone then
    /// refuses. Re-running the formatter over its own output must change nothing, and its
    /// output must parse back to the code it came from.
    func testAFormattedCodeIsAFixedPointOfTheFormatterAndStillParses() throws {
        for _ in 0..<50 {
            let code = PairingCode.mint()
            let grouped = PairingCode.grouped(partial: code.formatted)
            XCTAssertEqual(grouped, code.formatted)
            XCTAssertEqual(PairingCode(normalizing: grouped), code)
        }
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`

Expected: compile failure — `type 'PairingCode' has no member 'grouped'`.

- [ ] **Step 3: Add the formatter**

In `Sources/FleetKit/PairingCode.swift`, add above `public var formatted`:

```swift
    /// What a partially-typed code should look like on screen right now.
    ///
    /// Three jobs, and each of them exists because the field cannot get it for free:
    ///
    /// - **Uppercase.** `.textInputAutocapitalization(.characters)` is a hint to the software
    ///   keyboard. A hardware keyboard, a paste and dictation all ignore it, so the rewrite is
    ///   what actually guarantees the case.
    /// - **Group into `XXXX-XXXX-XXXX`.** The Mac shows hyphens; a field that did not would
    ///   have the user comparing two differently-shaped strings across a room.
    /// - **Map the letters the alphabet omits.** `O` → `0`, `I`/`L` → `1`, per Crockford. The
    ///   alphabet omits them *because* a person reading a code aloud produces them, so
    ///   rejecting them would punish exactly the mistake the alphabet was chosen to absorb.
    ///   `U` is dropped instead: Crockford excludes it to avoid accidental obscenity and it
    ///   stands for no digit.
    ///
    /// Capped at twelve symbols so a stray keystroke past the end cannot invalidate a code
    /// that was already right.
    ///
    /// This is presentation only. `init(normalizing:)` is what decides whether a code is
    /// valid, and it is deliberately not called from here — a field that refused input until
    /// it was complete would reject every prefix of a correct code.
    public static func grouped(partial input: String) -> String {
        var symbols = ""
        for character in input.uppercased() {
            let mapped: Character?
            switch character {
            case "O": mapped = "0"
            case "I", "L": mapped = "1"
            default: mapped = alphabet.contains(character) ? character : nil
            }
            guard let mapped else { continue }
            symbols.append(mapped)
            if symbols.count == symbolCount { break }
        }
        return stride(from: 0, to: symbols.count, by: 4).map {
            String(symbols[symbols.index(symbols.startIndex, offsetBy: $0)...].prefix(4))
        }.joined(separator: "-")
    }
```

`alphabet` and `symbolCount` are already `private static` on the type, so both are in scope.

- [ ] **Step 4: Rebuild the phone's typed field**

In `Sources/FlightDeckMobile/PairingScreen.swift`, replace the `DisclosureGroup` block with a first-class section. The QR scanner stays exactly as it is — nothing in this task touches `QRScannerView`, `QRScannerContainerView` or `QRScannerController`, whose lifecycle took three review rounds to get right.

```swift
            // Not behind a `DisclosureGroup` any more. It was hidden because it asked for 300
            // characters of base64; twelve symbols are a peer of the QR, and on a simulator —
            // which has no camera — this is the only route that works at all.
            VStack(alignment: .leading, spacing: 8) {
                Text("Or type the code from your Mac")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("XXXX-XXXX-XXXX", text: $typed)
                    // `.characters`, not `.never`: the code is uppercase Crockford base32, and
                    // a lowercase keyboard makes the user shift twelve times. The modifier is
                    // a hint the software keyboard may honour — `PairingCode.grouped` is what
                    // actually guarantees the case, for a paste or a hardware keyboard.
                    .textInputAutocapitalization(.characters)
                    // A twelve-symbol code is exactly the shape autocorrect turns into a word.
                    .autocorrectionDisabled()
                    .font(.system(.title2, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: typed) { _, latest in
                        // Rewritten on every keystroke, so the field always looks like the
                        // Mac's screen. Guarded against re-entrancy: assigning an unchanged
                        // value would re-fire this on some SwiftUI versions.
                        let formatted = PairingCode.grouped(partial: latest)
                        if formatted != latest { typed = formatted }
                        // Typing again clears a stale verdict; leaving it up next to a
                        // half-corrected code says the correction failed.
                        failure = nil
                    }

                Button("Pair") { pairByTyping() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    // Enabled only on a complete code, so the button cannot be pressed into a
                    // "that doesn't look right" the user has no way to act on yet.
                    .disabled(PairingCode(normalizing: typed) == nil && typed.count < 14)

                Text("Both devices need to be on the same Wi-Fi network.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

and add, beside `adopt(_:)`:

```swift
    /// The typed path. The checksum is checked **here**, before anything opens a socket — a
    /// mistyped code must cost no attempt against the Mac's three (spec §7), and "that code
    /// doesn't look right" and "pairing failed" send the user to different places.
    private func pairByTyping() {
        guard let code = PairingCode(normalizing: typed) else {
            failure = "That code doesn't look right. Check it against your Mac."
            return
        }
        failure = nil
        model.pair(code: code)
    }
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1258** tests, 0 failures (1252 + 6).

- [ ] **Step 6: Verify iOS still builds**

Run: `./scripts/build-ios.sh 2>&1 | grep -E "BUILD SUCCEEDED|TYPE-CHECK PASSED|error:"`

This will fail on `model.pair(code:)` until Task 4 lands. That is the expected order — write Task 4 next and run this again at its Step 5. Do **not** stub `pair(code:)` here to make the build green; a stub that silently does nothing is exactly the shape that survives review.

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/PairingCode.swift Sources/FlightDeckMobile/PairingScreen.swift Tests/FlightDeckTests/PairingCodeTests.swift
git commit -m "feat: a twelve-character field that formats itself"
```

---

### Task 4: Find the Mac and pair

**Files:**
- Modify: `Sources/FlightDeckMobile/FleetModel.swift`
- Test: none — see the note below.

**Interfaces:**
- Consumes: `PairingRunner` (channel plan, Task 7) — `init(queue:)`, `start(code:)`, `cancel()`, `onProgress`, `onPaired`, `Progress`; `PairingInitiator.Failure`; `PairedMac(key:macName:serviceName:endpoints:lastSeq:)`; `PairedMacStoring.save(_:) throws`.
- Produces: `FleetModel.pair(code: PairingCode)`; `FleetModel.pairingProgress: PairingRunner.Progress?`; `FleetModel.pairingFailure: String?`.

**Why no test.** `FleetModel` is `@MainActor` iOS-only glue over types that are already tested in `FleetKit` against real sockets — `PairingRunner`'s whole 0/1/2+ walk is proved by `PairingRunnerTests`, and the delivered key reaching the fleet is proved by `testATypedCodePairsAndTheDeliveredKeyReachesTheFleet`. There is no iOS test host on this machine, and moving this glue into FleetKit to test it would drag `PairedMacStoring` failure handling and SwiftUI observation across the module boundary for no gain. Keeping it thin is what keeps that true; the moment it grows a decision worth asserting, that decision belongs in FleetKit.

- [ ] **Step 1: Add the pairing state**

In `Sources/FlightDeckMobile/FleetModel.swift`, add beside `lastLive`:

```swift
    /// Where a typed pairing has got to, or `nil` when none is running. Drives the pairing
    /// screen's progress line; `nil` again the moment it ends, either way.
    private(set) var pairingProgress: PairingRunner.Progress?
    /// Copy for a pairing that ended badly. Separate from `pairingProgress` because the screen
    /// keeps showing this after the run is over, and a progress value that lingered would
    /// leave a spinner beside an error.
    private(set) var pairingFailure: String?

    @ObservationIgnored private var runner: PairingRunner?
```

- [ ] **Step 2: Add the pairing method**

```swift
    /// Pair by typed code: browse for armed Macs, try each in turn, store whichever accepts.
    ///
    /// Takes a `PairingCode`, never a `String` — the checksum is checked in `PairingScreen`
    /// before this is reached, and the type is what makes "a failed checksum never becomes an
    /// attempt" (spec §7) structural rather than a rule.
    func pair(code: PairingCode) {
        // Replaces any run already in flight. Without this a second tap orphans the first
        // runner, which keeps browsing and can complete a pairing the user has moved on from.
        runner?.cancel()
        pairingFailure = nil
        pairingProgress = .searching

        let runner = PairingRunner()
        runner.onProgress = { [weak self] progress in
            // `MainActor.assumeIsolated`, not a `Task` hop, for the reason `connect()`'s own
            // comment gives: `PairingRunner`'s queue defaults to `.main`, so this genuinely IS
            // the main queue, and a hop would let two progress updates land out of order.
            MainActor.assumeIsolated {
                guard let self else { return }
                switch progress {
                case .searching, .trying:
                    self.pairingProgress = progress
                case .paired:
                    self.pairingProgress = nil
                case .noMacsFound:
                    self.pairingProgress = nil
                    self.pairingFailure =
                        "Can't find that Mac on this network. Scan the QR code instead."
                case .failed(let failure):
                    self.pairingProgress = nil
                    self.pairingFailure = Self.message(for: failure)
                }
            }
        }
        runner.onPaired = { [weak self] key, serviceName, macName in
            MainActor.assumeIsolated { self?.adopt(key: key, serviceName: serviceName, macName: macName) }
        }
        self.runner = runner
        runner.start(code: code)
    }

    /// Stores what the exchange delivered and connects.
    ///
    /// **No endpoints, deliberately.** Typed pairing is LAN-only by design (spec §11), and
    /// `FleetConnector` reaches a Mac with an empty remembered list purely by browsing
    /// `_flightdeck._tcp` for `serviceName` — which is why `serviceName` here is the Bonjour
    /// instance name the runner actually dialled, not anything derived. `macName` comes out of
    /// the seal, so it is authenticated; the browse result's display name was not.
    private func adopt(key: FleetDeviceKey, serviceName: String, macName: String) {
        let mac = PairedMac(
            key: key, macName: macName, serviceName: serviceName, endpoints: []
        )
        do {
            try store.save(mac)
        } catch {
            // The exchange succeeded and the phone cannot keep the result. Saying "try again"
            // would be a lie — the retry runs the identical keychain write.
            pairingFailure = PairingScreen.message(for: error)
            return
        }
        self.mac = mac
        runner = nil
        connect()
    }

    /// Each failure says what to do next. One message for all of them would leave a user
    /// retyping a code whose window is already burned.
    private static func message(for failure: PairingInitiator.Failure) -> String {
        switch failure {
        case .wrongCode:
            return "No Mac on this network accepted that code. Check it against your Mac's screen."
        case .attemptsExhausted:
            return "Too many tries. Show a new code on your Mac and start again."
        case .connectionFailed:
            return "Couldn't reach that Mac. Check you're both on the same Wi-Fi."
        case .malformedResponse:
            return "That Mac answered with something Flight Deck didn't understand. Update both apps."
        }
    }
```

`unpair()` must also drop a run in flight — add `runner?.cancel()` and `runner = nil` as its first lines, and clear `pairingProgress`/`pairingFailure` alongside `lastLive`.

**Check the store's signature before writing this.** `PairedMacStore.save` was changed to throw (`PairedMacStoreError`) by concurrent work on this branch, and `PairingScreen.message(for:)` already has an overload for it. If `save` is still non-throwing in the tree you are working in, drop the `do`/`catch` — do not add a `try?`.

- [ ] **Step 3: Show progress on the pairing screen**

In `Sources/FlightDeckMobile/PairingScreen.swift`, replace the failure `Text` at the bottom with both states:

```swift
            if let progress = model.pairingProgress {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(Self.message(for: progress))
                        .foregroundStyle(.secondary)
                }
            } else if let message = failure ?? model.pairingFailure {
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
```

and add:

```swift
    /// Progress copy. `searching` names the wait a Bonjour browse imposes, so a five-second
    /// spinner reads as work rather than as a hang; `trying` names the Mac so a user with two
    /// of them can see which one is being asked.
    static func message(for progress: PairingRunner.Progress) -> String {
        switch progress {
        case .searching: return "Looking for your Mac…"
        case .trying(let displayName): return "Trying \(displayName)…"
        case .noMacsFound, .failed, .paired: return ""
        }
    }
```

`PairingScreen` needs `import FleetKit`, which it already has.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`

Expected: **1258** tests, 0 failures — unchanged from Task 3. This task adds no macOS-reachable code.

- [ ] **Step 5: Verify iOS builds — this is this task's real gate**

Run: `./scripts/build-ios.sh 2>&1 | tail -40`

Expected: three successes. Read the output for which of the two the script did for `FlightDeckMobile`:

- **`** FlightDeckMobile BUILD SUCCEEDED **`** — a real build, and Swift 6's region-based isolation checks ran. `MainActor.assumeIsolated` around a non-`Sendable` capture is the kind of thing this catches and a type-check does not.
- **`TYPE-CHECK PASSED (build skipped…)`** — no iOS runtime installed. Then the isolation checks did **not** run, and this task is not fully verified on this machine. Say so in the commit message rather than letting a green line stand for more than it is. Installing the runtime (`xcodebuild -downloadPlatform iOS`) turns this into a real check.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeckMobile/FleetModel.swift Sources/FlightDeckMobile/PairingScreen.swift
git commit -m "feat: pair by typing, over Bonjour"
```

---

### Task 5: Amend the specs and say what is unverified

**Files:**
- Modify: `docs/superpowers/specs/2026-08-18-mobile-companion-design.md` (§3, two amendments)
- Modify: `docs/MOBILE.md` (the checklists)
- Modify: `docs/FOLLOWUPS.md` (two entries)

**Interfaces:** none. Documentation only, and it is a task rather than a footnote because the spec it amends is the one a future reader will find first.

- [ ] **Step 1: Amend §3 of the mobile-companion spec**

This is [the short-pairing-code spec's §9](../specs/2026-08-21-short-pairing-code-design.md#9-what-this-changes-in-the-original-spec), applied. In `docs/superpowers/specs/2026-08-18-mobile-companion-design.md`, find the paragraph beginning "This is **trust-on-first-use over the user's own screen**" and replace its last sentence — "It is not a PAKE and does not defend against someone photographing the screen while it is up." — with:

```markdown
There are now two paths onto that screen, and they differ in one respect only. The **QR path**
is trust-on-first-use exactly as described: the code carries the device key itself, and the
screen it is displayed on is what secures it. The **typed path** carries no key — twelve
characters, 55 bits — and uses SPAKE2 plus a three-guess limit to make those 55 bits safe to
put on a wire. That PAKE is a prerequisite for shortening the code, **not a strengthening of
this trust boundary**: photographing a code during the window still pairs the photographer,
on either path. See
[`2026-08-21-short-pairing-code-design.md`](2026-08-21-short-pairing-code-design.md) §3.
```

Then find the bullet "From then on **every connection is TLS with that pre-shared key**…" and append to it:

```markdown
  There is exactly one exception, and it is scoped and named: the **pairing listener**, which
  exists only while a window is armed, carries a **public bootstrap PSK** compiled into both
  binaries, and can reach no application code at all — it speaks a frame vocabulary with no
  `hello` and no `cmd` in it. It provides no confidentiality and nothing depends on it for
  any: the device key crossing it is sealed under a SPAKE2-derived key. See
  [`2026-08-21-short-pairing-code-design.md`](2026-08-21-short-pairing-code-design.md) §6.
```

- [ ] **Step 2: Rewrite the QR-path checklist items in `docs/MOBILE.md`**

Item 2 of "The manual checklist" currently describes typing a 300-character code. Replace it, and add three items after item 12:

```markdown
2. Pair by typing the twelve-character code instead of scanning; same outcome. This is not a
   lesser path — it is what a user falls back to when they decline the camera, and it is the
   only pairing route that works at all on a simulator.

13. **Type a code with one character wrong.** The phone says "That code doesn't look right"
    *without* contacting the Mac — and the Mac's next three attempts are still available, so
    the correct code entered immediately afterwards pairs. A checksum that had stopped working
    would show up here as a generic pairing failure and a spent attempt.
14. **Type a wrong-but-well-formed code three times, then the correct one.** The third failure
    burns the window: the Mac's sheet closes, and the correct code afterwards is refused. Arm
    again and it works.
15. **Arm two Macs at once and type the second one's code into the phone.** It pairs with the
    second. Then, on the *first* Mac, enter its own correct code — it still has all three
    attempts minus the one the phone spent on it. The budget is per-Mac (spec §7); a global
    counter would have left the first Mac short.
```

- [ ] **Step 3: Add the cross-process criterion to `docs/MOBILE.md`**

Append a new section after "A second checklist: the iOS plumbing". Its wording matters more than most: this is the claim `docs/FOLLOWUPS.md` had to be corrected for once already.

```markdown
## The cross-process check, and exactly what it proves

**Run a pairing from a real `FlightDeckMobile` (simulator or device) against a real Flight
Deck on the Mac, using the typed code.** Both apps built from this tree, two processes, a real
network. It is an acceptance criterion for the pairing work, not a unit test, because nothing
on this machine can run an iOS process under XCTest.

**What it catches: caller-side asymmetry.** The two ends disagreeing about which of them is
the SPAKE2 initiator, about the two names they pass to `SPAKE2Session`, or about the order in
which they assemble the transcript. Those are decisions made in `PairingListener.handle` and
`PairingInitiator.start` — one file each, written by different hands at different times — and
a disagreement in any of them produces confirmations that never match. The Mac then reports
"wrong code" for a correctly typed one and spends an attempt saying so, three times, until the
user is locked out with every log line insisting they made a typo. A cross-process run is a
real check on that.

**What it does NOT catch: a consistent role or name swap inside `SPAKE2Session`.** Both ends
compile the same `FleetKit`, so a swap applied in the wrapper is applied identically on both
sides of the wire and survives a cross-process test exactly as it survives an in-process one.
This was demonstrated rather than argued: two mutants — roles swapped, and the two name
arguments swapped — each passed all seventeen SPAKE2 and `PairingSecrets` tests.

What closes *that* is a second implementation of the **caller**, not a second process.
`SPAKE2SessionTests.testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder` drives one side
through BoringSSL's raw C API with a literal `spake2_role_alice` and the argument order
`curve25519.h` declares, the other through `SPAKE2Session`, and requires the derived keys to
agree. Both mutants fail it. That is in place, in process, and it is the check that matters
for the wrapper. `docs/FOLLOWUPS.md`'s "Pairing crypto foundation" entry previously claimed
the cross-process run was what closed this gap; that was wrong and is corrected there. Do not
reintroduce the stronger claim here.
```

- [ ] **Step 4: Record the two follow-ups**

In `docs/FOLLOWUPS.md`, under "Deliberate choices worth remembering (not defects)", add:

```markdown
- **The packed QR keeps the Mac's display name and Bonjour service name, where the
  short-pairing-code spec's §8 said it could drop both.** §8's reasoning does not hold against
  the shipped code: `FleetSnapshot` (`Sources/FleetKit/Wire.swift`) carries no Mac identity at
  all, so the display name does *not* "arrive with the first snapshot"; and
  `FleetService.serviceName` is `<sanitised host>-<install suffix>`, stable per Mac and not
  derivable from a slot — `FleetConnector.startBrowsing` matches Bonjour results against
  exactly that string, so a phone without it cannot rediscover its Mac after either moved.
  Carrying both, length-prefixed, costs about 42 bytes of a ~97-byte payload. The measured QR
  improvement is in `PairingCodeImageTests.testThePackedPayloadProducesAMateriallySmallerQR`;
  read the numbers in its failure message rather than trusting §8's predicted QR version,
  which assumed a ~55-byte payload. **The cheaper route, if the density ever matters more:**
  add `macName` and `serviceName` to `FleetSnapshot` (decoded with `decodeIfPresent`, so
  already-paired phones are unaffected), then drop both from the payload and make §8's claim
  true. That is a wire change and wants its own slice.
- **A typed pairing stores no remembered endpoints.** `FleetModel.adopt(key:serviceName:macName:)`
  writes `PairedMac(endpoints: [])` on purpose: the seal carries the key and the Mac's name and
  nothing else, and off-LAN typed pairing is explicitly out of scope (spec §11). The phone
  finds its Mac by browsing `_flightdeck._tcp` for the service name it paired under, which is
  what `FleetConnector` does anyway. A phone paired by *QR* still gets one endpoint, from the
  code. If typed pairing ever needs to survive leaving the LAN, the fix is the phone recording
  the address it actually connected on — not widening the seal.
```

- [ ] **Step 5: Verify nothing broke**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`

Expected: **1258** tests, 0 failures. Documentation only.

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-08-18-mobile-companion-design.md docs/MOBILE.md docs/FOLLOWUPS.md
git commit -m "docs: one exception to 'every connection is TLS with the device key'"
```

---

## Acceptance

1. `./scripts/test-unit.sh` reports **1258** tests, 0 failures.
2. `./scripts/build-ios.sh` reports three successes, and the commit for Task 4 records whether `FlightDeckMobile` was **built** or only **type-checked** — those are different amounts of verification and only one of them ran Swift 6's isolation checks.
3. `testThePackedPayloadProducesAMateriallySmallerQR` passes at its written threshold. If it only passes after loosening, that is the spec's §8 claim failing and it goes to the user, not into the threshold.
4. The Mac's pairing sheet shows a QR **and** `XXXX-XXXX-XXXX`, neither behind a disclosure triangle.
5. **The cross-process criterion in `docs/MOBILE.md` has been run at least once** — a real phone app against a real Mac app, paired by typing — with its scope recorded as written there. Everything else on that page's checklists is documented-and-unrun by design; this one is a gate.

## Self-Review

**Spec coverage.** Of the sections this plan owns:

| Spec | Where |
|---|---|
| §4 displayed grouped `XXXX-XXXX-XXXX`; input strips hyphens, whitespace, case | Task 2 (display), Task 3 (`grouped(partial:)` + `init(normalizing:)`) |
| §4 the checksum lets the phone say "that code doesn't look right" | Task 3, `pairByTyping()` |
| §7 `0 Macs → "Can't find that Mac on this network. Scan the QR instead."` | Task 4, verbatim intent |
| §7 2+ Macs, tried in turn | Channel plan Task 7; surfaced here as `.trying(displayName:)` |
| §8 packed QR payload | Task 1 — **with the documented deviation on the two names** |
| §9 both amendments to the original spec | Task 5, Step 1 |
| §10 checksum: a typo is rejected locally and does not reach the network | Channel plan Task 5 (behaviour) + Task 3 here (the field) + checklist item 13 |
| §10 cross-process macOS-against-iOS | Task 5, Step 3 — stated with its limits |
| §11 the QR stays, and stays the off-LAN path | Task 1 keeps it carrying the key and one endpoint; nothing removes the scanner |

Everything §8 asks for is delivered except the ~55-byte target, and that shortfall is argued, measured and recorded rather than quietly absorbed.

**Placeholder scan.** No "TBD", no "add validation", no test described without code. Task 4 has no test and says why in a labelled paragraph rather than leaving the absence to be noticed. Task 5 is documentation and its "code" blocks are the exact prose to insert.

**Type consistency.** `ArmedPairing.payload`/`.code` (channel plan Task 8) are what Task 2's `PairingCodeSheet(service:preferences:window:)` reads, and `DevicesSettingsTab`'s `pairingWindow` state — named there — is what Task 2 Step 4 passes. `PairingCode.grouped(partial:)` (Task 3) is called from `PairingScreen`'s `.onChange` in the same task. `PairingRunner.Progress`'s five cases (channel plan Task 7) are matched exhaustively in Task 4's `onProgress` and in `PairingScreen.message(for:)`; `PairingInitiator.Failure`'s four are matched exhaustively in `FleetModel.message(for:)`. `PairingBrowser.DiscoveredMac.serviceName` is what arrives as `PairingRunner.onPaired`'s middle argument and what `PairedMac.serviceName` is set from — the same string `FleetConnector.startBrowsing` matches on.

**Two things the self-review changed.**

1. The first draft had Task 3's field call `PairingCode(normalizing:)` from `.onChange` and colour itself red while incomplete — which flags every prefix of a correct code as wrong. Validation moved to the Pair button; the formatter is presentation only, and its doc comment now says so.
2. The first draft asserted a QR *version* in the density test. CoreImage does not document which encoding mode `CIQRCodeGenerator` picks, so that would have been a guess dressed as a measurement. It compares measured module counts instead, and Task 1 Step 5 says what each possible ratio means rather than leaving an executor to loosen the threshold.
