import SwiftUI

/// The status glyph at the trailing edge of a sidebar row.
///
/// Each state gets a distinct SF Symbol as well as a distinct tint: Apple's HIG warns
/// against carrying meaning in colour alone, and the tooltip needs a deliberate hover
/// to read. `busy` uses a real indeterminate `ProgressView` because that is the macOS
/// idiom for work of unknown duration.
///
/// A nil status renders nothing — "no `claude` running here", distinct from `.idle`.
struct SessionStatusIcon: View {
    let status: SessionStatus?

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
            .help(status.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.tooltip)
            .accessibilityIdentifier("session-status")
        }
    }

    @ViewBuilder
    private func glyph(for activity: SessionActivity) -> some View {
        switch activity {
        case .idle:
            symbol("circle.fill").foregroundStyle(.secondary)
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
