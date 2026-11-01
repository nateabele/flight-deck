mod common;
use common::*;
use flightindex::proto::{state, Request, Response, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn service() -> (tempfile::TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    (dir, svc)
}

fn req(cwd: &Path, tool: &str, args: Value) -> Request {
    Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() }
}

fn call(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> Response {
    svc.handle(req(cwd, tool, args))
}

/// The text of a call that must succeed.
fn ok(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let r = call(svc, cwd, tool, args);
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

const TS_A: &str = "import { helper } from './b';\nexport function entry() {\n  return helper() + 1;\n}\n";
const TS_B: &str = "export function helper() {\n  return needle_marker;\n}\nconst needle_marker = 2;\n";

fn project() -> Repo {
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/A.elm", ELM_A);
    write(&r.root, "src/B.elm", ELM_B);
    write(&r.root, "web/a.ts", TS_A);
    write(&r.root, "web/b.ts", TS_B);
    write(&r.root, "lib.rs", "pub fn x() { y(); }\nfn y() {}\n");
    write(&r.root, "tests/a.test.ts", "import { entry } from '../web/a';\nentry();\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn every_result_starts_with_the_view_header_and_names_absolute_paths() {
    let (_d, svc) = service();
    let r = project();
    let text = ok(&svc, &r.root, "find", json!({"name": "helper"}));
    let first = text.lines().next().unwrap();
    assert!(first.starts_with(&format!("view: {} (repo ", r.root.display())), "{first}");
    assert!(first.ends_with(", clean)"), "{first}");
    assert!(text.contains(&format!("File: {}", r.root.join("web/b.ts").display())), "{text}");
}

#[test]
fn the_view_is_found_from_the_named_path_not_from_cwd() {
    let (_d, svc) = service();
    let a = project();
    let b = init_repo();
    write(&b.root, "other.ts", "export function only_in_b() {}\n");
    commit_all(&b.root, "init");
    // cwd is repo A; the relative path leads into repo B.
    let rel = pathdiff(&b.root.join("other.ts"), &a.root);
    let text = ok(&svc, &a.root, "outline", json!({"file_path": rel}));
    assert!(text.lines().next().unwrap().contains(&b.root.display().to_string()), "answered from B's view: {text}");
    assert!(text.contains("only_in_b"));
}

/// `to` relative to `from` (both absolute, no symlinks), with `..` where needed.
fn pathdiff(to: &Path, from: &Path) -> String {
    let (t, f): (Vec<_>, Vec<_>) = (to.components().collect(), from.components().collect());
    let common = t.iter().zip(&f).take_while(|(a, b)| a == b).count();
    let mut out: PathBuf = std::iter::repeat_n("..", f.len() - common).collect();
    out.extend(t[common..].iter().map(|c| c.as_os_str()));
    out.to_string_lossy().to_string()
}

#[test]
fn a_pathless_query_searches_the_callers_view_and_aliases_are_accepted() {
    let (_d, svc) = service();
    let r = project();
    let sub = r.root.join("web");
    for args in [json!({"name": "entry"}), json!({"symbol": "entry"}), json!({"symbol_name": "entry"})] {
        assert!(ok(&svc, &sub, "find", args).contains("entry (function)"));
    }
    for key in ["file_path", "file", "path"] {
        let text = ok(&svc, &r.root, "outline", json!({ key: "web/a.ts" }));
        assert!(text.contains("# Outline:") && text.contains("entry"), "{key}: {text}");
    }
    // The MCP names work too.
    assert!(ok(&svc, &sub, "qartez_find", json!({"name": "entry"})).contains("entry (function)"));
}

#[test]
fn find_regex_kind_and_limit() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "find", json!({"name": "^(entry|helper)$", "regex": true}));
    assert!(t.contains("Found 2 match(es)"), "{t}");
    let t = ok(&svc, &r.root, "find", json!({"name": "ENT", "regex": "true", "limit": "1", "kind": "function"}));
    assert!(t.contains("Found 1 match(es)") || t.contains("1 more"), "{t}");
    let t = ok(&svc, &r.root, "find", json!({"name": "nothing_like_this"}));
    assert!(t.contains("No symbol found with name 'nothing_like_this'"));
}

#[test]
fn mermaid_is_only_for_deps_and_calls() {
    let (_d, svc) = service();
    let r = project();
    let bad = call(&svc, &r.root, "find", json!({"name": "entry", "format": "mermaid"}));
    assert!(!bad.ok && bad.state.as_deref() == Some(state::BAD_REQUEST), "{bad:?}");
    assert!(bad.error.unwrap().contains("only supported by deps and calls"));
    let deps = ok(&svc, &r.root, "deps", json!({"file_path": "web/a.ts", "format": "mermaid"}));
    assert!(deps.contains("graph LR") && deps.contains("-->") && deps.contains(&r.root.join("web/b.ts").display().to_string()), "{deps}");
    let calls = ok(&svc, &r.root, "calls", json!({"name": "helper", "format": "mermaid"}));
    assert!(calls.contains("graph LR") && calls.contains("-->"), "{calls}");
}

#[test]
fn deps_impact_refs_and_calls_follow_the_graph() {
    let (_d, svc) = service();
    let r = project();
    let deps = ok(&svc, &r.root, "deps", json!({"file_path": "web/b.ts"}));
    assert!(deps.contains("Imported by (1):"), "only a.ts imports b.ts: {deps}");
    assert!(deps.contains("(import: ./b)"));
    let impact = ok(&svc, &r.root, "impact", json!({"file_path": "web/b.ts"}));
    assert!(impact.contains("Transitive blast radius: 1 file(s)"), "tests excluded by default: {impact}");
    let impact = ok(&svc, &r.root, "impact", json!({"file_path": "web/b.ts", "include_tests": true}));
    assert!(impact.contains("Transitive blast radius: 2 file(s)"), "a.ts and, through it, the test: {impact}");
    let refs = ok(&svc, &r.root, "refs", json!({"symbol": "helper"}));
    assert!(refs.contains("References (1 in 1 file(s)):") && refs.contains("L3 call in entry"), "{refs}");
    let calls = ok(&svc, &r.root, "calls", json!({"name": "entry", "direction": "callees"}));
    assert!(calls.contains("Callees (1):") && calls.contains("helper"), "{calls}");
    assert!(!calls.contains("Callers ("), "direction=callees prints only callees");
}

#[test]
fn an_ambiguous_calls_name_is_refused_with_candidates() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "a.ts", "export function dup() {}\n");
    write(&r.root, "b.ts", "export function dup() {}\n");
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "calls", json!({"name": "dup"}));
    assert!(t.contains("resolves to 2 function-like candidate(s)") && t.contains("a.ts") && t.contains("b.ts"), "{t}");
    let t = ok(&svc, &r.root, "calls", json!({"name": "dup", "file_path": "a.ts"}));
    assert!(t.contains("Call hierarchy for dup"), "{t}");
}

