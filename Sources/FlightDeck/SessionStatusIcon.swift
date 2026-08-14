import SwiftUI

/// The status glyph at the trailing edge of a sidebar row.
///
/// Each state gets a distinct SF Symbol as well as a distinct tint: Apple's HIG warns
/// against carrying meaning in colour alone, and the tooltip needs a deliberate hover
/// to read. `busy` uses a real indeterminate `ProgressView` because that is the macOS
/// idiom for work of unknown duration.
///
/// A nil status renders nothing — "no `claude` running here", distinct from `.idle`.
///
/// `unread` marks a session that finished while the user was looking elsewhere. It is the one
/// distinction here drawn in colour alone — a filled dot in the accent colour rather than in
/// grey — which is a deliberate exception to the rule above, taken because a second glyph
/// shape for "idle" read poorly next to the other three states. The tooltip and accessibility
/// label carry the same information in text; see `SessionStatus.tooltip(unread:)`.
struct SessionStatusIcon: View {
    let status: SessionStatus?
    var unread: Bool = false

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
            .help(status.tooltip(unread: unread))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.tooltip(unread: unread))
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
                // `.secondary` (α≈0.50 light / 0.55 dark) knocked back 20%, landing near
                // α 0.40/0.44. Applied as view opacity on top of the *semantic* colour rather
                // than as a literal grey, so it still adapts to light/dark and to the
                // accessibility contrast settings. The next semantic step down, `.tertiary`,
                // was measured at α≈0.26 — roughly half again, which reads as disabled.
                symbol("circle.fill").foregroundStyle(.secondary).opacity(0.8)
            }
        case .busy:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .waiting:
            symbol("questionmark.circle.fill").foregroundStyle(.orange)
        case .shell:
            symbol("terminal.fill").foregroundStyle(.green)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .imageScale(.small)
            .symbolRenderingMode(.hierarchical)
    }
}
