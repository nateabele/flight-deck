# Multi-agent ⌘K Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ⌘K search every agent's conversation history, not just Claude's, by moving
transcript discovery, line parsing and conversation naming behind one capability object on
`AgentAdapter` — with codex as the first conformer.

**Architecture:** A new `AgentSearchCorpus` protocol answers three questions per agent
(*which transcripts, this line as messages, what is it called*). `SearchIndexBuilder` stops
calling Claude parsers directly and calls the corpus instead. Discovery becomes per-account
and returns `TranscriptRef` values — transcripts, not directories — because codex has no
per-project transcript directory. The index schema gains agent/provenance/working-directory
on its `source` table, which is what lets a result say which adapter should resume it and
which working directory to resume it in.

**Tech Stack:** Swift 5 (`SWIFT_VERSION: "5.0"` is deliberate), SwiftUI/AppKit, SQLite FTS5,
XCTest. `FleetKit` is Swift 6 and limited to `Foundation`/`Network`/`Security` because it
compiles for iOS too.

**Spec:** `docs/superpowers/specs/2026-09-21-multi-agent-search-design.md`

## Global Constraints

- **Two test targets.** `./scripts/test-unit.sh` is macOS-only. Any task touching
  `Sources/FleetKit` or `Sources/FlightDeckMobile` ALSO needs `./scripts/build-ios.sh` and
  `./scripts/test-ios.sh`. Tasks 2, 8 and 11 touch FleetKit.
- **`test-unit.sh` ignores `-only-testing:`** — it silently runs the whole suite every time.
  Budget ~8 minutes per run and do not investigate why your filter was ignored.
- **Never loop `./scripts/smoke.sh`.** It seizes the foreground for ~70 s and captures the
  user's keystrokes as phantom failures. No task in this plan needs it.
- **Run tests in the foreground.** A backgrounded run dies with the subagent's turn.
- **`FleetKit` may import only `Foundation`, `Network`, `Security`.** It compiles for iOS.
  `AgentID` lives in `Sources/FlightDeck/Agents/AgentKind.swift`, which is **not** in
  FleetKit — see Task 2 for how the wire type carries the agent without importing it.
- **Comments explain *why* and name the failure they prevent.** This is the house style; a
  comment restating the code is a review rejection.
- **TDD, and confirm the test fails against the broken code first.** Never weaken an
  assertion to go green.
- **Shared checkout.** Other sessions edit this tree. Never `git stash`, `git checkout .`,
  or revert blind. `git add` only the exact paths your task names.
- **Commit trailer:** `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- **Build prerequisite:** `vendor/boringssl-artifacts/BoringSSL.xcframework` must exist or
  every target fails. If it is missing, run `./scripts/build-boringssl.sh`, then
  `rm -rf DerivedData/Build/Intermediates.noindex/XCBuildData` before rebuilding.

---

### Task 1: The corpus protocol and its types

Types only. Nothing consumes them yet, so the suite must stay green unchanged — this task's
deliverable is that the project still compiles with the new vocabulary in it.

**Files:**
- Create: `Sources/FlightDeck/Agents/AgentSearchCorpus.swift`
- Modify: `Sources/FlightDeck/Agents/AgentAdapter.swift` (add the protocol member near the
  other capability objects, ~line 232, beside `openPromptReader`)
- Modify: `Sources/FlightDeck/Agents/AgentAdapter.swift` (`extension AgentID`, ~line 459,
  after `openPromptReader`'s switch)
- Modify: `Sources/FlightDeck/Agents/ClaudeAdapter.swift` (stub `static let searchCorpus`)
- Modify: `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift` (stub `static let searchCorpus`)
- Test: `Tests/FlightDeckTests/AgentSearchCorpusTests.swift`

**Interfaces:**
- Consumes: `AgentID`, `AgentAccount`, `IndexedMessage` (all existing).
- Produces: `TranscriptRef`, `ConversationNaming`, `AgentSearchCorpus`,
  `AgentAdapter.searchCorpus`, `AgentID.searchCorpus`. Tasks 4, 5 and 6 conform to this
  protocol; Task 7 calls `AgentID.searchCorpus`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/AgentSearchCorpusTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// The capability is reached through `AgentID`, never off an adapter instance — the backfill
/// runs from `AppDelegate.startSearch`, which has no adapters and no live account stacks.
@MainActor
final class AgentSearchCorpusTests: XCTestCase {
    /// Every agent must answer. A `nil` here is a legitimate answer ("not searchable"), but
    /// it must be a *decision* — this asserts the switch is exhaustive by exercising every
    /// case, which is what fails to compile when a third `AgentID` is added without one.
    func testEveryAgentAnswersTheCapability() {
        for agent in AgentID.allCases {
            _ = agent.searchCorpus
        }
    }

    /// Placeholder ids are a value type, so this pins the shape the rest of the plan builds on.
    func testTranscriptRefCarriesAttributionAndProvenance() {
        let ref = TranscriptRef(
            url: URL(fileURLWithPath: "/tmp/rollout.jsonl"),
            projectPath: "/w/fd",
            accountHome: URL(fileURLWithPath: "/home/.codex"),
            workingDirectory: "/w/fd/.claude/worktrees/x",
            conversationID: "abc",
            agent: .codex,
            provenance: "exec",
            indexedName: "session 206",
            modified: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(ref.provenance, "exec")
        XCTAssertEqual(ref.workingDirectory, "/w/fd/.claude/worktrees/x")
        XCTAssertNotEqual(ref.workingDirectory, ref.projectPath)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — compile error, `cannot find 'TranscriptRef' in scope` and
`value of type 'AgentID' has no member 'searchCorpus'`.

- [ ] **Step 3: Create the types**

Create `Sources/FlightDeck/Agents/AgentSearchCorpus.swift`:

```swift
import Foundation

/// **One transcript this agent has written, and everything the index needs to file it.**
///
/// Replaces `SearchCorpus.Entry`, which was `(projectPath, directory)` — a *directory per
/// project*, which is claude's `~/.claude/projects/<encoded-cwd>` layout baked into a type.
/// Codex has no such directory: its rollouts live in a date tree and record their cwd inside
/// the file. So an adapter hands back transcripts, not folders.
struct TranscriptRef: Equatable, Sendable {
    /// codex: the rollout. claude: `<conversation-uuid>.jsonl`.
    let url: URL

    /// The sidebar project this is attributed to.
    let projectPath: String

    /// The account home this transcript was found under — `CODEX_HOME` or
    /// `CLAUDE_CONFIG_DIR`. Carried per-transcript rather than left to the caller because a
    /// corpus is reached statically through `AgentID.searchCorpus` and holds no account of
    /// its own to consult.
    let accountHome: URL

    /// **The literal directory the conversation ran in** — the project itself, or one of its
    /// worktrees.
    ///
    /// Captured at walk time because that is the only moment it is known without guessing:
    /// claude's directory encoding is one-way (see `SearchCorpus`'s doc comment) and codex
    /// records its cwd only inside the file. Carrying it is what lets a search result resume
    /// into the worktree it actually ran in, instead of `SessionStore` re-deriving it by
    /// probing candidate directories for a matching filename.
    let workingDirectory: String

    let conversationID: String
    let agent: AgentID

    /// codex: `session_meta.payload.source` — "exec", "cli", "vscode". nil for claude.
    /// Drives the `.automated` ranking tier and nothing else.
    let provenance: String?

    /// The name this agent records for the conversation OUT OF BAND, if any — codex's
    /// `session_index.jsonl` entry. nil for claude, whose names are in the transcript itself.
    ///
    /// Resolved during the walk rather than on demand: the walk already visits each account
    /// once, so one read of that account's index serves every rollout under it. Resolving it
    /// per-conversation would mean re-reading that file once per rollout — 563 times on the
    /// machine this was measured on — or caching inside a `Sendable` type that is called off
    /// the main actor.
    let indexedName: String?

    let modified: Date
}

