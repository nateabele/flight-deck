import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
import FleetKit
@testable import FlightDeck

final class PairingCodeImageTests: XCTestCase {
    /// A v2 payload — packed bytes in Crockford base32 behind an `FD2-` prefix, which is
    /// what `PairingCodeImage` is actually handed now.
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

    /// The generator's output is one point per module, plus the standard four-module quiet
    /// zone on each side — so the extent is the module count + 8. The constant is on both
    /// sides of the comparison above, which only makes the ratio it measures more
    /// conservative, so it is left in rather than subtracted out. Read before scaling.
    private func modules(of code: String) -> Int? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        return filter.outputImage.map { Int($0.extent.width) }
    }
}
