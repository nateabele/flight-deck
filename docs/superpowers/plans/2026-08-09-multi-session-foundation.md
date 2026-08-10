# Multi-Session Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the walking skeleton (one hard-wired terminal) to multiple repo-grouped terminal sessions created/switched/closed from a sidebar, and fold in the teardown-lifetime (UAF) fix by making the libghostty app a process-wide singleton that outlives every surface.

**Architecture:** An `AppDelegate` owns one `GhosttyApp` (the libghostty app handle) for the whole process. A `@MainActor` `SessionStore` (`ObservableObject`) is the single source of truth: ordered `Repo`s each holding ordered `Session`s, a global selection, and per-session retained `Ghostty.SurfaceView`s. A `SessionSidebar` and a `TerminalPane` only render the Store; the pane re-parents the Store-retained surface on selection change (so switching never kills a shell), and only close frees a surface. The Store makes surfaces through an injected `SurfaceProvider` so its logic is unit-testable without a real terminal.

**Tech Stack:** Swift 5, SwiftUI + AppKit, `GhosttyKit.xcframework` (libghostty), XcodeGen, XCTest (unit + UI).

## Global Constraints

- Minimum macOS deployment target: **14.0** (`ContentUnavailableView`, `NavigationSplitView`, `@NSApplicationDelegateAdaptor` all available). Copied from `project.yml`.
- Swift language version: **5.0** (`SWIFT_VERSION`), so no strict-concurrency errors — but keep all libghostty calls and Store mutations on the main actor by discipline.
- Link **`GhosttyKit.xcframework`**; `ghostty_init` runs exactly once per process (already guarded by `GhosttyApp.didInit`).
- **Store is the single source of truth.** The sidebar and pane render only. No component other than `SessionStore` creates or frees surfaces.
- New Swift files under `Sources/FlightDeck/`, `Tests/FlightDeckTests/`, `UITests/FlightDeckUITests/` are picked up automatically by `xcodegen generate` (folder-based `sources:` in `project.yml`) — **no `project.yml` edits needed** for new files.
- Build: `./scripts/build.sh`. Unit tests: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' -derivedDataPath DerivedData test -only-testing:FlightDeckTests`. UI/smoke: `./scripts/smoke.sh`.
- TDD, DRY, YAGNI, frequent commits.

---

### Task 1: Session & Repo model

**Files:**
- Create: `Sources/FlightDeck/SessionModel.swift`
- Test: `Tests/FlightDeckTests/SessionModelTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `struct Session: Identifiable, Equatable` with `let id: UUID`, `var title: String`, `let workingDirectory: String`, and `init(id: UUID = UUID(), title: String, workingDirectory: String)`.
  - `struct Repo: Identifiable, Equatable` with `let id: UUID`, `let url: URL`, `var displayName: String`, `var sessions: [Session]`, and `init(id: UUID = UUID(), url: URL, sessions: [Session] = [])` that sets `displayName = url.lastPathComponent`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/SessionModelTests.swift
import XCTest
@testable import FlightDeck

final class SessionModelTests: XCTestCase {
    func testRepoDisplayNameIsLastPathComponent() {
        let repo = Repo(url: URL(fileURLWithPath: "/Users/nate/code/flight-deck", isDirectory: true))
        XCTAssertEqual(repo.displayName, "flight-deck")
        XCTAssertTrue(repo.sessions.isEmpty)
    }

    func testSessionCarriesTitleAndWorkingDirectory() {
        let session = Session(title: "session 1", workingDirectory: "/tmp")
        XCTAssertEqual(session.title, "session 1")
        XCTAssertEqual(session.workingDirectory, "/tmp")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' -derivedDataPath DerivedData test -only-testing:FlightDeckTests`
