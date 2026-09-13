# Mobile Long-Session Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL — invoke `superpowers:subagent-driven-development` to execute this plan. Each task below is a self-contained TDD unit (failing test → run-to-fail → minimal implementation → run-to-pass → commit) and is written to be handed to an isolated executor who sees only that task.

**Goal:** The phone's session timeline stays smooth on a session of any length. Opening, scrolling, and following a live turn cost work proportional to what is *on screen*, never to how much history the session holds — and a single enormous session can no longer grow the phone's memory without bound.

**Architecture:** `FlightDeckMobile`'s `SessionTimelineScreen` renders a lazy SwiftUI `List` over a `SessionTimelineModel`, which owns a value-type `TimelineFeed` (in `FleetKit`, macOS-unit-tested) plus the fetch/merge/reconcile state machine. The fix moves the O(N) row-fold out of the view body into maintained model state recomputed once per real change, de-thrashes the per-poll amplifiers, bounds cross-session model retention, and adds a per-session disk-spill so a single giant session has a hard memory ceiling.

**Tech Stack:** Swift / SwiftUI / XCTest / SwiftPM (via `xcodegen` + `xcodebuild`).

**Spec:** `/Users/nate/Projects/Protos-n-Tools/flight-deck/docs/superpowers/specs/2026-09-12-mobile-long-session-perf-design.md` (commit `e0224a1`). This plan implements exactly that spec; it does not redesign it.

## Global Constraints

- **FleetKit logic belongs in the macOS unit suite.** The codebase doctrine (`TimelineFeed.swift:5-9`, `FleetModel.swift:7-15`) is that anything worth testing lives in `FleetKit` where the macOS suite reaches it without a booted simulator. New pure logic (`TimelineRender`, `TimelineFeed` merge/spill/rehydrate, `TimelineSpillStore`) is tested in `Tests/FlightDeckTests/` (which `@testable import FleetKit`).
- **Two test targets.** `scripts/test-unit.sh` runs `FlightDeckTests` headless on macOS (loads the bundle by hand — do not touch that dance). `scripts/test-ios.sh` runs `FlightDeckMobileTests` on a throwaway simulator. Every task states which script validates it. Both scripts run `xcodegen generate` first, so new files are picked up automatically once they sit under an existing target's source root. Note: `test-unit.sh` runs the full macOS suite regardless of `-only-testing:` — budget ~8 min.
- **Wire enum cases are atomic.** Do not add a wire enum case in one commit and its handling in another. (No new wire cases are introduced here; `Body.isPlaceholder` in Part 4 is a transient, non-encoded field, kept out of the wire contract by construction.)
- **Follow existing file/doc-comment style.** These files carry long "why, not what" doc comments explaining the defect each decision prevents. New public/internal declarations get comments in the same voice. Do not strip existing comments when editing.
- **Commit frequently**, one commit per task, each ending with the trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```
- **Branch first.** Before Task 1.1, create a working branch: `git checkout -b mobile-long-session-perf`.
- **Verified existing APIs** (checked against the tree at plan time, safe to rely on): `TimelineAnchor.around(Int)` (`TimelineFrames.swift:16`); `SessionTimelineModel.fetch(anchor:older:quiet:)` with `quiet: Bool = false` (`:850`), `prefetchOlder()` (`:372`), `loadNewer()` (`:388`), `send(_:)` (`:421`), `viewing(_ isViewing: Bool)` (`:603`), `isOnScreen` (`:623`), `answerState` (`:214`); `TimelineSegmenter.Clamped: Equatable` (`TimelineSegments.swift:74`) and `clampedProse(for:expanded:)` (`TimelineStyle.swift:460`); `PromptOutbox: Equatable` with `entries` and `PromptOutboxEntry.State.delivered` (`Sources/FleetKit/PromptOutbox.swift:4,11,18,53-54`).

---

# Part 1 — Rendered entries as maintained state (the lag fix)

*This is the whole user-visible win. Ship and validate it before touching Parts 2–4.*

---

## Task 1.1 — Move `Entry` + the pure fold into FleetKit as `TimelineRender`

**Files**
- Create: `Sources/FleetKit/TimelineRender.swift`
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (delete `Entry` struct at `:581-591`; delete `static func entries(from:delivered:)` at `:651-683`; the fold body moves to FleetKit and the ghost half to the model in Task 1.2)
- Test: `Tests/FlightDeckTests/TimelineRenderTests.swift` (new, macOS suite)

**Interfaces**
- Produces:
  - `public struct TimelineEntry: Identifiable, Hashable, Sendable { public let item: TimelineItem; public let result: TimelineItem?; public var id: String { item.id }; public var isGhost: Bool { item.id.hasPrefix("ghost:") }; public init(item: TimelineItem, result: TimelineItem?) }`
  - `public enum TimelineRender { public static func entries(from items: [TimelineItem]) -> [TimelineEntry] }`
- Consumes: `TimelineItem`, `TimelineItem.Kind` (`.toolCall`, `.toolResult`), `TimelineItem.Body.callID` (all `Sources/FleetKit/Timeline.swift`).

**Step 1 — Write the failing test.** Create `Tests/FlightDeckTests/TimelineRenderTests.swift`:

```swift
import XCTest
@testable import FleetKit

/// The fold that turns a flat item list into rows, moved out of the phone's view so the
/// macOS suite can hold its one hard invariant: a tool result is paired with its call across a
/// page boundary and never dropped when its call sits on an adjacent page.
final class TimelineRenderTests: XCTestCase {
    private func item(_ id: String, _ kind: TimelineItem.Kind, callID: String? = nil) -> TimelineItem {
        TimelineItem(id: id, kind: kind, status: .complete,
                     body: TimelineItem.Body(text: id, callID: callID))
    }

    func testAProseRowFoldsToOneEntryWithNoResult() {
        let entries = TimelineRender.entries(from: [item("0#0", .assistantText)])
        XCTAssertEqual(entries.map(\.id), ["0#0"])
        XCTAssertNil(entries[0].result)
    }

    func testAToolResultIsFoldedIntoItsCallByCallID() {
        let entries = TimelineRender.entries(from: [
            item("0#0", .toolCall, callID: "tA"),
            item("10#0", .toolResult, callID: "tA"),
        ])
        XCTAssertEqual(entries.map(\.id), ["0#0"], "the result folds away into its call's row")
        XCTAssertEqual(entries[0].result?.id, "10#0")
    }

    /// The invariant this whole move exists to protect: a result whose call is NOT in the
    /// window must survive as its own row rather than being dropped.
    func testAToolResultWhoseCallIsAbsentSurvivesAsItsOwnRow() {
        let entries = TimelineRender.entries(from: [item("10#0", .toolResult, callID: "tA")])
        XCTAssertEqual(entries.map(\.id), ["10#0"])
        XCTAssertNil(entries[0].result)
    }

    /// Two tools running at once interleave; each result must pair with ITS call, never "the
    /// next result".
    func testInterleavedCallsPairEachResultWithItsOwnCall() {
        let entries = TimelineRender.entries(from: [
            item("0#0", .toolCall, callID: "tA"),
            item("10#0", .toolCall, callID: "tB"),
            item("20#0", .toolResult, callID: "tB"),
            item("30#0", .toolResult, callID: "tA"),
        ])
        XCTAssertEqual(entries.map(\.id), ["0#0", "10#0"])
        XCTAssertEqual(entries[0].result?.id, "30#0", "tA's call paired with tA's result")
        XCTAssertEqual(entries[1].result?.id, "20#0", "tB's call paired with tB's result")
    }

    /// The first result for a call wins; a duplicate result does not fold and stays a row.
    func testASecondResultForOneCallIsNotFoldedTwice() {
        let entries = TimelineRender.entries(from: [
            item("0#0", .toolCall, callID: "tA"),
            item("10#0", .toolResult, callID: "tA"),
            item("20#0", .toolResult, callID: "tA"),
        ])
        XCTAssertEqual(entries[0].result?.id, "10#0")
        XCTAssertEqual(entries.map(\.id), ["0#0", "20#0"],
                       "the call folds its first result; the second stands alone")
    }
}
```

**Step 2 — Run to fail.** `./scripts/test-unit.sh` → compile failure: `cannot find 'TimelineRender' in scope` (and `TimelineEntry`).

**Step 3 — Minimal implementation.** Create `Sources/FleetKit/TimelineRender.swift`:

```swift
import Foundation

/// One row's worth of conversation: an item, plus the result that answers it when the item is a
/// call and the window holds one.
///
/// In `FleetKit` rather than in the phone's view for the reason `TimelineFeed`'s doc comment
/// gives: the fold's one hard invariant — pairing a `toolResult` with its `toolCall` across a
/// page boundary and never dropping a result whose call is on an adjacent page — is exactly the
/// kind of thing the macOS unit suite must be able to hold, not something behind a booted
/// simulator. The ghost-append that needs `PromptOutboxEntry` stays in the model layer as a thin
/// wrapper over this pure fold; this type and `TimelineRender.entries(from:)` know nothing about
/// the outbox.
public struct TimelineEntry: Identifiable, Hashable, Sendable {
    public let item: TimelineItem
    public let result: TimelineItem?
    public var id: String { item.id }

    /// A synthetic entry for a `.delivered` outbox message, never a record the agent wrote.
    /// Detected by id prefix rather than a stored field: the id is the one thing the ghost
    /// wrapper controls, and a second flag would be a second place the two could disagree. The
    /// wrapper lives in `SessionTimelineModel`; the pure fold here never produces one.
    public var isGhost: Bool { item.id.hasPrefix("ghost:") }

    public init(item: TimelineItem, result: TimelineItem?) {
        self.item = item
        self.result = result
    }
}

