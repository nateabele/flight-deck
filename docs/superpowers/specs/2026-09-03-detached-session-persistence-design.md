# Detached session persistence — design

**Goal: a Flight Deck session's agent process survives the app being killed, and reattaches
with its full terminal restored — so the "Keep going" resume hack is no longer the primary
restore path.**

## The problem

Today a session's `claude` (or `codex`) runs in a PTY that **libghostty owns inside the Flight
Deck process**. When the process dies — `⌘Q`, a crash, a dev rebuild, or `swap-release.sh`
(which `SIGKILL`s the app) — the PTY master closes, the child gets `SIGHUP`, and the agent
dies with it. Nothing of the running process survives; only the transcript on disk does.

Restore therefore *reconstructs* rather than *resumes*: `SessionStore.restore` forks a fresh
login shell, `sendToShell`s `adapter.resumeCommand(...)` (`claude --resume <id>`), waits for it
to settle, then types **"Keep going"** (`SessionStore.resumePrompt`, the `pendingResumePrompts`
machinery, `cancelSupersededPrompts`) to nudge the freshly-resumed agent to continue whatever
it was doing when the app died. It is a fragile approximation: a new process, a new pid, a
re-rendered conversation, and a guess ("keep going") standing in for the work that was actually
in flight. See `docs/superpowers/specs/2026-08-15-auto-resume-design.md`.

## What libghostty does and does not offer (verified)

Checked against `vendor/ghostty/include/ghostty.h`. `ghostty_surface_config_s` exposes exactly
three process levers — `command`, `initial_input`, `wait_after_command` — and libghostty forks
`command` into a PTY it owns **in-process**. There is no attach-to-existing-fd call, no detach
call, no PTY handoff anywhere in the C API. (`hyperb1iss/ghostty-automator`, a purpose-built
ghostty automation fork on the same v1.3.1 pin, confirms this from the other side: its IPC
server also runs *in-process* and dies with the app. Its span-encoded screen-read protocol is
unrelated prior art worth remembering for UI-test/phone screen capture, nothing more.)

**So process persistence is orthogonal to libghostty.** The only lever is `command`. Persistence
must come from making `command` attach to a process that lives in a **separate process tree**.

## Approach: a forked-abduco session daemon per session, with an in-memory replay buffer

