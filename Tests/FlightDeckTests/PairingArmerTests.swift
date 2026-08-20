import XCTest
import FleetKit
@testable import FlightDeck

@MainActor
final class PairingArmerTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000_000)

    private func armer() -> PairingArmer {
        PairingArmer(now: { self.now })
    }

    private func arm(_ armer: PairingArmer) -> PairingPayload {
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
        XCTAssertNotEqual(first.key.secret, second.key.secret)
        XCTAssertNotEqual(first.key.slot, second.key.slot)
        XCTAssertEqual(armer.pending?.slot, second.key.slot,
                       "re-arming replaces the window; two codes must never be live at once")
    }

    func testAClaimInsideTheWindowPairsTheDevice() {
        let armer = armer()
        let payload = arm(armer)
        now += 30
        XCTAssertTrue(armer.claim(slot: payload.key.slot))
        XCTAssertNil(armer.pending, "a claimed window is closed")
    }

    /// Single-use. A QR left on screen and photographed after the fact must not pair a
    /// second device.
    func testACodeCannotBeClaimedTwice() {
        let armer = armer()
        let payload = arm(armer)
        XCTAssertTrue(armer.claim(slot: payload.key.slot))
        XCTAssertFalse(armer.claim(slot: payload.key.slot))
    }

    func testAClaimAfterTheWindowIsRefused() {
        let armer = armer()
        let payload = arm(armer)
        now += PairingArmer.window + 1
        XCTAssertFalse(armer.claim(slot: payload.key.slot))
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

    func testTheProvisionalRecordCarriesTheSameKeyAsTheQR() {
        let armer = armer()
        let payload = arm(armer)
        let pending = armer.pending
        XCTAssertEqual(pending?.key(), payload.key)
        XCTAssertEqual(pending?.isProvisional, true)
    }
}
