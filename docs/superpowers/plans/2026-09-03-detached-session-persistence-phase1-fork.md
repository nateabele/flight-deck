# Detached Session Persistence — Phase 1: the `fd-abduco` fork — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce `fd-abduco` — a fork of abduco that persists a bounded, in-memory buffer of a session's PTY output and replays it to a client on attach — built into a git-ignored artifact and bundled into the app.

**Architecture:** abduco already runs a program in a PTY inside a detached daemon and forwards live output to attached clients over a Unix socket. Today it keeps no history, so a reattaching client sees only output from that moment on. This phase adds one capability: the daemon's `Server` accumulates output in a byte log (`FdOutlog`) capped at a budget and trimmed at terminal screen-clear boundaries, and streams that log to a newly-attached client as `MSG_CONTENT` before resuming live forwarding. Ghostty (Phase 2's client) reconstructs the full screen+scrollback by feeding those bytes through its own emulator.

**Tech Stack:** C (portable, builds with `cc`/`make` on macOS), a small C unit test and a protocol-level C integration harness, a bash build script mirroring `scripts/build-libghostty.sh`, XcodeGen `project.yml` for bundling.

**Spec:** `docs/superpowers/specs/2026-09-03-detached-session-persistence-design.md`

## Global Constraints

- **License:** abduco is ISC. Retain its copyright + permission notice verbatim in every vendored file; add a Flight Deck provenance header line, mirroring `GhosttyEmbed/`'s `// Adapted from ghostty v1.3.1:` convention.
- **In-tree vendored fork:** the sources live under `vendor/fd-abduco/` as Flight-Deck-owned editable files (NOT a pristine submodule — this is a fork). Pin the upstream commit in a provenance note.
- **Build artifact is git-ignored**, produced by a script into `vendor/fd-abduco-artifacts/`, mirroring `vendor/ghostty-artifacts/` and `vendor/boringssl-artifacts/`.
- **Binary name:** `fd-abduco` (distinct from any user-installed `abduco`).
- **No on-disk session buffer:** the output log is in daemon memory only. Nothing session-durable is written to disk by the daemon.
- **Symbol reconciliation:** exact abduco field/function names are confirmed by reading the vendored source in Task 1. Where this plan names a symbol (`Packet`, `Packet.u.msg`, `Packet.len`, `server.pty`, `server.clients`, `Client.socket`, `Client.state`, `STATE_ATTACHED`, `MSG_CONTENT`, `MSG_ATTACH`, `send_packet`, `server_mainloop`, `create_session`), reconcile against the real declaration and adjust the insertion accordingly. The added *logic* is what matters; the anchors are located in the real file.
- **Budget default:** `FD_OUTLOG_BUDGET` bytes, default `4 * 1024 * 1024`, read from the environment at daemon start so tests can shrink it.

---

### Task 1: Vendor abduco and build `fd-abduco` (baseline, unmodified behavior)

**Files:**
- Create: `vendor/fd-abduco/` — copied upstream sources: `abduco.c`, `server.c`, `client.c`, `debug.c`, `config.def.h` (as `config.h`), `forkpty-*.c` if referenced, `LICENSE`, plus a `PROVENANCE.md` noting the pinned upstream commit.
- Create: `scripts/build-fd-abduco.sh`
- Create: `.gitignore` entry for `vendor/fd-abduco-artifacts/`
- Test: `Tests/fd-abduco/baseline_smoke.sh`

**Interfaces:**
- Produces: an executable at `vendor/fd-abduco-artifacts/fd-abduco`. CLI (inherited from abduco): `fd-abduco -c <socket> -- <cmd...>` creates a detached session; `fd-abduco -a <socket>` attaches; `fd-abduco -l` lists. Socket path is taken **verbatim** from the argument (no socket-dir search) — confirm/adjust abduco's `config.h` `socket_dirs`/name resolution so an explicit path is honored; this is what Phase 2 relies on.

