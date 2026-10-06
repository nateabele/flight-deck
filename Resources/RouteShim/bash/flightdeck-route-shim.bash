# Flight Deck: keeps a tab's route-shim directory first on PATH (spec §8).
#
# Flight Deck launches every tab with $FLIGHTDECK_SHIM_DIR first on PATH, but a
# login shell's startup files then push it down: /etc/profile runs
# path_helper, which puts /etc/paths in front, and every `PATH=/x:$PATH` goes in
# front too, so a routed command never reaches its shim. Bash has no hook after
# its startup files and no way to point it at other ones, so Flight Deck adds
# `. <this file>` to PROMPT_COMMAND, which runs before every prompt: after the
# startup files, and after any later edit. A ~/.bashrc that assigns
# PROMPT_COMMAND outright, rather than adding to it, drops this.
#
# It only ever MOVES the directory. One that is not on PATH at all was taken
# off on purpose and stays off, and every other entry keeps its order, empty
# ones included. With FLIGHTDECK_SHIM_DIR unset or empty it does nothing.
# Bash 3.2, which is what macOS ships: no arrays of PATH, no `local` outside a
# function, so the scratch variables are unset at the end.
if [ -n "${FLIGHTDECK_SHIM_DIR:-}" ]; then
    case ":$PATH:" in
        ":$FLIGHTDECK_SHIM_DIR:"*) ;;
        *":$FLIGHTDECK_SHIM_DIR:"*)
            __flightdeck_rest=$PATH:
            __flightdeck_kept=
            __flightdeck_sep=
            while [ -n "$__flightdeck_rest" ]; do
                __flightdeck_entry=${__flightdeck_rest%%:*}
                __flightdeck_rest=${__flightdeck_rest#*:}
                if [ "$__flightdeck_entry" != "$FLIGHTDECK_SHIM_DIR" ]; then
                    __flightdeck_kept=$__flightdeck_kept$__flightdeck_sep$__flightdeck_entry
                    __flightdeck_sep=:
                fi
            done
            PATH=$FLIGHTDECK_SHIM_DIR${__flightdeck_sep:+:$__flightdeck_kept}
            unset __flightdeck_rest __flightdeck_kept __flightdeck_sep __flightdeck_entry
            ;;
    esac
fi
