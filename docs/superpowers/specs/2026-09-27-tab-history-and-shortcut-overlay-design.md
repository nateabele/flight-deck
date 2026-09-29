# Tab history (Back/Forward), project-row cycling, and the shortcut overlay — design

Date: 2026-09-27 · Status: approved in brainstorming, awaiting spec review

## Goal

Three keyboard features for moving around the sidebar:

1. **Back / Forward** — ⌃⌘← returns to the previously selected row, ⌃⌘→ undoes that. The
   history survives a relaunch.
2. **⌘⇧[ / ⌘⇧] stop on project rows**, now that a project row is selectable (per-project view).
3. **⌘⇧/ opens a keyboard-shortcut overlay** (layout A: centred, filterable HUD panel).

## Where each piece lands

Project-row selection (`selectedProjectID`, `selectProject`, `deselectProject`, the
per-project view) exists only on `flywheel-intake`, which is unmerged and actively worked in its
own worktree by another session.

| Piece | Branch |
|---|---|
| `SelectionHistory` model, Back/Forward commands, persistence (session entries only are ever recorded) | `master` |
| Shortcut overlay | `master` |
| Cycling over visible sidebar rows incl. project rows; recording/restoring project entries in history | `fi-tab-nav`, cut from `flywheel-intake` with `master` merged in. Folding it into `flywheel-intake` is that branch owner's call. |

## Key-binding decisions (and why)

