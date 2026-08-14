# Project Rows in the Sidebar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make sidebar projects directly manipulable — drag to reorder, a leading chevron to collapse, a close button with a suppressible confirmation, and a collapsed summary showing the child count and the highest-priority child status.

**Architecture:** `Repo` gains stored `isCollapsed`; project order and collapsed state persist in the existing `sessions.json` snapshot via a new optional `projects` array. `SessionSidebar` drops SwiftUI `Section`s in favour of a flattened `[SidebarRow]` with a single `.onMove`, backed by a pure `SidebarReorder.apply` function that is unit-tested with no SwiftUI involved. A project's lifetime becomes explicit: it survives its last session and is removed only by its close button.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit (`NSAlert`), XCTest. macOS 14 deployment target. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-14-project-tabs-design.md`

## Global Constraints

- **Deployment target: macOS 14.0.** `.selectionDisabled()`, `Section(isExpanded:)`, and `hasDestructiveAction` are all available; nothing newer may be used.
- **`SWIFT_VERSION: "5.0"`** — Swift 5 language mode, not Swift 6. Do not add `Sendable` conformances or actor isolation annotations to satisfy Swift 6 diagnostics.
- **No new dependencies.** The only frameworks in play are SwiftUI, AppKit, Foundation, OSLog, XCTest.
- **Unit tests run with `./scripts/test-unit.sh`** from the repo root. It runs `xcodegen generate` itself, so new files under `Sources/FlightDeck` and `Tests/FlightDeckTests` are picked up automatically. It prints a standard XCTest summary; "Executed N tests, with 0 failures" is the pass signal.
- **Never run `./scripts/smoke.sh` in a loop.** It takes over the screen for ~40 seconds and steals keyboard focus. Run it at most once, at the end, and only if asked.
- **Do not run `sudo xcode-select`.** The scripts export `DEVELOPER_DIR` themselves.
- **Shared working copy.** Other sessions edit this checkout concurrently. Never `git stash`, `git checkout -- .`, `git reset --hard`, or `git add -A`. Stage only the exact paths each task names.
- **Every commit message ends with:**
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  ```
- **Existing comment style.** This codebase writes long "why" comments on anything non-obvious, and treats a comment that has gone stale as a bug. Match that density.

### Deviation from the spec, recorded deliberately

The spec named two reorder entry points, `moveProjects(fromOffsets:toOffset:)` and `moveSessions(inProjectAt:fromOffsets:toOffset:)`. Because the sidebar ends up with a *single* `.onMove` over the flattened row list, there is one entry point instead: `SessionStore.moveSidebarRows(fromOffsets:toOffset:)`. The project-versus-session distinction lives inside `SidebarReorder.apply`, where it is tested. Nothing else in the spec changes.

---

## File Structure

**Created:**

| File | Responsibility |
| --- | --- |
| `Sources/FlightDeck/SidebarRow.swift` | The flattened row enum and the pure `rows(for:)` builder. No SwiftUI. |
| `Sources/FlightDeck/SidebarReorder.swift` | The pure move function mapping a flat-index move to a new `[Repo]`. No SwiftUI. |
| `Sources/FlightDeck/ProjectHeaderRow.swift` | The project header view: chevron, name, collapsed summary, close button, context menu. |
| `Sources/FlightDeck/ProjectCloseConfirmer.swift` | The confirmation protocol, its decision type, the `NSAlert` implementation, and the coordinator holding the "prompt or not" logic. |
| `Tests/FlightDeckTests/SidebarRowTests.swift` | Row-building tests. |
| `Tests/FlightDeckTests/SidebarReorderTests.swift` | Reorder tests, legal and illegal. |
| `Tests/FlightDeckTests/ProjectCollapseTests.swift` | Collapsed state and collapsed-status-summary tests. |
| `Tests/FlightDeckTests/ProjectPersistenceTests.swift` | Snapshot schema, restore, and v1 compatibility tests. |
| `Tests/FlightDeckTests/ProjectLifetimeTests.swift` | Empty-project survival and `closeProject` teardown tests. |
| `Tests/FlightDeckTests/ProjectCloseCoordinatorTests.swift` | Confirmation branching tests against a fake confirmer. |

**Modified:**

| File | Change |
| --- | --- |
| `Sources/FlightDeck/SessionModel.swift` | `Repo.isCollapsed`. |
| `Sources/FlightDeck/SessionStatus.swift` | `SessionActivity.summaryRank`. |
| `Sources/FlightDeck/SessionStore.swift` | `sidebarRows`, `setCollapsed`, `moveSidebarRows`, `collapsedStatus`, `closeProject`; `closeSession` stops removing empty repos; `restore`/`persist` handle projects. |
| `Sources/FlightDeck/SessionPersistence.swift` | `SessionSnapshot.Project` and the optional `projects` field. |
| `Sources/FlightDeck/SessionSidebar.swift` | Flattened rows replacing `Section`; `.onMove`; header wiring. |
| `Sources/FlightDeck/RootView.swift`, `RootWindow.swift` | Thread `PreferencesStore` down to the sidebar. |
| `Sources/FlightDeck/Preferences/Preferences.swift` | `ConfirmationPreferences` and the optional `confirmations` field. |
| `Sources/FlightDeck/Preferences/PreferencesStore.swift` | `confirmsProjectClose` accessor. |
| `Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift` | The suppression-reset checkbox, and a stale doc comment. |

---

## Task 1: The flattened row model

**Files:**
- Create: `Sources/FlightDeck/SidebarRow.swift`
- Test: `Tests/FlightDeckTests/SidebarRowTests.swift`

**Interfaces:**
- Consumes: `Repo`, `Session` from `Sources/FlightDeck/SessionModel.swift`.
- Produces: `enum SidebarRow: Identifiable, Hashable` with cases `.project(Repo.ID)`, `.session(Session.ID, project: Repo.ID)`, `.empty(Repo.ID)`; `var id: String`; `var projectID: Repo.ID`; `static func rows(for repos: [Repo]) -> [SidebarRow]`. Tasks 2, 4 and 8 all depend on these exact names.

Context you need: `Repo.ID` and `Session.ID` are both `UUID` — each type declares `let id: UUID` and gets `Identifiable` conformance from it. A `Repo` holds `var sessions: [Session]` and (after Task 3) `var isCollapsed: Bool`. **Task 1 runs before `isCollapsed` exists**, so `rows(for:)` is written here against `sessions` only and gains the collapsed branch in Task 3.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/SidebarRowTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SidebarRowTests: XCTestCase {
    private func repo(_ path: String, sessions: Int) -> Repo {
        Repo(
            url: URL(fileURLWithPath: path, isDirectory: true),
            sessions: (0..<sessions).map {
                Session(title: "s\($0)", workingDirectory: path)
            }
        )
    }

    func testExpandedProjectYieldsHeaderThenItsSessions() {
        let a = repo("/w/a", sessions: 2)

        let rows = SidebarRow.rows(for: [a])

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], .project(a.id))
        XCTAssertEqual(rows[1], .session(a.sessions[0].id, project: a.id))
        XCTAssertEqual(rows[2], .session(a.sessions[1].id, project: a.id))
    }

    func testEmptyProjectYieldsAPlaceholderRow() {
        let a = repo("/w/a", sessions: 0)

        let rows = SidebarRow.rows(for: [a])

        // Without the placeholder, an expanded empty project renders identically to a
        // collapsed one — the whole point of the row is to tell those two apart.
        XCTAssertEqual(rows, [.project(a.id), .empty(a.id)])
    }

    func testProjectsAppearInArrayOrder() {
        let a = repo("/w/a", sessions: 1)
        let b = repo("/w/b", sessions: 1)

        let rows = SidebarRow.rows(for: [b, a])

        XCTAssertEqual(rows.first, .project(b.id))
        XCTAssertEqual(rows.last, .session(a.sessions[0].id, project: a.id))
    }

    func testProjectIDIsReadableFromEveryCase() {
        let a = repo("/w/a", sessions: 1)

        XCTAssertEqual(SidebarRow.project(a.id).projectID, a.id)
        XCTAssertEqual(SidebarRow.session(a.sessions[0].id, project: a.id).projectID, a.id)
        XCTAssertEqual(SidebarRow.empty(a.id).projectID, a.id)
    }

    func testIDsAreUniqueAcrossCasesSharingAUUID() {
        // A project and its placeholder share a UUID. If `id` were just that UUID,
        // SwiftUI's ForEach would see duplicate identities and drop a row.
        let a = repo("/w/a", sessions: 0)

        XCTAssertNotEqual(SidebarRow.project(a.id).id, SidebarRow.empty(a.id).id)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'SidebarRow' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FlightDeck/SidebarRow.swift`:

```swift
import Foundation

/// One row of the sidebar, flattened.
///
/// The sidebar deliberately does not use SwiftUI `Section`s. `.onMove` is not supported on
/// a `ForEach` that yields Sections, so section-level drag would need a hand-rolled
/// `.draggable`/`.dropDestination` pair with its own insertion indicator while session rows
/// used `.onMove` — two mechanisms with two different feels. Flattening gives one `.onMove`
/// over one list, and moves the whole reorder decision into `SidebarReorder`, where it is
/// testable without instantiating any SwiftUI.
///
/// The cost is the system's sticky, styled group header. `ProjectHeaderRow` replaces that
/// header's contents wholesale anyway, so the loss is nominal.
enum SidebarRow: Identifiable, Hashable {
    case project(Repo.ID)
    case session(Session.ID, project: Repo.ID)
    /// Stands in for "this project is expanded and has no sessions". Without it, an expanded
    /// empty project is indistinguishable from a collapsed one.
    case empty(Repo.ID)

    /// Prefixed rather than bare: a project and its placeholder carry the same `Repo.ID`, and
    /// two rows with the same identity make `ForEach` drop one of them.
    var id: String {
        switch self {
        case .project(let id): return "p:\(id.uuidString)"
        case .session(let id, _): return "s:\(id.uuidString)"
        case .empty(let id): return "e:\(id.uuidString)"
        }
    }

    /// The project this row belongs to, however it belongs to it.
    var projectID: Repo.ID {
        switch self {
        case .project(let id), .empty(let id): return id
        case .session(_, let project): return project
        }
    }

    static func rows(for repos: [Repo]) -> [SidebarRow] {
        repos.flatMap { repo -> [SidebarRow] in
            let header: SidebarRow = .project(repo.id)
            guard !repo.sessions.isEmpty else { return [header, .empty(repo.id)] }
            return [header] + repo.sessions.map { .session($0.id, project: repo.id) }
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SidebarRow.swift Tests/FlightDeckTests/SidebarRowTests.swift
git commit -m "feat: add the flattened sidebar row model

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: The pure reorder function

**Files:**
- Create: `Sources/FlightDeck/SidebarReorder.swift`
- Test: `Tests/FlightDeckTests/SidebarReorderTests.swift`

**Interfaces:**
- Consumes: `SidebarRow` and `SidebarRow.rows(for:)` from Task 1.
- Produces: `enum SidebarReorder` with `static func apply(to repos: [Repo], rows: [SidebarRow], from source: IndexSet, to destination: Int) -> [Repo]?`. Task 4 wraps it as `SessionStore.moveSidebarRows`.

Context on `.onMove` semantics you must get right: SwiftUI hands you a `destination` expressed as an index in the **pre-move** array — "insert before the element currently at this index" — and `destination == array.count` means "append". `Array.move(fromOffsets:toOffset:)` uses the same convention, so passing the translated offsets straight through is correct.

`nil` return means "illegal move, do nothing". A move that resolves to no change returns the array unchanged rather than `nil`; `Array.move` already handles that case correctly.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/SidebarReorderTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SidebarReorderTests: XCTestCase {
    private func repo(_ path: String, sessions: Int) -> Repo {
        Repo(
            url: URL(fileURLWithPath: path, isDirectory: true),
            sessions: (0..<sessions).map {
                Session(title: "\(path)-s\($0)", workingDirectory: path)
            }
        )
    }

    /// [P_a, a0, a1, P_b, b0]
    private func fixture() -> [Repo] {
        [repo("/w/a", sessions: 2), repo("/w/b", sessions: 1)]
    }

    private func move(_ repos: [Repo], from: Int, to: Int) -> [Repo]? {
        SidebarReorder.apply(
            to: repos,
            rows: SidebarRow.rows(for: repos),
            from: IndexSet(integer: from),
            to: to
        )
    }

    func testDraggingAProjectPastAnotherMovesItsWholeBlock() {
        let repos = fixture()

        // Row 0 is project a's header; row 5 is one past the end (append).
        let moved = move(repos, from: 0, to: 5)

        XCTAssertEqual(moved?.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(moved?.last?.sessions.count, 2, "the project's sessions travel with it")
    }

    func testDroppingAProjectImmediatelyBeforeItsSuccessorIsANoOp() {
        let repos = fixture()

        // Row 3 is project b's header: dropping a just before b leaves a first.
        let moved = move(repos, from: 0, to: 3)

        XCTAssertEqual(moved?.map(\.url.lastPathComponent), ["a", "b"])
    }

    func testASessionReordersWithinItsOwnProject() {
        let repos = fixture()
        let second = repos[0].sessions[1].id

        // Row 2 is a1; row 1 is the first session slot of project a.
        let moved = move(repos, from: 2, to: 1)

        XCTAssertEqual(moved?[0].sessions.map(\.id).first, second)
        XCTAssertEqual(moved?[0].sessions.count, 2)
    }

    func testASessionCannotBeDraggedIntoAnotherProject() {
        let repos = fixture()

        // Row 1 is a0; row 4 sits inside project b's session block.
        XCTAssertNil(move(repos, from: 1, to: 4))
    }

    func testASessionMayLandAtTheEndOfItsOwnProject() {
        let repos = fixture()
        let first = repos[0].sessions[0].id

        // Row 3 is project b's header, which for a *session* of project a means "after a's
        // last session" — inserting before the next project's header is the end of this one.
        // Without this position being legal, the first session could never be dragged last.
        let moved = move(repos, from: 1, to: 3)

        XCTAssertEqual(moved?[0].sessions.map(\.id).last, first)
        XCTAssertEqual(moved?[0].sessions.count, 2)
        XCTAssertEqual(moved?[1].sessions.count, 1, "project b is untouched")
    }

    func testASessionMayLandAtTheEndOfTheLastProject() {
        let repos = fixture()
        let onlyChild = repos[1].sessions[0].id

        // rows.count is the append position, and for b's only session it is legal.
        let moved = move(repos, from: 4, to: 5)

        XCTAssertEqual(moved?[1].sessions.map(\.id), [onlyChild])
    }

    func testACollapsedProjectMovesAsASingleRow() {
        var repos = fixture()
        repos[0].isCollapsed = true

        // Rows are now [P_a, P_b, b0]; row 0 to row 3 appends a after b.
        let moved = move(repos, from: 0, to: 3)

        XCTAssertEqual(moved?.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(moved?.last?.sessions.count, 2, "collapsing hides sessions, never drops them")
    }

    func testAPlaceholderRowCannotBeDragged() {
        let repos = [repo("/w/a", sessions: 0), repo("/w/b", sessions: 1)]

        // Rows are [P_a, empty_a, P_b, b0]; row 1 is the placeholder.
        XCTAssertNil(move(repos, from: 1, to: 3))
    }

    func testAnEmptyProjectStillReorders() {
        let repos = [repo("/w/a", sessions: 0), repo("/w/b", sessions: 1)]

        let moved = move(repos, from: 0, to: 4)

        XCTAssertEqual(moved?.map(\.url.lastPathComponent), ["b", "a"])
    }

    func testAMultiRowSelectionIsRejected() {
        let repos = fixture()

        // The sidebar drags one row at a time; anything else is not a move we model.
        XCTAssertNil(
            SidebarReorder.apply(
                to: repos,
                rows: SidebarRow.rows(for: repos),
                from: IndexSet([0, 1]),
                to: 5
            )
        )
    }

    func testAnOutOfRangeIndexIsRejectedRatherThanTrapping() {
        let repos = fixture()

        XCTAssertNil(move(repos, from: 99, to: 0))
        XCTAssertNil(move(repos, from: 0, to: 99))
    }
}
```

One boundary is worth stating plainly before you implement it, because getting it wrong silently removes a gesture: the flat index of the *next* project's header is a legal destination for a session of the *previous* project. Inserting before the next header is what "move to the end of this project" means, and rejecting that position would make it impossible to drag a project's first session to its last position. That index is only ambiguous if you read it in project space; for a session drag it has exactly one meaning.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'SidebarReorder' in scope`, plus `value of type 'Repo' has no member 'isCollapsed'` from `testACollapsedProjectMovesAsASingleRow`.

Because `isCollapsed` does not land until Task 3, **temporarily comment out `testACollapsedProjectMovesAsASingleRow`** for this task and uncomment it in Task 3 Step 1. Leave a `// TODO(Task 3)` marker on it so it cannot be forgotten.

- [ ] **Step 3: Write the implementation**

Create `Sources/FlightDeck/SidebarReorder.swift`:

```swift
import Foundation

/// Translates a move expressed in flattened sidebar-row indices into a new `[Repo]`.
///
/// Kept as a free function over plain values rather than a method on `SessionStore` so the
/// whole reorder policy — what may move where, and what a drag does to the projects it
/// passes over — is testable without a store, a surface provider, or SwiftUI.
///
/// `nil` means "illegal move; change nothing". A legal move that happens to resolve to no
/// change returns the array unchanged, which is what `Array.move` already does.
enum SidebarReorder {
    static func apply(
        to repos: [Repo],
        rows: [SidebarRow],
        from source: IndexSet,
        to destination: Int
    ) -> [Repo]? {
        // The sidebar drags exactly one row; a multi-row move is not a gesture we model.
        guard source.count == 1, let from = source.first else { return nil }
        guard rows.indices.contains(from) else { return nil }
        // `destination == rows.count` is "append", and is legal.
        guard destination >= 0, destination <= rows.count else { return nil }

        switch rows[from] {
        case .empty:
            // A placeholder is a label, not a thing.
            return nil

        case .project(let projectID):
            guard let source = repos.firstIndex(where: { $0.id == projectID }) else { return nil }
            // The destination in *project* space is however many project headers precede it
            // in row space. This is what makes a project drag move its whole block: the
            // sessions between two headers never contribute to the count.
            let insertion = rows.prefix(destination).filter { row in
                if case .project = row { return true }
                return false
            }.count
            var updated = repos
            updated.move(fromOffsets: IndexSet(integer: source), toOffset: insertion)
            return updated

        case .session(let sessionID, let projectID):
            guard
                let projectIndex = repos.firstIndex(where: { $0.id == projectID }),
                let headerRow = rows.firstIndex(of: .project(projectID)),
                let sessionIndex = repos[projectIndex].sessions
                    .firstIndex(where: { $0.id == sessionID })
            else { return nil }

            // A session may be inserted anywhere inside its own project's block, including
            // the slot just past its last session — which is the flat index of the *next*
            // project's header. That position is not ambiguous for a session drag: inserting
            // before the next header is what "move to the end of this project" means, and
            // rejecting it would make it impossible to drag a project's first session to
            // last. Anything beyond it belongs to another project and is refused.
            //
            // Refused rather than clamped, deliberately: clamping would silently turn "drag
            // into the project below" into "drop at the bottom of this one", which reads as
            // the app ignoring the gesture it was given.
            let firstSlot = headerRow + 1
            let lastSlot = firstSlot + repos[projectIndex].sessions.count
            guard destination >= firstSlot, destination <= lastSlot else { return nil }

            var updated = repos
            updated[projectIndex].sessions.move(
                fromOffsets: IndexSet(integer: sessionIndex),
                toOffset: destination - firstSlot
            )
            return updated
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS, 0 failures (with the collapsed test still commented out).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SidebarReorder.swift Tests/FlightDeckTests/SidebarReorderTests.swift
git commit -m "feat: add the pure sidebar reorder function

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Collapsed state and the collapsed status summary

**Files:**
- Modify: `Sources/FlightDeck/SessionModel.swift:34-46`
- Modify: `Sources/FlightDeck/SessionStatus.swift:8-10`
- Modify: `Sources/FlightDeck/SessionStore.swift` (add members; see steps)
- Modify: `Sources/FlightDeck/SidebarRow.swift` (collapsed branch in `rows(for:)`)
- Modify: `Tests/FlightDeckTests/SidebarReorderTests.swift` (re-enable the collapsed test)
- Test: `Tests/FlightDeckTests/ProjectCollapseTests.swift`

**Interfaces:**
- Consumes: `SidebarRow.rows(for:)` from Task 1.
- Produces: `Repo.isCollapsed: Bool`; `SessionActivity.summaryRank: Int`; `SessionStore.setCollapsed(_ isCollapsed: Bool, forProjectAt id: Repo.ID)`; `SessionStore.collapsedStatus(forProjectAt id: Repo.ID) -> SessionStatus?`; `SessionStore.sidebarRows: [SidebarRow]`. Tasks 7 and 8 call all of these.

Context: `SessionStore.statuses` is `[UUID: SessionStatus]` keyed by session id, `@Published private(set)`. A session with no entry is absent from the map, which renders nothing and is deliberately distinct from `.idle`. `SessionStore.persist()` is private; call it from inside the store.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ProjectCollapseTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ProjectCollapseTests: XCTestCase {
    private func makeStore() -> (SessionStore, SessionPersistenceTests.FakePersistence) {
        let persistence = SessionPersistenceTests.FakePersistence()
        return (SessionStore(provider: nil, persistence: persistence), persistence)
    }

    func testSummaryRankOrdersWaitingAboveShellAboveBusyAboveIdle() {
        XCTAssertGreaterThan(SessionActivity.waiting.summaryRank, SessionActivity.shell.summaryRank)
        XCTAssertGreaterThan(SessionActivity.shell.summaryRank, SessionActivity.busy.summaryRank)
        XCTAssertGreaterThan(SessionActivity.busy.summaryRank, SessionActivity.idle.summaryRank)
    }

    func testCollapsedStatusPicksTheHighestPriorityChild() {
        let (store, _) = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.applyRegistryForTesting([a.id: .init(activity: .busy), b.id: .init(activity: .waiting)])

        XCTAssertEqual(store.collapsedStatus(forProjectAt: project)?.activity, .waiting)
    }

    func testCollapsedStatusIgnoresIdleAndUnstatusedChildren() {
        let (store, _) = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.applyRegistryForTesting([a.id: .init(activity: .idle)])

        XCTAssertNil(store.collapsedStatus(forProjectAt: project))
    }

    func testCollapsedStatusIsNilForAProjectWithNoSessions() {
        let (store, _) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.closeSession(session.id)

        XCTAssertNil(store.collapsedStatus(forProjectAt: project))
    }

    func testCollapsedStatusDropsTheSubagentCount() {
        let (store, _) = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.applyRegistryForTesting([a.id: .init(activity: .busy, subagentCount: 4)])

        // The collapsed header already carries one number — the session count. A second
        // number beside it reads as a second count of the same thing.
        XCTAssertEqual(store.collapsedStatus(forProjectAt: project)?.subagentCount, 0)
    }

    func testSetCollapsedTogglesAndPersists() {
        let (store, persistence) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        let before = persistence.saveCount

        store.setCollapsed(true, forProjectAt: project)

        XCTAssertTrue(store.repos[0].isCollapsed)
        XCTAssertGreaterThan(persistence.saveCount, before)
    }

    func testCollapsedProjectContributesOnlyItsHeaderRow() {
        let (store, _) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id

        XCTAssertEqual(store.sidebarRows.count, 3)
        store.setCollapsed(true, forProjectAt: project)
        XCTAssertEqual(store.sidebarRows, [.project(project)])
    }

    func testACollapsedEmptyProjectHasNoPlaceholder() {
        let (store, _) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.closeSession(session.id)
        store.setCollapsed(true, forProjectAt: project)

        XCTAssertEqual(store.sidebarRows, [.project(project)])
    }
}
```

`testCollapsedStatusIsNilForAProjectWithNoSessions` and `testACollapsedEmptyProjectHasNoPlaceholder` both assume a project survives its last session — that lands in Task 5. **Comment both out for this task**, with a `// TODO(Task 5)` marker, and re-enable them in Task 5 Step 1.

`applyRegistryForTesting` does not exist yet; add it in Step 3 as a test seam, since the real `applyRegistry` takes `[pid_t: ClaudeStatusFile.Entry]` and building those rows is beside the point here.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — no `summaryRank`, no `collapsedStatus`, no `setCollapsed`, no `sidebarRows`, no `applyRegistryForTesting`.

- [ ] **Step 3: Write the implementation**

In `Sources/FlightDeck/SessionModel.swift`, add the field to `Repo` and to its initializer:

```swift
struct Repo: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var displayName: String
    var sessions: [Session]
    /// Whether the sidebar hides this project's session rows. Stored on the model rather
    /// than as view state so it survives a relaunch — see `SessionSnapshot.Project`.
    var isCollapsed: Bool

    init(id: UUID = UUID(), url: URL, sessions: [Session] = [], isCollapsed: Bool = false) {
        self.id = id
        self.url = url
        self.displayName = url.lastPathComponent
        self.sessions = sessions
        self.isCollapsed = isCollapsed
    }
}
```

In `Sources/FlightDeck/SessionStatus.swift`, extend `SessionActivity`:

```swift
extension SessionActivity {
    /// Priority when several children collapse into one glyph on a project header.
    /// Higher wins. Idle sits at the bottom and is filtered out before this is consulted,
    /// but it is ranked anyway so the ordering is total and the tests can state it.
    ///
    /// The order is by how much the state wants you: a blocked prompt outranks a
    /// background command, which outranks work that is simply in progress.
    var summaryRank: Int {
        switch self {
        case .idle: return 0
        case .busy: return 1
        case .shell: return 2
        case .waiting: return 3
        }
    }
}
```

In `Sources/FlightDeck/SidebarRow.swift`, add the collapsed branch to `rows(for:)`:

```swift
    static func rows(for repos: [Repo]) -> [SidebarRow] {
        repos.flatMap { repo -> [SidebarRow] in
            let header: SidebarRow = .project(repo.id)
            guard !repo.isCollapsed else { return [header] }
            guard !repo.sessions.isEmpty else { return [header, .empty(repo.id)] }
            return [header] + repo.sessions.map { .session($0.id, project: repo.id) }
        }
    }
```

In `Sources/FlightDeck/SessionStore.swift`, add these members (put them next to the other repo-facing API, after `closeSession`):

```swift
    // MARK: Projects

    /// The sidebar's rendering order, flattened. Computed rather than stored so it cannot
    /// drift from `repos`; it is cheap, and `repos` is already `@Published`.
    var sidebarRows: [SidebarRow] { SidebarRow.rows(for: repos) }

    func setCollapsed(_ isCollapsed: Bool, forProjectAt id: Repo.ID) {
        guard let index = repos.firstIndex(where: { $0.id == id }),
              repos[index].isCollapsed != isCollapsed else { return }
        repos[index].isCollapsed = isCollapsed
        persist()
    }

    /// The one status a collapsed project header shows: the most demanding thing any child
    /// is doing. Idle and unstatused children contribute nothing, so a quiet project shows
    /// no glyph at all — the same "renders nothing" that an unstatused session row gets.
    ///
    /// The subagent count is deliberately dropped. `SessionStatusIcon` draws it beside the
    /// spinner, and the collapsed header already carries a number (the session count); two
    /// adjacent numerals read as two counts of the same thing.
    func collapsedStatus(forProjectAt id: Repo.ID) -> SessionStatus? {
        guard let repo = repos.first(where: { $0.id == id }) else { return nil }
        guard var best = repo.sessions
            .compactMap({ statuses[$0.id] })
            .filter({ $0.activity != .idle })
            .max(by: { $0.activity.summaryRank < $1.activity.summaryRank })
        else { return nil }
        best.subagentCount = 0
        return best
    }

    /// Test seam. Production statuses arrive through `applyRegistry`, which takes registry
    /// rows keyed by pid; a test that only cares about the sidebar's reading of a status
    /// should not have to fabricate those.
    func applyRegistryForTesting(_ next: [UUID: SessionStatus]) {
        statuses = next
    }
```

In `Tests/FlightDeckTests/SidebarReorderTests.swift`, re-enable `testACollapsedProjectMovesAsASingleRow` and delete its `// TODO(Task 3)` marker.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, 0 failures. The re-enabled reorder test is included; the two Task 5 tests are still commented out.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionModel.swift Sources/FlightDeck/SessionStatus.swift \
        Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/SidebarRow.swift \
        Tests/FlightDeckTests/ProjectCollapseTests.swift \
        Tests/FlightDeckTests/SidebarReorderTests.swift
git commit -m "feat: add collapsed project state and its status summary

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Persist project order and collapsed state

**Files:**
- Modify: `Sources/FlightDeck/SessionPersistence.swift:7-36`
- Modify: `Sources/FlightDeck/SessionStore.swift` (`restore`, `persist`, `moveSidebarRows`)
- Test: `Tests/FlightDeckTests/ProjectPersistenceTests.swift`

**Interfaces:**
- Consumes: `SidebarReorder.apply` (Task 2), `Repo.isCollapsed` (Task 3).
- Produces: `SessionSnapshot.Project` with `var path: String` and `var isCollapsed: Bool`; `SessionSnapshot.projects: [Project]?`; `SessionStore.moveSidebarRows(fromOffsets:toOffset:)`.

Context: `SessionStore.comparablePath(_:)` is a `private static func` used to decide whether two paths are the same project; paths are *stored* verbatim, because the reported string is what `claude` encodes into transcript directory names. `restore` currently guards `guard repos.isEmpty` then `guard let snapshot = persistence?.load(), !snapshot.sessions.isEmpty`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ProjectPersistenceTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ProjectPersistenceTests: XCTestCase {
    private let allDirsExist: (String) -> Bool = { _ in true }

    /// v1 snapshots predate the field. Decoding must not throw, or the first launch after
    /// this change wipes every tab and every project.
    func testV1SnapshotWithoutProjectsDecodes() throws {
        let id = UUID()
        let json = """
        {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],\
        "sessionCounter":1}
        """

        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

        XCTAssertNil(snapshot.projects)
    }

    func testRestoreWithoutProjectsFallsBackToEncounterOrder() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: UUID(), title: "b", workingDirectory: "/w/b"),
                .init(id: UUID(), title: "a", workingDirectory: "/w/a"),
            ],
            sessionCounter: 2
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(store.repos.map(\.isCollapsed), [false, false])
    }

    func testRestoreHonoursRecordedProjectOrderAndCollapsedState() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: UUID(), title: "a", workingDirectory: "/w/a"),
                .init(id: UUID(), title: "b", workingDirectory: "/w/b"),
            ],
            projects: [
                .init(path: "/w/b", isCollapsed: true),
                .init(path: "/w/a", isCollapsed: false),
            ],
            sessionCounter: 2
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(store.repos.map(\.isCollapsed), [true, false])
    }

    func testRestoreAppendsAProjectTheRecordedListDidNotCover() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [
                .init(id: UUID(), title: "a", workingDirectory: "/w/a"),
                .init(id: UUID(), title: "c", workingDirectory: "/w/c"),
            ],
            projects: [.init(path: "/w/a", isCollapsed: false)],
            sessionCounter: 2
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a", "c"])
    }

    func testRestoreSkipsAProjectWhoseDirectoryIsGone() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "a", workingDirectory: "/w/a")],
            projects: [
                .init(path: "/w/deleted", isCollapsed: false),
                .init(path: "/w/a", isCollapsed: false),
            ],
            sessionCounter: 1
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(store.restore(directoryExists: { $0 != "/w/deleted" }))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a"])
    }

    func testAProjectsOnlySnapshotRestoresTheProjectAndSeedsNoSession() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [],
            projects: [.init(path: "/w/a", isCollapsed: true)],
            sessionCounter: 3
        )
        let store = SessionStore(provider: nil, persistence: persistence)

        // Without this, closing every session but keeping the projects would discard the
        // project list on the next launch.
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a"])
        XCTAssertTrue(store.repos[0].sessions.isEmpty)
        XCTAssertTrue(store.repos[0].isCollapsed)
    }

    func testAnEmptySnapshotStillRestoresNothing() {
        let persistence = SessionPersistenceTests.FakePersistence()
        persistence.stored = SessionSnapshot(sessions: [], projects: [], sessionCounter: 0)
        let store = SessionStore(provider: nil, persistence: persistence)

        XCTAssertFalse(store.restore(directoryExists: allDirsExist))
    }

    func testPersistWritesProjectsInOrderWithCollapsedState() {
        let persistence = SessionPersistenceTests.FakePersistence()
        let store = SessionStore(provider: nil, persistence: persistence)
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))
        store.setCollapsed(true, forProjectAt: store.repos[0].id)

        XCTAssertEqual(persistence.stored?.projects?.map(\.path), ["/w/a", "/w/b"])
        XCTAssertEqual(persistence.stored?.projects?.map(\.isCollapsed), [true, false])
    }

    func testMoveSidebarRowsReordersProjectsAndPersists() {
        let persistence = SessionPersistenceTests.FakePersistence()
        let store = SessionStore(provider: nil, persistence: persistence)
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))

        // Rows are [P_a, a0, P_b, b0]; moving row 0 to 4 appends project a after b.
        store.moveSidebarRows(fromOffsets: IndexSet(integer: 0), toOffset: 4)

        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["b", "a"])
        XCTAssertEqual(persistence.stored?.projects?.map(\.path), ["/w/b", "/w/a"])
    }

    func testMoveSidebarRowsIgnoresAnIllegalMove() {
        let persistence = SessionPersistenceTests.FakePersistence()
        let store = SessionStore(provider: nil, persistence: persistence)
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))

        // Row 1 is project a's only session; row 3 is inside project b's block.
        store.moveSidebarRows(fromOffsets: IndexSet(integer: 1), toOffset: 3)

        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a", "b"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `SessionSnapshot` has no `projects`, no `SessionSnapshot.Project`, no `moveSidebarRows`.

- [ ] **Step 3: Write the implementation**

In `Sources/FlightDeck/SessionPersistence.swift`, add the nested type and field to `SessionSnapshot`:

```swift
struct SessionSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        // …unchanged…
    }

    /// A project's sidebar state. Sessions carry their own `workingDirectory`, so this
    /// exists for the two things the session list cannot express: the order the user put
    /// the projects in, and whether a project is collapsed.
    struct Project: Codable, Equatable {
        /// Stored as reported, matching `Session.workingDirectory`. Normalization decides
        /// *whether* two paths are the same project (`SessionStore.comparablePath`); it is
        /// never what gets written down.
        var path: String
        var isCollapsed: Bool

        init(path: String, isCollapsed: Bool = false) {
            self.path = path
            self.isCollapsed = isCollapsed
        }
    }

    var sessions: [Entry] = []
    /// Absent in v1 snapshots. Optional is load-bearing for exactly the reason
    /// `Entry.pinnedConversationID` is: synthesized `Codable` decodes an optional with
    /// `decodeIfPresent`, so every existing `sessions.json` still decodes. `nil` means "no
    /// recorded project state", and `restore` falls back to session-encounter order with
    /// every project expanded.
    var projects: [Project]?
    var selectedSessionID: UUID?
    /// Persisted so a new session cannot reuse a restored session's number.
    var sessionCounter: Int = 0
}
```

