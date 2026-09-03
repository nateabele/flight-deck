# Spec — an error badge for sessions that died on a Claude API error

**Date:** 2026-09-03
**Status:** design, awaiting review

## The problem

A session that dies on a Claude API error looks *exactly* like a session that finished
its work. `claude` ends the turn, writes an error record, and goes back to `status:
"idle"` in `~/.claude/sessions/<pid>.json`. Flight Deck reads that status file, sees
`idle`, and paints the resting-state dot — `.primary` at α 0.10, deliberately near
invisible, because it is on nearly every row at once.

So the sidebar's quietest glyph is what a 529 death gets. On a fleet of a dozen tabs the
dead one is indistinguishable from the eleven that are simply done, and it stays dead
until someone happens to open it and read the scrollback. The whole value of the fleet
view — glance, see who needs you — fails precisely when a capacity blip takes out half
your sessions at once.

## The signal, verified

Probed against the installed CLI (`~/.local/share/claude/versions/2.1.259`, a
bun-compiled binary; strings extracted and read). This is not inferred from
documentation:

- The transcript writer spreads the whole message entry into the JSONL record
  (`{parentUuid, logicalParentUuid, isSidechain, …, ...fe, gitBranch, slug}` →
  `appendEntry`), so an assistant record carries these fields **verbatim to disk**:
  - **`isApiErrorMessage: true`** — this assistant message wraps an API error.
  - **`apiErrorStatus: 529`** — the HTTP status. Set from the thrown error's `status`.
  - **`error: "overloaded"`** — the error kind.
  - **`apiErrorIsTransient: true`** — set explicitly for capacity-shaped 429s.
- The transient predicate in the CLI is
  `apiErrorIsTransient === true || error === "overloaded" || error === "server_error"`.
  The retryable-kind set is exactly `{"rate_limit", "overloaded", "server_error"}`.
- The rendered text is prefixed by the literal `"API Error"` (`var yc = "API Error"`).

Retries happen *inside* the request loop; the record is written when the request finally
gives up. So one `isApiErrorMessage` record ≈ one dead turn — we do not have to
de-duplicate a retry storm.

**Nothing else carries this.** The status file has no error field (verified: it is
`{pid, sessionId, cwd, startedAt, procStart, version, …, status, updatedAt}`). The
transcript is the only channel, and Flight Deck already tails it.

## Where it lands

`TranscriptWatcher` → `Scan.read` → `ClaudeSession.events(inObject:)` →
`[TranscriptEvent]` → fold in `apply()` → callback → `SessionStore`. Every record is
already JSON-decoded exactly once per poll and handed to this parser. Reading the two
new fields is free.

`backgroundWorkSessions: Set<UUID>` is the worked precedent for the state itself: an
orthogonal per-session flag on the store, `@Published`, persisted in the snapshot,
projected onto the wire beside the activity rather than folded into it, and rendered as
its own mark. This design follows that shape deliberately rather than inventing one.

## Design

### 1. The value — `SessionAPIError`, in FleetKit

```swift
public struct SessionAPIError: Equatable, Sendable, Codable {
    public var status: Int?      // apiErrorStatus, e.g. 529
    public var kind: String?     // error, e.g. "overloaded"
    public var isTransient: Bool // the CLI's own predicate, evaluated at parse time
}
```

**In `Sources/FleetKit/`, not `Sources/FlightDeck/`.** FleetKit is Foundation-only and
compiles for iOS, so the type *and* the label it produces are shared by both platforms.
`SessionStatusGlyph.swift` currently re-pins the Mac's tooltip literals by hand — its own
doc comment explains that a VoiceOver user hearing a different word than the Mac's
tooltip is as bad as a mismatched symbol. Putting this one in FleetKit means the new
state cannot drift that way by construction. Existing tooltips are left alone; this is
about not adding new duplication, not refactoring the old.

One label function beside it, so both platforms call the same code:

```swift
public var label: String   // "Stopped — API error 529 (overloaded)"
                           // "Stopped — API error 529" when kind is absent
                           // "Stopped — API error" when both are absent
```

Every component is optional because the CLI sets them independently: a client error with
no HTTP status still gets `isApiErrorMessage`, and the badge must survive that rather
than render "API error nil".

### 2. Parsing — two new `TranscriptEvent` cases

```swift
case apiError(SessionAPIError)  // this turn died
case progressed                 // the conversation moved past it
```

In `ClaudeSession.events(inObject:)`:

- `type == "assistant"` → the existing `agentStarted` scan **unchanged**, then one extra
  event: `.apiError(…)` when `isApiErrorMessage == true`, otherwise `.progressed`. The
  tool_use scan is deliberately *not* skipped for error records. An error message's content
  is a single text block, so the scan finds nothing — but making that an assumption the
  parser depends on buys nothing and costs a silently dropped `agentStarted` if it ever
  stops being true.
- `type == "user"` → the existing `agentFinished` scan, **plus** `.progressed`.
- `type == "system"` → unchanged. `turn_duration` keeps producing `.turnEnded` and nothing
  else; system records are bookkeeping, not conversational progress, and clearing on one
  would let a turn that died mid-flight clear its own badge.

The kind and status are read **verbatim** into `String?`/`Int?` rather than parsed against
an enum of known values. The CLI's vocabulary is its own and will grow; a badge that
renders an unrecognised kind as text is right, and one that drops it is not.

`.progressed` on any user record — tool results included — is deliberate. A tool result
means the turn is alive and producing, which is exactly the fact that makes a previous
error stale. Ordering makes this safe: the failure sequence is *user prompt → API call
fails → assistant error record*, so the error always arrives last and is never cleared by
the prompt that provoked it.

The parser stays per-record and stateless, which is the property its doc comment already
claims. Last-wins resolution happens in the fold, where the watcher's other cross-record
state already lives.

### 3. Folding — `TranscriptWatcher.apply`

```swift
var outcome: SessionAPIError?? = nil   // nil = no change, .some(nil) = clear, .some(e) = raise
```

Last event in the scan wins, matching how `.title` already resolves. The callback fires
only when the resolved value differs from the watcher's held value, so a session that has
been errored for an hour does not re-emit on every poll — the same discipline
`setUnread`'s doc comment insists on.

New `onAPIError: (SessionAPIError?) -> Void` initialiser parameter, defaulted to a no-op
so existing call sites are untouched (the pattern `onSubagentCount` established).

### 4. State — `SessionStore`

- `@Published private(set) var apiErrors: [UUID: SessionAPIError] = [:]`
- One writer, `setAPIError(_:_:) -> Bool`, mirroring `setUnread` exactly: mutate, emit,
  return whether anything changed. It sits under the "if you add a mutation to `repos`,
  `statuses` or `unreadIdle`, it must `emit`" rule at line 880 and obeys it.
- Persisted as `SessionSnapshot.Entry.apiError: SessionAPIError?`, restored on launch
  beside `unread` and `hasBackgroundWork`. This matters more here than for unread: the
  badge's clearing trigger is a *new transcript record*, and `TailReader` starts a first
  look at an existing file **at its current end**, so without persistence every relaunch
  would silently forget every dead session.

**Clearing is a transcript fact, not a UI one.** Selecting the tab does not clear it —
that was the explicit product decision. The badge means "this needs a nudge" and it stays
until the conversation actually gets one.

### 5. Wire

- `WireSession.apiError: SessionAPIError?` — added to `CodingKeys`, written with
  `encodeIfPresent`, read with `decodeIfPresent`. **No `FleetKitVersion.wire` bump**,
  following the explicit precedent set for `hasBackgroundWork`: the decoder already
  treats an absent key as a meaningful value rather than an error, so an older Mac
  talking to a newer phone degrades to "no badge", which is what it means.
  The hand-written encoder is the hazard here — `planGate`'s comment records that a
  member omitted from `CodingKeys` is *not* a compile error, just a field that silently
  never reaches the wire. A round-trip test is the only thing that catches it.
- `FleetEvent.apiErrorChanged(id: UUID, error: SessionAPIError?)` — a dedicated case
  rather than a sixth parameter on `activityChanged`, because it is not part of the
  status triple: it arrives on the transcript's cadence, not `commitStatuses`', and it
  clears on a different trigger. `unreadChanged` is the precedent, and for the same
  reasons.
- `FleetProjection` carries it, so the projection oracle and the event-fold mirror agree.
  `activityChanged`'s doc comment records what happens otherwise: a field the oracle can
  see that no event can produce is a disagreement by construction the moment the state is
  non-default.

**This is one atomic commit.** A new `FleetEvent` case makes every exhaustive switch over
it a compile error until it is handled — `SnapshotApplication.swift`, `WireCoding.swift`,
`FleetReplay.swift`, plus the mobile fold. The case and all its arms cannot be split
across commits.

