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
        XCTAssertEqual(bytes.count, 98, "the record whose end this test is about")
        bytes.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        let extended = "FD2-" + bytes.crockfordBase32EncodedString()
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
