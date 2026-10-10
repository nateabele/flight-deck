import IntakeKit
import SwiftUI

/// One round as a capsule: its progress mark, its name ("Refine 2"), a cross-check mark, and the
/// stack of agents that run it. Drawn from a `RoundChipModel` on BOTH sides of the planning view
/// — the Rounds inspector's timeline and the main view's round cards and live header — so a
/// round looks the same wherever it appears, and picking it on one side can be seen on the other.
///
/// With `action`, a button: the main view's chips open the round in the inspector, the
/// inspector's reveal its stage's pickers and show the round in the main view.
struct RoundChip: View {
    let model: RoundChipModel
    var selected = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
        } else {
            chip
        }
    }

    static let agentSize: CGFloat = 14

    private var chip: some View {
        HStack(spacing: 5) {
            progressMark
            Text(model.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(model.progress == .planned && !selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .fixedSize()
            if model.crossCheck {
                Image(systemName: Self.crossCheckSymbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if !model.agents.isEmpty {
                AgentStack(entries: model.agents, size: Self.agentSize)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, model.agents.isEmpty ? 8 : 5)
        .frame(height: Self.agentSize + 8)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(stroke, style: strokeStyle))
        .contentShape(Capsule())
        .help(model.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel)
        .accessibilityValue(AgentStackModel.accessibilityLabel(model.agents))
        .accessibilityIdentifier("round-chip-\(model.key.stage.rawValue)-\(model.key.round)")
    }

    /// Two reviewers from two families: the mark a cross-check round carries beside its name.
    static let crossCheckSymbol = "person.2.fill"

    @ViewBuilder
    private var progressMark: some View {
        switch model.progress {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .live:
            Circle().fill(Color.green).frame(width: 7, height: 7)
                .padding(.horizontal, 1.5)
        case .planned:
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: 8, height: 8)
                .padding(.horizontal, 1)
        }
    }

    private var fill: Color {
        if selected { return Color.accentColor.opacity(0.2) }
        switch model.progress {
        case .done: return Color.primary.opacity(0.07)
        case .live: return Color.green.opacity(0.13)
        case .planned: return .clear
        }
    }

    private var stroke: Color {
        if selected { return .accentColor }
        switch model.progress {
        case .done: return Color.primary.opacity(0.08)
        case .live: return Color.green.opacity(0.55)
        case .planned: return Color.primary.opacity(0.22)
        }
    }

    /// A round still to run is outlined in dashes — planned, not yet a thing that happened.
    private var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: model.progress == .planned && !selected ? [3, 2] : [])
    }
}

/// Lays its children out left to right, wrapping to a new line when the next one would pass the
/// proposed width — a stage's strip of chips in an inspector column that may be 300 pt wide.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, added > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
