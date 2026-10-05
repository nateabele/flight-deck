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
| claude interactive | **a Flight Deck mod** in the bundled plugin (`Resources/ClaudePlugin`, already passed as `--plugin-dir`). It hooks `session.measure`, which fires "when a rate-limit window moves a whole point" and carries `rateLimits: [{kind, percentUsed, resetsAt}]`. On each event it writes the reading to `<FD runtime dir>/usage/<FD session id>.json`, and FD watches that directory | API confirmed in the 2.1.289 type definitions; **probe first** (§9) |
| claude headless (intake seats) | `rate_limit_event.rate_limit_info.unifiedWindows.{five_hour,seven_day}.utilization` | fixtures exist; FD reads only `status` today |
| opencode hosted | no meter. An `APIError` with status 429 marks the account **over hard** until `retry-after`, or a 15-min backoff when there is none | from the OpenCode workstream |
| opencode local | no meter. Capacity = the pool's concurrency cap minus FD's live sessions on that pool | load from outside FD (for example ledger-sync holding Ollama slots) cannot be seen. The pool popover says so |

**FD maps a reading to an account** through the session that produced it (`Session.accountID`,
resolved). The mod never sees account identity.

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
- **Settings → Capacity:** pools, the order inside each pool, thresholds, the local caps,
  "Confirm hand-offs", the hand-off deadline.

## 7. Error handling

- A meter source fails (the app-server is down, the mod is not loaded): the account becomes
  unknown, and the popover shows the source error.
- The hand-off spawn fails: the old agent is left running, the task stays assigned to it, and
  the failure is logged and notified. The hand-off is retried at the next boundary.
- The transcript pointer is unavailable: the hand-off still runs. The prompt says the transcript
  is not available and leans on `git diff` and the task's notes.

## 8. Testing

- **Meter parsing:** per adapter, against fixtures. This covers the codex snapshot with
  primary/secondary windows and by-limit buckets, claude `unifiedWindows`, the mod's file
  format, and OpenCode `APIError` 429 with and without `retry-after`.
- **State and lease logic:** a pure state machine, table-tested over the L3-0 usage timeline
  fixture. This covers order, unknown accounts, hard rejection overriding a meter, reset
  clearing, and the local cap.
- **The hand-off driver:** against fake sessions, a fake spawner and a fake br. It covers the
  idle boundary, the deadline interrupt, confirm on and off, decline, no account free → spill,
  pinned → wait, spawn failure, and a missing transcript pointer.
- **The mod:** `claude plugin validate` and `claude plugin test` with a `*.test.ts` that feeds
  `session.measure` events and checks the file written.
- **Live, skipped by default** (`USAGE_LIVE=1`):
  - the codex app-server rate-limit read for one real account;
  - the claude mod in a real FD-spawned tab.
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

Real `CapacityReader`, `PoolAllocator` and `HandoffPlanner`, the meter sources, the mod, and the
Capacity pane.

## 11. Files

- `Sources/IntakeKit/FlightControl/PoolState.swift`, `LeasePolicy.swift`, `HandoffPrompt.swift`
- `Sources/FlightDeck/FlightControl/Usage/UsageService.swift`, `CodexRateLimitSource.swift`,
  `ClaudeModUsageSource.swift`, `HeadlessClaudeUsageSource.swift`, `OpenCodeErrorUsageSource.swift`,
  `HandoffDriver.swift`
- `Resources/ClaudePlugin/…`: the usage mod (`hooks/register.ts`, its test, `types/`)
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
