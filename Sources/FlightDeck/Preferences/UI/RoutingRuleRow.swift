import IntakeKit
import SwiftUI

/// What has keyboard focus in the Routing pane. Rows are focusable so the list navigates with
/// the arrow keys, Return edits and ⌫ deletes, the way a table does, while keeping the grouped
/// Settings look a `List` cannot draw on macOS.
enum RoutingFocus: Hashable {
    case rule(String)
    case sentence(String)
    case newRule(RuleScope)
}

/// One rule in the Routing pane (spec L3-R §2): the sentence on line 1, the compiled form as
/// pills (or a failure, or a spinner) on line 2, and exactly one trailing status. Every edit is a
/// popover off a pill; the sentence itself is edited inline on double-click or Return.
struct RoutingRuleRow: View {
    @ObservedObject var routing: RoutingService
    let rule: RoutingRule
    let scope: RuleScope
    let presentation: RuleRowPresentation
    let hint: RuleHint?
    let isSelected: Bool
    let isFirst: Bool
    let isLast: Bool
    var focus: FocusState<RoutingFocus?>.Binding
    @Binding var editing: String?
    let select: () -> Void
    let delete: () -> Void
    let move: (MoveCommandDirection) -> Void

    @State private var draft = ""
    @State private var open: Popover?

    enum Popover: Hashable {
        case condition(Int)
        case newCondition
        case target
        case hint
    }

