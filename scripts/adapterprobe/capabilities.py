# scripts/adapterprobe/capabilities.py
"""The rows, and how a cell becomes a verdict.

The valuable cell is the one where DECLARED and OBSERVED disagree, so both are carried and the
verdict is derived from the pair rather than asserted by each probe.

`ProbeContext` — the surface every row's `run(ctx, agent)` may call. `run.py` (Task 7)
implements it exactly; a row must never reach for anything not on this list:

    probe(args: list[str], stdin: str = "") -> dict   # runs the probe CLI, parses its JSON
    sandbox: AgentSandbox                              # the live sandbox for this run
    pty(agent: str, cmd: list[str]) -> PtyScreen       # cwd=sandbox.root, env=sandbox.child_env(agent)
    seed_one_turn(agent: str, cid: str) -> None        # full tier only; drives one real turn
    seeded_marker: str                                 # text seed_one_turn guarantees on screen
    versions: dict[str, str]                           # {"codex": ..., "claude": ...}

`ctx.sandbox` is itself on that list, so a row is free to read `ctx.sandbox.root`,
`ctx.sandbox.claude_home` / `.codex_home` and `ctx.sandbox.env(agent)` — those are the sandbox's
own public surface (Task 2), not a fourth thing bolted on. Rows also read a handful of
checked-in fixtures directly (plain `open()`), the same corpus `test_grammars.py` already reads
from — that keeps "cheap" rows free of any live agent, per the design's §3.5 corpus rule.
"""
import json
import os
import time
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
# The exact capture `PromptQuestion.init?(toolInput:)`'s own doc comment cites for the shape
# it expects — see `_ask_user_question_shape` below, which re-derives that claim instead of
# leaving it a version number nothing checks.
_CLAUDE_QUESTION_SHAPE_FIXTURE = os.path.join(_FIX, "Claude", "question-single.captured.jsonl")
_CODEX_ROLLOUT = os.path.join(_FIX, "Codex", "rollout.captured.jsonl")
_CODEX_IDLE_SCREEN = os.path.join(_FIX, "Codex", "tui-idle.captured.txt")
_CODEX_APPROVAL_SCREEN = os.path.join(_FIX, "Codex", "approval-command.captured.txt")

_UP_MARKER = {"claude": "Claude Code", "codex": "OpenAI Codex"}
# The row that already carries the "Yes" affirmative in each agent's own approval dialog —
# read straight off the captured screens above, not guessed.
_APPROVE_LABEL = {"claude": "Yes", "codex": "Yes, proceed"}

# What `_open_prompt_reader`'s claude arm types, and the two things it then requires to be on
# screen before it will read the transcript at all. The labels are dictated to the model in the
# prompt so the on-screen check can be a literal string match rather than a guess at whatever
# wording it would otherwise invent; "Do nothing else" keeps the turn to a single tool call.
_CLAUDE_QUESTION_OPTIONS = ("Crimson", "Viridian", "Cobalt")
_CLAUDE_QUESTION_PROMPT = (
    b"Use the AskUserQuestion tool to ask me which colour I prefer. Use exactly these three "
    b"option labels: Crimson, Viridian, Cobalt. Do nothing else, just ask.\r"
)
# The select-list dialog's own footer, read off `Fixtures/Claude/question-single.captured.txt`
# rather than guessed. It is the discriminator, not just a marker: claude's permission prompt
# footer is "Esc to cancel · Tab to amend" and workspace trust's is "Enter to confirm", so
# neither can satisfy this while looking like a question.
_CLAUDE_SELECT_FOOTER = "Enter to select"
# Claude Code's own status-line wording for an unauthenticated session, read off a live
# sandboxed launch. See `_open_prompt_reader`'s claude arm for why this is checked at all.
_CLAUDE_NOT_LOGGED_IN = "Not logged in"


def _screen_tail(screen, lines=12):
    """The last non-blank rows of a rendered screen, for a detail string. A wedged or
    unexpected screen is the only evidence a failed `establish` step leaves behind, and a
    detail that says only "it didn't happen" has thrown that evidence away."""
    kept = [ln.rstrip() for ln in screen.splitlines() if ln.strip()]
    return "\n".join(kept[-lines:])


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


