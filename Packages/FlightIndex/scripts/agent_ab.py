#!/usr/bin/env python3
"""Agent-level A/B of two code-index MCP servers: headless Claude Code names the files and
functions a commit changed, from the commit subject alone, with only the index tools and Read.

The relevance harness (`examples/eval.rs`) scores a tool's ranked output; this scores what an
agent ends up answering through the tools, and what it spends getting there. Tasks and gold sets
come from the harness (`tasks-*.json` cache plus `examples/eval_gold.rs` for gold symbols).

    agent_ab.py select  --tasks T.json [T2.json …] --gold gold.jsonl --per-repo 30 --out sel.json
    agent_ab.py prep    --sel sel.json --clone NAME=DIR … --work W --fdindex BIN --store S --socket P
    agent_ab.py run     --sel sel.json --work W --arm A|B … --reps 1 --budget 60 --jobs 4
    agent_ab.py report  --sel sel.json --work W [--md out.md]

`prep` makes one worktree per task at the task's parent commit, from a scratch clone (made with
`git clone --shared`, so the real repository is only read), and indexes it for both arms first,
so neither arm's wall time includes a cold index build. Arm A is `qartez.orig` with a scratch
`--db-path` per worktree and a scratch HOME; arm B is the `fdindex` shim on a scratch daemon.
Every run goes through `claude -p --strict-mcp-config --setting-sources ""`, so no user or
project settings, hooks or other MCP servers apply. Nothing outside --work is written.
"""
import argparse
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

# ---------------------------------------------------------------------------------------------
# Pure parts (tested in test_agent_ab.py)


def parse_answer(text):
    """The agent's final {"files": [...], "functions": [...]}: the last fenced json block, else the
    last bare object holding "files". None when there is none."""
    if not text:
        return None
    candidates = re.findall(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    if not candidates:
        candidates = re.findall(r"\{[^{}]*\"files\"[^{}]*\}", text, re.S)
    for raw in reversed(candidates):
        try:
            obj = json.loads(raw)
        except ValueError:
            continue
        if isinstance(obj, dict) and isinstance(obj.get("files"), list):
            fns = obj.get("functions") or []
            return {"files": [str(f) for f in obj["files"]], "functions": [str(f) for f in fns if isinstance(f, (str, int))]}
    return None


def _strip_private(p):
    return p[len("/private"):] if p.startswith("/private/") else p


def norm_path(p, root):
    """A path the agent printed, relative to the worktree root, without line suffixes."""
    p = p.strip().strip("`")
    p = re.sub(r"#L\d+.*$", "", p)
    p = re.sub(r":\d+(-\d+)?$", "", p)
    q, r = _strip_private(p), _strip_private(root.rstrip("/"))
    if q.startswith(r + "/"):
        q = q[len(r) + 1:]
    elif q.startswith("./"):
        q = q[2:]
    return q


def bare_name(name):
    """A function name without its module, type, file, arity or parentheses."""
    n = name.strip().strip("`")
    n = re.sub(r"\(.*$", "", n)
    n = re.sub(r"/\d+$", "", n)
    n = n.split()[-1] if n.split() else n
    for sep in ("::", "#", ":", "."):
        n = n.rsplit(sep, 1)[-1]
    return n.rsplit("/", 1)[-1]


def score(gold_files, gold_symbols, files, functions):
    """file1: the first answered file is gold. file5: gold files in the first 5 distinct answers,
    over min(5, |gold|). func: gold function names (bare) among the first 15 answered names, over
    the number of distinct gold names; None when the task has no gold symbols."""
    ranked = list(dict.fromkeys(files))
    gold = set(gold_files)
    file1 = 1.0 if ranked[:1] and ranked[0] in gold else 0.0
    file5 = len(gold & set(ranked[:5])) / min(5, len(gold)) if gold else 0.0
    names = {bare_name(s[2]) for s in gold_symbols}
    func = None
    if names:
        said = {bare_name(f) for f in list(dict.fromkeys(functions))[:15]}
        func = len(names & said) / len(names)
    return {"file1": file1, "file5": file5, "func": func}


def usage(events):
    """Tool calls (by tool, MCP prefix dropped), tokens, cost and time from a stream-json run."""
    tools = {}
    for e in events:
        if e.get("type") != "assistant":
            continue
        for block in (e.get("message") or {}).get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                name = block.get("name", "?").rsplit("__", 1)[-1]
                tools[name] = tools.get(name, 0) + 1
    res = next((e for e in reversed(events) if e.get("type") == "result"), {})
    u = res.get("usage") or {}
    return {
        "tool_calls": sum(tools.values()),
        "tools": tools,
        "input_tokens": u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0),
        "uncached_tokens": u.get("input_tokens", 0),
        "cache_write_tokens": u.get("cache_creation_input_tokens", 0),
        "cache_read_tokens": u.get("cache_read_input_tokens", 0),
        "output_tokens": u.get("output_tokens", 0),
        "cost": res.get("total_cost_usd", 0.0) or 0.0,
        "wall_s": (res.get("duration_ms") or 0) / 1000.0,
        "turns": res.get("num_turns", 0),
        "result": res.get("result", ""),
    }


