import os, sys, tempfile, unittest
from unittest import mock
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from sandbox import AgentSandbox, UnsafeHome, guard_home

HOME = os.path.expanduser("~")


class GuardTests(unittest.TestCase):
    def test_refuses_home_itself(self):
        with self.assertRaises(UnsafeHome):
            guard_home(HOME)

    def test_refuses_the_real_agent_homes(self):
        for p in (os.path.join(HOME, ".claude"), os.path.join(HOME, ".codex")):
            with self.assertRaises(UnsafeHome):
                guard_home(p)

    def test_refuses_anything_nested_under_home(self):
        with self.assertRaises(UnsafeHome):
            guard_home(os.path.join(HOME, "some", "deep", "path"))

    def test_refuses_a_symlink_that_points_into_home(self):
        with tempfile.TemporaryDirectory() as d:
            link = os.path.join(d, "innocent")
            os.symlink(os.path.join(HOME, ".codex"), link)
            with self.assertRaises(UnsafeHome):
                guard_home(link)

    def test_allows_a_temp_directory(self):
        with tempfile.TemporaryDirectory() as d:
            guard_home(d)  # must not raise

    def test_expands_tilde_before_resolving(self):
        # os.path.realpath alone does NOT expand `~` — only os.path.expanduser does. This does
        # not depend on cwd: expanduser resolves `~` from $HOME, not from the working directory.
        for p in ("~/.claude", "~/.codex"):
            with self.assertRaises(UnsafeHome):
                guard_home(p)


class SandboxTests(unittest.TestCase):
    def test_creates_both_homes_and_removes_the_tree(self):
        with AgentSandbox() as sb:
            root = sb.root
            self.assertTrue(os.path.isdir(sb.claude_home))
            self.assertTrue(os.path.isdir(sb.codex_home))
            # The property the sandbox exists to guarantee: nothing under the real home.
            self.assertFalse(
                os.path.realpath(root).startswith(os.path.realpath(HOME) + os.sep))
        self.assertFalse(os.path.exists(root))

    def test_env_names_the_sandbox_home_for_each_agent(self):
        with AgentSandbox() as sb:
            self.assertEqual(sb.env("claude")["CLAUDE_CONFIG_DIR"], sb.claude_home)
            self.assertEqual(sb.env("codex")["CODEX_HOME"], sb.codex_home)
            self.assertNotIn("CODEX_HOME", sb.env("claude"))

    def test_keep_retains_the_tree(self):
        sb = AgentSandbox(keep=True)
        with sb:
            root = sb.root
        self.assertTrue(os.path.exists(root))
        import shutil; shutil.rmtree(root)

    def test_a_failed_construction_never_leaves_a_partial_tree_behind(self):
        sb = AgentSandbox()
        with mock.patch.object(
            AgentSandbox, "_copy_credentials", side_effect=RuntimeError("boom")
        ):
            with self.assertRaises(RuntimeError):
                sb.__enter__()
        # Cleanup on a failed construction is unconditional — even with keep=True (not the case
        # here, but the property __enter__ must hold regardless).
        self.assertFalse(os.path.exists(sb.root))


if __name__ == "__main__":
    unittest.main()
