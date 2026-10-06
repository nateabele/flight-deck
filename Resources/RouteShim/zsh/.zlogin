# Flight Deck's stand-in for the user's own .zlogin: it sources theirs, then keeps
# the tab's route-shim directory first on PATH. See flightdeck-route-shim.zsh.
_flightdeck_zdotdir=$ZDOTDIR
if [[ -n ${FLIGHTDECK_USER_ZDOTDIR+X} ]]; then ZDOTDIR=$FLIGHTDECK_USER_ZDOTDIR; else builtin unset ZDOTDIR; fi
[[ ! -r ${ZDOTDIR-$HOME}/.zlogin ]] || builtin source -- "${ZDOTDIR-$HOME}/.zlogin"
builtin source -- "$_flightdeck_zdotdir/flightdeck-route-shim.zsh"
_flightdeck_zsh_after .zlogin "$_flightdeck_zdotdir"
builtin unset _flightdeck_zdotdir
