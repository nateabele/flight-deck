import XCTest
@testable import FlightDeckMobile

/// The decisions `KeyboardOverlapReader` makes that a simulator test can reach: how far the
/// composer must lift for a keyboard whose top edge the probe measured, and for a
/// `keyboardWillChangeFrame` end frame — which on iPad may not be a docked keyboard at all.
///
/// Whether the probe is actually laid out on every frame of an interactive dismissal — the
/// reason the reader exists — and whether its first report after re-entering a window
/// re-settles the composer are not reachable here; they stay in `docs/MOBILE.md`'s checklist,
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

    // MARK: - The notification's end frame

    // `keyboardWillChangeFrame` reports where the keyboard will END, and on iPad that is not
    // always a docked keyboard: a floating or split one ends mid-screen, and an undocked one can
    // end at `CGRect.zero`. Measured as "window height minus the frame's top", either reads as a
    // keyboard the height of the whole window — the composer thrown off the top of the screen and
    // the `List` padded by a screen until the next docked event. Only a frame that reaches the
    // window's bottom edge is a keyboard the composer has to clear.

    private let phone = CGRect(x: 0, y: 0, width: 393, height: 852)

    /// Docked: the keyboard's height above the bottom edge, less the home-indicator inset —
    /// the same answer the probe gives for the same keyboard.
    func testADockedEndFrameLiftsByItsHeightAboveTheHomeIndicator() {
        let keyboard = CGRect(x: 0, y: 516, width: 393, height: 336)
        XCTAssertEqual(KeyboardOverlapReader.overlap(
            keyboardEnd: keyboard, windowBounds: phone, safeBottom: 34), 302)
    }

    /// A hide ends the keyboard below the window: it reaches the bottom edge and overlaps none
    /// of it, so it lifts nothing.
    func testAKeyboardEndingOffscreenLiftsNothing() {
        let keyboard = CGRect(x: 0, y: 852, width: 393, height: 336)
        XCTAssertEqual(KeyboardOverlapReader.overlap(
            keyboardEnd: keyboard, windowBounds: phone, safeBottom: 34), 0)
    }

    /// `CGRect.zero` — what an undocked keyboard can report — is not a keyboard at the top of
    /// the window, it is no docked keyboard at all.
    func testAZeroEndFrameLiftsNothing() {
        XCTAssertEqual(KeyboardOverlapReader.overlap(
            keyboardEnd: .zero, windowBounds: phone, safeBottom: 34), 0)
    }

    /// A floating keyboard in the middle of an iPad window covers no bottom edge the composer
    /// sits on; lifting by "window height minus its top" would fling the field most of a screen.
    func testAFloatingEndFrameLiftsNothing() {
        let pad = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        let floating = CGRect(x: 350, y: 600, width: 320, height: 260)
        XCTAssertEqual(KeyboardOverlapReader.overlap(
            keyboardEnd: floating, windowBounds: pad, safeBottom: 20), 0)
    }

    /// A Stage Manager window does not start at the screen origin, so the keyboard — converted
    /// into the window — spills past the window's sides and bottom. Only the part inside the
    /// window counts: 750 − 600 = 150pt of keyboard over a 600pt window, not its full 300.
    func testAWindowOffsetFromTheScreenCountsOnlyTheKeyboardInsideIt() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let keyboard = CGRect(x: -120, y: 450, width: 1366, height: 300)
        XCTAssertEqual(KeyboardOverlapReader.overlap(
            keyboardEnd: keyboard, windowBounds: window, safeBottom: 0), 150)
    }
}