Because `SessionSnapshot` uses a memberwise initializer at call sites, adding `projects` between `sessions` and `selectedSessionID` keeps every existing call compiling — they all pass `selectedSessionID:` and `sessionCounter:` by label. Verify that when the suite runs.

In `Sources/FlightDeck/SessionStore.swift`, replace `persist()`:

```swift
    private func persist() {
        persistence?.save(
            SessionSnapshot(
                sessions: repos.flatMap(\.sessions).map {
                    .init(
                        id: $0.id,
                        title: $0.title,
                        workingDirectory: $0.workingDirectory,
                        pinnedConversationID: $0.pinnedConversationID
                    )
                },
                projects: repos.map { .init(path: $0.url.path, isCollapsed: $0.isCollapsed) },
                selectedSessionID: selectedSessionID,
                sessionCounter: sessionCounter
            )
        )
    }
```

Replace `restore`'s guards and add the seeding pass ahead of the session loop:

```swift
    @discardableResult
    func restore(
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard repos.isEmpty else { return false }
        guard let snapshot = persistence?.load() else { return false }
        // Projects outlive their sessions, so a snapshot can legitimately carry projects and
        // no sessions — the state you get after closing every session but no project. The
        // old "no sessions means nothing to restore" guard would have discarded it.
        let recorded = snapshot.projects ?? []
        guard !snapshot.sessions.isEmpty || !recorded.isEmpty else { return false }

        sessionCounter = snapshot.sessionCounter

        // Pass one: seed the projects, in the recorded order, so the sessions below land in
        // existing repos rather than conjuring them in encounter order.
        for project in recorded where directoryExists(project.path) {
            let url = URL(fileURLWithPath: project.path, isDirectory: true)
            guard indexOfRepo(for: url) == nil else { continue }
            repos.append(Repo(url: url, isCollapsed: project.isCollapsed))
        }

        // Pass two: file the sessions. `insertSession` appends a repo for any working
        // directory pass one did not cover, which is what keeps a v1 snapshot working.
        for entry in snapshot.sessions where directoryExists(entry.workingDirectory) {
            let url = URL(fileURLWithPath: entry.workingDirectory, isDirectory: true)
            let conversationID = entry.pinnedConversationID ?? entry.id
            let session = Session(
                id: entry.id,
                title: entry.title,
                workingDirectory: entry.workingDirectory,
                pinnedConversationID: conversationID
            )
            insertSession(
                session,
                in: url,
                initialInput: ClaudeSession.resumeCommand(
                    sessionID: conversationID,
                    title: entry.title,
                    flags: preferences?.resolvedFlags(forProject: entry.workingDirectory) ?? FlagSet()
                )
            )
        }

        let restoredIDs = repos.flatMap(\.sessions).map(\.id)
        selectedSessionID = snapshot.selectedSessionID.flatMap {
            restoredIDs.contains($0) ? $0 : nil
        } ?? restoredIDs.first
        persist()
        // Projects count as "restored something": `SessionStore.init` reads this as
        // `if resetState || !restore() { seedInitialSession() }`, and seeding a home-directory
        // session on top of a restored project list would be wrong. (`seedInitialSession`
        // guards on `repos.isEmpty` too, so this is belt and braces — but the return value is
        // also read by tests, and it should mean what it says.)
        return !restoredIDs.isEmpty || !repos.isEmpty
    }
```

Add the move entry point next to `setCollapsed`:

```swift
    /// The sidebar's single `.onMove` target. The policy — what may move where — lives in
    /// `SidebarReorder`, which is tested without a store; this only applies the result.
    func moveSidebarRows(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let updated = SidebarReorder.apply(
            to: repos, rows: sidebarRows, from: source, to: destination
        ) else { return }
        repos = updated
        persist()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, 0 failures. The pre-existing `SessionPersistenceTests` must still pass unchanged — if any fails, the memberwise-initializer assumption above was wrong and those call sites need `projects: nil` added explicitly.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionPersistence.swift Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/ProjectPersistenceTests.swift
git commit -m "feat: persist project order and collapsed state

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Explicit project lifetime and `closeProject`

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`closeSession`, add `closeProject`)
- Modify: `Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift:3-5` (stale doc comment)
- Modify: `Tests/FlightDeckTests/ProjectCollapseTests.swift` (re-enable two tests)
- Test: `Tests/FlightDeckTests/ProjectLifetimeTests.swift`

**Interfaces:**
- Consumes: `closeSession(_:)`, `persist()`.
- Produces: `SessionStore.closeProject(_ id: Repo.ID)`. Task 6's coordinator calls it.

Context on the change: `closeSession` currently ends with `if repos[repoIndex].sessions.isEmpty { repos.remove(at: repoIndex) }`. That branch goes. A project now appears when it is added or when a session lands in it, and is removed only by `closeProject`. `moveSession` already leaves an emptied source project standing — after this task the two paths finally agree.

Watch the selection logic in `closeSession`: it falls back to `repos.flatMap(\.sessions).first?.id`, which is correct precisely because an emptied repo can sit ahead of a populated one. That line stays.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ProjectLifetimeTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ProjectLifetimeTests: XCTestCase {
    private func makeStore() -> (SessionStore, SessionPersistenceTests.FakePersistence) {
        let persistence = SessionPersistenceTests.FakePersistence()
        return (SessionStore(provider: nil, persistence: persistence), persistence)
    }

    func testClosingTheLastSessionLeavesTheProjectStanding() {
        let (store, persistence) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))

        store.closeSession(session.id)

        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["a"])
        XCTAssertTrue(store.repos[0].sessions.isEmpty)
        XCTAssertEqual(persistence.stored?.projects?.map(\.path), ["/w/a"])
        XCTAssertEqual(persistence.stored?.sessions.count, 0)
    }

    func testAnEmptyProjectSurvivesARelaunch() {
        let (store, persistence) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.closeSession(session.id)

        let relaunched = SessionStore(provider: nil, persistence: persistence)

        XCTAssertTrue(relaunched.restore(directoryExists: { _ in true }))
        XCTAssertEqual(relaunched.repos.map(\.url.lastPathComponent), ["a"])
    }

    func testCloseProjectRemovesTheProjectAndAllItsSessions() {
        let (store, _) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))
        let project = store.repos[0].id

        store.closeProject(project)

        XCTAssertEqual(store.repos.map(\.url.lastPathComponent), ["b"])
    }

    func testCloseProjectTearsDownEveryChildsStatus() {
        let (store, _) = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.applyRegistryForTesting([a.id: .init(activity: .busy), b.id: .init(activity: .waiting)])

        store.closeProject(project)

        XCTAssertNil(store.status(for: a.id))
        XCTAssertNil(store.status(for: b.id))
    }

    func testCloseProjectMovesTheSelectionOffItsChildren() {
        let (store, _) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/b", isDirectory: true))
        let doomed = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos.first { $0.url.lastPathComponent == "a" }!.id
        store.selectedSessionID = doomed.id

        store.closeProject(project)

        XCTAssertNotEqual(store.selectedSessionID, doomed.id)
        XCTAssertNotNil(store.selectedSessionID)
    }

    func testCloseProjectOnAnEmptyProjectJustRemovesIt() {
        let (store, _) = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        let project = store.repos[0].id
        store.closeSession(session.id)

        store.closeProject(project)

        XCTAssertTrue(store.repos.isEmpty)
    }

    func testCloseProjectWithAnUnknownIDDoesNothing() {
        let (store, _) = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))

        store.closeProject(UUID())

        XCTAssertEqual(store.repos.count, 1)
    }
}
```

Also re-enable `testCollapsedStatusIsNilForAProjectWithNoSessions` and `testACollapsedEmptyProjectHasNoPlaceholder` in `Tests/FlightDeckTests/ProjectCollapseTests.swift`, deleting their `// TODO(Task 5)` markers.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'SessionStore' has no member 'closeProject'` — plus failures in `testClosingTheLastSessionLeavesTheProjectStanding` and the two re-enabled collapse tests, because `closeSession` still removes the empty repo.

- [ ] **Step 3: Write the implementation**

In `Sources/FlightDeck/SessionStore.swift`, delete this branch from `closeSession`:

```swift
        if repos[repoIndex].sessions.isEmpty {
            repos.remove(at: repoIndex)
        }
