import HostKit
import XCTest

/// The macOS hostd's "don't touch" panel, its logic only (`Sources/HostDaemon/ScreenPanel.swift`
/// is compiled into this bundle). The window itself is AppKit and gets no test: what can go
/// wrong worth catching is a panel left up after the screen is free, or one that flickers
/// away and back between two queued screen runs.
final class ScreenPanelStateTests: XCTestCase {
    private let first = LeaseHolder(runID: "r4", session: "Checkout UI tests")
    private let second = LeaseHolder(runID: "r9", session: "Settings tests")

    func testAGrantPresentsThePanelNamingTheHolder() {
        var state = ScreenPanelState()
        let effect = state.update(holder: first)
        XCTAssertEqual(effect, .present(ScreenPanelContent(holder: first)))
        XCTAssertEqual(ScreenPanelContent(holder: first).title, "UI tests running — don't touch")
        XCTAssertEqual(ScreenPanelContent(holder: first).detail, "Checkout UI tests · run r4")
        XCTAssertEqual(state.shown, ScreenPanelContent(holder: first))
    }

    func testTheLastReleaseDismissesIt() {
        var state = ScreenPanelState()
        _ = state.update(holder: first)
        XCTAssertEqual(state.update(holder: nil), .dismiss)
        XCTAssertNil(state.shown)
    }

    /// The lease passes straight from one run to the next waiter: the panel stays up and only
    /// its text changes, rather than closing and reopening over a running UI test.
    func testAHandoverUpdatesInPlace() {
        var state = ScreenPanelState()
        _ = state.update(holder: first)
        XCTAssertEqual(state.update(holder: second), .update(ScreenPanelContent(holder: second)))
        XCTAssertEqual(state.shown, ScreenPanelContent(holder: second))
    }

    /// The lease notifies on every queue change too (a waiter joining or leaving), with the
    /// same holder: nothing to redraw.
    func testRepeatsAreNoOps() {
        var state = ScreenPanelState()
        XCTAssertEqual(state.update(holder: nil), .none)
        _ = state.update(holder: first)
        XCTAssertEqual(state.update(holder: first), .none)
    }
}
