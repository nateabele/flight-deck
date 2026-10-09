import IntakeKit
import SwiftUI

/// One agent doing one role in a round: what a round's avatar stack is drawn from and what its
/// tooltip lists. `role` is the engine's raw role ("crossReviewer"), read through `UIText.roleName`.
struct RoundAgent: Equatable {
    var role: String
    var choice: ModelChoice
}

/// The Rounds inspector's sections, one per kind of round the tape runs — where clicking a round's
/// stack in the main view scrolls to. Polish, fresh eyes and dedup are one section: all three run
/// on the polisher, and the editor has one row for it.
enum RoundsSection: String, CaseIterable {
    case draft, synthesis, refine, encode, polish

    static func of(_ stage: Stage) -> RoundsSection {
        switch stage {
        case .draft: .draft
        case .synthesis: .synthesis
        case .refine: .refine
        case .encode: .encode
        case .polish, .freshEyes, .dedup: .polish
        }
    }

    /// The board's own stage words, so a section heading names the rounds it configures the way
    /// the tape and the round cards do.
    var title: String {
        switch self {
        case .draft: "Draft"
        case .synthesis: "Synthesis"
        case .refine: "Refine"
        case .encode: "Encode"
        case .polish: "Polish"
        }
    }

    /// The scroll anchor of the section's heading inside the inspector.
    var anchor: String { "rounds-section-\(rawValue)" }
}

/// Which agents a round's stack shows — pure, so `AgentStackModelTests` pins it. Every stack in
/// the planning UI is built here: a round card (what ran), the live round's header and a section
/// heading in the Rounds inspector (what is configured). One derivation is what makes a round in
/// the main view match its config beside it; two would drift the first time either changed.
enum AgentStackModel {
    /// Bubbles before the stack collapses the rest into "+N" — a stack wider than three reads as
    /// a row of chips, not a group.
    static let limit = 3

    /// The seats `stage` will start under `config`, in run order — read off `LiveSeats.expected`,
    /// the list the live card's seat rows come from, so the stack can't name a seat the rows
    /// don't. A seat with no slot (Sketch's polisher) is left out rather than drawn blank.
    static func planned(stage: Stage, crossCheck: Bool, config: RoundConfig) -> [RoundAgent] {
        LiveSeats.expected(PlannedRound(stage: stage, round: 0, major: false, crossCheck: crossCheck), config: config)
            .compactMap { seat in
                // `<stage>-<round>-<role>[-<index>]`: no stage's raw value has a dash.
                let parts = seat.base.split(separator: "-")
                guard parts.count >= 3, let slot = seat.requested else { return nil }
                return RoundAgent(role: String(parts[2]), choice: slot.choice)
            }
    }

    /// Who actually ran a finished round — a fallback's model, not the one asked for.
    static func ran(_ record: RoundRecord) -> [RoundAgent] {
        record.slots.map { RoundAgent(role: $0.role, choice: $0.used) }
    }

    /// Every agent `section`'s rounds can run: the union of its stages' seats, a cross-check
    /// round's included whenever the policy can seat one — so any one round's stack in the main
    /// view is a subset of its section's in the inspector.
    static func section(_ section: RoundsSection, config: RoundConfig) -> [RoundAgent] {
        switch section {
        case .draft: planned(stage: .draft, crossCheck: false, config: config)
        case .synthesis: config.synthesizer == nil ? [] : planned(stage: .synthesis, crossCheck: false, config: config)
        case .refine:
            // The integrator is listed even with no reviewer seated: its row lives in this section.
            (config.reviewer.map { [RoundAgent(role: "reviewer", choice: $0.choice)] } ?? [])
                + (config.crossCheck.map { $0 != .off } == true
                    ? config.crossReviewer.map { [RoundAgent(role: "crossReviewer", choice: $0.choice)] } ?? [] : [])
                + [RoundAgent(role: "integrator", choice: config.integrator)]
        case .encode: planned(stage: .encode, crossCheck: false, config: config)
        case .polish: planned(stage: .polish, crossCheck: false, config: config)
        }
    }

    /// The distinct agents, in the order they first appear — run order, so a stack doesn't
    /// reshuffle between a round's card and its section heading.
    static func agents(_ entries: [RoundAgent]) -> [AgentID] {
        var out: [AgentID] = []
        for entry in entries where !out.contains(entry.choice.agent) { out.append(entry.choice.agent) }
        return out
    }

    static func layout(_ agents: [AgentID], limit: Int = limit) -> (shown: [AgentID], overflow: Int) {
        (Array(agents.prefix(limit)), max(0, agents.count - limit))
    }

