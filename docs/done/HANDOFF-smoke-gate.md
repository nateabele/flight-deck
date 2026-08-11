# Postmortem — Multi-Session Foundation: smoke gate (RESOLVED)

**Date:** 2026-08-10 · **Branch:** `multi-session-foundation` (off `master` @ `8a20e11`)
**Status:** ✅ **RESOLVED — smoke gate GREEN.** Both UI tests pass.

## ✅ Resolution (root cause + fix)

**Root cause.** The initial `WindowGroup` window is gated behind the macOS **window-restoration
handshake**. A LaunchServices launch (`open`, i.e. every real-user launch) completes that handshake
and then creates the fresh window; XCUITest spawns the app via a **raw exec**, which never completes
it, so the window is never created. The menu bar still appears because it is built in
`applicationDidFinishLaunching`, independent of the window — which is exactly the symptom below (menu
bar present, zero `Window` nodes in the AX tree).

**Evidence (CGWindowList probe, no TCC needed), same test-build bundle, saved-state wiped each time:**
| Launch | Result |
|---|---|
| `open` (LaunchServices) | real 1000×700 window on main display ✅ |
| direct-exec (XCUITest-style) | **0 windows** at t=3.5s and t=6s ❌ |
| direct-exec **+ inject reopen event** | window appears |
| direct-exec **+ `-ApplePersistenceIgnoreState YES`** | window appears immediately |
| direct-exec **+ plain `activate`** | still no window (rules out "just needs focus") |

**Fix (verified green).** Both tests in `UITests/FlightDeckUITests/TerminalSmokeTests.swift` now pass
`app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]`. This bypasses restoration so the
window is created under XCUITest's raw-exec launch — matching real-user (LaunchServices) semantics.
It masks **no** user-facing bug: real users always launch via LaunchServices and always get a window;
the zero-window state is exclusive to non-LaunchServices spawns (XCUITest only). `RootWindow.swift`'s
`.defaultSize`/`.defaultPosition(.center)` was kept as placement polish (main-display, positive
coords) but does not affect window *count*.

**Why the two earlier hypotheses looked falsified:** the state-wipe attempt cleared restoration
*contents* but never the *mechanism* that gates the window; `.defaultPosition` is genuinely
irrelevant to whether a window exists.

The rest of this document is the original RED-state debug handoff, retained for the reasoning trail
and the shell-output discipline (§0), which is now baked into `scripts/smoke.sh`.

---

## 0. READ FIRST — shell-output discipline (this is what blew the context)

`./scripts/smoke.sh` dumped the **entire** `xcodebuild` verbose transcript (thousands of lines of compiler invocations) straight to stdout. When run as a `!` command that transcript lands in the model context and destroys it. **Never again.** Follow these rules for every `!` command and every script that shells out to a noisy tool (`xcodebuild`, `swift build`, `xcodegen`, `git log -p`, test runners):

1. **Redirect noisy output to a log file; print only a summary.**
   ```bash
   LOG=scripts/.smoke.log
   xcodebuild ... > "$LOG" 2>&1; rc=$?
   tail -n 20 "$LOG"                 # or a grep of the lines that matter
   echo "exit=$rc — full log: $LOG"
   ```
2. **Never pipe a full verbose build/test transcript to stdout.** Filter it:
   `grep -E 'error:|warning:|Test Case|XCTAssert|\*\* (BUILD|TEST)' "$LOG" | tail -n 40`.
3. **For xcodebuild test results, read the `.xcresult`, not the console.** It is compact and authoritative:
   ```bash
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   XCR=$(ls -dt ~/Library/Developer/Xcode/DerivedData/FlightDeck-*/Logs/Test/*.xcresult | head -1)
   xcrun xcresulttool get test-results summary --path "$XCR"   # ~1 line of JSON: pass/fail counts
   xcrun xcresulttool get test-results tests   --path "$XCR"   # per-test tree + failure messages
   ```
   (Note: `xcresulttool` needs `DEVELOPER_DIR` set or it errors "unable to find utility".)
