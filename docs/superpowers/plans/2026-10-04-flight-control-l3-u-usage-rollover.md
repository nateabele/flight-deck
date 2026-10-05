# Flight Control L3-U Usage and Rollover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flight Deck knows how much of each hosted account's usage window is used, leases new
work only to accounts with headroom, and hands a swarm agent whose account crosses its hard
threshold to a fresh agent on the next account, with a pointer to the old transcript.

**Architecture:** Pure state lives in IntakeKit (`Sources/IntakeKit/FlightControl/`, Swift 6,
Foundation only): the pool model, the headroom policy, the lease policy, a lock-protected
`CapacityLedger` that *is* the real `CapacityReader` and `PoolAllocator`, the
`LedgerHandoffPlanner`, the hand-off prompt and every meter parser. The app layer
(`Sources/FlightDeck/FlightControl/Usage/`, `@MainActor`, Swift 5 mode) owns the meter sources
(codex app-server, the claude mod's files, headless seats, OpenCode errors, the fleet's API
errors), `UsageService` that funnels them into the ledger, the `HandoffDriver` and its host, the
transcript pointers, the meter views and the Capacity settings pane. A small TypeScript mod in
the bundled Claude plugin (`Resources/ClaudePlugin/hooks/register.ts`) writes each tab's
`session.measure` rate limits to a file Flight Deck reads.

**Tech Stack:** Swift 6 (IntakeKit), Swift 5 mode (app), SwiftUI, XCTest, XCUITest, XcodeGen,
TypeScript (Claude Code mod API, claude 2.1.289), `codex app-server` JSON-RPC, `br`, `am`.

**Spec:** `docs/superpowers/specs/2026-10-04-flight-control-l3-usage-rollover-design.md`
(overview: `docs/superpowers/specs/2026-10-04-flight-control-l3-overview-contract-design.md`).

**Contract (lands before this plan executes):** `docs/superpowers/plans/2026-10-04-flight-control-l3-0-contract.md`.
This plan consumes exactly these L3-0 symbols and never redefines them: `PoolID`, `HarnessID`,
`KindID`, `AccountRef`, `AccountHeadroom`, `HeadroomState`, `AccountLease`, `UsageWindow`,
`UsageReading` (+ `worstWindow`), `TranscriptPointer`, `TaskRef`, `SessionRef`,
`SwarmAgentSnapshot`, `HandoffRequest`, `SpawnError`, `ExecutionBlock`, `AssignmentSource`,
`TaskKind`, `AdapterCatalogs`, `Assignment`, protocols `CapacityReader`, `PoolAllocator`,
`HandoffPlanner`, `UsageMeterSource`, `Router` (with `spill`), app-side
`AgentRoutingCapabilities`, `RoutingCapability`, `AccountModel`, `RoutingCapabilityRegistry`,
`ClaudeRoutingCapabilities`/`CodexRoutingCapabilities` (this plan fills their
`usageMeterSource(account:)` and `transcriptPointer(for:)`), `SwarmSpawner`
(`spawn(task:block:lease:firstPrompt:)`), `AgentID.harnessID`, and the test fakes
`FakeSwarmSpawner`, `FakeRouter`, `FakePoolAllocator`, `FakeHandoffPlanner`,
`FakeCapacityReader`, `FakeUsageMeterSource`, `FakeRoutingCapabilities`, `L3Fixtures` with
`usage-timeline.json`. It is built in parallel with L3-R, L3-I and L3-S and imports none of
their concrete types.

## Global Constraints

- **Thresholds:** hosted pool soft `0.80`, hard `0.95` (`CapacityPool.defaultSoftThreshold`,
  `defaultHardThreshold`). Local pool concurrency cap `2` (`defaultConcurrencyCap`).
- **Freshness:** a reading older than `1800` s (30 min) is `unknown`
  (`HeadroomPolicy.freshness`). A hard rejection with no reset time lasts `900` s (15 min,
  `HeadroomPolicy.rejectionBackoff`).
- **Hand-off:** deadline default `600` s (`CapacityPreferences.defaultDeadlineSeconds`);
  "Confirm hand-offs" default **off**.
- **Cadences:** `UsageService` ticks every `5` s; codex `account/rateLimits/read` is polled at
  most every `120` s per account while that account has a live codex tab; the "mod is silent"
  source error appears after `900` s; usage files older than `7` days are pruned at launch.
- **Default pools:** id `<agent raw value>-default` (`claude-default`, `codex-default`), label
  `"<AgentID.displayName> default"`, holding the agent's live accounts in preferences order.
  User pool ids are `pool-<8 lowercase hex>`, minted once; renaming changes only `label`.
- **Usage files:** `~/Library/Application Support/Flight Deck/usage-<debug|release>/<id>.json`,
  passed to claude as `FLIGHT_DECK_USAGE_DIR`. `<id>` is `FLIGHT_DECK_SESSION_ID` (the FD tab
  id) when set, else claude's own session id.
- **Persistence:** `Preferences.capacity: CapacityPreferences?` — optional, like every field
  added to `Preferences` after launch (an old `preferences.v1` blob must still decode).
- IntakeKit is Foundation-only, `SWIFT_VERSION: "6.0"`; every new IntakeKit type is `Sendable`.
  The app target stays `SWIFT_VERSION: "5.0"`. Don't "fix" it.
- UI copy says *tasks*, *agent*, *Flight Control* — never "beads", "seat" or "flywheel".
  `TerminologyGuardTests` scans every new file automatically.
- Comments explain *why* and name the failure they prevent (`docs/CONVENTIONS.md`).
- Tests: TDD; confirm each new test fails first. One class:
  `FD_TEST_FILTER=<Class> ./scripts/test-unit.sh 2>&1 | tail -40`. The script **exits 0 on
  failure**: read the final `** SHARDED UNIT RUN PASSED|FAILED` line and
  `rg -n "error:" <log>`. `@MainActor` async tests use `await fulfillment(of:)`, never
  `wait(for:)` (deadlocks). Subagents run tests in the foreground.
- Live tests are skipped unless `USAGE_LIVE=1` (or `TEST_RUNNER_USAGE_LIVE=1`).
- UI tests never run in a loop, never through `smoke.sh`; `scripts/test-ui-capacity.sh` warns
  10 s before it takes the foreground and honors `scripts/throttle.sh`.
- Commits: lowercase, behavioral, imperative; `git add` by path; trailer
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never `git stash`.
- Work in a worktree (`superpowers:using-git-worktrees`). Symlink `vendor/ghostty-artifacts`
  and `vendor/boringssl-artifacts` (and `vendor/fd-abduco-artifacts` if present) before the
  first build; never commit them. In a worktree use built-in `Edit`, not the quillmap mutators
  (they write to the main checkout).
- Never launch a bundle from `DerivedData/`. Never `defaults delete dev.flightdeck.FlightDeck`.
- Probing `claude` from inside `claude`: clear `CLAUDE_CODE_CHILD_SESSION` and `CLAUDECODE`, or
  transcript saving is silently off.

**Deviations from the spec decided while planning (Task 20 records them in the spec):**
1. **Codex is polled, not only pushed.** `account/rateLimits/updated` is scoped to the
   connection that ran the turn (see `CodexRuntime`'s doc comment), and Flight Deck's turns run
   in a `codex resume` TUI — a different process. So `UsageService` calls
   `account/rateLimits/read` on the account's existing app-server at most every 120 s while the
   account has a live codex tab, and still consumes pushes (new `CodexRPC.onNotification`) for
   turns Flight Deck's own connection runs. Probe 3 confirms or refutes the scoping.
2. **Usage directory** is `usage-<buildTag>` beside `hook-events-<buildTag>`, delivered by the
   new `FLIGHT_DECK_USAGE_DIR` variable, not "`<FD runtime dir>/usage/`". A file is keyed by
   the FD tab id when `FLIGHT_DECK_SESSION_ID` is set (control socket on), else by claude's
   session id, which Flight Deck maps through `Session.pinnedConversationID`.
3. **One funnel for meters.** Every source hands `UsageReading`s to `UsageService`, which feeds
   `CapacityLedger`. A hard rejection is a `UsageReading` with `hardRejection: true`; its
   worst window's `resetsAt`, when it has one, is when the rejection ends. The contract's
   per-account `UsageMeterSource` is served as a tap (`UsageMeterTap`) by
   `usageMeterSource(account:)`; `UsageService.consume(_:)` accepts any `UsageMeterSource`
   (how the OpenCode adapter will plug in).
4. **The real `CapacityReader`/`PoolAllocator`/`HandoffPlanner` are IntakeKit classes**
   (`CapacityLedger`, `LedgerHandoffPlanner`) so their `Sendable` conformance is honest under
   Swift 6, instead of `@MainActor` app classes.
5. **Settings tab.** A top-level **Capacity** tab (`PreferencesTab.capacity`), not "Flight
   Control → Capacity": master has no Flight Control tab, and L3-R and L3-I would collide
   adding one in parallel. Integration may regroup the three panes.
6. **`HandoffHost`.** L3-U ships the driver and `StoreHandoffHost`, which does interrupt,
   retire (Escape when a dialog is open, then the agent's exit command), `br update
   --assignee`, `am file_reservations release`, notification and a JSONL log. The swarm-owned
   parts — the confirmation surface, the kind lookup for spill, the catalogs, the reservation
   list, marking the old tab "handed off →", and the swarm log location — are closures L3-S
   sets at integration. With "Confirm hand-offs" on and no confirmation surface installed, the
   host declines and says so in a notification (never silently accepts).
7. **A window whose `resetsAt` passed after it was read counts as empty** (the spec is silent).
   A `resetsAt` at or before the reading's own `readAt` is clock skew, not a reset.
8. **Empty reservation list.** The prompt says "It held no file reservations. Reserve the files
   you will edit with Agent Mail before you edit them." instead of an empty list.
9. **Deadline during a dialog.** A `.waiting` agent at the deadline is handed off without
   Escape (Escape would answer the dialog as a denial and restart a turn on the exhausted
   account). The retire step then sends Escape, because the agent is being stopped anyway.
10. **"Retried at the next boundary"** after a spawn failure means: the old agent must be seen
    working again and then reach a boundary, so a failing spawn is not retried every 5 s.
11. **"The mod is not loaded"** is detected as: an account has a claude tab Flight Deck has
    seen for 15 min, and no usage file ever arrived for any of that account's tabs.
12. **UI tests.** The pool popover and the row meter are mounted by L3-S at integration, so the
    XCUITest drives them in a DEBUG-only "Meter Gallery" window
    (`-FlightControlMeterGallery YES`) and drives the Capacity pane in Settings, all against
    fixture readings (`-FlightControlUsageFixture YES`, only honored with
    `-FlightDeckResetState YES`).
13. **OpenCode.** Its adapter is on another workstream's unmerged branch. L3-U defines the event
    value `OpenCodeAPIErrorEvent` and `OpenCodeErrorUsageSource`, tested with fakes; wiring
    happens when that branch merges.
14. **`types/`.** The engine lays the mod API declarations into `.claude-plugin/types/` itself
    at load ("regenerate rather than edit"), so the repo does not commit them; the path is
    git-ignored.
15. **Local pool usage counts active leases.** "Cap minus FD's live sessions on that pool" is
    computed as cap minus the pool's unreleased leases; L3-S releases a lease when its session
    ends, is handed off or is reused (spec §4), so the two are the same number.
16. **A failing meter source does not discard a still-fresh reading.** The popover shows the
    source error at once; the account turns `unknown` when its last reading goes stale (≤ 30
    min), rather than the moment one poll fails.

## Review Focus

Five failure modes that the feature tests below would not catch on their own, each pinned by a
named test in the task that owns the code:

- **A tab whose account was removed (tombstoned) keeps producing readings.** The reading must
  still be recorded under the tombstone's id (the tab's identity must not move), but the account
  must never be leased again. Pinned by `testTombstonedAccountIsMeteredButNeverLeased`
  (Task 8).
- **Two pools share one account.** Both must see the same reading (the meter is per account),
  and a lease from one pool must not consume the other's. Pinned by
  `testTwoPoolsSharingAnAccountSeeOneReadingAndLeaseIndependently` (Task 6).
- **A window's reset time passes with no new reading.** A tab that went idle at 97 % must not
  keep its account `overHard` for hours after the window reset. Pinned by
  `testWindowPastItsResetCountsAsEmptyWithoutANewReading` (Task 5).
- **Clock skew between `resetsAt` and now.** A reset time at or before the moment the reading
  was taken is skew and must not zero the window; a reading stamped slightly in the future must
  count as fresh, not as a negative age. Pinned by `testResetAtOrBeforeReadAtIsClockSkewNotAReset`
  and `testReadingStampedInTheFutureIsFresh` (Task 5).
- **The hand-off deadline fires while the agent sits in a permission dialog.** Escape there is
  a denial that restarts a turn on the exhausted account. Pinned by
  `testDeadlineDuringAPermissionDialogHandsOffWithoutEscape` (Task 15).

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/IntakeKit/FlightControl/UsageParsers.swift` | `RateLimitClassifier`, `UsageWindowName`, codex/claude/mod/OpenCode parsers |
| `Sources/IntakeKit/FlightControl/PoolState.swift` | `CapacityPool`, `PoolValidationError`, `Rejection`, `HeadroomPolicy` |
| `Sources/IntakeKit/FlightControl/LeasePolicy.swift` | `LeasePolicy` |
| `Sources/IntakeKit/FlightControl/CapacityLedger.swift` | the real `CapacityReader` + `PoolAllocator` |
| `Sources/IntakeKit/FlightControl/HandoffPrompt.swift` | the hand-off prompt template and `LedgerHandoffPlanner` |
| `Sources/IntakeKit/SeatActivity.swift` | keep `unifiedWindows`, status and reset time from `rate_limit_event` |
| `Sources/FlightDeck/FlightControl/Usage/CapacityPreferences.swift` | stored pools + hand-off settings, default pools |
| `Sources/FlightDeck/FlightControl/Usage/TranscriptPointers.swift` | claude / codex / OpenCode transcript pointers |
| `Sources/FlightDeck/FlightControl/Usage/CodexRateLimitSource.swift` | codex buckets per account |
| `Sources/FlightDeck/FlightControl/Usage/ClaudeModUsageSource.swift` | scans the usage directory |
| `Sources/FlightDeck/FlightControl/Usage/HeadlessClaudeUsageSource.swift` | readings from intake seats |
| `Sources/FlightDeck/FlightControl/Usage/OpenCodeErrorUsageSource.swift` | 429 → hard rejection |
| `Sources/FlightDeck/FlightControl/Usage/UsageService.swift` | environment, funnel, tick, taps, notices |
| `Sources/FlightDeck/FlightControl/Usage/HandoffHost.swift` | `HandoffHost`, `HandoffLogEntry`, `BrAmHandoffCommands`, `StoreHandoffHost` |
| `Sources/FlightDeck/FlightControl/Usage/HandoffDriver.swift` | the hand-off state machine |
| `Sources/FlightDeck/FlightControl/Usage/MeterViews.swift` | models, formatter, `AccountMeterBar`, `PoolMeterList`, `RowMiniMeter` |
| `Sources/FlightDeck/FlightControl/Usage/CapacityEditing.swift` | pure pool edits |
| `Sources/FlightDeck/FlightControl/Usage/UsageFixture.swift` | DEBUG fixture readings + Meter Gallery window |
| `Sources/FlightDeck/Preferences/UI/CapacityPane.swift` | Settings → Capacity |
| `Sources/FlightDeck/Preferences/{Preferences,PreferencesStore,PreferencesTab}.swift`, `UI/PreferencesView.swift` | the `capacity` field and tab |
| `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift` | fill `usageMeterSource` / `transcriptPointer` |
| `Sources/FlightDeck/Agents/{ClaudePluginLocation,ClaudeAdapter}.swift` | usage dir + `FLIGHT_DECK_USAGE_DIR` |
| `Sources/FlightDeck/Agents/Codex/CodexRPC.swift` | `onNotification` |
| `Sources/FlightDeck/SessionStore.swift` | `onCodexNotification`, `codexRateLimitsRead`, `interruptTurn` |
| `Sources/FlightDeck/SessionStore+Handoff.swift` | `retireAgent`, `AgentID.exitCommand` |
| `Sources/FlightDeck/AppDelegate.swift` | `startUsage(store:)` |
| `Resources/ClaudePlugin/hooks/{hooks.json,register.ts}`, `Resources/ClaudePlugin/tests/usage.test.ts` | the usage mod |
| `Tests/FlightDeckTests/FlightControlL3/Usage/*.swift` | unit + live tests |
| `Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/*.json` | codex read/updated, mod file fixtures |
| `UITests/FlightDeckUITests/CapacityUITests.swift`, `scripts/test-ui-capacity.sh` | UI test + runner |

`project.yml` needs no edit: both source trees are globbed recursively,
`Tests/FlightDeckTests/Fixtures` and `Resources/ClaudePlugin` are folder references
(`project.yml:150-175`), and `UITests/FlightDeckUITests` is globbed (`project.yml:201`).

---

### Task 1: Probes (spec §9) — run before any dependent code

**Files:**
- Modify: `docs/superpowers/specs/2026-10-04-flight-control-l3-usage-rollover-design.md` (append §12)
- Scratch only (never committed): `$S` = this session's scratchpad directory, e.g.
  `/private/tmp/claude-501/<project>/<session>/scratchpad`. Every command below sets
  `S=<that path>` first.

**Interfaces:** none. Produces recorded outcomes that gate Tasks 2, 3 (Step 7), 10, 14 and 19.

Each probe step names what to do for each outcome. Record every outcome verbatim (command,
version, observed output) in the spec before moving on.

- [ ] **Step 1: Pin versions and the mod API in the installed build**

The mod API types file moves between releases (2.1.289 writes it under the plugin-authoring
skill's bundled directory). Find it by content, never by a hard-coded path:

```bash
claude --version
codex --version
TYPES=$(rg -l --hidden --no-ignore "SessionRateLimit" /private/tmp/claude-501/bundled-skills ~/.claude/plugins 2>/dev/null | rg 'claude-code\.d\.ts$' | head -1); echo "$TYPES"
rg -n "'session.measure'|export type SessionMeasureInput|export type SessionRateLimit|write: \(path: string, text: string\)|get: \(name: string\) => Promise<string \| undefined>|now: \(\) => Promise<number>" "$TYPES"
```

Expected: `2.1.289 (Claude Code)` or newer; a non-empty `$TYPES`; hits for all six patterns.
If `$TYPES` is empty, the bundled skills have not been unpacked in this session yet: invoke the
`plugin-authoring` skill once (it lays its `types/claude-code.d.ts` down) and search again, or
widen the search to `rg -l --hidden --no-ignore "SessionRateLimit" ~/.claude /private/tmp 2>/dev/null`.
- All six found → continue.
- `session.measure` or `SessionRateLimit` missing → the event was renamed or removed. Read the
  `rateLimits` mentions in `$TYPES` (`rg -n "rateLimits" "$TYPES"`), record what replaced it,
  and adapt `register.ts` in Task 10 to the new event name before writing it. If no event carries
  rate limits, STOP the claude-interactive meter: in Task 10 do only the Swift half (Steps 1–3
  without the payload test, then 7–8 — the usage directory and variable are harmless and Task 13
  compiles against them), delete Task 19's claude test, keep the headless and codex meters, and
  add a FOLLOWUPS entry in Task 20.
- `$.fs.write`, `$.env.get` or `$.clock.now` signatures differ → record them; Task 10 uses the
  recorded signatures.

- [ ] **Step 2: Build a scratch plugin carrying shell hooks AND a module**

Create these files with the Write tool (not heredocs):

`$S/usage-probe/.claude-plugin/plugin.json`
```json
{"name": "fd-usage-probe", "version": "0.0.1", "description": "Flight Deck usage probe"}
```

`$S/usage-probe/hooks/hooks.json`
```json
{
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/mark.sh\""}]}]},
  "modules": ["./register.ts"]
}
```

`$S/usage-probe/scripts/mark.sh` (then `chmod +x`)
```bash
#!/bin/bash
cat >/dev/null
echo stop >> "$FD_PROBE_OUT/shell-hook.txt"
exit 0
```

`$S/usage-probe/hooks/register.ts`
```ts
import type { Register } from 'claude-code'

export const register: Register = (on) => {
  on('session.measure', async ($, e, next) => {
    const dir = await $.env.get('FLIGHT_DECK_USAGE_DIR')
    const tab = await $.env.get('FLIGHT_DECK_SESSION_ID')
    if (dir) {
      const readAt = new Date(await $.clock.now()).toISOString()
      await $.fs.write(`${dir}/${tab ?? 'no-tab'}.json`,
        JSON.stringify({ v: 1, tab: tab ?? null, session: await $.session.id(), readAt, changed: e.changed, rateLimits: e.rateLimits }))
    }
    return next(e)
  })
}
```

Run: `chmod +x "$S/usage-probe/scripts/mark.sh" && claude plugin validate "$S/usage-probe"`
Expected: validation passes, lists a `Stop` command hook, a `session.measure` function hook, and
the env names `FLIGHT_DECK_USAGE_DIR`, `FLIGHT_DECK_SESSION_ID`.
- Passes with both kinds listed → **Outcome 1A**: one `hooks.json` carries both. Task 10 adds
  `"modules"` to `Resources/ClaudePlugin/hooks/hooks.json`.
- Validation rejects the mix (or lists only one kind) → **Outcome 1B**: move the module to a
  second plugin. Re-run with the module in `$S/usage-probe-mod/` (its own
  `.claude-plugin/plugin.json` named `fd-usage-probe-mod`, `hooks/hooks.json` =
  `{"modules": ["./register.ts"]}`) and the shell hook alone in `$S/usage-probe/`; both must
  validate. Task 10 then follows its "Outcome 1B" steps (second bundled plugin
  `Resources/ClaudeUsagePlugin`, injected as a second `--plugin-dir`).

- [ ] **Step 3: Load it in a real interactive session, with no prompt**

The tab must be interactive (a TTY), launched the way Flight Deck launches claude
(`--plugin-dir`), with the child-session markers cleared. tmux gives a TTY without touching the
foreground:

```bash
command -v tmux || echo "NO TMUX"
OUT="$S/usage-probe-out"; rm -rf "$OUT"; mkdir -p "$OUT"
tmux new-session -d -s fdusage -x 200 -y 50 \
  "env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE FD_PROBE_OUT='$OUT' FLIGHT_DECK_USAGE_DIR='$OUT' FLIGHT_DECK_SESSION_ID=11111111-2222-3333-4444-555555555555 claude --plugin-dir '$S/usage-probe'"
```

If `NO TMUX`: `brew install tmux` is not allowed without asking — instead open a Flight Deck
tab, run the same `env … claude --plugin-dir …` line in its shell by hand, and do Steps 3-5
there (this is also the "FD-spawned tab" the spec names).

Wait for the TUI to settle with a background wait (never a foreground `sleep`):
`until tmux capture-pane -p -t fdusage | rg -q '❯|>'; do sleep 1; done` (Bash
`run_in_background: true`, `timeout: 60000`). Then:

```bash
tmux capture-pane -p -t fdusage > "$OUT/pane-boot.txt"; cat "$OUT/pane-boot.txt"
ls -la "$S/usage-probe/.claude-plugin/"
```

- No dialog on screen (no trust, "enable", "reload" or plugin question) → **Outcome 3A**.
- A dialog asks to enable or trust the module → **Outcome 3B**. Read the reference
  (`rg -n "trust|Enable for this session|CLAUDE_CODE_PLUGIN" "$(dirname "$TYPES")/../reference.md"`)
  for a flag, setting or env var that pre-answers it for `--plugin-dir` folders; record it and
  pass it from Task 10's launch environment. If nothing pre-answers it, STOP the
  claude-interactive meter (as in Step 1) — a dialog in every FD claude tab is not acceptable.
- `ls` shows a new `types/` directory under `.claude-plugin/` → **Outcome 3C** (the engine
  writes into the plugin folder): do Task 2 (materialize the plugin into a folder Flight Deck
  owns) — writing into `/Applications/Flight Deck.app` would break the bundle's signature.
  No `types/` → skip Task 2.

- [ ] **Step 4: `session.measure` fires on real traffic and its windows match `/usage`**

```bash
tmux send-keys -t fdusage 'Reply with the single word ok.' Enter
```

Background-wait for the turn: `until [ -s "$OUT/shell-hook.txt" ]; do sleep 1; done`
(`run_in_background: true`, `timeout: 120000`). Then:

```bash
cat "$OUT/11111111-2222-3333-4444-555555555555.json"; echo
tmux send-keys -t fdusage '/usage' Enter
```

Background-wait `until tmux capture-pane -p -t fdusage | rg -qi 'session|week|5.?h'; do sleep 1; done`
(`timeout: 30000`), then `tmux capture-pane -p -t fdusage > "$OUT/pane-usage.txt"; cat "$OUT/pane-usage.txt"`.

- The JSON file exists, its `rateLimits` holds `five_hour` and `seven_day` with `percentUsed`
  equal (to the displayed precision) to the `/usage` screen's percentages, and `shell-hook.txt`
  says `stop` → **Outcome 4A**: shell hooks and the module coexist at runtime and the meter is
  correct. Record both screens' numbers.
- No JSON after the turn, but `shell-hook.txt` exists → the module did not run. Check the debug
  log line the reference describes (`rg -n "fd-usage-probe" ~/.claude/debug/*.txt | tail`)
  and record the reason. If it is a write refusal outside the project → **Outcome 4B**: Task 10
  writes through `$.process.run({ argv: ['/bin/sh', '-c', 'mkdir -p "$1" && cat > "$1/$2"', 'fd', dir, name], input: body })`
  instead of `$.fs.write` (record the exact `$.process.run` signature from `$TYPES` first). Any
  other reason: record it and STOP the claude-interactive meter.
- JSON exists but `rateLimits` is `[]` → the account is not on a subscription (API key). Record
  it; repeat on a subscription login if one exists. Not a blocker.
- Numbers disagree beyond rounding → record both; Task 3's parser keeps `percentUsed / 100`
  and the disagreement goes into FOLLOWUPS.

Close it: `tmux send-keys -t fdusage '/exit' Enter; tmux kill-session -t fdusage 2>/dev/null || true`.

Also record whether headless `claude -p` fires `session.measure` (Task 19's live test relies on
it):

```bash
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE FLIGHT_DECK_USAGE_DIR="$OUT" FLIGHT_DECK_SESSION_ID=22222222-2222-3333-4444-555555555555 \
  claude -p 'Reply with ok.' --plugin-dir "$S/usage-probe" > "$OUT/headless.txt" 2>&1
ls "$OUT"
```

- `22222222-….json` present → **Outcome 4C**: Task 19's claude test runs as written.
- Absent → **Outcome 4D**: Task 19's claude test is deleted and the real-tab check moves to
  The maintainer's checklist in Task 20.

- [ ] **Step 5: The codex app-server answers `account/rateLimits/read`, and when do pushes arrive**

Write `$S/codex_probe.py` with the Write tool. It speaks to `codex app-server` exactly as
`CodexProcessTransport.verifyHandshake` does (newline-delimited JSON-RPC, `initialize` with
`clientInfo` and `experimentalApi`, no `initialized` notification):

```python
import json, subprocess, sys, threading, time, os

turn = "--turn" in sys.argv
p = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
lines = []
def reader():
    for line in p.stdout:
        lines.append(line.strip())
threading.Thread(target=reader, daemon=True).start()
def send(obj):
    p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()
def wait_id(i, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        for l in lines:
            try: o = json.loads(l)
            except Exception: continue
            if o.get("id") == i: return o
        time.sleep(0.1)
    return None

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"clientInfo": {"name": "fd-usage-probe", "version": "0"}, "capabilities": {"experimentalApi": True}}})
print("initialize:", json.dumps(wait_id(1))[:300])
send({"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"})
print("READ:", json.dumps(wait_id(2)))
if turn:
    send({"jsonrpc": "2.0", "id": 3, "method": "thread/start", "params": {"cwd": os.getcwd(), "ephemeral": True}})
    r = wait_id(3); print("thread/start:", json.dumps(r)[:300])
    tid = r["result"]["thread"]["id"]
    send({"jsonrpc": "2.0", "id": 4, "method": "turn/start",
          "params": {"threadId": tid, "input": [{"type": "text", "text": "Reply with the single word ok."}]}})
    end = time.time() + 90
    while time.time() < end and not any('"turn/completed"' in l for l in lines): time.sleep(0.5)
for l in lines:
    if '"method":"account/rateLimits/updated"' in l.replace(" ", ""): print("UPDATED:", l)
p.terminate()
```

Run (read only, no tokens): `cd "$S" && python3 codex_probe.py | tee codex-read.txt`
Expected: a `READ:` line whose `result` has `rateLimits` (and, on 0.147+, `rateLimitsByLimitId`)
with `primary`/`secondary` `{usedPercent, windowDurationMins, resetsAt}`.
- Present → **Outcome 5A**. Save the `result` object verbatim (pretty-printed) as
  `Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-read.captured.json`
  plus a `.provenance.json` beside it (`{"capturedOn": "<date>", "codexVersion": "<codex --version>",
  "capturedBy": "account/rateLimits/read over stdio, see the L3-U plan Task 1 Step 5"}`),
  replacing account-identifying values (`planType` may stay). Task 3 Step 7 adds a test over it.
- An error result (`-32601` method not found, or unauthenticated) → **Outcome 5B**: record it.
  If method-not-found, the codex meter is unavailable on this version: Task 11's codex source
  still ships (schema-tested), and Task 20 adds a FOLLOWUPS entry with the version.

Run (one tiny real turn, a specific reason, never looped):
`cd "$S" && python3 codex_probe.py --turn | tee codex-turn.txt`
- `UPDATED:` lines during the probe's own turn → pushes work on the connection that runs the
  turn. Record a sample line; save it as
  `Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-updated.captured.json`
  (the `params` object) and add the same provenance file.
- No `UPDATED:` line → record it; the 120 s poll is the only live codex source.

Either way, Deviation 1's poll stays: the TUI's turns run on a different connection.

- [ ] **Step 6: Record the outcomes in the spec**

Append to the spec:

```markdown
## 12. Follow-up notes

### Probe results (L3-U plan Task 1, <date>)

- Versions: claude <x>, codex <y>. Mod API types found at <path> (version-specific).
- Probe 1 (one `hooks.json`, shell hooks + `modules`): Outcome <1A|1B>. <evidence>
- Probe 1 (prompt on load): Outcome <3A|3B>. Types laid into the plugin folder: <yes → Task 2 | no>.
- Probe 2 (`session.measure` in an interactive tab): Outcome <4A|4B|…>. Mod file: <numbers>.
  `/usage`: <numbers>. Headless `claude -p`: <4C|4D>.
- Probe 3 (codex `account/rateLimits/read`): Outcome <5A|5B>. Pushes during this connection's
  own turn: <yes|no>.
```

- [ ] **Step 7: Commit**

```bash
git add docs/superpowers/specs/2026-10-04-flight-control-l3-usage-rollover-design.md
git add Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-read.captured.json Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-read.captured.provenance.json 2>/dev/null || true
git add Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-updated.captured.json Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-updated.captured.provenance.json 2>/dev/null || true
git commit -m "docs: record the usage meter probes for flight control rollover" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2 (conditional — only on Outcome 3C): run the bundled plugin from a folder Flight Deck owns

Skip this task entirely unless Task 1 Step 3 saw the engine create `.claude-plugin/types/` in
the plugin folder.

**Files:**
- Modify: `Sources/FlightDeck/Agents/ClaudePluginLocation.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/ClaudePluginMaterializeTests.swift`

**Interfaces:**
- Produces: `ClaudePluginLocation.materializedDirectory: URL`,
  `ClaudePluginLocation.materialize(from: URL, to: URL) throws -> URL`; `applying(to:bundle:)`
  now injects the materialized copy.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import FlightDeck

/// The engine lays its type declarations into a `--plugin-dir` folder at every load (probe 1,
/// Outcome 3C). Pointed at the app bundle, that write lands inside a signed bundle. These pin
/// the copy Flight Deck runs instead: complete, refreshed when the bundle changes, and never
/// fighting the engine over the files it owns.
final class ClaudePluginMaterializeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-materialize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func write(_ text: String, _ path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testCopiesEveryFileOfTheSource() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("{}", "hooks/hooks.json", in: src)
        try write("export const register = () => {}", "hooks/register.ts", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("hooks/register.ts"), encoding: .utf8),
                       "export const register = () => {}")
    }

    func testRefreshesAChangedFileAndKeepsTheEnginesTypes() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("v1", "hooks/register.ts", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        try write("declare module 'claude-code' {}", ".claude-plugin/types/claude-code/index.d.ts", in: dst)
        try write("v2", "hooks/register.ts", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        XCTAssertEqual(try String(contentsOf: dst.appendingPathComponent("hooks/register.ts"), encoding: .utf8), "v2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.appendingPathComponent(".claude-plugin/types/claude-code/index.d.ts").path))
    }

    func testRemovesAFileTheSourceNoLongerShips() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("x", "scripts/old.sh", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        try FileManager.default.removeItem(at: src.appendingPathComponent("scripts/old.sh"))
        try write("y", "scripts/new.sh", in: src)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.appendingPathComponent("scripts/old.sh").path))
    }

    func testKeepsTheExecutableBit() throws {
        let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
        try write("#!/bin/bash\nexit 0\n", "scripts/record.sh", in: src)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.appendingPathComponent("scripts/record.sh").path)
        _ = try ClaudePluginLocation.materialize(from: src, to: dst)
        let perms = try FileManager.default.attributesOfItem(atPath: dst.appendingPathComponent("scripts/record.sh").path)[.posixPermissions] as? NSNumber
        XCTAssertNotEqual((perms?.intValue ?? 0) & 0o100, 0, "record.sh must stay executable or every hook exits 126")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=ClaudePluginMaterializeTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `type 'ClaudePluginLocation' has no member 'materialize'`.

- [ ] **Step 3: Implement**

Add to `ClaudePluginLocation` (inside the enum, after `eventDirectory`):

```swift
    /// Where Flight Deck runs its plugin from, when the engine writes into plugin folders.
    ///
    /// Claude lays its type declarations into `<plugin>/.claude-plugin/types/` every time it loads
    /// a `--plugin-dir` folder the user owns (probe 1, Outcome 3C). The bundle copy lives inside
    /// `/Applications/Flight Deck.app`, which the user owns and which is code-signed: that write
    /// would invalidate the signature on the first claude tab. So the bundle is the source and
    /// this copy is what claude is pointed at.
    static var materializedDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("claude-plugin-\(buildTag)", isDirectory: true)
    }

    /// Mirrors `source` into `destination`: copies new and changed files, removes files the
    /// source no longer ships, and never touches `.claude-plugin/types/`, which is the engine's.
    /// Compares bytes rather than dates so a reinstall of the same build rewrites nothing — a
    /// rewrite would hot-reload the module in every open claude tab for no reason.
    @discardableResult
    static func materialize(from source: URL, to destination: URL = materializedDirectory) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let shipped = try relativeFiles(under: source)
        for path in shipped {
            let from = source.appendingPathComponent(path), to = destination.appendingPathComponent(path)
            let bytes = try Data(contentsOf: from)
            if (try? Data(contentsOf: to)) != bytes {
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: to, options: .atomic)
            }
            if let perms = try fm.attributesOfItem(atPath: from.path)[.posixPermissions] {
                try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: to.path)
            }
        }
        for path in try relativeFiles(under: destination)
        where !shipped.contains(path) && !path.hasPrefix(".claude-plugin/types/") {
            try fm.removeItem(at: destination.appendingPathComponent(path))
        }
        return destination
    }

    private static func relativeFiles(under root: URL) throws -> Set<String> {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: Set<String> = []
        for case let url as URL in walker {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            out.insert(String(full.dropFirst(base.count + 1)))
        }
        return out
    }
```

Change `applying(to:bundle:)`'s injection line from
`return .claude(injecting(into: flags, pluginDirectory: plugin))` to:

```swift
        // Outcome 3C: run the owned copy, never the signed bundle. A failed copy falls back to
        // the bundle — a broken signature is recoverable, a claude tab with no hooks is the
        // silent failure `record.sh`'s header warns about.
        let runnable = (try? materialize(from: plugin)) ?? plugin
        return .claude(injecting(into: flags, pluginDirectory: runnable))
```

- [ ] **Step 4: Run to verify it passes, plus the plugin tests it touches**

Run: `FD_TEST_FILTER=ClaudePluginMaterializeTests,ClaudePluginPayloadTests,AccountLaunchTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`. If an `AccountLaunchTests` case asserts the `--plugin-dir`
path equals the bundle path, update that assertion to `ClaudePluginLocation.materializedDirectory.path`
and say why in its comment (the behavior changed on purpose; the assertion is not weakened).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/ClaudePluginLocation.swift Tests/FlightDeckTests/FlightControlL3/Usage/ClaudePluginMaterializeTests.swift
git commit -m "fix: run the claude plugin from a folder flight deck owns, not the signed bundle" -m "Claude lays its mod type declarations into every --plugin-dir folder it loads (probe 1). Pointed at /Applications/Flight Deck.app that write breaks the code signature. The bundle is now the source of a byte-compared copy under Application Support." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Meter parsers and the shared test support

**Files:**
- Create: `Sources/IntakeKit/FlightControl/UsageParsers.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Usage/UsageTestSupport.swift`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-read.json`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-updated.json`
- Create: `Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/claude-mod-usage.json`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/UsageParsersTests.swift`

