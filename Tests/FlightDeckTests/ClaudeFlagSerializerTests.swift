import XCTest
@testable import FlightDeck

final class ClaudeFlagSerializerTests: XCTestCase {
    func testSerializesToggle() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--verbose": .on])), "--verbose")
    }

    func testSerializesValue() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--model": .value("opus")])),
                       "--model opus")
    }

    func testSerializesNegatableOnAndOff() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--chrome": .value("on")])),
                       "--chrome")
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--chrome": .value("off")])),
                       "--no-chrome")
    }

    func testSerializesList() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--add-dir": .list(["a", "b"])])),
                       "--add-dir a b")
    }

    func testOmitsEmptyList() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--add-dir": .list([])])), "")
    }

    func testQuotesValuesThatNeedIt() {
        XCTAssertEqual(
            ClaudeFlagSerializer.serialize(FlagSet(values: ["--system-prompt": .value("be terse")])),
            "--system-prompt 'be terse'"
        )
    }

    func testOrderIsStableAndFollowsCatalogOrder() {
        let flags = FlagSet(values: ["--verbose": .on, "--model": .value("opus")])
        // --model is in Model & Effort, --verbose in Troubleshooting.
        XCTAssertEqual(ClaudeFlagSerializer.serialize(flags), "--model opus --verbose")
    }

    func testPassthroughLeadsSoAListFlagCannotAbsorbIt() {
        let flags = FlagSet(values: ["--verbose": .on], passthrough: ["--not-real", "a b"])
        XCTAssertEqual(ClaudeFlagSerializer.serialize(flags), "--not-real 'a b' --verbose")
    }

    func testEmptySetSerializesToEmptyString() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet()), "")
    }

    // MARK: the invariant

    func testRoundTripAcrossEveryKindInTheCatalog() {
        let flags = FlagSet(
            values: [
                "--verbose": .on,                                   // toggle
                "--chrome": .value("off"),                          // negatable
                "--effort": .value("high"),                         // choice
                "--model": .value("claude-opus-5"),                 // choice, custom
                "--debug": .value("api,hooks"),                     // optionalValue with value
                "--brief": .on,                                     // toggle
                "--agent": .value("reviewer"),                      // string
                "--system-prompt": .value("be terse; use $VARS"),   // multiline, needs quoting
                "--debug-file": .value("/tmp/a b.log"),             // path, needs quoting
                "--add-dir": .list(["../shared", "/tmp/x y"]),      // list, one needs quoting
            ],
            passthrough: ["--not-real", "a b", "--another"]
        )
        let round = ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags))
        XCTAssertEqual(round.flags, flags)
    }

    func testRoundTripOfBareOptionalValue() {
        let flags = FlagSet(values: ["--debug": .on, "--verbose": .on])
        XCTAssertEqual(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).flags, flags)
    }

    func testRoundTripPreservesInjectionAttemptAsLiteralText() {
        let flags = FlagSet(values: ["--system-prompt": .value("'; rm -rf ~; '")])
        XCTAssertEqual(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).flags, flags)
    }

    func testRoundTripIsCleanOfDiagnostics() {
        let flags = FlagSet(values: ["--model": .value("opus"), "--verbose": .on])
        XCTAssertTrue(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).diagnostics.isEmpty)
    }

    func testRoundTripOfAValueThatLooksLikeAFlag() {
        let flags = FlagSet(values: ["--system-prompt": .value("--verbose")])
        XCTAssertEqual(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).flags, flags)
    }

    func testRoundTripOfAListItemThatLooksLikeAFlag() {
        let flags = FlagSet(values: ["--add-dir": .list(["-foo", "--bar"])])
        XCTAssertEqual(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).flags, flags)
    }

    func testRoundTripOfPlainPassthroughAlongsideAListFlag() {
        let flags = FlagSet(values: ["--add-dir": .list(["a"])], passthrough: ["orphan"])
        XCTAssertEqual(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).flags, flags)
    }

    func testRoundTripOfAValueThatLooksLikeAFlagProducesNoDiagnostics() {
        let flags = FlagSet(values: ["--system-prompt": .value("--verbose")])
        XCTAssertTrue(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).diagnostics.isEmpty)
    }
}
