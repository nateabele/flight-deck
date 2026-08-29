# Phone Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pull down on the phone's session list to search the whole fleet — names instantly and offline, conversation history from the Mac — and tap a hit to land in that conversation at that line.

**Architecture:** The four pure ranking units move from `Sources/FlightDeck/Search/` to `Sources/FleetKit/Search/` and become `public`, so both screens rank identically. The phone matches names in memory on every keystroke against its fleet plus a conversation catalogue the Mac ships on connect; transcript hits come from a new `search` request, debounced 90 ms, and land in the last tier so they can only append below what is drawn. Jumping to a moment needs a byte offset per indexed message and a new `TimelineAnchor.around`.

**Tech Stack:** Swift 6 (FleetKit, FlightDeckMobile), Swift 5 (FlightDeck/macOS), SwiftUI, XCTest, SQLite FTS5, xcodegen.

**Spec:** `docs/superpowers/specs/2026-08-29-phone-search-design.md`

## Global Constraints

- **FleetKit imports Foundation, Network, Security and CryptoKit only.** No AppKit, no UIKit, no SwiftUI. `FleetKitiOS` compiles the same sources for iOS and is what enforces this — an `import AppKit` that slips in compiles on macOS and fails there.
- **Everything moved into FleetKit must be `public`**, including memberwise inits, or FlightDeck cannot see it.
- **`ServerFrame.Tag` raw values must not contain a dot.** `FleetEventTag`'s values are all dotted and `ServerFrame`'s are not; `ServerFrame.init(from:)` relies on that to tell a frame tag from an event tag.
- **`FleetRequest` and `TimelineAnchor` refuse unknown values rather than guessing.** A request travels phone → Mac and is executed; there is no fallback that is not a wrong answer.
- **New wire fields are optional and decoded with `decodeIfPresent`.** An older Mac talking to a newer phone is the skew that actually happens in the field.
- **iOS deployment target is 17.0.** No iOS 18+ API.
- **Tests are XCTest.** `@MainActor` async tests must use `await fulfillment(of:)`, never `wait(for:)` — the latter deadlocks on the main actor.
- **Test commands:** `scripts/test-unit.sh` (macOS), `scripts/test-ios.sh` (simulator).
- **Never run the GUI smoke tests in a loop** — they steal focus for ~40 s a run.
- **Never swap `/Applications` to try a build.** Launch debug builds in place; swapping kills every other session on this machine.
- **This is a shared working copy.** Several sessions edit it at once. Stage files by explicit path; never `git add -A`, never revert or stash blind.

---

### Task 1: Move the four pure search units into FleetKit

The move is a move, not a rewrite. The proof is that the tests pass unchanged and the iOS slice compiles them.

**Files:**
- Create: `Sources/FleetKit/Search/NameMatcher.swift`, `Sources/FleetKit/Search/SearchRanker.swift`, `Sources/FleetKit/Search/SearchResult.swift`, `Sources/FleetKit/Search/FTS5Query.swift`
- Delete: the same four under `Sources/FlightDeck/Search/`
- Modify: `Tests/FlightDeckTests/NameMatcherTests.swift`, `Tests/FlightDeckTests/SearchRankerTests.swift` (import line only)
- Modify: `Sources/FlightDeck/Search/SearchModel.swift`, `SearchCandidates.swift`, `SearchActivation.swift`, `SQLiteSearchIndex.swift`, `SearchOverlayView.swift`, `SearchPanel.swift` (add `import FleetKit` where needed)

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum MatchTier`, `public struct NameMatch`, `public enum NameMatcher`, `public enum SearchRanker`, `public struct SearchResult`, `public struct NameCandidate`, `public struct TranscriptHit`, `public enum SearchResultKind`, `public enum FTS5Query` — all in module `FleetKit`.

- [ ] **Step 1: Move the files with git so history follows**

```bash
mkdir -p Sources/FleetKit/Search
git mv Sources/FlightDeck/Search/NameMatcher.swift   Sources/FleetKit/Search/
git mv Sources/FlightDeck/Search/SearchRanker.swift  Sources/FleetKit/Search/
git mv Sources/FlightDeck/Search/SearchResult.swift  Sources/FleetKit/Search/
git mv Sources/FlightDeck/Search/FTS5Query.swift     Sources/FleetKit/Search/
```

- [ ] **Step 2: Make every moved declaration public**

In each moved file add `public` to the type and to every member FlightDeck or FlightDeckMobile reads. `SearchResult` and `NameCandidate` and `TranscriptHit` need `public init` written out — the memberwise init is internal by default. For example, in `SearchResult.swift`:

```swift
public enum SearchResultKind: Equatable, Sendable {
    case session(UUID)
    case project
    case conversation(String)
}

public struct TranscriptHit: Equatable, Sendable {
    public let rowID: Int64
    public let conversationID: String
    public let projectPath: String
    public let conversationName: String
    public let snippet: String
    public let timestamp: Date

    public init(
        rowID: Int64, conversationID: String, projectPath: String,
        conversationName: String, snippet: String, timestamp: Date
    ) {
        self.rowID = rowID
        self.conversationID = conversationID
        self.projectPath = projectPath
        self.conversationName = conversationName
        self.snippet = snippet
        self.timestamp = timestamp
    }
}
```

Apply the same treatment to `NameCandidate`, `SearchResult` (including its `isContinuation` default), `MatchTier`, `NameMatch`, `NameMatcher.score`, `SearchRanker.rank`, `SearchRanker.maxMatchesPerConversation` and `FTS5Query.match`.

`SearchRanker`'s `private extension SearchResult` at the bottom of the file stays `private` — it is used only within that file.

- [ ] **Step 3: Point the tests at the new module**

In both `Tests/FlightDeckTests/NameMatcherTests.swift` and `Tests/FlightDeckTests/SearchRankerTests.swift`, change:

```swift
@testable import FlightDeck
```

to:

```swift
import FleetKit
@testable import FlightDeck
```

`import FleetKit` (not `@testable`) is deliberate: the moved API is `public`, so a plain import is enough, and it proves the `public` surface is complete. **Change nothing else in these two files.** A diff beyond the import line means the move was a rewrite.

- [ ] **Step 4: Add `import FleetKit` to the Mac-side consumers**

Add `import FleetKit` to the top of `SearchModel.swift`, `SearchCandidates.swift`, `SearchActivation.swift`, `SQLiteSearchIndex.swift`, `SearchOverlayView.swift`, `SearchPanel.swift` and `SearchIndex.swift` — any file the compiler now reports an unresolved name in.

- [ ] **Step 5: Regenerate the project and build both slices**

```bash
xcodegen generate
scripts/build.sh
scripts/build-ios.sh
```

Expected: both succeed. `build-ios.sh` compiling `FleetKitiOS` is the proof the moved files are Foundation-only.

- [ ] **Step 6: Run the moved tests**

Run: `scripts/test-unit.sh`
Expected: PASS, with `NameMatcherTests` and `SearchRankerTests` green and unmodified beyond their import line.

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/Search Sources/FlightDeck/Search \
        Tests/FlightDeckTests/NameMatcherTests.swift \
        Tests/FlightDeckTests/SearchRankerTests.swift
git commit -m "refactor: share the pure search units with FleetKit

Ranking is now one implementation for both screens rather than two that
can drift. The iOS slice compiling them is the proof they are pure."
```

