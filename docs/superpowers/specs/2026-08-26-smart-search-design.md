# Smart Search — ⌘K over the fleet and its history

Status: design, awaiting review
Date: 2026-08-26

A Spotlight-style overlay on ⌘K that finds a session, a project, or a moment in a
conversation, and puts you back in it with one Return.

---

## 1. What it is

⌘K dims the deck and drops a search panel in front of it. You type; results rank
immediately. Session and project **names** come first, ordered by how well they match and
then by how recently you touched them. Below them come **moments inside conversations** —
a line you or an agent actually wrote — each with two lines of context and the matched
terms highlighted, so you can tell which one you want without opening anything.

Return resumes the highlighted result into a tab. Esc closes.

## 2. Scope

**In scope.** Every project in the sidebar, every session under it, and every past
conversation belonging to those projects — including conversations from their worktrees.
On this machine that is 13 projects, 484 conversations, 684 MB of transcript.

**Out of scope, deliberately.**

- Conversations from projects *not* in the sidebar. The corpus is bounded by what you have
  open, which is what keeps the index small and the results relevant.
- Tool inputs and tool results — the commands run, files read, and output produced. See §4.
- App actions ("New Session", "Add Project"). This is a search field, not a command palette.
- Learned/frecency ranking. Ranking is deterministic; the same query always sorts the same
  way. Revisit only if real use shows a need.
- Fleet projection to the mobile companion. Search is desktop-only for now.

## 3. The measurement that shapes the design

Sampling 60 random transcripts (97 MB) by content category:

| Category | Share |
|---|---|
| JSON envelope — uuids, parent chains, timestamps, cwd | 54.5% |
| `tool_result` output | 19.9% |
| `tool_use` input | 8.9% |
| **user text** | **3.3%** |
| **assistant text** | **1.7%** |
| base64 images | 0.9% |

**Conversation text is 5.0% of a transcript.** The 684 MB bounded corpus contains roughly
**34 MB of actual conversation**.

That number decides the architecture. 34 MB is small enough that the index is not the hard
problem — an FTS5 index over it is around 20 MB and answers in well under a millisecond.
The only expensive step is reading and parsing 684 MB of JSONL *once* to extract those
34 MB, after which everything is incremental.

## 4. What gets indexed

Only `user` and `assistant` **text** blocks: what you typed and what the agent wrote back.

Tool inputs and results are excluded. They are 29% of the bytes and would change what the
feature means — searching `rename` would surface every file that happens to contain the
word rather than the moment you asked for a rename. Excluding them also keeps every preview
a sentence a person or an agent wrote, which is what makes two lines enough to skim.

The schema stores a `kind` discriminator on every row even though only one kind is written
today, so widening to tool content later is a re-index and a query change rather than a
migration.

## 5. Which directories belong to a project

`claude` encodes a working directory into a project directory name by replacing every
non-ASCII-alphanumeric UTF-16 code unit with `-` (`ClaudeSession.encodedProjectDirName`).
The encoding is lossy and not invertible.

**Do not resolve the corpus by prefix-matching encoded names.** A project at
`~/Projects/flight-deck` encodes to a name that is also a prefix of the encoding of
`~/Projects/flight-deck-old` — a different project entirely. Prefix matching silently folds
one project's history into another's.

Instead, enumerate real paths on disk and encode each one exactly:

1. the project directory itself, and
2. each existing entry of `<project>/.claude/worktrees/*` and
   `<project>/.superpowers/worktrees/*`.

Encode those paths and accept only exact directory-name matches under
`~/.claude/projects`. `SearchCorpus` owns this rule and is pure — it takes a list of
project paths plus a directory lister and returns the transcript directories in scope.

## 6. Architecture

Nine units, in `Sources/FlightDeck/Search/`. The first five are pure: no SwiftUI, no
actors, no filesystem beyond an injected seam, so they test instantly.

| Unit | Responsibility |
|---|---|
| `SearchCorpus` | Project paths → transcript directories in scope (§5). Pure. |
| `TranscriptExtractor` | One JSONL line → zero or more `IndexedMessage`. Pure. |
| `NameMatcher` | Fuzzy subsequence scoring over session, project, and conversation names. Pure. |
| `SearchRanker` | Merges name hits and transcript hits into the tier order of §7. Pure. |
| `FTS5Query` | User text → a safe FTS5 MATCH expression (§8). Pure. |
| `SearchIndex` | Protocol: ingest messages, query, prune. `SQLiteSearchIndex` is the FTS5 implementation; tests use an in-memory fake. |
| `SearchIndexBuilder` | Backfills historical transcripts off the main actor (§9). |
| `SearchModel` | `@MainActor ObservableObject`: debounce, dispatch, selection, published results. |
| `SearchPanel` + `SearchOverlayView` | The AppKit panel and its SwiftUI contents (§10). |

`SearchActivation` decides what a chosen result does and calls into `SessionStore` (§11).

