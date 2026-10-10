import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The Rounds editor laid out as the round timeline, and the main view's chips beside it,
/// offscreen for design review — skipped unless `FD_TIMELINE_RENDER_DIR` names an output
/// directory. `testRenderOptions` draws the layouts the shipped one was picked from
/// (`options/option-*.png`); `testRenderFinal` draws the shipped editor beside the main view.
@MainActor
final class RoundsTimelineRenderTests: XCTestCase {
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")
    private let grok = ModelChoice(agent: .grok, model: "grok-4.7", effort: "high")
    private let gemini = ModelChoice(agent: .gemini, model: "gemini-3.1-pro-high", effort: "high")

    private func dir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_TIMELINE_RENDER_DIR"] else {
            throw XCTSkip("set FD_TIMELINE_RENDER_DIR to render the rounds timeline PNGs")
        }
        return URL(fileURLWithPath: dir)
    }

    private static let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]

    var config: RoundConfig {
        RoundConfig(drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist)],
                    synthesizer: Slot(claude), reviewer: Slot(grok), integrator: claude, encoder: codex, polisher: gemini,
                    refinementCap: 3, polishCap: 2, freshEyesAndDedup: false, defaultPlay: .nextMajor, customized: false,
                    crossReviewer: Slot(gemini), crossCheck: .firstAndLast)
    }

    var available: AvailableModels {
        AvailableModels(choices: [.codex: codex, .claude: claude, .grok: grok, .gemini: gemini])
    }

    /// Draft, synthesis and refine 1 on the tape; refine 2 running.
    var tape: Tape {
        let ran = { (role: String, used: ModelChoice) in SlotOutcome(role: role, used: used, requested: used, status: .ok) }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        var tape = Tape(checkpoints: [
            Checkpoint(id: 1, stage: .draft, round: 0, major: true, createdAt: t0.addingTimeInterval(900),
                       record: RoundRecord(slots: [ran("drafter", codex), ran("drafter", claude)])),
            Checkpoint(id: 2, parent: 1, stage: .synthesis, round: 0, major: true, createdAt: t0.addingTimeInterval(1400),
                       record: RoundRecord(slots: [ran("synthesizer", claude), ran("integrator", claude)], changeCount: 14,
                                           linesAdded: 42, linesRemoved: 17), startedAt: t0.addingTimeInterval(920)),
            Checkpoint(id: 3, parent: 2, stage: .refine, round: 1, major: false, createdAt: t0.addingTimeInterval(2100),
                       record: RoundRecord(slots: [ran("reviewer", grok), ran("crossReviewer", gemini), ran("integrator", claude)],
                                           changeCount: 22, linesAdded: 310, linesRemoved: 96,
                                           tally: VerdictTally(agree: 18, somewhat: 3, disagree: 1)),
                       startedAt: t0.addingTimeInterval(1410)),
        ], target: .nextMajor, status: .running)
        tape.roundInProgress = PlannedRound(stage: .refine, round: 2, major: false)
        return tape
    }

    private var rows: [RoundTimeline.Row] { RoundTimeline.rows(config: config, tape: tape) }
    private let selected = RoundKey(stage: .refine, round: 2)

    // MARK: - Options

    enum Option: String, CaseIterable {
        /// Each stage a row: its name in a leading column, its chips flowing beside it; the
        /// selected stage's pickers in an inset box under the row.
        case a = "A-label-column"
        /// Each stage a section: the inspector's uppercase heading, the chips under it, the
        /// selected stage's pickers directly beneath, the other stages collapsed to their chips.
        case b = "B-section-strips"
        /// A vertical rail: a node per stage on a line down the leading edge, the stage name and
        /// chips beside it, the selected stage's pickers indented under its node.
        case c = "C-vertical-rail"
    }

    func testRenderOptions() throws {
        let out = try dir().appendingPathComponent("options")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for option in Option.allCases {
            for (appearance, tag) in Self.appearances {
                try PlanningRender.write(optionColumn(option), size: NSSize(width: 420, height: 900),
                                         to: out.appendingPathComponent("option-\(option.rawValue)-\(tag).png"),
                                         appearance: appearance)
            }
        }
    }

    private func optionColumn(_ option: Option) -> some View {
        VStack(spacing: 0) {
            InspectorModeHeader(modes: [.notes, .rounds], mode: .rounds, select: { _ in })
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Text("Feature plan").font(.headline)
                switch option {
                case .a: optionA
                case .b: optionB
                case .c: optionC
                }
            }
            .padding(16)
            Spacer(minLength: 0)
        }
        .frame(width: 420)
    }

    private func chips(_ row: RoundTimeline.Row) -> some View {
        ChipFlow {
            ForEach(row.chips) { chip in RoundChip(model: chip, selected: chip.key == self.selected, action: {}) }
        }
    }

    private var optionA: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.section) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.section.title)
                            .font(.callout.weight(row.section == .refine ? .semibold : .regular))
                            .foregroundStyle(row.section == .refine ? .primary : .secondary)
                            .frame(width: 70, alignment: .leading)
                            .padding(.top, 3)
                        self.chips(row)
                    }
                    if row.section == .refine {
                        self.pickers(row.section)
                            .padding(10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
                    }
                }
                if row.section != self.rows.last?.section { Divider() }
            }
        }
    }

    private var optionB: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(rows, id: \.section) { row in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: row.section == .refine ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        Text(row.section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5).offset(y: 4) }
                    self.chips(row)
                    if row.section == .refine { self.pickers(row.section) }
                }
            }
        }
    }

    private var optionC: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.section) { index, row in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        self.node(row)
                        if index < self.rows.count - 1 {
                            Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 1.5).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 14)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.section.title).font(.callout.weight(.semibold))
                        self.chips(row)
                        if row.section == .refine { self.pickers(row.section).padding(.top, 4) }
                    }
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private func node(_ row: RoundTimeline.Row) -> some View {
        let done = !row.chips.isEmpty && row.chips.allSatisfy { $0.progress == .done }
        let live = row.chips.contains { $0.progress == .live }
        return Circle()
            .fill(live ? Color.green : done ? Color.secondary : Color.clear)
            .overlay(Circle().strokeBorder(live ? Color.green : Color.secondary, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .padding(.top, 4)
    }

    /// A stand-in for a stage's pickers: the caption, then one row per role.
    private func pickers(_ section: RoundsSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(RoundTimeline.caption(section)).font(.caption).foregroundStyle(.secondary)
            ForEach([("Reviewer", grok), ("Cross-check agent", gemini), ("Integrator", claude)], id: \.0) { role, choice in
                VStack(alignment: .leading, spacing: 4) {
                    Text(role).font(.callout.weight(.semibold))
                    HStack(spacing: 8) {
                        AgentBadge(agent: choice.agent, size: 18)
                        Picker("", selection: .constant(choice.agent)) { Text(choice.agent.rawValue).tag(choice.agent) }
                            .labelsHidden().fixedSize()
                        TextField("Model", text: .constant(choice.model)).textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Cross-check").foregroundStyle(.secondary)
                Picker("", selection: .constant(CrossCheckPolicy.firstAndLast)) {
                    Text("First and last").tag(CrossCheckPolicy.firstAndLast)
                }.labelsHidden().fixedSize()
                Spacer()
                Text("Rounds").foregroundStyle(.secondary)
                Stepper("3", value: .constant(3))
            }
            .font(.callout)
        }
    }

    // MARK: - Final

    /// The shipped editor beside the main view it corresponds to: the same round picked on both
    /// sides — a finished one (Refine 1, the card highlighted) and the running one (Refine 2).
    func testRenderFinal() throws {
        let out = try dir()
        let picks: [(String, RoundKey)] = [("done", RoundKey(stage: .refine, round: 1)), ("live", RoundKey(stage: .refine, round: 2))]
        for (name, key) in picks {
            for (appearance, tag) in Self.appearances {
                try PlanningRender.write(sideBySide(picked: key), size: NSSize(width: 1240, height: 1000),
                                         to: out.appendingPathComponent("final-\(name)-picked-\(tag).png"), appearance: appearance)
            }
        }
        for (appearance, tag) in Self.appearances {
            var sketch = config
            sketch.synthesizer = nil
            sketch.polisher = nil
            sketch.refinementCap = 2
            sketch.crossCheck = .every
            try PlanningRender.write(editor(sketch, tape: nil, picked: nil), size: NSSize(width: 420, height: 760),
                                     to: out.appendingPathComponent("final-before-shaping-\(tag).png"), appearance: appearance)
        }
    }

    private func sideBySide(picked: RoundKey) -> some View {
        var intake = Intake(projectPath: "/tmp/project", intent: "Scheduling platform for field technicians")
        intake.state = .shaping
        intake.roundConfig = config
        let tape = tape
        let checkpoint = tape.checkpoints.first { RoundKey(stage: $0.stage, round: $0.round) == picked }?.id
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MAIN VIEW").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                LiveCard.shaping(intake: intake, tape: tape, activities: [:], records: [:], pending: nil,
                                 selectedRound: .constant(checkpoint == tape.head?.id ? nil : checkpoint),
                                 showConfig: { _ in }, pickedRound: picked,
                                 controlBar: { _ in AnyView(EmptyView()) }, board: { _ in AnyView(EmptyView()) })
            }
            .padding(20)
            .frame(width: 820, alignment: .topLeading)
            editor(config, tape: tape, picked: picked)
                .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
        }
    }

    private func editor(_ config: RoundConfig, tape: Tape?, picked: RoundKey?) -> some View {
        VStack(spacing: 0) {
            InspectorModeHeader(modes: [.notes, .rounds], mode: .rounds, select: { _ in })
            Divider()
            RoundConfigEditor(preset: .featurePlan, config: .constant(config), available: available, tape: tape,
                              selection: .constant(picked.map(RoundTimeline.Selection.round)))
                .padding(16)
            Spacer(minLength: 0)
        }
        .frame(width: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
