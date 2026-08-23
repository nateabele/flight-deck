import AppKit
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
            // The chevron is the toggle, and it is a `Button` rather than a tap gesture on
            // the row. That is load-bearing, not stylistic: a `.onTapGesture` anywhere on a
            // row consumes the mouse-down that `List`'s `.onMove` needs to begin a drag, so
            // the row-wide toggle this used to carry made project reordering impossible —
            // dead across the whole row, because `.contentShape(Rectangle())` below extends
            // the gesture to the full width. Restricting the toggle to the chevron leaves
            // the rest of the row grabbable. Finder and the Xcode navigator toggle on the
            // triangle too, so this is also the more conventional behaviour.
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(repo.isCollapsed ? 0 : 90))
                    // Hidden but still occupying its space on an empty project: there is
                    // nothing to disclose, and collapsing the layout instead would knock
                    // every project name out of alignment as sessions come and go.
                    .opacity(repo.sessions.isEmpty ? 0 : 1)
            }
            .buttonStyle(.plain)
            .disabled(repo.sessions.isEmpty)
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
        // `.contentShape` stays — it is what makes hover cover the whole row rather than just
        // the drawn content. It is safe on its own; it was the `.onTapGesture` it used to sit
        // beside that killed the drag, not the hit-test shape.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: repo.isCollapsed)
        .contextMenu {
            Button("New Session") { store.newSession(in: repo.url) }
            Button(repo.isCollapsed ? "Expand" : "Collapse") { toggle() }
            Divider()
            // A project is a folder, and its path is otherwise only visible in Settings. Both
            // items act on the standardized URL, the same spelling everything else compares.
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repo.url.standardizedFileURL])
            }
            Button("Copy Path") {
                let pasteboard = NSPasteboard.general
                // A pasteboard write without a clear first appends to whatever is already
                // there under other types, which pastes as the previous contents in some apps.
                pasteboard.clearContents()
                pasteboard.setString(repo.url.standardizedFileURL.path, forType: .string)
            }
            Divider()
            Button("Close Project", role: .destructive, action: onClose)
            Divider()
            // Ellipsis because it opens a window, matching "Configure Tools…". Last rather
            // than above Close Project by request.
            Button("Configure…") {
                PreferencesOpener.open(
                    store.preferences,
                    tab: .projects,
                    project: repo.url.standardizedFileURL.path
                )
            }
            .accessibilityIdentifier("project-configure")
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
