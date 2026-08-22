# Flight Deck — Architecture (as built)

This describes the code **as it exists today** (the walking skeleton). For the intended
full design and the reasoning, see the [design spec](superpowers/specs/2026-07-09-flight-deck-design.md).

## The spine

```
FlightDeckApp (@main SwiftUI App)
  ├─ SessionStore (source of truth)
  │   ├─ owns/retains → Ghostty.SurfaceView (per session)
  │   └─ weak ref    → GhosttyApp.shared (libghostty)
  └─ RootWindow (Scene / Window)
       └─ RootView (NavigationSplitView)
            └─ TerminalPane (NSViewRepresentable)
                 └─ hosts → Ghostty.SurfaceView (from SessionStore)
```

- **`FlightDeckApp.swift`** — `@main`, just declares the scene.
- **`RootWindow.swift`** — a `Window` (not a `WindowGroup` — that would claim ⌘N) rendering `RootView`.
- **`TerminalPane.swift`** — the SwiftUI↔AppKit bridge. It hosts whichever surface `SessionStore` has selected: `updateNSView` detaches any surface that isn't the current selection (the Store keeps it retained, so its shell keeps running off-screen) and re-parents the selected one into a `TerminalHostView` rather than recreating it, so tab switching doesn't restart the shell. `TerminalHostView` is an `NSView` subclass that forwards frame changes to `Ghostty.SurfaceView.sizeDidChange(_:)`, which is what makes the terminal grid reflow on resize.
- **`ShellResolver.swift`** — pure helper: `SHELL` env → `/bin/zsh` fallback. TDD'd (`Tests/FlightDeckTests`).

## The reuse boundary: `Sources/FlightDeck/GhosttyEmbed/`

