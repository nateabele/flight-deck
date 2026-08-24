# State Integrity and Instance Isolation — Design

**Status:** designed, ready to plan. Written after the 2026-08-23 incident in which 21 tabs
were renamed to one name and one tab silently lost 63 hours of history.

**Scope:** three independent layers — event routing (L1), process/state isolation (L2), and
pin correctness plus recovery tooling (L3). Deliberately *not* the `FleetState` encapsulation
of `2026-08-18-fleet-state-encapsulation-design.md`: that remains deferred for the reason it
already documents, and nothing here blocks it or is blocked by it.

## 1. The incident, as established

Three distinct failures compounded. Each is addressed by one layer below.

**The rename.** At 16:31 local on 2026-08-23, one `.title` event carrying the `mobile`
conversation's name was written to 21 tabs' stored titles. The writer is the fan-out at
`SessionStore.swift:3413`:

```swift
for tab in self.tabs(following: binding.conversationID) {
    self.apply(event, to: tab)          // → 3441: case .title → applyExternalTitle
}
```

`tabs(following:)` (`SessionStore.swift:3432`) value-matches the in-memory `attachments`
dictionary. It is the only writer in the codebase that can set many tabs' titles from one
event; `applyExternalTitle` persists but never injects, which matches the total absence of
transcript writes at 16:31; and its blast radius is one `AgentInstance`, which matches the
damage exactly — in `ogolvy-app`, where both accounts have tabs, only the Default-account
tabs were hit.

Not established: *why* 21 attachments held one conversation id while their stored
`pinnedConversationID`s remained correct. `attachments` is in-memory only and leaves no trace.
**The design below does not depend on answering this** — it removes the ability of any single
event to reach a tab that did not subscribe, whatever put the dictionary in that state.

**The propagation.** At the 23:47 restart, `ClaudeSession.resumeCommand`
(`ClaudeSession.swift:140-149`) emits `claude --resume <id> || claude --session-id <id> --name
'<title>'`. The `--resume` leg failed for ~24 tabs, the fallback ran, and `--name` stamped the
already-wrong stored title into each transcript as `custom-title` + `agent-name` records —
24 within three seconds. This recurs on **every** launch while the stored titles are wrong, so
the transcript damage compounds per restart.

**The data loss.** Tab `mobile` was pinned to `f7f0fc13…`, which compacted on 2026-08-20; the
live thread continued into `af4aaf6b…`. The pin never followed. The two files share 1149
record uuids and diverge at Fri 08-21 08:18:56, after which only `af4aaf6b` continued — to
Sun 23:50:07. `sessions.json` was valid JSON throughout. A fleet-wide lineage test found no
other tab in this state.

**The shared-state hazard.** `FileSessionPersistence.defaultDirectory()`
(`SessionPersistence.swift:226`) hardcodes `~/Library/Application Support/Flight Deck`, keyed
by neither bundle id nor build configuration, and `project.yml` defines no separate DEBUG
bundle id. `-FlightDeckStateDir` exists (`FlightDeckApp.swift:49`) and its doc comment
predicts this incident, but it is opt-in, silent when forgotten, and redirects *only*
`sessions.json` — preferences still resolve to the shared `.standard` domain. The snapshot's
`owner` field is not a lock: its only consumer is `sweepOrphans`.

## 2. L1 — identity-routed events

### The shape today

`ClaudeRuntime.attachments` is keyed by `binding.conversationID`
(`ClaudeRuntime.swift:31-35`), so a second tab attaching to a conversation **replaces** the
first's `Attachment`: its watcher is stopped and its closure orphaned. The store's fan-out is
compensation for that lost subscriber identity, not an independent feature.

So the fan-out cannot simply be deleted. Subscriber identity has to be restored to the
runtime first.

### The change

```swift
protocol AgentRuntime: AnyObject {
    func attach(_ binding: AgentBinding, for tab: UUID,
                onEvent: @escaping (AgentEvent) -> Void) -> AttachmentToken
    func detach(_ token: AttachmentToken)
}
```