#[test]
fn impact_lists_co_change_partners_from_git_history() {
    let (_d, svc) = service();
    let r = project();
    for i in 0..3 {
        write(&r.root, "web/a.ts", &format!("{TS_A}// {i}\n"));
        write(&r.root, "lib.rs", &format!("pub fn x() {{ y(); }}\nfn y() {{}}\n// {i}\n"));
        commit_all(&r.root, &format!("both {i}"));
    }
    let t = ok(&svc, &r.root, "impact", json!({"file_path": "web/a.ts"}));
    assert!(t.contains(&format!("{} (changed together 4×)", r.root.join("lib.rs").display())), "{t}");
}

#[test]
fn token_budget_truncates_with_a_footer_naming_the_parameter() {
    let (_d, svc) = service();
    let r = init_repo();
    let body: String = (0..400).map(|i| format!("export function fn_{i:03}() {{}}\n")).collect();
    write(&r.root, "many.ts", &body);
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "outline", json!({"file_path": "many.ts", "token_budget": 100}));
    assert!(t.contains("truncated") && t.contains("token_budget=100") && t.contains("raise token_budget"), "{t}");
    assert!(t.len() < 900);
    let t = ok(&svc, &r.root, "outline", json!({"file_path": "many.ts"}));
    assert!(t.contains("next_offset: 100 (of 400)"), "outline pages: {}", &t[t.len().saturating_sub(120)..]);
    let t = ok(&svc, &r.root, "outline", json!({"file_path": "many.ts", "offset": 100, "token_budget": 20000}));
    assert!(t.contains("fn_100") && !t.contains("fn_099"));
}

