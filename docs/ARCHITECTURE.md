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

## Fleet replication (`FleetKit` / `Sources/FlightDeck/Fleet/`)

The spine a mobile companion replicates the fleet over — not wired to any UI yet (Plan 2:
`docs/superpowers/plans/2026-08-19-fleet-pairing-and-ios.md`), but live end to end: a real
client over a real TLS-PSK WebSocket can already receive a snapshot of a running
`SessionStore`, follow its mutations, and mark a session read. Two modules:

- **`Sources/FleetKit/`** — the wire types (`FleetSnapshot`, `WireProject`, `WireSession`), the
  delta vocabulary (`FleetEvent`), snapshot application, the replay fold, a hand-written frame
  codec, the TLS pre-shared-key parameters, and both socket halves (`FleetSocketServer`,
  `FleetClient`). It imports only `Foundation`, `Network`, and `Security` — never `AppKit` —
  and that boundary is enforced mechanically, not by convention: the same source directory is
  also compiled as an iOS target (`FleetKitiOS` in `project.yml`, checked by
  `scripts/build-ios.sh`), so a stray `import AppKit` fails that build immediately rather than
  surfacing later as a phone-side compile error nobody is watching for.
- **`Sources/FlightDeck/Fleet/`** — the desktop side. `FleetProjection` is a pure read of
  `SessionStore` into wire shape. `FleetReplicator` mirrors the fleet from `SessionStore`'s
  event log and holds a bounded ring for replaying across a reconnect. `FleetService` is the
  only type that knows both a `SessionStore` and a socket — deliberately: `FleetSocketServer`
  stays testable with no store, `SessionStore` stays testable with no network, and everything
  that needs both is here where it can be read at once.

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

## Search (`⌘K`, `Sources/FlightDeck/Search/`)

`⌘K` opens a floating overlay (`SearchPanel`, an `NSPanel` added as a child window over the
deck) that ranks open sessions, open projects, and past conversations against one query.
Full design: [specs/2026-08-26-smart-search-design.md](superpowers/specs/2026-08-26-smart-search-design.md).

**The corpus (spec §5): the sidebar's projects, plus their worktrees — nothing else.**
`SearchCorpus` enumerates each open project's own `.claude/worktrees` and
`.superpowers/worktrees` children, encodes each real path with
`ClaudeSession.encodedProjectDirName`, and accepts only an exact match against a directory
name under `~/.claude/projects`. Never a prefix match: the encoding is lossy (every
non-alphanumeric run collapses to `-`), so `/w/flight-deck` and `/w/flight-deck-old` produce
one encoded name that is a genuine prefix of the other — a prefix rule would fold a
neighbouring project's whole history into this one's results.

**What gets indexed, and why the measurement decided the architecture.** Only conversation
text — user and assistant text blocks, never tool input/output, envelope fields, or images.
A 97 MB, 60-transcript sample at spec time put that at 5.0% of transcript bytes (the rest:
54.5% JSON envelope, 19.9% `tool_result`, 8.9% `tool_use`, the remainder images and other
block types). That number is what justified skipping incremental/streaming complexity: at
~5%, extracting and indexing the *whole* visible corpus up front is cheap enough to just do.
The real corpus confirmed it — 362 transcripts, 361 MB read, 14.5 MB of conversation kept
(4.0%, consistent with the sampled estimate), in 7.0 seconds. A `withTaskGroup`-based
concurrent walk was the planned fallback if that number came back too slow; it wasn't needed
and isn't built.

**Two clocks, not one.** Live sessions need no separate mechanism: `ClaudeRuntime` already
runs one `TranscriptWatcher` per attached tab on the shared `WatchClock` (for titles and
sub-agent counts), and that watcher's `onMessages` hook now also extracts conversation text
and calls `SearchIndex.ingest(_:from:projectPath:offset: nil)` — the `nil` offset marks a
live-ingest row rather than a backfill read position, since the watcher tails from
end-of-file and has no notion of "how much of this file's history is indexed." Everything
that watcher does not cover — every conversation's history up to the moment the app
launched — is `SearchIndexBuilder`'s job: an `actor`, off the main actor, walking transcripts
newest-first (the conversation you want is overwhelmingly a recent one, so search becomes
useful long before the walk finishes), yielding between files, committing each file's byte
offset before starting the next so a killed build only ever loses the file it was mid-read
on. It starts 3 seconds after launch, deliberately after `SessionStore` has restored and
resumed every session, so a hundreds-of-megabytes parse never competes with the deck coming
back up.

**The index is a disposable cache, never a source of truth.** `SQLiteSearchIndex` lives
beside `sessions.json` (`search-index.sqlite` in Application Support, honouring
`-FlightDeckStateDir` for the same reason that flag exists — a debug instance must not write
into a real deck's index) and holds nothing that is not re-derivable from transcripts on
disk. A `schemaVersion` mismatch, or a file that fails to open at all (corrupt, truncated,
from an older build), is handled the same way: delete it and rebuild from scratch. Losing it
costs one backfill, never data.

**Ranking is tiers, not a blended score.** `SearchRanker` orders by match-quality tier first
(exact / prefix / fuzzy name match, then FTS5 transcript hit), and only breaks ties within a
tier by recency — deliberately not a single score, since BM25 (transcript relevance) and the
fuzzy-subsequence score (name matching) are not on a common scale, and any constant that
mixed them would be undefendable. Transcript hits are always the last tier: BM25 still
governs which 200 candidate hits FTS5 returns (`LIMIT 200 ORDER BY bm25(...)`), but within
the overlay they are ordered by recency and drawn only below every name match. That ordering
is what lets the debounced transcript query's slower results append below an already-visible,
already-selected row instead of reordering the list out from under the user's finger.

**⌘K had to be taken back from Ghostty first**, the same problem `⌘⇧T` (Tab navigation,
above) already had to solve. libghostty binds `super+k` to `clear_screen` on macOS and marks
it `performable`, and `MenuKeyEquivalents.shouldOfferToMenu` deliberately withholds
performable bindings from the main menu so they still reach the terminal when a menu item
shares the chord — so as long as libghostty claimed the key, `SurfaceView.performKeyEquivalent`
swallowed it before the Search menu item ever saw it, and it failed *silently*: the menu item
rendered correctly and simply never fired. `GhosttyDefaults.conf` now carries
`keybind = super+k=unbind`, loaded before the user's own Ghostty config, so anyone who wants
`clear_screen` back on `⌘K` can rebind it there. A unit test pins that line's presence in the
test bundle's copy of the file, but cannot catch the *app* target's copy going missing — only
a real, terminal-focused UI test can, which is what the `⌘K search opens, filters, and closes`
smoke group exists for.

## Not yet built (design, not code)

Harness adapters, the shared code index, the context engine, and the sidebar are **design only** so far — see the [spec](superpowers/specs/2026-07-09-flight-deck-design.md) §1–§9. Nothing in the current codebase implements them.
