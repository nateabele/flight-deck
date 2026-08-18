# Terminal Size At Spawn Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every terminal surface a correct size at the moment it is created, so a restored `claude` session never hard-wraps its scrollback at ~50 columns.

**Architecture:** `SessionStore` becomes the single owner of "the terminal pane's content size in points". It seeds that size from the persisted snapshot before any surface exists, hands it to each surface immediately after creation, tracks live resizes for the selected surface, and brings background surfaces up to date once per resize gesture via a debounce. A one-line scale fallback in the embed layer makes a size report correct for a view that is not yet in a window.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest, libghostty via `vendor/ghostty` (submodule, v1.3.1, **not patched**), xcodegen + xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-18-terminal-size-at-spawn-design.md`

## Global Constraints

- **Never make a `SessionSnapshot` field non-optional.** Synthesized `Codable` decodes optionals with `decodeIfPresent`; a required field throws on every existing `sessions.json` and wipes every tab on first launch. The defaults key stays `sessions.snapshot.v1`.
- **Sizes crossing the store/persistence boundary are in points, never pixels.** Scale belongs to the display in use now, not to the snapshot.
- **Do not modify `vendor/ghostty`.** It is a clean submodule at v1.3.1. Changes to the embed layer go in `Sources/FlightDeck/GhosttyEmbed/`, annotated with a `// Flight Deck:` comment in the style already used in that file.
- **Unit test command is `./scripts/test-unit.sh`** (headless, in-process). It runs the whole suite; there is no argument for filtering. Do **not** run `./scripts/smoke.sh` in a loop — it seizes the foreground for ~70s and turns the user's keystrokes into phantom failures.
- **This checkout is shared with other sessions.** Never `git stash`, `git checkout --`, or revert files you did not change. Commit only the paths each task names.
- Match the surrounding comment density. This codebase explains *why* at the point of the decision; a bare implementation with no rationale comment will be rejected in review.

---

### Task 1: Persist the terminal size

**Files:**
- Modify: `Sources/FlightDeck/SessionPersistence.swift`
- Test: `Tests/FlightDeckTests/SessionPersistenceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SessionSnapshot.TerminalSize` (`struct TerminalSize: Codable, Equatable { var width: Double; var height: Double }`) and `SessionSnapshot.terminalSize: TerminalSize?`. Task 2 reads both.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/FlightDeckTests/SessionPersistenceTests.swift`, inside the existing `SessionPersistenceTests` class:

```swift
/// Snapshots predating the field must still decode, or the first launch after this
/// change wipes every tab.
func testSnapshotWithoutTerminalSizeDecodes() throws {
    let id = UUID()
    let json = """
    {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],\
    "sessionCounter":1}
    """
    let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

    XCTAssertEqual(snapshot.sessions.first?.id, id)
    XCTAssertNil(snapshot.terminalSize)
}

