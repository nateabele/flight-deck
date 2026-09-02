# Adapter Capability Suite Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A capability matrix over both `AgentAdapter` conformers, probed against a real `claude` and a real `codex` through the built FlightDeck module plus a live pty, diffed against a pinned baseline.

**Architecture:** Python drives, Swift answers. `probe.swift` is a CLI that `@testable import`s the built `FlightDeck` module and links `Flight Deck.debug.dylib`, so every answer comes from the production adapter rather than a reimplementation. Python owns the pty (`pty.fork` + `pyte`), the throwaway agent homes, the row definitions, verdict derivation, and the baseline diff.

**Tech Stack:** Swift 6 / `swiftc` against `DerivedData/Build/Products/Debug`; Python 3 stdlib + `pyte`; `unittest` for the hermetic tests.

**Spec:** `docs/superpowers/specs/2026-09-02-adapter-capability-suite-design.md` (committed `1a1c0e5`)

## Global Constraints

- **The venv lives OUTSIDE the repo.** `/tmp/adapterprobe-venv`, matching `scripts/livefuzz/README.md`'s rule ("do not put it under `scripts/livefuzz/`"). Never commit it, never create it inside the working tree.
- **Hermetic tests use `unittest` from the stdlib.** `pytest` is not installed and must not become a dependency. Only the pty rows need `pyte`.
- **The sandbox guard is not optional.** No code path may run an agent with `CLAUDE_CONFIG_DIR` or `CODEX_HOME` resolving under `$HOME`, or equal to `~/.claude` / `~/.codex`. Resolve symlinks before checking.
- **`error` is never a capability verdict.** A probe that could not run is recorded as harness failure and must not satisfy a baseline expectation of `ok`.
- **Agent versions as of this plan:** `codex-cli 0.152.1`, `claude 2.1.258`. The adapter's own comments pin behaviour claims to 0.148.0 and 0.151.0, so the installed codex is already ahead of every claim in the source.
- **Never run `scripts/smoke.sh` or any GUI test from this work.** This suite is pty-only and steals no focus; keep it that way.
- **Do not fix anything the matrix finds.** Recording a `broken` cell in the baseline is the deliverable.

---

### Task 1: `ptyscreen.py` — extract the pty driver

**Files:**
- Create: `scripts/adapterprobe/ptyscreen.py`
- Create: `scripts/adapterprobe/tests/test_ptyscreen.py`
- Modify: `scripts/livefuzz/fuzz.py:189-232` (delete the inline pty/pyte code, import instead)

**Interfaces:**
- Consumes: nothing.
- Produces: `PtyScreen(cmd: list[str], cwd: str, env: dict[str,str], cols=136, rows=34)` with methods `pump(sec: float) -> None`, `display() -> str`, `send(data: bytes) -> None`, `wait(markers: list[str], limit: float) -> bool`, `close() -> None`; usable as a context manager. Module constant `NEG` (the mouse-negotiation filter regex).

- [ ] **Step 1: Write the failing test**

```python
# scripts/adapterprobe/tests/test_ptyscreen.py
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'ptyscreen'`

(If the venv does not exist yet: `python3 -m venv /tmp/adapterprobe-venv && /tmp/adapterprobe-venv/bin/pip install pyte`)

- [ ] **Step 3: Write `ptyscreen.py`**

Lift the working mechanics from `scripts/livefuzz/fuzz.py:189-232` verbatim — the `pty.fork`, the `TIOCSWINSZ` ioctl, the `select`-based `pump`, `"\n".join(screen.display)`, and the `NEG` regex from `fuzz.py:17`. Behaviour must not change; this is an extraction.

```python
# scripts/adapterprobe/ptyscreen.py
"""A live terminal, rendered.

Extracted verbatim from `scripts/livefuzz/fuzz.py`, which has driven a real `claude` TUI this
way since 2026-08. Two consumers now share one driver rather than keeping two copies that
drift: `fuzz.py` fuzzes one capability deeply, this suite checks many once each.
"""
import fcntl, os, pty, re, select, signal, struct, termios, time
import pyte

# Mouse-negotiation sequences pyte does not model; unfiltered they corrupt the screen.
NEG = re.compile(rb"\x1b\[[<>?][0-9;]*[usmhl]")

COLS, ROWS = 136, 34


class PtyScreen:
    def __init__(self, cmd, cwd, env, cols=COLS, rows=ROWS):
        self.screen = pyte.Screen(cols, rows)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:                      # child
            os.chdir(cwd)
            os.environ["TERM"] = "xterm-256color"
            os.environ.update(env)
            os.execvp(cmd[0], cmd)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ,
                    struct.pack("HHHH", rows, cols, 0, 0))

    def pump(self, sec):
        end = time.time() + sec
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.2)
            if self.fd in r:
                try:
                    d = os.read(self.fd, 65536)
                except OSError:
                    return
                if not d:
                    return
                self.stream.feed(NEG.sub(b"", d))

    def display(self):
        return "\n".join(self.screen.display)

    def send(self, data):
        os.write(self.fd, data)

    def wait(self, markers, limit):
        end = time.time() + limit
        while time.time() < end:
            self.pump(0.4)
            if any(m in self.display() for m in markers):
                return True
        return False

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except (ProcessLookupError, ChildProcessError):
            pass
        try:
            os.close(self.fd)
        except OSError:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v`
Expected: 4 tests, PASS

- [ ] **Step 5: Point `fuzz.py` at the shared driver**

