import CoreImage
import CoreImage.CIFilterBuiltins
import XCTest
import FleetKit
@testable import FlightDeck

final class PairingCodeImageTests: XCTestCase {
    /// A v3 payload — packed bytes in Crockford base32 behind an `FD3-` prefix, which is
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
    ///
    /// **The subject supplies three endpoints, and that is load-bearing.** This test is what
    /// `PairingPayload.maxEndpoints` and NETWORKING.md's "Two endpoints, not more" both cite
    /// as the guard on the cap, and it can only be that guard if the *encoder's* cap decides
    /// how many reach the QR. With one endpoint supplied it did not: raising `maxEndpoints`
    /// to 3 still packed one, produced a byte-identical string, and passed. Two would not
    /// have caught it either — the cap has to be the binding constraint at both settings.
    /// At 2 this packs two and measures 47 against v1's 67 (0.701, passes); at 3 it packs
    /// three and measures 51 (0.761, fails). Verified by sabotage in both directions.
    ///
    /// The v1 baseline keeps its ONE endpoint deliberately, which makes the comparison
    /// stricter rather than looser: the packed code is carrying more addresses than the
    /// legacy code it is measured against and still has to come in under three quarters of
    /// its size. Do not "even them up" — that would slacken the threshold, and the point of
    /// §8's measurement is the format, not the address count.
    func testThePackedPayloadProducesAMateriallySmallerQR() throws {
        let subject = PairingPayload(
            key: .mint(), macName: "Nate's MacBook Pro",
            serviceName: "flightdeck-macbook-a1b2",
            endpoints: ["100.108.99.35:53211", "192.168.1.20:53211", "192.168.139.3:53211"]
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

    /// The generator's output is one point per module plus a quiet zone, so this returns the
    /// module count **+ 2**, not the module count — the name is a half-truth kept because the
    /// comparison above only needs the two values to be commensurable.
    ///
    /// Two, measured, not the four-per-side the QR spec asks of a printer:
    /// `CIQRCodeGenerator` emits **one** module of quiet zone per side. Checked by rasterising
    /// the output at one pixel per point and finding the bounding box of the black pixels —
    /// one clear pixel on every edge, at every payload size from 21 modules to 57. The
    /// arithmetic corroborates it: a QR is always 21 + 4k modules square, and the extents this
    /// returns for the two codes above are 47 and 67, which are 45 and 65 — both valid — plus
    /// two. Subtract eight instead, as this comment used to say, and you get 39 and 59, which
    /// are not QR sizes at all.
    ///
    /// The constant is on both sides of the comparison, and leaving it in makes that
    /// comparison *stricter* rather than looser: 47/67 is 0.701 where the true module ratio
    /// 45/65 is 0.692, so the assertion clears its 0.75 threshold by less than the underlying
    /// shrink actually earns. That is why it is left in rather than subtracted out — the
    /// margin is real either way. Read before scaling.
    private func modules(of code: String) -> Int? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "M"
        return filter.outputImage.map { Int($0.extent.width) }
    }
}
