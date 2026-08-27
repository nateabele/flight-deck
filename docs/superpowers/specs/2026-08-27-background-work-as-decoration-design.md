# `shell` is not an activity: background work as a decoration

## 1. The finding

`SessionActivity` models `shell` as a peer of `idle`, `busy` and `waiting`. It is not one.
It is two orthogonal facts flattened into one field, and the flattening happens upstream, in
Claude Code's own status writer:

```js
Lt = ["busy","shell","idle","waiting"];               // the flat enum
mb = rm === "idle" && db ? "shell" : rm;              // rm = real status, db = has background shells
_ze({ status: mb, waitingFor: TM }, j);               // → ~/.claude/sessions/<pid>.json
```

So `shell` is **exactly `idle` ∧ `hasBackgroundTasks`**. Three consequences follow, and each
is a defect we carry today:

1. **The prompt guard refuses the readiest state there is.** `SessionStore.swift:2954` and
   `PromptComposer.swift:78` both refuse `.shell` on the stated grounds that it is "a bare
   prompt where the text would be RUN rather than read". That premise is false: `shell`
   implies the model turn has *finished*. `SessionStatus.swift:6-8` documents this correctly;
   the two guards contradict it. This is the bug that made a phone say "There's no agent
   running in this tab right now" about a live agent.

2. **`summaryRank` ranks it above `busy`.** `SessionStatus.swift:23` gives `shell` rank 2 and
   `busy` rank 1, so once `shell` is understood as *idle*, an idle tab outranks a working one
   on the project-header glyph. Claude Code itself buckets `shell` with `busy` as "working";
   we disagree with it in the opposite direction.

3. **The encoding is lossy in one direction only.** Background work is observable *only while
   idle*. During a turn upstream reports `busy` and the background fact is dropped — not set
   to false, simply unavailable.

## 2. The change

