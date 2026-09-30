import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

/// Draws Flight Control's phone screens (spec §10.5) so they can be looked at.
///
/// **Not a test, and it asserts nothing** — for the same reason as `ProseRenderHarness`: whether
/// a clock is readable on the strip, whether amber lands only on the stalled agent, whether a
/// row clips at the largest accessibility size, none of that is reachable by an assertion. It
/// draws the real screens (`IntakeScreen`, `RoundDetailScreen`, `PlanOutlineScreen`,
/// `PlanReaderScreen`) inside a `NavigationStack`, fed fixture details through a stub fetcher,
/// and writes PNGs. Phase 2 adds the steering surfaces: the transport row, the Rounds ±,
/// `NoteSheet`, and the reader's unsent and failed note cards.
///
/// Skipped unless `RENDER_INTAKE` is set. Its value is the output directory when it is an
/// absolute path (the simulator `test-ios.sh` creates is deleted when it exits, taking
/// `NSTemporaryDirectory()` with it), else the PNGs go to `NSTemporaryDirectory()`. An
/// app-hosted suite takes its environment from the SCHEME, not the command line
/// (`docs/MOBILE-UI.md`, "An offscreen render"), so for one run add, under `schemes:
/// FlightDeckMobile: test:` in `project.yml`,
///
///     environmentVariables:
///       RENDER_INTAKE: /tmp/<somewhere>/fc-renders
///
/// run `./scripts/test-ios.sh`, and take the entry back out.
@MainActor
final class IntakeRenderHarness: XCTestCase {

    /// iPhone 16/17 Pro in points. Screens are drawn at a phone's real size rather than measured:
    /// a `List` fills whatever it is offered, so measuring one reports the offer back.
    private static let width: CGFloat = 393
    private static let screenHeight: CGFloat = 852

    private var outputDirectory: URL!
    /// The models hold their fetcher `weak` (the real one is `FleetModel`, which outlives them),
    /// so a stub made inline is gone before the first request and the screen draws a spinner.
    private var stubs: [StubFetcher] = []
    /// `IntakeCommandModel` holds its commander `weak` for the same reason.
    private var commanders: [StubCommander] = []

    /// Called first by every render rather than from `setUp`, which is nonisolated.
    private func begin() throws {
        let value = ProcessInfo.processInfo.environment["RENDER_INTAKE"]
        try XCTSkipUnless(value != nil, "set RENDER_INTAKE to draw the Flight Control screens")
        outputDirectory = value!.hasPrefix("/")
            ? URL(fileURLWithPath: value!, isDirectory: true)
            : URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    private func stub(_ detail: WireIntakeDetail) -> StubFetcher {
        let fetcher = StubFetcher(detail: detail)
        stubs.append(fetcher)
        return fetcher
    }

    // MARK: - Renders

    func testDrawIntakeScreens() throws {
        try begin()
        for (name, detail) in Fixture.states {
            for style in [UIUserInterfaceStyle.light, .dark] {
                try draw(intake: detail, style: style, size: nil, to: "intake-\(name)-\(Self.styleName(style)).png")
            }
        }
        // The largest accessibility size, on a canvas tall enough to see every section: at
        // AX5 the screen's content runs to several phone heights.
        for (name, detail) in Fixture.states where ["running", "needs-answers", "failed"].contains(name) {
            try draw(intake: detail, style: .light, size: .accessibility5, to: "intake-\(name)-ax5.png", height: 2600)
        }
    }

    /// The five strips stacked, measured then drawn (two passes, as `ProseRenderHarness` does), so
    /// the tones can be compared side by side without the list around them.
    func testDrawStrips() throws {
        try begin()
        let strips = VStack(alignment: .leading, spacing: 14) {
            ForEach(Fixture.states, id: \.0) { name, detail in
                Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
                BoardStrip(model: BoardStripModel(detail: detail), offset: 0, frozenAt: nil, onDot: { _ in })
            }
            Text("running, link lost").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
            BoardStrip(model: BoardStripModel(detail: Fixture.running), offset: 0,
                       frozenAt: Date().addingTimeInterval(-30), onDot: { _ in })
        }
        .padding(.vertical, 12)
        for style in [UIUserInterfaceStyle.light, .dark] {
            try write(measuredImage(of: strips, style: style), to: "strips-\(Self.styleName(style)).png")
        }
    }

    func testDrawRoundDetail() throws {
        try begin()
        let flightControl = FlightControlModel(fetcher: stub(Fixture.running))
        let model = flightControl.detailModel(for: Fixture.running.summary.id)
        model.refresh()
        for (name, checkpoint) in [("verdicts", 3), ("no-verdicts", 1)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let view = NavigationStack {
                    RoundDetailScreen(intake: Fixture.running.summary.id, checkpoint: checkpoint,
                                      model: model, flightControl: flightControl)
                }
                try write(screenImage(of: view, style: style, size: nil), to: "round-\(name)-\(Self.styleName(style)).png")
            }
        }
    }