In `scripts/livefuzz/fuzz.py`, delete the inline `pyte.Screen`/`pty.fork`/`ioctl`/`pump`/`disp`/`wait` block inside `drive()` (currently `fuzz.py:206-228`) and the `NEG` constant at `fuzz.py:17`, and build a `PtyScreen` instead. The child-side env `fuzz.py` sets (`CLAUDE_CODE_CHILD_SESSION` popped, `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`) moves into the `env` argument:

```python
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "adapterprobe"))
from ptyscreen import PtyScreen

# ... inside drive(), replacing the inline pty block:
os.environ.pop("CLAUDE_CODE_CHILD_SESSION", None)
term = PtyScreen(["claude"], cwd=WD, env={"CLAUDE_CODE_FORCE_SESSION_PERSISTENCE": "1"})
pump, disp, wait = term.pump, term.display, term.wait
def write(b): term.send(b)
```

Replace the remaining `os.write(fd, ...)` calls in `drive()` with `write(...)`, and `return` paths with a `try/finally: term.close()`.

- [ ] **Step 6: Verify the extraction did not change `fuzz.py`'s behaviour**

Run: `cd scripts/livefuzz && /tmp/adapterprobe-venv/bin/python runfuzz.py single-set 1`
Expected: the run completes and reports its usual PASS/FAIL line — not an import error, not "no boot". This burns real claude quota; run it **once**.

- [ ] **Step 7: Commit**

```bash
git add scripts/adapterprobe/ptyscreen.py scripts/adapterprobe/tests/test_ptyscreen.py scripts/livefuzz/fuzz.py
git commit -m "refactor: extract livefuzz's pty driver into ptyscreen.py"
```

---

### Task 2: `sandbox.py` — throwaway agent homes

**Files:**
- Create: `scripts/adapterprobe/sandbox.py`
- Create: `scripts/adapterprobe/tests/test_sandbox.py`

**Interfaces:**
- Consumes: nothing.
- Produces: `guard_home(path: str) -> None` (raises `UnsafeHome`); `class UnsafeHome(Exception)`; `AgentSandbox(keep: bool = False)` context manager exposing `.root: str`, `.claude_home: str`, `.codex_home: str`, `.env(agent: str) -> dict[str,str]`, and `.copied: list[str]` naming which credential files were found and copied.

- [ ] **Step 1: Write the failing test**

```python
# scripts/adapterprobe/tests/test_sandbox.py
import os, sys, tempfile, unittest
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


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'sandbox'`

- [ ] **Step 3: Write `sandbox.py`**

```python
# scripts/adapterprobe/sandbox.py
"""Throwaway agent homes.

Real history is untouchable by construction rather than by careful cleanup. `scripts/smoke.sh`
carries a comment recording that it once `defaults delete`d the whole preference domain and
destroyed every real session on every run; cleanup-by-id is correct but relies on the cleanup
path executing. A sandbox does not.
"""
import os, shutil, tempfile

HOME = os.path.realpath(os.path.expanduser("~"))

# Copied IN, never out. The sandbox tree is deleted wholesale.
CREDENTIALS = {
    "claude": [(os.path.expanduser("~/.claude.json"), ".claude.json")],
    "codex":  [(os.path.expanduser("~/.codex/auth.json"), "auth.json")],
}


class UnsafeHome(Exception):
    pass


def guard_home(path):
    """Refuse any agent home that is, or is inside, the user's real home.

    Resolved before comparison so a symlink cannot smuggle a real home through.
    """
    real = os.path.realpath(path)
    if real == HOME or real.startswith(HOME + os.sep):
        raise UnsafeHome(
            f"refusing to run an agent with its home at {path!r} (resolves to {real!r}, "
            f"inside {HOME!r}) — probes must never touch real history"
        )


class AgentSandbox:
    def __init__(self, keep=False):
        self.keep = keep
        self.root = None
        self.copied = []

    def __enter__(self):
        self.root = tempfile.mkdtemp(prefix="adapterprobe-")
        self.claude_home = os.path.join(self.root, "claude-home")
        self.codex_home = os.path.join(self.root, "codex-home")
        for h in (self.claude_home, self.codex_home):
            guard_home(self.root)
            os.makedirs(h, exist_ok=True)
            guard_home(h)
        self._copy_credentials()
        return self

    def _copy_credentials(self):
        for agent, entries in CREDENTIALS.items():
            dest_home = self.claude_home if agent == "claude" else self.codex_home
            for src, name in entries:
                if os.path.exists(src):
                    shutil.copy2(src, os.path.join(dest_home, name))
                    self.copied.append(f"{agent}:{name}")

    def env(self, agent):
        if agent == "claude":
            return {"CLAUDE_CONFIG_DIR": self.claude_home}
        if agent == "codex":
            return {"CODEX_HOME": self.codex_home}
        raise ValueError(f"unknown agent {agent!r}")

    def __exit__(self, *exc):
        if self.root and not self.keep:
            shutil.rmtree(self.root, ignore_errors=True)
        return False
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v`
Expected: 12 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/adapterprobe/sandbox.py scripts/adapterprobe/tests/test_sandbox.py
git commit -m "feat: throwaway agent homes with a real-home guard"
```

---

### Task 3: `probe.swift` skeleton + `declare` — prove the link works

This is the riskiest task in the plan and is deliberately first among the Swift work: if `@testable import FlightDeck` against the built dylib does not link, the whole architecture is wrong and it must be found now.

**Files:**
- Create: `scripts/adapterprobe/probe.swift`
- Create: `scripts/adapterprobe/build-probe.sh`
- Create: `scripts/adapterprobe/tests/test_declare.py`

**Interfaces:**
- Consumes: nothing.
- Produces: an executable at `DerivedData/adapterprobe/probe`. Subcommand `probe declare <claude|codex>` prints a JSON object on stdout with keys `textChannel`, `dialogDriver`, `openPromptReader` (each `true`/`false` for non-nil), `negotiatesIdentity`, `needsRuntimeStart`, `hasStatusRegistry` (bools), `homeMarkerFile` (string). Exit 0 on success, 2 on usage error, 1 on failure with a JSON `{"error": "..."}` on stdout.

- [ ] **Step 1: Write the failing test**

```python
# scripts/adapterprobe/tests/test_declare.py
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k Declare`
Expected: FAIL — `build-probe.sh` does not exist.

- [ ] **Step 3: Write `build-probe.sh`**

The dylib is passed to `swiftc` **as a positional input path**, not with `-l`: it is named `Flight Deck.debug.dylib`, which has no `lib` prefix for `-l` to find. Its install name is `@rpath`-relative, so an `-rpath` is required for the built probe to find it at run time — the same problem `test-unit.sh` solves with its `Contents/Frameworks` symlink.

```bash
#!/usr/bin/env bash
set -euo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/../.."