### Storage

SQLite with FTS5, at
`~/Library/Application Support/Flight Deck/search-index.sqlite`, beside `sessions.json`.

```sql
CREATE TABLE message(
  id INTEGER PRIMARY KEY,
  conversation_id TEXT NOT NULL,   -- transcript uuid
  project_path    TEXT NOT NULL,   -- sidebar project it belongs to
  role            TEXT NOT NULL,   -- 'user' | 'assistant'
  kind            TEXT NOT NULL,   -- 'text' today; widens per §4
  timestamp       REAL NOT NULL,
  text            TEXT NOT NULL
);
CREATE VIRTUAL TABLE message_fts USING fts5(
  text, content='message', content_rowid='id', tokenize='unicode61'
);
CREATE TABLE source(              -- per-file incremental read position
  path TEXT PRIMARY KEY, offset INTEGER NOT NULL, mtime REAL NOT NULL
);
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);  -- schema version
```

FTS5 is present in the system SQLite (verified: 3.51.0, `snippet()` and all). Link it in
`project.yml` as an `sdk: libsqlite3.tbd` dependency. The C interop is confined to
`SQLiteSearchIndex`; nothing else in the app sees a `sqlite3*`.

`meta.schema_version` mismatched at open ⇒ delete the file and rebuild. The index is a
cache. It is never the source of truth for anything, so discarding it is always safe, and
that is the entire migration story.

## 7. Ranking

Four tiers. Within a tier, sessions rank above projects, and within a kind the most
recently active comes first — **recency breaks every tie, including among transcript
hits.**

| Tier | Contents |
|---|---|
| 0 | Exact, case-insensitive name match |
| 1 | Prefix name match |
| 2 | Fuzzy subsequence name match above threshold |
| 3 | Transcript hits |

Recency is the session's last activity for live sessions, and the transcript file's mtime
for historical conversations.

**BM25 selects, recency orders.** A query can match thousands of messages, and something
has to decide which ones are worth showing at all — that is BM25's job, as a `LIMIT 200`
on the FTS5 query. Those survivors are then sorted by recency, not by score. So relevance
decides *membership* in tier 3 and recency decides *order* within it.

Scores are never compared across tiers. A BM25 score and a fuzzy-subsequence score are not
on the same scale, and pretending otherwise is how these lists get mysterious.

**Empty query** lists sessions by most recent activity, so ⌘K-Return is "back to what I was
just doing".

**A property worth keeping.** Names are matched in memory and update every keystroke;
transcript results are debounced 90 ms and arrive later. Because transcript hits are always
tier 3, a late arrival can only ever append *below* what is already on screen. The
highlighted row can never be shoved out from under you by results landing. Selection is
tracked by result identity rather than by index, which holds this even when the name
results themselves change.

## 8. Query safety

FTS5 MATCH is a syntax, not a literal. A user typing `"`, `*`, `NEAR`, `AND` or `-` can
produce a syntax error or a query that means something surprising.

`FTS5Query` splits input on whitespace, wraps each token in double quotes with embedded
quotes doubled, and appends `*` to the final token so results narrow as you type:

```
SessionStore.rename  ->  "SessionStore.rename"*
fix the rename       ->  "fix" "the" "rename"*
say "hi"             ->  "say" "\"hi\""*
```

Highlighting uses `snippet()` with U+0002/U+0003 sentinels, which cannot occur in
transcript text, and the view parses them into an `AttributedString`. Two lines of context
comes from a 24-token snippet window.

## 9. Keeping the index fresh

**Live sessions ride the existing poll.** `TranscriptWatcher` already tails each open
session's transcript on the shared `WatchClock`, reading only appended bytes and parsing
every new line to find titles and subagent counts. The lines are already read and already
parsed — extraction hooks in there and costs one extra pass over data in hand. No second
reader, no second timer, and the conversation you are in right now is searchable within one
tick.

**History is backfilled once.** `SearchIndexBuilder` walks the in-scope directories on a
detached `.utility` task, newest file first, so the conversations you are most likely to
want are searchable first. Per file it reads from `source.offset` using the same
`TailReader` mechanic and commits in batches. It is cancellable, it yields between files,
and it survives being killed mid-walk because progress is per-file offsets in the database.

The first run's wall-clock cost is **not yet measured** — only the corpus size is. Parsing
684 MB of JSONL to extract 34 MB is the one genuinely expensive step in this design, and
the estimate to beat is under a minute of background work. The first implementation task is
to measure it against the real corpus; if it lands far above that, the fix is parallelism
across files, not a change to anything else here.

Throughout the backfill the overlay footer reports progress — `indexing 312 of 484
conversations` — because a search that silently returns nothing is worse than one that
admits it is still reading. Name search is fully functional the whole time.

**Pruning.** Files in `source` that no longer exist, and rows whose `project_path` has left
the sidebar, are deleted at the start of each backfill pass.

