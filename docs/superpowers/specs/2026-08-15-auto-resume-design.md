# Auto-Resume & Persisted Unread — Design

Date: 2026-08-15
Branch: `feat/auto-resume` (based on `master` @ `fe49c3f`)

Three related changes to what survives a Flight Deck restart:

1. A new **Claude** preference, *Auto-resume running sessions on restart*, **off by default**.
2. Each session's **activity is recorded in the snapshot as it changes**, so the next launch
   knows which sessions were mid-flight when the app went away.
3. **Unread marks survive a relaunch** — unconditionally, with no preference.

When the preference is on, a session that was `busy` or `shell` at shutdown is prompted with
*"Keep going"* once it has resumed and settled.

## 1. What already exists

The pieces this builds on, and the constraints each imposes.

| Piece | Where | What it constrains |
|---|---|---|
| `SessionSnapshot` | `SessionPersistence.swift` | Written on every mutation via `SessionStore.persist()`, atomically, to `~/Library/Application Support/Flight Deck/sessions.json`. |
| `restore()` | `SessionStore.swift:431` | Rebuilds each tab and hands libghostty an `initialInput` built by `ClaudeSession.resumeCommand`. |
| `applyRegistry(_:)` | `SessionStore.swift:1000` | Rebuilds `statuses` from `~/.claude/sessions/<pid>.json`. Early-returns when nothing changed. **Does not persist.** |
| `unreadIdle` | `SessionStore.swift:48` | `Set<UUID>`, documented as deliberately not persisted. |
| `flushPendingRename` | `SessionStore.swift:932` | The proven pattern for typing into a live session: defer until idle, kill-then-compare, inject, Return, yank-if-changed. |
| `InputBar` | `InputBar.swift` | Reads the prompt box off the screen. **Cannot tell a placeholder hint from a real draft** — only colour separates them, and libghostty returns no attributes. |

### 1.1 Two non-obvious facts that shape the design

**`SessionActivity` has four cases, not three.** `idle`, `busy`, `waiting`, and `shell` —
where `shell` means the model turn finished but a backgrounded Bash task is still running.

**A paste is not typing.** `TextInjecting.sendText` routes through libghostty's
`completeClipboardPaste`, and Claude Code enables bracketed-paste mode (2004), so any line
terminator inside the payload arrives as pasted *content* and never submits. Return has to
be a separate key event. This is why §4 extracts a helper rather than open-coding a second
injection site.

## 2. The preference

A new optional struct on `Preferences`:

```swift
/// Session lifecycle behaviour for the Claude tab.
struct ClaudePreferences: Codable, Equatable {
    /// Sessions that were mid-turn when Flight Deck last went away are prompted to
    /// continue once they have resumed and settled. Off by default: resuming work
    /// unattended is a decision the user has to make deliberately.
    var autoResumeRunningSessions: Bool

    init(autoResumeRunningSessions: Bool = false) {
        self.autoResumeRunningSessions = autoResumeRunningSessions
    }
}
```

added to `Preferences` as `var claude: ClaudePreferences?`.

**Optional is load-bearing, not stylistic.** `UserDefaultsPreferencesPersistence.load()`
decodes with `try?`, and synthesized `Codable` throws on a missing key rather than falling
back to a property default. A non-optional field here would fail to decode every existing
`preferences.v1` blob and silently reset every flag, project override and shell setting the
user has. This is the same trap already documented on `Preferences.confirmations`, and it is
guarded by a test (§6).

`PreferencesStore` gains an accessor in the `confirmsProjectClose` shape:

```swift
var autoResumesRunningSessions: Bool {
    get { preferences.claude?.autoResumeRunningSessions ?? false }
    set {
        var claude = preferences.claude ?? ClaudePreferences()
        claude.autoResumeRunningSessions = newValue
        preferences.claude = claude
    }
}
```

### 2.1 UI