def mean_ci(xs, resamples=4000, seed=7):
    """Mean and a 95% percentile-bootstrap interval, deterministic for a given sample."""
    xs = [float(x) for x in xs]
    if not xs:
        return None
    m = sum(xs) / len(xs)
    if min(xs) == max(xs):
        return (m, m, m)
    rng = random.Random(seed)
    n = len(xs)
    means = sorted(sum(xs[rng.randrange(n)] for _ in range(n)) / n for _ in range(resamples))
    return (m, means[int(0.025 * resamples)], means[int(0.975 * resamples) - 1])


LANGS = {".rs": "rust", ".swift": "swift", ".ex": "elixir", ".exs": "elixir", ".elm": "elm", ".ts": "typescript",
         ".tsx": "typescript", ".js": "javascript", ".mjs": "javascript", ".py": "python"}


def categories(task):
    exts = [LANGS.get(os.path.splitext(f)[1], "other") for f in task["gold_files"]]
    lang = max(sorted(set(exts)), key=exts.count) if exts else "other"
    n = len(task["gold_files"])
    size = "1 file" if n == 1 else "2-3 files" if n <= 3 else "4+ files"
    m = re.match(r"^([a-z]+)(\([^)]*\))?!?:", task["subject"])
    kind = m.group(1) if m and m.group(1) in ("fix", "feat", "test", "perf", "refactor", "build", "docs", "chore", "site", "release") else "other"
    return {"repo": task["repo"], "lang": lang, "size": size, "kind": kind}


# ---------------------------------------------------------------------------------------------
# Orchestration


def load_tasks(paths, gold_path):
    gold = {}
    with open(gold_path) as f:
        for line in f:
            row = json.loads(line)
            gold[(row["repo"], row["commit"])] = row
    tasks = []
    for p in paths:
        for t in json.load(open(p)):
            g = gold.get((t["repo"], t["commit"]))
            if g is None:
                continue
            t["gold_files"] = g["gold_files"]
            t["gold_symbols"] = g["gold_symbols"]
            t["id"] = f"{t['repo']}-{t['commit'][:10]}"
            tasks.append(t)
    return tasks


def cmd_select(a):
    tasks = load_tasks(a.tasks, a.gold)
    rng = random.Random(a.seed)
    by_repo = {}
    for t in tasks:
        by_repo.setdefault(t["repo"], []).append(t)
    sel = []
    for repo in sorted(by_repo):
        pool = by_repo[repo]
        sel += rng.sample(pool, min(a.per_repo, len(pool)))
    json.dump(sel, open(a.out, "w"), indent=1)
    print(f"selected {len(sel)} tasks: " + ", ".join(f"{r} {sum(1 for t in sel if t['repo'] == r)}" for r in sorted(by_repo)))


