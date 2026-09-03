import json, os, subprocess, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
BUILD = os.path.join(REPO, "scripts", "adapterprobe", "build-probe.sh")
PROBE = os.path.join(REPO, "DerivedData", "adapterprobe", "probe")


def declare(agent):
    out = subprocess.run([PROBE, "declare", agent], capture_output=True, text=True)
    assert out.returncode == 0, out.stderr
    return json.loads(out.stdout)


class DeclareTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run([BUILD], check=True, cwd=REPO)

    def test_claude_declares_what_ClaudeAdapter_declares(self):
        d = declare("claude")
        self.assertTrue(d["textChannel"])
        self.assertTrue(d["dialogDriver"])
        self.assertTrue(d["openPromptReader"])
        self.assertFalse(d["negotiatesIdentity"])
        self.assertFalse(d["needsRuntimeStart"])
        self.assertTrue(d["hasStatusRegistry"])
        self.assertEqual(d["homeMarkerFile"], ".claude.json")

    def test_codex_declares_what_CodexAdapter_declares(self):
        d = declare("codex")
        self.assertTrue(d["textChannel"])
        self.assertTrue(d["dialogDriver"])
        self.assertFalse(d["openPromptReader"])   # the nil this suite exists to re-check
        self.assertTrue(d["negotiatesIdentity"])
        self.assertTrue(d["needsRuntimeStart"])
        self.assertFalse(d["hasStatusRegistry"])
        self.assertEqual(d["homeMarkerFile"], "auth.json")

    def test_unknown_agent_is_a_usage_error(self):
        out = subprocess.run([PROBE, "declare", "gemini"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 2)


if __name__ == "__main__":
    unittest.main()