**Interfaces:**
- Consumes: L3-0 `UsageWindow`, `UsageReading`, `AccountRef`.
- Produces (all `public`, `Sendable`, in IntakeKit):
  - `enum RateLimitClassifier { static let kinds: Set<String>; static func isRateLimit(status: Int?, kind: String?) -> Bool }`
  - `enum UsageWindowName { static func forDuration(minutes: Int?) -> String }`
  - `struct CodexRateBucket: Equatable { limitId: String; primary: UsageWindow?; secondary: UsageWindow?; reachedType: String?; init(limitId:primary:secondary:reachedType:) }`
  - `enum CodexRateLimitParser { static func bucket(_ snapshot: [String: Any]) -> CodexRateBucket; static func readResponse(_ result: [String: Any]) -> [String: CodexRateBucket]; static func merge(update params: [String: Any], into: [String: CodexRateBucket]) -> [String: CodexRateBucket]; static func reading(_ buckets: [String: CodexRateBucket], account: AccountRef, readAt: Date, source: String = "codex app-server") -> UsageReading? }`
  - `enum ClaudeRateLimitParser { static func windows(rateLimitInfo: [String: Any]) -> [UsageWindow]; static func isRejected(rateLimitInfo: [String: Any]) -> Bool; static func resetsAt(rateLimitInfo: [String: Any]) -> Date? }`
  - `struct ModUsageFile: Equatable { struct Window: Equatable { kind: String; percentUsed: Double; resetsAt: Date? }; v: Int; tab: String?; session: String?; readAt: Date; rateLimits: [Window]; var windows: [UsageWindow]; static func decode(_ data: Data) -> ModUsageFile? }`
  - `struct OpenCodeAPIErrorEvent: Equatable { status: Int; retryAfter: TimeInterval?; message: String; at: Date; init(status:retryAfter:message:at:) }`
  - `enum OpenCodeRateLimit { static let backoff: TimeInterval; static func reading(for: OpenCodeAPIErrorEvent, account: AccountRef) -> UsageReading? }`
  - Test support (test target): `UsageFixtures`, `usageISO(_:)`, `UsageTestClock`, `UsageRefs`, `UsageRecordingRunner`, `UsageSpyNotifier`.

- [ ] **Step 1: Write the fixtures**

`codex-rate-limits-read.json` — hand-shaped from `GetAccountRateLimitsResponse` in
`Tests/FlightDeckTests/Fixtures/Codex/codex-app-server-v2.generated.json` (`usedPercent` is an
int 0–100, `resetsAt` unix seconds, `windowDurationMins` minutes). 1791136800 is
2026-10-04T18:00:00Z:

```json
{
  "rateLimits": {"limitId": "codex", "limitName": null,
    "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1791154800},
    "secondary": {"usedPercent": 71, "windowDurationMins": 10080, "resetsAt": 1791504000},
    "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
    "planType": "plus", "rateLimitReachedType": null, "spendControlReached": null, "individualLimit": null},
  "rateLimitsByLimitId": {
    "codex": {"limitId": "codex", "limitName": null,
      "primary": {"usedPercent": 42, "windowDurationMins": 300, "resetsAt": 1791154800},
      "secondary": {"usedPercent": 71, "windowDurationMins": 10080, "resetsAt": 1791504000},
      "credits": {"hasCredits": false, "unlimited": false, "balance": "0"},
      "planType": "plus", "rateLimitReachedType": null, "spendControlReached": null, "individualLimit": null},
    "codex_bengalfox": {"limitId": "codex_bengalfox", "limitName": "GPT-6 Sol",
      "primary": {"usedPercent": 88, "windowDurationMins": 300, "resetsAt": 1791151200},
      "secondary": null, "credits": null, "planType": "plus",
      "rateLimitReachedType": null, "spendControlReached": null, "individualLimit": null}
  },
  "rateLimitResetCredits": null
}
```

