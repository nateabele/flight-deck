# AGENTS.md

Flight Deck — an orchestration-native macOS terminal (Swift/SwiftUI/AppKit) that reuses Ghostty
for terminal rendering and runs many coding agents across repos in a `session → project` sidebar.

**New here? Read [docs/HANDOFF.md](docs/HANDOFF.md) first**, then this file.

---

## Read before you act

Four things trip up every agent on this repo. The detail is in
**[docs/AGENT-OPERATIONS.md](docs/AGENT-OPERATIONS.md)**.

1. **You are probably running inside the app you are editing.** The process tree is
   `Flight Deck.app → login → fish → claude`. Quitting or killing Flight Deck kills your own
   session. Detach anything that must outlive the app (`nohup … &`).
2. **Never launch a bundle from `DerivedData/`.** Flight Deck has no argv parsing — even
   `--help` boots a *second full app instance*, spawning duplicate `claude --resume` processes
   that collide in Claude's pid-keyed name registry. Run only `/Applications/Flight Deck.app`.
3. **Never `defaults delete dev.flightdeck.FlightDeck`.** Preferences live there. Sessions live
   in `~/Library/Application Support/Flight Deck/sessions.json`. Test isolation is the
   `-FlightDeckResetState YES` launch argument, not deletion.
4. **Don't loop `./scripts/smoke.sh`.** It seizes the foreground for ~70s and captures the
   user's keystrokes as phantom test failures. It's throttled to one run per 120s on purpose.
   **To chase a flaky assertion, isolate it — never re-run the suite.** `UITests` is one giant
   test function of `runActivity` groups, so `-only-testing:` cannot target a behavior, and the
   statistics are against you: at a 20% failure rate, five clean whole-suite runs still pass by
   luck 33% of the time, so "5/5 green" is not evidence of a fix. Add a skipped-by-default hunt
   case that loops the suspect sequence inside ONE launch —
   `testPermissionBypassConfirmationUnderChurn` is the worked example: 20 samples in ~107s, 1.2%
   luck, versus ~23 min for the same power via the suite. Gate it on a **`TEST_RUNNER_`-prefixed**
   variable; `xcodebuild` forwards nothing else into the UI-test runner, and a bare one silently
   *skips* the case rather than failing.

Also: this checkout is **shared by concurrent sessions**. Never `git stash`, `git checkout .`,
or revert blind — check `git status` and leave changes that aren't yours alone.

## Commands

```bash
./scripts/build-libghostty.sh   # once, ~10 min — builds GhosttyKit.xcframework
./scripts/build-boringssl.sh    # once, BEFORE ANY BUILD — see below
./scripts/build.sh              # xcodegen generate + xcodebuild → Debug "Flight Deck.app"
./scripts/test-unit.sh          # headless unit suite — your normal TDD loop
./scripts/smoke.sh              # GUI UITest, ends "SMOKE PASS" (see rule 4)

# Flake hunting — loops one suspect sequence 20x in a single launch (rule 4).
# The TEST_RUNNER_ prefix is mandatory; without it the case is silently SKIPPED.
TEST_RUNNER_FLIGHTDECK_FLAKE_HUNT=1 FLIGHTDECK_TEST_THROTTLE=0 ./scripts/smoke.sh

./scripts/build-ios.sh          # builds FleetKitiOS + FlightDeckMobile + its test bundle — run after touching Sources/FleetKit or Sources/FlightDeckMobile
./scripts/test-ios.sh           # runs FlightDeckMobileTests on a simulator this script creates and deletes
./scripts/deploy-phone.sh       # builds, installs and RELAUNCHES on a real device; --release for an optimised build, --no-build to install what is already there

# NOT hermetic — spawns real `codex` processes against your live ~/.codex, and one test
# runs a real model turn that costs real tokens. Never loop it; run it only when you
# have a specific reason to.
./scripts/test-codex-live.sh
```

**`build-boringssl.sh` is a prerequisite for *every* target, not just the iOS ones.** The
name reads like it only matters for pairing, and the macOS app is where that costs you: `FleetKit`
links `BoringSSL.xcframework` (SPAKE2), so a checkout without it fails **both** the macOS Debug and
Release builds with `There is no XCFramework found at vendor/boringssl-artifacts/BoringSSL.xcframework`,
from a target whose name says nothing about pairing. `vendor/boringssl-artifacts/` is gitignored build
output and `vendor/boringssl` is a submodule, so a fresh clone — and any *worktree*, which gets its own
working directory — starts without it.

**If you build before the artifact exists, fix the artifact AND clear the build description.**
Xcode caches the resolution: once one build has failed this way, later builds keep reporting the
xcframework missing even after it is in place, and re-running `xcodegen generate` does not clear it.
`rm -rf DerivedData/Build/Intermediates.noindex/XCBuildData` does.

