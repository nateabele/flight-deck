#!/usr/bin/env python3
"""The matrix runner: executes `capabilities.ROWS`, renders the report, diffs the baseline.

Implements the `ProbeContext` contract documented at the top of `capabilities.py` — exactly
those six members (`probe`, `sandbox`, `pty`, `seed_one_turn`, `seeded_marker`, `versions`).
Everything else on this class (`last_transcript`, `_probe_path`, `_timeout`, `_ptys`) is
`run.py`'s own bookkeeping — for `--capture`, and for pty cleanup/timeout enforcement between
rows; no row is allowed to reach for any of it.
"""
import argparse, json, os, shutil, subprocess, sys, threading, time, traceback, uuid

from capabilities import ROWS, verdict
from ptyscreen import PtyScreen
from sandbox import AgentSandbox, UnsafeHome

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PROBE = os.path.join(REPO, "DerivedData", "adapterprobe", "probe")
BUILD_PROBE = os.path.join(HERE, "build-probe.sh")
BASELINE = os.path.join(HERE, "baseline.json")
CORPUS = os.path.join(HERE, "corpus.json")
FIXTURES = os.path.join(REPO, "Tests", "FlightDeckTests", "Fixtures")

# The same "up" markers `capabilities.py` keeps private to itself (`_UP_MARKER`) — duplicated
# here rather than imported, because a row must only ever see the six-member contract, and
# `run.py` is not a row.
UP_MARKER = {"claude": "Claude Code", "codex": "OpenAI Codex"}

# Where `--capture` writes the transcripts a full-tier row produced. Same files
# `capabilities.py`'s `_CLAUDE_TRANSCRIPT` / `_CODEX_ROLLOUT` read back as the checked-in corpus.
CORPUS_DEST = {
    "claude": os.path.join(FIXTURES, "Claude", "transcript.captured.jsonl"),
    "codex": os.path.join(FIXTURES, "Codex", "rollout.captured.jsonl"),
}

GLYPH = {"ok": "✓", "broken": "✗", "by-design": "⊘", "rotted": "!",
         "needs-auth": "🔒", "error": "?"}

# A hard wall-clock cap per row. Nothing any row does -- a hung live pty, a wedged subprocess --
# is allowed to cost more than this before the runner declares it dead, kills whatever it spawned,
# and moves on. A single row spinning forever with no output is indistinguishable from the whole
# run being dead; this is what makes that distinguishable.
ROW_TIMEOUT = 120


def agent_versions():
    def v(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=20
                                  ).stdout.strip().splitlines()[0]
        except Exception:
            return "unavailable"
    return {"codex": v(["codex", "--version"]), "claude": v(["claude", "--version"])}


def diff_baseline(baseline, matrix):
    b, m = baseline.get("cells", {}), matrix.get("cells", {})
    changed = {k: (b[k], m[k]) for k in b.keys() & m.keys() if b[k] != m[k]}
    bv, mv = baseline.get("versions", {}), matrix.get("versions", {})
    return {
        "changed": changed,
        "added": {k: m[k] for k in m.keys() - b.keys()},
        "removed": {k: b[k] for k in b.keys() - m.keys()},
        "versions_changed": {k: (bv[k], mv[k]) for k in bv.keys() & mv.keys() if bv[k] != mv[k]},
    }


def render(matrix):
    lines = [f"agents: {matrix['versions']}", ""]
    for key, v in sorted(matrix["cells"].items()):
        detail = matrix.get("details", {}).get(key, "")
        lines.append(f"  {GLYPH.get(v, '?')} {v:<11} {key}" + (f"   — {detail}" if detail else ""))
    return "\n".join(lines)


def corpus_staleness(corpus, versions):
    """A grammar checked only against an old corpus is checking history, not today."""
    return {k: (corpus.get("versions", {}).get(k), versions[k])
            for k in versions
            if corpus.get("versions", {}).get(k) not in (None, versions[k])}


