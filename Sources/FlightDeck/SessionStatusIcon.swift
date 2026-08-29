import SwiftUI

/// The status glyph at the trailing edge of a sidebar row.
///
/// Each state gets a distinct SF Symbol as well as a distinct tint: Apple's HIG warns
/// against carrying meaning in colour alone, and the tooltip needs a deliberate hover
/// to read. `busy` uses a real indeterminate `ProgressView` because that is the macOS
/// idiom for work of unknown duration.
///
/// `status` nil and `unread` false renders nothing — "no `claude` running here", distinct
/// from `.idle`. That is a statement about *process* state: nothing is running, so there is
/// nothing to show. `unread` is a separate, user-asserted *read* state — "Mark as Unread" is
/// reachable from the context menu regardless of whether `claude` is running — and it must
/// stay visible even when there is no process to report on, or the menu item would look
/// broken. So a nil status with `unread == true` still draws the dot; "nil renders nothing"
/// only ever protected the process-state case.
///
/// `unread` marks a session that finished while the user was looking elsewhere. It is the one
/// distinction here drawn in colour alone — a filled dot in the accent colour rather than in
/// grey — which is a deliberate exception to the rule above, taken because a second glyph
/// shape for "idle" read poorly next to the other three states. The tooltip and accessibility
/// label carry the same information in text; see `SessionStatus.tooltip(unread:)`.
struct SessionStatusIcon: View {
    let status: SessionStatus?
    var unread: Bool = false
    var hasBackgroundWork: Bool = false

    var body: some View {
        if let status {
            HStack(spacing: 2) {
                glyph(for: status.activity)
                if status.activity == .busy, status.subagentCount > 0 {
                    Text("\(status.subagentCount)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                }
            }
            .help(status.tooltip(unread: unread, backgroundWork: hasBackgroundWork))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.tooltip(unread: unread, backgroundWork: hasBackgroundWork))
            .accessibilityIdentifier("session-status")
        } else if unread {
            // No `SessionStatus` to ask for a tooltip — `tooltip(unread:)` is an instance
            // method and needs an `activity` to branch on, and there is none here: no `claude`
            // is running, so there is no process state to describe, only the user's own mark.
            // `tooltip(unread:)`'s idle+unread string ("Finished — not yet viewed") would be
            // wrong here — nothing necessarily *finished*, there may never have been a process
            // — so this is a short literal instead of reshaping that API for a case it was
            // never meant to express.
            let label = "Unread"
            symbol("circle.fill")
                .foregroundStyle(Color.accentColor)
                .help(label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier("session-status")
        }
    }

    @ViewBuilder
    private func glyph(for activity: SessionActivity) -> some View {
        switch activity {
        case .idle:
            if unread {
                // Full strength, accent-tinted: this is the one row state meant to pull the
                // eye. `accentColor` rather than a pinned blue so it tracks the system accent
                // the way Mail's unread dot does.
                symbol("circle.fill").foregroundStyle(Color.accentColor)
            } else {
                // Ten percent off whatever it sits on, and no more. A read idle session is the
                // sidebar's resting state, so this dot is on nearly every row at once — at any
                // stronger tint the column reads as noise rather than as status. `.primary` at
                // α 0.10 rather than a literal grey so it tracks light/dark *and* the row's own
                // background: inside a selected row the hierarchical style resolves against the
                // selection fill, keeping the dot the same 10% step off its background there as
                // on an unselected one. Deliberately near-invisible; the tooltip and the
                // accessibility label are what actually carry the state.
                symbol("circle.fill").foregroundStyle(.primary).opacity(0.1)
            }
        case .busy:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .waiting:
            symbol("questionmark.circle.fill").foregroundStyle(.orange)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .imageScale(.small)
            .symbolRenderingMode(.hierarchical)
    }
}
