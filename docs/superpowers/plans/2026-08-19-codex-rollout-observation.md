# Codex Rollout Observation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make codex tabs observable — title, busy/idle and unread — by tailing the files codex writes, instead of listening for notifications a different process never sends us.

**Architecture:** Extract the byte-level tailing already inside `TranscriptWatcher` into a `TailReader`, then put three watchers on it: claude's existing transcript watcher, a new per-tab codex rollout watcher (turn boundaries), and one app-wide codex name watcher over `session_index.jsonl` (titles). Delete `CodexRuntime`'s notification path and the ~150 lines of reconcile-ordering machinery that existed only to make it safe.

**Tech Stack:** Swift 5, XCTest, XcodeGen. macOS app target `FlightDeck`, test target `FlightDeckTests`.

**Spec:** `docs/superpowers/specs/2026-08-19-codex-rollout-observation-design.md`

## Global Constraints

- **Test runner:** `./scripts/test-unit.sh` (runs `xcodegen generate` first, so new files under `Sources/` and `Tests/` are picked up automatically). It has **no filter argument** — it runs the whole suite in ~9s. Pipe through `rg` to find a named test.
- **Baseline:** 748 unit tests, 0 failures, 5 skipped. Every task must end at 0 failures.
- **No committed test may spawn `codex` or pop a modal.** Real-codex tests live only in `Tests/FlightDeckTests/CodexIntegrationTests.swift`, behind `FLIGHT_DECK_CODEX_INTEGRATION=1`.
- **Never touch live state:** `~/Library/Application Support/Flight Deck/sessions.json`, `UserDefaults`, `~/.claude`, or `~/.codex` beyond reads and threads the test itself created. Any codex process a task starts must run under an isolated `CODEX_HOME`.
- **Do not run `scripts/smoke.sh` in a loop** — it steals focus for ~40s.
- **This checkout is shared.** Commit by explicit path. Never `git add -A`, `checkout .`, `stash`, `rebase`, or `pull`.
- **`Tests/FlightDeckTests/Fixtures/` is a folder reference with `buildPhase: resources`.** Files placed there are copied into the test bundle, not compiled. A `.swift` file there silently vanishes.
- **Fixture rule:** captured files may have whole lines **dropped**, never **edited**. A fixture whose bytes a human typed is the failure mode this branch already shipped three times.

---

### Task 1: Extract `TailReader`

The tailing logic in `Scan.read` is correct and hard-won — where to start reading, how to survive a file that shrank, how to avoid splitting a record mid-write. It is currently welded to `ClaudeSession.events`. Lift it out unchanged in behaviour, and parameterize the one policy that must differ for a shared index file.

