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

- **`SWIFT_VERSION: "5.0"`** in `project.yml` (Swift 5 language mode under the Swift 6.3
  compiler) — chosen to compile the vendored Ghostty code without Swift-6 strict-concurrency
  breakage. Diverges from the plan's `6.0`/spec's "Swift 6"; revisit only if Flight Deck's own
  code is later isolated into a Swift-6 module separate from the adapted Ghostty sources.
- **Non-sandboxed entitlements** (no `app-sandbox`, `disable-library-validation` on) — required
  for a terminal linking a non-notarized static `libghostty`.

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

  `SessionRow.handleTitleTap()` now uses a single tap recognizer and detects the second
  click itself against `NSEvent.doubleClickInterval`, which takes SwiftUI's gesture
  arbitration out of the problem entirely. Guarded by an assertion in
  `testCommandNAddsASessionBelowTheActiveOne` that clicks the title and requires the row to
  become selected, plus `testDoubleClickRenamesSession` for the rename path.

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

Two bugs shipped from this, both reported by Nate against the merged build:

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

**Rule for anything added to a sidebar row: no tap gestures.** Use a `Button` on a small
control, or a context menu. Both leave the primary mouse-down alone.

Open, and a UX regression worth a decision: **double-click no longer renames a session.** It
was traded for drag-by-title. Finder's own arrangement is Return-to-rename with double-click
reserved for open, so Return would be the natural replacement — but it is not implemented, so
today rename is context-menu only. Candidate remedy: `.onKeyPress(.return)` on the list, or a
Rename item in the main menu via `SessionCommands` with `.keyboardShortcut(.return, ...)`.

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
  and clears it only when the settle work finishes, on every path out of that closure. The
  original writeup here reasoned about same-caller re-entry only — the registry tick's
  ~500ms poll against a 120ms settle — and judged it safe. That reasoning did not cover the
  other caller: `rename()` runs off a direct keystroke with no interval to race against, so
  a rename landing inside a queued prompt's settle window (or vice versa) could still send a
  second Ctrl+U into a viewport the first settle was mid-comparison against. The guard now
  lives inside `inject` itself, so it covers both callers instead of being restated in each.

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
- **`ConversationPin.resolve`'s `workingDirectory:` parameter is misnamed — rename deferred,
  deliberately.** Since the split it is fed, and echoes back, the tab's *transcript*
  directory; passing its `workingDirectory` would move a worktree session's watcher onto the
  project's transcript the first time a row omitted its `cwd`. The label survives because it
  is not local to that one function: `ClaudeSession.transcriptURL(sessionID:workingDirectory:)`
  carries the same label with the same "directory `claude` is running in" meaning, across two
  source files and four test files, and `ConversationPin.Resolution` carries it as a field
  name too. A coherent rename is therefore a multi-site production change (`transcriptDirectory:`
  everywhere, or nothing), which does not belong in a documentation pass. Until it happens the
  warning is written where a caller will hit it: a `- Parameter` doc on `resolve` itself and a
  field comment on `Resolution.workingDirectory`, rather than only at the one call site in
  `SessionStore.applyRegistry`.