---

### Task 2: Carry a byte offset on every indexed message

**Files:**
- Modify: `Sources/FlightDeck/Search/IndexedMessage.swift`
- Modify: `Sources/FlightDeck/Search/TranscriptExtractor.swift`
- Test: `Tests/FlightDeckTests/TranscriptExtractorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `IndexedMessage.offset: Int`; `TranscriptExtractor.messages(inLine:conversationID:offset:) -> [IndexedMessage]` and `messages(inObject:conversationID:offset:) -> [IndexedMessage]`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/TranscriptExtractorTests.swift` (create it with `import XCTest` / `@testable import FlightDeck` if absent):

```swift
/// One line can yield several messages, and they all name the same line.
///
/// An offset here is a LINE boundary, which is exactly what a timeline cursor is — so two
/// messages from one record sharing a number is correct, not a collision.
func testEveryMessageFromOneLineCarriesThatLinesOffset() {
    let line = """
        {"type":"assistant","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":\
        [{"type":"text","text":"first"},{"type":"text","text":"second"}]}}
        """
    let messages = TranscriptExtractor.messages(
        inLine: line, conversationID: "abc", offset: 4096
    )
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages.map(\.offset), [4096, 4096])
    XCTAssertEqual(messages.map(\.text), ["first", "second"])
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test-unit.sh`
Expected: FAIL to compile — `messages(inLine:conversationID:offset:)` does not exist and `IndexedMessage` has no `offset`.

- [ ] **Step 3: Add the field and thread it through**

In `IndexedMessage.swift`, add below `timestamp`:

```swift
    /// Where the record this came from starts in its transcript, in bytes, at a line
    /// boundary. Several messages from one record share it — a `TimelineAnchor` cursor names
    /// a line, so that is the right granularity rather than a collision.
    let offset: Int
```

In `TranscriptExtractor.swift`, add the parameter to both entry points and stamp it:

```swift
    static func messages(
        inLine line: String, conversationID: String, offset: Int
    ) -> [IndexedMessage] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return messages(inObject: object, conversationID: conversationID, offset: offset)
    }

    static func messages(
        inObject object: [String: Any], conversationID: String, offset: Int
    ) -> [IndexedMessage] {
```

and in the `compactMap` at the end of `messages(inObject:conversationID:offset:)`:

```swift
            return IndexedMessage(
                conversationID: conversationID, role: role, text: trimmed,
                timestamp: timestamp, offset: offset
            )
```

- [ ] **Step 4: Fix the two callers**

`SearchIndexBuilder` and `TranscriptWatcher` both call the extractor. Each already tracks its read position; pass it as the offset of the line being handed over. In `SearchIndexBuilder`, the running offset is the value it reads from and advances through `TailReader`; capture the position *before* consuming the line and pass that. In `TranscriptWatcher`, do the same with its own tail position.

If a caller genuinely has no position to hand over, pass `0` and leave a comment saying why — do not invent one.

- [ ] **Step 5: Run the tests**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Search/IndexedMessage.swift \
        Sources/FlightDeck/Search/TranscriptExtractor.swift \
        Sources/FlightDeck/Search/SearchIndexBuilder.swift \
        Sources/FlightDeck/TranscriptWatcher.swift \
        Tests/FlightDeckTests/TranscriptExtractorTests.swift
git commit -m "feat: record where each indexed message starts in its transcript

A search hit has to be able to say where it is, not just that it exists."
```

---

### Task 3: Store the offset in the index and return it on every hit

**Files:**
- Modify: `Sources/FleetKit/Search/SearchResult.swift` (`TranscriptHit.offset`)
- Modify: `Sources/FlightDeck/Search/SQLiteSearchIndex.swift` (schema, ingest, search)
- Test: `Tests/FlightDeckTests/SQLiteSearchIndexTests.swift`

**Interfaces:**
- Consumes: `IndexedMessage.offset` (Task 2).
- Produces: `TranscriptHit.offset: Int`, populated by `SQLiteSearchIndex.search`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/SQLiteSearchIndexTests.swift`, following the existing setup helper in that file for making a temporary index:

```swift
/// The offset survives the round trip into SQLite and back out on a hit.
///
/// Without this the phone can find a moment and not be able to open it.
func testSearchReturnsTheOffsetItIngested() throws {
    let index = try makeIndex()
    let source = URL(fileURLWithPath: "/tmp/conv.jsonl")
    try index.ingest(
        [IndexedMessage(
            conversationID: "conv", role: .user, text: "the rename path",
            timestamp: Date(timeIntervalSince1970: 100), offset: 8192
        )],
        from: source, projectPath: "/proj", offset: nil
    )

    let hits = try index.search("\"rename\"*", projects: ["/proj"], limit: 10)

    XCTAssertEqual(hits.count, 1)
    XCTAssertEqual(hits[0].offset, 8192)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/test-unit.sh`
Expected: FAIL to compile — `TranscriptHit` has no `offset`.

