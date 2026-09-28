# Flight Deck — Architecture (as built)

This describes the code **as it exists today**. For the intended full design and the reasoning,
see the [design spec](superpowers/specs/2026-07-09-flight-deck-design.md); for what is still
unbuilt, see the last section here.

It began as a walking skeleton and is well past one: two agents behind a common adapter, a
preferences core, external tools, transcript history, and a fleet replicated to a phone that
runs on real hardware. Sections below are ordered roughly as that grew.

**If you are about to change something, there is probably a working document for it.**
This file says what the pieces *are*; those say how to change one without breaking what is
holding it up.

| Changing | Read |
|---|---|
| The phone's screens | [MOBILE-UI.md](MOBILE-UI.md), then [MOBILE.md](MOBILE.md)'s checklist |
| The wire, pairing, discovery | [NETWORKING.md](NETWORKING.md) |
| Anything, at runtime, on this machine | [AGENT-OPERATIONS.md](AGENT-OPERATIONS.md) |

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
- **`SWIFT_VERSION: "5.0"` on the app target only** (Swift 5 language mode under the Swift 6.3 compiler) — required so the vendored Ghostty code compiles without Swift-6 strict-concurrency breakage. Deliberate; see FOLLOWUPS. Everything added since is Swift 6: `FleetKit`, its iOS twin, `FlightDeckMobile` and the test targets all set `SWIFT_VERSION: "6.0"`, which is why FleetKit's queue-confined classes carry explicit `@unchecked Sendable` conformances rather than inheriting a laxer default.
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

## Detached sessions

Each session's agent shell runs inside its own `fd-abduco` daemon rather than directly under
the surface's PTY — a separate process tree (`fd-abduco` `setsid`'s itself) that survives
Flight Deck quitting, crashing, or being replaced by `scripts/swap-release.sh`. This is what
makes those events invisible to a running `claude`/`codex`: the agent's own pid never changes.

- **`SessionDaemon`** (`Sources/FlightDeck/SessionDaemon.swift`) is a pure path calculator: a
  session id maps to a socket (`<directory>/<uuid>.sock`), a pidfile (that path + `.pid`), and
  a space-free symlink to the bundled binary — all rooted at `/tmp/flight-deck-<uid>`, chosen
  over an Application Support path so `sun_path`'s 104-byte cap always has room regardless of
  the login's home directory depth. The symlink exists because the real bundled binary
  (`.../Flight Deck.app/Contents/Resources/fd-abduco`) contains a space, which is fatal to
  ghostty's shell-command tokenizer.
- **`LaunchPlan`** decides attach-vs-cold-create from one bool: if `DaemonControlling.isLive`
  says the id's daemon already has a session, the launch command is `fd-abduco -a <sock>` and
  types nothing — the shell inside is already running whatever it was running, so a resumed
  `claude` or `codex resume` must not be re-typed into it. Otherwise the command is
  `fd-abduco -c <sock> <shell>` (cold-create) and the usual `typed` text (`claude --resume ...`,
  the "Keep going" auto-resume prompt, an empty string for a plain shell) is sent exactly as it
  was before this daemon existed. The distinction is agent-agnostic: Claude and Codex sessions
  go through the same `LaunchPlan.decide`, keyed only on their own daemon's liveness.
- **`PosixDaemonControl`** is the live `DaemonControlling`: `isLive` probes the `AF_UNIX`
  socket directly (ground truth a pidfile alone can't give — a crashed daemon can leave a
  stale socket, or a stale pidfile naming a recycled pid), and `terminate` is `SIGTERM`, poll
  for up to ~1s, `SIGKILL` if it didn't listen, then unconditionally unlink the socket and
  pidfile. `SessionStore` owns one `SessionDaemon` and one `DaemonControlling`; the latter now
  always derives from the former (`PosixDaemonControl(daemon: daemon)`) so a caller can't
  inject one without the other and end up probing the wrong socket path.
- **Lifecycle:** a daemon is created on first cold launch, reused on every subsequent attach,
  and left running across app quit — `reapAllForQuit` deliberately never calls
  `daemonControl.terminate`. It's torn down in exactly two places: closing its tab
  (`closeSession`, after the client's own process tree is reaped), and `restore()`'s
  `reconcileDaemons`, which kills any daemon whose socket survived on disk but whose session
  didn't come back on this launch (a crash, a hand-edited `sessions.json`, or a
  pre-this-feature snapshot). A daemon left by a hard crash mid-run is not reaped at all until
  the next launch reaches that point — it just sits there, reattachable, until then.
- **Scope:** `fd-abduco` sits below `AgentRuntime`/`ShellResolver` and knows nothing about
  Claude or Codex — it detaches a shell command, not an agent. Surviving a Mac reboot is out
  of scope (daemons live in `/tmp`, which does not survive one); cold-resume remains the
  post-reboot path. See [FOLLOWUPS.md](FOLLOWUPS.md) for carried-forward hardening
  (replay backpressure, nested-binary code-signing validation) and the debug/release
  socket-directory sharing caveat.

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

