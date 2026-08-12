# Resumed Conversation Pinning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user runs `/resume` inside a session tab's `claude`, the tab follows the resumed conversation — pinning its UUID, adopting its title, and moving to its project.

**Architecture:** Split `Session.id` (stable tab identity) from `Session.pinnedConversationID` (the attached Claude conversation). Detect the switch by anchoring each tab to a `~/.claude/sessions/<pid>.json` row at launch — when the conversation UUID is still guaranteed unique to us — then following that **pid** forever after. The row's `sessionId` and `cwd` are rewritten in place by `claude`, giving two independent signals: repin and move-project.

**Tech Stack:** Swift 5 (language mode 5.0), SwiftUI + AppKit, XCTest, macOS 14.0 deployment target. No external dependencies.

**Spec:** `docs/superpowers/specs/2026-08-11-resumed-conversation-pinning-design.md`

## Global Constraints

- Every `xcodebuild` / `xcodegen` / `xcrun` invocation needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The scripts export it themselves. **Never run `sudo xcode-select`.**
- Unit tests run with `./scripts/test-unit.sh`. It runs the whole `FlightDeckTests` bundle via `xcrun xctest`; there is no `-only-testing` path. Grep its output for your test's name.
- Swift language mode is **5.0** (`SWIFT_VERSION: "5.0"` in `project.yml`), not Swift 6. Strict concurrency checking is off; `@MainActor` annotations are honored but unchecked crossings do not error.
- `SessionStore`, `TranscriptWatcher`, and `SessionStatusWatcher` are all `@MainActor`. Test classes that touch them are `@MainActor final class … : XCTestCase`.
- Tests use **XCTest**, not swift-testing. Match the existing file style: `import XCTest` + `@testable import FlightDeck`.
- Pure logic lives in its own type with no I/O (`ClaudeSession`, `ClaudeStatusFile`, `SessionNotificationPolicy`, `SessionCreateAction`). Follow that split — a new pure type per new rule, with the I/O in a thin separate caller.
- **This is a shared working copy; other sessions edit it concurrently.** `git add` only the exact paths your task touches. Never `git add -A`, never `git stash`, never revert anything you did not write.
- Do not run `./scripts/smoke.sh`. It steals focus for ~40s and this plan adds no UITest coverage.

---

### Task 1: Registry entries carry `cwd` and `procStart`

`ClaudeStatusFile.Entry` currently drops two fields that are already in the JSON. `cwd` is how a tab learns its project moved; `procStart` is how a tab tells its own process from a recycled pid.

**Files:**
- Modify: `Sources/FlightDeck/ClaudeStatusFile.swift`
- Test: `Tests/FlightDeckTests/ClaudeStatusFileTests.swift`
- Fix fixtures: `Tests/FlightDeckTests/SessionStatusWatcherTests.swift:18-27`

**Interfaces:**
- Consumes: nothing.
- Produces: `ClaudeStatusFile.Entry` with two new stored properties, `let cwd: String` and `let procStart: String`, and an explicit memberwise `init` that defaults both to `""` so existing test call sites keep compiling.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/FlightDeckTests/ClaudeStatusFileTests.swift`, inside the existing class:

```swift
func testDecodeCapturesCwdAndProcStart() {
    let sid = UUID()
    let json = """
    {"pid":42,"sessionId":"\(sid.uuidString.lowercased())","status":"idle",\
    "cwd":"/Users/nate/Projects/flight-deck","procStart":"Mon Aug 10 15:03:38 2026",\
    "startedAt":1786374219307}
    """
    let entry = ClaudeStatusFile.decode(Data(json.utf8), expectedPID: 42)

    XCTAssertEqual(entry?.cwd, "/Users/nate/Projects/flight-deck")
    XCTAssertEqual(entry?.procStart, "Mon Aug 10 15:03:38 2026")
}

/// Fails closed, like every other required field: a row we cannot place in a
/// directory is worse than no row, because the transcript path derived from it
/// would silently point nowhere.
func testDecodeRejectsRowMissingCwd() {
    let sid = UUID()
    let json = """
    {"pid":42,"sessionId":"\(sid.uuidString.lowercased())","status":"idle",\
    "procStart":"Mon Aug 10 15:03:38 2026"}
    """
    XCTAssertNil(ClaudeStatusFile.decode(Data(json.utf8), expectedPID: 42))
}

