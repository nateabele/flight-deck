import XCTest
@testable import FlightDeck

final class ClaudeFlagCatalogTests: XCTestCase {
    func testLooksUpByCanonicalName() {
        XCTAssertEqual(ClaudeFlagCatalog.spec(for: "--model")?.canonical, "--model")
    }

    func testLooksUpByAlias() {
        XCTAssertEqual(ClaudeFlagCatalog.spec(for: "--allowed-tools")?.canonical, "--allowedTools")
    }

    func testLooksUpByNegatedFormOfNegatableFlag() {
        XCTAssertEqual(ClaudeFlagCatalog.spec(for: "--no-chrome")?.canonical, "--chrome")
    }

    func testUnknownFlagHasNoSpec() {
        XCTAssertNil(ClaudeFlagCatalog.spec(for: "--not-a-real-flag"))
    }

    func testAppManagedFlagsAreNotInTheCatalog() {
        for name in ClaudeFlagCatalog.appManaged {
            XCTAssertNil(ClaudeFlagCatalog.spec(for: name), "\(name) must not be user-editable")
        }
    }

    func testPrintOnlyAndSessionIdentityFlagsAreExcluded() {
        for name in ["--print", "--output-format", "--resume", "--continue", "--cloud", "--bg"] {
            XCTAssertNil(ClaudeFlagCatalog.spec(for: name), "\(name) must not have a control")
        }
    }

    func testCanonicalNamesAreUnique() {
        let names = ClaudeFlagCatalog.all.map(\.canonical)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testEverySpecIsReachableByItsOwnCanonicalName() {
        for spec in ClaudeFlagCatalog.all {
            XCTAssertEqual(ClaudeFlagCatalog.spec(for: spec.canonical)?.canonical, spec.canonical)
        }
    }

    func testEveryAliasResolvesToItsOwnSpec() {
        for spec in ClaudeFlagCatalog.all {
            for alias in spec.aliases {
                XCTAssertEqual(ClaudeFlagCatalog.spec(for: alias)?.canonical, spec.canonical)
            }
        }
    }

    func testCatalogCoversTheThirtySixSpecifiedOptions() {
        XCTAssertEqual(ClaudeFlagCatalog.all.count, 36)
    }

    func testEverySectionHasAtLeastOneFlag() {
        for section in FlagSpec.Section.allCases {
            XCTAssertFalse(
                ClaudeFlagCatalog.all.filter { $0.section == section }.isEmpty,
                "\(section) is empty"
            )
        }
    }
}
