# Flight Deck — Build, Run & Test

Practical how-to. For *why* the toolchain is unusual (the Zig/SDK linker workaround), see
[TOOLING.md](TOOLING.md); for known build limitations, [FOLLOWUPS.md](FOLLOWUPS.md).

## Prerequisites (this host)

- **Full Xcode** (built with 26.6) installed at `/Applications/Xcode.app`. The active
  `xcode-select` dir is Command Line Tools, so **every** `xcodebuild`/`xcodegen`/`xcrun`
  invocation must run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
  The scripts export this themselves — **do not run `sudo xcode-select`.**
- **`xcodegen`** (`brew install xcodegen`) — the `.xcodeproj` is generated from `project.yml`.
- **Zig 0.15.2** — auto-downloaded by `scripts/build-libghostty.sh` into `vendor/.zig-toolchain/`
  (checksum-verified). You don't install it yourself. The Homebrew Zig (if any) is left alone.
- **A local `MacOSX15.4.sdk`** at `/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk`.
  This is the linchpin of the workaround (see TOOLING.md). If absent, the libghostty build
  **fails fast with a clear error** — it is not reproducible without it (see "Limitations").

Exact recorded versions: [TOOLING.md](TOOLING.md).

## From a fresh clone

```bash
git clone <flight-deck remote or path> flight-deck && cd flight-deck
git submodule update --init            # checks out vendor/ghostty at pinned v1.3.1
./scripts/build-libghostty.sh          # ~10 min first run (builds libghostty from source)
./scripts/build.sh                     # xcodegen generate + xcodebuild → "Flight Deck.app"
open "DerivedData/Build/Products/Debug/Flight Deck.app"
```

You should see a "Flight Deck" window with a live shell prompt.

## The scripts

| Script | Does | Notes |
|---|---|---|
| `scripts/build-libghostty.sh` | Builds `libghostty` from the pinned submodule → stages `vendor/ghostty-artifacts/GhosttyKit.xcframework` | Downloads Zig 0.15.2 if missing; creates the `xcrun` SDK shim in `vendor/.build-shim/`; builds via the 15.4 SDK; `git clean`s the submodule after staging. Idempotent. Re-run only if the xcframework is missing or you re-pin Ghostty. |
| `scripts/build.sh` | `export DEVELOPER_DIR` → `xcodegen generate` → `xcodebuild ... build` | Builds the app. Assumes the xcframework already exists (run `build-libghostty.sh` once first). |
| `scripts/test-unit.sh` | Runs the headless unit test suite (`FlightDeckTests`) | The actually-working path for unit tests — see below. Needs the xcframework staged first, same as `build.sh`. |
| `scripts/smoke.sh` | Clears saved window *geometry* → `build.sh` → `xcodegen generate` → runs the UI smoke test → prints `SMOKE PASS` | See "One-time UI-automation grant" below. It deliberately does **not** clear sessions or preferences — the app isolates those itself via `-FlightDeckResetState`. |

## Running tests

**Unit tests** (fast, no special permission):

```bash
./scripts/test-unit.sh
# → all FlightDeckTests pass (count grows over time; see the script's own output)
```

**Smoke test** (launches the app, asserts the window renders):

```bash
./scripts/smoke.sh          # → ends with: SMOKE PASS
```

### One-time UI-automation grant

The first time the XCUITest runs, macOS shows **"XCTest is trying to Enable UI Automation —
Touch ID or enter your password."** Approve it once (Touch ID / password); it's a persistent
TCC grant, so subsequent `smoke.sh` runs (and CI, if the machine is pre-authorized) don't prompt.

## Troubleshooting

- **`xcodebuild: error ... requires Xcode` / SDK not found** — you didn't set `DEVELOPER_DIR`.
  Use the scripts, or prefix commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- **`build-libghostty.sh` errors that `MacOSX15.4.sdk` is missing** — the workaround needs that
  SDK present (see TOOLING.md). It cannot build without it on this Zig/macOS combination.
- **App launches off-screen / window seems missing** — stale macOS window-state restoration
  (e.g. keyed to a disconnected external display). Reset just the geometry:
  ```bash
  defaults delete dev.flightdeck.FlightDeck "NSWindow Frame main"
  rm -rf ~/Library/Saved\ Application\ State/dev.flightdeck.FlightDeck.savedState
  ```
  `smoke.sh` already does this before each run. **Do not `defaults delete` the whole domain** —
  preferences live there (`preferences.v1`), and it is how sessions used to get destroyed on
  every smoke run. Sessions themselves are now in
  `~/Library/Application Support/Flight Deck/sessions.json`.
- **`import GhosttyKit` fails / linker errors about `std::*`** — the xcframework isn't built
  (`./scripts/build-libghostty.sh`) or `OTHER_LDFLAGS: -lstdc++` was removed from `project.yml`.
- **Swift 6 concurrency errors in `GhosttyEmbed/`** — `SWIFT_VERSION` must be `"5.0"` (see
  ARCHITECTURE.md / FOLLOWUPS.md); the vendored Ghostty code isn't Swift-6 strict-concurrency clean.

## Worktrees

A fresh git worktree of this repo cannot build until `vendor/ghostty-artifacts/` is
populated — it is git-ignored, so a new worktree has no `GhosttyKit.xcframework` and
`xcodebuild` fails at framework linking before compiling any Swift. Either run
`scripts/build-libghostty.sh` in the worktree, or create `vendor/ghostty-artifacts/` as a
real directory and symlink `GhosttyKit.xcframework` into it from the main checkout. Note
it must be a real directory with the framework symlinked *inside* — a symlink at
`vendor/ghostty-artifacts` itself is not matched by the trailing-slash `.gitignore`
pattern and shows up as untracked. When the framework is a cross-checkout symlink,
`xcodebuild` needs to resolve outside the worktree, so a sandboxed shell will block it.

## Limitations (build reproducibility)

The libghostty build works on **this host** but is **not reproducible on an arbitrary clean
machine / CI** until Zig ships a 0.15.x linker backport (or Ghostty moves to Zig 0.16): it
depends on a locally-accumulated `MacOSX15.4.sdk`. This is tracked in [FOLLOWUPS.md](FOLLOWUPS.md)
and the root cause is in [TOOLING.md](TOOLING.md) (upstream zig#31658).