**Files:**
- Create: `Sources/FlightDeck/TailReader.swift`
- Modify: `Sources/FlightDeck/TranscriptWatcher.swift` (the `Scan.read` body only)
- Test: `Tests/FlightDeckTests/TailReaderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum TailTruncationPolicy { case restartFromZero, resumeAtEnd }`; `struct TailRead: Sendable { var offset: UInt64; var hasChosenStart: Bool; var lines: [String] }`; `enum TailReader { static func read(url: URL, offset: UInt64, hasChosenStart: Bool, truncation: TailTruncationPolicy = .restartFromZero) -> TailRead }`. Tasks 4 and 5 both call `TailReader.read`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/TailReaderTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class TailReaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    /// A file that already existed on the first look predates the watcher, so its history is
    /// not ours to replay — only what is appended afterwards is.
    func testSkipsWhatExistedBeforeTheFirstLook() throws {
        let url = dir.appendingPathComponent("f.jsonl")
        try write("old-a\nold-b\n", to: url)

        let first = TailReader.read(url: url, offset: 0, hasChosenStart: false)
        XCTAssertEqual(first.lines, [], "the first look at an existing file reads nothing")
        XCTAssertTrue(first.hasChosenStart)

        try write("old-a\nold-b\nnew\n", to: url)
        let second = TailReader.read(url: url, offset: first.offset, hasChosenStart: true)
        XCTAssertEqual(second.lines, ["new"])
    }

    /// A file that does not exist yet has no history to skip, so whatever appears there later
    /// is ours from byte 0. Deciding that on the *missing* look is what makes the first
    /// record in a file that springs into existence with content already in it arrive.
    func testReadsFromZeroWhenTheFileDidNotExistYet() throws {
        let url = dir.appendingPathComponent("later.jsonl")

        let first = TailReader.read(url: url, offset: 0, hasChosenStart: false)
        XCTAssertTrue(first.hasChosenStart, "a missing file still settles where reading starts")
        XCTAssertEqual(first.offset, 0)

        try write("born-with-content\n", to: url)
        let second = TailReader.read(url: url, offset: first.offset, hasChosenStart: true)
        XCTAssertEqual(second.lines, ["born-with-content"])
    }

    /// A read can land mid-write, so a trailing line with no newline is held back until it
    /// is whole.
    func testHoldsBackAPartialTrailingLine() throws {
        let url = dir.appendingPathComponent("f.jsonl")
        try write("", to: url)
        let primed = TailReader.read(url: url, offset: 0, hasChosenStart: false)

        try write("whole\npart", to: url)
        let read = TailReader.read(url: url, offset: primed.offset, hasChosenStart: true)
        XCTAssertEqual(read.lines, ["whole"])

        try write("whole\npartial-now-complete\n", to: url)
        let next = TailReader.read(url: url, offset: read.offset, hasChosenStart: true)
        XCTAssertEqual(next.lines, ["partial-now-complete"])
    }

    /// Default policy: a per-conversation file that shrank was replaced, and the replacement
    /// is entirely ours.
    func testRestartsFromZeroWhenAReplacedFileShrinks() throws {
        let url = dir.appendingPathComponent("f.jsonl")
        try write("", to: url)
        let primed = TailReader.read(url: url, offset: 0, hasChosenStart: false)
        try write("a\nb\nc\n", to: url)
        let read = TailReader.read(url: url, offset: primed.offset, hasChosenStart: true)
        XCTAssertEqual(read.lines, ["a", "b", "c"])

        try write("z\n", to: url)
        let after = TailReader.read(url: url, offset: read.offset, hasChosenStart: true)
        XCTAssertEqual(after.lines, ["z"], "a shorter file is a new file, read from the top")
    }

    /// Index policy: a shared append-only file that shrank was COMPACTED, and its history is
    /// not ours to replay. Every replayed line would re-apply a stale value.
    func testResumesAtTheEndWhenACompactedFileShrinks() throws {
        let url = dir.appendingPathComponent("index.jsonl")
        try write("", to: url)
        let primed = TailReader.read(url: url, offset: 0, hasChosenStart: false,
                                     truncation: .resumeAtEnd)
        try write("one\ntwo\nthree\n", to: url)
        let read = TailReader.read(url: url, offset: primed.offset, hasChosenStart: true,
                                   truncation: .resumeAtEnd)
        XCTAssertEqual(read.lines, ["one", "two", "three"])

        try write("compacted\n", to: url)
        let after = TailReader.read(url: url, offset: read.offset, hasChosenStart: true,
                                    truncation: .resumeAtEnd)
        XCTAssertEqual(after.lines, [], "compaction must not replay history as fresh news")

        try write("compacted\nfresh\n", to: url)
        let next = TailReader.read(url: url, offset: after.offset, hasChosenStart: true,
                                   truncation: .resumeAtEnd)
        XCTAssertEqual(next.lines, ["fresh"], "and reading must continue from there")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | rg -i "tailreader|error:" | head -20`
Expected: compile failure — `cannot find 'TailReader' in scope`.

- [ ] **Step 3: Write `TailReader`**

Create `Sources/FlightDeck/TailReader.swift`:

```swift
import Foundation

/// What a tailed file getting SHORTER than the offset we hold means.
///
/// The two answers are opposites, and picking the wrong one is silently destructive rather
/// than noisy, which is why this is a parameter and not a constant.
enum TailTruncationPolicy {
    /// The file was replaced, and the replacement is entirely ours to read. Correct for a
    /// file keyed to one conversation for its whole lifetime.
    case restartFromZero
    /// The file was compacted, and its history is NOT ours to replay. Correct for a shared
    /// append-only index, where every replayed line re-applies a value that has since moved.
    case resumeAtEnd
}

/// One look at a tailed file: how far reading got, and the complete lines it found.
///
/// Pure and `Sendable` — no actor state, no callbacks — so the read can run off the main
/// actor and only the fold back into watcher state has to return to it.
struct TailRead: Sendable {
    var offset: UInt64
    var hasChosenStart: Bool
    var lines: [String] = []
}

/// Incremental line-by-line tailing of an append-only file.
///
/// Extracted verbatim from `Scan.read`, which had carried this logic since the first
/// transcript watcher. Three things in here are load-bearing and were each learned from a
/// bug: where a first look starts reading, what a shrinking file means, and never consuming
/// a trailing line that has no newline yet.
enum TailReader {
    static func read(
        url: URL,
        offset: UInt64,
        hasChosenStart: Bool,
        truncation: TailTruncationPolicy = .restartFromZero
    ) -> TailRead {
        var result = TailRead(offset: offset, hasChosenStart: hasChosenStart)

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            // Nothing on disk, but that settles where reading will start: a file that does
            // not exist while we are *already* watching has no history to skip, so whatever
            // appears here later is ours from byte 0.
            //
            // Deciding it here rather than on the first successful open is what makes the
            // first record in a file that springs into existence with content already in it
            // arrive. `claude` buffers its startup records and creates the transcript only
            // when it first has something to persist — for a session renamed before its
            // first turn, that is the rename itself.
            result.hasChosenStart = true
            return result
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0

        // The file already existed on our first look, so it predates the watcher: start
        // tailing from its current end rather than from 0. A restored session points at a
        // file that may be huge, and a codex rollout carries an ~18 KB `session_meta` header
        // before any turn happens. Neither is news.
        if !result.hasChosenStart {
            result.hasChosenStart = true
            result.offset = size
        } else if size < result.offset {
            switch truncation {
            case .restartFromZero: result.offset = 0
            case .resumeAtEnd: result.offset = size
            }
        }
        guard size > result.offset else { return result }

        try? handle.seek(toOffset: result.offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return result }

        // Consume only through the last complete line. A trailing partial line is left
        // unread so the next read sees it whole — the writer appends this file while we read
        // it, and a read can land mid-write.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return result }
        let consumed = data.distance(from: data.startIndex, to: lastNewline) + 1
        result.offset += UInt64(consumed)

        result.lines = String(decoding: data[..<lastNewline], as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        return result
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`-style output with 0 failures (753 tests now).

- [ ] **Step 5: Refactor `Scan.read` onto `TailReader`**

In `Sources/FlightDeck/TranscriptWatcher.swift`, replace the whole body of `Scan.read` (keep the signature and the doc comment) with:

```swift
    static func read(
        url: URL,
        offset: UInt64,
        hasChosenStart: Bool,
        sessionID: UUID
    ) -> Scan {
        let tail = TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart)
        var result = Scan(offset: tail.offset, hasChosenStart: tail.hasChosenStart)
        for line in tail.lines {
            result.events += ClaudeSession.events(inLine: line, sessionID: sessionID)
        }
        return result
    }
```

Move the three explanatory comments that lived inside the old body (missing file / first look / partial line) into `TailReader` — they are already reproduced there in Step 3, so simply delete them here rather than duplicating.

- [ ] **Step 6: Run the full suite — claude's behaviour must not have moved**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: 0 failures. `TranscriptWatcherTests` in particular must be entirely green; it pins the start-position rules this refactor just moved.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/TailReader.swift Sources/FlightDeck/TranscriptWatcher.swift Tests/FlightDeckTests/TailReaderTests.swift
git commit -m "refactor: extract the file tailing TranscriptWatcher already did

Three watchers need it now, and a shared append-only index needs the
opposite answer to 'the file got shorter' than a per-conversation file
does. Behaviour for claude is unchanged."
```

---

### Task 2: Capture the codex fixtures

There is no schema for the rollout or index formats — `codex app-server generate-json-schema` covers the protocol only. The substitute is files real codex wrote, checked in with provenance, with lines dropped but never edited.

**Files:**
- Create: `Tests/FlightDeckTests/Fixtures/Codex/rollout.captured.jsonl`
- Create: `Tests/FlightDeckTests/Fixtures/Codex/turn-aborted.captured.jsonl`
- Create: `Tests/FlightDeckTests/Fixtures/Codex/session-index.captured.jsonl`
- Create: `Tests/FlightDeckTests/Fixtures/Codex/rollout.captured.provenance.json`
- Test: `Tests/FlightDeckTests/CodexRolloutFixtureTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: three fixture files loadable from the test bundle at `subdirectory: "Fixtures/Codex"`. Task 3 asserts the mapper against `rollout.captured.jsonl` and `turn-aborted.captured.jsonl`; Task 5 uses `session-index.captured.jsonl`.

- [ ] **Step 1: Copy the captured files from the design probe**

The design's probe already produced them under an isolated `CODEX_HOME`. Copy, keeping only `session_meta` and `event_msg` lines (dropping whole lines is allowed; editing one is not):

```bash
SP=/private/tmp/claude-501/-Users-nate-Projects-Protos-n-Tools-flight-deck/a3f8c025-ec3b-4953-b996-a4124759c23f/scratchpad
SRC=$SP/codexhome/sessions/2026/08/19/rollout-2026-08-19T11-47-47-01a01aeb-f936-7aa3-81b6-63359cdaf7e6.jsonl
jq -c 'select(.type=="session_meta" or .type=="event_msg")' "$SRC" \
  > Tests/FlightDeckTests/Fixtures/Codex/rollout.captured.jsonl
cp "$SP/codexhome/session_index.jsonl" \
  Tests/FlightDeckTests/Fixtures/Codex/session-index.captured.jsonl
```

If that scratchpad is gone, regenerate it — the steps are in the spec's §1 and reduce to: run `codex app-server` under a temp `CODEX_HOME`, `initialize` with real `clientInfo`, `thread/start {cwd}`, `thread/name/set`, then `codex exec resume --skip-git-repo-check <id> "Reply with exactly the word: ok"` twice from that cwd, then `thread/name/set` again from a second connection to add index lines. **Never regenerate against the real `~/.codex`.**

- [ ] **Step 2: Capture the one real `turn_aborted` line**

No probe produced an aborted turn; exactly one exists in local history, and it carries no prose — `{turn_id, reason, completed_at, duration_ms}`:

```bash
cd ~/.codex/sessions && for f in $(find . -name '*.jsonl'); do
  jq -c 'select(.type=="event_msg" and .payload.type=="turn_aborted")' "$f"
done | head -1 > /tmp/turn-aborted.jsonl
cd - && cp /tmp/turn-aborted.jsonl Tests/FlightDeckTests/Fixtures/Codex/turn-aborted.captured.jsonl
```

- [ ] **Step 3: Write the provenance file**

Create `Tests/FlightDeckTests/Fixtures/Codex/rollout.captured.provenance.json`:

```json
{
  "files": [
    "rollout.captured.jsonl",
    "turn-aborted.captured.jsonl",
    "session-index.captured.jsonl"
  ],
  "isVerbatimCapturedOutput": true,
  "codexVersion": "codex-cli 0.148.0",
  "capturedOn": "2026-08-19",
  "capturedBy": [
    "A thread created over `codex app-server` under an isolated CODEX_HOME, then driven by a",
    "real `codex resume` TUI and by `codex exec resume --skip-git-repo-check`. The index file",
    "is that home's session_index.jsonl after three renames: one at creation, one from a",
    "second app-server connection, one typed as `/rename` into the TUI.",
    "turn-aborted.captured.jsonl is a single line lifted from local codex history — no probe",
    "produced an interrupted turn, and the record carries no prose."
  ],
  "editingRule": [
    "Lines may be DROPPED, never EDITED. rollout.captured.jsonl is the source rollout filtered",
    "to `session_meta` and `event_msg` records; every surviving line is byte-for-byte what",
    "codex wrote.",
    "",
    "Unlike codex-app-server-v2.generated.json, this is not generated from a schema, because",
    "no schema for these formats exists — `codex app-server generate-json-schema` covers the",
    "protocol only. That makes these files the weakest ground truth in the suite: they record",
    "what codex DID on one day, not what it DECLARES. `CodexIntegrationTests` is what notices",
    "when that stops being true; run it with FLIGHT_DECK_CODEX_INTEGRATION=1."
  ]
}
```

- [ ] **Step 4: Write the test that proves the fixtures are in the bundle and say what we think**

Create `Tests/FlightDeckTests/CodexRolloutFixtureTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// Guards the fixtures themselves. `Fixtures/` is a folder reference copied as resources, so
/// a file that fails to land in the bundle produces a confusing nil at the first use site
/// rather than an error here.
final class CodexRolloutFixtureTests: XCTestCase {
    static func lines(_ name: String) throws -> [String] {
        let url = try XCTUnwrap(
            Bundle(for: CodexRolloutFixtureTests.self).url(
                forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Codex"
            ),
            "Fixtures/Codex/\(name).jsonl not found in the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    func testTheCapturedRolloutHasTheTurnRecordsThisAppReads() throws {
        let kinds = try Self.lines("rollout.captured").compactMap { line -> String? in
            let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            guard obj?["type"] as? String == "event_msg" else { return nil }
            return (obj?["payload"] as? [String: Any])?["type"] as? String
        }
        XCTAssertEqual(kinds.filter { $0 == "task_started" }.count, 3)
        XCTAssertEqual(kinds.filter { $0 == "task_complete" }.count, 2,
                       "the third turn was interrupted by an approval prompt and never "
                       + "completed — that asymmetry is the point of this capture")
    }

    func testTheCapturedIndexCarriesRenamesFromBothWriters() throws {
        let names = try Self.lines("session-index.captured").compactMap { line -> String? in
            let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            return obj?["thread_name"] as? String
        }
        XCTAssertEqual(names.count, 3, "one line per rename, append-only")
        XCTAssertEqual(names.last, "tui side rename",
                       "the last writer was the TUI's own /rename, which is the case the "
                       + "app-server notification path could never see")
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `./scripts/test-unit.sh 2>&1 | rg -i "CodexRolloutFixture|failed|error:" | head -20`
Expected: both tests pass. A "not found in the test bundle" failure means `xcodegen generate` did not pick the files up — confirm they are inside `Tests/FlightDeckTests/Fixtures/Codex/`.

- [ ] **Step 6: Commit**

```bash
git add Tests/FlightDeckTests/Fixtures/Codex/rollout.captured.jsonl Tests/FlightDeckTests/Fixtures/Codex/turn-aborted.captured.jsonl Tests/FlightDeckTests/Fixtures/Codex/session-index.captured.jsonl Tests/FlightDeckTests/Fixtures/Codex/rollout.captured.provenance.json Tests/FlightDeckTests/CodexRolloutFixtureTests.swift
git commit -m "test: capture what codex actually writes to disk

No schema exists for the rollout or session-index formats, so these are
captured files rather than generated ones, with lines dropped but never
edited. The third turn is deliberately unterminated: that is what an
approval prompt looks like on disk."
```

---

### Task 3: Map rollout records to `AgentEvent`

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift` (add a function; the notification path stays until Task 6)
- Test: `Tests/FlightDeckTests/CodexRolloutMapperTests.swift`

**Interfaces:**
- Consumes: `CodexRolloutFixtureTests.lines(_:)` from Task 2.
- Produces: `CodexEventMapper.events(inRolloutLine line: String) -> [AgentEvent]`. Tasks 4 and 6 call it.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/CodexRolloutMapperTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// Asserted against captured codex output, not against payloads written here. Three of this
/// branch's worst defects were assumptions validated against fixtures their author wrote.
final class CodexRolloutMapperTests: XCTestCase {
    func testACapturedRolloutProducesTheTurnEventsInOrder() throws {
        let events = try CodexRolloutFixtureTests.lines("rollout.captured")
            .flatMap { CodexEventMapper.events(inRolloutLine: $0) }

        // Two complete turns, then one that started and never finished — the approval prompt.
        XCTAssertEqual(events, [
            .activity(.busy), .activity(.idle), .turnEnded,
            .activity(.busy), .activity(.idle), .turnEnded,
            .activity(.busy),
        ])
    }

    /// The tail of that sequence is a user-visible limitation, not an oversight: codex writes
    /// nothing when it starts waiting on approval, so the tab stays busy. See the spec's §5.
    func testAnApprovalPromptLeavesTheThreadLookingBusy() throws {
        let events = try CodexRolloutFixtureTests.lines("rollout.captured")
            .flatMap { CodexEventMapper.events(inRolloutLine: $0) }
        XCTAssertEqual(events.last, .activity(.busy))
        XCTAssertFalse(events.contains(.activity(.waiting)),
                       "nothing in a rollout can justify .waiting; inferring it from a "
                       + "tool call with no output is a guess this app does not make")
    }

    func testAnAbortedTurnEndsTheTurnJustLikeACompletedOne() throws {
        let line = try XCTUnwrap(CodexRolloutFixtureTests.lines("turn-aborted").first)
        XCTAssertEqual(CodexEventMapper.events(inRolloutLine: line),
                       [.activity(.idle), .turnEnded])
    }

    func testNonEventRecordsAndGarbageProduceNothing() throws {
        let responseItem = #"{"type":"response_item","payload":{"type":"message"}}"#
        XCTAssertEqual(CodexEventMapper.events(inRolloutLine: responseItem), [])
        XCTAssertEqual(CodexEventMapper.events(inRolloutLine: "not json at all"), [])
        XCTAssertEqual(CodexEventMapper.events(inRolloutLine: ""), [])
        // A record shape codex adds later must be ignored, not crashed on.
        XCTAssertEqual(
            CodexEventMapper.events(inRolloutLine: #"{"type":"event_msg","payload":{"type":"invented"}}"#),
            []
        )
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | rg -i "inRolloutLine|error:" | head -10`
Expected: compile failure — no `events(inRolloutLine:)` member.

- [ ] **Step 3: Implement the rollout mapping**

Add to `Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift`, inside `enum CodexEventMapper`:

```swift
    /// Translates one line of a codex rollout `.jsonl` into the app's vocabulary.
    ///
    /// This is the production path. Codex's app-server notifications are scoped to the
    /// connection that made the change, and turns run in a separate `codex resume` process,
    /// so nothing about what the user does ever reaches our connection. The rollout is
    /// written by whichever process drives the turn, which is exactly the property the
    /// notification route lacks.
    ///
    /// Only `event_msg` records carry turn boundaries. `response_item`, `turn_context`,
    /// `world_state` and `session_meta` are conversation content and bookkeeping.
    static func events(inRolloutLine line: String) -> [AgentEvent] {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let record = raw as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              let kind = payload["type"] as? String
        else { return [] }

        switch kind {
        case "task_started":
            return [.activity(.busy)]

        // `.turnEnded` is what `SessionReadPolicy` marks unread from, so it must accompany
        // idle. An aborted turn is still a turn that ended: the user interrupted it, and a
        // tab left spinning because nothing said "over" is the worse failure.
        case "task_complete", "turn_aborted":
            return [.activity(.idle), .turnEnded]

        default:
            return []
        }
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | rg -i "CodexRolloutMapper|failed" | head -10`
Expected: 4 tests pass, 0 failures overall.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift Tests/FlightDeckTests/CodexRolloutMapperTests.swift
git commit -m "feat: map codex rollout records to agent events

task_started opens a turn; task_complete and turn_aborted close one.
Asserted against captured codex output rather than payloads written here."
```

---

### Task 4: `CodexRolloutWatcher`

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexRolloutWatcher.swift`
- Test: `Tests/FlightDeckTests/CodexRolloutWatcherTests.swift`

**Interfaces:**
- Consumes: `TailReader.read` (Task 1), `CodexEventMapper.events(inRolloutLine:)` (Task 3).
- Produces: `@MainActor final class CodexRolloutWatcher` with `init(url: URL, clock: WatchClock? = nil, onEvent: @escaping (AgentEvent) -> Void)`, `start()`, `stop()`, `drain()`, and `let url: URL`. Task 6 owns one per attached codex tab.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/CodexRolloutWatcherTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class CodexRolloutWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
    private let completed = #"{"type":"event_msg","payload":{"type":"task_complete"}}"# + "\n"

    func testReportsTurnBoundariesAppendedAfterStart() throws {
        let url = dir.appendingPathComponent("rollout.jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())

        var seen: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: url) { seen.append($0) }
        watcher.drain() // prime while empty

        try (started + completed).data(using: .utf8)!.write(to: url)
        watcher.drain()

        XCTAssertEqual(seen, [.activity(.busy), .activity(.idle), .turnEnded])
    }

    /// The rollout exists, carrying an ~18 KB `session_meta` header, before any terminal
    /// does — `thread/start` creates it and returns its path. Tailing from the end is
    /// therefore correct: the header is not a turn. Do not "fix" this into reading from 0.
    func testSkipsTheHeaderThatExistedBeforeWatchingBegan() throws {
        let url = dir.appendingPathComponent("rollout.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"x"}}"# + "\n"
        try (header + started + completed).data(using: .utf8)!.write(to: url)

        var seen: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: url) { seen.append($0) }
        watcher.drain()

        XCTAssertEqual(seen, [], "everything already in the file predates this watcher")

        try (header + started + completed + started).data(using: .utf8)!.write(to: url)
        watcher.drain()
        XCTAssertEqual(seen, [.activity(.busy)], "only the appended turn is news")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | rg -i "CodexRolloutWatcher|error:" | head -10`
Expected: compile failure — `cannot find 'CodexRolloutWatcher' in scope`.

- [ ] **Step 3: Implement the watcher**

Create `Sources/FlightDeck/Agents/Codex/CodexRolloutWatcher.swift`:

```swift
import Foundation

/// Tails one codex thread's rollout `.jsonl` and reports turn boundaries.
///
/// Codex's own app-server cannot tell us this: its notifications go only to the connection
/// that made the change, and Flight Deck's turns run in a `codex resume` TUI — a different
/// process, therefore a different connection. The rollout is written by whoever drives the
/// turn, so it is the one source that does not care who that is.
///
/// **Threading.** Mirrors `TranscriptWatcher`: the read and parse run off the main actor,
/// and only the fold hops back. **Scheduling.** Owns no timer; `SessionStore`'s single
/// `WatchClock` drives every watcher, so N tabs cost one wakeup.
@MainActor
final class CodexRolloutWatcher {
    /// Readable so a runtime can say which rollout a tab is actually tailing; immutable, so
    /// a watcher is replaced rather than re-pointed when a tab's thread changes.
    let url: URL

    private let onEvent: (AgentEvent) -> Void
    private var offset: UInt64 = 0
    /// Whether the position to start reading from has been decided yet. See `TailReader`.
    private var hasChosenStart = false
    private weak var clock: WatchClock?
    private var isPolling = false

    init(url: URL, clock: WatchClock? = nil, onEvent: @escaping (AgentEvent) -> Void) {
        self.url = url
        self.clock = clock
        self.onEvent = onEvent
    }

    func start() {
        clock?.add(self) { [weak self] in self?.poll() }
    }

    func stop() {
        clock?.remove(self)
    }

    /// One scheduled pass. Re-entrancy is guarded rather than queued: a pass that outlives
    /// its tick means the next tick would read from a stale offset, so dropping it is both
    /// cheaper and more correct than letting two passes interleave.
    private func poll() {
        guard !isPolling else { return }
        isPolling = true

        let url = self.url
        let offset = self.offset
        let hasChosenStart = self.hasChosenStart

        Task { [weak self] in
            let read = await Task.detached(priority: .utility) {
                TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart)
            }.value

            guard let self else { return }
            self.apply(read)
            self.isPolling = false
        }
    }

    /// Synchronous pass, so tests need no expectations. Mirrors `TranscriptWatcher.drain()`.
    func drain() {
        apply(TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart))
    }

    private func apply(_ read: TailRead) {
        hasChosenStart = read.hasChosenStart
        offset = read.offset
        // Emitted in file order and not folded: unlike claude's sub-agent counting, nothing
        // here needs remembering — a turn boundary is complete in one record.
        for line in read.lines {
            for event in CodexEventMapper.events(inRolloutLine: line) { onEvent(event) }
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | rg -i "CodexRolloutWatcher|failed" | head -10`
Expected: 2 tests pass, 0 failures overall.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexRolloutWatcher.swift Tests/FlightDeckTests/CodexRolloutWatcherTests.swift
git commit -m "feat: tail a codex thread's rollout for turn boundaries

Starts at end of file: thread/start creates the rollout with an 18KB
session_meta header before any terminal exists, and the header is not
a turn."
```

---

### Task 5: `CodexNameWatcher`

Renames never appear in the rollout — not ours, not the TUI's. They appear in one app-wide append-only file, which is also the only place a `/rename` typed by the user is observable.

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexNameWatcher.swift`
- Test: `Tests/FlightDeckTests/CodexNameWatcherTests.swift`

**Interfaces:**
- Consumes: `TailReader.read` with `truncation: .resumeAtEnd` (Task 1).
- Produces: `@MainActor final class CodexNameWatcher` with `static var defaultIndexURL: URL`, `init(url: URL = CodexNameWatcher.defaultIndexURL, clock: WatchClock? = nil)`, `register(_ id: UUID, onTitle: @escaping (String) -> Void)`, `unregister(_ id: UUID)`, `var isEmpty: Bool`, `start()`, `stop()`, `drain()`. Task 6 owns exactly one.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/CodexNameWatcherTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class CodexNameWatcherTests: XCTestCase {
    private var dir: URL!
    private var index: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = dir.appendingPathComponent("session_index.jsonl")
        FileManager.default.createFile(atPath: index.path, contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func line(_ id: UUID, _ name: String) -> String {
        #"{"id":"\#(id.uuidString.lowercased())","thread_name":"\#(name)","updated_at":"2026-08-19T16:47:49.135395Z"}"# + "\n"
    }

    func testRoutesARenameToTheThreadThatOwnsIt() throws {
        let mine = UUID(), theirs = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(mine) { seen.append($0) }
        watcher.drain() // prime

        try (line(theirs, "not mine") + line(mine, "mine")).data(using: .utf8)!.write(to: index)
        watcher.drain()

        XCTAssertEqual(seen, ["mine"], "the index is app-wide and carries threads we never made")
    }

    func testTheLastRenameWins() throws {
        let id = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(id) { seen.append($0) }
        watcher.drain()

        try (line(id, "first") + line(id, "second")).data(using: .utf8)!.write(to: index)
        watcher.drain()

        XCTAssertEqual(seen, ["first", "second"])
    }

    func testUnregisteringStopsDelivery() throws {
        let id = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(id) { seen.append($0) }
        watcher.drain()
        watcher.unregister(id)
        XCTAssertTrue(watcher.isEmpty)

        try line(id, "after").data(using: .utf8)!.write(to: index)
        watcher.drain()
        XCTAssertEqual(seen, [])
    }

    /// The load-bearing difference from every other watcher in the app. This file is shared
    /// and append-only, so a compaction must NOT replay history: each replayed line would
    /// re-apply a title the thread has since moved past.
    func testACompactedIndexDoesNotReplayStaleTitles() throws {
        let id = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(id) { seen.append($0) }
        watcher.drain()

        try (line(id, "old") + line(id, "current")).data(using: .utf8)!.write(to: index)
        watcher.drain()
        XCTAssertEqual(seen, ["old", "current"])

        // Codex compacts the index down to one line per thread.
        try line(id, "current").data(using: .utf8)!.write(to: index)
        watcher.drain()
        XCTAssertEqual(seen, ["old", "current"], "compaction is not news")
    }

    func testGarbageLinesAreIgnored() throws {
        let id = UUID()
        var seen: [String] = []
        let watcher = CodexNameWatcher(url: index)
        watcher.register(id) { seen.append($0) }
        watcher.drain()

        let junk = "not json\n" + #"{"id":"not-a-uuid","thread_name":"x"}"# + "\n"
            + #"{"id":"\#(id.uuidString.lowercased())"}"# + "\n"
        try (junk + line(id, "good")).data(using: .utf8)!.write(to: index)
        watcher.drain()

        XCTAssertEqual(seen, ["good"])
    }

    /// Codex honours `CODEX_HOME`; a watcher that ignored it would tail a file codex is not
    /// writing and report nothing, forever, with no error.
    func testTheDefaultPathFollowsCodexHome() {
        let url = CodexNameWatcher.defaultIndexURL
        XCTAssertEqual(url.lastPathComponent, "session_index.jsonl")
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                           URL(fileURLWithPath: home).standardizedFileURL.path)
        } else {
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ".codex")
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | rg -i "CodexNameWatcher|error:" | head -10`
Expected: compile failure — `cannot find 'CodexNameWatcher' in scope`.

- [ ] **Step 3: Implement the watcher**

Create `Sources/FlightDeck/Agents/Codex/CodexNameWatcher.swift`:

```swift
import Foundation

/// Tails codex's `session_index.jsonl` and reports thread renames.
///
/// One instance for the whole app, not one per tab, for the same reason `SessionStatusWatcher`
/// is shared: a single file carries every thread, so a per-tab watcher would read the same
/// bytes N times.
///
/// This file is the ONLY place a codex rename is observable. The rollout carries none — not
/// from `thread/name/set`, not from a `/rename` typed into the TUI — and the app-server tells
/// only the connection that made the change. Verified against codex-cli 0.148.0: three
/// renames from two different writers produced three lines here and nothing anywhere else.
@MainActor
final class CodexNameWatcher {
    /// Codex's index, honouring `CODEX_HOME` exactly as codex does. Getting this wrong fails
    /// silently — a watcher on the wrong path simply never reports anything.
    static var defaultIndexURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        return home.appendingPathComponent("session_index.jsonl")
    }

    let url: URL

    private var listeners: [UUID: (String) -> Void] = [:]
    private var offset: UInt64 = 0
    private var hasChosenStart = false
    private weak var clock: WatchClock?
    private var isPolling = false

    init(url: URL = CodexNameWatcher.defaultIndexURL, clock: WatchClock? = nil) {
        self.url = url
        self.clock = clock
    }

    func register(_ id: UUID, onTitle: @escaping (String) -> Void) {
        listeners[id] = onTitle
    }

    func unregister(_ id: UUID) {
        listeners[id] = nil
    }

    /// Lets the owner drop this watcher with the last codex tab rather than leave it ticking
    /// over a file nothing is listening to.
    var isEmpty: Bool { listeners.isEmpty }

    func start() {
        clock?.add(self) { [weak self] in self?.poll() }
    }

    func stop() {
        clock?.remove(self)
    }

    private func poll() {
        guard !isPolling else { return }
        isPolling = true

        let url = self.url
        let offset = self.offset
        let hasChosenStart = self.hasChosenStart

        Task { [weak self] in
            let read = await Task.detached(priority: .utility) {
                TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart,
                                truncation: .resumeAtEnd)
            }.value

            guard let self else { return }
            self.apply(read)
            self.isPolling = false
        }
    }

    /// Synchronous pass, so tests need no expectations.
    func drain() {
        apply(TailReader.read(url: url, offset: offset, hasChosenStart: hasChosenStart,
                              truncation: .resumeAtEnd))
    }

    private func apply(_ read: TailRead) {
        hasChosenStart = read.hasChosenStart
        offset = read.offset

        for line in read.lines {
            guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let record = raw as? [String: Any],
                  let id = (record["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let name = record["thread_name"] as? String,
                  let listener = listeners[id]
            else { continue }
            listener(name)
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | rg -i "CodexNameWatcher|failed" | head -10`
Expected: 6 tests pass, 0 failures overall.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexNameWatcher.swift Tests/FlightDeckTests/CodexNameWatcherTests.swift
git commit -m "feat: tail codex's session index for thread renames

The only place a codex rename is observable: the rollout carries none,
and the app-server tells only the connection that made the change. One
watcher for the app, and a compaction must never replay stale titles."
```

---

### Task 6: Rewire `CodexRuntime` and delete the notification path

The replacement is now in place, so the old path and the machinery guarding its ordering hazard both go. This task is atomic — the deletions cannot land before the rewire, and leaving them for later would mean two live sources for the same fact.

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexRuntime.swift` (rewrite)
- Modify: `Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift` (delete the notification half)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`CodexStack`, `makeCodexStackIfNeeded`, new `codexIndexURL` seam)
- Modify: `Tests/FlightDeckTests/CodexResumeTests.swift` (delete 6 tests + 2 helpers)
- Modify: `Tests/FlightDeckTests/CodexSchemaConformanceTests.swift` (delete 4 tests)
- Delete: `Tests/FlightDeckTests/CodexEventMapperTests.swift`
- Modify: `Tests/FlightDeckTests/CodexStatusRoutingTests.swift` (one doc comment)
- Test: `Tests/FlightDeckTests/CodexRuntimeAttachmentTests.swift`

**Interfaces:**
- Consumes: `CodexRolloutWatcher` (Task 4), `CodexNameWatcher` (Task 5).
- Produces: `CodexRuntime.init(clock: WatchClock? = nil, indexURL: URL = CodexNameWatcher.defaultIndexURL)`, `drainForTesting()`; `SessionStore.codexIndexURL: URL`. Task 7 uses both.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/CodexRuntimeAttachmentTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class CodexRuntimeAttachmentTests: XCTestCase {
    private var dir: URL!
    private var index: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        index = dir.appendingPathComponent("session_index.jsonl")
        FileManager.default.createFile(atPath: index.path, contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func rollout(named name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func indexLine(_ id: UUID, _ name: String) -> String {
        #"{"id":"\#(id.uuidString.lowercased())","thread_name":"\#(name)"}"# + "\n"
    }

    private let turn = #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"

    func testTurnsAndRenamesBothReachTheAttachedTab() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        let runtime = CodexRuntime(indexURL: index)

        var seen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: url)) { seen.append($0) }
        runtime.drainForTesting() // prime both watchers

        try append(turn, to: url)
        try append(indexLine(id, "renamed"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [.activity(.busy), .title("renamed")])
    }

    func testEachTabOnlySeesItsOwnThread() throws {
        let mine = UUID(), theirs = UUID()
        let mineURL = try rollout(named: "mine.jsonl")
        let theirsURL = try rollout(named: "theirs.jsonl")
        let runtime = CodexRuntime(indexURL: index)

        var mineSeen: [AgentEvent] = [], theirsSeen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: mine, transcriptURL: mineURL)) { mineSeen.append($0) }
        runtime.attach(AgentBinding(conversationID: theirs, transcriptURL: theirsURL)) { theirsSeen.append($0) }
        runtime.drainForTesting()

        try append(turn, to: mineURL)
        try append(indexLine(theirs, "theirs renamed"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(mineSeen, [.activity(.busy)])
        XCTAssertEqual(theirsSeen, [.title("theirs renamed")])
    }

    func testDetachingStopsEverythingForThatTab() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        let runtime = CodexRuntime(indexURL: index)

        var seen: [AgentEvent] = []
        let binding = AgentBinding(conversationID: id, transcriptURL: url)
        runtime.attach(binding) { seen.append($0) }
        runtime.drainForTesting()
        runtime.detach(binding)

        try append(turn, to: url)
        try append(indexLine(id, "after detach"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [], "a closed tab must not be written to")
    }

    /// A restored tab whose thread was renamed while the app was closed is NOT this watcher's
    /// job — `rebind`'s `thread/read` settles that. Tailing from the end is what keeps a
    /// reopened app from replaying every rename in the user's history across every tab.
    func testAttachingDoesNotReplayRenamesThatPredateIt() throws {
        let id = UUID()
        let url = try rollout(named: "a.jsonl")
        try append(indexLine(id, "renamed while we were closed"), to: index)

        var seen: [AgentEvent] = []
        let runtime = CodexRuntime(indexURL: index)
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: url)) { seen.append($0) }
        runtime.drainForTesting()

        XCTAssertEqual(seen, [])
    }

    func testATabWithNoTranscriptStillGetsRenames() throws {
        let id = UUID()
        let runtime = CodexRuntime(indexURL: index)

        var seen: [AgentEvent] = []
        runtime.attach(AgentBinding(conversationID: id, transcriptURL: nil)) { seen.append($0) }
        runtime.drainForTesting()

        try append(indexLine(id, "still named"), to: index)
        runtime.drainForTesting()

        XCTAssertEqual(seen, [.title("still named")])
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | rg -i "CodexRuntimeAttachment|error:" | head -10`
Expected: compile failure — `CodexRuntime` has no `init(indexURL:)` and no `drainForTesting()`.

- [ ] **Step 3: Rewrite `CodexRuntime`**

Replace the entire contents of `Sources/FlightDeck/Agents/Codex/CodexRuntime.swift` with:

```swift
import Foundation

/// Codex's observation half: everything is read from the files codex writes.
///
/// It does not use the app-server at all, and that is the whole point. Codex's notifications
/// are scoped to the connection that made the change, and Flight Deck runs turns in a
/// `codex resume` TUI — a different process, so a different connection. The app-server that
/// created a thread is never told what the user does in it. Files have no such rule.
///
/// The shape mirrors `ClaudeRuntime`: one watcher per tab over a per-conversation file, plus
/// one shared watcher over an app-wide file, fanned out by conversation id.
@MainActor
final class CodexRuntime: AgentRuntime {
    private struct Attachment {
        let onEvent: (AgentEvent) -> Void
        let watcher: CodexRolloutWatcher?
    }

    private var attachments: [UUID: Attachment] = [:]
    private let clock: WatchClock?
    private let indexURL: URL

    /// Built on first attach and dropped with the last one, so a user with no codex tabs
    /// never has a watcher ticking over codex's index.
    private var names: CodexNameWatcher?

    init(clock: WatchClock? = nil, indexURL: URL = CodexNameWatcher.defaultIndexURL) {
        self.clock = clock
        self.indexURL = indexURL
    }

    func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {
        let id = binding.conversationID

        var watcher: CodexRolloutWatcher?
        if let url = binding.transcriptURL {
            watcher = CodexRolloutWatcher(url: url, clock: clock, onEvent: onEvent)
            watcher?.start()
        }
        // Stopped explicitly rather than left to the replaced `Attachment` being released: it
        // survives its owner by its registration on the shared `WatchClock`, and although that
        // registration is weak and self-prunes, an invariant that holds only because of a
        // retention detail two files away is not one to lean on.
        attachments[id]?.watcher?.stop()
        attachments[id] = Attachment(onEvent: onEvent, watcher: watcher)

        // Registered even when there is no rollout to tail: a tab still has a name.
        nameWatcher().register(id) { onEvent(.title($0)) }
    }

    func detach(_ binding: AgentBinding) {
        let id = binding.conversationID
        attachments[id]?.watcher?.stop()
        attachments[id] = nil

        names?.unregister(id)
        if names?.isEmpty == true {
            names?.stop()
            names = nil
        }
    }

    private func nameWatcher() -> CodexNameWatcher {
        if let names { return names }
        let watcher = CodexNameWatcher(url: indexURL, clock: clock)
        watcher.start()
        names = watcher
        return watcher
    }

    /// Test seam mirroring `ClaudeRuntime.drainForTesting()`, so runtime tests need no clock.
    func drainForTesting() {
        for attachment in attachments.values { attachment.watcher?.drain() }
        names?.drain()
    }
}
```

- [ ] **Step 4: Delete the notification half of the mapper**

In `Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift`, delete `struct CodexThreadState`, `static let liveStates`, and `static func events(method:params:state:)` with their doc comments. What remains is the enum declaration, a doc comment, and `events(inRolloutLine:)`. Replace the type's doc comment with:

```swift
/// Translates codex's rollout records into the app's own vocabulary.
///
/// Pure and static so every mapping is testable from a captured line with no process, no
/// socket and no timing — the same reason `ClaudeSession.events(inLine:sessionID:)` is pure.
///
/// This used to translate app-server notifications instead. That path was removed, not
/// deprecated: those notifications only ever reach the connection that made the change, so
/// none of them described anything a user did in a `codex resume` TUI.
```

- [ ] **Step 5: Rewire `CodexStack` and add the store's index seam**

In `Sources/FlightDeck/SessionStore.swift`:

1. In `CodexStack`, change the initializer to take the clock and index URL, and delete the reconcile wiring:

```swift
        init(clock: WatchClock?, indexURL: URL) {
            transport = CodexProcessTransport()
            rpc = CodexRPC(transport: transport)
            adapter = CodexAdapter(rpc: rpc)
            runtime = CodexRuntime(clock: clock, indexURL: indexURL)
            // The hook `CodexProcessTransport` exposes exists for exactly this. Without it a
            // mid-session app-server crash leaves every in-flight request suspended forever —
            // a tab waiting on a dead process is indistinguishable from a hung agent, which is
            // the failure mode `CodexRPC` documents as the worst it can have. Weak so the
            // transport's callback does not retain the client that already owns it.
            transport.onTerminate = { [weak rpc] in rpc?.transportClosed() }
        }
```

2. Beside `var sessionsRoot: URL = SessionStatusWatcher.defaultRoot`, add:

```swift
    /// Codex's rename index. A seam for the same reason `sessionsRoot` is one: the default is
    /// a real file in the user's home, and a test that read it would be reading live state.
    var codexIndexURL: URL = CodexNameWatcher.defaultIndexURL
```

3. In `makeCodexStackIfNeeded`, change `let stack = CodexStack()` to:

```swift
        let stack = CodexStack(clock: clock, indexURL: codexIndexURL)
```

- [ ] **Step 6: Delete the tests that only covered the deleted path**

```bash
git rm Tests/FlightDeckTests/CodexEventMapperTests.swift
```

In `Tests/FlightDeckTests/CodexResumeTests.swift`, delete the `// MARK: - The reconcile ordering guard` section entirely: the `makeRuntime()` helper, the nested `ReadGate` class, and these six tests —
`testTheProductionWireReadsTheThreadAndAppliesWhatItSays`,
`testAScheduledReconcileCannotOverwriteANotificationThatBeatItHome`,
`testAFirstContactBurstDoesNotDropTheReconcileItScheduled`,
`testANotificationThatChangesNothingDoesNotInvalidateAReadInFlight`,
`testAnOvertakenReconcileIsRetriedRatherThanAbandoned`,
`testAReconcileForAReattachedThreadIsDropped`.
Everything above that MARK (the `read` and `rebind` tests) stays — `CodexAdapter.read` is still live.

In `Tests/FlightDeckTests/CodexSchemaConformanceTests.swift`, delete these four tests, which assert against a protocol this app no longer listens to —
`testEveryNotificationTheMapperHandlesExists`,
`testTurnAbortedIsNotAThingAndTheMapperNoLongerPretendsItIs`,
`testCollabAgentStateIsAnObjectWithAStatus`,
`testEveryLiveStateIsARealCollabAgentStatus`.
Keep `testEveryThreadStatusVariantIsAccountedFor` and `testEveryThreadActiveFlagMeansWaiting`: `CodexThreadStatus` is still on the `thread/read` path.

Add this note at the top of `CodexSchemaConformanceTests`, under its existing doc comment:

```swift
// Four cases were deleted when codex observation moved to the rollout file: they asserted
// that the notification vocabulary the mapper handled was real, and the mapper no longer
// handles notifications. Nothing generated can assert their replacement — the rollout and
// session-index formats have no schema — so that coverage now lives in captured fixtures
// (`rollout.captured.jsonl`) and in `CodexIntegrationTests`. That is weaker, deliberately
// and knowingly: see the spec's §6.
```

In `Tests/FlightDeckTests/CodexStatusRoutingTests.swift`, `testWaitingNotifiesThroughTheSamePolicy` still passes — it drives a `FakeAgentRuntime` and is really about `SessionStore`'s policy — but its premise moved. Add to its doc comment:

```swift
    /// Note: no codex source produces `.waiting` any more. Codex writes nothing when it
    /// starts waiting on approval, so a codex tab reads busy through a prompt. This test
    /// covers the store's policy for the event, which claude still produces.
```

- [ ] **Step 7: Run the full suite**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: 0 failures. The count drops by roughly 19 (6 reconcile + 9 mapper + 4 conformance) and rises by the 5 new attachment tests.

If `CodexResumeTests` fails to compile, a helper deleted in Step 6 is still referenced — `ReadGate` and `makeRuntime()` are used only by the six deleted tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexRuntime.swift Sources/FlightDeck/Agents/Codex/CodexEventMapper.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/CodexResumeTests.swift Tests/FlightDeckTests/CodexSchemaConformanceTests.swift Tests/FlightDeckTests/CodexStatusRoutingTests.swift Tests/FlightDeckTests/CodexRuntimeAttachmentTests.swift
git commit -m "feat: observe codex from its files, and delete the path that never fired

CodexRuntime now owns a rollout watcher per tab and one shared name
watcher, so a turn run in a codex resume TUI finally moves the tab it
belongs to.

The reconcile apparatus goes with the notifications it was guarding:
it ordered an async read against a synchronous notification stream,
and neither side exists now. So do four schema-conformance tests --
they asserted a protocol this app no longer listens to, and nothing
generated can assert what replaced it."
```

---

### Task 7: Prove it against real codex

The captured fixtures record what codex did on one day. This is the only test that notices when that stops being true.

**Files:**
- Modify: `Tests/FlightDeckTests/CodexIntegrationTests.swift`
- Modify: `Sources/FlightDeck/Agents/Codex/CodexProcessTransport.swift` (add an `environment` parameter)

**Interfaces:**
- Consumes: `CodexRuntime.drainForTesting()` and `SessionStore.codexIndexURL` (Task 6), `CodexRolloutWatcher` (Task 4).
- Produces: `CodexProcessTransport.init(executable:environment:)` — an environment seam added in Step 3. Nothing later depends on it.

- [ ] **Step 1: Repair the heal test, which delivered its news by notification**

`testARestoredCodexTabReattachesAfterAStartCodexFailure` proves the re-attachment by calling `runtime.handle(method: "thread/name/updated", ...)`. That method is gone. Replace the delivery — and only the delivery — so the test still proves exactly what it did before.

Where the store is built (around line 222), add a temp index the test controls:

```swift
        let index = tmp.appendingPathComponent("session_index.jsonl")
        FileManager.default.createFile(atPath: index.path, contents: Data())
        store.codexIndexURL = index
```

Replace the `currentRuntime.handle(...)` call and the `XCTUnwrap` above it with:

```swift
        let currentRuntime = try XCTUnwrap(store.runtime(for: .codex) as? CodexRuntime,
            "codex's runtime is always a CodexRuntime; draining its watchers below is how a "
            + "real rename reaches it, which is not part of the shared AgentRuntime protocol")
        // Prime, then append: the name watcher starts at end of file, so a line already
        // present when it attached is history rather than news.
        currentRuntime.drainForTesting()
        let line = #"{"id":"\#(existing.uuidString.lowercased())","thread_name":"post-heal-rename"}"# + "\n"
        let handle = try FileHandle(forWritingTo: index)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
        currentRuntime.drainForTesting()
```

Leave the assertion below it untouched — the tab must still end up titled `post-heal-rename`, and it is still true only if the heal re-attached the tab to the current runtime.

- [ ] **Step 2: Run the integration suite to confirm the repair**

Run: `FLIGHT_DECK_CODEX_INTEGRATION=1 ./scripts/test-unit.sh 2>&1 | rg -i "Reattaches|failed" | head`
Expected: `testARestoredCodexTabReattachesAfterAStartCodexFailure` passes. It needs a real codex on `PATH`; it does not need this task's new test yet.

- [ ] **Step 3: Give the transport an environment seam**

The test below must run a real `codex app-server` against an isolated `CODEX_HOME`, or the
threads it creates land in the user's own history. `CodexProcessTransport` has no way to say
so today. In `Sources/FlightDeck/Agents/Codex/CodexProcessTransport.swift`, replace the
stored `executable` and its initializer with:

```swift
    private let executable: String
    /// Extra environment for the spawned app-server, merged over the process's own.
    ///
    /// Empty in production. A committed test uses it to point a real `codex app-server` at an
    /// isolated `CODEX_HOME`, which is what lets that test create and resume threads without
    /// writing anything into the user's real `~/.codex`.
    private let environment: [String: String]

    init(executable: String = "codex", environment: [String: String] = [:]) {
        self.executable = executable
        self.environment = environment
    }
```

and in `start()`, immediately after `process.standardError = FileHandle.nullDevice`:

```swift
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, override in override }
        }
```

- [ ] **Step 4: Add the vocabulary test**

Append to `CodexIntegrationTests`, after the existing tests:

```swift
    // MARK: - 4. The rollout vocabulary

    /// The one test that can catch codex renaming the records this app reads.
    ///
    /// It pins two things at once, and both are load-bearing:
    ///
    /// 1. **A separate process appends to the rollout `thread/start` named.** This is the
    ///    fact the entire observation design rests on — our app-server does not run the turn,
    ///    and it does not have to.
    /// 2. **`task_started` and `task_complete` are still what a turn looks like.**
    ///    `rollout.captured.jsonl` records what codex wrote on one day, and no schema exists
    ///    for that format, so nothing else in the suite would notice a rename. The failure
    ///    mode without this test is silent: codex tabs simply stop moving.
    ///
    /// Everything happens under an isolated `CODEX_HOME` in a temp directory, so no thread
    /// cleanup is needed — the whole home is deleted — and the user's real codex history is
    /// neither read nor written.
    func testARealResumedTurnAppendsTheTurnRecordsToTheRolloutThreadStartNamed() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cwd = home.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        // Trusted in THIS home only. Without it `codex exec` refuses the directory, and the
        // TUI would raise a modal — neither of which a committed test may provoke.
        try """
        [projects."\(cwd.path)"]
        trust_level = "trusted"
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let auth = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: auth.path),
                          "needs a logged-in codex: ~/.codex/auth.json")
        try FileManager.default.copyItem(at: auth, to: home.appendingPathComponent("auth.json"))

        let transport = CodexProcessTransport(environment: ["CODEX_HOME": home.path])
        try transport.start()
        defer { transport.stop() }
        let rpc = CodexRPC(transport: transport)
        try await CodexProcessTransport.verifyHandshake(rpc)

        let started = try await rpc.request("thread/start", ["cwd": cwd.path])
        let thread = try XCTUnwrap(started["thread"] as? [String: Any])
        let id = try XCTUnwrap(thread["id"] as? String)
        let rollout = URL(fileURLWithPath: try XCTUnwrap(thread["path"] as? String))
        // Naming commits the thread. An unnamed one cannot be resumed at all — see
        // `testThreadStartAloneDoesNotPersistButNamingCommits` above.
        _ = try await rpc.request("thread/name/set", ["threadId": id, "name": "rollout vocabulary"])

        var seen: [AgentEvent] = []
        let watcher = CodexRolloutWatcher(url: rollout) { seen.append($0) }
        watcher.drain() // prime past the session_meta header

        let codex = Process()
        codex.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        codex.arguments = ["codex", "exec", "resume", "--skip-git-repo-check", id,
                           "Reply with exactly the word: ok"]
        codex.currentDirectoryURL = cwd
        codex.environment = ProcessInfo.processInfo.environment
            .merging(["CODEX_HOME": home.path]) { _, override in override }
        codex.standardOutput = FileHandle.nullDevice
        codex.standardError = FileHandle.nullDevice
        try codex.run()
        codex.waitUntilExit()
        XCTAssertEqual(codex.terminationStatus, 0, "codex exec resume failed")

        watcher.drain()
        XCTAssertEqual(seen, [.activity(.busy), .activity(.idle), .turnEnded],
                       "a turn run by a process our app-server does not own must still append "
                       + "task_started then task_complete to the rollout it named; if this "
                       + "fails, every codex tab has silently stopped moving")
    }
```

- [ ] **Step 5: Run the integration suite**

Run: `FLIGHT_DECK_CODEX_INTEGRATION=1 ./scripts/test-unit.sh 2>&1 | rg -i "AppendsTheTurnRecords|failed|error:" | head -20`
Expected: passes in roughly 15s (a real model turn is most of it).

- [ ] **Step 6: Confirm the hermetic suite is untouched**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: 0 failures, and the new test **skipped** (no `FLIGHT_DECK_CODEX_INTEGRATION`).

- [ ] **Step 7: Commit**

```bash
git add Tests/FlightDeckTests/CodexIntegrationTests.swift Sources/FlightDeck/Agents/Codex/CodexProcessTransport.swift
git commit -m "test: pin the rollout vocabulary against a real codex turn

Captured fixtures record what codex wrote on one day, and no schema
exists for that format. This is the only test that notices when
task_started or task_complete is renamed, or when a resumed turn stops
appending to the rollout thread/start named -- without it both failures
are silent, and codex tabs just stop moving.

The transport gains an environment seam so the test can run a real
app-server against an isolated CODEX_HOME instead of the user's own."
```

---

## Verification

After Task 7, confirm the whole thing end to end:

- [ ] `./scripts/test-unit.sh` — 0 failures, 6 skipped (the 5 that were already opt-in, plus Task 7's).
- [ ] `FLIGHT_DECK_CODEX_INTEGRATION=1 ./scripts/test-unit.sh` — 0 failures, 1 skipped.
- [ ] Manually, once: open a codex tab in the app, type a prompt, and watch the sidebar go busy then idle; rename with `/rename` inside the tab and watch the sidebar title follow. This is the only check that covers the wiring from `SessionStore` to the UI, and it is why `scripts/smoke.sh` is not a substitute.
