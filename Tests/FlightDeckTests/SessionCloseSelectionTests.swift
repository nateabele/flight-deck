// Tests/FlightDeckTests/SessionCloseSelectionTests.swift
import XCTest
@testable import FlightDeck

/// Closing the active tab used to jump the selection to the top of the sidebar. It should
/// instead walk back to whichever tab was active immediately before it, and only fall back to
/// the closed tab's sidebar neighbor when there is no usable history.
@MainActor
final class SessionCloseSelectionTests: XCTestCase {
    private struct SilentReporter: AgentLaunchFailureReporting {
        func report(_ error: AgentLaunchError) {}
    }

    private let project = URL(fileURLWithPath: "/w/a", isDirectory: true)

    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, _, done in done(nil) }
        store.launchFailureReporter = SilentReporter()
        return store
    }

    /// Activate A, then B, then C, so C is on screen. Closing it should not jump to the top
    /// of the sidebar (A) but back to B, the tab that was active immediately before it.
    func testClosingTheActiveTabReturnsToItsMostRecentlyActivePredecessor() {
        let store = makeStore()
        let a = store.newSession(in: project)
        let b = store.newSession(in: project)
        let c = store.newSession(in: project)
        XCTAssertEqual(store.selectedSessionID, c.id, "fixture assumption")

        store.closeSession(c.id)

        XCTAssertEqual(store.selectedSessionID, b.id)
    }

    /// Continuing to close the active tab should keep walking back through the full
    /// activation history, browser-tab style: close B next and land on A.
    func testRepeatedClosesWalkBackThroughTheFullActivationHistory() {
        let store = makeStore()
        let a = store.newSession(in: project)
        let b = store.newSession(in: project)
        let c = store.newSession(in: project)
        store.closeSession(c.id)
        XCTAssertEqual(store.selectedSessionID, b.id, "fixture assumption")

        store.closeSession(b.id)

        XCTAssertEqual(store.selectedSessionID, a.id)
    }

    /// With no usable activation history, closing the active tab falls back to the sidebar
    /// neighbor now sitting at its old position — the "next one down" — rather than the top
    /// of the list. X is inserted ahead of the seed session and Y after it (both without
    /// selecting them) so the seed is the only entry in the history, and specifically not the
    /// first row, so "next down" (Z) and "top of the list" (X) are different ids and the
    /// assertion actually distinguishes the fix from the bug.
    func testWithNoHistoryClosingANonLastActiveTabSelectsTheSurvivorNowInItsPlace() {
        let store = makeStore()
        let seed = store.newSession(in: project)
        let x = store.newSession(in: project, at: 0, selecting: false)
        let z = store.newSession(in: project, selecting: false)
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [x.id, seed.id, z.id],
                        "fixture assumption: seed sits between its two neighbors")
        XCTAssertEqual(store.selectedSessionID, seed.id, "fixture assumption")

        store.closeSession(seed.id)

        XCTAssertEqual(store.selectedSessionID, z.id)
    }

    /// The mirror of the previous case: when the active tab with no history is the LAST row,
    /// there is no "next one down", so the fallback lands on the previous neighbor instead.
    func testWithNoHistoryClosingTheLastActiveTabSelectsThePreviousNeighbor() {
        let store = makeStore()
        let seed = store.newSession(in: project)
        let x = store.newSession(in: project, at: 0, selecting: false)
        let y = store.newSession(in: project, at: 1, selecting: false)
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [x.id, y.id, seed.id],
                        "fixture assumption: seed is the last row")
        XCTAssertEqual(store.selectedSessionID, seed.id, "fixture assumption")

        store.closeSession(seed.id)

        XCTAssertEqual(store.selectedSessionID, y.id)
    }

    /// Closing a tab that is not the active one must not disturb the selection — and the
    /// closed tab's id must stop influencing history afterward, so a later active-tab close
    /// cannot resurrect it as a "predecessor".
    func testClosingANonActiveTabLeavesSelectionUnchangedAndPrunesItFromHistory() {
        let store = makeStore()
        let a = store.newSession(in: project)
        let b = store.newSession(in: project)
        let c = store.newSession(in: project)
        store.selectSession(b.id)
        XCTAssertEqual(store.selectedSessionID, b.id, "fixture assumption")

        store.closeSession(c.id)
        XCTAssertEqual(store.selectedSessionID, b.id, "closing a non-active tab must not move the selection")

        store.closeSession(b.id)

        XCTAssertEqual(store.selectedSessionID, a.id,
                        "c was already pruned by its own close, so b's predecessor is a, not c")
    }

    /// An id left over in the history from a tab that was later closed while inactive must be
    /// skipped rather than selected: activate A, B, C, close A while B/C remain untouched (A is
    /// not active), then close the active tab C and land on B, the next still-live entry.
    func testClosingTheActiveTabSkipsAPredecessorThatWasClosedWhileInactive() {
        let store = makeStore()
        let a = store.newSession(in: project)
        let b = store.newSession(in: project)
        let c = store.newSession(in: project)
        XCTAssertEqual(store.selectedSessionID, c.id, "fixture assumption")

        store.closeSession(a.id)
        XCTAssertEqual(store.selectedSessionID, c.id, "closing a wasn't active; selection is untouched")

        store.closeSession(c.id)

        XCTAssertEqual(store.selectedSessionID, b.id)
    }
}
