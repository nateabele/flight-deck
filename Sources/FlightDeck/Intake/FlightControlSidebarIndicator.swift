import SwiftUI

/// Flight Control's status at the trailing edge of a project's sidebar row.
///
/// Session rows carry their status at the LEADING edge (`SessionStatusIcon`); this sits at the
/// other end, in a different shape (a clipboard, a capsule), so a plan needing you never reads
/// as a tab needing you. Needs you wins over working, and idle draws nothing.
///
/// A pure view of `FlightControlSidebarStatus`, with no service, store or closure in its
/// inputs, and `Equatable` on the status, so its body runs only when the status changes
/// (`RenderProbe` "fcIndicator") however often the row around it redraws.
/// The click is NOT a `Button`: a control here would take the mouse-down that `List`'s `.onMove`
/// needs to begin a drag (see `ProjectHeaderRow`). A tap gesture on a glyph this small costs a
/// drag started exactly on it, the same trade the sub-agent count makes; `SidebarInputMonitor`
/// still sees the press first and selects the project, and the tap then picks the plan.
struct FlightControlSidebarIndicator: View, Equatable {
    let status: FlightControlSidebarStatus
    /// A plain `@Environment`, not an input: it must not make this view differ between renders.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// By status alone, so `.equatable()` at the call site skips the body for an unchanged one.
    static func == (a: Self, b: Self) -> Bool { a.status == b.status }

    var body: some View {
        let _ = RenderProbe.hit("fcIndicator")
        switch status.kind {
        case .idle:
            EmptyView()
        case .working:
            // Pulses while a round runs. With Reduce Motion it is still, and the accent tint
            // alone says "alive" — the glyph is different from the attention one either way.
            Image(systemName: "list.bullet.clipboard")
                .imageScale(.small)
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                .modifier(Described(status: status))
        case .needsYou:
            HStack(spacing: 2) {
                Image(systemName: "list.bullet.clipboard.fill")
                    .imageScale(.small)
                if status.attentionCount > 1 {
                    Text("\(status.attentionCount)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.22)))
            .modifier(Described(status: status))
        }
    }

    /// Hover help and the VoiceOver label; the row is one combined element, so the header adds
    /// the same words to its own label.
    private struct Described: ViewModifier {
        let status: FlightControlSidebarStatus
        func body(content: Content) -> some View {
            content
                .contentShape(Rectangle())
                .help(status.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(status.accessibilityLabel)
                .accessibilityIdentifier("flight-control-status")
        }
    }
}
