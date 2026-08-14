# Project Rows in the Sidebar — Design

Date: 2026-08-14

## Problem

Sidebar project headings are inert text. `SessionSidebar` renders
`List → Section(repo.displayName) → SessionRow`, and a `Repo` is derived state: it
comes into existence when `insertSession` meets an unfamiliar working directory and
vanishes when `closeSession` removes its last session. Projects have no order the user
controls, no collapsed state, and no way to be acted on.

This design makes a project a first-class, directly manipulable object: reorder it by
dragging, collapse it with a leading chevron, close it with a button, and — while
collapsed — read its children's combined activity without expanding it.

## Scope

In scope:

- Drag to reorder projects, and drag to reorder sessions within their own project.
- A leading disclosure chevron on each project header, with collapsed state persisted.
- A close button on each project header that closes every child session and removes the
  project, guarded by a suppressible confirmation when more than one session is open.
- A collapsed header summary: the child session count and a single status glyph for the
  highest-priority child activity.
- Projects become explicitly lifetimed — they survive their last session and are removed
  only by the close button.

Out of scope:

- Dragging a session between projects. Moving a session across projects changes its
  working directory while its terminal is already running in the old one;
  `SessionStore.moveSession` exists for the resume-driven case and is not being wired to
  a drag gesture here.
- Nested projects, project renaming, and project-level colour or icon customisation.
- New UITests. `scripts/smoke.sh` takes focus for roughly forty seconds per run, so the
  GUI gate stays exactly as it is.

## Decisions

| Question | Decision |
| --- | --- |
| What does the close button do? | Closes every child session through the existing teardown path, then removes the project. |
| What is draggable? | Projects among projects; sessions within their own project. Not across projects. |
| Collapsing the project holding the selected session | Selection and terminal are untouched. The sidebar hides the row; nothing re-expands itself. |
| Collapsed status summary | One glyph, the highest-priority child activity: `waiting` > `shell` > `busy`. Idle and unstatused children contribute nothing. |
| "Don't ask again" scope | One app-wide flag, resettable from the Preferences window. |
| Header chrome | Chevron always visible; close button appears on hover. |
| Where project state lives | In the session snapshot (Application Support), not `UserDefaults`. |
| Sidebar structure | Flattened row list with a single `.onMove`, not SwiftUI `Section`s. |
| A project whose last session closes | Stays, as an empty row. |

## Architecture

### `Repo` gains stored collapsed state

```swift
struct Repo: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var displayName: String
    var sessions: [Session]
    var isCollapsed: Bool = false
}
```

Project order stays implicit in the order of `SessionStore.repos`, as it already is.
Reordering is an array move, which means `cycleSelection`'s `repos.flatMap(\.sessions)`
keeps working untouched and ⌃Tab follows the visible order for free.

### `SessionSnapshot` gains an optional projects array

```swift
struct SessionSnapshot: Codable, Equatable {
    struct Project: Codable, Equatable {
        var path: String        // stored verbatim, matching Session.workingDirectory
        var isCollapsed: Bool
    }

    var sessions: [Entry] = []
    var projects: [Project]?    // absent in v1 snapshots
    var selectedSessionID: UUID?
    var sessionCounter: Int = 0
}
```

`projects` is optional for the same load-bearing reason `Entry.pinnedConversationID` is:
synthesized `Codable` decodes an optional with `decodeIfPresent`, so every existing
`sessions.json` still decodes and the file keeps its identity. `nil` means "no recorded
project state" and `restore` falls back to today's behaviour — projects in
session-encounter order, all expanded.

Paths are stored as reported and compared with `SessionStore.comparablePath`, matching
the split `moveSession` already documents: normalization decides *whether* two paths are
the same project, but the reported string is what gets written down.

### Restore becomes a two-pass build

`restore` currently walks `snapshot.sessions` and lets `insertSession` conjure repos in
encounter order. It becomes:

1. Seed `repos` from `snapshot.projects`, in order, carrying `isCollapsed`, skipping any
   whose directory no longer exists (same `directoryExists` seam the sessions use).
2. File sessions into those repos as today, appending a repo for any working directory
   the projects list did not cover.

Two guards change as a consequence of projects outliving their sessions:

- The early return `guard let snapshot = persistence?.load(), !snapshot.sessions.isEmpty`
  would discard a projects-only snapshot — the state you get after closing every session
  but no project. It becomes "no sessions *and* no projects".
- `restore` returns true when it restored anything at all, projects included.
  `SessionStore.init` reads it as `if resetState || !restore() { seedInitialSession() }`,
  and `seedInitialSession` is already a no-op when `repos` is non-empty, so a
  projects-only restore correctly seeds nothing.

