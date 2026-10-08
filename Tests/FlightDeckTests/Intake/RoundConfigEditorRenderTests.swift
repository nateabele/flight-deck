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

        // Cross-check on (Feature plan's default with both agents present): the Cross-check
        // picker plus the second reviewer's row sit right under Reviewer.
        let crossCheck = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        try render(
            RoundConfigEditor(preset: .featurePlan, config: .constant(crossCheck), available: .defaults),
            size: NSSize(width: 620, height: 560),
            to: URL(fileURLWithPath: dir).appendingPathComponent("rounds-editor-crosscheck.png")
        )

        // Same family: the cross-check agent picked the reviewer's own harness, so the caption
        // has to explain why the round won't actually cross-check rather than leaving it silent.
        var sameFamily = crossCheck
        sameFamily.crossReviewer = crossCheck.reviewer
        try render(
            RoundConfigEditor(preset: .featurePlan, config: .constant(sameFamily), available: .defaults),
            size: NSSize(width: 620, height: 560),
            to: URL(fileURLWithPath: dir).appendingPathComponent("rounds-editor-crosscheck-samefamily.png")
        )

        // Four families, as the live four-way round seats them: claude + codex drafting, Grok
        // reviewing, Gemini cross-checking. Gemini has no effort row of claude's five values and
        // both newcomers' data-use notes show. Built from what the gate offers, so a harness not
        // yet headless-ready simply renders absent rather than failing the render.
        var four = AvailableModels(choices: [
            .claude: AvailableModels.defaults.claude!, .codex: AvailableModels.defaults.codex!,
            .grok: ModelChoice(agent: .grok, model: "grok-4.7", effort: "high"),
            .gemini: ModelChoice(agent: .gemini, model: "gemini-3.1-pro-high", effort: "high"),
        ])
        four.models[.grok] = ["grok-4.7", "grok-4.6"]
        four.models[.gemini] = ["gemini-3.1-pro-high", "gemini-3.1-pro-low"]
        var fourFamily = crossCheck
        fourFamily.drafters = [Slot(AvailableModels.defaults.claude!), Slot(AvailableModels.defaults.codex!)]
        if let grok = four.choice(for: .grok) { fourFamily.reviewer = Slot(grok) }
        if let gemini = four.choice(for: .gemini) { fourFamily.crossReviewer = Slot(gemini) }
        try render(
            RoundConfigEditor(preset: .featurePlan, config: .constant(fourFamily), available: four),
            size: NSSize(width: 620, height: 720),
            to: URL(fileURLWithPath: dir).appendingPathComponent("rounds-editor-four-family.png")
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
