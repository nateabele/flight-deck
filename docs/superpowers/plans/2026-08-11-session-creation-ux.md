# Session Creation UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Flight Deck a true single-window app with keyboard-driven session creation: ⌘N adds a session directly below the active one, ⌘⇧A adds a project, and folders can be dropped on the sidebar.

**Architecture:** `RootWindow` becomes a `Window` scene, which both enforces one window and frees ⌘N from `WindowGroup`'s New Window. `SessionStore` moves up to `FlightDeckApp` so `.commands` can drive it. Two creation intents differ only in *where* the session lands: `newSessionBelowActive()` inserts at `activeIndex + 1`, `addProject(at:)` appends.

**Tech Stack:** Swift 5 language mode, SwiftUI, AppKit, XCTest, XcodeGen (`project.yml`), embedded libghostty.

## Global Constraints

- Target module is `FlightDeck`; tests live in `Tests/FlightDeckTests/` and use `XCTest` with `@testable import FlightDeck`.
- Unit tests run with `./scripts/test-unit.sh`; the UITest gate runs with `./scripts/smoke.sh`. Never invoke `xcodebuild` directly.
- `SessionStore` is `@MainActor`. Anything it calls synchronously must be main-actor safe.
- Never launch a real `claude` process from a test.
- Existing accessibility identifiers must keep working: `new-session`, `close-session`, `session-row-title`, `session-title-field`.
- Every UITest passes `-ApplePersistenceIgnoreState YES` and `-FlightDeckResetState YES`; new UITests must too.
- Do not change how sessions launch or restore (`ClaudeSession.launchCommand` / `resumeCommand`).

---

### Task 1: Single window

Swap the scene type and delete the guard it makes unreachable. **This task changes the scene and nothing else**, because the XCUITest window problem documented in `docs/done/HANDOFF-smoke-gate.md` was specific to how `WindowGroup` materialises its first window under a raw-exec launch — if `Window` regresses that, we need to know here and not three tasks later.

**Files:**
- Modify: `Sources/FlightDeck/RootWindow.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (delete `hasRestoredInProcess`)

**Interfaces:**
- Consumes: nothing.
- Produces: `SessionStore.init(ghostty:resetState:)` keeps its signature; only its body loses the static guard.

- [ ] **Step 1: Change the scene type**

```swift
// Sources/FlightDeck/RootWindow.swift
import SwiftUI

/// A `Window`, not a `WindowGroup`: Flight Deck is a single-window app. This is also what
/// frees ⌘N — `WindowGroup` claims it for File ▸ New Window. Closing this window quits,
/// because `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns true.
struct RootWindow: Scene {
    let ghostty: GhosttyApp?

