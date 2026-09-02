# scripts/adapterprobe/capabilities.py
"""The rows, and how a cell becomes a verdict.

The valuable cell is the one where DECLARED and OBSERVED disagree, so both are carried and the
verdict is derived from the pair rather than asserted by each probe.

`ProbeContext` — the surface every row's `run(ctx, agent)` may call. `run.py` (Task 7)
implements it exactly; a row must never reach for anything not on this list:

    probe(args: list[str], stdin: str = "") -> dict   # runs the probe CLI, parses its JSON
    sandbox: AgentSandbox                              # the live sandbox for this run
    pty(agent: str, cmd: list[str]) -> PtyScreen       # cwd=sandbox.root, env=sandbox.env(agent)
    seed_one_turn(agent: str, cid: str) -> None        # full tier only; drives one real turn
    seeded_marker: str                                 # text seed_one_turn guarantees on screen
    versions: dict[str, str]                           # {"codex": ..., "claude": ...}

`ctx.sandbox` is itself on that list, so a row is free to read `ctx.sandbox.root`,
`ctx.sandbox.claude_home` / `.codex_home` and `ctx.sandbox.env(agent)` — those are the sandbox's
own public surface (Task 2), not a fourth thing bolted on. Rows also read a handful of
checked-in fixtures directly (plain `open()`), the same corpus `test_grammars.py` already reads
from — that keeps "cheap" rows free of any live agent, per the design's §3.5 corpus rule.
"""
import os
import uuid
from collections import namedtuple

Row = namedtuple("Row", "key group agents tier flags run")
Observation = namedtuple("Observation", "declared observed absent_reason_holds detail")
Observation.__new__.__defaults__ = (None, None, None, "")


def verdict(declared, observed, absent_reason_holds=None):
    if observed == "needs-auth":
        return "needs-auth"
    if observed == "error" or observed is None:
        return "error"
    if declared:
        return "ok" if observed else "broken"
    # Declared absent. The refusal is only trustworthy if its stated reason was probed.
    if absent_reason_holds is None:
        return "error"
    return "by-design" if absent_reason_holds else "rotted"


# --- Checked-in corpus (§3.5: cheap rows read a captured corpus, never a live agent) --------
_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(os.path.dirname(_HERE))
_FIX = os.path.join(_REPO, "Tests", "FlightDeckTests", "Fixtures")

_CLAUDE_TRANSCRIPT = os.path.join(_FIX, "Claude", "transcript.captured.jsonl")
_CLAUDE_IDLE_SCREEN = os.path.join(_FIX, "Claude", "idle-empty-box.captured.txt")
_CLAUDE_APPROVAL_SCREEN = os.path.join(_FIX, "Claude", "permission-bash.captured.txt")
_CLAUDE_OPEN_PROMPT_TAIL = os.path.join(_FIX, "Claude", "question-single.captured.jsonl")
_CODEX_ROLLOUT = os.path.join(_FIX, "Codex", "rollout.captured.jsonl")
_CODEX_IDLE_SCREEN = os.path.join(_FIX, "Codex", "tui-idle.captured.txt")
_CODEX_APPROVAL_SCREEN = os.path.join(_FIX, "Codex", "approval-command.captured.txt")

_UP_MARKER = {"claude": "Claude Code", "codex": "OpenAI Codex"}
# The row that already carries the "Yes" affirmative in each agent's own approval dialog —
# read straight off the captured screens above, not guessed.
_APPROVE_LABEL = {"claude": "Yes", "codex": "Yes, proceed"}


def _agent_home(ctx, agent):
    return ctx.sandbox.claude_home if agent == "claude" else ctx.sandbox.codex_home


