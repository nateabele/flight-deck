# Account Usage in Settings → Accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every account row in Settings → Accounts shows each rate-limit window's usage and reset time. An idle account holds its last value until the window resets, then reads 0. Routing uses the same rule.

**Architecture:**
1. `HeadroomPolicy` (IntakeKit) changes so that a stale reading is projected instead of turning into `.unknown`.
2. A pure formatter, `MeterFormatter.accountUsage`, turns the ledger into a two-line row model.
3. A small SwiftUI cluster draws that model inside the existing account row.

**Tech Stack:** Swift 6, SwiftUI (macOS), XCTest, xcodegen project.

**Spec:** `docs/superpowers/specs/2026-10-25-account-usage-in-accounts-pane-design.md`

## Global Constraints

- **Row size:** the account row's height and the Settings pane's width do not change. The usage cluster is two caption-size lines at most, and its total width is fixed (start at about 150 pt).
- **No new sources:** no new usage sources, polling, network calls or CLI calls.
- **One shared rule:** display and routing use one projection function, `HeadroomPolicy.effectiveUtilization`.
- **Rejections untouched:** an active rejection still wins. `CapacityLedger.ingest`'s rejection-lifting rule (`CapacityLedger.swift:50`) is not changed.
- **Fixed copy:**
  - `No usage yet`
  - `No current reading`
  - `Refused`
  - `reset`
  - `held from last reading`
- **Window labels:** `five_hour` → `5h`, `seven_day` → `wk`, `seven_day_opus` → `Opus wk`, `seven_day_sonnet` → `Sonnet wk`.
- **How to run tests:** unit tests run with `FD_TEST_FILTER=<Class>[,<Class>] ./scripts/test-unit.sh`. That runs on the UI-test Mac and needs no `FD_TEST_LOCAL`. The full suite is `./scripts/test-unit.sh`.
- **Comments:** match the surrounding code. Doc comments explain *why* and name the incident or decision, as `PoolState.swift` and `MeterViews.swift` already do.

## Review Focus

