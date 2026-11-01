//! `calls depth>1` as a signature-only tree, and `read with=callers`.
mod common;
use common::*;
use flightindex::proto::{state, Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;

fn service() -> (tempfile::TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    (dir, svc)
}

fn call(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> flightindex::proto::Response {
    svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() })
}

fn ok(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let r = call(svc, cwd, tool, args);
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

/// a -> b -> d -> a (a cycle) and a -> c -> d (a diamond: d is reached twice).
fn diamond() -> Repo {
    let r = init_repo();
    write(&r.root, "a.ts", "import { b, c } from './b';\nexport function a(x: number): number {\n  return b(x) + c(x);\n}\n");
    write(&r.root, "b.ts", "import { d } from './d';\nexport function b(x: number): number {\n  return d(x);\n}\nexport function c(y: number): number {\n  return d(y) * 2;\n}\n");
    write(&r.root, "d.ts", "import { a } from './a';\nexport function d(z: number): number {\n  return z > 0 ? a(z - 1) : 0;\n}\n");
    commit_all(&r.root, "init");
    r
}

/// The tree rows of one section (`Callers` or `Callees`), without the section title.
fn section<'a>(text: &'a str, title: &str) -> Vec<&'a str> {
    let mut rows = Vec::new();
    let mut inside = false;
    for l in text.lines() {
        if l.starts_with("Callers") || l.starts_with("Callees") {
            inside = l.starts_with(title);
            continue;
        }
        if inside && l.starts_with(' ') {
            rows.push(l);
        }
    }
    rows
}

fn indent(row: &str) -> usize {
    row.len() - row.trim_start().len()
}

#[test]
fn deep_calls_nest_each_callee_under_its_caller_with_its_signature_and_no_body() {
    let (_d, svc) = service();
    let r = diamond();
    let t = ok(&svc, &r.root, "calls", json!({"name": "a", "direction": "callees", "depth": 3}));
    let rows = section(&t, "Callees");
    let b = rows.iter().position(|l| l.trim_start().starts_with("- b ")).unwrap_or_else(|| panic!("b is a callee: {t}"));
    assert!(rows[b].contains("function b(x: number): number"), "the signature is on b's row: {t}");
    assert!(rows[b].contains(&r.root.join("b.ts").display().to_string()), "rows name absolute paths: {t}");
    let d = rows.iter().position(|l| l.trim_start().starts_with("- d ")).unwrap_or_else(|| panic!("d is under b: {t}"));
    assert!(d == b + 1 && indent(rows[d]) > indent(rows[b]), "d is nested under b: {t}");
    assert!(!t.contains("return"), "no body text: {t}");
}

#[test]
fn a_node_reached_twice_is_expanded_once_and_a_cycle_is_marked() {
    let (_d, svc) = service();
    let r = diamond();
    let t = ok(&svc, &r.root, "calls", json!({"name": "a", "direction": "callees", "depth": 3}));
    let rows = section(&t, "Callees");
    let ds: Vec<&&str> = rows.iter().filter(|l| l.trim_start().starts_with("- d ")).collect();
    assert_eq!(ds.len(), 2, "d is called by b and by c: {t}");
    assert_eq!(ds.iter().filter(|l| l.contains("function d(z: number)")).count(), 1, "d's signature is printed once: {t}");
    assert_eq!(ds.iter().filter(|l| l.contains('↑')).count(), 1, "the other row points at it: {t}");
    let back = rows.iter().find(|l| l.trim_start().starts_with("- a ")).unwrap_or_else(|| panic!("d calls a back: {t}"));
    assert!(back.contains('↺'), "a call back to an ancestor is a cycle: {t}");
    assert!(t.contains("4 distinct") || t.contains("3 distinct"), "the section says how many distinct functions it holds: {t}");
}

#[test]
fn limit_counts_functions_not_the_rows_that_point_back() {
    let (_d, svc) = service();
    let r = diamond();
    // b, c and d are the three functions; the second d row and the cycle row only point.
    let t = ok(&svc, &r.root, "calls", json!({"name": "a", "direction": "callees", "depth": 3, "limit": 3}));
    assert!(t.contains("(tree, depth 3, 3 distinct)") && !t.contains("more row"), "{t}");
}

#[test]
fn each_direction_goes_as_deep_as_its_own_limit_allows() {
    let (_d, svc) = service();
    let r = wide();
    // root has 30 callees but no callers; mid0 has one caller (root) and ten callees.
    let t = ok(&svc, &r.root, "calls", json!({"name": "mid0", "depth": 3, "limit": 5, "token_budget": 100000}));
    assert!(t.contains("Callers (tree, depth 3,"), "the short side keeps its depth: {t}");
    assert!(t.contains("Callees (tree, depth 1 of 3; level 2 exceeds limit=5"), "{t}");
}

#[test]
fn deep_callers_are_a_tree_too() {
    let (_d, svc) = service();
    let r = diamond();
    let t = ok(&svc, &r.root, "calls", json!({"name": "d", "direction": "callers", "depth": 2}));
    let rows = section(&t, "Callers");
    let b = rows.iter().position(|l| l.trim_start().starts_with("- b ")).unwrap_or_else(|| panic!("{t}"));
    assert!(rows[b].contains(&format!("{}:L3", r.root.join("b.ts").display())), "a caller row names the call site: {t}");
    assert!(indent(rows[b + 1]) > indent(rows[b]) && rows[b + 1].trim_start().starts_with("- a "), "a calls b: {t}");
}

