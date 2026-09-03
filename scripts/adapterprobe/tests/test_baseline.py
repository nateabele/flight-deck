import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from run import corpus_staleness, diff_baseline, render

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


if __name__ == "__main__":
    unittest.main()
