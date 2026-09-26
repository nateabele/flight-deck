import json, os, subprocess, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PROBE = os.path.join(REPO, "DerivedData", "adapterprobe", "probe")
FIX = os.path.join(REPO, "Tests", "FlightDeckTests", "Fixtures")
ROLLOUT_FIXTURE = os.path.join(FIX, "Codex", "rollout.captured.jsonl")


def run(args, stdin=""):
    out = subprocess.run([PROBE] + args, input=stdin, capture_output=True, text=True)
    return out.returncode, json.loads(out.stdout) if out.stdout.strip() else {}


class GrammarTests(unittest.TestCase):
    def test_neither_agent_strips_shell_metacharacters_but_both_strip_control_characters(self):
        # Production dropped claude's shell-metacharacter strip once `SessionStore.inject`
        # started gating on a live composer box (see `AgentAdapter.sanitizedTitle`'s own
        # comment) -- this test used to assert the removed behaviour and had been failing
        # since. Both agents now go through the same `AgentTitle.sanitized` with an empty
        # forbidden set: metacharacters survive for both, a newline survives for neither.
        _, c = run(["sanitize", "claude", "a; rm -rf /"])
        _, x = run(["sanitize", "codex", "a; rm -rf /"])
        self.assertIn(";", c["sanitized"] or "")
        self.assertIn(";", x["sanitized"] or "")
        _, c_nl = run(["sanitize", "claude", "line1\nline2"])
        _, x_nl = run(["sanitize", "codex", "line1\nline2"])
        self.assertNotIn("\n", c_nl["sanitized"] or "")
        self.assertNotIn("\n", x_nl["sanitized"] or "")

    def test_codex_refuses_to_read_a_title_from_a_transcript(self):
        _, x = run(["title-from-transcript", "codex", ROLLOUT_FIXTURE])
        self.assertIsNone(x["title"])

    def test_the_captured_codex_rollout_still_yields_timeline_items(self):
        with open(ROLLOUT_FIXTURE) as f:
            rc, r = run(["timeline", "codex"], stdin=f.read())
        self.assertEqual(rc, 0)
        self.assertGreater(r["items"], 0)

    def test_codex_has_no_open_prompt_reader_and_says_so(self):
        _, r = run(["open-prompt", "codex"], stdin="{}\n")
        self.assertTrue(r["unsupported"])

    def test_the_captured_claude_transcript_still_yields_a_title(self):
        path = os.path.join(FIX, "Claude", "transcript.captured.jsonl")
        _, c = run(["title-from-transcript", "claude", path])
        self.assertIsNotNone(c["title"])

    def test_claude_reads_its_own_idle_screen_as_an_empty_composer(self):
        with open(os.path.join(FIX, "Claude", "idle-empty-box.captured.txt")) as f:
            _, r = run(["composer-empty", "claude"], stdin=f.read())
        self.assertTrue(r["empty"])

    def test_claude_derives_an_open_prompt_once_activity_is_threaded_through(self):
        path = os.path.join(FIX, "Claude", "question-single.captured.jsonl")
        with open(path) as f:
            rc, r = run(["open-prompt", "claude", "--activity", "waiting"], stdin=f.read())
        self.assertEqual(rc, 0)
        self.assertIsNotNone(r["kind"])

    def test_an_unrecognized_activity_value_is_a_usage_error(self):
        rc, _ = run(["open-prompt", "claude", "--activity", "bogus"], stdin="{}\n")
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()