Sidebar rows show what each session is doing. **This section describes the claude path**, which
is the one with the polled registry; codex reports its state over JSON-RPC and through
`CodexRolloutWatcher` instead, and both arrive as the same `SessionStatus` through the agent's
`AgentRuntime` (see "Agents" below). Two sources feed one map:

```
<account home>/sessions/<pid>.json ──> SessionStatusWatcher ──┐
  (Claude's own status registry,        (one per claude        │
   polled; see the design spec)          account, 500ms poll,  ├──> SessionStore.statuses
                                         keyed by sessionId)    │      [UUID: SessionStatus]
<transcript>.jsonl ────────────────────> TranscriptWatcher ────┘             │
  (outstanding Agent tool_use ids,        (one per session)                  v
   closed by <task-notification>)                                   SessionStatusIcon
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
- **`TranscriptWatcher`'s sub-agent count** — since claude 2.1.276 every `Agent` runs in the
  background: its tool_result (`toolUseResult.isAsync`) only acknowledges the launch, and the
  agent ends at a later `<task-notification>` — read from the `queue-operation` enqueue, the
  `queued_command` attachment, or the delivered `user` record, whichever lands first, and matched
  by `<tool-use-id>` or by the launch's agent id as `<task-id>`. Not cleared at turn end (the
  agents outlive it); only held ids are removed, so a notification for an unseen launch is a
  no-op. `agentAsyncLaunchMarker` / `agentCompletionNotification` in the adapter-probe matrix pin
  both record shapes.
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

## Composer readiness and the injection gate

Everything Flight Deck types into a live agent — a phone's prompt, `/rename`, `/login`, a
restore's "Keep going" — funnels through `SessionStore.inject` / `injectRename`, and both stand
behind one `injectionGate`. The gate used to be pure screen grammar: parse the viewport for the
composer's box-drawing characters and refuse anything else. That broke silently whenever an
agent changed its TUI. Since 2026-09-19 the durable half comes from each agent's own lifecycle
and the screen is consulted only to veto a dialog.

```
  claude                                          codex
  ──────                                          ─────
  Resources/ClaudePlugin  (bundled, loaded per    <rollout>.jsonl
    .claude-plugin/        session via              │
    hooks/hooks.json       --plugin-dir)            │  CodexRolloutWatcher
    scripts/record.sh                               │   (evidence of a live TUI)
        │ one JSON line per lifecycle event         │
        v                                           │
  ~/Library/Application Support/Flight Deck/        │
    hook-events-<debug|release>/events.ndjson       │
        │  HookEventWatcher (ONE for the app,       │
        │   shared WatchClock, tail-with-offset)    │
        v                                           v
        ╰──────────> AgentEvent.lifecycle(ComposerReadiness) ──> SessionStore
                                                                composerReadinessByTab
