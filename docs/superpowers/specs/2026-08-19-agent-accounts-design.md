# Agent Accounts — Design

**Date:** 2026-08-19 · **Status:** approved for planning · **Depends on:** agent adapters
([spec](2026-08-18-agent-adapters-design.md)), codex rollout observation (`b76a07b`), external
tools ([spec](2026-08-19-external-tools-design.md))

## 1. The problem

One machine, several logins. `nate@radify.io` and `nate@fieldwealth.ai` are separate Claude
accounts reached today by a shell alias:

```fish
alias cl='claude --dangerously-skip-permissions --chrome'
alias clf='env CLAUDE_CONFIG_DIR=$HOME/.claude-fieldwealth claude --dangerously-skip-permissions --chrome'
```

Flight Deck cannot express that. Every tab it spawns runs as whichever login owns the built-in
config directory, and there is no way to say "this repo is work."

Three capabilities, in the user's words: **inventory** the accounts on the machine, **add** new
ones, and **assign** them to projects.

### 1.1 Why this is not a preferences-only change

An account is not a setting an agent reads — it is the directory the agent *lives in*. Claude
writes its transcripts to `$CLAUDE_CONFIG_DIR/projects` and its status registry to
`$CLAUDE_CONFIG_DIR/sessions`; codex writes its rollouts and `session_index.jsonl` under
`$CODEX_HOME`. Those four locations are the substrate Flight Deck's sidebar reads for title
sync, activity glyphs, sub-agent counts and unread state.

Today all four are app-wide constants. A tab launched under a second account would therefore
show **no status and no inbound rename**, silently, with no error anywhere. Making accounts work
means making observation account-aware, which reaches `AgentAdapter`, `AgentRuntime`,
`SessionStore`'s instance registry, session persistence and the preferences schema.

## 2. Vocabulary: "account", not "profile"

`CLAUDE_CONFIG_DIR` and `CODEX_HOME` select **who you are logged in as**. Codex already uses
"profile" for something else — `codex -p <name>` layers `$CODEX_HOME/<name>.config.toml`, which
is configuration, not identity. Flight Deck says **account** throughout so the two never collide,
leaving `-p` available as a future `CodexThreadOptions` field.

## 3. Ground truth

Everything below was verified against this machine, not inferred.

| Fact | Evidence |
|---|---|
| An account's home holds its whole registry | `~/.claude-fieldwealth/` contains both `projects/` and `sessions/` |
| Account identity is readable from disk | `<home>/.claude.json` → `oauthAccount.emailAddress` (+ `organizationName`), giving `nate@radify.io` and `nate@fieldwealth.ai` |
| Codex's account boundary is `CODEX_HOME` | `~/.codex/auth.json` holds `tokens.id_token` and `tokens.account_id` |
| Codex's `-p` is config, not identity | `codex --help`: "Layer `$CODEX_HOME/<name>.config.toml` on top of the base user config" |
| Codex observation is live | `a8b2f9c` (rollout turn boundaries), `fb298ed` (`session_index.jsonl` renames), `481d0ea` (record→event mapping), `b76a07b` (deleted the notification path that never fired) |

### 3.1 Two hazards this design exists to fix

- `ClaudeSession.defaultProjectsRoot` and `SessionStatusWatcher.defaultRoot` hardcode
  `~/.claude/{projects,sessions}`.
- `CodexNameWatcher.defaultIndexURL` reads `CODEX_HOME` **from Flight Deck's own process
  environment** — one value, resolved once, for every tab. Now that codex observation actually
  fires, a codex tab on another home would have its renames tailed from a file it never writes.

## 4. Data model

