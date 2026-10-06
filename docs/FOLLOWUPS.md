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

- **`action_cb` is partial by design, not by omission.** Wired: `quit`, the clipboard callbacks
  (`read`/`write`/`confirm_read` — libghostty does no pasteboard I/O itself, so these are what
  make ⌘C/⌘V work at all), `close_surface_cb`, `open_url`, `mouse_over_link`, `mouse_shape`,
  `mouse_visibility`, `pwd`, and the four search actions.

  Everything else libghostty can emit is deliberately unhandled and is **not** a TODO. Flight
  Deck is a session manager with one surface per session, so Ghostty's own tab/split/window
  actions (`new_tab`, `new_split`, `goto_tab`, `goto_split`, `toggle_fullscreen`, …) would
  duplicate or fight the sidebar, and title/notification actions are already served by
  `TranscriptWatcher` and `SessionNotifier`. Returning `false` is the honest answer for those.
  Add one only when a concrete need appears — not to fill in the table.

## Build reproducibility (known limitation)

- **CI / arbitrary clean host is blocked on upstream Zig #31658.** Ghostty pins Zig 0.15.2,
  whose Mach-O linker mis-parses the macOS 26.4+ SDK `libSystem.tbd`; the fix is only in Zig
  0.16.0, which Ghostty rejects. Our build works because it shims Zig at a locally-present
  `MacOSX15.4.sdk` (see `scripts/build-libghostty.sh`, which fails fast with a clear error if
  that SDK is absent). Unblocks when Zig ships a 0.15.x backport or Ghostty accepts 0.16.

## Deliberate choices worth remembering (not defects)

- **Paired-device secrets (`Preferences.pairedDevices`) live in `UserDefaults`, not the
  Keychain.** That is a plist in the user's home directory, readable by anything running as
  them — the same exposure `sessions.json` and the agents' own credentials already have, and
  it is consistent with the mobile companion spec §3's trust model ("a QR on an unlocked Mac
  is seen only by someone who could already use the Mac"), not an oversight. What it does and
  does not expose: reading the plist gets you every paired device's 32-byte PSK, which is
  enough to connect to this Mac's fleet listener as that device until it is revoked; it does
  not get you anything already on disk elsewhere (session content, agent credentials) that a
  local attacker with plist-reading access could not already reach some other way. The
  phone's own copy is Keychain-backed (`KeychainPairedMacStore`) precisely because the phone
  is the side that leaves the building. It is not Keychain-grade on the Mac side, and someone
  will eventually ask why. Revisit if paired devices ever need to survive a `defaults delete`,
  or if the trust model changes to assume a less-trusted local user.
- **`SWIFT_VERSION: "5.0"`** in `project.yml` (Swift 5 language mode under the Swift 6.3
  compiler) — chosen to compile the vendored Ghostty code without Swift-6 strict-concurrency
  breakage. Diverges from the plan's `6.0`/spec's "Swift 6"; revisit only if Flight Deck's own
  code is later isolated into a Swift-6 module separate from the adapted Ghostty sources.
- **Non-sandboxed entitlements** (no `app-sandbox`, `disable-library-validation` on) — required
  for a terminal linking a non-notarized static `libghostty`.
- **The packed QR keeps the Mac's display name and Bonjour service name, where the
  short-pairing-code spec's §8 said it could drop both.** §8's reasoning does not hold against
  the shipped code: `FleetSnapshot` (`Sources/FleetKit/Wire.swift`) carries no Mac identity at
  all, so the display name does *not* "arrive with the first snapshot"; and
  `FleetService.serviceName` is `<sanitised host>-<install suffix>`, stable per Mac and not
  derivable from a slot — `FleetConnector.startBrowsing` matches Bonjour results against
  exactly that string, so a phone without it cannot rediscover its Mac after either moved.
  Carrying both, length-prefixed, costs 43 bytes of a 98-byte payload. The measured QR
  improvement is in `PairingCodeImageTests.testThePackedPayloadProducesAMateriallySmallerQR`;
  read the numbers in its failure message rather than trusting §8's predicted QR version,
  which assumed a ~55-byte payload. **The cheaper route, if the density ever matters more:**
  add `macName` and `serviceName` to `FleetSnapshot` (decoded with `decodeIfPresent`, so
  already-paired phones are unaffected), then drop both from the payload and make §8's claim
  true. That is a wire change and wants its own slice.
- **A typed pairing stores no remembered endpoints.**
  `FleetModel.adopt(key:serviceName:macName:)` writes `PairedMac(endpoints: [])` on purpose: the
  seal carries the key and the Mac's name and nothing else, and off-LAN typed pairing is
  explicitly out of scope (spec §11). The phone finds its Mac by browsing `_flightdeck._tcp` for
  the service name it paired under, which is what `FleetConnector` does anyway. A phone paired
  by *QR* still gets one endpoint, from the code. If typed pairing ever needs to survive leaving
  the LAN, the fix is the phone recording the address it actually connected on — not widening
  the seal.
- **Flight Control Observe polls on `WatchClock`-registered, mtime-gated `stat`s, not FSEvents,**
  though the design spec called for FSEvents. `FlywheelWatcher`
  (`Sources/FlightDeck/Flywheel/Observe/FlywheelWatcher.swift`) mirrors
  `SessionStatusWatcher`'s own documented stance against vnode/FSEvents watches
  (`SessionStatusWatcher.swift:13-16`): both `.beads/beads.db` (SQLite-WAL) and git's own
  write pattern touch a file through create-temp-then-rename or multi-file-then-fsync
  sequences that vnode watches observe unreliably. A `stat` per watched path every
  `WatchClock` beat is orders of magnitude cheaper than a subprocess spawn, so `drain()` pays
  that cost every tick and only shells out to `am`/`br` (`repollNow()`) once a watched path's
  mtime has actually moved — the spec's real intent ("don't poll `am`/`br` on a dumb timer")
  is preserved, just on a cheaper, already-established, already-tested watcher shape instead
  of FSEvents.
- **`FlywheelNotifier.blockThreshold` (default 120s) and `FlywheelObserveService.stallThreshold`
  (default 600s) are compile-time constants, not user preferences.** Both are constructor
  parameters with defaults (`FlywheelNotifier.swift:43`, `FlywheelObserveService.swift:25`),
  and the real app wiring (`FlightDeckApp.swift`, `SessionStore.swift`) uses those defaults
  with no override surface anywhere in `Preferences`. Nothing about the notifier/service
  design blocks surfacing either as a per-project or global preference later — there's just
  no UI for it yet.
- **A refreshed reservation lease is treated as stall continuity, not release+reacquire.**
  `FlywheelObserveService.enable`'s poll closure passes the previous projection into
  `FlywheelProjection.project(..., previous:)` on every poll, and the projection carries a
  held file's stall clock forward across a lease refresh rather than resetting it —
  deliberate, so an agent that keeps renewing a lease on a file it's silently stuck on still
  reads as stalled after the renewal, instead of the renewal resetting the "how long has this
  really been held" clock to zero. `FlywheelNotifier` tracks its own separate `firstSeen`
  clock per cause key on top of that (see its doc comment) — the two clocks answer different
  questions ("has this condition been continuously true" vs. "when did we first see it") and
  must not be conflated.

## Minor cleanups (safe to defer; optional wrap-up commit)

- `scripts/build-libghostty.sh`: add `-f`/`-fS` to the `curl` download (bad HTTP responses are
  already caught by the subsequent `shasum -c`, just less directly).
- **The flag catalog is a snapshot of `claude --help` at 2026-08-11.** New `claude` releases
  add options that will fall through to passthrough with a warning until the catalog is
  updated. That degradation is by design, but the catalog is worth re-auditing whenever
  Claude Code ships a notable release.

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
- **No automated test covers a background launch, which is where the input monitors broke.**
  `SidebarInputMonitor` and `ToolOverlayInputMonitor` used to latch
  `NSApp.keyWindow ?? NSApp.mainWindow` at startup; both are nil for as long as the app is
  inactive, so an app relaunched behind a terminal — every `scripts/swap-release.sh` release —
  ran with double-click-to-rename, Return-to-rename and the tool-cluster fade-in dead, while
  context-menu rename kept working and hid it. Fixed by asking `SessionWindow` per event, and
  `SessionWindowTests` measures the nil-while-inactive fact that caused it. What is *not*
  covered is the end-to-end path: `XCUIApplication.launch()` always activates the app, so the
  smoke suite cannot enter the broken state and never could have caught this. Any future
  monitor that captures a window at startup will reintroduce it silently — verify such changes
  by relaunching the real app in the background, not by a green suite.
- **A small delay before Return, if typing ever fails to submit — RESOLVED for codex, and
  it was real, not merely hypothetical.** This entry originally flagged the risk for claude's
  `SessionStore.rename`, which sends the command text (a paste, via `sendText`) then Return (a
  key event, via `sendReturn`) back to back, and speculated that "a program that debounces
  paste input could in principle still be assembling the paste when the keypress lands."
  claude has never shown that failure and still calls `settle` once. codex does show it:
  live-isolated against codex-cli 0.153.4 (`scripts/adapterprobe/ptyscreen.py`'s `submit()`),
  a Return arriving in the same burst as the text before it is folded into that paste and
  inserted as a literal newline instead of submitting — reported by a user as "it types the
  text, but instead of submitting... it just inserts a newline." Fixed in `CodexTextChannel
  .submit`/`.submitRename` by giving `sendReturn()` its own `settle` hop, separate from the
  text's — see that file's doc comments. `AgentTextChannel.submit`'s protocol contract changed
  to allow `settle` more than once as part of the fix, with `onFinished` (not settle) now
  carrying the one-shot completion guarantee `SessionStore.inject` depends on — the same
  `onFinished(Bool)` shape `AgentRenameTyping` uses, and for the same reason. Do **not** "fix"
  a future case like this by putting the terminator back inside the text, which is the bug
  that `TextInjecting.sendReturn()` exists to avoid.
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

  **Update (preferences, 2026-08-11):** now fixed behind a preference. `ShellSettingsTab`
  exposes *Clear `CLAUDE_CODE_CHILD_SESSION` in new sessions*, defaulted **on**, which blanks
  an inherited marker via `Ghostty.SurfaceConfiguration.environmentVariables`. The marker is
  blanked rather than unset because the surface config can only set variables; `claude`
  treats an empty value as absent.

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

  **Superseded twice since.** `SessionRow.handleTitleTap()` — a single tap recognizer that
  detected the second click itself — was removed in `b18b86a` because ANY tap recognizer on
  the row blocks drag-to-reorder, and `testDoubleClickRenamesSession` went with it. The
  AppKit recognizer that briefly replaced it was also removed, measured. Double-click is now
  detected entirely outside the row by `Sources/FlightDeck/SidebarInputMonitor.swift`; see the
  project-tabs section below for the four mechanisms tried and the three that failed. The
  title-click-selects-the-row assertion survives, inside the consolidated smoke test.

## Sidebar row hover no longer covers the full row width

`SessionRow` reveals its close button on hover. That hover is `.onHover` on the row's
HStack with **no** `.contentShape(Rectangle())`, so it follows the row's actual content:
the empty gap between the session title and the trailing status icon does not trigger it,
and sweeping the pointer across a row can flicker rather than hold.

The contentShape was removed deliberately (see `b5d4a07`). With it, the HStack became a
hit-test participant and competed with the title's `.onTapGesture` for click ownership,
intermittently swallowing the second click of a double click and breaking rename — 4
failures in 5 runs of `testDoubleClickRenamesSession`, against 9/9 before this branch met
master's hand-rolled double-click detection in `66cb7f2`.

Two fixes were measured and rejected, so don't re-try them blind:

- **`NSTrackingArea` via `NSViewRepresentable` in `.background()`** — worse. A real
  `NSView` takes over the row's hit-test geometry: 6 of 6 runs failed with
  `Not hittable: StaticText ... session-row-title`.
- **`.contentShape` + `.onHover` on a transparent SwiftUI layer behind the row** — fixes
  the click theft (6 of 6 rename runs passed) but breaks hover itself, because the content
  in front swallows the hover the layer needs to see. Both hover tests failed.

Restoring full-width hover needs a mechanism that does not join SwiftUI's hit-testing and
does not sit in front of or behind the row's content in a way that intercepts either
clicks or hover. Worth revisiting if the flicker proves annoying in practice.

Related, still open: `.onHover` does not fire while a trackpad scroll is in flight, so a
row can hold a stale hover state after scrolling.

## From project tabs (2026-08-14) — RESOLVED 2026-08-15, kept for the finding

The two `.onMove` questions below are now answered, and the third turned out to be a real bug
that shipped. Both are covered by UI tests in `TerminalSmokeTests`.

1. `.onMove` **does** give drag-to-reorder on a macOS `List` with no edit mode. Verified.
2. It **does** coexist with the existing `.dropDestination(for: URL.self)` folder drop on the
   same `List`. Verified. The `.draggable`/`.dropDestination` fallback recorded in
   `docs/superpowers/specs/2026-08-14-project-tabs-design.md` was not needed.

**The finding worth keeping: any tap recognizer on a row blocks that row's list drag.**

Two bugs shipped from this, both reported by the maintainer against the merged build:

- Project headings could not be dragged **at all**, because `ProjectHeaderRow`'s `HStack`
  carried a row-wide `.onTapGesture { toggle() }` for collapse.
- Session rows could not be dragged **by their title text**, because that `Text` carried the
  hand-rolled double-click rename detector. The rest of the row dragged fine, which is exactly
  what made it look like a partial failure rather than one mechanism.

Measured, not inferred: with a recognizer present the drag assertion fails and the control
assertion (dragging blank row space) passes; with it removed both pass. `.onTapGesture` and
`.simultaneousGesture(TapGesture())` were both tried and both blocked the drag — simultaneity
does not help, because the list's reorder is AppKit-level rather than a SwiftUI gesture, so
there is nothing for SwiftUI to arbitrate against.

Fixes: the project toggle moved onto the chevron as a `Button`; session rename moved to the
row's context menu. `.contentShape(Rectangle())` was kept on the project header — it is what
makes hover cover the full row, and on its own it consumes nothing.

**Rule for anything added to a sidebar row: add nothing to the row.** No *SwiftUI* tap gestures
(they eat the mouse-down the drag needs) and **no `NSViewRepresentable` either** — measured on
this branch at 5 of 5 smoke failures with `Not hittable: StaticText … session-row-title`, even
with `hitTest(_:)` returning nil. `hitTest` keeps a view out of AppKit's hit-test path but not
out of the accessibility geometry XCUITest measures, which is the same cause as the older
tracking-area finding. Safe: a `Button` on a small control, a context menu, or an out-of-band
event monitor (`Sources/FlightDeck/SidebarInputMonitor.swift`).

Two further mechanisms were tried on this branch and also failed, both worth not repeating:
an `NSClickGestureRecognizer` on the table view attaches correctly but never recognizes,
because XCUITest's synthetic double-click emits two mouse-*downs* (the second already carrying
`clickCount == 2`) and **no ups at all**; and `.onKeyPress(.return)` on the `List` never fires,
because the terminal `SurfaceView` holds first responder and neither a click nor Tab moves it —
a `@FocusState` on the `List` never reported true.

Closed: **double-click renames a session again**, and **Return-to-rename is implemented.** Both
live in `SidebarInputMonitor`: a passive `.leftMouseDown` monitor renames on `clickCount == 2`,
and Return renames the selected row when the sidebar's table is first responder. The sidebar
takes first responder when you click the row you are *already* on — not on every click, because
switching session re-parents the terminal surface and `TerminalPane` asynchronously calls
`Ghostty.moveFocus(to:)`, which would take focus straight back. Rename is reachable three ways:
double-click, Return, and the row's context menu.

Four more from the whole-branch review of this same commit, none exercised in a running app:

1. **`NSAlert` Escape key on the close-project confirmation.** In
   `Sources/FlightDeck/ProjectCloseConfirmer.swift`, `addButton(withTitle: "Cancel")` gets
   Escape as its key equivalent automatically — but the very next line,
   `cancel.keyEquivalent = "\r"`, overwrites it, and an `NSButton` has exactly one key
   equivalent. Return correctly takes the safe (Cancel) path, but Escape most likely no
   longer dismisses the alert at all, which is a HIG regression on the one alert the spec
   singles out for HIG treatment. Watch for: pressing Escape on the close-project alert does
   nothing.
2. **Accessibility on `ProjectHeaderRow` — now partly MEASURED, and worse than assumed.**
   `.accessibilityElement(children: .combine)` merges every descendant into one element, so the
   close button's own `accessibilityIdentifier("close-project")` is not queryable at runtime
   and its `accessibilityLabel("Close Project")` is superseded by the row's combined label.
   New evidence (2026-08-15): a UI test querying the header by identifier reads its `label` as
   the **empty string**, so the carefully composed
   `"flight-deck, 3 sessions, collapsed, waiting for you"` label is not reaching the
   accessibility client at all — the `testProjectHeadingsReorderByDragging` test had to assert
   on session-row order instead, because comparing header labels compared `""` to `""` and
   passed vacuously. If XCUITest cannot see it, VoiceOver most likely cannot either, which
   would make the whole collapsed-summary label dead weight. Worth checking with VoiceOver
   directly before redesigning. The collapse toggle is now a `Button` on the chevron, which
   VoiceOver can reach; the close button is still inside the combined element. Candidate
   remedy: drop `children: .combine` in favour of an explicit label on the row plus
   `.accessibilityHidden(true)` on the decorative parts, so the real controls stay reachable.
3. **`ProjectsSettingsTab` nests a `NavigationSplitView` inside a `VStack`.** Legal SwiftUI, and
   the split view's own body is unchanged by this branch, but a `NavigationSplitView` expects
   to own its container's sizing, and that can misbehave when it is not the top-level view.
   Nobody has opened Preferences → Projects since this change landed. Watch for: the project
   list/detail split rendering at the wrong size, or the bottom "Confirm before closing…" row
   squeezing or overlapping the split view.
4. **`closeProject` writes the snapshot N+1 times.** It routes through `closeSession` once per
   child (deliberately — see that method's doc comment — to avoid a second copy of the
   teardown list), and `closeSession`'s `selectedSessionID` `didSet` persists on every call, plus
   `closeProject` persists once more itself. Closing a ten-session project is eleven
   synchronous main-thread atomic file writes for one user gesture. Correct but wasteful, and
   it lands right after `perf: cut main-thread file work and idle timer wakeups`, which was
   trying to reduce exactly this. Candidate remedy: a private
   `closeSession(_:persisting:)` that the loop calls with `persisting: false`, or a
   suppression flag held for the duration of the loop.

**Stale confirmation alert on a double-clicked ✕.** `SessionSidebar.close(projectAt:)` spawns
a `Task` per call with no de-duplication, so double-clicking a project's close button starts
two `ProjectCloseCoordinator.requestClose` calls and can show two confirmation sheets for the
same project. Confirming the second one is a harmless no-op — `closeProject` re-resolves the
project by `Repo.ID` and does nothing if it is already gone — but the phantom second alert is
visible to the user. Candidate remedy: a `@State private var closing: Set<Repo.ID>` guard in
`SessionSidebar`, checked and inserted before starting the `Task` and removed when it
completes.

## From auto-resume & persisted unread (2026-08-15)

- **Status transitions want a state machine.** `applyRegistry` now computes each tick's
  edges once as `[StatusTransition]` and hands them to three consumers — `applyReadState`,
  `deliverNotifications`, and `cancelSupersededPrompts`. That is a seam, not a solution:
  each consumer still decides for itself what a given edge means, and the decisions are
  entangled (a `nil -> idle` edge is "launching" to the read policy and "ready" to the
  prompt queue). The motivating evidence is the bug fixed on that branch: `applyReadState`
  pruned marks with `unreadIdle.formIntersection(current.keys)`, which is correct for a
  session whose `claude` exited and wrong for one whose `claude` has not started yet — the
  two are indistinguishable in that formulation. A small explicit machine over
  `SessionActivity` (states, permitted edges, and what each edge means to each consumer)
  would make that class of bug unrepresentable. Not done on that branch because it touches
  every status consumer at once and the feature did not need it.

- **A prompt can be cancelled by a boot flicker.** `cancelSupersededPrompts` drops a queued
  "Keep going" the moment a session reports `busy` or `waiting`, so a resumed `claude` that
  passes briefly through `busy` while loading its transcript loses its prompt. Deliberately
  conservative: the failure is a silent no-op, where the alternative failure is typing into
  work the user is already doing. If it proves common in practice, the fix is to ignore
  transitions until the session has been seen `idle` at least once — not to remove the
  cancel.

- **Two ticks inside one settle window could double-inject — FIXED.** `inject` now marks a
  tab in-flight (a private `injecting: Set<UUID>`) the moment its `sendKillLine()` goes out
  and releases it unconditionally in `onFinished`, `submit`'s own one-shot completion signal —
  not tied to any single `settle` call, since a drive may now settle more than once (codex's
  Return needs a hop of its own; see `CodexTextChannel.submit`). The original writeup here
  reasoned about same-caller re-entry only — the registry tick's ~500ms poll against a 120ms
  settle — and judged it safe. That reasoning did not cover the other caller: `rename()` runs
  off a direct keystroke with no interval to race against, so a rename landing inside a queued
  prompt's settle window (or vice versa) could still send a second Ctrl+U into a viewport the
  first settle was mid-comparison against. The guard now lives inside `inject` itself, so it
  covers both callers instead of being restated in each.

- **`restore()` blanks the activity it just read.** The `persist()` at the end of `restore()`
  runs while `statuses` is still empty, so every entry's recorded `activity` is immediately
  rewritten to nil and only repopulates as each `claude` re-registers. Semantically
  defensible — activity means "right now" — but it means a second crash inside the boot
  window loses the auto-resume queue, and the on-disk record is blank for the seconds when
  it is most interesting. Preserving it needs the store to hold the loaded values until the
  first real tick; deferred as more machinery than the fix it buys, and the terminating
  guard already covers the case that actually bit.

## From worktree/project pinning (2026-08-16)

A reported cwd now answers two questions separately: the transcript always follows it
(`Session.transcriptDirectory`), while the tab moves in the sidebar only into a project that
is already open. Design record:
`superpowers/specs/2026-08-11-resumed-conversation-pinning-design.md` §6.1 and §7.

- **Phantom worktree projects already in the sidebar are not migrated — deliberate.** Sessions
  that entered a worktree before this change left `…/.claude/worktrees/<name>` projects behind,
  and nothing folds them back into their parents. A migration would have to guess which real
  project each one belongs under and relocate live sessions between projects during launch, on
  a heuristic, to save a one-time click of the project close button. Ruled out rather than
  overlooked; do not re-derive it.
- **A plain `cd` into a directory that happens to be another open project still moves the
  tab.** The sidebar cannot tell "resumed into that project" from "changed directory into it",
  and an open project is the only available evidence that a path is a project rather than a
  subdirectory. The move is at least visible in the sidebar, and strictly rarer than the
  phantom-project failure the conditional rule replaced (no undo, though: dragging a session
  between projects is still refused by `SidebarReorder`). The alternative — never
  moving — was considered and rejected: a genuine resume into an open project is worth
  following.
- **`ConversationPin.resolve`'s `workingDirectory:` parameter was misnamed — FIXED, and the
  name was hiding a bug rather than just reading badly.** It was deferred once as a cosmetic
  multi-site rename. It was not cosmetic: since the split that parameter is fed, and echoes
  back, the tab's *transcript* directory, and `Resolution` returned the echo and a genuine
  report under one name. `applyRegistry` refiled a tab on that field, so a tick that named no
  directory at all — no rows, or a live row with an empty `cwd` — looked like a report of the
  tab's transcript directory, and a tab whose transcript sat in a worktree the user still had
  open as a project was silently refiled into it. Before the split the echo was the tab's own
  project and always compared equal, so the branch was immune by construction.

  `Resolution` now carries both: `transcriptDirectory` (reported, else the echo — always
  usable, never evidence) and `reportedDirectory: String?` (nil when nothing was reported, an
  empty `cwd` included). The parameter is `transcriptDirectory:`, and the refile branch reads
  `reportedDirectory` only. A call-site gate was rejected: it would have left the trap intact
  for the next caller, and `moveSession` re-trips it the moment a drag-to-project UI exists,
  since a move leaves `transcriptDirectory` alone and the next quiet tick would echo it back.

  `ClaudeSession.transcriptURL(sessionID:workingDirectory:)` deliberately keeps its label —
  it is a pure path encoder whose argument really is "the directory `claude` is running in",
  it has no fallback and so no echo, and renaming it is a separate, genuinely cosmetic pass.

## From the mobile companion design (2026-08-18)

- **`SessionStore`'s fleet state should be encapsulated so a write cannot skip the event log —
  designed, deferred, not scheduled.** The mobile companion replicates the fleet by shipping an
  event log to the phone, and that has exactly one failure mode: a mutation site that changes
  `repos`/`statuses`/`unreadIdle` without appending its event leaves every connected client
  silently and permanently wrong until the next reconnect. Nothing crashes and no existing test
  fails, and the symptom on the phone reads as a network bug rather than a missing line in the
  store. The fix is to move the three fields into a `FleetState` value type whose storage is
  private and whose every mutating method records — making the omission unwriteable rather than
  merely detectable. Affordable because those fields are already `@Published private(set)` and
  reads outnumber writes heavily (72 referencing lines, a minority of them writes), so only the
  writes move and every read site stays as it is.

  Deferred purely on sequencing: it rewrites every write site in `SessionStore.swift`, which is
  the file the agent-adapter work is most actively changing, with codex session creation,
  codex auto-resume, and the agent preferences UI still outstanding — each adding mutation
  sites. Do it **after** those land, so one pass covers the codex sites too. Full event sourcing
  (a pure reducer) was considered and rejected for now: it forces every method to split into
  pure state change plus side effects, and that ordering is load-bearing in `createSession`,
  where getting it wrong reintroduces the half-bound-tab bug the codex work spent commits
  removing. Design, API shape, and the migration order are in
  [specs/2026-08-18-fleet-state-encapsulation-design.md](superpowers/specs/2026-08-18-fleet-state-encapsulation-design.md).

  **Until it lands, the mobile work carries an assertion instead** — after each tick, in tests
  and `#if DEBUG`, that folding the emitted events over the previous projection equals a fresh
  projection of the store. That assertion is the only thing standing between a new mutation
  site and a stale phone; do not remove it before the encapsulation replaces it.

## Codex rollout observation (2026-08-19) — landed, with these residues

Codex observation now reads the files codex writes: a per-thread rollout `.jsonl` for turn
boundaries and, per codex account, that account's `session_index.jsonl` for renames (rekeyed
from one app-wide file by the 2026-08-19 accounts work — see the entry below). Spec:
[superpowers/specs/2026-08-19-codex-rollout-observation-design.md](superpowers/specs/2026-08-19-codex-rollout-observation-design.md).
Everything below was found by that branch's reviews, triaged, and deliberately not fixed.

