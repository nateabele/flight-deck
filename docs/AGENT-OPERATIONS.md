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
| Only ever `open`s `/Applications/Flight Deck.app` — never the DerivedData bundle | *In this script*, a DerivedData launch would be a second live app on the **same state file**: both restore the deck, both spawn `claude --resume` for the same ids, and the duplicates collide in Claude's pid-keyed name registry — which is why `/rename Crashing` started returning `Crashing-valiant-quilt`. A DerivedData bundle run with `-FlightDeckStateDir` is a different matter and is safe; see §2's rule. The script has no scratch directory to point at, so for it the blanket rule holds. |
| Only relaunches if the app **was** running when the swap began | Don't spring a window on a machine where the user deliberately quit. |
| Stages via `ditto`, backs the old bundle up to `…/Flight Deck/backups/<ts>/`, restores on failure | A half-swapped `/Applications` with no working app. |
| Post-order signal walk (leaves → app), SIGTERM then SIGKILL | Children reparented to `launchd` become unkillable orphans. |
| Uses `ps -A`, not `pgrep -f` | `pgrep -f` matches nothing for this app in this environment; a silent no-match would swap the bundle out from under a live app. |
| Classifies the new bundle **Release / Debug / unknown** by static `otool -L` signals (`.debug.dylib` linkage, `Contents/PlugIns`) — never launches it — and refuses anything but a positively-confirmed Release build unless `FD_SWAP_ALLOW_DEBUG=1` | A Debug bundle installed at `/Applications`: it forks the fleet across two daemon roots (see below) so every restored conversation looks like it lost its last several turns, even though nothing is actually lost. |

Log: `~/Library/Logs/flight-deck-swap.log`. Rollback is printed at the end of every run.

**Before a Release build, rebuild the Linux hostd for BOTH architectures.** Run
`./scripts/build-hostd-linux.sh` with no arguments first. It writes
`build/hostd-release/installer.xcconfig`, which the Release config includes so the app embeds the
digest of that exact `SHA256SUMS`; a build from a one-architecture run (`build-hostd-linux.sh
aarch64`, or `test-hostd-install.sh`, which empties the directory and rebuilds aarch64 only)
would embed a digest the published release cannot match, and every pasted install command would
then refuse with "checksum mismatch". The script writes the xcconfig even after a partial run (a
known gap, in FOLLOWUPS), which is why a stale one-architecture xcconfig was deleted from the
host-foundation worktree. The
assets must then be uploaded, unchanged, as the GitHub release `hostd-v<MARKETING_VERSION>`;
**publishing is the maintainer's step**, no script does it ([HANDOFF.md](HANDOFF.md), "Releasing the
Linux host").

### Debug bundles fork the fleet — the daemon-root split

`bundle_flavor()` returns one of three outcomes, each refused with its own wording unless
`FD_SWAP_ALLOW_DEBUG=1` is set:

| Flavor | Log | Notification |
|---|---|---|
| `debug` | `FATAL: new bundle is Debug, not Release — aborting, nothing changed.` | "Refused to install a Debug bundle — nothing changed" |
| `unknown` (`otool` missing, or `otool -L` failed) | `FATAL: could not determine build flavor (otool unavailable or unreadable) — refusing, nothing changed.` | "Refused to install a bundle of unknown flavor — nothing changed" |
| `release` | (proceeds) | — |

`unknown` gets its own wording rather than being folded into `debug` — calling an undetermined
bundle "Debug" would send the next person down the wrong path. The notification is best-effort:
a successful `osascript` call means the AppleScript ran, not that Notification Center rendered a
banner — delivery depends on the calling binary's notification permission. The log at
`~/Library/Logs/flight-deck-swap.log` is the reliable channel; the notification is the
convenience.

