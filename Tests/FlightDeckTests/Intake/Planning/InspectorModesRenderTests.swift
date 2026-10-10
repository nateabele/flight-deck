import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// The inspector's mode control and the agent stacks, offscreen, for design review — skipped
/// unless `FD_INSPECTOR_RENDER_DIR` names an output directory. `testRenderOptions` draws the
/// candidates the shipped design was picked from (`options/option-*.png`); `testRenderFinal`
/// draws the shipped views: the Rounds mode with its section stacks, the Notes mode's empty
/// state, a single task's header, the agent drill-in, and the finished-round cards with theirs.
@MainActor
final class InspectorModesRenderTests: XCTestCase {
    private let codex = ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")
    private let claude = ModelChoice(agent: .claude, model: "opus", effort: "high")
    private let grok = ModelChoice(agent: .grok, model: "grok-4.7", effort: "high")
    private let gemini = ModelChoice(agent: .gemini, model: "gemini-3.1-pro-high", effort: "high")

    private func dir() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_INSPECTOR_RENDER_DIR"] else {
            throw XCTSkip("set FD_INSPECTOR_RENDER_DIR to render the inspector-mode PNGs")
        }
        return URL(fileURLWithPath: dir)
    }

    private static let appearances: [(NSAppearance.Name, String)] = [(.aqua, "light"), (.darkAqua, "dark")]

    private var fourWay: RoundConfig {
        RoundConfig(drafters: [Slot(codex, persona: .arbiter), Slot(claude, persona: .realist)],
                    synthesizer: Slot(claude), reviewer: Slot(grok), integrator: claude, encoder: codex, polisher: gemini,
                    refinementCap: 3, polishCap: 2, freshEyesAndDedup: false, defaultPlay: .nextMajor, customized: false,
                    crossReviewer: Slot(gemini), crossCheck: .firstAndLast)
    }

    private var fourWayAvailable: AvailableModels {
        AvailableModels(choices: [.codex: codex, .claude: claude, .grok: grok, .gemini: gemini])
    }

    // MARK: - Options

    func testRenderOptions() throws {
        let out = try dir().appendingPathComponent("options")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for option in Option.allCases {
            for (appearance, tag) in Self.appearances {
                try PlanningRender.write(optionBoard(option).padding(20), size: NSSize(width: 820, height: 470),
                                         to: out.appendingPathComponent("option-\(option.rawValue)-\(tag).png"),
                                         appearance: appearance)
            }
        }
    }

    enum Option: String, CaseIterable {
        /// Keynote/Pages: a text-only segmented control; filled tinted discs with white monograms.
        case a = "A-text-segments-filled-monograms"
        /// Icon-and-text segments; pale discs with tinted monograms.
        case b = "B-icon-text-segments-soft-monograms"
        /// Xcode: an icon-only tab strip; filled discs carrying an SF Symbol per agent.
        case c = "C-icon-tabs-symbol-discs"
    }

    private func optionBoard(_ option: Option) -> some View {
        let refine = AgentStackModel.planned(stage: .refine, crossCheck: true, config: fourWay)
        let draft = AgentStackModel.planned(stage: .draft, crossCheck: false, config: fourWay)
        let five = refine + [RoundAgent(role: "drafter", choice: codex),
                             RoundAgent(role: "drafter", choice: ModelChoice(agent: .opencode, model: "big-pickle", effort: ""))]
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("MAIN VIEW · ROUND CARDS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    mockCard("DRAFT", "Draft", draft, option)
                    mockCard("REFINE", "Refine 1", refine, option)
                }
                mockCard("REFINE", "Refine 2 · 5 agents", five, option)
                Text("LIVE ROUND HEADER").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).padding(.top, 8)
                HStack(spacing: 8) {
                    Text("REFINE 1").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    stack(refine, option, size: 15)
                    Text("1 of 3 agents done").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 400, alignment: .leading)
            VStack(spacing: 0) {
                optionHeader(option)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                    ForEach([RoundsSection.draft, .refine, .polish], id: \.self) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(section.title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                Spacer()
                                self.stack(AgentStackModel.section(section, config: self.fourWay), option, size: 18)
                            }
                            .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5).offset(y: 3) }
                            let first = AgentStackModel.section(section, config: self.fourWay)[0]
                            Text(UIText.sentenceCase(UIText.roleName(first.role))).font(.callout.weight(.semibold))
                            HStack(spacing: 8) {
                                self.badge(first.choice.agent, option, size: 18)
                                Picker("", selection: .constant(first.choice.agent)) {
                                    Text(first.choice.agent.rawValue).tag(first.choice.agent)
                                }
                                .labelsHidden().fixedSize()
                                TextField("Model", text: .constant(first.choice.model)).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .padding(14)
                Spacer(minLength: 0)
            }
            .frame(width: 340)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 1) }
        }
    }

    private func mockCard(_ stage: String, _ name: String, _ entries: [RoundAgent], _ option: Option) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(stage).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                Spacer()
                Text("4:12").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Text(name).font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 6)
                stack(entries, option, size: 15)
                FinishedRounds.statusSymbol(.ok)
            }
            HStack {
                Text("14 changes")
                Spacer()
                Text("+42/−17")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(width: 184, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private func optionHeader(_ option: Option) -> some View {
        switch option {
        case .a:
            InspectorModeHeader(modes: [.notes, .rounds], mode: .rounds, select: { _ in })
        case .b:
            Picker("Inspector", selection: .constant(DetailLayout.InspectorMode.rounds)) {
                ForEach(DetailLayout.InspectorMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .frame(maxWidth: .infinity).frame(height: 38)
        case .c:
            HStack(spacing: 18) {
                ForEach(DetailLayout.InspectorMode.allCases, id: \.self) { mode in
                    Image(systemName: mode == .rounds ? mode.symbol + ".fill" : mode.symbol)
                        .font(.system(size: 14))
                        .foregroundStyle(mode == .rounds ? Color.accentColor : .secondary)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 30)
        }
    }

    @ViewBuilder
    private func badge(_ agent: AgentID, _ option: Option, size: CGFloat) -> some View {
        switch option {
        case .a: AgentBadge(agent: agent, size: size)
        case .b:
            Circle().fill(agent.tint.opacity(0.22))
                .overlay(Text(agent.monogram).font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(agent.tint))
                .frame(width: size, height: size)
        case .c:
            Circle().fill(agent.tint.gradient)
                .overlay(Image(systemName: Self.symbol(agent)).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white))
                .frame(width: size, height: size)
        }
    }

    private static func symbol(_ agent: AgentID) -> String {
        switch agent {
        case .claude: "text.word.spacing"
        case .codex: "terminal"
        case .grok: "bolt"
        case .gemini: "diamond"
        case .opencode: "curlybraces"
        }
    }

    @ViewBuilder
    private func stack(_ entries: [RoundAgent], _ option: Option, size: CGFloat) -> some View {
        if option == .a {
            AgentStack(entries: entries, size: size)
        } else {
            let (shown, overflow) = AgentStackModel.layout(AgentStackModel.agents(entries))
            HStack(spacing: -size * 0.32) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, agent in
                    ZStack {
                        if index > 0 { Circle().frame(width: size + 3, height: size + 3).blendMode(.destinationOut) }
                        self.badge(agent, option, size: size)
                    }
                }
                if overflow > 0 {
                    Text("+\(overflow)").font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.leading, size * 0.4)
                }
            }
            .compositingGroup()
        }
    }

    // MARK: - Final

    func testRenderFinal() throws {
        let out = try dir()
        let roundsShaping = column {
            InspectorModeHeader(modes: [.notes, .rounds], mode: .rounds, select: { _ in })
            Divider()
            RoundConfigEditor(preset: .featurePlan, config: .constant(self.fourWay), available: self.fourWayAvailable,
                              highlight: .refine)
                .padding(16)
        }
        let notesEmpty = column {
            InspectorModeHeader(modes: [.notes, .rounds], mode: .notes, select: { _ in })
            Divider()
            InspectorPlaceholder(title: DetailLayout.Placeholder.notesBeforePlanning.title,
                                 message: DetailLayout.Placeholder.notesBeforePlanning.message)
                .padding(16)
        }
        let singleTask = column {
            InspectorModeHeader(modes: [.notes], mode: .notes, select: { _ in })
            Divider()
            InspectorPlaceholder(title: DetailLayout.Placeholder.notesSingleTask.title,
                                 message: DetailLayout.Placeholder.notesSingleTask.message)
                .padding(16)
        }
        for (appearance, tag) in Self.appearances {
            try PlanningRender.write(roundsShaping, size: NSSize(width: 420, height: 1080),
                                     to: out.appendingPathComponent("final-rounds-mode-\(tag).png"), appearance: appearance)
            try PlanningRender.write(notesEmpty, size: NSSize(width: 420, height: 260),
                                     to: out.appendingPathComponent("final-notes-empty-\(tag).png"), appearance: appearance)
            try PlanningRender.write(singleTask, size: NSSize(width: 420, height: 240),
                                     to: out.appendingPathComponent("final-single-task-\(tag).png"), appearance: appearance)
            try PlanningRender.write(cards().padding(20), size: NSSize(width: 1000, height: 260),
                                     to: out.appendingPathComponent("final-round-cards-\(tag).png"), appearance: appearance)
        }
    }

    private func column(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) { content() }
            .frame(width: 420, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The finished-round strip as `LiveCard.shaping` draws it, its cards carrying the stacks.
    private func cards() -> some View {
        var intake = Intake(projectPath: "/tmp/project", intent: "Scheduling platform for field technicians")
        intake.state = .shaping
        intake.roundConfig = fourWay
        let ran = { (role: String, used: ModelChoice) in SlotOutcome(role: role, used: used, requested: used, status: .ok) }
        let t0 = Date().addingTimeInterval(-20_000)
        let tape = Tape(checkpoints: [
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
            Checkpoint(id: 4, parent: 3, stage: .refine, round: 2, major: false, createdAt: t0.addingTimeInterval(2900),
                       record: RoundRecord(slots: [ran("reviewer", grok), ran("integrator", claude)], changeCount: 9,
                                           linesAdded: 40, linesRemoved: 12, tally: VerdictTally(agree: 8, somewhat: 1, disagree: 0)),
                       startedAt: t0.addingTimeInterval(2110)),
        ], target: .nextMajor, status: .paused)
        return LiveCard.shaping(intake: intake, tape: tape, activities: [:], records: [:], pending: nil,
                                showConfig: { _ in },
                                controlBar: { _ in AnyView(EmptyView()) }, board: { _ in AnyView(EmptyView()) })
    }
}
