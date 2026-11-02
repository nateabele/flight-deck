//! `impact pending=true`: the unedited call sites of every signature the worktree's diff changed.
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

fn pending(svc: &Arc<Service>, root: &Path) -> String {
    ok(svc, root, "impact", json!({"pending": true}))
}

const TS_B: &str = "export function helper(a: number) {\n  return a;\n}\n";
const TS_A: &str = "import { helper } from './b';\nexport function one() {\n  return helper(1);\n}\nexport function two() {\n  return helper(2);\n}\n";
const TS_C: &str = "import { helper } from './b';\nexport const three = () => helper(3);\n";

fn ts_repo() -> Repo {
    let r = init_repo();
    write(&r.root, "b.ts", TS_B);
    write(&r.root, "a.ts", TS_A);
    write(&r.root, "c.ts", TS_C);
    commit_all(&r.root, "init");
    r
}

#[test]
fn an_added_parameter_lists_the_call_sites_the_diff_has_not_edited() {
    let (_d, svc) = service();
    let r = ts_repo();
    pending(&svc, &r.root); // index the clean tree first
    write(&r.root, "b.ts", "export function helper(a: number, b: number) {\n  return a + b;\n}\n");
    write(&r.root, "a.ts", &TS_A.replace("helper(1)", "helper(1, 0)"));
    let t = pending(&svc, &r.root);
    assert!(t.contains("Changed: helper (function)") && t.contains("was: function helper(a: number)") && t.contains("now: function helper(a: number, b: number)"), "{t}");
    assert!(t.contains(&format!("{}:L6 call in two: `return helper(2);`", r.root.join("a.ts").display())), "unedited call in a.ts: {t}");
    assert!(t.contains(&format!("{}:L2 call in three", r.root.join("c.ts").display())), "unedited call in c.ts: {t}");
    assert!(!t.contains(":L3 call in one"), "the edited call site is not pending: {t}");
    assert!(t.contains("Not yet edited (2; 1 already edited)"), "{t}");
}

#[test]
fn a_renamed_parameter_owes_callers_nothing() {
    let (_d, svc) = service();
    let r = ts_repo();
    pending(&svc, &r.root);
    write(&r.root, "b.ts", "export function helper(n: number) {\n  return n;\n}\n");
    let t = pending(&svc, &r.root);
    assert!(t.contains("no signature changed in the diff (1 file(s) differ from the base)"), "{t}");
}

#[test]
fn a_clean_worktree_has_nothing_pending_and_impact_without_pending_still_needs_a_file() {
    let (_d, svc) = service();
    let r = ts_repo();
    let t = pending(&svc, &r.root);
    assert!(t.contains("Pending edits: none"), "{t}");
    let req = Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: r.root.to_string_lossy().to_string(), seq: 0, tool: "impact".into(), args: Default::default() };
    assert!(!svc.handle(req).ok, "impact without pending still requires file_path");
}

#[test]
fn a_renamed_function_lists_the_callers_still_using_the_old_name() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "lib.rs", "mod util;\npub fn run() {\n    util::old_name(1);\n}\npub fn again() {\n    util::old_name(2);\n}\n");
    write(&r.root, "util.rs", "pub fn old_name(n: u8) -> u8 {\n    n\n}\n");
    commit_all(&r.root, "init");
    pending(&svc, &r.root);
    write(&r.root, "util.rs", "pub fn new_name(n: u8) -> u8 {\n    n\n}\n");
    write(&r.root, "lib.rs", "mod util;\npub fn run() {\n    util::new_name(1);\n}\npub fn again() {\n    util::old_name(2);\n}\n");
    let t = pending(&svc, &r.root);
    assert!(t.contains("Removed or renamed: old_name (function)"), "{t}");
    assert!(t.contains(&format!("{}:L6 call in again", r.root.join("lib.rs").display())), "{t}");
    assert!(!t.contains(":L3 call in run"), "the renamed call is edited: {t}");
}

