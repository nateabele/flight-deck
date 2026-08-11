# Session Name Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a session's name in sync between the Flight Deck sidebar and the `claude` process running in that session's terminal, in both directions.

**Architecture:** Flight Deck assigns each session's `UUID` to `claude` at launch via `--session-id`, which makes the transcript path deterministic. Outbound renames inject `/rename <name>` into the pty; inbound renames are picked up by tailing the transcript for a `{"type":"custom-title"}` line. Loop suppression is a plain value comparison — no origin tags.

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest, XcodeGen (`project.yml`), embedded libghostty.

## Global Constraints

- Target module is `FlightDeck`; tests live in `Tests/FlightDeckTests/` and use `XCTest` with `@testable import FlightDeck`.
- Unit tests run with `./scripts/test-unit.sh`. Do not invoke `xcodebuild` directly.
- `SessionStore` is `@MainActor`. Anything it calls synchronously must be main-actor safe.
- Sessions persist across relaunch via `UserDefaults` in the app's standard domain
  (bundle id `dev.flightdeck.FlightDeck`). `scripts/smoke.sh:14` already wipes it.
- Do not read or write `~/.claude/projects/*/sessions-index.json`.
- Never launch a real `claude` process from a unit test.
- Transcript path root is `~/.claude/projects`; it must be injectable so tests use a temp dir.

---

### Task 1: `ClaudeSession` pure helpers

Path encoding, transcript-line parsing, and name sanitization. No I/O, no state — everything here is a pure function so the rules are testable without a filesystem or a terminal.

**Files:**
- Create: `Sources/FlightDeck/ClaudeSession.swift`
- Test: `Tests/FlightDeckTests/ClaudeSessionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ClaudeSession.encodedProjectDirName(for workingDirectory: String) -> String`
  - `ClaudeSession.transcriptURL(sessionID: UUID, workingDirectory: String, projectsRoot: URL) -> URL`
  - `ClaudeSession.defaultProjectsRoot: URL`
  - `ClaudeSession.customTitle(inLine: String, sessionID: UUID) -> String?`
  - `ClaudeSession.sanitizedName(_ raw: String) -> String?` (nil when unusable)
  - `ClaudeSession.launchCommand(sessionID: UUID, title: String) -> String` (fresh session)
  - `ClaudeSession.resumeCommand(sessionID: UUID, title: String) -> String` (restored session)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/ClaudeSessionTests.swift
import XCTest
@testable import FlightDeck

final class ClaudeSessionTests: XCTestCase {
    let sid = UUID(uuidString: "38f62687-0abb-4b2b-9cc7-35276b243bb2")!

    func testEncodesEveryNonAlphanumericAsDash() {
        XCTAssertEqual(
            ClaudeSession.encodedProjectDirName(for: "/Users/nate/Desktop/Scratch/gltf-viewer"),
            "-Users-nate-Desktop-Scratch-gltf-viewer"
        )
    }

    /// One-for-one, no collapsing: `/-` becomes `--`.
    func testDoesNotCollapseRuns() {
        XCTAssertEqual(
            ClaudeSession.encodedProjectDirName(for: "/private/tmp/x/-Users-nate"),
            "-private-tmp-x--Users-nate"
        )
    }

    func testTranscriptURLJoinsDirAndSessionID() {
        let root = URL(fileURLWithPath: "/root", isDirectory: true)
        let url = ClaudeSession.transcriptURL(
            sessionID: sid, workingDirectory: "/work/foo", projectsRoot: root
        )
        XCTAssertEqual(url.path, "/root/-work-foo/\(sid.uuidString.lowercased()).jsonl")
    }

    func testParsesCustomTitleLine() {
        let line = #"{"type":"custom-title","customTitle":"my name","sessionId":"\#(sid.uuidString.lowercased())"}"#
        XCTAssertEqual(ClaudeSession.customTitle(inLine: line, sessionID: sid), "my name")
    }

    func testIgnoresAgentNameLine() {
        let line = #"{"type":"agent-name","agentName":"x","sessionId":"\#(sid.uuidString.lowercased())"}"#
        XCTAssertNil(ClaudeSession.customTitle(inLine: line, sessionID: sid))
    }

    func testIgnoresMismatchedSessionID() {
        let line = #"{"type":"custom-title","customTitle":"x","sessionId":"00000000-0000-0000-0000-000000000000"}"#
        XCTAssertNil(ClaudeSession.customTitle(inLine: line, sessionID: sid))
    }