`ClaudeSettingsTab` is today *only* a `FlagEditor`, and `FlagEditor` owns its own `Form`.
Stacking a second grouped `Form` above it reads badly and needs a hard-coded height.

Instead `FlagEditor` gains an optional `@ViewBuilder` header slot, rendered as a leading
`Section` **inside its existing Form**, defaulting to `EmptyView` so the Projects tab is
untouched. The Claude tab passes:

```
Section("Startup") {
    Toggle("Auto-resume running sessions on restart", isOn: …)
    Text("Sessions that were working when Flight Deck last quit are asked to continue
          once they have resumed. Sessions that were idle, or waiting on you, are left
          alone.")
        .font(.caption).foregroundStyle(.secondary)
}
```

The caption states the `busy`/`shell` rule in user-facing terms, because "running" is not
self-evident from the toggle label alone.

## 3. Recording what was running

Two new fields on `SessionSnapshot.Entry`, both optional for the reason in §2:

```swift
/// The session's activity when this snapshot was written, as `SessionActivity.rawValue`.
/// Absent means "no `claude` was registered for this tab" — which is not the same as idle.
var activity: String?
/// Whether this session finished while the user was looking elsewhere. Absent means false.
var unread: Bool?
```

`persist()` fills both from `statuses` and `unreadIdle`.

`applyRegistry` gains a `persist()` call after `statuses = next`. It sits **below** the
existing `guard next != statuses else { return }`, so it writes only on a genuine
transition — a handful of small atomic writes per minute at worst.

**Why continuous rather than at quit.** Recording once in `reapAllForQuit` would be cheaper
and would touch less of the schema, but it only covers a clean ⌘Q. A `SIGKILL` — which is
exactly how `scripts/swap-release.sh` stops the app — or a panic would leave nothing
recorded. An unplanned exit is the case auto-resume is *most* wanted for, so the record has
to be continuous.

Storing the raw activity rather than a `wasRunning: Bool` keeps the "which states count"
rule in one place in code (§4.1) instead of freezing it into the file format.

## 4. Restore and the resume prompt

### 4.1 Seeding

`restore()` gains two steps, both **before** it assigns `selectedSessionID`:

- Seed `unreadIdle` from entries with `unread == true`.
- If `preferences?.autoResumesRunningSessions == true`, collect entries whose recorded
  activity is `.busy` or `.shell` into `pendingResumePrompts`.

Ordering against the selection assignment is deliberate: its `didSet` clears the mark for
the tab you land on, which is correct — that tab is in front of you — and
`observeAppActivation` would clear it a moment later at launch regardless.

`waiting` is excluded. The thing the session was blocked on does not survive the restart, so
"Keep going" would answer a question that no longer exists.

### 4.2 Delivery

`pendingResumePrompts` is flushed from the same `defer` in `applyRegistry` that already
retries renames. Per tab the gates are `flushPendingRename`'s, for the same reasons:

- **Idle only.** A resumed `claude` needs seconds to boot; until it registers in the status
  registry there is nothing to type into. While `busy` the text would queue behind a running
  turn; while `waiting` a Return answers a dialog instead of submitting.
- **Single row only.** Ctrl+U kills one logical line and yank-pop replaces rather than
  appends, so a draft spanning rows cannot be taken apart and put back.
- **Kill, then compare.** `InputBar` cannot tell a placeholder from a draft, so the only way
  to learn whether the box was empty is to kill it and measure the effect.

### 4.3 The extracted helper

Rather than copy that body, the sequence

> kill line → settle → re-read → `sendText` → `sendReturn` → yank if the content actually
> changed

moves into one private method on `SessionStore`, and both `flushPendingRename` and the new
prompt flush call it. Duplicating it would mean two places to get bracketed-paste ordering
right, and the yank-only-on-confirmed-change rule exists to avoid pasting text the user
never typed into a box that was empty.

This is the only refactor folded into this change. It is in the code being modified, and it
is what keeps the second injection site from being a second chance to get §1.1 wrong.

### 4.4 Staleness

