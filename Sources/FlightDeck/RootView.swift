import SwiftUI

/// Root of the window. Owns the SessionStore for the window's lifetime and,
/// for now, renders just the selected terminal. The sidebar is added in the
/// next task.
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
                    Button("New Session") {
                        if let url = FolderPicker.choose() {
                            store.newSession(in: url)
                        }
                    }
                }
            }
        }
    }
}