#[test]
fn an_elm_annotation_that_gains_an_argument_is_a_change_and_a_renamed_argument_is_not() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/B.elm", "module B exposing (b)\n\nb : Int -> Int\nb x =\n    x\n");
    write(&r.root, "src/A.elm", "module A exposing (a)\n\nimport B\n\na : Int\na =\n    B.b 1\n");
    commit_all(&r.root, "init");
    pending(&svc, &r.root);
    write(&r.root, "src/B.elm", "module B exposing (b)\n\nb : Int -> Int\nb y =\n    y\n");
    let t = pending(&svc, &r.root);
    assert!(t.contains("no signature changed"), "renaming x to y changes no caller: {t}");
    write(&r.root, "src/B.elm", "module B exposing (b)\n\nb : Int -> Int -> Int\nb x y =\n    x + y\n");
    let t = pending(&svc, &r.root);
    assert!(t.contains("Changed: b (function)") && t.contains(&format!("{}:L7 call in a", r.root.join("src/A.elm").display())), "{t}");
}

#[test]
fn an_elixir_arity_change_lists_remote_calls() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "lib/scopes.ex", "defmodule App.Scopes do\n  def values_for(state, conn) do\n    {state, conn}\n  end\nend\n");
    write(&r.root, "lib/user.ex", "defmodule App.User do\n  alias App.Scopes\n\n  def go(s, c) do\n    Scopes.values_for(s, c)\n  end\nend\n");
    commit_all(&r.root, "init");
    pending(&svc, &r.root);
    write(&r.root, "lib/scopes.ex", "defmodule App.Scopes do\n  def values_for(state, conn, opts) do\n    {state, conn, opts}\n  end\nend\n");
    let t = pending(&svc, &r.root);
    assert!(t.contains("Changed: values_for"), "{t}");
    assert!(t.contains(&format!("{}:L5 call in go", r.root.join("lib/user.ex").display())), "{t}");
}

#[test]
fn a_changed_trait_method_lists_its_unedited_implementers() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "lib.rs", "mod imp;\npub trait Shape {\n    fn area(&self) -> f64;\n}\n");
    write(&r.root, "imp.rs", "use crate::Shape;\npub struct Sq;\nimpl Shape for Sq {\n    fn area(&self) -> f64 {\n        1.0\n    }\n}\n");
    commit_all(&r.root, "init");
    pending(&svc, &r.root);
    write(&r.root, "lib.rs", "mod imp;\npub trait Shape {\n    fn area(&self, scale: f64) -> f64;\n}\n");
    let t = pending(&svc, &r.root);
    assert!(t.contains("Changed: area (method)"), "{t}");
    assert!(t.contains(&format!("{}:L4 implementer in", r.root.join("imp.rs").display())), "{t}");
}

#[test]
fn editing_one_of_two_adjacent_calls_leaves_the_other_pending() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "b.ts", TS_B);
    write(&r.root, "a.ts", "import { helper } from './b';\nexport function both() {\n  helper(1);\n  helper(2);\n}\n");
    commit_all(&r.root, "init");
    pending(&svc, &r.root);
    write(&r.root, "b.ts", "export function helper(a: number, b: number) {\n  return a + b;\n}\n");
    write(&r.root, "a.ts", "import { helper } from './b';\nexport function both() {\n  helper(1);\n  helper(2, 0);\n}\n");
    let t = pending(&svc, &r.root);
    assert!(t.contains(&format!("{}:L3 call in both", r.root.join("a.ts").display())), "line 3 is untouched, line 4 is the next call: {t}");
    assert!(!t.contains(":L4 call"), "{t}");
}

