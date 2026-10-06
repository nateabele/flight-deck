import SwiftUI

/// Root of the window: a split view pairing the repo-grouped session sidebar with the
/// selected session's terminal (or an empty-state prompt when nothing is selected). The
/// `SessionStore` is owned by `FlightDeckApp` as a `@StateObject`, not by this view.
struct RootView: View {
    @ObservedObject var store: SessionStore
    /// Only the sidebar's project-close confirmation reads this; passed rather than
    /// re-created so it is the same instance the Settings scene edits.
    var preferences: PreferencesStore?
    /// Sessions a paired phone has open; only the sidebar reads it.
    var phoneActiveSessions: Set<UUID> = []

    @StateObject private var overlayModel = ToolOverlayModel()
    @StateObject private var overlayMonitor = ToolOverlayInputMonitorBox()
    @State private var shortcutGroups: [ShortcutGroup]?

    /// Which node `DependencyDAGOverlay.onSelectNode` last picked, independent of the
    /// focused tab's own bead — the overlay lets you browse the graph without jumping
    /// tabs (`onSelectNode` vs `onJumpToTab`), so this has to be view state the store
    /// doesn't own. Reset on dismiss so the next open starts centered on the focused
    /// agent's own bead again, not wherever the last session left off.
    @State private var observeDAGSelectedBeadID: String?

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, preferences: preferences,
                           phoneActiveSessions: phoneActiveSessions)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let projectID = store.selectedProjectID,
               let repo = store.repos.first(where: { $0.id == projectID }) {
                ProjectView(store: store, repo: repo)
            } else if let surface = store.selectedSessionID.flatMap({ store.surface(for: $0) }) {
                VStack(spacing: 0) {
                    TerminalPane(store: store)
                        .frame(minWidth: 400, minHeight: 300)
                        // Both float rather than shrinking the terminal: the grid would otherwise
                        // reflow every time either one appeared. Stacked so the find bar and the
                        // tool cluster never contend for the same corner.
                        .overlay(alignment: .topTrailing) {
                            VStack(alignment: .trailing, spacing: 0) {
                                SearchOverlay(surface: surface)
                                if let preferences {
                                    ToolOverlay(
                                        store: store,
                                        preferences: preferences,
                                        model: overlayModel,
                                        monitor: overlayMonitor.monitor,
                                        launcher: ShellToolLauncher.configured(preferences)
                                    )
                                }
                            }
                        }
                    if let agent = store.focusedObserveAgent() {
                        ObserveDrawer(agent: agent,
                                      collapsed: store.observeDrawerCollapsed,
                                      onToggleCollapse: { store.toggleObserveDrawer() },
                                      onJumpToRootCause: { store.jumpToObserveRootCause() },
                                      onOpenDAG: { store.presentObserveDAG() },
                                      assignment: store.focusedSwarmAssignment(),
                                      session: store.selectedSessionID,
                                      swarmRevision: store.swarmServiceIfBuilt?.revision ?? 0,
                                      onJumpToSession: { store.selectedSessionID = $0 })
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("No Session", systemImage: "terminal")
                } description: {
                    Text("Create a session to get started.")
                } actions: {
                    Button("Add Project") { store.addProjectFromMenu() }
                }
            }
        }
        // Sets the WINDOW's title, not a navigation bar's: on macOS `navigationTitle` on a
        // `Window` scene's root view is what writes the title bar, and it re-applies on every
        // body pass, so switching sessions retitles the window with no AppKit reach-through
        // and nothing to keep in sync. Applied to the `NavigationSplitView` itself rather than
        // to either column, which is the placement SwiftUI resolves to the window.
        .navigationTitle(WindowTitle.text(project: store.currentProjectName))
        // The drawer's "open DAG" button (`presentObserveDAG()`) flips this; `onClose`
        // below clears it. Sourced from `focusedObserveProjection()` rather than a single
        // agent, since the overlay draws the whole project's graph.
        .sheet(isPresented: $store.observeDAGPresented, onDismiss: { observeDAGSelectedBeadID = nil }) {
            if let projection = store.focusedObserveProjection() {
                DependencyDAGOverlay(
                    projection: projection,
                    selectedBeadID: observeDAGSelectedBeadID ?? store.focusedObserveAgent()?.bead?.id,
                    onSelectNode: { observeDAGSelectedBeadID = $0 },
                    onJumpToTab: { store.selectObserveSession(forBeadID: $0) },
                    onClose: { store.observeDAGPresented = false }
                )
                .frame(minWidth: 640, minHeight: 440)
            }
        }
        .sheet(item: $store.swarmLaunchRequest) { request in
            LaunchSheet(model: LaunchSheetModel(request: request, backend: store.swarmService.backend,
                                                service: store.swarmService, registry: store.routingCapabilities),
                        harnesses: store.routingCapabilities.harnesses,
                        onClose: { store.swarmLaunchRequest = nil })
        }
        // Over the whole window, not the detail column: the scrim has to cover the sidebar too,
        // or a click there would change the selection behind an overlay the user is reading.
        .overlay {
            if let groups = shortcutGroups {
                ShortcutOverlay(groups: groups, dismiss: dismissShortcuts)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .flightDeckToggleShortcuts)) { _ in
            if shortcutGroups == nil { shortcutGroups = ShortcutCatalog.currentGroups() }
            else { dismissShortcuts() }
        }
        // ⌃⌘←/→, ⌘⇧], ⌘W, and ⌘⇧T all change the selection without going through this view at
        // all — they act on `store` directly — so without this the overlay stays open, scrim and
        // all, while the tab underneath it has already switched.
        .onChange(of: store.selectedSessionID) {
            if shortcutGroups != nil { dismissShortcuts() }
        }
        // Same for opening or closing a project view, which swaps the detail column without
        // touching `selectedSessionID` at all.
        .onChange(of: store.selectedProjectID) {
            if shortcutGroups != nil { dismissShortcuts() }
        }
    }

    /// Hands focus back to the terminal: the filter field held it, and without this the next
    /// keystroke after Esc goes nowhere visible instead of to the prompt the user came from.
    /// `Ghostty.moveFocus(to:)`, not a raw `makeFirstResponder`: it retries with backoff when
    /// the surface isn't attached to a window yet, which is the established idiom for handing
    /// focus back from a SwiftUI overlay — see `TerminalSearchBar.dismiss()` and the doc
    /// comment on `moveFocus` in `SurfaceConfiguration.swift`.
    private func dismissShortcuts() {
        shortcutGroups = nil
        if let id = store.selectedSessionID, let surface = store.surface(for: id) {
            Ghostty.moveFocus(to: surface)
        }
    }
}
