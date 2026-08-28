import XCTest
@testable import FlightDeck

/// The shipped libghostty defaults, asserted because their absence is invisible.
///
/// A missing unbind here does not produce an error, a warning, or a wrong-looking menu. The
/// menu item renders with its shortcut and silently never fires, because
/// `MenuKeyEquivalents.shouldOfferToMenu` withholds performable bindings from the menu and
/// `Ghostty.SurfaceView.performKeyEquivalent` swallows the key. Only a test catches it.
final class GhosttyDefaultsTests: XCTestCase {
    private func defaultsConfig() throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "GhosttyDefaults", withExtension: "conf")
                ?? Bundle.main.url(forResource: "GhosttyDefaults", withExtension: "conf")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// ⌘K is Ghostty's clear_screen, bound performable. Search cannot have it until this
    /// unbind ships.
    func testCommandKIsUnboundSoTheSearchMenuItemCanFire() throws {
        XCTAssertTrue(try defaultsConfig().contains("keybind = super+k=unbind"))
    }

    /// The precedent, still in place: ⌘⇧T belongs to Reopen Closed Session.
    func testCommandShiftTRemainsUnbound() throws {
        XCTAssertTrue(try defaultsConfig().contains("keybind = super+shift+t=unbind"))
    }
}
