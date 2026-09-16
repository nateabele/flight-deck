# Detached Session Persistence — Phase 3: scrollback-budget knob + end-to-end reattach test — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Finish the detached-session feature: (1) a user-facing scrollback-budget preference that sizes each session's `fd-abduco` replay ring, and (2) the spec's end-to-end proof — a real-ghostty `TerminalSmokeTests` case that kills and relaunches the app and asserts a live session reattaches with its scrollback intact.

**Scope:** Phase 3 of the approved spec (`docs/superpowers/specs/2026-09-03-detached-session-persistence-design.md`), the two items Phase 2 deferred. Phases 1+2 are complete on this branch (`worktree-detach-phase1`, tip `e12bacd` — which also now carries a teammate's smart-sleep work). This branch is SHARED with session "Energy"; Phase 3 deliberately avoids its flagged files (`DaemonControl.swift`, `SessionStore.swift`, `TerminalPane.swift`) — the only overlap is the Preferences pane (Task 1), where Energy is idle; ping it before that edit.

**Architecture:** The daemon already reads `FD_OUTLOG_BUDGET` from its environment at cold-create (`vendor/fd-abduco/abduco.c:386-388`, default 4 MiB). Flight Deck sets no such env var today. The scrollback ring wraps **every** session's shell regardless of agent, so this is agent-agnostic terminal/session infrastructure — it lives on the neutral **`ShellPreferences`** (`preferences.shell`), NOT `ClaudePreferences`. Task 1 adds `ShellPreferences.scrollbackBudgetBytes` and injects it in `PreferencesStore.sessionEnvironment(...)` — the one function both surface-creation sites already read and which already builds from `preferences.shell.environment`, so **no `SessionStore` edit is needed** and Claude/Codex/any future adapter get it identically. Task 2 adds an isolated XCUITest that drives the real app through kill/relaunch.

**Tech Stack:** Swift 5 app target + `FlightDeckTests` (macOS, `./scripts/test-unit.sh`) for Task 1; `FlightDeckUITests` XCUITest via `./scripts/smoke.sh` for Task 2.

**Spec:** `docs/superpowers/specs/2026-09-03-detached-session-persistence-design.md`

## Global Constraints

- **Agent-agnostic placement (load-bearing — this is terminal infra, not a Claude feature):** the field goes on the neutral **`ShellPreferences`** (`preferences.shell`, `Preferences.swift:4-24`), the control in the **Shell** settings pane (`ShellSettingsTab.swift`) — NOT `ClaudePreferences`/`AgentsSettingsTab`. Reuse the *mechanics* of Energy's `sleepIdleThresholdSeconds` (commit 516106b) — optional field (legacy-decode safe), read-through-optional get/set on `PreferencesStore` with the default in the getter, auto-persisted via the `preferences` `didSet` → `preferences.v1` JSON blob (no per-field UserDefaults key), a control with an `.accessibilityIdentifier` — but keep the placement neutral so Codex and every future adapter inherit it.
- **Budget is read once at cold-create**, like the sleep *threshold* (not live) — an attaching `-a` daemon never re-reads it. Document that in the control's help/comment.
- **Cap the budget** to a safe range — **min 256 KiB, max 16 MiB, default 4 MiB** — so a large replay never exercises the deferred `write_all`-busy-spin (`docs/FOLLOWUPS.md`); clamp in the setter.
- **Shared branch:** do not touch `DaemonControl.swift` / `SessionStore.swift` / `TerminalPane.swift` (Energy's). Task 1 edits `Preferences.swift` + `PreferencesStore.swift` (which Energy also touched — different struct/accessor) and `ShellSettingsTab.swift` (which Energy did NOT touch); send Energy a one-line heads-up before the first two (it is idle, so low risk). Never `git clean -fdx` (wipes the SDD ledger + `vendor/*-artifacts` symlinks).
- **Task 2 seizes the display.** `smoke.sh` runs a real GUI app and grabs the foreground for ~40s (repo memory: don't loop GUI smoke tests; alert before stealing the display). Run it **once**, only after a `PushNotification` heads-up, and never in a loop; if the machine is busy, the plan's execution pauses and hands the single run to Nate rather than seizing focus mid-work.
- `test-unit.sh` runs the whole macOS suite (~8 min, ignores `-only-testing:`). Keep it green.

---

### Task 1: Scrollback-budget preference → `FD_OUTLOG_BUDGET`

**Files:**
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift` (`ShellPreferences` — add field + init param, ~lines 4-24).
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift` (accessor reading `preferences.shell`; inject into `sessionEnvironment` ~295-308).
- Modify: `Sources/FlightDeck/Preferences/UI/ShellSettingsTab.swift` (a control in the Shell pane, near the existing environment editor).
- Test: `Tests/FlightDeckTests/PreferencesStoreTests.swift` (extend).

**Interfaces:**
- Produces: `PreferencesStore.scrollbackBudgetBytes: Int` (default `4*1024*1024`, clamped `[262144, 16777216]`), backed by `preferences.shell.scrollbackBudgetBytes`, and `sessionEnvironment(...)` now contains `"FD_OUTLOG_BUDGET": String(scrollbackBudgetBytes)`.

- [ ] **Step 1 — heads-up to Energy** (it edits `Preferences.swift`/`PreferencesStore.swift` too — different struct/accessor, and it is idle, but courteous): SendMessage that Task 1 adds `scrollbackBudgetBytes` to the neutral `ShellPreferences` + a Shell-pane control (`ShellSettingsTab.swift`, which Energy did NOT touch), additive. (Controller does this, not the implementer.)

- [ ] **Step 2 — failing tests** (`PreferencesStoreTests.swift`), mirroring the sleep-threshold tests:

```swift
func testScrollbackBudgetDefaultsToFourMiB() {
    let store = PreferencesStore(persistence: MemoryPersistence())
    XCTAssertEqual(store.scrollbackBudgetBytes, 4 * 1024 * 1024)
}
func testScrollbackBudgetRoundTripsAndClamps() {
    let store = PreferencesStore(persistence: MemoryPersistence())
    store.scrollbackBudgetBytes = 8 * 1024 * 1024
    XCTAssertEqual(store.scrollbackBudgetBytes, 8 * 1024 * 1024)
    store.scrollbackBudgetBytes = 999 * 1024 * 1024        // over max
    XCTAssertEqual(store.scrollbackBudgetBytes, 16 * 1024 * 1024)
    store.scrollbackBudgetBytes = 1                        // under min
    XCTAssertEqual(store.scrollbackBudgetBytes, 262144)
}
func testSessionEnvironmentCarriesScrollbackBudget() {
    let store = PreferencesStore(persistence: MemoryPersistence())
    store.scrollbackBudgetBytes = 2 * 1024 * 1024
    XCTAssertEqual(store.sessionEnvironment()["FD_OUTLOG_BUDGET"], String(2 * 1024 * 1024))
}
func testLegacyClaudeBlobWithoutScrollbackBudgetStillDecodes() {
    // strip the new key from an encoded Preferences and assert it loads with the default
    // (mirror the existing sleep-threshold legacy-decode test verbatim in shape)
}
```

- [ ] **Step 3 — run, verify fail** (`./scripts/test-unit.sh`, foreground; or compile-first with `./scripts/build.sh`).
- [ ] **Step 4 — implement:** add `var scrollbackBudgetBytes: Int?` to `ShellPreferences` (+ init param, defaulted `nil`, legacy-decode safe); add the clamped get/set accessor to `PreferencesStore` (getter default `4*1024*1024`; setter clamps to `[262144, 16777216]` then writes through the `shell` struct, mirroring the mechanics of `sleepIdleThresholdSeconds`); add `environment["FD_OUTLOG_BUDGET"] = String(scrollbackBudgetBytes)` inside `sessionEnvironment(for:inherited:)` (which already builds from `preferences.shell.environment`).
- [ ] **Step 5 — control:** in `ShellSettingsTab.swift` (the Shell pane, near the existing environment editor), add a `Stepper` (MB display; `.accessibilityIdentifier("prefs-scrollback-budget")`) or a small `Picker` over {0.25, 0.5, 1, 2, 4, 8, 16} MiB, bound through `preferences.scrollbackBudgetBytes`, with help text noting it applies to a session's next cold start (an already-running/attached daemon keeps its ring). Agent-neutral wording — this governs every session's terminal, not one adapter.
- [ ] **Step 6 — run, verify pass** (`./scripts/test-unit.sh` green).
- [ ] **Step 7 — commit** (`feat: scrollback-budget preference sizing the fd-abduco replay ring`).

---

### Task 2: End-to-end reattach `TerminalSmokeTests` case (real ghostty)

**Files:**
- Modify: `UITests/FlightDeckUITests/TerminalSmokeTests.swift` (add ONE standalone `func test…`, not folded into the giant sequence).

**Interfaces:**
- Consumes: `launchIsolated(_:)` (`TerminalSmokeTests.swift:327-341`) and the file's existing terminal-driving/query helpers.

- [ ] **Step 1 — write the test** `testSessionReattachesWithScrollbackAfterRelaunch()`:
  1. `let app = launchIsolated()` (reset state), drive to a shell tab as the existing tests do.
  2. Type `echo FD-REATTACH-<nonce>` + Return; assert `FD-REATTACH-<nonce>` appears on the terminal (wait-for-existence on the surface text).
  3. `app.terminate()` — the app-side client dies; the `setsid`'d `fd-abduco` daemon persists.
  4. Relaunch against the **same** `-FlightDeckStateDir` but **without** `-FlightDeckResetState` (add a `launchPreservingState()` variant beside `launchIsolated`, or parameterize it), so `restore()` runs and reattaches.
  5. Assert `FD-REATTACH-<nonce>` is **still visible** in the reattached terminal (replayed from the live daemon — a cold shell would not show it), and no fresh-shell/"Keep going" artifact is typed.
  6. `defer`/teardown: close the session in-app (so `closeSession` terminates the daemon) OR kill the daemon via its pidfile under `/tmp/flight-deck-<uid>` so no daemon leaks.

- [ ] **Step 2 — build** (`./scripts/build-fd-abduco.sh` then `./scripts/build.sh`) → BUILD SUCCEEDED, `fd-abduco` bundled.
- [ ] **Step 3 — run ONCE, with an alert.** Before running `./scripts/smoke.sh -only-testing:FlightDeckUITests/TerminalSmokeTests/testSessionReattachesWithScrollbackAfterRelaunch` (it seizes the display ~40s+): send a `PushNotification` warning Nate the screen will be grabbed. Do NOT loop. If the machine is in active use, STOP and hand the single run to Nate with the exact command rather than seizing focus.
- [ ] **Step 4 — commit** (`test: end-to-end reattach smoke test — session survives relaunch with scrollback`).

Adapter note: this shell-based surface test proves the real-ghostty reattach+replay path generically; Claude/Codex parity of the resume-gating is already unit-covered (`ResumeGatingTests`), so no separate Codex GUI case is needed.

---

## Verification (whole phase)
- `./scripts/test-unit.sh` green incl. the new Preferences tests; app builds; `fd-abduco` bundled.
- The scrollback pref appears in Agents settings, clamps, and a cold-created session's daemon receives `FD_OUTLOG_BUDGET` (spot-check: set 8 MiB, start a session, confirm the daemon's env).
- `testSessionReattachesWithScrollbackAfterRelaunch` passes its single alerted `smoke.sh` run (or is handed to Nate to run).

## Non-goals
- The `write_all`→`writefds` backpressure fix (budget is capped so it isn't exercised) — stays a FOLLOWUP.
- Nested-binary code-signing validation and the FdOutlog micro-hardening — FOLLOWUPs.
- Mac-reboot survival — spec non-goal.
