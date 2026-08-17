#!/usr/bin/env python3
"""Builds the posed deck the README screenshot is taken of.

This runs from `scripts/screenshot.sh`, NOT from the UI test, and the reason is a sandbox
boundary that is easy to rediscover the hard way. The UI-test bundle runs inside the
xctrunner's sandbox: it cannot write to the repo, and it cannot write to /private/tmp either.
The one place it can write is its own container — which the app, a separate process, is not
permitted to read. So a fixture built by the test is a fixture the app cannot open. It is
built here instead, by an ordinary unsandboxed script, and the path is handed to the test.

Everything written here is inert data. The app resolves it through its normal code paths:
`restore()` reads the snapshot, `SessionStatusWatcher` reads the status files, and
`TranscriptWatcher` reads the transcripts. No glyph is drawn by the fixture; every one of them
is derived the same way it is in a live run.
"""

import json
import os
import shutil
import stat
import sys
import time
import uuid

# Each row is (title, status, unread, subagents, waiting_for).
#
# The project names are invented on purpose. This image ships in the README of a public repo,
# so nothing here may name a real client or a private piece of work — `flight-deck` is the only
# genuine one, and it is this repo.
DECK = [
    ("flight-deck", False, [
        ("harden the release swap", "busy", False, 3, None),
        ("sidebar status icons", "waiting", False, 0,
         "permission to edit SessionStatusIcon.swift"),
        ("release notes for v0.1.0", "idle", True, 0, None),
    ]),
    ("dead-reckoning", False, [
        ("drift correction on long legs", "idle", False, 0, None),
        ("shell", "shell", False, 0, None),
    ]),
    ("semaphore", True, [
        ("deadlock under contention", "waiting", False, 0, "a decision on the lock order"),
    ]),
]

# The canned exchange the selected session's pane shows.
#
# The first three lines are not decoration. A restored session gets
# `ClaudeSession.resumeCommand` injected as initial input, so `claude --resume <uuid>` is typed
# into this shell moments after it starts. `stty -echo` stops it being echoed, the sleep lets
# it land, the clear wipes anything that arrived before the stty took effect, and the trailing
# `cat` swallows every later injection instead of printing it.
#
# The transcript itself imitates Claude Code's actual rendering rather than inventing a look:
# `⏺` before each assistant message and tool call, the tool written as `Name(argument)`, its
# result on an indented `⎿` line, a `✻` working line with elapsed time and token count, and the
# rounded input box pinned underneath. The whole point of the picture is that a session in
# Flight Deck is the harness you already run, so the pane has to be recognisable as one.
SHELL = r"""#!/bin/bash
# Silenced: this shell IS the visible terminal pane, so anything the nudge prints on the way
# past lands in the screenshot.
"$(dirname "$0")/nudge" >/dev/null 2>&1 &
stty -echo 2>/dev/null || true
sleep 1.5
printf '\033[2J\033[3J\033[H'

# The input box spans the pane, so its width is measured rather than hardcoded — a fixed box
# either falls short of the edge or wraps and tears in half.
W=$(tput cols 2>/dev/null || echo 80)
case "$W" in ''|*[!0-9]*) W=80;; esac
[ "$W" -lt 48 ] && W=80
INNER=$((W - 2))
BAR=$(printf '\342\224\200%.0s' $(seq 1 $INNER))

DIM='\033[38;5;245m'
FAINT='\033[38;5;240m'
DOT='\033[38;5;215m'
TOOL='\033[1m'
OFF='\033[0m'

printf "${DIM}>${OFF} harden the release swap so it can never run against a live app\n\n"
printf "${DOT}\342\217\272${OFF} Reading the script to see what the verify step actually does.\n\n"
printf "${DOT}\342\217\272${OFF} ${TOOL}Read${OFF}(scripts/swap-release.sh)\n"
printf "  ${DIM}\342\216\277  Read 168 lines${OFF}\n\n"
printf "${DOT}\342\217\272${OFF} Found it. The verify step executes the new bundle to check it, but\n"
printf "  Flight Deck has no argv parsing, so an unknown flag boots a second full\n"
printf "  instance instead of printing usage. That is what wedged the swap and\n"
printf "  spawned the duplicate resume processes.\n\n"
printf "${DOT}\342\217\272${OFF} ${TOOL}Agent${OFF}(static verify: codesign + Info.plist, never exec)\n"
printf "  ${DIM}\342\216\277  Running\342\200\246${OFF}\n\n"
printf "${DOT}\342\217\272${OFF} ${TOOL}Agent${OFF}(post-order descendant reap)\n"
printf "  ${DIM}\342\216\277  Running\342\200\246${OFF}\n\n"
printf "${DOT}\342\217\272${OFF} ${TOOL}Agent${OFF}(rollback path on a failed move)\n"
printf "  ${DIM}\342\216\277  Running\342\200\246${OFF}\n\n"
printf "${DOT}\342\234\273${OFF} ${DIM}Orchestrating\342\200\246 (18s \302\267 \342\206\221 2.1k tokens \302\267 esc to interrupt)${OFF}\n\n"
printf "${FAINT}\342\225\255%s\342\225\256${OFF}\n" "$BAR"
printf "${FAINT}\342\224\202${OFF} ${DIM}>${OFF} %*s${FAINT}\342\224\202${OFF}\n" $((INNER - 3)) ''
printf "${FAINT}\342\225\260%s\342\225\257${OFF}\n" "$BAR"
printf "  ${FAINT}\342\217\265\342\217\265 accept edits on${OFF}\n"

# Echo back on: Ghostty draws a padlock in the pane the whole time a tty has echo disabled
# (its password-entry indicator), and that ends up in the screenshot. The injection this was
# guarding against lands in the first second, long before here.
stty echo 2>/dev/null || true
cat > /dev/null
"""


