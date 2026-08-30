#!/usr/bin/env python3
"""Fuzz the answer-drive rules against a LIVE claude TUI in a pty.

Drives real dialogs with the exact keystroke program AnswerPlan computes, checking each step
against the SAME parser the answer path uses — `ChoiceDialog.swift`, via `probe.swift` — then
reads the transcript back to check the answers claude RECORDED are the ones we asked for.
Submission is the assertion — not that keys were sent.

Unlike a plan reimplemented purely in Python, an interlock failure here means what it means in
production: the driver refused a step because the screen did not read what it expected, and
`FAIL` names exactly which step and why.
"""
import json, os, glob, re, subprocess, tempfile, time
import pty, select, fcntl, termios, struct, pyte
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
CHOICE_DIALOG = os.path.join(REPO_ROOT, "Sources/FlightDeck/ChoiceDialog.swift")
PROBE_SRC = os.path.join(HERE, "probe.swift")
PROBE_BIN = os.path.join(tempfile.gettempdir(), "livefuzz-probe")

COLS, ROWS = 136, 34
NEG = re.compile(rb"\x1b\[[<>?][0-9;]*[usmhl]")
WD = "capture-workspace"


# --- the real parser, via the probe --------------------------------------------------------

def build_probe():
    """Compile `probe.swift` against the real, unmodified `ChoiceDialog.swift`.

    Rebuilt only when either source is newer than the last binary, so a run does not pay a
    swiftc invocation per step — but a `ChoiceDialog` edit is always picked up.
    """
    if (os.path.exists(PROBE_BIN)
            and os.path.getmtime(PROBE_BIN) > os.path.getmtime(CHOICE_DIALOG)
            and os.path.getmtime(PROBE_BIN) > os.path.getmtime(PROBE_SRC)):
        return
    subprocess.run(
        ["swiftc", "-O", CHOICE_DIALOG, PROBE_SRC, "-o", PROBE_BIN],
        check=True, cwd=REPO_ROOT,
    )


def probe_focused(screen_text):
    """`ChoiceDialog.focusedRow`, or -1 when it returns nil — mirrors `probe focused`."""
    build_probe()
    out = subprocess.run([PROBE_BIN, "focused"], input=screen_text,
                          capture_output=True, text=True)
    return int(out.stdout.strip())


def probe_reads(screen_text, index, label):
    """`ChoiceDialog.row(_:reads:)` — mirrors `probe reads <N> <label...>`."""
    build_probe()
    out = subprocess.run([PROBE_BIN, "reads", str(index), label], input=screen_text,
                          capture_output=True, text=True)
    return out.stdout.strip() == "true"


# --- AnswerPlan, in Python ------------------------------------------------------------------

def action_label(is_last):
    """`AnswerPlan.actionLabel`."""
    return "Submit" if is_last else "Next"


SUBMIT_ANSWERS_LABEL = "Submit answers"  # AnswerPlan.submitAnswersLabel


def plan(questions, answers):
    """`AnswerPlan.plan`, in Python — mirrors Sources/FleetKit/AnswerPlan.swift exactly.

    Returns a list of steps, each `frm`/`to` (screen row indices) and a `purpose` tuple:
    `("option", question_index, option_index)`, `("action", question_index, is_last)`, or
    `("submit",)`. Unlike the old version this does not emit keystrokes: the drive loop decides
    those, one step at a time, only after the interlock confirms each one.
    """
    steps = []
    last = len(questions) - 1
    for qi, q in enumerate(questions):
        chosen = sorted(answers[qi])
        is_last = qi == last

        if not q["multiSelect"]:
            # One press, and the screen auto-advances.
            steps.append(dict(frm=0, to=chosen[0], purpose=("option", qi, chosen[0])))
            continue

        # Toggles. Enter does NOT advance here, so the cursor carries from one to the next.
        cursor = 0
        for option in chosen:
            steps.append(dict(frm=cursor, to=option, purpose=("option", qi, option)))
            cursor = option
        action_row = len(q["options"]) + 1  # AnswerPlan.actionRow(optionCount:)
        steps.append(dict(frm=cursor, to=action_row, purpose=("action", qi, is_last)))

    # The review screen, cursor already on "Submit answers".
    steps.append(dict(frm=0, to=0, purpose=("submit",)))
    return steps


def expected_label(step, questions):
    """`SessionStore.rowLabel` — what the row a step is about must read."""
    kind = step["purpose"][0]
    if kind == "option":
        _, qi, oi = step["purpose"]
        return questions[qi]["options"][oi]["label"]
    if kind == "action":
        _, _, is_last = step["purpose"]
        return action_label(is_last)
    return SUBMIT_ANSWERS_LABEL


# --- driving the pty -------------------------------------------------------------------------