CONFIG=Debug
PRODUCTS="DerivedData/Build/Products/${CONFIG}"
APPMACOS="$PWD/${PRODUCTS}/Flight Deck.app/Contents/MacOS"
DYLIB="$APPMACOS/Flight Deck.debug.dylib"
OUT="DerivedData/adapterprobe"

# Build the app first, exactly as test-unit.sh does: the probe imports the app's own
# swiftmodule, so there is no separate build description to keep in step.
xcodegen generate >/dev/null
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -configuration "$CONFIG" -destination 'platform=macOS' \
  -derivedDataPath DerivedData build >/dev/null

[ -f "$DYLIB" ] || { echo "error: host dylib not found at $DYLIB" >&2; exit 1; }
mkdir -p "$OUT"

# -enable-testing on the app target is what makes `@testable import FlightDeck` legal here;
# Debug already sets it, which is how FlightDeckTests imports the same module.
#
# The four non-obvious flags below were each established by compiling a throwaway probe against
# this exact tree; without any one of them the build fails, so do not "simplify" them away:
#
#   -parse-as-library          A ONE-file swiftc invocation is script mode, and `@main` is
#                              illegal in a module with top-level code. (scripts/livefuzz's
#                              probe escapes this only by compiling two files.)
#   -Xcc -I<GhosttyEmbed>      `@testable import` pulls in the module's bridging header, which
#                              #imports ObjCExceptionCatcher.h / VibrantLayer.h.
#   -Xcc -I<boringssl include> FleetKit's BoringSSLShim module map needs openssl/curve25519.h.
#   -Xcc -I<products>/include  The GhosttyKit module map (umbrella header ghostty.h).
#
# The two -Xcc header paths are exactly FlightDeck's own HEADER_SEARCH_PATHS from
# project.yml:101; if that line ever changes, change these with it.
swiftc -O -parse-as-library \
  scripts/adapterprobe/probe.swift \
  -I "$PRODUCTS" \
  -F "$PRODUCTS" \
  -Xcc -I"$PWD/Sources/FlightDeck/GhosttyEmbed" \
  -Xcc -I"$PWD/vendor/boringssl-artifacts/include" \
  -Xcc -I"$PWD/$PRODUCTS/include" \
  -framework FleetKit \
  "$DYLIB" \
  -Xlinker -rpath -Xlinker "$APPMACOS" \
  -Xlinker -rpath -Xlinker "$PWD/$PRODUCTS" \
  -o "$OUT/probe"

echo "built $OUT/probe"
```

Then `chmod +x scripts/adapterprobe/build-probe.sh`.

- [ ] **Step 4: Write `probe.swift` with `declare` only**

```swift
// scripts/adapterprobe/probe.swift
//
// The real adapters, as a CLI.
//
// Linked against the built `FlightDeck` module rather than compiled from a hand-listed set of
// sources: `CodexAdapter` needs FleetKit, `CodexRPC`, `CodexProcessTransport`, `SessionStore`'s
// types and `@MainActor async` context, and a second source list would be a second build
// description that drifts. This one cannot drift, because it *is* the app's module.
//
// Every subcommand prints one JSON object on stdout. Exit 0 = the probe ran; 1 = it ran and
// the operation failed (the object carries "error"); 2 = usage. A non-zero exit is never by
// itself a statement about the adapter — the runner decides that.
import Foundation
@testable import FlightDeck

