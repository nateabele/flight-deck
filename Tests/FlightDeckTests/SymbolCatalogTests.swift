import AppKit
import XCTest
@testable import FlightDeck

@MainActor
final class SymbolCatalogTests: XCTestCase {
    func testAnEmptyQueryReturnsEverything() {
        XCTAssertEqual(SymbolCatalog.matching("").count, SymbolCatalog.all.count)
    }

    func testSearchMatchesKeywordsNotJustSymbolNames() {
        // "git" must find `arrow.triangle.branch`, whose name contains no such substring.
        // Without keywords the picker is only usable by people who already know SF Symbol
        // names, which is nobody.
        let names = SymbolCatalog.matching("git").map(\.name)
        XCTAssertTrue(names.contains("arrow.triangle.branch"), "got \(names)")
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(SymbolCatalog.matching("TERMINAL").map(\.name),
                       SymbolCatalog.matching("terminal").map(\.name))
    }

    func testAQueryThatMatchesNothingReturnsNothing() {
        XCTAssertTrue(SymbolCatalog.matching("zzzznotasymbol").isEmpty)
    }

    func testTheDefaultToolSymbolsAreInTheCatalog() {
        // Otherwise the picker opens on a selection it cannot show.
        let names = Set(SymbolCatalog.all.map(\.name))
        XCTAssertTrue(names.contains("chevron.left.forwardslash.chevron.right"))
        XCTAssertTrue(names.contains("terminal"))
    }

    func testEverySymbolInTheCatalogResolvesOnThisSystem() {
        // A typo'd SF Symbol name renders as a blank button with no error anywhere.
        for entry in SymbolCatalog.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: entry.name, accessibilityDescription: nil),
                "\(entry.name) is not a real SF Symbol"
            )
        }
    }
}
