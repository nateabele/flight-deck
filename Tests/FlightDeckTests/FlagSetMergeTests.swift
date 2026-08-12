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

    // MARK: unmerge

    func testUnmergeKeepsANewOverride() {
        let overrides = FlagSetMerge.unmerge(
            merged: FlagSet(values: ["--model": .value("sonnet")]),
            inherited: FlagSet(values: ["--model": .value("opus")])
        )
        XCTAssertEqual(overrides.values["--model"], .value("sonnet"))
    }

    /// Editing a project override back to the global's own value must drop it, so the row
    /// keeps inheriting rather than becoming a redundant explicit override.
    func testUnmergeDropsAnOverrideEditedBackToTheGlobalValue() {
        let overrides = FlagSetMerge.unmerge(
            merged: FlagSet(values: ["--model": .value("opus")]),
            inherited: FlagSet(values: ["--model": .value("opus")])
        )
        XCTAssertNil(overrides.values["--model"])
    }

    /// `FlagSet` cannot express "override to absent" — deleting an inherited keyed flag
    /// from the merged text simply leaves no override for it; `FlagEditor` is responsible
    /// for surfacing that as a warning, not `unmerge`.
    func testUnmergeHasNoOverrideForAnInheritedKeyDeletedFromTheMergedSet() {
        let overrides = FlagSetMerge.unmerge(
            merged: FlagSet(),
            inherited: FlagSet(values: ["--model": .value("opus")])
        )
        XCTAssertNil(overrides.values["--model"])
    }

    func testUnmergeKeepsAProjectOnlyKey() {
        let overrides = FlagSetMerge.unmerge(
            merged: FlagSet(values: ["--verbose": .on]),
            inherited: FlagSet()
        )
        XCTAssertEqual(overrides.values["--verbose"], .on)
    }

    /// A passthrough token the user typed at the front of the field is the project's own,
    /// not a duplicate of the inherited tail that happens to follow it.
    func testUnmergeAttributesAPrependedPassthroughTokenToTheProject() {
        let overrides = FlagSetMerge.unmerge(
            merged: FlagSet(passthrough: ["--new", "--g"]),
            inherited: FlagSet(passthrough: ["--g"])
        )
        XCTAssertEqual(overrides.passthrough, ["--new"])
    }

    /// A token appearing once in `inherited` and twice in `merged` is attributed once: the
    /// first copy is the inherited one, the second is a genuine project addition.
    func testUnmergeAttributesADuplicatedPassthroughTokenOnce() {
        let overrides = FlagSetMerge.unmerge(
            merged: FlagSet(passthrough: ["--dup", "--dup"]),
            inherited: FlagSet(passthrough: ["--dup"])
        )
        XCTAssertEqual(overrides.passthrough, ["--dup"])
    }

    /// The round trip the Projects tab depends on: unmerging a merge recovers the original
    /// project overrides, for a project whose keys all genuinely differ from the global's.
    func testUnmergeInvertsMergeForNonOverlappingKeys() {
        let global = FlagSet(values: ["--model": .value("opus")], passthrough: ["--g"])
        let project = FlagSet(values: ["--effort": .value("high")], passthrough: ["--p"])
        let merged = FlagSetMerge.merge(global: global, project: project)
        XCTAssertEqual(FlagSetMerge.unmerge(merged: merged, inherited: global), project)
    }
}