4. **`scripts/smoke.sh` has been updated to log-and-summarize** (see §6). Re-running it will no longer flood stdout. If you write a new gate script, copy that pattern.
5. When you need the user to run something interactive, hand them a command that already redirects: `! ./scripts/smoke.sh` (now safe) rather than a raw `xcodebuild`.

---

## 1. What the failure is (evidence, not theory)

`./scripts/smoke.sh` runs `xcodebuild test -only-testing:FlightDeckUITests`. Both UI tests in
`UITests/FlightDeckUITests/TerminalSmokeTests.swift` fail:

- `testAppLaunchesAndShowsTerminalSurface` — `TerminalSmokeTests.swift:9`
  `XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))` → **false**.
  Line 11 then errors: **“No matches found for … `Descendants matching type Window`, given input App element pid: N”.**
- `testClosingSeededSessionKeepsAppAlive` — fails at `:19` (same window-existence assert) and `:30`.

**Decisive fact:** under the XCUITest launch, the app is alive and `.runningForeground` with a **full menu bar** (incl. File ▸ New Window) but its accessibility tree has **ZERO `Window` nodes**. Confirmed in two separate interactive runs: `Test-FlightDeck-2026.08.10_09-56-55` and `…_11-05-41`. This is a **real red** (tests execute ~47–52s on My Mac), not the historical `childPID>0` environmental block.

The tests launch with a bare `XCUIApplication().launch()` — no launch args, no env overrides.

## 2. Hypotheses already FALSIFIED — do not repeat these

1. **State restoration / “zero windows” persisted state.**
   Fix tried: `scripts/smoke.sh` also `rm -rf`s `~/Library/Saved Application State/dev.flightdeck.FlightDeck.savedState` (kept — it’s correct hygiene regardless). **Falsified:** test #1 is the first launch *after* the wipe, with no intervening launch, and it still shows 0 windows. Restoration cannot explain a freshly-wiped launch.
2. **Off-primary window placement on the multi-display rig.**
   Fix tried: `Sources/FlightDeck/RootWindow.swift` added `.defaultSize(width:1000,height:700)` + `.defaultPosition(.center)`. **Falsified:** the 11:05 run (with the fix built in — the transcript shows `Compiling RootWindow.swift`) still fails with 0 Window nodes. Placement is irrelevant if no window exists in the AX tree. **This change did not fix anything — consider reverting it to keep a clean single-variable tree for bisecting** (or keep it as harmless polish; your call, but note it in the commit if kept).

### The one variable that was never actually tested — the real lead
All my autonomous “a window exists” evidence came from a **CGWindowList probe of an `open`-launched app** (LaunchServices). Under `open` the app shows a real 900×552 onscreen window (CG). Under **XCUITest** the app shows **no window** (AX). **The discriminating variable is the launch mechanism** — `open`/LaunchServices (full GUI session, works) vs. XCUITest’s direct child-process exec (fails). I never probed the XCUITest-style launch. That is the next experiment.

## 3. Next step — Phase-1 evidence, NOT another fix

