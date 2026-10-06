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
git submodule update --init            # checks out vendor/ghostty and vendor/boringssl
./scripts/build-libghostty.sh          # ~10 min first run (builds libghostty from source)
./scripts/build-boringssl.sh           # builds BoringSSL (SPAKE2, for pairing) from source
./scripts/build-fd-abduco.sh           # builds the fd-abduco daemon binary (seconds)
./scripts/build.sh                     # xcodegen generate + xcodebuild → "Flight Deck.app"
open "DerivedData/Build/Products/Debug/Flight Deck.app"
```

You should see a "Flight Deck" window with a live shell prompt.

## The scripts

| Script | Does | Notes |
|---|---|---|
| `scripts/build-libghostty.sh` | Builds `libghostty` from the pinned submodule → stages `vendor/ghostty-artifacts/GhosttyKit.xcframework` | Downloads Zig 0.15.2 if missing; creates the `xcrun` SDK shim in `vendor/.build-shim/`; builds via the 15.4 SDK; `git clean`s the submodule after staging. Idempotent. Re-run only if the xcframework is missing or you re-pin Ghostty. |
| `scripts/build-boringssl.sh` | Builds BoringSSL's `libcrypto` (for SPAKE2, the pairing PAKE) from the pinned submodule → stages `vendor/boringssl-artifacts/BoringSSL.xcframework` | Needs `cmake`, `ninja` and `go` on `PATH`. Refuses to build if `vendor/boringssl` has drifted off its pinned tag, rather than silently building whatever is checked out. Re-run only if the xcframework is missing or you re-pin BoringSSL. |
| `scripts/build-fd-abduco.sh` | Builds the `fd-abduco` fork (a plain C daemon binary, no Xcode involved) → stages `vendor/fd-abduco-artifacts/fd-abduco` | Universal (`arm64`+`x86_64`) Mach-O, built in seconds with the system `cc`. `project.yml`'s `FlightDeck` target copies this into the app bundle at **`Contents/Resources/fd-abduco`** (a Copy Files build phase, executable bit preserved) — that is the exact bundle-relative path a later phase resolves via `Bundle.main.url(forResource: "fd-abduco", withExtension: nil)` and execs. Must run before `scripts/build.sh` (or the app builds with no `fd-abduco` to copy — the Copy Files phase input simply won't exist yet). Re-run only if the binary is missing or `vendor/fd-abduco` changes. |
| `scripts/build.sh` | `export DEVELOPER_DIR` → `xcodegen generate` → `xcodebuild ... build` | Builds the app. Assumes both xcframeworks already exist (run `build-libghostty.sh` and `build-boringssl.sh` once first) and, since this fork, that `vendor/fd-abduco-artifacts/fd-abduco` exists too (run `build-fd-abduco.sh` once first). |
| `scripts/test-unit.sh` | Runs the headless unit test suite (`FlightDeckTests`) | The actually-working path for unit tests — see below. Needs both xcframeworks staged first, same as `build.sh`. |
| `scripts/smoke.sh` | Runs `smoke-remote.sh` (below). With `FD_SMOKE_LOCAL=1` instead: clears saved window *geometry* → `build.sh` → `xcodegen generate` → runs the UI smoke test on THIS Mac → prints `SMOKE PASS` | The local path takes over the screen for minutes; see "One-time UI-automation grant" below. It deliberately does **not** clear sessions or preferences — the app isolates those itself via `-FlightDeckResetState`. |
| `scripts/smoke-remote.sh` | Locks the UI-test Mac (`FD_UITEST_HOST` from `scripts/local.env`) → `build-for-testing` here → rsyncs the products and this Xcode's test frameworks (`xctest26/`) there → `scripts/patch-xctestrun.py` → `xcodebuild test-without-building` there → copies the log and `.xcresult` back to `DerivedData/smoke-remote/` → reaps the run's leftover daemons and agents → prints `SMOKE PASS` | Fails rather than falling back to this Mac when the host is unreachable. The `xctest26` shim exists because the remote Xcode is older and would otherwise load its own XCTest into a runner built against this one; it is re-shipped automatically when this Xcode's build number changes. Full mechanics: AGENT-OPERATIONS.md §5, "The UI suite runs on another Mac". |

### The host scripts (HostKit, the Linux hostd)

These need **Docker** (OrbStack here): the Linux hostd builds and tests in `swift:6.3-noble`.
None of them is part of `build.sh`; `HostKit` and the macOS `HostDaemon` build with the app, and
the Linux package (`Packages/HostDaemonLinux`) is never seen by Xcode.

| Script | Does | Notes |
|---|---|---|
| `scripts/build-boringssl-linux.sh [aarch64\|x86_64]` | Builds `libcrypto.a` from the pinned `vendor/boringssl` → `vendor/boringssl-artifacts/linux-<arch>/` | The Linux hostd's SPAKE2. Separate from swift-nio-ssl's own prefixed BoringSSL, so the two link side by side. Run once per checkout before the interop script or `test-hostd-linux.sh`. Default arch is this machine's. |
| `scripts/test-hostkit.sh` | `swift test` in `Packages/HostKit` on macOS, then in `swift:6.3-noble` | HostKit is Foundation-only so it compiles on both; the Linux pass is what stops a Darwin-only API creeping in. |
| `scripts/test-hostd-linux.sh` | `Packages/HostDaemonLinux`'s own tests in `swift:6.3-noble` | Linux only: the package links Linux libcrypto. Shares the package's `.build` with the interop script. |
| `scripts/test-hostd-linux-interop.sh <mode>` | Builds the Linux hostd, runs it in a container on a published port, then runs the Darwin side through `test-unit.sh` scoped to the mode's test class (`LinuxHostdInteropTests`, or `LinuxHostdRunInteropTests` for `run`) | Modes: `echo` (gate 1: Darwin TLS-PSK to swift-nio-ssl over 0xCCAC, plus a wrong-key refusal), `pair` (gate 2: a Darwin `PairingInitiator(profile: .host)` pairs with the Linux SPAKE2 responder), `pair-wrong` (three wrong codes exhaust the window; the container must exit 1), `serve` (a full hostd on 47410 with pairing on 47411: hello, `host.info`, revoke, pair-then-hello), `run` (delegated execution against the real `serve` on 47410: the app's factory-built `DelegationService` syncs a temp repo with an uncommitted edit, runs `echo`, then `git status`/`rev-parse HEAD` in the synced checkout, which must be clean, at the snapshot commit, and carry the edit). A gate test that is skipped or not run **fails** the script. |
| `scripts/build-hostd-linux.sh [arch ...]` | Builds the release assets in `build/hostd-release/`: a static-stdlib tarball per architecture, `hostd-install.sh` with the release URL baked in, `SHA256SUMS`, and `installer.xcconfig` | Default is both architectures; x86_64 is emulated and slow. Run it with **no arguments** before a Release build (see AGENT-OPERATIONS.md §2). Uploads nothing. |
| `scripts/test-hostd-install.sh` | Runs the pasted install command in `ubuntu:24.04` against a local HTTP server; ends `INSTALL PASS` | Rebuilds aarch64 only and **empties `build/hostd-release/`**; `FD_HOSTD_SKIP_BUILD=1` reuses what is there. |
| `scripts/hostd-install.sh` | The installer itself, not a build step | The source copy has an `@FD_HOSTD_ASSET_BASE@` placeholder and needs `--asset-base`; `build-hostd-linux.sh` stamps the release URL into the copy that ships. |

**Never run two interop runs at once, or one next to `test-hostd-linux.sh`.** They bind fixed
host ports (47410, 47411) and share `Packages/HostDaemonLinux/.build`, so the second one fails
with a bind error or a half-written build tree, neither of which points at the real cause.

`build-boringssl.sh` and `build-boringssl-linux.sh` are different artifacts: the first is the
macOS/iOS xcframework `FleetKit` links, the second is the Linux static library only the hostd uses.

### Delegated execution (sub-project C)

Delegation adds no build step: its HostKit half builds with the app and both hostds, and its app
half is ordinary `FlightDeck` sources. What it does add:

| Script / mode | Does | Notes |
|---|---|---|
| `scripts/test-hostkit.sh` | Also runs every delegation class in `Packages/HostKit/Tests/HostKitTests/` (`ChannelMux`, `Snapshotter`, `Workspace`, `ResultApplier`, `Runner`, `OutputSpool`, `ScreenLease`, `PortCheck`, `Preflight`, the TOML parser, writer and route matcher, the wire), on macOS and in `swift:6.3-noble` | The sync tests drive real git against temp repos and need **git 2.40 or later** on both sides (`merge-tree --write-tree --merge-base`); so does a real host. |
| `FD_TEST_FILTER=… ./scripts/test-unit.sh` | The app's delegation classes: `DelegationServiceTests`, `DelegationStreamTests`, `DelegationReplyStreamTests`, `DelegationRunRegistryTests`, `DelegationCLIRunnerTests`, `DelegationCLIArgumentsTests`, `DelegationRouteParityTests`, `DelegationFleetServiceTests`, `DelegationControlWireTests`, `DelegationBootstrapTests`, `RouteShimsTests`, `PluginReloadTests`, `DelegateSkillTests`, `PortForwarderTests`, `ScreenPanelStateTests`, the link's `HostChannelLoopbackTests` (channel frames over a real TLS connection to an in-process hostd), and the live adapters' `LiveHostLinkTests`, `RunMirrorTests`, `LiveAdapterTests`, `HostLinkDelegationTests` | Exits 0 even when a test fails: `rg -n "error:\|failed \("` the output. `RouteShimsTests` runs the real shim script under bash; its hang case takes about 3 s by design. |
| `FD_TEST_FILTER=DelegationLoopbackTests ./scripts/test-unit.sh` | `flightdeck run` end to end with nothing faked: the factory-built `DelegationService` over a real TLS `HostLink` to an in-process `DarwinHostServer` running real processes in temp git repos. Sync, run, exit codes, result patch and `run.ack`, artifacts, a forwarded service port, a link drop mid-run, the screen queue, preflight failures, `exec`, `logs` replay before and after a relaunch, and a service downed by a shortened orphan timeout once its controller is gone | About 16 s. Its tearDown downs every run the host's runner still has, so a failed test leaves no process behind. Hermetic: stub `xcodebuild` and `docker` go first on the host's `PATH` through the host `HOME`'s `.profile` (runs use a login shell, whose path_helper would reorder an inherited `PATH`), and the console probe is fixed. Launches no bundle. |
| `scripts/delegation-probes/p1_plugin_reload.py <trusted-dir> [plugin-dir]` | Probe P1: drives a real interactive `claude` in a pty and reads its slash-command autocomplete before and after `/reload-plugins` | Needs a venv with `pyte` (the usage line is in its docstring). Spends no model tokens, but it is a real claude process: run it from a folder claude already trusts. |
| `scripts/delegation-probes/p2_skill_roots.py <codex>` | Probe P2a: which directories codex's skill loader scans, over `codex app-server` stdio | Zero tokens; sandboxed `HOME`/`CODEX_HOME`. Run it for **both** codex installs. |
| `scripts/delegation-probes/p2_fake_upstream.py <codex> skill\|devinst` | Probe P2b: what `codex exec` actually sends the model, captured by a local server that answers 500 | Zero tokens. |

P3 and P4 (an XCTest UI suite from the hostd LaunchAgent, and the screen-lock read) have no
script: they need a real second Mac and are the maintainer's, written up as procedures in
[DELEGATION-PROBES.md](DELEGATION-PROBES.md).

**Route shims at run time.** A Debug build writes its shims under its own state directory
(`Application Support/Flight Deck (Debug)/route-shims/`), and a UITest reset writes none. To run a
routed command locally in a tab, set `FLIGHTDECK_NO_ROUTE=1`.

## Running tests

**Unit tests** (fast, no special permission):

```bash
./scripts/test-unit.sh
# → all FlightDeckTests pass (count grows over time; see the script's own output)
```

**Smoke test** (the UI suite, on the UI-test Mac):

Configure the UI-test Mac once: `cp scripts/local.env.example scripts/local.env` and set
`FD_UITEST_HOST` there. The file is git-ignored, so the host never lands in this public repo.

```bash
./scripts/smoke.sh                          # → ends with: SMOKE PASS
FD_UITEST_HOST=me@other-mac ./scripts/smoke.sh   # a different UI-test Mac
FD_SMOKE_LOCAL=1 ./scripts/smoke.sh         # on THIS Mac; takes over the screen
```

A UI-test Mac needs: ssh key login for `FD_UITEST_HOST`, an Xcode (any version new enough to run
`test-without-building`; this Mac's XCTest is shipped alongside), the UI-automation grant below,
a logged-in GUI session with the screen unlocked, and, for the claude and codex
investigations, `claude` and a `codex` at least `CodexProcessTransport.minimumVersion` on the
login shell's PATH.

**`fd-abduco` tests** (build + unit trim + live create/attach/replay/budget-trim of the
detached-session daemon; no app build needed):

```bash
bash Tests/fd-abduco/run_all.sh
# → ALL fd-abduco tests OK
```

### One-time UI-automation grant

The first time the XCUITest runs, macOS shows **"XCTest is trying to Enable UI Automation —
Touch ID or enter your password."** Approve it once (Touch ID / password); it's a persistent
TCC grant, so subsequent `smoke.sh` runs (and CI, if the machine is pre-authorized) don't prompt.
It is per machine: the UI-test Mac has its own, already granted.

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
  `~/Library/Application Support/Flight Deck/sessions.json` — or, for a Debug build,
  `~/Library/Application Support/Flight Deck (Debug)/sessions.json`, so a Debug launch never
  restores the live deck.
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

`vendor/boringssl-artifacts/` is the same story, for the same reason: git-ignored, so a fresh
worktree has no `BoringSSL.xcframework` either, and needs its own `scripts/build-boringssl.sh`
run (or the same real-directory-plus-symlink treatment) before `FleetKit`, `FleetKitiOS` or
`FlightDeckTests` will link.

`vendor/fd-abduco-artifacts/` is git-ignored too, but unlike the two xcframeworks above it costs
nothing to just build directly in the worktree — `scripts/build-fd-abduco.sh` is a few seconds
of plain `cc`, no SDK pin or Zig toolchain involved — so there is no need for the
real-directory-plus-symlink workaround here.

## Limitations (build reproducibility)

The libghostty build works on **this host** but is **not reproducible on an arbitrary clean
machine / CI** until Zig ships a 0.15.x linker backport (or Ghostty moves to Zig 0.16): it
depends on a locally-accumulated `MacOSX15.4.sdk`. This is tracked in [FOLLOWUPS.md](FOLLOWUPS.md)
and the root cause is in [TOOLING.md](TOOLING.md) (upstream zig#31658).
