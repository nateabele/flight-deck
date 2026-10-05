#!/usr/bin/env python3
"""P1: does a skill added to a --plugin-dir plugin AFTER an interactive claude
session starts become available without a restart? See docs/DELEGATION-PROBES.md.

Usage:  python3 -m venv /tmp/p1venv && /tmp/p1venv/bin/pip install pyte
        /tmp/p1venv/bin/python scripts/delegation-probes/p1_plugin_reload.py <trusted-dir> [plugin-dir]

<trusted-dir> must be a folder claude already trusts. A trust dialog opens focused on
"No, exit", so this driver never sends a key until the composer box is on screen.

With no plugin-dir it builds a throwaway plugin in a temp dir, adds a second skill
mid-session, and reports the autocomplete before, after 8 s, and after
`/reload-plugins`. With a plugin-dir it only checks that its skills are offered
(for example `Resources/ClaudePlugin`, which should offer `/flight-deck:delegate`).

Zero model turns: everything is read off the TUI's local slash-command
autocomplete. The parent session's markers are cleared, or a claude spawned from
claude silently runs with transcript saving off."""
import json, os, pty, select, shutil, signal, sys, tempfile, time
import pyte

cwd = sys.argv[1]
given = sys.argv[2] if len(sys.argv) > 2 else None
plugin = given or tempfile.mkdtemp(prefix="p1-plugin-")
if given:
    name = json.load(open(f"{plugin}/.claude-plugin/plugin.json"))["name"]
else:
    name = "p1probe"
    os.makedirs(f"{plugin}/.claude-plugin")
    open(f"{plugin}/.claude-plugin/plugin.json", "w").write('{"name":"p1probe","version":"0.0.1"}\n')

def add_skill(skill):
    os.makedirs(f"{plugin}/skills/{skill}", exist_ok=True)
    open(f"{plugin}/skills/{skill}/SKILL.md", "w").write(
        f"---\nname: {skill}\ndescription: P1 probe skill {skill}. Never use.\n---\n\nbody\n")

if not given:
    add_skill("alphaprobe")  # present at launch: the control that proves the listing works

DROP = ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_PID", "CLAUDE_EFFORT"]
env = {k: v for k, v in os.environ.items() if k not in DROP}
env["TERM"] = "xterm-256color"
COLS, ROWS = 160, 50
screen = pyte.Screen(COLS, ROWS)
stream = pyte.ByteStream(screen)
pid, fd = pty.fork()
if pid == 0:
    import fcntl, struct, termios
    os.chdir(cwd)
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    os.execvpe("claude", ["claude", "--plugin-dir", plugin], env)

def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                stream.feed(os.read(fd, 65536))
            except OSError:
                return

def text():
    return "\n".join(screen.display)

def send(keys):
    os.write(fd, keys.encode())
    pump(0.5)

def dump(label):
    lines = [l.rstrip() for l in screen.display if l.strip()]
    print(f"--- screen: {label}\n" + "\n".join(lines[-20:]))

def trust_dialog():
    t = text().lower()
    return "do you trust" in t or "trust this folder" in t

deadline = time.time() + 60
while time.time() < deadline and not (("❯" in text() and "────" in text()) or trust_dialog()):
    pump(0.3)
if trust_dialog() or "❯" not in text():
    dump("startup: not ready, or a trust dialog")
    os.kill(pid, signal.SIGKILL)
    sys.exit(2)
pump(2)

def listing():
    return sorted({w.split(":", 1)[1] for w in text().split() if w.startswith(f"/{name}:") and w != f"/{name}:"})

def offered(label, patience=3.0):
    """Polls rather than reading once: under load the autocomplete list draws a beat after
    the keystrokes, and a single early read reports an empty list that means nothing."""
    send(f"/{name}:")
    end = time.time() + patience
    while time.time() < end and not listing():
        pump(0.3)
    pump(0.5)
    shown = listing()
    print(f"{label}: autocomplete offers {shown}")
    send("\x15")  # ^U clears the composer without submitting
    return shown

try:
    if given:
        offered("bundled plugin", patience=20)
    else:
        # The control must show before anything else means anything: plugins load after the
        # composer draws, so an empty T0 is "not loaded yet", never a verdict.
        if not offered("T0 at launch", patience=20):
            sys.exit("control skill never appeared; the probe proves nothing")
        add_skill("betaprobe")
        pump(8)  # time for any file watcher to notice
        offered("T1 8s after adding skills/betaprobe, no reload")
        send("/reload-plugins")
        send("\r")
        pump(6)
        offered("T2 after /reload-plugins")
finally:
    os.kill(pid, signal.SIGKILL)
    if not given:
        shutil.rmtree(plugin, ignore_errors=True)