    var body: some Scene {
        Window("Flight Deck", id: "main") {
            RootView(ghostty: ghostty)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultPosition(.center)
    }
}
```

- [ ] **Step 2: Delete the now-unreachable multi-window guard**

In `SessionStore`, remove the `private static var hasRestoredInProcess = false` declaration and simplify the convenience initializer to:

```swift
    /// `resetState` comes from the `-FlightDeckResetState YES` launch argument: `smoke.sh`
    /// wipes defaults once per run, but the UITest bundle launches the app once per test
    /// case, so a session persisted by an earlier case would otherwise survive into a later
    /// one and make tests order-dependent.
    convenience init(ghostty: GhosttyApp?, resetState: Bool = false) {
        self.init(provider: ghostty, persistence: UserDefaultsSessionPersistence())
        if resetState || !restore() { seedInitialSession() }
    }
```

The deleted guard existed only to stop a *second window* from restoring the same snapshot. A `Window` scene cannot produce a second window, so the guard now defends against an impossible state.

- [ ] **Step 3: Run the unit suite**

Run: `./scripts/test-unit.sh 2>&1 | tail -6`
Expected: PASS. `SessionPersistenceTests.testResetStateSkipsRestoreEvenWithAStoredSnapshot` exercises the initializer you just changed — it must still pass.

- [ ] **Step 4: Run the smoke gate — this is the point of doing this task alone**

Run: `./scripts/smoke.sh 2>&1 | rg -i 'Test Case.*(passed|failed)|SMOKE' | tail -6`
Expected: all 4 UITests pass, `SMOKE PASS`.

If a test now fails to find a window, **stop and report** rather than patching around it: it means `Window` materialises differently under XCUITest's raw exec, which is a finding that changes the plan.

- [ ] **Step 5: Verify File ▸ New Window is gone**

Run: `./scripts/build.sh 2>&1 | tail -2 && open DerivedData/Build/Products/Debug/FlightDeck.app`
Check by hand that the File menu no longer offers New Window, then quit the app. This is the observable proof that ⌘N is free.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/RootWindow.swift Sources/FlightDeck/SessionStore.swift
git commit -m "feat: make Flight Deck a single-window app"
```

---

### Task 2: Move SessionStore ownership to the App

`.commands` cannot reach a `@StateObject` owned by `RootView`, so the store moves up. With one window this is also simply where it belongs.

**Files:**
- Modify: `Sources/FlightDeck/FlightDeckApp.swift`
- Modify: `Sources/FlightDeck/RootWindow.swift`
- Modify: `Sources/FlightDeck/RootView.swift`

**Interfaces:**
- Consumes: `SessionStore.init(ghostty:resetState:)` from Task 1.
- Produces: `RootWindow(store:)` and `RootView(store:)` both take a `SessionStore`; neither constructs one.

- [ ] **Step 1: Own the store on the App**

```swift
// Sources/FlightDeck/FlightDeckApp.swift
import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore

    init() {
        // Read the launch argument here rather than in a view: with a single window the
        // store is app-scoped, and `.commands` needs to reach it. The libghostty app comes
        // from a process-wide static, NOT from the delegate — the delegate does not exist
        // yet at this point (see Step 2).
        let resetState = UserDefaults.standard.bool(forKey: "FlightDeckResetState")
        _store = StateObject(
            wrappedValue: SessionStore(ghostty: GhosttyApp.shared, resetState: resetState)
        )
    }

    var body: some Scene {
        RootWindow(store: store)
    }
}
```

- [ ] **Step 2: Make the libghostty app a process-wide static**

`@NSApplicationDelegateAdaptor` does **not** construct its delegate before `App.init` runs, so
reaching the delegate from there yields nil. Do not try to publish the delegate; remove the
ordering dependency instead. Add to `Sources/FlightDeck/GhosttyEmbed/GhosttyApp.swift`:

```swift
    /// The one libghostty app for the process.
    ///
    /// A lazy static rather than something owned by a particular object: created on first
    /// access, never freed, and therefore impossible for a surface to outlive — the same
    /// teardown-lifetime guarantee `AppDelegate` ownership gave us, minus any dependency on
    /// *when* the delegate happens to be constructed.
    static let shared: GhosttyApp? = GhosttyApp()
```

and in `Sources/FlightDeck/AppDelegate.swift` change the stored property to share it:

```swift
    let ghostty: GhosttyApp? = GhosttyApp.shared
```

This second edit is load-bearing: if `AppDelegate` kept calling `GhosttyApp()` directly there
would be **two** libghostty apps in one process — `ghostty_init`'s one-time guard does not
stop a second `ghostty_app_new`.

- [ ] **Step 3: Thread the store through the scene and view**

```swift
// Sources/FlightDeck/RootWindow.swift — replace `let ghostty:` and the RootView call
struct RootWindow: Scene {
    @ObservedObject var store: SessionStore

    var body: some Scene {
        Window("Flight Deck", id: "main") {
            RootView(store: store)
                .frame(minWidth: 800, minHeight: 500)
        }
        .defaultSize(width: 1000, height: 700)
        .defaultPosition(.center)
    }
}
```

```swift
// Sources/FlightDeck/RootView.swift — replace the init and the property
struct RootView: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        // ... unchanged body ...
    }
}
```

Delete `RootView.init(ghostty:)` entirely.

- [ ] **Step 4: Run both gates**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Then: `./scripts/smoke.sh 2>&1 | rg -i 'Test Case.*(passed|failed)|SMOKE' | tail -6`
Expected: unit PASS; all 4 UITests pass, `SMOKE PASS`. The reset-state path now runs from `FlightDeckApp.init` instead of `RootView.init`, so a UITest regression here means the launch argument is no longer being read.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightDeckApp.swift Sources/FlightDeck/RootWindow.swift Sources/FlightDeck/RootView.swift Sources/FlightDeck/AppDelegate.swift
git commit -m "refactor: own SessionStore at app scope for menu commands"
```

---

### Task 3: Insert below the active session

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Test: `Tests/FlightDeckTests/SessionCreationTests.swift`

**Interfaces:**
- Consumes: `SessionStore.newSession(in:)`, `locate(_:)`, `insertSession(_:in:initialInput:)`.
- Produces:
  - `SessionStore.newSession(in url: URL, at index: Int? = nil) -> Session`
  - `SessionStore.newSessionBelowActive() -> Session?` (nil when nothing is active)
  - `SessionStore.addProject(at url: URL) -> Session`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SessionCreationTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionCreationTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    private func makeStore() -> SessionStore {
        SessionStore(provider: StubProvider())
    }

    private func titles(_ store: SessionStore) -> [String] {
        store.repos.flatMap(\.sessions).map(\.title)
    }

    /// Three sessions with the active one in the MIDDLE: an append-to-end regression
    /// would put the new session last and fail this.
    func testNewSessionBelowActiveInsertsDirectlyAfterTheActiveSession() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        let first = store.newSession(in: url)
        let middle = store.newSession(in: url)
        _ = store.newSession(in: url)

        store.selectedSessionID = middle.id
        let created = store.newSessionBelowActive()

        XCTAssertNotNil(created)
        XCTAssertEqual(
            titles(store),
            ["session 1", "session 2", "session 4", "session 3"],
            "the new session must sit directly below the active one, not at the end"
        )
        XCTAssertEqual(store.repos[0].sessions[2].id, created?.id)
        _ = first
    }

    func testNewSessionBelowActiveSelectsTheNewSession() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        _ = store.newSession(in: url)
        let created = store.newSessionBelowActive()
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    /// It inherits the ACTIVE session's project, not the first repo's.
    func testNewSessionBelowActiveUsesTheActiveSessionsProject() {
        let store = makeStore()
        _ = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let bar = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))

        store.selectedSessionID = bar.id
        let created = store.newSessionBelowActive()

        XCTAssertEqual(created?.workingDirectory, "/work/bar")
        XCTAssertEqual(store.repos.map(\.displayName), ["foo", "bar"])
        XCTAssertEqual(store.repos[1].sessions.count, 2)
    }

    func testNewSessionBelowActiveDoesNothingWithNoActiveSession() {
        let store = makeStore()
        XCTAssertNil(store.newSessionBelowActive())
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testAddProjectCreatesANewRepo() {
        let store = makeStore()
        let created = store.addProject(at: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(store.repos.map(\.displayName), ["foo"])
        XCTAssertEqual(store.selectedSessionID, created.id)
    }

    /// Dropping or adding an already-known folder adds another session to it.
    func testAddProjectOnAnExistingRepoAppendsAndActivates() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        _ = store.newSession(in: url)
        let created = store.addProject(at: url)

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 2)
        XCTAssertEqual(store.repos[0].sessions.last?.id, created.id)
        XCTAssertEqual(store.selectedSessionID, created.id)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -8`
Expected: FAIL — no `newSessionBelowActive` / `addProject` members.

- [ ] **Step 3: Add an insertion index to the primitive**

Change `insertSession`'s signature and its append line:

```swift
    private func insertSession(
        _ session: Session, in url: URL, initialInput: String, at index: Int? = nil
    ) -> Session {
```

Replace `repos[repoIndex].sessions.append(session)` with:

```swift
        // `index` is a position within this repo's sessions; out-of-range falls back to
        // appending so a stale index can never trap.
        if let index, index >= 0, index <= repos[repoIndex].sessions.count {
            repos[repoIndex].sessions.insert(session, at: index)
        } else {
            repos[repoIndex].sessions.append(session)
        }
```

- [ ] **Step 4: Add the index parameter to `newSession` and the two new intents**

Change `newSession(in:)` to `newSession(in url: URL, at index: Int? = nil) -> Session`, forwarding `at: index` to `insertSession`. Everything else in that method stays as it is.

Then add:

```swift
    /// ⌘N. Creates a session in the ACTIVE session's project, directly below it, and
    /// activates it. Returns nil when nothing is active — the caller routes that case to
    /// `addProject` instead (see `SessionCreateAction`).
    @discardableResult
    func newSessionBelowActive() -> Session? {
        guard let activeID = selectedSessionID, let at = locate(activeID) else { return nil }
        let active = repos[at.repo].sessions[at.session]
        let url = URL(fileURLWithPath: active.workingDirectory, isDirectory: true)
        return newSession(in: url, at: at.session + 1)
    }

    /// ⌘⇧A and folder drops. A new folder becomes a project; a known one gains another
    /// session. Either way the new session is appended to its project and activated.
    @discardableResult
    func addProject(at url: URL) -> Session {
        newSession(in: url)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -6`
Expected: PASS, including every pre-existing suite — `newSession(in:)` gained a defaulted parameter, so existing call sites are unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionCreationTests.swift
git commit -m "feat: insert new sessions below the active one"
```

---

### Task 4: Pure creation helpers

The ⌘N routing rule and the dropped-URL rule, as pure functions, so both are testable without a menu or a drag session.

**Files:**
- Create: `Sources/FlightDeck/SessionCreation.swift`
- Test: `Tests/FlightDeckTests/SessionCreationHelperTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SessionCreateAction { case newSession, addProject }`
  - `SessionCreateAction.forState(hasSessions: Bool) -> SessionCreateAction`
  - `SessionCreateAction.projectDirectory(for url: URL) -> URL`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SessionCreationHelperTests.swift
import XCTest
@testable import FlightDeck

final class SessionCreationHelperTests: XCTestCase {
    func testRoutesToNewSessionWhenSessionsExist() {
        XCTAssertEqual(SessionCreateAction.forState(hasSessions: true), .newSession)
    }

    /// With nothing open there is no project to create a session in, so ⌘N must fall
    /// through to Add Project.
    func testRoutesToAddProjectWhenEmpty() {
        XCTAssertEqual(SessionCreateAction.forState(hasSessions: false), .addProject)
    }

    func testDirectoryResolvesToItself() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(
            SessionCreateAction.projectDirectory(for: dir).standardizedFileURL,
            dir.standardizedFileURL
        )
    }

    /// Dropping a file from a repo adds the repo, not nothing.
    func testFileResolvesToItsParentDirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("README.md")
        try "hi".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            SessionCreateAction.projectDirectory(for: file).standardizedFileURL,
            dir.standardizedFileURL
        )
    }

    func testNonexistentPathResolvesToItsParent() {
        let missing = URL(fileURLWithPath: "/nope/does-not-exist/file.txt")
        XCTAssertEqual(
            SessionCreateAction.projectDirectory(for: missing).path,
            "/nope/does-not-exist"
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -6`
Expected: FAIL — `cannot find 'SessionCreateAction' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/SessionCreation.swift
import Foundation

/// Which creation intent a trigger resolves to, and how a dropped URL becomes a project
/// directory. Pure so both rules are testable without a menu or a real drag session.
enum SessionCreateAction: Equatable {
    /// Add a session to the active project (⌘N).
    case newSession
    /// Pick or accept a folder and create a session in it (⌘⇧A, folder drop).
    case addProject

    /// ⌘N reroutes to Add Project when nothing is open.
    ///
    /// The menu item stays enabled in both states deliberately: a disabled `NSMenuItem`
    /// does not fire its key equivalent, so disabling New Session when empty would make ⌘N
    /// dead in exactly the state it needs to work.
    static func forState(hasSessions: Bool) -> SessionCreateAction {
        hasSessions ? .newSession : .addProject
    }

    /// A directory resolves to itself; anything else resolves to its parent, so dropping a
    /// file out of a repo adds that repo. A path that does not exist is treated as a file.
    static func projectDirectory(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -6`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionCreation.swift Tests/FlightDeckTests/SessionCreationHelperTests.swift
git commit -m "feat: add creation-routing and dropped-URL helpers"
```

---

### Task 5: Menu commands

**Files:**
- Modify: `Sources/FlightDeck/FlightDeckApp.swift`
- Create: `Sources/FlightDeck/SessionCommands.swift`

**Interfaces:**
- Consumes: `SessionStore.newSessionBelowActive()`, `SessionStore.addProject(at:)`, `SessionCreateAction.forState(hasSessions:)`, `FolderPicker.choose()`.
- Produces: `SessionCommands: Commands`, and `SessionStore.createFromMenu()` used by both the menu and the sidebar button.

- [ ] **Step 1: Add the shared entry point to the store**

Both the ⌘N menu item and the sidebar button need the same routing, so it lives in one place. Add to `SessionStore`:

```swift
    /// The ⌘N / sidebar-button action. Routes to Add Project when nothing is open, which is
    /// why the menu item can stay enabled in both states.
    @discardableResult
    func createFromMenu(chooseFolder: () -> URL? = { FolderPicker.choose() }) -> Session? {
        switch SessionCreateAction.forState(hasSessions: !repos.isEmpty) {
        case .newSession:
            return newSessionBelowActive()
        case .addProject:
            guard let url = chooseFolder() else { return nil }
            return addProject(at: url)
        }
    }

