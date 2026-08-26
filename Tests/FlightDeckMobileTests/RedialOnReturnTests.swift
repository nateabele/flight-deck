import SwiftUI
import XCTest
@testable import FlightDeckMobile

/// When returning to the app redials the Mac.
///
/// **Every sequence below was observed, not imagined.** They come from `NSLog`ging every
/// `scenePhase` transition in a build on a simulator and driving it — which is also how the
/// defect this file exists for was found: the shipped predicate asked whether the *immediately
/// previous* phase was `.background`, and iOS never delivers `.active` straight from it.
@MainActor
final class RedialOnReturnTests: XCTestCase {

    /// The observed return sequence, verbatim from the log:
    ///
    ///     background -> inactive
    ///     inactive   -> active
    ///
    /// The old predicate saw `previous == .inactive` at the moment that mattered and did
    /// nothing, every single time.
    func testReturningFromBackgroundRedialsThroughTheInactiveStep() {
        var policy = RedialOnReturn()
        XCTAssertFalse(policy.phaseChanged(to: .inactive), "on the way down, nothing to do")
        XCTAssertFalse(policy.phaseChanged(to: .background))
        XCTAssertFalse(policy.phaseChanged(to: .inactive), "still on the way back up")
        XCTAssertTrue(policy.phaseChanged(to: .active), "this is the moment the socket is stale")
    }

    /// The case the original guard was narrow to protect, and it is still protected: a banner
    /// or the app switcher passes through `.inactive` without ever suspending, and redialling
    /// on those would churn the socket every time a notification arrived.
    func testABannerDoesNotRedial() {
        var policy = RedialOnReturn()
        XCTAssertFalse(policy.phaseChanged(to: .inactive))
        XCTAssertFalse(policy.phaseChanged(to: .active), "never suspended, so nothing is stale")
    }

    /// Launch is not a return. The first `.active` of a process has no connection behind it to
    /// be stale, and `FleetModel` dials on its own at startup.
    func testTheFirstActivationDoesNotRedial() {
        var policy = RedialOnReturn()
        XCTAssertFalse(policy.phaseChanged(to: .active))
    }

    /// One suspension, one redial. A second `.active` with no `.background` between — which the
    /// app switcher produces by hovering and returning — must not dial again.
    func testTheFlagIsConsumedByTheRedialItCauses() {
        var policy = RedialOnReturn()
        _ = policy.phaseChanged(to: .background)
        XCTAssertTrue(policy.phaseChanged(to: .active))
        XCTAssertFalse(policy.phaseChanged(to: .inactive))
        XCTAssertFalse(policy.phaseChanged(to: .active), "no suspension since the last redial")
    }

    /// Several trips down and up while the app is never brought back still arm exactly one
    /// redial, not one per transition.
    func testRepeatedBackgroundingArmsASingleRedial() {
        var policy = RedialOnReturn()
        _ = policy.phaseChanged(to: .background)
        _ = policy.phaseChanged(to: .inactive)
        _ = policy.phaseChanged(to: .background)
        XCTAssertTrue(policy.phaseChanged(to: .active))
        XCTAssertFalse(policy.sawBackground, "consumed")
    }
}
