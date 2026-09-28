import AppKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `SplitFlapText` offscreen to a PNG for design review — skipped by default. Set
/// `FD_INTAKE_RENDER_DIR` to an output directory to run it; it writes `pui-splitflap.png`. A
/// picture rather than an assertion, like `IntakeDetailViewRenderTests`: the fit and the card
/// can be looked at without launching the app (AGENTS.md rule 2).
@MainActor
final class SplitFlapTextRenderTests: XCTestCase {
    func testRenderFullNameAndCodeWithCard() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_INTAKE_RENDER_DIR"] else {
            throw XCTSkip("set FD_INTAKE_RENDER_DIR to render the split-flap PNG")
        }
        let policy = FlapPolicy()
        let nsFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        let font = Font(nsFont)
        let view = VStack(alignment: .leading, spacing: 14) {
            Text("NOW — wide slot, full name fits").font(.caption).foregroundStyle(.secondary)
            SplitFlapText(full: "Synthesis", code: "SYN", surface: "board.now", policy: policy, font: font, nsFont: nsFont)
                .frame(width: 200)
            Text("Tape slot — too narrow, code with its card open").font(.caption).foregroundStyle(.secondary)
            SplitFlapText(full: "Refine 2", code: "RF2", surface: "tape.refine-2", policy: policy, font: font, nsFont: nsFont,
                          detail: "landed 3:02", showsCardInitially: true)
                .frame(width: 48)
            Spacer()
        }
        .padding(20)
        try render(view, size: NSSize(width: 360, height: 220),
                   to: URL(fileURLWithPath: dir).appendingPathComponent("pui-splitflap.png"))
    }

    /// Parked offscreen `NSHostingView` + `layer.render(in:)` — screencapture is denied here,
    /// and `cacheDisplay` drops layer-backed SwiftUI content.
    private func render(_ view: some View, size: NSSize, to url: URL) throws {
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
        window.orderOut(nil)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