def wt_dir(work, t):
    return os.path.join(work, "wt", t["id"])


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def cmd_prep(a):
    clones = dict(c.split("=", 1) for c in a.clone)
    sel = json.load(open(a.sel))
    os.makedirs(os.path.join(a.work, "qdb"), exist_ok=True)
    os.makedirs(os.path.join(a.work, "qhome"), exist_ok=True)
    timings = {}
    for t in sel:
        wt = wt_dir(a.work, t)
        if not os.path.isdir(wt):
            r = sh(["git", "-C", clones[t["repo"]], "worktree", "add", "--detach", wt, t["parent"]])
            if r.returncode:
                print(f"{t['id']}: worktree failed: {r.stderr.strip()}", file=sys.stderr)
                continue
        t0 = time.time()
        r1 = sh(["nice", "-n", "10", a.qartez, "--root", wt, "--db-path", qdb(a.work, t), "--no-watch", "--format", "compact", "stats"],
                env={**os.environ, "HOME": os.path.join(a.work, "qhome")}, timeout=1800)
        t1 = time.time()
        r2 = sh([a.fdindex, "--store", a.store, "--socket", a.socket, "--cwd", wt, "build", wt, "--wait-ms", "600000", "--no-start"], timeout=1800)
        t2 = time.time()
        timings[t["id"]] = {"qartez_s": round(t1 - t0, 1), "fdindex_s": round(t2 - t1, 1), "qartez_rc": r1.returncode, "fdindex_rc": r2.returncode}
        print(f"{t['id']}: qartez {t1 - t0:.1f}s rc={r1.returncode}  fdindex {t2 - t1:.1f}s rc={r2.returncode}  load {os.getloadavg()[0]:.0f}", flush=True)
        if r1.returncode or r2.returncode:
            print((r1.stderr + r2.stderr)[-600:], file=sys.stderr)
    json.dump(timings, open(os.path.join(a.work, "prep-timings.json"), "w"), indent=1)


def qdb(work, t):
    # One directory per database: qartez keeps an index.lock beside its database, so databases
    # sharing a directory would serialize (or refuse) the parallel runs.
    d = os.path.join(work, "qdb", t["id"])
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, "qartez.db")


PROMPT = """You are planning a change to the repository in the current directory. Do not edit anything.

The change, as its commit subject puts it:
"{subject}"

Find the existing files this change must modify, most likely first, and the functions or methods in them that must change. Use only the code index tools (mcp__qartez__*) and Read.

End your reply with one fenced json block, exactly in this form, with at most 10 files (paths relative to the repository root) and at most 15 function names, ranked:
```json
{{"files": ["path/to/file", "..."], "functions": ["name", "..."]}}
```"""

# Mutators exist in both servers; the task is read-only, and a run that edits would skew both arms.
MUTATORS = ["replace_symbol", "insert_before_symbol", "insert_after_symbol", "rename", "move", "safe_delete", "rename_file"]


def mcp_config(a, arm, t):
    wt = wt_dir(a.work, t)
    if arm == "A":
        server = {"command": a.qartez, "args": ["--root", wt, "--db-path", qdb(a.work, t), "--no-watch"],
                  "env": {"HOME": os.path.join(a.work, "qhome")}}
    else:
        server = {"command": a.fdindex, "args": ["--store", a.store, "--socket", a.socket, "--cwd", wt, "mcp", "--no-start"]}
    return {"mcpServers": {"qartez": server}}


class Ledger:
    """Spent dollars across runs (including earlier invocations), and the cap check."""

    def __init__(self, path, cap):
        self.path, self.cap, self.lock = path, cap, threading.Lock()
        self.spent = 0.0
        if os.path.exists(path):
            for line in open(path):
                self.spent += json.loads(line).get("cost", 0.0)

    def room(self, reserve):
        with self.lock:
            return self.spent + reserve <= self.cap

    def add(self, row):
        with self.lock:
            self.spent += row.get("cost", 0.0)
            with open(self.path, "a") as f:
                f.write(json.dumps(row) + "\n")


