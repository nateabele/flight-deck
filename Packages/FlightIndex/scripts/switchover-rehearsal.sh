#!/bin/bash
# Rehearse `fdindex switchover` on COPIES of this machine's real config files in a temp HOME:
# dry run, apply, diff of every file against its original, rollback, byte comparison.
# The real HOME is only read from. No service is installed (--no-service).
#
#   switchover-rehearsal.sh [path/to/fdindex]
set -u
FD=$(realpath "${1:-$(dirname "$0")/../target/release/fdindex}")
REAL=$HOME
T=$(mktemp -d /tmp/fdrehearse.XXXXXX); trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
H=$T/home; mkdir -p $H/.local/bin $H/.config/opencode $H/.config/zed $H/.cursor $H/.gemini $H/.codex
cp_ () { [ -e "$REAL/$1" ] && { mkdir -p "$(dirname "$H/$1")"; cp -pc "$REAL/$1" "$H/$1"; }; }
for f in .claude/settings.json .claude-radify/settings.json .claude.json .claude-radify/.claude.json .codex/config.toml \
         .config/opencode/opencode.json .config/zed/settings.json .cursor/mcp.json .gemini/settings.json \
         .local/bin/qartez .local/bin/qartez-guard .local/bin/qartez-setup; do cp_ $f; done
for d in .claude/skills/qartez .claude-radify/skills/qartez; do [ -d "$REAL/$d" ] && { mkdir -p "$(dirname "$H/$d")"; cp -Rp "$REAL/$d" "$H/$d"; }; done
[ -L "$REAL/.local/bin/qartez-mcp" ] && ln -s qartez $H/.local/bin/qartez-mcp
sw () { "$FD" --home $H --store $T/store --socket $T/s.sock switchover --no-service "$@"; }

echo "################ seeded temp HOME: $H"
( cd $H && find . -type f -o -type l | sort | sed 's#^\./##' > $T/files.before; wc -l < $T/files.before | xargs echo "files:" )
mkdir -p $T/orig && ( cd $H && tar cf - . ) | ( cd $T/orig && tar xf - )

echo; echo "################ dry run"; sw
echo; echo "################ apply"; sw --apply || exit 1

echo; echo "################ diff of every changed file (original -> after apply)"
for f in $(cd $H && find . -type f ! -path './.local/bin/fdindex' | sort | sed 's#^\./##'); do
  if ! cmp -s "$T/orig/$f" "$H/$f"; then
    case $f in .local/bin/*) echo "--- $f (binary)"; continue;; esac
    echo "=== $f"; diff "$T/orig/$f" "$H/$f"
  fi
done
echo; echo "################ JSON still parses; qartez entries"
for f in .claude/settings.json .claude-radify/settings.json .claude.json .claude-radify/.claude.json .gemini/settings.json .cursor/mcp.json .config/zed/settings.json .config/opencode/opencode.json; do
  [ -f $H/$f ] && python3 -c "import json,sys; json.load(open('$H/$f')); print('ok  $f')"
done
ls -la $H/.local/bin | sed 's#^#   #'

echo; echo "################ rollback"; sw --rollback
echo; echo "################ byte comparison after rollback"
rc=0
for f in $(cat $T/files.before); do cmp -s "$T/orig/$f" "$H/$f" || { echo "DIFFERS: $f"; rc=1; }; done
( cd $H && find . -type f -o -type l | sort | sed 's#^\./##' ) | diff $T/files.before - && echo "same file list" || rc=1
[ -L $H/.local/bin/qartez ] && { echo "qartez is still a symlink"; rc=1; }
[ $rc = 0 ] && echo "ALL $(wc -l < $T/files.before) FILES BYTE-IDENTICAL AFTER ROLLBACK" || echo "ROLLBACK MISMATCH"
exit $rc