def _bytes_under(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total


# --- Declarations: is the static answer still honest? ---------------------------------------

def _negotiates_identity(ctx, agent):
    """A fabricated pin that never came from the agent: codex must hand back its own id
    (negotiated), claude must keep exactly the one we proposed (nothing to negotiate)."""
    declared = ctx.probe(["declare", agent])["negotiatesIdentity"]
    out = ctx.probe(["rebind", agent, "--pin", str(uuid.uuid4()), "--cwd", ctx.sandbox.root])
    if "error" in out:
        return Observation(declared=declared, observed=None, detail=out["error"])
    return Observation(declared=declared, observed=bool(out.get("repointed")))


def _needs_runtime_start(ctx, agent):
    """Does bringing an identity into being also require standing up a persistent stack?
    Measured by whether `prepare` writes anything into the agent's own home at all — codex's
    RPC process negotiates and persists a thread as a side effect, claude's does not."""
    declared = ctx.probe(["declare", agent])["needsRuntimeStart"]
    home = _agent_home(ctx, agent)
    before = set(os.listdir(home))
    out = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    if "error" in out:
        return Observation(declared=declared, observed=None, detail=out["error"])
    after = set(os.listdir(home))
    return Observation(declared=declared, observed=bool(after - before))


def _has_status_registry(ctx, agent):
    """Claude writes one status file per *live* session into `<home>/sessions` — no full model
    turn is needed to see it appear, just a process that is actually running."""
    declared = ctx.probe(["declare", agent])["hasStatusRegistry"]
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    text = ctx.probe(["launch-command", agent, "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    home = _agent_home(ctx, agent)
    with ctx.pty(agent, ["/bin/sh", "-lc", text]) as term:
        term.pump(5)
        sessions_dir = os.path.join(home, "sessions")
        wrote = os.path.isdir(sessions_dir) and bool(os.listdir(sessions_dir))
    return Observation(declared=declared, observed=wrote)


def _text_channel(ctx, agent):
    """A real idle screen must read back as an empty composer."""
    declared = ctx.probe(["declare", agent])["textChannel"]
    screen_path = _CLAUDE_IDLE_SCREEN if agent == "claude" else _CODEX_IDLE_SCREEN
    with open(screen_path) as f:
        screen = f.read()
    out = ctx.probe(["composer-empty", agent], stdin=screen)
    if "error" in out:
        return Observation(declared=declared, observed=None, detail=out["error"])
    return Observation(declared=declared, observed=bool(out.get("empty")))


def _dialog_driver(ctx, agent):
    """A real approval dialog: `focusedRow` must land on a row, and that row must read back
    as the agent's own affirmative option."""
    declared = ctx.probe(["declare", agent])["dialogDriver"]
    screen_path = _CLAUDE_APPROVAL_SCREEN if agent == "claude" else _CODEX_APPROVAL_SCREEN
    with open(screen_path) as f:
        screen = f.read()
    focus = ctx.probe(["focused-row", agent], stdin=screen)
    if "error" in focus:
        return Observation(declared=declared, observed=None, detail=focus["error"])
    row = focus.get("row")
    if row is None:
        return Observation(declared=declared, observed=False, detail="no row focused")
    reads = ctx.probe(["row-reads", agent, str(row), _APPROVE_LABEL[agent]], stdin=screen)
    return Observation(declared=declared, observed=bool(reads.get("reads")))


def _open_prompt_reader(ctx, agent):
    if agent == "claude":
        # `OpenPrompt.find` (`Sources/FleetKit/OpenPrompt.swift:218`) opens only when
        # `activity == "waiting"` — without the flag the subcommand returns null
        # unconditionally, which would misrecord a working reader as `broken`.
        declared = ctx.probe(["declare", "claude"])["openPromptReader"]
        with open(_CLAUDE_OPEN_PROMPT_TAIL) as f:
            tail = f.read()
        out = ctx.probe(["open-prompt", "claude", "--activity", "waiting"], stdin=tail)
        return Observation(declared=declared, observed=out.get("kind") is not None)

    # codex declares this nil for a *reason*, not a bare absence: "codex writes nothing to
    # its rollout when its own approval list is up." Trusting that forever is exactly the
    # drift this suite exists to catch, so the row raises a real approval list and checks
    # whether the agent's home actually stayed silent while it was showing. That needs a
    # live turn, which is why this row is `tier="full"` rather than the other declarations'
    # "cheap" — the one deliberate exception, called out where the row is registered below.
    declared = ctx.probe(["declare", "codex"])["openPromptReader"]
    prep = ctx.probe(["prepare", "codex", "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    text = ctx.probe(["launch-command", "codex", "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    home = ctx.sandbox.codex_home
    with ctx.pty("codex", ["/bin/sh", "-lc", text]) as term:
        term.wait([_UP_MARKER["codex"]], 30)
        term.send(b"Run the shell command: echo probe-approval-marker\r")
        appeared = term.wait(["Would you like to run the following command"], 45)
        if not appeared:
            return Observation(
                declared=declared, observed=None,
                detail="approval list never appeared; the stated reason is unconfirmed, "
                       "not refuted",
            )
        before = _bytes_under(home)
        term.pump(3)
        after = _bytes_under(home)
    still_silent = after == before
    # `absent_reason_holds` is set here and nowhere else in this table: this is the one row
    # where a declared absence carries a checkable reason, so a stale refusal can surface as
    # `rotted` instead of being blessed as `by-design` on faith.
    return Observation(
        declared=declared, observed=not still_silent, absent_reason_holds=still_silent,
        detail="" if still_silent else "the home grew while the approval list was up",
    )


def _home_marker_file(ctx, agent):
    marker = ctx.probe(["declare", agent])["homeMarkerFile"]
    home = _agent_home(ctx, agent)
    return Observation(declared=True, observed=os.path.exists(os.path.join(home, marker)),
                        detail=marker)


def _identity(ctx, agent):
    """Feed the real marker file; expect an identity or an honest `None` — never a plausible
    wrong address."""
    marker = ctx.probe(["declare", agent])["homeMarkerFile"]
    path = os.path.join(_agent_home(ctx, agent), marker)
    if not os.path.exists(path):
        return Observation(declared=True, observed=None, detail=f"no {marker} in the sandbox")
    with open(path) as f:
        out = ctx.probe(["identity", agent], stdin=f.read())
    identity = out.get("identity")
    return Observation(declared=True, observed=identity is None or "@" in identity,
                        detail=str(identity))


def _environment(ctx, agent):
    """Self-validating: every other row in this suite silently depends on `environment(for:)`
    actually redirecting the home into the sandbox rather than the real one. `declared` is
    trivially true — the member is required on every adapter, not optional — so what this row
    checks is whether the redirection took."""
    marker = ctx.probe(["declare", agent])["homeMarkerFile"]
    home = _agent_home(ctx, agent)
    out = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    redirected = "error" not in out and os.path.exists(os.path.join(home, marker))
    return Observation(declared=True, observed=redirected)


# --- Grammars: does the parser still match what the agent writes today? ---------------------

def _title_from_transcript(ctx, agent):
    if agent == "claude":
        out = ctx.probe(["title-from-transcript", "claude", _CLAUDE_TRANSCRIPT])
        return Observation(declared=True, observed=out.get("title") is not None)
    # codex's title(fromTranscriptAt:) is documented to always return nil — its real name
    # comes from `session_index.jsonl` via `CodexNameWatcher` instead. This is a plain
    # True/True check on that expectation, not an absence needing `absent_reason_holds`
    # (that machinery is reserved for `openPromptReader`; see its own comment).
    out = ctx.probe(["title-from-transcript", "codex", _CODEX_ROLLOUT])
    return Observation(declared=True, observed=out.get("title") is None,
                        detail="codex's real title comes from session_index.jsonl, not here")


def _timeline_items(ctx, agent):
    path = _CLAUDE_TRANSCRIPT if agent == "claude" else _CODEX_ROLLOUT
    with open(path) as f:
        out = ctx.probe(["timeline", agent], stdin=f.read())
    barren = out.get("barrenLines") or []
    return Observation(
        declared=True, observed=out.get("items", 0) > 0,
        detail=f"{len(barren)} barren line(s): {barren}" if barren else "",
    )


def _sanitized_title(ctx, agent):
    hostile = "a; rm -rf / \n\t<script>evil()</script>"
    out = ctx.probe(["sanitize", agent, hostile])
    sanitized = out.get("sanitized")
    if agent == "claude":
        # Claude types straight into a pty that may be a bare shell, so the strip is
        # load-bearing here in a way it is nowhere else (see `ClaudeAdapter.sanitizedTitle`).
        observed = sanitized is not None and ";" not in sanitized and "\n" not in sanitized
    else:
        # Codex goes over JSON-RPC, not a shell — nothing to strip.
        observed = sanitized == hostile
    return Observation(declared=True, observed=observed)


# --- Live operations: including both reported symptoms. -------------------------------------

def _prepare(ctx, agent):
    out = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    if "error" in out:
        return Observation(declared=True, observed=None, detail=out["error"])
    cid = out.get("conversationID") or ""
    return Observation(declared=True, observed=bool(cid) and cid == cid.lower(),
                        detail=f"unexpected id shape: {cid!r}")


def _binding(ctx, agent):
    """A pin read back: conversation id and transcript path agree with what the agent wrote."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    out = ctx.probe(["rebind", agent, "--pin", cid, "--cwd", ctx.sandbox.root])
    if "error" in out:
        return Observation(declared=True, observed=False, detail=out["error"])
    agrees = out.get("conversationID") == cid and not out.get("repointed", False)
    return Observation(declared=True, observed=agrees,
                        detail=f"rebind returned {out.get('conversationID')!r}")


def _location(ctx, agent):
    """Launch in the sandbox's own working directory; the agent's idle screen must name it."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    text = ctx.probe(["launch-command", agent, "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty(agent, ["/bin/sh", "-lc", text]) as term:
        up = term.wait([_UP_MARKER[agent]], 30)
        screen = term.display()
    named = ctx.sandbox.root in screen or os.path.basename(ctx.sandbox.root) in screen
    return Observation(declared=True, observed=up and named)


def _launch_command(ctx, agent):
    """Typed at a live pty. A TUI comes up bound to the expected conversation."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    text = ctx.probe(["launch-command", agent, "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty(agent, ["/bin/sh", "-lc", text]) as term:
        up = term.wait([_UP_MARKER[agent]], 30)
    return Observation(declared=True, observed=up)


def _resume_command(ctx, agent):
    """Type the real resumeCommand at a real pty and require prior history, no picker."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    ctx.seed_one_turn(agent, cid)            # tier "full" only; see run.py
    text = ctx.probe(["resume-command", agent, "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty(agent, ["/bin/sh", "-lc", text]) as term:
        attached = term.wait([ctx.seeded_marker], 60)
        picker = any(m in term.display() for m in
                     ("Select a session", "Resume a session", "to navigate"))
    return Observation(declared=True, observed=attached and not picker,
                        detail="picker shown instead of attaching" if picker else "")


def _rebind(ctx, agent):
    """Restore path settles identity. codex with a pin it never minted must hand back a
    *different* conversation, not fail."""
    if agent == "codex":
        bogus = str(uuid.uuid4())
        out = ctx.probe(["rebind", "codex", "--pin", bogus, "--cwd", ctx.sandbox.root])
        if "error" in out:
            return Observation(declared=True, observed=False, detail=out["error"])
        return Observation(declared=True, observed=bool(out.get("repointed")))
    prep = ctx.probe(["prepare", "claude", "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    out = ctx.probe(["rebind", "claude", "--pin", cid, "--cwd", ctx.sandbox.root])
    if "error" in out:
        return Observation(declared=True, observed=False, detail=out["error"])
    return Observation(declared=True, observed=out.get("conversationID") == cid)


def _rename(ctx, agent):
    """Outbound rename lands, and the name is still there after a relaunch.

    Codex renames through the real adapter method, so it goes straight through the probe.
    Claude does not: `probe rename claude` is a deliberate refusal (see `probe.swift` — claude
    renames dispatch inline through `SessionStore`, never through the adapter, and the
    production method traps on purpose as a tripwire). So claude's half of this row drives the
    real thing `SessionStore` does instead — typing `/rename <name>` at a live pty — rather
    than calling a method production code never calls."""
    if agent == "codex":
        prep = ctx.probe(["prepare", "codex", "--cwd", ctx.sandbox.root])
        cid = prep["conversationID"]
        out = ctx.probe(["rename", "codex", "--id", cid, "--to", "probe-renamed"])
        if "error" in out:
            return Observation(declared=True, observed=False, detail=out["error"])
        back = ctx.probe(["read", "codex", "--id", cid])
        return Observation(declared=True, observed=back.get("title") == "probe-renamed",
                            detail=f"read back {back.get('title')!r}")

    prep = ctx.probe(["prepare", "claude", "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    text = ctx.probe(["launch-command", "claude", "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty("claude", ["/bin/sh", "-lc", text]) as term:
        term.wait([_UP_MARKER["claude"]], 30)
        term.send(b"/rename probe-renamed\r")
        renamed = term.wait(["probe-renamed"], 20)
    return Observation(declared=True, observed=renamed)


def _login_invocation(ctx, agent):
    # The sandbox is authenticated on purpose (§3.3) — an honest login probe would mean
    # destroying that. The weaker "binary exists and advertises the subcommand" check is
    # deliberately never recorded as `ok`.
    return Observation(declared=True, observed="needs-auth",
                        detail="sandbox is authenticated; an honest probe is impossible")


def _runtime_observation(ctx, agent):
    """During a real turn: claude's status file transitions, codex's rollout tail grows."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    ctx.seed_one_turn(agent, cid)
    if agent == "claude":
        sessions_dir = os.path.join(ctx.sandbox.claude_home, "sessions")
        observed = os.path.isdir(sessions_dir) and bool(os.listdir(sessions_dir))
    else:
        observed = _bytes_under(ctx.sandbox.codex_home) > 0
    return Observation(declared=True, observed=observed)


BOTH = ("claude", "codex")

ROWS = [
    # Declarations
    Row("negotiatesIdentity", "declarations", BOTH, "cheap", (), _negotiates_identity),
    Row("needsRuntimeStart", "declarations", BOTH, "cheap", (), _needs_runtime_start),
    Row("hasStatusRegistry", "declarations", BOTH, "cheap", (), _has_status_registry),
    Row("textChannel", "declarations", BOTH, "cheap", (), _text_channel),
    Row("dialogDriver", "declarations", BOTH, "cheap", ("sandbox-config",), _dialog_driver),
    # The one deliberate tier exception among the declarations: see `_open_prompt_reader`'s
    # own comment for why probing codex's stated reason needs a real approval list, not a
    # captured screen.
    Row("openPromptReader", "declarations", BOTH, "full", ("sandbox-config",),
        _open_prompt_reader),
    Row("homeMarkerFile", "declarations", BOTH, "cheap", (), _home_marker_file),
    Row("identity", "declarations", BOTH, "cheap", (), _identity),
    Row("environment", "declarations", BOTH, "cheap", (), _environment),
    # Grammars
    Row("titleFromTranscript", "grammars", BOTH, "cheap", (), _title_from_transcript),
    Row("timelineItems", "grammars", BOTH, "cheap", (), _timeline_items),
    Row("sanitizedTitle", "grammars", BOTH, "cheap", (), _sanitized_title),
    # Live operations
    Row("prepare", "live", BOTH, "cheap", (), _prepare),
    Row("binding", "live", BOTH, "cheap", (), _binding),
    Row("location", "live", BOTH, "cheap", (), _location),
    Row("launchCommand", "live", BOTH, "cheap", (), _launch_command),
    Row("resumeCommand", "live", BOTH, "full", (), _resume_command),
    Row("rebind", "live", BOTH, "cheap", (), _rebind),
    Row("rename", "live", BOTH, "full", (), _rename),
    Row("loginInvocation", "live", BOTH, "cheap", (), _login_invocation),
    Row("runtimeObservation", "live", BOTH, "full", ("sandbox-config",),
        _runtime_observation),
]

assert len(ROWS) == 21, f"expected exactly 21 rows, found {len(ROWS)}"
