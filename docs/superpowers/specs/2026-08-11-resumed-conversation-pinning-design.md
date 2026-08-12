# Resumed Conversation Pinning — Design

**Date:** 2026-08-11 · **Status:** design approved, ready for planning
**Builds on** `2026-08-10-session-name-sync-design.md` (session UUID ownership, transcript
watching) and `2026-08-11-session-status-indicators-design.md` (the `~/.claude/sessions`
registry).

## 1. Goal

When the user runs `/resume` inside the `claude` running in a session tab and picks a
different conversation, the tab follows: its title becomes the resumed conversation's, the
resumed conversation's UUID is pinned to the tab (so a relaunch reattaches to *it*, not to
the tab's original conversation), and if the resume moved the working directory the tab
moves to that project in the sidebar.

Scope is **in-session `/resume` only** — same process, same pid, new conversation. Flight
Deck offers no UI for choosing a conversation to resume; that is a separate increment.

## 2. This is partly a bug fix

An in-session `/resume` already breaks two things today, silently:

- `SessionStore.applyRegistry` joins on `entries[session.id]`. `claude` rewrites `sessionId`
  in its pid file, so the join misses and the row's status icon **disappears** — visually
  identical to "claude exited".
- `TranscriptWatcher` keeps tailing `<old-uuid>.jsonl`, which is never written again.
  Renames and sub-agent counts **stop arriving permanently**.

The tab is already lying after a `/resume`. This design is the fix; the pinning behaviour
falls out of fixing it properly.

## 3. Findings verified against the 2.1.227 binary

Empirical, from the installed `claude`, not inferred. These are the assumptions the design
rests on, so they are recorded with the evidence.

| Question | Answer | Evidence |
|---|---|---|
| Does `<pid>.json` track an in-process conversation switch? | **Yes**, in place | after registering, `claude` subscribes `Due(l => updatePidFile({sessionId: l}))` |
| Does it track a cwd change? | **Yes**, in place | the sibling subscription `n9i(l => updatePidFile({cwd: l}))` |
| Does resume change cwd? | It can | the resume handler calls `uw(…, Or.projectPath ?? In())`; a conversation carries its own project path |
| Is resume distinguishable from fork? | Not from the registry, and it needn't be | the handler branches `pn === "fork" ? "fork" : "resume"` but both land on a new `sessionId` |
| Does the registry `name` follow a resume? | Only when the resumed conversation **has** a name | the handler calls `dAe(Or.agentName, Y)`, and `dAe` early-returns on a falsy name, leaving the pre-resume value |
| What does `claude` call an unnamed conversation? | Its first real user message | `cba` → `CIn`: first `user` record that is not `isMeta` and not `isCompactSummary`, newlines collapsed, truncated |
| Is there a per-conversation "derived name" to adopt? | **No** | `sdu` returns `slug(basename(cwd))` (or `"claude"`) joined to one hex byte from `randomBytes(1)` — cwd-only, random suffix, generated once at registration and never recomputed |
| Is `sessions-index.json` usable? | No | stale v1 index, `firstPrompt: "No prompt"` rows, absent for this project's directory entirely |
| Is the pid file removed on exit? | Yes | `process.on("exit", () => unlinkSync(pidFile))` |

Two consequences shape everything below. First, **the registry is a sufficient and reliable
resume detector** — no pty inspection, no reading another process's environment, no pid
ancestry walking. Second, **the registry is not a reliable title source**, because `name`
and `sessionId` are separate writes through `pidFileWriteChain`, so a poll can observe the
new conversation still carrying the old name.

## 4. The identity split

`Session.id` currently does five jobs at once: SwiftUI row identity, the key for
`surfaces` / `watchers` / `statuses` / `subagentCounts`, the `--session-id` passed to
`claude`, the transcript filename, and the registry join key. Resume breaks that
conflation, so it has to be split.

```swift
struct Session: Identifiable, Equatable {
    let id: UUID                     // tab identity — immutable for the tab's life
    var title: String
    var workingDirectory: String     // was `let`; see §7
    var pinnedConversationID: UUID   // attached conversation; starts == id
}
```

**Stays keyed on `id`:** `surfaces`, `watchers`, `statuses`, `subagentCounts`,
`selectedSessionID`, notification identifiers, `.flightDeckActivateSession`, and the
persistence entry.

**Moves to `pinnedConversationID`:** `ClaudeSession.transcriptURL`, `TranscriptWatcher`'s
`custom-title` sessionId match, `ClaudeSession.resumeCommand`, and the registry join.

`ClaudeSession.launchCommand` keeps using `id` — at birth the two are equal, and a new
session's conversation UUID *is* the tab's UUID.

### Why not mutate `Session.id` instead