def drive(prompt, answers, timeout=200):
    """Drive one live dialog, applying the interlock at every step.

    `answers` gives the chosen option indices per question, in transcript order — the option
    WORDING is never known up front (claude invents it), so it is read back from the transcript
    once the dialog appears, the same record `PromptQuestion` is built from in production.

    Returns `(final_screen, abort)`. `abort` names the step and reason a check failed, or is
    `None` when every step passed its interlock and Return was sent for `("submit",)`. It does
    NOT by itself mean claude recorded an answer — see `newest_result`.
    """
    os.makedirs(WD, exist_ok=True)
    # The harness reuses one throwaway workspace across every run in a batch, so a stale
    # transcript from an earlier run always exists. Only a file created at or after this run's
    # own start can be the one it just drove.
    run_started = time.time()
    screen = pyte.Screen(COLS, ROWS); stream = pyte.ByteStream(screen)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(WD); os.environ["TERM"] = "xterm-256color"
        os.environ.pop("CLAUDE_CODE_CHILD_SESSION", None)
        os.environ["CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"] = "1"
        os.execvp("claude", ["claude"])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    def pump(sec):
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if fd in r:
                try: d = os.read(fd, 65536)
                except OSError: return
                if not d: return
                stream.feed(NEG.sub(b"", d))

    def disp(): return "\n".join(screen.display)

    def wait(markers, limit):
        end = time.time() + limit
        while time.time() < end:
            pump(0.4)
            if any(m in disp() for m in markers): return True
        return False

    abort = None
    try:
        if wait(["safety check", "trust this folder"], 40): os.write(fd, b"\r"); pump(3)
        if not wait(["Claude Code v"], 60): return None, "no boot"
        pump(3); os.write(fd, prompt.encode()); pump(1.5); os.write(fd, b"\r")
        if not wait(["Enter to select", "to navigate"], timeout): return None, "no dialog"
        pump(3)

        # The tool_use write can lag the repaint by well more than a beat — observed anywhere
        # from under a second to over 30s on a loaded machine — so poll rather than reading
        # once, generously. Anything found MUST carry its own timestamp at or after
        # `run_started` (see newest_questions) — never data merely left behind by an earlier
        # run sharing this workspace. A poll that never turns up a fresh-enough record is an
        # environmental miss, not a parser refusal, and must read as one: see _stale_abort.
        questions = None
        deadline = time.time() + 45
        while time.time() < deadline:
            questions = newest_questions(since=run_started)
            if questions: break
            pump(0.5)
        if not questions:
            return disp(), _stale_abort("AskUserQuestion", run_started)

        for i, step in enumerate(plan(questions, answers)):
            label = expected_label(step, questions)

            # 1. the cursor must be where the plan believes it starts.
            focused = probe_focused(disp())
            if focused != step["frm"]:
                abort = (f"step {i} {step['purpose']}: expected focus {step['frm']}, "
                         f"saw {focused}")
                break

            # 2. the row about to be pressed must read what the plan says it should.
            if not probe_reads(disp(), step["to"], label):
                abort = f"step {i} {step['purpose']}: row {step['to']} does not read {label!r}"
                break

            # 3. move.
            distance = step["to"] - step["frm"]
            key = b"\x1b[B" if distance > 0 else b"\x1b[A"
            for _ in range(abs(distance)):
                os.write(fd, key)
            pump(0.6)

            # 4. re-read: the move must have landed exactly where the plan says.
            landed = probe_focused(disp())
            if landed != step["to"]:
                abort = (f"step {i} {step['purpose']}: expected to land on {step['to']}, "
                         f"saw {landed}")
                break

            # 5. press, and settle before the next step's checks.
            os.write(fd, b"\r")
            pump(0.8)

        pump(3)
        if abort is None:
            # Every step's interlock passed and the final Return went to the review screen's
            # "Submit answers". The recorded answer can lag that same beat behind, exactly like
            # the transcript's tool_use did above — so wait for it here, pty still open, rather
            # than closing early and risking a pending write getting dropped with it. A stale
            # OR missing result would be worse than a stale question: it would report a
            # submission that never happened, so the same fresh-timestamp requirement applies.
            deadline = time.time() + 45
            confirmed = False
            while time.time() < deadline:
                if newest_result(since=run_started):
                    confirmed = True
                    break
                pump(0.5)
            if not confirmed:
                abort = _stale_abort("tool_result", run_started)
        final = disp()
        os.write(fd, b"\x04"); pump(1)
    finally:
        try: os.close(fd)
        except OSError: pass
        try: os.waitpid(pid, os.WNOHANG)
        except ChildProcessError: pass
    return final, abort


