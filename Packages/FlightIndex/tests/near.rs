//! `near`: find, grep, refs, calls and impact order their rows by graph distance from what the
//! agent is working on (explicit `near`, else the worktree's diff and the files it read last).
mod common;
use common::*;
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;

fn service() -> (tempfile::TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    (dir, svc)
}

fn ok(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let r = svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() });
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

/// Two `parse` functions. `x/far.ts`'s is the popular one (three importers), so it leads by
/// PageRank; `y/near_dep.ts`'s is one import away from `y/seed.ts`, the file the agent works on.
/// Both call `helper` in `h.ts`.
fn project() -> Repo {
    let r = init_repo();
    write(&r.root, "h.ts", "export function helper() {\n  return 1;\n}\n");
    write(&r.root, "x/far.ts", "import { helper } from '../h';\nexport function parse() {\n  return helper();\n}\n");
    for u in ["u1", "u2", "u3"] {
        write(&r.root, &format!("x/{u}.ts"), &format!("import {{ parse }} from './far';\nexport function {u}() {{\n  return parse();\n}}\n"));
    }
    write(&r.root, "y/near_dep.ts", "import { helper } from '../h';\nexport function parse() {\n  return helper();\n}\n");
    write(&r.root, "y/seed.ts", "import { parse } from './near_dep';\nexport function main() {\n  return parse();\n}\n");
    commit_all(&r.root, "init");
    r
}

/// Position of the first line mentioning `needle`, for "a is listed before b".
fn pos(text: &str, needle: &str) -> usize {
    text.find(needle).unwrap_or_else(|| panic!("{needle} not in:\n{text}"))
}

fn before(text: &str, a: &str, b: &str) -> bool {
    pos(text, a) < pos(text, b)
}

#[test]
fn without_near_the_popular_definition_leads() {
    let r = project();
    let (_d, svc) = service();
    let t = ok(&svc, &r.root, "find", json!({"name": "parse"}));
    assert!(before(&t, "x/far.ts", "y/near_dep.ts"), "{t}");
    assert!(!t.contains("nearness"), "{t}");
}

#[test]
fn find_and_grep_put_the_definition_near_the_seed_first() {
    let r = project();
    let (_d, svc) = service();
    let t = ok(&svc, &r.root, "find", json!({"name": "parse", "near": ["y/seed.ts"]}));
    assert!(before(&t, "y/near_dep.ts", "x/far.ts"), "{t}");
    assert!(t.contains("ordered by nearness"), "{t}");
    // A cap keeps the near one, not the popular one.
    let t = ok(&svc, &r.root, "find", json!({"name": "parse", "near": ["y/seed.ts"], "limit": 1}));
    assert!(t.contains("y/near_dep.ts") && !t.contains("x/far.ts"), "{t}");
    let t = ok(&svc, &r.root, "grep", json!({"query": "pars", "near": ["y/seed.ts"]}));
    assert!(before(&t, "y/near_dep.ts", "x/far.ts"), "{t}");
    // A symbol works as a seed too: `main` is defined in y/seed.ts.
    let t = ok(&svc, &r.root, "find", json!({"name": "parse", "near": ["main"]}));
    assert!(before(&t, "y/near_dep.ts", "x/far.ts"), "{t}");
}

#[test]
fn refs_calls_and_impact_list_the_near_rows_first() {
    let r = project();
    let (_d, svc) = service();
    let plain = ok(&svc, &r.root, "refs", json!({"symbol": "helper"}));
    assert!(before(&plain, "x/far.ts", "y/near_dep.ts"), "{plain}");
    let t = ok(&svc, &r.root, "refs", json!({"symbol": "helper", "near": ["y/seed.ts"]}));
    assert!(before(&t, "y/near_dep.ts", "x/far.ts"), "{t}");
    let t = ok(&svc, &r.root, "calls", json!({"name": "helper", "direction": "callers", "near": ["y/seed.ts"]}));
    assert!(before(&t, "y/near_dep.ts", "x/far.ts"), "{t}");
    let t = ok(&svc, &r.root, "impact", json!({"file_path": "h.ts", "near": ["y/seed.ts"]}));
    let direct = &t[pos(&t, "Direct importers")..];
    assert!(before(direct, "y/near_dep.ts", "x/far.ts"), "{t}");
}

#[test]
fn the_worktree_diff_is_the_default_seed_and_an_empty_near_turns_it_off() {
    let r = project();
    let (_d, svc) = service();
    write(&r.root, "y/seed.ts", "import { parse } from './near_dep';\nexport function main() {\n  return parse() + 1;\n}\n");
    let t = ok(&svc, &r.root, "find", json!({"name": "parse"}));
    assert!(before(&t, "y/near_dep.ts", "x/far.ts"), "{t}");
    assert!(t.contains("ordered by nearness"), "{t}");
    let t = ok(&svc, &r.root, "find", json!({"name": "parse", "near": []}));
    assert!(before(&t, "x/far.ts", "y/near_dep.ts"), "{t}");
}

#[test]
fn files_read_recently_seed_a_clean_worktree() {
    let r = project();
    let (_d, svc) = service();
    ok(&svc, &r.root, "read", json!({"file_path": "y/seed.ts"}));
    let t = ok(&svc, &r.root, "find", json!({"name": "parse"}));
    assert!(before(&t, "y/near_dep.ts", "x/far.ts"), "{t}");
}
