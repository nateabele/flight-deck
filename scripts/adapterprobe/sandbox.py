"""Throwaway agent homes.

Real history is untouchable by construction rather than by careful cleanup. `scripts/smoke.sh`
carries a comment recording that it once `defaults delete`d the whole preference domain and
destroyed every real session on every run; cleanup-by-id is correct but relies on the cleanup
path executing. A sandbox does not.
"""
import os, shutil, tempfile

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
        for name in _CLAUDE_SESSION_MARKERS:
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
