import IntakeKit
import SwiftUI

/// What a collapsed Intakes list draws for one intake: the state pill reduced to a disc and a
/// glyph. The pill's colour (`IntakeStatePill.tint`) carries the meaning, the glyph tells two
/// states of one colour apart, and the states that want the human (`needsAttention`, all of
/// them orange) are a solid disc — the one thing a glance down the rail has to find.
/// Pure, so `IntakeRailTests` pins every state.
struct IntakeRailMark: Equatable {
    let symbol: String
    let tint: Color
    /// A solid disc with a white glyph, rather than the pill's tinted wash.
    let filled: Bool

    static func mark(for state: IntakeState) -> IntakeRailMark {
        IntakeRailMark(symbol: symbol(for: state), tint: IntakeStatePill.tint(for: state), filled: state.needsAttention)
    }

    private static func symbol(for state: IntakeState) -> String {
        switch state {
        case .triaging: "magnifyingglass"
        case .needsAnswers: "questionmark"
        case .awaitingChoice: "slider.horizontal.3"
        case .shaping: "arrow.triangle.2.circlepath"
        case .parked: "pause.fill"
        case .review: "eye.fill"
        case .releasing: "paperplane.fill"
        case .released: "checkmark"
        case .partiallyReleased: "circle.lefthalf.filled"
        case .failed: "xmark"
        case .interrupted: "exclamationmark"
        case .discarded: "trash"
        }
    }

    /// A rail row as VoiceOver reads it: the intake's title, then its state in the pill's words.
    static func accessibilityLabel(for intake: Intake, tape: Tape? = nil) -> String {
        "\(IntakeTitle(intent: intake.intent).title), \(IntakeStatePill.label(for: intake, tape: tape))"
    }
}

/// ↑/↓ through the rail's rows. Clamped at the ends, as a List is; with nothing selected (or a
/// selection the rail no longer lists) ↓ starts at the top and ↑ at the bottom.
enum IntakeRailNavigation {
    static func move(_ selection: UUID?, by step: Int, in ids: [UUID]) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current = selection.flatMap(ids.firstIndex(of:)) else { return step < 0 ? ids.last : ids.first }
        return ids[min(max(current + step, 0), ids.count - 1)]
    }
}

/// The state disc, shared by the rail's rows.
struct IntakeRailGlyph: View {
    let mark: IntakeRailMark
    static let diameter: CGFloat = 26

    var body: some View {
        Image(systemName: mark.symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(mark.filled ? AnyShapeStyle(.white) : AnyShapeStyle(mark.tint))
            .frame(width: Self.diameter, height: Self.diameter)
            .background(mark.filled ? mark.tint : mark.tint.opacity(0.16), in: Circle())
    }
}

/// The Intakes list collapsed to a rail (`IntakeService.intakeListCollapsed`): one disc per
/// intake, the selected one highlighted, a card with the whole title on hover or keyboard focus,
/// and a + at the foot that opens the composer in a popover. The expand toggle is not drawn
/// here: `ProjectView` rides one toggle on the column's trailing edge in both states, so it
/// slides with the edge rather than cross-fading between two copies — the rail leaves it
/// `headerHeight` at the top.
struct IntakeRail: View {
    static let width: CGFloat = 52
    static let headerHeight: CGFloat = 48

    let intakes: [Intake]
    let tapes: [UUID: Tape]
    @Binding var selection: UUID?
    @Binding var intent: String
    let onTriage: () -> Void