A pending prompt that never fires would sit in the set and fire *hours* later, when the
session finally idles and the user is long since working in it. Three rules prevent that:

| Rule | Behaviour |
|---|---|
| One-shot | Cleared the moment it is sent. |
| Cancel on activity | Dropped if the session reaches `busy` or `waiting` before firing — something is already working, so there is nothing to keep going. |
| Deadline | Dropped ~120 s after restore, via an injectable `now: () -> Date` seam in the `WatchClock` style. |

A tab with both a pending rename and a pending prompt gives the rename precedence: they
contend for the same input box, and a rename is a direct user action.

## 5. The pruning bug this exposes

`applyReadState` currently ends with:

```swift
unreadIdle.formIntersection(current.keys)
```

At launch `statuses` is empty until each `claude` re-registers, so the first registry tick
would wipe every restored mark before it was ever drawn. (`SessionStatusIcon` renders
nothing at all for a nil status, so the marks are invisible until then too.)

The fix is to prune only ids that *had* a status and lost it:

```swift
for id in previous.keys where current[id] == nil { unreadIdle.remove(id) }
```

A restored mark is in neither snapshot, so it survives until its own `claude` registers and
normal edge rules take over.

`closeSession` gains an explicit `unreadIdle.remove(id)`. The blanket intersection was
implicitly providing that; once it is narrowed, a closed tab's id would otherwise leak.

### 5.1 Structuring for the state machine that should follow

This bug is evidence of a real structural gap: three consumers — `applyReadState`,
`deliverNotifications`, and now prompt cancellation — each re-derive the same
`old`/`new` edge independently from the same pair of dictionaries, and each gets to be
subtly wrong on its own.

A full state machine over `SessionActivity` transitions is **out of scope here** and is
recorded in `docs/FOLLOWUPS.md` with this bug as its motivating evidence. What this change
does do is stop making it worse: `applyRegistry` computes the per-session transition set
**once** and passes it to all three consumers, rather than handing each one the raw
before/after maps to re-walk. That is the seam a state machine would slot into later.

## 6. Testing

| Area | Test | Asserts |
|---|---|---|
| Preference | `PreferencesStoreTests` | Defaults off; round-trips through save/load; **a `preferences.v1` blob written without the `claude` key still decodes and preserves every other setting.** |
| Snapshot | `SessionPersistenceTests` | `activity`/`unread` round-trip; a snapshot lacking both keys still decodes and restores every tab. |
| Recording | `SessionStoreTests` | `applyRegistry` persists on a genuine transition, and does **not** persist when nothing changed. |
| Seeding | `SessionAutoResumeTests` (new) | Pref off → nothing pending. Pref on + recorded `busy`/`shell` → pending. Recorded `idle`/`waiting`/absent → nothing pending. |
| Delivery | `SessionAutoResumeTests` | Fires once when the session lands idle; not before. Cancelled by `busy` before firing. Dropped past the deadline. Rename wins when both are pending. |
| Injection helper | `SessionRenameTests` | Existing rename behaviour is unchanged by the extraction — the yank-only-on-confirmed-change rule in particular. |
| Unread | `SessionReadPolicyTests` / `SessionStoreTests` | Restored marks survive a first tick with an empty registry; are dropped once their status has existed and gone; the selected tab comes back read; a closed tab leaves no entry behind. |

No UI test. The GUI smoke suite steals focus for ~40 s per run, and everything above is
reachable from the unit layer through the existing `injectionSettle`, `appIsActive`, and
persistence seams.

## 7. Out of scope

- A state machine over status transitions (§5.1) — `FOLLOWUPS.md`.
- Configurable prompt text. "Keep going" is a constant; a preference for it can follow if
  the fixed string proves wrong in use.
- Marking a session unread because it was interrupted mid-flight. `unread` means "finished
  while you were away", and `SessionStatus.tooltip(unread:)` says exactly that — an
  interrupted session has not finished, and the tooltip would be a lie.
