#!/bin/bash
# Flight Deck's routing shim (spec §8). A session's shim directory, at the front
# of its PATH, holds one symlink to this script per command a [[route]] names;
# the symlink's name is the command. The script decides nothing itself: it hands
# the argv to `flightdeck route-exec`, which matches it against delegate.toml and
# either delegates it or execs the real binary.
#
# The contract with the CLI (C6 implements the other half):
#
#   flightdeck route-exec <argv0> -- <args…>
#
# with <argv0> the bare command name and PATH already stripped of this shim
# directory. The CLI's fall-through is therefore a plain execvp(argv0) on the
# PATH it inherited; it never needs to know where the shims live.
#
# Stripping PATH here, rather than in the CLI, is what makes a fall-through
# unable to loop: an exec that found the shim again would re-enter route-exec
# forever. A side effect, deliberate: a routed command's own children see the
# stripped PATH, so a command that is already running locally (or remotely)
# never routes a nested call out from under itself.
#
# FLIGHTDECK_NO_ROUTE=1 (any value but empty or 0) bypasses routing, and so does
# a missing `flightdeck` — a shim must never make a command unrunnable.

name=${0##*/}
case $0 in
    */*) shim_dir=${0%/*} ;;
    *) shim_dir= ;;
esac

if [ "$name" = "flightdeck-route-shim.sh" ]; then
    echo "flightdeck: the route shim runs through a symlink named for the command it routes" >&2
    exit 125
fi

# PATH without this directory. Entries are compared as written: Flight Deck puts
# the shim directory on PATH itself, and an exec found through it hands the shell
# exactly that entry plus the name as $0. Empty entries (meaning the current
# directory) are kept as they were.
stripped=
separator=
rest=$PATH:
while [ -n "$rest" ]; do
    entry=${rest%%:*}
    rest=${rest#*:}
    if [ -z "$shim_dir" ] || { [ "$entry" != "$shim_dir" ] && [ "$entry" != "$shim_dir/" ]; }; then
        stripped=$stripped$separator$entry
        separator=:
    fi
done
PATH=$stripped
export PATH

case ${FLIGHTDECK_NO_ROUTE:-} in
    "" | 0) ;;
    *) exec "$name" "$@" ;;
esac

command -v flightdeck >/dev/null 2>&1 || exec "$name" "$@"
exec flightdeck route-exec "$name" -- "$@"
