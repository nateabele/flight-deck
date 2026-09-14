import XCTest
@testable import FlightDeckMobile

/// When a network path change redials the Mac.
///
/// Mirrors `RedialOnReturnTests`: every case here is a fingerprint sequence a device can
/// actually produce (walking out of Wi-Fi range, switching to cellular, a captive-portal
/// network that never satisfies), never a synthetic one — see `RedialOnPathChange`'s doc
/// comment for the failure this closes and the gap it deliberately leaves.
final class RedialOnPathChangeTests: XCTestCase {

    private func satisfied(_ interfaces: String...) -> PathFingerprint {
        PathFingerprint(isSatisfied: true, interfaces: interfaces)
    }

    private func unsatisfied(_ interfaces: String...) -> PathFingerprint {
        PathFingerprint(isSatisfied: false, interfaces: interfaces)
    }

    /// Launch has no stale socket behind it — `FleetModel` dials fresh, and the fleet-list /
    /// foreground triggers already cover the first render. The first fingerprint the monitor
    /// ever reports must not itself cause a redial.
    func testTheFirstObservationDoesNotRedialEvenWhenSatisfied() {
        var policy = RedialOnPathChange()
        XCTAssertFalse(policy.pathChanged(to: satisfied("wifi")))
    }

    /// The Wi-Fi-out-of-range case: the path goes unsatisfied (no redial — nothing to redial
    /// onto), then comes back satisfied on the same interface type once the phone rejoins the
    /// network. The unsatisfied step recorded in between is what makes the later satisfied
    /// fingerprint "different", even though its interface list matches the original baseline.
    func testDroppingAndRegainingTheSameInterfaceRedialsOnRegain() {
        var policy = RedialOnPathChange()
        XCTAssertFalse(policy.pathChanged(to: satisfied("wifi")), "baseline")
        XCTAssertFalse(policy.pathChanged(to: unsatisfied()), "no network yet, nothing to redial onto")
        XCTAssertTrue(policy.pathChanged(to: satisfied("wifi")), "network is back — stale socket needs a redial")
    }

    /// Walking out of Wi-Fi range straight onto cellular, with no observed unsatisfied gap
    /// (iOS can hand off fast enough that the monitor never reports one) — the interface list
    /// itself changing is enough on its own.
    func testSwitchingInterfaceTypesRedialsWithNoUnsatisfiedStepNeeded() {
        var policy = RedialOnPathChange()
        XCTAssertFalse(policy.pathChanged(to: satisfied("wifi")), "baseline")
        XCTAssertTrue(policy.pathChanged(to: satisfied("cellular")), "different interface, same as an actual handoff")
    }

    /// `NWPathMonitor` is documented to sometimes fire again with nothing meaningfully changed
    /// (a DNS server update, IPv6 renumbering). Repeating the identical satisfied fingerprint
    /// must not churn the connector on every such delivery.
    func testAnIdenticalSatisfiedRepeatDoesNotRedial() {
        var policy = RedialOnPathChange()
        XCTAssertFalse(policy.pathChanged(to: satisfied("wifi")), "baseline")
        XCTAssertFalse(policy.pathChanged(to: satisfied("wifi")), "nothing actually changed")
    }

    /// Launching in airplane mode, then landing on real Wi-Fi. The baseline being unsatisfied
    /// does not exempt the first satisfied fingerprint after it — this is not "the first
    /// observation", it's the second, and by then there is a socket that was never live to
    /// begin with, which is exactly what a redial should fix.
    func testBaselineUnsatisfiedThenSatisfiedRedials() {
        var policy = RedialOnPathChange()
        XCTAssertFalse(policy.pathChanged(to: unsatisfied()), "baseline, and no network to redial onto")
        XCTAssertTrue(policy.pathChanged(to: satisfied("wifi")))
    }

    /// Two interfaces reported at once (e.g. Wi-Fi plus a wired accessory) collapse to the same
    /// fingerprint regardless of the order `NWPath.availableInterfaces` enumerates them in —
    /// `PathFingerprint.init(isSatisfied:interfaces:)` sorts, so this must not read as "changed"
    /// on ordering alone.
    func testInterfaceOrderDoesNotCountAsAChange() {
        var policy = RedialOnPathChange()
        XCTAssertFalse(policy.pathChanged(to: satisfied("wifi", "wiredEthernet")), "baseline")
        XCTAssertFalse(
            policy.pathChanged(to: satisfied("wiredEthernet", "wifi")),
            "same interfaces, reported in a different order"
        )
    }

    /// Two unsatisfied fingerprints in a row — the monitor re-announcing "still no network" —
    /// change nothing about the decision either.
    func testRepeatedUnsatisfiedNeverRedials() {
        var policy = RedialOnPathChange()
        XCTAssertFalse(policy.pathChanged(to: unsatisfied()), "baseline")
        XCTAssertFalse(policy.pathChanged(to: unsatisfied()))
        XCTAssertFalse(policy.pathChanged(to: unsatisfied()))
    }
}
