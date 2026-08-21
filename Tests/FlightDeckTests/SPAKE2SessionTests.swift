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

    func testKeyMaterialBeforeAMessageIsRefused() {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        XCTAssertThrowsError(try session.keyMaterial(from: Data(repeating: 0, count: 32)))
    }

    func testAMalformedPeerMessageIsAnErrorNotACrash() throws {
        let session = SPAKE2Session(role: .initiator, myName: alice, theirName: bob)
        _ = try session.message(for: .mint())
        XCTAssertThrowsError(try session.keyMaterial(from: Data([0x00])))
    }

    /// There is no fixed vector to drive here — `vendor/boringssl/crypto/curve25519/
    /// spake25519_test.cc` says so itself, at line 29: "TODO(agl): add tests with fixed
    /// vectors once SPAKE2 is nailed down." That TODO was never picked up upstream, and every
    /// test in that file, including the canonical round trip at `TEST(SPAKE25519Test, SPAKE2)`
    /// (line 109), exercises the exchange with a freshly drawn ephemeral scalar rather than a
    /// documented one — `SPAKE2_generate_msg` has no parameter to fix it, so nothing pinned to
    /// specific input/output bytes is reachable through the public API this wrapper calls.
    /// (Recorded as a gap in `docs/FOLLOWUPS.md`.)
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