    func testDrawClarifications() throws {
        try begin()
        let flightControl = FlightControlModel(fetcher: stub(Fixture.needsAnswers))
        let model = flightControl.detailModel(for: Fixture.needsAnswers.summary.id)
        model.refresh()
        let view = NavigationStack {
            ClarificationsScreen(intake: Fixture.needsAnswers.summary.id, model: model, flightControl: flightControl)
        }
        try write(screenImage(of: view, style: .light, size: nil), to: "clarifications-light.png")
    }

    func testDrawPlan() throws {
        try begin()
        let id = Fixture.running.summary.id
        for style in [UIUserInterfaceStyle.light, .dark] {
            let outline = NavigationStack {
                PlanOutlineScreen(intake: id, checkpoint: nil,
                                  flightControl: FlightControlModel(fetcher: stub(Fixture.running)))
            }
            try write(screenImage(of: outline, style: style, size: nil), to: "outline-\(Self.styleName(style)).png")

            // The note sheet is the screen's private state and a tap away; the reader with its
            // notes washed is what is reachable from here.
            for changes in [false, true] {
                let reader = NavigationStack {
                    PlanReaderScreen(intake: id, checkpoint: nil, startBlock: nil, changes: changes,
                                     flightControl: FlightControlModel(fetcher: stub(Fixture.running)))
                }
                try write(screenImage(of: reader, style: style, size: nil, height: 1700),
                          to: "reader-\(changes ? "changes" : "notes")-\(Self.styleName(style)).png")
            }
        }
    }

    /// The Sessions list's intake rows and the banner — the two places an intake shows before it
    /// is opened.
    func testDrawRowsAndBanner() throws {
        try begin()
        let rows = List {
            Section {
                ForEach(IntakeRowStyle.ordered(Fixture.states.map(\.1.summary))) { s in
                    NavigationLink(value: s.id) { IntakeRow(summary: s, offset: 0, frozenAt: nil) }
                }
            } header: { Text("larkOS").font(.footnote) }
        }
        let screen = NavigationStack {
            VStack(spacing: 0) {
                AttentionBanner(banner: IntakeBanner(id: UUID(), project: "larkOS",
                                                     title: "Drain the queue before the flag flip needs answers",
                                                     subtitle: "larkOS · 3 questions"),
                                onOpen: {}, onDismiss: {})
                rows
            }
            .navigationTitle("Sessions").navigationBarTitleDisplayMode(.inline)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            try write(screenImage(of: screen, style: style, size: nil), to: "rows-\(Self.styleName(style)).png")
        }
        try write(screenImage(of: screen, style: .light, size: .accessibility5), to: "rows-ax5.png")
    }

    // MARK: - Phase 2: steering

