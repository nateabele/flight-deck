#!/bin/bash
# hangwatch.sh — auto-capture a stack sample when Flight Deck's main thread stalls.
#
# Detects a beach ball from outside the app: every few seconds it takes a cheap
# 1-second sample and checks whether the main thread ever returns to its idle
# parking spot (mach_msg2_trap under the CFRunLoop event wait). A main thread
# that is non-idle across two consecutive checks (~6s) is hung, not busy.
#
# Usage:  ./hangwatch.sh [output-dir]
# Output: <output-dir>/hang-YYYYmmdd-HHMMSS.txt  (full symbolicated sample)

set -u

OUTDIR="${1:-$HOME/Desktop/flightdeck-hangs}"
APP="Flight Deck"
POLL_INTERVAL=2      # seconds between probes
STRIKES_TO_FIRE=2    # consecutive non-idle probes before we call it a hang
CAPTURE_SECONDS=10   # length of the full sample we capture
COOLDOWN=60          # seconds to wait after a capture before arming again

mkdir -p "$OUTDIR"
probe=$(mktemp)
trap 'rm -f "$probe"' EXIT

echo "hangwatch: watching \"$APP\"; captures land in $OUTDIR"
echo "hangwatch: leave this running, then use the app normally. Ctrl-C to stop."

strikes=0
while true; do
    pid=$(pgrep -f "/Applications/$APP.app/Contents/MacOS/$APP" | head -1)
    if [ -z "$pid" ]; then
        strikes=0
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Cheap probe: 1 second at 200ms => 5 samples of every thread.
    if ! sample "$pid" 1 200 -file "$probe" >/dev/null 2>&1; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Pull the main thread's block out of the report and ask whether it ever
    # parked in the run loop's mach_msg wait. Idle main thread => healthy.
    idle=$(awk '
        /DispatchQueue_1: com.apple.main-thread/ { inmain = 1; next }
        inmain && /^ *[0-9]+ Thread_/            { inmain = 0 }
        inmain && /mach_msg2_trap/               { found = 1 }
        END { print (found ? "yes" : "no") }
    ' "$probe")

    ts=$(date '+%H:%M:%S')
    if [ "$idle" = "yes" ]; then
        [ "$strikes" -gt 0 ] && echo "$ts  recovered"
        strikes=0
    else
        strikes=$((strikes + 1))
        echo "$ts  main thread not idle (strike $strikes/$STRIKES_TO_FIRE)"

        if [ "$strikes" -ge "$STRIKES_TO_FIRE" ]; then
            out="$OUTDIR/hang-$(date '+%Y%m%d-%H%M%S').txt"
            echo "$ts  HANG — capturing ${CAPTURE_SECONDS}s sample to $out"
            sample "$pid" "$CAPTURE_SECONDS" -file "$out" >/dev/null 2>&1
            echo "$ts  captured $(wc -l < "$out" | tr -d ' ') lines"
            osascript -e "display notification \"Captured $(basename "$out")\" with title \"Flight Deck hang\"" >/dev/null 2>&1
            strikes=0
            sleep "$COOLDOWN"
        fi
    fi

    sleep "$POLL_INTERVAL"
done
