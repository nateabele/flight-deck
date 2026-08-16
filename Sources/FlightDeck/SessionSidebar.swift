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
                // The title carries no *SwiftUI* tap recognizer of any kind, and that is
                // still the point.
                //
                // Rename used to start from a hand-rolled double-click detector attached here.
                // It had to go: ANY SwiftUI tap recognizer on this text consumes the
                // mouse-down that `List`'s `.onMove` needs to begin a drag, so a row could not
                // be dragged by the one part of it people actually aim at. Measured in the
                // smoke test — with the recognizer present the drag group fails and the
                // control group (dragging blank row space) passes; with it removed both pass.
                // Exclusive and `simultaneousGesture` variants were both tried and both
                // blocked the drag.
                //
                // Double-click-to-rename is back, but it does not go through SwiftUI: see
                // `.onRowDoubleClick` below, which attaches an AppKit
                // `NSClickGestureRecognizer` to an ancestor view with
                // `delaysPrimaryMouseButtonEvents` hard-coded to `false`, so the mouse-down
                // still reaches the table view immediately and the drag survives. See
                // `RowDoubleClick.swift` for the SDK-header evidence. Rename is also reachable
                // from the row's context menu and from Return.
                Text(session.title)
                    .accessibilityIdentifier("session-row-title")
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
        // HISTORICAL, and kept because it still constrains what may be added here. The
        // conflict below was between the row's hit-testing and the title's own *SwiftUI* tap
        // recognizer; that recognizer is gone from the title now (see the note on the title
        // `Text`) — replaced by the AppKit recognizer in `RowDoubleClick.swift`, which is
        // attached to an ancestor view and deliberately kept out of this HStack's SwiftUI
        // hit-testing, so the specific breakage described below is not reachable through it.
        // What survives is the finding about `.contentShape` on this HStack, and the two
        // rejected alternatives.
        //
        // Hover is tracked without putting `.contentShape(Rectangle())` + `.onHover` on the
        // HStack itself. Applied to the HStack, that pair joins SwiftUI's hit-testing for the
        // row and competed with the title's `.onTapGesture`: it intermittently swallowed the
        // second click of a double click, so the rename detector never saw one. Measured at
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
        .onRowDoubleClick { beginRename() }
        .onChange(of: store.renameRequest) { _, request in
            guard request == session.id else { return }
            // Clear before the `isEditing` check, not after: a request addressed to this
            // row must always be consumed, even when it arrives while the row is already
            // editing and there is nothing left to do. Combining these into one guard (as
            // a "simplification") skips the clear whenever `isEditing` is true, which
            // leaves `renameRequest` stuck non-nil forever — `.onKeyPress(.return)` guards
            // on `renameRequest == nil`, so that permanently and silently kills
            // Return-to-rename for the rest of the session.
            store.renameRequest = nil
            guard !isEditing else { return }
            beginRename()
        }
        // A context menu is safe where a tap gesture is not: it responds to a right-click and
        // leaves the primary mouse-down — the one `List`'s drag-to-reorder needs — untouched.
        .contextMenu {
            Button("Mark as Unread") { store.markUnread(session.id) }
                .accessibilityIdentifier("session-mark-unread")
            Divider()
            Button("Rename") { beginRename() }
            Button("Close Session") { store.closeSession(session.id) }
        }
    }

    /// Swaps the title for the edit field. Reached from the row's context menu, a
    /// double-click, and Return (via `SessionStore.renameRequest`).
    ///
    /// This replaced a hand-rolled double-click detector on the title text. The history is
    /// worth keeping, because it rules out the fixes that look obvious: an exclusive
    /// `onTapGesture(count: 2)` swallows the single click so the row never reaches the
    /// enclosing `List(selection:)` and will not select; pairing count-2 with count-1 leaves
    /// the count-1 recognizer never firing at all; and detecting the second click by hand
    /// worked for rename but blocked `List`'s drag-to-reorder, because ANY *SwiftUI* tap
    /// recognizer here consumes the mouse-down the drag needs. Both the exclusive and the
    /// `simultaneousGesture` forms were measured against the smoke test and both blocked it.
    /// Double-click is back today via `.onRowDoubleClick` above, but that works precisely
    /// because it is not a SwiftUI recognizer: it is an AppKit
    /// `NSClickGestureRecognizer` with `delaysPrimaryMouseButtonEvents` hard-coded to
    /// `false` (see `RowDoubleClick.swift`), so the primary mouse-down still reaches the
    /// table view immediately. `.onTapGesture(count: 2)` and `.simultaneousGesture` are
    /// still wrong here for the same reason they always were — do not "simplify" this back
    /// to either of them.
    ///
    /// Selecting first is deliberate: renaming a row should also make it the active one.
    private func beginRename() {
        store.selectedSessionID = session.id
        draft = session.title
        isEditing = true
        focused = true
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

    /// Whether the `List` itself (not a row's text field) currently holds keyboard focus.
    /// Gates `.onKeyPress(.return)` below so Return-to-rename cannot fire while, say, a
    /// rename `TextField` or some other control owns focus.
    @FocusState private var sidebarFocused: Bool

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
        .focused($sidebarFocused)
        // Return starts a rename on the selected row, but only when the sidebar itself has
        // focus (not, say, a rename `TextField`, which handles its own Return via
        // `.onSubmit`) and there is a session to rename and no rename request is already in
        // flight. Any other case returns `.ignored` so Return still reaches whatever else
        // wants it.
        .onKeyPress(.return) {
            guard sidebarFocused,
                  let selected = store.selectedSessionID,
                  store.renameRequest == nil
            else { return .ignored }
            store.renameRequest = selected
            return .handled
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
