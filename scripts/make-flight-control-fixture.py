#!/usr/bin/env python3
"""Builds the fixture backend SwarmUITests drives (L3-S Task 14).

Run by scripts/test-ui-flight-control.sh, never by the test: the UI-test bundle is sandboxed and
cannot write anywhere the app can read (see scripts/make-screenshot-fixture.py, which hit the same
wall).

<root>/
  project/             the Flight Control project; .beads/beads.db is touched on every br write
  bin/br, bin/am       stubs over <root>/state.json (one lock, one file)
  shell                the stub agent every tab runs instead of the login shell
  status/ projects/    claude's status registry and transcripts, read in place of ~/.claude
  sessions.json        one project with one plain tab (--seeded: plus a handed-off pair)
  state/               the swarms root (--seeded: a paused swarm with a hand-off)
  swarm-deps.json      fixture routing and pool slots
  reservations-held.json, guard-message.txt, contested-task   the contested scenario
  stub.log             every stub's actions
"""
import json
import os
import shutil
import stat
import sys
import uuid

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAPTURED = os.path.join(REPO, "Tests/FlightDeckTests/Fixtures/FlightControlL3/Swarm")
SPIKE_MESSAGE = ("mcp-agent-mail: file reservation conflict detected! Sources/Foo.swift conflicts with "
                 "reservation 'Sources/*.swift' held by GreenFox")
AT = "2026-10-04T18:00:00Z"


def block(kind="tests"):
    return {"v": 1, "kind": kind, "harness": "claude", "model": "opus", "knobs": {}, "pool": "claude-local",
            "source": {"by": "rule", "reason": "fixture routing", "at": AT}, "pinned": False, "host": None}


def context(kind="tests"):
    return json.dumps({"flight_deck": {"execution": block(kind)}}, sort_keys=True)


TASKS = {
    "fx-a": {"title": "Add the parser tests", "priority": 1, "description": "Cover the parser.",
             "acceptance": "- tests pass"},
    "fx-b": {"title": "Edit Sources/Foo.swift", "priority": 2, "description": "Change Foo.",
             "acceptance": "- Foo changed"},
    "fx-c": {"title": "Write the changelog", "priority": 3, "description": "Note the change.",
             "acceptance": "- changelog updated"},
}

BR = r'''#!/usr/bin/env python3
import fcntl, json, os, sys, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def opt(argv, name):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None

def row(tid, t):
    r = {"id": tid, "title": t["title"], "status": t["status"], "priority": t["priority"],
         "issue_type": "task", "assignee": t.get("assignee")}
    if t.get("agent_context"):
        r["agent_context"] = t["agent_context"]
    return r

def run(state, argv):
    tasks = state["tasks"]
    cmd = argv[0] if argv else ""
    if cmd == "ready":
        return json.dumps([row(i, t) for i, t in tasks.items() if t["status"] == "open" and not t.get("assignee")]), 0, False
    if cmd == "scheduler":
        recs = [{"rank": n + 1, "issue": {"id": i}} for n, i in enumerate(state["order"])]
        return json.dumps({"schema": "br.scheduler.v1", "recommendations": recs}), 0, False
    if cmd == "list":
        status = opt(argv, "--status")
        rows = [row(i, t) for i, t in tasks.items() if status is None or t["status"] == status]
        return json.dumps({"issues": rows, "total": len(rows), "limit": 0, "offset": 0, "has_more": False}), 0, False
    if cmd == "graph":
        return json.dumps({"components": [], "total_nodes": 0, "total_components": 0}), 0, False
    if cmd == "show" and len(argv) > 1 and argv[1] in tasks:
        t = tasks[argv[1]]
        r = row(argv[1], t)
        r["description"] = t.get("description", "")
        r["acceptance_criteria"] = t.get("acceptance", "")
        return json.dumps([r]), 0, False
    if cmd == "update" and len(argv) > 1 and argv[1] in tasks:
        t = tasks[argv[1]]
        if "--claim" in argv:
            actor = opt(argv, "--actor")
            if t.get("assignee") and t["assignee"] != actor:
                return json.dumps({"error": {"code": "VALIDATION_FAILED", "message": "already claimed", "retryable": True}}), 1, False
            t["assignee"] = actor
            t["status"] = "in_progress"
            return "{}", 0, True
        if opt(argv, "--status") is not None:
            t["status"] = opt(argv, "--status")
        if "--assignee" in argv:
            t["assignee"] = opt(argv, "--assignee") or None
        if opt(argv, "--agent-context") is not None:
            t["agent_context"] = opt(argv, "--agent-context")
        return "{}", 0, True
    if cmd == "close" and len(argv) > 1 and argv[1] in tasks:
        tasks[argv[1]]["status"] = "closed"
        return "{}", 0, True
    return "{}", 0, False

def main(argv):
    with open(os.path.join(ROOT, "state.json"), "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        state = json.load(f)
        out, code, wrote = run(state, argv)
        if wrote:
            f.seek(0); f.truncate(); json.dump(state, f)
    if wrote:
        db = os.path.join(ROOT, "project/.beads/beads.db")
        with open(db, "a"):
            pass
        os.utime(db, None)   # the Observe watcher repolls on this mtime
    with open(os.path.join(ROOT, "stub.log"), "a") as log:
        log.write("%s br %s -> %d\n" % (time.strftime("%H:%M:%S"), " ".join(argv), code))
    print(out)
    return code

sys.exit(main(sys.argv[1:]))
'''