func testDecodeRejectsRowMissingProcStart() {
    let sid = UUID()
    let json = """
    {"pid":42,"sessionId":"\(sid.uuidString.lowercased())","status":"idle",\
    "cwd":"/Users/nate"}
    """
    XCTAssertNil(ClaudeStatusFile.decode(Data(json.utf8), expectedPID: 42))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile error — `value of type 'ClaudeStatusFile.Entry' has no member 'cwd'`.

- [ ] **Step 3: Add the fields**

In `Sources/FlightDeck/ClaudeStatusFile.swift`, replace the `Entry` struct with:

```swift
    struct Entry: Equatable {
        let pid: pid_t
        let sessionID: UUID
        let activity: SessionActivity
        let waitingFor: String?
        /// Epoch milliseconds. Breaks ties when two files claim one session (crash,
        /// then resume): the newest wins.
        let startedAt: Double
        /// The session's current working directory. `claude` rewrites this in place when
        /// a resume moves the session to another project, so it is the authority on where
        /// the transcript is being written — not the tab's own stored path.
        let cwd: String
        /// Human-readable process start time, e.g. "Mon Aug 10 15:03:38 2026". Paired with
        /// `pid` it identifies one *process*: macOS recycles pids, so a row with a familiar
        /// pid and an unfamiliar `procStart` is a different process, not a resume.
        let procStart: String

        /// `cwd` and `procStart` default to empty purely so existing test call sites that
        /// predate them keep compiling. Production values always come from `decode`, which
        /// requires both.
        init(
            pid: pid_t,
            sessionID: UUID,
            activity: SessionActivity,
            waitingFor: String?,
            startedAt: Double,
            cwd: String = "",
            procStart: String = ""
        ) {
            self.pid = pid
            self.sessionID = sessionID
            self.activity = activity
            self.waitingFor = waitingFor
            self.startedAt = startedAt
            self.cwd = cwd
            self.procStart = procStart
        }
    }
```

Then in `decode`, add both to the guard and the construction:

```swift
    static func decode(_ data: Data, expectedPID: pid_t) -> Entry? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawPID = obj["pid"] as? Int,
              let pid = pid_t(exactly: rawPID), pid == expectedPID,
              let rawSession = obj["sessionId"] as? String,
              let sessionID = UUID(uuidString: rawSession),
              let rawStatus = obj["status"] as? String,
              let activity = SessionActivity(rawValue: rawStatus),
              let cwd = obj["cwd"] as? String,
              let procStart = obj["procStart"] as? String
        else { return nil }

        return Entry(
            pid: expectedPID,
            sessionID: sessionID,
            activity: activity,
            waitingFor: obj["waitingFor"] as? String,
            startedAt: (obj["startedAt"] as? Double) ?? 0,
            cwd: cwd,
            procStart: procStart
        )
    }
```

- [ ] **Step 4: Fix the two existing fixtures that now decode to nil**

`decode` requires both new fields, so every fixture that omits one stops decoding. Two
helpers produce them. Fix the fixtures — do **not** relax the guard.

In `Tests/FlightDeckTests/ClaudeStatusFileTests.swift`, the `json(...)` helper already
sends `"cwd": "/tmp"`; add `procStart` beside it:

```swift
            "procStart": "Mon Aug 10 15:03:38 2026",
```

In `Tests/FlightDeckTests/SessionStatusWatcherTests.swift`, replace the `write` helper —
it sends neither field today:

```swift
    private func write(pid: Int, sid: UUID, status: String,
                       waitingFor: String? = nil, startedAt: Double = 1000,
                       cwd: String = "/tmp",
                       procStart: String = "Mon Aug 10 15:03:38 2026") throws {
        var obj: [String: Any] = [
            "pid": pid, "sessionId": sid.uuidString.lowercased(),
            "status": status, "startedAt": startedAt,
            "cwd": cwd, "procStart": procStart,
        ]
        if let waitingFor { obj["waitingFor"] = waitingFor }
        try JSONSerialization.data(withJSONObject: obj)
            .write(to: dir.appendingPathComponent("\(pid).json"))
    }
```

- [ ] **Step 5: Run the tests**

Run: `./scripts/test-unit.sh`
Expected: PASS, including the three new cases and every pre-existing
`ClaudeStatusFileTests` / `SessionStatusWatcherTests` case.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/ClaudeStatusFile.swift \
        Tests/FlightDeckTests/ClaudeStatusFileTests.swift \
        Tests/FlightDeckTests/SessionStatusWatcherTests.swift
git commit -m "feat: decode cwd and procStart from the session registry"
```

---

### Task 2: Resolve a conversation's title from its transcript

Pure rule plus a thin file reader. Used once per resume to answer "what is this conversation called".

**Files:**
- Create: `Sources/FlightDeck/ConversationTitle.swift`
- Test: `Tests/FlightDeckTests/ConversationTitleTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.sanitizedName(_:) -> String?` (existing).
- Produces:
  - `ConversationTitle.resolve(lines: [String]) -> String?` — pure.
  - `ConversationTitle.resolve(transcriptAt url: URL) -> String?` — reads the file, splits on newlines, delegates.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/ConversationTitleTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ConversationTitleTests: XCTestCase {
    private func userLine(_ text: String, isMeta: Bool = false,
                          isCompactSummary: Bool = false) -> String {
        """
        {"type":"user","isMeta":\(isMeta),"isCompactSummary":\(isCompactSummary),\
        "message":{"content":[{"type":"text","text":"\(text)"}]}}
        """
    }

    func testPrefersTheLastNameRecord() {
        let lines = [
            userLine("first thing I asked"),
            #"{"type":"agent-name","agentName":"early name"}"#,
            #"{"type":"agent-name","agentName":"later name"}"#,
        ]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "later name")
    }

    /// `custom-title` and `agent-name` are both rename records; whichever is last wins.
    func testCustomTitleRecordAlsoCounts() {
        let lines = [
            #"{"type":"agent-name","agentName":"early name"}"#,
            #"{"type":"custom-title","customTitle":"newest name"}"#,
        ]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "newest name")
    }

    /// The unnamed case: this is what `claude`'s own /resume picker shows.
    func testFallsBackToFirstUserMessage() {
        let lines = [userLine("fix the flaky test"), userLine("second message")]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "fix the flaky test")
    }

    func testSkipsMetaAndCompactSummaryMessages() {
        let lines = [
            userLine("injected context", isMeta: true),
            userLine("a summary of earlier work", isCompactSummary: true),
            userLine("the real first prompt"),
        ]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "the real first prompt")
    }

    func testCollapsesNewlinesInTheFirstMessage() {
        let lines = [userLine(#"line one\nline two"#)]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "line one line two")
    }

    func testStringContentIsAcceptedAsWellAsBlocks() {
        let lines = [#"{"type":"user","message":{"content":"plain string content"}}"#]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "plain string content")
    }

    func testEmptyTranscriptResolvesToNil() {
        XCTAssertNil(ConversationTitle.resolve(lines: []))
    }

    func testMalformedLinesAreIgnored() {
        let lines = ["not json at all", "", userLine("still found")]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines), "still found")
    }

    /// Sanitization is shared with every other title path, so the 120-char cap applies.
    func testOverlongFirstMessageIsCapped() {
        let lines = [userLine(String(repeating: "a", count: 400))]
        XCTAssertEqual(ConversationTitle.resolve(lines: lines)?.count, 120)
    }

    func testReadsFromDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("t.jsonl")
        try (userLine("from disk") + "\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(ConversationTitle.resolve(transcriptAt: url), "from disk")
    }

    func testMissingFileResolvesToNil() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).jsonl")
        XCTAssertNil(ConversationTitle.resolve(transcriptAt: url))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile error — `cannot find 'ConversationTitle' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FlightDeck/ConversationTitle.swift`:

```swift
import Foundation

/// What to call a Claude conversation we did not start.
///
/// Mirrors what `claude` itself displays in its `/resume` picker, verified against the
/// 2.1.227 binary: a conversation's own name when it has one, otherwise its first real
/// user message (`cba` → `CIn`). See
/// `docs/superpowers/specs/2026-08-11-resumed-conversation-pinning-design.md` §9.
///
/// Deliberately NOT sourced from the `name` field of `~/.claude/sessions/<pid>.json`.
/// `claude` writes that field and the `sessionId` field through separate hops of the same
/// promise chain, so a poll can observe the newly resumed conversation still carrying the
/// previous one's name.
enum ConversationTitle {
    /// Pure so the record shapes are testable without a filesystem.
    ///
    /// Rename records are not filtered by session id, unlike `ClaudeSession.customTitle`:
    /// the file *is* the conversation, so every rename record in it is this conversation's.
    static func resolve(lines: [String]) -> String? {
        var lastName: String?
        var firstUserText: String?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }

            switch type {
            case "agent-name":
                if let name = obj["agentName"] as? String { lastName = name }
            case "custom-title":
                if let name = obj["customTitle"] as? String { lastName = name }
            case "user":
                guard firstUserText == nil,
                      obj["isMeta"] as? Bool != true,
                      obj["isCompactSummary"] as? Bool != true,
                      let text = userText(obj)
                else { continue }
                firstUserText = text
            default:
                continue
            }
        }

        guard let raw = lastName ?? firstUserText else { return nil }
        // Shares the app's single sanitizer, so the 120-char cap and the control- and
        // shell-metacharacter stripping applied to every other title apply here too. That
        // keeps the stored title byte-identical to what a rename would inject, which is
        // what `SessionStore.applyExternalTitle`'s loop guard compares against.
        return ClaudeSession.sanitizedName(raw.replacingOccurrences(of: "\n", with: " "))
    }

    /// A missing or unreadable file is nil, not an error: it just means we have nothing
    /// better to call the conversation than whatever the tab is already called.
    static func resolve(transcriptAt url: URL) -> String? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return resolve(lines: contents.components(separatedBy: "\n"))
    }

    /// `content` is either a bare string or an array of typed blocks; take the first text.
    private static func userText(_ obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            if let text = block["text"] as? String { return text }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./scripts/test-unit.sh`
Expected: PASS, including the eleven new `ConversationTitleTests` cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ConversationTitle.swift Tests/FlightDeckTests/ConversationTitleTests.swift
git commit -m "feat: resolve a conversation's title from its transcript"
```

---

### Task 3: Split tab identity from conversation identity

`Session.id` currently doubles as the Claude conversation UUID. Give the conversation its own field so it can change without disturbing SwiftUI identity, the surface/watcher dictionaries, or persistence.

**Files:**
- Modify: `Sources/FlightDeck/SessionModel.swift`
- Modify: `Sources/FlightDeck/SessionPersistence.swift:6-17`
- Modify: `Sources/FlightDeck/SessionStore.swift` (`insertSession`, `restore`, `persist`, `applyRegistry`, `startWatching`)
- Test: `Tests/FlightDeckTests/SessionModelTests.swift`, `Tests/FlightDeckTests/SessionPersistenceTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Session.pinnedConversationID: UUID` (defaults to `id`), `Session.workingDirectory` becomes `var`.
  - `SessionSnapshot.Entry.pinnedConversationID: UUID?` (defaults to `nil`), `Entry.workingDirectory` becomes `var`.
  - `SessionStore.startWatching(tabID:conversationID:url:)` replaces `startWatching(_:workingDirectory:)`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/FlightDeckTests/SessionModelTests.swift`:

```swift
func testPinDefaultsToTheTabsOwnID() {
    let session = Session(title: "s", workingDirectory: "/w")
    XCTAssertEqual(session.pinnedConversationID, session.id)
}

func testPinCanDifferFromTheTabID() {
    let conversation = UUID()
    let session = Session(
        title: "s", workingDirectory: "/w", pinnedConversationID: conversation
    )
    XCTAssertNotEqual(session.id, conversation)
    XCTAssertEqual(session.pinnedConversationID, conversation)
}
```

Add to `Tests/FlightDeckTests/SessionPersistenceTests.swift`:

```swift
/// v1 snapshots predate the field. Decoding must not throw, or the first launch after
/// this change wipes every tab.
func testV1SnapshotWithoutPinDecodes() throws {
    let id = UUID()
    let json = """
    {"sessions":[{"id":"\(id.uuidString)","title":"a","workingDirectory":"/w"}],\
    "sessionCounter":1}
    """
    let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))

    XCTAssertEqual(snapshot.sessions.first?.id, id)
    XCTAssertNil(snapshot.sessions.first?.pinnedConversationID)
}

