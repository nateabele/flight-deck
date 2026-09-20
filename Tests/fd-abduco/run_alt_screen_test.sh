#!/usr/bin/env bash
# Tests/fd-abduco/run_alt_screen_test.sh — pins the Flight Deck fork's most
# user-visible behavioral delta: an attaching client must NOT switch the
# terminal to the alternate screen buffer.
#
# Why this matters (see vendor/fd-abduco/client.c's comment in
# client_setup_terminal for the full story): upstream abduco enters the
# alternate buffer on attach so a later detach restores the user's prior
# screen. Inside Flight Deck the attach client owns its ghostty surface for the
# tab's whole life, so that switch is never undone, and the tab lives on the
# alternate screen forever. That costs the session its scrollback outright, and
# — because ghostty converts wheel events to cursor keys on the alternate
# screen (DEC private mode 1007, default ON) — turned every two-finger scroll
# into Up/Down, which Claude Code's composer reads as prompt-history recall.
# Shipped symptom, 2026-09-20: "scrolling scrolls my prompt history".
#
# The second half of this test is the part that keeps the first half honest:
# with FD_ABDUCO_ALT_SCREEN=1 the old behavior must come BACK. Without it, a
# capture that silently recorded nothing — or a client that wrote no escapes at
# all — would leave assertion #1 passing for the wrong reason. (It did, while
# this test was being written: an earlier revision killed script(1) before it
# flushed its typescript, so both files were empty and only assertion #2
# noticed.)
set -euo pipefail
cd "$(dirname "$0")/../.."
./scripts/build-fd-abduco.sh
BIN=vendor/fd-abduco-artifacts/fd-abduco
ALT_ON=$'\033\\[?1049h'

SOCKS=()
cleanup() {
	local s
	for s in ${SOCKS+"${SOCKS[@]}"}; do
		if [ -f "$s.pid" ]; then kill -9 "$(cat "$s.pid")" 2>/dev/null || true; fi
	done
	rm -f /tmp/fd_alt_default.txt /tmp/fd_alt_optin.txt
}
trap cleanup EXIT

# Attaches to a FRESH session under a real pty and returns once the capture
# file is complete.
#
# `script -q FILE CMD` supplies the pty the client needs (it calls tcsetattr on
# stdin and only emits escapes when attached to a terminal). The client is
# ended by killing its SESSION rather than killing script(1): the client then
# exits of its own accord and script flushes the typescript. Killing script
# directly truncates the file to nothing, which is the false-pass this test's
# second assertion exists to catch.
capture_attach() { # $1=outfile
	local sock
	sock=$(mktemp -u /tmp/fdalt.XXXXXX).sock
	SOCKS+=("$sock")
	"$BIN" -n "$sock" sh -c 'printf "plain session, no full-screen app\n"; sleep 30'
	sleep 0.6
	test -S "$sock"

	script -q "$1" "$BIN" -r -a "$sock" >/dev/null 2>&1 &
	local spid=$!
	sleep 1.2
	kill -9 "$(cat "$sock.pid")" 2>/dev/null || true
	wait "$spid" 2>/dev/null || true
	# A capture that recorded nothing cannot prove anything either way.
	test -s "$1" || { echo "FAIL: capture $1 is empty" >&2; exit 1; }
}

# 1. Default: attaching must leave the terminal on the PRIMARY screen.
unset FD_ABDUCO_ALT_SCREEN
capture_attach /tmp/fd_alt_default.txt
if LC_ALL=C grep -q "$ALT_ON" /tmp/fd_alt_default.txt; then
	echo "FAIL: attach switched to the alternate screen (found ESC[?1049h)" >&2
	exit 1
fi

# 2. Opt-in restores upstream behavior — proves assertion #1 can actually fail.
# `export`, not a `VAR=x capture_attach` prefix: a prefix assignment on a shell
# FUNCTION is not exported to that function's own child processes, so the
# client would never see it.
export FD_ABDUCO_ALT_SCREEN=1
capture_attach /tmp/fd_alt_optin.txt
unset FD_ABDUCO_ALT_SCREEN
if ! LC_ALL=C grep -q "$ALT_ON" /tmp/fd_alt_optin.txt; then
	echo "FAIL: FD_ABDUCO_ALT_SCREEN=1 did not restore the alternate screen" >&2
	exit 1
fi

echo "alt-screen OK"