    /// ⌘⇧A. Always prompts, regardless of what is open.
    @discardableResult
    func addProjectFromMenu(chooseFolder: () -> URL? = { FolderPicker.choose() }) -> Session? {
        guard let url = chooseFolder() else { return nil }
        return addProject(at: url)
    }
```

- [ ] **Step 2: Write the failing tests**

Append to `Tests/FlightDeckTests/SessionCreationTests.swift`:

```swift
    func testCreateFromMenuAddsBelowActiveWhenSessionsExist() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        _ = store.newSession(in: url)
        var prompted = false
        let created = store.createFromMenu(chooseFolder: { prompted = true; return nil })

        XCTAssertFalse(prompted, "⌘N must not prompt for a folder when a session is active")
        XCTAssertEqual(store.repos[0].sessions.count, 2)
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    /// The reroute: with nothing open, ⌘N behaves as Add Project.
    func testCreateFromMenuPromptsAndAddsProjectWhenEmpty() {
        let store = makeStore()
        var prompted = false
        let created = store.createFromMenu(chooseFolder: {
            prompted = true
            return URL(fileURLWithPath: "/work/bar", isDirectory: true)
        })

        XCTAssertTrue(prompted)
        XCTAssertEqual(store.repos.map(\.displayName), ["bar"])
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    func testCancellingTheFolderPickerCreatesNothing() {
        let store = makeStore()
        XCTAssertNil(store.createFromMenu(chooseFolder: { nil }))
        XCTAssertTrue(store.repos.isEmpty)
    }

    func testAddProjectFromMenuAlwaysPromptsEvenWithSessionsOpen() {
        let store = makeStore()
        _ = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let created = store.addProjectFromMenu(chooseFolder: {
            URL(fileURLWithPath: "/work/bar", isDirectory: true)
        })
        XCTAssertEqual(store.repos.map(\.displayName), ["foo", "bar"])
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }
```

- [ ] **Step 3: Run tests to verify they fail, then pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -6`
Expected: FAIL first (no `createFromMenu`), then PASS once Step 1's code is in.

- [ ] **Step 4: Add the menu commands**

```swift
// Sources/FlightDeck/SessionCommands.swift
import SwiftUI

/// File-menu items for session creation. Both stay enabled in every state: a disabled
/// `NSMenuItem` does not fire its key equivalent, and ⌘N specifically must work when there
/// are no sessions (it reroutes to Add Project).
struct SessionCommands: Commands {
    @ObservedObject var store: SessionStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session") { store.createFromMenu() }
                .keyboardShortcut("n", modifiers: .command)

            Button("Add Project…") { store.addProjectFromMenu() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }
}
```

Wire it in `FlightDeckApp.body`:

```swift
    var body: some Scene {
        RootWindow(store: store)
            .commands { SessionCommands(store: store) }
    }
```

`CommandGroup(replacing: .newItem)` is deliberate: it takes over the slot where New Window used to live, so there is no leftover New-anything item.

- [ ] **Step 5: Verify by hand**

Run: `./scripts/build.sh 2>&1 | tail -2 && open DerivedData/Build/Products/Debug/FlightDeck.app`
Check: File menu shows "New Session ⌘N" and "Add Project… ⌘⇧A"; ⌘N adds a session below the active one; ⌘⇧A opens the folder picker. Quit when done.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionCommands.swift Sources/FlightDeck/FlightDeckApp.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionCreationTests.swift
git commit -m "feat: add New Session and Add Project menu commands"
```

---

### Task 6: Sidebar button follows state

**Files:**
- Modify: `Sources/FlightDeck/SessionSidebar.swift`
- Modify: `Sources/FlightDeck/RootView.swift` (empty-state button)
- Modify: `UITests/FlightDeckUITests/TerminalSmokeTests.swift`

**Interfaces:**
- Consumes: `SessionStore.createFromMenu()`, `SessionCreateAction.forState(hasSessions:)`.
- Produces: no new API. The `new-session` accessibility identifier stays on the button in both states.

- [ ] **Step 1: Make the button state-driven**

Replace the `.safeAreaInset(edge: .bottom)` button in `SessionSidebar` with:

```swift
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
```

and add to `SessionSidebar`:

```swift
    /// Drives both the label and which shortcut the button claims.
    private var isEmpty: Bool { store.repos.isEmpty }
```

- [ ] **Step 2: Point the empty-state button at the same path**

In `RootView`, replace the `ContentUnavailableView` action button body with:

```swift
                    Button("Add Project") { store.addProjectFromMenu() }
```

Delete the inline `FolderPicker.choose()` call there — routing now lives in one place.

- [ ] **Step 3: Write the UITest**

Append to `TerminalSmokeTests`:

```swift
    /// ⌘N adds a session below the active one. Asserts on row count so an implementation
    /// that opens a folder picker instead (the pre-feature behaviour) fails here.
    func testCommandNAddsASessionBelowTheActiveOne() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let rows = app.staticTexts.matching(identifier: "session-row-title")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)