It is the `Identifiable` key. Changing it makes SwiftUI destroy and recreate the row, drops
`List(selection:)`, and silently orphans four dictionaries — including `surfaces`, which
frees the live terminal out from under the user. Delivered notifications lose their target,
and a resumed UUID could collide with another tab's `id`. Not a close call.

## 5. Detection: anchor on pid, follow forever

The join has to stop being by-conversation, because the conversation is the thing that
changes.

- **While the tab has no anchor**, match a registry row by the tab's current
  `pinnedConversationID` and record that row's `(pid, procStart)` as the tab's **anchor**.
- **While the tab has an anchor**, find its row by `pid` and never by conversation again.

Match-by-conversation is the one ambiguous operation, and the guarantee that it is
unambiguous is **conditional, not universal**. It holds exactly when the pinned conversation
is a UUID Flight Deck generated — which is the case for a tab's whole life up to its first
resume, and is why the first anchoring is sound: no other `claude` on the machine can be
running a conversation whose id we invented and passed as `--session-id`.

It stops holding after a resume. Anchoring runs whenever `anchors[tab]` is nil — including
re-anchoring after the anchored `claude` exits — and by then the pin may be a conversation
the user could equally open in a plain terminal. The residual case is precise: **the tab's
`claude` has exited after a resume, the tab has not been re-anchored, and the user resumes
that same conversation in some other process.** That row then matches the pin, and the tab
adopts a foreign process's status and pid.

This is accepted, not overlooked. It is strictly better than the pre-branch behaviour, where
a resume simply broke the join and the tab went permanently statusless; the failure needs a
dead tab process plus a deliberate resume of that exact conversation elsewhere; and the
symptom is a wrong status icon, not lost state — the tab's pin, title, and transcript are
untouched. Narrowing it would mean either refusing to re-anchor after a resume (which
reintroduces the statusless tab) or matching on something the registry does not expose.

`procStart` is required, not defensive. macOS recycles pids; `claude`'s own concurrency code
uses proc-start-time for exactly this purpose (`procIdentityOf`, `isSameProcess`). Same pid
with a different `procStart` is a *new process*, not a resume — anchor lost, not repinned.

### 5.1 Reconciliation is pure

Following the file's existing house style (`ClaudeStatusFile`, `SessionNotificationPolicy`,
`SessionCreateAction` are all pure statics), the decision lives in a new pure type and the
store only applies the result.

```swift
enum ConversationPin {
    struct Anchor: Equatable { let pid: pid_t; let procStart: String }

    struct Resolution: Equatable {
        var anchor: Anchor?          // nil == lost
        var conversationID: UUID     // possibly repinned
        var workingDirectory: String // possibly moved
    }

    static func resolve(
        conversationID: UUID,
        workingDirectory: String,
        anchor: Anchor?,
        rows: [pid_t: ClaudeStatusFile.Entry]
    ) -> Resolution
}
```

The store diffs each `Resolution` against current state and applies the deltas. **`sessionId`
and `cwd` are independent outcomes** — either can change without the other, so "repin" and
"move project" are separate effects rather than one coupled resume event.

### 5.2 Two existing units change

Both are currently tested; their tests change with them.

- **`ClaudeStatusFile.Entry`** gains `cwd: String` and `procStart: String`. Both fields are
  already in the JSON and already ignored. Decoding stays fail-closed: a row missing either
  field yields `nil`, same as every other required field.
- **`SessionStatusWatcher`** must emit **pid-keyed** entries. It currently collapses rows by
  `sessionId`, keeping the newest `startedAt`. That collapse destroys the mapping this
  design needs, and — now that two tabs on one conversation is a supported state (§8) — it
  would also hide a genuinely live second process. The dedupe moves out; the store joins.
  `SessionStore.applyRegistry`'s signature changes accordingly.

## 6. The repin sequence

Order is load-bearing at two points.

1. **Withdraw** any pending notification for the tab. It refers to a prompt in a
   conversation the tab has left.
2. Set `pinnedConversationID` to the new UUID.
3. Reset `subagentCounts[tab.id] = 0`. The outstanding `Agent` ids belonged to the old
   conversation and will never be answered in the new transcript.
4. Stop the old watcher. **Resolve the title (§9) off the main thread** and apply it.
5. **Then** start a new watcher on the new transcript, seeking to end as it already does.

Steps 4 and 5 must not swap. `TranscriptWatcher` seeds its offset to the file's current size
on first open specifically so a restored session does not replay history — but an old
`agent-name` record from the resumed conversation's past, arriving before the resolved title
lands, would clobber it. Resolve first, tail second.

**The transcript directory comes from the anchored row's `cwd`, not from the tab's
`workingDirectory`.** A resumed conversation carries its own project path, and the row is
authoritative about where `claude` is actually writing. One field read removes an entire
failure class.

## 7. Moving the tab to the new project