`codex-rate-limits-updated.json` — an `AccountRateLimitsUpdatedNotification`'s `params`, sparse
on purpose (no `secondary`, as the schema's description allows):

```json
{"rateLimits": {"limitId": "codex", "limitName": null,
  "primary": {"usedPercent": 96, "windowDurationMins": 300, "resetsAt": 1791154800},
  "secondary": null, "credits": null, "planType": null,
  "rateLimitReachedType": null, "spendControlReached": null, "individualLimit": null}}
```

`claude-mod-usage.json` — exactly what Task 10's `register.ts` writes (JS `toISOString()` has
milliseconds; claude's own `resetsAt` may not):

```json
{"v": 1, "tab": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "session": "8552adc8-bbae-48c2-9b86-29a5becfa369",
 "readAt": "2026-10-04T19:00:00.000Z",
 "rateLimits": [{"kind": "five_hour", "percentUsed": 82.5, "resetsAt": "2026-10-04T23:00:00.000Z"},
                {"kind": "seven_day", "percentUsed": 31, "resetsAt": "2026-10-09T00:00:00Z"}]}
```

- [ ] **Step 2: Write the shared test support**

`Tests/FlightDeckTests/FlightControlL3/Usage/UsageTestSupport.swift`:

```swift
import Foundation
import XCTest
import IntakeKit
@testable import FlightDeck

/// Shared by the L3-U tests. Every name is prefixed `Usage…`: the test target is one module, so an
/// unprefixed `TestClock` here would collide with a sibling branch's at integration.
enum UsageFixtures {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: Token.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures/FlightControlL3/Usage"),
            "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    static func object(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    }
}

/// ISO 8601 with or without fractional seconds, for writing times in tests the way the
/// fixtures spell them.
func usageISO(_ text: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: text) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: text)!
}

final class UsageTestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date = usageISO("2026-10-04T18:00:00Z")) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

enum UsageRefs {
    /// The account `usage-timeline.json` (L3-0) is written for.
    static let workID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let spareID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let codexID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let work = AccountRef(harness: "claude", id: workID, label: "Work")
    static let spare = AccountRef(harness: "claude", id: spareID, label: "Spare")
    static let codex = AccountRef(harness: "codex", id: codexID, label: "Codex")

    static func reading(_ account: AccountRef, _ worst: Double, at: Date, resetsAt: Date? = nil,
                        rejection: Bool = false) -> UsageReading {
        UsageReading(account: account, windows: [UsageWindow(name: "five_hour", utilization: worst, resetsAt: resetsAt)],
                     readAt: at, source: "test", hardRejection: rejection)
    }
}

/// Records `br`/`am` invocations instead of running them.
final class UsageRecordingRunner: FlywheelProcessRunner, @unchecked Sendable {
    struct Call: Equatable { let executable: String; let args: [String]; let cwd: String? }
    private let lock = NSLock()
    private var recorded: [Call] = []
    var exitCode: Int32 = 0
    var stdout = ""
    var calls: [Call] { lock.withLock { recorded } }

    func run(_ executable: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        lock.withLock { recorded.append(Call(executable: executable, args: args, cwd: cwd)) }
        return (stdout, exitCode)
    }
}

final class UsageSpyNotifier: Notifying {
    struct Note: Equatable { let session: UUID; let title: String; let body: String }
    private(set) var notes: [Note] = []
    func requestAuthorization() {}
    func notify(sessionID: UUID, title: String, subtitle: String, body: String) {
        notes.append(Note(session: sessionID, title: title, body: body))
    }
    func withdraw(sessionID: UUID) {}
}
```

- [ ] **Step 3: Write the failing parser tests**

```swift
import XCTest
import IntakeKit

/// Every meter is a different vendor's shape for the same three facts — how full a window is,
/// when it resets, and whether the account was refused. These pin each translation against the
/// recorded or schema-shaped payloads, so a vendor rename shows up here, not as an account that
/// silently reads "no reading" forever.
final class UsageParsersTests: XCTestCase {
    func testRateLimitClassifierNamesOnlyQuotaFailures() {
        XCTAssertTrue(RateLimitClassifier.isRateLimit(status: 429, kind: nil))
        XCTAssertTrue(RateLimitClassifier.isRateLimit(status: nil, kind: "rate_limit"))
        XCTAssertTrue(RateLimitClassifier.isRateLimit(status: nil, kind: "rate_limit_exceeded"))
        XCTAssertTrue(RateLimitClassifier.isRateLimit(status: nil, kind: "usage_limit_exceeded"))
        XCTAssertFalse(RateLimitClassifier.isRateLimit(status: 529, kind: "overloaded"),
                       "an overloaded API is everyone's problem, not this account's quota")
        XCTAssertFalse(RateLimitClassifier.isRateLimit(status: nil, kind: "server_overloaded"))
        XCTAssertFalse(RateLimitClassifier.isRateLimit(status: nil, kind: nil))
    }

    func testWindowNamesFollowTheirDuration() {
        XCTAssertEqual(UsageWindowName.forDuration(minutes: 300), "five_hour")
        XCTAssertEqual(UsageWindowName.forDuration(minutes: 10080), "seven_day")
        XCTAssertEqual(UsageWindowName.forDuration(minutes: 60), "60m")
        XCTAssertEqual(UsageWindowName.forDuration(minutes: nil), "window")
    }

    func testCodexReadPrefersTheMultiBucketView() throws {
        let buckets = CodexRateLimitParser.readResponse(try UsageFixtures.object("codex-rate-limits-read"))
        XCTAssertEqual(Set(buckets.keys), ["codex", "codex_bengalfox"])
        XCTAssertEqual(buckets["codex"]?.primary, UsageWindow(name: "five_hour", utilization: 0.42, resetsAt: usageISO("2026-10-04T23:00:00Z")))
        XCTAssertEqual(buckets["codex"]?.secondary, UsageWindow(name: "seven_day", utilization: 0.71, resetsAt: usageISO("2026-10-09T00:00:00Z")))
        XCTAssertEqual(buckets["codex_bengalfox"]?.primary?.name, "codex_bengalfox:five_hour",
                       "a second bucket's windows say which bucket they are")
        XCTAssertNil(buckets["codex_bengalfox"]?.secondary)
    }

    func testCodexReadFallsBackToTheSingleBucketView() throws {
        var result = try UsageFixtures.object("codex-rate-limits-read")
        result["rateLimitsByLimitId"] = NSNull()
        let buckets = CodexRateLimitParser.readResponse(result)
        XCTAssertEqual(Array(buckets.keys), ["codex"])
        XCTAssertEqual(buckets["codex"]?.primary?.utilization ?? 0, 0.42, accuracy: 1e-9)
    }

    func testCodexReadingIsWorstAcrossBuckets() throws {
        let buckets = CodexRateLimitParser.readResponse(try UsageFixtures.object("codex-rate-limits-read"))
        let at = usageISO("2026-10-04T18:00:00Z")
        let r = try XCTUnwrap(CodexRateLimitParser.reading(buckets, account: AccountRef(harness: "codex", id: UUID(), label: "C"), readAt: at))
        XCTAssertEqual(r.worstWindow?.name, "codex_bengalfox:five_hour")
        XCTAssertEqual(r.worstWindow?.utilization ?? 0, 0.88, accuracy: 1e-9)
        XCTAssertFalse(r.hardRejection)
        XCTAssertEqual(r.source, "codex app-server")
        XCTAssertNil(CodexRateLimitParser.reading([:], account: r.account, readAt: at), "no buckets is no reading, not an empty one")
    }

    func testCodexUpdateIsSparseAndMergesIntoTheLastRead() throws {
        let read = CodexRateLimitParser.readResponse(try UsageFixtures.object("codex-rate-limits-read"))
        let merged = CodexRateLimitParser.merge(update: try UsageFixtures.object("codex-rate-limits-updated"), into: read)
        XCTAssertEqual(merged["codex"]?.primary?.utilization ?? 0, 0.96, accuracy: 1e-9)
        XCTAssertEqual(merged["codex"]?.secondary?.utilization ?? 0, 0.71, accuracy: 1e-9,
                       "a null window in a rolling update is 'not sent', not 'empty'")
        XCTAssertEqual(merged["codex_bengalfox"], read["codex_bengalfox"])
    }

    func testCodexReachedLimitIsAHardRejection() {
        let snap: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": 100, "windowDurationMins": 300, "resetsAt": 1791154800],
                                   "rateLimitReachedType": "rate_limit_reached"]
        let buckets = CodexRateLimitParser.readResponse(["rateLimits": snap])
        let r = CodexRateLimitParser.reading(buckets, account: AccountRef(harness: "codex", id: UUID(), label: "C"), readAt: Date())
        XCTAssertEqual(r?.hardRejection, true)
        XCTAssertEqual(r?.worstWindow?.resetsAt, usageISO("2026-10-04T23:00:00Z"))
    }

    func testClaudeUnifiedWindowsFromAStreamRecord() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "claude-stream-activity", withExtension: "jsonl", subdirectory: "Fixtures/Intake"))
        let line = try XCTUnwrap(String(contentsOf: url, encoding: .utf8).split(separator: "\n").first { $0.contains("\"rate_limit_event\"") })
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let info = try XCTUnwrap(obj["rate_limit_info"] as? [String: Any])
        XCTAssertEqual(ClaudeRateLimitParser.windows(rateLimitInfo: info), [
            UsageWindow(name: "five_hour", utilization: 0.01, resetsAt: Date(timeIntervalSince1970: 1790567400)),
            UsageWindow(name: "seven_day", utilization: 0.43, resetsAt: Date(timeIntervalSince1970: 1791032400)),
        ])
        XCTAssertFalse(ClaudeRateLimitParser.isRejected(rateLimitInfo: info))
        XCTAssertEqual(ClaudeRateLimitParser.resetsAt(rateLimitInfo: info), Date(timeIntervalSince1970: 1790567400))
    }

    func testClaudeStatusOtherThanAllowedIsARejection() {
        XCTAssertTrue(ClaudeRateLimitParser.isRejected(rateLimitInfo: ["status": "rejected"]))
        XCTAssertFalse(ClaudeRateLimitParser.isRejected(rateLimitInfo: ["status": "allowed_warning"]))
        XCTAssertFalse(ClaudeRateLimitParser.isRejected(rateLimitInfo: [:]), "no status is no evidence")
    }

    func testModFileDecodesWithAndWithoutFractionalSeconds() throws {
        let file = try XCTUnwrap(ModUsageFile.decode(try UsageFixtures.data("claude-mod-usage")))
        XCTAssertEqual(file.tab, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(file.readAt, usageISO("2026-10-04T19:00:00.000Z"))
        XCTAssertEqual(file.windows.map(\.name), ["five_hour", "seven_day"])
        XCTAssertEqual(file.windows[0].utilization, 82.5 / 100, accuracy: 1e-9)
        XCTAssertEqual(file.windows[1].resetsAt, usageISO("2026-10-09T00:00:00Z"))
    }

    func testModFileRejectsATornWriteAndANewerVersion() {
        XCTAssertNil(ModUsageFile.decode(Data(#"{"v":1,"tab":"x","readAt":"2026-10-04T19:00:00.000Z","rateLim"#.utf8)))
        XCTAssertNil(ModUsageFile.decode(Data(#"{"v":2,"readAt":"2026-10-04T19:00:00.000Z","rateLimits":[]}"#.utf8)))
        XCTAssertNil(ModUsageFile.decode(Data(#"{"v":1,"readAt":"yesterday","rateLimits":[]}"#.utf8)))
    }

    func testOpenCode429WithRetryAfterEndsThen() throws {
        let at = usageISO("2026-10-04T18:00:00Z")
        let r = try XCTUnwrap(OpenCodeRateLimit.reading(for: OpenCodeAPIErrorEvent(status: 429, retryAfter: 120, message: "slow down", at: at),
                                                        account: UsageRefs.work))
        XCTAssertTrue(r.hardRejection)
        XCTAssertEqual(r.worstWindow?.resetsAt, at.addingTimeInterval(120))
    }

    func testOpenCode429WithoutRetryAfterLeavesTheBackoffToPolicy() throws {
        let r = try XCTUnwrap(OpenCodeRateLimit.reading(for: OpenCodeAPIErrorEvent(status: 429, retryAfter: nil, message: "", at: Date()),
                                                        account: UsageRefs.work))
        XCTAssertTrue(r.hardRejection)
        XCTAssertEqual(r.windows, [], "no reset time: HeadroomPolicy applies its 15-minute backoff")
        XCTAssertEqual(OpenCodeRateLimit.backoff, 15 * 60)
    }

    func testOpenCodeOtherErrorsAreNotMeters() {
        XCTAssertNil(OpenCodeRateLimit.reading(for: OpenCodeAPIErrorEvent(status: 500, retryAfter: nil, message: "", at: Date()),
                                               account: UsageRefs.work))
    }
}
```

- [ ] **Step 4: Run to verify it fails**

Run: `FD_TEST_FILTER=UsageParsersTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'RateLimitClassifier' in scope`.

- [ ] **Step 5: Implement `UsageParsers.swift`**

```swift
import Foundation

/// Which reported failures mean "this account is out of quota", as opposed to "the API is having
/// a bad day". Only the first moves an account to over-hard: treating an overloaded API as
/// exhaustion would hand off every agent on every account at once, onto accounts that are just
/// as overloaded. Kinds are each agent's own spelling — claude's transcript `error`, codex's
/// rollout `codex_error_info` in snake_case (see `CodexTurnRecovery`).
public enum RateLimitClassifier {
    public static let kinds: Set<String> = ["rate_limit", "rate_limit_exceeded", "usage_limit_exceeded", "usage_limit_reached"]

    public static func isRateLimit(status: Int?, kind: String?) -> Bool {
        if status == 429 { return true }
        guard let kind else { return false }
        return kinds.contains(kind)
    }
}

/// One spelling for a window across vendors, so the popover says "five_hour" for claude's
/// `five_hour` and codex's 300-minute primary alike.
public enum UsageWindowName {
    public static func forDuration(minutes: Int?) -> String {
        switch minutes {
        case 300?: return "five_hour"
        case 10080?: return "seven_day"
        case let m?: return "\(m)m"
        case nil: return "window"
        }
    }
}

/// One codex rate-limit bucket (`limitId`), as the app-server reports it.
public struct CodexRateBucket: Equatable, Sendable {
    public var limitId: String
    public var primary: UsageWindow?
    public var secondary: UsageWindow?
    /// Non-nil once codex says a limit was reached (`rate_limit_reached`, a depleted workspace…).
    public var reachedType: String?

    public init(limitId: String, primary: UsageWindow? = nil, secondary: UsageWindow? = nil, reachedType: String? = nil) {
        self.limitId = limitId; self.primary = primary; self.secondary = secondary; self.reachedType = reachedType
    }
}

/// `account/rateLimits/read` and `account/rateLimits/updated`, per the schema in
/// `codex-app-server-v2.generated.json`: `usedPercent` is an integer 0–100, `resetsAt` unix
/// seconds, `windowDurationMins` minutes.
public enum CodexRateLimitParser {
    static func window(_ raw: Any?, limitId: String) -> UsageWindow? {
        guard let w = raw as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (w["windowDurationMins"] as? NSNumber)?.intValue
        let resets = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let base = UsageWindowName.forDuration(minutes: minutes)
        return UsageWindow(name: limitId == "codex" ? base : "\(limitId):\(base)", utilization: used / 100, resetsAt: resets)
    }

    public static func bucket(_ snapshot: [String: Any]) -> CodexRateBucket {
        let id = snapshot["limitId"] as? String ?? "codex"
        return CodexRateBucket(limitId: id,
                               primary: window(snapshot["primary"], limitId: id),
                               secondary: window(snapshot["secondary"], limitId: id),
                               reachedType: snapshot["rateLimitReachedType"] as? String)
    }

    /// The multi-bucket view when the server sends one, else the backward-compatible single
    /// bucket. Keyed by `limitId`.
    public static func readResponse(_ result: [String: Any]) -> [String: CodexRateBucket] {
        if let byID = result["rateLimitsByLimitId"] as? [String: Any], !byID.isEmpty {
            var out: [String: CodexRateBucket] = [:]
            for (key, value) in byID {
                guard var snapshot = value as? [String: Any] else { continue }
                if snapshot["limitId"] as? String == nil { snapshot["limitId"] = key }
                let b = bucket(snapshot)
                out[b.limitId] = b
            }
            return out
        }
        guard let single = result["rateLimits"] as? [String: Any] else { return [:] }
        let b = bucket(single)
        return [b.limitId: b]
    }

    /// A rolling update is sparse: the schema says a missing or null value "does not clear a
    /// previously observed value". So only what the update carries replaces what the last read
    /// said; the 120-second read (UsageService) is what corrects anything an update left stale.
    public static func merge(update params: [String: Any], into buckets: [String: CodexRateBucket]) -> [String: CodexRateBucket] {
        guard let snapshot = params["rateLimits"] as? [String: Any] else { return buckets }
        let id = snapshot["limitId"] as? String ?? "codex"
        var out = buckets
        var b = out[id] ?? CodexRateBucket(limitId: id)
        if let p = window(snapshot["primary"], limitId: id) { b.primary = p }
        if let s = window(snapshot["secondary"], limitId: id) { b.secondary = s }
        if let reached = snapshot["rateLimitReachedType"] as? String { b.reachedType = reached }
        out[id] = b
        return out
    }

    public static func reading(_ buckets: [String: CodexRateBucket], account: AccountRef, readAt: Date,
                               source: String = "codex app-server") -> UsageReading? {
        guard !buckets.isEmpty else { return nil }
        let ordered = buckets.keys.sorted().compactMap { buckets[$0] }
        let windows = ordered.flatMap { [$0.primary, $0.secondary].compactMap { $0 } }
        return UsageReading(account: account, windows: windows, readAt: readAt, source: source,
                            hardRejection: ordered.contains { $0.reachedType != nil })
    }
}

/// claude's stream-json `rate_limit_event.rate_limit_info`. `unifiedWindows` utilization is
/// already 0–1; `resetsAt` is unix seconds.
public enum ClaudeRateLimitParser {
    public static func windows(rateLimitInfo info: [String: Any]) -> [UsageWindow] {
        guard let unified = info["unifiedWindows"] as? [String: Any] else { return [] }
        return unified.keys.sorted().compactMap { name in
            guard let w = unified[name] as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(name: name, utilization: u, resetsAt: resets)
        }
    }

    /// `allowed` and `allowed_warning` pass; anything else that is present is a refusal. An
    /// absent status is no evidence either way.
    public static func isRejected(rateLimitInfo info: [String: Any]) -> Bool {
        guard let status = info["status"] as? String else { return false }
        return !status.hasPrefix("allowed")
    }

    public static func resetsAt(rateLimitInfo info: [String: Any]) -> Date? {
        (info["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }
}

/// The file Flight Deck's claude mod writes per tab: `<usage dir>/<id>.json`. `percentUsed` is
/// 0–100 with one decimal (the mod API's `SessionRateLimit`), so it is divided here, once.
public struct ModUsageFile: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var kind: String
        public var percentUsed: Double
        public var resetsAt: Date?
        public init(kind: String, percentUsed: Double, resetsAt: Date?) { self.kind = kind; self.percentUsed = percentUsed; self.resetsAt = resetsAt }
    }
    public static let currentVersion = 1

    public var v: Int
    public var tab: String?
    public var session: String?
    public var readAt: Date
    public var rateLimits: [Window]

    public var windows: [UsageWindow] {
        rateLimits.map { UsageWindow(name: $0.kind, utilization: $0.percentUsed / 100, resetsAt: $0.resetsAt) }
    }

    static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    /// Nil for a torn write (the mod's write and this read can interleave; the next scan
    /// retries), a newer version, or a missing `readAt` — never a partial reading.
    public static func decode(_ data: Data) -> ModUsageFile? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let v = (obj["v"] as? NSNumber)?.intValue, v <= currentVersion,
              let readAt = date(obj["readAt"]) else { return nil }
        let raw = obj["rateLimits"] as? [[String: Any]] ?? []
        let windows = raw.compactMap { w -> Window? in
            guard let kind = w["kind"] as? String, let pct = (w["percentUsed"] as? NSNumber)?.doubleValue else { return nil }
            return Window(kind: kind, percentUsed: pct, resetsAt: date(w["resetsAt"]))
        }
        return ModUsageFile(v: v, tab: obj["tab"] as? String, session: obj["session"] as? String, readAt: readAt, rateLimits: windows)
    }
}

/// What the OpenCode adapter reports when its server answers with an `APIError`. Defined here,
/// not on that adapter's branch, so the meter can be built and tested before it merges.
public struct OpenCodeAPIErrorEvent: Equatable, Sendable {
    public var status: Int
    /// Seconds, from the `retry-after` header when the provider sent one.
    public var retryAfter: TimeInterval?
    public var message: String
    public var at: Date
    public init(status: Int, retryAfter: TimeInterval?, message: String, at: Date) {
        self.status = status; self.retryAfter = retryAfter; self.message = message; self.at = at
    }
}

/// OpenCode has no meter, only refusals: a 429 is the whole signal.
public enum OpenCodeRateLimit {
    /// Documented here for the popover's wording; `HeadroomPolicy.rejectionBackoff` is what
    /// applies it, to a rejection whose reading carries no reset time.
    public static let backoff: TimeInterval = 15 * 60

    public static func reading(for event: OpenCodeAPIErrorEvent, account: AccountRef) -> UsageReading? {
        guard event.status == 429 else { return nil }
        let windows = event.retryAfter.map {
            [UsageWindow(name: "retry-after", utilization: 1, resetsAt: event.at.addingTimeInterval($0))]
        } ?? []
        return UsageReading(account: account, windows: windows, readAt: event.at, source: "opencode 429", hardRejection: true)
    }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=UsageParsersTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`, no `error:` lines.

- [ ] **Step 7: Add the captured codex response test (only if Task 1 saved one)**

If `codex-rate-limits-read.captured.json` exists, add to `UsageParsersTests`:

```swift
    /// The real payload from probe 3, not the schema-shaped one: a field codex renamed between
    /// the pinned schema and today fails here.
    func testParsesTheCapturedReadResponse() throws {
        let buckets = CodexRateLimitParser.readResponse(try UsageFixtures.object("codex-rate-limits-read.captured"))
        XCTAssertFalse(buckets.isEmpty)
        let r = try XCTUnwrap(CodexRateLimitParser.reading(buckets, account: UsageRefs.codex, readAt: Date()))
        XCTAssertFalse(r.windows.isEmpty)
        for w in r.windows { XCTAssertTrue((0...1.5).contains(w.utilization), "\(w.name) = \(w.utilization)") }
    }
```

Run `FD_TEST_FILTER=UsageParsersTests ./scripts/test-unit.sh 2>&1 | tail -20` → PASSED.
(`UsageFixtures.data` looks up `<name>.json`, so the resource name is `codex-rate-limits-read.captured`.)

- [ ] **Step 8: Commit**

```bash
git add Sources/IntakeKit/FlightControl/UsageParsers.swift Tests/FlightDeckTests/FlightControlL3/Usage/UsageTestSupport.swift Tests/FlightDeckTests/FlightControlL3/Usage/UsageParsersTests.swift Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-read.json Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-updated.json Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/claude-mod-usage.json
git commit -m "feat: parse codex, claude, mod and opencode rate limits into usage readings" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Headless seats keep claude's rate-limit windows

**Files:**
- Modify: `Sources/IntakeKit/SeatActivity.swift` (the `SeatActivity` fields and `foldClaude`'s `rate_limit_event` arm, today at ~lines 38-40 and ~216-219)
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/SeatActivityRateWindowTests.swift`

**Interfaces:**
- Consumes: `ClaudeRateLimitParser` (Task 3).
- Produces: `SeatActivity.rateLimitWindows: [UsageWindow]?`, `SeatActivity.rateLimitStatus: String?`, `SeatActivity.rateLimitResetsAt: Date?`.

- [ ] **Step 1: Verify the code is where this plan says**

Run: `rg -n "case \"rate_limit_event\"|public var rateLimitedAt" Sources/IntakeKit/SeatActivity.swift`
Expected: two hits. If `rate_limit_event` is no longer folded in `foldClaude`, find it with
`rg -n rate_limit_event Sources/IntakeKit` and apply Step 4's change there.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit

/// Headless `claude -p` seats are the only claude processes Flight Deck parses a stream for, and
/// every API call there carries a `rate_limit_event` with the account's real windows. Until now
/// the fold kept only the `status`; these pin that it keeps the windows too, so intake seats
/// meter the account they run on.
final class SeatActivityRateWindowTests: XCTestCase {
    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Intake")))
    }

    func testKeepsUnifiedWindowsFromTheLiveSample() throws {
        var p = ActivityParser(harness: .claude, project: URL(fileURLWithPath: "/p"), now: { Date(timeIntervalSince1970: 0) })
        p.feed(try load("claude-stream-activity"))
        XCTAssertEqual(p.activity.rateLimitWindows, [
            UsageWindow(name: "five_hour", utilization: 0.01, resetsAt: Date(timeIntervalSince1970: 1790567400)),
            UsageWindow(name: "seven_day", utilization: 0.43, resetsAt: Date(timeIntervalSince1970: 1791032400)),
        ])
        XCTAssertEqual(p.activity.rateLimitStatus, "allowed")
        XCTAssertEqual(p.activity.rateLimitResetsAt, Date(timeIntervalSince1970: 1790567400))
        XCTAssertNil(p.activity.rateLimitedAt, "allowed is still not a limit")
    }

    func testARejectedEventRecordsStatusAndStillSetsRateLimitedAt() {
        let clock = Date(timeIntervalSince1970: 1_790_000_000)
        var p = ActivityParser(harness: .claude, project: URL(fileURLWithPath: "/p"), now: { clock })
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1790567400,"unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":1790567400}}}}"# + "\n"
        p.feed(Data(line.utf8))
        XCTAssertEqual(p.activity.rateLimitStatus, "rejected")
        XCTAssertEqual(p.activity.rateLimitedAt, clock)
        XCTAssertEqual(p.activity.rateLimitWindows?.first?.utilization, 1.0)
    }

    func testAnEventWithoutWindowsKeepsTheLastWindows() {
        var p = ActivityParser(harness: .claude, project: URL(fileURLWithPath: "/p"), now: { Date() })
        p.feed(Data((#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.5,"resetsAt":1790567400}}}}"# + "\n").utf8))
        p.feed(Data((#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"# + "\n").utf8))
        XCTAssertEqual(p.activity.rateLimitWindows?.first?.utilization, 0.5)
    }

    /// `activity.json` files written before this change have none of the new keys; they must
    /// still decode, or every live round's seat rows go blank after an upgrade.
    func testOldActivityJSONStillDecodes() throws {
        var a = SeatActivity(harness: .claude, startedAt: Date(timeIntervalSince1970: 0))
        a.rateLimitWindows = [UsageWindow(name: "five_hour", utilization: 0.5, resetsAt: nil)]
        a.rateLimitStatus = "allowed"
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        obj.removeValue(forKey: "rateLimitWindows"); obj.removeValue(forKey: "rateLimitStatus"); obj.removeValue(forKey: "rateLimitResetsAt")
        let old = try JSONDecoder().decode(SeatActivity.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(old.rateLimitWindows)
        XCTAssertNil(old.rateLimitStatus)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=SeatActivityRateWindowTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `value of type 'SeatActivity' has no member 'rateLimitWindows'`.

- [ ] **Step 4: Implement**

In `SeatActivity`, after `public var rateLimitedAt: Date?`:

```swift
    /// The windows claude's last `rate_limit_event` reported (`unifiedWindows`). claude sends one
    /// per API call, allowed or not, so a headless seat meters the account it runs on for free
    /// (Flight Control L3-U). Nil until the first event carrying windows; an event without
    /// windows leaves the last ones standing.
    public var rateLimitWindows: [UsageWindow]?
    /// That event's `status` — `allowed`, `allowed_warning`, `rejected` — verbatim.
    public var rateLimitStatus: String?
    /// That event's top-level `resetsAt`: when a rejection lifts.
    public var rateLimitResetsAt: Date?
```

Replace the `rate_limit_event` arm in `foldClaude`:

```swift
        case "rate_limit_event":
            // Emitted on every call, mostly `allowed`; only a rejection is a limit worth showing.
            let info = obj["rate_limit_info"] as? [String: Any] ?? [:]
            if ClaudeRateLimitParser.isRejected(rateLimitInfo: info) { activity.rateLimitedAt = now() }
            let windows = ClaudeRateLimitParser.windows(rateLimitInfo: info)
            if !windows.isEmpty { activity.rateLimitWindows = windows }
            if let status = info["status"] as? String { activity.rateLimitStatus = status }
            if let resets = ClaudeRateLimitParser.resetsAt(rateLimitInfo: info) { activity.rateLimitResetsAt = resets }
```

Note the behavior change in the first line: the old arm treated a *missing* status as a
rejection (`"" .hasPrefix("allowed")` is false). `isRejected` treats it as no evidence. Run the
existing parser suite in Step 5 to confirm nothing relied on the old reading.

- [ ] **Step 5: Run to verify it passes, with the existing fold tests**

Run: `FD_TEST_FILTER=SeatActivityRateWindowTests,ActivityParserTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`. If an `ActivityParserTests` case feeds a
`rate_limit_event` with no status and expects `rateLimitedAt` set, that test encoded the old
accident: change its input to `"status":"rejected"` and say so in its comment — do not change the
new rule.

- [ ] **Step 6: Commit**

```bash
git add Sources/IntakeKit/SeatActivity.swift Tests/FlightDeckTests/FlightControlL3/Usage/SeatActivityRateWindowTests.swift
git commit -m "feat: keep claude's rate-limit windows on headless seat activity" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Pools and the headroom policy

**Files:**
- Create: `Sources/IntakeKit/FlightControl/PoolState.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/HeadroomPolicyTests.swift`

**Interfaces:**
- Consumes: L3-0 `PoolID`, `HarnessID`, `AccountRef`, `AccountHeadroom`, `HeadroomState`, `UsageWindow`, `UsageReading`; `L3Fixtures.usageTimeline()`.
- Produces (IntakeKit, `public`, `Sendable`):
  - `struct CapacityPool: Codable, Equatable, Identifiable { enum Kind: String { hosted, local }; static let defaultSoftThreshold = 0.80, defaultHardThreshold = 0.95, defaultConcurrencyCap = 2; id: PoolID; label: String; harness: HarnessID; kind: Kind; accounts: [UUID]; softThreshold: Double; hardThreshold: Double; endpoint: String?; concurrencyCap: Int; static func hosted(id:label:harness:accounts:soft:hard:) -> CapacityPool; static func local(id:label:harness:endpoint:cap:) -> CapacityPool; static func defaultID(for: HarnessID) -> PoolID; var isDefault: Bool; func validate() throws }`
  - `enum PoolValidationError: Error, Equatable { emptyLabel, thresholdOutOfRange(Double), thresholdsOutOfOrder(soft: Double, hard: Double), capBelowOne(Int) }`
  - `struct Rejection: Equatable { at: Date; until: Date?; source: String; var expiry: Date }`
  - `enum HeadroomPolicy { static let freshness: TimeInterval = 1800; static let rejectionBackoff: TimeInterval = 900; static func effectiveUtilization(of: UsageWindow, readAt: Date, now: Date) -> Double; static func isFresh(_: UsageReading, now: Date) -> Bool; static func evaluate(account: AccountRef, reading: UsageReading?, rejection: Rejection?, soft: Double, hard: Double, now: Date) -> AccountHeadroom }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The whole of "may this account take work" reduces to one pure function of a reading, a
/// rejection, two thresholds and the clock. These table-test it over the shared L3-0 timeline
/// and pin the time-based edges a live system hits and a fixture rarely does: staleness, a
/// window resetting under an idle tab, and two clocks that disagree.
final class HeadroomPolicyTests: XCTestCase {
    private let soft = 0.80, hard = 0.95

    private func evaluate(_ r: UsageReading?, rejection: Rejection? = nil, at now: Date) -> AccountHeadroom {
        HeadroomPolicy.evaluate(account: UsageRefs.work, reading: r, rejection: rejection, soft: soft, hard: hard, now: now)
    }

    func testTimelineReadingsCrossSoftThenHard() throws {
        let t = try L3Fixtures.usageTimeline()
        let states = t[0...2].map { evaluate($0, at: $0.readAt.addingTimeInterval(60)).state }
        XCTAssertEqual(states, [.underSoft, .overSoft, .overHard])
        XCTAssertEqual(evaluate(t[1], at: t[1].readAt).worstUtilization ?? 0, 0.82, accuracy: 1e-9)
        XCTAssertEqual(evaluate(t[2], at: t[2].readAt).resetsAt, usageISO("2026-10-04T23:00:00Z"))
        XCTAssertEqual(evaluate(t[4], at: t[4].readAt).state, .underSoft, "after the reset the account is open again")
    }

    func testNoReadingIsUnknownNotEmpty() {
        let h = evaluate(nil, at: Date())
        XCTAssertEqual(h.state, .unknown)
        XCTAssertNil(h.worstUtilization)
    }

    func testAReadingOlderThanThirtyMinutesIsUnknown() {
        let at = usageISO("2026-10-04T18:00:00Z")
        let r = UsageRefs.reading(UsageRefs.work, 0.5, at: at)
        XCTAssertEqual(evaluate(r, at: at.addingTimeInterval(30 * 60)).state, .underSoft, "exactly 30 minutes is still fresh")
        XCTAssertEqual(evaluate(r, at: at.addingTimeInterval(30 * 60 + 1)).state, .unknown)
    }

    func testAReadingWithNoWindowsIsUnknown() {
        let r = UsageReading(account: UsageRefs.work, windows: [], readAt: Date(), source: "t", hardRejection: false)
        XCTAssertEqual(evaluate(r, at: r.readAt).state, .unknown, "off a subscription claude reports no windows")
    }

    func testThresholdsAreInclusive() {
        let at = Date()
        XCTAssertEqual(evaluate(UsageRefs.reading(UsageRefs.work, 0.80, at: at), at: at).state, .overSoft)
        XCTAssertEqual(evaluate(UsageRefs.reading(UsageRefs.work, 0.95, at: at), at: at).state, .overHard)
        XCTAssertEqual(evaluate(UsageRefs.reading(UsageRefs.work, 0.7999, at: at), at: at).state, .underSoft)
    }

    func testAnActiveRejectionOverridesALowMeter() {
        let at = usageISO("2026-10-04T18:00:00Z")
        let h = evaluate(UsageRefs.reading(UsageRefs.work, 0.10, at: at),
                         rejection: Rejection(at: at, until: at.addingTimeInterval(600), source: "429"),
                         at: at.addingTimeInterval(60))
        XCTAssertEqual(h.state, .overHard)
        XCTAssertEqual(h.resetsAt, at.addingTimeInterval(600))
    }

    func testARejectionWithoutAnEndLastsFifteenMinutes() {
        let at = usageISO("2026-10-04T18:00:00Z")
        let rej = Rejection(at: at, until: nil, source: "apiError")
        XCTAssertEqual(rej.expiry, at.addingTimeInterval(15 * 60))
        XCTAssertEqual(evaluate(nil, rejection: rej, at: at.addingTimeInterval(14 * 60)).state, .overHard)
        XCTAssertEqual(evaluate(nil, rejection: rej, at: at.addingTimeInterval(15 * 60)).state, .unknown)
    }

    /// Review focus: a tab that went idle at 97 % writes no new reading. Without this the
    /// account would stay over hard until the reading went stale — or forever, for a reading
    /// refreshed by an idle tab's turn-end measure.
    func testWindowPastItsResetCountsAsEmptyWithoutANewReading() {
        let readAt = usageISO("2026-10-04T22:50:00Z")
        let r = UsageReading(account: UsageRefs.work,
                             windows: [UsageWindow(name: "five_hour", utilization: 0.97, resetsAt: usageISO("2026-10-04T23:00:00Z")),
                                       UsageWindow(name: "seven_day", utilization: 0.40, resetsAt: usageISO("2026-10-09T00:00:00Z"))],
                             readAt: readAt, source: "t", hardRejection: false)
        XCTAssertEqual(evaluate(r, at: usageISO("2026-10-04T22:59:00Z")).state, .overHard)
        let after = evaluate(r, at: usageISO("2026-10-04T23:05:00Z"))
        XCTAssertEqual(after.state, .underSoft)
        XCTAssertEqual(after.worstUtilization ?? 0, 0.40, accuracy: 1e-9, "the seven-day window is now the worst")
    }

    /// Review focus: the vendor's clock and the Mac's disagree. A reset time that had already
    /// passed when the reading was taken says nothing about a reset since — keep the number.
    func testResetAtOrBeforeReadAtIsClockSkewNotAReset() {
        let readAt = usageISO("2026-10-04T23:00:30Z")
        let r = UsageRefs.reading(UsageRefs.work, 0.97, at: readAt, resetsAt: usageISO("2026-10-04T23:00:00Z"))
        XCTAssertEqual(evaluate(r, at: readAt.addingTimeInterval(60)).state, .overHard)
        XCTAssertEqual(HeadroomPolicy.effectiveUtilization(of: r.windows[0], readAt: readAt, now: readAt.addingTimeInterval(60)), 0.97)
    }

    /// Review focus: a reading stamped a little ahead of this Mac's clock is fresh, and is not
    /// treated as a reset either.
    func testReadingStampedInTheFutureIsFresh() {
        let now = usageISO("2026-10-04T18:00:00Z")
        let r = UsageRefs.reading(UsageRefs.work, 0.85, at: now.addingTimeInterval(90), resetsAt: now.addingTimeInterval(30))
        XCTAssertTrue(HeadroomPolicy.isFresh(r, now: now))
        XCTAssertEqual(evaluate(r, at: now).state, .overSoft)
    }

    func testPoolConstructorsAndDefaults() throws {
        let p = CapacityPool.hosted(id: CapacityPool.defaultID(for: "claude"), label: "Claude default", harness: "claude", accounts: [UsageRefs.workID])
        XCTAssertEqual(p.id, "claude-default")
        XCTAssertTrue(p.isDefault)
        XCTAssertEqual(p.softThreshold, 0.80); XCTAssertEqual(p.hardThreshold, 0.95)
        let l = CapacityPool.local(id: "pool-local1", label: "Ollama", harness: "opencode", endpoint: "http://localhost:11434")
        XCTAssertEqual(l.concurrencyCap, 2); XCTAssertEqual(l.kind, .local); XCTAssertFalse(l.isDefault)
        XCTAssertNoThrow(try p.validate()); XCTAssertNoThrow(try l.validate())
        let data = try JSONEncoder().encode([p, l])
        XCTAssertEqual(try JSONDecoder().decode([CapacityPool].self, from: data), [p, l])
    }

    func testValidateNamesTheBadField() {
        var p = CapacityPool.hosted(id: "pool-a", label: "A", harness: "claude", accounts: [])
        p.softThreshold = 0.96
        XCTAssertThrowsError(try p.validate()) { XCTAssertEqual($0 as? PoolValidationError, .thresholdsOutOfOrder(soft: 0.96, hard: 0.95)) }
        p.softThreshold = 0.8; p.hardThreshold = 1.2
        XCTAssertThrowsError(try p.validate()) { XCTAssertEqual($0 as? PoolValidationError, .thresholdOutOfRange(1.2)) }
        var l = CapacityPool.local(id: "pool-b", label: "B", harness: "opencode", endpoint: "x")
        l.concurrencyCap = 0
        XCTAssertThrowsError(try l.validate()) { XCTAssertEqual($0 as? PoolValidationError, .capBelowOne(0)) }
        l.concurrencyCap = 1; l.label = " "
        XCTAssertThrowsError(try l.validate()) { XCTAssertEqual($0 as? PoolValidationError, .emptyLabel) }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=HeadroomPolicyTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'HeadroomPolicy' in scope`.

- [ ] **Step 3: Implement `PoolState.swift`**

```swift
import Foundation

/// A named group of capacity for one adapter (L3-U §2). Hosted pools are an ordered list of that
/// adapter's accounts; local pools are an endpoint with a concurrency cap and no account at all.
///
/// One flat struct rather than an enum with payloads, so a stored pool keeps decoding when a
/// later field is added and so the Settings editor can flip a draft between kinds without
/// losing what was typed.
public struct CapacityPool: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case hosted, local }

    public static let defaultSoftThreshold = 0.80
    public static let defaultHardThreshold = 0.95
    public static let defaultConcurrencyCap = 2

    /// Stable for the pool's life; renaming changes only `label`. Execution blocks store this.
    public var id: PoolID
    public var label: String
    public var harness: HarnessID
    public var kind: Kind
    /// Hosted: account ids, in lease order. Empty for a local pool.
    public var accounts: [UUID]
    public var softThreshold: Double
    public var hardThreshold: Double
    /// Local: where the provider listens (an Ollama URL, say). Display only — Flight Deck does
    /// not probe it.
    public var endpoint: String?
    public var concurrencyCap: Int

    public init(id: PoolID, label: String, harness: HarnessID, kind: Kind, accounts: [UUID],
                softThreshold: Double, hardThreshold: Double, endpoint: String?, concurrencyCap: Int) {
        self.id = id; self.label = label; self.harness = harness; self.kind = kind; self.accounts = accounts
        self.softThreshold = softThreshold; self.hardThreshold = hardThreshold
        self.endpoint = endpoint; self.concurrencyCap = concurrencyCap
    }

    public static func hosted(id: PoolID, label: String, harness: HarnessID, accounts: [UUID],
                              soft: Double = defaultSoftThreshold, hard: Double = defaultHardThreshold) -> CapacityPool {
        CapacityPool(id: id, label: label, harness: harness, kind: .hosted, accounts: accounts,
                     softThreshold: soft, hardThreshold: hard, endpoint: nil, concurrencyCap: defaultConcurrencyCap)
    }

    public static func local(id: PoolID, label: String, harness: HarnessID, endpoint: String,
                             cap: Int = defaultConcurrencyCap) -> CapacityPool {
        CapacityPool(id: id, label: label, harness: harness, kind: .local, accounts: [],
                     softThreshold: defaultSoftThreshold, hardThreshold: defaultHardThreshold,
                     endpoint: endpoint, concurrencyCap: cap)
    }

    /// `<adapter>-default`: the pool every adapter gets without asking (L3-U §2).
    public static func defaultID(for harness: HarnessID) -> PoolID { PoolID("\(harness.rawValue)-default") }

    public var isDefault: Bool { id == Self.defaultID(for: harness) }
}

public enum PoolValidationError: Error, Equatable, Sendable {
    case emptyLabel
    case thresholdOutOfRange(Double)
    case thresholdsOutOfOrder(soft: Double, hard: Double)
    case capBelowOne(Int)
}

extension CapacityPool {
    public func validate() throws {
        if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PoolValidationError.emptyLabel }
        switch kind {
        case .hosted:
            for t in [softThreshold, hardThreshold] where !(t > 0 && t <= 1) { throw PoolValidationError.thresholdOutOfRange(t) }
            if softThreshold >= hardThreshold { throw PoolValidationError.thresholdsOutOfOrder(soft: softThreshold, hard: hardThreshold) }
        case .local:
            if concurrencyCap < 1 { throw PoolValidationError.capBelowOne(concurrencyCap) }
        }
    }
}

/// A real refusal from the vendor: a 429, codex `rate_limit_exceeded`, a non-allowed
/// `rate_limit_event`, the fleet's rate-limit `apiError`. It overrides any meter (L3-U §3).
public struct Rejection: Equatable, Sendable {
    public var at: Date
    /// When the vendor said it lifts, if it said.
    public var until: Date?
    public var source: String
    public init(at: Date, until: Date?, source: String) { self.at = at; self.until = until; self.source = source }

    /// `until`, or the 15-minute backoff when the refusal named no time.
    public var expiry: Date { until ?? at.addingTimeInterval(HeadroomPolicy.rejectionBackoff) }
}

/// Reading + rejection + thresholds + clock → the account's state. Pure, so the ledger, the
/// popover and the tests all agree by construction.
public enum HeadroomPolicy {
    public static let freshness: TimeInterval = 30 * 60
    public static let rejectionBackoff: TimeInterval = 15 * 60

    /// A window whose reset time has passed since it was read is empty now: the vendor rolled it
    /// over and the idle tab that reported it will not say so. A reset time at or before the
    /// reading's own `readAt` is a disagreement between the vendor's clock and ours — the window
    /// cannot have reset *after* a reading that already saw it past — so the number stands.
    public static func effectiveUtilization(of window: UsageWindow, readAt: Date, now: Date) -> Double {
        guard let resets = window.resetsAt, resets <= now, resets > readAt else { return window.utilization }
        return 0
    }

    /// Age is clamped at zero: a reading stamped slightly in the future is simply new.
    public static func isFresh(_ reading: UsageReading, now: Date) -> Bool {
        max(0, now.timeIntervalSince(reading.readAt)) <= freshness
    }

    public static func evaluate(account: AccountRef, reading: UsageReading?, rejection: Rejection?,
                                soft: Double, hard: Double, now: Date) -> AccountHeadroom {
        if let rejection, now < rejection.expiry {
            return AccountHeadroom(account: account, worstUtilization: 1, state: .overHard, resetsAt: rejection.expiry)
        }
        let unknown = AccountHeadroom(account: account, worstUtilization: nil, state: .unknown, resetsAt: nil)
        guard let reading, isFresh(reading, now: now) else { return unknown }
        let scored = reading.windows.map { ($0, effectiveUtilization(of: $0, readAt: reading.readAt, now: now)) }
        guard let worst = scored.max(by: { $0.1 < $1.1 }) else { return unknown }
        let state: HeadroomState = worst.1 >= hard ? .overHard : worst.1 >= soft ? .overSoft : .underSoft
        return AccountHeadroom(account: account, worstUtilization: worst.1, state: state, resetsAt: worst.0.resetsAt)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `FD_TEST_FILTER=HeadroomPolicyTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/PoolState.swift Tests/FlightDeckTests/FlightControlL3/Usage/HeadroomPolicyTests.swift
git commit -m "feat: decide each account's headroom from its reading, rejection and thresholds" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: The lease policy and `CapacityLedger`

**Files:**
- Create: `Sources/IntakeKit/FlightControl/LeasePolicy.swift`
- Create: `Sources/IntakeKit/FlightControl/CapacityLedger.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/CapacityLedgerTests.swift`

**Interfaces:**
- Consumes: Task 5; L3-0 `CapacityReader`, `PoolAllocator`, `AccountLease`.
- Produces (IntakeKit, `public`):
  - `enum LeasePolicy { static func pick(_ headroom: [AccountHeadroom]) -> AccountRef? }`
  - `final class CapacityLedger: CapacityReader, PoolAllocator, @unchecked Sendable` with `init(now: @escaping @Sendable () -> Date = { Date() })`, `func configure(pools: [CapacityPool], accounts: [AccountRef])`, `var allPools: [CapacityPool]`, `func pool(_ id: PoolID) -> CapacityPool?`, `func ingest(_ reading: UsageReading)`, `func setSourceError(_ message: String?, account: UUID)`, `func sourceError(account: UUID) -> String?`, `func latestReading(account: UUID) -> UsageReading?`, `func rejection(account: UUID) -> Rejection?`, `func headroom(pool: PoolID) -> [AccountHeadroom]`, `func lease(pool: PoolID) -> AccountLease?`, `func release(_ lease: AccountLease)`, `func activeLeases(pool: PoolID) -> [AccountLease]`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The ledger is the real `CapacityReader` and `PoolAllocator`: everything L3-S asks about
/// capacity, and everything the hand-off driver leases, goes through it. These pin lease order,
/// the unknown fallback, rejections winning over meters and clearing again, local caps, and the
/// two review-focus cases a single-pool fixture never shows.
final class CapacityLedgerTests: XCTestCase {
    private var clock: UsageTestClock!
    private var ledger: CapacityLedger!
    private let pool = CapacityPool.hosted(id: "claude-default", label: "Claude default", harness: "claude",
                                           accounts: [UsageRefs.workID, UsageRefs.spareID])

    override func setUp() {
        clock = UsageTestClock()
        let c = clock!
        ledger = CapacityLedger(now: { c.now })
        ledger.configure(pools: [pool], accounts: [UsageRefs.work, UsageRefs.spare])
    }

    func testPickPrefersUnderSoftInOrderThenUnknown() {
        let a = AccountHeadroom(account: UsageRefs.work, worstUtilization: 0.9, state: .overSoft, resetsAt: nil)
        let b = AccountHeadroom(account: UsageRefs.spare, worstUtilization: nil, state: .unknown, resetsAt: nil)
        let c = AccountHeadroom(account: UsageRefs.codex, worstUtilization: 0.1, state: .underSoft, resetsAt: nil)
        XCTAssertEqual(LeasePolicy.pick([a, b, c]), UsageRefs.codex)
        XCTAssertEqual(LeasePolicy.pick([a, b]), UsageRefs.spare)
        XCTAssertNil(LeasePolicy.pick([a]))
    }

    func testUnknownAccountsLeaseInPoolOrder() {
        XCTAssertEqual(ledger.lease(pool: "claude-default")?.account, UsageRefs.work, "no readings yet: first unknown")
    }

    func testFirstUnderSoftAccountWinsOverAnEarlierUnknownOne() {
        ledger.ingest(UsageRefs.reading(UsageRefs.spare, 0.2, at: clock.now))
        XCTAssertEqual(ledger.lease(pool: "claude-default")?.account, UsageRefs.spare)
    }

    func testOverSoftTakesNoNewLease() {
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.85, at: clock.now))
        ledger.ingest(UsageRefs.reading(UsageRefs.spare, 0.90, at: clock.now))
        XCTAssertNil(ledger.lease(pool: "claude-default"))
        XCTAssertEqual(ledger.headroom(pool: "claude-default").map(\.state), [.overSoft, .overSoft])
    }

    func testAHardRejectionBeatsAFreshLowMeterAndClearsWithALaterBelowHardReading() {
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.10, at: clock.now))
        clock.advance(60)
        ledger.ingest(UsageReading(account: UsageRefs.work, windows: [], readAt: clock.now, source: "apiError", hardRejection: true))
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .overHard)
        XCTAssertEqual(ledger.latestReading(account: UsageRefs.workID)?.worstWindow?.utilization, 0.10,
                       "a rejection does not overwrite the meter the popover draws")

        clock.advance(60)
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.99, at: clock.now))
        XCTAssertNotNil(ledger.rejection(account: UsageRefs.workID), "a reading at or over hard does not lift a refusal")
        clock.advance(60)
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.30, at: clock.now))
        XCTAssertNil(ledger.rejection(account: UsageRefs.workID))
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .underSoft)
    }

    func testAReadingOlderThanTheRejectionDoesNotLiftIt() {
        let before = clock.now
        clock.advance(120)
        ledger.ingest(UsageReading(account: UsageRefs.work, windows: [], readAt: clock.now, source: "429", hardRejection: true))
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.10, at: before))
        XCTAssertNotNil(ledger.rejection(account: UsageRefs.workID))
    }

    func testARejectionCarryingAResetTimeEndsThen() {
        let until = clock.now.addingTimeInterval(300)
        ledger.ingest(UsageReading(account: UsageRefs.work, windows: [UsageWindow(name: "retry-after", utilization: 1, resetsAt: until)],
                                   readAt: clock.now, source: "429", hardRejection: true))
        XCTAssertEqual(ledger.rejection(account: UsageRefs.workID)?.until, until)
        clock.advance(299)
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .overHard)
        clock.advance(2)
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .unknown)
    }

    func testAnOutOfOrderReadingIsIgnored() {
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.5, at: clock.now))
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.99, at: clock.now.addingTimeInterval(-10)))
        XCTAssertEqual(ledger.latestReading(account: UsageRefs.workID)?.worstWindow?.utilization, 0.5)
    }

    func testTimelineFixtureDrivesLeasesThroughSoftHardAndReset() throws {
        let t = try L3Fixtures.usageTimeline()
        ledger.configure(pools: [CapacityPool.hosted(id: "solo", label: "Solo", harness: "claude", accounts: [UsageRefs.workID])],
                         accounts: [UsageRefs.work])
        var leased: [Bool] = []
        for r in t {
            clock.now = r.readAt.addingTimeInterval(30)
            ledger.ingest(r)
            if let l = ledger.lease(pool: "solo") { leased.append(true); ledger.release(l) } else { leased.append(false) }
        }
        XCTAssertEqual(leased, [true, false, false, false, true])
    }

    func testLocalPoolLeasesUpToItsCap() {
        let local = CapacityPool.local(id: "ollama", label: "Ollama", harness: "opencode", endpoint: "http://localhost:11434")
        ledger.configure(pools: [local], accounts: [])
        let a = ledger.lease(pool: "ollama"), b = ledger.lease(pool: "ollama")
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNil(a?.account.id, "a local slot has no account")
        XCTAssertNil(ledger.lease(pool: "ollama"), "cap 2")
        XCTAssertEqual(ledger.headroom(pool: "ollama").first?.state, .overHard)
        ledger.release(a!)
        XCTAssertNotNil(ledger.lease(pool: "ollama"))
        XCTAssertEqual(ledger.activeLeases(pool: "ollama").count, 2)
    }

    func testUnknownPoolHasNoHeadroomAndNoLease() {
        XCTAssertEqual(ledger.headroom(pool: "nope"), [])
        XCTAssertNil(ledger.lease(pool: "nope"))
    }

    func testSourceErrorIsClearedByTheNextReading() {
        ledger.setSourceError("Codex app-server: transportClosed", account: UsageRefs.workID)
        XCTAssertEqual(ledger.sourceError(account: UsageRefs.workID), "Codex app-server: transportClosed")
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.2, at: clock.now))
        XCTAssertNil(ledger.sourceError(account: UsageRefs.workID))
    }

    /// Review focus: the meter is per account, so two pools listing one account must agree on
    /// its reading; leases, though, are per pool, and releasing one must not free the other.
    func testTwoPoolsSharingAnAccountSeeOneReadingAndLeaseIndependently() {
        let strict = CapacityPool.hosted(id: "strict", label: "Strict", harness: "claude", accounts: [UsageRefs.workID], soft: 0.5, hard: 0.6)
        ledger.configure(pools: [pool, strict], accounts: [UsageRefs.work, UsageRefs.spare])
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.55, at: clock.now))
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.worstUtilization, 0.55)
        XCTAssertEqual(ledger.headroom(pool: "strict").first?.worstUtilization, 0.55)
        XCTAssertEqual(ledger.headroom(pool: "claude-default").first?.state, .underSoft)
        XCTAssertEqual(ledger.headroom(pool: "strict").first?.state, .overSoft, "each pool applies its own thresholds")

        let a = ledger.lease(pool: "claude-default")
        XCTAssertEqual(a?.account, UsageRefs.work)
        XCTAssertNil(ledger.lease(pool: "strict"))
        ledger.release(a!)
        XCTAssertEqual(ledger.activeLeases(pool: "claude-default"), [])
        XCTAssertEqual(ledger.activeLeases(pool: "strict"), [])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=CapacityLedgerTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'CapacityLedger' in scope`.

- [ ] **Step 3: Implement `LeasePolicy.swift`**

```swift
import Foundation

/// L3-U §4: the first account in pool order under soft; else the first unknown one (an idle
/// account has no reading, which is normal, and must still be usable); else nothing.
public enum LeasePolicy {
    public static func pick(_ headroom: [AccountHeadroom]) -> AccountRef? {
        headroom.first { $0.state == .underSoft }?.account
            ?? headroom.first { $0.state == .unknown }?.account
    }
}
```

- [ ] **Step 4: Implement `CapacityLedger.swift`**

```swift
import Foundation

/// The single owner of capacity state: pools, the newest meter reading and any standing
/// rejection per account, source errors, and active leases. It is the real `CapacityReader`
/// and `PoolAllocator` (L3-0); the app feeds it, L3-S and the hand-off driver read it.
///
/// A class behind a lock rather than a `@MainActor` app object because the contract protocols
/// are `Sendable` and non-isolated: a main-actor conformer would only satisfy them by
/// pretending. Every public method takes the lock once and does no I/O under it.
public final class CapacityLedger: CapacityReader, PoolAllocator, @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private var pools: [CapacityPool] = []
    private var refs: [UUID: AccountRef] = [:]
    private var meters: [UUID: UsageReading] = [:]
    private var rejections: [UUID: Rejection] = [:]
    private var errors: [UUID: String] = [:]
    private var active: [UUID: AccountLease] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    /// `accounts` includes tombstoned ones on purpose: a running tab on a removed account still
    /// reports, and its reading must land under the id it always had. Pools are what decide
    /// which accounts can be leased.
    public func configure(pools: [CapacityPool], accounts: [AccountRef]) {
        lock.withLock {
            self.pools = pools
            refs = Dictionary(accounts.compactMap { a in a.id.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        }
    }

    public var allPools: [CapacityPool] { lock.withLock { pools } }
    public func pool(_ id: PoolID) -> CapacityPool? { lock.withLock { pools.first { $0.id == id } } }

    public func ingest(_ reading: UsageReading) {
        guard let id = reading.account.id else { return }
        lock.withLock {
            if reading.hardRejection {
                rejections[id] = Rejection(at: reading.readAt, until: reading.worstWindow?.resetsAt, source: reading.source)
                return
            }
            if let current = meters[id], current.readAt > reading.readAt { return }
            meters[id] = reading
            errors[id] = nil
            // "The state clears … with the next reading that is below hard" (L3-U §3). Below the
            // strictest hard threshold of any pool holding the account, so lifting it in a lax
            // pool can never re-open it in a strict one. A reading with no windows is no
            // evidence that anything lifted.
            if let rejection = rejections[id], reading.readAt > rejection.at, !reading.windows.isEmpty {
                let t = now()
                let worst = reading.windows.map { HeadroomPolicy.effectiveUtilization(of: $0, readAt: reading.readAt, now: t) }.max() ?? 0
                if worst < strictestHard(for: id) { rejections[id] = nil }
            }
        }
    }

    public func setSourceError(_ message: String?, account: UUID) { lock.withLock { errors[account] = message } }
    public func sourceError(account: UUID) -> String? { lock.withLock { errors[account] } }
    public func latestReading(account: UUID) -> UsageReading? { lock.withLock { meters[account] } }
    public func rejection(account: UUID) -> Rejection? { lock.withLock { rejections[account] } }

    public func headroom(pool id: PoolID) -> [AccountHeadroom] {
        lock.withLock { pools.first { $0.id == id }.map(unlockedHeadroom) ?? [] }
    }

    public func lease(pool id: PoolID) -> AccountLease? {
        lock.withLock {
            guard let pool = pools.first(where: { $0.id == id }) else { return nil }
            let account: AccountRef?
            switch pool.kind {
            case .local:
                account = activeCount(id) < pool.concurrencyCap ? slot(pool) : nil
            case .hosted:
                account = LeasePolicy.pick(unlockedHeadroom(pool))
            }
            guard let account else { return nil }
            let lease = AccountLease(pool: id, account: account)
            active[lease.id] = lease
            return lease
        }
    }

    public func release(_ lease: AccountLease) { lock.withLock { _ = active.removeValue(forKey: lease.id) } }

    public func activeLeases(pool id: PoolID) -> [AccountLease] {
        lock.withLock { active.values.filter { $0.pool == id }.sorted { $0.id.uuidString < $1.id.uuidString } }
    }

    // MARK: - Under the lock

    private func unlockedHeadroom(_ pool: CapacityPool) -> [AccountHeadroom] {
        switch pool.kind {
        case .local:
            // A local pool's limit is concurrency, not quota: "full" is reported as over hard so
            // the popover and L3-S read it like any exhausted pool, but nothing is ever handed
            // off for it (`LedgerHandoffPlanner` skips slot leases).
            let used = activeCount(pool.id)
            return [AccountHeadroom(account: slot(pool), worstUtilization: Double(used) / Double(max(pool.concurrencyCap, 1)),
                                    state: used < pool.concurrencyCap ? .underSoft : .overHard, resetsAt: nil)]
        case .hosted:
            let t = now()
            return pool.accounts.compactMap { id in
                guard let ref = refs[id] else { return nil }
                return HeadroomPolicy.evaluate(account: ref, reading: meters[id], rejection: rejections[id],
                                               soft: pool.softThreshold, hard: pool.hardThreshold, now: t)
            }
        }
    }

    private func activeCount(_ pool: PoolID) -> Int { active.values.filter { $0.pool == pool }.count }
    private func slot(_ pool: CapacityPool) -> AccountRef { AccountRef(harness: pool.harness, id: nil, label: pool.label) }

    private func strictestHard(for account: UUID) -> Double {
        pools.filter { $0.kind == .hosted && $0.accounts.contains(account) }.map(\.hardThreshold).min()
            ?? CapacityPool.defaultHardThreshold
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=CapacityLedgerTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/IntakeKit/FlightControl/LeasePolicy.swift Sources/IntakeKit/FlightControl/CapacityLedger.swift Tests/FlightDeckTests/FlightControlL3/Usage/CapacityLedgerTests.swift
git commit -m "feat: lease accounts from pools by headroom through a capacity ledger" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The hand-off prompt and `LedgerHandoffPlanner`

**Files:**
- Create: `Sources/IntakeKit/FlightControl/HandoffPrompt.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/HandoffPromptTests.swift`

**Interfaces:**
- Consumes: L3-0 `HandoffRequest`, `TranscriptPointer`, `SwarmAgentSnapshot`, `HandoffPlanner`, `CapacityReader`.
- Produces: `public enum HandoffPrompt { static func render(_ request: HandoffRequest) -> String }`;
  `public final class LedgerHandoffPlanner: HandoffPlanner, @unchecked Sendable { init(reader: CapacityReader, transcript: @escaping @Sendable (SessionRef) -> TranscriptPointer?, reservedFiles: @escaping @Sendable (SwarmAgentSnapshot) -> [String]) }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The hand-off prompt is the only thing the new agent knows about the old one, and the planner
/// decides when there is a hand-off at all. These pin the spec's wording line by line (§5.5),
/// the missing-transcript fallback (§7), and that only a quota crossing — never a full local
/// pool or a renamed account — produces a request.
final class HandoffPromptTests: XCTestCase {
    private let task = TaskRef(id: "fd-3x9", project: URL(fileURLWithPath: "/p/proj"))
    private let block = ExecutionBlock(kind: "tests", harness: "claude", model: "opus", pool: "claude-default",
                                       source: AssignmentSource(by: .rule, reason: "r", at: Date(timeIntervalSince1970: 0)))

    private func request(transcript: TranscriptPointer?, files: [String]) -> HandoffRequest {
        HandoffRequest(task: task, block: block, oldAgent: "BlueLake", oldSession: SessionRef(id: UUID(), agentName: "BlueLake"),
                       transcript: transcript, reservedFiles: files, fromAccount: UsageRefs.work)
    }

    func testRendersEverySpecLineForAPathPointer() {
        let p = TranscriptPointer(locator: .path("/Users/n/.claude/projects/-p-proj/abc.jsonl"), format: "JSONL",
                                  howToRead: "Read the last 200 lines first.")
        XCTAssertEqual(HandoffPrompt.render(request(transcript: p, files: ["Sources/A.swift", "Sources/B.swift"])), """
        You are continuing task fd-3x9, started by BlueLake, which stopped because its account reached its usage limit.
        Its transcript is at /Users/n/.claude/projects/-p-proj/abc.jsonl (JSONL). Read it to understand what was done and decided.
        Read the last 200 lines first.
        Run `git status` and `git diff` before changing anything. The work may be half done.
        Re-reserve these files before editing: Sources/A.swift, Sources/B.swift.
        Then finish the task as described in `br show fd-3x9`.
        """)
    }

    func testACommandPointerSaysToRunIt() {
        let p = TranscriptPointer(locator: .command("opencode export ses_1"), format: "OpenCode session export, JSON", howToRead: "Read the messages array.")
        let text = HandoffPrompt.render(request(transcript: p, files: ["a"]))
        XCTAssertTrue(text.contains("Its transcript is available from `opencode export ses_1` (OpenCode session export, JSON). Read it to understand what was done and decided."))
    }

    func testAMissingTranscriptLeansOnGitAndTheTaskNotes() {
        let text = HandoffPrompt.render(request(transcript: nil, files: ["a"]))
        XCTAssertTrue(text.contains("Its transcript is not available. Lean on `git diff` and the task's notes in `br show fd-3x9` to understand what was done and decided."))
        XCTAssertFalse(text.contains("Its transcript is at"))
    }

    func testNoReservationsSaysToReserveRatherThanListingNothing() {
        let text = HandoffPrompt.render(request(transcript: nil, files: []))
        XCTAssertTrue(text.contains("It held no file reservations. Reserve the files you will edit with Agent Mail before you edit them."))
        XCTAssertFalse(text.contains("Re-reserve these files before editing: ."))
    }

    private func snapshot(lease: AccountLease?, task: TaskRef? = TaskRef(id: "fd-3x9", project: URL(fileURLWithPath: "/p/proj"))) -> SwarmAgentSnapshot {
        SwarmAgentSnapshot(session: SessionRef(id: UUID(), agentName: "BlueLake"), agentName: "BlueLake", block: block, lease: lease, task: task)
    }

    private func planner(_ reader: CapacityReader, files: [String] = ["Sources/A.swift"]) -> LedgerHandoffPlanner {
        let pointer = TranscriptPointer(locator: .path("/t.jsonl"), format: "JSONL", howToRead: "tail")
        return LedgerHandoffPlanner(reader: reader, transcript: { _ in pointer }, reservedFiles: { _ in files })
    }

    func testRequestOnlyWhenTheLeasedAccountIsOverHard() {
        let reader = FakeCapacityReader()
        let lease = AccountLease(pool: "claude-default", account: UsageRefs.work)
        reader.byPool["claude-default"] = [AccountHeadroom(account: UsageRefs.work, worstUtilization: 0.9, state: .overSoft, resetsAt: nil)]
        XCTAssertNil(planner(reader).request(for: snapshot(lease: lease)), "over soft takes no new work but keeps what it has")
        reader.byPool["claude-default"] = [AccountHeadroom(account: UsageRefs.work, worstUtilization: 0.97, state: .overHard, resetsAt: nil)]
        let r = planner(reader).request(for: snapshot(lease: lease))
        XCTAssertEqual(r?.fromAccount, UsageRefs.work)
        XCTAssertEqual(r?.reservedFiles, ["Sources/A.swift"])
        XCTAssertEqual(r?.transcript?.locator, .path("/t.jsonl"))
        XCTAssertEqual(r?.oldAgent, "BlueLake")
    }

    func testARenamedAccountStillMatchesItsLease() {
        let reader = FakeCapacityReader()
        var renamed = UsageRefs.work; renamed.label = "Work (renamed)"
        reader.byPool["claude-default"] = [AccountHeadroom(account: renamed, worstUtilization: 1, state: .overHard, resetsAt: nil)]
        XCTAssertNotNil(planner(reader).request(for: snapshot(lease: AccountLease(pool: "claude-default", account: UsageRefs.work))),
                        "matching on the label would strand an agent on an exhausted account after a rename")
    }

    func testNoRequestWithoutALeaseATaskOrForALocalSlot() {
        let reader = FakeCapacityReader()
        let slot = AccountRef(harness: "opencode", id: nil, label: "Ollama")
        reader.byPool["ollama"] = [AccountHeadroom(account: slot, worstUtilization: 1, state: .overHard, resetsAt: nil)]
        XCTAssertNil(planner(reader).request(for: snapshot(lease: AccountLease(pool: "ollama", account: slot))),
                     "a full local pool is concurrency, not quota: nothing to hand off")
        XCTAssertNil(planner(reader).request(for: snapshot(lease: nil)))
        reader.byPool["claude-default"] = [AccountHeadroom(account: UsageRefs.work, worstUtilization: 1, state: .overHard, resetsAt: nil)]
        XCTAssertNil(planner(reader).request(for: snapshot(lease: AccountLease(pool: "claude-default", account: UsageRefs.work), task: nil)))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=HandoffPromptTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'HandoffPrompt' in scope`.

- [ ] **Step 3: Implement `HandoffPrompt.swift`**

```swift
import Foundation

/// The first prompt a hand-off agent gets (L3-U §5.5). Nothing else is migrated: the new agent
/// learns what happened only from this text, the transcript it points at, and the repo — so
/// every line is an instruction it can act on.
public enum HandoffPrompt {
    public static func render(_ r: HandoffRequest) -> String {
        var lines = ["You are continuing task \(r.task.id), started by \(r.oldAgent), which stopped because its account reached its usage limit."]
        if let t = r.transcript {
            switch t.locator {
            case .path(let path):
                lines.append("Its transcript is at \(path) (\(t.format)). Read it to understand what was done and decided.")
            case .command(let command):
                lines.append("Its transcript is available from `\(command)` (\(t.format)). Read it to understand what was done and decided.")
            }
            if !t.howToRead.isEmpty { lines.append(t.howToRead) }
        } else {
            // §7: the hand-off still runs; the prompt says so and points at what is left.
            lines.append("Its transcript is not available. Lean on `git diff` and the task's notes in `br show \(r.task.id)` to understand what was done and decided.")
        }
        lines.append("Run `git status` and `git diff` before changing anything. The work may be half done.")
        if r.reservedFiles.isEmpty {
            lines.append("It held no file reservations. Reserve the files you will edit with Agent Mail before you edit them.")
        } else {
            lines.append("Re-reserve these files before editing: \(r.reservedFiles.joined(separator: ", ")).")
        }
        lines.append("Then finish the task as described in `br show \(r.task.id)`.")
        return lines.joined(separator: "\n")
    }
}

/// The real `HandoffPlanner` (L3-0): a swarm agent gets a request exactly when the account its
/// lease names is over hard in that lease's pool.
///
/// The transcript and reservation lookups are injected because both live app-side (adapter
/// capabilities, Agent Mail). They are `@Sendable` to satisfy the contract; the app's closures
/// hop with `MainActor.assumeIsolated`, which holds because the hand-off driver calls this from
/// the main actor.
public final class LedgerHandoffPlanner: HandoffPlanner, @unchecked Sendable {
    private let reader: CapacityReader
    private let transcript: @Sendable (SessionRef) -> TranscriptPointer?
    private let reservedFiles: @Sendable (SwarmAgentSnapshot) -> [String]

    public init(reader: CapacityReader,
                transcript: @escaping @Sendable (SessionRef) -> TranscriptPointer?,
                reservedFiles: @escaping @Sendable (SwarmAgentSnapshot) -> [String]) {
        self.reader = reader; self.transcript = transcript; self.reservedFiles = reservedFiles
    }

    public func request(for agent: SwarmAgentSnapshot) -> HandoffRequest? {
        // A slot lease (`id == nil`) is a local pool's concurrency, never quota.
        guard let lease = agent.lease, let accountID = lease.account.id, let task = agent.task else { return nil }
        // By id and harness, not the whole `AccountRef`: its label is display text and changes
        // on rename.
        let mine = reader.headroom(pool: lease.pool).first {
            $0.account.id == accountID && $0.account.harness == lease.account.harness
        }
        guard mine?.state == .overHard else { return nil }
        return HandoffRequest(task: task, block: agent.block, oldAgent: agent.agentName, oldSession: agent.session,
                              transcript: transcript(agent.session), reservedFiles: reservedFiles(agent),
                              fromAccount: lease.account)
    }
}
```

- [ ] **Step 4: Run to verify it passes, and the terminology guard (this file is scanned)**

Run: `FD_TEST_FILTER=HandoffPromptTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/IntakeKit/FlightControl/HandoffPrompt.swift Tests/FlightDeckTests/FlightControlL3/Usage/HandoffPromptTests.swift
git commit -m "feat: plan hand-offs from the ledger and write the hand-off prompt" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Capacity preferences and default pools

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Usage/CapacityPreferences.swift`
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift` (new optional field + init param)
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift` (accessors)
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/CapacityPreferencesTests.swift`

**Interfaces:**
- Consumes: Task 5 `CapacityPool`; Task 6 `CapacityLedger`; `AgentAccount`, `AgentID.harnessID` (L3-0).
- Produces:
  - `struct HandoffSettings: Equatable { var confirm: Bool; var deadline: TimeInterval }`
  - `struct CapacityPreferences: Codable, Equatable { var pools: [CapacityPool]?; var confirmHandoffs: Bool?; var handoffDeadlineSeconds: Int?; static let defaultDeadlineSeconds = 600; var handoffSettings: HandoffSettings; func effectivePools(accounts: [AgentAccount]) -> [CapacityPool]; static func accountRef(_ account: AgentAccount) -> AccountRef }`
  - `Preferences.capacity: CapacityPreferences?`
  - `PreferencesStore.capacity: CapacityPreferences` (read), `PreferencesStore.updateCapacity(_ edit: (inout CapacityPreferences) -> Void)`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Pools are the user's words for capacity, stored in preferences; the default pools are what
/// every user has without touching Settings. These pin that the defaults track the account list
/// the user already curates, that an edited pool keeps its order while new accounts still join,
/// that a removed account never reappears in a pool, and that an old preferences blob decodes.
@MainActor
final class CapacityPreferencesTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/fd-capacity-prefs", isDirectory: true)
    private lazy var work = AgentAccount(id: UsageRefs.workID, agent: .claude, displayName: "Work", home: home.appendingPathComponent("w"))
    private lazy var spare = AgentAccount(id: UsageRefs.spareID, agent: .claude, displayName: "Spare", home: home.appendingPathComponent("s"))
    private lazy var codex = AgentAccount(id: UsageRefs.codexID, agent: .codex, displayName: "Codex", home: home.appendingPathComponent("c"))

    func testDefaultPoolsHoldEachAgentsLiveAccountsInOrder() {
        let pools = CapacityPreferences().effectivePools(accounts: [work, codex, spare])
        XCTAssertEqual(pools.map(\.id), ["claude-default", "codex-default"])
        XCTAssertEqual(pools[0].accounts, [UsageRefs.workID, UsageRefs.spareID])
        XCTAssertEqual(pools[0].label, "Claude default")
        XCTAssertEqual(pools[0].harness, "claude")
        XCTAssertEqual(pools[0].softThreshold, 0.80)
        XCTAssertEqual(pools[0].hardThreshold, 0.95)
        XCTAssertEqual(pools[1].accounts, [UsageRefs.codexID])
    }

    func testAnAgentWithNoAccountsHasNoDefaultPool() {
        XCTAssertEqual(CapacityPreferences().effectivePools(accounts: [codex]).map(\.id), ["codex-default"])
    }

    func testAStoredDefaultPoolKeepsItsOrderAndGainsNewAccounts() {
        var stored = CapacityPool.hosted(id: "claude-default", label: "Claude default", harness: "claude", accounts: [UsageRefs.spareID, UsageRefs.workID])
        stored.softThreshold = 0.7
        let newcomer = AgentAccount(agent: .claude, displayName: "New", home: home.appendingPathComponent("n"))
        let pools = CapacityPreferences(pools: [stored]).effectivePools(accounts: [work, spare, newcomer])
        XCTAssertEqual(pools.first?.accounts, [UsageRefs.spareID, UsageRefs.workID, newcomer.id])
        XCTAssertEqual(pools.first?.softThreshold, 0.7)
    }

    func testUserPoolsFollowTheDefaultsAndDropDeletedAccounts() {
        let gone = UUID()
        let mine = CapacityPool.hosted(id: "pool-abc12345", label: "Night shift", harness: "claude", accounts: [gone, UsageRefs.spareID])
        let pools = CapacityPreferences(pools: [mine]).effectivePools(accounts: [work, spare])
        XCTAssertEqual(pools.map(\.id), ["claude-default", "pool-abc12345"])
        XCTAssertEqual(pools[1].accounts, [UsageRefs.spareID])
    }

    func testALocalPoolPassesThroughUntouched() {
        let local = CapacityPool.local(id: "pool-local001", label: "Ollama", harness: "opencode", endpoint: "http://localhost:11434")
        XCTAssertEqual(CapacityPreferences(pools: [local]).effectivePools(accounts: [work]).last, local)
    }

    func testHandoffSettingsDefaults() {
        XCTAssertEqual(CapacityPreferences().handoffSettings, HandoffSettings(confirm: false, deadline: 600))
        XCTAssertEqual(CapacityPreferences(confirmHandoffs: true, handoffDeadlineSeconds: 120).handoffSettings,
                       HandoffSettings(confirm: true, deadline: 120))
    }

    func testAnOldPreferencesBlobStillDecodes() throws {
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences())) as? [String: Any])
        old.removeValue(forKey: "capacity")
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.capacity)
    }

    func testPreferencesStoreRoundTripsAnEdit() {
        let store = PreferencesStore(persistence: nil)
        store.updateCapacity { $0.confirmHandoffs = true }
        XCTAssertEqual(store.capacity.confirmHandoffs, true)
        XCTAssertEqual(store.preferences.capacity?.confirmHandoffs, true)
    }

    /// Review focus: removing an account tombstones it while its tab runs. The running tab keeps
    /// reporting under the same id — so the ledger must record it — but no pool may lease it.
    func testTombstonedAccountIsMeteredButNeverLeased() {
        var removed = work
        removed.removedAt = Date()
        let accounts = [removed, spare]
        let ledger = CapacityLedger()
        ledger.configure(pools: CapacityPreferences().effectivePools(accounts: accounts),
                         accounts: accounts.map(CapacityPreferences.accountRef))
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.05, at: Date()))
        XCTAssertEqual(ledger.latestReading(account: UsageRefs.workID)?.worstWindow?.utilization, 0.05)
        XCTAssertEqual(ledger.pool("claude-default")?.accounts, [UsageRefs.spareID])
        XCTAssertEqual(ledger.lease(pool: "claude-default")?.account.id, UsageRefs.spareID,
                       "the removed account has the most headroom and must still never be chosen")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=CapacityPreferencesTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'CapacityPreferences' in scope`.

- [ ] **Step 3: Implement `CapacityPreferences.swift`**

```swift
import Foundation
import IntakeKit

/// What the hand-off driver reads on every tick, so a Settings change applies to the next
/// boundary without a restart.
struct HandoffSettings: Equatable {
    var confirm: Bool
    var deadline: TimeInterval
}

/// Settings → Capacity (L3-U §2, §6). Every field optional for the reason every later field of
/// `Preferences` is: a stored blob from before this existed must decode, and nil reads as the
/// default.
struct CapacityPreferences: Codable, Equatable {
    /// Only pools the user created or edited. The default pools are derived, so a user who never
    /// opens Settings has nothing stored and still gets one pool per agent that tracks the
    /// account list.
    var pools: [CapacityPool]?
    var confirmHandoffs: Bool?
    var handoffDeadlineSeconds: Int?

    static let defaultDeadlineSeconds = 600

    init(pools: [CapacityPool]? = nil, confirmHandoffs: Bool? = nil, handoffDeadlineSeconds: Int? = nil) {
        self.pools = pools
        self.confirmHandoffs = confirmHandoffs
        self.handoffDeadlineSeconds = handoffDeadlineSeconds
    }

    var handoffSettings: HandoffSettings {
        HandoffSettings(confirm: confirmHandoffs ?? false,
                        deadline: TimeInterval(handoffDeadlineSeconds ?? Self.defaultDeadlineSeconds))
    }

    static func accountRef(_ account: AgentAccount) -> AccountRef {
        AccountRef(harness: account.agent.harnessID, id: account.id, label: account.displayName)
    }

    /// The pools in force: one `<agent>-default` per agent with a live account, then the user's
    /// own pools in stored order.
    ///
    /// A stored default keeps the order the user gave it, but an account added since joins at
    /// the end — otherwise a new login would be invisible to Flight Control until someone
    /// remembered to edit a pool. Every hosted pool drops ids that are not live accounts: a
    /// tombstoned account's running tab still reports (see `CapacityLedger.configure`), but it
    /// must never be leased again.
    func effectivePools(accounts: [AgentAccount]) -> [CapacityPool] {
        let stored = pools ?? []
        let live = accounts.filter { !$0.isRemoved }
        let liveIDs = Set(live.map(\.id))
        var out: [CapacityPool] = []
        for agent in AgentID.allCases {
            let mine = live.filter { $0.agent == agent }.map(\.id)
            let id = CapacityPool.defaultID(for: agent.harnessID)
            if var pool = stored.first(where: { $0.id == id }) {
                pool.accounts = pool.accounts.filter { mine.contains($0) } + mine.filter { !pool.accounts.contains($0) }
                out.append(pool)
            } else if !mine.isEmpty {
                out.append(.hosted(id: id, label: "\(agent.displayName) default", harness: agent.harnessID, accounts: mine))
            }
        }
        for var pool in stored where !out.contains(where: { $0.id == pool.id }) {
            if pool.kind == .hosted { pool.accounts = pool.accounts.filter(liveIDs.contains) }
            out.append(pool)
        }
        return out
    }
}
```

- [ ] **Step 4: Add the field to `Preferences`**

In `Preferences`, after `var terminalFontSize: Float?` (and its doc comment):

```swift
    /// Flight Control's pools and hand-off settings (L3-U). Optional for exactly the reason
    /// `confirmations` is — see that property's comment. `nil` means "never configured": the
    /// default pools and hand-off settings.
    var capacity: CapacityPreferences?
```

In `init(…)`, change the last parameter line `terminalFontSize: Float? = nil` to:

```swift
        terminalFontSize: Float? = nil,
        capacity: CapacityPreferences? = nil
```

and after `self.terminalFontSize = terminalFontSize` add `self.capacity = capacity`.

- [ ] **Step 5: Add the store accessors**

In `PreferencesStore`, after `func account(id: UUID) -> AgentAccount?`:

```swift
    /// Settings → Capacity, defaults filled. A read, so callers never write a default back by
    /// accident and rewrite `preferences.v1` on a pure lookup.
    var capacity: CapacityPreferences { preferences.capacity ?? CapacityPreferences() }

    /// One edit, one write: `preferences`' `didSet` persists once per assignment.
    func updateCapacity(_ edit: (inout CapacityPreferences) -> Void) {
        var next = capacity
        edit(&next)
        preferences.capacity = next
    }
```

- [ ] **Step 6: Run to verify it passes, with the preferences suites**

Run: `FD_TEST_FILTER=CapacityPreferencesTests,PreferencesStoreTests,PreferencesTabTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`. (If `PreferencesStoreTests` does not exist under that
name, `rg -l "class PreferencesStore\w*Tests" Tests` and use the name it prints.)

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Usage/CapacityPreferences.swift Sources/FlightDeck/Preferences/Preferences.swift Sources/FlightDeck/Preferences/PreferencesStore.swift Tests/FlightDeckTests/FlightControlL3/Usage/CapacityPreferencesTests.swift
git commit -m "feat: store capacity pools in preferences with a default pool per agent" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Transcript pointers

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Usage/TranscriptPointers.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/TranscriptPointersTests.swift`

**Interfaces:**
- Consumes: `Session` (`pinnedConversationID`, `transcriptDirectory`, `transcriptPath`), `ClaudeSession.transcriptURL(sessionID:workingDirectory:projectsRoot:)`, L3-0 `TranscriptPointer`.
- Produces: `enum TranscriptPointers { static let claudeFormat, claudeHowToRead, codexFormat, codexHowToRead, openCodeFormat, openCodeHowToRead: String; static func claude(session: Session, projectsRoot: URL, exists: (String) -> Bool = …) -> TranscriptPointer?; static func codex(session: Session, exists: (String) -> Bool = …) -> TranscriptPointer?; static func openCode(sessionID: String, serverURL: URL?) -> TranscriptPointer }`

- [ ] **Step 1: Verify how the codebase already finds each transcript**

Run: `rg -n "static func transcriptURL|transcriptPath = binding.transcriptURL|var transcriptPath" Sources/FlightDeck/ClaudeSession.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/SessionModel.swift`
Expected: `ClaudeSession.transcriptURL(sessionID:workingDirectory:projectsRoot:)` (claude derives
`<projects root>/<encoded cwd>/<lowercased session id>.jsonl` from `transcriptDirectory`, which
follows the agent into worktrees) and `Session.transcriptPath` set from codex's
`AgentBinding.transcriptURL` (codex reports its rollout path). If either moved, use what `rg`
finds; the rule is "reuse the path the app already tails, never re-derive it".

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// A hand-off agent reads the old agent's transcript from wherever the old agent's account wrote
/// it. These pin that the pointer is the very file Flight Deck already tails for that tab — the
/// worktree-following directory for claude, the reported rollout for codex — and that a file
/// that is not on disk yields no pointer, so the prompt says "not available" instead of sending
/// the new agent to read nothing.
final class TranscriptPointersTests: XCTestCase {
    func testClaudePointsAtTheTailedTranscriptUnderTheAccountHome() throws {
        let conversation = UUID(uuidString: "8552ADC8-BBAE-48C2-9B86-29A5BECFA369")!
        var s = Session(title: "t", workingDirectory: "/p/proj", pinnedConversationID: conversation)
        s.transcriptDirectory = "/p/proj/.claude/worktrees/feat"
        let root = URL(fileURLWithPath: "/Users/n/.claude-work/projects", isDirectory: true)
        let p = try XCTUnwrap(TranscriptPointers.claude(session: s, projectsRoot: root, exists: { _ in true }))
        XCTAssertEqual(p.locator, .path("/Users/n/.claude-work/projects/-p-proj--claude-worktrees-feat/8552adc8-bbae-48c2-9b86-29a5becfa369.jsonl"))
        XCTAssertEqual(p.format, TranscriptPointers.claudeFormat)
        XCTAssertTrue(p.howToRead.contains("last 200 lines"))
    }

    func testClaudeWithNoFileOnDiskHasNoPointer() {
        let s = Session(title: "t", workingDirectory: "/p/proj")
        XCTAssertNil(TranscriptPointers.claude(session: s, projectsRoot: URL(fileURLWithPath: "/nope"), exists: { _ in false }))
    }

    func testCodexPointsAtTheReportedRollout() throws {
        let s = Session(title: "t", workingDirectory: "/p", agent: .codex, transcriptPath: "/Users/n/.codex/sessions/2026/10/04/rollout-x.jsonl")
        let p = try XCTUnwrap(TranscriptPointers.codex(session: s, exists: { _ in true }))
        XCTAssertEqual(p.locator, .path("/Users/n/.codex/sessions/2026/10/04/rollout-x.jsonl"))
        XCTAssertEqual(p.format, TranscriptPointers.codexFormat)
    }

    func testCodexWithoutAReportedPathHasNoPointer() {
        XCTAssertNil(TranscriptPointers.codex(session: Session(title: "t", workingDirectory: "/p", agent: .codex), exists: { _ in true }))
        XCTAssertNil(TranscriptPointers.codex(session: Session(title: "t", workingDirectory: "/p", agent: .codex, transcriptPath: "/gone.jsonl"),
                                              exists: { _ in false }))
    }

    func testOpenCodeIsACommand() {
        XCTAssertEqual(TranscriptPointers.openCode(sessionID: "ses_1", serverURL: nil).locator, .command("opencode export ses_1"))
        XCTAssertEqual(TranscriptPointers.openCode(sessionID: "ses_1", serverURL: URL(string: "http://127.0.0.1:4096")).locator,
                       .command("curl -s http://127.0.0.1:4096/session/ses_1/message"))
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=TranscriptPointersTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'TranscriptPointers' in scope`.

- [ ] **Step 4: Implement `TranscriptPointers.swift`**

```swift
import Foundation
import IntakeKit

/// Where a hand-off agent finds the old agent's transcript, and how to read it (L3-U §5).
///
/// Each pointer is the file Flight Deck itself already tails for that tab, never a re-derived
/// path: claude's follows `transcriptDirectory` into worktrees, codex's is the rollout codex
/// reported. All of them are on this Mac, so the new agent can read them whatever account it
/// runs on.
enum TranscriptPointers {
    static let claudeFormat = "Claude Code transcript, JSONL: one JSON record per line"
    static let claudeHowToRead = "Read the last 200 lines first (`tail -n 200`). Records with \"type\":\"user\" and \"type\":\"assistant\" hold the conversation; tool_use and tool_result blocks inside message.content show what was run and what it returned."
    static let codexFormat = "Codex rollout, JSONL: one {timestamp, type, payload} record per line"
    static let codexHowToRead = "Read the last 300 lines first (`tail -n 300`). response_item records hold the messages and tool calls; event_msg records hold tool output."
    static let openCodeFormat = "OpenCode session export, JSON"
    static let openCodeHowToRead = "Run the command and read its output; the last messages show where the work stopped."

    static func claude(session: Session, projectsRoot: URL,
                       exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> TranscriptPointer? {
        let url = ClaudeSession.transcriptURL(sessionID: session.pinnedConversationID,
                                              workingDirectory: session.transcriptDirectory,
                                              projectsRoot: projectsRoot)
        guard exists(url.path) else { return nil }
        return TranscriptPointer(locator: .path(url.path), format: claudeFormat, howToRead: claudeHowToRead)
    }

    static func codex(session: Session,
                      exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> TranscriptPointer? {
        guard let path = session.transcriptPath, exists(path) else { return nil }
        return TranscriptPointer(locator: .path(path), format: codexFormat, howToRead: codexHowToRead)
    }

    /// For the OpenCode adapter when it merges: `opencode export` against local storage, or the
    /// server's messages endpoint when the account runs its own server. Probe both against the
    /// OpenCode branch before relying on them.
    static func openCode(sessionID: String, serverURL: URL?) -> TranscriptPointer {
        let command = serverURL.map { "curl -s \($0.absoluteString)/session/\(sessionID)/message" } ?? "opencode export \(sessionID)"
        return TranscriptPointer(locator: .command(command), format: openCodeFormat, howToRead: openCodeHowToRead)
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=TranscriptPointersTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`. If the first test's expected directory name differs,
the encoding rule is `ClaudeSession.encodedProjectDirName`'s (every non-alphanumeric UTF-16 unit
→ `-`); recompute the literal from that rule rather than from the implementation's output.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Usage/TranscriptPointers.swift Tests/FlightDeckTests/FlightControlL3/Usage/TranscriptPointersTests.swift
git commit -m "feat: point hand-off agents at the transcript flight deck already tails" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: The claude usage mod

Follow the Outcome 1A steps unless Task 1 recorded Outcome 1B. If Task 1 STOPPED the
claude-interactive meter, do only the Swift half — Step 1 without
`testHooksManifestLoadsTheUsageModule`, Steps 2–3, 7 and 8 — because Task 13 compiles against
`ClaudePluginLocation.usageDirectory`; skip the mod files (Steps 4–6).

**Files:**
- Modify: `Resources/ClaudePlugin/hooks/hooks.json` (add `"modules"`)
- Create: `Resources/ClaudePlugin/hooks/register.ts`
- Create: `Resources/ClaudePlugin/tests/usage.test.ts`
- Modify: `Sources/FlightDeck/Agents/ClaudePluginLocation.swift` (`usageDirectory`)
- Modify: `Sources/FlightDeck/Agents/ClaudeAdapter.swift` (`launchEnvironment`)
- Modify: `Tests/FlightDeckTests/AgentAccountEnvironmentTests.swift`, `Tests/FlightDeckTests/ToolContextTests.swift` (the exact-environment assertions)
- Modify: `Tests/FlightDeckTests/ClaudePluginPayloadTests.swift` (the module is shipped)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the probe outcomes; `ModUsageFile` (Task 3) is the reader of what this writes.
- Produces: `ClaudePluginLocation.usageDirectory: URL`; claude tabs launch with
  `FLIGHT_DECK_USAGE_DIR`; the mod writes `<FLIGHT_DECK_USAGE_DIR>/<FLIGHT_DECK_SESSION_ID or claude session id>.json`
  in `ModUsageFile` v1 shape on every `session.measure` that carries windows.

- [ ] **Step 1: Write the failing Swift tests**

In `Tests/FlightDeckTests/AgentAccountEnvironmentTests.swift`, `testEachAgentNamesItsOwnVariable`:
after the `expectedEventDir` constant add

```swift
        let expectedUsageDir = base
            .appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("usage-debug", isDirectory: true)
            .path
```

and change the expected claude dictionary to

```swift
            [
                "CLAUDE_CONFIG_DIR": "/tmp/home",
                "FLIGHT_DECK_EVENT_DIR": expectedEventDir,
                "FLIGHT_DECK_USAGE_DIR": expectedUsageDir,
            ]
```

In `testTheAccountFreeLaunchEnvironmentCarriesOnlyClaudesHookDirectory` change the claude
expectation to

```swift
        XCTAssertEqual(ClaudeAdapter().launchEnvironment,
                       ["FLIGHT_DECK_EVENT_DIR": ClaudePluginLocation.eventDirectory.path,
                        "FLIGHT_DECK_USAGE_DIR": ClaudePluginLocation.usageDirectory.path])
```

and update the comment above it to say the account-free half carries claude's hook directory and
its usage directory (the mod writes there whether or not the tab has an account).

In `Tests/FlightDeckTests/ToolContextTests.swift`, beside `expectedEventDir`, add the same
`expectedUsageDir` literal and add `"FLIGHT_DECK_USAGE_DIR": expectedUsageDir,` to the expected
`accountEnvironment`.

In `Tests/FlightDeckTests/ClaudePluginPayloadTests.swift` add:

```swift
    /// The usage mod is data the engine loads, so nothing else would notice it went missing from
    /// the bundle until every claude account read "no reading" (Flight Control L3-U).
    func testHooksManifestLoadsTheUsageModule() throws {
        let root = try pluginRoot()
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("hooks/hooks.json"))) as? [String: Any])
        XCTAssertEqual(obj["modules"] as? [String], ["./register.ts"])
        let module = try String(contentsOf: root.appendingPathComponent("hooks/register.ts"), encoding: .utf8)
        XCTAssertTrue(module.contains("'session.measure'"))
        XCTAssertTrue(module.contains("'FLIGHT_DECK_USAGE_DIR'"))
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `FD_TEST_FILTER=AgentAccountEnvironmentTests,ToolContextTests,ClaudePluginPayloadTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `type 'ClaudePluginLocation' has no member 'usageDirectory'`.

- [ ] **Step 3: Add the usage directory and the variable**

In `ClaudePluginLocation`, after `eventDirectory`:

```swift
    /// Where the usage mod writes one file per tab (Flight Control L3-U). Beside the hook-event
    /// directory and split by build for the same reason: a debug build must never read the
    /// release fleet's meters as its own.
    static var usageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("usage-\(buildTag)", isDirectory: true)
    }
```

In `ClaudeAdapter.launchEnvironment`, replace the body with:

```swift
        let events = ClaudePluginLocation.eventDirectory
        try? FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        // The usage mod's directory rides the same account-free path, for the same reason: a tab
        // whose login was deleted still runs on *some* account and still has a meter.
        let usage = ClaudePluginLocation.usageDirectory
        try? FileManager.default.createDirectory(at: usage, withIntermediateDirectories: true)
        return ["FLIGHT_DECK_EVENT_DIR": events.path, "FLIGHT_DECK_USAGE_DIR": usage.path]
```

and add one sentence to its doc comment: "`FLIGHT_DECK_USAGE_DIR` is where the bundled usage
mod writes each tab's rate limits; without it the mod writes nothing."

- [ ] **Step 4: Write the mod (Outcome 1A)**

`Resources/ClaudePlugin/hooks/hooks.json` — keep every existing key and add `modules` (the
`hooks` block is unchanged):

```json
{
  "description": "Flight Deck lifecycle reporting. Every command quotes ${CLAUDE_PLUGIN_ROOT}: in production it expands to /Applications/Flight Deck.app/... and Claude Code runs hook commands through a shell, so unquoted it splits at the space and every hook dies with 127. See scripts/record.sh. The module is Flight Control's usage meter; see hooks/register.ts.",
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/record.sh\""}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/record.sh\""}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/record.sh\""}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/record.sh\""}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/record.sh\""}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/record.sh\""}]}]
  },
  "modules": ["./register.ts"]
}
```

`Resources/ClaudePlugin/hooks/register.ts` (if Task 1 recorded Outcome 4B, replace the
`$.fs.write` line with the recorded `$.process.run` form):

```ts
import type { Register } from 'claude-code'

