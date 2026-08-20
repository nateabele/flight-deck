import XCTest
@testable import FlightDeck

@MainActor
final class SidebarRowTests: XCTestCase {
    private func repo(_ path: String, sessions: Int) -> Repo {
        Repo(
            url: URL(fileURLWithPath: path, isDirectory: true),
            sessions: (0..<sessions).map {
                Session(title: "s\($0)", workingDirectory: path)
            }
        )
    }

    func testExpandedProjectYieldsHeaderThenItsSessions() {
        let a = repo("/w/a", sessions: 2)

        let rows = SidebarRow.rows(for: [a])

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], .project(a.id))
        XCTAssertEqual(rows[1], .session(a.sessions[0].id, project: a.id))
        XCTAssertEqual(rows[2], .session(a.sessions[1].id, project: a.id))
    }

    func testEmptyProjectYieldsAPlaceholderRow() {
        let a = repo("/w/a", sessions: 0)

        let rows = SidebarRow.rows(for: [a])

        // Without the placeholder, an expanded empty project renders identically to a
        // collapsed one — the whole point of the row is to tell those two apart.
        XCTAssertEqual(rows, [.project(a.id), .empty(a.id)])
    }

    func testProjectsAppearInArrayOrder() {
        let a = repo("/w/a", sessions: 1)
        let b = repo("/w/b", sessions: 1)

        let rows = SidebarRow.rows(for: [b, a])

        XCTAssertEqual(rows.first, .project(b.id))
        XCTAssertEqual(rows.last, .session(a.sessions[0].id, project: a.id))
    }

    func testProjectIDIsReadableFromEveryCase() {
        let a = repo("/w/a", sessions: 1)

        XCTAssertEqual(SidebarRow.project(a.id).projectID, a.id)
        XCTAssertEqual(SidebarRow.session(a.sessions[0].id, project: a.id).projectID, a.id)
        XCTAssertEqual(SidebarRow.empty(a.id).projectID, a.id)
    }

    func testIDsAreUniqueAcrossCasesSharingAUUID() {
        // A project and its placeholder share a UUID. If `id` were just that UUID,
        // SwiftUI's ForEach would see duplicate identities and drop a row.
        let a = repo("/w/a", sessions: 0)

        XCTAssertNotEqual(SidebarRow.project(a.id).id, SidebarRow.empty(a.id).id)
    }

    // MARK: - accountMismatched

    func testMatchingAccountsAreNotAMismatch() {
        let id = UUID()
        XCTAssertFalse(SidebarRow.accountMismatched(session: id, project: id))
    }

    func testNoAccountEitherSideIsNotAMismatch() {
        XCTAssertFalse(SidebarRow.accountMismatched(session: nil, project: nil))
    }

    func testDifferingAccountsAreAMismatch() {
        XCTAssertTrue(SidebarRow.accountMismatched(session: UUID(), project: UUID()))
    }

    /// A session pinned to a real account inside a project that resolves to none at all — the
    /// project's own settings changed out from under it — is still a mismatch worth flagging.
    func testAnAccountAgainstNoAccountIsAMismatch() {
        XCTAssertTrue(SidebarRow.accountMismatched(session: UUID(), project: nil))
    }
}
