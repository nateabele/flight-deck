"""Throwaway agent homes.

Real history is untouchable by construction rather than by careful cleanup. `scripts/smoke.sh`
carries a comment recording that it once `defaults delete`d the whole preference domain and
destroyed every real session on every run; cleanup-by-id is correct but relies on the cleanup
path executing. A sandbox does not.
"""
import json, os, shutil, subprocess, tempfile

HOME = os.path.realpath(os.path.expanduser("~"))

# Copied IN, never out. The sandbox tree is deleted wholesale.
CREDENTIALS = {
    "claude": [(os.path.expanduser("~/.claude.json"), ".claude.json")],
    "codex":  [(os.path.expanduser("~/.codex/auth.json"), "auth.json")],
}


# Names Claude Code sets on any process it spawns as its own child. A `claude` that inherits
# `CLAUDE_CODE_CHILD_SESSION` runs with transcript saving silently disabled -- no error, no
# JSONL, just a status-line banner easy to miss -- which would misreport every claude row that
# reads a transcript back as `broken` against a claude that actually works fine. This harness
# commonly runs *inside* a Claude Code session itself, so this is not hypothetical.
_CLAUDE_SESSION_MARKERS = (
    "CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE", "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT",
)

# Anything that redirects, rewrites or intercepts model traffic. A sandboxed agent inherits the
# real environment, so without this the suite measures whatever sits in front of the API rather
# than the agent -- and records the result as the AGENT's behaviour, which is precisely the
# false verdict this whole harness exists to prevent.
#
# Not hypothetical here: `ANTHROPIC_BASE_URL=http://localhost:8787` is set on this machine and
# points at `headroom proxy`, a context-optimisation layer that REWRITES requests. Measured
# 2026-09-27 over 2372 consecutive log records: every one `provider: anthropic`, and 53% had
# context removed -- mean 1659 tokens, max 40840 on a single request. A live claude row
# calibrated through that is measuring headroom+claude, not claude.
_MODEL_TRAFFIC_MARKERS = (
    "ANTHROPIC_BASE_URL", "ANTHROPIC_API_URL", "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_DEFAULT_HEADERS", "ANTHROPIC_PROXY", "HTTP_PROXY", "HTTPS_PROXY",
    "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy",
)

# The keychain item Claude Code stores its OAuth credential under for the DEFAULT config dir.
# The suffixed siblings (`Claude Code-credentials-<hash>`) are per-`CLAUDE_CONFIG_DIR` entries,
# keyed by a hash of that path -- which is exactly why a sandbox home cannot find one, and why
# the token has to be planted as a file instead.
_CLAUDE_KEYCHAIN_SERVICE = "Claude Code-credentials"


class UnsafeHome(Exception):
    pass


def guard_home(path):
    """Refuse any agent home that is, or is inside, the user's real home.

    Resolved before comparison so a symlink cannot smuggle a real home through, and so a `~`
    that a caller never expanded cannot bypass the check either (`os.path.realpath` alone does
    not expand `~` — only `os.path.expanduser` does).
    """
    real = os.path.realpath(os.path.expanduser(path))
    if real == HOME or real.startswith(HOME + os.sep):
        raise UnsafeHome(
            f"refusing to run an agent with its home at {path!r} (resolves to {real!r}, "
            f"inside {HOME!r}) — probes must never touch real history"
        )