Expected: FAIL — `cannot find 'Repo' in scope` / `cannot find 'Session' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/FlightDeck/SessionModel.swift
import Foundation

/// A single terminal session. In this foundation a session is just a titled
/// terminal rooted at a working directory; agent/worktree state comes later.
struct Session: Identifiable, Equatable {
    let id: UUID
    var title: String
    let workingDirectory: String

    init(id: UUID = UUID(), title: String, workingDirectory: String) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
    }
}

/// A working-directory root that groups sessions. `displayName` is the folder's
/// last path component.
struct Repo: Identifiable, Equatable {
    let id: UUID
    let url: URL
    var displayName: String
    var sessions: [Session]

    init(id: UUID = UUID(), url: URL, sessions: [Session] = []) {
        self.id = id
        self.url = url
        self.displayName = url.lastPathComponent
        self.sessions = sessions
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' -derivedDataPath DerivedData test -only-testing:FlightDeckTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionModel.swift Tests/FlightDeckTests/SessionModelTests.swift
git commit -m "feat: add Session and Repo model structs"
```

---

### Task 2: SurfaceProvider abstraction

Decouples the Store from a real libghostty app so Store logic can be tested with a stub, and gives the Store one seam through which surfaces are made and the event loop is ticked. Also adds a testable liveness accessor to `GhosttyApp` for the later UAF regression test.

**Files:**
- Create: `Sources/FlightDeck/SurfaceProvider.swift`
- Modify: `Sources/FlightDeck/GhosttyEmbed/GhosttyApp.swift` (add `hasValidApp`)
- Test: `Tests/FlightDeckTests/SurfaceProviderTests.swift`

**Interfaces:**
- Consumes: `GhosttyApp` (`makeSurfaceView(baseConfig:) -> Ghostty.SurfaceView`, `tick()`, `app: ghostty_app_t!`), `Ghostty.SurfaceConfiguration`, `Ghostty.SurfaceView`.
- Produces:
  - `protocol SurfaceProvider: AnyObject { func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView?; func tick() }`
  - `extension GhosttyApp: SurfaceProvider` — `makeSurface` forwards to `makeSurfaceView(baseConfig:)`.
  - `GhosttyApp.hasValidApp: Bool` — `true` while the underlying `ghostty_app_t` is non-nil.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/SurfaceProviderTests.swift
import XCTest
@testable import FlightDeck

final class SurfaceProviderTests: XCTestCase {
    func testGhosttyAppConformsToSurfaceProvider() throws {
        guard let app = GhosttyApp() else {
            throw XCTSkip("GhosttyApp could not initialize in this environment")
        }
        // Conformance is the assertion: this must compile and hold at runtime.
        let provider: SurfaceProvider = app
        XCTAssertTrue(provider is GhosttyApp)
        XCTAssertTrue(app.hasValidApp)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' -derivedDataPath DerivedData test -only-testing:FlightDeckTests`
Expected: FAIL — `cannot find type 'SurfaceProvider'` and `value of type 'GhosttyApp' has no member 'hasValidApp'`.

- [ ] **Step 3: Write minimal implementation**

Create the protocol + conformance:

```swift
// Sources/FlightDeck/SurfaceProvider.swift
import Foundation

/// The one seam through which the Store creates terminal surfaces and drives
/// libghostty's event loop. Real terminals come from `GhosttyApp`; tests inject
/// a stub so Store logic can be exercised without a live terminal.
protocol SurfaceProvider: AnyObject {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView?
    func tick()
}

extension GhosttyApp: SurfaceProvider {
    func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
        makeSurfaceView(baseConfig: config)
    }
}
```

Add the liveness accessor to `GhosttyApp` (place it right after the `app` property declaration, near line 23):

```swift
    /// True while the underlying libghostty app handle is valid. Used by the
    /// surface-lifetime regression test to prove the app outlives surface frees.
    var hasValidApp: Bool { app != nil }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' -derivedDataPath DerivedData test -only-testing:FlightDeckTests`
Expected: PASS (or SKIP if `GhosttyApp()` can't init headlessly — acceptable; the compile is the real check).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SurfaceProvider.swift Sources/FlightDeck/GhosttyEmbed/GhosttyApp.swift Tests/FlightDeckTests/SurfaceProviderTests.swift
git commit -m "feat: add SurfaceProvider seam and GhosttyApp liveness accessor"
```

---

### Task 3: SessionStore

The single source of truth: repos, sessions, selection, and per-session surface retention. All logic is tested with a stub `SurfaceProvider` (no real terminal).

**Files:**
- Create: `Sources/FlightDeck/SessionStore.swift`
- Test: `Tests/FlightDeckTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `Session`, `Repo` (Task 1); `SurfaceProvider`, `Ghostty.SurfaceConfiguration`, `Ghostty.SurfaceView` (Task 2); `ShellResolver.resolve()`.
- Produces `@MainActor final class SessionStore: ObservableObject`:
  - `@Published private(set) var repos: [Repo]`
  - `@Published var selectedSessionID: UUID?`
  - `init(provider: SurfaceProvider?)` (designated; does **not** seed)
  - `convenience init(ghostty: GhosttyApp?)` (builds provider, then seeds one `$HOME` session)
  - `func seedInitialSession(homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))` — creates one repo+session only if `repos` is empty
  - `@discardableResult func newSession(in url: URL) -> Session` — dedupes repo by standardized path, appends a `"session N"` session, makes+retains its surface, ticks, selects it
  - `func selectSession(_ id: UUID)`
  - `func closeSession(_ id: UUID)` — removes the session, drops its surface, removes the repo if now empty, reselects the first available session (or nil)
  - `func surface(for id: UUID) -> Ghostty.SurfaceView?`
  - `func tick()`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/SessionStoreTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionStoreTests: XCTestCase {
    /// Stub provider: records calls, returns no real surface (nil retained).
    final class StubProvider: SurfaceProvider {
        var madeCount = 0
        var tickCount = 0
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            madeCount += 1
            return nil
        }
        func tick() { tickCount += 1 }
    }

    func testNewSessionCreatesRepoAndSelects() {
        let store = SessionStore(provider: StubProvider())
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].displayName, "foo")
        XCTAssertEqual(store.repos[0].sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, session.id)
    }