- [ ] **Step 3: Add `offset` to `TranscriptHit`**

In `Sources/FleetKit/Search/SearchResult.swift`, add to `TranscriptHit` (and to its `public init`, as the last parameter):

```swift
    /// Where this message's record starts in its transcript, in bytes, at a line boundary —
    /// which is exactly what `TimelineAnchor.around` takes. This is what lets a hit be
    /// opened rather than only read.
    public let offset: Int
```

- [ ] **Step 4: Bump the schema and store the column**

In `SQLiteSearchIndex.swift`:

```swift
    static let schemaVersion = 2
```

In `createSchema()`, add the column to `message`, after `source`:

```sql
              source TEXT NOT NULL,
              offset INTEGER NOT NULL
```

A version mismatch deletes the file and rebuilds, which is the whole migration story — the index is a cache and is never the source of truth for anything.

In `ingest`, add `offset` to the `INSERT INTO message` column list and its value list, and bind `Int32(message.offset)` (or `sqlite3_bind_int64` with `Int64(message.offset)`) in the matching position.

In `search`, add `m.offset` to the `SELECT` list after `m.timestamp`, which shifts the snippet to column index 5:

```swift
            SELECT m.id, m.conversation_id, m.project_path, m.timestamp, m.offset,
                   snippet(message_fts, 0, char(2), char(3), '…', 24)
```

and in the row loop:

```swift
                snippet: text(statement, 5),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                offset: Int(sqlite3_column_int64(statement, 4))
```

**Check every other column index in that loop against the new list** — moving the snippet is exactly the kind of change that silently reads the wrong column.

- [ ] **Step 5: Run the tests**

Run: `scripts/test-unit.sh`
Expected: PASS, including the existing `SQLiteSearchIndexTests` and `SearchSnippetTests` — the latter is what catches a mis-numbered snippet column.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/Search/SearchResult.swift \
        Sources/FlightDeck/Search/SQLiteSearchIndex.swift \
        Tests/FlightDeckTests/SQLiteSearchIndexTests.swift
git commit -m "feat: return a transcript hit's byte offset from the index

Schema 2. A mismatched version deletes and rebuilds, as designed."
```

---

### Task 4: `TimelineAnchor.around`

**Files:**
- Modify: `Sources/FleetKit/TimelineFrames.swift`
- Modify: `Sources/FlightDeck/Timeline/TimelineReader.swift`
- Test: `Tests/FlightDeckTests/TimelineFramesTests.swift`, `Tests/FlightDeckTests/TimelineReaderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `TimelineAnchor.around(Int)`, wire name `"around"`; `TimelineReader` serves it.

- [ ] **Step 1: Write the failing tests**

```swift
/// `around` needs a cursor, and is refused without one — the same guard `before` and
/// `after` already carry, for the same reason: an anchor is executed, not rendered.
func testAroundRequiresACursor() {
    XCTAssertEqual(TimelineAnchor(name: "around", cursor: 4096), .around(4096))
    XCTAssertNil(TimelineAnchor(name: "around", cursor: nil))
}

func testAroundRoundTripsThroughARequest() throws {
    let request = FleetRequest.timeline(
        session: UUID(), anchor: .around(4096), limit: 20
    )
    let data = try JSONEncoder().encode(request)
    XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: data), request)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-unit.sh`
Expected: FAIL to compile — no `.around` case.

- [ ] **Step 3: Add the case**

In `TimelineAnchor`:

```swift
    /// The records either side of this offset. What opening a search hit asks for.
    case around(Int)
```

In `name`: `case .around: return "around"`.
In `cursor`: extend the existing binding — `case .before(let cursor), .after(let cursor), .around(let cursor): return cursor`.
In `init?(name:cursor:)`, before `default`:

```swift
        case ("around", let cursor?): self = .around(cursor)
```

- [ ] **Step 4: Serve it in the reader**

In `TimelineReader`, handle `.around(offset)`: read `limit / 2` records ending at `offset` and `limit - limit / 2` records starting at `offset`, then return them as one page in file order with `start` at the first included record and `end` just past the last — the same contract `.before` and `.after` already satisfy. `hasMore` means "anything precedes `start`", unchanged.

Reuse the existing seek-and-read helpers rather than adding a second reading path; `.around` is `.before` and `.after` back to back about one pivot.

- [ ] **Step 5: Write the reader test**

```swift
/// A page around an offset includes the record AT that offset and history either side.
func testAroundReturnsRecordsEitherSideOfTheOffset() throws {
    // Build a transcript of ten records using this file's existing fixture helper, note
    // the offset of record 5, then:
    let page = try reader.page(session: id, anchor: .around(pivot), limit: 6)

    XCTAssertTrue(page.items.contains { $0.id == pivot })
    XCTAssertLessThanOrEqual(page.start, pivot)
    XCTAssertGreaterThan(page.end, pivot)
}
```

- [ ] **Step 6: Run the tests**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/TimelineFrames.swift \
        Sources/FlightDeck/Timeline/TimelineReader.swift \
        Tests/FlightDeckTests/TimelineFramesTests.swift \
        Tests/FlightDeckTests/TimelineReaderTests.swift
git commit -m "feat: add the around anchor its own doc comment predicted

An old Mac refuses it on its cid and reads on, rather than dropping the socket."
```

---

### Task 5: `WireSession.lastActivity`

**Files:**
- Modify: `Sources/FleetKit/Wire.swift`
- Modify: the Mac-side projection that builds `WireSession` (find with `rg -n 'WireSession(' Sources/FlightDeck/`)
- Test: `Tests/FlightDeckTests/WireTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `WireSession.lastActivity: Date?`.

- [ ] **Step 1: Write the failing test**

```swift
/// An older Mac sends no `lastActivity`, and that is a value, not an error.
func testWireSessionDecodesWithoutLastActivity() throws {
    let json = """
        {"id":"\(UUID().uuidString)","title":"t","agent":"claude",
         "subagentCount":0,"isUnread":false}
        """.data(using: .utf8)!
    let session = try JSONDecoder().decode(WireSession.self, from: json)
    XCTAssertNil(session.lastActivity)
}

func testWireSessionRoundTripsLastActivity() throws {
    let sent = WireSession(
        id: UUID(), title: "t", agent: "claude",
        lastActivity: Date(timeIntervalSince1970: 1000)
    )
    let data = try JSONEncoder().encode(sent)
    XCTAssertEqual(try JSONDecoder().decode(WireSession.self, from: data), sent)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test-unit.sh`