func testTerminalSizeRoundTrips() throws {
    var snapshot = SessionSnapshot(sessions: [], sessionCounter: 0)
    snapshot.terminalSize = .init(width: 742.5, height: 618)

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

    XCTAssertEqual(decoded.terminalSize, .init(width: 742.5, height: 618))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'SessionSnapshot' has no member 'terminalSize'`.

- [ ] **Step 3: Add the field**

In `Sources/FlightDeck/SessionPersistence.swift`, add the nested type next to `Project`:

```swift
/// The terminal pane's content size when this snapshot was written.
///
/// Points, not pixels: scale is a property of whichever display the app is on now, so a
/// snapshot written on a Retina display and reopened on a 1x one must not double the
/// column count. `CGSize` is deliberately not used — this file is a JSON schema, and
/// `CGSize`'s `Codable` conformance encodes as an unlabelled array.
struct TerminalSize: Codable, Equatable {
    var width: Double
    var height: Double

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}
```

and the stored property, declared **last**, after `owner`:

```swift
/// The size the terminal pane was last laid out at, so a relaunch can size each surface
/// before its shell can print anything. Without it every restored session spawns into
/// libghostty's placeholder 800x600 *pixel* grid — about 50 columns on a 2x display —
/// and hard-wraps its scrollback there permanently.
///
/// Optional for the same load-bearing reason as `processes` above: synthesized `Codable`
/// decodes an optional with `decodeIfPresent`, so every existing `sessions.json` still
/// decodes instead of throwing and wiping every tab.
var terminalSize: TerminalSize?
```

Declaring it last keeps the synthesized memberwise initializer's existing call sites compiling, since every property has a default.

Note for Task 2: nothing writes this field yet. `SessionStore.persist()` is what fills it in, and that is Task 2's job — Task 1's round-trip test exercises the codec directly.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: the whole suite passes, including `testSnapshotWithoutTerminalSizeDecodes` and `testTerminalSizeRoundTrips`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionPersistence.swift Tests/FlightDeckTests/SessionPersistenceTests.swift
git commit -m "feat: persist the terminal pane's content size in the snapshot"
```

---

### Task 2: Store owns the size and reports it at creation

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Create: `Tests/FlightDeckTests/TerminalSizeTests.swift`

**Interfaces:**
- Consumes: `SessionSnapshot.terminalSize` and `SessionSnapshot.TerminalSize` from Task 1.
- Produces:
  - `SessionStore.terminalSize: CGSize` (`private(set)`)
  - `SessionStore.defaultTerminalSize: CGSize` (`static let`)
  - `SessionStore.sizeReporterOverride: ((UUID, CGSize) -> Void)?`
  - `private func report(_ size: CGSize, to id: UUID)`
  Task 3 adds `terminalSizeDidChange(_:)` and `activateTerminalSize(for:)` alongside these; Task 4 calls those two.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/TerminalSizeTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class TerminalSizeTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        var saveCount = 0
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot; saveCount += 1 }
    }

    private let allDirsExist: (String) -> Bool = { _ in true }

    /// Builds a store whose surfaces are stubbed and whose size reports are recorded
    /// rather than delivered. `restore()` is called by the caller, not here, so a test can
    /// install the recorder before any session exists.
    private func makeStore(_ persistence: FakePersistence) -> SessionStore {
        SessionStore(provider: StubProvider(), persistence: persistence)
    }

    func testRestoredSessionIsSizedFromTheSnapshot() {
        let id = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: id, title: "a", workingDirectory: "/w")],
            selectedSessionID: id,
            sessionCounter: 1
        )
        persistence.stored?.terminalSize = .init(width: 742, height: 618)

        let store = makeStore(persistence)
        var reports: [(UUID, CGSize)] = []
        store.sizeReporterOverride = { reports.append(($0, $1)) }

        store.restore(directoryExists: allDirsExist)

        XCTAssertEqual(store.terminalSize, CGSize(width: 742, height: 618))
        XCTAssertEqual(reports.map(\.0), [id])
        XCTAssertEqual(reports.first?.1, CGSize(width: 742, height: 618))

        // `restore()` ends in `persist()`, so the size must survive the round trip it just
        // made — otherwise the field is written once by Task 1 and never again.
        XCTAssertEqual(persistence.stored?.terminalSize, .init(width: 742, height: 618))
    }

    /// A snapshot from before the field existed has no size to restore, so the surface is
    /// sized from the window geometry `RootWindow` declares rather than from libghostty's
    /// 800x600 pixel placeholder.
    func testRestoreWithoutAPersistedSizeUsesTheDefault() {
        let id = UUID()
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(
            sessions: [.init(id: id, title: "a", workingDirectory: "/w")],
            selectedSessionID: id,
            sessionCounter: 1
        )

        let store = makeStore(persistence)
        var reports: [(UUID, CGSize)] = []
        store.sizeReporterOverride = { reports.append(($0, $1)) }

        store.restore(directoryExists: allDirsExist)

        XCTAssertEqual(store.terminalSize, SessionStore.defaultTerminalSize)
        XCTAssertEqual(reports.first?.1, SessionStore.defaultTerminalSize)
    }

    /// The `sessions.isEmpty && projects.isEmpty` guard in `restore()` returns before the
    /// session loop, but `seedInitialSession()` still creates a surface afterwards — so the
    /// size has to be seeded above that guard.
    func testSizeIsSeededEvenWhenThereIsNothingToRestore() {
        let persistence = FakePersistence()
        persistence.stored = SessionSnapshot(sessions: [], sessionCounter: 0)
        persistence.stored?.terminalSize = .init(width: 900, height: 500)

        let store = makeStore(persistence)
        store.restore(directoryExists: allDirsExist)

        XCTAssertEqual(store.terminalSize, CGSize(width: 900, height: 500))
    }
}
```

`SessionStore(provider:persistence:)` is the designated initializer (`SessionStore.swift:256`) and deliberately does **not** call `restore()` — only the `convenience init` at line 322 does. That is what lets these tests install `sizeReporterOverride` before any surface exists. Use the designated initializer; do not change either one.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — no member `sizeReporterOverride`, `terminalSize`, or `defaultTerminalSize` on `SessionStore`.

- [ ] **Step 3: Add the size, the default, and the choke point**

In `Sources/FlightDeck/SessionStore.swift`, near the other stored state:

```swift
/// The terminal pane's content size in points — the single source of truth for how big
/// every surface's grid should be.
///
/// It exists because there is nowhere else to ask. `restore()` runs inside
/// `SessionStore.init`, which is a `@StateObject` initializer, so every session's shell is
/// forked before SwiftUI has built the scene body: at spawn time there is no window to
/// measure. Seeded from the snapshot, updated by `TerminalHostView`, and handed to each
/// surface the moment it is created.
private(set) var terminalSize: CGSize = SessionStore.defaultTerminalSize

