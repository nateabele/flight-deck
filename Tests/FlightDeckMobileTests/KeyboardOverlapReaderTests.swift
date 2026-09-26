import XCTest
@testable import FlightDeckMobile

/// The one decision `KeyboardOverlapReader` makes that a simulator test can reach: how far the
/// composer must lift for a keyboard whose top edge the probe measured.
///
/// Whether the probe is actually laid out on every frame of an interactive dismissal — the
/// reason the reader exists — is not reachable here; it stays in `docs/MOBILE.md`'s checklist,
/// per this suite's own rule.
@MainActor
final class KeyboardOverlapReaderTests: XCTestCase {
    /// Keyboard down: the guide's top sits at the top of the safe-area inset, so the probe is
    /// exactly as tall as the home indicator strip and the composer must not move at all.
    func testAHiddenKeyboardLiftsNothing() {
        XCTAssertEqual(KeyboardOverlapReader.overlap(probeHeight: 34, safeBottom: 34), 0)
    }

    /// Keyboard up: the lift is the keyboard's height LESS the home-indicator inset, because
    /// the `safeAreaInset` the composer lives in already sits above that inset. Adding the
    /// whole height would float the field 34pt above the keyboard.
    func testARaisedKeyboardLiftsByItsHeightAboveTheHomeIndicator() {
        XCTAssertEqual(KeyboardOverlapReader.overlap(probeHeight: 336, safeBottom: 34), 302)
    }

    /// Never negative. A probe shorter than the inset (a transient layout pass, or a device
    /// whose guide ignores the safe area) must read as "no keyboard", not as a request to push
    /// the composer DOWN into the home indicator.
    func testTheLiftIsNeverNegative() {
        XCTAssertEqual(KeyboardOverlapReader.overlap(probeHeight: 0, safeBottom: 34), 0)
    }
}