fn wide() -> Repo {
    let r = init_repo();
    let mut src = String::from("export function root() {\n");
    for i in 0..30 {
        src.push_str(&format!("  mid{i}();\n"));
    }
    src.push_str("}\n");
    for i in 0..30 {
        src.push_str(&format!("export function mid{i}(): void {{\n"));
        for j in 0..10 {
            src.push_str(&format!("  leaf{i}x{j}();\n"));
        }
        src.push_str("}\n");
        for j in 0..10 {
            src.push_str(&format!("export function leaf{i}x{j}(): void {{}}\n"));
        }
    }
    write(&r.root, "big.ts", &src);
    commit_all(&r.root, "init");
    r
}

#[test]
fn limit_fills_the_last_level_after_every_level_above_it() {
    let (_d, svc) = service();
    let r = wide();
    let t = ok(&svc, &r.root, "calls", json!({"name": "root", "direction": "callees", "depth": 2, "limit": 40, "token_budget": 100000}));
    assert!(t.contains("(tree, depth 2, 330 distinct)"), "{t}");
    assert!(t.contains("- mid29 "), "every function of level 1 is listed: {t}");
    assert_eq!(t.lines().filter(|l| l.trim_start().starts_with("- leaf")).count(), 10, "level 2 gets the 10 rows left of 40: {t}");
    assert!(t.contains("… 290 more row(s) at level 2; pass limit=330"), "{t}");
}

#[test]
fn a_limit_smaller_than_the_upper_levels_drops_the_last_level() {
    let (_d, svc) = service();
    let r = wide();
    let t = ok(&svc, &r.root, "calls", json!({"name": "root", "direction": "callees", "depth": 2, "limit": 20, "token_budget": 100000}));
    assert!(t.contains("depth 1 of 2; level 2 exceeds limit=20"), "{t}");
    assert!(!t.contains("leaf0x0") && t.contains("… 10 more row(s) at level 1"), "{t}");
}

#[test]
fn read_with_callers_lists_test_callers_last() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "t.ts", "export function target(): number {\n  return 1;\n}\n");
    write(&r.root, "p.ts", "import { target } from './t';\nexport function plain(): number {\n  return target();\n}\n");
    // checksT is used by three suites and sorts first by path, so it outranks `plain`: only its
    // being a test puts it last.
    write(
        &r.root,
        "a.test.ts",
        "import { target } from './t';\nexport function checksT() {\n  return target();\n}\nexport function s1() { checksT(); }\nexport function s2() { checksT(); }\nexport function s3() { checksT(); }\n",
    );
    commit_all(&r.root, "init");
    let t = ok(&svc, &r.root, "read", json!({"symbol_name": "target", "with": "callers"}));
    let at = |n: &str| t.find(&format!("// ← {n} ")).unwrap_or_else(|| panic!("{n} listed: {t}"));
    assert!(at("checksT") > at("plain"), "the test caller comes last: {t}");
}

#[test]
fn a_tree_too_big_for_the_budget_drops_whole_levels_instead_of_cutting_mid_tree() {
    let (_d, svc) = service();
    let r = wide();
    let t = ok(&svc, &r.root, "calls", json!({"name": "root", "direction": "callees", "depth": 2, "limit": 1000, "token_budget": 2000}));
    assert!(!t.contains("… truncated"), "levels are dropped, not cut: {t}");
    assert!(t.contains("depth 1 of 2; level 2 exceeds token_budget=2000"), "says it reduced the depth and why: {t}");
    assert!(t.contains("mid29") && !t.contains("leaf0x0"), "all of level 1, none of level 2: {t}");
}

#[test]
fn depth_one_keeps_the_flat_rows() {
    let (_d, svc) = service();
    let r = diamond();
    let t = ok(&svc, &r.root, "calls", json!({"name": "a", "direction": "callees"}));
    assert!(t.contains("[d1] b (function)"), "{t}");
}

#[test]
fn read_with_callers_appends_caller_signatures_and_call_site_lines() {
    let (_d, svc) = service();
    let r = diamond();
    let t = ok(&svc, &r.root, "read", json!({"symbol_name": "d", "with": ["callers"]}));
    assert!(t.contains("return z > 0"), "the body is still read: {t}");
    assert!(t.contains("// callers (2 of 2):"), "{t}");
    assert!(t.contains("function b(x: number): number") && t.contains("function c(y: number): number"), "caller signatures: {t}");
    assert!(t.contains(&format!("{}:L3", r.root.join("b.ts").display())), "b's call site: {t}");
    assert!(t.contains("return d(y) * 2;"), "the call-site line: {t}");
    assert!(!t.contains("return d(x);\n}"), "not the caller's body: {t}");
}

#[test]
fn read_with_an_unknown_attachment_is_refused() {
    let (_d, svc) = service();
    let r = diamond();
    let bad = call(&svc, &r.root, "read", json!({"symbol_name": "d", "with": "callees"}));
    assert!(!bad.ok && bad.state.as_deref() == Some(state::BAD_REQUEST), "{bad:?}");
    let plain = ok(&svc, &r.root, "read", json!({"symbol_name": "d"}));
    assert!(!plain.contains("callers"), "callers are opt-in: {plain}");
}