```swift
/// One logged-in identity for one agent. `id` is opaque and permanent: renaming the label or
/// moving the directory never changes what sessions and projects point at.
struct AgentAccount: Codable, Equatable, Identifiable {
    let id: UUID
    var agent: AgentID
    var displayName: String
    /// Always concrete, never nil. `CLAUDE_CONFIG_DIR=$HOME/.claude` is exactly equivalent to
    /// setting nothing, so the built-in home is spelled out rather than special-cased — which
    /// removes a "nil means default" branch from every watcher and every launch path.
    var home: URL
    /// Display only, refreshed when Preferences opens. Never load-bearing: a menu must not
    /// touch disk, and a stale email must never affect which process is spawned.
    var cachedIdentity: AccountIdentity?
}

struct AccountIdentity: Codable, Equatable {
    var email: String?
    var organization: String?
    var readAt: Date
}

/// Absent entirely for a project the user has never configured — which is the default state.
struct ProjectSettings: Codable, Equatable {
    /// nil = "use global settings": inherit the global agent order.
    var defaultAgent: AgentID?
    /// Missing key = that agent's default account (top of its list).
    var accounts: [AgentID: UUID]
    /// Per agent, so switching which agent the pane edits never discards the other's values.
    var options: [AgentID: AgentOptions]
}
```

Accounts are stored as one flat ordered array, `Preferences.storedAccounts: [AgentAccount]?`,
filtered by agent for display. **Relative order within an agent's filter is that agent's default
ordering**; the topmost is the default. Optional-in-storage for the same reason `storedAgents`
and `storedTools` are: a blob written before this feature must decode cleanly rather than reset
every setting the user has.

`AgentID` gains `CodingKeyRepresentable` so the two dictionaries above encode as JSON objects
keyed `"claude"` / `"codex"` instead of Swift's default alternating-array form. The raw values
are already documented as a storage format; this keeps that promise legible on disk.

`Session` gains `accountID: UUID?`, persisted in `sessions.json`. **nil means the agent's
built-in home**, not "the current default". Every pre-existing tab decodes as nil and its
conversation genuinely does live in the built-in home, so legacy tabs stay correct even after the
user drags a different account to the top.

nil is a *storage* value only. Resolution normalises it immediately to the account whose `home`
equals the agent's built-in path — the one §10 seeds — so a legacy tab and a tab created today on
the same account share one identity everywhere downstream. Without that normalisation the built-in
home would carry two instance keys, which is the duplicate-home condition §9 rejects and would put
two `CodexStack`s on one `session_index.jsonl`.

The built-in account is therefore **not removable**: `−` is disabled for the account whose home is
the agent's built-in path. That is not a special case bolted on, it is what keeps nil resolvable.
An account being "built-in" is computed by comparing `home` to the built-in path, never stored.

### 4.1 Folding `globalFlags` into the agent list

`ClaudeOptionsPane` is currently documented as deliberately binding `Preferences.globalFlags`
rather than the claude row's `AgentOptions`, because `options(for:project:)` reads the former and
repointing the pane "would edit a value nothing reads." Once options are per-(project, agent),
that duplication becomes two competing homes for one setting. `agents[claude].options` becomes
the single source; `globalFlags` migrates into it and survives as a decode-only legacy field.

## 5. Resolution rules

All four live in `PreferencesStore` and are pure functions of `Preferences` plus a project path.

1. **Account** — `project.accounts[agent] ?? the first account for that agent in stored order`,
   with a nil `Session.accountID` normalised per §4. An id that no longer resolves is **broken**,
   never a fallback. Falling back would resume under the wrong
   login, find no conversation, and quietly start a fresh one — a silent data-attribution bug.
2. **Options** — global agent options merged with `project.options[agent]`. Claude reuses
   `FlagSetMerge`; codex needs the same field-wise merge written for `CodexThreadOptions`, where
   a nil project field inherits and a set field overrides. **Per-project options apply whenever
   that agent launches in that project, independently of `defaultAgent`.**
3. **Agent order** — `defaultAgent` promoted to the front, every other agent following in global
   list order; nil leaves the global order untouched. This feeds `NewSessionAffordance`, so
   ⌘N / ⌘⇧N / ⌘⇧⌥N re-slot per project and no agent is ever left unreachable by shortcut.