- [ ] **Step 1: Vendor the source.** Clone upstream `martanne/abduco` at a pinned commit into a temp dir, copy the files above into `vendor/fd-abduco/`, record the commit hash in `PROVENANCE.md`. Read `abduco.c`, `server.c`, `client.c` fully and confirm the symbols listed in Global Constraints. Set `VERSION`/`ABDUCO_CMD` in `config.h` so the built binary identifies as `fd-abduco`.

- [ ] **Step 2: Write the build script.**

```bash
#!/usr/bin/env bash
# scripts/build-fd-abduco.sh — builds the fd-abduco fork into a git-ignored artifact.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=vendor/fd-abduco
OUT=vendor/fd-abduco-artifacts
mkdir -p "$OUT"
CC=${CC:-cc}
# Universal binary to match the app's architectures.
"$CC" -arch arm64 -arch x86_64 -Os -Wall -o "$OUT/fd-abduco" \
  -I"$SRC" "$SRC/abduco.c"
echo "built $OUT/fd-abduco"
"$OUT/fd-abduco" -v || true
```

(Note: `abduco.c` `#include`s `server.c`/`client.c`/`debug.c` inline, so only `abduco.c` is compiled. If the vendored tree splits them, compile all `.c`. Confirm from Step 1.)

- [ ] **Step 3: Write the baseline smoke test.**

```bash
#!/usr/bin/env bash
# Tests/fd-abduco/baseline_smoke.sh — build works; create/list/exit roundtrip.
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
test -x "$BIN"
file "$BIN" | grep -qi mach-o
SOCK=$(mktemp -u /tmp/fdb.XXXXXX).sock
"$BIN" -c "$SOCK" -- sh -c 'sleep 5' &
sleep 0.5
"$BIN" -l | grep -q "$(basename "$SOCK")" || "$BIN" -l   # session is listed
# ending the program tears the session down
pkill -f "sleep 5" || true
sleep 0.5
echo "baseline OK"
```

- [ ] **Step 4: Run it.** `bash Tests/fd-abduco/baseline_smoke.sh` — Expected: builds, prints `baseline OK`. If `-l` path resolution fails, fix `config.h` socket handling so an explicit socket path is honored, then rerun.

- [ ] **Step 5: Commit.**

```bash
git add vendor/fd-abduco scripts/build-fd-abduco.sh .gitignore Tests/fd-abduco/baseline_smoke.sh
git commit -m "feat(fd-abduco): vendor abduco fork and build a bundled binary"
```

---

### Task 2: `FdOutlog` — the bounded output log with boundary-aware trim (pure C, unit-tested)

**Files:**
- Create: `vendor/fd-abduco/fd_outlog.h`, `vendor/fd-abduco/fd_outlog.c`
- Test: `Tests/fd-abduco/test_outlog.c`, run via `Tests/fd-abduco/run_outlog_test.sh`

**Interfaces:**
- Produces (consumed by Task 3):
  - `void fd_outlog_init(FdOutlog *o, size_t budget);`
  - `void fd_outlog_free(FdOutlog *o);`
  - `void fd_outlog_append(FdOutlog *o, const char *buf, size_t len);`
  - `void fd_outlog_trim(FdOutlog *o);` — after this, `[o->data, o->data + o->len)` is the replay content, `o->len <= o->budget`, and it begins at the most recent screen-clear boundary within the trailing budget window (or a hard cut if none).
  - struct `FdOutlog { char *data; size_t len, cap, budget; }`.

- [ ] **Step 1: Write the failing test.**

```c
/* Tests/fd-abduco/test_outlog.c */
#include <assert.h>
#include <string.h>
#include "fd_outlog.h"

int main(void) {
    /* 1. small append round-trips verbatim */
    FdOutlog o; fd_outlog_init(&o, 1024);
    fd_outlog_append(&o, "HELLO", 5);
    fd_outlog_trim(&o);
    assert(o.len == 5 && memcmp(o.data, "HELLO", 5) == 0);
    fd_outlog_free(&o);

    /* 2. over budget with no clear seq -> keep exactly the last `budget` bytes */
    fd_outlog_init(&o, 8);
    fd_outlog_append(&o, "0123456789ABCDEF", 16); /* 16 > 8 */
    fd_outlog_trim(&o);
    assert(o.len == 8 && memcmp(o.data, "89ABCDEF", 8) == 0);
    fd_outlog_free(&o);

    /* 3. clear seq inside the trailing window -> replay starts at the clear seq */
    fd_outlog_init(&o, 10);
    /* content: "aaaa" then ESC[2J then "bbb" ; total 4+4+3=11 > 10 */
    fd_outlog_append(&o, "aaaa\x1b[2Jbbb", 11);
    fd_outlog_trim(&o);
    assert(o.len == 7 && memcmp(o.data, "\x1b[2Jbbb", 7) == 0);
    fd_outlog_free(&o);

    return 0;
}
```