    @ObservedObject private var hover = HoverCardIntent.shared
    /// This rail's key in the app-wide hover intent, so two rails never open each other's card.
    @State private var hoverToken = UUID().uuidString
    @State private var hovered: UUID?
    @FocusState private var focusedRow: UUID?
    @State private var composing = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.headerHeight)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(intakes) { row($0) }
                }
                .padding(.vertical, 2)
            }
            Divider().padding(.horizontal, 12)
            newIntakeButton.padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }

    private func row(_ intake: Intake) -> some View {
        let selected = selection == intake.id
        let key = hoverToken + intake.id.uuidString
        return IntakeRailGlyph(mark: .mark(for: intake.state))
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.12 : hovered == intake.id ? 0.06 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.9 : 0), lineWidth: 1.5)
            )
            .frame(width: Self.width)
            .contentShape(Rectangle())
            .background(FloatingCard(isPresented: hover.shown == key || focusedRow == intake.id,
                                     card: IntakeRailCard(intake: intake, tape: tapes[intake.id]),
                                     side: .trailing, onDismiss: { hover.dismiss() }))
            .onHover { inside in
                hovered = inside ? intake.id : (hovered == intake.id ? nil : hovered)
                hover.hover(key, inside)
            }
            .onTapGesture { selection = intake.id }
            // Keyboard access (spec §14), as the tape's slots and seat rows have it: Tab reaches
            // the row under Full Keyboard Access, focus opens its card as hover does, Return or
            // Space selects, and ↑/↓ walk the selection (and focus) as they do in the list.
            .focusable(interactions: .activate)
            .focused($focusedRow, equals: intake.id)
            .onKeyPress(keys: [.return, .space]) { _ in
                selection = intake.id
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let next = IntakeRailNavigation.move(selection ?? intake.id, by: press.key == .upArrow ? -1 : 1,
                                                     in: intakes.map(\.id))
                selection = next
                focusedRow = next
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(IntakeRailMark.accessibilityLabel(for: intake, tape: tapes[intake.id]))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection = intake.id }
            .accessibilityIdentifier("intake-rail-row")
    }

    private var newIntakeButton: some View {
        Button { composing = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("New intake")
        .accessibilityLabel("New Intake")
        .accessibilityIdentifier("intake-rail-new")
        .popover(isPresented: $composing, arrowEdge: .trailing) {
            IntakeComposer(intent: $intent, onTriage: {
                onTriage()
                composing = false
            }, onCancel: { composing = false })
            .frame(width: 340)
            .padding(14)
        }
    }
}

/// The rail row's hover card: the pill and the request as the list row words it, uncut past
/// five lines. The system's own card look (window material, hairline, soft shadow) rather than
/// the board's phosphor glass — the rail is ordinary list chrome, not the instrument panel.
struct IntakeRailCard: View {
    let intake: Intake
    var tape: Tape? = nil

    var body: some View {
        let title = IntakeTitle(intent: intake.intent)
        VStack(alignment: .leading, spacing: 7) {
            IntakeStatePill(intake: intake, tape: tape)
            (Text(title.lead).fontWeight(.semibold)
                + Text(title.rest.isEmpty ? "" : " " + title.rest).foregroundStyle(.secondary))
                .font(.system(size: 12.5))
                .lineLimit(5)
                .truncationMode(.tail)
                .frame(width: 264, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 14, y: 7)
    }
}

/// "Describe what you want…" and Triage: at the foot of the expanded list, and in the rail's +
/// popover, where Cancel (Esc) closes it. One draft (`intent`) behind both, so collapsing the
/// list mid-sentence keeps what was typed.
struct IntakeComposer: View {
    @Binding var intent: String
    let onTriage: () -> Void
    /// Set in the popover: adds Cancel, bound to Esc — a focused text view takes Esc as
    /// completion rather than passing it on, so the popover's own Esc never came.
    var onCancel: (() -> Void)? = nil

    @FocusState private var editing: Bool

    private var empty: Bool { intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe what you want…").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $intent)
                .font(.body)
                // In the popover a set height: a TextEditor takes all it is offered, and the
                // popover offered its whole maximum, a tall empty box for a one-line request.
                .frame(minHeight: onCancel == nil ? 60 : 110, maxHeight: onCancel == nil ? 120 : 110)
                .border(.separator)
                .focused($editing)
                .accessibilityIdentifier("intake-intent-field")
            if let onCancel {
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                    triage.buttonStyle(.borderedProminent)
                }
            } else {
                triage
            }
        }
        .onAppear { if onCancel != nil { editing = true } }
    }

    private var triage: some View {
        Button("Triage", action: onTriage)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(empty)
    }
}
