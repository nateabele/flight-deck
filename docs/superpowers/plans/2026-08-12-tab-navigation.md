# Tab Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add ⌘⇧[ / ⌘⇧] tab navigation that cycles sessions in sidebar order with wraparound, and fix the terminal not resizing with the window.

**Architecture:** A "tab" is a `Session`; switching tabs means writing `SessionStore.selectedSessionID`. Cycling walks `repos.flatMap(\.sessions)` — the sidebar's visual order flattened across project sections — using the existing `Array.indexWrapping(after:)/(before:)` helpers. The shortcuts arrive via two Window-menu items; no input-layer changes are needed, because `MenuKeyEquivalents` already routes `consumed`-only libghostty bindings (which these are) to the main menu before the terminal swallows them. Separately, `TerminalPane`'s container becomes an `NSView` subclass that forwards frame changes to the orphaned `SurfaceView.sizeDidChange(_:)`.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit, XCTest, XcodeGen, macOS 14 target.

**Design spec:** `docs/superpowers/specs/2026-08-12-tab-navigation-design.md`

## Global Constraints

- **macOS deployment target 14.0** (`project.yml:5`). `SWIFT_VERSION: "5.0"` — Swift 5 language mode, no strict concurrency.
- **Every `xcodebuild`/`xcodegen`/`xcrun` invocation needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** The scripts export it themselves. **Do not run `sudo xcode-select`.**
- **Unit tests run with `./scripts/test-unit.sh`** — it runs the whole `FlightDeckTests` bundle headlessly via `xcrun xctest`. There is no per-test filter; read the named test out of the output.
- **Do not run `./scripts/smoke.sh` casually.** It seizes the foreground for ~40 s and fires key events into whatever has focus; stray typing during a run reads as phantom failures. Task 4 is the only task that runs it, once.
- **`Sources/FlightDeck/GhosttyEmbed/` is vendored-ish.** Every file there carries an `// Adapted from ghostty v1.3.1:` header. **No task in this plan modifies anything under `GhosttyEmbed/`** — it is read from only.
- **This checkout is shared with other sessions.** Stage named paths. Never `git add -A`, never `git stash`, never revert anything you did not write.

---

### Task 1: Terminal resizes with the window

Independent of the tab-navigation work, and sequenced first so that anyone manually exercising tab switching in later tasks is not looking at a stale terminal grid.

**Background the implementer needs:** `Ghostty.SurfaceView.sizeDidChange(_:)` (`Sources/FlightDeck/GhosttyEmbed/SurfaceView_AppKit.swift:471`) is the only thing that calls `ghostty_surface_set_size`. Upstream Ghostty calls it from a `SurfaceScrollView` inside a SwiftUI wrapper that Flight Deck deliberately dropped during decoupling, so today **nothing calls it**. The surface is born at a hardcoded 800×600 (`SurfaceView_AppKit.swift:269`) and only `viewDidChangeBackingProperties` (line 862) ever reports a real size — which fires when the view lands in a window, then never again.

**Files:**
- Modify: `Sources/FlightDeck/TerminalPane.swift` (whole file, currently 33 lines)
- Test: `Tests/FlightDeckTests/TerminalHostViewTests.swift` (create)