/// What to use on a first-ever launch, when no snapshot has a size to offer.
///
/// Derived from the geometry `RootWindow` declares — `.defaultSize(width: 1000, height:
/// 700)` less the sidebar's 240pt ideal and the title bar. An estimate, and deliberately
/// so: it is only ever wrong for one launch, after which a real layout has been recorded.
static let defaultTerminalSize = CGSize(width: 760, height: 672)

/// Test seam. Production leaves this nil and sizing goes to the live surface — the same
/// arrangement as `injectorOverride`, and for the same reason: `SurfaceProvider` stubs
/// return nil surfaces, so there would otherwise be nothing to assert against.
var sizeReporterOverride: ((UUID, CGSize) -> Void)?

/// The one place a size reaches a surface.
///
/// A zero-sized report is a normal transient state (a container added early, or to a
/// hierarchy that is not on screen yet); upstream Ghostty guards the same call the same
/// way in `SurfaceScrollView.synchronizeCoreSurface`.
private func report(_ size: CGSize, to id: UUID) {
    guard size.width > 0, size.height > 0 else { return }
    if let sizeReporterOverride {
        sizeReporterOverride(id, size)
        return
    }
    surfaces[id]?.sizeDidChange(size)
}
```

- [ ] **Step 4: Report at creation and seed from the snapshot**

In `insertSession`, immediately after `surfaces[session.id] = surface`:

```swift
if let surface = created {
    surfaces[session.id] = surface
    // Before `tick()`, and before anything can be typed at the shell: `ghostty_surface_new`
    // has already forked the child, and until this lands it is talking to libghostty's
    // placeholder 800x600 *pixel* grid — about 50 columns on a 2x display. Anything the
    // child prints in that window is hard-wrapped there for good, because reflow can only
    // rejoin rows the terminal soft-wrapped, not rows the program broke itself.
    report(terminalSize, to: session.id)
}
```

In `restore()`, immediately after `guard let snapshot = persistence?.load() else { return false }` and **above** the `guard !snapshot.sessions.isEmpty || !recorded.isEmpty` line:

```swift
// Above the emptiness guard on purpose. That guard returns early when the last run ended
// with every session closed, and `SessionStore.init` answers a false return by calling
// `seedInitialSession()` — which creates a surface that needs this size just as much as a
// restored one does.
if let size = snapshot.terminalSize {
    terminalSize = CGSize(width: size.width, height: size.height)
}
```

- [ ] **Step 5: Write the size into the snapshot**

In `persist()`, add the field to the `SessionSnapshot(...)` construction:

```swift
// Written on every save rather than only when it changes: it is one small object, and
// the alternative is tracking dirtiness for a value whose whole job is to be present at
// the next launch.
terminalSize: .init(width: terminalSize.width, height: terminalSize.height),
```

Place it to match the property's declaration order in `SessionSnapshot` — after the other labelled arguments the call already passes.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: whole suite passes, including the three new `TerminalSizeTests` cases.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/TerminalSizeTests.swift
git commit -m "fix: size a surface at creation instead of leaving it at libghostty's placeholder"
```

---

### Task 3: Resize handling — live for the selected tab, coalesced for the rest

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Test: `Tests/FlightDeckTests/TerminalSizeTests.swift`