A runtime keeps one `Source` per conversation — the single `TranscriptWatcher`, exactly as
now — and the source holds a **list of subscribers**, each carrying its own tab id and
closure. An event notifies each subscriber directly. `detach(token)` removes one subscriber
and tears the watcher down only when the list empties.

In the store, `apply(event, to:)` takes the tab id from the subscription.
`tabs(following:)` leaves the event path entirely.

### Why this is a fix and not a guard

The set of tabs an event can reach becomes exactly the set that subscribed to that
conversation. There is no dictionary scan and no value match on the event path, so a wrong
entry in `attachments` can no longer widen an event's blast radius. The class is removed by
construction rather than validated against — which matters precisely because we could not
determine what corrupted the dictionary.

### Behaviours preserved

All three the current doc comments defend:

- two tabs sharing one conversation both receive events (two subscribers, one source);
- one `TranscriptWatcher` per conversation, not per tab;
- detaching one of two sharers does not stop the other.

And one bug fixed incidentally: attaching a second tab no longer stops the first's watcher.

### Also in scope

`SessionStore.swift:548` fans a rename out over `tabs(following:)` as well. Per the
root-cause work `ClaudeAdapter.rename` is unreachable in production — `SessionStore.rename`
dispatches claude inline (`SessionStore.swift:2661`) and only codex reaches the adapter
(`:2668`). **Delete the dead path.** Unreachable fan-out is the exact shape that caused this.

### Tests

- N tabs on distinct conversations, emit one title, assert exactly one title changed.
  *This test fails against today's code* and is the regression gate for the incident.
- Two tabs on one conversation both receive.
- Detach one of two sharers; the other still receives.
- Detach the last sharer; the watcher stops.

## 3. L2 — process and state isolation

Two independent defences, because "bulletproof" means no single point of failure.

### 3.1 One decision point, two consumers

Today the state directory and the preferences domain are decided separately, which is why an
"isolated" debug run still writes real preferences. Replace both with a single value:

```swift
enum StateWorld {
    case owned(directory: URL, defaults: UserDefaults)
    case forked(directory: URL, defaults: UserDefaults, from: URL, owner: ProcessIdentity)
}

/// Both cases carry a defaults suite, so no consumer can reach `.standard` implicitly.
/// A fork's suite is its own, seeded by copying the contended world's preferences once.
```

Resolution order, once, at launch:

| Build | Directory | Defaults suite |
|---|---|---|
| Release | `~/Library/Application Support/Flight Deck` | standard domain |
| `#if DEBUG` | `~/Library/Application Support/Flight Deck (Debug)` | `dev.flightdeck.FlightDeck.debug` |
| `-FlightDeckStateDir <p>` | `<p>` | `dev.flightdeck.FlightDeck.<h>` |

`<h>` is a short stable digest of the resolved absolute path, so two overrides never share a
suite and the same override always reuses one. The suite name is derived, never passed
separately — a directory and a preferences domain cannot be pointed at different worlds.

Both stores derive from the resolved world. Forgetting a flag stops being possible because
there is no flag to forget: a debug build is isolated by virtue of being a debug build.

### 3.2 A real lock, not an inferred one

**Requirement (from review): an empty deck must be unreachable except on the contended path.**
Inferring liveness from the `owner` stamp can misfire — pid reuse, a stale stamp, a nil read —
and a misfire would present as "all my sessions vanished", which is the one outcome ruled out.
So the check must be authoritative rather than inferential.

Hold an advisory `flock` on `<state-dir>/.lock` for the lifetime of the process. A lock is
held or it is not. The kernel releases it on process death **including SIGKILL**, which
matters because `scripts/swap-release.sh` kills the app rather than quitting it, so a stale
lock cannot outlive its owner.