def run_one(a, ledger, t, arm, rep):
    key = f"{arm}-{rep}-{t['id']}"
    log = os.path.join(a.work, "runs-" + a.tag, key + ".jsonl")
    if os.path.exists(log + ".done"):
        return None
    if not ledger.room(a.reserve):
        return "budget"
    cfg = os.path.join(a.work, "cfg", key + ".json")
    json.dump(mcp_config(a, arm, t), open(cfg, "w"))
    wt = wt_dir(a.work, t)
    deny = [f"mcp__qartez__qartez_{m}" for m in MUTATORS]
    cmd = ["claude", "-p", PROMPT.format(subject=t["subject"]), "--model", a.model, "--strict-mcp-config", "--mcp-config", cfg,
           "--setting-sources", "", "--no-session-persistence", "--tools", "Read", "--allowedTools", "mcp__qartez", "Read",
           "--disallowedTools", *deny, "--output-format", "stream-json", "--verbose", "--max-budget-usd", str(a.run_cap)]
    t0 = time.time()
    load0 = os.getloadavg()[0]
    try:
        p = subprocess.run(cmd, cwd=wt, capture_output=True, text=True, timeout=a.timeout, stdin=subprocess.DEVNULL)
        out, rc = p.stdout, p.returncode
    except subprocess.TimeoutExpired as e:
        out, rc = (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "timeout"
    elapsed = time.time() - t0
    with open(log, "w") as f:
        f.write(out)
    events = []
    for line in out.splitlines():
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    u = usage(events)
    init = next((e for e in events if e.get("type") == "system" and e.get("subtype") == "init"), {})
    ans = parse_answer(u["result"]) or {"files": [], "functions": []}
    files = [norm_path(f, wt) for f in ans["files"]]
    s = score(t["gold_files"], t["gold_symbols"], files, ans["functions"])
    row = {"id": t["id"], "arm": arm, "rep": rep, "rc": rc, "answered": bool(ans["files"]), **s, **{k: v for k, v in u.items() if k != "result"},
           "elapsed_s": round(elapsed, 1), "load": round(load0, 1), "mcp_tools": len([x for x in init.get("tools", []) if str(x).startswith("mcp__")]),
           "mcp_status": init.get("mcp_servers"), "files": files[:10], "functions": ans["functions"][:15]}
    ledger.add(row)
    open(log + ".done", "w").close()
    print(f"{key}: f1={s['file1']:.0f} f5={s['file5']:.2f} fn={s['func']} calls={u['tool_calls']} ${u['cost']:.3f} {elapsed:.0f}s "
          f"load {load0:.0f} spent ${ledger.spent:.2f}", flush=True)
    return None


def cmd_run(a):
    for d in ("runs-" + a.tag, "cfg"):
        os.makedirs(os.path.join(a.work, d), exist_ok=True)
    sel = json.load(open(a.sel))
    if a.limit:
        sel = sel[: a.limit]
    ledger = Ledger(os.path.join(a.work, f"results-{a.tag}.jsonl"), a.budget)
    jobs = [(t, arm, rep) for rep in range(a.reps) for t in sel for arm in a.arm]
    # Interleave arms and tasks so machine load falls on both arms alike.
    random.Random(a.seed).shuffle(jobs)
    jobs.sort(key=lambda j: j[2])  # finish rep 0 everywhere before rep 1
    stop = threading.Event()

    def go(j):
        if stop.is_set():
            return
        if run_one(a, ledger, *j) == "budget":
            stop.set()

    with ThreadPoolExecutor(a.jobs) as ex:
        list(ex.map(go, jobs))
    print(f"spent ${ledger.spent:.2f} of ${a.budget:.2f}" + (" (stopped at the budget reserve)" if stop.is_set() else ""))


def fmt_ci(ci, scale=1.0, digits=1):
    if ci is None:
        return "n/a"
    m, lo, hi = (x * scale for x in ci)
    return f"{m:.{digits}f} [{lo:.{digits}f}, {hi:.{digits}f}]"


METRICS = [("file1", "File top-1 (%)", 100, 1), ("file5", "File recall@5 (%)", 100, 1), ("func", "Function recall (%)", 100, 1),
           ("tool_calls", "Tool calls", 1, 1), ("input_tokens", "Input tokens (k)", 0.001, 0), ("output_tokens", "Output tokens (k)", 0.001, 2),
           ("cache_write_tokens", "  of which cache writes (k)", 0.001, 1), ("cache_read_tokens", "  of which cache reads (k)", 0.001, 0),
           ("wall_s", "Wall time (s)", 1, 0), ("cost", "$ per task", 1, 3)]


def per_task(rows, metric):
    """Mean over reps, per task: the unit of the intervals is the task, not the run."""
    acc = {}
    for r in rows:
        v = r.get(metric)
        if v is not None:
            acc.setdefault(r["id"], []).append(v)
    return {k: sum(v) / len(v) for k, v in acc.items()}


def backfill(work, tag, row):
    """Fields added to usage() after a row was written, recomputed from the run's saved log."""
    if "cache_read_tokens" in row:
        return row
    log = os.path.join(work, "runs-" + tag, f"{row['arm']}-{row['rep']}-{row['id']}.jsonl")
    events = []
    for line in open(log):
        try:
            events.append(json.loads(line))
        except ValueError:
            pass
    u = usage(events)
    return {**row, **{k: u[k] for k in ("uncached_tokens", "cache_write_tokens", "cache_read_tokens")}}


def cmd_report(a):
    sel = {t["id"]: t for t in json.load(open(a.sel))}
    rows = [json.loads(line) for line in open(os.path.join(a.work, f"results-{a.tag}.jsonl"))]
    rows = [backfill(a.work, a.tag, r) for r in rows if r["id"] in sel]
    arms = sorted({r["arm"] for r in rows})
    by_arm = {arm: [r for r in rows if r["arm"] == arm] for arm in arms}
    paired = sorted(set.intersection(*[{r["id"] for r in by_arm[arm]} for arm in arms])) if arms else []
    out = []
    reps = sorted({r["rep"] for r in rows})
    out.append(f"{len(paired)} tasks answered by both arms, reps {len(reps)}, {len(rows)} runs, ${sum(r['cost'] for r in rows):.2f} spent. "
               "Intervals: 95% bootstrap over tasks (reps averaged per task first).\n")
    out.append("| metric | " + " | ".join(f"arm {x}" for x in arms) + " | B - A (paired) |")
    out.append("|---|" + "---|" * (len(arms) + 1))
    for key, label, scale, digits in METRICS:
        vals = {arm: per_task(by_arm[arm], key) for arm in arms}
        cells = [fmt_ci(mean_ci([vals[arm][i] for i in paired if i in vals[arm]]), scale, digits) for arm in arms]
        diff = "n/a"
        if len(arms) == 2:
            both = [i for i in paired if i in vals["A"] and i in vals["B"]]
            diff = fmt_ci(mean_ci([vals["B"][i] - vals["A"][i] for i in both]), scale, digits)
        out.append(f"| {label} | " + " | ".join(cells) + f" | {diff} |")
    if len(arms) == 2:
        out.append("\n### By category (paired tasks; File recall@5 %, Function recall %, tool calls, $)\n")
        out.append("| category | n | A f@5 | B f@5 | B-A f@5 | A fn | B fn | A calls | B calls | A $ | B $ |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|")
        cats = {}
        for i in paired:
            for dim, v in categories(sel[i]).items():
                cats.setdefault(f"{dim}={v}", []).append(i)
        f5 = {arm: per_task(by_arm[arm], "file5") for arm in arms}
        fn = {arm: per_task(by_arm[arm], "func") for arm in arms}
        calls = {arm: per_task(by_arm[arm], "tool_calls") for arm in arms}
        cost = {arm: per_task(by_arm[arm], "cost") for arm in arms}

        def m(d, ids, scale=100, digits=0):
            xs = [d[i] for i in ids if i in d]
            return f"{scale * sum(xs) / len(xs):.{digits}f}" if xs else "-"

        for c in sorted(cats):
            ids = cats[c]
            d = mean_ci([f5["B"][i] - f5["A"][i] for i in ids])
            out.append(f"| {c} | {len(ids)} | {m(f5['A'], ids)} | {m(f5['B'], ids)} | {fmt_ci(d, 100, 0)} | {m(fn['A'], ids)} | {m(fn['B'], ids)} | "
                       f"{m(calls['A'], ids, 1)} | {m(calls['B'], ids, 1)} | {m(cost['A'], ids, 1, 3)} | {m(cost['B'], ids, 1, 3)} |")
        wins = {"A": 0, "B": 0, "tie": 0}
        for i in paired:
            da = f5["B"][i] - f5["A"][i]
            wins["B" if da > 0 else "A" if da < 0 else "tie"] += 1
        out.append(f"\nPer-task File recall@5: B better on {wins['B']}, A better on {wins['A']}, tied on {wins['tie']}.")
        unanswered = {arm: sum(1 for r in by_arm[arm] if not r["answered"]) for arm in arms}
        out.append(f"Runs without a parsable answer: A {unanswered['A']}, B {unanswered['B']}.")
        tools = {arm: {} for arm in arms}
        for arm in arms:
            for r in by_arm[arm]:
                for k, v in r["tools"].items():
                    tools[arm][k] = tools[arm].get(k, 0) + v
        for arm in arms:
            top = sorted(tools[arm].items(), key=lambda kv: -kv[1])[:8]
            out.append(f"Arm {arm} tool mix: " + ", ".join(f"{k} {v}" for k, v in top) + f"; MCP tools exposed: {by_arm[arm][0].get('mcp_tools')}.")
    text = "\n".join(out)
    print(text)
    if a.md:
        open(a.md, "w").write(text + "\n")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("select")
    s.add_argument("--tasks", nargs="+", required=True)
    s.add_argument("--gold", required=True)
    s.add_argument("--per-repo", type=int, default=30)
    s.add_argument("--seed", type=int, default=20261101)
    s.add_argument("--out", required=True)
    for name in ("prep", "run"):
        q = sub.add_parser(name)
        q.add_argument("--sel", required=True)
        q.add_argument("--work", required=True)
        q.add_argument("--fdindex", required=True)
        q.add_argument("--store", required=True)
        q.add_argument("--socket", required=True)
        q.add_argument("--qartez", default=os.path.expanduser("~/.local/bin/qartez.orig"))
        if name == "prep":
            q.add_argument("--clone", action="append", required=True)
        else:
            q.add_argument("--arm", nargs="+", default=["A", "B"])
            q.add_argument("--reps", type=int, default=1)
            q.add_argument("--budget", type=float, default=60.0)
            q.add_argument("--reserve", type=float, default=2.0, help="stop starting runs this many dollars before the budget")
            q.add_argument("--run-cap", type=float, default=1.5, help="--max-budget-usd per run")
            q.add_argument("--jobs", type=int, default=4)
            q.add_argument("--model", default="sonnet")
            q.add_argument("--timeout", type=int, default=900)
            q.add_argument("--limit", type=int, default=0)
            q.add_argument("--seed", type=int, default=5)
            q.add_argument("--tag", default="main", help="names the results file and run logs")
    r = sub.add_parser("report")
    r.add_argument("--sel", required=True)
    r.add_argument("--work", required=True)
    r.add_argument("--md")
    r.add_argument("--tag", default="main")
    a = p.parse_args(argv)
    {"select": cmd_select, "prep": cmd_prep, "run": cmd_run, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
