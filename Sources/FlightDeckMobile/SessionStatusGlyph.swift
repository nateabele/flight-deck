import FleetKit
import SwiftUI

/// The sidebar's status vocabulary, on the phone.
///
/// `nil` activity renders **nothing**, which is not the same as idle: no glyph means no
/// agent process is registered for that tab, while a dot means one is running and quiet.
/// Collapsing the two would make every dead tab look alive.
///
/// Every branch must mean the same thing it means on the Mac — see
/// `Sources/FlightDeck/SessionStatusIcon.swift` — because two devices disagreeing about a
/// glyph is worse than the phone having no glyph at all. `waiting` and `shell` therefore use
/// the Mac's exact symbol *and* tint (`questionmark.circle.fill` orange,
/// `terminal.fill` green), and the "this build doesn't recognise this state" fallback uses a
/// symbol neither the Mac nor any other branch here ever draws
/// (`circle.dotted`) — `questionmark.circle` was reused for both `waiting` and "unknown" in
/// an earlier draft of this file, which is exactly the kind of collision this comment exists
/// to prevent.
struct SessionStatusGlyph: View {
    let session: WireSession

    var body: some View {
        switch session.activity {
        case nil:
            // Matches the width of every other branch below so the column doesn't ragged
            // when adjacent rows are in different states, but carries no accessibility
            // element — there is nothing to announce for a tab with no agent process.
            Color.clear.frame(width: 18, height: 18)
        case "idle":
            glyph(Circle().fill(.secondary).frame(width: 6, height: 6), label: "Idle")
        case "busy":
            glyph(
                HStack(spacing: 2) {
                    ProgressView().controlSize(.mini)
                    if session.subagentCount > 0 {
                        Text("\(session.subagentCount)").font(.caption2.monospacedDigit())
                    }
                },
                label: session.subagentCount > 0
                    ? "Busy, \(session.subagentCount) subagents" : "Busy"
            )
        case "shell":
            glyph(
                Image(systemName: "terminal.fill").font(.caption).foregroundStyle(.green),
                label: "Shell"
            )
        case "waiting":
            glyph(
                Image(systemName: "questionmark.circle.fill").font(.caption)
                    .foregroundStyle(.orange),
                label: "Waiting for you"
            )
        default:
            // An activity this build does not know about still renders as *something*,
            // for the same reason `WireSession.agent` is a String: the Mac may be newer.
            glyph(
                Image(systemName: "circle.dotted").font(.caption).foregroundStyle(.secondary),
                label: "Unrecognized status"
            )
        }
    }

    /// Fixes every glyph's column at the same width — `Color.clear`, a 6pt dot, an SF Symbol
    /// and a `ProgressView` all render at different intrinsic sizes, and without a shared
    /// frame the row titles they sit beside ragged from one row to the next.
    @ViewBuilder
    private func glyph(_ content: some View, label: String) -> some View {
        content
            .frame(width: 18, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}
