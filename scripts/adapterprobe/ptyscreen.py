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