def _poll(fn, limit, interval=0.3, until=bool):
    """Calls `fn()` roughly every `interval` seconds until `until(result)` is true or `limit`
    seconds have elapsed, then returns whatever `fn()` last produced either way -- a timeout is
    reported with what was actually seen, not silently collapsed to `None`. Bounded, not dwelled:
    a fixed dwell only ever encodes a guess about how long a write takes to land; this returns
    the moment the condition is actually true, and still gives up on a hard cap rather than
    spinning forever."""
    end = time.time() + limit
    result = fn()
    while not until(result) and time.time() < end:
        time.sleep(interval)
        result = fn()
    return result


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
    symmetric fact (`kind="fact"`), not a capability with a reason to probe.

    codex is the one case this harness cannot honestly measure at all: every codex probe
    subcommand -- `prepare` included -- routes through `probe.swift`'s `withCodex`, which
    unconditionally bootstraps a live app-server connection into `codex_home` before doing
    anything else. Any before/after diff this row could see on the codex side is that
    bootstrap, not a property of `prepare` itself -- there is no cheap way to ask "does *your*
    prepare need a runtime?" without the probe first starting one just to ask. Reporting a
    verdict here would misrepresent a harness artifact as a finding about codex, so this row
    records the gap honestly (`observed="error"`) instead of guessing.
    """
    declared = ctx.probe(["declare", agent])["needsRuntimeStart"]
    if agent == "codex":
        return Observation(
            declared=declared, observed="error",
            detail="every codex probe subcommand bootstraps a runtime via withCodex, so this "
                   "harness cannot separate 'prepare needs one' from 'the probe always starts "
                   "one'",
        )
    home = _agent_home(ctx, agent)
    before = set(os.listdir(home))
    out = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    if "error" in out:
        return Observation(declared=declared, observed=None, detail=out["error"])
    after = set(os.listdir(home))
    return Observation(declared=declared, observed=bool(after - before))


def _has_status_registry(ctx, agent):
    """Claude writes one status file per *live* session into `<home>/sessions`, named by pid
    but keyed inside by `sessionId` (see `ClaudeStatusFile.decode`) — so this row checks for an
    entry naming *this conversation's* id, not merely that the directory holds something. A
    bare directory-existence check is contaminated the moment any earlier row in this run's
    shared sandbox (the documented, intended design: one `AgentSandbox` for the whole run) has
    already launched this agent once — the directory, or codex's unrelated same-named one, is
    already populated by the time this row runs regardless of what this row's own launch does.
    Codex's declared `False` is the same kind of symmetric fact ("codex has no status
    registry"), not a capability that is absent for a reason, hence `kind="fact"` below rather
    than `absent_reason_holds` — codex's `<home>/sessions` holds its own rollout transcripts,
    never a per-conversation status entry, so no file there ever matches this check regardless
    of what earlier rows left behind.
    """
    declared = ctx.probe(["declare", agent])["hasStatusRegistry"]
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    text = ctx.probe(["launch-command", agent, "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    home = _agent_home(ctx, agent)
    sessions_dir = os.path.join(home, "sessions")
    with ctx.pty(agent, [ctx.login_shell, "-lc", text]) as term:
        term.pump(5)
        wrote_for_this_id = False
        if os.path.isdir(sessions_dir):
            for name in os.listdir(sessions_dir):
                try:
                    with open(os.path.join(sessions_dir, name)) as f:
                        entry = json.load(f)
                except (OSError, ValueError):
                    continue
                if isinstance(entry, dict) and entry.get("sessionId", "").lower() == cid.lower():
                    wrote_for_this_id = True
                    break
    return Observation(declared=declared, observed=wrote_for_this_id)


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
        # Drives a LIVE claude to an `AskUserQuestion` dialog and reads that session's own
        # transcript while the dialog is still on screen. Deliberately not a fixture, and the
        # one row where that distinction has already cost production: this arm used to feed
        # the probe `Fixtures/Claude/question-single.captured.jsonl`, captured at claude
        # 2.1.241, and reported `ok` straight through the 2.1.281 regression, which moved when
        # the `AskUserQuestion` `tool_use` record is written — from dialog-RAISE to
        # dialog-RESOLVE. A captured tail is by construction a *resolved* dialog's file, so it
        # still parses perfectly and can never catch that move; only a live agent with an
        # unanswered dialog up can. Costs a real turn, which is why this row is `tier="full"`.
        #
        # `--activity waiting` because `OpenPrompt.find` (`Sources/FleetKit/OpenPrompt.swift`)
        # opens only for a waiting session — without the flag the subcommand returns null
        # unconditionally, which would misrecord a working reader as `broken`.
        declared = ctx.probe(["declare", "claude"])["openPromptReader"]
        prep = ctx.probe(["prepare", "claude", "--cwd", ctx.sandbox.root])
        cid = prep["conversationID"]
        transcript = prep.get("transcriptURL")
        if not transcript:
            return Observation(declared=declared, observed="error",
                               detail="prepare returned no transcriptURL")
        text = ctx.probe(["launch-command", "claude", "--id", cid,
                          "--cwd", ctx.sandbox.root])["text"]
        with ctx.pty("claude", [ctx.login_shell, "-lc", text]) as term:
            if not term.wait([_UP_MARKER["claude"]], 30):
                return Observation(declared=declared, observed="error",
                                   detail="claude never came up within 30s")
            # Checked BEFORE typing, because an unauthenticated claude answers a question
            # prompt with silence, which is indistinguishable on screen from a model that
            # declined to call the tool — and costs the full 120s wait to find out.
            #
            # This is a live harness precondition, not a hypothetical. Claude Code keys its
            # keychain credential to the config dir: the default home uses the service
            # "Claude Code-credentials", any other `CLAUDE_CONFIG_DIR` uses
            # "Claude Code-credentials-<hash of that path>". `AgentSandbox` hands every run a
            # fresh tmpdir home, so its hash never has an entry and the session comes up
            # "Not logged in" no matter what `.claude.json` was copied in. Copying
            # `~/.claude.json` is NOT enough — that file carries account metadata, not the
            # token. (`$CLAUDE_CONFIG_DIR/.credentials.json` is read as a fallback when the
            # keychain misses — verified live — so that is where a fix belongs, but writing
            # it means extracting the user's OAuth token from their login keychain, which is
            # `sandbox.py`'s call to make and not this row's.)
            up_screen = term.display()
            if _CLAUDE_NOT_LOGGED_IN in up_screen:
                return Observation(
                    declared=declared, observed="error",
                    detail="the sandboxed claude is not authenticated, so no turn can run and "
                           "no dialog can be raised; this row cannot say anything about the "
                           "reader. AgentSandbox's per-run CLAUDE_CONFIG_DIR gets its own "
                           "keychain service 'Claude Code-credentials-<hash>' with no entry "
                           "in it. Screen tail: " + repr(_screen_tail(up_screen)),
                )
            term.send(_CLAUDE_QUESTION_PROMPT)
            # The dialog has to be provably ON SCREEN when the transcript is read — that is
            # the whole row, and the failure this establishes away is a confident `broken`
            # recorded for a configuration that was never reached: a model that simply
            # declined to call the tool leaves exactly the same empty transcript a genuinely
            # broken reader does.
            raised = term.wait([_CLAUDE_SELECT_FOOTER], 120)
            screen = term.display()
            # `Enter to select` is the select-list footer and alone rules out the two other
            # dialogs a fresh sandbox can raise — a permission prompt reads
            # "Esc to cancel · Tab to amend" and workspace trust reads "Enter to confirm"
            # (both captured under `Tests/FlightDeckTests/Fixtures/Claude/`). The label check
            # on top of it is what makes the dialog demonstrably OURS rather than some other
            # select list, so a `broken` below can only mean the reader missed a question that
            # was visibly up.
            if not raised or not any(o in screen for o in _CLAUDE_QUESTION_OPTIONS):
                return Observation(
                    declared=declared, observed="error",
                    detail=f"no AskUserQuestion dialog within 120s (footer "
                           f"{_CLAUDE_SELECT_FOOTER!r} seen: {raised}); the row cannot "
                           f"distinguish a broken reader from a model that never called the "
                           f"tool. Screen tail: {_screen_tail(screen)!r}",
                )
            # Polled here and NOT before the launch: `prepare` only names the path claude will
            # write to, it does not create it — a pre-launch existence poll always times out,
            # which is what leaves `claude.rename` recording `error` in `baseline.json` for a
            # reason that has nothing to do with renaming. By this point a real turn has run,
            # so a missing file is a genuine harness precondition failure, not a race.
            if not _poll(lambda: os.path.exists(transcript), 15):
                return Observation(
                    declared=declared, observed="error",
                    detail=f"the dialog was up but transcript {transcript!r} never appeared "
                           f"within 15s; there is nothing for the reader to be right or wrong "
                           f"about",
                )
            # The WHOLE file, not a window: `PromptService` widens its tail when a narrow read
            # finds nothing, so anything narrower here could fail for want of records rather
            # than for want of the record. Strictly more generous than production — a null
            # from this is the reader, never the window.
            with open(transcript) as f:
                tail = f.read()
            # Re-checked after the read, inside the `with`, so "the dialog was up" covers the
            # instant the bytes were taken and not merely some earlier moment.
            if not term.wait([_CLAUDE_SELECT_FOOTER], 5):
                return Observation(
                    declared=declared, observed="error",
                    detail="the dialog left the screen while the transcript was being read; "
                           "this run cannot say what was open when those bytes were written",
                )
            out = ctx.probe(["open-prompt", "claude", "--activity", "waiting"], stdin=tail)
        kind = out.get("kind")
        return Observation(
            declared=declared, observed=kind is not None,
            detail=f"live AskUserQuestion dialog on screen; reader returned {kind!r} from "
                   f"{len(tail.splitlines())} transcript lines",
        )

    # codex declares this nil for a *reason*, not a bare absence: "codex writes nothing to
    # its rollout when its own approval list is up." Trusting that forever is exactly the
    # drift this suite exists to catch, so the row raises a real approval list and checks
    # whether the agent's home actually stayed silent while it was showing. That needs a
    # live turn, which is why this row is `tier="full"` rather than the other declarations'
    # "cheap" — the one deliberate exception, called out where the row is registered below.
    # This is also the only row that keeps `kind="capability"` and sets
    # `absent_reason_holds` — it is a genuine refusal with a stated reason, unlike the three
    # `kind="fact"` rows above.
    #
    # `ProbeContext._dismiss_codex_onboarding` writes `trust_level = "trusted"` for this
    # sandbox's root so every OTHER row in the run skips the one-time "do you trust this
    # directory" prompt. That same trust plausibly removes the approval friction this row
    # exists to raise, which would make a 45s wait for it a coin flip against the wrong
    # thing. So this row also writes `approval_policy = "on-request"` — the config knob that
    # keeps prompting for approval even in a trusted directory, confirmed against this
    # machine's installed `codex --help` output — PREPENDED, not appended: appending would
    # land it inside the `[projects."<root>"]` table the trust entry already opened (TOML
    # puts a bare `key = value` in the table most recently opened), and live-confirmed
    # against `codex-cli 0.152.1`, a bogus value at top level errors with `unknown variant`
    # while the identical key inside a projects table is accepted silently and never
    # validated — i.e. appending would make this setting inert while looking like it took
    # effect. Prepending keeps it at top level, before any `[table]` header, so it is
    # actually in effect. This mutates the shared sandbox config for every later row in this
    # run; harmless today since no other row reads this key, but a future codex that starts
    # validating unknown keys inside a projects table would need this reverted before it
    # broke config load for the rest of the run.
    declared = ctx.probe(["declare", "codex"])["openPromptReader"]
    config_path = os.path.join(ctx.sandbox.codex_home, "config.toml")
    with open(config_path) as f:
        existing_config = f.read()
    with open(config_path, "w") as f:
        f.write('approval_policy = "on-request"\n' + existing_config)
    prep = ctx.probe(["prepare", "codex", "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    text = ctx.probe(["launch-command", "codex", "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    home = ctx.sandbox.codex_home
    with ctx.pty("codex", [ctx.login_shell, "-lc", text]) as term:
        term.wait([_UP_MARKER["codex"]], 30)
        term.send(b"Run the shell command: echo probe-approval-marker\r")
        appeared = term.wait(["Would you like to run the following command"], 45)
        if not appeared:
            # Live-confirmed (not assumed): even with `approval_policy = "on-request"` set
            # above -- and identically with it absent -- this exact message wedges the TUI
            # at "Booting MCP server: codex_apps (0s ...)" and never progresses, for at
            # least 180s. That screen is reached before any approval list could show, so
            # this row's "never appeared" result right now traces to that boot stall, not
            # to the trust override this row just named and worked around.
            return Observation(
                declared=declared, observed=None,
                detail="approval list never appeared; screen was still stuck at "
                       "'Booting MCP server: codex_apps' after the wait, which reaching an "
                       "approval prompt would require passing first -- trust_level "
                       "\"trusted\" is written for this sandbox root, and approval_policy "
                       "\"on-request\" is written at top level so it is genuinely in effect "
                       "this run, but whether it would have changed anything is NOT "
                       "established: the boot stall blocks this screen before any approval "
                       "prompt could appear either way, so this run cannot distinguish "
                       "'the override does nothing' from 'the override would work if the "
                       "boot stall were fixed'",
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
    """Not a checkable capability -- a declared-string fact, and deliberately so.

    This used to assert `os.path.exists(home/marker)`, but `AgentSandbox` copies exactly this
    file (`.claude.json` / `auth.json`) into the sandbox home at CONSTRUCTION time, before any
    row or adapter method has run (see `sandbox.py`'s `CREDENTIALS`) -- so that existence check
    was always true regardless of anything this suite does. It could only ever go red on a
    machine with no real credential file to seed from in the first place, which is a harness
    fact, not an adapter one. `environment`'s row is what actually proves the sandbox
    redirection now; this row's only honest job is to record which filename
    `AgentID.homeMarkerFile` currently names, `kind="fact"` so a symmetric declared/observed
    match is what "checked" means here, same as the other `kind="fact"` rows.
    """
    marker = ctx.probe(["declare", agent])["homeMarkerFile"]
    return Observation(declared=marker, observed=marker, detail=marker)


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
    checks is whether the redirection took, from two angles neither of which the harness itself
    can satisfy by accident:

    The previous version of this row checked `os.path.exists(home/marker)` for
    `marker = .claude.json` / `auth.json` — exactly the files `AgentSandbox` copies in at
    CONSTRUCTION time, before any adapter runs, so that half was always true regardless of what
    `prepare` did. Unlinking the marker first and requiring it back doesn't rescue the idea
    either: verified live (a throwaway `codex app-server` run against a copied `auth.json`),
    neither agent's `prepare` ever rewrites its credential file, so "does it come back" is either
    permanently unfalsifiable or, if actually deleted, risks breaking codex's real auth handshake
    for a reason that has nothing to do with this row.

    `prepare` already hands back something that DOES encode which home it used:
    `transcriptURL`. Claude's is a pure derivation off `projectsRoot()` with no filesystem write
    at all (`ClaudeAdapter.prepare` touches no disk), so a broken redirect would point it at the
    real `~/.claude/projects`, not the sandbox; codex's names a path under its own `sessions`
    directory the same way. Requiring it under the sandbox home is a direct assertion on the
    exact code path this row exists to protect, not a side effect that may or may not occur.
    `os.path.realpath` on both sides because codex resolves `/var`'s macOS symlink into
    `/private/var` before naming the path and claude does not, so a literal-prefix comparison
    would spuriously fail on codex alone.

    The second half calls the real `AgentAdapter.environment(for:)` through the new `probe
    environment` subcommand — no existing subcommand ever called it before this row: probe.swift's
    own `claudeAdapter()`/`withCodex` redirect the probe's OWN process straight off
    `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, bypassing `environment(for:)` entirely, so a probe that only
    exercised those two functions could read `ok` here even if `environment(for:)` itself were
    broken and named the wrong home.
    """
    home = _agent_home(ctx, agent)
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    if "error" in prep:
        return Observation(declared=True, observed=None, detail=prep["error"])
    transcript = prep.get("transcriptURL") or ""
    transcript_in_sandbox = os.path.realpath(transcript).startswith(
        os.path.realpath(home) + os.sep)

    env = ctx.probe(["environment", agent])
    if "error" in env:
        return Observation(declared=True, observed=None, detail=env["error"])
    names_sandbox_home = home in env.values()

    observed = transcript_in_sandbox and names_sandbox_home
    return Observation(
        declared=True, observed=observed,
        detail="" if observed else
               f"transcriptURL={transcript!r} under sandbox={transcript_in_sandbox}, "
               f"environment(for:)={env!r} names sandbox={names_sandbox_home}",
    )


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
    """Neither agent strips shell metacharacters any more — this row used to assert claude
    did, which is the same stale claim `AgentAdapter.sanitizedTitle`'s own doc comment carried
    until this task corrected it (production dropped the strip once `SessionStore.inject`
    started gating on a live composer box; see that comment). Both agents now run through
    `AgentTitle.sanitized` with an empty forbidden set: `;` survives for both, a control
    character (`\\n`, `\\t`) survives for neither.
    """
    hostile = "a; rm -rf / \n\t<script>evil()</script>"
    out = ctx.probe(["sanitize", agent, hostile])
    sanitized = out.get("sanitized")
    observed = (
        sanitized is not None and ";" in sanitized
        and "\n" not in sanitized and "\t" not in sanitized
    )
    return Observation(declared=True, observed=observed,
                        detail="" if observed else f"sanitized={sanitized!r}")


def _ask_user_question_shape(ctx, agent):
    """`PromptQuestion.init?(toolInput:)`'s doc comment pins the exact shape it expects —
    `{"questions":[{"question":…,"header":…,"multiSelect":false,
    "options":[{"label":…,"description":…}]}]}` — to `Fixtures/Claude/question-single
    .captured.jsonl (claude 2.1.241)`, a version number nothing checked. This is a cheap
    (fixture, no live turn) re-derivation off that same capture: feed the real tool_use
    record through the real reader (`probe open-prompt`, the same subcommand
    `openPromptReader` exercises) and require every field the doc comment names to still be
    there — the question's three options, in order, each carrying its `description` as
    `detail`, and `multiSelect` still read as `false`. A parser that silently dropped an
    option or a description would still return a non-nil `kind`, which is why
    `test_claude_derives_an_open_prompt_once_activity_is_threaded_through`'s bare
    not-None check is a different, weaker claim than this row makes.

    **What this row CANNOT catch, stated because its name invites the opposite reading.** It
    never runs a live claude, so it cannot see the hazard that motivated this whole suite: a
    NEW claude emitting a DIFFERENT shape. Against a frozen capture it will keep passing
    forever, which is exactly how `openPromptReader` sat at `ok` across the 2.1.281 change.
    What it does catch is the other direction — OUR parser regressing away from a shape claude
    really did emit. That is worth a row, but it is a regression guard, not a drift detector.
    Closing the live-drift half is `openPromptReader`'s job, and that row is currently blocked
    on authenticating a sandboxed claude; until it lands, this claim has no live coverage and
    the version number in `PromptQuestion`'s comment remains unverified against any newer
    binary. Do not read a green cell here as "the shape still matches claude".
    """
    with open(_CLAUDE_QUESTION_SHAPE_FIXTURE) as f:
        tail = f.read()
    out = ctx.probe(["open-prompt", "claude", "--activity", "waiting"], stdin=tail)
    kind = out.get("kind") or ""
    observed = (
        kind.startswith("question(")
        and 'multiSelect: false' in kind
        and all(f'label: "{label}"' in kind for label in ("Rust", "Go", "Swift"))
        and kind.count("Option(label:") == 3
        and kind.count("detail: Optional(") == 3
    )
    return Observation(declared=True, observed=observed, detail=kind)


# --- Live operations: including both reported symptoms. -------------------------------------

def _prepare(ctx, agent):
    out = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    if "error" in out:
        return Observation(declared=True, observed=None, detail=out["error"])
    cid = out.get("conversationID") or ""
    ok = bool(cid) and cid == cid.lower()
    return Observation(declared=True, observed=ok,
                        detail="" if ok else f"unexpected id shape: {cid!r}")


def _binding(ctx, agent):
    """A pin read back: conversation id and transcript path agree with what the agent wrote."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    out = ctx.probe(["rebind", agent, "--pin", cid, "--cwd", ctx.sandbox.root])
    if "error" in out:
        return Observation(declared=True, observed=False, detail=out["error"])
    agrees = out.get("conversationID") == cid and not out.get("repointed", False)
    return Observation(declared=True, observed=agrees,
                        detail="" if agrees else f"rebind returned {out.get('conversationID')!r}")


def _location(ctx, agent):
    """Launch in the sandbox's own working directory; the agent's idle screen must name it."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    text = ctx.probe(["launch-command", agent, "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty(agent, [ctx.login_shell, "-lc", text]) as term:
        up = term.wait([_UP_MARKER[agent]], 30)
        screen = term.display()
    named = ctx.sandbox.root in screen or os.path.basename(ctx.sandbox.root) in screen
    return Observation(declared=True, observed=up and named)


def _launch_command(ctx, agent):
    """Typed at a live pty. A TUI comes up bound to the expected conversation."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    text = ctx.probe(["launch-command", agent, "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty(agent, [ctx.login_shell, "-lc", text]) as term:
        up = term.wait([_UP_MARKER[agent]], 30)
    return Observation(declared=True, observed=up)


def _resume_command(ctx, agent):
    """Type the real resumeCommand at a real pty and require prior history, no picker."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    ctx.seed_one_turn(agent, cid)            # tier "full" only; see run.py
    text = ctx.probe(["resume-command", agent, "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty(agent, [ctx.login_shell, "-lc", text]) as term:
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
        with ctx.pty("codex", [ctx.login_shell, "-lc", resume_text]) as term:
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
    # A zero-turn session's transcript file may legitimately not exist on disk yet — polled
    # rather than assumed, so "the file hasn't been created yet" reads as an honest `error` (a
    # harness precondition unmet before this row even typed anything) instead of being folded
    # into whatever a fixed dwell happened to see after typing, which is what left the original
    # `claude.rename — broken` reading unable to rule out "3 seconds was too short."
    if not _poll(lambda: os.path.exists(transcript), 30):
        return Observation(
            declared=True, observed="error",
            detail=f"transcript {transcript!r} never appeared within 30s, before /rename was "
                   f"even typed",
        )
    text = ctx.probe(["launch-command", "claude", "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty("claude", [ctx.login_shell, "-lc", text]) as term:
        term.wait([_UP_MARKER["claude"]], 30)
        term.send(b"/rename probe-renamed\r")
        # Polled, not dwelled — for the same reason the on-screen echo check above was
        # rejected: an arbitrary "long enough" wait for a file write to land is exactly as
        # unconfirmed as an arbitrary wait for text to appear on screen, just failing quietly
        # instead of loudly. Polled inside the `with` so the pty (and the claude process
        # holding it) stays alive for the full window rather than being torn down the instant
        # a fixed dwell's clock ran out.
        outbound_title = _poll(
            lambda: ctx.probe(["title-from-transcript", "claude", transcript]).get("title"),
            30, until=lambda t: t == "probe-renamed",
        )
    if outbound_title != "probe-renamed":
        return Observation(declared=True, observed=False,
                            detail=f"outbound: transcript reads {outbound_title!r}")
    resume_text = ctx.probe(["resume-command", "claude", "--id", cid,
                              "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty("claude", [ctx.login_shell, "-lc", resume_text]) as term:
        attached = term.wait([_UP_MARKER["claude"]], 30)
    if not attached:
        return Observation(declared=True, observed=False,
                            detail="resumeCommand never attached; rename can't be re-checked")
    inbound = ctx.probe(["title-from-transcript", "claude", transcript])
    return Observation(declared=True, observed=inbound.get("title") == "probe-renamed",
                        detail=f"inbound: transcript reads {inbound.get('title')!r}")


# claude's permission dialog's own footer, read off `Fixtures/Claude/permission-bash
# .captured.txt` — distinct from `_CLAUDE_SELECT_FOOTER`'s "Enter to select", which is the
# `AskUserQuestion` select list's own footer, not this one.
_CLAUDE_APPROVAL_FOOTER = "Esc to cancel"


def _escape_denies_permission(ctx, agent):
    """`SessionStore.answerPrompt`'s `.deny` case (`ClaudeDialogDriver.deny`) sends one raw
    Escape and reads nothing back — no viewport, no confirmation pass — on the strength of a
    claim about what claude itself then does: the transcript closes the call `is_error=true`
    with claude's own rejection wording ("The user doesn't want to proceed with this tool
    use. The tool use was rejected"), measured against claude 2.1.241 in Task 3. That claim
    had nothing checking it before this row. Needs a real approval dialog and a real Escape,
    so `tier="full"`.
    """
    declared = True
    prep = ctx.probe(["prepare", "claude", "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    transcript = prep.get("transcriptURL")
    if not transcript:
        return Observation(declared=declared, observed="error",
                            detail="prepare returned no transcriptURL")
    text = ctx.probe(["launch-command", "claude", "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty("claude", [ctx.login_shell, "-lc", text]) as term:
        if not term.wait([_UP_MARKER["claude"]], 30):
            return Observation(declared=declared, observed="error",
                                detail="claude never came up within 30s")
        # Checked before typing, same discipline as `_open_prompt_reader`'s claude arm and
        # for the same reason: an unauthenticated claude answers silently, which this row
        # cannot tell apart from a genuinely broken dialog without wasting the full wait.
        up_screen = term.display()
        if _CLAUDE_NOT_LOGGED_IN in up_screen:
            return Observation(
                declared=declared, observed="error",
                detail="the sandboxed claude is not authenticated, so no tool call can run "
                       "and no approval dialog can be raised; see openPromptReader's own "
                       "comment for the keychain reason. Screen tail: "
                       + repr(_screen_tail(up_screen)),
            )
        term.send(b"Run the shell command: echo probe-deny-marker\r")
        raised = term.wait([_CLAUDE_APPROVAL_FOOTER], 60)
        screen = term.display()
        if not raised:
            return Observation(
                declared=declared, observed="error",
                detail=f"no approval dialog within 60s (footer "
                       f"{_CLAUDE_APPROVAL_FOOTER!r} seen: {raised}); the row cannot "
                       f"distinguish a broken dialog from a model that ran the command "
                       f"without asking. Screen tail: {_screen_tail(screen)!r}",
            )
        term.send(b"\x1b")

        # Polled, not dwelled — the same discipline `_rename`'s outbound half uses: an
        # arbitrary wait for the transcript write to land is exactly as unconfirmed as an
        # arbitrary wait for text to appear on screen, just failing quietly instead of loudly.
        def rejected():
            if not os.path.exists(transcript):
                return False
            with open(transcript) as f:
                content = f.read()
            return '"is_error":true' in content and "tool use was rejected" in content

        found = _poll(rejected, 15)
    return Observation(
        declared=declared, observed=found,
        detail="" if found else
               f"transcript {transcript!r} never closed the call with is_error=true and "
               f"claude's rejection wording after Escape",
    )


def _login_invocation(ctx, agent):
    # The sandbox is authenticated on purpose (§3.3) — an honest login probe would mean
    # destroying that. The weaker "binary exists and advertises the subcommand" check is
    # deliberately never recorded as `ok`.
    return Observation(declared=True, observed="needs-auth",
                        detail="sandbox is authenticated; an honest probe is impossible")


def _runtime_observation(ctx, agent):
    """During a real turn: claude's status file transitions to carry an entry for THIS
    conversation, codex's OWN rollout file for THIS thread grows. Both snapshotted immediately
    before `ctx.seed_one_turn` and required to change afterward -- the same discipline
    `_has_status_registry` uses -- because a bare post-hoc existence check is contaminated the
    moment anything else has happened in this run's shared sandbox: claude's `<home>/sessions`
    is routinely non-empty from an earlier row's own launch of this or another conversation, and
    codex's rollout file for THIS thread already exists with real content (a `session_meta`
    record plus environment context, ~18KB, verified live) the instant `prepare` returns --
    before this row's turn has sent or received a single byte. `_bytes_under(codex_home)`
    against the WHOLE home is even less informative: `run.py`'s onboarding dismissal and every
    earlier row's own `withCodex` bootstrap already made it nonzero long before this row runs.
    """
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    if agent == "claude":
        sessions_dir = os.path.join(ctx.sandbox.claude_home, "sessions")

        def has_entry_for_cid():
            if not os.path.isdir(sessions_dir):
                return False
            for name in os.listdir(sessions_dir):
                try:
                    with open(os.path.join(sessions_dir, name)) as f:
                        entry = json.load(f)
                except (OSError, ValueError):
                    continue
                if isinstance(entry, dict) and entry.get("sessionId", "").lower() == cid.lower():
                    return True
            return False

        before = has_entry_for_cid()
        ctx.seed_one_turn(agent, cid)
        after = has_entry_for_cid()
        observed = after and not before
    else:
        rollout = prep.get("transcriptURL")
        before = os.path.getsize(rollout) if rollout and os.path.exists(rollout) else 0
        ctx.seed_one_turn(agent, cid)
        after = os.path.getsize(rollout) if rollout and os.path.exists(rollout) else 0
        observed = after > before
        if not observed:
            # NOT an independent finding when this fails: `CodexAdapter.launchCommand`
            # (`Sources/FlightDeck/Agents/Codex/CodexAdapter.swift:286`) is `codex resume
            # <id>` -- byte-identical to `resumeCommand`'s own launch command -- and
            # `seed_one_turn` drives this row's turn through exactly that command. The
            # rollout this row measures can only grow if the resume attached, so this cell
            # and `codex.resumeCommand` failing together is one failure counted twice, not
            # two corroborating ones.
            return Observation(
                declared=True, observed=observed,
                detail="derivative: the turn is driven through `codex resume <id>`, the "
                       "same command resumeCommand launches, so this cannot pass while "
                       "resumeCommand fails")
    return Observation(declared=True, observed=observed)


def _codex_paste_detects_same_burst_return(ctx, agent):
    """`CodexTextChannel.submit`'s own doc comment: codex's TUI paste-detects, so a `\\r`
    arriving in the SAME burst as the text before it is folded into that burst and inserted
    as a literal newline rather than submitting — "live-isolated against codex-cli 0.153.4",
    a version number nothing since has checked. This re-derives it directly rather than
    trusting a comment to still be true: two resumes of the SAME thread, so both writes land
    on an identical rollout file and "grew" means the same thing both times.

    One write combines the marker and Return into a single `os.write()` (same burst,
    reproducing the failure the comment names) — codex should leave the marker typed and
    unsent, so the rollout should NOT grow. The other splits them with a real sleep in
    between (the gap `SessionStore.injectionSettle`'s 120ms opens in production) — codex
    should submit and reply, so the rollout SHOULD grow. Needs two real turns, so `tier="full"`
    — the one row in this suite that does, because nothing shorter can tell "typed but never
    sent" apart from "sent".
    """
    prep = ctx.probe(["prepare", "codex", "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    rollout = prep.get("transcriptURL")

    def size():
        return os.path.getsize(rollout) if rollout and os.path.exists(rollout) else 0

    marker = f"adapterprobe-paste-{uuid.uuid4().hex[:8]}: reply with exactly OK"

    text = ctx.probe(["launch-command", "codex", "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty("codex", [ctx.login_shell, "-lc", text]) as term:
        if not term.wait([_UP_MARKER["codex"]], 30):
            return Observation(declared=True, observed=None, detail="codex never came up")
        before_combined = size()
        term.send((marker + "\r").encode())
        term.pump(15)
        after_combined = size()
    combined_grew = after_combined > before_combined

    resume_text = ctx.probe(["resume-command", "codex", "--id", cid,
                              "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty("codex", [ctx.login_shell, "-lc", resume_text]) as term:
        if not term.wait([_UP_MARKER["codex"]], 30):
            return Observation(declared=True, observed=None, detail="codex never resumed")
        before_split = size()
        term.send(marker.encode())
        time.sleep(0.15)
        term.send(b"\r")
        # Polled with a deadline rather than one fixed `pump`, and generously: this is the
        # POSITIVE CONTROL, so time spent here buys interpretability, and it returns as soon
        # as the rollout moves. A fixed 20s window made a merely-slow model turn look exactly
        # like the regression this row exists to catch.
        split_deadline = time.time() + 90
        while time.time() < split_deadline and size() <= before_split:
            term.pump(2)
        after_split = size()
    split_grew = after_split > before_split

    # A failed positive control VOIDS the experiment; it does not fail the claim. If a normal
    # split-burst turn never grew the rollout, this run never established that "grew" is even
    # observable here — codex may be slow, rate-limited, or not answering — and the combined
    # write's non-growth then carries no information, because non-growth is what BOTH arms do
    # when nothing is happening. Reporting `broken` from that state is precisely the
    # "assert an outcome for a configuration you never established" failure this whole plan
    # exists to end, so it returns `error` (observed=None) and says which control failed.
    # Order matters: a DIRECTLY OBSERVED regression outranks the control. If the combined
    # write grew the rollout, codex submitted on a same-burst write — the exact failure this
    # row exists to catch — and that growth is itself proof that growth was observable in this
    # run, which is all the positive control was ever there to establish. Checking the control
    # first would throw that evidence away as `error` whenever the second turn also stalled.
    if not combined_grew and not split_grew:
        return Observation(
            declared=True, observed=None,
            detail=f"positive control failed: neither write grew the rollout (the split-burst "
                   f"write with a real gap did not grow it within 90s), so this run cannot tell "
                   f"'typed but never sent' from 'nothing happened at all'",
        )

    return Observation(
        declared=True, observed=not combined_grew,
        detail=f"combined write grew rollout: {combined_grew}; split write (real gap) grew "
               f"rollout: {split_grew}"
               + ("" if split_grew else " -- control did not grow, but the combined write did, "
                                        "which both proves the regression and proves growth was "
                                        "observable here"),
    )


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
    # The one deliberate tier exception among the declarations, and now on BOTH arms: see
    # `_open_prompt_reader`'s own comment for why probing codex's stated reason needs a real
    # approval list rather than a captured screen, and why claude's needs a real unanswered
    # `AskUserQuestion` dialog rather than a captured transcript — a captured one is a
    # resolved dialog's file and parses forever, which is how this row stayed green through
    # the 2.1.281 regression it exists to catch. Both arms spend a live turn.
    # Also the one row that keeps `kind="capability"` and uses
    # `absent_reason_holds` — it is a genuine refusal with a stated reason, not a symmetric
    # fact like the three rows above.
    Row("openPromptReader", "declarations", BOTH, "full", ("sandbox-config",),
        _open_prompt_reader),
    Row("homeMarkerFile", "declarations", BOTH, "cheap", (), _home_marker_file, kind="fact"),
    Row("identity", "declarations", BOTH, "cheap", (), _identity),
    Row("environment", "declarations", BOTH, "cheap", (), _environment),
    # Grammars
    Row("titleFromTranscript", "grammars", BOTH, "cheap", (), _title_from_transcript),
    Row("timelineItems", "grammars", BOTH, "cheap", (), _timeline_items),
    Row("sanitizedTitle", "grammars", BOTH, "cheap", (), _sanitized_title),
    # The shape `PromptQuestion.init?(toolInput:)`'s own doc comment pins to a captured
    # transcript (claude 2.1.241) — a fixture re-check, so `cheap`, not the live-turn
    # `openPromptReader` above.
    Row("askUserQuestionShape", "grammars", ("claude",), "cheap", (),
        _ask_user_question_shape),
    # Live operations
    Row("prepare", "live", BOTH, "cheap", (), _prepare),
    Row("binding", "live", BOTH, "cheap", (), _binding),
    Row("location", "live", BOTH, "cheap", (), _location),
    Row("launchCommand", "live", BOTH, "cheap", (), _launch_command),
    Row("resumeCommand", "live", BOTH, "full", (), _resume_command),
    Row("rebind", "live", BOTH, "cheap", (), _rebind),
    Row("rename", "live", BOTH, "full", (), _rename),
    # A real approval dialog and a real Escape; see `_escape_denies_permission`'s own
    # comment for what claude 2.1.241 was measured to do that nothing has checked since.
    Row("escapeDeniesPermission", "live", ("claude",), "full", (),
        _escape_denies_permission),
    Row("loginInvocation", "live", BOTH, "cheap", (), _login_invocation),
    Row("runtimeObservation", "live", BOTH, "full", ("sandbox-config",),
        _runtime_observation),
    # Two real turns, not one — see the row's own comment for why nothing shorter can tell
    # "typed but never sent" apart from "sent".
    Row("codexPasteDetectsSameBurstReturn", "live", ("codex",), "full", (),
        _codex_paste_detects_same_burst_return),
]

assert len(ROWS) == 24, f"expected exactly 24 rows, found {len(ROWS)}"