func testRestoreDefaultsAnAbsentPinToTheTabID() {
    let id = UUID()
    let persistence = FakePersistence()
    persistence.stored = SessionSnapshot(
        sessions: [.init(id: id, title: "a", workingDirectory: "/w")],
        selectedSessionID: id,
        sessionCounter: 1
    )
    let store = SessionStore(provider: nil, persistence: persistence)

    XCTAssertTrue(store.restore(directoryExists: allDirsExist))
    XCTAssertEqual(store.repos.first?.sessions.first?.pinnedConversationID, id)
}

func testRestoreRoundTripsAPinnedConversation() {
    let id = UUID()
    let conversation = UUID()
    let persistence = FakePersistence()
    persistence.stored = SessionSnapshot(
        sessions: [.init(
            id: id, title: "a", workingDirectory: "/w", pinnedConversationID: conversation
        )],
        selectedSessionID: id,
        sessionCounter: 1
    )
    let store = SessionStore(provider: nil, persistence: persistence)

    XCTAssertTrue(store.restore(directoryExists: allDirsExist))
    XCTAssertEqual(store.repos.first?.sessions.first?.pinnedConversationID, conversation)
    XCTAssertEqual(persistence.stored?.sessions.first?.pinnedConversationID, conversation)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile error — `extra argument 'pinnedConversationID' in call`.

- [ ] **Step 3: Add the fields**

Replace `Session` in `Sources/FlightDeck/SessionModel.swift`:

```swift
/// A single terminal session. In this foundation a session is just a titled
/// terminal rooted at a working directory; agent/worktree state comes later.
struct Session: Identifiable, Equatable {
    /// The tab's identity, immutable for its whole life. Keys the surface, the transcript
    /// watcher, the status map, the selection, and every notification. Deliberately NOT
    /// the Claude conversation id — see `pinnedConversationID`.
    let id: UUID
    var title: String
    /// The project the tab is filed under. Mutable because a resume can move a session to
    /// another project (`SessionStore.moveSession`).
    var workingDirectory: String
    /// The Claude conversation this tab is currently attached to. Equal to `id` at birth,
    /// because a session Flight Deck starts uses its own tab id as `--session-id`. An
    /// in-session `/resume` repoints it at the resumed conversation.
    var pinnedConversationID: UUID

    init(
        id: UUID = UUID(),
        title: String,
        workingDirectory: String,
        pinnedConversationID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.workingDirectory = workingDirectory
        self.pinnedConversationID = pinnedConversationID ?? id
    }
}
```

Replace `SessionSnapshot.Entry` in `Sources/FlightDeck/SessionPersistence.swift`:

```swift
    struct Entry: Codable, Equatable {
        let id: UUID
        var title: String
        var workingDirectory: String
        /// Absent in v1 snapshots and in tabs that were never resumed; absent means
        /// "same as `id`". Optional is load-bearing: synthesized `Codable` decodes an
        /// optional with `decodeIfPresent`, so every existing snapshot still decodes and
        /// the defaults key stays `sessions.snapshot.v1`. A non-optional field would throw
        /// and wipe every tab on the first launch after this change.
        var pinnedConversationID: UUID?

        init(
            id: UUID,
            title: String,
            workingDirectory: String,
            pinnedConversationID: UUID? = nil
        ) {
            self.id = id
            self.title = title
            self.workingDirectory = workingDirectory
            self.pinnedConversationID = pinnedConversationID
        }
    }
```

- [ ] **Step 4: Route the Claude-facing call sites through the pin**

In `Sources/FlightDeck/SessionStore.swift`:

Replace the tail of `insertSession` (currently `startWatching(session, workingDirectory: url.path)`) with:

```swift
        startWatching(
            tabID: session.id,
            conversationID: session.pinnedConversationID,
            url: ClaudeSession.transcriptURL(
                sessionID: session.pinnedConversationID,
                workingDirectory: url.path,
                projectsRoot: projectsRoot
            )
        )
        return session
```

Replace `startWatching` in the Helpers section:

```swift
    /// `tabID` keys our own state; `conversationID` is what the transcript is named after
    /// and what its rename records are stamped with. They differ after a resume.
    private func startWatching(tabID: UUID, conversationID: UUID, url: URL) {
        let watcher = TranscriptWatcher(
            sessionID: conversationID,
            url: url
        ) { [weak self] title in
            self?.applyExternalTitle(tabID, title)
        } onSubagentCount: { [weak self] count in
            self?.applySubagentCount(tabID, count)
        }
        watcher.start()
        watchers[tabID] = watcher
    }
```

In `restore`, replace the `Session(...)` construction and the `initialInput:` argument:

```swift
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
                    sessionID: conversationID, title: entry.title
                )
            )
        }
```

In `persist`, carry the pin:

```swift
                sessions: repos.flatMap(\.sessions).map {
                    .init(
                        id: $0.id,
                        title: $0.title,
                        workingDirectory: $0.workingDirectory,
                        pinnedConversationID: $0.pinnedConversationID
                    )
                },
```

In `applyRegistry`, join on the pin rather than the tab id — an interim step; Task 5 replaces this join entirely:

```swift
                guard let entry = entries[session.pinnedConversationID] else { continue }
```

- [ ] **Step 5: Run the tests**

Run: `./scripts/test-unit.sh`
Expected: PASS. Every pre-existing test should still pass untouched — at birth `pinnedConversationID == id`, so nothing observable changes yet.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionModel.swift Sources/FlightDeck/SessionPersistence.swift \
        Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionModelTests.swift \
        Tests/FlightDeckTests/SessionPersistenceTests.swift
git commit -m "feat: give a session its own pinned conversation id"
```

---

### Task 4: The pin reconciliation rule

Pure. Given a tab's current pin, its project, its anchor, and the registry keyed by pid, decide the tab's new anchor, conversation, and project.

**Files:**
- Create: `Sources/FlightDeck/ConversationPin.swift`
- Test: `Tests/FlightDeckTests/ConversationPinTests.swift`

**Interfaces:**
- Consumes: `ClaudeStatusFile.Entry` with `cwd`/`procStart` (Task 1), `Session.pinnedConversationID` (Task 3).
- Produces:
  - `ConversationPin.Anchor` — `init(pid: pid_t, procStart: String)`, `Equatable`.
  - `ConversationPin.Resolution` — `var anchor: Anchor?`, `var conversationID: UUID`, `var workingDirectory: String`, `Equatable`.
  - `ConversationPin.resolve(conversationID:workingDirectory:anchor:rows:) -> Resolution`.
  - `ConversationPin.conflicted(_ sessions: [Session]) -> Set<UUID>`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/ConversationPinTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ConversationPinTests: XCTestCase {
    private func row(
        pid: pid_t, session: UUID, cwd: String = "/w",
        procStart: String = "start-a", startedAt: Double = 1
    ) -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: session, activity: .idle, waitingFor: nil,
              startedAt: startedAt, cwd: cwd, procStart: procStart)
    }

    func testAnchorsToTheRowCarryingOurConversation() {
        let conversation = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: conversation,
            workingDirectory: "/w",
            anchor: nil,
            rows: [7: row(pid: 7, session: conversation)]
        )

        XCTAssertEqual(resolution.anchor, .init(pid: 7, procStart: "start-a"))
        XCTAssertEqual(resolution.conversationID, conversation)
    }

    func testWithoutAMatchingRowThereIsNoAnchor() {
        let resolution = ConversationPin.resolve(
            conversationID: UUID(),
            workingDirectory: "/w",
            anchor: nil,
            rows: [7: row(pid: 7, session: UUID())]
        )

        XCTAssertNil(resolution.anchor)
    }

    /// The whole feature: same process, new conversation.
    func testAnchoredRowChangingConversationIsARepin() {
        let old = UUID()
        let new = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: old,
            workingDirectory: "/w",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: new)]
        )

        XCTAssertEqual(resolution.conversationID, new)
        XCTAssertEqual(resolution.anchor, .init(pid: 7, procStart: "start-a"))
    }

    /// macOS recycles pids. A familiar pid with an unfamiliar start time is somebody
    /// else's process, and adopting its conversation would be a silent hijack.
    func testRecycledPidLosesTheAnchorRatherThanRepinning() {
        let old = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: old,
            workingDirectory: "/w",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: UUID(), procStart: "start-b")]
        )

        XCTAssertNil(resolution.anchor)
        XCTAssertEqual(resolution.conversationID, old)
    }

    func testVanishedRowLosesTheAnchorAndKeepsThePin() {
        let old = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: old,
            workingDirectory: "/w",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [:]
        )

        XCTAssertNil(resolution.anchor)
        XCTAssertEqual(resolution.conversationID, old)
        XCTAssertEqual(resolution.workingDirectory, "/w")
    }

    func testCwdChangeIsReportedIndependentlyOfTheConversation() {
        let conversation = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: conversation,
            workingDirectory: "/old",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: conversation, cwd: "/new")]
        )

        XCTAssertEqual(resolution.conversationID, conversation)
        XCTAssertEqual(resolution.workingDirectory, "/new")
    }

    func testRepinAndMoveCanHappenTogether() {
        let new = UUID()
        let resolution = ConversationPin.resolve(
            conversationID: UUID(),
            workingDirectory: "/old",
            anchor: .init(pid: 7, procStart: "start-a"),
            rows: [7: row(pid: 7, session: new, cwd: "/new")]
        )

        XCTAssertEqual(resolution.conversationID, new)
        XCTAssertEqual(resolution.workingDirectory, "/new")
    }

    /// Two processes can legitimately hold one conversation. Anchoring must be
    /// deterministic rather than dictionary-order dependent, and should prefer the
    /// newest process.
    func testAnchoringPrefersTheNewestProcessDeterministically() {
        let conversation = UUID()
        let rows: [pid_t: ClaudeStatusFile.Entry] = [
            7: row(pid: 7, session: conversation, procStart: "old", startedAt: 1),
            9: row(pid: 9, session: conversation, procStart: "new", startedAt: 2),
        ]

        for _ in 0..<20 {
            let resolution = ConversationPin.resolve(
                conversationID: conversation, workingDirectory: "/w", anchor: nil, rows: rows
            )
            XCTAssertEqual(resolution.anchor, .init(pid: 9, procStart: "new"))
        }
    }

    func testConflictedFlagsEveryTabSharingAConversation() {
        let shared = UUID()
        let a = Session(title: "a", workingDirectory: "/w", pinnedConversationID: shared)
        let b = Session(title: "b", workingDirectory: "/w", pinnedConversationID: shared)
        let c = Session(title: "c", workingDirectory: "/w")

        XCTAssertEqual(ConversationPin.conflicted([a, b, c]), [a.id, b.id])
    }

    func testConflictedIsEmptyWhenEveryPinIsDistinct() {
        let a = Session(title: "a", workingDirectory: "/w")
        let b = Session(title: "b", workingDirectory: "/w")

        XCTAssertTrue(ConversationPin.conflicted([a, b]).isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile error — `cannot find 'ConversationPin' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FlightDeck/ConversationPin.swift`:

```swift
import Foundation

/// Which Claude conversation a tab is attached to, and how that is worked out from the
/// `~/.claude/sessions/<pid>.json` registry.
///
/// Pure and stateless so every rule is unit-testable; `SessionStore` applies the results.
/// See `docs/superpowers/specs/2026-08-11-resumed-conversation-pinning-design.md` §5.
enum ConversationPin {
    /// One `claude` process. `pid` alone is not an identity — macOS recycles pids — so it
    /// is always paired with the process start time the registry reports.
    struct Anchor: Equatable {
        let pid: pid_t
        let procStart: String
    }

    /// What a tab should look like after reconciling against the registry. Each field is
    /// independent: a resume can change the conversation, the project, or both.
    struct Resolution: Equatable {
        /// nil means the anchor was lost — no live process is ours.
        var anchor: Anchor?
        var conversationID: UUID
        var workingDirectory: String
    }

    /// Anchor once by conversation, then follow the pid forever.
    ///
    /// The ordering is what makes this sound. A tab can only be anchored while its
    /// conversation id is one Flight Deck generated and passed as `--session-id`, so at
    /// that moment at most one row can plausibly be ours. Every later lookup is by pid,
    /// which is immune to the conversation changing underneath us — and the conversation
    /// changing underneath us is precisely the event we are trying to detect.
    static func resolve(
        conversationID: UUID,
        workingDirectory: String,
        anchor: Anchor?,
        rows: [pid_t: ClaudeStatusFile.Entry]
    ) -> Resolution {
        let unchanged = Resolution(
            anchor: nil, conversationID: conversationID, workingDirectory: workingDirectory
        )

        if let anchor {
            // A row under our pid whose process start time differs is a *different*
            // process that inherited a recycled pid, not our session resuming.
            guard let row = rows[anchor.pid], row.procStart == anchor.procStart else {
                return unchanged
            }
            return Resolution(
                anchor: anchor,
                conversationID: row.sessionID,
                workingDirectory: row.cwd.isEmpty ? workingDirectory : row.cwd
            )
        }

        // Newest process wins, with pid as a tiebreak purely so the choice is
        // deterministic: `rows.values` has no defined order, and two processes really can
        // hold one conversation once resumes are in play.
        let candidates = rows.values.filter { $0.sessionID == conversationID }
        guard let row = candidates.max(by: { lhs, rhs in
            (lhs.startedAt, lhs.pid) < (rhs.startedAt, rhs.pid)
        }) else { return unchanged }

        return Resolution(
            anchor: Anchor(pid: row.pid, procStart: row.procStart),
            conversationID: row.sessionID,
            workingDirectory: row.cwd.isEmpty ? workingDirectory : row.cwd
        )
    }

    /// Tabs sharing a conversation with another tab, as tab ids.
    ///
    /// Derived from the whole list on every read rather than recorded at resume time, so
    /// it also covers a restored snapshot that already holds a duplicate and two tabs that
    /// collide in either order.
    static func conflicted(_ sessions: [Session]) -> Set<UUID> {
        let groups = Dictionary(grouping: sessions, by: \.pinnedConversationID)
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./scripts/test-unit.sh`
Expected: PASS, including the ten new `ConversationPinTests` cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ConversationPin.swift Tests/FlightDeckTests/ConversationPinTests.swift
git commit -m "feat: add the pin reconciliation rule"
```

---

### Task 5: Join the registry by pid instead of by conversation

The watcher currently collapses rows by `sessionId`, which both discards the pid→row mapping the anchor needs and hides a genuinely live second process on a shared conversation. Move the dedupe out and let the store anchor.

**Files:**
- Modify: `Sources/FlightDeck/SessionStatusWatcher.swift:28,100-107`
- Modify: `Sources/FlightDeck/SessionStore.swift` (`applyRegistry`, plus a new `anchors` property)
- Test: `Tests/FlightDeckTests/SessionStatusWatcherTests.swift`, `Tests/FlightDeckTests/SessionStatusStoreTests.swift`

**Interfaces:**
- Consumes: `ConversationPin.resolve` (Task 4), `ClaudeStatusFile.Entry.procStart`/`.cwd` (Task 1).
- Produces:
  - `SessionStatusWatcher.init(root:isAlive:onChange:)` where `onChange: ([pid_t: ClaudeStatusFile.Entry]) -> Void`.
  - `SessionStore.applyRegistry(_ rows: [pid_t: ClaudeStatusFile.Entry])`.

- [ ] **Step 1: Write the failing tests**

In `Tests/FlightDeckTests/SessionStatusStoreTests.swift`, replace the `entry` helper and add two cases. The helper now needs a pid and must be keyed by pid at the call site:

```swift
    private func entry(_ sid: UUID, _ activity: SessionActivity,
                       waitingFor: String? = nil, pid: pid_t = 1,
                       cwd: String = "/w", procStart: String = "start-a")
        -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: sid, activity: activity, waitingFor: waitingFor,
              startedAt: 1, cwd: cwd, procStart: procStart)
    }
```

Every existing call of the form `store.applyRegistry([session.id: entry(session.id, .busy)])` becomes `store.applyRegistry([1: entry(session.id, .busy)])`. Apply that substitution to all of them, including the `[stranger: entry(stranger, .busy)]` case, which becomes `[1: entry(stranger, .busy)]`.

Then add:

```swift
/// Two live `claude` processes on one conversation are both real. The old
/// dedupe-by-sessionId in the watcher would have hidden one of them.
func testTwoProcessesOnOneConversationBothSurviveTheJoin() {
    let store = makeStore()
    let first = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))
    let second = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

    store.applyRegistry([
        1: entry(first.pinnedConversationID, .busy, pid: 1),
        2: entry(second.pinnedConversationID, .waiting, pid: 2, procStart: "start-b"),
    ])

    XCTAssertEqual(store.status(for: first.id)?.activity, .busy)
    XCTAssertEqual(store.status(for: second.id)?.activity, .waiting)
}

/// Once anchored, the tab follows its pid. The conversation id in the row is no longer
/// consulted for the status join, which is what lets a resume keep the icon alive.
func testStatusSurvivesTheConversationChangingUnderTheSamePid() {
    let store = makeStore()
    let session = store.newSession(in: URL(fileURLWithPath: NSTemporaryDirectory()))

    store.applyRegistry([1: entry(session.pinnedConversationID, .busy, pid: 1)])
    store.applyRegistry([1: entry(UUID(), .waiting, pid: 1)])

    XCTAssertEqual(store.status(for: session.id)?.activity, .waiting)
}
```

In `Tests/FlightDeckTests/SessionStatusWatcherTests.swift`, the `watcher(alive:onChange:)` helper's closure type changes:

```swift
    private func watcher(
        alive: @escaping (pid_t) -> Bool = { _ in true },
        onChange: @escaping ([pid_t: ClaudeStatusFile.Entry]) -> Void
    ) -> SessionStatusWatcher {
        SessionStatusWatcher(root: dir, isAlive: alive, onChange: onChange)
    }
```

Every `var seen: [UUID: ClaudeStatusFile.Entry] = [:]` in that file becomes
`var seen: [pid_t: ClaudeStatusFile.Entry] = [:]`, and every `seen[sid]` lookup becomes
`seen[<that test's pid>]` — e.g. in `testMapsFileToSessionID`, which writes `pid: 100`,
`seen[sid]?.activity` becomes `seen[100]?.activity`. Then add:

```swift
func testReportsRowsKeyedByPID() throws {
    let sid = UUID()
    try write(pid: 4242, sid: sid, status: "busy")

    var reported: [pid_t: ClaudeStatusFile.Entry] = [:]
    watcher { reported = $0 }.drain()

    XCTAssertEqual(reported[4242]?.sessionID, sid)
}

/// Two processes on one conversation used to collapse into one row, keeping only the
/// newest `startedAt`. Both are real and both must survive.
func testTwoProcessesOnOneConversationAreBothReported() throws {
    let sid = UUID()
    try write(pid: 100, sid: sid, status: "busy", startedAt: 1)
    try write(pid: 200, sid: sid, status: "waiting", startedAt: 2)

    var reported: [pid_t: ClaudeStatusFile.Entry] = [:]
    watcher { reported = $0 }.drain()

    XCTAssertEqual(reported.count, 2)
    XCTAssertEqual(reported[100]?.activity, .busy)
    XCTAssertEqual(reported[200]?.activity, .waiting)
}
```

If the file has a test asserting the old newest-`startedAt` collapse, delete it — that behaviour is being removed on purpose, and `testTwoProcessesOnOneConversationAreBothReported` replaces it.

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile errors on the `applyRegistry` and `onChange` types.

- [ ] **Step 3: Make the watcher emit pid-keyed rows**

In `Sources/FlightDeck/SessionStatusWatcher.swift`, change the stored closure's type:

```swift
    private let onChange: ([pid_t: ClaudeStatusFile.Entry]) -> Void
```

and the initializer parameter to match:

```swift
        onChange: @escaping ([pid_t: ClaudeStatusFile.Entry]) -> Void
```

Replace the by-session collapse at the end of `drain()`:

```swift
        // Keyed by pid, not by session: a tab follows its *process*, and two live
        // processes can legitimately hold one conversation once resumes are in play.
        // Collapsing by session id here would hide one of them and would throw away the
        // mapping `ConversationPin` anchors on.
        var byPID: [pid_t: ClaudeStatusFile.Entry] = [:]
        for entry in live.values { byPID[entry.pid] = entry }
        onChange(byPID)
```

- [ ] **Step 4: Anchor in the store**

In `Sources/FlightDeck/SessionStore.swift`, add next to `subagentCounts`:

```swift
    /// Which process each tab is following, keyed by tab id. Established the first time a
    /// registry row carries the tab's conversation, and thereafter the only thing consulted
    /// — see `ConversationPin.resolve`.
    private var anchors: [UUID: ConversationPin.Anchor] = [:]
```

Replace `applyRegistry` entirely:

```swift
    /// Rebuilds `statuses` from a registry scan and keeps each tab's anchor current.
    /// Entries for processes Flight Deck does not own are dropped: the registry lists
    /// every `claude` on the machine.
    func applyRegistry(_ rows: [pid_t: ClaudeStatusFile.Entry]) {
        // Resolve against a snapshot of the list before touching anything. Later tasks
        // apply repins and project moves here, and those mutate `repos` — iterating it
        // while it changes would resolve some tabs against a stale view.
        let resolutions: [(tab: UUID, resolution: ConversationPin.Resolution)] =
            repos.flatMap(\.sessions).map { session in
                (session.id, ConversationPin.resolve(
                    conversationID: session.pinnedConversationID,
                    workingDirectory: session.workingDirectory,
                    anchor: anchors[session.id],
                    rows: rows
                ))
            }
        for (tab, resolution) in resolutions {
            anchors[tab] = resolution.anchor
        }

        var next: [UUID: SessionStatus] = [:]
        for session in repos.flatMap(\.sessions) {
            guard let anchor = anchors[session.id], let entry = rows[anchor.pid] else {
                continue
            }
            next[session.id] = SessionStatus(
                activity: entry.activity,
                waitingFor: entry.waitingFor,
                subagentCount: subagentCounts[session.id] ?? 0
            )
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
        let previous = statuses
        statuses = next
        deliverNotifications(previous: previous, current: next)
    }
```

Also drop the anchor in `closeSession`, alongside the other per-tab teardown:

```swift
        anchors.removeValue(forKey: id)
```

- [ ] **Step 5: Run the tests**

Run: `./scripts/test-unit.sh`
Expected: PASS, including `testStatusSurvivesTheConversationChangingUnderTheSamePid` — which is the pre-existing bug this task fixes.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStatusWatcher.swift Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/SessionStatusWatcherTests.swift \
        Tests/FlightDeckTests/SessionStatusStoreTests.swift
git commit -m "fix: follow a session's process rather than its conversation id"
```

---

### Task 6: Repin the tab when its process changes conversation

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`applyRegistry`, new `repin`, new `titleResolver` seam)
- Test: `Tests/FlightDeckTests/ConversationRepinTests.swift` (create)

**Interfaces:**
- Consumes: `ConversationTitle.resolve(transcriptAt:)` (Task 2), `ConversationPin.Resolution` (Task 4), `applyRegistry` (Task 5).
- Produces:
  - `SessionStore.titleResolver: @MainActor (URL, @escaping @MainActor (String?) -> Void) -> Void` — test seam.
  - `SessionStore.pinnedConversationID(of:) -> UUID?` — read accessor for tests and the sidebar.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/ConversationRepinTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ConversationRepinTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        // Synchronous stand-in for the background transcript read, so tests need no
        // expectations — same rationale as `TranscriptWatcher.drain()` being callable.
        store.titleResolver = { _, done in done(nil) }
        return store
    }

    private func row(_ sid: UUID, pid: pid_t = 1, cwd: String = "/w",
                     procStart: String = "start-a") -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: sid, activity: .busy, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: procStart)
    }

    private var tmp: URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }

    func testResumeMovesThePinButNotTheTabID() {
        let store = makeStore()
        let session = store.newSession(in: tmp)
        let resumed = UUID()

        store.applyRegistry([1: row(session.pinnedConversationID)])   // anchor
        store.applyRegistry([1: row(resumed)])                        // /resume

        XCTAssertEqual(store.pinnedConversationID(of: session.id), resumed)
        XCTAssertEqual(store.repos.first?.sessions.first?.id, session.id)
    }

    func testResumeAdoptsTheResumedConversationsTitle() {
        let store = makeStore()
        store.titleResolver = { _, done in done("the resumed conversation") }
        let session = store.newSession(in: tmp)
        let resumed = UUID()

        store.applyRegistry([1: row(session.pinnedConversationID)])
        store.applyRegistry([1: row(resumed)])

        XCTAssertEqual(store.title(of: session.id), "the resumed conversation")
    }

    /// An unreadable or nameless transcript leaves the tab called what it was called.
    func testUnresolvableTitleLeavesTheTitleAlone() {
        let store = makeStore()
        let session = store.newSession(in: tmp)
        let before = store.title(of: session.id)

        store.applyRegistry([1: row(session.pinnedConversationID)])
        store.applyRegistry([1: row(UUID())])

        XCTAssertEqual(store.title(of: session.id), before)
    }

    /// The old conversation's outstanding Agent calls will never be answered in the new
    /// transcript, so a stale count would stick forever.
    func testResumeZeroesTheSubagentCount() {
        let store = makeStore()
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: row(session.pinnedConversationID)])
        store.applySubagentCount(session.id, 3)
        store.applyRegistry([1: row(UUID())])

        XCTAssertEqual(store.status(for: session.id)?.subagentCount, 0)
    }

    /// The banner refers to a prompt in a conversation the tab has left.
    func testResumeWithdrawsAPendingNotification() {
        let store = makeStore()
        let spy = SpyNotifier()
        store.notifier = spy
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: row(session.pinnedConversationID)])
        store.applyRegistry([1: row(UUID())])

        XCTAssertTrue(spy.withdrawn.contains(session.id))
    }

    func testResumeIsPersisted() {
        let persistence = FakePersistence()
        let store = SessionStore(provider: nil, persistence: persistence)
        store.titleResolver = { _, done in done(nil) }
        let session = store.newSession(in: tmp)
        let resumed = UUID()

        store.applyRegistry([1: row(session.pinnedConversationID)])
        store.applyRegistry([1: row(resumed)])

        XCTAssertEqual(
            persistence.stored?.sessions.first?.pinnedConversationID, resumed
        )
    }

    /// A steady state must not churn: repinning on every tick would restart the watcher
    /// 120 times a minute.
    func testUnchangedConversationDoesNotRepin() {
        let store = makeStore()
        var resolverCalls = 0
        store.titleResolver = { _, done in resolverCalls += 1; done(nil) }
        let session = store.newSession(in: tmp)

        store.applyRegistry([1: row(session.pinnedConversationID)])
        store.applyRegistry([1: row(session.pinnedConversationID)])
        store.applyRegistry([1: row(session.pinnedConversationID)])

        XCTAssertEqual(resolverCalls, 0)
    }

    final class FakePersistence: SessionPersisting {
        var stored: SessionSnapshot?
        func load() -> SessionSnapshot? { stored }
        func save(_ snapshot: SessionSnapshot) { stored = snapshot }
    }

    final class SpyNotifier: Notifying {
        var withdrawn: [UUID] = []
        func requestAuthorization() {}
        func notify(sessionID: UUID, title: String, body: String) {}
        func withdraw(sessionID: UUID) { withdrawn.append(sessionID) }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile error — `value of type 'SessionStore' has no member 'titleResolver'`.

- [ ] **Step 3: Add the seam and the read accessor**

In `Sources/FlightDeck/SessionStore.swift`, next to `injectorOverride`:

```swift
    /// Test seam. The default reads the resumed conversation's transcript off the main
    /// actor and calls back on it; tests substitute a synchronous closure so they need no
    /// expectations. The read is one-shot per resume and can touch a multi-megabyte file,
    /// which is why it does not run inline.
    var titleResolver: @MainActor (URL, @escaping @MainActor (String?) -> Void) -> Void = {
        url, done in
        Task.detached(priority: .userInitiated) {
            let title = ConversationTitle.resolve(transcriptAt: url)
            await done(title)
        }
    }

    func pinnedConversationID(of id: UUID) -> UUID? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session].pinnedConversationID
    }
```

- [ ] **Step 4: Implement `repin` and call it from `applyRegistry`**

Add to `Sources/FlightDeck/SessionStore.swift`:

```swift
    /// The tab's `claude` switched conversations in place (an in-session `/resume`).
    ///
    /// Step order is load-bearing at the end: the title is resolved *before* the new
    /// watcher starts. `TranscriptWatcher` seeds its offset to the file's current size on
    /// its first look, so it will not replay history — but if it were started first, an
    /// old rename record could still land before the resolved title and overwrite it.
    private func repin(
        _ tabID: UUID, to conversationID: UUID, transcriptDirectory: String
    ) {
        guard let at = locate(tabID) else { return }

        // Refers to a prompt in a conversation this tab has left.
        notifier?.withdraw(sessionID: tabID)

        repos[at.repo].sessions[at.session].pinnedConversationID = conversationID

        // The old conversation's outstanding Agent ids can never be answered in the new
        // transcript, so the count would otherwise stick at its last value forever.
        // Only the backing count is reset, not `statuses`: the sole caller is
        // `applyRegistry`, which rebuilds `statuses` from these counts immediately after
        // and diffs the result against the pre-call snapshot to decide notifications.
        // Editing `statuses` here would corrupt that "before" picture.
        subagentCounts[tabID] = 0

        watchers[tabID]?.stop()
        watchers.removeValue(forKey: tabID)

        // Directory comes from the registry row, not the tab: a resumed conversation
        // carries its own project path, and the row is authoritative about where `claude`
        // is actually writing.
        let url = ClaudeSession.transcriptURL(
            sessionID: conversationID,
            workingDirectory: transcriptDirectory,
            projectsRoot: projectsRoot
        )
        titleResolver(url) { [weak self] title in
            guard let self else { return }
            if let title { self.applyExternalTitle(tabID, title) }
            self.startWatching(tabID: tabID, conversationID: conversationID, url: url)
        }

        persist()
    }
```

In `applyRegistry`, replace the anchor-only loop with one that also applies the repin:

```swift
        for (tab, resolution) in resolutions {
            anchors[tab] = resolution.anchor
            if let session = session(for: tab),
               resolution.conversationID != session.pinnedConversationID {
                repin(
                    tab,
                    to: resolution.conversationID,
                    transcriptDirectory: resolution.workingDirectory
                )
            }
        }
```

Add the lookup helper next to `locate`:

```swift
    private func session(for id: UUID) -> Session? {
        guard let at = locate(id) else { return nil }
        return repos[at.repo].sessions[at.session]
    }
```

- [ ] **Step 5: Run the tests**

Run: `./scripts/test-unit.sh`
Expected: PASS, including all seven `ConversationRepinTests` cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/ConversationRepinTests.swift
git commit -m "feat: repin a tab when its process resumes another conversation"
```

---

### Task 7: Move the tab to the resumed conversation's project

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (new `moveSession`, `applyRegistry`)
- Test: `Tests/FlightDeckTests/SessionProjectMoveTests.swift` (create)

**Interfaces:**
- Consumes: `ConversationPin.Resolution.workingDirectory` (Task 4), `applyRegistry` (Task 5).
- Produces: `SessionStore.moveSession(_ id: UUID, toProjectAt url: URL)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/SessionProjectMoveTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SessionProjectMoveTests: XCTestCase {
    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.titleResolver = { _, done in done(nil) }
        return store
    }

    private func row(_ sid: UUID, pid: pid_t = 1, cwd: String,
                     procStart: String = "start-a") -> ClaudeStatusFile.Entry {
        .init(pid: pid, sessionID: sid, activity: .busy, waitingFor: nil,
              startedAt: 1, cwd: cwd, procStart: procStart)
    }

    func testMoveRelocatesTheSessionToAnExistingProject() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        _ = store.newSession(in: URL(fileURLWithPath: "/b", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/b", isDirectory: true))

        let b = store.repos.first { $0.url.path == "/b" }
        XCTAssertEqual(b?.sessions.map(\.id).contains(a.id), true)
        XCTAssertEqual(store.repos.count, 2)
    }

    func testMoveCreatesTheDestinationProjectWhenAbsent() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        XCTAssertEqual(store.repos.count, 2)
        XCTAssertEqual(
            store.repos.first { $0.url.path == "/new" }?.sessions.map(\.id), [a.id]
        )
    }

    /// A project with no sessions is a legitimate sidebar state. Unlike `closeSession`,
    /// moving out does not prune the source.
    func testMoveLeavesAnEmptiedSourceProjectStanding() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        let source = store.repos.first { $0.url.path == "/a" }
        XCTAssertNotNil(source)
        XCTAssertTrue(source!.sessions.isEmpty)
    }

    func testMoveUpdatesTheSessionsWorkingDirectory() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        XCTAssertEqual(
            store.repos.flatMap(\.sessions).first { $0.id == a.id }?.workingDirectory, "/new"
        )
    }

    func testMoveKeepsTheSelection() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/new", isDirectory: true))

        XCTAssertEqual(store.selectedSessionID, a.id)
    }

    func testMoveToTheSameProjectIsANoOp() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/a", isDirectory: true))

        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos.first?.sessions.map(\.id), [a.id])
    }

    /// The registry drives it: a resume that changes cwd moves the tab.
    func testRegistryCwdChangeMovesTheTab() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/moved")])

        XCTAssertEqual(
            store.repos.first { $0.url.path == "/moved" }?.sessions.map(\.id), [a.id]
        )
    }

    func testRegistryCanRepinAndMoveInOneTick() {
        let store = makeStore()
        let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
        let resumed = UUID()

        store.applyRegistry([1: row(a.pinnedConversationID, cwd: "/a")])
        store.applyRegistry([1: row(resumed, cwd: "/moved")])

        XCTAssertEqual(store.pinnedConversationID(of: a.id), resumed)
        XCTAssertEqual(
            store.repos.first { $0.url.path == "/moved" }?.sessions.map(\.id), [a.id]
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile error — `value of type 'SessionStore' has no member 'moveSession'`.

- [ ] **Step 3: Implement `moveSession`**

Add to `Sources/FlightDeck/SessionStore.swift`:

```swift
    /// Files a session under a different project, creating that project if it is new.
    ///
    /// Unlike `closeSession`, this does **not** prune a source project it empties: a
    /// project with no sessions is a legitimate sidebar state. (An empty project does not
    /// currently survive a relaunch, because `SessionSnapshot` stores only sessions and
    /// rebuilds `repos` from their `workingDirectory` — known, deferred.)
    ///
    /// The tab id does not change, so `selectedSessionID` needs no fixing up and SwiftUI
    /// animates the same row from one section to the other rather than recreating it.
    func moveSession(_ id: UUID, toProjectAt url: URL) {
        guard let at = locate(id) else { return }
        let target = url.standardizedFileURL
        guard repos[at.repo].url.standardizedFileURL.path != target.path else { return }

        var session = repos[at.repo].sessions.remove(at: at.session)
        session.workingDirectory = target.path

        // Resolved after the removal so the index cannot be stale. Removing a *session*
        // never removes a repo, so `at.repo` stays valid either way.
        let destination: Int
        if let existing = indexOfRepo(for: target) {
            destination = existing
        } else {
            repos.append(Repo(url: target))
            destination = repos.count - 1
        }
        repos[destination].sessions.append(session)

        persist()
    }
```

- [ ] **Step 4: Drive it from the registry**

In `applyRegistry`, extend the apply loop so a cwd change moves the tab. Replace the loop body from Task 6 with:

```swift
        for (tab, resolution) in resolutions {
            anchors[tab] = resolution.anchor
            guard let session = session(for: tab) else { continue }
            if resolution.conversationID != session.pinnedConversationID {
                repin(
                    tab,
                    to: resolution.conversationID,
                    transcriptDirectory: resolution.workingDirectory
                )
            }
            if !resolution.workingDirectory.isEmpty,
               resolution.workingDirectory != session.workingDirectory {
                moveSession(
                    tab,
                    toProjectAt: URL(
                        fileURLWithPath: resolution.workingDirectory, isDirectory: true
                    )
                )
            }
        }
```

- [ ] **Step 5: Run the tests**

Run: `./scripts/test-unit.sh`
Expected: PASS, including all eight `SessionProjectMoveTests` cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionProjectMoveTests.swift
git commit -m "feat: move a tab to the project its conversation resumed into"
```

---

### Task 8: Flag tabs that share a conversation

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (computed `conflictedSessionIDs`)
- Modify: `Sources/FlightDeck/SessionSidebar.swift:5-75,125-135`
- Test: `Tests/FlightDeckTests/ConversationRepinTests.swift` (two cases appended)

**Interfaces:**
- Consumes: `ConversationPin.conflicted(_:)` (Task 4).
- Produces: `SessionStore.conflictedSessionIDs: Set<UUID>`; `SessionRow` gains an `isConflicted: Bool` parameter.

- [ ] **Step 1: Write the failing test**

Add to `Tests/FlightDeckTests/ConversationRepinTests.swift`:

```swift
func testTwoTabsResumedOntoOneConversationAreBothFlagged() {
    let store = makeStore()
    let first = store.newSession(in: tmp)
    let second = store.newSession(in: tmp)
    let shared = UUID()

    store.applyRegistry([
        1: row(first.pinnedConversationID, pid: 1),
        2: row(second.pinnedConversationID, pid: 2, procStart: "start-b"),
    ])
    store.applyRegistry([
        1: row(shared, pid: 1),
        2: row(shared, pid: 2, procStart: "start-b"),
    ])

    XCTAssertEqual(store.conflictedSessionIDs, [first.id, second.id])
}

func testDistinctConversationsAreNotFlagged() {
    let store = makeStore()
    _ = store.newSession(in: tmp)
    _ = store.newSession(in: tmp)

    XCTAssertTrue(store.conflictedSessionIDs.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile error — `value of type 'SessionStore' has no member 'conflictedSessionIDs'`.

- [ ] **Step 3: Expose the derived set**

Add to `Sources/FlightDeck/SessionStore.swift`, near `status(for:)`:

```swift
    /// Tabs sharing a conversation with another tab. Computed rather than stored so it can
    /// never go stale: `repos` is `@Published`, so any change to a pin or to the list
    /// re-evaluates this on the next view update.
    var conflictedSessionIDs: Set<UUID> {
        ConversationPin.conflicted(repos.flatMap(\.sessions))
    }
```

- [ ] **Step 4: Show it in the sidebar**

In `Sources/FlightDeck/SessionSidebar.swift`, add a stored property to `SessionRow` immediately after `let session: Session`:

```swift
    let isConflicted: Bool
```

Insert the badge into `SessionRow.body`, between `Spacer()` and `SessionStatusIcon`:

```swift
            if isConflicted {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                    .help("Another tab is on this conversation")
                    .accessibilityIdentifier("session-pin-conflict")
            }
```

In `SessionSidebar.body`, compute the set once per render rather than per row:

```swift
    var body: some View {
        let conflicted = store.conflictedSessionIDs
        return List(selection: $store.selectedSessionID) {
            ForEach(store.repos) { repo in
                Section(repo.displayName) {
                    ForEach(repo.sessions) { session in
                        SessionRow(
                            store: store,
                            session: session,
                            isConflicted: conflicted.contains(session.id)
                        )
                        .tag(session.id)
                    }
                }
            }
        }
```

Leave the rest of `body` — the `.dropDestination` and `.safeAreaInset` modifiers — exactly as it is.

- [ ] **Step 5: Run the tests and build the app**

Run: `./scripts/test-unit.sh`
Expected: PASS.

Run: `./scripts/build.sh`
Expected: BUILD SUCCEEDED. This step exists because `SessionSidebar` is SwiftUI and is not touched by the unit suite; the build is the only thing that type-checks it.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/SessionSidebar.swift \
        Tests/FlightDeckTests/ConversationRepinTests.swift
git commit -m "feat: flag tabs sharing one conversation"
```

---

### Task 9: Session creation targets the last active project

Empty projects are now reachable, which breaks two assumptions in the creation path: a parameter named `hasSessions` that is really "has projects", and a no-selection fallback to an arbitrary `repos.first`.

**Files:**
- Modify: `Sources/FlightDeck/SessionCreation.swift:16-18`
- Modify: `Sources/FlightDeck/SessionStore.swift` (`selectedSessionID` didSet, `moveSession`, `createFromMenu`, new `lastActiveProjectURL`)
- Test: `Tests/FlightDeckTests/SessionCreationHelperTests.swift`, `Tests/FlightDeckTests/SessionCreationTests.swift`

**Interfaces:**
- Consumes: `SessionStore.moveSession` (Task 7).
- Produces: `SessionCreateAction.forState(hasProjects:)` replaces `forState(hasSessions:)`; `SessionStore.lastActiveProjectURL: URL?` (private setter).

- [ ] **Step 1: Write the failing tests**

In `Tests/FlightDeckTests/SessionCreationHelperTests.swift`, replace the two `forState` assertions:

```swift
        XCTAssertEqual(SessionCreateAction.forState(hasProjects: true), .newSession)
```

```swift
        XCTAssertEqual(SessionCreateAction.forState(hasProjects: false), .addProject)
```

Add to `Tests/FlightDeckTests/SessionCreationTests.swift`:

```swift
/// The case the empty-project state creates: the remembered project has to survive its
/// last session leaving, or ⌘N lands somewhere arbitrary.
@MainActor
func testNewSessionTargetsTheLastActiveProjectEvenWhenItIsEmpty() {
    let store = SessionStore(provider: nil, persistence: nil)
    store.titleResolver = { _, done in done(nil) }
    let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
    store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/b", isDirectory: true))
    // /a is now an empty project, /b holds the session and is last-active.
    store.selectedSessionID = nil

    let created = store.createFromMenu(chooseFolder: { XCTFail("must not prompt"); return nil })

    XCTAssertEqual(created?.workingDirectory, "/b")
}

@MainActor
func testLastActiveProjectFollowsAMovedSelectedSession() {
    let store = SessionStore(provider: nil, persistence: nil)
    store.titleResolver = { _, done in done(nil) }
    let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
    store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/moved", isDirectory: true))

    XCTAssertEqual(store.lastActiveProjectURL?.path, "/moved")
}

@MainActor
func testNilSelectionDoesNotForgetTheLastActiveProject() {
    let store = SessionStore(provider: nil, persistence: nil)
    _ = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))

    store.selectedSessionID = nil

    XCTAssertEqual(store.lastActiveProjectURL?.path, "/a")
}

/// A sidebar holding only an empty project still offers New Session, not Add Project:
/// an empty project is somewhere to put a session.
@MainActor
func testOnlyAnEmptyProjectStillCreatesWithoutPrompting() {
    let store = SessionStore(provider: nil, persistence: nil)
    store.titleResolver = { _, done in done(nil) }
    let a = store.newSession(in: URL(fileURLWithPath: "/a", isDirectory: true))
    store.moveSession(a.id, toProjectAt: URL(fileURLWithPath: "/b", isDirectory: true))
    store.closeSession(a.id)
    // /a survives as an empty project; /b was pruned by closeSession.
    store.selectedSessionID = nil

    let created = store.createFromMenu(chooseFolder: { XCTFail("must not prompt"); return nil })

    XCTAssertNotNil(created)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile error — `incorrect argument label in call (have 'hasProjects:', expected 'hasSessions:')`.

- [ ] **Step 3: Rename the parameter to what it always meant**

In `Sources/FlightDeck/SessionCreation.swift`:

```swift
    /// ⌘N reroutes to Add Project when the sidebar is bare.
    ///
    /// Keyed on *projects*, not sessions: a project with no sessions in it is still
    /// somewhere to put one, so ⌘N should create there rather than prompting for a folder.
    ///
    /// The menu item stays enabled in both states deliberately: a disabled `NSMenuItem`
    /// does not fire its key equivalent, so disabling New Session when empty would make ⌘N
    /// dead in exactly the state it needs to work.
    static func forState(hasProjects: Bool) -> SessionCreateAction {
        hasProjects ? .newSession : .addProject
    }
```

- [ ] **Step 4: Remember the last active project and use it**

In `Sources/FlightDeck/SessionStore.swift`, add next to `sessionCounter`:

```swift
    /// The project of the most recently activated tab, used as ⌘N's target when there is
    /// no selection. Deliberately not cleared when the selection goes nil or when the
    /// project empties — surviving the tab leaving is the entire point.
    private(set) var lastActiveProjectURL: URL?
```

Extend the `selectedSessionID` `didSet`:

```swift
    @Published var selectedSessionID: UUID? {
        didSet {
            if let id = selectedSessionID, let at = locate(id) {
                lastActiveProjectURL = URL(
                    fileURLWithPath: repos[at.repo].sessions[at.session].workingDirectory,
                    isDirectory: true
                )
            }
            persist()
        }
    }
```

In `moveSession`, keep the remembered project pointing at where the tab went rather than where it left. Add immediately before the closing `persist()`:

```swift
        if selectedSessionID == id { lastActiveProjectURL = target }
```

Replace `createFromMenu`:

```swift
    /// The ⌘N / sidebar-button action. Routes to Add Project when nothing is open, which is
    /// why the menu item can stay enabled in both states.
    @discardableResult
    func createFromMenu(chooseFolder: () -> URL? = { FolderPicker.choose() }) -> Session? {
        switch SessionCreateAction.forState(hasProjects: !repos.isEmpty) {
        case .newSession:
            if let created = newSessionBelowActive() {
                return created
            }
            // `newSessionBelowActive` needs a selection, not just a non-empty `repos` — and
            // selection can be nil with sessions still present (e.g. clicking below the last
            // row in the sidebar's List clears it). Prefer the project the user was last
            // working in, *including* when it is now empty; only fall back to an arbitrary
            // project if we have never had one, and only prompt when nothing is open.
            if let url = lastActiveProjectURL, indexOfRepo(for: url) != nil {
                return addProject(at: url)
            }
            if let first = repos.first {
                return addProject(at: first.url)
            }
            guard let url = chooseFolder() else { return nil }
            return addProject(at: url)
        case .addProject:
            guard let url = chooseFolder() else { return nil }
            return addProject(at: url)
        }
    }
```

- [ ] **Step 5: Run the tests and build the app**

Run: `./scripts/test-unit.sh`
Expected: PASS.

Run: `./scripts/build.sh`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionCreation.swift Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/SessionCreationHelperTests.swift \
        Tests/FlightDeckTests/SessionCreationTests.swift
git commit -m "feat: target the last active project when creating a session"
```

---

## Verification

After Task 9, confirm the whole suite is green and the app builds:

```bash
./scripts/test-unit.sh && ./scripts/build.sh
```

Do **not** run `./scripts/smoke.sh` — it steals focus for ~40 seconds and this plan adds no UITest coverage. Driving a real `/resume` through Claude's interactive picker is not scriptable, and a faked one would assert nothing about the registry mechanism the design rests on. That gap is recorded in spec §12.
