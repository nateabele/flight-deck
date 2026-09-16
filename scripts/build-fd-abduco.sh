#!/usr/bin/env bash
# scripts/build-fd-abduco.sh — builds the fd-abduco fork into a git-ignored artifact.
#
# `abduco.c` #includes `debug.c`, `client.c`, `server.c` inline (confirmed by
# reading vendor/fd-abduco/abduco.c), so it is a single translation unit and
# only abduco.c is compiled from that group. `fd_outlog.c` (Task 2) is NOT
# `#include`d anywhere -- it is a separate translation unit and must be
# compiled and linked alongside abduco.c explicitly.
#
# Flags beyond a bare `cc abduco.c` (see vendor/fd-abduco/PROVENANCE.md for
# why each is needed):
#   -std=c99 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700  upstream's own
#       Makefile always passes these.
#   -D_DARWIN_C_SOURCE   required in addition to the above on macOS, or
#       SIGWINCH/VLNEXT are undeclared under strict POSIX/XOPEN conformance.
#   -DNDEBUG             upstream's own guard for quiet/production behavior;
#       without it, every packet exchange is logged to stderr.
#   -lutil               forkpty()/openpty() live in libutil on macOS.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=vendor/fd-abduco
OUT=vendor/fd-abduco-artifacts
mkdir -p "$OUT"
CC=${CC:-cc}
# Universal binary to match the app's architectures.
"$CC" -arch arm64 -arch x86_64 -Os -Wall -o "$OUT/fd-abduco" \
  -std=c99 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 -D_DARWIN_C_SOURCE -DNDEBUG \
  -I"$SRC" "$SRC/abduco.c" "$SRC/fd_outlog.c" -lutil
echo "built $OUT/fd-abduco"
"$OUT/fd-abduco" -v || true
