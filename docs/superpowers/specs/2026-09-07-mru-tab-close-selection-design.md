# MRU tab-close selection

## Problem

Closing the active tab jumps the selection to the top of the sidebar:

```swift
if selectedSessionID == id {
    selectedSessionID = repos.flatMap(\.sessions).first?.id
}
```

The user is thrown to an unrelated session at the top of the list instead of
being returned to where they just were.

## Desired behavior

When the **active** tab is closed, select the session that was active
immediately before it — its most-recently-used predecessor. Repeated closes
walk back through the full activation history (activate C, then A, then B; close
B → land on A; close A → land on C).

When no history applies (first close after launch, or the history is exhausted
because every earlier-active tab is also gone), fall back to the **adjacent
sidebar tab** — the neighbor of the tab just closed (next one down, or the
previous one if the closed tab was last) — never the top of the list.

Closing a **non-active** tab does not change the selection (unchanged from
today).

## Mechanism

### Activation history

Add `private var activationOrder: [UUID] = []` to `SessionStore`, ordered
most-recently-active first. Record in the existing `selectedSessionID.didSet` —
the single choke point every selection change flows through, including the
sidebar's `List(selection:)` binding, which writes `selectedSessionID`
directly:

```swift
// Most-recently-active first, so closeSession can return to the tab you were on
// *before* this one rather than the top of the sidebar. Moving `id` to the front
// (removing any prior occurrence) keeps it deduped and correctly ordered.
if let id = selectedSessionID {
    activationOrder.removeAll { $0 == id }
    activationOrder.insert(id, at: 0)
}
```

Not persisted (absent from `SessionSnapshot`): after a relaunch there is no
meaningful "before", and the adjacent fallback covers the first close.
`restore()` assigns `selectedSessionID`, which seeds `activationOrder` with the
restored selection through the same `didSet`.

### Selection on close

In `closeSession`, replace the `first?.id` fallback with a call to a new helper,
and prune the closed id from the history whether or not it was the active tab:

```swift
if selectedSessionID == id {
    selectedSessionID = selectionAfterClosing(id, formerLocation: (repoIndex, sessionIndex))
}
// Prune regardless of active/non-active so opening and closing many tabs cannot
// grow activationOrder without bound. (selectionAfterClosing already skips dead
// entries, so this is tidiness, not correctness.)
activationOrder.removeAll { $0 == id }
```

```swift
/// The session to select once `closed` (at `at` before its removal) is gone: the
/// most recently active still-live session other than `closed`, or — when history
/// has nothing to offer — the closed tab's sidebar neighbor. Never the top of the list.
private func selectionAfterClosing(
    _ closed: UUID, formerLocation at: (repo: Int, session: Int)
) -> UUID? {
    // MRU first. The liveness check skips ids for tabs closed earlier, so a stale
    // history entry is invisible rather than wrong.
    if let predecessor = activationOrder.first(where: { $0 != closed && locate($0) != nil }) {
        return predecessor
    }
    // No history: the sidebar neighbor. `closed` is already removed from `repos`
    // (removal happens earlier in closeSession), so the survivor now sitting at the
    // closed tab's old flattened position is the "next one down"; clamping to the
    // last index lands on the "previous" when the closed tab was last.
    let ordered = repos.flatMap(\.sessions)
    guard !ordered.isEmpty else { return nil }
    let flattened = repos[..<at.repo].reduce(0) { $0 + $1.sessions.count } + at.session
    return ordered[min(flattened, ordered.count - 1)].id
}
```

The helper runs after `closed` has been removed from `repos`, so `locate` and
the flattened neighbor index both see the post-removal list. The flattened index
is computed from the *pre-removal* location `at`, which is still valid: repos
before `at.repo` are untouched by the removal, and `at.session` was the closed
tab's original within-repo index.

### closeProject

`closeProject` closes each child through `closeSession`, so the prune line
covers project closes too; the shared helper governs any resulting selection
fix-up. No separate change needed.

## Edge cases

- **Last tab closed**: no other live MRU entry, `ordered` empty after removal →
  helper returns `nil` → "No Session" empty state, same as today.
- **Predecessor already closed**: skipped by the `locate($0) != nil` liveness
  check; the next live MRU entry is used, else the adjacent fallback.
- **Nil selection**: the `if let id` guard skips recording; never reached by a
  live close.

## Testing

New file `Tests/FlightDeckTests/SessionCloseSelectionTests.swift`. A new file
avoids colliding with test files another session is actively rewriting in this
shared checkout. Construct with `SessionStore(provider:persistence: nil)` and
drive selection with `selectSession(_:)`, matching `ReopenClosedSessionTests`.

1. Activate A, B, C (C active); close C → lands on B.
2. Continue from (1): close B → lands on A. (Full-stack walk-back.)
3. No history beyond the seeded selection; close the active tab → adjacent
   neighbor (next down), not the top.
4. Active tab is last in the sidebar, no history → previous neighbor.
5. Close a non-active tab → selection unchanged, and its id no longer influences
   a later active-tab close.
6. Predecessor was closed first → close active → skips the dead entry, lands on
   the next live MRU session.

`test-unit.sh` runs the whole macOS suite (~8 min) regardless of
`-only-testing:`; budget for that.

## Risks

- **Concurrent edits**: this checkout is edited by several sessions at once (the
  test API was renamed under us mid-exploration). Re-read `SessionStore.swift`
  fresh at edit time, commit surgically (only the touched files — never a
  blanket `git add -A`), and do not revert or stash other sessions' work.
- **API drift**: `selectedSessionID`, `selectSession`, `locate`, and the
  `closeSession` removal-before-fixup ordering are current as of exploration but
  may move; verify at edit time.

## Non-goals

- Persisting activation history across relaunch.
- A ⌘\` style "switch to previous session" navigation command — only the
  close-selection lands on the MRU predecessor; a standalone toggle is out of
  scope.
- Changing whole-project selection semantics beyond routing through the shared
  helper.
