# Flight Deck — Agent Operations

Runtime hazards and rituals specific to working on this repo *with an agent*. Everything here
was learned the hard way; each item names the failure it prevents.

For build mechanics see [BUILD.md](BUILD.md); for why the toolchain is odd, [TOOLING.md](TOOLING.md).

---

## 1. You are probably running inside the app you are editing

Flight Deck hosts terminal sessions, and Claude Code usually runs in one of them:

```
Flight Deck.app → /usr/bin/login → fish/zsh → claude   ← you are here
```

Consequences, all of which have bitten:

- **Quitting or killing Flight Deck kills your own session mid-task.** Anything that must
  outlive the app (a release swap) has to be detached first — see §2.
- `pkill`-style cleanup aimed at "stray" `claude` processes can reap the session issuing it.
- A crash you introduce takes down the agent investigating it.

Treat "quit the app" as a destructive, self-affecting action: detach, or hand it to the user.

## 2. The release ritual

The canonical script is **`scripts/swap-release.sh`**; the deployed copy at
`~/Library/Application Support/Flight Deck/swap-release.sh` is *installed from* it. Edit the
repo copy and re-install — never the other way round.

```bash
# 1. Build Release
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -configuration Release -derivedDataPath DerivedData build

# 2. Swap, DETACHED (it quits the app running this very shell)
nohup ./scripts/swap-release.sh <delay-seconds> <current-app-pid> >/dev/null 2>&1 &
```

What the script guarantees, and why each guarantee exists:

| Guarantee | The failure it prevents |
|---|---|
| Verifies the new bundle **without executing it** (executable + `Info.plist` + `codesign --verify`) | Flight Deck has no argv parsing — argv goes straight to `ghostty_init`. `--help` does *not* print usage; it **boots a second full app instance**, restoring every session and spawning duplicate `claude --resume` processes. |
| Only ever `open`s `/Applications/Flight Deck.app` — never the DerivedData bundle | A DerivedData launch is a second live app holding live sessions. Duplicates collide in Claude's pid-keyed name registry, which is why `/rename Crashing` started returning `Crashing-valiant-quilt`. |
| Only relaunches if the app **was** running when the swap began | Don't spring a window on a machine where the user deliberately quit. |
| Stages via `ditto`, backs the old bundle up to `…/Flight Deck/backups/<ts>/`, restores on failure | A half-swapped `/Applications` with no working app. |
| Post-order signal walk (leaves → app), SIGTERM then SIGKILL | Children reparented to `launchd` become unkillable orphans. |
| Uses `ps -A`, not `pgrep -f` | `pgrep -f` matches nothing for this app in this environment; a silent no-match would swap the bundle out from under a live app. |

Log: `~/Library/Logs/flight-deck-swap.log`. Rollback is printed at the end of every run.

**Rule: never launch a bundle from `DerivedData/` directly.** Build there, run from
`/Applications`.

## 3. Process hygiene

- Orphaned `claude` processes are a real, recurring failure mode. `SessionReaper` +
  `ProcessTree` exist to reap a session's tree (SIGHUP → SIGTERM → SIGKILL with deadlines)
  before the surface is freed and before quit.
- Process identity is read via `sysctl`, not `libproc`, and start times gate the kill so a
  recycled pid is never signalled. Don't "simplify" that.
- `scripts/hangwatch.sh [outdir]` auto-captures a symbolicated stack sample when the main
  thread stalls (beach ball). Leave it running, use the app, samples land in the outdir.

## 4. State: where it lives, what never to delete

| What | Where |
|---|---|
| Sessions, projects, order, collapse, pins | `~/Library/Application Support/Flight Deck/sessions.json` (atomic write) |
| Preferences (`preferences.v1`) | `UserDefaults`, domain `dev.flightdeck.FlightDeck` |
| Window geometry | `UserDefaults` + `~/Library/Saved Application State/…` |

- **Never `defaults delete dev.flightdeck.FlightDeck`.** It nukes preferences; it used to nuke
  every session too, on every smoke run. Delete individual geometry keys only — the list
  `smoke.sh` uses is the correct one.
- Sessions moved *out* of `UserDefaults` deliberately: `defaults delete` is a routine debugging
  gesture, `cfprefsd` coalesces writes so a `SIGKILL` can drop the last one, and the snapshot
  grows with sessions × projects.
- Test isolation is the **`-FlightDeckResetState YES`** launch argument, not deletion. It makes
  the app start from a fresh slate without touching anything stored.

## 5. Tests

```bash
./scripts/test-unit.sh     # headless, fast, NOT throttled — your normal TDD loop
./scripts/smoke.sh         # GUI UITest; ends with "SMOKE PASS"
```

- `test-unit.sh` runs the app-hosted bundle in-process via `xcrun xctest` (symlinking the host
  dylib) because `xcodebuild test` would try to *launch* the app and dies with
  `DVTAssertions: Assertion failed: childPID > 0` outside a GUI login session.
- **Do not loop `smoke.sh`.** It seizes the foreground for ~70s and fires key events into
  whatever holds focus, so the user's typing lands in the test and shows up as phantom
  failures. `scripts/throttle.sh` caps it at one run per 120s
  (`FLIGHTDECK_TEST_THROTTLE=0` for a deliberate one-off).
- **To chase a flaky assertion, isolate it — do not re-run the suite.** `TerminalSmokeTests` is
  deliberately one test function of `runActivity` groups, so `-only-testing:` cannot target a
  single behaviour. Re-running the whole thing is also weak evidence: at a 20% failure rate,
  five clean runs still pass by luck 33% of the time. Instead add a hunt case that loops the
  suspect sequence inside ONE launch and is `XCTSkipUnless`-gated so normal runs pay nothing —
  `testPermissionBypassConfirmationUnderChurn` is the worked example, at 20 samples in ~107s
  (1.2% luck) against ~23 min for the same power via the suite.
- **Gate hunt cases on a `TEST_RUNNER_`-prefixed variable.** `xcodebuild` does not forward
  arbitrary shell environment into the UI-test runner process; it forwards only `TEST_RUNNER_*`,
  stripping the prefix. A bare `FOO=1` leaves the case **silently skipped**, which reads as a
  pass in the compact summary — check `scripts/.smoke.log` for `skipped` if a hunt reports
  nothing.
- The first UITest run needs a one-time TCC grant ("XCTest is trying to Enable UI Automation").
- **Output discipline:** `smoke.sh` sends all `xcodebuild` output to `scripts/.smoke.log` and
  prints a compact summary, because dumping it floods an agent's context window. Keep it that
  way; read the log on failure.

## 6. Worktrees

- A fresh worktree **cannot build**: `vendor/ghostty-artifacts/` is git-ignored, so there is no
  `GhosttyKit.xcframework` and linking fails before any Swift compiles. Either run
  `scripts/build-libghostty.sh` there, or make `vendor/ghostty-artifacts/` a **real directory**
  and symlink the framework *inside* it (a symlink at the directory itself isn't matched by the
  trailing-slash ignore pattern and shows up untracked).
- Pass `-derivedDataPath DerivedData` to every `xcodebuild`. Without it, two checkouts race in
  the shared `~/Library/Developer/Xcode/DerivedData`, deleting each other's app mid-launch.
- **qartez mutators are unsafe in a worktree** — they report success while writing to the main
  checkout. Use the built-in `Edit` there.

## 7. Shared checkout

Several agent sessions edit this one checkout concurrently. Never `git stash`, `git checkout
.`, or revert blind — you will silently destroy another session's in-flight work. Check
`git status`/`git diff` and, if changes aren't yours, leave them alone.
