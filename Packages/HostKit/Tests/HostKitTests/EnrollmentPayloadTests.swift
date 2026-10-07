import XCTest
@testable import HostKit

final class EnrollmentPayloadTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func payload(issued: Date? = nil, hex: String = String(repeating: "ab", count: 32), v: Int = 1) -> EnrollmentPayload {
        EnrollmentPayload(version: v, slot: UUID(), secretHex: hex, controllerName: "ctl", idleSeconds: 1800,
                          issuedAt: issued ?? t0)
    }

    func testValidWithinMaxAge() throws {
        let (_, secret) = try payload().validate(now: t0.addingTimeInterval(1799))
        XCTAssertEqual(secret, Data(repeating: 0xAB, count: 32))
    }

    func testExpired() {
        XCTAssertThrowsError(try payload().validate(now: t0.addingTimeInterval(1801))) {
            XCTAssertEqual($0 as? EnrollmentError, .expired)
        }
    }

    /// A machine whose clock runs a little ahead of the Mac's still enrolls; one issued
    /// further in the future than the skew allowance is refused like a stale one.
    func testClockSkewTolerance() throws {
        XCTAssertNoThrow(try payload().validate(now: t0.addingTimeInterval(-299)))
        XCTAssertThrowsError(try payload().validate(now: t0.addingTimeInterval(-301))) {
            XCTAssertEqual($0 as? EnrollmentError, .expired)
        }
    }

    func testMalformedSecretAndVersion() {
        XCTAssertThrowsError(try payload(hex: "zz").validate(now: t0)) { XCTAssertEqual($0 as? EnrollmentError, .malformed) }
        XCTAssertThrowsError(try payload(hex: String(repeating: "ab", count: 31)).validate(now: t0)) {
            XCTAssertEqual($0 as? EnrollmentError, .malformed)
        }
        XCTAssertThrowsError(try payload(v: 2).validate(now: t0)) { XCTAssertEqual($0 as? EnrollmentError, .wrongVersion) }
    }

    func testUppercaseHexIsAccepted() throws {
        let (_, secret) = try payload(hex: String(repeating: "AB", count: 32)).validate(now: t0)
        XCTAssertEqual(secret, Data(repeating: 0xAB, count: 32))
    }

    func testRoundTripsAsJSON() throws {
        let p = payload()
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(EnrollmentPayload.self, from: enc.encode(p)), p)
    }
}
