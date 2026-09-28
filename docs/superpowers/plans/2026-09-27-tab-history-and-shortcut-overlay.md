# Tab History, Project-Row Cycling and Shortcut Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ⌃⌘←/⌃⌘→ Back/Forward through a persisted selection history, ⌘⇧/ keyboard-shortcut overlay (master), and ⌘⇧[/] cycling that stops on project rows (side branch `fi-tab-nav`).

**Architecture:** A pure `SelectionHistory` value type recorded from the single selection funnel (`selectedSessionID`'s `didSet`) and persisted as an optional `SessionSnapshot` field. A pure `ShortcutCatalog` built from `NSApp.mainMenu` each time a SwiftUI overlay in `RootView` opens. Project-row work lands on a branch cut from `flywheel-intake`, where project selection exists.

**Tech Stack:** Swift 5 mode, SwiftUI + AppKit, XCTest (headless via `scripts/test-unit.sh`).

**Spec:** `docs/superpowers/specs/2026-09-27-tab-history-and-shortcut-overlay-design.md`

## Global Constraints

- Back = ⌃⌘← (`.leftArrow`, `[.command, .control]`), Forward = ⌃⌘→. **Never ⌘← / ⌘→** — libghostty's line start/end.
- Overlay chord ⌘⇧/ spelled `.keyboardShortcut("?", modifiers: .command)` — the same spelling macOS uses for its own Help ⌘?, which AppKit matches as shift+/ on a US layout. Comment says so.
- History cap: 50 per stack (`SelectionHistory.limit`).
- New `SessionSnapshot` field is **optional** and written `nil` when empty (synthesized `Codable` → `decodeIfPresent`; a non-optional would wipe every tab on first launch).
- Menu items carry **no `.disabled`** — a disabled `NSMenuItem` does not fire its key equivalent.
- Comments explain *why* and name the failure they prevent (house style, `docs/CONVENTIONS.md`).
- Commits: lowercase imperative behavioural subject; trailer `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- **Shared checkout.** On master, stage and commit **only your own paths** (`git commit -- <paths>`); never `git stash`, `git checkout .`, or touch others' changes (`.gitignore`, `docs/FLYWHEEL-*.md` are someone else's).
- Tests: `./scripts/test-unit.sh` (≈8 min, runs the whole suite; `-only-testing:` is ignored). Run it **in the foreground** with a 600000ms timeout. Confirm each new test fails before implementing (a compile failure counts as the red for a missing type).
- **Never launch the app, never run `smoke.sh`, never `defaults delete`.** GUI verification is the maintainer's.

## Review Focus

1. Clicking the already-selected row (the `didSet` fires on same-id reassignment) must not push a history entry — Task 2 test `testReselectingTheSameSessionRecordsNothing`.
2. `restore()`'s own selection assignment persists from inside `didSet`; if history is not loaded *before* that assignment, launch overwrites the saved history with empty — Task 2 test `testRestoreKeepsThePersistedHistory`.
3. Back when every earlier entry is closed: selection must stay put, not go nil — Task 2 test `testBackWithNothingLiveLeavesSelectionAlone`.
4. A pre-feature `sessions.json` (no key) must still restore every tab — Task 2 test `testSnapshotWithoutHistoryStillRestores`.
5. Overlay filter typed as a chord (`⌘N`) must match, not only titles — Task 4 test `testFilterMatchesChordText`.

---

## File Map

| File | Branch | Responsibility |
|---|---|---|
| Create `Sources/FlightDeck/SelectionHistory.swift` | master | Pure back/forward stacks |
| Modify `Sources/FlightDeck/SessionPersistence.swift` | master | `selectionHistory` snapshot field |
| Modify `Sources/FlightDeck/SessionStore.swift` | master, fi-tab-nav | Recording, `goBack`/`goForward`, restore, persist, cycling |
| Modify `Sources/FlightDeck/TabNavigationCommands.swift` | master | Back/Forward items |
| Create `Sources/FlightDeck/Shortcuts/ShortcutCatalog.swift` | master | Pure grouping/formatting/filtering |
| Create `Sources/FlightDeck/Shortcuts/ShortcutCatalog+AppKit.swift` | master | `NSMenu` → `MenuNode` |
| Create `Sources/FlightDeck/Shortcuts/ShortcutOverlay.swift` | master | Model, view, command |
| Modify `Sources/FlightDeck/RootView.swift`, `FlightDeckApp.swift` | master | Present overlay, register command |
| Tests `Tests/FlightDeckTests/SelectionHistoryTests.swift`, `SelectionHistoryStoreTests.swift`, `ShortcutCatalogTests.swift`, `TabNavigationTests.swift` | both | |

`project.yml` globs `Sources/FlightDeck/**`, so new files need no project edit; `xcodegen generate` (run by the scripts) picks them up.

---

### Task 1: `SelectionHistory` model (master)

**Files:**
- Create: `Sources/FlightDeck/SelectionHistory.swift`
- Test: `Tests/FlightDeckTests/SelectionHistoryTests.swift`

**Interfaces:**
- Produces: `enum SelectionTarget: Codable, Hashable { case session(UUID); case project(path: String) }`; `struct SelectionHistory: Codable, Equatable` with `back`, `forward` (`private(set)`), `static let limit = 50`, `var isEmpty: Bool`, `mutating func record(from: SelectionTarget?, to: SelectionTarget?)`, `mutating func goBack(from: SelectionTarget?, isLive: (SelectionTarget) -> Bool) -> SelectionTarget?`, `mutating func goForward(from:isLive:) -> SelectionTarget?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SelectionHistoryTests.swift
import XCTest
@testable import FlightDeck

final class SelectionHistoryTests: XCTestCase {
    private let a = SelectionTarget.session(UUID())
    private let b = SelectionTarget.session(UUID())
    private let c = SelectionTarget.session(UUID())
    private let p = SelectionTarget.project(path: "/w/p")
    private let live: (SelectionTarget) -> Bool = { _ in true }

    func testRecordPushesTheOriginOntoBack() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        XCTAssertEqual(h.back, [a])
        XCTAssertEqual(h.forward, [])
    }

    func testRecordIgnoresNilAndSameTarget() {
        var h = SelectionHistory()
        h.record(from: nil, to: a)
        h.record(from: a, to: nil)
        h.record(from: a, to: a)
        XCTAssertTrue(h.isEmpty)
    }

    func testBackThenForwardRoundTrips() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        h.record(from: b, to: c)
        XCTAssertEqual(h.goBack(from: c, isLive: live), b)
        XCTAssertEqual(h.goBack(from: b, isLive: live), a)
        XCTAssertNil(h.goBack(from: a, isLive: live))
        XCTAssertEqual(h.goForward(from: a, isLive: live), b)
        XCTAssertEqual(h.goForward(from: b, isLive: live), c)
        XCTAssertNil(h.goForward(from: c, isLive: live))
    }

    func testANewSelectionClearsForward() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        _ = h.goBack(from: b, isLive: live)
        h.record(from: a, to: c)
        XCTAssertEqual(h.forward, [])
        XCTAssertEqual(h.back, [a])
    }

    func testDeadEntriesAreSkippedAndDiscarded() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        h.record(from: b, to: c)
        let dest = h.goBack(from: c, isLive: { $0 != self.b })
        XCTAssertEqual(dest, a)
        XCTAssertEqual(h.back, [])
        XCTAssertEqual(h.forward, [c])
    }

    func testNothingLiveLeavesCurrentOffForward() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        XCTAssertNil(h.goBack(from: b, isLive: { _ in false }))
        XCTAssertEqual(h.forward, [], "no destination, so `current` must not be pushed")
        XCTAssertEqual(h.back, [], "the dead entry is discarded on the way")
    }

    /// ⌘⇧T reopens a closed session under its original id, so an entry dead at one moment
    /// can be live at the next. Nothing may prune it before a traversal actually skips it.
    func testAnEntryDeadAtRecordTimeIsStillReachableLater() {
        var h = SelectionHistory()
        h.record(from: a, to: b)
        XCTAssertEqual(h.goBack(from: b, isLive: live), a)
    }

    func testBackIsCappedAtTheLimit() {
        var h = SelectionHistory()
        var prev = SelectionTarget.session(UUID())
        let first = prev
        for _ in 0..<(SelectionHistory.limit + 5) {
            let next = SelectionTarget.session(UUID())
            h.record(from: prev, to: next)
            prev = next
        }
        XCTAssertEqual(h.back.count, SelectionHistory.limit)
        XCTAssertFalse(h.back.contains(first), "the oldest entries are the ones dropped")
    }

    func testCodableRoundTripKeepsBothCases() throws {
        var h = SelectionHistory()
        h.record(from: a, to: p)
        h.record(from: p, to: b)
        _ = h.goBack(from: b, isLive: live)
        let decoded = try JSONDecoder().decode(SelectionHistory.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(decoded, h)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `./scripts/test-unit.sh` → build fails: `cannot find 'SelectionHistory' in scope`.

- [ ] **Step 3: Implement**

```swift
// Sources/FlightDeck/SelectionHistory.swift
import Foundation

/// One place the user has been shown in the sidebar. A project is keyed by path, not by
/// `Repo.id`: repo ids are minted fresh on every launch (`SessionSnapshot.Project` stores only
/// the path), so an id-keyed entry would be dead after the first relaunch.
enum SelectionTarget: Codable, Hashable {
    case session(UUID)
    case project(path: String)
}

/// ⌃⌘← / ⌃⌘→, browser-style: selecting somewhere new pushes where you were and clears
/// Forward.
///
/// Dead entries (a closed session, a removed project) are pruned only when a traversal skips
/// them, never eagerly: ⌘⇧T reopens a closed session under its original id, so an entry that is
/// dead now can be live again by the time the user presses Back. Never deduplicated either —
/// "Back" means "where I was last", which dedup would break.
struct SelectionHistory: Codable, Equatable {
    private(set) var back: [SelectionTarget] = []
    private(set) var forward: [SelectionTarget] = []

    /// Per stack. Bounds `sessions.json` growth for a user who never relaunches.
    static let limit = 50

    var isEmpty: Bool { back.isEmpty && forward.isEmpty }

    mutating func record(from: SelectionTarget?, to: SelectionTarget?) {
        // `selectedSessionID`'s `didSet` fires on every assignment, including a click on the
        // already-selected row; without this guard each such click would push a duplicate.
        guard let from, let to, from != to else { return }
        Self.push(from, onto: &back)
        forward.removeAll()
    }

    mutating func goBack(
        from current: SelectionTarget?, isLive: (SelectionTarget) -> Bool
    ) -> SelectionTarget? {
        Self.traverse(pop: &back, push: &forward, from: current, isLive: isLive)
    }

    mutating func goForward(
        from current: SelectionTarget?, isLive: (SelectionTarget) -> Bool
    ) -> SelectionTarget? {
        Self.traverse(pop: &forward, push: &back, from: current, isLive: isLive)
    }

    private static func traverse(
        pop source: inout [SelectionTarget], push destination: inout [SelectionTarget],
        from current: SelectionTarget?, isLive: (SelectionTarget) -> Bool
    ) -> SelectionTarget? {
        while let candidate = source.popLast() {
            guard isLive(candidate) else { continue }
            // Pushed only once a destination exists: with nothing to go to, the selection does
            // not move, and recording `current` would leave a Forward entry pointing at the
            // very row the user is still on.
            if let current { push(current, onto: &destination) }
            return candidate
        }
        return nil
    }

    private static func push(_ target: SelectionTarget, onto stack: inout [SelectionTarget]) {
        stack.append(target)
        if stack.count > limit { stack.removeFirst(stack.count - limit) }
    }
}
```

- [ ] **Step 4: Run** `./scripts/test-unit.sh` → all `SelectionHistoryTests` pass, suite green.
- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SelectionHistory.swift Tests/FlightDeckTests/SelectionHistoryTests.swift
git commit -m "feat: add a browser-style selection history model" -- Sources/FlightDeck/SelectionHistory.swift Tests/FlightDeckTests/SelectionHistoryTests.swift
```

---

### Task 2: Record, traverse and persist history in `SessionStore` (master)

**Files:**
- Modify: `Sources/FlightDeck/SessionPersistence.swift` (after `terminalSize`, ~line 172)
- Modify: `Sources/FlightDeck/SessionStore.swift` — `selectedSessionID` `didSet` (~172-200), `restore` (~2994), `persist` (~3525), near `selectNextSession` (~3556)
- Test: `Tests/FlightDeckTests/SelectionHistoryStoreTests.swift`

**Interfaces:**
- Consumes: Task 1's `SelectionHistory`, `SelectionTarget`.
- Produces: `func goBack()`, `func goForward()` on `SessionStore`; `private(set) var selectionHistory: SelectionHistory` (readable by tests); `private func noteSelectionChange(from: SelectionTarget?, to: SelectionTarget?)` (fi-tab-nav reuses it); `private var isSuppressingHistory = false`; `SessionSnapshot.selectionHistory: SelectionHistory?`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SelectionHistoryStoreTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SelectionHistoryStoreTests: XCTestCase {
    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }
    private final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    private let foo = URL(fileURLWithPath: "/work/foo", isDirectory: true)

    private func makeStore(_ persistence: FakePersistence? = nil) -> (SessionStore, [UUID]) {
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        let ids = (0..<3).map { _ in store.newSession(in: foo).id }
        return (store, ids)
    }

    func testASidebarSelectionIsRecordedAndBackReturns() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[2]   // what `List(selection:)` does on a click
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[0])
        store.goForward()
        XCTAssertEqual(store.selectedSessionID, ids[2])
    }

    func testReselectingTheSameSessionRecordsNothing() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[1]
        let before = store.selectionHistory
        store.selectedSessionID = ids[1]
        XCTAssertEqual(store.selectionHistory, before)
    }

    func testTraversalDoesNotRecordItself() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        store.goBack()
        XCTAssertEqual(store.selectionHistory.forward, [.session(ids[1])])
        XCTAssertEqual(store.selectionHistory.back, [])
    }

    func testBackSkipsAClosedSession() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        store.selectedSessionID = ids[2]
        store.closeSession(ids[1])
        store.selectedSessionID = ids[2]
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testBackWithNothingLiveLeavesSelectionAlone() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        store.closeSession(ids[0])
        store.selectedSessionID = ids[1]
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[1])
    }

    func testReopenedSessionIsReachableAgain() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        store.closeSession(ids[0])
        store.reopenLastClosed()
        store.selectedSessionID = ids[1]
        store.goBack()
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testHistorySurvivesARelaunch() {
        let persistence = FakePersistence()
        let (store, ids) = makeStore(persistence)
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[2]
        XCTAssertNotNil(persistence.stored?.selectionHistory)

        let relaunched = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = relaunched.restore(directoryExists: { _ in true })
        XCTAssertEqual(relaunched.selectedSessionID, ids[2])
        relaunched.goBack()
        XCTAssertEqual(relaunched.selectedSessionID, ids[0])
    }

    /// `restore` assigns `selectedSessionID`, whose `didSet` persists. Unless the history is
    /// loaded before that assignment, launch overwrites the saved history with an empty one.
    func testRestoreKeepsThePersistedHistory() {
        let persistence = FakePersistence()
        let (store, ids) = makeStore(persistence)
        store.selectedSessionID = ids[0]
        store.selectedSessionID = ids[1]
        let saved = persistence.stored?.selectionHistory

        let relaunched = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = relaunched.restore(directoryExists: { _ in true })
        XCTAssertEqual(persistence.stored?.selectionHistory, saved)
        XCTAssertEqual(relaunched.selectionHistory, saved)
    }

    func testSnapshotWithoutHistoryStillRestores() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],
         "selectedSessionID":"\(id.uuidString)","sessionCounter":1}
        """
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.selectionHistory)
        let persistence = FakePersistence()
        persistence.stored = snapshot
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = store.restore(directoryExists: { _ in true })
        XCTAssertEqual(store.selectedSessionID, id)
        XCTAssertTrue(store.selectionHistory.isEmpty)
    }

    func testEmptyHistoryIsWrittenAsNil() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: StubProvider(), persistence: persistence)
        store.newSession(in: foo)
        XCTAssertNil(persistence.stored?.selectionHistory)
    }
}
```

Note: if `SessionStore(provider:persistence:)` calls `restore()` itself in `init` (check `init` ~line 1690 and `convenience init` ~1764), use whichever initializer the existing `TerminalSizeTests.makeStore` uses and follow its call pattern exactly; the assertions stay the same.

- [ ] **Step 2: Run to verify it fails** — `./scripts/test-unit.sh` → build fails (`goBack`, `selectionHistory` missing).

- [ ] **Step 3: Snapshot field** — in `SessionPersistence.swift`, after `var terminalSize: TerminalSize?`:

```swift
    /// ⌃⌘← / ⌃⌘→'s stacks, so Back after a relaunch goes where it would have gone before it.
    ///
    /// Optional for the same load-bearing reason as `processes` above: synthesized `Codable`
    /// decodes an optional with `decodeIfPresent`, so every existing `sessions.json` still
    /// decodes. Written `nil` when both stacks are empty, so the common file stays readable.
    var selectionHistory: SelectionHistory?
```

- [ ] **Step 4: Store** — in `SessionStore.swift`:

Properties, directly below the `selectedSessionID` declaration:

```swift
    /// See `SelectionHistory`. Recorded from `selectedSessionID`'s `didSet` — the one funnel
    /// every selection change passes through, the sidebar's `List(selection:)` binding
    /// included, which is why recording in `selectSession(_:)` would miss every click.
    private(set) var selectionHistory = SelectionHistory()

    /// Set while `goBack`/`goForward` or `restore` assign the selection: a traversal is not a
    /// new place, and restoring last run's selection is not a navigation.
    private var isSuppressingHistory = false

    private func noteSelectionChange(from: SelectionTarget?, to: SelectionTarget?) {
        guard !isSuppressingHistory else { return }
        selectionHistory.record(from: from, to: to)
    }
```

In the `didSet`, as its first statement:

```swift
            noteSelectionChange(from: oldValue.map(SelectionTarget.session),
                                to: selectedSessionID.map(SelectionTarget.session))
```

Methods, directly below `selectPreviousSession()`:

```swift
    /// ⌃⌘←. No-op when nothing earlier is still open.
    func goBack() { traverseHistory { $0.goBack(from: $1, isLive: $2) } }

    /// ⌃⌘→. See `goBack()`.
    func goForward() { traverseHistory { $0.goForward(from: $1, isLive: $2) } }

    private func traverseHistory(
        _ step: (inout SelectionHistory, SelectionTarget?, (SelectionTarget) -> Bool) -> SelectionTarget?
    ) {
        let current = selectedSessionID.map(SelectionTarget.session)
        let destination = step(&selectionHistory, current) { [self] target in
            switch target {
            case .session(let id): return locate(id) != nil
            case .project: return false  // master has no project selection; see fi-tab-nav
            }
        }
        guard case .session(let id)? = destination else { return }
        #if DEBUG
        selectionChangeReason = "traverseHistory"
        #endif
        isSuppressingHistory = true
        defer { isSuppressingHistory = false }
        // The `didSet` persists, which also writes the stacks `step` just mutated.
        selectedSessionID = id
    }
```

In `restore`, immediately before the `selectedSessionID = snapshot.selectedSessionID.flatMap {` assignment (keep the `#if DEBUG` reason line above it):

```swift
        // Loaded BEFORE the assignment below: its `didSet` persists, and with the history
        // still empty that save would overwrite last run's stacks on every launch.
        selectionHistory = snapshot.selectionHistory ?? SelectionHistory()
        isSuppressingHistory = true
        defer { isSuppressingHistory = false }
```

If a `defer` there would outlive other `selectedSessionID` writes later in `restore`, instead reset `isSuppressingHistory = false` explicitly right after the assignment.

In `persist()`, after `snapshot.owner = Self.selfIdentity`:

```swift
        snapshot.selectionHistory = selectionHistory.isEmpty ? nil : selectionHistory
```

- [ ] **Step 5: Run** `./scripts/test-unit.sh` → new tests pass; `TabNavigationTests`, `ReopenClosedSessionTests`, `TerminalSizeTests` still pass.
- [ ] **Step 6: Commit** (`feat: remember where the selection has been across relaunches`), only the three touched paths.

---

### Task 3: Back / Forward menu items (master)

**Files:**
- Modify: `Sources/FlightDeck/TabNavigationCommands.swift`
- Modify: `docs/ARCHITECTURE.md` (the passage describing selection / `SessionStore`), `docs/HANDOFF.md` (shortcut list, if one exists; `rg -n "⌘⇧\[" docs/` finds it)

**Interfaces:** Consumes `SessionStore.goBack()` / `goForward()` (Task 2).

- [ ] **Step 1: Add the items** after "Show Next Tab", before `Divider()`:

```swift
            Button("Back") { store.goBack() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])

            Button("Forward") { store.goForward() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
```

- [ ] **Step 2: Extend the type's doc comment** with a paragraph: ⌃⌘←/⌃⌘→ are libghostty's `resize_split` defaults, registered consumed-only like ⌘⇧[/], so `MenuKeyEquivalents` offers them to the menu; Flight Deck has no splits so nothing is lost. ⌘←/⌘→ were rejected because libghostty binds them to line start/end (`text:\x01` / `text:\x05`) and taking them would break every prompt.
- [ ] **Step 3: Docs** — add Back/Forward (and the persisted history) where shortcuts/selection are described.
- [ ] **Step 4: Build** `./scripts/build.sh` → succeeds. (No unit test: a `Commands` body is not reachable headlessly; the chord-reaching-the-menu check is the maintainer's GUI step.)
- [ ] **Step 5: Commit** (`feat: go back and forward through selected tabs with ⌃⌘← and ⌃⌘→`).

---

### Task 4: `ShortcutCatalog` (master)

**Files:**
- Create: `Sources/FlightDeck/Shortcuts/ShortcutCatalog.swift`
- Test: `Tests/FlightDeckTests/ShortcutCatalogTests.swift`

**Interfaces:**
- Produces: `struct ShortcutItem: Equatable, Identifiable { let title: String; let chord: String; var id: String }`, `struct ShortcutGroup: Equatable, Identifiable { let title: String; let items: [ShortcutItem]; var id: String { title } }`, `enum ShortcutCatalog` with `struct MenuNode`, `static func groups(from: [MenuNode]) -> [ShortcutGroup]`, `static func chord(key: String, modifiers: NSEvent.ModifierFlags) -> String`, `static func filter(_: [ShortcutGroup], query: String) -> [ShortcutGroup]`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/ShortcutCatalogTests.swift
import AppKit
import XCTest
@testable import FlightDeck

final class ShortcutCatalogTests: XCTestCase {
    private typealias Node = ShortcutCatalog.MenuNode

    private func item(_ title: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command,
                      hidden: Bool = false) -> Node {
        Node(title: title, keyEquivalent: key, modifiers: mods, isHidden: hidden, children: [])
    }
    private func menu(_ title: String, _ children: [Node]) -> Node {
        Node(title: title, keyEquivalent: "", modifiers: [], isHidden: false, children: children)
    }

    func testChordOrdersModifiersLikeTheMenuBar() {
        XCTAssertEqual(ShortcutCatalog.chord(key: "v", modifiers: [.command, .shift, .option]), "⌥⇧⌘V")
        XCTAssertEqual(ShortcutCatalog.chord(key: "t", modifiers: [.command, .shift]), "⇧⌘T")
    }

    func testUppercaseKeyImpliesShift() {
        XCTAssertEqual(ShortcutCatalog.chord(key: "T", modifiers: .command), "⇧⌘T")
    }

    func testArrowsAndPunctuation() {
        let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        XCTAssertEqual(ShortcutCatalog.chord(key: left, modifiers: [.command, .control]), "⌃⌘←")
        XCTAssertEqual(ShortcutCatalog.chord(key: "[", modifiers: [.command, .shift]), "⇧⌘[")
        XCTAssertEqual(ShortcutCatalog.chord(key: "?", modifiers: .command), "⌘?")
    }

    func testGroupsFollowTopLevelMenusAndFlattenSubmenus() {
        let groups = ShortcutCatalog.groups(from: [
            menu("File", [item("New Session", "n"), menu("Open Recent", [item("Clear", "k")])]),
            menu("Edit", [item("Find…", "f")]),
        ])
        XCTAssertEqual(groups.map(\.title), ["File", "Edit"])
        XCTAssertEqual(groups[0].items.map(\.title), ["New Session", "Clear"])
    }

    func testItemsWithoutAChordHiddenItemsAndEmptyMenusAreDropped() {
        let groups = ShortcutCatalog.groups(from: [
            menu("File", [item("About", ""), item("Secret", "s", hidden: true), item("Close", "w")]),
            menu("Window", [item("Zoom", "")]),
        ])
        XCTAssertEqual(groups.map(\.title), ["File"])
        XCTAssertEqual(groups[0].items.map(\.title), ["Close"])
    }

    func testFilterMatchesTitleCaseInsensitively() {
        let groups = ShortcutCatalog.groups(from: [menu("File", [item("New Session", "n"), item("Close", "w")])])
        XCTAssertEqual(ShortcutCatalog.filter(groups, query: "sess").first?.items.map(\.title), ["New Session"])
    }

    func testFilterMatchesChordText() {
        let groups = ShortcutCatalog.groups(from: [menu("File", [item("New Session", "n"), item("Close", "w")])])
        XCTAssertEqual(ShortcutCatalog.filter(groups, query: "⌘N").first?.items.map(\.title), ["New Session"])
    }

    func testFilterDropsGroupsLeftEmptyAndBlankQueryKeepsAll() {
        let groups = ShortcutCatalog.groups(from: [
            menu("File", [item("Close", "w")]), menu("Edit", [item("Find…", "f")]),
        ])
        XCTAssertEqual(ShortcutCatalog.filter(groups, query: "find").map(\.title), ["Edit"])
        XCTAssertEqual(ShortcutCatalog.filter(groups, query: "  "), groups)
    }
}
```

- [ ] **Step 2: Run to verify it fails** (`cannot find 'ShortcutCatalog'`).
- [ ] **Step 3: Implement**

```swift
// Sources/FlightDeck/Shortcuts/ShortcutCatalog.swift
import AppKit

struct ShortcutItem: Equatable, Identifiable {
    let title: String
    let chord: String
    var id: String { title + "\u{0}" + chord }
}

struct ShortcutGroup: Equatable, Identifiable {
    let title: String
    let items: [ShortcutItem]
    var id: String { title }
}

/// The ⌘⇧/ overlay's contents, derived from the main menu rather than a hand-kept list: a list
/// drifts the first time someone adds a menu item, and the per-agent ⌘N variants are built at
/// runtime so no static list could name them. Pure over `MenuNode` so it tests without AppKit's
/// menu machinery; `ShortcutCatalog+AppKit.swift` adapts `NSMenu`.
enum ShortcutCatalog {
    struct MenuNode {
        let title: String
        let keyEquivalent: String
        let modifiers: NSEvent.ModifierFlags
        let isHidden: Bool
        let children: [MenuNode]
    }

    static func groups(from topLevel: [MenuNode]) -> [ShortcutGroup] {
        topLevel.compactMap { menu in
            let items = flatten(menu.children)
            return items.isEmpty ? nil : ShortcutGroup(title: menu.title, items: items)
        }
    }

    private static func flatten(_ nodes: [MenuNode]) -> [ShortcutItem] {
        nodes.flatMap { node -> [ShortcutItem] in
            guard !node.isHidden else { return [] }
            if !node.children.isEmpty { return flatten(node.children) }
            guard !node.keyEquivalent.isEmpty else { return [] }
            return [ShortcutItem(title: node.title,
                                 chord: chord(key: node.keyEquivalent, modifiers: node.modifiers))]
        }
    }

    /// ⌃⌥⇧⌘ then the key — the order the menu bar itself draws. An upper-case key equivalent
    /// means ⇧ even without the flag: that is how AppKit encodes a shifted letter.
    static func chord(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var mods = modifiers
        if key.count == 1, key != key.lowercased() { mods.insert(.shift) }
        var out = ""
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        return out + glyph(for: key)
    }

    private static func glyph(for key: String) -> String {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else {
            return key.uppercased()
        }
        switch Int(scalar.value) {
        case NSLeftArrowFunctionKey: return "←"
        case NSRightArrowFunctionKey: return "→"
        case NSUpArrowFunctionKey: return "↑"
        case NSDownArrowFunctionKey: return "↓"
        case 0x0D, 0x03: return "↩"
        case 0x1B: return "⎋"
        case 0x09: return "⇥"
        case 0x08, 0x7F: return "⌫"
        case 0x20: return "Space"
        default: return key.uppercased()
        }
    }

    static func filter(_ groups: [ShortcutGroup], query: String) -> [ShortcutGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let hits = group.items.filter {
                $0.title.localizedCaseInsensitiveContains(needle)
                    || $0.chord.localizedCaseInsensitiveContains(needle)
            }
            return hits.isEmpty ? nil : ShortcutGroup(title: group.title, items: hits)
        }
    }
}
```

- [ ] **Step 4: Run** `./scripts/test-unit.sh` → green.
- [ ] **Step 5: Commit** (`feat: derive a keyboard-shortcut catalogue from the main menu`).

---

### Task 5: Shortcut overlay view, command and wiring (master)

**Files:**
- Create: `Sources/FlightDeck/Shortcuts/ShortcutCatalog+AppKit.swift`
- Create: `Sources/FlightDeck/Shortcuts/ShortcutOverlay.swift`
- Modify: `Sources/FlightDeck/RootView.swift` (outermost `NavigationSplitView` modifiers), `Sources/FlightDeck/FlightDeckApp.swift:255-261` (`.commands`)
- Modify: `docs/HANDOFF.md` / `docs/ARCHITECTURE.md` shortcut mention

**Interfaces:** Consumes Task 4's `ShortcutCatalog`, `ShortcutGroup`; `SessionStore.surface(for:)` and `selectedSessionID`.

- [ ] **Step 1: AppKit adapter**

```swift
// Sources/FlightDeck/Shortcuts/ShortcutCatalog+AppKit.swift
import AppKit

extension ShortcutCatalog.MenuNode {
    init(_ item: NSMenuItem) {
        self.init(
            title: item.title,
            keyEquivalent: item.keyEquivalent,
            // Only the four chord modifiers: `keyEquivalentModifierMask` can carry device bits
            // that would otherwise render as nothing and break equality in `chord`.
            modifiers: item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]),
            isHidden: item.isHidden || item.isSeparatorItem,
            children: item.submenu?.items.map(Self.init) ?? []
        )
    }
}

extension ShortcutCatalog {
    /// Read fresh on every open, never cached: menus rebuild as agents and accounts change.
    @MainActor static func currentGroups() -> [ShortcutGroup] {
        groups(from: NSApp.mainMenu?.items.map(MenuNode.init) ?? [])
    }
}
```

Top-level items carry their menu title on the `NSMenuItem` (the app menu's is the app name) — `groups` uses `menu.title` from the top-level node, which is correct.

- [ ] **Step 2: Model, command, view**

```swift
// Sources/FlightDeck/Shortcuts/ShortcutOverlay.swift
import SwiftUI

extension Notification.Name {
    /// Posted by the ⌘⇧/ menu item. A `Commands` struct has no route to `RootView`'s state —
    /// the same shape `SearchCommands` uses for ⌘K.
    static let flightDeckToggleShortcuts = Notification.Name("flightDeckToggleShortcuts")
}

/// Help ▸ Keyboard Shortcuts. No `.disabled(...)`: a disabled `NSMenuItem` does not fire its
/// key equivalent, and the item must also close the overlay it opened.
struct ShortcutOverlayCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .help) {
            Button("Keyboard Shortcuts") {
                NotificationCenter.default.post(name: .flightDeckToggleShortcuts, object: nil)
            }
            // ⌘⇧/ spelled as ⌘? — the spelling macOS uses for its own Help-search chord, which
            // AppKit matches against shift+/ on a US layout. `"/"` + `.shift` is not reliably
            // matched, because the event's shifted character is "?". This shadows Help search
            // on purpose (spec, 2026-09-27).
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

struct ShortcutOverlay: View {
    let groups: [ShortcutGroup]
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var filterFocused: Bool

    private var shown: [ShortcutGroup] { ShortcutCatalog.filter(groups, query: query) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            panel
        }
        .onAppear { filterFocused = true }
        .onExitCommand(perform: dismiss)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter shortcuts", text: $query)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onExitCommand(perform: dismiss)
                Text("esc").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

            if shown.isEmpty {
                Text("No shortcuts match").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top),
                                        GridItem(.flexible(), alignment: .top)],
                              alignment: .leading, spacing: 14) {
                        ForEach(shown) { group in groupView(group) }
                    }
                }
                .frame(maxHeight: 460)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
    }

    private func groupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
            ForEach(group.items) { item in
                HStack {
                    Text(item.title).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(item.chord).font(.system(size: 12)).monospacedDigit()
                        .padding(.horizontal, 5)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}
```

- [ ] **Step 3: Present from `RootView`** — add `@State private var shortcutGroups: [ShortcutGroup]?` and, on the `NavigationSplitView` (after `.navigationTitle(...)`):

```swift
        // Over the whole window, not the detail column: the scrim has to cover the sidebar too,
        // or a click there would change the selection behind an overlay the user is reading.
        .overlay {
            if let groups = shortcutGroups {
                ShortcutOverlay(groups: groups, dismiss: dismissShortcuts)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .flightDeckToggleShortcuts)) { _ in
            if shortcutGroups == nil { shortcutGroups = ShortcutCatalog.currentGroups() }
            else { dismissShortcuts() }
        }
```

and a method:

```swift
    /// Hands focus back to the terminal: the filter field held it, and without this the next
    /// keystroke after Esc goes nowhere visible instead of to the prompt the user came from.
    private func dismissShortcuts() {
        shortcutGroups = nil
        if let id = store.selectedSessionID, let surface = store.surface(for: id) {
            surface.window?.makeFirstResponder(surface)
        }
    }
```

Change `var body: some View` so the new modifiers attach to the same expression as `.navigationTitle`.

- [ ] **Step 4: Register the command** — in `FlightDeckApp.swift`'s `.commands { … }` add `ShortcutOverlayCommands()` after `SearchCommands()`.
- [ ] **Step 5: Docs** — mention ⌘⇧/ alongside the other shortcuts.
- [ ] **Step 6: Build and test** `./scripts/build.sh` then `./scripts/test-unit.sh` → both green.
- [ ] **Step 7: Commit** (`feat: show every menu shortcut in a filterable overlay on ⌘⇧/`), only the touched paths.

---

### Task 6: Cycle through visible sidebar rows, project rows included (`fi-tab-nav`)

**Setup (first step of this task):**

```bash
cd /Users/me/Projects/flight-deck
git worktree add .claude/worktrees/fi-tab-nav -b fi-tab-nav flywheel-intake
cd .claude/worktrees/fi-tab-nav
# Per memory: a worktree builds only with the vendor artifacts symlinked in. Do NOT commit these.
ln -s /Users/me/Projects/flight-deck/vendor/ghostty-artifacts vendor/ghostty-artifacts 2>/dev/null || true
ln -s /Users/me/Projects/flight-deck/vendor/boringssl-artifacts vendor/boringssl-artifacts 2>/dev/null || true
git merge --no-edit master   # brings Tasks 1–5 in; resolve conflicts keeping BOTH sides' intent
```

Check `ls /Users/me/Projects/flight-deck/vendor/` for the exact artifact directory names first. Use built-in Edit (not quillmap mutators — they write to the main checkout from a worktree). Before committing, `git diff flywheel-intake -- vendor` must show nothing.

**Files:**
- Modify: `SessionStore.swift` (`cycleSelection(forward:)` and its doc comment)
- Test: `Tests/FlightDeckTests/TabNavigationTests.swift`

**Interfaces:** Consumes flywheel-intake's `sidebarRows: [SidebarRow]` (`.project(UUID)`, `.session(UUID, project: UUID)`, `.empty(UUID)`), `selectProject(_:)`, `selectedProjectID`, `Repo.isCollapsed`. Collapsing in tests: use whatever store method `flywheel-intake` exposes (`rg -n "func toggleCollapse|func setCollapsed|isCollapsed =" Sources/FlightDeck/SessionStore.swift`).

- [ ] **Step 1: Rewrite the existing tests** for the new order. With `makeStore()` the sidebar is `P(foo), foo0, foo1, P(bar), bar2, bar3`. Replace `testNextCrossesIntoTheFollowingProject`, `testNextWrapsFromTheLastSessionToTheFirst`, `testPreviousMovesBackwardsAcrossProjects`, `testPreviousWrapsFromTheFirstSessionToTheLast` with:

```swift
    private func projectID(_ url: URL, in store: SessionStore) -> UUID {
        store.repos.first { $0.url.standardizedFileURL == url.standardizedFileURL }!.id
    }

    func testNextStopsOnTheFollowingProjectRow() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[1]
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(bar, in: store))
        store.selectNextSession()
        XCTAssertEqual(store.selectedSessionID, ids[2])
        XCTAssertNil(store.selectedProjectID)
    }

    func testNextWrapsFromTheLastSessionToTheFirstProjectRow() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[3]
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
    }

    func testPreviousFromAProjectRowGoesToTheSessionAboveIt() {
        let (store, ids) = makeStore()
        store.selectProject(projectID(bar, in: store))
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[1])
        XCTAssertNil(store.selectedProjectID)
    }

    func testPreviousWrapsFromTheFirstProjectRowToTheLastSession() {
        let (store, ids) = makeStore()
        store.selectProject(projectID(foo, in: store))
        store.selectPreviousSession()
        XCTAssertEqual(store.selectedSessionID, ids[3])
    }

    func testCyclingSkipsTheSessionsOfACollapsedProject() {
        let (store, ids) = makeStore()
        // collapse `foo` via flywheel-intake's collapse API
        store.selectProject(projectID(foo, in: store))
        store.selectNextSession()
        XCTAssertEqual(store.selectedProjectID, projectID(bar, in: store))
        _ = ids
    }

    func testAnEmptyProjectRowIsStillAStop() {
        let (store, _) = makeStore()
        let emptyURL = URL(fileURLWithPath: "/work/empty", isDirectory: true)
        // add a project with no sessions via flywheel-intake's add-project API (the one
        // `addProjectFromMenu` ends in), then:
        store.selectProject(projectID(bar, in: store))
        store.selectPreviousSession()   // bar's row → foo1
        store.selectNextSession()       // → bar's row again
        XCTAssertEqual(store.selectedProjectID, projectID(bar, in: store))
        _ = emptyURL
    }
```

Fill the two commented lines with the real API calls you find; the assertions stand. For the empty-project test, also assert that stepping onto the empty project's row selects it (it is a `.project` row followed by `.empty`, and `.empty` is never a stop). Keep `testNextAdvancesWithinAProject`, `testASingleSessionStaysSelected` (a lone session now alternates session ↔ its project row — update it to assert that), `testAnEmptyStoreIsANoOp`.

- [ ] **Step 2: Run to verify the rewritten tests fail** against the current session-only cycling (in the worktree: `./scripts/test-unit.sh`).
- [ ] **Step 3: Implement**

```swift
    /// The order is `sidebarRows` — exactly what the sidebar draws, top to bottom: each project
    /// row, then its sessions unless the project is collapsed. A project row is a stop because a
    /// project is selectable (its per-project view); a collapsed project's sessions are not,
    /// since landing on a row the user cannot see was the old behaviour's one surprise.
    /// `.empty` placeholder rows are never stops.
    ///
    /// The current position is the project view when one is up, else the selected session. An
    /// unknown position lands on the first stop going forward and the last going backward.
    private func cycleSelection(forward: Bool) {
        let stops: [SidebarRow] = sidebarRows.filter {
            if case .empty = $0 { return false } else { return true }
        }
        guard !stops.isEmpty else { return }

        #if DEBUG
        selectionChangeReason = "cycleSelection(forward: \(forward))"
        #endif
        let index = stops.firstIndex { row in
            switch row {
            case .project(let id): return selectedProjectID == id
            case .session(let id, _): return selectedProjectID == nil && selectedSessionID == id
            case .empty: return false
            }
        }
        let destination: SidebarRow
        if let index {
            destination = stops[forward ? stops.indexWrapping(after: index) : stops.indexWrapping(before: index)]
        } else {
            destination = forward ? stops.first! : stops.last!
        }
        switch destination {
        case .project(let id): selectProject(id)
        case .session(let id, _): selectedSessionID = id
        case .empty: break
        }
    }
```

- [ ] **Step 4: Run** `./scripts/test-unit.sh` in the worktree → green.
- [ ] **Step 5: Commit** in the worktree (`feat: stop on project rows when cycling with ⌘⇧[ and ⌘⇧]`); body notes the collapsed-project behaviour change.

---

### Task 7: Project entries in selection history (`fi-tab-nav`)

**Files:**
- Modify: `SessionStore.swift` in the `fi-tab-nav` worktree — `selectedSessionID` `didSet`, `selectProject`, `deselectProject`, `traverseHistory`
- Test: `Tests/FlightDeckTests/SelectionHistoryStoreTests.swift`

**Interfaces:** Consumes Task 2's `noteSelectionChange(from:to:)`, `isSuppressingHistory`, `traverseHistory`; flywheel-intake's `selectProject`, `deselectProject`, `selectedProjectID`, `repos`.

- [ ] **Step 1: Failing tests** (append to `SelectionHistoryStoreTests`, adding a `bar` URL and a second project's session in a local helper):

```swift
    private func projectID(_ url: URL, in store: SessionStore) -> UUID {
        store.repos.first { $0.url.standardizedFileURL == url.standardizedFileURL }!.id
    }

    func testSessionToProjectToSessionRecordsTwoEntries() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectProject(projectID(foo, in: store))
        store.selectedSessionID = ids[1]
        XCTAssertEqual(store.selectionHistory.back,
                       [.session(ids[0]), .project(path: foo.standardizedFileURL.path)])
    }

    func testBackReopensAProjectView() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectProject(projectID(foo, in: store))
        store.selectedSessionID = ids[1]
        store.goBack()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
        store.goBack()
        XCTAssertNil(store.selectedProjectID)
        XCTAssertEqual(store.selectedSessionID, ids[0])
    }

    func testForwardFromAProjectViewReturnsToTheSession() {
        let (store, ids) = makeStore()
        store.selectedSessionID = ids[0]
        store.selectProject(projectID(foo, in: store))
        store.goBack()
        XCTAssertNil(store.selectedProjectID)
        store.goForward()
        XCTAssertEqual(store.selectedProjectID, projectID(foo, in: store))
    }

    func testAProjectEntrySurvivesARelaunchByPath() {
        let persistence = FakePersistence()
        let (store, ids) = makeStore(persistence)
        store.selectProject(projectID(foo, in: store))
        store.selectedSessionID = ids[1]
        let relaunched = SessionStore(provider: StubProvider(), persistence: persistence)
        _ = relaunched.restore(directoryExists: { _ in true })
        relaunched.goBack()
        XCTAssertEqual(relaunched.selectedProjectID, projectID(foo, in: relaunched))
    }
```

- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement**

Add a helper next to `noteSelectionChange`:

```swift
    /// What the detail column shows: the project view when one is up, else the session. The
    /// history records what the user saw, so a session hidden behind a project view is not a
    /// place they were.
    private func displayedTarget(session: UUID?) -> SelectionTarget? {
        if let pid = selectedProjectID, let repo = repos.first(where: { $0.id == pid }) {
            return .project(path: repo.url.standardizedFileURL.path)
        }
        return session.map(SelectionTarget.session)
    }
```

In the `selectedSessionID` `didSet`, replace Task 2's call with one computed **before** the existing `if selectedSessionID != nil { selectedProjectID = nil }` line (move the note above it):

```swift
            noteSelectionChange(from: displayedTarget(session: oldValue),
                                to: selectedSessionID.map(SelectionTarget.session))
```

`selectProject(_:)` becomes:

```swift
    func selectProject(_ id: UUID) {
        let from = displayedTarget(session: selectedSessionID)
        selectedProjectID = id
        noteSelectionChange(from: from, to: displayedTarget(session: selectedSessionID))
        // Project selection is not persisted, but the history is — and nothing else here
        // persists, so without this a relaunch would lose the entry just recorded.
        persist()
    }
```

In `deselectProject()`, capture `let from = displayedTarget(session: selectedSessionID)` before `selectedProjectID = nil`, then `noteSelectionChange(from: from, to: selectedSessionID.map(SelectionTarget.session))` after it (it already persists).

In `traverseHistory`, make both `isLive` and the landing handle projects:

```swift
            case .project(let path): return repos.contains { $0.url.standardizedFileURL.path == path }
```

```swift
        isSuppressingHistory = true
        defer { isSuppressingHistory = false }
        switch destination {
        case .session(let id)?:
            if selectedProjectID != nil, selectedSessionID == id { deselectProject() }
            else { selectedSessionID = id }
        case .project(let path)?:
            if let repo = repos.first(where: { $0.url.standardizedFileURL.path == path }) {
                selectProject(repo.id)
            }
        case nil: return
        }
```

(`current` in `traverseHistory` becomes `displayedTarget(session: selectedSessionID)`.) Remove master's `case .project: return false` and its comment.

- [ ] **Step 4: Run** `./scripts/test-unit.sh` in the worktree → green, including Task 6's tests.
- [ ] **Step 5: Commit** in the worktree (`feat: include project views in back and forward history`). Confirm `git diff flywheel-intake -- vendor` is empty. **Do not merge into `flywheel-intake`** — report the branch.

---

## Final

- Whole-branch review of master's commits since `f06c1f3` and of `fi-tab-nav` vs `flywheel-intake`.
- Report to the maintainer: master commits, the `fi-tab-nav` branch/worktree, and the GUI checks only he can run — ⌃⌘←/→ with a terminal focused (and ⌘← still jumps to line start), ⌘⇧/ opens/closes and returns focus to the prompt, Help-menu shows ⌘?, Back after a relaunch.