/// What a naming pass concluded, and how much authority it carries.
///
/// A verdict rather than a `String?` because the builder's overwrite rule needs to know
/// *why* it got a name. A later pass sees only newly appended lines, so a derived name must
/// never overwrite a real one an earlier pass already stored — the rule
/// `SearchIndexBuilder.containsRename` implements today for claude, generalised so each agent
/// states its own.
enum ConversationNaming: Equatable {
    /// A real rename. Overwrite whatever is stored.
    case authoritative(String)
    /// Derived — a first user message, or a placeholder. Write only when nothing is stored.
    case fallback(String)
    /// Nothing in this pass. Leave what is stored alone.
    case unknown
}

/// **Everything the ⌘K index needs from one agent, and nothing about how it stores it.**
///
/// Three jobs: find this agent's transcripts, turn one of its lines into indexable messages,
/// and say what a conversation is called.
///
/// **`Sendable` and non-isolated, unlike the other capability objects.** `textChannel`,
/// `dialogDriver` and `openPromptReader` are `@MainActor` because they drive a screen. This
/// one is called from inside the `SearchIndexBuilder` actor and a `Task.detached` within it
/// — the backfill runs off the main actor precisely so parsing hundreds of megabytes cannot
/// stall the agents running in the same process. Every member is therefore a pure function
/// of its arguments, with no cache and no lock.
protocol AgentSearchCorpus: Sendable {
    /// Every transcript this agent has written that belongs to one of `projects`, across
    /// every one of `accounts`.
    ///
    /// Accounts rather than one root: a transcript's home is per-account for both agents
    /// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Passing a single root is exactly the bug that
    /// makes ⌘K blind to a second claude login today.
    func transcripts(
        forProjects projects: [String], accounts: [AgentAccount]
    ) -> [TranscriptRef]

    /// One line of this agent's transcript, as indexable messages. Pure — the same shape as
    /// `AgentAdapter.timelineItems(inLine:at:)`, and tested the same way, from fixtures.
    func indexedMessages(
        inLine line: String, conversationID: String, at offset: Int
    ) -> [IndexedMessage]

    /// What this conversation is called, judged from the lines read in THIS pass plus
    /// whatever out-of-band name the walk already put on `ref`.
    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming
}
```

- [ ] **Step 4: Add the protocol member and the AgentID switch**

In `Sources/FlightDeck/Agents/AgentAdapter.swift`, inside `protocol AgentAdapter`, directly
after the `openPromptReader` declaration:

```swift
    /// **How this agent's history becomes searchable — or `nil`, the refusal.**
    ///
    /// The fourth capability object, and the only one that is not `@MainActor` — see
    /// `AgentSearchCorpus`'s own doc comment for why. `nil` means this agent contributes
    /// nothing to ⌘K, which is an answer the overlay can state rather than a gap that reads
    /// as "you have no conversations here".
    ///
    /// Deliberately has NO default implementation. The defaults in this file exist for
    /// members with a genuine majority answer (`rebind`, `environment`); this has none, and a
    /// silent default is how a third agent would ship looking searchable and finding nothing.
    static var searchCorpus: AgentSearchCorpus? { get }
```

In the same file, inside `extension AgentID`, after the `openPromptReader` switch:

```swift
    /// See `AgentAdapter.searchCorpus`. Consulted by `AppDelegate.startSearch`'s backfill and
    /// by `SessionStore.openConversation`, neither of which holds an adapter — which is the
    /// whole reason the capability hangs off the agent rather than off an instance.
    ///
    /// `nonisolated` unlike its siblings here: the backfill calls it from an actor, and the
    /// object it returns is `Sendable`.
    nonisolated var searchCorpus: AgentSearchCorpus? {
        switch self {
        case .claude: ClaudeAdapter.searchCorpus
        case .codex: CodexAdapter.searchCorpus
        }
    }
```

In `ClaudeAdapter.swift`, beside its other `static let` capabilities:

```swift
    // Filled in by Task 4. Stubbed rather than omitted so this file compiles against the new
    // protocol requirement while the conformer is still being written.
    static let searchCorpus: AgentSearchCorpus? = nil
```

In `CodexAdapter.swift`, beside its other `static let` capabilities:

```swift
    // Filled in by Task 6.
    static let searchCorpus: AgentSearchCorpus? = nil
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS — the two new tests, and every pre-existing test unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentSearchCorpus.swift \
        Sources/FlightDeck/Agents/AgentAdapter.swift \
        Sources/FlightDeck/Agents/ClaudeAdapter.swift \
        Sources/FlightDeck/Agents/Codex/CodexAdapter.swift \
        Tests/FlightDeckTests/AgentSearchCorpusTests.swift
git commit -m "$(cat <<'EOF'
feat: add the AgentSearchCorpus capability

⌘K's corpus, extraction and naming are claude parsers called directly from
SearchIndexBuilder, so no other agent can be searched. This adds the seam:
one capability object per agent, reached through the same `extension AgentID`
switch that already dispatches textChannel, dialogDriver and openPromptReader.

Unlike those three it is Sendable rather than @MainActor — the backfill runs
inside an actor, off the main actor, so that parsing hundreds of megabytes of
transcript cannot stall the agents running in the same process.

TranscriptRef replaces SearchCorpus.Entry's (projectPath, directory) shape,
which is claude's encoded-directory layout baked into a type. It carries the
literal workingDirectory because that is knowable only at walk time: claude's
encoding is one-way and codex records its cwd inside the file.

Both adapters stub `nil` here; conformers land in Tasks 4 and 6.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: The wire type learns which agent a hit came from

`TranscriptHit` and `NameCandidate` are in `FleetKit`, which compiles for iOS and may not
import `AgentID`. They carry the agent as a `String` and the desk maps it.

