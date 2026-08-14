import XCTest
@testable import FlightDeck

@MainActor
final class SidebarReorderTests: XCTestCase {
    private func repo(_ path: String, sessions: Int) -> Repo {
        Repo(
            url: URL(fileURLWithPath: path, isDirectory: true),
            sessions: (0..<sessions).map {
                Session(title: "\(path)-s\($0)", workingDirectory: path)
            }
        )
    }

    /// [P_a, a0, a1, P_b, b0]
    private func fixture() -> [Repo] {
        [repo("/w/a", sessions: 2), repo("/w/b", sessions: 1)]
    }

    private func move(_ repos: [Repo], from: Int, to: Int) -> [Repo]? {
        SidebarReorder.apply(
            to: repos,
            rows: SidebarRow.rows(for: repos),
            from: IndexSet(integer: from),
            to: to
        )
    }

    func testDraggingAProjectPastAnotherMovesItsWholeBlock() {
        let repos = fixture()

        // Row 0 is project a's header; row 5 is one past the end (append).
        let moved = move(repos, from: 0, to: 5)

        XCTAssertEqual(moved?.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(moved?.last?.sessions.count, 2, "the project's sessions travel with it")
    }

    func testDroppingAProjectImmediatelyBeforeItsSuccessorIsANoOp() {
        let repos = fixture()

        // Row 3 is project b's header: dropping a just before b leaves a first.
        let moved = move(repos, from: 0, to: 3)

        XCTAssertEqual(moved?.map(\.url.lastPathComponent), ["a", "b"])
    }

    func testASessionReordersWithinItsOwnProject() {
        let repos = fixture()
        let second = repos[0].sessions[1].id

        // Row 2 is a1; row 1 is the first session slot of project a.
        let moved = move(repos, from: 2, to: 1)

        XCTAssertEqual(moved?[0].sessions.map(\.id).first, second)
        XCTAssertEqual(moved?[0].sessions.count, 2)
    }

    func testASessionCannotBeDraggedIntoAnotherProject() {
        let repos = fixture()

        // Row 1 is a0; row 4 sits inside project b's session block.
        XCTAssertNil(move(repos, from: 1, to: 4))
    }

    func testASessionMayLandAtTheEndOfItsOwnProject() {
        let repos = fixture()
        let first = repos[0].sessions[0].id

        // Row 3 is project b's header, which for a *session* of project a means "after a's
        // last session" — inserting before the next project's header is the end of this one.
        // Without this position being legal, the first session could never be dragged last.
        let moved = move(repos, from: 1, to: 3)

        XCTAssertEqual(moved?[0].sessions.map(\.id).last, first)
        XCTAssertEqual(moved?[0].sessions.count, 2)
        XCTAssertEqual(moved?[1].sessions.count, 1, "project b is untouched")
    }

    func testASessionMayLandAtTheEndOfTheLastProject() {
        let repos = fixture()
        let onlyChild = repos[1].sessions[0].id

        // rows.count is the append position, and for b's only session it is legal.
        let moved = move(repos, from: 4, to: 5)

        XCTAssertEqual(moved?[1].sessions.map(\.id), [onlyChild])
    }

    func testACollapsedProjectMovesAsASingleRow() {
        var repos = fixture()
        repos[0].isCollapsed = true

        // Rows are now [P_a, P_b, b0]; row 0 to row 3 appends a after b.
        let moved = move(repos, from: 0, to: 3)

        XCTAssertEqual(moved?.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(moved?.last?.sessions.count, 2, "collapsing hides sessions, never drops them")
    }

    func testAPlaceholderRowCannotBeDragged() {
        let repos = [repo("/w/a", sessions: 0), repo("/w/b", sessions: 1)]

        // Rows are [P_a, empty_a, P_b, b0]; row 1 is the placeholder.
        XCTAssertNil(move(repos, from: 1, to: 3))
    }

    func testAnEmptyProjectStillReorders() {
        let repos = [repo("/w/a", sessions: 0), repo("/w/b", sessions: 1)]

        let moved = move(repos, from: 0, to: 4)

        XCTAssertEqual(moved?.map(\.url.lastPathComponent), ["b", "a"])
    }

    func testAMultiRowSelectionIsRejected() {
        let repos = fixture()

        // The sidebar drags one row at a time; anything else is not a move we model.
        XCTAssertNil(
            SidebarReorder.apply(
                to: repos,
                rows: SidebarRow.rows(for: repos),
                from: IndexSet([0, 1]),
                to: 5
            )
        )
    }

    func testAnOutOfRangeIndexIsRejectedRatherThanTrapping() {
        let repos = fixture()

        XCTAssertNil(move(repos, from: 99, to: 0))
        XCTAssertNil(move(repos, from: 0, to: 99))
    }
}
