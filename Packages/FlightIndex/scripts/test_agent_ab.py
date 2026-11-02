"""Tests for the pure parts of agent_ab.py: answer parsing, scoring, usage, statistics.

    python3 -m unittest discover -s Packages/FlightIndex/scripts -p 'test_*.py'
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agent_ab as ab  # noqa: E402


class ParseAnswer(unittest.TestCase):
    def test_last_fenced_json_block_wins(self):
        text = 'thinking\n```json\n{"files": ["a.rs"], "functions": []}\n```\nfinal:\n```json\n{"files": ["b.rs", "c.rs"], "functions": ["go"]}\n```\n'
        self.assertEqual(ab.parse_answer(text), {"files": ["b.rs", "c.rs"], "functions": ["go"]})

    def test_bare_object_without_fence(self):
        self.assertEqual(ab.parse_answer('Answer: {"files": ["x.ex"], "functions": ["run/2"]}'), {"files": ["x.ex"], "functions": ["run/2"]})

    def test_no_answer_is_none(self):
        self.assertIsNone(ab.parse_answer("I could not find it."))

    def test_missing_functions_key_defaults_to_empty(self):
        self.assertEqual(ab.parse_answer('```json\n{"files": ["x.ex"]}\n```'), {"files": ["x.ex"], "functions": []})


class NormPath(unittest.TestCase):
    def test_strips_root_dot_slash_and_line_suffix(self):
        self.assertEqual(ab.norm_path("/w/t1/src/a.rs:42", "/w/t1"), "src/a.rs")
        self.assertEqual(ab.norm_path("./src/a.rs", "/w/t1"), "src/a.rs")
        self.assertEqual(ab.norm_path("src/a.rs#L10-20", "/w/t1"), "src/a.rs")
        self.assertEqual(ab.norm_path("src/a.rs:10-20", "/w/t1"), "src/a.rs")

    def test_private_tmp_alias_of_root(self):
        # macOS reports /tmp paths as /private/tmp; the agent may print either.
        self.assertEqual(ab.norm_path("/private/tmp/w/src/a.rs", "/tmp/w"), "src/a.rs")
        self.assertEqual(ab.norm_path("/tmp/w/src/a.rs", "/private/tmp/w"), "src/a.rs")


class BareName(unittest.TestCase):
    def test_qualifiers_arity_and_parens_fall_away(self):
        self.assertEqual(ab.bare_name("Foo.Bar.run/2"), "run")
        self.assertEqual(ab.bare_name("graph::ppr::rank()"), "rank")
        self.assertEqual(ab.bare_name("Session#close"), "close")
        self.assertEqual(ab.bare_name("src/a.rs:handle_call"), "handle_call")
        self.assertEqual(ab.bare_name("func viewDidLoad()"), "viewDidLoad")


class Score(unittest.TestCase):
    def test_file_top1_recall5_and_function_recall(self):
        s = ab.score(["src/a.rs", "src/b.rs"], [["src/a.rs", 3, "go"], ["src/b.rs", 9, "stop"], ["src/b.rs", 20, "stop"]],
                     ["src/c.rs", "src/b.rs", "src/a.rs"], ["Thing::go", "other"])
        self.assertEqual(s["file1"], 0.0)
        self.assertEqual(s["file5"], 1.0)
        self.assertEqual(s["func"], 0.5)  # gold names {go, stop}; only go named

    def test_recall5_divides_by_min_k_gold(self):
        gold = [f"f{i}.rs" for i in range(8)]
        s = ab.score(gold, [], ["f0.rs", "f1.rs", "x.rs", "f2.rs", "f3.rs", "f4.rs"], [])
        self.assertEqual(s["file5"], 4 / 5)  # f0..f3 in the top 5, out of min(5, 8)
        self.assertIsNone(s["func"])  # no gold symbols: not scored

    def test_duplicate_answers_do_not_double_count(self):
        s = ab.score(["a.rs"], [], ["a.rs", "a.rs"], [])
        self.assertEqual(s["file5"], 1.0)
        self.assertEqual(s["file1"], 1.0)

    def test_no_answer_scores_zero(self):
        s = ab.score(["a.rs"], [["a.rs", 1, "go"]], [], [])
        self.assertEqual((s["file1"], s["file5"], s["func"]), (0.0, 0.0, 0.0))


class Usage(unittest.TestCase):
    def test_counts_tool_uses_and_reads_result(self):
        events = [
            {"type": "system", "subtype": "init"},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "x"}, {"type": "tool_use", "name": "mcp__idx__qartez_find"}]}},
            {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Read"}, {"type": "tool_use", "name": "mcp__idx__qartez_find"}]}},
            {"type": "result", "total_cost_usd": 0.12, "duration_ms": 4000, "num_turns": 3, "result": "done",
             "usage": {"input_tokens": 10, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 1000, "output_tokens": 50}},
        ]
        u = ab.usage(events)
        self.assertEqual(u["tool_calls"], 3)
        self.assertEqual(u["tools"], {"qartez_find": 2, "Read": 1})
        self.assertEqual(u["input_tokens"], 1110)
        self.assertEqual(u["output_tokens"], 50)
        self.assertEqual(u["cost"], 0.12)
        self.assertEqual(u["wall_s"], 4.0)
        self.assertEqual(u["result"], "done")
        # Cache reads cost a tenth of a write: the split explains cost that token totals do not.
        self.assertEqual((u["uncached_tokens"], u["cache_write_tokens"], u["cache_read_tokens"]), (10, 100, 1000))


class Stats(unittest.TestCase):
    def test_mean_ci_brackets_mean_and_is_deterministic(self):
        xs = [0, 1, 1, 0, 1, 1, 1, 0, 1, 1]
        m, lo, hi = ab.mean_ci(xs)
        self.assertAlmostEqual(m, 0.7)
        self.assertLess(lo, m)
        self.assertGreater(hi, m)
        self.assertEqual((m, lo, hi), ab.mean_ci(xs))

    def test_constant_sample_has_zero_width(self):
        self.assertEqual(ab.mean_ci([2.0, 2.0, 2.0]), (2.0, 2.0, 2.0))

    def test_empty_is_none(self):
        self.assertIsNone(ab.mean_ci([]))


class Category(unittest.TestCase):
    def test_language_size_and_kind(self):
        t = {"repo": "fd", "subject": "fix: guard the socket", "gold_files": ["a.rs", "b.rs", "c.swift"]}
        self.assertEqual(ab.categories(t), {"repo": "fd", "lang": "rust", "size": "2-3 files", "kind": "fix"})

    def test_unprefixed_subject_is_other(self):
        t = {"repo": "tessera", "subject": "process gaps: wording", "gold_files": ["x.elm"]}
        self.assertEqual(ab.categories(t)["kind"], "other")
        self.assertEqual(ab.categories(t)["size"], "1 file")
        self.assertEqual(ab.categories(t)["lang"], "elm")


if __name__ == "__main__":
    unittest.main()