// Flight Control's usage meter (L3-U). claude raises `session.measure` after each turn and
// whenever a rate-limit window moves a whole point; this writes the windows to one file per
// tab, which Flight Deck reads to decide which account takes new work and when a swarm agent
// must be handed off.
//
// The file is named by FLIGHT_DECK_SESSION_ID (the tab) when Flight Deck set it, else by
// claude's own session id, which Flight Deck maps through the tab's pinned conversation.
// The mod never learns which account it runs on: Flight Deck knows that from the tab.
//
// No FLIGHT_DECK_USAGE_DIR means no Flight Deck (someone running claude with this plugin by
// hand): write nothing. A write that fails must never cost the session anything, so every path
// ends in next(e) — Flight Deck shows the account as "no reading" instead.
export const register: Register = (on) => {
  on('session.measure', async ($, e, next) => {
    if (e.rateLimits.length > 0) {
      try {
        const dir = await $.env.get('FLIGHT_DECK_USAGE_DIR')
        if (dir) {
          const tab = await $.env.get('FLIGHT_DECK_SESSION_ID')
          const session = await $.session.id()
          const readAt = new Date(await $.clock.now()).toISOString()
          const rateLimits = e.rateLimits.map((w) => ({ kind: w.kind, percentUsed: w.percentUsed, resetsAt: w.resetsAt ?? null }))
          const name = tab && tab.length > 0 ? tab : session
          await $.fs.write(`${dir}/${name}.json`, JSON.stringify({ v: 1, tab: tab ?? null, session, readAt, rateLimits }))
        }
      } catch {
        // Deliberately swallowed; see the header.
      }
    }
    return next(e)
  })
}
```

`Resources/ClaudePlugin/tests/usage.test.ts`:

```ts
import { test, expect, mock } from 'claude-code/testing'
import type { On, SessionMeasureInput } from 'claude-code'

const measure: SessionMeasureInput = {
  context: { window: 200000 },
  rateLimits: [
    { kind: 'five_hour', percentUsed: 82.5, resetsAt: '2026-10-04T23:00:00.000Z' },
    { kind: 'seven_day', percentUsed: 31 },
  ],
  changed: ['rateLimits'],
}

type Write = { path: string; text: string }

// Hooks registered on the test's `on` sit beneath the plugin and stand for the engine: the
// fs.write one records instead of touching disk, the session.measure one is the chain's end.
function engine(on: On, writes: Write[]) {
  on('fs.write', (_$, e) => { writes.push({ path: e.path, text: e.text }) })
  on('session.measure', (_$, e) => ({ changed: e.changed }))
}

test('writes the windows to the tab file', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, { FLIGHT_DECK_USAGE_DIR: '/fd/usage', FLIGHT_DECK_SESSION_ID: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE' })
  mock.clock(on, { now: Date.parse('2026-10-04T19:00:00.000Z') })
  engine(on, writes)
  const result = await $.session.measure(measure)
  expect(result.changed).toEqual(['rateLimits'])
  expect(writes.length).toBe(1)
  expect(writes[0].path).toBe('/fd/usage/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE.json')
  const body = JSON.parse(writes[0].text)
  expect(body.v).toBe(1)
  expect(body.tab).toBe('AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE')
  expect(body.readAt).toBe('2026-10-04T19:00:00.000Z')
  expect(body.rateLimits).toEqual([
    { kind: 'five_hour', percentUsed: 82.5, resetsAt: '2026-10-04T23:00:00.000Z' },
    { kind: 'seven_day', percentUsed: 31, resetsAt: null },
  ])
})

test('falls back to the claude session id without a tab id', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, { FLIGHT_DECK_USAGE_DIR: '/fd/usage' })
  engine(on, writes)
  await $.session.measure(measure)
  expect(writes[0].path).toBe(`/fd/usage/${await $.session.id()}.json`)
  expect(JSON.parse(writes[0].text).tab).toBe(null)
})

test('writes nothing outside Flight Deck', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, {})
  engine(on, writes)
  await $.session.measure(measure)
  expect(writes.length).toBe(0)
})

test('writes nothing off a subscription', async ($, on) => {
  const writes: Write[] = []
  mock.env(on, { FLIGHT_DECK_USAGE_DIR: '/fd/usage', FLIGHT_DECK_SESSION_ID: 'T' })
  engine(on, writes)
  await $.session.measure({ ...measure, rateLimits: [] })
  expect(writes.length).toBe(0)
})

test('a failing write never breaks the chain', async ($, on) => {
  mock.env(on, { FLIGHT_DECK_USAGE_DIR: '/fd/usage', FLIGHT_DECK_SESSION_ID: 'T' })
  on('fs.write', () => { throw new Error('EACCES') })
  on('session.measure', (_$, e) => ({ changed: e.changed }))
  const result = await $.session.measure(measure)
  expect(result.changed).toEqual(['rateLimits'])
})
```

`On` is the registrar type the testing module itself imports from `'claude-code'`
(`rg -n "import type \{ On \}" "$TYPES"`), so the helper's two registrations are typed per
event.

- [ ] **Step 4b (Outcome 1B only): ship the mod as a second plugin instead**

Leave `Resources/ClaudePlugin/hooks/hooks.json` unchanged. Create
`Resources/ClaudeUsagePlugin/.claude-plugin/plugin.json`
(`{"name": "flight-deck-usage", "version": "1.0.0", "description": "Reports rate-limit windows to Flight Deck."}`),
`Resources/ClaudeUsagePlugin/hooks/hooks.json` (`{"modules": ["./register.ts"]}`), and move
`register.ts` and `tests/usage.test.ts` under `Resources/ClaudeUsagePlugin/`. Add the folder to
`project.yml` beside `Resources/ClaudePlugin` in **both** the app target's and the test target's
resources (same `type: folder`, `buildPhase: resources` shape). In `ClaudePluginLocation` add:

```swift
    /// Outcome 1B (probe 1): claude would not take shell hooks and a module from one
    /// `hooks.json`, so the usage mod ships as its own plugin folder.
    static func usageDirectory(bundle: Bundle) -> URL? {
        guard let url = bundle.url(forResource: "ClaudeUsagePlugin", withExtension: nil),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("hooks/hooks.json").path)
        else { return nil }
        return url
    }
```

and in `applying(to:bundle:)` inject it after the main plugin:
`var flags = injecting(into: flags, pluginDirectory: plugin)` then
`if let mod = usageDirectory(bundle: bundle) { flags = injecting(into: flags, pluginDirectory: mod) }`
and return `.claude(flags)`. Change the payload test in Step 1 to read
`ClaudeUsagePlugin/hooks/hooks.json` (resource name `ClaudeUsagePlugin`). Run Step 6 against
`Resources/ClaudeUsagePlugin`.

- [ ] **Step 5: Validate and test the mod**

Run: `claude plugin validate Resources/ClaudePlugin`
Expected: passes; lists the six command hooks, a `session.measure` function hook, and env names
`FLIGHT_DECK_USAGE_DIR` and `FLIGHT_DECK_SESSION_ID`.

Run: `env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE claude plugin test Resources/ClaudePlugin`
Expected: 5 passed. A failure caused by an API shape (an argument name in `mock.env`, a field of
`SessionMeasureInput`) is fixed by reading the installed types
(`rg -n "env: \(on: On|export type SessionMeasureInput" "$TYPES"`) and correcting the test's
call — never by dropping an assertion.

- [ ] **Step 6: Ignore what the engine lays into the plugin folder**

Append to `.gitignore`:

```
# Claude lays its mod type declarations into a plugin folder whenever it loads or tests one
# ("regenerate rather than edit"). Never commit them; the installed claude is the authority.
Resources/ClaudePlugin/.claude-plugin/types/
Resources/ClaudeUsagePlugin/.claude-plugin/types/
```

Run: `git status --short Resources/` — expected: only the files this task created or changed.

- [ ] **Step 7: Run the Swift tests to verify they pass**

Run: `FD_TEST_FILTER=AgentAccountEnvironmentTests,ToolContextTests,ClaudePluginPayloadTests,AccountLaunchTests,ControlLaunchEnvironmentTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 8: Commit**

```bash
git add Resources/ClaudePlugin/hooks/hooks.json Resources/ClaudePlugin/hooks/register.ts Resources/ClaudePlugin/tests/usage.test.ts Sources/FlightDeck/Agents/ClaudePluginLocation.swift Sources/FlightDeck/Agents/ClaudeAdapter.swift Tests/FlightDeckTests/AgentAccountEnvironmentTests.swift Tests/FlightDeckTests/ToolContextTests.swift Tests/FlightDeckTests/ClaudePluginPayloadTests.swift .gitignore
git commit -m "feat: report each claude tab's rate-limit windows through a bundled mod" -m "session.measure fires after each turn and when a window moves a whole point. The mod writes the windows to FLIGHT_DECK_USAGE_DIR/<tab>.json; Flight Deck maps the tab to its account. Probe results are in the spec's follow-up notes." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

(For Outcome 1B, add `Resources/ClaudeUsagePlugin` and `project.yml` instead of the
`Resources/ClaudePlugin/hooks/register.ts` and `tests/usage.test.ts` paths.)

---

### Task 11: The codex meter source

**Files:**
- Modify: `Sources/FlightDeck/Agents/Codex/CodexRPC.swift` (`onNotification`)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`onCodexNotification`, `codexRateLimitsRead(account:)`, hook in `makeCodexStackIfNeeded`)
- Create: `Sources/FlightDeck/FlightControl/Usage/CodexRateLimitSource.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/CodexRateLimitSourceTests.swift`

**Interfaces:**
- Consumes: `CodexRateLimitParser` (Task 3); `CodexRPC`, `CodexTransport`; `SessionStore.codexStacks`/`codexHandshake` (private, so the accessor lives in `SessionStore.swift`).
- Produces:
  - `CodexRPC.onNotification: (@MainActor (String, [String: Any]) -> Void)?` — `@MainActor` like the class that calls it, so a listener may touch main-actor state directly
  - `SessionStore.onCodexNotification: (@MainActor (UUID?, String, [String: Any]) -> Void)?`
  - `SessionStore.codexRateLimitsRead(account: UUID?) async throws -> [String: Any]?` — nil when no app-server runs for the account; never spawns one.
  - `@MainActor final class CodexRateLimitSource { private(set) var buckets: [String: CodexRateBucket]; func applyRead(_ result: [String: Any]); func applyUpdate(_ params: [String: Any]); func reading(account: AccountRef, at: Date) -> UsageReading? }`

- [ ] **Step 1: Verify the codex plumbing is as this plan assumes**

Run: `rg -n "private var codexStacks|private var codexHandshake|let rpc: CodexRPC|codexStacks\[account\] = stack|Anything left is a notification" Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/Agents/Codex/CodexRPC.swift`
Expected: five hits — `codexStacks: [UUID?: CodexStack]`, `codexHandshake: [UUID?: Task<Void, Error>]`,
`CodexStack.rpc`, the memoizing assignment in `makeCodexStackIfNeeded`, and the comment in
`CodexRPC.receive` that says notifications are dropped. If the handshake is no longer a
`Task<Void, Error>`, `codexRateLimitsRead` awaits whatever "handshake completed" signal replaced it.

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// codex reports rate limits two ways: a read Flight Deck asks for, and pushes it is sent only
/// for turns its own connection runs. These pin that pushes now reach a listener instead of
/// being dropped, that a server *request* is not mistaken for one, and that the per-account
/// source turns either into one reading.
@MainActor
final class CodexRateLimitSourceTests: XCTestCase {
    private final class SilentTransport: CodexTransport {
        var onLine: ((String) -> Void)?
        func send(_ line: String) {}
    }

    func testNotificationsReachTheHook() {
        let transport = SilentTransport()
        let rpc = CodexRPC(transport: transport)
        var got: [(String, [String: Any])] = []
        rpc.onNotification = { got.append(($0, $1)) }
        transport.onLine?(#"{"jsonrpc":"2.0","method":"account/rateLimits/updated","params":{"rateLimits":{"limitId":"codex"}}}"#)
        XCTAssertEqual(got.map(\.0), ["account/rateLimits/updated"])
        XCTAssertEqual((got.first?.1["rateLimits"] as? [String: Any])?["limitId"] as? String, "codex")
    }

    func testServerRequestsAndStrayRepliesAreNotNotifications() {
        let transport = SilentTransport()
        let rpc = CodexRPC(transport: transport)
        var got: [String] = []
        rpc.onNotification = { method, _ in got.append(method) }
        transport.onLine?(#"{"jsonrpc":"2.0","id":7,"method":"item/commandExecution/requestApproval","params":{}}"#)
        transport.onLine?(#"{"jsonrpc":"2.0","id":99,"result":{}}"#)
        transport.onLine?("codex banner, not JSON")
        XCTAssertEqual(got, [])
    }

    func testNoAppServerMeansNoReadAndNoSpawn() async throws {
        let store = SessionStore(provider: nil, persistence: nil)
        let result = try await store.codexRateLimitsRead(account: nil)
        XCTAssertNil(result)
        XCTAssertFalse(store.hasCodexStackForTesting, "asking for a meter must never start codex")
    }

    func testReadThenSparseUpdateMakeOneReading() throws {
        let source = CodexRateLimitSource()
        let at = usageISO("2026-10-04T18:00:00Z")
        XCTAssertNil(source.reading(account: UsageRefs.codex, at: at), "nothing read yet")
        source.applyRead(try UsageFixtures.object("codex-rate-limits-read"))
        XCTAssertEqual(source.reading(account: UsageRefs.codex, at: at)?.worstWindow?.utilization ?? 0, 0.88, accuracy: 1e-9)
        source.applyUpdate(try UsageFixtures.object("codex-rate-limits-updated"))
        let r = try XCTUnwrap(source.reading(account: UsageRefs.codex, at: at))
        XCTAssertEqual(r.worstWindow?.utilization ?? 0, 0.96, accuracy: 1e-9)
        XCTAssertEqual(r.account, UsageRefs.codex)
        XCTAssertEqual(r.readAt, at)
    }

    func testAnEmptyReadKeepsTheLastBuckets() throws {
        let source = CodexRateLimitSource()
        source.applyRead(try UsageFixtures.object("codex-rate-limits-read"))
        source.applyRead([:])
        XCTAssertEqual(source.buckets.count, 2, "an empty answer is not evidence the limits vanished")
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=CodexRateLimitSourceTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `value of type 'CodexRPC' has no member 'onNotification'`.

- [ ] **Step 4: Add `CodexRPC.onNotification`**

After `private var pending: …` add:

```swift
    /// Notifications (a `method` and no `id`), for whoever wants them. Flight Control's usage
    /// meter reads `account/rateLimits/updated` (L3-U). Nil drops them, which is what every
    /// other caller has always relied on.
    var onNotification: (@MainActor (String, [String: Any]) -> Void)?