### Fixed

- **`codex resume` failed against a live app-server on codex-cli 0.148.0 — FIXED.** Codex
  holds a writer lock on a thread, and the interactive TUI refused with `thread/resume
  failed: thread <id> already has an active writer (code -32600)`. Flight Deck keeps ONE
  long-lived app-server per codex account (a thread belongs to the process that created it)
  and then spawns `codex resume <id>`, which is exactly the refused shape — so codex tabs
  appeared unable to launch on 0.148. Reproduced directly in that production shape; the
  adapter was built against 0.142.4/0.147.0, and `~/.codex` now has a `thread-writer-locks`
  directory, so this looked like newer codex behaviour rather than a regression here.

  `thread/unsubscribe` is NOT the release: it answers `{"status":"unsubscribed"}` and the
  lock stays held. The fix is `CodexAdapter.prepare` issuing `thread/archive` then
  `thread/unarchive` on the same connection right after `thread/name/set` — that round trip
  unloads the thread (`thread/loaded/list` goes from `[<id>]` to `[]`) and releases the lock
  while the app-server stays alive, with no need to stop or restart it. See the comment at
  that call site in `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift` for the full
  reasoning, including the archive-then-unarchive ordering hazard. Pinned hermetically in
  `Tests/FlightDeckTests/CodexAdapterTests.swift`, `CodexResumeTests.swift`, and
  `CodexLaunchFailureTests.swift`, and proven against a real app-server — a second connection
  successfully resuming the thread while the first stays up — by
  `CodexIntegrationTests.testPrepareReleasesTheWriterLockSoASecondConnectionCanResumeTheThread`.

### Worth doing

- **codex-cli 0.151.0 flipped the default thread-history contract from `legacy` to
  `paginated`, and Flight Deck now pins `legacy` explicitly** (`historyMode: "legacy"` on
  `thread/start`, gated by `CodexVersionProbe.supportsHistoryMode`'s 0.151.0 threshold, plus
  `capabilities.experimentalApi` at `initialize` — without it codex refuses the param). This
  keeps the `thread/start` does-not-persist / `thread/name/set` commits invariant the rest of
  the adapter relies on (see the doc comments in
  `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift` and `SessionStore.swift`). But `legacy`
  is **deprecated upstream** — codex ships a `migrate-rollouts` command to move users off
  it — so this pin will need revisiting once `legacy` support is actually removed, at which
  point the adapter has to speak `paginated` for real (a rollout is not written until a turn
  is taken, so the commit-on-name invariant this whole area depends on goes away). Also
  untested: codex-cli 0.149.x–0.150.x, which sit below the `supportsHistoryMode` threshold
  and so receive no `historyMode` pin at all — if `paginated` was already default there, the
  same failure this fix addresses would reproduce, and `AgentLaunchError.prepareFailed`'s
  diagnostic (the `rolloutExists` guard in `CodexAdapter.prepare`) is what should report it
  rather than an opaque `-32600`.
- **`SessionStore.swift:1408` (`stack.adapter.historyMode = ...`) — the single line that makes
  production use the right history mode — is not covered by any test, hermetic or live.**
  Deleting it leaves all 1959 hermetic and 5 live tests green.
  `CodexIntegrationTests.testARestoredCodexTabReattachesAfterAStartCodexFailure` does NOT cover
  it: that test deliberately makes `checkOffMainActor` throw, so execution never reaches the
  assignment. The fix is to give `SessionStore.startCodex` an injectable probe seam — a `run:`-
  style closure threaded through to `CodexVersionProbe.checkOffMainActor` — plus a testing read
  of the adapter's `historyMode`, which would let two hermetic tests exist: "a 0.151.0 codex
  gets `legacy`" and "a 0.147.0 codex gets `nil`".
  Also worth noting for whoever eventually migrates off `legacy`: if codex ever answers
  `-32600 no rollout found for thread id <id>` for a RESTORED thread under `paginated`,
  `CodexAdapter.isThreadGone` will match on "no rollout" plus the echoed id and `rebind` will
  re-pin the tab onto a fresh empty thread — the exact loss `isThreadGone` exists to prevent.
  This is pre-existing and harmless while `legacy` holds (restored threads always have a
  rollout under `legacy`), but it needs handling before `paginated` becomes real.
- **`SessionStore.newSession` returns a `Session` it did not create** when the project's claude
  account no longer resolves. The refusal is real — nothing is filed, no surface exists, and
  `launchFailureReporter` tells the user — but the return value is an unfiled draft, because
  widening the signature to `Session?` would touch ~140 call sites that all treat it as total
  and act on nothing. The honest shape is `Session?` (or routing every UI creation through the
  fallible `createSession`, which is where `ProjectHeaderRow`'s "New Session" and the folder
  drop should probably go anyway); do it when one of those call sites next needs the answer.
- **`CodexRuntime`'s two `watcher.stop()` calls are unasserted, and investigation found no
  black-box test can currently fail against their removal** (`CodexRuntime.swift:44,53`).
  Both calls are followed immediately by the only strong reference to that watcher being
  dropped (a dict overwrite or a `nil`), so ARC deallocates it synchronously either way, and
  `WatchClock.fire()` already prunes a dead owner before ticking it (see
  `WatchClockTests.testDroppedOwnerIsPrunedWithoutStop`) — confirmed by temporarily deleting
  each `.stop()` call in turn and rerunning a real-`WatchClock` regression test against it,
  which passed both with and without the call. The calls stay defensive (a future retention
  elsewhere would need them), but closing this gap for real would need a production-only test
  seam to retain the replaced/detached watcher, which felt like more than this cleanup should
  add unasked.

### Not worth doing

- The captured rollout fixture bakes a temp probe path (and so a username) into the repo.
  Editing it would violate the fixture's own verbatim rule, and git authorship already
  discloses the same thing.
- `CodexProcessTransport.stop()` sends SIGTERM without awaiting exit. Theoretical, unobserved,
  and integration-test-only; a wait would need a timeout policy for no measured gain.

## From the fleet replication spine (2026-08-19)

- **The drift assertion is temporary and must not be removed** until the `FleetState`
  encapsulation designed on 2026-08-18 lands — see the section directly above, which this entry
  does not repeat. It is not diagnostics: it is the only thing standing between a mutation site
  with no matching `FleetEvent` and a client that is silently and permanently wrong.

- **"Mark as Read" exists as a store method and a phone command, but has no Mac menu item.**
  `SessionStore.markRead` is the method the phone's `markRead` command lands on, added there
  specifically because the spec's rule is that anything the phone can do the Mac's own UI
  should too — but `SessionSidebar`'s row context menu offers only "Mark as Unread". There is
  no way to mark a session read from the Mac short of selecting it (which clears the mark as a
  side effect of viewing). Small, and deliberately not in this plan's scope.

- **The listener restarts to pick up a key change** (`FleetService.reloadKeys`), which drops
  every attached client for the length of a reconnect. Acceptable because revocation is rare and
  a client reconnects on its own, but worth knowing before someone calls it on a timer.
  `FleetSocketServer.stop()` drains both the `attached` and `pending` connection sets, so a
  rotation that catches a device mid-handshake no longer orphans its socket — that was a real
  leak, found in review, and the `pending` set exists for exactly this call path.

- **`FleetSocketServer`'s safety rests on its queue being serial, which `init(queue:)` does not
  enforce.** Every current caller passes the `.main` default. A concurrent queue would compile
  without complaint and break two things that both assume single-queue confinement: the
  `resumed` guard in `start()`'s `bind` helper, a plain `Bool` read and written from the
  listener's `stateUpdateHandler` with no lock, and `FleetService`'s `onAttachedSlotsChanged` handler,
  which reaches into `MainActor.assumeIsolated` on the strength of that same assumption (see the
  comment at that call site). Nothing catches a non-serial queue at compile time; passing one
  would surface only at runtime, as either a data race or a trap.

- **`wait(for:)` deadlocks in a `@MainActor async` XCTest method under the headless harness.**
  It blocks the main actor's executor in place without suspending it, which starves the very
  main-queue callbacks — `FleetSocketServer` and `FleetClient` both default their `queue:` to
  `.main` — that the wait is blocking on: the socket frame never arrives and the expectation
  never fulfills. `await fulfillment(of:)` is a genuine suspension point, so the queue keeps
  draining while the test waits; `FleetServiceTests` uses it throughout for exactly this reason.
  It also costs roughly 100ms per call even when it works, which `wait(for:)` does not. A
  non-`@MainActor`-isolated test class is unaffected by any of this, which is what makes the
  failure confusing the first time it is hit.

## From pairing and the phone (2026-08-19)

Plan 2 (`docs/superpowers/plans/2026-08-19-fleet-pairing-and-ios.md`) built pairing, Bonjour
discovery, and `FlightDeckMobile` on top of the spine above. What its own reviews found and
did not fix:

- **Paired secrets live in `UserDefaults` on the Mac** (`Preferences.pairedDevices`, added in
  Task 3) — recorded under "Deliberate choices worth remembering" above, which this entry
  does not repeat.

- **A key change restarts the listener**, dropping every attached client for the length of a
  reconnect — recorded in the section directly above this one (`FleetService.reloadKeys`),
  which this entry does not repeat.

- **Bonjour resolution, roaming and off-LAN reachability are manually verified only.** There is
  no automated coverage and there cannot be on one machine with one network interface — the
  twelve-item checklist in [docs/MOBILE.md](MOBILE.md) is what stands in for it.

- **No relay**, so reaching the Mac from off-LAN still needs a VPN — that half is unchanged.
  What changed, per `docs/superpowers/specs/2026-08-25-off-lan-endpoint-discovery.md`: the VPN
  address is no longer merely a candidate designed for. It is packed as a second endpoint in the
  pairing code alongside the LAN one, and refreshed on every connect over `mac.endpoints` — see
  [docs/NETWORKING.md](NETWORKING.md), "The endpoint refresh" and "Two endpoints, not more" —
  so a code scanned once keeps working after the tailnet address underneath it moves.

- **"Neither documented fallback was needed" — WRONG, corrected 2026-08-20.** This entry
  originally claimed `sec_protocol_metadata_access_pre_shared_keys` "genuinely yields" the
  PSK identity that actually negotiated a given connection, "verified by test." It does not,
  and whatever verified it was not exercising the case that matters: with two or more keys
  registered on one listener (i.e. two or more paired devices), the closure fires once per
  *configured* key on every connection, overwriting a local variable each time, so
  `FleetSocketServer.slot(of:)` returns whichever key was registered **last** — for every
  connection, regardless of which device actually shook hands. `attachedSlots()` (a `Set`)
  then collapses two genuinely distinct attached phones into one slot. Full writeup, repro,
  and status in "PSK slot misattribution with 2+ paired devices" below — this bullet is kept,
  corrected in place, so nobody re-reads the old claim as settled.

- **`FleetSocketServer.start()` cannot assert `dispatchPrecondition(.onQueue(queue))` as a
  first line the way `stop()`/`broadcast()` and `FleetConnector`'s entry points do.** Tried
  during the final review pass, and it trapped every time, `@MainActor` callers included:
  `start()` is a plain `nonisolated async` method, and Swift's concurrency runtime schedules a
  bare `await` call to one of those onto the default global executor regardless of the caller's
  queue — and, less obviously, resuming a `withCheckedContinuation` from inside `queue.async`
  does not make the *rest* of the async function's body keep running on `queue` either, since
  that resumption is scheduled by the task, not by whichever GCD queue happened to call
  `resume()`. The fix that landed: `start()` now dispatches its own body onto `queue` via
  `queue.async`, bridged back to `async`/`await` by one outer continuation, rather than
  asserting the caller already put it there — see the doc comments on `start()` and `bind(...)`.
  `stop()` and `broadcast()` are synchronous and unaffected by any of this; they keep the
  literal `FleetConnector`-style assertion as their first line.

- **The phone persists `lastSeq` on every applied frame**, deliberately: with the keychain item
  updated in place there is no write window, and the event rate is bounded by the Mac's
  activity filter and poll interval to roughly two per second per session. The cost that is
  real and unmeasured is that each write is a synchronous `securityd` round-trip on the
  connector's queue — which defaults to `.main`, the thread drawing the fleet list. If this
  ever shows up as scroll hitching, the fix is moving the write off the main queue, not
  throttling it.

## From closing the review gaps (2026-08-20)

Two small gaps left by the final review of the pairing branch: a missing regression test for
`onAttachedSlotsChanged`, and a false "zero diagnostics" claim about the iOS build. Closing the
first surfaced a third, unrelated finding serious enough to record here rather than only in a
commit message.