public enum TimelineRender {
    /// Folds every tool result into the call it answers, so a command and its output are one row
    /// rather than two that read as two unrelated events.
    ///
    /// **Paired on `callID` — the agent's own id — and never on position.** A session running two
    /// tools at once interleaves their records, so "the next result" is a different call's output
    /// about half the time.
    ///
    /// **A result is only folded away when its call is actually here.** A page boundary can land
    /// between the two, and dropping a result whose call is on the previous page would delete
    /// content from the screen. So the set of calls present is what decides, not merely the
    /// result having an id.
    public static func entries(from items: [TimelineItem]) -> [TimelineEntry] {
        var resultsByCall: [String: TimelineItem] = [:]
        var callsPresent: Set<String> = []
        for item in items {
            guard let callID = item.body.callID else { continue }
            switch item.kind {
            case .toolResult: if resultsByCall[callID] == nil { resultsByCall[callID] = item }
            case .toolCall: callsPresent.insert(callID)
            default: break
            }
        }
        return items.compactMap { item -> TimelineEntry? in
            guard let callID = item.body.callID else { return TimelineEntry(item: item, result: nil) }
            switch item.kind {
            case .toolCall:
                return TimelineEntry(item: item, result: resultsByCall[callID])
            case .toolResult:
                return callsPresent.contains(callID) ? nil : TimelineEntry(item: item, result: nil)
            default:
                return TimelineEntry(item: item, result: nil)
            }
        }
    }
}
```

Now delete the old `Entry` struct (`SessionTimelineScreen.swift:581-591`) and the old `static func entries(from:delivered:)` (`:651-683`). The screen will not compile yet — its `entries` computed property (`:421-426`), `entryRow(_ entry: Entry)` (`:445`), `prefetchTrigger(_ entries: [Entry])` (`:572-575`), and `ForEach(entries)` (`:107`) still reference the deleted `Entry`. **Task 1.2 and 1.3 finish the migration; do not leave this task half-compiled.** To keep this task independently green, in this same commit rename the mobile references to the new FleetKit type and re-home the ghost fold as a temporary static on the screen so the app compiles and the mobile suite stays green:

In `SessionTimelineScreen.swift`, change `entryRow(_ entry: Entry)` → `entryRow(_ entry: TimelineEntry)`, `prefetchTrigger(_ entries: [Entry])` → `prefetchTrigger(_ entries: [TimelineEntry])`, and replace the deleted static fold with a thin temporary wrapper (removed in Task 1.2):

```swift
static func entries(from items: [TimelineItem], delivered: [PromptOutboxEntry] = []) -> [TimelineEntry] {
    var mapped = TimelineRender.entries(from: items)
    mapped.append(contentsOf: delivered.map { entry in
        TimelineEntry(
            item: TimelineItem(
                id: "ghost:\(entry.id.uuidString)", kind: .userTurn, status: .complete,
                body: .init(text: entry.text)
            ),
            result: nil
        )
    })
    return mapped
}
```

The `private var entries` computed (`:421-426`) now calls this wrapper and compiles unchanged.

Update the existing callers/tests that name the type: `Tests/FlightDeckMobileTests/SessionTimelineScreenTests.swift` and `Tests/FlightDeckMobileTests/TranscriptGhostTests.swift` continue to call `SessionTimelineScreen.entries(from:)` / `.prefetchTrigger(_:)` unchanged (the wrapper preserves the signature), so no test edits are needed in this task.

**Step 4 — Run to pass.** `./scripts/test-unit.sh` (new FleetKit tests green) and `./scripts/test-ios.sh` (mobile suite still green — the wrapper preserves behaviour).

**Step 5 — Commit.**
```
git add -A
git commit -m "Move timeline Entry + pure fold into FleetKit TimelineRender

The call/result pairing across a page boundary is the one invariant worth
holding in the macOS suite; extract it from the view so a test can reach it
without a simulator. A temporary ghost-appending wrapper stays on the screen
until the model owns it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 1.2 — Maintain `rendered` + `prefetchTriggerID` in the model via `rebuild()`

**Files**
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift` (add stored state near `:116-142`; add `rebuild()`; gate it in `fetch` success at `:902-909`)
- Modify: `Sources/FleetKit/TimelineFeed.swift` (make `merge` return whether items changed, `:75-103`)
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (move `prefetchTrigger` + `prefetchDepth` to the model; remove the temporary wrapper; keep the `entries` computed for now)
- Test: `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift` (extend), `Tests/FlightDeckTests/TimelineFeedTests.swift` (extend for the `merge` return)

**Interfaces**
- Produces (on `SessionTimelineModel`):
  - `private(set) var rendered: [TimelineEntry] = []`
  - `private(set) var prefetchTriggerID: String?`
  - `@ObservationIgnored private(set) var rebuildCount = 0`
  - `private func rebuild()`
  - `static func rendered(from items: [TimelineItem], delivered: [PromptOutboxEntry]) -> [TimelineEntry]`
  - `static let prefetchDepth = TimelineLimits.defaultLimit`
  - `static func prefetchTrigger(_ entries: [TimelineEntry]) -> String?`
- Produces (on `TimelineFeed`): `@discardableResult public mutating func merge(_ page: TimelinePage) -> Bool` (returns whether `items` changed).
- Consumes: `TimelineRender.entries(from:)`, `PromptOutboxEntry.state == .delivered` (`Sources/FleetKit/PromptOutbox.swift`), `feed.items`, `feed.hasOlder`.

**Step 1 — Write the failing tests.** In `TimelineFeedTests.swift`, add:

```swift
func testMergeReportsWhetherItemsChanged() {
    var feed = TimelineFeed()
    XCTAssertTrue(feed.merge(page([item("10#0", "a")], start: 10, end: 20, hasMore: true)),
                  "the first page adds an item")
    XCTAssertFalse(feed.merge(page([], start: 20, end: 20)),
                   "an empty newer poll page changes no items")
    XCTAssertTrue(feed.merge(page([item("20#0", "b")], start: 20, end: 30)),
                  "a page with a new item changes items")
}
```

In `SessionTimelineModelTests.swift`, add (the `StubPager`, `model(_:)`, `page(_:)`, `tail()`, `item(_:_:)` helpers already exist at `:12-129`):

```swift
func testRenderedIsMaintainedAfterAFetchLands() {
    let pager = StubPager()
    let model = model(pager)
    model.open()
    pager.answer(tail())
    XCTAssertEqual(model.rendered.map(\.id), ["1040#0", "1090#0"],
                   "rendered is folded from the merged feed and held")
}

func testAQuietNoOpPollTriggersNoRebuild() {
    let pager = StubPager()
    let model = model(pager)
    model.open()
    pager.answer(tail(hasMore: false))
    let after = model.rebuildCount
    model.loadNewer()
    pager.answer(page([], start: 1200, end: 1200))  // nothing new
    XCTAssertEqual(model.rebuildCount, after,
                   "a poll that merges nothing must not recompute rendered")
}

func testOneNewItemTriggersExactlyOneRebuild() {
    let pager = StubPager()
    let model = model(pager)
    model.open()
    pager.answer(tail(hasMore: false))
    let after = model.rebuildCount
    model.loadNewer()
    pager.answer(page([item(1200, "third")], start: 1200, end: 1260))
    XCTAssertEqual(model.rebuildCount, after + 1,
                   "one new item recomputes rendered exactly once")
    XCTAssertEqual(model.rendered.map(\.id), ["1040#0", "1090#0", "1200#0"])
}
```

**Step 2 — Run to fail.** `./scripts/test-ios.sh` → `value of type 'SessionTimelineModel' has no member 'rendered'` / `rebuildCount`; `./scripts/test-unit.sh` → `merge` returns `()`.

**Step 3 — Minimal implementation.**

In `TimelineFeed.swift`, change `merge` to report change (`:75-103`):

```swift
@discardableResult
public mutating func merge(_ page: TimelinePage) -> Bool {
    guard !page.reset else {
        let hadItems = !items.isEmpty
        self = TimelineFeed()
        return hadItems
    }
    let isFirstPage = !hasLoadedAnything
    let isOlder = oldest.map { page.start < $0 } ?? false
    let before = items
    items = Self.merging(items, page.items)
    oldest = min(oldest ?? page.start, page.start)
    newest = max(newest ?? page.end, page.end)
    if isOlder || isFirstPage { hasOlder = page.hasMore }
    return items != before
}
```

(The `items != before` compare is O(N) but runs at most once per fetch, not once per render; Task 2.2 makes the common no-op path allocate nothing. Array `==` short-circuits on differing counts, which covers the ordinary "new item appended" case cheaply.)

In `SessionTimelineModel.swift`, add stored state after `olderFailure` (`:129`):

```swift
/// The folded, ghost-appended list the `ForEach` draws — maintained state, recomputed by
/// `rebuild()` exactly once per change to its inputs, never from the view. The lag this whole
/// change removes was this fold running O(N) on every render and every row lifecycle.
private(set) var rendered: [TimelineEntry] = []

/// The id of the row whose appearance triggers a backward prefetch, computed once alongside
/// `rendered`. The view compares an id here instead of re-folding the feed in every row's
/// `.onAppear`.
private(set) var prefetchTriggerID: String?

/// How many times `rebuild()` has run. `@ObservationIgnored` because a busy poll must not
/// invalidate the view merely by counting, and because the recompute-count guard test asserts
/// on it directly — a quiet poll must add zero, one new item exactly one.
@ObservationIgnored private(set) var rebuildCount = 0
```

Add the fold wrapper, the prefetch statics, and `rebuild()` (place near the existing `highlightTarget` static, `:329`):

```swift
/// The pure fold plus the ghost-append. The fold itself is `TimelineRender.entries(from:)` in
/// FleetKit; the ghosts need `PromptOutboxEntry` and so stay here, appended after the folded
/// feed, one per `.delivered` entry, in send order. Each carries a `"ghost:<token>"` id that
/// exists only in this array — never written into `TimelineFeed`, so a page reset or a
/// reconcile cannot find it.
static func rendered(from items: [TimelineItem], delivered: [PromptOutboxEntry]) -> [TimelineEntry] {
    var entries = TimelineRender.entries(from: items)
    entries.append(contentsOf: delivered.map { entry in
        TimelineEntry(
            item: TimelineItem(
                id: "ghost:\(entry.id.uuidString)", kind: .userTurn, status: .complete,
                body: .init(text: entry.text)
            ),
            result: nil
        )
    })
    return entries
}

/// One page's worth of runway below the top of history — moved here from the view because the
/// trigger id is now maintained state. `defaultLimit` is in records and one record can carry
/// several entries, so this is a floor on the real distance.
static let prefetchDepth = TimelineLimits.defaultLimit

/// Falls back to the OLDEST entry (index 0), never the newest and never nil: a feed shorter
/// than the depth has no runway, so the earliest possible ask is the right one; clamping to
/// `count - 1` would fire the prefetch the instant the screen draws.
static func prefetchTrigger(_ entries: [TimelineEntry]) -> String? {
    guard !entries.isEmpty else { return nil }
    return entries.count > prefetchDepth ? entries[prefetchDepth].id : entries[0].id
}

/// The one place `rendered` and the derived prefetch id are recomputed. Called only when an
/// input actually changed — after a merge that moved items, after a reconcile that retired an
/// outbox entry — never from the view.
private func rebuild() {
    rebuildCount += 1
    rendered = Self.rendered(
        from: feed.items,
        delivered: outbox.entries.filter { $0.state == .delivered }
    )
    prefetchTriggerID = feed.hasOlder ? Self.prefetchTrigger(rendered) : nil
}
```

Gate the call in `fetch`'s success path (`:902-909`). Replace:

```swift
case .success(let page):
    self.feed.merge(page)
    self.outbox.reconcile(with: self.feed.items)
    self.phase = .idle
```
with:
```swift
case .success(let page):
    let hadOlder = self.feed.hasOlder
    let outboxBefore = self.outbox
    let itemsChanged = self.feed.merge(page)
    self.outbox.reconcile(with: self.feed.items)
    // Recompute maintained state only when an input to it actually moved: the folded items,
    // whether there is more history (drives the prefetch id), or the set of delivered outbox
    // ghosts. A quiet 1.5s poll changes none of these and rebuilds nothing.
    if itemsChanged || self.feed.hasOlder != hadOlder || self.outbox != outboxBefore {
        self.rebuild()
    }
    self.phase = .idle
