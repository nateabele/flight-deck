# Flight Deck Walking Skeleton — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a from-scratch macOS app ("Flight Deck") whose window renders a **reused Ghostty terminal surface** running a real interactive shell — proving the highest-risk integration before any orchestration is built.

**Architecture:** Flight Deck is a Swift + AppKit/SwiftUI + Metal app on the same stack as Ghostty's macOS app. Rather than reimplement a terminal, it **vendors Ghostty's `macos/Sources/Ghostty` Swift module** (the SwiftUI-consumable wrapper around `libghostty`) plus a Zig-built `libghostty`, and hosts its `SurfaceView` in Flight Deck's own SwiftUI window. This plan builds only the terminal surface (spec §3 Terminal Core, and the first task of spec §9 phase 1). Adapters, context engine, index, and sidebar are separate later plans.

**Tech Stack:** Swift 6 / Xcode 16+, SwiftUI + AppKit, Metal (via reused Ghostty), `libghostty` (built with Zig), **XcodeGen** (text-defined `.xcodeproj` so the project is reproducible from the CLI), `xcodebuild`.

**Testing strategy (read this first):** A terminal surface is integration scaffolding, not pure logic — its correctness is "it builds, launches, renders, and runs a shell," verified by a **build + launch smoke test** (an `XCUITest` that launches the app and asserts the terminal surface exists, plus a manual verification checklist). Classic unit-TDD applies to the *pure-logic* subsystems (event normalization, store reducers, context assembly) which live in later plans, not here. Where a genuine unit exists in this plan (the shell-resolution helper in Task 5), it gets a real unit test first.

**Vendoring / license note:** Ghostty is MIT-licensed; vendoring its Swift module + linking `libghostty` is permitted. Pin a specific upstream revision (Task 1) and keep Flight Deck's changes to vendored files at zero in this plan (reuse unmodified) so upstream rebases stay trivial. Confirm the current license text at the pinned revision during Task 1.

---

## File Structure

Created by this plan (under the `flight-deck` repo root):

