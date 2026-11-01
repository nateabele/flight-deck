//! The mutators, driven through the service the way a client calls them.
//!
//! The behaviours that make them worth having over a text editor: edits land only in the view
//! that answered the lookup, the next query sees them, a multi-file edit is all or nothing, and an
//! ambiguous or unsafe request is refused with what to do about it.
mod common;
use common::*;
use flightindex::proto::{Request, Response, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn service() -> (tempfile::TempDir, Arc<Service>) {
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    (dir, svc)
}

fn call(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> Response {
    svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() })
}

fn ok(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let r = call(svc, cwd, tool, args);
    assert!(r.ok, "{tool} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

fn refused(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> String {
    let r = call(svc, cwd, tool, args);
    assert!(!r.ok, "{tool} should have been refused: {:?}", r.text);
    r.error.unwrap()
}

fn read(root: &Path, rel: &str) -> String {
    std::fs::read_to_string(root.join(rel)).unwrap()
}

fn found(svc: &Arc<Service>, cwd: &Path, name: &str) -> usize {
    let t = ok(svc, cwd, "find", json!({"name": name}));
    if t.contains("No symbol found") { 0 } else { t.matches("File: ").count() }
}

// ---- Elm ----------------------------------------------------------------------------------------

const ELM_LIB: &str = "module Lib exposing (Kind(..), helper, other)\n\n\n{-| a doc that mentions helper -}\nhelper : Int -> Int\nhelper n =\n    n + 1\n\n\nother : Int\nother =\n    helper 2\n\n\ntype Kind\n    = Small\n    | Large\n";
const ELM_B: &str = "module B exposing (b)\n\nimport Lib exposing (helper)\n\n\nb : Int\nb =\n    helper 1 + String.length \"helper\"\n";
const ELM_C: &str = "module C exposing (c)\n\nimport Lib as L\n\n\nc : Int\nc =\n    L.helper 3\n";
const ELM_D: &str = "module D exposing (d)\n\nimport Lib\n\n\nd : Int\nd =\n    Lib.helper 4\n-- helper stays in comments\n";

fn elm_project() -> Repo {
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"],"elm-version":"0.19.1","dependencies":{"direct":{},"indirect":{}},"test-dependencies":{"direct":{},"indirect":{}}}"#);
    write(&r.root, "src/Lib.elm", ELM_LIB);
    write(&r.root, "src/B.elm", ELM_B);
    write(&r.root, "src/C.elm", ELM_C);
    write(&r.root, "src/D.elm", ELM_D);
    commit_all(&r.root, "init");
    r
}

#[test]
fn an_elm_rename_changes_the_definition_exposing_lists_qualified_uses_and_nothing_in_strings() {
    let (_d, svc) = service();
    let r = elm_project();
    let out = ok(&svc, &r.root, "rename", json!({"old_name": "helper", "new_name": "assist", "apply": true}));
    assert!(out.contains("applied: rename helper -> assist"), "{out}");
    let lib = read(&r.root, "src/Lib.elm");
    assert!(lib.contains("exposing (Kind(..), assist, other)"), "{lib}");
    assert!(lib.contains("assist : Int -> Int\nassist n =") && lib.contains("    assist 2"), "{lib}");
    assert!(lib.contains("a doc that mentions helper"), "a comment is not code: {lib}");
    assert!(read(&r.root, "src/B.elm").contains("import Lib exposing (assist)") && read(&r.root, "src/B.elm").contains("assist 1 + String.length \"helper\""));
    assert!(read(&r.root, "src/C.elm").contains("L.assist 3"));
    assert!(read(&r.root, "src/D.elm").contains("Lib.assist 4") && read(&r.root, "src/D.elm").contains("-- helper stays in comments"));
    // The next query sees it: the new name is found, the old one is gone.
    assert_eq!((found(&svc, &r.root, "assist"), found(&svc, &r.root, "helper")), (1, 0));
    let status = git(&r.root, &["status", "--porcelain"]);
    assert_eq!(status.lines().count(), 4, "exactly the four Elm files: {status}");
}

#[test]
fn a_preview_shows_a_diff_per_file_with_absolute_paths_and_writes_nothing() {
    let (_d, svc) = service();
    let r = elm_project();
    let out = ok(&svc, &r.root, "rename", json!({"old_name": "helper", "new_name": "assist"}));
    assert!(out.lines().next().unwrap().starts_with(&format!("view: {} (repo ", r.root.display())), "{out}");
    assert!(out.contains("nothing written, pass apply=true") && out.contains(&format!("--- {}", r.root.join("src/Lib.elm").display())), "{out}");
    assert!(out.contains("-    helper 1 + ") && out.contains("+    assist 1 + "), "{out}");
    assert_eq!(read(&r.root, "src/Lib.elm"), ELM_LIB);
    assert_eq!(git(&r.root, &["status", "--porcelain"]), "");
}

#[test]
fn a_rename_onto_an_existing_name_is_refused_unless_collisions_are_allowed() {
    let (_d, svc) = service();
    let r = elm_project();
    let e = refused(&svc, &r.root, "rename", json!({"old_name": "helper", "new_name": "other", "apply": true}));
    assert!(e.contains("would collide") && e.contains("allow_collision=true"), "{e}");
    assert_eq!(read(&r.root, "src/Lib.elm"), ELM_LIB, "nothing was written");
    ok(&svc, &r.root, "rename", json!({"old_name": "helper", "new_name": "other", "allow_collision": true}));
}

#[test]
fn an_elm_name_must_keep_its_case() {
    let (_d, svc) = service();
    let r = elm_project();
    let e = refused(&svc, &r.root, "rename", json!({"old_name": "helper", "new_name": "Assist"}));
    assert!(e.contains("lowercase"), "{e}");
}

#[test]
fn an_ambiguous_name_is_refused_with_every_candidate_and_its_kind() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/P.elm", "module P exposing (twin)\n\n\ntwin : Int\ntwin =\n    1\n");
    write(&r.root, "src/Q.elm", "module Q exposing (Twin(..))\n\n\ntype Twin\n    = Twin\n");
    commit_all(&r.root, "init");
    let e = refused(&svc, &r.root, "rename", json!({"old_name": "Twin", "new_name": "Pair"}));
    assert!(e.contains("matches 2 definitions") && e.contains(&format!("enum {}", r.root.join("src/Q.elm").display())) && e.contains(&format!("constructor {}", r.root.join("src/Q.elm").display())), "{e}");
    ok(&svc, &r.root, "rename", json!({"old_name": "Twin", "new_name": "Pair", "kind": "enum", "apply": true}));
    assert!(read(&r.root, "src/Q.elm").contains("type Pair\n    = Twin"), "{}", read(&r.root, "src/Q.elm"));
}

#[test]
fn replace_symbol_needs_a_definition_introducer_and_keeps_the_rest_of_the_file() {
    let (_d, svc) = service();
    let r = elm_project();
    let e = refused(&svc, &r.root, "replace_symbol", json!({"symbol": "other", "new_code": "1 + 1", "apply": true}));
    assert!(e.contains("definition introducer"), "{e}");
    ok(&svc, &r.root, "replace_symbol", json!({"symbol": "other", "new_code": "other : Int\nother =\n    42", "apply": true}));
    let lib = read(&r.root, "src/Lib.elm");
    assert!(lib.contains("other =\n    42\n\n\ntype Kind") && lib.contains("helper n =\n    n + 1"), "{lib}");
    assert_eq!(found(&svc, &r.root, "other"), 1);
}

#[test]
fn inserts_land_next_to_the_symbol_and_the_new_symbol_is_found_at_once() {
    let (_d, svc) = service();
    let r = elm_project();
    ok(&svc, &r.root, "insert_after_symbol", json!({"symbol": "helper", "new_code": "\n\nextra : Int\nextra =\n    7", "apply": true}));
    ok(&svc, &r.root, "insert_before_symbol", json!({"symbol": "other", "new_code": "before_other : Int\nbefore_other =\n    0\n\n", "apply": true}));
    let lib = read(&r.root, "src/Lib.elm");
    assert!(lib.contains("    n + 1\n\n\nextra : Int\nextra =\n    7\n\n\nbefore_other"), "{lib}");
    assert_eq!((found(&svc, &r.root, "extra"), found(&svc, &r.root, "before_other")), (1, 1));
}

#[test]
fn safe_delete_refuses_live_references_and_force_removes_the_export_too() {
    let (_d, svc) = service();
    let r = elm_project();
    let e = refused(&svc, &r.root, "safe_delete", json!({"symbol": "helper", "apply": true}));
    assert!(e.contains("live reference") && e.contains("B.elm") && e.contains("force=true"), "{e}");
    assert_eq!(read(&r.root, "src/Lib.elm"), ELM_LIB);
    ok(&svc, &r.root, "safe_delete", json!({"symbol": "Kind", "apply": true}));
    let lib = read(&r.root, "src/Lib.elm");
    assert!(!lib.contains("type Kind") && lib.contains("exposing (helper, other)"), "the module no longer exposes what it lost: {lib}");
    assert_eq!(found(&svc, &r.root, "Kind"), 0);
    let out = ok(&svc, &r.root, "safe_delete", json!({"symbol": "helper", "force": true, "apply": true}));
    assert!(out.contains("warning: deleted with force"), "{out}");
}

#[test]
fn an_elm_move_creates_the_module_and_follows_every_importer() {
    let (_d, svc) = service();
    let r = elm_project();
    let out = ok(&svc, &r.root, "move", json!({"symbol": "helper", "to_file": "src/Util/Math.elm", "apply": true}));
    assert!(out.contains("created") && out.contains("Util/Math.elm"), "{out}");
    let math = read(&r.root, "src/Util/Math.elm");
    assert!(math.starts_with("module Util.Math exposing (helper)\n"), "{math}");
    assert!(math.contains("helper : Int -> Int\nhelper n =\n    n + 1"), "{math}");
    let lib = read(&r.root, "src/Lib.elm");
    assert!(!lib.contains("helper n =") && lib.contains("exposing (Kind(..), other)") && lib.contains("import Util.Math exposing (helper)"), "Lib still uses it, so it imports it back: {lib}");
    let b = read(&r.root, "src/B.elm");
    assert!(b.contains("import Util.Math exposing (helper)") && !b.contains("import Lib exposing"), "{b}");
    let c = read(&r.root, "src/C.elm");
    assert!(c.contains("import Util.Math") && c.contains("Util.Math.helper 3"), "{c}");
    let d = read(&r.root, "src/D.elm");
    assert!(d.contains("Util.Math.helper 4") && d.contains("import Util.Math"), "{d}");
    let at = ok(&svc, &r.root, "find", json!({"name": "helper"}));
    assert!(at.contains(&format!("File: {}", r.root.join("src/Util/Math.elm").display())) && at.matches("File: ").count() == 1, "{at}");
}

#[test]
fn an_elm_move_exposes_the_neighbours_the_moved_code_reaches_back_for_and_keeps_the_gap() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/Lib.elm", "module Lib exposing (last, outer)\n\n\nouter : Int\nouter =\n    inner 1\n\n\ninner : Int -> Int\ninner n =\n    n\n\n\nlast : Int\nlast =\n    0\n");
    commit_all(&r.root, "init");
    ok(&svc, &r.root, "move", json!({"symbol": "outer", "to_file": "src/Out.elm", "apply": true}));
    let lib = read(&r.root, "src/Lib.elm");
    // Without the extra export, Out's `import Lib exposing (inner)` would not compile.
    assert!(lib.starts_with("module Lib exposing (last, inner)\n"), "{lib}");
    assert!(lib.contains("\n\n\ninner : Int -> Int") && !lib.contains("\n\n\n\n"), "the gap between declarations is kept: {lib:?}");
    assert!(read(&r.root, "src/Out.elm").contains("import Lib exposing (inner)"));
}

#[test]
fn an_elm_move_that_would_make_two_modules_import_each_other_is_refused() {
    let (_d, svc) = service();
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/Lib.elm", "module Lib exposing (a, b)\n\n\na : Int\na =\n    b\n\n\nb : Int\nb =\n    a2\n\n\na2 : Int\na2 =\n    a\n");
    commit_all(&r.root, "init");
    // `b` uses `a2`, which uses `a`: moving `a2` would need `Lib` for nothing, but moving `b` away
    // while `a` still calls it back creates the cycle.
    let e = refused(&svc, &r.root, "move", json!({"symbol": "b", "to_file": "src/Other.elm", "apply": true}));
    assert!(e.contains("import each other"), "{e}");
    assert!(!r.root.join("src/Other.elm").exists());
}

#[test]
fn an_elm_rename_file_rewrites_the_module_line_importers_and_qualified_uses() {
    let (_d, svc) = service();
    let r = elm_project();
    let out = ok(&svc, &r.root, "rename_file", json!({"from": "src/Lib.elm", "to": "src/Core/Lib.elm", "apply": true}));
    assert!(out.contains("deleted") && out.contains("created"), "{out}");
    assert!(!r.root.join("src/Lib.elm").exists());
    assert!(read(&r.root, "src/Core/Lib.elm").starts_with("module Core.Lib exposing (Kind(..), helper, other)"));
    assert!(read(&r.root, "src/B.elm").contains("import Core.Lib exposing (helper)"));
    assert!(read(&r.root, "src/C.elm").contains("import Core.Lib as L") && read(&r.root, "src/C.elm").contains("L.helper 3"), "an alias keeps its uses");
    let d = read(&r.root, "src/D.elm");
    assert!(d.contains("import Core.Lib") && d.contains("Core.Lib.helper 4"), "{d}");
    let at = ok(&svc, &r.root, "find", json!({"name": "Core.Lib.helper"}));
    assert!(at.contains("Found 1 match"), "{at}");
}

// ---- TypeScript ---------------------------------------------------------------------------------

fn ts_project() -> Repo {
    let r = init_repo();
    write(&r.root, "src/util.ts", "export function helper(n: number): number {\n  return n + 1;\n}\n\nexport const keep = 1;\n");
    write(&r.root, "src/a.ts", "import { helper, keep as k } from './util';\n\nexport function entry(): number {\n  const label = 'helper';\n  // helper in a comment\n  return helper(1) + k;\n}\n");
    write(&r.root, "src/lib/b.ts", "import * as u from '../util';\nimport {\n  helper as h,\n} from '../util';\n\nexport const b = u.helper(2) + h(3);\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn a_ts_rename_follows_named_imports_namespaces_and_aliases() {
    let (_d, svc) = service();
    let r = ts_project();
    ok(&svc, &r.root, "rename", json!({"old_name": "helper", "new_name": "assist", "apply": true}));
    assert!(read(&r.root, "src/util.ts").contains("export function assist(n: number)"));
    let a = read(&r.root, "src/a.ts");
    assert!(a.contains("import { assist, keep as k } from './util';") && a.contains("return assist(1) + k;") && a.contains("'helper'") && a.contains("// helper in a comment"), "{a}");
    let b = read(&r.root, "src/lib/b.ts");
    assert!(b.contains("assist as h,") && b.contains("u.assist(2) + h(3)"), "an alias keeps its uses: {b}");
    assert_eq!((found(&svc, &r.root, "assist"), found(&svc, &r.root, "helper")), (1, 0));
}

#[test]
fn a_ts_rename_file_rewrites_relative_specifiers_in_both_directions() {
    let (_d, svc) = service();
    let r = ts_project();
    ok(&svc, &r.root, "rename_file", json!({"from": "src/util.ts", "to": "src/core/tools.ts", "apply": true}));
    assert!(read(&r.root, "src/a.ts").contains("from './core/tools';"));
    let b = read(&r.root, "src/lib/b.ts");
    assert!(b.contains("from '../core/tools';") && !b.contains("'../util'"), "{b}");
    assert!(r.root.join("src/core/tools.ts").exists() && !r.root.join("src/util.ts").exists());
}

#[test]
fn a_ts_move_splits_the_import_and_exports_what_was_private() {
    let (_d, svc) = service();
    let r = ts_project();
    ok(&svc, &r.root, "move", json!({"symbol": "helper", "to_file": "src/math.ts", "apply": true}));
    let math = read(&r.root, "src/math.ts");
    assert!(math.contains("export function helper(n: number): number {"), "{math}");
    let a = read(&r.root, "src/a.ts");
    assert!(a.contains("import { keep as k } from './util';") && a.contains("import { helper } from './math';"), "{a}");
    let b = read(&r.root, "src/lib/b.ts");
    assert!(b.contains("from '../math';") || b.contains("import { helper } from '../math'"), "{b}");
    assert!(!read(&r.root, "src/util.ts").contains("function helper") && read(&r.root, "src/util.ts").contains("keep"));
    assert_eq!(found(&svc, &r.root, "helper"), 1);
}

// ---- Rust ---------------------------------------------------------------------------------------

fn rust_project() -> Repo {
    let r = init_repo();
    write(&r.root, "Cargo.toml", "[package]\nname = \"demo\"\nversion = \"0.1.0\"\nedition = \"2021\"\n");
    write(&r.root, "src/lib.rs", "pub mod store;\npub mod app;\n");
    write(&r.root, "src/store.rs", "pub fn open(path: &str) -> usize {\n    path.len()\n}\n\npub struct Store {\n    pub n: usize,\n}\n\nimpl Store {\n    pub fn new() -> Store {\n        Store { n: open(\"x\") }\n    }\n}\n");
    write(&r.root, "src/app.rs", "use crate::store::{open, Store};\n\npub fn run() -> usize {\n    let s = Store::new();\n    open(\"a\") + crate::store::open(\"b\") + s.n\n}\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn a_rust_rename_reaches_use_lists_qualified_paths_and_impl_headers() {
    let (_d, svc) = service();
    let r = rust_project();
    ok(&svc, &r.root, "rename", json!({"old_name": "open", "new_name": "open_store", "apply": true}));
    assert!(read(&r.root, "src/store.rs").contains("pub fn open_store(path") && read(&r.root, "src/store.rs").contains("n: open_store(\"x\")"));
    let app = read(&r.root, "src/app.rs");
    assert!(app.contains("use crate::store::{open_store, Store};") && app.contains("open_store(\"a\") + crate::store::open_store(\"b\")"), "{app}");
    ok(&svc, &r.root, "rename", json!({"old_name": "Store", "new_name": "Db", "apply": true}));
    let store = read(&r.root, "src/store.rs");
    assert!(store.contains("pub struct Db {") && store.contains("impl Db {") && store.contains("-> Db {") && store.contains("Db { n:"), "{store}");
    assert!(read(&r.root, "src/app.rs").contains("use crate::store::{open_store, Db};") && read(&r.root, "src/app.rs").contains("Db::new()"));
}

#[test]
fn a_rust_replace_symbol_and_insert_after_work_and_a_method_on_a_shared_line_is_replaced_by_columns() {
    let (_d, svc) = service();
    let r = rust_project();
    ok(&svc, &r.root, "replace_symbol", json!({"symbol": "open", "new_code": "pub fn open(path: &str) -> usize {\n    path.len() * 2\n}", "apply": true}));
    ok(&svc, &r.root, "insert_after_symbol", json!({"symbol": "open", "new_code": "\npub fn close() {}", "apply": true}));
    let s = read(&r.root, "src/store.rs");
    assert!(s.contains("path.len() * 2\n}\n\npub fn close() {}\n\npub struct Store"), "{s}");
    assert_eq!(found(&svc, &r.root, "close"), 1);

    write(&r.root, "src/one.rs", "impl Default for Thing { fn default() -> Self { Thing } }\npub struct Thing;\n");
    ok(&svc, &r.root, "replace_symbol", json!({"symbol": "default", "file_path": "src/one.rs", "new_code": "fn default() -> Self { Thing }  // changed", "apply": true}));
    let one = read(&r.root, "src/one.rs");
    assert!(one.starts_with("impl Default for Thing { fn default() -> Self { Thing }  // changed }") || one.starts_with("impl Default for Thing { fn default() -> Self { Thing }  // changed"), "the impl header survives: {one}");
    assert!(one.contains("impl Default for Thing"), "{one}");
}

#[test]
fn a_rust_rename_file_updates_the_mod_declaration_and_use_paths_and_refuses_mod_rs() {
    let (_d, svc) = service();
    let r = rust_project();
    write(&r.root, "src/sub/mod.rs", "pub fn x() {}\n");
    let e = refused(&svc, &r.root, "rename_file", json!({"from": "src/sub/mod.rs", "to": "src/sub/other.rs"}));
    assert!(e.contains("mod.rs"), "{e}");
    ok(&svc, &r.root, "rename_file", json!({"from": "src/store.rs", "to": "src/db.rs", "apply": true}));
    assert_eq!(read(&r.root, "src/lib.rs"), "pub mod db;\npub mod app;\n");
    let app = read(&r.root, "src/app.rs");
    assert!(app.contains("use crate::db::{open, Store};") && app.contains("crate::db::open(\"b\")"), "{app}");
    assert!(r.root.join("src/db.rs").exists() && !r.root.join("src/store.rs").exists());
}

#[test]
fn a_rust_move_to_a_new_module_registers_it_and_repoints_the_use() {
    let (_d, svc) = service();
    let r = rust_project();
    ok(&svc, &r.root, "move", json!({"symbol": "open", "to_file": "src/files.rs", "apply": true}));
    assert!(read(&r.root, "src/lib.rs").contains("mod files;"));
    assert!(read(&r.root, "src/files.rs").contains("pub fn open(path: &str) -> usize"));
    let app = read(&r.root, "src/app.rs");
    assert!(app.contains("use crate::store::{Store};") || app.contains("use crate::store::Store;"), "{app}");
    assert!(app.contains("use crate::files::open;") && app.contains("crate::files::open(\"b\")"), "{app}");
    let store = read(&r.root, "src/store.rs");
    assert!(store.contains("use crate::files::open;") && !store.contains("pub fn open"), "the impl still calls it: {store}");
}

// ---- where writes may land ----------------------------------------------------------------------

#[test]
fn a_mutation_from_a_worktree_changes_only_that_worktree_and_the_main_checkout_stays_clean() {
    let (d, svc) = service();
    let r = elm_project();
    let wt = d.path().canonicalize().unwrap().join("wt");
    git(&r.root, &["worktree", "add", "-q", "-b", "feature", wt.to_str().unwrap()]);
    let out = ok(&svc, &wt, "rename", json!({"old_name": "helper", "new_name": "assist", "apply": true}));
    assert!(out.lines().next().unwrap().starts_with(&format!("view: {} ", wt.display())), "{out}");
    assert!(out.contains(&format!("modified {}", wt.join("src/Lib.elm").display())), "{out}");
    assert_eq!(git(&r.root, &["status", "--porcelain"]), "", "the main checkout is untouched");
    assert_eq!(read(&r.root, "src/Lib.elm"), ELM_LIB);
    assert!(read(&wt, "src/Lib.elm").contains("assist"));
    // The main checkout still answers with the old name; the worktree with the new one.
    assert_eq!((found(&svc, &r.root, "helper"), found(&svc, &wt, "assist"), found(&svc, &wt, "helper")), (1, 1, 0));
}

#[test]
fn a_symbol_defined_only_in_another_checkout_is_refused_unless_a_path_inside_it_is_named() {
    let (d, svc) = service();
    let r = elm_project();
    let wt = d.path().canonicalize().unwrap().join("wt");
    git(&r.root, &["worktree", "add", "-q", "-b", "feature", wt.to_str().unwrap()]);
    // Only the main checkout has this file (untracked there, so the worktree never sees it).
    write(&r.root, "src/OnlyMain.elm", "module OnlyMain exposing (lonely)\n\n\nlonely : Int\nlonely =\n    1\n");
    ok(&svc, &r.root, "find", json!({"name": "lonely"}));
    let e = refused(&svc, &wt, "rename", json!({"old_name": "lonely", "new_name": "solo", "apply": true}));
    assert!(e.contains("no definition named 'lonely'") && e.contains("pass file_path inside it"), "{e}");
    assert!(read(&r.root, "src/OnlyMain.elm").contains("lonely"), "nothing was written anywhere");
    // Naming a path inside the main checkout is the explicit request, and the answer says where it lands.
    let out = ok(&svc, &wt, "rename", json!({"old_name": "lonely", "new_name": "solo", "file_path": r.root.join("src/OnlyMain.elm").to_str().unwrap(), "apply": true}));
    assert!(out.contains("this is not your worktree") && out.lines().next().unwrap().starts_with(&format!("view: {} ", r.root.display())), "{out}");
    assert!(read(&r.root, "src/OnlyMain.elm").contains("solo"));
}

#[test]
fn a_rename_never_writes_through_a_symlink_that_leaves_the_worktree() {
    let (d, svc) = service();
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/P.elm", "module P exposing (twin)\n\n\ntwin : Int\ntwin =\n    1\n");
    let outside = d.path().canonicalize().unwrap().join("outside.elm");
    std::fs::write(&outside, "module Out exposing (x)\n\n\nx =\n    1\n").unwrap();
    std::os::unix::fs::symlink(&outside, r.root.join("src/Link.elm")).unwrap();
    commit_all(&r.root, "init");
    let before = std::fs::read_to_string(&outside).unwrap();
    // The symlink is not part of the answer; whatever happens, the file outside is not written.
    let _ = call(&svc, &r.root, "rename", json!({"old_name": "twin", "new_name": "pair", "apply": true}));
    assert_eq!(std::fs::read_to_string(&outside).unwrap(), before);
}

#[test]
fn a_file_changed_after_the_index_parsed_it_is_refused_rather_than_spliced_into_shifted_lines() {
    use flightindex::engine::Engine;
    use flightindex::tools::args::Args;
    use flightindex::tools::mutate::{plan, MutCtx, STALE};
    let dir = tempfile::tempdir().unwrap();
    let engine = Engine::open(dir.path().join("store")).unwrap();
    let r = elm_project();
    let view = engine.view_for_path(&r.root).unwrap();
    engine.build(&view, &[], |_| {}).unwrap();
    let graph = engine.graph(&view).unwrap();
    // Someone adds three lines above `other` after the graph was made.
    write(&r.root, "src/Lib.elm", &ELM_LIB.replace("helper : Int", "-- a\n-- b\n-- c\nhelper : Int"));
    let args = Args::new(json!({"symbol": "other", "new_code": "other : Int\nother =\n    0"}).as_object().cloned().unwrap(), r.root.clone());
    let err = plan("replace_symbol", &MutCtx { graph: &graph, args: &args }).err().expect("must refuse");
    assert!(err.message.starts_with(STALE), "{}", err.message);
}

// ---- read your writes, and concurrency ----------------------------------------------------------

#[test]
fn twenty_renames_in_a_row_are_each_found_by_the_very_next_query() {
    let (_d, svc) = service();
    let r = elm_project();
    let mut name = "helper".to_string();
    let mut hits = 0;
    for i in 0..20 {
        let next = format!("helper{i}");
        ok(&svc, &r.root, "rename", json!({"old_name": name, "new_name": next, "apply": true}));
        if found(&svc, &r.root, &next) == 1 && found(&svc, &r.root, &name) == 0 {
            hits += 1;
        }
        name = next;
    }
    assert_eq!(hits, 20, "read-your-writes: the new name found and the old one gone, 20 of 20");
}

#[test]
fn readers_never_see_a_half_applied_rename_or_a_lock_error_while_renames_run() {
    let (_d, svc) = service();
    let r = elm_project();
    ok(&svc, &r.root, "find", json!({"name": "helper"}));
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let root: PathBuf = r.root.clone();
    let readers: Vec<_> = (0..4)
        .map(|_| {
            let (svc, stop, root) = (svc.clone(), stop.clone(), root.clone());
            std::thread::spawn(move || {
                let mut bad = Vec::new();
                while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                    // `refs` of whichever name exists lists the importers B, C and D, or the call fails.
                    for name in ["helper", "assist"] {
                        let t = call(&svc, &root, "refs", json!({"symbol": name}));
                        if !t.ok {
                            bad.push(format!("{name}: {:?}", t.error));
                            continue;
                        }
                        let text = t.text.unwrap();
                        if text.contains("Symbol:") {
                            let files = ["B.elm", "C.elm", "D.elm"].iter().filter(|f| text.contains(*f)).count();
                            if files != 3 {
                                bad.push(format!("half a rename for {name}: {text}"));
                            }
                        }
                    }
                }
                bad
            })
        })
        .collect();
    for i in 0..10 {
        let (a, b) = if i % 2 == 0 { ("helper", "assist") } else { ("assist", "helper") };
        ok(&svc, &r.root, "rename", json!({"old_name": a, "new_name": b, "apply": true}));
    }
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    let bad: Vec<String> = readers.into_iter().flat_map(|h| h.join().unwrap()).collect();
    assert!(bad.is_empty(), "{bad:#?}");
}
