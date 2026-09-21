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
            // The toggle is a `Button` rather than a tap gesture on the row. That is
            // load-bearing, not stylistic: a `.onTapGesture` anywhere on a row consumes the
            // mouse-down that `List`'s `.onMove` needs to begin a drag, so the row-wide
            // toggle this used to carry made project reordering impossible — dead across the
            // whole row, because `.contentShape(Rectangle())` below extends the gesture to
            // the full width. A `Button` does not have that effect outside its own bounds,
            // so the toggle can be made as large as it needs to be and the row stays
            // draggable everywhere the button is not.
            //
            // The button covers the chevron AND the name, plus a few points around both.
            // The chevron alone was a ~5×9pt glyph — and `.rotationEffect` turns hit-testing
            // with it, so expanded it was a 9×5 sliver — which took repeated tries to hit.
            // Finder and the Xcode navigator likewise toggle from the whole label, not just
            // the triangle.
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(repo.isCollapsed ? 0 : 90))
                        // Hidden but still occupying its space on an empty project: there is
                        // nothing to disclose, and collapsing the layout instead would knock
                        // every project name out of alignment as sessions come and go.
                        .opacity(repo.sessions.isEmpty ? 0 : 1)
                        // Decorative: the row's own label says "collapsed"/"expanded" in
                        // words. This is the ONLY thing in the button that may be hidden —
                        // see the note on the button below.
                        .accessibilityHidden(true)

                    Text(repo.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                // Claims the whole stack — the 4pt gap between chevron and name, and the
                // slack above and below the glyphs, are dead without this — and the negative
                // inset then pushes the hit rect 4pt past the drawn content on every side.
                // An outward-inset shape rather than `.padding()`: padding would move the
                // chevron and the name off the pixels they align to (the session titles
                // below share this leading edge), and cancelling it again with negative
                // padding would leave the hit area depending on hits surviving a parent
                // narrower than its child. This changes hit-testing only; layout is
                // untouched, so there is nothing to cancel.
                .contentShape(Rectangle().inset(by: -4))
            }
            .buttonStyle(.plain)
            // Not `.disabled`: that dims the label, and an empty project's name should read
            // exactly like every other project's. Dropping hit-testing instead makes the
            // no-op unclickable and hands that row back to the drag gesture entirely.
            .allowsHitTesting(!repo.sessions.isEmpty)
            // NOT `.accessibilityHidden(true)`, though it was while the chevron was its only
            // content. The row is an `.accessibilityElement(children: .combine)`, and combine
            // needs at least one unhidden descendant to have anything to build from — hiding
            // this button once it contained the name left the row with none, and SwiftUI
            // dropped the whole element, `.accessibilityIdentifier("project-header")` with it.
            // `testProjectHeadingsReorderByDragging` caught it: 0 headers matched, not 2. The
            // chevron carries the hidden flag instead, which is what it was ever for.

            // 24 rather than 4 so a long, truncating name cannot squeeze the bare row down to
            // a hairline: everything left of this spacer is now button, and `.onMove` needs
            // somewhere to start a drag from. This strip is that somewhere, at every name
            // length.
            Spacer(minLength: 24)

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
