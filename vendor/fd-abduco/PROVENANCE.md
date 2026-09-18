# Provenance: `fd-abduco`

`fd-abduco` is a Flight Deck fork of [abduco](https://github.com/martanne/abduco),
Marc André Tanner's terminal session manager. It is vendored in-tree as editable
source (not a git submodule) so it can grow an output-replay buffer for detached
Flight Deck sessions (see the phase-1 spec/plan under
`docs/superpowers/specs/2026-09-03-detached-session-persistence-design.md` and
`docs/superpowers/plans/2026-09-03-detached-session-persistence-phase1-fork.md`).

## Pinned upstream commit

- Repository: `https://github.com/martanne/abduco`
- Tag: `v0.6`
- Commit: `e76729a2df45ecabe72a423e925ed876f66235d6`

The `v0.6` tag was used (not `master`) because it builds cleanly on macOS once
given the same compiler flags as upstream's own `Makefile`
(`-std=c99 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 -D_DARWIN_C_SOURCE`);
there was no need to fall back to a newer commit.

## Files copied

| Vendored file       | Upstream source     | Notes |
|----------------------|----------------------|-------|
| `abduco.c`            | `abduco.c`           | Unmodified body; Flight Deck provenance header prepended, ISC notice retained verbatim. |
| `client.c`            | `client.c`           | Same. Inlined into `abduco.c` via `#include "client.c"` — not compiled separately. |
| `server.c`            | `server.c`           | Same. Inlined into `abduco.c` via `#include "server.c"` — not compiled separately. |
| `debug.c`             | `debug.c`             | Same. Inlined into `abduco.c` via `#include "debug.c"` — not compiled separately. |
| `config.h`            | `config.def.h`        | Renamed per Task 1 brief. `VERSION` and `ABDUCO_CMD` edited to identify this fork (see below); `socket_dirs` table left as upstream default (unused for explicit paths — see below). |
| `forkpty-aix.c`       | `forkpty-aix.c`       | Copied for source fidelity; not built by `scripts/build-fd-abduco.sh` (AIX-only, guarded by `#if defined(_AIX)` in `abduco.c`). |
| `forkpty-sunos.c`     | `forkpty-sunos.c`     | Copied for source fidelity; not built (Solaris-only, guarded by `#elif defined(__sun)`). |
| `LICENSE`             | `LICENSE`             | Verbatim. |

Not vendored: upstream's `Makefile`, `configure`, `abduco.1`, `README.md`,
`testsuite.sh`, `contrib/` — Flight Deck has its own build script
(`scripts/build-fd-abduco.sh`) and test harness (`Tests/fd-abduco/`).

## `abduco.c` inlines the rest of the translation unit

`abduco.c` does `#include "debug.c"`, `#include "client.c"`, `#include "server.c"`
directly (confirmed by reading the source), so the whole program is one
translation unit. `scripts/build-fd-abduco.sh` therefore compiles only
`abduco.c` — compiling `client.c`/`server.c`/`debug.c` separately would
double-define every symbol in them.

## Compiler flags needed beyond a bare `cc abduco.c`

Verified empirically on this macOS host:

- `-D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700` are required (upstream's
  `Makefile` always passes them) but on their own are *too* strict on macOS:
  building with only those two defined fails with `use of undeclared identifier
  'SIGWINCH'` / `'VLNEXT'`.
- `-D_DARWIN_C_SOURCE` is additionally required on macOS to re-expose
  `SIGWINCH`/`VLNEXT` (and other BSD/Darwin extensions) under those POSIX/XOPEN
  strict-conformance defines. This matches Task 1 decision #3.
- `VERSION` is **not** defined in `config.h`/`config.def.h` upstream — it's
  injected by upstream's `Makefile` as `-DVERSION=\"0.6\"`. Since Flight Deck
  doesn't use that Makefile, `VERSION` is instead `#define`d directly in the
  vendored `config.h` (`"fd-abduco-0.6"`), so the binary self-identifies via
  `fd-abduco -v` without needing an extra build-script define.
- `-DNDEBUG` is required to get upstream's quiet/production behavior; without
  it, `debug.c`'s `debug()`/`print_packet()` are compiled to real functions
  that spam every packet exchange to stderr (this is upstream's own guard,
  see `debug.c`'s `#ifdef NDEBUG`).
- `-lutil` is required to link `forkpty`/`openpty` on macOS.

## Explicit socket path: confirmed to already work verbatim (decision #2)

Read `set_socket_name()` in `abduco.c` in full. It has three branches keyed on
the session-name argument:

1. `name[0] == '/'` (absolute path) → `sockaddr->sun_path` is set to `name`
   **verbatim**, via `strncpy`. No `socket_dirs` lookup, no hostname suffix.
2. `name[0] == '.'` followed by `.` or `/` (relative path with a leading
   `./` or `../`) → resolved against `getcwd()` and used as-is (also bypasses
   `socket_dirs`).
3. Anything else (a bare session name) → resolved via `create_socket_dir()`
   against the `socket_dirs` table in `config.h`, with the hostname appended.

This is upstream's existing, unmodified behavior — also documented in
`abduco.1`: *"However if a given session name represents either a relative or
absolute path it is used unmodified."* **No code change was needed** to honor
an explicit `-c /absolute/path.sock -- cmd` verbatim; `config.h`'s
`socket_dirs` table is simply never consulted for such an argument. Confirmed
empirically: creating a session with `fd-abduco -n /tmp/abdtest3.XXXXXX.sock
sh -c 'sleep 5'` produces a socket at that exact path, and `fd-abduco -l`
(which only scans `socket_dirs`) does **not** list it — proving the explicit
path bypasses `socket_dirs` entirely, as Phase 2 requires.

## CLI note: no `--` separator

Unlike `getopt`-based tools that support a `--` end-of-options marker, abduco's
own argument grammar (confirmed in `abduco.c`'s `main()`) is
`abduco [-a|-A|-c|-n] [-r] [-l] [-f] [-e detachkey] name command [args...]` —
after `getopt()` consumes the flags, the *first* remaining positional argument
is the session name and everything after that is the command argv, taken
literally. Passing a literal `--` (as in `fd-abduco -c sock -- sh -c '...'`)
makes `--` itself `argv[0]` of the command, which fails with
`server-execvp: --: No such file or directory`. `Tests/fd-abduco/baseline_smoke.sh`
in this tree invokes it correctly as `fd-abduco -n "$SOCK" sh -c '...'` (no `--`).

## `-c` vs `-n`

`-c` creates **and immediately attaches** to a session in the foreground
(blocking, driving the terminal); `-n` creates a session **without** attaching
— the server daemonizes via the standard double-fork and detaches
immediately, which is the "detached session" behavior Flight Deck needs. The
baseline smoke test uses `-n`.

## Fork-delta log

### 2026-09-18: DEC private mode tracking + reattach preamble (`fd_outlog.c`/`.h`, `server.c`)

Extends the `FdOutlog` per-byte CSI scanner (added earlier to drop
terminal-capability *query* sequences on reattach) to also track the
last-seen set/reset state of every DEC private mode (`CSI ? Pm h` /
`CSI ? Pm l`, including multi-param forms like `CSI ?1000;1006h`) it sees
flow through the pty stream — mouse tracking, alternate-scroll, alt-screen,
bracketed paste, cursor keys, whichever ones a given program happens to set,
generically, at no extra parsing cost beyond the grammar the scanner already
walks for the query-drop logic. Unlike the query-drop path, these bytes are
**not** dropped — a mode set/reset is real program behavior, not a stale
query — they're classified in `csi_is_private_mode()`/tracked in
`track_private_modes()` on the way through, into a small growable
`FdOutlogMode` table on `FdOutlog` (`fd_outlog.c`/`.h`).

Motivation: `FdOutlog.data` is a *bounded* ring (default 4 MiB, configurable).
A program's one-time "enable mouse tracking" escape sequence, sent once at
startup, ages out of that ring in any long-running session, so a rebuilt
terminal surface reattaching later never re-learns the mode was on — this is
exactly the "two-finger scroll turns into arrow keys after sleep/wake" bug
the mode table fixes. `fd_outlog_preamble_size()`/`fd_outlog_preamble()`
synthesize a preamble that unconditionally re-asserts every tracked mode's
*current* value; `server.c`'s `MSG_RESIZE` first-attach block
(`server_send_content()`) sends it as its own `MSG_CONTENT` packet
immediately before the existing history replay. This is idempotent: if a
mode's own set/reset bytes are still inside the replay window, the preamble
duplicates them harmlessly; once they've aged out, the preamble is what
restores the mode.

Scope is deliberately narrow, per the reported bug: only *private*
(`CSI ? ... h/l`) modes are tracked — non-private ANSI modes (`CSI Pm h/l`,
no `?`) aren't implicated and go untouched. DECRQM (`CSI ? Pm $p`, a mode
*query*, not a set/reset) is unaffected — it already flows through the
scanner unclassified, same as before this change.

Known limitation: `CSI ? Pm s` (XTSAVE) / `CSI ? Pm r` (XTRESTORE) — saving
and later restoring a private mode's state via those sequences, rather than
setting/resetting it directly with `h`/`l` — aren't recognized by
`csi_is_private_mode()`, so a program that relies on them can desync the
tracked table from the terminal's real state. This is believed rare in
practice: mode 1049 (the alt-screen mode, by far the dominant real-world
case this tracker exists to fix) is set/reset with `h`/`l` directly, not
saved/restored. Documented as a known limitation rather than fixed now.

Test coverage: `Tests/fd-abduco/test_outlog_modes.c` (unit-level: a mode set
sequence pushed out of the trim budget by filler bytes, a set-then-reset,
and a multi-param sequence, plus DECRQM/non-private-mode/no-modes-seen
negative cases) and `Tests/fd-abduco/run_mode_preamble_test.sh`
(protocol-level: a live session sets mode 1000 and prints a marker, both get
trimmed by a small budget, and a client attaching afterward still receives
the mode via the preamble even though neither the original bytes nor the
marker are present in history anymore).

**Follow-up fix (same day):** `track_private_modes()`'s digit accumulation
(`val = val * 10 + digit`) had no bound beyond `FD_OUTLOG_PEND_CAP` (32 bytes
for the whole escape sequence), so a private-mode parameter with ~10+ digits
signed-integer-overflowed a 32-bit `int` (confirmed with
`-fsanitize=undefined` on input `\x1b[?3217300869h`). Fixed by capping
accumulation at `FD_OUTLOG_MODE_MAX` (999999 — no real DEC private mode is
anywhere near that large): once a parameter's running value exceeds it,
further digits are still consumed (to stay in sync with the rest of the
sequence) but no longer folded into `val`, so `val` can never exceed
`FD_OUTLOG_MODE_MAX * 10 + 9`, nowhere near overflow, regardless of how many
digits follow; such an oversized parameter is dropped rather than tracked
(it's adversarial/corrupted input, not a real mode number). Covered by a new
case 9 in `test_outlog_modes.c` using the reviewer's exact reproducer.

**Second follow-up fix (final review):** the `FdOutlogMode` table itself had
no cap, unlike the byte ring — the reviewer measured ~200,000 distinct mode
numbers (reachable in ~1.8 MiB of crafted pty input, well within a session's
normal output budget) building a 2 MiB table, a 5.2s CPU parse, and a
~1.9 MiB preamble resent on *every* reattach. Fixed by capping the table at
`FD_OUTLOG_MODE_CAP` (256 — far above any real program's distinct-mode
count) in `track_mode()`: existing entries still update in place past the
cap (a session using fewer than 256 distinct modes is unaffected), only
*new* mode numbers beyond it are dropped. Covered by a new case 10 in
`test_outlog_modes.c`. Separately, `FD_OUTLOG_MODE_MAX`'s bound-before-multiply
check in `track_private_modes()` was tightened from `val <= FD_OUTLOG_MODE_MAX`
to `val < FD_OUTLOG_MODE_MAX / 10`, closing an off-by-one that let a 7-digit
value (up to 9,999,999) through before tripping — cosmetic (structurally safe
either way) but now the cutoff actually matches the documented ~999999
ceiling. And `server_send_content()`'s chunking loop now bails out on the
first failed `server_send_packet()` instead of continuing to write to a
now-dead socket; the pre-existing history-replay loop right below it (which
open-coded the identical chunking logic, with the identical gap) now just
calls `server_send_content()` instead of duplicating it.
