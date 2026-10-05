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
# PATH it inherited; it never needs to know where the shims live. A bare
# `flightdeck route-exec` (no operands) must exit 2 with a usage message and
# touch nothing: the probe below relies on it.
#
# Stripping PATH here, rather than in the CLI, is what makes a fall-through
# unable to loop: an exec that found the shim again would re-enter route-exec
# forever. A side effect, deliberate: a routed command's own children see the
# stripped PATH, so a command that is already running locally (or remotely)
# never routes a nested call out from under itself. FLIGHTDECK_ROUTE_DEPTH is
# the same guard for a child that rebuilds PATH from a profile.
#
# Every failure here runs the real command. A shim must never make a command
# unrunnable: FLIGHTDECK_NO_ROUTE=1 (any value but empty or 0), no CLI, a CLI on
# PATH that is too old, crashes or hangs on the probe, or re-entry all fall
# through.

name=${0##*/}
case $0 in
    */*) shim_dir=${0%/*} ;;
    *) shim_dir= ;;
esac

if [ "$name" = "flightdeck-route-shim.sh" ]; then
    echo "flightdeck: the route shim runs through a symlink named for the command it routes" >&2
    exit 125
fi

# PATH without this directory. `-ef` compares the directories themselves, so an
# entry spelled differently (a trailing slash, `/var` for `/private/var`, a
# symlinked parent) is still recognised. Empty entries (meaning the current
# directory) are kept as they were.
stripped=
separator=
rest=$PATH:
while [ -n "$rest" ]; do
    entry=${rest%%:*}
    rest=${rest#*:}
    if [ -z "$shim_dir" ] || [ -z "$entry" ] || ! [ "$entry" -ef "$shim_dir" ]; then
        stripped=$stripped$separator$entry
        separator=:
    fi
done
PATH=$stripped
export PATH

case ${FLIGHTDECK_NO_ROUTE:-} in
    "" | 0) ;;
    *) exec -- "$name" "$@" ;;
esac
case ${FLIGHTDECK_ROUTE_DEPTH:-0} in
    0) ;;
    *) exec -- "$name" "$@" ;;
esac
FLIGHTDECK_ROUTE_DEPTH=1
export FLIGHTDECK_ROUTE_DEPTH

# Which CLI. Whatever `flightdeck` is first on PATH is often an older install
# with no route-exec, so prefer, in order: the one the app named at tab launch
# (FLIGHTDECK_CLI), the one in the same bundle as this script
# (Contents/Resources/RouteShim/ -> Contents/MacOS/flightdeck), then PATH.
# The first two are this build's own CLI and cannot predate route-exec, so only
# a CLI found on PATH is probed; the normal case costs no extra process.
cli=
trusted=
if [ -n "${FLIGHTDECK_CLI:-}" ] && [ -x "$FLIGHTDECK_CLI" ]; then
    cli=$FLIGHTDECK_CLI
    trusted=1
fi
if [ -z "$cli" ]; then
    script=$(readlink "$0" 2>/dev/null) || script=
    case $script in
        "") ;;
        /*) ;;
        *) script=$shim_dir/$script ;;
    esac
    if [ -n "$script" ] && [ -x "${script%/*}/../../MacOS/flightdeck" ]; then
        cli=${script%/*}/../../MacOS/flightdeck
        trusted=1
    fi
fi
if [ -z "$cli" ]; then
    cli=$(command -v flightdeck 2>/dev/null) || cli=
fi
[ -n "$cli" ] || exec -- "$name" "$@"

# A CLI from PATH is probed with a bare `route-exec`, which a current CLI
# rejects with a usage error (exit 2) without doing anything. Routing goes ahead
# only on exactly that. Anything else runs the real binary: an old CLI's
# `unknown command "route-exec"`, a crash (status 128 or more), no output at all,
# or a hang, which the watchdog kills after 2 seconds. Probing first, rather
# than inspecting a failed real run, is what stops a current CLI that already
# ran the command remotely from having it run a second time locally.
#
# The watchdog is plain bash because `timeout` is not installed on macOS. Its
# output goes to /dev/null so it never holds the capture pipe open: otherwise
# every probe would wait out the full 2 seconds. `set -m` gives the probe its
# own process group and the watchdog kills the whole group: killing only the
# CLI left a hung script's own children holding the pipe, and the shim waited
# for them (30 s with a stub that slept) even though the probe was "killed".
probe() {
    set -m
    "$1" route-exec </dev/null 2>&1 &
    probe_pid=$!
    set +m
    ( sleep 2; kill -KILL -- "-$probe_pid" ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$probe_pid"
    probe_status=$?
    kill "$watchdog" 2>/dev/null
    printf '\n%s' "$probe_status"
}
if [ -z "$trusted" ]; then
    # stderr dropped: job control makes bash report the killed job there.
    answer=$(probe "$cli" 2>/dev/null)
    probe_status=${answer##*$'\n'}
    probe_text=${answer%$'\n'*}
    case $probe_text in
        *'unknown command'*) exec -- "$name" "$@" ;;
    esac
    if [ "$probe_status" != 2 ] || [ -z "${probe_text//[[:space:]]/}" ]; then
        exec -- "$name" "$@"
    fi
fi

exec "$cli" route-exec "$name" -- "$@"
