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
# `flightdeck route-exec` (no operands) must fail with a usage error and touch
# nothing: the probe below relies on it.
#
# Stripping PATH here, rather than in the CLI, is what makes a fall-through
# unable to loop: an exec that found the shim again would re-enter route-exec
# forever. A side effect, deliberate: a routed command's own children see the
# stripped PATH, so a command that is already running locally (or remotely)
# never routes a nested call out from under itself. FLIGHTDECK_ROUTE_DEPTH is
# the same guard for a child that rebuilds PATH from a profile.
#
# Every failure here runs the real command. A shim must never make a command
# unrunnable: FLIGHTDECK_NO_ROUTE=1 (any value but empty or 0), no CLI, a CLI
# too old to know route-exec, or re-entry all fall through.

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
cli=
if [ -n "${FLIGHTDECK_CLI:-}" ] && [ -x "$FLIGHTDECK_CLI" ]; then
    cli=$FLIGHTDECK_CLI
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
    fi
fi
if [ -z "$cli" ]; then
    cli=$(command -v flightdeck 2>/dev/null) || cli=
fi
[ -n "$cli" ] || exec -- "$name" "$@"

# A CLI that predates route-exec answers `unknown command "route-exec"`. Probe
# with no operands (which a current CLI rejects as a usage error, doing nothing)
# rather than run the real thing and inspect the failure: by then a current CLI
# might already have run the command remotely, and running it again locally
# would run it twice.
case $("$cli" route-exec 2>&1 </dev/null) in
    *'unknown command'*) exec -- "$name" "$@" ;;
esac

exec "$cli" route-exec "$name" -- "$@"
