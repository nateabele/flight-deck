import SwiftUI

/// A project's row in the sidebar: disclosure chevron, name, and — when collapsed — how
/// many sessions it holds and the most demanding thing any of them is doing.
///
/// The chevron sits on the leading edge, as it does in the Finder and Xcode navigators,
/// rather than using the hover-revealed trailing "Show"/"Hide" that a system `Section`
/// header draws. It is always visible: collapse state has to be legible at a glance, and
/// with the session rows hidden the chevron is the only thing that says so. The close
/// button is the opposite — destructive, so it stays out of the way until pointed at.
struct ProjectHeaderRow: View {
    @ObservedObject var store: SessionStore
    let repo: Repo
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(repo.isCollapsed ? 0 : 90))
                // Hidden but still occupying its space on an empty project: there is nothing
                // to disclose, and collapsing the layout instead would knock every project
                // name out of alignment as sessions come and go.
                .opacity(repo.sessions.isEmpty ? 0 : 1)
                .accessibilityHidden(true)

            Text(repo.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if repo.isCollapsed {
                Text("\(repo.sessions.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // Reused rather than reimplemented so the collapsed and expanded renderings
                // of the same state cannot drift apart.
                SessionStatusIcon(status: store.collapsedStatus(forProjectAt: repo.id))
            }

            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close Project")
                .accessibilityLabel("Close Project")
                .accessibilityIdentifier("close-project")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: repo.isCollapsed)
        .contextMenu {
            Button("New Session") { store.newSession(in: repo.url) }
            Button(repo.isCollapsed ? "Expand" : "Collapse") { toggle() }
            Divider()
            Button("Close Project", role: .destructive, action: onClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("project-header")
    }

    private func toggle() {
        store.setCollapsed(!repo.isCollapsed, forProjectAt: repo.id)
    }

    /// The count and the status glyph reach VoiceOver as words here; on screen they are a
    /// bare numeral and an unnamed symbol.
    private var accessibilityLabel: String {
        var parts = [repo.displayName]
        parts.append(repo.sessions.count == 1 ? "1 session" : "\(repo.sessions.count) sessions")
        parts.append(repo.isCollapsed ? "collapsed" : "expanded")
        if repo.isCollapsed, let status = store.collapsedStatus(forProjectAt: repo.id) {
            parts.append(status.tooltip)
        }
        return parts.joined(separator: ", ")
    }
}
