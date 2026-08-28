import XCTest
@testable import FlightDeck

@MainActor
final class ProjectCollapseTests: XCTestCase {
    private func makeStore() -> (SessionStore, SessionPersistenceTests.FakePersistence) {
        let persistence = SessionPersistenceTests.FakePersistence()
        return (SessionStore(provider: nil, persistence: persistence), persistence)
    }

    func testSummaryRankOrdersWaitingAboveBusyAboveIdle() {
        XCTAssertGreaterThan(SessionActivity.waiting.summaryRank, SessionActivity.busy.summaryRank)
        XCTAssertGreaterThan(SessionActivity.busy.summaryRank, SessionActivity.idle.summaryRank)
    }

    func testCollapsedStatusPicksTheHighestPriorityChild() {
        let (store, _) = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.applyRegistryForTesting([a.id: .init(activity: .busy), b.id: .init(activity: .waiting)])

        XCTAssertEqual(store.collapsedStatus(forProjectAt: project)?.activity, .waiting)
    }

    func testCollapsedStatusIgnoresIdleAndUnstatusedChildren() {
        let (store, _) = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.applyRegistryForTesting([a.id: .init(activity: .idle)])

        XCTAssertNil(store.collapsedStatus(forProjectAt: project))
    }

    func testCollapsedStatusIsNilForAProjectWithNoSessions() {
        let (store, _) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.closeSession(session.id)

        XCTAssertNil(store.collapsedStatus(forProjectAt: project))
    }

    /// Pins the tie-break spelled out in `collapsedStatus`'s doc comment rather than leaving it
    /// incidental: `max(by:)` returns the FIRST maximal element on a tie, so when two children
    /// are equally `.waiting`, the one that comes first in `repo.sessions` wins.
    func testCollapsedStatusTieBreaksTowardTheFirstEquallyRankedChild() {
        let (store, _) = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.applyRegistryForTesting([
            a.id: .init(activity: .waiting, waitingFor: "permission prompt"),
            b.id: .init(activity: .waiting, waitingFor: "input needed"),
        ])

        XCTAssertEqual(store.collapsedStatus(forProjectAt: project)?.waitingFor, "permission prompt")
    }

    func testCollapsedStatusDropsTheSubagentCount() {
        let (store, _) = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.applyRegistryForTesting([a.id: .init(activity: .busy, subagentCount: 4)])

        // The collapsed header already carries one number — the session count. A second
        // number beside it reads as a second count of the same thing.
        XCTAssertEqual(store.collapsedStatus(forProjectAt: project)?.subagentCount, 0)
    }

    func testSetCollapsedTogglesAndPersists() {
        let (store, persistence) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        let before = persistence.saveCount

        store.setCollapsed(true, forProjectAt: project)

        XCTAssertTrue(store.repos[0].isCollapsed)
        XCTAssertGreaterThan(persistence.saveCount, before)
    }

    func testCollapsedProjectContributesOnlyItsHeaderRow() {
        let (store, _) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id

        XCTAssertEqual(store.sidebarRows.count, 3)
        store.setCollapsed(true, forProjectAt: project)
        XCTAssertEqual(store.sidebarRows, [.project(project)])
    }

    func testACollapsedEmptyProjectHasNoPlaceholder() {
        let (store, _) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.closeSession(session.id)
        store.setCollapsed(true, forProjectAt: project)

        XCTAssertEqual(store.sidebarRows, [.project(project)])
    }

    // MARK: - Un-collapsing when a session lands (merge-gating fix)

    /// `newSession` is the only place a session can land in an already-collapsed project
    /// (⌘N, a context-menu "New Session", a folder drop onto a known project, or
    /// `moveSession`/registry-driven moves — all funnel through here or through
    /// `moveSession`). Without this, the sidebar shows nothing for the new row.
    func testNewSessionInACollapsedProjectExpandsItAndTheNewRowIsVisible() {
        let (store, _) = makeStore()
        let url = URL(fileURLWithPath: "/w/a", isDirectory: true)
        let first = store.newSession(in: url)
        let project = store.repos[0].id
        store.setCollapsed(true, forProjectAt: project)
        XCTAssertTrue(store.repos[0].isCollapsed)

        let created = store.newSession(in: url)

        XCTAssertFalse(store.repos[0].isCollapsed)
        XCTAssertTrue(store.sidebarRows.contains(.session(created.id, project: project)))
        _ = first
    }

    func testMoveSessionIntoACollapsedDestinationExpandsIt() {
        let (store, _) = makeStore()
        store.titleResolver = { _, _, done in done(nil) }
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))
        let destination = store.repos.first { $0.url.lastPathComponent == "b" }!.id
        store.setCollapsed(true, forProjectAt: destination)
        XCTAssertTrue(store.repos.first { $0.id == destination }!.isCollapsed)

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/w/b", isDirectory: true))

        XCTAssertFalse(store.repos.first { $0.id == destination }!.isCollapsed)
        XCTAssertTrue(store.sidebarRows.contains(.session(a.id, project: destination)))
    }

    /// The regression guard: `restore()` calls `insertSession` directly, not `newSession`,
    /// precisely so a persisted collapsed project stays collapsed across a relaunch. If this
    /// ever regresses — e.g. by moving the un-collapse from `newSession` into `insertSession`
    /// — every restored collapsed project would spring open on launch.
    func testRestoreDoesNotExpandAProjectRecordedAsCollapsed() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "a", workingDirectory: "/w/a")],
            projects: [.init(path: "/w/a", isCollapsed: true)],
            sessionCounter: 1
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: { _ in true }))

        XCTAssertTrue(store.repos[0].isCollapsed)
        XCTAssertEqual(store.sidebarRows, [.project(store.repos[0].id)])
    }
}
