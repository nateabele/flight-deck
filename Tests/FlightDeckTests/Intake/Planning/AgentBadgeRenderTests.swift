import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `AgentBadge` and `AgentStack` offscreen to PNGs for design review — skipped by
/// default. Set `FD_AGENT_ICONS_RENDER_DIR` to an output directory to run it. Not an assertion
/// test: whether a mark is legible on a disc can only be judged by looking. Same technique as
/// `RoundConfigEditorRenderTests`.
final class AgentBadgeRenderTests: XCTestCase {
    @MainActor
    func testRenderBadgesAndStacks() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_AGENT_ICONS_RENDER_DIR"] else {
            throw XCTSkip("set FD_AGENT_ICONS_RENDER_DIR to render the agent-icon PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        let entries = AgentID.allCases.map { agent in
            RoundAgent(role: "reviewer", choice: ModelChoice(agent: agent, model: "m", effort: "high"))
        }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for size in [14.0, 16.0, 18.0] {
                // The stack shows three of the five, so render the tail too (Gemini, OpenCode).
                for (tag, shown) in [("", entries), ("-tail", Array(entries.reversed()))] {
                    try render(AgentStack(entries: shown, size: size), size: NSSize(width: 160, height: 40),
                               to: out.appendingPathComponent("stack-\(Int(size))\(tag)-\(name).png"), appearance: appearance)
                }
            }
            try render(HStack(spacing: 12) { ForEach(AgentID.allCases, id: \.self) { AgentBadge(agent: $0, size: 32) } },
                       size: NSSize(width: 240, height: 64),
                       to: out.appendingPathComponent("badges-32-\(name).png"), appearance: appearance)
        }
    }

    @MainActor
    private func render(_ view: some View, size: NSSize, to url: URL, appearance: NSAppearance.Name) throws {
        let root = view.padding(12).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 4
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(host.layer).render(in: context)
        window.orderOut(nil)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