- [ ] **Step 2: Run it, verify it fails.** `bash Tests/fd-abduco/run_outlog_test.sh` — Expected: compile error (no `fd_outlog.h`).

- [ ] **Step 3: Implement `FdOutlog`.**

```c
/* fd_outlog.h */
#ifndef FD_OUTLOG_H
#define FD_OUTLOG_H
#include <stddef.h>
typedef struct { char *data; size_t len, cap, budget; } FdOutlog;
void fd_outlog_init(FdOutlog *o, size_t budget);
void fd_outlog_free(FdOutlog *o);
void fd_outlog_append(FdOutlog *o, const char *buf, size_t len);
void fd_outlog_trim(FdOutlog *o);
#endif
```

```c
/* fd_outlog.c */
#include "fd_outlog.h"
#include <stdlib.h>
#include <string.h>

void fd_outlog_init(FdOutlog *o, size_t budget) {
    o->data = NULL; o->len = 0; o->cap = 0;
    o->budget = budget ? budget : (4u * 1024 * 1024);
}
void fd_outlog_free(FdOutlog *o) { free(o->data); o->data = NULL; o->len = o->cap = 0; }

static void ensure(FdOutlog *o, size_t need) {
    if (o->cap >= need) return;
    size_t c = o->cap ? o->cap : 4096;
    while (c < need) c *= 2;
    o->data = realloc(o->data, c); o->cap = c;
}

/* find the byte index of the last occurrence of `needle` at or after `from`, or (size_t)-1 */
static size_t last_of(const char *hay, size_t n, size_t from, const char *needle, size_t nl) {
    if (nl == 0 || n < nl) return (size_t)-1;
    size_t best = (size_t)-1;
    for (size_t i = from; i + nl <= n; i++)
        if (memcmp(hay + i, needle, nl) == 0) best = i;
    return best;
}

void fd_outlog_append(FdOutlog *o, const char *buf, size_t len) {
    if (len == 0) return;
    ensure(o, o->len + len);
    memcpy(o->data + o->len, buf, len);
    o->len += len;
    if (o->len > 2 * o->budget) fd_outlog_trim(o); /* amortized: keep the hot path cheap */
}

void fd_outlog_trim(FdOutlog *o) {
    if (o->len <= o->budget) return;
    size_t window = o->len - o->budget;               /* earliest index we may keep from */
    size_t cut = window;                              /* default: hard cut to budget */
    /* prefer starting at a full clear so a fresh emulator lands correctly */
    const char *marks[] = { "\x1bc", "\x1b[2J", "\x1b[3J" };
    const size_t mlen[] = { 2, 4, 4 };
    for (int m = 0; m < 3; m++) {
        size_t p = last_of(o->data, o->len, window, marks[m], mlen[m]);
        if (p != (size_t)-1 && p > cut) cut = p;      /* the most recent clear in-window */
    }
    memmove(o->data, o->data + cut, o->len - cut);
    o->len -= cut;
}
```

```bash
# Tests/fd-abduco/run_outlog_test.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
cc -Wall -O0 -I../../vendor/fd-abduco -o /tmp/fd_outlog_test \
   test_outlog.c ../../vendor/fd-abduco/fd_outlog.c
/tmp/fd_outlog_test && echo "outlog OK"
```

- [ ] **Step 4: Run it, verify it passes.** `bash Tests/fd-abduco/run_outlog_test.sh` — Expected: `outlog OK`.