4. **Emptiness** — a `ProjectSettings` with no default agent, no account assignments and no
   non-empty options is removed, matching how an emptied flag override already drops a project
   from the Projects list today.

## 6. Launch: how an account reaches the process

The environment variable's *name* is agent knowledge, so it belongs on the adapter:

```swift
/// The environment that binds a process to this account. Claude answers `CLAUDE_CONFIG_DIR`,
/// codex `CODEX_HOME`; a third agent answers its own and no caller ever learns which.
func environment(for account: AgentAccount) -> [String: String]

/// How to sign this account in: the shell command, plus any text to inject once the agent is
/// up. Claude has no shell-level login subcommand — it authenticates inside a running session —
/// so it answers `("claude", "/login")` and the injection goes through the existing
/// `TextInjecting` path. Codex answers `("codex login", nil)`.
func loginInvocation(for account: AgentAccount) -> (command: String, inject: String?)
```

`PreferencesStore.sessionEnvironment(...)` takes the resolved account and merges that dictionary
over the user's shell variables. `SessionStore.insertSession` already assigns
`config.environmentVariables`, so the pty side is one parameter deep.
`CodexProcessTransport` gains a `process.environment` override so the app-server it spawns lives
in the same home as the tabs it serves.

External tools inherit the same environment: `ShellToolLauncher` spawns with the selected
session's account variables set. `0f27e6b` has just given that launcher an injectable
`environment: () -> [String: String]`, wired in `ToolLauncher.configured(_:)` to merge
`ShellPreferences.environment` over the process environment. That closure takes no session, so
the account overlay cannot go inside it — it must be applied at the launch call site, which is
the one place that already holds the `ToolContext` and therefore knows which account the selected
session runs as. No template change is needed for them to be usable —
`ToolTemplate.expand` already leaves unknown `${NAME}` literal for the login shell, so
`${CLAUDE_CONFIG_DIR}` resolves as a real shell variable. Two first-class names are added to
`knownNames` for convenience and safe quoting: `${account}` (display name) and `${accountHome}`.
Neither collides with `${home}`, which is `NSHomeDirectory()`.

## 7. Observation: fanning out per account

Both registries stop being keyed by agent alone.

| Today | After |
|---|---|
| `adapters: [AgentID: any AgentAdapter]` | `[AgentInstance: any AgentAdapter]` |
| `runtimes: [AgentID: any AgentRuntime]` | `[AgentInstance: any AgentRuntime]` |
| `codexStack: CodexStack?` | `codexStacks: [UUID: CodexStack]` |
| `codexHandshake: Task<Void, Error>?` | one per account |

where `AgentInstance` is a `Hashable` pair of `AgentID` and a **concrete** account id. The
optional lives only in `Session.accountID`'s storage; §4 normalises it away before any instance is
keyed, so one home can never map to two instances.

`CodexStack` already exists as the unit of lifetime — transport, rpc, adapter and runtime are
inseparable because all three depend on the one `CodexRPC` that talks to the one app-server. So
"one app-server per account" is a dictionary lookup, not a redesign. `bc60a7c` already narrowed
teardown to the specific stack a caller meant; `stopCodexIfUnused`'s "no codex tabs remain"
predicate narrows further to "no tabs remain **on this account**."

`CodexVersionProbe` stays global: the binary does not vary by home, so one probe serves every
stack.

Instances are built **on demand for accounts actually in use**, never for every account
configured. Two accounts in play means two status watchers, not one per row in the list.

Watcher roots, all currently app-wide, become functions of the account's home:

- `ClaudeAdapter.projectsRoot` → `<home>/projects` (already a closure — the seam working as
  designed)
- `SessionStatusWatcher` root → `<home>/sessions`
- `CodexNameWatcher` index → `<home>/session_index.jsonl`, replacing the read of Flight Deck's
  own `CODEX_HOME`
- codex rollout tailing → `<home>/sessions/…`

`SessionFixture` keeps its override but must now retarget **every** account at the fixture root
rather than a single global field. A fixture run that missed one would write into the real
`~/.claude/sessions`, which is the precise corruption `SessionFixture`'s own comments exist to
prevent.

