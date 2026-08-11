# Session Creation UX — Design

**Date:** 2026-08-11 · **Status:** design approved, ready for planning

## 1. Goal

Make creating sessions fast and keyboard-driven, and make the app a true single-window app:

- **One window, ever.** No File ▸ New Window, no second sidebar, no duplicate state.
- **⌘N — New Session** in the active session's project, inserted *directly below* the active
  session and activated.
- **⌘⇧A — Add Project…** picks a folder, adds it as a project, and creates a session in it.
- With **no sessions**, the sidebar button becomes *Add Project* and **⌘N reroutes** to it.
- Both actions appear as menu items, with their shortcuts shown on the sidebar button.
- **Dropping folders on the sidebar** adds them as projects with a session each.

## 2. Single window, and what it lets us delete

`RootWindow` becomes a `Window` scene instead of `WindowGroup`. That is the whole
single-window mechanism: SwiftUI creates exactly one, and File ▸ New Window disappears —
which is also what frees ⌘N, since `WindowGroup` was claiming it.

`applicationShouldTerminateAfterLastWindowClosed` already returns `true`, so closing the
window quits. No "how do I get the window back" problem to solve.

Two consequences worth taking deliberately:

- **`SessionStore` moves up to the `App`.** It is currently a `@StateObject` on `RootView`,
  which was correct when windows were plural. With one window the store is app-scoped, and
  it *has* to be reachable from `.commands` for the menu items to drive it. `FlightDeckApp`
  owns it; `RootView` takes it as an `@ObservedObject`.
- **`SessionStore.hasRestoredInProcess` gets deleted.** That static guard exists only to stop
  a second window from restoring the same snapshot (`docs/FOLLOWUPS.md`). A `Window` scene
  makes a second window impossible, so the guard becomes unreachable code defending against
  a state that can no longer occur. Leaving it would be a trap for the next reader.

## 3. Two distinct creation paths

They differ in *where the session lands*, which is the whole point of the feature.

**New Session (⌘N)** — no folder prompt. Uses the active session's project, inserts the new
session at `activeIndex + 1` within that project, and selects it. "Directly under the
currently active tab" is literal: adjacent in the list, not appended to the end of the group.

**Add Project (⌘⇧A), and folder drops** — appends. A newly added project has no ordering
question; an existing one appends to the end of its group. Both then activate the new session.

`SessionStore` grows two intents:

```
func newSessionBelowActive() -> Session?     // nil when there is no active session
func addProject(at url: URL) -> Session      // existing repo → append; new repo → create
```

`addProject` is `newSession(in:)`'s existing behaviour, renamed at the call site for intent.
`newSession(in:)` itself stays as the primitive both build on.

## 4. ⌘N with nothing open

**One always-enabled menu item.** "New Session ⌘N" is never disabled; its action checks
whether any session exists and calls `addProject` when none does. The alternative — disabling
New Session and moving ⌘N onto Add Project — cannot work: a disabled menu item's key
equivalent does not fire, so ⌘N would simply be dead in exactly the state it needs to work.

The routing decision is a one-line pure function so it can be tested without a menu:

```
static func action(hasSessions: Bool) -> CreateAction   // .newSession / .addProject
```

## 5. Sidebar button

One button whose label follows state:

| State | Label | Shortcut shown |
|---|---|---|
| Any session exists | New Session | ⌘N |
| No sessions | Add Project | ⌘⇧A |

The shortcut renders as trailing, de-emphasised text on the button. Apple's HIG puts
shortcuts on *menu items*, not buttons — this is a deliberate deviation, requested so the
binding is discoverable without opening the menu. The menu items carry the same shortcuts, so
the two agree.

Accessibility identifiers stay stable across the swap (`new-session`), with the label text
itself carrying the state, so UITests assert on text rather than on two different ids.

## 6. Folder drop

`.dropDestination(for: URL.self)` on the sidebar list. Each dropped URL resolves to a project
directory through a pure helper:

```
static func projectDirectory(for url: URL) -> URL   // directory → itself; file → its parent
```

Resolving a file to its parent means dropping `README.md` from a repo adds that repo. The
cost is that dropping a loose file from `~/Downloads` adds Downloads as a project — accepted
as the more forgiving trade.

Every dropped folder becomes a project with one session; the **last** one is activated.
Dropping a folder that is already a project creates and activates another session in it —
the same outcome as Add Project on an existing folder, so there is one rule to remember.

## 7. Testing

Unit, no window or menu required:

- `newSessionBelowActive` inserts at `activeIndex + 1` in the active session's repo — pinned
  by *ordering*, with three sessions and the active one in the middle, so an append-to-end
  regression fails.
- `newSessionBelowActive` returns nil and creates nothing when there is no active session.
- `addProject` on an existing repo appends and activates; on a new repo creates the repo.
- `CreateAction.action(hasSessions:)` both ways.
- `projectDirectory(for:)` — a real temp directory, a real temp file, and a nonexistent path.
- The new session is selected in every creating path.

UITest additions:

- ⌘N adds a second row and selects it.
- With no sessions, the sidebar button reads "Add Project"; with sessions, "New Session".

Drag-and-drop is not driven by XCUITest — `dropDestination` needs a real drag session. The
pure resolver is unit-tested and the store path is shared with Add Project, so the untested
surface is the SwiftUI modifier wiring only. This is stated rather than papered over.

## 8. Risks

- **The `WindowGroup` → `Window` swap could disturb the smoke gate.** The XCUITest window
  problem solved in `docs/done/HANDOFF-smoke-gate.md` was specific to how `WindowGroup`
  materialises its initial window under a raw-exec launch. `Window` may behave differently.
  The first implementation task therefore makes the scene change *alone* and runs the smoke
  gate before anything is built on top of it.
- **Moving `SessionStore` ownership touches every existing test's construction path.** The
  store's initialisers stay as they are; only who holds it changes.
- **Shortcut text on a button is a HIG deviation** (§5), taken deliberately.

## 9. Out of scope

- Reordering sessions by drag within the sidebar.
- Removing a project without closing its sessions individually.
- Any change to how sessions launch or restore.