Expected: FAIL to compile — no `lastActivity`.

- [ ] **Step 3: Add the property**

In `WireSession`, after `hasBackgroundWork`:

```swift
    /// The transcript's modification time — when this session last did anything.
    ///
    /// Optional because an older Mac does not send it, and because the phone must degrade to
    /// sidebar order rather than crash. `SearchRanker` reads it as `.distantPast` when absent,
    /// which sorts such a session last within its tier instead of first.
    public var lastActivity: Date?
```

Add `lastActivity: Date? = nil` as the final parameter of the memberwise `public init` and assign it. In `init(from decoder:)`, add:

```swift
        // Absent from an older Mac's snapshot, and that is a meaningful value, not an error —
        // the same rule `hasBackgroundWork` above is decoded under.
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
```

- [ ] **Step 4: Populate it on the Mac**

Where the Mac builds a `WireSession`, pass the transcript's mtime — the same value `SearchCandidates.build` already reads via `ClaudeSession.transcriptURL(sessionID:workingDirectory:)` and its `modified` seam. Reuse that call rather than adding a second way to ask the same question.

- [ ] **Step 5: Run the tests**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/Wire.swift Sources/FlightDeck Tests/FlightDeckTests/WireTests.swift
git commit -m "feat: tell clients when a session last did anything

Recency breaks every tie in ranking, and the phone had no data to run it on."
```

---

### Task 6: The three new wire frames

**Files:**
- Modify: `Sources/FleetKit/TimelineFrames.swift` (`FleetRequest`)
- Modify: `Sources/FleetKit/Frames.swift` (`ServerFrame`)
- Create: `Sources/FleetKit/WireSearch.swift`
- Test: `Tests/FlightDeckTests/FramesTests.swift`

**Interfaces:**
- Consumes: `TranscriptHit` (Task 3).
- Produces:
  - `public struct WireConversation { public let id: String; public let name: String; public let projectPath: String }`
  - `public struct WireSearchHits { public let hits: [TranscriptHit]; public let indexing: WireIndexingProgress? }`
  - `public struct WireIndexingProgress { public let done: Int; public let total: Int }`
  - `FleetRequest.conversations`, `.search(query: String, limit: Int)`, `.openConversation(conversationID: String, projectPath: String)`
  - `ServerFrame.conversations(cid: Int, [WireConversation])`, `.searchHits(cid: Int, WireSearchHits)`, `.session(cid: Int, UUID)`

- [ ] **Step 1: Write the failing round-trip tests**

```swift
func testNewRequestsRoundTrip() throws {
    let requests: [FleetRequest] = [
        .conversations,
        .search(query: "rename", limit: 200),
        .openConversation(conversationID: "abc", projectPath: "/proj"),
    ]
    for request in requests {
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(FleetRequest.self, from: data), request)
    }
}

func testNewRepliesRoundTrip() throws {
    let hit = TranscriptHit(
        rowID: 1, conversationID: "abc", projectPath: "/proj", conversationName: "n",
        snippet: "s", timestamp: Date(timeIntervalSince1970: 1), offset: 4096
    )
    let frames: [ServerFrame] = [
        .conversations(cid: 1, [WireConversation(id: "abc", name: "n", projectPath: "/proj")]),
        .searchHits(cid: 2, WireSearchHits(hits: [hit], indexing: nil)),
        .session(cid: 3, UUID()),
    ]
    for frame in frames {
        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(ServerFrame.self, from: data), frame)
    }
}

/// The frame tags and the event tags share one `t` namespace, and `ServerFrame` tells them
/// apart by the event tags all containing a dot. A new undotted tag must stay undotted.
func testNewFrameTagsAreUndotted() {
    for tag in ["conversations", "hits", "session"] {
        XCTAssertFalse(tag.contains("."))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-unit.sh`
Expected: FAIL to compile.

- [ ] **Step 3: Add the wire types**

Create `Sources/FleetKit/WireSearch.swift`:

```swift
import Foundation

/// One conversation the Mac's index knows a name for.
///
/// The phone matches names over these locally, so search over history feels the same as
/// search over open tabs. At a few hundred conversations the whole catalogue is tens of
/// kilobytes, which is why it is shipped rather than queried per keystroke.
public struct WireConversation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let projectPath: String

    public init(id: String, name: String, projectPath: String) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
    }
}

/// How far the Mac has got through its backfill.
///
/// Carried on a search reply rather than pushed as an event: it is only interesting while
/// somebody is looking at a search field, and an event would log it into the resume cursor.
public struct WireIndexingProgress: Codable, Equatable, Sendable {
    public let done: Int
    public let total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// The answer to one search.
///
/// `hits` arrive in BM25 order and are NOT ranked — ranking happens on the phone, where the
/// name half of the results lives. Merging the two halves anywhere else would mean shipping
/// the phone's fleet to the Mac on every keystroke.
public struct WireSearchHits: Codable, Equatable, Sendable {
    public let hits: [TranscriptHit]
    public let indexing: WireIndexingProgress?