## 8. User interface

### 8.1 Agents tab

The left list is untouched: still agents, still order-binds the New Session shortcuts. Putting
accounts in a two-level tree there was considered and rejected — child rows that do not
participate in position-counting make "position is the shortcut" a rule users get wrong, and
dragging becomes ambiguous.

The selected agent's detail pane gains an **Accounts** section: a listbox with drag-to-reorder
and `+` / `−` beneath it. Each row shows the display name over `email · organization` in
secondary text. A caption reads *"Projects that haven't chosen an account use the topmost one."*

Nothing nests under an account, so there is no second detail pane: **double-click a row to rename
inline**, right-click for **Relocate…**, **Sign In Again**, **Reveal in Finder**, **Refresh
Identity**.

### 8.2 Adding an account

Sheet with **Name** and **Location** (prefilled `~/.claude-<slug>` or `~/.codex-<slug>`, with a
Choose… escape). On confirm Flight Deck creates the directory, inserts the row, and offers **Sign
In Now**, which opens an ordinary session tab on the new account in the frontmost project with
the adapter's `loginInvocation`. Identity is re-read when the sheet closes and on
every Preferences open.

Re-login needs no separate machinery: **Sign In Again** is the same call.

### 8.3 Removing an account

Confirm sheet, two actions. Default is **Remove from Flight Deck** — registry entry only, the
directory untouched. Secondary destructive is **Also delete files…**, behind a second confirm and
hard-disabled while any session is bound to the account. `rm -rf` over a directory holding OAuth
credentials and every transcript for a login is not a one-click affordance.

If projects reference the account, the sheet states how many and clears those assignments as part
of the removal.

### 8.4 Projects tab

Restructured from a bare flag editor into a sectioned pane:

1. **Agent** — a dropdown whose first entry is `<Use global settings>` (the default). Selecting an
   agent both sets the project's default agent and chooses which agent the sections below edit.
2. **Account** — rendered only when the selected agent has two or more accounts. Offers
   *Default (<name>)* plus each account.
3. **Options** — `FlagEditor` for claude, `CodexOptionsForm` for codex, bound to
   `project.options[selectedAgent]` with the global values passed as `inherited`.

Because per-project options stay in force regardless of the dropdown, an agent's overrides can be
active while `<Use global settings>` is selected and the editor is hidden. The pane therefore
shows a line naming them — *"Codex has project overrides. Select Codex to edit them."* —
and **Remove Overrides** clears every agent's options and account assignments at once.

The empty state stops saying "override its Claude options."

### 8.5 New Session affordance

The sidebar button gains a chevron on its right: a menu of every agent, each listing its accounts
beneath when it has more than one, with a checkmark on whatever the project currently resolves
to. The app's New Session menu item renders the same entries — it is SwiftUI
(`SessionCommands.swift`), not AppKit; `258dc2f` never touched it (that commit built the *Tools*
menu, over `AppDelegate.swift`/`RootView.swift`/`Sources/FlightDeck/Tools/*`). The per-project
agent ordering this menu needs is delivered through `SessionCommands` reading
`agentOrder(forProject:)`, not through moving the menu into AppKit.

⌘N and its siblings keep launching the project's resolved default. The dropdown is for
departures, not for the common case.

### 8.6 Sidebar

A tab whose account differs from its project's resolved account shows a small account marker, so
a work session inside a personal repo is visible rather than silent.

## 9. Lifecycle and failure states

| Condition | Behaviour |
|---|---|
| Session's `accountID` resolves to nothing | Tab is broken and does not launch; `AgentLaunchFailureReporter` names the missing account |
| Account's home directory is gone at launch | Same, with a distinct message and **Relocate…** offered |
| Account exists but is not logged in | **Nothing.** The agent prompts inside the tab. Flight Deck must not attempt to detect login state |
| Project references a removed account | Cleared during removal; resolution falls to the agent's top account |
| Two accounts share one home directory | **Rejected at add and at relocate.** Two `CodexStack`s on one home would contend for the same `session_index.jsonl` writer lock (`1ad3d4d`) |
| codex is not installed | Unchanged: `CodexVersionProbe` still runs once, globally |