@main
struct Probe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let op = args.first else { usage() }
        switch op {
        case "declare":
            guard args.count == 2, let agent = agentID(args[1]) else { usage() }
            await emit(declare(agent))
        default:
            usage()
        }
    }

    @MainActor
    static func declare(_ agent: AgentID) -> [String: Any] {
        [
            "agent": agent.rawValue,
            "textChannel": agent.textChannel != nil,
            "dialogDriver": agent.dialogDriver != nil,
            "openPromptReader": agent.openPromptReader != nil,
            "negotiatesIdentity": agent.negotiatesIdentity,
            "needsRuntimeStart": agent.needsRuntimeStart,
            "hasStatusRegistry": agent.hasStatusRegistry,
            "homeMarkerFile": agent.homeMarkerFile,
            "allowRow": agent.dialogDriver?.allowRow as Any,
        ]
    }

    static func agentID(_ raw: String) -> AgentID? {
        switch raw {
        case "claude": .claude
        case "codex": .codex
        default: nil
        }
    }

    static func emit(_ object: [String: Any], exit code: Int32 = 0) -> Never {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"error":"unserializable"}"#.utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(code)
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data("usage: probe declare <claude|codex>\n".utf8))
        exit(2)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k Declare`
Expected: 3 tests, PASS. The build takes a few minutes on a cold DerivedData.

This linkage is already proven against this worktree: a throwaway probe with the exact flags above compiled, linked and ran, printing real values read out of the production adapter (`codex openPromptReader != nil: false`, `homeMarkerFile: auth.json`). If your build fails, the cause is almost certainly a dropped or reordered flag — compare against the list above before changing anything else.

Expect a harmless `umbrella header for module 'GhosttyKit' does not include header '/ghostty/vt.h'` warning. It is pre-existing and not yours to fix.

If `@testable import FlightDeck` fails with "module was not compiled for testing", confirm the Debug configuration sets `ENABLE_TESTABILITY=YES` in `project.yml` — `FlightDeckTests` already depends on it, so it should already be set; do not add a new build setting to work around a stale DerivedData, clean and rebuild instead.

- [ ] **Step 6: Commit**

```bash
git add scripts/adapterprobe/probe.swift scripts/adapterprobe/build-probe.sh scripts/adapterprobe/tests/test_declare.py
git commit -m "feat: probe CLI linking the built FlightDeck module, with declare"
```

---

### Task 4: probe subcommands for the pure and grammar members

**Files:**
- Modify: `scripts/adapterprobe/probe.swift`
- Create: `scripts/adapterprobe/tests/test_grammars.py`

**Interfaces:**
- Consumes: `Probe.agentID`, `Probe.emit`, `Probe.usage` from Task 3.
- Produces: subcommands `sanitize <agent> <raw>` → `{"sanitized": String?}`; `title-from-transcript <agent> <path>` → `{"title": String?}`; `timeline <agent>` (transcript on stdin) → `{"lines": Int, "items": Int, "barrenLines": [Int]}`; `identity <agent>` (marker JSON on stdin) → `{"identity": String?}`; `composer-empty <agent>` (screen on stdin) → `{"empty": Bool}` or `{"error":"no text channel"}`; `focused-row <agent>` (screen on stdin) → `{"row": Int?}`; `row-reads <agent> <n> <label>` (screen on stdin) → `{"reads": Bool}`; `open-prompt <agent>` (JSONL tail on stdin) → `{"kind": String?}` or `{"unsupported": true}`.

- [ ] **Step 1: Write the failing test**

Uses fixtures already committed in the repo. These paths are verified to exist — use them exactly, do not go looking for substitutes:

- `Tests/FlightDeckTests/Fixtures/Codex/rollout.captured.jsonl` — codex's rollout
- `Tests/FlightDeckTests/Fixtures/Claude/transcript.captured.jsonl` — claude's transcript
- `Tests/FlightDeckTests/Fixtures/Claude/question-single.captured.txt` — a claude dialog screen
- `Tests/FlightDeckTests/Fixtures/Claude/idle-empty-box.captured.txt` — a claude idle screen
- `Tests/FlightDeckTests/Fixtures/Codex/tui-idle.captured.txt` — a codex idle screen

```python
# scripts/adapterprobe/tests/test_grammars.py
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k Grammar`
Expected: FAIL — exit 2 (usage) from every unknown subcommand.

- [ ] **Step 3: Add the subcommands to `probe.swift`**

Extend the `switch op` in `main()`. `stdinText()` reads the whole of stdin.

```swift
    static func stdinText() -> String {
        String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // inside switch op:
    case "sanitize":
        guard args.count == 3, let agent = agentID(args[1]) else { usage() }
        await emit(["sanitized": agent.sanitizedTitle(args[2]) as Any])

    case "title-from-transcript":
        guard args.count == 3, let agent = agentID(args[1]) else { usage() }
        let url = URL(fileURLWithPath: args[2])
        await emit(["title": agent.title(fromTranscriptAt: url) as Any])

    case "timeline":
        guard args.count == 2, let agent = agentID(args[1]) else { usage() }
        let lines = stdinText().split(separator: "\n", omittingEmptySubsequences: true)
        var items = 0
        var barren: [Int] = []
        for (i, line) in lines.enumerated() {
            let produced = await MainActor.run { agent.timelineItems(inLine: String(line), at: i) }
            if produced.isEmpty { barren.append(i) } else { items += produced.count }
        }
        await emit(["lines": lines.count, "items": items, "barrenLines": barren])

    case "identity":
        guard args.count == 2, let agent = agentID(args[1]) else { usage() }
        let data = Data(stdinText().utf8)
        let id = await MainActor.run { agent.identity(fromHomeData: data) }
        await emit(["identity": id?.email as Any])

    case "composer-empty":
        guard args.count == 2, let agent = agentID(args[1]) else { usage() }
        let screen = stdinText()
        let answer: [String: Any] = await MainActor.run {
            guard let channel = agent.textChannel else { return ["error": "no text channel"] }
            return ["empty": channel.isComposerEmpty(ViewportInjector(screen))]
        }
        await emit(answer)

    case "focused-row":
        guard args.count == 2, let agent = agentID(args[1]) else { usage() }
        let screen = stdinText()
        let answer: [String: Any] = await MainActor.run {
            guard let driver = agent.dialogDriver else { return ["error": "no dialog driver"] }
            return ["row": driver.focusedRow(inViewport: screen) as Any]
        }
        await emit(answer)

    case "row-reads":
        guard args.count >= 4, let agent = agentID(args[1]), let n = Int(args[2]) else { usage() }
        let label = args[3...].joined(separator: " ")
        let screen = stdinText()
        let answer: [String: Any] = await MainActor.run {
            guard let driver = agent.dialogDriver else { return ["error": "no dialog driver"] }
            return ["reads": driver.row(n, reads: label, inViewport: screen)]
        }
        await emit(answer)

    case "open-prompt":
        guard args.count == 2, let agent = agentID(args[1]) else { usage() }
        let tail = stdinText()
        let answer: [String: Any] = await MainActor.run {
            guard let reader = agent.openPromptReader else { return ["unsupported": true] }
            let lines = tail.split(separator: "\n").enumerated().map {
                SourceLine(offset: $0.offset, text: String($0.element))
            }
            return ["kind": reader.openPrompt(inTranscriptTail: lines, activity: nil)
                        .map { String(describing: $0) } as Any]
        }
        await emit(answer)
```

`ViewportInjector` is a `TextInjecting` over a fixed screen. `TextInjecting` is `@MainActor` and `AnyObject`-constrained with exactly eight members (`Sources/FlightDeck/TextInjecting.swift`); the reading members answer from `viewport`, and the writing members record rather than no-op, so a later row can assert which keys a driver actually sent. Add it at file scope:

```swift
/// A `TextInjecting` over a captured screen. Reads answer `viewport`; writes are recorded so a
/// probe can report the keystrokes a driver produced without a real surface to send them at.
@MainActor
final class ViewportInjector: TextInjecting {
    let viewport: String
    private(set) var sent: [String] = []

    init(_ viewport: String) { self.viewport = viewport }

    func sendText(_ text: String) { sent.append("text:\(text)") }
    func sendReturn()             { sent.append("return") }
    func sendKillLine()           { sent.append("killline") }
    func sendYank()               { sent.append("yank") }
    func sendArrowDown()          { sent.append("down") }
    func sendArrowUp()            { sent.append("up") }
    func sendEscape()             { sent.append("escape") }
    func readViewport() -> String? { viewport }
}
```

`AccountIdentity` is declared at `Sources/FlightDeck/Agents/AgentAccount.swift:28` with `var email: String?`, so `id?.email` above is correct as written.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/adapterprobe/build-probe.sh && /tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k Grammar`
Expected: 6 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/adapterprobe/probe.swift scripts/adapterprobe/tests/test_grammars.py
git commit -m "feat: probe subcommands for the pure and grammar adapter members"
```

---

### Task 5: probe subcommands for the live members

**Files:**
- Modify: `scripts/adapterprobe/probe.swift`
- Create: `scripts/adapterprobe/tests/test_live_probe.py`

**Interfaces:**
- Consumes: everything from Tasks 3-4.
- Produces: subcommands `prepare <agent> --cwd <dir>` → `{"conversationID": String, "transcriptURL": String?}` or `{"error": String}`; `rebind <agent> --pin <uuid> --cwd <dir>` → same shape plus `{"repointed": Bool}`; `rename <agent> --id <uuid> --to <title>` → `{"renamed": true}` or `{"error": String}`; `read <agent> --id <uuid>` → `{"title": String?, "activity": String?}`; `launch-command <agent> --id <uuid> --cwd <dir>` and `resume-command <agent> --id <uuid> --cwd <dir>` → `{"text": String}`. Codex subcommands spawn a real `codex app-server` honouring `CODEX_HOME` from the environment and stop it via `defer` on every path.

- [ ] **Step 1: Write the failing test**

These spawn a real codex inside a sandbox. Keep them few and cheap — none requires a model turn.

```python
# scripts/adapterprobe/tests/test_live_probe.py
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
            self.assertIn(p["conversationID"], r["text"])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k LiveProbe`
Expected: FAIL — exit 2 (usage).

- [ ] **Step 3: Add the live subcommands to `probe.swift`**

A codex subcommand needs a transport, a handshake and an adapter. `CodexProcessTransport(executable:home:)` takes the home directly; pass the sandbox's `CODEX_HOME`. `Session(title:workingDirectory:)` is the construction the existing tests use (`CodexAdapterTests.swift:64`).

```swift
    /// A real codex stack for one probe invocation, torn down on every exit path.
    @MainActor
    static func withCodex<T>(_ body: (CodexAdapter) async throws -> T) async throws -> T {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        let transport = CodexProcessTransport(executable: "codex", home: home)
        try transport.start()
        defer { transport.stop() }
        let rpc = CodexRPC(transport: transport)
        try await CodexProcessTransport.verifyHandshake(rpc)
        var adapter = CodexAdapter(rpc: rpc)
        adapter.historyMode = "legacy"   // the commit rule; see CodexIntegrationTests
        return try await body(adapter)
    }

    static func flag(_ args: [String], _ name: String) -> String? {
        guard let i = args.firstIndex(of: name), args.index(after: i) < args.endIndex else { return nil }
        return args[args.index(after: i)]
    }

    // inside switch op:
    case "prepare":
        guard let agent = args.count > 1 ? agentID(args[1]) : nil,
              let cwd = flag(args, "--cwd") else { usage() }
        let session = await MainActor.run { Session(title: "adapterprobe", workingDirectory: cwd) }
        do {
            let binding: AgentBinding
            switch agent {
            case .claude:
                binding = try await MainActor.run { ClaudeAdapter() }
                    .prepare(for: session, options: .claude(FlagSet()))
            case .codex:
                binding = try await withCodex {
                    try await $0.prepare(for: session, options: .codex(CodexThreadOptions()))
                }
            }
            await emit([
                "conversationID": binding.conversationID.uuidString,
                "transcriptURL": binding.transcriptURL?.path as Any,
            ])
        } catch {
            await emit(["error": String(describing: error)], exit: 1)
        }
```

Add `rebind`, `rename`, `read`, `launch-command` and `resume-command` following the same shape: build the session, dispatch on `agent`, wrap codex in `withCodex`, emit the result or `{"error":…}` with exit 1. `ClaudeAdapter()`'s `projectsRoot` default reads `ClaudeSession.defaultProjectsRoot`; for the sandbox, set it to the sandbox home's `projects` directory so nothing resolves against the real one:

```swift
        var claude = ClaudeAdapter()
        if let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            claude.projectsRoot = { URL(fileURLWithPath: home).appendingPathComponent("projects") }
        }
