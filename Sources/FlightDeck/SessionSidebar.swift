import AppKit
import SwiftUI

/// One sidebar row. Owns only its transient edit state; the title itself lives in the Store.
private struct SessionRow: View {
    @ObservedObject var store: SessionStore
    let session: Session

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    /// When the title was last clicked, for the hand-rolled double-click detection in
    /// `handleTitleTap()`.
    @State private var lastTitleTap: Date?

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
                    // A single recognizer, with the double click detected by hand. See
                    // `handleTitleTap()` for why this isn't `onTapGesture(count: 2)`.
                    .onTapGesture(perform: handleTitleTap)
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

    /// Selects on the first click, starts a rename on a second click that lands within the
    /// system double-click interval.
    ///
    /// This is deliberately *not* `.onTapGesture(count: 2)`, and not a count-2 plus count-1
    /// pair either. An exclusive count-2 recognizer swallows the single click, so clicking
    /// the title — the part of the row people actually aim at — never reached the enclosing
    /// `List(selection:)` and the row would not select. Two things that look like fixes are
    /// not: `simultaneousGesture` still does not let the click through to the List, and
    /// pairing a count-2 with a count-1 recognizer leaves the count-1 one never firing at
    /// all (verified — an explicit handler assigning `selectedSessionID` did not run).
    ///
    /// Detecting the second click ourselves removes SwiftUI's gesture arbitration from the
    /// problem entirely: one recognizer, always delivered. `NSEvent.doubleClickInterval`
    /// honours the user's Trackpad/Mouse setting rather than hard-coding a threshold.
    ///
    /// Selecting on the first click of a double click is intended — double-clicking a row
    /// should both activate it and begin editing it.
    private func handleTitleTap() {
        let now = Date()
        defer { lastTitleTap = now }

        store.selectedSessionID = session.id

        // No need to reset the timestamp after starting a rename: the `Text` is replaced by
        // the `TextField` while editing, so it cannot receive a third tap.
        if let last = lastTitleTap, now.timeIntervalSince(last) <= NSEvent.doubleClickInterval {
            draft = session.title
            isEditing = true
            focused = true
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

    /// Drives both the label and which shortcut the button claims.
    private var isEmpty: Bool { store.repos.isEmpty }

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
        .dropDestination(for: URL.self) { urls, _ in
            store.acceptDroppedURLs(urls) != nil
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                store.createFromMenu()
            } label: {
                HStack {
                    Label(isEmpty ? "Add Project" : "New Session", systemImage: "plus")
                    Spacer()
                    // Apple's HIG puts shortcuts on menu items, not buttons. Shown here
                    // deliberately so the binding is discoverable without opening the menu;
                    // the File menu carries the same two shortcuts.
                    Text(isEmpty ? "⇧⌘A" : "⌘N")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("new-session")
            .keyboardShortcut(isEmpty ? .init("a", modifiers: [.command, .shift])
                                     : .init("n", modifiers: .command))
            .padding(8)
        }
    }
}