#[test]
fn read_by_symbol_by_range_and_for_a_file_outside_any_index() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "read", json!({"symbol_name": "helper"}));
    assert!(t.contains("// helper function @") && t.contains("1 | export function helper() {"), "{t}");
    let t = ok(&svc, &r.root, "read", json!({"file_path": "web/b.ts", "start_line": 2, "limit": 2}));
    assert!(t.contains("[L2-L3 of 4]") && t.contains("2 |   return needle_marker;") && !t.contains("1 |"), "{t}");
    // From a cwd outside any repository, by absolute path.
    let elsewhere = tempfile::tempdir().unwrap();
    let t = ok(&svc, &elsewhere.path().canonicalize().unwrap(), "read", json!({"file_path": r.root.join("web/b.ts").to_string_lossy()}));
    assert!(t.lines().next().unwrap().contains(&r.root.display().to_string()), "{t}");
    // A file in no repository and no project is refused, and nothing is indexed for it.
    let stray = elsewhere.path().canonicalize().unwrap().join("notes.txt");
    std::fs::write(&stray, "hello\n").unwrap();
    let bad = call(&svc, &elsewhere.path().canonicalize().unwrap(), "read", json!({"file_path": stray.to_string_lossy()}));
    assert!(!bad.ok && bad.error.unwrap().contains("not inside a git repository"));
}

#[test]
fn grep_matches_symbol_names_by_prefix_and_can_search_bodies() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "grep", json!({"query": "hel*"}));
    assert!(t.contains("Found 1 result(s)") && t.contains("helper"), "{t}");
    let t = ok(&svc, &r.root, "grep", json!({"query": "web"}));
    assert!(t.contains("No symbol names start with `web`"), "a file path never matches a prefix: {t}");
    let t = ok(&svc, &r.root, "grep", json!({"query": "needle_marker", "search_bodies": true}));
    assert!(t.contains("b.ts:L2 in helper (function)") && t.contains("return needle_marker;"), "{t}");
}

#[test]
fn stats_and_map_summarise_the_view() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "stats", json!({}));
    assert!(t.contains("files=6") && t.contains("typescript:") && t.contains("elm:"), "{t}");
    let t = ok(&svc, &r.root, "stats", json!({"file_path": "web/b.ts"}));
    assert!(t.contains("Importers: 1") && t.contains("Language: typescript"), "{t}");
    let t = ok(&svc, &r.root, "map", json!({"top_n": 3}));
    assert!(t.contains("# | File | PageRank | Exports | Blast") && t.contains(&r.root.join("web/b.ts").display().to_string()), "{t}");
    let t = ok(&svc, &r.root, "map", json!({"by": "symbols", "top_n": 3}));
    assert!(t.contains("# | Symbol | Kind | File | PageRank"), "{t}");
}

#[test]
fn an_edit_is_visible_to_the_very_next_query() {
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "entry"})); // builds and caches the base graph
    let mut found = 0;
    for i in 0..30 {
        let name = format!("fresh_fn_{i}");
        let body = format!("{TS_A}export function {name}() {{ return {i}; }}\n");
        write(&r.root, "web/a.ts", &body);
        if ok(&svc, &r.root, "find", json!({"name": name})).contains(&format!("Found 1 match(es) for '{name}'")) {
            found += 1;
        }
    }
    assert_eq!(found, 30, "read-your-writes: every edit found by the next query");
    // And the header says the view is dirty.
    assert!(ok(&svc, &r.root, "find", json!({"name": "entry"})).lines().next().unwrap().contains("dirty 1 files"));
}

#[test]
fn a_second_worktree_on_an_indexed_commit_answers_with_zero_parses() {
    let (d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "entry"}));
    let parsed = svc.engine.parse_count();
    let wt = d.path().canonicalize().unwrap().join("wt");
    git(&r.root, &["worktree", "add", "-q", "-b", "feature", wt.to_str().unwrap()]);
    let t = ok(&svc, &wt, "find", json!({"name": "entry"}));
    assert_eq!(svc.engine.parse_count(), parsed, "no blob parsed for the new worktree");
    assert!(t.lines().next().unwrap().starts_with(&format!("view: {} ", wt.display())));
    assert!(t.contains(&format!("File: {}", wt.join("web/a.ts").display())), "paths point into the worktree that asked: {t}");
}

#[test]
fn a_build_slower_than_the_bound_answers_building_then_finishes() {
    let (_d, svc) = service();
    let r = project();
    // A zero bound: answer at once from whatever is stored (nothing yet).
    let t = ok(&svc, &r.root, "find", json!({"name": "entry", "build_wait_ms": 0}));
    assert!(t.lines().next().unwrap().contains(" index: building, "), "{t}");
    // The build carries on in the background; a wait-for-it request then sees the whole index.
    let t = ok(&svc, &r.root, "find", json!({"name": "entry", "build_wait_ms": 20000}));
    assert!(!t.lines().next().unwrap().contains("building") && t.contains("Found 1 match(es)"), "{t}");
}

