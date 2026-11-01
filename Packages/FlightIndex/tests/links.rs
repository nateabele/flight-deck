//! Links between views (spec §5.3, requirement 14): a manifest that points outside its repository
//! makes the repository it lands in part of the query.
//!
//! The fixture mirrors the real case. `app` (like `formula-editor`) lists `../lib/src` (like
//! `../tessera/designer/src`) as an Elm source directory; both are repositories in one parent
//! directory. The literal path decides which checkout `../lib` is.
mod common;
use common::*;
use flightindex::links::{manifest_targets, strip_jsonc};
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

const NODE: &str = "module Expression.Node exposing (Node(..), toString, unused)\n\n\ntype Node\n    = Leaf Int\n    | Branch Node Node\n\n\ntoString : Node -> String\ntoString node =\n    case node of\n        Leaf n ->\n            String.fromInt n\n\n        Branch a b ->\n            toString a ++ toString b\n\n\nunused : Int\nunused =\n    0\n";
const UTIL: &str = "module Expression.Util exposing (render)\n\nimport Expression.Node as Node\n\n\nrender : Node.Node -> String\nrender n =\n    Node.toString n\n";
const MAIN: &str = "module Main exposing (main, view)\n\nimport Expression.Node as Node exposing (Node(..))\n\n\nview : Int -> String\nview n =\n    Node.toString (Leaf n)\n\n\nmain : String\nmain =\n    view 1\n";
const APP_ELM_JSON: &str = r#"{"type":"application","source-directories":["src","../lib/src"],"elm-version":"0.19.1"}"#;

