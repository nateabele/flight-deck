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
            // Leading, unlike the project header's, which stays trailing.
            //
            // The fixed minimum width is what makes that work. `SessionStatusIcon` draws
            // *nothing* for a session with no `claude` running, which on the trailing edge was
            // invisible — the row simply ended — but on the leading edge would slide that
            // row's title left and leave the sidebar's left edge ragged as sessions start and
            // stop. Reserving the column keeps every title on the same x.
            //
            // `minWidth`, not `width`: a busy session with sub-agents draws its count beside
            // the glyph, and a hard width would overlap it onto the title. That row's title
            // shifts right by the width of the numeral, which is the one case where alignment
            // gives — deliberately, since clipping the count would be worse.
            SessionStatusIcon(
                status: store.status(for: session.id),
                unread: store.unreadIdle.contains(session.id)
            )
            .frame(minWidth: 16, alignment: .leading)

            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .accessibilityIdentifier("session-title-field")
                    .onSubmit(commit)
                    .onExitCommand {                      // Esc
                        isEditing = false
                        store.renamingSessionID = nil
                    }
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
                // Double-click-to-rename is back, and nothing about it lives in this row.
                // `SidebarInputMonitor` (see `SidebarInputMonitor.swift`) watches `.leftMouseDown`
                // from outside the view hierarchy entirely and maps the click to a row itself.
                // Putting ANY `NSView` here — even one whose `hitTest(_:)` returns nil — makes
                // this `Text` unhittable, which was measured at 5 of 5 smoke runs; a gesture
                // recognizer on the table view never fires, because the synthetic double-click
                // delivers no mouse-ups. Rename is also reachable from the context menu and
                // from Return.
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
            // Absent rather than hidden until hover, as it always was — but the reason has
            // changed with the status icon's move. It used to be that inserting the button is
            // what pushed the status icon left, so no manual offset was needed. The icon is on
            // the leading edge now and nothing trails it but the conflict marker, so this is
            // simply a destructive control kept out of the way until pointed at — the same
            // rule `ProjectHeaderRow`'s close button follows.
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
        // `Text`) — double-click is detected by `SidebarInputMonitor`, which adds nothing to
        // this row at all, so the specific breakage described below is not reachable through
        // it. What survives is the finding about `.contentShape` on this HStack, and the two
        // rejected alternatives — one of which, the `NSViewRepresentable`, was re-confirmed
        // the hard way on this branch: it makes the title unhittable even when its `hitTest`
        // returns nil.
        //
        // Hover is tracked without putting `.contentShape(Rectangle())` + `.onHover` on the
        // HStack itself. Applied to the HStack, that pair joins SwiftUI's hit-testing for the
        // row and competed with the title's `.onTapGesture`: it intermittently swallowed the
        // second click of a double click, so the rename detector never saw one. Measured at
        // 4 failures in 5 runs of `testDoubleClickRenamesSession` (a test from the
        // hand-rolled-detector era; it no longer exists — double-click is now covered by
        // the AppKit-recognizer tests in `TerminalSmokeTests.swift`), against 9/9 before
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
        // Nothing here detects the double-click. It arrives as a `renameRequest` from the
        // sidebar-level event monitor below, for the same reason the title carries no tap
        // recognizer: anything added to a row breaks either the drag or the row's
        // hit-testing. See `SidebarInputMonitor.swift`.
        .onChange(of: store.renameRequest) { _, request in
            guard request == session.id else { return }
            // Clear before the `isEditing` check, not after: a request addressed to this
            // row must always be consumed, even when it arrives while the row is already
            // editing and there is nothing left to do. Combining these into one guard (as
            // a "simplification") skips the clear whenever `isEditing` is true, which
            // leaves `renameRequest` stuck non-nil forever — the Return path guards on
            // `renameRequest == nil`, so that permanently and silently kills
            // Return-to-rename for the rest of the session.
            store.renameRequest = nil
            guard !isEditing else { return }
            beginRename()
        }
        // Teardown safety net. `renamingSessionID` is otherwise only ever cleared from inside
        // this row (commit, Esc, focus loss), so a row destroyed MID-EDIT would strand it — and
        // the Return path refuses to fire while it is set, which would silently kill
        // Return-to-rename for the rest of the process. Reachable: ⌘W closes the session from a
        // menu key equivalent without any focus change, and `observeSurfaceClose` closes a
        // session asynchronously when its shell exits. Whether SwiftUI delivers `focused ->
        // false` during teardown is not something worth betting the feature on.
        .onDisappear { if isEditing { store.renamingSessionID = nil } }
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
    /// Double-click is back today, but nothing detects it inside this row: `SidebarInputMonitor`
    /// (`SidebarInputMonitor.swift`) observes `.leftMouseDown` from outside the view hierarchy and
    /// maps the click to a row itself, so the row gains neither a gesture nor a subview.
    /// `.onTapGesture(count: 2)` and `.simultaneousGesture` are still wrong here for the same
    /// reason they always were, and an `NSViewRepresentable` is worse — do not "simplify" this
    /// back to any of them.
    ///
    /// Selecting first is deliberate: renaming a row should also make it the active one.
    private func beginRename() {
        store.selectedSessionID = session.id
        draft = session.title
        isEditing = true
        focused = true
        // Publish that a field is open so the sidebar's Return handler stands down. See the
        // note on `renamingSessionID` in the store for the bug this fixes.
        store.renamingSessionID = session.id
    }

    /// Empty input reverts: `rename` ignores it and we simply leave edit mode.
    private func commit() {
        guard isEditing else { return }
        isEditing = false
        store.renamingSessionID = nil
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

    /// Owns the sidebar's input monitor. `@StateObject` rather than a fresh instance per
    /// render: the monitor holds `NSEvent` tokens that must be installed once and removed once,
    /// and a value recreated on every body evaluation would leak monitors.
    ///
    /// There is deliberately no `@FocusState` here. Measured: `.focused($flag)` on a `List`
    /// never reported true — the terminal `SurfaceView` holds first responder and neither a
    /// click nor Tab moves it — so anything gated on it was dead on arrival. The monitor works
    /// from the real first responder instead.
    @State private var input = SidebarInputMonitor()

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
        // Double-click-to-rename. The monitor reports a table row index; `sidebarRows` is the
        // same flat array the `ForEach` above renders, so the index maps straight back to a
        // row. Bounds-checked because the index comes from AppKit, not from us, and a
        // non-session row (a project header, or the empty placeholder) is simply ignored.
        // Double-click renames the row under the pointer; Return renames the selected row
        // once the sidebar holds focus. Both live in `SidebarInputMonitor` because neither can
        // be expressed here — see `SidebarInputMonitor.swift` for the four mechanisms measured and
        // the three that failed.
        //
        // The `renameSelected` guard is why a selected-but-invisible session cannot strand a
        // request: a selected session need not be rendered, because collapsing its project
        // (`SessionStore.setCollapsed`) does not clear selection and `cycleSelection` (⌘⇧[/⌘⇧])
        // walks every session regardless of whether its project is collapsed. Returning false
        // there also leaves the key unconsumed, so Return still reaches whatever else wants it.
        .sidebarInputMonitor(
            input,
            renameRow: { index in
                guard index >= 0, index < store.sidebarRows.count else { return }
                guard case .session(let id, _) = store.sidebarRows[index] else { return }
                // The same one-shot channel the Return path uses, so all three rename entry
                // points converge on `SessionRow`'s single consumer.
                store.renameRequest = id
            },
            renameSelected: {
                guard let selected = store.selectedSessionID,
                      store.renameRequest == nil,
                      // A rename field being open is the case first-responder checks cannot
                      // fully cover; without this the Return that COMMITS a rename would be
                      // eaten here instead.
                      store.renamingSessionID == nil,
                      store.sidebarRows.contains(where: { row in
                          if case .session(let id, _) = row { return id == selected }
                          return false
                      })
                else { return false }
                store.renameRequest = selected
                return true
            }
        )
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
