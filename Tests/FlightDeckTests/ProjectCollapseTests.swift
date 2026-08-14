import XCTest
@testable import FlightDeck

@MainActor
final class ProjectCollapseTests: XCTestCase {
    private func makeStore() -> (SessionStore, SessionPersistenceTests.FakePersistence) {
        let persistence = SessionPersistenceTests.FakePersistence()
        return (SessionStore(provider: nil, persistence: persistence), persistence)
    }

    func testSummaryRankOrdersWaitingAboveShellAboveBusyAboveIdle() {
        XCTAssertGreaterThan(SessionActivity.waiting.summaryRank, SessionActivity.shell.summaryRank)
        XCTAssertGreaterThan(SessionActivity.shell.summaryRank, SessionActivity.busy.summaryRank)
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
}
