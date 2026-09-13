# Mobile long-session performance — design

**Goal: the phone's session timeline stays smooth on a session of any length. Opening, scrolling,
and following a live turn cost work proportional to what is *on screen*, never to how much history
the session holds — and a single enormous session can no longer grow the phone's memory without
bound.**

## The problem

`FlightDeckMobile`'s session screen becomes "abysmally" slow the longer a session runs. The
container is not the cause — the transcript is a lazy `List` with stable row ids
(`SessionTimelineScreen.swift:90,107`, `Entry.id = item.id` at `:584`), so off-screen rows are not
built. The cause is **derived state recomputed with cost O(N) in the held item count, many times
per second, while N grows without bound.**

Three compounding facts:

1. **`entries` is a computed property folded from the whole feed on every access.**
   `SessionTimelineScreen.entries` (`:421-426`) calls `entries(from: model.feed.items, …)`
   (`:651-683`), which walks all items twice (dict build `:654-661`, then `compactMap` `:662-672`)
   and allocates a fresh `[Entry]`. It is read by `ForEach(entries)` (`:107`) — so SwiftUI also
   diffs N `Entry` values whose `Hashable` includes full body text — **and re-entered inside every
   row's `.onAppear`/`.onDisappear`** via `prefetchTriggerID` (`:130`, `:548-550`). The screen
   `body` re-evaluates on every `@Observable` touch and on the **1.5s busy poll** (`:347-354`), so
   the full fold runs on every status change, every poll tick, and every row that scrolls into view.

2. **N never shrinks.** `TimelineFeed.items` only ever grows — the merge widens cursors and evicts
   nothing (`TimelineFeed.swift:96-98`), forward `chase` walks to the live edge uncapped
   (`SessionTimelineModel.swift:988-997`). And `FleetModel.timelineModels` retains every session
   ever opened for the app's lifetime, cleared only by `unpair()` (`FleetModel.swift:44,242,429-434`).

3. **Per-tick amplifiers, all O(N), all paid on the 1.5s busy poll:** `TimelineFeed.merging`
   reallocates the entire items array every merge (`TimelineFeed.swift:92,117-158`); `blocked()` →
   `OpenPrompt.find` builds a set and reverse-scans all items from the `body` while the session is
   `waiting` (`SessionTimelineScreen.swift:295-298`); the per-row segmenter runs ~3× uncached
   (`TimelineRow.swift:257`, via `expandsInPlace` at `:352` and `:101`), splitting the full body
   each time (`TimelineSegments.swift:96-141`); and `TimelineStyle.date` allocates **two**
   `ISO8601DateFormatter`s per row per render (`TimelineStyle.swift:180-187`).

The heavy markdown→`AttributedString` parse *is* cached on the `SelectableProseView` coordinator
(`SelectableProseView.swift:70-93`), which is why the screen lags rather than freezes outright.

The lag is a **CPU** problem: O(N) work × high render frequency, with N climbing. Memory is a
secondary ceiling — the resident `TimelineItem` is already the compact form (raw `body.text`,
COW-shared; the expensive rendered artifacts are per-visible-row and released on recycle), so
holding history is cheap until a session is pathologically large.

## The four parts

The parts are independent and land in order of value. Part 1 alone removes the lag. Parts 2–4 are
the full sweep: de-thrash the live-turn path, bound cross-session growth, and put a hard ceiling on
a single giant session.

---

## Part 1 — Rendered entries as maintained state (the lag fix)

**Move the fold out of the view `body` and off the row lifecycle. Compute it exactly once per
change to its inputs, store the result, and let both the `ForEach` and the prefetch check read the
stored value.**

- Add to `SessionTimelineModel`:
  - `private(set) var rendered: [Entry] = []` — the folded, ghost-appended list the `ForEach` draws.
  - `private(set) var prefetchTriggerID: String?` — the id of the row whose appearance should
    trigger a backward prefetch, computed once alongside `rendered`.
  - `private(set) var blocked: BlockedPrompt?` (see Part 2).
- Recompute `rendered` (and the two derived ids) in exactly one place — a private `rebuild()` —
  called only when an input actually changes: after `feed.merge` in `fetch` completion
  (`SessionTimelineModel.swift:903`), after `outbox.reconcile` (`:908`), and on the status inputs
  that affect folding/blocking. Never from the view.
