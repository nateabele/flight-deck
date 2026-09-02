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


class UnsafeHome(Exception):
    pass


def guard_home(path):
    """Refuse any agent home that is, or is inside, the user's real home.

    Resolved before comparison so a symlink cannot smuggle a real home through.
    """
    real = os.path.realpath(path)
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
        self.claude_home = os.path.join(self.root, "claude-home")
        self.codex_home = os.path.join(self.root, "codex-home")
        for h in (self.claude_home, self.codex_home):
            guard_home(self.root)
            os.makedirs(h, exist_ok=True)
            guard_home(h)
        self._copy_credentials()
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

    def __exit__(self, *exc):
        if self.root and not self.keep:
            shutil.rmtree(self.root, ignore_errors=True)
        return False
