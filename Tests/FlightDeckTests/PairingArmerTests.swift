import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class PairingArmerTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000_000)

    private func armer() -> PairingArmer {
        PairingArmer(now: { self.now })
    }

    private func arm(_ armer: PairingArmer) -> ArmedPairing {
        armer.arm(macName: "mac", serviceName: "svc", endpoints: ["127.0.0.1:1"])
    }

    /// The Mac is never passively pairable. Nothing exists to claim until the user opens a
    /// window, which is the whole difference between this and a machine anyone on the LAN
    /// can adopt.
    func testNothingIsPendingUntilTheUserArms() {
        XCTAssertNil(armer().pending)
        XCTAssertFalse(armer().claim(slot: UUID()))
    }

    func testArmingMintsAFreshSecretEveryTime() {
        let armer = armer()
        let first = arm(armer)
        let second = arm(armer)
        XCTAssertNotEqual(first.payload.key.secret, second.payload.key.secret)
        XCTAssertNotEqual(first.payload.key.slot, second.payload.key.slot)
        XCTAssertNotEqual(
            first.code.secret, second.code.secret,
            "two windows must not share a code"
        )
        XCTAssertEqual(armer.pending?.slot, second.payload.key.slot,
                       "re-arming replaces the window; two codes must never be live at once")
    }

    func testAClaimInsideTheWindowPairsTheDevice() {
        let armer = armer()
        let armed = arm(armer)
        now += 30
        XCTAssertTrue(armer.claim(slot: armed.payload.key.slot))
        XCTAssertNil(armer.pending, "a claimed window is closed")
    }

    /// Single-use. A QR left on screen and photographed after the fact must not pair a
    /// second device.
    func testACodeCannotBeClaimedTwice() {
        let armer = armer()
        let armed = arm(armer)
        XCTAssertTrue(armer.claim(slot: armed.payload.key.slot))
        XCTAssertFalse(armer.claim(slot: armed.payload.key.slot))
    }

    func testAClaimAfterTheWindowIsRefused() {
        let armer = armer()
        let armed = arm(armer)
        now += PairingArmer.window + 1
        XCTAssertFalse(armer.claim(slot: armed.payload.key.slot))
    }

    /// The exact edge, which the tests either side of it do not touch. `claim` accepts at
    /// `now == armedUntil` and `expire` drops only strictly past it, so the two boundaries
    /// are complementary — there is no instant where one calls the window gone and the other
    /// still honours it. Pinned because this file exists to enforce a boundary, and a later
    /// edit tightening `<=` to `<` would otherwise pass every test here.
    func testAClaimAtTheExactExpiryInstantIsStillHonoured() {
        let armer = armer()
        let armed = arm(armer)
        now += PairingArmer.window
        armer.expire()
        XCTAssertNotNil(armer.pending, "expire must not drop a window at the instant it ends")
        XCTAssertTrue(armer.claim(slot: armed.payload.key.slot))
    }

    func testAClaimForADifferentSlotIsRefused() {
        let armer = armer()
        _ = arm(armer)
        XCTAssertFalse(armer.claim(slot: UUID()))
    }

    func testExpiringDropsAStaleWindowSoItsKeyStopsBeingAccepted() {
        let armer = armer()
        _ = arm(armer)
        now += PairingArmer.window + 1
        armer.expire()
        XCTAssertNil(armer.pending)
    }

    func testExpiringLeavesALiveWindowAlone() {
        let armer = armer()
        _ = arm(armer)
        now += 5
        armer.expire()
        XCTAssertNotNil(armer.pending)
    }

    func testCancellingClosesTheWindowImmediately() {
        let armer = armer()
        _ = arm(armer)
        armer.cancel()
        XCTAssertNil(armer.pending)
    }

    /// The rule `FleetService.closePairingListener()` states, at the level it is actually
    /// enforced: the listener's lifetime is `pending`'s lifetime, so *every* way `pending`
    /// stops being a live window has to announce it. Asserted over all three clearing routes
    /// at once rather than one test each, because the property is the exhaustiveness — a
    /// fourth route added without firing this is exactly the defect the QR path shipped with,
    /// and a per-route test would have said nothing about it either.
    func testEveryWayAWindowEndsAnnouncesThatItEnded() {
        for (name, end) in [
            ("cancel", { (armer: PairingArmer) in armer.cancel() }),
            ("claim", { armer in _ = armer.claim(slot: armer.pending!.slot) }),
            ("expire", { armer in
                self.now += PairingArmer.window + 1
                armer.expire()
            }),
        ] {
            let armer = armer()
            _ = arm(armer)
            var closures = 0
            armer.onWindowClosed = { closures += 1 }
            end(armer)
            XCTAssertNil(armer.pending, "\(name) did not end the window")
            XCTAssertEqual(closures, 1, "\(name) ended the window without announcing it")
        }
    }

    func testTheProvisionalRecordCarriesTheSameKeyAsTheQR() {
        let armer = armer()
        let armed = arm(armer)
        let pending = armer.pending
        XCTAssertEqual(pending?.key(), armed.payload.key)
        XCTAssertEqual(pending?.isProvisional, true)
    }
}