Why this refusal exists: `SessionDaemon.defaultDirectory()`
(`Sources/FlightDeck/SessionDaemon.swift:56`) keys the fd-abduco socket root on build flavor —
Release `/tmp/flight-deck-<uid>`, Debug `/tmp/flight-deck-debug-<uid>` — deliberately, so a
locally launched Debug build never reaps a released build's daemons. Before 2026-09-29
`sessions.json` was shared by both flavors too, so a Debug bundle installed at `/Applications`
restored the live sessions and attached them to whatever sat in the *debug* root. It now reads
`Flight Deck (Debug)/sessions.json` instead, so a Debug bundle there opens its own (usually
empty) deck. Nothing is lost either way: the live daemons keep running in the release root,
and reinstalling a genuine Release bundle restores them.

This doesn't conflict with the `-FlightDeckStateDir` guidance below: that flag redirects
`sessions.json` only, not the daemon root, so a Debug build launched in place with a scratch
state dir stays safe. The hazard above is specifically a Debug bundle *installed at*
`/Applications`, not one launched from `DerivedData/`.

Diagnose in one step:

```bash
rg -N 'new bundle:|flavor:' ~/Library/Logs/flight-deck-swap.log | tail
```

Recover by re-running the swap with a genuine Release bundle — the release-root daemons were
never touched, so nothing needs restoring beyond that.

**Operator env vars:**

| Var | Purpose |
|---|---|
| `FD_SWAP_NEW_APP` | Overrides which bundle path gets installed. Exists so the flavor guard can be exercised against a known-debug bundle without editing the script. |
| `FD_SWAP_CHECK_ONLY=1` | Runs every pre-swap check (executable, `Info.plist`, `codesign --verify`, flavor) and exits before staging — nothing touched. This is the pre-flight. |
| `FD_SWAP_ALLOW_DEBUG=1` | Escape hatch: installs a Debug or unknown-flavor bundle anyway, logging `FD_SWAP_ALLOW_DEBUG=1 — installing a Debug bundle anyway, override recorded` (or the unknown-flavor equivalent). Essentially never use it — it is exactly what forks the fleet across daemon roots, above. |

Pre-flight, before arming a swap:

```bash
FD_SWAP_CHECK_ONLY=1 ./scripts/swap-release.sh
```

**Rule: never launch a `DerivedData/` bundle against the real state directory.** The danger
was never the bundle's location — it is two live apps sharing
`~/Library/Application Support/Flight Deck/sessions.json`. Both restore the same deck, both
spawn `claude --resume` for the same session ids, and the duplicates collide in Claude's
pid-keyed name registry.

**`-FlightDeckStateDir <path>` removes that entirely**, which is what it exists for
(`FlightDeckApp.swift`). Point it at a scratch directory for a fresh deck, or at a *copy* of
the real `sessions.json` to reproduce a specific deck — either is safe, and the choice makes no
difference to the isolation. The real state file is never opened, so no session is restored
twice and nothing collides.

```bash
open -n "DerivedData/Build/Products/Debug/Flight Deck.app" \
  --args -FlightDeckStateDir /tmp/fd-scratch
```

Note `-FlightDeckStateDir` redirects `sessions.json` only. Preferences still resolve to the
shared `UserDefaults` domain, so a debug run can still change a real preference.

**Quitting the Debug app does not undo a collision.** Its daemons are detached (children of
launchd, not of the app), so every session it restored keeps a live fd-abduco daemon in
`/tmp/flight-deck-debug-<uid>/` with its own shell and `claude --resume` inside, long after the
app is gone. The symptom is "two fd-abduco processes" per session in Activity Monitor. On
2026-09-28 one Debug launch from a worktree had left 54 such daemons and 52 duplicate agents
running for a day. Nothing attaches to them, so they sit idle, but each one holds a second
live process on the same transcript.

Diagnose — debug daemons whose session id also has a release daemon are duplicates:

```bash
ps -axo command | rg -o 'flight-deck-debug-[0-9]+/[0-9a-f-]{36}' | wc -l
ps -axo command | rg '^claude .*--plugin-dir .*/DerivedData/'   # agents from a dev bundle
```

Before reaping, check for any debug session with **no** release twin: it was created inside
the Debug app and is absent from `sessions.json`, so its only handle afterwards is
`claude --resume <id>` (its transcript is on disk and survives). Then reap with SIGTERM,
never SIGKILL: agents first, so each closes its JSONL cleanly (a SIGKILL mid-append can tear a
line in a file the live twin is still writing), then the daemons, so each runs its atexit
handler and unlinks its socket and `.pid` sidecar. Write it in bash — in zsh an unquoted
`$pids` does not word-split, so the kill silently gets one invalid argument:

```bash
bash -c 'kill -TERM $(pgrep -f "^claude .*--plugin-dir .*/DerivedData/")
         sleep 2
         kill -TERM $(pgrep -f "/tmp/flight-deck-debug-$(id -u)/fd-abduco -c")'
rm /tmp/flight-deck-debug-$(id -u)/fd-abduco && rmdir /tmp/flight-deck-debug-$(id -u)
```

The release root is never touched. When
counting survivors, don't `pgrep -f` a pattern from inside `bash -c '…'` — the wrapper's own
argv matches and reports phantom processes.

The swap script's own "never `open`s the DerivedData bundle" guarantee above is narrower and
still correct: it runs unattended against the live deck, where there is no scratch directory in
play and a second instance would be exactly the collision described.

## 3. Process hygiene

- Orphaned `claude` processes are a real, recurring failure mode. `SessionReaper` +
  `ProcessTree` exist to reap a session's tree (SIGHUP → SIGTERM → SIGKILL with deadlines)
  before the surface is freed and before quit.
- Process identity is read via `sysctl`, not `libproc`, and start times gate the kill so a
  recycled pid is never signalled. Don't "simplify" that.
- `scripts/hangwatch.sh [outdir]` auto-captures a symbolicated stack sample when the main
  thread stalls (beach ball). Leave it running, use the app, samples land in the outdir.

### The host daemon (`flightdeck-hostd`)

Flight Deck can run a second long-lived process of its own: the **hostd**, which lets other Flight
Decks pair with this machine and run `host info` against it. It is a LaunchAgent
(`dev.flightdeck.hostd`, registered through `SMAppService` from Settings → Hosting), a child of
`launchd` and not of the app, so quitting or swapping Flight Deck does not stop it and it
survives `swap-release.sh`. It listens on **47410** (the host connection) and, only while a
pairing window is armed, on a second port (47411 on Linux; an ephemeral one on a Mac), and it
keeps an admin socket at `<state root>/admin.sock`.

It ships as its own helper app, `Flight Deck.app/Contents/Library/LoginItems/Flight Deck Host.app`
(bundle id `dev.flightdeck.hostd`, `LSUIElement`), executable `flightdeck-hostd`. Through the
build that kept it bare at `Contents/MacOS/flightdeck-hostd`, a host Mac could not open Flight Deck
at all: hostd's `NSApplication` checked in with LaunchServices as `dev.flightdeck.FlightDeck`, so
`open -a`, Finder and the Dock activated hostd instead of launching the app.

- **After installing the first build with the helper layout over an older one, toggle Hosting off
  and on** on a host Mac. The registered agent's job was loaded with the old `BundleProgram`, a
  path the new bundle no longer has, so a restart of that job cannot find its binary until the
  agent is re-registered (inferred from how launchd loads a job; not observed live).

- **Stop it with the Hosting toggle** (Settings → Hosting → "Let other Macs use this Mac" off), or
  from a shell: `launchctl bootout gui/$UID/dev.flightdeck.hostd`. It exits 0 on SIGTERM and
  unlinks its admin socket. Do not `kill -9` it, least of all mid-pairing: the admin socket file
  is left behind, and a window that was armed dies with the code the user was reading.
