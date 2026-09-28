import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `RoundConfigEditor` offscreen to a PNG for design review — skipped by default. Set
/// `FD_ROUNDS_RENDER_DIR` to an output directory to run it. Not an assertion test: layout
/// can't be checked headlessly in any useful way, but a picture of it can be looked at without
/// launching the app (AGENTS.md rule 2). The same technique as `PlanningRender`.
final class RoundConfigEditorRenderTests: XCTestCase {
    @MainActor
    func testRenderFullPlanExpanded() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_ROUNDS_RENDER_DIR"] else {
            throw XCTSkip("set FD_ROUNDS_RENDER_DIR to render the round-config-editor PNGs")
        }
        var full = try XCTUnwrap(PresetExpansion.config(for: .fullPlan, available: .defaults))
        full.customized = true
        try render(
            RoundConfigEditor(preset: .fullPlan, config: .constant(full), available: .defaults),
            size: NSSize(width: 620, height: 520),
            to: URL(fileURLWithPath: dir).appendingPathComponent("rounds-editor.png")
        )

        // Sketch: one drafter, no synthesizer, no polisher — the shortest the panel gets, and
        // the one whose polish controls are disabled.
        let sketch = try XCTUnwrap(PresetExpansion.config(for: .sketch, available: .defaults))
        try render(
            RoundConfigEditor(preset: .sketch, config: .constant(sketch), available: .defaults),
            size: NSSize(width: 620, height: 340),
            to: URL(fileURLWithPath: dir).appendingPathComponent("rounds-editor-sketch.png")
        )
    }

    /// Parked offscreen `NSHostingView` + `layer.render(in:)` — screencapture is denied here,
    /// and `cacheDisplay` drops layer-backed SwiftUI content.
    @MainActor
    private func render(_ view: some View, size: NSSize, to url: URL) throws {
        let root = view.padding(16).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        // Bitmap contexts are bottom-left origin and the hosting view is flipped.
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(host.layer).render(in: context)
        window.orderOut(nil)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
