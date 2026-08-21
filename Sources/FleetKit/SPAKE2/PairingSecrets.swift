import CryptoKit
import Foundation

public enum PairingSealError: Error, Equatable {
    case sealFailed
    case openFailed
}

/// Everything derived from a completed SPAKE2 exchange: the two confirmation values, and the
/// key that seals the real device key on its way to the phone.
///
/// This exists because BoringSSL's SPAKE2 does not confirm keys. Its header is explicit that a
/// wrong password yields a *different* key rather than an error, so without an explicit
/// confirmation step the Mac has no way to distinguish a typo from a correct pairing — and the
/// three-attempt budget would have nothing to count.
///
/// Every value is bound to the transcript (both SPAKE2 messages, in a fixed order) so a proof
/// captured from one window cannot be replayed into another.
public struct PairingSecrets {
    private let confirmationKey: SymmetricKey
    private let sealingKey: SymmetricKey
    private let transcript: Data

    public init(keyMaterial: Data, transcript: Data) {
        let base = SymmetricKey(data: keyMaterial)
        self.transcript = transcript
        // Separate subkeys for separate jobs. Reusing one key for both confirmation and
        // encryption would mean a confirmation value — which is sent in the clear, by design —
        // is derived from the same secret that protects the device key.
        self.confirmationKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: base, salt: transcript,
            info: Data("flightdeck-pairing-confirm".utf8), outputByteCount: 32
        )
        self.sealingKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: base, salt: transcript,
            info: Data("flightdeck-pairing-seal".utf8), outputByteCount: 32
        )
    }

    /// The phone proves itself with this; the Mac checks it before spending an attempt.
    public var initiatorConfirmation: Data { confirmation(for: "initiator") }
    /// The Mac proves itself with this, so a phone cannot be walked through a pairing by
    /// something that never knew the code.
    public var responderConfirmation: Data { confirmation(for: "responder") }

    private func confirmation(for role: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data(role.utf8) + transcript, using: confirmationKey
        ))
    }

    public func seal(_ key: FleetDeviceKey, slot: UUID, macName: String) throws -> Data {
        var payload = Data()
        payload.append(contentsOf: withUnsafeBytes(of: slot.uuid) { Data($0) })
        payload.append(key.secret)
        payload.append(Data(macName.utf8))
        guard let sealed = try? AES.GCM.seal(payload, using: sealingKey).combined else {
            throw PairingSealError.sealFailed
        }
        return sealed
    }

    public func open(_ sealed: Data) throws -> (key: FleetDeviceKey, macName: String) {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
              let payload = try? AES.GCM.open(box, using: sealingKey),
              payload.count >= 48,
              let macName = String(data: payload[48...], encoding: .utf8)
        else { throw PairingSealError.openFailed }

        let slotBytes = [UInt8](payload[..<16])
        let slot = UUID(uuid: (
            slotBytes[0], slotBytes[1], slotBytes[2], slotBytes[3],
            slotBytes[4], slotBytes[5], slotBytes[6], slotBytes[7],
            slotBytes[8], slotBytes[9], slotBytes[10], slotBytes[11],
            slotBytes[12], slotBytes[13], slotBytes[14], slotBytes[15]
        ))
        return (FleetDeviceKey(slot: slot, secret: payload[16..<48]), macName)
    }
}
