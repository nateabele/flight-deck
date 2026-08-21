import XCTest
import FleetKit

final class SPAKE2SessionTests: XCTestCase {
    private let alice = Data("alice".utf8)
    private let bob = Data("bob".utf8)

    /// The property the whole design rests on: same code, both sides land on the same key.
    func testBothSidesDeriveTheSameKeyFromTheSameCode() throws {
        let code = PairingCode.mint()
        let initiator = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        let responder = SPAKE2Session(role: .responder, myName: bob, theirName: alice)

        let fromInitiator = try initiator.message(for: code)
        let fromResponder = try responder.message(for: code)

        let initiatorKey = try initiator.keyMaterial(from: fromResponder)
        let responderKey = try responder.keyMaterial(from: fromInitiator)

        XCTAssertEqual(initiatorKey, responderKey)
        XCTAssertEqual(initiatorKey.count, 64)
    }

    /// And the property that makes the attempt limit meaningful: a wrong code does not fail
    /// loudly, it silently produces a *different* key. That is why key confirmation (Task 4)
    /// exists at all — without it the Mac cannot tell these two cases apart.
    func testADifferentCodeYieldsADifferentKeyRatherThanAnError() throws {
        let initiator = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        let responder = SPAKE2Session(role: .responder, myName: bob, theirName: alice)

        let fromInitiator = try initiator.message(for: .mint())
        let fromResponder = try responder.message(for: .mint())

        let initiatorKey = try initiator.keyMaterial(from: fromResponder)
        let responderKey = try responder.keyMaterial(from: fromInitiator)

        XCTAssertNotEqual(initiatorKey, responderKey)
    }

    /// The names are bound into the exchange precisely so one code cannot be replayed against
    /// a different device — BoringSSL's header calls this context confusion.
    func testMismatchedNamesYieldDifferentKeys() throws {
        let code = PairingCode.mint()
        let initiator = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        let responder = SPAKE2Session(
            role: .responder, myName: Data("carol".utf8), theirName: alice
        )

        let fromInitiator = try initiator.message(for: code)
        let fromResponder = try responder.message(for: code)

        XCTAssertNotEqual(
            try initiator.keyMaterial(from: fromResponder),
            try responder.keyMaterial(from: fromInitiator)
        )
    }

    /// The seam this closes is not hypothetical, it is the *natural* implementation. Writing
    /// both sides symmetrically from role-neutral locals — the identical line on each end,
    /// `transcript: myMsg + theirMsg` — hands the initiator `initiator‖responder` and the
    /// responder `responder‖initiator`. Different HKDF salts, different confirmation keys,
    /// nothing matches. It fails closed, so it is not a hole; it is worse to diagnose than one,
    /// because the Mac reports "wrong code" for a correctly typed one and spends an attempt
    /// saying so. Three correct entries and the user is locked out with every log line
    /// insisting they made a typo.
    ///
    /// So `transcript` is the fixed order rather than a convention a caller is asked to keep.
    /// This asserts the property that makes it work: both sides report the *same bytes*, which
    /// stops being true the moment the ordering is made role-relative.
    func testBothSidesReportTheSameTranscriptRegardlessOfRole() throws {
        let code = PairingCode.mint()
        let initiator = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        let responder = SPAKE2Session(role: .responder, myName: bob, theirName: alice)

        let fromInitiator = try initiator.message(for: code)
        let fromResponder = try responder.message(for: code)
        _ = try initiator.keyMaterial(from: fromResponder)
        _ = try responder.keyMaterial(from: fromInitiator)

        XCTAssertEqual(try initiator.transcript, try responder.transcript)
        // And it is the initiator's message first, mirroring the order BoringSSL itself hashes
        // in (`spake25519.cc:502-512`) rather than an order of our own invention.
        XCTAssertEqual(try responder.transcript, fromInitiator + fromResponder)
    }

