# Account Sign-In and Removal — Design

**Date:** 2026-08-21 · **Status:** approved for planning · **Depends on:** agent accounts
([spec](2026-08-19-agent-accounts-design.md)), agent adapters
([spec](2026-08-18-agent-adapters-design.md))

## 1. The problem

Two of the Accounts pane's affordances (spec §8) do not work.

**Sign In does nothing.** Clicking "Sign In Now" after adding an account opens a session tab
whose terminal sits at a shell prompt with the literal text `claude` typed into it, unexecuted.
The same is true of "Sign In Again" in the row context menu, and of codex's `codex login`.

**Remove is impossible.** The `−` button under the Accounts list is disabled for every row a
user would want to remove: permanently for the seeded built-in account, and for any account with
a session tab open on it.

The two are unrelated in cause and share only the pane they live in.

## 2. Ground truth

Everything below was read from the tree at `d4e7f44`, not inferred.

| Fact | Evidence |
|---|---|
| `initial_input` is written to the pty verbatim | `SurfaceConfiguration.swift:99` passes it straight to `config.initial_input`; nothing appends to it |
| Every working producer terminates its own command | `ClaudeSession.launchCommand` ends `+ "\n"` (`ClaudeSession.swift:130`); `resumeCommand` likewise (`:148`) |
| `LoginInvocation` does not | `ClaudeAdapter.swift:70` → `command: "claude"`; `CodexAdapter.swift:225` → `command: "codex login"` |
| Sign-in passes it through unchanged | `SessionStore.openSignInSession` (`SessionStore.swift:1242-1249`) hands `typing` to `initialInput` |
| `injectRename` is the *rename* channel | wired at `SessionStore.swift:537` to `injectPendingRename`, which types `"/rename \(name)"` (`:2699-2712`) |
| `/` survives sanitization | `shellMetacharacters` is `;&|`$()<>` (`ClaudeSession.swift:77`), so `sanitizedName("/login")` returns `"/login"` intact |
| A deleted account id collapses to `nil` | `PreferencesStore.resolvedAccountID` (`:121-124`) returns `account(id:)?.id`, i.e. nil once removed |
| That flips a live tab's runtime key | `SessionStore.instance(for:)` (`:419-424`) keys on `resolvedAccountID` |

## 3. Defect one: the command is never executed

`initial_input` reaches the pty as typed characters with no implicit Return. `LoginInvocation.command`
carries no `"\n"`, so `claude` / `codex login` lands at the prompt and waits forever.

### 3.1 Fix

`openSignInSession` normalizes: append `"\n"` unless the command already ends in one.

The newline belongs in the store, not in each adapter's `LoginInvocation`. An adapter is asked
*what to run*; a future agent's author has no reason to know that the answer is fed to a pty
rather than to `Process`. Putting the normalization at the one consumer makes it impossible to
forget, and leaves `LoginInvocation.command` reading as a command — so the existing
`AgentAccountEnvironmentTests.testLoginInvocationsDifferInShape` assertion stands unchanged.

## 4. Defect two: `/login` is routed through the rename channel

```swift
// AccountsSection.swift:305-306
guard let inject = invocation.inject, let claude = adapter as? ClaudeAdapter else { return }
Task { await claude.injectRename(session.pinnedConversationID, inject) }
```

`ClaudeAdapter.injectRename` is a closure the store supplies (`SessionStore.swift:534-544`) whose
whole job is to queue a **rename**. It lands in `pendingRenames` and eventually types
`/rename /login` — renaming the conversation instead of authenticating, and clobbering any
genuine pending rename for that tab on the way. Fixing §3 alone therefore produces a running
`claude` that renames itself `/login`.

### 4.1 Fix, part one: the store owns both halves

`openSignInSession` takes the whole `LoginInvocation` rather than a `typing:` string, and is
responsible for both the command and the follow-up injection.

`AccountsSection.signIn` loses its `as? ClaudeAdapter` downcast entirely. A view has no business
knowing which adapter class it is holding; that downcast is precisely what dragged the rename
channel into a login. Afterwards the view reads the invocation off the adapter and hands it to
the store — nothing agent-specific remains in it.

### 4.2 Fix, part two: a deferred prompt that carries its own text

The injection cannot be attempted immediately. `SessionStore.inject` (`:2664-2695`) gates on
`statuses[id]?.activity == .idle` plus a readable one-row `InputBar` — neither holds during the
seconds `claude` takes to boot, so a single attempt is guaranteed to fail.

That retry machinery already exists as `pendingResumePrompts`: `[UUID: Date]`, a constant text
(`Self.resumePrompt`), flushed from `applyRegistry`'s `defer` (`:2896-2901`), a 120s deadline
(`resumePromptWindow`), and cancellation on `busy`/`waiting` via `cancelSupersededPrompts`.

Generalize it to carry its text:

```swift
struct DeferredPrompt { let text: String; let deadline: Date }
private var pendingPrompts: [UUID: DeferredPrompt] = [:]
```

Resume passes `Self.resumePrompt`; sign-in passes `invocation.inject`. Every existing rule
carries over unchanged, and each is correct for both callers:

- **Deadline.** A login window that never opened should expire the same way a resume prompt does.
- **Rename precedence** (`guard pendingRenames[id] == nil`). A user's rename still wins the input
  box; the login retries on the next tick.
- **Cancel on busy/waiting.** On a *fresh* home `claude` raises its own auth flow on first run,
  which registers as `waiting`. Typing `/login` on top of that would be wrong, so cancelling is
  the desired behavior, not merely a tolerable one.

**Alternative rejected:** a parallel `pendingLogins` queue. It duplicates ~15 lines and creates a
second home for the rename-precedence rule to drift out of.

## 5. Defect three: removal is blocked

`AccountsSection.canRemove` (`:57-59`) refuses two cases:

```swift
!account.isBuiltIn && !boundAccountIDs.contains(account.id)
```

Both go. The new rule is **"another live account exists for this agent"** — the `−` button is
disabled only for an agent's last remaining account, so the invariant "there is always at least
one account" holds. The built-in row is removable like any other.

### 5.1 Why the bound-sessions guard existed, and why a tombstone retires it

The guard was not arbitrary. `resolvedAccountID` collapses a *deleted* id to `nil`, so dropping
the record flips a live tab's `instance(for:)` key from `<id>` to `nil` mid-run. Its existing
`statusWatchers[<id>]` and `codexStacks[<id>]` can then no longer be matched by
`stopStatusWatchingIfUnused` / `stopCodexIfUnused`, and the next lookup at the `nil` key builds a
**second** codex app-server pointed at the built-in home, tailing the wrong `session_index.jsonl`.

Removing the guard without addressing that would ship exactly that bug. So removal becomes a
**soft delete**: the record is flagged, not dropped.

**The invariant this buys, and the whole reason for the design:** a tombstoned account *still
resolves by id*. `account(id:)` keeps returning it → `resolvedAccountID` keeps returning `<id>` →
`instance(for:)` keeps its key → watchers stay matchable and no second stack is ever built. The
tombstone does not merely tolerate the hazard; it removes it.

### 5.2 Model

`AgentAccount` gains `var removedAt: Date?` — nil means live. Synthesized `Codable` uses
`decodeIfPresent` for optional properties, so existing `storedAccounts` JSON decodes unchanged
and no migration is needed.

### 5.3 The reader split

This is the load-bearing part of the change. Every reader of `accounts` falls into exactly one
column, and a reader in the wrong one is a bug:

| Must still see tombstones (lookup by id) | Must skip them (lists and defaults) |
|---|---|
| `PreferencesStore.account(id:)` (`:107`) | `Preferences.accounts(for:)` (`Preferences.swift:189`) |
| `resolvedAccountID` — the stored-id branch (`:122`) | `account(for:project:)` topmost fallback (`:115`) |
| `SessionStore.accountIsMissing` (`:461`) | `resolvedAccountID` built-in fallback for nil (`:123`) |
| `sessionEnvironment(for:)` (`:236`) | `homeIsTaken` (`:168`) — so a removed home can be re-added |
| | `SessionCommands.swift:106` and `SessionSidebar.swift:459` |

`Preferences.accounts` stays the raw stored array: every write path (`addAccount`,
`renameAccount`, `relocateAccount`, `AccountsSection.refreshIdentity`) indexes into it by id, and
a filtered array would make those index writes land on the wrong record. The filtering lives in
the *accessors*: `accounts(for:)` gains a `removedAt == nil` filter, and a new flat `liveAccounts`
serves the two menu call sites.

### 5.4 The New Session menus

Both menus — the File menu (`SessionCommands.swift:106`) and the sidebar dropdown
(`SessionSidebar.swift:459`) — feed the flat `preferences.preferences.accounts` into
`NewSessionAffordance.menu`. Both switch to `liveAccounts`, so a tombstoned account disappears
from every "New … Session" affordance.

The knock-on is already handled by existing code and is the desired behavior: `menu` nests rows
into a submenu only when an agent has more than one account (`NewSessionAffordance.swift:99`), so
removing one of two accounts un-nests that agent's submenu back to a flat row, and
`shortcutLeaf`/`chords` move the agent's chord onto it. No shortcut is dropped.

`resolved:` comes from `resolvedAccounts(for:project:)` → `account(for:project:)`. An explicit
project assignment naming a removed account cannot linger, because `markAccountRemoved` clears
those assignments (§5.6); resolution falls through to the topmost live account.

### 5.5 Lifecycle

Tombstones exist only to protect *live* tabs, and at launch there are none — so they are purged
at launch. Nothing else prunes them; one mechanism, not two.

Concretely: a `mutating func purgeRemovedAccounts()` on `Preferences`, called from
`PreferencesStore.init`'s migration chain immediately after `migrateAccountsIfNeeded()` — after
seeding, so the guarantee "at least one live account per agent" is already established, and
before anything resolves against the list. Placing it in that chain also means it participates in
the `migrated != loaded` comparison, so the purge reaches disk on the launch that performs it
rather than waiting for the user's next preference edit.

The purge never empties `storedAccounts` to `nil`, so it cannot cause `migrateAccountsIfNeeded`
to re-seed on a later launch and resurrect what the user removed.

A restored tab whose account was purged is already handled and needs no new code:
`accountIsMissing` returns true, so `insertSession` sets no home variable at all, and `restore`
passes an empty `initialInput` — the shell starts no agent rather than silently booting into the
wrong login (`SessionStore.swift:1524-1533`).

### 5.6 `removeAccount` → `markAccountRemoved`

Stamps `removedAt` and keeps its existing second job: clearing every project assignment that
names the account, dropping any `ProjectSettings` record emptied by that clearing.

### 5.7 The dialogs

Both buttons are kept; only the wording and the guards change.

**First dialog** — title `Remove "<name>"?`, buttons `Remove from Flight Deck` /
`Also Delete Files…` / `Cancel`. Message gains permanence, and a second sentence only when the
account has live tabs:

> This can't be undone. The directory at ‹path› is left in place.
>
> N open session(s) are signed in to this account. They'll keep running, but Flight Deck will no
> longer offer this login.

**Second dialog** (`Also Delete Files…`) keeps its own separate confirmation, and names what is
lost — the account's credentials and transcripts — plus the live-sessions sentence when it applies.

`AccountsSection.remove` and `deleteFiles` re-check the last-account rule immediately before
acting, exactly as they re-check today: a dialog can sit open while the list changes underneath it.

**Accepted risk, stated rather than silently designed around:** `Also Delete Files…` is now
reachable while sessions are live, which trashes an OAuth token and transcript tree out from under
a running agent. This follows from "the button should never be disabled." The mitigation is
wording — the second dialog names the live sessions — not a refusal.

## 6. Testing

Every rule above is pure or store-level and therefore testable without a window; the SwiftUI body
remains a thin shell, per `AccountsSection`'s existing convention.

**Sign-in**
- `openSignInSession` produces an `initialInput` ending in `"\n"`, for both agents
  (`RecordingProvider` already captures configs — `AccountLaunchTests.swift:408`).
- A command that already ends in a newline is not double-terminated.
- Sign-in queues `invocation.inject` as a deferred prompt **and leaves `pendingRenames` empty** —
  the direct regression test for defect two.
- The deferred prompt flushes on a later `applyRegistry` tick once the tab reports idle, and
  expires at its deadline.
- Codex (`inject == nil`) queues nothing.

**Removal**
- A tombstoned account still resolves by id: `resolvedAccountID` and the `instance` key are
  unchanged, and `accountIsMissing` stays false.
- It is absent from `accounts(for:)`, from the topmost fallback, and from `homeIsTaken`.
- Both New Session menus exclude it; an agent dropping to one live account un-nests its submenu
  and keeps its chord.
- `canRemove` is false only for an agent's last live account — true for the built-in row and true
  for an account with bound sessions.
- `markAccountRemoved` clears project assignments naming the account.
- Purge at launch drops tombstones; a restored tab whose account was purged starts no agent.

## 7. Files touched

`Agents/AgentAccount.swift` · `Preferences/Preferences.swift` · `Preferences/PreferencesStore.swift` ·
`Preferences/UI/AccountsSection.swift` · `SessionStore.swift` · `SessionCommands.swift` ·
`SessionSidebar.swift`

Comment audit (per `docs/CONVENTIONS.md`): the doc comments on `canRemove`, `remove`,
`deleteFiles`, `boundAccountIDs`, `resolvedAccountID`, `removeAccount`, `openSignInSession` and
`ClaudeAdapter.injectRename` all describe rules this change replaces, and each must be rewritten
rather than left to outlive its code.
