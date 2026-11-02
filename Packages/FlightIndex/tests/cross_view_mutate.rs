//! Mutators applied across linked views (contract "Mutators and links"): a rename, move,
//! safe_delete or rename_file of something another view uses is written into that view too when
//! the agent names it in `views`, under both views' write gates, all files or none, and both views
//! are re-indexed before the answer. A view the agent did not name is never written.
//!
//! The fixture mirrors tests/links.rs: `app` (like `formula-editor`) lists `../lib/src` (like
//! `../tessera/designer/src`) as an Elm source directory.
mod common;
use common::*;
use flightindex::edit::{apply_change_sets, Change};
use flightindex::proto::{Request, Response, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

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

const NODE: &str = "module Expression.Node exposing (Node(..), toString, unused)\n\n\ntype Node\n    = Leaf Int\n    | Branch Node Node\n\n\ntoString : Node -> String\ntoString node =\n    case node of\n        Leaf n ->\n            String.fromInt n\n\n        Branch a b ->\n            toString a ++ toString b\n\n\nunused : Int\nunused =\n    0\n";
const UTIL: &str = "module Expression.Util exposing (render)\n\nimport Expression.Node as Node\n\n\nrender : Node.Node -> String\nrender n =\n    Node.toString n\n";
const MAIN: &str = "module Main exposing (main, view)\n\nimport Expression.Node as Node exposing (Node(..))\n\n\nview : Int -> String\nview n =\n    Node.toString (Leaf n)\n\n\nmain : String\nmain =\n    view 1\n";
const SPARE: &str = "module Spare exposing (zero)\n\nimport Expression.Node exposing (toString, unused)\n\n\nzero : Int\nzero =\n    unused\n";
const APP_ELM_JSON: &str = r#"{"type":"application","source-directories":["src","../lib/src"],"elm-version":"0.19.1"}"#;

struct World {
    _outer: tempfile::TempDir,
    outer: PathBuf,
    app: PathBuf,
    lib: PathBuf,
}

impl World {
    fn node(&self) -> PathBuf {
        self.lib.join("src/Expression/Node.elm")
    }
    fn read(&self, root: &Path, rel: &str) -> String {
        std::fs::read_to_string(root.join(rel)).unwrap()
    }
    fn clean(&self) {
        assert_eq!(git(&self.lib, &["status", "--porcelain"]), "", "lib must not change");
        assert_eq!(git(&self.app, &["status", "--porcelain"]), "", "app must not change");
    }
}

fn repo_at(parent: &Path, name: &str, files: &[(&str, &str)]) -> PathBuf {
    let root = parent.join(name);
    std::fs::create_dir_all(&root).unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    for (rel, text) in files {
        write(&root, rel, text);
    }
    commit_all(&root, "init");
    root
}

fn world_with(app_files: &[(&str, &str)]) -> World {
    let outer = tempfile::tempdir().unwrap();
    let parent = outer.path().canonicalize().unwrap();
    let lib = repo_at(&parent, "lib", &[("src/Expression/Node.elm", NODE), ("src/Expression/Util.elm", UTIL)]);
    let mut files = vec![("elm.json", APP_ELM_JSON), ("src/Main.elm", MAIN)];
    files.extend_from_slice(app_files);
    let app = repo_at(&parent, "app", &files);
    World { _outer: outer, outer: parent, app, lib }
}

fn world() -> World {
    world_with(&[])
}

// ---- rename -------------------------------------------------------------------------------------

#[test]
fn naming_the_dependent_view_renames_in_both_views_and_reindexes_both() {
    let (_d, svc) = service();
    let w = world();
    let text = ok(&svc, &w.app, "rename", json!({"symbol": "toString", "new_name": "asString", "file_path": w.node(), "views": [w.app], "apply": true}));
    assert!(text.contains("applied:"), "{text}");
    assert!(text.contains(&w.app.join("src/Main.elm").display().to_string()) && text.contains(&w.node().display().to_string()), "both views' files are listed: {text}");
    assert!(text.contains("2 view(s)"), "{text}");
    let node = w.read(&w.lib, "src/Expression/Node.elm");
    assert!(node.contains("exposing (Node(..), asString, unused)") && node.contains("asString : Node -> String") && !node.contains("toString"), "{node}");
    assert!(w.read(&w.lib, "src/Expression/Util.elm").contains("Node.asString n"));
    let main = w.read(&w.app, "src/Main.elm");
    assert!(main.contains("Node.asString (Leaf n)") && !main.contains("toString"), "{main}");
    // Both views were re-indexed before the answer: the next query sees the new name everywhere.
    let refs = ok(&svc, &w.app, "refs", json!({"symbol": "asString"}));
    assert!(refs.contains(&format!("{}", w.app.join("src/Main.elm").display())) && refs.contains("L8"), "{refs}");
    let r = call(&svc, &w.app, "refs", json!({"symbol": "toString"}));
    assert!(!r.ok || !r.text.clone().unwrap_or_default().contains("Main.elm"), "{r:?}");
}

#[test]
fn a_cross_view_preview_writes_nothing_and_diffs_both_views() {
    let (_d, svc) = service();
    let w = world();
    let text = ok(&svc, &w.app, "rename", json!({"symbol": "toString", "new_name": "asString", "file_path": w.node(), "views": [w.app]}));
    assert!(text.contains("preview:") && text.contains("nothing written"), "{text}");
    assert!(text.contains(&format!("+++ {}", w.app.join("src/Main.elm").display())), "{text}");
    assert!(text.contains(&format!("+++ {}", w.node().display())), "{text}");
    w.clean();
}

#[test]
fn a_dependent_view_that_uses_it_but_is_not_named_still_refuses_and_says_how_to_opt_in() {
    let (_d, svc) = service();
    let w = world();
    let msg = refused(&svc, &w.app, "rename", json!({"symbol": "toString", "new_name": "asString", "file_path": w.node(), "apply": true}));
    assert!(msg.contains("would break views that use it") && msg.contains(&format!("views=[\"{}\"]", w.app.display())), "{msg}");
    w.clean();
}

#[test]
fn a_named_view_that_does_not_link_into_the_target_is_refused() {
    let (_d, svc) = service();
    let w = world();
    let other = repo_at(&w.outer, "other", &[("src/Other.elm", "module Other exposing (x)\n\n\nx : Int\nx =\n    1\n")]);
    let msg = refused(&svc, &w.app, "rename", json!({"symbol": "toString", "new_name": "asString", "file_path": w.node(), "views": [w.app, other], "apply": true}));
    assert!(msg.contains("does not link into") && msg.contains(&other.display().to_string()), "{msg}");
    w.clean();
}

#[test]
fn a_rename_in_typescript_follows_a_climbing_import_into_the_named_view() {
    let (_d, svc) = service();
    let outer = tempfile::tempdir().unwrap();
    let parent = outer.path().canonicalize().unwrap();
    let shared = repo_at(&parent, "shared", &[("src/util.ts", "export function slug(s: string) { return s; }\n")]);
    let web = repo_at(
        &parent,
        "web",
        &[
            ("package.json", r#"{"name":"web","dependencies":{"shared":"file:../shared"}}"#),
            ("src/page.ts", "import { slug } from '../../shared/src/util';\nexport function title(s: string) { return slug(s); }\n"),
        ],
    );
    let text = ok(&svc, &web, "rename", json!({"symbol": "slug", "new_name": "toSlug", "file_path": shared.join("src/util.ts"), "views": [web], "apply": true}));
    assert!(text.contains("applied:"), "{text}");
    assert_eq!(std::fs::read_to_string(shared.join("src/util.ts")).unwrap(), "export function toSlug(s: string) { return s; }\n");
    assert_eq!(std::fs::read_to_string(web.join("src/page.ts")).unwrap(), "import { toSlug } from '../../shared/src/util';\nexport function title(s: string) { return toSlug(s); }\n");
}

// ---- move, rename_file, safe_delete -------------------------------------------------------------

#[test]
fn a_move_repoints_the_dependent_views_qualified_uses_and_imports() {
    let (_d, svc) = service();
    let w = world();
    let to = w.lib.join("src/Expression/Text.elm");
    let text = ok(&svc, &w.app, "move", json!({"symbol": "toString", "file_path": w.node(), "to_file": to, "views": [w.app], "apply": true}));
    assert!(text.contains("applied:"), "{text}");
    let moved = std::fs::read_to_string(&to).unwrap();
    assert!(moved.starts_with("module Expression.Text exposing (toString)") && moved.contains("toString node ="), "{moved}");
    let main = w.read(&w.app, "src/Main.elm");
    assert!(main.contains("import Expression.Text\n") && main.contains("Expression.Text.toString (Leaf n)"), "{main}");
}

#[test]
fn a_rename_file_rewrites_the_dependent_views_imports() {
    let (_d, svc) = service();
    let w = world();
    let to = w.lib.join("src/Expression/Tree.elm");
    let text = ok(&svc, &w.app, "rename_file", json!({"from": w.node(), "to": to, "views": [w.app], "apply": true}));
    assert!(text.contains("applied:"), "{text}");
    assert!(to.exists() && !w.node().exists());
    let main = w.read(&w.app, "src/Main.elm");
    assert!(main.contains("import Expression.Tree as Node exposing (Node(..))"), "{main}");
    // Re-indexed: the dependent view's import now resolves to the renamed file.
    let deps = ok(&svc, &w.app, "deps", json!({"file_path": "src/Main.elm"}));
    assert!(deps.contains(&to.display().to_string()), "{deps}");
}

#[test]
fn safe_delete_counts_the_named_views_uses_and_with_force_drops_them_from_its_imports() {
    let (_d, svc) = service();
    let w = world_with(&[("src/Spare.elm", SPARE)]);
    let msg = refused(&svc, &w.app, "safe_delete", json!({"symbol": "unused", "file_path": w.node(), "views": [w.app], "apply": true}));
    assert!(msg.contains("live reference") && msg.contains(&format!("{}:", w.app.join("src/Spare.elm").display())), "{msg}");
    w.clean();
    let text = ok(&svc, &w.app, "safe_delete", json!({"symbol": "unused", "file_path": w.node(), "views": [w.app], "force": true, "apply": true}));
    assert!(text.contains("applied:") && text.contains("will no longer resolve"), "{text}");
    let spare = w.read(&w.app, "src/Spare.elm");
    assert!(spare.contains("import Expression.Node exposing (toString)\n"), "{spare}");
    assert!(!w.read(&w.lib, "src/Expression/Node.elm").contains("unused"));
}

// ---- atomicity and locking -----------------------------------------------------------------------

#[test]
fn a_failed_write_in_the_dependent_view_rolls_back_the_target_view() {
    use std::os::unix::fs::PermissionsExt;
    let (_d, svc) = service();
    let w = world();
    let src = w.app.join("src");
    std::fs::set_permissions(&src, std::fs::Permissions::from_mode(0o555)).unwrap();
    let r = call(&svc, &w.app, "rename", json!({"symbol": "toString", "new_name": "asString", "file_path": w.node(), "views": [w.app], "apply": true}));
    std::fs::set_permissions(&src, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(!r.ok, "{:?}", r.text);
    assert!(r.error.as_deref().unwrap_or("").contains("Rolled back"), "{:?}", r.error);
    w.clean();
    // The view is still consistent: the same rename now goes through.
    ok(&svc, &w.app, "rename", json!({"symbol": "toString", "new_name": "asString", "file_path": w.node(), "views": [w.app], "apply": true}));
}

#[test]
fn change_sets_in_two_roots_are_written_together_or_not_at_all() {
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let (a, b) = (a.path().canonicalize().unwrap(), b.path().canonicalize().unwrap());
    std::fs::write(a.join("x.txt"), "old").unwrap();
    std::fs::write(b.join("blocker"), "a file, not a directory").unwrap();
    let ca = [Change { path: a.join("x.txt"), before: Some(b"old".to_vec()), after: Some(b"new".to_vec()), mode: None }];
    let cb = [Change { path: b.join("blocker/y.txt"), before: None, after: Some(b"y".to_vec()), mode: None }];
    let e = apply_change_sets(&[(a.as_path(), &ca[..]), (b.as_path(), &cb[..])]).unwrap_err();
    assert!(e.contains("Rolled back 2 file(s)"), "{e}");
    assert_eq!(std::fs::read_to_string(a.join("x.txt")).unwrap(), "old");
    // A change outside its own root is refused before anything is written.
    let stray = [Change { path: a.join("x.txt"), before: Some(b"old".to_vec()), after: Some(b"new".to_vec()), mode: None }];
    let e = apply_change_sets(&[(b.as_path(), &stray[..])]).unwrap_err();
    assert!(e.contains("outside the view's worktree"), "{e}");
    assert_eq!(std::fs::read_to_string(a.join("x.txt")).unwrap(), "old");
}

#[test]
fn concurrent_cross_view_mutations_and_queries_finish() {
    let (_d, svc) = service();
    let w = Arc::new(world());
    ok(&svc, &w.app, "refs", json!({"symbol": "Expression.Node.toString"}));
    let (tx, rx) = std::sync::mpsc::channel();
    let mut handles = Vec::new();
    for i in 0..4 {
        let (svc, w, tx) = (svc.clone(), w.clone(), tx.clone());
        handles.push(std::thread::spawn(move || {
            // Two writers that need both gates, and readers of each view.
            let r = match i {
                0 => call(&svc, &w.lib, "rename", json!({"symbol": "unused", "new_name": "spare", "file_path": w.node(), "views": [w.app]})),
                1 => call(&svc, &w.app, "rename", json!({"symbol": "toString", "new_name": "asString", "file_path": w.node(), "views": [w.app]})),
                2 => call(&svc, &w.app, "refs", json!({"symbol": "Expression.Node.toString"})),
                _ => call(&svc, &w.lib, "refs", json!({"symbol": "toString"})),
            };
            tx.send((i, r.ok)).unwrap();
        }));
    }
    drop(tx);
    for _ in 0..4 {
        let (i, okay) = rx.recv_timeout(Duration::from_secs(60)).expect("a request hung: gates taken in an order that deadlocks");
        assert!(okay, "request {i} failed");
    }
    for h in handles {
        h.join().unwrap();
    }
}

#[test]
fn a_forced_delete_warns_about_uses_left_in_a_named_view_it_had_nothing_to_rewrite_in() {
    let (_d, svc) = service();
    let w = world();
    // app uses `Node.toString` qualified: no import names it, so app has no edit, only a use left.
    let text = ok(&svc, &w.app, "safe_delete", json!({"symbol": "toString", "file_path": w.node(), "views": [w.app], "force": true, "apply": true}));
    assert!(text.contains(&format!("{}:L8", w.app.join("src/Main.elm").display())) && text.contains("will no longer resolve"), "{text}");
    assert!(text.contains("view updated:") && !text.contains(&format!("{} and", w.app.display())), "{text}");
}
