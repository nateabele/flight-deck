import CryptoKit
import XCTest
@testable import FleetKit

final class PairingSecretsTests: XCTestCase {
    /// Both sides take their transcript from their own session rather than sharing one local,
    /// which is what a real deployment can do — `SPAKE2Session.transcript` is initiator-first
    /// on both ends, so the two agree without either side knowing what the other assembled.
    private func agreeing() throws -> (PairingSecrets, PairingSecrets) {
        let code = PairingCode.mint()
        let phone = SPAKE2Session(role: .initiator, myName: Data("phone".utf8),
                                  theirName: Data("mac".utf8))
        let mac = SPAKE2Session(role: .responder, myName: Data("mac".utf8),
                                theirName: Data("phone".utf8))
        let fromPhone = try phone.message(for: code)
        let fromMac = try mac.message(for: code)
        let phoneMaterial = try phone.keyMaterial(from: fromMac)
        let macMaterial = try mac.keyMaterial(from: fromPhone)
        return (
            PairingSecrets(keyMaterial: phoneMaterial, transcript: try phone.transcript),
            PairingSecrets(keyMaterial: macMaterial, transcript: try mac.transcript)
        )
    }

    /// The point of the whole task: with the same code, each side can prove to the other that
    /// it holds the same key material, and the proofs differ by direction so one cannot be
    /// replayed back at its sender.
    func testConfirmationsMatchAcrossSidesAndDifferByDirection() throws {
        let (phone, mac) = try agreeing()
        XCTAssertEqual(phone.initiatorConfirmation, mac.initiatorConfirmation)
        XCTAssertEqual(phone.responderConfirmation, mac.responderConfirmation)
        XCTAssertNotEqual(phone.initiatorConfirmation, phone.responderConfirmation)
        XCTAssertEqual(phone.initiatorConfirmation.count, 32)
    }

    /// This is what the Mac's three-attempt budget actually counts. A wrong code produces
    /// different key material (proved in Task 3) and therefore a confirmation that does not
    /// match — which is the only signal distinguishing a typo from an attack.
    func testAWrongCodeProducesANonMatchingConfirmation() throws {
        let phone = SPAKE2Session(role: .initiator, myName: Data("phone".utf8),
                                  theirName: Data("mac".utf8))
        let mac = SPAKE2Session(role: .responder, myName: Data("mac".utf8),
                                theirName: Data("phone".utf8))
        let fromPhone = try phone.message(for: .mint())
        let fromMac = try mac.message(for: .mint())

        let phoneSecrets = PairingSecrets(
            keyMaterial: try phone.keyMaterial(from: fromMac), transcript: try phone.transcript)
        let macSecrets = PairingSecrets(
            keyMaterial: try mac.keyMaterial(from: fromPhone), transcript: try mac.transcript)

        XCTAssertNotEqual(phoneSecrets.initiatorConfirmation, macSecrets.initiatorConfirmation)
    }

    /// Two runs with the same code must not produce the same confirmations, or a captured
    /// proof could be replayed into a later window.
    func testConfirmationsAreBoundToTheTranscript() throws {
        let material = Data(repeating: 0xAB, count: 64)
        let first = PairingSecrets(keyMaterial: material, transcript: Data([0x01]))
        let second = PairingSecrets(keyMaterial: material, transcript: Data([0x02]))
        XCTAssertNotEqual(first.initiatorConfirmation, second.initiatorConfirmation)
    }

    /// The headline property, and one no black-box test can pin: with the two keys collapsed
    /// into one, an attacker holding the published confirmation still cannot derive the
    /// (identical) sealing key, so nothing externally observable would change. Only a look at
    /// the keys themselves catches that.
    func testConfirmationAndSealingKeysAreDistinct() throws {
        let (phone, _) = try agreeing()
        XCTAssertNotEqual(phone.confirmationKey, phone.sealingKey)
    }

    /// Same shape as `testConfirmationsAreBoundToTheTranscript`, but for the sealing key: a
    /// blob sealed under one transcript must not open under another, or a sealed key captured
    /// from one pairing window could be replayed into a later one.
    func testTheSealingKeyIsBoundToTheTranscript() throws {
        let material = Data(repeating: 0xAB, count: 64)
        let first = PairingSecrets(keyMaterial: material, transcript: Data([0x01]))
        let second = PairingSecrets(keyMaterial: material, transcript: Data([0x02]))
        let sealed = try first.seal(FleetDeviceKey.mint(), macName: "m")
        XCTAssertThrowsError(try second.open(sealed))
    }

    /// `testConfirmationAndSealingKeysAreDistinct` proves the two keys differ; it does not
    /// prove `seal` uses the right one. Point both `AES.GCM.seal` and `open` at
    /// `confirmationKey` instead and every other test here stays green — the suite would be
    /// just as happy with `sealingKey` dead. So open the box from outside the type, once with
    /// each key, and require exactly one of them to work.
    func testTheSealIsUnderTheSealingKeyAndNotTheConfirmationKey() throws {
        let (phone, mac) = try agreeing()
        let box = try AES.GCM.SealedBox(combined: try mac.seal(FleetDeviceKey.mint(),
                                                               macName: "m"))
        XCTAssertNoThrow(try AES.GCM.open(box, using: phone.sealingKey))
        XCTAssertThrowsError(try AES.GCM.open(box, using: phone.confirmationKey))
    }

    func testTheDeviceKeyRoundTripsThroughSealing() throws {
        let (phone, mac) = try agreeing()
        let key = FleetDeviceKey.mint()
        let sealed = try mac.seal(key, macName: "Nate's MacBook Pro")
        let opened = try phone.open(sealed)
        XCTAssertEqual(opened.key, key)
        XCTAssertEqual(opened.macName, "Nate's MacBook Pro")
    }

    /// The sealed key is the one genuinely secret thing crossing the pairing channel, and that
    /// channel offers no confidentiality of its own — its PSK is public. So this must fail for
    /// anyone who did not complete the exchange.
    func testSealedMaterialIsUselessWithoutTheSharedKey() throws {
        let (_, mac) = try agreeing()
        let (stranger, _) = try agreeing()
        let sealed = try mac.seal(FleetDeviceKey.mint(), macName: "m")
        XCTAssertThrowsError(try stranger.open(sealed))
    }

    func testATamperedSealIsRejected() throws {
        let (phone, mac) = try agreeing()
        var sealed = try mac.seal(FleetDeviceKey.mint(), macName: "m")
        // A flip inside the ciphertext body, not just the trailing tag byte — a tag-only flip
        // is caught by CryptoKit's AEAD regardless of anything this file does, so it earns
        // nothing about our code. Byte 12 is the first byte of the ciphertext, right after the
        // 12-byte nonce in `AES.GCM.SealedBox.combined`.
        sealed[12] ^= 0xFF
        sealed[sealed.count - 1] ^= 0xFF
        XCTAssertThrowsError(try phone.open(sealed))
    }
}
