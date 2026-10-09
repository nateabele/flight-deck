import AppKit
import SwiftUI

/// Sidebar mouse/keyboard affordances that SwiftUI cannot express here: double-click-to-rename,
/// click-to-focus, click-to-collapse, Return-to-rename, and ←/→ to collapse/expand the
/// highlighted project.
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
/// - **mouse-down, `clickCount == 1`, that turns out not to have been a drag** → collapse that
///   project header if the press landed in its chevron zone, or select the project otherwise.
///   The "turns out" is the whole trick; see below. A click that SELECTS a project also makes
///   the table first responder: the detail column swaps the terminal for `ProjectView`, so
///   there is no visible terminal to take focus from, and without it ←/→ below would have
///   nowhere to arrive.
/// - **← / → with a project selected and the sidebar focused** → collapse / expand that project,
///   consuming the key. Unmodified only, so ⌃⌘←/→ (tab history) is untouched. "Focused" also
///   admits the window itself as first responder, which is where focus falls when keyboard
///   navigation (⌘⇧[/]) lands on a header and the terminal leaves the hierarchy under it.
///
/// Mouse events are always returned unchanged, so row hit-testing and list dragging cannot
/// change. A drag begins with a `clickCount == 1` down, so dragging never renames.
///
/// # Click-to-collapse: why there is no mouse-up handler
///
/// A project-header row collapses on a click to its chevron, selects the project on a click
/// anywhere else in the row, and reorders on a drag. All three begin with the same mouse-down,
/// and nothing here may consume it, so they can only be told apart *after the fact*. The obvious
/// way to do that — widen the monitor's mask to `.leftMouseUp` and compare the two points — **does
/// not work, and was measured not to work**:
///
///     [plain SwiftUI view]                       DOWN seen, UP seen
///     [List row, press resolved to a row]        DOWN seen, UP NEVER SEEN
///
/// `NSTableView` runs a nested tracking loop from inside its `mouseDown:`, pulling events
/// straight off the queue with `nextEventMatchingMask:` until the button comes up. Local
/// monitors are invoked from `NSApplication.sendEvent`, which that loop bypasses entirely, so
/// the up is consumed where no monitor can see it.
///
/// **The loop is not something the sidebar opts into, and nothing here can opt out of it.**
/// `.onMove` does not cause it (measured with and without: identical, both swallow the up), and
/// `.selectionDisabled()` — which every project header carries — does not avoid it either. So
/// dropping reorder, or selection, would not bring the mouse-up back; there is nothing to trade
/// away here.
///
/// An earlier version of this table claimed a third row — that a window which never becomes key
/// *does* deliver the up — and it was wrong in a way worth recording, because the raw line it
/// came from is true. Those runs do see the up. They also log `rowResolved=false`: with the app
/// inactive there was no List row under the pointer to press, so the press landed on the table's
/// background and was never the configuration the line described. Across every run gathered,
/// `rowResolved` and key/active moved together perfectly, so the two cannot be told apart here:
/// what is measured is that **a press landing on a row is never followed by an up**, and that
/// every press that did see an up had not landed on a row. Whether an unfocused window would
/// swallow the up if a row were under the pointer is simply not known — activation could not be
/// forced on a machine in use, so that case was never produced.
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
/// a window. **Travel is what rejects a drag**, and the identity check does not help there: in
/// an `.onMove` reorder the dragged block follows the pointer, so the row under it at release is
/// often the dragged project's own header or one of its sessions — identity matches, and travel
/// is the only thing left saying no. Identity earns its keep against the opposite case, a row
/// removed or inserted under a pointer that never moved. (Which row is under the pointer at the
/// end of a real reorder drag was not measured; it is read off how `.onMove` moves the block.)
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
/// **The case this exclusion exists for is the confirmation sheet.** Press the X on a project
/// that closes outright and the row is gone by the time the decision runs, so the identity
/// comparison vetoes the toggle on its own and `pressedRowControl` changes nothing. But a
/// project with more than one session asks first (`ProjectCloseCoordinator.requestClose`), and
/// `NSAlert.beginSheetModal` returns immediately: the run loop reaches `.default` with the sheet
/// open, the pointer exactly where it was pressed, and the row still there. Without this
/// exclusion that press collapses the project behind the sheet — and then closes it, or does
/// not, depending on which button the user picks. It is the one path where nothing else says no.
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
///
/// **The session window itself grew a second table, and `SessionWindow` alone cannot see that.**
/// `ProjectView`'s Intakes `List` (`ProjectView.swift`) is an `NSTableView` in the SAME window as
/// the sidebar — a project's detail pane, not a different window — so `SessionWindow.hitView(for:)`
/// answers a real, non-nil view for a click on an intake row, and the old `sidebarRow(under:)`
/// walked up from there to the Intakes table and treated it as `sidebarRows`: clicking intake row
/// N landed on sidebar row N (row 0 is the first project header), double-clicking one renamed a
/// session, and Return while the Intakes list had focus renamed the selected session instead of
/// doing nothing. `isSidebarTable` is the fix — every path that resolves a table now also checks
/// that IT, not just the window, is the sidebar's.
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
    /// makes a click on a session row a no-op. See `SessionSidebar`. Fires only for a completed
    /// single click inside the header's chevron zone; see `SidebarClickIntent.chevronZoneWidth`.
    var toggleRow: ((Int) -> Void)?
    /// Fires for a completed single click on a row outside the chevron zone — a header click that
    /// did not collapse it. This is the ONLY way `SessionSidebar` selects a project header today:
    /// headers are `.selectionDisabled()` in the `List`, because making one natively selectable
    /// let `NSTableView` claim its mouse-down for the table's own selection tracking regardless of
    /// chevron zone, starving this file's own click-vs-drag decision (see `SessionSidebar`'s
    /// `selectionBinding` comment for the GUI evidence). The caller still decides what "select"
    /// means; this file has no model of what a row is.
    ///
    /// Returns whether it selected a project, which is when the monitor also hands the table
    /// keyboard focus so ←/→ reach `setSelectedProjectCollapsed`.
    var selectRow: ((Int) -> Bool)?
    /// Collapse (`true`) or expand (`false`) the selected project. Returns whether a project was
    /// selected, so the monitor knows whether to consume the arrow.
    var setSelectedProjectCollapsed: ((Bool) -> Bool)?
    /// The identity of the row at this table index — `SidebarRow.id`, supplied by the caller for
    /// the same reason as above. Click-to-collapse decides a press-duration after it began, and
    /// a bare index does not survive that: sessions come and go asynchronously here, so a row
    /// removed above the pointer shifts everything below it up one, and the index pressed would
    /// then name a different project. Identity is what is compared instead.
    var rowIdentity: ((Int) -> String?)?

    /// `kVK_Return`. Hard-coded rather than importing Carbon for one constant.
    private static let returnKeyCode: UInt16 = 36
    /// `kVK_LeftArrow` / `kVK_RightArrow`.
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124

    /// `true` to collapse, `false` to expand, `nil` when this key is not one of ours. Pure so the
    /// modifier rule is testable: arrow keys always arrive with `.numericPad` and `.function`
    /// set, and a check that treated those as modifiers would never fire at all.
    static func arrowCollapseIntent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool? {
        guard modifiers.intersection([.shift, .control, .option, .command]).isEmpty else { return nil }
        switch keyCode {
        case leftArrowKeyCode: return true
        case rightArrowKeyCode: return false
        default: return nil
        }
    }

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
                return nil     // consumed: the sidebar had focus and acted on Return or ←/→
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
        // This guard is also what keeps a control-click out of click-to-collapse, which is worth
        // knowing because nothing below filters modifiers the way `handleKeyDown` does. Probed on
        // a replica of this list — a plain press and a control-press at the same point in the
        // same run — the plain one resolved a row and scheduled, and the control-press resolved
        // NO row (`rowResolved=false`) and got no further than here, while the context menu
        // opened normally. So the sequence control-click → Escape leaves the row untouched. Not
        // driven in the real app: `AXIsProcessTrusted()` is false on this machine, so no
        // synthetic control-click can be delivered to it.
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
        //
        // Deliberately *after* the field-editor guard above, which is broader than "a click
        // inside the field": while a rename is open it suppresses the collapse/select decision
        // for a click ANYWHERE in the sidebar, including on some other project's header. That is
        // the right behaviour and it is what the user sees — the first click commits the rename,
        // the second one acts on the row it landed on — but it is worth saying, because it is not
        // what "never collapse a project from inside a rename field" implies.
        //
        // Deliberately *before* the selected-row guard below, which returns early on every row
        // but one.
        //
        // `clickCount == 1` is the only value that reaches the scheduler, so **clicking a header
        // repeatedly and fast collapses or selects it exactly once, however many clicks land**:
        // the first (cc=1) schedules and decides, the second (cc=2) goes to `renameRow` above,
        // which guards `case .session` and no-ops on a header, and the third and beyond (cc>=3)
        // match nothing here at all. That is the intended behaviour and not flakiness — a
        // double-click that acted twice would look like it had done nothing — but nobody should
        // have to derive it from the guards. The rule keeps its own `clickCount` guard anyway,
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
        // The row view's own coordinate space, not the window's: it is stable across a scroll —
        // `downPoint` is a window point captured at press time, before any of that. The zone
        // itself is measured from the row's cell, not the row's edge; see
        // `SidebarClickIntent.chevronZoneWidth` for the macOS 15 failure that cost.
        let inChevronZone = SidebarClickIntent.inChevronZone(
            pressX: rowView.convert(downPoint, from: nil).x,
            contentLeadingX: Self.contentLeadingX(in: rowView)
        )

        // `.default` ONLY. A block that also listed `.eventTracking` — or a
        // `DispatchQueue.main.async`, which effectively does, since event tracking is a common
        // mode — runs mid-press with the button still down, and every drag would toggle.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated {
                self?.finishToggleDecision(
                    downOnScreen: downOnScreen, downIdentity: identity,
                    pressedRowControl: pressedRowControl, inChevronZone: inChevronZone,
                    clickCount: clickCount
                )
            }
        }
    }

    private func finishToggleDecision(
        downOnScreen: NSPoint,
        downIdentity: String,
        pressedRowControl: Bool,
        inChevronZone: Bool,
        clickCount: Int
    ) {
        // The press is not over, so this is not yet a click — and it may never be one.
        //
        // This is reachable, and the measurements do not pin down when. The block is scheduled
        // from `handleMouseDown`, and `SessionWindow.hitView(for:)` requires neither a key window
        // nor an active app, so a press can arrive here with no tracking loop to wait behind —
        // and the decision then happens immediately, while the button is still down.
        //
        // That was seen exactly once, in one run of one probe variant (`upprobe3 --noselect`,
        // window not key): no tracking loop ran at all and the block fired ~3ms into a 100ms
        // press. It has not been reproduced since. Later probing of a never-key window — seven
        // runs of a differently-built probe, so not a rerun of that one — always found a
        // tracking loop and always decided after the release. Nothing was found that predicts
        // which way it goes, and that is the argument FOR this guard rather than against it: an
        // unpredictable early fire is exactly what turns a drag into a toggle.
        //
        // Two limits on all of the above, because the value of this comment is that it separates
        // what was run from what was reasoned:
        //
        //   - `AXIsProcessTrusted()` is false on the machine this was probed on, so no synthetic
        //     press can make `NSEvent.pressedMouseButtons` non-zero. What was verified is the
        //     ORDERING this guard keys on — decision before release. That the guard then returns
        //     early under a real finger is inference from the API, not an observation.
        //   - The consequence for a click that activates an unfocused Flight Deck — that click
        //     not collapsing a project, and the next one doing so, which is how macOS apps are
        //     meant to behave — has not been driven in the real app either.
        //
        // Declining costs a toggle on a press still in progress and nothing else.
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }

        // Resolved again rather than captured, the same rule the rest of this file follows: the
        // window may have closed while the button was held. `NSEvent.mouseLocation` is where the
        // pointer is *now*, which — the tracking loop having just returned — is where it was
        // released.
        guard let window = SessionWindow.main else { return }
        let upOnScreen = NSEvent.mouseLocation
        guard let hit = SessionWindow.hitView(
            inWindow: window, at: window.convertPoint(fromScreen: upOnScreen)
        ), let (table, _, rowIndex) = Self.sidebarRow(under: hit) else { return }

        let upIdentity = rowIdentity?(rowIndex)
        // The index resolved NOW, not the one pressed: whichever callback fires below, the rule
        // has just proved the two name the same row, and it is today's index that indexes
        // today's `sidebarRows`. `togglesCollapse` and `selectsRow` share every guard but
        // `inChevronZone`, so at most one of them can answer true for a given press.
        if SidebarClickIntent.togglesCollapse(
            downPoint: downOnScreen,
            upPoint: upOnScreen,
            downRow: downIdentity,
            upRow: upIdentity,
            clickCount: clickCount,
            pressedRowControl: pressedRowControl,
            inChevronZone: inChevronZone
        ) {
            toggleRow?(rowIndex)
        } else if SidebarClickIntent.selectsRow(
            downPoint: downOnScreen,
            upPoint: upOnScreen,
            downRow: downIdentity,
            upRow: upIdentity,
            clickCount: clickCount,
            pressedRowControl: pressedRowControl,
            inChevronZone: inChevronZone
        ) {
            // See the doc comment: a selected header shows `ProjectView`, not a terminal, so
            // focus here takes nothing from the user and is what lets ←/→ act on it.
            if selectRow?(rowIndex) == true, window.firstResponder !== table {
                window.makeFirstResponder(table)
            }
        }
    }

    /// Where the row's content starts, in the row view's coordinates: the leading edge of its
    /// cell view. macOS 15 insets the cell 10pt inside a row view that starts at the window edge;
    /// macOS 26 starts the cell at the row's edge. The chevron zone is measured from here so the
    /// same strip of the header collapses on both — see `SidebarClickIntent.chevronZoneWidth`.
    ///
    /// The table's own answer (`view(atColumn: 0)`, the sidebar's one column) when the row is
    /// managed by a table, else the row's first subview — SwiftUI's tree is row → cell →
    /// hosting view, and a row built by hand in a test has no columns. A row with neither
    /// measures from its own edge, which is the old behaviour.
    ///
    /// Not private so it can be tested against a built row view.
    static func contentLeadingX(in rowView: NSTableRowView) -> CGFloat {
        let column = rowView.numberOfColumns > 0 ? rowView.view(atColumn: 0) as? NSView : nil
        return (column ?? rowView.subviews.first).map { $0.frame.minX } ?? 0
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
        if let collapse = Self.arrowCollapseIntent(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            guard let window = NSApp.keyWindow, SessionWindow.isSessionWindow(window) else { return false }
            // The sidebar's table, or nothing at all. Never another table (the Intakes list owns
            // its own arrows), a text field (arrows move the caret), or the terminal.
            let responder = window.firstResponder
            let sidebarFocused = (responder as? NSTableView).map(Self.isSidebarTable) ?? (responder === window)
            guard sidebarFocused else { return false }
            return setSelectedProjectCollapsed?(collapse) ?? false
        }
        guard event.keyCode == Self.returnKeyCode else { return false }
        // Any modifier means this is some other command, not a plain Return.
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        // Same scope check as the mouse path: only the session window.
        guard let window = NSApp.keyWindow, SessionWindow.isSessionWindow(window) else { return false }
        // Only when the SIDEBAR's table holds focus, not just any table. This is what keeps
        // Return working normally in the terminal and inside the rename field editor — and, since
        // the Intakes `List` can also become first responder, what keeps Return from renaming the
        // selected session while a project's Intakes list has focus instead. See `isSidebarTable`.
        guard let table = window.firstResponder as? NSTableView, Self.isSidebarTable(table) else {
            return false
        }
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
        guard isSidebarTable(table) else { return nil }

        let index = table.row(for: rowView)
        guard index >= 0 else { return nil }
        return (table, rowView, index)
    }

    /// Whether `table` is the sidebar's own table, as opposed to some other `NSTableView` in the
    /// session window — `ProjectView`'s Intakes `List` chief among them. See the "Scoping" doc
    /// comment's Intakes paragraph for the bug this exists to stop.
    ///
    /// **An earlier version of this rule checked "the FIRST pane of the window's outermost
    /// `NSSplitView`", and it was wrong — caught by hosting the real `NavigationSplitView`
    /// offscreen in `SidebarTableIdentityLiveTests` rather than trusting the hand-built trees
    /// alone.** On this SDK, `NavigationSplitView`'s own `NSSplitView` holds SIX subviews per
    /// side — dividers, glass-effect chrome (`NSContainerConcentricGlassEffectView`), a
    /// `_NSSplitViewShadowView`, collapsed-interaction views — not two, and the DETAIL pane's
    /// wrapper is `subviews[0]`; the SIDEBAR's own is `subviews[2]`. "First" picked
    /// `ProjectView`'s Intakes table every time, which is the exact bug this file exists to fix,
    /// just relocated into the fix itself.
    ///
    /// The rule instead: the table must live inside the pane of the window's OUTERMOST
    /// `NSSplitView` that contains `SidebarTableMarker`'s view somewhere in its subtree.
    /// "Outermost" still matters — `ProjectView` builds its own `HSplitView` for the Intakes list
    /// and the detail pane, and `HSplitView` is an `NSSplitView` too, so asking about the NEAREST
    /// split would find that inner one and answer about the wrong split entirely — but which
    /// pane no longer depends on subview order, only on where the marker actually is.
    ///
    /// Walks every ancestor once — no worse than the hit-test walk this sits behind already — and
    /// needs no window for the pure logic (`SidebarTableIdentityTests`, hand-built
    /// `NSSplitView`/`NSTableView`/`SidebarTableMarker.MarkerView` trees). `SidebarTableIdentityLiveTests`
    /// re-checks the load-bearing assumption itself — that `NavigationSplitView` really does put
    /// an `NSSplitView` between the window and the sidebar's table at all — by hosting the real
    /// shape offscreen; that is the one thing a hand-built tree cannot prove.
    static func isSidebarTable(_ table: NSTableView) -> Bool {
        // The last (i.e. outermost, since the walk moves toward the window's root) split view's
        // immediate child that the table descends through — not `table` itself, which by the
        // time an outer split is reached is several nested views down.
        var childUnderOutermostSplit: NSView?
        var current: NSView = table
        while let superview = current.superview {
            if superview is NSSplitView { childUnderOutermostSplit = current }
            current = superview
        }
        guard let childUnderOutermostSplit else { return false }
        return containsMarker(childUnderOutermostSplit)
    }

    /// Depth-first search for `SidebarTableMarker.MarkerView` under `view`. There is exactly one
    /// in the live tree — `SessionSidebar` plants it once — so finding it anywhere under the
    /// candidate pane is unambiguous; nothing bounds the recursion because nothing needs to: the
    /// caller already bounded the search to one pane of the outermost split before calling this.
    private static func containsMarker(_ view: NSView) -> Bool {
        if view is SidebarTableMarker.MarkerView { return true }
        return view.subviews.contains(where: containsMarker)
    }
}