```

`PromptOutbox` is `Equatable` (`PromptOutbox.swift:53`), so `self.outbox != outboxBefore` compiles. A reconcile that retires an entry mutates `entries`, so the compare is honest.

Now remove the temporary `static func entries(from:delivered:)` wrapper added to `SessionTimelineScreen` in Task 1.1, and remove the screen's `prefetchTrigger` / `prefetchDepth` (`:559`, `:572-575`) since they moved to the model. The screen's `private var entries` (`:421-426`) and `private var prefetchTriggerID` (`:548-550`) still exist and now must call the model — but the full view switch is Task 1.3. To keep this task compiling and green, point the screen's computed properties at the model's statics:

```swift
private var entries: [TimelineEntry] {
    SessionTimelineModel.rendered(
        from: model.feed.items,
        delivered: model.outbox.entries.filter { $0.state == .delivered }
    )
}
private var prefetchTriggerID: String? {
    model.feed.hasOlder ? SessionTimelineModel.prefetchTrigger(entries) : nil
}
```

Update the two existing test callers that used the removed screen statics: in `SessionTimelineScreenTests.swift` change `SessionTimelineScreen.entries(from:)` → `TimelineRender.entries(from:)` and `SessionTimelineScreen.prefetchTrigger(_:)` → `SessionTimelineModel.prefetchTrigger(_:)`; in `TranscriptGhostTests.swift` change `SessionTimelineScreen.entries(from: feed, delivered:)` → `SessionTimelineModel.rendered(from: feed, delivered:)` and `SessionTimelineScreen.entries(from: feed)` → `SessionTimelineModel.rendered(from: feed, delivered: [])`.

**Step 4 — Run to pass.** `./scripts/test-unit.sh` and `./scripts/test-ios.sh` both green.

**Step 5 — Commit.**
```
git add -A
git commit -m "Maintain rendered + prefetch id in the model via rebuild()

Fold the feed exactly once per real change instead of on every render and every
row lifecycle. merge() now reports whether items moved so a quiet poll rebuilds
nothing; a recompute-count guard pins that.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 1.3 — View reads stored `rendered` / `prefetchTriggerID`; drop the computed fold

**Files**
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (`ForEach` at `:107`; `.onAppear`/`.onDisappear` at `:129-136`; delete `private var entries` `:421-426` and `private var prefetchTriggerID` `:548-550`)
- Test: `Tests/FlightDeckMobileTests/SessionTimelineScreenTests.swift` (add a body-smoke assertion; the fold and trigger unit tests already target the model/FleetKit statics)

**Interfaces**
- Consumes: `model.rendered: [TimelineEntry]`, `model.prefetchTriggerID: String?` (from Task 1.2).

**Step 1 — Write the failing test.** In `SessionTimelineScreenTests.swift`, add:

```swift
@MainActor
func testTheScreenDrawsTheModelsMaintainedRenderedList() {
    // The screen's ForEach source is model.rendered; a test with no window asserts the model
    // maintains exactly the ids the list will draw, folding a tool result into its call.
    let items = [
        TimelineItem(id: "0#0", kind: .toolCall, status: .complete,
                     body: .init(text: "call", callID: "tA")),
        TimelineItem(id: "10#0", kind: .toolResult, status: .complete,
                     body: .init(text: "out", callID: "tA")),
    ]
    let rendered = SessionTimelineModel.rendered(from: items, delivered: [])
    XCTAssertEqual(rendered.map(\.id), ["0#0"])
    XCTAssertEqual(rendered[0].result?.id, "10#0")
}
```

(This test passes already from Task 1.2; the code change below is the point — it removes the last O(N) fold on the render path. The test is the regression guard that `rendered` stays the single source.)

**Step 2 — Run to fail / establish baseline.** `./scripts/test-ios.sh` green (baseline); the change is verified by the diff and the existing suite staying green.

**Step 3 — Minimal implementation.** In `SessionTimelineScreen.swift`:

- `ForEach(entries) { entry in` (`:107`) → `ForEach(model.rendered) { entry in`.
- In the row `.onAppear` (`:129-133`): `guard entry.id == prefetchTriggerID else { return }` → `guard entry.id == model.prefetchTriggerID else { return }`.
- In `.onDisappear` (`:134-136`): `if entry.id == prefetchTriggerID { isNearOldest = false }` → `if entry.id == model.prefetchTriggerID { isNearOldest = false }`.
- Delete `private var entries` (`:421-426`) and `private var prefetchTriggerID` (`:548-550`) entirely — nothing reads them now.

**Step 4 — Run to pass.** `./scripts/test-ios.sh` green.

**Step 5 — Commit.**
```
git add -A
git commit -m "Read maintained rendered/prefetch id from the view

The ForEach and the row prefetch check now compare against stored state; the
per-render O(N) fold is gone from the view entirely.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## ▶ CHECKPOINT after Part 1

**Part 1 is the whole user-visible win.** Before starting Part 2, validate that the lag is gone:

1. Run both suites: `./scripts/test-unit.sh` and `./scripts/test-ios.sh` — all green.
2. Manually validate on device/simulator per `docs/MOBILE.md`: open a long-running session (or the longest available fixture session), scroll through it, and follow a live busy turn. Confirm scrolling and the 1.5s busy poll no longer produce the "abysmal" lag — render cost is now O(on-screen rows), not O(feed length).
3. Only once the lag is confirmed gone do Parts 2–4 (they are the full sweep: de-thrash, bound cross-session growth, ceiling a single giant session). They are independent and can each be validated on their own.

---

# Part 2 — De-thrash the live-turn path

---

## Task 2.1 — Fold `blocked` into `rebuild()`; view reads the stored value

**Files**
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift` (add `blocked` storage + status inputs + `updateStatus`; extend `rebuild()`)
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (`PromptCard(open:)` at `:294-298`; add `updateStatus` calls at `:330,337` and on mount)
- Test: `Tests/FlightDeckMobileTests/SessionTimelineBlockedTests.swift` (add a stored-blocked test there)

**Interfaces**
- Produces (on `SessionTimelineModel`):
  - `private(set) var blocked: OpenPrompt?`  *(the actual type returned by `blocked(agent:activity:call:)` at `:700`; the stored property `blocked` coexists with the method `blocked(agent:activity:call:)`)*
  - `func updateStatus(agent: String?, activity: String?, call: OpenPromptIdentity)`
  - `@ObservationIgnored private var statusAgent: String?`, `statusActivity: String?`, `statusCall: OpenPromptIdentity = .unreported`
- Consumes: `blocked(agent:activity:call:) -> OpenPrompt?` (`:700-705`), `OpenPromptIdentity` (`Sources/FleetKit/Wire.swift`).

