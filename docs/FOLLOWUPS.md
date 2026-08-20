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
boundaries and the app-wide `session_index.jsonl` for renames. Spec:
[superpowers/specs/2026-08-19-codex-rollout-observation-design.md](superpowers/specs/2026-08-19-codex-rollout-observation-design.md).
Everything below was found by that branch's reviews, triaged, and deliberately not fixed.

### Fixed

- **`codex resume` failed against a live app-server on codex-cli 0.148.0 — FIXED.** Codex
  holds a writer lock on a thread, and the interactive TUI refused with `thread/resume
  failed: thread <id> already has an active writer (code -32600)`. Flight Deck keeps ONE
  long-lived app-server (a thread belongs to the process that created it) and then spawns
  `codex resume <id>`, which is exactly the refused shape — so codex tabs appeared unable to
  launch on 0.148. Reproduced directly in that production shape; the adapter was built
  against 0.142.4/0.147.0, and `~/.codex` now has a `thread-writer-locks` directory, so this
  looked like newer codex behaviour rather than a regression here.

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

- **No relay**, so reaching the Mac from off-LAN needs a VPN. Designed for as a further
  candidate endpoint (spec §3, §12), not built in either plan.

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

- **PSK slot misattribution with 2+ paired devices — real, found while writing the
  `onAttachedSlotsChanged` two-device regression test the review asked for.** Corrects the
  "Neither documented fallback was needed" bullet directly above (2026-08-19 section); this is
  the full writeup that bullet points to.

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

  **Also crashes the test host.** A fuller version of the reproduction above — two clients,
  one client disconnecting after both are attached — twice produced a reproducible `SIGABRT`
  ("freed pointer was not the last allocation") during XCTest's tearDown, crashing the whole
  `xctest` process rather than just failing an assertion (crash reports captured under
  `~/Library/Logs/DiagnosticReports/xctest-*.ips`; faulting thread inside Swift Concurrency's
  `_swift_task_dealloc_specific`). Not root-caused further — this needs its own investigation,
  separate from the misattribution — but it means any test exercising 2+ PSK keys with 2+ real
  connections and a disconnect can take down an entire `test-unit.sh` run, not just itself.
  No such test is checked in for exactly this reason.

  Two fixes were sketched and deliberately not attempted here (out of scope for "add a
  regression test," and this is the TLS/security layer): have the client self-report its slot
  in `hello` and verify it cryptographically against the negotiated secret (this plan's Task 4
  named exactly this as the documented fallback, before the 2026-08-19 entry wrongly declared
  it unneeded); or correlate `sec_protocol_options_set_pre_shared_key_selection_block` (a
  client-hint API, so this direction is unconfirmed) against `ObjectIdentifier`s per
  connection. Needs sign-off before either is attempted.
