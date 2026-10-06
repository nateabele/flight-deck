# Flight Control Level 3 — Usage and rollover (L3-U)

Date: 2026-10-04. Status: design approved in brainstorming; spec under review.
Depends on: L3-0 only.

## 1. Goal

Flight Deck knows how much of each hosted account's usage window is used. New work goes to
accounts with headroom. A swarm agent whose account is nearly exhausted is handed off to a fresh
agent on the next account, before it stalls.

**Success criteria:**
1. Each claude and codex account shows its worst-window utilization and reset time, updated from
   live sessions.
2. An account past its soft threshold receives no new lease.
3. A swarm agent on an account past its hard threshold is handed off at its next turn boundary.
   The new agent runs on the next account and is told where the old transcript is and how to read
   it.
4. When every account in a pool is exhausted, new work spills over (L3-R §5) or, if the block is
   pinned, waits with a visible reason.

## 2. Pools

A **pool** is a named group of capacity for one adapter. Defined in Settings → Flight Control →
Capacity.

- **Hosted pool:** an ordered list of that adapter's accounts, a soft threshold (default 0.80)
  and a hard threshold (default 0.95).
- **Local pool:** an endpoint (for example an Ollama URL, for an adapter with
  `accountModel == .none`) and a concurrency cap (default 2).
- **Default pools:** each adapter gets `<adapter>-default`, holding all its accounts in the
  existing account order. A user-made pool may share accounts with another pool. The meter is per
  account, so both pools see the same reading.

Stored in preferences. Pool ids are stable. Renaming a pool changes only its label.

## 3. Meters

A reading is `{account, windows: [{name, utilization 0–1, resetsAt}], readAt, source}`. An
account's **worst window** is the window with the highest utilization in its newest reading.

| Adapter / mode | Source | Status |
|---|---|---|
| codex | the per-account app-server FD already runs: `account/rateLimits/read` at start and on demand, plus `account/rateLimits/updated` pushes. `RateLimitSnapshot.primary` / `.secondary` → `RateLimitWindow {usedPercent, windowDurationMins, resetsAt}`; `rateLimitsByLimitId` gives buckets | schema in `codex-app-server-v2.generated.json`; **first task probes it live** |
| claude interactive | **Flight Deck's status line** (`Resources/ClaudePlugin/scripts/statusline.sh`, installed per tab with `--settings '{"statusLine":…}'`). Claude hands a status line command `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}` on stdin; no hook payload carries them. The script writes the reading to `<FD usage dir>/<FD session id>.json` and then runs the user's own status line on the same stdin. Until 2026-10-06 this was a Claude Code mod on `session.measure` (§12, "Status line replaces the mod") | live-probed on claude 2.1.292 (§12) |
| claude headless (intake seats) | `rate_limit_event.rate_limit_info.unifiedWindows.{five_hour,seven_day}.utilization` | fixtures exist; FD reads only `status` today |
| opencode hosted | no meter. An `APIError` with status 429 marks the account **over hard** until `retry-after`, or a 15-min backoff when there is none | from the OpenCode workstream |
| opencode local | no meter. Capacity = the pool's concurrency cap minus FD's live sessions on that pool | load from outside FD (for example ledger-sync holding Ollama slots) cannot be seen. The pool popover says so |

**FD maps a reading to an account** through the session that produced it (`Session.accountID`,
resolved). The status line never sees account identity.

**Freshness.** A reading older than 30 min is **unknown**. An account with no live session has
no reading, so it is unknown. This is normal for idle accounts.

**Hard rejections override meters.** These mark the account **over hard** at once, whatever the
meter said:
- a `rate_limit_event` with a status that is not `allowed*`;
- codex `rate_limit_exceeded`;
- an OpenCode 429;
- the fleet's `apiError` with a rate-limit kind.

The state clears at `resetsAt`, or with the next reading that is below hard.

## 4. Account states and leases

The state of an account is computed from its newest reading and the pool's thresholds:
`underSoft`, `overSoft`, `overHard` or `unknown`.

**`PoolAllocator.lease(pool)`:**
1. The first account **in pool order** that is `underSoft`.
2. If there is none, the first `unknown` account, in pool order.
3. If there is none, return nil. L3-S then asks L3-R to spill, or makes the task wait if it is
   pinned.

For a local pool, `lease` succeeds while live sessions are below the cap. A lease is released
when its session ends, is handed off, or is reused for a different pool.