**Step 1 — Write the failing test.** In `Tests/FlightDeckMobileTests/SessionTimelineBlockedTests.swift` (existing file — reuse its stub and fixtures; if a helper is missing, mirror `SessionTimelineModelTests`'s `StubPager`), add:

```swift
@MainActor
func testBlockedIsStoredAndRecomputedOnStatusChange() {
    let pager = StubPager()
    let model = model(pager)
    model.open()
    // A claude prompt call sitting unanswered in the feed.
    pager.answer(page([
        item(0, index: 0, kind: .prompt,
             #"{"questions":[{"question":"Pick","options":[{"label":"A"}]}]}"#)
    ], start: 0, end: 100))
    XCTAssertNil(model.blocked, "no status yet: nothing is claimed blocked")

    model.updateStatus(agent: "claude", activity: "waiting", call: .unreported)
    XCTAssertEqual(model.blocked?.callID, "cA",
                   "waiting + an unanswered prompt call derives a blocked prompt, stored")

    model.updateStatus(agent: "claude", activity: "idle", call: .unreported)
    XCTAssertNil(model.blocked, "leaving waiting clears the stored blocked value")
}
```

(Use whatever `callID` the file's prompt fixture carries; align `"cA"` to it. The existing blocked tests in this file already build prompt items with a known `callID` — reuse that fixture.)

**Step 2 — Run to fail.** `./scripts/test-ios.sh` → `no member 'blocked'` (property) / `'updateStatus'`.

**Step 3 — Minimal implementation.** In `SessionTimelineModel.swift`, add near `rendered` (`:116`):

```swift
/// What this session is blocked on, or nil — maintained state, folded by `rebuild()` from the
/// live status inputs and the feed, so the `OpenPrompt.find` scan runs once per change rather
/// than once per render. The scan still only does work while `waiting`.
private(set) var blocked: OpenPrompt?

/// The live `WireSession` fields the blocked derivation reads, pushed by the view through
/// `updateStatus`. `@ObservationIgnored` because they are inputs to `rebuild()`, not display
/// state — the view draws `blocked`, never these.
@ObservationIgnored private var statusAgent: String?
@ObservationIgnored private var statusActivity: String?
@ObservationIgnored private var statusCall: OpenPromptIdentity = .unreported
```

Add the setter (near `open()`, `:294`):

```swift
/// The view's status inputs moved: fold them in and recompute, but only when one actually
/// changed. A supersede — same activity, different open call — still lands here because `call`
/// is part of the comparison.
func updateStatus(agent: String?, activity: String?, call: OpenPromptIdentity) {
    guard agent != statusAgent || activity != statusActivity || call != statusCall else { return }
    statusAgent = agent
    statusActivity = activity
    statusCall = call
    rebuild()
}
```

Extend `rebuild()` to fold `blocked`:

```swift
private func rebuild() {
    rebuildCount += 1
    rendered = Self.rendered(
        from: feed.items,
        delivered: outbox.entries.filter { $0.state == .delivered }
    )
    prefetchTriggerID = feed.hasOlder ? Self.prefetchTrigger(rendered) : nil
    blocked = blocked(agent: statusAgent, activity: statusActivity, call: statusCall)
}
```

In `SessionTimelineScreen.swift`, change the card to read the stored value (`:294-298`):

```swift
PromptCard(
    open: model.blocked,
    ...
```

Push status into the model wherever the view reads those fields. Add to the two `.onChange` handlers (`:330`, `:337`) and give the model an initial value on mount:

```swift
.onChange(of: session?.activity) { _, _ in
    model.loadNewer()
    model.updateStatus(agent: session?.agent, activity: session?.activity,
                       call: session?.openPromptCall ?? .unreported)
}
.onChange(of: session?.openPromptCall) { _, _ in
    model.loadNewer()
    model.updateStatus(agent: session?.agent, activity: session?.activity,
                       call: session?.openPromptCall ?? .unreported)
}
```

And seed it on mount so `blocked` is right before the first status change — add to the existing `.task(id: model.sessionID) { model.open() }` (`:278`):

```swift
.task(id: model.sessionID) {
    model.updateStatus(agent: session?.agent, activity: session?.activity,
                       call: session?.openPromptCall ?? .unreported)
    model.open()
}
```

(The blocked value also refreshes whenever the feed moves, because `rebuild()` after a merge recomputes it from the stored status inputs — so records naming a newly-open dialog surface without a separate status change.)

**Step 4 — Run to pass.** `./scripts/test-ios.sh` green.

**Step 5 — Commit.**
```
git add -A
git commit -m "Fold blocked into rebuild(); view reads the stored value

OpenPrompt.find no longer runs in the view body on every render; the waiting-
only scan runs once per change to the status inputs or the feed.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2.2 — `TimelineFeed.merge` no-op early-out

**Files**
- Modify: `Sources/FleetKit/TimelineFeed.swift` (`merging` at `:117-158`; add a no-op guard)
- Test: `Tests/FlightDeckTests/TimelineFeedTests.swift` (extend)

**Interfaces**
- Consumes/Produces: `merging(_ held:, _ page:)` gains a no-op fast path; `merge`'s `@discardableResult Bool` contract (Task 1.2) is unchanged — a no-op returns `false`.

**Step 1 — Write the failing test.** In `TimelineFeedTests.swift`:

```swift
/// A quiet poll re-delivers a page already fully held. The merge must return the SAME array
/// instance — no reallocation — and report no change.
func testANoOpPageReturnsTheHeldArrayWithoutReallocating() {
    var feed = TimelineFeed()
    feed.merge(page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: true))
    let heldBefore = feed.items
    let changed = feed.merge(page([item("10#0", "a"), item("20#0", "b")], start: 10, end: 30, hasMore: true))
    XCTAssertFalse(changed, "every incoming id is already present with an equal body")
    XCTAssertTrue(feed.items.withUnsafeBufferPointer { held in
        heldBefore.withUnsafeBufferPointer { $0.baseAddress == held.baseAddress }
    }, "the held array buffer must be returned unchanged, not rebuilt")
    expect(feed, texts: ["a", "b"], oldest: 10, newest: 30,
           hasOlder: true, hasLoadedAnything: true)
}

/// The case that must NOT be skipped: same id, longer body. A body cut short by one page's
/// budget and delivered whole by another has to replace the short one.
func testASameIdLongerBodyIsNotTreatedAsANoOp() {
    var feed = TimelineFeed()
    var short = item("10#0", "abc"); short.body.truncatedBytes = 100
    feed.merge(page([short], start: 10, end: 20))
    let changed = feed.merge(page([item("10#0", "abcdef")], start: 10, end: 20))
    XCTAssertTrue(changed, "a longer body for a held id is a real change")
    XCTAssertEqual(feed.items.map(\.body.text), ["abcdef"])
}
```

**Step 2 — Run to fail.** `./scripts/test-unit.sh` → the no-op test fails (a fresh array is built, buffers differ, and `merge` returns `true`).

**Step 3 — Minimal implementation.** In `merging` (`:117-127`), after the `guard !page.isEmpty` and before sorting, add the no-op detection:

```swift
private static func merging(
    _ held: [TimelineItem], _ page: [TimelineItem]
) -> [TimelineItem] {
    guard !page.isEmpty else { return held }
    guard !held.isEmpty else { return page.sorted { order(of: $0.id) < order(of: $1.id) } }

    // A quiet poll re-delivers a page already fully held. If every incoming id is present with
    // an equal body, the merge is a copy that changes nothing — so return the held array
    // unchanged and allocate nothing on the 1.5s tick. Cursor widening is decided by the
    // caller from the page boundaries, not from here, so this only skips the array rebuild.
    var heldByID: [String: TimelineItem] = Dictionary(minimumCapacity: held.count)
    for item in held { heldByID[item.id] = item }
    let isNoOp = page.allSatisfy { heldByID[$0.id] == $0 }
    if isNoOp { return held }

    let incoming = page.sorted { order(of: $0.id) < order(of: $1.id) }
    var merged: [TimelineItem] = []
    merged.reserveCapacity(held.count + incoming.count)
    var h = held.startIndex
    var i = incoming.startIndex
    while h < held.endIndex, i < incoming.endIndex {
        let there = order(of: held[h].id)
        let here = order(of: incoming[i].id)
        if there < here {
            merged.append(held[h]); h += 1
        } else if here < there {
            merged.append(incoming[i]); i += 1
        } else if held[h].id == incoming[i].id {
            merged.append(incoming[i]); h += 1; i += 1
        } else {
            merged.append(held[h]); h += 1
        }
    }
    merged.append(contentsOf: held[h...])
    merged.append(contentsOf: incoming[i...])
    return merged
}
```

`TimelineItem` is `Equatable` (via `Hashable`), so `heldByID[$0.id] == $0` compares the whole item including body. A same-id-longer-body page has `page[i] != held[i]`, so `isNoOp` is false and the full merge runs — the existing replace-by-id path handles it. When `isNoOp` returns `held`, `merge`'s `items != before` compares the array to itself → `false`.

**Step 4 — Run to pass.** `./scripts/test-unit.sh` green (all `TimelineFeedTests`, including the existing idempotency and replace-by-id tests, still pass).

**Step 5 — Commit.**
```
git add -A
git commit -m "Skip the array rebuild on a no-op merge

A quiet poll re-delivers a fully-held page; detect it and return the held array
unchanged so a 1.5s tick allocates nothing. A same-id-longer-body page is still
a real change and is not skipped.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2.3 — Per-row segment memo

**Files**
- Create: `Sources/FlightDeckMobile/TimelineSegmentCache.swift`
- Modify: `Sources/FlightDeckMobile/TimelineRow.swift` (`segments` at `:257-259`; add `cache` + `widthBucket` inputs)
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (own the cache, pass it into `TimelineRow` in `entryRow` at `:449-461`)
- Test: `Tests/FlightDeckMobileTests/TimelineSegmentCacheTests.swift` (new)

**Interfaces**
- Produces:
  - `final class TimelineSegmentCache { func clamped(for item: TimelineItem, expanded: Bool, widthBucket: Int) -> TimelineSegmenter.Clamped; private(set) var computeCount: Int; init(capacity: Int = 60) }`
- Consumes: `TimelineStyle.clampedProse(for:expanded:) -> TimelineSegmenter.Clamped` (`TimelineStyle.swift:460`), `TimelineSegmenter.Clamped` (`TimelineSegments.swift:74`).

**Step 1 — Write the failing test.** Create `Tests/FlightDeckMobileTests/TimelineSegmentCacheTests.swift`:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

@MainActor
final class TimelineSegmentCacheTests: XCTestCase {
    private func prose(_ id: String) -> TimelineItem {
        TimelineItem(id: id, kind: .assistantText, status: .complete,
                     body: .init(text: "**bold** and `code` across a line or two"))
    }

    func testASecondCallWithTheSameKeyIsAMemoHit() {
        let cache = TimelineSegmentCache()
        let item = prose("0#0")
        let first = cache.clamped(for: item, expanded: false, widthBucket: 12)
        let second = cache.clamped(for: item, expanded: false, widthBucket: 12)
        XCTAssertEqual(cache.computeCount, 1, "the segmenter ran once for two identical asks")
        XCTAssertEqual(first, second)
    }

    func testExpandedAndWidthAndIdAreEachPartOfTheKey() {
        let cache = TimelineSegmentCache()
        let item = prose("0#0")
        _ = cache.clamped(for: item, expanded: false, widthBucket: 12)
        _ = cache.clamped(for: item, expanded: true, widthBucket: 12)   // expanded differs
        _ = cache.clamped(for: item, expanded: false, widthBucket: 11)  // width differs
        _ = cache.clamped(for: prose("10#0"), expanded: false, widthBucket: 12) // id differs
        XCTAssertEqual(cache.computeCount, 4, "each axis of the key is a distinct entry")
    }

    func testTheCacheIsBoundedAndEvicts() {
        let cache = TimelineSegmentCache(capacity: 2)
        _ = cache.clamped(for: prose("0#0"), expanded: false, widthBucket: 1)
        _ = cache.clamped(for: prose("1#0"), expanded: false, widthBucket: 1)
        _ = cache.clamped(for: prose("2#0"), expanded: false, widthBucket: 1) // evicts 0#0
        _ = cache.clamped(for: prose("0#0"), expanded: false, widthBucket: 1) // recompute
        XCTAssertEqual(cache.computeCount, 4, "the evicted key recomputes rather than hitting")
    }
}
```

**Step 2 — Run to fail.** `./scripts/test-ios.sh` → `cannot find 'TimelineSegmentCache'`.

**Step 3 — Minimal implementation.** Create `Sources/FlightDeckMobile/TimelineSegmentCache.swift`:

```swift
import FleetKit

/// The clamped-segments memo for the prose rows on one screen.
///
/// A row's segmenter used to run three times per render — through `expandsInPlace`, through
/// `segments`, and through the accessibility label — each splitting the full body again, on
/// every re-render and every poll tick. This caches the split, keyed by exactly what changes
/// it: the item id, whether the row is expanded, and the width bucket the row laid out at.
///
/// Bounded (visible rows plus a margin) and evicted least-recently-used, so a long scroll never
/// grows it without bound. Owned by the screen and handed to each row, so it outlives cell
/// recycling and is drivable by a test with no window.
@MainActor
final class TimelineSegmentCache {
    struct Key: Hashable {
        let id: String
        let expanded: Bool
        let widthBucket: Int
    }

    private let capacity: Int
    private var store: [Key: TimelineSegmenter.Clamped] = [:]
    private var order: [Key] = []  // least-recently-used first
    /// How many times the underlying segmenter actually ran — a miss. Tests assert on it.
    private(set) var computeCount = 0

    init(capacity: Int = 60) {
        self.capacity = max(1, capacity)
    }

    func clamped(for item: TimelineItem, expanded: Bool, widthBucket: Int) -> TimelineSegmenter.Clamped {
        let key = Key(id: item.id, expanded: expanded, widthBucket: widthBucket)
        if let hit = store[key] {
            touch(key)
            return hit
        }
        computeCount += 1
        let value = TimelineStyle.clampedProse(for: item, expanded: expanded)
        store[key] = value
        order.append(key)
        evictIfNeeded()
        return value
    }

    private func touch(_ key: Key) {
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            store.removeValue(forKey: oldest)
        }
    }
}
```

In `TimelineRow.swift`, thread the cache and a width bucket. Add stored inputs and route `segments` through the cache (`:257-259`):

```swift
/// The screen's shared segment memo, and the width the row laid out at. Optional so a row
/// built with no screen behind it — the offscreen harnesses, the filler rows in tests —
/// segments directly through `TimelineStyle` as it always has.
var segmentCache: TimelineSegmentCache?
var widthBucket: Int = 0
```

Replace `segments`:

```swift
private var segments: [TimelineSegment] {
    clamped.segments
}

private var clamped: TimelineSegmenter.Clamped {
    if let segmentCache {
        return segmentCache.clamped(for: item, expanded: isExpanded, widthBucket: widthBucket)
    }
    return TimelineStyle.clampedProse(for: item, expanded: isExpanded)
}
```

And route the `expandsInPlace` check through the same cached value so the row's three passes collapse to one. In `chips` (`:352`) and `expandActionName` (`:101-104`), replace `TimelineStyle.expandsInPlace(item)` with a row-local check that reuses `clamped`:

```swift
private var expandsInPlace: Bool {
    TimelineStyle.rendersMarkdown(item) && clamped.hasMore
}
```
(Use `expandsInPlace` — the row's own — at `:102` and `:352`.) This preserves the exact semantics of `TimelineStyle.expandsInPlace` (`TimelineStyle.swift:446-448`), which is `rendersMarkdown(item) && clampedProse(for: item).hasMore`.

In `SessionTimelineScreen.swift`, own the cache and measure width. Add `@State private var segmentCache = TimelineSegmentCache()` near the other `@State` (`:57`). In `entryRow`'s `TimelineRow(...)` construction (`:449-461`), pass the cache and a measured width bucket:

```swift
let row = TimelineRow(
    item: entry.item, result: entry.result, agent: session?.agent,
    isExpanded: expansion.isExpanded(entry.id),
    toggleExpanded: { expansion.toggle(entry.id) },
    onReply: { model.quote($0) },
    segmentCache: segmentCache,
    widthBucket: widthBucket
)
```

Measure the list width once with a background reader on the `List` and bucket it (add `@State private var widthBucket = 0` and, on the `List` at `:147`):

```swift
.background(
    GeometryReader { geo in
        Color.clear.onAppear { widthBucket = Int((geo.size.width / 32).rounded()) }
            .onChange(of: geo.size.width) { _, w in widthBucket = Int((w / 32).rounded()) }
    }
)
```

Bucketing at 32-point granularity keeps a hairline width jitter from invalidating the memo while still distinguishing portrait from landscape / split-view widths — which change how many characters fit per line and therefore where the clamp lands.

**Step 4 — Run to pass.** `./scripts/test-ios.sh` green (the cache tests, plus `ProseExpansionRecyclingTests` and `TimelineSegmentTests` unchanged — the harness builds `TimelineRow` with no cache, so it takes the direct-segment path).

**Step 5 — Commit.**
```
git add -A
git commit -m "Memoize clamped prose segments per (id, expanded, width)