def encoded_project_dir_name(path):
    """Mirrors ClaudeSession.encodedProjectDirName: non-alphanumerics become dashes."""
    return "".join(c if c.isascii() and c.isalnum() else "-" for c in path)


def main(root):
    if os.path.exists(root):
        shutil.rmtree(root)
    status_root = os.path.join(root, "status")
    projects_root = os.path.join(root, "projects")
    work_root = os.path.join(root, "work")
    for directory in (status_root, projects_root, work_root):
        os.makedirs(directory)

    sessions, projects, titles, deferred = [], [], [], []
    pid = 90001
    selected = None

    for name, collapsed, rows in DECK:
        # A real directory: restore() drops sessions whose working directory has gone away,
        # so a fixture pointing at invented paths restores an empty deck.
        cwd = os.path.join(work_root, name)
        os.makedirs(cwd, exist_ok=True)
        projects.append({"path": cwd, "isCollapsed": collapsed})

        for title, status, unread, subagents, waiting_for in rows:
            session_id = str(uuid.uuid4())
            conversation = str(uuid.uuid4())
            if selected is None:
                selected = session_id
            if not collapsed:
                titles.append(title)

            sessions.append({
                "id": session_id,
                "title": title,
                "workingDirectory": cwd,
                "transcriptDirectory": cwd,
                # Ties the three files together: ConversationPin.resolve matches a registry
                # row to a tab by comparing this against the status file's sessionId.
                "pinnedConversationID": conversation,
                "activity": status,
                "unread": unread,
            })

            entry = {
                "pid": pid,
                "sessionId": conversation,
                "status": status,
                "startedAt": time.time() * 1000,
                "cwd": cwd,
                "procStart": "Mon Aug 17 09:14:02 2026",
            }
            if waiting_for:
                entry["waitingFor"] = waiting_for
            with open(os.path.join(status_root, f"{pid}.json"), "w") as handle:
                json.dump(entry, handle)
            pid += 1

            if subagents:
                deferred.append((transcript_path(projects_root, cwd, conversation),
                                 transcript_record(subagents)))

    with open(os.path.join(root, "sessions.json"), "w") as handle:
        json.dump({
            "sessions": sessions,
            "projects": projects,
            "selectedSessionID": selected,
            "sessionCounter": len(sessions),
        }, handle)

    # Read by the test, so the deck is defined in exactly one place.
    with open(os.path.join(root, "expected.json"), "w") as handle:
        json.dump({"visibleTitles": titles}, handle)

    write_executable(os.path.join(root, "shell"), SHELL)
    write_executable(os.path.join(root, "nudge"), nudge_script(deferred))

    print(f"{len(sessions)} sessions across {len(projects)} projects; "
          f"{len(titles)} visible; {len(deferred)} deferred transcript(s)")


def write_executable(path, body):
    with open(path, "w") as handle:
        handle.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def transcript_path(projects_root, cwd, conversation):
    return os.path.join(
        projects_root, encoded_project_dir_name(cwd), f"{conversation.lower()}.jsonl"
    )


def transcript_record(agents):
    """A record holding `agents` unclosed Agent tool_use blocks.

    No matching tool_result and no turn_duration record, so TranscriptWatcher reports them as
    still outstanding and the row renders its spinner with a count beside it.
    """
    return json.dumps({
        "type": "assistant",
        "message": {
            "content": [
                {"type": "tool_use", "name": "Agent", "id": f"agent-{i}"}
                for i in range(agents)
            ]
        },
    })


def nudge_script(deferred):
    """Creates the transcripts a couple of seconds AFTER the app has started watching.

    They cannot simply be written at build time. `TranscriptWatcher.Scan.read` deliberately
    starts tailing an already-existing transcript from its current end — a restored session
    points at a file that may hold an entire prior conversation, and replaying it would clobber
    renames. A transcript that is absent when the watcher first looks is the opposite case:
    the watcher records that it has no history to skip, so whatever appears there later is read
    from byte 0. That is the branch this aims for.

    Launched in the background by every fixture session, so it runs several times over. Each
    file is therefore written once and only if absent, and atomically, so concurrent copies
    cannot leave a half-written record for the watcher to parse.
    """
    lines = [
        "#!/bin/bash",
        "# Generated by scripts/make-screenshot-fixture.py. See nudge_script() there.",
        "sleep 2.5",
    ]
    for path, record in deferred:
        assert "'" not in record, "single quote would break the shell quoting below"
        lines += [
            f"f='{path}'",
            'mkdir -p "$(dirname "$f")"',
            'if [ ! -f "$f" ]; then',
            # $$ so concurrent copies cannot race on one temp name: without it, two nudges can
            # both pass the -f test, both write the same "$f.tmp", and the loser's mv fails
            # with "No such file or directory" on stderr.
            f"  printf '%s\\n' '{record}' > \"$f.$$.tmp\"",
            '  mv -n "$f.$$.tmp" "$f" 2>/dev/null || rm -f "$f.$$.tmp"',
            "fi",
        ]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    main(sys.argv[1])
