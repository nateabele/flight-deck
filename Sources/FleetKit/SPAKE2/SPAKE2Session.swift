import BoringSSLShim
import Foundation

public enum SPAKE2Role: Sendable {
    /// The phone. Arbitrary but fixed: SPAKE2 is asymmetric and the two ends must disagree
    /// about which they are, so this mapping is part of the protocol and cannot be flipped
    /// on one side alone.
    case initiator
    /// The Mac.
    case responder
}

public enum SPAKE2Error: Error, Equatable {
    case contextUnavailable
    case generateFailed
    case processFailed
    case wrongOrder
}

/// One run of SPAKE2, wrapping BoringSSL.
///
/// A session is single-use in the C library — one `generate_msg`, then one `process_msg`, then
/// the context may only be freed — and this type enforces that in Swift rather than relying on
/// callers to read the header. A retry needs a new session.
///
/// **This produces keying material and nothing else.** BoringSSL performs no key confirmation,
/// and a wrong password does not fail here: it silently yields a different key. Distinguishing
/// "right code" from "wrong code" is `PairingSecrets`' job (Task 4), and until that confirmation
/// runs, nothing derived from this material may be trusted or acted on.
public final class SPAKE2Session {
    private var context: OpaquePointer?
    private var hasGenerated = false
    private var hasProcessed = false

    public init(role: SPAKE2Role, myName: Data, theirName: Data) {
        let cRole = role == .initiator ? spake2_role_alice : spake2_role_bob
        // The returned context escapes both `withUnsafeBytes` closures — safe only because
        // `SPAKE2_CTX_new` (spake25519.cc) copies both names via `CBS_stow` before it returns,
        // rather than retaining these pointers. If a future BoringSSL version stopped doing
        // that, this would need to move inside the closures.
        context = myName.withUnsafeBytes { mine in
            theirName.withUnsafeBytes { theirs in
                SPAKE2_CTX_new(
                    cRole,
                    mine.baseAddress?.assumingMemoryBound(to: UInt8.self), mine.count,
                    theirs.baseAddress?.assumingMemoryBound(to: UInt8.self), theirs.count
                )
            }
        }
    }

    deinit {
        if let context { SPAKE2_CTX_free(context) }
    }

    public func message(for code: PairingCode) throws -> Data {
        guard let context else { throw SPAKE2Error.contextUnavailable }
        guard !hasGenerated else { throw SPAKE2Error.wrongOrder }

        var out = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_MSG_SIZE))
        var outLength = 0
        let ok = code.secret.withUnsafeBytes { password in
            SPAKE2_generate_msg(
                context, &out, &outLength, out.count,
                password.baseAddress?.assumingMemoryBound(to: UInt8.self), password.count
            )
        }
        guard ok == 1 else { throw SPAKE2Error.generateFailed }
        hasGenerated = true
        return Data(out[..<outLength])
    }

    public func keyMaterial(from peerMessage: Data) throws -> Data {
        guard let context else { throw SPAKE2Error.contextUnavailable }
        guard hasGenerated, !hasProcessed else { throw SPAKE2Error.wrongOrder }

        // Sized from SPAKE2_MAX_KEY_SIZE, not from what we intend to use. `process_msg`
        // truncates silently into a short buffer, so a smaller number here would not fail —
        // it would quietly produce less key material than both sides expect.
        var out = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_KEY_SIZE))
        var outLength = 0
        let ok = peerMessage.withUnsafeBytes { message in
            SPAKE2_process_msg(
                context, &out, &outLength, out.count,
                message.baseAddress?.assumingMemoryBound(to: UInt8.self), message.count
            )
        }
        guard ok == 1 else { throw SPAKE2Error.processFailed }
        hasProcessed = true
        return Data(out[..<outLength])
    }
}
