# Phone Search — pull down on the session list, reach the whole fleet's history

Status: design, awaiting review
Date: 2026-08-29

Pull down on the session list and a search field appears. Typing filters the fleet
instantly, offline, on the phone itself; a moment later, moments from inside conversations
arrive underneath. Tapping one lands you in that conversation, scrolled to the line you
searched for.

This is the mobile half of `2026-08-26-smart-search-design.md`, whose §2 listed "fleet
projection to the mobile companion" as deliberately out of scope. This spec takes it in.

---

## 1. What it is

The fleet list gains a standard iOS search field: hidden above the first row, revealed by
dragging down at the top of the list, exactly as Mail and Messages do it. `.searchable`
provides the gesture, so there is no custom recogniser competing with the `List`'s own
scrolling — a conflict this screen has already paid for once (see `FleetListScreen
.sessionRow`'s note on the `simultaneousGesture` that broke every row tap).

Typing ranks results in one list, in the desktop's tier order: exact name matches, prefix,
fuzzy, then moments inside conversations. Tapping a name opens that session. Tapping a
moment opens the conversation **scrolled to that message**, with history above and below.

## 2. Scope

**In scope.** Every project the Mac has in its sidebar, every session under it, and every
past conversation belonging to those projects — the same bounded corpus the desktop
indexes, reached from the phone. Tapping a hit in a conversation with no live tab asks the
Mac to resume it into one.

**Out of scope, deliberately.**

- A phone-side transcript index. The Mac already has one; a second copy on a device that
  sees conversations through a socket would be a cache of a cache.
- Persisting the conversation catalogue or the fleet across launches. `FleetModel`'s
  constructor documents why the snapshot is not persisted — a restored snapshot must also
  restore `lastLive` or the list renders stale data indistinguishably from live. The
  catalogue inherits that rule rather than arguing with it.
- Searching tool inputs and results. Inherited from the desktop spec §4, unchanged.
- A command palette. This is a search field.

## 3. What the phone has, and what it does not

Three facts about the current mobile model shape everything below.

**It has names for live sessions only.** `FleetModel.fleet` is `[WireProject]`, each holding
`[WireSession]`. The 484 conversations with no open tab are invisible to it.

**It has no timestamps.** `WireSession` carries `title`, `agent`, `activity`, `waitingFor`,
`subagentCount`, `isUnread` and `hasBackgroundWork` — and no notion of when anything last
happened. The desktop's "recency breaks every tie" has no data to run on.

**It cannot map a conversation to a tab.** `WireSession` does not expose
`pinnedConversationID`, so the phone cannot tell whether a search hit belongs to a session
it is already showing.

Each is addressed once, in §5, rather than worked around at every call site.

## 4. Architecture

### What moves to FleetKit

Four files move from `Sources/FlightDeck/Search/` to `Sources/FleetKit/Search/`. All four
are already `import Foundation` and nothing else, which is precisely the bar `FleetKitiOS`
enforces — the move is a move, not a rewrite, and the iOS slice compiling them is the proof.

| File | Why it is shared |
|---|---|
| `NameMatcher.swift` | The tier rules and the subsequence walk are the same question on both screens. |
| `SearchRanker.swift` | Tier order, session-before-project, recency-then-id, and the per-conversation grouping cap. Reimplementing this on the phone is how two search boxes come to disagree about what "best match" means. |
| `SearchResult.swift` | `SearchResult`, `NameCandidate`, `TranscriptHit`, `SearchResultKind`. |
| `FTS5Query.swift` | Stays on the Mac in practice — the phone never builds a MATCH expression — but travels with the others so the query safety rule has one home. |

`project.yml` needs no change: `FleetKit`'s sources are declared as the whole
`Sources/FleetKit` directory, and `SPAKE2/` is the precedent for a subdirectory in it.

Their tests move with them, from `Tests/FlightDeckTests` to the FleetKit test target, for
the ordinary reason that a test which cannot see its subject is not a test.

**What stays on the Mac.** `SearchCorpus`, `TranscriptExtractor`, `SearchIndex`,
`SQLiteSearchIndex`, `SearchIndexBuilder`, `SearchModel`, `SearchPanel`, `SearchOverlayView`
— every one either touches the filesystem, SQLite, or AppKit. `SearchCandidates` stays
because it reads `Repo` and `ClaudeSession`, which are Mac types; the phone gets its own
candidate builder (§6) over the wire shapes it actually holds.

`SearchActivation` also stays. Activation happens on the Mac because that is where sessions
are created — see §8.

### What is new

| Unit | Where | Responsibility |
|---|---|---|
| `PhoneSearchCandidates` | `FlightDeckMobile` | `[WireProject]` + catalogue → `[NameCandidate]`. Pure. The phone's answer to `SearchCandidates`. |
| `SessionSearchModel` | `FlightDeckMobile` | `@Observable`: query, debounce, dispatch, published results, footer state. |
| `SessionSearchResults` | `FlightDeckMobile` | The result rows the `.searchable` field displays. |

## 5. Wire additions

Four changes, each closing one gap from §3.

**`WireSession.lastActivity: Date?`.** The transcript's mtime, which the Mac already reads
for `SearchCandidates`. Optional so an older Mac decodes into a newer phone; absent sorts as
`.distantPast`, which degrades ranking to sidebar order rather than to a crash.

**`FleetRequest.conversations`** → **`ServerFrame.conversations(cid:, WireConversationCatalogue)`**.
The catalogue is `[WireConversation]`, each `{ id: String, name: String, projectPath:
String }` — exactly what `SQLiteSearchIndex.conversationNames()` already returns, filtered
to open projects the way `SearchCandidates` filters it and for the same reason: offering a
name match the Mac cannot honour without silently re-adding a project the user removed.

At 484 conversations this is roughly 30 KB. It is requested on every snapshot, alongside
`refreshNewSessionOptions`, which already covers first dial, reconnect and return from
background — the three moments it can have gone stale, none of which needs its own hook.

**`FleetRequest.search(query: String, limit: Int)`** → **`ServerFrame.searchHits(cid:,
WireSearchHits)`**. `WireSearchHits` is `{ hits: [TranscriptHit], indexing:
IndexingProgress? }`. The Mac runs `FTS5Query.match` and `SearchIndex.search` — the same two
calls `SearchModel.scheduleTranscriptSearch` makes — and returns the hits unranked, in BM25
order. Ranking happens on the phone, because that is where the name half lives.

A query `FTS5Query.match` rejects (empty, or whitespace only) returns no hits rather than an
error. It is not a failure; it is a query with nothing to match.

**`TranscriptHit.offset: Int`**, and a matching `offset` column on the `message` table. This
is what makes §7 possible, and it is the one change that reaches into the index.

## 6. Ranking, and the two clocks

The phone runs the desktop's split, for the desktop's reason.

**Names are matched in memory, on the keystroke, with no debounce.** `PhoneSearchCandidates`
flattens `fleet.projects` and the catalogue into `[NameCandidate]`, and `SearchRanker.rank`
scores them. A few hundred candidates with no I/O is not worth a debounce, and the list
responding to the letter you just typed is the whole feel of the feature.

Live sessions contribute `lastActivity` from §5. Catalogue conversations contribute
`.distantPast`, exactly as `SearchCandidates` gives them — the desktop's reasoning holds
unchanged here: anything with a live tab is more likely to be what you want, and stat-ing
484 transcripts to do better would put a filesystem walk behind a keystroke.

Projects contribute a row as they do on the desktop, with the newest session's activity.

**Transcript hits are debounced 90 ms and arrive from the Mac.** Same constant as
`SearchModel.transcriptDebounce`, and it now buys more than it did: it is the difference
between one request and six over a socket, not just one SQLite query and six.

**Why the split is safe, on a phone specifically.** `SearchRanker` puts transcript hits in
the last tier unconditionally, so a late reply can only append *below* what is drawn. On the
desktop that protects the highlighted row from moving under someone reaching for Return.
Here it protects something more literal: a finger already descending on a row. A result set
that reordered under a tap is a mis-tap, and on a touch screen there is no equivalent of
noticing the highlight moved before you commit.

Stale replies are dropped by matching the reply against the query that requested it, which
is the phone's version of `SearchModel`'s cancellation. The socket answers exactly once per
`cid` — including `.disconnected` — so there is no path where a reply is silently lost and
the footer spins forever.

**Empty query.** The list is the fleet, unchanged and unfiltered: projects, headers,
collapse state and all. `.searchable` with an empty query means the search field is open and
nothing has been asked, which is not the same as ⌘K's "the deck, most recent first" — on the
phone the unfiltered list is *already* the screen behind the field, and replacing it with a
flat recency list would throw away the project grouping for no gain.

## 7. Jumping to a moment

Tapping a transcript hit opens the conversation scrolled to that line. Two pieces are
missing today.

**The index does not record where a message is in its file.** `message.id` is an FTS rowid;
it says nothing about bytes. `SearchIndexBuilder` reads through `TailReader` from
`source.offset`, so it knows the starting offset of every line it parses, and
`TranscriptWatcher` tracks the same position for live sessions. Both already hold the number;
neither passes it on. `TranscriptExtractor` gains the line's offset as a parameter and stamps
it onto every `IndexedMessage` it yields from that line — several messages from one line all
carry the same offset, which is correct, because an offset here names a line boundary and
that is exactly what a timeline cursor is.

Schema version bumps. The desktop spec §6 already states the migration story in full: a
mismatched `meta.schema_version` deletes the file and rebuilds, because the index is a cache
and is never the source of truth for anything.

**The protocol has no way to ask for the middle of a file.** `TimelineAnchor` gains
`case around(Int)`, wire name `"around"` — the name its own doc comment already uses as the
example of an anchor a future phone might invent. That comment is worth honouring rather
than merely satisfying: it refuses to guess at unknown anchors *because* an anchor is
executed rather than rendered, and `FleetSocketServer.onUndecodable` already answers an
unparseable `req` with `err`/`unsupported` on its own `cid`. So a new phone asking an old
Mac for `.around` gets a clean refusal, not a dropped socket. The phone falls back to
`.latest` and lands in the conversation without the scroll, which is a worse answer to the
right question.

`.around(offset)` returns records either side of that line. `TimelinePage`'s existing shape
carries it: `start`, `end` and `hasMore` mean what they already mean, and `.before(start)` /
`.after(end)` page outward from there.

**Highlighting needs no new field.** `TimelinePage` documents that item ids *are* byte
offsets, so the phone highlights the item whose id equals the offset it asked around. The
highlight fades after a beat — long enough to find, short enough not to become permanent
decoration on a conversation you are now just reading.

## 8. Activation

**`FleetRequest.openConversation(conversationID:projectPath:)`** → **`ServerFrame.session(cid:, UUID)`**.

A request, not a command, and that is the whole design. The phone needs to know *which* tab
to push, and a command's effect comes back as a northbound event with no way to tell which
of them was yours.

On the Mac it calls `SearchActivation.plan` and `SessionStore.openConversation` — the tested
seam the desktop's Return already uses, and the one `reopenLastClosed` uses to rebuild a tab
onto an existing conversation. Every rule in desktop §11 therefore holds here for free:
re-add the project if it has left the sidebar, expand it if collapsed, select the existing
tab if one is already attached rather than starting a second `--resume` against a live
transcript, and resolve the real transcript directory rather than trusting a worktree hint.

The phone does not reimplement any of it. It sends two strings and receives a tab id.

Tapping a **name** result for a live session is unchanged from tapping its row today: push
that tab. Tapping a name result for a catalogue conversation, or a project, goes through
`openConversation` the same as a transcript hit.

## 9. Offline, and other things worth admitting

The name half works with the Mac asleep, for as long as this launch has held a fleet. The
transcript half cannot, and says so rather than returning nothing.

A footer under the results reports, in priority order:

- **Not connected.** "Searching names only — not connected to <Mac>." The name results above
  it are real and complete for what they cover.
- **Indexing.** "Indexing 312 of 484 conversations." Carried on the search reply, mirroring
  the desktop's footer, and for the identical reason: a search that silently returns nothing
  is worse than one that admits it is still reading.
- **Nothing found.** Only claimed when the Mac answered and had nothing. A disconnected
  phone must never render "No results" — that is a claim about the corpus it is in no
  position to make, and it is the same class of quiet lie the stale banner exists to prevent.

On a cold launch with no connection there is no catalogue and no fleet, so search matches
nothing and the first line is what shows. That is the honest state, and it resolves itself
the moment the socket comes up.

## 10. The surface

`.searchable(text:placement: .navigationBarDrawer(displayMode: .automatic))` on the `List`
inside the existing `NavigationStack`. Hidden above row one, revealed by dragging down, at
no cost to the screen's resting height — which matters on a screen whose comments record a
30 pt fight over list style and a 52 pt one over the title.

With a query typed, the results replace the list's content. Rows follow the desktop's
uniformity rule — a heading plus supporting lines — adapted down:

- **A session or project:** the row that already exists, `SessionStatusGlyph` and all, with
  the matched span underlined from `SearchResult.highlightedRanges`.
- **A conversation:** name, then `project · relative time`, then the snippet with its
  U+0002/U+0003 sentinels parsed into an `AttributedString` — the parsing that
  `SearchSnippetTests` already covers.
- **A continuation:** indented and headless, per `SearchResult.isContinuation`, capped at
  `SearchRanker.maxMatchesPerConversation`. The cap and the grouping come free with the
  shared ranker.

No result-count height animation: that is a floating panel's concern, and this is a list.

## 11. Testing

The pure units are the bulk of it and stay instant.

- **Moved tests** (`NameMatcherTests`, `SearchRankerTests`) must pass unchanged after the
  move. Unchanged is the assertion — a diff in them means the move was a rewrite.
- **`PhoneSearchCandidates`**: a live session and a catalogue entry for the same
  conversation contribute one candidate, not two. Absent `lastActivity` sorts as
  `.distantPast` rather than crashing. Catalogue entries for projects not in the fleet are
  dropped.
- **`SessionSearchModel`**: names rank with no request in flight; a reply for a superseded
  query is discarded; `.disconnected` sets the offline footer rather than "No results"; hits
  land below names for every ordering of arrival.
- **Wire round-trips**: each new frame encodes and decodes, and an older Mac's
  `WireSession` without `lastActivity` still decodes — the compatibility direction that
  actually happens in the field.
- **`.around`**: `TimelineAnchor(name:cursor:)` accepts `"around"` with a cursor and rejects
  it without one, matching how `.before` and `.after` are already guarded.
- **Offsets**: a line yielding two messages stamps the same offset on both, and that offset
  round-trips through the index to a `TranscriptHit`.

Simulator tests (`scripts/test-ios.sh`) cover the model; the `.searchable` gesture itself is
platform behaviour and is not worth a UI test to assert that Apple's field appears.

## 12. Order of work

1. Move the four files to FleetKit with their tests. Nothing behaves differently; the iOS
   slice compiling them is the proof the move was legal.
2. `offset` through `TranscriptExtractor`, the schema, and `TranscriptHit`. Schema bump.
3. `TimelineAnchor.around` and its reader support, with the old-Mac refusal path.
4. The three new frames and `WireSession.lastActivity`, with round-trip tests.
5. `PhoneSearchCandidates` and `SessionSearchModel`, pure and tested first.
6. The `.searchable` surface and the result rows.
7. `openConversation` end to end: tap a closed conversation on the phone, watch the tab
   appear on the Mac and the phone land in it at the right line.

Steps 1–3 are Mac-side and independently shippable; the desktop keeps working throughout and
gains a slightly better index.