```

Check `FlagSet()` and `CodexThreadOptions()` have no-argument initializers; if not, use the defaults the existing tests use.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `scripts/adapterprobe/build-probe.sh && /tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k LiveProbe`
Expected: 3 tests, PASS. Requires a logged-in codex; if `verifyHandshake` fails, the sandbox credential copy is the first thing to check.

- [ ] **Step 5: Commit**

```bash
git add scripts/adapterprobe/probe.swift scripts/adapterprobe/tests/test_live_probe.py
git commit -m "feat: probe subcommands for the live adapter members"
```

---

### Task 6: `capabilities.py` — rows and verdict derivation

**Files:**
- Create: `scripts/adapterprobe/capabilities.py`
- Create: `scripts/adapterprobe/tests/test_verdicts.py`

**Interfaces:**
- Consumes: `sandbox.AgentSandbox`, `ptyscreen.PtyScreen`.
- Produces: **the `ProbeContext` contract** (stated here, implemented by `run.py` in Task 7 —
  every row calls through it and nothing else):

  ```
  probe(args: list[str], stdin: str = "") -> dict   # runs the probe CLI, parses its JSON
  sandbox: AgentSandbox                              # the live sandbox for this run
  pty(agent: str, cmd: list[str]) -> PtyScreen       # cwd=sandbox.root, env=sandbox.env(agent)
  seed_one_turn(agent: str, cid: str) -> None        # full tier only; drives one real turn
  seeded_marker: str                                 # text seed_one_turn guarantees on screen
  versions: dict[str, str]                           # {"codex": ..., "claude": ...}
  ```

  Write this block as a module docstring at the top of `capabilities.py`. Task 7 implements it
  exactly; a row must never reach for anything not on this list.
- Produces: `verdict(declared, observed, absent_reason_holds=None) -> str` returning one of `ok`/`broken`/`by-design`/`rotted`/`needs-auth`/`error`; `ROWS: list[Row]` where `Row = namedtuple("Row", "key group agents tier flags run")`; `run` is `callable(ctx) -> Observation` and `Observation = namedtuple("Observation", "declared observed absent_reason_holds detail")`.

- [ ] **Step 1: Write the failing test**

```python
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k "Verdict or RowTable"`
Expected: FAIL — `ModuleNotFoundError: No module named 'capabilities'`

- [ ] **Step 3: Write `capabilities.py`**

```python
# scripts/adapterprobe/capabilities.py
"""The rows, and how a cell becomes a verdict.

The valuable cell is the one where DECLARED and OBSERVED disagree, so both are carried and the
verdict is derived from the pair rather than asserted by each probe.
"""
from collections import namedtuple