| Outcome | Result |
|---|---|
| Lock acquired | `.owned` — normal launch, full deck. Always. |
| Lock positively held by another live process | `.forked` — empty deck, banner |
| Lock fails for any other reason (fs won't lock, permissions) | `.owned` — full deck, log loudly |

The third row is deliberate: when the mechanism itself is uncertain, fail toward the full
deck. A missed conflict is recoverable and rare; a false conflict is the failure mode the
requirement forbids.

### 3.3 What a fork does

Forking the state would fork the tabs, and this instance would then `claude --resume`
conversations the other instance owns — writing to shared transcripts, which is the collision
being removed. So **a fork resumes nothing**:

- copies `projects` and preferences from the contended directory;
- starts with an **empty session list**;
- shows a persistent banner naming the fork directory and the owning pid;
- never writes to, and never deletes from, the contended directory — including no orphan
  sweep, which must be gated on `.owned`.

Only `.forked` can produce an empty session list. On `.owned`, an empty deck can only mean the
snapshot was genuinely empty. That is a type-level guarantee, not a discipline.

Recovery from an unwanted fork is quit-and-relaunch; the real directory is untouched.

### 3.4 Kill the silent legacy fallback

`FileSessionPersistence.load()` falls back to `migrateFromDefaults()` when the file read **or
decode** fails, so a corrupt file silently restores a stale snapshot. The legacy
`sessions.snapshot.v1` key is still present on this machine and still decodable — two
`/Users/nate` tabs, `sessionCounter: 2`, pre-projects schema — because the key is only cleared
on the migration path, so it sits armed indefinitely.

- Missing file → migrate. That is a real first run.
- Present but unreadable → never migrate, never seed. Quarantine and surface (§4.4).
- Clear the legacy key on the first successful normal load.

## 4. L3 — pin correctness and recovery

### 4.1 A pin must follow its thread

A compaction writes the continuation to a new conversation id. Detect a superseded pin and
repoint it.

**Cost.** The check is not a per-tick whole-file read. A registry tick already tells us when a
tab's `claude` is writing somewhere the tab is not following; the lineage read runs only on
that transition, and on restore. Reading the last record of the pinned file and the first of a
candidate is enough to test the link below — neither is a full-file load.

Guarded by a **strong link only**: the continuation's first record's `parentUuid` equals the
pinned file's last record's `uuid`. Not a similarity heuristic, not shared-uuid overlap —
those are fine for a diagnostic sweep but not for automatically repointing a tab.

When no strong link exists but the pinned transcript looks abandoned, do not guess: flag it
(§4.3) and let the user choose.

### 4.2 A failed resume must never write

`resumeCommand`'s fallback runs `--name '<title>'`, so a *failed resume* performs a *write*
that renames a conversation. That is what stamped 24 transcripts, and it recurs every launch.

Drop `--name` from the fallback. A failed `--resume` surfaces on the tab; it does not silently
start a differently-named session. More generally: **no failure path may rename a
conversation.**

### 4.3 Detection, surfaced

Nothing told the user the `mobile` pin was stale — that is why it cost a day rather than a
minute. Add:

- a sidebar indicator on any tab whose pin looks superseded, alongside the existing
  `conflictedSessionIDs` and `accountMismatchedSessionIDs` treatments;
- a startup summary when any tab is affected, with one-click repoint.

### 4.4 Validation, backups, quarantine

- **Schema version** on the snapshot, plus invariant validation on load: unique tab ids,
  well-formed pins, absolute directories.
- **Refuse partial application.** An invalid snapshot is never half-loaded; it is quarantined
  and the newest good backup is offered.
- **Rolling backups** written once per launch before the first write, keeping ~20. Not per
  `persist()` — there are 36 call sites and per-write generations would be noise.

### 4.5 `scripts/fd-state`

For when the app will not start, in the spirit of `scripts/swap-release.sh`:
`list`, `doctor` (stale pins, duplicate pins, missing transcripts), `repin`, `retitle`,
`rollback`, `fork`.

## 5. Sequencing

L1, L2 and L3 are independent and land in that order. L1 first: it is the smallest change,
it removes the corruption class, and its regression test fails today. L2 next: it is what
stops a debug build reaching the real fleet at all. L3 last and largest.

L3.2 (drop `--name` from the fallback) is a one-line change that stops damage compounding on
every restart, and should land with L1 rather than wait for the rest of L3.

## 6. Out of scope

- `FleetState` encapsulation — still deferred, for its own documented reason.
- The one-off repair of the 21 titles and the `mobile` re-pin, which is operational, not a
  code change.
- Answering why 21 attachments shared one conversation id. §2 makes it unnecessary to answer.