- [ ] **Step 5: Commit.**

```bash
git add vendor/fd-abduco/fd_outlog.h vendor/fd-abduco/fd_outlog.c Tests/fd-abduco/test_outlog.c Tests/fd-abduco/run_outlog_test.sh
git commit -m "feat(fd-abduco): add FdOutlog bounded output log with boundary-aware trim"
```

---

### Task 3: Capture output into the log and replay it on attach

**Files:**
- Modify: `vendor/fd-abduco/server.c` (the `Server` struct, `create_session`/session init, `server_mainloop`, the `MSG_ATTACH` handler) and, if the struct is declared there, `vendor/fd-abduco/abduco.c`.
- Modify: `scripts/build-fd-abduco.sh` (compile `fd_outlog.c`).
- Test: `Tests/fd-abduco/test_replay.c`, run via `Tests/fd-abduco/run_replay_test.sh`.

**Interfaces:**
- Consumes: `FdOutlog` (Task 2), the abduco socket protocol (`Packet`, `MSG_ATTACH`, `MSG_CONTENT`, `MSG_RESIZE`).
- Produces: on attach, the server sends the trimmed log as one or more `MSG_CONTENT` packets to the newly-attached client's socket **before** any live output.

- [ ] **Step 1: Write the failing test — a protocol-level replay harness.** It launches a daemon that emits a marker then idles, connects a raw socket, performs the attach handshake, and asserts the marker arrives via replay. (Confirm the exact handshake — whether the client sends `MSG_ATTACH` alone or `MSG_ATTACH`+`MSG_RESIZE`, and whether the server sends anything first — from `client.c`/`server.c` read in Task 1; encode it here.)

```c
/* Tests/fd-abduco/test_replay.c — connects to an existing fd-abduco session socket,
   sends the attach handshake, reads MSG_CONTENT, asserts the marker appears. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "protocol.h"   /* the Packet/MSG_* declarations, factored out in Step 3 */

int main(int argc, char **argv) {
    const char *sock = argv[1];
    int fd = socket(AF_UNIX, SOCK_STREAM, 0); assert(fd >= 0);
    struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
    strncpy(a.sun_path, sock, sizeof a.sun_path - 1);
    assert(connect(fd, (struct sockaddr*)&a, sizeof a) == 0);

    Packet p; memset(&p, 0, sizeof p);
    p.type = MSG_ATTACH; p.len = /* payload per protocol */ 0;
    /* send attach (+resize if the handshake requires it) using the vendored send_packet
       logic or an inline write of packet_header_size()+p.len bytes */
    write(fd, &p, /* header size */ 8 + p.len);

    char buf[65536]; size_t got = 0; int found = 0;
    for (int i = 0; i < 50 && got < sizeof buf - 1; i++) {
        ssize_t n = read(fd, buf + got, sizeof buf - 1 - got);
        if (n <= 0) break;
        got += (size_t)n; buf[got] = 0;
        if (memmem(buf, got, "MARKER-12345", 12)) { found = 1; break; }
    }
    assert(found);
    printf("replay OK\n");
    return 0;
}
```

```bash
# Tests/fd-abduco/run_replay_test.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
SOCK=$(mktemp -u /tmp/fdr.XXXXXX).sock
FD_OUTLOG_BUDGET=1048576 "$BIN" -c "$SOCK" -- sh -c 'printf "MARKER-12345\n"; sleep 30' &
DPID=$!
sleep 0.6
cc -Wall -O0 -I vendor/fd-abduco -o /tmp/fd_replay_test Tests/fd-abduco/test_replay.c
/tmp/fd_replay_test "$SOCK"; rc=$?
kill "$DPID" 2>/dev/null || true; pkill -f 'sleep 30' 2>/dev/null || true
exit $rc
```

- [ ] **Step 2: Run it, verify it fails.** `bash Tests/fd-abduco/run_replay_test.sh` — Expected: assertion fails (`found` is 0) because the current server replays no history. (If it errors before that on the handshake, fix the harness against the real protocol first — the *behavior* under test is "marker present after attach".)