Row = namedtuple("Row", "key group agents tier flags run")
Observation = namedtuple("Observation", "declared observed absent_reason_holds detail")
Observation.__new__.__defaults__ = (None, None, None, "")


def verdict(declared, observed, absent_reason_holds=None):
    if observed == "needs-auth":
        return "needs-auth"
    if observed == "error" or observed is None:
        return "error"
    if declared:
        return "ok" if observed else "broken"
    # Declared absent. The refusal is only trustworthy if its stated reason was probed.
    if absent_reason_holds is None:
        return "error"
    return "by-design" if absent_reason_holds else "rotted"
```

Then define `ROWS` — exactly these 21 keys, matching the spec's §3.4 tables. Do not invent
others and do not omit any; the row table IS the matrix:

```python
DECLARATIONS = ["negotiatesIdentity", "needsRuntimeStart", "hasStatusRegistry",
                "textChannel", "dialogDriver", "openPromptReader",
                "homeMarkerFile", "identity", "environment"]                 # 9
GRAMMARS     = ["titleFromTranscript", "timelineItems", "sanitizedTitle"]    # 3
LIVE         = ["prepare", "binding", "location", "launchCommand",
                "resumeCommand", "rebind", "rename", "loginInvocation",
                "runtimeObservation"]                                        # 9
