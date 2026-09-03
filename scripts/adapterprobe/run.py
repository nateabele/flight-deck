#!/usr/bin/env python3
"""The matrix runner: executes `capabilities.ROWS`, renders the report, diffs the baseline.

Implements the `ProbeContext` contract documented at the top of `capabilities.py` — exactly
those six members (`probe`, `sandbox`, `pty`, `seed_one_turn`, `seeded_marker`, `versions`).
Everything else on this class (`last_transcript`, `_probe_path`, `_timeout`, `_ptys`,
`_accepting_ptys`) is `run.py`'s own bookkeeping — for `--capture`, and for pty cleanup/timeout
enforcement between rows; no row is allowed to reach for any of it.
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

# Where `--capture` writes the transcripts a full-tier row produced. NEVER the Swift fixtures
# under `Tests/FlightDeckTests/Fixtures/` — those are sha256-pinned by `TimelineFixtureTests`,
# so a `--capture` writing there would deterministically break the Swift suite on the very next
# `--tier full` run, and codex writes its home's `~/.agents/skills` inventory regardless of
# `CODEX_HOME` (see `Fixtures/Codex/rollout.captured.provenance.json`'s own account of a real
# leak caught only by hand-scanning a capture after the fact) — a sandbox does not make a
# capture clean enough to land directly on a pinned fixture unreviewed. This directory is
# gitignored; promoting a capture into the checked-in corpus is a deliberate, reviewed, separate
# step, never this flag's side effect.
CORPUS_CAPTURE_DIR = os.path.join(HERE, "corpus")
CORPUS_DEST = {
    "claude": os.path.join(CORPUS_CAPTURE_DIR, "claude.transcript.captured.jsonl"),
    "codex": os.path.join(CORPUS_CAPTURE_DIR, "codex.rollout.captured.jsonl"),
}

GLYPH = {"ok": "✓", "broken": "✗", "by-design": "⊘", "rotted": "!",
         "needs-auth": "🔒", "error": "?"}

# A hard wall-clock cap per row, keyed by `row.tier` -- nothing any row does (a hung live pty, a
# wedged subprocess) is allowed to cost more than this before the runner declares it dead, kills
# whatever it spawned, and moves on. A single row spinning forever with no output is
# indistinguishable from the whole run being dead; this is what makes that distinguishable.
#
# The cap must exceed the worst *bounded* chain a row of that tier can legitimately take before
# any of its own component timeouts would have given up on their own -- otherwise a merely slow
# (not hung) agent gets force-recorded as `error` on exactly the rows this suite exists to
# measure, and the next task pins that wrong verdict into `baseline.json`.
#
# `_resume_command` (full tier) is the worst case: `prepare` (<= PROBE_TIMEOUT) + `seed_one_turn`
# (its own launch-command probe <= PROBE_TIMEOUT, plus two 30s `term.wait`s, plus a fixed 20s
# `term.pump`) + its own `resume-command` probe (<= PROBE_TIMEOUT) + a 60s attach `term.wait`.
PROBE_TIMEOUT = 45  # ProbeContext.__init__'s own default `timeout=`
_SEED_ONE_TURN_CHAIN = PROBE_TIMEOUT + 30 + 30 + 20  # == 125
_WORST_FULL_CHAIN = PROBE_TIMEOUT + _SEED_ONE_TURN_CHAIN + PROBE_TIMEOUT + 60  # == 275

ROW_TIMEOUT = {"cheap": 120, "full": 420}
assert ROW_TIMEOUT["full"] > _WORST_FULL_CHAIN, (
    "ROW_TIMEOUT['full'] must stay strictly greater than the worst bounded chain a full-tier "
    "row can legitimately take -- if capabilities.py grows a longer chain than the one this "
    "constant is computed from, update both."
)


def agent_versions():
    def v(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=20
                                  ).stdout.strip().splitlines()[0]
        except Exception:
            return "unavailable"
    return {"codex": v(["codex", "--version"]), "claude": v(["claude", "--version"])}


def diff_baseline(baseline, matrix, tiers=None):
    """`tiers` is the set of tiers *this run* exercised. A baseline cell missing from the
    matrix is only real drift (`removed`) if this run actually attempted its tier -- otherwise
    it is merely `skipped`: not attempted, which is a different fact than gone. A `--tier cheap`
    run against a baseline recorded with `--tier full` must not report every full-tier-only cell
    as removed just because this run never went looking for it.

    `tiers=None` (the default) disables this distinction entirely and treats every baseline key
    missing from the matrix as `removed`, matching this function's original, tier-blind
    behavior -- used by callers (and most of this module's own tests) that pass a matrix already
    scoped to exactly what they want compared.

    A baseline cell with no recorded tier (an older `baseline.json`, or a synthetic one in a
    test) is always compared: with no tier of its own to check against `tiers`, there is no
    basis for saying it wasn't attempted, so it is never exempted from `removed`.
    """
    b, m = baseline.get("cells", {}), matrix.get("cells", {})
    b_tiers = baseline.get("tiers", {})

    def exercised(k):
        if tiers is None:
            return True
        t = b_tiers.get(k)
        return t is None or t in tiers

    missing = b.keys() - m.keys()
    changed = {k: (b[k], m[k]) for k in b.keys() & m.keys() if b[k] != m[k]}
    bv, mv = baseline.get("versions", {}), matrix.get("versions", {})
    return {
        "changed": changed,
        "added": {k: m[k] for k in m.keys() - b.keys()},
        "removed": {k: b[k] for k in missing if exercised(k)},
        "skipped": {k: b[k] for k in missing if not exercised(k)},
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
        # Set by `_run_one` for the duration of exactly one row's execution. A pty is only ever
        # legitimate while its owning row is still the one running; an orphaned daemon thread
        # from a row that has already timed out has no business starting a fresh, credentialed
        # agent that nothing left running would ever go on to close.
        self._accepting_ptys = True
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
        # `probe` is built from a coverage-instrumented `FlightDeck` dylib (Debug always sets
        # `-enable-testing`, and this checkout also profiles), so every one of the hundreds of
        # invocations a run makes would otherwise drop its own `default.profraw` -- ~165 MB a
        # run, and none of it examined by anything this suite does.
        env["LLVM_PROFILE_FILE"] = "/dev/null"
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
        if not self._accepting_ptys:
            raise RuntimeError(
                "ctx.pty() called after this row already finished -- refusing to fork a "
                "fresh agent that nothing would ever go on to close")
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
    cap = ROW_TIMEOUT[row.tier]

    def target():
        try:
            result["obs"] = row.run(ctx, agent)
        except Exception:
            result["exc"] = traceback.format_exc()

    ctx._accepting_ptys = True
    start = time.time()
    t = threading.Thread(target=target, daemon=True)
    t.start()
    t.join(cap)
    elapsed = time.time() - start
    timed_out = t.is_alive()
    # From here on, any pty this row's thread (or an orphan of it) still tries to open is
    # refused -- see `ProbeContext.pty`'s guard -- before we close out whatever it already
    # opened.
    ctx._accepting_ptys = False
    try:
        ctx._close_ptys()
    except Exception:
        pass
    if timed_out:
        return "error", f"row timed out after {elapsed:.1f}s (cap {cap}s)", elapsed
    if "exc" in result:
        return "error", result["exc"], elapsed
    obs = result["obs"]
    return (verdict(obs.declared, obs.observed, obs.absent_reason_holds, kind=row.kind),
            obs.detail, elapsed)


def _run_matrix(ctx, tiers):
    """Crash-isolated: one bad row records an `error` cell and never costs the others. Each row
    also gets its own hard wall-clock cap (see `_run_one`) and one progress line as it starts and
    one as it finishes, flushed immediately -- with no output at all, "still working" and
    "silently wedged" look identical from outside. Records each cell's tier alongside its
    verdict -- `diff_baseline` needs it to tell a cell this run genuinely never attempted from
    one that used to exist and no longer does."""
    cells, details, cell_tiers = {}, {}, {}
    for row in ROWS:
        if row.tier not in tiers:
            continue
        for agent in row.agents:
            key = f"{agent}.{row.key}"
            print(f"... {key}", flush=True)
            v, detail, elapsed = _run_one(ctx, row, agent)
            cells[key] = v
            cell_tiers[key] = row.tier
            if detail:
                details[key] = detail
            print(f"{GLYPH.get(v, '?')} {v:<11} {key}  ({elapsed:.1f}s)", flush=True)
    return {"versions": ctx.versions, "cells": cells, "details": details, "tiers": cell_tiers}


def _capture(ctx):
    """Stages this run's transcripts under the gitignored `CORPUS_CAPTURE_DIR` -- never over
    the pinned `Fixtures/{Claude,Codex}/*.captured.jsonl` files, and never touches the
    committed `corpus.json` either. Both of those are promotion steps: a raw capture has not
    been scanned for anything a throwaway sandbox failed to keep private (see `CORPUS_DEST`'s
    own comment), so this function's job ends at "here is what came out, and here is what
    version it came from" -- a human decides whether that is fit to promote."""
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
    for agent, version in captured.items():
        print(f"--capture: staged {CORPUS_DEST[agent]} (captured against {version}); "
              f"review by hand before promoting into Fixtures/ and updating corpus.json")


def _exit_code(diff):
    """0 clean, 1 capability drift, 3 harness failure -- and `error` never satisfies any
    baseline expectation, so it always outranks plain drift. That has to hold whether the
    `error` cell shows up in `changed` (something that used to read `ok` now reads `error`) or
    in `added` (a cell with no baseline entry at all reads `error`) -- the latter is this
    repo's exact current state before any `baseline.json` exists, and a wholly broken harness
    must not be reported as mere "capability drift"."""
    harness_failures = {k: v for k, v in diff["changed"].items()
                         if v[1] == "error" and v[0] != "error"}
    harness_failures.update({k: v for k, v in diff["added"].items() if v == "error"})
    if harness_failures:
        return 3, harness_failures
    if diff["changed"] or diff["added"] or diff["removed"]:
        return 1, harness_failures
    return 0, harness_failures


def build_probe():
    subprocess.run([BUILD_PROBE], check=True, cwd=REPO)


def _real_agent_listing():
    """`~/.codex/sessions` and `~/.claude/projects` as they stand in the REAL home -- spec
    invariant 9. Every live agent this run drives runs inside `AgentSandbox`'s throwaway
    `codex_home`/`claude_home`, so nothing in this run has any legitimate reason to add,
    remove, or rename anything these two real directories list; `main()` snapshots this before
    the sandbox opens and asserts it is unchanged after the sandbox is gone, so a redirection
    leak (the exact failure mode `_environment`'s row exists to catch on the adapter side) would
    also be caught here as a harness-level guarantee, independent of any one row's own verdict.
    """
    def listing(path):
        return sorted(os.listdir(path)) if os.path.isdir(path) else None
    return {
        "codex_sessions": listing(os.path.expanduser("~/.codex/sessions")),
        "claude_projects": listing(os.path.expanduser("~/.claude/projects")),
    }


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
    real_before = _real_agent_listing()

    try:
        build_probe()
    except subprocess.CalledProcessError as e:
        print(f"error: build-probe.sh failed: {e}", file=sys.stderr)
        return 2

    try:
        with AgentSandbox(keep=args.keep) as sb:
            ctx = ProbeContext(sb)
            try:
                matrix = _run_matrix(ctx, tiers)
                if args.capture:
                    _capture(ctx)
            finally:
                # `_run_one` already closes out every row's own ptys, but this is the backstop
                # for anything a still-running orphan thread stashed in `ctx._ptys` after its
                # row's own cleanup ran -- nothing is allowed to survive past the sandbox tree
                # being torn down, no matter what state any leftover thread is in.
                ctx._close_ptys()
    except UnsafeHome as e:
        print(f"refusing to proceed: {e}", file=sys.stderr)
        return 4

    real_after = _real_agent_listing()
    if real_after != real_before:
        print(f"error: this run touched the REAL agent state it must never reach -- "
              f"before={real_before!r} after={real_after!r}", file=sys.stderr)
        return 5

    corpus = {}
    if os.path.exists(CORPUS):
        with open(CORPUS) as f:
            corpus = json.load(f)
    stale = corpus_staleness(corpus, matrix["versions"])
    if stale:
        print(f"corpus stale: {stale}")

    found_baseline = os.path.exists(BASELINE)
    if found_baseline:
        with open(BASELINE) as f:
            baseline = json.load(f)
    else:
        baseline = {"versions": {}, "cells": {}, "tiers": {}}

    # Computed even in `--update-baseline` mode -- cheap, and the skip line below is worth
    # seeing on any run, not just a diffing one. Not used to decide anything in that mode: the
    # write below always replaces the whole file with exactly this run's matrix.
    diff = diff_baseline(baseline, matrix, tiers=tiers)
    if diff["skipped"]:
        skipped_tiers = sorted({baseline.get("tiers", {}).get(k) for k in diff["skipped"]} - {None})
        label = skipped_tiers[0] if len(skipped_tiers) == 1 else "other-tier"
        print(f"{len(diff['skipped'])} {label}-tier cells not exercised "
              f"(run --tier {label} to check them)")

    print(render(matrix))

    if args.json:
        with open(args.json, "w") as f:
            json.dump(matrix, f, indent=2, sort_keys=True)

    if args.update_baseline:
        with open(BASELINE, "w") as f:
            json.dump(matrix, f, indent=2, sort_keys=True)
        return 0

    if not found_baseline:
        print("no baseline.json yet; every cell is reported as new", file=sys.stderr)

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

    code, harness_failures = _exit_code(diff)
    if harness_failures:
        print(f"harness failure: {harness_failures}", file=sys.stderr)
    return code


if __name__ == "__main__":
    sys.exit(main())
