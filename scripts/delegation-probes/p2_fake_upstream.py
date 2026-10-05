#!/usr/bin/env python3
"""P2b: what does codex actually send the model? See docs/DELEGATION-PROBES.md.

Usage:  python3 scripts/delegation-probes/p2_fake_upstream.py <codex-binary> skill [SKILL.md]
        python3 scripts/delegation-probes/p2_fake_upstream.py <codex-binary> devinst

  skill    puts SKILL.md (default: the bundled delegate skill) at
           $CODEX_HOME/skills/flightdeck-delegate/ and reports whether the request
           lists it, and whether the body was inlined.
  devinst  sets developer_instructions in config.toml AND with -c, and reports which
           one reached the request. Measured: the -c value REPLACES the config.toml one.

Zero tokens: codex's config points at a local HTTP server that records each POST body
and answers 500, with retries off. stdin is closed, or `codex exec` waits on it."""
import http.server, json, os, shutil, subprocess, sys, tempfile, threading

codex, mode = sys.argv[1], sys.argv[2]
repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
skill_md = sys.argv[3] if len(sys.argv) > 3 else f"{repo_root}/Resources/ClaudePlugin/skills/delegate/SKILL.md"
root = tempfile.mkdtemp(prefix="p2-upstream-")
chome = f"{root}/home/.codex"
os.makedirs(f"{root}/work")
os.makedirs(chome)
bodies = []

class Recorder(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        bodies.append(self.rfile.read(int(self.headers.get("content-length", 0))).decode())
        self.send_response(500)
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Recorder)
threading.Thread(target=server.serve_forever, daemon=True).start()
extra_toml, extra_args = "", []
if mode == "skill":
    os.makedirs(f"{chome}/skills/flightdeck-delegate")
    shutil.copy(skill_md, f"{chome}/skills/flightdeck-delegate/SKILL.md")
elif mode == "devinst":
    extra_toml = 'developer_instructions = "USER-MARK from config.toml"\n'
    extra_args = ["-c", 'developer_instructions="FD-MARK from -c\\nsecond line with \\"quotes\\""']
else:
    sys.exit(f"unknown mode {mode}")
open(f"{chome}/config.toml", "w").write(f'''model_provider = "fake"
model = "gpt-5"
{extra_toml}
[model_providers.fake]
name = "fake"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
env_key = "FAKE_KEY"
request_max_retries = 0
stream_max_retries = 0
''')
env = {k: v for k, v in os.environ.items() if not k.startswith(("CODEX_", "CLAUDE"))}
env.update(HOME=f"{root}/home", CODEX_HOME=chome, FAKE_KEY="x")
try:
    print(subprocess.run([codex, "--version"], capture_output=True, text=True).stdout.strip())
    try:
        subprocess.run([codex, *extra_args, "exec", "--skip-git-repo-check", "say hi"], cwd=f"{root}/work",
                       env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=60)
    except subprocess.TimeoutExpired:
        print("codex still running at 60s; killed")
    print(f"{len(bodies)} request(s) captured")
    if bodies:
        request = bodies[0]
        if mode == "skill":
            body = open(skill_md).read().split("---", 2)[2].strip()
            print("skill listed:", "flightdeck-delegate/SKILL.md" in request)
            print("body inlined:", body[:60] in request)
        else:
            print("config.toml value reached the model:", "USER-MARK" in request)
            print("-c value reached the model:", "FD-MARK" in request)
finally:
    server.shutdown()
    shutil.rmtree(root, ignore_errors=True)