Each session's agent runs inside a small long-lived **daemon** (a fork of
[`abduco`](https://github.com/martanne/abduco), ISC-licensed) that owns the real PTY. The
ghostty surface's `command` becomes the daemon's **attach-client**, which connects over a Unix
socket, replays the session's output so far, then pipes live I/O both ways. The daemon is
`setsid`'d into its own session/process group, so an app `SIGKILL` — including `swap-release.sh`
— cannot reach it; it merely drops the client socket, and the agent keeps running.

Three properties make this the right shape:

- **Ghostty stays the only emulator.** abduco does not emulate a terminal; it pipes PTY bytes.
  A terminal's screen+scrollback is a deterministic fold over its input byte stream, so replaying
  the exact bytes the agent emitted into a *fresh* ghostty surface reconstructs the full screen
  and scrollback natively — no status line, no prefix key, no copy-mode, no reflow fights, `⌘K`
  and tab-nav untouched. This is why abduco was chosen over tmux.
- **The replay buffer lives in the daemon's memory, not on disk.** It only has to outlive
  *Flight Deck*, which it does by being in a separate process that Flight Deck's death does not
  touch. If the daemon *itself* dies (the agent crashed), the session is genuinely gone and we
  fall back to cold resume — so there is nothing a disk log would buy. This removes all file-IO
  and log-path concerns from the fork.
- **The agent's pid becomes stable across attaches.** Today every resume mints a new pid; with a
  persistent daemon the agent keeps one pid for its whole life, which the status pipeline
  (`<account home>/sessions/<pid>.json`) can only benefit from.

## The daemon (the abduco fork)

abduco's `abduco.c` `#include`s `server.c` / `client.c` / `debug.c` inline. Today `Server` holds
only `pty_output`, a **single** `Packet` (~4 KiB) overwritten each read; a new client that
`MSG_ATTACH`es receives live output only, with redraw left to `SIGWINCH`/`Ctrl-L`. The fork adds
exactly one capability — a bounded output history and its replay:

1. **`Server` gains an in-memory ring buffer** of recent PTY output bytes (in `abduco.c`, where
   the struct is defined). Sized to match ghostty's `scrollback-limit` so replay can fill
   scrollback but never more than ghostty would keep.
2. **Capture point:** in `server_mainloop()` (in `server.c`), where it reads `server.pty` into
   `server.pty_output` and `send_packet`s to attached clients, append the same bytes to the ring.
3. **Replay-on-attach:** in `server.c`, where a `MSG_ATTACH` moves a `Client` to
   `STATE_ATTACHED`, stream the ring to *that one* client as `MSG_CONTENT` packets (chunked to
   `sizeof(pkt->u.msg)`) **before** resuming live forwarding.
4. **Trim at a safe boundary.** Trimming the ring mid-escape-sequence, or mid-alternate-screen,
   would start replay from a corrupt state. Trim only back to the most recent full-screen-clear
   /clear-scrollback boundary that keeps the ring under budget, so replay always begins from a
   point where a fresh emulator lands correctly. abduco already scans the stream for
   `alternate_buffer`; this extends that scanning. (Fidelity caveats: a resize performed while
   detached can only be reflowed at the current width on reattach — cosmetic wrapping differences
   in old scrollback, no lost content; a session ending inside a full-screen alt-screen app
   replays correctly because the enter-alt-screen sequence is in the ring.)

The socket protocol (`Packet{type,len,union}`, `MSG_CONTENT/ATTACH/DETACH/RESIZE/EXIT/PID`) is
unchanged. The fork is additive; no existing abduco behavior is removed. Binary name:
**`fd-abduco`** (distinct from any user-installed `abduco`; name is not load-bearing).

## Flight Deck integration (Swift)

**Launch decision at the two `config.command` sites** (`SessionStore.swift:1024`,
`SessionStore.swift:1923`). Instead of forking the shell directly, Flight Deck probes for a live
daemon for this session and picks one of two modes:

- **Attach** (a live daemon exists): `config.command = fd-abduco -a <sock>`. The client attaches,
  the ring replays, and the shell — with the agent running exactly mid-conversation — reappears
  in full. **Nothing is typed. No `--resume`. No "Keep going."**
- **Cold create** (no live daemon — first launch, or the daemon died): `config.command =
  fd-abduco -c <sock> -- <resolvedShell>`. This creates the daemon running the login shell, and
  Flight Deck proceeds exactly as it does today — `sendToShell(resumeCommand)` for a restore of a
  dead daemon, or the normal new-session typing for a brand-new session. This is where "Keep
  going" survives, **demoted to a fallback that fires only when a daemon is genuinely absent.**

The probe is Flight Deck's own decision (attach `-a` vs. create `-c`), not abduco's `-A`
auto-mode, so the cold-vs-attach branch — and thus whether the resume/keep-going path runs — is
explicit and unit-testable behind a `DaemonProbing` seam.

**Socket & pidfile layout.** macOS caps `sun_path` at ~104 bytes, and Application Support paths
are far too long. Sockets and pidfiles therefore live under a **short** per-uid directory (mode
`0700`), e.g. `/tmp/fd-<uid>/<shortid>.sock` / `.pid`, where `<shortid>` is derived from the
session UUID. The stateful directory (`-FlightDeckStateDir` / Application Support) is *not* used
for sockets; the daemon keeps its buffer in memory, so nothing session-durable is written there.

**Lifecycle & GC** — deliberately *not* launchd. Unlike `mail-api` (a stateless service that
*should* be respawned), a daemon holds a specific agent's live conversation; respawning it would
destroy exactly what we are preserving. So daemons are plain detached processes that Flight Deck
reaps itself:

- **Close a session** (`closeSession`): `SIGTERM` the daemon via its pidfile, tearing down the
  agent + PTY; remove socket/pidfile.
- **Reconcile on launch:** for each session in `sessions.json`, probe its socket → *attach* if
  live, *cold-create* if dead. For each live daemon with **no** matching session (a session
  removed while the app was dead), `SIGTERM` it — otherwise orphaned agents accumulate.

**Status pipeline:** unaffected in shape (`SessionStatusWatcher` scans `<account home>/sessions/`
and keys the map by the `sessionId` *inside* each file, not by the filename's pid), and strictly
improved by the now-stable agent pid.

**Agent-agnostic:** the daemon runs whatever command; both `ClaudeAdapter` and `CodexAdapter`
benefit with no adapter-specific work. `resumeCommand` remains, used only on the cold path.

## Build & bundling

Vendor the abduco fork's C sources in-tree (it is ~4 small files we are modifying, so a pristine
submodule is the wrong shape) and build `fd-abduco` via `scripts/build-fd-abduco.sh` into a
git-ignored artifact, mirroring `build-libghostty.sh` / `build-boringssl.sh`. Bundle the binary
in the app; the app resolves it by bundle path at launch. An already-running daemon is unaffected
by a later `swap-release.sh` replacing the bundle — it is a separate, already-exec'd process.
No new entitlements (the app is already non-sandboxed; sockets are per-uid in a `0700` dir).

## Testing

- **Daemon (C):** a harness creates a session, writes known output, drops the client socket
  (simulating app death), reattaches, and asserts the replayed bytes equal what was written —
  plus a trim-at-boundary case and an alt-screen case.
- **Swift, pure:** the attach-vs-cold-create decision behind `DaemonProbing`, and the launch-time
  reconcile (attach live / cold-create dead / reap orphan) as a pure function over
  `sessions.json` × probed daemons. Unit-tested with no ghostty, no sockets.
- **End-to-end:** a `TerminalSmokeTests` case — start a session, produce output, kill and relaunch
  the surface, assert the pane shows the prior scrollback and the agent is the same live process.
  This is the only layer that exercises a real ghostty surface replaying real bytes.

## Risks & edge cases

- **Memory cost:** N sessions × ring size (tuned to scrollback-limit, a few MB each). Bounded and
  modest; document the knob.
- **Reflow fidelity across a detached resize:** cosmetic only (see fork §4).
- **Path length:** addressed by the short socket dir above; a regression here fails at bind time,
  so it is caught immediately, not silently.
- **Orphan reaping is the one way to leak agents;** it is a first-class launch step, not a
  cleanup afterthought.
- **A daemon whose agent has exited** (normal `claude` quit) closes its PTY → `MSG_EXIT`; the
  client sees the session end exactly as an in-process child exit does today.

## Phasing

1. **Fork + daemon:** `fd-abduco` with the ring buffer and replay-on-attach; C-level tests;
   build script + bundling.
2. **Swift integration:** the launch decision, socket/pidfile layout, close-time teardown,
   launch-time reconcile, `DaemonProbing` seam; demote "Keep going" to the cold-path fallback.
3. **End-to-end smoke test** and the memory/scrollback knob.

## Non-goals (for now)

- **Surviving a Mac reboot / logout.** That needs launchd-managed persistence and the agents
  surviving a reboot at all (login state, network) — a separate, larger effort. The cold-resume
  path (with "Keep going") remains the behavior after a reboot.
- **Respawn semantics.** A dead daemon is not restarted; it falls back to cold resume. Persistence,
  not resurrection.
- Keeping the app alive headless as *the* mechanism (ruled out — must survive `SIGKILL`); it may
  still be added later as an independent nicety.
