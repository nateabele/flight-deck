import AppKit
import SwiftUI

/// Sidebar mouse/keyboard affordances that SwiftUI cannot express here: double-click-to-rename,
/// click-to-focus, and Return-to-rename.
///
/// # Four mechanisms were measured. Three are dead. Read this before "simplifying".
///
/// **1. A SwiftUI tap recognizer on the row breaks drag-to-reorder.**
/// `NSClickGestureRecognizer` overrides `NSGestureRecognizer`'s pass-through default and
/// withholds the mouse-down until recognition fails. From `NSGestureRecognizer.h`: *"causes the
/// specified events to be delivered to the target view only after this gesture has failed
/// recognition… refer to specific gesture subclasses as they have different defaults"* —
/// `delaysPrimaryMouseButtonEvents` defaults to `NO` on the base class, but
/// `NSClickGestureRecognizer.h` says it *"dynamically returns YES to delay primary, secondary
/// and other mouse events depending on this value"*. `List`'s reorder is AppKit-level and needs
/// that mouse-down. `.onTapGesture(count: 2)` and `.simultaneousGesture` are the same recognizer
/// twice; both measured, both blocked the drag (commit `b18b86a`).
///
/// **2. An `NSViewRepresentable` in the row breaks hit-testing, even with `hitTest(_:) -> nil`.**
/// Measured: 5 of 5 smoke runs died at the pre-existing "clicking a row's title selects it"
/// assertion — `Not hittable: StaticText, …, identifier: 'session-row-title'`. Isolated in two
/// steps: disabling the modifier made it pass, and keeping the view while never attaching a
/// recognizer still failed. It is the **presence of an `NSView` in the row**, not the
/// recognizer. `hitTest -> nil` keeps a view out of AppKit's hit-test path but not out of the
/// accessibility geometry XCUITest measures — the same cause as the older tracking-area finding.
///
/// **3. A gesture recognizer on the table view never fires.** It attaches correctly
/// (instrumentation confirmed one live on SwiftUI's `SwiftUIOutlineListView` with the right row
/// count) but never recognizes, because a click gesture needs a complete down-up cycle and the
/// synthetic double-click delivers no ups at all:
///
///     probe DOWN cc=1 t=357898.889
///     probe DOWN cc=2 t=357899.038
///
/// **4. `.onKeyPress(.return)` on the `List` never fires**, because the sidebar never holds
/// keyboard focus. Measured by logging the first responder on every Return: it is
/// `_SystemTextFieldFieldEditor` while a rename field is open and `SurfaceView` — the terminal —
/// every other time, including immediately after a row is clicked. Tab does not help; the
/// terminal consumes it. A `@FocusState` on the `List` never reported true.
///
/// # What this does instead
///
/// One passive monitor, no views, no gestures, no target/action on SwiftUI's table:
///
/// - **mouse-down, `clickCount == 2`** → rename that row. `clickCount == 2` is what AppKit
///   synthesizes here and what a real double-click produces, so it works for users and the suite.
/// - **mouse-down, `clickCount == 1`, on the already-selected row** → make the table first
///   responder, so the sidebar can hold keyboard focus at all. This mirrors what
///   `SurfaceView.localEventLeftMouseDown` already does for the terminal. It is restricted to the
///   selected row because clicking a *different* row switches session, which re-parents the
///   surface and makes `TerminalPane` asynchronously call `Ghostty.moveFocus(to:)` — claiming
///   focus there achieves nothing but a flicker, and measurably broke the Copy and ⌘F groups.
/// - **Return with the sidebar table as first responder** → rename the selected row, consuming
///   the key. Gated on the first responder, so Return still reaches the terminal and still
///   commits an open rename field.
///
/// Mouse events are always returned unchanged, so row hit-testing and list dragging cannot
/// change. A drag begins with a `clickCount == 1` down, so dragging never renames.
///
/// # Scoping: this monitor is app-wide, so it must prove which table it is looking at
///
/// `NSEvent.addLocalMonitorForEvents` sees every event in the process, and this app has more
/// than one `NSTableView`: Settings ▸ Projects is a second SwiftUI `List`, and `NSOpenPanel`
/// (used by "Add Project", and in-process because the app is unsandboxed) is table-backed too.
/// Without a scope check, double-clicking a folder in the open panel would map a row index onto
/// `sidebarRows` and rename an unrelated session, and Return in Settings would be swallowed.
/// So every path asks `SessionWindow` whether the event landed in the session window — Settings
/// and the open panel carry different identifiers and are excluded outright.
///
/// **The scope check is asked per event, and must stay that way.** It used to be a window
/// captured once at `start()` from `NSApp.keyWindow ?? NSApp.mainWindow`, retried for two
/// seconds and then abandoned. Both of those properties are nil for as long as the app is
/// inactive, so an app launched in the background — every `scripts/swap-release.sh` relaunch —
/// captured nothing and compared every later event against nil. The monitor stayed installed
/// and silently matched nothing for the life of the process: double-click-to-rename dead,
/// and Return-to-rename with it, since Return is only reachable once the mouse path has made
/// the table first responder. Rename via the context menu still worked, which is what made it
/// read as a rename bug rather than a monitor bug. See `SessionWindow`.
@MainActor
final class SidebarInputMonitor {
    private var mouseToken: Any?
    private var keyToken: Any?

