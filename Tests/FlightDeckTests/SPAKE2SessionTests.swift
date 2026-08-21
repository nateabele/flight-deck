import XCTest
import BoringSSLShim
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

    /// The one thing an in-process test genuinely cannot reach by construction — and it is
    /// **not** what we first wrote down. The earlier note here and in `docs/FOLLOWUPS.md` said
    /// only a cross-process macOS-against-iOS exchange could catch a wrapper that swapped
    /// `.initiator`/`.responder` or its two name arguments. That was wrong: both ends compile
    /// this same `FleetKit`, so a consistent swap is applied on both sides of the wire and
    /// survives any cross-process test just as happily. Proved by mutation — roles swapped, and
    /// names passed swapped to `SPAKE2_CTX_new`, each pass every other test in this file.
    ///
    /// What actually closes it is a second implementation of the *caller*, which is what this
    /// is: one side goes through `SPAKE2Session`, the other straight through BoringSSL's C API
    /// with a literal `spake2_role_alice` and the argument order the header declares. The raw
    /// side is written from the header rather than from the wrapper, so agreement pins the
    /// wrapper's mapping to the library's own convention rather than to itself.
    ///
    /// Worth being clear about what a swap would have cost, because it is less than we implied:
    /// a *consistent* one is pure relabelling. Both names still reach the transcript, still in a
    /// fixed order, still distinguishing one device from another — so it would be
    /// unconventional, not insecure. Cross-process still earns its place in the pairing plan,
    /// but for caller-side asymmetry, which is the thing that plan can actually get wrong.
    func testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder() throws {
        let code = PairingCode.mint()
        let wrapper = SPAKE2Session(role: .responder, myName: bob, theirName: alice)

        // Deliberately built from `curve25519.h` and not from `SPAKE2Session`: `my_name` first
        // and `their_name` second because that is the order the signature declares them in, and
        // the role spelled out rather than derived. The context escapes both closures for the
        // same reason the wrapper's does — `SPAKE2_CTX_new` copies both names via `CBS_stow`.
        let myName = Array("alice".utf8)
        let theirName = Array("bob".utf8)
        let raw = myName.withUnsafeBufferPointer { mine in
            theirName.withUnsafeBufferPointer { theirs in
                SPAKE2_CTX_new(
                    spake2_role_alice,
                    mine.baseAddress, mine.count,
                    theirs.baseAddress, theirs.count
                )
            }
        }
        XCTAssertNotNil(raw)
        defer { SPAKE2_CTX_free(raw) }

        var rawMessage = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_MSG_SIZE))
        var rawMessageLength = 0
        let password = [UInt8](code.secret)
        XCTAssertEqual(1, password.withUnsafeBufferPointer { pw in
            SPAKE2_generate_msg(
                raw, &rawMessage, &rawMessageLength, rawMessage.count, pw.baseAddress, pw.count
            )
        })

        let fromWrapper = [UInt8](try wrapper.message(for: code))
        var rawKey = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_KEY_SIZE))
        var rawKeyLength = 0
        XCTAssertEqual(1, fromWrapper.withUnsafeBufferPointer { theirMessage in
            SPAKE2_process_msg(
                raw, &rawKey, &rawKeyLength, rawKey.count,
                theirMessage.baseAddress, theirMessage.count
            )
        })

        XCTAssertEqual(
            try wrapper.keyMaterial(from: Data(rawMessage[..<rawMessageLength])),
            Data(rawKey[..<rawKeyLength]),
            "wrapper's role/name marshalling disagrees with the raw C API"
        )
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
    /// in `docs/FOLLOWUPS.md`. The residual risk that leaves — this wrapper's marshalling
    /// rather than BoringSSL's math — is pinned by
    /// `testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder` above, in process.
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