    public init(hits: [TranscriptHit], indexing: WireIndexingProgress?) {
        self.hits = hits
        self.indexing = indexing
    }
}
```

Make `TranscriptHit` conform to `Codable` in `Sources/FleetKit/Search/SearchResult.swift` — it crosses the wire now:

```swift
public struct TranscriptHit: Codable, Equatable, Sendable {
```

- [ ] **Step 4: Add the request cases**

In `FleetRequest`, add the three cases with doc comments, extend `CodingKeys` with `query, conversationID, projectPath`, add to `Op`:

```swift
        case conversations = "search.conversations"
        case search = "search.query"
        case openConversation = "search.open"
```

and the matching `encode`/`init(from:)` arms:

```swift
        case .conversations:
            try c.encode(Op.conversations, forKey: .op)
        case .search(let query, let limit):
            try c.encode(Op.search, forKey: .op)
            try c.encode(query, forKey: .query)
            try c.encode(limit, forKey: .limit)
        case .openConversation(let conversationID, let projectPath):
            try c.encode(Op.openConversation, forKey: .op)
            try c.encode(conversationID, forKey: .conversationID)
            try c.encode(projectPath, forKey: .projectPath)
```

```swift
        case .conversations:
            self = .conversations
        case .search:
            self = .search(
                query: try c.decode(String.self, forKey: .query),
                limit: try c.decode(Int.self, forKey: .limit)
            )
        case .openConversation:
            self = .openConversation(
                conversationID: try c.decode(String.self, forKey: .conversationID),
                projectPath: try c.decode(String.self, forKey: .projectPath)
            )
```

- [ ] **Step 5: Add the reply cases**

In `ServerFrame`, add the three cases, extend `CodingKeys` with `conversations, hits, session`, and add to `Tag`:

```swift
    private enum Tag: String, Codable {
        case snapshot, ack, err, page, options, endpoints, conversations, hits, session
    }
```

**Undotted, deliberately** — `ServerFrame.init(from:)` distinguishes a frame tag from an event tag by the event tags all being dotted. Add the encode and decode arms in the same shape as `.newSessionOptions`.

- [ ] **Step 6: Run the tests**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit Tests/FlightDeckTests/FramesTests.swift
git commit -m "feat: wire frames for the conversation catalogue, search and open"
```

---

### Task 7: Serve the three requests on the Mac

**Files:**
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift:141` (`server.onRequest`)
- Test: `Tests/FlightDeckTests/FleetServiceTests.swift`

**Interfaces:**
- Consumes: the frames from Task 6, `SQLiteSearchIndex.conversationNames()`, `FTS5Query.match`, `SearchIndex.search`, `SearchActivation.plan`, `SessionStore.openConversation`.
- Produces: replies on the `cid` for all three requests.

- [ ] **Step 1: Add the three arms to `onRequest`**

Alongside the existing `.timeline` and `.newSessionOptions` cases:

```swift
            case .conversations:
                // Filtered to open projects, the same rule and the same reason
                // `SearchCandidates` applies: a name match the Mac cannot honour without
                // silently re-adding a project the user removed on purpose.
                let open = Set(self.openProjectPaths())
                let catalogue = ((try? self.searchIndex.conversationNames()) ?? [:])
                    .filter { open.contains($0.value.projectPath) }
                    .map { WireConversation(
                        id: $0.key, name: $0.value.name, projectPath: $0.value.projectPath
                    ) }
                    .sorted { $0.id < $1.id }
                reply(.conversations(cid: cid, catalogue))

            case .search(let query, let limit):
                // A query FTS5 cannot match is not a failure — it is a query with nothing
                // to match, and an empty answer is the honest one.
                guard let match = FTS5Query.match(for: query) else {
                    return reply(.searchHits(
                        cid: cid, WireSearchHits(hits: [], indexing: self.indexingProgress())
                    ))
                }
                let projects = self.openProjectPaths()
                let capped = min(limit, SearchModel.transcriptLimit)
                let hits = (try? self.searchIndex.search(
                    match, projects: projects, limit: capped
                )) ?? []
                reply(.searchHits(
                    cid: cid, WireSearchHits(hits: hits, indexing: self.indexingProgress())
                ))

