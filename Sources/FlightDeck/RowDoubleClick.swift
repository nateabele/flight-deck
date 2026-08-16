import AppKit
import SwiftUI

/// Sidebar keyboard/mouse affordances that SwiftUI cannot express here: double-click-to-rename,
/// click-to-focus, and Return-to-rename.
///
/// # Why none of this is a SwiftUI gesture or a subview. Read before "simplifying".
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
/// recognizer. `hitTest -> nil` keeps the view out of AppKit's hit-test path but not out of the
/// accessibility geometry XCUITest measures — which is also why the older tracking-area
/// representable made the title unhittable 6 times out of 6.
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
/// `_SystemTextFieldFieldEditor` while a rename field is open, and `SurfaceView` — the terminal —
/// every other time, including immediately after a row is clicked. Tab does not help; the
/// terminal consumes it like any other key. A `@FocusState` on the `List` never reported true.
///
/// # What this does instead
///
/// One passive monitor, no views, no gestures, no target/action on SwiftUI's table:
///
/// - **mouse-down, `clickCount == 2`** → rename that row. `clickCount == 2` is what AppKit
///   synthesizes here and what a real double-click produces, so it works for users and the suite.
/// - **mouse-down, `clickCount == 1`, inside the sidebar table** → make the table the first
///   responder, so the sidebar can hold keyboard focus at all. This mirrors exactly what
///   `SurfaceView.localEventLeftMouseDown` already does for the terminal (it claims first
///   responder when a click hit-tests to itself), so the two panes now behave symmetrically —
///   click a pane, focus that pane, which is also how Finder and Xcode behave.
/// - **Return with the sidebar table as first responder** → rename the selected row, and consume
///   the event. Gated on the first responder, so Return still reaches the terminal whenever the
///   terminal has focus, and still commits a rename whenever the field editor has focus.
///
/// Mouse events are always returned unchanged, so nothing about row hit-testing or list dragging
/// can change. A drag begins with a `clickCount == 1` down, so dragging never renames.
@MainActor
final class SidebarInputMonitor: ObservableObject {
    private var mouseToken: Any?
    private var keyToken: Any?

    /// Rename the session at this table row index.
    var renameRow: ((Int) -> Void)?
    /// Rename whatever session is currently selected. Returns true if it acted, so the monitor
    /// knows whether to consume the key.
    var renameSelected: (() -> Bool)?

    /// `kVK_Return`. Hard-coded rather than imported from Carbon for one constant.
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
        // `NSEvent.removeMonitor` is not main-actor-isolated, so a deallocation off the main
        // actor still drops the tokens rather than leaking monitors.
        if let mouseToken { NSEvent.removeMonitor(mouseToken) }
        if let keyToken { NSEvent.removeMonitor(keyToken) }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let window = event.window, let content = window.contentView else { return }

        // `NSView.hitTest(_:)` takes a point in the RECEIVER'S SUPERVIEW coordinates; for a
        // window's `contentView` that is already `locationInWindow`, so no conversion.
        guard let hit = content.hitTest(event.locationInWindow) else { return }
        guard let (table, rowIndex) = Self.sidebarRow(under: hit) else { return }

        if event.clickCount == 2 {
            renameRow?(rowIndex)
            return
        }

        // Single click on the ALREADY-SELECTED row: take keyboard focus, so Return means
        // something here.
        //
        // Deliberately not on every click. Clicking a *different* row switches session, which
        // re-parents the terminal surface, and `TerminalPane` responds by calling
        // `Ghostty.moveFocus(to: surface)` — asynchronously, so it lands after any claim made
        // here and hands the keyboard back to the terminal anyway. Claiming focus on those
        // clicks therefore achieves nothing except a brief focus flicker, and measurably broke
        // the terminal-focused groups later in the smoke test (Copy and ⌘F both failed).
        //
        // Restricting it to the selected row means focus only moves when the click cannot be a
        // session switch, so the terminal keeps focus exactly when a user expects to keep
        // typing, and the sidebar can still be focused deliberately by clicking the row you are
        // already on.
        guard table.selectedRow == rowIndex else { return }
        if window.firstResponder !== table { window.makeFirstResponder(table) }
    }

    /// Returns true if the event was handled and should be consumed.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.keyCode == Self.returnKeyCode else { return false }
        // Any modifier means this is some other command, not a plain Return.
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        // Only when the sidebar's own table holds focus. This is what keeps Return working
        // normally in the terminal and inside the rename field editor.
        guard NSApp.keyWindow?.firstResponder is NSTableView else { return false }
        return renameSelected?() ?? false
    }

    /// Resolves a hit view to the sidebar's table and the row index under it. Read-only: nothing
    /// is attached, replaced, or reconfigured.
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