## 5. Hand-off

**Trigger.** A **swarm agent's** account becomes `overHard`. Your own manual tabs are never
handed off: they get a meter badge and a one-time notification.

**Steps:**
1. **Wait for a turn boundary.** The agent goes idle, or hits a rate-limit rejection (it is
   stuck anyway). There is a deadline, default 10 min. After the deadline FD interrupts the
   agent (adapter interrupt) and continues.
2. **Confirmation (optional).** When "Confirm hand-offs" is on (default off), the hand-off waits
   for Confirm or Decline on the Mac or the phone. Decline leaves the agent running and does not
   ask again for this crossing.
3. **Lease** the next account in the same pool. If none is free, use L3-R's spill. A pinned
   block waits, and the agent stays where it is.
4. **Build the `HandoffRequest`:**
   - the task id and its execution block;
   - the old agent's name;
   - the **transcript pointer**, from `transcriptPointer(session)`: a path or a command, its
     format, and how to read it. For example "JSONL, one event per line; read the last 200
     lines first";
   - the files the old agent had reserved.
5. **The hand-off prompt** for the new agent (a template in L3-U, filled per request):
   - "You are continuing task <id>, started by <old agent>, which stopped because its account
     reached its usage limit."
   - "Its transcript is at <path> (<format>). Read it to understand what was done and decided."
   - "Run `git status` and `git diff` before changing anything. The work may be half done."
   - "Re-reserve these files before editing: <list>."
   - "Then finish the task as described in `br show <id>`."
6. **Spawn** through L3-S's `SwarmSpawner` with the new lease and the hand-off prompt as the
   first prompt.
7. **Reassign and release.** `br update <id> --assignee <new agent>`. Release the old agent's
   reservations. Stop the old agent's process. Mark the old tab *handed off → <new tab>* and keep
   it open, read-only, for history.
8. **Log** the hand-off in the swarm log, with both accounts and both tabs.

**Transcript pointers per adapter** (verify in the first task):
- claude: the session's JSONL under `<account home>/projects/<project key>/<session id>.jsonl`;
- codex: the rollout path under `<account home>/sessions/`;
- opencode: `opencode export <session id>` against the account's server, or the HTTP messages
  endpoint, given as a command.

All three are on local disk, or reachable on the Mac. The new agent can read them whatever
account it runs on.

## 6. UI (drawn through L3-S's surfaces)

- **Project header popover:** one bar per account in each pool, showing the worst window, ticks
  at soft and hard, the reset time, the source and its age. Unknown accounts are grey with
  "no reading".
- **Sidebar row:** a small meter when the row's account is past soft.
- **Observe drawer, Assignment lane:** the account, its meter, and the hand-off history.
- **Settings → Flight Control → Capacity:** pools, the order inside each pool, thresholds, the local caps,
  "Confirm hand-offs", the hand-off deadline.

## 7. Error handling

- A meter source fails (the app-server is down, the status line did not run): the account becomes
  unknown, and the popover shows the source error.
- The hand-off spawn fails: the old agent is left running, the task stays assigned to it, and
  the failure is logged and notified. The hand-off is retried at the next boundary.
- The transcript pointer is unavailable: the hand-off still runs. The prompt says the transcript
  is not available and leans on `git diff` and the task's notes.

## 8. Testing

- **Meter parsing:** per adapter, against fixtures. This covers the codex snapshot with
  primary/secondary windows and by-limit buckets, claude `unifiedWindows`, the usage file
  format, and OpenCode `APIError` 429 with and without `retry-after`.
- **State and lease logic:** a pure state machine, table-tested over the L3-0 usage timeline
  fixture. This covers order, unknown accounts, hard rejection overriding a meter, reset
  clearing, and the local cap.
- **The hand-off driver:** against fake sessions, a fake spawner and a fake br. It covers the
  idle boundary, the deadline interrupt, confirm on and off, decline, no account free → spill,
  pinned → wait, spawn failure, and a missing transcript pointer.
- **The status line:** `ClaudeStatusLineTests` runs `scripts/statusline.sh` with a synthetic stdin
  and a fake user command (the file written, the user's text passed through byte for byte, no
  rewrite of an unchanged reading), and pins the `--settings` injection and merge.
- **Live, skipped by default** (`USAGE_LIVE=1`):
  - the codex app-server rate-limit read for one real account;
  - the claude status line is not here: headless `claude -p` runs no status line, so it is
    checked with a tmux probe of an interactive claude (§12).
