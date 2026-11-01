# Account usage in Settings → Accounts — design

2026-10-25 · status: approved

## Intent

The maintainer wants to see, on every account in Settings → Accounts, how much of each rate-limit window
the account has used and when each window resets — including accounts that nothing has run on
recently. Today those numbers exist (`UsageService`'s ledger, drawn per pool in Settings →
Flight Control → Capacity), but the Accounts pane shows none of them, and an idle account's
reading is treated as unknown once it is 30 minutes old.

## Decided (the maintainer's words, then what they mean)

1. **"If the account hasn't been active, use the last known value up until the reset, then drop
   it to zero."** Each window of an account's latest reading keeps its last utilization until its
   own `resetsAt`, then reads 0 %. A newer reading replaces it as soon as one arrives. Age alone
   never discards a window.
2. **"Both should be standardized on the new behavior."** Routing (`HeadroomPolicy.evaluate`,
   which `LeasePolicy` and the meters both read) adopts the same rule. The display and the lease
   decision must never disagree about an account.
3. **"Fit all stats within the existing account row without changing its dimensions."** The row
   keeps its current height and the pane its current width. No second line, no expanding row.

## Goals

- Every hosted account row shows, for its windows: utilization, and when the window resets.
- An idle account shows numbers projected by rule 1, not "unknown".
- Routing leases by the same projected numbers.
- The number never pretends to be live: the reading's age and source are one hover away.

## Non-goals

- Polling idle accounts for fresh numbers (no new network or CLI calls).
- Changing the Capacity pane's layout (it gets rule 1 for free through `HeadroomPolicy`).
- Editing soft/hard thresholds from the row.

## Anti-goals (failure even if it works)

- The row grows, wraps, or pushes the name/identity caption into heavy truncation at the
  default Settings width.
- The Accounts pane and Flight Control disagree about the same account.
- A held-over number reads as live with no way to tell it is days old.

## Behaviour change: `HeadroomPolicy.evaluate` (Sources/IntakeKit/FlightControl/PoolState.swift)

Current rules (lines 116–135): a reading older than `freshness` (30 min) keeps only windows whose
reset is ahead; if the result is under soft it returns `.unknown`; a stale reading with nothing
left also returns `.unknown`.

New rule, for every reading, fresh or stale:

- A window whose `resetsAt` is ahead of now → its last `utilization`.
- A window whose `resetsAt` has passed (and is after `readAt`, per the existing clock-skew rule in
  `effectiveUtilization`) → 0.
- A window whose `resetsAt` is at or before `readAt` (the existing clock-skew case, and the
  status-line replay `CapacityLedger.merged` describes: old rate limits stamped with a new
  `readAt`): while the reading is fresh, keep its number (today's skew rule,
  `testResetAtOrBeforeReadAtIsClockSkewNotAReset` stays); once stale, it reads 0 — its reset is
  in the past, so rule 1 applies. Without this a replayed 97 % would hold an account over hard
  forever. *(My call: rule 1 taken literally once the skew window is over.)*
- A window with no `resetsAt`: kept while the reading is fresh; dropped once stale (there is no
  reset to project to). *(My call: nothing to project means nothing to claim.)*
- State is computed from the worst remaining window as today. `.unknown` remains only for: no
  reading, a reading with no usable windows, and an expired rejection with no reading.
- The `if !fresh, state == .underSoft { return unknown }` guard is removed.
- `resetsAt` on the result: the worst window's reset if it is still ahead; for a window that
  has reset to 0, nil.

Consequence, accepted by decision 2: an idle account whose windows have all reset reads 0 %
under soft and is leased in pool order like any account with headroom, ahead of `.unknown`
members. Usage made outside Flight Deck (claude.ai, another machine) during that time is not
seen until the next reading — the same blind spot a fresh reading already has.

`isFresh`/`freshness` stay: they still decide whether a no-reset window counts, and the UI uses
age for its caption. Rejections are untouched (an active rejection still wins).

Tests in `Tests/FlightDeckTests/FlightControlL3/Usage/HeadroomPolicyTests.swift` that pin the old
rule change meaning and must be rewritten to the new one, not deleted:
`testAReadingOlderThanThirtyMinutesIsUnknown`, `testAStaleReadingUnderSoftStaysUnknown`, and the
"reset: nothing known now" assertion in `testAStaleReadingOverALimitStaysOverUntilItsWindowResets`
(it now reads `.underSoft` at 0). Each keeps its incident comment, amended to say what changed.