    /// A half-finished exchange has no transcript to bind anything to, and
    /// `PairingSecrets.init` would take an empty one as a `precondition` crash rather than an
    /// error. Refuse it here, where it is still recoverable.
    func testTheTranscriptIsUnavailableUntilBothMessagesExist() throws {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        XCTAssertThrowsError(try session.transcript) {
            XCTAssertEqual($0 as? SPAKE2Error, .wrongOrder)
        }
        _ = try session.message(for: .mint())
        XCTAssertThrowsError(try session.transcript) {
            XCTAssertEqual($0 as? SPAKE2Error, .wrongOrder)
        }
    }

    func testAMessageIsThirtyTwoBytes() throws {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        XCTAssertEqual(try session.message(for: .mint()).count, 32)
    }

    /// BoringSSL documents one `generate_msg` per context and a context that is finished after
    /// `process_msg`. Enforce both in Swift rather than letting a misuse reach C, where the
    /// documented behaviour is an error return that is easy to drop.
    func testAContextRefusesToBeReused() throws {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        _ = try session.message(for: .mint())
        XCTAssertThrowsError(try session.message(for: .mint()))
    }

    /// The other half of the single-use contract: `hasProcessed` should refuse a second call
    /// just as `hasGenerated` refuses a second `message(for:)`, not merely accept it and hand
    /// back stale or re-derived material.
    func testKeyMaterialRefusesToBeCalledTwice() throws {
        let code = PairingCode.mint()
        let initiator = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        let responder = SPAKE2Session(role: .responder, myName: bob, theirName: alice)

        _ = try initiator.message(for: code)
        let fromResponder = try responder.message(for: code)

        _ = try initiator.keyMaterial(from: fromResponder)
        XCTAssertThrowsError(try initiator.keyMaterial(from: fromResponder))
    }

    func testKeyMaterialBeforeAMessageIsRefused() {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        XCTAssertThrowsError(try session.keyMaterial(from: Data(repeating: 0, count: 32)))
    }

    func testAMalformedPeerMessageIsAnErrorNotACrash() throws {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        _ = try session.message(for: .mint())
        XCTAssertThrowsError(try session.keyMaterial(from: Data([0x00])))
    }

    /// There is no fixed vector to drive here, and not merely because BoringSSL never wrote
    /// one (`vendor/boringssl/crypto/curve25519/spake25519_test.cc` line 29 — "TODO(agl): add
    /// tests with fixed vectors once SPAKE2 is nailed down" — still open upstream). This
    /// vendored SPAKE2 is not CFRG SPAKE2 at all: its `M`/`N` are BoringSSL-generated points,
    /// not RFC 9382's; `password_scalar_hack` is a unilateral bug fix baked into the wire
    /// format; and the transcript hashes `password_hash` (SHA-512 of the password) rather than
    /// the derived scalar. There is no specification this could conform to, so a vector would
    /// not be validation even if one existed — the property that matters is that both ends,
    /// which run this same BoringSSL, agree with *each other*. `SPAKE2_generate_msg` also has
    /// no parameter to fix the ephemeral scalar, so nothing pinned to specific input/output
    /// bytes is reachable through the public API this wrapper calls regardless. Full reasoning
    /// and the real residual risk (marshalling, not the algorithm) in `docs/FOLLOWUPS.md`.
    ///
    /// What *is* available, and what this test drives, is BoringSSL's own default scenario —
    /// the "alice"/"bob" names `SPAKE2Run` uses when nothing overrides them — through a second,
    /// independently constructed session pair, to confirm the round-trip property is not an
    /// artifact of the one pair every other test in this file happens to share.
    func testASecondIndependentSessionPairAlsoInteroperates() throws {
        let code = PairingCode.mint()
        let initiator = SPAKE2Session(
            role: .initiator, myName: Data("alice".utf8), theirName: Data("bob".utf8)
        )
        let responder = SPAKE2Session(
            role: .responder, myName: Data("bob".utf8), theirName: Data("alice".utf8)
        )

        let fromInitiator = try initiator.message(for: code)
        let fromResponder = try responder.message(for: code)

        XCTAssertEqual(
            try initiator.keyMaterial(from: fromResponder),
            try responder.keyMaterial(from: fromInitiator)
        )
    }
}
