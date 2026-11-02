//! Capped, ranked list output with narrowing hints; readable `path:Type.method` ids; the
//! windowed whole-file `read` (contract: "Caps, ranking and ids").
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
    let req = Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() };
    let r = svc.handle(req);
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

/// The lines of `text` from the one starting with `from` up to (not including) the next line
/// that starts with `until`.
fn section<'a>(text: &'a str, from: &str, until: &str) -> Vec<&'a str> {
    text.lines().skip_while(|l| !l.starts_with(from)).skip(1).take_while(|l| !l.starts_with(until)).collect()
}

#[test]
fn impact_ranks_the_same_directory_importer_into_the_capped_list() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "lib/core/target.ts", "export function target() { return 1; }\n");
    // Forty importers far away whose paths sort before the near one.
    for i in 0..40 {
        write(&r.root, &format!("app/a{i:02}.ts"), &format!("import {{ target }} from '../lib/core/target';\nexport function a{i:02}() {{ return target(); }}\n"));
    }
    write(&r.root, "lib/core/near.ts", "import { target } from './target';\nexport function near() { return target(); }\n");
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "impact", json!({"file_path": "lib/core/target.ts"}));
    let near = r.root.join("lib/core/near.ts").display().to_string();
    let direct = section(&t, "Direct importers", "Transitive");
    assert!(direct.iter().take(30).any(|l| l.contains(&near)), "the same-directory importer is inside the cap: {t}");
    assert!(direct.iter().any(|l| l.contains("11 more") && l.contains("ranked by directory proximity") && l.contains("narrow")), "{t}");
    let radius = section(&t, "Transitive blast radius", "Co-change");
    assert!(radius.first().is_some_and(|l| l.contains(&near)), "nearest first in the radius too: {t}");
}

#[test]
fn refs_transitive_says_how_many_dependents_it_left_out() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "core.ts", "export function core() { return 1; }\n");
    for i in 0..40 {
        write(&r.root, &format!("m{i:02}.ts"), &format!("import {{ core }} from './core';\nexport function m{i:02}() {{ return core(); }}\n"));
    }
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "refs", json!({"symbol": "core", "transitive": true, "token_budget": 100000}));
    assert!(t.contains("Transitive dependents (40 file(s)):") && t.contains("… 10 more"), "{t}");
}

fn many_functions(n: usize) -> String {
    (0..n).map(|i| format!("export function fn_{i:03}() {{ return {i}; }}\n")).collect()
}

#[test]
fn grep_caps_at_fifty_rows_and_a_budget_cut_keeps_the_narrowing_hint() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "many.ts", &many_functions(400));
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "grep", json!({"query": "fn_"}));
    assert!(t.contains("… 350 more (50 of 400 shown)") && t.contains("kind=") && t.contains("limit=400"), "{t}");
    let t = ok(&svc, &r.root, "grep", json!({"query": "fn_", "limit": 400, "token_budget": 300}));
    let last = t.lines().last().unwrap();
    assert!(last.contains("of 400 shown") && last.contains("kind=") && last.contains("raise token_budget"), "the footer survives the cut: {last}");
    assert!(t.len() <= 300 * 4 + 400, "{}", t.len());
}

#[test]
fn grep_orders_rows_by_file_importance_then_name() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "a.ts", "export function widget_alpha() {}\n");
    write(&r.root, "z.ts", "export function widget_zulu() {}\nexport function widget() {}\n");
    for i in 0..5 {
        write(&r.root, &format!("u{i}.ts"), &format!("import {{ widget_zulu }} from './z';\nexport function u{i}() {{ widget_zulu(); }}\n"));
    }
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "grep", json!({"query": "widget"}));
    let pos = |n: &str| t.lines().position(|l| l.starts_with(&format!("{n} "))).unwrap_or(usize::MAX);
    assert!(pos("widget") < pos("widget_zulu") && pos("widget_zulu") < pos("widget_alpha"), "{t}");
}

#[test]
fn grep_puts_rows_from_a_file_named_after_the_query_first() {
    let (_d, svc) = service();
    let r = init_repo();
    // `hub.ts` is the most imported file; `SessionStore.ts` is named after the word searched.
    write(&r.root, "hub.ts", "export function session_hub() {}\n");
    write(&r.root, "SessionStore.ts", "export function session_load() {}\n");
    for i in 0..5 {
        write(&r.root, &format!("u{i}.ts"), &format!("import {{ session_hub }} from './hub';\nexport function u{i}() {{ session_hub(); }}\n"));
    }
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "grep", json!({"query": "session"}));
    let pos = |n: &str| t.lines().position(|l| l.starts_with(&format!("{n} "))).unwrap_or(usize::MAX);
    assert!(pos("session_hub") != usize::MAX && pos("session_load") < pos("session_hub"), "{t}");
}

