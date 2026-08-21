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

    /// The password handed to SPAKE2 is the 55 bits, not the display string — so hyphenation
    /// and case cannot change what the two sides prove knowledge of.
    func testTheSecretIsIndependentOfPresentation() {
        let code = PairingCode.mint()
        let bare = code.formatted.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertEqual(PairingCode(normalizing: bare)?.secret, code.secret)
        XCTAssertEqual(code.secret.count, 7)
    }
}
