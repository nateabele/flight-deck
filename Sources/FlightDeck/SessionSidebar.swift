import SwiftUI

/// Renders the repo→session tree and issues create/switch/close intents to the
/// Store. Rendering only: it holds no session state of its own.
struct SessionSidebar: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        List(selection: $store.selectedSessionID) {
            ForEach(store.repos) { repo in
                Section(repo.displayName) {
                    ForEach(repo.sessions) { session in
                        HStack {
                            Text(session.title)
                            Spacer()
                            Button {
                                store.closeSession(session.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("close-session")
                        }
                        .tag(session.id)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if let url = FolderPicker.choose() {
                    store.newSession(in: url)
                }
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("new-session")
            .padding(8)
        }
    }
}