#[test]
fn calls_header_counts_what_it_shows_of_the_total() {
    let (_d, svc) = service();
    let r = init_repo();
    let mut body = String::from("export function hub() { return 1; }\n");
    for i in 0..60 {
        body.push_str(&format!("export function c{i:02}() {{ return hub(); }}\n"));
    }
    write(&r.root, "hub.ts", &body);
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "calls", json!({"name": "hub", "direction": "callers"}));
    assert!(t.contains("Callers (50 of 60):"), "{t}");
    assert!(t.contains("… 10 more (50 of 60 shown)") && t.contains("limit=60"), "{t}");
    let t = ok(&svc, &r.root, "calls", json!({"name": "hub", "token_budget": 150}));
    assert!(t.contains("Callers (") && t.contains("of 60):") && t.contains("direction=callers") && t.contains("raise token_budget"), "{t}");
}

#[test]
fn outline_cut_by_the_budget_gives_the_next_offset() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "many.ts", &many_functions(400));
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "outline", json!({"file_path": "many.ts", "token_budget": 200}));
    let last = t.lines().last().unwrap();
    assert!(last.contains("next_offset:") && last.contains("raise token_budget"), "{last}");
    let k: usize = last.split("next_offset: ").nth(1).unwrap().split(' ').next().unwrap().parse().unwrap();
    assert!(k > 0 && k < 100 && t.contains(&format!("fn_{:03}", k - 1)) && !t.contains(&format!("fn_{k:03}")), "{t}");
}

fn long_file() -> String {
    let mut s = String::new();
    for i in 0..30 {
        s.push_str(&format!("export function part_{i:02}() {{\n"));
        for j in 0..8 {
            s.push_str(&format!("  const v{j} = {i} + {j};\n"));
        }
        s.push_str("  return 0;\n}\n");
    }
    s
}

#[test]
fn read_of_a_long_file_returns_its_outline_and_the_first_hundred_lines() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "long.ts", &long_file()); // 330 lines
    write(&r.root, "short.ts", &many_functions(120));
    write(&r.root, "notes.md", &"a line of prose\n".repeat(300));
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "read", json!({"file_path": "long.ts"}));
    assert!(t.contains("[L1-L100 of 330]"), "{t}");
    assert!(t.contains("part_29 [L320-L330]"), "the outline points past the window: {t}");
    assert!(t.contains("100 |") && !t.contains("101 |"), "{t}");
    assert!(t.lines().last().unwrap().contains("start_line") && t.contains("symbol_name="), "{t}");
    // An explicit range, limit or max_bytes reads as before.
    let t = ok(&svc, &r.root, "read", json!({"file_path": "long.ts", "start_line": 200}));
    assert!(t.contains("[L200-L330 of 330]") && t.contains("330 |"), "{t}");
    let t = ok(&svc, &r.root, "read", json!({"file_path": "long.ts", "max_bytes": 100000}));
    assert!(t.contains("[L1-L330 of 330]") && t.contains("330 |"), "{t}");
    // A short file is read whole.
    let t = ok(&svc, &r.root, "read", json!({"file_path": "short.ts"}));
    assert!(t.contains("[L1-L120 of 120]"), "{t}");
    // A file no language module handles has no outline to lead with: read whole.
    let t = ok(&svc, &r.root, "read", json!({"file_path": "notes.md"}));
    assert!(t.contains("[L1-L300 of 300]"), "{}", &t[..200]);
}

#[test]
fn read_of_a_symbol_past_max_bytes_names_its_range_and_where_to_go_on() {
    let (_d, svc) = service();
    let r = init_repo();
    let mut body = String::from("export function huge() {\n");
    for j in 0..2000 {
        body.push_str(&format!("  const value_{j} = {j};\n"));
    }
    body.push_str("  return 0;\n}\n");
    write(&r.root, "huge.ts", &body);
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "read", json!({"symbol_name": "huge"}));
    let last = t.lines().last().unwrap();
    assert!(last.contains("huge [L1-L2003]") && last.contains("start_line="), "{last}");
    // The full span is kept up to max_bytes: no 100-line cap on a symbol.
    assert!(t.contains("500 |"), "{}", &t[..200]);
}

#[test]
fn readable_ids_are_emitted_by_find_and_accepted_by_read_refs_and_calls() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "web/store.ts", "export class Store {\n  open() { return 1; }\n}\nexport function open() { return new Store().open(); }\n");
    write(&r.root, "web/other.ts", "export class Other {\n  open() { return 2; }\n}\n");
    commit_all(&r.root, "init");
    let path = r.root.join("web/store.ts").display().to_string();
    let t = ok(&svc, &r.root, "find", json!({"name": "open"}));
    assert!(t.contains(&format!("Id: {path}:Store.open")), "{t}");
    let id = format!("{path}:Store.open");
    let t = ok(&svc, &r.root, "read", json!({"symbol_name": id}));
    assert!(t.contains("// open method @") && t.contains("open() { return 1; }") && !t.contains("return 2"), "{t}");
    // A relative id is read against the cwd, like every path.
    let t = ok(&svc, &r.root, "read", json!({"symbols": ["web/store.ts:open"], "kind": "function"}));
    assert!(t.contains("// open function @") && !t.contains("warning"), "{t}");
    let t = ok(&svc, &r.root, "calls", json!({"name": format!("{path}:open"), "kind": "function"}));
    assert!(t.contains("Call hierarchy for open (function)"), "{t}");
    // An ambiguous name lists the candidates as ids that can be passed back.
    let t = ok(&svc, &r.root, "calls", json!({"name": "open"}));
    assert!(t.contains(&format!("- {path}:Store.open (method)")), "{t}");
    // `Type::name` is still a qualified name, not a path.
    let t = ok(&svc, &r.root, "find", json!({"name": "Store::open"}));
    assert!(t.contains("Found ") && t.contains("Store") && !t.contains("Other"), "{t}");
}

