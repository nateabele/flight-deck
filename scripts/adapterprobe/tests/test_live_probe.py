import json, os, subprocess, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sandbox import AgentSandbox

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
PROBE = os.path.join(REPO, "DerivedData", "adapterprobe", "probe")


def run(args, env):
    e = dict(os.environ); e.update(env)
    out = subprocess.run([PROBE] + args, capture_output=True, text=True, env=e, timeout=120)
    return out.returncode, json.loads(out.stdout) if out.stdout.strip() else {}


class LiveProbeTests(unittest.TestCase):
    def test_claude_prepare_mints_an_id_with_no_runtime(self):
        with AgentSandbox() as sb:
            rc, r = run(["prepare", "claude", "--cwd", sb.root], sb.env("claude"))
            self.assertEqual(rc, 0)
            self.assertRegex(r["conversationID"], r"^[0-9A-Fa-f-]{36}$")

    def test_codex_prepare_negotiates_a_thread_inside_the_sandbox(self):
        with AgentSandbox() as sb:
            rc, r = run(["prepare", "codex", "--cwd", sb.root], sb.env("codex"))
            self.assertEqual(rc, 0, r.get("error"))
            self.assertRegex(r["conversationID"], r"^[0-9A-Fa-f-]{36}$")
            # The sandbox is the only place anything was written.
            self.assertTrue(any(f for f in os.listdir(sb.codex_home)))

    def test_resume_command_text_names_the_conversation(self):
        with AgentSandbox() as sb:
            _, p = run(["prepare", "claude", "--cwd", sb.root], sb.env("claude"))
            _, r = run(["resume-command", "claude", "--id", p["conversationID"],
                        "--cwd", sb.root], sb.env("claude"))
            # Case-insensitive: `prepare` emits Swift's `UUID.uuidString` (uppercase), while
            # `ClaudeSession.resumeCommand` deliberately lowercases the id for the command
            # line it hands to a real shell. Same conversation, different hex case.
            self.assertIn(p["conversationID"].lower(), r["text"].lower())


if __name__ == "__main__":
    unittest.main()