class ProbeContext:
    """The live `ProbeContext` a real run hands to every row."""

    def __init__(self, sandbox, probe_path=PROBE, timeout=45):
        self.sandbox = sandbox
        self.versions = agent_versions()
        self.seeded_marker = f"adapterprobe-seed-{uuid.uuid4().hex[:8]}: reply with exactly OK"
        self._probe_path = probe_path
        self._timeout = timeout
        # Recorded here, not returned by any row: `main()`'s only way to find the transcript
        # a full-tier row produced, for `--capture`, without widening what a row may call.
        self.last_transcript = {}
        # Every `PtyScreen` this context has ever handed out. A row is trusted to use its own
        # `with`, but not relied on to -- `_run_matrix` closes whatever is still open here after
        # every row, whether that row returned, raised, or was abandoned mid-`wait()` by a
        # timeout. Closing an already-closed `PtyScreen` must be harmless.
        self._ptys = []
        self._dismiss_codex_onboarding()

    def _dismiss_codex_onboarding(self):
        """Two pieces of codex-cli's own first-run UX, neither of which is the adapter
        capability any row exists to check, and both of which would otherwise eat a live-pty
        row's `wait()` budget and misreport it as `broken`:

        - A "do you trust this directory" prompt the first time codex ever sees a given cwd.
          A fresh sandbox root is by construction such a cwd. A real Flight Deck install's
          `~/.codex/config.toml` already carries a `[projects."<path>".trust_level]` entry for
          every folder it has been pointed at; pre-writing the same entry for the one
          directory this run owns is the sandbox equivalent, on the same footing as the
          credentials `AgentSandbox` already copies in. Keyed on the resolved path because
          codex resolves symlinks before it checks trust, and on macOS `TMPDIR` sits under
          `/var`, itself a symlink into `/private`.

        - An "update available" splash the moment codex notices its own version lags the
          latest, which on this machine it already does (the installed CLI reports
          `codex-cli 0.152.1`; the TUI binary it launches identifies itself as `v0.142.4`).
          The real `~/.codex/version.json` records that gap as already seen and dismissed;
          copying it in (or synthesizing an equivalent if the real one is missing) keeps every
          row in this run past a splash that is about codex's own release cadence, not
          anything an adapter row is testing.
        """
        real_root = os.path.realpath(self.sandbox.root)
        with open(os.path.join(self.sandbox.codex_home, "config.toml"), "a") as f:
            f.write(f'\n[projects."{real_root}"]\ntrust_level = "trusted"\n')

        real_version_json = os.path.expanduser("~/.codex/version.json")
        version = {}
        if os.path.exists(real_version_json):
            with open(real_version_json) as f:
                version = json.load(f)
        version.setdefault("latest_version", self.versions["codex"].split()[-1])
        version["dismissed_version"] = version["latest_version"]
        with open(os.path.join(self.sandbox.codex_home, "version.json"), "w") as f:
            json.dump(version, f)

    def probe(self, args, stdin=""):
        agent = args[1] if len(args) > 1 else None
        env = self.sandbox.child_env(agent) if agent in ("claude", "codex") else dict(os.environ)
        try:
            proc = subprocess.run(
                [self._probe_path, *args], input=stdin, capture_output=True, text=True,
                env=env, timeout=self._timeout,
            )
        except subprocess.TimeoutExpired as e:
            raise RuntimeError(f"probe timed out on {args!r}") from e
        if proc.returncode == 2:
            raise RuntimeError(f"probe usage error on {args!r}: {proc.stderr.strip()}")
        if proc.returncode not in (0, 1):
            raise RuntimeError(
                f"probe exited {proc.returncode} on {args!r}: {proc.stderr.strip()}")
        try:
            out = json.loads(proc.stdout)
        except json.JSONDecodeError as e:
            raise RuntimeError(
                f"probe produced unparseable output on {args!r}: {proc.stdout!r}") from e
        if args and args[0] == "prepare" and agent in ("claude", "codex") and out.get(
                "transcriptURL"):
            self.last_transcript[agent] = out["transcriptURL"]
        return out

    def pty(self, agent, cmd):
        term = PtyScreen(cmd, cwd=self.sandbox.root, env=self.sandbox.child_env(agent))
        self._ptys.append(term)
        return term

    def _close_ptys(self):
        """Force-closes every `PtyScreen` this context has ever handed out, whether or not the
        row that opened it is still running. Called after every row, timed out or not, so one
        row's leaked pty can never wedge -- or outlive -- the run."""
        while self._ptys:
            term = self._ptys.pop()
            try:
                term.close()
            except Exception:
                pass

    def seed_one_turn(self, agent, cid):
        """Drives one real turn so a resume row has prior history to attach to. The marker is
        the line we type, not anything the model chooses to say back — it is guaranteed to
        show up the moment it is echoed into the transcript, and again after a real resume,
        without depending on the model complying with the request folded into it."""
        text = self.probe(
            ["launch-command", agent, "--id", cid, "--cwd", self.sandbox.root])["text"]
        with self.pty(agent, ["/bin/sh", "-lc", text]) as term:
            if not term.wait([UP_MARKER[agent]], 30):
                raise RuntimeError(f"{agent} never came up for seed_one_turn")
            term.send((self.seeded_marker + "\r").encode())
            if not term.wait([self.seeded_marker], 30):
                raise RuntimeError(f"{agent} never echoed the seed marker")
            # A fixed dwell for the turn to actually finish and its transcript to flush before
            # the pty is torn down. The instruction folded into the marker keeps the model's
            # own reply short, but the wait does not depend on seeing it.
            term.pump(20)