A row's three segmenter passes collapse to one cached split that survives
re-render. Bounded LRU, owned by the screen, evicted with the visible window.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2.4 — Shared static date formatters

**Files**
- Modify: `Sources/FlightDeckMobile/TimelineStyle.swift` (`date(_:)` at `:180-187`)
- Test: `Tests/FlightDeckMobileTests/TimelineStyleDateTests.swift` (new, unless a `TimelineStyle`-facing file already exists)

**Interfaces**
- Produces: two shared formatters (private); `date(_:)` behaviour unchanged (both spellings still parse; unparseable → nil).

**Step 1 — Write the failing test.** Create/extend a test asserting behaviour is preserved:

```swift
import FleetKit
import XCTest
@testable import FlightDeckMobile

final class TimelineStyleDateTests: XCTestCase {
    func testBothISO8601SpellingsStillParse() {
        // Claude writes fractional seconds; codex does not. Both must format to a HH:MM time.
        XCTAssertNotNil(TimelineStyle.time("2026-09-12T14:30:05.123Z"))
        XCTAssertNotNil(TimelineStyle.time("2026-09-12T14:30:05Z"))
    }

    func testAnUnparseableTimestampIsNilNotALie() {
        XCTAssertNil(TimelineStyle.time("not a date"))
        XCTAssertNil(TimelineStyle.time(nil))
    }
}
```

**Step 2 — Run to fail / baseline.** `./scripts/test-ios.sh` — green if `time` is already correct; this test pins behaviour across the refactor. Run it before and after the change.

**Step 3 — Minimal implementation.** In `TimelineStyle.swift`, add the shared formatters (near the top of the type, alongside other `static let`s) and rewrite `date(_:)`:

```swift
/// The two spellings ISO-8601 arrives in, allocated once. Claude writes fractional seconds
/// and codex does not, and `ISO8601DateFormatter` fails the spelling it was not configured
/// for, so both are kept. `date(_:)` used to allocate BOTH of these on every call — twice per
/// row per render on a list hundreds of rows long. `ISO8601DateFormatter` is thread-safe for
/// reading; `nonisolated(unsafe)` states that fact for Swift 6 rather than hiding a hazard.
nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private static func date(_ raw: String) -> Date? {
    isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
}
```

(If `TimelineStyle` is not `@MainActor`-isolated, plain `private static let` without `nonisolated(unsafe)` is fine; keep whichever the compiler accepts. The semantic requirement is one shared instance of each, not per-call allocation.)

**Step 4 — Run to pass.** `./scripts/test-ios.sh` green.

**Step 5 — Commit.**
```
git add -A
git commit -m "Share the two ISO8601 date formatters instead of per-call allocation

date(_:) allocated two formatters on every call — twice per row per render.
Two shared static instances; both spellings still parse.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

# Part 3 — Cross-session model eviction

---

## Task 3.1 — LRU eviction of `timelineModels`

**Files**
- Modify: `Sources/FlightDeckMobile/FleetModel.swift` (`timelineModels` at `:44`; `timelineModel(for:)` at `:429-434`; `unpair()` at `:242`)
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift` (add `hasOutstandingWork`)
- Test: `Tests/FlightDeckMobileTests/FleetModelTests.swift` (extend — runs via `test-ios.sh`)

**Interfaces**
- Produces (on `SessionTimelineModel`): `var hasOutstandingWork: Bool { !outbox.entries.isEmpty || blocked != nil || answerState.call != nil }`
- Produces (on `FleetModel`): `func timelineModel(for id: UUID) -> SessionTimelineModel` (unchanged signature, now with LRU tracking + eviction); `@ObservationIgnored private var timelineViewOrder: [UUID]`; `static let maxKeptTimelineModels = 8`; `@ObservationIgnored private(set) var evictedTimelineModelIDs: Set<UUID>` (test seam); `private func evictIdleTimelineModels()`.
- Consumes: `SessionTimelineModel.isOnScreen` (`:623`), `outbox`, `blocked` (Part 2), `answerState` (`:214`).

**Step 1 — Write the failing test.** In `FleetModelTests.swift`:

```swift
@MainActor
func testOpeningManySessionsEvictsAllButTheMostRecentlyViewed() {
    let model = FleetModel.fixture()   // existing test factory used elsewhere in this file
    var ids: [UUID] = []
    for _ in 0..<(FleetModel.maxKeptTimelineModels + 3) {
        let id = UUID(); ids.append(id)
        _ = model.timelineModel(for: id)
    }
    let kept = ids.suffix(FleetModel.maxKeptTimelineModels)
    for id in kept { XCTAssertFalse(model.evictedTimelineModelIDs.contains(id)) }
    for id in ids.prefix(3) { XCTAssertTrue(model.evictedTimelineModelIDs.contains(id)) }
}

@MainActor
func testAModelWithAnOutstandingOutboxEntryIsNotEvicted() {
    let model = FleetModel.fixture()
    let sticky = UUID()
    let stickyModel = model.timelineModel(for: sticky)
    stickyModel.send("a message that will sit unacked with no connector")  // fixture: no socket
    XCTAssertTrue(stickyModel.hasOutstandingWork, "the outbox holds an unretired entry")
    for _ in 0..<(FleetModel.maxKeptTimelineModels + 3) { _ = model.timelineModel(for: UUID()) }
    XCTAssertFalse(model.evictedTimelineModelIDs.contains(sticky),
                   "a model with outstanding work is never evicted")
}

@MainActor
func testReopeningAnEvictedModelReturnsAFreshOne() {
    let model = FleetModel.fixture()
    let first = UUID()
    let a = model.timelineModel(for: first)
    for _ in 0..<(FleetModel.maxKeptTimelineModels + 3) { _ = model.timelineModel(for: UUID()) }
    XCTAssertTrue(model.evictedTimelineModelIDs.contains(first))
    let b = model.timelineModel(for: first)
    XCTAssertFalse(a === b, "a reopened evicted session gets a fresh model that re-fetches")
    XCTAssertFalse(model.evictedTimelineModelIDs.contains(first), "reopening un-evicts it")
}
```

(`FleetModel.fixture()` is referenced by existing `sentCommands` comments at `:51-54`; reuse it. `send(_:)` with no connector completes synchronously with `.disconnected` → the outbox entry is added then failed but stays present, so `hasOutstandingWork` is true — a failed entry is still an unretired outbox row the reader must see. If the fixture path retires it, adjust the assertion to build outstanding work directly via a `.waiting` blocked value; either is a legitimate "not idle" signal.)

**Step 2 — Run to fail.** `./scripts/test-ios.sh` → `no member 'maxKeptTimelineModels'` / `'evictedTimelineModelIDs'` / `'hasOutstandingWork'`.

**Step 3 — Minimal implementation.** In `SessionTimelineModel.swift`, add:

```swift
/// Whether this model must not be evicted: it holds a message the reader was told is in
/// flight, or a dialog they may still answer. Only a truly idle model is eligible to be
/// dropped and rebuilt on reopen.
var hasOutstandingWork: Bool {
    !outbox.entries.isEmpty || blocked != nil || answerState.call != nil
}
```

