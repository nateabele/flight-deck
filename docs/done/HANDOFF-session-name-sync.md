# Hand-off — Session Name Sync (Flight Deck ⇄ Claude Code)

**Date:** 2026-08-10 · **Status:** brainstorming in progress (pre-spec) · **Stage:** clarifying questions

## 0. Why this doc exists

We were brainstorming a feature and the session context was lost. This captures the
findings and decisions so far so brainstorming can resume without re-deriving anything.
When resuming: continue the `superpowers:brainstorming` flow (clarifying questions →
2–3 approaches → design sections → write spec to `docs/superpowers/specs/` → `writing-plans`
→ present via `ExitPlanMode`). Do **not** jump to implementation.

## 1. The goal (user's words)

Keep **session names in sync between the Flight Deck sidebar and Claude Code**, bidirectionally:

- **Sidebar → Claude Code:** double-click a session in the sidebar → inline edit field →
  rename it from e.g. "session 1" → that name syncs to the session name in Claude Code.
- **Claude Code → sidebar:** when `/rename` is run inside Claude Code, that new name syncs
  back to the sidebar.

## 2. Flight Deck side — how it works today (verified in code)

- **Data model** (`Sources/FlightDeck/SessionModel.swift`): `Session` is `{ let id: UUID;
  var title: String; let workingDirectory: String }`. `title` is currently `"session N"`.
  `Repo` groups sessions by working-directory root. The design spec's model comment even says
  *"renaming is out of scope"* — that changes with this feature.
- **Store** (`Sources/FlightDeck/SessionStore.swift`): `@MainActor final class SessionStore:
  ObservableObject`. Single source of truth. Holds `[Repo]`, `selectedSessionID`, and a private
  `[UUID: Ghostty.SurfaceView]` retaining live surfaces. `newSession(in:)` assigns
  `title: "session \(sessionCounter)"`. There is **no rename method yet.**
- **Sidebar** (`Sources/FlightDeck/SessionSidebar.swift`): a `List` rendering `repo.displayName`
  sections with `Text(session.title)` rows + a close button. Rendering only; issues intents to
  the Store. **No inline-edit affordance yet** (needs double-click → editable `TextField`).
- **Each session is a Ghostty terminal running a shell** (`config.command =
  ShellResolver.resolve()`), where `claude` is (or will be) running.

### The two candidate sync channels already present in the Ghostty embed

