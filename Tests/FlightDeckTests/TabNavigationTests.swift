// Tests/FlightDeckTests/TabNavigationTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class TabNavigationTests: XCTestCase {
    /// Retains no real surface — these tests only move a selection around.
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private let foo = URL(fileURLWithPath: "/work/foo", isDirectory: true)
    private let bar = URL(fileURLWithPath: "/work/bar", isDirectory: true)

    /// Two projects, two sessions each. Sidebar order: foo[0], foo[1], bar[2], bar[3].
    private func makeStore() -> (SessionStore, [UUID]) {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let ids = [
            store.newSession(in: foo).id,
            store.newSession(in: foo).id,
            store.newSession(in: bar).id,
            store.newSession(in: bar).id,
        ]
        return (store, ids)
    }

    func testNextAdvancesWithinAProject() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[1])
    }

    func testNextCrossesIntoTheFollowingProject() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[1]
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[2])
    }

    func testNextWrapsFromTheLastSessionToTheFirst() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[3]
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testPreviousMovesBackwardsAcrossProjects() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[2]
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[1])
    }

    func testPreviousWrapsFromTheFirstSessionToTheLast() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[3])
    }

    func testASingleSessionStaysSelected() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let only = store.newSession(in: foo)
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, only.id)
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, only.id)
    }

    func testAnEmptyStoreIsANoOp() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        store.selectNextSession()
        XCTAssertNil(store.selectedSessionID)
        store.selectPreviousSession()
        XCTAssertNil(store.selectedSessionID)
    }

    func testNoSelectionGoesToTheFirstSessionGoingForward() {
        let (store, ids) = makeStore()
        store.selectedSessionID = nil
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testNoSelectionGoesToTheLastSessionGoingBackward() {
        let (store, ids) = makeStore()
        store.selectedSessionID = nil
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[3])
    }

    func testASelectionNamingAMissingSessionIsTreatedAsNoSelectionGoingForward() {
        let (store, ids) = makeStore()
        store.selectedSessionID = UUID()
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testASelectionNamingAMissingSessionIsTreatedAsNoSelectionGoingBackward() {
        let (store, ids) = makeStore()
        store.selectedSessionID = UUID()
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[3])
    }

    /// `moveSession` deliberately leaves an emptied source project standing, so the first
    /// repo can hold no sessions while live tabs sit below it. Cycling must walk the live
    /// tabs and never land on nothing — the same hazard `closeSession` documents.
    func testCyclesOverLiveTabsWhenTheFirstProjectIsEmpty() {
        let store = SessionStore(provider: StubProvider())
        store.display = DrawableDisplay()
        let moved = store.newSession(in: foo)
        let stayed = store.newSession(in: bar)
        store.moveSession(moved.id, toProjectAt: bar)
        XCTAssertTrue(store.repos[0].sessions.isEmpty, "precondition: source project stands empty")

        // Sidebar order is now bar[stayed], bar[moved].
        store.selectedSessionID = stayed.id
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, moved.id)

        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, stayed.id)
    }
}