    /// Rename the session at this table row index.
    var renameRow: ((Int) -> Void)?
    /// Rename whatever session is currently selected. Returns true if it acted, so the monitor
    /// knows whether to consume the key.
    var renameSelected: (() -> Bool)?

    /// `kVK_Return`. Hard-coded rather than importing Carbon for one constant.
    private static let returnKeyCode: UInt16 = 36

    func start() {
        if mouseToken == nil {
            mouseToken = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.handleMouseDown(event)
                return event   // never consumed — see the doc comment
            }
        }
        if keyToken == nil {
            keyToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handleKeyDown(event) else { return event }
                return nil     // consumed: the sidebar had focus and acted on Return
            }
        }
    }

    func stop() {
        if let mouseToken { NSEvent.removeMonitor(mouseToken) }
        if let keyToken { NSEvent.removeMonitor(keyToken) }
        mouseToken = nil
        keyToken = nil
    }

    deinit {
        // Hop to the main actor rather than removing inline: `removeMonitor` is an AppKit call
        // and belongs on the main thread. A `@StateObject` is released on main in practice, but
        // "in practice" is not a reason to make the unsafe call the documented one.
        let (mouse, key) = (mouseToken, keyToken)
        if mouse != nil || key != nil {
            DispatchQueue.main.async {
                if let mouse { NSEvent.removeMonitor(mouse) }
                if let key { NSEvent.removeMonitor(key) }
            }
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        // Scope check first: Settings ▸ Projects and `NSOpenPanel` are table-backed too.
        // `hitView` answers nil for both, so nothing below can act on their rows.
        guard let window = event.window, let hit = SessionWindow.hitView(for: event) else { return }
        guard let (table, rowIndex) = Self.sidebarRow(under: hit) else { return }

        if event.clickCount == 2 {
            renameRow?(rowIndex)
            return
        }

        // Never steal focus from an open text editor. A rename field's row IS the selected row
        // (`beginRename` selects it), so without this a click inside the field would satisfy the
        // guard below, pull first responder to the table, and the resulting focus loss would
        // commit the rename — making it impossible to click, drag-select, or double-click a word
        // inside the field you are editing. `NSTextView` (the field editor) is an `NSText`.
        guard !(window.firstResponder is NSText) else { return }

        // Single click on the already-selected row: take keyboard focus, so Return means
        // something here. See the doc comment for why this is not done on every click.
        guard table.selectedRow == rowIndex else { return }
        if window.firstResponder !== table { window.makeFirstResponder(table) }
    }

    /// Returns true if the event was handled and should be consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.returnKeyCode else { return false }
        // Any modifier means this is some other command, not a plain Return.
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        // Same scope check as the mouse path: only the session window.
        guard let window = NSApp.keyWindow, SessionWindow.isSessionWindow(window) else { return false }
        // Only when a table holds focus. This is what keeps Return working normally in the
        // terminal and inside the rename field editor.
        guard window.firstResponder is NSTableView else { return false }
        return renameSelected?() ?? false
    }

    /// Resolves a hit view to its table and the row index under it. Read-only: nothing is
    /// attached, replaced, or reconfigured.
    private static func sidebarRow(under view: NSView) -> (NSTableView, Int)? {
        var candidate: NSView? = view
        while let current = candidate, !(current is NSTableRowView) { candidate = current.superview }
        guard let rowView = candidate as? NSTableRowView else { return nil }

        var tableCandidate: NSView? = rowView.superview
        while let current = tableCandidate, !(current is NSTableView) { tableCandidate = current.superview }
        guard let table = tableCandidate as? NSTableView else { return nil }

        let index = table.row(for: rowView)
        guard index >= 0 else { return nil }
        return (table, index)
    }
}

extension View {
    /// Installs the sidebar input monitor for the lifetime of this view. Applied to the
    /// sidebar's `List`, never to a row — see the file's doc comment for why nothing may go
    /// inside a row.
    func sidebarInputMonitor(
        _ monitor: SidebarInputMonitor,
        renameRow: @escaping (Int) -> Void,
        renameSelected: @escaping () -> Bool
    ) -> some View {
        self
            .onAppear {
                monitor.renameRow = renameRow
                monitor.renameSelected = renameSelected
                monitor.start()
            }
            .onDisappear { monitor.stop() }
    }
}