**Interfaces:**
- Consumes: `Ghostty.SurfaceView.sizeDidChange(_ size: CGSize)` (internal, same module); `SessionStore.surface(for: UUID) -> Ghostty.SurfaceView?`; `SessionStore.tick()`; `Ghostty.moveFocus(to:)`
- Produces: `final class TerminalHostView: NSView` with `var onResize: ((CGSize) -> Void)?`

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/TerminalHostViewTests.swift`:

```swift
// Tests/FlightDeckTests/TerminalHostViewTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class TerminalHostViewTests: XCTestCase {
    func testSetFrameSizeReportsTheNewSize() {
        let view = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        var reported: [CGSize] = []
        view.onResize = { reported.append($0) }

        view.setFrameSize(NSSize(width: 640, height: 480))

        XCTAssertEqual(reported, [CGSize(width: 640, height: 480)])
    }

    /// Autoresizing and SwiftUI both drive the view through the `frame` setter rather than
    /// calling `setFrameSize` directly, so that path is the one that actually matters.
    func testAssigningFrameReportsTheNewSize() {
        let view = TerminalHostView(frame: .zero)
        var reported: [CGSize] = []
        view.onResize = { reported.append($0) }

        view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        XCTAssertEqual(reported, [CGSize(width: 800, height: 600)])
    }

    func testNoCallbackIsHarmless() {
        let view = TerminalHostView(frame: .zero)
        view.setFrameSize(NSSize(width: 10, height: 10))
        XCTAssertEqual(view.frame.size, NSSize(width: 10, height: 10))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'TerminalHostView' in scope`.

- [ ] **Step 3: Write the implementation**

Replace the whole of `Sources/FlightDeck/TerminalPane.swift` with:

```swift
import SwiftUI

/// The container the selected surface is parented into.
///
/// It exists as a subclass for one reason: libghostty has to be *told* the new pixel size or
/// the terminal grid never reflows. `Ghostty.SurfaceView.sizeDidChange(_:)` is the call that
/// does that, and upstream drives it from a `SurfaceScrollView` inside the SwiftUI wrapper
/// this app dropped during decoupling — so without this hook nothing calls it at all, and the
/// Metal layer stretches over a grid that keeps its launch-time rows and columns.
final class TerminalHostView: NSView {
    var onResize: ((CGSize) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
    }
}

/// Hosts the Store's currently-selected surface. The surface is retained by the
/// Store, not by this view, so selection changes re-parent the same live NSView
/// (the shell keeps running) instead of recreating it.
struct TerminalPane: NSViewRepresentable {
    @ObservedObject var store: SessionStore

    func makeNSView(context: Context) -> TerminalHostView {
        let container = TerminalHostView()
        container.autoresizingMask = [.width, .height]
        container.onResize = { [weak container] size in
            guard let surface = container?.subviews.first as? Ghostty.SurfaceView else { return }
            Self.report(size, to: surface)
        }
        return container
    }

    func updateNSView(_ container: TerminalHostView, context: Context) {
        let current = store.selectedSessionID.flatMap { store.surface(for: $0) }

        // Detach any surface that isn't the current selection. It stays retained
        // by the Store, so its shell keeps running while off-screen.
        for sub in container.subviews where sub !== current {
            sub.removeFromSuperview()
        }

        guard let surface = current else { return }
        if surface.superview !== container {
            surface.frame = container.bounds
            surface.autoresizingMask = [.width, .height]
            container.addSubview(surface)
            Ghostty.moveFocus(to: surface)
        }

        // Unconditionally, not just on attach. Re-parenting is how tab switching works, so a
        // surface that was created off-screen or last shown at a different window size still
        // carries that old grid — resizing the window while another tab is selected is enough
        // to produce one.
        Self.report(container.bounds.size, to: surface)
        store.tick()
    }

    /// A zero-sized container is a normal transient state (added early, or to a hierarchy
    /// that is not on screen yet); upstream Ghostty guards the same call the same way in
    /// `SurfaceScrollView.synchronizeCoreSurface`.
    private static func report(_ size: CGSize, to surface: Ghostty.SurfaceView) {
        guard size.width > 0, size.height > 0 else { return }
        surface.sizeDidChange(size)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, including the three `TerminalHostViewTests` cases. The rest of the suite must stay green.

- [ ] **Step 5: Verify the app still builds and the terminal reflows**

Run: `./scripts/build.sh && open "DerivedData/Build/Products/Debug/Flight Deck.app"`

In the running app: run `seq 1 50` in the terminal so there is wrapped output on screen, then drag the window's corner to make it substantially wider and narrower. The text must **reflow to the new width** (long lines re-wrap; the prompt stays at the correct column). Before this change it would stretch without reflowing. Quit the app when done.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/TerminalPane.swift Tests/FlightDeckTests/TerminalHostViewTests.swift
git commit -m "fix: tell libghostty the surface size, so the terminal reflows on resize"
```

---

### Task 2: Cycling logic in SessionStore

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` — insert after `selectSession(_:)`, which ends at line 346
- Test: `Tests/FlightDeckTests/TabNavigationTests.swift` (create)

**Interfaces:**
- Consumes: `SessionStore.repos: [Repo]`, `SessionStore.selectedSessionID: UUID?`, `Array.indexWrapping(after:)` / `indexWrapping(before:)` (`GhosttyEmbed/Helpers/Extensions/Array+Extension.swift:7-23`)
- Produces: `SessionStore.selectNextSession()`, `SessionStore.selectPreviousSession()` — both `@MainActor`, no arguments, no return value

**Why the flattened order matters:** `repos.flatMap(\.sessions)` is already the codebase's canonical flat order. `closeSession` uses it with a comment (`SessionStore.swift:368-371`) recording why reading through `repos.first` is wrong: `moveSession` deliberately does **not** prune a source project it empties (`SessionStore.swift:656-659`), so the first repo can hold zero sessions while live tabs sit in a later section. Step 1's final test pins exactly that case.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/TabNavigationTests.swift`:

```swift
// Tests/FlightDeckTests/TabNavigationTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class TabNavigationTests: XCTestCase {
    /// Retains no real surface — these tests only move a selection around.
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private let foo = URL(fileURLWithPath: "/work/foo", isDirectory: true)
    private let bar = URL(fileURLWithPath: "/work/bar", isDirectory: true)

    /// Two projects, two sessions each. Sidebar order: foo[0], foo[1], bar[2], bar[3].
    private func makeStore() -> (SessionStore, [UUID]) {
        let store = SessionStore(provider: StubProvider())
        let ids = [
            store.newSession(in: foo).id,
            store.newSession(in: foo).id,
            store.newSession(in: bar).id,
            store.newSession(in: bar).id,
        ]
        return (store, ids)
    }

    func testNextAdvancesWithinAProject() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[1])
    }

    func testNextCrossesIntoTheFollowingProject() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[1]
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[2])
    }

    func testNextWrapsFromTheLastSessionToTheFirst() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[3]
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testPreviousMovesBackwardsAcrossProjects() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[2]
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[1])
    }

    func testPreviousWrapsFromTheFirstSessionToTheLast() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[3])
    }

    func testASingleSessionStaysSelected() {
        let store = SessionStore(provider: StubProvider())
        let only = store.newSession(in: foo)
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, only.id)
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, only.id)
    }

    func testAnEmptyStoreIsANoOp() {
        let store = SessionStore(provider: StubProvider())
        store.selectNextSession()
        XCTAssertNil(store.selectedSessionID)
        store.selectPreviousSession()
        XCTAssertNil(store.selectedSessionID)
    }

    func testNoSelectionGoesToTheFirstSessionGoingForward() {
        let (store, ids) = makeStore()
        store.selectedSessionID = nil
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testNoSelectionGoesToTheLastSessionGoingBackward() {
        let (store, ids) = makeStore()
        store.selectedSessionID = nil
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[3])
    }

    func testASelectionNamingAMissingSessionIsTreatedAsNoSelection() {
        let (store, ids) = makeStore()
        store.selectedSessionID = UUID()
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    /// `moveSession` deliberately leaves an emptied source project standing, so the first
    /// repo can hold no sessions while live tabs sit below it. Cycling must walk the live
    /// tabs and never land on nothing — the same hazard `closeSession` documents.
    func testCyclesOverLiveTabsWhenTheFirstProjectIsEmpty() {
        let store = SessionStore(provider: StubProvider())
        let moved = store.newSession(in: foo)
        let stayed = store.newSession(in: bar)
        // `restartsWatcher: false` keeps this test off the filesystem.
        store.moveSession(moved.id, toProjectAt: bar, restartsWatcher: false)
        XCTAssertTrue(store.repos[0].sessions.isEmpty, "precondition: source project stands empty")

        // Sidebar order is now bar[stayed], bar[moved].
        store.selectedSessionID = stayed.id
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, moved.id)

        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, stayed.id)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'SessionStore' has no member 'selectNextSession'`.

- [ ] **Step 3: Write the implementation**

In `Sources/FlightDeck/SessionStore.swift`, insert immediately after `selectSession(_:)` (which ends at line 346, before `func closeSession`):

```swift
    /// ⌘⇧] — moves the selection one session down the sidebar's visual order, wrapping to the
    /// top. ⌘⇧[ is the mirror image.
    func selectNextSession() { cycleSelection(forward: true) }

    /// ⌘⇧[. See `selectNextSession()`.
    func selectPreviousSession() { cycleSelection(forward: false) }

    /// The order is `repos.flatMap(\.sessions)` — the sidebar top to bottom, crossing project
    /// sections. Flattening is not a convenience: `moveSession` deliberately leaves an emptied
    /// source project standing, so the first repo can hold no sessions while live tabs sit in a
    /// later section, and anything reading through `repos.first` would walk off the live list.
    /// `closeSession` documents the same hazard.
    ///
    /// No-ops on an empty list, and a lone session wraps to itself. A `selectedSessionID` that
    /// names no live session is treated as no selection at all, which lands on the first
    /// session going forward and the last going backward — the same place a nil selection goes.
    ///
    /// Assigning `selectedSessionID` is the whole effect: its `didSet` persists the change and
    /// updates `lastActiveProjectURL`, so ⌘N after a tab switch already targets the newly
    /// active session's project.
    private func cycleSelection(forward: Bool) {
        let ordered = repos.flatMap(\.sessions)
        guard !ordered.isEmpty else { return }

        guard
            let current = selectedSessionID,
            let index = ordered.firstIndex(where: { $0.id == current })
        else {
            selectedSessionID = forward ? ordered.first?.id : ordered.last?.id
            return
        }

        let destination = forward
            ? ordered.indexWrapping(after: index)
            : ordered.indexWrapping(before: index)
        selectedSessionID = ordered[destination].id
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, all eleven `TabNavigationTests` cases plus a green rest-of-suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/TabNavigationTests.swift
git commit -m "feat: cycle the selected session in sidebar order, with wraparound"
```

---

### Task 3: Window-menu items carrying ⌘⇧[ and ⌘⇧]

**Files:**
- Create: `Sources/FlightDeck/TabNavigationCommands.swift`
- Modify: `Sources/FlightDeck/FlightDeckApp.swift:46-48` (the `body` scene)

**Interfaces:**
- Consumes: `SessionStore.selectNextSession()` / `selectPreviousSession()` from Task 2
- Produces: `struct TabNavigationCommands: Commands` with `let store: SessionStore`

**Why a menu item is the mechanism, not a workaround:** AppKit gives a view's `performKeyEquivalent(with:)` first refusal ahead of the main menu, and `Ghostty.SurfaceView.performKeyEquivalent` (`SurfaceView_AppKit.swift:1211-1252`) returns `true` for anything libghostty calls a binding. ⌘⇧[ and ⌘⇧] *are* bindings — libghostty's macOS defaults map them to `previous_tab`/`next_tab` (`vendor/ghostty/src/config/Config.zig:6969-6978`) — but they are registered with a plain `put`, so their flags are `consumed` only, not `performable`, not `all`. That is exactly the shape `MenuKeyEquivalents.shouldOfferToMenu` (`MenuKeyEquivalents.swift:31-39`) hands to the menu first, and it is already pinned by `MenuKeyEquivalentsTests.testConsumedBindingIsOfferedToTheMenu`. **No file under `GhosttyEmbed/` changes.**

There is no unit test in this task: what it adds is a SwiftUI `Commands` declaration, and the thing worth verifying about it — that the keystroke actually reaches the menu item — is only observable with a running app. Task 4 is that test.

- [ ] **Step 1: Create the commands**

Create `Sources/FlightDeck/TabNavigationCommands.swift`:

```swift
import SwiftUI

/// Window-menu items for moving between sessions.
///
/// **Why these shortcuts reach this menu at all.** AppKit runs a view's
/// `performKeyEquivalent(with:)` *before* the main menu, and `Ghostty.SurfaceView` claims
/// everything libghostty treats as a binding — ⌘⇧[ and ⌘⇧] among them, since libghostty's
/// macOS defaults bind them to `previous_tab`/`next_tab`. Both are registered `consumed`-only
/// (not `performable`, not `all`), which is precisely the shape `MenuKeyEquivalents` offers to
/// the menu before letting the terminal have it. Until now libghostty claimed the keys and the
/// resulting action went nowhere; these items are where it lands.
struct TabNavigationCommands: Commands {
    // Plain `let`, not `@ObservedObject`, for the same reason as `SessionCommands`: no
    // published property is read here, so observing would invalidate and rebuild the menu on
    // every unrelated `SessionStore` mutation — including `applyExternalTitle` firing from the
    // transcript watcher's 500ms poll, potentially while the menu is open.
    let store: SessionStore

    var body: some Commands {
        // Both items stay enabled in every state: a disabled `NSMenuItem` does not fire its
        // key equivalent, so validating them would also silently disable the shortcuts. With
        // fewer than two sessions the action is a no-op, which says the same thing more
        // cheaply — see `SessionStore.cycleSelection(forward:)`.
        CommandGroup(before: .windowList) {
            Button("Show Previous Tab") { store.selectPreviousSession() }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            Button("Show Next Tab") { store.selectNextSession() }
                .keyboardShortcut("]", modifiers: [.command, .shift])

            Divider()
        }
    }
}
```

- [ ] **Step 2: Wire it into the scene**

In `Sources/FlightDeck/FlightDeckApp.swift`, replace lines 47-48:

```swift
        RootWindow(store: store)
            .commands { SessionCommands(store: store) }
```

with:

```swift
        RootWindow(store: store)
            .commands {
                SessionCommands(store: store)
                TabNavigationCommands(store: store)
            }
```

- [ ] **Step 3: Build, and confirm the unit suite is still green**

Run: `./scripts/test-unit.sh`
Expected: builds clean, whole suite PASSes. (`test-unit.sh` builds the app target, so a compile error in either file fails here.)

- [ ] **Step 4: Verify the shortcut by hand, once**

This is the step that resolves the one real unknown in the design (spec §5.1): whether SwiftUI's `.keyboardShortcut("[", modifiers: [.command, .shift])` yields a menu key equivalent that matches a real ⇧⌘[ event, or whether it normalizes the shift into `{`.

Run: `./scripts/build.sh && open "DerivedData/Build/Products/Debug/Flight Deck.app"`

Then, in the running app:
1. Press ⌘N twice, so there are three sessions.
2. Open the **Window** menu and confirm **Show Previous Tab ⇧⌘[** and **Show Next Tab ⇧⌘]** appear above the window list, with those shortcuts rendered.
3. Close the menu, click into the terminal so the *surface* has focus, and press ⌘⇧] — the sidebar selection must move down one row and the terminal must swap. Press it twice more to confirm it wraps to the top. Press ⌘⇧[ to confirm it goes back.
4. Confirm no `[` or `]` character was typed into the shell.

Quit the app when done.

**If the keystroke does nothing but the menu items are present and clickable**, the SwiftUI key equivalent did not match. Fallback: keep the `Button`s but drop their `.keyboardShortcut` modifiers, and set the equivalents directly on the `NSMenuItem`s from `AppDelegate` after launch — locate them by title in `NSApp.mainMenu`, then assign `keyEquivalent = "["` and `keyEquivalentModifierMask = [.command, .shift]`. Record which path was taken in the commit message.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/TabNavigationCommands.swift Sources/FlightDeck/FlightDeckApp.swift
git commit -m "feat: add Show Next/Previous Tab to the Window menu with ⌘⇧] and ⌘⇧["
```

---

### Task 4: End-to-end keystroke proof in the UI smoke test

**Files:**
- Modify: `UITests/FlightDeckUITests/TerminalSmokeTests.swift` — insert one `XCTContext.runActivity` group after the "⌘N inserts below the active session and selects it" group (which ends at line 145) and before the "double-click renames a session" group (line 147)

**Interfaces:**
- Consumes: everything from Tasks 2 and 3, through the running app

**Read this before touching the file.** `TerminalSmokeTests` is deliberately **one test** that walks every behaviour in a single app launch, because each `launch()` seizes the foreground — the file's header comment explains the trade. So this task adds a `runActivity` **group**, not a new `func test…`. Order is load-bearing: read-only checks first, then the mutations that build on each other, and ⌘Q strictly last because it terminates the app.

Placing the group right after the ⌘N group is what makes it cheap: that group leaves exactly three rows in a **known order and selection** — titles `["session 1", "session 3", "session 2"]` with `"session 3"` (row index 1) selected. This group only moves the selection; it changes no row count or title, and the rename group that follows re-establishes its own target row, so nothing downstream is disturbed.

All three sessions live in one project here (⌘N creates in the active session's project), so this group does not exercise cross-project cycling — `TabNavigationTests` covers that. What only a running app can prove is that the keystroke reaches the menu item instead of the pty, which is the same thing the ⌘Q group at the end of the file exists to prove.

`isSelected` is reliable on the row's `Cell`, and **cell indices are offset by one** because the section header occupies index 0 — so row index *n* is cell index *n+1*.

- [ ] **Step 1: Write the failing test group**

Insert after line 145 (the closing `}` of the ⌘N group) in `UITests/FlightDeckUITests/TerminalSmokeTests.swift`:

```swift
        // The keystroke, not the menu item, is what this proves. libghostty binds ⌘⇧[ / ⌘⇧]
        // to previous_tab/next_tab, and the Ghostty surface claims every binding ahead of the
        // main menu — so with focus in the terminal these keys reach `TabNavigationCommands`
        // only because `MenuKeyEquivalents` hands consumed-only bindings over first. Clicking
        // the menu items would exercise none of that, which is why this types instead.
        //
        // Inherited state: rows are ["session 1", "session 3", "session 2"] with "session 3"
        // (row 1) selected. Only the selection moves here.
        XCTContext.runActivity(named: "⌘⇧] and ⌘⇧[ cycle sessions and wrap around") { _ in
            XCTAssertEqual(rows.count, 3, "precondition: three sessions from the ⌘N group")
            XCTAssertTrue(app.cells.element(boundBy: 2).isSelected, "precondition: row 1 selected")

            // Forward one: row 1 -> row 2.
            app.typeKey("]", modifierFlags: [.command, .shift])
            settle()
            XCTAssertTrue(
                app.cells.element(boundBy: 3).isSelected,
                "⌘⇧] did not advance the selection — the terminal probably swallowed the key"
            )

            // Forward again from the last row: wraps to row 0.
            app.typeKey("]", modifierFlags: [.command, .shift])
            settle()
            XCTAssertTrue(
                app.cells.element(boundBy: 1).isSelected,
                "⌘⇧] did not wrap from the last session to the first"
            )

            // Backward from the first row: wraps to the last, row 2.
            app.typeKey("[", modifierFlags: [.command, .shift])
            settle()
            XCTAssertTrue(
                app.cells.element(boundBy: 3).isSelected,
                "⌘⇧[ did not wrap from the first session to the last"
            )

            // The rows themselves must be untouched — a stray "[" or "]" reaching the pty
            // would not change these, but a misrouted key that hit rename or create would.
            let labels = (0..<3).map { rows.element(boundBy: $0).value as? String }
            XCTAssertEqual(labels, ["session 1", "session 3", "session 2"])
        }
```

- [ ] **Step 2: Run the smoke test to verify the new group fails**

This is the one sanctioned `smoke.sh` run in the plan. **Before starting it, stop typing and leave the machine alone for ~40 s** — it takes the foreground and fires key events into whatever has focus.

To confirm the group genuinely fails without the feature, first stash *only* the two source files from Task 3 by checking out their committed-parent versions… **do not do this** — it would rewrite files another session may be using. Instead, take the cheaper equivalent: trust Task 3's Step 4 manual verification as the red/green evidence, and run the smoke test here purely as the green confirmation.

Run: `./scripts/smoke.sh`
Expected: ends with `SMOKE PASS`, and the new activity appears in the result bundle.

- [ ] **Step 3: If it fails, diagnose before changing the test**

A failure here with Task 3's manual check having passed means the keystroke works for a human but not for XCUITest's synthesized events. Check, in order: that `settle()` gives the selection long enough to land (raise to two `settle()` calls); that the cell index offset is still +1 (it changes if SwiftUI alters how it flattens sections — `app.cells.count` should be 4 for three rows plus one header); and that no earlier group left a different selection than the comment claims.

Do **not** relax an assertion to make it pass. If the shortcut genuinely does not work under automation but does by hand, note that in the commit message and leave the group asserting the truth.

- [ ] **Step 4: Commit**

```bash
git add UITests/FlightDeckUITests/TerminalSmokeTests.swift
git commit -m "test: prove ⌘⇧[ / ⌘⇧] reach the menu with the terminal focused"
```

---

### Task 5: Update the architecture docs

`docs/ARCHITECTURE.md` describes the app as built and currently says nothing about tab navigation, and its description of `TerminalContainer` predates the rename to `TerminalPane`. This task records what Tasks 1–4 changed. No code, no tests.

**Files:**
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Read the file and find the two spots**

Run: `rg -n 'TerminalContainer|Runtime model|Preferences' docs/ARCHITECTURE.md`

The "Runtime model" section is where retention and the tick loop are described; the resize hook belongs there. Tab navigation belongs in a short new subsection near the session/sidebar material.

- [ ] **Step 2: Add the resize note to "Runtime model"**

Append this bullet to that section's list:

```markdown
- **Surface sizing:** `TerminalPane`'s container is a `TerminalHostView`, an `NSView` subclass
  that forwards frame changes to `Ghostty.SurfaceView.sizeDidChange(_:)` — the call that
  reaches `ghostty_surface_set_size`. It exists because that method's upstream caller lives in
  the `SurfaceScrollView`/SwiftUI wrapper this app dropped during decoupling, so without the
  hook nothing calls it and the terminal never reflows. `updateNSView` reports the size on
  every update, not just on attach: re-parenting is how tab switching works, so a surface last
  shown at a different window size would otherwise carry a stale grid.
```

- [ ] **Step 3: Add a tab-navigation subsection**

Add after the sidebar/session material:

```markdown
## Tab navigation

⌘⇧[ / ⌘⇧] move the selection along `repos.flatMap(\.sessions)` — the sidebar's visual order
flattened across project sections — wrapping at both ends. `SessionStore.selectNextSession()` /
`selectPreviousSession()` hold the logic; `TabNavigationCommands` supplies the Window-menu items.

The menu items are the *mechanism*, not decoration. AppKit gives the Ghostty surface's
`performKeyEquivalent` first refusal, and libghostty binds both shortcuts by default — but as
`consumed`-only bindings, which `MenuKeyEquivalents` routes to the main menu first. Before this
feature the keys were claimed by the surface and the resulting `previous_tab`/`next_tab` action
went nowhere.
```

- [ ] **Step 4: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: record tab navigation and the surface-sizing hook"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §1 goal: ⌘⇧[ / ⌘⇧] | 2 (logic), 3 (shortcuts) |
| §1 goal: wraps at both ends | 2, tests `testNextWrapsFromTheLastSessionToTheFirst` / `testPreviousWrapsFromTheFirstSessionToTheLast` |
| §1 goal: Window-menu items | 3 |
| §2 a tab is a `Session` | 2 |
| §3 flat order across projects | 2, test `testNextCrossesIntoTheFollowingProject` |
| §3.1 API shape | 2, Interfaces block |
| §3.2 all six edge cases | 2, one test each |
| §4 menu placement, `let store`, always enabled | 3 |
| §5 routing via `MenuKeyEquivalents` | 3 (no code change needed), 4 (proof) |
| §5.1 the `[` vs `{` risk | 3 Step 4, with the stated `AppDelegate` fallback |
| §6 resize cause and fix | 1 |
| §6 attach-time `sizeDidChange` | 1, Step 3 `updateNSView` |
| §7 `TabNavigationTests` | 2 |
| §7 `TerminalHostView` test | 1 |
| §7 `MenuKeyEquivalentsTests` unchanged | acknowledged in Task 3's preamble |
| §7 UITest, run deliberately | 4 |
| §8 files touched | Tasks 1-4; Task 5 adds `docs/ARCHITECTURE.md`, which §8 omitted |

**Placeholder scan:** No TBD/TODO. Every code step carries complete code. Task 4 Step 2 contains a deliberate instruction *not* to do something (revert files in a shared checkout) with the substitute stated — that is a constraint, not a placeholder.

**Type consistency:** `TerminalHostView` / `onResize: ((CGSize) -> Void)?` used identically in Tasks 1 and 5. `selectNextSession()` / `selectPreviousSession()` named identically in Tasks 2, 3, 5 and the spec. `cycleSelection(forward:)` is private and referenced only from within Task 2 and its doc comment. `report(_:to:)` is private to `TerminalPane`. `makeNSView` return type changed from `NSView` to `TerminalHostView` in both `makeNSView` and `updateNSView` signatures — checked.

**One gap found and fixed:** the spec's §8 file table omits `docs/ARCHITECTURE.md`, which documents the app as built and would go stale. Added as Task 5.
