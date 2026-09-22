#!/bin/bash
# Swaps the running /Applications/Flight Deck.app for a freshly built Release bundle.
#
# This MUST run detached from Claude Code: Claude is running in a shell inside the very
# app being replaced (Flight Deck → login → fish → claude), so quitting the app kills
# the session that would otherwise be doing this work. Launched via `nohup … &` so the
# SIGHUP that follows the app's death does not take this script with it.
#
# The canonical copy of this script lives here, in the repo. The deployed copy at
# ~/Library/Application Support/Flight Deck/swap-release.sh is installed from this one;
# edit this file, then re-install, never the other way round.

set -uo pipefail

# FD_SWAP_NEW_APP overrides which bundle gets installed. Exists so the flavor guard below
# can be exercised against a known-debug bundle without editing the script — see
# FD_SWAP_CHECK_ONLY and FD_SWAP_ALLOW_DEBUG a few lines down.
NEW_APP="${FD_SWAP_NEW_APP:-/Users/nate/Projects/Protos-n-Tools/flight-deck/DerivedData/Build/Products/Release/Flight Deck.app}"
INSTALLED="/Applications/Flight Deck.app"
STAGING="/Applications/.Flight Deck.app.incoming"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/Users/nate/Library/Application Support/Flight Deck/backups/$TS"
LOG="/Users/nate/Library/Logs/flight-deck-swap.log"
DELAY="${1:-30}"

# BACKUP_DIR is created lazily, at its first use in step 3 — not here. FD_SWAP_CHECK_ONLY is
# meant to be run casually as a pre-flight, and a refused/check-only run never gets that far;
# creating it unconditionally here littered an empty timestamped directory under
# ~/Library/Application Support/Flight Deck/backups/ on every such run.
mkdir -p "$(dirname "$LOG")"

log() { echo "[$(date '+%H:%M:%S')] $*" >>"$LOG"; }

# Deliberately NOT pgrep: in this environment `pgrep -f` matches nothing for this app,
# even from a detached child, while `ps -A` lists it fine. Verified before arming — a
# silent no-match here would skip the quit and swap the bundle out from under a live app.
#
# Matches ANY Flight Deck.app bundle executable, not just the installed one. A stray
# instance launched from DerivedData is still a live app holding live sessions, and
# leaving it running is what produced duplicate `claude --resume` processes and the
# name collisions in ~/.claude/sessions.
find_pids() {
  ps -Ao pid=,comm= 2>/dev/null | awk '
    {
      pid = $1
      sub(/^[ \t]*[0-9]+[ \t]+/, "")
      if ($0 ~ /\/Flight Deck\.app\/Contents\/MacOS\/Flight Deck$/) print pid
    }'
}

# Classifies a bundle as debug/release/unknown without ever launching it — see the
# 2026-09-22 incident below. Info.plist and the get-task-allow entitlement were both checked
# against a real Debug/Release pair and are byte-identical, so neither can discriminate;
# executable size is a heuristic, not a signal, and is deliberately not used. Two static
# signals are: Debug links `@rpath/Flight Deck.debug.dylib` where Release links only
# `@rpath/FleetKit.framework/…`, and Debug ships the XCTest runner under Contents/PlugIns
# where Release has none. Either firing means debug — fail closed toward refusing.
#
# `release` is returned ONLY on positive evidence (otool ran, showed no .debug.dylib, AND
# PlugIns is absent). If otool is missing from PATH, or otool -L fails on a bundle that
# already passed the executable check above, that is "cannot tell" — not "release". Folding
# that case into `release` would have waved through the exact culprit bundle from the
# 2026-09-22 incident (caught by the otool signal alone) the moment otool was unavailable.
#
# otool -L exits 0 and prints "is not an object file" to STDOUT for a non-Mach-O input, so a
# zero exit status alone is not evidence otool actually read anything — require at least one
# real library-reference line (.dylib or .framework) before trusting the absence of
# .debug.dylib. Every macOS binary links libSystem, so a genuine Mach-O always has one.
bundle_flavor() {
  local bundle="$1"
  if ! command -v otool >/dev/null 2>&1; then
    echo unknown
    return
  fi
  local otool_out
  if ! otool_out="$(otool -L "$bundle/Contents/MacOS/Flight Deck" 2>/dev/null)"; then
    echo unknown
    return
  fi
  if grep -q '\.debug\.dylib' <<<"$otool_out"; then
    echo debug
    return
  fi
  if [ -d "$bundle/Contents/PlugIns" ]; then
    echo debug
    return
  fi
  if ! grep -Eq '\.(dylib|framework)' <<<"$otool_out"; then
    echo unknown
    return
  fi
  echo release
}

