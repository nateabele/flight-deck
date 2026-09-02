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
            # `prepare` canonicalizes on lowercase (see its comment in probe.swift) so that
            # every consumer of a probe id can compare it verbatim against the agents' own
            # command text, which is always lowercase. Assert both halves of that contract:
            # the id `prepare` handed back is already lowercase, and it appears verbatim —
            # no case-folding needed by the caller — in what `resume-command` prints.
            self.assertEqual(p["conversationID"], p["conversationID"].lower())
            _, r = run(["resume-command", "claude", "--id", p["conversationID"],
                        "--cwd", sb.root], sb.env("claude"))
            self.assertIn(p["conversationID"], r["text"])

    def test_rename_claude_refuses_without_crashing_the_harness(self):
        # `ClaudeAdapter.rename` is a deliberate `assertionFailure` trap in production — see
        # its own doc comment — because claude renames dispatch inline through
        # `SessionStore`, never through the adapter. The probe must not reach it: a bare
        # SIGTRAP is indistinguishable from a real crash, and a `rename` capability row
        # needs to tell "this agent doesn't rename through the adapter" apart from "the
        # harness died". Exit 1 with parseable JSON is what makes that distinction possible.
        with AgentSandbox() as sb:
            rc, r = run(["rename", "claude", "--id", "31938ae3-29f8-47b5-97c2-6d51a4032873",
                         "--to", "whatever"], sb.env("claude"))
            self.assertEqual(rc, 1)
            self.assertIn("SessionStore", r["error"])


if __name__ == "__main__":
    unittest.main()