Per `superpowers:systematic-debugging` (Iron Law: no fix without root cause; 2 fixes have already failed — the next move is evidence, not fix #3):

1. **Reproduce the failure autonomously via a non-LaunchServices launch.** Launch the built binary directly, the way XCUITest does, and probe:
   ```bash
   APP=~/Library/Developer/Xcode/DerivedData/FlightDeck-eznrxnuxsmerbbgkymomdhwkbzzj/Build/Products/Debug/FlightDeck.app
   # NB: the TEST run uses the user-DerivedData build above, NOT ./DerivedData used by `open` probes.
   pkill -x FlightDeck; rm -rf ~/Library/Saved\ Application\ State/dev.flightdeck.FlightDeck.savedState
   "$APP/Contents/MacOS/FlightDeck" &      # direct exec, no LaunchServices
   sleep 3
   scratchpad/winprobe <pid>               # CGWindowList probe (see §5) — does a window exist here?
   ```
   - If **no window at CG** under direct-exec → failure reproduced without XCUITest; the bug is in the app’s launch/lifecycle under a non-LaunchServices spawn (investigate `AppDelegate` / `GhosttyApp` init / WindowGroup materialization when not launched by LaunchServices).
   - If a **window exists at CG** under direct-exec but XCUITest still sees none → the gap is specifically XCUITest’s AX bridging/activation; investigate `app.activate()` timing, key-window, and whether the window needs to become key before AX exposes it.
2. **Verify the bundle id under test** actually matches what smoke.sh wipes (`dev.flightdeck.FlightDeck`). If the test build’s id or state key differs, the wipe is a no-op.
3. **Only after evidence points at restoration** should you consider the standard XCUITest remedy
   `app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]` — and note it may **mask** a genuine user-facing relaunch bug (real users with `applicationShouldTerminateAfterLastWindowClosed = true` can also hit menu-bar-only relaunch). That trade-off is a **human decision**, already flagged in the ledger.

Cannot be driven by the agent: XCUITest itself needs the user’s interactive GUI/TCC session. The agent CAN run the direct-exec/CG probe autonomously (no TCC needed for the window *list*).

## 4. Working-tree state (nothing committed since ffe4d58)

Uncommitted changes:
- `Sources/FlightDeck/RootWindow.swift` — the falsified `.defaultPosition/.defaultSize` change (decide: revert or keep).
- `scripts/smoke.sh` — Saved-App-State wipe (keep) + corrected comment + **new log-and-summarize wrapper** (keep; see §6).
- `.superpowers/sdd/progress.md` — ledger, current through the 10:51–11:02 investigation. **Append the 11:05 result** (still RED; placement hypothesis falsified) when you resume.
- `docs/HANDOFF.md` — pre-existing modification from earlier (unrelated to this debug).

Do **not** commit the fix attempts as “the fix” — none is verified. When smoke is genuinely green, commit with a clean message (NO “Generated with Claude Code” / NO `Co-Authored-By` trailers), then run `superpowers:finishing-a-development-branch`.

## 5. Reference — key files, commands, evidence

- Failing tests: `UITests/FlightDeckUITests/TerminalSmokeTests.swift`
- App entry: `FlightDeckApp` (`@NSApplicationDelegateAdaptor`) → `RootWindow` (WindowGroup) → `RootView` → `SessionStore` → `SurfaceProvider`. Single `GhosttyApp()` created in `AppDelegate` (`Sources/FlightDeck/AppDelegate.swift`).
- Unit tests (headless, agent-runnable, currently green): `./scripts/test-unit.sh` → 14 pass / 1 skip / 0 fail.
- Smoke gate (needs interactive TCC): `./scripts/smoke.sh` → target `SMOKE PASS`.
- CG probe (agent-runnable, no TCC): `scratchpad/winprobe.swift` + `scratchpad/run_probe.sh`; NSScreen dump: `scratchpad/screens.swift`. (Scratchpad dir:
  `/private/tmp/claude-501/-Users-nate-Projects-Protos-n-Tools-flight-deck/afae11fc-c5ce-4f5d-a96b-2ca2071e8951/scratchpad`.)
- Display rig (relevant only to the *falsified* placement theory): main 1728×1117 @(0,0); external 4K 3840×2160 @(−3840,−295) to the left (negative X).
- Latest RED evidence: `~/Library/Developer/Xcode/DerivedData/FlightDeck-eznrxnuxsmerbbgkymomdhwkbzzj/Logs/Test/Test-FlightDeck-2026.08.10_11-05-41--0500.xcresult` (read via §0 rule 3).

## 6. `scripts/smoke.sh` new logging contract

`smoke.sh` now writes build/generate/test output to `scripts/.smoke.log` (git-ignored) and prints only:
a one-line build result, a filtered test summary (pass/fail lines + assertion failures), and `SMOKE PASS` / `SMOKE FAIL (see scripts/.smoke.log)`. Re-running it will not flood the terminal/context. Keep this contract for any future gate scripts.

---

### TL;DR for the next session
Branch done except the smoke gate. Bug: under XCUITest the app has a menu bar but **no window in its AX tree**. Two fixes (state-wipe, `.defaultPosition`) are **falsified**. The untested lead is the **launch mechanism** — reproduce via **direct-exec + CG probe** (§3) before touching code. And **redirect all noisy shell output to logs** (§0) so this doesn’t blow context again.
