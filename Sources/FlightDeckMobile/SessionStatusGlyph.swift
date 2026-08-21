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
///
/// The accessibility labels mirror `SessionStatus.tooltip`/`tooltip(unread:)` in
/// `Sources/FlightDeck/SessionStatus.swift` verbatim, string for string, including the
/// singularization at `subagentCount == 1` and the idle+unread override to
/// "Finished — not yet viewed" — a VoiceOver user hearing a different word than what the
/// Mac's own tooltip says for the identical state is the same kind of disagreement a
/// mismatched symbol would be.
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
            // Unread is expressed HERE, in the status column, not as a separate badge on the
            // trailing edge. That is where the Mac puts it — `SessionStatusIcon` draws an
            // idle-and-unread session as a full-strength accent `circle.fill` and an
            // idle-and-read one as `.secondary` knocked back — and a badge on the opposite
            // side of the row for the same fact is the kind of split vocabulary this file
            // exists to prevent. It also made VoiceOver say the state twice.
            //
            // The distinction is tint, exactly as on the Mac; the size is 8pt rather than the
            // Mac's 6 because this is read at arm's length on a phone rather than at desk
            // distance, and both branches share it so the column cannot ragged.
            glyph(
                Circle()
                    .fill(session.isUnread ? AnyShapeStyle(Color.accentColor)
                                           : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .opacity(session.isUnread ? 1 : 0.8)
                    .frame(width: 8, height: 8),
                label: idleLabel
            )
        case "busy":
            glyph(
                HStack(spacing: 2) {
                    ProgressView().controlSize(.mini)
                    if session.subagentCount > 0 {
                        Text("\(session.subagentCount)").font(.caption2.monospacedDigit())
                    }
                },
                label: busyLabel
            )
        case "shell":
            glyph(
                Image(systemName: "terminal.fill").font(.caption).foregroundStyle(.green),
                label: "Background command running"
            )
        case "waiting":
            glyph(
                Image(systemName: "questionmark.circle.fill").font(.caption)
                    .foregroundStyle(.orange),
                label: waitingLabel
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

    /// `SessionStatus.tooltip(unread:)`'s one override: an idle session that hasn't been
    /// opened yet reads as finished-but-unseen, not merely idle.
    private var idleLabel: String {
        session.isUnread ? "Finished — not yet viewed" : "Idle"
    }

    /// `SessionStatus.tooltip`'s `.busy` branch, singularization included.
    private var busyLabel: String {
        guard session.subagentCount > 0 else { return "Working" }
        let noun = session.subagentCount == 1 ? "subagent" : "subagents"
        return "Working — \(session.subagentCount) \(noun)"
    }

    /// `SessionStatus.tooltip`'s `.waiting` branch: the reason, when `claude` gave one.
    private var waitingLabel: String {
        guard let waitingFor = session.waitingFor, !waitingFor.isEmpty else {
            return "Waiting for you"
        }
        return "Waiting for you — \(waitingFor)"
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
