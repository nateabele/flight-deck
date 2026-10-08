#!/usr/bin/env bash
# scripts/test-infra-live.sh — cloud infra hosts end to end, against the user's REAL account.
# It creates a real machine, which costs real money (cents: the smallest type, a 15-minute TTL),
# so it is never part of any suite and refuses to start without FD_INFRA_LIVE=1. An agent must
# never run it unasked (docs/AGENT-OPERATIONS.md, "Cloud machines").
#
# It drives the installed Flight Deck through its own CLI (`flightdeck`, or FLIGHTDECK=/path), so
# it tests what the user runs: the app owns the credentials, OpenTofu state and budget, and the
# CLI only asks. Run it from a tab inside that Flight Deck, with Settings → Cloud set up.
#
#   FD_INFRA_LIVE=1 ./scripts/test-infra-live.sh aws|gcp
#
# What it checks is the spec's success criteria (§1): `run --on` an `auto_up` machine creates it,
# it pairs with nothing typed and runs a command, it is listed as a host, and `infra down` leaves
# no labelled resource behind (an orphan scan that could not read an account fails the run
# rather than passing as "none").
set -euo pipefail

if [ "${FD_INFRA_LIVE:-}" != 1 ]; then
  echo "refusing: set FD_INFRA_LIVE=1 (this creates real cloud resources and costs money)" >&2
  exit 2
fi
CLOUD=${1:-}
case "$CLOUD" in aws|gcp) ;; *) echo "usage: FD_INFRA_LIVE=1 $0 aws|gcp" >&2; exit 2 ;; esac

FD=${FLIGHTDECK:-flightdeck}
command -v "$FD" >/dev/null || { echo "$FD not found: run this from a Flight Deck tab, or set FLIGHTDECK=" >&2; exit 2; }
NAME=fd-live-test

# A throwaway repo: v1 delegation refuses a repo with submodules, which Flight Deck's own has.
WORK=$(mktemp -d)
# The trap destroys the machine on ANY exit, a failed assertion included: the TTL would end it
# anyway, but a test that leaves its machine running for 15 minutes on failure is a test people
# stop trusting with their account.
cleanup() {
  cd /
  "$FD" infra down "$NAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"
git init -q
git -c user.name=fd-live -c user.email=fd-live@example.com commit -q --allow-empty -m init
mkdir -p .flightdeck
case "$CLOUD" in
  aws) printf '[infra.%s]\npreset = "aws-linux"\nregion = "us-east-1"\ninstance_type = "t4g.nano"\narch = "arm64"\nttl = "15m"\nauto_up = true\n' "$NAME" ;;
  gcp) printf '[infra.%s]\npreset = "gcp-linux"\nregion = "us-central1"\ninstance_type = "e2-micro"\nttl = "15m"\nauto_up = true\n' "$NAME" ;;
esac > .flightdeck/delegate.toml
git add -A
git -c user.name=fd-live -c user.email=fd-live@example.com commit -q -m cfg

start=$(date +%s)
# auto_up: the run creates the machine, waits for it to enroll, then runs. stderr carries the
# progress and the cost line; stdout is the remote command's.
"$FD" run --on "$NAME" -- uname -a | tee run.out
grep -q Linux run.out
"$FD" host ls --json | grep -q "\"name\":\"$NAME\""
"$FD" infra down "$NAME"
# `ls --orphans --json` is {"machines":…,"orphans":[…],"unreadable":{…}}: both must be empty, or
# "no orphans" only means "could not look".
orphans=$("$FD" infra ls --orphans --json)
echo "$orphans" | grep -q '"orphans":\[\]' || { echo "FAIL: orphans left: $orphans" >&2; exit 1; }
echo "$orphans" | grep -q '"unreadable":{}' || { echo "FAIL: an account could not be scanned: $orphans" >&2; exit 1; }
echo "INFRA LIVE PASS ($CLOUD, $(( $(date +%s) - start ))s)"
