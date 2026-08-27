# Smart Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A ⌘K Spotlight-style overlay that finds a session, a project, or a moment inside a past conversation, and resumes the chosen one into a tab.

**Architecture:** Five pure value types (corpus resolution, extraction, name matching, query escaping, ranking) sit under a SQLite FTS5 index of conversation text only. Historical transcripts are backfilled once by a cancellable background walker keyed on per-file byte offsets; live sessions index for free by riding the existing `TranscriptWatcher` poll, which already reads and parses their appended bytes. A borderless `NSPanel` child window renders the results and takes key focus off the Ghostty surface.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit, macOS 14 deployment target, system SQLite (`libsqlite3.tbd`) with FTS5, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-26-smart-search-design.md` (commit `f6cd32e`)

## Global Constraints

- `SWIFT_VERSION: "5.0"` and `MACOSX_DEPLOYMENT_TARGET: "14.0"` are deliberate. Do not raise either. Any API above macOS 14 needs an `#available` fallback — see `FloatingChrome` for the house pattern.
- New code lives in `Sources/FlightDeck/Search/`. Tests in `Tests/FlightDeckTests/`.
- **Comments explain *why* and name the failure they prevent.** This is the house style; a comment restating the code is a review rejection.
- TDD, and **confirm the test fails against the broken code before fixing.** Never weaken an assertion to go green.
- Commits: lowercase, behavioral, imperative (`feat: rank session names above transcript hits`). Body covers mechanism, evidence, and rejected alternatives. Trailer: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Unit tests run with `./scripts/test-unit.sh`. **Never loop `./scripts/smoke.sh`** — see `AGENTS.md` rule 4.
- `@MainActor` async tests use `await fulfillment(of:)`, never `wait(for:)`, which deadlocks.
- Never launch a bundle from `DerivedData/` by executing it; launch with `open`. Never `defaults delete dev.flightdeck.FlightDeck`.
- This checkout is shared by concurrent sessions. Never `git stash`, `git checkout .`, or revert blind.
- Prefer pure logic behind protocol seams; keep SwiftUI out of anything testable.

---

## File Structure

| File | Responsibility |
|---|---|
| `Search/IndexedMessage.swift` | The record the index stores. Pure value type. |
| `Search/TranscriptExtractor.swift` | One JSONL line → zero or more `IndexedMessage`. Pure. |
| `Search/SearchCorpus.swift` | Project paths → transcript directories in scope. Pure. |
| `Search/FTS5Query.swift` | User text → a safe FTS5 MATCH expression. Pure. |
| `Search/SearchIndex.swift` | `SearchIndex` protocol, `TranscriptHit`, `SnippetSentinel`. |
| `Search/SQLiteSearchIndex.swift` | The FTS5 implementation. The only file that sees a `sqlite3*`. |
| `Search/NameMatcher.swift` | Fuzzy subsequence scoring over names. Pure. |
| `Search/SearchResult.swift` | `SearchResult`, `SearchResultKind`, `MatchTier`. Pure. |
| `Search/SearchRanker.swift` | Merges name hits and transcript hits into tier order. Pure. |
| `Search/SearchIndexBuilder.swift` | Backfills history off the main actor. |
| `Search/SearchModel.swift` | `@MainActor ObservableObject`: debounce, dispatch, selection. |
| `Search/SearchActivation.swift` | Pure: result → `Activation` describing what opening it means. |
| `Search/SearchPanel.swift` | The borderless `NSPanel` child window. |
| `Search/SearchOverlayView.swift` | SwiftUI contents: field, rows, motion. |
| `Search/SearchCommands.swift` | The ⌘K menu item. |

Modified: `Sources/FlightDeck/TranscriptWatcher.swift` (live indexing hook), `Sources/FlightDeck/SessionStore.swift` (`openConversation`), `Sources/FlightDeck/GhosttyDefaults.conf` (⌘K unbind), `Sources/FlightDeck/FlightDeckApp.swift` and `AppDelegate.swift` (wiring), `project.yml` (link SQLite).

---

## Task 1: Extract conversation text from a transcript line

**Files:**
- Create: `Sources/FlightDeck/Search/IndexedMessage.swift`
- Create: `Sources/FlightDeck/Search/TranscriptExtractor.swift`
- Test: `Tests/FlightDeckTests/TranscriptExtractorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct IndexedMessage: Equatable, Sendable { let conversationID: String; let role: Role; let text: String; let timestamp: Date? }` with `enum Role: String, Sendable { case user, assistant }`; `enum TranscriptExtractor { static func messages(inLine: String, conversationID: String) -> [IndexedMessage] }`.

The measured basis for this task: conversation text is **5.0%** of a transcript. Everything this extractor drops is the other 95%.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/TranscriptExtractorTests.swift
import XCTest
@testable import FlightDeck

/// What is worth searching inside a transcript, and — mostly — what is not.
///
/// Measured over 60 random transcripts (97 MB): user and assistant text are 5.0% of the
/// bytes. Tool results are 20%, tool inputs 9%, the JSON envelope 54%. This type is the
/// boundary that keeps the other 95% out of the index, so every exclusion below is a
/// deliberate size and relevance decision, not an oversight.
final class TranscriptExtractorTests: XCTestCase {
    private let conversation = "c1"

    private func extract(_ line: String) -> [IndexedMessage] {
        TranscriptExtractor.messages(inLine: line, conversationID: conversation)
    }

