# The phone's New Session menu, mirroring the desktop's — design

**Status:** specified. **Built once on 2026-08-24 and backed out**, because the working
implementation broke two invariants the test suite defends. This spec exists so the second
attempt does not rediscover them.

## The ask

The `+` on a project header opens a menu reading "NEW SESSION" with a single option. It should
**mirror the New Session menu at the bottom of the desktop sidebar** — one row per agent, with
account submenus where an agent has more than one, and a tick on the account a plain tap uses.

## What the desktop menu actually is

`SessionSidebar.newSessionMenuEntries` builds from `NewSessionAffordance.menu(agents:preferences:resolved:)`.
That function encodes rules with edges:

- an agent with **no live account is omitted entirely**;
- **order decides the keyboard chord** (⌘N, ⌘⇧N, ⌘⌥⇧N — `NewSessionAffordance.ladder`);
- an agent with one account is a **flat row**, several is a **submenu**;
- the tick marks `isResolved` **only inside a submenu** — on an agent's only account it would
  mark a choice that was never offered.

**The phone must not restate these.** A second implementation drifts the first time any of them
moves. The menu the phone draws has to come from that same function's output.

## Why the obvious implementation is wrong

The backed-out version put the rows in the fleet snapshot as `WireProject.newSessionOptions`,
built from `NewSessionAffordance.menu`. Both platforms compiled; three Mac tests failed, and
both failures are correct.

### Invariant 1 — an account id may not travel

`FleetAccountEmissionTests.testAnAccountsHomeNeverReachesTheWire` asserts the encoded snapshot
contains neither an account's home path **nor the id that resolves to one**. The backed-out
rows were identified by account UUID and sent it back on tap.

So menu rows need an **opaque identity**: the agent (already public — `WireSession.agent` is a
plain `String`) plus the row's **index among that agent's accounts**. The Mac re-resolves the
menu for that project and picks by index.

A stale index is possible if accounts change between fetch and tap. The Mac must **validate the
agent matches** and fall back to the project's default rather than opening a session as an
account the user did not choose.

### Invariant 2 — the snapshot must be reproducible from events

`FleetReplicator` folds emitted events into a mirror and fails the test suite when the mirror
diverges from `FleetProjection.snapshot(of:)`. Menu options derive from **preferences**, which
emit no fleet events — so signing in changed the snapshot with nothing recorded, and two
`FleetAccountEmissionTests` cases failed with "a mutation changed the fleet without recording
its event".

There is **no preferences-changed hook on the store** to emit from; this was checked.

## The design: a request, not replicated state

The menu is not fleet state. It is a question with an answer, like a transcript page.

- **New request** `FleetRequest.newSessionOptions(project: UUID)`, answered like
  `timeline.page` — correlated by `cid`, replied through `reply`.
- The answer carries `[WireNewSessionOption]`, each row: `agent`, `agentName`, `index`,
  `accountName?` (nil ⇒ flat row), `isDefault`.
- **Nothing enters `FleetSnapshot`**, so no event, no drift, and presence of a menu never
  changes what a reconnect replays. (This is the same reasoning that kept the presence badge
  out of the snapshot; see `FleetEvent.viewing`.)
- `FleetCommand.newSession` gains `agent: String?` and `accountIndex: Int?`. Both nil means
  "the project's default", which is today's behaviour and stays the plain-tap path.

### Fetching

A SwiftUI `Menu` builds its content when opened, so the rows must already be in hand.

**One request per project**, mirroring `timeline.page`: the reply path already correlates by
`cid`, and N small independent fetches mean one slow project cannot hold up the rest of the
list. Cache on `FleetModel`.

**Fetch on appear, on reconnect, and on returning to the foreground.** The third is not
belt-and-braces — it is the only one that covers the realistic staleness case. Options derive
from preferences, preferences emit no fleet events, and there is no hook to push from, so the
phone cannot be told that an account was signed in. What it can do is ask again at the moment
the reader picks the phone up, which is when a change made on the Mac would have happened.

### Absent is not empty

The cache must distinguish **no answer yet** from **an answer with no rows**, because they mean
opposite things and the same fallback would be wrong for one of them.

- **No answer yet** — the request is in flight, or the Mac predates this feature and will never
  send one. Fall back to the single default row. This is a supported state, not a placeholder.
- **An answer with zero rows** — every agent was omitted for having no live account. There is
  nothing to launch, so the `+` is **disabled**. Offering the default row here would be offering
  a tap whose only possible outcome is a failure reported from the other end of the wire.

## Acceptance

- [ ] The `+` menu lists one row per agent the project offers, in the Mac's order.
- [ ] An agent with several accounts is a submenu of account names; one account is a flat
      "New <Agent> Session".
- [ ] The tick marks the default account, and appears only inside a submenu.
- [ ] Tapping `+` without opening the menu still creates with the project's defaults.
- [ ] An agent with no live account does not appear.
- [ ] A project whose answer has zero rows disables the `+`; one whose answer has not arrived
      still offers the default row.
- [ ] **No account id, and no account home path, appears anywhere in an encoded frame** —
      extend `testAnAccountsHomeNeverReachesTheWire` to cover the new request's answer.
- [ ] The replicator drift assertion stays green (nothing new in the snapshot).
- [ ] A stale index whose agent no longer matches falls back to the default rather than opening
      the wrong account.

## Risks

- **The order is the ⌘N ladder.** Sorting on the phone would silently disagree with the
  sidebar. Preserve arrival order; a test should assert it rather than trusting it.
- **Index stability.** The index is only meaningful against the account list the Mac resolves
  at that instant. The agent check is the guard; without it this is a silent wrong-account bug,
  which is worse than a refusal.
- **Fallback is a real state, not an edge case** — an older Mac never sends options at all.

## Sequencing

1. `WireNewSessionOption` + the request and its answer. No UI.
2. Mac answers it from `NewSessionAffordance.menu`, with the opaque index. Test the privacy
   assertion here, before anything renders.
3. `FleetCommand.newSession` gains `agent`/`accountIndex`; Mac resolves and validates.
4. Phone fetches and caches per project — on appear, reconnect and foreground — with absent
   and empty held as distinct states; menu renders from the cache with the flat/submenu rule.
