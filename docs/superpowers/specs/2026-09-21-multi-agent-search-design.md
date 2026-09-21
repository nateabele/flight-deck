# Multi-agent ⌘K search

**Status:** design
**Date:** 2026-09-21

⌘K searches Claude conversations only. This makes it search every agent's, starting with
codex, by moving the three agent-specific jobs — *find the transcripts*, *parse a line*,
*name the conversation* — behind one capability object on `AgentAdapter`, so a third agent
becomes searchable by conforming rather than by editing the search subsystem.

---

## 1. What is Claude-specific today

The ⌘K stack is seven pieces. Four are already agent-blind; five assumptions are not.

| Piece | File | Agent-neutral? |
|---|---|---|
| Menu item → notification | `Search/SearchCommands.swift` | yes |
| Corpus discovery | `Search/SearchCorpus.swift` | **no** |
| Backfill walker | `Search/SearchIndexBuilder.swift` | **no** (two call sites) |
| Line → messages | `Search/TranscriptExtractor.swift` | **no** |
| Index (SQLite FTS5) | `Search/SQLiteSearchIndex.swift` | yes — schema is agent-blind |
| Ranking + overlay | `SearchRanker`, `SearchModel`, `SearchPanel` | yes |
| Activation | `SearchActivation.plan` → `SessionStore.openConversation` | **no** |
| Live ingest | `ClaudeRuntime.attach`'s `onMessages` | **no** — only leg that exists |

The five assumptions, precisely:

