# Hook-fed composer state

**Status:** design
**Date:** 2026-09-19

Replace the screen-grammar gate in front of pty injection with an event-fed
session state machine, keeping the real pty and the real TUI for everything
else.

## 1. Problem

`SessionStore.inject` — the single funnel for every string Flight Deck types
into a live agent (phone prompts, `/rename`, `/login`, restore's "Keep going")
— decides whether it is safe to type by *reading the screen*.
`ClaudeTextChannel.isComposerBox` parses the viewport for a `─`/`❯`/`─`
sandwich; `CodexTextChannel` parses a footer. Three failures follow from that:

1. **The grammar is a guess about a UI, not a contract.** It is pinned to
   Claude Code's rendering and re-derived from captured fixtures. Every shape
   it has not seen — a picker, an unfamiliar dialog, a partially-drawn frame —
   is a wrong answer in one direction or the other.
2. **It reads a moving screen.** A viewport read taken while a turn is
   streaming can land mid-repaint, which is exactly when a phone prompt
   arrives.
3. **It breaks on Claude Code updates, silently, in production.** The failure
   is a regression discovered by a person, not by the build.

Drafts are *not* the problem. The kill-and-compare dance in
`ClaudeTextChannel.submit` works and is out of scope here.

## 2. Approach

Claude Code fires a documented set of lifecycle hooks, identically in the
interactive TUI and headless. Flight Deck spawns these processes, so it can
load a plugin into them and receive those events directly. The composer's
presence stops being *inferred from pixels* and becomes *derived from the
agent's own lifecycle*.

The screen read does not disappear. It is demoted from the gate to a **veto**
that only fires when it positively recognises a non-composer shape.

### Verified by probe (2026-09-19)

A throwaway plugin loaded with `--plugin-dir` against Claude Code confirmed:

- `--plugin-dir` loads a plugin with **no trust prompt**.
- `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` and
  `SessionEnd` all fire, in order.
- Every payload carries `session_id` as a UUID and `transcript_path`.
- A hook that exits 0 when its env var is unset costs nothing.
- No `jq` dependency: the hook forwards its own stdin with `tr -d '\n'`.

### Non-goals

- **The Agent SDK.** It has no TUI (fidelity) and bills per-token against the
  API rather than the subscription (cost). Rejected on both counts.
- **Replacing the pty.** The pty stays. Rendering, keystrokes and the TUI are
  unchanged.
- **A hook mailbox for injection.** `additionalContext` delivery was
  considered and dropped: no hook can wake an idle session, and injected text
  lands as a `system` reminder rather than a `user` turn, so a phone prompt
  delivered that way would not read as the person's own message. Injection
  stays typed.
- **Removing `submit()`'s viewport reads.** The multi-row-draft guard stays.
  Revisit once the state machine is proven.

## 3. Components

### 3.1 The plugin

A directory shipped inside the app bundle, loaded per-session by adding
`--plugin-dir <bundle>/Contents/Resources/ClaudePlugin` to the launch command.
Per-session only: the user's `~/.claude` is never written to, which matters
because the built-in account's home *is* their real `~/.claude`.

One script, registered against every lifecycle hook, whose whole body is:

```bash
[ -n "${FLIGHT_DECK_EVENT_DIR:-}" ] || exit 0
printf '%s\t%s\n' "$1" "$(cat | tr -d '\n')" >> "$FLIGHT_DECK_EVENT_DIR/$$.ndjson"
exit 0
```

Hooks run synchronously and block the agent, so the script must stay a single
append. No `jq`, no subshell beyond the one capture, no network.

Absent env var means absent Flight Deck: a user running `claude` with this
plugin by hand pays one `exit 0`.

### 3.2 Transport

An append-only NDJSON file per session in a Flight-Deck-owned directory, named
by the env var `FLIGHT_DECK_EVENT_DIR`, set in `ClaudeAdapter.environment(for:)`.

A file rather than a socket: Flight Deck already watches files
(`TranscriptWatcher`, `SessionStatusWatcher`) and that machinery is proven,
whereas a socket would need a per-session listener and a lifecycle to leak.
`O_APPEND` writes of this size are atomic, and the reader is a tail.

The env var is also the isolation seam. A debug build and a release build must
name **different** directories, or they will read each other's events — the
same trap `sessions.json` already has.

Events are keyed by `session_id`, which for Claude is the UUID Flight Deck
minted and passed as `--session-id`, so it matches `binding.conversationID`
with no extra mapping.

### 3.3 The state machine

```swift
enum ComposerReadiness: Equatable {
    case unknown   // no events yet
    case absent    // not started, or ended
    case present   // this agent's own composer is on screen
    case dialog    // agent-raised dialog on screen
}
```

Claude's transitions:

| Event | Readiness |
|---|---|
| `SessionStart` | `.present` |
| `UserPromptSubmit` | `.present` |
| `PreToolUse` | `.present` |
| `PermissionRequest` | `.dialog` |
| `PostToolUse` | `.present` |
| `Notification` (`idle_prompt`) | `.present` |
| `Stop` | `.present` |
| `SessionEnd` | `.absent` |

**Busy versus idle is deliberately not modelled here.** Every event that is
not a dialog collapses to the same answer, because the question this type
exists to answer is "is there a composer to type into", and mid-turn injection
is fine — Claude queues it. Activity already has an owner: the status registry
(`ClaudeStatusFile`) feeds `AgentEvent.activity`, and a second, differently-
derived answer to the same question would be free to disagree with it.

`.dialog` is cleared by *any* later event, because there is no dedicated
"dialog dismissed" hook: an approved tool produces `PostToolUse`, a denied one
produces a later event, and a turn abandoned at the dialog produces `Stop`.
**This rule must be verified by live probe during implementation**, not
assumed — particularly what fires on deny.

`.unknown` is load-bearing, not a placeholder. It is the state of a session
restored from a snapshot written by an older build, or one whose plugin failed
to load. It falls back to today's behaviour — the full screen grammar, alone —
so the change degrades to the status quo instead of to a refusal.

### 3.4 The gate

`SessionStore.injectionGate` becomes:

```
readiness == .present  AND  NOT channel.isKnownNonComposer(viewport)
readiness == .unknown  →    today's full-grammar screen check
readiness == .dialog / .absent  →  refuse
```

### 3.5 The veto, and why it fails open

`isKnownNonComposer(_ viewport: String) -> Bool` replaces
`hasComposerBox` on the gate path. It returns `true` **only when it positively
recognises** a full-screen picker or dialog shape, and `false` whenever it is
unsure.

This inversion is the point. An `AND` of hook state with the *existing*
predicate would keep failure-on-update: a drifted grammar that stops
recognising a composer would still block injection, which is the bug being
fixed. A veto that only fires on positive recognition means drift fails
**open** — injection keeps working, and the residual risk is typing into an
unrecognised picker.

**What the veto must recognise, corrected by probe (2026-09-19).** An earlier
draft of this section argued the residual was bounded because TUI-only dialogs
are user-initiated — the person is at the keyboard when one is open. **The
interactive probe falsified that.** Immediately after `Stop` fired, Claude Code
spontaneously raised a select-list dialog of its own ("Teach auto mode about
your environment? 1. Yes / 2. Not now / 3. Don't show again"). Hook state at
that instant reads `.present`, because `Stop` is the settle signal — and that
is precisely the moment a queued phone prompt fires. An unprompted nudge dialog
is therefore a **common** case arriving at the **worst** moment, not a rare
user-initiated one.

So the veto is load-bearing and must be good. It keys on **list-ness**, not on
composer geometry: the footer `Enter to confirm · Esc to cancel` and numbered
`❯`-marked rows. That is a far more stable signal than the box-drawing sandwich
it replaces — it is user-facing copy with a fixed meaning rather than an
incidental artefact of how a frame is drawn — and it is what makes fail-open
defensible: the shapes that actually threaten an injection are recognised by a
string that has no reason to churn, while an unrecognised *composer* variant
still lets injection through.

The hook-covered dialogs (permission prompts) never reach the veto at all.

### 3.6 Codex parity

Codex gets the same `ComposerReadiness`, fed from its app-server rather than
from hooks: it already has structured thread status over `CodexRPC`, so its
footer scrape is replaced by the same state machine from a better source. The
readiness type and the gate are agent-agnostic; only the feed differs.

This is the adapter rule, not an exception to it: a UI-surfaced capability
lands through the adapter interface for every adapter, and an agent-specific
*signal* is a reason to put detection behind the adapter, never to scope the
feature to one agent.

### 3.7 Wiring

- `AgentEvent` gains `.lifecycle(ComposerReadiness)`. Every switch over
  `AgentEvent` is exhaustive, so the case and all its handler arms land in one
  commit.
- `ClaudeRuntime` gains a `HookEventWatcher`, built alongside
  `TranscriptWatcher` in `attach` and stopped in `detach` on the last
  subscriber, emitting `.lifecycle(...)`.
- `CodexRuntime` emits `.lifecycle(...)` from thread status.
- `SessionStore` holds `composerReadiness: [UUID: ComposerReadiness]`, written
  from the event handler and read by `injectionGate`.

## 4. Error handling

- **Plugin fails to load / hooks never fire.** Readiness stays `.unknown`
  forever; the session behaves exactly as it does today. No refusal, no
  regression.
- **Event file grows unboundedly.** Truncated on session end; the watcher
  tails from its own offset and never reads the backlog.
- **Stale readiness after a crash.** Readiness is per-tab in memory, never
  persisted, so a relaunch starts at `.unknown` and falls back.
- **A hook script error.** Exits 0 on every path. A hook that fails must never
  block the agent.

## 5. Testing

- **Unit — state machine.** Synthetic event sequences to every state,
  including the `.dialog`-clear rule and out-of-order arrival.
- **Unit — the veto.** Run `isKnownNonComposer` against every capture in
  `Fixtures/Claude/`: every dialog and picker fixture must veto; no composer
  fixture may.
- **Unit — gate.** `.unknown` takes the legacy path; `.dialog` refuses;
  `.present` injects.
- **Live probe.** Extend `scripts/adapterprobe` to assert the real event order
  against a real `claude`, and to establish the two transitions this design
  still assumes rather than knows: that `PermissionRequest` fires at all (see
  §7.1), and what clears it on deny.
- **Interactive confirmation — done.** A PTY probe on 2026-09-19 observed
  `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` and
  `SessionEnd` firing in a real interactive TUI session, in order. It also
  established that **no hook fires at all until the folder is trusted** — an
  untrusted directory leaves readiness `.unknown`, which correctly degrades to
  the legacy path.
- **Veto corpus.** The nudge dialog the probe caught ("Teach auto mode…") must
  be captured as a fixture and must veto.

`test-unit.sh` ignores `-only-testing:` and runs the whole macOS suite — budget
~8 minutes per run. Nothing here touches `Sources/FlightDeckMobile`, so
`test-ios.sh` is not needed.

## 6. Risks

| Risk | Handling |
|---|---|
| Hook latency blocks the agent | One append, no `jq`, `exit 0` always. Measure in the probe. |
| `.dialog` clear rule is wrong on deny | Probe it before relying on it; until proven, a denied prompt resolves via the next event or `Stop`. |
| Veto fails open into a picker | Accepted, §3.5 — but only because the veto keys on list-ness (`Enter to confirm · Esc to cancel`), which probe evidence shows is the shape that actually threatens an injection. Unprompted nudge dialogs land right after `Stop`, so this veto is load-bearing, not a backstop. |
| Debug/release share an event dir | Different `FLIGHT_DECK_EVENT_DIR` per build. |
| Plugin path has spaces (`Flight Deck.app`) | `ClaudeFlagQuoting` already handles it; assert with a test. |
| Claude Code renames a hook event | Readiness degrades to `.unknown` → legacy path, not a break. |

## 7. Open questions

1. **Does `PermissionRequest` fire at all?** Two probes have now failed to
   observe it — headless raises no dialog (it auto-denies, and `PostToolUse`
   still fires), and the interactive probe had its tool auto-approved. If it
   turns out not to fire, `.dialog` loses its only source and the veto becomes
   the *sole* defence against permission prompts too. **This must be settled
   before the gate depends on it** — it is the first task of implementation,
   not a later verification.
2. What fires when a permission prompt is **denied**? Determines the
   `.dialog`-clear rule. Same probe.
3. Does `Notification`/`idle_prompt` fire reliably enough to be a transition,
   or should it be dropped and `Stop` left as the sole settle signal?
4. Should injection additionally defer when the tab has focus and has seen
   recent keystrokes — a cheap way to avoid typing over someone mid-thought,
   independent of the screen? Deferred; not required by this design.
