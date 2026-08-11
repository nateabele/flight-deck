import SwiftUI

/// One sidebar row. Owns only its transient edit state; the title itself lives in the Store.
private struct SessionRow: View {
    @ObservedObject var store: SessionStore
    let session: Session

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .accessibilityIdentifier("session-title-field")
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }   // Esc
                    .onChange(of: focused) { if !$1 { commit() } }
            } else {
                Text(session.title)
                    .accessibilityIdentifier("session-row-title")
                    .onTapGesture(count: 2) {
                        draft = session.title
                        isEditing = true
                        focused = true
                    }
            }
            Spacer()
            Button {
                store.closeSession(session.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("close-session")
        }
    }

    /// Empty input reverts: `rename` ignores it and we simply leave edit mode.
    private func commit() {
        guard isEditing else { return }
        isEditing = false
        store.rename(session.id, to: draft)
    }
}

/// Renders the repo→session tree and issues create/switch/close intents to the
/// Store. Rendering only: it holds no session state of its own.
struct SessionSidebar: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        List(selection: $store.selectedSessionID) {
            ForEach(store.repos) { repo in
                Section(repo.displayName) {
                    ForEach(repo.sessions) { session in
                        SessionRow(store: store, session: session)
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
