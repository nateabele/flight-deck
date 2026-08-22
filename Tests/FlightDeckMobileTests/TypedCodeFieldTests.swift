import FleetKit
import XCTest
@testable import FlightDeckMobile

/// `PairingCode.grouped(partial:)` and `PairingCode(normalizing:)` are covered against every
/// edge in `FleetKit`'s own suite, on macOS. Nothing covered that the *field* calls them —
/// which is the half that shipped, and the half a reviewer can only confirm by reading.
///
/// So these four are deliberately the only four. Two more were written and cut because no
/// mutation of this file could make them fail: the twelve-symbol cap and the idempotence of
/// `reformat()` are both properties of `PairingCode.grouped`, already asserted where they
/// live. `reformat()`'s `!=` re-entrancy guard in particular is unfalsifiable here — removing
/// it produces the identical string and only loops once SwiftUI re-fires `.onChange`, which
/// is docs/MOBILE.md's iOS-plumbing item 11 and not a unit test.
final class TypedCodeFieldTests: XCTestCase {
    /// Ambiguous letters included on purpose: Crockford maps `O`→`0` and `I`/`L`→`1`, and a
    /// user reading twelve characters off a Mac across a room produces exactly those. The
    /// hyphens are not typed — the field inserts them, so what the phone shows and what the
    /// Mac shows are the same shape.
    func testTypingIsUppercasedGroupedAndDisambiguatedAsItGoes() {
        var field = TypedCodeField()
        field.text = "oil3abcd5678"
        field.reformat()
        XCTAssertEqual(field.text, "0113-ABCD-5678")
    }

    /// Spec §7, and the reason the checksum symbol exists at all: a mistyped code must be
    /// refused here, on the phone, rather than spend one of the Mac's three attempts finding
    /// out the same thing. `submit()` returning `.rejected` is what makes that structural —
    /// there is no `PairingCode` for `FleetModel.pair(code:)` to be handed.
    func testAFailedChecksumIsRejectedInsteadOfBecomingAPairingAttempt() {
        var field = TypedCodeField()
        field.text = Self.codeWithABrokenChecksum()

        guard case .rejected(let message) = field.submit() else {
            return XCTFail("a code that fails its checksum must not produce a PairingCode")
        }
        XCTAssertEqual(message, "That code doesn't look right. Check it against your Mac.")
    }

    func testACorrectCodeSubmitsAsThatExactCode() {
        let minted = PairingCode.mint()
        var field = TypedCodeField()
        field.text = minted.formatted
        XCTAssertEqual(field.submit(), .pair(minted))
    }

    /// Deliberately NOT gated on the checksum: the button enables on twelve symbols even when
    /// they are wrong, so the user gets the verdict above instead of a dead button they have
    /// no way to act on. Both halves are asserted, because a mutation to either one is
    /// invisible on a correctly typed code.
    func testThePairButtonEnablesOnTwelveSymbolsEvenWhenTheChecksumFails() {
        var field = TypedCodeField()

        field.text = "0113-ABCD-567"
        XCTAssertFalse(field.canSubmit, "eleven symbols is not a code yet")

        field.text = Self.codeWithABrokenChecksum()
        XCTAssertTrue(field.canSubmit, "a full-length code must be submittable to be refused")

        field.text = PairingCode.mint().formatted
        XCTAssertTrue(field.canSubmit)
    }

    /// A well-formed twelve-symbol code whose check symbol is deliberately not the one its
    /// entropy implies. Built by mutating a minted code rather than hard-coded, because the
    /// check symbol is five bits of SHA-256 over the packed secret and a literal would be a
    /// number nobody could re-derive when it needed changing.
    private static func codeWithABrokenChecksum() -> String {
        let formatted = PairingCode.mint().formatted     // "XXXX-XXXX-XXXX"
        let check = formatted.last!
        // Any other alphabet symbol; the entropy is untouched, so the checksum cannot match.
        let wrong: Character = check == "0" ? "1" : "0"
        let broken = formatted.dropLast() + String(wrong)
        XCTAssertNil(PairingCode(normalizing: String(broken)))
        return String(broken)
    }
}