        app.typeKey("n", modifierFlags: .command)

        let two = NSPredicate(format: "count == 2")
        expectation(for: two, evaluatedWith: rows)
        waitForExpectations(timeout: 10)
    }

    /// The button's label follows state: with a seeded session it offers New Session.
    func testSidebarButtonOffersNewSessionWhenASessionExists() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let button = app.buttons["new-session"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.label.contains("New Session"), "got: \(button.label)")
    }
```

- [ ] **Step 4: Run both gates**

Run: `./scripts/test-unit.sh 2>&1 | tail -4`
Then: `./scripts/smoke.sh 2>&1 | rg -i 'Test Case.*(passed|failed)|SMOKE' | tail -8`
Expected: unit PASS; all 6 UITests pass, `SMOKE PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionSidebar.swift Sources/FlightDeck/RootView.swift UITests/FlightDeckUITests/TerminalSmokeTests.swift
git commit -m "feat: sidebar button follows session state and shows its shortcut"
```

---

### Task 7: Folder drop

**Files:**
- Modify: `Sources/FlightDeck/SessionSidebar.swift`
- Test: `Tests/FlightDeckTests/SessionCreationTests.swift`

**Interfaces:**
- Consumes: `SessionCreateAction.projectDirectory(for:)`, `SessionStore.addProject(at:)`.
- Produces: `SessionStore.acceptDroppedURLs(_ urls: [URL]) -> Session?` — returns the last session created, which is also the one selected.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/SessionCreationTests.swift`:

