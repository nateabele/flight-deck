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
///     [plain SwiftUI view, key + active]   DOWN seen, UP seen
///     [List row,           key + active]   DOWN seen, UP NEVER SEEN
///     [List row,       window never key]   DOWN seen, UP seen
///
/// `NSTableView` runs a nested tracking loop from inside its `mouseDown:`, pulling events
/// straight off the queue with `nextEventMatchingMask:` until the button comes up. Local
/// monitors are invoked from `NSApplication.sendEvent`, which that loop bypasses entirely, so
/// the up is consumed where no monitor can see it.
///
/// **The loop is not something the sidebar opts into, and nothing here can opt out of it.**
/// `.onMove` does not cause it (measured with and without: identical, both swallow the up), and
/// `.selectionDisabled()` — which every project header carries — does not avoid it either. The
/// only condition that correlated across every variant was the window being key and the app
/// active, which the real sidebar always is. So dropping reorder, or selection, would not bring
/// the mouse-up back; there is nothing to trade away here.
///
/// What *is* observable is the loop **ending**: a block scheduled for `NSDefaultRunLoopMode`
/// only cannot run until the run loop leaves `NSEventTrackingRunLoopMode`. Measured against a
/// press held 100ms on a `.selectionDisabled()` row, key and active, with the release marked:
///
///       0.0ms [kCFRunLoopDefaultMode] window isKey=true app active=true
///       0.7ms [-]                     monitor DOWN cc=1 rowResolved=true
///       1.7ms [NSEventTrackingRunLoopMode]   DispatchQueue.main.async ran  ← during, useless
///     104.3ms [NSEventTrackingRunLoopMode] RELEASING (posting the up now)
///     107.8ms [kCFRunLoopDefaultMode]   RunLoop.perform(inModes:) ran      ← after the release
///
/// So the down records where the press started and asks to be called back once it is over; the
/// callback reads `NSEvent.mouseLocation` for where it ended. `DispatchQueue.main.async` is
/// **not** interchangeable here: `NSEventTrackingRunLoopMode` is a common mode, so it runs
/// mid-press with the button still down, and every drag would toggle.
///
/// `SidebarClickIntent` holds the decision itself, over plain numbers, so it is testable without
/// a window. Its travel threshold is belt and braces rather than the load-bearing check: a real
/// drag both exceeds it *and* usually ends with the pointer on another row entirely. The
/// threshold catches what is left — a press that wobbles a point or two and never drags at all.
///
/// # Excluding the close button, by its own frame
///
/// A hit-test walk UP from the event cannot tell the hover-revealed X from the project name:
/// SwiftUI backs the row with one `NSHostingView`, and its `hitTest` returns *itself* even at
/// the button's exact center (probed). That is why this one decision departs from the idiom in
/// `sidebarRow(under:)` and `ToolOverlayInputMonitor.isOverTerminal`.
///
/// Walking DOWN does work, and needs no geometry plumbed out of SwiftUI and no reserved strip of
/// guessed width. The button is a real `NSView` in the row's subtree with a real frame, and
/// SwiftUI backs it with an `NSButton`. So the exclusion is that control's actual frame: exact,
/// and still right if a project header ever gains a second control.
///
/// **In a project-header row that button is the only `NSControl`** — everything else there, the
/// chevron, the name, the collapsed session count, the status icon and the background-work
/// badge, is drawn by SwiftUI, and a collapsed header's busy spinner is an `NSProgressIndicator`,
/// an `NSView` and not an `NSControl`. That is not true of the sidebar's other rows, and
/// `pressedControl` is asked about every row this monitor sees: a **session** row carries its own
/// borderless close button, and a `TextField` while it is being renamed, both `NSControl`
/// subclasses. Neither can cause a wrong toggle, but for reasons outside this function —
/// `SessionSidebar`'s `toggleRow` drops anything that is not `case .project`, and an open rename
/// field never reaches the scheduler at all, because the first-responder guard in
/// `handleMouseDown` returns before it. The false positive is real; it is simply always caught
/// downstream.
///
/// `.accessibilityIdentifier("close-project")` would have been the more pointed match and was
/// tried first: it does not reach the `NSView`. SwiftUI serves accessibility from its own element
/// tree, and every `accessibilityIdentifier()` under a row reads empty.
///
/// The button is in the tree only while the row is hovered, which is exactly when it can be
/// clicked. Counted directly — `NSControl`s under one row across the three states — it is
/// **removed and not merely hidden**, so there is no permanent dead strip to filter for:
///
///     never hovered: 0, hovered: 1, un-hovered again: 0
///
/// When it is absent nothing is excluded, which is correct: a button that is not in the tree is
/// not on screen and cannot have been the target.
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
    /// The identity of the row at this table index — `SidebarRow.id`, supplied by the caller for
    /// the same reason as above. Click-to-collapse decides a press-duration after it began, and
    /// a bare index does not survive that: sessions come and go asynchronously here, so a row
    /// removed above the pointer shifts everything below it up one, and the index pressed would
    /// then name a different project. Identity is what is compared instead.
    var rowIdentity: ((Int) -> String?)?

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
        // below, which returns early on every row but one.
        //
        // `clickCount == 1` is the only value that reaches the scheduler, so a real double-click
        // resolves like this: the first down (cc=1) schedules, and toggles once when the button
        // comes up; the second (cc=2) goes to `renameRow` above, which guards `case .session`
        // and no-ops on a project header. Net effect, one toggle — which is the right answer,
        // but nobody should have to derive it. The rule keeps its own `clickCount` guard anyway,
        // because a pure rule should be total over its inputs rather than rely on this call site.
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
    /// Everything the decision needs is resolved here, while the press's own view tree is still
    /// the one under the pointer: by the time the block runs the list may have scrolled,
    /// reordered, or lost the window entirely.
    private func scheduleToggleDecision(
        window: NSWindow,
        rowView: NSTableRowView,
        rowIndex: Int,
        downPoint: NSPoint,
        clickCount: Int
    ) {
        // A row the caller cannot identify cannot be proved to be the same row later, so it is
        // never scheduled at all.
        guard let identity = rowIdentity?(rowIndex) else { return }
        // Screen coordinates, because that is the space the answer arrives in: the block reads
        // `NSEvent.mouseLocation`, and a reorder can slide the rows under the pointer in between.
        let downOnScreen = window.convertPoint(toScreen: downPoint)
        let pressedRowControl = Self.pressedControl(in: rowView, at: downPoint)

        // `.default` ONLY. A block that also listed `.eventTracking` — or a
        // `DispatchQueue.main.async`, which effectively does, since event tracking is a common
        // mode — runs mid-press with the button still down, and every drag would toggle.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                self?.finishToggleDecision(
                    downOnScreen: downOnScreen, downIdentity: identity,
                    pressedRowControl: pressedRowControl, clickCount: clickCount
                )
            }
        }
    }

    private func finishToggleDecision(
        downOnScreen: NSPoint,
        downIdentity: String,
        pressedRowControl: Bool,
        clickCount: Int
    ) {
        // The press is not over, so this is not yet a click — and it may never be one.
        //
        // This is reachable, and the measurements do not pin down exactly when. The block is
        // scheduled from `handleMouseDown`, and `SessionWindow.hitView(for:)` requires neither a
        // key window nor an active app, so presses arrive here that never ran a tracking loop to
        // wait on. Probing a window that never became key, the decision point landed after the
        // release in four runs out of five and about 4ms into the press — long before it — in
        // the fifth. Nothing was found that makes the loop's absence predictable, which is the
        // argument for this guard rather than against it: without it, that fifth case turns a
        // drag into a toggle.
        //
        // Declining costs a toggle on the press that is still in progress and nothing else; the
        // next click on a settled window toggles normally. If that press is the one activating
        // an unfocused Flight Deck, the result is that the activating click does not collapse a
        // project and the one after it does — which is how macOS apps are supposed to behave,
        // though that particular sequence has not been driven in the real app.
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }

        // Resolved again rather than captured, the same rule the rest of this file follows: the
        // window may have closed while the button was held. `NSEvent.mouseLocation` is where the
        // pointer is *now*, which — the tracking loop having just returned — is where it was
        // released.
        guard let window = SessionWindow.main else { return }
        let upOnScreen = NSEvent.mouseLocation
        guard let hit = SessionWindow.hitView(
            inWindow: window, at: window.convertPoint(fromScreen: upOnScreen)
        ), let (_, _, rowIndex) = Self.sidebarRow(under: hit) else { return }

        guard SidebarClickIntent.togglesCollapse(
            downPoint: downOnScreen,
            upPoint: upOnScreen,
            downRow: downIdentity,
            upRow: rowIdentity?(rowIndex),
            clickCount: clickCount,
            pressedRowControl: pressedRowControl
        ) else { return }
        // The index resolved NOW, not the one pressed: the rule has just proved the two name the
        // same row, and it is today's index that indexes today's `sidebarRows`.
        toggleRow?(rowIndex)
    }

    /// Whether a press landed on a real AppKit control inside the row — in a project header, the
    /// hover-revealed close button, which is the only `NSControl` there.
    ///
    /// Answers for any row, including ones where a control is not the close button: a session
    /// row has its own close button and, mid-rename, a text field. See the file's doc comment for
    /// why that cannot produce a wrong toggle, and why this walks DOWN rather than up from the
    /// hit view.
    ///
    /// Not private so the walk itself can be tested; the rule it feeds is pure, but this half is
    /// the half that has to be right about AppKit.
    static func pressedControl(in rowView: NSTableRowView, at pointInWindow: NSPoint) -> Bool {
        let pointInRow = rowView.convert(pointInWindow, from: nil)
        func covers(_ view: NSView) -> Bool {
            if view is NSControl, view.convert(view.bounds, to: rowView).contains(pointInRow) {
                return true
            }
            return view.subviews.contains(where: covers)
        }
        return rowView.subviews.contains(where: covers)
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
    /// nothing is attached, replaced, or reconfigured. The row view comes back so that
    /// `pressedControl(in:at:)` has a subtree to walk — it is the root of the only geometry the
    /// click rule needs, and it is AppKit's, not SwiftUI's.
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

    /// Whether a press/release pair should toggle the row it landed on.
    ///
    /// The two points only have to share a coordinate space — the caller passes screen points.
    /// The two row identities are `SidebarRow.id`, not indices: the release is decided a whole
    /// press later, and an index can come to mean a different row in that time.
    ///
    /// `pressedRowControl` is whether the press landed on an AppKit control inside the row —
    /// the close button. There is no exclusion *width* here to get wrong: the caller measures
    /// the control's own frame. See `SidebarInputMonitor.pressedControl(in:at:)`.
    static func togglesCollapse(
        downPoint: CGPoint,
        upPoint: CGPoint,
        downRow: String?,
        upRow: String?,
        clickCount: Int,
        pressedRowControl: Bool
    ) -> Bool {
        guard clickCount == 1, !pressedRowControl else { return false }
        guard let downRow, downRow == upRow else { return false }
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
        toggleRow: @escaping (Int) -> Void,
        rowIdentity: @escaping (Int) -> String?
    ) -> some View {
        self
            .onAppear {
                monitor.renameRow = renameRow
                monitor.renameSelected = renameSelected
                monitor.toggleRow = toggleRow
                monitor.rowIdentity = rowIdentity
                monitor.start()
            }
            .onDisappear { monitor.stop() }
    }
}