def _run_one(ctx, row, agent):
    """Runs one row under a hard wall-clock cap (`ROW_TIMEOUT`), guaranteeing every pty the row
    opened is closed before this returns -- on a clean return, on a raised exception, or on a
    timeout the row itself never returned from. `ctx._close_ptys()` runs in a `finally` rather
    than relying on the row's own `with` -- a row is not trusted to always use one correctly, and
    a wedged live pty is exactly the kind of thing a timeout exists to interrupt.

    The row runs on a daemon thread so a genuinely uninterruptible wedge (blocked on a syscall,
    not just a slow `wait()`) cannot hang the whole run past `ROW_TIMEOUT` -- this function
    returns regardless, records `error`, and lets process exit reap the thread later.
    """
    result = {}

    def target():
        try:
            result["obs"] = row.run(ctx, agent)
        except Exception:
            result["exc"] = traceback.format_exc()

    start = time.time()
    t = threading.Thread(target=target, daemon=True)
    t.start()
    t.join(ROW_TIMEOUT)
    elapsed = time.time() - start
    timed_out = t.is_alive()
    try:
        ctx._close_ptys()
    except Exception:
        pass
    if timed_out:
        return "error", f"row timed out after {elapsed:.1f}s (cap {ROW_TIMEOUT}s)", elapsed
    if "exc" in result:
        return "error", result["exc"], elapsed
    obs = result["obs"]
    return (verdict(obs.declared, obs.observed, obs.absent_reason_holds, kind=row.kind),
            obs.detail, elapsed)


def _run_matrix(ctx, tiers):
    """Crash-isolated: one bad row records an `error` cell and never costs the others. Each row
    also gets its own hard wall-clock cap (see `_run_one`) and one progress line as it starts and
    one as it finishes, flushed immediately -- with no output at all, "still working" and
    "silently wedged" look identical from outside."""
    cells, details = {}, {}
    for row in ROWS:
        if row.tier not in tiers:
            continue
        for agent in row.agents:
            key = f"{agent}.{row.key}"
            print(f"... {key}", flush=True)
            v, detail, elapsed = _run_one(ctx, row, agent)
            cells[key] = v
            if detail:
                details[key] = detail
            print(f"{GLYPH.get(v, '?')} {v:<11} {key}  ({elapsed:.1f}s)", flush=True)
    return {"versions": ctx.versions, "cells": cells, "details": details}