```swift
    func testDroppingTwoFoldersCreatesAProjectEachAndActivatesTheLast() {
        let store = makeStore()
        let created = store.acceptDroppedURLs([
            URL(fileURLWithPath: "/work/foo", isDirectory: true),
            URL(fileURLWithPath: "/work/bar", isDirectory: true),
        ])

        XCTAssertEqual(store.repos.map(\.displayName), ["foo", "bar"])
        XCTAssertEqual(store.repos.flatMap(\.sessions).count, 2)
        XCTAssertEqual(store.selectedSessionID, created?.id)
        XCTAssertEqual(store.repos[1].sessions.last?.id, created?.id)
    }

    /// Dropping a folder that is already a project adds another session to it.
    func testDroppingAKnownFolderAddsASessionToThatProject() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/work/foo", isDirectory: true)
        _ = store.newSession(in: url)
        let created = store.acceptDroppedURLs([url])

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 2)
        XCTAssertEqual(store.selectedSessionID, created?.id)
    }

    func testDroppingNothingCreatesNothing() {
        let store = makeStore()
        XCTAssertNil(store.acceptDroppedURLs([]))
        XCTAssertTrue(store.repos.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -6`
Expected: FAIL — no `acceptDroppedURLs` member.

- [ ] **Step 3: Add the store method**

