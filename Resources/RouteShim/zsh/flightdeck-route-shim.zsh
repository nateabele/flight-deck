# Flight Deck: keeps a tab's route-shim directory first on PATH (spec §8).
#
# Flight Deck launches every tab with $FLIGHTDECK_SHIM_DIR first on PATH, but a
# login shell's startup files then push it down: /etc/zprofile runs
# path_helper, which puts /etc/paths in front, and every `export PATH=/x:$PATH`
# goes in front too. Measured under zsh, the shim directory ended up 18th, so a
# routed command never reached its shim.
#
# zsh has no hook after its startup files, so Flight Deck points ZDOTDIR here
# and saves the user's own as FLIGHTDECK_USER_ZDOTDIR. Each .z* file in this
# directory sources the user's real one, with ZDOTDIR set back to theirs while
# it runs, then calls `_flightdeck_zsh_after`. After the last startup file this
# shell reads, ZDOTDIR is the user's again for good, and a precmd hook keeps
# the directory first for the rest of an interactive session.
#
# The user's files are sourced by the .z* files themselves, at the top level:
# sourced inside a function, every `typeset` and `local` in them would be
# scoped to that function and gone when it returned.

# Moves the shim directory to the front of PATH. Only ever moves it: one that
# is not on PATH at all was taken off on purpose and stays off, and every other
# entry keeps its order. With FLIGHTDECK_SHIM_DIR unset or empty it does nothing.
_flightdeck_route_shim_front() {
    [[ -n ${FLIGHTDECK_SHIM_DIR-} ]] || return 0
    [[ ${path[1]-} == "$FLIGHTDECK_SHIM_DIR" ]] && return 0
    (( ${path[(Ie)$FLIGHTDECK_SHIM_DIR]} )) || return 0
    # (b) quotes the directory, so it is removed as a literal, never as a glob.
    path=("$FLIGHTDECK_SHIM_DIR" "${(@)path:#${(b)FLIGHTDECK_SHIM_DIR}}")
}

# After the user's file `$1` ran, with this directory `$2`: re-prepends, and
# either points ZDOTDIR back here for the next startup file or, after the last
# one, leaves it as the user's.
_flightdeck_zsh_after() {
    local name=$1 ours=$2 last=0
    # Their ZDOTDIR as it stands now: a ~/.zshenv that sets ZDOTDIR moves
    # every later startup file, and the next stage must source from there.
    if [[ -n ${ZDOTDIR+X} ]]; then
        export FLIGHTDECK_USER_ZDOTDIR=$ZDOTDIR
    else
        unset FLIGHTDECK_USER_ZDOTDIR
    fi
    _flightdeck_route_shim_front
    # The last file zsh reads: .zlogin for a login shell, .zshrc for any other
    # interactive one, .zshenv for the rest, or wherever the user's own file
    # turned startup files off (`unsetopt rcs`).
    case $name in
        .zshenv) [[ -o login || -o interactive ]] || last=1 ;;
        .zshrc) [[ -o login ]] || last=1 ;;
        .zlogin) last=1 ;;
    esac
    [[ -o rcs ]] || last=1
    if [[ $name == .zshrc ]]; then
        autoload -Uz add-zsh-hook && add-zsh-hook precmd _flightdeck_route_shim_front
    fi
    if (( last )); then
        unset FLIGHTDECK_USER_ZDOTDIR
    else
        ZDOTDIR=$ours
    fi
}
