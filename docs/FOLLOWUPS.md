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
