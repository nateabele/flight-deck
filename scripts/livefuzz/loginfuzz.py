#!/usr/bin/env python3
"""Drive the Mac's screen-menu reading against a live claude's first-run login flow.

    <venv>/bin/python loginfuzz.py

A sibling of `runfuzz.py`, for the dialogs claude never writes to its transcript
(`Sources/FlightDeck/ScreenPromptReader.swift`). It starts a REAL `claude` in a pty with a fresh,
empty `CLAUDE_CONFIG_DIR` — so it shows its first-run theme picker and then `/login`'s menu — and
at each screen asks the actual `ScreenPromptReader`/`ChoiceDialog` (compiled by
`build_screenprobe()`, via `screenprobe.swift`) what the Mac would offer. It then does what a
phone tap does on the Mac: arrows, re-read, confirm the cursor landed and the identity held,
Return.

It goes UP TO the paste-code screen and stops. **It never pastes a code and never completes a
login**: `open`/`xdg-open`/`BROWSER` are shimmed so no browser launches, the config dir is a
throwaway so no real credentials are read or written, and claude is killed on the paste-code
screen. It spends no model tokens — claude never reaches a conversation.

The authorize URL carries the attempt's `state`, so it is parsed and checked in memory and never
printed or written anywhere.

Needs a live `claude` on the PATH and `pyte` (the same venv as `runfuzz.py`).
"""
import fcntl
import json
import os
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from urllib.parse import parse_qs, urlparse

import pyte

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BUILD = os.path.join(tempfile.gettempdir(), "flightdeck-screenprobe")
PROBE_BIN = os.path.join(BUILD, "screenprobe")
COLS, ROWS = 140, 45
DOWN, UP, RETURN = b"\x1b[B", b"\x1b[A", b"\r"

FLEETKIT_SOURCES = ["ScreenPrompt.swift", "OpenPrompt.swift", "JSONValue.swift", "Timeline.swift"]


def build_screenprobe():
    """Compile the real sources: the FleetKit subset as a module, then the app-side reader.

    Two steps because `ScreenPromptReader.swift` does `import FleetKit`, and the files it needs
    from there are `public` API of that module — so they are built AS that module rather than
    pasted into one. Always rebuilt: a run is minutes long and the compile is seconds, and a
    stale binary would check the wrong parser.
    """
    os.makedirs(BUILD, exist_ok=True)
    fleetkit = [os.path.join(REPO_ROOT, "Sources", "FleetKit", f) for f in FLEETKIT_SOURCES]
    subprocess.run(
        ["swiftc", "-O", "-parse-as-library", "-module-name", "FleetKit", "-emit-module",
         "-emit-library", "-static", *fleetkit, "-o", os.path.join(BUILD, "libFleetKit.a"),
         "-emit-module-path", os.path.join(BUILD, "FleetKit.swiftmodule")],
        check=True, cwd=REPO_ROOT)
    subprocess.run(
        ["swiftc", "-O", "-I", BUILD, "-L", BUILD, "-lFleetKit",
         os.path.join(REPO_ROOT, "Sources", "FlightDeck", "ScreenPromptReader.swift"),
         os.path.join(REPO_ROOT, "Sources", "FlightDeck", "ChoiceDialog.swift"),
         os.path.join(HERE, "screenprobe.swift"), "-o", PROBE_BIN],
        check=True, cwd=REPO_ROOT)


def probe(op_args, screen):
    done = subprocess.run([PROBE_BIN, *op_args], input=screen, text=True, capture_output=True)
    if done.returncode != 0:
        raise RuntimeError(f"screenprobe {op_args} failed: {done.stderr.strip()}")
    return done.stdout.strip()


def read(screen):
    return json.loads(probe(["read"], screen))


