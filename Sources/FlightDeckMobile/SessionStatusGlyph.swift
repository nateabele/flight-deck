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
/// glyph is worse than the phone having no glyph at all. `waiting` therefore uses the Mac's
/// exact symbol *and* tint (`questionmark.circle.fill` orange), and the "this build doesn't
/// recognise this state" fallback uses a symbol neither the Mac nor any other branch here ever
/// draws (`circle.dotted`) — `questionmark.circle` was reused for both `waiting` and "unknown"
/// in an earlier draft of this file, which is exactly the kind of collision this comment
/// exists to prevent.
///
/// `"shell"` no longer reaches the phone as an activity value at all: the Mac decomposes it
/// into `activity: "idle"` plus the orthogonal `WireSession.hasBackgroundWork`, which the
/// caller renders as a `terminal.fill` badge beside this glyph rather than a branch of it.
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
                label: label
            )
        case "busy":
            glyph(
                HStack(spacing: 2) {
                    ProgressView().controlSize(.mini)
                    // Through `subagentSummary` rather than off `subagentCount` directly, so
                    // this column and the timeline header cannot disagree: a codex tab's 0
                    // means "unknown", and neither screen may render it as "none".
                    if session.subagentSummary != nil {
                        Text("\(session.subagentCount)").font(.caption2.monospacedDigit())
                    }
                },
                label: label
            )
        case "waiting":
            glyph(
                Image(systemName: "questionmark.circle.fill").font(.caption)
                    .foregroundStyle(.orange),
                label: label
            )
        default:
            // An activity this build does not know about still renders as *something*,
            // for the same reason `WireSession.agent` is a String: the Mac may be newer.
            glyph(
                Image(systemName: "circle.dotted").font(.caption).foregroundStyle(.secondary),
                label: label
            )
        }
    }

    /// What VoiceOver announces for this row, coalesced from `label(for:)`'s `nil` — which
    /// only ever means "no agent process", the one branch below that renders no accessibility
    /// element at all and so never reads this.
    private var label: String { Self.label(for: session) ?? "" }

    /// The whole accessibility vocabulary, in one place and reachable without SwiftUI.
    ///
    /// `nil` means *no accessibility element*, which is not the same as an empty label: a tab
    /// with no agent process registered has nothing to announce, and giving it a label would
    /// make VoiceOver stop on every dead row in the list. A background flag cannot resurrect
    /// one — `label(for:)` below only appends its clause once `baseLabel` has returned
    /// something to append it to.
    ///
    /// Every string here must equal what `SessionStatus.tooltip`/`tooltip(unread:)` produces
    /// for the identical state on the Mac (`Sources/FlightDeck/SessionStatus.swift`). That
    /// invariant is checked from both ends: `SessionStatusGlyphTests` on iOS pins these
    /// strings, and `SessionStatusTests`/`SessionReadPolicyTests` on macOS pin the same
    /// literals against `tooltip`. Either side drifting fails its own suite.
    private static func baseLabel(for session: WireSession) -> String? {
        switch session.activity {
        case nil:
            return nil
        case "idle":
            // `SessionStatus.tooltip(unread:)`'s one override: an idle session that hasn't
            // been opened yet reads as finished-but-unseen, not merely idle.
            return session.isUnread ? "Finished — not yet viewed" : "Idle"
        case "busy":
            // `SessionStatus.tooltip`'s `.busy` branch. The count comes from
            // `subagentSummary`, which is nil for codex at any count — see that property.
            guard let summary = session.subagentSummary else { return "Working" }
            return "Working — \(summary)"
        case "waiting":
            // `SessionStatus.tooltip`'s `.waiting` branch: the reason, when `claude` gave one.
            guard let waitingFor = session.waitingFor, !waitingFor.isEmpty else {
                return "Waiting for you"
            }
            return "Waiting for you — \(waitingFor)"
        default:
            // An activity this build does not know about, matching `body`'s own fallback.
            return "Unrecognized status"
        }
    }

    /// Appends `SessionStatus.tooltip(unread:backgroundWork:)`'s background clause, verbatim
    /// and always last, so every label `baseLabel` produced before the flag existed is
    /// byte-identical when it is false.
    static func label(for session: WireSession) -> String? {
        guard let base = baseLabel(for: session) else { return nil }
        guard session.hasBackgroundWork else { return base }
        return base + " — background command running"
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
