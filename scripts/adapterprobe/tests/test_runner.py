# scripts/adapterprobe/tests/test_runner.py
#
# `_run_one` / `ProbeContext`'s pty bookkeeping and timeout enforcement, exercised with fake
# rows and a stripped-down context -- no `AgentSandbox`, no probe binary, no live agent. A
# couple of tests below do spawn a real `/bin/sh` child through `ProbeContext.pty()`, same as
# `test_ptyscreen.py` already does directly against `PtyScreen`; neither is `claude` or
# `codex`.
import os, sys, time, unittest
from unittest.mock import patch

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from capabilities import Observation, Row
import run


class FakeSandbox:
    """Just enough of `AgentSandbox`'s public surface for `ProbeContext.pty()` to fork a real
    `/bin/sh`, never a live agent."""
    root = "/tmp"

    def child_env(self, agent):
        return {}


def _bare_context():
    """A `ProbeContext` with none of the real construction -- no sandbox homes, no codex
    onboarding files, no version probing -- just the bookkeeping `_run_one` and `pty()`
    actually exercise."""
    ctx = run.ProbeContext.__new__(run.ProbeContext)
    ctx.sandbox = FakeSandbox()
    ctx.last_transcript = {}
    ctx._ptys = []
    ctx._accepting_ptys = True
    return ctx


def _row(run_fn, tier="cheap", kind="capability"):
    return Row("fakeRow", "fake", ("codex",), tier, (), run_fn, kind)


class RunOneTests(unittest.TestCase):
    def test_a_raising_row_is_recorded_as_error_and_the_run_continues(self):
        def boom(ctx, agent):
            raise ValueError("kaboom")
        v, detail, _ = run._run_one(_bare_context(), _row(boom), "codex")
        self.assertEqual(v, "error")
        self.assertIn("kaboom", detail)

    def test_a_clean_row_is_verdicted_normally(self):
        def fine(ctx, agent):
            return Observation(declared=True, observed=True)
        v, _, _ = run._run_one(_bare_context(), _row(fine), "codex")
        self.assertEqual(v, "ok")

    def test_a_row_that_exceeds_the_cap_is_recorded_as_error_naming_the_timeout(self):
        def slow(ctx, agent):
            time.sleep(2)
            return Observation(declared=True, observed=True)
        with patch.object(run, "ROW_TIMEOUT", {"cheap": 0.2, "full": 0.2}):
            v, detail, elapsed = run._run_one(_bare_context(), _row(slow), "codex")
        self.assertEqual(v, "error")
        self.assertIn("timed out", detail)
        self.assertIn("0.2", detail)
        self.assertLess(elapsed, 1)  # `_run_one` returned at the cap, not after the sleep

    def test_a_pty_a_row_opens_is_closed_once_the_row_returns(self):
        def opens_a_pty(ctx, agent):
            ctx.pty(agent, ["/bin/sh", "-c", "sleep 5"])
            return Observation(declared=True, observed=True)
        ctx = _bare_context()
        run._run_one(ctx, _row(opens_a_pty), "codex")
        self.assertEqual(ctx._ptys, [])


class PtyGateTests(unittest.TestCase):
    def test_a_late_ctx_pty_call_after_the_row_finished_is_refused(self):
        ctx = _bare_context()
        ctx._accepting_ptys = False
        with self.assertRaises(RuntimeError):
            ctx.pty("codex", ["/bin/sh", "-c", "true"])

    def test_an_orphaned_thread_from_a_timed_out_row_cannot_open_a_pty_afterward(self):
        """The exact scenario Finding 2 named: a timed-out row's thread is still running --
        `_run_one` abandoned it, never killed it -- and calls `ctx.pty()` after `_run_one` has
        already moved on and closed out that row. It must be refused, not silently accepted
        into whatever runs next."""
        outcome = []

        def hangs_then_opens_late(ctx, agent):
            time.sleep(0.3)  # long enough that _run_one's join() has already given up
            try:
                ctx.pty(agent, ["/bin/sh", "-c", "true"])
                outcome.append("opened")
            except RuntimeError:
                outcome.append("refused")

        ctx = _bare_context()
        with patch.object(run, "ROW_TIMEOUT", {"cheap": 0.05, "full": 0.05}):
            v, _, _ = run._run_one(ctx, _row(hangs_then_opens_late), "codex")
        self.assertEqual(v, "error")

        deadline = time.time() + 2
        while not outcome and time.time() < deadline:
            time.sleep(0.02)
        self.assertEqual(outcome, ["refused"])
        self.assertEqual(ctx._ptys, [])


class ExitCodeTests(unittest.TestCase):
    def test_a_version_change_alone_is_not_a_clean_run(self):
        diff = {"changed": {}, "added": {}, "removed": {},
                "versions_changed": {"claude": ("2.1.263", "2.1.281")}}
        code, _ = run._exit_code(diff)
        self.assertNotEqual(code, 0,
            "a new agent build with identical cells must not report clean: the cells may be "
            "identical only because a frozen fixture cannot see the change")

    def test_a_clean_run_with_no_version_change_is_still_zero(self):
        diff = {"changed": {}, "added": {}, "removed": {}, "versions_changed": {}}
        code, _ = run._exit_code(diff)
        self.assertEqual(code, 0)

    def test_error_outranks_version_drift(self):
        """Even when the version also moved, a harness failure (`error`) must still win --
        the same ranking `_exit_code` already guarantees against plain capability drift."""
        diff = {"changed": {}, "added": {"someRow": "error"}, "removed": {},
                "versions_changed": {"claude": ("2.1.263", "2.1.281")}}
        code, _ = run._exit_code(diff)
        self.assertEqual(code, 3)

    def test_capability_drift_outranks_version_drift_alone(self):
        """A cell that actually moved is concrete, already-observed evidence -- stronger than
        merely knowing the version number changed with no cell to show for it -- so plain
        capability drift keeps its own code even when a version also moved."""
        diff = {"changed": {"someRow": ("ok", "unclaimed")}, "added": {}, "removed": {},
                "versions_changed": {"claude": ("2.1.263", "2.1.281")}}
        code, _ = run._exit_code(diff)
        self.assertEqual(code, 1)

    def test_version_drift_has_its_own_code_distinct_from_drift_and_harness_failure(self):
        diff = {"changed": {}, "added": {}, "removed": {},
                "versions_changed": {"claude": ("2.1.263", "2.1.281")}}
        code, _ = run._exit_code(diff)
        self.assertNotIn(code, (0, 1, 3))
        # Pinned exactly, not just "not one of the others": a future edit to `return 5` would
        # satisfy the assertion above while silently colliding with the listing-churn code.
        self.assertEqual(code, 6)


if __name__ == "__main__":
    unittest.main()
