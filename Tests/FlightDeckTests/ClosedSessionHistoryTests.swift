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

    /// The menu reads most-recent-first, the opposite of the array's push order.
    func testSessionEntriesComeBackMostRecentFirst() {
        var history = ClosedSessionHistory()
        history.record(.session(closed("one")))
        history.record(.session(closed("two")))

        XCTAssertEqual(history.sessionEntries.map(\.session.title), ["two", "one"])
    }

    /// A project's children are not separately offerable: taking one would leave the project
    /// entry half-consumed, and reopening the project afterwards would reinsert a tab that is
    /// already open.
    func testSessionEntriesSkipsSessionsNestedInAClosedProject() {
        var history = ClosedSessionHistory()
        history.record(.session(closed("loose")))
        history.record(.project(ClosedSessionHistory.ClosedProject(
            path: "/w/a", isCollapsed: false, indexInSidebar: 0,
            sessions: [closed("nested", at: 0)]
        )))

        XCTAssertEqual(history.sessionEntries.map(\.session.title), ["loose"])
    }

    func testTakingASessionByIDRemovesOnlyThatEntry() {
        var history = ClosedSessionHistory()
        let first = closed("one")
        let middle = closed("two")
        let last = closed("three")
        history.record(.session(first))
        history.record(.session(middle))
        history.record(.session(last))

        XCTAssertEqual(history.takeSession(id: middle.session.id), middle)
        XCTAssertEqual(history.sessionEntries.map(\.session.title), ["three", "one"])
        // ⌘⇧T goes on popping whatever is now on top, which is the entry above the hole.
        XCTAssertEqual(history.takeLast(), .session(last))
    }

    func testTakingAnUnknownOrNestedSessionYieldsNothing() {
        var history = ClosedSessionHistory()
        let nested = closed("nested", at: 0)
        history.record(.project(ClosedSessionHistory.ClosedProject(
            path: "/w/a", isCollapsed: false, indexInSidebar: 0, sessions: [nested]
        )))

        XCTAssertNil(history.takeSession(id: nested.session.id))
        XCTAssertNil(history.takeSession(id: UUID()))
        XCTAssertFalse(history.isEmpty, "a failed take must not consume the project entry")
    }
}
