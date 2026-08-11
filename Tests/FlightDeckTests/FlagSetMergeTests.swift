import XCTest
@testable import FlightDeck

final class FlagSetMergeTests: XCTestCase {
    func testProjectValueWinsForTheSameKey() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(values: ["--model": .value("opus")]),
            project: FlagSet(values: ["--model": .value("sonnet")])
        )
        XCTAssertEqual(merged.values["--model"], .value("sonnet"))
    }

    func testKeysAbsentFromProjectAreInherited() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(values: ["--model": .value("opus"), "--effort": .value("high")]),
            project: FlagSet(values: ["--model": .value("sonnet")])
        )
        XCTAssertEqual(merged.values["--effort"], .value("high"))
    }

    func testKeysOnlyInProjectAreAdded() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(),
            project: FlagSet(values: ["--verbose": .on])
        )
        XCTAssertEqual(merged.values["--verbose"], .on)
    }

    func testEmptyProjectInheritsEverything() {
        let global = FlagSet(values: ["--model": .value("opus")], passthrough: ["--x"])
        XCTAssertEqual(FlagSetMerge.merge(global: global, project: FlagSet()), global)
    }

    /// Absent key means inherit; a present-but-empty list is a real override meaning
    /// "off". This distinction is the whole per-flag merge and must not regress.
    func testPresentButEmptyListOverridesRatherThanInherits() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(values: ["--add-dir": .list(["a"])]),
            project: FlagSet(values: ["--add-dir": .list([])])
        )
        XCTAssertEqual(merged.values["--add-dir"], .list([]))
    }

    func testPassthroughTailsConcatenateGlobalFirst() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(passthrough: ["--g"]),
            project: FlagSet(passthrough: ["--p"])
        )
        XCTAssertEqual(merged.passthrough, ["--g", "--p"])
    }
}
