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
            // Nothing in this row toggles anything, and that is load-bearing: a `Button` — or
            // a tap gesture, or an `NSViewRepresentable`, or a recognizer on the table —
            // consumes the mouse-down that `List`'s `.onMove` needs to begin a drag, so a
            // toggle placed here kills reordering everywhere it reaches. The chevron alone was
            // once small enough to dodge that (a ~5×9pt glyph, and `.rotationEffect` turns
            // hit-testing with it, so expanded it was a 9×5 sliver) but it took repeated tries
            // to hit, and widening it to cover the name took the whole row's drag with it.
            //
            // The toggle is `SidebarInputMonitor`'s instead. It watches mouse-down and mouse-up
            // passively, returns both unchanged, and tells a click from a drag afterwards — so
            // the entire row toggles on a click AND drags to reorder. Finder and the Xcode
            // navigator toggle from the whole label too, so this is also the conventional
            // behaviour.
            //
            // Nothing is lost to VoiceOver by there being no button: the one that used to be
            // here was `.accessibilityHidden(true)`, so it was never actuatable. The context
            // menu's Expand/Collapse is, and remains, the accessible route.
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(repo.isCollapsed ? 0 : 90))
                // Hidden but still occupying its space on an empty project: there is nothing to
                // disclose, and collapsing the layout instead would knock every project name
                // out of alignment as sessions come and go.
                .opacity(repo.sessions.isEmpty ? 0 : 1)
                // Decorative — the row's own label says "collapsed"/"expanded" in words — and
                // this is the ONLY thing here that may ever be hidden. The row is an
                // `.accessibilityElement(children: .combine)`, and combine needs at least one
                // unhidden descendant to build from: hiding anything that contains the title
                // leaves it with none, and SwiftUI drops the entire element,
                // `.accessibilityIdentifier("project-header")` with it.
                // `testProjectHeadingsReorderByDragging` caught that as "0 project headers
                // found", with an assertion message that blamed the seed flag.
                .accessibilityHidden(true)

            Text(repo.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // 4, not a reserved grab strip: the whole row is drag surface again now that
            // nothing in it takes the mouse-down.
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
                // Independent of the icon above: `collapsedStatus` filters out idle children,
                // so a project whose only active tab is idle-with-background-work would
                // otherwise go completely silent when collapsed — the same badge a session
                // row draws beside its own (visible) idle dot.
                if store.projectHasBackgroundWork(forProjectAt: repo.id) {
                    BackgroundWorkBadge()
                }
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
        if repo.isCollapsed {
            if let status = store.collapsedStatus(forProjectAt: repo.id) {
                parts.append(status.tooltip)
            }
            // Independent of `collapsedStatus`, and appended regardless of whether it found
            // anything — this is the one fact that survives every tab going idle.
            if store.projectHasBackgroundWork(forProjectAt: repo.id) {
                parts.append("background command running")
            }
        }
        return parts.joined(separator: ", ")
    }
}
