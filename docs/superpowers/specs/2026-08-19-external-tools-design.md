# External Tools — Design

**Date:** 2026-08-19
**Status:** design, pre-implementation
**Scope of this spec:** user-configurable external tools, launched by menu shortcut or by a
floating overlay over the terminal, edited in a new Tools preferences pane.

A tool is a shell command template with an icon and a hotkey. `Editor` (`$EDITOR ${cwd}`, ⌘O)
and `Terminal` (the user's terminal emulator, ⌘T) ship as defaults; users add arbitrary others.
Pressing the chord — or clicking the button — runs the expanded command against the currently
selected session's directory.

## 1. Findings that constrain the design

Each was checked against the tree on 2026-08-19 rather than assumed. Three of them decide a
mechanism outright.

1. **SwiftUI cannot vary a `.keyboardShortcut` at runtime.** `SessionCommands` documents this
   in its own comments and works around it by giving each agent list position a *statically*
   chorded menu item. User-recorded shortcuts are inherently dynamic, so the Tools menu cannot
   be a SwiftUI `Commands` group. It has to be an AppKit `NSMenu` whose items' `keyEquivalent`
   is assigned as a plain property (§6).

2. **Ghostty swallows ⌘-combinations, and the existing hand-off already covers us.**
   `Ghostty.SurfaceView.performKeyEquivalent` returns true for anything libghostty considers a
   binding, which is why `MenuKeyEquivalents` exists. Its doc comment states the invariant
   directly: nothing in it names a specific shortcut, and `NSMenu.performKeyEquivalent` walks
   the entire menu tree, so *"any menu item or hotkey added later is covered with no change to
   this file."* **This feature needs zero changes to key-equivalent routing** — provided the
   Tools menu is in `NSApp.mainMenu`, which is another reason for §6's AppKit menu.

3. **Mouse-move events do flow over the terminal.** `SurfaceView.updateTrackingAreas`
   (`SurfaceView_AppKit.swift:862`) installs an `NSTrackingArea` with `.mouseMoved` and
   `.mouseEnteredAndExited`, and the view overrides `mouseMoved` at line 1071. macOS only
   generates `mouseMoved` when something asks for it, so without this the fade-in trigger would
   not exist. A local `NSEvent` monitor can therefore see mouse movement over the surface, which
   is what makes §7's monitor viable at all.

4. **A `Session` carries two directories with different meanings.** `workingDirectory` is the
   project the tab is filed under and deliberately does *not* follow the agent into a worktree;
   `transcriptDirectory` follows every reported cwd change, *including* into
   `<project>/.claude/worktrees/<name>`. `${cwd}` and `${project}` map onto these two facts
   (§4) rather than collapsing them.

5. **Agent-session facts are already normalized, and tools must use that boundary.**
   `AgentBinding { conversationID, transcriptURL? }` is the adapter vocabulary for exactly the
   two facts a tool wants, and the adapters differ underneath in ways no caller should see:
   `ClaudeAdapter.binding` *derives* the transcript path from the cwd via
   `ClaudeSession.transcriptURL`, while `CodexAdapter.binding` reads a path codex *reported*
   into `Session.transcriptPath`. `ClaudeAdapter`'s own doc comment states the rule this
   feature has to respect — `encodedProjectDirName` is kept off the protocol deliberately so
   that claude's path derivation does not "leak a claude implementation detail into every
   future agent." A `ToolContext` built by reading `Session.transcriptPath` and calling
   `ClaudeSession.transcriptURL` would be that leak, one layer further out.

   The cwd is the same story wearing a misleading name. `transcriptDirectory` reads as
   claude-specific, but `CodexAdapter.prepare` passes it as codex's *thread* cwd
   (`asThreadStartParams(cwd:)`), and `launchCommand`'s comment requires the pty to be spawned
   there. It is already the shared "where this agent is working" fact — it just has no
   normalized accessor. §3.1 adds one rather than letting the tools subsystem hardcode today's
   coincidence.

6. **Optional fields in `Preferences` are load-bearing, not stylistic.**
   `UserDefaultsPreferencesPersistence.load()` decodes with `try?`, and synthesized `Codable`
   throws on a missing key rather than falling back to a property default. A non-optional
   `tools` field would fail to decode every existing `preferences.v1` blob and silently reset
   every flag, override and shell setting the user has. `storedTools` is Optional for exactly
   the reason `confirmations`, `claude` and `storedAgents` are (§3).

7. **Flight Deck's own environment is not the user's shell environment.** Launched from Finder,
   the app process has no `$EDITOR` and a `PATH` without `/opt/homebrew/bin`. `$EDITOR ${cwd}`
   can only work if the command runs through the login shell (§5).

## 2. Non-goals

Chosen, not forgotten. Each is a clean later addition.

- **No per-project tool overrides.** `Preferences.projectFlags` exists for agent flags; tools
  are global. A per-project editor is not a want anyone has expressed.
- **No system-wide hotkeys.** Tools act on the selected session, which has no meaning when
  Flight Deck is not frontmost. Shortcuts are ordinary app key equivalents; no Carbon
  `RegisterEventHotKey`, no accessibility permission.
- **No "runs in a Flight Deck tab" mode.** A terminal-first tool (`nvim`, `lazygit`, `tig`)
  launched detached gets no tty and dies immediately. Hosting such tools in a new session tab is
  a coherent future feature and explicitly out of scope here; the workaround today is to write
  the command as `open -b <terminal> …`.
- **No app-icon picker.** Icons are SF Symbols only. Symbols are monochrome templates that tint
  cleanly against `.regularMaterial` at any opacity, and cost one string rather than a stored
  bundle path that can go stale.
- **No UITest coverage.** Per `AGENTS.md` rule 4, this does not earn a `scripts/smoke.sh`
  change. Everything below is assertable headlessly.

## 3. Model and storage

```swift
struct ToolDefinition: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String            // "Editor"
    var symbol: String          // SF Symbol name, e.g. "chevron.left.forwardslash.chevron.right"
    var command: String         // template, e.g. "$EDITOR ${cwd}"
    var shortcut: ToolShortcut? // nil = reachable from the menu and overlay, but unbound
    var showsInOverlay: Bool
}

struct ToolShortcut: Codable, Equatable {
    var key: String    // the character, lowercased: "o"
    var modifiers: UInt // NSEvent.ModifierFlags.deviceIndependentFlagsMask raw value
}
```

`ToolShortcut` maps 1:1 onto `NSMenuItem.keyEquivalent` / `keyEquivalentModifierMask`, which is
the whole point of storing it in `NSEvent`'s vocabulary rather than SwiftUI's `EventModifiers`.

`Preferences` gains one field, following the `storedAgents` pattern exactly:

```swift
var storedTools: [ToolDefinition]?

var tools: [ToolDefinition] {
    get { storedTools ?? Self.fallbackTools }
    set { storedTools = newValue }
}

mutating func migrateToolsIfNeeded(terminalCommand: String) { … }
```

`migrateToolsIfNeeded` runs from `PreferencesStore.init`, is idempotent, and only fires when
`storedTools == nil`. **The one-shot materialisation is behavioural, not cosmetic.** Deleting
every tool must persist as `[]` and stay empty; a bare `?? defaults` getter with no
materialisation would resurrect Editor and Terminal on the next launch. Because the setter
writes `newValue` through unconditionally, `[]` round-trips as `[]`, and `fallbackTools` is only
ever a safety net for a blob that predates migration.

### Default tools

| Name | Symbol | Command | Shortcut |
|---|---|---|---|
| Editor | `chevron.left.forwardslash.chevron.right` | `$EDITOR ${cwd}` | ⌘O |
| Terminal | `terminal` | `open -b <resolved bundle id> ${cwd}` | ⌘T |

macOS exposes no "default terminal" setting, so `DefaultTerminalResolver` probes bundle ids in
order — iTerm2, Ghostty, WezTerm, Kitty, Alacritty, `com.apple.Terminal` — through an injectable
lookup (`NSWorkspace.urlForApplication(withBundleIdentifier:)` in production), and
`migrateToolsIfNeeded` bakes the winner into a **literal, editable command string**. The user
sees `open -b com.googlecode.iterm2 ${cwd}` in the pane and can change it; nothing resolves
magically at launch time. The probe runs once, at materialisation, which is the second reason
the migration is one-shot.

### 3.1 Normalizing agent-session facts

Everything a tool knows about the *agent* comes through `AgentAdapter`. Nothing in the tools
subsystem may read `Session.transcriptPath`, `Session.transcriptDirectory` or
`Session.pinnedConversationID`, and nothing there may call `ClaudeSession` (finding 5).

`AgentBinding` already normalizes conversation identity and transcript location. The gap is the
working directory, which has no accessor. One type and one method close it, both alongside
`AgentBinding` in `Agents/AgentKind.swift` and `Agents/AgentAdapter.swift`:

```swift
/// Where an agent is working right now, and what it is bound to. The adapter's answer to
/// "describe this live session" — callers never learn which agent produced it.
struct AgentLocation: Equatable, Sendable {
    let workingDirectory: String
    let binding: AgentBinding
}

// on AgentAdapter
func location(for session: Session) -> AgentLocation
```

**No protocol-extension default. Every adapter states its own answer.**

An earlier draft of this spec gave `location(for:)` a default returning
`session.transcriptDirectory`, and justified it as "shaped exactly like `rebind`'s". Review of
Task 1 showed that premise is false, so the conclusion it supported does not stand.
`rebind`'s default delegates to `binding(for:)` — a protocol *requirement* — which makes it
correct by construction for **every** conformer, present or future. A `location` default
hardcoding `transcriptDirectory` has no such property: that field is not derived from the
adapter at all, so a third adapter that simply failed to override would inherit an
unguaranteed working directory, with no compile error and no failing test to say so. Today's
agreement between claude and codex is a coincidence of two implementations, not a derivable
rule, and a default would have encoded the coincidence as though it were the rule.

Requiring the member costs two three-line implementations and buys compiler enforcement: a new
adapter cannot be written without answering "where does my agent work?". That the change forced
`location(for:)` onto five existing test stubs is the enforcement working — a default would
have silently absorbed all five.

`SessionStore` owns adapter resolution (`adapter(for:)`), so it is also where a context is
assembled — tools code never touches an adapter:

```swift
// SessionStore
func toolContext() -> ToolContext?   // nil when nothing is selected
```

It combines `adapter(for: session.agent).location(for: session)` with the facts that are Flight
Deck's own and not any agent's: the `Repo` the tab is filed under, the tab's title, and its
`AgentID`. `ToolContext` is a plain value type with no adapter or SwiftUI knowledge, which is
what keeps `ToolTemplate` a pure function.

## 4. Template expansion

`ToolTemplate.expand(_:in:)` is pure — no Foundation process API, no SwiftUI — so the quoting
rules are assertable without a window.

| Variable | Source | Example |
|---|---|---|
| `${cwd}` | `AgentLocation.workingDirectory` — where the agent actually is, worktree included | `~/Projects/fd/.claude/worktrees/tools` |
| `${transcript}` | `AgentLocation.binding.transcriptURL` | |
| `${conversationID}` | `AgentLocation.binding.conversationID` | |
| `${project}` | `Repo.url.path` — the filed project root | `~/Projects/fd` |
| `${root}` | alias for `${project}` | |
| `${projectName}` | `Repo.displayName` | `flight-deck` |
| `${session}` | `Session.title` | `tools` |
| `${agent}` | `AgentID` raw value | `claude` |
| `${home}` | `NSHomeDirectory()` | |

The first three come from the adapter (§3.1); the rest are Flight Deck's own facts.

There is deliberately **no `${sessionID}`**. It was the ambiguity finding 5 is about: a tab has
both a `Session.id` and a conversation id, they diverge the moment an in-session `/resume`
repoints the tab, and a variable named for both is a variable that is wrong half the time.
`${conversationID}` names the one a tool could act on. Flight Deck's internal tab UUID is not
exposed at all until something needs it.

Three rules matter:

**Substituted values are shell-quoted** — wrapped in single quotes with embedded `'` escaped as
`'\''`. `$EDITOR ${cwd}` over `~/My Projects/foo` must not word-split. This is the single most
likely correctness bug in the feature and the reason expansion is a tested pure function rather
than string interpolation at the call site.

**Names Flight Deck does not know are left literal**, and reach the login shell unchanged. This
is a documented property, not an oversight: it is what makes `$EDITOR` work at all, and it means
`${HOME}`, `$USER` and command substitution behave exactly as they would if typed. The cost is
that `${cwd}` shadows a shell variable of that name, which the pane's variable reference states.

**A known name with no value expands to `''`, not to nothing.** `AgentBinding.transcriptURL` is
Optional — its doc comment notes an agent that reports no transcript "is still usable" — so
`${transcript}` can legitimately have no value. Expanding it to the empty string would let the
command silently absorb the *next* argument into that position; expanding it to an empty quoted
string keeps argument count intact and fails visibly instead. This is the one case where a known
and an unknown name must behave differently, which is why they are separate rules.

When no session is selected there is no context at all — `SessionStore.toolContext()` returns
nil — and every tool is disabled rather than expanded against blanks (§6, §7).

## 5. Launching

```swift
@MainActor protocol ToolLaunching {
    func launch(_ command: String, in directory: String) 
}
```

`ShellToolLauncher` runs `$SHELL -lc '<expanded>'`:

- **Shell** comes from `PreferencesStore.resolvedShell()`, so the Shell & Environment pane's
  override applies here too.
- **`-l`** is what makes `$EDITOR` and the user's `PATH` exist at all (finding 6). `-c` takes the
  expanded template as one string, so shell syntax in a template — pipes, `&&`, quoting — works
  as written.
- **`currentDirectoryURL`** is set to `${cwd}`, so relative paths in a template resolve where the
  user expects and tools that read the cwd rather than argv still land correctly.
- **Environment** is `ProcessInfo.processInfo.environment` merged with
  `ShellPreferences.environment`. Deliberately *not* `PreferencesStore.sessionEnvironment()`:
  that method's `CLAUDE_CODE_CHILD_SESSION` blanking exists to protect claude's transcript
  writing, which is a session-creation concern with nothing to say about launching an editor.
- **The process is not waited on.** Flight Deck does not own the tool's lifetime.

### Failure reporting

`stderr` goes to a pipe rather than `/dev/null`, and a `ToolLaunchFailureReporting` seam — shaped
like `AgentLaunchFailureReporting`, sheet-on-window with an `NSLog` fallback when there is no
window — reports the last stderr line if the child exits non-zero within a **2.0s** grace window.
A child still alive after the grace window is assumed fine and forgotten.

This is beyond the literal ask and worth the code. The most likely first-run failure is `$EDITOR`
unset: the shell then runs a bare path, gets `permission denied`, and writes it to stderr. With
stderr discarded, the user presses ⌘O and *nothing happens at all*, on a feature whose entire
contract is "press key, thing happens." A launch that cannot fail visibly cannot be debugged by
the person it fails for.

## 6. The Tools menu

`ToolsMenuController` builds an `NSMenu` titled "Tools" and inserts it into `NSApp.mainMenu`
after View (before Window if View is absent), rebuilding whenever `preferences.tools` changes.

AppKit rather than SwiftUI `Commands`, for finding 1. Menu rather than a bare event monitor for
three reasons: the chord renders next to the tool's name, so the feature is discoverable;
`MenuKeyEquivalents` covers it with no changes (finding 2); and validation gets the disabled
state for free.

Items target the controller and validate through `validateMenuItem` on
`store.selectedSessionID != nil`. `SessionCommands` records that *a disabled `NSMenuItem` does not
fire its key equivalent* — normally a hazard, here exactly the desired behaviour: with no session
there is no `${cwd}`, so the item greys out and the chord is inert rather than launching a tool
against nothing.

A trailing separator and **Configure Tools…** open the Tools preferences pane.

## 7. The overlay

`ToolOverlay` is a SwiftUI view in `RootView`'s detail, stacked in a `VStack` at `.topTrailing`
with `SearchOverlay` above it so the find bar and the tool cluster never contend for the corner.
Chrome matches `TerminalSearchBar`: `.regularMaterial` in a `RoundedRectangle`, `.strokeBorder(
.separator)`, soft shadow. One circular symbol button per tool with `showsInOverlay`, in list
order, left to right, each with `.help("Editor ⌘O")`. Buttons are disabled with no selected
session, matching the menu.

### Visibility

A pure struct with no clock inside it, so all five transitions are assertable without a window:

```swift
struct ToolOverlayVisibility {
    static let idleTimeout: Duration = .seconds(5)

    mutating func mouseMoved(at: ContinuousClock.Instant)  // un-suppress, stamp
    mutating func keyPressed()                             // suppress
    mutating func hoverChanged(_ inside: Bool)             // pin
    func isVisible(at now: ContinuousClock.Instant) -> Bool
}

// isVisible == isHovering || (!suppressedByTyping && now - lastMove < idleTimeout)
```

Mouse movement over the terminal fades the cluster in; the first keystroke fades it out
immediately and keeps it out until the mouse next moves; five seconds without movement fades it
out on its own; hovering the cluster pins it so a button can actually be aimed at. Fades are
0.15s in, 0.4s out.

`ToolOverlayModel: ObservableObject` wraps the struct, republishing on each event and scheduling
a single one-shot wake at the idle deadline. It deliberately does **not** join `WatchClock`:
that clock exists to collapse *recurring polls* into one wakeup, and this needs one timer that
fires once and is usually cancelled first.

### Input

`ToolOverlayInputMonitor` is `SidebarInputMonitor`'s twin — one passive local monitor on
`[.mouseMoved, .keyDown]` that **never consumes an event**, so terminal input, hit-testing and
list dragging cannot change. It is scoped the same way, and for the same reason that file's doc
comment gives: a local monitor sees every event in the process, so it must prove what it is
looking at. A mouse move qualifies only when its window is the main window *and* hit-testing its
location resolves to the surface or a descendant of `TerminalHostView` — the same upward walk
`sidebarRow(under:)` performs. That avoids plumbing pane geometry out of SwiftUI, and stops the
cluster fading in when the pointer is merely crossing the sidebar.

Hovering the cluster itself hit-tests to the SwiftUI host rather than `TerminalHostView`, which
is precisely why pinning goes through `.onHover` on the view instead of through the monitor.

## 8. The preferences pane

A fourth tab in `PreferencesView` — `Label("Tools", systemImage: "wrench.and.screwdriver")`,
accessibility identifier `prefs-tools`.

- A reorderable `List` of tools showing icon, name, and chord, with +/− beneath. **Drag order is
  the overlay's left-to-right order** — the same "order is semantic" property `AgentSettings`
  has, and the pane says so.
- A detail `Form` for the selected row: Name; Icon (a button opening a searchable grid popover
  over a curated symbol set); Command in a monospaced field; Shortcut recorder; "Show in overlay".
- A footer listing every variable from §4, including the note that unknown names fall through to
  the shell.

Under the command field, a **live expansion preview** rendered against the currently selected
session, falling back to a sample context when nothing is selected. It costs nothing — expansion
is already a pure function — and it is what makes shell quoting visible up front rather than
something discovered the first time a path contains a space.

### `ShortcutRecorder`

Arms a local `keyDown` monitor and consumes the next chord. Esc cancels, Delete clears, and at
least ⌘ or ⌃ is required so a bare letter cannot be recorded into something that would hijack
typing. It walks `NSApp.mainMenu` for collisions and shows a non-blocking inline warning
("⌘R is already Rename Session") rather than refusing — the user may genuinely want to shadow
something. Local monitors run ahead of `NSApplication.sendEvent`, and therefore ahead of
`performKeyEquivalent`, so even ⌘Q is captured cleanly while armed.

## 9. Testing

Headless unit tests only (§2).

| Unit | Assertions |
|---|---|
| `ToolTemplate` | every variable; paths with spaces and embedded single quotes survive quoting; unknown `${…}` left literal; a nil `transcriptURL` expands to `''`; `$EDITOR` untouched |
| `AgentAdapter.location` | the extension default reports `transcriptDirectory` and the adapter's own binding; an adapter that overrides it is honoured (asserted through a stub, which is the point of the seam) |
| `SessionStore.toolContext` | nil with no selection; built from the *adapter's* location, proven by overriding the adapter via `overrideAdapter` and seeing the context change; project facts come from the `Repo`, not the agent |
| `ToolOverlayVisibility` | move → visible; +5s → hidden; keystroke → hidden immediately; move after keystroke → visible again; hover pins past the timeout |
| `ToolShortcut` | round trip to `NSMenuItem` key equivalent + modifier mask; `⌘⇧O` display string |
| `Preferences` | a `preferences.v1` blob with no `storedTools` decodes and materialises defaults; `[]` persists as `[]` across a save/load; full round trip |
| `DefaultTerminalResolver` | picks the first available bundle id from an injected lookup; falls back to `com.apple.Terminal` when none are found |
| `ShellToolLauncher` | `/bin/sh -lc 'exit 3'` reports through the seam; `exit 0` does not; a child alive past the grace window does not |
| `ToolsMenuController` | builds items with the right key equivalents from a tools array; rebuilds on change; validation false with no selected session |

## 10. Files

**New**, under `Sources/FlightDeck/Tools/` except where noted:

`ToolDefinition.swift`, `ToolShortcut.swift`, `ToolTemplate.swift`, `ToolContext.swift`,
`ToolLauncher.swift`, `ToolLaunchFailureReporter.swift`, `DefaultTerminalResolver.swift`,
`ToolsMenuController.swift`, `ToolOverlay.swift`, `ToolOverlayVisibility.swift`,
`ToolOverlayInputMonitor.swift`; and under `Preferences/UI/`, `ToolsSettingsTab.swift`,
`SymbolPicker.swift`, `ShortcutRecorder.swift`.

**Modified:** `Agents/AgentKind.swift` (`AgentLocation`), `Agents/AgentAdapter.swift`
(`location(for:)` plus its extension default), `SessionStore.swift` (`toolContext()`),
`Preferences/Preferences.swift` (the `storedTools` field, defaults, migration),
`Preferences/PreferencesStore.swift` (call the migration; expose `tools`),
`Preferences/UI/PreferencesView.swift` (the fourth tab), `RootView.swift` (the stacked overlay),
`AppDelegate.swift` (install `ToolsMenuController`), `project.yml` only if the new directory
needs declaring.

Note that `ToolContext` assembly lives on `SessionStore`, not `PreferencesStore`: the store owns
both adapter resolution and the `Repo` a session is filed under, and neither is a preference.

**Docs:** `docs/ARCHITECTURE.md` gains the tools spine; `README.md` gains a bullet.

## 11. Risks

- **The overlay could be occluded by the Metal layer.** `SearchOverlay` already floats over the
  same surface, so this is unlikely; if it happens, the fallback is an AppKit sibling view inside
  `TerminalHostView`, at the cost of hand-rolling hover, layout and material.
- **`mouseMoved` depends on a vendored tracking area.** Finding 3 rests on
  `SurfaceView.updateTrackingAreas`. `GhosttyEmbed/` is adapt-copied and re-pulled from upstream,
  so a future re-pull that drops `.mouseMoved` would silently break fade-in. The overlay
  visibility tests cover the state machine, not the event source, so this would surface as a
  behaviour report rather than a red test.
- ~~**`location(for:)`'s default is an inherited answer.**~~ **Resolved during Task 1**, not
  accepted. The risk as first written — a future agent silently inheriting the wrong `${cwd}` —
  was real, and the mitigation offered here (a documented override point) was too weak for it:
  nothing would have failed. `location(for:)` is now a protocol requirement with no default, so
  the compiler refuses an adapter that has not answered. See §3.1.
- **Menu insertion index.** SwiftUI owns `NSApp.mainMenu` and builds it asynchronously;
  `ToolsMenuController` must tolerate installing before the menu is fully populated and place
  itself by title lookup rather than a fixed index.
