# Hook-fed composer state

**Status:** design
**Date:** 2026-09-19

Replace the screen-grammar gate in front of pty injection with an event-fed
liveness signal plus a narrow, stable dialog veto — keeping the real pty and
the real TUI for everything else.

## 1. Problem

`SessionStore.inject` — the single funnel for every string Flight Deck types
into a live agent (phone prompts, `/rename`, `/login`, restore's "Keep going")
— decides whether it is safe to type by *reading the screen*.
`ClaudeTextChannel.isComposerBox` parses the viewport for a `─`/`❯`/`─`
sandwich; `CodexTextChannel` parses a footer. Three failures follow:

1. **The grammar is a guess about a UI, not a contract.** Pinned to Claude
   Code's rendering, re-derived from captured fixtures. Every shape it has not
   seen is a wrong answer in one direction or the other.
2. **It reads a moving screen.** A viewport read taken while a turn streams can
   land mid-repaint — exactly when a phone prompt arrives.
3. **It breaks on Claude Code updates, silently, in production.**

Drafts are *not* the problem. The kill-and-compare dance in
`ClaudeTextChannel.submit` works and is out of scope.

## 2. Approach

Claude Code fires a documented set of lifecycle hooks, identically in the
interactive TUI and headless. Flight Deck spawns these processes, so it can
load a plugin into them and receive those events directly.

The design splits one question into two, and gives each to the source that can
actually answer it:

- **"Is this session booted and alive?"** → hooks. A durable fact, derived from
  the agent's own lifecycle, with no screen involved.
- **"Is a dialog covering the composer right now?"** → a narrow screen veto
  keyed on `Esc to cancel`, a piece of user-facing copy with a fixed meaning.

The screen read is not eliminated. It is reduced from a geometry parse that
must positively recognise a composer, to a string match that positively
recognises a dialog.

## 3. What the probes established

Four probes on 2026-09-19, headless and under a real pty.

**Confirmed:**

- `--plugin-dir` loads a plugin with **no trust prompt**.
- `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`,
  `SessionEnd` all fire **in a real interactive TUI**, in order.
- `PermissionRequest` fires when an approval dialog is raised, followed by
  `Notification`.
- Payloads carry `session_id` (a UUID) and `hook_event_name`, so the hook
  script needs no argument and no `jq`.
- **No hook fires at all until the folder is trusted.**

**Two findings that changed the design:**

1. **Claude Code raises select-list dialogs of its own, unprompted, right
   after `Stop`.** The probe caught "Teach auto mode about your environment?
   1. Yes / 2. Not now / 3. Don't show again". Any model in which `Stop` means
   "composer ready" is wrong at exactly the moment a queued prompt fires. An
   earlier draft argued TUI-only dialogs are user-initiated and therefore safe
   to fail open against; that is false.
2. **Denying a permission prompt with `Esc` fires no hook at all.** Event
   sequence was unchanged across the dismissal. There is no "dialog dismissed"
   signal on the deny path.

Finding 2 kills a `.dialog` state. A state entered by `PermissionRequest` and
cleared "by any later event" deadlocks on deny: readiness stays `.dialog`,
injection is refused, and the only event that would clear it —
`UserPromptSubmit` — is the very thing being refused. The tab wedges until a
human types into it locally.

Both dialog families share the footer token **`Esc to cancel`** (permission:
`Esc to cancel · Tab to amend`; nudge: `Enter to confirm · Esc to cancel`).
Since the veto must catch family 2 regardless, it catches family 1 for free —
so `.dialog` is redundant *and* hazardous. It is not in this design.

## 4. Components

### 4.1 The plugin

A directory shipped in the app bundle, loaded per-session by adding
`--plugin-dir <path>` to the launch command. Per-session only: the user's
`~/.claude` is never written to, which matters because the built-in account's
home *is* their real `~/.claude`.

One script, registered against the lifecycle hooks, whose whole body is:

```bash
[ -n "${FLIGHT_DECK_EVENT_DIR:-}" ] || exit 0
cat | tr -d '\n' >> "$FLIGHT_DECK_EVENT_DIR/events.ndjson"
printf '\n' >> "$FLIGHT_DECK_EVENT_DIR/events.ndjson"
exit 0
```

The payload already carries `hook_event_name` and `session_id`, so the script
passes no arguments and parses nothing. Hooks run synchronously and block the
agent, so this stays a single append. No `jq`, no network, `exit 0` always.

An absent env var means an absent Flight Deck: a user running `claude` with
this plugin by hand pays one `exit 0`.

### 4.2 Transport

**One** append-only NDJSON file for the whole app, in a directory named by
`FLIGHT_DECK_EVENT_DIR`. Flight Deck demultiplexes by the `session_id` in each
record.

One shared file rather than one per session, because the hook script cannot
cheaply derive a per-session filename without parsing its payload — and this
mirrors the existing `SessionStatusWatcher` shape exactly: a single watcher
that scans once per tick and fans out, rather than one watcher per tab.

A file rather than a socket: Flight Deck already watches files
(`TranscriptWatcher`, `TailReader`, the shared `WatchClock`) and that machinery
is proven; a socket needs a per-session listener and a lifecycle to leak.
`O_APPEND` writes of this size are atomic.

`TailReader` is reused as-is with `TailTruncationPolicy.resumeAtEnd`, the
policy meant for a shared append-only log.

The env var is also the isolation seam: **debug and release must name
different directories**, or they read each other's events — the trap
`sessions.json` already has.

Claude's `session_id` is the UUID Flight Deck minted and passed as
`--session-id`, so it matches `binding.conversationID` with no extra mapping.

### 4.3 Readiness

```swift
enum ComposerReadiness: Equatable {
    case unknown   // no events seen for this session yet
    case live      // booted, running, not ended
    case absent    // SessionEnd seen
}
```

| Event | Readiness |
|---|---|
| `SessionStart` | `.live` |
| `UserPromptSubmit` | `.live` |
| `PreToolUse` | `.live` |
| `PostToolUse` | `.live` |
| `Stop` | `.live` |
| `SessionEnd` | `.absent` |

**Busy versus idle is deliberately not modelled.** Mid-turn injection is fine —
Claude queues it — so every non-terminal event collapses to the same answer.
Activity already has an owner (`ClaudeStatusFile` → `AgentEvent.activity`); a
second, differently-derived answer would be free to disagree with it.

**`PermissionRequest` and `Notification` are deliberately not wired.**
`PermissionRequest` has no observable clear (§3, finding 2), and `Notification`
fires for permission prompts as well as idle, so neither can carry a state
transition honestly. The veto covers what they would have covered.

`.unknown` is load-bearing, not a placeholder: it is a session restored from an
older build's snapshot, one whose plugin failed to load, and one in an
untrusted folder. It falls back to today's full screen grammar, so the change
degrades to the status quo rather than to a refusal.

### 4.4 The gate

`SessionStore.injectionGate` becomes:

```
.live     →  inject, unless channel.isKnownNonComposer(viewport)
.unknown  →  today's full-grammar screen check (unchanged legacy path)
.absent   →  refuse
```

### 4.5 The veto

`isKnownNonComposer(_ viewport: String) -> Bool` replaces `hasComposerBox` on
the gate path. It returns `true` **only when it positively recognises** a
dialog, and `false` whenever unsure.

The inversion is the point. `AND`-ing hook state with the *existing* predicate
would preserve failure-on-update: a drifted grammar that stopped recognising a
composer would still block injection — the bug being fixed. A veto that fires
only on positive recognition makes drift fail **open**.

It keys on **`Esc to cancel`**, which both dialog families carry and a composer
never does. That is a far more stable signal than the box-drawing sandwich it
replaces: user-facing copy with a fixed meaning, rather than an incidental
artefact of how a frame is drawn.

**It must not match a running turn.** Claude Code shows `esc to interrupt`
while streaming, which is a different string and must stay unmatched — the
whole point of allowing mid-turn injection is that Claude queues it. This is a
required test, not an incidental one.

### 4.6 Codex parity

Codex gets the same `ComposerReadiness`, fed from its app-server rather than
hooks: it already has structured thread status over `CodexRPC`, so its footer
scrape is replaced by the same readiness from a better source, with its own
veto for its own dialog shapes. The readiness type and the gate are
agent-agnostic; only the feed differs.

This is the adapter rule honoured, not excepted: an agent-specific *signal* is
a reason to put detection behind the adapter, never to scope a feature to one
agent.

### 4.7 Wiring

- `AgentEvent` gains `.lifecycle(ComposerReadiness)`. The only exhaustive
  switch is `SessionStore.apply(_:to:)`, so the case and its arm land together.
- `SessionStore` owns one `HookEventWatcher` (mirroring `SessionStatusWatcher`)
  and fans its output to `ClaudeRuntime.ingest(...)`, which emits `.lifecycle`
  to that conversation's subscribers.
- `SessionStore` holds `composerReadiness: [UUID: ComposerReadiness]`, written
  by `apply` and read by `injectionGate`.
- `--plugin-dir` is injected **where flags are resolved**, not in
  `ClaudeAdapter` — `ClaudeAdapterTests` asserts `launchCommand`/`resumeCommand`
  are byte-identical pass-throughs to `ClaudeSession`, and that property is
  worth keeping.

## 5. Error handling

- **Plugin never loads, or folder untrusted** → readiness stays `.unknown`;
  behaves exactly as today. No refusal, no regression.
- **Event file grows** → truncated at launch; `TailReader` resumes at end.
- **Stale readiness after a crash** → never persisted; relaunch starts
  `.unknown`.
- **Hook script error** → exits 0 on every path; must never block the agent.
- **A session whose events never arrive** (plugin stripped by `--bare`) →
  `.unknown`, legacy path.

## 6. Testing

- **Unit — readiness.** Synthetic event sequences to every state, including
  out-of-order arrival and an unknown `hook_event_name` (must be ignored, not
  crash).
- **Unit — the veto, against the existing corpus.** `Fixtures/Claude/` already
  holds `permission-bash`, `permission-write`, `permission-write-60col`,
  `permission-write-row2`, `question-*` (11 captures), and `workspace-trust`:
  **every one must veto**. `idle-empty-box`, `busy-*` (5 captures): **none may
  veto** — `busy-streaming-*` is the `esc to interrupt` case.
- **New fixture.** The nudge dialog the probe caught ("Teach auto mode…") must
  be captured and must veto. It is the shape that motivated the veto.
- **Unit — gate.** `.unknown` takes the legacy path; `.absent` refuses;
  `.live` injects; `.live` + veto refuses.
- **Integration.** A denied permission prompt must leave the tab injectable —
  the regression this design exists to avoid.
- **End-to-end.** Phone prompt mid-turn and while idle; both land as real user
  turns. `/rename` still works (the class that broke 100% of renames before).

`test-unit.sh` runs `xcodegen generate` then drives `xctest` on the bundle
directly, and ignores `-only-testing:` — budget ~8 minutes per run. Nothing
here touches `Sources/FlightDeckMobile`, so `test-ios.sh` is not needed.

**`Bundle.main` is the `xctest` tool under that runner, not `Flight Deck.app`.**
The plugin-directory lookup must therefore be an injectable seam with a
`Bundle.main` default, exactly as `SessionDaemon.bundledBinary` already is.

## 7. Risks

| Risk | Handling |
|---|---|
| Hook latency blocks the agent | One append, no `jq`, always `exit 0`. Measure. |
| Veto misses a new dialog family | Fails open — an injection lands in a picker. Bounded and recoverable; the alternative (fail closed) reintroduces the original bug. |
| Veto matches a running turn | Explicit test on `busy-streaming-*`; `esc to interrupt` must not match. |
| Debug/release share an event dir | Different `FLIGHT_DECK_EVENT_DIR` per build. |
| Plugin path has spaces (`Flight Deck.app`) | `ClaudeFlagSerializer` quoting; assert with a test. |
| Claude Code renames a hook event | Unknown names ignored; readiness degrades to `.unknown` → legacy path. |
| `--bare` strips plugins | `.unknown` → legacy path. |

## 8. Open questions

1. Should `PermissionRequest` be re-introduced later as a veto *strengthener*
   (set a flag that also vetoes, cleared by any later event **or** a short
   timeout)? It would add defence-in-depth without the deadlock, but only
   earns its place if the veto proves insufficient in practice. Deferred.
2. Should injection additionally defer when the tab has focus and has seen
   recent keystrokes — a cheap way to avoid typing over someone mid-thought,
   independent of the screen? Deferred; not required here.
