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
    }

    func testAnArbitraryStringIsRejectedRatherThanPartlyParsed() {
        XCTAssertThrowsError(try PairingPayload(decoding: "https://example.com")) { error in
            XCTAssertEqual(error as? PairingPayloadError, .notAPairingCode)
        }
        XCTAssertThrowsError(try PairingPayload(decoding: "flightdeck1:not-base64!!"))
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

    func testEndpointsSurviveInTheOrderTheMacListedThem() throws {
        let original = payload()
        XCTAssertEqual(
            try PairingPayload(decoding: original.encoded()).endpoints,
            ["192.168.1.20:53211", "10.8.0.3:53211"]
        )
    }
}
