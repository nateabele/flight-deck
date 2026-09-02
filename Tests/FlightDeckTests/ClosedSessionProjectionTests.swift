// Tests/FlightDeckTests/ClosedSessionProjectionTests.swift
import FleetKit
import XCTest
@testable import FlightDeck

/// The reopen stack described for a phone. Pure, and separate from `FleetService`, so the
/// privacy property can be asserted without a socket — the same split
/// `NewSessionOptionsProjection` makes and for the same reason.
final class ClosedSessionProjectionTests: XCTestCase {
    private func closed(_ title: String, in project: String) -> ClosedSessionHistory.ClosedSession {
        ClosedSessionHistory.ClosedSession(
            session: Session(title: title, workingDirectory: project),
            projectPath: project, indexInProject: 0
        )
    }

    func testARowCarriesTheTabIDTitleAgentAndProjectPath() {
        let entry = closed("fix the pager", in: "/w/a")
        let rows = ClosedSessionProjection.rows(for: [entry])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, entry.session.id)
        XCTAssertEqual(rows[0].title, "fix the pager")
        XCTAssertEqual(rows[0].agent, entry.session.agent.rawValue)
        XCTAssertEqual(rows[0].projectPath, "/w/a")
    }

    /// Order is the stack's, not re-sorted here: `sessionEntries` already hands them over
    /// most-recent-first and the phone renders them in arrival order.
    func testOrderIsPreserved() {
        let rows = ClosedSessionProjection.rows(for: [
            closed("newest", in: "/w/a"), closed("older", in: "/w/b")
        ])
        XCTAssertEqual(rows.map(\.title), ["newest", "older"])
    }
}