**Files:**
- Modify: `Sources/FleetKit/Search/SearchResult.swift`
- Modify: `Sources/FlightDeck/Search/SQLiteSearchIndex.swift:191-199` (the `TranscriptHit`
  construction — pass the new fields as today's constants for now; Task 3 makes them real)
- Modify: `Sources/FlightDeck/Search/SearchCandidates.swift` (pass `agent` per candidate)
- Test: `Tests/FlightDeckTests/TranscriptHitWireTests.swift`
- Test: `Tests/FlightDeckMobileTests/TranscriptHitWireTests.swift`

**Interfaces:**
- Consumes: `TranscriptHit`, `NameCandidate` (existing initializers, both widened here).
- Produces: `TranscriptHit.agent: String`, `.provenance: String?`,
  `.workingDirectory: String`; `NameCandidate.agent: String`. Tasks 3, 8, 9 and 11 read them.
  The agent string is `AgentID.rawValue` — `"claude"` / `"codex"`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/TranscriptHitWireTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

final class TranscriptHitWireTests: XCTestCase {
    /// A newer phone against an older Mac must degrade to today's behaviour rather than
    /// failing the whole frame. The old payload has none of the three new keys.
    func testDecodesPayloadMissingTheNewKeys() throws {
        let legacy = """
        {"rowID":7,"conversationID":"abc","projectPath":"/w/fd","conversationName":"n",
         "snippet":"s","timestamp":0,"offset":12}
        """
        let hit = try JSONDecoder().decode(TranscriptHit.self, from: Data(legacy.utf8))
        XCTAssertEqual(hit.agent, "claude")
        XCTAssertNil(hit.provenance)
        XCTAssertEqual(hit.workingDirectory, "")
        XCTAssertEqual(hit.rowID, 7)
    }

    /// The agent is carried as a raw string because FleetKit compiles for iOS and cannot see
    /// `AgentID`. This pins the two ends agreeing on the spelling.
    func testAgentStringRoundTripsThroughAgentID() throws {
        let hit = TranscriptHit(
            rowID: 1, conversationID: "c", projectPath: "/w/fd", conversationName: "n",
            snippet: "s", timestamp: Date(timeIntervalSince1970: 0), offset: 0,
            agent: AgentID.codex.rawValue, provenance: "exec", workingDirectory: "/w/fd"
        )
        let round = try JSONDecoder().decode(
            TranscriptHit.self, from: JSONEncoder().encode(hit)
        )
        XCTAssertEqual(AgentID(rawValue: round.agent), .codex)
        XCTAssertEqual(round.provenance, "exec")
    }
}
```

Create `Tests/FlightDeckMobileTests/TranscriptHitWireTests.swift` — the phone must decode the
same legacy payload, and it cannot see `AgentID`:

```swift
import FleetKit
import XCTest

final class TranscriptHitWireTests: XCTestCase {
    func testPhoneDecodesPayloadMissingTheNewKeys() throws {
        let legacy = """
        {"rowID":7,"conversationID":"abc","projectPath":"/w/fd","conversationName":"n",
         "snippet":"s","timestamp":0,"offset":12}
        """
        let hit = try JSONDecoder().decode(TranscriptHit.self, from: Data(legacy.utf8))
        XCTAssertEqual(hit.agent, "claude")
        XCTAssertNil(hit.provenance)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `extra argument 'agent' in call` and `value of type 'TranscriptHit' has no
member 'agent'`.

- [ ] **Step 3: Widen the wire types**

In `Sources/FleetKit/Search/SearchResult.swift`, add to `TranscriptHit`:

```swift
    /// Which agent wrote this transcript, as `AgentID.rawValue`.
    ///
    /// **A `String`, not an `AgentID`, because `AgentID` is not in FleetKit** — this module
    /// compiles for iOS and is limited to Foundation/Network/Security, and the phone has no
    /// adapters to name. The desk maps it back with `AgentID(rawValue:)`; a value neither end
    /// recognises degrades to "unknown agent", which is a row without a glyph rather than a
    /// decode failure that would lose every other hit in the frame.
    public let agent: String

    /// codex: `session_meta.payload.source` — "exec", "cli", "vscode". nil for claude.
    /// The only consumer is `SearchRanker`'s `.automated` tier.
    public let provenance: String?

    /// The literal directory this conversation ran in — the project, or one of its worktrees.
    /// Empty when the index predates this field; `SessionStore.openConversation` falls back
    /// to `projectPath` in that case.
    public let workingDirectory: String
```

Widen the memberwise `init` with `agent: String = "claude"`, `provenance: String? = nil`,
`workingDirectory: String = ""` — defaults so existing call sites keep compiling and only
the ones that genuinely know the answer are edited.

Add a custom decoder to `TranscriptHit`:

```swift
    /// Hand-written solely so the three fields added after the phone shipped decode as
    /// absent rather than as a thrown error. A synthesised decoder treats a missing
    /// non-optional key as a failure, and `WireSearchHits` decodes its whole array at once —
    /// so one old payload would lose every hit in the frame, not just its new fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowID = try c.decode(Int64.self, forKey: .rowID)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        projectPath = try c.decode(String.self, forKey: .projectPath)
        conversationName = try c.decode(String.self, forKey: .conversationName)
        snippet = try c.decode(String.self, forKey: .snippet)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        offset = try c.decode(Int.self, forKey: .offset)
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? "claude"
        provenance = try c.decodeIfPresent(String.self, forKey: .provenance)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? ""
    }
```

Add `public let agent: String` to `NameCandidate` with the same `= "claude"` default on its
`init`. `NameCandidate` is not `Codable`, so it needs no custom decoder.

- [ ] **Step 4: Pass the agent at the two call sites that know it**

In `SearchCandidates.build`, sessions and projects come from the deck, so the agent is known
per session. Pass `agent: session.agent.rawValue` for session candidates and
`agent: AgentID.claude.rawValue` for project rows (a project is not an agent; the value is
unused for `.project` kinds and the default would say the same thing).

For conversation candidates from the index, pass `conversation.agent` — added in Task 3.
Until then pass `AgentID.claude.rawValue` and leave a comment naming Task 3.

`SQLiteSearchIndex.search` keeps constructing `TranscriptHit` with the defaults for now;
Task 3 makes them real.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expected PASS.
Run: `./scripts/build-ios.sh && ./scripts/test-ios.sh` — expected PASS, including the new
phone-side decode test.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/Search/SearchResult.swift \
        Sources/FlightDeck/Search/SQLiteSearchIndex.swift \
        Sources/FlightDeck/Search/SearchCandidates.swift \
        Tests/FlightDeckTests/TranscriptHitWireTests.swift \
        Tests/FlightDeckMobileTests/TranscriptHitWireTests.swift
git commit -m "$(cat <<'EOF'
fix: let a search hit say which agent wrote it

TranscriptHit and NameCandidate carry no agent, so a result cannot say which
adapter should resume it — the reason ⌘K can only ever open claude tabs.

The agent travels as a raw string rather than an AgentID: FleetKit compiles for
iOS and is limited to Foundation/Network/Security, and the phone has no adapters
to name. The desk maps it back with AgentID(rawValue:).

TranscriptHit gets a hand-written decoder so the three new keys decode as absent
instead of throwing. WireSearchHits decodes its whole array at once, so without
this one old payload from an un-upgraded Mac would lose every hit in the frame
rather than just the fields it does not carry.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Schema v3 — the index files a transcript by agent

**Files:**
- Modify: `Sources/FlightDeck/Search/SQLiteSearchIndex.swift` (`schemaVersion`,
  `createSchema`, `ingest`, `search`, `conversationNames`, `setConversationName`)
- Modify: `Sources/FlightDeck/Search/SearchIndex.swift` (protocol signatures)
- Modify: `Sources/FlightDeck/Agents/ClaudeRuntime.swift:88-97` (the live-ingest call site)
- Test: `Tests/FlightDeckTests/SQLiteSearchIndexTests.swift`

**Interfaces:**
- Consumes: `TranscriptRef` (Task 1), `TranscriptHit.agent/.provenance/.workingDirectory`
  (Task 2).
- Produces: `SearchIndex.ingest(_:for:offset:)` taking a `TranscriptRef` in place of
  `from source: URL, projectPath: String`; `IndexedConversation.agent: String`. Tasks 4, 5
  and 10 call the new `ingest`.

- [ ] **Step 1: Write the failing test**

Add to `Tests/FlightDeckTests/SQLiteSearchIndexTests.swift`:

```swift
    /// A hit must carry enough to resume the RIGHT agent in the RIGHT directory. Before this,
    /// every hit was implicitly claude-in-the-project-root.
    func testSearchReturnsAgentProvenanceAndWorkingDirectory() throws {
        let ref = TranscriptRef(
            url: URL(fileURLWithPath: "/tmp/rollout.jsonl"),
            projectPath: "/w/fd",
            accountHome: URL(fileURLWithPath: "/home/.codex"),
            workingDirectory: "/w/fd/.claude/worktrees/hunt",
            conversationID: "c1",
            agent: .codex,
            provenance: "exec",
            indexedName: nil,
            modified: Date(timeIntervalSince1970: 0)
        )
        try index.ingest(
            [IndexedMessage(
                conversationID: "c1", role: .user, text: "reticulating splines",
                timestamp: Date(timeIntervalSince1970: 10), offset: 0
            )],
            for: ref, offset: 99
        )

        let hits = try index.search("splines", projects: ["/w/fd"], limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].agent, "codex")
        XCTAssertEqual(hits[0].provenance, "exec")
        XCTAssertEqual(hits[0].workingDirectory, "/w/fd/.claude/worktrees/hunt")
    }

    /// The v2 file on disk is discarded rather than migrated — the index is derived data and
    /// its whole migration story is "delete it and rebuild".
    func testOpeningAVersionTwoIndexRebuildsIt() throws {
        let url = directory.appendingPathComponent("legacy.sqlite")
        // A v2 index has no `agent` column on `source`; opening it must not throw, and must
        // leave a usable empty index rather than a half-readable one.
        let first = try SQLiteSearchIndex(at: url)
        _ = first
        let reopened = try SQLiteSearchIndex(at: url)
        XCTAssertEqual(try reopened.conversationNames().count, 0)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `incorrect argument labels in call (have '_:for:offset:', expected
'_:from:projectPath:offset:')`.

- [ ] **Step 3: Change the schema and the protocol**

In `SearchIndex.swift`, replace the `ingest` requirement:

```swift
    /// Adds `messages`, and — when `offset` is non-nil — records that `ref.url` has been read
    /// through that byte position.
    ///
    /// Takes the whole `TranscriptRef` rather than a URL plus a project path because the
    /// index now files four facts about a transcript (project, agent, provenance, working
    /// directory) and passing them as loose parameters is how three of them get forgotten at
    /// one of the two call sites.
    ///
    /// `nil` means live ingest: add the rows, do NOT touch this source's read position. The
    /// live watcher starts at end-of-file, so its byte position is the wrong number to record
    /// as indexing progress — recording it would make the backfill start there and silently
    /// never index that conversation's history, which is exactly the history ⌘K exists to
    /// search. An `offset` of 0 means the file restarted and this source's rows are replaced.
    func ingest(_ messages: [IndexedMessage], for ref: TranscriptRef, offset: UInt64?) throws
```

Add `agent` to `IndexedConversation`:

```swift
struct IndexedConversation: Equatable, Sendable {
    let name: String
    let projectPath: String
    /// `AgentID.rawValue`. A conversation with no open tab still has to resume as the right
    /// agent, and this row is the only record of which one it was.
    let agent: String
}
```

Widen `setConversationName` to `setConversationName(_ name: String, projectPath: String,
agent: String, for id: String) throws`.

In `SQLiteSearchIndex.swift`, bump `schemaVersion` to `3` and replace the `source` table in
`createSchema`:

```sql
            -- agent/provenance/working_directory live HERE rather than on `message`: a
            -- transcript file has exactly one of each, so this is where they normalise.
            -- Repeating them per message would cost three columns across hundreds of
            -- thousands of rows to answer a question that is per-file.
            CREATE TABLE source(
              path TEXT PRIMARY KEY,
              offset INTEGER NOT NULL,
              agent TEXT NOT NULL,
              provenance TEXT,
              working_directory TEXT NOT NULL
            );
            CREATE TABLE conversation(
              conversation_id TEXT PRIMARY KEY, name TEXT NOT NULL,
              project_path TEXT NOT NULL, agent TEXT NOT NULL
            );
```

In `ingest`, write the source row with its new columns (an `INSERT OR REPLACE` on `path`, so
a re-walk updates provenance if codex ever changes it), taking every value from `ref`.

In `search`, join through `source` and populate the new `TranscriptHit` fields:

```swift
        let statement = try prepare("""
            SELECT m.id, m.conversation_id, m.project_path, m.timestamp, m.offset,
                   snippet(message_fts, 0, char(2), char(3), '…', 24),
                   s.agent, s.provenance, s.working_directory
            FROM message_fts
            JOIN message m ON m.id = message_fts.rowid
            -- LEFT JOIN, not JOIN: a message row is written before its source row's offset is
            -- committed at the end of the file's pass, so an inner join would make every hit
            -- from the file currently being indexed invisible until that pass finished.
            LEFT JOIN source s ON s.path = m.source
            WHERE message_fts MATCH ? AND m.project_path IN (\(placeholders))
            ORDER BY bm25(message_fts)
            LIMIT ?
            """)
```

Read columns 6/7/8 into `agent` (defaulting to `"claude"` when NULL), `provenance` and
`workingDirectory`.

- [ ] **Step 4: Update the two ingest call sites**

`SearchIndexBuilder` (Task 4 rewrites it wholesale — for now, construct a `TranscriptRef`
inline from what it already has, so this task's suite is green) and
`ClaudeRuntime.attach`'s `onMessages` closure, which must build a ref from the session's
binding. `ClaudeRuntime` already closes over `projectPath(id)`; add a `workingDirectory(id)`
closure beside it returning `session.transcriptDirectory`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, including every pre-existing `SQLiteSearchIndexTests` case.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Search/SQLiteSearchIndex.swift \
        Sources/FlightDeck/Search/SearchIndex.swift \
        Sources/FlightDeck/Search/SearchIndexBuilder.swift \
        Sources/FlightDeck/Agents/ClaudeRuntime.swift \
        Tests/FlightDeckTests/SQLiteSearchIndexTests.swift
git commit -m "$(cat <<'EOF'
feat: file each indexed transcript by agent, provenance and directory

A hit could not say which agent wrote it or which worktree it ran in, so ⌘K
could only ever open a claude tab in a project root.

The three columns go on `source`, not `message`: a transcript file has exactly
one of each, so repeating them per message would cost three columns across
hundreds of thousands of rows to answer a per-file question.

search() joins them with a LEFT JOIN deliberately. A message row is written
before its source row's offset is committed at the end of that file's pass, so
an inner join would make every hit from the file currently being indexed
invisible until the pass finished.

ingest() now takes the whole TranscriptRef rather than a URL plus a project
path — four facts passed as loose parameters is how three get forgotten at one
of the two call sites.

schemaVersion 2 -> 3. No migration: the index is derived data whose entire
migration story is "delete it and rebuild".

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Claude conforms, and the builder goes agent-blind

Behaviour must not change. Every pre-existing search test is the regression suite.

**Files:**
- Create: `Sources/FlightDeck/Agents/ClaudeSearchCorpus.swift`
- Modify: `Sources/FlightDeck/Agents/ClaudeAdapter.swift` (replace the Task 1 stub)
- Modify: `Sources/FlightDeck/Search/SearchIndexBuilder.swift` (`build` takes
  `[TranscriptRef]`; delete its private `transcripts(in:)` and `containsRename`)
- Move: `Sources/FlightDeck/Search/SearchCorpus.swift` → `Sources/FlightDeck/Agents/ClaudeSearchCorpus+Directories.swift`
- Test: `Tests/FlightDeckTests/ClaudeSearchCorpusTests.swift`
- Test: `Tests/FlightDeckTests/SearchIndexBuilderTests.swift` (union-prune case)

**Interfaces:**
- Consumes: `AgentSearchCorpus`, `TranscriptRef`, `ConversationNaming` (Task 1);
  `SearchIndex.ingest(_:for:offset:)` (Task 3).
- Produces: `SearchIndexBuilder.build(_ refs: [TranscriptRef], progress:)`. Task 7 calls it.
  `SearchCorpus.candidateWorkingDirectories(forProjectAt:listing:)` keeps its current
  signature and stays public to the module — Task 5 uses it.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/ClaudeSearchCorpusTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ClaudeSearchCorpusTests: XCTestCase {
    private var corpus: AgentSearchCorpus { ClaudeAdapter.searchCorpus! }

    /// The walk knows which candidate directory produced the match, so a conversation that
    /// ran in a worktree resumes there. Before this the directory was thrown away and
    /// `SessionStore` re-derived it by probing.
    func testWorktreeTranscriptCarriesItsLiteralWorkingDirectory() throws {
        // Fixture: a project with one worktree, each with a transcript under its own encoded
        // directory. Build it with FileManager in a temp dir, then assert the ref for the
        // worktree's transcript names the worktree path, not the project root.
    }

    /// Claude's authority rule, unchanged in substance: a rename beats a first user message,
    /// and a pass that saw no rename may not overwrite one an earlier pass stored.
    func testRenameIsAuthoritativeAndAPlainMessageIsNot() {
        let ref = TranscriptRef(
            url: URL(fileURLWithPath: "/tmp/c.jsonl"), projectPath: "/w/fd",
            accountHome: URL(fileURLWithPath: "/home/.claude"), workingDirectory: "/w/fd",
            conversationID: "c", agent: .claude, provenance: nil, indexedName: nil,
            modified: Date(timeIntervalSince1970: 0)
        )
        let renamed = #"{"type":"custom-title","customTitle":"Badge anchor"}"#
        XCTAssertEqual(
            corpus.conversationName(inLines: [renamed], for: ref),
            .authoritative("Badge anchor")
        )

        let plain = #"{"type":"user","message":{"content":"fix the chevron"}}"#
        guard case .fallback = corpus.conversationName(inLines: [plain], for: ref) else {
            return XCTFail("a plain user message must not be authoritative")
        }

        XCTAssertEqual(corpus.conversationName(inLines: [], for: ref), .unknown)
    }
}
```

Add to `Tests/FlightDeckTests/SearchIndexBuilderTests.swift`:

```swift
    /// **The trap this whole design is most likely to fall into.** `build` opens with
    /// `prune(keepingSources:projects:)`, which drops every source outside the set it is
    /// handed. One pass per agent would therefore delete the other agent's rows on every
    /// run, and the two would take turns wiping each other — producing an index that looks
    /// populated and is missing half its corpus.
    func testOneBuildOverBothAgentsPrunesNeither() async throws {
        // Two refs, one per agent, each with its own transcript file and messages.
        // Build once with both. Assert a search finds BOTH agents' text.
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `ClaudeAdapter.searchCorpus` is `nil`, so the force-unwrap traps.

- [ ] **Step 3: Write `ClaudeSearchCorpus`**

Create `Sources/FlightDeck/Agents/ClaudeSearchCorpus.swift`. `transcripts` is today's
`SearchCorpus.directories` + `SearchIndexBuilder.transcripts(in:)` fused, now per-account and
retaining the candidate directory:

```swift
/// Claude's half of ⌘K: `~/.claude/projects/<encoded-cwd>/<conversation>.jsonl`.
///
/// Per-account, unlike the code this replaces. A second login is a second `CLAUDE_CONFIG_DIR`
/// with its own `projects/` tree, and reading one hardcoded root is what made ⌘K blind to
/// every conversation under a non-default account.
struct ClaudeSearchCorpus: AgentSearchCorpus {
    var listing: @Sendable (String) -> [String] = { SearchCorpus.defaultListing($0) }
    var exists: @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    func transcripts(
        forProjects projects: [String], accounts: [AgentAccount]
    ) -> [TranscriptRef] {
        var seen: Set<URL> = []
        var refs: [TranscriptRef] = []
        for account in accounts where account.agent == .claude {
            let root = account.home.appendingPathComponent("projects", isDirectory: true)
            for project in projects {
                // The candidate directories are the project and its worktrees — the literal
                // paths. Kept alongside their encoded names rather than discarded, because
                // the encoding is one-way: nothing downstream can turn `-w-flight-deck` back
                // into a path, which is why `workingDirectory` has to be captured here.
                for workingDirectory in SearchCorpus.candidateWorkingDirectories(
                    forProjectAt: project, listing: listing
                ) {
                    let name = ClaudeSession.encodedProjectDirName(for: workingDirectory)
                    let directory = root.appendingPathComponent(name, isDirectory: true)
                    guard exists(directory.path), seen.insert(directory).inserted else { continue }
                    refs += Self.transcripts(
                        in: directory, project: project,
                        workingDirectory: workingDirectory, accountHome: account.home,
                        listing: listing
                    )
                }
            }
        }
        return refs
    }
    // ... indexedMessages delegates to TranscriptExtractor; conversationName wraps
    //     ConversationTitle.resolve plus the containsRename check moved from the builder.
}
```

`conversationName` is the builder's current rule, relocated verbatim in meaning:

```swift
    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming {
        guard let name = ConversationTitle.resolve(lines: lines) else { return .unknown }
        // `containsRename` moved here from `SearchIndexBuilder`, where it was the one piece
        // of claude-record knowledge left in an otherwise agent-blind actor. A later pass
        // sees only newly appended lines, so it cannot know an earlier pass already found a
        // rename — which is why a name resolved only as a fallback must never overwrite.
        return Self.containsRename(lines) ? .authoritative(name) : .fallback(name)
    }
```

- [ ] **Step 4: Make `SearchIndexBuilder` agent-blind**

`build(_ refs: [TranscriptRef], progress:)`. Delete `transcripts(in:)` and `containsRename`.
Inside `index(_ ref:)`, replace the two claude call sites:

```swift
            batch += corpus.indexedMessages(
                inLine: line, conversationID: ref.conversationID, at: Int(offset)
            )
```

and the naming block:

```swift
        // The verdict, not a bare name: only `.authoritative` may overwrite, for the reason
        // `AgentSearchCorpus.conversationName` documents. `.unknown` writes nothing at all,
        // which is what stops a pass with no conversational lines in it blanking a good name.
        switch corpus.conversationName(inLines: read.lines, for: ref) {
        case .authoritative(let name):
            try? index.setConversationName(
                name, projectPath: ref.projectPath, agent: ref.agent.rawValue,
                for: ref.conversationID
            )
        case .fallback(let name):
            if (try? index.conversationNames())?[ref.conversationID] == nil {
                try? index.setConversationName(
                    name, projectPath: ref.projectPath, agent: ref.agent.rawValue,
                    for: ref.conversationID
                )
            }
        case .unknown:
            break
        }
```

`corpus` is `ref.agent.searchCorpus`, resolved per file — refs of both agents arrive in one
list, so it cannot be hoisted out of the loop.

Sort `refs` by `modified` descending at the top of `build` (newest first is why search
becomes useful before the walk finishes).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS — critically, every pre-existing `SearchIndexBuilderTests` and
`SearchCorpusTests` case, unchanged. If any needed its assertion relaxed, stop: the
refactor changed behaviour and that is the bug.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudeSearchCorpus.swift \
        Sources/FlightDeck/Agents/ClaudeAdapter.swift \
        Sources/FlightDeck/Search/SearchIndexBuilder.swift \
        Sources/FlightDeck/Search/SearchCorpus.swift \
        Tests/FlightDeckTests/ClaudeSearchCorpusTests.swift \
        Tests/FlightDeckTests/SearchIndexBuilderTests.swift
git commit -m "$(cat <<'EOF'
refactor: move claude's transcript knowledge out of the index builder

SearchIndexBuilder called TranscriptExtractor and ConversationTitle directly,
which is what made an otherwise agent-blind actor claude-only. Both call sites
now go through ref.agent.searchCorpus, resolved per file rather than hoisted —
refs from both agents arrive in one list.

containsRename moves to ClaudeSearchCorpus, where it belongs: it is knowledge of
claude's record shapes, and the builder now only needs the verdict. The three-way
verdict replaces a bare name so `.unknown` can write nothing, which is what stops
a pass containing no conversational lines from blanking a good name.

Discovery is now per-account. Reading one hardcoded projects root is what made
⌘K blind to every conversation under a second claude login.

The walk also keeps the literal working directory it matched, instead of
discarding it and leaving SessionStore to re-derive the answer by probing
candidate directories for a matching filename.

No behaviour change is intended: the pre-existing builder and corpus suites are
the regression test and pass unmodified.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Codex discovery

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexSearchCorpus.swift` (discovery half)
- Test: `Tests/FlightDeckTests/CodexSearchCorpusDiscoveryTests.swift`

**Interfaces:**
- Consumes: `AgentSearchCorpus`, `TranscriptRef`;
  `SearchCorpus.candidateWorkingDirectories(forProjectAt:listing:)`.
- Produces: `CodexSearchCorpus.transcripts(forProjects:accounts:)`. Task 6 adds the other
  two members to this same type; Task 7 wires it to the adapter.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/CodexSearchCorpusDiscoveryTests.swift`. Build a temp
`<home>/sessions/2026/09/16/rollout-*.jsonl` tree whose first lines are `session_meta`
records, then assert:

```swift
    func testAttributesARolloutByItsRecordedCwd()
    func testSkipsARolloutWhoseCwdIsNoSidebarProject()       // scratchpads, unopened repos
    func testAttributesAWorktreeRolloutToItsParentProject()  // via candidateWorkingDirectories
    func testSkipsArchivedSessions()                         // ~/.codex/archived_sessions
    func testCarriesSourceAsProvenance()                     // "exec" survives to the ref
    func testNormalisesPrivateVarAgainstVar()                // /private/var vs /var
    func testAMalformedFirstLineDropsOnlyItsOwnFile()        // 6 of 563 are unparsable
    func testReadsTheIndexedNameFromSessionIndex()           // session_index.jsonl, once
```

Write each with a real fixture and a real assertion — no placeholders. The `/private/var`
case matters because macOS produces it routinely and an exact-string comparison silently
yields "no threads here", which is indistinguishable from an empty corpus.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `cannot find 'CodexSearchCorpus' in scope`.

- [ ] **Step 3: Implement discovery**

```swift
/// Codex's half of ⌘K.
///
/// **Why a walk and not `thread/list`.** The adapter already speaks `thread/list` with a
/// `cwd` filter and it returns exactly the fields discovery wants. It is still the wrong
/// tool: it needs a live app-server per account at backfill time, which the claude leg has
/// no equivalent of; `codexThreadListLimit` caps it at 10; and its `cwd` match is
/// exact-string with a SILENT empty result on any normalisation difference — the failure
/// `CodexAdapter.threads(inDirectory:)` calls the one most likely to make it look like it
/// simply does not work. Reading the first line of every rollout measured 0.08 s for 563
/// files and depends on nothing.
struct CodexSearchCorpus: AgentSearchCorpus {
    /// Codex records the conversation's cwd in the first record, and nowhere else. There is
    /// no cheap index to consult instead: `session_index.jsonl` is rename-only (no cwd, no
    /// path) and `thread_history_1.sqlite` is a recent-turns projection — 85 turns against
    /// 563 rollouts on the machine this was measured on. The rollouts ARE the corpus.
    private static func meta(ofRolloutAt url: URL) -> (id: String, cwd: String, source: String?)?
```

Key rules to implement:
- Read only the first line (`FileHandle` + read up to a bounded prefix; `session_meta`
  carries `base_instructions`, tens of KB, but `cwd` precedes it — read the whole first line
  rather than a fixed prefix, and cap at 1 MB so a corrupt file cannot be read forever).
- Normalise both sides through one helper (`URL(fileURLWithPath:).resolvingSymlinksInPath()
  .standardized.path`) before comparing. One helper, used on both sides, or the bug returns.
- `archived_sessions/` is a sibling of `sessions/` and is simply never walked.
- Read each account's `session_index.jsonl` **once** into `[String: String]` before the walk,
  and stamp `indexedName` from it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexSearchCorpus.swift \
        Tests/FlightDeckTests/CodexSearchCorpusDiscoveryTests.swift
git commit -m "$(cat <<'EOF'
feat: find codex rollouts belonging to the open projects

Codex writes rollouts into a date tree and records the conversation's cwd inside
the file, so claude's encoded-directory mapping has no codex equivalent.
Discovery reads the first line of each rollout for its session_meta and
attributes it by exact cwd match against the same worktree-aware candidate set
claude encodes.

A walk rather than thread/list: that RPC needs a live app-server per account at
backfill time, caps at 10 threads, and answers a non-matching cwd with an empty
list rather than an error. Measured, the walk is 0.08s for 563 files and depends
on nothing.

Both sides of the cwd comparison go through one normalisation helper. macOS
produces /private/var against /var routinely, and an exact-string mismatch is
indistinguishable from "this project has no threads" — silent, and the failure
most likely to make this look broken.

session_index.jsonl is read once per account, not once per rollout.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Codex extraction and naming

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexSearchCorpus.swift`
- Modify: `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift` (replace the Task 1 stub with
  `static let searchCorpus: AgentSearchCorpus? = CodexSearchCorpus()`)
- Create: `Tests/FlightDeckTests/Fixtures/codex-rollout-sample.jsonl`
- Test: `Tests/FlightDeckTests/CodexSearchCorpusExtractionTests.swift`

**Interfaces:**
- Consumes: `CodexSearchCorpus` (Task 5), `ConversationNaming`, `IndexedMessage`.
- Produces: `CodexAdapter.searchCorpus` non-nil. Task 7 depends on it being non-nil.

- [ ] **Step 1: Write the failing tests**

```swift
    /// Prose comes from `event_msg` ONLY. The `response_item` family is the model
    /// transcript: a second copy of the same prose, plus a role:"user" record that is the
    /// assembled prompt (skills, plugin catalogue, environment context — tens of KB every
    /// turn), plus `reasoning` carrying an encrypted blob. Indexing it doubles every reply
    /// and puts instruction blobs into search results.
    func testIndexesEventMsgProseOnly()
    func testDropsResponseItemDuplicateOfTheSameReply()
    func testDropsTheAssembledPromptBlob()
    func testDropsAgentReasoning()
    func testParsesFractionalSecondTimestamps()   // 2026-09-16T16:25:50.889Z

    /// The naming rule, in order.
    func testARealRenameIsAuthoritative()                    // "Pipeline Review"
    func testAPlaceholderLosesToTheFirstUserMessage()        // "session 206" -> the message
    func testAPlaceholderAloneIsAFallback()                  // better than a bare UUID
    func testANameThatMerelyStartsWithSessionIsNotAPlaceholder()  // "session 4 retrospective"
    func testNoNameAndNoMessageIsUnknown()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `indexedMessages` returns `[]` (unimplemented protocol stub).

- [ ] **Step 3: Implement extraction and naming**

```swift
    /// `^session \d+$` — Flight Deck's OWN default tab title (`SessionStore.swift`'s
    /// `"session \(sessionCounter)"`), pushed to codex by `thread/name/set`. So codex's index
    /// is polluted with names this app wrote: of 70 interactive rollouts on the machine this
    /// was measured on, 66 are named and a large share read `session 189` / `session 206`.
    ///
    /// Porting claude's "a rename always beats the first user message" rule literally would
    /// let those win, and ⌘K rows would read `session 206` for a conversation that opens
    /// "Index the Claude Code conversations for this directory."
    ///
    /// Anchored on purpose: a thread a person genuinely named `session 4 retrospective` is
    /// not a placeholder and keeps its name.
    private static let placeholder = /^session \d+$/
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexSearchCorpus.swift \
        Sources/FlightDeck/Agents/Codex/CodexAdapter.swift \
        Tests/FlightDeckTests/Fixtures/codex-rollout-sample.jsonl \
        Tests/FlightDeckTests/CodexSearchCorpusExtractionTests.swift
git commit -m "$(cat <<'EOF'
feat: index codex prose, and name a thread something readable

Extraction takes the event_msg family only, the same split CodexTimelineMapper
documents. response_item is the model transcript: a second copy of the prose, a
role:"user" record that is the assembled prompt blob, and a reasoning record
carrying ciphertext. Indexing it would double every reply and put instruction
blobs in the results.

agent_reasoning earns a timeline row but not an index row, for the reason
TranscriptExtractor already drops tool blocks: searching "rename" should find
the message where somebody asked for one.

Naming cannot port claude's rule literally. Codex names live in
session_index.jsonl, and that file is polluted with Flight Deck's own default
tab titles — "session 206" and friends, pushed there by thread/name/set. So a
name matching ^session \d+$ loses to the thread's first user message, while a
real rename still wins. The pattern is anchored: "session 4 retrospective" is
somebody's actual title and keeps it.

CodexAdapter.title(fromTranscriptAt:) deliberately stays nil. It answers a
different question — a repointed tab, served by CodexNameWatcher — and handing a
rollout to claude's JSONL parser is the bug it exists to prevent.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Wire the backfill to every agent

This is the task that makes codex conversations actually appear in ⌘K.

**Files:**
- Modify: `Sources/FlightDeck/AppDelegate.swift:244-265` (`startSearch`'s build task)
- Test: `Tests/FlightDeckTests/SearchBackfillWiringTests.swift`

**Interfaces:**
- Consumes: `AgentID.searchCorpus` (Task 1), `SearchIndexBuilder.build(_:progress:)`
  (Task 4), `preferences.accounts`.
- Produces: nothing downstream; this is a wiring leaf.

- [ ] **Step 1: Write the failing test**

Assert the assembly function — extracted so it is testable without an `AppDelegate`:

```swift
    /// Every agent contributes to ONE list. Asserted rather than assumed because the
    /// alternative — a build per agent — silently halves the index (see
    /// `testOneBuildOverBothAgentsPrunesNeither`).
    func testAssemblyAsksEveryAgentAndConcatenates()
    /// Newest first: search becomes useful long before a walk of hundreds of megabytes ends.
    func testAssemblySortsNewestFirstAcrossAgents()
    /// An agent answering nil contributes nothing and must not abort the others.
    func testAnUnsearchableAgentIsSkipped()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh` — expected FAIL, function does not exist.

- [ ] **Step 3: Extract and implement the assembly**

```swift
    /// The refs every agent contributes, as ONE list.
    ///
    /// One list, never one build per agent: `SearchIndexBuilder.build` opens with a prune
    /// that drops every source outside the set it is handed, so per-agent passes would take
    /// turns deleting each other's rows and leave an index that looks populated and is
    /// missing half its corpus.
    static func corpusRefs(
        projects: [String], accounts: [AgentAccount]
    ) -> [TranscriptRef] {
        AgentID.allCases
            .compactMap(\.searchCorpus)
            .flatMap { $0.transcripts(forProjects: projects, accounts: accounts) }
            .sorted { $0.modified > $1.modified }
    }
```

Call it from `startSearch`'s deferred task in place of `SearchCorpus.directories(...)`,
passing `store.repos.map(\.url.path)` and the accounts from preferences.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expected PASS.

- [ ] **Step 5: Verify by hand, once**

Build and launch the Debug app **in place** — never swap `/Applications`, which kills every
other session. Wait out the 3 s backfill, ⌘K a phrase that appears only in a codex thread,
and confirm a row appears naming the conversation rather than `session N`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/AppDelegate.swift \
        Tests/FlightDeckTests/SearchBackfillWiringTests.swift
git commit -m "$(cat <<'EOF'
feat: back-fill the search index from every agent

startSearch asked SearchCorpus for claude directories under one hardcoded
projects root. It now asks every agent's searchCorpus, across every account, and
hands the builder one combined list.

One list, never one build per agent: build() opens with a prune that drops every
source outside the set it is handed, so per-agent passes would take turns
deleting each other's rows — an index that looks populated and is missing half
its corpus.

Sorted newest-first across agents, so search becomes useful long before a walk
of hundreds of megabytes finishes rather than at the end of it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Rank automated runs below conversations

**Files:**
- Modify: `Sources/FleetKit/Search/NameMatcher.swift` (`MatchTier`)
- Modify: `Sources/FleetKit/Search/SearchRanker.swift` (group ordering)
- Test: `Tests/FlightDeckTests/SearchRankerTests.swift`

**Interfaces:**
- Consumes: `TranscriptHit.provenance` (Task 2).
- Produces: `MatchTier.automated`. Task 11 reads `result.tier` for the phone's glyph.

- [ ] **Step 1: Write the failing test**

```swift
    /// 86% of rollouts on a working machine are `codex exec` runs, and on the machine this
    /// was measured on 485 of 487 were in ONE repo. Sharing the transcript tier lets that
    /// project's automation bury its conversations.
    func testExecHitsSortBelowEveryInteractiveHit()

    /// The invariant the two-clock design depends on: transcript results are appended whole,
    /// below the sorted name matches, so a late batch can only append BELOW what is drawn and
    /// cannot shove the highlighted row out from under someone reaching for Return.
    func testAutomatedTierStillAppendsBelowNameMatches()

    /// Grouping must survive the partition — a conversation's continuation rows stay adjacent
    /// to their heading row rather than being split across the tier boundary.
    func testAnExecConversationKeepsItsRowsAdjacent()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh` — expected FAIL, `type 'MatchTier' has no member 'automated'`.

- [ ] **Step 3: Add the tier and partition the groups**

In `NameMatcher.swift`:

```swift
    case transcript = 3
    /// A transcript hit from an automated run — a `codex exec`. Indexed, but below every
    /// conversation.
    case automated = 4
```

In `SearchRanker.rank`, **the ordering fix is in the group sort, not in the tier comparator.**
The grouped block is appended whole after `results.sorted(by:)`, so a tier alone changes
nothing about where these rows land relative to each other:

```swift
        // Automated groups last. This is done HERE, in the group ordering, and not by leaning
        // on `MatchTier`'s `<`: the grouped block is appended whole below the sorted name
        // matches (see the return statement), so the tier a grouped row carries never reaches
        // a comparator. Partitioning the groups is what actually moves them, and doing it at
        // group granularity is what keeps a conversation's continuation rows adjacent to the
        // heading row they belong to.
        let groups: [[TranscriptHit]] = order
            .compactMap { byConversation[$0] }
            .sorted { lhs, rhs in
                guard let a = lhs.first, let b = rhs.first else { return false }
                let aAutomated = a.provenance == "exec"
                let bAutomated = b.provenance == "exec"
                if aAutomated != bAutomated { return !aAutomated }
                if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
                return a.conversationID < b.conversationID
            }
```

and set each row's `tier` to `hit.provenance == "exec" ? .automated : .transcript`, so the
row's own label is honest even though the comparator is not what placed it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expected PASS.
Run: `./scripts/build-ios.sh && ./scripts/test-ios.sh` — FleetKit changed, so the phone
builds and its suite runs.

- [ ] **Step 5: Commit**

```bash
git add Sources/FleetKit/Search/NameMatcher.swift \
        Sources/FleetKit/Search/SearchRanker.swift \
        Tests/FlightDeckTests/SearchRankerTests.swift
git commit -m "$(cat <<'EOF'
feat: rank automated codex runs below real conversations

86% of the rollouts on a working machine are `codex exec`, and 485 of 487 of
them were in a single repo. Sharing the transcript tier lets one project's
automation bury its own conversations.

The ordering is done in the GROUP sort, not by leaning on MatchTier's
comparator. The grouped transcript block is appended whole below the sorted name
matches, so the tier a grouped row carries never reaches a comparator — adding a
case alone would have changed nothing, which is the kind of fix that passes
review and does nothing. Partitioning at group granularity also keeps a
conversation's continuation rows adjacent to their heading row.

The row still carries `.automated` so its label is honest.

Ranking lives in FleetKit, so the phone inherits the same order from the same
implementation rather than growing a second copy that can drift.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Return opens the right agent, in the right directory

**Files:**
- Modify: `Sources/FlightDeck/Search/SearchActivation.swift` (`Activation` cases gain `agent`)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`openConversation`; **delete**
  `resolvedTranscriptDirectory`)
- Modify: `Sources/FlightDeck/AppDelegate.swift` (`SearchPanel`'s `onSelect`)
- Test: `Tests/FlightDeckTests/SearchActivationTests.swift`
- Test: `Tests/FlightDeckTests/OpenConversationTests.swift`

**Interfaces:**
- Consumes: `SearchResult` carrying agent + working directory via `TranscriptHit`/
  `NameCandidate` (Task 2).
- Produces: `SearchActivation.Activation.resume(conversationID:projectPath:title:agent:workingDirectory:)`
  and the matching `addProjectThenResume`.

- [ ] **Step 1: Write the failing tests**

```swift
    func testACodexHitPlansAsCodex()
    func testResumeCarriesTheStoredWorkingDirectoryNotTheProjectRoot()
    /// Unchanged and load-bearing: a second writer on a live conversation means two processes
    /// appending one transcript. Codex refuses it outright ("already has an active writer").
    func testALiveCodexTabIsSelectedRatherThanResumedTwice()
    func testOpenConversationResolvesTheCodexAccountNotTheClaudeOne()
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh` — expected FAIL, `resume` has no `agent` argument.

- [ ] **Step 3: Thread the agent through**

In `openConversation`, replace `launchAccount(for: .claude, project: projectPath)` with the
activation's agent, set `transcriptDirectory` from the carried working directory (falling
back to `projectPath` when empty), set `transcriptPath` from the hit's source, and sanitise
the title through `activation.agent.sanitizedTitle` rather than `ClaudeSession.sanitizedName`.

Delete `resolvedTranscriptDirectory` and its `openConversation` default argument. Its own doc
comment describes the bug it papered over — nothing in a result identified the worktree — and
the walk now records the answer.

The existing `deferred` → `resumeRestoredCodex([session.id], pinsPredateThisRun: false)`
branch becomes reachable for the first time. Its argument and its comment are already correct;
do not change them.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expected PASS.

- [ ] **Step 5: Verify by hand, once**

Launch the Debug build in place, ⌘K a codex conversation, press Return, and confirm a
**codex** tab opens on that thread — in its worktree if it ran in one.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Search/SearchActivation.swift \
        Sources/FlightDeck/SessionStore.swift \
        Sources/FlightDeck/AppDelegate.swift \
        Tests/FlightDeckTests/SearchActivationTests.swift \
        Tests/FlightDeckTests/OpenConversationTests.swift
git commit -m "$(cat <<'EOF'
fix: resume a searched conversation as its own agent

openConversation resolved `launchAccount(for: .claude, ...)` unconditionally, so
Return on any result opened a claude tab — the method's own comment anticipated
this and said a default would decide it the wrong way round on the first day
search learned about codex.

resolvedTranscriptDirectory is deleted rather than generalised. It probed
candidate directories for a file named after the conversation because nothing in
a result identified which worktree the conversation ran in. The corpus walk
knows, and now records it, so there is nothing left to re-derive.

The deferred resumeRestoredCodex branch becomes reachable for the first time. Its
`pinsPredateThisRun: false` was already correct: the pin is the conversation the
user searched for, so a reconcile pass following the directory's newest thread
would answer a different question than the one they asked.

Selecting an already-open tab instead of resuming is unchanged and stays
load-bearing — codex refuses a second writer outright.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Live ingest for codex

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexRolloutWatcher.swift` (add `onMessages`)
- Modify: `Sources/FlightDeck/Agents/Codex/CodexRuntime.swift` (wire it, mirroring
  `ClaudeRuntime.attach`)
- Test: `Tests/FlightDeckTests/CodexRolloutWatcherTests.swift`

**Interfaces:**
- Consumes: `CodexSearchCorpus.indexedMessages` (Task 6),
  `SearchIndex.ingest(_:for:offset:)` (Task 3).
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing test**

```swift
    func testAppendedProseReachesTheIndex()
    /// `offset: nil`, always. This watcher starts at end-of-file, so recording its read
    /// position as indexing progress would make the backfill resume from there and silently
    /// never index that thread's history — exactly the history ⌘K exists to search.
    func testLiveIngestNeverRecordsAReadPosition()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh` — expected FAIL, no `onMessages` parameter.

- [ ] **Step 3: Add the leg**

Mirror `ClaudeRuntime.attach` exactly, including passing `onMessages` unconditionally rather
than gating on whether an index exists yet — `ClaudeRuntime`'s comment explains why deciding
at attach time reintroduces the ordering dependency reading it live was meant to avoid.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh` — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexRolloutWatcher.swift \
        Sources/FlightDeck/Agents/Codex/CodexRuntime.swift \
        Tests/FlightDeckTests/CodexRolloutWatcherTests.swift
git commit -m "$(cat <<'EOF'
feat: index a codex turn as it happens

ClaudeRuntime fed the search index from its transcript watcher; codex had no
such leg, so a running codex conversation was searchable only after the next
backfill.

offset: nil, always. The watcher starts at end-of-file, so its read position is
never the right number to record as indexing progress — doing so would make the
backfill resume from there and silently skip that thread's whole history.

onMessages is passed unconditionally rather than gated on whether an index
exists yet, for the reason ClaudeRuntime documents: deciding at attach time
needs to know whether searchIndex() will EVER be non-nil, and a session attached
before startSearch runs would otherwise never become searchable at all.

The watcher already decodes every line for turn boundaries, so this costs
dictionary lookups, not a second JSONSerialization pass.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: The phone shows which agent a hit is

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionSearchResults.swift`
- Modify: `Sources/FlightDeck/Search/SearchOverlayView.swift:109` (desk glyph)
- Test: `Tests/FlightDeckMobileTests/SessionSearchModelTests.swift`

**Interfaces:**
- Consumes: `TranscriptHit.agent` (Task 2), `MatchTier.automated` (Task 8).
- Produces: nothing downstream.

Keep `Sources/FlightDeckMobile/` **flat** — `build-ios.sh`'s type-check fallback globs
`*.swift` only, so a subdirectory goes silently unchecked on a machine with no iOS platform.

- [ ] **Step 1: Write the failing test**

```swift
    /// A mixed result list is unreadable if the rows do not say which agent they came from.
    func testAHitCarriesItsAgentToTheRow()
    /// The phone must order exactly as the desk does — same implementation, one rule.
    func testExecHitsSortLastOnThePhoneToo()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-ios.sh` — expected FAIL.

- [ ] **Step 3: Add the glyph**

A per-row SF Symbol chosen from the agent string, with an explicit unknown case — an agent
neither end recognises draws no glyph rather than a wrong one.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/build-ios.sh && ./scripts/test-ios.sh` — expected PASS.
Run: `./scripts/test-unit.sh` — expected PASS (the desk overlay changed).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeckMobile/SessionSearchResults.swift \
        Sources/FlightDeck/Search/SearchOverlayView.swift \
        Tests/FlightDeckMobileTests/SessionSearchModelTests.swift
git commit -m "$(cat <<'EOF'
feat: show which agent a search result came from

⌘K and the phone's search now mix claude and codex conversations in one list,
and a row that does not say which is which is guesswork.

An agent string neither end recognises draws no glyph rather than a wrong one —
the same degradation the wire decoder takes for an unknown agent.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Documentation

**Files:**
- Modify: `docs/ARCHITECTURE.md` (the search section; `AgentSearchCorpus` as the fourth
  capability)
- Modify: `docs/HANDOFF.md` (current state)
- Modify: `docs/FOLLOWUPS.md` (the deferred items)
- Modify: `AGENTS.md` (layout table — `Sources/FlightDeck/Agents/` now holds corpus conformers)

- [ ] **Step 1: Audit stale comments repo-wide**

Behaviour changed, so comments describing the old behaviour are now wrong. Specifically
check: `SearchCorpus`'s doc comment (still true about encoding, no longer the only corpus),
`SearchActivation.plan`'s `transcriptDirectory` parameter comment (the "production wiring has
no answer to pass" claim is now false), `SessionStore.openConversation`'s codex comment at
:3985 (search now DOES build codex sessions — the comment's prediction came true and must be
rewritten as present tense), and `ClaudeRuntime`'s `onMessages` comment.

- [ ] **Step 2: Record the deferred items in `docs/FOLLOWUPS.md`**

- Flight Deck pushes `session N` placeholder titles to codex via `thread/name/set`, polluting
  `session_index.jsonl`. Fixing it at the source would let claude's naming rule port cleanly;
  the ~30 already written still need the fallback.
- `~/.codex/archived_sessions/` is deliberately not searched.
- Filtering ⌘K by agent (`agent:codex …`) — YAGNI until mixed results are confusing.

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md docs/HANDOFF.md docs/FOLLOWUPS.md AGENTS.md
git commit -m "$(cat <<'EOF'
docs: describe search as an agent capability, not a claude feature

Also corrects three comments the behaviour change falsified, including
openConversation's note predicting "the first day search learns about codex" —
that day is this branch, so it is rewritten in the present tense.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review

**Spec coverage.** §1 → Tasks 4, 7. §1.1 multi-account → Task 4. §3 protocol → Task 1.
§3.1 `TranscriptRef` → Task 1. §3.2 `AgentID` switch → Task 1. §3.3 builder + union prune →
Task 4. §4.1 claude discovery → Task 4. §4.2 codex discovery → Task 5. §5 extraction →
Task 6. §6 naming → Task 6. §7 ranking → Task 8. §8.1 schema → Task 3. §8.2 activation →
Task 9. §9 live ingest → Task 10; wire → Task 2; phone → Tasks 2, 8, 11. §11 verification →
distributed. No gaps.

**One correction to the spec, found while planning.** §7 claims the `.automated` tier sorts
below `.transcript` because `MatchTier`'s `<` is `rawValue` order. That is not sufficient:
`SearchRanker.rank` appends the grouped transcript block **whole** after
`results.sorted(by: byTierThenRecency)`, so a grouped row's tier never reaches a comparator.
Task 8 therefore partitions the *groups*, which is also what keeps continuation rows adjacent
to their heading. The tier is still set, so the row's label stays honest.

**Type consistency.** `ingest(_:for:offset:)` is defined in Task 3 and called in Tasks 4
and 10. `conversationName(inLines:for:)` is defined in Task 1 and implemented in Tasks 4 and
6. `TranscriptHit.agent` is a `String` everywhere (Task 2), mapped through
`AgentID(rawValue:)` only on the desk. `setConversationName(_:projectPath:agent:for:)` is
widened in Task 3 and called in Task 4.
