# scripts/adapterprobe/tests/test_verdicts.py
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


if __name__ == "__main__":
    unittest.main()