def _capture(ctx):
    captured = {}
    for agent, dest in CORPUS_DEST.items():
        src = ctx.last_transcript.get(agent)
        if not src or not os.path.exists(src):
            print(f"--capture: no transcript captured for {agent} "
                  f"(needs a full-tier row that renamed or resumed); skipping", file=sys.stderr)
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(src, dest)
        captured[agent] = ctx.versions[agent]
    if not captured:
        return
    existing = {}
    if os.path.exists(CORPUS):
        with open(CORPUS) as f:
            existing = json.load(f)
    existing.setdefault("versions", {}).update(captured)
    with open(CORPUS, "w") as f:
        json.dump(existing, f, indent=2, sort_keys=True)
        f.write("\n")


def build_probe():
    subprocess.run([BUILD_PROBE], check=True, cwd=REPO)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run the adapter capability matrix.")
    ap.add_argument("--tier", choices=("cheap", "full"), default="cheap")
    ap.add_argument("--capture", action="store_true",
                     help="refresh the grammar corpus from this run's full-tier transcripts")
    ap.add_argument("--keep", action="store_true", help="keep the sandbox tree after the run")
    ap.add_argument("--update-baseline", action="store_true",
                     help="write this run's matrix to baseline.json instead of diffing")
    ap.add_argument("--json", metavar="PATH", help="also write the matrix as JSON to PATH")
    args = ap.parse_args(argv)

    tiers = {"cheap"} if args.tier == "cheap" else {"cheap", "full"}

    try:
        build_probe()
    except subprocess.CalledProcessError as e:
        print(f"error: build-probe.sh failed: {e}", file=sys.stderr)
        return 2

    try:
        with AgentSandbox(keep=args.keep) as sb:
            ctx = ProbeContext(sb)
            matrix = _run_matrix(ctx, tiers)
            if args.capture:
                _capture(ctx)
    except UnsafeHome as e:
        print(f"refusing to proceed: {e}", file=sys.stderr)
        return 4

    corpus = {}
    if os.path.exists(CORPUS):
        with open(CORPUS) as f:
            corpus = json.load(f)
    stale = corpus_staleness(corpus, matrix["versions"])
    if stale:
        print(f"corpus stale: {stale}")

    print(render(matrix))

    if args.json:
        with open(args.json, "w") as f:
            json.dump(matrix, f, indent=2, sort_keys=True)

    if args.update_baseline:
        with open(BASELINE, "w") as f:
            json.dump(matrix, f, indent=2, sort_keys=True)
        return 0

    if os.path.exists(BASELINE):
        with open(BASELINE) as f:
            baseline = json.load(f)
    else:
        print("no baseline.json yet; every cell is reported as new", file=sys.stderr)
        baseline = {"versions": {}, "cells": {}}

    diff = diff_baseline(baseline, matrix)
    if diff["added"] or diff["removed"] or diff["changed"] or diff["versions_changed"]:
        print()
        print("diff against baseline:")
        for k, v in sorted(diff["added"].items()):
            print(f"  + {k}: {v}")
        for k, v in sorted(diff["removed"].items()):
            print(f"  - {k}: {v}")
        for k, (old, new) in sorted(diff["changed"].items()):
            print(f"  ~ {k}: {old} -> {new}")
        for k, (old, new) in sorted(diff["versions_changed"].items()):
            print(f"  v {k}: {old} -> {new}")

    # A cell that turned to `error` where the baseline expected something else is the harness
    # itself failing, not a capability regressing — must be distinguishable from plain drift.
    harness_failures = {k: v for k, v in diff["changed"].items()
                         if v[1] == "error" and v[0] != "error"}
    if harness_failures:
        print(f"harness failure: {harness_failures}", file=sys.stderr)
        return 3
    if diff["changed"] or diff["added"] or diff["removed"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
