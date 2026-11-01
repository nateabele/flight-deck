mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::facts::*;
use flightindex::graph::{Confidence, ViewGraph};
use flightindex::query::{Direction, NameMatch};
use std::path::Path;
use std::sync::Arc;

fn graph_of(repo: &Repo) -> (tempfile::TempDir, Engine, Arc<ViewGraph>) {
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(&repo.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let g = e.graph(&v).unwrap();
    (dir, e, g)
}

fn exact(g: &ViewGraph, name: &str) -> flightindex::graph::SymId {
    let hits = g.find_symbols(&NameMatch::Exact(name.into()), None, 10).data;
    assert!(!hits.is_empty(), "no symbol {name}");
    hits[0].id
}

fn rel(root: &Path, p: &Path) -> String {
    p.strip_prefix(root).unwrap_or(p).to_string_lossy().to_string()
}

fn elm_fixture(outside: Option<&Path>) -> Repo {
    let r = init_repo();
    let dirs = match outside {
        Some(o) => format!(r#"["src", "{}"]"#, o.display()),
        None => r#"["src"]"#.into(),
    };
    write(&r.root, "elm.json", &format!(r#"{{"type":"application","source-directories":{dirs}}}"#));
    write(
        &r.root,
        "src/Expression/Node.elm",
        "module Expression.Node exposing (Node(..), toString)\n\ntype Node\n    = Leaf Int\n    | Branch (List Node)\n\ntoString : Node -> String\ntoString n =\n    case n of\n        Leaf i ->\n            String.fromInt i\n\n        Branch xs ->\n            String.join \",\" (List.map toString xs)\n",
    );
    write(
        &r.root,
        "src/ExprViewer.elm",
        "module ExprViewer exposing (view)\n\nimport Expression.Node as N exposing (Node(..))\nimport Ext.Thing\n\nview : N.Node -> String\nview n =\n    N.toString n ++ N.toString leaf\n\nleaf : Node\nleaf =\n    Leaf 1\n\nthing =\n    Ext.Thing.value\n",
    );
    write(&r.root, "src/Main.elm", "module Main exposing (main)\n\nimport ExprViewer\n\nmain =\n    ExprViewer.view\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn elm_qualified_lookup_and_references_follow_the_import_table() {
    let r = elm_fixture(None);
    let (_d, _e, g) = graph_of(&r);
    // find by qualified name: Module.name
    let hits = g.find_symbols(&NameMatch::Exact("Expression.Node.toString".into()), None, 10);
    assert_eq!(hits.data.len(), 1);
    assert_eq!(hits.data[0].path, r.root.join("src/Expression/Node.elm"));
    assert_eq!(hits.data[0].kind, SymbolKind::Function);
    assert_eq!(hits.view.worktree, r.root);

    let refs = g.references(hits.data[0].id).data;
    let from: Vec<String> = refs.iter().map(|h| rel(&r.root, &h.path)).collect();
    assert!(from.contains(&"src/ExprViewer.elm".to_string()), "N.toString goes through the `as N` alias: {from:?}");
    assert!(refs.iter().all(|h| h.confidence == Confidence::Exact));
    // recursion inside the module is a reference too
    assert!(from.contains(&"src/Expression/Node.elm".to_string()));
}

#[test]
fn elm_exposed_constructors_and_types_resolve() {
    let r = elm_fixture(None);
    let (_d, _e, g) = graph_of(&r);
    let leaf = g.find_symbols(&NameMatch::Exact("Leaf".into()), Some(SymbolKind::Constructor), 5).data;
    assert_eq!(leaf.len(), 1);
    let refs = g.references(leaf[0].id).data;
    assert!(refs.iter().any(|h| rel(&r.root, &h.path) == "src/ExprViewer.elm"), "`Leaf 1` via exposing Node(..)");
    let node = g.find_symbols(&NameMatch::Exact("Node".into()), Some(SymbolKind::Enum), 5).data;
    let trefs = g.references(node[0].id).data;
    assert!(trefs.iter().any(|h| h.kind == RefKind::Type && rel(&r.root, &h.path) == "src/ExprViewer.elm"), "`N.Node` type");
}

#[test]
fn file_deps_importers_and_blast_radius() {
    let r = elm_fixture(None);
    let (_d, _e, g) = graph_of(&r);
    let node_file = r.root.join("src/Expression/Node.elm");
    let importers = g.file_deps(&node_file, Direction::In, 1).data.unwrap();
    assert_eq!(importers.iter().map(|d| rel(&r.root, &d.path)).collect::<Vec<_>>(), ["src/ExprViewer.elm"]);
    let radius = g.blast_radius(&node_file).data.unwrap();
    let names: Vec<String> = radius.iter().map(|d| rel(&r.root, &d.path)).collect();
    assert!(names.contains(&"src/ExprViewer.elm".to_string()) && names.contains(&"src/Main.elm".to_string()), "{names:?}");
    assert_eq!(radius.iter().find(|d| d.path.ends_with("Main.elm")).unwrap().depth, 2);
    let main_deps = g.file_deps(&r.root.join("src/Main.elm"), Direction::Out, 5).data.unwrap();
    assert_eq!(main_deps.iter().map(|d| rel(&r.root, &d.path)).collect::<Vec<_>>(), ["src/ExprViewer.elm", "src/Expression/Node.elm"]);
    assert!(g.file_deps(&r.root.join("nope.elm"), Direction::Out, 1).data.is_none());
}

#[test]
fn elm_source_directory_outside_the_repo_is_reported_external() {
    let outside = tempfile::tempdir().unwrap();
    let ext_src = outside.path().canonicalize().unwrap().join("tessera/designer/src");
    write(&ext_src, "Ext/Thing.elm", "module Ext.Thing exposing (value)\n\nvalue =\n    1\n");
    let r = elm_fixture(Some(&ext_src));
    let (_d, _e, g) = graph_of(&r);
    let deps = g.file_deps(&r.root.join("src/ExprViewer.elm"), Direction::Out, 1).data.unwrap();
    let ext = deps.iter().find(|d| d.external).expect("an external dependency");
    assert_eq!(ext.path, ext_src.join("Ext/Thing.elm"));
    assert!(deps.iter().any(|d| !d.external && d.path.ends_with("Expression/Node.elm")));
}

#[test]
fn outline_nests_constructors_under_their_type() {
    let r = elm_fixture(None);
    let (_d, _e, g) = graph_of(&r);
    let o = g.outline(&r.root.join("src/Expression/Node.elm")).data.unwrap();
    let shape: Vec<(u32, &str)> = o.iter().map(|e| (e.depth, e.hit.name.as_str())).collect();
    assert_eq!(shape, [(0, "Node"), (1, "Leaf"), (1, "Branch"), (0, "toString")]);
}

#[test]
fn call_hierarchy_callers_and_callees() {
    let r = elm_fixture(None);
    let (_d, _e, g) = graph_of(&r);
    let to_string = exact(&g, "toString");
    let callers = g.calls(to_string, Direction::In, 3).data;
    let names: Vec<(&str, u32)> = callers.iter().map(|c| (c.hit.name.as_str(), c.depth)).collect();
    assert!(names.contains(&("view", 1)), "{names:?}");
    assert!(names.contains(&("main", 3)) || names.contains(&("main", 2)), "transitive: {names:?}");
    let view = exact(&g, "view");
    let callees = g.calls(view, Direction::Out, 1).data;
    assert!(callees.iter().any(|c| c.hit.name == "toString"), "{:?}", callees.iter().map(|c| &c.hit.name).collect::<Vec<_>>());
    assert!(callees.iter().all(|c| c.hit.kind != SymbolKind::TypeAlias));
}

fn ts_fixture() -> Repo {
    let r = init_repo();
    write(&r.root, "web/util.ts", "export function f() { return 1 }\nexport default class Widget { go() { return f(); } }\n");
    write(&r.root, "web/lib/index.ts", "export { helper } from './impl';\n");
    write(&r.root, "web/lib/impl.ts", "export function helper() {}\n");
    write(
        &r.root,
        "web/app.ts",
        "import { f } from './util';\nimport Widget from './util';\nimport * as lib from './lib';\nimport { missing } from 'some-package';\nexport function main() { f(); lib.helper(); new Widget().go(); missing(); stray(); }\n",
    );
    write(&r.root, "web/other.js", "function stray() { return 2 }\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn typescript_imports_default_reexports_and_fallback() {
    let r = ts_fixture();
    let (_d, _e, g) = graph_of(&r);
    let main = exact(&g, "main");
    let callees = g.calls(main, Direction::Out, 1).data;
    let by_name = |n: &str| callees.iter().find(|c| c.hit.name == n);
    let f = by_name("f").expect("f resolved through the named import");
    assert_eq!(f.confidence, Confidence::Exact);
    assert!(f.hit.path.ends_with("web/util.ts"));
    let helper = by_name("helper").expect("lib.helper resolved through `index.ts` re-export");
    assert!(helper.hit.path.ends_with("web/lib/impl.ts"), "{:?}", helper.hit.path);
    assert_eq!(helper.confidence, Confidence::Exact);
    let go = by_name("go").expect("new Widget().go() by unique name");
    assert_eq!(go.confidence, Confidence::Fallback);
    let stray = by_name("stray").expect("a name with no import resolves by unique name");
    assert_eq!(stray.confidence, Confidence::Fallback);
    assert!(by_name("missing").is_none(), "an import from a package never falls back to a project symbol");
    // default import binds the exported class
    let widget = exact(&g, "Widget");
    assert!(g.references(widget).data.iter().any(|h| h.path.ends_with("web/app.ts")));
    // file graph
    let deps = g.file_deps(&r.root.join("web/app.ts"), Direction::Out, 1).data.unwrap();
    let names: Vec<_> = deps.iter().map(|d| rel(&r.root, &d.path)).collect();
    assert_eq!(names, ["web/lib/index.ts", "web/util.ts"]);
    let two_hops = g.file_deps(&r.root.join("web/app.ts"), Direction::Out, 2).data.unwrap();
    assert!(two_hops.iter().any(|d| d.path.ends_with("web/lib/impl.ts")), "reexport edge counts");
}

fn rust_fixture() -> Repo {
    let r = init_repo();
    write(&r.root, "Cargo.toml", "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n");
    write(
        &r.root,
        "src/lib.rs",
        "pub mod store;\nmod util;\nuse crate::store::{open, Store};\npub fn run() { open(); let s = Store::new(); s.close(); util::helper::go(); crate::store::open(); }\n",
    );
    write(&r.root, "src/store.rs", "pub struct Store;\nimpl Store { pub fn new() -> Self { Store } pub fn close(&self) {} }\npub fn open() { super::util::helper::go() }\n");
    write(&r.root, "src/util/mod.rs", "pub mod helper;\n");
    write(&r.root, "src/util/helper.rs", "use super::super::store::open;\npub fn go() { open() }\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn rust_mod_declarations_and_crate_paths_resolve() {
    let r = rust_fixture();
    let (_d, _e, g) = graph_of(&r);
    let deps = g.file_deps(&r.root.join("src/lib.rs"), Direction::Out, 1).data.unwrap();
    let names: Vec<_> = deps.iter().map(|d| rel(&r.root, &d.path)).collect();
    assert_eq!(names, ["src/store.rs", "src/util/mod.rs"], "mod decls and `use crate::` both edge to store.rs once");
    let importers = g.file_deps(&r.root.join("src/store.rs"), Direction::In, 1).data.unwrap();
    let who: Vec<_> = importers.iter().map(|d| rel(&r.root, &d.path)).collect();
    assert_eq!(who, ["src/lib.rs", "src/util/helper.rs"], "super::super:: from helper.rs lands on store.rs");

    let run = exact(&g, "run");
    let callees = g.calls(run, Direction::Out, 1).data;
    let names: Vec<(&str, String)> = callees.iter().map(|c| (c.hit.name.as_str(), rel(&r.root, &c.hit.path))).collect();
    assert!(names.contains(&("open", "src/store.rs".into())), "{names:?}");
    assert!(names.contains(&("new", "src/store.rs".into())), "Store::new through the use list: {names:?}");
    assert!(names.contains(&("go", "src/util/helper.rs".into())), "util::helper::go via mod path: {names:?}");
    assert!(callees.iter().all(|c| c.confidence == Confidence::Exact || c.hit.name == "close"));
    assert!(callees.iter().any(|c| c.hit.name == "close"), "method call by unique name: {names:?}");
}

#[test]
fn most_imported_file_ranks_highest() {
    let r = rust_fixture();
    let (_d, _e, g) = graph_of(&r);
    let store = g.file_rank_of(&r.root.join("src/store.rs")).unwrap();
    for other in ["src/lib.rs", "src/util/mod.rs", "src/util/helper.rs"] {
        assert!(store > g.file_rank_of(&r.root.join(other)).unwrap(), "store.rs should outrank {other}");
    }
    let total: f64 = ["src/lib.rs", "src/store.rs", "src/util/mod.rs", "src/util/helper.rs"].iter().map(|p| g.file_rank_of(&r.root.join(p)).unwrap()).sum();
    assert!((total - 1.0).abs() < 1e-6, "ranks sum to 1, got {total}");
}

#[test]
fn find_by_prefix_regex_and_kind() {
    let r = ts_fixture();
    let (_d, _e, g) = graph_of(&r);
    let p = g.find_symbols(&NameMatch::Prefix("hel".into()), None, 10).data;
    assert_eq!(p.len(), 1);
    let re = g.find_symbols(&NameMatch::Regex(regex::Regex::new("^(f|go)$").unwrap()), None, 10).data;
    assert_eq!(re.len(), 2);
    let classes = g.find_symbols(&NameMatch::Prefix("".into()), Some(SymbolKind::Class), 10).data;
    assert_eq!(classes.len(), 1);
    assert_eq!(classes[0].name, "Widget");
    assert!(g.find_symbols(&NameMatch::Exact("nothing".into()), None, 10).data.is_empty());
}

#[test]
fn stats_by_language() {
    let r = ts_fixture();
    let (_d, _e, g) = graph_of(&r);
    let s = g.stats();
    assert_eq!(s.data.files, 5);
    assert_eq!(s.data.by_language["typescript"].files, 4);
    assert_eq!(s.data.by_language["javascript"].files, 1);
    assert_eq!(s.data.symbols, 6); // f, Widget, go, helper, main, stray
    assert!(s.data.lines > 0);
    assert_eq!(s.view.base_commit.as_ref().map(String::len), Some(40));
}

/// The overlay path must give exactly the answer a full rebuild of the same content gives.
/// Applies `edit` to the working tree, builds the incremental graph from the warm base, then
/// commits and builds the same content from scratch with a fresh engine, and compares.
fn assert_overlay_equals_full(r: &Repo, edit: impl Fn(&Path)) -> (Arc<ViewGraph>, Arc<ViewGraph>) {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let base_view = e.view_for_path(&r.root).unwrap();
    e.build(&base_view, &[], |_| {}).unwrap();
    let base = e.graph(&base_view).unwrap(); // warm the base-tree cache: the dirty view is incremental
    edit(&r.root);
    let dirty_view = e.view_for_path(&r.root).unwrap();
    assert!(dirty_view.label.dirty);
    e.build(&dirty_view, &[], |_| {}).unwrap();
    let incremental = e.graph(&dirty_view).unwrap();
    assert_ne!(base.fingerprint(), incremental.fingerprint(), "the edit must change something");

    commit_all(&r.root, "edits");
    let e2 = Engine::open(&store).unwrap(); // empty graph cache, same facts
    let full = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert_eq!(incremental.fingerprint(), full.fingerprint());
    (incremental, full)
}

#[test]
fn overlay_removing_a_used_symbol_re_resolves_importers() {
    let r = elm_fixture(None);
    // Content-only edit: no path appears or disappears, so only the importer rule can notice that
    // ExprViewer's `N.toString` no longer has a target.
    let (g, _) = assert_overlay_equals_full(&r, |root| {
        write(root, "src/Expression/Node.elm", "module Expression.Node exposing (Node(..))\n\ntype Node\n    = Leaf Int\n");
    });
    assert!(g.find_symbols(&NameMatch::Exact("toString".into()), None, 5).data.is_empty());
}

#[test]
fn overlay_adding_a_file_resolves_previously_unresolved_imports() {
    let r = elm_fixture(None);
    let (g, _) = assert_overlay_equals_full(&r, |root| {
        // Defines nothing the importer references by name, so only the unresolved-import rule can
        // make ExprViewer notice the new file.
        write(root, "src/Ext/Thing.elm", "module Ext.Thing exposing (other)\n\nother =\n    1\n");
    });
    let deps = g.file_deps(&r.root.join("src/ExprViewer.elm"), Direction::Out, 1).data.unwrap();
    assert!(deps.iter().any(|d| d.path.ends_with("src/Ext/Thing.elm")));
}

#[test]
fn overlay_adding_a_second_definition_makes_a_fallback_ambiguous() {
    let r = init_repo();
    write(&r.root, "a.ts", "export function main() { stray(); }\n");
    write(&r.root, "b.js", "function stray() {}\n");
    commit_all(&r.root, "init");
    let (g, _) = assert_overlay_equals_full(&r, |root| write(root, "c.js", "function stray() {}\n"));
    let main = exact(&g, "main");
    assert!(g.calls(main, Direction::Out, 1).data.is_empty(), "two candidates: no guess");
}

#[test]
fn overlay_deleting_and_renaming_files_matches_a_rebuild() {
    let r = elm_fixture(None);
    let (g, _) = assert_overlay_equals_full(&r, |root| {
        std::fs::remove_file(root.join("src/Main.elm")).unwrap();
        write(root, "src/Expression/Node.elm", "module Expression.NodeRenamed exposing (Node(..), toString)\n\ntype Node\n    = Leaf Int\n\ntoString n =\n    \"\"\n");
    });
    assert!(g.find_symbols(&NameMatch::Exact("Main.main".into()), None, 5).data.is_empty());
    let deps = g.file_deps(&r.root.join("src/ExprViewer.elm"), Direction::Out, 1).data.unwrap();
    // Elm resolves an import by path, so a file whose declaration disagrees still answers it.
    assert!(deps.iter().any(|d| d.path.ends_with("src/Expression/Node.elm")), "{deps:?}");
}

/// A four-file import chain a -> b -> c -> d beside a hub that three files import, so the hub
/// tops the global rank and the chain does not.
fn ppr_fixture() -> Repo {
    let r = init_repo();
    write(&r.root, "a.ts", "import { bee } from './b';\nexport function aye() { return bee(); }\n");
    write(&r.root, "b.ts", "import { sea } from './c';\nexport function bee() { return sea(); }\n");
    write(&r.root, "c.ts", "import { dee } from './d';\nexport function sea() { return dee(); }\n");
    write(&r.root, "d.ts", "export function dee() { return 1; }\n");
    write(&r.root, "hub.ts", "export function hubFn() { return 2; }\n");
    for x in ["x1", "x2", "x3"] {
        write(&r.root, &format!("{x}.ts"), &format!("import {{ hubFn }} from './hub';\nexport function {x}() {{ return hubFn(); }}\n"));
    }
    commit_all(&r.root, "init");
    r
}

#[test]
fn personalized_rank_seeded_at_a_chain_file_lifts_its_importer_and_its_import_over_the_hub() {
    let r = ppr_fixture();
    let (_d, _e, g) = graph_of(&r);
    let fi = |p: &str| g.file_idx(Path::new(p)).unwrap();
    let plain = g.personalized_file_rank(&[], 20.0);
    assert!(plain[fi("hub.ts") as usize] > plain[fi("b.ts") as usize], "the hub leads the global rank: {plain:?}");
    let seeded = g.personalized_file_rank(&[(fi("c.ts"), 1.0)], 20.0);
    let hub = seeded[fi("hub.ts") as usize];
    for p in ["b.ts", "d.ts"] {
        assert!(seeded[fi(p) as usize] > hub, "{p} must outrank the hub when c.ts seeds the walk: {seeded:?}");
    }
    // Two hops out still beats a file the seed never reaches.
    assert!(seeded[fi("a.ts") as usize] > hub, "{seeded:?}");
    // The importer is reached only through the reverse edge: a forward-only walk (Aider's) never
    // leaves what the seed uses.
    let forward = g.personalized_file_rank(&[(fi("c.ts"), 1.0)], 0.0);
    assert!(forward[fi("b.ts") as usize] < forward[fi("d.ts") as usize] / 10.0, "{forward:?}");
}

#[test]
fn personalized_rank_with_no_seed_is_exactly_the_plain_file_rank() {
    let r = ppr_fixture();
    let (_d, _e, g) = graph_of(&r);
    let old: Vec<f64> = ["a.ts", "b.ts", "c.ts", "d.ts", "hub.ts", "x1.ts"].iter().map(|p| g.file_rank_of(Path::new(p)).unwrap()).collect();
    let fi = |p: &str| g.file_idx(Path::new(p)).unwrap() as usize;
    for seeds in [vec![], vec![(u32::MAX, 1.0)], vec![(0, 0.0)]] {
        let ranks = g.personalized_file_rank(&seeds, 20.0);
        let got: Vec<f64> = ["a.ts", "b.ts", "c.ts", "d.ts", "hub.ts", "x1.ts"].iter().map(|p| ranks[fi(p)]).collect();
        assert_eq!(got, old, "seeds {seeds:?} name no live file, so the rank is the plain one");
    }
}
