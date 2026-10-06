#!/bin/bash
# Flight Deck's claude status line: records the account's rate-limit windows for Flight
# Control's usage meter (L3-U), then runs the user's own status line unchanged.
#
# Flight Deck installs this per claude tab with `--settings '{"statusLine":…}'`. Claude Code
# hands a status line command a JSON object on stdin that carries `.rate_limits.<window>`
# (`used_percentage`, `resets_at` in epoch seconds); no hook payload carries them. So this
# script is both the meter's only source for an interactive tab and the thing that draws the
# user's status line, and the second job must never suffer for the first:
#
# - The user's command (FLIGHT_DECK_USER_STATUSLINE, resolved by Flight Deck from the user's
#   effective claude settings at launch) gets the same stdin, and its output reaches claude
#   untouched. No command means no status line text, which is what claude shows without one.
# - The usage write runs in the background, in parallel with the user's command, so it adds
#   no latency unless the user's command is faster than it (~40 ms of plutil calls).
# - No jq: it is not on every Mac, and a missing jq would cost the meter silently. plutil is.
#   Not python3 either: on a Mac without the developer tools /usr/bin/python3 is a stub that
#   opens an install dialog, and a status line runs every 30 s.
# - Every path exits 0.
#
# The usage file is the shape the retired usage mod wrote (`ModUsageFile`, v1), at
# <FLIGHT_DECK_USAGE_DIR>/<tab or claude session id>.json, written to a temp file and renamed
# so Flight Deck never reads a torn file. No FLIGHT_DECK_USAGE_DIR means no Flight Deck: write
# nothing.
#
# It rewrites the file only when the reading moved: the rate limits, or the token usage of the
# last API call. A status line also runs on a timer (`refreshInterval`) and on UI events, and
# between API calls it re-sends the numbers of the last one. Stamping those with a new readAt
# would make an idle tab's old numbers the account's newest reading — the ledger keeps the
# newest — and hide the real reading of a busy tab on the same account.
#
# Flight Deck puts this path in the settings QUOTED, and must: it lives under
# "Application Support/Flight Deck" (or "/Applications/Flight Deck.app") and claude runs the
# command through a shell, so unquoted it splits at the space and exits 127 — no status line
# and no meter. See record.sh.

input=$(cat; printf x)
input=${input%x}

record_usage() {
  export LC_ALL=C
  local pl=/usr/bin/plutil dir=$FLIGHT_DECK_USAGE_DIR
  local limits last name session tab fp file old kinds kind pct resets at windows sep now tmp
  limits=$(printf '%s' "$input" | $pl -extract rate_limits json -o - - 2>/dev/null) || return 0
  [ -n "$limits" ] || return 0

  tab=${FLIGHT_DECK_SESSION_ID:-}
  case "$tab" in *[!A-Za-z0-9-]*) tab="" ;; esac
  session=$(printf '%s' "$input" | $pl -extract session_id raw -o - - 2>/dev/null)
  case "$session" in *[!A-Za-z0-9-]*) session="" ;; esac
  name=${tab:-$session}
  [ -n "$name" ] || return 0
  file="$dir/$name.json"

  last=$(printf '%s' "$input" | $pl -extract context_window.current_usage json -o - - 2>/dev/null)
  fp=$(printf '%s\n%s' "$limits" "$last" | cksum)
  fp=${fp%% *}
  old=$($pl -extract fp raw -o - "$file" 2>/dev/null)
  [ "$old" = "$fp" ] && return 0

  windows="" sep=""
  kinds=$(printf '%s' "$input" | $pl -extract rate_limits raw -o - - 2>/dev/null)
  for kind in $kinds; do
    case "$kind" in *[!a-z0-9_]*) continue ;; esac
    pct=$(printf '%s' "$limits" | $pl -extract "$kind.used_percentage" raw -o - - 2>/dev/null)
    case "$pct" in '' | *[!0-9.]* | *.*.*) continue ;; esac
    resets=$(printf '%s' "$limits" | $pl -extract "$kind.resets_at" raw -o - - 2>/dev/null)
    resets=${resets%%.*}
    at=null
    case "$resets" in '' | *[!0-9]*) ;; *) at="\"$(date -u -r "$resets" +%Y-%m-%dT%H:%M:%SZ)\"" ;; esac
    windows="$windows$sep{\"kind\":\"$kind\",\"percentUsed\":$pct,\"resetsAt\":$at}"
    sep=","
  done
  [ -n "$windows" ] || return 0

  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ -n "$tab" ] && tab="\"$tab\"" || tab=null
  [ -n "$session" ] && session="\"$session\"" || session=null
  tmp="$dir/.$name.$$.tmp"
  if printf '{"v":1,"tab":%s,"session":%s,"readAt":"%s","fp":"%s","rateLimits":[%s]}' \
       "$tab" "$session" "$now" "$fp" "$windows" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

if [ -n "${FLIGHT_DECK_USAGE_DIR:-}" ]; then
  record_usage </dev/null >/dev/null 2>&1 &
fi
if [ -n "${FLIGHT_DECK_USER_STATUSLINE:-}" ]; then
  printf '%s' "$input" | /bin/sh -c "$FLIGHT_DECK_USER_STATUSLINE"
fi
wait
exit 0