            case .openConversation(let conversationID, let projectPath):
                guard let id = self.openConversation(
                    conversationID: conversationID, projectPath: projectPath
                ) else {
                    return reply(.err(cid: cid, code: "unknown_conversation"))
                }
                reply(.session(cid: cid, id))
```

- [ ] **Step 2: Implement `openConversation` over the existing seam**

Add a private helper on `FleetService` that builds a `SearchResult` for the conversation and hands it to the code the desktop's Return already runs — `SearchActivation.plan` followed by `SessionStore.openConversation`. Do not reimplement the rules; `SearchActivation` already decides select-vs-resume-vs-add-project, and `SessionStore` already re-resolves the real transcript directory. Return the resulting tab id.

- [ ] **Step 3: Write the test**

```swift
/// A project that has left the sidebar contributes nothing, rather than a hit the Mac
/// could not honour without silently re-adding it. Asserted at the index, which is where
/// the scoping actually happens.
func testSearchIsScopedToOpenProjects() throws {
    let index = try makeIndex()
    try index.ingest(
        [IndexedMessage(
            conversationID: "c", role: .user, text: "the rename path",
            timestamp: Date(timeIntervalSince1970: 1), offset: 0
        )],
        from: URL(fileURLWithPath: "/tmp/c.jsonl"), projectPath: "/closed", offset: nil
    )

    XCTAssertTrue(
        try index.search("\"rename\"*", projects: ["/open"], limit: 10).isEmpty
    )
    XCTAssertEqual(
        try index.search("\"rename\"*", projects: ["/closed"], limit: 10).count, 1
    )
}

/// Opening a conversation that already has a tab selects it rather than starting a second
/// `--resume` against a live transcript — two processes appending one file.
func testOpenConversationSelectsAnExistingTab() {
    let tab = UUID()
    let conversation = UUID()
    let result = SearchResult(
        id: "conversation:\(conversation.uuidString.lowercased())",
        kind: .conversation(conversation.uuidString.lowercased()),
        title: "auth refactor",
        projectName: "proj",
        projectPath: "/proj",
        tier: .transcript,
        recency: Date(timeIntervalSince1970: 1),
        highlightedRanges: [],
        snippet: "the rename path",
        conversationID: conversation.uuidString.lowercased()
    )

    let plan = SearchActivation.plan(
        for: result,
        openSessions: [.init(id: tab, conversationID: conversation)],
        projects: ["/proj"]
    )

    XCTAssertEqual(plan, .select(tab))
}
```

Both assert the rules `FleetService` delegates to rather than re-asserting them through a
socket: the scoping lives in `SQLiteSearchIndex.search`'s SQL, and the select-vs-resume
decision lives in `SearchActivation.plan`. `makeIndex()` is the helper
`SQLiteSearchIndexTests` already uses; put the first test in that file and the second in
`SearchActivationTests`.

- [ ] **Step 4: Run the tests**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Fleet/FleetService.swift Tests/FlightDeckTests/FleetServiceTests.swift
git commit -m "feat: answer catalogue, search and open-conversation from the Mac

Activation goes through SearchActivation and SessionStore.openConversation —
the seam the desktop's Return and Reopen Closed Session already use."
```

---

### Task 8: Ask for them from the phone

**Files:**
- Modify: `Sources/FleetKit/FleetConnector.swift`
- Test: `Tests/FlightDeckTests/FleetConnectorTests.swift`

**Interfaces:**
- Consumes: the frames from Task 6.
- Produces:
  - `requestConversations(then: @escaping (Result<[WireConversation], FleetRequestError>) -> Void)`
  - `requestSearch(query: String, limit: Int, then: @escaping (Result<WireSearchHits, FleetRequestError>) -> Void)`
  - `requestOpenConversation(conversationID: String, projectPath: String, then: @escaping (Result<UUID, FleetRequestError>) -> Void)`

- [ ] **Step 1: Add three pending tables and three request methods**

Follow the existing shape exactly — `pending`, `pendingAcks`, `pendingOptions` and `pendingEndpoints` are four separate tables on purpose, and the file says why: a generic reply type would mean retyping `pending` and widening every caller. Add `pendingConversations`, `pendingSearch` and `pendingSession` beside them, each with its own `request*` method mirroring `requestNewSessionOptions`, and its own arm in `apply` that removes the entry and completes it.

Every one of them must complete **exactly once**, including with `.disconnected` when the socket dies — that is what stops a footer spinning forever.

- [ ] **Step 2: Write the test**

```swift
**Do not invent fixtures for this file.** `FleetConnectorTests` already has tests for
`requestNewSessionOptions` that stand up a connector and drive replies into it. Open them,
copy the two that cover *reply lands on its cid* and *socket death completes with
`.disconnected`*, and change exactly three things in each copy:

| In the copy | From | To |
|---|---|---|
| the call under test | `requestNewSessionOptions(project:then:)` | `requestSearch(query:limit:then:)` |
| the frame driven in | `.newSessionOptions(cid:, WireNewSessionOptions(...))` | `.searchHits(cid:, WireSearchHits(hits: [], indexing: nil))` |
| the test names | `...NewSessionOptions...` | `...Search...` |

Everything else — the connector construction, the store stub, the expectation and timeout —
carries over unchanged, which is the point: this is a fourth table beside three that already
work, and it should be tested the same way they are. Repeat the same three substitutions for
`requestConversations` and `requestOpenConversation`.

Both properties must hold for all three: the entry is removed when it completes, so a second
frame on the same `cid` cannot complete it twice, and a socket that goes away completes with
`.disconnected` rather than never at all.

- [ ] **Step 3: Run the tests**

Run: `scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/FleetKit/FleetConnector.swift Tests/FlightDeckTests/FleetConnectorTests.swift
git commit -m "feat: client requests for catalogue, search and open-conversation"
```

---

### Task 9: `PhoneSearchCandidates`

**Files:**
- Create: `Sources/FlightDeckMobile/PhoneSearchCandidates.swift`
- Test: `Tests/FlightDeckMobileTests/PhoneSearchCandidatesTests.swift`

**Interfaces:**
- Consumes: `WireProject`, `WireSession`, `WireConversation`, `NameCandidate`.
- Produces: `enum PhoneSearchCandidates { static func build(projects: [WireProject], conversations: [WireConversation]) -> [NameCandidate] }`

- [ ] **Step 1: Write the failing tests**

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

final class PhoneSearchCandidatesTests: XCTestCase {
    /// A conversation with a live tab is contributed by the tab and not again by the
    /// catalogue — otherwise it appears twice with two different meanings for a tap.
    func testALiveSessionClaimsItsConversation() {
        let id = UUID()
        let projects = [WireProject(
            id: UUID(), name: "flight-deck", path: "/proj",
            sessions: [WireSession(id: id, title: "rename fix", agent: "claude")]
        )]
        let catalogue = [WireConversation(
            id: id.uuidString.lowercased(), name: "rename fix", projectPath: "/proj"
        )]

        let candidates = PhoneSearchCandidates.build(
            projects: projects, conversations: catalogue
        )

        XCTAssertEqual(candidates.filter { $0.name == "rename fix" }.count, 1)
    }

    /// A catalogue entry for a project the phone is not showing is dropped: tapping it
    /// would ask the Mac to re-add a project the user removed.
    func testCatalogueEntriesOutsideTheFleetAreDropped() {
        let candidates = PhoneSearchCandidates.build(
            projects: [WireProject(id: UUID(), name: "a", path: "/a")],
            conversations: [WireConversation(id: "x", name: "gone", projectPath: "/b")]
        )
        XCTAssertFalse(candidates.contains { $0.name == "gone" })
    }

    /// No `lastActivity` sorts last within its tier rather than crashing or sorting first.
    func testAbsentLastActivityBecomesDistantPast() {
        let candidates = PhoneSearchCandidates.build(
            projects: [WireProject(
                id: UUID(), name: "a", path: "/a",
                sessions: [WireSession(id: UUID(), title: "t", agent: "claude")]
            )],
            conversations: []
        )
        XCTAssertEqual(candidates.first { $0.name == "t" }?.lastActivity, .distantPast)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-ios.sh`
Expected: FAIL to compile — no `PhoneSearchCandidates`.

- [ ] **Step 3: Implement it**

```swift
import FleetKit
import Foundation

/// Flattens what the phone holds into the list `SearchRanker` matches names against.
///
/// The phone's answer to the Mac's `SearchCandidates`, and deliberately a separate type
/// rather than a shared one: that reads `Repo` and `ClaudeSession`, which are Mac types that
/// exist to derive filesystem paths. The *rules* are shared — through `SearchRanker` — and
/// the sources are not.
enum PhoneSearchCandidates {
    static func build(
        projects: [WireProject], conversations: [WireConversation]
    ) -> [NameCandidate] {
        var candidates: [NameCandidate] = []
        var claimed: Set<String> = []

        for project in projects {
            var newest = Date.distantPast
            for session in project.sessions {
                // Lowercased because a transcript filename stem is lowercase and
                // `UUID.uuidString` is not — comparing them raw never matches, which would
                // silently defeat the claim below and list every open session twice.
                claimed.insert(session.id.uuidString.lowercased())
                let stamp = session.lastActivity ?? .distantPast
                newest = max(newest, stamp)
                candidates.append(NameCandidate(
                    id: session.id.uuidString,
                    kind: .session(session.id),
                    name: session.title,
                    projectPath: project.path,
                    projectName: project.name,
                    lastActivity: stamp,
                    conversationID: nil
                ))
            }
            candidates.append(NameCandidate(
                id: "project:\(project.path)",
                kind: .project,
                name: project.name,
                projectPath: project.path,
                projectName: project.name,
                lastActivity: newest,
                conversationID: nil
            ))
        }

        let open = Set(projects.map(\.path))
        // Sorted by id so the list is deterministic: `SearchRanker`'s final tiebreak is the
        // result id, and a candidate list that reshuffled between calls would defeat it.
        for conversation in conversations.sorted(by: { $0.id < $1.id })
        where !claimed.contains(conversation.id) && open.contains(conversation.projectPath) {
            candidates.append(NameCandidate(
                id: "conversation:\(conversation.id)",
                kind: .conversation(conversation.id),
                name: conversation.name,
                projectPath: conversation.projectPath,
                projectName: URL(fileURLWithPath: conversation.projectPath).lastPathComponent,
                // Unknown without stat-ing every historical transcript on the Mac, which the
                // desktop declines to do for the same reason. Sorting last within a tier is
                // the right default: anything with a live tab is likelier to be wanted.
                lastActivity: .distantPast,
                conversationID: conversation.id
            ))
        }
        return candidates
    }
}
```

**Note the claim key.** A `WireSession` does not expose its conversation id, so a session is matched against the catalogue by its tab id lowercased. For claude these are the same value; for codex they are not, so a codex session's past conversation may appear as a separate catalogue row. That is the honest limit of what the wire says today — do not invent a mapping. If it proves confusing in use, the fix is a `conversationID` on `WireSession`, not a guess here.

- [ ] **Step 4: Run the tests**

Run: `scripts/test-ios.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeckMobile/PhoneSearchCandidates.swift \
        Tests/FlightDeckMobileTests/PhoneSearchCandidatesTests.swift
git commit -m "feat: build the phone's name-match candidates from fleet and catalogue"
```

---

### Task 10: `SessionSearchModel`

**Files:**
- Create: `Sources/FlightDeckMobile/SessionSearchModel.swift`
- Modify: `Sources/FlightDeckMobile/FleetModel.swift` (catalogue refresh, request forwarding)
- Test: `Tests/FlightDeckMobileTests/SessionSearchModelTests.swift`

**Interfaces:**
- Consumes: `PhoneSearchCandidates.build`, `SearchRanker.rank`, `FleetConnector.requestSearch`.
- Produces:
  - `protocol TranscriptSearching: AnyObject { func searchTranscripts(query: String, limit: Int, then: @escaping (Result<WireSearchHits, FleetRequestError>) -> Void) }`, which `FleetModel` conforms to alongside `TimelinePaging` and `PromptSending`
  - `@MainActor @Observable final class SessionSearchModel` with `var query: String`, `private(set) var results: [SearchResult]`, `private(set) var footer: Footer?`, `func candidatesChanged(_:)`, and `enum Footer: Equatable { case offline(String), indexing(done: Int, total: Int), empty }`
  - `init(transport: any TranscriptSearching, macName: String)`

- [ ] **Step 1: Write the failing tests**

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

@MainActor
final class SessionSearchModelTests: XCTestCase {
    /// Hands back what the test says, when the test says — so the two clocks can be driven
    /// apart deliberately instead of raced.
    final class Transport: TranscriptSearching {
        var requests: [String] = []
        var pending: [(Result<WireSearchHits, FleetRequestError>) -> Void] = []