#[test]
fn a_file_that_is_not_parsed_yet_is_a_building_error_not_a_missing_file() {
    let (_d, svc) = service();
    let r = project();
    let bad = call(&svc, &r.root, "outline", json!({"file_path": "web/b.ts", "build_wait_ms": 0}));
    // Either the slice already landed (fine) or the answer says BUILDING; never a bare "no such file".
    if !bad.ok {
        assert_eq!(bad.state.as_deref(), Some(state::BUILDING), "{bad:?}");
        assert!(bad.error.unwrap().contains("index: building"));
    }
}

#[test]
fn many_clients_mixing_queries_and_builds_see_no_errors() {
    let (d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "entry"}));
    let mut roots = vec![r.root.clone()];
    for i in 0..4 {
        let wt = d.path().canonicalize().unwrap().join(format!("wt{i}"));
        git(&r.root, &["worktree", "add", "-q", "-b", &format!("f{i}"), wt.to_str().unwrap()]);
        write(&wt, "web/own.ts", &format!("export function own_{i}() {{}}\n")); // a new blob per worktree
        roots.push(wt);
    }
    let errors = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let done = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    std::thread::scope(|s| {
        for n in 0..24 {
            let (svc, roots, errors, done) = (svc.clone(), roots.clone(), errors.clone(), done.clone());
            s.spawn(move || {
                let root = &roots[n % roots.len()];
                for tool in ["find", "outline", "impact", "refs", "grep", "stats", "map", "deps"] {
                    let args = match tool {
                        "find" | "refs" => json!({"name": "helper", "symbol": "helper"}),
                        "grep" => json!({"query": "he"}),
                        "stats" | "map" => json!({}),
                        _ => json!({"file_path": "web/b.ts"}),
                    };
                    let r = svc.handle(req(root, tool, args));
                    done.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if !r.ok {
                        errors.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        eprintln!("{tool} in {}: {:?}", root.display(), r.error);
                    }
                }
            });
        }
    });
    assert_eq!(done.load(std::sync::atomic::Ordering::Relaxed), 24 * 8);
    assert_eq!(errors.load(std::sync::atomic::Ordering::Relaxed), 0);
}

#[test]
fn protocol_errors_are_answers_not_crashes() {
    let (_d, svc) = service();
    let r = project();
    let mut old = req(&r.root, "find", json!({"name": "x"}));
    old.v = Some(PROTOCOL_VERSION + 1);
    assert_eq!(svc.handle(old).state.as_deref(), Some(state::VERSION_MISMATCH));
    assert_eq!(call(&svc, &r.root, "bogus", json!({})).state.as_deref(), Some(state::BAD_REQUEST));
    assert_eq!(call(&svc, &r.root, "find", json!({})).state.as_deref(), Some(state::BAD_REQUEST));
    let rel = svc.handle(req(Path::new("relative/cwd"), "find", json!({"name": "x"})));
    assert_eq!(rel.state.as_deref(), Some(state::BAD_REQUEST));
    let hello = svc.handle(req(&r.root, "hello", json!({})));
    assert_eq!(hello.data.unwrap()["protocol"], PROTOCOL_VERSION);
    let st = ok(&svc, &r.root, "status", json!({}));
    assert!(st.contains("views known: 1"), "{st}");
}

#[test]
fn add_root_and_workspace_are_hints_that_build_early() {
    let (_d, svc) = service();
    let r = project();
    let t = ok(&svc, &r.root, "add_root", json!({"path": r.root.to_string_lossy(), "build_wait_ms": 0}));
    assert!(t.starts_with("view: "), "{t}");
    let t = ok(&svc, &r.root, "qartez_workspace", json!({"action": "remove", "path": "x"}));
    assert!(t.contains("nothing to do"));
}

#[test]
fn an_edit_is_visible_even_while_other_clients_hammer_the_same_worktree() {
    // Concurrent requests share a view computation; none may share one older than itself.
    let (_d, svc) = service();
    let r = project();
    ok(&svc, &r.root, "find", json!({"name": "entry"}));
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let hammers: Vec<_> = (0..6)
        .map(|_| {
            let (svc, root, stop) = (svc.clone(), r.root.clone(), stop.clone());
            std::thread::spawn(move || {
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    let r = svc.handle(req(&root, "find", json!({"name": "helper"})));
                    assert!(r.ok, "{:?}", r.error);
                }
            })
        })
        .collect();
    let mut missed = Vec::new();
    for i in 0..25 {
        let name = format!("raced_{i}");
        write(&r.root, "web/a.ts", &format!("{TS_A}export function {name}() {{}}\n"));
        if !ok(&svc, &r.root, "find", json!({"name": name})).contains("Found 1 match(es)") {
            missed.push(name);
        }
    }
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    for h in hammers {
        h.join().unwrap();
    }
    assert!(missed.is_empty(), "edits not visible to the next query: {missed:?}");
}
