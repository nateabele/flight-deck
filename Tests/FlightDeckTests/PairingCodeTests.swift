import XCTest
import FleetKit

final class PairingCodeTests: XCTestCase {
    func testAMintedCodeFormatsAsTwelveSymbolsInThreeGroups() {
        let code = PairingCode.mint()
        XCTAssertEqual(code.formatted.count, 14, "12 symbols plus two hyphens")
        let groups = code.formatted.split(separator: "-")
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.count == 4 })
    }

    /// The alphabet is the whole reason this is typable. `I`, `L`, `O` and `U` are absent:
    /// the first three because they are unreadable next to `1` and `0`, and `U` because
    /// excluding it is what keeps an accidental obscenity out of a code the user reads aloud.
    func testTheAlphabetExcludesTheAmbiguousLetters() {
        let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        for _ in 0..<200 {
            let symbols = PairingCode.mint().formatted.filter { $0 != "-" }
            XCTAssertTrue(symbols.allSatisfy { alphabet.contains($0) }, "\(symbols)")
        }
    }

    func testAMintedCodeRoundTripsThroughItsOwnFormatting() {
        let code = PairingCode.mint()
        XCTAssertEqual(PairingCode(normalizing: code.formatted), code)
    }

    /// Someone reading a code off a screen across the room types what they hear, in whatever
    /// case their keyboard is in, with or without the hyphens we added for legibility.
    func testInputIsNormalizedBeforeItIsJudged() {
        let code = PairingCode.mint()
        let bare = code.formatted.replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(PairingCode(normalizing: bare.lowercased()), code)
        XCTAssertEqual(PairingCode(normalizing: "  \(code.formatted)  "), code)
        let spaced = bare.map { String($0) }.joined(separator: " ")
        XCTAssertEqual(PairingCode(normalizing: spaced), code,
                       "spaces anywhere are noise, not signal")
    }

    /// The checksum is what makes a 3-attempt budget workable: a typo must be caught here,
    /// on the device, rather than spending a third of the budget to learn it on the Mac.
    func testASingleCharacterTypoIsRejectedLocally() {
        let code = PairingCode.mint()
        var symbols = Array(code.formatted.filter { $0 != "-" })
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var rejected = 0
        for position in symbols.indices {
            let original = symbols[position]
            for replacement in alphabet where replacement != original {
                symbols[position] = replacement
                if PairingCode(normalizing: String(symbols)) == nil { rejected += 1 }
            }
            symbols[position] = original
        }
        // A 5-bit checksum catches 31/32 of single-symbol errors. Assert the rate rather than
        // "all", because claiming a 5-bit check is perfect would be a lie a future reader
        // might rely on.
        let total = symbols.count * (alphabet.count - 1)
        XCTAssertGreaterThan(Double(rejected) / Double(total), 0.9)
    }

    func testGarbageIsRejectedRatherThanCrashing() {
        XCTAssertNil(PairingCode(normalizing: ""))
        XCTAssertNil(PairingCode(normalizing: "TOO-SHORT"))
        XCTAssertNil(PairingCode(normalizing: "IIII-LLLL-OOOO"), "excluded letters are not symbols")
        XCTAssertNil(PairingCode(normalizing: "!!!!-!!!!-!!!!"))
    }

    /// Two codes minted in a row must differ. A stuck CSPRNG or a mis-masked value that
    /// collapsed the space would otherwise pass every other test in this file.
    func testMintedCodesAreNotRepeating() {
        let codes = Set((0..<500).map { _ in PairingCode.mint().formatted })
        XCTAssertEqual(codes.count, 500)
    }

    /// `mint()` masks byte 0's top bit off, and that mask is not cosmetic: `pack()` never sets
    /// it for any input, so a minted secret carrying it would be a value no formatted code can
    /// round-trip back to. Deleting the mask still passes most of this file — only three tests
    /// mint and round-trip, each catching it with p≈0.5, which measured out at 7 failures in 40
    /// runs. This one catches it every time.
    func testAMintedSecretNeverSetsTheBitAboveItsFiftyFive() {
        for _ in 0..<200 {
            XCTAssertEqual(PairingCode.mint().secret[0] & 0x80, 0)
        }
    }

    /// The password handed to SPAKE2 is the 55 bits, not the display string — so hyphenation
    /// and case cannot change what the two sides prove knowledge of.
    func testTheSecretIsIndependentOfPresentation() {
        let code = PairingCode.mint()
        let bare = code.formatted.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertEqual(PairingCode(normalizing: bare)?.secret, code.secret)
        XCTAssertEqual(code.secret.count, 7)
    }

    /// The field rewrites what the user types as they type it, so the string on screen always
    /// looks like the string on the Mac. Without this the two are compared by eye across a
    /// room while one of them has hyphens and the other does not.
    func testGroupingInsertsTheHyphensAsYouType() {
        XCTAssertEqual(PairingCode.grouped(partial: ""), "")
        XCTAssertEqual(PairingCode.grouped(partial: "AB"), "AB")
        XCTAssertEqual(PairingCode.grouped(partial: "ABCD"), "ABCD")
        XCTAssertEqual(PairingCode.grouped(partial: "ABCDE"), "ABCD-E")
        XCTAssertEqual(PairingCode.grouped(partial: "ABCDEFGH"), "ABCD-EFGH")
        XCTAssertEqual(PairingCode.grouped(partial: "ABCDEFGHJKMN"), "ABCD-EFGH-JKMN")
    }

    /// `.textInputAutocapitalization(.characters)` asks the keyboard to send uppercase; a
    /// hardware keyboard, a paste, and dictation all ignore it. The rewrite is what actually
    /// guarantees it, which is why the field cannot rely on the modifier alone.
    func testGroupingUppercasesWhateverArrives() {
        XCTAssertEqual(PairingCode.grouped(partial: "abcdefgh"), "ABCD-EFGH")
    }

    /// Crockford's own substitutions, applied on input rather than rejected. The alphabet
    /// omits `I`, `L` and `O` precisely because a person reading a code aloud produces them —
    /// so typing one is the expected mistake, and the expected mistake should work.
    func testGroupingMapsTheAmbiguousLettersRatherThanRejectingThem() {
        XCTAssertEqual(PairingCode.grouped(partial: "OIL"), "011")
        XCTAssertEqual(PairingCode.grouped(partial: "oil"), "011")
    }

    /// `U` is dropped rather than mapped: Crockford excludes it to avoid accidental
    /// obscenity, and it has no digit to stand for. Everything else outside the alphabet —
    /// spaces, the hyphens the user retypes, punctuation — is dropped for the same reason
    /// `init(normalizing:)` strips them: they are presentation, not content.
    func testGroupingDropsWhatItCannotMap() {
        XCTAssertEqual(PairingCode.grouped(partial: "AB CD-EF!GH"), "ABCD-EFGH")
        XCTAssertEqual(PairingCode.grouped(partial: "ABUCD"), "ABCD")
    }

    /// Twelve symbols and no more. Without the cap the field grows past the code's length and
    /// the user's own extra keystroke silently invalidates something that was already correct.
    func testGroupingStopsAtTwelveSymbols() {
        let long = PairingCode.grouped(partial: "ABCDEFGHJKMNPQRSTV")
        XCTAssertEqual(long, "ABCD-EFGH-JKMN")
        XCTAssertEqual(long.filter { $0 != "-" }.count, 12)
    }

    /// The formatter and the parser have to agree, or the field shows a string the phone then
    /// refuses. Re-running the formatter over its own output must change nothing, and its
    /// output must parse back to the code it came from.
    func testAFormattedCodeIsAFixedPointOfTheFormatterAndStillParses() throws {
        for _ in 0..<50 {
            let code = PairingCode.mint()
            let grouped = PairingCode.grouped(partial: code.formatted)
            XCTAssertEqual(grouped, code.formatted)
            XCTAssertEqual(PairingCode(normalizing: grouped), code)
        }
    }
}
