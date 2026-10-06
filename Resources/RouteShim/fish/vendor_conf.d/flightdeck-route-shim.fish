# Flight Deck: keeps a tab's route-shim directory first on PATH (spec §8).
#
# Flight Deck launches every tab with $FLIGHTDECK_SHIM_DIR first on PATH, but a
# login shell's startup files then push it down: macOS's path_helper puts
# /etc/paths in front, and every `set PATH /x $PATH` or fish_add_path goes in
# front too. Measured under fish, the shim directory ended up 40th of 43
# entries, behind the real binaries, so a routed command never reached its
# shim. Fish finds this file through the XDG_DATA_DIRS entry Flight Deck adds,
# as <dir>/fish/vendor_conf.d/, and reads it before the user's config.fish.
#
# A handler on PATH itself rather than a hook after config.fish, which fish
# does not have: it puts the directory back the moment anything moves it, so
# it is first once config.fish is done (the `fish -l -c …` case, where no
# prompt ever fires) and before every prompt after an interactive edit.
#
# It only ever MOVES the directory. One that is not on PATH at all was taken
# off on purpose and stays off, and every other entry keeps its order. With
# FLIGHTDECK_SHIM_DIR unset or empty it does nothing.
function __flightdeck_route_shim_front --on-variable PATH --on-event fish_prompt
    set -q FLIGHTDECK_SHIM_DIR[1]; and test -n "$FLIGHTDECK_SHIM_DIR"; or return 0
    test "$PATH[1]" = "$FLIGHTDECK_SHIM_DIR"; and return 0
    contains -- "$FLIGHTDECK_SHIM_DIR" $PATH; or return 0
    # A literal comparison: `string match -v` would treat the path as a glob.
    set -l rest
    for entry in $PATH
        test "$entry" = "$FLIGHTDECK_SHIM_DIR"; or set -a rest $entry
    end
    # Setting PATH fires this handler again, which then finds the directory first.
    set -gx PATH $FLIGHTDECK_SHIM_DIR $rest
end
__flightdeck_route_shim_front