(If `answerState` has no `call` member, use the file's actual "an answer is outstanding" predicate — e.g. `answerState != .idle`; the intent is "a dialog the reader may still answer is open".)

In `FleetModel.swift`, add near `timelineModels` (`:44`):

```swift
/// The tab ids of the open session models in view order, most-recently-viewed last. Bounds
/// `timelineModels`: everything past the cap that is neither on screen nor holding outstanding
/// work is dropped and rebuilt on reopen.
@ObservationIgnored private var timelineViewOrder: [UUID] = []

/// The most-recently-viewed models to keep resident, plus whatever is on screen. Small on
/// purpose: a `TimelineFeed` for a long session is the one thing here that grows, and a reader
/// who has opened ten sessions has no use for the feed of the eight-tabs-ago one.
static let maxKeptTimelineModels = 8

/// The tab ids evicted since launch, for the tests — reaching eviction through the real path
/// needs a Mac and a socket. Cleared for an id the moment it is reopened.
@ObservationIgnored private(set) var evictedTimelineModelIDs: Set<UUID> = []
```

Rewrite `timelineModel(for:)` (`:429-434`):

```swift
func timelineModel(for id: UUID) -> SessionTimelineModel {
    // Reopening an evicted (or never-seen) tab makes it the most recent again.
    timelineViewOrder.removeAll { $0 == id }
    timelineViewOrder.append(id)
    evictedTimelineModelIDs.remove(id)

    let model: SessionTimelineModel
    if let existing = timelineModels[id] {
        model = existing
    } else {
        model = SessionTimelineModel(sessionID: id, fleet: self)
        timelineModels[id] = model
    }
    evictIdleTimelineModels()
    return model
}

/// Keep the most-recently-viewed cap plus the on-screen model plus any model holding
/// outstanding work; drop the rest. An evicted model's `TimelineFeed` goes with it, and
/// `timelineModel(for:)` recreates it on reopen — the same path a first open takes, re-fetching
/// from `.latest`. The reconnect fan-out (`onState`) naturally skips evicted models: nothing
/// observes a model that is not resident.
private func evictIdleTimelineModels() {
    guard timelineModels.count > Self.maxKeptTimelineModels else { return }
    let keepRecent = Set(timelineViewOrder.suffix(Self.maxKeptTimelineModels))
    for (id, model) in timelineModels {
        guard !keepRecent.contains(id), !model.isOnScreen, !model.hasOutstandingWork else { continue }
        timelineModels.removeValue(forKey: id)
        timelineViewOrder.removeAll { $0 == id }
        evictedTimelineModelIDs.insert(id)
    }
}
```

In `unpair()` (`:242`, where `timelineModels.removeAll()` already lives), also clear the new state for the same privacy reasoning the file gives: `timelineViewOrder.removeAll()` and `evictedTimelineModelIDs.removeAll()`.

**Step 4 — Run to pass.** `./scripts/test-ios.sh` green (existing `FleetModelTests` and the `unpair()` clearing still pass).

**Step 5 — Commit.**
```
git add -A
git commit -m "Bound timelineModels to the most-recently-viewed plus on-screen

Evict idle session models past a cap of 8; never evict one on screen or holding
an unretired outbox entry or open prompt. Reopen recreates and re-fetches.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3.2 — Memory-warning eviction (all but on-screen)

**Files**
- Modify: `Sources/FlightDeckMobile/FleetModel.swift` (subscribe in `init`; add `handleMemoryWarning()`)
- Test: `Tests/FlightDeckMobileTests/FleetModelTests.swift` (extend)

**Interfaces**
- Produces (on `FleetModel`): `func handleMemoryWarning()` (internal, so a test can invoke it without posting a real notification); a `NotificationCenter` observer registered for `UIApplication.didReceiveMemoryWarningNotification`.

**Step 1 — Write the failing test.** In `FleetModelTests.swift`:

```swift
@MainActor
func testAMemoryWarningEvictsEverythingButTheOnScreenAndBusyModels() {
    let model = FleetModel.fixture()
    let onScreen = UUID(), idle = UUID(), busy = UUID()
    model.timelineModel(for: onScreen).viewing(true)
    _ = model.timelineModel(for: idle)
    model.timelineModel(for: busy).send("stuck")   // outstanding work, no socket

    model.handleMemoryWarning()

    XCTAssertTrue(model.evictedTimelineModelIDs.contains(idle), "an idle off-screen model goes")
    XCTAssertFalse(model.evictedTimelineModelIDs.contains(onScreen), "the on-screen model stays")
    XCTAssertFalse(model.evictedTimelineModelIDs.contains(busy), "outstanding work stays")
}
```

**Step 2 — Run to fail.** `./scripts/test-ios.sh` → `no member 'handleMemoryWarning'`.

**Step 3 — Minimal implementation.** In `FleetModel.swift`, add the handler and register for the notification. Add to `init` (after `mac` is loaded, `:70-99`):

```swift
NotificationCenter.default.addObserver(
    forName: UIApplication.didReceiveMemoryWarningNotification,
    object: nil, queue: .main
) { [weak self] _ in
    MainActor.assumeIsolated { self?.handleMemoryWarning() }
}
```

Add the method near `evictIdleTimelineModels`:

```swift
/// Under memory pressure, keep only what the reader is actually looking at (plus anything
/// mid-send or mid-answer) and drop every other session's feed. The OS is asking for memory
/// back and a held transcript is the largest thing here that is safe to rebuild on reopen.
func handleMemoryWarning() {
    for (id, model) in timelineModels {
        guard !model.isOnScreen, !model.hasOutstandingWork else { continue }
        timelineModels.removeValue(forKey: id)
        timelineViewOrder.removeAll { $0 == id }
        evictedTimelineModelIDs.insert(id)
    }
    PhoneLog.connection.notice(
        "memory-warning evicted timeline models kept=\(self.timelineModels.count, privacy: .public)"
    )
}
```

(`UIApplication` is available — the file imports `UIKit`. `PhoneLog` is already used throughout; match the existing logger name if `PhoneLog.connection` differs.)

**Step 4 — Run to pass.** `./scripts/test-ios.sh` green.

**Step 5 — Commit.**
```
git add -A
git commit -m "Evict all but the on-screen model on a memory warning

Register for didReceiveMemoryWarningNotification and drop every idle session's
feed under pressure; on-screen and mid-send models stay.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

# Part 4 — Per-session disk-spill (hard memory ceiling)

---

## Task 4.1 — `Body.isPlaceholder` transient flag + placeholder helper

**Files**
- Modify: `Sources/FleetKit/Timeline.swift` (`Body` at `:67-139`)
- Test: `Tests/FlightDeckTests/TimelinePlaceholderTests.swift` (new, macOS suite)

**Interfaces**
- Produces (on `TimelineItem.Body`):
  - `public var isPlaceholder: Bool` (stored, defaults `false`, **not encoded** — decode always yields `false`, keeping the wire contract untouched)
  - memberwise init gains trailing `isPlaceholder: Bool = false`
  - `public func spilledPlaceholder() -> Body` — returns a copy with `text` replaced by a first-line preview and `isPlaceholder = true`, preserving `summary`, `tool`, `callID`, `truncatedBytes`, `isError`.
  - `public static func placeholderPreview(of text: String, limit: Int = 80) -> String`

**Step 1 — Write the failing test.** Create `Tests/FlightDeckTests/TimelinePlaceholderTests.swift`:

```swift
import XCTest
@testable import FleetKit

final class TimelinePlaceholderTests: XCTestCase {
    func testAFreshBodyIsNotAPlaceholder() {
        XCTAssertFalse(TimelineItem.Body(text: "hi").isPlaceholder)
    }

    func testSpilledPlaceholderKeepsEverythingButTheFullText() {
        let body = TimelineItem.Body(
            text: "first line of a long body\nsecond line\nthird",
            summary: "sum", tool: "Bash", callID: "tA", truncatedBytes: 42, isError: true
        )
        let placeholder = body.spilledPlaceholder()
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertEqual(placeholder.text, "first line of a long body", "preview is the first line")
        XCTAssertEqual(placeholder.summary, "sum")
        XCTAssertEqual(placeholder.tool, "Bash")
        XCTAssertEqual(placeholder.callID, "tA")
        XCTAssertEqual(placeholder.truncatedBytes, 42)
        XCTAssertTrue(placeholder.isError)
    }

    /// The wire contract is untouched: `isPlaceholder` never crosses the wire, so a decoded
    /// body is never a placeholder however it was encoded.
    func testIsPlaceholderNeverRoundTripsThroughCoding() throws {
        var body = TimelineItem.Body(text: "x")
        body.isPlaceholder = true
        let data = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(TimelineItem.Body.self, from: data)
        XCTAssertFalse(decoded.isPlaceholder, "a decoded body is never a placeholder")
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("isPlaceholder"),
                       "the flag is not an encoded key")
    }
}
```

**Step 2 — Run to fail.** `./scripts/test-unit.sh` → `no member 'isPlaceholder'` / `'spilledPlaceholder'`.

**Step 3 — Minimal implementation.** In `Timeline.swift`, add to `Body` after `isError` (`:99`):

```swift
/// Whether this body's full text has been spilled to disk and only a first-line preview is
/// resident. **In-memory only — never encoded, never decoded** (see the coding below), so the
/// wire contract is untouched: a body that crosses the socket is always the real thing.
/// `TimelineFeed.spill`/`rehydrate` set and clear this; a placeholder row draws a skeleton.
public var isPlaceholder: Bool = false
```

Add the trailing init parameter (`:101-111`), keeping the default so every existing call site is source-compatible:

```swift
public init(
    text: String, summary: String? = nil, tool: String? = nil,
    callID: String? = nil, truncatedBytes: Int = 0, isError: Bool = false,
    isPlaceholder: Bool = false
) {
    self.text = text
    self.summary = summary
    self.tool = tool
    self.callID = callID
    self.truncatedBytes = truncatedBytes
    self.isError = isError
    self.isPlaceholder = isPlaceholder
}
```

The hand-written `encode(to:)` (`:120-128`) and `init(from:)` (`:130-138`) are left exactly as they are — they never touch `isPlaceholder`, so it never encodes and always decodes to the `false` default. (If `Body` uses synthesized `Codable` rather than hand-written, add an explicit `CodingKeys` enum that omits `isPlaceholder` so the flag stays off the wire; verify at edit time which the file uses.) Add the helpers to `Body`:

```swift
/// A first-line preview cheap enough to keep resident for a spilled row's skeleton.
public static func placeholderPreview(of text: String, limit: Int = 80) -> String {
    let firstLine = text.prefix { $0 != "\n" }
    return String(firstLine.prefix(limit))
}

/// This body with its full text swapped for a preview and marked spilled, keeping everything a
/// row skeleton needs — the summary, the tool, the callID, the truncation count, the error
/// flag. The full text is written to the spill store by the caller before this is installed.
public func spilledPlaceholder() -> Body {
    Body(
        text: Self.placeholderPreview(of: text), summary: summary, tool: tool,
        callID: callID, truncatedBytes: truncatedBytes, isError: isError, isPlaceholder: true
    )
}
```

**Step 4 — Run to pass.** `./scripts/test-unit.sh` green (existing `Timeline`/`TimelineFeed` tests unaffected — all existing bodies are constructed with the default `isPlaceholder: false`).

**Step 5 — Commit.**
```
git add -A
git commit -m "Add a transient Body.isPlaceholder + spill preview helper

A spilled body keeps id/kind/callID/summary and a first-line preview; the flag
is in-memory only and never crosses the wire.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4.2 — `TimelineSpillStore` (Codable per-session cache under Caches)

**Files**
- Create: `Sources/FleetKit/TimelineSpillStore.swift`
- Test: `Tests/FlightDeckTests/TimelineSpillStoreTests.swift` (new, macOS suite)

**Interfaces**
- Produces:
  - `public final class TimelineSpillStore { public init(session: UUID, directory: URL? = nil); public func write(_ bodies: [String: TimelineItem.Body]); public func read(_ ids: Set<String>) -> [String: TimelineItem.Body]; public func purge() }`
- Consumes: `TimelineItem.Body` is `Codable` (`Timeline.swift:67`).

**Step 1 — Write the failing test.** Create `Tests/FlightDeckTests/TimelineSpillStoreTests.swift`:

```swift
import XCTest
@testable import FleetKit

final class TimelineSpillStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spill-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testWriteThenReadRoundTripsTheBodies() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineSpillStore(session: UUID(), directory: dir)
        let bodies = [
            "0#0": TimelineItem.Body(text: "full body one", callID: "tA"),
            "10#0": TimelineItem.Body(text: "full body two"),
        ]
        store.write(bodies)
        let read = store.read(["0#0", "10#0"])
        XCTAssertEqual(read["0#0"]?.text, "full body one")
        XCTAssertEqual(read["0#0"]?.callID, "tA")
        XCTAssertEqual(read["10#0"]?.text, "full body two")
    }

    func testWriteAppendsRatherThanReplacingTheWholeFile() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineSpillStore(session: UUID(), directory: dir)
        store.write(["0#0": TimelineItem.Body(text: "one")])
        store.write(["10#0": TimelineItem.Body(text: "two")])
        let read = store.read(["0#0", "10#0"])
        XCTAssertEqual(read.count, 2, "a second write does not lose the first record")
    }

    /// A purged cache (the OS may drop a Caches file under pressure) reads empty — the model's
    /// wire-refetch fallback covers it.
    func testReadingAPurgedStoreReturnsEmpty() {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = TimelineSpillStore(session: UUID(), directory: dir)
        store.write(["0#0": TimelineItem.Body(text: "one")])
        store.purge()
        XCTAssertTrue(store.read(["0#0"]).isEmpty)
    }
}
```

**Step 2 — Run to fail.** `./scripts/test-unit.sh` → `cannot find 'TimelineSpillStore'`.

**Step 3 — Minimal implementation.** Create `Sources/FleetKit/TimelineSpillStore.swift`:

```swift
import Foundation