`test-ios.sh` is `xcodebuild test` rather than `test-unit.sh`'s hand-rolled loader, because the
thing that script routes around (an AppKit host cannot be launched without a GUI login session)
is macOS-only. It builds and boots its **own throwaway simulator** every run: the suite installs
the app onto its destination, so pointing it at a device you have a build on would overwrite it.

Every `xcodebuild` needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and
`-derivedDataPath DerivedData` (the scripts handle both). Never `sudo xcode-select`.
Releases go through `scripts/swap-release.sh`, run detached — see
[docs/AGENT-OPERATIONS.md §2](docs/AGENT-OPERATIONS.md).

## Layout

| Path | What |
|---|---|
| `Sources/FlightDeck/` | The app. `SessionStore` is the single source of truth (`@MainActor`). |
| `Sources/FlightDeck/GhosttyEmbed/` | **Adapt-copied Ghostty** (MIT, provenance-marked). Vendored-ish — prefer re-pulling upstream to hand-editing. |
| `Sources/FlightDeck/Preferences/` | Pure flag catalog/parser/serializer/merge + SwiftUI shell. |
| `Sources/FleetKit/` | Wire types, event fold, pairing payload, and both socket halves — plus both platforms' pairing stores. Swift 6, `Foundation`, `Network`, and `Security` only — compiled for iOS too, which is what enforces that. |
| `Sources/FlightDeck/Fleet/` | The desktop side: projection, replicator, arming window, and the service that binds the store to the socket. |
| `Sources/FlightDeckMobile/` | The iOS companion app: pairing screen (QR scan or typed code), fleet list. **Keep it flat** — `build-ios.sh`'s type-check fallback globs `*.swift` only, so a subdirectory goes silently unchecked on a machine with no iOS platform. See `docs/MOBILE.md`. |
| `Tests/FlightDeckTests/` | Headless unit tests. `UITests/` drives the real app. |
| `Tests/FlightDeckMobileTests/` | The phone app's unit suite, hosted by `FlightDeckMobile` on the simulator. Logic only — SwiftUI layout, the caret and the camera are not reachable; those stay on `docs/MOBILE.md`'s checklists. |
| `project.yml` | Source of truth for the build; `.xcodeproj` is **generated** and git-ignored. |
| `vendor/ghostty` | Submodule pinned to v1.3.1. Pristine — never modify. |
| `vendor/boringssl` | Submodule pinned to tag `0.20250114.0`, for SPAKE2 (pairing). Pristine — never modify. `vendor/boringssl-artifacts/` is its git-ignored build output, not rebuilt by `build.sh` — run `build-boringssl.sh` yourself first, same as libghostty. |
| `docs/` | See below. |

Spine: `FlightDeckApp → RootWindow → RootView → TerminalPane → Ghostty.SurfaceView`.

## Conventions (short version)

Full detail: **[docs/CONVENTIONS.md](docs/CONVENTIONS.md)**.

- **Comments explain *why* and name the failure they prevent** — this is the house style. Audit
  stale comments repo-wide when behavior changes.
- Commits: `fix: stop the unread dot marking every session at launch` — lowercase, behavioral,
  imperative; body covers mechanism, evidence, and rejected alternatives; trailer
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- TDD, and **confirm the test fails against the broken code** before fixing. Never weaken an
  assertion to go green.
- Keep logic pure and SwiftUI-free where possible; put seams behind protocols.
- `SWIFT_VERSION: "5.0"` is deliberate (vendored Ghostty isn't Swift-6 clean). Don't "fix" it.
- Non-trivial work: spec → plan → subagent-driven build, artifacts in `docs/superpowers/`.
- Update the affected doc in the same branch as the behavior change.

## Docs

| Doc | For |
|---|---|
| [docs/HANDOFF.md](docs/HANDOFF.md) | Current state, quickstart, locked decisions. **Start here.** |
| [docs/AGENT-OPERATIONS.md](docs/AGENT-OPERATIONS.md) | Release ritual, process/state hazards, worktrees, test discipline. |
| [docs/CONVENTIONS.md](docs/CONVENTIONS.md) | Code, comment, commit, and workflow conventions. |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | As-built structure, the Ghostty reuse boundary, runtime model. |
| [docs/BUILD.md](docs/BUILD.md) | Build/run/test from a fresh clone + troubleshooting. |
| [docs/TOOLING.md](docs/TOOLING.md) | Toolchain versions and the Zig/SDK linker workaround. |
| [docs/FOLLOWUPS.md](docs/FOLLOWUPS.md) | Known limitations, next fixes, and deliberate non-fixes. |
| [docs/superpowers/specs/](docs/superpowers/specs) · [plans/](docs/superpowers/plans) | Per-feature design specs and executed plans. |

## Known limitation

The libghostty build is **not reproducible on a clean host/CI**: Ghostty pins Zig 0.15.2, whose
Mach-O linker mis-parses the macOS 26.x SDK, so the build shims `xcrun` at a locally-present
`MacOSX15.4.sdk`. It fails fast with a clear error if that SDK is absent.
[TOOLING.md](docs/TOOLING.md) has the full root cause.