    func testAStringContentUserMessageIsExtracted() {
        let line = #"{"type":"user","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":"fix the rename bug"}}"#
        let messages = extract(line)

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "fix the rename bug")
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.conversationID, conversation)
    }

    func testEveryTextBlockOfABlockArrayIsExtracted() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]}}"#
        XCTAssertEqual(extract(line).map(\.text), ["first", "second"])
    }

    /// The 29% of bytes that would change what the feature means: searching `rename` must
    /// find the moment somebody asked for a rename, not every file that contains the word.
    func testToolBlocksYieldNothing() {
        let toolUse = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"old_string":"rename"}}]}}"#
        let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"rename rename rename"}]}}"#

        XCTAssertTrue(extract(toolUse).isEmpty)
        XCTAssertTrue(extract(toolResult).isEmpty)
    }

    /// `isMeta` records are the harness talking to itself — caveats, reminders, the
    /// system-reminder envelope. `ConversationTitle.resolve` already excludes them when
    /// picking a name, for the same reason: they are not something a person said.
    func testMetaAndCompactSummaryRecordsAreExcluded() {
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"caveat: the messages below"}}"#
        let compact = #"{"type":"user","isCompactSummary":true,"message":{"content":"summary of the above"}}"#

        XCTAssertTrue(extract(meta).isEmpty)
        XCTAssertTrue(extract(compact).isEmpty)
    }

    /// A transcript is appended to while we read it, and `TailReader` hands back only
    /// complete lines — but a line can still be malformed for reasons we do not control.
    /// A bad line must cost that line, never the pass.
    func testMalformedLinesAreSkippedRatherThanThrowing() {
        XCTAssertTrue(extract("not json at all").isEmpty)
        XCTAssertTrue(extract("").isEmpty)
        XCTAssertTrue(extract(#"{"type":"user"}"#).isEmpty)
    }

    func testOtherRecordTypesAreIgnored() {
        XCTAssertTrue(extract(#"{"type":"custom-title","customTitle":"rename-break"}"#).isEmpty)
        XCTAssertTrue(extract(#"{"type":"system","content":"rename"}"#).isEmpty)
    }

    /// Recency orders transcript hits (§7), so the record's own timestamp is what the
    /// ranker sorts on. File mtime is only the fallback for records that lack one.
    func testTheRecordTimestampIsParsed() throws {
        let line = #"{"type":"user","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":"hi"}}"#
        let stamp = try XCTUnwrap(extract(line).first?.timestamp)
        let expected = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-26T21:57:19Z")
        )

        XCTAssertEqual(stamp.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
    }

    func testWhitespaceOnlyTextIsNotWorthIndexing() {
        XCTAssertTrue(extract(#"{"type":"user","message":{"content":"   \n  "}}"#).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'TranscriptExtractor' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Search/IndexedMessage.swift
import Foundation

/// One searchable thing somebody said, ready to go into the index.
///
/// Deliberately carries no file path or project: those are properties of *where* the
/// message was found, and `SearchIndexBuilder` knows them. Keeping them off this type is
/// what lets the extractor stay pure and be tested against a bare string.
struct IndexedMessage: Equatable, Sendable {
    enum Role: String, Sendable { case user, assistant }

    let conversationID: String
    let role: Role
    let text: String
    /// The record's own ISO-8601 stamp. nil for records that carry none, in which case the
    /// builder substitutes the transcript file's mtime — a whole-file approximation, which
    /// is why the per-record value is preferred whenever it exists.
    let timestamp: Date?
}
```

```swift
// Sources/FlightDeck/Search/TranscriptExtractor.swift
import Foundation

/// Pulls the conversation out of a transcript line and throws the rest away.
///
/// **Why so little survives.** Sampling 60 transcripts (97 MB): the JSON envelope is 54.5%
/// of the bytes, `tool_result` 19.9%, `tool_use` 8.9%, base64 images 0.9%, and user plus
/// assistant text just 5.0%. Indexing only that 5% turns a 684 MB corpus into ~34 MB, which
/// is what makes the index small enough to stop being the hard part of this feature.
///
/// **Why not the tool blocks.** They are not merely large, they change what searching
/// means: with tool results indexed, `rename` matches every file Claude ever read that
/// contains the word, drowning the one message where somebody asked for a rename. They also
/// wreck the preview, which is a two-line extract that only reads well when it is a
/// sentence a person or an agent actually wrote.
///
/// Pure and synchronous: no file handles, no state. `SearchIndexBuilder` and
/// `TranscriptWatcher` both feed it lines they have already read.
enum TranscriptExtractor {
    /// Shared because `ISO8601DateFormatter` is expensive to construct and this runs once
    /// per record across hundreds of thousands of records during a backfill.
    ///
    /// `.withFractionalSeconds` is required, not optional: claude writes
    /// `2026-08-26T21:57:19.490Z`, and the default option set rejects the milliseconds
    /// outright rather than ignoring them — every timestamp would silently parse as nil and
    /// every transcript hit would fall back to file mtime.
    private static let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func messages(inLine line: String, conversationID: String) -> [IndexedMessage] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let role = IndexedMessage.Role(rawValue: object["type"] as? String ?? "")
        else { return [] }

        // The harness talking to itself rather than a person talking to an agent. Matches
        // the exclusions `ConversationTitle.resolve` already applies when it picks a name
        // out of the first real user message.
        guard object["isMeta"] as? Bool != true,
              object["isCompactSummary"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return [] }

        let timestamp = (object["timestamp"] as? String).flatMap(timestamps.date(from:))

        return texts(inContent: message["content"]).compactMap { text in
            // Trimmed before the emptiness check so a record whose whole content is a
            // newline does not become an index row that can never match anything but still
            // costs a row, a rowid, and a slot in every `LIMIT 200`.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return IndexedMessage(
                conversationID: conversationID, role: role, text: trimmed, timestamp: timestamp
            )
        }
    }

    /// `content` is either a bare string or an array of typed blocks — the same two shapes
    /// `ConversationTitle.userText` handles. Only `text` blocks are taken; `tool_use`,
    /// `tool_result`, `image` and `thinking` are dropped on purpose (see the type comment).
    private static func texts(inContent content: Any?) -> [String] {
        if let text = content as? String { return [text] }
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Measure the real extraction cost**

The spec (§9) calls this out as the one genuinely expensive step and leaves it unmeasured. Measure it now, before anything is built on the assumption.

Write a throwaway harness to the scratchpad — **not** into the repo and **not** into the test suite, which must stay hermetic and fast. It mirrors `TranscriptExtractor.messages`: parse every line, keep user/assistant text only.

```bash
# Build the harness, run it against the real corpus, then delete it.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift <<'SWIFT'
import Foundation
let root = ("~/.claude/projects" as NSString).expandingTildeInPath
var files: [String] = []
for dir in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
    let full = root + "/" + dir
    for f in (try? FileManager.default.contentsOfDirectory(atPath: full)) ?? []
    where f.hasSuffix(".jsonl") { files.append(full + "/" + f) }
}
let start = Date(); var bytes = 0; var kept = 0; var records = 0
for path in files {
    guard let data = FileManager.default.contents(atPath: path) else { continue }
    bytes += data.count
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        guard let d = line.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["type"] as? String, t == "user" || t == "assistant",
              o["isMeta"] as? Bool != true, let m = o["message"] as? [String: Any]
        else { continue }
        if let s = m["content"] as? String { kept += s.count; records += 1 }
        else if let blocks = m["content"] as? [[String: Any]] {
            for b in blocks where b["type"] as? String == "text" {
                kept += (b["text"] as? String ?? "").count; records += 1
            }
        }
    }
}
let elapsed = Date().timeIntervalSince(start)
print(String(format: "%d files, %.0f MB read, %.1f MB kept, %d records, %.1fs (%.0f MB/s)",
             files.count, Double(bytes)/1e6, Double(kept)/1e6, records, elapsed,
             Double(bytes)/1e6/elapsed))
SWIFT
```

Record the numbers in the commit body. The estimate to beat is **under a minute**. If it lands far above, the fix is concurrency across files in Task 7 (`withTaskGroup` over the file list) — not a change to anything else in this plan.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Search/IndexedMessage.swift \
        Sources/FlightDeck/Search/TranscriptExtractor.swift \
        Tests/FlightDeckTests/TranscriptExtractorTests.swift
git commit -m "feat: extract only conversation text from transcript lines

Measured over 60 random transcripts (97 MB): user and assistant text is
5.0% of a transcript. The JSON envelope is 54.5%, tool_result 19.9%,
tool_use 8.9%. Indexing only the 5% turns the 684 MB bounded corpus into
~34 MB, which is what stops the index being the hard part of ⌘K search.

Tool blocks are excluded for relevance as much as size: with tool results
indexed, searching 'rename' matches every file Claude read containing the
word rather than the message where somebody asked for a rename, and the
two-line preview stops being a sentence anyone wrote.

Full-corpus extraction measured at <RECORD ACTUAL NUMBERS HERE>.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Resolve which transcript directories belong to a project

**Files:**
- Create: `Sources/FlightDeck/Search/SearchCorpus.swift`
- Test: `Tests/FlightDeckTests/SearchCorpusTests.swift`

**Interfaces:**
- Consumes: `ClaudeSession.encodedProjectDirName(for:)` from `Sources/FlightDeck/ClaudeSession.swift`.
- Produces: `enum SearchCorpus { static func transcriptDirectoryNames(forProjectAt path: String, listing: (String) -> [String]) -> [String] }` and `static func directories(forProjects paths: [String], projectsRoot: URL, listing: (String) -> [String], exists: (String) -> Bool) -> [SearchCorpus.Entry]`, where `struct Entry: Equatable { let projectPath: String; let directory: URL }`.

**This task exists because of one trap.** `claude`'s directory encoding is lossy and not invertible, so the obvious implementation — prefix-match the encoded project name against `~/.claude/projects` — silently folds a *different* project's history into this one. `~/Projects/flight-deck` encodes to a string that is a genuine prefix of the encoding of `~/Projects/flight-deck-old`. The test below asserts that directly.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SearchCorpusTests.swift
import XCTest
@testable import FlightDeck

/// Which `~/.claude/projects` directories a sidebar project owns.
///
/// `claude` encodes a working directory by replacing every non-ASCII-alphanumeric UTF-16
/// code unit with `-`, which is lossy and not invertible — so the corpus cannot be resolved
/// by decoding names. It is resolved by encoding *real* paths and matching exactly.
final class SearchCorpusTests: XCTestCase {
    /// The trap this whole type exists to avoid. `/w/flight-deck` encodes to
    /// `-w-flight-deck`, which is a prefix of `/w/flight-deck-old`'s `-w-flight-deck-old`.
    /// A prefix match would put another project's entire history into this one's results,
    /// silently and permanently.
    func testASiblingProjectSharingAnEncodedPrefixIsNotIncluded() {
        let names = SearchCorpus.transcriptDirectoryNames(
            forProjectAt: "/w/flight-deck",
            listing: { _ in [] }   // no worktrees
        )

        XCTAssertEqual(names, ["-w-flight-deck"])
        XCTAssertFalse(names.contains("-w-flight-deck-old"))
    }

    /// A worktree is a directory *inside* the project where `claude` genuinely runs and
    /// writes its own transcripts, so its conversations belong to this project. Both
    /// worktree roots the repo uses are covered.
    func testWorktreeDirectoriesAreIncluded() {
        let names = SearchCorpus.transcriptDirectoryNames(
            forProjectAt: "/w/flight-deck",
            listing: { path in
                switch path {
                case "/w/flight-deck/.claude/worktrees": return ["fleet-pairing"]
                case "/w/flight-deck/.superpowers/worktrees": return ["status-enums"]
                default: return []
                }
            }
        )

        XCTAssertEqual(
            Set(names),
            [
                "-w-flight-deck",
                "-w-flight-deck--claude-worktrees-fleet-pairing",
                "-w-flight-deck--superpowers-worktrees-status-enums",
            ]
        )
    }

    /// Each returned directory has to remember which project it came from: a transcript hit
    /// carries its project into the result row, and activation needs it to know which
    /// sidebar project to expand.
    func testEachDirectoryRemembersItsProject() {
        let entries = SearchCorpus.directories(
            forProjects: ["/w/a", "/w/b"],
            projectsRoot: URL(fileURLWithPath: "/root", isDirectory: true),
            listing: { _ in [] },
            exists: { _ in true }
        )

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].projectPath, "/w/a")
        XCTAssertEqual(entries[0].directory, URL(fileURLWithPath: "/root/-w-a", isDirectory: true))
        XCTAssertEqual(entries[1].projectPath, "/w/b")
    }

    /// A project can be open in the sidebar and have no history at all — it was added
    /// today, or every conversation in it was deleted. That is not an error and must not
    /// produce a directory the builder will then fail to open.
    func testDirectoriesThatDoNotExistAreDropped() {
        let entries = SearchCorpus.directories(
            forProjects: ["/w/a"],
            projectsRoot: URL(fileURLWithPath: "/root", isDirectory: true),
            listing: { _ in [] },
            exists: { _ in false }
        )

        XCTAssertTrue(entries.isEmpty)
    }

    /// Two sidebar projects can legitimately resolve to the same directory — nested
    /// projects, or one added twice by different paths that normalise together. The
    /// builder indexes per directory, so a duplicate would index it twice and double every
    /// hit in it.
    func testADirectoryReachedByTwoProjectsIsOnlyReturnedOnce() {
        let entries = SearchCorpus.directories(
            forProjects: ["/w/a", "/w/a"],
            projectsRoot: URL(fileURLWithPath: "/root", isDirectory: true),
            listing: { _ in [] },
            exists: { _ in true }
        )

        XCTAssertEqual(entries.count, 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'SearchCorpus' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Search/SearchCorpus.swift
import Foundation

/// Which `~/.claude/projects` directories belong to the projects open in the sidebar.
///
/// **Why this is not a prefix match.** `ClaudeSession.encodedProjectDirName` replaces every
/// non-ASCII-alphanumeric UTF-16 code unit with `-`, which is lossy: nothing can turn
/// `-w-flight-deck` back into a path. The tempting shortcut is to accept every directory
/// whose name starts with the project's encoding — and that is wrong in a way that is
/// invisible until someone notices results from the wrong repo. `/w/flight-deck` encodes to
/// `-w-flight-deck`, which is a genuine prefix of `/w/flight-deck-old`'s encoding, so the
/// shortcut folds a neighbouring project's whole history into this one's search results.
///
/// So the direction is reversed: enumerate paths that really exist on disk — the project
/// and its worktrees — encode each, and accept only exact name matches.
///
/// Pure. `listing` and `exists` are injected so the rules above are testable without a
/// filesystem.
enum SearchCorpus {
    /// A transcript directory and the sidebar project that owns it.
    struct Entry: Equatable {
        let projectPath: String
        let directory: URL
    }

    /// Where a project's own agents put worktrees. Both are real: `EnterWorktree` uses
    /// `.claude/worktrees`, and the superpowers skills use `.superpowers/worktrees`.
    private static let worktreeRoots = [".claude/worktrees", ".superpowers/worktrees"]

    /// The encoded directory names this project owns: itself, plus one per existing
    /// worktree. Exact names — never prefixes.
    static func transcriptDirectoryNames(
        forProjectAt path: String,
        listing: (String) -> [String]
    ) -> [String] {
        var paths = [path]
        for root in worktreeRoots {
            let rootPath = (path as NSString).appendingPathComponent(root)
            for child in listing(rootPath) {
                paths.append((rootPath as NSString).appendingPathComponent(child))
            }
        }
        return paths.map(ClaudeSession.encodedProjectDirName(for:))
    }

    /// Every in-scope transcript directory across `paths`, each tagged with its project.
    ///
    /// Deduplicated by resolved directory, not by project: two sidebar entries can resolve
    /// to the same directory (nested projects, or the same folder added by two paths that
    /// normalise together), and indexing it twice would double every hit inside it. First
    /// project named wins, so the order of `paths` decides the owner — which matches the
    /// sidebar's own order.
    static func directories(
        forProjects paths: [String],
        projectsRoot: URL,
        listing: (String) -> [String],
        exists: (String) -> Bool
    ) -> [Entry] {
        var seen: Set<URL> = []
        var entries: [Entry] = []

        for path in paths {
            for name in transcriptDirectoryNames(forProjectAt: path, listing: listing) {
                let directory = projectsRoot.appendingPathComponent(name, isDirectory: true)
                guard exists(directory.path), seen.insert(directory).inserted else { continue }
                entries.append(Entry(projectPath: path, directory: directory))
            }
        }
        return entries
    }

    /// The production `listing`: a directory that is absent or unreadable simply has no
    /// worktrees, which is the overwhelmingly common case and not an error.
    static func defaultListing(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Search/SearchCorpus.swift \
        Tests/FlightDeckTests/SearchCorpusTests.swift
git commit -m "feat: resolve a project's transcript directories by exact encoded name

The corpus is the sidebar's projects plus their worktrees. Resolving it by
prefix-matching encoded directory names looks equivalent and is not:
ClaudeSession.encodedProjectDirName is lossy, and /w/flight-deck encodes to
a genuine prefix of /w/flight-deck-old's encoding — so a prefix match puts a
different project's entire history into this one's results, invisibly.

Reversed instead: enumerate real paths (the project, and each existing
worktree under .claude/worktrees and .superpowers/worktrees), encode each,
accept exact matches only. A test asserts the sibling-prefix case directly
because nothing in the UI would reveal it.

Deduplicated by resolved directory so two sidebar entries pointing at one
folder do not index it twice and double every hit inside it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Turn typed text into a safe FTS5 query

**Files:**
- Create: `Sources/FlightDeck/Search/FTS5Query.swift`
- Test: `Tests/FlightDeckTests/FTS5QueryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum FTS5Query { static func match(for input: String) -> String? }` — nil when there is nothing to search for.

FTS5 `MATCH` takes a query *syntax*, not a literal. Unescaped user input either throws `SQLITE_ERROR` (a bare `"`), or silently means something else (`NEAR`, `AND`, `OR`, `NOT`, a leading `-`, a `*`). Every one of those is reachable by typing normal text into a search box.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/FTS5QueryTests.swift
import XCTest
@testable import FlightDeck

/// Typed text is data, never syntax.
///
/// FTS5's MATCH argument is a query language: `NEAR`, `AND`, `OR`, `NOT`, `-`, `*`, `:` and
/// `"` all mean something in it. A search field that passes text straight through either
/// errors out on a stray quote or quietly runs a different query than the one shown. Every
/// token is quoted; only the trailing `*` is ours.
final class FTS5QueryTests: XCTestCase {
    func testEachTokenIsQuotedAndTheLastGetsAPrefixStar() {
        XCTAssertEqual(FTS5Query.match(for: "fix the rename"), #""fix" "the" "rename"*"#)
    }

    /// Prefix matching on the final token is what makes results narrow as you type rather
    /// than appearing only when a word is finished.
    func testASingleTokenIsAPrefixQuery() {
        XCTAssertEqual(FTS5Query.match(for: "renam"), #""renam"*"#)
    }

    /// Punctuation inside a token must survive as literal text. `unicode61` will split it
    /// into terms itself; what matters is that FTS5 never reads the `.` as syntax.
    func testPunctuationInsideATokenIsPreserved() {
        XCTAssertEqual(FTS5Query.match(for: "SessionStore.rename"), #""SessionStore.rename"*"#)
    }

    /// The crash case. A bare double quote terminates the quoted string and leaves FTS5
    /// parsing the remainder as syntax; doubling it is FTS5's own escape.
    func testEmbeddedQuotesAreDoubledRatherThanTerminatingTheToken() {
        XCTAssertEqual(FTS5Query.match(for: #"say "hi""#), #""say" ""hi"""*"#)
    }

    /// Reserved words are only reserved when bare. Quoted, they are the words the user
    /// typed — which is what someone searching for the phrase "near miss" means.
    func testReservedWordsAreNeutralisedByQuoting() {
        XCTAssertEqual(FTS5Query.match(for: "near miss"), #""near" "miss"*"#)
        XCTAssertEqual(FTS5Query.match(for: "this AND that"), #""this" "AND" "that"*"#)
    }

    /// A leading `-` is FTS5 negation. Someone typing a flag name is not asking to exclude
    /// anything.
    func testALeadingHyphenIsNotNegation() {
        XCTAssertEqual(FTS5Query.match(for: "--resume"), #""--resume"*"#)
    }

    /// A star the user typed is a literal star, not a second prefix operator — otherwise
    /// `a*b` becomes a syntax error.
    func testUserSuppliedStarsAreLiteral() {
        XCTAssertEqual(FTS5Query.match(for: "a*b"), #""a*b"*"#)
    }

    /// Nothing to search for is not an error and not an empty match-everything query — it
    /// is the empty-query state, which shows recent sessions instead (§7).
    func testBlankInputProducesNoQuery() {
        XCTAssertNil(FTS5Query.match(for: ""))
        XCTAssertNil(FTS5Query.match(for: "   \n\t "))
    }

    func testRunsOfWhitespaceCollapse() {
        XCTAssertEqual(FTS5Query.match(for: "  fix   rename  "), #""fix" "rename"*"#)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'FTS5Query' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Search/FTS5Query.swift
import Foundation

/// Builds the `MATCH` expression for a typed query.
///
/// **Why this is not string interpolation.** FTS5's MATCH argument is a query language, not
/// a literal. `NEAR`, `AND`, `OR`, `NOT`, a leading `-`, a trailing `*` and `:` are all
/// operators in it, and an unbalanced `"` is a syntax error that fails the whole statement.
/// A search field wired straight to MATCH therefore has two failure modes reachable by
/// typing ordinary text: it errors on a quote, and it quietly runs a different query than
/// the one on screen for anything containing a reserved word.
///
/// Quoting every token removes both. Inside an FTS5 string literal the only special
/// character is `"`, escaped by doubling it — exactly like SQL.
///
/// The single `*` this type adds itself, on the final token, is what makes results narrow
/// while you are still typing a word.
enum FTS5Query {
    static func match(for input: String) -> String? {
        let tokens = input.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }

        let quoted = tokens.map { token in
            "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        // Only the last token is a prefix. Starring the earlier ones would match far more
        // than the user typed — "fi" would hit "file", "finish", "fix" — and the earlier
        // words in a multi-word query are the ones already finished.
        return quoted.dropLast().joined(separator: " ")
            + (quoted.count > 1 ? " " : "")
            + quoted[quoted.count - 1] + "*"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Search/FTS5Query.swift \
        Tests/FlightDeckTests/FTS5QueryTests.swift
git commit -m "feat: quote typed text into a safe FTS5 match expression

FTS5's MATCH argument is a query language, so a search field wired straight
to it has two failure modes reachable by typing ordinary text: an unbalanced
double quote fails the statement outright, and NEAR/AND/OR/NOT/-/*/: quietly
run a different query than the one on screen.

Every token is wrapped in an FTS5 string literal with embedded quotes
doubled, which neutralises all of it. The one operator we add is a trailing
star on the final token, so results narrow while a word is still being
typed; earlier tokens are left unstarred because they are already finished
and starring them would match far more than was typed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Score a name against a typed query

**Files:**
- Create: `Sources/FlightDeck/Search/NameMatcher.swift`
- Test: `Tests/FlightDeckTests/NameMatcherTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum NameMatcher { static func score(_ candidate: String, against query: String) -> NameMatch? }` and `struct NameMatch: Equatable { let tier: MatchTier; let matchedRanges: [Range<String.Index>] }`. `MatchTier` is defined here as `enum MatchTier: Int, Comparable { case exact = 0, prefix = 1, fuzzy = 2, transcript = 3 }`.

Names are the small, fast half: at most a few hundred candidates, matched in memory on every keystroke. `matchedRanges` is what the row highlights.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/NameMatcherTests.swift
import XCTest
@testable import FlightDeck

/// Scoring one name against a typed query.
///
/// Tiers, not a single blended score: an exact match and a loose subsequence match are
/// different *kinds* of answer, and collapsing them into one number is what makes a search
/// list feel arbitrary. `SearchRanker` orders by tier first and recency second.
final class NameMatcherTests: XCTestCase {
    func testAnExactMatchIsTheTopTier() {
        XCTAssertEqual(NameMatcher.score("rename-break", against: "rename-break")?.tier, .exact)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(NameMatcher.score("Rename-Break", against: "rename-break")?.tier, .exact)
        XCTAssertEqual(NameMatcher.score("rename-break", against: "RENAME")?.tier, .prefix)
    }

    func testAPrefixOutranksAFuzzyMatch() {
        let prefix = NameMatcher.score("rename-break", against: "rename")
        let fuzzy = NameMatcher.score("rename-break", against: "rnmbk")

        XCTAssertEqual(prefix?.tier, .prefix)
        XCTAssertEqual(fuzzy?.tier, .fuzzy)
        XCTAssertLessThan(prefix!.tier, fuzzy!.tier)
    }

    /// Subsequence matching is the whole point of "fuzzy": the characters appear in order
    /// but not adjacently, which is how people type abbreviations.
    func testCharactersMatchingInOrderButNotAdjacentlyAreAFuzzyMatch() {
        XCTAssertEqual(NameMatcher.score("session-menu", against: "ssnmn")?.tier, .fuzzy)
    }

    func testCharactersOutOfOrderDoNotMatch() {
        XCTAssertNil(NameMatcher.score("session-menu", against: "unem"))
    }

    func testAQueryLongerThanTheCandidateCannotMatch() {
        XCTAssertNil(NameMatcher.score("wifi", against: "wifi-network"))
    }

    /// The ranges the row underlines. Without them a fuzzy hit looks like it matched
    /// nothing, which reads as a bug.
    func testMatchedRangesCoverEveryQueryCharacter() {
        let match = NameMatcher.score("session-menu", against: "smenu")
        let matched = match?.matchedRanges.map { String("session-menu"[$0]) }.joined()

        XCTAssertEqual(matched, "smenu")
    }

    func testAnExactMatchHighlightsTheWholeName() {
        let match = NameMatcher.score("wifi", against: "wifi")
        XCTAssertEqual(match?.matchedRanges.count, 1)
        XCTAssertEqual(match.map { String("wifi"[$0.matchedRanges[0]]) }, "wifi")
    }

    /// An empty query is the empty-query state, which lists recent sessions rather than
    /// matching. It must not report every name as a match.
    func testAnEmptyQueryMatchesNothing() {
        XCTAssertNil(NameMatcher.score("anything", against: ""))
    }

    /// A one-character query subsequence-matches almost every name, which would bury the
    /// exact and prefix hits under noise on the very first keystroke.
    func testASingleCharacterQueryOnlyMatchesAsAPrefix() {
        XCTAssertEqual(NameMatcher.score("rename-break", against: "r")?.tier, .prefix)
        XCTAssertNil(NameMatcher.score("session-menu", against: "r"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'NameMatcher' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Search/NameMatcher.swift
import Foundation

/// How well a query matches a name, as a tier rather than a score.
///
/// Shared with transcript hits, which always occupy the last tier — see `SearchRanker`.
/// `Comparable` on the raw value so "better" is `<`, which reads correctly at every call
/// site (`.exact < .fuzzy`).
enum MatchTier: Int, Comparable, Sendable {
    case exact = 0
    case prefix = 1
    case fuzzy = 2
    case transcript = 3

    static func < (lhs: MatchTier, rhs: MatchTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One name's match, and where it matched.
struct NameMatch: Equatable {
    let tier: MatchTier
    /// Ranges into the *original* candidate, so the row can underline them without
    /// re-deriving anything from a lowercased copy.
    let matchedRanges: [Range<String.Index>]
}

/// Fuzzy matching for session, project and conversation names.
///
/// This is the cheap half of search: a few hundred candidates, rescored on every keystroke
/// with no I/O, which is what lets name results update with no debounce at all while
/// transcript results wait 90 ms behind them.
///
/// **Why tiers instead of a score.** A single blended number has to answer "is an exact
/// match from March better than a fuzzy match from ten minutes ago" with a magic constant,
/// and every such constant is wrong for somebody. Tiering the *kind* of match and letting
/// recency order within a tier makes both halves explainable.
enum NameMatcher {
    /// Below this length a subsequence match is meaningless — one or two characters appear
    /// in order inside almost any name, so fuzzy matching on the first keystroke would bury
    /// the exact and prefix hits under the entire fleet.
    private static let minimumFuzzyQueryLength = 3

    static func score(_ candidate: String, against query: String) -> NameMatch? {
        let needle = query.lowercased()
        let haystack = candidate.lowercased()
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }

        if haystack == needle {
            return NameMatch(tier: .exact, matchedRanges: [candidate.startIndex..<candidate.endIndex])
        }
        if haystack.hasPrefix(needle) {
            let end = candidate.index(candidate.startIndex, offsetBy: needle.count)
            return NameMatch(tier: .prefix, matchedRanges: [candidate.startIndex..<end])
        }
        guard needle.count >= minimumFuzzyQueryLength,
              let ranges = subsequenceRanges(of: needle, in: haystack, mappedInto: candidate)
        else { return nil }

        return NameMatch(tier: .fuzzy, matchedRanges: ranges)
    }

    /// Greedy left-to-right subsequence walk: take the first occurrence of each query
    /// character at or after the previous one.
    ///
    /// Greedy is not optimal — it will not find the *tightest* run of matches — but it is
    /// linear, and the alternative (searching for the best alignment) buys a slightly nicer
    /// underline for real cost on every keystroke. Match/no-match is identical either way,
    /// which is what the tier depends on.
    ///
    /// `haystack` is the lowercased copy that is walked; `original` is what the returned
    /// ranges index into. Lowercasing can change length in general, so the two are walked in
    /// step rather than by offsetting into `original` afterwards.
    private static func subsequenceRanges(
        of needle: String, in haystack: String, mappedInto original: String
    ) -> [Range<String.Index>]? {
        var ranges: [Range<String.Index>] = []
        var hayIndex = haystack.startIndex
        var originalIndex = original.startIndex
        var needleIndex = needle.startIndex

        while needleIndex < needle.endIndex, hayIndex < haystack.endIndex {
            if haystack[hayIndex] == needle[needleIndex] {
                let next = original.index(after: originalIndex)
                // Extend the previous range when this character continues it, so an
                // adjacent run underlines as one span rather than as separate letters.
                if let last = ranges.last, last.upperBound == originalIndex {
                    ranges[ranges.count - 1] = last.lowerBound..<next
                } else {
                    ranges.append(originalIndex..<next)
                }
                needleIndex = needle.index(after: needleIndex)
            }
            hayIndex = haystack.index(after: hayIndex)
            // Guarded because `original` can run out before `haystack` if lowercasing
            // lengthened the string (ß → ss); the ranges built so far stay valid.
            guard originalIndex < original.endIndex else { break }
            originalIndex = original.index(after: originalIndex)
        }
        return needleIndex == needle.endIndex ? ranges : nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Search/NameMatcher.swift \
        Tests/FlightDeckTests/NameMatcherTests.swift
git commit -m "feat: tier name matches as exact, prefix, or fuzzy subsequence

Names are the cheap half of ⌘K: a few hundred candidates rescored on every
keystroke with no I/O, which is what lets them update with no debounce while
transcript hits wait behind a 90 ms one.

Tiers rather than a blended score. A single number has to answer 'is an exact
match from March better than a fuzzy one from ten minutes ago' with a magic
constant that is wrong for somebody; tiering the kind of match and letting
recency order within the tier makes both halves explainable.

Fuzzy matching is floored at three characters. One or two characters appear
in order inside nearly every name, so subsequence matching on the first
keystroke buried the exact and prefix hits under the whole fleet.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Merge name and transcript hits into one ranked list

**Files:**
- Create: `Sources/FlightDeck/Search/SearchResult.swift`
- Create: `Sources/FlightDeck/Search/SearchRanker.swift`
- Test: `Tests/FlightDeckTests/SearchRankerTests.swift`

**Interfaces:**
- Consumes: `MatchTier`, `NameMatch` (Task 4).
- Produces:
  - `struct TranscriptHit: Equatable, Sendable { let conversationID: String; let projectPath: String; let conversationName: String; let snippet: String; let timestamp: Date }`
  - `struct NameCandidate: Equatable { let id: SearchResult.ID; let kind: SearchResultKind; let name: String; let projectPath: String; let projectName: String; let lastActivity: Date; let conversationID: String? }`
  - `enum SearchResultKind: Equatable { case session(UUID), project, conversation(String) }`
  - `struct SearchResult: Identifiable, Equatable { let id: String; let kind: SearchResultKind; let title: String; let projectName: String; let projectPath: String; let tier: MatchTier; let recency: Date; let highlightedRanges: [Range<String.Index>]; let snippet: String?; let conversationID: String? }`
  - `enum SearchRanker { static func rank(names: [NameCandidate], query: String, transcripts: [TranscriptHit]) -> [SearchResult] }`

This is the type that makes "recency breaks every tie" true, and the one whose ordering a fresh reader will most want to argue with — so the tests are the specification.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SearchRankerTests.swift
import XCTest
@testable import FlightDeck

/// The order results come back in.
///
/// Two rules, in this order: match quality tiers the list, and within a tier the most
/// recently active thing wins. Scores are never compared across tiers — a BM25 score and a
/// fuzzy-subsequence score are not on the same scale.
final class SearchRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func session(
        _ name: String, project: String = "flight-deck", activity: TimeInterval
    ) -> NameCandidate {
        NameCandidate(
            id: name, kind: .session(UUID()), name: name,
            projectPath: "/w/\(project)", projectName: project,
            lastActivity: ago(activity), conversationID: nil
        )
    }

    private func project(_ name: String, activity: TimeInterval) -> NameCandidate {
        NameCandidate(
            id: "project-\(name)", kind: .project, name: name,
            projectPath: "/w/\(name)", projectName: name,
            lastActivity: ago(activity), conversationID: nil
        )
    }

    private func hit(_ conversation: String, snippet: String, activity: TimeInterval) -> TranscriptHit {
        TranscriptHit(
            conversationID: conversation, projectPath: "/w/flight-deck",
            conversationName: conversation, snippet: snippet, timestamp: ago(activity)
        )
    }

    /// The headline rule. An exact match that is weeks old still beats a fuzzy match from a
    /// minute ago, because quality tiers the list before recency touches it.
    func testTierBeatsRecency() {
        let results = SearchRanker.rank(
            names: [
                session("rnm-brk", activity: 60),          // fuzzy, one minute old
                session("rename", activity: 60 * 60 * 24 * 30), // exact, a month old
            ],
            query: "rename",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.title), ["rename", "rnm-brk"])
    }

    /// The rule the user chose: within one tier, the thing touched most recently wins.
    func testRecencyOrdersWithinATier() {
        let results = SearchRanker.rank(
            names: [
                session("rename-old", activity: 60 * 60 * 24),
                session("rename-new", activity: 60),
            ],
            query: "rename",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.title), ["rename-new", "rename-old"])
    }

    /// "Prioritizes session and project names" is a hard rule, not a nudge: no transcript
    /// hit, however fresh or however well it matches, may outrank any name match.
    func testNoTranscriptHitOutranksAnyNameMatch() {
        let results = SearchRanker.rank(
            names: [session("rnm", activity: 60 * 60 * 24 * 365)],  // fuzzy, a year old
            query: "rename",
            transcripts: [hit("mobile-ui", snippet: "the rename bug", activity: 1)]
        )

        XCTAssertEqual(results.first?.title, "rnm")
        XCTAssertEqual(results.last?.kind, .conversation("mobile-ui"))
    }

    /// Sessions before projects at equal tier: the deck is session-centric and activating a
    /// result opens a session, so a session is the more likely intent.
    func testSessionsRankAboveProjectsAtTheSameTier() {
        let results = SearchRanker.rank(
            names: [
                project("rename", activity: 1),          // more recent
                session("rename", activity: 60 * 60),
            ],
            query: "rename",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.kind), [.session(results[0].kindSessionID!), .project])
    }

    /// Transcript hits carry the FTS5 snippet; name matches carry highlight ranges. The row
    /// draws one or the other, so a result must never arrive with neither.
    func testTranscriptHitsCarryASnippetAndNameMatchesCarryRanges() {
        let results = SearchRanker.rank(
            names: [session("rename-break", activity: 1)],
            query: "rename",
            transcripts: [hit("mobile-ui", snippet: "don't fire a rename", activity: 2)]
        )

        XCTAssertNil(results[0].snippet)
        XCTAssertFalse(results[0].highlightedRanges.isEmpty)
        XCTAssertEqual(results[1].snippet, "don't fire a rename")
        XCTAssertTrue(results[1].highlightedRanges.isEmpty)
    }

    func testNamesThatDoNotMatchAreExcluded() {
        let results = SearchRanker.rank(
            names: [session("wifi", activity: 1), session("rename", activity: 2)],
            query: "rename",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.title), ["rename"])
    }

    /// The empty-query state: every session, most recent first, so ⌘K-Return returns you to
    /// what you were just doing. Projects and transcript hits stay out — an empty query has
    /// nothing for FTS5 to match, and a list of every project is not what that gesture means.
    func testAnEmptyQueryListsSessionsByRecency() {
        let results = SearchRanker.rank(
            names: [
                session("older", activity: 60 * 60),
                project("a-project", activity: 1),
                session("newer", activity: 60),
            ],
            query: "",
            transcripts: []
        )

        XCTAssertEqual(results.map(\.title), ["newer", "older"])
    }

    /// Ordering must be total. Two candidates identical in tier and timestamp would
    /// otherwise sort unstably, and a list that reshuffles between identical keystrokes is
    /// exactly the jitter the panel's stable-selection property is meant to prevent.
    func testOrderingIsDeterministicWhenTierAndRecencyTie() {
        let stamp: TimeInterval = 60
        let first = SearchRanker.rank(
            names: [session("rename-a", activity: stamp), session("rename-b", activity: stamp)],
            query: "rename", transcripts: []
        )
        let second = SearchRanker.rank(
            names: [session("rename-b", activity: stamp), session("rename-a", activity: stamp)],
            query: "rename", transcripts: []
        )

        XCTAssertEqual(first.map(\.title), second.map(\.title))
    }
}

private extension SearchResult {
    /// Test-only reach into the associated value, so the session-vs-project assertion above
    /// can be written without spelling out a UUID it does not care about.
    var kindSessionID: UUID? {
        if case .session(let id) = kind { return id }
        return nil
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'SearchRanker' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Search/SearchResult.swift
import Foundation

/// What a result *is*, which decides its icon and what activating it does.
enum SearchResultKind: Equatable, Sendable {
    /// A tab open in the deck right now. Activating it selects that tab.
    case session(UUID)
    /// A project in the sidebar. Activating it selects the project's first session.
    case project
    /// A conversation on disk with no tab attached. Activating it resumes into a new tab.
    case conversation(String)
}

/// One match found inside a conversation, straight out of the index.
///
/// `snippet` arrives with the sentinel markers FTS5 was asked for; the view turns those into
/// an `AttributedString`. Keeping them as markers rather than as ranges means the index does
/// not have to reason about `String.Index` across a SQLite boundary.
struct TranscriptHit: Equatable, Sendable {
    let conversationID: String
    let projectPath: String
    let conversationName: String
    let snippet: String
    let timestamp: Date
}

/// A name the ranker may match against: a session, a project, or a past conversation.
///
/// Flattened deliberately — the ranker takes one array rather than reaching into
/// `SessionStore`, which is what keeps it pure and instantly testable.
struct NameCandidate: Equatable {
    let id: String
    let kind: SearchResultKind
    let name: String
    let projectPath: String
    let projectName: String
    /// For a live session this is its transcript's mtime, which moves whenever the agent
    /// writes. There is no per-session activity timestamp in the model, and adding one
    /// would duplicate what the file already records exactly.
    let lastActivity: Date
    let conversationID: String?
}

/// A row in the overlay.
struct SearchResult: Identifiable, Equatable {
    let id: String
    let kind: SearchResultKind
    let title: String
    let projectName: String
    let projectPath: String
    let tier: MatchTier
    let recency: Date
    /// Where the query matched inside `title`. Empty for transcript hits, whose evidence is
    /// in `snippet` instead.
    let highlightedRanges: [Range<String.Index>]
    /// The two-line extract, with FTS5 sentinels. nil for name matches.
    let snippet: String?
    let conversationID: String?
}
```

```swift
// Sources/FlightDeck/Search/SearchRanker.swift
import Foundation

/// Merges the two halves of search into the one list the overlay draws.
///
/// **The two rules, in order.** Match quality tiers the list; within a tier the most
/// recently active thing wins. That is the whole ordering, and it is deliberately not a
/// blended score: BM25 and fuzzy-subsequence scores are not on the same scale, and any
/// constant that mixed them would be a magic number nobody could defend.
///
/// **Where BM25 went.** It still decides *membership* in the transcript tier — the index
/// applies `LIMIT 200` ordered by BM25, so relevance chooses which 200 of possibly thousands
/// of matches are worth showing. This type then orders those 200 by recency. Relevance
/// selects; recency orders.
///
/// **The property this preserves.** Transcript hits are always the last tier, so results
/// arriving late from the debounced index query can only ever append *below* what is already
/// on screen. The highlighted row can never be shoved out from under the user by results
/// landing — which is why `SearchModel` can track selection by identity and have it hold.
enum SearchRanker {
    static func rank(
        names: [NameCandidate], query: String, transcripts: [TranscriptHit]
    ) -> [SearchResult] {
        // Nothing typed: the deck, most recent first. Projects are left out because a list
        // of every project is not what ⌘K-Return means, and transcripts because an empty
        // query gives FTS5 nothing to match — see `FTS5Query.match` returning nil.
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return names
                .filter { if case .session = $0.kind { return true } else { return false } }
                .sorted(by: recencyThenID)
                .map { SearchResult(candidate: $0, tier: .exact, ranges: []) }
        }

        var results: [SearchResult] = names.compactMap { candidate in
            guard let match = NameMatcher.score(candidate.name, against: query) else { return nil }
            return SearchResult(candidate: candidate, tier: match.tier, ranges: match.matchedRanges)
        }

        results += transcripts.map { hit in
            SearchResult(
                id: "\(hit.conversationID)#\(hit.timestamp.timeIntervalSince1970)",
                kind: .conversation(hit.conversationID),
                title: hit.conversationName,
                projectName: URL(fileURLWithPath: hit.projectPath).lastPathComponent,
                projectPath: hit.projectPath,
                tier: .transcript,
                recency: hit.timestamp,
                highlightedRanges: [],
                snippet: hit.snippet,
                conversationID: hit.conversationID
            )
        }

        return results.sorted { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            // Sessions before projects at equal tier: the deck is session-centric, and
            // activating a result opens a session either way, so a session is the likelier
            // intent when both names match equally well.
            if lhs.kindRank != rhs.kindRank { return lhs.kindRank < rhs.kindRank }
            if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
            // Total order. Without this, two candidates identical in tier and timestamp sort
            // unstably and the list reshuffles between identical keystrokes — exactly the
            // jitter the stable-selection property exists to prevent.
            return lhs.id < rhs.id
        }
    }

    private static func recencyThenID(_ lhs: NameCandidate, _ rhs: NameCandidate) -> Bool {
        lhs.lastActivity != rhs.lastActivity ? lhs.lastActivity > rhs.lastActivity : lhs.id < rhs.id
    }
}

private extension SearchResult {
    init(candidate: NameCandidate, tier: MatchTier, ranges: [Range<String.Index>]) {
        self.init(
            id: candidate.id, kind: candidate.kind, title: candidate.name,
            projectName: candidate.projectName, projectPath: candidate.projectPath,
            tier: tier, recency: candidate.lastActivity, highlightedRanges: ranges,
            snippet: nil, conversationID: candidate.conversationID
        )
    }

    /// Sessions, then projects, then conversations. Only consulted within a tier.
    var kindRank: Int {
        switch kind {
        case .session: return 0
        case .project: return 1
        case .conversation: return 2
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Search/SearchResult.swift \
        Sources/FlightDeck/Search/SearchRanker.swift \
        Tests/FlightDeckTests/SearchRankerTests.swift
git commit -m "feat: rank by match tier, then by recency within the tier

Two rules and no blended score: quality tiers the list, and the most recently
active thing wins inside a tier. A BM25 score and a fuzzy-subsequence score
are not on the same scale, so any constant mixing them would be indefensible.
BM25 keeps deciding membership in the transcript tier — the index limits to
200 by relevance — and recency then orders those. Relevance selects, recency
orders.

Transcript hits are always the last tier, which is load-bearing beyond
ordering: results arriving late from the debounced index query can only
append below what is already drawn, so the highlighted row can never be
shoved out from under the user.

Sorting falls through to result id so the order is total. Without it two
candidates identical in tier and timestamp sort unstably and the list
reshuffles between identical keystrokes.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: The FTS5 index

**Files:**
- Create: `Sources/FlightDeck/Search/SearchIndex.swift`
- Create: `Sources/FlightDeck/Search/SQLiteSearchIndex.swift`
- Modify: `project.yml` (add `- sdk: libsqlite3.tbd` to the `FlightDeck` target's `dependencies`)
- Test: `Tests/FlightDeckTests/SQLiteSearchIndexTests.swift`

**Interfaces:**
- Consumes: `IndexedMessage` (Task 1), `TranscriptHit` (Task 5), `FTS5Query` (Task 3).
- Produces:

```swift
protocol SearchIndex: AnyObject {
    func ingest(_ messages: [IndexedMessage], from source: URL, projectPath: String, offset: UInt64) throws
    func readOffset(for source: URL) -> UInt64
    func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit]
    func conversationNames() throws -> [String: IndexedConversation]
    func prune(keepingSources: Set<URL>, projects: Set<String>) throws
    func messageCount(forConversation id: String) throws -> Int
}
struct IndexedConversation: Equatable, Sendable { let name: String; let projectPath: String }
enum SnippetSentinel { static let open: Character; static let close: Character }
final class SQLiteSearchIndex: SearchIndex { init(at url: URL) throws; static let schemaVersion = 1 }
```

- [ ] **Step 1: Link SQLite and confirm the build still works**

```bash
# In project.yml, under targets.FlightDeck.dependencies, alongside the existing entries:
#   - sdk: libsqlite3.tbd
./scripts/build.sh 2>&1 | tail -5
```
Expected: BUILD SUCCEEDED. FTS5 is compiled into the system SQLite (verified: 3.51.0); no vendored copy is needed.

- [ ] **Step 2: Write the failing tests**

```swift
// Tests/FlightDeckTests/SQLiteSearchIndexTests.swift
import XCTest
@testable import FlightDeck

/// The index against a real SQLite file in a temp directory.
///
/// Not a fake: FTS5's tokenizer, prefix matching and `snippet()` are the behaviour under
/// test, and a stub of them would assert nothing about whether search actually works.
final class SQLiteSearchIndexTests: XCTestCase {
    private var directory: URL!
    private var index: SQLiteSearchIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try SQLiteSearchIndex(at: directory.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func source(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private func message(
        _ text: String, conversation: String = "c1", at seconds: TimeInterval = 0
    ) -> IndexedMessage {
        IndexedMessage(
            conversationID: conversation, role: .user, text: text,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 + seconds)
        )
    }

    func testAnIngestedMessageIsFoundByAWordInIt() throws {
        try index.ingest(
            [message("don't fire a rename when the session already has the name")],
            from: source("a.jsonl"), projectPath: "/w/fd", offset: 100
        )

        let hits = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10)

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.conversationID, "c1")
        XCTAssertEqual(hits.first?.projectPath, "/w/fd")
    }

    /// The preview the user asked for: two lines with the matched terms marked. The markers
    /// are sentinels rather than ranges so nothing has to carry a `String.Index` across the
    /// SQLite boundary.
    func testTheSnippetMarksTheMatchedTermWithSentinels() throws {
        try index.ingest(
            [message("don't fire a rename when the session already has the given name")],
            from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )

        let snippet = try XCTUnwrap(
            index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).first?.snippet
        )

        XCTAssertTrue(snippet.contains(SnippetSentinel.open))
        XCTAssertTrue(snippet.contains(SnippetSentinel.close))
        let marked = snippet.split(separator: SnippetSentinel.open)
            .dropFirst().compactMap { $0.split(separator: SnippetSentinel.close).first }
        XCTAssertEqual(marked.map(String.init), ["rename"])
    }

    /// Prefix matching is what makes results narrow while a word is still being typed.
    func testAPrefixQueryMatchesAPartialWord() throws {
        try index.ingest(
            [message("the rename bug")], from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )

        XCTAssertEqual(try index.search(#""renam"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// The corpus is bounded by the sidebar. A project closed since the last prune must not
    /// leak its conversations into results.
    func testResultsAreConfinedToTheNamedProjects() throws {
        try index.ingest(
            [message("rename", conversation: "c1")],
            from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )
        try index.ingest(
            [message("rename", conversation: "c2")],
            from: source("b.jsonl"), projectPath: "/w/other", offset: 1
        )

        let hits = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10)

        XCTAssertEqual(hits.map(\.conversationID), ["c1"])
    }

    /// The builder resumes from this. It must survive the process going away, which is what
    /// makes a cancelled backfill cost nothing on the next launch.
    func testTheReadOffsetRoundTripsAndSurvivesReopening() throws {
        try index.ingest([message("hi")], from: source("a.jsonl"), projectPath: "/w/fd", offset: 4096)
        XCTAssertEqual(index.readOffset(for: source("a.jsonl")), 4096)

        let url = directory.appendingPathComponent("index.sqlite")
        index = nil
        let reopened = try SQLiteSearchIndex(at: url)

        XCTAssertEqual(reopened.readOffset(for: source("a.jsonl")), 4096)
    }

    func testAnUnknownSourceStartsAtZero() {
        XCTAssertEqual(index.readOffset(for: source("never-seen.jsonl")), 0)
    }

    /// A conversation deleted on disk, or a project removed from the sidebar, must stop
    /// producing results — otherwise the index only ever grows and starts answering with
    /// things the user cannot open.
    func testPruningDropsSourcesAndProjectsThatAreNoLongerInScope() throws {
        try index.ingest(
            [message("rename", conversation: "c1")],
            from: source("keep.jsonl"), projectPath: "/w/fd", offset: 1
        )
        try index.ingest(
            [message("rename", conversation: "c2")],
            from: source("drop.jsonl"), projectPath: "/w/gone", offset: 1
        )

        try index.prune(keepingSources: [source("keep.jsonl")], projects: ["/w/fd"])

        let hits = try index.search(#""rename"*"#, projects: ["/w/fd", "/w/gone"], limit: 10)
        XCTAssertEqual(hits.map(\.conversationID), ["c1"])
        XCTAssertEqual(index.readOffset(for: source("drop.jsonl")), 0)
    }

    /// Re-ingesting a file from offset 0 — a transcript replaced under the same path, which
    /// `TailReader`'s `.restartFromZero` policy already handles — must replace its rows
    /// rather than double every message in it.
    func testReingestingFromZeroReplacesRatherThanDuplicates() throws {
        let file = source("a.jsonl")
        try index.ingest([message("rename")], from: file, projectPath: "/w/fd", offset: 50)
        try index.ingest([message("rename")], from: file, projectPath: "/w/fd", offset: 0)

        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// Recency orders the transcript tier, so the timestamp has to survive the round trip
    /// intact rather than being approximated by insertion order.
    func testTimestampsRoundTrip() throws {
        try index.ingest(
            [message("rename", at: 1234)], from: source("a.jsonl"), projectPath: "/w/fd", offset: 1
        )

        let hit = try XCTUnwrap(index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).first)
        XCTAssertEqual(hit.timestamp.timeIntervalSince1970, 1_800_001_234, accuracy: 0.001)
    }

    /// Opening a file written by an older schema must not throw and must not return
    /// nonsense — the index is a cache, so the answer is to discard and rebuild.
    func testAnIncompatibleSchemaIsDiscardedRatherThanFailingToOpen() throws {
        let url = directory.appendingPathComponent("stale.sqlite")
        try Data("not a sqlite database at all".utf8).write(to: url)

        let rebuilt = try SQLiteSearchIndex(at: url)

        XCTAssertEqual(rebuilt.readOffset(for: source("a.jsonl")), 0)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'SQLiteSearchIndex' in scope`.

- [ ] **Step 4: Write the protocol and sentinels**

```swift
// Sources/FlightDeck/Search/SearchIndex.swift
import Foundation

/// The markers `snippet()` wraps matched terms in.
///
/// U+0002 and U+0003 (START OF TEXT / END OF TEXT) rather than something like `<b>`: the
/// text being marked up is arbitrary conversation content, and any printable delimiter is
/// something a message could legitimately contain — an agent discussing HTML would produce
/// snippets that highlight the wrong span. `TranscriptExtractor` cannot emit these because
/// they are control characters, which is what makes them unambiguous.
enum SnippetSentinel {
    static let open: Character = "\u{2}"
    static let close: Character = "\u{3}"
}

/// What the index knows about a conversation: its newest name, and which project it
/// belongs to. Defined here rather than beside its consumer so the protocol, the SQLite
/// implementation and `SearchCandidates` all name one type.
struct IndexedConversation: Equatable, Sendable {
    let name: String
    let projectPath: String
}

/// Storage for the searchable half of transcripts.
///
/// A protocol so `SearchModel` can be tested against an in-memory stub while the real thing
/// talks to SQLite. Everything here is synchronous and throwing; callers run it off the main
/// actor.
protocol SearchIndex: AnyObject {
    /// Adds `messages`, recording that `source` has now been read through `offset`.
    ///
    /// An `offset` of 0 means the file restarted (see `TailTruncationPolicy.restartFromZero`)
    /// and this source's existing rows are replaced rather than added to.
    func ingest(
        _ messages: [IndexedMessage], from source: URL, projectPath: String, offset: UInt64
    ) throws

    /// Where reading `source` should resume. 0 for a file never seen.
    func readOffset(for source: URL) -> UInt64

    /// `query` is an FTS5 MATCH expression from `FTS5Query.match`, never raw user text.
    func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit]

    /// Conversation id → its name and project, for rows and for name matching over
    /// conversations that have no open tab.
    func conversationNames() throws -> [String: IndexedConversation]

    /// Drops everything outside the current scope.
    func prune(keepingSources: Set<URL>, projects: Set<String>) throws

    /// Shown in a name-match row when known. Cheap enough to call per visible row.
    func messageCount(forConversation id: String) throws -> Int
}
```

- [ ] **Step 5: Write the SQLite implementation**

```swift
// Sources/FlightDeck/Search/SQLiteSearchIndex.swift
import Foundation
import SQLite3

/// FTS5 over conversation text.
///
/// **Why SQLite rather than an index of our own.** `snippet()` returns exactly the
/// two-line, term-marked extract the overlay row is specified to show, `bm25()` ranks, and
/// prefix queries work — all of it battle-tested, all of it in the system library, no
/// dependency to vendor. The alternative was roughly six hundred lines of tokenizer,
/// postings list, prefix walk and snippet extraction, every one of them easy to get subtly
/// wrong and none of them this app's business.
///
/// **Why the file is disposable.** It is a cache of data that lives in `~/.claude/projects`,
/// never a source of truth. So the entire migration and corruption story is "delete it and
/// rebuild", which is what `schemaVersion` and the open path below implement. Anything that
/// made this file precious would be a design error.
///
/// This is the only file in the app that sees a `sqlite3*`.
final class SQLiteSearchIndex: SearchIndex {
    /// Bump on any schema change. A mismatch deletes the file — see `init`.
    static let schemaVersion = 1

    /// SQLite's own "copy this string, I may free it" sentinel. It is a `#define` casting
    /// -1 to a function pointer, which does not survive into Swift, so it is respelled here.
    /// Without it every bound string is treated as `STATIC` and SQLite reads freed memory.
    private static let transient = unsafeBitCast(
        -1, to: sqlite3_destructor_type.self
    )

    private var db: OpaquePointer?

    struct Failure: Error { let message: String }

    init(at url: URL) throws {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Two attempts, deliberately. A file that is corrupt, truncated, or written by an
        // older schema is discarded and rebuilt rather than reported: the index holds
        // nothing that is not derivable from transcripts on disk, so losing it costs one
        // backfill and never costs data.
        if (try? open(url)) == nil || !(try isCurrentSchema()) {
            close()
            try? FileManager.default.removeItem(at: url)
            try open(url)
            try createSchema()
        }
    }

    deinit { close() }

    // MARK: - Ingest

    func ingest(
        _ messages: [IndexedMessage], from source: URL, projectPath: String, offset: UInt64
    ) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            // A restart from byte 0 means the transcript was replaced under the same path.
            // Its old rows describe a file that no longer exists, so they are dropped rather
            // than appended to — otherwise every message in the replacement is doubled.
            if offset == 0 { try deleteRows(forSource: source) }

            let insert = try prepare("""
                INSERT INTO message(conversation_id, project_path, role, kind, timestamp, text, source)
                VALUES (?, ?, ?, 'text', ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            let intoFTS = try prepare("INSERT INTO message_fts(rowid, text) VALUES (?, ?)")
            defer { sqlite3_finalize(intoFTS) }

            for message in messages {
                bind(insert, 1, message.conversationID)
                bind(insert, 2, projectPath)
                bind(insert, 3, message.role.rawValue)
                sqlite3_bind_double(insert, 4, message.timestamp?.timeIntervalSince1970 ?? 0)
                bind(insert, 5, message.text)
                bind(insert, 6, source.path)
                guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
                sqlite3_reset(insert)

                // `content='message'` makes the FTS table external-content: it stores no
                // text of its own and is NOT populated by the insert above. Keeping it in
                // step by hand — rather than by triggers — is what lets one prepared
                // statement pair serve the whole batch.
                sqlite3_bind_int64(intoFTS, 1, sqlite3_last_insert_rowid(db))
                bind(intoFTS, 2, message.text)
                guard sqlite3_step(intoFTS) == SQLITE_DONE else { throw failure() }
                sqlite3_reset(intoFTS)
            }

            let source_ = try prepare(
                "INSERT INTO source(path, offset) VALUES (?, ?) "
                + "ON CONFLICT(path) DO UPDATE SET offset = excluded.offset"
            )
            defer { sqlite3_finalize(source_) }
            bind(source_, 1, source.path)
            sqlite3_bind_int64(source_, 2, Int64(offset))
            guard sqlite3_step(source_) == SQLITE_DONE else { throw failure() }

            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    func readOffset(for source: URL) -> UInt64 {
        guard let statement = try? prepare("SELECT offset FROM source WHERE path = ?") else {
            return 0
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, source.path)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return UInt64(max(0, sqlite3_column_int64(statement, 0)))
    }

    // MARK: - Query

    func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit] {
        guard !projects.isEmpty else { return [] }

        // The project filter is in SQL rather than applied to the results afterwards. Doing
        // it after LIMIT would let a project that has left the sidebar consume slots in the
        // 200 and silently shrink what the user sees.
        let placeholders = Array(repeating: "?", count: projects.count).joined(separator: ", ")
        let statement = try prepare("""
            SELECT m.conversation_id, m.project_path, m.timestamp,
                   snippet(message_fts, 0, char(2), char(3), '…', 24)
            FROM message_fts
            JOIN message m ON m.id = message_fts.rowid
            WHERE message_fts MATCH ? AND m.project_path IN (\(placeholders))
            ORDER BY bm25(message_fts)
            LIMIT ?
            """)
        defer { sqlite3_finalize(statement) }

        bind(statement, 1, query)
        for (offset, project) in projects.enumerated() {
            bind(statement, Int32(2 + offset), project)
        }
        sqlite3_bind_int(statement, Int32(2 + projects.count), Int32(limit))

        let names = try conversationNames()
        var hits: [TranscriptHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let conversation = text(statement, 0)
            hits.append(TranscriptHit(
                conversationID: conversation,
                projectPath: text(statement, 1),
                // Falls back to the conversation id's leading segment, which is what the
                // sidebar shows for an unnamed conversation too.
                conversationName: names[conversation]?.name ?? String(conversation.prefix(8)),
                snippet: text(statement, 3),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            ))
        }
        return hits
    }

    func conversationNames() throws -> [String: IndexedConversation] {
        let statement = try prepare("SELECT conversation_id, name, project_path FROM conversation")
        defer { sqlite3_finalize(statement) }
        var names: [String: IndexedConversation] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            names[text(statement, 0)] = IndexedConversation(
                name: text(statement, 1), projectPath: text(statement, 2)
            )
        }
        return names
    }

    func setConversationName(_ name: String, projectPath: String, for id: String) throws {
        let statement = try prepare(
            "INSERT INTO conversation(conversation_id, name, project_path) VALUES (?, ?, ?) "
            + "ON CONFLICT(conversation_id) DO UPDATE SET "
            + "name = excluded.name, project_path = excluded.project_path"
        )
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        bind(statement, 2, name)
        bind(statement, 3, projectPath)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    func messageCount(forConversation id: String) throws -> Int {
        let statement = try prepare("SELECT count(*) FROM message WHERE conversation_id = ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Prune

    func prune(keepingSources: Set<URL>, projects: Set<String>) throws {
        let statement = try prepare("SELECT DISTINCT source, project_path FROM message")
        var doomed: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let path = text(statement, 0)
            let project = text(statement, 1)
            if !keepingSources.contains(URL(fileURLWithPath: path)) || !projects.contains(project) {
                doomed.insert(path)
            }
        }
        sqlite3_finalize(statement)

        // Also sweep `source` rows whose file is gone but which contributed no messages —
        // an empty or all-tool transcript. Left behind, they would make the builder skip a
        // file it has never actually indexed if the path were ever reused.
        let orphans = try prepare("SELECT path FROM source")
        while sqlite3_step(orphans) == SQLITE_ROW {
            let path = text(orphans, 0)
            if !keepingSources.contains(URL(fileURLWithPath: path)) { doomed.insert(path) }
        }
        sqlite3_finalize(orphans)

        guard !doomed.isEmpty else { return }
        try exec("BEGIN IMMEDIATE")
        do {
            for path in doomed { try deleteRows(forSource: URL(fileURLWithPath: path)) }
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Deletes a source's messages, its FTS rows, and its read position.
    ///
    /// The FTS rows go first and by rowid: `message_fts` is external-content, so deleting
    /// from `message` alone leaves the index pointing at rows that no longer exist and
    /// `snippet()` starts returning empty strings for surviving matches.
    private func deleteRows(forSource source: URL) throws {
        let statement = try prepare("""
            DELETE FROM message_fts
            WHERE rowid IN (SELECT id FROM message WHERE source = ?)
            """)
        bind(statement, 1, source.path)
        guard sqlite3_step(statement) == SQLITE_DONE else { sqlite3_finalize(statement); throw failure() }
        sqlite3_finalize(statement)

        for sql in ["DELETE FROM message WHERE source = ?", "DELETE FROM source WHERE path = ?"] {
            let statement = try prepare(sql)
            bind(statement, 1, source.path)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_finalize(statement); throw failure()
            }
            sqlite3_finalize(statement)
        }
    }

    // MARK: - Connection

    private func open(_ url: URL) throws {
        guard sqlite3_open_v2(
            url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else { throw failure() }
        // WAL so a backfill writing on a background task cannot block the overlay's read.
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
    }

    private func close() {
        if db != nil { sqlite3_close(db); db = nil }
    }

    private func isCurrentSchema() throws -> Bool {
        guard let statement = try? prepare("SELECT value FROM meta WHERE key = 'schema_version'")
        else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return Int(text(statement, 0)) == Self.schemaVersion
    }

    private func createSchema() throws {
        try exec("""
            CREATE TABLE message(
              id INTEGER PRIMARY KEY,
              conversation_id TEXT NOT NULL,
              project_path TEXT NOT NULL,
              role TEXT NOT NULL,
              kind TEXT NOT NULL,
              timestamp REAL NOT NULL,
              text TEXT NOT NULL,
              source TEXT NOT NULL
            );
            CREATE INDEX message_by_source ON message(source);
            CREATE INDEX message_by_conversation ON message(conversation_id);
            CREATE VIRTUAL TABLE message_fts USING fts5(
              text, content='message', content_rowid='id', tokenize='unicode61'
            );
            CREATE TABLE source(path TEXT PRIMARY KEY, offset INTEGER NOT NULL);
            CREATE TABLE conversation(
              conversation_id TEXT PRIMARY KEY, name TEXT NOT NULL, project_path TEXT NOT NULL
            );
            CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO meta(key, value) VALUES ('schema_version', '\(Self.schemaVersion)');
            """)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ column: Int32, _ value: String) {
        sqlite3_bind_text(statement, column, value, -1, Self.transient)
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: cString)
    }

    private func failure() -> Failure {
        Failure(message: String(cString: sqlite3_errmsg(db)))
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS. If `snippet()` returns empty strings, the external-content FTS table is out of step with `message` — check `deleteRows` runs the FTS delete first.

- [ ] **Step 7: Commit**

```bash
git add project.yml Sources/FlightDeck/Search/SearchIndex.swift \
        Sources/FlightDeck/Search/SQLiteSearchIndex.swift \
        Tests/FlightDeckTests/SQLiteSearchIndexTests.swift
git commit -m "feat: index conversation text in SQLite FTS5

FTS5 gives snippet(), bm25 ranking and prefix queries out of the system
library, and snippet() returns precisely the two-line term-marked extract the
overlay row is specified to draw. The alternative was ~600 lines of
tokenizer, postings list and snippet extraction, all easy to get subtly wrong
and none of it this app's business. Linked as sdk: libsqlite3.tbd — no
vendored copy, FTS5 is compiled in (verified against 3.51.0).

The file is deliberately disposable. It caches data that lives in
~/.claude/projects and is never a source of truth, so a corrupt file or a
schema bump is handled by deleting and rebuilding rather than by migrating.

Three details that fail silently if missed, each commented at its site:
SQLITE_TRANSIENT does not survive into Swift and must be respelled or every
bound string reads freed memory; message_fts is external-content so it is
populated and deleted by hand, and deleting message rows first leaves
snippet() returning empty strings; and the project filter is in SQL rather
than applied after LIMIT, so a project that left the sidebar cannot consume
result slots.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Backfill history in the background

**Files:**
- Create: `Sources/FlightDeck/Search/SearchIndexBuilder.swift`
- Test: `Tests/FlightDeckTests/SearchIndexBuilderTests.swift`

**Interfaces:**
- Consumes: `SearchIndex` (Task 6), `SearchCorpus.Entry` (Task 2), `TranscriptExtractor` (Task 1), `TailReader` from `Sources/FlightDeck/TailReader.swift`.
- Produces: `actor SearchIndexBuilder { init(index: SearchIndex); func build(_ entries: [SearchCorpus.Entry], progress: @Sendable (Progress) -> Void) async }` with `struct Progress: Equatable, Sendable { let indexed: Int; let total: Int }`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SearchIndexBuilderTests.swift
import XCTest
@testable import FlightDeck

/// The one-time walk over transcript history.
///
/// The expensive step in the whole design: 684 MB of JSONL parsed to extract ~34 MB of
/// conversation. Everything asserted here is about making that cost payable once and
/// survivable when interrupted.
final class SearchIndexBuilderTests: XCTestCase {
    private var directory: URL!
    private var index: SQLiteSearchIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("builder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try SQLiteSearchIndex(at: directory.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        index = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a transcript. `conversation` is the file's basename, matching how claude names
    /// them and how the builder derives a conversation id.
    @discardableResult
    private func write(_ lines: [String], conversation: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(conversation).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func userLine(_ text: String) -> String {
        #"{"type":"user","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":"\#(text)"}}"#
    }

    private func entries(_ folder: URL, project: String = "/w/fd") -> [SearchCorpus.Entry] {
        [SearchCorpus.Entry(projectPath: project, directory: folder)]
    }

    func testEveryTranscriptInScopeIsIndexed() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        try write([userLine("the rename bug")], conversation: "c1", in: folder)
        try write([userLine("something else")], conversation: "c2", in: folder)

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 1)
        XCTAssertEqual(try index.search(#""something"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// The property that makes a second run cheap: a file already read through its end
    /// contributes no new rows.
    func testASecondPassOverUnchangedFilesAddsNothing() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        try write([userLine("the rename bug")], conversation: "c1", in: folder)

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })
        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// Only appended bytes are re-read, which is what keeps a growing transcript cheap
    /// rather than re-parsing 23 MB every pass.
    func testOnlyAppendedBytesAreIndexedOnASecondPass() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        let url = try write([userLine("first message")], conversation: "c1", in: folder)

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((userLine("second message") + "\n").utf8))
        try handle.close()

        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.search(#""first"*"#, projects: ["/w/fd"], limit: 10).count, 1)
        XCTAssertEqual(try index.search(#""second"*"#, projects: ["/w/fd"], limit: 10).count, 1)
    }

    /// A cancelled backfill must leave the offsets it did commit, so the next launch
    /// resumes rather than starting over. Nothing here asserts *where* it stopped — only
    /// that stopping is not destructive.
    func testACancelledBuildKeepsWhatItAlreadyCommitted() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        for i in 0..<20 { try write([userLine("rename \(i)")], conversation: "c\(i)", in: folder) }

        let builder = SearchIndexBuilder(index: index)
        let task = Task { await builder.build(entries(folder), progress: { _ in }) }
        task.cancel()
        await task.value

        // Whatever was committed stays committed and is not double-counted on resume.
        let before = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 100).count
        await builder.build(entries(folder), progress: { _ in })
        let after = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 100).count

        XCTAssertGreaterThanOrEqual(after, before)
        XCTAssertEqual(after, 20)
    }

    /// The overlay footer reports this. A search that silently returns nothing while the
    /// index is still filling is worse than one that says it is still reading.
    func testProgressIsReportedAgainstTheTotalFileCount() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        for i in 0..<3 { try write([userLine("m\(i)")], conversation: "c\(i)", in: folder) }

        var seen: [SearchIndexBuilder.Progress] = []
        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { seen.append($0) })

        XCTAssertEqual(seen.last, SearchIndexBuilder.Progress(indexed: 3, total: 3))
        XCTAssertTrue(seen.allSatisfy { $0.total == 3 })
    }

    /// Conversations no longer on disk, and projects no longer in the sidebar, are dropped
    /// at the start of a pass — otherwise the index only grows and starts answering with
    /// things that cannot be opened.
    func testFilesThatHaveDisappearedArePruned() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        let doomed = try write([userLine("rename me")], conversation: "c1", in: folder)
        try write([userLine("rename survivor")], conversation: "c2", in: folder)

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })
        try FileManager.default.removeItem(at: doomed)
        await builder.build(entries(folder), progress: { _ in })

        let hits = try index.search(#""rename"*"#, projects: ["/w/fd"], limit: 10)
        XCTAssertEqual(hits.map(\.conversationID), ["c2"])
    }

    /// Names come from the transcript itself, via the same rules the sidebar uses, so a
    /// result row for a conversation with no open tab is still called something meaningful.
    func testConversationNamesAreRecorded() async throws {
        let folder = directory.appendingPathComponent("proj", isDirectory: true)
        try write(
            [#"{"type":"custom-title","customTitle":"rename-break"}"#, userLine("hello")],
            conversation: "c1", in: folder
        )

        let builder = SearchIndexBuilder(index: index)
        await builder.build(entries(folder), progress: { _ in })

        XCTAssertEqual(try index.conversationNames()["c1"]?.name, "rename-break")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'SearchIndexBuilder' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Search/SearchIndexBuilder.swift
import Foundation

/// Reads transcript history into the index, once, without getting in anybody's way.
///
/// **The cost this manages.** Extracting ~34 MB of conversation means parsing ~684 MB of
/// JSONL, and it happens while real agents are running in the same app. So the walk is an
/// `actor` off the main actor, it yields between files, it is cancellable at every file
/// boundary, and every file's progress is committed as a byte offset before the next one
/// starts — a build killed halfway costs nothing but the file it was inside.
///
/// **Why newest first.** The conversation you want is overwhelmingly likely to be a recent
/// one, so ordering by mtime descending means search becomes useful long before the walk
/// finishes rather than at the end of it.
///
/// **Why it reuses `TailReader`.** Incremental reading of an append-only transcript is
/// already solved there, including the two rules that are easy to get wrong: never consume a
/// trailing line without its newline (the writer is appending as we read), and treat a file
/// that shrank as a replacement. Using it means a growing transcript costs only its new
/// bytes on every later pass.
actor SearchIndexBuilder {
    struct Progress: Equatable, Sendable {
        let indexed: Int
        let total: Int
    }

    /// How many messages accumulate before a commit. Per-batch rather than per-file so a
    /// single 23 MB transcript — the largest in the corpus here — cannot hold a transaction
    /// open long enough to stall the overlay's reads behind it.
    private static let batchSize = 500

    private let index: SearchIndex

    init(index: SearchIndex) { self.index = index }

    func build(_ entries: [SearchCorpus.Entry], progress: @Sendable (Progress) -> Void) async {
        let files = Self.transcripts(in: entries)

        // Before anything is added, so a project removed from the sidebar stops answering
        // immediately rather than at the end of a walk that may take a minute.
        try? index.prune(
            keepingSources: Set(files.map(\.url)),
            projects: Set(entries.map(\.projectPath))
        )

        for (position, file) in files.enumerated() {
            // Checked per file rather than per line: a cancelled build should stop promptly,
            // but tearing out of the middle of a file would abandon work already parsed.
            if Task.isCancelled { return }
            index(file)
            progress(Progress(indexed: position + 1, total: files.count))
            // Hands the thread back between files so a backfill cannot monopolise a core
            // while agents are running in the same process.
            await Task.yield()
        }
    }

    /// One transcript: everything appended since the offset the index remembers.
    private func index(_ file: Transcript) {
        var offset = index.readOffset(for: file.url)
        // `hasChosenStart: true` is deliberate and is the opposite of what a live watcher
        // wants. `TailReader`'s default for a first look is to skip to the end of an
        // existing file, because a watcher attaching to a running session does not want its
        // backlog. A backfill wants exactly that backlog — it *is* the backlog.
        let read = TailReader.read(url: file.url, offset: offset, hasChosenStart: true)
        guard !read.lines.isEmpty else { return }

        var batch: [IndexedMessage] = []
        var name: String?

        for line in read.lines {
            batch += TranscriptExtractor.messages(inLine: line, conversationID: file.conversationID)
            // The sidebar's own naming rule, so a conversation with no open tab is called
            // what it would be called if it had one.
            if let resolved = ConversationTitle.resolve(lines: [line]) { name = resolved }

            if batch.count >= Self.batchSize {
                // The offset committed with a partial batch is the file's *previous*
                // position, not the read's end: the remaining lines are not stored yet, and
                // an interruption here must re-read them rather than skip them.
                try? index.ingest(
                    batch, from: file.url, projectPath: file.projectPath, offset: offset
                )
                batch.removeAll(keepingCapacity: true)
            }
        }

        offset = read.offset
        try? index.ingest(batch, from: file.url, projectPath: file.projectPath, offset: offset)
        if let name, let sqlite = index as? SQLiteSearchIndex {
            try? sqlite.setConversationName(
                name, projectPath: file.projectPath, for: file.conversationID
            )
        }
    }

    private struct Transcript {
        let url: URL
        let projectPath: String
        let conversationID: String
        let modified: Date
    }

    /// Every `.jsonl` under the in-scope directories, newest first.
    ///
    /// Subdirectories are skipped: `~/.claude/projects/<dir>/<conversation>/subagents/*.jsonl`
    /// holds subagent transcripts, which are not conversations anyone resumes and would
    /// double-count text their parent already carries.
    private static func transcripts(in entries: [SearchCorpus.Entry]) -> [Transcript] {
        var found: [Transcript] = []
        for entry in entries {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: entry.directory.path))
                ?? []
            for name in names where name.hasSuffix(".jsonl") {
                let url = entry.directory.appendingPathComponent(name)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                found.append(Transcript(
                    url: url,
                    projectPath: entry.projectPath,
                    conversationID: String(name.dropLast(".jsonl".count)),
                    modified: modified
                ))
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Search/SearchIndexBuilder.swift \
        Tests/FlightDeckTests/SearchIndexBuilderTests.swift
git commit -m "feat: backfill transcript history off the main actor, newest first

The expensive step in the design: ~684 MB of JSONL parsed to extract ~34 MB
of conversation, while real agents run in the same process. So it is an actor
off the main actor that yields between files, checks cancellation at every
file boundary, and commits each file's byte offset before starting the next —
a build killed halfway costs only the file it was inside.

Newest first, so search becomes useful long before the walk ends rather than
at the end of it. Pruning runs before ingest so a project removed from the
sidebar stops answering immediately.

Reuses TailReader, which already solves incremental reads including the two
rules easy to get wrong: never consume a trailing line lacking its newline
while the writer is appending, and treat a shrunken file as a replacement.
It is passed hasChosenStart: true — the opposite of a live watcher, which
skips an existing file's backlog. A backfill *is* the backlog.

Subagent transcripts under <conversation>/subagents/ are skipped: nobody
resumes them, and their text is already carried by the parent.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Index the live session for free

**Files:**
- Modify: `Sources/FlightDeck/TranscriptWatcher.swift`
- Test: `Tests/FlightDeckTests/TranscriptWatcherIndexingTests.swift`

**Interfaces:**
- Consumes: `IndexedMessage`, `TranscriptExtractor` (Task 1).
- Produces: `TranscriptWatcher.onMessages: (([IndexedMessage]) -> Void)?` — a new optional init parameter, defaulted so every existing call site is unaffected. `Scan` gains `var messages: [IndexedMessage] = []`.

The conversation you are in right now appends constantly, and `SearchIndexBuilder` only walks history. But `TranscriptWatcher` already reads and JSON-parses every appended line of every open session, on the shared `WatchClock`, off the main actor. Extraction rides that: no second reader, no second timer, and the live session is searchable within one tick.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/TranscriptWatcherIndexingTests.swift
import XCTest
@testable import FlightDeck

/// Live sessions index by riding the poll that already exists.
///
/// `TranscriptWatcher` reads and parses every appended line to find titles and subagent
/// counts. Extraction costs one more pass over data already in hand, which is what keeps
/// the conversation you are typing in searchable without a second reader or a second timer.
@MainActor
final class TranscriptWatcherIndexingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-indexing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAppendedConversationTextIsReportedToTheIndexingHook() throws {
        let sessionID = UUID()
        let url = directory.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var indexed: [IndexedMessage] = []
        let watcher = TranscriptWatcher(
            sessionID: sessionID, url: url,
            onTitle: { _ in },
            onMessages: { indexed += $0 }
        )
        watcher.drain()   // establishes the start position on the empty file

        let line = #"{"type":"user","timestamp":"2026-08-26T21:57:19.490Z","message":{"content":"the rename bug"}}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()

        watcher.drain()

        XCTAssertEqual(indexed.map(\.text), ["the rename bug"])
        XCTAssertEqual(indexed.first?.conversationID, sessionID.uuidString.lowercased())
    }

    /// The hook is optional and defaulted, so every existing call site keeps compiling and
    /// keeps costing exactly what it did.
    func testAWatcherWithNoIndexingHookStillReportsTitles() throws {
        let sessionID = UUID()
        let url = directory.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var title: String?
        let watcher = TranscriptWatcher(sessionID: sessionID, url: url, onTitle: { title = $0 })
        watcher.drain()

        let line = #"{"type":"custom-title","customTitle":"rename-break","sessionId":"\#(sessionID.uuidString.lowercased())"}"#
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()

        watcher.drain()

        XCTAssertEqual(title, "rename-break")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `extra argument 'onMessages' in call`.

- [ ] **Step 3: Extend `Scan` to carry extracted messages**

In `Sources/FlightDeck/TranscriptWatcher.swift`, add to `struct Scan`:

```swift
    /// Conversation text found in this pass, for the search index.
    ///
    /// Collected here rather than in a second reader because this pass has already paid for
    /// the two expensive parts — the file read and the JSON parse — and transcript lines are
    /// large enough (a single assistant record carries whole tool inputs and results) that
    /// doing either of them twice would be the most expensive thing in the app.
    var messages: [IndexedMessage] = []
```

and in `Scan.read`, inside the existing `for line in tail.lines` loop, alongside the existing `result.events` append:

```swift
            result.messages += TranscriptExtractor.messages(
                inLine: line, conversationID: sessionID.uuidString.lowercased()
            )
```

- [ ] **Step 4: Add the hook to the watcher**

Add the stored property and init parameter:

```swift
    /// Reports conversation text to the search index. Optional and defaulted: title-only
    /// call sites are unaffected, and a watcher built without it does no extra work.
    private let onMessages: ([IndexedMessage]) -> Void
```

```swift
    init(
        sessionID: UUID,
        url: URL,
        clock: WatchClock? = nil,
        onTitle: @escaping (String) -> Void,
        onSubagentCount: @escaping (Int) -> Void = { _ in },
        onMessages: @escaping ([IndexedMessage]) -> Void = { _ in }
    ) {
        // ... existing assignments ...
        self.onMessages = onMessages
    }
```

and at the end of `apply(_:)`, after the existing title and count callbacks:

```swift
        if !scan.messages.isEmpty { onMessages(scan.messages) }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, and the whole existing suite still green — no other call site changed.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/TranscriptWatcher.swift \
        Tests/FlightDeckTests/TranscriptWatcherIndexingTests.swift
git commit -m "feat: report live conversation text from the transcript poll

SearchIndexBuilder only walks history, but the conversation you are typing in
appends constantly and has to be searchable now. TranscriptWatcher already
reads and JSON-parses every appended line of every open session, on the shared
WatchClock, off the main actor — so extraction rides that pass instead of
adding a second reader and a second timer.

That placement is the point: the file read and the JSON parse are the two
expensive halves, transcript lines are large (one assistant record carries
whole tool inputs and results), and doing either twice would be the most
expensive thing in the app.

The hook is optional and defaulted, so every existing call site compiles
unchanged and a watcher built without it does no extra work.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: The search model — debounce, dispatch, stable selection

**Files:**
- Create: `Sources/FlightDeck/Search/SearchModel.swift`
- Test: `Tests/FlightDeckTests/SearchModelTests.swift`

**Interfaces:**
- Consumes: `SearchIndex` (Task 6), `SearchRanker`, `NameCandidate`, `SearchResult` (Task 5), `FTS5Query` (Task 3).
- Produces: `@MainActor final class SearchModel: ObservableObject` with `@Published var query: String`, `@Published private(set) var results: [SearchResult]`, `@Published var selectedID: SearchResult.ID?`, `@Published private(set) var indexingProgress: SearchIndexBuilder.Progress?`, and `func moveSelection(by: Int)`, `func activateSelection() -> SearchResult?`, `func candidatesChanged(_:)`, `func open()`, `func close()`. Debounce interval exposed as `static var transcriptDebounce: Duration`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SearchModelTests.swift
import XCTest
@testable import FlightDeck

/// An index that answers instantly and records what it was asked, so the model's
/// debouncing and merging can be tested without SQLite or sleeping.
private final class StubSearchIndex: SearchIndex {
    var hits: [TranscriptHit] = []
    private(set) var queries: [String] = []

    func ingest(_: [IndexedMessage], from: URL, projectPath: String, offset: UInt64) throws {}
    func readOffset(for: URL) -> UInt64 { 0 }
    func conversationNames() throws -> [String: IndexedConversation] { [:] }
    func prune(keepingSources: Set<URL>, projects: Set<String>) throws {}
    func messageCount(forConversation: String) throws -> Int { 0 }

    func search(_ query: String, projects: [String], limit: Int) throws -> [TranscriptHit] {
        queries.append(query)
        return hits
    }
}

/// What the overlay binds to.
@MainActor
final class SearchModelTests: XCTestCase {
    private var index: StubSearchIndex!
    private var model: SearchModel!

    private func candidate(_ name: String, activity: TimeInterval = 0) -> NameCandidate {
        NameCandidate(
            id: name, kind: .session(UUID()), name: name,
            projectPath: "/w/fd", projectName: "fd",
            lastActivity: Date(timeIntervalSince1970: 1_800_000_000 + activity),
            conversationID: nil
        )
    }

    override func setUp() async throws {
        index = StubSearchIndex()
        model = SearchModel(index: index, projects: { ["/w/fd"] })
        model.candidatesChanged([
            candidate("rename-break", activity: 100),
            candidate("session-menu", activity: 50),
            candidate("wifi", activity: 10),
        ])
    }

    /// Names are matched in memory with no I/O, so they must be on screen before any
    /// debounce elapses — that is the whole reason the two halves are split.
    func testNameResultsAppearSynchronouslyOnTyping() {
        model.query = "rename"

        XCTAssertEqual(model.results.map(\.title), ["rename-break"])
        XCTAssertTrue(index.queries.isEmpty, "the index must not be hit on the keystroke")
    }

    func testTranscriptResultsArriveAfterTheDebounce() async throws {
        index.hits = [TranscriptHit(
            conversationID: "c1", projectPath: "/w/fd", conversationName: "mobile-ui",
            snippet: "don't fire a \u{2}rename\u{3}", timestamp: Date(timeIntervalSince1970: 1)
        )]

        model.query = "rename"
        XCTAssertEqual(model.results.count, 1)

        try await Task.sleep(for: SearchModel.transcriptDebounce * 3)

        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.results.last?.snippet, "don't fire a \u{2}rename\u{3}")
    }

    /// The debounce exists so a fast typist costs one query, not one per keystroke, against
    /// an index that may be mid-backfill.
    func testRapidTypingIssuesASingleIndexQuery() async throws {
        for text in ["r", "re", "ren", "rena", "renam", "rename"] { model.query = text }

        try await Task.sleep(for: SearchModel.transcriptDebounce * 3)

        XCTAssertEqual(index.queries.count, 1)
        XCTAssertEqual(index.queries.first, #""rename"*"#)
    }

    /// The property the whole tier scheme protects: a late transcript result appends below
    /// the name results, so whatever the user had highlighted stays highlighted.
    func testLateTranscriptResultsDoNotMoveTheSelection() async throws {
        index.hits = [TranscriptHit(
            conversationID: "c1", projectPath: "/w/fd", conversationName: "mobile-ui",
            snippet: "x", timestamp: Date(timeIntervalSince1970: 1)
        )]
        model.query = "e"                     // matches two names by prefix/fuzzy
        model.moveSelection(by: 1)
        let held = model.selectedID

        try await Task.sleep(for: SearchModel.transcriptDebounce * 3)

        XCTAssertEqual(model.selectedID, held)
    }

    func testSelectionResetsToTheTopWhenTheQueryChanges() {
        model.query = "e"
        model.moveSelection(by: 1)
        model.query = "rename"

        XCTAssertEqual(model.selectedID, model.results.first?.id)
    }

    /// Arrowing past either end holds rather than wrapping: at eight visible rows, wrapping
    /// from the top to the bottom of a 200-result list is disorienting, and the top of the
    /// list is where the best match is.
    func testSelectionClampsAtBothEnds() {
        model.query = ""                      // empty query lists all three sessions

        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedID, model.results.first?.id)

        model.moveSelection(by: 99)
        XCTAssertEqual(model.selectedID, model.results.last?.id)
    }

    func testActivatingReturnsTheHighlightedResult() {
        model.query = "rename"
        XCTAssertEqual(model.activateSelection()?.title, "rename-break")
    }

    /// Closing must not leave the previous query's results to flash on the next open.
    func testClosingClearsTheQueryAndResults() {
        model.query = "rename"
        model.close()

        XCTAssertTrue(model.query.isEmpty)
        XCTAssertTrue(model.results.allSatisfy { $0.snippet == nil })
    }

    /// An empty query has nothing for FTS5 to match, so it must not reach the index at all.
    func testAnEmptyQueryNeverHitsTheIndex() async throws {
        model.query = ""
        try await Task.sleep(for: SearchModel.transcriptDebounce * 3)

        XCTAssertTrue(index.queries.isEmpty)
        XCTAssertEqual(model.results.count, 3)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'SearchModel' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Search/SearchModel.swift
import Foundation
import SwiftUI

/// What the overlay binds to: the query, the ranked results, and the highlighted row.
///
/// **Two clocks, on purpose.** Name matching is in-memory over a few hundred candidates, so
/// it runs on the keystroke with no debounce — the list responds instantly. Transcript
/// matching goes to SQLite, so it waits 90 ms, which turns a fast typist's six keystrokes
/// into one query.
///
/// **Why that split is safe.** `SearchRanker` puts transcript hits in the last tier
/// unconditionally, so results arriving late can only append *below* what is drawn. Combined
/// with tracking selection by result id rather than by row index, the highlighted row cannot
/// be shoved out from under a user who is already reaching for Return.
@MainActor
final class SearchModel: ObservableObject {
    /// How long transcript matching waits behind the last keystroke. Long enough to collapse
    /// a burst of typing into one query, short enough that pausing to read feels immediate.
    static let transcriptDebounce: Duration = .milliseconds(90)

    /// How many transcript hits BM25 selects before recency reorders them (§7).
    static let transcriptLimit = 200

    @Published var query: String = "" { didSet { queryChanged(from: oldValue) } }
    @Published private(set) var results: [SearchResult] = []
    @Published var selectedID: SearchResult.ID?
    @Published private(set) var indexingProgress: SearchIndexBuilder.Progress?

    private let index: SearchIndex
    private let projects: () -> [String]
    private var candidates: [NameCandidate] = []
    /// The transcript hits currently merged in. Cleared whenever the query changes, so a
    /// previous query's evidence can never survive under a new one.
    private var transcripts: [TranscriptHit] = []
    private var debounceTask: Task<Void, Never>?

    init(index: SearchIndex, projects: @escaping () -> [String]) {
        self.index = index
        self.projects = projects
    }

    /// The names to match against — sessions, projects, and conversations from the index.
    /// Pushed in by the owner rather than pulled from `SessionStore`, which keeps this type
    /// testable without a store.
    func candidatesChanged(_ candidates: [NameCandidate]) {
        self.candidates = candidates
        rerank()
    }

    func indexingProgressChanged(_ progress: SearchIndexBuilder.Progress?) {
        indexingProgress = progress
    }

    func open() {
        query = ""
        rerank()
    }

    func close() {
        debounceTask?.cancel()
        debounceTask = nil
        transcripts = []
        query = ""
        results = []
        selectedID = nil
    }

    /// Arrow-key movement. Clamps rather than wraps: with eight rows visible, wrapping from
    /// the top of a 200-result list to its bottom is disorienting, and the top is where the
    /// best match already is.
    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { selectedID = nil; return }
        let current = results.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        selectedID = results[next].id
    }

    func activateSelection() -> SearchResult? {
        results.first { $0.id == selectedID } ?? results.first
    }

    private func queryChanged(from old: String) {
        guard query != old else { return }
        // Dropped immediately, not when the replacement arrives: otherwise a query with no
        // transcript hits leaves the previous query's hits on screen until it returns.
        transcripts = []
        rerank()
        scheduleTranscriptSearch()
    }

    private func scheduleTranscriptSearch() {
        debounceTask?.cancel()
        guard let match = FTS5Query.match(for: query) else { return }
        let projects = self.projects()
        let limit = Self.transcriptLimit

        debounceTask = Task { [weak self, index] in
            try? await Task.sleep(for: Self.transcriptDebounce)
            guard !Task.isCancelled else { return }

            // Off the main actor: the query itself is sub-millisecond on a warm index, but
            // it can contend with a backfill's writer, and blocking the main actor there
            // would stutter the panel's height animation.
            let hits = await Task.detached(priority: .userInitiated) {
                (try? index.search(match, projects: projects, limit: limit)) ?? []
            }.value

            guard !Task.isCancelled, let self else { return }
            self.transcripts = hits
            self.rerank()
        }
    }

    private func rerank() {
        results = SearchRanker.rank(names: candidates, query: query, transcripts: transcripts)
        // Selection is held by identity across reranks, so a late-arriving batch of
        // transcript hits leaves the highlighted row exactly where it was. It only resets
        // when the row it named is genuinely gone — which is what a changed query does.
        if selectedID == nil || !results.contains(where: { $0.id == selectedID }) {
            selectedID = results.first?.id
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Search/SearchModel.swift \
        Tests/FlightDeckTests/SearchModelTests.swift
git commit -m "feat: run name matching on the keystroke and transcripts behind a debounce

Two clocks. Name matching is in-memory over a few hundred candidates and runs
with no debounce, so the list responds instantly. Transcript matching goes to
SQLite and waits 90 ms, turning a fast typist's six keystrokes into one query.

The split is only safe because SearchRanker puts transcript hits in the last
tier unconditionally: late results can only append below what is drawn. With
selection tracked by result id rather than row index, the highlighted row
cannot move out from under someone already reaching for Return — asserted
directly.

Stale hits are dropped when the query changes rather than when the
replacement arrives, or a query with no matches would leave the previous
query's evidence on screen. Arrowing clamps rather than wraps: with eight
rows visible, wrapping to the end of a 200-result list is disorienting.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Activate a result

**Files:**
- Create: `Sources/FlightDeck/Search/SearchActivation.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (extract a shared resume path; add `openConversation`)
- Test: `Tests/FlightDeckTests/SearchActivationTests.swift`

**Interfaces:**
- Consumes: `SearchResult` (Task 5).
- Produces: `enum SearchActivation { static func plan(for result: SearchResult, openSessions: [ActiveSession], projects: [String]) -> Activation }`, where `struct ActiveSession: Equatable { let id: UUID; let conversationID: String }` and

```swift
enum Activation: Equatable {
    case select(UUID)
    case resume(conversationID: String, projectPath: String, transcriptDirectory: String)
    case addProjectThenResume(projectPath: String, conversationID: String, transcriptDirectory: String)
}
```

plus `@MainActor func SessionStore.openConversation(_ activation: SearchActivation.Activation)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/FlightDeckTests/SearchActivationTests.swift
import XCTest
@testable import FlightDeck

/// What pressing Return on a result means, decided as a value before anything is launched.
///
/// Pure so the rules are testable without spawning an agent: launching is `SessionStore`'s
/// job, deciding is this type's.
final class SearchActivationTests: XCTestCase {
    private func result(
        kind: SearchResultKind, conversation: String? = nil, project: String = "/w/fd"
    ) -> SearchResult {
        SearchResult(
            id: "r", kind: kind, title: "t", projectName: "fd", projectPath: project,
            tier: .exact, recency: .distantPast, highlightedRanges: [], snippet: nil,
            conversationID: conversation
        )
    }

    func testASessionResultSelectsItsTab() {
        let id = UUID()
        let activation = SearchActivation.plan(
            for: result(kind: .session(id)), openSessions: [], projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .select(id))
    }

    /// Re-resuming a conversation that already has a tab would start a second `claude` on
    /// the same conversation — two processes writing one transcript, which is the collision
    /// the app's pid-keyed registry cannot survive.
    func testAConversationThatAlreadyHasATabSelectsItRatherThanResuming() {
        let tab = UUID()
        let activation = SearchActivation.plan(
            for: result(kind: .conversation("c1"), conversation: "c1"),
            openSessions: [SearchActivation.ActiveSession(id: tab, conversationID: "c1")],
            projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .select(tab))
    }

    func testAConversationWithNoTabResumesIntoItsProject() {
        let activation = SearchActivation.plan(
            for: result(kind: .conversation("c1"), conversation: "c1"),
            openSessions: [], projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .resume(
            conversationID: "c1", projectPath: "/w/fd", transcriptDirectory: "/w/fd"
        ))
    }

    /// The user asked for this explicitly: opening a result reopens its project if it is no
    /// longer in the sidebar.
    func testAConversationWhoseProjectHasLeftTheSidebarBringsTheProjectBack() {
        let activation = SearchActivation.plan(
            for: result(kind: .conversation("c1"), conversation: "c1", project: "/w/gone"),
            openSessions: [], projects: ["/w/fd"]
        )

        XCTAssertEqual(activation, .addProjectThenResume(
            projectPath: "/w/gone", conversationID: "c1", transcriptDirectory: "/w/gone"
        ))
    }

    /// A worktree conversation must resume where claude actually wrote it. Resuming it in
    /// the project root would point the tab's watcher at a transcript nothing writes to,
    /// silently losing title sync and subagent counts — the failure `Session.transcriptDirectory`
    /// exists to prevent.
    func testAWorktreeConversationResumesInItsWorktreeDirectory() {
        var worktree = result(kind: .conversation("c1"), conversation: "c1")
        worktree = SearchResult(
            id: worktree.id, kind: worktree.kind, title: worktree.title,
            projectName: worktree.projectName, projectPath: "/w/fd",
            tier: worktree.tier, recency: worktree.recency,
            highlightedRanges: [], snippet: nil, conversationID: "c1"
        )

        let activation = SearchActivation.plan(
            for: worktree, openSessions: [], projects: ["/w/fd"],
            transcriptDirectory: "/w/fd/.claude/worktrees/fleet-pairing"
        )

        XCTAssertEqual(activation, .resume(
            conversationID: "c1", projectPath: "/w/fd",
            transcriptDirectory: "/w/fd/.claude/worktrees/fleet-pairing"
        ))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'SearchActivation' in scope`.

- [ ] **Step 3: Write the pure decision**

```swift
// Sources/FlightDeck/Search/SearchActivation.swift
import Foundation

/// What Return on a search result means.
///
/// Pure and separate from `SessionStore` on purpose: "should this select a tab or launch an
/// agent" is a rule worth testing exhaustively, and testing it inside the store would mean
/// spawning processes to assert a branch.
enum SearchActivation {
    /// A tab currently in the deck, reduced to the two fields activation cares about.
    struct ActiveSession: Equatable {
        let id: UUID
        let conversationID: String
    }

    enum Activation: Equatable {
        /// Already open. Select it.
        case select(UUID)
        /// Resume into a new tab under a project that is already in the sidebar.
        case resume(conversationID: String, projectPath: String, transcriptDirectory: String)
        /// The project has left the sidebar since this conversation ran; put it back first.
        case addProjectThenResume(
            projectPath: String, conversationID: String, transcriptDirectory: String
        )
    }

    /// `transcriptDirectory` defaults to the project, and differs only for a conversation
    /// that ran inside a worktree. Getting this wrong is silent: a tab resumed in the project
    /// root would tail a transcript nothing writes to and lose title sync and subagent counts
    /// with no error — the failure `Session.transcriptDirectory` was introduced to prevent.
    static func plan(
        for result: SearchResult,
        openSessions: [ActiveSession],
        projects: [String],
        transcriptDirectory: String? = nil
    ) -> Activation {
        if case .session(let id) = result.kind { return .select(id) }

        guard let conversation = result.conversationID else {
            // A project row with no conversation: selecting the project is the closest
            // meaningful action, and the store resolves it to the project's first session.
            return .addProjectThenResume(
                projectPath: result.projectPath, conversationID: "",
                transcriptDirectory: transcriptDirectory ?? result.projectPath
            )
        }
        // A second `claude --resume` on a live conversation means two processes appending
        // one transcript and colliding in claude's pid-keyed name registry. Selecting the
        // existing tab is both cheaper and the only correct answer.
        if let open = openSessions.first(where: { $0.conversationID == conversation }) {
            return .select(open.id)
        }

        let directory = transcriptDirectory ?? result.projectPath
        return projects.contains(result.projectPath)
            ? .resume(
                conversationID: conversation, projectPath: result.projectPath,
                transcriptDirectory: directory
            )
            : .addProjectThenResume(
                projectPath: result.projectPath, conversationID: conversation,
                transcriptDirectory: directory
            )
    }
}
```

- [ ] **Step 4: Give `SessionStore` one seam both reopen and search use**

`reinsertClosed` (around `SessionStore.swift:2428`) already does exactly what resuming a conversation into a tab requires: fall back to the project directory when the transcript directory is gone, refuse to launch an orphaned account, build the resume command from the adapter, and hand off to `insertSession`. Extract its body so search reuses it rather than growing a parallel copy that can drift.

Add, next to `reinsertClosed`:

```swift
    /// Rebuilds one tab onto an existing conversation and starts it resuming.
    ///
    /// Extracted from `reinsertClosed` so ⌘⇧T and ⌘K search share one implementation. Every
    /// rule here is `restore`'s and is documented there: a transcript directory that has
    /// gone (a deleted worktree, usually) falls back to the project so `--resume` runs where
    /// claude actually wrote; a tab whose login was deleted is rebuilt but never launched;
    /// codex is typed at only after `resumeRestoredCodex` confirms its thread still exists.
    ///
    /// Returns true when it is a codex tab whose resume text still has to be settled.
    @discardableResult
    private func resumeExisting(
        _ session: Session,
        inProjectAt projectPath: String,
        at index: Int?,
        directoryExists: (String) -> Bool
    ) -> Bool {
        var session = session
        if !directoryExists(session.transcriptDirectory) {
            session.transcriptDirectory = session.workingDirectory
        }

        let orphaned = accountIsMissing(for: session)
        let deferred = session.agent == .codex
        let initialInput: String
        if orphaned || deferred {
            initialInput = ""
        } else {
            let adapter = adapter(for: instance(for: session))
            initialInput = adapter.resumeCommand(
                adapter.binding(for: session), session,
                options(for: session.agent, project: session.workingDirectory)
            )
        }

        insertSession(
            session,
            in: URL(fileURLWithPath: projectPath, isDirectory: true),
            initialInput: initialInput,
            at: index
        )
        return deferred && !orphaned
    }
```

Rewrite `reinsertClosed` to delegate:

```swift
    @discardableResult
    private func reinsertClosed(
        _ closed: ClosedSessionHistory.ClosedSession,
        directoryExists: (String) -> Bool
    ) -> Bool {
        resumeExisting(
            closed.session,
            inProjectAt: closed.projectPath,
            at: closed.indexInProject,
            directoryExists: directoryExists
        )
    }
```

Then add the search entry point:

```swift
    /// ⌘K activation. Selects an open tab, or rebuilds one onto a past conversation.
    ///
    /// The project is added back when it has left the sidebar, and un-collapsed either way:
    /// a tab resumed into a collapsed project would come back invisible, since
    /// `SidebarRow.rows` renders only the header for a collapsed repo. Same reasoning as
    /// `reopenLastClosed`, which un-collapses for the same reason.
    func openConversation(
        _ activation: SearchActivation.Activation,
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        let projectPath: String
        let conversationID: String
        let transcriptDirectory: String

        switch activation {
        case .select(let id):
            selectSession(id)
            return
        case .resume(let conversation, let project, let directory):
            projectPath = project; conversationID = conversation; transcriptDirectory = directory
        case .addProjectThenResume(let project, let conversation, let directory):
            projectPath = project; conversationID = conversation; transcriptDirectory = directory
        }

        let url = URL(fileURLWithPath: projectPath, isDirectory: true)
        // A project row, or a result whose conversation id we never learned: there is
        // nothing to resume, so land on the project instead of launching a nameless agent.
        guard let pinned = UUID(uuidString: conversationID) else {
            if let existing = indexOfRepo(for: url) {
                repos[existing].isCollapsed = false
                emit(.projectCollapsed(id: repos[existing].id, isCollapsed: false))
                if let first = repos[existing].sessions.first { selectedSessionID = first.id }
            } else {
                addProject(at: url)
            }
            persist()
            return
        }

        let session = Session(
            title: ClaudeSession.sanitizedName(conversationID) ?? "session",
            workingDirectory: projectPath,
            transcriptDirectory: transcriptDirectory,
            pinnedConversationID: pinned
        )
        let deferred = resumeExisting(
            session, inProjectAt: projectPath, at: nil, directoryExists: directoryExists
        )
        if let target = indexOfRepo(for: url), repos[target].isCollapsed {
            repos[target].isCollapsed = false
            emit(.projectCollapsed(id: repos[target].id, isCollapsed: false))
        }
        selectedSessionID = session.id
        persist()

        if deferred {
            codexRestoreTask = Task { [weak self] in
                await self?.resumeRestoredCodex([session.id])
            }
        }
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS, including every existing `reopenLastClosed` test — the extraction must not change ⌘⇧T's behaviour at all. If any reopen test fails, the extraction dropped a rule; diff `resumeExisting` against the original `reinsertClosed`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Search/SearchActivation.swift \
        Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/SearchActivationTests.swift
git commit -m "feat: resume a searched conversation into a tab

Return on a result selects the tab when the conversation already has one, and
otherwise rebuilds a tab onto it — adding the project back to the sidebar
when it has left, and un-collapsing it either way, since a tab resumed into a
collapsed project comes back invisible.

Selecting rather than re-resuming a live conversation is a correctness rule,
not an optimisation: a second claude --resume means two processes appending
one transcript and colliding in claude's pid-keyed name registry.

The decision is a pure value (SearchActivation.Activation) so every branch is
testable without spawning an agent, and the launch reuses reinsertClosed's
body, extracted as resumeExisting. ⌘⇧T and ⌘K now share one resume path
rather than two that can drift — the existing reopen tests are what hold that
extraction honest.

Worktree conversations resume in their worktree directory. Resuming one in
the project root points the tab's watcher at a transcript nothing writes to
and silently loses title sync and subagent counts.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: The overlay panel

**Files:**
- Create: `Sources/FlightDeck/Search/SearchPanel.swift`
- Create: `Sources/FlightDeck/Search/SearchOverlayView.swift`
- Test: `Tests/FlightDeckTests/SearchSnippetTests.swift`

**Interfaces:**
- Consumes: `SearchModel` (Task 9), `SnippetSentinel` (Task 6).
- Produces: `@MainActor final class SearchPanel: NSPanel { init(model: SearchModel, onActivate: @escaping (SearchResult) -> Void); func present(over host: NSWindow); func dismiss() }`, `struct SearchOverlayView: View`, and `enum SearchSnippet { static func attributed(_ raw: String) -> AttributedString }`.

**Why an `NSPanel` and not a SwiftUI overlay inside `RootView`.** `Ghostty.SurfaceView` returns true from `performKeyEquivalent(with:)` for anything libghostty binds, and libghostty binds most ⌘-chords. A SwiftUI overlay inside the window would be fighting the terminal for every keystroke. A panel that becomes key takes focus off the surface entirely, so the field simply has it.

- [ ] **Step 1: Write the failing test for the one piece of the view that has logic**

```swift
// Tests/FlightDeckTests/SearchSnippetTests.swift
import XCTest
@testable import FlightDeck

/// Turning FTS5's marked-up snippet into something the row can draw.
///
/// The markers are U+0002/U+0003 rather than anything printable because the marked-up text
/// is arbitrary conversation content — an agent discussing HTML would otherwise produce a
/// snippet that highlights the wrong span.
final class SearchSnippetTests: XCTestCase {
    private func runs(_ attributed: AttributedString) -> [(String, Bool)] {
        attributed.runs.map { run in
            (String(attributed[run.range].characters), run.inlinePresentationIntent == .stronglyEmphasized)
        }
    }

    func testSentinelsBecomeEmphasisAndAreRemoved() {
        let result = SearchSnippet.attributed("don't fire a \u{2}rename\u{3} when")

        XCTAssertFalse(String(result.characters).contains(SnippetSentinel.open))
        XCTAssertFalse(String(result.characters).contains(SnippetSentinel.close))
        XCTAssertEqual(String(result.characters), "don't fire a rename when")
        XCTAssertEqual(runs(result).filter(\.1).map(\.0), ["rename"])
    }

    func testEveryMatchedTermIsEmphasised() {
        let result = SearchSnippet.attributed("\u{2}Rename\u{3} and \u{2}rename\u{3} again")
        XCTAssertEqual(runs(result).filter(\.1).map(\.0), ["Rename", "rename"])
    }

    func testTextWithNoSentinelsIsUnchangedAndUnemphasised() {
        let result = SearchSnippet.attributed("no markers here")

        XCTAssertEqual(String(result.characters), "no markers here")
        XCTAssertTrue(runs(result).filter(\.1).isEmpty)
    }

    /// A snippet truncated by FTS5's window can end mid-highlight. An unbalanced sentinel
    /// must degrade to plain text, never drop the rest of the line.
    func testAnUnclosedSentinelDoesNotSwallowTheRemainder() {
        let result = SearchSnippet.attributed("a \u{2}rename that never closes")
        XCTAssertEqual(String(result.characters), "a rename that never closes")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL — `cannot find 'SearchSnippet' in scope`.

- [ ] **Step 3: Write the snippet renderer and the view**

```swift
// Sources/FlightDeck/Search/SearchOverlayView.swift
import SwiftUI

/// Turns FTS5's sentinel-marked snippet into an `AttributedString`.
///
/// An unbalanced opening sentinel — which a snippet truncated at FTS5's window boundary can
/// genuinely produce — emphasises nothing and keeps the remaining text, because losing the
/// rest of the line is far worse than losing a highlight.
enum SearchSnippet {
    static func attributed(_ raw: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(raw)

        while let open = rest.firstIndex(of: SnippetSentinel.open) {
            result += AttributedString(String(rest[rest.startIndex..<open]))
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: SnippetSentinel.close) else {
                result += AttributedString(String(rest[afterOpen...]))
                return result
            }
            var marked = AttributedString(String(rest[afterOpen..<close]))
            marked.inlinePresentationIntent = .stronglyEmphasized
            result += marked
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return result
    }
}

/// The card: query field, result rows, footer.
///
/// Every row is a heading plus two lines, uniform across result kinds. The two lines are the
/// snippet for a transcript hit and the working directory plus agent detail for a name
/// match — the row must draw immediately either way and never wait on the index.
struct SearchOverlayView: View {
    @ObservedObject var model: SearchModel
    var onActivate: (SearchResult) -> Void
    var onDismiss: () -> Void

    /// Past this many rows the list scrolls instead of the card growing. Eight is where the
    /// card stops feeling like a menu and starts feeling like a window.
    private static let maximumVisibleRows = 8
    private static let rowHeight: CGFloat = 46

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            if !model.results.isEmpty {
                Divider()
                list
            }
            if let progress = model.indexingProgress, progress.indexed < progress.total {
                Divider()
                footer(progress)
            }
        }
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
        .shadow(radius: 30, y: 12)
        // The height spring. Driven by the result *count* rather than by the array, so a
        // rerank that returns the same number of rows does not re-animate — animating twice
        // for one keystroke is what makes a panel like this feel cheap.
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: model.results.count)
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search sessions and conversations", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($fieldFocused)
                .onSubmit { if let result = model.activateSelection() { onActivate(result) } }
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.results) { result in
                        SearchResultRow(result: result, isSelected: result.id == model.selectedID)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(result) }
                    }
                }
            }
            .frame(height: min(
                CGFloat(model.results.count), CGFloat(Self.maximumVisibleRows)
            ) * Self.rowHeight)
            .onChange(of: model.selectedID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func footer(_ progress: SearchIndexBuilder.Progress) -> some View {
        // Shown while history is still being read. A search that silently returns nothing
        // is worse than one that says it is still reading — and name results, which are the
        // common case, work the whole time.
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Indexing \(progress.indexed) of \(progress.total) conversations")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

/// One result. Heading plus exactly two lines, whatever the result kind.
private struct SearchResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(highlightedTitle).font(.system(size: 13, weight: .semibold))
                    Text(result.projectName).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Text(result.recency, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: 46, alignment: .top)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
    }

    private var symbol: String {
        switch result.kind {
        case .session: return "chevron.right"
        case .project: return "folder"
        case .conversation: return "text.alignleft"
        }
    }

    /// The two lines. A transcript hit shows its snippet; a name match shows where it lives,
    /// which is what distinguishes two sessions with the same name in different worktrees.
    private var detail: AttributedString {
        if let snippet = result.snippet { return SearchSnippet.attributed(snippet) }
        return AttributedString(result.projectPath)
    }

    private var highlightedTitle: AttributedString {
        var attributed = AttributedString(result.title)
        for range in result.highlightedRanges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
```

- [ ] **Step 4: Write the panel**

```swift
// Sources/FlightDeck/Search/SearchPanel.swift
import AppKit
import SwiftUI

/// The window the overlay lives in.
///
/// **Why a panel rather than a SwiftUI overlay in `RootView`.** `Ghostty.SurfaceView`
/// returns true from `performKeyEquivalent(with:)` for anything libghostty binds, and
/// libghostty binds most ⌘-chords — so an in-window overlay would be contending with the
/// terminal for every keystroke, including the arrow keys and Return this needs. A panel
/// that becomes key takes first-responder status off the surface entirely, and the text
/// field simply has focus.
///
/// **Why a child window.** Added to the deck window with `addChildWindow(_:ordered:)`, so it
/// tracks the host's moves, resizes and miniaturisation without observing anything.
@MainActor
final class SearchPanel: NSPanel {
    private let model: SearchModel
    private weak var host: NSWindow?

    init(model: SearchModel, onActivate: @escaping (SearchResult) -> Void) {
        self.model = model
        super.init(
            contentRect: .zero,
            // `.nonactivatingPanel` is deliberately absent: this panel must become key so
            // the terminal stops receiving keys while it is up.
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // the card draws its own; the scrim must not have one
        level = .floating
        isMovable = false
        // Closing the deck window must take this with it rather than leaving an orphan
        // floating over other apps.
        hidesOnDeactivate = true

        let root = SearchOverlayRoot(
            model: model,
            onActivate: { [weak self] result in self?.dismiss(); onActivate(result) },
            onDismiss: { [weak self] in self?.dismiss() }
        )
        contentView = NSHostingView(rootView: root)
    }

    /// Key and main, or the text field cannot take focus while a terminal is running.
    override var canBecomeKey: Bool { true }

    func present(over host: NSWindow) {
        self.host = host
        setFrame(host.frame, display: false)
        host.addChildWindow(self, ordered: .above)
        model.open()
        makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        model.close()
        host?.removeChildWindow(self)
        orderOut(nil)
        // Focus has to go back to the terminal explicitly. Ordering out a key child window
        // leaves the host key but leaves first responder unset, so the next keystroke would
        // go nowhere.
        host?.makeKeyAndOrderFront(nil)
    }

    /// Esc closes. Handled here rather than with `.keyboardShortcut(.cancelAction)` because
    /// the panel has no default button for SwiftUI to attach that to.
    override func cancelOperation(_ sender: Any?) { dismiss() }
}

/// Scrim plus card. Separated from `SearchOverlayView` so the dimming and the arrow-key
/// handling live with the window rather than with the list.
private struct SearchOverlayRoot: View {
    @ObservedObject var model: SearchModel
    var onActivate: (SearchResult) -> Void
    var onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.34)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            GeometryReader { geometry in
                SearchOverlayView(model: model, onActivate: onActivate, onDismiss: onDismiss)
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.18)
            }
        }
        // Arrow keys move the highlight. `onMoveCommand` rather than a key monitor: it is
        // scoped to this view's focus, so it cannot intercept anything once the panel is down.
        .onMoveCommand { direction in
            switch direction {
            case .up: model.moveSelection(by: -1)
            case .down: model.moveSelection(by: 1)
            default: break
            }
        }
        .onExitCommand { onDismiss() }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Search/SearchPanel.swift \
        Sources/FlightDeck/Search/SearchOverlayView.swift \
        Tests/FlightDeckTests/SearchSnippetTests.swift
git commit -m "feat: draw the search overlay as a key child panel

A borderless NSPanel rather than a SwiftUI overlay inside RootView, because
Ghostty.SurfaceView returns true from performKeyEquivalent for anything
libghostty binds — which is most ⌘-chords plus the arrows and Return this
needs. A panel that becomes key takes first responder off the surface
entirely, so the field simply has focus. Added as a child window so it
tracks the deck window without observing anything.

Rows are uniform: a heading plus exactly two lines whatever the kind, the
snippet for a transcript hit and the working directory for a name match, so
a row never waits on the index to draw. The height spring is keyed on the
result count rather than the array, so a rerank returning the same number of
rows does not animate twice for one keystroke.

FTS5's U+0002/U+0003 sentinels become emphasis. An unbalanced opener — which
a snippet truncated at the window boundary really produces — degrades to
plain text and keeps the rest of the line rather than swallowing it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Take ⌘K back from the terminal and wire it up

**Files:**
- Modify: `Sources/FlightDeck/GhosttyDefaults.conf`
- Create: `Sources/FlightDeck/Search/SearchCommands.swift`
- Create: `Sources/FlightDeck/Search/SearchCandidates.swift`
- Modify: `Sources/FlightDeck/SessionWindow.swift` (add `main`)
- Modify: `Sources/FlightDeck/FlightDeckApp.swift`
- Modify: `Sources/FlightDeck/AppDelegate.swift`
- Test: `Tests/FlightDeckTests/GhosttyDefaultsTests.swift`

**Interfaces:**
- Consumes: `SearchPanel` (Task 11), `SearchModel` (Task 9), `SearchIndexBuilder` (Task 7), `SearchCorpus` (Task 2), `SQLiteSearchIndex` (Task 6), `SearchActivation` (Task 10).
- Produces: `struct SearchCommands: Commands`, `Notification.Name.flightDeckOpenSearch`, `enum SearchCandidates { static func build(repos:conversations:modified:) -> [NameCandidate] }`, `SessionWindow.main: NSWindow?`.

**This is the task that fails silently if skipped.** Ghostty binds `super+k` to `clear_screen` with `performable: true` (`vendor/ghostty/src/config/Config.zig:6867`), and `MenuKeyEquivalents.shouldOfferToMenu` deliberately withholds performable bindings from the main menu. A ⌘K menu item would look correct in the menu and simply never fire while a terminal has focus.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/GhosttyDefaultsTests.swift
import XCTest
@testable import FlightDeck

/// The shipped libghostty defaults, asserted because their absence is invisible.
///
/// A missing unbind here does not produce an error, a warning, or a wrong-looking menu. The
/// menu item renders with its shortcut and silently never fires, because
/// `MenuKeyEquivalents.shouldOfferToMenu` withholds performable bindings from the menu and
/// `Ghostty.SurfaceView.performKeyEquivalent` swallows the key. Only a test catches it.
final class GhosttyDefaultsTests: XCTestCase {
    private func defaultsConfig() throws -> String {
        let url = try XCTUnwrap(
            Bundle(for: type(of: self)).url(forResource: "GhosttyDefaults", withExtension: "conf")
                ?? Bundle.main.url(forResource: "GhosttyDefaults", withExtension: "conf")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// ⌘K is Ghostty's clear_screen, bound performable. Search cannot have it until this
    /// unbind ships.
    func testCommandKIsUnboundSoTheSearchMenuItemCanFire() throws {
        XCTAssertTrue(try defaultsConfig().contains("keybind = super+k=unbind"))
    }

    /// The precedent, still in place: ⌘⇧T belongs to Reopen Closed Session.
    func testCommandShiftTRemainsUnbound() throws {
        XCTAssertTrue(try defaultsConfig().contains("keybind = super+shift+t=unbind"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: FAIL on `testCommandKIsUnboundSoTheSearchMenuItemCanFire`. If the resource cannot be found instead, add `GhosttyDefaults.conf` to the test target's resources in `project.yml` before continuing — a test that cannot read the file asserts nothing.

- [ ] **Step 3: Unbind ⌘K**

Append to `Sources/FlightDeck/GhosttyDefaults.conf`:

```
# Give ⌘K to Search.
#
# Ghostty binds super+k to `clear_screen` on macOS (src/config/Config.zig, "Mac-specific
# keyboard bindings"), and binds it `performable`. `MenuKeyEquivalents.shouldOfferToMenu`
# deliberately withholds performable bindings from the main menu — they must reach the
# terminal even when a menu item shares the chord — so as long as libghostty claims this
# key, `Ghostty.SurfaceView.performKeyEquivalent` swallows it and the Search menu item
# never fires while a terminal has focus, which is essentially always. It fails silently:
# the menu item looks correct and does nothing.
#
# Unbinding rather than reassigning, as with super+shift+t above: clear_screen has a
# perfectly good home on ⌘L in most shells, and Flight Deck has no equivalent of its own to
# route the chord to.
#
# Loaded before the user's own config (see the header), so anyone who wants ⌘K back on
# clear-screen can rebind it in ~/.config/ghostty/config.
keybind = super+k=unbind
```

- [ ] **Step 4: Add the menu command**

```swift
// Sources/FlightDeck/Search/SearchCommands.swift
import SwiftUI

extension Notification.Name {
    /// Posted by the ⌘K menu item. `AppDelegate` owns the panel, and a `Commands` struct
    /// has no route to it — the same shape `SessionCommands` uses for window-level actions.
    static let flightDeckOpenSearch = Notification.Name("flightDeckOpenSearch")
}

/// The ⌘K menu item.
///
/// In the File menu's `.textEditing` group rather than a menu of its own: it is a find, and
/// this is where a find belongs. It carries no `.disabled(...)` — a disabled `NSMenuItem`
/// does not fire its key equivalent, which would silently kill the shortcut, exactly as
/// `EditCommands` documents.
struct SearchCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Search…") {
                NotificationCenter.default.post(name: .flightDeckOpenSearch, object: nil)
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }
}
```

Register it in `FlightDeckApp.body`, alongside the existing command groups:

```swift
            .commands {
                SessionCommands(store: store, preferences: preferences)
                EditCommands()
                TabNavigationCommands(store: store)
                SearchCommands()
            }
```

- [ ] **Step 5: Build the name candidates, and let `SessionWindow` name the deck window**

`SearchModel` matches against a flat `[NameCandidate]` pushed in by its owner. Building that
list is real logic — three sources, each with its own recency — so it gets its own type and
its own test rather than being inlined into `AppDelegate`.

`SessionWindow` currently answers *whether* a window is the deck window (`isSessionWindow`,
`isKey`, `hitView`) but cannot hand you the window itself, which the panel needs as its
parent. Add that, in the same per-lookup style the type already argues for — nothing
captured, nothing to go stale:

```swift
    /// The session window itself, for callers that need to parent something to it.
    ///
    /// Searched per call rather than latched, for the reason this whole type exists: the
    /// obvious shortcuts (`NSApp.keyWindow`, `NSApp.mainWindow`) are both nil for as long as
    /// the app is inactive, even with the window fully on screen. `NSApp.windows` is not.
    static var main: NSWindow? {
        NSApp.windows.first { isSessionWindow($0) }
    }
```

```swift
// Tests/FlightDeckTests/SearchCandidatesTests.swift
import XCTest
@testable import FlightDeck

/// Building the name-match list from the deck and the index.
///
/// Three sources with three different recency answers, which is why this is a tested unit
/// rather than a closure inside `AppDelegate`.
final class SearchCandidatesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func repo(_ path: String, sessions: [Session] = []) -> Repo {
        var repo = Repo(url: URL(fileURLWithPath: path, isDirectory: true))
        repo.sessions = sessions
        return repo
    }

    func testEveryOpenSessionBecomesACandidate() {
        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd", sessions: [
                Session(title: "rename-break", workingDirectory: "/w/fd"),
                Session(title: "wifi", workingDirectory: "/w/fd"),
            ])],
            conversations: [:],
            modified: { _ in self.now }
        )

        let sessions = candidates.filter {
            if case .session = $0.kind { return true } else { return false }
        }
        XCTAssertEqual(sessions.map(\.name), ["rename-break", "wifi"])
    }

    func testEachProjectBecomesACandidateNamedByItsFolder() {
        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd")], conversations: [:], modified: { _ in self.now }
        )

        XCTAssertEqual(candidates.filter { $0.kind == .project }.map(\.name), ["fd"])
    }

    /// A past conversation with no open tab is still matchable by name — that is most of
    /// what makes ⌘K useful for history rather than only for the live deck.
    func testIndexedConversationsWithNoTabBecomeCandidates() {
        let candidates = SearchCandidates.build(
            repos: [],
            conversations: ["c1": IndexedConversation(name: "mobile-ui", projectPath: "/w/fd")],
            modified: { _ in self.now }
        )

        XCTAssertEqual(candidates.map(\.name), ["mobile-ui"])
        XCTAssertEqual(candidates.first?.kind, .conversation("c1"))
        XCTAssertEqual(candidates.first?.projectPath, "/w/fd")
    }

    /// A conversation that already has a tab must appear once, as the session — not twice,
    /// once as a tab and once as history, with two different meanings for Return.
    func testAConversationWithAnOpenTabIsNotAlsoListedAsHistory() {
        let id = UUID()
        let session = Session(id: id, title: "rename-break", workingDirectory: "/w/fd")

        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd", sessions: [session])],
            conversations: [
                id.uuidString.lowercased():
                    IndexedConversation(name: "rename-break", projectPath: "/w/fd"),
            ],
            modified: { _ in self.now }
        )

        XCTAssertEqual(candidates.filter { $0.name == "rename-break" }.count, 1)
    }

    /// Recency comes from the transcript's mtime. There is no per-session activity stamp
    /// anywhere in the model, and the file already records exactly this — a live session
    /// appends to it constantly — so adding one would duplicate a fact that could then
    /// disagree with itself.
    func testRecencyComesFromTheTranscriptModificationDate() {
        let stamp = now.addingTimeInterval(-500)
        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd", sessions: [
                Session(title: "rename-break", workingDirectory: "/w/fd"),
            ])],
            conversations: [:],
            modified: { _ in stamp }
        )

        XCTAssertEqual(candidates.first?.lastActivity, stamp)
    }

    /// A project is as recent as its liveliest session, so an active project outranks a
    /// dormant one at equal match quality.
    func testAProjectIsAsRecentAsItsNewestSession() {
        let old = Session(title: "old", workingDirectory: "/w/fd")
        let new = Session(title: "new", workingDirectory: "/w/fd")
        let stamps = [
            ClaudeSession.transcriptURL(
                sessionID: old.pinnedConversationID, workingDirectory: "/w/fd"
            ): now.addingTimeInterval(-1000),
            ClaudeSession.transcriptURL(
                sessionID: new.pinnedConversationID, workingDirectory: "/w/fd"
            ): now,
        ]

        let candidates = SearchCandidates.build(
            repos: [repo("/w/fd", sessions: [old, new])],
            conversations: [:],
            modified: { stamps[$0] ?? .distantPast }
        )

        XCTAssertEqual(candidates.first { $0.kind == .project }?.lastActivity, now)
    }
}
```

```swift
// Sources/FlightDeck/Search/SearchCandidates.swift
import Foundation

/// Flattens the deck and the index into the one list `SearchModel` matches names against.
///
/// Three sources: open tabs, the projects holding them, and every conversation the index has
/// a name for. A conversation that already has a tab is contributed by the tab and *not*
/// again by the index, so it appears once rather than twice with two different meanings for
/// Return.
///
/// **Where recency comes from.** The transcript's modification date, for all three. There is
/// no per-session activity timestamp anywhere in the model, and the file already records
/// exactly this — a live session appends to it constantly — so introducing one would
/// duplicate a fact that can then disagree with itself. `modified` is injected so all of this
/// is testable without touching a filesystem.
enum SearchCandidates {
    static func build(
        repos: [Repo],
        conversations: [String: Conversation],
        modified: (URL) -> Date
    ) -> [NameCandidate] {
        var candidates: [NameCandidate] = []
        var claimed: Set<String> = []

        for repo in repos {
            var newest = Date.distantPast
            for session in repo.sessions {
                let conversation = session.pinnedConversationID.uuidString.lowercased()
                claimed.insert(conversation)
                let stamp = modified(ClaudeSession.transcriptURL(
                    sessionID: session.pinnedConversationID,
                    workingDirectory: session.transcriptDirectory
                ))
                newest = max(newest, stamp)
                candidates.append(NameCandidate(
                    id: session.id.uuidString,
                    kind: .session(session.id),
                    name: session.title,
                    projectPath: repo.url.path,
                    projectName: repo.displayName,
                    lastActivity: stamp,
                    conversationID: conversation
                ))
            }
            candidates.append(NameCandidate(
                id: "project:\(repo.url.path)",
                kind: .project,
                name: repo.displayName,
                projectPath: repo.url.path,
                projectName: repo.displayName,
                lastActivity: newest,
                conversationID: nil
            ))
        }

        // Sorted by id so the list is deterministic regardless of dictionary ordering —
        // `SearchRanker`'s final tiebreak is the result id, and a candidate list that
        // reshuffled between calls would defeat it.
        for (id, conversation) in conversations.sorted(by: { $0.key < $1.key })
        where !claimed.contains(id) {
            candidates.append(NameCandidate(
                id: "conversation:\(id)",
                kind: .conversation(id),
                name: conversation.name,
                projectPath: conversation.projectPath,
                projectName: URL(fileURLWithPath: conversation.projectPath).lastPathComponent,
                // Unknown without stat-ing every historical transcript, which would put a
                // filesystem walk on the ⌘K keystroke. Historical conversations therefore
                // sort last within their tier, which is the right default: anything with a
                // live tab is more likely to be what you want.
                lastActivity: .distantPast,
                conversationID: id
            ))
        }
        return candidates
    }
}
```

- [ ] **Step 6: Own the index and the panel in `AppDelegate`**

`AppDelegate` already finds the store via `.flightDeckStoreReady` / `SessionStore.current`; hang the search stack off the same hook. Add:

```swift
    /// The search index, its backfill, and the overlay panel.
    ///
    /// Owned here rather than by `RootView` because the panel is a window, the backfill
    /// outlives any view, and the index file must be opened exactly once per launch.
    private var searchIndex: SQLiteSearchIndex?
    private var searchModel: SearchModel?
    private var searchPanel: SearchPanel?
    private var searchBuildTask: Task<Void, Never>?

    /// Beside `sessions.json`, and honouring `-FlightDeckStateDir` for the same reason that
    /// flag exists: a debug instance pointed at a copy of a real deck must not also write
    /// into the real index.
    private static func searchIndexURL() -> URL {
        (FlightDeckApp.stateDirectory() ?? FileSessionPersistence.defaultDirectory())
            .appendingPathComponent("search-index.sqlite")
    }

    @MainActor
    private func startSearch(store: SessionStore) {
        guard let index = try? SQLiteSearchIndex(at: Self.searchIndexURL()) else { return }
        let model = SearchModel(index: index, projects: { store.repos.map(\.url.path) })
        let panel = SearchPanel(model: model) { [weak store] result in
            guard let store else { return }
            let open = store.repos.flatMap(\.sessions).map {
                SearchActivation.ActiveSession(
                    id: $0.id, conversationID: $0.pinnedConversationID.uuidString.lowercased()
                )
            }
            store.openConversation(SearchActivation.plan(
                for: result, openSessions: open, projects: store.repos.map(\.url.path)
            ))
        }

        searchIndex = index
        searchModel = model
        searchPanel = panel

        NotificationCenter.default.addObserver(
            forName: .flightDeckOpenSearch, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.presentSearch() }
        }

        // Deferred off the launch path: a backfill parsing hundreds of megabytes must not
        // compete with restoring the deck and resuming its agents. Name search works from
        // the first keystroke regardless.
        let builder = SearchIndexBuilder(index: index)
        searchBuildTask = Task { [weak model] in
            try? await Task.sleep(for: .seconds(3))
            let entries = SearchCorpus.directories(
                forProjects: store.repos.map(\.url.path),
                projectsRoot: ClaudeSession.defaultProjectsRoot,
                listing: SearchCorpus.defaultListing,
                exists: { FileManager.default.fileExists(atPath: $0) }
            )
            await builder.build(entries) { progress in
                Task { @MainActor in model?.indexingProgressChanged(progress) }
            }
            await MainActor.run { model?.indexingProgressChanged(nil) }
        }
    }

    @MainActor
    private func presentSearch() {
        guard let panel = searchPanel, let model = searchModel, let store = SessionStore.current,
              let host = SessionWindow.main
        else { return }
        model.candidatesChanged(SearchCandidates.build(
            repos: store.repos,
            conversations: (try? searchIndex?.conversationNames()) ?? [:],
            modified: { url in
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
            }
        ))
        panel.present(over: host)
    }
```

Also route live-session text into the index where `SessionStore` builds its watchers — pass `onMessages:` through to `index.ingest(_:from:projectPath:offset:)` for that session's transcript URL, using the watcher's own `url` and the offset it already tracks.

- [ ] **Step 7: Build and confirm ⌘K opens over a focused terminal**

```bash
./scripts/build.sh 2>&1 | tail -5
open -a "$PWD/DerivedData/Build/Products/Debug/Flight Deck.app" --args -FlightDeckStateDir /tmp/fd-search-check
```

Launch the Debug build **in place** — never swap `/Applications`, which kills every other session on this machine. Click into a terminal so a Ghostty surface has focus, then press ⌘K. The panel must appear. If it does not, the unbind is not in the bundled `GhosttyDefaults.conf` — check it was copied into the app's Resources.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/GhosttyDefaults.conf Sources/FlightDeck/Search/SearchCommands.swift \
        Sources/FlightDeck/Search/SearchCandidates.swift Sources/FlightDeck/SessionWindow.swift \
        Tests/FlightDeckTests/SearchCandidatesTests.swift \
        Sources/FlightDeck/FlightDeckApp.swift Sources/FlightDeck/AppDelegate.swift \
        Tests/FlightDeckTests/GhosttyDefaultsTests.swift
git commit -m "feat: open the search overlay on ⌘K

Ghostty binds super+k to clear_screen with performable: true, and
MenuKeyEquivalents.shouldOfferToMenu withholds performable bindings from the
menu, so a ⌘K menu item renders correctly and never fires while a terminal
has focus — which is always. Unbound in GhosttyDefaults.conf, the same route
⌘⇧T already takes, and asserted by a test because nothing in the UI reveals
the omission.

The index, its backfill and the panel are owned by AppDelegate: the panel is
a window, the backfill outlives any view, and the index file must be opened
once per launch. The index lives beside sessions.json and honours
-FlightDeckStateDir, so a debug instance pointed at a copy of a real deck
does not write into the real index.

The backfill is deferred three seconds off the launch path so parsing
hundreds of megabytes does not compete with restoring the deck and resuming
its agents. Name search works from the first keystroke regardless.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---
## Task 13: Smoke coverage and docs

**Files:**
- Modify: `UITests/FlightDeckUITests/` (one added `runActivity` group)
- Modify: `docs/ARCHITECTURE.md`, `docs/HANDOFF.md`, `README.md`

- [ ] **Step 1: Add one smoke group**

Add to the existing single test function, following the surrounding `runActivity` style:

```swift
        XCTContext.runActivity(named: "⌘K search opens, filters, and closes") { _ in
            // The regression this exists for: ⌘K reaching the menu at all while a terminal
            // has focus. Ghostty binds it performable, so a missing unbind in
            // GhosttyDefaults.conf makes the menu item silently inert — invisible to every
            // unit test, and only observable with a real surface focused.
            app.typeKey("k", modifierFlags: .command)
            let field = app.textFields["Search sessions and conversations"]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘K did not open the overlay")

            field.typeText("session")
            XCTAssertTrue(app.staticTexts.count > 0)

            app.typeKey(.escape, modifierFlags: [])
            XCTAssertFalse(field.waitForExistence(timeout: 2), "Esc did not close the overlay")
        }
```

- [ ] **Step 2: Run the smoke suite once**

Run: `./scripts/smoke.sh 2>&1 | tail -20`
Expected: ends `SMOKE PASS`.

**Run it once.** Per `AGENTS.md` rule 4 it seizes the foreground for ~70 s and captures the user's keystrokes as phantom failures, and it is throttled to one run per 120 s on purpose. If this group is flaky, do **not** re-run the suite — add a skipped-by-default hunt case gated on a `TEST_RUNNER_`-prefixed variable, as `testPermissionBypassConfirmationUnderChurn` does.

- [ ] **Step 3: Update the docs**

- `docs/ARCHITECTURE.md` — a "Search" subsection: the corpus rule (§5), the 5%-of-transcript measurement and why it decides the architecture, the two-clock split, and that the index is a disposable cache.
- `docs/HANDOFF.md` — ⌘K in the shortcut list; note that first launch backfills in the background.
- `README.md` — one line in the feature list, in the existing voice.

- [ ] **Step 4: Commit**

```bash
git add UITests docs README.md
git commit -m "test(ui): cover ⌘K opening over a focused terminal, and document search

The smoke group exists for one regression no unit test can catch: whether ⌘K
reaches the menu at all while a Ghostty surface has focus. Ghostty binds it
performable, so a missing unbind makes the menu item silently inert, and only
a real focused surface shows it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Verification

End to end, after Task 13:

1. `./scripts/test-unit.sh` — the whole unit suite green, including the existing `reopenLastClosed` tests that hold Task 10's extraction honest.
2. `./scripts/build.sh`, then launch the Debug build **in place** with `-FlightDeckStateDir /tmp/fd-search-check`.
3. ⌘K with a terminal focused → the panel opens (the §12 regression).
4. Type a session name → it ranks first, above any transcript hit.
5. Type a phrase you remember saying → the transcript hit shows two lines with the terms marked.
6. Return on a historical conversation → its project expands and the conversation resumes in a new tab on the right conversation id.
7. Watch the footer during first launch — it must report progress rather than returning silence.
8. Confirm the measured backfill time from Task 1 Step 5 against the real corpus.
