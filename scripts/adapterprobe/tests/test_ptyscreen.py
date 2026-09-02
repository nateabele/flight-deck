import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from ptyscreen import PtyScreen


class PtyScreenTests(unittest.TestCase):
    def test_renders_command_output_onto_the_screen(self):
        with PtyScreen(["/bin/sh", "-c", "echo HELLO-FROM-PTY"], cwd="/tmp", env={}) as p:
            self.assertTrue(p.wait(["HELLO-FROM-PTY"], 10))
            self.assertIn("HELLO-FROM-PTY", p.display())

    def test_send_reaches_the_child(self):
        with PtyScreen(["/bin/sh", "-c", "read x; echo GOT-$x"], cwd="/tmp", env={}) as p:
            p.pump(0.5)
            p.send(b"PING\r")
            self.assertTrue(p.wait(["GOT-PING"], 10))

    def test_wait_returns_false_when_the_marker_never_appears(self):
        with PtyScreen(["/bin/sh", "-c", "echo other"], cwd="/tmp", env={}) as p:
            self.assertFalse(p.wait(["NEVER-APPEARS"], 2))

    def test_env_is_passed_to_the_child(self):
        with PtyScreen(["/bin/sh", "-c", "echo V=$PROBE_VAR"], cwd="/tmp",
                       env={"PROBE_VAR": "sentinel"}) as p:
            self.assertTrue(p.wait(["V=sentinel"], 10))


if __name__ == "__main__":
    unittest.main()
