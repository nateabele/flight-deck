import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders the detail header (the request title as a disclosure, collapsed and expanded) and the
/// Intakes list rows, light and dark, for design review. Skipped unless `FD_PLANNING_RENDER_DIR`
/// names an output directory — pictures, not assertions (AGENTS.md rule 2).
@MainActor
final class IntakeTitleRenderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IntakeTitleRenderTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]

    private static let longIntent = """
        Build a field-service scheduling platform: technicians, jobs, a dispatch board and mobile check-in. \
        Technicians start each day from a home depot, and dispatchers can override a skill match as long as \
        they give a reason. Check-in has to work offline, queueing until the phone reconnects, e.g. in \
        basements and plant rooms where there is no signal.
        """

    private let round1 = TriageExchange(
        questions: ["Do technicians work from a home depot, or start each day at their first job?",
                    "Is skill match a hard rule, or can a dispatcher override it?"],
        answers: ["Home depot; travel is from there.", "A dispatcher may override it, with a reason."])

    private func outputDirectory() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_PLANNING_RENDER_DIR"] else {
            throw XCTSkip("set FD_PLANNING_RENDER_DIR to render the header and row PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    func testRenderHeader() throws {
        let out = try outputDirectory()
        let store = IntakeStore(root: root)
        var long = Intake(projectPath: "/tmp/project", intent: Self.longIntent)
        long.state = .awaitingChoice
        long.recommended = .fullPlan
        long.recommendationReason = "Four subsystems with shared rules: worth a full plan with several drafters."
        long.exchanges = [round1]
        var short = Intake(projectPath: "/tmp/project", intent: "Add a contributor note to the README about the release swap.")
        short.state = .needsAnswers
        short.exchanges = [round1, TriageExchange(questions: ["Should it link to docs/AGENT-OPERATIONS.md §2?"])]
        for i in [long, short] { try store.save(i) }
        let service = IntakeService(store: store, triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                                    availableModels: .defaults, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })

        for (name, appearance) in Self.appearances {
            for (label, intake, expanded) in [("collapsed", long, false), ("expanded", long, true), ("one-sentence", short, false)] {
                try PlanningRender.write(IntakeDetailView(service: service, intake: intake, onOpenReview: {}, requestExpanded: expanded),
                                         size: NSSize(width: 820, height: 620),
                                         to: out.appendingPathComponent("header-\(label)-\(name).png"), appearance: appearance)
            }
        }
    }

    func testRenderRows() throws {
        let out = try outputDirectory()
        func intake(_ intent: String, _ state: IntakeState, steps: Int = 0) -> Intake {
            var i = Intake(projectPath: "/tmp/project", intent: intent)
            i.state = state
            if state == .released { i.release = ReleaseRecord(releasedAt: Date(), appliedSteps: steps, idMap: [:]) }
            return i
        }
        let intakes = [
            intake(Self.longIntent, .shaping),
            intake("Make the intake rows taller — show two or three lines of each request so the list can be scanned without opening anything. Keep the state pill.", .review),
            intake("Fix the flicker on resize.", .needsAnswers),
            intake("Bump the triage timeout to 2.5 seconds, e.g. for large monorepos where the graph read is slow. It flakes on CI roughly once a day and the retry hides it.", .failed),
            intake("Add a contributor note to the README about the release swap", .released, steps: 14),
        ]
        let rows: [(String, (Intake) -> AnyView)] = [
            ("chosen", { AnyView(IntakeRow(intake: $0)) }),
            ("alt-mail", { AnyView(MailStyleRow(intake: $0)) }),
            ("alt-inline-pill", { AnyView(InlinePillRow(intake: $0)) }),
            ("alt-reserved", { AnyView(ReservedRow(intake: $0)) }),
        ]
        for (name, appearance) in Self.appearances {
            for (style, row) in rows {
                for width in [320, 280] as [CGFloat] {
                    let list = VStack(alignment: .leading, spacing: 8) {
                        Text("flight-deck").font(.title3.weight(.semibold))
                        Text("Intakes").font(.headline).foregroundStyle(.secondary)
                        List(selection: .constant(Optional(intakes[1].id))) {
                            ForEach(intakes) { row($0).tag($0.id) }
                        }
                    }
                    .padding(16)
                    try PlanningRender.write(list, size: NSSize(width: width, height: 640),
                                             to: out.appendingPathComponent("rows-\(style)-\(Int(width))-\(name).png"),
                                             appearance: appearance)
                }
            }
        }
    }
}

/// Alternative: Mail's two-part row — title on one line with the pill trailing, the rest as a
/// two-line secondary preview under it.
private struct MailStyleRow: View {
    let intake: Intake

    var body: some View {
        let title = IntakeTitle(intent: intake.intent)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.title).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                IntakeStatePill(intake: intake)
            }
            Text(title.rest).font(.callout).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .padding(.vertical, 5)
    }
}

/// Alternative: today's row, the pill leading on the first baseline, the intent wrapped to three.
private struct InlinePillRow: View {
    let intake: Intake

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            IntakeStatePill(intake: intake)
            Text(intake.intent).lineLimit(3)
        }
        .padding(.vertical, 5)
    }
}

/// Alternative: the chosen row, but every row reserves all three lines, as Mail's list does.
private struct ReservedRow: View {
    let intake: Intake

    var body: some View {
        let title = IntakeTitle(intent: intake.intent)
        VStack(alignment: .leading, spacing: 4) {
            IntakeStatePill(intake: intake)
            (Text(title.lead).fontWeight(.semibold)
                + Text(title.rest.isEmpty ? "" : " " + title.rest).foregroundStyle(.secondary))
                .lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }
}
