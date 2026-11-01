#!/bin/bash
# Records one Claude Code lifecycle event for Flight Deck to tail.
#
# The payload goes to `flightdeck hook-record`, which pares it to the fields
# Flight Deck reads (session, event, agent, tool call id, tool name, and a
# digest of the tool input; see Sources/FleetKit/HookEventLine.swift) and
# appends that one line. Never the payload itself: it carries the prompt, the
# tool's input and the tool's output, and this file used to keep all of it, in
# plain text, forever.
#
# Parsing JSON takes a real parser, and this hook blocks the agent while it
# runs: the system perl took 381 ms on a 2 MB PostToolUse payload, while the
# bundled Swift CLI starts in a few ms. FLIGHTDECK_CLI names it in every tab.
#
# No FLIGHT_DECK_EVENT_DIR means no Flight Deck (a user running `claude` with
# this plugin by hand). Exit 0 on every path, and never `exec` the CLI: a hook
# that fails blocks the agent, and exit 2 from PreToolUse refuses the tool call,
# which an older CLI without `hook-record` would return. Nothing reaches stdout,
# so the PermissionRequest hook never makes a permission decision.
#
# `hooks.json` invokes this path QUOTED, and must: ${CLAUDE_PLUGIN_ROOT} expands
# to "/Applications/Flight Deck.app/Contents/Resources/ClaudePlugin" and Claude
# Code runs hook commands through a shell, so an unquoted expansion splits at
# `Flight` and every hook exits 127 — the whole claude feed silently off, on
# every installation there is.
[ -n "${FLIGHT_DECK_EVENT_DIR:-}" ] || exit 0
if [ -x "${FLIGHTDECK_CLI:-}" ]; then
  "$FLIGHTDECK_CLI" hook-record >/dev/null 2>&1
else
  cat >/dev/null
fi
exit 0