```swift
    /// Folder drop. Each URL becomes a project with one session; the last is activated.
    /// A file resolves to its containing folder, so dropping a file out of a repo adds
    /// that repo — see `SessionCreateAction.projectDirectory(for:)`.
    @discardableResult
    func acceptDroppedURLs(_ urls: [URL]) -> Session? {
        var last: Session?
        for url in urls {
            last = addProject(at: SessionCreateAction.projectDirectory(for: url))
        }
        return last
    }
```

- [ ] **Step 4: Wire the drop target**

Add to the `List` in `SessionSidebar`, directly after the closing brace of the `List` body and before `.safeAreaInset`:

```swift
        .dropDestination(for: URL.self) { urls, _ in
            store.acceptDroppedURLs(urls) != nil
        }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -6`
Expected: PASS.

- [ ] **Step 6: Verify the drop by hand**

XCUITest cannot drive a real drag session, so this is a manual check:

Run: `./scripts/build.sh 2>&1 | tail -2 && open DerivedData/Build/Products/Debug/FlightDeck.app`
Drag a folder from Finder onto the sidebar. Expected: it appears as a new project with one session, and that session becomes active. Drag the same folder again: a second session appears under it. Drag a *file* from inside a project: its parent folder is added. Quit when done.

- [ ] **Step 7: Run the smoke gate and commit**