### 6. Rendering

**Symbol and tint:** `exclamationmark.triangle.fill`, `.red`. Distinct in both channels,
per the HIG rule `SessionStatusIcon`'s doc comment already enforces. Orange is spoken for
by `waiting` and must not be reused.

**Precedence: the error glyph wins outright**, over the idle dot, over unread, and over
the activity glyph. The justification is the clearing rule: the flag only survives while
no newer record has arrived, so if it is set, the last thing that actually happened in
this conversation *was* an error — whatever the status file currently claims. A status
file reading `busy` against a transcript whose last record is a failure is precisely the
stale-status case this badge exists to expose, so deferring to it would defeat the
feature. The window is small in practice: the first record of a genuine new turn clears
the flag.

**Mac** (`SessionStatusIcon`): a new branch ahead of the `status`/`unread` branches. The
help and accessibility label become `SessionAPIError.label`.

**iOS** (`SessionStatusGlyph`): the same symbol, the same tint, the same label string
from the same FleetKit function — satisfying that file's "every branch must mean the same
thing it means on the Mac" rule by sharing the code rather than by re-pinning literals.

**Project headers** (`SessionSidebar`'s collapsed summary): out of scope. `summaryRank`
ranks `SessionActivity`, and this is not one; a collapsed project whose child died still
shows its child's activity. Noted in FOLLOWUPS rather than half-built.

## Testing

TDD, and each test is confirmed to fail against the unfixed code first.

| Layer | File | What |
|---|---|---|
| Parser | `ClaudeSessionTests` | A 529 record → `.apiError(status: 529, kind: "overloaded", isTransient: true)`. A normal assistant record → `.progressed` and no error. A `tool_result` user record → `.progressed`. A `turn_duration` system record → `.turnEnded` only, no `.progressed`. An error record with neither status nor kind → still raises, label degrades. An unrecognised kind → carried through verbatim. |
| Fold | `TranscriptWatcher` tests | raise → clear across two `drain()`s; no re-emit when unchanged; last-wins within one scan. |
| Store | `SessionStore` tests | `setAPIError` emits once and only on change; snapshot round-trip; restore on launch. |
| Wire | `FleetFrameCodingTests` | `WireSession` with and without `apiError` round-trips; a payload with the key absent decodes to nil, not a throw. |
| Fold parity | `FleetEventApplicationTests`, `FleetReplayFoldTests` | Oracle equals replayed mirror with an error raised — the check `planGate` needed. |
| iOS | `FlightDeckMobileTests` | The glyph's label for an errored `WireSession` equals `SessionAPIError.label`, string for string. |

**On the fixtures.** No transcript on this machine contains an `isApiErrorMessage` record
— every `~/.claude/projects/**/*.jsonl` was searched and none has one, which is why the
field names come from the CLI binary rather than from a sample. The fixtures are therefore
*constructed* from the verified field names, and that is a real limitation worth stating:
they prove the parser handles the shape we read out of the CLI, not that the shape is what
lands on disk. The cheap confirmation is to keep one real record the first time a session
here does die on a 529, and pin it as a fixture then.

`./scripts/test-unit.sh` for the macOS side (runs the full suite, ~8 min — `-only-testing:`
is silently ignored). `./scripts/test-ios.sh` is **required**, not optional: this touches
`Sources/FleetKit` and `Sources/FlightDeckMobile`.

## Non-goals

- **No backfill.** `TailReader` starts a first look at an existing transcript at its
  current end, so a session that died while Flight Deck was not running gets no badge on
  launch — only what the snapshot restored. Scanning backwards for a trailing error record
  is real complexity (find the last assistant record, prove nothing followed it) and is a
  follow-up, not part of this.
- **Claude only.** The wire field is agent-agnostic, but only the claude transcript parser
  raises it. Codex's failure shape is a separate probe — and per the standing note that
  adapter behaviour claims expire, one that must be re-run rather than assumed.
- **No notification.** Explicitly deferred. `SessionNotificationPolicy` already has
  suppression rules around idle/waiting edges, and adding an error edge means designing
  its own suppression (a capacity blip takes out many sessions at once, which is a
  notification storm). Separable, and better done once the badge has proven it fires on
  the right things.
- **No project-header rollup.** See Rendering.

## Docs to update in the same branch

`docs/FOLLOWUPS.md` — the three non-goals above.
`docs/MOBILE.md` — the new glyph, in the checklist that covers what the phone renders.