| Path | Responsibility |
|---|---|
| `vendor/ghostty/` | Pinned clone of `ghostty-org/ghostty` (git submodule) — source of the reused module + `libghostty` build |
| `vendor/ghostty-artifacts/` | Built `libghostty` output (headers + static lib / xcframework); git-ignored |
| `project.yml` | XcodeGen spec defining the `FlightDeck` app target, its sources, and the libghostty link |
| `Sources/FlightDeck/FlightDeckApp.swift` | SwiftUI `@main` app entry; owns the Ghostty app-state object |
| `Sources/FlightDeck/RootWindow.swift` | The main `WindowGroup` / `Scene` and root SwiftUI view |
| `Sources/FlightDeck/TerminalContainer.swift` | Flight Deck view that hosts the reused Ghostty `SurfaceView` |
| `Sources/FlightDeck/ShellResolver.swift` | Pure helper: resolve the shell to launch (env `SHELL` → `/bin/zsh` fallback) |
| `Sources/FlightDeck/FlightDeck.entitlements` | Sandbox/entitlements needed for a terminal (inherit from Ghostty's debug entitlements) |
| `Tests/FlightDeckTests/ShellResolverTests.swift` | Unit test for `ShellResolver` |
| `UITests/FlightDeckUITests/TerminalSmokeTests.swift` | Launch smoke test asserting the terminal surface renders |
| `scripts/build.sh` | Wrapper: build libghostty (if stale) → xcodegen generate → xcodebuild |
| `scripts/smoke.sh` | Build, launch the app, run the UI smoke test, report pass/fail |

Reused unmodified from `vendor/ghostty/macos/Sources/Ghostty/` (added to the target as source refs, not copied): `GhosttyPackage.swift`, `Ghostty.App.swift`, `Ghostty.Surface.swift`, `Surface View/*`, `Ghostty.Input.swift`, `Ghostty.Action.swift`, `Ghostty.Config.swift`, `Ghostty.Shell.swift`, `Ghostty.Error.swift`, `Ghostty.Event.swift`, and their `Helpers/` dependencies (exact set resolved in Task 3 by following compile errors).

---

## Task 0: Tooling prerequisites

**Files:** none (environment only)

- [ ] **Step 1: Verify Xcode + Swift**

Run: `xcodebuild -version && swift --version`
Expected: Xcode 16 or newer; Swift 6.x. If missing, stop and install Xcode from the App Store.

- [ ] **Step 2: Install Zig (to build libghostty) and XcodeGen**

Run: `brew install zig xcodegen && zig version && xcodegen --version`
Expected: prints a Zig version (0.14+) and an XcodeGen version. (Ghostty pins a Zig version in its `build.zig.zon`/`.zigversion`; Task 1 Step 3 reconciles if the build complains.)

- [ ] **Step 3: Commit a tooling note**

Create `docs/TOOLING.md` with the exact versions printed above, then:
```bash
git add docs/TOOLING.md
git commit -m "chore: record toolchain versions for the walking skeleton"
```

## Task 1: Vendor and build Ghostty / libghostty

**Files:**
- Create: `vendor/ghostty` (submodule), `vendor/ghostty-artifacts/` (git-ignored), `scripts/build-libghostty.sh`
- Modify: `.gitignore`

- [ ] **Step 1: Add Ghostty as a pinned submodule**

```bash
git submodule add https://github.com/ghostty-org/ghostty vendor/ghostty
cd vendor/ghostty && git checkout <LATEST_STABLE_TAG_OR_KNOWN_GOOD_SHA> && cd ../..
git config -f .gitmodules submodule.vendor/ghostty.branch main
```
Record the exact SHA checked out. Read `vendor/ghostty/LICENSE` and confirm it is MIT; note it in `docs/TOOLING.md`.

- [ ] **Step 2: Ignore build artifacts**

Append to `.gitignore`:
```
vendor/ghostty-artifacts/
DerivedData/
*.xcodeproj
```
(The `.xcodeproj` is generated by XcodeGen from `project.yml`, so it is not committed.)

- [ ] **Step 3: Build libghostty**

Create `scripts/build-libghostty.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../vendor/ghostty"
# Build the embeddable library only (no macOS app). See macos/AGENTS.md.
zig build -Demit-macos-app=false
# Ghostty emits the C headers + static lib under zig-out/. Locate and stage them.
mkdir -p ../ghostty-artifacts
cp -R zig-out/include ../ghostty-artifacts/
cp -R zig-out/lib ../ghostty-artifacts/
echo "libghostty artifacts staged in vendor/ghostty-artifacts/"
```
Run: `chmod +x scripts/build-libghostty.sh && ./scripts/build-libghostty.sh`
Expected: `vendor/ghostty-artifacts/include/ghostty.h` and a `libghostty` static library exist. If `zig build` complains about the Zig version, install the exact version named in `vendor/ghostty/.zigversion` (via `brew install zig@<v>` or the `zvm`/`zigup` tool) and re-run.

- [ ] **Step 4: Commit the vendored submodule + build script**

```bash
git add .gitmodules vendor/ghostty .gitignore scripts/build-libghostty.sh docs/TOOLING.md
git commit -m "chore: vendor ghostty submodule and libghostty build script"
```

## Task 2: Scaffold the Flight Deck app (empty window)

**Files:**
- Create: `project.yml`, `Sources/FlightDeck/FlightDeckApp.swift`, `Sources/FlightDeck/RootWindow.swift`, `Sources/FlightDeck/FlightDeck.entitlements`, `scripts/build.sh`

- [ ] **Step 1: Write the XcodeGen project spec**

Create `project.yml`:
```yaml
name: FlightDeck
options:
  bundleIdPrefix: dev.flightdeck
  deploymentTarget:
    macOS: "14.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "14.0"
targets:
  FlightDeck:
    type: application
    platform: macOS
    sources:
      - Sources/FlightDeck
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Sources/FlightDeck/FlightDeck.entitlements
        INFOPLIST_KEY_NSHumanReadableCopyright: ""
        INFOPLIST_KEY_CFBundleDisplayName: Flight Deck
        GENERATE_INFOPLIST_FILE: "YES"
```

- [ ] **Step 2: Minimal entitlements**

Create `Sources/FlightDeck/FlightDeck.entitlements` by copying `vendor/ghostty/macos/GhosttyDebug.entitlements` verbatim (a terminal needs the same JIT/inherit/network-client entitlements Ghostty uses in debug):
```bash
cp vendor/ghostty/macos/GhosttyDebug.entitlements Sources/FlightDeck/FlightDeck.entitlements
```

- [ ] **Step 3: Empty SwiftUI app**

Create `Sources/FlightDeck/FlightDeckApp.swift`:
```swift
import SwiftUI

@main
struct FlightDeckApp: App {
    var body: some Scene {
        RootWindow()
    }
}
```
Create `Sources/FlightDeck/RootWindow.swift`:
```swift
import SwiftUI

struct RootWindow: Scene {
    var body: some Scene {
        WindowGroup {
            Text("Flight Deck")
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
```

- [ ] **Step 4: Build script + generate project**

Create `scripts/build.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f vendor/ghostty-artifacts/include/ghostty.h ] || ./scripts/build-libghostty.sh
xcodegen generate
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -configuration Debug \
  -derivedDataPath DerivedData build
echo "Built: DerivedData/Build/Products/Debug/FlightDeck.app"
```
Run: `chmod +x scripts/build.sh && ./scripts/build.sh`
Expected: `DerivedData/Build/Products/Debug/FlightDeck.app` exists and builds with no errors.

- [ ] **Step 5: Launch smoke (manual) + commit**

Run: `open DerivedData/Build/Products/Debug/FlightDeck.app`
Expected: a window titled "Flight Deck" appears showing the placeholder text. Close it.
```bash
git add project.yml Sources/FlightDeck scripts/build.sh
git commit -m "feat: scaffold Flight Deck macOS app with an empty window"
```

## Task 3: Link libghostty and the reused Ghostty Swift module (compiles)

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add the reused Ghostty sources + libghostty link to the target**

Edit `project.yml` — under `targets.FlightDeck`, extend `sources` and add the library link + header search path. Add the Ghostty module and its Helpers by reference (not copy):
```yaml
    sources:
      - Sources/FlightDeck
      - path: vendor/ghostty/macos/Sources/Ghostty
      - path: vendor/ghostty/macos/Sources/Helpers
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: Sources/FlightDeck/FlightDeck.entitlements
        GENERATE_INFOPLIST_FILE: "YES"
        INFOPLIST_KEY_CFBundleDisplayName: Flight Deck
        SWIFT_OBJC_BRIDGING_HEADER: Sources/FlightDeck/BridgingHeader.h
        HEADER_SEARCH_PATHS: $(SRCROOT)/vendor/ghostty-artifacts/include
        LIBRARY_SEARCH_PATHS: $(SRCROOT)/vendor/ghostty-artifacts/lib
        OTHER_LDFLAGS: -lghostty
```

- [ ] **Step 2: Bridging header to expose the C API**

Create `Sources/FlightDeck/BridgingHeader.h`:
```c
#import "ghostty.h"
```

- [ ] **Step 3: Generate + build; resolve the exact reused-file set by following errors**

Run: `./scripts/build.sh`
Expected on first attempt: compile errors naming missing symbols/types from `Helpers/` or other Ghostty support files (the module was written for Ghostty's full target). For each "cannot find X in scope" error, locate X under `vendor/ghostty/macos/Sources/` and add its enclosing folder/file to `project.yml` `sources`. Repeat until it compiles. Do **not** modify any vendored file; only add source references. If a file pulls in app-only concerns (menus, settings windows) that don't compile standalone, prefer adding only the specific support file it needs rather than the whole `App/` or `Features/` tree.
Expected end state: `./scripts/build.sh` succeeds with the Ghostty module + libghostty linked.

- [ ] **Step 4: Commit**

```bash
git add project.yml Sources/FlightDeck/BridgingHeader.h
git commit -m "feat: link libghostty and vendor the reused Ghostty Swift module"
```

## Task 4: Render a live terminal surface running a shell

**Files:**
- Create: `Sources/FlightDeck/TerminalContainer.swift`
- Modify: `Sources/FlightDeck/RootWindow.swift`

- [ ] **Step 1: Read the reused API to find the real entry points**

Read these vendored files and note the exact initializer/config API (do not guess names):
- `vendor/ghostty/macos/Sources/Ghostty/GhosttyPackage.swift` — how the global Ghostty app-state (libghostty init) is created.
- `vendor/ghostty/macos/Sources/Ghostty/Ghostty.Surface.swift` and `vendor/ghostty/macos/Sources/Ghostty/Surface View/` — the SwiftUI `SurfaceView`/`SurfaceWrapper` type, its initializer, and how Ghostty's own app instantiates it (cross-reference `vendor/ghostty/macos/Sources/App` and `Features`).
- `vendor/ghostty/macos/Sources/Ghostty/Ghostty.Shell.swift` — how the surface is pointed at a shell command / working directory.

Write the discovered type names and initializer signatures into this task as a comment block before implementing (so the next step uses real API, not invented API).

- [ ] **Step 2: TerminalContainer hosting the reused SurfaceView**

Create `Sources/FlightDeck/TerminalContainer.swift`. Using the *real* types found in Step 1, instantiate the Ghostty app-state once and embed a `SurfaceView` bound to it, launching the resolved shell (from `ShellResolver`, Task 5) in the repo's working directory. Structure (fill the Ghostty types from Step 1):
```swift
import SwiftUI
// import the Ghostty module types as discovered in Step 1

struct TerminalContainer: View {
    // Hold the Ghostty app-state object created via GhosttyPackage's real initializer.
    // Hold surface configuration pointing at ShellResolver.resolve() as the command
    // and the given workingDirectory.
    let workingDirectory: String

    var body: some View {
        // Return the reused Ghostty SurfaceView/SurfaceWrapper, configured as above.
        // (Exact type + initializer come from Step 1's discovery.)
        Text("REPLACE with reused Ghostty SurfaceView")
    }
}
```

- [ ] **Step 3: Show the terminal in the window**

Edit `Sources/FlightDeck/RootWindow.swift` to render the terminal at the user's home directory:
```swift
import SwiftUI

struct RootWindow: Scene {
    var body: some Scene {
        WindowGroup {
            TerminalContainer(workingDirectory: NSHomeDirectory())
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
```

- [ ] **Step 4: Build, launch, verify a real terminal**

Run: `./scripts/build.sh && open DerivedData/Build/Products/Debug/FlightDeck.app`
Manual verification checklist (all must pass):
- A terminal renders in the window with a shell prompt.
- Typing `echo flight-deck-ok` and pressing Return prints `flight-deck-ok`.
- `pwd` prints the home directory.
- Resizing the window reflows the terminal.
If the surface is blank, revisit Step 1 (likely the app-state/surface was not retained or the Metal layer not attached) — compare against how `vendor/ghostty/macos/Sources/App` retains and presents the surface.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/TerminalContainer.swift Sources/FlightDeck/RootWindow.swift
git commit -m "feat: render a reused-Ghostty terminal surface running a shell"
```

## Task 5: Shell resolution (a real unit, TDD)

**Files:**
- Create: `Sources/FlightDeck/ShellResolver.swift`, `Tests/FlightDeckTests/ShellResolverTests.swift`
- Modify: `project.yml` (add a unit-test target)

- [ ] **Step 1: Add a unit test target to project.yml**

Under `targets:` add:
```yaml
  FlightDeckTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/FlightDeckTests]
    dependencies:
      - target: FlightDeck
    settings:
      base: { GENERATE_INFOPLIST_FILE: "YES" }
```

- [ ] **Step 2: Write the failing test**

Create `Tests/FlightDeckTests/ShellResolverTests.swift`:
```swift
import XCTest
@testable import FlightDeck

final class ShellResolverTests: XCTestCase {
    func testUsesShellEnvWhenSet() {
        let shell = ShellResolver.resolve(environment: ["SHELL": "/bin/fish"])
        XCTAssertEqual(shell, "/bin/fish")
    }
    func testFallsBackToZshWhenUnset() {
        let shell = ShellResolver.resolve(environment: [:])
        XCTAssertEqual(shell, "/bin/zsh")
    }
    func testFallsBackToZshWhenEmpty() {
        let shell = ShellResolver.resolve(environment: ["SHELL": ""])
        XCTAssertEqual(shell, "/bin/zsh")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodegen generate && xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' test -only-testing:FlightDeckTests`
Expected: FAIL — `ShellResolver` not found.

- [ ] **Step 4: Implement ShellResolver**

Create `Sources/FlightDeck/ShellResolver.swift`:
```swift
import Foundation

enum ShellResolver {
    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let shell = environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' test -only-testing:FlightDeckTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Wire ShellResolver into TerminalContainer**

In `TerminalContainer.swift` (Task 4 Step 2), use `ShellResolver.resolve()` as the command launched by the surface. Rebuild and re-run the Task 4 Step 4 manual checklist to confirm no regression.

- [ ] **Step 7: Commit**

```bash
git add project.yml Sources/FlightDeck/ShellResolver.swift Tests/FlightDeckTests/ShellResolverTests.swift
git commit -m "feat: resolve the launch shell from SHELL with a zsh fallback (TDD)"
```

## Task 6: Launch smoke test (automated) + finish

**Files:**
- Create: `UITests/FlightDeckUITests/TerminalSmokeTests.swift`, `scripts/smoke.sh`
- Modify: `project.yml` (add a UI-test target)

- [ ] **Step 1: Add a UI test target to project.yml**

Under `targets:` add:
```yaml
  FlightDeckUITests:
    type: bundle.ui-testing
    platform: macOS
    sources: [UITests/FlightDeckUITests]
    dependencies:
      - target: FlightDeck
    settings:
      base: { GENERATE_INFOPLIST_FILE: "YES" }
```

- [ ] **Step 2: Write the smoke test**

Create `UITests/FlightDeckUITests/TerminalSmokeTests.swift`:
```swift
import XCTest

final class TerminalSmokeTests: XCTestCase {
    func testAppLaunchesAndShowsTerminalSurface() {
        let app = XCUIApplication()
        app.launch()
        // The app window must exist and contain a rendered content view.
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        // The window must be non-empty (the terminal surface occupies it).
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, 100)
    }
}
```
(Assertion is deliberately coarse — a rendered Metal terminal surface is not introspectable by accessibility by default. If Task 4's surface exposes an accessibility identifier, tighten this to assert that element; otherwise the launch-without-crash + window-present check is the smoke signal.)

- [ ] **Step 3: Smoke script**

Create `scripts/smoke.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
xcodegen generate
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck -destination 'platform=macOS' \
  test -only-testing:FlightDeckUITests
echo "SMOKE PASS"
```
Run: `chmod +x scripts/smoke.sh && ./scripts/smoke.sh`
Expected: ends with `SMOKE PASS`.

- [ ] **Step 4: Final commit**

```bash
git add project.yml UITests scripts/smoke.sh
git commit -m "test: add launch smoke test for the terminal surface"
```

---

## Self-Review

**Spec coverage (this plan's scope):** Implements spec §3 **Terminal Core** (reuse Ghostty's macOS surface as a thin delta) and the first task of spec §9 **phase 1** ("get a reused-Ghostty terminal rendering in our shell"). Explicitly out of scope here and deferred to their own plans: Claude Code adapter + injection, minimal index, Session/Project Store, sidebar (rest of phase 1); Index Service, Memory, opencode adapter, worktrees, compaction UI (phases 2–5). This is a deliberate decomposition, not a gap.

**Placeholder scan:** The only intentionally-deferred code is Task 4 Step 2's `SurfaceView` instantiation, which is gated on Task 4 Step 1 reading the *real* vendored API — this is correct-by-construction (do not invent Ghostty's API; discover it), not a hand-wave. Every other step has exact commands, file contents, and expected output.

**Type consistency:** `ShellResolver.resolve(environment:)` is defined in Task 5 and consumed in Task 4 Step 6 / Task 5 Step 6 with the same signature. `scripts/build.sh` / `build-libghostty.sh` / `smoke.sh` are referenced consistently. `project.yml` target names (`FlightDeck`, `FlightDeckTests`, `FlightDeckUITests`) are consistent across tasks.

**Risk callouts realized in the plan:** libghostty API churn → pin a SHA (Task 1) and reuse vendored files unmodified (Task 3). Non-standard Xcode-from-CLI → XcodeGen text spec. Metal surface not accessibility-introspectable → coarse smoke assertion (Task 6 Step 2) with a manual checklist as the real render gate (Task 4 Step 4).

## Definition of Done

- `./scripts/build.sh` builds `FlightDeck.app` with the reused Ghostty module + libghostty linked.
- Launching the app shows a working terminal surface running the user's shell (Task 4 manual checklist passes).
- `xcodebuild ... test -only-testing:FlightDeckTests` passes (ShellResolver).
- `./scripts/smoke.sh` prints `SMOKE PASS`.
- Zero modifications to any file under `vendor/ghostty/` (reuse only).