#[test]
fn find_detail_defaults_from_the_hit_count() {
    let (_d, svc) = service();
    let r = init_repo();
    let body: String = (0..12).map(|i| format!("export class K{i} {{\n  run() {{ return {i}; }}\n}}\n")).collect();
    write(&r.root, "k.ts", &body);
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "find", json!({"name": "run"}));
    assert!(t.contains("Found 12 match(es)") && !t.contains("File: ") && t.lines().filter(|l| l.starts_with("run ")).count() == 12, "rows past 10 hits: {t}");
    let t = ok(&svc, &r.root, "find", json!({"name": "run", "detail": "full"}));
    assert!(t.contains("File: "), "{t}");
    let t = ok(&svc, &r.root, "find", json!({"name": "run", "kind": "method", "limit": 3, "detail": "full"}));
    assert!(t.matches("File: ").count() == 3 && t.contains("… 9 more"), "{t}");
}

/// p5's ids and caps next to q9's `with=callers` and signature tree, and q8's `near` on top of
/// p5's ranked order: each still works when the others are in play.
#[test]
fn ids_work_with_callers_the_call_tree_and_a_near_seed() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "web/store.ts", "export class Store {\n  open() { return 1; }\n}\nexport function open() { return new Store().open(); }\n");
    write(&r.root, "web/user.ts", "import { open } from './store';\nexport function go() { return open(); }\n");
    write(&r.root, "far/zzz.ts", "import { open } from '../web/store';\nexport function later() { return open(); }\n");
    commit_all(&r.root, "init");
    let path = r.root.join("web/store.ts").display().to_string();
    let id = format!("{path}:open");
    ok(&svc, &r.root, "stats", json!({})); // waits for the whole build: a symbol `read` is answered from the first slice
    let t = ok(&svc, &r.root, "read", json!({"symbol_name": id, "kind": "function", "with": ["callers"]}));
    assert!(t.contains("// open function @") && t.contains("go") && t.contains("later"), "{t}");
    let t = ok(&svc, &r.root, "calls", json!({"name": id, "kind": "function", "depth": 2, "direction": "callers"}));
    assert!(t.contains("Call tree for open") && t.contains("go"), "{t}");
    // Proximity puts web/user.ts before far/zzz.ts; a near seed in far/ puts the far caller first.
    let at = |t: &str, name: &str| t.find(name).unwrap_or_else(|| panic!("no {name}: {t}"));
    let t = ok(&svc, &r.root, "calls", json!({"name": id, "kind": "function", "direction": "callers", "near": []}));
    assert!(at(&t, "go") < at(&t, "later"), "{t}");
    let t = ok(&svc, &r.root, "calls", json!({"name": id, "kind": "function", "direction": "callers", "near": [r.root.join("far/zzz.ts").display().to_string()]}));
    assert!(at(&t, "later") < at(&t, "go"), "{t}");
}

#[test]
fn find_narrows_to_a_file_or_directory_with_file_path() {
    let (_d, svc) = service();
    let r = init_repo();
    for dir in ["web", "web/admin", "api"] {
        for i in 0..3 {
            write(&r.root, &format!("{dir}/v{i}.ts"), "export function view() { return 1; }\n");
        }
    }
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "find", json!({"name": "view", "limit": 2}));
    assert!(t.contains("narrow with kind= or file_path= (a file or directory)"), "{t}");
    let t = ok(&svc, &r.root, "find", json!({"name": "view", "file_path": "web/admin"}));
    assert!(t.starts_with("Found 3 match(es)") || t.contains("Found 3 match(es)"), "{t}");
    assert!(!t.contains("/api/") && !t.contains("web/v0.ts"), "{t}");
    let t = ok(&svc, &r.root, "find", json!({"name": "view", "file_path": "web"}));
    assert!(t.contains("Found 6 match(es)"), "a directory takes in its subdirectories: {t}");
    let t = ok(&svc, &r.root, "find", json!({"name": "view", "file_path": "api/v1.ts"}));
    assert!(t.contains("Found 1 match(es)") && t.contains("api/v1.ts"), "{t}");
}
