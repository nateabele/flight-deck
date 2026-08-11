# Flight Deck — Known Limitations & Follow-ups

Originally captured from the walking-skeleton whole-branch review (2026-07-10); kept current
as work lands. Last audited against the tree on **2026-08-11** (master, post session-name-sync
and menu-key-equivalent merges) — every entry below was re-checked against the code, not
carried forward on trust.

## Resolved (kept for the reasoning trail)

- **Teardown UAF hazard on window close — FIXED** in the multi-session foundation. The
  hazard was that `GhosttyApp.deinit` frees the libghostty app synchronously while
  `Ghostty.Surface.deinit` defers `ghostty_surface_free` to a later main-actor `Task`, so a
  per-view `GhosttyApp` could be freed before its surfaces. `GhosttyApp` is now a
  process-wide singleton owned by `AppDelegate` (`Sources/FlightDeck/AppDelegate.swift`) and
  is not constructed per view, so it outlives every surface free. Guarded by
  `Tests/FlightDeckTests/SurfaceLifecycleTests.swift`.
- **XCUITest saw no window — FIXED.** The initial `WindowGroup` window was gated behind the
  macOS window-restoration handshake, which only a LaunchServices launch completes; XCUITest
  raw-execs the binary. All UITests now pass `-ApplePersistenceIgnoreState YES`. Full
  postmortem: [done/HANDOFF-smoke-gate.md](done/HANDOFF-smoke-gate.md).
- **⌘Q (and any menu shortcut) swallowed by the terminal — FIXED.** AppKit runs a view's
  `performKeyEquivalent` ahead of the main menu, and the vendored Ghostty surface claimed
  every libghostty binding. `Sources/FlightDeck/MenuKeyEquivalents.swift` now offers consumed
  bindings to `NSApp.mainMenu` first; it is keyed to no specific shortcut, so menu items
  added later are covered automatically.

## Deferred to the harness-adapter / block-model phase

- **`close_surface_cb` is still a no-op, and `action_cb` handles only `quit`.** A shell `exit`
  leaves a dead surface on screen; title/notification/clipboard/OSC actions are still dropped.
  Wire the rest when building the block model and the harness adapters (they are the surface's
  event surface). `action_cb` gained a `quit` case with the menu-key-equivalent fix — see
  `MenuKeyEquivalents` — because a Ghostty keybind can resolve to `quit` with no menu item
  involved.

## Build reproducibility (known limitation)

- **CI / arbitrary clean host is blocked on upstream Zig #31658.** Ghostty pins Zig 0.15.2,
  whose Mach-O linker mis-parses the macOS 26.4+ SDK `libSystem.tbd`; the fix is only in Zig
  0.16.0, which Ghostty rejects. Our build works because it shims Zig at a locally-present
  `MacOSX15.4.sdk` (see `scripts/build-libghostty.sh`, which fails fast with a clear error if
  that SDK is absent). Unblocks when Zig ships a 0.15.x backport or Ghostty accepts 0.16.

## Deliberate choices worth remembering (not defects)

- **`SWIFT_VERSION: "5.0"`** in `project.yml` (Swift 5 language mode under the Swift 6.3
  compiler) — chosen to compile the vendored Ghostty code without Swift-6 strict-concurrency
  breakage. Diverges from the plan's `6.0`/spec's "Swift 6"; revisit only if Flight Deck's own
  code is later isolated into a Swift-6 module separate from the adapted Ghostty sources.
- **Non-sandboxed entitlements** (no `app-sandbox`, `disable-library-validation` on) — required
  for a terminal linking a non-notarized static `libghostty`.

## Minor cleanups (safe to defer; optional wrap-up commit)

- `scripts/build-libghostty.sh`: add `-f`/`-fS` to the `curl` download (bad HTTP responses are
  already caught by the subsequent `shasum -c`, just less directly).

## Deferred from session name sync (2026-08-11)

Reviewed, real, and deliberately not fixed on that branch. Rulings recorded so the next
reader doesn't re-derive them.

