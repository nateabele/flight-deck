import FleetKit
import SwiftUI

/// The status glyph at the leading edge of a sidebar row (a busy row's sub-agent count is
/// drawn separately, at the trailing edge — see `SubagentCount`).
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
    var apiError: SessionAPIError?

    var body: some View {
        if let apiError {
            // Wins outright — over the idle dot, over unread, and over the activity glyph.
            //
            // The justification is the clearing rule: this flag only survives while no newer
            // transcript record has arrived, so if it is set, the last thing that actually happened
            // in this conversation WAS an error, whatever the status file currently claims. A status
            // file reading `busy` against a transcript whose last record is a failure is precisely
            // the stale-status case this badge exists to expose, so deferring to it would defeat the
            // feature. The window is small: the first record of a genuine new turn clears the flag.
            //
            // Red and a triangle: distinct in BOTH channels, per the HIG rule this file already
            // enforces. Orange is spoken for by `waiting` and must not be reused.
            symbol("exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .help(apiError.label)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(apiError.label)
                .accessibilityIdentifier("session-status")
        } else if let status {
            // The sub-agent count is not drawn here any more — see `SubagentCount`, which the
            // session row places at its trailing edge. The label below still names it.
            glyph(for: status.activity)
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

/// A busy session's sub-agent count — or a waiting one's, while an agent is blocked — drawn
/// at the row's trailing edge.
///
/// Trailing rather than beside the status glyph: inline, the numeral widened the leading
/// status column and pushed that one row's title right of every other. Placed immediately
/// before the hover-only close button, it rests flush right and slides left when the button
/// appears. Hidden from accessibility — `SessionStatusIcon`'s label already says
/// "Working — N subagents", and a bare numeral read after the title would say it twice.
struct SubagentCount: View {
    let status: SessionStatus?
    let tree: SubagentTree
    /// Click the count to see which subagents those are; a bare numeral answered "how many"
    /// but never "which one is blocked on me".
    @State private var showing = false

    /// The numeral to draw, or nil for no badge. Busy with agents, as before — OR any agent
    /// blocked, whatever the parent's activity: while a subagent's dialog is up the parent
    /// reads `waiting`, and a busy-only rule hid the count (and its popover) exactly when the
    /// user needed to see which agent was asking. A blocked agent is a live one, so the count
    /// never reads 0 then.
    static func badge(status: SessionStatus?, tree: SubagentTree) -> Int? {
        guard let status else { return nil }
        if status.activity == .busy, status.subagentCount > 0 { return status.subagentCount }
        let blocked = tree.nodes.contains {
            if case .blocked = $0.state { return true } else { return false }
        }
        return blocked ? max(status.subagentCount, 1) : nil
    }

    var body: some View {
        if let status, let count = Self.badge(status: status, tree: tree) {
            Button { showing.toggle() } label: {
                Text("\(count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .help(status.tooltip)
            .accessibilityHidden(true)
            .popover(isPresented: $showing) { outline }
        }
    }

    private var outline: some View {
        let rows = SubagentOutline.rows(tree)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.node.id) { row in
                HStack(spacing: 6) {
                    stateSymbol(row.node.state)
                    Text(row.node.type).fontWeight(.medium)
                    Text(row.node.description).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.leading, CGFloat(row.depth) * 12)
            }
        }
        .padding(12)
        .frame(minWidth: 260, alignment: .leading)
    }

    @ViewBuilder
    private func stateSymbol(_ state: SubagentNode.State) -> some View {
        switch state {
        case .running: Image(systemName: "circle.fill").foregroundStyle(.tint)
        case .blocked: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }
}