- **`FleetSocket.swift` has five real Swift 6 concurrency warnings — verified, not
  hypothetical.** `Sources/FleetKit/FleetSocket.swift:34,47,58,58,68` — "capture of \<param\>
  with non-Sendable type ... in a '@Sendable' closure" at 34 (`onError`), 47 (`onEnd`), 58
  (`onFrame`), 68 (`type`), plus a second, distinct warning also at 58 ("capture of
  non-Sendable type 'Frame.Type' in an isolated closure"). Confirmed by forcing a recompile of
  just that file (`touch` + `xcodebuild -scheme FleetKit build` / `-scheme FleetKitiOS -sdk
  iphonesimulator build`) — both targets emit the identical five warnings at the identical
  lines. Not a regression from this branch: `FleetSocket.swift`'s last commit is an ancestor of
  master, and type-checking it at `c590087` and `ba78b7e` gives byte-identical output.

  Why nobody noticed: `./scripts/build.sh` and `./scripts/build-ios.sh`, run normally, see
  these targets already up to date in DerivedData, so the compile task for this file is
  skipped — "the build is clean" was never a claim either script could actually support as
  normally invoked, only an artifact of incremental builds. `touch` the file, or clear
  DerivedData, to see them.

  Not urgent: `FleetSocket` is queue-confined the same way `FleetClient`/`FleetSocketServer`/
  `FleetConnector` are (`@unchecked Sendable`, every touch on one queue), so these are
  compiler noise about a real discipline the code already has, not a live data race. The shape
  that resolves them is already in the tree: `QRScannerController` in
  `Sources/FlightDeckMobile/PairingScreen.swift` moves the non-Sendable capture state
  (`AVCaptureSession`/`AVCaptureMetadataOutput`) onto its own private `@unchecked Sendable`
  reference type (`CaptureResources`) and captures *that* — a `Sendable` value — across the
  `@Sendable` boundary instead of the non-Sendable types directly. `FleetSocket.send`/
  `.receive` would need the same move for `onError`/`onEnd`/`onFrame`/`type` before any of the
  four callers'-worth of closures would type-check clean.

- **PSK slot misattribution with 2+ paired devices — FIXED (2026-08-20), writeup kept for the
  reasoning trail.** Found while writing the `onAttachedSlotsChanged` two-device regression test
  the review asked for. Corrects the "Neither documented fallback was needed" bullet directly
  above (2026-08-19 section); this is the full writeup that bullet points to. What the fix
  turned out to be is at the end of this entry.

  `FleetSocketServer.slot(of:)` reads a connection's PSK identity via
  `sec_protocol_metadata_access_pre_shared_keys`. That call's own header doc says it returns
  "the PSKs supported by the local instance" — verified here to mean *every* PSK configured on
  the *listener*, not the one a given peer's handshake actually negotiated. With one key
  registered (every shipped test, and the common case of one paired device) that distinction is
  invisible: there is only one PSK to enumerate. With two or more, the closure fires once per
  configured key for every connection and overwrites a local variable each time, so
  `slot(of:)` returns whichever key was registered **last**, for every connection, regardless
  of which device actually shook hands. `attachedSlots()` (a `Set`) then collapses two
  genuinely distinct attached phones into one slot.

  Reproduced cleanly: two keys registered on one listener, two real `FleetClient`s connecting
  **sequentially** — after only the first client (`firstKey`) attaches, the server's reported
  slot set already reads `[secondKey.slot]`, not `[firstKey.slot]`. The handshake's
  cryptography itself is unaffected — each client authenticates against its own secret
  correctly; only the server's readback of *which* key negotiated is wrong.

  Not a regression from this branch: `FleetTLS`'s use of
  `sec_protocol_metadata_access_pre_shared_keys` predates the `onAttachedSlotsChanged` fix
  under test, introduced in `45f1221`. It is a real production concern, not a test-only
  artifact — `FleetService.start()` passes every currently-paired device's key to
  `server.start(keys:)`, so any Mac with 2+ paired phones is affected today: the Devices tab
  cannot reliably tell two attached phones apart, and a disconnect can update or clear the
  wrong slot's badge.

  **The fix, and the API that turned out to do the job.** The second of the two sketched
  directions was right, and the doubt attached to it here ("a client-hint API, so this
  direction is unconfirmed") was wrong.
  `sec_protocol_options_set_pre_shared_key_selection_block` is documented from the client's
  point of view (`SecProtocolOptions.h:406-420`, "when the client must choose a PSK identity
  given a hint from its peer"), but installed on *listener* options it fires once per incoming
  connection with the hint carrying the identity the **client** offered — measured against a
  real two-key listener, not inferred. The `sec_protocol_metadata_t` it is handed is the same
  object the connection later exposes as `NWProtocolTLS.Metadata.securityProtocolMetadata`
  (pointer-identical, also measured), so the recorded identity can be looked up per connection.
  `FleetPSKIdentities` in `Sources/FleetKit/FleetTLS.swift` is that record;
  `FleetSocketServer.slot(of:id:)` reads it and caches the answer per connection.
  `sec_protocol_metadata_access_pre_shared_keys` is no longer used for attribution. The client
  never names its own slot, so the other sketched fallback — a nonce/HMAC round trip in `hello`
  — was not needed, and neither was any protocol change.

  Authorization is untouched, and that was checked rather than assumed: with the selection block
  installed, a *paired* identity presented with the wrong secret is still refused (`bad MAC`,
  -9846) and an unregistered identity is still refused (`unknown PSK identity`, -9864). The
  identity is a claim; the PSK remains the credential. Guarded by
  `Tests/FlightDeckTests/FleetSlotAttributionTests.swift` (two keys, two real `FleetClient`s),
  which fails against the old implementation on all three tests.

  **The test-host `SIGABRT`: investigated, and the evidence says it is not ours.** A fuller
  version of the reproduction above — two clients, one disconnecting after both are attached —
  twice produced a `SIGABRT` ("freed pointer was not the last allocation") during XCTest's
  tearDown, crashing the whole `xctest` process (reports under
  `~/Library/Logs/DiagnosticReports/xctest-2026-08-20-1450*.ips`). Re-examined 2026-08-20:
  the faulting stack is `_swift_task_dealloc_specific` ->
  `XCTSwiftErrorObservation._observeErrors(in:)` -> `-[XCTestCase
  _performTearDownSequenceWithSelector:]`, entirely inside XCTest's async-tearDown machinery.
  **No FleetKit, FlightDeckTests or Network.framework frame appears on the faulting thread or
  on any other thread in either report**, and the assertion is the Swift *task* allocator's
  LIFO check, not a heap free — memory sockets never touch. Attempts to reproduce it: the
  two-client attach/attach/disconnect scenario run 25x in isolation, 10x alongside every other
  socket test class in one process, and in four further shapes (a red assertion, a timed-out
  expectation, tearDown racing the drop, stopping the server with both attached) — against both
  the fixed and the *unfixed* server, ~90 test processes in all. Zero aborts; no new crash
  report was written. So it is treated as an XCTest harness artifact, not a use-after-free in
  `FleetSocket`/`FleetClient`, and the two-device disconnect test is now checked in
  (`testDroppingOneDeviceLeavesTheOtherOnItsOwnSlot`). Not *proven* absent — an intermittent
  harness bug that has not recurred cannot be — so if it ever resurfaces, the thing to capture
  is the fresh `.ips`: a FleetKit frame appearing in one would overturn this reading.
## Agent accounts (2026-08-19) — what the work left behind

Spec: [superpowers/specs/2026-08-19-agent-accounts-design.md](superpowers/specs/2026-08-19-agent-accounts-design.md).
An account is a login, identified by its config directory (`CLAUDE_CONFIG_DIR` /
`CODEX_HOME`); every observation root that used to be an app-wide constant now derives from
the account a session runs as. Three things this deliberately did not build:

- **Relocating an account is blocked while any of its sessions are open — a refusal, not a
  migration.** `PreferencesStore.relocateAccount` only rewrites the stored `home`; it never
  moves a file. The guard that makes this safe is the same one `canRemove` uses for delete
  (`AccountsSection.canRemove`, `Sources/FlightDeck/Preferences/UI/AccountsSection.swift`): an
  account with a tab bound to it (`boundAccountIDs`) cannot be relocated either, so there is no
  window where a live tab's transcript/registry watcher is pointed at a home nobody told it
  about. There is no data-migration path (copying transcripts, re-pointing an in-flight
  watcher) — the user closes the account's tabs first, or does not relocate it.
- **"Scan for Accounts…" is the only way to pick up a home created after first launch.**
  `Preferences.migrateAccountsIfNeeded` (`Sources/FlightDeck/Preferences/Preferences.swift`)
  discovers sibling account directories exactly once, on first migration — deliberately not a
  re-scan on every launch, because a re-scan would resurrect an account the user removed. A
  `~/.claude-something` created afterwards (a new login added on the machine after Flight Deck
  first ran) is invisible until the user opens Preferences → Accounts and runs "Scan for
  Accounts…" by hand.
- **A typed account Location is not tilde-expanded.** `AccountDraft.trimmedHome` builds the
  home with `URL(fileURLWithPath:)` on the raw text, so a hand-typed `~/.codex-work` resolves
  against the process working directory rather than `$HOME` — it then passes `validate` as
  vacant and a bogus `./~/.codex-work` gets created. Not reachable through `Choose…`, which
  hands over a real URL, and not reachable from the derived default. The only expansion in the
  codebase is `FlightDeckApp.stateDirectory`'s; when this is fixed the expansion belongs in
  `trimmedHome` so `validate` inspects the same directory Add creates. Noted here because the
  one place that *did* expand a tilde in a home path — `CodexNameWatcher`'s read of Flight
  Deck's own `CODEX_HOME` — was deleted by this work, and with it the only test for it.
- **Codex's `-p` config profiles remain unimplemented, and are a different axis from
  accounts.** `codex -p <name>` layers `$CODEX_HOME/<name>.config.toml` over one `CODEX_HOME` —
  it is a config profile inside one login, not a second login. The design spec names this
  explicitly (§2, §7.5 "Deferred") as a future `CodexThreadOptions` field; nothing in this work
  reads or writes a `-p` profile, and an account switch does not change which profile (if any)
  a codex thread would use.

## Where accounts and the fleet meet (2026-08-20, from merging the two)

- **A phone cannot tell which login a session runs as, and that is the decision, not an
  oversight.** An account is a config directory, so it stays off the wire entirely — see
  `docs/ARCHITECTURE.md` § "Fleet replication" and `FleetAccountEmissionTests`. If a client
  ever needs to *distinguish* two logins visually, the thing to replicate is a stable opaque
  handle minted for the wire plus the account's display name — never `AgentAccount.id` (it is
  the key to a home path) and never the home itself.

- **`accountMismatchedSessionIDs` is sidebar-only and deliberately not replicated.** It is
  derived from preferences (which account a *project* would pick today) rather than from
  `repos`/`statuses`/`unreadIdle`, so it changes with no `SessionStore` mutation and therefore
  with no `FleetEvent` — replicating it would mean either a preferences observer feeding the
  event log or a field that silently goes stale. Neither is worth it for a warning badge, but
  a client that grows one will need the first.

- **The per-account registry merge is not under the drift check.**
  `SessionStore.applyRegistry(_:from:)` — which unions every account's last scan before
  committing statuses — is private and only reachable through a real `SessionStatusWatcher`,
  so no test drives it with a replicator attached. It funnels into the same
  `applyRegistry(_:)` that `applyRegistryForTesting` does, which *is* covered, so the emission
  itself is pinned; what is not pinned is the merge deciding *which* rows reach it. A seam for
  the per-account entry point would close that.

## Pairing crypto foundation (2026-08-21)

- **`SPAKE2SessionTests` has no fixed test vector, and there is no specification for one to
  conform to — this vendored BoringSSL SPAKE2 is not CFRG SPAKE2.** Three divergences, all
  read from `vendor/boringssl/crypto/curve25519/spake25519.cc`: its `M`/`N` points are
  BoringSSL's own generated constants (line 47, "These points and their precomputation tables
  are generated with..."), not RFC 9382's published ones; `disable_password_scalar_hack`
  (checked at line 400) is a unilateral fix for a BoringSSL bug that is baked into the wire
  format, not an interop option; and the transcript hashes `password_hash` (SHA-512 of the
  password, line 374) rather than the derived scalar `w`, with cofactor multiplication folded
  in — see `update_with_length_prefix` and the final `SHA512_Final` around lines 451-518.
  SPAKE2+ (RFC 9383, which does ship test vectors) is not in this submodule pin either.
  Separately, `vendor/boringssl/crypto/curve25519/spake25519_test.cc` line 29 confirms no
  vector was ever added upstream ("TODO(agl): add tests with fixed vectors once SPAKE2 is
  nailed down"), and `SPAKE2_generate_msg`'s public API gives no way to fix the ephemeral
  scalar from outside, so even a hypothetical vector would not be drivable through
  `SPAKE2Session`.

  This means a fixed vector would not be validation — a *conforming* implementation would not
  interoperate with BoringSSL's SPAKE2, and a vector conforming to BoringSSL's variant would
  not check anything against a specification, because there is no specification for this
  variant. The property that matters here is **agreement, not conformance**: both ends of a
  pairing exchange run this same BoringSSL, so what needs proving is that this wrapper's two
  ends agree with each other, which `SPAKE2SessionTests` already does.

  The genuine residual risk is narrower than "is the algorithm right" and sits in this
  wrapper's marshalling, not BoringSSL's math: a bug that swapped `.initiator`/`.responder`, or
  the two name arguments to `SPAKE2_CTX_new`, would be wrong identically on both sides and pass
  every round-trip test. **This entry previously said a cross-process macOS-against-iOS exchange
  was what would close that. That was wrong.** Both ends compile the same `FleetKit`, so a
  consistent swap is applied on both sides of the wire and survives a cross-process test exactly
  as it survives an in-process one. Demonstrated rather than argued: two mutants — roles
  swapped, and names passed swapped — each pass all 17 SPAKE2 and `PairingSecrets` tests.

  What closes it is a second implementation of the *caller*, not a second process.
  `testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder` drives one side through the raw C
  API with a literal `spake2_role_alice` and the argument order `curve25519.h` declares, the
  other through `SPAKE2Session`, and asserts the derived keys agree. The raw side is written
  from the header rather than from the wrapper, so agreement pins the wrapper's mapping to
  BoringSSL's own convention. Both mutants fail it. **Closed, in process.**

  Worth recording what a swap would actually have cost, because it is less than the original
  wording implied: a *consistent* role or name swap is pure relabelling. Both names still reach
  the transcript, still in a fixed order, still distinguishing one device from another — so such
  a wrapper would be unconventional, not insecure. The residual risk here was smaller than we
  said, and is now pinned anyway.

  A cross-process macOS-against-iOS exchange still belongs in the plan that wires pairing to a
  socket, but for **caller-side asymmetry** — the two ends disagreeing about which is the
  initiator, about the names they pass, or about how they assemble the transcript — which is the
  thing that plan can genuinely get wrong and which no single-process test constructs.

  Revisit if either upstream BoringSSL lands fixed vectors, or the vendored submodule moves to
  a version carrying SPAKE2+ (RFC 9383).

- **The spec's test-vector requirement is now amended, not silently dropped.**
  `docs/superpowers/specs/2026-08-21-short-pairing-code-design.md` §5 originally required
  validation "against published test vectors, not round-trips," on the sound reasoning that a
  round-trip only proves the two ends agree with each other, not with the specification. The
  finding above is that the requirement was never satisfiable for the reason just given — there
  is no specification this variant conforms to — so §5 now carries the finding inline as an
  amendment rather than having the sentence quietly disappear for a later reader to wonder
  about.

- **Swift-side key buffers are not scrubbed.** `SPAKE2Session` reads key material into a Swift
  `[UInt8]` and returns it as `Data`; `PairingSecrets` holds two `SymmetricKey`s and a
  transcript. None of that is zeroed on the way out — Swift has no reliable way to, since the
  compiler is free to copy a value anywhere and eliding a final write to memory that is about to
  be freed is a legal optimisation. BoringSSL's own side is clean (`SPAKE2_CTX_free` cleanses
  before `OPENSSL_free`), so this is the Swift half only. It matters if the process is core-
  dumped or swapped between a pairing exchange and its next collection, which for a foreground
  Mac app during a 2-minute window is a narrow target. Revisit if pairing material ever
  outlives a window, or if key handling moves anywhere long-lived; `CryptoKit`'s
  `SymmetricKey` already zeroes its own backing store, so the exposure is the intermediate
  `Data`/`[UInt8]` buffers rather than the keys themselves.

- **BoringSSL is pinned to a tag and updated by hand; nothing watches upstream for security
  fixes.** `BORINGSSL_TAG` in `scripts/build-boringssl.sh` names `0.20250114.0`, and the script
  refuses to build if the submodule has drifted off it — but moving the pin forward, including
  for a CVE, is a human noticing and doing it deliberately. This is the same standing
  obligation `vendor/ghostty`'s pin already carries; it is worth saying plainly here rather than
  leaving it to be rediscovered the day a BoringSSL advisory lands.

- **The vendoring is a submodule, not a committed artifact — a committed `BoringSSL.xcframework`
  was tried first, at 54 MB, and reverted the same day** (fda5c22, then 8f36b33). The tradeoff
  a committed artifact bought was one less local build step; what it cost was 54 MB of binary in
  every clone and a second vendoring pattern next to `vendor/ghostty`'s submodule-plus-build-
  script one, for no reason other than that BoringSSL's build happened to be written second.
  `vendor/boringssl` is now a submodule pinned to the tag above, and
  `scripts/build-boringssl.sh` builds it into the git-ignored `vendor/boringssl-artifacts/` —
  the same shape `scripts/build-libghostty.sh` already uses, so there is one build pattern to
  know instead of two, and upstream stays a live submodule rather than a snapshot nobody
  re-pulls.

- **A fresh clone now needs a second submodule-and-build pair before anything builds.** Same
  shape as libghostty, one more of them: `git submodule update --init vendor/boringssl` then
  `./scripts/build-boringssl.sh`, in addition to the existing `vendor/ghostty` /
  `build-libghostty.sh` pair. `docs/BUILD.md`'s "From a fresh clone" section and its
  "Worktrees" section (a new worktree has neither artifacts directory populated, for the same
  git-ignored reason) both now say so.

## From the typed pairing code (2026-08-22)

Two plans — `docs/superpowers/plans/2026-08-21-pairing-channel.md` and
`docs/superpowers/plans/2026-08-21-pairing-ui.md` — turned the SPAKE2 foundation above into a
twelve-character code a user can type, over a listener that exists only while a window is open.
What they left behind, deliberately unfixed:

- **The QR payload has no integrity check, so a corrupted one decodes to a *wrong key* rather
  than being refused.** `PairingPayload.init(decoding:)` validates the record's shape — the
  `FD2-` prefix, digits-only version, the version byte repeated inside the body, both name
  lengths, and `cursor == bytes.count` — and none of that reaches the 32 bytes of secret in the
  middle. A single flipped bit in those 32 decodes cleanly into a different, well-formed key.
  The phone stores it, dials the fleet listener, and the handshake is refused *by silence*
  (Apple drops a mismatched PSK identity rather than sending an alert), so the phone reports
  something that looks like a network problem and the Mac logs nothing at all. Diagnosable from
  neither end.

  This is not new — v1's base64url'd JSON had exactly the same property — and it is not what a
  QR actually fails at: correction level `M` either reconstructs a camera misread or refuses to
  decode, so landing a corrupted-but-well-formed record on the phone takes deliberate
  corruption or a generator/scanner bug, not glare. That is why it has never bitten, and why
  this is recorded rather than fixed. **A one-byte checksum over the record is the only thing
  that closes it** — computed across every preceding byte, checked before any field is read,
  reported as `.malformed`, which the phone already renders as "That code is damaged. Show a
  new one on your Mac." It costs two base32 symbols and a version bump, and a version bump is
  cheap here because codes live 120 seconds: there is no installed base of QRs to migrate.
  Nothing weaker closes it, because shape validation cannot see into a secret by definition.

- **A peer that speaks holds one of four pairing slots for 30 seconds, and no deadline value
  eliminates that.** `PairingListener.maxPending` is 4; `exchangeDeadline` is 30s. The *silent*
  peer is already handled — `firstFrameDeadline` evicts a connection that has said nothing in 5
  seconds *after its socket became usable*, and `handshakeDeadline` gives it 10 to get that far,
  which is what makes the long deadline reachable only by a peer that spoke. What
  remains is the peer that speaks: one valid `pake` frame is a curve25519 point, which anyone
  can generate against any password, and it earns the full 30 seconds. Four of those, renewed,
  keep the legitimate phone refused at `accept`'s cap guard for the length of a window.

  It is worth being exact about how little that buys. It costs the attacker no attempts (only a
  mismatched `confirm` charges the three-guess budget) and yields no information (SPAKE2 gives
  one online guess per exchange and no offline path). So this is **availability only, LAN-local,
  and it denies only the typed path** — a phone pairing by QR never touches this socket at all;
  it dials the fleet listener with the key the code carried, out of that listener's own 16-slot
  pool. The user's way out is the QR, which is one of the reasons the typed path is documented
  as the fallback rather than the primary. Lowering `exchangeDeadline` narrows each slot but
  cannot remove a slot reachable by legitimate-looking work, and dropping it below
  `PairingInitiator.exchangeTimeout` (8s) would make the Mac the side that gives up first on a
  slow-but-live phone. What would actually close it is per-source accounting — a cap per peer
  address rather than per listener — and that is a different mechanism, worth its own slice only
  if anyone ever sees this happen.

- **Two code comments are now known to be wrong, both found by mutating the thing they
  describe.** Recorded so nobody re-derives them; neither is corrected in the source yet, and
  each is a one-line fix.
  - `FleetModel.connect()` says that assigning main-actor state from a `FleetConnector` (or
    `PairingRunner`) callback "is an error the compiler cannot see past on its own". It is not:
    removing `MainActor.assumeIsolated` from `pair(code:)`'s `onProgress` still **builds** under
    Swift 6, with the build log confirming `FleetModel.swift` was recompiled under
    `-swift-version 6`. A non-`@Sendable` closure literal formed in a `@MainActor` context
    inherits that isolation, so the compiler never needed the assumption. The annotation is a
    **runtime tripwire, not a compile-time necessity** — it traps loudly rather than corrupting
    state if either type is ever handed a queue other than `.main` — which is a good reason to
    keep it and not the reason the comment gives.
  - `PairingCodeView`'s typed-code comment says uppercase "buys nothing in the QR, where `FD`
    and `fd` measure the same 39 modules". Both numbers are stale: 39 was a CoreImage *extent*
    read as a module count, and re-measured on the same payload `FD2-<body>` is **45** modules
    against **53** for the same body lowercased behind `fd2-`. The case is worth 8 modules after
    all. The conclusion the sentence supports — uppercase is kept for the *reader*, because
    Crockford base32 is only unambiguous in one case — is unaffected, which is why no code
    changed; `PairingPayload.prefix`'s doc comment carries the corrected measurements.

- **`FleetSocketServer`'s sixteen pending slots are not all authenticated, and the comment
  claiming they were is now corrected rather than made true.** `maxPending` read "each has
  completed a TLS-PSK handshake — it cannot be a stranger". That holds for the entries past
  `.ready` and not for the rest: `pending` is filed in `accept`, which fires when TCP connects,
  so anyone who can open a socket to the Mac takes a slot for `handshakeDeadline` — 10 seconds
  since the deadline split, up from the 5 `authDeadline` used to give them. Sixteen sockets at
  1.6 connections a second is what it takes to keep a real phone refused at `accept`'s cap
  guard.

  Same shape as the pairing pool above and the same verdict: **availability only, LAN-local**,
  it costs the attacker nothing and yields nothing, and the deadline cannot be shortened past
  `FleetConnector.raceTimeout` (8s) without making the Mac the side that hangs up on a
  slow-but-live phone — which is the bug the split exists to fix. It is also milder here than
  there: the pairing pool is 4 and closes a window the user is watching, this one is 16 and only
  delays a reconnect that retries on its own backoff. What closes it is the same thing —
  per-source accounting, a cap per peer address rather than per listener — and it is worth
  building once, for both listeners, if either is ever seen to happen.

- **The Mac's pairing sheet says the same thing three times.** The warning paragraph ends "It
  expires in 2 minutes.", the countdown under it reads "Expires in 1:47", and the typed-code
  block ends "Only works on this Wi-Fi network." Every line shipped for its own reason and none
  of them is wrong; together they read as a sheet that does not trust the user to have read the
  line above. An editing pass, not a defect — and the right time to do it is alongside the
  596pt-sheet-on-a-560pt-window question in [docs/MOBILE.md](MOBILE.md), since cutting a line is
  also the cheapest way to lose the 36pt overhang.

## From the session timeline screen (2026-08-23)

- **A timeline item is capped at 64 KB and a page at 128 KB.** A file read larger than the item
  cap is truncated, with the shortfall stated on the row (a `scissors` chip) and in full on the
  detail screen ("Showing the first 584 bytes of 69 KB"). The alternative — a second round trip
  fetching one item whole — needs an offset index the transcript readers do not build, and
  64 KB covers essentially every command output. Revisit if "open it on your Mac" turns out to
  be a common answer rather than a rare one.

- **An open session screen polls at 1.5s while the session is busy.** History is pulled, not
  pushed (spec §6), and the Mac emits activity events only on genuine transitions, so a long
  busy turn signals nothing in the middle of it. A push channel would need per-connection
  subscription state in `FleetSocketServer` and a northbound frame outside the `seq` space;
  that is a real design, not a tweak, and the poll is cheap enough that it has not earned one
  yet.

- **"Is the reader at the live edge" is inferred from a 1pt sentinel row.** `follow` needs to
  know whether the end of the conversation is on screen, and on iOS 17 there is no scroll
  geometry to ask — `onScrollGeometryChange` and `defaultScrollAnchor` on a `List` are both 18+.
  So a zero-height trailing row's `onAppear`/`onDisappear` carries it. It is a real signal and
  it is coarse: a row taller than the screen between the reader and the sentinel reads as "not
  at the bottom" even when the reader is following along. Worth replacing with scroll geometry
  the moment the deployment target moves to 18.

- **A tool card shows six lines of output and three of input, and the numbers are taste.** They
  were chosen by rendering a real conversation and looking — enough to recognise a result,
  little enough that one `Read` does not bury the turn around it — not measured against
  anything. If a reader ends up tapping through on every row, they are too small.

- **`layer.render(in:)` cannot see a programmatic scroll.** Recorded in
  [docs/MOBILE.md](MOBILE.md) beside the technique itself, because the failure looks exactly
  like the `drawHierarchy` trap it replaced: several different screens coming back as one
  identical blank PNG. Anything that has to be verified *after* a scroll needs
  `xcrun simctl io <udid> screenshot` and a window attached to the app's own `UIWindowScene`.

## Answering prompts from the phone (2026-08-24) — three gaps, accepted on purpose

From `docs/superpowers/plans/2026-08-24-answering-prompts-from-the-phone.md`. All three are
scope decisions, recorded so that **disagreeing with one is a change to a decision rather than
the discovery of a bug**. Each is argued rather than apologised for, because each was reached
by ruling out the alternative and not by running out of time.

- **A paired phone can approve a tool in a tab nobody is looking at.** The only Mac-side signal
  that it happened is the terminal moving — the selection travelling to a row and a Return
  landing on it. There is no per-tab opt-in ("this session may be answered remotely"), no
  notification, and no allow-list of which tools may be approved from a pocket. That is
  deliberate, and the reasoning is that a companion which must be confirmed on the Mac is not a
  companion: the whole case for the feature is the person who is not at the desk. What
  *changed* here is not the blast radius but **who decided** — a typed message is a request the
  agent may refuse, and everything dangerous it leads to still stops at a permission prompt,
  whereas a permission decision **is** the stopping point and there is no layer under it. The
  control the spec names is the only one shipped, and it is the right shape for this: **pairing
  is all-or-nothing and revocation is immediate**, with Settings → Devices showing which device
  is attached while it does this. If per-tab consent is ever wanted, it is a new mechanism with
  its own state, not a flag on this one.

- **The permission card cannot show the dialog's own wording, and shows the tool call
  instead.** Claude assembles a permission dialog's text in its TUI at display time, out of the
  live permission rule set — it exists in no file, no transcript record and no hook payload, so
  there is nothing for Flight Deck to read and nothing to put on the wire. The card is built
  from the tool call itself, which the phone already has **whole** from the history channel:
  the tool's name, and its entire input. So a Bash approval on the phone shows the full command
  where the terminal shows a one-line summary — the card is arguably *more* legible than the
  dialog it is standing in for, not less. What it costs is exactness: the card cannot promise
  that the words on the phone are the words on the Mac. The two are derived from the same call
  by different renderers, and if claude ever adds a warning to its own wording, the phone will
  not carry it. That is the trade, and it is the reason Deny leads on the card.

- **There is no case for "Yes, and don't ask again for X in Y", and that is a security
  property rather than a missing feature.** Claude's dialogs can put a durable grant in their
  middle rows — a rule that outlives the tap, written from a pocket, off a label a fixed-width
  terminal has wrapped. **It is structurally unreachable from the phone, twice over.**
  `PromptAnswer` has no case that names one, so there is no index a client could send and no
  button the card could draw; and the Mac never offers one, because `SessionStore.answerPrompt`'s
  `.allow` arm targets the dialog's first row and confirms it is there before pressing Return.
  A phone cannot widen its own future authority — the property is that, stated once.

  Worth recording honestly: **the captured Bash dialog in claude 2.1.241 has only two options
  and no such row at all** (`Yes` / `No`; the three-option shape exists on `Write`, whose middle
  row is accept-edits mode rather than a durable per-directory grant). So this property
  currently guards a case that did not arise in the dialogs anyone has looked at. It is kept
  because the ones that do arise are exactly the ones nobody will notice arriving: a claude
  release that adds a grant row to Bash needs no change here to be safe, and a design that had
  merely *avoided* the row by index would have silently started approving it.

These three are what the feature deliberately does **not** do. What it does do, and what no
automated test can watch it doing, is checked by hand: [docs/MOBILE.md](MOBILE.md) items 42-50,
which are the only cover the three untestable parts have — a key event reaching a real surface,
`.allow` finding the first row, and the status-file/transcript write race.

**Two things this work discovered that outlive it**, both about verification rather than about
the feature, and both written up where someone will hit them rather than here:

- **`xctest -XCTest FlightDeckTests/SomeClass` runs zero tests and reports success**, so a
  mutation "verified" through it is not verified at all. The working spelling and the measured
  0-versus-21 are in [docs/AGENT-OPERATIONS.md](AGENT-OPERATIONS.md) §5.
- **`layer.render(in:)` returns a blank image for a `List` that has scrolled** — hit a second
  time here, by the whole-screen render of the prompt card, and a longer settle changed nothing.
  The entry above this one records the rule; the working route (a window on the app's own
  `UIWindowScene` held across an `xcrun simctl io … screenshot`, with the two-file handshake
  that makes it possible) is in [docs/MOBILE.md](MOBILE.md) beside the technique.

## Detached session persistence (2026-09-07), carried forward from Phase 1

`fd-abduco` (`vendor/fd-abduco/`) is a vendored fork; all four items below were flagged in
Phase 1's own review and are unreachable from Phase 2's paths, which is why they were deferred
rather than fixed alongside the daemon wiring.

- **Replay backpressure: `write_all` busy-spins on `EAGAIN`.** `server.c`'s attach-time replay
  (the loop that hands a newly-attached client the captured `FdOutlog` history, one packet at a
  time via `server_send_packet`) goes through `abduco.c`'s `write_all`, whose retry loop treats
  `EAGAIN`/`EWOULDBLOCK` exactly like `EINTR` — `continue` with no wait. For a slow or
  non-draining client with a large backlog to replay, that spins the daemon's CPU instead of
  blocking. The server already runs a `select()` loop with a `writefds` set sitting unused for
  this purpose; the fix is to drive replay through it (queue the remaining chunks, mark the
  client's fd in `writefds`, resume the write when `select` reports it writable) rather than
  through a tight retry. Unreachable today because replay payloads in practice fit well within
  socket buffer sizes before a client can be slow enough to matter — worth fixing before Phase
  3's user-facing scrollback-budget preference lets that payload grow large enough to matter.
- **Nested-binary code-signing is unvalidated.** `SessionDaemon.resolvedBinaryPath()` symlinks
  to the bundled `fd-abduco` and Flight Deck `exec`s it directly; nothing here checks that the
  binary's signature matches expectations before that first `exec` under the app's hardened
  runtime. A binary that failed to sign (or was tampered with post-build) would only surface as
  a launch failure at exec time, not as a clear signing error. Worth a `SecStaticCodeCheckValidity`
  probe (or equivalent) the first time a launch resolves the symlink, logged clearly rather than
  left to whatever `posix_spawn`/exec reports.
- **Opportunistic `FdOutlog` hardening**, all in `vendor/fd-abduco/fd_outlog.c` /
  `server.c`, none exercised by any budget-trim or replay test because none of them are reachable
  short of an actual allocation failure or code that never runs on the path taken:
  - `fd_outlog.c`'s `ensure()` does not NULL-check `realloc`'s return before assigning it to
    `o->data` — an allocation failure on a very long-lived session (budget growth, not the
    normal trim-at-`2×budget` path) would silently corrupt `o->data` and drop the old pointer,
    leaking it. Belongs beside the existing bounded-budget design, not as a behavior change to it.
  - `server.c` never calls `fd_outlog_free(&server.outlog)`, so the log's buffer is never
    reclaimed. Harmless as written — the server only ever exits via `_exit`/signal, which the OS
    reclaims for free — but worth adding for symmetry with `fd_outlog_init`, and in case a future
    change adds a graceful-shutdown path that returns from `main`.
  - `server.c`'s `MSG_RESIZE` handler has a redundant self-assign: the `else` branch of
    `if (c->state != STATE_ATTACHED) { c->state = STATE_ATTACHED; ... } else { c->state = STATE_ATTACHED; }`
    reassigns a value the `else` condition already guarantees. Cosmetic; safe to delete the
    `else` body's assignment when next touching that function.
- **Debug and Release no longer share state — but only by file path, not by identity.** The
  daemon root (`/tmp/flight-deck-debug-<uid>`) and, since 2026-09-29, the state directory
  (`Flight Deck (Debug)`, with an override naming the live directory refused) are both salted
  by build. The latter closed the worst collision: a Debug bundle launched from a worktree's
  DerivedData restored the live `sessions.json`, resumed a duplicate agent for all 62 sessions,
  and the duplicates' newer `~/.claude/sessions/<pid>.json` rows won the registry tie-break —
  every question raised afterwards read as `idle` and never reached the phone. Still shared:
  the `UserDefaults` domain (one bundle id — preferences, pairing, `installID`) and the logs.
  The bundle-id half is planned in
  `docs/superpowers/plans/2026-09-24-debug-build-identity-isolation.md` (its Task 4 is the
  state-directory salt, now done). A **Release** bundle launched from DerivedData still reads
  the live deck; nothing but AGENTS.md rule 2 stops that.

## API-error badge (2026-09-03)

- **No backfill of API errors missed while closed.** `TailReader` starts a first look at an
  existing transcript at its current end, so a session that died while Flight Deck was not
  running gets no badge beyond whatever the `sessions.json` snapshot restored. Scanning
  backwards for a trailing error record means finding the last assistant record and proving
  nothing followed it — real complexity, deferred.

- **The API-error badge is claude-only.** `WireSession.apiError` is agent-agnostic, but only
  `ClaudeSession.events(inObject:)` ever raises it. Codex's failure shape needs its own probe
  against a current `codex app-server`; a claim about an older version is not evidence.

- **No notification when a session dies on an API error.** Deliberately deferred. A capacity
  blip kills many sessions at once, so this edge needs its own suppression design in
  `SessionNotificationPolicy` rather than riding the existing idle/waiting rules.

- **No project-header rollup for the API-error badge.** `SessionActivity.summaryRank` ranks
  activities and this is not one, so a collapsed project whose child died still shows that
  child's activity.

- **`FleetEventTag.apiErrorChanged` is not backward-degradable for an older phone.** The
  `WireSession.apiError` FIELD degrades cleanly — `decodeIfPresent` on an absent key is "no
  badge", not an error, and that half is real and tested. The new `FleetEvent` case is a
  different thing: `FleetEventTag`'s decoder is a raw-value `Codable` enum, so a phone built
  before this feature throws decoding a tag it does not recognise, and that throw propagates
  out of `FleetEvent.init(from:)` and `ServerFrame.init(from:)`. `FleetClient`'s `onUndecodable`
  salvage only rescues frames with `t == "ask"`, so the socket is torn down; the phone
  reconnects at the same `lastSeq`, `FleetReplicator.resume(from:)` replays the same event off
  the ring, and it throws again — a reconnect flap that only stops once the event ages past the
  ring floor and a resnapshot takes over. `planGateChanged` and `promptExpired` shipped with the
  identical exposure, so this is a third instance of a pre-existing repo-wide gap rather than
  something this feature introduced, and it only bites when the phone build is older than the
  Mac's — the ordinary direction of skew during a staged rollout, not the common case day to
  day.

## Hook-fed composer state (2026-09-19)

- **`events.ndjson` grows without bound, and faster than "log file" suggests.** Nothing ever
  removes or rotates it. Launch-time truncation was considered and rejected on its merits
  (ledger Ruling E): a shrink under a concurrently-running second instance would make that
  instance's `HookEventWatcher` resume at the new end and miss everything in between, so
  truncation trades a disk-space problem for a correctness one. What the ruling underweighted
  is the rate. `PreToolUse` and `PostToolUse` payloads carry `tool_input` and `tool_response`
  verbatim, and `record.sh` writes the whole payload, so a busy fleet writes **megabytes per
  minute** — not the kilobytes-per-day a lifecycle log sounds like. Two candidate answers, both
  deferred: size-triggered rotation (the watcher's `TailTruncationPolicy.resumeAtEnd` already
  survives a shrink correctly, so this is mostly a question of who rotates and when), or
  trimming the payload in `record.sh` to the two fields the decoder actually reads
  (`session_id`, `hook_event_name`) — cheaper, and it shrinks the line rather than the file.
  Trimming at the writer is probably the better first move: `HookEventRecord.decode` reads
  nothing else, and it also removes tool arguments and tool output from a file that currently
  accumulates them in plain text.

- **`HookEventWatcher.drain()` decodes that delta synchronously on `@MainActor`, every
  500 ms.** Harmless at today's line sizes and directly compounded by the entry above: the
  bigger the per-tick delta, the more JSON parsing happens on the main thread. Trimming the
  payload addresses both at once.

- **A never-anchored claude tab sits at `.unknown` until its next turn, not "one beat".**
  `applyRegistry` demotes readiness whenever no status-registry row names a tab's conversation,
  and it clears the watcher's fold for that session — but not the tail offset, so the tab is
  re-reported only when the agent emits its *next* hook event. For a freshly booted, genuinely
  idle claude that is its first prompt. Accepted: the level trigger's protection against a
  stale `.live` is worth strictly more than the boot window it costs.

  **What is NOT safe about it, stated plainly, because an earlier version of this entry said
  the opposite.** "The tab falls back to the legacy screen grammar" is a fallback, not a
  protection. `hasComposerBox` accepts the composer a dead claude leaves on screen (pty probe,
  2026-09-21), so `.unknown` refuses nothing that matters. A death is caught by demoting to
  `.absent` instead — but that needs an anchor to probe, so any tab that reaches a corpse
  without one is still decided by the screen, and typing a rename there runs it as a shell
  command.

  **The reachable path is a Flight Deck restart, not an exotic claude.** An earlier draft of
  this entry argued the residual away as "an agent that drew its input box and yet never wrote
  the file it writes at startup" — implausible, and beside the point, because the tab does not
  have to be the one that lost the race. `composerReadinessByTab` and `anchors` are both
  in-memory only, and detach persistence (`SessionDaemon`; see `SessionStore.reapAll`'s note on
  never terminating the daemon) is built precisely so a session survives an app quit and the
  next launch reattaches to it. So: claude dies at some point, Flight Deck is quit and
  relaunched, and the reattached tab comes up with no anchor, no readiness and a corpse on
  screen. No registry row will ever name it, no hook event is coming, and it reads `.unknown`
  for the life of the process. The agent *did* write its status file; Flight Deck forgot it
  across the restart.

  **Not a regression, and deliberately not fixed in that round.** The behaviour is identical to
  what shipped before the `.absent` work, and the same-run repro that was filed (quit with
  Ctrl-D, rename from the sidebar) really is fixed. The fix for this one is the second liveness
  source already proposed below: a live `claude` under the tab's own surface
  (`processRegistry.process(for:)` + `processInspector.descendants(of:)`) answers "is anything
  alive here" without an anchor, without a hook feed and without anything surviving a relaunch,
  which is exactly what this path lacks. A wider `.absent` cannot reach it — there is no
  evidence in the store to widen.

- **Multi-account amplification of that same reset.** While only one account has scanned,
  tabs belonging to an account whose watcher has not yet run resolve `anchor == nil` and reset
  on each such tick. Bounded by the second account's first scan, and in the safe direction.

- **Live in-app verification is a hand-off checklist, not a test** (ledger Ruling L). The
  end-to-end path — phone prompt idle and mid-turn, open a permission prompt and **deny** it,
  then inject; sidebar rename — needs a GUI session and a paired phone. The deny-then-inject
  case is the one that must not be skipped: it is the deadlock the design was reworked around,
  and the only thing standing behind it is the dialog veto's fail-open contract.

- **`closeSession`'s route through `resetComposerReadiness` is untested**, and two tabs sharing
  a `pinnedConversationID` make closing one `forget` the conversation the survivor still holds.
  The cost is one redundant re-emission of an already-correct value.

- **The codex exemption from liveness demotion rests on a measured-but-unpinned teardown
  behaviour, not a fixture.** `injectableReadiness` and `applyRegistry` (`SessionStore.swift`)
  both now justify skipping the demotion with a real finding: a `codex` quit under a pty
  (Ctrl-C/Ctrl-D, codex-cli 0.155.1, 2026-09-21) REMOVES its `›` marker on exit, so
  `CodexTextChannel.composer(_:)` finds nothing and `submit`/`submitRename` refuse on their own
  opening guard — unlike claude, which leaves its `❯` box drawn and needed the P0 fix. That
  replaces an earlier, false justification ("a shell draws neither codex's `›` marker nor its
  footer") which was true of a shell and beside the point — the failure mode is a corpse, not a
  shell. No fixture captures a dead-codex screen (`Tests/FlightDeckTests/Fixtures/Codex/` has
  none), so `CodexTextChannel.composer(_:) == nil` on a dead codex is asserted nowhere; the
  existing codex bare-shell tests exercise a live-but-elsewhere screen, not this one. Capturing
  one (verbatim, with `.captured.provenance.json` provenance, per the convention
  `Tests/FlightDeckTests/Fixtures/Claude/dialogs.captured.provenance.json` documents) and
  asserting against it would close this; deferred as disproportionate to a docs-only follow-up
  pass. It is also, like the rest of this section, a property of the CLI's own teardown that
  could change under a future codex release with no signal here — see
  `docs/codex-behaviour-claims-expire` in memory for the general pattern.

- **The `.absent` strand: a plain `claude` typed into the shell after Ctrl-D never recovers.**
  Both recovery paths in `demoteComposerReadiness` key off the tab's `pinnedConversationID`: a
  resumed claude reuses that session id, so its `SessionStart` clears the mark, and a fresh
  registry row for that same conversation frees it too. A user who instead types plain `claude`
  (no `--resume`) gets a brand-new session id — no registry row ever matches the tab's pinned
  conversation again, no hook event routes to it, and the tab stays `.absent` for the life of
  that process. Blast radius is small: `composerReadiness(for:)` has exactly one consumer, so
  only a `/rename` typed *into the conversation* is lost — the sidebar title still updates and
  persists (it does not go through the gate). Cheap mitigation, not implemented: a tab whose
  surface has a live claude descendant is provably not the dead one `.absent` was written for —
  `processRegistry.process(for:)` + `processInspector.descendants(of:)` already answer exactly
  that question two screens away, in `pinResolutions` — so "a live claude process under this
  tab's surface" could free `.absent` on its own, independent of `pinnedConversationID`, closing
  both this residual and the never-anchored one above in one mechanism.

- **The status file is a single point of failure for this whole safety gate.**
  `~/.claude/sessions/<pid>.json` (`ClaudeStatusFile.swift:3-9`) is Claude Code's own
  undocumented, unversioned file — nothing in this design owns its format or its continued
  existence. If a future claude release stops writing it, `SessionStatusWatcher` never anchors
  any tab, every demotion in `demoteComposerReadiness` lands in the weak `.unknown` branch (no
  `priorAnchor` to prove dead), and this P0 returns in full — a dead claude's composer stays on
  screen and `hasComposerBox` accepts it — while the hook feed keeps reporting `.live` right up
  to the moment of death, same as before this fix. This is the strongest argument for the
  `.absent` strand's mitigation above: a surface-process check does not depend on Claude Code
  choosing to keep writing a file Flight Deck has no contract for.

- **`./scripts/test-unit.sh` fails before running a single test when launched from inside a
  Flight Deck that was itself started by a UI-test runner.** The app inherits the runner's
  `XCTestSessionIdentifier` / `XCTestBundleInjectPath` / related env vars and passes them down
  the pty; `xctest` sees `XCTestSessionIdentifier`, tries to attach to an IDE session that died
  long ago, and exits with "Failed to establish connection to the IDE: Timed out while
  preparing IDE session." — after the build has already succeeded, so it reads like a harness
  crash rather than a polluted environment. Reproduces in the foreground; backgrounding is not
  the cause. Workaround: strip the vars before invoking `xctest`
  (`env -u XCTestSessionIdentifier -u XCTestConfigurationFilePath -u XCTestBundlePath -u
  XCTestBundleInjectPath -u XCODE_TEST_PLAN_NAME -u XCODE_SCHEME_NAME -u
  __XPC_DYLD_FRAMEWORK_PATH`). Folding that into `scripts/test-unit.sh` itself is a separate,
  deliberate change — not done here.
## From multi-agent ⌘K search (2026-09-21)

Full design: [superpowers/specs/2026-09-21-multi-agent-search-design.md](superpowers/specs/2026-09-21-multi-agent-search-design.md).
Plan: [superpowers/plans/2026-09-21-multi-agent-search.md](superpowers/plans/2026-09-21-multi-agent-search.md).

- **Flight Deck pollutes codex's own naming source, and `CodexSearchCorpus` has to work around
  it rather than fix it.** Every tab Flight Deck creates pushes its default title —
  `session N` — to codex via `thread/name/set`, so `session_index.jsonl` ends up full of
  names this app wrote, not the user. That is why codex naming needs a placeholder rule at
  all (`^session \d+$`, preferring a real first user message over it): without it, claude's
  "a rename always beats the first user message" rule would port straight across and ⌘K rows
  would read `session 206` for a conversation that actually opens on something else entirely.
  Fixing it at the source — not pushing a placeholder title to codex in the first place —
  would let claude's simpler rule port cleanly, but it is a change to `SessionStore`'s rename
  path, not to search, and the roughly 30 placeholders already written to existing users'
  `session_index.jsonl` files would still need the fallback regardless. Left as a rename-path
  fix for its own branch.

- **`~/.codex/archived_sessions/` is deliberately not searched.** `thread/archive` moves a
  rollout there as part of releasing it (`CodexAdapter` documents the RPC), so resurrecting an
  archived thread in ⌘K results would undo an explicit put-away rather than surface something
  merely old. If this ever needs revisiting, it is a product decision (should an archived
  thread be findable at all?), not a bug.

- **No per-agent ⌘K filter (`agent:codex …`).** YAGNI until a mixed result list is actually
  confusing in practice — codex is one additional agent today, and the `.automated` ranking
  tier already keeps its noisiest source (`codex exec`) out of the way. Add the filter syntax
  only once a real session shows it is needed, not ahead of that.

- **`PhoneSearchCandidates.build` never passes the real `agent` for a `.session` candidate**,
  so every open tab the phone contributes to name matching reads as `.claude` regardless of
  which agent it actually runs — unlike the desk's `SearchCandidates.build`, which does carry
  the real value. Inert today: `search.open` sends only a conversation id and a project path
  over the wire, so nothing on either end reads a `.session` candidate's `agent` field. Still
  a wrong value sitting in a field, and worth fixing before anything ever does read it.

- **`CodexRuntime.attach`'s live-ingest `TranscriptRef` carries the built-in codex home
  (`AgentID.codex.builtInHome`) as `accountHome`, not the tab's actual account**, even though
  discovery is per-account. Inert because `SearchIndex.ingest` never reads `accountHome` off
  a ref — it exists for codex naming during the backfill walk, which live ingest does not do
  — and the same shortcut mirrors what `ClaudeRuntime.attach` already does. Worth widening
  only if `accountHome` ever grows a second live-ingest reader.

- **The agent glyph draws only on a `.conversation` row, never on `.session` or `.project`,
  and that scope is load-bearing rather than incidental.** A `.session` row is a tab already
  open in the sidebar (or the phone's fleet list) and identifiable there the way it always
  has been, so a glyph would be redundant on the desk — but on the phone it would also
  currently be **wrong**: the `PhoneSearchCandidates` gap above means every `.session`
  candidate's `agent` reads `.claude` regardless of truth, so drawing a glyph from it would
  assert a false identity instead of adding a redundant true one. A `.project` row's `agent`
  is an unused placeholder value (see `SearchCandidates.build`), never a real one worth
  drawing either. Widening the glyph's scope needs the `PhoneSearchCandidates` fix first, or
  it ships a glyph that lies on exactly the platform it was added for.

## API-error auto-retry (2026-09-22)

Spec: [superpowers/specs/2026-09-21-api-error-auto-retry-design.md](superpowers/specs/2026-09-21-api-error-auto-retry-design.md).
An opt-in loop (**Retry after API errors**, off by default, in Shell & Environment →
Recovery) that nudges an agent whose turn died on a transient API failure back to life on a
backoff ladder, riding the existing `pendingPrompts` queue rather than a second typing path.

- **The Mac shows the attempt number but no live countdown; the phone counts down.**
  `SessionAPIError.label` renders `"… · retrying, attempt 2"` and stops there. The sidebar
  row is a flat `HStack` with no subtitle slot, and `SessionSidebar.swift`'s
  `PhonePresenceBadge` doc comment already states the reason no row here gets a
  `TimelineView`: it would re-render the whole row on a display-linked schedule for state
  that is usually absent. A tooltip is also expected to be the wrong vehicle regardless: the
  standard `NSToolTip`/`.help(_:)` mechanism is not documented to re-read its string while the
  pointer just sits there, so a per-second countdown would likely need to be dismissed and
  re-shown to update — worse than a static attempt number. Not verified against AppKit source
  or measured on this build; recorded as expected platform behavior, not a confirmed fact.
  Deliberate non-fix regardless, since the flat `HStack` and the `TimelineView` rejection above
  hold on their own; the
  phone's banner (`SessionTimelineScreen`) is the one place this actually counts down,
  because it can afford a `TimelineView` scoped to a banner that is usually absent.

- **`SessionAPIError.kind` is now matched against an allowlist for policy, while still being
  rendered verbatim for display.** `CodexTurnRecovery.transientKinds` (`rate_limit_exceeded`,
  `server_overloaded`, `internal_server_error`, `response_too_many_failed_attempts`,
  `response_stream_connection_failed`, `response_stream_disconnected`,
  `http_connection_failed`) is the one place that vocabulary is judged; `kind` itself stays
  free text everywhere else, per the field's own "never matched against an enum" rule for
  *display*. The consequence: codex's error vocabulary is not ours and will grow, so a
  codex-cli upgrade can add a new transient kind the allowlist does not know about, and the
  loop will silently not retry it — fail-closed is the deliberate trade (a denylist would
  fail open onto a terminal error being retried forever instead). The allowlist was derived
  by driving a real codex TUI against a local upstream returning 429 (codex-cli 0.155.1,
  2026-09-21); only `response_too_many_failed_attempts` was captured verbatim that way (the
  fixture is `Tests/FlightDeckTests/CodexRolloutMapperTests.swift`), and the rest were
  converted from the app-server's camelCase schema to the rollout's snake_case by rule, not
  observed. Re-probing the same way — a real `codex` TUI against an upstream that returns
  each status the allowlist claims to cover, reading the resulting `task_complete.error`
  record straight off the rollout `.jsonl` — is how this gets checked after an upgrade; the
  probe rig itself was scratchpad-only and was never added to the repo, so there is no script
  to just re-run.

- **Task 5 fixed a pre-existing starvation that was never filed as a bug.** `applyRegistry`
  is driven only by `SessionStatusWatcher`, which exists only for agents answering
  `hasStatusRegistry` — true for claude, false for codex (`SessionStore.startStatusWatching`,
  `startWatching(tabID:)`). So on a codex-only fleet, `flushPendingPrompts` (phone-sent
  prompts and the auto-resume nudge) and `flushPendingRenames` never flushed at all — nothing
  drove them. This auto-retry feature would have reproduced the identical gap for its own
  nudge on day one had it been built on the same tick, so the fix landed underneath it
  instead: the registry-tick `defer` body was pulled into `maintenanceTick()`
  (`flushPendingRenames`, `flushPendingPrompts`, `flushPromptQueue`, plus the new
  `flushRetryBackoff`), called both from `applyRegistry`'s `defer` (unchanged for claude) and
  from a new registration on the shared `WatchClock`, which ticks every agent regardless of
  status registry. All four flushes are idempotent and deadline-guarded and `inject` is
  re-entrancy-guarded, so the two call sites landing in the same instant is safe.

- **A per-tab "stop retrying" cannot work by clearing `retryAttempt`, and now does not.**
  `flushRetryBackoff`'s "not armed, preference on" branch re-judges any tab whose
  `retryAttempt` is `nil` on every tick it sees one, and re-arms it at `resumedRung` if the
  failure is still transient — so clearing the field is undone on the very next tick, and at
  rung 1 if the episode went too, which makes the typing arrive *sooner*. The suppression
  signal this entry predicted would be needed is `SessionStore.retryInterrupted`, added for
  the interrupt stop below; a future user-facing cancel control should set that rather than
  clear state.

- **Pressing Esc stops the loop on codex, and needs no equivalent on claude.** `turn_aborted`
  now also maps to `AgentEvent.turnAborted`, which strips the tab's schedule, forgets its
  `RetryEpisode` and latches `retryInterrupted` so the re-arm branch above cannot undo it —
  while leaving the error badge standing, because the last turn really did fail. Claude has no
  abort signal to map and needs none: every `"type":"user"` transcript record emits
  `.progressed` (`ClaudeSession.events(inObject:)`), and `.progressed` clears `apiError`
  outright, schedule included — so a claude interrupt stops the loop by clearing it. The latch
  is lifted by a turn that completes with no error, which is the only evidence the outage is
  actually over, and dropped with the tab in `closeSession`. A re-report of the same failure
  does **not** lift it: the user stopped this loop by hand and a repeat of the error they
  stopped it over is not new information. Nor does toggling the preference off and back on:
  nothing in that path touches `retryInterrupted`, so a tab the user interrupted by hand stays
  latched across the cycle and does not resume — a per-tab interrupt outranking the global
  toggle, which is the right precedence, just not the symmetric one the re-arm branch's own
  comment used to claim.

- **The rung advances at queue time, not send time.** `flushRetryBackoff` calls
  `armed(_, attempt: attempt + 1)` in the same pass that queues the `DeferredPrompt` — before
  `flushPendingPrompts` has actually typed anything. So a nudge that `cancelSupersededPrompts`
  drops (the session went busy on its own) or that misses the 120s `resumePromptWindow`
  deadline (`SessionStore.resumePromptWindow`) still spends a rung, even though nothing was
  typed. This is pre-existing shape from the scheduler's first cut, narrowed since by the
  "one nudge in flight per tab" and "already working" guards in the same function; recorded
  rather than fixed, since a rung spent on a no-op nudge just makes the next real one wait
  proportionally longer, never shorter.

- **Two pre-existing test faults were observed while building this feature, in code it never
  touches, and neither was chased — the "isolate, don't loop" rule.** A malloc abort in
  `QuitReapTests`, seen twice across separate runs during this work — a memory fault, not an
  assertion, so it will not present as an ordinary flaky test — and Fleet/Pairing networking
  flakiness (sockets/TLS/async timeouts), seen in 2 of 4 runs across one task. Task 9's own
  two-suite gate run was clean on both suites, first try, with neither fault recurring — see
  the commit that lands alongside this entry for the tail output.

Two smaller things worth recording alongside the above, found reading `CodexEventMapper`
rather than by design:

- An `error` present on a `task_complete` record with `codex_error_info` absent or `{}`
  yields a **kind-less** `SessionAPIError` (`kind: nil`, `isTransient: false`) rather than
  `nil` — the badge still raises, just with no kind to show or retry on. Defensible default
  (a failure with no parseable info is still a failure worth surfacing), currently untested.
- `CodexEventMapper.apiError(fromTurnError:)` reads the single key of a `codex_error_info`
  object with `object.keys.first`. `Dictionary.Keys` has no defined ordering in Swift, so a
  malformed multi-key payload — not in the published schema today, but nothing parses it away
  — would pick a `kind` non-deterministically rather than failing loudly.

## Flight Control setup/enable (2026-09-22) — a known-corrupted repo from before `66fa004`

- **A repo that ran "Enable/Set Up Flight Control" during the window when `FlywheelSetup` appended
  shell lines to `.git/hooks/pre-commit` has a permanently broken `pre-commit` — deliberately
  not auto-repaired.** Before `66fa004`, `installBeadsSyncHook` appended `br sync
  --flush-only` / `git add -A .beads` directly to `pre-commit`, which `am guard install`
  writes as a Python chain-runner (`#!/usr/bin/env python3 ... sys.exit(first_failure)`) —
  appending shell to it is a `SyntaxError` that fails every commit in that repo. `66fa004`
  fixed the *install* path (beads-sync now lives as its own `hooks.d/pre-commit/` script and
  never touches `pre-commit`), but neither it nor anything since detects or repairs a
  `pre-commit` a pre-fix run already corrupted: re-running Enable installs the hooks.d script
  correctly but leaves the bad append in `pre-commit` in place, since nothing in
  `FlywheelSetup`/`FlywheelProjectProbe` reads that file's *contents* looking for the old
  shell lines — only for the guard markers. Known scope: essentially just `~/fw-functest`
  (already hand-repaired), since the buggy code path never shipped anywhere off this branch.
  Manual fix, if another one turns up: remove the appended `br sync --flush-only` / `git add
  -A .beads` lines from the end of `.git/hooks/pre-commit`, leaving the Python chain-runner
  otherwise intact. Document, don't auto-heal, unless this recurs somewhere it can't be
  hand-fixed once.

## From the rename-injection fix wave (2026-09-22)

Whole-branch review of the two fixes that landed `f0399b6` (release the injection mark on
every path, not only when text was sent) and `46c2402` (admit the two-row composer claude
draws right after a submit). No Critical or Important findings; these are the Minor residue,
recorded rather than fixed in this pass.

- **`killedADraft` is a guaranteed false positive on the screen `46c2402` newly admits, and
  the compensating `sendYank()` can paste stale kill-ring content into the user's composer.**
  On `busy-echo-only` the `❯` row holds the echo of the just-submitted prompt, not a draft —
  the input buffer is empty. Proof from the corpus: when a real draft coexists with the echo,
  the capture is `busy-draft-below-echo`, which `InputBar.read` returns as TWO rows, so
  `submit`'s `bar.rows.count == 1` guard refuses it — so at `rows.count == 1` on an echo
  screen, `before` is provably not a draft. Ctrl+U therefore kills nothing, but ~120ms later
  claude has usually scrolled the echo into the transcript, so `after` = "" ≠ `before` →
  `killedADraft = true` → `sendYank()` fires at `ClaudeTextChannel.swift:212` after the
  Return, replaying the PREVIOUS kill — typically the user's own already-submitted draft,
  which reappears in the box.

  Not urgent: the yank is after `sendReturn()`, so it can never submit anything; the rename
  lands correctly; the text is one undo away. And it is NOT a regression from this branch —
  post-`worktree-hook-composer-state` the `.live` arm never consults `hasComposerBox`, so
  echo screens were already admitted there; `46c2402` only extends the exposure to the
  `.unknown` arm.

- **Claude's rename leg retires its pending entry without the identity re-check codex's leg
  has.** `SessionStore.swift:5768`'s `onSent: { self?.pendingRenames[id] = nil }` is
  unguarded, whereas `injectRename`'s `onFinished` (`SessionStore.swift:5800`) guards
  `pendingRenames[id] == name`. Safe today: `ClaudeTextChannel.submit` checks `stillWanted()`
  and calls `onFinished(true)` in the same synchronous MainActor block
  (`ClaudeTextChannel.swift:205-213`), so nothing can replace the entry in between. But the
  protocol `f0399b6` wrote now explicitly permits multi-hop settles, and
  `CodexTextChannel.submit` demonstrates the gap — it checks `stillWanted()` at
  `CodexTextChannel.swift:179` and calls `onFinished(true)` at `CodexTextChannel.swift:195`
  across a real 120ms hop. If claude's channel ever grows a second hop, the unguarded clear
  silently drops a replacement rename. One-line hardening when someone touches that path.

- **`CodexTextChannel.submitRename`'s cancellation path still loses the user's draft, and the
  justification in `restoreDraft`'s doc comment (`CodexTextChannel.swift:235-266`) is weaker
  than it reads.** That exit is at the SAME point in the drive as `submit`'s superseded exit
  that `f0399b6` just fixed: the kill has gone out and the post-kill screen is still readable.
  `restoreDraft`'s doc argues that by the time "either exit path calls it" the screen has
  moved through `/rename` — true of the two exits that DO call `restoreDraft`, false of this
  one, which simply never reads. So the fix is three lines (read
  `composer(injector)?.content`, same confirmed-change condition as
  `CodexTextChannel.swift:178`), not the structural impossibility the paragraph implies.

  Parity note worth recording: for the same user-facing gesture — a sidebar rename preserving
  an in-progress draft — claude restores and codex does not, because they travel different
  channels. AGENTS.md's "a feature shipped for one adapter is a defect" rule applies, but the
  window is two renames in flight inside ~600ms, and it predates this branch.

## From Flight Control Observe Level 1 (2026-09-25)

- **There is no UI path to disable Flight Control once enabled.** `ProjectSettings.flywheelEnabled`
  is only ever set `true` — `ProjectHeaderRow.swift:161`'s enabled-state menu item is
  `Button("Flight Control coordination enabled") {}.disabled(true)`, a genuinely inert label, not a
  toggle. `FlywheelObserveService.disable(project:)` (`FlywheelObserveService.swift:72-77`)
  is fully implemented and unit-tested but has zero call sites in `Sources/`. No runtime
  defect follows from this — a project can only ever be enabled, and enabled works — but it
  means `docs/FLYWHEEL-OBSERVE-CHECKLIST.md` step 8 (disable → drawer gone, no watcher) is
  not yet testable. Surfacing a real disable control is the follow-up.
- **`SessionStore.jumpToObserveRootCause()` is a live no-op today.** Its root-cause
  computation is correct and exercises the same `DependencyGraphLayout` the DAG overlay
  draws from (`SessionStore.swift:2395-2414`), but `FlywheelWatcher.repollNow()` hardcodes
  `depEdges: nil` in every `FlywheelSnapshot` it produces (`FlywheelWatcher.swift:145-149`,
  see the transport/lane note above), so `DependencyGraphLayout.layout`'s `rootCauseID`
  has no edges to reason over and is `nil` for every projection assembled from real reads —
  `jumpToObserveRootCause()` guards on exactly that and returns without moving selection.
  The wiring (drawer button → store method → layout → jump) is correct and covered by unit
  tests against hand-built projections; only the live `depEdges` data source is absent. See
  `task-12-fix-1-report.md`.
- **`ObserveDrawer` never threads `FlywheelProjection.lanesUnavailable` through to
  `ObserveLaneModel`.** `FlywheelProjection.project(...)` does compute a real
  `lanesUnavailable` set from which snapshot lanes came back nil
  (`FlywheelProjection.swift:54-74`), and `ObserveLaneModel.row(...)` does know how to render
  a degraded lane as the literal text "unavailable" (`ObserveDrawer.swift:59-65`) — but
  `ObserveDrawer.expanded(_:)` calls `ObserveLaneModel.lanes(for: agent, unavailable: [])`
  with a hardcoded empty set (`ObserveDrawer.swift:150`), so that path is exercised only at
  the unit-test level (`ObserveLaneModelTests`), never through the live view. Concretely:
  because `reservations`/`depEdges`/`events` are also permanent nil-stubs at the read-command
  layer (next item), Files/Dependency/Activity always render their own "nothing here" copy
  ("no held or waited-on files", "no blocking dependency", "no recent activity") rather than
  "unavailable" — cosmetically different from what the design intended, not a data-loss bug.
  Flagged for this exact follow-up in `.superpowers/sdd/2026-09-24-flywheel-observe/
  progress.md`'s Task 10 ruling; one-line fix (pass `projection.lanesUnavailable` through)
  once there's a projection worth degrading against.
- **`FlywheelReadCommands.reservations`/`.depEdges`/`.events` are permanent nil-stubs**, not
  conditional on `am`/`br` being installed or reachable — they never attempt a subprocess
  call at all (`FlywheelReadCommands.swift:79-102`). Task 1's live probe confirmed each
  command's argv and envelope shape but never captured a positive-path row (an empty
  `all_active`, a `dep list` that needs a real issue id, an empty `events` array), so the
  per-row/per-event Decodable shapes are unconfirmed and were deliberately left un-guessed
  rather than risk silently decoding nothing — or garbage — forever. `FlywheelWatcher`
  therefore only ever shells out to `am agents list` and `br list --status in_progress`
  ("two shell-outs, not five," `FlywheelWatcher.swift:126-130`). This is the root cause of
  both nil-stub items above and is the one lane-availability fact
  `docs/FLYWHEEL-OBSERVE-CHECKLIST.md` step 2 calls out directly.
- **All three `FlywheelNotifier` triggers (persistent block, stalled-holder collision,
  dependency cycle) are inert against live data in Level 1.** Each is fully wired and
  unit-tested against hand-built projections (`FlywheelNotifierTests`), but nothing live can
  satisfy any of them today. The block trigger (`evaluateBlocks`, `FlywheelNotifier.swift:70-
  84`) fires on `agent.status == .blocked`, which `FlywheelProjection.project(...)` derives
  solely from `bead.status == "blocked"` (`FlywheelProjection.swift:109`) — but the only live
  bead read is `br list --status in_progress` (`FlywheelWatcher.swift:126-130`), which by
  definition never returns a blocked bead, so no live projection can ever carry a `.blocked`
  agent. The stalled-holder collision trigger (`evaluateCollisions`) needs the
  `reservations` lane, and the dependency-cycle trigger (`evaluateDependencyCycle`) needs the
  `depEdges` lane — both permanent nil-stubs per the item above. `br blocked` was confirmed
  available during the Task 1 probe
  (`docs/superpowers/notes/2026-09-24-observe-command-shapes.md`, fixture
  `Tests/FlightDeckTests/Flywheel/Observe/Fixtures/br-blocked.json`) but is deliberately not
  wired: its `BlockedIssue` schema carries `blocked_by[]` but no `assignee`, so lighting up
  the block lane is a design task (a join to figure out which agent a blocked bead belongs
  to), not a one-liner — that fixture currently has no consumer. All three triggers are
  ready to light up, unit-test-verified, the moment a future level wires the lanes/join they
  need.
- **`DependencyGraphLayout`'s longest-path ranking can over-rank a node reachable only
  through an out-of-set intermediate.** A chain A(in-set) → X(not in the polled bead/edge
  set) → C(in-set) still contributes `rank[X] = rank[A] + 1` during relaxation even though X
  is never placed as a node, which can push C's rank deeper than a same-length in-set-only
  path would. Parked during the Task 4 layout work as a real but narrow edge case (needs an
  edge into a bead outside the current poll's known set, which the live nil-stub `depEdges`
  makes unreachable today regardless) — noted here per
  `.superpowers/sdd/2026-09-24-flywheel-observe/progress.md`'s flag for this task.
- **`DAGCamera` has two unguarded degenerate-input cases**, both latent rather than currently
  reachable given the same `depEdges` nil-stub: `graphPoint(fromViewPoint:viewport:)` calls
  `.inverted()` on the view→graph transform with no `scale == 0` guard
  (`DAGCamera.swift:26-28`) — Core Graphics returns the original (non-inverted) transform
  rather than crashing on a singular matrix, so the failure mode is a silently wrong
  hit-test, not a crash; and `fitting(_:viewport:padding:)` divides `viewport` by `rect`'s
  width/height with no zero guard (`DAGCamera.swift:38-42`), so a bounds rect that is zero on
  both axes would produce an infinite-scale camera. In the current `DependencyDAGOverlay`,
  the minimap's bounds always include each node's non-zero `nodeSize`, so this doesn't fire
  from the shipped drawing path today — but `SessionStore.jumpToObserveRootCause()` builds a
  layout with `nodeSize: .zero, spacing: .zero` (geometry is irrelevant to that call's
  `rootCauseID`-only use), so any future code path that fed *that* layout's node positions
  into a `DAGCamera.fitting` call would hit it. Parked per
  `.superpowers/sdd/2026-09-24-flywheel-observe/progress.md`'s flag for this task, alongside
  the Task 4 rank-leakage item above.
## What actually sent CSI-u at a bare shell (2026-09-25)

**Supersedes the entry written here on 2026-09-24**, which asked whether Claude's composer acts
on `ESC[117;5u`. That entry has been withdrawn, not left in place — its own claim was wrong, so
it is not reproduced here; docs/HANDOFF-agent-surface-findings.md §4 keeps the record of what it
said and why. The question it asked is moot regardless: `TextInjecting.sendControl` does not send
that sequence.

`sendControl` passes an explicit control byte via `text:`, and **that byte is what reaches the
terminal, under the kitty keyboard protocol as well as the legacy encoding.** Traced link by link
through ghostty's encoder: Flight Deck never sets `unshiftedCodepoint` (it defaults to 0 and
nothing in `Sources/` assigns it), ghostty's kitty table holds no plain letters, and
`key_encode.zig:132` synthesizes a fallback entry only when `unshifted_codepoint > 0` — so no
entry is found and the `:217` fallback writes `event.utf8` verbatim. `KittySequence` is built
only *after* that point. Full derivation, and the correction of the earlier wrong claim, in
docs/HANDOFF-agent-surface-findings.md §4.

**The open question is now an observation nothing explains.** Live test #3 left the literal text
`;5u;5u/rename Rename 3` at a zsh prompt after claude was killed in that tab — two CSI-u tails,
matching Ctrl-E then Ctrl-U. The traced path cannot emit them, and `git log -S` shows `text: byte`
entered in 6c2a39d and never changed, so the code under test did carry it. Either some other path
sent those keys, or an assumption in the trace is wrong. **Unexplained.**

**Two things must not be inferred from this.**

- **The draft-rename bug has no identified cause.** A rename into a composer holding a draft
  submits the draft; the "Ctrl-U leaves as CSI-u so the box never clears" hypothesis is dead, and
  nothing has replaced it.
- The byte's survival is **an unguarded invariant, not a guarantee.** Any caller that supplies an
  unshifted codepoint — as the real `NSEvent` path derives for a human keypress — flips the same
  call to `ESC[117;5u` and discards the byte. Nothing in the suite can catch that: no test stands
  on a real surface.

**Binding on any probe that settles this.** It **must record which keyboard mode was active and
which code path actually sent the keys, and must refuse to report a verdict if it cannot
establish both.** This is not boilerplate. This project has now produced four wrong conclusions
from probes that asserted an outcome for a configuration they never established — including one
where a bare pty left claude in *legacy* mode, so the probe exercised an encoder ghostty never
uses in production, and including the 2026-09-24 correction above (**withdrawn**, not restored —
see docs/HANDOFF-agent-surface-findings.md §4, which keeps the record). A probe that cannot name
its configuration must fail, not conclude. See docs/HANDOFF-agent-surface-findings.md §7.

## Claude has no live coverage in the adapter suite (2026-09-25)

This branch's stated top priority was `claude.openPromptReader` — "the one row that should have
caught 2.1.281 and didn't" — so it was rewritten to drive a live `claude` instead of the frozen
`question-single.captured.jsonl` fixture (claude 2.1.241) it used to parse. The rewrite works,
but its verdict moved `ok` -> **`error`**: a sandboxed claude cannot authenticate. Claude Code
keys its keychain credential to a hash of `CLAUDE_CONFIG_DIR` — the default home uses the service
`Claude Code-credentials`, any other config dir uses `Claude Code-credentials-<hash>` — and
`AgentSandbox` hands every run a fresh temp home whose hash has no entry, so the sandboxed session
always comes up "Not logged in", regardless of what `.claude.json` was copied in. Unblocking it
means extracting the user's real OAuth token out of the login keychain — a security-sensitive act,
escalated rather than performed here.

`claude.escapeDeniesPermission`, the other row this branch added, needs the same thing (a real
approval dialog raised in a live, authenticated claude pty) and hits the identical guard. So
**claude has no live coverage in this suite today** — both of its live-turn rows fail closed on
sandbox auth rather than measuring anything — and a `--tier full` run against the committed
baseline exits `3` (harness failure) on that account.

Stated plainly rather than buried: the plan's own top priority is **not delivered.**
`claude.openPromptReader` still cannot catch a 2.1.281-class change; the honest gap it can close
is refusing to report a false `ok` the way the frozen fixture did. That is a real improvement over
a green fixture that measures nothing live, but it is not the fix, and exit code `6` (version
drift, see `scripts/adapterprobe/README.md`) is the compensating control that currently stands in
for it — a version bump gets caught, a same-version behaviour change on claude still would not.

Also unproven: **all three** new full-tier rows have never once run to completion against a live
agent. The two claude rows (`claude.openPromptReader`'s live rewrite,
`claude.escapeDeniesPermission`) stop at the auth guard above.
`codex.codexPasteDetectsSameBurstReturn` is not blocked by auth but has simply never been run —
`baseline.json` was last written before this branch and holds no cell for it, so no comment may
cite it as evidence yet. `baseline.json` is deliberately not refreshed against this branch; see
`scripts/adapterprobe/README.md`'s baseline note for the resulting diff.

**Two premises inside the codex paste row are untested, and both fail SAFE — to `error`, never to
a wrong verdict — which is also why its expected first live result is `error` rather than `ok`.**
(1) It establishes "typed" by looking for the marker in `term.display()`, which assumes codex
renders a detected paste literally rather than as a `[Pasted N chars]` placeholder; no codex
fixture captures a pasted composer, so this is unverified. (2) It reads the rollout path `prepare`
returned, which requires `codex resume <id>` to append to that same file — and this suite already
records `codex.resumeCommand` as **broken** (history not reattached). Whoever runs `--tier full`
first should expect to debug the row before trusting a verdict from it, and should read an `error`
here as "the row could not establish its configuration", which is what it is designed to say.

## adapterprobe: two harness gaps found while wiring the drift gate (2026-09-25)

Both found incidentally during the durable-control-surface work, both verified against the code
at `d85a40f`, and both are pre-existing rather than introduced by it.

**1. `seed_one_turn` never confirms a model turn completed, so no claude row has ever exercised
one.** `run.py:333-349` types a marker, waits for **its own echo** (`term.wait([seeded_marker])` —
which matches the instant the typed line is echoed, regardless of whether the model ever answers),
then dwells `pump(20)` and tears the pty down. Its docstring is candid that it does not depend on
the model replying. So a row that asks for "prior history to attach to" can proceed against a
transcript holding a user line and no assistant turn. This is the *deeper* reason the
`openPromptReader` row sat green through claude 2.1.281 — the frozen fixture was the visible half;
the other half is that the suite's claude arms never completed a live turn at all. Fixing it means
waiting on something only a real reply produces, which costs tokens, so it is a `--tier full`
concern and wants a positive control of its own (see the codex paste row for the shape).

**2. `ANTHROPIC_BASE_URL` leaks into the sandboxed agent.** `sandbox.py:24-29`'s
`_CLAUDE_SESSION_MARKERS` strips the `CLAUDE_CODE_*` family so a probe running *inside* a Claude
Code session does not inherit transcript-disabling state — a good guard — but it does not strip
`ANTHROPIC_BASE_URL`. That variable is set in this machine's environment
(`http://localhost:8787`), so a sandboxed `claude` points at a local inference gateway rather than
the real API, and every live claude row silently measures whatever that gateway does. Add it to the
strip list. Two consequences worth separating: it is a **sandbox-hygiene bug** regardless, and it
independently answers spike B7 in the control-surface plan, which recorded the proxy route as
"unresolved, needs execution" — the base URL *is* honoured and a gateway is already running, so a
proxy tier would be far cheaper than the plan assumed. That does not make the proxy a good idea
(it is observation, never control, and blind to everything client-side); it just removes the
feasibility unknown.

## Phone log fetches block the phone's main thread (2026-09-26)

- **`PhoneLog.entries` enumerates `OSLogStore` on the main actor, and on a real device that is
  slow enough to miss the Mac's deadline and freeze the phone.** `FleetModel`'s
  `connector.onPhoneRequest` handler wraps the whole answer in `MainActor.assumeIsolated`, so
  the store read — `getEntries` and the walk over its results — runs on the UI thread. Seen
  while diagnosing the keyboard-lift regression on an iPhone 15 Pro (iOS 18.3.1): fetches via
  `scripts/answer-trigger.sh logs` repeatedly came back `timed_out`, i.e. past
  `FleetSocketServer.askDeadline`'s 10 s, even for a 120 s window; and a burst of ~8 fetches
  froze the phone's UI while they ran. The deadline's own doc comment sizes 10 s against "a
  phone reading its own `OSLogStore`", which this contradicts. Not fixed with that work. The
  suggested direction is to run the store read off the main actor (a detached task or a
  utility queue) and hop back only to log the served line and call `reply` — the handler's
  `assumeIsolated` is there for the `FleetModel` state it touches, not for the read itself, and
  `PhoneLog.entries` touches none. Worth confirming before relying on it: whether a single
  unloaded fetch alone exceeds 10 s, or only fetches that queue behind each other on the main
  thread, which decides whether `askDeadline` needs raising too.

## From Flight Control intake, phases 1–3 (2026-09-26)

- **In-process triage and release are lost on quit.** `IntakeService` runs triage and release
  as an in-process `Task`, tracked only in its own `tasks: [UUID: Task<Void, Never>]`
  dictionary — if Flight Deck quits mid-turn, the `Task` is simply gone, and the intake is left
  `.interrupted` at the next launch for the human to Retry. Shaping rounds no longer have this
  problem: they run in the detached `flightdeck intake run <id>` runner (see ARCHITECTURE,
  "Planning rounds"), which survives an FD quit. Triage and release could move onto the same
  runner; nothing has needed it yet, since both are single short turns.
- **`br update` has no `--if-version` precondition.** Release re-reads and rechecks every
  bead an op touches (`DriftClassifier`) right before writing it, but there is still a window
  of real milliseconds between that recheck and the write where another actor could get in —
  FD has no way to make the write itself conditional on the state it just observed. Today's
  mitigation is the recheck itself: a mismatch stops the release right there, before that
  bead's write, and leaves the intake `.partiallyReleased` with the mismatch as its
  `ReleaseRecord.error` — it never applies over the change. An upstream `br update --if-version <n>` (or similar optimistic-lock
  primitive) would close the window instead of narrowing it; filed as a `br` feature request,
  not something FD can fix on its own side.
- **No Beads tab, no graph review UI yet.** The release review sheet (`ReleaseReviewView`)
  shows drift and lets you confirm or drop each drifted op, but there is no dedicated place to browse
  the bead graph itself, see an intake's change set laid over it, or navigate from a bead to
  the intake that touched it. Spec §8.3–8.4 sketches this and §14 phases it as step 4, after
  phases 1–3 this plan covers — expected, not a gap in this work.
- **A drifted op cannot be re-triaged.** Confirm (release against the bead as it is now) and
  Drop are the only answers the review offers to drift. Sending just the drifted ops back to
  the triage agent against the live graph — so it can re-derive the edit rather than the human
  accepting or discarding it wholesale — is deferred; today the nearest thing is discarding the
  intake and capturing the intent again.
- **A partial release cannot be re-released.** `.partiallyReleased` records how many plan
  steps applied before a `br` command failed or a recheck refused (`ReleaseRecord.appliedSteps`,
  `idMap`, `error`), and the intake's detail pane shows that record — but there is no review of
  the remainder, and nothing in `IntakeService` drives it back through `release(_:)` a second
  time. Today the human's only path forward from a partial release is manual: check
  `br list`/`br graph` for what actually landed, finish by hand, then Dismiss the intake (the one
  action that stops it counting toward the project's "needs you" badge). Re-release-the-remainder is straightforward
  given `ApplyPlanner` already knows how to skip ops (`skipping:`), but no code path calls it
  that way yet.
- **Claude triage's `br` deny rules match the verb in first position only.** `HarnessCommand`
  passes `--permission-mode dontAsk` and denies every `br` write verb as `Bash(br <verb> *)`, which
  beats any allow rule a project's `.claude/settings.json` adds. A command that puts a global flag
  before the verb (`br --actor x create …`) would not match those patterns; it would still need
  an allow rule broad enough to cover it (`Bash(br:*)`). Codex triage is unaffected — its sandbox
  is `read-only` at the OS level. A tighter fix is a `br` wrapper on the triage `PATH` that refuses
  write verbs wherever they appear.
- **Retry discards the Q&A that got the intake there.** `IntakeService.retry(_:)` clears
  `exchanges` and re-runs triage from `.initial` on the unchanged intent text — deliberate
  (its own comment: "the earlier Q&A goes with it — the agent will ask again if it still
  matters"), since the old session's context is exactly what may have gone wrong, and a
  fresh triage against a re-read graph is the only safe base after an interrupted release.
  Noted here rather than as a bug because it is a real cost to the human when a triage failed
  *after* several rounds of clarifying answers: they answer the same questions again. A
  `retry` that replayed `exchanges` as follow-up turns before failing forward on the current
  question would recover that, at the cost of trusting stale context more than today's design
  wants to.

## From Flight Control intake, the round engine (2026-09-27)

**Next** — designed in the spec, deliberately not in the round-engine plan:

- **Branches and rewind.** The tape is a straight line: there is no ⏮, so a paused or failed
  round can only be retried (⏯/⏭/⏩ rerun the next round from the head), never re-targeted to
  an earlier checkpoint. Spec §6.4's branches — play forward from an earlier checkpoint, keep
  the old line, compare lineages — need a rewind command, a `parent` that can point anywhere
  (`Checkpoint.parent` already exists), and a strip that draws forks.
- **The Beads tab and graph review.** Still unbuilt (see the phase 1–3 entry above). The
  shaping view shows a change set as a list of ops; nothing yet lays it over the graph.
- **Oracle, grok and gemini slots.** `Harness` is `codex | claude` only. Spec §6.2's slot-kind
  interface (`start`/`adopt`/`result`/`cancel`), oracle's browser runner with its
  `challenge`/`tierUnavailable`/`uiChanged` diagnoses, and the unverified grok/gemini adapters
  are all next.
- **Coverage metrics balanced against fidelity — DESIGNED AND BUILT (2026-09-29).** Refine
  rounds can now cross-check (a second model family reviews the same round), and
  `CoverageSeries` folds both reviewers' verdicts into a band. Spec:
  [superpowers/specs/2026-09-29-flight-control-coverage-design.md](superpowers/specs/2026-09-29-flight-control-coverage-design.md).
  Plan: [superpowers/plans/2026-09-29-flight-control-coverage.md](superpowers/plans/2026-09-29-flight-control-coverage.md).
  Deferred out of this branch (each its own later spec, design §10):
  - **The shadow probe** for Gemini / Grok / Qwen (handoff §4): score-only integrate, a
    `probes/` directory beside `checkpoints/`. Reuses this design's clustering and
    `CoverageReading`.
  - **An OpenAI-compatible (or per-vendor) harness** (handoff §5).
  - **Cross-tape project index** ("Feature plans here usually saturate by Refine 2"), and
    calibrating `CoverageThresholds` / `CoverageTargets` from finished tapes.
  - **Reviewer family rotation per round and a reviewer persona.**
  - **Cost per accepted issue by family** (needs a codex price table, or tokens as the unit).
  - **Draft-stage metrics** (draft overlap, unique coverage, synthesis provenance).
  - **Change severity** (major/minor).

  **First real cross-check (2026-10-02) — the estimate is not usable yet.** One Refine round
  over a copy of the larkOS intake (`RoundsLiveProbeTests`, skipped by default; 1009 s; claude
  seats $2.92, codex 919k in / 15.8k out tokens): codex made 57 single-issue proposals, claude 12
  — one per plan section, each bundling numbered sub-issues (mean 3,345 chars vs codex's 511;
  its own summary said "75 problems"). So n1=49, n2=12, both=8 compares issues against sections,
  and Chapman (~71, MANY LEFT) is meaningless. The integrator's 8 clusters were section matches
  (3 good, 1 weak) and it missed obvious sub-issue duplicates; the text matcher found 0 in
  common and the disagreement note fired, correctly. **Next:** make the review prompt/schema
  force one issue per proposal (or have the integrator split bundles) before any threshold is
  calibrated. Also seen: codex's `run.json` `finished` lands ~105 s after its last event, at the
  same moment as the parallel claude seat — unexplained.

  Residuals noticed while building, deliberately not fixed on this branch:
  - Plain (non-cross-check) Refine rounds still ignore the reviewer's fallback (pre-existing
    `seat` behavior), while cross-check rounds honor it. It's inconsistent; a ruling kept it
    out of this branch.
  - A non-cancellation I/O error in the cross-reviewer's run setup pauses the round (it should
    degrade to `.failed` instead, the same way a cross-reviewer failure elsewhere does).
  - No test covers pausing while the cross-reviewer is still running — cancellation is proven
    only by reading `CommandRunner`'s killpg path, never exercised live.
  - `CoverageSeries` re-reads `changes.json`/`verdicts.json` that the convergence fold already
    read in the same task — two passes over the same checkpoint files.
  - Every `CoverageThresholds` / `CoverageTargets` value is an uncalibrated placeholder: one
    intake existed while this was built, and it stopped before Refine 1, so nothing has tuned
    the band boundaries or the per-fidelity stop targets against a real run.
  - **The GUI check is the maintainer's** (agents can't drive the GUI, AGENTS.md rule 2): turn cross-check
    on for an intake, continue Refine 1, confirm two reviewer rows run, then check the LCD's
    COVERAGE cell and the coverage card's counts against `checkpoints/<n>/crosscheck.json`.
- **Detection UI.** `IntakeService.availableModels()` only probes PATH for the two CLIs and
  fills in fixed defaults. Spec §6.2's detection — plan type and rate limits from
  `codex app-server`, `claude auth status`, per-value source labels, unreachable tiers shown as
  unavailable with a reason — is not built, so the Rounds editor's model field is free text.
- **The convergence gauge — FIXED by the planning UI redesign (2026-09-28).**
  `ConvergenceSeries` (IntakeKit) folds every Refine/Polish cycle into a verdict
  (`tooEarly`/`converging`/`plateau`/`diverging`), folded off-main by
  `IntakeService.refreshConvergence`, and the LCD's CONVERGENCE cell, the section heatmap and
  the churn lane draw it (`ConvergenceCellModel.swift`, `ConvergenceViews.swift`). Its
  thresholds are still untuned — see the planning-UI section below.

**Accepted residuals:**

- **Three app processes still use `waitUntilExit()`**: `LoginShellPath`,
  `CodexProcessTransport` and `FlywheelProcessRunner`. Called from a GCD worker it was shown to
  wedge after the child had already exited (sampled 2026-09-27, four concurrent test runs all
  stuck in it), which is why `SystemCommandRunner` moved to a `terminationHandler` + semaphore
  (f703040). None of the three has been seen hanging in the app, but each is the same pattern
  and should move the same way.

**Not yet run or measured:**

- **No live whole-tape run under fd-abduco with claude seats and the isolation flags.** Each
  flag was probed live on its own (claude `--restricted` + `--tools`, codex
  `--ignore-user-config --ignore-rules --disable hooks` + `-c service_tier`), and
  `RoundsLiveProbeTests` ran a codex-only Sketch in-process — but no app-spawned runner has yet
  taken a tape to review with claude seats under the full flag set. That is
  `docs/FLYWHEEL-INTAKE-CHECKLIST.md`'s "Plan from scratch" job (including its Full plan variant
  and the `.quillmap/` check). State on 2026-09-28: the maintainer's one real run (the larkOS intake,
  `~/Library/Application Support/Flight Deck/intakes/7C3A9E52-…/`, Full plan) has two
  checkpoints (Draft ×4, Synthesis), status `stopped`, with Refine 1 started and stopped — so
  no tape has yet reached Encode, Polish or review with real claude + codex agents under the
  flag set. Read that intake; never write it.
