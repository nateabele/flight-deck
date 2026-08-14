import AppKit
import SwiftUI

/// One sidebar row. Owns only its transient edit state; the title itself lives in the Store.
private struct SessionRow: View {
    @ObservedObject var store: SessionStore
    let session: Session
    let isConflicted: Bool

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var isHovered = false

    /// When the title was last clicked, for the hand-rolled double-click detection in
    /// `handleTitleTap()`.
    @State private var lastTitleTap: Date?

    var body: some View {
        HStack(spacing: 4) {
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
            if isConflicted {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                    .help("Another tab is on this conversation")
                    .accessibilityIdentifier("session-pin-conflict")
            }
            SessionStatusIcon(
                status: store.status(for: session.id),
                unread: store.unreadIdle.contains(session.id)
            )
            // The close button is absent, not merely hidden, until hover: inserting it
            // is what pushes the status icon left. No manual offset needed.
            if isHovered {
                Button {
                    store.closeSession(session.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("close-session")
            }
        }
        // Hover is tracked on a transparent layer BEHIND the row, not by putting
        // `.contentShape(Rectangle())` + `.onHover` on the HStack itself. Applied to the
        // HStack, that pair joins SwiftUI's hit-testing for the row and competes with the
        // title's own `.onTapGesture`: it intermittently swallowed the second click of a
        // double click, so `handleTitleTap` never saw one and rename broke. Measured at
        // 4 failures in 5 runs of `testDoubleClickRenamesSession`, against 9/9 before
        // these two changes met.
        //
        // `.onHover` alone is safe; it was `.contentShape(Rectangle())` that made the
        // HStack a hit-test participant and let it take the click. Dropping the
        // contentShape costs hovering the empty gap between the title and the icon —
        // hover now follows the row's actual content — which is a smaller price than an
        // intermittently broken rename.
        //
        // Two alternatives were measured and rejected. An `NSViewRepresentable` tracking
        // area in `.background()` is worse than either: a real `NSView` takes over the
        // row's hit-test geometry and makes the title unhittable outright (6 of 6 runs
        // failed, "Not hittable: StaticText ... session-row-title"). Putting
        // `.contentShape` + `.onHover` on a transparent SwiftUI layer behind the row fixes
        // the click theft (6 of 6 rename runs passed) but breaks hover itself, since the
        // content in front of it swallows the hover the layer needs to see.
        //
        // Known wart, unchanged: `.onHover` does not fire while a trackpad scroll is in
        // flight, so a row can hold a stale hover state after scrolling.
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
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

/// Renders the project→session tree and issues create/switch/close intents to the
/// Store. Rendering only: it holds no session state of its own.
struct SessionSidebar: View {
    @ObservedObject var store: SessionStore
    var preferences: PreferencesStore?
    /// Injectable so a future test can drive the close flow without a panel; production
    /// always gets the real alert.
    var confirmer: ProjectCloseConfirming = NSAlertProjectCloseConfirmer()

    /// Drives both the label and which shortcut the button claims.
    private var isEmpty: Bool { store.repos.isEmpty }

    var body: some View {
        let conflicted = store.conflictedSessionIDs
        return List(selection: $store.selectedSessionID) {
            // One flat ForEach rather than a Section per project: `.onMove` is not supported
            // on a ForEach that yields Sections, and this is what lets one gesture reorder
            // both projects and sessions. See `SidebarRow`.
            ForEach(store.sidebarRows) { row in
                switch row {
                case .project(let projectID):
                    if let repo = store.repos.first(where: { $0.id == projectID }) {
                        ProjectHeaderRow(store: store, repo: repo) {
                            close(projectAt: projectID)
                        }
                        .selectionDisabled()
                    }

                case .session(let sessionID, let projectID):
                    if let repo = store.repos.first(where: { $0.id == projectID }),
                       let session = repo.sessions.first(where: { $0.id == sessionID }) {
                        SessionRow(
                            store: store,
                            session: session,
                            isConflicted: conflicted.contains(session.id)
                        )
                        .tag(session.id)
                    }

                case .empty:
                    Text("No sessions")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
            }
            .onMove { store.moveSidebarRows(fromOffsets: $0, toOffset: $1) }
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

    private func close(projectAt id: Repo.ID) {
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )
        Task { await coordinator.requestClose(projectAt: id) }
    }
}
