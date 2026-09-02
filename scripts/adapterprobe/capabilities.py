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

Row = namedtuple("Row", "key group agents tier flags run kind")
Row.__new__.__defaults__ = ("capability",)   # every row is a "capability" claim unless marked
Observation = namedtuple("Observation", "declared observed absent_reason_holds detail")
Observation.__new__.__defaults__ = (None, None, None, "")


def verdict(declared, observed, absent_reason_holds=None, kind="capability"):
    if observed == "needs-auth":
        return "needs-auth"
    if observed == "error" or observed is None:
        return "error"
    if kind == "fact":
        # A symmetric boolean claim ("does this negotiate identity?"), not a capability that
        # can be absent for a reason. `False` here is not a refusal to justify — it is just
        # the other value the claim can take, and is checked exactly like `True` is.
        return "ok" if observed == declared else "broken"
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
    (negotiated), claude must keep exactly the one we proposed (nothing to negotiate). This is
    a symmetric fact, not a capability that can be absent for a reason — `kind="fact"` below."""
    declared = ctx.probe(["declare", agent])["negotiatesIdentity"]
    out = ctx.probe(["rebind", agent, "--pin", str(uuid.uuid4()), "--cwd", ctx.sandbox.root])
    if "error" in out:
        return Observation(declared=declared, observed=None, detail=out["error"])
    return Observation(declared=declared, observed=bool(out.get("repointed")))


def _needs_runtime_start(ctx, agent):
    """Does bringing an identity into being also require standing up a persistent stack?
    Measured by whether `prepare` writes anything into the agent's own home at all — codex's
    RPC process negotiates and persists a thread as a side effect, claude's does not. Also a
    symmetric fact (`kind="fact"`), not a capability with a reason to probe."""
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
    turn is needed to see it appear, just a process that is actually running. Codex's declared
    `False` is the same kind of symmetric fact ("codex has no status registry"), not a
    capability that is absent for a reason, hence `kind="fact"` below rather than
    `absent_reason_holds`."""
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
    # This is also the only row that keeps `kind="capability"` and sets
    # `absent_reason_holds` — it is a genuine refusal with a stated reason, unlike the three
    # `kind="fact"` rows above.
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
    """Outbound: rename, then read the *persisted record* back — never the live screen — to
    confirm it landed. Inbound: relaunch through the real `resumeCommand`, then read the
    persisted record again; this second half is the reported symptom (tabs not picking names
    back up).

    Neither branch decides the verdict off a screen. A prior version of this row waited for
    `"probe-renamed"` to appear on-screen after typing `/rename probe-renamed` at claude — but
    claude renders keystrokes into its own composer live, before Enter is even processed (see
    `Fixtures/Claude/busy-draft-below-echo.captured.txt`, a draft visible mid-type). That wait
    matches the echo of what was just typed on the very first poll, regardless of whether
    `/rename` did anything at all, so it could report `ok` against a completely broken rename —
    the worst failure mode this suite has. Codex's branch never had that problem, because it
    already read the effect back through `probe read` rather than a screen; claude's branch now
    does the equivalent read through `probe title-from-transcript`.
    """
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]

    if agent == "codex":
        # Codex renames through the real adapter method, so both halves go straight through
        # the probe: rename, read (outbound), resume, read again (inbound).
        out = ctx.probe(["rename", "codex", "--id", cid, "--to", "probe-renamed"])
        if "error" in out:
            return Observation(declared=True, observed=False, detail=out["error"])
        outbound = ctx.probe(["read", "codex", "--id", cid])
        if outbound.get("title") != "probe-renamed":
            return Observation(declared=True, observed=False,
                                detail=f"outbound: read back {outbound.get('title')!r}")
        resume_text = ctx.probe(["resume-command", "codex", "--id", cid,
                                  "--cwd", ctx.sandbox.root])["text"]
        with ctx.pty("codex", ["/bin/sh", "-lc", resume_text]) as term:
            attached = term.wait([_UP_MARKER["codex"]], 30)
        if not attached:
            return Observation(declared=True, observed=False,
                                detail="resumeCommand never attached; rename can't be re-checked")
        inbound = ctx.probe(["read", "codex", "--id", cid])
        return Observation(declared=True, observed=inbound.get("title") == "probe-renamed",
                            detail=f"inbound: read back {inbound.get('title')!r}")

    # Claude never renames through the adapter — `probe rename claude` is a deliberate
    # refusal (see `probe.swift`'s own comment: renames dispatch inline through
    # `SessionStore`, never through the adapter, and the production method traps on purpose
    # as a tripwire). So the outbound half drives the real thing `SessionStore` does — typing
    # `/rename <name>` at a live pty — and then reads the effect back out of claude's own
    # transcript file, exactly as codex's branch reads its effect back through `read`.
    transcript = prep.get("transcriptURL")
    if not transcript:
        return Observation(declared=True, observed=None,
                            detail="prepare returned no transcriptURL")
    text = ctx.probe(["launch-command", "claude", "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty("claude", ["/bin/sh", "-lc", text]) as term:
        term.wait([_UP_MARKER["claude"]], 30)
        term.send(b"/rename probe-renamed\r")
        # Deliberately not waited on: any text match here would be the same live-echo problem
        # described above. This is a fixed dwell to let the write land, nothing more — the
        # verdict comes only from re-reading the transcript below.
        term.pump(3)
    outbound = ctx.probe(["title-from-transcript", "claude", transcript])
    if outbound.get("title") != "probe-renamed":
        return Observation(declared=True, observed=False,
                            detail=f"outbound: transcript reads {outbound.get('title')!r}")
    resume_text = ctx.probe(["resume-command", "claude", "--id", cid,
                              "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty("claude", ["/bin/sh", "-lc", resume_text]) as term:
        attached = term.wait([_UP_MARKER["claude"]], 30)
    if not attached:
        return Observation(declared=True, observed=False,
                            detail="resumeCommand never attached; rename can't be re-checked")
    inbound = ctx.probe(["title-from-transcript", "claude", transcript])
    return Observation(declared=True, observed=inbound.get("title") == "probe-renamed",
                        detail=f"inbound: transcript reads {inbound.get('title')!r}")


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
    Row("negotiatesIdentity", "declarations", BOTH, "cheap", (), _negotiates_identity,
        kind="fact"),
    Row("needsRuntimeStart", "declarations", BOTH, "cheap", (), _needs_runtime_start,
        kind="fact"),
    Row("hasStatusRegistry", "declarations", BOTH, "cheap", (), _has_status_registry,
        kind="fact"),
    Row("textChannel", "declarations", BOTH, "cheap", (), _text_channel),
    Row("dialogDriver", "declarations", BOTH, "cheap", ("sandbox-config",), _dialog_driver),
    # The one deliberate tier exception among the declarations: see `_open_prompt_reader`'s
    # own comment for why probing codex's stated reason needs a real approval list, not a
    # captured screen. Also the one row that keeps `kind="capability"` and uses
    # `absent_reason_holds` — it is a genuine refusal with a stated reason, not a symmetric
    # fact like the three rows above.
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