    /// The strip with its transport row: running (only Pause and Stop live), paused (the default
    /// dot on Next major), a Pause the Mac is acting on, and a halt "stopping" (every key off,
    /// Stop reading "Stopping…"). The Stop confirmation is a system dialog and cannot be drawn.
    func testDrawTransportStrips() throws {
        try begin()
        let cases: [(String, WireIntakeDetail)] = [
            ("running", Fixture.steering(Fixture.running, enabled: ["pause", "stop", "extend", "trim"])),
            ("paused", Fixture.steering(Fixture.paused, enabled: ["step", "nextMajor", "toReview", "stop", "extend", "trim"])),
            ("pausing", Fixture.steering(Fixture.running, enabled: ["pause", "stop"], halt: "pausing")),
            ("stopping", Fixture.steering(Fixture.running, enabled: ["pause", "stop"], halt: "stopping")),
        ]
        let strips = VStack(alignment: .leading, spacing: 14) {
            ForEach(cases, id: \.0) { name, detail in
                Text(name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
                BoardStrip(model: BoardStripModel(detail: detail), offset: 0, frozenAt: nil, onDot: { _ in },
                           keys: TransportKeys.keys(detail: detail, inFlight: []))
            }
            Text("running, link lost").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
            BoardStrip(model: BoardStripModel(detail: cases[0].1), offset: 0, frozenAt: Date().addingTimeInterval(-30),
                       onDot: { _ in }, keys: TransportKeys.keys(detail: cases[0].1, inFlight: []))
        }
        .padding(.vertical, 12)
        for style in [UIUserInterfaceStyle.light, .dark] {
            try write(measuredImage(of: strips, style: style), to: "transport-strips-\(Self.styleName(style)).png")
        }
        try write(measuredImage(of: strips, style: .light, size: .accessibility5), to: "transport-strips-ax5.png")
    }

    /// The whole intake screen while steering: the strip's transport row in place, and the
    /// Rounds header's "Refine ×5 − +".
    func testDrawSteeringIntakeScreen() throws {
        try begin()
        let running = Fixture.steering(Fixture.running, enabled: ["pause", "stop", "extend", "trim"])
        let paused = Fixture.steering(Fixture.paused, enabled: ["step", "nextMajor", "toReview", "stop", "extend", "trim"])
        for style in [UIUserInterfaceStyle.light, .dark] {
            try draw(intake: running, style: style, size: nil, to: "steer-running-\(Self.styleName(style)).png")
            try draw(intake: paused, style: style, size: nil, to: "steer-paused-\(Self.styleName(style)).png")
        }
        // 2600 as the Phase 1 AX5 renders: at 3200 the draw came back blank (one colour).
        try draw(intake: running, style: .light, size: .accessibility5, to: "steer-running-ax5.png", height: 2600)
    }

    /// `NoteSheet` on its own, full height: a phrase note (quote, all six kinds) and a plan-wide
    /// one (no quote, no Highlight). The keyboard is not drawn offscreen.
    func testDrawNoteSheet() throws {
        try begin()
        let phrase = NoteDraft(target: NoteDraftTarget(block: 4, quote: "wait until the queue drains — check queue.isEmpty"),
                               showing: 3, kind: "mustChange", text: "Say what happens to a job that is mid-flight when the ceiling hits.")
        let wide = NoteDraft(target: NoteDraftTarget(block: nil, quote: nil), showing: 3)
        for style in [UIUserInterfaceStyle.light, .dark] {
            try write(screenImage(of: NoteSheet(draft: phrase) { _ in }, style: style, size: nil),
                      to: "note-sheet-quote-\(Self.styleName(style)).png")
            try write(screenImage(of: NoteSheet(draft: wide) { _ in }, style: style, size: nil),
                      to: "note-sheet-plan-wide-\(Self.styleName(style)).png")
        }
        try write(screenImage(of: NoteSheet(draft: phrase) { _ in }, style: .light, size: .accessibility5),
                  to: "note-sheet-quote-ax5.png")
    }

    /// The reader at the head with notes on: one note the Mac has not answered ("Not yet sent")
    /// and one whose send failed (Retry / Discard, the reason in the message row).
    func testDrawReaderWithUnsentNotes() throws {
        try begin()
        let detail = Fixture.steering(Fixture.running, enabled: ["pause", "stop", "extend", "trim"])
        let id = detail.summary.id
        for (name, answer) in [("unsent", nil), ("failed", Result<Void, FleetRequestError>.failure(.server(code: "not_allowed")))] {
            let commander = StubCommander(answer: answer)
            commanders.append(commander)
            let flightControl = FlightControlModel(fetcher: stub(detail), commander: commander)
            flightControl.detailModel(for: id).refresh()
            let passage = NoteDraft(target: NoteDraftTarget(block: 4, quote: "the queue drains"), showing: 3,
                                    kind: "question", text: "What if a producer ignores the pause?")
            let wide = NoteDraft(target: NoteDraftTarget(block: nil, quote: nil), showing: 3,
                                 kind: "comment", text: "Keep the plan to one page.")
            var outbox = NoteOutbox()
            for d in [passage, wide] {
                outbox.submit(d)
                // The send the reader would have made: in flight until answered, or failed.
                flightControl.commands(for: id).send(.note(d.id), command: {
                    .intakeNote(id: id, token: $0, noteID: d.id, kind: d.kind, text: d.text,
                                checkpoint: d.checkpoint, block: d.target.block, quote: d.target.quote)
                }, onAck: {})
            }
            for style in [UIUserInterfaceStyle.light, .dark] {
                let reader = NavigationStack {
                    PlanReaderScreen(intake: id, checkpoint: nil, startBlock: nil, changes: false,
                                     flightControl: flightControl, outbox: outbox)
                }
                try write(screenImage(of: reader, style: style, size: nil, height: 2000),
                          to: "reader-\(name)-\(Self.styleName(style)).png")
            }
        }
    }

    // MARK: - Drawing

    private func draw(intake detail: WireIntakeDetail, style: UIUserInterfaceStyle, size: DynamicTypeSize?,
                      to name: String, height: CGFloat = screenHeight) throws {
        let fleet = FleetModel(store: InMemoryPairedMacStore())
        let model = IntakeDetailModel(id: detail.summary.id, fetcher: stub(detail))
        model.refresh()
        let view = NavigationStack { IntakeScreen(id: detail.summary.id, model: model, fleet: fleet) }
        try write(screenImage(of: view, style: style, size: size, height: height), to: name)
    }

    /// A phone-sized screen: fixed size, one window, and a short run-loop spin so `.task` loads
    /// and the `List`'s cells exist before `drawHierarchy`.
    private func screenImage(of view: some View, style: UIUserInterfaceStyle, size: DynamicTypeSize?,
                             height: CGFloat = screenHeight) -> UIImage {
        let frame = CGRect(x: 0, y: 0, width: Self.width, height: height)
        let controller = UIHostingController(rootView: AnyView(sized(view, size)))
        controller.overrideUserInterfaceStyle = style
        controller.view.backgroundColor = .systemBackground
        controller.view.frame = frame
        let window = UIWindow(frame: frame)
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = style
        if size != nil { window.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(size: frame.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }

    private func sized(_ view: some View, _ size: DynamicTypeSize?) -> some View {
        view.environment(\.dynamicTypeSize, size ?? .large)
    }

    /// **Measured in one window, drawn in another** — see `ProseRenderHarness.image(of:style:)`
    /// for why the two passes cannot share a window.
    private func measuredImage(of view: some View, style: UIUserInterfaceStyle, size type: DynamicTypeSize? = nil) -> UIImage {
        let view = sized(view, type)
        let measuring = UIHostingController(rootView: view.frame(width: Self.width))
        measuring.view.frame = CGRect(x: 0, y: 0, width: Self.width, height: 4000)
        let scratch = UIWindow(frame: measuring.view.frame)
        scratch.rootViewController = measuring
        scratch.isHidden = false
        scratch.layoutIfNeeded()
        let height = measuring.sizeThatFits(in: CGSize(width: Self.width, height: .greatestFiniteMagnitude)).height
        print("MEASURED strips \(Self.width)×\(height)")

        let size = CGSize(width: Self.width, height: height)
        let controller = UIHostingController(rootView: view.frame(width: Self.width))
        controller.overrideUserInterfaceStyle = style
        controller.view.backgroundColor = .systemBackground
        controller.view.frame = CGRect(origin: .zero, size: size)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.overrideUserInterfaceStyle = style
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
    }

    /// Writes the PNG and prints its pixel size and how many distinct colours a 24×24 sample
    /// grid found — a blank image is the failure mode (MOBILE-UI), and it samples as 1 or 2.
    private func write(_ image: UIImage, to name: String) throws {
        let url = outputDirectory.appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        let cg = try XCTUnwrap(image.cgImage)
        print("RENDERED \(url.path) \(cg.width)×\(cg.height)px scale=\(image.scale) colours=\(sampledColours(cg))")
    }

    private func sampledColours(_ image: CGImage) -> Int {
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return -1 }
        var seen = Set<UInt32>()
        for gy in 0..<24 {
            for gx in 0..<24 {
                let (x, y) = (gx * (w - 1) / 23, gy * (h - 1) / 23)
                let i = (y * w + x) * 4
                seen.insert(UInt32(pixels[i]) << 24 | UInt32(pixels[i + 1]) << 16 | UInt32(pixels[i + 2]) << 8 | UInt32(pixels[i + 3]))
            }
        }
        return seen.count
    }

    private static func styleName(_ style: UIUserInterfaceStyle) -> String { style == .dark ? "dark" : "light" }
}

/// Answers every detail request with one fixture (then "unchanged"), and every plan request
/// with `Fixture.plan` — synchronously, so a screen has content by its first layout.
@MainActor
private final class StubFetcher: IntakeFetching {
    let detail: WireIntakeDetail
    private var served = false
    init(detail: WireIntakeDetail) { self.detail = detail }

    func intakeDetail(_ id: UUID, ifNot: String?, then: @escaping (Result<WireIntakeDetail?, FleetRequestError>) -> Void) {
        then(.success(ifNot == detail.etag ? nil : detail))
    }

    func intakePlan(_ id: UUID, checkpoint: Int?, changes: Bool, then: @escaping (Result<WireIntakePlan, FleetRequestError>) -> Void) {
        var plan = Fixture.plan
        if !changes { plan.added = nil; plan.removed = nil }
        then(.success(plan))
    }
}

/// Never answers (`answer == nil`: the send stays in flight, as when the Mac has not acked), or
/// answers at once with `answer`.
@MainActor
private final class StubCommander: IntakeCommanding {
    let answer: Result<Void, FleetRequestError>?
    init(answer: Result<Void, FleetRequestError>?) { self.answer = answer }

    func sendIntake(_ command: FleetCommand, then: @escaping (Result<Void, FleetRequestError>) -> Void) {
        if let answer { then(answer) }
    }
}

/// Fixture intakes, one per state the spec asks to see. Dates are relative to now so the clocks
/// read like a real run.
@MainActor
private enum Fixture {
    static let project = UUID()
    static let t = Date()
    static func ago(_ s: TimeInterval) -> Date { t.addingTimeInterval(-s) }

    static let states: [(String, WireIntakeDetail)] = [
        ("running", running), ("paused", paused), ("needs-answers", needsAnswers),
        ("awaiting-choice", awaitingChoice), ("failed", failed),
    ]

    static func slots(live: String?, failed: String? = nil) -> [WireSlot] {
        func state(_ id: String, landed: Bool) -> String {
            if id == failed { return "failed" }
            if id == live { return "live" }
            return landed ? "done" : "future"
        }
        return [
            WireSlot(id: "draft-0", name: "Drafts", code: "DRF", state: state("draft-0", landed: true), major: true, checkpoint: 1, duration: 512),
            WireSlot(id: "refine-1", name: "Refine 1", code: "RF1", state: state("refine-1", landed: true), group: "REFINE", checkpoint: 3, duration: 391),
            WireSlot(id: "refine-2", name: "Refine 2", code: "RF2", state: state("refine-2", landed: false), group: "REFINE"),
            WireSlot(id: "refine-3", name: "Refine 3", code: "RF3", state: state("refine-3", landed: false), group: "REFINE"),
            WireSlot(id: "encode-0", name: "Encode", code: "ENC", state: "future", major: true),
            WireSlot(id: "polish-1", name: "Polish 1", code: "PL1", state: "future", group: "POLISH"),
            WireSlot(id: "review-0", name: "Review", code: "REV", state: "future", major: true),
        ]
    }

    static func board(live: String?, failed: String? = nil, caption: String, since: Date?,
                      convergence: WireConvergence?) -> WireBoard {
        WireBoard(slots: slots(live: live, failed: failed), nowName: "Refine 2", nowChip: "ON COURSE",
                  clockCaption: caption, clockSince: since, stopsAt: "Encode", stopSlotID: "encode-0",
                  callingAt: "3 · Encode · Polish 1 · Review", convergence: convergence, defaultPlay: "nextMajor")
    }

    static let rounds: [WireRound] = [
        WireRound(checkpoint: 1, name: "Drafts", code: "DRF", stage: "draft", startedAt: nil, landedAt: ago(1_600),
                  outcome: "fallback", linesAdded: 0, linesRemoved: 0,
                  agents: [WireRoundAgent(role: "drafter", ran: "claude · opus · high", status: "ok"),
                           WireRoundAgent(role: "drafter", ran: "codex · gpt-6-sol · high", status: "substituted",
                                          detail: "fell back to codex · claude returned 529")]),
        WireRound(checkpoint: 3, name: "Refine 1", code: "RF1", stage: "refine", startedAt: ago(1_200), landedAt: ago(809),
                  outcome: "ok", changeCount: 41, linesAdded: 620, linesRemoved: 180,
                  verdicts: WireVerdicts(agreed: 33, somewhat: 6, declined: 2),
                  note: "Tightened the rollback path and split the drain into its own section.",
                  sectionsChanged: ["Approach", "Rollback", "Checks before the flip"],
                  agents: [WireRoundAgent(role: "reviewer", ran: "codex · gpt-6-sol · high", status: "ok"),
                           WireRoundAgent(role: "editor", ran: "claude · opus · high", status: "ok")],
                  notesConsumed: [WireNote(id: UUID(), kind: "mustChange", text: "Say what happens to a job mid-flight.",
                                           quote: "the queue drains", consumed: true, blockIndex: 4)]),
    ]

    static let agents: [WireAgent] = [
        WireAgent(id: "a1", glyph: "running", role: "reviewer", identity: "codex · gpt-6-sol · high",
                  headline: "Checking the drain order against the flag flip", action: "Reading Sources/Queue/Drain.swift",
                  steps: "14 steps", contextFraction: 0.42, startedAt: ago(214), lastEventAt: ago(3)),
        WireAgent(id: "a2", glyph: "done", role: "reviewer", identity: "claude · opus · high",
                  result: "Flagged 9 changes, 2 of them blocking", duration: 391),
        WireAgent(id: "a3", glyph: "running", role: "reviewer", identity: "gemini · 3-pro",
                  headline: "Reviewing the rollback section", action: "Running swift test --filter QueueTests",
                  steps: "6 steps", contextFraction: 0.18, startedAt: ago(400), lastEventAt: ago(128)),
        WireAgent(id: "a4", glyph: "running", role: "editor", identity: "claude · sonnet · medium",
                  headline: "Waiting for reviews", action: "Waiting for reviews", startedAt: ago(90), lastEventAt: ago(41)),
    ]

    static let running = WireIntakeDetail(
        etag: "run", project: project,
        summary: WireIntakeSummary(id: UUID(), title: "Drain the queue before the flag flip", state: "shaping",
                                   needsAttention: false, preset: "fullPlan", now: "Refine 2", runStatus: "running",
                                   clockSince: ago(754), agentsDone: 1, agentsTotal: 4, createdAt: ago(2_000)),
        intent: "Drain the queue before flipping the flag.",
        board: board(live: "refine-2", caption: "IN THE AIR", since: ago(754),
                     convergence: WireConvergence(word: "DIVERGING ↗", amber: true, spark: [41, 52])),
        agents: agents, rounds: rounds,
        questions: WireQuestions(answered: [WireExchange(questions: ["Which flag?"], answers: ["queue_v2"])]),
        pendingNotes: 2, headCheckpoint: 3, servedAt: t)

    static let paused = WireIntakeDetail(
        etag: "paused", project: project,
        summary: WireIntakeSummary(id: UUID(), title: "Split the billing export", state: "shaping",
                                   needsAttention: false, preset: "featurePlan", now: "Refine 2", runStatus: "paused",
                                   clockSince: ago(4_000), createdAt: ago(9_000)),
        intent: "Split the billing export.",
        board: board(live: nil, caption: "PAUSED FOR", since: ago(4_000),
                     convergence: WireConvergence(word: "SETTLING ↘", spark: [41, 12])),
        rounds: rounds, pendingNotes: 0, headCheckpoint: 3, servedAt: t)

    static let needsAnswers = WireIntakeDetail(
        etag: "answers", project: project,
        summary: WireIntakeSummary(id: UUID(), title: "Add retries to the sync worker", state: "needsAnswers",
                                   needsAttention: true, preset: "bead", now: "Clarify 2", questionCount: 3,
                                   createdAt: ago(300)),
        intent: "Add retries to the sync worker.",
        questions: WireQuestions(
            open: ["Should a retry reuse the original request id, or mint a new one so the server logs tell them apart?",
                   "What is the ceiling on attempts?",
                   "Is a 409 retryable?"],
            answered: [WireExchange(questions: ["Which worker — the push or the pull side?", "Is backoff jittered today?"],
                                    answers: ["Pull.", "No, fixed 2 s."])]),
        servedAt: t)

    static let awaitingChoice = WireIntakeDetail(
        etag: "choice", project: project,
        summary: WireIntakeSummary(id: UUID(), title: "Move settings to the new schema", state: "awaitingChoice",
                                   needsAttention: true, createdAt: ago(600)),
        intent: "Move settings to the new schema.",
        questions: WireQuestions(answered: [WireExchange(questions: ["Keep the old keys readable?"], answers: ["For one release."])]),
        choice: WireChoice(recommended: "featurePlan",
                           reason: "Three files and a migration; a sketch would skip the rollback, a full plan is more than it needs.",
                           roundsSummary: "Drafts · 2 refine · review"),
        servedAt: t)

    static let failed = WireIntakeDetail(
        etag: "failed", project: project,
        summary: WireIntakeSummary(id: UUID(), title: "Rewrite the log shipper", state: "failed", needsAttention: true,
                                   preset: "fullPlan", now: "Refine 2", runStatus: "failed", createdAt: ago(5_000)),
        intent: "Rewrite the log shipper.",
        board: board(live: nil, failed: "refine-2", caption: "IN THE AIR", since: nil, convergence: nil),
        rounds: rounds,
        failure: WireFailure(reason: "Every reviewer failed in Refine 2: claude exited 1, codex hit its rate limit twice.",
                             output: "error: rate limit exceeded (429)\nretry-after: 60\nexit status 1"),
        pendingNotes: 1, headCheckpoint: 3, servedAt: t)

    /// `detail` from a Mac that takes commands: `steer`, the board's controls with `enabled` live,
    /// and a Refine cycle of five that both ± act on.
    static func steering(_ detail: WireIntakeDetail, enabled: [String], halt: String? = nil) -> WireIntakeDetail {
        var d = detail
        d.steer = true
        d.halt = halt
        d.etag += "-steer-\(enabled.joined())-\(halt ?? "")"
        d.board?.controls = WireControls(enabled: enabled, extendStage: "refine", trimStage: "refine",
                                         cycleName: "Refine", cyclePlanned: 5)
        return d
    }

    static let markdown = """
    # Drain the queue before the flag flip

    ## Goal

    Flip `queue_v2` without losing a job. A job that starts under the old flag and finishes under the new one writes a row neither side can read.

    ## Approach

    Stop intake, then wait until **the queue drains** — check `queue.isEmpty`, not `queue.count == 0`, which races.

    - Pause the producers with `Producer.pause(all:)`.
    - Wait for in-flight jobs, with a ceiling of five minutes.

    ## Rollback

    If the drain times out, resume the producers and leave the flag where it was. Nothing has been written under the new flag yet, so there is nothing to undo.

    ### Checks before the flip

    Compare the row counts on both sides and refuse to flip on a mismatch.
    """

    static let plan = WireIntakePlan(
        checkpoint: 3, roundName: "Refine 1", editsVersion: "v1", markdown: markdown,
        outline: [
            WireSection(heading: "Drain the queue before the flag flip", level: 1, blockIndex: 0, churn: [12, 2]),
            WireSection(heading: "Goal", level: 2, blockIndex: 1, churn: [4, 0], settledSince: "Refine 1"),
            WireSection(heading: "Approach", level: 2, blockIndex: 3, churn: [30, 22], diverging: true),
            WireSection(heading: "Rollback", level: 2, blockIndex: 7, churn: [18, 9]),
            WireSection(heading: "Checks before the flip", level: 3, blockIndex: 9, churn: [0, 6]),
        ],
        notes: [
            WireNote(id: UUID(), kind: "question", text: "Five minutes from when — the pause or the last enqueue?",
                     quote: "a ceiling of five minutes", section: "Approach", blockIndex: 6),
            WireNote(id: UUID(), kind: "comment", text: "", quote: "the queue drains", section: "Approach", blockIndex: 4),
            WireNote(id: UUID(), kind: "mustChange", text: "Say who gets paged.", quote: "resume the producers",
                     section: "Rollback", consumed: true, blockIndex: 8),
            WireNote(id: UUID(), kind: "comment", text: "The old wording about batch jobs went missing.",
                     quote: "batch jobs are retried", section: "Approach", blockIndex: nil),
        ],
        added: [5, 6],
        removed: [WireRemovedBlock(after: 4, text: "Batch jobs are retried by the scheduler, so they can be ignored.")])
}
