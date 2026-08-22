import XCTest
import FleetKit
@testable import FlightDeck

/// The sheet's own logic, which is the part a screenshot cannot check: that the string put in
/// front of the user is the code the listener is actually holding, in the grouped form.
///
/// SwiftUI rendering is not asserted here. The three defects this sheet has already shipped —
/// an empty sheet, a QR that appeared to churn, and a warning that truncated instead of
/// wrapping — were all layout facts, and none of them is reachable from a unit test: they are
/// only visible once something lays the view out. Asserting on the font or the frame here
/// would be asserting that the source says what the source says. What *is* asserted is the
/// value, because the failure mode worth catching is a sheet that displays one window's code
/// beside another window's QR, and that one looks completely normal on screen.
@MainActor
final class PairingCodeSheetTests: XCTestCase {
    private func window() -> ArmedPairing {
        PairingArmer().arm(
            macName: "Nate's MacBook Pro",
            serviceName: "flightdeck-macbook-a1b2",
            endpoints: ["192.168.1.20:53211"]
        )
    }

    func testTheDisplayedCodeIsTheWindowsCodeInGroupedForm() {
        let armed = window()
        let displayed = PairingCodeSheet.displayedCode(for: armed)
        XCTAssertEqual(displayed, armed.code.formatted)
        XCTAssertEqual(displayed.count, 14)
        XCTAssertEqual(displayed.filter { $0 == "-" }.count, 2)
    }

    /// The two halves of one window must come from one value. A sheet handed a code and a
    /// payload separately can draw a code from one window beside a QR from another, and the
    /// user would have no way to tell.
    func testTheQRAndTheCodeComeFromTheSameWindow() {
        let armed = window()
        let sheetCode = PairingCodeSheet.displayedCode(for: armed)
        let qrPayload = PairingCodeSheet.qrCode(for: armed)
        XCTAssertEqual(sheetCode, armed.code.formatted)
        XCTAssertEqual(qrPayload, armed.payload.encoded())
        XCTAssertFalse(qrPayload.contains(armed.payload.key.slot.uuidString))
    }

    /// The typed code is not in the QR and the QR's body is not the typed code. They are two
    /// independent secrets — the payload carries the device key, the code is a SPAKE2 password
    /// for one window — and a sheet that showed a substring of the payload as "the code" would
    /// hand a shoulder-surfer with a camera the thing SPAKE2 exists to protect.
    func testTheTypedCodeIsNotCarriedInTheQR() {
        let armed = window()
        let qrPayload = PairingCodeSheet.qrCode(for: armed)
        // Both forms. Grouping is presentation, so a payload that carried the code with its
        // hyphens in would leak exactly as much as one that carried it without them.
        let displayed = PairingCodeSheet.displayedCode(for: armed)
        XCTAssertFalse(qrPayload.contains(displayed))
        XCTAssertFalse(qrPayload.contains(displayed.replacingOccurrences(of: "-", with: "")))
    }

    /// Every character on screen is from the code's alphabet, so the four symbols a person
    /// substitutes — `I`, `L`, `O`, `U` — never appear in something they are asked to read
    /// aloud and type. Both cases, because a lowercased display would reintroduce exactly the
    /// pair the alphabet omits `L` to avoid.
    func testTheDisplayedCodeContainsNoAmbiguousCharacters() {
        for _ in 0..<50 {
            let displayed = PairingCodeSheet.displayedCode(for: window())
            XCTAssertFalse(displayed.contains { "ILOUilou".contains($0) })
        }
    }

    /// Uppercase, always. The Crockford alphabet is only unambiguous in one case — lowercase
    /// `l` against `1` is the exact substitution the alphabet omits `I` and `L` to prevent —
    /// and the code is read off this screen and typed into a phone.
    func testTheDisplayedCodeIsUppercase() {
        for _ in 0..<50 {
            let displayed = PairingCodeSheet.displayedCode(for: window())
            XCTAssertEqual(displayed, displayed.uppercased())
        }
    }

    /// The groups are what make fourteen characters readable across a room: four, four, four.
    /// A code that arrived ungrouped, or grouped unevenly, would still be correct and still be
    /// unusable at the distance it is meant to be read from.
    func testTheDisplayedCodeIsThreeGroupsOfFour() {
        let groups = PairingCodeSheet.displayedCode(for: window()).split(separator: "-")
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.count), [4, 4, 4])
    }

    /// What the user types back is what the Mac minted. The display goes through grouping and
    /// uppercasing; `PairingCode(normalizing:)` has to undo both and land on the same secret,
    /// or the code on screen is a code that does not work.
    func testTheDisplayedCodeRoundTripsBackToTheSameSecret() throws {
        let armed = window()
        let displayed = PairingCodeSheet.displayedCode(for: armed)
        let retyped = try XCTUnwrap(PairingCode(normalizing: displayed))
        XCTAssertEqual(retyped, armed.code)
    }
}