When the anchored row's `cwd` changes, the tab moves in the sidebar rather than staying put
with a divergent transcript path.

```swift
func moveSession(_ id: UUID, toProjectAt url: URL)
```

- The destination repo is found via the existing `indexOfRepo(for:)`
  (`standardizedFileURL.path` comparison). **If absent, it is created** — the same
  `repos.append(Repo(url:))` path `insertSession` already uses.
- The session **appends** to the destination repo's sessions.
- The source repo is **left in place even when its last session leaves**. A project with no
  sessions is a legitimate sidebar state. This deliberately does *not* mirror
  `closeSession`, which still prunes an emptied repo; unifying the two is a separate
  question, deferred.
- `Session.workingDirectory` becomes `var` and is updated. `SessionSnapshot.Entry`'s
  likewise.

An empty repo renders correctly as-is: `SessionSidebar` is
`ForEach(repos) { Section(repo.displayName) { ForEach(repo.sessions) … } }`, so a repo with
no sessions shows its header and nothing under it.

One consequence is accepted as-is: **an empty project does not survive a relaunch.**
`SessionSnapshot` stores only sessions and rebuilds `repos` from their `workingDirectory`
(§10), so a project with nothing in it has nothing to rebuild from. Persisting repos
independently belongs with the deferred empty-project work, not here.

### 7.1 Session creation follows the last active project

Allowing empty repos breaks an assumption `createFromMenu` currently makes, so the creation
path is corrected rather than left to drift.

**The naming was already wrong.** `SessionCreateAction.forState(hasSessions:)` is fed
`!repos.isEmpty`, which is "has projects", not "has sessions". Today those are the same
thing; with empty projects they are not. The parameter is renamed `hasProjects`, which is
what the call site always meant and what the behaviour should key on: **while any project
exists the button offers "New Session" (⌘N)**, and it only offers "Add Project" (⇧⌘A) when
the sidebar is genuinely bare. An empty project is still somewhere to put a session.

**The fallback chain was arbitrary.** With no selection, `createFromMenu` falls back to
`repos.first` — which may be an empty leftover the user has nothing to do with. It should
target the project the user was last working in. `SessionStore` gains:

```swift
private(set) var lastActiveProjectURL: URL?
```

- Updated whenever `selectedSessionID` changes to a locatable session, to that session's
  `workingDirectory`.
- Updated by `moveSession` (§7) when the session it moves is the selected one, so the
  remembered project follows a tab into its new home rather than pointing at the one it
  left.
- **Not cleared when the selection goes nil** (clicking below the last row), and not cleared
  when the project empties. That is the whole point: the target survives the tab leaving.
- Follows `closeSession`'s automatic reassignment, since that reassignment genuinely
  activates another tab.

`createFromMenu`'s `.newSession` path becomes: new session below the active one; else
`lastActiveProjectURL` **even when that repo is now empty**; else `repos.first`; else prompt
for a folder. No new insertion machinery is needed — `addProject(at:)` routes to
`insertSession`, whose `indexOfRepo(for:)` lookup already appends to an existing repo, and
an empty repo is found the same as any other.

Selection is unaffected: `selectedSessionID` holds the tab `id`, which does not change, so
SwiftUI animates the stable row from one section to the other rather than dropping it.

`workingDirectory` now carries a slightly different meaning after a move — it is the
project the row is filed under, which is also the directory the pane will respawn in on
relaunch. The *shell's* live cwd is unchanged by a resume; only `claude`'s project path
moved. Respawning in the new directory is the coherent choice because that is the project
the user can see the row belongs to, and `claude --resume <pinned>` sets its own project
path regardless. Nothing else reads `workingDirectory` in a way this breaks:
`newSessionBelowActive` creating a sibling in the *new* project is correct behaviour.

## 8. Conflict: two tabs on one conversation

A **continuously derived property of the session list**, not a check performed at resume
time:

```swift
static func conflicted(_ sessions: [Session]) -> Set<UUID>  // tab ids
```

Group by `pinnedConversationID`; any group larger than one flags every member. Recomputed
whenever a pin changes or the list changes, so it covers resume-onto-occupied in either
order, a restored snapshot that already holds a duplicate, and any future path that sets a
pin.

Both tabs stay pinned and both rows carry a conflict affordance (icon + tooltip). Flight
Deck reports what is true rather than policing it: two `claude` processes really are
appending to one transcript.

Three consequences, all deliberate:

- **Statuses stay independent.** The join is by pid, so each tab reflects its own process
  and its own permission prompt. No notification dedupe is needed, and none should be
  added — two prompts in two processes are two real prompts.
- **A `/rename` in either tab retitles both.** Correct: it is one conversation.
- **Sub-agent counts mirror each other**, since both watchers tail the same file. Ambiguous
  rather than wrong; left alone.

