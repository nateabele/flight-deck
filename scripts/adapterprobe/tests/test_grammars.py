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
    def test_claude_strips_shell_metacharacters_codex_does_not(self):
        _, c = run(["sanitize", "claude", "a; rm -rf /"])
        _, x = run(["sanitize", "codex", "a; rm -rf /"])
        self.assertNotIn(";", c["sanitized"] or "")
        self.assertIn(";", x["sanitized"] or "")

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


if __name__ == "__main__":
    unittest.main()