1. **A replayed status line.** The reset is before `readAt`, utilization is 0.97, and the reading is days old. The account should read 0 % and under soft, not over hard forever. (Task 1 test `testAStaleReplayedWindowPastItsResetReadsZero`.)
2. **A reading that mixes windows with and without a reset time, once stale.** Only the windows that have a reset should count, and only they should be drawn. The no-reset ones appear in the tooltip only. (Task 2 test `testStaleNoResetWindowsGoToTheTooltipOnly`.)
3. **An account in two pools with different thresholds.** The row's colours use the strictest soft and hard values, so they never show "room" while routing in a strict pool says "over". (Task 2 test `testStrictestPoolThresholdsColourTheRow`.)
4. **A reading with three or more windows** (Claude's per-model weekly). The row shows exactly two lines, five-hour first, and the rest appear in the tooltip. (Task 2 test `testThreeWindowsShowFiveHourAndWorstOfTheRest`.)
5. **A long account name at the default Settings width.** The row keeps its height and the cluster stays fully visible. (Task 3 UI activity: row-height and screenshot check.)

---

### Task 1: Project stale readings in `HeadroomPolicy`

**Files:**
- Modify: `Sources/IntakeKit/FlightControl/PoolState.swift:99-135` (`HeadroomPolicy`)
- Modify: `Sources/FlightDeck/FlightControl/Usage/MeterViews.swift` (`MeterFormatter.account`, its `detail` wording only)
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/HeadroomPolicyTests.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/MeterFormatterTests.swift` (only those assertions whose stale `.unknown` changes)

**Interfaces:**
- Produces:
  - `HeadroomPolicy.effectiveUtilization(of: UsageWindow, readAt: Date, now: Date) -> Double?`. The return type changes from `Double` to `Double?`; nil means the window is dropped (no reset, and the reading is stale).
  - `HeadroomPolicy.evaluate(...)` keeps its signature but gets the new semantics.
  - `HeadroomPolicy.isFresh`/`freshness` are unchanged.
- Consumes: nothing new.

**Projection rules**, from the spec. `fresh = isFresh(readAt, now)`.

| Window | Result |
|---|---|
| `resetsAt == nil` | `fresh ? utilization : nil` |
| `resetsAt > now` | `utilization` |
| `resetsAt <= now`, `resetsAt > readAt` | `0` |
| `resetsAt <= readAt` (skew or replay) | `fresh ? utilization : 0` |

**`evaluate` uses every window whose projection is non-nil, whether the reading is fresh or stale:**
- The `if !fresh, state == .underSoft { return unknown }` guard and the stale `resetsAt > now` filter are removed.
- With no usable windows, the result is `.unknown`.
- The result's `resetsAt` is the worst window's `resetsAt` if it is later than `now`, otherwise nil.

**Callers of `effectiveUtilization` to update for `Double?`:**
- `CapacityLedger.swift:52`: use `?? 0` there. Reasoning: a window dropped for staleness is no evidence the account is over.
- `MeterFormatter.account`'s rejection branch.

- [ ] **Step 1: Rewrite the three old-rule tests and add the new ones**

In `HeadroomPolicyTests`:
- Rename `testAReadingOlderThanThirtyMinutesIsUnknown` to `testAStaleReadingWithoutAResetTimeIsUnknown`. Its fixture has no `resetsAt`, so its assertion stays `.unknown` after 30 min + 1 s. Update the comment.
- Rename `testAStaleReadingUnderSoftStaysUnknown` to `testAStaleReadingUnderSoftHoldsUntilItsReset`. Assert `.underSoft` with `worstUtilization == 0.30` at 2026-10-15T21:00Z. Keep the comment, and amend it: decision 2026-10-25 (the maintainer) is to hold the last value until reset.
- In `testAStaleReadingOverALimitStaysOverUntilItsWindowResets`, change the last assertion to `.underSoft` with `worstUtilization == 0`. The message becomes `"reset: reads zero"`.
- Add these tests:

```swift
func testAStaleReplayedWindowPastItsResetReadsZero() {
    // status line replays old limits with a new readAt (CapacityLedger.merged)
    let readAt = usageISO("2026-10-04T23:00:30Z")
    let r = UsageRefs.reading(UsageRefs.work, 0.97, at: readAt, resetsAt: usageISO("2026-10-04T23:00:00Z"))
    let h = evaluate(r, at: readAt.addingTimeInterval(30 * 60 + 1))
    XCTAssertEqual(h.state, .underSoft)
    XCTAssertEqual(h.worstUtilization, 0)
    XCTAssertNil(h.resetsAt)
}

func testAStaleReadingKeepsOnlyWindowsWithAResetTime() {
    let at = usageISO("2026-10-13T12:00:00Z")
    let r = UsageReading(account: UsageRefs.work, windows: [
        UsageWindow(name: "five_hour", utilization: 0.4, resetsAt: usageISO("2026-10-13T15:00:00Z")),
        UsageWindow(name: "credits", utilization: 0.99, resetsAt: nil)],
        readAt: at, source: "test", hardRejection: false)
    XCTAssertEqual(evaluate(r, at: at.addingTimeInterval(60)).state, .overHard, "fresh: the no-reset window counts")
    let stale = evaluate(r, at: usageISO("2026-10-13T14:00:00Z"))
    XCTAssertEqual(stale.state, .underSoft)
    XCTAssertEqual(stale.worstUtilization, 0.4)
}
```

- `testResetAtOrBeforeReadAtIsClockSkewNotAReset` stays as is. It is a fresh case, and its `effectiveUtilization` assertion compares against `Optional(0.97)`.

- [ ] **Step 2: Run, expect failures**

Run: `FD_TEST_FILTER=HeadroomPolicyTests ./scripts/test-unit.sh`

Expected: the build fails, or the renamed and new tests fail with `.unknown` vs `.underSoft`.

- [ ] **Step 3: Implement the projection table and the new `evaluate` in `PoolState.swift`**

- Update the doc comments on both functions: replace the "stale LOW number is no evidence of headroom" rationale with the 2026-10-25 decision.
- Fix `CapacityLedger.swift:52` and `MeterFormatter.account` for `Double?`.
- In `MeterFormatter.account`, the `.unknown` detail becomes:
  - `"no reading"` when `reading == nil`;
  - otherwise `"No current reading"`.
  The old `"reading is stale"` wording is removed.

- [ ] **Step 4: Run, expect pass, then run the neighbours**

Run: `FD_TEST_FILTER=HeadroomPolicyTests,CapacityLedgerTests,MeterFormatterTests,MeterAccessibilityTests,UsageServiceTests,UsageLiveTests ./scripts/test-unit.sh`

Expected: all pass. Any assertion that pinned `"reading is stale"`, or a stale `.unknown` that is now projected, is updated to the new rule in this step, with its comment amended. Do not delete such tests.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-10-25-account-usage-in-accounts-pane-design.md docs/superpowers/plans/2026-10-25-account-usage-in-accounts-pane.md Sources/IntakeKit/FlightControl/PoolState.swift Sources/IntakeKit/FlightControl/CapacityLedger.swift Sources/FlightDeck/FlightControl/Usage/MeterViews.swift Tests/FlightDeckTests/FlightControlL3/Usage/
git commit -m "feat: a stale usage reading holds until its window resets, then reads zero"
```

---

### Task 2: `MeterFormatter.accountUsage` row model

**Files:**
- Modify: `Sources/FlightDeck/FlightControl/Usage/MeterViews.swift` (new types, plus extensions on `MeterFormatter`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/AccountUsageFormatterTests.swift` (new; picked up by the `Tests/FlightDeckTests` source glob in `project.yml`)

**Interfaces:**
- Consumes: Task 1's `HeadroomPolicy.effectiveUtilization -> Double?` and `HeadroomPolicy.isFresh`.
- Produces:

```swift
struct AccountUsageLine: Equatable {
    let label: String          // "5h", "wk", …
    let fraction: Double       // projected, 0…(>1)
    let state: HeadroomState   // against the row's soft/hard
    let percentText: String    // "62%", or "Refused"
    let resetText: String      // "3:40 PM", "Thu 9 AM", "reset", or "" when no reset time
}
struct AccountUsageRowModel: Equatable {
    enum Body: Equatable { case lines([AccountUsageLine]), message(String) }  // message: "No usage yet" / "No current reading"
    let body: Body
    let soft: Double
    let hard: Double
    let tooltip: String        // also the accessibility value
}
extension MeterFormatter {
    static func windowLabel(_ name: String) -> String
    static func accountUsage(account id: UUID, ledger: CapacityLedger, now: Date,
                             timeZone: TimeZone = .current, locale: Locale = .current) -> AccountUsageRowModel
}
```

**Rules for `accountUsage`:**
- **Thresholds:** collect every pool in `ledger.allPools` whose `accounts` contains `id`. Take the minimum `softThreshold` and the minimum `hardThreshold`. With no pool, use `CapacityPool.defaultSoftThreshold`/`defaultHardThreshold`.
- **No reading:** if there is no `latestReading` and no active rejection, the body is `.message("No usage yet")`.
- **Active rejection** (`ledger.rejection(account:)`, `now < expiry`): one line.
  - The label is the worst window's label, or `"5h"` when there is no reading.
  - `fraction` is 1, `state` is `.overHard`, `percentText` is `"Refused"`.
  - `resetText` is the expiry, formatted by the reset rule below.
- **Usable windows:** those whose `effectiveUtilization` is non-nil. If there are none, the body is `.message("No current reading")`.
- **Choosing the lines:** at most 2.
  - The first line is the window named `five_hour`. If there is none, take the first window by name order.
  - The second is the worst of the remaining windows by projected fraction.
  - With exactly one window, show one line.
- **Reset text:**
  - A future reset under 24 h away: `h:mm a`.
  - A future reset 24 h or more away: `EEE h a`.
  - A window projected to 0 because its reset passed: `"reset"`.
  - No reset time: `""`.
- **Tooltip:** one line per window in the reading, including unusable ones. Lines are joined by `"\n"`, and the source line comes last:
  - a usable window: `"<label> <pct>% · resets <EEE MMM d, h:mm a>"`;
  - a window that has reset: `"<label> 0% · reset"`;
  - an unusable window: `"<label> <pct>% · no reset time"`;
  - the source line: `"<source> · <MeterFormatter.age>"`, plus `" · held from last reading"` when `!isFresh`.

  For a `.message("No usage yet")` row the tooltip is `"No usage yet"`.
- **`windowLabel`:**
  - Use the global-constraints table first.
  - Otherwise a name `"<n>m"` becomes `"<n/60>h"` when n is a multiple of 60, else `"<n>m"`.
  - Otherwise a `"<limitId>:<base>"` name is labelled as its `base`.
  - Otherwise use the name's first 6 characters.

- [ ] **Step 1: Write the failing tests** in `AccountUsageFormatterTests`

Use `utc`/`posix` as `MeterFormatterTests` does, a `CapacityLedger` configured with `UsageRefs` accounts, and readings built with `UsageReading(...)`. Tests and the key assertions:

- `testWindowLabels`:
  - `windowLabel("five_hour") == "5h"`
  - `"seven_day" → "wk"`
  - `"seven_day_opus" → "Opus wk"`
  - `"60m" → "1h"`
  - `"90m" → "90m"`
  - `"codex_other:five_hour" → "5h"`
  - `"credits_balance" → "credit"`
- `testFreshTwoWindows`: five_hour 0.62 resetting 3:40 PM the same day, and seven_day 0.18 resetting more than a day ahead. Expect `.lines`, with labels `["5h","wk"]`, `percentText` `["62%","18%"]`, and `resetText` `["3:40 PM","Thu 9 AM"]`.
- `testIdleWindowPastResetReadsZeroAndSaysReset`: a reading 3 days old whose five_hour reset has passed and whose weekly reset is still ahead. Expect `5h` at `"0%"`/`"reset"`, `wk` holding its value, and a tooltip containing `"held from last reading"`.
- `testNoReadingSaysNoUsageYet`: `.message("No usage yet")`.
- `testStaleNoResetWindowsGoToTheTooltipOnly`: a stale reading with five_hour (has a reset) and `credits` (no reset). Expect one line, `5h`, and a tooltip containing `"credit"` and `"no reset time"`.
- `testOnlyNoResetWindowsStaleSaysNoCurrentReading`: `.message("No current reading")`.
- `testActiveRejectionShowsRefused`: `percentText == "Refused"`, `state == .overHard`, and `resetText` is the expiry.
- `testStrictestPoolThresholdsColourTheRow`: the account is in pool A (soft 0.8) and pool B (soft 0.5), at 0.6. Expect `soft == 0.5` and the line state `.overSoft`.
- `testThreeWindowsShowFiveHourAndWorstOfTheRest`: five_hour 0.1, seven_day 0.3, seven_day_opus 0.9. Expect lines `["5h","Opus wk"]`, and a tooltip that also lists `wk`.

- [ ] **Step 2: Run, expect failure**

Run: `FD_TEST_FILTER=AccountUsageFormatterTests ./scripts/test-unit.sh`

Expected: the build fails with "cannot find 'AccountUsageRowModel'".

- [ ] **Step 3: Implement the types and the two functions in `MeterViews.swift`**

Reuse `MeterFormatter.age` and `HeadroomPolicy.effectiveUtilization`. The state uses the same comparison `evaluate` does: `>= hard`, then `>= soft`.

- [ ] **Step 4: Run, expect pass**

Run: `FD_TEST_FILTER=AccountUsageFormatterTests,MeterFormatterTests ./scripts/test-unit.sh`

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Usage/MeterViews.swift Tests/FlightDeckTests/FlightControlL3/Usage/AccountUsageFormatterTests.swift
git commit -m "feat: format an account's usage windows for its Accounts row"
```

---

### Task 3: Draw the cluster in the account row

**Files:**
- Modify: `Sources/FlightDeck/FlightControl/Usage/MeterViews.swift`: add `struct AccountUsageCluster: View`.
- Modify: `Sources/FlightDeck/Preferences/UI/AccountsSettingsTab.swift`:
  - add `@ObservedObject var usage: UsageService`, defaulted in `init` to `UsageService.shared`;
  - in `accountRow` (line 338), insert the cluster after `Spacer(minLength: 8)` and before the Default capsule.
- Modify: `UITests/FlightDeckUITests/CapacityUITests.swift`: add one activity to `testMetersAndCapacityPane`.

**Interfaces:**
- Consumes: Task 2's `MeterFormatter.accountUsage(account:ledger:now:)` and `AccountUsageRowModel`/`AccountUsageLine`, plus the existing `MeterTrack(fraction:soft:hard:state:)`.
- Produces: `AccountUsageCluster(model: AccountUsageRowModel)`, and accessibility identifier `account-usage-<displayName>` on the row's cluster.

**View:**
- **Lines:** a `VStack(spacing: 2)` of up to 2 `HStack` lines, in `.caption` font. Each line, with fixed-width columns:
  - the label, about 44 pt, trailing-aligned and secondary;
  - a `MeterTrack`, 40×4;
  - `percentText`, about 34 pt, `.monospacedDigit()`;
  - `resetText`, about 56 pt, secondary.
- **Message body:** a single `.caption` line in `.secondary`.
- **Width:** the whole cluster has a fixed width (about 150 pt; tune it so nothing truncates at the default Settings width).
- **Tooltip and accessibility:**
  - `.help(model.tooltip)` and `.accessibilityElement(children: .ignore)`;
  - `.accessibilityLabel("<displayName> usage")` and `.accessibilityValue(model.tooltip)`.
- **Live updates:** in `accountRow`, read `let _ = usage.revision` (as `CapacityPane` does) so the 30 s tick re-renders a reset crossing. Build the model with `MeterFormatter.accountUsage(account: account.id, ledger: usage.ledger, now: Date())`.

- [ ] **Step 1: Write the UI activity** (it fails until the cluster exists)

In `testMetersAndCapacityPane`, after the Capacity activity, add `"Settings → Accounts shows each account's usage in its row"`:

```swift
prefs.buttons["Accounts"].click()
let work = prefs.descendants(matching: .any)["account-usage-Work"]
XCTAssertTrue(work.waitForExistence(timeout: 10))
XCTAssertTrue((work.value as? String ?? "").contains("82%"), work.value as? String ?? "")
let row = prefs.descendants(matching: .any)["account-row-Work"]
let spare = prefs.descendants(matching: .any)["account-row-Spare"]
XCTAssertEqual(row.frame.height, spare.frame.height, accuracy: 0.5, "a row with two usage lines is no taller than one with a message")
XCTAssertTrue(row.frame.contains(work.frame), "the cluster sits inside its row")
shoot(prefs, "accounts-usage")
```

The fixture's Work reading is five_hour 0.82 and seven_day 0.31 (`UsageFixture.swift:34`). Spare has no reading, so its cluster shows `No usage yet`.

Also record the row height before the change. Run once on master and attach the `account-row-Work` height, then assert it is unchanged. The cheapest way: put the current value in as a literal with a comment naming this plan. Measure it in Step 2's run, before Step 3.

- [ ] **Step 2: Run, expect failure, and read the baseline row height**

Run: `./scripts/test-ui-capacity.sh` (it sets `TEST_RUNNER_FLIGHTDECK_CAPACITY_UI=1` and runs on the UI-test Mac; screenshots land in `DerivedData/capacity-ui-shots/`)

Expected: FAIL, because `account-usage-Work` does not exist. Read `account-row-Work`'s height from the attached tree and put it into an `XCTAssertEqual(row.frame.height, <baseline>, accuracy: 0.5)` assertion.

- [ ] **Step 3: Implement `AccountUsageCluster` and wire it into `accountRow` and the `init`**

- [ ] **Step 4: Run the UI test, expect pass, and inspect the screenshot**

Run: `./scripts/test-ui-capacity.sh` (it sets `TEST_RUNNER_FLIGHTDECK_CAPACITY_UI=1` and runs on the UI-test Mac; screenshots land in `DerivedData/capacity-ui-shots/`)

Expected: PASS. Open the `accounts-usage` screenshot in `DerivedData/capacity-ui-shots/` and confirm all of the following:
- the name/caption is not truncated more than before;
- both lines show;
- the columns line up across Work, Spare and Codex.

- [ ] **Step 5: Run the full unit suite**

Run: `./scripts/test-unit.sh`

Expected: everything passes except failures already present before this work. The pre-existing one is `ClaudePluginPayloadTests.testHooksManifestLoadsOnlyTheSwitchAccountModuleAndTheStatusLineShips`, which comes from the uncommitted `/budget` work. Name every failure in the report.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Usage/MeterViews.swift Sources/FlightDeck/Preferences/UI/AccountsSettingsTab.swift UITests/FlightDeckUITests/CapacityUITests.swift
git commit -m "feat: show each account's usage and resets in its Accounts row"
```
