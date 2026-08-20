// Tests/FlightDeckTests/ClosedSessionHistoryTests.swift
import XCTest
@testable import FlightDeck

/// The reopen stack on its own, with no store behind it. `SessionStore` decides *what* to
/// record and how to rebuild it; this decides only the order things come back in and how
/// much of it is kept.
final class ClosedSessionHistoryTests: XCTestCase {
    private func closed(
        _ title: String, at index: Int = 0, in project: String = "/w/a"
    ) -> ClosedSessionHistory.ClosedSession {
        ClosedSessionHistory.ClosedSession(
            session: Session(title: title, workingDirectory: project),
            projectPath: project,
            indexInProject: index
        )
    }

    func testTheMostRecentlyClosedSessionComesBackFirst() {
        var history = ClosedSessionHistory()
        let first = closed("one")
        let second = closed("two")

        history.record(.session(first))
        history.record(.session(second))

        XCTAssertEqual(history.takeLast(), .session(second))
        XCTAssertEqual(history.takeLast(), .session(first))
    }

    func testTakingFromAnEmptyHistoryYieldsNothing() {
        var history = ClosedSessionHistory()
        XCTAssertTrue(history.isEmpty)
        XCTAssertNil(history.takeLast())
    }

    /// A closed project is one entry, not one per session, so a single reopen brings the
    /// whole thing back — the same way a browser reopens a closed window.
    func testAClosedProjectIsASingleEntryHoldingAllItsSessions() {
        var history = ClosedSessionHistory()
        let project = ClosedSessionHistory.ClosedProject(
            path: "/w/a", isCollapsed: true, indexInSidebar: 2,
            sessions: [closed("one", at: 0), closed("two", at: 1)]
        )

        history.record(.project(project))

        XCTAssertEqual(history.takeLast(), .project(project))
        XCTAssertTrue(history.isEmpty)
    }

    /// The stack is unbounded input — every close pushes — so it has to forget from the far
    /// end rather than grow for the life of the run.
    func testTheOldestEntryIsDroppedOnceTheCapIsReached() {
        var history = ClosedSessionHistory()
        let oldest = closed("oldest")
        history.record(.session(oldest))
        for i in 0..<ClosedSessionHistory.depth {
            history.record(.session(closed("filler \(i)")))
        }

        var drained: [ClosedSessionHistory.Entry] = []
        while let entry = history.takeLast() { drained.append(entry) }

        XCTAssertEqual(drained.count, ClosedSessionHistory.depth)
        XCTAssertFalse(drained.contains(.session(oldest)), "the oldest close is the one forgotten")
    }
}
