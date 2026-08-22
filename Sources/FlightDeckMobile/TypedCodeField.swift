import FleetKit

/// The typed-code field's state and the two decisions it makes, lifted out of `PairingScreen`.
///
/// It lives here rather than in a pair of `@State` properties because the properties worth
/// guarding are behavioural, not visual: that what a user types is rewritten into the Mac's
/// own `XXXX-XXXX-XXXX` shape on every keystroke, and that a code whose checksum fails
/// produces a verdict *instead of* a pairing attempt (spec §7). `PairingCode.grouped(partial:)`
/// and `PairingCode(normalizing:)` are both covered in `FleetKit`; what was never covered is
/// that the field calls them at all, and a field that stopped would look identical to source
/// that still read as if it did.
///
/// What deliberately did NOT move here is everything SwiftUI owns: where the caret lands when
/// `text` is reassigned mid-string, and whether the software keyboard honours
/// `.textInputAutocapitalization(.characters)`. Neither is reachable from a unit test at all —
/// they are `docs/MOBILE.md`'s iOS-plumbing items 10 and 11, and they stay there.
struct TypedCodeField {
    /// Bound straight to the `TextField`, so this is exactly what the user sees.
    var text = ""

    /// What the field should read after this keystroke.
    ///
    /// Run from `.onChange`, so the field always looks like the Mac's screen rather than
    /// like whatever the keyboard produced. The `!=` is a re-entrancy guard, not tidiness:
    /// assigning an unchanged value re-fires `.onChange` on some SwiftUI versions, and the
    /// loop shows up as a field that freezes or eats every second keystroke.
    mutating func reformat() {
        let formatted = PairingCode.grouped(partial: text)
        if formatted != text { text = formatted }
    }

    /// Whether the Pair button is live.
    ///
    /// Twelve symbols is the gate, **not** a valid checksum: a button that stayed dead on a
    /// mistyped code would leave the user with no way to be told it was mistyped. So a
    /// full-length code always submits, and `submit()` is what says no.
    var canSubmit: Bool { PairingCode(normalizing: text) != nil || text.count >= 14 }

    /// What a tap on Pair produced. `rejected` carries the copy because the alternative — a
    /// `Bool` and a message chosen by the caller — is how the two ends drift apart.
    enum Submission: Equatable {
        case pair(PairingCode)
        case rejected(String)
    }

    /// The checksum is checked **here**, before anything opens a socket — a mistyped code must
    /// cost no attempt against the Mac's three (spec §7), and "that code doesn't look right"
    /// and "pairing failed" send the user to different places.
    ///
    /// Returning a `PairingCode` rather than a `String` is what makes that structural:
    /// `FleetModel.pair(code:)` cannot be handed a code that failed its checksum.
    func submit() -> Submission {
        guard let code = PairingCode(normalizing: text) else {
            return .rejected("That code doesn't look right. Check it against your Mac.")
        }
        return .pair(code)
    }
}