    private var isEditing: Bool { editing == rule.id }
    private var isFocused: Bool { focus.wrappedValue == .rule(rule.id) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                sentenceLine
                detailLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(selectionBackground)
        // Simultaneous, so a click selects at once instead of waiting out the double-click
        // interval the sentence's own double-click gesture would otherwise impose.
        .simultaneousGesture(TapGesture().onEnded { select() })
        .focusable(!isEditing)
        .focused(focus, equals: .rule(rule.id))
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard isFocused else { return .ignored }
            beginEdit()
            return .handled
        }
        .onDeleteCommand { if isFocused { delete() } }
        .onMoveCommand { if isFocused { move($0) } }
        .contextMenu { menu }
        .onChange(of: editing) { _, now in
            if now == rule.id { draft = rule.sentence; focus.wrappedValue = .sentence(rule.id) }
        }
    }

    // MARK: - Line 1

    @ViewBuilder
    private var sentenceLine: some View {
        if isEditing {
            TextField("Rule", text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused(focus, equals: .sentence(rule.id))
                .onSubmit(commitEdit)
                .onExitCommand(perform: endEdit)
                .accessibilityLabel("Rule sentence")
                .accessibilityIdentifier("routing-sentence-field-\(rule.id)")
                .onChange(of: focus.wrappedValue) { _, now in
                    // Clicking away cancels rather than commits: committing recompiles, which
                    // would quietly take a live rule out of routing until it is Used again.
                    if now != .sentence(rule.id), isEditing { editing = nil }
                }
        } else {
            HStack(spacing: 6) {
                Text(rule.sentence)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(rule.sentence)
                    .accessibilityIdentifier("routing-sentence-\(rule.id)")
                    .onTapGesture(count: 2, perform: beginEdit)
                if presentation.adjusted {
                    Text("Edited")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .help("Adjusted by hand: the pills no longer match the sentence word for word. Reword the rule, or choose Recompile from Sentence, to match them again.")
                        .accessibilityIdentifier("routing-adjusted-\(rule.id)")
                }
            }
        }
    }

    // MARK: - Line 2

    @ViewBuilder
    private var detailLine: some View {
        switch presentation.status {
        case .live, .awaitingUse:
            pills
        case .compiling:
            // Words only: the trailing status is already the spinner, and two spinners on one
            // row read as two things happening.
            Text("Compiling…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .failed:
            Text(presentation.detail ?? "")
                .font(.subheadline)
                .foregroundStyle(.red)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("routing-failure-\(rule.id)")
        case .draft:
            Text(presentation.detail ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .accessibilityIdentifier("routing-note-\(rule.id)")
        }
    }

    /// Wraps like tokens instead of truncating: in the real Settings window a middle-truncated
    /// "test-a…ng ≥ 0.5" hid which dimension a condition was on. Each joiner travels with the pill
    /// after it, and the arrow with the target, so a wrap never strands an "or" or a "→".
    private var pills: some View {
        PillFlow(spacing: 4, lineSpacing: 5) {
            ForEach(presentation.conditions, id: \.index) { c in
                HStack(spacing: 4) {
                    if c.index > 0 {
                        Text(presentation.joiner).font(.caption).foregroundStyle(.tertiary)
                    }
                    Button(c.text) { open = .condition(c.index) }
                        .buttonStyle(PillStyle())
                        .focusEffectDisabled()
                        .accessibilityLabel(c.accessibilityLabel)
                        .accessibilityHint("Opens a popover to change this condition")
                        .accessibilityIdentifier("routing-condition-\(rule.id)-\(c.index)")
                        .popover(isPresented: binding(.condition(c.index)), arrowEdge: .bottom) {
                            conditionEditor(index: c.index)
                        }
                }
            }
            Button { open = .newCondition } label: { Image(systemName: "plus") }
                .buttonStyle(PillStyle(compact: true, dashed: true))
                .focusEffectDisabled()
                .help("Add a condition")
                .accessibilityLabel("Add condition")
                .accessibilityIdentifier("routing-add-condition-\(rule.id)")
                .popover(isPresented: binding(.newCondition), arrowEdge: .bottom) { conditionEditor(index: nil) }
            if let target = presentation.target, let assign = rule.compiled?.assign {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Button(target) { open = .target }
                        .buttonStyle(PillStyle(prominent: true))
                        .focusEffectDisabled()
                        .accessibilityLabel(presentation.targetAccessibility ?? target)
                        .accessibilityHint("Opens a popover to change the agent, model, effort and accounts")
                        .accessibilityIdentifier("routing-target-\(rule.id)")
                        .popover(isPresented: binding(.target), arrowEdge: .bottom) {
                            RoutingTargetEditor(routing: routing, ruleID: rule.id, scope: scope, assign: assign)
                        }
                }
            }
        }
        .help(presentation.tooltip ?? "")
    }

    private func conditionEditor(index: Int?) -> some View {
        RoutingConditionEditor(routing: routing, ruleID: rule.id, scope: scope, match: rule.compiled?.match ?? .any([]),
                               index: index, close: { open = nil })
    }

    // MARK: - Trailing status

    private var trailing: some View {
        HStack(spacing: 10) {
            if let hint {
                Button { open = .hint } label: {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                }
                .buttonStyle(.plain)
                .help("A better-scoring model exists")
                .accessibilityLabel("Suggestion: \(hint.text)")
                .accessibilityIdentifier("routing-hint-\(rule.id)")
                .popover(isPresented: binding(.hint), arrowEdge: .bottom) {
                    RoutingHintPopover(routing: routing, hint: hint, scope: scope, close: { open = nil })
                }
            }
            status
        }
        .frame(minWidth: 44, alignment: .trailing)
    }

    @ViewBuilder
    private var status: some View {
        switch presentation.status {
        case .live:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("Live: this rule routes tasks")
                .accessibilityLabel(presentation.statusAccessibility)
                .accessibilityIdentifier("routing-status-\(rule.id)")
        case .awaitingUse:
            Button("Use") { routing.confirm(rule.id, in: scope) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Compiled, but not routing yet. Check the pills, then Use it.")
                .accessibilityLabel(presentation.statusAccessibility)
                .accessibilityIdentifier("routing-use-\(rule.id)")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(presentation.detail ?? "Failed")
                .accessibilityLabel(presentation.statusAccessibility)
                .accessibilityIdentifier("routing-status-\(rule.id)")
        case .compiling:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(presentation.statusAccessibility)
                .accessibilityIdentifier("routing-status-\(rule.id)")
        case .draft:
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
                .help(presentation.detail ?? "Not compiled")
                .accessibilityLabel(presentation.statusAccessibility)
                .accessibilityIdentifier("routing-status-\(rule.id)")
        }
    }

    // MARK: - Selection, menu, editing

    private var selectionBackground: some View {
        // Inset rounded selection, like a sidebar's, drawn into the grouped row's padding so the
        // row's own content never moves when it is selected.
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(isFocused ? 0.16 : 0.08) : .clear)
            .padding(.horizontal, -8)
            .padding(.vertical, -4)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Use") { routing.confirm(rule.id, in: scope) }
            .disabled(!presentation.canUse)
        Button("Edit Sentence", action: beginEdit)
        if presentation.adjusted {
            Button("Recompile from Sentence") { routing.revertToSentence(rule.id, in: scope) }
        }
        Divider()
        Button("Move Up") { routing.moveRule(rule.id, by: -1, in: scope) }
            .disabled(isFirst)
        Button("Move Down") { routing.moveRule(rule.id, by: 1, in: scope) }
            .disabled(isLast)
        Divider()
        Button("Delete", role: .destructive, action: delete)
    }

    private func binding(_ p: Popover) -> Binding<Bool> {
        Binding(get: { open == p }, set: { if !$0, open == p { open = nil } })
    }

    private func beginEdit() {
        select()
        editing = rule.id
    }

    private func commitEdit() {
        routing.reword(rule.id, draft, in: scope)
        endEdit()
    }

    private func endEdit() {
        editing = nil
        focus.wrappedValue = .rule(rule.id)
    }
}

/// A capsule button for one part of a compiled rule. Conditions are neutral; the target is
/// accent-tinted so the eye finds where the rule sends work.
struct PillStyle: ButtonStyle {
    var prominent = false
    var compact = false
    @State private var hovering = false

    var dashed = false

    func makeBody(configuration: Configuration) -> some View {
        let tint: Color = prominent ? .accentColor : .primary
        configuration.label
            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 2)
            .frame(minHeight: 20)
            .foregroundStyle(prominent ? AnyShapeStyle(Color.accentColor)
                             : compact ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.85)))
            // A rounded rect just under half the pill's height, not a `Capsule`: SwiftUI strokes
            // a thin capsule border with a stray vertical sliver at each end (seen in renders and
            // reproduced in isolation); this shape reads as a capsule and strokes cleanly.
            .background {
                ZStack {
                    Self.shape
                        .fill(tint.opacity(dashed ? (hovering ? 0.06 : 0) : fillOpacity(pressed: configuration.isPressed)))
                    Self.shape
                        .strokeBorder(tint.opacity(prominent ? 0.4 : dashed ? 0.25 : 0.12),
                                      style: StrokeStyle(lineWidth: dashed ? 0.75 : 0.5, dash: dashed ? [2.5, 2] : []))
                }
            }
            .contentShape(Self.shape)
            .onHover { hovering = $0 }
    }

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 9) }

    private func fillOpacity(pressed: Bool) -> Double {
        let base = prominent ? 0.16 : 0.06
        if pressed { return base + 0.12 }
        return hovering ? base + 0.06 : base
    }
}

/// Lays its children out left to right and wraps to a new line when the next one would not fit,
/// each line's items centred on one another.
struct PillFlow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(width: bounds.width, subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var line: [Int] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0

        func finishLine() {
            // Centre each item on its line: the joiner text is shorter than a pill.
            for i in line { frames[i].origin.y = y + (lineHeight - frames[i].height) / 2 }
            y += lineHeight
            line = []
        }

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                finishLine()
                y += lineSpacing
                x = 0
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            line.append(frames.count - 1)
            widest = max(widest, x + size.width)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        finishLine()
        return (frames, CGSize(width: widest, height: y))
    }
}