/// An invisible marker `SessionSidebar` attaches to the sidebar `List` via `.background()`, so
/// `SidebarInputMonitor.isSidebarTable` has something unambiguous to find instead of guessing
/// from `NSSplitView` subview order (see that function's doc comment for why the order guess was
/// wrong). `.background()` on the `List` itself, never inside a row: this backs the WHOLE list,
/// behind the AppKit-owned `NSTableView` host, not a SwiftUI-drawn row's content, so it cannot
/// compete for a row's click the way the file's doc comment's mechanism #2 measured a per-row
/// `NSViewRepresentable` doing.
struct SidebarTableMarker: NSViewRepresentable {
    /// Never drawn, never hit-tested, never read for its frame — only ever matched by type
    /// identity from `containsMarker`.
    final class MarkerView: NSView {}

    func makeNSView(context: Context) -> NSView { MarkerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Click, or drag? The whole rule, over plain numbers — no `NSEvent`, no view, no window — so it
/// can be exercised by `scripts/test-unit.sh`, which runs the `xctest` binary with no GUI host.
///
/// `SidebarInputMonitor` owns the two events this decides between; see its doc comment for why
/// the decision has to be made after the fact rather than by consuming the mouse-down.
enum SidebarClickIntent {
    /// How far the mouse may travel between press and release and still count as a click.
    ///
    /// This is the check that rejects a reorder drag. The identity comparison below does not: a
    /// dragged block follows the pointer, so at release the row under it is frequently the one
    /// that was dragged. See the file's doc comment.
    static let dragThreshold: CGFloat = 4.0

    /// Width, from the row's CONTENT leading edge (its cell view, see
    /// `SidebarInputMonitor.contentLeadingX(in:)`), of the strip where a header click collapses:
    /// everything left of the project name. The chevron is a SwiftUI `Image`, not an
    /// `NSControl`, so there is no view to hit-test — the zone is geometry. The earlier note here
    /// rejected a "reserved strip of guessed width" because the WHOLE row toggled then and a
    /// strip would have shrunk the target; now the row body selects the project (the
    /// per-project view) and only the chevron may collapse, so a strip is the only way to tell
    /// the two apart.
    ///
    /// Measured, on both OS generations the app ships to: the header's content starts 6pt into
    /// the cell, the `.imageScale(.small)` chevron spans 6-13 and the name starts at 18 — on
    /// macOS 15 (UI-test Mac recording) and on macOS 26 (the README capture) alike.
    ///
    /// It used to be 22pt from the `NSTableRowView`'s edge. That was right on macOS 26, where
    /// the cell starts at the row's edge, and wrong on macOS 14/15, where the row view starts at
    /// the window edge and the cell 10pt inside it: the zone there ended at the glyph's trailing
    /// edge, so a click just past the glyph — the gap before the name — selected the project
    /// instead of collapsing it, and `testProjectHeadingsReorderByDragging` failed on the UI-test
    /// Mac every run. Measuring from the cell is what makes the target the same on both.
    static let chevronZoneWidth: CGFloat = 18

    /// Whether a press at `pressX` (the row view's coordinates) is on the chevron's side of a
    /// header: anywhere left of the name, including the row margin before the cell, where
    /// nothing else lives. `contentLeadingX` is the cell's leading edge in the same space.
    static func inChevronZone(pressX: CGFloat, contentLeadingX: CGFloat) -> Bool {
        pressX < contentLeadingX + chevronZoneWidth
    }

    /// Whether a press/release pair should toggle the row it landed on.
    ///
    /// The two points only have to share a coordinate space — the caller passes screen points.
    /// The two row identities are `SidebarRow.id`, not indices: the release is decided a whole
    /// press later, and an index can come to mean a different row in that time.
    ///
    /// `pressedRowControl` is whether the press landed on an AppKit control inside the row —
    /// the close button. There is no exclusion *width* here to get wrong: the caller measures
    /// the control's own frame. See `SidebarInputMonitor.pressedControl(in:at:)`.
    ///
    /// `inChevronZone` is the one exclusion that IS a guessed width — see `chevronZoneWidth` —
    /// because collapsing is now only the chevron's job; a press anywhere else on the row is a
    /// candidate to select the project instead. See `SidebarInputMonitor.finishToggleDecision`.
    static func togglesCollapse(
        downPoint: CGPoint,
        upPoint: CGPoint,
        downRow: String?,
        upRow: String?,
        clickCount: Int,
        pressedRowControl: Bool,
        inChevronZone: Bool
    ) -> Bool {
        guard inChevronZone else { return false }
        return isClick(
            downPoint: downPoint, upPoint: upPoint, downRow: downRow, upRow: upRow,
            clickCount: clickCount, pressedRowControl: pressedRowControl
        )
    }

    /// Whether a press/release pair should select the project the row it landed on belongs to —
    /// the row-body counterpart to `togglesCollapse`. Same click-vs-drag test, over the same six
    /// inputs, differing only in which side of `inChevronZone` it requires: the two can never
    /// both be true, so a press is never both a collapse and a selection.
    static func selectsRow(
        downPoint: CGPoint,
        upPoint: CGPoint,
        downRow: String?,
        upRow: String?,
        clickCount: Int,
        pressedRowControl: Bool,
        inChevronZone: Bool
    ) -> Bool {
        guard !inChevronZone else { return false }
        return isClick(
            downPoint: downPoint, upPoint: upPoint, downRow: downRow, upRow: upRow,
            clickCount: clickCount, pressedRowControl: pressedRowControl
        )
    }

    /// The click-vs-drag test shared by `togglesCollapse` and `selectsRow`. Neither rule differs
    /// on this half — clickCount, the close-button exclusion, identity, and travel — only on
    /// which side of the chevron zone it requires the press to have landed.
    private static func isClick(
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
        selectRow: @escaping (Int) -> Bool,
        setSelectedProjectCollapsed: @escaping (Bool) -> Bool,
        rowIdentity: @escaping (Int) -> String?
    ) -> some View {
        self
            .onAppear {
                monitor.renameRow = renameRow
                monitor.renameSelected = renameSelected
                monitor.toggleRow = toggleRow
                monitor.selectRow = selectRow
                monitor.setSelectedProjectCollapsed = setSelectedProjectCollapsed
                monitor.rowIdentity = rowIdentity
                monitor.start()
            }
            .onDisappear { monitor.stop() }
    }
}
