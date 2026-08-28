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
        XCTAssertEqual(decoded.version, 3)
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
        XCTAssertTrue(payload().encoded().hasPrefix("FD3-"))
    }

    /// Kept from v1, and still the reason the version lives in the prefix: a payload from a
    /// newer Mac may pack fields this version cannot parse, and reporting it as "damaged"
    /// sends the user to show a fresh code when what they need is to update the app.
    func testAFutureVersionIsRejectedByVersionNotByShape() {
        let code = payload().encoded().replacingOccurrences(of: "FD3-", with: "FD9-")
        XCTAssertThrowsError(try PairingPayload(decoding: code)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .unsupportedVersion(9))
        }
    }

    /// The version is checked twice — once in the prefix, before a byte is decoded, and once
    /// in the packed body — so a hand-edited prefix cannot walk a mismatched body past the
    /// gate. This is v1's `testAPrefixVersionDisagreeingWithTheBodyIsMalformed`, re-expressed.
    func testAPrefixVersionDisagreeingWithThePackedVersionIsMalformed() throws {
        var bytes = try XCTUnwrap(Data(crockfordBase32: String(payload().encoded().dropFirst(4))))
        bytes[0] = 9
        let code = "FD3-" + bytes.crockfordBase32EncodedString()
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

    /// The mirror of truncation, and the one the decoder used not to make: a record with
    /// bytes appended past the mac name decoded *successfully*, because nothing checked that
    /// the cursor had reached the end. It cannot produce a wrong key — every field is already
    /// read by then — so this is robustness rather than safety, but a decoder whose accepted
    /// set is wider than its encoder's output set is one where "this code scans" stops
    /// meaning "this code is intact".
    ///
    /// Four bytes rather than one: base32 drops a partial trailing group, so a single
    /// appended symbol is invisible by construction and only whole appended *bytes* are a
    /// thing the decoder could ever see.
    func testACodeWithBytesAppendedPastTheEndIsMalformed() throws {
        let code = payload().encoded()
        var bytes = try XCTUnwrap(Data(crockfordBase32: String(code.dropFirst(4))))
        XCTAssertEqual(bytes.count, 99, "the record whose end this test is about")
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        let extended = "FD3-" + bytes.crockfordBase32EncodedString()
        XCTAssertThrowsError(try PairingPayload(decoding: extended)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .malformed)
        }
        // And the clean record it was built from still decodes, so the guard above rejects
        // the appended bytes rather than every code of this shape.
        XCTAssertNoThrow(try PairingPayload(decoding: code))
    }

    /// v1's `testTheCodeIsNotAURL`, kept: a scanner that treated this as a link would hand it
    /// to Safari instead of to the app.
    func testTheCodeIsNotAURL() {
        XCTAssertNil(URL(string: payload().encoded())?.scheme)
    }

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

    /// A Mac with no routable address still produces a scannable code — the phone will find it
    /// over Bonjour. An encoder that refused here would fail pairing on a machine that is
    /// perfectly pairable. Round-trips to `[]` via a zero count byte, not six zero bytes as
    /// under v2 — an unusable slot is no longer spent (see
    /// `testAnUnusableEndpointDoesNotConsumeASlot`).
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
