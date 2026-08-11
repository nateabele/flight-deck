# Session Status Indicators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each Claude session's live activity as an SF Symbol in its sidebar row, with a sub-agent count when running agents, and raise a click-to-activate system notification when a backgrounded session blocks for input.

**Architecture:** Claude Code publishes an undocumented per-process status registry at `~/.claude/sessions/<pid>.json`. A single polling watcher reads it and keys entries by `sessionId` — the UUID Flight Deck already assigns via `--session-id`. Sub-agent counts come from the transcript Flight Deck already tails. `SessionStore` merges both into one `[UUID: SessionStatus]` map that the sidebar renders.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit, XCTest, XcodeGen, macOS 14 deployment target.

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-08-11-session-status-indicators-design.md`. Read it first.
- Swift 5 language mode (`SWIFT_VERSION: "5.0"`). Do not use Swift 6 strict-concurrency syntax.
- macOS 14 deployment target. Only SF Symbols 1.0 names are used: `circle.fill`, `questionmark.circle.fill`, `terminal.fill`.
- **Real SF Symbols only** — `Image(systemName:)` and `ProgressView`. No emoji, no unicode glyph characters anywhere in source or tests.
- All new types that touch the filesystem take an injectable root so tests use a temp directory. Follow the existing `SessionStore.projectsRoot` pattern.
- Unit tests are XCTest, `@testable import FlightDeck`, `@MainActor` where they touch `SessionStore`/watchers. Match the style in `Tests/FlightDeckTests/TranscriptWatcherTests.swift`.
- Run unit tests with `./scripts/test-unit.sh` (headless; UI tests need `./scripts/smoke.sh`).
- Never call `UNUserNotificationCenter.current()` from anything reachable by the unit-test bundle — it traps outside a signed bundle. That is what the `Notifying` protocol seam is for.
- New files go in `Sources/FlightDeck/`; XcodeGen picks them up from the directory, so `project.yml` needs no edit.
- Commit after each task with a `feat:`/`test:`/`docs:` prefix.

## File Structure

**Create:**
- `Sources/FlightDeck/SessionStatus.swift` — `SessionActivity`, `SessionStatus`, tooltip text.
- `Sources/FlightDeck/ClaudeStatusFile.swift` — pure decoding of one registry file.
- `Sources/FlightDeck/SessionStatusWatcher.swift` — polls `~/.claude/sessions/`.
- `Sources/FlightDeck/SessionStatusIcon.swift` — the row icon view.
- `Sources/FlightDeck/SessionNotificationPolicy.swift` — pure transition → action.
- `Sources/FlightDeck/SessionNotifier.swift` — `Notifying` protocol + `UNUserNotificationCenter` impl.
- Tests: `SessionStatusTests`, `ClaudeStatusFileTests`, `SessionStatusWatcherTests`, `TranscriptEventTests`, `SubagentCountTests`, `SessionStatusStoreTests`, `SessionNotificationPolicyTests`.

**Modify:**
- `Sources/FlightDeck/ClaudeSession.swift` — add `TranscriptEvent` + `events(inLine:sessionID:)`.
- `Sources/FlightDeck/TranscriptWatcher.swift` — emit sub-agent counts.
- `Sources/FlightDeck/SessionStore.swift` — own the status map and the watcher.
- `Sources/FlightDeck/SessionSidebar.swift` — `SessionRow` gets the icon and hover-gated close.
- `Sources/FlightDeck/AppDelegate.swift` — notification delegate + activation.
- `docs/ARCHITECTURE.md` — document the status pipeline.

---

### Task 1: Status model and registry decoding

**Files:**
- Create: `Sources/FlightDeck/SessionStatus.swift`
- Create: `Sources/FlightDeck/ClaudeStatusFile.swift`
- Test: `Tests/FlightDeckTests/SessionStatusTests.swift`
- Test: `Tests/FlightDeckTests/ClaudeStatusFileTests.swift`

**Interfaces:**
- Produces: `SessionActivity` (`.idle/.busy/.waiting/.shell`, `String` raw values matching the registry); `SessionStatus(activity:waitingFor:subagentCount:)` with `var tooltip: String`; `ClaudeStatusFile.Entry(pid:sessionID:activity:waitingFor:startedAt:)`; `ClaudeStatusFile.decode(_:expectedPID:) -> Entry?`; `ClaudeStatusFile.pid(fromFileName:) -> pid_t?`.

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/SessionStatusTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class SessionStatusTests: XCTestCase {
    func testIdleTooltip() {
        XCTAssertEqual(SessionStatus(activity: .idle).tooltip, "Idle")
    }

    func testBusyTooltipWithoutSubagents() {
        XCTAssertEqual(SessionStatus(activity: .busy).tooltip, "Working")
    }

    func testBusyTooltipSingularSubagent() {
        XCTAssertEqual(
            SessionStatus(activity: .busy, subagentCount: 1).tooltip,
            "Working — 1 subagent"
        )
    }

    func testBusyTooltipPluralSubagents() {
        XCTAssertEqual(
            SessionStatus(activity: .busy, subagentCount: 3).tooltip,
            "Working — 3 subagents"
        )
    }

    func testWaitingTooltipIncludesReason() {
        XCTAssertEqual(
            SessionStatus(activity: .waiting, waitingFor: "permission prompt").tooltip,
            "Waiting for you — permission prompt"
        )
    }

    func testWaitingTooltipWithoutReason() {
        XCTAssertEqual(SessionStatus(activity: .waiting).tooltip, "Waiting for you")
    }

    func testShellTooltip() {
        XCTAssertEqual(
            SessionStatus(activity: .shell).tooltip,
            "Background command running"
        )
    }

    /// The count is only meaningful while busy; other states render their own glyph.
    func testSubagentCountIgnoredWhenNotBusy() {
        XCTAssertEqual(SessionStatus(activity: .waiting, subagentCount: 5).tooltip,
                       "Waiting for you")
    }
}
```