/// A per-session cache of spilled timeline body text, keyed by item id, under `Caches`.
///
/// Part of the hard memory ceiling: when a single session's resident text grows past a byte
/// budget, `TimelineFeed.spill` swaps the full `body.text` of items far from the visible window
/// for a placeholder preview and hands the originals here to persist. On approach,
/// `rehydrate` reads them back synchronously — local and fast, no loading flash. The file lives
/// under `Caches`, so the OS may purge it under pressure; a purged read returns empty and the
/// model falls back to a wire re-fetch of that offset range.
///
/// `TimelineItem.Body` is `Codable`, so a record is the body itself — nothing bespoke to keep in
/// sync with the wire type.
public final class TimelineSpillStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "flightdeck.timeline-spill")

    public init(session: UUID, directory: URL? = nil) {
        let base = directory ?? Self.defaultCachesDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("\(session.uuidString).json", isDirectory: false)
    }

    private static func defaultCachesDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("FlightDeckTimelineSpill", isDirectory: true)
    }

    /// Merge `bodies` into the file. Appends rather than replacing, so successive spills as the
    /// window moves accumulate rather than clobbering earlier records.
    public func write(_ bodies: [String: TimelineItem.Body]) {
        guard !bodies.isEmpty else { return }
        queue.sync {
            var current = readAll()
            for (id, body) in bodies { current[id] = body }
            if let data = try? JSONEncoder().encode(current) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
    }

    /// The bodies for `ids` that the cache still holds. A missing id — never written, or purged
    /// — is simply absent; the caller's wire fallback covers it.
    public func read(_ ids: Set<String>) -> [String: TimelineItem.Body] {
        queue.sync {
            let all = readAll()
            return all.filter { ids.contains($0.key) }
        }
    }

    public func purge() {
        queue.sync { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func readAll() -> [String: TimelineItem.Body] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: TimelineItem.Body].self, from: data)
        else { return [:] }
        return decoded
    }
}
```

**Step 4 — Run to pass.** `./scripts/test-unit.sh` green.

**Step 5 — Commit.**
```
git add -A
git commit -m "Add TimelineSpillStore: a Codable per-session text cache under Caches

Write/read/purge spilled body text keyed by item id. A purged read returns
empty so the model can fall back to a wire re-fetch.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4.3 — `TimelineFeed.spill(_:)` / `rehydrate(_:)`; merge clears a placeholder

**Files**
- Modify: `Sources/FleetKit/TimelineFeed.swift` (add `spill`/`rehydrate`; the replace-by-id merge path at `:142-147` already clears a placeholder — add a test to pin it)
- Test: `Tests/FlightDeckTests/TimelineFeedTests.swift` (extend)

**Interfaces**
- Produces (on `TimelineFeed`):
  - `@discardableResult public mutating func spill(_ ids: Set<String>) -> [String: TimelineItem.Body]` — returns the original bodies removed, for the store.
  - `public mutating func rehydrate(_ bodies: [String: TimelineItem.Body])`
- Consumes: `TimelineItem.Body.spilledPlaceholder()` (Task 4.1), `TimelineItem.Body.isPlaceholder`.

**Step 1 — Write the failing test.** In `TimelineFeedTests.swift`:

```swift
func testSpillSwapsBodyTextForAPlaceholderWithoutTouchingOrderOrCursors() {
    var feed = TimelineFeed()
    feed.merge(page([item("0#0", "aaa long"), item("10#0", "bbb long"), item("20#0", "ccc long")],
                    start: 0, end: 30, hasMore: true))
    let originals = feed.spill(["0#0", "20#0"])

    XCTAssertEqual(feed.items.map(\.id), ["0#0", "10#0", "20#0"], "order is untouched")
    XCTAssertTrue(feed.items[0].body.isPlaceholder)
    XCTAssertFalse(feed.items[1].body.isPlaceholder, "an unspilled item is unchanged")
    XCTAssertTrue(feed.items[2].body.isPlaceholder)
    XCTAssertEqual(originals["0#0"]?.text, "aaa long", "the full body is returned for the store")
    XCTAssertEqual(feed.oldest, 0)
    XCTAssertEqual(feed.newest, 30)
    XCTAssertTrue(feed.hasOlder)
}

func testRehydrateRestoresTheFullBodyAndClearsThePlaceholder() {
    var feed = TimelineFeed()
    feed.merge(page([item("0#0", "aaa long")], start: 0, end: 10))
    let originals = feed.spill(["0#0"])
    XCTAssertTrue(feed.items[0].body.isPlaceholder)
    feed.rehydrate(originals)
    XCTAssertFalse(feed.items[0].body.isPlaceholder)
    XCTAssertEqual(feed.items[0].body.text, "aaa long")
}

/// A merge that re-delivers a spilled id with a full body must clear the placeholder — a
/// re-delivery never leaves a stale placeholder.
func testMergingAFullBodyClearsAHeldPlaceholder() {
    var feed = TimelineFeed()
    feed.merge(page([item("0#0", "aaa long")], start: 0, end: 10))
    _ = feed.spill(["0#0"])
    XCTAssertTrue(feed.items[0].body.isPlaceholder)
    let changed = feed.merge(page([item("0#0", "aaa long")], start: 0, end: 10))
    XCTAssertTrue(changed, "a full body replacing a placeholder is a real change")
    XCTAssertFalse(feed.items[0].body.isPlaceholder, "the incoming full body is authoritative")
    XCTAssertEqual(feed.items[0].body.text, "aaa long")
}
```

**Step 2 — Run to fail.** `./scripts/test-unit.sh` → `no member 'spill'` / `'rehydrate'`.

**Step 3 — Minimal implementation.** In `TimelineFeed.swift`, add after `merge` (`:103`):

```swift
/// Swap the full `body.text` of each item in `ids` for a placeholder preview, returning the
/// original bodies for the spill store. **Ordering and both cursors are untouched** — this only
/// mutates body text in place, which is the clean part this approach buys over eviction: the
/// paging cursors never learn a spill happened. An id not present, or already a placeholder, is
/// skipped.
@discardableResult
public mutating func spill(_ ids: Set<String>) -> [String: TimelineItem.Body] {
    guard !ids.isEmpty else { return [:] }
    var originals: [String: TimelineItem.Body] = [:]
    for index in items.indices {
        let item = items[index]
        guard ids.contains(item.id), !item.body.isPlaceholder else { continue }
        originals[item.id] = item.body
        items[index].body = item.body.spilledPlaceholder()
    }
    return originals
}

/// Restore full bodies for the ids in `bodies`, clearing their placeholders. Ordering and
/// cursors are untouched, exactly as `spill`. An id not present is skipped.
public mutating func rehydrate(_ bodies: [String: TimelineItem.Body]) {
    guard !bodies.isEmpty else { return }
    for index in items.indices {
        if let full = bodies[items[index].id] { items[index].body = full }
    }
}
```

The merge replace-by-id path (`:142-147`) already appends `incoming[i]` on an equal id, so a re-delivered full body (with `isPlaceholder == false`) replaces a held placeholder unconditionally. The Part 2 no-op early-out compares whole items (`heldByID[$0.id] == $0`), and a placeholder held ≠ a full-body incoming (text and `isPlaceholder` differ), so the merge is not skipped. No merge change is needed — the third test pins this behaviour.

**Step 4 — Run to pass.** `./scripts/test-unit.sh` green.

**Step 5 — Commit.**
```
git add -A
git commit -m "Add TimelineFeed spill/rehydrate that leave ordering and cursors intact

spill swaps body text for a placeholder in place and returns the originals for
the store; rehydrate restores them. A re-delivered full body clears a
placeholder through the existing replace-by-id path.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4.4 — Model-driven spill/rehydrate scheduling with hysteresis + wire fallback

**Files**
- Modify: `Sources/FlightDeckMobile/SessionTimelineModel.swift` (add spill store + budget/margins + `reportVisibleWindow`; call `reconcileSpill()`; add optional `spillDirectory` init param)
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (report the visible window from row `.onAppear`/`.onDisappear`)
- Test: `Tests/FlightDeckMobileTests/SessionTimelineModelTests.swift` (extend)

**Interfaces**
- Produces (on `SessionTimelineModel`):
  - `func reportVisibleWindow(firstID: String?, lastID: String?)`
  - `@ObservationIgnored private var spillStore: TimelineSpillStore`
  - `static let spillBudgetBytes = 2_000_000`, `static let spillMargin = 200`, `static let rehydrateMargin = 60`
  - `@ObservationIgnored var spillBudgetBytesOverride: Int?`, `@ObservationIgnored var spillMarginOverride: Int?` (test hooks, mirroring `promptRetries`)
  - `private func reconcileSpill()`
  - init gains `spillDirectory: URL? = nil`
- Consumes: `TimelineFeed.spill/rehydrate` (Task 4.3), `TimelineSpillStore` (Task 4.2), `fetch(anchor: .around(offset), older: false, quiet: true)` (`:850`).

**Step 1 — Write the failing test.** In `SessionTimelineModelTests.swift`:

```swift
@MainActor
func testItemsFarFromTheWindowSpillWhenOverBudget() {
    let pager = StubPager()
    let model = model(pager)   // pass a temp spillDirectory via the model(_:) helper
    model.spillBudgetBytesOverride = 100     // tiny, so a few bodies exceed it
    model.spillMarginOverride = 1
    model.open()
    let big = (0..<10).map { item($0 * 10, String(repeating: "x", count: 50)) }
    pager.answer(page(big, start: 0, end: 100, hasMore: false))

    model.reportVisibleWindow(firstID: "80#0", lastID: "90#0")  // window at the bottom
    XCTAssertTrue(model.feed.items.first(where: { $0.id == "0#0" })!.body.isPlaceholder,
                  "an item far from the window spilled")
    XCTAssertFalse(model.feed.items.first(where: { $0.id == "90#0" })!.body.isPlaceholder,
                   "the visible item stays resident")
    XCTAssertFalse(model.feed.items.first(where: { $0.id == "80#0" })!.body.isPlaceholder)
}

@MainActor
func testApproachingASpilledRegionRehydratesFromDisk() {
    let pager = StubPager()
    let model = model(pager)
    model.spillBudgetBytesOverride = 100
    model.spillMarginOverride = 1
    model.open()
    let big = (0..<10).map { item($0 * 10, String(repeating: "x", count: 50)) }
    pager.answer(page(big, start: 0, end: 100, hasMore: false))

    model.reportVisibleWindow(firstID: "80#0", lastID: "90#0")   // spills the top
    XCTAssertTrue(model.feed.items.first(where: { $0.id == "0#0" })!.body.isPlaceholder)

    model.reportVisibleWindow(firstID: "0#0", lastID: "10#0")    // scroll back to the top
    XCTAssertFalse(model.feed.items.first(where: { $0.id == "0#0" })!.body.isPlaceholder,
                   "an approached spilled item rehydrates synchronously from the store")
    XCTAssertEqual(model.feed.items.first(where: { $0.id == "0#0" })!.body.text.count, 50,
                   "the full body is back")
}
```

(Give the `model(_:)` test helper an optional temp `spillDirectory` so these tests never touch the real Caches dir — mirror the injectable-`timeout` pattern at `:264-274`.)

**Step 2 — Run to fail.** `./scripts/test-ios.sh` → `no member 'reportVisibleWindow'` / `'spillBudgetBytesOverride'`.

**Step 3 — Minimal implementation.** In `SessionTimelineModel.swift`, add init parameter and stored state:

```swift
@ObservationIgnored private let spillStore: TimelineSpillStore
@ObservationIgnored private var visibleFirstID: String?
@ObservationIgnored private var visibleLastID: String?