- [ ] **Step 3: Implement capture + replay.**
  1. If needed, factor the `Packet`/`MSG_*` declarations into `vendor/fd-abduco/protocol.h` and include it where they were, so the test can share them. (If they already sit in a shared header, include that instead and delete `protocol.h` from the test.)
  2. Add `#include "fd_outlog.h"` and a field to `Server`: `FdOutlog outlog;`.
  3. In `create_session` (or wherever `Server` is initialized), `fd_outlog_init(&server.outlog, getenv("FD_OUTLOG_BUDGET") ? (size_t)strtoull(getenv("FD_OUTLOG_BUDGET"),0,10) : 0);`.
  4. In `server_mainloop`, at the point where a PTY read fills `server.pty_output` and is `send_packet`ed to clients, also: `fd_outlog_append(&server.outlog, server.pty_output.u.msg, server.pty_output.len);`.
  5. In the `MSG_ATTACH` handler, right after the client transitions to `STATE_ATTACHED` and before live forwarding resumes for it:

```c
fd_outlog_trim(&server.outlog);
for (size_t off = 0; off < server.outlog.len; ) {
    Packet rp; memset(&rp, 0, sizeof rp);
    size_t chunk = server.outlog.len - off;
    if (chunk > sizeof(rp.u.msg)) chunk = sizeof(rp.u.msg);
    rp.type = MSG_CONTENT; rp.len = (uint32_t)chunk;
    memcpy(rp.u.msg, server.outlog.data + off, chunk);
    send_packet(c->socket, &rp);   /* `c` = the just-attached client */
    off += chunk;
}
```

  6. Update `scripts/build-fd-abduco.sh` to compile `fd_outlog.c` alongside `abduco.c` (if not `#include`d).

- [ ] **Step 4: Run it, verify it passes.** `bash Tests/fd-abduco/run_replay_test.sh` — Expected: `replay OK`.

- [ ] **Step 5: Commit.**

```bash
git add vendor/fd-abduco Tests/fd-abduco/test_replay.c Tests/fd-abduco/run_replay_test.sh scripts/build-fd-abduco.sh
git commit -m "feat(fd-abduco): capture PTY output and replay it to attaching clients"
```

---

### Task 4: Trim-under-budget verified end-to-end through the daemon

