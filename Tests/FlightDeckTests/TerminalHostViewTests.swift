// Tests/FlightDeckTests/TerminalHostViewTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class TerminalHostViewTests: XCTestCase {
    func testSetFrameSizeReportsTheNewSize() {
        let view = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var reported: [CGSize] = []
        view.onResize = { reported.append($0) }

        view.setFrameSize(NSSize(width: 640, height: 480))

        XCTAssertEqual(reported, [CGSize(width: 640, height: 480)])
    }

    /// Autoresizing and SwiftUI both drive the view through the `frame` setter rather than
    /// calling `setFrameSize` directly, so that path is the one that actually matters.
    func testAssigningFrameReportsTheNewSize() {
        let view = TerminalHostView(frame: .zero)
        var reported: [CGSize] = []
        view.onResize = { reported.append($0) }

        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        XCTAssertEqual(reported, [CGSize(width: 800, height: 600)])
    }

    func testNoCallbackIsHarmless() {
        let view = TerminalHostView(frame: .zero)
        view.setFrameSize(NSSize(width: 10, height: 10))
        XCTAssertEqual(view.frame.size, NSSize(width: 10, height: 10))
    }
}
