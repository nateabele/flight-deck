# Session Timeline Screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make tapping a session on the phone open it — a timeline rendered in the terminal's own idiom, paging backwards on scroll, picking up new records while it is open, with a tool row tapping through to the full command output — and surface the two places where the agents genuinely differ rather than papering over them.

**Architecture:** The pagination state machine is a value type in `FleetKit` (`TimelineFeed`), so the merge, the dedupe and the cursor arithmetic are covered by `./scripts/test-unit.sh` on macOS rather than by a simulator nobody can assert against. `FlightDeckMobile` holds the thin `@Observable` shell over it, exactly as `FleetModel` is a thin shell over `FleetSnapshot.apply(_:)`. Three screens, as spec §7 says: fleet list → session timeline → item detail.

**Tech Stack:** Swift 6, SwiftUI (iOS 17 deployment target), `FleetKit`, XCTest.

**Spec:** [`docs/superpowers/specs/2026-08-18-mobile-companion-design.md`](../specs/2026-08-18-mobile-companion-design.md) — §6 (content feed) and §7 (iOS client), with §8 (unread is one fleet-wide fact) governing what opening a session does.

**Follows:** [`2026-08-21-timeline-vocabulary-and-history-channel.md`](2026-08-21-timeline-vocabulary-and-history-channel.md). **Every type this plan consumes is produced there and none is invented here** — this plan adds nothing to the wire. Read that plan's "Findings that change §6" section before Task 2; two of the three findings are surfaced by this plan's UI and would otherwise look like bugs.

---

## Why this is its own plan

The seam is verification, not size. Everything in the other plan is provable by `./scripts/test-unit.sh`: byte offsets, codecs, mapping tables, socket plumbing. Everything here needs `./scripts/build-ios.sh`, a booted simulator, and a person looking at it — the class of check this repo already keeps as a manual checklist in `docs/MOBILE.md`, because a build machine with no camera and no device cannot settle it.

Splitting on that line worked twice on this branch already (the replication spine before pairing; the pairing channel before the pairing UI), and it is what lets the first two tasks here still be real unit tests: the pagination state machine lives in `FleetKit` precisely so a reviewer can reject the merge logic without having an opinion about row density.

## What the two agents' asymmetries actually look like on screen

The spec asks for two asymmetries to be **surfaced rather than papered over**. Checked against the code, one is not the asymmetry §6 describes and the other is backwards. The other plan's findings §2 and §3 have the evidence; this is what the screen does about it.

### 1. Nothing streams, for either agent

§6 expects codex to stream tokens and claude to land whole messages. Both agents are observed from files they write, and neither writes deltas — a survey of 494 codex rollouts found zero `*delta*` records, and codex's app-server notification path (the only thing that could stream) was deleted in `b76a07b`. So the honest surfacing is **no streaming affordance anywhere**: no caret, no fading last row, no "typing" animation, for either agent.

What the screen shows instead is the truth it does have: a session whose `WireSession.activity` is `busy` gets a **footer** below the last item saying the agent is working, and the feed polls. That is a statement about the session, which is live and correct, rather than about the last row, which is finished. `TimelineItem.Status.streaming` exists in the vocabulary and nothing emits it; Task 4 renders it identically to `.complete` and says why, so that a future streaming source is a rendering change and not a redesign.

### 2. Sub-agents are a claude count and a codex unknown

§6 says "a count for claude, per-sub-agent for codex". The reverse is true. `TranscriptWatcher` counts claude's outstanding top-level `Agent` tool calls, and `CodexEventMapper` states outright that no `collab` record exists in any surveyed rollout and `subagentCount` is **deliberately never emitted for codex** — re-checked across 494 rollouts here, still nothing.

So for a codex tab, `WireSession.subagentCount` is always `0`, and **`0` means unknown, not none.** The rule this plan implements, in `FleetKit` where it can be tested:

- claude, count > 0 → "1 subagent" / "N subagents"
- claude, count == 0 → nothing (it really is none)
- codex, any count → **nothing, ever** — never "0 subagents", which asserts a fact nobody has

Task 2 is that rule and its mutation test. `SessionStatusGlyph` already renders `subagentCount` beside the busy spinner and shows nothing at 0, so it is already correct by accident; Task 2 makes it correct on purpose and shares one implementation with the timeline header.

## Global Constraints

- **`FleetKit` imports Foundation, Network, Security, CryptoKit and `BoringSSLShim` only.** No SwiftUI, no UIKit, no Observation. Tasks 1 and 2 add types to `FleetKit`; the `FleetKitiOS` target is what enforces the boundary.
- **`FleetKit` and `FlightDeckMobile` build in Swift 6 language mode.** The rest of the project is Swift 5. `SWIFT_VERSION: "5.0"` in `project.yml`'s `settings.base` is deliberate — do not "fix" it.
- **Every new `FlightDeckMobile` file goes directly in `Sources/FlightDeckMobile/`, never a subdirectory.** `project.yml`'s source entry is recursive, but `scripts/build-ios.sh`'s fallback type-check globs `Sources/FlightDeckMobile/*.swift` — a file in a subdirectory is silently unchecked on any machine without an iOS platform installed, which is the machine this was written on.
- **Sessions are keyed on the tab `id`, never `conversationId`.** `FleetListScreen`'s `ForEach` already says so; the navigation value this plan adds carries the same id.
- **Every `Text` names its own font.** `List { … }.font(…)` does not reach row content — some rows inherited it and their neighbours did not, in the same list, which is what sent an earlier version of `FleetListScreen` back from testing. See that file's `row(_:)` comment.
- **`wait(for:)` deadlocks in a `@MainActor` async XCTest method** under this repo's headless harness. Use `await fulfillment(of:timeout:)`.
- **`Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift` and `Sources/FlightDeck/Fleet/FleetService.swift` are being edited by other agents.** This plan touches neither.
- **Never run `./scripts/smoke.sh`.** It seizes the foreground and turns the user's keystrokes into phantom failures.
- **A debug Mac instance and an iOS Simulator may be live.** Check `pgrep -f "harness/Flight Deck.app"` before the suite, and never launch a build to "try it".
- **Verification per task:** `./scripts/test-unit.sh` (baseline **1299** after the preceding plan, 0 failures) and `./scripts/build-ios.sh` (three `BUILD SUCCEEDED`). Report the count after every task.
- **This branch's standing bar: every test must be shown to fail against the bug it exists for.** Seven have shipped here unable to do that. Tasks 1 and 2 carry named mutations. Tasks 3–7 are largely SwiftUI and mostly *cannot* carry unit tests, which is exactly why their verification is `docs/MOBILE.md` items with observable outcomes — and why as much logic as possible was pushed into Tasks 1 and 2 where it can be proven.

## File Structure

**Created — `Sources/FleetKit/`:**

| File | Responsibility |
|---|---|
| `TimelineFeed.swift` | The pagination state machine: merge a page, dedupe, order, track cursors, handle `reset`. A value type with no I/O. |
| `SubagentSummary.swift` | The per-agent sub-agent rule, as a computed property on `WireSession`. |

**Created — `Sources/FlightDeckMobile/` (flat, see the constraints):**

| File | Responsibility |
|---|---|
| `SessionTimelineModel.swift` | `@Observable` shell: holds a `TimelineFeed`, asks `FleetModel` for pages, owns the poll. |
| `SessionTimelineScreen.swift` | The screen: the list, the load-older trigger, the working footer, the empty and error states. |
| `TimelineRow.swift` | One item, in the terminal idiom. |
| `TimelineItemDetailScreen.swift` | Full body, truncation disclosure, the paired call/result. |

**Modified:**

| File | Change |
|---|---|
| `Sources/FlightDeckMobile/FleetListScreen.swift` | Rows become navigation links; the "opening a session is slice 1b and does not exist" comment goes. |
| `Sources/FlightDeckMobile/FleetModel.swift` | `timelinePage(_:then:)`, forwarding to the connector. |
| `docs/MOBILE.md` | New checklist items for the timeline. |

**Test files created:** `Tests/FlightDeckTests/TimelineFeedTests.swift`, `Tests/FlightDeckTests/SubagentSummaryTests.swift`.

---

### Task 1: The pagination state machine

**Files:**
- Create: `Sources/FleetKit/TimelineFeed.swift`
- Test: `Tests/FlightDeckTests/TimelineFeedTests.swift`

