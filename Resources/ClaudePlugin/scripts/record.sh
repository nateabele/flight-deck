#!/bin/bash
# Appends one JSON line per Claude Code lifecycle event for Flight Deck to tail.
#
# The payload already carries `hook_event_name` and `session_id`, so this takes
# no arguments and parses nothing — no `jq` dependency. `tr` removes only
# pretty-printing newlines; JSON strings escape their own as \n.
#
# No FLIGHT_DECK_EVENT_DIR means no Flight Deck (a user running `claude` with
# this plugin by hand). Exit 0 on every path: a hook that fails blocks the agent.
#
# `hooks.json` invokes this path QUOTED, and must: ${CLAUDE_PLUGIN_ROOT} expands
# to "/Applications/Flight Deck.app/Contents/Resources/ClaudePlugin" and Claude
# Code runs hook commands through a shell, so an unquoted expansion splits at
# `Flight` and every hook exits 127 — the whole claude feed silently off, on
# every installation there is.
[ -n "${FLIGHT_DECK_EVENT_DIR:-}" ] || exit 0
printf '%s\n' "$(cat | tr -d '\n')" >> "$FLIGHT_DECK_EVENT_DIR/events.ndjson" 2>/dev/null
exit 0