- **Debug and Release share ONE hostd.** The label, port 47410 and the state root
  (`~/Library/Application Support/Flight Deck Host`) are the same in both, so there is no
  "Debug hostd". Enabling Hosting from a Debug build registers the agent from that bundle, so a
  Release build may find it already registered and running the other build's binary (inferred
  from the shared label; not observed live). If hosting looks wrong after switching builds, toggle it off and on from the
  build you mean to use. This is unlike `sessions.json`, which Debug splits off on purpose (see
  "Debug bundles fork the fleet").
- **On a Linux host, list and revoke from a shell:** `flightdeck-hostd controllers` prints each
  paired controller as `SLOT<TAB>NAME<TAB>PAIRED-AT` (`--json` for JSON); `flightdeck-hostd revoke
  SLOT` unpairs one and cuts its live connection. Both exit 2 when hostd is not running. A Mac host
  does the same from Settings → Hosting.
- **Never launch the hostd binary or `Flight Deck Host.app` by hand from `DerivedData/` to "try it".** It binds 47410 and
  the admin socket in the real state root, which belong to the live hostd.
- Interop tests (`test-hostd-linux-interop.sh`) bind fixed ports (47410, 47411) and share the
  package's one `.build`: **never run two at once, and never alongside `test-hostd-linux.sh`.**
  The loser reports a bind failure or a corrupted build tree that has nothing to do with its code.
  They also fail if a real hostd is already holding 47410 on the same machine.
- **Turn Hosting off before `test-hostd-linux-interop.sh run` (and `serve`).** Both publish the
  container's hostd on `127.0.0.1:47410`, the port this Mac's own hostd listens on whenever
  Settings → Hosting is on. With both up, the publish fails, or the Darwin side of the gate dials
  the live hostd instead of the container; either way the failure says nothing about the code.
  `FD_INTEROP_PORT` moves the gate to another port when Hosting has to stay on.

### Delegated runs (sub-project C)

With Hosting on, this Mac runs other Macs' `flightdeck run|up` commands, and its own tabs can send
theirs elsewhere. Four consequences for anyone working here:

- **The hostd runs user commands that outlive the app.** A delegated run or service is a process
  group under the hostd, not under Flight Deck, so quitting or swapping the app does not stop it. A
  service (`up`) runs until `down`, until its tab closes, or until no controller has been connected
  for its orphan timeout (30 minutes by default). Stopping the hostd (the Hosting toggle,
  `launchctl bootout`, an update that restarts it) stops its work cleanly: on SIGTERM it downs
  every service, running its `down` command, and cancels every run within launchd's 20 s exit
  timeout, and a hostd that crashed kills the process groups it had recorded when it next starts.
  To see what is running, `flightdeck ps` from a plain shell on the controller lists every tab's
  runs.
- **Screen runs keep the display awake.** While a `screen = true` run holds the host's screen, the
  hostd holds a display-sleep assertion and shows a "don't touch" panel; every run also holds an
  idle-sleep assertion. `pmset -g assertions` names them (`Flight Deck screen run <id>`,
  `Flight Deck run <id>`). A run that never ends keeps the Mac awake until it is stopped
  (`flightdeck stop <id>` from the controller) or Hosting is turned off.
- **Agent tabs get route shims.** Every tab's `PATH` starts with
  `<state dir>/route-shims/<session id>/` (Debug: under `Flight Deck (Debug)/`), and the shell's
  startup snippet puts it back in front after the user's own profile has run. In a project whose
  `.flightdeck/delegate.toml` has `[[route]]` rules, a matching command typed by an agent (say
  `xcodebuild test …`) runs on a host, not here. `FLIGHTDECK_NO_ROUTE=1` (any non-empty value other
  than `0`) bypasses routing for that command. This repo has no `delegate.toml`, and could not
  delegate anyway: it has submodules, which v1 refuses (`submodules_unsupported`).