`Tests/FlightDeckTests/ClaudeStatusFileTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ClaudeStatusFileTests: XCTestCase {
    private let sid = UUID(uuidString: "a8cf5a53-1a20-4e2c-b5d1-6fca4e6d73af")!

    private func json(
        pid: Int = 4242,
        status: String = "busy",
        waitingFor: String? = nil,
        startedAt: Double = 1_786_415_100_341
    ) -> Data {
        var obj: [String: Any] = [
            "pid": pid,
            "sessionId": sid.uuidString.lowercased(),
            "status": status,
            "startedAt": startedAt,
            "cwd": "/tmp",
            "kind": "interactive",
        ]
        if let waitingFor { obj["waitingFor"] = waitingFor }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    func testDecodesEachStatus() {
        for (raw, expected): (String, SessionActivity) in [
            ("idle", .idle), ("busy", .busy), ("waiting", .waiting), ("shell", .shell),
        ] {
            let entry = ClaudeStatusFile.decode(json(status: raw), expectedPID: 4242)
            XCTAssertEqual(entry?.activity, expected, "status \(raw)")
        }
    }

    func testDecodesWaitingReason() {
        let entry = ClaudeStatusFile.decode(
            json(status: "waiting", waitingFor: "permission prompt"), expectedPID: 4242
        )
        XCTAssertEqual(entry?.waitingFor, "permission prompt")
    }

    func testDecodesSessionIDAndStartedAt() {
        let entry = ClaudeStatusFile.decode(json(), expectedPID: 4242)
        XCTAssertEqual(entry?.sessionID, sid)
        XCTAssertEqual(entry?.startedAt, 1_786_415_100_341)
    }

    /// Schema drift: a status we do not know must degrade to "no status", never a guess.
    func testUnknownStatusYieldsNil() {
        XCTAssertNil(ClaudeStatusFile.decode(json(status: "compacting"), expectedPID: 4242))
    }

    /// The writer is a non-atomic in-place writeFile, so a reader can catch a torn file.
    func testTornJSONYieldsNil() {
        let torn = Data(#"{"pid":4242,"sessionId":"a8cf5a5"#.utf8)
        XCTAssertNil(ClaudeStatusFile.decode(torn, expectedPID: 4242))
    }

    func testPIDMismatchYieldsNil() {
        XCTAssertNil(ClaudeStatusFile.decode(json(pid: 4242), expectedPID: 9999))
    }

    func testNonUUIDSessionIDYieldsNil() {
        let obj: [String: Any] = ["pid": 4242, "sessionId": "not-a-uuid", "status": "idle"]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        XCTAssertNil(ClaudeStatusFile.decode(data, expectedPID: 4242))
    }

    func testPIDFromFileName() {
        XCTAssertEqual(ClaudeStatusFile.pid(fromFileName: "75951.json"), 75951)
        XCTAssertNil(ClaudeStatusFile.pid(fromFileName: "notes.json"))
        XCTAssertNil(ClaudeStatusFile.pid(fromFileName: "75951.txt"))
        XCTAssertNil(ClaudeStatusFile.pid(fromFileName: "007.json"))  // non-canonical
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `cannot find 'SessionStatus' in scope`, `cannot find 'ClaudeStatusFile' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/FlightDeck/SessionStatus.swift`:

```swift
import Foundation

/// What a Claude session is doing. Raw values match the `status` field written by
/// `claude` to `~/.claude/sessions/<pid>.json`.
///
/// `shell` is the non-obvious one: the model turn has finished but a backgrounded
/// Bash task is still running, so the session is neither working nor done.
enum SessionActivity: String, Equatable {
    case idle, busy, waiting, shell
}

/// A session's activity plus the detail the sidebar needs to describe it.
/// Absence of a status is represented by `nil` at the call site, not by a case —
/// "no `claude` running" renders nothing, which is distinct from `idle`.
struct SessionStatus: Equatable {
    var activity: SessionActivity
    /// Why the session is blocked, when `activity == .waiting`. Values come from
    /// `claude` verbatim: "permission prompt", "input needed", "dialog open", …
    var waitingFor: String?
    /// Outstanding top-level `Agent` tool calls. Only meaningful while `busy`.
    var subagentCount: Int

    init(activity: SessionActivity, waitingFor: String? = nil, subagentCount: Int = 0) {
        self.activity = activity
        self.waitingFor = waitingFor
        self.subagentCount = subagentCount
    }

    /// Tooltip and accessibility label. Kept on the model rather than in the view so
    /// it is testable without instantiating SwiftUI.
    var tooltip: String {
        switch activity {
        case .idle:
            return "Idle"
        case .busy:
            guard subagentCount > 0 else { return "Working" }
            let noun = subagentCount == 1 ? "subagent" : "subagents"
            return "Working — \(subagentCount) \(noun)"
        case .waiting:
            guard let waitingFor, !waitingFor.isEmpty else { return "Waiting for you" }
            return "Waiting for you — \(waitingFor)"
        case .shell:
            return "Background command running"
        }
    }
}
```

`Sources/FlightDeck/ClaudeStatusFile.swift`:

```swift
import Foundation

/// Pure decoding of one `~/.claude/sessions/<pid>.json` registry file. No I/O and no
/// state, so every rule is unit-testable.
///
/// The registry is undocumented and unversioned. Every parse rule here fails closed:
/// anything unrecognized yields nil, and the caller keeps its last known status rather
/// than showing a guess. See the design spec §1 for the field shapes and §10 for the
/// risk this mitigates.
enum ClaudeStatusFile {
    struct Entry: Equatable {
        let pid: pid_t
        let sessionID: UUID
        let activity: SessionActivity
        let waitingFor: String?
        /// Epoch milliseconds. Breaks ties when two files claim one session (crash,
        /// then resume): the newest wins.
        let startedAt: Double
    }