# --- reading the transcript back ------------------------------------------------------------
#
# The workspace directory is reused run after run, so a stale transcript from an earlier run in
# the same batch always sits alongside the current one. The ONLY thing that reliably says a
# record belongs to THIS run is the record's own `timestamp` field (ISO-8601, e.g.
# "2026-08-30T21:06:03.148Z") — never a file's mtime. claude can flush and touch a transcript
# file's mtime on shutdown well after a newer run has already started, so an OLDER run's file
# can pass an `mtime >= since` test even though every record inside it predates `since`. That is
# exactly the bug this module used to have: it let a stale record through and the harness drove
# a live screen against a previous run's option labels, reporting a `row N does not read
# '<label>'` interlock refusal that was actually just reading the wrong run's questions.
#
# File mtime is kept below, but ONLY as a cheap pre-filter to limit how much needs scanning —
# never as what correctness rests on. It cannot falsely EXCLUDE a genuine match (an append always
# bumps the file's mtime to at least the record's own timestamp), so it is safe to use for
# narrowing candidates; it is unsafe to use for accepting one.

CLOCK_SLACK = 5  # seconds of tolerance for skew between this machine's clock and claude's server


def _record_timestamp(record):
    """A transcript record's own `timestamp`, as epoch seconds — or None if absent/unparseable."""
    ts = record.get("timestamp")
    if not isinstance(ts, str):
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _stale_abort(what, since):
    """The one, unmistakable abort text for 'nothing fresh enough turned up' — distinct on its
    face from a `step N (...): row X does not read '<label>'` interlock refusal, so a reader
    never has to guess whether a FAIL means the parser refused or the transcript never caught
    up. See the module docstring above: this is the fix for that exact confusion.
    """
    started = datetime.fromtimestamp(since, tz=timezone.utc).isoformat()
    return f"stale/absent transcript: no {what} record after {started}"


def _transcript_files(since=None):
    """Every transcript file for this harness's workspace, newest first.

    A cheap pre-filter only, when `since` is given — see the module note above.
    """
    d = os.path.expanduser("~/.claude/projects/" + os.path.abspath(WD).replace("/", "-"))
    files = glob.glob(d + "/*.jsonl")
    if since is not None:
        files = [f for f in files if os.path.getmtime(f) >= since]
    return sorted(files, key=os.path.getmtime, reverse=True)


def _newest_record(since, needle, matches):
    """The record with the largest OWN `timestamp` at or after `since - CLOCK_SLACK`, among
    every line in every candidate file that contains `needle` and satisfies `matches(record)`.

    Scans every candidate file in full rather than stopping at the first hit or the first few
    files by mtime: the failure this guards against is precisely a newer run's file sorting
    behind an older one, so "first found" and "most recently touched" are not trustworthy
    stand-ins for "actually newest". Returns None if nothing at or after `since` qualifies —
    callers must treat that as absence, never fall back to an older record.
    """
    best_ts, best_record = None, None
    for f in _transcript_files(since=since):
        for ln in open(f, errors="replace").read().splitlines():
            if needle not in ln: continue
            try: r = json.loads(ln)
            except Exception: continue
            ts = _record_timestamp(r)
            if ts is None or ts < since - CLOCK_SLACK: continue
            if not matches(r): continue
            if best_ts is None or ts > best_ts:
                best_ts, best_record = ts, r
    return best_record


def newest_questions(since):
    """The `questions` array off the newest `AskUserQuestion` tool_use at or after `since`.

    claude invents the option wording, so the harness cannot know it up front — and neither
    can Flight Deck, which is exactly why production reads it from this same transcript record
    (`PromptQuestion`) instead of trusting the scenario that prompted it. `since` is mandatory:
    without a floor to check each record's own timestamp against, there is no way to tell this
    run's question apart from one an earlier run in this reused workspace already asked.
    """
    def is_ask_user_question(r):
        for b in ((r.get("message") or {}).get("content") or []):
            if isinstance(b, dict) and b.get("type") == "tool_use" \
                    and b.get("name") == "AskUserQuestion":
                return True
        return False

    r = _newest_record(since, "AskUserQuestion", is_ask_user_question)
    if not r:
        return None
    for b in r["message"]["content"]:
        if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "AskUserQuestion":
            return b.get("input", {}).get("questions")
    return None


def newest_result(since):
    """The tool_result content for the newest `AskUserQuestion` at or after `since` — same
    timestamp-based staleness guard as `newest_questions`, and for the same reason it matters
    more here: a false "submitted" left over from an earlier run in this reused workspace would
    report an answer that was never actually recorded for THIS run.

    Filtered on `"type":"tool_result"`, not on the tool's own name: unlike the `tool_use` line,
    the `tool_result` line that answers it names only the `tool_use_id` it responds to, never
    "AskUserQuestion" itself — filtering for that string here finds nothing and every run reads
    as unsubmitted, control included.
    """
    def is_tool_result(r):
        for b in ((r.get("message") or {}).get("content") or []):
            if isinstance(b, dict) and b.get("type") == "tool_result":
                return True
        return False

    r = _newest_record(since, '"type":"tool_result"', is_tool_result)
    if not r:
        return None
    for b in r["message"]["content"]:
        if isinstance(b, dict) and b.get("type") == "tool_result":
            c = b.get("content")
            return c if isinstance(c, str) else json.dumps(c)
    return None
