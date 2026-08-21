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
    private let role: SPAKE2Role
    /// Also the single-use state: non-nil means that half of the exchange has happened.
    private var myMessage: Data?
    private var peerMessage: Data?

    public init(role: SPAKE2Role, myName: Data, theirName: Data) {
        self.role = role
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
        guard myMessage == nil else { throw SPAKE2Error.wrongOrder }

        var out = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_MSG_SIZE))
        var outLength = 0
        let ok = code.secret.withUnsafeBytes { password in
            SPAKE2_generate_msg(
                context, &out, &outLength, out.count,
                password.baseAddress?.assumingMemoryBound(to: UInt8.self), password.count
            )
        }
        guard ok == 1 else { throw SPAKE2Error.generateFailed }
        let message = Data(out[..<outLength])
        myMessage = message
        return message
    }

    public func keyMaterial(from message: Data) throws -> Data {
        guard let context else { throw SPAKE2Error.contextUnavailable }
        guard myMessage != nil, peerMessage == nil else { throw SPAKE2Error.wrongOrder }

        // Sized from SPAKE2_MAX_KEY_SIZE, not from what we intend to use. `process_msg`
        // truncates silently into a short buffer, so a smaller number here would not fail —
        // it would quietly produce less key material than both sides expect.
        var out = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_KEY_SIZE))
        var outLength = 0
        let ok = message.withUnsafeBytes { peer in
            SPAKE2_process_msg(
                context, &out, &outLength, out.count,
                peer.baseAddress?.assumingMemoryBound(to: UInt8.self), peer.count
            )
        }
        guard ok == 1 else { throw SPAKE2Error.processFailed }
        peerMessage = message
        return Data(out[..<outLength])
    }

    /// Both SPAKE2 messages concatenated, **initiator's first**, whichever side this session
    /// is — the transcript everything in `PairingSecrets` is bound to.
    ///
    /// This exists so the order cannot be got wrong rather than merely documented. The natural
    /// implementation writes both ends from the same role-neutral locals
    /// (`transcript: myMsg + theirMsg`), which silently gives the initiator `initiator‖responder`
    /// and the responder `responder‖initiator` — different HKDF salts, so confirmations never
    /// match. It fails closed, but the diagnosis is a lie: the Mac reports "wrong code" for a
    /// correctly typed one and spends an attempt doing it, three times over, until the user is
    /// locked out with every log line saying *typo*. A session knows both messages and its own
    /// role at the moment `keyMaterial(from:)` returns, so it is the only place that can settle
    /// this once.
    ///
    /// Initiator-first mirrors BoringSSL, which commits to the same ordering internally when it
    /// hashes the transcript — `ctx->my_role == spake2_role_alice` selects alice's name and
    /// message first either way (`vendor/boringssl/crypto/curve25519/spake25519.cc:502-512`).
    /// Deriving our salt in a different order than the library derives its key would be merely
    /// confusing, not wrong, and there is no reason to be merely confusing.
    ///
    /// Throws `.wrongOrder` until both messages exist: an empty or half transcript is exactly
    /// the input `PairingSecrets` must never be handed.
    public var transcript: Data {
        get throws {
            guard let myMessage, let peerMessage else { throw SPAKE2Error.wrongOrder }
            return role == .initiator ? myMessage + peerMessage : peerMessage + myMessage
        }
    }
}
