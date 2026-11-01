import AppKit
import IntakeKit
import WebKit
import XCTest
@testable import FlightDeck

/// The size switch on a live block (final review B-I2): the fitted page lays the diagram out at
/// the chosen size's width, so "narrow" draws narrower than "wide" in the same pane.
@MainActor
final class VisualLiveSizeTests: XCTestCase {
    private var fixture: VisualFixture!

    override func setUpWithError() throws { fixture = try VisualFixture() }
    override func tearDown() { fixture.remove() }

    private func drawnWidth(size: String) async throws -> CGFloat {
        let pane = NSRect(x: 0, y: 0, width: 1000, height: 320)
        let web = VisualWebView(store: fixture.store, frame: pane, fit: true)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: pane.width, height: pane.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web.view
        window.orderFrontRegardless()
        defer { web.stop(); window.orderOut(nil); window.contentView = nil }
        let status: VisualRenderStatus = try await withCheckedThrowingContinuation { continuation in
            var done = false
            web.onStatus = { status in
                guard !done, status != .loading else { return }
                done = true
                continuation.resume(returning: status)
            }
            web.show(VisualID(rawValue: "flow")!, r: 1, state: "default", size: size)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                guard !done else { return }
                done = true
                continuation.resume(throwing: CancellationError())
            }
        }
        guard case .rendered(let width, _) = status else { XCTFail("\(status)"); return 0 }
        return width
    }

    func testNarrowDrawsNarrowerThanWideInTheSamePane() async throws {
        try fixture.revision("flow", r: 1, source: """
        flowchart LR
            a[A rather long first node] --> b[A second long node] --> c[A third long node] --> d[And a fourth one]
        """, kind: "flowchart", sizes: ["wide", "narrow"])
        let wide = try await drawnWidth(size: "wide")
        let narrow = try await drawnWidth(size: "narrow")
        XCTAssertGreaterThan(wide, 0)
        XCTAssertLessThanOrEqual(narrow, CGFloat(VisualSize.width("narrow")), "narrow lays out at its own width")
        XCTAssertLessThan(narrow, wide - 50, "the size switch changes the drawing (wide \(wide), narrow \(narrow))")
    }
}
