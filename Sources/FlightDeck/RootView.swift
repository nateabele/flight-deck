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
            if store.selectedSessionID.flatMap({ store.surface(for: $0) }) != nil {
                TerminalPane(store: store)
                    .frame(minWidth: 400, minHeight: 300)
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