`persist()` writes `repos.map { Project(path: $0.url.path, isCollapsed: $0.isCollapsed) }`.

### Project lifetime becomes explicit

Today `closeSession` removes a repo when its last session goes, while `moveSession`
deliberately leaves an emptied source project standing — the two paths disagree, and the
disagreement only stayed invisible because empty projects never survived a relaunch.

The new rule is one rule: **a project appears when it is added or when a session lands in
it, and is removed only by its close button.** `closeSession` drops its
`if repos[repoIndex].sessions.isEmpty { repos.remove(at: repoIndex) }` branch.
`createFromMenu` already anticipates this — its comment about preferring the last active
project "*including* when it is now empty" describes exactly the state that now persists.

One consequence to accept deliberately: `SessionCreateAction.forState(hasProjects:)`
reads `!repos.isEmpty`, so with projects but no sessions the sidebar button stays "New
Session" (⌘N) rather than reverting to "Add Project". That is the correct affordance —
there is a project to add a session to.

### New store API

All of it persists, and all of it is reachable from a test without SwiftUI:

- `setCollapsed(_:forProjectAt:)` — by `Repo.ID`.
- `moveProjects(fromOffsets:toOffset:)`.
- `moveSessions(inProjectAt:fromOffsets:toOffset:)`.
- `closeProject(_:)` — closes every child through the existing `closeSession` teardown
  (surface released, watcher stopped, status and subagent count dropped, anchor dropped,
  notification withdrawn), then removes the repo. Iterating a copy of the child id list,
  since `closeSession` mutates `repos`.
- `collapsedStatus(forProjectAt:) -> SessionStatus?` — the highest-priority child status,
  `nil` when every child is idle or unstatused.

Priority lives on `SessionActivity` as a `summaryRank` property, sitting beside
`SessionStatus.tooltip` — that type already keeps presentation-adjacent logic on the model
precisely so it is testable without instantiating SwiftUI.

## Sidebar rendering

### Flattened rows

`Section` is dropped. The store exposes a computed row list and `SessionSidebar` becomes a
single `ForEach` over it:

```swift
enum SidebarRow: Identifiable, Hashable {
    case project(Repo.ID)
    case session(Session.ID, project: Repo.ID)
    case empty(Repo.ID)     // placeholder under an expanded, empty project
}
```

A collapsed project contributes only its header row. An expanded project with no sessions
contributes a `.empty` placeholder rendering a dimmed "No sessions" — without it, an
expanded empty project is indistinguishable from a collapsed one. Project headers and
placeholders get
`.selectionDisabled()`, so `List(selection: $store.selectedSessionID)` still binds to a
`UUID?` over session rows alone and `SessionRow`'s hand-rolled double-click rename — and
the hover behaviour documented at length around it — is not touched by this work.

Losing `Section` costs the sticky, system-styled group header. That header is being
replaced wholesale by `ProjectHeaderRow` anyway, so the loss is nominal.

### Reorder

One `.onMove` on the flattened `ForEach`, delegating to a pure function:

```swift
enum SidebarReorder {
    static func apply(
        to repos: [Repo],
        rows: [SidebarRow],
        from source: IndexSet,
        to destination: Int
    ) -> [Repo]?
}
```

- Moving a `.project` row moves that project's whole block; the destination flat index
  resolves to a project index.
- Moving a `.session` row is accepted only when the destination lands inside its own
  project's session block, and rejected otherwise.
- `nil` means "illegal move", which the view treats as a no-op.

Everything about the reorder is decided in this function, with no SwiftUI in the test.

Two behaviours to verify during implementation rather than assume, both with the same
fallback:

1. `.onMove` gives drag-to-reorder on a macOS `List` without an edit mode.
2. It coexists with the existing `.dropDestination(for: URL.self)` folder drop on the same
   `List`.

If either misbehaves, the fallback is `.draggable`/`.dropDestination` with a typed
`SidebarRow` payload and a hand-drawn insertion indicator — behind the same
`SidebarReorder.apply`, so only the gesture plumbing changes.

### `ProjectHeaderRow`

Leading to trailing: chevron, name, then (when collapsed) count and status glyph, then
(on hover) the close button.

- **Chevron** — `chevron.right`, rotated 90° when expanded, animated with
  `.easeOut(duration: 0.12)` to match the hover animation `SessionRow` already uses. On a
  project with no sessions it is hidden but still occupies its space, so names stay
  aligned down the column.
- **Name** — `displayName` in secondary semibold, the macOS source-list group-header
  treatment.
