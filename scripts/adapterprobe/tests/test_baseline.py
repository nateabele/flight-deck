import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from run import _exit_code, corpus_staleness, diff_baseline, render

BASE = {"versions": {"codex": "0.152.1", "claude": "2.1.258"},
        "cells": {"codex.rename": "ok", "codex.resumeCommand": "broken"}}


class BaselineDiffTests(unittest.TestCase):
    def test_identical_matrix_has_no_drift(self):
        d = diff_baseline(BASE, {"versions": BASE["versions"], "cells": dict(BASE["cells"])})
        self.assertEqual(d["changed"], {})
        self.assertEqual(d["added"], {})
        self.assertEqual(d["removed"], {})

    def test_a_regression_is_reported_as_changed(self):
        m = {"versions": BASE["versions"], "cells": {**BASE["cells"], "codex.rename": "broken"}}
        self.assertEqual(diff_baseline(BASE, m)["changed"],
                         {"codex.rename": ("ok", "broken")})

    def test_a_fix_is_also_reported_so_the_baseline_records_when_it_started_working(self):
        m = {"versions": BASE["versions"],
             "cells": {**BASE["cells"], "codex.resumeCommand": "ok"}}
        self.assertEqual(diff_baseline(BASE, m)["changed"],
                         {"codex.resumeCommand": ("broken", "ok")})

    def test_a_new_row_is_added_not_changed(self):
        m = {"versions": BASE["versions"], "cells": {**BASE["cells"], "codex.read": "ok"}}
        d = diff_baseline(BASE, m)
        self.assertEqual(d["added"], {"codex.read": "ok"})
        self.assertEqual(d["changed"], {})

    def test_a_version_bump_is_reported_even_with_an_identical_matrix(self):
        m = {"versions": {"codex": "0.153.0", "claude": "2.1.258"},
             "cells": dict(BASE["cells"])}
        self.assertEqual(diff_baseline(BASE, m)["versions_changed"],
                         {"codex": ("0.152.1", "0.153.0")})

    def test_a_pty_resolved_version_drift_is_reported_even_when_the_plain_one_matches(self):
        # `codex`/`claude` name whatever this process's own PATH resolves; `*_pty` names
        # whatever a live pty row's login shell resolves -- a machine with two binaries on
        # different paths can drift in the second without the first ever moving, and that
        # drift must not be silently absorbed just because the plain key still matches.
        base = {**BASE, "versions": {**BASE["versions"], "codex_pty": "0.142.4"}}
        m = {"versions": {**base["versions"], "codex_pty": "0.148.0"},
             "cells": dict(BASE["cells"])}
        self.assertEqual(diff_baseline(base, m)["versions_changed"],
                         {"codex_pty": ("0.142.4", "0.148.0")})


class RenderTests(unittest.TestCase):
    def test_every_cell_and_its_glyph_appear(self):
        out = render({"versions": {"codex": "0.152.1", "claude": "2.1.258"},
                       "cells": {"codex.rename": "ok", "claude.rename": "broken"}})
        self.assertIn("✓", out)
        self.assertIn("✗", out)
        self.assertIn("codex.rename", out)
        self.assertIn("claude.rename", out)

    def test_a_detail_is_appended_after_its_cell(self):
        out = render({"versions": {"codex": "0.152.1", "claude": "2.1.258"},
                       "cells": {"codex.rebind": "error"},
                       "details": {"codex.rebind": "boom"}})
        self.assertIn("codex.rebind", out)
        self.assertIn("boom", out)

    def test_an_unknown_verdict_gets_the_fallback_glyph_rather_than_crashing(self):
        out = render({"versions": {}, "cells": {"codex.mystery": "somethingnew"}})
        self.assertIn("?", out)
        self.assertIn("codex.mystery", out)

    def test_rows_are_sorted_by_key_so_output_is_stable(self):
        out = render({"versions": {},
                       "cells": {"codex.zeta": "ok", "codex.alpha": "ok"}})
        self.assertLess(out.index("codex.alpha"), out.index("codex.zeta"))


class CorpusStalenessTests(unittest.TestCase):
    def test_no_corpus_yet_is_not_reported_as_stale(self):
        self.assertEqual(corpus_staleness({}, {"codex": "0.152.1", "claude": "2.1.258"}), {})

    def test_a_matching_corpus_is_not_stale(self):
        corpus = {"versions": {"codex": "0.152.1"}}
        self.assertEqual(corpus_staleness(corpus, {"codex": "0.152.1", "claude": "2.1.258"}), {})

    def test_an_older_recorded_version_is_reported_stale(self):
        corpus = {"versions": {"codex": "0.150.0"}}
        self.assertEqual(
            corpus_staleness(corpus, {"codex": "0.152.1", "claude": "2.1.258"}),
            {"codex": ("0.150.0", "0.152.1")})


