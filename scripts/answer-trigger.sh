#!/usr/bin/env bash
set -euo pipefail

# Deliver a phone-shaped answer to a running Flight Deck, from a terminal.
#
# The app answers an `AskUserQuestion` by driving its own terminal, and until this existed the
# only way to start that drive was to tap a paired iPhone — so every attempt to reproduce a
# failed drive, and to read the `AnswerAbort` record it writes, cost a human a round trip on a
# handset. This is the same code path with a socket in front of it: `PromptService`, then
# `SessionStore.answerPrompt`, then `AnswerPlan` and the `ChoiceDialog` interlock, exactly as
# `FleetService`'s `.answerPrompt` arm runs them.
#
# It is OFF unless the app was told to open the socket. Turn it on, then relaunch the app:
#
#   defaults write dev.flightdeck.FlightDeck FlightDeckAnswerTrigger -bool YES
#
# Usage:
#   scripts/answer-trigger.sh list
#   scripts/answer-trigger.sh answer <session-uuid> '[[0,1],[2]]' [call-id]
#   scripts/answer-trigger.sh logs [seconds]
#   scripts/answer-trigger.sh raw '{"op":"list"}'
#
# `[[0,1],[2]]` is one array per question, in the order the questions are asked, holding the
# option indices chosen for it — so that is "question 0 takes options 0 and 1, question 1 takes
# option 2". Every id and index comes from `list`.
#
# The call id is optional. Supplied, it is compared against what the terminal is blocked on
# right now and a tab that has moved on answers `prompt_changed` — the same check a phone gets.
# Omitted, this answers whatever is open, which is what a script driving its own session wants.
#
# `logs` pulls every attached phone's own diagnostic log to this Mac and appends it to
# ~/Library/Logs/flight-deck-phone.log, beside the Mac's own answer and prompt logs. The reply
# names that path and how many entries arrived. `seconds` is how far back to reach and defaults
# to 600; the phone clamps it. It answers `no_phones` when nothing is attached, and
# `unsupported_peer` for a handset built before the feature existed — that phone is not sent
# anything, because a frame it cannot decode would cost it its connection.

STATE_DIR="${FLIGHT_DECK_STATE_DIR:-$HOME/Library/Application Support/Flight Deck}"
SOCKET="$STATE_DIR/answer-trigger.sock"

usage() {
  sed -n '4,35p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

send() {
  if [ ! -S "$SOCKET" ]; then
    echo "error: no answer-trigger socket at $SOCKET" >&2
    echo "  the app opens it only when the flag is set, and only at launch:" >&2
    echo "    defaults write dev.flightdeck.FlightDeck FlightDeckAnswerTrigger -bool YES" >&2
    echo "  then relaunch Flight Deck." >&2
    exit 3
  fi
  # `nc -U` is the whole client: one line in, one line out, connection closed by the app. No
  # `-w` — the app's own SO_RCVTIMEO bounds the exchange, and a timeout here would race it.
  reply="$(printf '%s\n' "$1" | nc -U "$SOCKET")"
  printf '%s\n' "$reply"
  # Matched anywhere rather than at the front: `JSONEncoder` emits a keyed container in hash
  # order, so `ok` is not reliably the first key even though it is declared first — the app
  # asks for `sortedKeys` to make the output stable, which puts `ok` in the middle. A substring
  # test keeps this script free of a JSON parser for the one thing a caller branches on.
  case "$reply" in
    *'"ok":true'*) return 0 ;;
    *) return 1 ;;
  esac
}

# JSON string escaping for the two values this ever interpolates — a UUID and a call id. Both
# are already constrained shapes, but building JSON by concatenation without this is how a
# script grows a quoting bug that reads as a protocol error.
json_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
}

case "${1:-}" in
  list)
    send '{"op":"list"}'
    ;;
  answer)
    [ $# -ge 3 ] || usage
    request="{\"op\":\"answer\",\"session\":$(json_string "$2"),\"selections\":$3"
    # `if`, not `[ … ] && …`: under `set -e` a trailing test that is false is a failed command
    # and would exit the script instead of skipping an optional field.
    if [ $# -ge 4 ]; then
      request="$request,\"call\":$(json_string "$4")"
    fi
    send "$request}"
    ;;
  logs)
    # `case` rather than a `[ ]` numeric test: the argument is whatever a person typed, and
    # `[ "$2" -gt 0 ]` on a non-number is a shell error under `set -e` rather than a usage
    # message. The app clamps whatever number does get through.
    if [ $# -ge 2 ]; then
      case "$2" in
        ''|*[!0-9]*) echo "error: seconds must be a whole number" >&2; exit 2 ;;
      esac
      send "{\"op\":\"logs\",\"seconds\":$2}"
    else
      send '{"op":"logs"}'
    fi
    ;;
  raw)
    [ $# -ge 2 ] || usage
    send "$2"
    ;;
  *)
    usage
    ;;
esac