- The view drops its computed `entries` and `prefetchTrigger`; `ForEach(model.rendered)` and
  `guard entry.id == model.prefetchTriggerID` replace them. Row `.onAppear`/`.onDisappear` then do
  an id comparison, not an O(N) fold.

**Move `Entry` and the fold into `FleetKit`.** The fold's correctness — pairing a `toolResult`
with its `toolCall` across a page boundary, never dropping a result whose call is on an adjacent
page (`SessionTimelineScreen.swift:640-668`) — is exactly the kind of invariant `TimelineFeed`'s
doc comment says belongs where the macOS unit suite can reach it, not behind a booted simulator.
`Entry` and a pure `TimelineRender.entries(from:)` move to `FleetKit`; the ghost-append (which
needs `PromptOutboxEntry`) stays in the model layer as a thin wrapper over the pure fold.

Result: render cost becomes O(on-screen rows); `rendered` is rebuilt once per real change, over
whatever the feed holds — and Part 4 bounds even that.

## Part 2 — De-thrash the live-turn path

Each is O(N)-per-tick today and becomes O(1) or "only when it changed":

- **`blocked` computed on change, not in `body`.** Fold the `OpenPrompt.find` result into
  `rebuild()` and store `blocked` (`SessionTimelineModel`); the view reads the stored value. The
  scan still happens only while `waiting`, but once per change rather than once per render.
- **`TimelineFeed.merge` early-out on a no-op page.** A quiet poll returns a page already fully
  held; `merging` currently still allocates a fresh N-item array. Detect the no-op (every incoming
  id already present with an equal body, and neither cursor widens) and return the existing array
  unchanged, so a quiet 1.5s tick allocates nothing. `TimelineFeed` stays `Equatable` and the
  merge stays idempotent — this only skips a redundant copy. New tests cover the no-op and the
  "same id, longer body" replace case that must *not* be skipped.
- **Per-row segment memo.** Cache `clampedProse(for:expanded:)` output keyed by
  `(item.id, expanded, widthBucket)` so a row's three segmenter passes collapse to one and survive
  re-render. Small bounded cache (visible rows + margin); evicted with the row.
- **Shared date formatter.** Replace the two per-call `ISO8601DateFormatter` allocations
  (`TimelineStyle.swift:180-187`) with two shared `static let` instances.

## Part 3 — Cross-session model eviction

`FleetModel.timelineModels` grows for the app's lifetime. Bound it:

- Track view order; keep the N most-recently-viewed models (a small cap, e.g. 8) plus whichever is
  currently on screen. Evict the rest.
- Also evict all but the on-screen model on `UIApplication.didReceiveMemoryWarningNotification`.
- Eviction just drops the `SessionTimelineModel` (and its `TimelineFeed`); `timelineModel(for:)`
  recreates it on reopen and it re-fetches from `.latest` — the same path a first open takes. The
  reconnect fan-out (`FleetModel.swift:657`) naturally skips evicted models; nothing observes a
  model that is not on screen.

## Part 4 — Per-session disk-spill (hard memory ceiling)

Put a ceiling on a single arbitrarily-long session **without** re-fetching over the wire, using the
insight that only `body.text` costs memory and the item is otherwise tiny.

- **Placeholder swap, not eviction.** When the resident text of `feed.items` exceeds a byte budget,
  take items *far from the visible window* and swap `body.text` for a placeholder marker, keeping
  id, kind, offset, `callID`, status, and a short first-line preview for the row skeleton. The item
  stays in the array at its position; **`TimelineFeed`'s cursors and ordering never change** — the
  clean part this approach buys over eviction+refetch.
- **Spill store.** A per-session cache file (`TimelineSpillStore`) writes the spilled text keyed by
  item id. `TimelineItem.Body` is `Codable`; records are appended/compacted per session. File lives
  under `Caches` — the OS may purge it under pressure, which is fine (see fallback).
- **Rehydrate on approach.** When the visible window moves toward a spilled region, rehydrate those
  items' text synchronously from disk (local, fast — no loading flash). If the cache file was
  purged, fall back to a wire re-fetch of that offset range (the one case a spinner appears); the
  feed's `olderAnchor`/re-merge path already supports this and the merge is idempotent.
- **Placeholder rows render as skeletons** (first-line preview + a subtle "loading full text" only
  if a wire fallback is actually in flight), so a spilled-but-not-yet-rehydrated row is never blank.