```

and replace it with a comment explaining the absence, since the removal is the kind of thing a future reader would otherwise reinstate:

```swift
        // The project deliberately stays, even emptied. A project's lifetime is explicit:
        // it appears when added or when a session lands in it, and is removed only by
        // `closeProject` — the sidebar's project close button. That also settles a
        // long-standing disagreement with `moveSession`, which has always left an emptied
        // source project standing.
```

Add `closeProject` immediately after `closeSession`:

```swift
    /// Closes every session in a project, then removes the project.
    ///
    /// Deliberately routed through `closeSession` per child rather than reimplementing the
    /// teardown: that method is where surface release, watcher shutdown, status and
    /// subagent-count removal, anchor removal, and notification withdrawal all live, and a
    /// second copy of that list would rot.
    func closeProject(_ id: Repo.ID) {
        guard let index = repos.firstIndex(where: { $0.id == id }) else { return }
        // Snapshot the ids first: `closeSession` mutates `repos`, so iterating the live
        // array would walk off the end.
        for sessionID in repos[index].sessions.map(\.id) {
            closeSession(sessionID)
        }
        // Re-found rather than reusing `index`: every `closeSession` above rewrote `repos`.
        repos.removeAll { $0.id == id }
        persist()
    }
```

In `Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift`, fix the now-false doc comment:

```swift
/// Per-project overrides. The project list is the union of currently-open projects and
/// projects with a saved override — an override outlives the project it belongs to, since
/// closing a project removes it from `SessionStore` entirely.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, 0 failures. Pay attention to pre-existing tests here: anything asserting that a repo disappears when its last session closes is now asserting the old contract. If `SessionStoreTests` or `SessionPersistenceTests` fails on that, update the assertion and its comment to state the new rule — do not weaken the test to make it pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift \
        Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift \
        Tests/FlightDeckTests/ProjectLifetimeTests.swift \
        Tests/FlightDeckTests/ProjectCollapseTests.swift
git commit -m "feat: give projects an explicit lifetime and a close operation

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: The close confirmation and its preference

**Files:**
- Create: `Sources/FlightDeck/ProjectCloseConfirmer.swift`
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift:26-44`
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift` (add accessor)
- Test: `Tests/FlightDeckTests/ProjectCloseCoordinatorTests.swift`

**Interfaces:**
- Consumes: `SessionStore.closeProject` (Task 5).
- Produces: `struct ProjectCloseDecision` with `var confirmed: Bool` and `var suppressFutureConfirmations: Bool`; `protocol ProjectCloseConfirming` with `func confirmClose(projectNamed name: String, sessionCount: Int) async -> ProjectCloseDecision`; `struct NSAlertProjectCloseConfirmer: ProjectCloseConfirming`; `struct ProjectCloseCoordinator` with `init(store:preferences:confirmer:)` and `func requestClose(projectAt id: Repo.ID) async`; `struct ConfirmationPreferences`; `PreferencesStore.confirmsProjectClose: Bool`. Task 8 constructs the coordinator.

Context, and this one is not optional: `UserDefaultsPreferencesPersistence.load()` decodes with `try? JSONDecoder().decode(Preferences.self, from: data)`. Synthesized `Codable` does **not** fall back to a property's default value when a key is missing — it throws. So a new *non-optional* property on `Preferences` would make every existing `preferences.v1` blob fail to decode, and `load()` would return `nil`, silently resetting every flag, project override and shell setting the user has. The new property is optional. Do not "tidy" that away.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ProjectCloseCoordinatorTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ProjectCloseCoordinatorTests: XCTestCase {
    final class FakeConfirmer: ProjectCloseConfirming {
        var decision = ProjectCloseDecision(confirmed: true, suppressFutureConfirmations: false)
        var calls: [(name: String, count: Int)] = []

        func confirmClose(projectNamed name: String, sessionCount: Int) async -> ProjectCloseDecision {
            calls.append((name, sessionCount))
            return decision
        }
    }

    private func fixture(
        sessionsInA: Int
    ) -> (SessionStore, PreferencesStore, FakeConfirmer, Repo.ID) {
        let store = SessionStore(
            provider: nil, persistence: SessionPersistenceTests.FakePersistence()
        )
        for _ in 0..<sessionsInA {
            store.newSession(in: URL(fileURLWithPath: "/w/a", isDirectory: true))
        }
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        return (store, preferences, FakeConfirmer(), store.repos[0].id)
    }

    func testConfirmationDefaultsToOn() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())

        XCTAssertTrue(preferences.confirmsProjectClose)
    }

    func testPreferencesDecodeWithoutTheConfirmationsKey() throws {
        // A v1 preferences blob predates the field. If this throws, `load()` returns nil and
        // every flag, override and shell setting the user has is silently reset.
        let json = """
        {"globalFlags":{"entries":[]},"projectFlags":{},\
        "shell":{"environment":{},"clearChildSessionMarker":true}}
        """

        let decoded = try? JSONDecoder().decode(Preferences.self, from: Data(json.utf8))

        XCTAssertNotNil(decoded, "adding a non-optional key here wipes every preference")
    }

    func testMoreThanOneSessionPrompts() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 2)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertEqual(confirmer.calls.count, 1)
        XCTAssertEqual(confirmer.calls.first?.count, 2)
        XCTAssertEqual(confirmer.calls.first?.name, "a")
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testExactlyOneSessionClosesWithoutPrompting() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 1)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertTrue(confirmer.calls.isEmpty)
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testAnEmptyProjectClosesWithoutPrompting() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 1)
        store.closeSession(store.repos[0].sessions[0].id)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertTrue(confirmer.calls.isEmpty)
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testSuppressedPreferenceSkipsThePrompt() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 3)
        preferences.confirmsProjectClose = false
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertTrue(confirmer.calls.isEmpty)
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testCancellingClosesNothing() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 2)
        confirmer.decision = .init(confirmed: false, suppressFutureConfirmations: false)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 2)
    }

    func testTickingSuppressionWritesThePreference() async {
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 2)
        confirmer.decision = .init(confirmed: true, suppressFutureConfirmations: true)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertFalse(preferences.confirmsProjectClose)
    }

    func testSuppressionIsRecordedEvenWhenCancelling() async {
        // macOS convention: the suppression box applies to the decision the user just made,
        // whichever button they pressed.
        let (store, preferences, confirmer, project) = fixture(sessionsInA: 2)
        confirmer.decision = .init(confirmed: false, suppressFutureConfirmations: true)
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )

        await coordinator.requestClose(projectAt: project)

        XCTAssertFalse(preferences.confirmsProjectClose)
        XCTAssertEqual(store.repos.count, 1)
    }

    func testSuppressionRoundTripsThroughPersistence() {
        let persistence = PreferencesStoreTests.MemoryPersistence()
        let preferences = PreferencesStore(persistence: persistence)

        preferences.confirmsProjectClose = false

        XCTAssertFalse(PreferencesStore(persistence: persistence).confirmsProjectClose)
    }
}
```

If `PreferencesStoreTests.MemoryPersistence` is `private`, make it internal — `SessionLaunchTests` already reaches for it the same way, so the precedent exists.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — no `ProjectCloseConfirming`, `ProjectCloseDecision`, `ProjectCloseCoordinator`, or `confirmsProjectClose`.

- [ ] **Step 3: Write the implementation**

In `Sources/FlightDeck/Preferences/Preferences.swift`, add the type and field:

```swift
/// Alerts the user has chosen to stop seeing.
struct ConfirmationPreferences: Codable, Equatable {
    /// Set by the "Don't ask me again" box on the project-close alert.
    var suppressProjectClose: Bool

    init(suppressProjectClose: Bool = false) {
        self.suppressProjectClose = suppressProjectClose
    }
}

struct Preferences: Codable, Equatable {
    var globalFlags: FlagSet
    var projectFlags: [String: FlagSet]
    var shell: ShellPreferences
    /// Optional, and it has to stay that way. `UserDefaultsPreferencesPersistence.load()`
    /// decodes with `try?`, and synthesized `Codable` throws on a missing key rather than
    /// falling back to a property default — so a non-optional field here would fail to
    /// decode every existing `preferences.v1` blob and silently reset every flag, override
    /// and shell setting the user has. `nil` means "never answered", which is not suppressed.
    var confirmations: ConfirmationPreferences?

    init(
        globalFlags: FlagSet = FlagSet(),
        projectFlags: [String: FlagSet] = [:],
        shell: ShellPreferences = ShellPreferences(),
        confirmations: ConfirmationPreferences? = nil
    ) {
        self.globalFlags = globalFlags
        self.projectFlags = projectFlags
        self.shell = shell
        self.confirmations = confirmations
    }
}
```

In `Sources/FlightDeck/Preferences/PreferencesStore.swift`, add the accessor (put it after the flags section):

```swift
    // MARK: Confirmations

    /// Whether closing a project with several sessions asks first. Phrased positively — the
    /// stored flag is a suppression, but every reader wants the question, and a checkbox
    /// labelled with a negative is a checkbox people get backwards.
    var confirmsProjectClose: Bool {
        get { !(preferences.confirmations?.suppressProjectClose ?? false) }
        set {
            var confirmations = preferences.confirmations ?? ConfirmationPreferences()
            confirmations.suppressProjectClose = !newValue
            preferences.confirmations = confirmations
        }
    }