# The script always runs detached (nohup … >/dev/null 2>&1 &), so a log line alone is
# invisible — the operator just sees nothing happen. Used for both a refusal AND an
# FD_SWAP_ALLOW_DEBUG override that proceeds anyway, so the title is always passed in
# explicitly ($2) rather than assumed — a hardcoded "refused" title on the override path
# would read as "nothing happened" while a Debug bundle installs anyway, which is worse than
# no notification. This is best-effort: a failing osascript (no GUI session, notifications
# disabled, etc.) is logged and swallowed, never allowed to turn either path into a crash.
# Notifications are not the safety mechanism — the exit before staging is, on the refusal
# path — this just makes the outcome audible either way.
notify() {
  if ! osascript -e "display notification \"$1\" with title \"$2\"" >>"$LOG" 2>&1; then
    log "warning: osascript notification failed, see above — the underlying decision still stands"
  fi
}

# Post-order walk: children are printed before their parent, so signalling in order
# takes the leaves (claude, zsh, login) down before the app that owns them and nothing
# is left reparented to launchd.
descendants() {
  local pid="$1" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null); do
    descendants "$kid"
    echo "$kid"
  done
}

log "=== swap starting (pid $$), waiting ${DELAY}s before quitting the app ==="
log "new bundle:  $NEW_APP"
log "installed:   $INSTALLED"
log "backup dir:  $BACKUP_DIR"

# --- 0. Verify the new bundle BEFORE touching anything installed -----------------------
# Verification must NEVER execute the bundle. Flight Deck has no argv parsing — argv goes
# straight to ghostty_init (GhosttyApp.swift) — so an unknown flag like `--help` does not
# print usage and exit non-zero. It boots a full second instance of the app, which restores
# the session store and spawns a duplicate `claude --resume` for every session. Those
# duplicates collide in Claude Code's pid-keyed name registry (~/.claude/sessions/<pid>.json),
# which is why renaming a tab started returning suffixed names like `Crashing-valiant-quilt`.
# Worse, the probe never returns, so the script wedged here and the swap never happened.
# Everything below is a static check on the bundle: no exec, no launch.
if [ ! -x "$NEW_APP/Contents/MacOS/Flight Deck" ]; then
  log "FATAL: new bundle missing or has no executable — aborting, nothing changed."
  exit 1
fi
if [ ! -f "$NEW_APP/Contents/Info.plist" ]; then
  log "FATAL: new bundle has no Info.plist — aborting, nothing changed."
  exit 1
fi
if ! codesign --verify --strict "$NEW_APP" >>"$LOG" 2>&1; then
  log "FATAL: new bundle fails codesign --verify — aborting, nothing changed."
  exit 1