- **UI:** XCUITest for the pool popover, the row meter and the Capacity pane against fixture
  readings, with screenshots.

## 9. First task: probes

1. **The mod loads in an FD-spawned tab.** `Resources/ClaudePlugin/hooks/hooks.json` holds shell
   hooks today. Check that one `hooks.json` can carry both shell hooks and `"modules"`. If it
   cannot, ship the mod as a second bundled plugin directory. Check that a `--plugin-dir` mod
   loads with no hot-reload prompt.
2. **`session.measure` fires** on real traffic in an interactive tab, and its `rateLimits` match
   `/usage`.
3. **The codex app-server** returns `account/rateLimits/read` for a real account, and
   `account/rateLimits/updated` arrives during a turn.

The result of each probe is recorded in the spec's follow-up notes before the meter code that
depends on it is written.

## 10. Provides at integration

Real `CapacityReader`, `PoolAllocator` and `HandoffPlanner`, the meter sources, the status line, and the
Capacity pane.

## 11. Files

- `Sources/IntakeKit/FlightControl/PoolState.swift`, `LeasePolicy.swift`, `HandoffPrompt.swift`
- `Sources/FlightDeck/FlightControl/Usage/UsageService.swift`, `CodexRateLimitSource.swift`,
  `ClaudeUsageFileSource.swift`, `HeadlessClaudeUsageSource.swift`, `OpenCodeErrorUsageSource.swift`,
  `HandoffDriver.swift`
- `Resources/ClaudePlugin/scripts/statusline.sh` and `Sources/FlightDeck/Agents/ClaudeStatusLine.swift`:
  the usage status line (the mod — `hooks/register.ts`, its test — was removed 2026-10-06)
- `Sources/IntakeKit/SeatActivity.swift`: keep `unifiedWindows`, not just `status`
- `Sources/FlightDeck/Preferences/UI/CapacityPane.swift`
- `Tests/FlightDeckTests/FlightControlL3/Usage/…`, `UITests/FlightDeckUITests/CapacityUITests.swift`

## 12. Follow-up notes

### Probe results (L3-U plan Task 1, 2026-10-05)

- Versions: claude 2.1.289 (Claude Code), codex-cli 0.160.0. Mod API types found at
  `/private/tmp/claude-501/bundled-skills/2.1.289/<hash>/plugin-authoring/types/claude-code.d.ts`
  (version-specific). All six patterns present: `'session.measure'`, `SessionMeasureInput`,
  `SessionRateLimit` (`{kind, percentUsed, resetsAt?}`; `percentUsed` is 0–100 with at most one
  decimal, past 100 on an exceeded spend limit), `$.fs.write(path, text)`, `$.env.get(name)`,
  `$.clock.now()`.
- Probe 1 (one `hooks.json`, shell hooks + `modules`): **Outcome 1A**. `claude plugin validate`
  passes and lists the module (`./register.ts hooks: session.measure`, env reads
  `FLIGHT_DECK_SESSION_ID`, `FLIGHT_DECK_USAGE_DIR`). The validator never lists command hooks —
  it prints none for the bundled `Resources/ClaudePlugin` either — so the decisive evidence is
  runtime: in the same session the `Stop` shell hook wrote `shell-hook.txt` *and* the module wrote
  its usage file. Both kinds coexist in one `hooks.json`.
- Probe 1 (prompt on load): **Outcome 3A** — an interactive `claude --plugin-dir` tab (tmux TTY,
  child-session markers cleared) booted straight to the composer, no trust/enable/reload dialog.
  Types laid into the plugin folder: **yes → Task 2 (Outcome 3C)**. At load (01:27:19, not at
  `validate`) the engine created `.claude-plugin/types/{.gitignore,tsconfig.json,claude-code/,
  claude-code-mcp/,claude-code-tools/}` inside the `--plugin-dir` folder. The bundled
  `Resources/ClaudePlugin` (no module) got no `types/` from `validate`.