- **Main-thread cost during a run is unmeasured.** The tick stats `tape.json` per shaping intake,
  decodes it when it moves (every heartbeat of a running tape), reads `commands.jsonl` for a
  waiting tape, and probes the runner socket; heartbeat-only changes are no longer published.
  None of it has been timed against a live app mid-run.

**From the live Sketch probe** (`RoundsLiveProbeTests`, codex `gpt-5.6-luna`/`low` in every
seat, 2026-09-27 — it reached review first time, 277 s, ~452k input / ~19k output tokens):

- **Cheap reviewers propose at line granularity.** The one refine round proposed 64 changes to a
  141-line draft (all 64 agreed; the plan came out at 85 lines), and the encoder turned a
  one-flag intent into 11 new beads and 18 edges — against a scratch project with no code, so
  the plan hedged with discovery/bootstrap beads. Not a schema problem; a prompt-calibration
  one worth watching at real fidelity before anyone reads the change count as a convergence
  signal.

**From editable plans and anchored notes** (engine only, 2026-09-27):

- **A mid-round edit carries forward only on a clean merge.** `git merge-file` treats adjacent
  changes as a conflict, so an edit on the line right next to one the round changed leaves the
  new head clean and sets `editConflict`; the edit stays on its old checkpoint for the human to
  reapply. The merge base is the plan the round actually read (the generated plan, or the edited
  one when edits already existed at round start), so edits the round already built on are not
  merged twice. An edit sent to the old head after the round has landed (a view that hadn't
  switched yet) is stored there and feeds nothing — the UI should follow the head.
