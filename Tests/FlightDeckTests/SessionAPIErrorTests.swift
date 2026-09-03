import XCTest
@testable import FleetKit

final class SessionAPIErrorTests: XCTestCase {
    func testLabelCarriesStatusAndKind() {
        let e = SessionAPIError(status: 529, kind: "overloaded", isTransient: true)
        XCTAssertEqual(e.label, "Stopped — API error 529 (overloaded)")
    }

    /// Every component is optional because the CLI sets them independently — a client-side
    /// failure raises `isApiErrorMessage` with no HTTP status at all. The badge has to survive
    /// that rather than render "API error nil".
    func testLabelDegradesWhenPartsAreMissing() {
        XCTAssertEqual(SessionAPIError(status: 529).label, "Stopped — API error 529")
        XCTAssertEqual(SessionAPIError(kind: "overloaded").label,
                       "Stopped — API error (overloaded)")
        XCTAssertEqual(SessionAPIError().label, "Stopped — API error")
    }

    /// An empty string is not a kind. It reaches us from a record whose `error` key is
    /// present but blank, and "()" in the sidebar is worse than saying nothing.
    func testEmptyKindIsTreatedAsAbsent() {
        XCTAssertEqual(SessionAPIError(status: 500, kind: "").label, "Stopped — API error 500")
    }

    func testRoundTripsThroughCodable() throws {
        let e = SessionAPIError(status: 429, kind: "rate_limit", isTransient: true)
        let data = try JSONEncoder().encode(e)
        XCTAssertEqual(try JSONDecoder().decode(SessionAPIError.self, from: data), e)
    }
}
