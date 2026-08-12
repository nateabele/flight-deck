import XCTest
@testable import FlightDeck

final class ClaudeFlagParserTests: XCTestCase {
    func testParsesToggle() {
        let result = ClaudeFlagParser.parse("--verbose")
        XCTAssertEqual(result.flags.values["--verbose"], .on)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testParsesValueFlag() {
        XCTAssertEqual(ClaudeFlagParser.parse("--model opus").flags.values["--model"], .value("opus"))
    }

    func testParsesEqualsForm() {
        XCTAssertEqual(ClaudeFlagParser.parse("--model=opus").flags.values["--model"], .value("opus"))
    }

    func testResolvesAliasToCanonicalKey() {
        let flags = ClaudeFlagParser.parse("--allowed-tools Edit").flags
        XCTAssertEqual(flags.values["--allowedTools"], .list(["Edit"]))
        XCTAssertNil(flags.values["--allowed-tools"])
    }

    func testParsesNegatableOnAndOff() {
        XCTAssertEqual(ClaudeFlagParser.parse("--chrome").flags.values["--chrome"], .value("on"))
        XCTAssertEqual(ClaudeFlagParser.parse("--no-chrome").flags.values["--chrome"], .value("off"))
    }

    func testListFlagConsumesAllFollowingNonFlagTokens() {
        let flags = ClaudeFlagParser.parse("--add-dir a b c --verbose").flags
        XCTAssertEqual(flags.values["--add-dir"], .list(["a", "b", "c"]))
        XCTAssertEqual(flags.values["--verbose"], .on)
    }

    func testRepeatedListFlagAccumulates() {
        let flags = ClaudeFlagParser.parse("--plugin-dir a --plugin-dir b").flags
        XCTAssertEqual(flags.values["--plugin-dir"], .list(["a", "b"]))
    }

    func testOptionalValueTakesNextTokenWhenNotAFlag() {
        XCTAssertEqual(ClaudeFlagParser.parse("--debug api,hooks").flags.values["--debug"],
                       .value("api,hooks"))
    }

    func testOptionalValueIsBareWhenFollowedByAFlag() {
        let flags = ClaudeFlagParser.parse("--debug --verbose").flags
        XCTAssertEqual(flags.values["--debug"], .on)
        XCTAssertEqual(flags.values["--verbose"], .on)
    }

    func testOptionalValueIsBareAtEndOfInput() {
        XCTAssertEqual(ClaudeFlagParser.parse("--debug").flags.values["--debug"], .on)
    }

    func testQuotedValuePreservesSpaces() {
        XCTAssertEqual(ClaudeFlagParser.parse("--system-prompt 'be terse'").flags.values["--system-prompt"],
                       .value("be terse"))
    }

    func testValueFlagMissingItsValueWarnsAndIsDropped() {
        let result = ClaudeFlagParser.parse("--model")
        XCTAssertNil(result.flags.values["--model"])
        XCTAssertEqual(result.diagnostics.first?.severity, .warning)
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("--model") })
    }

    // MARK: passthrough

    func testUnknownFlagAndItsValuesGoToPassthroughVerbatim() {
        let result = ClaudeFlagParser.parse("--not-real a b --verbose")
        XCTAssertEqual(result.flags.passthrough, ["--not-real", "a", "b"])
        XCTAssertEqual(result.flags.values["--verbose"], .on)
    }

    func testUnknownFlagWarns() {
        let result = ClaudeFlagParser.parse("--modle opus")
        XCTAssertEqual(result.diagnostics.first?.severity, .warning)
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("--modle") })
    }

    func testBarePositionalGoesToPassthrough() {
        XCTAssertEqual(ClaudeFlagParser.parse("just some words").flags.passthrough,
                       ["just", "some", "words"])
    }

    func testAppManagedFlagIsRejectedToPassthroughWithWarning() {
        let result = ClaudeFlagParser.parse("--session-id abc")
        XCTAssertNil(result.flags.values["--session-id"])
        XCTAssertEqual(result.flags.passthrough, ["--session-id", "abc"])
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("managed by Flight Deck") })
    }

    func testUnknownFlagInEqualsFormIsReassembledIntoPassthrough() {
        let result = ClaudeFlagParser.parse("--not-real=foo --verbose")
        XCTAssertEqual(result.flags.passthrough, ["--not-real=foo"])
        XCTAssertEqual(result.flags.values["--verbose"], .on)
    }

    func testAppManagedFlagInEqualsFormIsReassembledIntoPassthrough() {
        let result = ClaudeFlagParser.parse("--session-id=abc")
        XCTAssertNil(result.flags.values["--session-id"])
        XCTAssertEqual(result.flags.passthrough, ["--session-id=abc"])
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("managed by Flight Deck") })
    }

    func testKnownFlagInEqualsFormWithEmptyValueRecordsEmptyString() {
        XCTAssertEqual(ClaudeFlagParser.parse("--model=").flags.values["--model"], .value(""))
    }

    // MARK: duplicates

    func testDuplicateFlagWarnsAndLastValueWins() {
        let result = ClaudeFlagParser.parse("--model opus --model sonnet")
        XCTAssertEqual(result.flags.values["--model"], .value("sonnet"))
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("more than once") })
    }

    func testChromeAndNoChromeAreReportedAsADuplicate() {
        let result = ClaudeFlagParser.parse("--chrome --no-chrome")
        XCTAssertEqual(result.flags.values["--chrome"], .value("off"))
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("more than once") })
    }

    // MARK: errors

    func testUnterminatedQuoteIsAnErrorAndYieldsNoFlags() {
        let result = ClaudeFlagParser.parse("--name 'oops")
        XCTAssertTrue(result.flags.isEmpty)
        XCTAssertEqual(result.diagnostics.first?.severity, .error)
    }

    func testEmptyInputIsCleanAndEmpty() {
        let result = ClaudeFlagParser.parse("   ")
        XCTAssertTrue(result.flags.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }
}
