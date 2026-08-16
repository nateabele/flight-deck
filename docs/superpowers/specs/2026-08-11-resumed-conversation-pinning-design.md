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
follows `claude` to the transcript it is now writing — and to that project in the sidebar,
but only when that project is already open (§7).

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
    var workingDirectory: String     // the project the tab is filed under; was `let`, see §7
    var transcriptDirectory: String  // where `claude` is writing; see §6.1
    var pinnedConversationID: UUID   // attached conversation; starts == id
}
```

**Stays keyed on `id`:** `surfaces`, `watchers`, `statuses`, `subagentCounts`,
`selectedSessionID`, notification identifiers, `.flightDeckActivateSession`, and the
persistence entry.

**Moves to `pinnedConversationID`:** `ClaudeSession.transcriptURL`, `TranscriptWatcher`'s
`custom-title` sessionId match, `ClaudeSession.resumeCommand`, and the registry join.
`transcriptURL` takes a directory as well as a conversation, and that argument splits off in
the same way: it comes from `transcriptDirectory`, never from `workingDirectory` (§6.1).

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
        var workingDirectory: String // the row's reported cwd; see below
    }

    static func resolve(
        conversationID: UUID,
        workingDirectory: String,     // the tab's transcript directory, as a fallback
        anchor: Anchor?,
        rows: [pid_t: ClaudeStatusFile.Entry]
    ) -> Resolution
}
```

The store diffs each `Resolution` against current state and applies the deltas. **`sessionId`
and `cwd` are independent outcomes** — either can change without the other, so a repin and
whatever the cwd implies are separate effects rather than one coupled resume event.

`Resolution.workingDirectory` is a **reported** directory, not a decided project: the
resolver says where the process is and stops there. What that directory means is the store's
call, and it makes two of them from the one field — the transcript always follows it (§6.1),
the tab is refiled only if that directory is a project already open (§7). The parameter of
the same name is the fallback used when a row reports an empty `cwd`, and the store passes
the tab's **transcript** directory into it, never its project: falling back to the project
would move a worktree session's watcher back to the project's transcript on the first row
that happened to omit its cwd. The shared name is a wart — see FOLLOWUPS.

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

### 6.1 The transcript directory is a field of its own

`Session.transcriptDirectory` records where `claude` is writing, and is the only input to
`ClaudeSession.transcriptURL`'s directory argument. It equals `workingDirectory` at birth
and follows **every** reported cwd change thereafter, whatever that change means.

It has to be a separate field because the two questions a cwd answers have different
answers. `claude` derives its project directory under `~/.claude/projects` from its live
`process.cwd()`, so the transcript's location is a fact about the process and cannot be
declined: a tab that kept watching its project's transcript while `claude` wrote into a
worktree's would tail a file nothing appends to, and lose title sync and sub-agent counts
silently — the same permanent-silence failure §2 describes, arrived at from the other
direction. Which project the tab is *filed under* is a question about the sidebar, and §7
answers it differently.

Keeping them in one field is what made the sidebar bug unavoidable: whichever way that
single field resolved a worktree cwd, one of the two consumers was wrong.

Following it is `retarget(_:to:)` — store the directory, stop the watcher, start one on the
new transcript. There is no title read to defer to, unlike `repin` (§6): the conversation is
the same one, so its title is already right and only the path it is written at has moved. A
tick that repins does not also retarget, because `repin` already stores that directory and
rebuilds the watcher from it; keeping exactly one owner of "who repoints this tab's watcher"
per tick is what `repin`'s async title-read completion is written against.

**The transcript comparison is raw string equality, deliberately unlike the project
comparison in §7, which is symlink-resolved.** `ClaudeSession.encodedProjectDirName` is a
byte-for-byte encoding of the cwd string, so two paths `comparablePath` calls equal — a
symlink and its target — name two *different* transcript files. Normalizing here would
leave a project opened through a symlink watching a path `claude` never writes to. The
comparisons differ because the things being compared differ: project identity is about
which directory the user means, transcript identity is about which filename `claude`
produced.

## 7. Where a reported cwd goes: the transcript always, the sidebar conditionally

