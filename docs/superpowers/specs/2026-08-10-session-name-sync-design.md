# Session Name Sync (Flight Deck ⇄ Claude Code) — Design

**Date:** 2026-08-10 · **Status:** design approved, ready for planning
**Supersedes the open questions in** `docs/HANDOFF-session-name-sync.md` §6.

## 1. Goal

Keep a session's name in sync in both directions:

- **Sidebar → Claude:** double-click a sidebar row → inline edit → the new name reaches the
  running `claude`.
- **Claude → sidebar:** `/rename` inside `claude` updates the sidebar row.

## 2. Findings that settle the prior unknowns

All of these were verified empirically on 2026-08-10 against the installed `claude`, not
inferred from docs. They replace the speculative material in the handoff.

| Question | Answer | Confidence |
|---|---|---|
| Bind a session to its transcript | `claude --session-id <uuid>` accepts a caller-chosen UUID | CONFIRMED (`claude --help`) |
| Set a name at launch | `claude -n/--name <name>` | CONFIRMED (`claude --help`) |
| Reattach to a conversation | `claude -r/--resume <session-id>` restores it across processes | CONFIRMED (round-trip test) |
| Resume of a missing transcript | exits `1`, so a `\|\|` shell fallback fires | CONFIRMED (exit-code test) |
| Transcript location | `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` | CONFIRMED |
| cwd encoding | every non-`[0-9A-Za-z]` **UTF-16 code unit** → `-`, one-for-one, no collapsing | CONFIRMED |
| Rename record shape | a JSONL line `{"type":"custom-title","customTitle":"<name>","sessionId":"<uuid>"}` | CONFIRMED |
| Rename push notification (hook/env) | none exists — must watch the transcript | CONFIRMED |
| OSC title carrying the name | not needed; the transcript path is strictly better | dropped from scope |

Two consequences:

- `Session.id` is **already** a `UUID`. We pass that same UUID to `claude`, so the transcript
  path is fully determined at launch. No discovery, no race.
- The inbound watcher is no longer speculative. It is a file tail looking for one known line
  shape.

The `sessions-index.json` sidecar in each project dir carries `summary` (Claude's
auto-summary), not the custom title. We do not read or write it.

## 3. Architecture

Four units, each independently testable.

### 3.1 `ClaudeSession` — pure functions (new file)

No I/O, no state. Two responsibilities:

- `transcriptURL(sessionID:workingDirectory:)` → applies the encoding rule above.
- `customTitle(inLine:)` → parses one JSONL line, returns the `customTitle` when
  `type == "custom-title"` and the `sessionId` matches, else `nil`.

Kept pure so the encoding rule and the parse are unit-testable without a filesystem.

**The encoding rule, exactly.** Replace every UTF-16 code unit that is not an ASCII
alphanumeric (`0-9`, `A-Z`, `a-z`) with `-`. Runs are not collapsed.

This is narrower than it first appears, and getting it wrong is silent. Swift's
`Character.isLetter` is Unicode-aware and would keep `é`, `Ω`, and CJK characters —
Claude does not. Verified by creating real sessions and reading back the directories
Claude created:

| cwd | directory Claude created |
|---|---|
| `…/scratchpad/café-Ω-probe` | `…-scratchpad-caf----probe` |
| `…/scratchpad/emo🎈dir` | `…-scratchpad-emo--dir` |

The emoji becoming **two** dashes is the decisive case: the replacement is per UTF-16
code unit, so a surrogate pair yields two dashes. That matches a JavaScript
`.replace(/[^a-zA-Z0-9]/g, '-')` without the `u` flag.

Getting this wrong doesn't crash — it computes a path that doesn't exist, and inbound
sync just never fires. That failure is invisible, which is why it is pinned by test
rather than left to inference.

### 3.2 `TranscriptWatcher` — inbound (new file)

Owns one session's transcript file. Watches with a `DispatchSource` file-system monitor,
reading only the bytes appended since the last offset, and emits the **last** `customTitle`
seen in that batch via a callback on the main actor.

Because `claude` creates the file slightly after launch, the watcher starts in a
"waiting" state watching the parent directory, then promotes itself to watching the file once
it appears.

Failure is non-fatal by design: if the file never appears (e.g. `claude` is not running), the
watcher stays idle and the name remains a plain local label — exactly the behaviour agreed in
handoff §5.

### 3.3 `SessionStore` — the sync spine

Gains one intent and one seam.

```
func rename(_ id: UUID, to newTitle: String)
```

- Sanitizes, updates `Session.title`, then injects `/rename <name>\n` into that session's pty.

The injection goes through a small `TextInjecting` protocol (implemented by the real
surface) so the store is testable with a fake. This mirrors the existing `SurfaceProvider`
seam rather than inventing a new pattern.

**Launch.** `newSession(in:)` keeps `command = ShellResolver.resolve()` and adds:

```
config.initialInput = "claude --session-id <uuid> --name <quoted title>\n"
```