```

In `receive`, replace the trailing comment block that begins `// Anything left is a
notification:` with:

```swift
        // Anything left without an `id` is a notification. Codex sends these regardless of
        // whether anyone is listening; `CodexRuntime` deliberately does not (they describe only
        // this connection's turns, not what the user does in a `codex resume` TUI). A message
        // with both `id` and `method` is a server *request* — not ours to answer here.
        if obj["id"] == nil, let method = obj["method"] as? String {
            onNotification?(method, obj["params"] as? [String: Any] ?? [:])
        }
```

- [ ] **Step 5: Add the store hooks**

In `SessionStore`, after `private var codexHandshake: …`:

```swift
    /// Every codex app-server notification, with the account its server answers for. Flight
    /// Control's usage meter reads `account/rateLimits/updated` here (L3-U); with no listener
    /// they are dropped, as they always were.
    var onCodexNotification: (@MainActor (UUID?, String, [String: Any]) -> Void)?
```

In `makeCodexStackIfNeeded(account:)`, immediately before `codexStacks[account] = stack`:

```swift
        stack.rpc.onNotification = { [weak self] method, params in
            self?.onCodexNotification?(account, method, params)
        }
```

After `makeCodexStackIfNeeded`, add:

```swift
    /// This account's codex rate limits, asked of the app-server Flight Deck already runs for it
    /// (L3-U). Nil when none is running: a meter must never spawn `codex app-server` — the stack
    /// exists only while the account has a codex tab, which is exactly when its meter matters.
    func codexRateLimitsRead(account: UUID?) async throws -> [String: Any]? {
        guard let stack = codexStacks[account], let handshake = codexHandshake[account] else { return nil }
        try await handshake.value
        return try await stack.rpc.request("account/rateLimits/read", [:])
    }
```

(`[:]` omits `params`, which is what the schema's `Account/rateLimits/readRequest` declares:
`"params": {"type": "null"}`.)

- [ ] **Step 6: Implement `CodexRateLimitSource.swift`**

```swift
import Foundation
import IntakeKit

/// One codex account's rate-limit buckets: the last `account/rateLimits/read`, with any
/// `account/rateLimits/updated` pushes merged in. One per account because a `CODEX_HOME` — and
/// so its app-server — answers for exactly one login.
@MainActor
final class CodexRateLimitSource {
    private(set) var buckets: [String: CodexRateBucket] = [:]

    /// An empty answer keeps what was known: it is not evidence the limits went away, and an
    /// account flipping to "no reading" between polls would make the popover flicker.
    func applyRead(_ result: [String: Any]) {
        let parsed = CodexRateLimitParser.readResponse(result)
        if !parsed.isEmpty { buckets = parsed }
    }

    func applyUpdate(_ params: [String: Any]) {
        buckets = CodexRateLimitParser.merge(update: params, into: buckets)
    }

    func reading(account: AccountRef, at: Date) -> UsageReading? {
        CodexRateLimitParser.reading(buckets, account: account, readAt: at)
    }
}
```

- [ ] **Step 7: Run to verify it passes, with the codex suites it touches**

Run: `FD_TEST_FILTER=CodexRateLimitSourceTests,CodexLaunchFailureTests,CodexResumeTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/Agents/Codex/CodexRPC.swift Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/FlightControl/Usage/CodexRateLimitSource.swift Tests/FlightDeckTests/FlightControlL3/Usage/CodexRateLimitSourceTests.swift
git commit -m "feat: read codex rate limits from the account's running app-server" -m "Adds account/rateLimits/read on the existing per-account app-server (never spawning one) and forwards app-server notifications, which were dropped, so account/rateLimits/updated reaches the usage meter." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: The claude-mod, headless-seat and OpenCode sources

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Usage/ClaudeModUsageSource.swift`
- Create: `Sources/FlightDeck/FlightControl/Usage/HeadlessClaudeUsageSource.swift`
- Create: `Sources/FlightDeck/FlightControl/Usage/OpenCodeErrorUsageSource.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/UsageSourcesTests.swift`

**Interfaces:**
- Consumes: `ModUsageFile`, `OpenCodeRateLimit`, `OpenCodeAPIErrorEvent` (Task 3); `SeatActivity.rateLimit*` (Task 4).
- Produces:
  - `@MainActor final class ClaudeModUsageSource { let directory: URL; init(directory: URL); func scan() -> [(stem: UUID, file: ModUsageFile)]; func prune(olderThan: TimeInterval, now: Date) }`
  - `@MainActor final class HeadlessClaudeUsageSource { func readings(from: [SeatActivity], account: AccountRef) -> [UsageReading] }`
  - `final class OpenCodeErrorUsageSource: UsageMeterSource, @unchecked Sendable { let readings: AsyncStream<UsageReading>; @discardableResult func ingest(_ event: OpenCodeAPIErrorEvent, account: AccountRef) -> UsageReading?; func finish() }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Three sources with three failure shapes: a directory another process writes into (torn
/// writes, stale files, foreign names), seat activity that repeats the same numbers on every
/// tick, and an error stream with no meter at all. These pin that each yields a reading once
/// per real change and never a half-read one.
@MainActor
final class UsageSourcesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ data: Data, mtime: Date) throws {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    func testScanYieldsEachFileOncePerChange() throws {
        let tab = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let fixture = try UsageFixtures.data("claude-mod-usage")
        try write("\(tab.uuidString).json", fixture, mtime: Date(timeIntervalSince1970: 1_000))
        let source = ClaudeModUsageSource(directory: dir)
        let first = source.scan()
        XCTAssertEqual(first.map(\.stem), [tab])
        XCTAssertEqual(first.first?.file.windows.first?.name, "five_hour")
        XCTAssertTrue(source.scan().isEmpty, "unchanged since the last scan")
        try write("\(tab.uuidString).json", fixture, mtime: Date(timeIntervalSince1970: 1_001))
        XCTAssertEqual(source.scan().count, 1)
    }