fi
# 2026-09-22 incident: a Debug bundle got swapped into /Applications. Debug and Release key
# their fd-abduco daemon root differently (/tmp/flight-deck-debug-501 vs /tmp/flight-deck-501)
# while sessions.json is shared, so the Debug app restored all 55 sessions and attached each
# one to stale debug-root daemon leftovers — every conversation looked like it had lost its
# last several turns. The executable/Info.plist/codesign checks above all passed; none of them
# can tell Debug from Release. This is what bundle_flavor() exists to catch.
FLAVOR="$(bundle_flavor "$NEW_APP")"
case "$FLAVOR" in
  release) FLAVOR_DISPLAY="Release" ;;
  debug) FLAVOR_DISPLAY="Debug" ;;
  unknown) FLAVOR_DISPLAY="unknown" ;;
  # bundle_flavor() only returns the three cases above today; this exists so a future fourth
  # value degrades to showing itself instead of leaving FLAVOR_DISPLAY unbound under set -u.
  *) FLAVOR_DISPLAY="$FLAVOR" ;;
esac
log "flavor:      $FLAVOR_DISPLAY (verified statically, not executed)"

# unknown (otool missing, or otool -L failed) is refused exactly like debug, via the same
# FD_SWAP_ALLOW_DEBUG escape hatch — a second override variable would just be a second way
# to get this wrong. It gets its own wording throughout: calling an undetermined bundle
# "Debug" would be its own kind of wrong and would send the next person down the wrong path.
if [ "$FLAVOR" != "release" ] && [ "${FD_SWAP_ALLOW_DEBUG:-}" != "1" ]; then
  if [ "$FLAVOR" = "unknown" ]; then
    log "FATAL: could not determine build flavor (otool unavailable or unreadable) — refusing, nothing changed."
    notify "Refused to install a bundle of unknown flavor — nothing changed" "Flight Deck swap refused"
  else
    log "FATAL: new bundle is $FLAVOR_DISPLAY, not Release — aborting, nothing changed."
    notify "Refused to install a $FLAVOR_DISPLAY bundle — nothing changed" "Flight Deck swap refused"
  fi
  exit 1
fi
if [ "$FLAVOR" != "release" ]; then
  if [ "$FLAVOR" = "unknown" ]; then
    log "FD_SWAP_ALLOW_DEBUG=1 — installing a bundle of unknown flavor anyway, override recorded"
    notify "Installing a bundle of unknown flavor — FD_SWAP_ALLOW_DEBUG override in effect" "Flight Deck swap proceeding (override)"
  else
    log "FD_SWAP_ALLOW_DEBUG=1 — installing a $FLAVOR_DISPLAY bundle anyway, override recorded"
    notify "Installing a $FLAVOR_DISPLAY bundle — FD_SWAP_ALLOW_DEBUG override in effect" "Flight Deck swap proceeding (override)"
  fi
fi

# Safe test harness for the guard above and a real operator pre-flight: runs every check in
# this block and stops before anything is touched. The accept path can't otherwise be
# exercised by actually running the script — a completed run quits Flight Deck and drops
# every live agent session on the machine — which is exactly why this mode exists.
if [ "${FD_SWAP_CHECK_ONLY:-}" = "1" ]; then
  log "FD_SWAP_CHECK_ONLY=1 — bundle accepted, exiting before staging (nothing changed)"
  exit 0
fi

log "new bundle verified (executable + Info.plist + codesign), without launching it"

sleep "$DELAY"

# --- 1. Stage the new bundle alongside the old one -------------------------------------
# Done before the app is quit, so the window with no usable app in /Applications is as
# short as possible. ditto (not cp -R) preserves bundle metadata and extended attributes.
rm -rf "$STAGING"
if ! ditto "$NEW_APP" "$STAGING"; then
  log "FATAL: ditto to staging failed — aborting, nothing changed."
  rm -rf "$STAGING"
  exit 1
fi
log "staged new bundle at $STAGING"

# --- 2. Quit every running instance ------------------------------------------------------
# This kills the Claude session that launched this script. Everything after this line runs
# orphaned, reparented to launchd.
PIDS="$(find_pids)"
# HINT_PID is the app pid observed at arming time, passed in by the caller. Used only as a
# fallback in case the ps/awk lookup comes up empty; verified live with `kill -0` first so a
# recycled pid cannot be signalled by mistake.
HINT_PID="${2:-}"
if [ -z "$PIDS" ] && [ -n "$HINT_PID" ] && kill -0 "$HINT_PID" 2>/dev/null; then
  log "ps lookup found nothing; falling back to hint pid $HINT_PID"
  PIDS="$HINT_PID"
