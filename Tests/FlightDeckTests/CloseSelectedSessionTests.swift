// Tests/FlightDeckTests/CloseSelectedSessionTests.swift
import XCTest
@testable import FlightDeck

/// ⌘W means "close the selected session" from anywhere in the window.
///
/// The responder-chain route (`TerminalHostView.performClose`) only fires while focus is
/// inside the terminal: `NSWindow` implements `performClose:` itself, so with the sidebar
/// focused the chain reaches the window first and closes it — which, in a single-window app
/// that quits with its window, means ⌘W quit the app. The menu item binds to this method
/// instead, so which view has focus stops mattering.
@MainActor
final class CloseSelectedSessionTests: XCTestCase {
    private let projectA = URL(fileURLWithPath: "/w/a", isDirectory: true)

    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, _, done in done(nil) }
        return store
    }

    func testClosingTheSelectionRemovesTheSelectedSession() {
        let store = makeStore()
        let first = store.newSession(in: projectA)
        let second = store.newSession(in: projectA)
        XCTAssertEqual(store.selectedSessionID, second.id)

        XCTAssertTrue(store.closeSelectedSession())

        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [first.id])
    }

    /// The return value is what lets ⌘W fall through to closing the window when there is
    /// nothing to close, rather than becoming a dead key in the empty state.
    func testClosingWithNoSelectionReportsThatItDidNothing() {
        let store = makeStore()
        XCTAssertNil(store.selectedSessionID)

        XCTAssertFalse(store.closeSelectedSession())
    }

    /// It must be the same teardown as every other close, not a second copy of it — and it
    /// has to reach the reopen stack, or ⌘W would be the one close ⌘⇧T could not undo.
    func testASessionClosedThisWayCanBeReopened() {
        let store = makeStore()
        let session = store.newSession(in: projectA)

        XCTAssertTrue(store.closeSelectedSession())
        store.reopenLastClosed(directoryExists: { _ in true })

        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [session.id])
    }
}
