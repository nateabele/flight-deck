#!/bin/bash
# Pull the phone's own log (PhoneJournal) and symbolicate its main-thread stall samples.
#
# Usage:
#   scripts/phone-stalls.sh [lines]     # the last `lines` lines (default 200)
#
# The phone appends every PhoneLog line to Library/Caches/phone.log (rotated to phone.1.log
# past 1 MB): connection, prompt and answer lines, and under `perf` every main-thread stall
# over 250 ms with up to four stack samples taken while it lasted, plus slow highlighting,
# rebuilds, cache reads and log reads. See `PhoneJournal` and `MainStallWatch` in
# Sources/FlightDeckMobile/PhoneLog.swift.
#
# Read with `devicectl` rather than over the fleet socket on purpose: a phone whose main
# thread is stuck is exactly the phone whose socket log fetch would not answer.
#
# The app's own frames arrive as FlightDeckMobile+0xOFFSET and are resolved with `atos`
# against the dSYM whose UUID matches the `stall watch armed uuid=…` line of the same launch.
# The dSYMs searched are every Release/Debug iphoneos build under this checkout and its
# worktrees, plus any directories in PHONE_DSYM_DIRS (space-separated) — put a copy of a build's
# dSYM there before DerivedData is rebuilt over it. A launch whose dSYM is nowhere prints its
# offsets unresolved.
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/.."

LINES=${1:-200}
DEVICE=${DEVICE:-Mobile3}
BUNDLE=io.radify.flightdeck.FlightDeckMobile
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

for f in phone.1.log phone.log; do
  xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --source "Library/Caches/$f" --destination "$OUT/$f" \
    >/dev/null 2>&1 || true
done
cat "$OUT"/phone.1.log "$OUT"/phone.log 2>/dev/null | tail -n "$LINES" > "$OUT/tail.log" || true
[ -s "$OUT/tail.log" ] || { echo "no phone log on $DEVICE" >&2; exit 1; }

# "uuid path" per line, for every phone build dSYM this checkout has. A file rather than an
# associative array: /bin/bash on macOS is 3.2, which has none.
while IFS= read -r dsym; do
  bin="$dsym/Contents/Resources/DWARF/FlightDeckMobile"
  [ -f "$bin" ] || continue
  dwarfdump --uuid "$bin" | awk -v b="$bin" '{print $2, b}' >> "$OUT/dsyms"
done < <(find DerivedData .claude/worktrees/*/DerivedData ${PHONE_DSYM_DIRS:-} -maxdepth 4 \
           -path '*FlightDeckMobile.app.dSYM' 2>/dev/null)
touch "$OUT/dsyms"

bin=""
while IFS= read -r line; do
  if [[ $line =~ stall\ watch\ armed\ uuid=([0-9A-F-]+) ]]; then
    bin=$(awk -v u="${BASH_REMATCH[1]}" '$1 == u {print $2; exit}' "$OUT/dsyms")
    [ -n "$bin" ] || line+="   (no matching dSYM; offsets left unresolved)"
  fi
  if [[ $line == *"stack["* && -n $bin ]]; then
    prefix=${line%%stack\[*}
    rest=${line#"$prefix"}
    label=${rest%% *}
    echo "$prefix$label"
    IFS='|' read -ra frames <<< "${rest#"$label "}"
    for frame in "${frames[@]}"; do
      frame=$(echo "$frame" | xargs)
      if [[ $frame =~ ^FlightDeckMobile\+0x([0-9a-f]+)$ ]]; then
        addr=$(printf '0x%x' $((0x100000000 + 0x${BASH_REMATCH[1]})))
        echo "      $(atos -o "$bin" -arch arm64 -l 0x100000000 "$addr")"
      else
        echo "      $frame"
      fi
    done
  else
    echo "$line"
  fi
done < "$OUT/tail.log"