    func testIgnoresMalformedJSON() {
        XCTAssertNil(ClaudeSession.customTitle(inLine: "{not json", sessionID: sid))
        XCTAssertNil(ClaudeSession.customTitle(inLine: "", sessionID: sid))
    }

    func testSanitizerTrimsAndRejectsEmpty() {
        XCTAssertEqual(ClaudeSession.sanitizedName("  hi  "), "hi")
        XCTAssertNil(ClaudeSession.sanitizedName("   "))
        XCTAssertNil(ClaudeSession.sanitizedName(""))
    }

    func testSanitizerStripsControlCharacters() {
        XCTAssertEqual(ClaudeSession.sanitizedName("a\nb\tc\u{7}d"), "abcd")
    }

    func testSanitizerCapsLength() {
        XCTAssertEqual(ClaudeSession.sanitizedName(String(repeating: "x", count: 200))?.count, 120)
    }

    func testLaunchCommandSingleQuotesAndEscapes() {
        let cmd = ClaudeSession.launchCommand(sessionID: sid, title: "it's mine")
        XCTAssertEqual(
            cmd,
            "claude --session-id \(sid.uuidString.lowercased()) --name 'it'\\''s mine'\n"
        )
    }

    /// Restore falls back to a fresh session when the transcript is gone.
    /// Verified empirically: `claude --resume <unknown-uuid>` exits 1, so `||` fires.
    func testResumeCommandFallsBackToFreshSession() {
        let id = sid.uuidString.lowercased()
        XCTAssertEqual(
            ClaudeSession.resumeCommand(sessionID: sid, title: "my work"),
            "claude --resume \(id) || claude --session-id \(id) --name 'my work'\n"
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ClaudeSession' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/ClaudeSession.swift
import Foundation

/// Pure rules for locating and reading a Claude Code session transcript, and for
/// building the launch command. No I/O and no state so every rule is unit-testable.
///
/// The encoding rule and the `custom-title` record shape were verified empirically
/// against the installed `claude`; see
/// `docs/superpowers/specs/2026-08-10-session-name-sync-design.md` §2.
enum ClaudeSession {
    static let maxNameLength = 120

    static var defaultProjectsRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Claude replaces every UTF-16 code unit that is not an ASCII alphanumeric with `-`,
    /// one for one, without collapsing runs.
    ///
    /// Verified against real `claude` output: `café-Ω-probe` → `caf----probe`, and
    /// `emo🎈dir` → `emo--dir`. The emoji yielding TWO dashes is what pins this to UTF-16
    /// code units rather than scalars or Swift `Character`s. Note Swift's Unicode-aware
    /// `isLetter`/`isNumber` would wrongly *keep* `é` and `Ω`, producing a transcript path
    /// that does not exist — a failure that is silent rather than loud.
    static func encodedProjectDirName(for workingDirectory: String) -> String {
        String(workingDirectory.utf16.map { unit in
            let isASCIIAlphanumeric = (0x30...0x39).contains(unit)   // 0-9
                || (0x41...0x5A).contains(unit)                      // A-Z
                || (0x61...0x7A).contains(unit)                      // a-z
            return isASCIIAlphanumeric ? Character(UnicodeScalar(UInt8(unit))) : "-"
        })
    }

    static func transcriptURL(
        sessionID: UUID,
        workingDirectory: String,
        projectsRoot: URL = defaultProjectsRoot
    ) -> URL {
        projectsRoot
            .appendingPathComponent(encodedProjectDirName(for: workingDirectory), isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
    }

    /// Returns the title when `line` is this session's rename record, else nil.
    /// Shape: `{"type":"custom-title","customTitle":"…","sessionId":"…"}`.
    static func customTitle(inLine line: String, sessionID: UUID) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "custom-title",
              let sid = obj["sessionId"] as? String,
              sid.lowercased() == sessionID.uuidString.lowercased(),
              let title = obj["customTitle"] as? String
        else { return nil }
        return title
    }

    /// Trims, strips control characters, and caps length. Returns nil when nothing usable
    /// remains, which callers treat as "revert to the previous title".
    static func sanitizedName(_ raw: String) -> String? {
        let stripped = raw.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// POSIX single-quoting: wrap in `'…'` and rewrite embedded `'` as `'\''`.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The command the shell runs at session start, binding `claude` to our UUID and title.
    static func launchCommand(sessionID: UUID, title: String) -> String {
        let name = sanitizedName(title) ?? "session"
        return "claude --session-id \(sessionID.uuidString.lowercased()) "
            + "--name \(shellQuoted(name))\n"
    }

    /// The command for a session restored from a previous app launch. Reattaches to the
    /// existing conversation, falling back to a fresh session with the same id and name
    /// when the transcript has been deleted or pruned (`--resume` exits 1 in that case).
    static func resumeCommand(sessionID: UUID, title: String) -> String {
        let id = sessionID.uuidString.lowercased()
        let name = sanitizedName(title) ?? "session"
        return "claude --resume \(id) || claude --session-id \(id) --name \(shellQuoted(name))\n"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ClaudeSession.swift Tests/FlightDeckTests/ClaudeSessionTests.swift
git commit -m "feat: add ClaudeSession path/parse/sanitize helpers"
```

---

### Task 2: Rename intent and injection seam in `SessionStore`

Adds the outbound rename and the inbound apply, plus a `TextInjecting` seam so both are testable without a live terminal.

**Files:**
- Create: `Sources/FlightDeck/TextInjecting.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Test: `Tests/FlightDeckTests/SessionRenameTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.sanitizedName(_:)` from Task 1.
- Produces:
  - `protocol TextInjecting: AnyObject { @MainActor func sendText(_ text: String) }`
  - `SessionStore.rename(_ id: UUID, to newTitle: String)`
  - `SessionStore.applyExternalTitle(_ id: UUID, _ title: String)`
  - `SessionStore.injectorOverride: TextInjecting?` (test seam; nil in production)
  - `SessionStore.title(of id: UUID) -> String?`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SessionRenameTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionRenameTests: XCTestCase {
    final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
    }

    final class SpyInjector: TextInjecting {
        var sent: [String] = []
        func sendText(_ text: String) { sent.append(text) }
    }

    private func makeStore() -> (SessionStore, SpyInjector, UUID) {
        let store = SessionStore(provider: StubProvider())
        let spy = SpyInjector()
        store.injectorOverride = spy
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        spy.sent.removeAll()          // ignore anything emitted at creation
        return (store, spy, session.id)
    }

    func testRenameUpdatesTitle() {
        let (store, _, id) = makeStore()
        store.rename(id, to: "my session")
        XCTAssertEqual(store.title(of: id), "my session")
    }

    func testRenameInjectsExactlyOneRenameCommand() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "my session")
        XCTAssertEqual(spy.sent, ["/rename my session\n"])
    }

    func testRenameSanitizesBeforeInjecting() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "  bad\nname  ")
        XCTAssertEqual(store.title(of: id), "badname")
        XCTAssertEqual(spy.sent, ["/rename badname\n"])
    }

    func testEmptyRenameIsIgnored() {
        let (store, spy, id) = makeStore()
        let before = store.title(of: id)
        store.rename(id, to: "   ")
        XCTAssertEqual(store.title(of: id), before)
        XCTAssertTrue(spy.sent.isEmpty)
    }

    func testUnknownSessionIsIgnored() {
        let (store, spy, _) = makeStore()
        store.rename(UUID(), to: "x")
        XCTAssertTrue(spy.sent.isEmpty)
    }

    func testApplyExternalTitleUpdatesWithoutInjecting() {
        let (store, spy, id) = makeStore()
        store.applyExternalTitle(id, "from claude")
        XCTAssertEqual(store.title(of: id), "from claude")
        XCTAssertTrue(spy.sent.isEmpty, "inbound must never inject")
    }

    /// Loop suppression: the transcript line our own rename caused must not bounce back.
    func testApplyExternalTitleIsNoOpWhenUnchanged() {
        let (store, spy, id) = makeStore()
        store.rename(id, to: "same")
        spy.sent.removeAll()
        store.applyExternalTitle(id, "same")
        XCTAssertEqual(store.title(of: id), "same")
        XCTAssertTrue(spy.sent.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — `cannot find type 'TextInjecting'`, no `rename` member.

- [ ] **Step 3: Write the implementation**

Create the seam:

```swift
// Sources/FlightDeck/TextInjecting.swift
import Foundation

/// Anything that can type text into a live terminal. Mirrors the `SurfaceProvider`
/// seam so the Store stays testable without a real surface.
@MainActor
protocol TextInjecting: AnyObject {
    func sendText(_ text: String)
}

extension Ghostty.SurfaceView: TextInjecting {
    func sendText(_ text: String) {
        surfaceModel?.sendText(text)
    }
}
```

Add to `SessionStore` (place after `closeSession`, before `surface(for:)`):

```swift
    /// Test seam. Production leaves this nil and injection goes to the live surface.
    var injectorOverride: TextInjecting?

    func title(of id: UUID) -> String? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session].title
    }

    /// Sidebar → Claude. Updates the title, then types `/rename <name>` into the pty
    /// so the *running* interactive session renames itself and records it.
    func rename(_ id: UUID, to newTitle: String) {
        guard let at = locate(id),
              let name = ClaudeSession.sanitizedName(newTitle)
        else { return }

        repos[at.repo].sessions[at.session].title = name
        injector(for: id)?.sendText("/rename \(name)\n")
    }

    /// Claude → sidebar. Applied from the transcript watcher; never injects.
    /// The equality check is the loop guard: a `custom-title` line caused by our own
    /// `rename` matches the title we already set and stops here.
    func applyExternalTitle(_ id: UUID, _ title: String) {
        guard let at = locate(id),
              let name = ClaudeSession.sanitizedName(title),
              repos[at.repo].sessions[at.session].title != name
        else { return }

        repos[at.repo].sessions[at.session].title = name
    }

    private func injector(for id: UUID) -> TextInjecting? {
        injectorOverride ?? surfaces[id]
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS. Existing `SessionStoreTests` must still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/TextInjecting.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionRenameTests.swift
git commit -m "feat: add session rename intent and text-injection seam"
```

---

### Task 3: Launch `claude` bound to the session UUID

Makes the shell immediately exec `claude` with our UUID and title, which is what makes the transcript path knowable.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift:40-64` (`newSession(in:)`)
- Test: `Tests/FlightDeckTests/SessionLaunchTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.launchCommand(sessionID:title:)` from Task 1.
- Produces: `config.initialInput` populated on every created surface. No new API.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/SessionLaunchTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionLaunchTests: XCTestCase {
    final class CapturingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    func testLaunchesClaudeBoundToSessionUUID() {
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider)
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))

        let input = try? XCTUnwrap(provider.configs.first?.initialInput)
        XCTAssertEqual(
            input,
            "claude --session-id \(session.id.uuidString.lowercased()) --name '\(session.title)'\n"
        )
    }

    func testStillLaunchesTheShellAsTheCommand() {
        let provider = CapturingProvider()
        let store = SessionStore(provider: provider)
        store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(provider.configs.first?.command, ShellResolver.resolve())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — `initialInput` is nil.

- [ ] **Step 3: Write the implementation**

In `newSession(in:)`, directly after `config.workingDirectory = url.path`:

```swift
        // Bind `claude` to our own UUID so the transcript path is deterministic,
        // and seed it with the sidebar's title. See ClaudeSession.
        config.initialInput = ClaudeSession.launchCommand(
            sessionID: session.id, title: session.title
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, including Task 2's tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionLaunchTests.swift
git commit -m "feat: launch claude bound to the session UUID and title"
```

---

### Task 4: `TranscriptWatcher` — inbound sync

Tails one session's transcript and reports the newest `customTitle`. Watches the parent directory until the file exists, then the file itself.

**Files:**
- Create: `Sources/FlightDeck/TranscriptWatcher.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Test: `Tests/FlightDeckTests/TranscriptWatcherTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.customTitle(inLine:sessionID:)`, `ClaudeSession.transcriptURL(...)`, `SessionStore.applyExternalTitle(_:_:)`.
- Produces:
  - `TranscriptWatcher(sessionID:url:onTitle:)`
  - `TranscriptWatcher.start()`, `.stop()`, `.drain()` (`drain` is synchronous and used by tests)

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/TranscriptWatcherTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class TranscriptWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ title: String, _ sid: UUID) -> String {
        #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(sid.uuidString.lowercased())"}"# + "\n"
    }

    func testReportsTitleAppendedAfterStart() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()

        try (line("first", sid)).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, ["first"])
    }

    func testReportsOnlyTheLastTitleInABatch() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()

        try (line("a", sid) + line("b", sid)).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, ["b"])
    }

    func testIgnoresUnrelatedLines() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()

        let noise = #"{"type":"agent-name","agentName":"x","sessionId":"\#(sid.uuidString.lowercased())"}"# + "\n"
        try (noise + "{bad json\n").data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertTrue(seen.isEmpty)
    }

    func testHandlesFileCreatedAfterStart() throws {
        let sid = UUID()
        let url = dir.appendingPathComponent("later.jsonl")

        var seen: [String] = []
        let watcher = TranscriptWatcher(sessionID: sid, url: url) { seen.append($0) }
        watcher.start()   // file does not exist yet

        try (line("late", sid)).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, ["late"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — `cannot find 'TranscriptWatcher' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/TranscriptWatcher.swift
import Foundation

/// Tails one session's Claude transcript and reports the newest `customTitle`.
///
/// `claude` creates the transcript slightly after launch, so the watcher polls for the
/// file and only then starts reading. Reads are incremental: only bytes appended since
/// the last read are parsed. A missing file is not an error — it just means `claude`
/// isn't running, and the sidebar name stays a local label.
@MainActor
final class TranscriptWatcher {
    private let sessionID: UUID
    private let url: URL
    private let onTitle: (String) -> Void

    private var offset: UInt64 = 0
    private var timer: DispatchSourceTimer?

    init(sessionID: UUID, url: URL, onTitle: @escaping (String) -> Void) {
        self.sessionID = sessionID
        self.url = url
        self.onTitle = onTitle
    }

    deinit { timer?.cancel() }

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.drain() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Reads everything appended since the last call and reports the last title found.
    /// Synchronous so tests need no expectations.
    func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        // A shorter file means it was replaced; start over.
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        guard size > offset else { return }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        offset = size

        let titles = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { ClaudeSession.customTitle(inLine: String($0), sessionID: sessionID) }

        if let last = titles.last { onTitle(last) }
    }
}
```

Wire it into `SessionStore`. Add the storage next to `surfaces`:

```swift
    /// One transcript watcher per session, torn down with the session.
    private var watchers: [UUID: TranscriptWatcher] = [:]

    /// Injectable so tests can point at a temp directory.
    var projectsRoot: URL = ClaudeSession.defaultProjectsRoot
```

Add a private helper (Task 5 reuses it from the restore path, so it must be a method,
not inline code):

```swift
    private func startWatching(_ session: Session, workingDirectory: String) {
        let watcher = TranscriptWatcher(
            sessionID: session.id,
            url: ClaudeSession.transcriptURL(
                sessionID: session.id,
                workingDirectory: workingDirectory,
                projectsRoot: projectsRoot
            )
        ) { [weak self] title in
            self?.applyExternalTitle(session.id, title)
        }
        watcher.start()
        watchers[session.id] = watcher
    }
```

Call it from `newSession(in:)` immediately before `selectedSessionID = session.id`:

```swift
        startWatching(session, workingDirectory: url.path)
```

In `closeSession(_:)`, alongside the existing `surfaces` removal:

```swift
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, including all earlier tasks.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/TranscriptWatcher.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/TranscriptWatcherTests.swift
git commit -m "feat: watch claude transcripts for external renames"
```

---

### Task 5: Persistence and restore

Sessions survive relaunch: every row comes back, each reattached to its own Claude
conversation via `--resume`. This is the reason Task 1 built `resumeCommand`.

**Files:**
- Create: `Sources/FlightDeck/SessionPersistence.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (pass persistence into the Store)
- Test: `Tests/FlightDeckTests/SessionPersistenceTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.resumeCommand(sessionID:title:)` and
  `ClaudeSession.launchCommand(sessionID:title:)` from Task 1.
- Produces:
  - `struct SessionSnapshot: Codable, Equatable` with `sessions: [Entry]`,
    `selectedSessionID: UUID?`, `sessionCounter: Int`
  - `SessionSnapshot.Entry` — `{ id: UUID, title: String, workingDirectory: String }`
  - `protocol SessionPersisting: AnyObject { func load() -> SessionSnapshot?; func save(_:) }`
  - `final class UserDefaultsSessionPersistence: SessionPersisting`
  - `SessionStore.init(provider:persistence:)`
  - `SessionStore.restore(directoryExists:) -> Bool`

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SessionPersistenceTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionPersistenceTests: XCTestCase {
    final class CapturingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    /// In-memory stand-in for UserDefaults.
    final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        var saveCount = 0
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot; saveCount += 1 }
    }

    private let allDirsExist: (String) -> Bool = { _ in true }

    func testSnapshotRoundTripsThroughUserDefaults() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = UserDefaultsSessionPersistence(defaults: defaults)
        XCTAssertNil(store.load())

        let snap = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "a", workingDirectory: "/w")],
            selectedSessionID: nil,
            sessionCounter: 3
        )
        store.save(snap)
        XCTAssertEqual(store.load(), snap)
    }

    func testCreatingASessionPersistsIt() {
        let fake = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))

        XCTAssertEqual(fake.stored?.sessions.map(\.id), [session.id])
        XCTAssertEqual(fake.stored?.selectedSessionID, session.id)
    }

    func testRenamePersistsTheNewTitle() {
        let fake = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.rename(session.id, to: "renamed")
        XCTAssertEqual(fake.stored?.sessions.first?.title, "renamed")
    }

    func testClosePersistsRemoval() {
        let fake = FakePersistence()
        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        let session = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        store.closeSession(session.id)
        XCTAssertEqual(fake.stored?.sessions.count, 0)
    }

    func testRestoreRebuildsReposGroupedAndOrdered() {
        let fake = FakePersistence()
        let a = UUID(), b = UUID(), c = UUID()
        fake.stored = SessionSnapshot(
            sessions: [
                .init(id: a, title: "one", workingDirectory: "/work/foo"),
                .init(id: b, title: "two", workingDirectory: "/work/bar"),
                .init(id: c, title: "three", workingDirectory: "/work/foo"),
            ],
            selectedSessionID: b,
            sessionCounter: 3
        )

        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))

        XCTAssertEqual(store.repos.map(\.displayName), ["foo", "bar"])
        XCTAssertEqual(store.repos[0].sessions.map(\.title), ["one", "three"])
        XCTAssertEqual(store.repos[1].sessions.map(\.title), ["two"])
        XCTAssertEqual(store.selectedSessionID, b)
    }

    func testRestoreResumesEachClaudeConversation() {
        let provider = CapturingProvider()
        let fake = FakePersistence()
        let a = UUID()
        fake.stored = SessionSnapshot(
            sessions: [.init(id: a, title: "one", workingDirectory: "/work/foo")],
            selectedSessionID: a,
            sessionCounter: 1
        )

        let store = SessionStore(provider: provider, persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        XCTAssertEqual(
            provider.configs.first?.initialInput,
            ClaudeSession.resumeCommand(sessionID: a, title: "one")
        )
    }

    func testRestoreDropsSessionsWhoseDirectoryIsGone() {
        let fake = FakePersistence()
        fake.stored = SessionSnapshot(
            sessions: [
                .init(id: UUID(), title: "gone", workingDirectory: "/work/deleted"),
                .init(id: UUID(), title: "kept", workingDirectory: "/work/foo"),
            ],
            selectedSessionID: nil,
            sessionCounter: 2
        )

        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: { $0 != "/work/deleted" }))
        XCTAssertEqual(store.repos.flatMap(\.sessions).map(\.title), ["kept"])
    }

    /// The counter must survive so a new session cannot collide with a restored name.
    func testRestoredCounterAvoidsTitleCollision() {
        let fake = FakePersistence()
        fake.stored = SessionSnapshot(
            sessions: [.init(id: UUID(), title: "session 3", workingDirectory: "/work/foo")],
            selectedSessionID: nil,
            sessionCounter: 3
        )

        let store = SessionStore(provider: CapturingProvider(), persistence: fake)
        XCTAssertTrue(store.restore(directoryExists: allDirsExist))
        let fresh = store.newSession(in: URL(fileURLWithPath: "/work/foo", isDirectory: true))
        XCTAssertEqual(fresh.title, "session 4")
    }

    func testRestoreReturnsFalseWhenNothingStored() {
        let store = SessionStore(provider: CapturingProvider(), persistence: FakePersistence())
        XCTAssertFalse(store.restore(directoryExists: allDirsExist))
        XCTAssertTrue(store.repos.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: FAIL — `cannot find type 'SessionSnapshot'`, no `persistence:` initializer.

- [ ] **Step 3: Write the persistence types**

```swift
// Sources/FlightDeck/SessionPersistence.swift
import Foundation

/// What survives a relaunch. Repos are derived from `workingDirectory`, so only
/// sessions are stored and the grouping rebuilds on restore.
struct SessionSnapshot: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let id: UUID
        var title: String
        let workingDirectory: String
    }

    var sessions: [Entry] = []
    var selectedSessionID: UUID?
    /// Persisted so a new session cannot reuse a restored session's number.
    var sessionCounter: Int = 0
}

