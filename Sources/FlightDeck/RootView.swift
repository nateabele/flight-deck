import SwiftUI

/// Root of the window: a split view pairing the repo-grouped session sidebar with the
/// selected session's terminal (or an empty-state prompt when nothing is selected). The
/// `SessionStore` is owned by `FlightDeckApp` as a `@StateObject`, not by this view.
struct RootView: View {
    @ObservedObject var store: SessionStore
    /// Only the sidebar's project-close confirmation reads this; passed rather than
    /// re-created so it is the same instance the Settings scene edits.
    var preferences: PreferencesStore?

    @StateObject private var overlayModel = ToolOverlayModel()
    @StateObject private var overlayMonitor = ToolOverlayInputMonitorBox()

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, preferences: preferences)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let surface = store.selectedSessionID.flatMap({ store.surface(for: $0) }) {
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
                                    monitor: overlayMonitor.monitor
                                )
                            }
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
    }
}
