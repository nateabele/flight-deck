// Tests/FlightDeckTests/SurfaceLifecycleTests.swift
import XCTest
import AppKit
@testable import FlightDeck

@MainActor
final class SurfaceLifecycleTests: XCTestCase {
    /// Let the detached main-actor ghostty_surface_free task run to completion.
    private func drainMainQueue() {
        let exp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    func testCreateCloseCyclesKeepAppValid() throws {
        // Use the one process-wide app from the launched host app so we exercise
        // the real singleton and never create a second ghostty_app_t.
        guard let ghostty = (NSApplication.shared.delegate as? AppDelegate)?.ghostty else {
            throw XCTSkip("Host app GhosttyApp singleton unavailable")
        }
        XCTAssertTrue(ghostty.hasValidApp)

        let store = SessionStore(provider: ghostty)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        for _ in 0..<3 {
            let session = store.newSession(in: dir)
            XCTAssertNotNil(store.surface(for: session.id))
            store.closeSession(session.id)   // drops the surface → deferred free
            drainMainQueue()                 // let the free actually run
            XCTAssertTrue(ghostty.hasValidApp) // app survived freeing a surface
        }
        XCTAssertTrue(ghostty.hasValidApp)
    }
}