        func searchTranscripts(
            query: String, limit: Int,
            then completion: @escaping (Result<WireSearchHits, FleetRequestError>) -> Void
        ) {
            requests.append(query)
            pending.append(completion)
        }

        func answer(_ hits: [TranscriptHit], at index: Int = 0) {
            pending[index](.success(WireSearchHits(hits: hits, indexing: nil)))
        }
    }

    /// Comfortably past the 90 ms debounce, so the request has certainly been issued.
    private func letTheDebounceFire() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }

    private func candidate(_ name: String) -> NameCandidate {
        NameCandidate(
            id: name, kind: .session(UUID()), name: name,
            projectPath: "/proj", projectName: "proj",
            lastActivity: Date(timeIntervalSince1970: 1), conversationID: nil
        )
    }

    private func hit(_ conversation: String) -> TranscriptHit {
        TranscriptHit(
            rowID: 1, conversationID: conversation, projectPath: "/proj",
            conversationName: conversation, snippet: "the rename path",
            timestamp: Date(timeIntervalSince1970: 1), offset: 4096
        )
    }

    /// Names rank on the keystroke with nothing in flight — the whole point of matching
    /// them locally, and what makes the field work with the Mac asleep.
    func testNamesRankWithoutAskingTheMac() {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Mac")
        model.candidatesChanged([candidate("rename fix"), candidate("unrelated")])

        model.query = "rename"

        XCTAssertEqual(model.results.map(\.title), ["rename fix"])
        XCTAssertTrue(transport.requests.isEmpty, "names must not wait on a round trip")
    }

    /// A reply for a superseded query is discarded, so a previous query's evidence can
    /// never survive under a new one.
    func testAStaleReplyIsDropped() async throws {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Mac")

        model.query = "rena"
        try await letTheDebounceFire()
        XCTAssertEqual(transport.requests, ["rena"])

        model.query = "rename"
        transport.answer([hit("stale")], at: 0)

        XCTAssertFalse(model.results.contains { $0.conversationID == "stale" })
    }