- Probe 2 (`session.measure` in an interactive tab): **Outcome 4A**. After one turn the mod file
  was `{"v":1,"tab":"11111111-…","session":"7050…","readAt":"2026-10-05T06:32:21.357Z",
  "changed":["context","cost"],"rateLimits":[{"kind":"five_hour","percentUsed":1,
  "resetsAt":"2026-10-05T11:30:00.000Z"},{"kind":"seven_day","percentUsed":58,
  "resetsAt":"2026-10-08T21:00:00.000Z"}]}`. `/usage` (about 4 minutes later, with other
  sessions on the same account running in parallel): Current session 2 % (resets 6:30am CDT =
  11:30Z), Current week (all models) 58 % (resets Oct 8 4pm CDT = 21:00Z). The reset times match
  exactly; the session figure moved one point in between, consistent with the parallel load, not
  a parser disagreement. `/usage` also shows a third window, "Current week (Fable)" 0 %, that
  `session.measure` does not report. Note: the first measurement's `changed` did not include
  `rateLimits` even though `rateLimits` was populated, so the mod must write on every measure, not
  only when `changed` contains `rateLimits`. Headless `claude -p`: **Outcome 4C** — the module
  fired and wrote `22222222-….json` (`changed` included `rateLimits`, five_hour 2 %, seven_day
  58 %).
- Probe 3 (codex `account/rateLimits/read`): **Outcome 5A**. `result` carries `rateLimits` and
  `rateLimitsByLimitId.codex` with `primary {usedPercent 0, windowDurationMins 300, resetsAt}` and
  `secondary {usedPercent 0, windowDurationMins 10080, resetsAt}`, `planType "plus"`, plus fields
  the plan did not name: `ordinaryUsageAllowed`, `spendControlReached`, `rateLimitReachedType`,
  `credits`, `rateLimitResetCredits`, `accountId`, `rateLimitUpsell`. With 0 % used, `resetsAt`
  is "now + window" and advances on every read (it moved 553 s between two reads 553 s apart):
  an unused window has no fixed reset. Saved (account id and credit ids redacted) as
  `Tests/FlightDeckTests/Fixtures/FlightControlL3/Usage/codex-rate-limits-read.captured.json`.
  Pushes during this connection's own turn: **yes** — one `account/rateLimits/updated` with
  `params.rateLimits` of the same shape (note `spendControlReached: null` in the push vs `false`
  in the read, and an `emittedAtMs` beside `params`); saved as `codex-rate-limits-updated.captured.json`.
  Deviation 1's 120 s poll stays, because the TUI's turns run on a different connection.
- Probe hazard: typing `/usage` + Enter in one `send-keys` let the slash menu complete to
  `/auto-mode-setup`; it was cancelled with Escape before anything ran. Type the command, confirm
  the menu's first row, then send Enter.

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
5. Settings had a temporary top-level Capacity tab (`PreferencesTab.capacity`) so parallel
   branches never edited the same tab file; integration folded it into Settings → Flight Control →
   Capacity and deleted that tab.
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
11. "Status line silent" (was "mod not loaded") = an account's claude tab seen for 15 min with no
    usage file from any of its tabs.
12. The pool popover and row meter are UI-tested in a DEBUG Meter Gallery window; the pane in
    Settings. Script: `scripts/test-ui-capacity.sh`.
13. OpenCode: `OpenCodeAPIErrorEvent` + `OpenCodeErrorUsageSource` ship, tested with fakes; wiring
    waits for the OpenCode branch.
14. The engine's `.claude-plugin/types/` is git-ignored, not committed.
15. A local pool's usage is its unreleased leases (L3-S releases one when its session ends).
16. A failing meter source shows its error at once but keeps a still-fresh reading until it goes
    stale.
17. The claude plugin (`Resources/ClaudePlugin`) is run from a byte-compared copy under
    `~/Library/Application Support/Flight Deck/claude-plugin-<debug|release>/`
    (`ClaudePluginLocation.materialize`), because claude writes `.claude-plugin/types/` into any
    module-carrying `--plugin-dir` at load (probe Outcome 3C) and the bundle is code-signed. The
    module is gone, but the copy stays: the status line script runs from it too, and a later
    module would bring the write back. The
    copy never takes the source's `.claude-plugin/types/` and never deletes the destination's.