/// The resident-text budget for one session, and the two hysteresis margins that stop a window
/// parked on a spill boundary from thrashing: spill only beyond `spillMargin` items outside the
/// window, rehydrate anything within the tighter `rehydrateMargin` of it. `var` overrides are
/// for tests only, the same device as `promptRetries`.
static let spillBudgetBytes = 2_000_000
static let spillMargin = 200
static let rehydrateMargin = 60
@ObservationIgnored var spillBudgetBytesOverride: Int?
@ObservationIgnored var spillMarginOverride: Int?
```

Extend `init` (`:266-274`) to take `spillDirectory: URL? = nil` and build the store:

```swift
init(
    sessionID: UUID,
    fleet: any TimelinePaging & PromptSending & PromptAnswering & PresenceReporting,
    timeout: Duration = .seconds(15),
    spillDirectory: URL? = nil
) {
    self.sessionID = sessionID
    self.fleet = fleet
    self.timeout = timeout
    self.spillStore = TimelineSpillStore(session: sessionID, directory: spillDirectory)
}
```

Add the reporting entry point and the reconcile:

```swift
/// The visible window moved. Reported by the screen from the rows entering and leaving the
/// viewport; drives spill (far items) and rehydrate (approaching items).
func reportVisibleWindow(firstID: String?, lastID: String?) {
    guard firstID != visibleFirstID || lastID != visibleLastID else { return }
    visibleFirstID = firstID
    visibleLastID = lastID
    reconcileSpill()
}

/// Spill items far from the window when resident text is over budget; rehydrate placeholders
/// the window is approaching. Both are main-actor and keyed by the same window, so they cannot
/// fight — a rehydrated edge item may simply be re-spilled later.
private func reconcileSpill() {
    let items = feed.items
    guard !items.isEmpty else { return }
    let budget = spillBudgetBytesOverride ?? Self.spillBudgetBytes
    let margin = spillMarginOverride ?? Self.spillMargin

    let firstIndex = visibleFirstID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
    let lastIndex = visibleLastID.flatMap { id in items.firstIndex { $0.id == id } } ?? (items.count - 1)

    // Rehydrate first: anything within the tight margin that is a placeholder.
    let rehydrateLower = max(0, firstIndex - Self.rehydrateMargin)
    let rehydrateUpper = min(items.count - 1, lastIndex + Self.rehydrateMargin)
    let toRehydrate = Set(items[rehydrateLower...rehydrateUpper]
        .filter { $0.body.isPlaceholder }.map(\.id))
    if !toRehydrate.isEmpty {
        let restored = spillStore.read(toRehydrate)
        if !restored.isEmpty {
            feed.rehydrate(restored)
            rebuild()
        }
        // Any id the store no longer holds — a purged cache — falls back to a wire re-fetch of
        // its offset range. The merge is idempotent and its full body clears the placeholder.
        let missing = toRehydrate.subtracting(restored.keys)
        if let offset = missing.compactMap({ Self.offset(of: $0) }).min() {
            fetch(anchor: .around(offset), older: false, quiet: true)
        }
    }

    // Spill next, only if over budget: items outside the window plus the wider margin whose
    // bodies are still resident, biggest first, until back under budget.
    var residentBytes = items.reduce(0) { $0 + ($1.body.isPlaceholder ? 0 : $1.body.text.utf8.count) }
    guard residentBytes > budget else { return }
    let spillLower = max(0, firstIndex - margin)
    let spillUpper = min(items.count - 1, lastIndex + margin)
    let candidates = items.indices.filter { index in
        (index < spillLower || index > spillUpper) && !items[index].body.isPlaceholder
    }.sorted { items[$0].body.text.utf8.count > items[$1].body.text.utf8.count }

    var toSpill: Set<String> = []
    for index in candidates {
        guard residentBytes > budget else { break }
        toSpill.insert(items[index].id)
        residentBytes -= items[index].body.text.utf8.count
    }
    if !toSpill.isEmpty {
        let originals = feed.spill(toSpill)
        spillStore.write(originals)
        rebuild()
    }
}

/// The byte offset from an item id (`"<offset>#<index>"`), for the wire fallback's `.around`.
private static func offset(of id: String) -> Int? {
    guard let hash = id.firstIndex(of: "#") else { return nil }
    return Int(id[id.startIndex..<hash])
}
```

In `SessionTimelineScreen.swift`, report the window. Add `@State private var visibleIDs: Set<String> = []` and update it in the existing row `.onAppear`/`.onDisappear` (`:129-136`), then report min/max by feed order. Extend the row modifiers:

```swift
.onAppear {
    visibleIDs.insert(entry.id)
    reportWindow()
    guard entry.id == model.prefetchTriggerID else { return }
    isNearOldest = true
    model.prefetchOlder()
}
.onDisappear {
    visibleIDs.remove(entry.id)
    reportWindow()
    if entry.id == model.prefetchTriggerID { isNearOldest = false }
}
```

Add the helper (near `bottomSentinel`):

```swift
/// The first and last visible entry ids in feed order, handed to the model so it can spill far
/// history and rehydrate what the reader is approaching. Cheap: a set membership scan over the
/// maintained `rendered`, which is already O(on-screen) rows short.
private func reportWindow() {
    let visible = model.rendered.filter { visibleIDs.contains($0.id) }
    model.reportVisibleWindow(firstID: visible.first?.id, lastID: visible.last?.id)
}
```

**Step 4 — Run to pass.** `./scripts/test-ios.sh` green.

**Step 5 — Commit.**
```
git add -A
git commit -m "Drive per-session spill/rehydrate from the visible window

Over a byte budget, spill far history to disk (biggest first); rehydrate what
the window approaches, synchronously from disk with a wire re-fetch fallback if
the cache was purged. Hysteresis margins keep a boundary window from thrashing.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4.5 — Placeholder rows render as skeletons

**Files**
- Modify: `Sources/FlightDeckMobile/SessionTimelineScreen.swift` (`entryRow` at `:445-468` — branch on `entry.item.body.isPlaceholder` before the `TimelineRow` path)
- Create: `Sources/FlightDeckMobile/TimelineSkeletonRow.swift`
- Test: `Tests/FlightDeckMobileTests/TimelineSkeletonRowTests.swift` (new — use the mount-harness pattern from `ProseExpansionRecyclingTests` to assert a placeholder row lays out with a non-zero height, i.e. is not blank)

**Interfaces**
- Produces: `struct TimelineSkeletonRow: View { let item: TimelineItem; var isFetching: Bool = false }` — draws the first-line preview (`item.body.text`, which for a placeholder is the preview) plus, only if a wire fallback is in flight, a subtle "loading full text" line.
- Consumes: `TimelineItem.Body.isPlaceholder`, `TimelineItem.Body.text` (the preview).

**Step 1 — Write the failing test.** Create `Tests/FlightDeckMobileTests/TimelineSkeletonRowTests.swift`:

```swift
import FleetKit
import SwiftUI
import UIKit
import XCTest
@testable import FlightDeckMobile

@MainActor
final class TimelineSkeletonRowTests: XCTestCase {
    func testAPlaceholderRowRendersItsPreviewRatherThanBlank() {
        var body = TimelineItem.Body(text: "the first line of a spilled body")
        body.isPlaceholder = true
        let item = TimelineItem(id: "0#0", kind: .assistantText, status: .complete, body: body)

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 200))
        window.rootViewController = UIHostingController(rootView:
            TimelineSkeletonRow(item: item).frame(width: 402))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        for _ in 0..<8 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        window.layoutIfNeeded()

        let size = window.rootViewController!.view.systemLayoutSizeFitting(
            CGSize(width: 402, height: UIView.layoutFittingCompressedSize.height))
        XCTAssertGreaterThan(size.height, 10, "a skeleton row draws its preview, not nothing")
        window.isHidden = true
    }
}
```

**Step 2 — Run to fail.** `./scripts/test-ios.sh` → `cannot find 'TimelineSkeletonRow'`.

**Step 3 — Minimal implementation.** Create `Sources/FlightDeckMobile/TimelineSkeletonRow.swift`:

```swift
import FleetKit
import SwiftUI

/// A spilled-but-not-yet-rehydrated row, drawn as a skeleton so it is never blank.
///
/// The full body was swapped to disk to keep a single giant session under its memory ceiling
/// (see `TimelineFeed.spill`), leaving the first-line preview resident on `item.body.text`. That
/// preview is what a reader sees for the instant before the row rehydrates from disk on
/// approach — local and fast, so ordinarily there is no loading state at all. The subtle
/// "loading" line appears only when a wire re-fetch is genuinely in flight, the one case a spill
/// record was purged.
struct TimelineSkeletonRow: View {
    let item: TimelineItem
    /// True only when a wire fallback for this row's range is in flight.
    var isFetching: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.body.text)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .redacted(reason: .placeholder)
            if isFetching {
                Label("Loading full text", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.body.text.isEmpty ? "Loading message" : item.body.text)
    }
}
```

In `SessionTimelineScreen.swift`, branch `entryRow` (`:445-448`) on the placeholder before the ghost/`TimelineRow` split:

```swift
@ViewBuilder
private func entryRow(_ entry: TimelineEntry) -> some View {
    if entry.item.body.isPlaceholder {
        TimelineSkeletonRow(item: entry.item)
    } else if entry.isGhost {
        ghostRow(entry)
    } else {
        // ... existing TimelineRow construction unchanged ...
    }
}
```

(Match the existing `entryRow` structure; if it does not already branch on `isGhost`, insert the placeholder branch ahead of whatever it returns today.)

**Step 4 — Run to pass.** `./scripts/test-ios.sh` green.

**Step 5 — Commit.**
```
git add -A
git commit -m "Render spilled rows as skeletons, never blank

A placeholder row draws its resident first-line preview redacted, plus a subtle
loading line only when a wire fallback is actually in flight.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final validation

After Task 4.5:

1. `./scripts/test-unit.sh` — all FleetKit + macOS logic tests green (`TimelineRenderTests`, `TimelineFeedTests` incl. no-op/spill/rehydrate, `TimelinePlaceholderTests`, `TimelineSpillStoreTests`).
2. `./scripts/test-ios.sh` — all mobile tests green (`SessionTimelineModelTests` incl. recompute-count + spill scheduling, `SessionTimelineBlockedTests`, `TimelineSegmentCacheTests`, `TimelineStyleDateTests`, `FleetModelTests` incl. eviction + memory warning, `TimelineSkeletonRowTests`, and the untouched `ProseExpansionRecyclingTests` / `TranscriptGhostTests` / `SessionTimelineScreenTests`).
3. Manual device pass per `docs/MOBILE.md`: confirm lag is gone on a long session (Part 1), a quiet busy poll is near-free (Part 2), opening many sessions does not grow memory unbounded (Part 3), and a pathologically long session scrolls with skeleton rows and rehydrates on approach without a loading flash (Part 4).

---

## Critical files

- `Sources/FlightDeckMobile/SessionTimelineModel.swift`
- `Sources/FlightDeckMobile/SessionTimelineScreen.swift`
- `Sources/FleetKit/TimelineFeed.swift`
- `Sources/FleetKit/Timeline.swift`
- `Sources/FlightDeckMobile/FleetModel.swift`
