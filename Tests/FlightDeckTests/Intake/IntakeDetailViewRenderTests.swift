import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders `IntakeDetailView` offscreen to PNGs for design review — skipped by default. Set
/// `FD_INTAKE_RENDER_DIR` to an output directory to run it. Like `PlanningRenderTests`, a
/// picture rather than an assertion: layout can't be checked headlessly in any useful way,
/// but it can be looked at without launching the app (AGENTS.md rule 2).
@MainActor
final class IntakeDetailViewRenderTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeDetailViewRenderTests-\(UUID())", isDirectory: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private let round1 = TriageExchange(
        questions: ["Which README should carry the note — the repository root or docs/README.md?",
                    "Should the existing build badge stay?",
                    "Is this for contributors or for end users?"],
        answers: ["The root one; docs/README.md is generated.", "Yes, keep it where it is.", "Contributors."])
    private let round2 = TriageExchange(
        questions: ["Where should the note sit relative to the Quickstart section?"],
        answers: ["Directly under the title, above Quickstart."])

    func testRenderQuestionsActionsAndClarifications() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_INTAKE_RENDER_DIR"] else {
            throw XCTSkip("set FD_INTAKE_RENDER_DIR to render intake-detail PNGs")
        }
        let out = URL(fileURLWithPath: dir)

        var asking = Intake(projectPath: "/tmp/project", intent: "Add a contributor note to the README about the release swap")
        asking.state = .needsAnswers
        let open = ["How long should the note be — one line or a short section?",
                    "Should it link to docs/AGENT-OPERATIONS.md §2, which describes the release ritual in full, or restate the steps inline?",
                    "Any wording it must avoid?"]
        asking.exchanges = [round1, TriageExchange(questions: open)]

        var choosing = Intake(projectPath: "/tmp/project", intent: "Add a contributor note to the README about the release swap")
        choosing.state = .awaitingChoice
        choosing.recommended = .bead
        choosing.recommendationReason = "One small, self-contained docs change — a single bead covers it."
        choosing.exchanges = [round1, round2]

        var failed = Intake(projectPath: "/tmp/project", intent: "Add a contributor note to the README about the release swap")
        failed.state = .failed
        failed.failure = "codex exited 1: rate limited (429) after 3 attempts."
        failed.rawFailureOutput = "{\"type\":\"error\",\"message\":\"429 Too Many Requests\"}"
        failed.exchanges = [round1]

        let store = IntakeStore(root: root)
        for i in [asking, choosing, failed] { try store.save(i) }
        let service = IntakeService(store: store, triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                    availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
        // Partially typed drafts go through the same file a relaunch reads them back from.
        service.saveAnswerDrafts(asking.id, questions: open, answers: ["One short paragraph.", "Link to it", ""])

        try render(IntakeDetailView(service: service, intake: asking, onOpenReview: {}), to: out.appendingPathComponent("qa-a.png"))
        try render(IntakeDetailView(service: service, intake: choosing, onOpenReview: {}), to: out.appendingPathComponent("qa-b.png"))
        try render(IntakeDetailView(service: service, intake: choosing, onOpenReview: {}, expandedRounds: [0]),
                   to: out.appendingPathComponent("qa-c.png"))
        try render(IntakeDetailView(service: service, intake: failed, onOpenReview: {}), to: out.appendingPathComponent("qa-d.png"))
    }

    /// Parked offscreen `NSHostingView` + `layer.render(in:)` — screencapture is denied here,
    /// and `cacheDisplay` drops layer-backed SwiftUI content.
    private func render(_ view: some View, to url: URL) throws {
        let size = NSSize(width: 560, height: 720)
        let root = view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            // The test runner is never the active app, and activating it would steal focus
            // from whoever is typing; this draws controls as the focused window would.
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        // Long enough for the `.task` that loads the saved drafts to land.
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

