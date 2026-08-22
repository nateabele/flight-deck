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