@MainActor
protocol SessionPersisting: AnyObject {
    func load() -> SessionSnapshot?
    func save(_ snapshot: SessionSnapshot)
}

/// Stores the snapshot in the app's standard defaults domain
/// (`dev.flightdeck.FlightDeck`), which `scripts/smoke.sh` already wipes so the
/// UITest gate stays hermetic.
@MainActor
final class UserDefaultsSessionPersistence: SessionPersisting {
    private let defaults: UserDefaults
    private let key = "sessions.snapshot.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SessionSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    func save(_ snapshot: SessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}
```

- [ ] **Step 4: Wire the Store**

Add the stored property and initializer alongside the existing ones:

```swift
    private let persistence: SessionPersisting?

    init(provider: SurfaceProvider?, persistence: SessionPersisting? = nil) {
        self.provider = provider
        self.persistence = persistence
    }
```

Update the production convenience initializer so restore runs ahead of seeding:

```swift
    convenience init(ghostty: GhosttyApp?) {
        self.init(provider: ghostty, persistence: UserDefaultsSessionPersistence())
        if !restore() { seedInitialSession() }
    }
```

Extract the shared insert path so create and restore share one code path:

```swift
    /// Shared by `newSession` and `restore`. `initialInput` is the only difference:
    /// a fresh session starts `claude`, a restored one resumes it.
    @discardableResult
    private func insertSession(
        _ session: Session, in url: URL, initialInput: String
    ) -> Session {
        let repoIndex: Int
        if let existing = indexOfRepo(for: url) {
            repoIndex = existing
        } else {
            repos.append(Repo(url: url))
            repoIndex = repos.count - 1
        }
        repos[repoIndex].sessions.append(session)

        var config = Ghostty.SurfaceConfiguration()
        config.command = ShellResolver.resolve()
        config.workingDirectory = url.path
        config.initialInput = initialInput
        if let surface = provider?.makeSurface(config) {
            surfaces[session.id] = surface
        }
        provider?.tick()

        startWatching(session, workingDirectory: url.path)
        return session
    }
```

`newSession(in:)` becomes:

```swift
    @discardableResult
    func newSession(in url: URL) -> Session {
        sessionCounter += 1
        let session = Session(
            title: "session \(sessionCounter)", workingDirectory: url.path
        )
        insertSession(
            session,
            in: url,
            initialInput: ClaudeSession.launchCommand(
                sessionID: session.id, title: session.title
            )
        )
        selectedSessionID = session.id
        persist()
        return session
    }
```

Add restore and persistence:

```swift
    /// Rebuilds sessions from the last run. Returns false when there was nothing to
    /// restore, which is the caller's signal to seed a first session instead.
    /// Sessions whose working directory has since disappeared are dropped rather
    /// than resurrected as broken terminals.
    @discardableResult
    func restore(
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let snapshot = persistence?.load(), !snapshot.sessions.isEmpty else {
            return false
        }

        sessionCounter = snapshot.sessionCounter
        for entry in snapshot.sessions where directoryExists(entry.workingDirectory) {
            let url = URL(fileURLWithPath: entry.workingDirectory, isDirectory: true)
            let session = Session(
                id: entry.id, title: entry.title, workingDirectory: entry.workingDirectory
            )
            insertSession(
                session,
                in: url,
                initialInput: ClaudeSession.resumeCommand(
                    sessionID: entry.id, title: entry.title
                )
            )
        }

        let restoredIDs = Set(repos.flatMap(\.sessions).map(\.id))
        selectedSessionID = snapshot.selectedSessionID.flatMap {
            restoredIDs.contains($0) ? $0 : nil
        } ?? restoredIDs.first
        persist()
        return !restoredIDs.isEmpty
    }