`shell` leaves `SessionActivity`. The background fact becomes a decoration, modelled on the
existing `isPhoneActive` precedent (`FleetService.phoneActiveSessions` → threaded as a
defaulted `Bool` → its own badge with its own transition, documented as "presence, not
state").

```swift
enum SessionActivity: String, Equatable {
    case idle, busy, waiting        // `shell` removed
}
```

- `SessionStore.backgroundWorkSessions: Set<UUID>`, parallel to `statuses`, rebuilt in
  `applyRegistry`. Mirrors `phoneActiveSessions` in shape and in lifetime.
- `SessionRow.hasBackgroundWork: Bool = false`, defaulted so fixtures and tests are untouched.
- A `BackgroundWorkBadge`, sibling to `PhonePresenceBadge`, animated on the container keyed on
  set membership — a badge created by an `if` cannot animate its own arrival.

### 2.1 Observation, not conclusion, at the decode boundary

`ClaudeStatusFile.Entry.activity` is decoded with `SessionActivity(rawValue:)`. Removing the
case would make `"shell"` fail to decode, and that file's contract is "anything unrecognized
yields nil, and the caller keeps its last known status" — so shrinking the enum alone would
silently freeze every backgrounded tab on a stale status. The decode changes deliberately:

```swift
// "shell" is `idle` plus a fact upstream can only report while idle.
case "shell": (activity: .idle, reportsBackgroundWork: true)
default:      (activity: SessionActivity(rawValue: raw), reportsBackgroundWork: false)
```

`Entry` carries `reportsBackgroundWork` — the **observation**. `false` here means "not
reported", never "known absent". Turning observations into durable state is the latch's job,
one layer up, where the history lives.

### 2.2 The latch

Because the fact is unavailable during a turn, the naive rendering blinks the badge off on
every prompt and back on when the turn ends, while the dev server it describes never stopped.
The set is therefore latched, and cleared only on positive proof:

| observed        | action                                        |
|-----------------|-----------------------------------------------|
| `shell`         | insert — background work confirmed             |
| `idle`          | **remove** — idle without `shell` proves it ended |
| `busy`          | leave unchanged — unknowable                   |
| `waiting`       | leave unchanged — unknowable                   |
| no status / gone| remove — the agent is gone, so its children are |

The accepted cost: a background task that dies *during* a turn keeps its badge until the next
idle tick. Bounded by one status poll after the turn ends, and it errs toward showing work
that has finished rather than hiding work that is still running.

### 2.3 The `commitStatuses` guard

`commitStatuses` is the single writer of `statuses` and opens with
`guard next != statuses else { return }`. A tick where only the background set changed — a
task starting or ending under an otherwise-idle tab — leaves `statuses` identical, hits that
early return, and never emits. The guard must compare both, and the emit must carry both.

## 3. Wire

`WireSession` and `FleetEvent.activityChanged` both carry activity; both gain the flag.

```swift
public var hasBackgroundWork: Bool          // WireSession
case activityChanged(id: UUID, activity: String?, waitingFor: String?,
                     subagentCount: Int, hasBackgroundWork: Bool)
```

Decoded with `decodeIfPresent(...) ?? false`, matching how `activity` is already read in
`WireCoding.swift:121`. Synthesized `Codable` does not apply property defaults to missing
keys, so an older Mac's payload would otherwise throw on a newer phone and take the whole
snapshot down. No `FleetKitVersion.wire` bump: absence is a valid, meaningful value, which is
exactly the skew tolerance `agent: String` and `activity: String?` already buy elsewhere.

`FleetReplay.Key.activity(UUID)` is unchanged — the flag coalesces on the same key as the
activity it accompanies. `FleetProjection` stays pure, and `FleetReplicator`'s oracle
comparison keeps working only if the projection and the event fold both learn the field; a
mismatch there fails the replicator's own assertion, which is the intended tripwire.

## 4. Persistence and migration

Two consequences that are easy to miss and both ship broken if missed:

**Auto-resume regresses without a fix.** `resumableActivities: Set<SessionActivity> =
[.busy, .shell]` means "was working when we went away". With `shell` folded into `idle`, a tab
with a live dev server persists as `.idle` and stops being resumed. The snapshot must persist
the flag alongside `activity`, and the predicate becomes `activity == .busy ||
hasBackgroundWork`.

**Existing state files contain `"activity":"shell"` right now.** Reading one back after the
change yields `nil` from `SessionActivity(rawValue:)`. The snapshot decoder maps legacy
`"shell"` → `.idle` + flag set, the same mapping as §2.1. Written state uses the new shape;
the legacy read is permanent, cheap, and the only thing standing between this change and a
fleet that loses its statuses on first launch.

## 5. Consumers

| Site | Today | After |
|---|---|---|
| `SessionStatus.swift:23` `summaryRank` | `.shell` = 2, above `busy` | case gone; ranking is `idle < busy < waiting` |
| `SessionStatus.swift:59` `tooltip` | "Background command running" | composed — see §5.1 |
| `SessionStatusIcon.swift:83` | `terminal.fill` green, *instead of* the dot | case gone — the icon draws the activity only; the badge is a sibling view in `SessionRow` |
| `SessionStore.swift:2293` `resumableActivities` | `[.busy, .shell]` | `activity == .busy \|\| hasBackgroundWork` (§4) |
| `SessionStore.swift:2954` prompt guard | refuses `.shell` | **fix** — idle is sendable; the flag is not consulted |
| `SessionStore.swift:3338-3343` mid-turn typing | whitelist excludes `.shell` | `.idle`/`.busy` whitelist unchanged; `.shell` no longer exists to exclude |
| `SessionStore.swift:3445` `cancelSupersededPrompts` | `case .idle, .shell, nil: continue` | `case .idle, nil: continue` |
| `SessionStatusGlyph.swift:68,118` (phone) | `terminal.fill` case + label | dot plus badge; label composes |
| `PromptComposer.swift:75-78` (phone) | refuses `"shell"` | **fix** — refuses only `nil` |
| `CodexThreadStatus.swift` | never produces `.shell` | unchanged; flag is claude-only, gated by `hasStatusRegistry` |
| `SessionReadPolicy` / `SessionNotificationPolicy` | key off `.idle` / `.waiting` only | unchanged — and this is the point: a background task must not mark a tab read or fire a notification |

### 5.1 Composed tooltips

The badge does not carry its own text. `tooltip` composes, because the two axes are now
independent and VoiceOver must hear both from one label:

| state | string |
|---|---|
| idle, no background work | `Idle` |
| idle, background work | `Idle — background command running` |
| idle, unread, no background work | `Finished — not yet viewed` |
| idle, unread, background work | `Finished — not yet viewed — background command running` |
| busy, background work | `Working — background command running` |
| busy, 2 subagents, background work | `Working — 2 subagents — background command running` |
| waiting, background work | `Waiting for you — permission prompt — background command running` |

Em dash separators throughout, matching the existing `Working — 2 subagents` and
`Waiting for you — <reason>` forms. The background clause is always last, so an existing
string is only ever suffixed — which is what lets the pinned macOS/iOS literals below be
extended rather than rewritten.

The accessibility invariant in `SessionStatusGlyph.label(for:)` — every string equal to what
`SessionStatus.tooltip` produces, pinned from both ends by `SessionStatusGlyphTests` (iOS) and
`SessionStatusTests` (macOS) — extends to the composed form. Both suites fail if either side
drifts, which is how this stays honest.

## 6. Testing

- **Decode**: `"shell"` → `(.idle, reports: true)`; `"idle"` → `(.idle, reports: false)`.
- **Latch**: the §2.2 table, driven as a status sequence, including
  `shell → busy → idle` (clears) and `shell → busy → shell` (never clears).
- **The regression that started this**: a tab reporting `shell` accepts a phone prompt.
  Asserted on both sides — `PhonePromptDispatchTests` for the Mac's `.notRunning`, and
  `PromptComposerTests` for the phone's early refusal — because the two are deliberately
  the same three refusals worded once.
- **Emit**: a tick where only the background flag changes still emits (§2.3). This is the
  test that fails if `commitStatuses`'s guard is left comparing `statuses` alone.
- **Migration**: a snapshot containing `"activity":"shell"` restores as idle + flag, and is
  still resumable.
- **Replicator oracle**: an `activityChanged` fold matches `FleetProjection` on the new field.

## 7. Out of scope

- Observing the process tree directly. `ProcessTree.descendants(of:)` exists and would make
  the axis genuinely independent of what claude reports, but it cannot distinguish a 200ms
  `ls` from a twelve-hour dev server without an age or pgid heuristic. The latch gets the same
  user-visible result from data we already have.
- Codex background work. Codex has no equivalent signal; the flag stays claude-only.
- `FleetKitVersion.wire` remains 1. See §3.