    static func overflowText(_ n: Int) -> String { "+\(n)" }

    /// "Reviewer: Grok grok-4.7", a line per role — the stack's tooltip, the one place it says
    /// which model each bubble stands for.
    static func help(_ entries: [RoundAgent]) -> String {
        entries.map { "\(UIText.sentenceCase(UIText.roleName($0.role))): \($0.choice.agent.displayName) \($0.choice.model)" }
            .joined(separator: "\n")
    }

    /// "Agents: Grok, Gemini, Claude" — every agent, the overflow included.
    static func accessibilityLabel(_ entries: [RoundAgent]) -> String {
        "Agents: " + agents(entries).map(\.displayName).joined(separator: ", ")
    }
}

// MARK: - Glyph

extension AgentID {
    /// The agent's monogram in its glyph. Two letters, because one can't tell Claude from Codex,
    /// and never a vendor's logo or mark: the repo is public, and a trademark in it is a
    /// liability for no gain a tint and two letters don't already give.
    var monogram: String {
        switch self {
        case .claude: "Cl"
        case .codex: "Cx"
        case .grok: "Gk"
        case .gemini: "Gm"
        case .opencode: "Oc"
        }
    }

    /// The glyph's tint: a system colour, so it follows the appearance and the accessibility
    /// contrast setting, and no vendor's brand colour.
    var tint: Color {
        switch self {
        case .claude: .orange
        case .codex: .teal
        case .grok: .purple
        case .gemini: .blue
        case .opencode: .green
        }
    }
}

/// One agent as a small tinted disc with its monogram — defined once and used wherever an agent
/// is shown beside a round: the stacks, the Rounds editor's pickers, a finished round's seat list.
struct AgentBadge: View {
    let agent: AgentID
    var size: CGFloat = 16

    var body: some View {
        Circle()
            .fill(agent.tint.gradient)
            .overlay(
                Text(agent.monogram)
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            )
            .frame(width: size, height: size)
            .accessibilityLabel(agent.displayName)
    }
}

/// A round's distinct agents as overlapping glyphs, the Messages/Shared-with shape: each later
/// disc cut out of the one under it by a ring, so the stack reads on any background — a card's
/// tint, the selected card's accent, the inspector's material. Past `AgentStackModel.limit`, a
/// "+N" for the rest. The tooltip lists every role's agent and model.
///
/// With `action`, a button: the main view's stacks open the round's config in the inspector.
struct AgentStack: View {
    let entries: [RoundAgent]
    var size: CGFloat = 16
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { stack }
                .buttonStyle(.plain)
                .accessibilityHint("Shows these agents in the inspector")
        } else {
            stack
        }
    }

    private var stack: some View {
        let (shown, overflow) = AgentStackModel.layout(AgentStackModel.agents(entries))
        // Shallow on purpose: a two-letter monogram spans most of its disc, and at a quarter's
        // overlap the next disc cut the second letter off ("Gk" read as "G").
        let overlap = size * 0.15
        return HStack(spacing: -overlap) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, agent in
                // Notched where the next item sits on it, so the overlap reads as a gap: a ring
                // in the background colour would be wrong on every background but one.
                AgentBadge(agent: agent, size: size)
                    .clipShape(StackNotch(overlap: overlap, cut: index < shown.count - 1 || overflow > 0),
                               style: FillStyle(eoFill: true))
            }
            if overflow > 0 {
                Text(AgentStackModel.overflowText(overflow))
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: size * 1.35, height: size)
                    .background(Capsule().fill(Color.primary.opacity(0.12)))
            }
        }
        .contentShape(Rectangle())
        .help(AgentStackModel.help(entries))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AgentStackModel.accessibilityLabel(entries))
        .accessibilityAddTraits(action == nil ? [] : .isButton)
        .accessibilityIdentifier("agent-stack")
    }
}

/// A stack item's clip: its whole frame less a disc where the next item overlaps it, one ring
/// wider than that item. Even-odd, so the disc is subtracted; the part of it past the frame's
/// edge clips nothing, because nothing is drawn there. A path clip rather than a
/// `.destinationOut` cut-out: the offscreen renders the design is reviewed from (`layer.render`)
/// drop blend modes, and drew the stack with no gaps at all.
private struct StackNotch: Shape {
    let overlap: CGFloat
    let cut: Bool
    var ring: CGFloat = 1.2

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        guard cut else { return path }
        let r = rect.height / 2 + ring
        let center = CGPoint(x: rect.maxX - overlap + rect.height / 2, y: rect.midY)
        path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        return path
    }
}