```

- **The plugin is data in the app bundle** (`Resources/ClaudePlugin`, a *folder reference* in
  `project.yml` — a plain group would flatten `.claude-plugin/` and `hooks/`).
  `ClaudePluginLocation.applying(to:bundle:)` appends it to whatever `--plugin-dir` flags the
  user already set, idempotently, so a resume does not accumulate duplicates.
- **`FLIGHT_DECK_EVENT_DIR` is what switches the feed on.** `record.sh`'s first line exits when
  it is unset, so a session launched without it reports nothing and stays `.unknown` for the
  life of the process. It reaches the pty through `AgentAdapter.launchEnvironment`, merged over
  `PreferencesStore.sessionEnvironment` by `SessionStore.launchEnvironment(for:adapter:orphaned:)`
  at both surface-config sites — *not* through `AgentAdapter.environment(for:)`, whose only
  production consumer is the Tools menu. Deliberately not keyed on having an account: a tab
  whose login was deleted launches with no account variable and must still report.
  `AccountLaunchTests` pins that the directory a tab is told to write to is the one
  `HookEventWatcher` tails.
- **Every hook command in `hooks.json` quotes `${CLAUDE_PLUGIN_ROOT}`**, because in production
  it expands to `/Applications/Flight Deck.app/…` and Claude Code runs hook commands through a
  shell.
- **`ComposerReadiness` is `.unknown` / `.live` / `.absent`, and nothing else.** Busy-vs-idle is
  absent because mid-turn injection is fine and activity already has an owner
  (`ClaudeStatusFile`). A dialog state is absent because denying a permission prompt with Esc
  fires no hook at all, so a `.dialog` would have no observable clear.
- **The gate**: `.live` → the viewport must be readable, and inject unless
  `AgentTextChannel.isKnownNonComposer` recognises a dialog on it; `.unknown` → the legacy
  `hasComposerBox` grammar, exactly what every tab did before this existed, which is the
  migration guarantee; `.absent` → refuse.
- **`hasComposerBox` cannot tell a composer from its corpse, so `.absent` is the only thing
  that refuses a dead agent.** Claude Code does not clear the terminal on exit: the box it drew
  is still the last one in the viewport with the process gone, and a live pty probe
  (2026-09-21) had `hasComposerBox` answering `true` after the exit exactly as it had before
  it, with no dialog for the veto to catch. So `.unknown` is a fallback for a tab nothing has
  *reported* on, never a way to refuse one known to be dead.
- **The dialog veto recognises a dialog, never a composer**, and so fails *open* on an
  unfamiliar screen. Per agent it is the footer token (`Esc to cancel`, plus codex's
  `esc to go back`) **or** a marker line (`❯` / `›`) followed by numbered ` N. ` rows.
- **`.live` is not sticky, and the demotion is graded by how certain the death is.** Neither
  agent reliably announces its own death — `SessionReaper` escalates to SIGKILL, so
  `SessionEnd` usually never fires, and codex has no session-end record at all. On any tick
  where no registry row names a claude tab's conversation, `applyRegistry` demotes it: to
  **`.absent`** when the tab had an anchor and a `kill(pid, 0)` says that pid is gone (a
  certain death, refused without consulting the screen), and to **`.unknown`** otherwise — a
  tab that was never anchored is indistinguishable from one in the boot window, and the
  multi-account merge makes every tab of a not-yet-scanned account look unanchored while its
  agent is perfectly alive. The demotion never promotes, so `.absent` survives later ticks; it
  clears the hook watcher's per-session memory, so a resumed claude's `SessionStart` is
  reported as news rather than swallowed as unchanged; and a registry row appearing where there
  was none frees an `.absent` tab back to `.unknown`, which is what recovers a tab with no hook
  feed at all. Between ticks, `injectableReadiness` re-probes the anchor's pid at the instant
  of injection and answers `.absent` on the same evidence, which is what covers `submitPrompt`
  and `rename` — the two callers that inject inline rather than from the tick.

Design record: `docs/superpowers/specs/2026-09-19-hook-fed-composer-state-design.md` and
`docs/superpowers/plans/2026-09-19-hook-fed-composer-state.md`. Several of their decisions were
overruled during execution; each such site carries a superseded note naming the ruling that
replaced it and what shipped instead, so the two are safe to read — but **this section is the
authority**, because the ledger those notes cite
(`.superpowers/sdd/2026-09-19-hook-fed-composer-state/progress.md`) is git-ignored and exists
only on the machine the work was done on.
## Agents

`Sources/FlightDeck/Agents/` is the per-harness adapter protocol referenced from "Session
status pipeline" above — `AgentAdapter`, with two implementations today, `ClaudeAdapter` and
`CodexAdapter`, dispatched through the `AgentID` switch rather than held as an existentially
typed value. Each supplies its own runtime, dialog driver, turn recovery and timeline mapper.

**Adapter capabilities are optional statics, `nil` is the refusal.** `textChannel` (how a
message is typed into the agent's live terminal), `dialogDriver` (how a select-list dialog
the agent raised is driven) and `turnRecovery` (how a turn lost to an API failure is
revived) are all declared the same way on `AgentAdapter`: a static property an agent either
answers or leaves `nil`, dispatched through the `AgentID` switch rather than asked of an
instance. A `nil` is not a missing feature to fill in later — it **is** the refusal, so an
agent that cannot support a capability is refused it at one site instead of scattering a
predicate that could disagree with the implementation. `turnRecovery` additionally decides,
per agent, which of its own error vocabulary is worth retrying — see "API-error auto-retry"
in [FOLLOWUPS.md](FOLLOWUPS.md) for the codex allowlist and its fail-closed default.

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

Back (⌃⌘←) and Forward (⌃⌘→) navigate a persisted selection history of up to 50 entries per stack, recalled by `SessionStore.goBack()` / `goForward()` and never landing on the row already showing. The history persists across relaunches in `SessionSnapshot` and is populated by every visible selection change — a manual click, a new session selecting itself, the sibling `closeSession` falls back to, and ⌘⇧[ / ⌘⇧] cycling included. Only `restore()` and Back/Forward's own traversal are silent: replaying where you already were, or where the app already had you, is not a new place to record.

⌘⇧/ (Help ▸ Keyboard Shortcuts) opens a filterable overlay listing every one of these chords
plus the rest of the main menu's, derived from the live menu bar rather than a hand-kept list
so it never drifts. `ShortcutCatalog` walks `NSApp.mainMenu` into groups keyed by top-level
menu (`ShortcutCatalog+AppKit.swift` does the `NSMenuItem` adaptation; the catalog itself is
pure so it tests without AppKit's menu machinery); `ShortcutOverlay` renders and filters them.
Chords the terminal alone handles (⌘←/⌘→ line start/end, ⌘K clear) are not in the menu, so
they are correctly absent from the overlay too.

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

**The phone runs.** It takes a code off the Mac's screen — scanned, or twelve characters typed —
finds the Mac over Bonjour or by racing remembered addresses, and shows the running fleet in the
terminal's own idiom: one project section per open project, one row per session, renamed, marked
read and closed from either side, with the conversation itself readable and answerable. It has
paired against a real Mac from both a simulator and a real handset, and
`./scripts/deploy-phone.sh` installs and relaunches it on the device.

What that does and does not settle is worth being precise about, because this paragraph used to
say "has never been run" and the correction is not "so it is proven now":

- **Its logic is tested.** `FlightDeckMobileTests` is an app-hosted suite on a simulator
  covering the phone's decision-making — the typed-code field, `FleetModel`'s orderings, the
  status vocabulary, how a body is split into segments, what a quotation puts in the composer.
- **Its appearance is not, and cannot be.** That process has no window: nothing there lays out,
  draws or taps a view. See [MOBILE-UI.md](MOBILE-UI.md) for what follows from that and how to
  look at a change anyway.
- **Everything below the UI is covered by the macOS suite**, because it deliberately lives in
  `FleetKit` — including real sockets, a real handshake and real loopback runs.

`docs/MOBILE.md` carries the checklist of what only a device on a real network can confirm and
says plainly which parts are least proven. Plan 2 built the phone and the pairing
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

**Conversation history is pulled, not pushed, and it does not ride the event log.** Fleet state
is pushed because it is small and every client wants all of it; a transcript is bulk that only
the one client looking at that session wants. So a phone *asks*: `ClientFrame.req` carries a
`FleetRequest.timeline` with a `TimelineAnchor` (`latest` / `before(cursor)` / `after(cursor)`)
and a record limit, and `ServerFrame.page` answers with the mapped items on the same `cid` —
deliberately carrying no `seq`, because a history fetch must not move the resume point a client
hands back on its next `hello`. Scrolling up through an hour of transcript therefore cannot
change where a reconnect resumes. Cursors are byte offsets at line boundaries in the agent's own
transcript, opaque to the client, which only ever echoes back a `start` or an `end` it was
given. `TimelinePage.reset` is the file-level analogue of the wire's `seq_too_old`
re-snapshot: the transcript that cursor came from was replaced, so every item id the client
holds — ids *are* offsets — now names a different record, and it must discard and re-fetch.
The path is `TranscriptPager` (which bytes), the per-agent mapper (`ClaudeTimelineMapper`,
`CodexTimelineMapper`, turning lines into `TimelineItem`s), `TimelineReader` (composing them
under a page byte budget), and `TimelineService`, which resolves a tab id through `SessionStore`
and runs the read off the main actor — a page is file I/O, and parsing it on the main thread
while an agent is producing output is a visible stall in the Mac's own UI. `FleetService` wires
that to the socket in `wireHandlers()`, answering from a `Task` so the reply lands back on the
socket's queue after the read. **Nothing in that path writes to the store**, which is why the
timeline needed no `FleetEvent`, no broadcast, and left the drift check above with nothing new
to guard. `TimelineLoopbackTests` is the end-to-end proof: a real service over a real socket
answering a real client out of a real file on disk, including the second page fetched from the
first page's cursor.

**The phone talks back, and what it sends is held until the Mac confirms it.** A prompt typed
on the phone goes as `FleetCommand.prompt` carrying a client-minted token; `SessionStore`
dedupes on that token and queues the text until the agent's input box is free, so sending
mid-turn — which is when someone reaches for their phone — is the ordinary case rather than a
refusal. Until the Mac echoes the turn back as a `FleetEvent`, the message sits in
`PromptOutbox` above the composer, dimmed: it is not in the conversation, because the
conversation is what the agent has actually written. **Nothing is set optimistically anywhere on
this screen** — the same rule covers marking a session unread — because a row that appears and
then vanishes when the Mac disagrees is worse than one that takes a moment. `ack` means
dispatched, and the outbox retires a row on exact string equality with the turn that comes back,
so anything that rewrites a draft on its way out would strand it. `AskUserQuestion` is the same
shape in the other direction: an open question replicates as `OpenPrompt`, the phone draws it as
a card with one button per option, and `FleetCommand.answerPrompt` sends the choice.
`PhonePromptLoopbackTests` and `AnswerLoopbackTests` are the end-to-end proofs.

**Requests carry the things that are not state at all.** The pulled channel described above is
not only for history. The phone's New Session menu is the other user of it: its rows come from
`NewSessionAffordance.menu` — the same function the desktop sidebar draws from, so the two
cannot disagree about which agents appear, in what order, or which account is ticked — and they
are answered on a `cid` rather than replicated. They have to be. Menu rows derive from
preferences, preferences emit no `FleetEvent`, and a snapshot field built from them changes the
fleet with nothing recorded, which is exactly what the drift assertion above catches; an earlier
implementation put them in `WireProject` and failed three Mac tests for that reason. Rows are
identified by agent plus **position** among that agent's accounts, never by an account id, for
the reason the next paragraph gives, and the Mac re-resolves that position — validating the
agent — when a row comes back. [NETWORKING.md](NETWORKING.md) has the full recipe for adding a
command or a request, including both of those traps.

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
real sockets on macOS, and **has now run on iOS** — a typed-code pairing from a simulator and
from a handset, against a real Mac. The QR path still has no simulator coverage for the obvious
reason that a simulator has no camera. See [docs/MOBILE.md](MOBILE.md) for the checklist, and
[NETWORKING.md](NETWORKING.md) for what a cross-process run does and does not prove — the
distinction matters here more than anywhere else in the codebase.

### Local control socket (`flightdeck` CLI)

Design: [specs/2026-09-24-flightdeck-cli-design.md](superpowers/specs/2026-09-24-flightdeck-cli-design.md).
A second, independent `FleetSocketServer` instance — `FleetService.localServer` — listens on
a unix socket at `<state dir>/control.sock` (`control-debug.sock` in a Debug build, so the two
builds never fight over one path) and speaks exactly the phone's frames (`ClientFrame` /
`ServerFrame`) through the same `onHello`/`onCommand`/`onRequest` closures the paired instance
uses. **Same server type, separate instance, never a second listener on the phone's**: the
phone instance's `stop()` — which every arm, expiry and revocation reaches through
`reloadKeys()` — cancels every connection it holds, and sharing an instance would drop every
`flightdeck tail` whenever a phone paired or was revoked.

**Not WebSocket.** `NWProtocolWebSocket` over a `.unix(path:)` endpoint aborts the client with
`ECONNABORTED` before `.ready` (probed 2026-09-24, recorded in the spec). `FleetSocket.lineParameters()`
builds newline-delimited framing instead, via `FleetLineFramer` (an `NWProtocolFramerImplementation`
that splits on `\n` and fails the connection over `TimelineLimits.maximumMessageSize`, so a peer
that never sends a newline cannot grow the receive buffer without bound). Everything above the
transport — frame types, handlers, the event/timeline/request plumbing — is unchanged; only
`FleetSocketServer.startLocal(path:)` (server side) and `FleetClient(localCaller:)` /
`connect(toLocal:lastSeq:)` (client side, used by the CLI) dial line parameters instead of
TLS-PSK and WebSocket. Authorization is the filesystem: the socket file is `0600`, and by
default it sits inside `~/Library` (0700), which is the real boundary — the mode is set after
bind, so for a moment the file has only the umask's. A `-FlightDeckStateDir` outside
`~/Library` relies on the mode alone, which is why a failed `chmod` fails `startLocal` rather
than leaving the listener up. `NWConnection` exposes no descriptor to run
`getpeereid` against, the same argument `AnswerTriggerSocket` already makes for the answer
trigger. A live socket file is refused (`FleetSocketError.inUse`), never unlinked, so a second
app instance sharing the state directory cannot steal the first one's path; a dead file is
unlinked and rebound.

**A local connection is invisible to everything phone-shaped**, by construction rather than by
filtering: `FleetAttachment.isLocal` and `.caller` are set only by the local instance (a phone's
own `caller` in `hello` is ignored), and `attachedSlots`, the prompt-lifecycle client counts,
and `phoneRequest` are all sourced only from the paired instance's attachments. A local `viewing`
is acked and dropped rather than recorded, so `flightdeck tail` never lights the phone's presence
badge.

**`ControlEnvironment`** (`Sources/FlightDeck/Fleet/ControlEnvironment.swift`) is the socket's
address and a tab's identity on it. `FlightDeckControlSocket` (UserDefaults, default **on**,
read once at launch like `FlightDeckAnswerTrigger`) gates whether `FlightDeckApp` starts the
local listener at all. Every tab Flight Deck launches gets three environment variables — set in
`SessionStore.launchEnvironment` on the adapter's own half, so a Shell pane cannot override
them:

- `FLIGHT_DECK_SESSION_ID` — the tab's UUID.
- `FLIGHT_DECK_CONTROL_SOCKET` — the absolute path, so a tab always reaches the instance that
  launched it, even when a Debug and a Release build share one state directory.
- `FLIGHT_DECK_CALLER` — `<session-uuid>.<hex HMAC-SHA256(secret, session-uuid)>`. **Derived,
  not minted and stored per launch**: a detached (fd-abduco) session outlives an app relaunch
  and keeps the environment it was launched with, so a freshly-minted token would go stale in
  every surviving tab after a restart. The 32-byte secret lives in `FlightDeckControlSecret`
  in `UserDefaults`, generated once and read back thereafter, so re-deriving the token for a
  given session id always agrees with what was handed out at launch.

**`ControlScope`** (`Sources/FlightDeck/Fleet/ControlScope.swift`) is the pure policy `FleetService`
checks before `apply`, for local callers only — a paired phone is always fully privileged, and
a human shell that presents no `caller` token is never scoped either. The preference
`FlightDeckAgentControlScope` (`ControlScopeLevel`: `full` default · `ownSession` · `readOnly`)
is read fresh on every command via `FleetService.scopeLevel()`, so the Preferences picker (the
Devices tab's "Command Line" section) takes effect immediately, with no listener restart. A
token that fails to verify is `.invalid`, not `.human` — it fails closed under a scoped level
rather than falling back to a human's trust. Refusal is `err(cid, "out_of_scope")`. **This is a
guardrail, not a sandbox**, and both the preference caption and the code comments say so: any
process running as the user can already read the environment or the defaults domain and mint
its own token.

The CLI itself lives in `Sources/FlightDeckCLI` (the pure core: argument parsing, session
resolution, the runner that drives `FleetClient`) and `Sources/FlightDeckTool` (the executable's
`main.swift` — kept out of `Sources/flightdeck` because that name collides with `Sources/FlightDeck`
on case-insensitive APFS). The xcodegen target is `FlightDeckCLI`, its product is `flightdeck`,
embedded at `Flight Deck.app/Contents/MacOS/flightdeck` — already on every tab's `PATH` as
`GHOSTTY_BIN_DIR` — so running it never boots the app.

**Codex tabs.** Codex runs every tool call in its own seatbelt sandbox, and its default
`:workspace` profile refuses `connect()` on a unix socket with `EPERM`, so a codex agent cannot
run `flightdeck` at all without a grant. The only narrow grant codex has is its managed network
proxy: `CodexControlAccess` (`Sources/FlightDeck/Agents/Codex/`) appends
`--enable network_proxy` and four `-c` overrides to every `codex`/`codex resume` line a codex tab
types. They define a `flightdeck` permissions profile that extends `:workspace`, turns
`network.enabled` on, and allows exactly one entry in `network.unix_sockets`: the control
socket *file*. Codex writes each key into the seatbelt profile as `(subpath <key>)`, so a
directory key would allow every socket in the state directory, including the unauthenticated
`answer-trigger.sock`; the file key allows that one socket and nothing beside it. Probed on
codex-cli 0.155.1 and re-checked on 0.157.1: the socket connects, a sibling socket in the same
directory gets `EPERM`, and a direct TCP connect to the internet gets `EPERM` from the seatbelt.
Codex's session header says "network access enabled" under this profile. Egress is not open:
direct connects are refused, and codex points the child's `http_proxy`/`https_proxy`/… at its
own proxy, which denies every host by default. What the proxy does with a denied host depends
on the approval policy. Under `codex exec` with `approval: never` (the only live run) it
returned 403. In a `codex resume` TUI tab the policy is not `never`, and codex 0.157.1's source
sends the host to an approval decider, so a proxy-aware tool (curl, pip, npm, git over https)
should raise a per-host "`<host>` is not in the allowed_domains" / `network-access <host>`
approval dialog. **That TUI behaviour is read from the source and is unverified live** (see
FOLLOWUPS). `CodexAdapter.controlSocket` carries the path, and `SessionStore` sets it on every
codex stack, both ones built after `controlSocket` is set and ones that already exist.
The flags are typed only when the probed codex is at least
`CodexVersionProbe.controlAccessMinimumVersion` (0.155.1): `startCodex` sets
`CodexAdapter.controlAccessSupported` beside `historyMode`, and the adapter needs both it and a
socket. An older codex gets no flags, and its `flightdeck` exits 77. Claude tabs need none of
this: Flight Deck does not sandbox claude, so its `flightdeck` reaches the socket directly.

- **Experimental dependency.** `network_proxy` is an experimental codex feature. The guard is
  `CodexIntegrationTests.testControlSocketGrantConnectsWithoutOpeningTheInternet`, run by
  `./scripts/test-codex-live.sh` (no model turn, no tokens). It runs our exact argv through
  `codex sandbox`, checks that `:workspace` alone refuses the socket, that the grant connects,
  that a second socket beside it is refused with `EPERM`, that a direct connect to
  1.1.1.1:443 is refused with the seatbelt's `EPERM` (an offline Mac's timeout does not pass),
  and that an HTTP request through codex's own proxy is denied. Run it after a codex update.
- **Sandbox-choice exception.** A user who picked a codex sandbox in Preferences
  (`CodexThreadOptions.sandbox` set) gets no flags: codex refuses to start when both
  `sandbox_mode` and `default_permissions` are set as overrides. That tab's agent cannot reach
  `flightdeck`. A `sandbox_mode` in the user's `~/.codex/config.toml` does *not* conflict: the
  command-line `default_permissions` wins (probed 2026-09-26, the active profile was
  `flightdeck`).
- **Exit 77.** When a sandbox still refuses the socket (a tab opened before this change, the
  exception above, or a codex that dropped the mechanism), `flightdeck` exits `77`
  (`EX_NOPERM`) with a message that names the sandbox, not `69` ("cannot reach"). The check is
  `CLIRunner.isSandboxRefusal` (`EPERM`/`EACCES` from `NWConnection` or a raw `POSIXError`).
  Verified with the real binary under `codex sandbox -P :workspace`.

## Search (`⌘K`, `Sources/FlightDeck/Search/`)

`⌘K` opens a floating overlay (`SearchPanel`, an `NSPanel` added as a child window over the
deck) that ranks open sessions, open projects, and past conversations — across every agent,
not just claude — against one query. Original design:
[specs/2026-08-26-smart-search-design.md](superpowers/specs/2026-08-26-smart-search-design.md).
Multi-agent design, discovery details and the ranking correction below:
[specs/2026-09-21-multi-agent-search-design.md](superpowers/specs/2026-09-21-multi-agent-search-design.md).

**`AgentSearchCorpus` is the fourth capability object on `AgentAdapter`**, beside
`textChannel`, `dialogDriver` and `openPromptReader` — but `Sendable` and `nonisolated`
rather than `@MainActor`, because its sole production caller, `SearchIndexBuilder`, calls it
directly from inside its own `actor`, off the main actor, precisely so parsing hundreds of
megabytes of transcript cannot stall an agent running in the same process. It answers three
questions for one agent: which transcripts belong to which sidebar projects
(`transcripts(forProjects:accounts:)`), what one transcript line means as indexable messages
(`indexedMessages(inLine:conversationID:at:)`), and what a conversation is called
(`conversationName(inLines:for:)`). Like its three siblings it is reached through a
hand-written, non-optional switch — `extension AgentID { var searchCorpus }` — rather than
off an adapter instance, because its caller, `AppDelegate.startSearch`'s backfill kickoff,
holds no adapter at all, only the `AgentID` each `TranscriptRef` carries. **That switch is
what actually makes a third agent searchable by conforming rather than by editing the search
subsystem**: it is exhaustive over `AgentID`, a `CaseIterable` enum, so a third case added
there **fails to compile** until it answers `searchCorpus` too — the same gate `textChannel`,
`dialogDriver` and `openPromptReader` already stand behind, and the thing a future maintainer
most needs to know about this seam.

**Discovery is per-agent, and per-account within each agent.** `ClaudeSearchCorpus` is
claude's own implementation — one of two conformers today, not "the" corpus — and keeps the
original encoding rule: enumerate each open project's own `.claude/worktrees` and
`.superpowers/worktrees` children, encode each real path with
`ClaudeSession.encodedProjectDirName`, and accept only an exact match against a directory
name under `<account>/projects`. Never a prefix match: the encoding is lossy (every
non-alphanumeric run collapses to `-`), so `/w/flight-deck` and `/w/flight-deck-legacy` produce
one encoded name that is a genuine prefix of the other — a prefix rule would fold a
neighbouring project's whole history into this one's results. `CodexSearchCorpus` has no
such directory to encode: codex's rollouts live in a date tree and record their cwd only
inside the file, so it walks `<account>/sessions/**`, reads each rollout's first line
(`session_meta`), and attributes it by an *exact, normalised* match of that `cwd` against the
same worktree-aware candidate set claude uses — `/private/var` vs `/var` is the case that
makes normalisation load-bearing rather than defensive. `archived_sessions/` is never walked:
`thread/archive` puts a rollout there on purpose, and resurfacing it in ⌘K would undo that.
Both conformers are per-account, which is also what fixed ⌘K being blind to a second claude
login — reading one hardcoded `~/.claude/projects` root was the bug.

**Extraction and naming are agent-specific too, behind the same protocol.** Codex indexes
only the `event_msg` family (`user_message`, `agent_message`) — the same reasoning
`TranscriptExtractor` already applies to claude's tool blocks: the `response_item` family is
the model transcript, carrying a second copy of the prose plus an assembled-prompt blob per
turn, and indexing it would double every reply. Naming prefers a real
`session_index.jsonl` name over a first user message, unless that name is a `"session N"`
placeholder Flight Deck itself wrote via `thread/name/set` — see `docs/FOLLOWUPS.md` for why
that placeholder exists at all and why the fallback has to stay even after it is fixed at the
source.

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

**Two clocks, not one.** Live sessions need no separate mechanism: `ClaudeRuntime` and
`CodexRuntime` each already run one watcher per attached tab on the shared `WatchClock` (for
titles and sub-agent counts, or turn boundaries), and that watcher's `onMessages` hook also
extracts conversation text and calls `SearchIndex.ingest(_:for:offset: nil)` — the `nil`
offset marks a live-ingest row rather than a backfill read position, since the watcher tails
from end-of-file and has no notion of "how much of this file's history is indexed." Everything
that watcher does not cover — every conversation's history up to the moment the app
launched — is `SearchIndexBuilder`'s job: an `actor`, off the main actor, walking transcripts
newest-first (the conversation you want is overwhelmingly a recent one, so search becomes
useful long before the walk finishes), yielding between files, committing each file's byte
offset before starting the next so a killed build only ever loses the file it was mid-read
on. It starts 3 seconds after launch, deliberately after `SessionStore` has restored and
resumed every session, so a hundreds-of-megabytes parse never competes with the deck coming
back up. One build pass runs over the union of every agent's refs, never one pass per agent —
`build` opens with a prune that drops any source outside the set it is handed, so a per-agent
pass would delete the other agent's rows on every run.

**The index is a disposable cache, never a source of truth.** `SQLiteSearchIndex` lives
beside `sessions.json` (`search-index.sqlite` in Application Support, honouring
`-FlightDeckStateDir` for the same reason that flag exists — a debug instance must not write
into a real deck's index) and holds nothing that is not re-derivable from transcripts on
disk. A `schemaVersion` mismatch, or a file that fails to open at all (corrupt, truncated,
from an older build), is handled the same way: delete it and rebuild from scratch. Losing it
costs one backfill, never data. Schema v3 added `agent`, `provenance` and `working_directory`
to the **`source`** table (one row per transcript file), not to `message`: a transcript has
exactly one of each, so putting them on `message` would repeat them across every one of that
file's rows to answer a question that is per-file. `provenance` (codex's `session_meta.source`
— `"exec"`, `"cli"`, `"vscode"`) drives the ranking tier below; `working_directory` is what
lets a result resume into the worktree it actually ran in, without re-deriving it —
`SessionStore.resolvedTranscriptDirectory`, which used to re-derive it by probing candidate
directories for a matching filename, is gone.

**Ranking is tiers, not a blended score.** `SearchRanker` orders by match-quality tier first
(exact / prefix / fuzzy name match, then FTS5 transcript hit, then an `.automated` tier below
that), and only breaks ties within a tier by recency — deliberately not a single score, since
BM25 (transcript relevance) and the fuzzy-subsequence score (name matching) are not on a
common scale, and any constant that mixed them would be undefendable. Transcript hits are
always the last tiers: BM25 still governs which 200 candidate hits FTS5 returns (`LIMIT 200
ORDER BY bm25(...)`), but within the overlay they are ordered by recency and drawn only below
every name match. That ordering is what lets the debounced transcript query's slower results
append below an already-visible, already-selected row instead of reordering the list out from
under the user's finger. `.automated` exists because 86% of rollouts on a working machine are
headless `codex exec` runs, concentrated in one repo — sharing the `.transcript` tier with
real conversations would let one project's automation bury its own history. **The tier alone
does not move a grouped row**, and assuming it does is the trap: `SearchRanker.rank` appends
the grouped transcript block whole after the sort, so a row's tier never reaches the
comparator once it is inside a group. The `.automated` ordering is therefore applied to the
**group sort** (whether a group's first hit is an `exec` run), which is also what keeps a
conversation's continuation rows adjacent to their heading rather than split across the tier
boundary.

**Activation resumes the result's own agent, into the directory the walk recorded.**
`SearchActivation.plan` carries `agent` and `workingDirectory` through to
`SessionStore.openConversation`, which resolves `launchAccount(for: result.agent, …)` instead
of assuming claude, and sets `Session.transcriptDirectory` from the stored value rather than
probing for it. A codex result whose rollout no longer exists still resumes, through the same
`rolloutExists` check a restored tab takes, onto a fresh thread rather than failing.

A transcript hit already carries `workingDirectory` and `transcriptPath` from the corpus walk
itself (see the `source`-table paragraph above). A **name match** — a result that matched on
title rather than content, which is what `SearchCandidates.build` produces for every
conversation with no open tab — carries neither: naming a conversation and locating its
transcript are two different reads, and the name pass has no cheap way to do the second
without stat-ing every historical transcript on every keystroke. `AppDelegate`'s ⌘K
`onSelect` and `FleetService.openConversation` (the phone's `search.open` handler) each close
this gap the same way, independently: before calling `SearchActivation.plan`, they look the
conversation up with `SearchIndex.transcriptLocation(forConversation:)` — the same index row a
transcript hit's `source` fields come from — and fill it in. Only a conversation the index has
no row for at all reaches `SessionStore.openConversation` still empty, which is what its own
project-root fallback is for.

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
a real, terminal-focused UI test can, which is what
`TerminalSmokeTests.testCommandKOpensTheSearchOverlayOverAFocusedTerminal` exists for — its own
test rather than a group, so an unrelated failure elsewhere in the suite cannot stop it running.

## Not yet built (design, not code)

**The shared code index and the context engine** are design only — see the
[spec](superpowers/specs/2026-07-09-flight-deck-design.md) §1–§9. Nothing in the codebase
implements either, and no file below `Sources/` mentions them.

Two items that used to be on this list are not any more, and are described above instead:
**harness adapters** (`Sources/FlightDeck/Agents/`, a protocol with two implementations —
`ClaudeAdapter` and `CodexAdapter`, each with its own runtime, dialog driver, turn recovery
and timeline mapper — see "Agents") and **the sidebar** ("Sidebar structure").

Also designed and deliberately deferred rather than unbuilt: encapsulating `SessionStore`'s
fleet state behind a type whose every mutator records its own event
([spec](superpowers/specs/2026-08-18-fleet-state-encapsulation-design.md)). The `#if DEBUG`
drift assertion described above is the interim measure standing in for it, and must not be
removed before it lands.