Check every other consumer of `.unknown` from a stale reading — `MeterFormatter.account`'s
"reading is stale" detail, `rowMeter`, `LeasePolicy`, `UsageService` notices — and make each
match the new rule. `CapacityLedger.ingest`'s rejection-lifting rule (`CapacityLedger.swift:50`)
is **not** changed: rejections are out of scope.

## The row

Current row (`AccountsSettingsTab.accountRow`, `Sources/FlightDeck/Preferences/UI/AccountsSettingsTab.swift:338`):
`[icon] [name / identity caption] <spacer> [Default capsule] [⋯ menu]` — two text lines tall.

New: a usage cluster between the spacer and the Default capsule, exactly two caption-size lines
so it matches the name/caption stack's height. One line per window:

```
[👤] Work                      5h  ▰▰▰▱▱  62%  3:40 PM   [Default] [⋯]
     dana@personal.example · Max      wk  ▰▱▱▱▱  18%  Thu 9 AM
```

- Each line: short window label, a mini track (existing `MeterTrack`, soft/hard ticks from the
  account's pool, colours by `HeadroomState`), percent (monospaced digits), reset time
  (`MeterFormatter.resetText` minus the "resets " word — the column makes it obvious; "h:mm a"
  under a day, "EEE h a" beyond).
- A window that has already reset under rule 1 shows `0%` and, in place of the time, `reset`.
- Fixed column widths so rows align vertically across the list; the cluster has a fixed total
  width and the name stack keeps the flexible space (its caption already truncates middle).
- **Which two windows**: the account's two longest-lived distinct windows by kind — for Claude
  `five_hour` and `seven_day`; for codex its primary and secondary. When a reading has more than
  two (e.g. Claude's per-model weekly, Gemini's per-model quotas), show the five-hour-class one
  and the worst of the rest; the others go in the tooltip. One window → one line, vertically
  centred. *(Builder's call recorded; adjust the mapping table in one place.)*
- Labels: a small table, `five_hour → 5h`, `seven_day → wk`, `seven_day_opus → Opus wk`,
  codex primary/secondary by their window length; unknown names fall back to a duration derived
  from the window if available, else the first 6 characters.
- No reading at all: one dim `No usage yet` line, centred. Active rejection: the track full red
  and `Refused` in place of the percent, reset column shows the rejection's expiry.
- A stale reading whose windows all lack a reset time (Grok without `period.end`, Gemini buckets
  without `reset_time`, codex windows without `resetsAt`): one dim `No current reading` line;
  the tooltip lists the held numbers and their age. The formatter applies exactly
  `evaluate`'s window filter, so what the row draws as a number is what routing counts.
  *(My call.)*
- Thresholds come from the account's effective pool — an unpooled account's is
  `<agent>-default` (`AccountList.effectivePools`, `AccountList.swift:178`), which may carry
  edited thresholds; `CapacityPool.defaultSoft/HardThreshold` only when the ledger has no pool
  for the account. When an account sits in several pools, use the strictest (lowest soft and
  hard), matching `rowMeter`'s "earliest threshold anyone set". *(My call.)*
- Tooltip (`.help`) on the cluster: every window, full reset date, the reading's source and age
  ("claude status line · 2 d ago"), and "held from last reading" when the reading is stale.
- Accessibility: the cluster is one element whose value is the same sentence the tooltip
  carries (reuse `AccountMeterModel.accessibilityValue` style), identifier
  `account-usage-<displayName>`.

## Data path

- `AccountsSettingsTab` observes `UsageService.shared` (it already ticks every 30 s and bumps
  `revision`, so a reset crossing re-renders within 30 s).
- A new pure formatter in `MeterViews.swift` — e.g. `MeterFormatter.accountWindows(account:ledger:now:)`
  returning a small `AccountUsageRowModel` (lines, tooltip, accessibility text) — so
  `MeterFormatterTests` pins every word without SwiftUI, like the existing formatters.
- Per-window projection uses `HeadroomPolicy.effectiveUtilization` so display and routing share
  one function; the stale rules above live inside it (it already gets `readAt` and `now`).

## Constraints

- Row height and pane width unchanged (decision 3). Verify at the default Settings window size
  with the longest real account name in the user's list.
- No new usage sources or polling.
- Unit tests for `HeadroomPolicy` and the new formatter; a UI assertion reading
  `account-usage-*` is welcome but the Settings UI tests run only on the UI-test Mac.

## Left to the builder

- Exact column widths and the mini track's width (fit the anti-goal; ~150 pt total is the
  starting guess).
- Whether the cluster hides while the row is in rename mode.
- Colour treatment of a held (stale) number beyond the tooltip — keep it subtle if any.