This directory is the crux of the "reuse Ghostty" approach. Ghostty's Swift `SurfaceView`
module could **not** be reused by reference — it hard-references app-shell types
(`AppDelegate`, `BaseTerminalController`, `TerminalWindow`, `SplitTree`, `SecureInputOverlay`,
`QuickTerminal`) that transitively pull in ~82 files (essentially all of Ghostty's macOS app).

So the surface was **adapt-copied**: copied into `GhosttyEmbed/` as **Flight-Deck-owned, editable**
files and decoupled from the app shell.

| Kind | Files | Notes |
|---|---|---|
| **Adapted-copied, verbatim** | `SurfaceView_AppKit.swift` (2.2k lines), `Ghostty.Input.swift` (1.3k), `Ghostty.Surface.swift`, `Ghostty.Action.swift`, `Ghostty.Event.swift`, `Ghostty.Error.swift`, `Ghostty.Inspector.swift`, `Ghostty.Shell.swift`, `GhosttyPackage.swift`, `SecureInput.swift`, `NSEvent+Extension.swift`, `Helpers/**`, the `ObjCExceptionCatcher`/`VibrantLayer` ObjC pairs | Each carries `// Adapted from ghostty v1.3.1: <path>` (Ghostty is MIT). Byte-identical to vendor modulo the provenance header. **Treat as vendored-ish**: prefer re-pulling from upstream over hand-editing, except for deliberate decoupling. |
| **Adapted-copied, edited (decoupling)** | mostly `SurfaceView_AppKit.swift`; also `GhosttyPackage.swift` | Dropped: session-restoration/`Codable`, focus-follows-mouse, app-menu key forwarding, "Change Tab Title", `DerivedConfig` reduced to defaults, the `SplitTree` extension. `AppDelegate.logger` → `Ghostty.logger`. |
| **Hand-extracted** | `SurfaceConfiguration.swift` | `SurfaceConfiguration` / `SearchState` / `moveFocus` lifted out of Ghostty's dropped SwiftUI wrapper. |
| **Hand-written (Flight Deck's own)** | `GhosttyApp.swift` (~100 lines) | Replaces Ghostty's app-coupled 2.2k-line `Ghostty.App.swift`. Does only what the surface needs: `ghostty_init` (process-once), `ghostty_config_new`+load+finalize (guarded), `ghostty_app_new` with runtime callbacks, `tick()`, and a `makeSurfaceView` factory. `deinit` frees app+config. |

Net: **~97% of `GhosttyEmbed/` is reused Ghostty code**; the Flight-Deck-authored delta is the ~100-line wrapper plus the decoupling edits.

## Linkage & build config (`project.yml`, XcodeGen)

- **`GhosttyKit.xcframework`** (the built `libghostty`, a static-lib xcframework) is linked via `dependencies: [{ framework: vendor/ghostty-artifacts/GhosttyKit.xcframework, embed: false }]`. The reused Swift files `import GhosttyKit`. **Not** a raw `-lghostty` + header-search-path setup.
- **`SWIFT_VERSION: "5.0"`** (Swift 5 language mode under the Swift 6.3 compiler) — required so the vendored Ghostty code compiles without Swift-6 strict-concurrency breakage. Deliberate; see FOLLOWUPS.
- **`OTHER_LDFLAGS: -lstdc++`** — `libghostty` statically bundles C++ (glslang); matches Ghostty's own project.
- **`SWIFT_OBJC_BRIDGING_HEADER: Sources/FlightDeck/BridgingHeader.h`** — imports the two owned ObjC headers (`ObjCExceptionCatcher.h`, `VibrantLayer.h`), which transitively expose Foundation/QuartzCore target-wide (Ghostty relies on this implicit-Foundation trick). `HEADER_SEARCH_PATHS` points at `GhosttyEmbed/`.
- **Entitlements** (`FlightDeck.entitlements`) are the non-sandboxed subset (no `app-sandbox`, `disable-library-validation` on) — required to link a non-notarized static `libghostty`.
- The `.xcodeproj` is **generated** by XcodeGen from `project.yml` and is git-ignored.

## Runtime model

- **Tick loop:** `libghostty` only advances when `ghostty_app_tick` is called. `GhosttyApp`'s `wakeup` callback does `DispatchQueue.main.async { tick() }` (thread-safe), and `TerminalPane` kicks an initial tick so the first frame renders.
- **Retention:** one process-wide `GhosttyApp.shared`, held **weakly** by `SessionStore` (the store must not co-own a static that already owns itself for the life of the process). **This is the thing to change before multi-window/multi-session** — see the teardown-lifetime item in [FOLLOWUPS.md](FOLLOWUPS.md).
- **Shell launch:** the surface's PTY forks `ShellResolver.resolve()` in the session's `transcriptDirectory` — the same field the transcript watcher reads, not the project the row is filed under, so a restored `claude --resume` runs where its conversation actually lives (verified: `FlightDeck → /usr/bin/login → -/bin/zsh`). The two are equal until `claude` changes directory to somewhere the tab does not follow — a git worktree, a plain `cd`, or a resume into a conversation whose project is not open — since the transcript follows every reported cwd while the row is refiled only into an already-open project.
- **Surface sizing:** `TerminalPane`'s container is a `TerminalHostView`, an `NSView` subclass
  that forwards frame changes to `Ghostty.SurfaceView.sizeDidChange(_:)` — the call that
  reaches `ghostty_surface_set_size`. It exists because that method's upstream caller lives in
  the `SurfaceScrollView`/SwiftUI wrapper this app dropped during decoupling, so without the
  hook nothing calls it and the terminal never reflows. `updateNSView` reports the size on
  every update, not just on attach: re-parenting is how tab switching works, so a surface last
  shown at a different window size would otherwise carry a stale grid.

## Preferences

`Sources/FlightDeck/Preferences/` holds a pure core and a SwiftUI shell over it.

The core is a declarative `FlagSpec` catalog (`ClaudeFlagCatalog`, a snapshot of
`claude --help` at 2026-08-11) plus four pure functions: `ClaudeFlagQuoting` (tokenize /
quote), `ClaudeFlagParser` (text → `FlagSet` + diagnostics), `ClaudeFlagSerializer`
(`FlagSet` → text), and `FlagSetMerge` (project over global, per flag). The invariant
`parse(serialize(x)) == x` is what makes the two-way sync between the controls and the
command field safe; it is pinned in `ClaudeFlagSerializerTests`. Two details of that
invariant are load-bearing: `ClaudeFlagSerializer.serialize` emits the **passthrough run
first, then catalog order** — a list flag consumes every following non-flag token, so a
*trailing* passthrough run would get silently absorbed into it — and `ClaudeFlagQuoting`'s
tokens carry `wasQuoted`, with the parser refusing to read a quoted token as a flag. That is
what lets a value like `--verbose` on `--system-prompt` round-trip correctly; quoting alone
cannot fix it, because the parser never sees the quotes.

`PreferencesStore` (owned by `FlightDeckApp`, constructed **before** `SessionStore` because
that store restores inline) persists to `UserDefaults` behind `PreferencesPersisting`.

Sessions do **not** share that store. `SessionStore` persists through `SessionPersisting` to
`~/Library/Application Support/Flight Deck/sessions.json` (`FileSessionPersistence`, atomic
write, one-shot migration from the old `sessions.snapshot.v1` defaults key). The split is
deliberate: `defaults delete <domain>` is a routine debugging gesture that used to take the
whole session graph with it, `cfprefsd` coalesces writes so a `SIGKILL` could drop the last
one, and the snapshot grows with sessions × projects. Preferences have none of those
properties, so they stay where they belong.
`SessionStore.insertSession` reads it once per session at creation: preferences configure
*new* sessions and never reconfigure a running one.

Project overrides are keyed by standardized path in `Preferences.projectFlags`, not held on
`Repo` — closing a project (`SessionStore.closeProject`) removes its `Repo` outright, and an
override must outlive that so it is still there if the same path is reopened later.

Unknown flags are preserved verbatim in `FlagSet.passthrough` and warned about rather than
rejected, so a `claude` release that adds a flag does not make the field lossy.

## Vendored layout (git-ignored build inputs/outputs)

- `vendor/ghostty` — submodule, pinned **v1.3.1** (`332b2ae`), pristine (never modified).
- `vendor/ghostty-artifacts/GhosttyKit.xcframework` — build output of `scripts/build-libghostty.sh`.
- `vendor/.zig-toolchain/` — Zig 0.15.2 (auto-downloaded by the build script).
- `vendor/.build-shim/` — the `xcrun` SDK shim (recreated by the build script).
- `vendor/boringssl` — submodule, pinned to tag **0.20250114.0**, pristine (never modified).
- `vendor/boringssl-artifacts/BoringSSL.xcframework` — build output of
  `scripts/build-boringssl.sh`; same shape as `ghostty-artifacts`, built from the submodule
  rather than committed after an earlier attempt (54 MB) was reverted — see docs/FOLLOWUPS.md.

## Sidebar structure

`SessionSidebar` renders one flat `List(selection:) { ForEach(store.sidebarRows) { … } }` rather
than a `List` of per-project `Section`s. `SidebarRow` (`.project`, `.session`, and `.empty` for
an expanded project with no sessions) is what gets flattened: `.onMove` is not supported on a
`ForEach` that yields `Section`s, and flattening is what lets one drag gesture reorder both
projects and sessions instead of needing a second, hand-rolled `.draggable`/`.dropDestination`
mechanism just for project drags. `ProjectHeaderRow` draws the chevron, name, and (when
collapsed) the session count and status glyph in place of the system group header a `Section`
would have drawn, so nothing about the on-screen result actually needed `Section` to begin with.

`SidebarReorder.apply` holds the whole reorder policy — what a drag of a given row may legally
move to, and what it does to the projects it passes over — as a pure function over
`[Repo]`/`[SidebarRow]`/index set, so it is unit-tested without instantiating any SwiftUI.
`SessionStore.moveSidebarRows(fromOffsets:toOffset:)` is the `.onMove` target and only applies
the result.

A project's lifetime is explicit, not derived: a `Repo` appears when added
(`SessionStore.addProject`) or when a session lands in it (`moveSession`), and is removed only
by `SessionStore.closeProject`, which closes each child session through `closeSession` and then
drops the `Repo`. `closeSession` no longer prunes an emptied project on its own — an emptied
project stays in the sidebar until its own close button removes it. That settles a
disagreement the two methods used to have: `closeSession` used to prune an emptied project while
`moveSession` always deliberately left one standing; both now agree that an empty project does
not vanish by itself. The close button itself is not immediate: `ProjectCloseCoordinator` asks
`ProjectCloseConfirmer` (a real `NSAlert` in production, behind a protocol seam for tests) to
confirm whenever a project holds more than one session, unless the user has suppressed that
prompt.

Project order and collapsed state (`Repo.isCollapsed`, toggled by `SessionStore.setCollapsed`)
survive a relaunch through `SessionSnapshot.projects: [Project]?` — each entry is a path plus
`isCollapsed`. It is optional for the reason `Entry.pinnedConversationID` is: a non-optional
field would throw on every `sessions.json` written before this change and wipe every session on
the first launch after it. `nil` decodes as "no recorded project state", and restore falls back
to session-encounter order with every project expanded.

## Session status pipeline

Sidebar rows show what each Claude session is doing. Two sources feed one map:

```
<account home>/sessions/<pid>.json ──> SessionStatusWatcher ──┐
  (Claude's own status registry,        (one per claude        │
   polled; see the design spec)          account, 500ms poll,  ├──> SessionStore.statuses
                                         keyed by sessionId)    │      [UUID: SessionStatus]
<transcript>.jsonl ────────────────────> TranscriptWatcher ────┘             │
  (outstanding Agent tool_use ids,        (one per session)                  v
   cleared at each turn boundary)                                   SessionStatusIcon
                                                                     SessionNotifier
```

`<account home>` is `CLAUDE_CONFIG_DIR` for that session's account (`~/.claude` for the
built-in login) — resolved once per tab from the account the launching session runs as, not
a fixed constant. Before the 2026-08-19 accounts work every tab shared one app-wide watcher
rooted at `~/.claude/sessions`; now `SessionStore` keeps one `SessionStatusWatcher` per claude
account (`statusWatchers[account]`), built on first tab and stopped when that account's last
claude tab closes, so two logins' registries are never merged into one scan.

- **`ClaudeStatusFile`** — pure decode of one registry file. Fails closed: an unknown
  `status`, a torn read, or a pid/filename mismatch all yield nil, and the watcher keeps
  its last known value. The registry is undocumented and unversioned, so this is the
  compatibility boundary.
- **`SessionStatusWatcher`** — polls rather than watching vnodes because `claude` rewrites
  the file in place with no create/rename, so a directory watch would never fire.
- **`SessionStore`** — merges registry activity with transcript-derived sub-agent counts and
  drops sessions Flight Deck does not own. Each tick computes the edges once, as
  `[StatusTransition]` (`old`/`new` status per tab), and hands that same list to three
  consumers: `applyReadState` (the sidebar's unread dot), `deliverNotifications`
  (`SessionNotificationPolicy`), and `cancelSupersededPrompts` (drops a queued "Keep going"
  the moment a resumed session reports `busy` or `waiting` on its own). `persist()` runs
  after all three, so the on-disk snapshot's `activity` and `unread` fields reflect the same
  tick the sidebar just drew.
- **`SessionNotifier`** — behind the `Notifying` protocol, because
  `UNUserNotificationCenter.current()` traps outside a signed bundle and would take the
  unit-test bundle down.

Full field shapes, the decompiled status derivation, and accepted limitations are in
`docs/superpowers/specs/2026-08-11-session-status-indicators-design.md`. The persisted
`activity`/`unread` fields and the auto-resume prompt built on top of them are in
`docs/superpowers/plans/2026-08-15-auto-resume.md`.

## Tab navigation

⌘⇧[ / ⌘⇧] move the selection along `repos.flatMap(\.sessions)` — the sidebar's session order
crossing every project — wrapping at both ends. This does not skip a collapsed project's
sessions; they are still selectable, just not currently drawn. `SessionStore.selectNextSession()` /
`selectPreviousSession()` are the entry points; the wraparound algorithm lives in the private `cycleSelection(forward:)`. `TabNavigationCommands` supplies the Window-menu items.

The menu items are the *mechanism*, not decoration. AppKit gives the Ghostty surface's
`performKeyEquivalent` first refusal, and libghostty binds both shortcuts by default — but as
`consumed`-only bindings, which `MenuKeyEquivalents` routes to the main menu first. Before this
feature the keys were claimed by the surface and the resulting `previous_tab`/`next_tab` action
went nowhere.

## External tools

`Sources/FlightDeck/Tools/` runs a shell command template — an editor, a terminal, a git
client, anything the user configures — against whichever session is selected. A tool
(`ToolDefinition`) is a name, an SF Symbol, a command template and an optional recorded
chord. Two ship by default, Editor (`$EDITOR ${cwd}`, ⌘O) and Terminal (a probed terminal
emulator, ⌘T); users add their own in the Tools preferences pane.

The spine: `ToolsMenuController` (the AppKit Tools menu) and `ToolOverlay` (the buttons that
fade in over the terminal) both call `ToolRunner.run(_:store:launcher:)` — the one path that
keeps a menu launch and a button launch from drifting apart. `ToolRunner` reads
`SessionStore.toolContext()`, expands the tool's command with `ToolTemplate.expand`, and
hands the result to a `ToolLaunching` (`ShellToolLauncher` in production), which runs it as
`$SHELL -lc <command>`, detached, with `currentDirectoryURL` set to the resolved working
directory. The login shell rather than a bare `Process` invocation because Flight Deck
launched from Finder has no `$EDITOR` and no user `PATH` — `-lc` sources the profile, so a
template behaves exactly as it would if typed into a terminal.

**`SessionStore.toolContext()` is the only bridge into the tools subsystem.** Every agent
fact it carries — working directory, conversation id, transcript path — comes from
`AgentAdapter.location(for:)`, never from `Session.transcriptDirectory`,
`Session.transcriptPath` or `Session.pinnedConversationID` directly, and nothing under
`Sources/FlightDeck/Tools/` calls `ClaudeSession`. That mirrors why `ClaudeAdapter`
deliberately keeps `encodedProjectDirName` off the protocol: a claude-only path-derivation
detail has no business being reachable from the tools subsystem, or from any future adapter.
`location(for:)` is a required protocol member with no default, so a future adapter cannot
silently inherit another agent's working-directory logic — the compiler makes it answer for
its own.

**The Tools menu is AppKit, not a SwiftUI `Commands` group**, for the reason
`SessionCommands` already documents: SwiftUI cannot vary a `.keyboardShortcut` at runtime,
and a user-recorded chord is dynamic by definition. `ToolsMenuController` assigns each
tool's `ToolShortcut` straight onto `NSMenuItem.keyEquivalent` /
`keyEquivalentModifierMask`, which is a plain property and can change whenever the
preferences pane changes it. `MenuKeyEquivalents` covers the new menu with **no change at
all** — it walks the whole main menu and names no specific shortcut, so a Tools item added
after that file was written routes the same way ⌘Q already does.

**Being AppKit costs one thing, and it is not obvious: SwiftUI prunes the menu back out.**
SwiftUI owns `NSApp.mainMenu` and removes items it did not author, on a reconciliation pass
that runs *after* `applicationDidFinishLaunching`. So installing once always loses — the item
lands correctly between View and Window, and is gone a moment later from that same `NSMenu`
instance. The symptom is not a missing menu but broken shortcuts: with nothing to claim ⌘O,
`SurfaceView.performKeyEquivalent` returns false, AppKit re-dispatches the same event, the
`lastPerformKeyEvent` timestamp matches on the second pass, and the terminal receives a
synthesized keyDown carrying `characters` — a literal "o" in the running agent's prompt.

`ToolsMenuController` therefore keeps a weak reference to its host menu and observes
`NSMenu.didRemoveItemNotification`, re-inserting whenever its item disappears. A timed
re-install would have been enough at launch and wrong afterwards: SwiftUI rebuilds its
commands when observed state changes, and `SessionCommands` observes preferences, so editing
a tool can prune the menu again — killing the shortcuts at the exact moment the user
configures them.

**"Configure Tools…" opens Settings by driving SwiftUI's own menu item**, via
`SettingsMenuItem.locate(in:)`, rather than by sending `showSettingsWindow:`. That selector is
the widely-repeated recipe and here it is worse than broken: it **returns true** while opening
nothing, because something in the responder chain accepts it — so any fallback guarded on its
return value is unreachable. `sendAction` can only answer "did a responder accept this?", never
"did Settings open?". SwiftUI's item is wired to a private `menuAction:` on a private
`MenuItemCallback`, so the item itself is the only dependable handle; it is matched on the ⌘,
chord rather than its title, which is localized and was renamed in macOS 13.

Landing on the right pane is a second, separate mechanism: `PreferencesView`'s `TabView` is
bound to `PreferencesStore.selectedTab` with every pane tagged, and the menu sets `.tools`
*before* opening so the first build of the view already has it. `selectedTab` sits beside
`preferences` rather than inside it — that struct persists on every mutation, so a pane stored
there would rewrite `preferences.v1` on every tab click and reopen Settings weeks later
wherever the user last was.

**The overlay's fade is a clock-free state machine.** `ToolOverlayVisibility` owns no clock
of its own — every method takes "now" from its caller, `ToolOverlayModel` — so "fades after
five idle seconds" is a test that runs instantly rather than one that sleeps. It is driven
by one passive local `NSEvent` monitor, `ToolOverlayInputMonitor`, modelled on
`SidebarInputMonitor`: it never consumes an event, so terminal input and hit-testing cannot
change. Mouse movement is available over the terminal at all only because
`Ghostty.SurfaceView.updateTrackingAreas` installs an `NSTrackingArea` with `.mouseMoved` —
record that as a dependency on adapt-copied vendored code: a future re-pull of Ghostty that
drops the flag would break fade-in with nothing here failing to say so.

Command expansion (`ToolTemplate.expand`) is a pure function with three deliberately
distinct rules: a known variable (`${cwd}`, `${transcript}`, …) is substituted and
shell-quoted, so a path with a space stays one argument; a known variable with no value (an
agent that reports no transcript) becomes `''` rather than nothing, so the command cannot
silently absorb its next argument into the empty position; an unknown `${…}` is left
literal, braces and all, and reaches the login shell unchanged — which is what makes
`$EDITOR` and `${HOME}` behave exactly as they would if typed.

`ShellToolLauncher` drains a launched tool's stderr continuously from a background thread
rather than reading it after the fact: a `Pipe` has a 64 KiB kernel buffer, and a child
blocked writing to a full one still reports `isRunning == true`, so an un-drained pipe would
make a failed-but-verbose launch read identical to a successful one. A non-zero exit inside
a 2-second grace window is reported through `ToolLaunchFailureReporting`; still running past
that window counts as success.

## Fleet replication, pairing, and the phone (`FleetKit` / `Sources/FlightDeck/Fleet/` / `Sources/FlightDeckMobile/`)

The spine is live end to end and proven that way: a real client completes a TLS-PSK handshake
against a real listener, takes a snapshot of a live `SessionStore`, follows its mutations,
resumes after a drop and marks a session read — all inside `./scripts/test-unit.sh`.

The phone is built on top of that and **has never been run**. It is designed to take a code off
the Mac's screen — scanned, or twelve characters typed — find the Mac over Bonjour or by racing
remembered addresses, and show the running fleet in the terminal's own idiom: one project
section per open project, one row per session, renamed and marked read from either side. Every
part of that below the UI is covered by the macOS test suite, because it deliberately lives in
`FleetKit`. The screens themselves have never executed a line. `scripts/build-ios.sh` now really
*builds* the app target rather than type-checking it, which is what first put Swift 6's
region-based isolation over these sources and immediately found an error `-typecheck` had been
passing over for the life of the branch — but a build is not a run, and a simulator has no
camera in any case. `docs/MOBILE.md` carries the checklist of what a device would have to
confirm, and says plainly which parts are least proven. Plan 2 built the phone and the pairing
UI on top of the spine Plan 1 built (Plan 1:
`docs/superpowers/plans/2026-08-19-fleet-replication-spine.md`; Plan 2:
`docs/superpowers/plans/2026-08-19-fleet-pairing-and-ios.md`). The manual checklist for what
only a real device on a real network can prove is [docs/MOBILE.md](MOBILE.md). Three modules:

- **`Sources/FleetKit/`** — the wire types (`FleetSnapshot`, `WireProject`, `WireSession`), the
  delta vocabulary (`FleetEvent`), snapshot application, the replay fold, a hand-written frame
  codec, the TLS pre-shared-key parameters, both socket halves (`FleetSocketServer`,
  `FleetClient`), the pairing payload (`PairingPayload`) that the QR encodes, the typed code
  (`PairingCode`) and the pairing channel that carries it (`Pairing/`, over the SPAKE2 wrapper
  in `SPAKE2/`), and the phone's Keychain-backed pairing store (`KeychainPairedMacStore`) and
  network-discovery connector (`FleetConnector`). It imports only `Foundation`, `Network`, and
  `Security` — never `AppKit` — and that boundary is enforced mechanically, not by convention:
  the same source directory
  is also compiled as an iOS target (`FleetKitiOS` in `project.yml`, checked by
  `scripts/build-ios.sh`), so a stray `import AppKit` fails that build immediately rather than
  surfacing later as a phone-side compile error nobody is watching for.
- **`Sources/FlightDeck/Fleet/`** — the desktop side. `FleetProjection` is a pure read of
  `SessionStore` into wire shape. `FleetReplicator` mirrors the fleet from `SessionStore`'s
  event log and holds a bounded ring for replaying across a reconnect. `FleetService` is the
  only type that knows both a `SessionStore` and a socket — deliberately: `FleetSocketServer`
  stays testable with no store, `SessionStore` stays testable with no network, and everything
  that needs both is here where it can be read at once. `PairingArmer` is a pure state machine
  over an injected clock holding the one-slot-at-a-time arming window; the Devices tab
  (`Sources/FlightDeck/Preferences/UI/DevicesSettingsTab.swift`) is the only place a user can
  arm pairing, see who is attached, or revoke a device.
- **`Sources/FlightDeckMobile/`** — the phone app. `FleetModel` owns a `PairedMacStoring` and a
  `FleetConnector` and is the only thing either screen talks to; `PairingScreen` scans a QR (or
  takes a typed code, the only route that works on a simulator) and adopts it, `FleetListScreen`
  renders the replicated fleet. Most of `PairingScreen.swift` is its QR scanner
  (`AVCaptureSession` wrapped in a `UIViewRepresentable`), whose teardown path — stop the
  session, clear the delegate, let `deinit` run — took three review rounds to get right; see
  [docs/MOBILE.md](MOBILE.md) for what that history means for the manual checklist.

**The event log, and the drift assertion standing in for encapsulating it.** `SessionStore`
emits a `FleetEvent` for every change to `repos`, `statuses`, or `unreadIdle` (`unreadIdle` now
has a single private writer, `setUnread`, for exactly this reason), and `FleetReplicator` folds
that log into the mirror it hands a connecting client and the ring it replays across a gap.
Nothing in the compiler stops a future mutation site from touching one of those three fields
without recording its event, and the failure is not a crash — it is a client left silently and
permanently wrong until it happens to reconnect. Until `SessionStore`'s fleet state is
encapsulated behind a type whose every mutator records for itself (designed, deliberately
deferred:
[specs/2026-08-18-fleet-state-encapsulation-design.md](superpowers/specs/2026-08-18-fleet-state-encapsulation-design.md)),
`FleetReplicator` runs a `#if DEBUG` check after every batch — fold the log, project the store
fresh, and assert the two agree. It is an interim measure, not the design, but it is not
decorative either: it caught five real defects during this plan's own execution. It must not be
removed before the encapsulation replaces it.

**Accounts are deliberately not fleet state.** An account *is* a config directory —
`CLAUDE_CONFIG_DIR` / `CODEX_HOME`, where that login's credentials live — so `WireSession`
carries no account field and `FleetProjection` never reads `Session.accountID`, not even as an
opaque id. The wire already refuses `transcriptDirectory`, `transcriptPath` and
`pinnedConversationID` for the weaker reason that they are Mac path details; a config home is
the credential-adjacent case of the same rule, and `FleetAccountEmissionTests` pins it against
the serialized snapshot rather than field by field so a later addition to `WireSession` cannot
quietly reintroduce it. Nothing is lost by the omission: `accountID` is stamped once at
creation and never mutated, so there is no account change for an event to describe, and a
client that cannot open the Mac's filesystem has nothing to do with a home path anyway.
The one thing a phone *can* see is second-order — an orphaned tab (its login deleted between
runs) is restored but never launched, so it replicates as a session with `activity: nil`,
exactly like any other tab with no agent process behind it.

**One socket carries everything, because there is no HTTP tier to split it across.**
Network.framework has no HTTP server, and a listener carrying `NWProtocolWebSocket` can only
accept or reject a connection whole — there is nothing to route a request to within it. So one
WebSocket per attached client carries authentication, the connect-time snapshot, every live
event, and every command in both directions. `ack` means a command was *dispatched*, not that
it completed: typing into a pty has no delivery confirmation, so the observable effect always
arrives separately, as the same northbound `FleetEvent` a local mutation would have produced.

**TLS-PSK is the whole authorization story.** Pairing mints a `FleetDeviceKey` — 32 CSPRNG
bytes per device slot — and the listener registers every currently-paired key up front; the TLS
handshake itself is the credential check, with no separate token or login layer above it. Two
things about it cost real time to discover and are not documented anywhere but code comments:
Apple's PSK support is the **TLS 1.2** ciphersuite family
(`TLS_PSK_WITH_AES_128_GCM_SHA256`) — `sec_protocol_options_append_tls_ciphersuite` is
mandatory, and pinning a minimum TLS version of 1.3, which reads as obvious hardening, silently
breaks PSK instead, because the handshake then offers no suite the peer can agree to and simply
hangs. And a refused handshake presents as *silence*, not a `.failed` state: Apple drops a
mismatched identity rather than sending an alert, which closes off an identity oracle but means
"wrong key" and "network trouble" look identical from the client's side. One listener can hold
several devices' keys at once and picks the right one per connection from the PSK identity —
this was the plan's central open question, now verified, so revoking one device (delete its
slot's key, restart the listener) does not disturb any other paired device.

**Pairing is two paths onto one 2-minute window.** `PairingArmer.arm` mints a fresh
`FleetDeviceKey`, opens a 120-second window, and hands back a single `ArmedPairing` carrying
both presentations of it — a `PairingPayload` for the QR and a `PairingCode` for typing — as one
value, so a sheet cannot draw one window's code beside another window's QR. The QR is `FD2-`
plus Crockford base32 of a packed byte record: version, slot, the 32-byte key, one IPv4
endpoint, and the Bonjour instance name and display name length-prefixed. That is 98 bytes and
161 characters where v1's `flightdeck1:` base64url JSON was ~270, which measures as 45 QR
modules against 65 — the packing is what paid, not the alphabet. Both names stayed in it
because the phone learns neither anywhere else: `FleetSnapshot` carries no Mac identity at all,
and `FleetConnector` re-finds its Mac by matching Bonjour results against exactly that instance
name. The version digits are checked before any byte is decoded, so a code from a newer Mac is
refused as *too-new* rather than as *damaged* — the two failures send the user in opposite
directions. The window is enforced by the armer itself, not by the UI:
`PairingArmer.claim(slot:)` re-checks `armedUntil` against its own clock, so a code that expires
unscanned stays refused even if the sheet displaying it is still on screen.

**The window closes in exactly one place, and that is a rule with a scar behind it.**
`PairingArmer.clearPending()` is the only writer that nils `pending`, and it fires
`onWindowClosed`; `FleetService` hangs the pairing listener's teardown off that, which makes
"the listener's lifetime is the window's" mechanical rather than a convention. The enumerated
version — a teardown call beside every route that ends a window — shipped first and missed the
QR path, because that route clears `pending` inside an `if` whose second condition can fail
independently. A completed QR pairing left its listener up, and its code a live key, for the
rest of the window. The Mac advertises `_flightdeck._tcp` over Bonjour
(`NSBonjourServices`, `NSCameraUsageDescription`, and `NSLocalNetworkUsageDescription` are all
declared in `project.yml` — macOS 15+ and iOS both gate their respective access behind a user
prompt, and an app with no usage description never gets to show it, so the failure is silent
rather than a crash); the phone's `FleetConnector` finds the Mac by racing Bonjour resolution
alongside every endpoint the payload carried, live or dead, and keeps whichever answers first —
which is what roaming across Wi-Fi and cellular falls out of, with no stable hostname assumed
anywhere.

**Paired-device state is deliberately not the same shape on both sides.** The Mac keeps
`[PairedDevice]` — including a device's key — in `Preferences`, persisted as JSON in
`UserDefaults` alongside every other preference; the phone keeps one `PairedMac` in a single
Keychain item (`KeychainPairedMacStore`), updated in place rather than deleted-and-re-added so
there is never a window with no pairing on disk (`PairedMacStore.swift` has the reasoning
comment on why that shape was tried first and rejected). The Mac's copy is not Keychain-grade;
see docs/FOLLOWUPS.md.

**The typed code is that second path, and it has its own socket.** `FleetKit` links a vendored
BoringSSL, for exactly one function: SPAKE2, a password-authenticated key exchange CryptoKit
does not have. Hand-rolling one is not on the
table — the ways a PAKE goes wrong (point validation, transcript binding, non-constant-time
comparison) do not announce themselves in tests, and BoringSSL's implementation is the one
Chrome and Android ship. `vendor/boringssl` is a submodule, built by
`scripts/build-boringssl.sh` into the git-ignored `vendor/boringssl-artifacts/` — the same
arrangement `vendor/ghostty` already uses; see "Vendored layout" below.
`Sources/FleetKit/SPAKE2/BoringSSLShim.h` and its `module.modulemap` expose only SPAKE2 to
Swift, because importing `curve25519.h` directly would drop the whole of BoringSSL's namespace
into `FleetKit`, none of it reviewed for use here.

SPAKE2 itself produces keying material and **nothing else** — BoringSSL performs no key
confirmation, and a wrong password does not fail: it silently derives a different key.
`PairingSecrets` (`Sources/FleetKit/SPAKE2/PairingSecrets.swift`) exists to close exactly that
gap — an HKDF-derived confirmation value and sealing key, both bound to the transcript so a
proof or a sealed device key captured from one pairing window cannot be replayed into another —
and until both sides' confirmations match, nothing derived from the exchange may be trusted or
acted on. That is also what gives a three-attempt budget something to count: without an
explicit confirmation step, the Mac has no way to tell a typo from a correct pairing.

The code itself (`PairingCode`, `Sources/FleetKit/PairingCode.swift`) carries 55 bits of
entropy, and **that is not the security boundary — the attempt limit is.** Three online
guesses against 55 bits is roughly 1 in 10¹⁶ per window; SPAKE2 is what makes that the *only*
path available, by denying an offline one. Without it, a code this short used directly as a
transport credential would be recoverable offline by anyone who captured the handshake, with
unlimited time and no attempt limit to bound the search. `PairingCode` is deliberately not
derived from or mixed into any other secret on the wire — see the reasoning comment on its
`secret` property — so shortening it costs nothing else.

**The socket it runs on is deliberately not the fleet listener.** A PAKE runs *before* any
shared secret exists, so carrying it on the fleet listener would mean accepting unauthenticated
handshakes there — letting anyone on the LAN consume that listener's pending pool during every
window, and turning "a bootstrap connection must never send `hello`" into a check somebody has
to remember to write. `PairingListener` (`Sources/FleetKit/Pairing/`) exists only while a window
is armed, advertises `_flightdeck-pair._tcp` so its presence *is* the announcement that a Mac is
pairable, and speaks a vocabulary with no `hello` and no `cmd` in it: application code is not
reachable from it because it is not there. Its TLS-PSK is a **public bootstrap key compiled into
both binaries**, which buys no confidentiality and is not meant to — the device key crossing it
is sealed under the SPAKE2-derived key and would be equally safe in the clear. What the PSK buys
is that no unauthenticated frame parser sits on the wire in plaintext. Deriving that PSK from
the typed code is the obvious-looking improvement and would destroy the design: it would hand a
passive observer an offline attack on the 55 bits SPAKE2 is there to protect.

The budget that makes 55 bits safe is **three guesses, per Mac, per window**
(`PairingListener.maxAttempts`), and only a mismatched confirmation spends one: a frame that is
not a curve point at all, a confirmation with no exchange behind it, and a code that fails its
checksum on the phone all cost nothing. Per-Mac rather than global is load-bearing —
`PairingRunner` walks discovered Macs one at a time, so a user with two on the LAN must not
exhaust the budget on the right one by trying the wrong one first. The phone's half is
`PairingBrowser`, `PairingRunner` and `PairingInitiator`; the whole exchange is covered against
real sockets on macOS, and has never run on iOS — see [docs/MOBILE.md](MOBILE.md).

## Not yet built (design, not code)

Harness adapters, the shared code index, the context engine, and the sidebar are **design only** so far — see the [spec](superpowers/specs/2026-07-09-flight-deck-design.md) §1–§9. Nothing in the current codebase implements them.
