#!/usr/bin/env python3
"""Synthetic refactors in a throwaway tessera worktree: score impact pending=true against
`refs` and `impact file_path` (the baseline an agent has today).

usage: eval_pending.py <fdindex binary> <store dir> <mode: base|new> <out json>
Expects a throwaway tessera worktree at ./tessera-wt next to this script and a daemon on
/tmp/fdi-q15 (`fdindex --store <dir> --socket /tmp/fdi-q15 daemon --no-watch`).
"""
import json, os, re, subprocess, sys, time

S = os.path.dirname(os.path.abspath(__file__))
WT = os.path.join(S, "tessera-wt")
SOCK = "/tmp/fdi-q15"
BIN, STORE, MODE, OUT = sys.argv[1:5]

CASES = [
    dict(lang="rust", glob="*.rs", name="encode_frame", file="engine/proto/src/frame.rs",
         call=r"encode_frame\(", skip=r"fn encode_frame",
         arity=("schema: impl Fn(u64) -> Option<&'s [Col]>)", "schema: impl Fn(u64) -> Option<&'s [Col]>, strict: bool)"),
         rename=("(frame: &Frame,", "(fr: &Frame,"), edit=("encode_frame(", "encode_frame(true, ")),
    dict(lang="rust", glob="*.rs", name="apply_chunk", file="engine/sidecar/tests/common/mod.rs",
         call=r"common::apply_chunk\(", skip=r"^\s*//",
         arity=("c: &Chunk) {", "c: &Chunk, strict: bool) {"), rename=("c: &Chunk) {", "chunk: &Chunk) {"),
         edit=("apply_chunk(", "apply_chunk(true, ")),
    dict(lang="ts", glob="*.ts", name="assertNonEmptyDomain", file="formula-editor/test/proof/scope.ts",
         call=r"assertNonEmptyDomain\(", skip=r"function assertNonEmptyDomain",
         arity=("count: number): void", "count: number, strict: boolean): void"), rename=("count: number): void", "n: number): void"),
         edit=("assertNonEmptyDomain(", "assertNonEmptyDomain(true, ")),
    dict(lang="ts", glob="*.ts", name="actionToString", file="formula-editor/test/helpers/action-model.ts",
         call=r"actionToString\(|map\(actionToString\)", skip=r"function actionToString",
         arity=("actionToString(action: Action): string", "actionToString(action: Action, verbose: boolean): string"),
         rename=("actionToString(action: Action): string", "actionToString(a: Action): string"),
         edit=("actionToString(", "actionToString(true, "), edit2=("map(actionToString)", "map((a) => actionToString(a, true))")),
    dict(lang="elm", glob="*.elm", name="addElement", file="designer/src/Designer/LayoutOps.elm",
         call=r"LayoutOps\.addElement\b", skip=r"`",
         arity=[("addElement : ObjectId", "addElement : Bool -> ObjectId"), ("addElement l layout parent kind =", "addElement strict l layout parent kind =")],
         rename=("addElement l layout parent kind =", "addElement lid layout parent kind ="),
         edit=("LayoutOps.addElement ", "LayoutOps.addElement True ")),
    dict(lang="elm", glob="*.elm", name="activeIds", file="designer/src/Attention.elm",
         call=r"Attention\.activeIds\b", skip=r"`|test \"",
         arity=[("activeIds : Attention m d", "activeIds : Bool -> Attention m d"), ("activeIds attention =", "activeIds strict attention =")],
         rename=("activeIds attention =", "activeIds att ="),
         edit=("Attention.activeIds", "Attention.activeIds True")),
    dict(lang="elixir", glob="*.{ex,exs}", name="values_for", file="server/lib/tessera_server/scopes.ex",
         call=r"Scopes\.values_for\(", skip=r"^\s*#|`|@doc",
         arity=[("def values_for(%__MODULE__{} = state, conn)", "def values_for(%__MODULE__{} = state, conn, opts)"), ("@spec values_for(t(), term())", "@spec values_for(t(), term(), keyword())")],
         rename=("def values_for(%__MODULE__{} = state, conn)", "def values_for(%__MODULE__{} = state, c)"),
         edit=("Scopes.values_for(", "Scopes.values_for(nil, ")),
    dict(lang="elixir", glob="*.{ex,exs}", name="holders", file="server/lib/tessera_server/scopes.ex",
         call=r"Scopes\.holders\(", skip=r"^\s*#|`|@doc",
         arity=[("def holders(%__MODULE__{} = state, scope, key) do", "def holders(%__MODULE__{} = state, scope, key, opts) do"), ("@spec holders(t(), scope() | String.t(), key())", "@spec holders(t(), scope() | String.t(), key(), keyword())")],
         rename=("def holders(%__MODULE__{} = state, scope, key) do", "def holders(%__MODULE__{} = state, sc, key) do"),
         edit=("Scopes.holders(", "Scopes.holders(nil, "), fnrename="holders_of"),
    dict(lang="rust", glob="*.rs", name="eval", file="engine/evaluator/src/eval.rs",
         call=r"eval::eval\(", skip=r"fn eval",
         arity=("names: &HashMap<String, String>) -> R {", "names: &HashMap<String, String>, budget: u64) -> R {"),
         rename=("pub fn eval(core: &Core,", "pub fn eval(c: &Core,"), edit=("eval::eval(", "eval::eval(0, ")),
    dict(lang="ts", glob="*.ts", name="lit", file="formula-editor/src/anode.ts",
         call=r"ANode\.lit\(", def_call=r"(^|[^.\w$])lit\(", skip=r"^\s*\*|function lit\(",
         arity=("export function lit(rawValue: LitValue,", "export function lit(kind: number, rawValue: LitValue,"),
         rename=("export function lit(rawValue: LitValue,", "export function lit(value: LitValue,"), edit=("ANode.lit(", "ANode.lit(0, "), edit_alt=("lit(", "lit(0, ")),
]
for c in CASES:
    c.setdefault("fnrename", {"assertNonEmptyDomain": "assertDomain", "activeIds": "litIds", "apply_chunk": "apply_chunks", "values_for": "visible_values"}.get(c["name"]))


