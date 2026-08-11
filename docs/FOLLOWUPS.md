# Flight Deck — Known Limitations & Follow-ups

Captured from the walking-skeleton whole-branch review (2026-07-10). None block the
walking skeleton (a from-scratch macOS app rendering a reused-Ghostty terminal running
a shell), which is complete and verified. These are for the phases that follow.

## Deferred to the multi-session / window-lifecycle phase (spec §9 phase 1 cont.)

- **Teardown UAF hazard once window-close is exercised.** `GhosttyApp.deinit` frees the
  libghostty app *synchronously*, but `Ghostty.Surface.deinit` defers `ghostty_surface_free`
  to a later main-actor `Task`. Today `TerminalContainer.Coordinator` owns a `GhosttyApp`
  **per view**; closing a `WindowGroup` window (which does not quit the app) would release
  the Coordinator → free the app → then the deferred surface-free runs against an already-freed
  app. The skeleton never closes a window before process quit, so it does not bite now.
  **Fix when adding multi-session/multi-window:** make `GhosttyApp` an app-level singleton
  (mirroring Ghostty's own `AppDelegate` ownership) so it outlives all surfaces, or order the
  app free on a main-actor task after all surface frees.

## Deferred to the harness-adapter / block-model phase

- **`close_surface_cb` and `action_cb` in `GhosttyApp` are no-ops.** A shell `exit` leaves a
  dead surface on screen; title/notification/clipboard/OSC actions are dropped. Wire these when
  building the block model and the harness adapters (they are the surface's event surface).

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