    /// Saved on every mutation rather than at terminate, so a crash cannot lose the list.
    private func persist() {
        persistence?.save(
            SessionSnapshot(
                sessions: repos.flatMap(\.sessions).map {
                    .init(id: $0.id, title: $0.title, workingDirectory: $0.workingDirectory)
                },
                selectedSessionID: selectedSessionID,
                sessionCounter: sessionCounter
            )
        )
    }
```

Call `persist()` at the end of `closeSession(_:)`, `rename(_:to:)`, `applyExternalTitle(_:_:)`, and in `selectSession(_:)`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, including all earlier tasks.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionPersistence.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/FlightDeckApp.swift Tests/FlightDeckTests/SessionPersistenceTests.swift
git commit -m "feat: persist sessions and resume claude conversations on relaunch"
```

---

### Task 6: Sidebar inline edit

Double-click a row to rename it. Enter or blur commits, Esc cancels, empty reverts.

**Files:**
- Modify: `Sources/FlightDeck/SessionSidebar.swift:12-25`
- Test: `UITests/` (add one case to the existing session UITest file)

**Interfaces:**
- Consumes: `SessionStore.rename(_:to:)` from Task 2.
- Produces: a `TextField` with `accessibilityIdentifier("session-title-field")`.

- [ ] **Step 1: Write the implementation**

Replace the `ForEach(repo.sessions)` body so each row owns its edit state. Add above `SessionSidebar`:

```swift
/// One sidebar row. Owns only its transient edit state; the title itself lives in the Store.
private struct SessionRow: View {
    @ObservedObject var store: SessionStore
    let session: Session

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            if isEditing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .accessibilityIdentifier("session-title-field")
                    .onSubmit(commit)
                    .onExitCommand { isEditing = false }   // Esc
                    .onChange(of: focused) { if !$1 { commit() } }
            } else {
                Text(session.title)
                    .onTapGesture(count: 2) {
                        draft = session.title
                        isEditing = true
                        focused = true
                    }
            }
            Spacer()
            Button {
                store.closeSession(session.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("close-session")
        }
    }

    /// Empty input reverts: `rename` ignores it and we simply leave edit mode.
    private func commit() {
        guard isEditing else { return }
        isEditing = false
        store.rename(session.id, to: draft)
    }
}
```

And in `SessionSidebar.body`:

```swift
                    ForEach(repo.sessions) { session in
                        SessionRow(store: store, session: session)
                            .tag(session.id)
                    }
```

- [ ] **Step 2: Build and verify the unit suite still passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 3: Add the UITest case**

Append to the existing session UITest class (match the file's current naming and launch helper):

```swift
    func testDoubleClickRenamesSession() {
        let app = XCUIApplication()
        app.launch()

        let row = app.staticTexts.matching(identifier: "session-title-field").firstMatch
        let first = app.tables.cells.firstMatch
        first.doubleClick()

        let field = app.textFields["session-title-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("renamed\n")

        XCTAssertTrue(app.staticTexts["renamed"].waitForExistence(timeout: 5))
        _ = row
    }
```

- [ ] **Step 4: Run the smoke gate**

Run: `./scripts/smoke.sh 2>&1 | tail -20`
Expected: PASS. If it fails, read `scripts/.release-build.log` rather than re-running with more output.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionSidebar.swift UITests
git commit -m "feat: inline-edit session names in the sidebar"
```

---

## Self-Review

**Spec coverage.** §3.1 `ClaudeSession` → Task 1. §3.2 `TranscriptWatcher` → Task 4. §3.3 `SessionStore` rename + seam → Task 2, launch wiring → Task 3. §3.4 sidebar → Task 6. §3.5 persistence + restore → Task 5. §4 loop suppression → Task 2 (`testApplyExternalTitleIsNoOpWhenUnchanged`). §5 sanitization → Task 1. §6 testing → covered per task.

**Known gap, deliberately deferred.** The spec's §3.1 bounded-scan fallback (used when the encoding rule mispredicts the directory) is *not* implemented in Task 4 — the watcher simply stays idle if the file never appears, which is the same graceful degradation as "claude isn't running". Add it only if a real cwd is found where the rule mispredicts; it is dead code until then.

**Type consistency.** `sanitizedName` returns `String?` and every call site handles nil (Task 1 `launchCommand`, Task 2 `rename`/`applyExternalTitle`). `customTitle(inLine:sessionID:)` keeps one signature across Tasks 1 and 4. `TextInjecting.sendText` matches `Ghostty.Surface.sendText` at `Ghostty.Surface.swift:42`.