**Interfaces:**
- Consumes: `TimelineItem`, `TimelinePage`, `TimelineAnchor` (preceding plan, Tasks 1–2).
- Produces: `TimelineFeed` (`items: [TimelineItem]`, `oldest: Int?`, `newest: Int?`, `hasOlder: Bool`, `hasLoadedAnything: Bool`), `TimelineFeed.merge(_ page: TimelinePage)`, `TimelineFeed.olderAnchor: TimelineAnchor?`, `TimelineFeed.newerAnchor: TimelineAnchor`.

This is in `FleetKit` and not in the app for the reason `FleetModel`'s own doc comment gives: the iOS target has no test host on this machine, so anything worth testing belongs where the unit suite can reach it. The merge is the part worth testing.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/TimelineFeedTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// What a screen holds while it pages: the items it has, in order, and the two cursors that
/// say what to ask for next.
///
/// Four properties are load-bearing, and each is a bug that looks like a rendering glitch
/// rather than a state bug — which is why they are tested here and not left to the screen:
/// a page merged twice must not double the rows, an older page must go on the FRONT, the
/// cursors must widen in both directions rather than being overwritten, and a `reset` page
/// must clear everything.
final class TimelineFeedTests: XCTestCase {
    private let session = UUID()

    private func item(_ id: String, _ text: String) -> TimelineItem {
        TimelineItem(id: id, kind: .assistantText, status: .complete,
                     body: TimelineItem.Body(text: text))
    }

    private func page(
        _ items: [TimelineItem], start: Int, end: Int,
        hasMore: Bool = false, reset: Bool = false
    ) -> TimelinePage {
        TimelinePage(session: session, items: items, start: start, end: end,
                     hasMore: hasMore, reset: reset)
    }

    func testAnEmptyFeedHasLoadedNothingAndAsksForTheLatest() {
        let feed = TimelineFeed()
        XCTAssertTrue(feed.items.isEmpty)
        XCTAssertFalse(feed.hasLoadedAnything)
        XCTAssertNil(feed.olderAnchor, "nothing has been loaded, so there is no cursor to "
                     + "page up from — the screen asks for .latest instead")
        XCTAssertEqual(feed.newerAnchor, .latest)
    }

