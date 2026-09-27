import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `ShapingView` offscreen to PNGs for design review — skipped by default. Set
/// `FD_SHAPING_RENDER_DIR` to an output directory to run it. Not an assertion test: layout
/// can't be checked headlessly in any useful way, but a picture of it can be looked at
/// without launching the app (AGENTS.md rule 2).
final class ShapingViewRenderTests: XCTestCase {
    private let codex = ModelChoice(harness: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(harness: .claude, model: "opus", effort: "high")

    @MainActor
    func testRenderRunningAndFailedTapes() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_SHAPING_RENDER_DIR"] else {
            throw XCTSkip("set FD_SHAPING_RENDER_DIR to render shaping-view PNGs")
        }
        var intake = Intake(projectPath: "/tmp/project", intent: "Per-project font size")
        intake.state = .shaping
        intake.roundConfig = PresetExpansion.config(for: .featurePlan, available: .defaults)

        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let drafts = RoundRecord(slots: [
            SlotOutcome(role: "drafter", persona: .arbiter, used: codex, requested: codex, status: .ok),
            SlotOutcome(role: "drafter", persona: .realist, used: codex, requested: claude, status: .substituted,
                        diagnosis: Diagnosis(category: .authExpired, detail: "claude login expired", action: "Run `claude /login`")),
        ], linesAdded: 212)
        let base: [Checkpoint] = [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: date, record: drafts),
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: date,
                       record: RoundRecord(slots: [SlotOutcome(role: "synthesizer", persona: .arbiter, used: codex, requested: codex, status: .ok)],
                                           linesAdded: 240, linesRemoved: 60)),
            Checkpoint(id: 3, parent: 2, stage: .refine, round: 1, major: false, createdAt: date,
                       record: RoundRecord(slots: [SlotOutcome(role: "reviewer", used: codex, requested: codex, status: .ok)],
                                           changeCount: 41, linesAdded: 620, linesRemoved: 180,
                                           tally: VerdictTally(agree: 33, somewhat: 6, disagree: 2))),
            Checkpoint(id: 4, parent: 3, stage: .refine, round: 2, major: false, createdAt: date,
                       record: RoundRecord(slots: [SlotOutcome(role: "reviewer", used: codex, requested: codex, status: .ok)],
                                           changeCount: 14, linesAdded: 140, linesRemoved: 95,
                                           tally: VerdictTally(agree: 12, somewhat: 2, disagree: 0))),
        ]
        let plans: [Int: String] = [
            1: "# Per-project font size\n\n## Settings storage\nFonts resolve through the plugin registry,\n  falling back to the global default.\n",
            2: "# Per-project font size\n\n## Architecture\nOne setting per project.\n\n## Settings storage\nFonts resolve through the plugin registry,\n  falling back to the global default.\n",
            3: "# Per-project font size\n\n## Architecture\nOne setting per project.\n\n## Settings storage\nEach project stores `fontSize` in\n  ProjectSettings; nil means inherit.\n",
            4: "# Per-project font size\n\n## Architecture\nOne setting per project.\n\n## Settings storage\nEach project stores `fontSize` in\n  ProjectSettings; nil means inherit the\n  global preference, read at surface init.\n\n## Testing\nPin the fallback.\n",
        ]
        let load: (Int, String) -> Data? = { id, path in
            if id == 1, path == "drafts/0.md" { return plans[1].map { Data($0.utf8) } }
            if id > 1, path == "plan.md" { return plans[id].map { Data($0.utf8) } }
            return nil
        }

        var running = Tape(checkpoints: base, target: .nextMajor, status: .running,
                           roundInProgress: PlannedRound(stage: .refine, round: 3, major: true))
        running.pendingAnnotations = ["no plugin system"]
        var failed = Tape(checkpoints: base, target: .none, status: .failed)
        failed.pauseDiagnosis = Diagnosis(category: .rateLimited, detail: "codex returned 429 after 3 attempts",
                                          action: "Wait about 5 minutes, then press ⏯ to retry R3")

        try render(ShapingView(intake: intake, tape: running, loadFile: load, onSend: { _ in }),
                   to: URL(fileURLWithPath: dir).appendingPathComponent("shaping-running.png"))
        try render(ShapingView(intake: intake, tape: failed, loadFile: load, onSend: { _ in }, viewerMode: .diff),
                   to: URL(fileURLWithPath: dir).appendingPathComponent("shaping-failed.png"))
    }

    /// Parked offscreen `NSHostingView` + `layer.render(in:)` — screencapture is denied here,
    /// and `cacheDisplay` drops layer-backed SwiftUI content.
    @MainActor
    private func render(_ view: some View, to url: URL) throws {
        let size = NSSize(width: 820, height: 640)
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
