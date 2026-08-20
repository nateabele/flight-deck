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
    /// eventually, a log. Note `URL(string:)` does return non-nil for an opaque `scheme:body`
    /// URI like this one — the protection here is the absent authority (`//`) and query (`?`)
    /// components, not the absence of a `URL` value.
    func testTheCodeIsNotAURL() {
        let encoded = payload().encoded()
        XCTAssertTrue(encoded.hasPrefix("flightdeck1:"))
        XCTAssertFalse(encoded.contains("//"))
        XCTAssertFalse(encoded.contains("?"))
        XCTAssertNil(URL(string: encoded)?.host)
    }

    func testTheSecretIsNotReadableFromTheCodeAsText() {
        let key = FleetDeviceKey.mint()
        let encoded = PairingPayload(
            key: key, macName: "m", serviceName: "s", endpoints: []
        ).encoded()
        XCTAssertFalse(encoded.contains(key.secret.base64EncodedString()),
                       "the body is base64url of JSON; a raw base64 secret would mean it is not")
        XCTAssertFalse(encoded.contains(key.secret.base64URLEncodedString()),
                       "the secret is embedded inside JSON that is itself base64url-encoded, " +
                       "so even the base64url form of the raw secret should not appear verbatim")
    }

    func testAnArbitraryStringIsRejectedRatherThanPartlyParsed() {
        XCTAssertThrowsError(try PairingPayload(decoding: "https://example.com")) { error in
            XCTAssertEqual(error as? PairingPayloadError, .notAPairingCode)
        }
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
        let code = "flightdeck2:" + alienBody.base64URLEncodedString()
        XCTAssertThrowsError(try PairingPayload(decoding: code)) { error in
            XCTAssertEqual(error as? PairingPayloadError, .unsupportedVersion(2))
        }
    }

    /// A prefix version that disagrees with the body's is a hand-edited code, not a newer one.
    func testAPrefixVersionDisagreeingWithTheBodyIsMalformed() throws {
        let body = Data(#"{"v":7,"slot":"00000000-0000-0000-0000-000000000000","psk":"AAAA","name":"m","svc":"s","eps":[]}"#.utf8)
        let code = "flightdeck1:" + body.base64URLEncodedString()
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
