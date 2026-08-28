# Timeline Vocabulary and History Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the one content vocabulary both agents map onto, the paginated history request/response that rides the existing fleet socket, and the Mac-side readers that answer it — so a phone can ask for any page of any session's conversation and get it, before any screen exists to draw it.

**Architecture:** `TimelineItem` and its page/anchor types join the wire value types in `FleetKit`. Two pure static mappers in the app module (`ClaudeTimelineMapper`, `CodexTimelineMapper`) turn one JSONL line into zero or more items, from captured fixtures, with no process and no timing. A `TranscriptPager` reads an arbitrary byte window of an append-only JSONL file backwards or forwards; `TimelineReader` composes pager + mapper + byte budget into one page. `TimelineService` resolves a tab id to an agent and a transcript URL through `SessionStore`, runs the read off the main actor, and answers on it. `FleetSocketServer` grows one new closure — `onRequest`, with an **asynchronous** reply — because a page is file I/O and `onCommand`'s synchronous single-frame return cannot carry it. Nothing is pushed: the phone asks.

**Tech Stack:** Swift 6 (`FleetKit`), Swift 5 (`FlightDeck`), Foundation `FileHandle`/`JSONSerialization`, Network.framework (WebSocket over TLS-PSK, already shipped), XCTest.

**Spec:** [`docs/superpowers/specs/2026-08-18-mobile-companion-design.md`](../specs/2026-08-18-mobile-companion-design.md) — **§6 is the binding section**; §4 (wire protocol) and §1.3 (the transcript is rich enough to render from) constrain it; §9 (prompt bridging) is designed there and **built in slice 2 — nothing in this plan builds it**, but §6's `.prompt` kind ships in the vocabulary so slice 2 is a Mac-side change and not a protocol break.

**Precedes:** [`2026-08-21-session-timeline-screen.md`](2026-08-21-session-timeline-screen.md), which draws it. That plan consumes every type this one produces and adds nothing to the wire.

---

## Why this is two plans

Slice 1b splits on exactly the seam that split the replication spine from pairing, and Plan A from Plan B in the short-code work. It worked both times, and the same three reasons hold:

- **Each half produces working, testable software on its own.** This plan's final task runs a real `FleetService` over a real loopback socket, asks for a real page of a real transcript file, and asserts the items that come back. That is the whole feature minus a way to look at it. The other plan is a screen with a fixture-backed state machine underneath it.
- **The two halves fail review for different reasons.** Everything here is verified by `./scripts/test-unit.sh` — byte offsets, codecs, mapping tables, socket plumbing. Everything in the screen plan is verified by `./scripts/build-ios.sh`, a simulator, and the manual checklist this repo already keeps in `docs/MOBILE.md`. A reviewer cannot meaningfully reject a `SwiftUI` row's density while approving a backwards-paging byte-window algorithm.
- **One document covering both would be unreviewable.** Seventeen tasks and two verification regimes.

## Findings that change §6, decided here

**Read this section before Task 1.** Three of §6's statements are contradicted by the code as it actually exists on this branch. They are recorded here so an executor does not "fix" the plan back toward the spec. Each was checked against the source and against real files on this machine, not assumed.

### 1. Codex has no `item/started` / `item/completed` path to map from. §6's source for codex does not exist.

§6 says codex "maps from `item/started` / `item/completed` plus streaming deltas." Those are **codex app-server notifications**, and Flight Deck's app-server notification path was **deleted**, not deprecated — commit `b76a07b`, *"observe codex from its files, and delete the path that never fired"*. `CodexEventMapper`'s own doc comment states why:

> This used to translate app-server notifications instead. That path was removed, not deprecated: those notifications only ever reach the connection that made the change, so none of them described anything a user did in a `codex resume` TUI.

The production observation path is `CodexRolloutWatcher` over the thread's rollout `.jsonl`. `rg 'item/'` over `Sources/` returns **nothing**; the strings survive only in the generated app-server schema fixture. **This plan maps codex from the rollout file**, which is the same shape claude's mapping already has (tail a JSONL, parse a line, emit) and is the only source that sees a turn driven by a `codex resume` TUI.

### 2. Neither agent streams tokens. §6's first "accepted asymmetry" does not exist.

§6 says "Codex streams tokens; claude's transcript lands per-message, so on claude the phone shows completed messages, not a live cursor." Streaming for codex could only come from the deleted notification path: a survey of **494 rollout files** on this machine (`~/.codex/sessions/**/*.jsonl`) finds **zero** records of any `*delta*` type. `AgentMessageDeltaNotification` exists in the app-server schema and is written to no file.

So the asymmetry is real but **symmetric in the opposite direction**: *both* agents land whole records, and neither can be rendered as a live cursor. §6's requirement — surface it, do not paper over it — is satisfied by never drawing a streaming affordance for either agent. `TimelineItem.Status.streaming` still ships in the vocabulary, because a future app-server route or slice 2's prompt bridging may need it, and a `Status` added later would be a protocol break. **Every item either mapper emits is `.complete`**, and Task 3 and Task 4 each assert it.

### 3. Sub-agents are a count for **claude** and *nothing at all* for **codex**. §6 has this backwards.

§6 says "sub-agents reduce to a count for claude while codex exposes per-sub-agent state." The code says the reverse, and so does the disk:

- Claude: `TranscriptWatcher` tracks outstanding top-level `Agent` `tool_use` ids and reports `onSubagentCount(_:)`. A count, and a real one.
- Codex: `CodexEventMapper`'s doc comment — *"No `collab` record exists in any of 492 surveyed rollouts, so there is no ground truth to map it from. Deliberately never emitted for codex."* Re-checked here across the same corpus: `rg 'collab|subagent|sub_agent'` over `~/.codex/sessions` returns **nothing**. `WireSession.subagentCount` is therefore **always 0 for a codex tab**, and 0 does not mean "none are running" — it means "unknown".

The honest surfacing is the *screen* plan's job (it must not render "0 subagents" for codex, which would assert a fact nobody has). This plan's job is to not encode the spec's inverted claim anywhere. **No per-sub-agent state is added to `TimelineItem`.** Claude's sub-agent transcripts live in a sibling `<conversationId>/subagents/agent-*.jsonl` directory that nothing reads and this plan does not start reading.

### 4. §6's "extend `TranscriptWatcher` rather than adding a second reader" is honoured as *one parser, two readers*.

§6 says claude's mapping should extend the existing `TranscriptWatcher` path. `TranscriptWatcher` is a **forward-only tail**: it holds one `offset`, never seeks backwards, and its `TailReader` exists to consume newly appended bytes. Backwards pagination over an arbitrary byte range is not a thing a tail can do, so a second *reader* is unavoidable.

What §6 is actually protecting against — two independent parses of the same file disagreeing about what it says — is prevented by structure instead:

- One **parser** per agent (`ClaudeTimelineMapper`, `CodexTimelineMapper`), pure and static, in the same shape and the same directory as the existing `ClaudeSession.events(inLine:sessionID:)` and `CodexEventMapper.events(inRolloutLine:)`.
- One **poll loop** per tab. `TranscriptWatcher` and `CodexRolloutWatcher` are untouched by this plan: no second timer, no second `offset`, no second source of truth for title or sub-agent count.
- The pager is stateless and on-demand — it runs only when a phone asks.

Stated up front so nobody "fixes" this by bolting a page cache onto `TranscriptWatcher`.

### 5. Nothing here is pushed, so the DEBUG drift check is untouched — and stays that way.

`FleetReplicator`'s drift check compares the folded mirror against a fresh `FleetProjection` after every batch, and its doc comment is explicit that it is load-bearing until `SessionStore`'s fleet state is encapsulated. **This plan adds no `FleetEvent` case, no `SessionStore` mutation, and no northbound broadcast.** The timeline is answered from files on request; it never changes fleet state, so there is no new mutation site for the check to miss. `TimelineService` reads `SessionStore` and writes nothing to it — Task 7's `timelineSource(of:)` is a pure read in the exact idiom of the existing `toolContext()`.

That is a deliberate design choice, not an accident of scoping: pushing timeline items would mean per-connection subscription state in `FleetSocketServer`, a northbound frame outside the `seq` space (or inside it, corrupting resume for clients not watching that session), and a Mac-side broker. §6 says "a long transcript is still bulk transfer and still must not be pushed unasked — the phone asks for the page it needs." The phone asks.

## Global Constraints

- **`FleetKit` imports Foundation, Network, Security, CryptoKit and `BoringSSLShim` only.** No AppKit, no UIKit, no SwiftUI, no Observation. The `FleetKitiOS` target compiles the same sources for iOS and is what enforces this.
- **`FleetKit` builds in Swift 6 language mode.** The rest of the project is Swift 5. `SWIFT_VERSION: "5.0"` in `project.yml`'s `settings.base` is deliberate (vendored Ghostty is not Swift-6 clean) — do not "fix" it.
- **Sessions are keyed on the tab `id`, never `conversationId`.** The latter is not stable across a re-pin and, for codex, differs from the tab id from birth. Every timeline request carries a tab id.
- **`wait(for:)` deadlocks in a `@MainActor` async XCTest method** under this repo's headless harness. Use `await fulfillment(of:timeout:)`. Every test in this plan that awaits a socket is in that shape.
- **`FleetSocketServer` and `FleetConnector` confine their state to `queue`** (`.main` in production) and assert it with `dispatchPrecondition`. Every closure this plan adds keeps that discipline: entry points assert on entry, invocation sites assert before invoking. Do not resolve a concurrency diagnostic here with `nonisolated(unsafe)`.
- **Fixtures are captured, never authored.** Everything under `Tests/FlightDeckTests/Fixtures/` must be named `*.captured.*`, must carry a `*.provenance.json` beside it, and lines may be **dropped, never edited**. `Fixtures` is a folder reference in `project.yml`, so a new subdirectory lands in the bundle with its structure intact and needs no build change.
- **`project.yml` needs no change in this plan.** `Sources/FlightDeck` and `Sources/FleetKit` are both recursive path entries. Do not edit it — another agent is editing it on this branch.
- **Four files are being edited concurrently by other agents on this branch.** `Sources/FlightDeck/Fleet/FleetService.swift` (Task 10 touches it), `Sources/FleetKit/FleetClient.swift` and `Sources/FleetKit/FleetSocket.swift` (Tasks 2 and 9 touch them — the pairing-channel work is hoisting `webSocketEndpoint(for:)` out of `FleetClient` into `FleetSocket` as this is written), and `Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift` (nothing here touches it). **Re-read each immediately before editing and merge into what is there rather than pasting over it.** `git status` at the start of every task; this checkout is shared, so never `git stash`, `git checkout .`, or revert blind.
- **Never run `./scripts/smoke.sh`.** It seizes the foreground for ~70s and turns the user's keystrokes into phantom failures.
- **A debug Mac instance and an iOS Simulator may be live.** Check `pgrep -f "harness/Flight Deck.app"` before running the suite, and never launch a build to "try it".
- **Verification per task:** `./scripts/test-unit.sh` (baseline **1211**, 0 failures) and `./scripts/build-ios.sh` (three `BUILD SUCCEEDED`). Report the count after every task.
- **This branch's standing bar: every test must be shown to fail against the bug it exists for.** Seven tests have shipped here unable to do that, each caught late — one passed 7 runs in 40 with the code it guarded deleted, and a mutation campaign found three survivors in a suite that looked green. Every task below whose test guards something subtle carries an explicit **"prove it can fail"** step naming the exact mutation. That step is not optional and its result goes in the task report.

## Limits, fixed here

One file, `Sources/FleetKit/TimelineLimits.swift`, holds every number, so a reviewer can see the whole budget at once and a future change moves one line.

| Constant | Value | Why |
|---|---|---|
| `maxItemBytes` | 65_536 | A tool result larger than this is truncated with `truncatedBytes` recording the remainder. Covers essentially every `Bash` output and most file reads; §7 wants "the full command output" and this is how much of it a phone gets. |
| `maxPageBytes` | 131_072 | A page stops accumulating records once its item bodies exceed this. **Always emits at least one record**, so a single oversized record cannot stall backwards pagination forever. |
| `defaultLimit` | 40 | Source **records**, not items — one record can carry several items, so `items.count` can exceed it. |
| `maxLimit` | 200 | A client asking for more is clamped, not refused. |
| `window` | 524_288 | Bytes read per pager pass. A page whose `limit` records do not fit in one window returns fewer; the client pages again. |
| `maximumMessageSize` | 4_194_304 | Set on `NWProtocolWebSocket.Options`. **The SDK default is 0, meaning no receive limit** (`ws_options.h`) — an unbounded frame is an unbounded allocation, and this plan is the first thing to put bulk on the socket. |

## File Structure

**Created — `Sources/FleetKit/`:**

| File | Responsibility |
|---|---|
| `Timeline.swift` | `TimelineItem`, its nested `Kind` / `Status` / `Body`. The vocabulary, and nothing else. |
| `TimelineLimits.swift` | The six constants above. No behaviour. |
| `TimelineFrames.swift` | `TimelineAnchor`, `TimelinePage`, `FleetRequest`, `FleetRequestError`, and the hand-written codecs that flatten them into `ClientFrame.req` / `ServerFrame.page`. |

**Created — `Sources/FlightDeck/`:**

| File | Responsibility |
|---|---|
| `Agents/ClaudeTimelineMapper.swift` | One claude transcript line → `[TimelineItem]`. Pure, static, no I/O. |
| `Agents/Codex/CodexTimelineMapper.swift` | One codex rollout line → `[TimelineItem]`. Pure, static, no I/O. |
| `Timeline/TranscriptPager.swift` | Byte-window paging over an append-only JSONL file, backwards or forwards. Knows nothing about agents. |
| `Timeline/TimelineReader.swift` | Pager + mapper + budget + truncation → one `TimelinePage`. Pure apart from the file read; `Sendable`, so it runs off the main actor. |
| `Fleet/TimelineService.swift` | Resolves a tab id through `SessionStore`, dispatches the read, answers on the main actor. |

**Modified:**

| File | Change |
|---|---|
| `Sources/FleetKit/Frames.swift` | `ClientFrame.req(cid:_:)`, `ServerFrame.page(cid:_:)`. |
| `Sources/FleetKit/FleetSocket.swift` | Set `maximumMessageSize`. |
| `Sources/FleetKit/FleetSocketServer.swift` | `onRequest` with an asynchronous reply; the `req` arm of the frame switch. |
| `Sources/FleetKit/FleetClient.swift` | `send(_ request: FleetRequest) -> Int`. |
| `Sources/FleetKit/FleetConnector.swift` | `request(_:then:)`, a pending table, and a drain on teardown. |
| `Sources/FlightDeck/SessionStore.swift` | `timelineSource(of:)` — one method, a pure read. |
| `Sources/FlightDeck/Fleet/FleetService.swift` | Own a `TimelineService`; wire `server.onRequest`. **Re-read before editing.** |
| `docs/ARCHITECTURE.md` | A paragraph on the history channel in the fleet-replication section. |

**Test files created, all under `Tests/FlightDeckTests/`:** `TimelineVocabularyTests`, `TimelineFrameCodingTests`, `ClaudeTimelineMapperTests`, `CodexTimelineMapperTests`, `TimelineFixtureTests`, `TranscriptPagerTests`, `TimelineReaderTests`, `TimelineServiceTests`, `FleetRequestPlumbingTests`, `TimelineLoopbackTests`.