- **`editPlan` carries the whole plan, and `commands.jsonl` never shrinks.** `appendCommand`
  re-reads every line to pick the next `seq`, so a UI that sends an edit per keystroke on a
  large plan makes each append slower. The editor as built commits on end-of-editing or after
  2 s idle (`EditPolicy.idle`, `PlanTextView.swift`), never per keystroke — but each commit is
  still the whole plan, and a long session of edit bursts still grows the file without bound.
  Compacting acked lines is the fix if appends ever show up in a profile.
- **The lost-edit check is line-exact.** A round that keeps an edited line but reflows it (or
  moves one word) counts it as lost; the warning over-reports rather than under-reports.
- **No views — FIXED by the planning UI redesign (2026-09-28).** The editable plan with its
  edit layer, per-hunk and Revert-all, anchored notes and the notes rail are built under
  `Sources/FlightDeck/Intake/Planning/PlanEditor/` on exactly these seams. What is left of them
  is in the planning-UI and "unverified in the GUI" sections below.

## From the planning UI redesign (2026-09-28), the views landed on top of the round engine

**Not yet tuned:**

- **Quiet/stall/convergence thresholds are named constants, not tuned values.**
  `SeatRowModel.Thresholds` (quiet 30s, stalled 90s) and `ConvergenceSeries.Thresholds`
  (`convergingRatio` 0.6, `agreeDrop` 5, `growRatio`/`growMin` for the "growing" diverging
  reason) ship at spec-picked defaults — spec §12 calls this out by name as next-plan scope,
  deliberately not tuned against real runs here.

