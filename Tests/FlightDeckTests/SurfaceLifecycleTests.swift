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

    /// `ghostty_surface_set_occlusion` takes VISIBLE (true = render), not occluded — the
    /// inverse of what `NSWindow.occlusionState` itself reports. Locks the polarity so a
    /// future edit that inverts it fails here rather than silently freezing the terminal
    /// whenever the window is on screen.
    func testOcclusionVisibleReflectsWindowVisibility() {
        XCTAssertTrue(occlusionVisible([.visible]))
        XCTAssertFalse(occlusionVisible([]))
    }

    /// A surface in no window is not on screen, whatever the window it last sat in reports.
    /// Tab switching detaches the outgoing surface (`TerminalPane`), and a surface restored at
    /// launch is created before any window exists — both must read as hidden, or libghostty
    /// keeps a display link redrawing them at refresh rate. Measured 2026-10-05: 78 hidden
    /// surfaces doing exactly that cost 63.6% of a core.
    func testASurfaceInNoWindowIsNotVisible() {
        XCTAssertFalse(surfaceVisible(in: nil))
    }
}