```

Create `Sources/FlightDeck/ProjectCloseConfirmer.swift`:

```swift
import AppKit

/// What the user decided, and whether they asked not to be asked again.
struct ProjectCloseDecision: Equatable {
    var confirmed: Bool
    var suppressFutureConfirmations: Bool
}

/// Seam over the close confirmation, so the "prompt or not" logic in
/// `ProjectCloseCoordinator` is testable without putting a panel on screen.
@MainActor
protocol ProjectCloseConfirming {
    func confirmClose(projectNamed name: String, sessionCount: Int) async -> ProjectCloseDecision
}

/// The real thing.
///
/// `NSAlert` rather than SwiftUI's `.alert` or `.confirmationDialog`: neither can host a
/// suppression checkbox, and `NSAlert.showsSuppressionButton` exists for exactly this case
/// and draws the platform-standard control.
@MainActor
struct NSAlertProjectCloseConfirmer: ProjectCloseConfirming {
    /// Injectable so a headless context can fall back to a modal run rather than trapping
    /// on a nil window.
    var window: () -> NSWindow? = { NSApp.keyWindow }

    func confirmClose(projectNamed name: String, sessionCount: Int) async -> ProjectCloseDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Close the project “\(name)”?"
        alert.informativeText = """
            This closes \(sessionCount) sessions. Any commands still running in them will be \
            terminated.
            """

        let close = alert.addButton(withTitle: "Close Project")
        close.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        // Return takes the safe path. `addButton` makes the first button the default, and a
        // destructive default is exactly the alert people dismiss into data loss.
        close.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask me again"

        let response: NSApplication.ModalResponse
        if let window = window() {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        return ProjectCloseDecision(
            confirmed: response == .alertFirstButtonReturn,
            // Read after the alert closes, and recorded whichever button was pressed: the
            // box applies to the decision the user just made, which is what every other
            // macOS app does with it.
            suppressFutureConfirmations: alert.suppressionButton?.state == .on
        )
    }
}

/// Decides whether closing a project needs to ask, asks if so, and then closes.
///
/// A separate type from the view so the branching is a unit test rather than a UI test.
@MainActor
struct ProjectCloseCoordinator {
    let store: SessionStore
    let preferences: PreferencesStore?
    let confirmer: ProjectCloseConfirming

