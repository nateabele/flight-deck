import AppKit
import SwiftUI

/// Sidebar mouse/keyboard affordances that SwiftUI cannot express here: double-click-to-rename,
/// click-to-focus, click-to-collapse, and Return-to-rename.
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
/// - **mouse-down, `clickCount == 1`, that turns out not to have been a drag** → toggle that
///   project header's collapse state. The "turns out" is the whole trick; see below.
///
/// Mouse events are always returned unchanged, so row hit-testing and list dragging cannot
/// change. A drag begins with a `clickCount == 1` down, so dragging never renames.
///
/// # Click-to-collapse: why there is no mouse-up handler
///
/// The whole project-header row toggles on a click and reorders on a drag. Both begin with the
/// same mouse-down, and nothing here may consume it, so the two can only be told apart *after
/// the fact*. The obvious way to do that — widen the monitor's mask to `.leftMouseUp` and
/// compare the two points — **does not work, and was measured not to work**:
///
///     [plain SwiftUI view]  DOWN seen, UP seen
///     [List row, .onMove ]  DOWN seen, UP NEVER SEEN
///     [List row, no .onMove] DOWN seen, UP seen
///
/// A reorder-capable `NSTableView` runs a nested tracking loop from inside its `mouseDown:`,
/// pulling events straight off the queue with `nextEventMatchingMask:` until the button comes
/// up. Local monitors are invoked from `NSApplication.sendEvent`, which that loop bypasses
/// entirely, so the up is consumed where no monitor can see it. It is `.onMove` that turns the
/// loop on — which is exactly the feature this row must not break, so it cannot be given up.
///
/// What *is* observable is the loop **ending**: schedule a block for `NSDefaultRunLoopMode`
/// only, and it cannot run until the run loop leaves `NSEventTrackingRunLoopMode`. Measured on
/// the same probe, against a click held for 100ms:
///
///     1574.7ms [?]                        monitor DOWN
///     1575.8ms [NSEventTrackingRunLoopMode]   DispatchQueue.main.async ran   ← during, useless
///     1677.8ms [NSEventTrackingRunLoopMode]   button released
///     1680.6ms [kCFRunLoopDefaultMode]        RunLoop.perform(inModes:) ran  ← after
///
/// So the down records where it started and asks to be called back once the click is over, and
/// the callback reads `NSEvent.mouseLocation` for where it ended. `DispatchQueue.main.async` is
/// **not** interchangeable here: `NSEventTrackingRunLoopMode` is a common mode, so it runs
/// mid-drag with the button still down, and everything would toggle.
///
/// `SidebarClickIntent` holds the decision itself, over plain numbers, so it is testable without
/// a window. Its travel threshold is belt and braces rather than the load-bearing check: a real
/// drag both exceeds it *and* usually ends with the pointer on another row entirely. The
/// threshold catches what is left — a press that wobbles a point or two and never drags at all.
///
/// The hover-revealed close button is excluded **by geometry, not by a hit-test walk**, and that
/// is the one place this file departs from the idiom in `sidebarRow(under:)` and
/// `ToolOverlayInputMonitor.isOverTerminal`. A probe ruled the walk out: SwiftUI backs the row
/// with a single `NSHostingView` whose `hitTest` returns *itself* even directly over the
/// `SwiftUIAppKitButton` it creates for that button, so `SessionWindow.hitView(for:)` cannot tell
/// the X from the project name. The fallback measures the down point against the trailing edge of
/// the `NSTableRowView` this monitor already resolves — no geometry is plumbed out of SwiftUI.
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
    /// Toggle the collapse state of the row at this table row index. Every row is reported, not
    /// just project headers — this monitor has no model of what a row is — so the caller is what
    /// makes a click on a session row a no-op. See `SessionSidebar`.
    var toggleRow: ((Int) -> Void)?

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
        guard let (table, rowView, rowIndex) = Self.sidebarRow(under: hit) else { return }

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

        // Ask to be called back once this click is over, so it can be told apart from a drag.
        // Deliberately *after* the field-editor guard above — so a click inside an open rename
        // field can never collapse a project — and deliberately *before* the selected-row guard
        // below, which returns early on every row but one. `clickCount == 1` only: a
        // double-click would otherwise toggle on its first click and again on its second, and
        // read as having done nothing.
        if event.clickCount == 1 {
            scheduleToggleDecision(
                window: window, rowView: rowView, rowIndex: rowIndex,
                downPoint: event.locationInWindow, clickCount: event.clickCount
            )
        }

        // Single click on the already-selected row: take keyboard focus, so Return means
        // something here. See the doc comment for why this is not done on every click.
        guard table.selectedRow == rowIndex else { return }
        if window.firstResponder !== table { window.makeFirstResponder(table) }
    }

    /// The second half of click-to-collapse, scheduled for after the table's drag-tracking loop
    /// returns — which is the earliest moment this monitor can know a click was not a drag. See
    /// the doc comment for the measurements behind both halves.
    ///
    /// Everything the decision needs is captured as a number here, while the down's view tree is
    /// still the one under the pointer: by the time the block runs the list may have scrolled,
    /// reordered, or lost the window entirely.
    private func scheduleToggleDecision(
        window: NSWindow,
        rowView: NSTableRowView,
        rowIndex: Int,
        downPoint: NSPoint,
        clickCount: Int
    ) {
        // Screen coordinates, because that is the space the answer arrives in: the block reads
        // `NSEvent.mouseLocation`, and a reorder can slide the rows under the pointer in between.
        let downOnScreen = window.convertPoint(toScreen: downPoint)
        let distanceFromTrailingEdge = rowView.bounds.maxX - rowView.convert(downPoint, from: nil).x

        // `.default` ONLY. A block that also listed `.eventTracking` — or a
        // `DispatchQueue.main.async`, which effectively does, since event tracking is a common
        // mode — runs mid-press with the button still down, and every drag would toggle.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                self?.finishToggleDecision(
                    downOnScreen: downOnScreen, downRow: rowIndex,
                    distanceFromTrailingEdge: distanceFromTrailingEdge, clickCount: clickCount
                )
            }
        }
    }

    private func finishToggleDecision(
        downOnScreen: NSPoint,
        downRow: Int,
        distanceFromTrailingEdge: CGFloat,
        clickCount: Int
    ) {
        // Resolved again rather than captured, the same rule the rest of this file follows: the
        // window may have closed while the button was held. `NSEvent.mouseLocation` is where the
        // pointer is *now*, which — the tracking loop having just returned — is where it was
        // released.
        guard let window = SessionWindow.main else { return }
        let upOnScreen = NSEvent.mouseLocation
        guard let hit = SessionWindow.hitView(
            inWindow: window, at: window.convertPoint(fromScreen: upOnScreen)
        ), let (_, _, upRow) = Self.sidebarRow(under: hit) else { return }

        guard SidebarClickIntent.togglesCollapse(
            downPoint: downOnScreen,
            upPoint: upOnScreen,
            downRow: downRow,
            upRow: upRow,
            clickCount: clickCount,
            downDistanceFromTrailingEdge: distanceFromTrailingEdge
        ) else { return }
        toggleRow?(downRow)
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

    /// Resolves a hit view to its table, the row view, and the row index under it. Read-only:
    /// nothing is attached, replaced, or reconfigured. The row view comes back because the
    /// close-button exclusion is measured against its trailing edge — it is the only geometry
    /// the click rule needs, and it is AppKit's, not SwiftUI's.
    private static func sidebarRow(under view: NSView) -> (NSTableView, NSTableRowView, Int)? {
        var candidate: NSView? = view
        while let current = candidate, !(current is NSTableRowView) { candidate = current.superview }
        guard let rowView = candidate as? NSTableRowView else { return nil }

        var tableCandidate: NSView? = rowView.superview
        while let current = tableCandidate, !(current is NSTableView) { tableCandidate = current.superview }
        guard let table = tableCandidate as? NSTableView else { return nil }

        let index = table.row(for: rowView)
        guard index >= 0 else { return nil }
        return (table, rowView, index)
    }
}

