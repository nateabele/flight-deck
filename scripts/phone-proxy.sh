#!/usr/bin/env bash
# Make a phone on this Wi-Fi reachable to CoreDevice, by re-advertising its remote-pairing
# Bonjour service from this Mac. Idempotent: does nothing when the device is already available.
#
# Usage:
#   scripts/phone-proxy.sh            # DEVICE defaults to Mobile3; PHONE_IP overrides discovery
#
# Why it exists: the router here drops the phone's multicast `_remotepairing._tcp` advert, so
# `devicectl` lists the phone `unavailable` while it is on the same Wi-Fi and answering ping.
# Asked over UNICAST, the phone's own mDNS responder still answers, so the fix is to read its
# records directly and register them here with `dns-sd -P`. The phone rotates its service UUID
# and authTag (seen 2026-10-14 and 2026-10-15), which makes any earlier proxy stale — so this
# reads the records fresh every time and replaces whatever proxy is running. See MOBILE-UI.md,
# "`unavailable` on Wi-Fi". scripts/deploy-phone.sh runs this before every install.
#
# Exit 0 when the device is available, 1 when it could not be made so (and says why).
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

DEVICE="${DEVICE:-Mobile3}"
SERVICE=_remotepairing._tcp

available() {
  xcrun devicectl list devices 2>/dev/null | grep -E "^$DEVICE[[:space:]]" | grep -q "available (paired)"
}

if available; then
  exit 0
fi

# The phone's LAN address: PHONE_IP, or the phone's own host record over mDNS, which gets
# through when the service advert does not. Not Tailscale's "direct" address: the tailnet has
# more than one iPhone, and nothing there maps a CoreDevice name to a tailnet one.
ip="${PHONE_IP:-}"
if [ -z "$ip" ]; then
  ip=$(timeout 5 dscacheutil -q host -a name "$DEVICE.local" 2>/dev/null \
    | awk '/^ip_address:/ {print $2; exit}') || true
fi
if [ -z "$ip" ]; then
  echo "phone-proxy: cannot find $DEVICE on the LAN ($DEVICE.local does not resolve)." >&2
  echo "  Asleep, off this Wi-Fi, or on cellular (Tailscale does not carry CoreDevice)?" >&2
  echo "  Wake it on this Wi-Fi, set PHONE_IP, or plug in a cable." >&2
  exit 1
fi

# Its records, asked over unicast.
# `dig` prints its own failures (";; connection timed out") to stdout and exits nonzero, so both
# are filtered here and the empty result below says what happened instead.
ask() { dig +short +time=2 +tries=2 @"$ip" -p 5353 "$@" 2>/dev/null | grep -v '^;;' || true; }
instance=$(ask "$SERVICE.local" PTR | head -1)
if [ -z "$instance" ]; then
  echo "phone-proxy: $DEVICE at $ip did not answer for $SERVICE (asleep, or not the phone?)." >&2
  exit 1
fi
uuid=${instance%%.*}
port=$(ask "$instance" SRV | awk '{print $3; exit}')
txt=$(ask "$instance" TXT | head -1)
if [ -z "$port" ] || [ -z "$txt" ]; then
  echo "phone-proxy: $DEVICE answered PTR but not SRV/TXT for $instance." >&2
  exit 1
fi
# TXT comes back as "k=v" "k=v" …; dns-sd takes them as separate arguments. Split without
# `eval`: this text came off the network, and anything on the LAN can answer mDNS.
pairs=()
while IFS= read -r pair; do
  pairs+=("${pair//\"/}")
done < <(printf '%s' "$txt" | grep -oE '"[^"]*"')

# Replace any proxy for this service: an old one names a UUID or authTag the phone has dropped.
pkill -f "dns-sd -P .* $SERVICE " 2>/dev/null || true
host=$(printf '%s' "$DEVICE" | tr '[:upper:]' '[:lower:]')-proxy.local
nohup dns-sd -P "$uuid" "$SERVICE" local "$port" "$host" "$ip" "${pairs[@]}" >/dev/null 2>&1 &
disown
echo "phone-proxy: advertising $DEVICE ($ip:$port, $uuid) from this Mac"

for _ in $(seq 1 30); do
  available && { echo "phone-proxy: $DEVICE is available"; exit 0; }
  sleep 2
done
echo "phone-proxy: proxy registered, but $DEVICE is still not available after 60 s." >&2
exit 1