A changed `cwd` on the anchored row is not by itself evidence that the tab belongs to
another project. `EnterWorktree` changes `claude`'s cwd to
`<project>/.claude/worktrees/<name>` — a directory change *within* a project, and a routine
one. Treating every cwd change as a project move filed the tab under a phantom project
named after the worktree, one per worktree entered, and the user was left with a sidebar of
projects nobody opened. So the two effects are separated: the transcript retargets
unconditionally (§6.1), and **the tab moves only into a project the sidebar already holds.**

A cwd matching no open project moves nothing and creates nothing. That is deliberately not
"never move at all": a genuine resume into another project the user already has open is
still worth following, and the presence of that project in the sidebar is the available
evidence that the destination is a project rather than a subdirectory. Flight Deck cannot
tell the two apart from the path, and an already-open project is the one case where it does
not have to guess.

```swift
func moveSession(_ id: UUID, toProjectAt url: URL)
```

- The destination repo is found via the existing `indexOfRepo(for:)`, comparing paths
  standardized **and symlink-resolved**: `claude` reports `process.cwd()` with symlinks
  already resolved, while a path from the folder picker or a drop is not, so comparing them
  raw would move a symlinked project into a duplicate of itself. The registry path files the
  tab under the **repo's own recorded path** rather than the row's cwd, since those differ
  for a project opened through a symlink and `Repo.url` and `Session.workingDirectory` must
  not disagree about the project they both name.
- `moveSession` still creates an absent repo, because its other callers are explicit user
  actions where creating one is the whole point. The registry path never reaches that branch:
  it only calls `moveSession` once `indexOfRepo(for:)` has already found the destination.
- **There is no `restartsWatcher:` parameter.** It existed because `workingDirectory` fed
  `ClaudeSession.transcriptURL`, so a move changed where the tab believed `claude` was
  writing and the watcher had to be rebuilt — and because a repin in the same tick had
  already rebuilt it, the caller had to say which of the two owned that rebuild. With the
  transcript path on its own field, a move cannot change it, so `moveSession` touches no
  watchers at all and the coordination it needed disappears rather than being handled.
  Exactly one path repoints a tab's watcher per tick: a repin, or the retarget.
- The session **appends** to the destination repo's sessions.
- The source repo is **left in place even when its last session leaves**. A project with no
  sessions is a legitimate sidebar state. This disagreed with `closeSession`, which pruned an
  emptied repo, until the project-tabs work settled it the other way: a project's lifetime is
  now explicit everywhere, and only its own close button removes it.
- `Session.workingDirectory` becomes `var` and is updated. `Session.transcriptDirectory`
  (§6.1) is not — a move says nothing about where `claude` writes. `SessionSnapshot.Entry`
  carries both (§10).

An empty repo renders correctly as-is: the sidebar draws one row per project and one per
session, so a project with no sessions shows its header and nothing under it.

One consequence was accepted at the time: **an empty project did not survive a relaunch**,
because `SessionSnapshot` stored only sessions and rebuilt `repos` from their
`workingDirectory`. The project-tabs work removed that limitation by persisting projects in
their own right (`SessionSnapshot.projects`), so an empty project now comes back.

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
SwiftUI animates the stable row from one project's rows to another's rather than dropping it.

### 7.2 What a restored tab is rooted at

`workingDirectory` carries a narrower meaning after a move than it looks like it does — it is
the project the row is filed under, and nothing more. In particular it is **not** where the
pane respawns. A restored tab's terminal is rooted at `transcriptDirectory`, falling back to
the project only when that directory no longer exists (a worktree deleted between runs, which
is the ordinary end of one); the fallback resets `transcriptDirectory` to match, so the tab is
rebuilt as a project-directory session outright rather than persisting a dead path back out
and watching a transcript nobody writes.

Rooting the shell there is what makes the resume work at all. `claude` derives its project
path from the cwd it is started in, so a shell started at the project while the conversation
lives in a worktree finds nothing to resume and falls through to the
`|| claude --session-id <pinned>` half of §10's fallback: a live pane, the right title, and
none of the history. The shell's cwd and the watcher therefore read the same field, because
the two disagreeing means watching a file the process just started will never write.