fi

# Whether to relaunch at the end. Only relaunch an app that was actually running when we
# started — this script must not spring a Flight Deck window on a machine where the user
# had deliberately quit it.
WAS_RUNNING=0

if [ -z "$PIDS" ]; then
  log "app does not appear to be running; skipping quit (will not relaunch)"
else
  WAS_RUNNING=1
  log "quitting Flight Deck (pids: $PIDS)"

  # Collect descendants (login → zsh → claude) before the parents die, otherwise they
  # reparent to launchd and we lose the ability to find them by ancestry.
  KIDS=""
  for p in $PIDS; do KIDS="$KIDS $(descendants "$p")"; done
  log "descendant processes to reap:${KIDS:- none}"

  # SIGTERM first, but session state is safe even against the SIGKILL below: SessionStore
  # persists on every mutation (selectedSessionID's didSet → persist()), not at quit time,
  # and since 2026-08-12 that write is a synchronous atomic write to
  # ~/Library/Application Support/Flight Deck/sessions.json — not UserDefaults, whose
  # coalescing cfprefsd could still be holding the last write when the app is killed.
  # Preferences DO still live in UserDefaults, so a SIGKILL can drop a just-changed pref.
  for p in $KIDS $PIDS; do kill -TERM "$p" 2>/dev/null; done

  for _ in $(seq 1 20); do
    sleep 0.5
    still="$(find_pids)"
    [ -z "$still" ] && break
  done

  still="$(find_pids)"
  if [ -n "$still" ]; then
    log "still alive after 10s, sending SIGKILL to: $still"
    for p in $still; do
      for k in $(descendants "$p"); do kill -KILL "$k" 2>/dev/null; done
      kill -KILL "$p" 2>/dev/null
    done
    sleep 2
  fi

  # Anything left from the original descendant set is now orphaned; reap it explicitly.
  for k in $KIDS; do
    if kill -0 "$k" 2>/dev/null; then
      log "reaping orphaned descendant $k"
      kill -KILL "$k" 2>/dev/null
    fi
  done
fi
log "app is down"

# --- 3. Swap ---------------------------------------------------------------------------
mkdir -p "$BACKUP_DIR"
if [ -d "$INSTALLED" ]; then
  if mv "$INSTALLED" "$BACKUP_DIR/Flight Deck.app"; then
    log "backed up previous build → $BACKUP_DIR/Flight Deck.app"
  else
    log "FATAL: could not move the installed app aside — leaving everything as-is."
    rm -rf "$STAGING"
    exit 1
  fi
fi

if mv "$STAGING" "$INSTALLED"; then
  log "installed new build at $INSTALLED"
else
  log "FATAL: could not move staged bundle into place — restoring previous build."
  mv "$BACKUP_DIR/Flight Deck.app" "$INSTALLED" 2>/dev/null && log "previous build restored."
  exit 1
fi

# --- 4. Re-register and relaunch --------------------------------------------------------
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
  -f "$INSTALLED" >/dev/null 2>&1
log "re-registered with LaunchServices"

sleep 1
# The ONLY place this script launches the app, and it launches $INSTALLED — never $NEW_APP.
# Running a DerivedData bundle directly is what created a second live app instance.
if [ "$WAS_RUNNING" -eq 1 ]; then
  if open "$INSTALLED"; then
    log "relaunched."
  else
    log "WARNING: relaunch failed — open \"$INSTALLED\" by hand."
  fi
else
  log "app was not running when the swap started; not relaunching."
fi

log "=== swap complete ==="
log "previous build kept at: $BACKUP_DIR/Flight Deck.app"
log "to roll back: rm -rf '$INSTALLED' && mv '$BACKUP_DIR/Flight Deck.app' '$INSTALLED'"
