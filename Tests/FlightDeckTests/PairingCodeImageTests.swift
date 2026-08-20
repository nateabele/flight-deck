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
