import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `ProjectView`'s flywheel-disabled empty state offscreen to PNGs for design review —
/// skipped by default. Set `FD_PROJECT_RENDER_DIR` to an output directory to run it. Same
/// parked-`NSHostingView` + `layer.render(in:)` technique as `IntakeDetailViewRenderTests`
/// (screencapture is denied here, and `cacheDisplay` drops layer-backed SwiftUI content); this
/// one renders once per appearance since the splash art is a glowing blue on a transparent
/// background, which reads very differently on a light window background.
@MainActor
final class ProjectViewRenderTests: XCTestCase {
    func testRenderDisabledEmptyState() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_PROJECT_RENDER_DIR"] else {
            throw XCTSkip("set FD_PROJECT_RENDER_DIR to render the disabled-empty-state PNGs")
        }
        let out = URL(fileURLWithPath: dir)

        let store = SessionStore(provider: nil, persistence: SessionPersistenceTests.FakePersistence())
        store.newSession(in: URL(fileURLWithPath: "/w/splash-demo", isDirectory: true))
        let repo = try XCTUnwrap(store.repos.first)

        try render(ProjectView(store: store, repo: repo), appearance: .darkAqua, to: out.appendingPathComponent("splash-empty-state.png"))
        try render(ProjectView(store: store, repo: repo), appearance: .aqua, to: out.appendingPathComponent("splash-empty-state-light.png"))
    }

    /// Parked offscreen `NSHostingView` + `layer.render(in:)` — see
    /// `IntakeDetailViewRenderTests.render` for why.
    private func render(_ view: some View, appearance: NSAppearance.Name, to url: URL) throws {
        let size = NSSize(width: 900, height: 600)
        let root = view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            // The test runner is never the active app, and activating it would steal focus
            // from whoever is typing; this draws controls as the focused window would.
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
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