    func testDedupesReposByStandardizedPath() {
        let store = SessionStore(provider: StubProvider())
        store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/work/foo/", isDirectory: true))
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 2)
    }

    func testTitlesIncrement() {
        let store = SessionStore(provider: StubProvider())
        let a = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let b = store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))
        XCTAssertEqual(a.title, "session 1")
        XCTAssertEqual(b.title, "session 2")
    }

    func testCloseRemovesSessionAndEmptyRepo() {
        let store = SessionStore(provider: StubProvider())
        let s = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.closeSession(s.id)
        XCTAssertTrue(store.repos.isEmpty)
        XCTAssertNil(store.selectedSessionID)
    }

    func testCloseReselectsRemainingSession() {
        let store = SessionStore(provider: StubProvider())
        let s1 = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        let s2 = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.selectSession(s1.id)
        store.closeSession(s1.id)
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].sessions.count, 1)
        XCTAssertEqual(store.selectedSessionID, s2.id)
    }

    func testSeedInitialSessionCreatesOneHomeRepoOnce() {
        let store = SessionStore(provider: StubProvider())
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        store.seedInitialSession(homeURL: home)
        store.seedInitialSession(homeURL: home) // second call must be a no-op
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos[0].displayName, "tester")
        XCTAssertEqual(store.repos[0].sessions.count, 1)
        XCTAssertNotNil(store.selectedSessionID)
    }

    func testProviderInvokedPerSession() {
        let stub = StubProvider()
        let store = SessionStore(provider: stub)
        store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.newSession(in: URL(fileURLWithPath: "/work/bar", isDirectory: true))
        XCTAssertEqual(stub.madeCount, 2)
        XCTAssertEqual(stub.tickCount, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' -derivedDataPath DerivedData test -only-testing:FlightDeckTests`
Expected: FAIL — `cannot find 'SessionStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/FlightDeck/SessionStore.swift
import Foundation
import SwiftUI

/// Single source of truth for repos, sessions, selection, and live surfaces.
/// The sidebar and terminal pane render this and nothing else; only this type
/// creates or frees surfaces.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var repos: [Repo] = []
    @Published var selectedSessionID: UUID?

    /// Weak: the process-wide `GhosttyApp` is owned by the AppDelegate for the
    /// whole process; the Store must not co-own its lifetime.
    private weak var provider: SurfaceProvider?

    /// Live surfaces retained here (not by the SwiftUI view tree) so switching
    /// sessions re-parents rather than recreates. Dropping an entry frees it.
    private var surfaces: [UUID: Ghostty.SurfaceView] = [:]

    private var sessionCounter = 0

    init(provider: SurfaceProvider?) {
        self.provider = provider
    }

    /// Production entry point: build from the app singleton and seed one session.
    convenience init(ghostty: GhosttyApp?) {
        self.init(provider: ghostty)
        seedInitialSession()
    }

    func seedInitialSession(
        homeURL: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        guard repos.isEmpty else { return }
        newSession(in: homeURL)
    }

    @discardableResult
    func newSession(in url: URL) -> Session {
        let repoIndex: Int
        if let existing = indexOfRepo(for: url) {
            repoIndex = existing
        } else {
            repos.append(Repo(url: url))
            repoIndex = repos.count - 1
        }

        sessionCounter += 1
        let session = Session(title: "session \(sessionCounter)", workingDirectory: url.path)
        repos[repoIndex].sessions.append(session)

        var config = Ghostty.SurfaceConfiguration()
        config.command = ShellResolver.resolve()
        config.workingDirectory = url.path
        if let surface = provider?.makeSurface(config) {
            surfaces[session.id] = surface
        }
        provider?.tick()

        selectedSessionID = session.id
        return session
    }

    func selectSession(_ id: UUID) {
        guard locate(id) != nil else { return }
        selectedSessionID = id
    }

    func closeSession(_ id: UUID) {
        guard let (repoIndex, sessionIndex) = locate(id) else { return }
        repos[repoIndex].sessions.remove(at: sessionIndex)
        // Dropping the retained view triggers Ghostty.Surface.deinit, which
        // defers ghostty_surface_free to a main-actor task. The singleton app
        // outlives that free, so there is no use-after-free.
        surfaces[id] = nil
        if repos[repoIndex].sessions.isEmpty {
            repos.remove(at: repoIndex)
        }
        if selectedSessionID == id {
            selectedSessionID = repos.first?.sessions.first?.id
        }
    }

    func surface(for id: UUID) -> Ghostty.SurfaceView? { surfaces[id] }

    func tick() { provider?.tick() }

    // MARK: - Helpers

    private func indexOfRepo(for url: URL) -> Int? {
        let target = url.standardizedFileURL.path
        return repos.firstIndex { $0.url.standardizedFileURL.path == target }
    }

    private func locate(_ id: UUID) -> (repo: Int, session: Int)? {
        for (r, repo) in repos.enumerated() {
            if let s = repo.sessions.firstIndex(where: { $0.id == id }) {
                return (r, s)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' -derivedDataPath DerivedData test -only-testing:FlightDeckTests`
Expected: PASS (all 7 SessionStore tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionStoreTests.swift
git commit -m "feat: add SessionStore as single source of truth"
```

---

### Task 4: Lifetime fix + store-driven single terminal

Introduce the process-wide singleton `GhosttyApp` owned by an `AppDelegate` (the UAF fix), and route the window through the Store + a re-parenting `TerminalPane`. At the end of this task the app launches into one live terminal exactly as before — but now via the singleton and the Store — and `TerminalContainer` is retired.

**Files:**
- Create: `Sources/FlightDeck/AppDelegate.swift`
- Create: `Sources/FlightDeck/TerminalPane.swift`
- Create: `Sources/FlightDeck/RootView.swift`
- Modify: `Sources/FlightDeck/FlightDeckApp.swift`
- Modify: `Sources/FlightDeck/RootWindow.swift`
- Delete: `Sources/FlightDeck/TerminalContainer.swift`
- Verify: `UITests/FlightDeckUITests/TerminalSmokeTests.swift` (unchanged; must still pass)

**Interfaces:**
- Consumes: `GhosttyApp` (Task 2), `SessionStore` (Task 3), `Ghostty.SurfaceView`, `Ghostty.moveFocus(to:)`.
- Produces:
  - `final class AppDelegate: NSObject, NSApplicationDelegate` with `let ghostty: GhosttyApp?` and `applicationShouldTerminateAfterLastWindowClosed -> true`.
  - `struct RootView: View` with `init(ghostty: GhosttyApp?)` that owns `@StateObject var store: SessionStore`.
  - `struct TerminalPane: NSViewRepresentable` that hosts the Store's selected surface and re-parents on update.
  - `RootWindow(ghostty: GhosttyApp?)`.

- [ ] **Step 1: Create the AppDelegate (the singleton owner)**

```swift
// Sources/FlightDeck/AppDelegate.swift
import AppKit

/// Owns the one libghostty app for the whole process. Because the delegate
/// outlives every window and surface, the deferred ghostty_surface_free in
/// Ghostty.Surface.deinit can never race a freed app — this is the fix for the
/// documented teardown-lifetime hazard.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let ghostty: GhosttyApp? = GhosttyApp()

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
```

- [ ] **Step 2: Create the re-parenting TerminalPane**

```swift
// Sources/FlightDeck/TerminalPane.swift
import SwiftUI

/// Hosts the Store's currently-selected surface. The surface is retained by the
/// Store, not by this view, so selection changes re-parent the same live NSView
/// (the shell keeps running) instead of recreating it.
struct TerminalPane: NSViewRepresentable {
    @ObservedObject var store: SessionStore

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.autoresizingMask = [.width, .height]
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
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
        store.tick()
    }
}
```

- [ ] **Step 3: Create RootView (owns the Store, shows the pane)**

```swift
// Sources/FlightDeck/RootView.swift
import SwiftUI

/// Root of the window. Owns the SessionStore for the window's lifetime and,
/// for now, renders just the selected terminal. The sidebar is added in the
/// next task.
struct RootView: View {
    @StateObject private var store: SessionStore

    init(ghostty: GhosttyApp?) {
        // StateObject's autoclosure runs exactly once, so the seed happens once.
        _store = StateObject(wrappedValue: SessionStore(ghostty: ghostty))
    }

    var body: some View {
        TerminalPane(store: store)
            .frame(minWidth: 400, minHeight: 300)
    }
}
```

- [ ] **Step 4: Point the app entry and window at the singleton + RootView**

```swift
// Sources/FlightDeck/FlightDeckApp.swift
import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        RootWindow(ghostty: appDelegate.ghostty)
    }
}
```

```swift
// Sources/FlightDeck/RootWindow.swift
import SwiftUI