    /// Hits land BELOW names however they arrive — the property that stops a row moving
    /// under a finger already descending on it.
    func testHitsAlwaysAppendBelowNames() async throws {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Mac")
        model.candidatesChanged([candidate("rename fix")])

        model.query = "rename"
        try await letTheDebounceFire()
        transport.answer([hit("conv")])

        XCTAssertEqual(model.results.first?.title, "rename fix")
        XCTAssertEqual(model.results.last?.conversationID, "conv")
    }

    /// Disconnected says so and never claims "no results" — that is a claim about the
    /// corpus a disconnected phone is in no position to make.
    func testDisconnectedSetsTheOfflineFooterRatherThanEmpty() async throws {
        let transport = Transport()
        let model = SessionSearchModel(transport: transport, macName: "Nate's Mac")

        model.query = "rename"
        try await letTheDebounceFire()
        transport.pending[0](.failure(.disconnected))

        XCTAssertEqual(model.footer, .offline("Nate's Mac"))
    }
}
```

These drive the debounce with `Task.sleep` rather than an expectation, which sidesteps the
`@MainActor` hazard entirely: **`wait(for:)` deadlocks on the main actor** — if you do reach
for an expectation anywhere here, it must be `await fulfillment(of:)`.

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/test-ios.sh`
Expected: FAIL to compile.

- [ ] **Step 3: Implement the model**

Mirror `SearchModel`'s two-clock structure: `query`'s `didSet` clears held hits immediately and reranks with no debounce, then schedules a 90 ms task that issues one `requestSearch`. Drop a reply whose query does not equal the current one. Hold hits in a stored array cleared on every query change, so a previous query's evidence can never survive under a new one.

```swift
    /// Long enough to collapse a burst of typing into one request, short enough that pausing
    /// to read feels immediate. The same constant as the Mac's, and it now buys a socket
    /// round trip rather than a local query.
    static let transcriptDebounce: Duration = .milliseconds(90)
```

Take the transport as a small protocol rather than `FleetModel` directly, so the tests need no socket.

- [ ] **Step 4: Fetch the catalogue on every snapshot**

In `FleetModel.connect()`'s `onFleet` closure, call a new `refreshConversations()` beside the existing `refreshNewSessionOptions()`. It covers first dial, reconnect and return from foreground — the three moments it can go stale — for the reason already written there.

- [ ] **Step 5: Run the tests**

Run: `scripts/test-ios.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeckMobile/SessionSearchModel.swift \
        Sources/FlightDeckMobile/FleetModel.swift \
        Tests/FlightDeckMobileTests/SessionSearchModelTests.swift
git commit -m "feat: rank names locally and merge the Mac's transcript hits below them"
```

---

### Task 11: The search surface, and landing on the moment

**Files:**
- Modify: `Sources/FlightDeckMobile/FleetListScreen.swift`
- Create: `Sources/FlightDeckMobile/SessionSearchResults.swift`
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift` (open at an offset)
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (highlight and scroll)

**Interfaces:**
- Consumes: `SessionSearchModel`, `SearchResult`, `TimelineAnchor.around`.
- Produces: the visible feature.

- [ ] **Step 1: Add the field**

On the `List` in `FleetListScreen.body`:

```swift
            .searchable(
                text: $search.query,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search sessions and history"
            )
```

Hidden above the first row and revealed by dragging down, at no cost to the screen's resting height. `.searchable` is the whole gesture — **do not add a `simultaneousGesture` or any custom recogniser.** This screen has already lost every row tap once to a second recogniser competing with the `List`.

- [ ] **Step 2: Swap the content when a query is typed**

With `search.query` empty the list is exactly what it is today — projects, headers, collapse state and all. Non-empty, it renders `SessionSearchResults(results:footer:onTap:)` instead.

- [ ] **Step 3: Draw the rows**

Three shapes, per the spec: a session or project row reuses the existing `row(_:)` with the matched span underlined from `SearchResult.highlightedRanges`; a conversation row is name, `project · relative time`, and the snippet with its U+0002/U+0003 sentinels parsed into an `AttributedString`; a continuation is indented and headless per `SearchResult.isContinuation`. Reuse the sentinel parsing `SearchSnippetTests` already covers rather than writing a second parser.

Every `Text` names its own font. A `List` does not pass a container font down to its rows — the file's own comment records that this sent a build back from testing once.

- [ ] **Step 4: Open a hit at its offset**

On tap:
- `.session(let id)` → push that tab, as today.
- `.conversation` or `.project` → `requestOpenConversation`, then push the returned tab id.

Then have `SessionTimelineModel` fetch `.around(offset)` for its first page instead of `.latest`, and have `SessionTimelineScreen` scroll to the item whose id equals that offset and highlight it briefly before fading.

If the Mac answers `err`/`unsupported` to `.around` — an older Mac that has never heard of it — fall back to `.latest` and land in the conversation without the scroll. That is a worse answer to the right question, not a failure.

- [ ] **Step 5: Build and run on a simulator**

```bash
scripts/build-ios.sh
scripts/test-ios.sh
```

Expected: builds, tests pass.

- [ ] **Step 6: Verify by hand against a real Mac**

Pull down on the session list. Type a word you know is in a closed conversation. Confirm: names filter as you type; hits appear below them a beat later; tapping a hit opens the conversation at that line, highlighted; a tab appears on the Mac. Then put the Mac to sleep and type again — names must still filter and the footer must say "searching names only", never "No results".

Launch the debug build **in place**. Do not swap `/Applications`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeckMobile
git commit -m "feat: search the fleet and its history from the phone

Pull down on the session list. Names rank instantly and offline; history
arrives from the Mac and lands below, so a row cannot move under a finger."
```

---

## Verification

- `scripts/test-unit.sh` — all macOS tests. `NameMatcherTests` and `SearchRankerTests` must pass with **no diff beyond their import line**; that is the proof Task 1 was a move.
- `scripts/test-ios.sh` — `PhoneSearchCandidatesTests` and `SessionSearchModelTests`.
- `scripts/build-ios.sh` — compiling `FleetKitiOS` proves the moved units stayed Foundation-only.
- By hand, per Task 11 Step 6: the end-to-end tap, and the offline check.
- Desktop regression: open ⌘K on the Mac and confirm search still ranks and activates as before. Tasks 1–5 change the code underneath it, and the index rebuilds once on first launch after the schema bump.