Relocate and delete are both disabled while any session is bound to the account — one predicate,
two call sites. It compares **resolved** account ids, so legacy tabs storing nil correctly count as
bound to the built-in account.

Reordering accounts affects **new** sessions only, and only in projects with no explicit
assignment. Nothing already running ever changes account.

## 10. Migration

Idempotent, run on load, in this order — accounts must exist before anything resolves against
them.

1. **`migrateAccountsIfNeeded`** — seed one account per agent at the built-in home (`~/.claude`,
   `~/.codex`), named from its readable identity or "Default". Then a **one-time discovery scan**:
   `$HOME/.claude-*` containing `.claude.json`, and `$HOME/.codex-*` containing `auth.json`,
   appended after the default. This picks up `~/.claude-fieldwealth` with no user action.
   Deliberately not re-scanned on later launches — a re-scan resurrects accounts the user
   removed. A **Scan for Accounts…** action covers additions made afterwards.
2. **`migrateProjectSettingsIfNeeded`** — each `projectFlags[path]` becomes
   `ProjectSettings(defaultAgent: nil, accounts: [:], options: [.claude: .claude(flags)])`. Every
   existing project lands in the unspecified state with its flags intact.
3. **`globalFlags` → `agents[claude].options`** (§4.1).

`projectFlags` and `globalFlags` remain as decode-only legacy fields. `sessions.json` needs no
migration: an absent `accountID` is nil is the built-in home, correct by construction.

## 11. Testing

Behaviour worth pinning, not coverage theatre:

1. **Resolution precedence** — project explicit → agent top → broken. Pure and exhaustive.
2. **Instance keying** — two accounts on one agent yield two adapters, two runtimes and two
   `CodexStack`s; one account yields one. `overrideAdapter` / `overrideRuntime` take the new key.
3. **Watcher roots derive from the account's home** — not `NSHomeDirectory()`, not the app
   process's `CODEX_HOME`. This is the test that would have caught the `CodexNameWatcher` hazard
   in §3.1, and the most valuable one here.
4. **nil normalisation** — a legacy tab and a new tab on the built-in account resolve to the
   same instance key, and building both yields exactly one `CodexStack`.
5. **Legacy decode** — a `sessions.json` with no `accountID` binds to the built-in home; a
   `preferences.v1` carrying `projectFlags` migrates with claude's flags intact and everything
   else unspecified.
6. **Per-project agent order** — default promoted to front, remainder in global order; nil leaves
   global order untouched.
7. **`CodexThreadOptions` merge** — nil project field inherits, set field overrides.
8. **`SessionFixture` retargets every account** at the fixture root; assert no resolved path
   escapes to the real `~/.claude`.
9. **Tools** — `${account}` / `${accountHome}` expansion, and account environment reaching
   `ShellToolLauncher`.
10. **Duplicate-home rejection** at add and relocate.

No committed test spawns a real `codex app-server` or touches a real account directory; the
existing opt-in integration tests keep that boundary.

## 12. Out of scope

- **Per-account default flags.** An account is an identity, not a config profile. Options belong
  to the agent and the project.
- **Detecting logged-out state.** The agent already reports it, in the tab, better than a poller
  could.
- **Copying settings between accounts.**
- **Switching a live tab's account.** Impossible in principle: the conversation lives in the home
  it was born in.
- **Codex's `-p` profiles.** A future `CodexThreadOptions` field, unrelated to identity.

## 13. Documentation to correct

- `docs/HANDOFF-agent-adapters.md` — the `AgentRuntime` row reads "App-wide **per agent kind**";
  it becomes per (agent, account).
- `docs/ARCHITECTURE.md` — the observation section's app-wide roots.
- `SessionStore.options(for:project:)` — the comment asserting codex has no project layer becomes
  false with this work.