1. **`SearchCorpus`** maps a project path to `~/.claude/projects/<encoded-cwd>` via
   `ClaudeSession.encodedProjectDirName`. Codex writes rollouts into a *date tree*
   (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`) and records the cwd **inside**
   the file, in the first `session_meta` record. No encoding relates the two.
2. **`SearchIndexBuilder`** calls `TranscriptExtractor.messages` (:89) and
   `ConversationTitle.resolve` (:111) directly. Both are Claude-JSONL parsers. Everything
   else in that actor — batching, offsets, cancellation, prune, the `offset: 0` restart
   rule — is already agent-blind.
3. **`SessionStore.openConversation`** is literally `launchAccount(for: .claude, …)` (:3955),
   and `resolvedTranscriptDirectory` re-derives the directory by probing for
   `<uuid>.jsonl` under the Claude encoding. The method's own comment at :3985 anticipates
   this: *"a default would decide this the wrong way round on the first day search learns
   about codex."*
4. **No row carries an agent.** `TranscriptHit`, `NameCandidate`, `IndexedConversation` and
   the `conversation` table are all agent-free, so a result cannot say which adapter should
   resume it. `TranscriptHit` lives in `FleetKit`, so this is a phone-wire change too.
5. **Live ingest exists only in `ClaudeRuntime`.** `CodexRolloutWatcher` tails the same way,
   through the same `TailReader`, but has no `onMessages` leg.

### 1.1 A bug this uncovered

`AppDelegate.swift:249` passes `ClaudeSession.defaultProjectsRoot` — one hardcoded root. A
second Claude login is a second `CLAUDE_CONFIG_DIR` with its own `projects/` tree, so **⌘K
is already blind to every conversation under a non-default Claude account.** Codex forces
per-account discovery anyway (each `CODEX_HOME` has its own `sessions/` and
`session_index.jsonl`), so taking accounts rather than a root fixes this for free. It is in
scope.

## 2. Measurements

Taken on the build machine, 2026-09-21, against codex-cli 0.154.0. These decided three
design choices, so they are recorded rather than summarised.

```
563 rollouts, 67 MB total          (Claude's corpus: 684 MB)
first-line walk of all 563:  0.08s
source:      exec 487  ·  vscode 62  ·  cli 8
cwd:         /Users/me/Projects/crate-runner → 485 of them
session_index.jsonl: 95 lines, {id, thread_name, updated_at} only — no cwd, no path
interactive rollouts: 70, of which 66 named in session_index
```

Three consequences:

- **Discovery is free.** A filesystem walk reading each rollout's first line costs 0.08s for
  the whole tree. It beats the `thread/list` RPC outright — see §10.
- **There is no cheap codex-wide index.** `session_index.jsonl` is rename-only (95 entries,
  no cwd, no path) and `thread_history_1.sqlite` is a recent-turns projection (85 turns
  against 563 rollouts). The rollouts *are* the corpus.
- **86% of rollouts are headless `codex exec`**, concentrated in one repo. They need their
  own ranking tier (§7) or one project's automation buries its conversations.

## 3. Decisions

| Question | Decision |
|---|---|
| Scope | **Full parity** — every historical codex thread whose cwd is a sidebar project |
| `codex exec` runs | **Indexed, ranked below** interactive threads |
| Phone | **Included in this work** — wire change, phone ranks identically |
| Placeholder names | **First user message beats `session N`**; real renames still win |
| Protocol shape | **Capability object on `AgentAdapter`** |

## 4. The protocol change

A capability object, following the exact precedent of `openPromptReader`, `dialogDriver` and
`textChannel`: an object rather than methods returning nil, because `nil` must mean *this
agent is not searchable* as a stated answer the overlay can surface — distinct from
*searchable, nothing found*. Like those three it is a `static let` on the adapter, so there
is one shared instance per agent and no per-account construction.

**Unlike those three it is `Sendable` and `nonisolated`, not `@MainActor`.** Its callers are
the `SearchIndexBuilder` actor and a `Task.detached` inside it — the backfill runs off the
main actor precisely so parsing 750 MB cannot stall agents running in the same process.
Every member is therefore a pure function of its arguments, which is also why `indexedName`
is resolved at walk time (§4.1) rather than cached behind a lock.

```swift
/// **Everything the ⌘K index needs from one agent, and nothing about how it stores it.**
///
/// Three jobs: find this agent's transcripts, turn one of its lines into indexable
/// messages, and say what a conversation is called. An adapter that answers `nil` for
/// `searchCorpus` is not searchable, and that is an answer — the overlay says so rather
/// than silently omitting the agent, which is indistinguishable from "you have no
/// conversations there".
protocol AgentSearchCorpus {
    /// Every transcript this agent has written that belongs to one of `projects`, newest
    /// first, across every one of `accounts`.
    ///
    /// Accounts rather than a root: a transcript's home is per-account for both agents
    /// (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`), and passing one root is the bug in §1.1.
    func transcripts(
        forProjects projects: [String], accounts: [AgentAccount]
    ) -> [TranscriptRef]

    /// One line of this agent's transcript, as indexable messages. Pure; same shape as
    /// `AgentAdapter.timelineItems(inLine:at:)` and tested the same way, from fixtures.
    func indexedMessages(
        inLine line: String, conversationID: String, at offset: Int
    ) -> [IndexedMessage]

    /// What this conversation is called, judged from the lines read in THIS pass.
    ///
    /// A verdict rather than a `String?` because the builder's overwrite rule needs to know
    /// *why* it got a name. A later pass sees only newly appended lines, so a derived name
    /// must never overwrite a real one that an earlier pass already stored — the rule
    /// `SearchIndexBuilder.containsRename` implements today for Claude, generalised.
    func conversationName(inLines lines: [String], for ref: TranscriptRef) -> ConversationNaming
}

enum ConversationNaming: Equatable {
    /// A real rename. Overwrite whatever is stored.
    case authoritative(String)
    /// Derived (a first user message, a placeholder). Write only when nothing is stored.
    case fallback(String)
    /// Nothing in this pass. Leave what is stored alone.
    case unknown
}
```

On `AgentAdapter`, beside the three existing capability objects:

```swift
/// **How this agent's history becomes searchable — or `nil`, the refusal.**
static var searchCorpus: AgentSearchCorpus? { get }
```

No default implementation. `AgentAdapter`'s existing defaults exist for members with a
genuine majority answer (`rebind`, `environment`); this has none, and a silent default is
how a third agent would ship looking searchable and finding nothing.

### 4.1 `TranscriptRef`

`SearchCorpus.Entry` is `(projectPath, directory)` — a *directory per project*, which is
Claude's encoding baked into the type. Codex has no such directory. The adapter therefore
hands back transcripts, not folders:

```swift
struct TranscriptRef: Equatable, Sendable {
    /// codex: the rollout. claude: `<conversation-uuid>.jsonl`.
    let url: URL
    /// The sidebar project this is attributed to.
    let projectPath: String
    /// The account home this transcript was found under — `CODEX_HOME` or
    /// `CLAUDE_CONFIG_DIR`. Carried per-transcript rather than left to the caller because
    /// naming needs it: codex's names live in that home's own `session_index.jsonl`, and
    /// `searchCorpus` is reached statically (§4.2), so there is no instance holding an
    /// account for `conversationName` to consult.
    let accountHome: URL
    /// The literal directory the conversation ran in — the project itself, or one of its
    /// worktrees. Captured HERE, at walk time, because that is the only moment it is known
    /// without guessing: Claude's directory encoding is one-way (see `SearchCorpus`'s doc
    /// comment) and codex records its cwd only inside the file. Storing it kills
    /// `SessionStore.resolvedTranscriptDirectory`'s probe entirely — see §8.
    let workingDirectory: String
    let conversationID: String
    let agent: AgentID
    /// codex: `session_meta.payload.source` — "exec", "cli", "vscode". nil for claude.
    /// Drives the ranking tier in §7 and nothing else.
    let provenance: String?
    /// The name this agent records for the conversation OUT OF BAND, if any — codex's
    /// `session_index.jsonl` entry. nil for claude, whose names are in the transcript.
    ///
    /// Resolved here, during the walk, rather than by `conversationName` on demand: the walk
    /// already visits each account once, so one read of that account's index serves every
    /// rollout under it, and `conversationName` stays a pure function of things it was
    /// handed. Resolving it on demand would mean 563 reads of a 95-line file, or a cache
    /// inside a `Sendable` type that is called off the main actor.
    let indexedName: String?
    let modified: Date
}
```

### 4.2 Reaching it without an adapter instance

`AgentAdapter`'s capability objects are read through a hand-written switch on `AgentID`
(`extension AgentID { var textChannel … }`), not off an adapter instance, and that extension
states why: *"a capability is a property of the agent, not of one account's live stack"*,
and its callers hold only a tab id and cannot afford to build a runtime to ask a question.
`searchCorpus` joins that extension for a stronger version of the same reason — the backfill
runs from `AppDelegate.startSearch`, which has no adapters and no accounts' live stacks at
all, three seconds after launch.

```swift
extension AgentID {
    /// See `AgentAdapter.searchCorpus`. Consulted by `AppDelegate.startSearch`'s backfill
    /// and by `SessionStore.openConversation`.
    var searchCorpus: AgentSearchCorpus? {
        switch self {
        case .claude: ClaudeAdapter.searchCorpus
        case .codex: CodexAdapter.searchCorpus
        }
    }
}
```

This is where "a new adapter works seamlessly" is actually enforced: the switch is
exhaustive over a `CaseIterable` enum, so adding a third `AgentID` case **fails to compile**
until it answers here — the same gate the other five capabilities already stand behind.

### 4.3 What `SearchIndexBuilder` becomes

Agent-blind. Its two Claude call sites become `corpus.indexedMessages(...)` and
`corpus.conversationName(...)`, and `build` takes `[TranscriptRef]` instead of
`[SearchCorpus.Entry]` plus its own `transcripts(in:)` walk. Everything that makes it
correct — batching at 500, the `offset: nil` live-ingest rule, the `offset: 0` restart rule,
per-file cancellation, prune-before-add, newest-first ordering — is untouched and stays
where it is. `SearchCorpus` itself survives as Claude's implementation detail, moved under
`Agents/` beside `ClaudeAdapter`, because `candidateWorkingDirectories` is still what maps a
project to its worktrees and **codex needs it too** (§5.2).

**One build pass over the union of agents, never one pass per agent.** `build` opens with
`prune(keepingSources:projects:)`, which drops every source outside the set it is handed —
so a per-agent pass would delete the other agent's rows on every run, and the two would take
turns wiping each other. `AppDelegate.startSearch` therefore assembles the refs first —
`AgentID.allCases.compactMap(\.searchCorpus)`, each asked for its transcripts, results
concatenated and sorted newest-first — and hands `build` one list. This is the single most
likely way to get a plausible-looking half-empty index, so the prune contract is asserted
directly: a test builds with both agents' refs and confirms neither agent's rows are pruned.

## 5. Corpus discovery

### 5.1 Claude

Today's logic, unchanged in substance: for each account, for each project, encode the
project and its worktrees, accept exact directory-name matches under that account's
`projects/` root, enumerate `*.jsonl`, skip subdirectories (subagent transcripts).
`workingDirectory` is the candidate path that produced the match — known for free, no longer
thrown away.

### 5.2 Codex

For each account, walk `<home>/sessions/**/*.jsonl` and read **only the first line** of
each, which is `session_meta` and carries `session_id`, `cwd`, `source` and `originator`.
Attribute by **exact match of `cwd`** against `candidateWorkingDirectories(forProjectAt:)`
for each sidebar project — the same worktree-aware set Claude encodes, compared literally
instead of encoded. A `cwd` matching no sidebar project is skipped, which is what keeps
scratchpad threads (`/private/tmp/…`) and unopened repos out.

Measured cost for the whole tree: 0.08s for 563 files. It runs inside the existing
`SearchIndexBuilder` actor, off the main actor, already deferred 3 s off the launch path.

`~/.codex/archived_sessions/` is **not** walked. `thread/archive` moves a rollout out of
`sessions/` as part of releasing it (`CodexAdapter` documents this); resurrecting archived
threads in ⌘K would undo an explicit put-away.

**The failure mode to guard.** `cwd` is compared as a literal string, exactly as
`CodexAdapter.threads(inDirectory:)` warns for `thread/list`: a `/private` prefix, a
resolved symlink or a trailing slash is indistinguishable from "no threads here". Both sides
are normalised through one helper before comparison, and a test covers the `/private/var`
vs `/var` case specifically, because macOS produces it routinely.

## 6. Extraction and naming

### 6.1 Codex extraction

Prose from the `event_msg` family only — `user_message` → `.user`, `agent_message` →
`.assistant`. This is `CodexTimelineMapper`'s documented rule and the reasoning transfers
exactly: the `response_item` family is the *model transcript*, carrying a second copy of the
prose, plus a `role:"user"` record that is the assembled prompt (skills, plugin catalogue,
environment context — tens of KB every turn), plus `reasoning` with an encrypted blob.
Indexing it would double every reply and put instruction blobs into search results.

`agent_reasoning` is **not** indexed. It earns a timeline row but not an index row: it is
not something a person or an agent said, and it is the same category `TranscriptExtractor`
already drops tool blocks for — "searching `rename` should find the message where somebody
asked for a rename, not everything that mentions it."

Timestamps come from the record's own `timestamp`, which codex writes as
`2026-09-16T16:25:50.889Z` — fractional seconds, so the extractor needs
`.withFractionalSeconds` for the reason `TranscriptExtractor` already documents.

### 6.2 Codex naming

Codex names live in `session_index.jsonl`, per account, out of band from the rollout. The
rule, in order:

1. `ref.indexedName` is set and **not** a placeholder → `.authoritative(name)`.
2. Otherwise, the first `event_msg`/`user_message` in this pass → `.fallback(text)`.
3. Otherwise, a placeholder `indexedName` → `.fallback(name)`, better than a bare UUID.
4. Otherwise → `.unknown`.

`indexedName` arrives on the ref, read once per account during the walk (§4.1), so this
function touches no file and is pure.

**Placeholder** means `^session \d+$`. That is Flight Deck's own default tab title
(`SessionStore.swift:2021`), pushed to codex by `thread/name/set`, so the index is polluted
with names this app wrote. Measured: of 70 interactive rollouts, 66 are named, and a large
share are `session 189` / `session 206` / `session 191`. Porting Claude's "a rename always
beats the first user message" rule literally would make those placeholders win, and ⌘K rows
would read `session 206` where the conversation actually opens *"Index the Claude Code
conversations for this directory."*

The pattern is deliberately narrow and anchored: a thread a person genuinely named
`session 4 retrospective` is not a placeholder and keeps its name.

`CodexAdapter.title(fromTranscriptAt:)` **stays `nil`.** It is documented as "an answer
rather than a gap" because a codex rollout handed to Claude's JSONL parser is exactly the
bug it prevents, and the store uses it for repointed tabs — a different question, answered
by `CodexNameWatcher` live. Naming for search is the new member on `AgentSearchCorpus`, and
the two do not merge.

## 7. Ranking

`MatchTier` gains one case after `transcript`:

```swift
case transcript = 3
/// A transcript hit from an automated run — codex `exec`. Indexed, but below every
/// conversation: 86% of rollouts on a working machine are exec runs concentrated in one
/// repo, so sharing the transcript tier lets one project's automation bury its
/// conversations.
case automated = 4
```

`SearchRanker` assigns `.automated` when `provenance == "exec"`, `.transcript` otherwise.
The existing invariant — *transcript hits are always last, so late-arriving results can only
append below what is drawn* — still holds, because the new tier is strictly below the old
one and `MatchTier`'s `<` is `rawValue` order. `SearchModel`'s two-clock split (§`SearchModel`
doc comment) is unaffected.

## 8. Index schema and activation

### 8.1 Schema

Bump `SQLiteSearchIndex.schemaVersion` 2 → 3. There is no migration to write: the index is
explicitly disposable ("delete it and rebuild") and the whole rebuild is a 67 MB + 684 MB
first-line-and-append walk that already runs in the background.

`agent`, `provenance` and `working_directory` go on the **`source`** table, not on
`message`. A transcript file has exactly one of each, so `source` is where they normalise;
putting them on `message` would repeat them across hundreds of thousands of rows to answer a
question that is per-file.

```sql
CREATE TABLE source(
  path TEXT PRIMARY KEY, offset INTEGER NOT NULL,
  agent TEXT NOT NULL, provenance TEXT, working_directory TEXT NOT NULL
);
```

`search()` joins `message → source` for `agent` and `provenance`, alongside the existing
`conversation` join for the name.

### 8.2 Activation

`TranscriptHit` and `NameCandidate` gain `agent: AgentID`, `provenance: String?`, and
`workingDirectory: String`. `SearchActivation.Activation`'s `resume` and
`addProjectThenResume` cases gain `agent` and carry the real `workingDirectory` instead of
today's `transcriptDirectory` hint.

`SessionStore.openConversation` then:

- resolves `launchAccount(for: result.agent, project: projectPath)` instead of `.claude`;
- sets `Session.transcriptDirectory` from the stored `workingDirectory` rather than probing
  — **`resolvedTranscriptDirectory` is deleted**, along with the class of bug its own doc
  comment describes (nothing in a result identifies which worktree a conversation ran in).
  The walk knew; now it says so;
- sets `Session.transcriptPath` from the hit's source path, which codex requires and Claude
  ignores;
- sanitises the title through the result's adapter (`sanitizedTitle`), not
  `ClaudeSession.sanitizedName`;
- keeps the `.select(existing tab)` rule unchanged — it is what stops a second writer on a
  live conversation, and codex enforces the same thing harder (`thread/resume` fails with
  *"already has an active writer"*).

The `deferred` → `resumeRestoredCodex([session.id], pinsPredateThisRun: false)` branch at
:3985 becomes live for the first time. Its argument is already correct and its comment
already explains why: the pin is the conversation the user searched for, so a reconcile pass
that followed the directory's newest thread would answer a different question.

A codex thread whose rollout no longer exists resumes through `CodexAdapter`'s existing
`rolloutExists` check — the same path a restored tab takes — and lands on a fresh thread
rather than failing, which is Claude's `--resume || --session-id` behaviour by a different
mechanism.

## 9. Live ingest, wire, and the phone

**Live ingest.** `CodexRolloutWatcher` gains an `onMessages` closure and `CodexRuntime.attach`
wires it exactly as `ClaudeRuntime.attach` does, including `offset: nil` — the watcher starts
at end-of-file, so its read position must never be recorded as indexing progress or the
backfill resumes from there and silently skips that thread's history. The watcher already
decodes every line for turn boundaries, so extraction adds dictionary lookups, not a second
`JSONSerialization` pass — the same argument `ClaudeRuntime` makes for passing `onMessages`
unconditionally.

**Wire.** `TranscriptHit`'s new fields decode with `decodeIfPresent`, defaulting `agent` to
`.claude` and `provenance`/`workingDirectory` to nil/empty. A new phone against an older Mac
then degrades to today's behaviour rather than failing the whole frame on a missing key.

**Phone.** `SearchRanker` is in `FleetKit` and shared, so the `.automated` tier applies to
both ends from one implementation — which is the reason for including the phone now rather
than letting the rule exist in two places. `SessionSearchResults` shows a per-row agent
glyph. `search.open` already routes through `SessionStore.openConversation`, so it inherits
codex activation with no phone-side change.

## 10. Rejected alternatives

**`thread/list` RPC for discovery.** The adapter already speaks it with a `cwd` filter, and
it returns `path`, `name` and `updatedAt` — apparently exactly what discovery needs. Rejected
on three counts: it needs a **live app-server per account** at backfill time, which is a
process dependency the Claude leg does not have; `codexThreadListLimit` caps it at 10 and
raising it trades a bounded file walk for an unbounded RPC; and its `cwd` matching is
exact-string with a **silent empty result** on any normalisation difference — the failure the
adapter's own comment calls "most likely to make this look like it simply does not work". The
measured walk is 0.08s and depends on nothing.

**Reusing `SearchCorpus.Entry`.** It is `(projectPath, directory)`. Codex has no per-project
directory, so any reuse means a sentinel directory and a downstream branch on it.

**Indexing codex's `response_item` family.** §6.1.

**Excluding `exec` runs entirely**, mirroring `CodexAdapter.threads(inDirectory:)`'s
`sourceKinds`. That exclusion exists to stop an automated run **stealing a binding**, which
is a different question from whether it is findable. Ranked below instead.

**Fixing `session N` at the source** — not pushing placeholder titles to codex at all.
Correct, and it would let Claude's naming rule port cleanly, but it is a change to
`SessionStore`'s rename path rather than to search, and the ~30 placeholders already written
to `session_index.jsonl` still need the fallback. Recorded in `docs/FOLLOWUPS.md`.

**A separate `AgentSearchProvider` registry.** Best blast-radius isolation, but
`SessionStore.adapter(for:)` is already a hand-written `if .codex` factory, and a parallel
registry doubles what a third agent must register — weakening the exact property this design
is for.

## 11. Testing

Unit (`./scripts/test-unit.sh`), TDD, each failing first:

- **Codex discovery** against a temp `sessions/` tree of fixture rollouts: attribution by
  `cwd`, worktree attribution through `candidateWorkingDirectories`, unmatched `cwd`
  skipped, `archived_sessions/` skipped, `/private/var` vs `/var` normalisation, a
  truncated or non-JSON first line dropping only its own file (6 of 563 on this machine are
  unparsable).
- **Codex extraction** from captured rollout fixtures: `event_msg` prose in, `response_item`
  prose and `reasoning` out, `role:"developer"` prompt blob out, fractional-second
  timestamps parsed.
- **Naming verdicts**: real rename → `.authoritative`; `session 206` + a first user message
  → `.fallback(message)`; `session 206` alone → `.fallback("session 206")`;
  `session 4 retrospective` → `.authoritative`; nothing → `.unknown`. Plus the builder's
  overwrite rule: a `.fallback` never replaces a stored `.authoritative`.
- **Ranker**: an `exec` hit sorts below every interactive transcript hit; the
  "late results only append below" invariant holds across the new tier.
- **Activation**: a codex hit plans with `agent: .codex` and the stored working directory; a
  live codex tab still `.select`s rather than resuming twice.
- **Multi-account**: a second account's transcripts appear (the §1.1 regression test).
- **Union prune**: a build over both agents' refs prunes neither agent's rows (§4.3's trap).
- **Schema**: a v2 index on disk is discarded and rebuilt at v3.

iOS (`./scripts/build-ios.sh`, `./scripts/test-ios.sh`): `TranscriptHit` decodes a
payload missing the new keys, defaulting to `.claude`; the shared ranker puts `exec` last on
the phone too.

**No new smoke test.** Per `AGENTS.md` rule 4, and there is no new GUI surface — the overlay
gains a glyph, not a flow.

## 12. Out of scope

- Filtering ⌘K by agent (`agent:codex …`). YAGNI until mixed results are actually confusing.
- Indexing `codex exec` output blocks or tool calls, for `TranscriptExtractor`'s reasons.
- `~/.codex/archived_sessions/`.
- Stopping placeholder titles reaching `thread/name/set` (§10) — follow-up.