```

`loginInvocation`'s `run` returns `Observation(declared=True, observed="needs-auth")` — the
sandbox is authenticated, so an honest probe is impossible and the weaker "binary exists"
check must never be recorded as `ok`. `openPromptReader` for codex is the one row that sets
`absent_reason_holds`: it is `True` only when the rollout still records nothing while codex's
approval list is up, which is what lets a stale refusal surface as `rotted`.

Each `run` takes a context object (`ctx.probe(args, stdin=...)`, `ctx.sandbox`, `ctx.pty(...)`) and returns an `Observation`. Write them in three groups matching the spec's §3.4 tables. The two that matter most:

```python
def _resume_command(ctx, agent):
    """Type the real resumeCommand at a real pty and require prior history, no picker."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    ctx.seed_one_turn(agent, cid)            # tier "full" only; see run.py
    text = ctx.probe(["resume-command", agent, "--id", cid, "--cwd", ctx.sandbox.root])["text"]
    with ctx.pty(agent, ["/bin/sh", "-lc", text]) as term:
        attached = term.wait([ctx.seeded_marker], 60)
        picker = any(m in term.display() for m in
                     ("Select a session", "Resume a session", "to navigate"))
    return Observation(declared=True, observed=attached and not picker,
                       detail="picker shown instead of attaching" if picker else "")


def _rename(ctx, agent):
    """Outbound rename lands, and the name is still there after a relaunch."""
    prep = ctx.probe(["prepare", agent, "--cwd", ctx.sandbox.root])
    cid = prep["conversationID"]
    out = ctx.probe(["rename", agent, "--id", cid, "--to", "probe-renamed"])
    if "error" in out:
        return Observation(declared=True, observed=False, detail=out["error"])
    back = ctx.probe(["read", agent, "--id", cid])
    return Observation(declared=True, observed=back.get("title") == "probe-renamed",
                       detail=f"read back {back.get('title')!r}")
```

Give `resumeCommand` and `rename` `tier="full"`, and every declaration/grammar row `tier="cheap"`. Flag rows whose result could depend on real config with `flags=("sandbox-config",)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k "Verdict or RowTable"`
Expected: 9 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/adapterprobe/capabilities.py scripts/adapterprobe/tests/test_verdicts.py
git commit -m "feat: capability rows and verdict derivation"
```

---

### Task 7: `run.py` — runner, report, baseline diff

**Files:**
- Create: `scripts/adapterprobe/run.py`
- Create: `scripts/adapterprobe/tests/test_baseline.py`

**Interfaces:**
- Consumes: `capabilities.ROWS`, `capabilities.verdict`, `sandbox.AgentSandbox`, `ptyscreen.PtyScreen`, and **the `ProbeContext` contract defined in `capabilities.py`'s module docstring** — `run.py` provides the concrete object implementing exactly those six members, no more.
- Produces: `diff_baseline(baseline: dict, matrix: dict) -> dict` with keys `changed`, `added`, `removed`, `versions_changed`; `render(matrix: dict) -> str`; CLI `run.py [--tier cheap|full] [--capture] [--keep] [--update-baseline] [--json PATH]`. Exit codes: `0` no drift, `1` capability drift, `3` harness failure (any `error` cell where the baseline expected otherwise), `4` unsafe home refused.

- [ ] **Step 1: Write the failing test**

```python
# scripts/adapterprobe/tests/test_baseline.py
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from run import diff_baseline

BASE = {"versions": {"codex": "0.152.1", "claude": "2.1.258"},
        "cells": {"codex.rename": "ok", "codex.resumeCommand": "broken"}}


class BaselineDiffTests(unittest.TestCase):
    def test_identical_matrix_has_no_drift(self):
        d = diff_baseline(BASE, {"versions": BASE["versions"], "cells": dict(BASE["cells"])})
        self.assertEqual(d["changed"], {})
        self.assertEqual(d["added"], {})
        self.assertEqual(d["removed"], {})

    def test_a_regression_is_reported_as_changed(self):
        m = {"versions": BASE["versions"], "cells": {**BASE["cells"], "codex.rename": "broken"}}
        self.assertEqual(diff_baseline(BASE, m)["changed"],
                         {"codex.rename": ("ok", "broken")})

    def test_a_fix_is_also_reported_so_the_baseline_records_when_it_started_working(self):
        m = {"versions": BASE["versions"],
             "cells": {**BASE["cells"], "codex.resumeCommand": "ok"}}
        self.assertEqual(diff_baseline(BASE, m)["changed"],
                         {"codex.resumeCommand": ("broken", "ok")})

    def test_a_new_row_is_added_not_changed(self):
        m = {"versions": BASE["versions"], "cells": {**BASE["cells"], "codex.read": "ok"}}
        d = diff_baseline(BASE, m)
        self.assertEqual(d["added"], {"codex.read": "ok"})
        self.assertEqual(d["changed"], {})

    def test_a_version_bump_is_reported_even_with_an_identical_matrix(self):
        m = {"versions": {"codex": "0.153.0", "claude": "2.1.258"},
             "cells": dict(BASE["cells"])}
        self.assertEqual(diff_baseline(BASE, m)["versions_changed"],
                         {"codex": ("0.152.1", "0.153.0")})


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k Baseline`
Expected: FAIL — `ModuleNotFoundError: No module named 'run'`

- [ ] **Step 3: Write `run.py`**

```python
#!/usr/bin/env python3
"""The matrix runner."""
import argparse, json, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
PROBE = os.path.join(REPO, "DerivedData", "adapterprobe", "probe")
BASELINE = os.path.join(HERE, "baseline.json")

GLYPH = {"ok": "✓", "broken": "✗", "by-design": "⊘", "rotted": "!",
         "needs-auth": "🔒", "error": "?"}


def agent_versions():
    def v(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=20
                                  ).stdout.strip().splitlines()[0]
        except Exception:
            return "unavailable"
    return {"codex": v(["codex", "--version"]), "claude": v(["claude", "--version"])}


def diff_baseline(baseline, matrix):
    b, m = baseline.get("cells", {}), matrix.get("cells", {})
    changed = {k: (b[k], m[k]) for k in b.keys() & m.keys() if b[k] != m[k]}
    bv, mv = baseline.get("versions", {}), matrix.get("versions", {})
    return {
        "changed": changed,
        "added": {k: m[k] for k in m.keys() - b.keys()},
        "removed": {k: b[k] for k in b.keys() - m.keys()},
        "versions_changed": {k: (bv[k], mv[k]) for k in bv.keys() & mv.keys() if bv[k] != mv[k]},
    }


def render(matrix):
    lines = [f"agents: {matrix['versions']}", ""]
    for key, v in sorted(matrix["cells"].items()):
        detail = matrix.get("details", {}).get(key, "")
        lines.append(f"  {GLYPH.get(v, '?')} {v:<11} {key}" + (f"   — {detail}" if detail else ""))
    return "\n".join(lines)
```

Complete it with `main()`: parse args, refuse to proceed if the sandbox guard raises (exit 4), build the probe via `build-probe.sh`, open an `AgentSandbox`, run every `Row` whose `tier` is allowed and whose `agents` include each agent, catch every exception per row into an `error` cell with the traceback in `details`, assemble `{"versions":…, "cells":…, "details":…}`, print `render(...)`, then diff against `baseline.json` and exit `0`/`1`/`3`. `--update-baseline` writes the matrix to `baseline.json` instead of diffing.

`--capture` refreshes the grammar corpus, which the cheap tier reads instead of running a turn
(the sandbox that produced a transcript is deleted at the end of its run). It copies the
transcripts the full-tier rows produced into `Tests/FlightDeckTests/Fixtures/<Agent>/` and
writes `scripts/adapterprobe/corpus.json` recording the agent versions they came from:

```python
def corpus_staleness(corpus, versions):
    """A grammar checked only against an old corpus is checking history, not today."""
    return {k: (corpus.get("versions", {}).get(k), versions[k])
            for k in versions
            if corpus.get("versions", {}).get(k) not in (None, versions[k])}
```

`main()` calls `corpus_staleness` on every run and prints a `corpus stale:` line above the
matrix when it is non-empty. It is reported, never fatal — a stale corpus is a reason to
re-capture, not a drift in the adapters.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v -k Baseline`
Expected: 5 tests, PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/adapterprobe/run.py scripts/adapterprobe/tests/test_baseline.py
git commit -m "feat: matrix runner with baseline diffing"
```

---

### Task 8: `test-adapters.sh`, README, and the first baseline

**Files:**
- Create: `scripts/test-adapters.sh`
- Create: `scripts/adapterprobe/README.md`
- Create: `scripts/adapterprobe/baseline.json`

**Interfaces:**
- Consumes: everything above.
- Produces: `./scripts/test-adapters.sh [--tier full] [--update-baseline]` as the single entry point.

- [ ] **Step 1: Write `scripts/test-adapters.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# The venv lives OUTSIDE the repo, matching scripts/livefuzz/README.md's rule.
VENV=/tmp/adapterprobe-venv
if [ ! -x "$VENV/bin/python" ]; then
  echo "[adapterprobe] creating $VENV…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet pyte
fi

# Same output discipline as smoke.sh: xcodebuild is thousands of lines and floods a
# transcript. Full build output goes to the log; the matrix goes to stdout.
LOG="scripts/.adapterprobe.log"
: > "$LOG"
echo "[adapterprobe] building probe… (full output → $LOG)"
if ! scripts/adapterprobe/build-probe.sh >>"$LOG" 2>&1; then
  echo "ADAPTERPROBE FAIL: probe build failed — see $LOG"; tail -n 30 "$LOG"; exit 1
fi

exec "$VENV/bin/python" scripts/adapterprobe/run.py "$@"
```

`chmod +x scripts/test-adapters.sh`.

- [ ] **Step 2: Run the hermetic tests end to end**

Run: `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v`
Expected: every test from Tasks 1-7 passes.

- [ ] **Step 3: Take the first baseline**

Run: `./scripts/test-adapters.sh --tier full --update-baseline`
Expected: a printed matrix and a written `baseline.json`. **Do not fix any `broken` or `rotted` cell** — recording it is the deliverable. Read the matrix and note in the README which cells are red on first capture, with the two reported symptoms called out by name.

- [ ] **Step 4: Verify the gate actually gates**

Run: `./scripts/test-adapters.sh --tier full; echo "exit=$?"`
Expected: `exit=0` — the matrix now matches the baseline just written.

Then hand-edit one cell in `baseline.json` to a different verdict, re-run, and confirm a nonzero exit naming that cell. Restore the file with `git checkout scripts/adapterprobe/baseline.json`.

- [ ] **Step 5: Write `scripts/adapterprobe/README.md`**

Cover: what the suite is and the verdict vocabulary; the venv setup line; `./scripts/test-adapters.sh` usage and every flag; that `--tier full` spends tokens and creates real threads so it must not be looped; that the sandbox makes real history unreachable and the guard refuses a real home; that a `broken` cell is a finding to record, not to fix here; and the first-capture results with the versions they were taken against. Link the spec and cross-link `scripts/livefuzz/README.md` (shared pty driver) and `Tests/FlightDeckTests/CodexIntegrationTests.swift` (five specific codex behaviours as assertions).

- [ ] **Step 6: Commit**

```bash
git add scripts/test-adapters.sh scripts/adapterprobe/README.md scripts/adapterprobe/baseline.json
git commit -m "feat: adapter capability suite entry point, docs and first baseline"
```

---

## Verification

End to end, from a clean checkout:

1. `python3 -m venv /tmp/adapterprobe-venv && /tmp/adapterprobe-venv/bin/pip install pyte`
2. `/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v` — every hermetic test passes, no agent spawned.
3. `./scripts/test-adapters.sh` — cheap tier; prints the matrix, exits 0 against the committed baseline.
4. `./scripts/test-adapters.sh --tier full` — adds the rows needing a real turn, including both reported symptoms. Exits 0.
5. `cd scripts/livefuzz && /tmp/adapterprobe-venv/bin/python runfuzz.py single-set 1` — the extraction in Task 1 did not break the existing harness.
6. `./scripts/test-unit.sh` — the Swift suite is unchanged; `probe.swift` is not in any target, so this should be untouched. Budget ~8 minutes; it ignores `-only-testing:` and runs everything.

Confirm after a full run that `ls ~/.codex/sessions | wc -l` and the `~/.claude/projects` listing are unchanged from before it — the sandbox must have absorbed everything.