def sh(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def fd(*args):
    t = time.time()
    r = sh([BIN, "--store", STORE, "--socket", SOCK, "--cwd", WT, *args, "--token-budget", "40000", "--build-wait-ms", "600000"])
    return r.stdout + r.stderr, (time.time() - t) * 1000


def reset():
    sh(["git", "-C", WT, "checkout", "--", "."])


def truth_sites(c):
    r = sh(["rg", "-n", "--no-heading", "-g", c["glob"], c["call"], "."], cwd=WT)
    out = []
    for line in r.stdout.splitlines():
        m = re.match(r"\./([^:]+):(\d+):(.*)", line)
        if not m or re.search(c["skip"], m.group(3)):
            continue
        out.append((os.path.join(WT, m.group(1)), int(m.group(2))))
    if c.get("def_call"):
        for i, l in enumerate(open(os.path.join(WT, c["file"])).read().split("\n")):
            if re.search(c["def_call"], l) and not re.search(c["skip"], l):
                out.append((os.path.join(WT, c["file"]), i + 1))
    return sorted(set(out))


def replace_in(path, old, new, line=None):
    with open(path) as f:
        lines = f.read().split("\n")
    rng = [line - 1] if line else range(len(lines))
    for i in rng:
        if old in lines[i]:
            lines[i] = lines[i].replace(old, new, 1)
            if line is None:
                break
    else:
        if line is None:
            raise SystemExit(f"{old!r} not in {path}")
    with open(path, "w") as f:
        f.write("\n".join(lines))


def apply_def(c, which):
    edits = c[which] if isinstance(c[which], list) else [c[which]]
    for old, new in edits:
        replace_in(os.path.join(WT, c["file"]), old, new)


def parse_pending(text):
    return {(m.group(1), int(m.group(2))) for m in re.finditer(r"^    (/\S+):L(\d+) ", text, re.M)}


def parse_refs(text):
    sites, cur = set(), None
    for line in text.splitlines():
        if line.startswith("/"):
            cur = line.split("  [view")[0].strip()
        m = re.match(r"^  L(\d+) ", line)
        if m and cur:
            sites.add((cur, int(m.group(1))))
    return sites


def parse_impact_files(text):
    files, on = set(), False
    for line in text.splitlines():
        if line.startswith("Direct importers"):
            on = True
            continue
        if on and line.startswith("  /"):
            files.add(line.strip().split("  [view")[0])
        elif on and not line.startswith("  "):
            on = False
    return files


def score(listed, want):
    hit = len(listed & want)
    return dict(listed=len(listed), want=len(want), hit=hit, fp=len(listed - want), recall=(hit / len(want)) if want else None)


results = []
fd("build", WT)  # warm the base tree
for c in CASES:
    reset()
    sites = truth_sites(c)
    # Arity change, half of the call sites already updated.
    apply_def(c, "arity")
    half = (len(sites) + 1) // 2
    edited, left = sites[:half], set(sites[half:])
    for p, l in edited:
        text = open(p).read().split("\n")[l - 1]
        opts = [e for e in (c.get("edit2"), c["edit"], c.get("edit_alt")) if e and e[0] in text]
        assert opts, (p, l, text)
        replace_in(p, opts[0][0], opts[0][1], l)
    row = dict(case=c["name"], lang=c["lang"], sites=len(sites), edited=len(edited), owed=len(left))
    refs_text, refs_ms = fd("refs", c["name"], "--file-path", c["file"])
    row["refs"] = score(parse_refs(refs_text), left)
    imp_text, imp_ms = fd("impact", "--file-path", c["file"], "--include-tests")
    row["impact_files"] = score(parse_impact_files(imp_text), {p for p, _ in left})
    if MODE == "new":
        pend_text, ms = fd("impact", "--pending", "--limit", "500")
        row["pending"] = score(parse_pending(pend_text), left)
        row["pending_ms"] = round(ms)
        row["pending_missed"] = sorted(f"{os.path.relpath(p, WT)}:{l}" for p, l in left - parse_pending(pend_text))
        row["pending_fp"] = sorted(f"{os.path.relpath(p, WT)}:{l}" for p, l in parse_pending(pend_text) - left)[:12]
        with open(os.path.join(S, f"out-{c['name']}-arity.txt"), "w") as f:
            f.write(pend_text)
    reset()
    # Parameter rename: no call site owes an edit.
    apply_def(c, "rename")
    if MODE == "new":
        pend_text, ms = fd("impact", "--pending", "--limit", "500")
        row["rename_pending_rows"] = len(parse_pending(pend_text))
        row["rename_says_nothing"] = "no signature changed" in pend_text
        with open(os.path.join(S, f"out-{c['name']}-rename.txt"), "w") as f:
            f.write(pend_text)
    refs_text, _ = fd("refs", c["name"], "--file-path", c["file"])
    row["rename_refs_rows"] = len(parse_refs(refs_text))
    reset()
    if c["fnrename"] and MODE == "new":
        # Rename the function itself; half of the call sites already use the new name.
        old, new = c["name"], c["fnrename"]
        path = os.path.join(WT, c["file"])
        lines = open(path).read().split("\n")
        pat = re.compile(r"^(\s*(?:,|\(|pub fn|export function|def|defp|@spec)?\s*)" + re.escape(old) + r"\b")
        lines = [pat.sub(lambda m: m.group(1) + new, l) for l in lines]
        open(path, "w").write("\n".join(lines))
        for p, l in edited:
            replace_in(p, old, new, l)
        pend_text, ms = fd("impact", "--pending", "--limit", "500")
        row["fnrename"] = score(parse_pending(pend_text), left)
        row["fnrename_missed"] = sorted(f"{os.path.relpath(p, WT)}:{l}" for p, l in left - parse_pending(pend_text))
        row["fnrename_fp"] = sorted(f"{os.path.relpath(p, WT)}:{l}" for p, l in parse_pending(pend_text) - left)[:12]
        with open(os.path.join(S, f"out-{c['name']}-fnrename.txt"), "w") as f:
            f.write(pend_text)
        reset()
    results.append(row)
    print(json.dumps(row), flush=True)

json.dump(results, open(OUT, "w"), indent=1)
