# Shared by test-unit-remote.sh and smoke-remote.sh; needs their `remote` function and REMOTE_DIR.
#
# A run whose caller was killed (a tool timeout, say) dies without its EXIT trap and leaves the
# remote lock behind until the 45-minute rule breaks it, wedging every later run. The owner token
# is `[unit-]<short host>-<pid>-<time>`, so an owner from THIS Mac can be checked directly: if its
# pid is dead, the lock is orphaned and is removed at once (only if the owner file still holds
# that exact token, so a lock someone else has since taken is never touched).
break_dead_local_lock() {
  local owner rest pid host
  owner=$(remote "$REMOTE_DIR" <<<'cat "$1/.lock/owner" 2>/dev/null') || return 0
  [ -n "$owner" ] || return 0
  rest=${owner%-*}; pid=${rest##*-}; host=${rest%-*}; host=${host#unit-}
  [ "$host" = "$(hostname -s)" ] && [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null && return 0
  echo "breaking lock left by dead local run $owner" >&2
  remote "$REMOTE_DIR" "$owner" <<<'cd "$1" && [ "$(cat .lock/owner 2>/dev/null)" = "$2" ] && rm -rf .lock' || true
}

# Retries `acquire_lock_once <seconds>` for up to 20 minutes, checking for a dead local owner
# before each attempt.
acquire_lock() {
  local waited=0
  while :; do
    break_dead_local_lock
    acquire_lock_once 60 && return 0
    waited=$((waited + 60))
    [ "$waited" -ge 1200 ] && { echo "error: UI-test Mac still busy after 20 min" >&2; return 3; }
  done
}