    func testATornWriteIsRetriedNotSkipped() throws {
        let tab = UUID()
        try write("\(tab.uuidString).json", Data(#"{"v":1,"readAt":"2026-10-04T19:00:00.000Z","rateLim"#.utf8), mtime: Date(timeIntervalSince1970: 1_000))
        let source = ClaudeModUsageSource(directory: dir)
        XCTAssertTrue(source.scan().isEmpty)
        try write("\(tab.uuidString).json", try UsageFixtures.data("claude-mod-usage"), mtime: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(source.scan().count, 1, "same mtime, but the torn read was never recorded as seen")
    }

    func testAClaudeSessionIDNamedFileScansAndForeignNamesDoNot() throws {
        try write("8552adc8-bbae-48c2-9b86-29a5becfa369.json", try UsageFixtures.data("claude-mod-usage"), mtime: Date())
        try write("notes.json", Data("{}".utf8), mtime: Date())
        try write("\(UUID().uuidString).tmp", Data("{}".utf8), mtime: Date())
        XCTAssertEqual(ClaudeModUsageSource(directory: dir).scan().map(\.stem), [UUID(uuidString: "8552ADC8-BBAE-48C2-9B86-29A5BECFA369")!])
    }

    func testAMissingDirectoryIsEmptyNotAnError() {
        XCTAssertTrue(ClaudeModUsageSource(directory: dir.appendingPathComponent("nope")).scan().isEmpty)
    }

    func testPruneRemovesOnlyOldFiles() throws {
        let now = Date(timeIntervalSince1970: 10_000_000)
        try write("old.json", Data("{}".utf8), mtime: now.addingTimeInterval(-8 * 86_400))
        try write("new.json", Data("{}".utf8), mtime: now.addingTimeInterval(-60))
        ClaudeModUsageSource(directory: dir).prune(olderThan: 7 * 86_400, now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["new.json"])
    }

    private func seat(windows: [UsageWindow]?, status: String?, resets: Date? = nil, last: Date, harness: Harness = .claude) -> SeatActivity {
        var a = SeatActivity(harness: harness, startedAt: Date(timeIntervalSince1970: 0))
        a.rateLimitWindows = windows; a.rateLimitStatus = status; a.rateLimitResetsAt = resets; a.lastEventAt = last
        return a
    }

    func testHeadlessSeatsYieldAReadingPerNewEvent() {
        let source = HeadlessClaudeUsageSource()
        let w = [UsageWindow(name: "five_hour", utilization: 0.4, resetsAt: nil)]
        let a = seat(windows: w, status: "allowed", last: Date(timeIntervalSince1970: 100))
        let first = source.readings(from: [a], account: UsageRefs.work)
        XCTAssertEqual(first, [UsageReading(account: UsageRefs.work, windows: w, readAt: Date(timeIntervalSince1970: 100), source: "claude headless", hardRejection: false)])
        XCTAssertEqual(source.readings(from: [a], account: UsageRefs.work), [], "the same event is not news")
        let b = seat(windows: w, status: "allowed", last: Date(timeIntervalSince1970: 160))
        XCTAssertEqual(source.readings(from: [b], account: UsageRefs.work).count, 1)
    }

    func testARejectedSeatIsAHardRejectionUntilItsReset() {
        let resets = Date(timeIntervalSince1970: 5_000)
        let a = seat(windows: [UsageWindow(name: "five_hour", utilization: 1, resetsAt: resets)], status: "rejected", resets: resets,
                     last: Date(timeIntervalSince1970: 100))
        let r = HeadlessClaudeUsageSource().readings(from: [a], account: UsageRefs.work)
        XCTAssertEqual(r.first?.hardRejection, true)
        XCTAssertEqual(r.first?.worstWindow?.resetsAt, resets)
    }

    func testCodexSeatsAndSeatsWithoutRateLimitsAreSkipped() {
        let source = HeadlessClaudeUsageSource()
        XCTAssertEqual(source.readings(from: [seat(windows: [UsageWindow(name: "x", utilization: 0.1, resetsAt: nil)], status: "allowed",
                                                   last: Date(), harness: .codex)], account: UsageRefs.work), [])
        XCTAssertEqual(source.readings(from: [seat(windows: nil, status: nil, last: Date())], account: UsageRefs.work), [])
    }

    func testOpenCodeSourceStreamsOnlyQuotaRefusals() async {
        let source = OpenCodeErrorUsageSource()
        let at = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(source.ingest(OpenCodeAPIErrorEvent(status: 500, retryAfter: nil, message: "", at: at), account: UsageRefs.work))
        XCTAssertNotNil(source.ingest(OpenCodeAPIErrorEvent(status: 429, retryAfter: 30, message: "", at: at), account: UsageRefs.work))
        source.finish()
        var got: [UsageReading] = []
        for await r in source.readings { got.append(r) }
        XCTAssertEqual(got.map(\.hardRejection), [true])
        XCTAssertEqual(got.first?.worstWindow?.resetsAt, at.addingTimeInterval(30))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=UsageSourcesTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'ClaudeModUsageSource' in scope`.

- [ ] **Step 3: Implement `ClaudeModUsageSource.swift`**

```swift
import Foundation
import IntakeKit

/// Reads the files the bundled usage mod writes, one per claude tab, into
/// `ClaudePluginLocation.usageDirectory`.
///
/// Polled, not watched: `UsageService` already ticks every few seconds and a directory listing
/// is cheap, while an FSEvents stream would be one more lifetime to manage for no gain. A file
/// is decoded only when its modification date moved, and is recorded as seen only after it
/// decoded — the mod's write and this read can interleave, and a torn read must be retried on
/// the next scan, not mistaken for "already handled".
@MainActor
final class ClaudeModUsageSource {
    let directory: URL
    private var seen: [String: Date] = [:]

    init(directory: URL) { self.directory = directory }

    /// Files named `<uuid>.json` that changed since the last scan. The stem is the FD tab id or
    /// claude's own session id; `UsageService` decides which.
    func scan() -> [(stem: UUID, file: ModUsageFile)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var out: [(stem: UUID, file: ModUsageFile)] = []
        for name in names.sorted() where name.hasSuffix(".json") {
            guard let stem = UUID(uuidString: String(name.dropLast(5))) else { continue }
            let url = directory.appendingPathComponent(name)
            guard let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  seen[name] != mtime,
                  let data = try? Data(contentsOf: url),
                  let file = ModUsageFile.decode(data) else { continue }
            seen[name] = mtime
            out.append((stem, file))
        }
        return out
    }

    /// One file per tab ever opened would grow forever; a week-old file belongs to a tab that is
    /// long gone, and its reading is stale thirty minutes after it was written anyway.
    func prune(olderThan age: TimeInterval, now: Date) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard let mtime = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) > age else { continue }
            try? fm.removeItem(at: url)
            seen.removeValue(forKey: name)
        }
    }
}
```

- [ ] **Step 4: Implement `HeadlessClaudeUsageSource.swift`**

```swift
import Foundation
import IntakeKit

/// Readings from headless `claude -p` intake seats, whose stream carries a `rate_limit_event`
/// per API call (folded into `SeatActivity` by Task 4's parser change).
///
/// A seat's activity is re-read on every tick with the same numbers, so a reading is produced
/// once per seat event (`startedAt` + `lastEventAt`), not once per tick — otherwise every tick
/// would look like a fresh reading and an idle seat would keep its account "fresh" forever.
@MainActor
final class HeadlessClaudeUsageSource {
    private var seen: Set<String> = []

    func readings(from activities: [SeatActivity], account: AccountRef) -> [UsageReading] {
        var out: [UsageReading] = []
        for a in activities where a.harness == .claude && (a.rateLimitWindows != nil || a.rateLimitStatus != nil) {
            let at = a.lastEventAt ?? a.startedAt
            let key = "\(a.startedAt.timeIntervalSince1970)|\(at.timeIntervalSince1970)"
            guard seen.insert(key).inserted else { continue }
            if let status = a.rateLimitStatus, !status.hasPrefix("allowed") {
                let until = a.rateLimitResetsAt.map { [UsageWindow(name: "rejected", utilization: 1, resetsAt: $0)] } ?? []
                out.append(UsageReading(account: account, windows: until, readAt: at, source: "claude headless", hardRejection: true))
            } else if let windows = a.rateLimitWindows {
                out.append(UsageReading(account: account, windows: windows, readAt: at, source: "claude headless", hardRejection: false))
            }
        }
        // Bounded: keys are only needed for seats still being re-read.
        if seen.count > 4_096 { seen.removeAll() }
        return out
    }
}
```

- [ ] **Step 5: Implement `OpenCodeErrorUsageSource.swift`**

```swift
import Foundation
import IntakeKit

/// OpenCode has no meter (L3-U §3): a 429 `APIError` is the whole signal, and it puts the
/// account over hard until `retry-after`, or for the 15-minute backoff when there is none.
///
/// A real `UsageMeterSource`, so the OpenCode adapter (another workstream's branch) can return
/// it from `usageMeterSource(account:)` and `UsageService.consume(_:)` reads it like any other.
/// Until that branch merges, nothing calls `ingest` outside tests.
final class OpenCodeErrorUsageSource: UsageMeterSource, @unchecked Sendable {
    let readings: AsyncStream<UsageReading>
    private let continuation: AsyncStream<UsageReading>.Continuation

    init() { (readings, continuation) = AsyncStream.makeStream(of: UsageReading.self) }

    @discardableResult
    func ingest(_ event: OpenCodeAPIErrorEvent, account: AccountRef) -> UsageReading? {
        guard let reading = OpenCodeRateLimit.reading(for: event, account: account) else { return nil }
        continuation.yield(reading)
        return reading
    }

    func finish() { continuation.finish() }
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `FD_TEST_FILTER=UsageSourcesTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Usage/ClaudeModUsageSource.swift Sources/FlightDeck/FlightControl/Usage/HeadlessClaudeUsageSource.swift Sources/FlightDeck/FlightControl/Usage/OpenCodeErrorUsageSource.swift Tests/FlightDeckTests/FlightControlL3/Usage/UsageSourcesTests.swift
git commit -m "feat: meter claude tabs, headless seats and opencode refusals" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: `UsageService` — the funnel, the tick, taps and manual-tab notices

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Usage/UsageService.swift`
- Modify: `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift` (fill two methods per adapter)
- Modify: `Sources/FlightDeck/AppDelegate.swift` (`startUsage(store:)` from both store-ready hops)
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/UsageServiceTests.swift`

**Interfaces:**
- Consumes: Tasks 3–12; `SessionStore.repos`, `.apiErrors`, `.notifier`, `.intakeService`, `.onCodexNotification`, `.codexRateLimitsRead(account:)`; `PreferencesStore.preferences`, `.resolvedAccountID(for:in:)`, `.capacity`; `Notifying`.
- Produces:
  - `struct UsageEnvironment` (closures, all `@MainActor`): `sessions`, `apiErrors`, `accounts`, `resolvedAccountID`, `capacity`, `usageDirectory`, `codexRead`, `seatActivities`, `notifier`, `isSwarmSession`; `static var empty`; `static func live(store:preferences:)`.
  - `final class UsageMeterTap: UsageMeterSource, @unchecked Sendable { let accountID: UUID?; let readings: AsyncStream<UsageReading> }`
  - `@MainActor final class UsageService: ObservableObject` with `static let shared`, `let ledger: CapacityLedger`, `@Published private(set) var revision: Int`, `private(set) var isAttached: Bool`, `init(environment:ledger:now:)`, `func attach(store:preferences:)`, `func reconfigure()`, `func ingest(_:)`, `@discardableResult func consume(_ source: any UsageMeterSource) -> Task<Void, Never>`, `func tick() async`, `func ingestCodexNotification(account: UUID?, method: String, params: [String: Any])`, `func tap(agent: AgentID, account: AgentAccount?) -> UsageMeterTap`, `func accountRef(for: Session) -> AccountRef?`, `func claudeProjectsRoot(for: Session) -> URL`, `func transcriptPointer(for: SessionRef) -> TranscriptPointer?`, `func isOverHard(account: UUID) -> Bool`, `lazy var planner: LedgerHandoffPlanner`, `func setSwarmPredicate(_ isSwarm: @escaping @MainActor (UUID) -> Bool)` (L3-S calls it at integration), `static let modSilenceMessage: String`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// `UsageService` is where every meter meets the ledger. These drive one tick at a time against
/// a scripted environment and pin: each source lands on the right account, codex is polled at
/// most every two minutes and never without a running server, rate-limit API errors refuse the
/// account once per occurrence, manual tabs are told once per crossing, silence from the mod
/// becomes a visible error, and taps deliver only their own account's readings.
@MainActor
final class UsageServiceTests: XCTestCase {
    private var dir: URL!
    private var clock: UsageTestClock!
    private var sessions: [Session] = []
    private var apiErrors: [UUID: SessionAPIError] = [:]
    private var codexResult: [String: Any]?
    private var codexError: Error?
    private var codexReads = 0
    private var seats: [SeatActivity] = []
    private var swarm: Set<UUID> = []
    private var capacity = CapacityPreferences()
    private let notifier = UsageSpyNotifier()
    private let accounts = [
        AgentAccount(id: UsageRefs.workID, agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/tmp/fd-usage/w", isDirectory: true)),
        AgentAccount(id: UsageRefs.spareID, agent: .claude, displayName: "Spare", home: URL(fileURLWithPath: "/tmp/fd-usage/s", isDirectory: true)),
        AgentAccount(id: UsageRefs.codexID, agent: .codex, displayName: "Codex", home: URL(fileURLWithPath: "/tmp/fd-usage/c", isDirectory: true)),
    ]

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-usage-svc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        clock = UsageTestClock()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func service() -> UsageService {
        let c = clock!
        let env = UsageEnvironment(
            sessions: { [unowned self] in self.sessions },
            apiErrors: { [unowned self] in self.apiErrors },
            accounts: { [unowned self] in self.accounts },
            resolvedAccountID: { agent, stored in stored ?? (agent == .claude ? UsageRefs.workID : UsageRefs.codexID) },
            capacity: { [unowned self] in self.capacity },
            usageDirectory: dir,
            codexRead: { [unowned self] _ in
                self.codexReads += 1
                if let e = self.codexError { throw e }
                return self.codexResult
            },
            seatActivities: { [unowned self] in self.seats },
            notifier: { [unowned self] in self.notifier },
            isSwarmSession: { [unowned self] in self.swarm.contains($0) })
        return UsageService(environment: env, ledger: CapacityLedger(now: { c.now }), now: { c.now })
    }

    private func claudeTab(on account: UUID?, conversation: UUID? = nil) -> Session {
        Session(title: "tab", workingDirectory: "/p", pinnedConversationID: conversation, agent: .claude, accountID: account)
    }

    private func writeModFile(named stem: String, percent: Double, readAt: Date) throws {
        let body = #"{"v":1,"tab":null,"session":"s","readAt":"\#(ISO8601DateFormatter().string(from: readAt))","rateLimits":[{"kind":"five_hour","percentUsed":\#(percent),"resetsAt":null}]}"#
        try Data(body.utf8).write(to: dir.appendingPathComponent("\(stem).json"))
    }

    func testAModFileLandsOnItsTabsAccount() async throws {
        let tab = claudeTab(on: UsageRefs.spareID)
        sessions = [tab]
        try writeModFile(named: tab.id.uuidString, percent: 42, readAt: clock.now)
        let svc = service()
        await svc.tick()
        let r = try XCTUnwrap(svc.ledger.latestReading(account: UsageRefs.spareID))
        XCTAssertEqual(r.source, "claude mod")
        XCTAssertEqual(r.worstWindow?.utilization ?? 0, 0.42, accuracy: 1e-9)
        XCTAssertNil(svc.ledger.latestReading(account: UsageRefs.workID))
    }

    func testAModFileNamedByConversationMapsToItsTab() async throws {
        let conversation = UUID()
        sessions = [claudeTab(on: UsageRefs.spareID, conversation: conversation)]
        try writeModFile(named: conversation.uuidString.lowercased(), percent: 10, readAt: clock.now)
        let svc = service()
        await svc.tick()
        XCTAssertNotNil(svc.ledger.latestReading(account: UsageRefs.spareID),
                        "without FLIGHT_DECK_SESSION_ID the mod names the file by claude's session id")
    }

    func testAModFileForNoKnownTabIsIgnored() async throws {
        try writeModFile(named: UUID().uuidString, percent: 99, readAt: clock.now)
        let svc = service()
        await svc.tick()
        XCTAssertNil(svc.ledger.latestReading(account: UsageRefs.workID))
        XCTAssertNil(svc.ledger.latestReading(account: UsageRefs.spareID))
    }

    func testCodexIsPolledAtMostEveryTwoMinutesWhileItHasATab() async throws {
        sessions = [Session(title: "c", workingDirectory: "/p", agent: .codex, accountID: UsageRefs.codexID)]
        codexResult = try UsageFixtures.object("codex-rate-limits-read")
        let svc = service()
        await svc.tick()
        XCTAssertEqual(codexReads, 1)
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.codexID)?.worstWindow?.utilization ?? 0, 0.88, accuracy: 1e-9)
        clock.advance(60); await svc.tick()
        XCTAssertEqual(codexReads, 1)
        clock.advance(61); await svc.tick()
        XCTAssertEqual(codexReads, 2)
    }

    func testNoCodexTabMeansNoPoll() async {
        let svc = service()
        await svc.tick()
        XCTAssertEqual(codexReads, 0)
    }

    func testAFailedCodexReadIsAVisibleSourceErrorAndNoServerIsNot() async {
        sessions = [Session(title: "c", workingDirectory: "/p", agent: .codex, accountID: UsageRefs.codexID)]
        let svc = service()
        await svc.tick()
        XCTAssertNil(svc.ledger.sourceError(account: UsageRefs.codexID), "no app-server running is normal, not an error")
        codexError = CodexRPCError.transportClosed
        clock.advance(121); await svc.tick()
        XCTAssertTrue(svc.ledger.sourceError(account: UsageRefs.codexID)?.hasPrefix("Codex app-server:") ?? false)
    }

    func testAPushedUpdateMergesForItsAccount() throws {
        let svc = service()
        svc.ingestCodexNotification(account: UsageRefs.codexID, method: "account/rateLimits/updated",
                                    params: try UsageFixtures.object("codex-rate-limits-updated"))
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.codexID)?.worstWindow?.utilization ?? 0, 0.96, accuracy: 1e-9)
        svc.ingestCodexNotification(account: UsageRefs.codexID, method: "thread/started", params: [:])
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.codexID)?.source, "codex app-server")
    }

    func testARateLimitAPIErrorRefusesTheAccountOncePerOccurrence() async throws {
        let tab = claudeTab(on: UsageRefs.workID)
        sessions = [tab]
        apiErrors = [tab.id: SessionAPIError(status: 429, kind: "rate_limit")]
        let svc = service()
        await svc.tick()
        let first = try XCTUnwrap(svc.ledger.rejection(account: UsageRefs.workID))
        clock.advance(30); await svc.tick()
        XCTAssertEqual(svc.ledger.rejection(account: UsageRefs.workID)?.at, first.at, "a standing error is one refusal, not one per tick")
    }

    func testAnOverloadedAPIIsNotThisAccountsLimit() async {
        let tab = claudeTab(on: UsageRefs.workID)
        sessions = [tab]
        apiErrors = [tab.id: SessionAPIError(status: 529, kind: "overloaded")]
        let svc = service()
        await svc.tick()
        XCTAssertNil(svc.ledger.rejection(account: UsageRefs.workID))
    }

    func testHeadlessSeatsMeterTheBuiltInClaudeAccount() async {
        var a = SeatActivity(harness: .claude, startedAt: Date(timeIntervalSince1970: 0))
        a.rateLimitWindows = [UsageWindow(name: "five_hour", utilization: 0.3, resetsAt: nil)]
        a.rateLimitStatus = "allowed"
        a.lastEventAt = clock.now
        seats = [a]
        let svc = service()
        await svc.tick()
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.workID)?.source, "claude headless")
    }

    func testAManualTabIsToldOncePerCrossing() async {
        let tab = claudeTab(on: UsageRefs.workID)
        sessions = [tab]
        let svc = service()
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.97, at: clock.now))
        await svc.tick(); await svc.tick()
        XCTAssertEqual(notifier.notes.count, 1)
        XCTAssertEqual(notifier.notes.first?.session, tab.id)
        clock.advance(10); svc.ingest(UsageRefs.reading(UsageRefs.work, 0.10, at: clock.now)); await svc.tick()
        clock.advance(10); svc.ingest(UsageRefs.reading(UsageRefs.work, 0.98, at: clock.now)); await svc.tick()
        XCTAssertEqual(notifier.notes.count, 2, "a new crossing is news again")
    }

    func testASwarmTabIsNotNotifiedTheDriverHandlesIt() async {
        let tab = claudeTab(on: UsageRefs.workID)
        sessions = [tab]; swarm = [tab.id]
        let svc = service()
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.97, at: clock.now))
        await svc.tick()
        XCTAssertEqual(notifier.notes, [])
    }

    func testFifteenSilentMinutesFromTheModIsAVisibleError() async throws {
        let tab = claudeTab(on: UsageRefs.spareID)
        sessions = [tab]
        let svc = service()
        await svc.tick()
        clock.advance(14 * 60); await svc.tick()
        XCTAssertNil(svc.ledger.sourceError(account: UsageRefs.spareID))
        clock.advance(60); await svc.tick()
        XCTAssertEqual(svc.ledger.sourceError(account: UsageRefs.spareID), UsageService.modSilenceMessage)
        try writeModFile(named: tab.id.uuidString, percent: 5, readAt: clock.now)
        await svc.tick()
        XCTAssertNil(svc.ledger.sourceError(account: UsageRefs.spareID))
    }

    func testATapDeliversOnlyItsAccountsReadings() async {
        let svc = service()
        let tap = svc.tap(agent: .claude, account: nil)
        XCTAssertEqual(tap.accountID, UsageRefs.workID, "nil is the built-in account, resolved")
        svc.ingest(UsageRefs.reading(UsageRefs.spare, 0.5, at: clock.now))
        svc.ingest(UsageRefs.reading(UsageRefs.work, 0.6, at: clock.now))
        var it = tap.readings.makeAsyncIterator()
        let r = await it.next()
        XCTAssertEqual(r?.account, UsageRefs.work)
    }

    func testConsumeReadsAnyMeterSource() async {
        let svc = service()
        let fake = FakeUsageMeterSource()
        let task = svc.consume(fake)
        fake.send(UsageRefs.reading(UsageRefs.spare, 0.25, at: clock.now)); fake.finish()
        await task.value
        XCTAssertEqual(svc.ledger.latestReading(account: UsageRefs.spareID)?.worstWindow?.utilization, 0.25)
    }

    func testReconfigurePicksUpStoredPools() {
        let svc = service()
        XCTAssertNil(svc.ledger.pool("pool-night001"))
        capacity = CapacityPreferences(pools: [.hosted(id: "pool-night001", label: "Night", harness: "claude", accounts: [UsageRefs.spareID])])
        svc.reconfigure()
        XCTAssertEqual(svc.ledger.pool("pool-night001")?.accounts, [UsageRefs.spareID])
    }

    func testCapabilitiesNowAnswerMeterAndTranscript() throws {
        XCTAssertNotNil(ClaudeRoutingCapabilities().usageMeterSource(account: nil).value)
        XCTAssertNotNil(CodexRoutingCapabilities().usageMeterSource(account: nil).value)
        let rollout = dir.appendingPathComponent("rollout.jsonl")
        try Data().write(to: rollout)
        let codexTab = Session(title: "c", workingDirectory: "/p", agent: .codex, transcriptPath: rollout.path)
        XCTAssertEqual(CodexRoutingCapabilities().transcriptPointer(for: codexTab).value?.locator, .path(rollout.path))
        XCTAssertNil(CodexRoutingCapabilities().transcriptPointer(for: Session(title: "c", workingDirectory: "/p", agent: .codex)).value)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=UsageServiceTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'UsageEnvironment' in scope`.

- [ ] **Step 3: Implement `UsageService.swift`**

```swift
import Combine
import Foundation
import IntakeKit

/// What `UsageService` reads from the rest of the app. Closures, so its tests drive it from
/// literals instead of a live store; `@MainActor` because every real answer comes from the
/// store or the preferences, which are.
struct UsageEnvironment {
    var sessions: @MainActor () -> [Session]
    var apiErrors: @MainActor () -> [UUID: SessionAPIError]
    /// Every account, tombstones included: a removed account's running tab still reports, and
    /// its readings must land under its own id.
    var accounts: @MainActor () -> [AgentAccount]
    var resolvedAccountID: @MainActor (AgentID, UUID?) -> UUID?
    var capacity: @MainActor () -> CapacityPreferences
    var usageDirectory: URL
    /// The account's codex `account/rateLimits/read`, or nil when no app-server runs for it.
    var codexRead: @MainActor (UUID?) async throws -> [String: Any]?
    var seatActivities: @MainActor () -> [SeatActivity]
    var notifier: @MainActor () -> Notifying?
    /// Swarm tabs are the hand-off driver's; only manual tabs get the one-time notice. L3-S
    /// answers this at integration; until then every tab is manual.
    var isSwarmSession: @MainActor (UUID) -> Bool

    static var empty: UsageEnvironment {
        UsageEnvironment(sessions: { [] }, apiErrors: { [:] }, accounts: { [] },
                         resolvedAccountID: { _, stored in stored }, capacity: { CapacityPreferences() },
                         usageDirectory: ClaudePluginLocation.usageDirectory, codexRead: { _ in nil },
                         seatActivities: { [] }, notifier: { nil }, isSwarmSession: { _ in false })
    }

    @MainActor
    static func live(store: SessionStore, preferences: PreferencesStore) -> UsageEnvironment {
        UsageEnvironment(
            sessions: { [weak store] in store?.repos.flatMap(\.sessions) ?? [] },
            apiErrors: { [weak store] in store?.apiErrors ?? [:] },
            accounts: { [weak preferences] in preferences?.preferences.accounts ?? [] },
            resolvedAccountID: { [weak preferences] agent, stored in
                preferences?.resolvedAccountID(for: agent, in: stored) ?? stored
            },
            capacity: { [weak preferences] in preferences?.capacity ?? CapacityPreferences() },
            usageDirectory: ClaudePluginLocation.usageDirectory,
            codexRead: { [weak store] account in try await store?.codexRateLimitsRead(account: account) },
            // `intakeService` is lazy; by the first tick the project views have built it, and
            // building it here would only start the same watchers they would.
            seatActivities: { [weak store] in
                guard let intake = store?.intakeService else { return [] }
                return intake.seatActivities.values.flatMap(\.values) + Array(intake.triageActivities.values)
            },
            notifier: { [weak store] in store?.notifier },
            isSwarmSession: { _ in false })
    }
}

/// The contract's per-account `UsageMeterSource` (L3-0), served by `usageMeterSource(account:)`.
/// A view onto `UsageService`'s funnel rather than a second meter: everything an adapter could
/// report already arrives there.
final class UsageMeterTap: UsageMeterSource, @unchecked Sendable {
    let accountID: UUID?
    let readings: AsyncStream<UsageReading>
    private let continuation: AsyncStream<UsageReading>.Continuation

    init(accountID: UUID?) {
        self.accountID = accountID
        (readings, continuation) = AsyncStream.makeStream(of: UsageReading.self, bufferingPolicy: .bufferingNewest(16))
    }

    func send(_ reading: UsageReading) { continuation.yield(reading) }
    func finish() { continuation.finish() }
}

/// Funnels every meter into `CapacityLedger` and keeps the account states current (L3-U §3).
///
/// One per app (`shared`), attached once to the store and preferences from `AppDelegate`'s
/// store-ready hops. It ticks every 5 s: scan the mod's files, fold headless seats, turn
/// rate-limit API errors into refusals, poll codex at most every 120 s per account with a live
/// codex tab, flag a silent mod, and tell manual tabs once when their account crosses hard.
@MainActor
final class UsageService: ObservableObject {
    static let shared = UsageService()

    static let tickInterval: Duration = .seconds(5)
    static let codexPollInterval: TimeInterval = 120
    static let modSilenceGrace: TimeInterval = 15 * 60
    static let fileRetention: TimeInterval = 7 * 24 * 3600
    static let modSilenceMessage = "No reading from Flight Deck's usage mod in this account's tabs for 15 minutes. Its Claude plugin may not be loaded."

    let ledger: CapacityLedger
    /// Bumped on every change and every tick: freshness and window resets move with the clock
    /// even when no new reading arrives, so the meters must redraw anyway.
    @Published private(set) var revision = 0
    private(set) var isAttached = false
    private(set) var environment: UsageEnvironment
    private let now: () -> Date

    private var modSource: ClaudeModUsageSource
    private let headless = HeadlessClaudeUsageSource()
    private var codexSources: [UUID: CodexRateLimitSource] = [:]
    private var lastCodexPoll: [UUID: Date] = [:]
    private struct WeakTap { weak var tap: UsageMeterTap? }
    private var taps: [WeakTap] = []
    private var firstSeen: [UUID: Date] = [:]
    private var reported: Set<UUID> = []
    private var rejectedTabs: Set<UUID> = []
    private var notifiedOverHard: Set<UUID> = []
    private var loop: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(environment: UsageEnvironment = .empty, ledger: CapacityLedger = CapacityLedger(), now: @escaping () -> Date = Date.init) {
        self.environment = environment
        self.ledger = ledger
        self.now = now
        modSource = ClaudeModUsageSource(directory: environment.usageDirectory)
        reconfigure()
    }

    /// The real `HandoffPlanner`, for L3-S to give the `HandoffDriver` at integration. The
    /// reservation list is the driver host's job (it asks Agent Mail just before the prompt),
    /// so the planner's is empty.
    lazy var planner = LedgerHandoffPlanner(
        reader: ledger,
        transcript: { [weak self] ref in MainActor.assumeIsolated { self?.transcriptPointer(for: ref) } },
        reservedFiles: { _ in [] })

    func attach(store: SessionStore, preferences: PreferencesStore) {
        guard !isAttached else { return }
        isAttached = true
        environment = .live(store: store, preferences: preferences)
        modSource = ClaudeModUsageSource(directory: environment.usageDirectory)
        modSource.prune(olderThan: Self.fileRetention, now: now())
        store.onCodexNotification = { [weak self] account, method, params in
            self?.ingestCodexNotification(account: account, method: method, params: params)
        }
        // `@Published` emits in `willSet`, so the new preferences are read one hop later.
        preferences.$preferences
            .sink { [weak self] _ in Task { @MainActor in self?.reconfigure() } }
            .store(in: &cancellables)
        reconfigure()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.tickInterval)
            }
        }
    }

    /// L3-S answers "is this tab a swarm agent?" at integration. Until then every tab is
    /// manual: it gets the one-time notice and is never handed off.
    func setSwarmPredicate(_ isSwarm: @escaping @MainActor (UUID) -> Bool) {
        environment.isSwarmSession = isSwarm
    }

    func reconfigure() {
        let accounts = environment.accounts()
        ledger.configure(pools: environment.capacity().effectivePools(accounts: accounts),
                         accounts: accounts.map(CapacityPreferences.accountRef))
        revision += 1
    }

    func ingest(_ reading: UsageReading) {
        ledger.ingest(reading)
        taps.removeAll { $0.tap == nil }
        for box in taps where box.tap?.accountID == reading.account.id { box.tap?.send(reading) }
        revision += 1
    }

    /// How a source that is a stream (the OpenCode adapter's, say) joins the funnel.
    @discardableResult
    func consume(_ source: any UsageMeterSource) -> Task<Void, Never> {
        Task { [weak self] in
            for await reading in source.readings { self?.ingest(reading) }
        }
    }

    func tick() async {
        let t = now()
        let sessions = environment.sessions()
        for s in sessions where firstSeen[s.id] == nil { firstSeen[s.id] = t }
        ingestModFiles(sessions)
        ingestHeadlessSeats()
        ingestAPIErrors(sessions, at: t)
        await pollCodex(sessions, at: t)
        flagSilentMod(sessions, at: t)
        noticeManualTabs(sessions)
        revision += 1
    }

    func ingestCodexNotification(account: UUID?, method: String, params: [String: Any]) {
        guard method == "account/rateLimits/updated", let id = account ?? environment.resolvedAccountID(.codex, nil),
              let ref = ref(forAccount: id) else { return }
        let source = codexSource(id)
        source.applyUpdate(params)
        if let reading = source.reading(account: ref, at: now()) { ingest(reading) }
    }

    func tap(agent: AgentID, account: AgentAccount?) -> UsageMeterTap {
        let id = account?.id ?? environment.resolvedAccountID(agent, nil)
        let tap = UsageMeterTap(accountID: id)
        taps.append(WeakTap(tap: tap))
        if let id, let latest = ledger.latestReading(account: id) { tap.send(latest) }
        return tap
    }

    func accountRef(for session: Session) -> AccountRef? {
        environment.resolvedAccountID(session.agent, session.accountID).flatMap(ref(forAccount:))
    }

    /// The account's `projects/` directory — the root claude writes this tab's transcript under.
    func claudeProjectsRoot(for session: Session) -> URL {
        let id = environment.resolvedAccountID(.claude, session.accountID)
        let home = environment.accounts().first { $0.id == id }?.home ?? AgentID.claude.builtInHome
        return home.appendingPathComponent("projects", isDirectory: true)
    }

    func transcriptPointer(for ref: SessionRef) -> TranscriptPointer? {
        guard let session = environment.sessions().first(where: { $0.id == ref.id }) else { return nil }
        return RoutingCapabilityRegistry.standard().capabilities(for: session.agent.harnessID)?
            .transcriptPointer(for: session).value
    }

    /// Over hard in any hosted pool that holds it. The strictest pool decides, so a manual tab is
    /// warned at the earliest threshold anyone configured for its account.
    func isOverHard(account id: UUID) -> Bool {
        ledger.allPools.filter { $0.kind == .hosted && $0.accounts.contains(id) }.contains { pool in
            ledger.headroom(pool: pool.id).contains { $0.account.id == id && $0.state == .overHard }
        }
    }

    // MARK: - One tick

    private func ref(forAccount id: UUID) -> AccountRef? {
        environment.accounts().first { $0.id == id }.map(CapacityPreferences.accountRef)
    }

    private func codexSource(_ id: UUID) -> CodexRateLimitSource {
        if let existing = codexSources[id] { return existing }
        let made = CodexRateLimitSource()
        codexSources[id] = made
        return made
    }

    private func ingestModFiles(_ sessions: [Session]) {
        for (stem, file) in modSource.scan() {
            guard let tab = sessions.first(where: { $0.agent == .claude && ($0.id == stem || $0.pinnedConversationID == stem) }),
                  let ref = accountRef(for: tab) else { continue }
            reported.insert(tab.id)
            ingest(UsageReading(account: ref, windows: file.windows, readAt: file.readAt, source: "claude mod", hardRejection: false))
        }
    }

    /// Headless seats run with Flight Deck's own environment, so they bill the built-in claude
    /// account (see `IntakeRunnerController`'s environment recipe).
    private func ingestHeadlessSeats() {
        guard let id = environment.resolvedAccountID(.claude, nil), let ref = ref(forAccount: id) else { return }
        for reading in headless.readings(from: environment.seatActivities(), account: ref) { ingest(reading) }
    }

    private func ingestAPIErrors(_ sessions: [Session], at t: Date) {
        let errors = environment.apiErrors()
        for s in sessions {
            guard let e = errors[s.id], RateLimitClassifier.isRateLimit(status: e.status, kind: e.kind) else {
                rejectedTabs.remove(s.id)
                continue
            }
            // Once per occurrence: a standing error re-reported every tick would push the
            // 15-minute backoff forward forever.
            guard rejectedTabs.insert(s.id).inserted, let ref = accountRef(for: s) else { continue }
            ingest(UsageReading(account: ref, windows: [], readAt: t, source: "\(s.agent.displayName) API error", hardRejection: true))
        }
    }

    private func pollCodex(_ sessions: [Session], at t: Date) async {
        let keys = Set(sessions.filter { $0.agent == .codex }.compactMap { environment.resolvedAccountID(.codex, $0.accountID) })
        for id in keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let last = lastCodexPoll[id], t.timeIntervalSince(last) < Self.codexPollInterval { continue }
            lastCodexPoll[id] = t
            guard let ref = ref(forAccount: id) else { continue }
            do {
                guard let result = try await environment.codexRead(id) else { continue }
                let source = codexSource(id)
                source.applyRead(result)
                if let reading = source.reading(account: ref, at: t) { ingest(reading) }
            } catch {
                ledger.setSourceError("Codex app-server: \(error)", account: id)
            }
        }
    }

    private func flagSilentMod(_ sessions: [Session], at t: Date) {
        var tabsByAccount: [UUID: [Session]] = [:]
        for s in sessions where s.agent == .claude {
            if let id = environment.resolvedAccountID(.claude, s.accountID) { tabsByAccount[id, default: []].append(s) }
        }
        for (id, tabs) in tabsByAccount where ledger.latestReading(account: id) == nil && !tabs.contains(where: { reported.contains($0.id) }) {
            let oldest = tabs.compactMap { firstSeen[$0.id] }.min() ?? t
            if t.timeIntervalSince(oldest) >= Self.modSilenceGrace { ledger.setSourceError(Self.modSilenceMessage, account: id) }
        }
    }

    private func noticeManualTabs(_ sessions: [Session]) {
        for s in sessions where !environment.isSwarmSession(s.id) {
            guard let ref = accountRef(for: s), let id = ref.id else { continue }
            guard isOverHard(account: id) else { notifiedOverHard.remove(s.id); continue }
            guard notifiedOverHard.insert(s.id).inserted else { continue }
            environment.notifier()?.notify(
                sessionID: s.id, title: "\(ref.label) is near its usage limit", subtitle: s.title,
                body: "Flight Control does not move your own tabs. This agent may stop until the limit resets.")
        }
    }
}
```

`isSwarmSession` is part of the environment; L3-S replaces it at integration with one call,
`UsageService.shared.setSwarmPredicate { … }`.

- [ ] **Step 4: Fill the capability stubs**

In `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift`, inside
`ClaudeRoutingCapabilities`, replace exactly these two lines (they appear verbatim in both stub
classes, so the `Edit` tool's `old_string` must start at the class's
`let harness: HarnessID = AgentID.claude.harnessID` line and run through the `transcriptPointer`
line, keeping the lines in between unchanged):

```swift
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> { .unsupported(reason: "filled in by L3-U") }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> { .unsupported(reason: "filled in by L3-U") }
```

with:

```swift
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> {
        .supported(UsageService.shared.tap(agent: .claude, account: account))
    }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> {
        guard let pointer = TranscriptPointers.claude(session: session, projectsRoot: UsageService.shared.claudeProjectsRoot(for: session)) else {
            return .unsupported(reason: "no transcript file on disk for this conversation")
        }
        return .supported(pointer)
    }
```

The same two lines appear in `CodexRoutingCapabilities`; the `Edit` tool needs a unique match, so
include the class's `let harness: HarnessID = AgentID.codex.harnessID` line … through its
`transcriptPointer` line in `old_string`, and replace the two methods with:

```swift
    func usageMeterSource(account: AgentAccount?) -> RoutingCapability<any UsageMeterSource> {
        .supported(UsageService.shared.tap(agent: .codex, account: account))
    }
    func transcriptPointer(for session: Session) -> RoutingCapability<TranscriptPointer> {
        guard let pointer = TranscriptPointers.codex(session: session) else {
            return .unsupported(reason: "codex has not reported a rollout path for this tab")
        }
        return .supported(pointer)
    }
```

Leave every other method of both classes as L3-0 wrote it (L3-R and L3-S fill those in their own
branches). Update the stub comment above `ClaudeRoutingCapabilities` to say L3-U's two are filled.

- [ ] **Step 5: Start the service from both store-ready hops**

In `AppDelegate`, in the `.flightDeckStoreReady` observer (beside `startAnswerTrigger(store: store)`)
and in `applicationDidFinishLaunching` (same place), add `self?.startUsage(store: store)` /
`startUsage(store: store)`. Add the method beside `startAnswerTrigger`:

```swift
    /// Starts Flight Control's usage meters. Reached from both store-ready hops for the reason
    /// `startSearch` is, and idempotent for the same reason (`UsageService.attach` guards).
    @MainActor
    private func startUsage(store: SessionStore) {
        guard let preferences = store.preferences, !UsageService.shared.isAttached else { return }
        UsageService.shared.attach(store: store, preferences: preferences)
    }
```

- [ ] **Step 6: Run to verify it passes, with the contract's registry tests**

Run: `FD_TEST_FILTER=UsageServiceTests,RoutingCapabilityRegistryTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`. `testStubsSayUnsupportedRatherThanFake` still passes: it
checks only `applying(_:to:)`, which this task does not touch.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Usage/UsageService.swift Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift Sources/FlightDeck/AppDelegate.swift Tests/FlightDeckTests/FlightControlL3/Usage/UsageServiceTests.swift
git commit -m "feat: funnel every usage meter into the capacity ledger on a five-second tick" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 14: The hand-off host — interrupt, retire, `br`/`am`, notify, log

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`interruptTurn`, beside `private func injector(for:)` — it needs that private accessor)
- Create: `Sources/FlightDeck/SessionStore+Handoff.swift` (`AgentID.exitCommand`, `retireAgent`)
- Create: `Sources/FlightDeck/FlightControl/Usage/HandoffHost.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/HandoffHostTests.swift`

**Interfaces:**
- Consumes: `SessionStore.statuses`, `.apiErrors`, `.notifier`, `.submitPrompt(_:token:to:)`, `.injector(for:)` (private); `FlywheelProcessRunner`; `RateLimitClassifier`; L3-0 `TaskRef`, `SessionRef`, `HandoffRequest`, `ExecutionBlock`, `TaskKind`, `AdapterCatalogs`, `AccountRef`.
- Produces:
  - `SessionStore.interruptTurn(_ id: UUID, includingDialog: Bool = false) -> Bool` (`@discardableResult`)
  - `AgentID.exitCommand: String`; `SessionStore.retireAgent(_ id: UUID) -> PromptDispatch` (`@discardableResult`)
  - `@MainActor protocol HandoffHost: AnyObject` — `activity(of:) -> SessionActivity?`, `isRateLimited(_:) -> Bool`, `interrupt(_:)`, `confirm(_:) async -> Bool`, `kind(for:project:) -> TaskKind?`, `catalogs() async -> AdapterCatalogs`, `reservedFiles(of:project:) async -> [String]?`, `reassign(task:to:) async -> String?`, `releaseReservations(of:project:) async -> String?`, `stopAgent(_:) async`, `markHandedOff(_:to:)`, `record(_:)`, `notify(title:body:session:)`
  - `struct HandoffLogEntry: Codable, Equatable { enum Outcome: String, Codable { handedOff, spawnFailed, waitingForCapacity, declined, interrupted }; at: Date; outcome: Outcome; task: String; oldSession: UUID; oldAgent: String; newSession: UUID?; newAgent: String?; fromAccount: String; toAccount: String?; detail: String? }`
  - `struct BrAmHandoffCommands { var runner: FlywheelProcessRunner; var brPath: String; var amPath: String; static let actor = "flightdeck-handoff"; func reassign(task: TaskRef, to agent: String) async -> String?; func releaseReservations(of agent: String, project: URL) async -> String? }`
  - `@MainActor final class StoreHandoffHost: HandoffHost` with `init(store:commands:logURL:)`, `static var defaultLogURL: URL`, and the L3-S hooks `confirmer`, `kindLookup`, `catalogProvider`, `reservationLookup`, `onHandedOff`.

- [ ] **Step 1: Verify the external commands and exit commands**

Run: `br update --help 2>&1 | rg -n "assignee|actor"; am file_reservations release --help 2>&1 | head -20`
Expected: `br update` accepts `--assignee <name>` and `--actor <name>` (as `IntakeDelivery`'s reclaim
already uses), and `am file_reservations release <project> <agent>` is the positional form
`IntakeDelivery` uses. If `am`'s usage differs, use the form it prints and update the test's
expected argv to match the printed usage (cite it in the test comment).

Verify codex's exit command in a scratch TUI (no turn is run, no tokens):

```bash
tmux new-session -d -s fdcodexexit -x 160 -y 40 "env -u CLAUDE_CODE_CHILD_SESSION codex; echo EXITED-TO-SHELL; sleep 30"
```

Background-wait until the TUI draws (`until tmux capture-pane -p -t fdcodexexit | rg -q '›|>'; do sleep 1; done`,
`run_in_background: true`, `timeout: 60000`), then `tmux send-keys -t fdcodexexit '/quit' Enter`,
background-wait `until tmux capture-pane -p -t fdcodexexit | rg -q EXITED-TO-SHELL; do sleep 1; done`
(`timeout: 20000`), and `tmux kill-session -t fdcodexexit`.
- `EXITED-TO-SHELL` appeared → codex's exit command is `/quit` (as below).
- It did not → repeat with `/exit`; if that works, use `"/exit"` for `.codex` in Step 4 and in the
  test. If neither does, record it in the spec follow-up notes and use `"/exit"` (claude's) for
  both, with a FOLLOWUPS line that codex hand-offs leave the old TUI running.
(Use the same claude check if Task 1's tmux session did not already show `/exit` returning to the
shell.)

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit
import FleetKit
@testable import FlightDeck

/// The host is every side effect of a hand-off that touches the outside world: keys typed into a
/// live terminal, `br` and `am`, notifications, the log. These pin the guards that keep those
/// side effects from landing where they do harm — an Escape into an idle draft, an exit command
/// typed into a dialog, a silent "yes" when the user asked to be asked.
@MainActor
final class HandoffHostTests: XCTestCase {
    private func storeWithTab(_ activity: SessionActivity) -> (SessionStore, UUID, SpyInjector) {
        let store = SessionStore(provider: nil, persistence: nil)
        let spy = SpyInjector()
        store.injectorOverride = spy
        let id = store.newSession(in: URL(fileURLWithPath: "/tmp/fd-handoff-host")).id
        store.applyRegistryForTesting([id: SessionStatus(activity: activity)])
        spy.events.removeAll()
        return (store, id, spy)
    }

    func testInterruptOnlyEscapesABusyTurn() {
        let (busy, b, busySpy) = storeWithTab(.busy)
        XCTAssertTrue(busy.interruptTurn(b))
        XCTAssertEqual(busySpy.events, [.escape])

        let (idle, i, idleSpy) = storeWithTab(.idle)
        XCTAssertFalse(idle.interruptTurn(i), "Escape on an idle composer clears the user's draft")
        XCTAssertEqual(idleSpy.events, [])
    }

    func testADialogIsEscapedOnlyWhenAsked() {
        let (store, id, spy) = storeWithTab(.waiting)
        XCTAssertFalse(store.interruptTurn(id), "Escape in a dialog is a denial, not an interrupt")
        XCTAssertEqual(spy.events, [])
        XCTAssertTrue(store.interruptTurn(id, includingDialog: true))
        XCTAssertEqual(spy.events, [.escape])
    }

    func testExitCommands() {
        XCTAssertEqual(AgentID.claude.exitCommand, "/exit")
        XCTAssertEqual(AgentID.codex.exitCommand, "/quit")
    }

    func testRetiringAnIdleAgentSendsItsExitCommandWithoutEscape() {
        let (store, id, spy) = storeWithTab(.idle)
        let dispatch = store.retireAgent(id)
        XCTAssertTrue([.sent, .queued].contains(dispatch), "\(dispatch)")
        XCTAssertNotEqual(spy.events.first, .escape)
    }

    func testRetiringAnAgentInADialogEscapesTheDialogFirst() {
        let (store, id, spy) = storeWithTab(.waiting)
        _ = store.retireAgent(id)
        XCTAssertEqual(spy.events.first, .escape)
    }

    func testBrAndAmArgvAndWorkingDirectory() async {
        let runner = UsageRecordingRunner()
        let commands = BrAmHandoffCommands(runner: runner)
        let task = TaskRef(id: "fd-3x9", project: URL(fileURLWithPath: "/p/proj"))
        let reassigned = await commands.reassign(task: task, to: "GreenFox")
        let released = await commands.releaseReservations(of: "BlueLake", project: task.project)
        XCTAssertNil(reassigned); XCTAssertNil(released)
        XCTAssertEqual(runner.calls, [
            .init(executable: "br", args: ["update", "fd-3x9", "--assignee", "GreenFox", "--actor", "flightdeck-handoff"], cwd: "/p/proj"),
            .init(executable: "am", args: ["file_reservations", "release", "/p/proj", "BlueLake"], cwd: "/p/proj"),
        ])
    }

    func testACommandFailureIsAWarningNamingTheCommand() async {
        let runner = UsageRecordingRunner()
        runner.exitCode = 1; runner.stdout = "VALIDATION_FAILED: no such issue\nmore"
        let warning = await BrAmHandoffCommands(runner: runner).reassign(task: TaskRef(id: "fd-1", project: URL(fileURLWithPath: "/p")), to: "GreenFox")
        XCTAssertEqual(warning, "br update fd-1 --assignee GreenFox failed (exit 1): VALIDATION_FAILED: no such issue")
    }

    func testRateLimitedReadsTheFleetsAPIError() {
        let (store, id, _) = storeWithTab(.idle)
        let host = StoreHandoffHost(store: store, logURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.jsonl"))
        let ref = SessionRef(id: id, agentName: nil)
        XCTAssertFalse(host.isRateLimited(ref))
        store.apply(.apiError(SessionAPIError(status: 529, kind: "overloaded")), to: id)
        XCTAssertFalse(host.isRateLimited(ref))
        store.apply(.apiError(SessionAPIError(status: 429, kind: "rate_limit")), to: id)
        XCTAssertTrue(host.isRateLimited(ref))
        XCTAssertEqual(host.activity(of: ref), .idle)
    }

    func testConfirmWithNoSurfaceDeclinesAndSaysSo() async {
        let (store, id, _) = storeWithTab(.idle)
        let notifier = UsageSpyNotifier()
        store.notifier = notifier
        let host = StoreHandoffHost(store: store, logURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.jsonl"))
        let request = HandoffRequest(task: TaskRef(id: "fd-1", project: URL(fileURLWithPath: "/p")),
                                     block: ExecutionBlock(kind: "tests", harness: "claude", model: "opus", pool: "claude-default",
                                                           source: AssignmentSource(by: .rule, reason: "r", at: Date())),
                                     oldAgent: "BlueLake", oldSession: SessionRef(id: id, agentName: "BlueLake"),
                                     transcript: nil, reservedFiles: [], fromAccount: UsageRefs.work)
        let ok = await host.confirm(request)
        XCTAssertFalse(ok, "the user asked to be asked; nothing may answer for them")
        XCTAssertEqual(notifier.notes.map(\.title), ["Hand-off needs a confirmation"])
        host.confirmer = { _ in true }
        let accepted = await host.confirm(request)
        XCTAssertTrue(accepted)
    }

    func testRecordAppendsOneJSONLinePerEntry() throws {
        let (store, _, _) = storeWithTab(.idle)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fd-handoff-\(UUID().uuidString)/handoffs.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = StoreHandoffHost(store: store, logURL: url)
        let entry = HandoffLogEntry(at: Date(timeIntervalSince1970: 1_790_000_000), outcome: .handedOff, task: "fd-1",
                                    oldSession: UUID(), oldAgent: "BlueLake", newSession: UUID(), newAgent: "GreenFox",
                                    fromAccount: "Work", toAccount: "Spare", detail: nil)
        host.record(entry); host.record(entry)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(HandoffLogEntry.self, from: Data(lines[0].utf8)), entry)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=HandoffHostTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `value of type 'SessionStore' has no member 'interruptTurn'`.

- [ ] **Step 4: Implement `interruptTurn` (in `SessionStore.swift`, right after `private func injector(for id: UUID)`)**

```swift
    /// Escape into a tab whose agent is mid-turn: both claude's and codex's TUIs stop the turn on
    /// it. Flight Control's hand-off deadline uses it (L3-U §5.1).
    ///
    /// Refuses an idle tab — a stray Escape there clears the user's draft — and a tab sitting in
    /// a dialog unless the caller says so, because Escape there is a *denial*, which restarts a
    /// turn rather than ending one. Retiring an agent (`retireAgent`) is the one caller that
    /// wants the denial.
    @discardableResult
    func interruptTurn(_ id: UUID, includingDialog: Bool = false) -> Bool {
        let activity = statuses[id]?.activity
        guard activity == .busy || (includingDialog && activity == .waiting),
              let injector = injector(for: id) else { return false }
        injector.sendEscape()
        return true
    }
```

- [ ] **Step 5: Implement `SessionStore+Handoff.swift`**

```swift
import Foundation

extension AgentID {
    /// The slash command that ends this agent's TUI and returns its tab to the shell (verified
    /// against each TUI; see the L3-U plan Task 14 Step 1).
    var exitCommand: String {
        switch self {
        case .claude: return "/exit"
        case .codex: return "/quit"
        }
    }
}

extension SessionStore {
    /// Ends a handed-off agent but keeps its tab, whose scrollback is the hand-off's history
    /// (L3-U §5.7). Typed rather than signalled: the process the tab runs is the shell, and
    /// killing the agent's pid would mean resolving which descendant it is — the exit command
    /// gets the TUI to leave on its own and the shell prompt comes back.
    ///
    /// A dialog still open is refused first: the agent is being retired, so denying whatever it
    /// was about to do is right, and an exit command typed into a dialog would land in the
    /// dialog. `submitPrompt` queues the command until the composer is back.
    @discardableResult
    func retireAgent(_ id: UUID) -> PromptDispatch {
        if statuses[id]?.activity == .waiting { interruptTurn(id, includingDialog: true) }
        let agent = repos.flatMap(\.sessions).first { $0.id == id }?.agent ?? .claude
        return submitPrompt(agent.exitCommand, token: UUID(), to: id)
    }
}
```

- [ ] **Step 6: Implement `HandoffHost.swift`**

```swift
import Foundation
import IntakeKit

/// Everything the hand-off driver does to the world, behind one seam so the driver is a pure
/// state machine its tests can run against a fake.
@MainActor
protocol HandoffHost: AnyObject {
    func activity(of session: SessionRef) -> SessionActivity?
    func isRateLimited(_ session: SessionRef) -> Bool
    func interrupt(_ session: SessionRef)
    func confirm(_ request: HandoffRequest) async -> Bool
    func kind(for block: ExecutionBlock, project: URL) -> TaskKind?
    func catalogs() async -> AdapterCatalogs
    /// Nil keeps the planner's list.
    func reservedFiles(of agent: String, project: URL) async -> [String]?
    /// Each returns a warning, or nil when it worked.
    func reassign(task: TaskRef, to agentName: String) async -> String?
    func releaseReservations(of agent: String, project: URL) async -> String?
    func stopAgent(_ session: SessionRef) async
    func markHandedOff(_ old: SessionRef, to new: SessionRef)
    func record(_ entry: HandoffLogEntry)
    func notify(title: String, body: String, session: SessionRef)
}

/// One line of the hand-off log (L3-U §5.8): both tabs and both accounts, so "where did my
/// agent go" has an answer after the fact.
struct HandoffLogEntry: Codable, Equatable {
    enum Outcome: String, Codable { case handedOff, spawnFailed, waitingForCapacity, declined, interrupted }
    var at: Date
    var outcome: Outcome
    var task: String
    var oldSession: UUID
    var oldAgent: String
    var newSession: UUID?
    var newAgent: String?
    var fromAccount: String
    var toAccount: String?
    var detail: String?
}

/// `br update --assignee` and `am file_reservations release`, with the warning-not-throw shape
/// `IntakeDelivery` uses: a hand-off that already spawned its new agent must not roll back
/// because a bookkeeping command failed — it is logged and the user is told.
struct BrAmHandoffCommands {
    var runner: FlywheelProcessRunner = SystemFlywheelProcessRunner()
    var brPath = "br"
    var amPath = "am"
    static let actor = "flightdeck-handoff"

    func reassign(task: TaskRef, to agent: String) async -> String? {
        await run(brPath, ["update", task.id, "--assignee", agent, "--actor", Self.actor], cwd: task.project.path,
                  describing: "br update \(task.id) --assignee \(agent)")
    }

    func releaseReservations(of agent: String, project: URL) async -> String? {
        await run(amPath, ["file_reservations", "release", project.path, agent], cwd: project.path,
                  describing: "am file_reservations release for \(agent)")
    }

    private func run(_ executable: String, _ args: [String], cwd: String, describing: String) async -> String? {
        do {
            let (stdout, code) = try await runner.run(executable, args, cwd: cwd)
            guard code != 0 else { return nil }
            let first = stdout.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? "(no output)"
            return "\(describing) failed (exit \(code)): \(first)"
        } catch {
            return "\(describing) failed: \(error)"
        }
    }
}

/// The production host. The parts only the swarm knows — how to ask for confirmation, a task's
/// kind for spill, the catalogs, an agent's reservations, marking the old tab "handed off →",
/// where the swarm log lives — are hooks L3-S sets at integration; their defaults are the safe
/// answer (no spill, keep the planner's list, a log file of its own).
@MainActor
final class StoreHandoffHost: HandoffHost {
    private weak var store: SessionStore?
    private let commands: BrAmHandoffCommands
    private let logURL: URL

    var confirmer: ((HandoffRequest) async -> Bool)?
    var kindLookup: (ExecutionBlock, URL) -> TaskKind? = { _, _ in nil }
    var catalogProvider: () async -> AdapterCatalogs = { AdapterCatalogs([]) }
    var reservationLookup: (String, URL) async -> [String]? = { _, _ in nil }
    var onHandedOff: (SessionRef, SessionRef) -> Void = { _, _ in }

    init(store: SessionStore, commands: BrAmHandoffCommands = BrAmHandoffCommands(), logURL: URL = StoreHandoffHost.defaultLogURL) {
        self.store = store; self.commands = commands; self.logURL = logURL
    }

    /// Split by build like every other Flight Deck runtime file, so a debug build's hand-offs
    /// never appear in the real fleet's history.
    static var defaultLogURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Flight Deck", isDirectory: true)
            .appendingPathComponent("swarm-log", isDirectory: true)
            .appendingPathComponent("handoffs-\(ClaudePluginLocation.buildTag).jsonl")
    }

    func activity(of session: SessionRef) -> SessionActivity? { store?.statuses[session.id]?.activity }

    func isRateLimited(_ session: SessionRef) -> Bool {
        guard let e = store?.apiErrors[session.id] else { return false }
        return RateLimitClassifier.isRateLimit(status: e.status, kind: e.kind)
    }

    func interrupt(_ session: SessionRef) { store?.interruptTurn(session.id) }

    /// With "Confirm hand-offs" on and nothing installed to ask, the answer is no — never a
    /// silent yes on the user's behalf — and the user is told why their agent stayed put.
    func confirm(_ request: HandoffRequest) async -> Bool {
        guard let confirmer else {
            notify(title: "Hand-off needs a confirmation",
                   body: "Confirm hand-offs is on, but there is nowhere to confirm yet. \(request.oldAgent) stays on its account.",
                   session: request.oldSession)
            return false
        }
        return await confirmer(request)
    }

    func kind(for block: ExecutionBlock, project: URL) -> TaskKind? { kindLookup(block, project) }
    func catalogs() async -> AdapterCatalogs { await catalogProvider() }
    func reservedFiles(of agent: String, project: URL) async -> [String]? { await reservationLookup(agent, project) }
    func reassign(task: TaskRef, to agentName: String) async -> String? { await commands.reassign(task: task, to: agentName) }
    func releaseReservations(of agent: String, project: URL) async -> String? { await commands.releaseReservations(of: agent, project: project) }
    func stopAgent(_ session: SessionRef) async { store?.retireAgent(session.id) }
    func markHandedOff(_ old: SessionRef, to new: SessionRef) { onHandedOff(old, new) }

    func record(_ entry: HandoffLogEntry) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard var line = try? enc.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: logURL)
        }
    }

    func notify(title: String, body: String, session: SessionRef) {
        store?.notifier?.notify(sessionID: session.id, title: title, subtitle: "Flight Control", body: body)
    }
}
```

- [ ] **Step 7: Run to verify it passes, with the injection suites `interruptTurn` sits beside**

Run: `FD_TEST_FILTER=HandoffHostTests,AgentTextChannelTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`. If `testRetiringAnIdleAgent…` gets `.notRunning`, the spy
tab has no composer the gate recognizes: copy `AgentTextChannelTests`' setup (it seeds a status
and clears the spy the same way) rather than loosening the assertion.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Sources/FlightDeck/SessionStore+Handoff.swift Sources/FlightDeck/FlightControl/Usage/HandoffHost.swift Tests/FlightDeckTests/FlightControlL3/Usage/HandoffHostTests.swift
git commit -m "feat: give hand-offs a host that interrupts, retires, reassigns and logs" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: The hand-off driver

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Usage/HandoffDriver.swift`
- Create: `Tests/FlightDeckTests/FlightControlL3/Usage/FakeHandoffHost.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/HandoffDriverTests.swift`

**Interfaces:**
- Consumes: `HandoffHost`, `HandoffLogEntry` (Task 14); `HandoffPrompt` (Task 7); `HandoffSettings` (Task 8); L3-0 `HandoffPlanner`, `PoolAllocator`, `Router`, `SwarmSpawner`, `SwarmAgentSnapshot`, fakes `FakeHandoffPlanner`, `FakePoolAllocator`, `FakeRouter`, `FakeSwarmSpawner`.
- Produces: `@MainActor final class HandoffDriver { enum Phase: Equatable { waitingForBoundary(since: Date), waitingForCapacity(String), declined, failed, done(SessionRef) }; private(set) var phases: [UUID: Phase]; init(planner: HandoffPlanner, allocator: PoolAllocator, router: Router?, spawner: SwarmSpawner, host: HandoffHost, settings: @escaping () -> HandoffSettings, now: @escaping () -> Date); func evaluate(_ agents: [SwarmAgentSnapshot]) async }`. L3-S calls `evaluate` with its swarm agents on its controller tick (integration).

- [ ] **Step 1: Write the fake host**

```swift
import Foundation
import IntakeKit
@testable import FlightDeck

/// Scriptable `HandoffHost`: answers what it is told and records every side effect, in order.
@MainActor
final class FakeHandoffHost: HandoffHost {
    var activities: [UUID: SessionActivity] = [:]
    var rateLimited: Set<UUID> = []
    var confirmAnswer = true
    var kinds: [KindID: TaskKind] = [:]
    var reserved: [String]?
    var reassignWarning: String?
    private(set) var interrupted: [UUID] = []
    private(set) var confirmations: [HandoffRequest] = []
    private(set) var reassigned: [(task: String, agent: String)] = []
    private(set) var released: [String] = []
    private(set) var stopped: [UUID] = []
    private(set) var marked: [(old: UUID, new: UUID)] = []
    private(set) var log: [HandoffLogEntry] = []
    private(set) var notices: [String] = []

    func activity(of session: SessionRef) -> SessionActivity? { activities[session.id] }
    func isRateLimited(_ session: SessionRef) -> Bool { rateLimited.contains(session.id) }
    func interrupt(_ session: SessionRef) { interrupted.append(session.id) }
    func confirm(_ request: HandoffRequest) async -> Bool { confirmations.append(request); return confirmAnswer }
    func kind(for block: ExecutionBlock, project: URL) -> TaskKind? { kinds[block.kind] }
    func catalogs() async -> AdapterCatalogs { AdapterCatalogs([]) }
    func reservedFiles(of agent: String, project: URL) async -> [String]? { reserved }
    func reassign(task: TaskRef, to agentName: String) async -> String? { reassigned.append((task.id, agentName)); return reassignWarning }
    func releaseReservations(of agent: String, project: URL) async -> String? { released.append(agent); return nil }
    func stopAgent(_ session: SessionRef) async { stopped.append(session.id) }
    func markHandedOff(_ old: SessionRef, to new: SessionRef) { marked.append((old.id, new.id)) }
    func record(_ entry: HandoffLogEntry) { log.append(entry) }
    func notify(title: String, body: String, session: SessionRef) { notices.append(title) }
}
```

- [ ] **Step 2: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The driver is spec §5 steps 1–8 as a state machine. Every test scripts the four contract
/// fakes and the host, runs `evaluate` one tick at a time, and asserts the side effects — so the
/// order "spawn, then reassign, then release, then stop" and every refusal to act are pinned
/// without a terminal in sight.
@MainActor
final class HandoffDriverTests: XCTestCase {
    private var clock: UsageTestClock!
    private var planner: FakeHandoffPlanner!
    private var allocator: FakePoolAllocator!
    private var router: FakeRouter!
    private var spawner: FakeSwarmSpawner!
    private var host: FakeHandoffHost!
    private var settings = HandoffSettings(confirm: false, deadline: 600)

    private let oldID = UUID(), newID = UUID()
    private let project = URL(fileURLWithPath: "/p/proj")
    private lazy var block = ExecutionBlock(kind: "tests", harness: "claude", model: "opus", pool: "claude-default",
                                            source: AssignmentSource(by: .rule, reason: "r", at: Date(timeIntervalSince1970: 0)))
    private lazy var oldLease = AccountLease(pool: "claude-default", account: UsageRefs.work)
    private lazy var newLease = AccountLease(pool: "claude-default", account: UsageRefs.spare)
    private lazy var agent = SwarmAgentSnapshot(session: SessionRef(id: oldID, agentName: "BlueLake"), agentName: "BlueLake",
                                                block: block, lease: oldLease, task: TaskRef(id: "fd-3x9", project: project))
    private lazy var request = HandoffRequest(task: TaskRef(id: "fd-3x9", project: project), block: block, oldAgent: "BlueLake",
                                              oldSession: agent.session,
                                              transcript: TranscriptPointer(locator: .path("/t.jsonl"), format: "JSONL", howToRead: "Read the last 200 lines first."),
                                              reservedFiles: ["Sources/A.swift"], fromAccount: UsageRefs.work)

    override func setUp() {
        clock = UsageTestClock()
        planner = FakeHandoffPlanner(); allocator = FakePoolAllocator(); router = FakeRouter()
        spawner = FakeSwarmSpawner(); host = FakeHandoffHost()
        planner.requests[oldID] = request
        allocator.leases["claude-default"] = [newLease]
        spawner.results = [.success(SessionRef(id: newID, agentName: "GreenFox"))]
    }

    private func driver() -> HandoffDriver {
        let c = clock!
        return HandoffDriver(planner: planner, allocator: allocator, router: router, spawner: spawner, host: host,
                             settings: { [unowned self] in self.settings }, now: { c.now })
    }

    func testAnIdleAgentIsHandedOffAtOnceInSpecOrder() async {
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(spawner.calls.first?.lease, newLease)
        XCTAssertEqual(spawner.calls.first?.block, block)
        XCTAssertEqual(spawner.calls.first?.firstPrompt, HandoffPrompt.render(request))
        XCTAssertEqual(host.reassigned.map { $0.agent }, ["GreenFox"])
        XCTAssertEqual(host.released, ["BlueLake"])
        XCTAssertEqual(host.stopped, [oldID])
        XCTAssertEqual(host.marked.map { $0.new }, [newID])
        XCTAssertEqual(allocator.released, [oldLease], "the old lease goes back only after the new agent exists")
        XCTAssertEqual(host.log.map(\.outcome), [.handedOff])
        XCTAssertEqual(host.log.first?.fromAccount, "Work"); XCTAssertEqual(host.log.first?.toAccount, "Spare")
        XCTAssertEqual(d.phases[oldID], .done(SessionRef(id: newID, agentName: "GreenFox")))
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1, "a finished hand-off never runs twice")
    }

    func testABusyAgentWaitsForItsTurnToEnd() async {
        host.activities[oldID] = .busy
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 0)
        clock.advance(60); host.activities[oldID] = .idle
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(host.interrupted, [])
    }

    func testTheDeadlineInterruptsABusyAgent() async {
        host.activities[oldID] = .busy
        let d = driver()
        await d.evaluate([agent])
        clock.advance(599); await d.evaluate([agent])
        XCTAssertEqual(host.interrupted, [])
        clock.advance(1); await d.evaluate([agent])
        XCTAssertEqual(host.interrupted, [oldID])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(host.log.map(\.outcome), [.interrupted, .handedOff])
    }

    /// Review focus: Escape in a permission dialog is a denial, and a denial restarts a turn on
    /// the exhausted account. At the deadline the agent is handed off as it stands.
    func testDeadlineDuringAPermissionDialogHandsOffWithoutEscape() async {
        host.activities[oldID] = .waiting
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 0, "a dialog is not a turn boundary")
        clock.advance(600); await d.evaluate([agent])
        XCTAssertEqual(host.interrupted, [])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(host.stopped, [oldID])
    }

    func testARateLimitRejectionIsABoundary() async {
        host.activities[oldID] = .busy; host.rateLimited = [oldID]
        await driver().evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(host.interrupted, [])
    }

    func testConfirmOnAsksOnceThenProceeds() async {
        settings.confirm = true
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertEqual(host.confirmations.count, 1)
        XCTAssertEqual(spawner.calls.count, 1)
    }

    func testDeclineLeavesTheAgentAndDoesNotAskAgainThisCrossing() async {
        settings.confirm = true; host.confirmAnswer = false
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent]); await d.evaluate([agent])
        XCTAssertEqual(host.confirmations.count, 1)
        XCTAssertEqual(spawner.calls.count, 0)
        XCTAssertEqual(host.stopped, [])
        XCTAssertEqual(d.phases[oldID], .declined)
        XCTAssertEqual(host.log.map(\.outcome), [.declined])
    }

    func testANewCrossingAsksAgain() async {
        settings.confirm = true; host.confirmAnswer = false
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        planner.requests[oldID] = nil
        await d.evaluate([agent])
        XCTAssertNil(d.phases[oldID], "below hard: the crossing is over")
        planner.requests[oldID] = request
        await d.evaluate([agent])
        XCTAssertEqual(host.confirmations.count, 2)
    }

    func testNoAccountFreeSpillsThroughTheRouter() async {
        allocator.leases["claude-default"] = []
        let spilled = ExecutionBlock(kind: "tests", harness: "codex", model: "gpt-6-sol", pool: "codex-default",
                                     source: AssignmentSource(by: .spill, reason: "claude-default exhausted", at: Date(timeIntervalSince1970: 0)))
        let kind = TaskKind(id: "tests", name: "Tests", description: "d", dimensions: ["test-authoring": 0.9], origin: .seed, createdAt: Date(timeIntervalSince1970: 0))
        host.kinds["tests"] = kind
        router.spills["tests"] = Assignment(block: spilled)
        let codexLease = AccountLease(pool: "codex-default", account: UsageRefs.codex)
        allocator.leases["codex-default"] = [codexLease]
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertEqual(router.spillCalls.map { $0.1 }, [["claude-default"]])
        XCTAssertEqual(spawner.calls.first?.block, spilled)
        XCTAssertEqual(spawner.calls.first?.lease, codexLease)
    }

    func testAPinnedBlockWaitsAndTheAgentStays() async {
        var pinned = block; pinned.pinned = true
        var pinnedAgent = agent; pinnedAgent.block = pinned
        allocator.leases["claude-default"] = []
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([pinnedAgent]); await d.evaluate([pinnedAgent])
        XCTAssertEqual(spawner.calls.count, 0)
        XCTAssertEqual(host.stopped, [])
        XCTAssertEqual(router.spillCalls.count, 0, "a pinned block never spills")
        guard case .waitingForCapacity(let reason)? = d.phases[oldID] else { return XCTFail("\(String(describing: d.phases[oldID]))") }
        XCTAssertTrue(reason.contains("pinned"))
        XCTAssertEqual(host.log.map(\.outcome), [.waitingForCapacity], "logged once, not every tick")

        allocator.leases["claude-default"] = [newLease]
        await d.evaluate([pinnedAgent])
        XCTAssertEqual(spawner.calls.count, 1, "capacity came back: the next boundary hands off")
    }

    func testSpillFindingNothingWaits() async {
        allocator.leases["claude-default"] = []
        host.kinds["tests"] = TaskKind(id: "tests", name: "Tests", description: "d", dimensions: [:], origin: .seed, createdAt: Date(timeIntervalSince1970: 0))
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 0)
        guard case .waitingForCapacity? = d.phases[oldID] else { return XCTFail() }
    }

    func testASpawnFailureKeepsTheOldAgentAndRetriesAtTheNextBoundary() async {
        spawner.results = [.failure(.launchFailed("no composer")), .success(SessionRef(id: newID, agentName: "GreenFox"))]
        allocator.leases["claude-default"] = [newLease, AccountLease(pool: "claude-default", account: UsageRefs.spare)]
        host.activities[oldID] = .idle
        let d = driver()
        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1)
        XCTAssertEqual(allocator.released, [newLease], "the lease taken for the failed spawn goes back")
        XCTAssertEqual(host.stopped, []); XCTAssertEqual(host.reassigned.count, 0)
        XCTAssertEqual(host.notices, ["Hand-off failed"])
        XCTAssertEqual(d.phases[oldID], .failed)

        await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 1, "still idle: not a new boundary")
        host.activities[oldID] = .busy; await d.evaluate([agent])
        host.activities[oldID] = .idle; await d.evaluate([agent])
        XCTAssertEqual(spawner.calls.count, 2)
        XCTAssertEqual(host.stopped, [oldID])
    }

    func testAMissingTranscriptStillHandsOff() async {
        var bare = request; bare.transcript = nil
        planner.requests[oldID] = bare
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertTrue(spawner.calls.first?.firstPrompt.contains("Its transcript is not available.") ?? false)
    }

    func testTheHostsReservationListWins() async {
        host.reserved = ["Sources/B.swift"]
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertTrue(spawner.calls.first?.firstPrompt.contains("Re-reserve these files before editing: Sources/B.swift.") ?? false)
    }

    func testAnUnnamedNewAgentSkipsReassignAndSaysWhy() async {
        spawner.results = [.success(SessionRef(id: newID, agentName: nil))]
        host.activities[oldID] = .idle
        await driver().evaluate([agent])
        XCTAssertEqual(host.reassigned.count, 0)
        XCTAssertTrue(host.log.first?.detail?.contains("assignee") ?? false)
    }
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `FD_TEST_FILTER=HandoffDriverTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'HandoffDriver' in scope`.

- [ ] **Step 4: Implement `HandoffDriver.swift`**

```swift
import Foundation
import IntakeKit

/// Spec L3-U §5 as a state machine, one agent at a time: wait for a turn boundary (or the
/// deadline), optionally confirm, lease the next account or spill, spawn the new agent with the
/// hand-off prompt, then reassign, release, stop and mark the old one.
///
/// Ordering is the safety property. Nothing about the old agent changes until the new one exists:
/// a spawn that fails leaves the old agent running, still assigned, on its account — the task is
/// never orphaned between two agents.
@MainActor
final class HandoffDriver {
    enum Phase: Equatable {
        case waitingForBoundary(since: Date)
        case waitingForCapacity(String)
        case declined
        case failed
        case done(SessionRef)
    }

    private(set) var phases: [UUID: Phase] = [:]
    private var confirmed: Set<UUID> = []
    private var workedSinceFailure: Set<UUID> = []
    private var inFlight: Set<UUID> = []

    private let planner: HandoffPlanner
    private let allocator: PoolAllocator
    private let router: Router?
    private let spawner: SwarmSpawner
    private let host: HandoffHost
    private let settings: () -> HandoffSettings
    private let now: () -> Date

    init(planner: HandoffPlanner, allocator: PoolAllocator, router: Router?, spawner: SwarmSpawner, host: HandoffHost,
         settings: @escaping () -> HandoffSettings, now: @escaping () -> Date = Date.init) {
        self.planner = planner; self.allocator = allocator; self.router = router; self.spawner = spawner
        self.host = host; self.settings = settings; self.now = now
    }

    func evaluate(_ agents: [SwarmAgentSnapshot]) async {
        for agent in agents { await evaluate(agent) }
    }

    private func evaluate(_ agent: SwarmAgentSnapshot) async {
        let id = agent.session.id
        guard !inFlight.contains(id) else { return }
        if case .done? = phases[id] { return }
        let activity = host.activity(of: agent.session)
        guard let request = planner.request(for: agent) else {
            // Below hard again: this crossing is over. A decline, a failure or a wait from it must
            // not carry into the next one (§5.2: "does not ask again *for this crossing*").
            phases[id] = nil; confirmed.remove(id); workedSinceFailure.remove(id)
            return
        }
        switch phases[id] {
        case .done?, .declined?:
            return
        case .failed?:
            // "Retried at the next boundary" (§7): the agent must work again and stop again, or a
            // spawn that keeps failing would be retried on every tick.
            if activity == .busy { workedSinceFailure.insert(id); return }
            guard workedSinceFailure.contains(id), isBoundary(activity, agent) else { return }
            workedSinceFailure.remove(id)
            await handOff(agent, request)
        case .waitingForCapacity?:
            // The agent keeps working where it is (§5.3); try again whenever it is between turns.
            guard isBoundary(activity, agent) else { return }
            await handOff(agent, request)
        case .waitingForBoundary(let since)?:
            await waitOrGo(agent, request, activity: activity, since: since)
        case nil:
            let since = now()
            phases[id] = .waitingForBoundary(since: since)
            await waitOrGo(agent, request, activity: activity, since: since)
        }
    }

    /// Idle, no agent at all, or refused by the API (it is stuck anyway, §5.1).
    private func isBoundary(_ activity: SessionActivity?, _ agent: SwarmAgentSnapshot) -> Bool {
        activity == nil || activity == .idle || host.isRateLimited(agent.session)
    }

    private func waitOrGo(_ agent: SwarmAgentSnapshot, _ request: HandoffRequest, activity: SessionActivity?, since: Date) async {
        if !isBoundary(activity, agent) {
            guard now().timeIntervalSince(since) >= settings().deadline else { return }
            if activity == .busy {
                host.interrupt(agent.session)
                record(.interrupted, agent, request, detail: "deadline reached mid-turn")
            }
            // `.waiting`: a dialog is open, so the agent is not generating. Escape would answer it
            // as a denial and start a new turn on the exhausted account — hand off as it stands;
            // retiring the old agent deals with the dialog.
        }
        await handOff(agent, request)
    }

    private func handOff(_ agent: SwarmAgentSnapshot, _ original: HandoffRequest) async {
        let id = agent.session.id
        inFlight.insert(id)
        defer { inFlight.remove(id) }

        if settings().confirm && !confirmed.contains(id) {
            guard await host.confirm(original) else {
                phases[id] = .declined
                record(.declined, agent, original, detail: nil)
                return
            }
            confirmed.insert(id)
        }
        guard let resolved = await capacity(for: agent, original) else { return }
        let (block, lease) = resolved

        var request = original
        if let files = await host.reservedFiles(of: agent.agentName, project: request.task.project) { request.reservedFiles = files }
        let result = await spawner.spawn(task: request.task, block: block, lease: lease, firstPrompt: HandoffPrompt.render(request))

        switch result {
        case .failure(let error):
            allocator.release(lease)
            phases[id] = .failed
            workedSinceFailure.remove(id)
            record(.spawnFailed, agent, request, to: lease.account, detail: "\(error)")
            host.notify(title: "Hand-off failed",
                        body: "\(agent.agentName) keeps task \(request.task.id) on \(request.fromAccount.label). Flight Control tries again at its next turn boundary.",
                        session: agent.session)
        case .success(let fresh):
            var warnings: [String] = []
            if let name = fresh.agentName {
                if let w = await host.reassign(task: request.task, to: name) { warnings.append(w) }
            } else {
                warnings.append("the new agent has no name yet, so the task's assignee was not changed")
            }
            if let w = await host.releaseReservations(of: agent.agentName, project: request.task.project) { warnings.append(w) }
            await host.stopAgent(agent.session)
            host.markHandedOff(agent.session, to: fresh)
            if let old = agent.lease { allocator.release(old) }
            phases[id] = .done(fresh)
            record(.handedOff, agent, request, to: lease.account, fresh: fresh,
                   detail: warnings.isEmpty ? nil : warnings.joined(separator: "; "))
        }
    }

    /// §5.3: the next account in the same pool; else L3-R's spill; a pinned block waits.
    private func capacity(for agent: SwarmAgentSnapshot, _ request: HandoffRequest) async -> (ExecutionBlock, AccountLease)? {
        let pool = agent.block.pool
        if let lease = allocator.lease(pool: pool) { return (agent.block, lease) }
        if agent.block.pinned {
            return wait(agent, request, "pinned to pool \(pool), and every account in it is past its limit")
        }
        guard let router, let kind = host.kind(for: agent.block, project: request.task.project) else {
            return wait(agent, request, "no account in pool \(pool) has headroom")
        }
        let catalogs = await host.catalogs()
        guard let spilled = router.spill(agent.block, kind: kind, project: request.task.project, exhausted: [pool],
                                         catalogs: catalogs, now: now()) else {
            return wait(agent, request, "no account in pool \(pool) has headroom, and no other model fits")
        }
        guard let lease = allocator.lease(pool: spilled.block.pool) else {
            return wait(agent, request, "spilled to pool \(spilled.block.pool), which has no account free either")
        }
        return (spilled.block, lease)
    }

    private func wait(_ agent: SwarmAgentSnapshot, _ request: HandoffRequest, _ reason: String) -> (ExecutionBlock, AccountLease)? {
        if phases[agent.session.id] != .waitingForCapacity(reason) {
            phases[agent.session.id] = .waitingForCapacity(reason)
            record(.waitingForCapacity, agent, request, detail: reason)
        }
        return nil
    }

    private func record(_ outcome: HandoffLogEntry.Outcome, _ agent: SwarmAgentSnapshot, _ request: HandoffRequest,
                        to: AccountRef? = nil, fresh: SessionRef? = nil, detail: String?) {
        host.record(HandoffLogEntry(at: now(), outcome: outcome, task: request.task.id, oldSession: agent.session.id,
                                    oldAgent: agent.agentName, newSession: fresh?.id, newAgent: fresh?.agentName,
                                    fromAccount: request.fromAccount.label, toAccount: to?.label, detail: detail))
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `FD_TEST_FILTER=HandoffDriverTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Usage/HandoffDriver.swift Tests/FlightDeckTests/FlightControlL3/Usage/FakeHandoffHost.swift Tests/FlightDeckTests/FlightControlL3/Usage/HandoffDriverTests.swift
git commit -m "feat: hand a swarm agent off to the next account at its turn boundary" -m "Waits for idle or a rate-limit refusal, interrupts a busy turn at the deadline (never a dialog), confirms when asked, leases the next account or spills, and only touches the old agent after the new one exists." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Meter view models and views

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Usage/MeterViews.swift`
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/MeterFormatterTests.swift`

**Interfaces:**
- Consumes: `CapacityLedger`, `CapacityPool`, L3-0 `AccountHeadroom`, `HeadroomState`, `UsageReading`.
- Produces:
  - `struct AccountMeterModel: Identifiable, Equatable { id: String; label: String; fraction: Double?; state: HeadroomState; soft: Double; hard: Double; resetText: String?; sourceText: String?; detail: String?; var percentText: String; var accessibilityValue: String }`
  - `struct PoolMeterModel: Identifiable, Equatable { id: PoolID; title: String; isLocal: Bool; accounts: [AccountMeterModel]; note: String? }`
  - `enum MeterFormatter { static func age(_:) -> String; static func resetText(_:now:timeZone:locale:) -> String?; static func account(_:pool:reading:error:now:timeZone:locale:) -> AccountMeterModel; static func pools(_ ledger: CapacityLedger, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [PoolMeterModel]; static func rowMeter(account: UUID, ledger: CapacityLedger, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> AccountMeterModel? }`
  - Views (L3-S mounts them at integration): `MeterTrack`, `AccountMeterBar(model:)` (identifier `meter-bar`), `PoolMeterList(pools:)` (identifier `pool-meter-<pool id>`), `RowMiniMeter(model:)` (identifier `row-mini-meter`; draws nothing for `nil`).

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// What a meter says is decided here, not in SwiftUI, so it can be pinned: the percentages, the
/// reset time in the viewer's clock, the source and its age, "no reading" versus "stale", and
/// when the sidebar row shows a meter at all (only past soft).
final class MeterFormatterTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")
    private let pool = CapacityPool.hosted(id: "claude-default", label: "Claude default", harness: "claude", accounts: [UsageRefs.workID, UsageRefs.spareID])

    func testAgeWording() {
        XCTAssertEqual(MeterFormatter.age(5), "just now")
        XCTAssertEqual(MeterFormatter.age(-30), "just now", "a reading from slightly ahead of this clock is new")
        XCTAssertEqual(MeterFormatter.age(180), "3 min ago")
        XCTAssertEqual(MeterFormatter.age(2 * 3600 + 5), "2 h ago")
        XCTAssertEqual(MeterFormatter.age(3 * 86_400), "3 d ago")
    }

    func testResetTextUsesTheViewersClock() {
        let now = usageISO("2026-10-04T19:00:00Z")
        XCTAssertEqual(MeterFormatter.resetText(usageISO("2026-10-04T23:00:00Z"), now: now, timeZone: utc, locale: posix), "resets 11:00 PM")
        XCTAssertEqual(MeterFormatter.resetText(usageISO("2026-10-09T00:00:00Z"), now: now, timeZone: utc, locale: posix), "resets Fri 12:00 AM")
        XCTAssertNil(MeterFormatter.resetText(usageISO("2026-10-04T18:00:00Z"), now: now, timeZone: utc, locale: posix), "a past reset says nothing useful")
        XCTAssertNil(MeterFormatter.resetText(nil, now: now, timeZone: utc, locale: posix))
    }

    func testAFreshAccount() {
        let now = usageISO("2026-10-04T19:00:00Z")
        let reading = UsageReading(account: UsageRefs.work, windows: [UsageWindow(name: "five_hour", utilization: 0.824, resetsAt: usageISO("2026-10-04T23:00:00Z"))],
                                   readAt: now.addingTimeInterval(-180), source: "claude mod", hardRejection: false)
        let h = AccountHeadroom(account: UsageRefs.work, worstUtilization: 0.824, state: .overSoft, resetsAt: usageISO("2026-10-04T23:00:00Z"))
        let m = MeterFormatter.account(h, pool: pool, reading: reading, error: nil, now: now, timeZone: utc, locale: posix)
        XCTAssertEqual(m.percentText, "82%")
        XCTAssertEqual(m.soft, 0.80); XCTAssertEqual(m.hard, 0.95)
        XCTAssertEqual(m.resetText, "resets 11:00 PM")
        XCTAssertEqual(m.sourceText, "claude mod · 3 min ago")
        XCTAssertNil(m.detail)
        XCTAssertEqual(m.accessibilityValue, "82 percent used, past its soft limit, resets 11:00 PM")
    }

    func testUnknownSaysWhy() {
        let now = Date()
        let h = AccountHeadroom(account: UsageRefs.spare, worstUtilization: nil, state: .unknown, resetsAt: nil)
        XCTAssertEqual(MeterFormatter.account(h, pool: pool, reading: nil, error: nil, now: now).detail, "no reading")
        let stale = UsageRefs.reading(UsageRefs.spare, 0.5, at: now.addingTimeInterval(-3600))
        XCTAssertEqual(MeterFormatter.account(h, pool: pool, reading: stale, error: nil, now: now).detail, "reading is stale")
        XCTAssertEqual(MeterFormatter.account(h, pool: pool, reading: nil, error: "Codex app-server: transportClosed", now: now).detail,
                       "Codex app-server: transportClosed", "a source error is the more useful sentence")
        let m = MeterFormatter.account(h, pool: pool, reading: nil, error: nil, now: now)
        XCTAssertNil(m.fraction); XCTAssertEqual(m.percentText, "—"); XCTAssertEqual(m.accessibilityValue, "no reading")
    }

    func testPoolsAndTheLocalNote() {
        let ledger = CapacityLedger()
        let local = CapacityPool.local(id: "ollama", label: "Ollama", harness: "opencode", endpoint: "http://localhost:11434")
        ledger.configure(pools: [pool, local], accounts: [UsageRefs.work, UsageRefs.spare])
        _ = ledger.lease(pool: "ollama")
        let models = MeterFormatter.pools(ledger, now: Date())
        XCTAssertEqual(models.map(\.id), ["claude-default", "ollama"])
        XCTAssertEqual(models[0].accounts.map(\.label), ["Work", "Spare"])
        XCTAssertEqual(models[1].note, "1 of 2 agents running on http://localhost:11434. Load from outside Flight Deck is not visible.")
        XCTAssertTrue(models[1].isLocal)
    }

    func testTheRowMeterAppearsOnlyPastSoftAndPicksTheWorstPool() {
        let ledger = CapacityLedger()
        let strict = CapacityPool.hosted(id: "strict", label: "Strict", harness: "claude", accounts: [UsageRefs.workID], soft: 0.5, hard: 0.6)
        ledger.configure(pools: [pool, strict], accounts: [UsageRefs.work, UsageRefs.spare])
        let now = Date()
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.40, at: now))
        XCTAssertNil(MeterFormatter.rowMeter(account: UsageRefs.workID, ledger: ledger, now: now))
        ledger.ingest(UsageRefs.reading(UsageRefs.work, 0.62, at: now.addingTimeInterval(1)))
        let m = MeterFormatter.rowMeter(account: UsageRefs.workID, ledger: ledger, now: now.addingTimeInterval(1))
        XCTAssertEqual(m?.state, .overHard, "the strict pool rates it worst")
        XCTAssertEqual(m?.hard, 0.6)
        XCTAssertNil(MeterFormatter.rowMeter(account: UsageRefs.spareID, ledger: ledger, now: now), "unknown draws nothing")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=MeterFormatterTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'MeterFormatter' in scope`.

- [ ] **Step 3: Implement `MeterViews.swift`**

```swift
import SwiftUI
import IntakeKit

/// One account's bar, decided outside SwiftUI so `MeterFormatterTests` can pin every word.
struct AccountMeterModel: Identifiable, Equatable {
    let id: String
    let label: String
    /// Nil is unknown: the bar is drawn empty and grey.
    let fraction: Double?
    let state: HeadroomState
    let soft: Double
    let hard: Double
    let resetText: String?
    let sourceText: String?
    let detail: String?

    var percentText: String { fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }

    /// What VoiceOver says, and what the UI test reads, so both describe the same state.
    var accessibilityValue: String {
        guard let fraction else { return detail ?? "no reading" }
        var parts = ["\(Int((fraction * 100).rounded())) percent used"]
        switch state {
        case .underSoft: parts.append("has headroom")
        case .overSoft: parts.append("past its soft limit")
        case .overHard: parts.append("past its hard limit")
        case .unknown: break
        }
        if let resetText { parts.append(resetText) }
        if let detail { parts.append(detail) }
        return parts.joined(separator: ", ")
    }
}

struct PoolMeterModel: Identifiable, Equatable {
    let id: PoolID
    let title: String
    let isLocal: Bool
    let accounts: [AccountMeterModel]
    let note: String?
}

enum MeterFormatter {
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86_400: return "\(Int(s / 3600)) h ago"
        default: return "\(Int(s / 86_400)) d ago"
        }
    }

    static func resetText(_ date: Date?, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard let date, date > now else { return nil }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = date.timeIntervalSince(now) < 86_400 ? "h:mm a" : "EEE h:mm a"
        return "resets \(f.string(from: date))"
    }

    static func account(_ h: AccountHeadroom, pool: CapacityPool, reading: UsageReading?, error: String?, now: Date,
                        timeZone: TimeZone = .current, locale: Locale = .current) -> AccountMeterModel {
        let detail: String?
        if let error { detail = error }
        else if h.state == .unknown { detail = reading == nil ? "no reading" : "reading is stale" }
        else { detail = nil }
        // A local pool's bar is slots in use; soft/hard ticks mean nothing there, so they sit at
        // the end of the track.
        let isLocal = pool.kind == .local
        return AccountMeterModel(
            id: "\(pool.id.rawValue)|\(h.account.id?.uuidString ?? "slot")",
            label: h.account.label,
            fraction: h.state == .unknown ? nil : h.worstUtilization,
            state: h.state,
            soft: isLocal ? 1 : pool.softThreshold,
            hard: isLocal ? 1 : pool.hardThreshold,
            resetText: resetText(h.resetsAt, now: now, timeZone: timeZone, locale: locale),
            sourceText: reading.map { "\($0.source) · \(age(now.timeIntervalSince($0.readAt)))" },
            detail: detail)
    }

    static func pools(_ ledger: CapacityLedger, now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> [PoolMeterModel] {
        ledger.allPools.map { pool in
            let rows = ledger.headroom(pool: pool.id).map { h in
                account(h, pool: pool,
                        reading: h.account.id.flatMap { ledger.latestReading(account: $0) },
                        error: h.account.id.flatMap { ledger.sourceError(account: $0) },
                        now: now, timeZone: timeZone, locale: locale)
            }
            // The spec's caveat, said where the number is: FD counts only its own agents.
            let note: String? = pool.kind == .local
                ? "\(ledger.activeLeases(pool: pool.id).count) of \(pool.concurrencyCap) agents running on \(pool.endpoint ?? "this endpoint"). Load from outside Flight Deck is not visible."
                : nil
            return PoolMeterModel(id: pool.id, title: pool.label, isLocal: pool.kind == .local, accounts: rows, note: note)
        }
    }

    /// The sidebar row's small meter (L3-U §6): only past soft, from whichever pool holding the
    /// account rates it worst — the row warns at the earliest threshold anyone set.
    static func rowMeter(account id: UUID, ledger: CapacityLedger, now: Date,
                         timeZone: TimeZone = .current, locale: Locale = .current) -> AccountMeterModel? {
        var best: AccountMeterModel?
        for pool in ledger.allPools where pool.kind == .hosted && pool.accounts.contains(id) {
            guard let h = ledger.headroom(pool: pool.id).first(where: { $0.account.id == id }),
                  h.state == .overSoft || h.state == .overHard else { continue }
            let m = account(h, pool: pool, reading: ledger.latestReading(account: id), error: ledger.sourceError(account: id),
                            now: now, timeZone: timeZone, locale: locale)
            if best.map({ severity(m) > severity($0) }) ?? true { best = m }
        }
        return best
    }

    private static func severity(_ m: AccountMeterModel) -> Double { (m.state == .overHard ? 2 : 1) + (m.fraction ?? 0) }
}

/// The bar itself: fill by state, ticks at soft and hard.
struct MeterTrack: View {
    let fraction: Double?
    let soft: Double
    let hard: Double
    let state: HeadroomState

    static func color(for state: HeadroomState) -> Color {
        switch state {
        case .underSoft: return .green
        case .overSoft: return .orange
        case .overHard: return .red
        case .unknown: return .gray
        }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                if let fraction {
                    Capsule().fill(Self.color(for: state)).frame(width: max(2, width * min(max(fraction, 0), 1)))
                }
                tick(at: soft, width: width)
                tick(at: hard, width: width)
            }
        }
    }

    private func tick(at t: Double, width: CGFloat) -> some View {
        Rectangle().fill(Color.primary.opacity(0.55)).frame(width: 1).offset(x: width * min(max(t, 0), 1) - 0.5)
    }
}

/// One account in the project header's pool popover and in Settings → Capacity.
struct AccountMeterBar: View {
    let model: AccountMeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.label).font(.callout).lineLimit(1)
                Spacer(minLength: 8)
                Text(model.percentText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            MeterTrack(fraction: model.fraction, soft: model.soft, hard: model.hard, state: model.state).frame(height: 6)
            Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("meter-bar")
        .accessibilityLabel(model.label)
        .accessibilityValue(model.accessibilityValue)
    }

    private var caption: String { [model.resetText, model.sourceText, model.detail].compactMap { $0 }.joined(separator: " · ") }
}

/// The project header's pool popover body (L3-S mounts it in the popover at integration).
struct PoolMeterList: View {
    let pools: [PoolMeterModel]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if pools.isEmpty {
                Text("No pools yet. Add an account in Settings → Agents.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(pools) { pool in
                VStack(alignment: .leading, spacing: 8) {
                    Text(pool.title).font(.headline)
                    ForEach(pool.accounts) { AccountMeterBar(model: $0) }
                    if let note = pool.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("pool-meter-\(pool.id.rawValue)")
            }
        }
    }
}

/// The sidebar row's small meter. Draws nothing for nil — an account under soft, or unknown,
/// is not the row's business.
struct RowMiniMeter: View {
    let model: AccountMeterModel?

    var body: some View {
        if let model {
            MeterTrack(fraction: model.fraction, soft: model.soft, hard: model.hard, state: model.state)
                .frame(width: 28, height: 4)
                .help("\(model.label): \(model.accessibilityValue)")
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("row-mini-meter")
                .accessibilityLabel("\(model.label) usage")
                .accessibilityValue(model.accessibilityValue)
        }
    }
}

#if DEBUG
enum MeterPreviewData {
    static let pools: [PoolMeterModel] = [
        PoolMeterModel(id: "claude-default", title: "Claude default", isLocal: false, accounts: [
            AccountMeterModel(id: "a", label: "Work", fraction: 0.82, state: .overSoft, soft: 0.8, hard: 0.95,
                              resetText: "resets 11:00 PM", sourceText: "claude mod · 3 min ago", detail: nil),
            AccountMeterModel(id: "b", label: "Spare", fraction: nil, state: .unknown, soft: 0.8, hard: 0.95,
                              resetText: nil, sourceText: nil, detail: "no reading"),
        ], note: nil),
        PoolMeterModel(id: "codex-default", title: "Codex default", isLocal: false, accounts: [
            AccountMeterModel(id: "c", label: "Codex", fraction: 0.97, state: .overHard, soft: 0.8, hard: 0.95,
                              resetText: "resets 10:00 PM", sourceText: "codex app-server · 1 min ago", detail: nil),
        ], note: nil),
    ]
}

#Preview("Pool meters") { PoolMeterList(pools: MeterPreviewData.pools).padding().frame(width: 320) }
#Preview("Row meter") { RowMiniMeter(model: MeterPreviewData.pools[1].accounts[0]).padding() }
#endif
```

- [ ] **Step 4: Run to verify it passes, plus the terminology guard**

Run: `FD_TEST_FILTER=MeterFormatterTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Usage/MeterViews.swift Tests/FlightDeckTests/FlightControlL3/Usage/MeterFormatterTests.swift
git commit -m "feat: draw account usage as bars with soft and hard ticks" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 17: Settings → Capacity, the fixture and the Meter Gallery

**Files:**
- Create: `Sources/FlightDeck/FlightControl/Usage/CapacityEditing.swift`
- Create: `Sources/FlightDeck/Preferences/UI/CapacityPane.swift`
- Create: `Sources/FlightDeck/FlightControl/Usage/UsageFixture.swift` (DEBUG only)
- Modify: `Sources/FlightDeck/Preferences/PreferencesTab.swift` (`case capacity`)
- Modify: `Sources/FlightDeck/Preferences/UI/PreferencesView.swift` (the tab)
- Modify: `Sources/FlightDeck/AppDelegate.swift` (fixture + gallery in `startUsage`)
- Test: `Tests/FlightDeckTests/FlightControlL3/Usage/CapacityEditingTests.swift`

**Interfaces:**
- Consumes: Tasks 8, 13, 16; `RoutingCapabilityRegistry`, `AccountModel` (L3-0).
- Produces:
  - `enum CapacityEditing` — `newPoolID(existing:random:)`, `materialize(_:accounts:)`, `addHostedPool(_:agent:accounts:random:) -> PoolID`, `addLocalPool(_:harness:accounts:random:) -> PoolID`, `removePool(_:_:accounts:) -> Bool`, `rename(_:to:_:accounts:)`, `setThresholds(_:soft:hard:_:accounts:)`, `toggle(_:in:_:accounts:)`, `move(in:from:to:_:accounts:)`, `setCap(_:_:_:accounts:)`, `setEndpoint(_:_:_:accounts:)` (each `inout CapacityPreferences` in the third/fourth position as written below)
  - `struct CapacityPane: View { init(preferences:usage:localHarnesses:); static func defaultLocalHarnesses() -> [HarnessID] }`
  - `PreferencesTab.capacity`
  - DEBUG: `enum UsageFixture { static let workID, spareID, codexID: UUID; static var isRequested: Bool; static var isGalleryRequested: Bool; static func install(into:preferences:now:) }`, `struct MeterGallery: View`, `enum MeterGalleryWindow { static func show(usage:) -> NSWindow }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// Every Settings edit is a pure function over `CapacityPreferences`, so the pane is a thin
/// binding and these pin the rules: default pools cannot be deleted, ids are minted once and
/// never reused for a different pool, thresholds can never cross, and the first edit of a
/// default pool stores it without losing what it held.
@MainActor
final class CapacityEditingTests: XCTestCase {
    private let accounts = [
        AgentAccount(id: UsageRefs.workID, agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/tmp/fd-edit/w")),
        AgentAccount(id: UsageRefs.spareID, agent: .claude, displayName: "Spare", home: URL(fileURLWithPath: "/tmp/fd-edit/s")),
    ]
    private func fixedUUIDs(_ texts: [String]) -> () -> UUID {
        var queue = texts.map { UUID(uuidString: $0)! }
        return { queue.removeFirst() }
    }

    func testNewIDsArePrefixedHexAndSkipTakenOnes() {
        let next = fixedUUIDs(["ABCDEF12-0000-0000-0000-000000000000", "12345678-0000-0000-0000-000000000000"])
        XCTAssertEqual(CapacityEditing.newPoolID(existing: ["pool-abcdef12"], random: next), "pool-12345678")
    }

    func testAddingAHostedPoolStoresTheDefaultsToo() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addHostedPool(&prefs, agent: .claude, accounts: accounts,
                                               random: fixedUUIDs(["ABCDEF12-0000-0000-0000-000000000000"]))
        XCTAssertEqual(id, "pool-abcdef12")
        XCTAssertEqual(prefs.pools?.map(\.id), ["claude-default", "pool-abcdef12"])
        XCTAssertEqual(prefs.pools?.last?.label, "New Claude pool")
        XCTAssertEqual(prefs.pools?.last?.accounts, [])
        XCTAssertEqual(prefs.pools?.first?.accounts, [UsageRefs.workID, UsageRefs.spareID])
    }

    func testAddingALocalPoolUsesTheDefaultCap() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addLocalPool(&prefs, harness: "opencode", accounts: accounts,
                                              random: fixedUUIDs(["0000AAAA-0000-0000-0000-000000000000"]))
        let pool = prefs.pools?.first { $0.id == id }
        XCTAssertEqual(pool?.kind, .local); XCTAssertEqual(pool?.concurrencyCap, 2); XCTAssertEqual(pool?.endpoint, "http://localhost:11434")
    }

    func testDefaultPoolsCannotBeRemovedUserPoolsCan() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addHostedPool(&prefs, agent: .claude, accounts: accounts)
        XCTAssertFalse(CapacityEditing.removePool("claude-default", &prefs, accounts: accounts))
        XCTAssertTrue(CapacityEditing.removePool(id, &prefs, accounts: accounts))
        XCTAssertEqual(prefs.pools?.map(\.id), ["claude-default"])
    }

    func testRenameTrimsAndIgnoresEmpty() {
        var prefs = CapacityPreferences()
        CapacityEditing.rename("claude-default", to: "  Day shift ", &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.first?.label, "Day shift")
        XCTAssertEqual(prefs.pools?.first?.id, "claude-default", "renaming never changes the id blocks store")
        CapacityEditing.rename("claude-default", to: "   ", &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.first?.label, "Day shift")
    }

    func testThresholdsNeverCross() {
        var prefs = CapacityPreferences()
        CapacityEditing.setThresholds("claude-default", soft: 0.97, hard: 0.95, &prefs, accounts: accounts)
        let p = prefs.pools?.first
        XCTAssertEqual(p?.hardThreshold ?? 0, 0.95, accuracy: 1e-9)
        XCTAssertEqual(p?.softThreshold ?? 0, 0.90, accuracy: 1e-9)
        XCTAssertNoThrow(try p?.validate())
        CapacityEditing.setThresholds("claude-default", soft: 0.0, hard: 2.0, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.first?.softThreshold ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(prefs.pools?.first?.hardThreshold ?? 0, 1.0, accuracy: 1e-9)
    }

    func testToggleAndMoveAccounts() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addHostedPool(&prefs, agent: .claude, accounts: accounts)
        CapacityEditing.toggle(UsageRefs.workID, in: id, &prefs, accounts: accounts)
        CapacityEditing.toggle(UsageRefs.spareID, in: id, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.accounts, [UsageRefs.workID, UsageRefs.spareID])
        CapacityEditing.move(in: id, from: IndexSet(integer: 1), to: 0, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.accounts, [UsageRefs.spareID, UsageRefs.workID])
        CapacityEditing.toggle(UsageRefs.spareID, in: id, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.accounts, [UsageRefs.workID])
    }

    func testCapAndEndpointClamp() {
        var prefs = CapacityPreferences()
        let id = CapacityEditing.addLocalPool(&prefs, harness: "opencode", accounts: accounts)
        CapacityEditing.setCap(id, 0, &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.concurrencyCap, 1)
        CapacityEditing.setEndpoint(id, " http://box:11434 ", &prefs, accounts: accounts)
        XCTAssertEqual(prefs.pools?.last?.endpoint, "http://box:11434")
    }

    func testNoLocalHarnessIsRegisteredOnMaster() {
        XCTAssertEqual(CapacityPane.defaultLocalHarnesses(), [], "claude and codex are both .login; OpenCode adds the first local one")
    }

    func testTheFixtureSeedsThreeAccountsAndTwoReadings() {
        let preferences = PreferencesStore(persistence: nil)
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)
        let usage = UsageService(environment: .live(store: store, preferences: preferences))
        UsageFixture.install(into: usage, preferences: preferences, now: Date())
        XCTAssertEqual(preferences.preferences.accounts.map(\.displayName), ["Work", "Spare", "Codex"],
                       "seeded accounts carry real email addresses; a screenshot must never show them")
        XCTAssertEqual(usage.ledger.headroom(pool: "claude-default").map(\.state), [.overSoft, .unknown])
        XCTAssertEqual(usage.ledger.headroom(pool: "codex-default").map(\.state), [.overHard])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `FD_TEST_FILTER=CapacityEditingTests ./scripts/test-unit.sh 2>&1 | tail -40`
Expected: build error `cannot find 'CapacityEditing' in scope`.

- [ ] **Step 3: Implement `CapacityEditing.swift`**

```swift
import SwiftUI
import IntakeKit

/// The Capacity pane's edits as pure functions, so the pane is a thin binding and the rules are
/// testable: default pools cannot be removed, ids are minted once, thresholds never cross.
///
/// Every edit first materializes the pools in force: the default pools are derived until the
/// user touches one, and the first touch must store them whole rather than store an empty list.
enum CapacityEditing {
    static func newPoolID(existing: [PoolID], random: () -> UUID = UUID.init) -> PoolID {
        while true {
            let id = PoolID("pool-\(random().uuidString.prefix(8).lowercased())")
            if !existing.contains(id) { return id }
        }
    }

    static func materialize(_ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        prefs.pools = prefs.effectivePools(accounts: accounts)
    }

    private static func edit(_ id: PoolID, _ prefs: inout CapacityPreferences, accounts: [AgentAccount],
                             _ change: (inout CapacityPool) -> Void) {
        materialize(&prefs, accounts: accounts)
        guard let i = prefs.pools?.firstIndex(where: { $0.id == id }) else { return }
        change(&prefs.pools![i])
    }

    @discardableResult
    static func addHostedPool(_ prefs: inout CapacityPreferences, agent: AgentID, accounts: [AgentAccount],
                              random: () -> UUID = UUID.init) -> PoolID {
        materialize(&prefs, accounts: accounts)
        let id = newPoolID(existing: prefs.pools?.map(\.id) ?? [], random: random)
        prefs.pools?.append(.hosted(id: id, label: "New \(agent.displayName) pool", harness: agent.harnessID, accounts: []))
        return id
    }

    @discardableResult
    static func addLocalPool(_ prefs: inout CapacityPreferences, harness: HarnessID, accounts: [AgentAccount],
                             random: () -> UUID = UUID.init) -> PoolID {
        materialize(&prefs, accounts: accounts)
        let id = newPoolID(existing: prefs.pools?.map(\.id) ?? [], random: random)
        prefs.pools?.append(.local(id: id, label: "New local pool", harness: harness, endpoint: "http://localhost:11434"))
        return id
    }

    /// A default pool is every account's home; removing it would leave an agent's tasks with no
    /// pool to name.
    @discardableResult
    static func removePool(_ id: PoolID, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) -> Bool {
        materialize(&prefs, accounts: accounts)
        guard let i = prefs.pools?.firstIndex(where: { $0.id == id }), prefs.pools?[i].isDefault == false else { return false }
        prefs.pools?.remove(at: i)
        return true
    }

    static func rename(_ id: PoolID, to label: String, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit(id, &prefs, accounts: accounts) { $0.label = trimmed }
    }

    /// Hard in 0.10…1.0; soft in 0.05…hard−0.05. Clamped rather than refused, so a stepper can
    /// never leave the pool in a state `CapacityPool.validate` rejects.
    static func setThresholds(_ id: PoolID, soft: Double, hard: Double, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        let h = min(max(hard, 0.10), 1.0)
        let s = min(max(soft, 0.05), h - 0.05)
        edit(id, &prefs, accounts: accounts) { $0.hardThreshold = h; $0.softThreshold = s }
    }

    static func toggle(_ account: UUID, in id: PoolID, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        edit(id, &prefs, accounts: accounts) { pool in
            if let i = pool.accounts.firstIndex(of: account) { pool.accounts.remove(at: i) } else { pool.accounts.append(account) }
        }
    }

    static func move(in id: PoolID, from: IndexSet, to: Int, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        edit(id, &prefs, accounts: accounts) { $0.accounts.move(fromOffsets: from, toOffset: to) }
    }

    static func setCap(_ id: PoolID, _ cap: Int, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        edit(id, &prefs, accounts: accounts) { $0.concurrencyCap = min(max(cap, 1), 64) }
    }

    static func setEndpoint(_ id: PoolID, _ endpoint: String, _ prefs: inout CapacityPreferences, accounts: [AgentAccount]) {
        edit(id, &prefs, accounts: accounts) { $0.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
```

- [ ] **Step 4: Implement `CapacityPane.swift`**

```swift
import SwiftUI
import IntakeKit

/// Settings → Capacity (L3-U §6): pools and the order inside each, thresholds, local caps,
/// "Confirm hand-offs" and the hand-off deadline, with the live meters of the selected pool.
struct CapacityPane: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var usage: UsageService
    /// Adapters with no accounts (`AccountModel.none`) can have local pools. None on master;
    /// the OpenCode adapter brings the first.
    let localHarnesses: [HarnessID]
    @State private var selection: PoolID?

    init(preferences: PreferencesStore, usage: UsageService, localHarnesses: [HarnessID]) {
        self.preferences = preferences; self.usage = usage; self.localHarnesses = localHarnesses
    }

    /// `AccountModel.none` spelled out: `.none` here would compare against `Optional.none`.
    @MainActor
    static func defaultLocalHarnesses() -> [HarnessID] {
        let registry = RoutingCapabilityRegistry.standard()
        return registry.harnesses.filter { registry.capabilities(for: $0)?.accountModel == AccountModel.none }
    }

    private var accounts: [AgentAccount] { preferences.preferences.accounts }
    private var pools: [CapacityPool] { preferences.capacity.effectivePools(accounts: accounts) }
    private var selected: CapacityPool? { pools.first { $0.id == (selection ?? pools.first?.id) } }

    private func edit(_ change: (inout CapacityPreferences, [AgentAccount]) -> Void) {
        let snapshot = accounts
        preferences.updateCapacity { change(&$0, snapshot) }
    }

    var body: some View {
        HStack(spacing: 0) {
            poolList.frame(width: 210)
            Divider()
            ScrollView { detail.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private var poolList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(pools) { pool in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pool.label)
                        Text(pool.kind == .local ? "Local · \(pool.harness.rawValue)" : "\(pool.accounts.count) accounts · \(pool.harness.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(pool.id)
                }
            }
            .accessibilityIdentifier("capacity-pool-list")
            HStack(spacing: 4) {
                Menu {
                    ForEach(AgentID.allCases, id: \.self) { agent in
                        Button("\(agent.displayName) pool") {
                            edit { prefs, accts in selection = CapacityEditing.addHostedPool(&prefs, agent: agent, accounts: accts) }
                        }
                    }
                    ForEach(localHarnesses, id: \.self) { harness in
                        Button("Local \(harness.rawValue) pool") {
                            edit { prefs, accts in selection = CapacityEditing.addLocalPool(&prefs, harness: harness, accounts: accts) }
                        }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("capacity-add-pool")
                Button {
                    guard let id = selected?.id else { return }
                    edit { prefs, accts in _ = CapacityEditing.removePool(id, &prefs, accounts: accts) }
                    selection = nil
                } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
                    .disabled(selected?.isDefault ?? true)
                    .help("Default pools cannot be removed")
                    .accessibilityIdentifier("capacity-remove-pool")
                Spacer()
            }
            .padding(6)
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let pool = selected {
                TextField("Name", text: Binding(get: { pool.label },
                                                set: { v in edit { CapacityEditing.rename(pool.id, to: v, &$0, accounts: $1) } }))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("capacity-pool-name")
                if pool.kind == .hosted { hostedEditor(pool) } else { localEditor(pool) }
            }
            Divider()
            handoffSettings
            Divider()
            Text("Current usage").font(.headline)
            let _ = usage.revision
            PoolMeterList(pools: MeterFormatter.pools(usage.ledger, now: Date()).filter { $0.id == selected?.id })
        }
    }

    @ViewBuilder
    private func hostedEditor(_ pool: CapacityPool) -> some View {
        Text("Accounts, in lease order").font(.headline)
        List {
            ForEach(pool.accounts, id: \.self) { id in
                HStack {
                    Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    Text(accounts.first { $0.id == id }?.displayName ?? "Removed account")
                    Spacer()
                    Button("Remove") { edit { CapacityEditing.toggle(id, in: pool.id, &$0, accounts: $1) } }.buttonStyle(.borderless)
                }
            }
            .onMove { from, to in edit { CapacityEditing.move(in: pool.id, from: from, to: to, &$0, accounts: $1) } }
        }
        .frame(minHeight: 90, maxHeight: 160)
        .accessibilityIdentifier("capacity-accounts")
        let others = accounts.filter { $0.agent.harnessID == pool.harness && !$0.isRemoved && !pool.accounts.contains($0.id) }
        if !others.isEmpty {
            Menu("Add account") {
                ForEach(others) { a in Button(a.displayName) { edit { CapacityEditing.toggle(a.id, in: pool.id, &$0, accounts: $1) } } }
            }
            .fixedSize()
        }
        Stepper(value: Binding(get: { Int((pool.softThreshold * 100).rounded()) },
                               set: { v in edit { CapacityEditing.setThresholds(pool.id, soft: Double(v) / 100, hard: pool.hardThreshold, &$0, accounts: $1) } }),
                in: 5...99) {
            Text("New work stops at \(Int((pool.softThreshold * 100).rounded()))% (soft)")
        }
        .accessibilityIdentifier("capacity-soft")
        Stepper(value: Binding(get: { Int((pool.hardThreshold * 100).rounded()) },
                               set: { v in edit { CapacityEditing.setThresholds(pool.id, soft: pool.softThreshold, hard: Double(v) / 100, &$0, accounts: $1) } }),
                in: 10...100) {
            Text("Agents hand off at \(Int((pool.hardThreshold * 100).rounded()))% (hard)")
        }
        .accessibilityIdentifier("capacity-hard")
    }

    @ViewBuilder
    private func localEditor(_ pool: CapacityPool) -> some View {
        TextField("Endpoint", text: Binding(get: { pool.endpoint ?? "" },
                                            set: { v in edit { CapacityEditing.setEndpoint(pool.id, v, &$0, accounts: $1) } }))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("capacity-endpoint")
        Stepper(value: Binding(get: { pool.concurrencyCap },
                               set: { v in edit { CapacityEditing.setCap(pool.id, v, &$0, accounts: $1) } }),
                in: 1...64) {
            Text("Up to \(pool.concurrencyCap) agents at once")
        }
        .accessibilityIdentifier("capacity-cap")
        Text("Flight Deck counts only the agents it runs here. Load from outside Flight Deck is not visible.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var handoffSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hand-offs").font(.headline)
            Toggle("Confirm hand-offs", isOn: Binding(get: { preferences.capacity.handoffSettings.confirm },
                                                      set: { v in preferences.updateCapacity { $0.confirmHandoffs = v } }))
                .accessibilityIdentifier("capacity-confirm-handoffs")
            let minutes = (preferences.capacity.handoffDeadlineSeconds ?? CapacityPreferences.defaultDeadlineSeconds) / 60
            Stepper(value: Binding(get: { minutes }, set: { m in preferences.updateCapacity { $0.handoffDeadlineSeconds = max(1, m) * 60 } }),
                    in: 1...60) {
                Text("Interrupt a busy agent after \(minutes) min")
            }
            .accessibilityIdentifier("capacity-deadline")
            Text("Your own tabs are never handed off. When their account passes its hard limit, you get one notification.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 5: Add the tab**

`PreferencesTab`: add `case capacity` after `case devices`.

`PreferencesView`: after the Devices tab, add

```swift
            CapacityPane(preferences: preferences, usage: UsageService.shared,
                         localHarnesses: CapacityPane.defaultLocalHarnesses())
                .tabItem { Label("Capacity", systemImage: "gauge.with.dots.needle.33percent") }
                .accessibilityIdentifier("prefs-capacity")
                .tag(PreferencesTab.capacity)
```

- [ ] **Step 6: Implement `UsageFixture.swift` (DEBUG)**

```swift
#if DEBUG
import AppKit
import SwiftUI
import IntakeKit

/// Fixture readings for the capacity UI test (L3-U §8). `-FlightControlUsageFixture YES` is
/// honored only together with `-FlightDeckResetState YES`, so it can never touch a real deck's
/// accounts. It *replaces* the seeded accounts: in reset mode those are read from `$HOME` and
/// carry real email addresses, which must never land in a screenshot.
@MainActor
enum UsageFixture {
    static let workID = UUID(uuidString: "F1000000-0000-0000-0000-000000000001")!
    static let spareID = UUID(uuidString: "F1000000-0000-0000-0000-000000000002")!
    static let codexID = UUID(uuidString: "F1000000-0000-0000-0000-000000000003")!

    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "FlightDeckResetState") && UserDefaults.standard.bool(forKey: "FlightControlUsageFixture")
    }

    static var isGalleryRequested: Bool {
        UserDefaults.standard.bool(forKey: "FlightDeckResetState") && UserDefaults.standard.bool(forKey: "FlightControlMeterGallery")
    }

    static func install(into usage: UsageService, preferences: PreferencesStore, now: Date = Date()) {
        let root = URL(fileURLWithPath: "/tmp/fd-usage-fixture", isDirectory: true)
        preferences.preferences.accounts = [
            AgentAccount(id: workID, agent: .claude, displayName: "Work", home: root.appendingPathComponent("claude-work")),
            AgentAccount(id: spareID, agent: .claude, displayName: "Spare", home: root.appendingPathComponent("claude-spare")),
            AgentAccount(id: codexID, agent: .codex, displayName: "Codex", home: root.appendingPathComponent("codex")),
        ]
        usage.reconfigure()
        let refs = preferences.preferences.accounts.map(CapacityPreferences.accountRef)
        usage.ingest(UsageReading(account: refs[0],
                                  windows: [UsageWindow(name: "five_hour", utilization: 0.82, resetsAt: now.addingTimeInterval(2 * 3600)),
                                            UsageWindow(name: "seven_day", utilization: 0.31, resetsAt: now.addingTimeInterval(3 * 86_400))],
                                  readAt: now.addingTimeInterval(-180), source: "claude mod", hardRejection: false))
        usage.ingest(UsageReading(account: refs[2],
                                  windows: [UsageWindow(name: "five_hour", utilization: 0.97, resetsAt: now.addingTimeInterval(3600)),
                                            UsageWindow(name: "seven_day", utilization: 0.40, resetsAt: now.addingTimeInterval(5 * 86_400))],
                                  readAt: now.addingTimeInterval(-60), source: "codex app-server", hardRejection: false))
        // Spare gets no reading: the grey "no reading" bar.
    }
}

/// The pool popover and the sidebar row meter, hosted on their own because L3-S mounts them in
/// the header and the row only at integration — the UI test still has to see them drawn.
struct MeterGallery: View {
    @ObservedObject var usage: UsageService

    var body: some View {
        let _ = usage.revision
        let now = Date()
        VStack(alignment: .leading, spacing: 16) {
            Text("Pool popover").font(.headline)
            PoolMeterList(pools: MeterFormatter.pools(usage.ledger, now: now))
                .padding(12).frame(width: 320)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                .accessibilityIdentifier("gallery-popover")
            Text("Sidebar rows").font(.headline)
            HStack { Text("Codex tab"); Spacer(); RowMiniMeter(model: MeterFormatter.rowMeter(account: UsageFixture.codexID, ledger: usage.ledger, now: now)) }
                .frame(width: 260)
            HStack { Text("Spare tab"); Spacer(); RowMiniMeter(model: MeterFormatter.rowMeter(account: UsageFixture.spareID, ledger: usage.ledger, now: now)) }
                .frame(width: 260)
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 440)
    }
}

enum MeterGalleryWindow {
    @MainActor
    static func show(usage: UsageService) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Meter Gallery"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MeterGallery(usage: usage))
        window.center()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}
#endif
```

- [ ] **Step 7: Wire the fixture into `startUsage`**

In `AppDelegate`, add a stored property (DEBUG only) beside the other window/panel properties:

```swift
    #if DEBUG
    /// The capacity UI test's Meter Gallery (L3-U); held so it is not released when shown.
    private var meterGallery: NSWindow?
    #endif
```

and extend `startUsage(store:)` after `attach`:

```swift
        #if DEBUG
        if UsageFixture.isRequested { UsageFixture.install(into: UsageService.shared, preferences: preferences) }
        if UsageFixture.isGalleryRequested { meterGallery = MeterGalleryWindow.show(usage: UsageService.shared) }
        #endif
```

- [ ] **Step 8: Run to verify it passes, with the preferences and terminology suites**

Run: `FD_TEST_FILTER=CapacityEditingTests,PreferencesTabTests,TerminologyGuardTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `** SHARDED UNIT RUN PASSED`.

Then build the app (no launch): `./scripts/build.sh 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.
This is the first task that adds SwiftUI the unit suite does not render; a compile error here is
cheaper than inside the UI test run.

- [ ] **Step 9: Commit**

```bash
git add Sources/FlightDeck/FlightControl/Usage/CapacityEditing.swift Sources/FlightDeck/Preferences/UI/CapacityPane.swift Sources/FlightDeck/FlightControl/Usage/UsageFixture.swift Sources/FlightDeck/Preferences/PreferencesTab.swift Sources/FlightDeck/Preferences/UI/PreferencesView.swift Sources/FlightDeck/AppDelegate.swift Tests/FlightDeckTests/FlightControlL3/Usage/CapacityEditingTests.swift
git commit -m "feat: edit capacity pools, thresholds and hand-off settings in settings" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: XCUITest for the meters and the Capacity pane, with screenshots

**Files:**
- Create: `UITests/FlightDeckUITests/CapacityUITests.swift`
- Create: `scripts/test-ui-capacity.sh` (executable)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the launch arguments and accessibility identifiers from Tasks 16–17.
- Produces: one UI test, skipped unless `TEST_RUNNER_FLIGHTDECK_CAPACITY_UI=1`, run only by
  `scripts/test-ui-capacity.sh`; screenshots exported to `scripts/.capacity-ui-shots/`.

- [ ] **Step 1: Verify the UI-test conventions this copies**

Run: `rg -n "FlightDeckResetState|environmentValue|preferencesWindow|typeKey\(\",\"" UITests/FlightDeckUITests/*.swift | head; rg -n "only-testing|derivedDataPath|throttle" scripts/smoke.sh`
Expected: `ScreenshotTests` reads env under both spellings (`X` and `TEST_RUNNER_X`), the smoke
tests find Settings by a tab button and open it with ⌘,, and `smoke.sh` sources `throttle.sh`
and uses `-derivedDataPath DerivedData`. The script below mirrors those.

- [ ] **Step 2: Write the UI test**

```swift
import XCTest

/// Flight Control's capacity surfaces in the real app, against fixture readings, with a
/// screenshot at each state (L3-U §8). The pool popover and the row meter are drawn in the
/// DEBUG "Meter Gallery" window because L3-S mounts them in the header and the row only at
/// integration; the Capacity pane is the real Settings tab.
///
/// Skipped unless `scripts/test-ui-capacity.sh` asks for it: a UI test takes the foreground, so
/// it never runs inside the smoke gate.
final class CapacityUITests: XCTestCase {
    private func environmentValue(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[name] ?? environment["TEST_RUNNER_\(name)"]
    }

    private func shoot(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func bar(_ label: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any).matching(identifier: "meter-bar")
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testMetersAndCapacityPane() throws {
        guard environmentValue("FLIGHTDECK_CAPACITY_UI") == "1" else {
            throw XCTSkip("FLIGHTDECK_CAPACITY_UI unset; run scripts/test-ui-capacity.sh")
        }
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-FlightDeckResetState", "YES",
            "-FlightControlUsageFixture", "YES",
            "-FlightControlMeterGallery", "YES",
        ]
        app.launch()
        app.activate()

        XCTContext.runActivity(named: "the pool popover draws one bar per account, with its state") { _ in
            let gallery = app.windows["Meter Gallery"]
            XCTAssertTrue(gallery.waitForExistence(timeout: 20), "the gallery window did not open")
            XCTAssertTrue(bar("Work", in: gallery).waitForExistence(timeout: 10))
            XCTAssertTrue((bar("Work", in: gallery).value as? String ?? "").contains("82 percent used, past its soft limit"))
            XCTAssertEqual(bar("Spare", in: gallery).value as? String, "no reading")
            XCTAssertTrue((bar("Codex", in: gallery).value as? String ?? "").contains("past its hard limit"))
            shoot(gallery, "pool-popover")
        }

        XCTContext.runActivity(named: "the row meter appears only past soft") { _ in
            let gallery = app.windows["Meter Gallery"]
            let meters = gallery.descendants(matching: .any).matching(identifier: "row-mini-meter")
            XCTAssertEqual(meters.count, 1, "the Codex row is past hard; the Spare row is unknown and draws nothing")
            shoot(gallery, "row-meter")
        }

        XCTContext.runActivity(named: "Settings → Capacity lists the default pools and takes edits") { _ in
            app.typeKey(",", modifierFlags: .command)
            let prefs = app.windows.containing(.button, identifier: "Capacity").firstMatch
            XCTAssertTrue(prefs.waitForExistence(timeout: 10), "Settings did not open with a Capacity tab")
            prefs.buttons["Capacity"].click()
            XCTAssertTrue(prefs.descendants(matching: .any).matching(identifier: "capacity-pool-list").firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(prefs.staticTexts["Claude default"].exists)
            XCTAssertTrue(prefs.staticTexts["Codex default"].exists)
            XCTAssertTrue(bar("Work", in: prefs).exists, "the pane embeds the same bar the popover draws")
            shoot(prefs, "capacity-pane")

            let confirm = prefs.checkBoxes["capacity-confirm-handoffs"]
            XCTAssertEqual(confirm.value as? Int, 0, "Confirm hand-offs defaults off")
            confirm.click()
            XCTAssertEqual(confirm.value as? Int, 1)

            prefs.descendants(matching: .any).matching(identifier: "capacity-add-pool").firstMatch.click()
            app.menuItems["Claude pool"].click()
            XCTAssertTrue(prefs.staticTexts["New Claude pool"].waitForExistence(timeout: 5))
            shoot(prefs, "capacity-pane-edited")
        }
    }
}
```

- [ ] **Step 3: Write `scripts/test-ui-capacity.sh`**

```bash
#!/usr/bin/env bash
# Runs CapacityUITests (Flight Control L3-U) and exports its screenshots.
#
# A UI test takes the foreground and types into whatever holds focus, so this warns first,
# shares smoke.sh's throttle, and is never part of the smoke gate. Run it once; never loop it.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

. scripts/throttle.sh

LOG="scripts/.capacity-ui.log"
RESULT="scripts/.capacity-ui.xcresult"
SHOTS="scripts/.capacity-ui-shots"
: > "$LOG"
rm -rf "$RESULT" "$SHOTS"

echo "[capacity-ui] building… (full output → $LOG)"
if ! ./scripts/build.sh >>"$LOG" 2>&1; then
  echo "CAPACITY UI FAIL: build failed — see $LOG"; tail -n 30 "$LOG"; exit 1
fi
xcodegen generate >>"$LOG" 2>&1

osascript -e 'display notification "The capacity UI test takes the foreground in 10 seconds." with title "Flight Deck tests"' >/dev/null 2>&1 || true
echo "[capacity-ui] taking the foreground in 10 s for about a minute (Ctrl-C to cancel)"
sleep 10

set +e
TEST_RUNNER_FLIGHTDECK_CAPACITY_UI=1 xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -destination 'platform=macOS' -derivedDataPath DerivedData -resultBundlePath "$RESULT" \
  test -only-testing:FlightDeckUITests/CapacityUITests >>"$LOG" 2>&1
rc=$?
set -e

grep -E "Test Case '.*' (passed|failed|skipped)|XCTAssert|error:|\*\* TEST (SUCCEEDED|FAILED)" "$LOG" | tail -n 40 || true

mkdir -p "$SHOTS"
if xcrun xcresulttool export attachments --path "$RESULT" --output-path "$SHOTS" >>"$LOG" 2>&1; then
  echo "[capacity-ui] screenshots: $SHOTS"
else
  echo "[capacity-ui] could not export screenshots with this Xcode; open $RESULT in Xcode"
fi

if [ "$rc" -ne 0 ]; then echo "CAPACITY UI FAIL (rc=$rc) — full log: $LOG"; exit "$rc"; fi
echo "CAPACITY UI PASS"
```

Then `chmod +x scripts/test-ui-capacity.sh` and append to `.gitignore`:

```
scripts/.capacity-ui.log
scripts/.capacity-ui.xcresult/
scripts/.capacity-ui-shots/
```

- [ ] **Step 4: Confirm the test is skipped where it must be**

Run: `rg -n "FLIGHTDECK_CAPACITY_UI" UITests scripts`
Expected: the guard in the test and the variable in the script only. (`smoke.sh` runs the whole
`FlightDeckUITests` bundle, so without the guard this test would ride every smoke run.)

- [ ] **Step 5: Run it once**

Tell the maintainer in one line, ~10 s ahead, that a UI test is about to take the foreground (the script
also posts a notification). Then run: `./scripts/test-ui-capacity.sh`
Expected: `Test Case '-[FlightDeckUITests.CapacityUITests testMetersAndCapacityPane]' passed`,
`CAPACITY UI PASS`, and four PNGs in `scripts/.capacity-ui-shots/` (`pool-popover`,
`row-meter`, `capacity-pane`, `capacity-pane-edited`). Open each with the Read tool and check
that no real email address appears (the fixture replaces the seeded accounts). On failure, read
`scripts/.capacity-ui.log`; do not re-run in a loop (AGENTS.md rule 4) — fix the cause, then run
once more.

- [ ] **Step 6: Commit**

```bash
git add UITests/FlightDeckUITests/CapacityUITests.swift scripts/test-ui-capacity.sh .gitignore
git commit -m "test: drive the capacity meters and settings pane in the real app with screenshots" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 19: Live meter tests (skipped by default)

**Files:**
- Create: `Tests/FlightDeckTests/FlightControlL3/Usage/UsageLiveTests.swift`

**Interfaces:**
- Consumes: `CodexProcessTransport(home:)`, `.start()`, `.stop()`, `.onTerminate`, `CodexProcessTransport.verifyHandshake(_:timeoutSeconds:)`, `CodexRPC`, `CodexRateLimitParser`, `ModUsageFile`, the bundled `ClaudePlugin`.
- Produces: two tests that run only with `USAGE_LIVE=1`.

- [ ] **Step 1: Write the live tests**

```swift
import XCTest
import IntakeKit
@testable import FlightDeck

/// The meters against the real binaries, because both vendors' payloads are claims that expire
/// (see the "codex behaviour claims expire" note). Skipped unless `USAGE_LIVE=1` (or
/// `TEST_RUNNER_USAGE_LIVE=1`). The codex test spends no tokens; the claude test runs one tiny
/// headless turn on the built-in account.
@MainActor
final class UsageLiveTests: XCTestCase {
    private var live: Bool {
        let e = ProcessInfo.processInfo.environment
        return e["USAGE_LIVE"] == "1" || e["TEST_RUNNER_USAGE_LIVE"] == "1"
    }

    func testCodexAppServerReadsTheRealAccountsRateLimits() async throws {
        guard live else { throw XCTSkip("set USAGE_LIVE=1") }
        let transport = CodexProcessTransport(home: AgentID.codex.builtInHome)
        let rpc = CodexRPC(transport: transport)
        transport.onTerminate = { [weak rpc] in rpc?.transportClosed() }
        do { try transport.start() } catch { throw XCTSkip("codex app-server did not start: \(error)") }
        defer { transport.stop() }
        try await CodexProcessTransport.verifyHandshake(rpc, timeoutSeconds: 15)
        let result = try await rpc.request("account/rateLimits/read", [:])
        let buckets = CodexRateLimitParser.readResponse(result)
        XCTAssertFalse(buckets.isEmpty, "a ChatGPT login reports at least one bucket; got \(result)")
        let reading = try XCTUnwrap(CodexRateLimitParser.reading(buckets, account: AccountRef(harness: "codex", id: UUID(), label: "live"), readAt: Date()))
        XCTAssertFalse(reading.windows.isEmpty)
        for w in reading.windows { XCTAssertTrue((0...1.5).contains(w.utilization), "\(w.name) = \(w.utilization)") }
    }

    /// Only meaningful when probe 2 found that headless `claude -p` fires `session.measure`
    /// (Outcome 4C). On 4D this test is deleted and the real-tab check is the maintainer's (Task 20).
    func testTheBundledModWritesAUsageFileForARealTurn() throws {
        guard live else { throw XCTSkip("set USAGE_LIVE=1") }
        // Outcome 1B: the mod is `ClaudeUsagePlugin`; pass it as a second --plugin-dir below.
        let plugin = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ClaudePlugin", withExtension: nil))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fd-usage-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tab = UUID()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["claude", "-p", "Reply with the single word ok.", "--plugin-dir", plugin.path]
        var env = ProcessInfo.processInfo.environment
        // Probing claude from inside claude: without this the child runs as a nested session.
        env.removeValue(forKey: "CLAUDE_CODE_CHILD_SESSION"); env.removeValue(forKey: "CLAUDECODE")
        env["FLIGHT_DECK_USAGE_DIR"] = dir.path
        env["FLIGHT_DECK_SESSION_ID"] = tab.uuidString
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw XCTSkip("claude is not runnable here: \(error)") }
        p.waitUntilExit()

        let data = try Data(contentsOf: dir.appendingPathComponent("\(tab.uuidString).json"))
        let file = try XCTUnwrap(ModUsageFile.decode(data))
        XCTAssertEqual(file.tab, tab.uuidString)
        XCTAssertFalse(file.windows.isEmpty, "a subscription login reports five_hour and seven_day")
        for w in file.windows { XCTAssertTrue((0...1.5).contains(w.utilization), "\(w.name) = \(w.utilization)") }
    }
}
```

- [ ] **Step 2: Verify the transport API this uses**

Run: `rg -n "init\(executable: String = \"codex\", home: URL\? = nil\)|func start\(\) throws|func stop\(\)|var onTerminate" Sources/FlightDeck/Agents/Codex/CodexProcessTransport.swift`
Expected: four hits. If `onTerminate` is spelled differently, use the hook `CodexStack.init` sets.

- [ ] **Step 3: Run skipped, then live once**

Run: `FD_TEST_FILTER=UsageLiveTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `PASSED` with both tests skipped.

Run (one real read, one tiny turn): `USAGE_LIVE=1 FD_TEST_FILTER=UsageLiveTests ./scripts/test-unit.sh 2>&1 | tail -20`
Expected: `PASSED`, both executed. If `test-unit.sh` does not forward `USAGE_LIVE`, use
`TEST_RUNNER_USAGE_LIVE=1`. A codex failure here that probe 3 did not show is a real drift:
capture the response into the spec's follow-up notes; do not loosen the parser test.

- [ ] **Step 4: Commit**

```bash
git add Tests/FlightDeckTests/FlightControlL3/Usage/UsageLiveTests.swift
git commit -m "test: check both usage meters against the real codex and claude, opt-in" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 20: Full suite, spec notes, FOLLOWUPS, merge readiness

**Files:**
- Modify: `docs/superpowers/specs/2026-10-04-flight-control-l3-usage-rollover-design.md` (§12)
- Modify: `docs/FOLLOWUPS.md` (the Level 3 entry)

- [ ] **Step 1: Run the whole unit suite**

Run: `./scripts/test-unit.sh 2>&1 | tee /tmp/l3-u-unit.log | tail -5; rg -n "error:" /tmp/l3-u-unit.log | head`
Expected: `** SHARDED UNIT RUN PASSED` and no `error:` lines. A failure in a test this branch did
not touch: run that class on master first (`git stash` is forbidden — use a second worktree)
before blaming this branch. Budget ~8 minutes; `FD_TEST_FILTER` does not shorten the full run.

- [ ] **Step 2: Validate and test the mod once more**

Run: `claude plugin validate Resources/ClaudePlugin && env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE claude plugin test Resources/ClaudePlugin`
Expected: valid; 5 passed. (Outcome 1B: `Resources/ClaudeUsagePlugin`.)

- [ ] **Step 3: Record the deviations and integration notes in the spec**

Under the §12 heading Task 1 created, after "Probe results", append:

```markdown
### Plan deviations (L3-U plan, 2026-10-04)

1. Codex is polled (`account/rateLimits/read`, ≤ every 120 s per account with a live codex tab)
   as well as pushed: pushes only reach the connection that ran the turn, and FD's turns run in
   a `codex resume` TUI.
2. Usage files live in `~/Library/Application Support/Flight Deck/usage-<debug|release>/`,
   passed as `FLIGHT_DECK_USAGE_DIR`; a file is keyed by the FD tab id
   (`FLIGHT_DECK_SESSION_ID`) or, without it, claude's session id.
3. Every meter funnels through `UsageService` into `CapacityLedger`. A hard rejection is a
   `UsageReading` with `hardRejection: true`; its worst window's `resetsAt` is when it ends.
4. `CapacityLedger` (CapacityReader + PoolAllocator) and `LedgerHandoffPlanner` are IntakeKit
   classes, so their `Sendable` conformance is honest.
5. Settings has a top-level Capacity tab (`PreferencesTab.capacity`), not Flight Control →
   Capacity.
6. `StoreHandoffHost` does interrupt, retire (Escape for an open dialog, then `/exit` or
   `/quit`), `br update --assignee`, `am file_reservations release`, notify and a JSONL log;
   confirmation, kind lookup, catalogs, reservations, the "handed off →" marker and the swarm
   log location are hooks L3-S sets. With Confirm on and no confirmation surface, it declines and
   says so.
7. A window whose `resetsAt` passed after it was read counts as empty; a `resetsAt` at or before
   `readAt` is clock skew and keeps its number.
8. An empty reservation list reads "It held no file reservations. Reserve the files you will
   edit with Agent Mail before you edit them."
9. At the deadline, an agent in a dialog is handed off without Escape.
10. After a spawn failure, the retry waits until the old agent works again and reaches a new
    boundary.
11. "Mod not loaded" = an account's claude tab seen for 15 min with no usage file from any of
    its tabs.
12. The pool popover and row meter are UI-tested in a DEBUG Meter Gallery window; the pane in
    Settings. Script: `scripts/test-ui-capacity.sh`.
13. OpenCode: `OpenCodeAPIErrorEvent` + `OpenCodeErrorUsageSource` ship, tested with fakes; wiring
    waits for the OpenCode branch.
14. The engine's `.claude-plugin/types/` is git-ignored, not committed.
15. A local pool's usage is its unreleased leases (L3-S releases one when its session ends).
16. A failing meter source shows its error at once but keeps a still-fresh reading until it goes
    stale.

### Provided at integration

- `UsageService.shared.ledger` is the `CapacityReader` and `PoolAllocator`;
  `UsageService.shared.planner` is the `HandoffPlanner`.
- L3-S builds `HandoffDriver(planner:allocator:router:spawner:host:settings:now:)` with its
  `SwarmSpawner`, L3-R's `Router`, a `StoreHandoffHost` with the swarm hooks set, and
  `settings: { preferences.capacity.handoffSettings }`, and calls `evaluate(_:)` on its tick.
- L3-S calls `UsageService.shared.setSwarmPredicate { … }`, mounts `PoolMeterList` in the
  header popover and `RowMiniMeter(model: MeterFormatter.rowMeter(account:ledger:now:))` on
  swarm rows, and wires `handoff.confirm`/`handoff.decline` into `StoreHandoffHost.confirmer`.
- The Observe drawer's Assignment lane (L3-S) draws the account with `AccountMeterBar` and the
  hand-off history from the JSONL `StoreHandoffHost` writes (`HandoffLogEntry`, one per line).
- The OpenCode adapter returns an `OpenCodeErrorUsageSource` from `usageMeterSource(account:)`,
  `UsageService.shared.consume(_:)`s it, and points `transcriptPointer` at
  `TranscriptPointers.openCode(sessionID:serverURL:)`.
```

- [ ] **Step 4: Update FOLLOWUPS**

In `docs/FOLLOWUPS.md`, in the "**Level 3 "Operate" — DESIGNED (2026-10-04), not built.**"
entry, add a sentence after its spec list:

```markdown
  L3-U (usage and rollover) built on branch `<branch>` (<sha>): pools, meters (codex app-server
  read every 2 min, the bundled claude mod via `session.measure`, headless seats, the fleet's
  rate-limit API errors), the capacity ledger, the hand-off driver and Settings → Capacity. Not
  yet wired to a swarm (integration). The maintainer's checks after integration: open Settings → Capacity
  and confirm each account's bar matches `/usage` (claude) and codex's own status; run one
  swarm agent on an account near its limit and watch it hand off; confirm a manual tab gets one
  notification and stays put.
```

Add, as separate bullets in the same section, every open item the probes or tasks recorded:
any STOPPED meter (Task 1), Outcome 4D (the real-tab mod check is manual), codex's exit command
if it was not verified (Task 14), and "local-pool capacity cannot see load from outside Flight
Deck" (spec §3, by design).

- [ ] **Step 5: Check the vendor tree and the worktree hygiene**

Run: `git diff master...HEAD --stat -- vendor; git status --short`
Expected: no `vendor` lines (worktree symlinks were never committed) and a clean tree.

Run: `git log --oneline master..HEAD`
Expected: one commit per task (plus Task 2's only on Outcome 3C).

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-10-04-flight-control-l3-usage-rollover-design.md docs/FOLLOWUPS.md
git commit -m "docs: record l3-u usage and rollover as built, with probe results and deviations" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Then finish per `superpowers:finishing-a-development-branch`. Merging to master is the maintainer's call;
the branch is merge-ready when Steps 1–5 hold.