18. Claude gates hook modules behind a remote rollout switch: `claude plugin test` once refused
    with "hooks modules are turned off… rollout switch saved off" until an interactive claude
    refreshed it. A user whose switch is off gets no claude meter; the "mod is not loaded"
    source error (deviation 11) is how that shows. **Resolved 2026-10-06:** the meter now comes
    from the status line, which no rollout switch governs, so this hazard is gone (see "Status
    line replaces the mod" below).
19. A headless seat counts as refused while `SeatActivity.rateLimitedAt` is set (cleared by the
    next assistant event), not by its last `rate_limit_event` status, which stays "rejected"
    after recovery.
20. Each codex rate-limit read is bounded by a timeout (`UsageService.codexReadTimeout`, 20 s)
    with at most one read in flight per account, so one stuck app-server cannot stall the tick;
    a read that never returns stops that account's polling until restart, with its source error
    visible.
21. The swarm predicate set by `setSwarmPredicate` survives `attach` (it is stored outside the
    replaceable environment).
22. Transcript pointers are computed from the session's agent directly in `UsageService`, not
    through the shared registry.
23. The hand-off deadline's Escape is gated on the agent's own activity
    (`SessionStatus.agentActivity`), so an idle agent with a busy subagent is not interrupted;
    `retireAgent` sends the dialog Escape through `interruptTurn(includingDialog:)`, not
    `abortPrompt` (which refuses nameable prompts).
24. An unroutable spill (`Assignment.isUnroutable`) is treated as no spill: the driver waits and
    surfaces `unroutableReason`.
25. The driver drops per-agent state (phase, confirmation, failure memory) for agents that leave
    the snapshot, and a rate-limited agent counts as a boundary after a failed spawn.
26. A refused account's meter shows its real reading (or none), the refusal's source and
    "Refused by the provider", not a synthetic 100 %.
27. A pool never holds another agent's account: `CapacityEditing.toggle` refuses it and
    `effectivePools` drops a stored cross-harness member.
28. Each meter bar is exposed to accessibility as one static text "<account>: <reading>"
    (identifier `meter-bar`): on macOS an AXGroup carries no value and a Text reports its string
    as value with an empty label (found in real XCUITest runs).
29. The Capacity settings tab carries no container accessibility identifier (a container
    identifier is stamped onto every child and hides theirs); the tab is found by its title.
30. The over-hard notice is per account per crossing, for live tabs, and never fires on launch
    for a reading already over hard.
31. Default pools hold every live account; Remove is not offered there.

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
- `UsageService.shared.planner` must be called on the main actor (its transcript closure uses
  `MainActor.assumeIsolated`); the `@MainActor` `HandoffDriver` satisfies that.
- `LedgerHandoffPlanner`'s `reservedFiles` is `{ _ in [] }` and `StoreHandoffHost.reservationLookup`
  defaults to nil, so until L3-S wires them every hand-off prompt says "It held no file
  reservations" (spec §5.4 wants the list).
- Nothing in L3-U makes the old tab read-only after a hand-off (spec §5.7); `markHandedOff`
  defaults to a no-op — L3-S's responsibility.
- `CapacityLedger` can conform to the contract's `PoolDirectory` (`allPools` → `PoolSummary`);
  L3-U does not. Default pool labels differ: L3-U says "Claude default", `DefaultPoolDirectory`
  says "claude — all accounts".
- (Fixed in integration, task 9.) `StoreHandoffHost.stopAgent` ignored `retireAgent`'s `PromptDispatch`:
  if the exit command is not delivered, nothing logged it and the old agent could stay alive after a
  "handed off" record. A failed stop is now the terminal phase `.stopFailed`. (Final fix wave:)
  the swarm still records the new agent, which holds the task, and the driver keeps the old lease
  until the old tab no longer exists, then releases it.
- (Fixed in integration, task 10.) `HandoffDriver.evaluate` awaited `host.confirm` inline, so one
  pending human confirmation stalled every other agent's hand-off in that pass. Confirmation is now
  a non-blocking `requestConfirmation`; `HandoffDriver` is the `HandoffDecisionSink`; there is no
  Mac confirm UI (phone only).
- (Final fix wave, 2026-10-06.) **The "Confirm hand-offs" toggle is disabled until a confirm
  surface exists.** The phone has no Confirm/Decline yet (`FleetModel.decideHandoff` has no caller
  and no view reads `handoffPending`) and the Mac has none, so with confirm on every agent that
  crossed hard waited forever on its exhausted account. `CapacityPreferences.confirmSurfaceExists`
  is false: Settings greys the toggle out with a note, and `handoffSettings.confirm` reads false
  whatever is stored. §5's confirmation step (2) is therefore skipped in practice. The driver's
  confirmation machinery and its tests are kept for when a surface ships.

### Status line replaces the mod (2026-10-06)

The claude interactive meter moved from the `session.measure` mod to the status line. The mod
could be switched off remotely (deviation 18), which blanks every claude meter at once; the status
line has no such switch.

- **Source.** Claude passes a status line command a JSON object on stdin with
  `rate_limits.<window>.used_percentage` (0–100) and `resets_at` (epoch seconds), for
  subscribers, after the first API response, while the window's reset is in the future. Ordinary
  hook payloads (`Stop`, `PostToolUse`, …) do not carry them (checked on claude 2.1.292).
- **Install.** `ClaudePluginLocation.applying` adds `--settings '{"statusLine":{"type":"command",
  "command":"'<copy>/scripts/statusline.sh'","refreshInterval":30}}'`, beside `--plugin-dir`
  and pointing at the same Application Support copy. The path is single-quoted inside the JSON
  because it has a space (exit 127 otherwise, as for `record.sh`); the JSON is written without
  `\/` escapes because fish reads a backslash inside single quotes. The user's `padding`,
  `hideVimModeIndicator` and a shorter `refreshInterval` are carried over.
- **The user's status line.** Claude takes one status line, so the wrapper runs the user's: it
  pipes the same stdin to `$FLIGHT_DECK_USER_STATUSLINE` through `/bin/sh -c` and prints its
  output unchanged; no user command prints nothing. `SessionStore.launchEnvironment` resolves
  the variable per tab in claude's order: the user's own `--settings` flag, the project's
  `.claude/settings.local.json`, its `.claude/settings.json`, then the account's `settings.json`
  (`CLAUDE_CONFIG_DIR`, else `~/.claude`). A leading `~/` is expanded (quoted). Managed settings
  outrank `--settings`; under one that sets a status line ours does not run, and the account
  shows the silence error.
- **An existing `--settings`** is merged into, not replaced: inline JSON is parsed, a path is read
  (relative to the project) and folded in inline, since claude takes one `--settings`. A value
  that does not read as a JSON object is left alone and gets no status line.
- **File.** Same name rule and v1 shape as the mod's (`<tab or claude session id>.json`), so
  `ClaudeUsageFileSource` (renamed from `ClaudeModUsageSource`; `ModUsageFile` is now
  `ClaudeUsageFile`) reads it unchanged, plus an `fp` key. Temp file plus rename. The script
  parses with `plutil` (no `jq`; not `python3`, which on a Mac without developer tools is an
  install-dialog stub) and exits 0 on every path.
- **No rewrite of an unchanged reading.** The status line re-runs on a timer and on UI events
  and re-sends the last API call's numbers. A rewrite would stamp them with a new `readAt`, and
  the ledger keeps the newest reading per account, so an idle tab would hide a busy tab's real
  reading. The script fingerprints `rate_limits` plus `context_window.current_usage` (the last
  API call's tokens) and writes only when that changes.
- **Cost.** Measured on this Mac: a writing run is about 70 ms of `plutil` work, an unchanged run
  about 30 ms, both in the background beside the user's command (Nate's own status line alone
  takes about 160 ms), so the visible status line is not slowed. `refreshInterval: 30` adds one
  such run per tab every 30 s. It does not freshen the meter (the numbers move only on API
  calls); it is there so an idle tab's status line keeps time-based text current.
- **Live probe (claude 2.1.292, 2026-10-06).** Interactive claude in tmux with the flags above, a
  scratch `FLIGHT_DECK_USAGE_DIR` and the user's `~/.claude/statusline.sh`; one Haiku prompt. The
  file appeared with five_hour 37 % (resets 21:00Z) and seven_day 38 % (resets Oct 8 21:00Z); the
  user's status line rendered in the pane with the same figures ("5h 37% ↻36m", "wk 38% ↻2d0h").
  40 s later the file's mtime had not moved (whether a timed refresh ran in that window was
  not observed).
- **Silence warning.** Kept, reworded: the status line may not have run (untrusted folder,
  `disableAllHooks`, managed settings) or no tab has had a reply yet.
- **Not covered.** Headless `claude -p` seats run no status line; they keep their
  `rate_limit_event` source. A restored tab on a different account than the project's current one
  takes its `padding` from the project's account (the command comes from its own account).

**Integrated (2026-10-06):** integration branch `l3-integration`, code head 4db609f0 (not merged to master). The real graph is built in one place, `FlightControlComposition`; see `docs/FOLLOWUPS.md` for what is still open.