## 9. Title resolution

One background read of the resumed transcript, resolving in order:

1. The last `agent-name` / `custom-title` record in the file → that name.
2. Else, per `CIn`: the first `user` record that is not `isMeta` and not `isCompactSummary`,
   first text block, newlines collapsed to spaces.
3. Else the tab's existing title, unchanged.

Passed through the existing `ClaudeSession.sanitizedName`, so the 120-character cap and the
control/shell-metacharacter stripping already used for every other title apply here too and
the loop-suppression invariant in `applyExternalTitle` (stored title is byte-identical to
what would be injected) is preserved.

Split pure from I/O like `ClaudeSession` / `TranscriptWatcher` already are:
`ConversationTitle.resolve(lines:) -> String?` is pure and fixture-tested; a thin caller
does the file read on a background queue.

**Deliberately not the registry `name`,** even though it is one field away: `dAe` and the
`sessionId` write are separate hops through `pidFileWriteChain`, so a 500 ms poll can
observe the new conversation still carrying the old name. Pin from the registry, title from
the transcript — each field keeps a single authority and the race disappears rather than
being mitigated.

**A hand-typed sidebar title does not survive a resume.** The title always follows the
attached conversation. This is a behaviour change from the current "title is whatever you
last set" and is intended.

## 10. Persistence

`SessionSnapshot.Entry` gains:

```swift
var pinnedConversationID: UUID?   // absent in v1; absent means "never resumed"
```

**Optional is load-bearing.** Synthesized `Codable` uses `decodeIfPresent` for optional
properties, so every existing v1 snapshot decodes unchanged and the defaults key stays
`sessions.snapshot.v1`. A non-optional field would throw on decode and wipe every tab on
first launch after the update. On restore, `pinnedConversationID ?? id`.

`workingDirectory` becomes `var` (§7). Repos are still derived from it, so the grouping —
including a project that only exists because a tab moved into it — rebuilds for free.

Restore resumes the **pinned** conversation. The existing fallback still applies: if the
pinned transcript was pruned, `claude --resume <pinned> || claude --session-id <pinned>
--name '<title>'` recreates it under the pinned id, so the tab stays coherent instead of
showing a dead pane.

## 11. Failure modes and non-goals

- **Manual relaunch orphans a tab.** If `claude` exits and the user starts it again by hand,
  the new process has a random conversation id, matches no pin, and never anchors. The tab
  shows no status until the app restarts. This is today's behaviour; this change neither
  worsens nor fixes it.
- **Fork is handled for free.** `--fork-session` and an in-session fork also produce a new
  UUID and are indistinguishable here from a resume — correctly so.
- **Detection depends on undocumented internals.** If a future `claude` stops updating
  `sessionId` in place, detection stops silently: the tab keeps its old pin and its title
  goes stale. It fails closed, consistent with the posture the status-indicator design
  already took toward this registry.
- **No resume UI.** Choosing a conversation from within Flight Deck is out of scope.
- **No scrollback restoration**, unchanged from the session-name-sync design.

## 12. Testing

Pure, no filesystem and no terminal:

- `ConversationPin.resolve`: `sessionId` changes under a stable pid → repin; same pid with a
  different `procStart` → anchor lost, not repinned; row absent → anchor lost; `cwd` changes
  alone → move without repin; both change → both effects.
- `ConversationTitle.resolve(lines:)`: named conversation (last `agent-name` wins over an
  earlier one), unnamed → first user message, unnamed whose first records are `isMeta` /
  `isCompactSummary` → those skipped, empty file → nil.
- `ConversationPin.conflicted`: duplicate pins flag every member; distinct pins flag none.
- `ClaudeStatusFile.decode`: rows missing `cwd` or `procStart` fail closed.

Store-level, with the existing fakes:

- Repin keeps `id`, moves the pin, re-points the watcher, zeroes the sub-agent count,
  withdraws the notification, and persists.
- Move relocates the session, creates the destination repo when absent, and **leaves the
  source repo in place when it empties**.
- `lastActiveProjectURL` follows selection, follows a move of the selected session, and
  survives both a nil selection and its project emptying.
- `createFromMenu` with no selection creates in `lastActiveProjectURL` **even when that repo
  is empty**, rather than in `repos.first`, and only prompts for a folder when no project
  exists at all.
- `SessionCreateAction.forState(hasProjects:)` — existing cases updated for the rename; a
  sidebar holding only an empty project yields `.newSession`, not `.addProject`.
- A v1 snapshot without `pinnedConversationID` decodes with the pin defaulting to `id`.

**Not covered by the UITest gate.** Driving a real `/resume` through Claude's interactive
picker is not scriptable, and a fake would assert nothing about the mechanism this design
actually depends on. Left uncovered deliberately rather than covered dishonestly.