    func requestClose(projectAt id: Repo.ID) async {
        guard let repo = store.repos.first(where: { $0.id == id }) else { return }

        // One session or none closes outright — that is what a single session's own close
        // button already does, and an alert to confirm closing one thing is noise.
        guard repo.sessions.count > 1, preferences?.confirmsProjectClose ?? true else {
            store.closeProject(id)
            return
        }

        let decision = await confirmer.confirmClose(
            projectNamed: repo.displayName, sessionCount: repo.sessions.count
        )
        if decision.suppressFutureConfirmations {
            preferences?.confirmsProjectClose = false
        }
        guard decision.confirmed else { return }
        store.closeProject(id)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ProjectCloseConfirmer.swift \
        Sources/FlightDeck/Preferences/Preferences.swift \
        Sources/FlightDeck/Preferences/PreferencesStore.swift \
        Tests/FlightDeckTests/ProjectCloseCoordinatorTests.swift
git commit -m "feat: add the suppressible project-close confirmation

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: The project header view

**Files:**
- Create: `Sources/FlightDeck/ProjectHeaderRow.swift`

**Interfaces:**
- Consumes: `SessionStore.setCollapsed`, `SessionStore.collapsedStatus`, `SessionStore.newSession(in:)`, `SessionStatusIcon`, `Repo`.
- Produces: `struct ProjectHeaderRow: View` with `init(store: SessionStore, repo: Repo, onClose: @escaping () -> Void)`. Task 8 places it.

Context on the hover trick, copied from `SessionRow` because it is the same trick: the close button is **inserted** on hover, not hidden. Inserting it is what pushes the trailing content left, so no manual offsets are needed. And a warning from that same file — `SessionRow` documents that putting `.contentShape(Rectangle())` plus `.onHover` on a row's `HStack` made it a hit-test participant and let it steal clicks from a child gesture. Here the only child that takes clicks is the close `Button`, and SwiftUI gives a `Button` priority over an ancestor's `.onTapGesture`. **Verify that by hand in Step 3** (see the build check); if the header's tap swallows the close button, move the toggle gesture onto the chevron alone.

This task has no unit test: it is a view with no logic that is not already tested in Tasks 3, 5 and 6, and the project takes no new UITests (`smoke.sh` steals focus). Its verification is a build plus a manual look.

- [ ] **Step 1: Write the implementation**

Create `Sources/FlightDeck/ProjectHeaderRow.swift`:

```swift
import SwiftUI

/// A project's row in the sidebar: disclosure chevron, name, and — when collapsed — how
/// many sessions it holds and the most demanding thing any of them is doing.
///
/// The chevron sits on the leading edge, as it does in the Finder and Xcode navigators,
/// rather than using the hover-revealed trailing "Show"/"Hide" that a system `Section`
/// header draws. It is always visible: collapse state has to be legible at a glance, and
/// with the session rows hidden the chevron is the only thing that says so. The close
/// button is the opposite — destructive, so it stays out of the way until pointed at.
struct ProjectHeaderRow: View {
    @ObservedObject var store: SessionStore
    let repo: Repo
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(repo.isCollapsed ? 0 : 90))
                // Hidden but still occupying its space on an empty project: there is nothing
                // to disclose, and collapsing the layout instead would knock every project
                // name out of alignment as sessions come and go.
                .opacity(repo.sessions.isEmpty ? 0 : 1)
                .accessibilityHidden(true)

            Text(repo.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if repo.isCollapsed {
                Text("\(repo.sessions.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // Reused rather than reimplemented so the collapsed and expanded renderings
                // of the same state cannot drift apart.
                SessionStatusIcon(status: store.collapsedStatus(forProjectAt: repo.id))
            }

            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close Project")
                .accessibilityLabel("Close Project")
                .accessibilityIdentifier("close-project")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: repo.isCollapsed)
        .contextMenu {
            Button("New Session") { store.newSession(in: repo.url) }
            Button(repo.isCollapsed ? "Expand" : "Collapse") { toggle() }
            Divider()
            Button("Close Project", role: .destructive, action: onClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("project-header")
    }

    private func toggle() {
        store.setCollapsed(!repo.isCollapsed, forProjectAt: repo.id)
    }

    /// The count and the status glyph reach VoiceOver as words here; on screen they are a
    /// bare numeral and an unnamed symbol.
    private var accessibilityLabel: String {
        var parts = [repo.displayName]
        parts.append(repo.sessions.count == 1 ? "1 session" : "\(repo.sessions.count) sessions")
        parts.append(repo.isCollapsed ? "collapsed" : "expanded")
        if repo.isCollapsed, let status = store.collapsedStatus(forProjectAt: repo.id) {
            parts.append(status.tooltip)
        }
        return parts.joined(separator: ", ")
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `./scripts/build.sh`
Expected: `** BUILD SUCCEEDED **`.

The view is not yet placed anywhere, so this only proves it compiles. `SessionSidebar` still uses `Section`; that is Task 8.

- [ ] **Step 3: Commit**

```bash
git add Sources/FlightDeck/ProjectHeaderRow.swift
git commit -m "feat: add the project header row view

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Wire the sidebar

**Files:**
- Modify: `Sources/FlightDeck/SessionSidebar.swift:126-173`
- Modify: `Sources/FlightDeck/RootView.swift:6-12`
- Modify: `Sources/FlightDeck/RootWindow.swift:6-13`
- Modify: `Sources/FlightDeck/FlightDeckApp.swift:69-70`
- Modify: `Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift` (suppression checkbox)

**Interfaces:**
- Consumes: everything from Tasks 1–7.
- Produces: no new API. This is the wiring task.

Context: `SessionSidebar` keeps its `.dropDestination(for: URL.self)` folder drop and its `.safeAreaInset` new-session button exactly as they are. `SessionRow` is not touched — its hand-rolled double-click rename and its hover behaviour are documented as fragile, and nothing in this task goes near them.

`PreferencesStore` has to reach the sidebar, and today only `SessionStore` is threaded through `RootWindow → RootView → SessionSidebar`. Add it as a parameter at each level.

- [ ] **Step 1: Rewrite the sidebar body**

In `Sources/FlightDeck/SessionSidebar.swift`, replace the `SessionSidebar` struct (leave `SessionRow` above it untouched):

```swift
/// Renders the project→session tree and issues create/switch/close intents to the
/// Store. Rendering only: it holds no session state of its own.
struct SessionSidebar: View {
    @ObservedObject var store: SessionStore
    var preferences: PreferencesStore?
    /// Injectable so a future test can drive the close flow without a panel; production
    /// always gets the real alert.
    var confirmer: ProjectCloseConfirming = NSAlertProjectCloseConfirmer()

    /// Drives both the label and which shortcut the button claims.
    private var isEmpty: Bool { store.repos.isEmpty }

    var body: some View {
        let conflicted = store.conflictedSessionIDs
        return List(selection: $store.selectedSessionID) {
            // One flat ForEach rather than a Section per project: `.onMove` is not supported
            // on a ForEach that yields Sections, and this is what lets one gesture reorder
            // both projects and sessions. See `SidebarRow`.
            ForEach(store.sidebarRows) { row in
                switch row {
                case .project(let projectID):
                    if let repo = store.repos.first(where: { $0.id == projectID }) {
                        ProjectHeaderRow(store: store, repo: repo) {
                            close(projectAt: projectID)
                        }
                        .selectionDisabled()
                    }

                case .session(let sessionID, let projectID):
                    if let repo = store.repos.first(where: { $0.id == projectID }),
                       let session = repo.sessions.first(where: { $0.id == sessionID }) {
                        SessionRow(
                            store: store,
                            session: session,
                            isConflicted: conflicted.contains(session.id)
                        )
                        .tag(session.id)
                    }

                case .empty:
                    Text("No sessions")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
            }
            .onMove { store.moveSidebarRows(fromOffsets: $0, toOffset: $1) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.acceptDroppedURLs(urls) != nil
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                store.createFromMenu()
            } label: {
                HStack {
                    Label(isEmpty ? "Add Project" : "New Session", systemImage: "plus")
                    Spacer()
                    // Apple's HIG puts shortcuts on menu items, not buttons. Shown here
                    // deliberately so the binding is discoverable without opening the menu;
                    // the File menu carries the same two shortcuts.
                    Text(isEmpty ? "⇧⌘A" : "⌘N")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("new-session")
            .keyboardShortcut(isEmpty ? .init("a", modifiers: [.command, .shift])
                                     : .init("n", modifiers: .command))
            .padding(8)
        }
    }

    private func close(projectAt id: Repo.ID) {
        let coordinator = ProjectCloseCoordinator(
            store: store, preferences: preferences, confirmer: confirmer
        )
        Task { await coordinator.requestClose(projectAt: id) }
    }
}
```

- [ ] **Step 2: Thread `PreferencesStore` down to it**

`Sources/FlightDeck/RootView.swift`:

```swift
struct RootView: View {
    @ObservedObject var store: SessionStore
    /// Only the sidebar's project-close confirmation reads this; passed rather than
    /// re-created so it is the same instance the Settings scene edits.
    var preferences: PreferencesStore?

    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store, preferences: preferences)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            // …unchanged…
        }
    }
}
```

`Sources/FlightDeck/RootWindow.swift`:

```swift
struct RootWindow: Scene {
    @ObservedObject var store: SessionStore
    var preferences: PreferencesStore?

    var body: some Scene {
        Window("Flight Deck", id: "main") {
            RootView(store: store, preferences: preferences)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultPosition(.center)
    }
}
```

`Sources/FlightDeck/FlightDeckApp.swift`, in `body`:

```swift
        RootWindow(store: store, preferences: preferences)
            .commands {
```

- [ ] **Step 3: Add the suppression-reset checkbox**

In `Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift`, wrap the existing `NavigationSplitView` so the checkbox spans the tab's full width beneath it. Replace `var body: some View {` and its opening `NavigationSplitView {` with:

```swift
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
```

then, after the closing brace of the `detail:` block (the `}` that currently ends the `NavigationSplitView`), add:

```swift
            Divider()
            HStack {
                // HIG requires a suppressed alert to stay recoverable; this is the recovery.
                // Phrased as the question rather than the suppression — a checkbox whose
                // label is a negative is one people read backwards.
                Toggle(
                    "Confirm before closing a project with multiple sessions",
                    isOn: Binding(
                        get: { preferences.confirmsProjectClose },
                        set: { preferences.confirmsProjectClose = $0 }
                    )
                )
                .accessibilityIdentifier("prefs-confirm-project-close")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
```

Make sure the braces balance: the `VStack` opened in Step 3's first hunk closes at the very end of `body`.

- [ ] **Step 4: Build and run the full suite**

Run: `./scripts/build.sh && ./scripts/test-unit.sh`
Expected: `** BUILD SUCCEEDED **` and 0 test failures.

- [ ] **Step 5: Verify the four interaction behaviours by hand**

Launch the app once — `open "DerivedData/Build/Products/Debug/Flight Deck.app"` — and check:

1. **Drag reorders a project.** Drag a project header past another; both projects keep their sessions, and the order survives quitting and relaunching.
2. **Drag reorders a session inside its project**, and dragging one toward another project is refused rather than silently re-filed.
3. **The chevron collapses**, the collapsed header shows the count and one status glyph, and the selected session's terminal keeps running while its project is collapsed.
4. **The close button works while the header tap toggles collapse.** This is the interaction flagged in Task 7: if clicking the ✕ collapses the project instead of closing it, the header's `.onTapGesture` is stealing the click — move the gesture off the `HStack` and onto the chevron `Image` alone, and note in a comment that a `Button` inside a tap-gesture ancestor did not win.

If `.onMove` gives no drag at all, or fights the folder `.dropDestination`, fall back to `.draggable`/`.dropDestination` with a `SidebarRow` payload behind the same `SidebarReorder.apply` — the spec records this fallback and only the gesture plumbing changes.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionSidebar.swift Sources/FlightDeck/RootView.swift \
        Sources/FlightDeck/RootWindow.swift Sources/FlightDeck/FlightDeckApp.swift \
        Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift
git commit -m "feat: wire draggable, collapsible, closable project rows into the sidebar

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Documentation

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/FOLLOWUPS.md`

**Interfaces:** none.

- [ ] **Step 1: Read what is there**

Run: `rg -n 'sidebar|Repo|Section' docs/ARCHITECTURE.md`

Any passage describing the sidebar as a `List` of `Section`s per repo, or describing a `Repo` as existing only while it has sessions, is now wrong. This codebase treats a stale comment as a bug; the same applies to the docs.

- [ ] **Step 2: Update `docs/ARCHITECTURE.md`**

Correct those passages to describe: the flattened `SidebarRow` list and why it is not `Section`s; `SidebarReorder` as the single place reorder policy lives; project lifetime being explicit; and `SessionSnapshot.projects` carrying order and collapsed state.

- [ ] **Step 3: Record the open question in `docs/FOLLOWUPS.md`**

Add an entry noting that project reorder relies on `.onMove` over a flattened `List`, that the `.draggable`/`.dropDestination` fallback is specified in `docs/superpowers/specs/2026-08-14-project-tabs-design.md` if it ever misbehaves, and — if the Task 8 Step 5 check found the header tap stealing the close click — how that was resolved.

- [ ] **Step 4: Commit**

```bash
git add docs/ARCHITECTURE.md docs/FOLLOWUPS.md
git commit -m "docs: describe the flattened sidebar and explicit project lifetime

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage.** Drag to reorder projects → Tasks 1, 2, 4, 8. Drag sessions within a project → Tasks 2, 8. Leading chevron with persisted collapse → Tasks 3, 4, 7. Close button → Tasks 5, 7, 8. Collapsed count and single status glyph → Tasks 3, 7. Suppressible confirmation → Task 6. Preferences reset control → Task 8 Step 3. Snapshot schema and v1 compatibility → Task 4. Explicit project lifetime → Task 5. Restore guard change → Task 4. Accessibility labelling → Task 7. Every spec section maps to a task.

**Ordering hazards, all handled explicitly:** `Repo.isCollapsed` does not exist until Task 3, so one reorder test is commented out in Task 2 and re-enabled in Task 3; empty projects do not survive until Task 5, so two collapse tests are commented out in Task 3 and re-enabled in Task 5. Both carry `// TODO(Task N)` markers.

**Naming consistency, checked across tasks:** `SidebarRow.rows(for:)`, `SidebarReorder.apply(to:rows:from:to:)`, `setCollapsed(_:forProjectAt:)`, `collapsedStatus(forProjectAt:)`, `moveSidebarRows(fromOffsets:toOffset:)`, `closeProject(_:)`, `summaryRank`, `confirmsProjectClose`, `ProjectCloseDecision.confirmed` / `.suppressFutureConfirmations`, `confirmClose(projectNamed:sessionCount:)` — each is spelled identically everywhere it appears.