class ExitCodeTests(unittest.TestCase):
    """`error` never satisfies a baseline expectation and never reads as a statement about the
    adapter -- so it must outrank plain drift whether it lands in `changed` or in `added`."""

    def test_an_identical_matrix_is_exit_0(self):
        m = {"versions": BASE["versions"], "cells": dict(BASE["cells"])}
        code, failures = _exit_code(diff_baseline(BASE, m))
        self.assertEqual(code, 0)
        self.assertEqual(failures, {})

    def test_a_regression_with_no_error_involved_is_exit_1(self):
        m = {"versions": BASE["versions"], "cells": {**BASE["cells"], "codex.rename": "broken"}}
        code, failures = _exit_code(diff_baseline(BASE, m))
        self.assertEqual(code, 1)
        self.assertEqual(failures, {})

    def test_a_changed_cell_turning_to_error_is_exit_3_not_1(self):
        m = {"versions": BASE["versions"], "cells": {**BASE["cells"], "codex.rename": "error"}}
        code, failures = _exit_code(diff_baseline(BASE, m))
        self.assertEqual(code, 3)
        self.assertEqual(failures, {"codex.rename": ("ok", "error")})

    def test_an_added_error_cell_is_exit_3_even_with_no_baseline_yet(self):
        # This is the repo's exact current state: no `baseline.json` exists yet, so every cell
        # shows up as `added` -- a wholly broken harness must not read as "capability drift".
        diff = diff_baseline({"versions": {}, "cells": {}},
                              {"versions": {}, "cells": {"codex.rebind": "error"}})
        code, failures = _exit_code(diff)
        self.assertEqual(code, 3)
        self.assertEqual(failures, {"codex.rebind": "error"})

    def test_a_cell_that_was_already_error_in_the_baseline_and_stays_error_is_not_a_new_failure(
            self):
        base = {"versions": {}, "cells": {"codex.needsRuntimeStart": "error"}}
        m = {"versions": {}, "cells": {"codex.needsRuntimeStart": "error"}}
        code, failures = _exit_code(diff_baseline(base, m))
        self.assertEqual(code, 0)
        self.assertEqual(failures, {})


MIXED_TIER_BASE = {
    "versions": {"codex": "0.152.1", "claude": "2.1.258"},
    "cells": {"codex.rename": "ok", "codex.resumeCommand": "broken", "codex.rebind": "ok"},
    "tiers": {"codex.rename": "full", "codex.resumeCommand": "full", "codex.rebind": "cheap"},
}


class TierAwareDiffTests(unittest.TestCase):
    """A `--tier cheap` run must not report every full-tier-only baseline cell as `removed`
    just because it never went looking for it -- that is this repo's exact default-invocation
    defect: a bare `./scripts/test-adapters.sh` always failed against a `--tier full` baseline,
    for cells it structurally cannot have run."""

    def test_a_cheap_run_against_a_full_tier_baseline_exits_0_when_cheap_cells_match(self):
        m = {"versions": MIXED_TIER_BASE["versions"], "cells": {"codex.rebind": "ok"}}
        diff = diff_baseline(MIXED_TIER_BASE, m, tiers={"cheap"})
        self.assertEqual(diff["removed"], {})
        self.assertEqual(diff["changed"], {})
        code, failures = _exit_code(diff)
        self.assertEqual(code, 0)
        self.assertEqual(failures, {})

    def test_the_two_full_tier_only_cells_are_skipped_not_removed(self):
        m = {"versions": MIXED_TIER_BASE["versions"], "cells": {"codex.rebind": "ok"}}
        diff = diff_baseline(MIXED_TIER_BASE, m, tiers={"cheap"})
        self.assertEqual(diff["skipped"],
                          {"codex.rename": "ok", "codex.resumeCommand": "broken"})
        self.assertEqual(diff["removed"], {})

    def test_a_cheap_cell_that_genuinely_disappeared_still_reports_removed(self):
        # Its own tier (cheap) WAS exercised by this run -- being absent from the matrix is
        # real drift, not "not attempted".
        m = {"versions": MIXED_TIER_BASE["versions"], "cells": {}}
        diff = diff_baseline(MIXED_TIER_BASE, m, tiers={"cheap"})
        self.assertEqual(diff["removed"], {"codex.rebind": "ok"})

    def test_a_full_tier_run_against_the_same_baseline_sees_every_cell(self):
        m = {"versions": MIXED_TIER_BASE["versions"],
             "cells": dict(MIXED_TIER_BASE["cells"])}
        diff = diff_baseline(MIXED_TIER_BASE, m, tiers={"cheap", "full"})
        self.assertEqual(diff["skipped"], {})
        self.assertEqual(diff["removed"], {})

    def test_a_baseline_entry_with_no_recorded_tier_is_still_compared(self):
        base = {"versions": {}, "cells": {"codex.mystery": "ok"}, "tiers": {}}
        diff = diff_baseline(base, {"versions": {}, "cells": {}}, tiers={"cheap"})
        self.assertEqual(diff["removed"], {"codex.mystery": "ok"})
        self.assertEqual(diff["skipped"], {})


if __name__ == "__main__":
    unittest.main()