**Interfaces:**
- Consumes: `report(_:to:)`, `terminalSize`, `sizeReporterOverride` from Task 2.
- Produces: `func terminalSizeDidChange(_ size: CGSize)`, `func activateTerminalSize(for id: UUID)`, and `var resizeSettle: (@escaping () -> Void) -> Void`. Task 4 calls the first two.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/FlightDeckTests/TerminalSizeTests.swift`. Add this helper to the class first:

```swift
/// A store with three live sessions in one project, the first selected.
private func makeStoreWithThreeSessions(
    _ persistence: FakePersistence
) -> (SessionStore, [UUID]) {
    let ids = [UUID(), UUID(), UUID()]
    persistence.stored = SessionSnapshot(
        sessions: ids.map { .init(id: $0, title: "s", workingDirectory: "/w") },
        selectedSessionID: ids[0],
        sessionCounter: 3
    )
    let store = makeStore(persistence)
    store.restore(directoryExists: allDirsExist)
    return (store, ids)
}
```

then the cases:

```swift
func testResizeReachesTheSelectedTabImmediatelyAndTheRestOnSettle() {
    let persistence = FakePersistence()
    let (store, ids) = makeStoreWithThreeSessions(persistence)

    var pending: (() -> Void)?
    store.resizeSettle = { pending = $0 }

    var reports: [(UUID, CGSize)] = []
    store.sizeReporterOverride = { reports.append(($0, $1)) }

    store.terminalSizeDidChange(CGSize(width: 900, height: 700))

    // Only the selected tab, until the drag settles.
    XCTAssertEqual(reports.map(\.0), [ids[0]])

    pending?()

    XCTAssertEqual(Set(reports.map(\.0)), Set(ids))
    XCTAssertTrue(reports.allSatisfy { $0.1 == CGSize(width: 900, height: 700) })
}

/// Every frame of a window drag calls this. Only the last size may be broadcast, or a
/// drag costs one grid-and-scrollback reflow per surface per frame.
func testOnlyTheFinalSizeOfADragIsBroadcast() {
    let persistence = FakePersistence()
    let (store, ids) = makeStoreWithThreeSessions(persistence)

    var pending: [() -> Void] = []
    store.resizeSettle = { pending.append($0) }
    store.terminalSizeDidChange(CGSize(width: 900, height: 700))
    store.terminalSizeDidChange(CGSize(width: 950, height: 700))

    var reports: [(UUID, CGSize)] = []
    store.sizeReporterOverride = { reports.append(($0, $1)) }
    for work in pending { work() }

    XCTAssertEqual(Set(reports.map(\.0)), Set(ids), "the superseded settle must be dropped")
    XCTAssertTrue(reports.allSatisfy { $0.1 == CGSize(width: 950, height: 700) })
    XCTAssertEqual(reports.count, ids.count, "exactly one report per surface")
}

/// "Launch, resize, quit" contains no session mutation, so the size would otherwise be
/// lost exactly when the user had just chosen it.
func testASettledResizePersists() {
    let persistence = FakePersistence()
    let (store, _) = makeStoreWithThreeSessions(persistence)

    var pending: (() -> Void)?
    store.resizeSettle = { pending = $0 }
    store.terminalSizeDidChange(CGSize(width: 900, height: 700))
    pending?()

    XCTAssertEqual(
        persistence.stored?.terminalSize, .init(width: 900, height: 700))
}

/// A repeat of the current size is the `updateNSView` path, which runs on every published
/// store change — roughly 2 Hz per live agent.
func testARepeatedSizeIsIgnored() {
    let persistence = FakePersistence()
    let (store, _) = makeStoreWithThreeSessions(persistence)

    // Installed before the first resize, so this case never schedules a real 150ms
    // dispatch that would outlive it and fire into another test's store.
    var pending: [() -> Void] = []
    store.resizeSettle = { pending.append($0) }
    store.terminalSizeDidChange(CGSize(width: 900, height: 700))
    XCTAssertEqual(pending.count, 1, "the first resize is accepted")

    var reports: [(UUID, CGSize)] = []
    store.sizeReporterOverride = { reports.append(($0, $1)) }
    store.terminalSizeDidChange(CGSize(width: 900, height: 700))

    XCTAssertTrue(reports.isEmpty)
    XCTAssertEqual(pending.count, 1, "no second settle scheduled")
}

