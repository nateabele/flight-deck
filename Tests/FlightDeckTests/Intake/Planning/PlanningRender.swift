import AppKit
import SwiftUI
import XCTest

/// Offscreen PNGs of the planning views for design review. Parked offscreen `NSHostingView` +
/// `layer.render(in:)` — screencapture is denied here, and `cacheDisplay` drops layer-backed
/// SwiftUI content.
///
/// Also composites the window's child windows: the split-flap card lives in its own child panel
/// (`FloatingCard`, so the tape's ScrollView can't clip it), and a render of the host view alone
/// would silently leave every card out.
@MainActor
enum PlanningRender {
    static func write(_ view: some View, size: NSSize, to url: URL) throws {
        let root = view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        // Long enough for the first-appearance flaps (≤ 0.32 s + stagger) to land.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
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
        for child in window.childWindows ?? [] where child.isVisible {
            guard let layer = child.contentView?.layer else { continue }
            // Screen frames are y-up; this context is y-down from the window's top edge.
            context.saveGState()
            context.translateBy(x: child.frame.minX - window.frame.minX, y: window.frame.maxY - child.frame.maxY)
            layer.render(in: context)
            context.restoreGState()
        }
        window.childWindows?.forEach { window.removeChildWindow($0); $0.orderOut(nil) }
        window.orderOut(nil)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