AM = r'''#!/usr/bin/env python3
import fcntl, json, os, sys, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def run(state, argv):
    if argv[:2] == ["macros", "start-session"]:
        name = state["names"].pop(0) if state["names"] else "Agent%d" % (len(state["booted"]) + 1)
        state["booted"].append(name)
        return json.dumps({"agent": {"name": name}}), 0, True
    if argv[:2] == ["agents", "list"]:
        return json.dumps([{"name": n} for n in state["booted"]]), 0, False
    if argv[:1] == ["reservations"]:
        held = os.path.join(ROOT, "reservations-held.json")
        if state.get("contested") and os.path.exists(held):
            return open(held).read(), 0, False
        return json.dumps({"all_active": []}), 0, False
    return "{}", 0, False

def main(argv):
    with open(os.path.join(ROOT, "state.json"), "r+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        state = json.load(f)
        out, code, wrote = run(state, argv)
        if wrote:
            f.seek(0); f.truncate(); json.dump(state, f)
    with open(os.path.join(ROOT, "stub.log"), "a") as log:
        log.write("%s am %s -> %d\n" % (time.strftime("%H:%M:%S"), " ".join(argv), code))
    print(out)
    return code

sys.exit(main(sys.argv[1:]))
'''

SHELL = r'''#!/bin/bash
# The stub agent every fixture tab runs in place of the login shell. It draws claude's composer
# box (a rule, a ❯ line, a rule — ClaudeTextChannel.isComposerBox), reports a claude status file,
# echoes each prompt, closes its task through the stub br, or — for the contested task — writes
# the guard's refusal into its transcript the way a failed `git commit` tool call would.
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/stub.log"
stty dsusp undef 2>/dev/null || true   # ^Y yanks in claude; on BSD it is delayed-suspend
IFS= read -r LAUNCH                    # the claude launch/resume line FD types as initial input
SID=$(printf '%s' "$LAUNCH" | sed -nE 's/.*(--session-id|--resume) ([0-9a-f-]{36}).*/\2/p' | head -1)
echo "$(date +%T) agent $$ ${AGENT_NAME:-?} sid=$SID" >> "$LOG"
ENC=$(printf '%s' "$PWD" | sed 's/[^A-Za-z0-9]/-/g')
TRANSCRIPT="$DIR/projects/$ENC/$SID.jsonl"
mkdir -p "$(dirname "$TRANSCRIPT")" "$DIR/status"
status() {
  printf '{"pid":%d,"sessionId":"%s","status":"%s","startedAt":%s000,"cwd":"%s","procStart":"Mon Oct  5 09:00:00 2026"}' \
    $$ "$SID" "$1" "$(date +%s)" "$PWD" > "$DIR/status/$$.json.tmp" && mv "$DIR/status/$$.json.tmp" "$DIR/status/$$.json"
}
W=$(tput cols 2>/dev/null || echo 80); case "$W" in ''|*[!0-9]*) W=80;; esac
RULE=$(printf '─%.0s' $(seq 1 "$W"))
box() { printf '%s\n❯ \n%s\n' "$RULE" "$RULE"; printf '\033[2A\033[2C'; }
status idle; box
while IFS= read -r FIRST; do
  TEXT="$FIRST"
  while IFS= read -r -t 0.5 MORE; do TEXT="$TEXT"$'\n'"$MORE"; done
  printf '\n'
  # FD clears the composer first (ctrl-E ctrl-U as kitty CSI-u: ESC[5;5u ESC[21;5u) and may wrap
  # the text in bracketed-paste markers, so the first line arrives with escapes in front of it.
  # Strip CSI sequences, then any stray control byte but newline, before matching anything.
  ESC=$(printf '\033')
  TEXT=$(printf '%s' "$TEXT" | sed -E "s/${ESC}\[[0-9;?]*[A-Za-z~]//g" | tr -d '\000-\011\013-\037')
  echo "$(date +%T) agent ${AGENT_NAME:-?} prompt: ${TEXT%%$'\n'*}" >> "$LOG"
  case "$TEXT" in
    /clear*|/new*) printf '\033[2J\033[H'; status idle; box; continue ;;
  esac
  TASK=$(printf '%s' "$TEXT" | sed -nE 's/.*Your task is ([^:]+):.*/\1/p' | head -1)
  status busy
  printf '⏺ %s\n' "${TEXT%%$'\n'*}"
  if [ -n "$TASK" ]; then
    sleep 2
    if [ "$TASK" = "$(cat "$DIR/contested-task" 2>/dev/null)" ]; then
      python3 - "$TRANSCRIPT" "$DIR/guard-message.txt" <<'PY'
import json, sys
msg = open(sys.argv[2]).read().strip()
rec = {"type": "user", "message": {"role": "user", "content": [
    {"type": "tool_result", "tool_use_id": "fixture", "is_error": True, "content": "Exit code 1\n" + msg}]}}
open(sys.argv[1], "a").write(json.dumps(rec) + "\n")
PY
      printf 'commit blocked by the reservation guard\n'
    else
      "$DIR/bin/br" close "$TASK" >/dev/null
      printf 'closed %s\n' "$TASK"
    fi
  fi
  status idle; box
done
'''