    func testTheFirstPageBecomesTheFeed() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: true))
        XCTAssertEqual(feed.items.map(\.body.text), ["a", "b"])
        XCTAssertEqual(feed.oldest, 10)
        XCTAssertEqual(feed.newest, 30)
        XCTAssertTrue(feed.hasOlder)
        XCTAssertTrue(feed.hasLoadedAnything)
        XCTAssertEqual(feed.olderAnchor, .before(10))
        XCTAssertEqual(feed.newerAnchor, .after(30))
    }

    /// **An older page goes on the front.** Appending it instead puts the conversation's
    /// beginning underneath its end — which on screen reads as the agent answering before it
    /// was asked, and looks like a rendering bug rather than a merge bug.
    func testAnOlderPageIsPrepended() {
        var feed = TimelineFeed()
        feed.merge(page([item("30#0", "c")], start: 30, end: 40, hasMore: true))
        feed.merge(page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: false))
        XCTAssertEqual(feed.items.map(\.body.text), ["a", "b", "c"])
        XCTAssertEqual(feed.oldest, 10)
        XCTAssertEqual(feed.newest, 40, "a page above must not drag the newest cursor back")
        XCTAssertFalse(feed.hasOlder)
    }

    func testANewerPageIsAppended() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a")], start: 10, end: 20, hasMore: true))
        feed.merge(page([item("20#0", "b")], start: 20, end: 30))
        XCTAssertEqual(feed.items.map(\.body.text), ["a", "b"])
        XCTAssertEqual(feed.oldest, 10, "a page below must not drag the oldest cursor forward")
        XCTAssertEqual(feed.newest, 30)
        XCTAssertTrue(feed.hasOlder, "hasOlder is about the TOP of the feed and a page at the "
                      + "bottom says nothing about it")
    }

    /// **Dedupe.** The poll re-asks from `newest` and a screen re-entered re-asks for
    /// `.latest`, so overlapping pages are ordinary rather than exceptional. Ids are stable
    /// (they are byte offsets), which is what makes this possible at all.
    func testMergingTheSamePageTwiceChangesNothing() {
        var feed = TimelineFeed()
        let first = page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: true)
        feed.merge(first)
        feed.merge(first)
        XCTAssertEqual(feed.items.map(\.id), ["10#0", "20#0"])
        XCTAssertEqual(feed.oldest, 10)
        XCTAssertEqual(feed.newest, 30)
    }

    func testAPartiallyOverlappingPageAddsOnlyWhatIsNew() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: true))
        feed.merge(page([item("20#0", "b"), item("30#0", "c")], start: 20, end: 40))
        XCTAssertEqual(feed.items.map(\.id), ["10#0", "20#0", "30#0"])
    }

    /// A re-delivered item wins on content, not on arrival order: a body that was truncated
    /// by a page budget and arrives whole in a later page must replace the short one, not be
    /// discarded as a duplicate.
    func testARedeliveredItemReplacesTheOneHeld() {
        var feed = TimelineFeed()
        var short = item("10#0", "abc")
        short.body.truncatedBytes = 100
        feed.merge(page([short], start: 10, end: 20))
        feed.merge(page([item("10#0", "abcdef")], start: 10, end: 20))
        XCTAssertEqual(feed.items.map(\.body.text), ["abcdef"])
        XCTAssertEqual(feed.items[0].body.truncatedBytes, 0)
    }

    /// **`reset` clears everything.** Item ids are byte offsets into the transcript, so a
    /// replaced file makes every id the feed holds name a different record. Merging into it
    /// would interleave two conversations under matching ids — the exact failure the flag
    /// exists to prevent, and it would look like corruption rather than staleness.
    func testAResetPageEmptiesTheFeed() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a")], start: 10, end: 20, hasMore: true))
        feed.merge(page([], start: 0, end: 0, reset: true))
        XCTAssertTrue(feed.items.isEmpty)
        XCTAssertNil(feed.oldest)
        XCTAssertNil(feed.newest)
        XCTAssertFalse(feed.hasLoadedAnything, "the screen must fetch .latest again, not page "
                       + "from a cursor that has been declared meaningless")
        XCTAssertEqual(feed.newerAnchor, .latest)
    }

    /// An empty page from a poll is the ordinary case — nothing new since the last look —
    /// and must not read as "the conversation ended".
    func testAnEmptyNewerPageLeavesTheFeedAlone() {
        var feed = TimelineFeed()
        feed.merge(page([item("10#0", "a")], start: 10, end: 20, hasMore: true))
        feed.merge(page([], start: 20, end: 20))
        XCTAssertEqual(feed.items.map(\.id), ["10#0"])
        XCTAssertEqual(feed.newest, 20)
        XCTAssertTrue(feed.hasOlder)
    }

    /// Reaching the top is a fact the screen renders (no spinner, no further fetch), so it
    /// has to survive later pages arriving at the bottom.
    func testReachingTheTopStaysReachedAsNewerPagesArrive() {
        var feed = TimelineFeed()
        feed.merge(page([item("0#0", "a")], start: 0, end: 10, hasMore: false))
        XCTAssertFalse(feed.hasOlder)
        feed.merge(page([item("10#0", "b")], start: 10, end: 20, hasMore: true))
        XCTAssertFalse(feed.hasOlder, "hasMore on a page BELOW says nothing about the top")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `cannot find 'TimelineFeed' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FleetKit/TimelineFeed.swift`:

```swift
import Foundation

/// What a session screen holds while it pages, as a value type.
///
/// In `FleetKit` rather than in the phone app for the reason `FleetModel`'s doc comment
/// gives: the iOS target has no test host on this machine, so anything worth testing belongs
/// where the unit suite can reach it. This is the part worth testing — the merge, the
/// dedupe, and the two cursors — and the app's `@Observable` shell over it is glue.
///
/// The same division `FleetSnapshot.apply(_:)` and `FleetModel` already use.
public struct TimelineFeed: Equatable, Sendable {
    /// Oldest first, always, whichever direction the page that delivered them was fetched in.
    public private(set) var items: [TimelineItem] = []
    /// The `start` of the oldest page held. `nil` until something is loaded.
    public private(set) var oldest: Int?
    /// The `end` of the newest page held. `nil` until something is loaded.
    public private(set) var newest: Int?
    /// Whether anything precedes `oldest`. Purely about the TOP of the feed: a page arriving
    /// at the bottom says nothing about it, and letting one overwrite this is how a feed
    /// starts offering to load older items it has already reached the end of.
    public private(set) var hasOlder = false

    /// Membership index, so a merge is linear rather than quadratic. A long session's feed
    /// runs to thousands of items and the poll merges into it every couple of seconds.
    private var positions: [String: Int] = [:]

    public init() {}

    /// Whether anything has been fetched at all. Distinguishes "still loading" from "this
    /// conversation is empty", which are the same empty list and different screens.
    public var hasLoadedAnything: Bool { oldest != nil }

    /// What to ask for to page up. `nil` when nothing has been loaded — the screen asks for
    /// `.latest` then — and the screen must also check `hasOlder` before using it.
    public var olderAnchor: TimelineAnchor? { oldest.map { .before($0) } }

    /// What to ask for to pick up whatever has been appended. `.latest` before anything is
    /// loaded, which is exactly what opening a session wants.
    public var newerAnchor: TimelineAnchor { newest.map { .after($0) } ?? .latest }

    public mutating func merge(_ page: TimelinePage) {
        // The transcript this feed's cursors came from is gone. Item ids ARE byte offsets, so
        // every id held now names a different record: merging would interleave two
        // conversations under matching ids, which reads as corruption rather than staleness.
        // Discard, and let the screen start again from `.latest`.
        guard !page.reset else {
            self = TimelineFeed()
            return
        }

        // Older or newer is decided by the CURSORS, not by whether the items look old:
        // an empty page carries no items to compare and is the ordinary result of a poll.
        let isOlder = oldest.map { page.start < $0 } ?? false

        varfresh = [TimelineItem]()
        for item in page.items {
            if let at = positions[item.id] {
                // Re-delivered. Replaced rather than skipped: a body truncated by one page's
                // budget and delivered whole by another must not lose to arrival order.
                items[at] = item
            } else {
                fresh.append(item)
            }
        }
        if isOlder {
            items.insert(contentsOf: fresh, at: 0)
            reindex()
        } else {
            let base = items.count
            items.append(contentsOf: fresh)
            for (offset, item) in fresh.enumerated() { positions[item.id] = base + offset }
        }

        // Each cursor only ever widens. A page fetched above must not drag `newest` back, and
        // one fetched below must not drag `oldest` forward — either would make the next fetch
        // re-request a range the feed already holds, forever.
        oldest = min(oldest ?? page.start, page.start)
        newest = max(newest ?? page.end, page.end)
        // `hasMore` is only about the direction the page was fetched in, so it is only ever
        // believed for an older page — or for the very first one, which is also the top of
        // what the feed knows.
        if isOlder || !hasLoadedAnythingBefore { hasOlder = page.hasMore }
        hasLoadedAnythingBefore = true
    }

    /// Whether `merge` has run at all. Separate from `hasLoadedAnything`, which is about
    /// cursors: the first merge may be an empty page, which sets cursors and no items.
    private var hasLoadedAnythingBefore = false

    private mutating func reindex() {
        positions.removeAll(keepingCapacity: true)
        for (at, item) in items.enumerated() { positions[item.id] = at }
    }
}
```

- [ ] **Step 4: Run the tests, then prove four of them can fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1310 tests.

| Test | Mutation | Expected failure |
|---|---|---|
| `testAnOlderPageIsPrepended` | change the `isOlder` branch to `items.append(contentsOf: fresh)` | `["c", "a", "b"]` — the conversation's beginning under its end |
| `testMergingTheSamePageTwiceChangesNothing` | drop the `positions[item.id]` check and always append | `["10#0", "20#0", "10#0", "20#0"]` |
| `testAResetPageEmptiesTheFeed` | delete the `guard !page.reset` block | the stale item survives |
| `testReachingTheTopStaysReachedAsNewerPagesArrive` | set `hasOlder = page.hasMore` unconditionally | `XCTAssertFalse failed` — the feed offers to load older items above the top it already reached |

Record all four.

- [ ] **Step 5: Verify the iOS boundary and commit**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`

```bash
git add Sources/FleetKit/TimelineFeed.swift Tests/FlightDeckTests/TimelineFeedTests.swift
git commit -m "feat: hold a paging timeline as a value type

In FleetKit rather than the phone app for the reason FleetModel already
documents: the iOS target has no test host on this machine, so the part
worth testing has to live where the unit suite can reach it. Same
division FleetSnapshot.apply and FleetModel already use.

Four properties, each a bug that would look like a rendering glitch. An
older page is PREPENDED — appending puts the conversation's beginning
under its end, which reads as the agent answering before it was asked.
Items dedupe by id, because overlapping pages are ordinary: the poll
re-asks from the newest cursor and a re-entered screen re-asks for the
latest. Each cursor only widens, so a page fetched above cannot drag the
newest back and re-request a range the feed already holds. And hasOlder
is only ever believed for a page fetched upwards, or the feed offers to
load older items above a top it has already reached.

A reset page clears everything. Item ids are byte offsets, so a replaced
transcript makes every held id name a different record — merging would
interleave two conversations under matching ids.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The sub-agent asymmetry, stated once

**Files:**
- Create: `Sources/FleetKit/SubagentSummary.swift`
- Modify: `Sources/FlightDeckMobile/SessionStatusGlyph.swift` (use the shared rule)
- Test: `Tests/FlightDeckTests/SubagentSummaryTests.swift`

**Interfaces:**
- Consumes: `WireSession` (shipped).
- Produces: `WireSession.subagentSummary: String?`.

**Read the preceding plan's findings §3 first.** §6 has this asymmetry backwards: claude has a real count, codex has nothing and `subagentCount` is deliberately never emitted for it. `0` on a codex tab means *unknown*, not *none*.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/SubagentSummaryTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// The one place the sub-agent asymmetry is decided, so the list glyph and the timeline
/// header cannot disagree about it.
///
/// Spec §6 says "a count for claude, per-sub-agent for codex". The code says the reverse:
/// `TranscriptWatcher` counts claude's outstanding top-level `Agent` tool calls, while
/// `CodexEventMapper` states that no `collab` record exists in any surveyed rollout and that
/// `subagentCount` is deliberately never emitted for codex. Re-checked across 494 rollouts
/// on the build machine: still nothing.
///
/// **So a codex tab's `0` means unknown, not none**, and saying "0 subagents" would assert a
/// fact nobody has. That is the whole point of this file.
final class SubagentSummaryTests: XCTestCase {
    private func session(agent: String, subagents: Int) -> WireSession {
        WireSession(id: UUID(), title: "t", agent: agent, activity: "busy",
                    subagentCount: subagents)
    }

    func testClaudeReportsItsCount() {
        XCTAssertEqual(session(agent: "claude", subagents: 3).subagentSummary, "3 subagents")
    }

    func testClaudeSingularizesAtOne() {
        XCTAssertEqual(session(agent: "claude", subagents: 1).subagentSummary, "1 subagent")
    }

    func testClaudeAtZeroSaysNothingBecauseThereReallyAreNone() {
        XCTAssertNil(session(agent: "claude", subagents: 0).subagentSummary)
    }

    /// The load-bearing case. Codex has no sub-agent ground truth at all, so the honest
    /// answer is silence — never "0 subagents", which would claim none are running when the
    /// truth is that nobody knows.
    func testCodexSaysNothingEvenAtZero() {
        XCTAssertNil(session(agent: "codex", subagents: 0).subagentSummary)
    }

    /// And nothing at a non-zero count either. Nothing produces one today; if something
    /// starts to, this fails and whoever changed it has to decide what codex's count MEANS
    /// before it reaches a screen.
    func testCodexSaysNothingAtANonZeroCountEither() {
        XCTAssertNil(session(agent: "codex", subagents: 4).subagentSummary)
    }

    /// An agent this build has never heard of gets the same silence for the same reason:
    /// `WireSession.agent` is a String precisely so a newer Mac's agent renders without a
    /// glyph rather than taking the snapshot down, and inventing a count for it would be the
    /// same mistake as inventing one for codex.
    func testAnUnknownAgentSaysNothing() {
        XCTAssertNil(session(agent: "goose", subagents: 2).subagentSummary)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | tail -30`
Expected: compile failure — `value of type 'WireSession' has no member 'subagentSummary'`.

- [ ] **Step 3: Write the implementation**

Create `Sources/FleetKit/SubagentSummary.swift`:

```swift
import Foundation

extension WireSession {
    /// How many sub-agents this session is running, said out loud — or `nil` when nobody
    /// knows, which is not the same as zero.
    ///
    /// **The spec has this asymmetry backwards, and the difference is a claim about the
    /// world.** §6 says "a count for claude, per-sub-agent for codex". In fact
    /// `TranscriptWatcher` maintains a real count of claude's outstanding top-level `Agent`
    /// tool calls, while `CodexEventMapper`'s doc comment records that no `collab` record
    /// exists in any of 492 surveyed rollouts and that `subagentCount` is *deliberately never
    /// emitted for codex*. Re-checked across 494 rollouts: still nothing.
    ///
    /// So a codex tab's `subagentCount` is always `0`, and `0` there means **unknown**.
    /// Rendering "0 subagents" would assert that none are running, which nobody has any
    /// grounds to say. Silence is the honest answer, and it is the same answer an agent this
    /// build has never heard of gets — `agent` is a `String` precisely so a newer Mac's agent
    /// degrades to "renders without a glyph" rather than taking the snapshot down, and
    /// inventing a count for it would be the same mistake.
    ///
    /// One implementation, shared by the list's status glyph and the timeline's header, so
    /// the two screens cannot come to different conclusions about the same session.
    public var subagentSummary: String? {
        // Only claude has ground truth here. Add an agent to this list when — and only
        // when — something actually emits a count for it.
        guard agent == "claude", subagentCount > 0 else { return nil }
        return "\(subagentCount) subagent\(subagentCount == 1 ? "" : "s")"
    }
}
```

In `Sources/FlightDeckMobile/SessionStatusGlyph.swift`, replace the `busy` branch's inline count and its `busyLabel` with the shared rule:

```swift
        case "busy":
            glyph(
                HStack(spacing: 2) {
                    ProgressView().controlSize(.mini)
                    // Through `subagentSummary` rather than off `subagentCount` directly, so
                    // this column and the timeline header cannot disagree: a codex tab's 0
                    // means "unknown", and neither screen may render it as "none".
                    if session.subagentSummary != nil {
                        Text("\(session.subagentCount)").font(.caption2.monospacedDigit())
                    }
                },
                label: busyLabel
            )
```

```swift
    /// `SessionStatus.tooltip`'s `.busy` branch. The count comes from `subagentSummary`, which
    /// is nil for codex at any count — see that property.
    private var busyLabel: String {
        guard let summary = session.subagentSummary else { return "Working" }
        return "Working — \(summary)"
    }
```

- [ ] **Step 4: Run the tests, then prove the codex case can fail**

Run: `./scripts/test-unit.sh 2>&1 | tail -20`
Expected: PASS, 1316 tests.

Mutation: drop the agent check —

```swift
        guard subagentCount > 0 else { return nil }
```

Run: `./scripts/test-unit.sh 2>&1 | grep -A3 testCodexSaysNothingAtANonZeroCount`
Expected: **FAIL** — `XCTAssertNil failed: "4 subagents"`. Note that `testCodexSaysNothingEvenAtZero` still *passes* under this mutation, because the count guard alone happens to cover it: that is why both cases exist, and it is a small worked example of a test that looks like it guards a rule and does not. Revert and re-run to green; record both.

- [ ] **Step 5: Verify the iOS boundary and commit**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`

```bash
git add Sources/FleetKit/SubagentSummary.swift Sources/FlightDeckMobile/SessionStatusGlyph.swift \
        Tests/FlightDeckTests/SubagentSummaryTests.swift
git commit -m "fix: say nothing about codex sub-agents instead of saying zero

The spec has this asymmetry backwards. It says a count for claude and
per-sub-agent state for codex; in fact TranscriptWatcher keeps a real
count of claude's outstanding top-level Agent calls, and CodexEventMapper
records that no collab record exists in any surveyed rollout and that
subagentCount is deliberately never emitted for codex. Re-checked across
494 rollouts here: still nothing.

So a codex tab's 0 means UNKNOWN, and rendering '0 subagents' would
assert that none are running, which nobody has grounds to say. Silence is
the honest answer, and an agent this build has never heard of gets it for
the same reason WireSession.agent is a String.

One implementation on WireSession, shared by the list's status glyph and
the timeline header that follows, so two screens cannot reach different
conclusions about the same session.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Asking for a page from the phone

**Files:**
- Modify: `Sources/FlightDeckMobile/FleetModel.swift`
- Create: `Sources/FlightDeckMobile/SessionTimelineModel.swift`

**Interfaces:**
- Consumes: `FleetConnector.request(_:then:)`, `FleetRequest`, `TimelinePage`, `FleetRequestError` (preceding plan, Task 9); `TimelineFeed` (Task 1).
- Produces: `FleetModel.timelinePage(_ request: FleetRequest, then: @escaping (Result<TimelinePage, FleetRequestError>) -> Void)`, `SessionTimelineModel` (`feed: TimelineFeed`, `phase: Phase`, `sessionID: UUID`, `loadLatest()`, `loadOlder()`, `loadNewer()`).

There is no unit test in this task and that is a deliberate consequence of Task 1, not a gap: everything with a decision in it — the merge, the cursors, the dedupe — is in `TimelineFeed` and is covered. What is left here is forwarding and a small state enum, and the verification is `./scripts/build-ios.sh` plus Task 7's checklist. Resist moving logic back into this file; if something here starts to deserve a test, it belongs in `TimelineFeed`.

- [ ] **Step 1: Add the forwarding on `FleetModel`**

In `Sources/FlightDeckMobile/FleetModel.swift`, beside `markRead(_:)`:

```swift
    /// Ask the Mac for a page of a session's conversation.
    ///
    /// Forwarded rather than absorbed: the connector answers **exactly once**, including with
    /// `.disconnected` when nothing is connected or the socket dies mid-fetch, and adding a
    /// layer that could swallow that would put a spinner on screen forever with nothing to
    /// explain it. This model's job is to hand the callback through unchanged.
    func timelinePage(
        _ request: FleetRequest,
        then completion: @escaping (Result<TimelinePage, FleetRequestError>) -> Void
    ) {
        guard let connector else { return completion(.failure(.disconnected)) }
        connector.request(request, then: completion)
    }
```

- [ ] **Step 2: Write the screen's model**

Create `Sources/FlightDeckMobile/SessionTimelineModel.swift`:

```swift
import FleetKit
import Foundation
import Observation

/// One open session screen.
///
/// Thin on purpose, in the same spirit as `FleetModel`: it owns a `TimelineFeed` — which is
/// in `FleetKit` and unit-tested — plus the three things a screen genuinely adds, which are
/// *which* fetch is in flight, whether one already is, and what to say when one fails.
/// Anything here that starts to deserve a test belongs in `TimelineFeed` instead.
@MainActor
@Observable
final class SessionTimelineModel {
    /// What the screen draws when the feed is empty, and what it draws at the top while
    /// paging. Deliberately not a bare `isLoading` flag: "still loading", "this conversation
    /// is empty", and "the Mac refused" are the same empty list and three different screens,
    /// and collapsing them is how an empty state ends up claiming a session has no history
    /// when the fetch simply failed.
    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    let sessionID: UUID

    private(set) var feed = TimelineFeed()
    private(set) var phase = Phase.idle
    /// Whether a page fetched upwards is in flight, so the scroll trigger cannot fire five
    /// times while the first one is still reading.
    private(set) var isLoadingOlder = false

    @ObservationIgnored private let fleet: FleetModel
    /// Guards every fetch. Two overlapping requests would merge out of order, and — worse —
    /// both would be computed from the same cursor, so the second would re-fetch what the
    /// first had already added.
    @ObservationIgnored private var isFetching = false

    init(sessionID: UUID, fleet: FleetModel) {
        self.sessionID = sessionID
        self.fleet = fleet
    }

    /// The screen's first fetch, and its recovery after a `reset`.
    func loadLatest() {
        fetch(anchor: .latest, older: false)
    }

    /// Called when the top of the list comes into view.
    func loadOlder() {
        guard feed.hasOlder, let anchor = feed.olderAnchor else { return }
        fetch(anchor: anchor, older: true)
    }

    /// Called by the poll and by a fleet event for this session. Quiet: it does not touch
    /// `phase`, because a background poll that fails must not replace a screen full of
    /// conversation with an error — the connection banner on the list already says the phone
    /// is offline, and this screen's content is still the last thing the Mac said.
    func loadNewer() {
        guard feed.hasLoadedAnything else { return loadLatest() }
        fetch(anchor: feed.newerAnchor, older: false, quiet: true)
    }

    private func fetch(anchor: TimelineAnchor, older: Bool, quiet: Bool = false) {
        guard !isFetching else { return }
        isFetching = true
        if older { isLoadingOlder = true }
        if !quiet, !feed.hasLoadedAnything { phase = .loading }

        fleet.timelinePage(
            .timeline(session: sessionID, anchor: anchor, limit: TimelineLimits.defaultLimit)
        ) { [weak self] result in
            guard let self else { return }
            self.isFetching = false
            self.isLoadingOlder = false
            switch result {
            case .success(let page):
                self.feed.merge(page)
                self.phase = .idle
                // A reset emptied the feed: the transcript these cursors came from is gone,
                // so start again from the end rather than leaving a blank screen that will
                // never fill in.
                if page.reset { self.loadLatest() }
            case .failure(let error):
                guard !quiet else { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    /// Copy, not a code. Each of these is a different thing for the reader to do about it,
    /// which is why the wire distinguishes them at all.
    private static func message(for error: FleetRequestError) -> String {
        switch error {
        case .disconnected:
            return "Not connected to your Mac."
        case .server(let code):
            switch code {
            case "unknown_session":
                return "This session is no longer open on your Mac."
            case "no_transcript":
                return "This agent doesn't keep a transcript, so there's nothing to show."
            case "unreadable":
                return "Nothing here yet — this session hasn't taken its first turn."
            default:
                return "Your Mac couldn't read this session (\(code))."
            }
        }
    }
}
```

- [ ] **Step 3: Verify it compiles for iOS**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`
Expected: three successes.

Note the constraint if it fails to be found at all: the file must be **directly** in `Sources/FlightDeckMobile/`. The fallback type-check globs `Sources/FlightDeckMobile/*.swift`, so a file in a subdirectory is silently unchecked on a machine with no iOS platform installed.

- [ ] **Step 4: Run the unit suite**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: 1316 tests, 0 failures — unchanged. This task adds no macOS code.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeckMobile/FleetModel.swift \
        Sources/FlightDeckMobile/SessionTimelineModel.swift
git commit -m "feat: ask the Mac for a page from the phone

The model for one open session: a TimelineFeed, which fetch is in flight,
and what to say when one fails. Everything with a decision in it is in
TimelineFeed and unit-tested; what is left here is forwarding, and if
anything here starts to deserve a test it belongs there instead.

Three things are deliberate. A single in-flight guard, because two
overlapping fetches would both be computed from the same cursor and the
second would re-fetch what the first had just added. A phase enum rather
than an isLoading flag, because 'still loading', 'this conversation is
empty' and 'the Mac refused' are the same empty list and three different
screens. And loadNewer is QUIET — a background poll that fails must not
replace a screen full of conversation with an error, since the content is
still the last thing the Mac said and the list's own banner already says
the phone is offline.

A reset page re-fetches the latest rather than leaving a blank screen
that will never fill in.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Opening a session

**Files:**
- Create: `Sources/FlightDeckMobile/SessionTimelineScreen.swift`
- Modify: `Sources/FlightDeckMobile/FleetListScreen.swift`

**Interfaces:**
- Consumes: `SessionTimelineModel` (Task 3), `WireSession.subagentSummary` (Task 2).
- Produces: `SessionTimelineScreen(session:model:)`.

This is the task the whole slice is named for. `FleetListScreen`'s current comment says it out loud:

> Every row used to be one, which meant every row highlighted under a finger and absorbed the touch — and then did nothing… Opening a session is slice 1b and does not exist. Twice the report came back as "tapping sessions does nothing".

That comment is now wrong and must go with the change, per the house rule about auditing stale comments when behaviour changes.

- [ ] **Step 1: Write the screen**

Create `Sources/FlightDeckMobile/SessionTimelineScreen.swift`:

```swift
import FleetKit
import SwiftUI

/// One session's conversation. The second of spec §7's three screens.
///
/// **Nothing here implies streaming, for either agent**, and that is a decision rather than
/// an omission. Both agents are read from files they write and neither writes token deltas —
/// see the plan's asymmetry §1. So there is no caret, no fading last row, and no typing
/// animation. What the screen does show is the truth it has: when the session's `activity` is
/// `busy`, a footer says the agent is working and the feed polls. That is a claim about the
/// SESSION, which is live, rather than about the last row, which is finished.
struct SessionTimelineScreen: View {
    /// Read from the live fleet rather than captured at push time, so a title change, a
    /// status change or the session closing while this screen is open is visible here too.
    let session: WireSession?
    let model: SessionTimelineModel

    var body: some View {
        List {
            if model.feed.hasOlder {
                loadOlderRow
            }
            ForEach(model.feed.items) { item in
                NavigationLink(value: item) {
                    TimelineRow(item: item)
                }
                .listRowInsets(Self.rowInsets)
            }
            footer
        }
        .listStyle(.plain)
        // `.plain` HERE, unlike the fleet list, and the reason is the content rather than
        // taste: this list is prose and command output in a monospaced face, and
        // inset-grouped's card edges cut every line short and put a rounded corner through
        // the middle of a diff. The fleet list's own comment explains why IT keeps
        // inset-grouped; the two screens differ because what they hold differs.
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: TimelineItem.self) { item in
            TimelineItemDetailScreen(item: item, result: pairedResult(for: item))
        }
        .task(id: model.sessionID) { model.loadLatest() }
    }

    private static let rowInsets = EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)

    /// A button, not an `onAppear` trigger. An automatic fetch on the top row appearing fires
    /// again on every bounce of an over-scroll and, worse, fires while the list is still
    /// settling after the previous page was inserted — so the reader is dragged upward by
    /// content arriving above them. An explicit tap costs one gesture and puts the reader in
    /// charge of where they are.
    private var loadOlderRow: some View {
        Button {
            model.loadOlder()
        } label: {
            HStack {
                Spacer()
                if model.isLoadingOlder {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Load earlier").font(.footnote)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .listRowInsets(Self.rowInsets)
    }

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowInsets(Self.rowInsets)
        case .failed(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .listRowInsets(Self.rowInsets)
        case .idle:
            if model.feed.items.isEmpty {
                // Distinct from `.loading` above: the fetch succeeded and there was nothing
                // in it. Saying "no messages yet" while a fetch is still running is how an
                // empty state ends up lying about a session that has plenty of history.
                Text("No messages yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowInsets(Self.rowInsets)
            } else if let working = workingFooter {
                working
            }
        }
    }

    /// The only live affordance on the screen, and it is about the session, not the last row.
    /// `subagentSummary` is nil for codex at any count — see that property; a codex `0` means
    /// unknown, and this must not turn it into "0 subagents".
    @ViewBuilder
    private var workingFooter: some View {
        if session?.activity == "busy" {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(session?.subagentSummary.map { "Working — \($0)" } ?? "Working")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowInsets(Self.rowInsets)
        } else if session?.activity == "waiting" {
            Label(
                session?.waitingFor.map { "Waiting for you — \($0)" } ?? "Waiting for you",
                systemImage: "questionmark.circle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
            .listRowInsets(Self.rowInsets)
        }
    }

    /// The result that answers a tool call, when the feed happens to hold it, so the detail
    /// screen can show a command and its output together. Matched on `callID` — the agent's
    /// own id — and never on `id`, which is a byte offset and pairs nothing.
    private func pairedResult(for item: TimelineItem) -> TimelineItem? {
        guard item.kind == .toolCall, let callID = item.body.callID else { return nil }
        return model.feed.items.first { $0.kind == .toolResult && $0.body.callID == callID }
    }
}
```

- [ ] **Step 2: Route to it from the list**

In `Sources/FlightDeckMobile/FleetListScreen.swift`, replace `sessionRow(_:)` and its doc comment:

```swift
    /// Every row opens its session. `markRead` rides along on the same tap for an unread one
    /// — spec §8 makes unread one fleet-wide fact, and opening a session on the phone is
    /// exactly the "I have looked at this" the mark means.
    ///
    /// This used to be a `Button` only for an unread row, because tapping a read one had
    /// nothing to do: a control that looks live and is not is what produced "tapping sessions
    /// does nothing" twice in testing. Now there is something to do, so every row is a link
    /// — including while disconnected, where the timeline shows what it last held and says
    /// so, rather than the row being inert with no explanation.
    private func sessionRow(_ session: WireSession) -> some View {
        NavigationLink(value: session.id) {
            row(session)
        }
        .listRowInsets(Self.rowInsets)
        .simultaneousGesture(TapGesture().onEnded {
            guard isConnected, session.isUnread else { return }
            model.markRead(session.id)
            justMarkedRead = session.id
        })
    }
```

and add the destination to the `List`, beside `.refreshable`:

```swift
            .navigationDestination(for: UUID.self) { id in
                // Looked up live rather than captured, so a rename or a status change on the
                // Mac reaches the open screen, and closing the session on the Mac leaves the
                // screen able to say so. Keyed on the tab id, never the conversation id.
                SessionTimelineScreen(
                    session: model.fleet.projects
                        .flatMap(\.sessions).first { $0.id == id },
                    model: model.timelineModel(for: id)
                )
            }
```

In `FleetModel`, add the cache the destination needs:

```swift
    /// One model per open session, kept so that going back and forward again does not
    /// re-download a page the phone already holds. Keyed on the tab id.
    @ObservationIgnored private var timelineModels: [UUID: SessionTimelineModel] = [:]

    func timelineModel(for id: UUID) -> SessionTimelineModel {
        if let existing = timelineModels[id] { return existing }
        let model = SessionTimelineModel(sessionID: id, fleet: self)
        timelineModels[id] = model
        return model
    }
```

and clear it in `unpair()`, beside `fleet = .empty`:

```swift
        fleet = .empty
        // Held conversation content is as much "this pairing" as the snapshot is. A phone
        // that unpaired and kept a session's transcript in memory is showing the user
        // something they believe they revoked.
        timelineModels.removeAll()
```

- [ ] **Step 3: Add the row and detail screens as stubs so this compiles**

`TimelineRow` and `TimelineItemDetailScreen` are Tasks 5 and 6. To keep this task independently reviewable, create both now with a minimal body and finish them there:

`Sources/FlightDeckMobile/TimelineRow.swift`:

```swift
import FleetKit
import SwiftUI

/// One timeline item. Task 5 gives it the terminal idiom.
struct TimelineRow: View {
    let item: TimelineItem

    var body: some View {
        Text(item.body.summary ?? item.body.text)
            .font(.system(.body, design: .monospaced))
            .lineLimit(3)
    }
}
```

`Sources/FlightDeckMobile/TimelineItemDetailScreen.swift`:

```swift
import FleetKit
import SwiftUI

/// The third of spec §7's screens. Task 6 gives it the full body and the truncation notice.
struct TimelineItemDetailScreen: View {
    let item: TimelineItem
    let result: TimelineItem?

    var body: some View {
        ScrollView {
            Text(item.body.text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
```

`TimelineItem` must be `Hashable` for `NavigationLink(value:)` and `navigationDestination(for:)`. It is `Equatable` already; add `Hashable` conformance to it and to `TimelineItem.Body`, `Kind` and `Status` in `Sources/FleetKit/Timeline.swift` — all are value types over `String`/`Int`/`Bool`, so the synthesized conformance is correct and free.

- [ ] **Step 4: Build and run it in the simulator**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`
Then follow `docs/MOBILE.md`'s boot/install/pair sequence and confirm, by looking at it:

1. Tapping any session row pushes a screen with that session's title in the bar.
2. The screen fills with the tail of the conversation.
3. "Load earlier" appears above it and adds older items when tapped, without moving the reader.
4. Going back and forward again does not re-fetch (the content is already there).
5. Tapping an unread row still clears its dot on the Mac.

Record what you saw. **Do not run `./scripts/smoke.sh`.**

- [ ] **Step 5: Run the unit suite and commit**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: 1316 tests, 0 failures.

```bash
git add Sources/FlightDeckMobile/SessionTimelineScreen.swift \
        Sources/FlightDeckMobile/TimelineRow.swift \
        Sources/FlightDeckMobile/TimelineItemDetailScreen.swift \
        Sources/FlightDeckMobile/FleetListScreen.swift \
        Sources/FlightDeckMobile/FleetModel.swift \
        Sources/FleetKit/Timeline.swift
git commit -m "feat: tapping a session opens it

The thing the fleet list has been promising since slice 1a, and whose
absence came back from testing twice as 'tapping sessions does nothing'.
Every row is a link now, and markRead rides the same tap for an unread
one — §8 makes unread one fleet-wide fact, and opening a session on the
phone is exactly what the mark means.

Nothing on the screen implies streaming, for either agent, and that is a
decision. Both agents are read from files they write and neither writes
token deltas, so there is no caret and no typing animation. What it shows
instead is a footer about the SESSION — working, or waiting for you —
which is live and true, rather than an affordance on the last row, which
is finished.

'Load earlier' is a button rather than an appear-trigger. An automatic
fetch fires again on every over-scroll bounce and while the list is still
settling after the previous insert, which drags the reader upward by
content arriving above them.

The session is read live out of the fleet rather than captured at push
time, so a rename or a status change on the Mac reaches an open screen.
Unpairing drops held conversations: a phone that kept a transcript in
memory after unpairing is showing the user something they believe they
revoked.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The terminal idiom

**Files:**
- Modify: `Sources/FlightDeckMobile/TimelineRow.swift`

**Interfaces:**
- Consumes: `TimelineItem` (preceding plan, Task 1).
- Produces: nothing new.

Spec §7: "The timeline renders in the terminal's own idiom (monospace, the terminal palette, `⏺`/`⎿` shapes) rather than as chat bubbles."

- [ ] **Step 1: Write the row**

Replace `Sources/FlightDeckMobile/TimelineRow.swift` in full:

```swift
import FleetKit
import SwiftUI

/// One timeline item, in the terminal's own idiom rather than as a chat bubble (spec §7).
///
/// The shapes are claude's own — `⏺` marks a tool call, `⎿` marks what came back — and they
/// are used here for the same reason `SessionStatusGlyph` reuses the Mac's status symbols
/// verbatim: someone reading this screen has been reading the same conversation in a terminal
/// all day, and a second vocabulary for the same thing costs them a translation on every row.
///
/// **No kind renders as streaming**, including `.streaming` itself. Nothing emits it — both
/// agents are read from files that carry whole records — so a distinct rendering would be
/// dead code that quietly implies the timeline can show a live cursor, which it cannot. If a
/// streaming source ever lands, this is where it becomes visible, and it will be a rendering
/// change rather than a redesign.
struct TimelineRow: View {
    let item: TimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            marker
            content
            Spacer(minLength: 0)
        }
    }

    /// Fixed width so the text column cannot ragged from one row to the next — the same
    /// problem, and the same fix, as `SessionStatusGlyph.glyph(_:label:)`.
    @ViewBuilder
    private var marker: some View {
        Group {
            switch item.kind {
            case .userTurn:
                Text(">").foregroundStyle(.secondary)
            case .assistantText:
                Text("⏺").foregroundStyle(.primary)
            case .thinking:
                Text("✻").foregroundStyle(.secondary)
            case .toolCall:
                Text("⏺").foregroundStyle(.green)
            case .toolResult:
                Text("⎿").foregroundStyle(item.body.isError ? .red : .secondary)
            case .prompt:
                // Slice 2 (§9) is what emits these. Rendered now, from nothing, so that
                // shipping the broker is a Mac-side change: a phone built today shows a
                // pending prompt as a prompt rather than as an unrecognised row.
                Text("?").foregroundStyle(.orange)
            case .unknown:
                // A kind this build has not heard of, from a newer Mac. It renders as
                // *something* for the same reason `WireSession.agent` is a String — see
                // `TimelineItem.Kind`.
                Text("·").foregroundStyle(.secondary)
            }
        }
        .font(.system(.body, design: .monospaced))
        .frame(width: 14, alignment: .center)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let tool = item.body.tool {
                HStack(spacing: 6) {
                    Text(tool).font(.system(.body, design: .monospaced).weight(.semibold))
                    if let summary = item.body.summary {
                        Text(summary)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            if !previewText.isEmpty {
                Text(previewText)
                    // Every `Text` names its own font. `List { … }.font(…)` does not reach
                    // row content — some rows inherited it and their neighbours did not, in
                    // the same list, which is what sent `FleetListScreen` back from testing.
                    .font(.system(bodyStyle, design: .monospaced))
                    .foregroundStyle(bodyColor)
                    .lineLimit(item.kind == .userTurn ? nil : 6)
            }
            if item.body.truncatedBytes > 0 {
                // Said on the ROW and not only in the detail screen. A tool result cut at the
                // page budget looks exactly like a short one, and a reader who does not know
                // the output was cut will act on a partial file read as though it were whole.
                Text("+\(item.body.truncatedBytes) more bytes")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A tool CALL's body is its pretty-printed input, which is JSON and belongs on the detail
    /// screen — the row already shows the tool and the summary line above.
    private var previewText: String {
        item.kind == .toolCall ? "" : item.body.text
    }

    private var bodyStyle: Font.TextStyle {
        // Tool output is reference material and reads fine a size down; prose is what the
        // reader is actually here for.
        item.kind == .toolResult || item.kind == .thinking ? .footnote : .body
    }

    private var bodyColor: Color {
        switch item.kind {
        case .thinking: return .secondary
        case .toolResult: return item.body.isError ? .red : .secondary
        default: return .primary
        }
    }
}
```

- [ ] **Step 2: Build and look at it**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`

Then, in the simulator, against a session with a real mixed conversation, confirm by looking:

1. The marker column lines up down the whole list, across every kind.
2. A tool call shows `Bash` and its command on one line, middle-truncated, not wrapped.
3. A long tool result is clamped rather than filling the screen, and a truncated one says `+N more bytes`.
4. A user turn is not clamped — the whole prompt is readable in place.
5. Dynamic Type at its largest still lays out, with rows growing rather than text colliding.
6. Dark and light both read; nothing relies on a colour that vanishes in one of them.

Record what you saw, with a screenshot if the simulator will give one.

- [ ] **Step 3: Run the unit suite and commit**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: 1316 tests, 0 failures.

```bash
git add Sources/FlightDeckMobile/TimelineRow.swift
git commit -m "feat: render the timeline in the terminal's idiom, not as chat

Spec §7 asks for monospace and the terminal's own shapes rather than chat
bubbles, and the reason is the reader: someone opening this screen has
been reading the same conversation in a terminal all day, so ⏺ for a call
and ⎿ for what came back costs them no translation. Same reason
SessionStatusGlyph reuses the Mac's status symbols verbatim.

Truncation is said on the ROW, not only in the detail screen. A tool
result cut at the page budget looks exactly like a short one, and a
reader who does not know the output was cut will act on a partial file
read as though it were whole.

No kind renders as streaming, including .streaming itself. Nothing emits
it, so a distinct rendering would be dead code that quietly implies this
screen can show a live cursor. .prompt renders from nothing on purpose,
so slice 2's broker is a Mac-side change rather than a phone update.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: The item detail

**Files:**
- Modify: `Sources/FlightDeckMobile/TimelineItemDetailScreen.swift`

**Interfaces:**
- Consumes: `TimelineItem`, `TimelineLimits.maxItemBytes` (preceding plan, Tasks 1–2).
- Produces: nothing new.

Spec §7: "a tool row taps through to the full diff, full command output, or full file read."

What it can actually show is bounded by `TimelineLimits.maxItemBytes` (64 KB per item), which the preceding plan chose in preference to a second round trip for full bodies. This screen's job is to show all of what arrived **and be explicit about the rest** — the alternative, a screen that silently ends at 64 KB, is precisely the "presenting a partial file read as a whole one" failure the `truncatedBytes` field exists to prevent.

- [ ] **Step 1: Write the screen**

Replace `Sources/FlightDeckMobile/TimelineItemDetailScreen.swift` in full:

```swift
import FleetKit
import SwiftUI

/// The third of spec §7's screens: the whole of one item, and — for a tool call — what came
/// back from it.
///
/// **What "whole" means is stated on screen rather than assumed.** An item is capped at
/// `TimelineLimits.maxItemBytes` on the Mac, which covers essentially every command output
/// and most file reads and does not cover all of them. A screen that simply stopped at the
/// cap would be indistinguishable from one showing a complete result, which is exactly the
/// failure `Body.truncatedBytes` exists to prevent.
struct TimelineItemDetailScreen: View {
    let item: TimelineItem
    /// The result that answers this call, when the feed holds it. Paired on the agent's own
    /// `callID`, never on `id` — `id` is a byte offset and pairs nothing.
    let result: TimelineItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                block(title: item.body.tool.map { "\($0) input" } ?? title(for: item.kind),
                      item: item)
                if let result {
                    block(title: result.body.isError ? "Error" : "Output", item: result)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.body.tool ?? title(for: item.kind))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var header: some View {
        if let at = item.at {
            // The agent's own timestamp, verbatim off the wire and formatted here — the Mac
            // deliberately never parses it (see `TimelineItem.at`).
            Text(formatted(at) ?? at)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func block(title: String, item: TimelineItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(item.body.text.isEmpty ? "(empty)" : item.body.text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.body.truncatedBytes > 0 {
                truncationNotice(shown: item.body.text.utf8.count,
                                 dropped: item.body.truncatedBytes)
            }
        }
    }

    /// Says both numbers, because "truncated" alone does not tell a reader whether they are
    /// missing a line or a megabyte — and that is the difference between reading on and
    /// going to the Mac.
    private func truncationNotice(shown: Int, dropped: Int) -> some View {
        Label(
            "Showing the first \(bytes(shown)) of \(bytes(shown + dropped)). "
            + "Open this session on your Mac to see the rest.",
            systemImage: "scissors"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func title(for kind: TimelineItem.Kind) -> String {
        switch kind {
        case .userTurn: return "You"
        case .assistantText: return "Assistant"
        case .thinking: return "Thinking"
        case .toolCall: return "Tool call"
        case .toolResult: return "Tool result"
        case .prompt: return "Waiting for you"
        case .unknown: return "Unrecognized"
        }
    }

    /// `nil` rather than a fallback string when the timestamp does not parse: the header falls
    /// back to the raw text, which is at least what the agent wrote, instead of a formatted
    /// lie about a date nobody has.
    private func formatted(_ raw: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: raw) ?? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: raw)
        }() else { return nil }
        return date.formatted(date: .abbreviated, time: .standard)
    }
}
```

- [ ] **Step 2: Build and look at it**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`

In the simulator, confirm:

1. Tapping a `Bash` row shows the full command and the full output below it.
2. Text is selectable — a command a reader wants to copy is the obvious thing to want here.
3. A long output scrolls and does **not** scroll the page sideways; long unbroken lines wrap.
4. An item over 64 KB shows the scissors notice with two real byte counts.
5. Tapping a plain assistant message shows the whole message with no empty "Output" block.
6. Both themes read.

Record what you saw.

- [ ] **Step 3: Run the unit suite and commit**

Run: `./scripts/test-unit.sh 2>&1 | tail -5`
Expected: 1316 tests, 0 failures.

```bash
git add Sources/FlightDeckMobile/TimelineItemDetailScreen.swift
git commit -m "feat: tap a tool row through to its full output

§7's third screen. It shows all of what arrived and is explicit about
what did not: an item is capped at 64 KB on the Mac, which covers
essentially every command output and most file reads and does not cover
all of them, and a screen that simply stopped at the cap would be
indistinguishable from one showing a complete result.

The notice says both numbers rather than just 'truncated', because that
word does not tell a reader whether they are missing a line or a
megabyte — which is the difference between reading on and going to the
Mac.

A tool call is paired with its result on the agent's own callID, never on
id: id is a byte offset and pairs nothing.

The timestamp is formatted here from the raw string the agent wrote,
because the Mac deliberately never parses it — and falls back to that raw
string when it does not parse, rather than to a formatted lie about a
date nobody has.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Keeping an open session current

**Files:**
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift`
- Modify: `docs/MOBILE.md`
- Modify: `docs/FOLLOWUPS.md`

**Interfaces:**
- Consumes: `SessionTimelineModel.loadNewer()` (Task 3).
- Produces: nothing new.

History is pulled, not pushed (spec §6: "the phone asks for the page it needs"), so an open screen has to ask. Two triggers, and both are needed:

- **A fleet event for this session.** The list already receives `session.activity` and `session.renamed` live. But `emitActivity` on the Mac filters to genuine *transitions*, so a turn that runs busy for four minutes produces no event at all in the middle of it — an event-only trigger would show nothing until the turn ended.
- **A timer while the screen is open and the session is busy.** Which is what covers the four minutes. It stops when the screen goes away and when the session is not busy, so an idle session costs nothing.

- [ ] **Step 1: Add the triggers**

In `Sources/FlightDeckMobile/SessionTimelineScreen.swift`, add beside the existing `.task(id:)`:

```swift
        .task(id: model.sessionID) { model.loadLatest() }
        // The event trigger. `activity` and the title change live on the fleet socket, and a
        // change to either is the cheapest possible signal that this session has moved —
        // most importantly the busy → idle transition, which is the moment the last records
        // of a turn have landed.
        .onChange(of: session?.activity) { _, _ in model.loadNewer() }
        // The timer, and it is not redundant with the event above: `emitActivity` on the Mac
        // filters to genuine transitions, so a turn that runs busy for four minutes emits
        // NOTHING in the middle of it. Without this, an open screen would sit unchanged
        // through the whole turn and then fill in at the end.
        //
        // Only while busy, and only while the screen is on top: `.task` cancels on
        // disappear, so an idle session and a backgrounded screen both cost nothing. The
        // interval is a compromise a reader will accept — 1.5s is a beat behind a terminal
        // and cheap enough that a page of nothing new is a handful of bytes.
        .task(id: session?.activity) {
            guard session?.activity == "busy" else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1_500))
                guard !Task.isCancelled else { return }
                model.loadNewer()
            }
        }
```

- [ ] **Step 2: Build and watch a live turn**

Run: `./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'`

In the simulator, with a session open on the phone, give that session a multi-step task on the Mac and watch:

1. New items appear on the phone within a couple of seconds of landing in the terminal, throughout the turn — not all at once at the end.
2. The "Working" footer is present for the whole turn and gone after it.
3. Scrolling up to read older items is not yanked back down by an arriving page.
4. Leaving the screen stops the polling (the Mac's log shows the requests stop).
5. An idle session's screen issues no requests at all.

Record what you saw. **Do not run `./scripts/smoke.sh`.**

- [ ] **Step 3: Extend the manual checklist**

In `docs/MOBILE.md`, add to "The manual checklist":

```markdown
13. Tap a session — its conversation opens, showing the most recent messages, with the
    session's title in the bar.
14. Scroll to the top and tap "Load earlier" — older messages arrive above, and the reader
    stays where they were rather than being dragged up.
15. Tap a `Bash` row — the full command and its full output. Text is selectable.
16. Open a session and give it a multi-step task on the Mac — new rows land on the phone
    throughout the turn, not all at once at the end. Item 3 does not cover this: a rename
    fires an event, and a long busy turn fires none, which is exactly the case the poll
    exists for.
17. Leave the session screen — the Mac's log shows the timeline requests stop. An idle
    session's screen never issues one at all.
18. Open a **codex** session and a **claude** session side by side while both are working.
    Claude's footer may read "Working — 2 subagents"; codex's says only "Working", **never
    "0 subagents"** — codex writes no sub-agent record of any kind, so its count of 0 means
    unknown, not none (spec §6 has this asymmetry backwards; see the plan's asymmetry §2).
19. Neither agent shows a cursor, a caret, or a typing animation, at any point. Both are
    read from files that carry whole records, so a live cursor would be a fiction —
    including for codex, which §6 expects to stream and does not (the app-server path that
    could was deleted in b76a07b).
20. Open a session that has never taken a turn — it says so, rather than showing an empty
    conversation or a spinner that never resolves.
21. Quit Flight Deck with a session screen open — it says it is not connected, and keeps
    showing what it last held rather than emptying.
```

- [ ] **Step 4: Record the two known limits**

In `docs/FOLLOWUPS.md`, under known limitations:

```markdown
- **A timeline item is capped at 64 KB and a page at 128 KB.** A file read larger than the
  item cap is truncated with the shortfall stated on the row and on the detail screen. The
  alternative — a second round trip fetching one item whole — needs an offset index the
  transcript readers do not build, and 64 KB covers essentially every command output. Revisit
  if "open it on your Mac" turns out to be a common answer rather than a rare one.
- **An open session screen polls at 1.5s while the session is busy.** History is pulled, not
  pushed (spec §6), and the Mac emits activity events only on genuine transitions, so a long
  busy turn signals nothing in the middle of it. A push channel would need per-connection
  subscription state in `FleetSocketServer` and a northbound frame outside the `seq` space;
  that is a real design, not a tweak, and the poll is cheap enough that it has not earned one
  yet.
```

- [ ] **Step 5: Final verification and commit**

```bash
./scripts/test-unit.sh 2>&1 | tail -5
./scripts/build-ios.sh 2>&1 | grep -E 'BUILD SUCCEEDED|TYPE-CHECK PASSED|error:'
```

Expected: 1316 tests, 0 failures; three iOS successes.

```bash
git add Sources/FlightDeckMobile/SessionTimelineScreen.swift docs/MOBILE.md docs/FOLLOWUPS.md
git commit -m "feat: keep an open session current while a turn runs

Two triggers, and both are needed. A fleet event for this session is the
cheap one and catches the busy → idle transition, which is when a turn's
last records land. But emitActivity on the Mac filters to genuine
transitions, so a turn that runs busy for four minutes emits nothing in
the middle of it — an event-only trigger would leave the screen unchanged
through the whole turn and then fill it in at the end. The 1.5s poll
covers those four minutes, runs only while the session is busy and the
screen is on top, and costs a handful of bytes when there is nothing new.

The checklist gains the items only a device can settle, including the two
the spec gets wrong: codex must say 'Working' and never '0 subagents',
because it writes no sub-agent record at all and 0 there means unknown;
and neither agent shows a cursor, because neither streams through the
path that ships.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Self-review

Run against the spec with fresh eyes after the plan was complete.

**Spec coverage:**

| Requirement | Where |
|---|---|
| §7: three screens — fleet list → session timeline → item detail | Tasks 4, 6 |
| §7: terminal idiom (monospace, `⏺`/`⎿`), not chat bubbles | Task 5 |
| §7: a tool row taps through to the full diff / command output / file read | Task 6, bounded at 64 KB and explicit about it |
| §7: key mobile state on the tab `id`, never `conversationId` | Task 4 — the navigation value is `session.id`, and `FleetModel.timelineModel(for:)` is keyed on it |
| §6: opening a session fetches the most recent page and pages backwards on scroll | Tasks 3, 4 |
| §6: asymmetry — no live cursor | Task 5 renders `.streaming` identically to `.complete`; Task 7's checklist items 18–19 are how a human confirms it. **The spec's version of this asymmetry is wrong and the plan says so up front.** |
| §6: asymmetry — sub-agents | Task 2, **inverted relative to §6**, with the evidence in the preceding plan's findings §3 |
| §8: reading a session on the phone clears the dot on the Mac | Task 4 — `markRead` on the tap that opens it |
| §8: only the device not showing that session notifies | **Not in this plan.** It is slice 3 (notifications), which does not exist yet; nothing here can suppress an alert that nothing sends. |

**Placeholder scan:** no TBDs. Task 4 creates two files as stubs and Tasks 5 and 6 replace them in full — stated explicitly at both ends, so a reader of Task 5 alone is not left wondering what the previous body was.

**Type consistency, checked name by name:** `TimelineFeed`'s surface (`items`, `oldest`, `newest`, `hasOlder`, `hasLoadedAnything`, `olderAnchor`, `newerAnchor`, `merge(_:)`) is defined in Task 1 and every use in Tasks 3 and 4 matches. `SessionTimelineModel`'s surface (`feed`, `phase`, `sessionID`, `isLoadingOlder`, `loadLatest`, `loadOlder`, `loadNewer`) is defined in Task 3 and used in Tasks 4 and 7. `WireSession.subagentSummary` is produced in Task 2 and consumed in Task 2 (`SessionStatusGlyph`) and Task 4 (`workingFooter`). `TimelineRow(item:)` and `TimelineItemDetailScreen(item:result:)` are stubbed in Task 4 with exactly the signatures Tasks 5 and 6 keep.

**One build-system trap, checked:** every new `FlightDeckMobile` file is directly in `Sources/FlightDeckMobile/`. `project.yml`'s source entry is recursive so a build would find a subdirectory, but `scripts/build-ios.sh`'s fallback type-check globs `Sources/FlightDeckMobile/*.swift` — and that fallback is the *only* automated check of these files on a machine with no iOS platform installed, which is the machine this was written on.

**What this plan cannot prove, and does not pretend to:** every SwiftUI decision in Tasks 4–7. There is no test host for the iOS target here, and `UITests` is throttled GUI territory that AGENTS.md rule 4 puts off limits. That is why Tasks 1 and 2 exist in `FleetKit` at all — the merge, the cursors, the dedupe and the sub-agent rule are the parts with decisions in them, and they are unit-tested — and why every remaining task ends in an observable outcome on a simulator rather than in an assertion that would only be testing that SwiftUI compiles.