#[test]
fn a_call_the_parser_cannot_see_is_found_by_text_in_the_files_that_import_the_symbol() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "b.ts", TS_B);
    // A call inside a template substitution and one in a comment: only the first is owed an edit.
    write(&r.root, "a.ts", "import { helper } from './b';\nexport function msg() {\n  return `n=${helper(1)}`;\n}\n// helper(9) is documented here\nit('helper(2) in a test name', () => {});\n");
    // A macro argument the parser reads, and a `macro_rules!` body it does not (a template that
    // only becomes code where the macro is used): the text scan finds the second.
    write(&r.root, "lib.rs", "mod util;\npub fn check() {\n    assert!(util::twice(1) > 0);\n}\nmacro_rules! again {\n    () => { util::twice(3) };\n}\n");
    write(&r.root, "util.rs", "pub fn twice(n: u8) -> u8 {\n    n * 2\n}\n");
    commit_all(&r.root, "init");
    pending(&svc, &r.root);
    write(&r.root, "b.ts", "export function helper(a: number, b: number) {\n  return a + b;\n}\n");
    write(&r.root, "util.rs", "pub fn twice(n: u8, m: u8) -> u8 {\n    n * m\n}\n");
    let t = pending(&svc, &r.root);
    let row = |file: &str, line: u32| t.lines().find(|l| l.contains(&format!("{}:L{line} ", r.root.join(file).display()))).unwrap_or_else(|| panic!("no row for {file}:L{line}: {t}"));
    assert!(row("a.ts", 3).contains("call in msg") && !row("a.ts", 3).contains("matched"), "a template substitution is a parsed reference: {t}");
    assert!(row("lib.rs", 3).contains("call in check") && !row("lib.rs", 3).contains("matched"), "a macro argument is a parsed reference: {t}");
    assert!(row("lib.rs", 6).contains("(matched by text)"), "a macro_rules body is found by text: {t}");
    let a = r.root.join("a.ts").display().to_string();
    assert!(!t.contains(&format!("{a}:L5 ")), "a comment is not a call site: {t}");
    assert!(!t.contains(&format!("{a}:L6 ")), "nor is a string: {t}");
}

#[test]
fn a_file_with_its_own_function_of_that_name_is_not_scanned_by_text() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "lib.rs", "mod ev;\nmod join;\n");
    write(&r.root, "ev.rs", "pub fn eval(n: u8) -> u8 {\n    n\n}\n");
    // `join.rs` wraps `ev::eval` in a local `eval`: its own calls are to the wrapper.
    write(&r.root, "join.rs", "use crate::ev;\nfn eval(n: u8) -> u8 {\n    ev::eval(n)\n}\npub fn go() {\n    assert!(eval(1) > 0);\n}\n");
    commit_all(&r.root, "init");
    pending(&svc, &r.root);
    write(&r.root, "ev.rs", "pub fn eval(n: u8, m: u8) -> u8 {\n    n + m\n}\n");
    let t = pending(&svc, &r.root);
    assert!(t.contains(&format!("{}:L3 call in eval", r.root.join("join.rs").display())), "the wrapper's call is owed: {t}");
    assert!(!t.contains(":L6 call"), "the call to the local wrapper is not: {t}");
}

#[test]
fn a_long_list_is_capped_and_limit_raises_the_cap() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "b.ts", TS_B);
    let calls: String = (0..40).map(|i| format!("  helper({i});\n")).collect();
    write(&r.root, "a.ts", &format!("import {{ helper }} from './b';\nexport function many() {{\n{calls}}}\n"));
    commit_all(&r.root, "init");
    pending(&svc, &r.root);
    write(&r.root, "b.ts", "export function helper(a: number, b: number) {\n  return a + b;\n}\n");
    let t = pending(&svc, &r.root);
    assert!(t.contains("… 10 more (pass limit=40 to see all"), "{t}");
    let t = ok(&svc, &r.root, "impact", json!({"pending": true, "limit": 100, "token_budget": 100000}));
    assert!(t.contains(":L42 call in many") && !t.contains("more (pass limit"), "{t}");
}
