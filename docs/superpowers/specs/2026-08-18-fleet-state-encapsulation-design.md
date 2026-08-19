# Fleet State Encapsulation — Design (deferred follow-up)

**Status:** designed, **not scheduled**. Deliberately deferred so the mobile companion work
does not rewrite `SessionStore.swift` while the agent-adapter tasks are still landing in it.
Nothing here is implemented.

**Why it exists:** the mobile companion replicates the fleet to a phone by shipping an event
log northbound (`docs/superpowers/specs/2026-08-18-mobile-companion-design.md` §3). An event
log has exactly one failure mode, and this document is how that failure mode is removed rather
than merely tested for.

## 1. The failure this prevents

A mutation site that changes fleet state without appending the corresponding event leaves every
connected client silently, permanently wrong — until the next reconnect re-snapshots. Nothing
crashes, no test fails unless it specifically exercises that mutation with a client attached,
and the symptom on the phone (a stale title, a session that never disappears) looks like a
network bug rather than a missing line in the store.

That is the classic event-log drift, and it is a *when*, not an *if*: the whole point of the
adapter work is that new agents add new mutation paths.

## 2. Why the state is nearly encapsulated already

The three fields that constitute fleet state are already closed to the outside world:

```swift
@Published private(set) var repos: [Repo] = []
@Published private(set) var statuses: [UUID: SessionStatus] = [:]
@Published private(set) var unreadIdle: Set<UUID> = []
```

So no caller outside `SessionStore` can write them. Every write is internal, and the reads
dominate: 72 lines in `SessionStore.swift` reference these three fields, of which only a
minority are writes — `repos.append` (×3), `repos.remove` (×1), `repos[i].isCollapsed =` (×3),
`statuses[id] =` (×1), `unreadIdle.insert/remove/formUnion` (×8), plus nested subscript-path
writes of the form `repos[a].sessions[b].<field> = …` that a flat pattern does not catch.

**That asymmetry is the whole reason this refactor is affordable.** Move the storage, leave
every read alone.

## 3. The API

`FleetState` is a pure value type that owns the storage privately, and whose every mutating
method records what it did. It has no reference to SwiftUI, no reference to a surface, and no
side effects, so it is testable on its own.

```swift
struct FleetState: Equatable {
    private var repos: [Repo]
    private var statuses: [UUID: SessionStatus]
    private var unreadIdle: Set<UUID>

    /// Recorded by every mutator, drained by the replicator once per tick.
    /// Never read by the store's own logic — this is an output, not state.
    private(set) var pending: [FleetEvent]

    // Reads: plain computed passthroughs, so existing call sites are untouched.
    var allRepos: [Repo] { repos }

    // Writes: the only path to the storage.
    mutating func rename(_ id: UUID, to title: String, origin: RenameOrigin) {
        guard let at = locate(id) else { return }
        repos[at.repo].sessions[at.session].title = title
        pending.append(.renamed(id: id, title: title, origin: origin))
    }
}
```

`SessionStore` keeps its published surface by forwarding:

```swift
@Published private(set) var fleet: FleetState
var repos: [Repo] { fleet.allRepos }
```

`objectWillChange` still fires on any `fleet` assignment, so SwiftUI observation is unchanged
and the sidebar needs no edit.

### Why mutators-that-record, and not a pure reducer

The more principled end state is full event sourcing: a pure `reduce(FleetState, FleetEvent) ->
FleetState`, with the store's methods reduced to emitting events. It was considered and rejected
**for now**, on risk rather than taste.

A reducer forces every current method to be split into a pure state change plus its side
effects, and the ordering between those two halves is currently implicit and load-bearing —
`createSession` interleaves minting identity, preparing an adapter (which can fail and must
then create no tab at all), spawning a surface, and recording the session. Getting that
sequence wrong reintroduces exactly the half-bound-tab class of bug the codex work spent
commits eliminating.

Recording mutators give the identical guarantee — the storage is unreachable, so a write
without a record cannot be written — while keeping each method's logic where it is. They can
also land one mutator at a time with the suite green after each, which a reducer cannot. If the
pure reducer is wanted later, this is the step that makes it safe.

## 4. What this makes unnecessary

The mobile design's fallback safety net:

```swift
// after each tick, in tests and #if DEBUG
assert(apply(emittedEvents, to: projectionBefore) == project(store))
```

Under encapsulation that property holds by construction rather than by assertion, and
`project(_:)` shrinks to what it is actually for — producing the connect-time snapshot.

Until this lands, **the mobile work ships that assertion**, and it is the only thing standing
between a new mutation site and a silently stale phone. Do not remove it before this does.

## 5. Sequencing hazard (the reason this is deferred)

This rewrites every write site in `SessionStore.swift` — the file the agent-adapter workstream
is most actively changing. At the time of writing, codex session creation into the store, codex
auto-resume, and the agent preferences UI are all outstanding, and each adds mutation sites.
Landing this first would force a painful mid-flight rebase on that work; landing it
concurrently in a shared checkout would collide directly.

**Do this after the adapter tasks land**, so a single pass covers the codex mutation sites too
rather than missing them and needing a second sweep.

## 6. Testing

- `FleetState` gets its own unit tests: mutate, assert both the resulting state and the exact
  `pending` events. No store, no SwiftUI, no processes.
- The existing `SessionStore` suite is the regression net for the move itself and must stay
  green after every individual mutator is migrated. It is the only evidence that forwarding the
  reads changed nothing.
- One test asserts the invariant directly — that every mutator appends at least one event —
  by exercising each and checking `pending` is non-empty. Cheap, and it is what catches a
  mutator added later that forgets.