/// Click, or drag? The whole rule, over plain numbers — no `NSEvent`, no view, no window — so it
/// can be exercised by `scripts/test-unit.sh`, which runs the `xctest` binary with no GUI host.
///
/// `SidebarInputMonitor` owns the two events this decides between; see its doc comment for why
/// the decision has to be made after the fact rather than by consuming the mouse-down.
enum SidebarClickIntent {
    /// How far the mouse may travel between press and release and still count as a click.
    ///
    /// Belt and braces, not the load-bearing check: a real reorder drag both exceeds this *and*
    /// usually ends over a different row, which is rejected on its own. This catches what is
    /// left — a press that wobbles a point or two without ever starting a drag.
    static let dragThreshold: CGFloat = 4.0

    /// The trailing strip of a row that never toggles, reserved for the hover-revealed close
    /// button.
    ///
    /// Geometry rather than a hit-test walk because a probe ruled the walk out: SwiftUI backs the
    /// row with one `NSHostingView`, and its `hitTest` returns *itself* even directly over the
    /// `SwiftUIAppKitButton` created for the close button, so the hit view cannot tell the X from
    /// the project name.
    ///
    /// 32 rather than the button's own ~15pt width: the row's trailing inset and the button's
    /// slop sit inside it. Over-reserving costs a strip of row that does not toggle;
    /// under-reserving collapses a project on the way to closing it.
    static let closeButtonExclusion: CGFloat = 32.0

    /// Whether a press/release pair should toggle the row it landed on.
    ///
    /// The two points only have to share a coordinate space — the caller passes screen points.
    /// `downDistanceFromTrailingEdge` is the press point's distance from the trailing edge of the
    /// row view, in the row's own coordinates.
    static func togglesCollapse(
        downPoint: CGPoint,
        upPoint: CGPoint,
        downRow: Int,
        upRow: Int,
        clickCount: Int,
        downDistanceFromTrailingEdge: CGFloat
    ) -> Bool {
        guard clickCount == 1, downRow == upRow else { return false }
        guard downDistanceFromTrailingEdge > closeButtonExclusion else { return false }
        return hypot(upPoint.x - downPoint.x, upPoint.y - downPoint.y) < dragThreshold
    }
}

extension View {
    /// Installs the sidebar input monitor for the lifetime of this view. Applied to the
    /// sidebar's `List`, never to a row — see the file's doc comment for why nothing may go
    /// inside a row.
    func sidebarInputMonitor(
        _ monitor: SidebarInputMonitor,
        renameRow: @escaping (Int) -> Void,
        renameSelected: @escaping () -> Bool,
        toggleRow: @escaping (Int) -> Void
    ) -> some View {
        self
            .onAppear {
                monitor.renameRow = renameRow
                monitor.renameSelected = renameSelected
                monitor.toggleRow = toggleRow
                monitor.start()
            }
            .onDisappear { monitor.stop() }
    }
}