## Components

- `FleetKit/TimelineRender.swift` — `Entry` + pure `entries(from:)` fold (moved from the view),
  unit-tested against page-boundary result/call pairing.
- `FleetKit/TimelineFeed.swift` — no-op merge early-out; a `spill(_:)`/`rehydrate(_:)` surface that
  swaps `body.text` ↔ placeholder without touching cursors.
- `FleetKit/TimelineSpillStore.swift` — Codable per-session text cache under `Caches`.
- `FlightDeckMobile/SessionTimelineModel.swift` — stored `rendered`, `prefetchTriggerID`,
  `blocked`; single `rebuild()`; spill/rehydrate scheduling driven by the visible window.
- `FlightDeckMobile/SessionTimelineScreen.swift` — read stored state; report visible range; drop
  computed `entries`.
- `FlightDeckMobile/FleetModel.swift` — LRU + memory-warning eviction of `timelineModels`.
- `FlightDeckMobile/TimelineStyle.swift` / `TimelineRow.swift` — shared formatters; segment memo.

## Error handling & edge cases

- **Spilled item redelivered by a merge.** A page can re-deliver an item whose text is spilled. The
  merge's replace-by-id path (`TimelineFeed.swift:143-148`) must treat an incoming full body as
  authoritative and clear that id's placeholder, so a re-delivery never leaves a stale placeholder.
- **Rehydrate races the spiller.** Spill and rehydrate are both main-actor and keyed by the visible
  window, so they cannot fight; a rehydrated item near the edge simply may be re-spilled later.
- **Cache purge mid-scroll.** Missing spill record → wire fallback for that range; the placeholder
  stays a skeleton until it arrives.
- **Evicted model with an outstanding prompt.** Do not evict a model with unacknowledged outbox
  entries or an open prompt; only truly idle models are eligible.
- **Follow-the-edge unaffected.** `follow()` keys off `feed.items.last?.id`
  (`SessionTimelineScreen.swift:173`), which is never spilled (the tail is always resident), so
  live-edge following is untouched.

## Testing

- `FleetKit` unit tests (macOS suite, no simulator): `entries(from:)` fold across page boundaries;
  `TimelineFeed` no-op merge early-out vs. body-replace; `spill`/`rehydrate` round-trip leaves
  ordering and cursors identical; `TimelineSpillStore` write/read/purge-fallback.
- A recompute-count guard: a fake that counts `rebuild()` calls asserts a busy poll that changes
  nothing triggers zero rebuilds, and one new item triggers exactly one.
- Mobile tests (existing `ProseExpansionRecyclingTests` neighbourhood): segment memo hits on
  re-render; placeholder rows render a skeleton, not blank; formatter identity is shared.
- iOS suite runs via `test-ios.sh`; FleetKit/model tests via `test-unit.sh`.

## Phasing

1. **Part 1** — maintained `rendered` + moved fold + prefetch id. Ship and confirm the lag is gone
   before touching anything else; this is the whole user-visible win.
2. **Part 2** — amplifier cleanup.
3. **Part 3** — cross-session eviction.
4. **Part 4** — disk-spill ceiling.

## Non-goals (for now)

- Token-level streaming — nothing emits `.streaming` (`Timeline.swift:46-53`); not introduced here.
- Reworking the wire protocol or paging cursors — the feed's paging is sound and untouched.
- Changing the 1.5s busy-poll cadence — Part 2 makes a quiet tick nearly free, which is the point.

## Risks

- **`rebuild()` completeness.** The single rebuild must fire on every input that affects the fold or
  blocked state; a missed input shows stale rows. Mitigated by routing all input changes through the
  model's existing mutation points (`fetch` completion, `reconcile`, status setters) and the
  recompute-count test.
- **Spill boundary thrash.** A visible window parked exactly on a spill boundary could spill/rehydrate
  repeatedly. Mitigated by hysteresis — spill only beyond a margin well outside the window, rehydrate
  at the window edge.
- **`Entry`/fold move.** Relocating to `FleetKit` must preserve the ghost-append semantics
  (`"ghost:<token>"` ids never entering `TimelineFeed`, `SessionTimelineScreen.swift:646-650`); the
  pure fold stays free of outbox concepts and the ghost wrapper stays in the model.