- **Collapsed summary** — the session count, then one `SessionStatusIcon` fed by
  `collapsedStatus`. Reusing that view rather than re-implementing the glyphs is what
  keeps the collapsed and expanded representations of the same state from drifting apart.
- **Close button** — inserted on hover rather than hidden, which is the same trick
  `SessionRow` documents: inserting the button is what pushes the trailing content left,
  so no manual offsets are needed. `accessibilityIdentifier("close-project")`, help text
  "Close Project".

Clicking anywhere on the header toggles collapse — a full-width target, matching
`DisclosureGroup`.

A context menu on the header carries **New Session**, **Expand**/**Collapse**, and
**Close Project**. This is load-bearing rather than decorative: projects now outlive their
sessions, and since headers are not selectable, ⌘N cannot target an empty project through
the selection. "New Session" calls `newSession(in: repo.url)`, which already routes
through `insertSession` and finds the existing repo.

Accessibility: the header is a single element labelled like
`"flight-deck, 3 sessions, collapsed, waiting for you"`, so the count and the status
summary reach VoiceOver as words rather than as a bare numeral and an unnamed glyph.

## Close confirmation

Neither `.alert` nor `.confirmationDialog` can host a suppression checkbox.
`NSAlert.showsSuppressionButton` exists for exactly this case and provides the
platform-standard control, so the confirmation is an `NSAlert` run as a window sheet
behind a protocol seam:

```swift
@MainActor
protocol ProjectCloseConfirming {
    func confirmClose(projectNamed: String, sessionCount: Int) async
        -> (confirmed: Bool, suppress: Bool)
}
```

The alert, per HIG for a destructive confirmation:

- `alertStyle = .warning`.
- `messageText`: `Close the project “flight-deck”?`
- `informativeText`: `This closes 3 sessions. Any commands still running in them will be
  terminated.`
- Buttons: "Close Project" with `hasDestructiveAction = true`, and "Cancel" — **Cancel is
  the default**, so Return takes the safe path.
- `showsSuppressionButton = true`, suppression title "Don't ask me again".

It is shown only when the project holds more than one session and the flag is unset. One
session or none closes immediately, which matches how a single session's own close button
already behaves.

## Preferences

```swift
struct ConfirmationPreferences: Codable, Equatable {
    var suppressProjectClose: Bool
}

struct Preferences: Codable, Equatable {
    // …
    var confirmations: ConfirmationPreferences?
}
```

Optional, and not negotiable: `UserDefaultsPreferencesPersistence.load` decodes with
`try?`, so a new *non-optional* key would fail to decode every existing blob and silently
reset every preference the user has — flags, project overrides, shell, all of it.
`PreferencesStore` exposes it through a non-optional computed accessor so callers never
see the optionality.

The reset control is a checkbox in the Projects tab of the Preferences window —
"Confirm before closing a project with multiple sessions", checked by default. HIG
requires that a suppressible alert stay recoverable, and this is the recovery.

## Testing

Unit tests, in the style of the existing `Tests/FlightDeckTests` suite:

- `SidebarReorder`: project moves up and down; a legal session move inside its project; an
  illegal session move across projects returning `nil`; a collapsed project moving as a
  single block; an empty project as both source and destination.
- Snapshot round-trip: projects written and read back with order and collapsed state; a
  v1 blob with no `projects` key decoding and restoring in encounter order, all expanded;
  a projects-only snapshot restoring projects and seeding no session.
- `setCollapsed` persisting.
- `closeProject`: teardown parity with `closeSession` for every child (watchers stopped,
  statuses and subagent counts dropped, notifications withdrawn), repo removed, selection
  moved off a closed child.
- Project lifetime: closing the last session leaves the project standing and persisted.
- `collapsedStatus`: priority order, ties, all-idle returning `nil`, and no children.
- Confirmation branching against a fake `ProjectCloseConfirming`: more than one session
  prompts; exactly one does not; suppressed does not; cancelling closes nothing; ticking
  the suppression box writes the preference.

No new UITests, for the focus-stealing reason given under Scope.

## Risks

- **`.onMove` on macOS.** Covered above, with a fallback that does not disturb the reorder
  logic.
- **Snapshot compatibility.** The optional-field approach is the one already proven by
  `pinnedConversationID` in this same file; the projects-only restore path is the genuinely
  new state and is covered by a test.
- **Selection and empty projects.** With headers non-selectable and projects able to hold
  no sessions, the app can sit with projects visible and `selectedSessionID` nil. That is
  already a reachable state today (clicking below the last row clears the selection) and
  `RootView` already answers it with `ContentUnavailableView`.
- **Shared working copy.** Several sessions edit this checkout at once. Changes stay
  scoped to the files this design names.