**Fixtures created:** `Tests/FlightDeckTests/Fixtures/Claude/transcript.captured.jsonl` + `transcript.captured.provenance.json`; `Tests/FlightDeckTests/Fixtures/Codex/rollout-content.captured.jsonl` (added to the existing `Fixtures/Codex/` provenance file's `files` list).

---

### Task 1: The `TimelineItem` vocabulary

**Files:**
- Create: `Sources/FleetKit/Timeline.swift`
- Create: `Sources/FleetKit/TimelineLimits.swift`
- Test: `Tests/FlightDeckTests/TimelineVocabularyTests.swift`

**Interfaces:**
- Consumes: nothing — this is the base of the plan.
- Produces: `TimelineItem` (`id: String`, `kind: Kind`, `status: Status`, `body: Body`, `at: String?`), `TimelineItem.Kind` (`.userTurn .assistantText .thinking .toolCall .toolResult .prompt .unknown`), `TimelineItem.Status` (`.streaming .complete .unknown`), `TimelineItem.Body` (`text: String`, `summary: String?`, `tool: String?`, `callID: String?`, `truncatedBytes: Int`, `isError: Bool`), `TimelineItem.identifier(offset:index:) -> String`, `TimelineLimits.maxItemBytes/maxPageBytes/defaultLimit/maxLimit/window/maximumMessageSize`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/TimelineVocabularyTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// The content vocabulary, and the one property of it that is not obvious: an unrecognised
/// `kind` or `status` must DECODE, not throw.
///
/// `FleetSocket.receive` treats a frame it cannot parse as a protocol violation and ends the
/// connection — deliberately, because two sides silently disagreeing about state is the
/// failure the whole resume design exists to prevent. That rule is correct for a malformed
/// frame and catastrophic for a well-formed one carrying a kind this build has not heard of:
/// a Mac shipping a new `TimelineItem.Kind` would disconnect every older phone, permanently,
/// with no diagnostic. Same reasoning as `WireSession.agent` being a `String` rather than an
/// enum — see that property's comment.
final class TimelineVocabularyTests: XCTestCase {
    private func decode(_ json: String) throws -> TimelineItem {
        try JSONDecoder().decode(TimelineItem.self, from: Data(json.utf8))
    }

    func testAnUnknownKindDecodesRatherThanThrowing() throws {
        let item = try decode("""
            {"id":"12#0","kind":"videoClip","status":"complete","body":{"text":"hi"}}
            """)
        XCTAssertEqual(item.kind, .unknown)
        XCTAssertEqual(item.body.text, "hi", "the rest of the item must survive the unknown kind")
    }

    func testAnUnknownStatusDecodesRatherThanThrowing() throws {
        let item = try decode("""
            {"id":"12#0","kind":"assistantText","status":"buffering","body":{"text":"hi"}}
            """)
        XCTAssertEqual(item.status, .unknown)
    }

    func testEveryKnownKindRoundTrips() throws {
        for kind in [TimelineItem.Kind.userTurn, .assistantText, .thinking,
                     .toolCall, .toolResult, .prompt] {
            let item = TimelineItem(
                id: "0#0", kind: kind, status: .complete,
                body: TimelineItem.Body(text: "x")
            )
            let data = try JSONEncoder().encode(item)
            XCTAssertEqual(try JSONDecoder().decode(TimelineItem.self, from: data), item,
                           "\(kind) did not survive a round trip")
        }
    }

    /// `.prompt` is in the vocabulary and nothing emits it. Slice 2 (spec §9) is where a
    /// pending approval becomes a timeline row, and it must be a Mac-side change only — a
    /// `Kind` added after phones shipped would decode as `.unknown` on every one of them.
    func testThePromptKindExistsSoSliceTwoIsNotAProtocolBreak() throws {
        XCTAssertEqual(TimelineItem.Kind(rawValue: "prompt"), .prompt)
    }

    func testAnItemsIdentifierIsItsByteOffsetAndBlockIndex() {
        XCTAssertEqual(TimelineItem.identifier(offset: 4096, index: 2), "4096#2")
    }

    /// The body's optional fields are absent from the wire when they are nil, so a plain
    /// prose item is a small object rather than four explicit nulls. This is checked because
    /// a page carries up to 200 of them.
    func testAProseBodyEncodesWithoutItsToolFields() throws {
        let data = try JSONEncoder().encode(
            TimelineItem(id: "0#0", kind: .assistantText, status: .complete,
                         body: TimelineItem.Body(text: "hello"))
        )
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("\"tool\""))
        XCTAssertFalse(json.contains("\"callID\""))
        XCTAssertFalse(json.contains("\"summary\""))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `cannot find 'TimelineItem' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FleetKit/TimelineLimits.swift`:

```swift
import Foundation

/// Every size this feature is bounded by, in one place, so the whole budget can be read at
/// once and a change moves one line rather than five.
///
/// The numbers are a phone's budget, not a terminal's: a page is bulk transfer over a
/// possibly-cellular link, and the spec (§6) is explicit that history "must not be pushed
/// unasked". These are what "asked for" costs.
public enum TimelineLimits {
    /// Per-item body cap. Beyond this the text is cut and `Body.truncatedBytes` records what
    /// was dropped, so a client can say "showing the first 64 KB of 210 KB" rather than
    /// silently presenting a partial file read as a whole one.
    public static let maxItemBytes = 65_536

    /// A page stops accumulating records once the bodies it already holds exceed this — but
    /// never before it holds one. See `TimelineReader`: a page that can come back empty
    /// because its first record is oversized makes backwards pagination stall forever on
    /// that record, with no way for a client to get past it.
    public static let maxPageBytes = 131_072

    /// Source **records** per page, not items: one assistant record can carry text, thinking
    /// and three tool calls, so `TimelinePage.items.count` is routinely larger than this.
    public static let defaultLimit = 40

    /// A client asking for more is clamped rather than refused — a limit is a hint about
    /// what a screen wants, and refusing the request would turn a mildly greedy client into
    /// a broken one.
    public static let maxLimit = 200

    /// Bytes read per pager pass. A page whose `limit` records do not fit in one window
    /// comes back short; the client simply pages again from the cursor it was given.
    public static let window = 524_288

    /// The WebSocket receive cap, applied on both ends.
    ///
    /// **`ws_options.h` documents the default as 0, which means no receive limit at all.**
    /// That was harmless while every frame was a snapshot or a status delta and is not now:
    /// this plan is the first thing to put bulk on the socket, and an unbounded frame is an
    /// unbounded allocation on a phone. Comfortably above `maxPageBytes` even after JSON
    /// escaping doubles a worst-case body.
    public static let maximumMessageSize = 4_194_304
}
```

Create `Sources/FleetKit/Timeline.swift`:

```swift
import Foundation

/// One thing that happened in a conversation, in the single vocabulary both agents map onto.
///
/// On a channel separate from `AgentEvent` deliberately (spec §6): `AgentEvent` is four cases
/// sized for a sidebar row, and widening it to carry conversation content would drag desktop
/// code through a change it does not need.
public struct TimelineItem: Identifiable, Codable, Equatable, Sendable {
    /// What this row is. `unknown` is not a case any mapper emits — it is what a build
    /// decodes when a newer Mac sends a kind it has not heard of.
    ///
    /// Decoding an unknown value rather than throwing is load-bearing, not lenient:
    /// `FleetSocket.receive` ends the connection on a frame it cannot parse, so a strict
    /// enum here would mean a Mac shipping one new kind silently and permanently
    /// disconnecting every phone built before it. Same rule, same reason, as
    /// `WireSession.agent` being a `String`.
    public enum Kind: String, Codable, Equatable, Sendable {
        case userTurn, assistantText, thinking, toolCall, toolResult, prompt
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknown
        }
    }

    /// Whether the agent is still adding to this item.
    ///
    /// **Nothing in this codebase emits `.streaming`, and that is a finding rather than an
    /// omission.** Both agents are observed from the files they write, and neither writes
    /// token deltas — a survey of 494 codex rollouts on the build machine found zero
    /// `*delta*` records, and claude's transcript lands one whole record at a time. The case
    /// ships anyway because a `Status` added after phones shipped is a protocol break, and
    /// slice 2's prompt bridging (spec §9) may want it.
    public enum Status: String, Codable, Equatable, Sendable {
        case streaming, complete
        case unknown

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Status(rawValue: raw) ?? .unknown
        }
    }

    /// The renderable content. One shape for six kinds, because the alternative — an
    /// associated-value enum — would need a hand-written codec per case and gives a client
    /// nothing it does not get from optional fields being absent.
    public struct Body: Codable, Equatable, Sendable {
        /// The full text, up to `TimelineLimits.maxItemBytes`. For a `.toolCall` this is the
        /// tool's input, pretty-printed; for a `.toolResult` it is the output.
        public var text: String
        /// A one-line preview for a list row. Set only where `text` is unfit for one — a
        /// tool call's input is JSON, and `{` is not a useful row. Nil means "use the first
        /// line of `text`", which is right for every prose kind.
        public var summary: String?
        /// The tool's name, for `.toolCall` and `.toolResult`. Nil elsewhere.
        public var tool: String?
        /// The agent's own id for the call this row is, or answers — claude's `tool_use_id`,
        /// codex's `call_id`. This is what pairs a result with its call, and it is
        /// deliberately NOT `id`: the two agents' id spaces have nothing in common, while
        /// `id` has one rule that works for both.
        public var callID: String?
        /// Bytes dropped from `text` at the per-item cap. `0` means whole. A client that
        /// hides this is claiming a truncated file read is a complete one.
        public var truncatedBytes: Int
        /// The source record said this result was an error.
        public var isError: Bool

        public init(
            text: String, summary: String? = nil, tool: String? = nil,
            callID: String? = nil, truncatedBytes: Int = 0, isError: Bool = false
        ) {
            self.text = text
            self.summary = summary
            self.tool = tool
            self.callID = callID
            self.truncatedBytes = truncatedBytes
            self.isError = isError
        }

        enum CodingKeys: String, CodingKey {
            case text, summary, tool, callID, truncatedBytes, isError
        }

        /// Hand-written so the four rarely-set fields are ABSENT rather than null, and so
        /// `truncatedBytes: 0` / `isError: false` cost nothing. A page carries up to 200
        /// bodies; four explicit nulls each is real bytes on a cellular link.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(summary, forKey: .summary)
            try c.encodeIfPresent(tool, forKey: .tool)
            try c.encodeIfPresent(callID, forKey: .callID)
            if truncatedBytes != 0 { try c.encode(truncatedBytes, forKey: .truncatedBytes) }
            if isError { try c.encode(isError, forKey: .isError) }
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            tool = try c.decodeIfPresent(String.self, forKey: .tool)
            callID = try c.decodeIfPresent(String.self, forKey: .callID)
            truncatedBytes = try c.decodeIfPresent(Int.self, forKey: .truncatedBytes) ?? 0
            isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        }
    }

    /// Stable across fetches, and unique within one session's transcript.
    ///
    /// `"<byteOffset>#<blockIndex>"` — the offset of the record's line in the file, and the
    /// index of the block within it. Deliberately NOT the agent's own record id: claude's
    /// records carry a `uuid` and codex's `event_msg` records carry nothing at all, so a
    /// natural-id rule would need a per-agent fallback and would still not be uniform. An
    /// append-only file gives every line exactly one offset for its whole life, which is all
    /// "stable" has to mean here.
    ///
    /// The one case that breaks it is a transcript REPLACED rather than appended to, which
    /// shifts every offset. `TimelinePage.reset` is how a client is told that happened; see
    /// `TranscriptPager`.
    public let id: String
    public var kind: Kind
    public var status: Status
    public var body: Body
    /// The record's own timestamp, verbatim, exactly as the agent wrote it (ISO-8601).
    /// Carried as a `String` and never parsed on the Mac: both agents already write a valid
    /// ISO-8601 instant, a `Date` would drag `JSONEncoder`'s date strategy into the wire
    /// contract, and the client is the only side that formats it anyway.
    public var at: String?

    public init(
        id: String, kind: Kind, status: Status, body: Body, at: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.body = body
        self.at = at
    }

    /// The one id rule, in one place, so the two mappers cannot drift.
    public static func identifier(offset: Int, index: Int) -> String { "\(offset)#\(index)" }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1217 tests, 0 failures.

- [ ] **Step 5: Prove the forward-compatibility tests can fail**

Temporarily delete `Kind`'s custom `init(from:)` so the synthesized strict decoder is used again:

```swift
        case userTurn, assistantText, thinking, toolCall, toolResult, prompt
        case unknown
        // (custom init(from:) removed)
```

Run: `./scripts/test-unit.sh 2>&1 | grep -A3 testAnUnknownKindDecodes`
Expected: **FAIL** — `dataCorrupted … Cannot initialize Kind from invalid String value videoClip`. Restore the initializer and re-run to green. Record both outcomes in the task report.

- [ ] **Step 6: Verify the iOS boundary**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`
Expected: three successes, no errors. (These two files import Foundation only, so this is cheap — but it is the check that catches an import that should not be there, and it runs after every FleetKit task in this plan.)

- [ ] **Step 7: Commit**

```bash
git add Sources/FleetKit/Timeline.swift Sources/FleetKit/TimelineLimits.swift \
        Tests/FlightDeckTests/TimelineVocabularyTests.swift
git commit -m "feat: one content vocabulary both agents can map onto

TimelineItem is the shape spec §6 names, on a channel separate from
AgentEvent — four cases sized for a sidebar row should not grow to carry
conversation content.

Two decisions worth the reader's time. Kind and Status decode an
unrecognised value to .unknown rather than throwing: FleetSocket.receive
ends the connection on an unparseable frame, so a strict enum would mean
one new kind on the Mac silently disconnecting every older phone. And an
item's id is its byte offset plus block index, not the agent's own record
id — claude records carry a uuid and codex event_msg records carry
nothing, so there is no natural id rule that covers both.

.prompt ships with nothing emitting it. Slice 2 (§9) turns a pending
approval into a row, and a Kind added after phones shipped would decode
as .unknown on all of them.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The request/response frames

**Files:**
- Create: `Sources/FleetKit/TimelineFrames.swift`
- Modify: `Sources/FleetKit/Frames.swift` (add one `ClientFrame` case and one `ServerFrame` case)
- Modify: `Sources/FleetKit/FleetSocket.swift` (`maximumMessageSize`)
- Test: `Tests/FlightDeckTests/TimelineFrameCodingTests.swift`

**Interfaces:**
- Consumes: `TimelineItem`, `TimelineLimits` (Task 1); `ClientFrame`, `ServerFrame`, `FleetSocket.webSocketParameters(_:)` (shipped).
- Produces: `TimelineAnchor` (`.latest`, `.before(Int)`, `.after(Int)`), `TimelinePage` (`session: UUID`, `items: [TimelineItem]`, `start: Int`, `end: Int`, `hasMore: Bool`, `reset: Bool`), `FleetRequest.timeline(session:anchor:limit:)`, `FleetRequestError` (`.disconnected`, `.server(code: String)`), `ClientFrame.req(cid: Int, FleetRequest)`, `ServerFrame.page(cid: Int, TimelinePage)`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/TimelineFrameCodingTests.swift`:

```swift
import Network
import XCTest
@testable import FleetKit

/// The history channel's frames, and the two properties of them that are not obvious.
///
/// One: `req` and `cmd` share a socket and a `cid` space but are different verbs. `ack` means
/// *dispatched, not done* (spec §4) — correct for "mark this read", and wrong for "tell me
/// what is in this session", which has to answer with data. So a request gets its own tag and
/// its own reply frame rather than being smuggled into `FleetCommand`.
///
/// Two: `page` carries a `cid` and no `seq`. A history fetch is not fleet state and must not
/// move a client's resume point — see `testAPageCarriesNoSequence`.
final class TimelineFrameCodingTests: XCTestCase {
    private let session = UUID(uuidString: "6C6E9A1E-6E5E-4F5A-9C7C-0F1A2B3C4D5E")!

    private func roundTrip(_ frame: ClientFrame) throws -> ClientFrame {
        try JSONDecoder().decode(ClientFrame.self, from: JSONEncoder().encode(frame))
    }

    private func roundTrip(_ frame: ServerFrame) throws -> ServerFrame {
        try JSONDecoder().decode(ServerFrame.self, from: JSONEncoder().encode(frame))
    }

    func testEveryAnchorRoundTrips() throws {
        for anchor in [TimelineAnchor.latest, .before(4096), .after(0)] {
            let frame = ClientFrame.req(
                cid: 7, .timeline(session: session, anchor: anchor, limit: 40)
            )
            XCTAssertEqual(try roundTrip(frame), frame, "\(anchor) did not survive")
        }
    }

    /// The request is flattened into the frame object, the same way `cmd` flattens a
    /// `FleetCommand`, so one request reads as one line in a packet dump.
    func testARequestIsOneFlatObject() throws {
        let data = try JSONEncoder().encode(
            ClientFrame.req(cid: 7, .timeline(session: session, anchor: .before(88), limit: 40))
        )
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["t"] as? String, "req")
        XCTAssertEqual(json["cid"] as? Int, 7)
        XCTAssertEqual(json["op"] as? String, "timeline.page")
        XCTAssertEqual(json["anchor"] as? String, "before")
        XCTAssertEqual(json["cursor"] as? Int, 88)
        XCTAssertNil(json["request"], "the request must not be nested under a key")
    }

    func testTheLatestAnchorCarriesNoCursor() throws {
        let data = try JSONEncoder().encode(
            ClientFrame.req(cid: 1, .timeline(session: session, anchor: .latest, limit: 40))
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["anchor"] as? String, "latest")
        XCTAssertNil(json["cursor"], "there is no cursor to send when asking for the end")
    }

    func testAPageRoundTrips() throws {
        let page = TimelinePage(
            session: session,
            items: [TimelineItem(id: "0#0", kind: .userTurn, status: .complete,
                                 body: .init(text: "hello"), at: "2026-08-21T00:00:00.000Z")],
            start: 0, end: 120, hasMore: true, reset: false
        )
        XCTAssertEqual(try roundTrip(ServerFrame.page(cid: 7, page)), .page(cid: 7, page))
    }

    /// A history fetch is not fleet state. `page` carries a correlation id and no sequence,
    /// so a client that pages back through an hour of transcript does not move the resume
    /// point it will hand the Mac on its next `hello`.
    func testAPageCarriesNoSequence() throws {
        let data = try JSONEncoder().encode(
            ServerFrame.page(cid: 3, TimelinePage(session: session, items: [],
                                                  start: 0, end: 0, hasMore: false, reset: false))
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["t"] as? String, "page")
        XCTAssertNil(json["seq"], "a page is not a fleet event and must not be sequenced")
    }

    /// `ServerFrame`'s decoder tries its own tags first and treats anything else as a
    /// `FleetEvent` tag, which is why the two namespaces must never collide. `FleetEventTag`'s
    /// values are all dotted and the frame tags are not; `page` keeps that property.
    func testThePageTagDoesNotCollideWithAnEventTag() {
        XCTAssertFalse("page".contains("."))
        XCTAssertNil(FleetEventTag(rawValue: "page"))
    }

    /// The receive cap, which the SDK leaves at "unlimited" by default (`ws_options.h`:
    /// "A maximum message size of 0 means there is no receive limit"). This plan is the first
    /// thing to put bulk on this socket, so an unbounded frame stops being theoretical.
    func testTheWebSocketReceiveSizeIsBounded() throws {
        let parameters = FleetSocket.webSocketParameters(.tcp)
        let options = try XCTUnwrap(
            parameters.defaultProtocolStack.applicationProtocols
                .compactMap { $0 as? NWProtocolWebSocket.Options }.first
        )
        XCTAssertEqual(options.maximumMessageSize, TimelineLimits.maximumMessageSize)
        XCTAssertGreaterThan(options.maximumMessageSize, TimelineLimits.maxPageBytes * 2,
                             "the cap must clear a worst-case page after JSON escaping")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `cannot find 'TimelineAnchor' in scope`, `type 'ClientFrame' has no member 'req'`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FleetKit/TimelineFrames.swift`:

```swift
import Foundation

/// Where in a transcript a client wants to read from.
///
/// Cursors are **byte offsets into the source file, always at a line boundary**, and they are
/// opaque to the client: it never computes one, only echoes back a `start` or an `end` it was
/// given. That is what keeps the file format out of the protocol.
public enum TimelineAnchor: Equatable, Sendable {
    /// The newest records. What opening a session asks for.
    case latest
    /// The records ending immediately before this offset. What scrolling up asks for.
    case before(Int)
    /// Whatever has been appended since this offset. What a screen already open asks for.
    case after(Int)

    /// The wire spelling. A table rather than a derivation, for the same reason
    /// `FleetEventTag` is one: a case rename must not silently become a protocol break.
    var name: String {
        switch self {
        case .latest: return "latest"
        case .before: return "before"
        case .after: return "after"
        }
    }

    var cursor: Int? {
        switch self {
        case .latest: return nil
        case .before(let cursor), .after(let cursor): return cursor
        }
    }

    init?(name: String, cursor: Int?) {
        switch (name, cursor) {
        case ("latest", _): self = .latest
        case ("before", let cursor?): self = .before(cursor)
        case ("after", let cursor?): self = .after(cursor)
        default: return nil
        }
    }
}

/// One page of one session's conversation.
public struct TimelinePage: Codable, Equatable, Sendable {
    /// The tab this is about. Echoed back so a client with two fetches in flight can tell
    /// them apart without holding the request beside the `cid`.
    public var session: UUID
    /// In file order, oldest first, for every anchor — including `.before`, where the client
    /// asked for them backwards. Reversing at the reader means every client renders the same
    /// way and nobody has to remember which anchor produced which order.
    public var items: [TimelineItem]
    /// The offset of the first included record's line. Feed it back as `.before(start)` to
    /// page further up.
    public var start: Int
    /// The offset just past the last included record's line. Feed it back as `.after(end)` to
    /// pick up whatever has been appended since.
    public var end: Int
    /// Whether anything precedes `start`. False means the top of the transcript.
    public var hasMore: Bool
    /// The transcript this cursor came from is gone — it shrank, or was replaced. The client
    /// must **discard what it holds** and re-fetch `.latest`; item ids are byte offsets, so
    /// a replaced file makes every held id name a different record.
    ///
    /// The explicit signal is required, not an optimisation, for the same reason §4's
    /// re-snapshot is: silently serving from wherever the file happens to be now is how a
    /// phone ends up confidently displaying a conversation that no longer exists.
    public var reset: Bool

    public init(
        session: UUID, items: [TimelineItem], start: Int, end: Int,
        hasMore: Bool, reset: Bool
    ) {
        self.session = session
        self.items = items
        self.start = start
        self.end = end
        self.hasMore = hasMore
        self.reset = reset
    }

    enum CodingKeys: String, CodingKey { case session, items, start, end, hasMore, reset }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(session, forKey: .session)
        try c.encode(items, forKey: .items)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        if hasMore { try c.encode(hasMore, forKey: .hasMore) }
        if reset { try c.encode(reset, forKey: .reset) }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = try c.decode(UUID.self, forKey: .session)
        items = try c.decode([TimelineItem].self, forKey: .items)
        start = try c.decode(Int.self, forKey: .start)
        end = try c.decode(Int.self, forKey: .end)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        reset = try c.decodeIfPresent(Bool.self, forKey: .reset) ?? false
    }
}

/// Something the client asks the Mac to **tell** it.
///
/// Separate from `FleetCommand`, which asks the Mac to **do** something. The distinction is
/// load-bearing rather than tidy: a command's reply is `ack`, and `ack` means *dispatched,
/// not done* (spec §4) because typing into a pty has no delivery confirmation. That is the
/// right contract for `markRead` and a wrong one for a page, whose whole point is the data it
/// carries back. Two verbs, two reply shapes.
public enum FleetRequest: Codable, Equatable, Sendable {
    /// `limit` counts source **records**, not items — one record can carry several. Clamped
    /// to `TimelineLimits.maxLimit` by the reader rather than refused here.
    case timeline(session: UUID, anchor: TimelineAnchor, limit: Int)

    enum CodingKeys: String, CodingKey { case op, session, anchor, cursor, limit }

    private enum Op: String, Codable { case timeline = "timeline.page" }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .timeline(let session, let anchor, let limit):
            try c.encode(Op.timeline, forKey: .op)
            try c.encode(session, forKey: .session)
            try c.encode(anchor.name, forKey: .anchor)
            // `encodeIfPresent`: `.latest` genuinely has no cursor, and an explicit null
            // would invite a reader to treat it as offset 0 — the opposite end of the file.
            try c.encodeIfPresent(anchor.cursor, forKey: .cursor)
            try c.encode(limit, forKey: .limit)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .timeline:
            let name = try c.decode(String.self, forKey: .anchor)
            let cursor = try c.decodeIfPresent(Int.self, forKey: .cursor)
            guard let anchor = TimelineAnchor(name: name, cursor: cursor) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .anchor, in: c,
                    debugDescription: "unknown anchor \"\(name)\""
                        + (cursor == nil ? " (or a cursor was required and absent)" : "")
                )
            }
            self = .timeline(
                session: try c.decode(UUID.self, forKey: .session),
                anchor: anchor,
                limit: try c.decode(Int.self, forKey: .limit)
            )
        }
    }
}

/// Why a request did not produce a page.
public enum FleetRequestError: Error, Equatable, Sendable {
    /// The socket went away before the reply arrived. A client that does not surface this
    /// spins forever on a fetch that will never land.
    case disconnected
    /// The Mac answered `err`. Codes this plan produces: `unknown_session` (no such tab),
    /// `no_transcript` (the tab's agent reports no transcript file — a codex thread whose
    /// `thread/start` never returned a path), `unreadable` (a path that is not there yet, the
    /// ordinary state of a claude tab before its first turn), `stopped` (the service is gone).
    case server(code: String)
}
```

Then in `Sources/FleetKit/Frames.swift`, add the `req` case to `ClientFrame`:

```swift
    case hello(lastSeq: Int, device: String?)
    case cmd(cid: Int, FleetCommand)
    /// Ask, rather than tell. See `FleetRequest` for why this is not a `cmd`.
    case req(cid: Int, FleetRequest)
```

```swift
    private enum Tag: String, Codable { case hello, cmd, req }
```

in `encode(to:)`:

```swift
        case .req(let cid, let request):
            try c.encode(Tag.req, forKey: .t)
            try c.encode(cid, forKey: .cid)
            // Flattened into the same object, exactly as `cmd` flattens its command: two
            // keyed containers over one encoder merge into a single JSON object, and one
            // request reading as one line is what makes a packet dump usable.
            try request.encode(to: encoder)
```

in `init(from:)`:

```swift
        case .req:
            self = .req(cid: try c.decode(Int.self, forKey: .cid),
                        try FleetRequest(from: decoder))
```

And add `page` to `ServerFrame`:

```swift
    case ack(cid: Int)
    case err(cid: Int, code: String)
    /// The reply to `ClientFrame.req`. Correlated by `cid` and deliberately **not**
    /// sequenced: a history fetch is not fleet state, and giving it a `seq` would let a
    /// client paging back through an hour of transcript move the resume point it hands the
    /// Mac on its next `hello`.
    case page(cid: Int, TimelinePage)
```

```swift
    private enum Tag: String, Codable { case snapshot, ack, err, page }
```

in `encode(to:)`:

```swift
        case .page(let cid, let page):
            try c.encode(Tag.page, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(page, forKey: .page)
```

Add `page` to `ServerFrame.CodingKeys`:

```swift
    enum CodingKeys: String, CodingKey { case t, seq, fleet, reason, cid, code, page }
```

in `init(from:)`, inside the existing `if let tag` block:

```swift
            case .page:
                self = .page(cid: try c.decode(Int.self, forKey: .cid),
                             try c.decode(TimelinePage.self, forKey: .page))
```

Finally, in `Sources/FleetKit/FleetSocket.swift`, inside `webSocketParameters(_:)`:

```swift
        options.autoReplyPing = true
        // The SDK's default is 0 — "no receive limit" (`ws_options.h`). That was harmless
        // while every frame was a snapshot or a status delta; a page is bulk, so an
        // unbounded frame is now an unbounded allocation on a phone. Above a worst-case
        // page even after JSON escaping doubles it.
        options.maximumMessageSize = TimelineLimits.maximumMessageSize
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1224 tests, 0 failures.

- [ ] **Step 5: Prove `testAPageCarriesNoSequence` can fail**

Temporarily add a sequence to the page frame's encoder:

```swift
        case .page(let cid, let page):
            try c.encode(Tag.page, forKey: .t)
            try c.encode(cid, forKey: .cid)
            try c.encode(0, forKey: .seq)   // ← the mutation
            try c.encode(page, forKey: .page)
```

Run: `./scripts/test-unit.sh 2>&1 | grep -A3 testAPageCarriesNoSequence`
Expected: **FAIL** — `XCTAssertNil failed: "0" - a page is not a fleet event and must not be sequenced`. Revert and re-run to green.

- [ ] **Step 6: Prove `testTheWebSocketReceiveSizeIsBounded` can fail**

Temporarily comment out the `options.maximumMessageSize = …` line.

Run: `./scripts/test-unit.sh 2>&1 | grep -A3 testTheWebSocketReceiveSize`
Expected: **FAIL** — `XCTAssertEqual failed: ("0") is not equal to ("4194304")`. That `0` is the SDK default, and seeing it is the point: it is what "no receive limit" looks like. Restore and re-run to green.

- [ ] **Step 7: Verify the iOS boundary**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`
Expected: three successes.

- [ ] **Step 8: Commit**

```bash
git add Sources/FleetKit/TimelineFrames.swift Sources/FleetKit/Frames.swift \
        Sources/FleetKit/FleetSocket.swift \
        Tests/FlightDeckTests/TimelineFrameCodingTests.swift
git commit -m "feat: a cid-correlated request that answers with data, not an ack

History rides the fleet socket as spec §6 says it should, but not as a
FleetCommand: ack means dispatched-not-done, which is right for markRead
and wrong for a page, whose entire content is the reply. So req/page joins
cmd/ack in the same cid space with its own tag.

A page carries no seq, on purpose. Sequencing it would let a phone paging
back through an hour of transcript move the resume point it hands the Mac
on its next hello — a fetch that reads history would rewrite the client's
idea of how much fleet history it has seen.

Cursors are byte offsets at line boundaries, opaque to the client, which
only ever echoes back a start or an end it was given. TimelinePage.reset
is the file-level analogue of §4's re-snapshot: the transcript this cursor
came from is gone, discard and re-fetch.

Also sets maximumMessageSize. ws_options.h documents the default as 0 —
no receive limit at all — which stops being harmless the moment bulk goes
on this socket.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Claude's mapping

**Files:**
- Create: `Sources/FlightDeck/Agents/ClaudeTimelineMapper.swift`
- Create: `Tests/FlightDeckTests/Fixtures/Claude/transcript.captured.jsonl` (captured, see Step 1)
- Create: `Tests/FlightDeckTests/Fixtures/Claude/transcript.captured.provenance.json`
- Test: `Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift`
- Test: `Tests/FlightDeckTests/TimelineFixtureTests.swift`

**Interfaces:**
- Consumes: `TimelineItem`, `TimelineItem.Body`, `TimelineItem.identifier(offset:index:)` (Task 1).
- Produces: `ClaudeTimelineMapper.items(inLine: String, at offset: Int) -> [TimelineItem]`, `ToolInputSummary.text(for: [String: Any]) -> String?`, `ToolInputSummary.pretty(_: Any?) -> String`.

**Mapping table** — every rule below is checked against real records on this machine, not assumed:

| Transcript record | Emits |
|---|---|
| `type:"user"`, `message.content` a **String** | one `.userTurn` |
| `type:"user"`, block `type:"text"` | one `.userTurn` |
| `type:"user"`, block `type:"image"` | one `.userTurn` with body text `"[image]"` — **the base64 never leaves the Mac** |
| `type:"user"`, block `type:"tool_result"` | one `.toolResult`, `callID` = `tool_use_id`, `isError` = `is_error` |
| `type:"assistant"`, block `type:"text"` | one `.assistantText` |
| `type:"assistant"`, block `type:"thinking"` | one `.thinking` — **dropped when `thinking` is empty**, which is what a redacted block looks like (`{"type":"thinking","thinking":"","signature":"CAIS…"}`); `signature` is never carried |
| `type:"assistant"`, block `type:"tool_use"` | one `.toolCall`, `tool` = `name`, `callID` = `id`, text = pretty-printed `input` |
| `isMeta: true` | nothing — `"Continue from where you left off."` and the image-geometry note are claude talking to itself, not turns |
| `isSidechain: true` | nothing — sub-agent records belong in `<conversationId>/subagents/agent-*.jsonl`; one appearing here means claude moved them, and rendering it would interleave two conversations |
| `custom-title`, `system`, `attachment`, `mode`, `last-prompt`, everything else | nothing |

- [ ] **Step 1: Capture the fixture**

**Do not author this file.** `Fixtures/` is captured output; the rule in `Fixtures/Codex/rollout.captured.provenance.json` is that lines may be **dropped, never edited**, and every file must be named `*.captured.*`. Make a throwaway session whose content is inherently uninteresting, exactly as the codex rollout fixture was made:

```bash
cd /Users/nate/Projects/Protos-n-Tools/flight-deck/.claude/worktrees/fleet-pairing
CAP=$(mktemp -d)
SID=$(uuidgen | tr 'A-Z' 'a-z')
mkdir -p "$CAP/home"
# An isolated CLAUDE_CONFIG_DIR, so nothing of the user's own conversations can be captured.
CLAUDE_CONFIG_DIR="$CAP/home" claude --session-id "$SID" -p \
  'Reply with exactly the word: ok'
CLAUDE_CONFIG_DIR="$CAP/home" claude --resume "$SID" -p \
  'Run this exact shell command with the Bash tool and then say done: echo hi'
find "$CAP/home/projects" -name "$SID.jsonl"
```

Copy the resulting `.jsonl` verbatim to `Tests/FlightDeckTests/Fixtures/Claude/transcript.captured.jsonl`. Confirm before committing that it contains a `user` record with string content, an `assistant` record with a `text` block, an `assistant` record with a `tool_use` block, and a `user` record with a `tool_result` block — Step 6's fixture test asserts exactly that, so a capture missing one of them fails loudly rather than silently under-covering.

If `claude` cannot run headlessly here, **stop and report it**. Do not hand-write a substitute: an authored fixture records what somebody believed claude writes, and the entire value of this directory is that it records what claude actually wrote.

Write `Tests/FlightDeckTests/Fixtures/Claude/transcript.captured.provenance.json`:

```json
{
  "files": ["transcript.captured.jsonl"],
  "isVerbatimCapturedOutput": true,
  "capturedOn": "2026-08-21",
  "capturedBy": [
    "Two headless `claude -p` turns under a throwaway CLAUDE_CONFIG_DIR, so no line of this",
    "file comes from any real conversation. Turn one asks for a single word; turn two asks",
    "for one Bash call, which is what produces the tool_use / tool_result pair.",
    "Record `claude --version` output here when capturing."
  ],
  "editingRule": [
    "Lines may be DROPPED, never EDITED. Every surviving line is byte-for-byte what claude",
    "wrote.",
    "",
    "No schema for this format exists — the record shapes were established empirically (see",
    "docs/superpowers/specs/2026-08-10-session-name-sync-design.md §2 for the same method",
    "applied to `custom-title`). That makes this the same weak ground truth the codex",
    "captures are: it records what claude DID on one day, not what it DECLARES.",
    "",
    "Every fixture in Fixtures/ MUST be named *.captured.* to signal that it is verbatim",
    "captured output, not authored. Tests reference captures by their documented name; if a",
    "test cannot find its fixture, correct the lookup name in the test, never add an",
    "undocumented copy under another name."
  ]
}
```

- [ ] **Step 2: Write the failing test**

Create `Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift`. The lines here are **shape-accurate and hand-written**, deliberately: a unit test wants one record with one property under examination, and the captured fixture in Step 6 is what proves the shapes are real.

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Claude's half of the one vocabulary (spec §6). Pure, per line, from records whose shapes
/// were read off real transcripts on the build machine.
///
/// Three of these guard a rule whose violation is invisible rather than noisy — an image's
/// base64 going on the wire, a redacted thinking block rendering as a blank row, and a
/// sub-agent record interleaving into the main conversation. Each has a named mutation in
/// Step 4.
final class ClaudeTimelineMapperTests: XCTestCase {
    private func items(_ line: String, at offset: Int = 100) -> [TimelineItem] {
        ClaudeTimelineMapper.items(inLine: line, at: offset)
    }

    func testAUserRecordWithStringContentIsOneUserTurn() {
        let items = items("""
            {"type":"user","uuid":"u1","timestamp":"2026-08-21T10:00:00.000Z",\
            "isSidechain":false,"message":{"role":"user","content":"read project.yml"}}
            """)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].kind, .userTurn)
        XCTAssertEqual(items[0].body.text, "read project.yml")
        XCTAssertEqual(items[0].id, "100#0")
        XCTAssertEqual(items[0].at, "2026-08-21T10:00:00.000Z")
        XCTAssertEqual(items[0].status, .complete)
    }

    func testAnAssistantRecordSplitsIntoOneItemPerBlock() {
        let items = items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"thinking","thinking":"weighing it","signature":"CAIS7wYK"},\
            {"type":"text","text":"I'll read the file."},\
            {"type":"tool_use","id":"toolu_01A","name":"Bash",\
            "input":{"command":"sed -n '1,60p' project.yml","description":"Read it"}}]}}
            """)
        XCTAssertEqual(items.map(\.kind), [.thinking, .assistantText, .toolCall])
        XCTAssertEqual(items.map(\.id), ["100#0", "100#1", "100#2"],
                       "the block index is what makes several items from one line addressable")
        XCTAssertEqual(items[2].body.tool, "Bash")
        XCTAssertEqual(items[2].body.callID, "toolu_01A")
        XCTAssertEqual(items[2].body.summary, "sed -n '1,60p' project.yml",
                       "a row cannot render pretty-printed JSON; the command is the preview")
        XCTAssertTrue(items[2].body.text.contains("\"command\""),
                      "the detail screen still gets the whole input")
    }

    /// A `signature` is a several-hundred-byte opaque blob and is not thinking. It must never
    /// reach a phone.
    func testAThinkingBlocksSignatureIsNeverCarried() {
        let items = items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"thinking","thinking":"weighing it","signature":"CAIS7wYKowEIERgC"}]}}
            """)
        XCTAssertEqual(items[0].body.text, "weighing it")
        XCTAssertFalse(items[0].body.text.contains("CAIS"))
    }

    /// A redacted thinking block is `{"thinking":"","signature":"…"}`, and there are hundreds
    /// of them in a long conversation. Emitting them puts an empty row on screen for each.
    func testARedactedThinkingBlockEmitsNothing() {
        XCTAssertTrue(items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"thinking","thinking":"","signature":"CAIS7wYKowEIERgC"}]}}
            """).isEmpty)
    }

    func testAToolResultCarriesTheCallItAnswers() {
        let items = items("""
            {"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":\
            [{"tool_use_id":"toolu_01A","type":"tool_result","content":"name: FlightDeck\\n",\
            "is_error":false}]}}
            """)
        XCTAssertEqual(items.map(\.kind), [.toolResult])
        XCTAssertEqual(items[0].body.callID, "toolu_01A")
        XCTAssertEqual(items[0].body.text, "name: FlightDeck\n")
        XCTAssertFalse(items[0].body.isError)
    }

    func testAFailedToolResultSaysSo() {
        let items = items("""
            {"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":\
            [{"tool_use_id":"toolu_01A","type":"tool_result","content":"No such file",\
            "is_error":true}]}}
            """)
        XCTAssertTrue(items[0].body.isError)
    }

    /// A tool result's `content` is a String on most tools and a block array on some. Both are
    /// real; a mapper that handles only the first silently drops the second's output.
    func testAToolResultWithBlockContentIsFlattened() {
        let items = items("""
            {"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":\
            [{"tool_use_id":"toolu_01A","type":"tool_result",\
            "content":[{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}]}}
            """)
        XCTAssertEqual(items[0].body.text, "line one\nline two")
    }

    /// **The base64 never leaves the Mac.** A pasted screenshot is roughly a megabyte of it in
    /// one block; a page of forty records containing two of them is a multi-megabyte frame
    /// over a cellular link, to render a picture the phone is not going to draw anyway.
    func testAnImageBlockIsReplacedRatherThanCarried() {
        let items = items("""
            {"type":"user","uuid":"u2","isSidechain":false,"message":{"role":"user","content":\
            [{"type":"text","text":"[Image #1] look at this"},\
            {"type":"image","source":{"type":"base64","media_type":"image/png",\
            "data":"iVBORw0KGgoAAAANSUhEUgAAA"}}]}}
            """)
        XCTAssertEqual(items.map(\.body.text), ["[Image #1] look at this", "[image]"])
        XCTAssertFalse(items.contains { $0.body.text.contains("iVBORw0") })
    }

    /// `isMeta` records are claude talking to itself — "Continue from where you left off.",
    /// the image-geometry note. Rendering them as user turns puts words in the user's mouth.
    func testAMetaRecordIsNotAUserTurn() {
        XCTAssertTrue(items("""
            {"type":"user","uuid":"u3","isMeta":true,"isSidechain":false,"message":\
            {"role":"user","content":[{"type":"text","text":"Continue from where you left off."}]}}
            """).isEmpty)
    }

    /// Sub-agent records live in `<conversationId>/subagents/agent-*.jsonl`, which nothing
    /// reads. One appearing in the main transcript means claude changed where it writes them,
    /// and mapping it would interleave a sub-agent's conversation into its parent's.
    func testASidechainRecordIsNotMapped() {
        XCTAssertTrue(items("""
            {"type":"assistant","uuid":"a9","isSidechain":true,"message":{"role":"assistant",\
            "content":[{"type":"text","text":"sub-agent speaking"}]}}
            """).isEmpty)
    }

    func testRecordsThisVocabularyHasNoRowForEmitNothing() {
        for line in [
            #"{"type":"custom-title","customTitle":"x","sessionId":"s"}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":1}"#,
            #"{"type":"mode","mode":"default"}"#,
            #"{"type":"attachment","id":"1"}"#,
            "not json at all",
            "",
        ] {
            XCTAssertTrue(items(line).isEmpty, "\(line.prefix(30)) should map to nothing")
        }
    }

    /// Nothing streams. Both agents are read from files they write, and neither writes token
    /// deltas — see the plan's findings §2. `.streaming` exists in the vocabulary for a future
    /// route; if something starts emitting it, this fails and the UI has to be built for it.
    func testEveryMappedItemIsComplete() {
        let items = items("""
            {"type":"assistant","uuid":"a1","isSidechain":false,"message":{"role":"assistant",\
            "content":[{"type":"text","text":"hi"},{"type":"tool_use","id":"t","name":"Bash",\
            "input":{"command":"ls"}}]}}
            """)
        XCTAssertFalse(items.isEmpty)
        XCTAssertTrue(items.allSatisfy { $0.status == .complete })
    }
}
```

- [ ] **Step 3: Write the implementation**

Create `Sources/FlightDeck/Agents/ClaudeTimelineMapper.swift`:

```swift
import FleetKit
import Foundation

/// Turns one line of a claude transcript into timeline rows.
///
/// Pure and static so every mapping is testable from a captured line with no process, no
/// socket and no timing — the same reason `ClaudeSession.events(inLine:sessionID:)` and
/// `CodexEventMapper.events(inRolloutLine:)` are.
///
/// **Why this is a second parser and not an extension of `TranscriptWatcher`.** Spec §6 asks
/// claude's mapping to extend the existing watcher path rather than add a second reader.
/// `TranscriptWatcher` is a forward-only tail — one `offset`, never seeking backwards — and
/// backwards pagination over an arbitrary byte range is not something a tail can do. What §6
/// is protecting against is two parses of the same file disagreeing, and that is prevented
/// structurally instead: this is the only place a transcript line is read as *content*, there
/// is still exactly one poll loop per tab, and nothing here touches the watcher's title or
/// sub-agent state. See the plan's findings §4.
///
/// **Two rules here are about what must NOT go on the wire**, and both are silent when
/// broken: a pasted screenshot's base64 (roughly a megabyte per block) and a thinking block's
/// `signature` (a few hundred opaque bytes per block, hundreds of blocks per conversation).
enum ClaudeTimelineMapper {
    /// `offset` is the byte offset of this line in the transcript, and it is what makes an
    /// item addressable — see `TimelineItem.id`.
    static func items(inLine line: String, at offset: Int) -> [TimelineItem] {
        guard let data = line.data(using: .utf8),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = record["type"] as? String
        else { return [] }

        // Claude talking to itself: "Continue from where you left off.", the image-geometry
        // note that accompanies a paste. Rendering these as user turns puts words in the
        // user's mouth.
        guard record["isMeta"] as? Bool != true else { return [] }
        // Sub-agent records belong in `<conversationId>/subagents/agent-*.jsonl`, which
        // nothing reads. One in the main transcript means claude moved them, and mapping it
        // would interleave a sub-agent's conversation into its parent's.
        guard record["isSidechain"] as? Bool != true else { return [] }

        let at = record["timestamp"] as? String
        guard let message = record["message"] as? [String: Any] else { return [] }

        switch type {
        case "user":
            if let text = message["content"] as? String {
                return [
                    TimelineItem(
                        id: TimelineItem.identifier(offset: offset, index: 0),
                        kind: .userTurn, status: .complete,
                        body: TimelineItem.Body(text: text), at: at
                    )
                ]
            }
            return blocks(message).enumerated().compactMap { index, block in
                userItem(block, offset: offset, index: index, at: at)
            }
        case "assistant":
            return blocks(message).enumerated().compactMap { index, block in
                assistantItem(block, offset: offset, index: index, at: at)
            }
        default:
            return []
        }
    }

    private static func blocks(_ message: [String: Any]) -> [[String: Any]] {
        message["content"] as? [[String: Any]] ?? []
    }

    private static func userItem(
        _ block: [String: Any], offset: Int, index: Int, at: String?
    ) -> TimelineItem? {
        let id = TimelineItem.identifier(offset: offset, index: index)
        switch block["type"] as? String {
        case "text":
            guard let text = block["text"] as? String, !text.isEmpty else { return nil }
            return TimelineItem(id: id, kind: .userTurn, status: .complete,
                                body: TimelineItem.Body(text: text), at: at)
        case "image":
            // A placeholder, never the payload. One pasted screenshot is about a megabyte of
            // base64; two in a page is a multi-megabyte frame over a possibly-cellular link,
            // to carry a picture the phone does not draw.
            return TimelineItem(id: id, kind: .userTurn, status: .complete,
                                body: TimelineItem.Body(text: "[image]"), at: at)
        case "tool_result":
            return TimelineItem(
                id: id, kind: .toolResult, status: .complete,
                body: TimelineItem.Body(
                    text: resultText(block["content"]),
                    callID: block["tool_use_id"] as? String,
                    isError: block["is_error"] as? Bool == true
                ),
                at: at
            )
        default:
            return nil
        }
    }

    private static func assistantItem(
        _ block: [String: Any], offset: Int, index: Int, at: String?
    ) -> TimelineItem? {
        let id = TimelineItem.identifier(offset: offset, index: index)
        switch block["type"] as? String {
        case "text":
            guard let text = block["text"] as? String, !text.isEmpty else { return nil }
            return TimelineItem(id: id, kind: .assistantText, status: .complete,
                                body: TimelineItem.Body(text: text), at: at)
        case "thinking":
            // `signature` is deliberately not read. An empty `thinking` with a signature is
            // what a redacted block looks like, and there are hundreds of them in a long
            // conversation — emitting each as a blank row is the failure this guard prevents.
            guard let text = block["thinking"] as? String, !text.isEmpty else { return nil }
            return TimelineItem(id: id, kind: .thinking, status: .complete,
                                body: TimelineItem.Body(text: text), at: at)
        case "tool_use":
            let input = block["input"] as? [String: Any]
            return TimelineItem(
                id: id, kind: .toolCall, status: .complete,
                body: TimelineItem.Body(
                    text: ToolInputSummary.pretty(input),
                    summary: input.flatMap(ToolInputSummary.text(for:)),
                    tool: block["name"] as? String,
                    callID: block["id"] as? String
                ),
                at: at
            )
        default:
            return nil
        }
    }

    /// A tool result's `content` is a String for most tools and a block array for some. Both
    /// shapes are real; handling only the first silently drops the second's whole output.
    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
}

/// Shared by both mappers, because a tool call looks the same on a phone whichever agent made
/// it: a name, a one-line preview, and the whole input a tap away.
enum ToolInputSummary {
    /// The keys a preview is drawn from, most specific first. A table rather than "the first
    /// String value", which would pick whichever key the JSON happened to order first and
    /// give a `Bash` row its `description` on one call and its `command` on the next.
    private static let previewKeys = [
        "command", "file_path", "path", "pattern", "query", "url", "prompt", "description",
    ]

    /// A one-line row preview, or nil when nothing in the input makes one. Nil is fine: the
    /// row still has `Body.tool` to render.
    static func text(for input: [String: Any]) -> String? {
        for key in previewKeys {
            guard let value = input[key] as? String else { continue }
            let line = value.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? value
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// The whole input, for the detail screen. `sortedKeys` so the same call renders the same
    /// way every time it is fetched — an unstable key order would make a re-fetched page look
    /// like a changed one to anything comparing bodies.
    static func pretty(_ input: Any?) -> String {
        guard let input,
              JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(
                  withJSONObject: input, options: [.prettyPrinted, .sortedKeys]
              )
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run the tests, then prove three of them can fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

Then, one at a time — apply the mutation, run only the named test, confirm the failure, revert:

| Test | Mutation | Expected failure |
|---|---|---|
| `testAnImageBlockIsReplacedRatherThanCarried` | in the `"image"` arm, return the payload: `text: (block["source"] as? [String: Any])?["data"] as? String ?? ""` | `XCTAssertEqual failed: ("["[Image #1] look at this", "iVBORw0KGgoAAAANSUhEUgAAA"]")` |
| `testARedactedThinkingBlockEmitsNothing` | drop `, !text.isEmpty` from the `"thinking"` guard | `XCTAssertTrue failed` — one empty row emitted |
| `testASidechainRecordIsNotMapped` | delete the `isSidechain` guard | `XCTAssertTrue failed` — the sub-agent's text is mapped |

Record all three outcomes in the task report. A mutation that does **not** fail its test means the test is not guarding what it claims and must be fixed before this task is done — that is this branch's standing bar and the reason it exists.

- [ ] **Step 5: Run the whole suite and the iOS build**

Run: `./scripts/test-unit.sh 2>&1 | tail -20` then `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`
Expected: PASS, 1237 tests; three iOS successes.

- [ ] **Step 6: Add the fixture guard**

Create `Tests/FlightDeckTests/TimelineFixtureTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Guards the timeline fixtures themselves, and what they must contain.
///
/// Two jobs. `Fixtures/` is a folder reference copied as resources, so a file that fails to
/// land in the bundle otherwise produces a confusing nil at its first use site rather than an
/// error here — the same reason `CodexRolloutFixtureTests` exists. And a capture that came
/// out missing a record shape would silently under-cover the mapper, so the composition is
/// asserted rather than assumed.
final class TimelineFixtureTests: XCTestCase {
    static func lines(_ name: String, in directory: String) throws -> [String] {
        let url = try XCTUnwrap(
            Bundle(for: TimelineFixtureTests.self).url(
                forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/\(directory)"
            ),
            "Fixtures/\(directory)/\(name).jsonl not found in the test bundle"
        )
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func mapped(_ lines: [String]) -> [TimelineItem] {
        var offset = 0
        var items: [TimelineItem] = []
        for line in lines {
            items += ClaudeTimelineMapper.items(inLine: line, at: offset)
            offset += line.utf8.count + 1
        }
        return items
    }

    func testTheCapturedClaudeTranscriptExercisesEveryKindThisMapperEmits() throws {
        let kinds = Set(mapped(try Self.lines("transcript.captured", in: "Claude")).map(\.kind))
        XCTAssertEqual(kinds, [.userTurn, .assistantText, .toolCall, .toolResult],
                       "the capture must contain a prompt, a reply, a tool call and its "
                       + "result; recapture per the plan's Task 3 Step 1 if it does not. "
                       + "(.thinking is absent on purpose — a two-turn -p session produces "
                       + "no unredacted thinking, and the unit tests cover it.)")
    }

    func testEveryItemFromTheCapturedTranscriptHasAUniqueId() throws {
        let ids = mapped(try Self.lines("transcript.captured", in: "Claude")).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "ids are offset#index; a collision means the offset arithmetic is wrong "
                       + "and a client would drop rows as duplicates")
    }

    /// The whole point of the fixture being captured rather than authored.
    func testNoCapturedLineWasEdited() throws {
        for line in try Self.lines("transcript.captured", in: "Claude") {
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: Data(line.utf8)),
                "a line that no longer parses was edited: \(line.prefix(60))"
            )
        }
    }
}
```

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1240 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudeTimelineMapper.swift \
        Tests/FlightDeckTests/ClaudeTimelineMapperTests.swift \
        Tests/FlightDeckTests/TimelineFixtureTests.swift \
        Tests/FlightDeckTests/Fixtures/Claude
git commit -m "feat: read a claude transcript as conversation, not just as a title

The transcript already carries everything a timeline needs (spec §1.3);
this is the table that turns it into TimelineItems. One parser, per line,
pure — the same shape ClaudeSession.events and CodexEventMapper already
have, and testable from a captured line with no process and no timing.

Two of the rules are about what must NOT go on the wire, and both fail
silently rather than loudly. A pasted screenshot is about a megabyte of
base64 per block, so an image becomes the string [image] and the payload
never leaves the Mac. And a thinking block's signature is a few hundred
opaque bytes that are not thinking, while an EMPTY thinking with a
signature is what a redacted block looks like — hundreds per long
conversation, each of which would have rendered as a blank row.

isMeta records are claude talking to itself and are not user turns.
isSidechain records belong in the subagents/ directory nothing reads;
one here would interleave two conversations.

This is a second reader over the transcript, which §6 asked to avoid.
It is unavoidable — a forward-only tail cannot page backwards — and what
§6 was protecting against is prevented structurally instead: one parser,
one poll loop per tab, and nothing here touching the watcher's state.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Codex's mapping

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexTimelineMapper.swift`
- Create: `Tests/FlightDeckTests/Fixtures/Codex/rollout-content.captured.jsonl` (captured, see Step 1)
- Modify: `Tests/FlightDeckTests/Fixtures/Codex/rollout.captured.provenance.json` (add the new file to `files` and a line to `capturedBy`)
- Modify: `Tests/FlightDeckTests/TimelineFixtureTests.swift` (add the codex cases)
- Test: `Tests/FlightDeckTests/CodexTimelineMapperTests.swift`

**Interfaces:**
- Consumes: `TimelineItem`, `ToolInputSummary` (Tasks 1, 3).
- Produces: `CodexTimelineMapper.items(inRolloutLine: String, at offset: Int) -> [TimelineItem]`.

**Read the plan's findings §1 before starting.** §6 says codex maps from `item/started` / `item/completed`. Those are app-server notifications, and that path was **deleted** in `b76a07b` because its notifications only ever reach the connection that made the change — never the `codex resume` TUI where Flight Deck's turns actually run. `rg 'item/' Sources/` returns nothing. The source is the rollout `.jsonl`, exactly as `CodexRolloutWatcher` already reads it.

**Mapping table** — every rule checked against 494 real rollouts on this machine:

| Rollout record | Emits | Why this family and not the other |
|---|---|---|
| `event_msg` / `user_message` → `message` | `.userTurn` | The `response_item` / `message` with `role:"user"` is **not** a user turn: it carries the AGENTS.md instruction blob and the environment context, tens of KB of it, on every turn. |
| `event_msg` / `agent_message` → `message` | `.assistantText` | Same prose as `response_item` / `message` with `role:"assistant"`; taking one family for prose is what keeps every reply from appearing twice. |
| `event_msg` / `agent_reasoning` → `text` | `.thinking` | The **only** renderable reasoning codex writes. `response_item` / `reasoning` carries `summary: []` and an `encrypted_content` blob — unrenderable, and it must never go on the wire. |
| `response_item` / `function_call` | `.toolCall`, `tool` = `name`, `callID` = `call_id`, text = `arguments` parsed then pretty-printed | `event_msg` covers only *some* calls (`mcp_tool_call_end`, `patch_apply_end`, `web_search_end`) and never the call itself. |
| `response_item` / `custom_tool_call` | `.toolCall`, text = `input` verbatim | `apply_patch` arrives here, and its `input` is a patch, not JSON. |
| `response_item` / `function_call_output` | `.toolResult`, `callID` = `call_id` | |
| `response_item` / `custom_tool_call_output` | `.toolResult` | |
| `response_item` / `message`, `reasoning`, `web_search_call`, `tool_search_*`; `event_msg` / `task_started`, `task_complete`, `token_count`, `mcp_tool_call_end`, `patch_apply_end`, `web_search_end`, `thread_settings_applied`; `session_meta`, `turn_context`, `world_state`, `compacted` | nothing | Duplicates of something already mapped, bookkeeping, or unrenderable. |

- [ ] **Step 1: Capture the fixture**

The existing `rollout.captured.jsonl` was filtered to `session_meta` and `event_msg` only, so it contains **no `response_item` records at all** and cannot exercise the tool-call half of the table. Capture a second file that keeps them, the same way and under the same rules:

```bash
cd /Users/nate/Projects/Protos-n-Tools/flight-deck/.claude/worktrees/fleet-pairing
CAP=$(mktemp -d)
CODEX_HOME="$CAP/home" codex exec --skip-git-repo-check \
  'Run the shell command: echo hi. Then reply with exactly the word: done'
find "$CAP/home/sessions" -name 'rollout-*.jsonl'
```

Copy the rollout verbatim to `Tests/FlightDeckTests/Fixtures/Codex/rollout-content.captured.jsonl`. Confirm before committing that it contains at least one `event_msg`/`user_message`, one `event_msg`/`agent_message`, one `response_item`/`function_call` and one `response_item`/`function_call_output` — Step 5's fixture test asserts it.

Lines may be **dropped, never edited**. If the capture carries an absolute path or a directory name that should not be in the repo, drop the whole line; do not rewrite it.

Add to `Fixtures/Codex/rollout.captured.provenance.json`:

```json
  "files": [
    "rollout.captured.jsonl",
    "rollout-content.captured.jsonl",
    "turn-aborted.captured.jsonl",
    "session-index.captured.jsonl"
  ],
```

and append to `capturedBy`:

```json
    "rollout-content.captured.jsonl is a second rollout, captured 2026-08-21 from one `codex",
    "exec` turn under a throwaway CODEX_HOME, and NOT filtered to event_msg: it keeps the",
    "response_item records the timeline mapper reads and rollout.captured.jsonl has none of."
```

If `codex exec` cannot run here, **stop and report it.** Do not author a substitute.

- [ ] **Step 2: Write the failing test**

Create `Tests/FlightDeckTests/CodexTimelineMapperTests.swift`. The lines are verbatim record shapes read off real rollouts, with long strings shortened.

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Codex's half of the one vocabulary (spec §6), mapped from the ROLLOUT rather than from
/// `item/started` / `item/completed`.
///
/// Spec §6 names the app-server notifications; that path was deleted in b76a07b because its
/// notifications only reach the connection that made the change, and Flight Deck's turns run
/// in a separate `codex resume` process. The rollout is written by whoever drives the turn.
/// See the plan's findings §1.
///
/// The subtle rule here is which record FAMILY each row comes from. Prose comes from
/// `event_msg` and tool calls from `response_item`, and taking both families for either would
/// double every reply or paste the AGENTS.md instruction blob in as a user turn. Three tests
/// below guard exactly that, with named mutations in Step 4.
final class CodexTimelineMapperTests: XCTestCase {
    private func items(_ line: String, at offset: Int = 200) -> [TimelineItem] {
        CodexTimelineMapper.items(inRolloutLine: line, at: offset)
    }

    func testAUserMessageEventIsAUserTurn() {
        let items = items("""
            {"timestamp":"2026-08-19T16:47:57.520Z","type":"event_msg","payload":\
            {"type":"user_message","message":"Reply with exactly the word: ok",\
            "images":[],"local_images":[],"audio":[],"local_audio":[],"text_elements":[]}}
            """)
        XCTAssertEqual(items.map(\.kind), [.userTurn])
        XCTAssertEqual(items[0].body.text, "Reply with exactly the word: ok")
        XCTAssertEqual(items[0].id, "200#0")
        XCTAssertEqual(items[0].at, "2026-08-19T16:47:57.520Z")
        XCTAssertEqual(items[0].status, .complete)
    }

    func testAnAgentMessageEventIsAssistantText() {
        let items = items("""
            {"timestamp":"2026-08-19T16:47:59.159Z","type":"event_msg","payload":\
            {"type":"agent_message","message":"ok","phase":"final_answer","memory_citation":null}}
            """)
        XCTAssertEqual(items.map(\.kind), [.assistantText])
        XCTAssertEqual(items[0].body.text, "ok")
    }

    /// **The prose family is `event_msg`, and only `event_msg`.** Codex writes the same reply
    /// twice — once as an event and once as a `response_item` — so mapping both puts every
    /// assistant message on screen twice.
    func testAResponseItemMessageIsNotMappedAsProse() {
        XCTAssertTrue(items("""
            {"timestamp":"2026-06-09T14:48:06.003Z","type":"response_item","payload":\
            {"type":"message","role":"assistant","content":[{"type":"output_text",\
            "text":"I'll look for the project's tooling first."}],"phase":"commentary"}}
            """).isEmpty, "agent_message already carried this; mapping both duplicates it")
    }

    /// A `response_item` / `message` with `role:"user"` is codex's *prompt assembly* — the
    /// AGENTS.md instruction blob, the environment context — tens of kilobytes of it, on
    /// every single turn. It is not something the user said.
    func testTheInstructionBlobIsNotAUserTurn() {
        XCTAssertTrue(items("""
            {"timestamp":"2026-06-09T14:48:00.429Z","type":"response_item","payload":\
            {"type":"message","role":"user","content":[{"type":"input_text",\
            "text":"# AGENTS.md instructions for /Users/x\\n<INSTRUCTIONS>…"}]}}
            """).isEmpty)
    }

    func testAgentReasoningIsThinking() {
        let items = items("""
            {"timestamp":"2025-10-14T16:38:51.503Z","type":"event_msg","payload":\
            {"type":"agent_reasoning","text":"**Verifying command execution permissions**"}}
            """)
        XCTAssertEqual(items.map(\.kind), [.thinking])
        XCTAssertEqual(items[0].body.text, "**Verifying command execution permissions**")
    }

    /// `response_item` / `reasoning` carries `summary: []` and a multi-kilobyte
    /// `encrypted_content` blob. There is nothing renderable in it, and shipping the
    /// ciphertext would be several kilobytes per turn of unreadable payload.
    func testEncryptedReasoningIsNeverCarried() {
        let items = items("""
            {"timestamp":"2026-06-09T14:48:05.224Z","type":"response_item","payload":\
            {"type":"reasoning","summary":[],"encrypted_content":"gAAAAABqKCelFjUA_JsDN0w0"}}
            """)
        XCTAssertTrue(items.isEmpty)
    }

    /// `arguments` is a JSON **string**, not an object — the one shape difference from
    /// claude's `input` that a shared mapper has to know about.
    func testAFunctionCallParsesItsArgumentsString() {
        let items = items("""
            {"timestamp":"2026-06-09T14:48:08.898Z","type":"response_item","payload":\
            {"type":"function_call","name":"qartez_map","namespace":"mcp__qartez",\
            "arguments":"{\\"top_n\\":20,\\"format\\":\\"concise\\"}",\
            "call_id":"call_AejD3fggPArahE3Bb78ykVbb"}}
            """)
        XCTAssertEqual(items.map(\.kind), [.toolCall])
        XCTAssertEqual(items[0].body.tool, "qartez_map")
        XCTAssertEqual(items[0].body.callID, "call_AejD3fggPArahE3Bb78ykVbb")
        XCTAssertTrue(items[0].body.text.contains("\"top_n\" : 20"),
                      "the arguments string is parsed and pretty-printed, not passed through "
                      + "as one escaped line")
    }

    /// Not every `arguments` is JSON. One that is not must render as itself rather than as an
    /// empty body.
    func testAFunctionCallWithNonJSONArgumentsKeepsThemVerbatim() {
        let items = items("""
            {"type":"response_item","payload":{"type":"function_call","name":"shell",\
            "arguments":"echo hi","call_id":"call_1"}}
            """)
        XCTAssertEqual(items[0].body.text, "echo hi")
    }

    func testAFunctionCallOutputIsAToolResult() {
        let items = items("""
            {"type":"response_item","payload":{"type":"function_call_output",\
            "call_id":"call_AejD3fggPArahE3Bb78ykVbb","output":"Wall time: 0.02s\\nOutput:\\nhi"}}
            """)
        XCTAssertEqual(items.map(\.kind), [.toolResult])
        XCTAssertEqual(items[0].body.callID, "call_AejD3fggPArahE3Bb78ykVbb")
        XCTAssertEqual(items[0].body.text, "Wall time: 0.02s\nOutput:\nhi")
    }

    /// `apply_patch` arrives as a `custom_tool_call` whose `input` is a patch, not JSON. A
    /// mapper that assumed JSON here would render every edit as an empty row.
    func testACustomToolCallCarriesItsInputVerbatim() {
        let items = items("""
            {"type":"response_item","payload":{"type":"custom_tool_call","status":"completed",\
            "call_id":"call_EDyk","name":"apply_patch",\
            "input":"*** Begin Patch\\n*** Add File: docs/x.md\\n+hello\\n"}}
            """)
        XCTAssertEqual(items.map(\.kind), [.toolCall])
        XCTAssertEqual(items[0].body.tool, "apply_patch")
        XCTAssertTrue(items[0].body.text.hasPrefix("*** Begin Patch"))
        XCTAssertEqual(items[0].body.summary, "*** Begin Patch",
                       "the first line is the preview when the input is not JSON")
    }

    func testACustomToolCallOutputIsAToolResult() {
        let items = items("""
            {"type":"response_item","payload":{"type":"custom_tool_call_output",\
            "call_id":"call_EDyk","output":"Exit code: 0\\nSuccess."}}
            """)
        XCTAssertEqual(items.map(\.kind), [.toolResult])
        XCTAssertEqual(items[0].body.callID, "call_EDyk")
    }

    /// Bookkeeping, duplicates, and records with no row. `mcp_tool_call_end` in particular
    /// carries a full tool result and is skipped anyway: `function_call_output` already
    /// carried it, and mapping both would double every MCP call's output.
    func testBookkeepingAndDuplicateRecordsEmitNothing() {
        for line in [
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t","last_agent_message":"ok"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
            #"{"type":"event_msg","payload":{"type":"thread_settings_applied"}}"#,
            #"{"type":"event_msg","payload":{"type":"mcp_tool_call_end","call_id":"c","result":{"Ok":{}}}}"#,
            #"{"type":"event_msg","payload":{"type":"patch_apply_end","call_id":"c","success":true}}"#,
            #"{"type":"event_msg","payload":{"type":"web_search_end","call_id":"c","query":"x"}}"#,
            #"{"type":"response_item","payload":{"type":"web_search_call","status":"completed"}}"#,
            #"{"type":"session_meta","payload":{"id":"x"}}"#,
            #"{"type":"turn_context","payload":{}}"#,
            "not json at all",
        ] {
            XCTAssertTrue(items(line).isEmpty, "\(line.prefix(40)) should map to nothing")
        }
    }

    /// The plan's findings §2: a survey of 494 rollouts on the build machine found zero
    /// `*delta*` records. Codex does not stream through this path, so nothing here is ever
    /// `.streaming`.
    func testEveryMappedItemIsComplete() {
        let items = items("""
            {"type":"event_msg","payload":{"type":"agent_message","message":"ok",\
            "phase":"final_answer"}}
            """)
        XCTAssertEqual(items.map(\.status), [.complete])
    }
}
```

- [ ] **Step 3: Write the implementation**

Create `Sources/FlightDeck/Agents/Codex/CodexTimelineMapper.swift`:

```swift
import FleetKit
import Foundation

/// Turns one line of a codex rollout `.jsonl` into timeline rows.
///
/// Pure and static, exactly like `CodexEventMapper` beside it and `ClaudeTimelineMapper` in
/// the sibling directory.
///
/// **The source is the rollout, not the app-server.** Spec §6 names `item/started` /
/// `item/completed`; those are app-server notifications, and that path was deleted in
/// b76a07b — the notifications only ever reach the connection that made the change, and
/// Flight Deck runs turns in a separate `codex resume` process. `CodexRolloutWatcher` reads
/// this same file for turn boundaries; this reads it for content.
///
/// **The rule that is easy to get wrong is which record FAMILY a row comes from.** Codex
/// writes the same conversation twice, in two shapes:
///
/// - `event_msg` records are the *conversation* — one `user_message` per prompt, one
///   `agent_message` per reply, `agent_reasoning` for renderable thinking.
/// - `response_item` records are the *model transcript* — every tool call and output, plus a
///   second copy of the prose, plus a `role:"user"` message that is not a user turn at all
///   but the assembled prompt (AGENTS.md, environment context: tens of KB, every turn), plus
///   a `reasoning` record whose content is encrypted.
///
/// So: **prose from `event_msg`, tools from `response_item`, nothing from either family's
/// duplicate of the other's job.** Mapping both families for prose doubles every reply;
/// mapping `response_item` / `message` as a user turn pastes an instruction blob into the
/// conversation.
enum CodexTimelineMapper {
    static func items(inRolloutLine line: String, at offset: Int) -> [TimelineItem] {
        guard let raw = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
              let record = raw as? [String: Any],
              let payload = record["payload"] as? [String: Any],
              let kind = payload["type"] as? String
        else { return [] }

        let at = record["timestamp"] as? String
        let id = TimelineItem.identifier(offset: offset, index: 0)

        switch (record["type"] as? String, kind) {
        case ("event_msg", "user_message"):
            guard let text = payload["message"] as? String, !text.isEmpty else { return [] }
            return [item(id, .userTurn, TimelineItem.Body(text: text), at)]

        case ("event_msg", "agent_message"):
            guard let text = payload["message"] as? String, !text.isEmpty else { return [] }
            return [item(id, .assistantText, TimelineItem.Body(text: text), at)]

        case ("event_msg", "agent_reasoning"):
            // The only renderable reasoning codex writes. `response_item`/`reasoning` is
            // `summary: []` plus an `encrypted_content` blob — nothing to show, and several
            // kilobytes of ciphertext per turn if it were carried anyway.
            guard let text = payload["text"] as? String, !text.isEmpty else { return [] }
            return [item(id, .thinking, TimelineItem.Body(text: text), at)]

        case ("response_item", "function_call"):
            // `arguments` is a JSON **string**, not an object — the one shape difference from
            // claude's `input`. Parsed so the detail screen shows structure rather than one
            // escaped line, and kept verbatim when it is not JSON (a `shell` call is not).
            let decoded = decodedArguments(payload["arguments"])
            return [
                item(id, .toolCall, TimelineItem.Body(
                    text: decoded.text,
                    summary: decoded.summary,
                    tool: payload["name"] as? String,
                    callID: payload["call_id"] as? String
                ), at)
            ]

        case ("response_item", "custom_tool_call"):
            // `apply_patch` lives here and its `input` is a patch, not JSON. Verbatim.
            let input = payload["input"] as? String ?? ""
            return [
                item(id, .toolCall, TimelineItem.Body(
                    text: input,
                    summary: firstLine(input),
                    tool: payload["name"] as? String,
                    callID: payload["call_id"] as? String
                ), at)
            ]

        case ("response_item", "function_call_output"),
             ("response_item", "custom_tool_call_output"):
            return [
                item(id, .toolResult, TimelineItem.Body(
                    text: payload["output"] as? String ?? "",
                    callID: payload["call_id"] as? String
                ), at)
            ]

        default:
            // Everything else is bookkeeping (`token_count`, `turn_context`, `session_meta`),
            // a turn boundary `CodexEventMapper` already owns (`task_started`,
            // `task_complete`), or the other family's duplicate of a row already emitted
            // above — `mcp_tool_call_end` and `patch_apply_end` both carry a full tool result
            // that `function_call_output` has already supplied.
            return []
        }
    }

    private static func item(
        _ id: String, _ kind: TimelineItem.Kind, _ body: TimelineItem.Body, _ at: String?
    ) -> TimelineItem {
        TimelineItem(id: id, kind: kind, status: .complete, body: body, at: at)
    }

    private static func decodedArguments(_ raw: Any?) -> (text: String, summary: String?) {
        guard let text = raw as? String else { return ("", nil) }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (text, firstLine(text)) }
        return (ToolInputSummary.pretty(object), ToolInputSummary.text(for: object))
    }

    private static func firstLine(_ text: String) -> String? {
        let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

- [ ] **Step 4: Run the tests, then prove three of them can fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS.

Then one at a time — mutate, run the named test, confirm, revert:

| Test | Mutation | Expected failure |
|---|---|---|
| `testAResponseItemMessageIsNotMappedAsProse` | add a `case ("response_item", "message")` arm mapping `content[].text` to `.assistantText` | `XCTAssertTrue failed` — the reply is emitted a second time |
| `testEncryptedReasoningIsNeverCarried` | add `case ("response_item", "reasoning")` emitting `payload["encrypted_content"]` as `.thinking` | `XCTAssertTrue failed` — ciphertext in a body |
| `testAFunctionCallParsesItsArgumentsString` | in `decodedArguments`, return `(text, nil)` unconditionally | `XCTAssertTrue failed: the arguments string is parsed and pretty-printed` |

Record all three in the task report.

- [ ] **Step 5: Extend the fixture guard**

Append to `Tests/FlightDeckTests/TimelineFixtureTests.swift`:

```swift
    private func mappedCodex(_ lines: [String]) -> [TimelineItem] {
        var offset = 0
        var items: [TimelineItem] = []
        for line in lines {
            items += CodexTimelineMapper.items(inRolloutLine: line, at: offset)
            offset += line.utf8.count + 1
        }
        return items
    }

    func testTheCapturedRolloutExercisesEveryKindThisMapperEmits() throws {
        let kinds = Set(mappedCodex(try Self.lines("rollout-content.captured", in: "Codex"))
            .map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.userTurn, .assistantText, .toolCall, .toolResult]),
                      "the capture must contain a prompt, a reply, a tool call and its "
                      + "result; recapture per the plan's Task 4 Step 1. Got \(kinds)")
    }

    /// The existing capture is filtered to `event_msg`, which is why a second one was needed:
    /// it cannot exercise the tool half of the table at all. Asserted so nobody "consolidates"
    /// the two fixtures and quietly loses that coverage.
    func testTheOlderRolloutCaptureHasNoToolRecordsAndThatIsWhyThereAreTwo() throws {
        let kinds = Set(mappedCodex(try Self.lines("rollout.captured", in: "Codex")).map(\.kind))
        XCTAssertFalse(kinds.contains(.toolCall))
    }

    func testEveryItemFromTheCapturedRolloutHasAUniqueId() throws {
        let ids = mappedCodex(try Self.lines("rollout-content.captured", in: "Codex")).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
```

Run: `./scripts/test-unit.sh 2>&1 | tail -20` and `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`
Expected: PASS, 1256 tests; three iOS successes.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexTimelineMapper.swift \
        Tests/FlightDeckTests/CodexTimelineMapperTests.swift \
        Tests/FlightDeckTests/TimelineFixtureTests.swift \
        Tests/FlightDeckTests/Fixtures/Codex
git commit -m "feat: read a codex rollout as conversation, from the file that has one

The spec maps codex from item/started and item/completed. Those are
app-server notifications and that path was deleted in b76a07b: they only
reach the connection that made the change, and turns run in a separate
codex resume process. rg 'item/' over Sources returns nothing. So this
maps the rollout, the same file CodexRolloutWatcher already tails for
turn boundaries.

The rule that is easy to get wrong is which record family a row comes
from, because codex writes the conversation twice. event_msg is the
conversation — one user_message, one agent_message, agent_reasoning.
response_item is the model transcript — every tool call and output, plus
a second copy of the prose, plus a role:user message that is the
assembled prompt (AGENTS.md, environment context, tens of KB every turn)
rather than anything a user said, plus a reasoning record whose content
is encrypted.

Prose from event_msg, tools from response_item, nothing from either
family's duplicate of the other's job. Mapping both for prose puts every
reply on screen twice; mapping response_item/message as a user turn
pastes an instruction blob into the conversation.

The existing rollout capture is filtered to event_msg and therefore has
no tool records at all, so a second capture that keeps response_item
joins it. A test asserts the old one still has none, so nobody
consolidates the two and loses the coverage.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Paging an append-only file by byte window

**Files:**
- Create: `Sources/FlightDeck/Timeline/TranscriptPager.swift`
- Test: `Tests/FlightDeckTests/TranscriptPagerTests.swift`

**Interfaces:**
- Consumes: `TimelineAnchor`, `TimelineLimits` (Tasks 1–2).
- Produces: `SourceLine` (`offset: Int`, `text: String`), `TranscriptPage` (`lines: [SourceLine]`, `start: Int`, `end: Int`, `hasMore: Bool`, `reset: Bool`), `TranscriptPager.page(url:anchor:limit:window:maxScan:) -> TranscriptPage?` (nil = unreadable).

This task is agent-agnostic and has no JSON in it: it answers "which lines of this file, and where were they" for an anchor. That separation is what lets the byte arithmetic — the part that is easy to get subtly wrong and impossible to eyeball — be tested against files written by the test itself.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/TranscriptPagerTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Byte-window paging over an append-only JSONL file. No agents, no JSON — just "which lines,
/// and where were they".
///
/// Four properties here are load-bearing and each is a bug someone would otherwise ship:
/// a trailing partial line must never be consumed, a page must always make progress, cursors
/// must round-trip exactly, and a cursor past the end of the file must announce a reset
/// rather than silently serving from wherever the file happens to be now.
final class TranscriptPagerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("pager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    /// Every line is the same length, so an expected offset is arithmetic a reader can check.
    private func write(_ contents: String) throws -> URL {
        let url = directory.appendingPathComponent("t.jsonl")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func numbered(_ count: Int) -> String {
        (0..<count).map { String(format: "line%03d", $0) }.joined(separator: "\n") + "\n"
    }

    func testLatestReturnsTheNewestLines() throws {
        let url = try write(numbered(10))                       // 8 bytes per line
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 3))
        XCTAssertEqual(page.lines.map(\.text), ["line007", "line008", "line009"])
        XCTAssertEqual(page.start, 56, "7 lines * 8 bytes")
        XCTAssertEqual(page.end, 80)
        XCTAssertTrue(page.hasMore)
        XCTAssertFalse(page.reset)
    }

    /// The cursor contract: `start` fed back as `.before` is the next page up, with no gap and
    /// no overlap. This is the property every scroll depends on.
    func testStartFedBackAsBeforeIsTheNextPageUpExactly() throws {
        let url = try write(numbered(10))
        let first = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 4))
        let second = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .before(first.start), limit: 4)
        )
        XCTAssertEqual(second.lines.map(\.text), ["line002", "line003", "line004", "line005"])
        XCTAssertEqual(second.end, first.start, "no gap and no overlap between pages")
    }

    func testPagingUpToTheTopReportsNoMore() throws {
        let url = try write(numbered(3))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(page.lines.count, 3)
        XCTAssertEqual(page.start, 0)
        XCTAssertFalse(page.hasMore, "there is nothing above offset 0")
    }

    func testAfterReturnsWhatWasAppendedSince() throws {
        let url = try write(numbered(4))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .after(16), limit: 10))
        XCTAssertEqual(page.lines.map(\.text), ["line002", "line003"])
        XCTAssertEqual(page.start, 16)
        XCTAssertEqual(page.end, 32)
    }

    func testAfterTheEndReturnsNothingRatherThanRereading() throws {
        let url = try write(numbered(4))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .after(32), limit: 10))
        XCTAssertTrue(page.lines.isEmpty)
        XCTAssertEqual(page.start, 32)
        XCTAssertEqual(page.end, 32)
        XCTAssertFalse(page.reset, "at the end is not the same as past the end")
    }

    /// **The writer appends while we read.** A read can land mid-write, and consuming a
    /// trailing line that has no newline yet hands a client half a JSON record — which the
    /// mapper drops, permanently, because the cursor has already moved past it. Same rule
    /// `TailReader` documents, for the same reason.
    func testATrailingPartialLineIsNeverConsumed() throws {
        let url = try write(numbered(3) + "line003-partial-no-newline")
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertEqual(page.lines.map(\.text), ["line000", "line001", "line002"])
        XCTAssertEqual(page.end, 24, "the end is the last newline boundary, not the file size")
    }

    /// A cursor past the end of the file means the transcript was replaced or truncated.
    /// Item ids are byte offsets, so every id a client holds now names a different record —
    /// it must be told to throw them away, not quietly handed a page from the new file.
    /// The file-level analogue of §4's explicit re-snapshot.
    func testACursorPastTheEndAnnouncesAReset() throws {
        let url = try write(numbered(2))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .after(9_999), limit: 10))
        XCTAssertTrue(page.reset)
        XCTAssertTrue(page.lines.isEmpty)
    }

    func testABeforeCursorPastTheEndAlsoAnnouncesAReset() throws {
        let url = try write(numbered(2))
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .before(9_999), limit: 10))
        XCTAssertTrue(page.reset)
    }

    /// **Progress.** A record longer than one window must still come back, or backwards
    /// paging stalls on it forever with no way past. The scan widens until it has enough
    /// newlines rather than giving up at the first window.
    func testALineLongerThanTheWindowIsStillReturned() throws {
        let long = String(repeating: "x", count: 300)
        let url = try write("short\n" + long + "\n")
        let page = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .latest, limit: 1, window: 64)
        )
        XCTAssertEqual(page.lines.map(\.text), [long])
        XCTAssertEqual(page.start, 6)
        XCTAssertTrue(page.hasMore)
    }

    /// The widening is bounded. A file that is one enormous line cannot be paged, and saying
    /// so beats reading it all into memory on a Mac.
    func testTheBackwardScanIsBounded() throws {
        let url = try write(String(repeating: "x", count: 5_000) + "\n")
        let page = try XCTUnwrap(
            TranscriptPager.page(url: url, anchor: .latest, limit: 1, window: 64, maxScan: 256)
        )
        XCTAssertTrue(page.lines.isEmpty)
        XCTAssertFalse(page.hasMore, "nothing further is reachable, so do not invite a retry")
    }

    func testAMissingFileIsNilRatherThanAnEmptyPage() {
        XCTAssertNil(TranscriptPager.page(
            url: directory.appendingPathComponent("nope.jsonl"), anchor: .latest, limit: 10
        ), "a claude tab before its first turn has no transcript yet, and 'not there' must "
           + "not render as 'empty conversation'")
    }

    func testAnEmptyFileIsAnEmptyPage() throws {
        let url = try write("")
        let page = try XCTUnwrap(TranscriptPager.page(url: url, anchor: .latest, limit: 10))
        XCTAssertTrue(page.lines.isEmpty)
        XCTAssertFalse(page.hasMore)
        XCTAssertFalse(page.reset)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `cannot find 'TranscriptPager' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FlightDeck/Timeline/TranscriptPager.swift`:

```swift
import FleetKit
import Foundation

/// One line of a transcript, and where it was.
///
/// The offset is what makes an item addressable — `TimelineItem.id` is built from it — so it
/// travels with the text rather than being recomputed by whoever consumes the page.
struct SourceLine: Equatable, Sendable {
    let offset: Int
    let text: String
}

/// One look at a byte range of a transcript.
struct TranscriptPage: Equatable, Sendable {
    var lines: [SourceLine] = []
    /// The offset of the first line. `.before(start)` is the next page up.
    var start: Int
    /// The offset just past the last line. `.after(end)` picks up what has been appended.
    var end: Int
    /// Whether there is more **in the direction that was asked for**. Exact when paging
    /// backwards (`start > 0`); upward-approximate when paging forwards, where a trailing
    /// partial line makes it true and the next `.after(end)` simply comes back empty. That
    /// asymmetry is deliberate: the cheap check is right for the direction where being wrong
    /// costs one empty round trip, and the exact check is used where being wrong would hide
    /// the top of a conversation.
    var hasMore: Bool
    /// The file this cursor came from is gone. See `TimelinePage.reset`.
    var reset: Bool = false
}

/// Reads an arbitrary byte window of an append-only JSONL file, backwards or forwards.
///
/// Agent-agnostic and JSON-free on purpose: the byte arithmetic is the part that is easy to
/// get subtly wrong and impossible to eyeball, so it is separated from anything that would
/// need a fixture to exercise. `TimelineReader` composes this with a mapper.
///
/// Not `TailReader`, and not an extension of it: that type is a forward-only tail with a
/// caller-held `offset` and a truncation policy, which is the right shape for a watcher and
/// cannot seek backwards. Three of its hard-won rules are reproduced here because they are
/// properties of the file rather than of the tail — never consume a trailing partial line,
/// treat a shrinking file as a replacement, and decide where a read starts explicitly.
enum TranscriptPager {
    /// `nil` means the file could not be opened — which for a claude tab before its first
    /// turn is the ordinary state, not an error, and must not be rendered as an empty
    /// conversation.
    static func page(
        url: URL,
        anchor: TimelineAnchor,
        limit: Int,
        window: Int = TimelineLimits.window,
        maxScan: Int = TimelineLimits.window * 16
    ) -> TranscriptPage? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)

        switch anchor {
        case .latest:
            return backwards(handle, from: lastBoundary(handle, size: size, window: window),
                             limit: limit, window: window, maxScan: maxScan)
        case .before(let cursor):
            // Strictly greater: a cursor exactly at the end is a client that is up to date,
            // not one holding a stale one.
            guard cursor <= size else { return reset(at: size) }
            return backwards(handle, from: cursor, limit: limit, window: window, maxScan: maxScan)
        case .after(let cursor):
            guard cursor <= size else { return reset(at: size) }
            return forwards(handle, from: cursor, size: size, limit: limit, window: window)
        }
    }

    private static func reset(at size: Int) -> TranscriptPage {
        // No lines and no `hasMore`: the client's next move is to discard and re-fetch
        // `.latest`, not to page from a cursor that has already been declared meaningless.
        TranscriptPage(start: size, end: size, hasMore: false, reset: true)
    }

    /// The offset just past the file's last newline — the end of the last COMPLETE line.
    ///
    /// Not the file size. The writer appends while this reads, so a read can land mid-write,
    /// and treating the size as a boundary hands a client half a record and then moves the
    /// cursor past it, losing that record for good.
    private static func lastBoundary(_ handle: FileHandle, size: Int, window: Int) -> Int {
        var end = size
        while end > 0 {
            let start = max(0, end - window)
            guard let data = read(handle, from: start, count: end - start) else { return 0 }
            if let index = data.lastIndex(of: UInt8(ascii: "\n")) {
                return start + data.distance(from: data.startIndex, to: index) + 1
            }
            end = start
        }
        return 0
    }

    /// Reads backwards in window-sized chunks until it holds `limit + 1` line boundaries, or
    /// reaches the start of the file, or exceeds `maxScan`.
    ///
    /// `limit + 1`, not `limit`: the extra boundary is what proves the oldest line in the
    /// buffer is whole rather than a fragment the window happened to cut.
    private static func backwards(
        _ handle: FileHandle, from end: Int, limit: Int, window: Int, maxScan: Int
    ) -> TranscriptPage {
        guard end > 0, limit > 0 else {
            return TranscriptPage(start: end, end: end, hasMore: end > 0 && limit <= 0)
        }
        var start = end
        var buffer = Data()
        var boundaries = 0
        while start > 0, boundaries <= limit, buffer.count < maxScan {
            let chunkStart = max(0, start - window)
            guard let chunk = read(handle, from: chunkStart, count: start - chunkStart) else {
                break
            }
            boundaries += chunk.reduce(into: 0) { $0 += ($1 == UInt8(ascii: "\n")) ? 1 : 0 }
            buffer = chunk + buffer
            start = chunkStart
        }

        // The scan ran out of budget without finding a whole line: the file is one record
        // larger than `maxScan`. Report nothing further reachable rather than inviting a
        // retry that will make the same journey — and rather than reading an unbounded file
        // into memory, which is the alternative.
        if start > 0, boundaries == 0 {
            return TranscriptPage(start: end, end: end, hasMore: false)
        }

        var lines = split(buffer, from: start)
        // A window that starts mid-file starts mid-line unless it starts exactly at a
        // boundary. The first element is that fragment; the `boundaries > 0` check above is
        // what guarantees there is something behind it.
        if start > 0, let first = lines.first {
            lines.removeFirst()
            start = first.offset + first.text.utf8.count + 1
        }
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
            start = lines.first?.offset ?? start
        } else if let first = lines.first {
            start = first.offset
        } else {
            start = end
        }
        return TranscriptPage(lines: lines, start: start, end: end, hasMore: start > 0)
    }

    private static func forwards(
        _ handle: FileHandle, from cursor: Int, size: Int, limit: Int, window: Int
    ) -> TranscriptPage {
        guard cursor < size, limit > 0 else {
            return TranscriptPage(start: cursor, end: cursor, hasMore: false)
        }
        guard let data = read(handle, from: cursor, count: min(window, size - cursor)),
              let last = data.lastIndex(of: UInt8(ascii: "\n"))
        else {
            // Nothing but a partial line so far. Not an error and not the end — the writer is
            // mid-record, and the same cursor will work in a moment.
            return TranscriptPage(start: cursor, end: cursor, hasMore: cursor < size)
        }
        let complete = data[..<data.index(after: last)]
        var lines = split(Data(complete), from: cursor)
        var truncated = false
        if lines.count > limit {
            lines.removeLast(lines.count - limit)
            truncated = true
        }
        let end = lines.last.map { $0.offset + $0.text.utf8.count + 1 } ?? cursor
        return TranscriptPage(
            lines: lines, start: cursor, end: end,
            // Exactly true when records were dropped for the limit; upward-approximate
            // otherwise, because a trailing partial line counts. See `hasMore`'s doc.
            hasMore: truncated || end < size
        )
    }

    private static func read(_ handle: FileHandle, from offset: Int, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        try? handle.seek(toOffset: UInt64(offset))
        guard let data = try? handle.read(upToCount: count), !data.isEmpty else { return nil }
        return data
    }

    /// Splits on newlines, carrying each line's absolute offset. Empty lines are dropped —
    /// a JSONL file's blank line carries no record — but their bytes still advance the offset,
    /// which is why this counts rather than joining.
    private static func split(_ data: Data, from base: Int) -> [SourceLine] {
        var lines: [SourceLine] = []
        var offset = base
        for piece in data.split(separator: UInt8(ascii: "\n"), omittingSubsequences: false) {
            let text = String(decoding: piece, as: UTF8.self)
            if !text.isEmpty { lines.append(SourceLine(offset: offset, text: text)) }
            offset += piece.count + 1
        }
        // `omittingSubsequences: false` yields a trailing empty piece for data that ends in a
        // newline, which the emptiness check above already dropped. What it does NOT drop is a
        // final piece with no newline after it — data that does not end in one — and every
        // caller here has already cut the buffer at a boundary, so that case cannot arise.
        return lines
    }
}
```

- [ ] **Step 4: Run the tests, then prove three of them can fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1269 tests.

Mutations, one at a time:

| Test | Mutation | Expected failure |
|---|---|---|
| `testATrailingPartialLineIsNeverConsumed` | in `.latest`, pass `size` instead of `lastBoundary(...)` | the partial line appears in `lines` and `end` is 50 |
| `testACursorPastTheEndAnnouncesAReset` | change `guard cursor <= size` to `guard true` in the `.after` arm | `XCTAssertTrue(page.reset) failed` |
| `testALineLongerThanTheWindowIsStillReturned` | change `backwards`'s loop condition to run at most once (`while start > 0, boundaries <= limit, buffer.isEmpty`) | the long line never comes back |

Record all three.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Timeline/TranscriptPager.swift \
        Tests/FlightDeckTests/TranscriptPagerTests.swift
git commit -m "feat: page an append-only transcript backwards by byte window

The reader a scrolling timeline needs, and the one thing TailReader
cannot be extended into: it holds a caller's forward-only offset, and
backwards pagination has to seek. Agent-agnostic and JSON-free, so the
byte arithmetic — the part that is impossible to eyeball — is tested
against files the test wrote itself.

Three of TailReader's hard-won rules are reproduced because they are
properties of the file rather than of the tail. A trailing partial line
is never consumed: the writer appends while this reads, and consuming
half a record moves the cursor past it for good. A cursor past the end
of the file means the transcript was replaced, and since item ids ARE
byte offsets, every id the client holds now names a different record —
so it is told to discard them, the file-level analogue of §4's explicit
re-snapshot. And the backwards scan widens until it holds a whole line
rather than giving up at one window, or a record larger than the window
would stall paging on it forever.

The widening is bounded at 8 MB. A file that is one enormous line cannot
be paged, and saying so beats reading it all into memory.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Composing a page — mapper, budget, truncation

**Files:**
- Create: `Sources/FlightDeck/Timeline/TimelineReader.swift`
- Test: `Tests/FlightDeckTests/TimelineReaderTests.swift`

**Interfaces:**
- Consumes: `TranscriptPager.page(url:anchor:limit:window:maxScan:)`, `SourceLine`, `TranscriptPage` (Task 5); `ClaudeTimelineMapper.items(inLine:at:)`, `CodexTimelineMapper.items(inRolloutLine:at:)` (Tasks 3–4); `TimelinePage`, `TimelineLimits`, `AgentID`.
- Produces: `TimelineReader.page(session:agent:url:anchor:limit:) -> Result<TimelinePage, TimelineReadFailure>`, `TimelineReadFailure` (`.unreadable`).

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/TimelineReaderTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Pager plus mapper plus budget. The three things this adds on top of Task 5 are the ones a
/// phone on a cellular link depends on: a per-item cap, a per-page budget, and the guarantee
/// that neither of them can ever produce an empty page while a record remains.
final class TimelineReaderTests: XCTestCase {
    private let session = UUID()
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func write(_ lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent("t.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url
    }

    private func userTurn(_ text: String) -> String {
        #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"\#(text)"}}"#
    }

    private func read(
        _ url: URL, _ anchor: TimelineAnchor, limit: Int = 40
    ) throws -> TimelinePage {
        try TimelineReader.page(
            session: session, agent: .claude, url: url, anchor: anchor, limit: limit
        ).get()
    }

    func testAPageCarriesTheMappedItemsInFileOrder() throws {
        let url = try write([userTurn("one"), userTurn("two"), userTurn("three")])
        let page = try read(url, .latest, limit: 2)
        XCTAssertEqual(page.items.map(\.body.text), ["two", "three"],
                       "oldest first, even though the anchor asked backwards")
        XCTAssertEqual(page.session, session)
        XCTAssertTrue(page.hasMore)
    }

    /// One record can carry several items, so `limit` counts records and `items.count` can
    /// exceed it. Asserted because the opposite reading — limit as an item count — produces a
    /// pager call with the wrong argument and pages that shrink unpredictably.
    func testTheLimitCountsRecordsNotItems() throws {
        let url = try write([
            #"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":"#
            + #"[{"type":"text","text":"a"},{"type":"text","text":"b"},{"type":"text","text":"c"}]}}"#
        ])
        XCTAssertEqual(try read(url, .latest, limit: 1).items.count, 3)
    }

    func testAnItemLongerThanTheCapIsTruncatedAndSaysSo() throws {
        let long = String(repeating: "x", count: TimelineLimits.maxItemBytes + 500)
        let url = try write([userTurn(long)])
        let item = try XCTUnwrap(try read(url, .latest).items.first)
        XCTAssertEqual(item.body.text.utf8.count, TimelineLimits.maxItemBytes)
        XCTAssertEqual(item.body.truncatedBytes, 500,
                       "a client that cannot say how much it is missing will present a "
                       + "partial file read as a whole one")
    }

    /// **Progress.** A record whose body alone exceeds the page budget must still come back,
    /// or backwards paging stalls on it forever with no way past.
    func testAnOversizedRecordStillMakesAPage() throws {
        let long = String(repeating: "x", count: TimelineLimits.maxPageBytes + 1_000)
        let url = try write([userTurn("first"), userTurn(long)])
        let page = try read(url, .latest)
        XCTAssertEqual(page.items.count, 1, "the budget stops it AFTER one record, never before")
        XCTAssertTrue(page.hasMore)
    }

    /// Paging backwards, the budget drops the OLDEST records — the client is scrolling up and
    /// wants what is nearest its cursor. `start` moves with them, so the next `.before(start)`
    /// picks up exactly what was dropped.
    func testTheBudgetTrimsFromTheOldestEndWhenPagingBackwards() throws {
        let big = String(repeating: "y", count: TimelineLimits.maxPageBytes / 2 + 100)
        let url = try write([userTurn("oldest"), userTurn(big), userTurn(big)])
        let page = try read(url, .latest)
        XCTAssertFalse(page.items.contains { $0.body.text == "oldest" })
        XCTAssertTrue(page.hasMore)
        let next = try read(url, .before(page.start))
        XCTAssertEqual(next.items.last?.body.text, "oldest",
                       "what the budget dropped is exactly what the next page up returns")
    }

    /// Paging forwards, it trims from the newest end instead, and `end` moves back with them.
    func testTheBudgetTrimsFromTheNewestEndWhenPagingForwards() throws {
        let big = String(repeating: "y", count: TimelineLimits.maxPageBytes / 2 + 100)
        let url = try write([userTurn(big), userTurn(big), userTurn("newest")])
        let page = try read(url, .after(0))
        XCTAssertFalse(page.items.contains { $0.body.text == "newest" })
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(try read(url, .after(page.end)).items.last?.body.text, "newest")
    }

    func testAResetPageCarriesNoItemsAndSaysReset() throws {
        let url = try write([userTurn("one")])
        let page = try read(url, .after(9_999))
        XCTAssertTrue(page.reset)
        XCTAssertTrue(page.items.isEmpty)
    }

    func testAMissingTranscriptIsAFailureNotAnEmptyPage() {
        let result = TimelineReader.page(
            session: session, agent: .claude,
            url: directory.appendingPathComponent("nope.jsonl"),
            anchor: .latest, limit: 40
        )
        XCTAssertEqual(result, .failure(.unreadable))
    }

    func testALimitAboveTheMaximumIsClampedRatherThanRefused() throws {
        let url = try write((0..<5).map { userTurn("m\($0)") })
        XCTAssertEqual(try read(url, .latest, limit: 10_000).items.count, 5)
    }

    /// The agent chooses the mapper and nothing else does. A codex rollout read as claude
    /// yields nothing, which is what a mis-routed tab would look like — so this is the test
    /// that catches the routing being wrong rather than the mapping.
    func testTheAgentSelectsTheMapper() throws {
        let url = try write([
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"ok"}}"#
        ])
        let asCodex = try TimelineReader.page(
            session: session, agent: .codex, url: url, anchor: .latest, limit: 40
        ).get()
        XCTAssertEqual(asCodex.items.map(\.body.text), ["ok"])
        XCTAssertTrue(try read(url, .latest).items.isEmpty, "claude's mapper has no row for it")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `cannot find 'TimelineReader' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FlightDeck/Timeline/TimelineReader.swift`:

```swift
import FleetKit
import Foundation

enum TimelineReadFailure: Error, Equatable, Sendable {
    /// The transcript could not be opened. Ordinary rather than exceptional: a claude tab
    /// that has not taken its first turn has no file yet, and `claude` creates one only when
    /// it first has something to persist.
    case unreadable
}

/// Composes a page: which lines (`TranscriptPager`), what they mean (the agent's mapper), and
/// how much of it a phone gets (`TimelineLimits`).
///
/// Pure apart from the file read and free of actor state, so it runs off the main actor —
/// `TimelineService` dispatches it exactly the way `TranscriptWatcher` dispatches `Scan.read`,
/// and for the same reason: transcript records are large, and parsing them on the main thread
/// at the moment an agent is producing output is a visible stall.
enum TimelineReader {
    static func page(
        session: UUID, agent: AgentID, url: URL, anchor: TimelineAnchor, limit: Int
    ) -> Result<TimelinePage, TimelineReadFailure> {
        // Clamped, not refused. A limit is a hint about what a screen wants, and refusing an
        // over-eager client turns a mildly greedy request into a broken one.
        let limit = min(max(limit, 1), TimelineLimits.maxLimit)
        guard let source = TranscriptPager.page(url: url, anchor: anchor, limit: limit) else {
            return .failure(.unreadable)
        }
        if source.reset {
            return .success(TimelinePage(
                session: session, items: [], start: source.start, end: source.end,
                hasMore: false, reset: true
            ))
        }

        // Mapped per line, keeping each line's items together, because the budget below drops
        // whole RECORDS. Half a record on screen — a tool call with no result, an assistant
        // message missing its second paragraph — is worse than one fewer record.
        let mapper = self.mapper(for: agent)
        let mapped: [(line: SourceLine, items: [TimelineItem])] = source.lines.map {
            ($0, mapper($0.text, $0.offset).map(capped))
        }

        // Backwards anchors trim the oldest end and move `start`; forwards trims the newest
        // and moves `end`. The direction matters: a client scrolling up wants what is nearest
        // the cursor it gave, and trimming the wrong end would hand it a gap it can never
        // close because the cursor it is told to use has already moved past the hole.
        let fromOldest: Bool
        switch anchor {
        case .latest, .before: fromOldest = true
        case .after: fromOldest = false
        }
        let kept = withinBudget(mapped, droppingFromOldest: fromOldest)

        // `hasMore` must account for what the budget dropped, not only for what the pager
        // could not reach: a page that silently shed three records while reporting "that is
        // everything" is a conversation with a hole in it.
        let dropped = kept.count < mapped.count
        let start = fromOldest ? (kept.first?.line.offset ?? source.end) : source.start
        let end = fromOldest
            ? source.end
            : (kept.last.map { $0.line.offset + $0.line.text.utf8.count + 1 } ?? source.start)
        return .success(TimelinePage(
            session: session,
            items: kept.flatMap(\.items),
            start: start,
            end: end,
            hasMore: source.hasMore || dropped,
            reset: false
        ))
    }

    private static func mapper(for agent: AgentID) -> (String, Int) -> [TimelineItem] {
        switch agent {
        case .claude: return ClaudeTimelineMapper.items(inLine:at:)
        case .codex: return CodexTimelineMapper.items(inRolloutLine:at:)
        }
    }

    /// Cuts an oversized body and records what was dropped, so a client can say "showing the
    /// first 64 KB of 210 KB" rather than presenting a partial file read as a whole one.
    ///
    /// Cut on a UTF-8 **character** boundary, not a byte one: `String(decoding:)` would
    /// silently substitute a replacement character for a split scalar, and a body that ends
    /// in U+FFFD looks like corrupted output rather than a truncation.
    private static func capped(_ item: TimelineItem) -> TimelineItem {
        let total = item.body.text.utf8.count
        guard total > TimelineLimits.maxItemBytes else { return item }
        var kept = ""
        var bytes = 0
        for character in item.body.text {
            let width = String(character).utf8.count
            if bytes + width > TimelineLimits.maxItemBytes { break }
            kept.append(character)
            bytes += width
        }
        var item = item
        item.body.text = kept
        item.body.truncatedBytes = total - bytes
        return item
    }

    /// Keeps records until the bodies exceed the page budget — **but never returns none.**
    ///
    /// The `isEmpty` check is the whole point of this function existing separately. Without
    /// it, a single record whose body exceeds the budget produces an empty page with the same
    /// cursor the client already had, and backwards paging stalls on that record forever with
    /// no way past it. One oversized page beats a conversation with an impassable wall in it.
    private static func withinBudget(
        _ records: [(line: SourceLine, items: [TimelineItem])], droppingFromOldest: Bool
    ) -> [(line: SourceLine, items: [TimelineItem])] {
        var kept: [(line: SourceLine, items: [TimelineItem])] = []
        var bytes = 0
        for record in droppingFromOldest ? records.reversed() : records {
            let cost = record.items.reduce(0) { $0 + $1.body.text.utf8.count }
            if bytes + cost > TimelineLimits.maxPageBytes, !kept.isEmpty { break }
            bytes += cost
            kept.append(record)
        }
        return droppingFromOldest ? kept.reversed() : kept
    }
}
```

- [ ] **Step 4: Run the tests, then prove three of them can fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1280 tests.

Mutations:

| Test | Mutation | Expected failure |
|---|---|---|
| `testAnOversizedRecordStillMakesAPage` | drop `, !kept.isEmpty` from the budget check in `withinBudget` | `XCTAssertEqual failed: ("0") is not equal to ("1")` — the impassable page |
| `testTheBudgetTrimsFromTheOldestEndWhenPagingBackwards` | hard-code `fromOldest = false` | the page keeps `"oldest"` and drops the newest, and the follow-up `.before(start)` re-returns what was already shown |
| `testAnItemLongerThanTheCapIsTruncatedAndSaysSo` | return `item` unchanged from `capped` | `XCTAssertEqual failed: ("66036") is not equal to ("65536")` |

Record all three.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Timeline/TimelineReader.swift \
        Tests/FlightDeckTests/TimelineReaderTests.swift
git commit -m "feat: compose a timeline page under a byte budget

Pager plus mapper plus limits. Three properties here are what a phone on
a cellular link actually depends on.

The budget drops whole RECORDS, never items within one: a tool call with
no result, or an assistant message missing its second paragraph, is worse
on screen than one fewer record.

Which END it drops from depends on the direction. Backwards, it drops the
oldest and moves start; forwards, the newest and moves end. Trimming the
wrong end hands the client a gap it can never close, because the cursor
it is told to use next has already moved past the hole.

And it can never return nothing while a record remains. Without that
guard, one record larger than the page budget yields an empty page with
the cursor the client already had — backwards paging stalls on it
forever with no way past. One oversized page beats an impassable wall.

Per-item truncation cuts on a character boundary rather than a byte one:
a body ending in U+FFFD reads as corrupted output rather than as a
truncation, and truncatedBytes is what lets a client say how much it is
missing instead of presenting half a file read as the whole thing.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Resolving a tab id to a transcript

**Files:**
- Create: `Sources/FlightDeck/Fleet/TimelineService.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (add `timelineSource(of:)` beside `watchedTranscriptURL(of:)`, around line 2616)
- Test: `Tests/FlightDeckTests/TimelineServiceTests.swift`

**Interfaces:**
- Consumes: `TimelineReader.page(session:agent:url:anchor:limit:)` (Task 6); `SessionStore.adapter(for:)`, `AgentAdapter.binding(for:)` (shipped).
- Produces: `TimelineSource` (`.file(agent: AgentID, url: URL)`, `.noTranscript`, `.unknownSession`), `SessionStore.timelineSource(of: UUID) -> TimelineSource`, `TimelineService.page(session:anchor:limit:) async -> Result<TimelinePage, String>` (the `String` is a wire error code).

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/TimelineServiceTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeck

/// Tab id → agent + transcript → page, and the three answers that are not a page.
///
/// The distinctions here are the ones a phone renders differently: a tab that does not exist
/// is a stale row, a tab whose agent reports no transcript can never have one, and a tab
/// whose transcript is not on disk yet is the ordinary state of a claude session before its
/// first turn. Collapsing them into one error makes all three read as "something is broken".
@MainActor
final class TimelineServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    /// Mirrors `AgentRoutingTests.StubAdapter`, with a transcript URL this test controls —
    /// the real `ClaudeAdapter` derives one under `~/.claude/projects`, and a test has no
    /// business writing there.
    private struct FixedTranscriptAdapter: AgentAdapter {
        static let id: AgentID = .claude
        let url: URL?

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }
        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: url)
        }
        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory,
                          binding: binding(for: session))
        }
        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
        func loginInvocation(for account: AgentAccount) -> LoginInvocation {
            LoginInvocation(command: "", inject: nil)
        }
    }

    private func store(transcript: URL?) -> (SessionStore, Session) {
        let store = SessionStore(provider: nil, persistence: nil)
        store.overrideAdapter(
            FixedTranscriptAdapter(url: transcript), for: .claude, account: nil
        )
        let session = store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        return (store, session)
    }

    private func writeTranscript() throws -> URL {
        let url = directory.appendingPathComponent("t.jsonl")
        try Data(#"""
            {"type":"user","isSidechain":false,"message":{"role":"user","content":"hello"}}
            {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}

            """#.utf8).write(to: url)
        return url
    }

    func testAKnownTabResolvesToItsAgentAndTranscript() throws {
        let url = try writeTranscript()
        let (store, session) = store(transcript: url)
        XCTAssertEqual(store.timelineSource(of: session.id), .file(agent: .claude, url: url))
    }

    func testAnUnknownTabResolvesToUnknownSession() {
        let (store, _) = store(transcript: nil)
        XCTAssertEqual(store.timelineSource(of: UUID()), .unknownSession)
    }

    /// A codex thread whose `thread/start` never returned a path has no transcript and never
    /// will. That is a different fact from "the file is not there yet" and reads differently
    /// on screen.
    func testATabWhoseAgentReportsNoTranscriptSaysSo() {
        let (store, session) = store(transcript: nil)
        XCTAssertEqual(store.timelineSource(of: session.id), .noTranscript)
    }

    func testTheServiceReturnsAPageForAKnownTab() async throws {
        let url = try writeTranscript()
        let (store, session) = store(transcript: url)
        let page = try await TimelineService(store: store)
            .page(session: session.id, anchor: .latest, limit: 40).get()
        XCTAssertEqual(page.items.map(\.body.text), ["hello", "hi"])
        XCTAssertEqual(page.session, session.id)
    }

    func testEachFailureHasItsOwnCode() async throws {
        let (emptyStore, _) = store(transcript: nil)
        let service = TimelineService(store: emptyStore)

        let unknown = await service.page(session: UUID(), anchor: .latest, limit: 40)
        XCTAssertEqual(unknown, .failure("unknown_session"))

        let (noneStore, noneSession) = store(transcript: nil)
        let missing = await TimelineService(store: noneStore)
            .page(session: noneSession.id, anchor: .latest, limit: 40)
        XCTAssertEqual(missing, .failure("no_transcript"))

        let (pendingStore, pendingSession) = store(
            transcript: directory.appendingPathComponent("not-written-yet.jsonl")
        )
        let pending = await TimelineService(store: pendingStore)
            .page(session: pendingSession.id, anchor: .latest, limit: 40)
        XCTAssertEqual(pending, .failure("unreadable"),
                       "a claude tab before its first turn: claude creates the transcript "
                       + "only when it first has something to persist")
    }

    /// The service must not become another way to change the fleet. Nothing it does writes,
    /// so a replicator attached to the store sees no event and the DEBUG drift check has
    /// nothing new to catch — which is exactly why the timeline could be added without
    /// touching the fleet event log at all.
    func testAnsweringAPageEmitsNoFleetEvent() async throws {
        let url = try writeTranscript()
        let (store, session) = store(transcript: url)
        let replicator = attachedReplicator(to: store)
        let before = replicator.seq
        _ = await TimelineService(store: store)
            .page(session: session.id, anchor: .latest, limit: 40)
        XCTAssertEqual(replicator.seq, before, "reading a transcript is not a fleet mutation")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `value of type 'SessionStore' has no member 'timelineSource'`.

- [ ] **Step 3: Write the implementation**

In `Sources/FlightDeck/SessionStore.swift`, immediately after `watchedTranscriptURL(of:)` (around line 2616):

```swift
    /// Which agent a tab runs, and which file its conversation is read from.
    ///
    /// Three answers rather than an optional, because a phone renders them differently: a tab
    /// that is gone is a stale row, a tab whose agent reports no transcript can never have
    /// one, and a transcript that is simply not on disk yet is the ordinary state of a claude
    /// session before its first turn (`TimelineReader` reports that one, not this).
    ///
    /// The live attachment first, then the adapter: an attached tab is being tailed right now
    /// and its binding is settled, while a tab with no agent process still has a conversation
    /// worth reading. Everything agent-shaped goes through `AgentAdapter.binding(for:)` and
    /// never through `Session.transcriptDirectory` or `ClaudeSession` — same rule
    /// `toolContext()` follows, so that claude deriving its path from a cwd does not become a
    /// rule every future agent inherits.
    func timelineSource(of id: UUID) -> TimelineSource {
        guard let at = locate(id) else { return .unknownSession }
        let session = repos[at.repo].sessions[at.session]
        let url = attachments[id]?.binding.transcriptURL
            ?? adapter(for: instance(for: session)).binding(for: session).transcriptURL
        guard let url else { return .noTranscript }
        return .file(agent: session.agent, url: url)
    }
```

Create `Sources/FlightDeck/Fleet/TimelineService.swift`:

```swift
import FleetKit
import Foundation

/// Where a tab's conversation is read from.
enum TimelineSource: Equatable {
    case file(agent: AgentID, url: URL)
    /// The tab exists and its agent reports no transcript at all — a codex thread whose
    /// `thread/start` never returned a path. Permanent, unlike a file that is not written yet.
    case noTranscript
    /// No such tab. A phone holding a row the Mac has since closed.
    case unknownSession
}

/// Answers a phone's history request.
///
/// The only type that knows both a `SessionStore` and `TimelineReader`, in the same spirit as
/// `FleetService` being the only type that knows both a store and an `NWListener`: the reader
/// stays testable without a store, the store stays testable without a reader, and the thing
/// that needs both is here where it can be read at once.
///
/// **The read runs off the main actor**, exactly as `TranscriptWatcher.poll()` dispatches
/// `Scan.read`, and for the same reason that type documents: transcript records are large —
/// one assistant record carries whole tool inputs and results — and parsing a page of them on
/// the main thread while an agent is producing output is a visible stall in the Mac's own UI.
/// Only the resolution and the answer are main-actor.
///
/// It reads and never writes, which is why the timeline needed no `FleetEvent` and no change
/// to the replication path. `FleetReplicator`'s DEBUG drift check guards mutation sites that
/// forget to record their event; this adds none.
@MainActor
final class TimelineService {
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    /// The `String` on the failure side is the wire error code, verbatim — `err`'s `code`
    /// field. Codes and their meanings are documented on `FleetRequestError`.
    func page(
        session: UUID, anchor: TimelineAnchor, limit: Int
    ) async -> Result<TimelinePage, String> {
        let agent: AgentID
        let url: URL
        switch store.timelineSource(of: session) {
        case .file(let resolvedAgent, let resolvedURL):
            agent = resolvedAgent
            url = resolvedURL
        case .noTranscript:
            return .failure("no_transcript")
        case .unknownSession:
            return .failure("unknown_session")
        }

        let read = await Task.detached(priority: .utility) {
            TimelineReader.page(
                session: session, agent: agent, url: url, anchor: anchor, limit: limit
            )
        }.value

        switch read {
        case .success(let page): return .success(page)
        case .failure(.unreadable): return .failure("unreadable")
        }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1286 tests.

- [ ] **Step 5: Prove `testEachFailureHasItsOwnCode` can fail**

Temporarily collapse the two store answers:

```swift
        case .noTranscript, .unknownSession:
            return .failure("unknown_session")
```

Run: `./scripts/test-unit.sh 2>&1 | grep -A3 testEachFailureHasItsOwnCode`
Expected: **FAIL** — `XCTAssertEqual failed: ("failure("unknown_session")") is not equal to ("failure("no_transcript")")`. Revert.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Fleet/TimelineService.swift Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/TimelineServiceTests.swift
git commit -m "feat: resolve a tab id to the transcript its timeline is read from

One accessor on the store and one service over it. The accessor answers
with three cases rather than an optional, because a phone renders them
differently: a tab that is gone is a stale row, a tab whose agent reports
no transcript can never have one, and a transcript not on disk yet is the
ordinary state of a claude session before its first turn — claude creates
the file only when it first has something to persist.

The live attachment is consulted before the adapter, so an attached tab
answers from the binding it is actually being tailed on, and a tab with no
agent process still has a conversation worth reading. Everything
agent-shaped goes through AgentAdapter.binding(for:), never through
Session.transcriptDirectory or ClaudeSession — the rule toolContext()
already follows, so claude deriving a path from a cwd does not become a
rule future agents inherit.

The read runs off the main actor, the way TranscriptWatcher dispatches
Scan.read and for the reason that type documents: one assistant record
carries whole tool inputs and results, and parsing a page of them on the
main thread while an agent is producing output stalls the Mac's own UI.

It reads and never writes, which is why the timeline needed no FleetEvent
and no change to the replication path — there is no new mutation site for
the DEBUG drift check to miss. A test asserts the sequence does not move.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: A request on the socket, answered asynchronously

**Files:**
- Modify: `Sources/FleetKit/FleetSocketServer.swift` (add `onRequest`; add the `req` arm to `accept`'s frame switch)
- Test: `Tests/FlightDeckTests/FleetRequestPlumbingTests.swift`

**Interfaces:**
- Consumes: `ClientFrame.req`, `ServerFrame.page`, `FleetRequest` (Task 2); `FleetAttachment` (shipped).
- Produces: `FleetSocketServer.onRequest: ((_ client: FleetAttachment, _ cid: Int, _ request: FleetRequest, _ reply: @escaping (ServerFrame) -> Void) -> Void)?`.

`onCommand` returns one frame synchronously, which is right for a command — it is dispatched, not done. A page is file I/O and cannot be produced on the way back out of a frame handler without blocking `queue`, which in production is the main queue. So `onRequest` hands the answer back through a closure instead. That closure must be called on `queue`, exactly once, and is a no-op after the connection has gone.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetRequestPlumbingTests.swift`. It drives a real listener and a real client over loopback, in the shape `FleetSocketLoopbackTests` already uses.

```swift
import Network
import XCTest
@testable import FleetKit

/// The `req` arm of the server's frame switch. A real listener, a real client, a real
/// TLS-PSK handshake — the same shape `FleetSocketLoopbackTests` uses, because a fake
/// transport here would prove nothing about the thing that ships.
///
/// Two rules are load-bearing and neither is visible in normal operation: a `req` before
/// `hello` must be refused exactly as a `cmd` is, and a reply that arrives after the phone
/// has gone must be dropped rather than written to a dead connection.
@MainActor
final class FleetRequestPlumbingTests: XCTestCase {
    private var server: FleetSocketServer!
    private var client: FleetClient!
    private let key = FleetDeviceKey.mint()
    private let session = UUID()

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func page() -> TimelinePage {
        TimelinePage(
            session: session,
            items: [TimelineItem(id: "0#0", kind: .userTurn, status: .complete,
                                 body: .init(text: "hello"))],
            start: 0, end: 80, hasMore: true, reset: false
        )
    }

    private func start() async throws -> NWEndpoint {
        server.onHello = { _, _ in [] }
        let port = try await server.start(keys: [key], port: nil)
        return .hostPort(host: "127.0.0.1", port: port)
    }

    func testARequestIsAnsweredWithAPage() async throws {
        let endpoint = try await start()
        let expected = page()
        server.onRequest = { _, cid, request, reply in
            guard case .timeline(let id, let anchor, let limit) = request else {
                return XCTFail("wrong request")
            }
            XCTAssertEqual(id, self.session)
            XCTAssertEqual(anchor, .before(4_096))
            XCTAssertEqual(limit, 40)
            reply(.page(cid: cid, expected))
        }

        let received = expectation(description: "page")
        client = FleetClient(key: key)
        client.onReady = { [weak self] in
            _ = self?.client.send(
                FleetRequest.timeline(session: self!.session, anchor: .before(4_096), limit: 40)
            )
        }
        client.onFrame = { frame in
            if case .page(_, let page) = frame, page == expected { received.fulfill() }
        }
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [received], timeout: 10)
    }

    /// The correlation id is the client's, echoed. Two fetches in flight is the ordinary case
    /// — a screen asking for older history while a poll for newer is outstanding — and a
    /// server that answered with its own numbering would let a client apply the wrong page.
    func testTwoConcurrentRequestsAreCorrelatedIndependently() async throws {
        let endpoint = try await start()
        var replies: [Int: (ServerFrame) -> Void] = [:]
        server.onRequest = { _, cid, _, reply in replies[cid] = reply }

        var cids: [Int] = []
        let both = expectation(description: "both pages")
        var seen: Set<Int> = []
        client = FleetClient(key: key)
        client.onReady = { [weak self] in
            guard let self else { return }
            cids = [
                self.client.send(FleetRequest.timeline(session: self.session, anchor: .latest, limit: 1)),
                self.client.send(FleetRequest.timeline(session: self.session, anchor: .after(9), limit: 1)),
            ]
            // Answered out of order on purpose: a page is a file read, and the second
            // request can finish first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                replies[cids[1]]?(.page(cid: cids[1], self.page()))
                replies[cids[0]]?(.page(cid: cids[0], self.page()))
            }
        }
        client.onFrame = { frame in
            if case .page(let cid, _) = frame {
                seen.insert(cid)
                if seen == Set(cids) { both.fulfill() }
            }
        }
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [both], timeout: 10)
        XCTAssertEqual(cids.count, 2)
        XCTAssertNotEqual(cids[0], cids[1])
    }

    /// A `req` before `hello` is a peer that skipped the handshake step. `cmd` already
    /// refuses one — answering it would let an unattached peer drive the Mac — and a request
    /// that read a transcript would let it read one.
    func testARequestBeforeHelloIsRefused() async throws {
        server.onHello = { _, _ in [] }
        let port = try await server.start(keys: [key], port: nil)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        var answered = false
        server.onRequest = { _, cid, _, reply in
            answered = true
            reply(.page(cid: cid, self.page()))
        }

        let dropped = expectation(description: "connection dropped")
        client = FleetClient(key: key)
        // A raw client that sends `req` INSTEAD of `hello`. `FleetClient.connect` sends
        // `hello` on `.ready`, so this drives the connection by hand.
        client.onReady = { [weak self] in
            _ = self?.client.send(
                FleetRequest.timeline(session: self!.session, anchor: .latest, limit: 1)
            )
        }
        client.onDisconnect = { _ in dropped.fulfill() }
        client.connectWithoutHelloForTesting(to: endpoint)
        await fulfillment(of: [dropped], timeout: 10)
        XCTAssertFalse(answered, "an unattached peer must not reach the reader")
    }

    /// A page can take a moment to read, and the phone can leave inside that moment. The
    /// reply closure must find nothing to write to rather than writing to a cancelled socket.
    func testAReplyAfterTheClientLeavesIsDropped() async throws {
        let endpoint = try await start()
        let held = expectation(description: "request received")
        var deferredReply: ((ServerFrame) -> Void)?
        server.onRequest = { _, cid, _, reply in
            deferredReply = { _ in reply(.page(cid: cid, self.page())) }
            held.fulfill()
        }

        client = FleetClient(key: key)
        client.onReady = { [weak self] in
            _ = self?.client.send(
                FleetRequest.timeline(session: self!.session, anchor: .latest, limit: 1)
            )
        }
        client.connect(to: endpoint, lastSeq: 0)
        await fulfillment(of: [held], timeout: 10)

        client.disconnect()
        // Let the server observe the end before the reply lands.
        try await Task.sleep(for: .milliseconds(300))
        deferredReply?(.ack(cid: 0))     // must not trap, must not write
        XCTAssertTrue(true, "reaching here without a trap is the assertion")
    }
}
```

`connectWithoutHelloForTesting(to:)` is added to `FleetClient` in Task 9; until then, write `testARequestBeforeHelloIsRefused` as `XCTExpectFailure`-free but **skipped** with `throw XCTSkip("needs FleetClient.connectWithoutHelloForTesting, Task 9")`, and remove the skip in Task 9 Step 4. Note the skip in this task's report so it is not forgotten.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `value of type 'FleetSocketServer' has no member 'onRequest'`.

- [ ] **Step 3: Write the implementation**

In `Sources/FleetKit/FleetSocketServer.swift`, beside `onCommand`:

```swift
    /// Answers a request. Unlike `onCommand`, the answer comes back through `reply` rather
    /// than as a return value, and that difference is forced rather than stylistic: a command
    /// is dispatched on the way out of the frame handler, while a page is a file read that
    /// would otherwise block `queue` — which in production is the main queue.
    ///
    /// `reply` must be called on `queue`, at most once. Calling it after the connection has
    /// ended is safe and does nothing: a phone can leave inside the moment a page takes to
    /// read, and that is the ordinary case, not an error.
    public var onRequest: (
        (_ client: FleetAttachment, _ cid: Int, _ request: FleetRequest,
         _ reply: @escaping (ServerFrame) -> Void) -> Void
    )?
```

In `accept(_:)`'s frame switch, after the `.cmd` case:

```swift
            case .req(let cid, let request):
                // Same rule as `cmd`, for a stronger reason: answering an unattached peer's
                // command lets it drive the Mac, and answering its request lets it READ one.
                guard self.attached[id] != nil else { return connection.cancel() }
                guard let onRequest = self.onRequest else {
                    FleetSocket.send(ServerFrame.err(cid: cid, code: "unhandled"), over: connection)
                    return
                }
                onRequest(attachment, cid, request) { [weak self, weak connection] frame in
                    guard let self, let connection else { return }
                    dispatchPrecondition(condition: .onQueue(self.queue))
                    // The connection may have ended while the page was being read — a phone
                    // that put itself in a pocket mid-scroll. `attached` is keyed by a fresh
                    // UUID per connection and `onEnd` removes it, so this cannot match a
                    // later peer that happens to reuse anything.
                    guard self.attached[id] != nil else { return }
                    FleetSocket.send(frame, over: connection)
                }
```

- [ ] **Step 4: Run the tests**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1289 tests (one skipped until Task 9).

- [ ] **Step 5: Prove `testAReplyAfterTheClientLeavesIsDropped` can fail**

Temporarily change the deferred guard to `guard self.attached[id] == nil else { return }` — inverted, so the reply is written only after the peer has gone.

Run: `./scripts/test-unit.sh 2>&1 | grep -A5 testARequestIsAnsweredWithAPage`
Expected: **FAIL** — `testARequestIsAnsweredWithAPage` times out, because with the guard inverted no live client is ever answered. That inversion is the honest proof the guard is consulted at all; the drop test itself asserts absence, which is why it needs a live-path partner to be evidence. Revert and re-run to green, and note both outcomes.

- [ ] **Step 6: Verify the iOS boundary and commit**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`

```bash
git add Sources/FleetKit/FleetSocketServer.swift \
        Tests/FlightDeckTests/FleetRequestPlumbingTests.swift
git commit -m "feat: answer a socket request asynchronously

onCommand returns one frame on the way out of the frame handler, which is
right for a command — ack means dispatched, not done. A page is a file
read, and producing one inside that return would block queue, which in
production is the main queue. So onRequest hands its answer back through
a closure instead.

Two rules, neither visible in normal operation. A req before hello is
refused exactly as a cmd is, and for a stronger reason: answering an
unattached peer's command lets it drive the Mac, answering its request
lets it read one. And a reply that lands after the connection has ended
is dropped rather than written to a cancelled socket — a phone can go in
a pocket inside the moment a page takes to read, which is ordinary rather
than exceptional.

The correlation id is the client's, echoed, so two fetches in flight —
older history while a poll for newer is outstanding — cannot be confused
for one another.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: The client half

**Files:**
- Modify: `Sources/FleetKit/FleetClient.swift` (`send(_ request:)`, `connectWithoutHelloForTesting(to:)`)
- Modify: `Sources/FleetKit/FleetConnector.swift` (`request(_:then:)`, a pending table, and the drain)
- Modify: `Tests/FlightDeckTests/FleetRequestPlumbingTests.swift` (remove Task 8's skip)
- Test: `Tests/FlightDeckTests/FleetConnectorRequestTests.swift`

**Interfaces:**
- Consumes: `FleetRequest`, `FleetRequestError`, `TimelinePage`, `ServerFrame.page` (Task 2); `FleetConnector` internals (shipped).
- Produces: `FleetClient.send(_ request: FleetRequest) -> Int`, `FleetClient.connectWithoutHelloForTesting(to: NWEndpoint)`, `FleetConnector.request(_ request: FleetRequest, then: @escaping (Result<TimelinePage, FleetRequestError>) -> Void)`.

The load-bearing part is not the send. It is that **every pending callback is answered exactly once, including when the socket dies.** A phone whose connection drops mid-fetch and never hears back shows a spinner forever, with nothing on screen to explain it — the same class of failure the stale-fleet banner exists to prevent.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/FleetConnectorRequestTests.swift`:

```swift
import Network
import XCTest
@testable import FleetKit

/// The connector's request half, against a real listener.
///
/// `browse: false` throughout, as every other connector test does: Bonjour on the build
/// machine finds whatever else is running and makes the race nondeterministic.
@MainActor
final class FleetConnectorRequestTests: XCTestCase {
    private var server: FleetSocketServer!
    private var connector: FleetConnector!
    private let key = FleetDeviceKey.mint()
    private let session = UUID()

    override func setUp() {
        super.setUp()
        server = FleetSocketServer()
    }

    override func tearDown() {
        connector?.stop()
        connector = nil
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func page() -> TimelinePage {
        TimelinePage(
            session: session,
            items: [TimelineItem(id: "0#0", kind: .userTurn, status: .complete,
                                 body: .init(text: "hello"))],
            start: 0, end: 80, hasMore: false, reset: false
        )
    }

    private func startConnector() async throws -> FleetConnector {
        server.onHello = { _, _ in [] }
        let port = try await server.start(keys: [key], port: nil)
        let mac = PairedMac(
            key: key, macName: "Test", serviceName: "none-\(UUID().uuidString)",
            endpoints: ["127.0.0.1:\(port.rawValue)"]
        )
        let store = InMemoryPairedMacStore()
        store.save(mac)
        // `browse: false`, as every connector test does: Bonjour on the build machine finds
        // whatever else is running and makes the race nondeterministic.
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        let connected = expectation(description: "connected")
        connector.onState = { if case .connected = $0 { connected.fulfill() } }
        connector.start()
        await fulfillment(of: [connected], timeout: 10)
        return connector
    }

    func testARequestResolvesWithItsPage() async throws {
        let expected = page()
        server.onRequest = { _, cid, _, reply in reply(.page(cid: cid, expected)) }
        let connector = try await startConnector()

        let answered = expectation(description: "answered")
        connector.request(.timeline(session: session, anchor: .latest, limit: 40)) { result in
            XCTAssertEqual(try? result.get(), expected)
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
    }

    func testAnErrorReplyResolvesWithItsCode() async throws {
        server.onRequest = { _, cid, _, reply in reply(.err(cid: cid, code: "no_transcript")) }
        let connector = try await startConnector()

        let answered = expectation(description: "answered")
        connector.request(.timeline(session: session, anchor: .latest, limit: 40)) { result in
            XCTAssertEqual(result, .failure(.server(code: "no_transcript")))
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
    }

    /// **The one that matters.** A socket that dies with a fetch outstanding must answer the
    /// callback, not abandon it. A screen waiting on a callback that never arrives shows a
    /// spinner forever with nothing to explain it — the same failure the stale-fleet banner
    /// exists to prevent, one layer down.
    func testAPendingRequestFailsWhenTheConnectionDrops() async throws {
        let held = expectation(description: "request reached the server")
        server.onRequest = { _, _, _, _ in held.fulfill() }   // deliberately never replies
        let connector = try await startConnector()

        let answered = expectation(description: "answered")
        connector.request(.timeline(session: session, anchor: .latest, limit: 40)) { result in
            XCTAssertEqual(result, .failure(.disconnected))
            answered.fulfill()
        }
        await fulfillment(of: [held], timeout: 10)
        server.stop()
        await fulfillment(of: [answered], timeout: 10)
    }

    func testStoppingTheConnectorAnswersEveryPendingRequest() async throws {
        let held = expectation(description: "reached")
        held.expectedFulfillmentCount = 2
        server.onRequest = { _, _, _, _ in held.fulfill() }
        let connector = try await startConnector()

        let answered = expectation(description: "both answered")
        answered.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            connector.request(.timeline(session: session, anchor: .latest, limit: 40)) { result in
                XCTAssertEqual(result, .failure(.disconnected))
                answered.fulfill()
            }
        }
        await fulfillment(of: [held], timeout: 10)
        connector.stop()
        await fulfillment(of: [answered], timeout: 10)
    }

    /// A request made while nothing is connected has to answer immediately. `send(_ command:)`
    /// is a silent no-op in that state, which is correct for a command whose effect arrives
    /// as an event and wrong for a request whose whole point is the reply.
    func testARequestWhileDisconnectedFailsAtOnce() {
        let mac = PairedMac(key: key, macName: "Test",
                            serviceName: "none-\(UUID().uuidString)", endpoints: [])
        let store = InMemoryPairedMacStore()
        store.save(mac)
        let connector = FleetConnector(mac: mac, store: store, browse: false)
        self.connector = connector
        var result: Result<TimelinePage, FleetRequestError>?
        connector.request(.timeline(session: session, anchor: .latest, limit: 40)) { result = $0 }
        XCTAssertEqual(result, .failure(.disconnected), "and synchronously, not eventually")
    }

    /// A page must not move the resume point. `FleetConnector.advance(to:)` and `adopt(_:)`
    /// are the only writers of `lastSeq`, and neither may be reached from a `.page`: a phone
    /// paging back through an hour of transcript would otherwise rewrite how much fleet
    /// history it believes it has seen, and resume from the wrong place on its next launch.
    func testAPageDoesNotMoveTheResumePoint() async throws {
        server.onRequest = { _, cid, _, reply in reply(.page(cid: cid, self.page())) }
        server.onHello = { _, _ in [] }
        let port = try await server.start(keys: [key], port: nil)
        let seeded = PairedMac(
            key: key, macName: "Test", serviceName: "none-\(UUID().uuidString)",
            endpoints: ["127.0.0.1:\(port.rawValue)"], lastSeq: 500
        )
        let store = InMemoryPairedMacStore()
        store.save(seeded)
        let connector = FleetConnector(mac: seeded, store: store, browse: false)
        self.connector = connector
        let connected = expectation(description: "connected")
        connector.onState = { if case .connected = $0 { connected.fulfill() } }
        connector.start()
        await fulfillment(of: [connected], timeout: 10)

        let answered = expectation(description: "answered")
        connector.request(.timeline(session: session, anchor: .latest, limit: 40)) { _ in
            answered.fulfill()
        }
        await fulfillment(of: [answered], timeout: 10)
        XCTAssertEqual(store.load()?.lastSeq, 500, "a history fetch is not fleet history")
    }
}
```

`InMemoryPairedMacStore` already ships in `Sources/FleetKit/PairedMacStore.swift` — `init()` with no argument, then `save(_:)`. `FleetConnectorTests` uses it exactly this way; reuse it and do **not** add a second in-memory store.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `value of type 'FleetConnector' has no member 'request'`.

- [ ] **Step 3: Write the implementation**

**Re-read `Sources/FleetKit/FleetClient.swift` first.** The pairing-channel work is editing it concurrently — it hoists `webSocketEndpoint(for:)` out of this file into `FleetSocket`. That does not collide with the change below, which touches `send` and `connect`, but only if you edit the current contents rather than a remembered version of them.

In `Sources/FleetKit/FleetClient.swift`, beside the existing `send(_ command:)`:

```swift
    /// Returns the correlation id the reply will carry. Unlike a command's `ack`, that reply
    /// carries the answer — see `FleetRequest`.
    @discardableResult
    public func send(_ request: FleetRequest) -> Int {
        guard let connection else { return 0 }
        let cid = nextCID
        nextCID += 1
        FleetSocket.send(ClientFrame.req(cid: cid, request), over: connection)
        return cid
    }

    /// Connects WITHOUT sending `hello`, so a test can prove the server refuses an
    /// unattached peer's frames. Production has no use for this and must not gain one:
    /// `hello` is what turns a completed handshake into an attachment, and a client that
    /// skipped it is exactly the shape `FleetSocketServer` drops on sight.
    func connectWithoutHelloForTesting(to endpoint: NWEndpoint) {
        connect(to: endpoint, lastSeq: 0, sendHello: false)
    }
```

Change `connect(to:lastSeq:)` to take a defaulted flag rather than duplicating the body:

```swift
    public func connect(to endpoint: NWEndpoint, lastSeq: Int) {
        connect(to: endpoint, lastSeq: lastSeq, sendHello: true)
    }

    private func connect(to endpoint: NWEndpoint, lastSeq: Int, sendHello: Bool) {
```

and in the `.ready` arm:

```swift
            case .ready:
                if sendHello {
                    // `hello` goes out the instant the socket is usable. TLS-PSK has already
                    // established who we are, so this is a resume point, not a credential.
                    FleetSocket.send(
                        ClientFrame.hello(lastSeq: lastSeq, device: self.deviceName),
                        over: connection
                    )
                }
                self.onReady?()
```

In `Sources/FleetKit/FleetConnector.swift`, add the pending table beside `racers`:

```swift
    /// Outstanding requests, by correlation id.
    ///
    /// Every entry MUST be resolved exactly once — with a page, with an error, or with
    /// `.disconnected` when the socket goes away. A callback that never fires leaves the
    /// screen that made the request showing a spinner forever, with nothing on screen to say
    /// why. That is the same failure the stale-fleet banner exists to prevent, one layer
    /// down, and it is why `teardown()` drains this table rather than clearing it.
    private var pending: [Int: (Result<TimelinePage, FleetRequestError>) -> Void] = [:]
```

the public entry point:

```swift
    /// Ask the Mac for something and get exactly one answer.
    ///
    /// Answers **synchronously with `.disconnected`** when nothing is connected, rather than
    /// dropping the request the way `send(_ command:)` does. That asymmetry is deliberate:
    /// a command's effect arrives separately as a northbound event, so a dropped one is
    /// merely ineffective, while a dropped request is a caller waiting forever.
    public func request(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let winner else { return completion(.failure(.disconnected)) }
        let cid = winner.send(request)
        guard cid != 0 else { return completion(.failure(.disconnected)) }
        pending[cid] = completion
    }
```

in `apply(_ frame:)`, before the existing `switch`'s `.ack, .err` arm — replace that arm and add `.page`:

```swift
        case .page(let cid, let page):
            // Resolved and returned WITHOUT touching `lastSeq`. A page carries no sequence
            // (see `ServerFrame.page`), and reaching `advance(to:)` from here would let a
            // phone paging back through an hour of transcript rewrite how much fleet history
            // it believes it has applied.
            pending.removeValue(forKey: cid)?(.success(page))
            return
        case .ack(let cid), .err(let cid, _):
            // A command's reply changes no fleet state; its effect arrives as its own event.
            // A request's does not — an `err` is the only answer that request will ever get.
            if let completion = pending.removeValue(forKey: cid) {
                if case .err(_, let code) = frame {
                    completion(.failure(.server(code: code)))
                } else {
                    // An `ack` correlated to a request is a server that answered the wrong
                    // verb. Treated as a server error rather than dropped, so the caller is
                    // released either way.
                    completion(.failure(.server(code: "unexpected_ack")))
                }
            }
            return
```

and in `teardown()`, before the racers are dropped:

```swift
    private func teardown() {
        // Drained, not cleared. See `pending`.
        let outstanding = pending.values
        pending.removeAll()
        for completion in outstanding { completion(.failure(.disconnected)) }
        for client in racers.values { client.disconnect() }
```

- [ ] **Step 4: Remove Task 8's skip and run the tests**

Delete the `throw XCTSkip(...)` line from `testARequestBeforeHelloIsRefused`.

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1296 tests, 0 skipped.

- [ ] **Step 5: Prove three tests can fail**

| Test | Mutation | Expected failure |
|---|---|---|
| `testAPendingRequestFailsWhenTheConnectionDrops` | in `teardown()`, replace the drain with `pending.removeAll()` | times out at 10s — the callback never fires, which is exactly the spinner-forever bug |
| `testAPageDoesNotMoveTheResumePoint` | add `advance(to: page.end)` to the `.page` arm | `XCTAssertEqual failed: ("Optional(80)") is not equal to ("Optional(500)")` |
| `testARequestWhileDisconnectedFailsAtOnce` | change the `guard let winner` to `guard let winner else { return }` | `XCTAssertEqual failed: ("nil") is not equal to ("Optional(failure(disconnected)))")` |

Record all three.

- [ ] **Step 6: Verify the iOS boundary and commit**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`

```bash
git add Sources/FleetKit/FleetClient.swift Sources/FleetKit/FleetConnector.swift \
        Tests/FlightDeckTests/FleetConnectorRequestTests.swift \
        Tests/FlightDeckTests/FleetRequestPlumbingTests.swift
git commit -m "feat: ask the Mac for a page and always get an answer

The send is the easy half. The load-bearing half is that every pending
callback resolves exactly once — with a page, with the server's error
code, or with .disconnected when the socket dies. teardown() DRAINS the
pending table rather than clearing it, because a callback that never
fires leaves the screen that made the request spinning forever with
nothing to explain it: the same failure the stale-fleet banner exists to
prevent, one layer down.

A request while nothing is connected fails synchronously rather than
being dropped, which is where it differs from send(_ command:) on
purpose. A command's effect arrives separately as a northbound event, so
dropping one is merely ineffective; dropping a request is a caller
waiting forever.

A page resolves without touching lastSeq. Reaching advance(to:) from
there would let a phone paging back through an hour of transcript
rewrite how much fleet history it believes it has applied, and resume
from the wrong place on its next launch.

FleetClient gains a test-only connect that skips hello, so the server's
refusal of an unattached peer's frames can be proven rather than assumed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Wire it to the fleet, end to end

**Files:**
- Modify: `Sources/FlightDeck/Fleet/FleetService.swift` (**re-read immediately before editing — another agent is working in this file**)
- Modify: `docs/ARCHITECTURE.md`
- Test: `Tests/FlightDeckTests/TimelineLoopbackTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: nothing new — this is the assembly, and its test is the plan's acceptance test.

- [ ] **Step 1: Write the failing acceptance test**

Create `Tests/FlightDeckTests/TimelineLoopbackTests.swift`:

```swift
import Network
import XCTest
@testable import FleetKit
@testable import FlightDeck

/// The whole channel, in one process: a real `FleetService` over a real TLS-PSK socket,
/// answering a real request from a real `FleetClient` out of a real file on disk.
///
/// This is the plan's acceptance test. Everything below it is unit-tested in isolation; this
/// is the only place that proves the pieces are actually connected — the seam every previous
/// slice on this branch found its integration bug at.
@MainActor
final class TimelineLoopbackTests: XCTestCase {
    private var directory: URL!
    private var service: FleetService!
    private var client: FleetClient!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("loopback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        client?.disconnect()
        client = nil
        service?.stop()
        service = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        super.tearDown()
    }

    private struct FixedTranscriptAdapter: AgentAdapter {
        static let id: AgentID = .claude
        let url: URL?
        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }
        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: url)
        }
        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: session.transcriptDirectory,
                          binding: binding(for: session))
        }
        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
        func loginInvocation(for account: AgentAccount) -> LoginInvocation {
            LoginInvocation(command: "", inject: nil)
        }
    }

    func testAPairedClientReadsASessionsTimelineOverTheSocket() async throws {
        // A transcript on disk, three records, mapping to four items.
        let transcript = directory.appendingPathComponent("t.jsonl")
        try Data(#"""
            {"type":"user","isSidechain":false,"message":{"role":"user","content":"read it"}}
            {"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"text","text":"on it"},{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}]}}
            {"type":"user","isSidechain":false,"message":{"role":"user","content":[{"tool_use_id":"tu1","type":"tool_result","content":"a\nb"}]}}

            """#.utf8).write(to: transcript)

        // A real service, a real store, one real session.
        let harness = FleetTestHarness()
        service = harness.service
        harness.store.overrideAdapter(
            FixedTranscriptAdapter(url: transcript), for: .claude, account: nil
        )
        let session = harness.store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        try await harness.start()

        // A real client over a real handshake.
        var received: TimelinePage?
        let answered = expectation(description: "page")
        client = FleetClient(key: harness.key)
        client.onFrame = { frame in
            if case .page(_, let page) = frame {
                received = page
                answered.fulfill()
            }
        }
        client.onReady = { [weak self] in
            _ = self?.client.send(
                FleetRequest.timeline(session: session.id, anchor: .latest, limit: 40)
            )
        }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)

        let page = try XCTUnwrap(received)
        XCTAssertEqual(page.session, session.id)
        XCTAssertEqual(page.items.map(\.kind),
                       [.userTurn, .assistantText, .toolCall, .toolResult])
        XCTAssertEqual(page.items.map(\.body.text).first, "read it")
        XCTAssertEqual(page.items.last?.body.callID, "tu1")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.start, 0)
    }

    /// The second page is what proves the cursors survive the wire, not just the reader.
    func testTheCursorFromOnePageFetchesTheOneAboveIt() async throws {
        let transcript = directory.appendingPathComponent("t.jsonl")
        let lines = (0..<6).map {
            #"{"type":"user","isSidechain":false,"message":{"role":"user","content":"m\#($0)"}}"#
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)

        let harness = FleetTestHarness()
        service = harness.service
        harness.store.overrideAdapter(
            FixedTranscriptAdapter(url: transcript), for: .claude, account: nil
        )
        let session = harness.store.newSession(in: URL(fileURLWithPath: "/w/alpha"))
        try await harness.start()

        var pages: [TimelinePage] = []
        let both = expectation(description: "two pages")
        both.expectedFulfillmentCount = 2
        client = FleetClient(key: harness.key)
        client.onFrame = { [weak self] frame in
            guard case .page(_, let page) = frame else { return }
            pages.append(page)
            if pages.count == 1 {
                _ = self?.client.send(
                    FleetRequest.timeline(session: session.id,
                                          anchor: .before(page.start), limit: 3)
                )
            }
            both.fulfill()
        }
        client.onReady = { [weak self] in
            _ = self?.client.send(
                FleetRequest.timeline(session: session.id, anchor: .latest, limit: 3)
            )
        }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [both], timeout: 15)

        XCTAssertEqual(pages[0].items.map(\.body.text), ["m3", "m4", "m5"])
        XCTAssertEqual(pages[1].items.map(\.body.text), ["m0", "m1", "m2"])
        XCTAssertEqual(pages[1].end, pages[0].start, "no gap, no overlap, across the wire")
        XCTAssertFalse(pages[1].hasMore)
    }

    func testAnUnknownSessionComesBackAsAnError() async throws {
        let harness = FleetTestHarness()
        service = harness.service
        try await harness.start()

        var code: String?
        let answered = expectation(description: "err")
        client = FleetClient(key: harness.key)
        client.onFrame = { frame in
            if case .err(_, let received) = frame {
                code = received
                answered.fulfill()
            }
        }
        client.onReady = { [weak self] in
            _ = self?.client.send(
                FleetRequest.timeline(session: UUID(), anchor: .latest, limit: 40)
            )
        }
        client.connect(to: try service.loopbackEndpoint(), lastSeq: 0)
        await fulfillment(of: [answered], timeout: 15)
        XCTAssertEqual(code, "unknown_session")
    }
}
```

**`FleetTestHarness` is an extraction, not an invention.** `FleetServiceTests` already stands a real service up in a private `standUp()` plus a private `MemoryPersistence`; this task lifts both into `Tests/FlightDeckTests/FleetTestHarness.swift` unchanged and points `FleetServiceTests` at it. Do not write a second one — two ways to stand up a fleet in one suite is exactly how the two halves drift.

```swift
import FleetKit
import Network
import XCTest
@testable import FlightDeck

/// Stands up a real `FleetService` over a real socket with one paired device.
///
/// Extracted verbatim from `FleetServiceTests.standUp()`, which was the only copy until the
/// timeline tests needed the same thing. It is a `final class` rather than a function
/// returning a tuple because the caller has to keep the service alive for the length of the
/// test — a returned service with no owner is cancelled out from under the socket.
@MainActor
final class FleetTestHarness {
    let store: SessionStore
    let preferences: PreferencesStore
    let service: FleetService
    let key: FleetDeviceKey

    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    init() {
        store = SessionStore(provider: nil, persistence: nil)
        key = FleetDeviceKey.mint()
        preferences = PreferencesStore(persistence: MemoryPersistence())
        preferences.upsert(
            PairedDevice(
                slot: key.slot, name: "test device", secret: key.secret,
                pairedAt: Date(), lastSeenAt: nil, armedUntil: nil
            )
        )
        service = FleetService(store: store, preferences: preferences, armer: PairingArmer())
    }

    @discardableResult
    func start() async throws -> NWEndpoint.Port { try await service.start(port: nil) }
}
```

Then replace `FleetServiceTests.standUp()`'s body with a call through this type, keeping its existing `(SessionStore, FleetDeviceKey, NWEndpoint.Port)` return so none of its own tests change.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: the requests are answered `err` with code `unhandled` — `FleetService` has no `onRequest` handler yet, so `FleetSocketServer` falls through to its own reply. `testAPairedClientReadsASessionsTimelineOverTheSocket` times out waiting for a `page`.

That failure mode is worth pausing on: it is exactly what a forgotten wiring looks like in production, and it is why this test exists.

- [ ] **Step 3: Write the implementation**

**Re-read `Sources/FlightDeck/Fleet/FleetService.swift` before editing it.** Another agent is working in this file; merge into what is there rather than pasting over it.

Add the stored property beside `replicator`:

```swift
    private let replicator: FleetReplicator
    /// Answers history requests. Held here rather than built per request because it holds the
    /// store, and because there is exactly one of it — a request carries its own session id,
    /// so nothing about it is per-connection.
    private let timeline: TimelineService
```

in `init`, after `self.replicator = …`:

```swift
        self.timeline = TimelineService(store: store)
```

in `wireHandlers()`, after the `server.onCommand` assignment:

```swift
        server.onRequest = { [weak self] _, cid, request, reply in
            guard let self else { return reply(.err(cid: cid, code: "stopped")) }
            switch request {
            case .timeline(let session, let anchor, let limit):
                // A `Task` rather than a synchronous answer, because reading a page is file
                // I/O: `TimelineService` hands the parse to a detached task and resumes here
                // on the main actor, which is `queue`. `reply` is therefore called on
                // `queue`, as `onRequest` requires — and after an await, which is exactly the
                // case `FleetSocketServer`'s deferred-send guard is written for.
                Task { @MainActor in
                    switch await self.timeline.page(
                        session: session, anchor: anchor, limit: limit
                    ) {
                    case .success(let page): reply(.page(cid: cid, page))
                    case .failure(let code): reply(.err(cid: cid, code: code))
                    }
                }
            }
        }
```

- [ ] **Step 4: Run the tests**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1299 tests, 0 failures.

- [ ] **Step 5: Prove the wiring test can fail**

Temporarily comment out the whole `server.onRequest = { … }` assignment.

Run: `./scripts/test-unit.sh 2>&1 | grep -A5 testAPairedClientReadsASessionsTimeline`
Expected: **FAIL** — the expectation times out; the client receives `err(code: "unhandled")` instead of a page. Restore and re-run to green.

- [ ] **Step 6: Update the architecture doc**

In `docs/ARCHITECTURE.md`, in the fleet-replication section, after the paragraph describing the event log and replay ring, add:

```markdown
### History

Conversation content does **not** ride the event log. Fleet state is pushed — it is small,
and every client wants all of it — while a transcript is bulk that only the one client
looking at that session wants, so history is **pulled**: `ClientFrame.req` carries a
`TimelineAnchor` (`latest` / `before(cursor)` / `after(cursor)`) and `ServerFrame.page`
answers with the mapped items, correlated by `cid` and deliberately carrying no `seq` — a
history fetch must not move a client's resume point.

Cursors are byte offsets at line boundaries in the agent's own transcript, opaque to the
client, which only ever echoes back a `start` or an `end` it was given. `TimelinePage.reset`
is the file-level analogue of the wire's `seq_too_old` re-snapshot: the transcript this
cursor came from was replaced, so every item id the client holds — ids *are* offsets — now
names a different record, and it must discard and re-fetch.

`TranscriptPager` reads the byte window, the per-agent mapper (`ClaudeTimelineMapper`,
`CodexTimelineMapper`) turns lines into `TimelineItem`s, and `TimelineReader` composes them
under a page byte budget. `TimelineService` resolves a tab id through `SessionStore` and runs
the read off the main actor. Nothing in that path writes to the store, which is why the
timeline needed no `FleetEvent` and left `FleetReplicator`'s drift check with nothing new to
guard.
```

- [ ] **Step 7: Final verification and commit**

Run both, and report the numbers:

```bash
./scripts/test-unit.sh 2>&1 | tail -5
./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'
```

Expected: 1299 tests, 0 failures; three iOS successes.

```bash
git add Sources/FlightDeck/Fleet/FleetService.swift docs/ARCHITECTURE.md \
        Tests/FlightDeckTests/TimelineLoopbackTests.swift Tests/FlightDeckTests/FleetTestHarness.swift
git commit -m "feat: answer a phone's history request over the fleet socket

The assembly, and the acceptance test that proves the pieces are actually
connected: a real FleetService over a real TLS-PSK socket answering a
real FleetClient out of a real file, including the second page fetched
from the first page's cursor — which is what shows the cursors survive
the wire and not merely the reader.

The handler answers from a Task rather than synchronously, because
reading a page is file I/O. TimelineService hands the parse to a detached
task and resumes on the main actor, which is the socket's queue, so the
reply lands where onRequest requires — after an await, which is exactly
the case the server's deferred-send guard was written for.

Removing the wiring makes the acceptance test time out with the client
receiving err(unhandled), which is precisely what a forgotten handler
looks like in production.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-review

Run against the spec with fresh eyes after the plan was complete.

**Spec coverage (§6, the binding section):**

| §6 requirement | Where |
|---|---|
| `TimelineItem` with `id` / `kind` / `status` / `body`, on a channel separate from `AgentEvent` | Task 1 |
| The six kinds, `.prompt` included | Task 1 |
| codex maps from its own record stream | Task 4 — **from the rollout, not `item/started`; see findings §1** |
| claude maps by parsing transcript JSONL, extending the existing path | Tasks 3, 5 — **one parser, two readers; see findings §4** |
| Asymmetry 1: no live cursor | Findings §2 — it applies to *both* agents; `.streaming` ships unused and both mapper suites assert `.complete`. The screen plan is where "do not imply otherwise" is enforced. |
| Asymmetry 2: sub-agents | Findings §3 — **inverted in the spec.** Nothing per-sub-agent is added here; the screen plan carries the rule that a codex `subagentCount` of 0 means *unknown*, not *none*. |
| History paginated, riding the same socket as a `cid`-correlated pair | Tasks 2, 8, 9 |
| Not pushed unasked | The whole design is pull; findings §5 |
| Opening a session fetches the most recent page and pages backwards | `.latest` then `.before(start)`; proven end to end in Task 10 |

**§9 (built in slice 2, not here):** nothing in this plan builds prompt bridging. Two decisions keep it possible without a protocol break — `TimelineItem.Kind.prompt` exists with nothing emitting it, and `Kind`/`Status` decode unknown values rather than throwing, so a Mac that starts emitting prompts does not disconnect older phones. A `PromptBroker` will emit `.prompt` items and a `prompt.opened` event; neither needs a wire change from here.

**Placeholder scan:** no TBDs; every code step carries the code. Two steps deliberately point at existing files rather than repeating them — Task 9's `InMemoryPairedMacStore` and Task 10's `FleetTestHarness` — and both say explicitly that adding a second copy is the failure to avoid, which is the point of not repeating them.

**Type consistency, checked name by name:** `TimelineItem.identifier(offset:index:)` is produced in Task 1 and used in Tasks 3, 4. `TimelineAnchor`'s three cases are consistent from Task 2 through Task 10. `TranscriptPage` (Task 5, `lines`/`start`/`end`/`hasMore`/`reset`) is distinct from `TimelinePage` (Task 2, `session`/`items`/…) and the two are never confused — the reader converts one to the other in Task 6. `TimelineReadFailure.unreadable` (Task 6) becomes the wire code `"unreadable"` in Task 7. `TimelineSource`'s three cases (Task 7) map to `"unknown_session"` / `"no_transcript"` / a page. `FleetSocketServer.onRequest`'s signature in Task 8 matches its call in Task 10.

**One gap accepted knowingly:** a session screen left open sees new records only when it asks again. There is no push, and the screen plan's poll is what covers it. That is §6's model, stated: the phone asks for the page it needs.

**One thing this plan does not test and cannot:** that `claude` and `codex` still write the record shapes the mappers read. `CodexIntegrationTests` (`FLIGHT_DECK_CODEX_INTEGRATION=1`) is the existing answer for codex and the fixtures are dated captures for both. This is the same weak ground truth `rollout.captured.provenance.json` already names, and no amount of unit testing changes it.