- **`TranscriptWatcher` polls at 2 Hz forever when `claude` never runs**, with no backoff or
  cap. Negligible today — it is a `stat` of a nonexistent path — but worth a cap if session
  counts grow.
- **Actor-isolation inconsistency across the seams.** `TextInjecting` and `SessionPersisting`
  are `@MainActor`; `SurfaceProvider` is not. `TranscriptWatcher` also calls `@MainActor
  drain()` synchronously from a non-isolated `@Sendable` timer handler — dynamically correct
  (the queue *is* `.main`) but it only compiles because of `SWIFT_VERSION: "5.0"` above. This
  is Swift-6-migration work, not a defect in the feature.
- **`testRestoreSelectsFirstSurvivingSessionWhenSelectionIsDropped` is a weak regression
  guard.** It pins that restore's selection fallback uses an ordered collection rather than a
  `Set`, but with two survivors a regression to `Set` would still pass roughly half the time
  (Swift's hash seed is per-process). Adding survivors only moves the odds; if it is ever
  revisited, assert the full restored ordering instead.
- **`SessionStore.selectSession(_:)` has no production caller.** The sidebar's
  `List(selection:)` binds `selectedSessionID` directly, and persistence now hangs off that
  property's `didSet`. The method is still exercised by `SessionStoreTests`; left in place
  rather than deleted, but it is dead weight if nothing adopts it.
- **If a sidebar rename ever intermittently fails to submit, add a small delay before the
  Return.** `SessionStore.rename` sends the command text (a paste, via `sendText`) and then
  Return (a key event, via `sendReturn`) back to back. Ordering is preserved through
  libghostty's IO queue, so no delay is needed today and none is shipped — but the two travel
  different paths, and a program that debounces paste input could in principle still be
  assembling the paste when the keypress lands. A ~50 ms gap before `sendReturn()` is the
  first thing to try; do **not** "fix" it by putting the terminator back inside the text,
  which is the bug that `TextInjecting.sendReturn()` exists to avoid.
- **`CLAUDE_CODE_CHILD_SESSION` in the inherited environment turns transcript saving off**,
  which silently kills inbound rename sync — the watcher tails a file that is never written.
  Claude Code sets this marker for nested sessions; a `claude` inheriting it prints
  *"Transcript saving is off — inherited CLAUDE_CODE_CHILD_SESSION marker"* in its status
  line. Launching Flight Deck from Finder / `/Applications` gives a clean LaunchServices
  environment, so this does not bite in normal use — but launching it from a terminal that
  is itself inside a Claude Code session does. If inbound sync ever looks dead, check that
  status line first. `Ghostty.SurfaceConfiguration` exposes `environmentVariables`, so the
  defensive fix (clear the marker for spawned sessions) is available if this proves to be
  more than a development-time footgun.

## From session creation UX (2026-08-11)

- **A single click on a sidebar row's title text did not select the row — FIXED.** The
  `Text` in `SessionRow` carried `.onTapGesture(count: 2)` for inline rename, and that
  recognizer swallowed the single click before the enclosing `List(selection:)` saw it, so
  the one part of the row users aim at was the one part that did not work.

  Two plausible-looking fixes are **not** fixes, both confirmed by test rather than
  argument: `simultaneousGesture(TapGesture(count: 2))` still does not let the click reach
  the List, and pairing a count-2 with a count-1 recognizer leaves the count-1 handler never
  firing at all — an explicit handler assigning `selectedSessionID` did not run. Don't
  re-attempt either.

  `SessionRow.handleTitleTap()` now uses a single tap recognizer and detects the second
  click itself against `NSEvent.doubleClickInterval`, which takes SwiftUI's gesture
  arbitration out of the problem entirely. Guarded by an assertion in
  `testCommandNAddsASessionBelowTheActiveOne` that clicks the title and requires the row to
  become selected, plus `testDoubleClickRenamesSession` for the rename path.
