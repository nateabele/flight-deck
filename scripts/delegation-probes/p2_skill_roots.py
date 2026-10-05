#!/usr/bin/env python3
"""P2a: which directories does codex's skill loader scan? See docs/DELEGATION-PROBES.md.

Usage:  python3 scripts/delegation-probes/p2_skill_roots.py <codex-binary>
        (run it for BOTH installs: ~/.local/bin/codex and /opt/homebrew/bin/codex)

Zero tokens: it only speaks newline-delimited JSON-RPC to `codex app-server` over stdio:
    {"id":1,"method":"initialize","params":{"clientInfo":{"name":"fd-p2-probe","version":"0"}}}
    {"method":"initialized"}
    {"id":2,"method":"skills/list","params":{"cwds":["<repo>"],"forceReload":true}}
    {"id":3,"method":"skills/extraRoots/set","params":{"extraRoots":["<bundle>/skills"]}}
    {"id":4,"method":"skills/list","params":{"cwds":["<repo>"],"forceReload":true}}
HOME and CODEX_HOME point at a throwaway sandbox, so nothing real is read or written."""
import json, os, shutil, subprocess, sys, tempfile

codex = sys.argv[1]
root = os.path.realpath(tempfile.mkdtemp(prefix="p2-roots-"))
home, chome, repo, bundle = (f"{root}/{d}" for d in ("home", "home/.codex", "repo", "bundle"))

def skill(directory, name):
    os.makedirs(f"{directory}/{name}", exist_ok=True)
    open(f"{directory}/{name}/SKILL.md", "w").write(f"---\nname: {name}\ndescription: probe {name}\n---\n\nbody\n")

skill(f"{chome}/skills", "in-codex-home")
skill(f"{home}/.agents/skills", "in-home-agents")
skill(f"{repo}/.agents/skills", "in-repo-agents")
skill(f"{repo}/.codex/skills", "in-repo-codex")
skill(f"{bundle}/skills", "in-extra-root")
os.makedirs(f"{repo}/.git")  # a project root, so the repo-scoped roots apply

env = {k: v for k, v in os.environ.items() if not k.startswith(("CODEX_", "CLAUDE"))}
env.update(HOME=home, CODEX_HOME=chome)
proc = subprocess.Popen([codex, "app-server"], cwd=repo, env=env, text=True,
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
next_id = 0

def rpc(method, params):
    global next_id
    next_id += 1
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params}) + "\n")
    proc.stdin.flush()
    while True:
        message = json.loads(proc.stdout.readline())
        if message.get("id") == next_id:
            return message

def listed():
    response = rpc("skills/list", {"cwds": [repo], "forceReload": True})
    return sorted((s["name"], s.get("scope"), s["path"].replace(root, "<sandbox>"))
                  for entry in response.get("result", {}).get("data", []) for s in entry.get("skills", []))

try:
    print(subprocess.run([codex, "--version"], capture_output=True, text=True).stdout.strip())
    rpc("initialize", {"clientInfo": {"name": "fd-p2-probe", "version": "0"}})
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized"}) + "\n")
    proc.stdin.flush()
    print("skills/list:")
    for row in listed():
        print("  ", row)
    print("skills/extraRoots/set:", rpc("skills/extraRoots/set", {"extraRoots": [f"{bundle}/skills"]}).get("error", "ok"))
    print("skills/list after extraRoots:")
    for row in listed():
        print("  ", row)
finally:
    proc.terminate()
    shutil.rmtree(root, ignore_errors=True)