- **⌃⌘← / ⌃⌘→, not ⌘←.** libghostty binds ⌘← / ⌘→ to `text:\x01` / `text:\x05` (line start /
  end), consumed-only, so `MenuKeyEquivalents` would hand them to a menu item and every terminal
  would lose line-start/end. ⌃⌘← / ⌃⌘→ are bound by libghostty to `resize_split` (consumed-only,
  not `performable`); Flight Deck has no splits, so the menu receives them exactly as it receives
  ⌘⇧[ today. No `GhosttyDefaults.conf` change is needed. Matches Xcode's Go Back / Go Forward.
- **⌘⇧/** is not bound by libghostty. It shadows the system Help-menu search chord (⌘?); accepted.
  Implementation must verify the chord actually fires on a US layout, since SwiftUI may register
  `"/"` + shift as `"?"` — use whichever spelling is proven to match, and say which in a comment.
  **Resolved 2026-09-28:** `"/"` + ⇧⌘. The first spelling, `"?"` + ⌘, is the Help search field's
  own key equivalent, and the menu item was drawn with no shortcut beside it.

## 1. Selection history

### Model — `Sources/FlightDeck/SelectionHistory.swift` (pure, no SwiftUI/AppKit)

```swift
enum SelectionTarget: Codable, Hashable {
    case session(UUID)
    case project(path: String)   // repo ids are not persisted; the path is the stable identity
}

struct SelectionHistory: Codable, Equatable {
    private(set) var back: [SelectionTarget] = []
    private(set) var forward: [SelectionTarget] = []
    static let limit = 50

    /// A user-visible selection change from `from` to `to`. No-op when either is nil or they are
    /// equal. Pushes `from` onto `back` (trimming the oldest past `limit`), clears `forward`.
    mutating func record(from: SelectionTarget?, to: SelectionTarget?)

    /// Pops `back` until it finds an entry `isLive` accepts, discarding dead ones on the way;
    /// pushes `current` (if non-nil) onto `forward`; returns the destination, or nil (history
    /// unchanged apart from discarded dead entries) when nothing live remains.
    mutating func goBack(from current: SelectionTarget?, isLive: (SelectionTarget) -> Bool) -> SelectionTarget?

    /// Mirror of `goBack`.
    mutating func goForward(from current: SelectionTarget?, isLive: (SelectionTarget) -> Bool) -> SelectionTarget?
}
```

Dead entries are pruned **lazily**, only when traversal skips them. That is deliberate: ⌘⇧T
reopens a closed session under its original id, so an entry that was dead becomes live again.
The model never deduplicates — a browser does not either, and "back" meaning "where I was last"
is only true without dedup. Consecutive duplicates cannot occur because `record` ignores
`from == to`.

### Store wiring — `SessionStore`

- A private `selectionHistory: SelectionHistory` and a private flag `isTraversingHistory`.
- **Recording** happens in `selectedSessionID`'s `didSet`, using `oldValue`, as
  `record(from: oldValue.map(.session), to: new.map(.session))` — skipped when
  `isTraversingHistory` is set or while restoring a snapshot. The `didSet` is the single funnel:
  the sidebar's `List(selection:)` binding writes there directly, so recording in
  `selectSession(_:)` would miss every click.
- Programmatic selections that the user sees (new session with `selecting: true`, the neighbour
  chosen by `selectionAfterClosing`, cycling) **are** recorded — each is a place the user was
  shown. Restoring the snapshot at launch is **not**.
- `goBack()` / `goForward()` set `isTraversingHistory`, ask the model for a destination with
  `isLive` = "`locate(id) != nil`" for sessions, and assign `selectedSessionID`. Both are no-ops
  with nothing live to go to.
- `persist()` writes the history (see below); every history mutation is already followed by a
  `selectedSessionID` assignment, whose `didSet` persists, so no extra `persist()` calls.

### Persistence — `SessionSnapshot`

A new optional field `selectionHistory: SelectionHistory?`, written as `nil` when both stacks
are empty (the file is meant to stay human-readable, as with `unread`). Synthesized `Codable`
decodes a missing key as `nil`, so older files load with empty history, and older builds reading
a newer file ignore the unknown key. `SelectionTarget` encodes as
`{"session":{"id":"<uuid>"}}` / `{"project":{"path":"…"}}` (synthesized enum coding, with the
associated value labeled so the payload nests under a named key rather than `_0`).
`SelectionHistory` itself has a hand-written, non-throwing `init(from:)`: a malformed entry
(an unknown case, a wrong-shaped value) is dropped rather than failing the whole
`SessionSnapshot` decode, which would otherwise wipe every tab.

### Commands — `TabNavigationCommands`

Add **Back** (⌃⌘←) and **Forward** (⌃⌘→) beside Show Previous/Next Tab in the Window menu.
Always enabled, for the reason already documented there: a disabled item does not fire its key
equivalent. The file's header comment gains the `resize_split` explanation.

## 2. Cycling over project rows (`fi-tab-nav`)

- `cycleSelection(forward:)` walks `store.sidebarRows` — the sidebar's visible order: each
  project row, then its sessions unless the project is collapsed. Landing on a project row calls
  `selectProject(_:)`; landing on a session assigns `selectedSessionID`. Wraps at both ends.
- **Behaviour change:** sessions inside a collapsed project are now skipped (today cycling lands
  on them, invisibly). Stepping onto the collapsed project's row is how you reach it.
- The "current position" is `selectedProjectID` when non-nil (a project view is showing), else
  `selectedSessionID`. An unknown current position lands on the first row going forward and the
  last going backward, as today.
- **History with projects:** `selectProject(_:)` and `deselectProject()` record transitions
  using the *displayed* target (`project(path)` while a project view is up, else the session).
  The `selectedSessionID` `didSet` computes its `from` the same way, so session → project →
  session produces two entries, not one. Traversal to a `.project(path)` entry resolves the path
  to a live repo and calls `selectProject`; `isLive` for a project is "a repo with that
  standardized path exists".
- `selectedProjectID` stays unpersisted (its doc comment says why); only history entries carry
  projects across a relaunch.

## 3. Shortcut overlay (layout A)

### Catalogue — `Sources/FlightDeck/ShortcutCatalog.swift` (pure)

```swift
struct ShortcutItem: Equatable { let title: String; let chord: String }        // "⇧⌘T"
struct ShortcutGroup: Equatable { let title: String; let items: [ShortcutItem] } // menu title

enum ShortcutCatalog {
    /// A menu-shaped input so tests need no NSMenu.
    struct MenuNode { let title: String; let keyEquivalent: String;
                      let modifiers: NSEvent.ModifierFlags; let isHidden: Bool; let children: [MenuNode] }
    static func groups(from topLevel: [MenuNode]) -> [ShortcutGroup]
    static func chord(key: String, modifiers: NSEvent.ModifierFlags) -> String   // ⌃⌥⇧⌘ order
    static func filter(_ groups: [ShortcutGroup], query: String) -> [ShortcutGroup] // case-insensitive, title or chord
}
```

- One group per top-level menu (App, File, Edit, View, Window, Help…), in menu order; submenus
  flatten into their top-level group. Items with no key equivalent, hidden items and separators are
  dropped; empty groups are dropped. Upper-case key equivalents imply ⇧ (AppKit convention);
  arrow/function-key private-use characters map to ←→↑↓ etc.
- `NSMenu` → `MenuNode` is a thin adapter (`ShortcutCatalog+AppKit.swift`) read from
  `NSApp.mainMenu` **each time the overlay opens**, so it cannot drift from what is bound — the
  per-agent ⌘N variants included. Terminal-only chords (⌘← line start, ⌘K clear) are not in the
  menu and are intentionally not listed.

### View — `ShortcutOverlay.swift`

- A dimmed full-window scrim with a centred panel (~600pt wide, 14pt radius, material
  background), a filter field at the top with an `esc` hint, and the groups flowed into two
  columns. Matches mockup A (`.superpowers/brainstorm/…/shortcut-overlay.html`).
- Presented from `RootView` as a top-level `.overlay`, driven by a `@Published` flag on a small
  `ShortcutOverlayModel` (not `SessionStore` — it is pure UI state).
- Help-menu item **Keyboard Shortcuts** (⌘⇧/) toggles it. Dismissed by Esc, ⌘⇧/ again, or a
  click on the scrim.
- On open, the filter field takes first responder; on dismiss, focus returns to the selected
  session's surface (so typing resumes in the terminal). No filter match shows "No shortcuts
  match".

## Testing

TDD; confirm each test fails against the unimplemented code first.

- `SelectionHistoryTests`: record/no-op on equal or nil; limit trim; forward cleared by record;
  back/forward round trip; dead entries skipped and discarded; nothing-live leaves `current` in
  place; a revived entry is reachable; Codable round trip with both cases.
- `SessionStore` tests: a sidebar-style `selectedSessionID` write records; snapshot restore does
  not; `goBack` after closing the previous session skips it; ⌘⇧T reopen revives it; history
  survives a persist → restore round trip; an old snapshot without the key loads.
- `ShortcutCatalogTests`: chord formatting incl. implied shift and arrows; grouping and drop
  rules; filtering by title and by chord.
- `fi-tab-nav`: cycling order over mixed rows, wrap, collapsed-project skip, project entries in
  history and their restoration by path.
- GUI end-to-end (the chords reaching the menu with a terminal focused, overlay focus handoff) is
  **Nate's to run** — agents cannot launch the app here (AGENTS.md rule 2). No `smoke.sh` loops.

## Docs

Update `docs/HANDOFF.md`'s shortcut list (if present) and `docs/ARCHITECTURE.md` where selection
is described, in the same commits as the behaviour.

## Out of scope

Rebinding shortcuts, a per-window history, showing terminal-only chords in the overlay,
long-press history menus on Back/Forward.