Nothing else reads `workingDirectory` in a way this breaks: `newSessionBelowActive` creating
a sibling in the *new* project is correct behaviour, and per-project flag overrides are
resolved from `workingDirectory` on purpose, so a session running inside a worktree still
gets its project's flags rather than none.

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
var transcriptDirectory: String?  // absent pre-split; absent means "same as workingDirectory"
```

**Optional is load-bearing, for both.** Synthesized `Codable` uses `decodeIfPresent` for
optional properties, so every existing snapshot decodes unchanged and the defaults key stays
`sessions.snapshot.v1`. A non-optional field would throw on decode and wipe every tab on
first launch after the update. On restore, `pinnedConversationID ?? id` and
`transcriptDirectory ?? workingDirectory` — the latter is exactly right for a pre-split
snapshot, where the one field meant both things.

`transcriptDirectory` is written on **every** entry, not only the ones that diverge. Absence
is reserved for pre-split snapshots, and a file that names each tab's transcript directory
outright is the one place to see that a session is running somewhere other than the project
it is filed under — a worktree usually, but any undirected `cd` gets there — which is the
state the split exists for.

`workingDirectory` becomes `var` (§7). At the time this was written repos were derived from
it alone, so the grouping — including a project that only exists because a tab moved into it
— rebuilt for free. Since the project-tabs work `restore` builds in two passes: `snapshot.projects`
seeds the repos in their recorded order and with their collapsed state, and only then are
sessions filed, with derivation from `workingDirectory` as the fallback that keeps a snapshot
predating that field working. A tab that moved still lands in the right project either way;
what the second pass no longer decides on its own is the *order* projects appear in.

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
- **Phantom projects already in a sidebar are not migrated.** Stopping the rule from
  creating them (§7) does not retroactively fold the ones it already created back into their
  parent projects. A migration would have to guess which existing project a
  `…/.claude/worktrees/<name>` entry belongs under and move live sessions between projects at
  launch, on a heuristic, to save a one-time close-button click. The user closes them.
- **No resume UI.** Choosing a conversation from within Flight Deck is out of scope.
- **No scrollback restoration**, unchanged from the session-name-sync design.

## 12. Testing

Pure, no filesystem and no terminal:

- `ConversationPin.resolve`: `sessionId` changes under a stable pid → repin; same pid with a
  different `procStart` → anchor lost, not repinned; row absent → anchor lost; `cwd` changes
  alone → reported without a repin; both change → both reported. The resolver only reports;
  what a changed `cwd` *means* is §7's decision and is tested at store level.
- `ConversationTitle.resolve(lines:)`: named conversation (last `agent-name` wins over an
  earlier one), unnamed → first user message, unnamed whose first records are `isMeta` /
  `isCompactSummary` → those skipped, empty file → nil.
- `ConversationPin.conflicted`: duplicate pins flag every member; distinct pins flag none.
- `ClaudeStatusFile.decode`: rows missing `cwd` or `procStart` fail closed.

Store-level, with the existing fakes:

- Repin keeps `id`, moves the pin, re-points the watcher, zeroes the sub-agent count,
  withdraws the notification, and persists.
- Move relocates the session, creates the destination repo when called directly, and
  **leaves the source repo in place when it empties**.
- A registry cwd naming an open project moves the tab; a cwd naming nothing open moves it
  nowhere and **creates no project** — asserted on the repo list, since the failure it guards
  is a project appearing, not a session going missing. The worktree path
  (`<project>/.claude/worktrees/<name>`) is the fixture, because that is the shape that
  actually produced the phantoms.
- Either way the transcript follows: `watchedTranscriptURL(of:)` is the assertion, because
  presence of a watcher alone cannot catch one left behind on the pre-retarget path.
- A tab restored from an entry whose `transcriptDirectory` still exists starts its shell
  there and watches that transcript; one whose directory is gone starts at the project and
  persists the project back out, not the dead path.
- `lastActiveProjectURL` follows selection, follows a move of the selected session, and
  survives both a nil selection and its project emptying.
- `createFromMenu` with no selection creates in `lastActiveProjectURL` **even when that repo
  is empty**, rather than in `repos.first`, and only prompts for a folder when no project
  exists at all.
- `SessionCreateAction.forState(hasProjects:)` — existing cases updated for the rename; a
  sidebar holding only an empty project yields `.newSession`, not `.addProject`.
- A v1 snapshot without `pinnedConversationID` decodes with the pin defaulting to `id`, and
  one without `transcriptDirectory` with the transcript directory defaulting to
  `workingDirectory`.

**Not covered by the UITest gate.** Driving a real `/resume` through Claude's interactive
picker is not scriptable, and a fake would assert nothing about the mechanism this design
actually depends on. Left uncovered deliberately rather than covered dishonestly.