so the shell immediately execs `claude` already bound to our UUID and our name. This is the
seam the separate auto-launch workstream can later take over; it is deliberately one
assignment in one place.

### 3.4 `SessionSidebar` — inline edit

Double-click a row → the `Text` becomes a `TextField`. Enter or blur commits; Esc cancels;
an empty or whitespace-only value reverts to the previous title. The field carries
`accessibilityIdentifier("session-title-field")` for UITests, alongside the existing
`close-session` / `new-session` identifiers.

### 3.5 `SessionPersistence` — surviving relaunch

Sessions persist so every tab returns after a restart, each reattached to its own Claude
conversation. This falls out of the same decision that enables sync: because *we* choose
the session UUID and persist it, restore is just `--resume <that id>`.

A `SessionSnapshot: Codable` holds the ordered sessions (`id`, `title`,
`workingDirectory`), the selection, and the session counter — the counter so a newly
created session cannot reuse a restored session's number. Repos are *derived* from
`workingDirectory`, so only sessions are stored and the grouping rebuilds on load.

Storage is behind a `SessionPersisting` protocol (same seam style as `SurfaceProvider`
and `TextInjecting`), with a `UserDefaults` implementation and an in-memory fake for
tests. It writes to the app's standard defaults domain, which `scripts/smoke.sh:14`
already wipes via `defaults delete dev.flightdeck.FlightDeck` — so the UITest gate stays
hermetic with no new plumbing.

Saving happens on every mutation rather than at terminate, so a crash cannot lose the
list. The list is a handful of small structs; the cost is irrelevant.

Two degradations, both deliberate:

- A session whose `workingDirectory` no longer exists is **dropped** on restore rather
  than resurrected as a broken terminal.
- A session whose transcript has been deleted or pruned still returns: the restore
  command is `claude --resume <id> || claude --session-id <id> --name '<title>'`, so it
  comes back as a fresh conversation with the right id and name instead of a dead pane
  showing a resume error. This relies on `--resume` exiting non-zero, which is confirmed
  in §2.

Closing a session removes it from the snapshot. It does **not** delete the underlying
Claude transcript — closing a tab is not deleting a conversation.

## 4. Data flow

**Outbound.** double-click → edit → commit → `store.rename(id, to:)` → title updated →
`/rename <name>\n` injected → `claude` renames itself and appends a `custom-title` line.

**Inbound.** user types `/rename` in the terminal → `claude` appends a `custom-title` line →
watcher reads the delta → `store.applyExternalTitle(id, title)` → `Session.title` updated.

**Loop suppression.** `applyExternalTitle` is a no-op when the incoming title already equals
the current title. An outbound rename sets the title *before* injecting, so the
`custom-title` line it causes matches and stops there. No origin tags or echo counters are
needed — the guard is a value comparison, which also makes the two directions converge
naturally when both change close together (last writer wins).

## 5. Name sanitization

Applied on every outbound rename, because the name is interpolated into a shell-visible
command line:

- trim whitespace; reject empty (revert to previous title)
- strip control characters and newlines (prevents injecting a second command)
- cap length (120 chars)
- single-quote for the command line, escaping embedded single quotes

The same sanitizer is used for the `--name` argument at launch.

## 6. Testing

Unit, no filesystem or terminal required:

- path encoding for a handful of representative cwds, including one with a leading `-`
- `customTitle(inLine:)` against fixture lines: a real `custom-title` line, an `agent-name`
  line, a mismatched `sessionId`, and malformed JSON
- sanitizer: empty, whitespace-only, embedded newline, embedded quote, over-length
- `SessionStore.rename` updates the title and injects exactly one `/rename` line (fake injector)
- `applyExternalTitle` no-ops when the value is unchanged (loop suppression)

Integration, filesystem only (no `claude` process): write a temp `.jsonl`, append a
`custom-title` line, assert the watcher reports it.

The existing smoke/UITest gate gains one case: double-click a session row, type a name, press
Enter, assert the row shows it.

## 7. Explicitly out of scope

- Restoring terminal *scrollback*. `--resume` restores the conversation; the pane starts
  with a fresh screen.
- OSC/terminal-title plumbing and the `action_cb` no-op in `docs/FOLLOWUPS.md`.
- Reading or writing `sessions-index.json`.
- Non-Claude programs in the terminal; per handoff §5 we assume `claude`, and degrade to a
  plain local label when it is absent.
- Renaming repos/groups. Only sessions.

## 8. Risks

- **Injection timing.** If the user is mid-typing when a sidebar rename commits, the injected
  `/rename` mixes with their input. Accepted for this increment: the rename is best-effort and
  visible in the terminal. A readiness detector is a follow-up, not a blocker.
- **`--name` at launch overrides Claude's auto-summary.** Intended: the sidebar is the source
  of truth at creation time.
- **Encoding rule gaps.** Mitigated by the bounded-scan fallback in §3.1.