**Known gaps in the as-built views:**

- **Convergence fold is O(rounds) per redraw, not incremental.** T5's fix report measured it at
  1.46s off-main per landed round on a 30-checkpoint/17.5KB tape — folded once per round landed,
  not per keystroke, so it doesn't cost a running UI anything today, but it re-walks every prior
  checkpoint each time. Worth an incremental fold (carry the running tallies forward from the
  last cycle) once tapes regularly run longer than 30 rounds.
- **The live slot doesn't grow.** Spec §5 says "the live slot shows the playhead and grows";
  `BoardModel` gives every slot an equal share of the tape's width instead, and there is no
  honest progress fraction to grow it by (T7, deferred as ruled — the seats-done fraction lives
  with T6/T8's work, not T7's).
- **The heatmap can't align to a scrolled tape.** At a narrow pane where the departures board's
  own tape is wider than the pane and scrolls, `slotColumns` returns nil, so the heatmap packs
  its own columns after the name column instead of tracking the tape's actual scroll position
  (T13).
- **`BILLED` covers only the round in flight.** `LCDModel.billed` sums `SeatRowModel.cost`
  across the *current* round's finished seats — the only place a cost is known, since only
  claude states one and only once a seat finishes. Checkpoints record no cost, so there is no
  run-total figure to fall back to across rounds; a dash means "nobody in this round has said
  yet", not "free". The raw figures do survive: each claude seat's `runs/<run>/activity.json`
  keeps its `costUSD` after the round lands, so a run total for claude seats is a fold over
  `runs/`, not new recording; codex seats have tokens only. The coverage design
  ([FLIGHT-CONTROL-COVERAGE-HANDOFF.md](FLIGHT-CONTROL-COVERAGE-HANDOFF.md) §2.8) needs the same
  fold for cost per accepted change.