class AgentSandbox:
    def __init__(self, keep=False):
        self.keep = keep
        self.root = None
        self.copied = []

    def __enter__(self):
        self.root = tempfile.mkdtemp(prefix="adapterprobe-")
        try:
            guard_home(self.root)
            self.claude_home = os.path.join(self.root, "claude-home")
            self.codex_home = os.path.join(self.root, "codex-home")
            for h in (self.claude_home, self.codex_home):
                os.makedirs(h, exist_ok=True)
                guard_home(h)
            self._copy_credentials()
        except BaseException:
            # A failed construction always cleans up, regardless of `keep` — `keep` is for
            # inspecting a *successful* run, not for preserving a partial, broken tree.
            shutil.rmtree(self.root, ignore_errors=True)
            raise
        return self

    def _copy_credentials(self):
        for agent, entries in CREDENTIALS.items():
            dest_home = self.claude_home if agent == "claude" else self.codex_home
            for src, name in entries:
                if os.path.exists(src):
                    shutil.copy2(src, os.path.join(dest_home, name))
                    self.copied.append(f"{agent}:{name}")
        self._plant_claude_oauth()
        self._trust_sandbox_workspace()

    def _plant_claude_oauth(self):
        """Give the sandboxed `claude` a usable credential, read from the login keychain at run
        time and written ONLY inside the throwaway home.

        `~/.claude.json` (copied above) carries account metadata, not the token, so a sandbox
        with only that file reaches "Not logged in" and every live claude row dies before its
        actual check. Claude Code keys its keychain item to a hash of `CLAUDE_CONFIG_DIR`, so a
        fresh temp home can never find its own entry -- but the `$CLAUDE_CONFIG_DIR/
        .credentials.json` fallback IS read, which is the seam this uses.

        **The token is never written outside the sandbox tree and never logged.** It lands at
        mode 0600 in a directory `guard_home` has already refused to place inside the real home,
        and it dies with `__exit__`'s `rmtree`. `self.copied` records only that a credential was
        planted, never any part of it.

        Fails SOFT on purpose. A missing or unreadable keychain item leaves the sandbox exactly
        as it was, so rows fail their own login guard and report `error`/`needs-auth` -- an
        honest "could not establish the configuration". Raising here would instead take down
        every row in the suite, including the cheap ones that never needed a credential.
        """
        try:
            out = subprocess.run(
                ["security", "find-generic-password",
                 "-s", _CLAUDE_KEYCHAIN_SERVICE, "-a", os.environ.get("USER", ""), "-w"],
                capture_output=True, text=True, timeout=30,
            )
        except (OSError, subprocess.SubprocessError):
            return
        raw = (out.stdout or "").strip()
        if out.returncode != 0 or not raw:
            return
        try:
            # Parsed, not blindly copied: a keychain item that is not the OAuth blob this
            # expects would otherwise be written as a plausible-looking credential file and
            # produce a confusing downstream failure instead of a clean absence.
            if "claudeAiOauth" not in json.loads(raw):
                return
        except (ValueError, TypeError):
            return
        dest = os.path.join(self.claude_home, ".credentials.json")
        fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, raw.encode())
        finally:
            os.close(fd)
        self.copied.append("claude:.credentials.json (planted from keychain)")

    def _trust_sandbox_workspace(self):
        """Pre-accept claude's folder-trust prompt for the sandbox root.

        Claude Code keys trust per absolute project path in `.claude.json`
        (`projects[<path>].hasTrustDialogAccepted`). Every sandbox gets a BRAND-NEW temp root,
        so that path is never in the copied file and claude opens its "Quick safety check: Is
        this a project you created or one you trust?" prompt over the composer instead of doing
        anything a row asked for.

        Measured 2026-09-27, before this existed: with the OAuth token planted and auth finally
        working, `openPromptReader` and `escapeDeniesPermission` BOTH still reported `error` --
        "no dialog within 120s/60s" -- because the trust prompt, not the agent, owned the
        screen. The rows were honest about not establishing their configuration; they just
        could not get far enough to test anything.

        Granted in the config file rather than by driving the prompt on screen, and that is
        deliberate: `docs/AGENT-OPERATIONS.md` records that this dialog opens on `No, exit`, so
        a rig that answers it with a blind Return QUITS THE SESSION it was about to measure and
        looks like a hang. Not answering it at all is safer than answering it wrong.
        """
        cfg = os.path.join(self.claude_home, ".claude.json")
        if not os.path.exists(cfg):
            return
        try:
            with open(cfg) as f:
                doc = json.load(f)
        except (OSError, ValueError):
            return
        if not isinstance(doc, dict):
            return
        projects = doc.setdefault("projects", {})
        if not isinstance(projects, dict):
            return
        # BOTH spellings, and that is the whole trick: on macOS `/tmp` is a symlink to
        # `/private/tmp`, so `mkdtemp` hands back `/tmp/adapterprobe-XXXX` while claude records
        # the workspace it resolved -- `/private/tmp/adapterprobe-XXXX`. Granting only the path
        # we happen to hold leaves the trust prompt up under a key that never matches, which is
        # exactly how this failed the first time it was tried.
        for path in {self.root, os.path.realpath(self.root)}:
            entry = projects.setdefault(path, {})
            if isinstance(entry, dict):
                entry["hasTrustDialogAccepted"] = True
        try:
            with open(cfg, "w") as f:
                json.dump(doc, f)
        except OSError:
            return
        self.copied.append("claude:workspace pre-trusted")

    def env(self, agent):
        if agent == "claude":
            return {"CLAUDE_CONFIG_DIR": self.claude_home}
        if agent == "codex":
            return {"CODEX_HOME": self.codex_home}
        raise ValueError(f"unknown agent {agent!r}")

    def child_env(self, agent):
        """A COMPLETE environment for spawning `agent` as a live process -- not just the one
        variable `env()` names.

        `env()` alone is enough for `subprocess.run(..., env=...)`, which replaces the child's
        environment outright. It is not enough for a `PtyScreen`, which forks *this* process
        and then only `update()`s on top of whatever it already inherited at fork time -- it
        never deletes a key. So the markers below have to be gone from this process's real
        `os.environ` before any fork happens, not merely absent from the dict handed back
        here. `scripts/livefuzz/fuzz.py` hits the identical trap driving a live `claude` pty
        and works around it the same way: popping the markers from its own environment before
        spawning.
        """
        for name in _CLAUDE_SESSION_MARKERS + _MODEL_TRAFFIC_MARKERS:
            os.environ.pop(name, None)
        e = dict(os.environ)
        e.update(self.env(agent))
        if agent == "claude":
            e["CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"] = "1"
        return e

    def __exit__(self, *exc):
        if self.root and not self.keep:
            shutil.rmtree(self.root, ignore_errors=True)
        return False