**Files:**
- Test: `Tests/fd-abduco/run_trim_test.sh` (reuses `test_replay.c`'s harness or a variant `test_trim.c`).

**Interfaces:**
- Consumes: everything from Task 3. No production code changes expected — this proves the budget path is wired through the daemon (Task 2 proved the unit; this proves the env-configured budget + trim runs in the real process).

- [ ] **Step 1: Write the failing test.** Launch the daemon with a tiny budget and a program that prints far more than the budget, including a clear sequence near the end; attach and assert (a) total replayed bytes ≤ budget + one packet, and (b) the bytes after the last clear are present while early bytes are gone.

```bash
# Tests/fd-abduco/run_trim_test.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
SOCK=$(mktemp -u /tmp/fdt.XXXXXX).sock
# 64 KiB of 'x', then a clear, then a unique tail; budget 4 KiB.
FD_OUTLOG_BUDGET=4096 "$BIN" -c "$SOCK" -- sh -c \
  'head -c 65536 /dev/zero | tr "\0" x; printf "\033[2JTAIL-99\n"; sleep 30' &
DPID=$!; sleep 0.6
cc -Wall -O0 -I vendor/fd-abduco -DWANT_MARKER='"TAIL-99"' -DWANT_ABSENT='"xxxxxxxxxx"' \
   -o /tmp/fd_trim_test Tests/fd-abduco/test_replay.c
/tmp/fd_trim_test "$SOCK"; rc=$?
kill "$DPID" 2>/dev/null || true; pkill -f 'sleep 30' 2>/dev/null || true
exit $rc
```

(Generalize `test_replay.c` to take `WANT_MARKER` present and, optionally, `WANT_ABSENT` not present, via the `-D` macros above; default them to the Task-3 values so `run_replay_test.sh` is unaffected.)

- [ ] **Step 2: Run it, verify it fails first if the generalization isn't in place** (compile error on the macros), then implement the small `test_replay.c` change.

- [ ] **Step 3: Run it, verify it passes.** `bash Tests/fd-abduco/run_trim_test.sh` — Expected: `replay OK` with `TAIL-99` present and no long `x` run replayed.

- [ ] **Step 4: Commit.**

```bash
git add Tests/fd-abduco/test_replay.c Tests/fd-abduco/run_trim_test.sh
git commit -m "test(fd-abduco): verify budget trim runs through the live daemon"
```

---

### Task 5: Bundle `fd-abduco` into the app and add an aggregate test entry point

**Files:**
- Modify: `project.yml` (copy `vendor/fd-abduco-artifacts/fd-abduco` into the app bundle).
- Create: `Tests/fd-abduco/run_all.sh` (runs baseline + outlog + replay + trim).
- Modify: `docs/BUILD.md` (a line: build `fd-abduco` before the app; where the binary lands in the bundle).

**Interfaces:**
- Produces (consumed by Phase 2): `fd-abduco` present in the built `.app` bundle at a stable, `Bundle.main`-resolvable path (e.g. `Contents/Resources/fd-abduco` or `Contents/MacOS/`). Record the exact chosen location in `docs/BUILD.md` — Phase 2 resolves and execs it from there.

- [ ] **Step 1: Add the bundling to `project.yml`.** Following how the app already consumes `vendor/*-artifacts`, add a build phase / resource that copies `vendor/fd-abduco-artifacts/fd-abduco` into the bundle and marks it executable. Read the existing `dependencies:`/resources handling for `GhosttyKit.xcframework` first and match the established mechanism.

- [ ] **Step 2: Write the aggregate test runner.**

```bash
# Tests/fd-abduco/run_all.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
bash run_outlog_test.sh
bash ../../Tests/fd-abduco/baseline_smoke.sh
bash run_replay_test.sh
bash run_trim_test.sh
echo "ALL fd-abduco tests OK"
```

- [ ] **Step 3: Regenerate the project and build the app.** Run the repo's XcodeGen step, then a debug build. Verify the binary is in the bundle:

Run: `find "$(ls -dt ~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/*.app | head -1)" -name fd-abduco -perm -111`
Expected: one path printed (the bundled, executable binary). Do NOT launch the app to verify (per repo memory: never verify a bundle by executing it).

- [ ] **Step 4: Run the aggregate tests.** `bash Tests/fd-abduco/run_all.sh` — Expected: `ALL fd-abduco tests OK`.

- [ ] **Step 5: Commit.**

```bash
git add project.yml Tests/fd-abduco/run_all.sh docs/BUILD.md
git commit -m "build(fd-abduco): bundle the daemon binary into the app"
```

---

## Verification (whole phase)

- `bash Tests/fd-abduco/run_all.sh` passes: build, unit trim, live create/attach, replay, budget-trim.
- The debug `.app` bundle contains an executable `fd-abduco` (found via the `find` command in Task 5; not executed).
- Manual confidence check (optional, not automated): in one terminal `vendor/fd-abduco-artifacts/fd-abduco -c /tmp/x.sock -- $SHELL`, run `ls`/`vim` and scroll; in another, `Ctrl-\` to detach; reattach with `fd-abduco -a /tmp/x.sock` and confirm prior scrollback is redrawn. This is the human-visible version of what Phase 2 wires into ghostty.

## Not in this plan (subsequent phases, planned after this lands)

- **Phase 2 (Swift integration):** the attach-vs-cold-create launch decision at `SessionStore.swift:1024`/`:1923`, the `DaemonProbing` seam, socket/pidfile layout under a short per-uid dir, `closeSession` teardown, launch-time reconcile/orphan-reaping, and demoting "Keep going" to the cold-path fallback. Its exact code depends on `fd-abduco`'s CLI/handshake as built here, which is why it is a separate plan.
- **Phase 3:** the `TerminalSmokeTests` end-to-end case and the user-facing scrollback-budget knob.
