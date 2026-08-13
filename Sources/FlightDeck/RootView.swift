import SwiftUI

/// Root of the window: a split view pairing the repo-grouped session sidebar with the
/// selected session's terminal (or an empty-state prompt when nothing is selected). The
/// `SessionStore` is owned by `FlightDeckApp` as a `@StateObject`, not by this view.
struct RootView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let surface = store.selectedSessionID.flatMap({ store.surface(for: $0) }) {
                TerminalPane(store: store)
                    .frame(minWidth: 400, minHeight: 300)
                    // The find bar floats over the terminal rather than shrinking it: the
                    // grid would otherwise reflow every time the bar opened or closed.
                    .overlay(alignment: .topTrailing) {
                        SearchOverlay(surface: surface)
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
