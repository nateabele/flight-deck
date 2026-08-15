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

NEW_APP="/Users/nate/Projects/Protos-n-Tools/flight-deck/DerivedData/Build/Products/Release/Flight Deck.app"
INSTALLED="/Applications/Flight Deck.app"
STAGING="/Applications/.Flight Deck.app.incoming"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/Users/nate/Library/Application Support/Flight Deck/backups/$TS"
LOG="/Users/nate/Library/Logs/flight-deck-swap.log"
DELAY="${1:-30}"

mkdir -p "$(dirname "$LOG")" "$BACKUP_DIR"

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
