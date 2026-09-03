# scripts/adapterprobe/tests/test_verdicts.py
#
# The brief's own selector, `-k "Verdict or RowTable"`, is a pytest-ism. Stdlib unittest's
# `-k` takes one fnmatch pattern per flag and ORs repeats together -- it does not parse "or"
# as an expression, so that exact string matches nothing and silently runs zero tests. Use:
#   python -m unittest discover -s scripts/adapterprobe/tests -v -k Verdict -k RowTable
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from capabilities import ROWS, verdict


class VerdictTests(unittest.TestCase):
    def test_present_and_working_is_ok(self):
        self.assertEqual(verdict(declared=True, observed=True), "ok")

    def test_present_but_not_working_is_broken(self):
        self.assertEqual(verdict(declared=True, observed=False), "broken")

    def test_absent_with_the_reason_still_holding_is_by_design(self):
        self.assertEqual(
            verdict(declared=False, observed=False, absent_reason_holds=True), "by-design")

    def test_absent_but_the_reason_no_longer_holds_is_rotted(self):
        self.assertEqual(
            verdict(declared=False, observed=True, absent_reason_holds=False), "rotted")

    def test_an_unprobed_absence_is_not_silently_blessed(self):
        # No reason was checked, so "by-design" would be a claim the probe did not earn.
        self.assertEqual(verdict(declared=False, observed=False), "error")

    def test_needs_auth_survives_derivation(self):
        self.assertEqual(verdict(declared=True, observed="needs-auth"), "needs-auth")


class FactKindVerdictTests(unittest.TestCase):
    """`kind="fact"` is for a symmetric boolean claim (declared False is just the other
    value, not a refusal that needs a reason) -- distinct from `kind="capability"`
    (default), where a declared absence is only trustworthy once its reason is probed."""

    def test_fact_true_matching_observed_true_is_ok(self):
        self.assertEqual(verdict(declared=True, observed=True, kind="fact"), "ok")

    def test_fact_true_but_observed_false_is_broken(self):
        self.assertEqual(verdict(declared=True, observed=False, kind="fact"), "broken")

    def test_fact_false_matching_observed_false_is_ok(self):
        self.assertEqual(verdict(declared=False, observed=False, kind="fact"), "ok")

    def test_fact_false_but_observed_true_is_broken(self):
        self.assertEqual(verdict(declared=False, observed=True, kind="fact"), "broken")

    def test_fact_kind_does_not_bypass_needs_auth(self):
        self.assertEqual(verdict(declared=True, observed="needs-auth", kind="fact"),
                          "needs-auth")

    def test_fact_kind_does_not_bypass_error(self):
        self.assertEqual(verdict(declared=True, observed=None, kind="fact"), "error")

    def test_capability_kind_absent_with_no_reason_probed_is_still_error(self):
        # Regression guard: adding `kind="fact"` must not loosen the default
        # `kind="capability"` path -- an unprobed absence still can't be blessed.
        self.assertEqual(
            verdict(declared=False, observed=False, kind="capability"), "error")


class RowTableTests(unittest.TestCase):
    def test_every_row_key_is_unique(self):
        keys = [r.key for r in ROWS]
        self.assertEqual(len(keys), len(set(keys)))

    def test_the_two_reported_symptoms_have_rows(self):
        keys = {r.key for r in ROWS}
        self.assertIn("resumeCommand", keys)
        self.assertIn("rename", keys)

    def test_every_row_names_a_tier_and_at_least_one_agent(self):
        for r in ROWS:
            self.assertIn(r.tier, ("cheap", "full"), r.key)
            self.assertTrue(r.agents, r.key)

    def test_exactly_the_four_symmetric_facts_are_kind_fact(self):
        # `homeMarkerFile` joined this set once its row stopped asserting a checkable
        # capability (see `_home_marker_file`'s docstring): declared/observed are the same
        # declared string, so "checked" here means the symmetric match itself, same as the
        # three original fact rows.
        fact_keys = {r.key for r in ROWS if r.kind == "fact"}
        self.assertEqual(
            fact_keys,
            {"negotiatesIdentity", "needsRuntimeStart", "hasStatusRegistry", "homeMarkerFile"})

    def test_open_prompt_reader_stays_a_capability(self):
        row = next(r for r in ROWS if r.key == "openPromptReader")
        self.assertEqual(row.kind, "capability")


if __name__ == "__main__":
    unittest.main()
