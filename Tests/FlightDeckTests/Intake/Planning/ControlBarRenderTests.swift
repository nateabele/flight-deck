import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `ControlBar` offscreen to a PNG for design review — skipped by default. Set
/// `FD_INTAKE_RENDER_DIR` to an output directory to run it; it writes `pui-controlbar.png`:
/// running, paused, failed and review at 1100 pt, then running and paused at 600 pt (the
/// compact bar). A picture rather than an assertion, like `SplitFlapTextRenderTests`.
@MainActor
final class ControlBarRenderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testRenderStatesAtFullAndCompactWidths() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_INTAKE_RENDER_DIR"] else {
            throw XCTSkip("set FD_INTAKE_RENDER_DIR to render the control bar PNG")
        }
        var intake = Intake(projectPath: "/tmp/project", intent: "Field-service scheduling platform")
        intake.state = .shaping
        let config = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: .defaults))
        intake.roundConfig = config
        intake.exchanges = [TriageExchange(questions: ["Q?"], answers: ["A"])]

        func cp(_ id: Int, _ stage: Stage, _ round: Int, major: Bool, at: TimeInterval, _ added: Int, _ removed: Int) -> Checkpoint {
            Checkpoint(id: id, stage: stage, round: round, major: major, createdAt: t0.addingTimeInterval(at),
                       record: RoundRecord(linesAdded: added, linesRemoved: removed))
        }
        let landed = [cp(1, .draft, 0, major: true, at: 0, 412, 0), cp(2, .synthesis, 0, major: true, at: 180, 30, 12),
                      cp(3, .refine, 1, major: false, at: 468, 12, 5)]
        var running = Tape(checkpoints: landed, target: .nextMajor, status: .running,
                           roundInProgress: PlannedRound(stage: .refine, round: 2, major: false),
                           roundStartedAt: t0.addingTimeInterval(468))
        running.ackedCommandSeq = 3
        let paused = Tape(checkpoints: landed, status: .paused)
        let failed = Tape(checkpoints: landed, status: .failed,
                          pauseDiagnosis: Diagnosis(category: .rateLimited, detail: "429 from codex", action: "Wait"),
                          roundStartedAt: t0.addingTimeInterval(500), failedAt: t0.addingTimeInterval(530))
        let review = Tape(checkpoints: landed, status: .reachedReview)

        let seat = { (glyph: SeatRowModel.Glyph, cost: Double?) in
            SeatRowModel(id: UUID().uuidString, glyph: glyph, role: "reviewer", identity: "claude", headline: nil,
                         action: nil, footprint: [], footprintAll: [], steps: nil, contextFraction: nil, elapsed: 0,
                         exception: nil, result: nil, cost: cost)
        }
        let seats = [seat(.done, 0.61), seat(.running, nil), seat(.running, nil), seat(.queued, nil)]
        let converging = ConvergenceCellModel(word: "CONVERGING ↘", latest: 14, spark: [41, 14], tone: .normal)
        let diverging = ConvergenceCellModel(word: "DIVERGING ↗", latest: 29, spark: [22, 9, 17, 29], tone: .amber)

        let policy = FlapPolicy()
        func bar(_ title: String, _ tape: Tape, seats: [SeatRowModel] = [], convergence: ConvergenceCellModel?,
                 halt: HaltRequest? = nil, width: CGFloat) -> some View {
            let now = t0.addingTimeInterval(723)
            let board = BoardModel(intake: intake, tape: tape, config: config, now: now, selected: nil, preview: nil)
            let lcd = LCDModel(tape: tape, config: config, board: board, seats: seats, convergence: convergence,
                               preview: nil, now: now)
            let shaping = ShapingModel(intake: intake, tape: tape)
            return VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ControlBar(lcd: lcd, convergence: convergence,
                           actions: PlanningActions(enabled: shaping.enabled, perform: { _ in }),
                           status: tape.status, defaultPlay: config.defaultPlay, halting: halt?.label(for: tape),
                           policy: policy, preview: .constant(nil), setDefaultPlay: { _ in }, onBack: {})
                    .frame(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }

        let view = VStack(alignment: .leading, spacing: 18) {
            bar("Running Refine 2 · 1100 pt", running, seats: seats, convergence: converging, width: 1100)
            bar("Running, pause sent and not yet acknowledged · 1100 pt", running, seats: seats, convergence: converging,
                halt: HaltRequest(kind: .pause, seq: 4), width: 1100)
            bar("Paused after Refine 1 · 1100 pt", paused, convergence: converging, width: 1100)
            bar("Failed (rate limited) · 1100 pt", failed, convergence: diverging, width: 1100)
            bar("Review · 1100 pt", review, convergence: converging, width: 1100)
            bar("Running · 600 pt (compact)", running, seats: seats, convergence: converging, width: 600)
            bar("Paused · 600 pt (compact)", paused, convergence: converging, width: 600)
            bar("Failed · 600 pt (compact)", failed, convergence: diverging, width: 600)
        }
        .padding(20)
        try render(view, size: NSSize(width: 1140, height: 960),
                   to: URL(fileURLWithPath: dir).appendingPathComponent("pui-controlbar.png"))
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
