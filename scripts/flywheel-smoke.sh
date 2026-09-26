#!/usr/bin/env bash
# flywheel-smoke.sh — on-demand, real-agent smoke harness for Flywheel integration.
#
# Proves the thing the spike could only simulate: two Flight-Deck-spawned agents in
# ONE flywheel repo get distinct AGENT_NAMEs, and the reservation guard actually
# blocks a conflicting commit between them (not just a synthetic CLI call).
#
# NOT wired into CI. Never run this unattended:
#   - it spawns real coding agents (claude tabs) → burns real tokens
#   - it drives Flight Deck's GUI → steals focus while it runs
# The operator does the FD/agent steps by hand; this script only sets up the
# isolated scratch repo and verifies the substrate afterward.
#
# Usage:
#   FLYWHEEL_SMOKE=1 scripts/flywheel-smoke.sh [setup]     # default: setup
#   FLYWHEEL_SMOKE=1 scripts/flywheel-smoke.sh verify <scratch-repo>
#   FLYWHEEL_SMOKE=1 scripts/flywheel-smoke.sh teardown <scratch-repo>
#
# See docs/FLYWHEEL-SMOKE-CHECKLIST.md for the full human runbook.
set -euo pipefail

say(){ printf '\n\033[1m» %s\033[0m\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
pass(){ printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail(){ printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

if [ "${FLYWHEEL_SMOKE:-0}" != "1" ]; then
  cat >&2 <<'EOF'
flywheel-smoke.sh: refusing to run.

This harness spawns real coding agents in Flight Deck (tokens, real GUI focus
theft) — it must never run unattended or from a script/CI job. Run it
deliberately, at the terminal, once you're ready to babysit it:

  FLYWHEEL_SMOKE=1 scripts/flywheel-smoke.sh [setup|verify <repo>|teardown <repo>]
EOF
  exit 1
fi

cmd="${1:-setup}"

cmd_setup() {
  have flywheel-new || { echo "flywheel-smoke.sh: flywheel-new not on PATH" >&2; exit 1; }
  have br || { echo "flywheel-smoke.sh: br not on PATH" >&2; exit 1; }
  have am || { echo "flywheel-smoke.sh: am not on PATH" >&2; exit 1; }

  local repo
  repo="$(mktemp -d "${TMPDIR:-/tmp}/flywheel-smoke.XXXXXX")"

  say "Bootstrapping isolated scratch flywheel project"
  flywheel-new "$repo"

  say "Installing the reservation guard (flywheel-new does not do this by itself)"
  am guard install "$repo" "$repo"

  say "Creating two claimable beads"
  local id1 id2
  id1="$(cd "$repo" && br create "smoke: agent 1 task" -t task -p 2 --silent)"
  id2="$(cd "$repo" && br create "smoke: agent 2 task" -t task -p 2 --silent)"

  cat <<EOF

✅ Scratch flywheel repo ready:

    $repo

Beads for the two agents to claim:
    agent 1: $id1
    agent 2: $id2

--- Manual operator steps (in Flight Deck) -----------------------------------

1. Add "$repo" as a project in Flight Deck.
2. Project header menu → "Enable Flywheel coordination…" → confirm the setup
   dialog.
3. Spawn TWO claude tabs in that project.
4. Give agent 1 this one-line task:
     claim bead $id1 (br update $id1 --claim --actor \$AGENT_NAME), reserve
     foo.txt (am file_reservations reserve $repo \$AGENT_NAME foo.txt
     --exclusive), then edit + commit foo.txt.
5. Give agent 2 this one-line task, redirecting its commit attempt's output to
   the log this verifier reads:
     claim bead $id2 (br update $id2 --claim --actor \$AGENT_NAME), then try to
     edit + commit foo.txt, redirecting stdout+stderr of the commit to
     $repo/.smoke-agent2.log — this MUST be blocked by the guard.
6. Once both agents are done, run:
     FLYWHEEL_SMOKE=1 $0 verify "$repo"
7. When finished, run:
     FLYWHEEL_SMOKE=1 $0 teardown "$repo"

-------------------------------------------------------------------------------
EOF
}

cmd_verify() {
  local repo="${1:-}"
  [ -n "$repo" ] || { echo "flywheel-smoke.sh verify: missing <scratch-repo> argument" >&2; exit 1; }
  [ -d "$repo" ] || { echo "flywheel-smoke.sh verify: no such directory: $repo" >&2; exit 1; }
  have jq || { echo "flywheel-smoke.sh verify: jq is required to parse am/br JSON output" >&2; exit 1; }

  local overall=0

  say "Check 1/3 — two distinct AGENT_NAMEs registered"
  local agent_names agent_count
  agent_names="$(am agents list "$repo" --json 2>/dev/null | jq -r '.[].name' | sort -u || true)"
  agent_count="$(printf '%s\n' "$agent_names" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$agent_count" -ge 2 ]; then
    pass "found $agent_count distinct agent name(s): $(printf '%s' "$agent_names" | tr '\n' ' ')"
  else
    fail "expected >=2 distinct agent names, found $agent_count (am agents list $repo --json)"
    overall=1
  fi

  say "Check 2/3 — conflicting commit was blocked by the guard"
  local log="$repo/.smoke-agent2.log"
  if [ -f "$log" ] && grep -q 'mcp-agent-mail: file reservation conflict detected!' "$log" 2>/dev/null; then
    pass "guard conflict marker found in $log"
  else
    fail "guard conflict marker not found — expected agent 2's commit output redirected to $log to contain: mcp-agent-mail: file reservation conflict detected!"
    overall=1
  fi

  say "Check 3/3 — both bead claims visible, two distinct assignees"
  local issues_json in_progress_count distinct_assignees
  issues_json="$(cd "$repo" && br list --status in_progress --json 2>/dev/null || true)"
  in_progress_count="$(printf '%s' "$issues_json" | jq -r '.issues | length' 2>/dev/null || echo 0)"
  distinct_assignees="$(printf '%s' "$issues_json" | jq -r '[.issues[].assignee] | unique | length' 2>/dev/null || echo 0)"
  if [ "${in_progress_count:-0}" -ge 2 ] && [ "${distinct_assignees:-0}" -ge 2 ]; then
    pass "$in_progress_count in_progress bead(s), $distinct_assignees distinct assignee(s)"
  else
    fail "expected >=2 in_progress beads with >=2 distinct assignees, found $in_progress_count bead(s) / $distinct_assignees assignee(s) (br list --status in_progress --json, run from $repo)"
    overall=1
  fi

  say "Result"
  if [ "$overall" -eq 0 ]; then
    echo "  ALL CHECKS PASSED"
  else
    echo "  ONE OR MORE CHECKS FAILED — see above"
  fi
  return "$overall"
}

cmd_teardown() {
  local repo="${1:-}"
  [ -n "$repo" ] || { echo "flywheel-smoke.sh teardown: missing <scratch-repo> argument" >&2; exit 1; }

  say "Removing scratch repo"
  rm -rf "$repo" 2>/dev/null || true
  echo "  removed $repo"

  echo
  echo "Note: Agent Mail's project/agent registrations are global state keyed by"
  echo "path and are NOT cleaned up here — they're harmless scratch left behind"
  echo "(the path no longer resolves to a real repo). Run 'am doctor' if it ever"
  echo "needs a real cleanup."
}

case "$cmd" in
  setup)    cmd_setup ;;
  verify)   cmd_verify "${2:-}" ;;
  teardown) cmd_teardown "${2:-}" ;;
  *)
    echo "flywheel-smoke.sh: unknown command '$cmd' (expected: setup, verify <repo>, teardown <repo>)" >&2
    exit 1
    ;;
esac