## 10. The overlay

A borderless `NSPanel`, sized to the deck window's frame and added as a child window so it
tracks moves and resizes. It becomes key, which takes focus off the Ghostty surface
outright — the reliable way to stop a terminal that claims nearly every ⌘-chord from eating
the keystrokes.

Inside: a scrim at 34% black over the whole window, and a 680 pt card centred horizontally
at 18% from the top.

**Rows are uniform — every result is a heading plus two lines.** The heading is
`name · project` with a status dot for live sessions and a right-aligned relative time.
The two lines are the FTS5 snippet for a transcript hit; for a name match they are the
working directory, and the agent plus transcript size. Message count is shown when the
conversation is already indexed and omitted when it is not — the row must not wait on the
index to draw.

**Motion.** Open: opacity 0→1 over 170 ms, scale 0.97→1 over 220 ms on
`cubic-bezier(0.2, 0.9, 0.25, 1)`, scrim fading in alongside. The card's **height springs**
between result counts on the same curve, clamped between 1 and 8 rows; past 8 the list
scrolls. Close reverses it. The height animates once per settled result set, never on the
in-flight debounce — animating twice for one keystroke is what makes these panels feel
cheap.

## 11. Activation

Return on any result resumes it into a tab:

1. Ensure the result's project is in the sidebar, adding it if it has since been removed.
2. Expand it if collapsed.
3. If a live session is already attached to that conversation, select it and stop.
4. Otherwise insert a session with `pinnedConversationID` set to the conversation's uuid and
   `transcriptDirectory` set to the directory the transcript actually lives in — which is
   the worktree path, not the project path, for a worktree conversation — and resume it.

Step 4 is the path `reopenLastClosed` already uses to rebuild a tab onto an existing
conversation; activation calls the same seam rather than a parallel one.

`SearchActivation` is pure: result in, an `Activation` value out describing which of these
apply. The store performs it. That keeps "what should happen" testable without launching an
agent.

## 12. ⌘K has to be taken back from the terminal

Ghostty binds `super+k` to `clear_screen` with `performable: true`
(`vendor/ghostty/src/config/Config.zig:6867`). `MenuKeyEquivalents.shouldOfferToMenu`
deliberately withholds performable bindings from the main menu, so a ⌘K menu item would
never fire while a terminal has focus — which is essentially always. It would fail
**silently**: the menu item would look correct and simply never run.

The repo already solved this once. `GhosttyDefaults.conf` unbinds `super+shift+t` to give
⌘⇧T back to Reopen Closed Session. Do the same:

```
keybind = super+k=unbind
```

That file loads before the user's own Ghostty config, so anyone who wants ⌘K back on
clear-screen can rebind it in `~/.config/ghostty/config`. A unit test asserts the entry is
present, because its absence is invisible in the UI.

## 13. Testing

Pure units, no filesystem, instant:

- `TranscriptExtractor` against fixture JSONL lines: string content, block-array content,
  `isMeta` and compact-summary exclusion, malformed lines, and that tool blocks yield
  nothing.
- `SearchCorpus`: worktrees included; **a sibling project sharing an encoded prefix
  excluded** — the §5 trap, asserted directly.
- `NameMatcher`: subsequence hits, case-insensitivity, threshold behaviour.
- `SearchRanker`: tier order, and recency ordering *within* a tier; a stale exact match
  outranks a fresh fuzzy one, and a fresh transcript hit never outranks any name match.
- `FTS5Query`: quotes, stars, `NEAR`, and an empty query.
- `SearchActivation`: already-open conversation selects rather than duplicates; worktree
  conversation gets the worktree transcript directory.

Against a temp directory with fixture transcripts:

- `SQLiteSearchIndex` round-trip: ingest, query, snippet sentinels, prune.
- `SearchIndexBuilder` incremental behaviour: appended bytes only, resumable after
  cancellation, offsets survive a reopen.

UI smoke — **one** added `runActivity` group in the existing suite: ⌘K opens, typing
narrows, Esc closes. Per `AGENTS.md` rule 4, do not loop `smoke.sh` to chase flakiness.

Async tests touching `SearchModel` use `await fulfillment(of:)`, never `wait(for:)` —
`@MainActor` XCTest deadlocks on the latter.

## 14. Risks

| Risk | Handling |
|---|---|
| First-run parse of 684 MB competes with live agents | Detached `.utility`, yields between files, newest-first, cancellable. Progress shown. |
| Index file corrupted or from an older schema | Delete and rebuild. It is a cache; nothing depends on it. |
| ⌘K silently swallowed by the terminal | Unbind in `GhosttyDefaults.conf`, asserted by a unit test (§12). |
| A huge single transcript (largest here is 23 MB) stalls a batch | Batch commits are per-N-messages, not per-file. |
| Corpus grows without bound as projects accumulate | Bounded by open projects, and pruned when one leaves the sidebar. |
