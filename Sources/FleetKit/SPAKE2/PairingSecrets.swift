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
/// Every value — both confirmations and the sealing key — is bound to the transcript (both
/// SPAKE2 messages, in a fixed order) so a proof or a sealed blob captured from one pairing
/// window cannot be replayed into another.
///
/// **Take that transcript from `SPAKE2Session.transcript`, never assemble it at the call site.**
/// It arrives here as opaque bytes, so this type cannot check the order — and the order is not a
/// detail: the two ends must agree on it byte for byte or every confirmation mismatches and the
/// Mac blames a correctly typed code. `SPAKE2Session` knows both messages and its own role, so
/// it is where the order is settled; see the reasoning on that property.
public struct PairingSecrets: Sendable {
    // Not `private`: `PairingSecretsTests` reaches these two through `@testable import` to
    // assert they are distinct keys and that the seal is under the right one — neither of which
    // any black-box test can pin. With the keys collapsed, an attacker holding the published
    // confirmation still cannot derive the (identical) sealing key, so nothing externally
    // observable would change.
    let confirmationKey: SymmetricKey
    let sealingKey: SymmetricKey
    private let transcript: Data

    public init(keyMaterial: Data, transcript: Data) {
        precondition(!keyMaterial.isEmpty, "keyMaterial must not be empty")
        precondition(!transcript.isEmpty, "transcript must not be empty")
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

    /// Seals `key`'s secret for the peer, under `key.slot` — never a slot passed separately.
    /// `seal` and `open` are not a general encode/decode pair: `open` already reconstructs a
    /// whole `FleetDeviceKey`, so the only way to disagree with it is to take the slot and
    /// secret apart here and hand back a slot that does not match. That failure is silent and
    /// severe — the seal still decrypts and authenticates cleanly, the phone stores the wrong
    /// slot as its PSK identity, and pairing "succeeds" only to fail at the next connection
    /// with nothing reported where the mistake was made.
    public func seal(_ key: FleetDeviceKey, macName: String) throws -> Data {
        var payload = Data()
        payload.append(contentsOf: withUnsafeBytes(of: key.slot.uuid) { Data($0) })
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
        // `Data(...)`, not the bare slice: `AES.GCM.open` returns a fresh `Data` indexed from
        // zero, but slicing it still yields a `Data` whose `startIndex` is 16, not 0. Nothing
        // indexes `secret` absolutely today, so a bare slice is not a live bug — but it is a
        // trap for the next caller who does.
        return (FleetDeviceKey(slot: slot, secret: Data(payload[16..<48])), macName)
    }
}