struct World {
    /// Keeps the directory alive.
    _outer: tempfile::TempDir,
    outer: PathBuf,
    app: PathBuf,
    lib: PathBuf,
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

fn world() -> World {
    let outer = tempfile::tempdir().unwrap();
    let parent = outer.path().canonicalize().unwrap();
    let lib = repo_at(&parent, "lib", &[("src/Expression/Node.elm", NODE), ("src/Expression/Util.elm", UTIL)]);
    let app = repo_at(&parent, "app", &[("elm.json", APP_ELM_JSON), ("src/Main.elm", MAIN)]);
    World { _outer: outer, outer: parent, app, lib }
}

fn tag(root: &Path) -> String {
    format!("{} @ {}", root.file_name().unwrap().to_string_lossy(), root.display())
}

// ---- discovery ----------------------------------------------------------------------------------

#[test]
fn manifests_name_the_directories_they_point_at() {
    let paths = |kind: &str, text: &str| manifest_targets(kind, text).into_iter().map(|p| p.to_string_lossy().to_string()).collect::<Vec<_>>();
    assert_eq!(paths("elm.json", APP_ELM_JSON), ["src", "../lib/src"]);
    assert_eq!(paths("elm.json", r#"{"type":"package","name":"a/b"}"#), Vec::<String>::new());
    assert_eq!(
        paths("package.json", r#"{"dependencies":{"a":"file:../a","b":"link:../b","c":"^1.0.0","d":"file:./vendor/d.tgz"},"workspaces":["../shared/*","packages/*"]}"#),
        ["../a", "../b", "../shared", "packages"]
    );
    assert_eq!(paths("package.json", r#"{"workspaces":{"packages":["../w/pkgs/*"]}}"#), ["../w/pkgs"]);
    assert_eq!(paths("mix.exs", "defp deps do\n  [{:a, path: \"../a\"}, {:b, \"~> 1.0\"}, {:c, in_umbrella: true}]\nend\n"), ["../a"]);
    assert_eq!(
        paths("Cargo.toml", "[package]\nname = \"x\"\n[lib]\npath = \"src/lib.rs\"\n[dependencies]\na = { path = \"../a\" }\nb = \"1\"\n[dev-dependencies.c]\npath = \"../c\"\n"),
        ["../a", "../c"],
        "a [lib] path is not a dependency; a `path =` under a dependency table (inline or its own table) is"
    );
    assert_eq!(paths("Cargo.toml", "[dependencies.c]\npath = \"../c\"\n"), ["../c"]);
}

#[test]
fn tsconfig_paths_and_references_with_comments_and_trailing_commas() {
    let text = r#"{
      // where things live
      "compilerOptions": {
        "baseUrl": ".",
        "paths": { "@shared/*": ["../shared/src/*"], "@util": ["../util/index.ts"], },  /* trailing comma above */
        "note": "http://not-a-comment",
      },
      "references": [{ "path": "../core" }, ],
    }"#;
    let got: Vec<String> = manifest_targets("tsconfig.json", text).into_iter().map(|p| p.to_string_lossy().to_string()).collect();
    assert_eq!(got, ["./../shared/src", "./../util/index.ts", "../core"]);
    assert_eq!(strip_jsonc(r#"{"a": "x//y", /* c */ "b": [1, 2,], }"#), r#"{"a": "x//y",  "b": [1, 2] }"#);
}

// ---- reading across the link -----------------------------------------------------------------------

#[test]
fn a_qualified_find_resolves_through_the_link_and_labels_the_view() {
    let (_d, svc) = service();
    let w = world();
    let text = ok(&svc, &w.app, "find", json!({"name": "Expression.Node.toString"}));
    let lines: Vec<&str> = text.lines().collect();
    assert!(lines[0].starts_with(&format!("view: {} (repo app", w.app.display())), "{text}");
    assert!(lines.iter().any(|l| l.starts_with(&format!("linked view: {} (repo lib", w.lib.display())) && l.ends_with("via elm.json")), "the header names the linked view: {text}");
    assert!(text.contains(&format!("File: {}", w.lib.join("src/Expression/Node.elm").display())), "{text}");
    assert!(text.contains(&format!("View: {}", tag(&w.lib))), "the row says which checkout answered: {text}");
    assert!(text.contains("Found 1 match(es)"), "{text}");
}

#[test]
fn a_pathless_search_looks_in_the_callers_view_first_then_the_linked_ones() {
    let (_d, svc) = service();
    let w = world();
    // `view` exists in app; `render` and `toString` only in lib.
    let own = ok(&svc, &w.app, "find", json!({"name": "view"}));
    assert!(own.contains(&format!("File: {}", w.app.join("src/Main.elm").display())) && !own.contains("View: "), "{own}");
    let both = ok(&svc, &w.app, "grep", json!({"query": "render"}));
    assert!(both.contains(&w.lib.join("src/Expression/Util.elm").display().to_string()) && both.contains(&format!("[view: {}]", tag(&w.lib))), "{both}");
    // The other direction is not a search: lib does not link to app.
    let from_lib = ok(&svc, &w.lib, "find", json!({"name": "view"}));
    assert!(from_lib.contains("No symbol found"), "{from_lib}");
}

#[test]
fn refs_from_the_linking_repo_include_its_own_files_and_label_the_rest() {
    let (_d, svc) = service();
    let w = world();
    let text = ok(&svc, &w.app, "refs", json!({"symbol": "Expression.Node.toString"}));
    assert!(text.contains(&format!("Defined in: {}", w.lib.join("src/Expression/Node.elm").display())), "{text}");
    assert!(text.contains(&format!("[view: {}]", tag(&w.lib))), "{text}");
    // app's own file, unlabelled (the header's view), and lib's own users, labelled.
    let main_row = text.lines().find(|l| l.starts_with(&w.app.join("src/Main.elm").display().to_string())).unwrap_or_else(|| panic!("no Main.elm in {text}"));
    assert!(!main_row.contains("[view:"), "{main_row}");
    assert!(text.contains("L8 call in view"), "{text}");
    let util_row = text.lines().find(|l| l.starts_with(&w.lib.join("src/Expression/Util.elm").display().to_string())).expect("Util.elm");
    assert!(util_row.contains(&format!("[view: {}]", tag(&w.lib))), "{util_row}");
}

#[test]
fn a_constructor_exposed_through_a_linked_type_is_a_reference_to_it() {
    let (_d, svc) = service();
    let w = world();
    // `Leaf n` in app/src/Main.elm comes from `exposing (Node(..))` of a module in another repo.
    let text = ok(&svc, &w.app, "refs", json!({"symbol": "Leaf", "kind": "constructor"}));
    assert!(text.contains(&w.app.join("src/Main.elm").display().to_string()), "{text}");
}

#[test]
fn deps_and_impact_of_a_linked_file_show_the_importers_that_stand_in_the_callers_repo() {
    let (_d, svc) = service();
    let w = world();
    let node = w.lib.join("src/Expression/Node.elm");
    // Named from app: the file is lib's, and app's importer is the point.
    let deps = ok(&svc, &w.app, "deps", json!({"file_path": node}));
    assert!(deps.lines().next().unwrap().starts_with(&format!("view: {} (repo lib", w.lib.display())), "{deps}");
    assert!(deps.contains(&format!("<- {} (view: {}, import: Expression.Node)", w.app.join("src/Main.elm").display(), tag(&w.app))), "{deps}");
    assert!(deps.contains(&format!("<- {} (import: Expression.Node)", w.lib.join("src/Expression/Util.elm").display())), "{deps}");
    let impact = ok(&svc, &w.app, "impact", json!({"file_path": node}));
    assert!(impact.contains(&format!("{}  [view: {}]", w.app.join("src/Main.elm").display(), tag(&w.app))), "{impact}");
    assert!(impact.contains("Direct importers (2):"), "{impact}");
    // And the way in: app's file imports a file that is in lib.
    let out = ok(&svc, &w.app, "deps", json!({"file_path": "src/Main.elm"}));
    assert!(out.contains(&format!("-> {node} (view: {}, import: Expression.Node)", tag(&w.lib), node = node.display())), "{out}");
}

#[test]
fn a_long_list_in_one_view_does_not_push_the_other_views_rows_out() {
    let (_d, svc) = service();
    let w = world();
    for i in 0..60 {
        write(&w.lib, &format!("src/Many/M{i:02}.elm"), &format!("module Many.M{i:02} exposing (v)\n\nimport Expression.Node as Node\n\n\nv : Int\nv =\n    {i}\n"));
    }
    commit_all(&w.lib, "many importers");
    let node = w.lib.join("src/Expression/Node.elm");
    let deps = ok(&svc, &w.app, "deps", json!({"file_path": node, "format": "concise", "token_budget": 20000}));
    assert!(deps.contains("Imported by (62):") && deps.contains("more importer(s)"), "{deps}");
    assert!(deps.contains(&format!("<- {}  [view: {}]", w.app.join("src/Main.elm").display(), tag(&w.app))), "{deps}");
    let impact = ok(&svc, &w.app, "impact", json!({"file_path": node, "token_budget": 20000}));
    assert!(impact.contains("Direct importers (62):") && impact.contains(&format!("{}  [view: {}]", w.app.join("src/Main.elm").display(), tag(&w.app))), "{impact}");
}

#[test]
fn calls_cross_the_link_both_ways() {
    let (_d, svc) = service();
    let w = world();
    let callers = ok(&svc, &w.app, "calls", json!({"name": "Expression.Node.toString", "direction": "callers"}));
    assert!(callers.contains("view (function)") && callers.contains(&w.app.join("src/Main.elm").display().to_string()), "app's `view` calls it: {callers}");
    assert!(callers.contains("render (function)") && callers.contains(&format!("[view: {}]", tag(&w.lib))), "lib's `render` too, labelled: {callers}");
    let callees = ok(&svc, &w.app, "calls", json!({"name": "view", "direction": "callees"}));
    assert!(callees.contains("toString (function)"), "{callees}");
    assert!(callees.contains(&format!("defined in {}  [view: {}]", w.lib.join("src/Expression/Node.elm").display(), tag(&w.lib))), "{callees}");
}

#[test]
fn a_dependent_view_that_was_seen_before_answers_for_the_view_it_links_into() {
    let (_d, svc) = service();
    let w = world();
    ok(&svc, &w.app, "find", json!({"name": "view"})); // records app's links and indexes it
    ok(&svc, &w.lib, "find", json!({"name": "toString"})); // indexes lib
    // Asked from lib itself, nothing says app matters, but app's manifests point at lib.
    let impact = ok(&svc, &w.lib, "impact", json!({"file_path": "src/Expression/Node.elm"}));
    assert!(impact.contains(&format!("dependent view: {} (repo app", w.app.display())), "{impact}");
    assert!(impact.contains(&w.app.join("src/Main.elm").display().to_string()), "{impact}");
}

// ---- building, memory, literal paths ---------------------------------------------------------------

#[test]
fn the_first_query_builds_the_linked_view_without_registration() {
    let (_d, svc) = service();
    let w = world();
    assert_eq!(svc.engine.parse_count(), 0);
    let text = ok(&svc, &w.app, "find", json!({"name": "toString"}));
    assert!(text.contains(&w.lib.join("src/Expression/Node.elm").display().to_string()), "{text}");
    assert!(svc.engine.parse_count() >= 3, "app's Main.elm and lib's two files were parsed: {}", svc.engine.parse_count());
}

#[test]
fn linked_views_share_the_graph_cache_and_nothing_is_loaded_twice() {
    let (_d, svc) = service();
    let w = world();
    ok(&svc, &w.app, "refs", json!({"symbol": "toString"}));
    let (parses, graphs) = (svc.engine.parse_count(), svc.engine.graph_cache_stats().graphs);
    assert_eq!(graphs, 2, "one graph per view, held by the one cache");
    // The same views asked for again, and lib asked for directly: no parse, no third graph.
    ok(&svc, &w.app, "refs", json!({"symbol": "toString"}));
    ok(&svc, &w.lib, "outline", json!({"file_path": "src/Expression/Node.elm"}));
    ok(&svc, &w.lib, "find", json!({"name": "toString"}));
    assert_eq!((svc.engine.parse_count(), svc.engine.graph_cache_stats().graphs), (parses, 2));
}

#[test]
fn a_link_is_the_literal_path_not_a_worktree_of_the_target() {
    let (_d, svc) = service();
    let w = world();
    // A worktree of lib that has a different `toString` than the checkout at ../lib.
    git(&w.lib, &["worktree", "add", "-q", "-b", "other", w.outer.join("lib-other").to_str().unwrap()]);
    write(&w.outer.join("lib-other"), "src/Expression/Node.elm", &NODE.replace("toString", "render2"));
    let text = ok(&svc, &w.app, "find", json!({"name": "toString"}));
    assert!(text.contains(&w.lib.display().to_string()) && !text.contains("lib-other"), "{text}");
}

#[test]
fn a_clean_worktree_of_a_linking_repo_resolves_the_link_from_where_it_stands() {
    let (_d, svc) = service();
    let w = world();
    // Same commit, so the two share one resolved graph; `../lib` means a different directory (here,
    // none) from `nested/app2`, so the cached graph must not carry app's resolution into it.
    let nested = w.outer.join("nested");
    std::fs::create_dir_all(&nested).unwrap();
    git(&w.app, &["worktree", "add", "-q", "-b", "wt", nested.join("app2").to_str().unwrap()]);
    let first = ok(&svc, &w.app, "deps", json!({"file_path": "src/Main.elm"}));
    assert!(first.contains(&w.lib.join("src/Expression/Node.elm").display().to_string()), "{first}");
    let app2 = nested.join("app2");
    let second = ok(&svc, &app2, "deps", json!({"file_path": "src/Main.elm"}));
    assert!(!second.contains("Expression/Node.elm") && !second.contains("linked view"), "app2 has no ../lib: {second}");
}

#[test]
fn a_graph_built_where_the_link_was_missing_is_redone_where_it_exists() {
    let (_d, svc) = service();
    let w = world();
    let nested = w.outer.join("nested");
    std::fs::create_dir_all(&nested).unwrap();
    git(&w.app, &["worktree", "add", "-q", "-b", "wt", nested.join("app2").to_str().unwrap()]);
    git(&w.app, &["worktree", "add", "-q", "-b", "wt3", w.outer.join("app3").to_str().unwrap()]);
    // The shared graph of this commit is first resolved from `nested/app2`, where `../lib` is nothing.
    let first = ok(&svc, &nested.join("app2"), "deps", json!({"file_path": "src/Main.elm"}));
    assert!(!first.contains("Expression/Node.elm"), "{first}");
    let second = ok(&svc, &w.outer.join("app3"), "deps", json!({"file_path": "src/Main.elm"}));
    assert!(second.contains(&format!("-> {} (view: {}, import: Expression.Node)", w.lib.join("src/Expression/Node.elm").display(), tag(&w.lib))), "{second}");
}

#[test]
fn links_are_read_again_when_a_manifest_changes() {
    let (_d, svc) = service();
    let w = world();
    assert!(ok(&svc, &w.app, "find", json!({"name": "toString"})).contains("Found 1 match(es)"));
    write(&w.app, "elm.json", r#"{"type":"application","source-directories":["src"],"elm-version":"0.19.1"}"#);
    let after = ok(&svc, &w.app, "find", json!({"name": "toString"}));
    assert!(after.contains("No symbol found") && !after.contains("linked view"), "{after}");
    write(&w.app, "elm.json", APP_ELM_JSON);
    assert!(ok(&svc, &w.app, "find", json!({"name": "toString"})).contains("Found 1 match(es)"));
}

#[test]
fn a_package_json_link_and_a_climbing_import_resolve_into_the_linked_view() {
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
    let refs = ok(&svc, &web, "refs", json!({"symbol": "slug"}));
    assert!(refs.contains(&format!("Defined in: {}", shared.join("src/util.ts").display())), "{refs}");
    assert!(refs.contains(&web.join("src/page.ts").display().to_string()), "{refs}");
    let deps = ok(&svc, &web, "deps", json!({"file_path": "src/page.ts"}));
    assert!(deps.contains(&format!("-> {} (view: {}, import: ../../shared/src/util)", shared.join("src/util.ts").display(), tag(&shared))), "{deps}");
}

// ---- mutators --------------------------------------------------------------------------------------

fn lib_is_untouched(w: &World) {
    assert_eq!(git(&w.lib, &["status", "--porcelain"]), "", "lib must not change");
    assert_eq!(git(&w.app, &["status", "--porcelain"]), "", "app must not change");
}

#[test]
fn a_rename_from_the_linking_repo_does_not_write_into_the_linked_view() {
    let (_d, svc) = service();
    let w = world();
    // No path: the lookup is app's own view, which has no `toString`.
    for apply in [false, true] {
        let msg = refused(&svc, &w.app, "rename", json!({"symbol": "toString", "new_name": "asString", "apply": apply}));
        assert!(msg.contains("is not defined in your view") && msg.contains("never writes into a linked view unless you name a path inside it"), "{msg}");
        assert!(msg.contains(&w.lib.join("src/Expression/Node.elm").display().to_string()) && msg.contains("nothing was changed"), "{msg}");
    }
    lib_is_untouched(&w);
}

#[test]
fn naming_a_path_in_the_linked_view_still_refuses_a_rename_that_would_break_the_caller() {
    let (_d, svc) = service();
    let w = world();
    let node = w.lib.join("src/Expression/Node.elm");
    for apply in [false, true] {
        let msg = refused(&svc, &w.app, "rename", json!({"symbol": "toString", "new_name": "asString", "file_path": node, "apply": apply}));
        assert!(msg.contains("would break views that use it; nothing was changed"), "{msg}");
        // The sites in both views.
        assert!(msg.contains(&format!("in this view ({})", tag(&w.lib))) && msg.contains(&node.display().to_string()), "{msg}");
        assert!(msg.contains(&format!("in {} it is used at", tag(&w.app))) && msg.contains(&format!("{}:8", w.app.join("src/Main.elm").display())), "{msg}");
    }
    lib_is_untouched(&w);
    // Deleting it or moving the file is the same break.
    let msg = refused(&svc, &w.app, "safe_delete", json!({"symbol": "toString", "file_path": node, "force": true, "apply": true}));
    assert!(msg.contains("would break views that use it"), "{msg}");
    let msg = refused(&svc, &w.app, "rename_file", json!({"from": node, "to": w.lib.join("src/Expression/Tree.elm"), "apply": true}));
    assert!(msg.contains("would break views that use it") && msg.contains(&w.app.join("src/Main.elm").display().to_string()), "{msg}");
    lib_is_untouched(&w);
}

#[test]
fn a_rename_nothing_outside_uses_goes_ahead_in_the_view_the_path_names() {
    let (_d, svc) = service();
    let w = world();
    let node = w.lib.join("src/Expression/Node.elm");
    // `unused` is exposed but no other view imports it by name: the import in app is
    // `exposing (Node(..))` and `Node.unused` is never written.
    let text = ok(&svc, &w.app, "rename", json!({"symbol": "unused", "new_name": "spare", "file_path": node, "apply": true}));
    assert!(text.contains("applied:") && text.contains("not your worktree"), "{text}");
    assert!(std::fs::read_to_string(&node).unwrap().contains("spare"));
    assert_eq!(git(&w.app, &["status", "--porcelain"]), "", "the caller's checkout was not written");
}