    /// Parses "<pid>.json". Rejects anything that does not round-trip back to the same
    /// digits, which is what `claude`'s own reader does before unlinking the file.
    static func pid(fromFileName name: String) -> pid_t? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = String(name.dropLast(5))
        guard let value = Int32(stem), String(value) == stem, value > 0 else { return nil }
        return value
    }

    /// `expectedPID` is the pid parsed from the filename; a mismatch means a stale or
    /// hand-edited file.
    static func decode(_ data: Data, expectedPID: pid_t) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // `pid_t(exactly:)`, not `pid_t(_:)` — the non-failable conversion traps
              // on an out-of-range value, which would crash on exactly the malformed
              // input this decoder exists to absorb.
              let rawPID = obj["pid"] as? Int,
              let pid = pid_t(exactly: rawPID), pid == expectedPID,
              let rawSession = obj["sessionId"] as? String,
              let sessionID = UUID(uuidString: rawSession),
              let rawStatus = obj["status"] as? String,
              let activity = SessionActivity(rawValue: rawStatus)
        else { return nil }

        // Also add a regression test for the out-of-range pid path:
        //   func testOutOfRangePIDYieldsNil() {
        //       XCTAssertNil(ClaudeStatusFile.decode(json(pid: 99_999_999_999), expectedPID: 4242))
        //   }

        return Entry(
            pid: expectedPID,
            sessionID: sessionID,
            activity: activity,
            waitingFor: obj["waitingFor"] as? String,
            startedAt: (obj["startedAt"] as? Double) ?? 0
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass, including the pre-existing suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStatus.swift Sources/FlightDeck/ClaudeStatusFile.swift \
        Tests/FlightDeckTests/SessionStatusTests.swift Tests/FlightDeckTests/ClaudeStatusFileTests.swift
git commit -m "feat: add session status model and registry decoding"
```

---

### Task 2: Poll the status registry

**Files:**
- Create: `Sources/FlightDeck/SessionStatusWatcher.swift`
- Test: `Tests/FlightDeckTests/SessionStatusWatcherTests.swift`

**Interfaces:**
- Consumes: `ClaudeStatusFile.decode(_:expectedPID:)`, `ClaudeStatusFile.pid(fromFileName:)`, `ClaudeStatusFile.Entry`.
- Produces: `SessionStatusWatcher(root:isAlive:onChange:)` where `onChange: ([UUID: ClaudeStatusFile.Entry]) -> Void`; `start()`, `stop()`, `drain()`; `static var defaultRoot: URL`; `static let processIsAlive: (pid_t) -> Bool`.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/SessionStatusWatcherTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionStatusWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(pid: Int, sid: UUID, status: String,
                       waitingFor: String? = nil, startedAt: Double = 1000) throws {
        var obj: [String: Any] = [
            "pid": pid, "sessionId": sid.uuidString.lowercased(),
            "status": status, "startedAt": startedAt,
        ]
        if let waitingFor { obj["waitingFor"] = waitingFor }
        try JSONSerialization.data(withJSONObject: obj)
            .write(to: dir.appendingPathComponent("\(pid).json"))
    }

    /// Every process is alive unless a test says otherwise.
    private func watcher(
        alive: @escaping (pid_t) -> Bool = { _ in true },
        onChange: @escaping ([UUID: ClaudeStatusFile.Entry]) -> Void
    ) -> SessionStatusWatcher {
        SessionStatusWatcher(root: dir, isAlive: alive, onChange: onChange)
    }

    func testMapsFileToSessionID() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "waiting", waitingFor: "permission prompt")

        var seen: [UUID: ClaudeStatusFile.Entry] = [:]
        watcher { seen = $0 }.drain()

        XCTAssertEqual(seen[sid]?.activity, .waiting)
        XCTAssertEqual(seen[sid]?.waitingFor, "permission prompt")
    }

    func testPicksUpStatusChangeOnSecondDrain() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "busy")

        var seen: [UUID: ClaudeStatusFile.Entry] = [:]
        let w = watcher { seen = $0 }
        w.drain()
        XCTAssertEqual(seen[sid]?.activity, .busy)

        try write(pid: 100, sid: sid, status: "idle")
        w.drain()
        XCTAssertEqual(seen[sid]?.activity, .idle)
    }

    /// `claude` unlinks its file only on a clean exit, so a crash leaks one.
    func testSkipsDeadProcesses() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "busy")

        var seen: [UUID: ClaudeStatusFile.Entry] = [:]
        watcher(alive: { _ in false }) { seen = $0 }.drain()

        XCTAssertTrue(seen.isEmpty)
    }

    /// A crash-then-resume leaves two files for one session; the newest wins.
    func testDuplicateSessionIDResolvesToNewestStartedAt() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "idle", startedAt: 1000)
        try write(pid: 200, sid: sid, status: "busy", startedAt: 2000)

        var seen: [UUID: ClaudeStatusFile.Entry] = [:]
        watcher { seen = $0 }.drain()

        XCTAssertEqual(seen[sid]?.activity, .busy)
        XCTAssertEqual(seen[sid]?.pid, 200)
    }

    /// A torn read must not look like "session gone" — the last good status stands.
    func testTornFileKeepsLastKnownStatus() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "busy")

        var seen: [UUID: ClaudeStatusFile.Entry] = [:]
        let w = watcher { seen = $0 }
        w.drain()

        // Truncate mid-object, exactly as an in-place rewrite can be observed.
        try Data(#"{"pid":100,"sessi"#.utf8)
            .write(to: dir.appendingPathComponent("100.json"))
        w.drain()

        XCTAssertEqual(seen[sid]?.activity, .busy)
    }

    func testRemovedFileDropsSession() throws {
        let sid = UUID()
        try write(pid: 100, sid: sid, status: "busy")

        var seen: [UUID: ClaudeStatusFile.Entry] = [:]
        let w = watcher { seen = $0 }
        w.drain()

        try FileManager.default.removeItem(at: dir.appendingPathComponent("100.json"))
        w.drain()

        XCTAssertTrue(seen.isEmpty)
    }

    func testIgnoresNonPIDFiles() throws {
        try Data("{}".utf8).write(to: dir.appendingPathComponent("notes.json"))

        var called = false
        watcher { _ in called = true }.drain()

        XCTAssertTrue(called, "drain still reports an empty map")
    }

    func testMissingRootIsNotAnError() {
        let missing = dir.appendingPathComponent("nope", isDirectory: true)
        var seen: [UUID: ClaudeStatusFile.Entry] = [:]
        SessionStatusWatcher(root: missing, isAlive: { _ in true }) { seen = $0 }.drain()
        XCTAssertTrue(seen.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: compile failure — `cannot find 'SessionStatusWatcher' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/FlightDeck/SessionStatusWatcher.swift`:

```swift
import Foundation

/// Polls Claude Code's per-process status registry and reports every live session's
/// status, keyed by the session UUID Flight Deck assigned with `--session-id`.
///
/// One instance serves the whole app: the registry is a single flat directory, so a
/// per-session watcher would re-scan the same files N times.
///
/// Polling rather than a vnode watch is forced by how `claude` writes the file — a
/// non-atomic in-place `writeFile`, with no create/rename, so a directory watch would
/// never fire on a status change. That same in-place write means a read can land
/// mid-write; see `drain()`.
@MainActor
final class SessionStatusWatcher {
    static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    /// `EPERM` means the process exists but belongs to another user — still alive.
    static let processIsAlive: (pid_t) -> Bool = { pid in
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private let root: URL
    private let isAlive: (pid_t) -> Bool
    private let onChange: ([UUID: ClaudeStatusFile.Entry]) -> Void

    /// Last successfully decoded entry per filename. Survives a torn read so a
    /// half-written file does not read as "session gone".
    private var cache: [String: ClaudeStatusFile.Entry] = [:]
    private var mtimes: [String: Date] = [:]
    private var timer: DispatchSourceTimer?

    init(
        root: URL = SessionStatusWatcher.defaultRoot,
        isAlive: @escaping (pid_t) -> Bool = SessionStatusWatcher.processIsAlive,
        onChange: @escaping ([UUID: ClaudeStatusFile.Entry]) -> Void
    ) {
        self.root = root
        self.isAlive = isAlive
        self.onChange = onChange
    }

    deinit { timer?.cancel() }

    /// 500 ms matches `TranscriptWatcher`; the registry is a handful of small files.
    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.drain() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Rescans the registry and reports the current map. Synchronous so tests need no
    /// expectations. A missing root is normal (no `claude` has ever run) and reports
    /// an empty map rather than failing.
    func drain() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var live: [String: ClaudeStatusFile.Entry] = [:]

        for name in names {
            guard let pid = ClaudeStatusFile.pid(fromFileName: name), isAlive(pid) else {
                continue
            }
            let url = root.appendingPathComponent(name)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date

            // Unchanged since the last look: reuse the decoded entry.
            if let mtime, mtimes[name] == mtime, let cached = cache[name] {
                live[name] = cached
                continue
            }

            if let data = try? Data(contentsOf: url),
               let entry = ClaudeStatusFile.decode(data, expectedPID: pid) {
                cache[name] = entry
                mtimes[name] = mtime
                live[name] = entry
            } else if let cached = cache[name] {
                // Torn or momentarily invalid: keep the last good value and re-read
                // next tick. Deliberately does not update `mtimes`.
                live[name] = cached
            }
        }

        // Drop cache for files that vanished, so a closed session stops reporting.
        let present = Set(live.keys)
        cache = cache.filter { present.contains($0.key) }
        mtimes = mtimes.filter { present.contains($0.key) }

        var bySession: [UUID: ClaudeStatusFile.Entry] = [:]
        for entry in live.values {
            if let existing = bySession[entry.sessionID], existing.startedAt >= entry.startedAt {
                continue
            }
            bySession[entry.sessionID] = entry
        }
        onChange(bySession)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStatusWatcher.swift \
        Tests/FlightDeckTests/SessionStatusWatcherTests.swift
git commit -m "feat: poll Claude's session status registry"
```

---

### Task 3: Sub-agent counting from the transcript

**Files:**
- Modify: `Sources/FlightDeck/ClaudeSession.swift` (append to the enum)
- Modify: `Sources/FlightDeck/TranscriptWatcher.swift`
- Test: `Tests/FlightDeckTests/TranscriptEventTests.swift`
- Test: `Tests/FlightDeckTests/SubagentCountTests.swift`

**Interfaces:**
- Produces: `ClaudeSession.TranscriptEvent` (`.title(String)`, `.agentStarted(String)`, `.agentFinished(String)`, `.turnEnded`); `ClaudeSession.events(inLine:sessionID:) -> [TranscriptEvent]`; `TranscriptWatcher.init(sessionID:url:onTitle:onSubagentCount:)` where the new callback defaults to a no-op so existing call sites compile unchanged.

- [ ] **Step 1: Write the failing tests**

`Tests/FlightDeckTests/TranscriptEventTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class TranscriptEventTests: XCTestCase {
    private let sid = UUID()

    private func events(_ line: String) -> [ClaudeSession.TranscriptEvent] {
        ClaudeSession.events(inLine: line, sessionID: sid)
    }

    func testParsesCustomTitle() {
        let line = #"{"type":"custom-title","customTitle":"hello","sessionId":"\#(sid.uuidString.lowercased())"}"#
        XCTAssertEqual(events(line), [.title("hello")])
    }

    func testIgnoresCustomTitleForAnotherSession() {
        let line = #"{"type":"custom-title","customTitle":"hello","sessionId":"\#(UUID().uuidString.lowercased())"}"#
        XCTAssertEqual(events(line), [])
    }

    func testParsesAgentToolUse() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{}}]}}
        """#
        XCTAssertEqual(events(line), [.agentStarted("toolu_1")])
    }

    func testParsesMultipleAgentToolUsesInOneRecord() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Agent"},{"type":"tool_use","id":"toolu_2","name":"Agent"}]}}
        """#
        XCTAssertEqual(events(line), [.agentStarted("toolu_1"), .agentStarted("toolu_2")])
    }

    func testIgnoresNonAgentToolUse() {
        let line = #"""
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_9","name":"Bash"}]}}
        """#
        XCTAssertEqual(events(line), [])
    }

    /// Emitted for every tool_result; the watcher's set makes non-Agent ids a no-op.
    func testParsesToolResultAsAgentFinished() {
        let line = #"""
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1"}]}}
        """#
        XCTAssertEqual(events(line), [.agentFinished("toolu_1")])
    }

    func testParsesTurnDuration() {
        let line = #"{"type":"system","subtype":"turn_duration","durationMs":1178896}"#
        XCTAssertEqual(events(line), [.turnEnded])
    }

    func testIgnoresOtherSystemSubtypes() {
        let line = #"{"type":"system","subtype":"stop_hook_summary"}"#
        XCTAssertEqual(events(line), [])
    }

    func testMalformedLineYieldsNothing() {
        XCTAssertEqual(events("not json"), [])
        XCTAssertEqual(events(""), [])
    }
}
```

`Tests/FlightDeckTests/SubagentCountTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SubagentCountTests: XCTestCase {
    private var dir: URL!
    private let sid = UUID()

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func start(_ url: URL, counts: @escaping (Int) -> Void) -> TranscriptWatcher {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let w = TranscriptWatcher(
            sessionID: sid, url: url, onTitle: { _ in }, onSubagentCount: counts
        )
        w.drain() // prime while empty, mirroring production
        return w
    }

    private func agentStart(_ id: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Agent"}]}}"# + "\n"
    }

    private func toolResult(_ id: String) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)"}]}}"# + "\n"
    }

    private let turnEnd = #"{"type":"system","subtype":"turn_duration"}"# + "\n"

    func testCountsOutstandingAgents() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        try (agentStart("a") + agentStart("b")).write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertEqual(seen.last, 2)
    }

    func testFinishedAgentDecrementsCount() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        try (agentStart("a") + agentStart("b")).write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        try (agentStart("a") + agentStart("b") + toolResult("a"))
            .write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertEqual(seen.last, 1)
    }

    /// The self-heal: a count inherited from attaching mid-turn clears at the boundary.
    func testTurnEndResetsCount() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        try agentStart("a").write(to: url, atomically: true, encoding: .utf8)
        w.drain()
        XCTAssertEqual(seen.last, 1)

        try (agentStart("a") + turnEnd).write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertEqual(seen.last, 0)
    }

    func testUnknownToolResultDoesNotReport() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        var seen: [Int] = []
        let w = start(url) { seen.append($0) }

        try toolResult("never-started").write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertTrue(seen.isEmpty, "no change means no callback")
    }

    func testTitleStillReported() throws {
        let url = dir.appendingPathComponent("t.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        var titles: [String] = []
        let w = TranscriptWatcher(sessionID: sid, url: url, onTitle: { titles.append($0) })
        w.drain()

        let line = #"{"type":"custom-title","customTitle":"renamed","sessionId":"\#(sid.uuidString.lowercased())"}"# + "\n"
        try line.write(to: url, atomically: true, encoding: .utf8)
        w.drain()

        XCTAssertEqual(titles, ["renamed"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: compile failure — no `TranscriptEvent`, no `events(inLine:sessionID:)`, no `onSubagentCount:` label.

- [ ] **Step 3: Add the parser to `ClaudeSession`**

Append inside `enum ClaudeSession` in `Sources/FlightDeck/ClaudeSession.swift`, after `customTitle(inLine:sessionID:)`:

```swift
    /// One state-bearing thing that happened in the transcript.
    ///
    /// `agentFinished` is emitted for *every* tool_result, not just `Agent` ones —
    /// the record does not name the tool it answers. `TranscriptWatcher` keeps a set
    /// of outstanding `Agent` ids, so an unrelated id is a harmless no-op there and
    /// this parser stays free of cross-record state.
    enum TranscriptEvent: Equatable {
        case title(String)
        case agentStarted(String)
        case agentFinished(String)
        case turnEnded
    }

    /// Parses one JSONL line into zero or more events. A single assistant record can
    /// carry several `tool_use` blocks, hence the array.
    ///
    /// Only `custom-title` is filtered by `sessionID` (preserving `customTitle`'s
    /// existing rule). The tool records need no such filter: this file is already
    /// scoped to one session, and sub-agent records live in a separate
    /// `subagents/agent-*.jsonl` file, so only top-level agents are ever seen here.
    static func events(inLine line: String, sessionID: UUID) -> [TranscriptEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }

        switch type {
        case "custom-title":
            return customTitle(inLine: line, sessionID: sessionID).map { [.title($0)] } ?? []

        case "system":
            return obj["subtype"] as? String == "turn_duration" ? [.turnEnded] : []

        case "assistant":
            return contentBlocks(obj).compactMap { block in
                guard block["type"] as? String == "tool_use",
                      block["name"] as? String == "Agent",
                      let id = block["id"] as? String
                else { return nil }
                return .agentStarted(id)
            }

        case "user":
            return contentBlocks(obj).compactMap { block in
                guard block["type"] as? String == "tool_result",
                      let id = block["tool_use_id"] as? String
                else { return nil }
                return .agentFinished(id)
            }

        default:
            return []
        }
    }

    private static func contentBlocks(_ obj: [String: Any]) -> [[String: Any]] {
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }
        return content
    }
```

- [ ] **Step 4: Teach `TranscriptWatcher` to count**

In `Sources/FlightDeck/TranscriptWatcher.swift`, add the stored properties next to `onTitle`:

```swift
    private let onSubagentCount: (Int) -> Void

    /// Outstanding top-level `Agent` tool_use ids. Cleared at every turn boundary, which
    /// is what makes a miscount from attaching mid-turn self-correcting rather than
    /// permanent.
    private var outstandingAgents: Set<String> = []
```

Replace the initializer with:

```swift
    /// `onSubagentCount` defaults to a no-op so title-only call sites are unaffected.
    init(
        sessionID: UUID,
        url: URL,
        onTitle: @escaping (String) -> Void,
        onSubagentCount: @escaping (Int) -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.url = url
        self.onTitle = onTitle
        self.onSubagentCount = onSubagentCount
    }
```

Replace the `let titles = …` / `if let last = titles.last` tail of `drain()` with:

```swift
        var lastTitle: String?
        var countChanged = false

        for raw in String(decoding: data[..<lastNewline], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true) {
            for event in ClaudeSession.events(inLine: String(raw), sessionID: sessionID) {
                switch event {
                case .title(let title):
                    lastTitle = title
                case .agentStarted(let id):
                    if outstandingAgents.insert(id).inserted { countChanged = true }
                case .agentFinished(let id):
                    if outstandingAgents.remove(id) != nil { countChanged = true }
                case .turnEnded:
                    if !outstandingAgents.isEmpty {
                        outstandingAgents.removeAll()
                        countChanged = true
                    }
                }
            }
        }

        if let lastTitle { onTitle(lastTitle) }
        if countChanged { onSubagentCount(outstandingAgents.count) }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass, including the pre-existing `TranscriptWatcherTests`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/ClaudeSession.swift Sources/FlightDeck/TranscriptWatcher.swift \
        Tests/FlightDeckTests/TranscriptEventTests.swift Tests/FlightDeckTests/SubagentCountTests.swift
git commit -m "feat: count outstanding subagents from the transcript"
```

---

### Task 4: Merge both sources in the store

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Test: `Tests/FlightDeckTests/SessionStatusStoreTests.swift`

**Interfaces:**
- Consumes: `SessionStatusWatcher`, `ClaudeStatusFile.Entry`, `SessionStatus`, `TranscriptWatcher.init(…onSubagentCount:)`.
- Produces: `SessionStore.statuses: [UUID: SessionStatus]` (`@Published private(set)`); `SessionStore.status(for:) -> SessionStatus?`; `SessionStore.sessionsRoot: URL`; `SessionStore.startStatusWatching()`; `SessionStore.applyRegistry(_:)` and `SessionStore.applySubagentCount(_:_:)` (internal, for tests).

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/SessionStatusStoreTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionStatusStoreTests: XCTestCase {
    private func makeStore() -> SessionStore {
        SessionStore(provider: nil, persistence: nil)
    }

    private func entry(_ sid: UUID, _ activity: SessionActivity,
                       waitingFor: String? = nil) -> ClaudeStatusFile.Entry {
        .init(pid: 1, sessionID: sid, activity: activity,
              waitingFor: waitingFor, startedAt: 1)
    }

    func testRegistryPopulatesStatusForKnownSession() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .busy)])

        XCTAssertEqual(store.status(for: session.id)?.activity, .busy)
    }

    /// The registry lists every `claude` on the machine, including ones the user runs
    /// in other terminals. Those must never appear.
    func testIgnoresSessionsNotInStore() {
        let store = makeStore()
        let stranger = UUID()

        store.applyRegistry([stranger: entry(stranger, .busy)])

        XCTAssertNil(store.status(for: stranger))
        XCTAssertTrue(store.statuses.isEmpty)
    }

    func testSubagentCountSurvivesRegistryRefresh() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .busy)])
        store.applySubagentCount(session.id, 3)
        store.applyRegistry([session.id: entry(session.id, .busy)])

        XCTAssertEqual(store.status(for: session.id)?.subagentCount, 3)
    }

    /// A count can arrive before the registry has ever been read.
    func testSubagentCountArrivingBeforeRegistryIsRetained() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applySubagentCount(session.id, 2)
        store.applyRegistry([session.id: entry(session.id, .busy)])

        XCTAssertEqual(store.status(for: session.id)?.subagentCount, 2)
    }

    func testDisappearingSessionClearsStatus() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .busy)])
        store.applyRegistry([:])

        XCTAssertNil(store.status(for: session.id))
    }

    func testClosingSessionDropsItsStatus() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .busy)])
        store.applySubagentCount(session.id, 2)
        store.closeSession(session.id)

        XCTAssertNil(store.status(for: session.id))
    }

    func testWaitingReasonIsCarriedThrough() {
        let store = makeStore()
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([
            session.id: entry(session.id, .waiting, waitingFor: "input needed"),
        ])

        XCTAssertEqual(store.status(for: session.id)?.waitingFor, "input needed")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: compile failure — `value of type 'SessionStore' has no member 'applyRegistry'`.

- [ ] **Step 3: Write the implementation**

In `Sources/FlightDeck/SessionStore.swift`, add near the other `@Published` properties:

```swift
    /// Live activity per session, merged from two sources: the status registry supplies
    /// `activity`/`waitingFor`, the transcript watchers supply `subagentCount`.
    /// A session with no entry is absent from the map — that renders no icon, which is
    /// deliberately distinct from `.idle`.
    @Published private(set) var statuses: [UUID: SessionStatus] = [:]
```

Add near `projectsRoot`:

```swift
    /// Injectable so tests can point at a temp directory.
    var sessionsRoot: URL = SessionStatusWatcher.defaultRoot

    /// Sub-agent counts kept separately so one arriving before the registry has been
    /// read is not lost, and so a registry refresh never clobbers it.
    private var subagentCounts: [UUID: Int] = [:]
    private var statusWatcher: SessionStatusWatcher?
```

Add the methods (place them after `applyExternalTitle`):

```swift
    func status(for id: UUID) -> SessionStatus? { statuses[id] }

    /// Starts registry polling. Called from the production convenience init only, so
    /// tests using `init(provider:persistence:)` never touch the real registry or spin
    /// a timer.
    func startStatusWatching() {
        guard statusWatcher == nil else { return }
        let watcher = SessionStatusWatcher(root: sessionsRoot) { [weak self] entries in
            self?.applyRegistry(entries)
        }
        watcher.start()
        statusWatcher = watcher
    }

    /// Rebuilds `statuses` from a registry scan. Entries for sessions Flight Deck does
    /// not own are dropped: the registry lists every `claude` on the machine.
    func applyRegistry(_ entries: [UUID: ClaudeStatusFile.Entry]) {
        var next: [UUID: SessionStatus] = [:]
        for repo in repos {
            for session in repo.sessions {
                guard let entry = entries[session.id] else { continue }
                next[session.id] = SessionStatus(
                    activity: entry.activity,
                    waitingFor: entry.waitingFor,
                    subagentCount: subagentCounts[session.id] ?? 0
                )
            }
        }
        guard next != statuses else { return }
        // A session that HAD a status and no longer does means its `claude` exited.
        // Drop its sub-agent count too, so a later process reusing the same session
        // UUID does not inherit a count from the dead one. Counts for sessions that
        // never had a status are deliberately left alone — that is the
        // count-arrives-before-registry case.
        for id in statuses.keys where next[id] == nil {
            subagentCounts.removeValue(forKey: id)
        }
        statuses = next
    }

    /// Applied from a transcript watcher. Stored even when the registry has not yet
    /// reported this session, so the next `applyRegistry` picks it up.
    func applySubagentCount(_ id: UUID, _ count: Int) {
        guard subagentCounts[id] != count else { return }
        subagentCounts[id] = count
        guard var status = statuses[id] else { return }
        status.subagentCount = count
        statuses[id] = status
    }
```

In `startWatching(_:workingDirectory:)`, pass the new callback:

```swift
        ) { [weak self] title in
            self?.applyExternalTitle(session.id, title)
        } onSubagentCount: { [weak self] count in
            self?.applySubagentCount(session.id, count)
        }
```

In `closeSession(_:)`, after `watchers.removeValue(forKey: id)`:

```swift
        statuses.removeValue(forKey: id)
        subagentCounts.removeValue(forKey: id)
```

In the convenience init `init(ghostty:resetState:)`, after the restore/seed line:

```swift
        startStatusWatching()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionStatusStoreTests.swift
git commit -m "feat: merge registry and subagent status in the store"
```

---

### Task 5: Row icon and hover-revealed close button

**Files:**
- Create: `Sources/FlightDeck/SessionStatusIcon.swift`
- Modify: `Sources/FlightDeck/SessionSidebar.swift` (the `SessionRow` struct only)
- Test: `UITests/FlightDeckUITests/TerminalSmokeTests.swift`

**Interfaces:**
- Consumes: `SessionStatus`, `SessionStatus.tooltip`, `SessionStore.status(for:)`.
- Produces: `SessionStatusIcon(status: SessionStatus?)`, carrying accessibility identifier `session-status`.

- [ ] **Step 1: Write the view**

`Sources/FlightDeck/SessionStatusIcon.swift`:

```swift
import SwiftUI

/// The status glyph at the trailing edge of a sidebar row.
///
/// Each state gets a distinct SF Symbol as well as a distinct tint: Apple's HIG warns
/// against carrying meaning in colour alone, and the tooltip needs a deliberate hover
/// to read. `busy` uses a real indeterminate `ProgressView` because that is the macOS
/// idiom for work of unknown duration.
///
/// A nil status renders nothing — "no `claude` running here", distinct from `.idle`.
struct SessionStatusIcon: View {
    let status: SessionStatus?

    var body: some View {
        if let status {
            HStack(spacing: 2) {
                glyph(for: status.activity)
                if status.activity == .busy, status.subagentCount > 0 {
                    Text("\(status.subagentCount)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tint)
                }
            }
            .help(status.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status.tooltip)
            .accessibilityIdentifier("session-status")
        }
    }

    @ViewBuilder
    private func glyph(for activity: SessionActivity) -> some View {
        switch activity {
        case .idle:
            symbol("circle.fill").foregroundStyle(.secondary)
        case .busy:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
        case .waiting:
            symbol("questionmark.circle.fill").foregroundStyle(.orange)
        case .shell:
            symbol("terminal.fill").foregroundStyle(.green)
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .imageScale(.small)
            .symbolRenderingMode(.hierarchical)
    }
}
```

- [ ] **Step 2: Wire it into the row**

In `Sources/FlightDeck/SessionSidebar.swift`, add to `SessionRow`'s stored state:

```swift
    @State private var isHovered = false
```

Replace the `Spacer()` + close `Button` tail of `SessionRow.body`'s `HStack` with:

```swift
            Spacer()
            SessionStatusIcon(status: store.status(for: session.id))
            // The close button is absent, not merely hidden, until hover: inserting it
            // is what pushes the status icon left. No manual offset needed.
            if isHovered {
                Button {
                    store.closeSession(session.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("close-session")
            }
```

Change the `HStack {` opening the body to `HStack(spacing: 4) {`, and add after the closing brace of the `HStack`:

```swift
        // Known wart: .onHover does not fire while a trackpad scroll is in flight, so a
        // row can hold a stale hover state after scrolling. Fixing it needs a tracking-area
        // NSViewRepresentable; out of scope here.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: builds clean, all existing tests still pass.

- [ ] **Step 4: Add the UI test**

Append to `UITests/FlightDeckUITests/TerminalSmokeTests.swift`, inside the existing test class:

```swift
    /// The close button is hover-gated now, so it must be absent at rest and present
    /// once the pointer is over the row.
    func testHoverRevealsCloseButtonBesideStatusIcon() {
        let app = XCUIApplication()
        app.launchArguments += ["-FlightDeckResetState", "YES"]
        app.launch()

        let row = app.staticTexts.matching(
            identifier: "session-row-title"
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30))

        XCTAssertFalse(app.buttons["close-session"].exists,
                       "close button should be hidden until hover")

        row.hover()

        XCTAssertTrue(app.buttons["close-session"].waitForExistence(timeout: 5))
    }
```

- [ ] **Step 5: Run the UI test**

Run: `./scripts/smoke.sh 2>&1 | tail -30`
Expected: PASS. This needs a GUI login session and the one-time UI-automation TCC grant. If the environment cannot grant it, record that the test was written but not executed — do not delete it, and do not claim it passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStatusIcon.swift Sources/FlightDeck/SessionSidebar.swift \
        UITests/FlightDeckUITests/TerminalSmokeTests.swift
git commit -m "feat: show session status icon with hover-revealed close button"
```

---

### Task 6: Notification policy

**Files:**
- Create: `Sources/FlightDeck/SessionNotificationPolicy.swift`
- Test: `Tests/FlightDeckTests/SessionNotificationPolicyTests.swift`

**Interfaces:**
- Consumes: `SessionStatus`, `SessionActivity`.
- Produces: `SessionNotificationPolicy.Action` (`.none`, `.notify(waitingFor: String?)`, `.withdraw`); `SessionNotificationPolicy.action(old:new:appActive:) -> Action`.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/SessionNotificationPolicyTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class SessionNotificationPolicyTests: XCTestCase {
    private typealias Policy = SessionNotificationPolicy

    private let busy = SessionStatus(activity: .busy)
    private let waiting = SessionStatus(activity: .waiting, waitingFor: "permission prompt")

    func testNotifiesOnEnteringWaitingWhileBackgrounded() {
        XCTAssertEqual(
            Policy.action(old: busy, new: waiting, appActive: false),
            .notify(waitingFor: "permission prompt")
        )
    }

    func testSuppressedWhileAppIsFrontmost() {
        XCTAssertEqual(Policy.action(old: busy, new: waiting, appActive: true), .none)
    }

    func testDoesNotRefireWhileStillWaiting() {
        XCTAssertEqual(Policy.action(old: waiting, new: waiting, appActive: false), .none)
    }

    func testWithdrawsWhenLeavingWaiting() {
        XCTAssertEqual(Policy.action(old: waiting, new: busy, appActive: false), .withdraw)
    }

    /// Withdrawal must not depend on focus — the prompt resolved either way.
    func testWithdrawsEvenWhileFrontmost() {
        XCTAssertEqual(Policy.action(old: waiting, new: busy, appActive: true), .withdraw)
    }

    func testWithdrawsWhenSessionDisappearsWhileWaiting() {
        XCTAssertEqual(Policy.action(old: waiting, new: nil, appActive: false), .withdraw)
    }

    func testNotifiesWhenSessionAppearsAlreadyWaiting() {
        XCTAssertEqual(
            Policy.action(old: nil, new: waiting, appActive: false),
            .notify(waitingFor: "permission prompt")
        )
    }

    func testNoActionForUnrelatedTransitions() {
        XCTAssertEqual(Policy.action(old: busy, new: busy, appActive: false), .none)
        XCTAssertEqual(
            Policy.action(old: SessionStatus(activity: .idle),
                          new: SessionStatus(activity: .shell), appActive: false),
            .none
        )
        XCTAssertEqual(Policy.action(old: nil, new: nil, appActive: false), .none)
    }

    func testNotifyCarriesNilReasonWhenAbsent() {
        XCTAssertEqual(
            Policy.action(old: busy, new: SessionStatus(activity: .waiting), appActive: false),
            .notify(waitingFor: nil)
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: compile failure — `cannot find 'SessionNotificationPolicy' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/FlightDeck/SessionNotificationPolicy.swift`:

```swift
import Foundation

/// Decides whether a status transition should raise, withdraw, or ignore a notification.
///
/// Pure and total so the whole policy is testable without `UNUserNotificationCenter`,
/// which cannot be instantiated in the unit-test bundle.
enum SessionNotificationPolicy {
    enum Action: Equatable {
        case none
        case notify(waitingFor: String?)
        case withdraw
    }

    /// Fires only on the *edge* into `waiting`, so a session that stays blocked does not
    /// re-notify on every poll. Withdrawal ignores `appActive`: once the prompt is gone
    /// the banner is stale regardless of where focus was.
    static func action(
        old: SessionStatus?, new: SessionStatus?, appActive: Bool
    ) -> Action {
        let wasWaiting = old?.activity == .waiting
        let isWaiting = new?.activity == .waiting

        if isWaiting, !wasWaiting {
            return appActive ? .none : .notify(waitingFor: new?.waitingFor)
        }
        if wasWaiting, !isWaiting {
            return .withdraw
        }
        return .none
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionNotificationPolicy.swift \
        Tests/FlightDeckTests/SessionNotificationPolicyTests.swift
git commit -m "feat: add session notification policy"
```

---

### Task 7: Deliver notifications and activate on click

**Files:**
- Create: `Sources/FlightDeck/SessionNotifier.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Modify: `Sources/FlightDeck/AppDelegate.swift`
- Modify: `docs/ARCHITECTURE.md`
- Test: `Tests/FlightDeckTests/SessionStatusStoreTests.swift` (extend)

**Interfaces:**
- Consumes: `SessionNotificationPolicy.action(old:new:appActive:)`, `SessionStore.statuses`, `SessionStore.selectSession(_:)`.
- Produces: `protocol Notifying`; `SessionNotifier`; `Notification.Name.flightDeckActivateSession` (userInfo key `"sessionID"`, value `UUID`); `SessionStore.notifier: Notifying?`; `SessionStore.appIsActive: () -> Bool`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/SessionStatusStoreTests.swift`:

```swift
    private final class SpyNotifier: Notifying {
        var notified: [(UUID, String, String)] = []
        var withdrawn: [UUID] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, body: String) {
            notified.append((sessionID, title, body))
        }
        func withdraw(sessionID: UUID) { withdrawn.append(sessionID) }
    }

    func testNotifiesWhenSessionStartsWaitingAndAppIsBackgrounded() {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        store.appIsActive = { false }
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .busy)])
        store.applyRegistry([
            session.id: entry(session.id, .waiting, waitingFor: "permission prompt"),
        ])

        XCTAssertEqual(spy.notified.count, 1)
        XCTAssertEqual(spy.notified.first?.0, session.id)
        XCTAssertEqual(spy.notified.first?.2, "Waiting for you — permission prompt")
    }

    func testDoesNotNotifyWhileAppIsFrontmost() {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        store.appIsActive = { true }
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .waiting)])

        XCTAssertTrue(spy.notified.isEmpty)
    }

    func testWithdrawsWhenPromptResolves() {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        store.appIsActive = { false }
        let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

        store.applyRegistry([session.id: entry(session.id, .waiting)])
        store.applyRegistry([session.id: entry(session.id, .busy)])

        XCTAssertEqual(spy.withdrawn, [session.id])
    }

    func testActivationNotificationSelectsSession() {
        let store = makeStore()
        let first = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))
        let second = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))
        store.selectSession(first.id)

        NotificationCenter.default.post(
            name: .flightDeckActivateSession,
            object: nil,
            userInfo: ["sessionID": second.id]
        )

        XCTAssertEqual(store.selectedSessionID, second.id)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: compile failure — `cannot find type 'Notifying' in scope`.

- [ ] **Step 3: Write the notifier**

`Sources/FlightDeck/SessionNotifier.swift`:

```swift
import Foundation
import UserNotifications

extension Notification.Name {
    /// Posted when the user clicks a session notification. userInfo: `["sessionID": UUID]`.
    /// A `NotificationCenter` hop rather than a direct reference because `AppDelegate` is
    /// created by `@NSApplicationDelegateAdaptor` and the store by `FlightDeckApp.init`,
    /// with no ordering guarantee between them.
    static let flightDeckActivateSession = Notification.Name("FlightDeckActivateSession")
}

/// Delivery seam. `SessionNotifier` is the real implementation; tests substitute a spy.
///
/// The protocol is load-bearing, not ceremony: `UNUserNotificationCenter.current()` traps
/// when the calling binary is not a signed bundle, which is exactly the case inside the
/// unit-test bundle. Nothing reachable from a test may touch it.
protocol Notifying: AnyObject {
    func requestAuthorization()
    func notify(sessionID: UUID, title: String, body: String)
    func withdraw(sessionID: UUID)
}

final class SessionNotifier: Notifying {
    private var center: UNUserNotificationCenter { .current() }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // A denial is not an error: the sidebar icons still convey everything.
        }
    }

    /// The request identifier is the session UUID, so a second prompt for the same
    /// session replaces its banner instead of stacking, and `withdraw` targets exactly one.
    func notify(sessionID: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["sessionID": sessionID.uuidString]
        center.add(
            UNNotificationRequest(
                identifier: sessionID.uuidString, content: content, trigger: nil
            )
        )
    }

    func withdraw(sessionID: UUID) {
        center.removeDeliveredNotifications(withIdentifiers: [sessionID.uuidString])
        center.removePendingNotificationRequests(withIdentifiers: [sessionID.uuidString])
    }
}
```

- [ ] **Step 4: Hook the store up**

In `Sources/FlightDeck/SessionStore.swift`, add near `injectorOverride`:

```swift
    /// Test seam. Production sets this from the convenience init.
    var notifier: Notifying?
    /// Test seam for frontmost-ness; production reads `NSApplication`.
    var appIsActive: () -> Bool = { NSApplication.shared.isActive }

    private var activationObserver: NSObjectProtocol?
```

At the end of `applyRegistry(_:)`, replace `statuses = next` with:

```swift
        let previous = statuses
        statuses = next
        deliverNotifications(previous: previous, current: next)
```

Add:

```swift
    /// One notification decision per session, over the union of both snapshots so a
    /// session that vanished while waiting still gets its banner withdrawn.
    private func deliverNotifications(
        previous: [UUID: SessionStatus], current: [UUID: SessionStatus]
    ) {
        guard let notifier else { return }
        let active = appIsActive()
        for id in Set(previous.keys).union(current.keys) {
            switch SessionNotificationPolicy.action(
                old: previous[id], new: current[id], appActive: active
            ) {
            case .none:
                continue
            case .notify:
                guard let status = current[id], let title = title(of: id) else { continue }
                notifier.notify(sessionID: id, title: title, body: status.tooltip)
            case .withdraw:
                notifier.withdraw(sessionID: id)
            }
        }
    }

    /// Click-to-activate. The window ordering is the AppDelegate's job; this only moves
    /// the selection.
    private func observeActivationRequests() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: .flightDeckActivateSession, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?["sessionID"] else { return }
            let id = (raw as? UUID) ?? (raw as? String).flatMap(UUID.init(uuidString:))
            guard let id else { return }
            MainActor.assumeIsolated { self?.selectSession(id) }
        }
    }
```

Call `observeActivationRequests()` at the end of the designated `init(provider:persistence:)` so tests get it too, and add the matching teardown — without it every store built during the test run stays subscribed and reacts to a later test's activation post:

```swift
    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }
```

In the convenience init, after `startStatusWatching()`:

```swift
        let notifier = SessionNotifier()
        notifier.requestAuthorization()
        self.notifier = notifier
```

Add `import AppKit` at the top of the file if not already present.

- [ ] **Step 5: Wire the AppDelegate**

Replace `Sources/FlightDeck/AppDelegate.swift` with:

```swift
import AppKit
import UserNotifications

/// App-level delegate: notification handling and the last-window-closed policy.
///
/// This type does NOT own libghostty. `GhosttyApp.shared` is a process-wide static that
/// owns itself for the life of the process, which is what keeps the deferred
/// `ghostty_surface_free` in `Ghostty.Surface.deinit` from racing a freed app. The
/// property below is a convenience handle, not ownership.
///
/// (The previous comment here claimed this type owned the libghostty app. Master
/// corrected the same stale claim in `RootView` and `SessionStore` in 6717cc5; this
/// file was missed. Corrected here since we are rewriting the file anyway.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    let ghostty: GhosttyApp? = GhosttyApp.shared

    /// Registered before launch completes, which is required for the delegate to
    /// receive a click that launched or foregrounded the app.
    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Clicking a session notification brings Flight Deck forward and selects that
    /// session. The selection itself is the store's job, reached by notification because
    /// the delegate and the store are constructed independently.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let raw = response.notification.request.content.userInfo["sessionID"] as? String,
              let id = UUID(uuidString: raw)
        else { return }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(
            name: .flightDeckActivateSession, object: nil, userInfo: ["sessionID": id]
        )
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 7: Document the pipeline**

In `docs/ARCHITECTURE.md`, add this section immediately before `## Not yet built (design, not code)`:

```markdown
## Session status pipeline

Sidebar rows show what each Claude session is doing. Two sources feed one map:

```
~/.claude/sessions/<pid>.json ──> SessionStatusWatcher ──┐
  (Claude's own status registry,   (one per app, 500ms    │
   polled; see the design spec)     poll, keyed by         ├──> SessionStore.statuses
                                    sessionId)             │      [UUID: SessionStatus]
<transcript>.jsonl ──────────────> TranscriptWatcher ─────┘             │
  (outstanding Agent tool_use ids,  (one per session)                   v
   cleared at each turn boundary)                              SessionStatusIcon
                                                               SessionNotifier
```

- **`ClaudeStatusFile`** — pure decode of one registry file. Fails closed: an unknown
  `status`, a torn read, or a pid/filename mismatch all yield nil, and the watcher keeps
  its last known value. The registry is undocumented and unversioned, so this is the
  compatibility boundary.
- **`SessionStatusWatcher`** — polls rather than watching vnodes because `claude` rewrites
  the file in place with no create/rename, so a directory watch would never fire.
- **`SessionStore`** — merges registry activity with transcript-derived sub-agent counts,
  drops sessions Flight Deck does not own, and runs `SessionNotificationPolicy` on each
  transition.
- **`SessionNotifier`** — behind the `Notifying` protocol, because
  `UNUserNotificationCenter.current()` traps outside a signed bundle and would take the
  unit-test bundle down.

Full field shapes, the decompiled status derivation, and accepted limitations are in
`docs/superpowers/specs/2026-08-11-session-status-indicators-design.md`.
```

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/SessionNotifier.swift Sources/FlightDeck/SessionStore.swift \
        Sources/FlightDeck/AppDelegate.swift Tests/FlightDeckTests/SessionStatusStoreTests.swift \
        docs/ARCHITECTURE.md
git commit -m "feat: notify when a backgrounded session needs input"
```

---

## Verification

After Task 7:

- [ ] `./scripts/test-unit.sh` — full unit suite green.
- [ ] `./scripts/smoke.sh` — UI suite green (needs GUI session + TCC grant).
- [ ] Manual: launch the app, start a session, confirm the icon goes `busy` while Claude
      works, shows a count while sub-agents run, turns into the orange
      `questionmark.circle.fill` on a permission prompt, and returns to `idle`.
- [ ] Manual: with Flight Deck in the background, trigger a permission prompt and confirm
      the notification appears and clicking it activates that session.