Run: `./scripts/smoke.sh 2>&1 | rg -i 'Test Case.*(passed|failed)|SMOKE' | tail -8`
Expected: all 6 UITests pass, `SMOKE PASS`.

```bash
git add Sources/FlightDeck/SessionSidebar.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionCreationTests.swift
git commit -m "feat: add projects by dropping folders on the sidebar"
```

---

## Self-Review

**Spec coverage.** §2 single window → Task 1; store ownership move → Task 2; `hasRestoredInProcess` deletion → Task 1. §3 two creation paths → Task 3. §4 ⌘N reroute → Task 4 (rule) + Task 5 (wiring). §5 sidebar button → Task 6. §6 folder drop → Tasks 4 (resolver) + 7 (wiring). §7 testing → per task; the "activated in every creating path" requirement is asserted in Tasks 3, 5, and 7. §8 risks → Task 1 isolates the scene swap and runs the smoke gate before anything builds on it.

**Known gaps, stated deliberately.**
- Drag-and-drop's SwiftUI modifier wiring is verified by hand (Task 7 Step 6), not by XCUITest, which cannot drive a real drag session. The store path and the URL resolver are both unit-tested.
- The empty-state sidebar button label ("Add Project") has no UITest, because every UITest starts from a seeded session; only the non-empty label is asserted. Reaching the empty state under test would mean closing the seeded session first, which `testClosingSeededSessionKeepsAppAlive` already covers separately.

**Type consistency.** `newSession(in:at:)` gains a defaulted parameter, so Tasks 5 and 7 calling `newSession(in:)` still compile. `addProject(at:)` is the name used in Tasks 3, 5, and 7. `createFromMenu(chooseFolder:)` and `addProjectFromMenu(chooseFolder:)` both take an injectable picker and are used by Tasks 5 and 6. `SessionCreateAction.forState(hasSessions:)` and `.projectDirectory(for:)` are defined in Task 4 and consumed in Tasks 5, 6, and 7.