- **Esc inside the plan editor may not reach the heatmap.** `NSTextView` binds Esc to
  `complete:`, not `cancelOperation:`, while the editor has focus, so `.onExitCommand` may never
  fire there even though it closes the heatmap correctly with focus anywhere else (T9b). The
  pane-wide `.onExitCommand` (`IntakeDetailView.swift`, "Esc closes the heatmap from anywhere in
  the pane") landed, and closes the heatmap, then the finished-round panel — but whether it
  fires with the editor as first responder is still only a GUI question. If it doesn't,
  `PlanNSTextView` could forward Esc while the heatmap or panel is open.

- **Typing flushed as the plan reaches review can be dropped (final review #15, recorded, not
  fixed).** `PlanTextView.dismantleNSView` commits the last idle-debounce window of typing when
  the editor goes away, through `IntakeService.send`, which refuses anything but `.shaping`
  (`guard intake(id)?.state == .shaping`). When the runner lands the last round and
  `finishShaping` moves the intake to `.review` in the same tick that tears the editable plan
  down (the plan turns into the read-only final plan), the flush arrives after the state
  change and is silently dropped — up to the last ~2 s of keystrokes, only if they were typed
  in the moment review arrived. Review Focus 3 ("no keystroke is lost") does not hold in that
  window. Ruled a narrow race not worth a fix now; the remedy, if it shows up in use, is to
  surface the dropped text (a note on the final plan, or a banner offering to copy it) rather
  than let `send` accept edits after the change set was encoded from the plan.

**Resolved in the final review:** the release sheet's footer, button and header no longer count
different things — `ReleaseCounts` is the one count ("Release 3 New Tasks" over "3 new tasks ·
2 edits · 2 dependencies"), and the header says "N dropped" instead of "N of M selected".

## Codex control-socket grant (2026-09-26)

- **It depends on an experimental codex feature.** `CodexControlAccess` needs
  `--enable network_proxy` and the `permissions.<profile>.network.unix_sockets` map. Codex
  labels `network_proxy` experimental, so a release can rename or drop it with no warning.
  Verified on codex-cli 0.155.1 and 0.157.1, so `CodexVersionProbe.controlAccessMinimumVersion`
  is 0.155.1 and an older codex gets no flags. Raise the floor, never lower it, without a live
  run of the guard on the older version.
- **If the live guard fails** (`testControlSocketGrantConnectsWithoutOpeningTheInternet` under
  `./scripts/test-codex-live.sh`), read which assertion failed:
  - *The control* (`:workspace` connected without the grant): codex now allows unix sockets by
    default. The grant is not needed, but check that the internet is still blocked before you
    remove it.
  - *The connect*: every codex tab's `flightdeck` now exits `77`. Probe the new codex with
    `codex sandbox --help` and a manual `codex sandbox … -P flightdeck -- python3 client.py`,
    find the new spelling in codex-rs `sandboxing/src/seatbelt.rs`, and fix
    `CodexControlAccess.launchArguments`. Do not fall back to `danger-full-access`.
  - *The sibling socket* (`other.sock` connected): codex now treats a `unix_sockets` key as
    wider than the file. This is serious: in the real state dir, `answer-trigger.sock` is
    unauthenticated and can press Return in any tab. Stop injecting the flags (return `[]` from
    `launchArguments`), or move the control socket into its own directory and key that.
  - *The internet check* (1.1.1.1:443 connected, or failed without `EPERM`): either the grant
    now opens general network access, which is the serious case — stop injecting the flags
    (return `[]` from `launchArguments`) until the grant is narrow again, and accept exit `77`
    in codex tabs meanwhile — or the Mac is offline, in which case re-run it online.
  - *The proxy check* (a request through codex's `http_proxy` succeeded): the proxy now
    allows hosts by default. Treat it like the internet check.
- **A tab that predates the grant keeps its old launch line.** Reopen it to get the flags.
- **A user-chosen codex sandbox gets no grant**, on purpose (codex rejects `sandbox_mode` with
  `default_permissions`). Such a tab's agent always sees exit `77`.
- **TUI tabs probably get per-host network approval dialogs, and nothing handles them.** With
  `network.enabled=true`, a proxy-aware tool (curl, pip, npm, git over https) in a codex tab
  goes through codex's proxy. Codex 0.157.1's source sends a host the proxy does not allow to
  an approval decider whenever the approval policy is not `never`, which is the case in a
  `codex resume` TUI tab. So the tab should show a "`<host>` is not in the allowed_domains" /
  `network-access <host>` dialog. This is read from the source only: the one live turn ran
  `codex exec` with `approval: never` and saw a plain 403. `CodexDialogDriver` has no fixture
  for this dialog, and the phone's answer path has never seen it. Next step is the maintainer's, in the
  GUI: in a codex tab, have the agent run `curl -sS https://example.com`, capture the dialog's
  screen text as a `CodexDialogDriver` fixture, and try answering it from the phone.
- **Quoting limits of the typed launch line.** `ClaudeSession.shellQuoted` targets POSIX
  shells only. fish collapses `\\` to `\` inside single quotes, so a state-dir path containing
  `\` silently loses its TOML escape under fish and the grant breaks (the key is wrong, or
  codex rejects the TOML). `CodexControlAccess.tomlEscaped` also does not escape control
  characters. The default path (`~/Library/Application Support/Flight Deck/control.sock`)
  contains neither, so it is unaffected. The round-trip test
  (`testAPathWithSpacesAndQuotesIsQuotedForShellAndToml`) runs through `/bin/sh`, not fish.
- **Two live tests were already failing before this branch, and it did not cause them.**
  `./scripts/test-codex-live.sh` on 2026-09-26:
  - `CodexIntegrationTests.testARealResumedTurnAppendsTheTurnRecordsToTheRolloutThreadStartNamed`
    now sees a trailing `.apiError(nil)` after `.turnEnded`. That event comes from the API-error
    work (f4fa03d, 89c4d23); the test's expected event list is out of date.
  - `CodexIntegrationTests.testARestoredCodexTabReattachesAfterAStartCodexFailure` types a bare
    `codex` instead of `codex resume <id>`. Its fixture's rollout path does not exist, so
    `coldCreateCommand` falls back to a fresh launch, which it has done since 443bdc5.

## From tab history and the shortcut overlay (2026-09-27)

- **Back/Forward into a session inside a collapsed project selects a row that isn't drawn.**
  `SessionSidebar`'s `List` only renders rows for an expanded project, so landing
  `selectedSessionID` on a session whose project is collapsed changes the terminal pane but
  leaves the sidebar showing no highlighted row at all — no visible feedback that the jump
  happened. `fi-tab-nav`'s cycling does not have this gap: it already treats a collapsed
  project's header row as standing in for a selected session hidden inside it (see
  `collapsedHomeID` in `cycleSelection`). Two options for Back/Forward: un-collapse the owning
  project as part of the traversal (`goBack`/`goForward` would need
  `setCollapsed(false, forProjectAt:)` alongside the selection write), or land on the collapsed
  project's header, as cycling does, instead of the session inside it. Left to the maintainer's call
  rather than picked here.

## Level 3 swarm: branch strategy (the maintainer's ruling, 2026-09-28 — for when Operate is designed)

- **Default now: one shared main branch per project** — the simplified mode. Agents coordinate
  through Agent Mail file reservations and the pre-commit guard, so reservation-conflict
  visibility (a "contested" session state, why a commit was blocked) is required UI, not polish.
- **Later: configurable per project — worktrees as the advanced mode.** The two modes run
  different processes, not one process with a flag:
  - Worktree mode needs an **integrator** role: a merge coordinator and test runner that brings
    agents' worktree branches back to main (serialize merges, run the suite, bounce failures back
    to the owning agent/task).
  - **Infrastructure stacks:** some apps' stack (servers, databases, services) only runs on the
    one main checkout. Options must include a stack per worktree, a stack for selected worktrees
    only, and a single shared stack, with the integrator testing against whichever applies.
- Design Level 3 so both modes share the task/claim/tending surfaces and differ only in the
  landing path (commit-to-main vs. integrator merge).

## Flight Control — unverified in the GUI (gathered 2026-09-28)

Every planning-UI behaviour below passed its unit tests and offscreen renders, and none has been
seen in the real app: agents can't drive the GUI (AGENTS.md rule 2), and
`docs/FLYWHEEL-INTAKE-CHECKLIST.md`'s "Planning UI" section (and its "Plan from scratch" job)
has never been walked. Each item is on that checklist; this list is what the build reports
flagged as most likely to differ from the tests. The maintainer's to run.

- **Stop's confirmation defaults to Cancel.** `confirmationDialog("Stop the run?")` in
  `IntakeDetailView.swift` forces Cancel with `.keyboardShortcut(.defaultAction)`, but macOS picks
  a dialog's default itself. Check that Return after ⌘. keeps the round.
- **Tab reaches the CONVERGENCE cell, agent rows and finished-round cards**, and Return/Space
  acts on them (final review #8). The churn lane's NSView markers still can't take Tab focus;
  their keyboard route is the heatmap plus the "Show Versions" VoiceOver action.
- **Opening the heatmap from the pinned bar** scrolls the card into view and the heatmap never
  covers the plan (final review #11, fixed without a live repro).
- **Esc with the plan editor focused** closes the heatmap, then the round panel (see the
  planning-UI entry above).
- **⌘- (Remove a Round) and ⌘= (Extend) reach the Run menu past the Ghostty surface**, rather
  than changing the terminal font size. ⌘- is `unbind` in `GhosttyDefaults.conf`; the live key
  path is unchecked.
- **+/− and play/pause show at once with no bounce back** (`TapeOverlay`): measured 0–2 ms
  in-process, never on screen; `startRunner` still spawns on the main actor in the same turn as
  the click (measured ~0 ms, unmeasured in the GUI).
- **The notes-rail close race** (`ProjectViewInspectorLiveTests`) was reproduced offscreen only;
  whether it is the path the maintainer hit in the real window's animation timing is unconfirmed. Check
  ⌥⌘I and Hide Inspector, immediately and after settling, and per-project state across a
  relaunch.
- **A selected intake row's secondary text follows the key-window accent highlight**
  (`IntakeRow.swift`, hierarchical `.secondary`); the offscreen List only draws the gray
  unemphasized selection.
- **The Intakes rail collapse jumps once, then slides** (`IntakeRail.swift`), by design so the
  plan isn't re-laid each frame — judge the feel. The divider is now a SwiftUI `DragGesture`,
  not an `NSSplitView` tracking loop, so whole-plan layout slices can run between drag ticks on
  a 2,000-line plan; drag smoothness is unmeasured.
- **A plain click on a link places the caret; ⌘-click opens it** (`PlanLinks`,
  `PlanNSTextView.clicked(onLink:)`). Whether an editable TextKit 2 view calls
  `clicked(onLink:)` on a plain click, and how caret/drag feel over link text, couldn't be
  synthesized. Same for **VoiceOver activating a link**.
- **Hover cards: the 350 ms intent delay, warm switching and the 500 ms cool-down**
  (`HoverIntent`), the fade/scale entrance, and click/Esc/scroll closing them. Live pointer
  timing can't be reached offscreen.
- **Finished rounds: the panel's height animation, the caret sliding between cards, no flicker
  on the 1 Hz tick, Esc, and Reduce Motion** (`FinishedRounds.swift`). Renders show settled
  frames only.
- **Folding and the section cue:** ⌥⌘←/→ fold with the editor focused, the chevron on hover,
  auto-unfold on Find or caret landing, and the pinned board's "§ N. HEADING" breadcrumb
  appearing only once the heading scrolls under the block (`PlanFolding.swift`,
  `PlanOutline.swift`).
- **One scroll for the plan:** wheel over the plan and over the pinned block scrolls the page;
  the caret stays visible typing or pasting at the bottom and under the pinned block; notes
  bands stay on their text after relayout; Find (⌘F) reveal and IME composition (both go
  through the same `scrollRangeToVisible` override, never run live).

## Flight Control — known gaps and limits (gathered 2026-09-28)

- **Flight Control on the phone — BUILT (superseded 2026-10-02).** This entry said nothing
  crossed the phone link. Intake summaries, detail, plan, transport, default play and notes now
  do: spec [superpowers/specs/2026-09-29-flight-control-mobile-design.md](superpowers/specs/2026-09-29-flight-control-mobile-design.md),
  merged with `fc-mobile-watch` and `fc-mobile-steer`.
- **Only two harnesses, so only two model families.** `Harness` is `codex | claude`
  (`Sources/IntakeKit/Intake.swift:24`), and one reviewer slot serves every Refine round
  (`RoundConfig.reviewer`) — by default always codex, so reviewer diversity is zero. Coverage
  metrics and the shadow probe that would tell the maintainer whether Gemini/Grok/Qwen add anything are
  designed in [FLIGHT-CONTROL-COVERAGE-HANDOFF.md](FLIGHT-CONTROL-COVERAGE-HANDOFF.md).
- **⏹ and notes are not overlaid** (`TapeOverlay.swift`). With ⏹ queued ahead of a + or play,
  STOPS AT can show the old target until the runner acks ("Stopping…" is showing meanwhile).
  The notes rail keeps its own optimistic copy. Play on a paused tape clears a FAILED/STOPPED
  chip at once — intended, but visible.
- **A trim sent with no live runner spawns one to fold it** (the same path `+` takes), so the
  board waits for that spawn before the runner confirms. The engine would also let a trim remove
  a failed round (it doesn't know which round failed); the UI never offers it.
- **Heatmap jump geometry uses estimates.** The offset reads the document clip's height at the
  moment of the jump, and the pinned block's height falls back to 300 pt before its first
  measurement (`PageJump`, onescroll report).
- **A heatmap cell opens Diff vs Previous, not the editor**, so there is no fold to open on that
  path; notes-rail cards have no click-to-scroll action, so a note inside a folded section is
  placed at its heading instead.
- **Folds in the final plan last one editor lifetime.** Past shaping, `IntakeService` drops the
  fold store on its next poll (`PlanFolding`).
- **The versions card still covers text below its heading.** It now hangs below the heading
  line and never covers the line itself (`CardPlacement.Side.belowLine`), but at pane width
  there is no side room, so the lines under it are hidden while it is open.
- **Link rendering quirks.** TextKit 2 ignores `.underlineStyle`, so the ⌘-hover underline is a
  subview, removed on any text change; the ⌘-hover tip covers part of the next line while ⌘ is
  held; relative links resolve against the project, never the plan's own location (it has none
  — the plan lives in the checkpoint store).
- **Hover-card flip is a 2D projection** (`TileFlip`, y-scale by cos θ), because
  `layer.render(in:)` drops 3D transforms and blanked the mid-flip renders. No perspective taper
  on screen; restoring `rotation3DEffect` is one line but loses the render frames. The card's
  event monitor closes it on *any* scroll wheel event in the app while it is up.
- **The Intakes list's expanded width doesn't persist** — it resets per view mount, as it did
  under `HSplitView`.
- **Old tapes mix line-count units.** Rounds recorded before `MarkdownUnwrap` counted hard-wrapped
  source lines; later rounds count about one line per block. Nothing is converted, so churn and
  "N lines" on a pre-unwrap tape jump at the boundary. A soft newline the human types inside a
  paragraph is joined on store (renders the same).
- **A failed tape's idle clock can be up to a minute stale** when it has `failedAt` but no next
  slot: its minute ticks align to `failedAt` while the board counts from the head.
- **`PlanNotesBridge` re-subscribes to enclosing clip views on `attach`**, which runs on every
  view update; an editor re-parented with no update following would miss the outer scroll until
  the next one. Not expected in practice.
- **Finished-round card truncation is SwiftUI tail truncation**, not word-boundary; every field
  is short by construction and none truncated at 184 pt, so it only matters if a field grows.

## Flight Control — tooling and tests (gathered 2026-09-28)

- **`scripts/test-unit.sh` exits 0 when the sharded run FAILS.** It tracks `rc` through the
  shards and the serial lane but never exits with it: the last command is the
  `echo "** SHARDED UNIT RUN … **"` banner, so the script's status is the echo's. Every caller
  (agents, `&&` chains, any future CI) sees success on a red run; today the only reliable signal
  is reading the final PASSED/FAILED line. Fix: `exit "$rc"` after the banner. (The
  `FD_TEST_FILTER` path ends in a bare `exit` right after xctest, so it keeps xctest's own
  status and is unaffected.)
- **`CodexPinReconcileTests.testATickInTheGapBeforePassNowResumesCannotOverlapItsOwnPass` flaked
  once under a full sharded run**, although its class is already in the serial lane
  (`scripts/test-serial-classes.txt`). It passed alone three times and on the rerun. The serial
  lane runs after the shards, so the load it saw was the machine's, not a sibling shard's — if it
  recurs, give it a flake-hunt loop rather than rerunning the suite.
- **`ProjectViewInspectorLiveTests` probably flashes titled windows on the real screen.** It
  parks a plain titled `NSWindow` at −10,000 (`ProjectViewInspectorLiveTests.swift:130`); AppKit
  constrains a titled window onto a screen when it is ordered front, which the rail work caught
  happening. Move it to `ParkedWindow` (`ProjectViewIntakeListLiveTests.swift:188`, overrides
  `constrainFrameRect`).
- **The phone target has no terminology guard.** `TerminologyGuardTests` scans
  `Sources/FlightDeck` and `Sources/IntakeKit` only, so a "bead", "seat" or "Flywheel" in a
  `Sources/FlightDeckMobile` string would ship. Matters as soon as Flight Control reaches the
  phone; extend the scan (and run it under `test-ios.sh` or read the files from the mac suite).
- **Two render fixtures still say "seats failed after 3 retries"** —
  `SplitFlapTextRenderTests.swift:30` and `DeparturesBoardRenderTests.swift:41`. Synthetic
  diagnosis text no production path generates; cosmetic, but it is what the renders show.
- **The link tests were written with the code, not red-first** (`PlanLinksTests`); the
  scripts-open-in-editor follow-up was red-first.
- **The `flywheel-intake` branch, its worktree (`.claude/worktrees/flywheel-intake`) and the
  `.superpowers/sdd/2026-09-27-planning-ui-redesign/` workspace still exist** after the merge to
  master. Deleting them is the maintainer's call.

## Flight Control — next phases (gathered 2026-09-28)

- **Coverage × fidelity — BUILT 2026-09-29 (see the round-engine section above).** Originally: Metrics for whether the reviewing families have
  searched the plan's issue space (capture–recapture over accepted changes, per-family marginal
  yield), fidelity presets as coverage budgets, a convergence-AND-coverage stopping rule, and a
  shadow probe for trying Gemini/Grok/Qwen on frozen checkpoints — which needs a harness beyond
  claude/codex (an OpenAI-compatible endpoint, say). Handoff:
  [FLIGHT-CONTROL-COVERAGE-HANDOFF.md](FLIGHT-CONTROL-COVERAGE-HANDOFF.md).
- **Flight Control on the phone — BUILT (see "known gaps and limits" above).** Originally: Handoff:
  [FLIGHT-CONTROL-MOBILE-HANDOFF.md](FLIGHT-CONTROL-MOBILE-HANDOFF.md).
- **Level 3 "Operate" — BUILT (2026-10-06), integrated on branch l3-integration (not merged), GUI-unverified.**
  Five specs: overview and contract
  ([L3-0](superpowers/specs/2026-10-04-flight-control-l3-overview-contract-design.md)), routing
  ([L3-R](superpowers/specs/2026-10-04-flight-control-l3-routing-design.md)), capability index
  ([L3-I](superpowers/specs/2026-10-04-flight-control-l3-capability-index-design.md)), usage and
  rollover ([L3-U](superpowers/specs/2026-10-04-flight-control-l3-usage-rollover-design.md)) and
  swarm ([L3-S](superpowers/specs/2026-10-04-flight-control-l3-swarm-design.md)). The four
  sub-branches (`l3-routing`, `l3-index`, `l3-usage`, `l3-swarm`) are merged into `l3-integration`,
  and `FlightControlComposition` (installed in `FlightDeckApp.makeStore`) builds the one real
  graph. The branch has NOT been merged to master and nothing has been swapped into /Applications.
  The maintainer's checks are [FLIGHT-CONTROL-L3-CHECKLIST.md](FLIGHT-CONTROL-L3-CHECKLIST.md)
  (eight tasks), run against a Release build.
  - **UI runs (2026-10-06, `l3-integration` @ 4db609f0, under the global UI lock):**
    `RoutingUITests` 4/4 PASS (the first execution on any branch); `CapabilityIndexUITests` PASS
    (first execution, opt-in via `TEST_RUNNER_INDEX_UI=1`); `CapacityUITests` PASS;
    `SwarmUITests` 2/2 PASS. Caveat: `SwarmUITests` runs under `-FlightControlFixtureBackend`,
    which skips `FlightControlComposition`, so the UI suites do NOT exercise the real joined graph.
    The joined graph is covered by `SwarmEndToEndTests` and the `FlightControlL3/Integration` unit
    tests, against faked `br`/`am` and tabs. A real-stack GUI run is the maintainer's checklist.
  - **What integration added beyond the merge** (each has a test; see the spec as-built sections):
    - Retiring an agent honors the exit delivery: a failed exit is the terminal phase
      `.stopFailed` (not `.failed`, which would spawn a second replacement); the old lease is kept.
    - Hand-off confirmation does not block the pass. `HandoffDriver` is the
      `HandoffDecisionSink`; confirmation is phone-only, there is no Mac confirm UI.
    - Hand-off prompts list the old agent's file reservations. An unreadable lookup says so
      instead of claiming "held no file reservations".
    - A handed-off tab is marked finished and Flight Control stops driving it (no prompt, claim
      or reuse). The user's keyboard is not blocked.
    - A fresh router per launch and per spill, so a rule edited after launch applies.
    - Spill and the launch sheet's catalogs follow Settings (a disabled agent is never a target).
    - One hand-off pass per tick over all swarms; the task is held during a hand-off; the old
      claim goes back to open before the new agent claims; the driver is the only owner of the
      old lease.
    - A block naming a deleted pool waits with "pool <id> no longer exists" and never spills.
    - Real meters on swarm rows, observing `UsageService`.
    - The materialized claude plugin copy is refreshed before `/reload-plugins`.
    - Settings: one Flight Control tab with Routing, Capability index, Capacity and Task kinds
      sections (Settings → Flight Control → Capacity); the temporary top-level tabs are gone.
  - **OpenCode routing capabilities wait for the opencode-adapter merge; `RoutingCapabilityRegistry.standard()` will fail to compile until it states them, which is intended.**
  - **Still open** (unresolved probe outcomes and deferred minors, carried from every branch):
    - Probes never run live: the changed triage/change-set strict-mode schema
      (`taskKind`/`kindProposal`) against claude and codex (probe once per CLI before merging,
      since every planning round shares it); codex `effort` and `/new`; reservations time parsed
      from a relative `granted_at`; codex usage-limit `codex_error_info` spellings
      (`RateLimitClassifier.kinds`), so the fleet API-error path may never mark a codex account
      over hard (the 120 s `rateLimitReachedType` read is the authoritative signal); the real
      claude-tab meter (the mod in an FD-spawned tab) against `/usage`; the hook log's
      failed-tool event for claude (transcript used instead).
    - Capability index: the validator trims spaces but not newlines; the proposer proposes the
      bare model for a non-knob bracketed setting; the confidence denominator counts sources that
      returned no data; a model-supplied `retrievedAt` is kept as row provenance; a refresh has no
      timeout or cancel (a hung `claude` leaves Roll back disabled until relaunch); an
      all-sources-failed refresh still writes a snapshot, which can push real ones out of the 12
      kept; the agent model field accepts an empty model and a token cap of 0 and saves on every
      keystroke; `knownCatalogs` is filled only by a refresh in the session; a `prune()` failure
      after a good write reads as a snapshot save failure; the manual-score discount is not
      clamped to 0...1. The routing hint fallback is per-model, not per-dimension: a variant row
      lacking the rule dimension suppresses the hint.
    - Routing: claude full model ids (aliases only); codex's effort knob schema is the union
      across models, so a rule can validate with an effort one model rejects.
      `ProjectViewInspectorLiveTests` failed once in `l3-routing`'s full run (passes on master
      and on the integration branch).
    - Usage: local-pool capacity cannot see load from outside Flight Deck (by design); claude hook
      modules sit behind a remote rollout switch (no meter when it is off); `spendControlReached`
      is ignored; the silent-mod check is suppressed by any other reading on the account; a codex
      read that never returns stops that account's polling until restart; the OpenCode transcript
      command interpolates its session id and server URL unquoted (quote them when the adapter
      lands); `/usage` shows a third window ("Current week (Fable)") that `session.measure` does
      not report; `UsageService.revision` bumps on every tick, so swarm rows re-evaluate each tick.
    - Swarm: the Observe events lane is a nil stub (activity stands in); the Assignment lane is
      hidden when the tab has no Observe (am) agent row; claude/codex accept only the hard-coded
      `effort` knob; an agent `stop()` retired gets no "done" marker and a stopped swarm's summary
      is not visible; `SwarmService.applyProjections` awaits each project in turn, so one slow
      `br show` delays completion detection everywhere; old phone builds get a `.session` reply to
      `session.new`; the phone's hand-off decision API (`decideHandoff`, `handoffPending`) has no
      UI caller yet, and there is no Mac confirm UI, so a user who turns "Confirm hand-offs" on
      without the phone never gets hand-offs.
    - Integration: a failed plugin refresh still arms the reload and records the fingerprint
      (NSLog only); an absent Observe projection reads as no reservations (prompt says "held
      none"); the debug fixture backend keeps all-harness catalogs (its router never spills);
      `stop()` mid-hand-off can release the old lease twice (the ledger ignores the second);
      a hung `onTick` stops all hand-offs; the hand-off claim conflict was inferred from a fixture,
      not live `br`; the hand-off rig opens claude tabs for codex blocks; Settings'
      `.id(project)` rebuilds Capacity drafts on a project change; `PreferencesOpener` cannot
      select a Flight Control section; the awaiting agent is not re-Escaped if it resumes work
      during a pending confirmation; no test for confirm-turned-off-while-pending; the swarm
      drawer pixel test captures the first render without settling.
    - Test flakes seen under load, each passing alone: `PlanEditorKeystrokeTests` frame budget
      (16.1 to 16.7 ms), `PlanningRenderTests.testASeatBeatRedrawsTheLiveCardAlone`,
      `DelegationLifecycleTests.testUnknownRunFromTheHostEndsTheRunAsDied`.
  - **Still deferred (Level 3 follow-on, unchanged):** the remaining tending actions (reclaim and
    respawn a stuck task, "fresh eyes", "reread AGENTS.md", a tend-cadence nudge), the Agent Mail
    inbox anchored to tasks, and the task-graph convergence gauge. Unresolved: whether
    `AgentAdapter`/`AgentKind` should share `ntm`'s agent taxonomy, and whether `ntm serve`'s
    event stream is worth a transport spike ([FLYWHEEL-SPIKE-FINDINGS.md](FLYWHEEL-SPIKE-FINDINGS.md)
    already ruled it out as FD's own runner).

## Plan comments from the phone (2026-09-30)

- **Phone comments never reached the agent — FIXED.** Plannotator's `POST /api/deny` gives the
  hook exactly `body.feedback` and never reads its own annotation store; the `# Plan Feedback`
  document the browser's "Send Feedback" sends is built client-side by the browser. So a comment
  posted to `/api/external-annotations` showed in the gate's sidebar and the agent read only
  "Plan rejected by user". `PlanGateService.resolve` now reads the gate's store (falling back to
  what this Mac posted) and sends `PlanFeedback.compose`, the browser's own format, as
  `feedback`. Verified end to end against a live `plannotator` 0.27.8 gate: the hook's deny
  message carried every pinned and global comment plus the footer note.
  (`a35207e`, reverted in `dcc80a7`, had blamed the endpoint: `/api/deny` 404'd there because
  that probe hit a non-plan Plannotator server. On a plan gate it answers 200.)
- **Approve cannot carry words — a limitation, not fixable here.** Plannotator's allow decision
  for Claude Code has no message field (Plannotator itself links anthropics/claude-code#16001),
  so a note or comments on an approved plan are saved with the plan but never reach the agent.
  The phone now confirms before an Approve that would drop them and offers "Request changes"
  instead, as Plannotator's browser does. Revisit if Claude Code's `PermissionRequest` allow
  decision gains a message.

## From remote hosts, sub-project A: host foundation (2026-10-05)

Pairing, a live link to each host, and `flightdeck host ls|info` landed on branch
`host-foundation`, now merged to master (plan: [the host-foundation plan](superpowers/plans/2026-10-04-host-foundation.md)).
What is open, in the order it will bite:

### Not built, not done

- **MUST-FIX before the first `hostd-v*` publish: installer hardening.** Three items, none optional:
  wrap `hostd-install.sh`'s body in `main()` (called on the last line) so a truncated `curl | sh`
  runs nothing; have `build-hostd-linux.sh` write `installer.xcconfig` only after a full
  two-architecture build (a partial run writes a digest the published release cannot match, and
  the Release app then embeds a command that fails its own checksum); and require an `https` asset
  base on the app side before the Add Host sheet shows a command. Publishing without them ships a
  pasted command that can half-run or point at plain HTTP.
- **Spec §5 is not fully met.** `flightdeck host info` reports no simulators and no screen state
  (locked, asleep, logged out), and `flightdeck host ls` shows no tools and no workspace sizes.
  `HostInfo` carries neither; both need new fields (additive, so a minor-version bump) and a
  probe on each hostd.
- **Forgetting a host while it is online does not revoke on the host (§3.5).** Hosts → Forget
  drops the controller's key and record, but the host keeps the slot until its owner revokes it
  (Hosting tab, or `flightdeck-hostd controllers` then `revoke` on Linux). The spec wants Forget to
  send a revoke over the live link first; there is no such request on the wire yet.
- **`flightdeck host update` (spec §3.4) is not built.** The major-version refusal and its
  "Update Flight Deck on <name>" message are; the command that pushes a new hostd to a host is not.
  Until it exists, updating a Linux host is re-running the pasted installer.
- **The hostd release is unpublished.** `build-hostd-linux.sh` makes the assets; nothing uploads
  them. The Add Host → Linux sheet says the installer is not published until a Release build embeds
  the digest. Publishing `hostd-v<MARKETING_VERSION>` is the maintainer's step (HANDOFF.md, "Releasing the
  Linux host").
- **x86_64 has never been built.** The `swift:6.3-noble` amd64 image pull hangs in OrbStack, so
  `build-hostd-linux.sh x86_64`, `build-boringssl-linux.sh x86_64` and the `#if arch` branch in the
  package are untested. A release needs both; do not publish on aarch64 alone.
- **Linux has no Bonjour without `avahi-publish`.** The hostd publishes `_fd-host._tcp` and
  `_fd-host-pair._tcp` by running it. A minimal server or container has none, so the user types the
  address into Add Host → Linux. Pair-by-address dials 47411, so it reaches Linux hosts only; a Mac
  host is found through Bonjour (its pairing port is random).
- **The GUI end-to-end checklist is the maintainer's.** Agents cannot run it here (AGENTS.md rule 2). The four
  checks: pair a second Mac (Settings → Hosting on the target, Hosts → Add Host on the controller,
  `flightdeck host info <name>` lists Xcode versions); revoke from the host's Hosting tab (controller
  shows offline within seconds, reconnect refused); pair a Linux box with the pasted command; move
  the laptop from Wi-Fi to Tailscale and see the host return online with no re-pairing. For the
  last one, check `hosts.json` holds the host's `100.x` address *before* leaving the LAN: hosts now
  advertise their own addresses in `helloAck` (ARCHITECTURE.md, "Reaching a host off the LAN"),
  which is unit-tested against a scripted network only.
- **P3 (does XCTest UI run from a hostd LaunchAgent?) is still unverified.** Sub-project C built
  screen runs on that assumption but could not run the probe; see the next section.
- **Sub-project C landed** (next section). Deleting `workspaces/<slot>/` on revoke did not: it is
  listed there. B and D get their own specs.
- **Never run against real hardware:** the Linux systemd path is tested only against stub
  `systemctl`/`loginctl`; the installer's tarballs are not reproducible (two builds differ).
- **The full macOS suite has no baseline for this branch.** Task 2's full run showed about 11
  failures in unrelated classes (editor and planning timing budgets) at a load average of ~300;
  nobody ran `56fc926` quiet to prove they are load. Baseline when the machine is idle.

### Deferred minors, by area

**Pairing and the admin socket**
- `PairingWindow` has no per-window attempt cap of its own; the 3-attempt limit lives in each
  transport's responder.
- Admin socket: `writeAll` with `n == 0` leaves a stale `errno`; the accept loop spins without backoff
  on a persistent accept failure; `acceptThread` is not nil'd after `stop()`.
- Admin socket: two hostds starting simultaneously can race between the liveness probe and the
  unlink. A full Darwin backlog may report `ECONNREFUSED`, so `requireDead` could misjudge a
  saturated live server, and the EAGAIN comment is not accurate for Darwin.
- Linux `pair`: Ctrl-C's bare `cancelArm` can cancel another `pair`'s newer code; a bind failure on
  47411 is reported as "code expired".
- Linux hostd: SIGTERM while a window is armed orphans the `_fd-host-pair` `avahi-publish` child
  (`exit(0)` skips the `defer`).
- **Late pairing: a lost race leaves the controller holding a dead key.** NEITHER hostd consumes
  the window before the seal: both transports seal and send first, and only then (from the
  seal's send completion) consume the window and store the controller. If the code was replaced,
  cancelled or expired while that exchange was in flight, the consume fails, nothing is stored
  (the macOS hostd also revokes the slot at once), and the controller holds a key the host never
  accepts — it shows the host as paired and never gets online. The race is narrow: the exchange
  has to straddle a re-arm, a cancel or the two-minute expiry. Fixing it means a gate the responder
  consults *before* sealing, which neither `PairingListener` nor `NIOPairingResponder` offers.
  (A second controller sealing from the same code inside one window is closed: both responders
  refuse every confirm after their first seal.)

**Host core and the stores**
- `HostServerCore`: a frame with a known op but bad fields is also labelled "unsupported".
- `ControllerStore.load` returns `[]` silently if the corrupt-aside rename itself fails, and the aside
  name has 1 s granularity. Two `ControllerStore`s on one root are last-writer-wins.
- `HostInfoProbe.runCommand`: a timed-out reader thread stays pinned while a wedged grandchild holds
  the pipe (bounded by the grandchild's life).
- `PeerIdentities.slot(of:)` trusts the caller to call it after `.ready`; the app does.

**Transports (macOS and Linux)**
- A macOS listener that repeatedly reaches `.ready` and then fails rebinds without backoff, and a
  timed-out bind's late `.failed` can double-rebind.

**Controller side (`HostLink`, `HostService`, `HostRegistry`)**
- A host that acknowledges and immediately closes causes a hot reconnect loop: the attempt counter
  resets on the win, and a Bonjour re-add cancels the backoff. Fix: reset the attempt only after one
  stable ping interval.
- `Handle` and `NetworkHostConnection` have no `deinit` teardown when released without `stop()` (no
  leak in the app today).
- The sync-settling pairing driver is retained.
- A hostd's error code is passed through unprefixed into the Mac `err` namespace; the relative-date
  helper is duplicated.

**Settings UI**
- After `.failed` the Hosting tab keeps stale controllers and their Revoke buttons; the revoke
  read-back uses the current generation.
- An in-flight pairing survives closing the Add Host sheet (no `cancelPairing` on disappear), and the
  countdown reaching zero can send `cancelArm` more than once.

**Installer and release**
- The three MUST-FIX items are at the top of this section. Lesser: give a failed
  `systemctl enable --now` its own `die` message.

## From remote hosts, sub-project C: delegated execution (2026-10-05)

`flightdeck run|exec|up|down|restart|sync|ps|wait|logs|stop|diff|apply|recipe` on top of the
paired-host link (plan: [the delegated-execution plan](superpowers/plans/2026-10-05-delegated-execution.md);
as built: ARCHITECTURE.md, "Delegated execution"). Built in parallel tracks C0–C8. Every result
below comes from unit tests, the end-to-end `DelegationLoopbackTests` and the Linux hostd in a local
container; **nothing has run against a real second machine.**

### Unverified live, and the maintainer's

- **P3: does an XCTest UI suite run from the hostd LaunchAgent, and fail from a plain SSH child?**
  The placement of the macOS hostd rests on it. Procedure in [DELEGATION-PROBES.md](DELEGATION-PROBES.md).
- **P4: does `CGSessionCopyCurrentDictionary` report the locked screen reliably from the hostd?**
  The screen preflight (`screen_locked`) reads nothing else. Same document.
- **The spec's manual checks (§10):** a real UI test on a second Mac (the "don't touch" panel shows
  while the lease is held, and a second screen run queues behind the first), and a Linux pairing
  from the pasted command followed by a `flightdeck run` there.
- **The "don't touch" panel and the hostd's AppKit run loop.** The macOS hostd now ends in
  `ScreenPanel.runApplication()` (an `.accessory` `NSApplication`) instead of `dispatchMain()`.
  Unchecked on a real Mac: that it still launches and serves as a LaunchAgent, that the panel draws
  while a screen lease is held, and that it never takes focus from the UI test it guards.
- **`SMAppService` registration of the hostd from an installed build** has never run (sub-project A
  item above); every delegation run on a Mac host depends on it.
- **A routed command in a real tab.** Login-shell startup files do push the shim directory off
  the front (measured with real login shells: 40th of 43 entries under fish, 18th under zsh), so
  the shell now re-prepends `$FLIGHTDECK_SHIM_DIR` after its startup files (fish `vendor_conf.d`,
  zsh `ZDOTDIR` wrapper, bash `PROMPT_COMMAND`; ARCHITECTURE.md, "`delegate.toml` and transparent
  routing"). That is tested against real login shells, not in a Flight Deck tab: check
  `command -v xcodebuild` in a tab of a project that routes it.
- **Linux delegation under a real systemd is unverified.** The idle-sleep assertion is
  `systemd-inhibit`, and the claim that a hostd under systemd reaps zombie grandchildren (unlike a
  container's PID 1) rests on systemd's design, not a run: every Linux delegation test is in a
  `swift:6.3-noble` container with no systemd. Check both on a real host: `systemd-inhibit --list`
  during a run, and a run whose grandchild exits before it.
- **`/reload-plugins` at a busy composer** is unprobed, which is why the app sends it only to an
  idle tab. **A codex TUI already running** when its skill is installed or refreshed may not see
  it; new tabs do.

### Not built, or out of v1 by decision

- **Revoking a controller does not delete its `workspaces/<slot>/`** on the host (spec §3.5). Its
  checkouts, and any `include`d secret in them, stay until removed by hand or by
  `flightdeck host prune`.
- **Submodules are refused** (`submodules_unsupported`), like LFS: decided during the build to keep
  sync bounded. Spec §4.2 step 4 (recursive submodules) is deferred. **This includes Flight Deck's
  own repo** (`vendor/ghostty`, `vendor/boringssl`), so `flightdeck run` from any Flight Deck
  worktree exits 125 until submodules are supported.
- **Phones cannot delegate.** Every `delegate.*` from a paired phone is `out_of_scope`: the phone
  has no UI for it, and delegation runs code on hosts. A phone feature needs that decision
  revisited first.
- **Controller scoping on a host is hygiene, not isolation.** Every controller's runs execute as
  the host user, so one paired controller can read `controllers.json` (every controller's key), use
  `admin.sock` to arm, list and revoke, and touch other controllers' `workspaces/` and processes.
  `screen.status` and `queued` events also show another controller's session title and run id, by
  design (spec §6.3). Real isolation would need a user per controller.
- **A service's port forwards are not rebuilt after an app relaunch.** The service is still listed
  and can be downed; its `localhost` ports are gone until `restart`.
- **`exec` still takes a local snapshot** only to learn the workspace identity for
  `run.start apply:false`. `existingCheckout` on the host makes a cheaper identity call possible.
- **`queued(.slot)` always reports position 1 with no holder:** `WorkspaceStore` gives `acquire` no
  queue information.
- **Stale shim directories.** A tab closed while the app was not running (a crash, a hand-edited
  `sessions.json`) leaves `route-shims/<id>/` behind: a few dangling symlinks, never pruned.
- **Spec §8 wording.** The shim runs `flightdeck route-exec <name> -- <args>` and the CLI does the
  matching; the spec says the shim runs `flightdeck run <recipe> -- <argv>`. Same behaviour.
- **Unknown future `RunEvent` kinds** make the whole `event` frame fail to decode, and `HostLink`
  drops it. Fine for 1.x skew, but adding an event kind is a minor bump older controllers ignore.

### Deferred minors, by area

**Host router and wire**
- **No failure event.** A run that never ran is a synthesized `flightdeck: <reason>` line plus
  `exited(125)`. The line sits at the spool's end without being stored in it, so a re-attach from
  past it sends it again at the new offset (a cosmetic duplicate).
- **No event-send backpressure on the host.** `HostPeer.send(text:)` is fire-and-forget and
  `Runner.events` buffers without limit: replaying a full 64 MiB spool to a slow link holds about
  85 MiB in hostd.
- **`unknown_run` after a hostd restart.** Runs do not outlive the hostd: stopping it stops them
  cleanly (on SIGTERM it downs every service, running its `down` command, and cancels every run
  within launchd's 20 s exit timeout; after a crash it kills the recorded process groups when it
  next starts). The run-to-repo map is in memory, so `run.result`/`run.artifacts` for a run from
  before the restart answer `unknown_run`, and the controller ends that run as died (exit 125).
  `run.ack` carries `repoRoot`, so an ack still reaches the store.
- **The 60 s idle limit counts only channel bytes.** `sync.push`, `run.result` and `run.artifacts`
  fail `host_timeout` after 60 s with no bytes moving, and the host moves none while it unpacks a
  pushed bundle or builds a result bundle. A very large repo could hit it; a host keepalive (credit
  frames while it works) is the fix. A retry heals it (the host finishes `receive` anyway, so the
  next bundle is small). The per-store lock also covers `apply` and the hourly `gc --auto`, so a
  long checkout can stall a second worktree's `sync.push` past 60 s the same way.
- `run.ack` is best effort: an ack lost with its connection leaves the result on the host until its
  24 h expiry, which costs disk, not data.
- `run.result` tells a run still going (`run_active`) by `(runner as? Runner)?.phase`:
  `RunControlling` has no phase query.
- `port.open` checks the run's owner, not that it is a service still running; a finished run's port
  simply gets `dial_failed`.

**Host workspace**
- **Same-snapshot runs share one checkout** (`Workspace.claimSlot`, as spec §4.6 asks). Concurrent
  runs on one snapshot cross-contaminate each other's result commits, and two `xcodebuild`s in one
  checkout share DerivedData, so the second fails with "database is locked". Sharing only for
  `exec` is worth considering.
- **Host disk grows without bound across worktrees.** Each new worktree gets up to `pool` full
  checkouts plus their build output, and nothing ages them out; `flightdeck host prune` is the only
  cleanup, and it is fleet-wide. An LRU age-out of idle slots in the hourly `gc` would bound it.

**Controller adapters**
- A replay is recognised when offsets go backwards or a state event arrives, so a `queued`→`started`
  landing just before the replay begins can be taken for its start and leave a hole in the copy
  until the next replay.

**Channel mux**
- The unclaimed-channel cap is skipped once an `accept()` stream exists (controller side only).
- `closedIDs` grows by one tombstone per channel ever closed on a connection; a busy forwarded
  port accumulates them until the link drops. Tombstoning only above a low-water mark would bound it.
- Throughput is about one 256 KiB window per round trip per channel (about 5 MiB/s on a 50 ms
  tailnet path). A larger or adaptive window is the lever if bundles or forwards prove slow.

**Sync and results**
- `ResultApplier`'s `.git` check is case-insensitive but does not cover HFS-ignorable Unicode
  variants; git's own `verify_path` does, at checkout.
- A symlink planted *during* an apply makes it throw `unsafe_path` after earlier paths were written,
  and a time-of-check gap remains between the parent walk and the rename (Foundation has no portable
  `openat`/`O_NOFOLLOW` write).
- An apply stages the result inside `.git`, using about the result's size until it finishes.

**Runner**
- A pty run's output ends at the first quiet 100 ms after the leader exits; a later write is cut off
  (Darwin discards unread master output once the slave closes).
- In a Linux container, where PID 1 never reaps, a zombie grandchild counts as dead. A hostd under
  systemd should be unaffected, but that is unverified (see "Unverified live" above).

**Config and routing shims**
- The shim's probe watchdog (`sleep 2`) can linger up to 2 s after the probe returns; `exec sleep`
  would end it with the probe.
- The inline-table deep-key test asserts only that it throws.
- A CLI found on `PATH` (not this build's) costs one extra process start per routed command for the
  `route-exec` probe.
- `recipe add` drops comments inside the recipe's own table when it replaces it, and cannot replace a
  recipe defined only through root-level dotted keys (it throws rather than duplicate it).
- The TOML subset has no multi-line strings, floats or dates; each is a parse error naming its line.
- `delegate.toml` is parsed on the main actor once per tab launch (and per `.flightdeck/` change);
  small files, but a restore of many tabs in one project parses it once per tab.
- Route matching exists twice: the app uses HostKit's `RouteMatcher`, the CLI (which does not link
  HostKit) a copy held to the same answers by `DelegationRouteParityTests`.

**Preflight and port forwarding**
- On a failure after step 4, `release()` returns before the listeners have closed; awaiting
  `released()` (or fixing the comment in `Preflight.run`) would make it exact. `released()` has no
  timeout.
- An established connection with no listener makes the local bind retry for 30 s and then report
  TIME_WAIT, which is the wrong reason.
- The `MemoryPipe` test fake can spin.
- `testForeignTimeWaitIsRetriedUntilItClears` costs about 30 s per run: the kernel's TIME_WAIT.

**App service and CLI**
- After a `slow_reader`, the app keeps the dead `cid`'s subscriber until the run ends (its replies
  are dropped).
- The CLI's 30 reconnects (about 30 s) after a dropped app are a guess at how long a relaunch takes.
- A `long` recipe is known only to the app, so the CLI reads `recipe.ls` first to set `detach`. If
  that read fails while the run succeeds, the CLI waits for a terminal frame that never comes.

**Agent skill and plugin reload**
- **The first launch after this merge sends `/reload-plugins` to every idle adopted claude tab:** a
  missing fingerprint counts as changed. Intended, but expect it.
- The fingerprint is recorded at launch, before any tab is reloaded: a crash before then costs those
  tabs their reload until the next plugin change.
- Deleting the whole `flightdeck-delegate/` directory (sidecar included) reinstalls the skill; the
  permanent opt-out is deleting `SKILL.md` and keeping the sidecar. The skill also survives an app
  uninstall. The maintainer may want a Preferences opt-out.
- `CodexDelegateSkill`'s `CODEX_HOME` environment fallback is dead code (it matches the app's
  convention elsewhere).

**Tests and tooling**
- `scripts/test-unit.sh`'s class check can report a real class as unknown under load
  (`printf … | rg -qx` under `pipefail`: `rg -q` exits on its match and `printf` takes SIGPIPE).
  Suggested fix: `rg -qx "$cls" <<<"$ALL_CLASSES"`.
- `PromptDeliveredLoopbackTests.testPromptTypedFollowsTheAckOverTheWire` is load-flaky (passes alone
  and with the delegation contract reverted).
- **"Listeners are released after any later failure" is checked only against a recording fake**
  (`testEachFailureStopsLaterStepsAndReleasesPorts`), never with real sockets; this is the same gap
  as the `release()`-before-close minor under Preflight.
- `DelegationServiceTests` runs its fake service with real-time replay thresholds
  (`replayIdle: 0.05`, `replayFirstEvent: 0.2`), which can be tight under heavy load, and two
  negative assertions (`testLongRecipeDetaches`, `testAReattachHasNoTimeout`) wait 20–30 ms for
  something not to happen, so under load they pass without proving anything.
- `testRunSurvivesControllerDrop` drops the link with a graceful `link.stop()`, not a half-dead TCP
  connection; the ping timeout path (three missed pings) is covered only by `HostLinkTests`.
- The in-process `DarwinHostServer` in the loopback tests advertises itself over Bonjour as "mini"
  on the LAN for the test's duration, so it can rename-collide with a real host named "mini".
- `test-hostd-linux-interop.sh run|serve` publish `127.0.0.1:47410`, which this Mac's own hostd
  holds while Hosting is on (AGENT-OPERATIONS.md says to turn it off first). The script could check
  the port and refuse with that advice instead of failing later.
- The HostKit `Delegation/*` file headers still say "Implemented by track Cn", which means nothing
  after the merge.

## Hidden tabs and idle polling CPU (2026-10-05)

After the probe fix below, a `sample` of 78 tabs still showed Ghostty's renderer threads at 63.6%
of a core. Of their busy samples, 782 of 855 were in `Metal.surfaceSize()` property reads, ahead
of frames with nothing to draw. libghostty starts every surface focused and visible, and keeps a
display link (a redraw at screen refresh) running for that pair. Upstream turns it off from
`syncFocusToSurfaceTree`, which this app does not have, so every tab restored at launch and never
shown kept its link running. **Fixed:** a surface starts hidden and unfocused, and is marked
hidden and unfocused again whenever it leaves a window (`TerminalPane` detaches every tab but the
selected one). Attaching it and making it first responder turn both back on.

`SessionSleepController.tick` read a pidfile and walked the process tree for every idle tab
every 500ms: ~5% of a core on the main thread. **Fixed:** the cheap policy gates run first, and
the lookups run at most every 5s (`evaluationInterval`). The idle clock is still kept every tick.

Still open: whether smart sleep can ever sleep a claude tab whose agent has MCP-server children.
`hasLiveDescendants` counts them, and that is unverified.

**Later the same day, also fixed:** `TranscriptWatcher` opened every tab's transcript every tick
just to learn it had not grown (~1.5% of a core in `FileHandle` construction alone). It now
skips the tick on a `stat` (`TailReader.hasNothingNew`). And the intake attention badge and
`resumeIfStalled` each re-read `commands.jsonl` per call (~2.6% of a core). That answer is now
memoized on the file's stat and the tape's ack. After all of this, Flight Deck idles at
roughly 5–10% of a core with 78 tabs.

### Not done: event-driven status registry (FSEvents)

**What it costs today.** `SessionStatusWatcher.drain` runs on every `WatchClock` beat: 500ms
when the app is active, 2s in the background. Each run lists `~/.claude/sessions/` (57 `.json`
files and 114 entries on 2026-10-05, including leftovers from dead pids), calls
`kill(pid, 0)` for every file, and reads each file's mtime with `resourceValues`. It decodes only
the files whose mtime moved, then hands the whole map to `SessionStore.applyRegistry`. Measured
over 10s with 78 tabs: `drain` 55 samples plus `applyRegistry` 49, about 1.9% of a core on the
main thread. Small, but it is the largest remaining fixed per-tick cost, and it grows with the
number of status files, not the number of tabs.

**What an event-driven version must handle.** These are the facts that shape the design; the
first one rules out the obvious approach:

1. **claude writes status files in place.** Birth time precedes mtime by hours on every live
   file, so updates are not atomic renames. A `DISPATCH_SOURCE_TYPE_VNODE` source on the
   *directory* fires on create, delete and rename only, so it would miss every status change.
   Either use FSEvents with `kFSEventStreamCreateFlagFileEvents` on the directory, or keep one
   vnode source per file (`.write | .extend | .delete | .rename`) and re-arm them as files come
   and go. FSEvents is the simpler of the two. Use a short latency (~0.1s) so a `waiting` edge
   is not delayed: the phone card and the notification both hang off it.
2. **Process death does not touch the file.** A crashed claude leaves its `<pid>.json` behind,
   which is why `drain` calls `kill(pid, 0)` for every file. Events alone would leave a dead
   session showing its last status forever. Pair the watch with `EVFILT_PROC`/`NOTE_EXIT` per
   pid (a `DispatchSource.makeProcessSource`), or keep a slow liveness sweep (every 5–10s).
3. **The tick must not disappear entirely.** `commitStatuses` drives time-based state, not just
   file edges: the stuck-prompt episode and its `answerless` rung at 5s
   (`stuckPromptReportLadder`) and `checkStuckPrompts`' report ladder. Something must still run
   them while any tab is `waiting`. A timer armed only while a `waiting` episode exists is enough.
4. **Accounts multiply the roots.** `startStatusWatching(account:)` starts one watcher per
   claude account home, so it would be one stream per root. Codex status comes from
   elsewhere (`CodexRolloutWatcher`, `CodexNameWatcher`), which is out of scope here.
5. **Keep `drain()` as the reconciler.** Have events *schedule* a `drain()` (coalesced onto the
   main actor) instead of parsing individual events. The mtime cache already makes a no-change
   drain cheap, the existing tests drive `drain()` directly, and FSEvents may drop or coalesce
   events (`kFSEventStreamEventFlagMustScanSubDirs`), which a full drain absorbs.

**Expected win:** most of that ~1.9%, plus fewer main-thread wakeups while idle, which matters
more for energy than for CPU percentage. **Why it was not done:** it touches the status spine
every phone and notification feature depends on, for under 2% of a core. Worth doing alongside
other work in `SessionStatusWatcher`, not on its own.

## Open-prompt probe CPU (2026-10-05)

A tab that claude reported as `waiting` ("permission prompt") had no open call in its transcript.
The last conversational record was plain assistant text, followed by 112 bookkeeping lines, and
the file was last written 53 minutes before the status flipped. Every registry tick widened the
probe to the pager's scan ceiling: the whole 7.1 MB file, twice, every 500ms, on the main actor.
Flight Deck sat at ~112% CPU (`sample`: 92% of main-thread samples under
`PromptService.pushedOpenPrompt`). **Fixed:** the push-side probe caches on the transcript's
`stat` (inode, size, mtime), so an unchanged file costs one `stat` a tick. A widen runs off the
main actor and recommits through `SessionStore.recommitStatuses` when it lands. The answer path
is still uncached.

Still open:
- **Explained: the dialog belonged to a background subagent.** A live screen capture of the same
  tab showed "Bash command · from the implementer agent" ("Dangerous rm operation on
  statically-unresolvable target", which bypass mode still asks about). claude draws a background
  subagent's permission dialog in the parent's TUI and sets the parent `waiting`, but writes the
  `tool_use` to `<conversation>/subagents/agent-<id>.jsonl`. The registry flipped 70ms after the
  subagent wrote the call. "Blocking tool_use is written at raise" still holds, just in another
  file. The 5s `answerless` debounce then made the Mac and phone say "Still working (no response
  needed)" over a real dialog for 90 minutes. **Fixed:** `PromptService` checks the subagent
  transcripts the tab's current claude process has written, and refuses `subagent_prompt` rather
  than `prompt_changed` when one ends on an unresolved call, so `answerless` does not fire and
  claude's own "Waiting for you — permission prompt" stays up. Cost on the live 238-file
  directory: 1.2ms a tick while the tab is in that state.
- **A subagent's dialog still cannot be answered from the phone.** The phone derives its card
  from the parent's feed, which does not hold the call, and the Mac cannot tell the blocked
  subagent from one that is merely running a tool (both end on an unresolved `tool_use`). The
  dialog header names the agent *type*, not its id. A `PermissionRequest` hook (not registered by
  the plugin today) or reading the dialog header off the screen could disambiguate. Either needs
  a wire decision, because the prompt is derived on both ends and never sent.
- **The registry poll itself** (`SessionStatusWatcher.drain`, mtime-cached) and the rest of the
  tick were ~4.5% of a core in the same sample. An FSEvents or `DISPATCH_SOURCE_TYPE_VNODE` watch
  on the status directory could replace the 500ms rescan. Not done: it is a separate, smaller win.

## UI suite on the UI-test Mac (2026-10-06)

`smoke.sh` now runs on the UI-test Mac; see AGENT-OPERATIONS.md §5. The failures
it still reports there, each diagnosed from the run's `.xcresult` screen recording:

- **Both codex tests: the UI-test Mac's environment.** an older codex-cli is below
  `CodexProcessTransport.minimumVersion` (0.142.4), so creating a codex session is refused and the
  tests fail with "creating a codex session added no row". Upgrading codex on the UI-test Mac fixes it.
- **`testProjectHeadingsReorderByDragging`, "clicking a project's chevron did not collapse it":
  macOS 15 sidebar geometry.** The recording shows the click landing just right of the chevron
  glyph and selecting the project instead. On macOS 15 the `NSTableRowView` starts at the window
  edge and the heading content (chevron at ~15–22pt) is inset 16pt inside it, so the test's
  "element left edge + 10pt" is 26pt into the row, past `SidebarClickIntent.chevronZoneWidth`
  (22pt). The test's comment assumes the row edge is "a few points" left of the element, which
  is true of macOS 26. This is also a product issue on macOS 14/15 (the deployment target is
  14.0): the collapse target there is roughly the glyph alone. Measuring the zone from the
  heading's content edge rather than the row view's would fix both; not done here because it
  changes product hit-testing and needs a run on macOS 26 too.
- **`testTheWholeShellInOneSession`, "dragging blank row space did not reorder either": macOS 15
  accessibility frames.** `blankSpace(inRow:)` presses 40pt right of the session title's frame;
  on macOS 15 that frame spans the cell, so the press lands in the terminal pane (visible in the
  recording), and the title-drag group after it has no control to stand on.
- **Same test, "the context menu renames a session": undiagnosed.** The Rename menu item is
  clicked, no `session-title-field` appears, and the recording shows the session order changing
  (to 3, 2, 1) at that moment, as if a drop from the earlier drag groups landed late. Not chased
  further within the time box.
- **`testPermissionBypassConfirmationUnderChurn` (the flake hunt) on the UI-test Mac:** fails at once with
  "Unable to find hit point for ScrollView" at y≈2600: the Preferences command field is off the UI-test Mac's
  1125pt-tall screen. A screen-size environment failure, not the race it hunts.
