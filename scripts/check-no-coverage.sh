#!/usr/bin/env bash
# Asserts the built app carries no code-coverage instrumentation. Run after ./scripts/build.sh.
#
# Why: a coverage-instrumented binary writes `default.profraw` into the CWD at exit, so every
# `flightdeck` CLI run littered the user's git repos, and hostd (launchd, read-only CWD) logged
# "LLVM Profile Error: Failed to write file default.profraw". xcodebuild's auto-synthesized
# `FlightDeck` scheme gathers coverage; project.yml's explicit scheme turns that off.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"
APP="DerivedData/Build/Products/${CONFIG}/Flight Deck.app"
[ -d "$APP" ] || { echo "error: no built app at $APP (run scripts/build.sh)" >&2; exit 1; }

fail=0
while IFS= read -r f; do
  if file "$f" | rg -q 'Mach-O' && otool -l "$f" 2>/dev/null | rg -q '__llvm_prf'; then
    echo "FAIL: __llvm_prf section in $f"; fail=1
  fi
done < <(find "$APP" -type f ! -name '*.dSYM')

CLI="$(find "$APP" -type f -name flightdeck -perm -u+x | head -n 1)"
[ -n "$CLI" ] || { echo "error: no flightdeck binary in $APP" >&2; exit 1; }
tmp="$(mktemp -d)"
(cd "$tmp" && "$OLDPWD/$CLI" --help >/dev/null 2>&1 || true)
if ls "$tmp"/*.profraw >/dev/null 2>&1; then
  echo "FAIL: flightdeck --help left $(ls "$tmp" | head -n 1) behind"; fail=1
fi
rm -rf "$tmp"

[ "$fail" = 0 ] && echo "NO-COVERAGE PASS" || exit 1
