import AppKit
import IntakeKit
import SwiftUI

/// File-menu items for session creation and renaming. All stay enabled in every state: a
/// disabled `NSMenuItem` does not fire its key equivalent, ⌘N specifically must work when
/// there are no sessions (it reroutes to Add Project), and Rename Session needs its shortcut
/// live so it can guard on the current selection internally (see the comment below).
struct SessionCommands: Commands {
    // Plain `let`, not `@ObservedObject`: no published property is read here, so observing
    // would invalidate and rebuild the menu on every unrelated `SessionStore` mutation —
    // including `applyExternalTitle` firing from the transcript watcher's 500ms poll —
    // potentially while the menu is open. The actions below close over the same
    // reference-type instance either way.
    //
    // The New Session rows are not here. They follow the current project (its agent order,
    // its resolved accounts), and a `Commands` that observed that — it used to, through
    // `CurrentProjectObserver` and `@ObservedObject preferences` — made SwiftUI reconcile the
    // main menu on every switch between two projects' tabs, removing the Tools menu each time
    // (11 removals in 10 switches, measured 2026-10-09). They are AppKit items now, placed
    // above Add Project… (`NewSessionMenuController`).
    let store: SessionStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Project…") { store.addProjectFromMenu() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }

        // Separate group from `.newItem`: renaming isn't a creation command, and this
        // keeps it visually adjacent rather than crowding the New/Add Project block.
        CommandGroup(after: .newItem) {
            // Stays enabled, guarded internally instead of `.disabled(store.selectedSessionID
            // == nil)`: `store` here is a plain `let`, not `@ObservedObject` (see the type's
            // doc comment), so a `.disabled` condition would be evaluated once at menu build
            // time and never refresh as the selection changes — the item would freeze in
            // whatever state existed when the menu was constructed. Guarding in the action
            // keeps the item live and correct without requiring observation.
            // `renamableSessionID`, not `selectedSessionID`: behind a project view the
            // selection is hidden, and ⌘R used to open a rename on a row nobody was looking at.
            Button("Rename Session") {
                guard let id = store.renamableSessionID else { return }
                store.renameRequest = id
            }
            .keyboardShortcut("r", modifiers: .command)

            // Stays enabled and guards internally, for the same reason as Rename Session
            // above: `store` is a plain `let`, so a `.disabled(...)` condition would be
            // evaluated once at menu build time and freeze there — and a disabled
            // `NSMenuItem` does not fire its key equivalent at all.
            // `reopenLastClosed` no-ops on an empty history, which is the whole guard.
            //
            // ⌘⇧T reaches this item only because `GhosttyDefaults.conf` unbinds it. Ghostty
            // binds it to `undo` on macOS and marks it `performable`, and the
            // `MenuKeyEquivalents` hand-off that saves ⌘⇧[ and ⌘⇧] deliberately does NOT
            // cover performable bindings — so while libghostty claimed this chord,
            // `Ghostty.SurfaceView.performKeyEquivalent` swallowed it and this item never
            // fired with a terminal focused. See that file's entry for the full reasoning;
            // moving the shortcut here without it is what breaks it.
            Button("Reopen Closed Session") { store.reopenLastClosed() }
                .keyboardShortcut("t", modifiers: [.command, .shift])

            // ⌘W is bound here, to the store, rather than left to AppKit's `performClose:`.
            //
            // The responder-chain route only ever worked with focus inside the terminal:
            // `TerminalHostView` implements `performClose:` and sits below the terminal pane,
            // so a focused surface reaches it — but from a focused sidebar there is nothing
            // between the sidebar and the window, `NSWindow` implements `performClose:`
            // itself, and the window claimed the key. Since closing this app's only window
            // quits it, ⌘W in the sidebar was ⌘Q.
            //
            // This item sits in the File menu ahead of the Close item SwiftUI adds for the
            // `Window` scene, and `NSMenu.performKeyEquivalent` takes the first matching
            // enabled item it walks, so this one answers ⌘W from every focus state.
            // `closeSelectedSession` reporting false is the empty state — nothing to close —
            // where the key falls through to closing the window as it always did.
            //
            // Answering ⌘W from every focus state is what this item is for, but "every focus
            // state" used to include the *other* windows: a main-menu key equivalent is
            // offered to the menu before the responder chain, so with Settings open and
            // focused ⌘W closed the session behind it instead of the window in front of it.
            // `SessionWindow.isKey` is the guard, and the fallback is the same one the empty
            // state already used — close the focused window, which is what ⌘W means anywhere
            // but here.
            //
            // With a project view up, `closeSelectedSession` closes the view instead of the
            // session hidden behind it — see that method.
            Button("Close Session") {
                guard SessionWindow.isKey else {
                    NSApp.keyWindow?.performClose(nil)
                    return
                }
                if !store.closeSelectedSession() { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }
}