class Claude:
    """A real claude in a pty, rendered through pyte — what `readViewport()` returns, as text."""

    def __init__(self):
        self.work = tempfile.mkdtemp(prefix="loginfuzz-")
        cfg = os.path.join(self.work, "config")
        shim = os.path.join(self.work, "shim")
        os.makedirs(cfg)
        os.makedirs(shim)
        self.open_log = os.path.join(self.work, "open.log")
        for name in ("open", "xdg-open", "fakebrowser"):
            path = os.path.join(shim, name)
            with open(path, "w") as f:
                f.write(f'#!/bin/sh\necho "{name} $@" >> {self.open_log}\n')
            os.chmod(path, 0o755)
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("ANTHROPIC") and k != "CLAUDE_CODE_OAUTH_TOKEN"}
        env.update(CLAUDE_CONFIG_DIR=cfg, BROWSER=os.path.join(shim, "fakebrowser"),
                   PATH=shim + ":" + env["PATH"], TERM="xterm-256color",
                   COLUMNS=str(COLS), LINES=str(ROWS))
        self.screen = pyte.Screen(COLS, ROWS)
        self.stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(self.work)
            os.execvpe("claude", ["claude"], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))

    def pump(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.1)
            if ready:
                try:
                    self.stream.feed(os.read(self.fd, 65536))
                except OSError:
                    return

    def text(self):
        return "\n".join(line.rstrip() for line in self.screen.display).rstrip() + "\n"

    def wait_for(self, needle, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            self.pump(0.3)
            if needle in self.text():
                return True
        return False

    def send(self, keys, settle=0.6):
        os.write(self.fd, keys)
        self.pump(settle)

    def browser_state(self):
        """The `state` of the URL claude handed the (shimmed) browser, or None. Read in memory only."""
        try:
            with open(self.open_log) as f:
                for line in f:
                    m = re.search(r"https://\S+", line)
                    if m:
                        return parse_qs(urlparse(m.group(0)).query).get("state", [None])[0]
        except OSError:
            pass
        return None

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        shutil.rmtree(self.work, ignore_errors=True)


results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"  {'OK  ' if ok else 'FAIL'} {name}{(' - ' + detail) if detail else ''}", flush=True)
    return ok


def main():
    build_screenprobe()
    c = Claude()
    try:
        print("== claude first-run login, driven through the real ScreenPromptReader ==", flush=True)
        if not check("theme picker appears", c.wait_for("Choose the text style")):
            return
        shot = read(c.text())
        check("theme picker produces no card (unnumbered list, out of scope)", shot["kind"] == "none",
              f"read={shot['kind']}")

        c.send(RETURN)
        if not check("login-method menu appears", c.wait_for("Select login method")):
            return
        menu = read(c.text())
        check("menu is read as a menu", menu["kind"] == "menu", menu["kind"])
        if menu["kind"] != "menu":
            return
        check("three rows", len(menu["labels"]) == 3, f"{len(menu['labels'])} rows")
        check("question is the line above the list", menu["prompt"] == "Select login method:", menu["prompt"])
        check("cursor opens on row 0", menu["focused"] == 0, str(menu["focused"]))
        check("identity is a screen id", menu["call"].startswith("screen:"))
        call = menu["call"]

        # What the Mac does for a tap on row 1: arrows, then re-read and confirm before Return.
        c.send(DOWN)
        moved = read(c.text())
        check("one Down lands on row 1", moved.get("focused") == 1, str(moved.get("focused")))
        check("identity ignores the cursor", moved.get("call") == call)
        check("row 1 reads as its label",
              probe(["reads", "1", menu["labels"][1]], c.text()) == "true")
        check("row 1 does not read as row 0's label",
              probe(["reads", "1", menu["labels"][0]], c.text()) == "false")
        c.send(UP)
        back = read(c.text())
        check("Up returns to row 0 with the same identity",
              back.get("focused") == 0 and back.get("call") == call)

        # Row 0 is "Claude account with subscription": Return opens the paste-code screen.
        # Up to, and not past, that screen.
        check("row 0 reads as its label",
              probe(["reads", "0", menu["labels"][0]], c.text()) == "true")
        c.send(RETURN, settle=0.3)
        if not check("paste-code screen appears", c.wait_for("Paste code here if prompted", timeout=30)):
            return
        sign = read(c.text())
        check("screen is read as a sign-in", sign["kind"] == "signin", sign["kind"])
        if sign["kind"] != "signin":
            return
        url = sign["url"]
        query = parse_qs(urlparse(url).query)
        redirect = query.get("redirect_uri", [""])[0]
        check("URL is claude.com's authorize endpoint",
              url.startswith("https://claude.com/") and urlparse(url).path.endswith("/oauth/authorize"))
        check("URL was rejoined from its hard-wrapped lines", " " not in url and "\n" not in url)
        check("redirect is not localhost", "localhost" not in redirect and "127.0.0.1" not in redirect,
              urlparse(redirect).netloc)
        check("identity is a sign-in id, not the state", sign["call"].startswith("signin:")
              and query["state"][0] not in sign["call"])
        check("menu and sign-in are different dialogs", sign["call"] != call)
        browser = c.browser_state()
        check("on-screen URL is the same login attempt as the browser's",
              browser is not None and browser == query["state"][0],
              "browser URL not logged" if browser is None else "")
        print("  (stopped on the paste-code screen: nothing pasted, no login completed)", flush=True)
    finally:
        c.close()
        passed = sum(results)
        print(f"== {passed}/{len(results)} checks passed ==", flush=True)
        sys.exit(0 if passed == len(results) and results else 1)


if __name__ == "__main__":
    main()