def write_executable(path, body):
    with open(path, "w") as handle:
        handle.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def guard_message():
    path = os.path.join(CAPTURED, "guard-block.txt")
    if os.path.exists(path):
        # The whole block, not one line: the guard wraps, and the file, pattern and holder AgentOutputScan
        # needs are on the line after the "conflict detected!" marker.
        text = open(path).read().strip()
        if "file reservation conflict detected" in text:
            return text
    return SPIKE_MESSAGE


def session(sid, title, cwd):
    return {"id": sid, "title": title, "workingDirectory": cwd, "transcriptDirectory": cwd,
            "pinnedConversationID": sid, "activity": "idle", "unread": False}


def main(root, seeded):
    if os.path.exists(root):
        real = os.path.realpath(root)
        safe = ("/DerivedData/", "/tmp/", "/private/tmp/", "/var/folders/", "/.fd-l3s-fixture.")
        if not any(marker in real + "/" for marker in safe):
            sys.exit("refusing to delete %s: not under DerivedData or a temp directory" % real)
        shutil.rmtree(root)
    project = os.path.join(root, "project")
    for d in ("bin", "status", "projects", "state", "project/.beads"):
        os.makedirs(os.path.join(root, d))
    open(os.path.join(project, ".beads/beads.db"), "w").close()
    with open(os.path.join(project, "AGENTS.md"), "w") as handle:
        handle.write("# Fixture project\n")

    tasks = {}
    for tid, t in TASKS.items():
        tasks[tid] = dict(t, status="open", assignee=None, agent_context=context())
    names = ["BlueLake", "RedStone", "GoldViper", "SilverPine"]
    state = {"tasks": tasks, "order": list(TASKS), "names": names, "booted": [], "contested": True}

    sessions = [session(str(uuid.uuid4()), "planning", project)]
    if seeded:
        old, new = str(uuid.uuid4()), str(uuid.uuid4())
        sessions += [session(old, "swarm old", project), session(new, "swarm new", project)]
        state["booted"] = ["BlueLake", "GreenFox"]
        tasks["fx-a"]["status"] = "in_progress"
        tasks["fx-a"]["assignee"] = "GreenFox"
        state["contested"] = False

        def agent(sid, name, st, task, frm=None, to=None):
            a = {"session": sid, "agentName": name, "config": "claude|opus||claude-local", "block": context(),
                 "state": st, "excludedFromReuse": False, "stateSince": AT}
            if task: a["task"] = task
            if st == "handedOff": a["lastTask"] = "fx-a"
            if frm: a["handedOffFrom"] = frm
            if to: a["handedOffTo"] = to
            return a
        swarm = {"id": str(uuid.uuid4()), "project": project, "cap": 2, "poolCaps": {}, "filter": {"allReady": True},
                 "state": "paused", "createdAt": AT, "waiting": [], "unroutable": [], "spawnFailures": {},
                 "agents": [agent(old, "BlueLake", "handedOff", None, to=new),
                            agent(new, "GreenFox", "working", "fx-a", frm=old)]}
        with open(os.path.join(root, "state/swarms.json"), "w") as handle:
            json.dump({"v": 1, "swarms": [swarm]}, handle)

    with open(os.path.join(root, "state.json"), "w") as handle:
        json.dump(state, handle)
    with open(os.path.join(root, "sessions.json"), "w") as handle:
        json.dump({"sessions": sessions, "projects": [{"path": project, "isCollapsed": False}],
                   "selectedSessionID": sessions[0]["id"], "sessionCounter": len(sessions)}, handle)
    with open(os.path.join(root, "swarm-deps.json"), "w") as handle:
        json.dump({"pools": {"claude-local": 3}, "routing": {"harness": "claude", "model": "opus", "pool": "claude-local"}}, handle)

    held = os.path.join(CAPTURED, "am-reservations-held.json")
    if os.path.exists(held):
        shutil.copy(held, os.path.join(root, "reservations-held.json"))
    with open(os.path.join(root, "guard-message.txt"), "w") as handle:
        handle.write(guard_message() + "\n")
    with open(os.path.join(root, "contested-task"), "w") as handle:
        handle.write("fx-b")

    write_executable(os.path.join(root, "bin/br"), BR)
    write_executable(os.path.join(root, "bin/am"), AM)
    write_executable(os.path.join(root, "shell"), SHELL)
    print("fixture at %s (%s)" % (root, "seeded" if seeded else "live"))


if __name__ == "__main__":
    main(sys.argv[1], "--seeded" in sys.argv[2:])