1. **Terminal pty title** — `Ghostty.SurfaceView.title` is `@Published private(set) var title`
   in `Sources/FlightDeck/GhosttyEmbed/SurfaceView_AppKit.swift` (~line 22), reflecting the pty
   title set via OSC escape codes. **BUT** the app-level `action_cb` in `GhosttyApp` that would
   deliver title-change actions is currently a **no-op** (`docs/FOLLOWUPS.md` lines ~21–22:
   *"`close_surface_cb` and `action_cb` in `GhosttyApp` are no-ops … title/notification/clipboard/
   OSC actions are dropped. Wire these when …"*). So the inbound-via-title path would require
   wiring that callback first — **and** it only works if Claude Code actually emits its session
   name as an OSC title, which is **unconfirmed** (see §3).
2. **Injecting input into the pty** — `SurfaceView_AppKit.swift` ~line 1901 calls
   `surfaceModel.sendText(chars)`, backed by `ghostty_surface_text(surface, ptr, len)`
   (~line 2022). This means Flight Deck **can write text into a running session's pty** — e.g.
   inject `/rename <name>\n` into a live `claude`.

## 3. Claude Code side — research findings (with confidence flags)

Researched via the claude-code-guide agent. **Treat the exotic API names with skepticism**
(LLM research tends to confabulate specific SDK/CLI symbols). Split into what we can rely on
vs. what must be verified empirically.

### High confidence (rely on)
- **`/rename <name>` exists** as an interactive slash command, takes an **inline argument**,
  renames the **current** session, and the name **appears on the prompt bar**. (User-asserted +
  research-confirmed.)
- **Session state, including the name, persists to**
  `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, where `<encoded-cwd>` is the cwd with
  non-alphanumeric chars replaced by `-`. The rename is recorded as a metadata entry appended to
  that JSONL transcript (custom-title). (Well-known transcript location; exact field name TBD.)
- **No rename hook**, **no live env var** carrying the current name to the child process, and
  **SessionStart/SessionEnd hooks do not receive the current name** as input. So we cannot get a
  push notification when the user types `/rename` — we must **watch the transcript file**.

### Unconfirmed / must verify empirically (do NOT design hard dependencies on these)
- Whether Claude Code emits its session name as an **OSC terminal title** (OSC 0/1/2). Not found
  in docs. Test: run a named session and observe emitted escape sequences.
- The **exact JSONL field/shape** for a rename entry (need to `/rename` and diff the transcript).
- Agent-claimed but unverified symbols: an Agent SDK `rename_session` / `get_session_info` /
  `list_sessions` / `tag_session`, a `claude agents --json` subcommand, a
  `claude -p … --continue /rename` form, a SessionStart `sessionTitle` decision field, `--name`
  launch flag. **Verify before relying on any of these.** Note the research also flagged that an
  *external* rename (SDK/CLI) does **not** live-update an already-running interactive session —
  which is a strong reason to prefer pty-injection for the outbound direction (below).

## 4. Recommended sync spine (robust, avoids unverified APIs)

- **Outbound (sidebar edit → Claude Code):** inject `/rename <name>\n` into the session's pty via
  `sendText`. This drives the exact command the user would type, so the **running** interactive
  session updates live and persists to the transcript — sidestepping the "external rename doesn't
  live-update a running session" problem. **Risks:** the claude prompt must be ready/empty (user
  might be mid-typing or mid-turn); name sanitization/escaping; echo/visual noise in the terminal.
- **Inbound (Claude `/rename` → sidebar):** **watch the session's JSONL transcript** for the
  custom-title entry and update `Session.title`. Robust, no OSC dependency. **Risks:** mapping a
  Flight Deck session → its `<session-id>.jsonl` (we know the cwd, hence the project dir, but the
  session-id is chosen by claude at launch — need a way to associate them), file-watch mechanics,
  parsing.
- **Terminal-title path is a fallback/nice-to-have**, contingent on the OSC spike + wiring
  `action_cb`. Not the primary mechanism.

A quick **empirical spike** should precede the plan: launch `claude`, run `/rename foo`, and
(a) diff the transcript JSONL to learn the exact rename entry shape, (b) capture emitted escape
sequences to settle the OSC question, (c) confirm how a fresh session-id is discoverable at launch
so we can bind a Flight Deck session to its transcript file.

## 5. Clarifying questions — asked & answered

**Q1 — Scope of the sidebar name relative to what's running in the terminal?**
(Options were: A = FD's own editable label that also syncs to Claude when present; B = strictly a
mirror of Claude's name; C = other.)

**A1 (user):** *"For now assume Claude."* There will likely be a plugin interface for different
things running in the terminal later, and a **separate workstream** will ensure Claude Code is
launched automatically in every new terminal session. **For now assume `claude` is always
running.** If Claude is not running, the name is **just a local label**.

→ **Design implication:** effectively option **A**, simplified by the assumption that `claude` is
always present. Treat the sidebar name as the Claude session name; keep it working as a plain local
label when Claude is absent; don't over-engineer the plugin/non-Claude case now, but don't hard-code
assumptions that would block it later.

## 6. Open questions still to work through (next in brainstorming)

- **Session ↔ transcript binding:** how does a Flight Deck session learn its Claude
  `<session-id>` / transcript path? (Discover newest JSONL in the project dir at launch? A launch
  flag? Parse from the pty?) This gates the inbound watcher.
- **Outbound timing/conflict:** what to do when the user renames in the sidebar but the claude
  prompt isn't ready (queue until idle? best-effort + toast? detect readiness how?).
- **Conflict resolution / source of truth** when both sides change close together (last-writer-wins?
  debounce? echo-suppression so an inbound update we caused by injection doesn't bounce back out).
- **Loop suppression:** injecting `/rename` → transcript updates → inbound watcher fires → must not
  re-inject. Need an origin tag / expected-value guard.
- **Initial name:** today it's `"session N"`. On new session, do we push that into claude via
  `/rename`, or let claude's auto-summary win until the user renames? (User said if Claude not
  running it's just a local label — implies we don't force a name.)
- **Persistence:** sessions are in-memory only today (design spec §8). Does a synced name need to
  survive relaunch? (Probably follows the existing "no persistence yet" stance.)
- **Inline-edit UX details:** double-click to edit, commit on Enter/blur, Esc to cancel, empty →
  revert; accessibility identifiers for UITests.

## 7. Where we are in the process

- [x] Explored project context (Flight Deck side fully mapped; Claude Code side researched).
- [x] Asked clarifying question #1 → answered (§5).
- [ ] Remaining clarifying questions (§6) — resume here.
- [ ] Propose 2–3 approaches with trade-offs + recommendation.
- [ ] Present design sections, get approval.
- [ ] Write spec → `docs/superpowers/specs/2026-08-10-session-name-sync-design.md`, commit.
- [ ] Spec self-review + user review gate.
- [ ] `writing-plans` → present plan via `ExitPlanMode` (per user's global planning workflow).

## 8. Key files

- `Sources/FlightDeck/SessionModel.swift` — `Session.title` lives here.
- `Sources/FlightDeck/SessionStore.swift` — add a `rename(_:to:)` intent; origin/echo guards.
- `Sources/FlightDeck/SessionSidebar.swift` — add double-click inline `TextField` edit.
- `Sources/FlightDeck/GhosttyEmbed/SurfaceView_AppKit.swift` — `title` (~L22), `sendText`
  (~L1901), `ghostty_surface_text` (~L2022).
- `docs/FOLLOWUPS.md` — `action_cb`/`close_surface_cb` no-op note (title/OSC wiring).
- `docs/superpowers/specs/2026-08-08-multi-session-foundation-design.md` — current foundation.
