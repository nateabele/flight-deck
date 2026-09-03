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
