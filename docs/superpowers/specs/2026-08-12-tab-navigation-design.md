# Tab Navigation — Design

**Date:** 2026-08-12 · **Status:** design approved, ready for planning

## 1. Goal

Give the app the tab navigation every tabbed macOS app has:

- **⌘⇧[ — Show Previous Tab**, **⌘⇧] — Show Next Tab**.
- Cycling follows the sidebar's **visual order, flattened across projects**, and **wraps**
  at both ends.
- Both appear as **Window-menu items** carrying those shortcuts.

And fix a bug that this feature would otherwise expose: **the terminal does not resize with
the window.** These ship together because tab switching re-parents surfaces, which is
exactly the path that surfaces a stale terminal grid — see §6.

Explicitly out of scope: ⌘1–⌘9 direct selection, a tab bar, tab reordering, and the
`SurfaceScrollView` port (and therefore the terminal scrollbar).

## 2. What a "tab" is here

There is no tab type. A tab is a `Session`, and the tab strip is the sidebar:
`SessionStore.repos: [Repo]`, each `Repo` holding `sessions: [Session]`, rendered by
`SessionSidebar` as one `Section` per project over a `List(selection: $store.selectedSessionID)`.

So "switch to the next tab" means *write a different id into `selectedSessionID`*. Everything
downstream already reacts: `TerminalPane` re-parents the selected surface, and the property's
`didSet` persists the selection and updates `lastActiveProjectURL` — so ⌘N after a tab switch
targets the newly-active session's project without any extra work.

## 3. Cycling order

The order is `repos.flatMap(\.sessions)`: the sidebar top-to-bottom, crossing project section
boundaries, wrapping from the last session of the last project to the first session of the
first.

This is not a new idiom. `closeSession` already picks its successor with exactly that
expression, and its comment (`SessionStore.swift:368-372`) records why you must **not** read
through `repos.first`: `moveSession` deliberately leaves an emptied source project standing,
so the first repo can hold zero sessions while live tabs sit in a later section. Reading
`repos.first?.sessions.first` there would clear the selection and drop the app to its "No
Session" empty state. Cycling inherits that hazard exactly, so it inherits the same idiom —
and §7 pins it with a test.

### 3.1 API

Two methods on `SessionStore` over one private helper:

```swift
func selectNextSession()     { cycleSelection(forward: true) }
func selectPreviousSession() { cycleSelection(forward: false) }
```

The helper flattens, locates the current index, and steps with wraparound. It needs no new
index arithmetic: `Array.indexWrapping(after:)` and `indexWrapping(before:)` already exist in
`GhosttyEmbed/Helpers/Extensions/Array+Extension.swift:7-23` — vendored from Ghostty, same
target, and precisely this operation.

### 3.2 Edge cases

All deliberate, all tested:

| State | ⌘⇧] does |
|---|---|
| No sessions | nothing |
| Exactly one session | nothing (wraps to itself) |
| `selectedSessionID` is `nil`, sessions exist | selects the **first** session (⌘⇧[ selects the **last**) |
| `selectedSessionID` names a session that no longer exists | treated as `nil`, per the row above |
| Selection is the last session | wraps to the first, crossing projects |
| First project is empty, live tabs sit below it | cycles over the live tabs; never selects nothing |

## 4. The menu

A new `TabNavigationCommands.swift` sits alongside `SessionCommands.swift` and is added to
`FlightDeckApp.body`'s `.commands { }`. It places two items in the **Window** menu via
`CommandGroup(before: .windowList)` — where Safari and Terminal put theirs:

```
Show Previous Tab    ⇧⌘[
Show Next Tab        ⇧⌘]
```

It copies two decisions from `SessionCommands` rather than inventing new ones:

- **Plain `let store`, not `@ObservedObject`.** No published property is read here, so
  observing would rebuild the menu on every unrelated `SessionStore` mutation — including
  `applyExternalTitle` firing from the transcript watcher's 500 ms poll, potentially while
  the menu is open.
- **Both items stay unconditionally enabled.** A disabled `NSMenuItem` does not fire its key
  equivalent. With fewer than two sessions the action is simply a no-op (§3.2), which is the
  cheaper way to express "nothing to do" than a validation rule that also suppresses the key.

## 5. Why the shortcut reaches the menu at all

This is the part that would otherwise be a landmine, and it is already solved in this
codebase.

AppKit dispatches a key equivalent to the view hierarchy's `performKeyEquivalent(with:)`
**before** the main menu sees it, and `Ghostty.SurfaceView.performKeyEquivalent`
(`SurfaceView_AppKit.swift:1211-1252`) returns `true` for anything libghostty considers a
binding. ⌘⇧[ and ⌘⇧] *are* bindings: libghostty's macOS defaults map them to `previous_tab`
and `next_tab` (`vendor/ghostty/src/config/Config.zig:6969-6978`).

They are registered with a plain `put`, so their flags are `consumed` only — not
`performable`, not `all`. That is exactly the shape `MenuKeyEquivalents.shouldOfferToMenu`
(`MenuKeyEquivalents.swift:31-39`) hands to the menu before the terminal swallows it.

**No change to the input plumbing is required.** Today the binding is claimed by the surface
and then dropped on the floor — libghostty emits a `previous_tab`/`next_tab` action that
Flight Deck's apprt does nothing with. This feature gives it somewhere to land.

### 5.1 The one real risk

Whether SwiftUI's `.keyboardShortcut("[", modifiers: [.command, .shift])` produces a menu key
equivalent that matches the real ⇧⌘[ event, or whether it normalizes the shift into `{`.

The evidence is good but not conclusive: `Ghostty.Input.keyboardShortcut(for:)`
(`Ghostty.Input.swift:20-47`) constructs `KeyboardShortcut(KeyEquivalent("["), modifiers:
[.shift, .command])` from this same trigger, and upstream Ghostty ships that. Good evidence
is not verification, so the plan carries an **explicit verification step** with a stated
fallback: set the key equivalent directly on the `NSMenuItem` from `AppDelegate` if the
SwiftUI representation does not match.

## 6. The resize bug, and why it ships here

**Symptom.** The terminal does not reflow when the window resizes. The Metal layer stretches;
the grid keeps its old rows and columns.

**Cause.** `SurfaceView.sizeDidChange(_:)` — the only thing that calls
`ghostty_surface_set_size` — is **never called in Flight Deck**. Upstream its macOS caller is
the `SurfaceScrollView` inside Ghostty's SwiftUI wrapper (`SurfaceView.swift:636`,
`SurfaceScrollView.swift:215`), and per `docs/ARCHITECTURE.md` that wrapper was dropped
during the decoupling — only `SurfaceConfiguration` and `moveFocus` were lifted out of it.
The method came across with the adapt-copy and has sat orphaned since.

So the surface is born at a hardcoded `800×600` (`SurfaceView_AppKit.swift:269`), and the only
thing that ever reports a real size is `viewDidChangeBackingProperties` (line 862), which
reads `contentSize` — a property that falls back to `frame.size`
(`SurfaceView_AppKit.swift:151-154`). That fires when the view lands in a window, which is why
the terminal looks right at launch and never adapts again.

**Fix.** `TerminalPane.makeNSView` returns a `TerminalHostView` instead of a bare `NSView`:

```swift
final class TerminalHostView: NSView {
    var onResize: ((CGSize) -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
    }
}
```

The coordinator forwards to the attached surface's `sizeDidChange(_:)`, guarded on a non-zero
size — upstream guards the same way and records why (`SurfaceScrollView.swift:208-216`: the
content size can be zero when the view is added early or to an invisible hierarchy). Upstream's
warning against relying on the AppKit resize callback is scoped to macOS 12; this project
targets 14.0 (`project.yml:5`), where it is reliable.

**And `updateNSView` calls `sizeDidChange` on attach.** This is where the two halves of this
spec meet. Re-parenting is how tab switching works — the surface is retained by the store, not
by the view tree, so switching sessions moves a live `NSView` rather than making a new one. A
surface created while off-screen, or last attached at a different window size, therefore
carries a stale grid. Without the attach-time call, §1's shortcuts would make that path easy
to hit for the first time. The resize fix is not a neighbouring bug; it is a prerequisite.

## 7. Testing

- **`Tests/FlightDeckTests/TabNavigationTests.swift`** — cycling order, wraparound in both
  directions, cross-project traversal, every no-op in §3.2, and the emptied-source-project
  case that `closeSession`'s comment warns about. Pure store manipulation, following
  `SessionStoreTests`.
- **`TerminalHostView`** — a unit test asserting `onResize` fires with the new size. Plain
  AppKit, no libghostty needed.
- **`MenuKeyEquivalentsTests`** — no change needed. §5's routing rule is already pinned by
  `testConsumedBindingIsOfferedToTheMenu` (`MenuKeyEquivalentsTests.swift:20`), which is the
  exact flag shape ⌘⇧[ and ⌘⇧] carry.
- **UITest** — one end-to-end keystroke test, written but left to be run deliberately rather
  than wired into a loop: `smoke.sh` steals focus for ~40 s per run, and stray typing during
  a run reads as phantom test failures.

## 8. Files touched

| File | Change |
|---|---|
| `Sources/FlightDeck/SessionStore.swift` | add `selectNextSession()`, `selectPreviousSession()`, private `cycleSelection(forward:)` |
| `Sources/FlightDeck/TabNavigationCommands.swift` | **new** — Window-menu items and shortcuts |
| `Sources/FlightDeck/FlightDeckApp.swift` | add `TabNavigationCommands` to `.commands { }` |
| `Sources/FlightDeck/TerminalPane.swift` | `TerminalHostView`; forward resize and attach to `sizeDidChange(_:)` |
| `Tests/FlightDeckTests/TabNavigationTests.swift` | **new** |
| `UITests/FlightDeckUITests/` | one keystroke test |