/// Activation must NOT go through the dedupe: the whole point is that this surface's grid
/// may be stale while the store's size has not moved.
func testActivatingATabReportsTheCurrentSizeEvenWhenItHasNotChanged() {
    let persistence = FakePersistence()
    let (store, ids) = makeStoreWithThreeSessions(persistence)

    var reports: [(UUID, CGSize)] = []
    store.sizeReporterOverride = { reports.append(($0, $1)) }

    store.activateTerminalSize(for: ids[2])

    XCTAssertEqual(reports.map(\.0), [ids[2]])
    XCTAssertEqual(reports.first?.1, store.terminalSize)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — no member `resizeSettle`, `terminalSizeDidChange`, or `activateTerminalSize` on `SessionStore`.

- [ ] **Step 3: Implement**

Add to `Sources/FlightDeck/SessionStore.swift`, next to the members from Task 2:

```swift
/// Test seam. Production waits for a drag to settle before touching background surfaces;
/// tests capture the continuation and run it when they choose. Mirrors `injectionSettle`.
var resizeSettle: (@escaping () -> Void) -> Void = { work in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
}

/// Bumped on every accepted resize so a superseded settle can identify itself and bow out.
/// A counter rather than a cancellable `DispatchWorkItem` because it keeps working
/// unchanged when a test substitutes a `resizeSettle` that runs inline.
private var resizeGeneration = 0

/// The terminal pane was laid out at a new size.
///
/// The selected surface is told straight away — it is the one being watched, and its
/// reflow is the one the user is waiting to see. Every other live surface is told once,
/// after the drag settles. Telling them all per frame would cost one
/// `ghostty_surface_set_size` — a grid *and* scrollback reflow — per surface per frame,
/// and `setSurfaceSize`'s deduplication cannot help, because no two frames of a drag carry
/// the same size.
func terminalSizeDidChange(_ size: CGSize) {
    guard size.width > 0, size.height > 0, size != terminalSize else { return }
    terminalSize = size
    if let selectedSessionID { report(size, to: selectedSessionID) }

    resizeGeneration &+= 1
    let generation = resizeGeneration
    resizeSettle { [weak self] in
        guard let self, self.resizeGeneration == generation else { return }
        // Every surface, not "every surface except the selected one": selection can change
        // between the resize and the settle, and `setSurfaceSize` already discards a repeat
        // of an unchanged pixel size, so the redundant call costs nothing.
        for id in self.surfaces.keys { self.report(self.terminalSize, to: id) }
        // Persisted here rather than left to the next mutation, because "launch, resize the
        // window, quit" contains no mutation — and once per drag gesture is cheap.
        self.persist()
    }
}

/// A tab was selected, so its surface may be carrying a grid from whenever it was last on
/// screen — or, for a tab restored and never opened, from its creation.
///
/// Deliberately not routed through `terminalSizeDidChange`: that method dedupes against
/// the stored size, and here the stored size is exactly what has *not* changed.
func activateTerminalSize(for id: UUID) {
    report(terminalSize, to: id)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: whole suite passes, including the five new cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/TerminalSizeTests.swift
git commit -m "feat: coalesce background-surface resizes to one report per drag"
```

---

### Task 4: Route the view's sizes through the store

**Files:**
- Modify: `Sources/FlightDeck/TerminalPane.swift`

**Interfaces:**
- Consumes: `terminalSizeDidChange(_:)` and `activateTerminalSize(for:)` from Task 3.
- Produces: nothing new.

This task has no new unit test: `TerminalPane` is an `NSViewRepresentable` whose behaviour is covered by Task 3's tests on the store side and by the manual check in Task 6. Verification is that the app builds and the existing suite still passes.

- [ ] **Step 1: Replace the resize hook**

In `makeNSView`, replace the `container.onResize` closure — the store now owns delivery, so the view no longer reaches into its own subviews:

```swift
container.onResize = { [weak store] size in
    store?.terminalSizeDidChange(size)
}
```

- [ ] **Step 2: Replace the attach-time report**

In `updateNSView`, replace the trailing `Self.report(container.bounds.size, to: surface)` call with:

```swift
// Unconditionally, not just on attach. Re-parenting is how tab switching works, so a
// surface that was created off-screen or last shown at a different window size still
// carries that old grid — a resize while another tab was selected is enough to produce
// one. This goes through `activateTerminalSize` rather than `terminalSizeDidChange`
// because the store's size has not changed; only this surface's copy of it is stale.
if let id = store.selectedSessionID {
    store.activateTerminalSize(for: id)
}
```

- [ ] **Step 3: Delete the now-unused private helper**

Remove the `private static func report(_:to:)` method from `TerminalPane` — its zero-size guard now lives in `SessionStore.report(_:to:)`, and leaving a second copy invites the two drifting apart. Update the type-level doc comment on `TerminalHostView` so its explanation of why the subclass exists points at `SessionStore.terminalSizeDidChange` rather than at a call it no longer makes.

- [ ] **Step 4: Verify the build and the suite**

Run: `./scripts/test-unit.sh`
Expected: builds clean (no "unused" or "never used" warnings for the removed helper) and the whole suite passes.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/TerminalPane.swift
git commit -m "refactor: let the store own delivery of terminal sizes to surfaces"
```

---

### Task 5: Correct the points-to-pixels conversion for an unparented view

**Files:**
- Modify: `Sources/FlightDeck/GhosttyEmbed/SurfaceView_AppKit.swift` (the `sizeDidChange` method, around line 471)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing new. This corrects the behaviour of the existing `sizeDidChange(_:)`.

Without this task, Tasks 2-4 report a *point* size to a surface that is not yet in a window, `convertToBacking` returns it unscaled, and libghostty is told those points are pixels — the same bug at a different column count. This task is what makes the creation-time report actually correct, so it must land before the manual verification in Task 6.

- [ ] **Step 1: Replace the conversion**

```swift
func sizeDidChange(_ size: CGSize) {
    // Ghostty wants to know the actual framebuffer size... It is very important
    // here that we use "size" and NOT the view frame. If we're in the middle of
    // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
    // The size represents our final size we're going for.
    //
    // Flight Deck: `convertToBacking` returns the size *unchanged* for a view with no
    // window, and this app sizes surfaces before they are ever parented — a restored
    // session's shell is forked from `SessionStore.init`, long before SwiftUI builds the
    // scene body. Falling back to the main screen's scale keeps that report honest, and
    // matches what `SurfaceConfiguration.withCValue` already hands `ghostty_surface_new`
    // as `scale_factor`. Once the view is in a window, `convertToBacking` is authoritative
    // again — it accounts for which screen the window is actually on.
    let scaledSize: CGSize
    if window != nil {
        scaledSize = convertToBacking(size)
    } else {
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        scaledSize = CGSize(width: size.width * scale, height: size.height * scale)
    }

    setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
    // Store this size so we can reuse it when backing properties change
    contentSize = size
}
```

Leave `contentSize` assignment as it is — it is already in points, and `viewDidChangeBackingProperties` re-scales it with the authoritative `convertToBacking` once the view is parented, so the creation-time value stays consistent.

- [ ] **Step 2: Verify the build and the suite**

Run: `./scripts/test-unit.sh`
Expected: whole suite passes. No new unit test here — `sizeDidChange` needs a live `Ghostty.SurfaceView`, which the headless suite cannot construct; Task 6's manual check is the verification.

- [ ] **Step 3: Commit**

```bash
git add Sources/FlightDeck/GhosttyEmbed/SurfaceView_AppKit.swift
git commit -m "fix: scale a size report from a view that has no window yet"
```

---

### Task 6: Verify against the real app

**Files:**
- Modify: `docs/FOLLOWUPS.md` (only if something is found and deliberately deferred)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Build and swap in the release build**

Run: `./scripts/swap-release.sh`

Follow the ritual that script documents — it SIGKILLs the running app and must be run detached. Do **not** verify a build by executing the bundle directly.

- [ ] **Step 2: Reproduce the original bug's absence**

With at least two sessions open in two different projects, quit and relaunch the app. Then check, in order:

1. The **selected** tab: scroll up. Its restored output must run the full width of the pane, with no narrow left-hand column above the live region.
2. A tab that was **never selected** since launch: switch to it and scroll up. Same expectation — this is the case that was worst before, since it never received a size at all.
3. Resize the window wider while a background session is printing, then switch to it. Its output from after the resize must be at the new width, not the old one.

- [ ] **Step 3: Confirm no snapshot damage**

Run: `cat ~/Library/Application\ Support/Flight\ Deck/sessions.json | python3 -m json.tool | tail -20`
Expected: a `terminalSize` object with plausible point values (a few hundred each), and every session still listed. If sessions vanished, the optionality constraint was violated somewhere — stop and fix Task 1 rather than proceeding.

- [ ] **Step 4: Record anything deferred**

If steps 2-3 surface a residual issue that is out of this plan's scope — the spec names the spawn-to-set_size race and already-wrapped scrollback in a running session as known non-goals — add a line to `docs/FOLLOWUPS.md` describing it. If nothing is found, skip this step and make no commit.

- [ ] **Step 5: Commit (only if Step 4 wrote anything)**

```bash
git add docs/FOLLOWUPS.md
git commit -m "docs: note a follow-up from terminal-size verification"
```