- **Debug builds do not write `~/.codex`.** A Debug codex start skips installing the `delegate`
  skill into the real `~/.codex/skills/` (it logs once); only a Release build installs or
  refreshes it. A Debug build that predates this fix did write it, and the next Release start
  rewrites it.

## 4. State: where it lives, what never to delete

| What | Where |
|---|---|
| Sessions, projects, order, collapse, pins | `~/Library/Application Support/Flight Deck/sessions.json` (atomic write) |
| Preferences (`preferences.v1`) | `UserDefaults`, domain `dev.flightdeck.FlightDeck` |
| Window geometry | `UserDefaults` + `~/Library/Saved Application State/…` |
| Paired hosts (controller side) | `~/Library/Application Support/Flight Deck/hosts.json` (never in `sessions.json`); their secrets in the login Keychain, service `dev.flightdeck.host`, one item per slot |
| Paired controllers (host side) | `~/Library/Application Support/Flight Deck Host/controllers.json`, mode 0600 in a 0700 directory (Linux: `$XDG_DATA_HOME` or `~/.local/share/flightdeck-hostd`) |
| Delegated runs (controller side) | `~/Library/Application Support/Flight Deck/delegation.json` (the run registry), `delegation/` beside it (each run's output copy and result bundles), `route-shims/<session id>/` (per-tab shims, rebuilt at launch) |
| Delegated work (host side) | Under the hostd's state root: `workspaces/<controller slot>/` (object stores and checkouts, cleared only by `flightdeck host prune`) and `runs/<id>/` (spooled output, pruned after 24 h) |

- **Never `defaults delete dev.flightdeck.FlightDeck`.** It nukes preferences; it used to nuke
  every session too, on every smoke run. Delete individual geometry keys only — the list
  `smoke.sh` uses is the correct one.
- Sessions moved *out* of `UserDefaults` deliberately: `defaults delete` is a routine debugging
  gesture, `cfprefsd` coalesces writes so a `SIGKILL` can drop the last one, and the snapshot
  grows with sessions × projects.
- **`kSecAttrAccessible` on the host secrets is probably advisory.** `HostSecretStore` sets
  `AfterFirstUnlockThisDeviceOnly`, but the macOS file-based login keychain (which an
  unentitled app uses) does not appear to enforce data-protection classes the way the iOS
  keychain does. Treat the Keychain as "an app-ACL-protected file", not as hardware-bound. Not
  verified against a data-protection keychain.
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
- **To run one test class, use the DOT spelling — `-XCTest FlightDeckTests.SomeClass`, never
  `FlightDeckTests/SomeClass`.** The slash is `xcodebuild -only-testing:`'s spelling and the one
  a hand reaches for, and under `xctest` it **runs zero tests and reports success**. Measured
  here on the same bundle in the same second:

  ```
  -XCTest FlightDeckTests/ChoiceDialogTests    Executed 0 tests   ("Selected tests" passed)
  -XCTest FlightDeckTests.ChoiceDialogTests    Executed 21 tests, with 0 failures
  ```

  That matters most when mutating: a mutation "verified" through the slash spelling produces no
  failures and looks proven, when nothing ran at all. **Report the executed count beside every
  mutation result**, and read a zero as a broken filter rather than as a clean suite. Run it the
  way `test-unit.sh` does — the same `DYLD_FRAMEWORK_PATH` and the resolved `xcrun --find
  xctest` binary — or the bundle fails to load for an unrelated reason.
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
- **quillmap mutators are unsafe in a worktree** — they report success while writing to the main
  checkout. Use the built-in `Edit` there.

## 7. Shared checkout

Several agent sessions edit this one checkout concurrently. Never `git stash`, `git checkout
.`, or revert blind — you will silently destroy another session's in-flight work. Check
`git status`/`git diff` and, if changes aren't yours, leave them alone.
