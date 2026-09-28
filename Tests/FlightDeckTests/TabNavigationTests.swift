// Tests/FlightDeckTests/TabNavigationTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class TabNavigationTests: XCTestCase {
    /// Retains no real surface — these tests only move a selection around.
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    private let foo = URL(fileURLWithPath: "/work/foo", isDirectory: true)
    private let bar = URL(fileURLWithPath: "/work/bar", isDirectory: true)

    /// Two projects, two sessions each. Sidebar order: P(foo), foo[0], foo[1], P(bar),
    /// bar[2], bar[3].
    private func makeStore() -> (SessionStore, [UUID]) {
        let store = SessionStore(provider: StubProvider())
        let ids = [
            store.newSession(in: foo).id,
            store.newSession(in: foo).id,
            store.newSession(in: bar).id,
            store.newSession(in: bar).id,
        ]
        return (store, ids)
    }

    private func projectID(_ url: URL, in store: SessionStore) -> UUID {
        store.repos.first { $0.url.standardizedFileURL == url.standardizedFileURL }!.id
    }

    func testNextAdvancesWithinAProject() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[1])
    }

    func testNextStopsOnTheFollowingProjectRow() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[1]
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(bar, in: store))
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[2])
        XCTAssertNil(store.selectedProjectID)
    }

    func testNextWrapsFromTheLastSessionToTheFirstProjectRow() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[3]
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
    }

    func testPreviousFromAProjectRowGoesToTheSessionAboveIt() {
        let (store, ids) = makeStore()
        store.selectProject(projectID(bar, in: store))
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[1])
        XCTAssertNil(store.selectedProjectID)
    }

    func testPreviousWrapsFromTheFirstProjectRowToTheLastSession() {
        let (store, ids) = makeStore()
        store.selectProject(projectID(foo, in: store))
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[3])
    }

    func testCyclingSkipsTheSessionsOfACollapsedProject() {
        let (store, _) = makeStore()
        store.setCollapsed(true, forProjectAt: projectID(foo, in: store))
        store.selectProject(projectID(foo, in: store))
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(bar, in: store))
    }

    /// A session inside a collapsed project is still selected but has no rendered row — the
    /// project's own header row stands in for it, so cycling forward moves one stop past that
    /// header rather than treating the position as unknown and jumping to the first stop.
    func testCyclingNextFromASessionInACollapsedProjectHoldingItGoesToTheNextRow() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.setCollapsed(true, forProjectAt: projectID(foo, in: store))
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(bar, in: store))
    }

    /// Mirror of the above going backward: the collapsed project's header is the current
    /// position, so Previous lands on the row before it, not the last stop in the sidebar.
    func testCyclingPreviousFromASessionInACollapsedProjectHoldingItGoesToThePriorRow() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[2]
        store.setCollapsed(true, forProjectAt: projectID(bar, in: store))
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[1])
        XCTAssertNil(store.selectedProjectID)
    }

    func testAnEmptyProjectRowIsStillAStop() {
        let (store, _) = makeStore()
        let emptyURL = URL(fileURLWithPath: "/work/empty", isDirectory: true)
        // `addProject` always seeds one session; moving it straight into `bar` leaves this
        // new project standing empty — the same "a project's lifetime is explicit" state
        // `moveSession`'s own doc comment describes. Appended last, so `empty`'s project row
        // sits after `bar`'s own sessions in sidebar order.
        let seed = store.addProject(at: emptyURL)
        store.moveSession(seed.id, toProjectAt: bar)

        store.selectProject(projectID(bar, in: store))
        store.selectPreviousSession()   // bar's row → foo1
        store.selectNextSession()       // → bar's row again
        XCTAssertEqual(store.selectedProjectID, projectID(bar, in: store))

        // bar2, bar3, the moved-in session, then the empty project's own row — its `.empty`
        // placeholder is never a stop, so this must land ON the project row, not skip it.
        store.selectNextSession()
        store.selectNextSession()
        store.selectNextSession()
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(emptyURL, in: store))
    }

    /// A lone session alternates with its own project row: cycling never gets stuck showing
    /// only the terminal when the project view is one stop away too.
    func testASingleSessionAlternatesWithItsProjectRow() {
        let store = SessionStore(provider: StubProvider())
        let only = store.newSession(in: foo)
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, only.id)
        XCTAssertNil(store.selectedProjectID)
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
    }

    func testAnEmptyStoreIsANoOp() {
        let store = SessionStore(provider: StubProvider())
        store.selectNextSession()
        XCTAssertNil(store.selectedSessionID)
        store.selectPreviousSession()
        XCTAssertNil(store.selectedSessionID)
    }

    /// With project rows now in the running, "no selection" lands on the first STOP going
    /// forward — the first project's own row, not its first session.
    func testNoSelectionGoesToTheFirstProjectRowGoingForward() {
        let (store, _) = makeStore()
        store.selectedSessionID = nil
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
    }

    /// The sidebar's very last row is still a session (a project row always precedes its own
    /// sessions), so "no selection" going backward is unchanged from the session-only order.
    func testNoSelectionGoesToTheLastSessionGoingBackward() {
        let (store, ids) = makeStore()
        store.selectedSessionID = nil
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[3])
    }

    func testASelectionNamingAMissingSessionIsTreatedAsNoSelectionGoingForward() {
        let (store, _) = makeStore()
        store.selectedSessionID = UUID()
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
    }

    func testASelectionNamingAMissingSessionIsTreatedAsNoSelectionGoingBackward() {
        let (store, ids) = makeStore()
        store.selectedSessionID = UUID()
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[3])
    }

    /// `moveSession` deliberately leaves an emptied source project standing, so the first
    /// repo can hold no sessions while live tabs sit below it. Cycling must walk the live
    /// tabs and stop on every project row along the way, never landing on nothing — the same
    /// hazard `closeSession` documents.
    func testCyclesOverLiveTabsWhenTheFirstProjectIsEmpty() {
        let store = SessionStore(provider: StubProvider())
        let moved = store.newSession(in: foo)
        let stayed = store.newSession(in: bar)
        store.moveSession(moved.id, toProjectAt: bar)
        XCTAssertTrue(store.repos[0].sessions.isEmpty, "precondition: source project stands empty")

        // Sidebar order is now P(foo), P(bar), bar[stayed], bar[moved].
        store.selectedSessionID = stayed.id
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, moved.id)

        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
    }
}