struct RootWindow: Scene {
    let ghostty: GhosttyApp?

    var body: some Scene {
        WindowGroup {
            RootView(ghostty: ghostty)
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
```

- [ ] **Step 5: Retire the old per-view owner**

```bash
git rm Sources/FlightDeck/TerminalContainer.swift
```

- [ ] **Step 6: Build, then run the smoke test to verify the app still launches into a live terminal**

Run: `./scripts/build.sh`
Expected: build succeeds.

Run: `./scripts/smoke.sh`
Expected: `SMOKE PASS` — the window exists and is non-empty (the seeded session's surface fills it), proving the singleton + Store path renders a live terminal.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: own libghostty app in AppDelegate singleton; drive terminal via Store

Retires per-view GhosttyApp ownership (the UAF hazard). The libghostty app is
now a process-wide singleton owned by AppDelegate, outliving every surface, and
the window renders the Store's selected surface via a re-parenting TerminalPane."
```

---

### Task 5: Sidebar + multi-session UI

Add the repo→session sidebar with create (folder picker), switch, and close, plus an empty state. This turns the single-terminal window into the multi-session container.

**Files:**
- Create: `Sources/FlightDeck/FolderPicker.swift`
- Create: `Sources/FlightDeck/SessionSidebar.swift`
- Modify: `Sources/FlightDeck/RootView.swift`

**Interfaces:**
- Consumes: `SessionStore` (Task 3), `TerminalPane` (Task 4).
- Produces:
  - `enum FolderPicker { static func choose() -> URL? }` — folder-only `NSOpenPanel`.
  - `struct SessionSidebar: View` — `List(selection: $store.selectedSessionID)` of repos→sessions with a per-row close button (`accessibilityIdentifier("close-session")`) and a bottom "New Session" button (`accessibilityIdentifier("new-session")`).
  - `RootView` renders a `NavigationSplitView { SessionSidebar } detail: { TerminalPane or empty state }`.

- [ ] **Step 1: Add the folder picker helper**

```swift
// Sources/FlightDeck/FolderPicker.swift
import AppKit

/// Modal folder chooser used to define a repo when creating a session.
enum FolderPicker {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
```

- [ ] **Step 2: Add the sidebar**

```swift
// Sources/FlightDeck/SessionSidebar.swift
import SwiftUI

/// Renders the repo→session tree and issues create/switch/close intents to the
/// Store. Rendering only: it holds no session state of its own.
struct SessionSidebar: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        List(selection: $store.selectedSessionID) {
            ForEach(store.repos) { repo in
                Section(repo.displayName) {
                    ForEach(repo.sessions) { session in
                        HStack {
                            Text(session.title)
                            Spacer()
                            Button {
                                store.closeSession(session.id)
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("close-session")
                        }
                        .tag(session.id)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                if let url = FolderPicker.choose() {
                    store.newSession(in: url)
                }
            } label: {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("new-session")
            .padding(8)
        }
    }
}
```

- [ ] **Step 3: Compose sidebar + pane in RootView**

Replace the body of `RootView` (keep its `init` unchanged):

```swift
    var body: some View {
        NavigationSplitView {
            SessionSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if store.selectedSessionID.flatMap({ store.surface(for: $0) }) != nil {
                TerminalPane(store: store)
                    .frame(minWidth: 400, minHeight: 300)
            } else {
                ContentUnavailableView {
                    Label("No Session", systemImage: "terminal")
                } description: {
                    Text("Create a session to get started.")
                } actions: {
                    Button("New Session") {
                        if let url = FolderPicker.choose() {
                            store.newSession(in: url)
                        }
                    }
                }
            }
        }
    }
```

- [ ] **Step 4: Build and smoke to verify the sidebar layout launches**

Run: `./scripts/build.sh`
Expected: build succeeds.

Run: `./scripts/smoke.sh`
Expected: `SMOKE PASS` — window still exists and is non-empty (seeded session shows in the sidebar and its terminal fills the detail pane).

- [ ] **Step 5: Manual verification (record result in the commit)**

Launch `DerivedData/Build/Products/Debug/FlightDeck.app`. Confirm by observation:
- The seeded home session appears under a repo named after your home folder, with a live shell.
- "New Session" opens a folder picker; choosing a folder adds a session under that folder's repo and switches to it with its own live shell.
- Clicking another session switches back and the **first shell is still running** (scrollback intact) — proof surfaces are retained and re-parented, not recreated.
- Closing a session with × removes it; closing the last session in a repo removes the repo; closing everything shows the "No Session" empty state.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FolderPicker.swift Sources/FlightDeck/SessionSidebar.swift Sources/FlightDeck/RootView.swift
git commit -m "feat: add repo-grouped session sidebar with create/switch/close"
```

---

### Task 6: Surface-lifetime regression tests

Prove the UAF fix: surfaces can be created and freed repeatedly through the Store while the singleton app stays valid, and closing a session in the running app never crashes it.

**Files:**
- Create: `Tests/FlightDeckTests/SurfaceLifecycleTests.swift`
- Modify: `UITests/FlightDeckUITests/TerminalSmokeTests.swift`

**Interfaces:**
- Consumes: `AppDelegate` (Task 4), `GhosttyApp.hasValidApp` (Task 2), `SessionStore` (Task 3); the `close-session` accessibility id (Task 5).
- Produces: no new production symbols.

- [ ] **Step 1: Write the failing unit test (create→close cycles keep the app valid)**

```swift
// Tests/FlightDeckTests/SurfaceLifecycleTests.swift
import XCTest
import AppKit
@testable import FlightDeck

@MainActor
final class SurfaceLifecycleTests: XCTestCase {
    /// Let the detached main-actor ghostty_surface_free task run to completion.
    private func drainMainQueue() {
        let exp = expectation(description: "drain")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    func testCreateCloseCyclesKeepAppValid() throws {
        // Use the one process-wide app from the launched host app so we exercise
        // the real singleton and never create a second ghostty_app_t.
        guard let ghostty = (NSApp.delegate as? AppDelegate)?.ghostty else {
            throw XCTSkip("Host app GhosttyApp singleton unavailable")
        }
        XCTAssertTrue(ghostty.hasValidApp)

        let store = SessionStore(provider: ghostty)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        for _ in 0..<3 {
            let session = store.newSession(in: dir)
            XCTAssertNotNil(store.surface(for: session.id))
            store.closeSession(session.id)   // drops the surface → deferred free
            drainMainQueue()                 // let the free actually run
            XCTAssertTrue(ghostty.hasValidApp) // app survived freeing a surface
        }
        XCTAssertTrue(ghostty.hasValidApp)
    }
}
```

- [ ] **Step 2: Run the unit test to verify it passes (fix is in place)**

Run: `export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer && xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' -derivedDataPath DerivedData test -only-testing:FlightDeckTests`
Expected: PASS (or SKIP if the host app's delegate isn't reachable in this environment). It must **not** crash — a crash here is the UAF regressing.

Sanity check that the test is meaningful: temporarily change `AppDelegate.ghostty` to a per-call `GhosttyApp()` created and released inside a session's lifetime (simulating the old per-view ownership) and confirm this test crashes/fails; then revert. (Optional; do not commit the temporary change.)

- [ ] **Step 3: Extend the UI smoke test (closing a session doesn't crash the app)**

Add this method to `TerminalSmokeTests`:

```swift
    func testClosingSeededSessionKeepsAppAlive() {
        let app = XCUIApplication()
        app.launch()
        app.activate()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))

        // Close the seeded session; this frees its surface while the app lives —
        // the exact use-after-free path the singleton fix protects.
        let close = app.buttons["close-session"].firstMatch
        if close.waitForExistence(timeout: 5) {
            close.click()
        }

        // The app must survive: still running, window still present.
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(window.exists)
    }
```

- [ ] **Step 4: Run the full smoke/UI suite**

Run: `./scripts/smoke.sh`
Expected: `SMOKE PASS` — both `testAppLaunchesAndShowsTerminalSurface` and `testClosingSeededSessionKeepsAppAlive` pass.

- [ ] **Step 5: Commit**

```bash
git add Tests/FlightDeckTests/SurfaceLifecycleTests.swift UITests/FlightDeckUITests/TerminalSmokeTests.swift
git commit -m "test: guard surface-lifetime fix with create/close regression tests"
```

---

## Notes for the implementer

- **Re-parenting & rendering.** `Ghostty.SurfaceView` (in `GhosttyEmbed/SurfaceView_AppKit.swift`) starts/stops its Metal display link on `viewDidMoveToWindow`, so removing it from one container and adding it to another is expected to resume rendering. If a re-parented surface shows a blank frame, calling `store.tick()` (already done in `TerminalPane.updateNSView`) after attach should push a frame; do not recreate the surface.
- **Surface creation timing.** `SessionStore(ghostty:)` seeds a session at `RootView` init, which creates a real surface before it is attached to a window. This mirrors what the old `TerminalContainer` did (create, then attach, then tick) and is supported by libghostty; the pane attaches and ticks on first `updateNSView`.
- **Main actor.** `SessionStore` is `@MainActor`; its unit tests are `@MainActor`. All surface make/free happens on the main actor, matching the `Ghostty.Surface` contract.
- **No `project.yml` changes.** All new files live under folders already globbed by XcodeGen; `./scripts/build.sh` runs `xcodegen generate` first.
