//! Swift has no file imports: files of one module see each other, so a reference resolves by name
//! within the module (and the modules it imports) and that resolution is the dependency edge.

mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::facts::SymbolKind;
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

fn rel(root: &Path, p: &Path) -> String {
    p.strip_prefix(root).unwrap_or(p).to_string_lossy().to_string()
}

fn deps(g: &ViewGraph, r: &Repo, file: &str, dir: Direction) -> Vec<String> {
    let mut v: Vec<String> = g.file_deps(&r.root.join(file), dir, 1).data.unwrap().iter().map(|d| rel(&r.root, &d.path)).collect();
    v.sort();
    v
}

fn fixture() -> Repo {
    let r = init_repo();
    write(&r.root, "Sources/App/Store.swift", "public final class Store {\n    func reload() {\n        Loader.fetch()\n        helper()\n    }\n}\n");
    write(&r.root, "Sources/App/Store+More.swift", "extension Store {\n    func more() { reload() }\n}\n");
    write(&r.root, "Sources/App/Loader.swift", "enum Loader {\n    static func fetch() {}\n}\n");
    write(&r.root, "Sources/App/Util.swift", "func helper() {}\n");
    write(&r.root, "Sources/App/UsesKit.swift", "import Kit\nfunc k() -> Kit { Kit() }\n");
    write(&r.root, "Sources/Other/Same.swift", "struct Store {}\n");
    write(&r.root, "Sources/Other/Thing.swift", "import App\nstruct Thing { let s: Store }\n");
    write(&r.root, "Packages/Kit/Sources/Kit/Kit.swift", "public struct Kit {}\n");
    write(&r.root, "Tests/AppTests/StoreTests.swift", "@testable import App\nfinal class StoreTests {\n    func t() { Store().reload() }\n}\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn files_of_one_module_depend_on_each_other_without_any_import() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_eq!(
        deps(&g, &r, "Sources/App/Store.swift", Direction::Out),
        ["Sources/App/Loader.swift", "Sources/App/Util.swift"],
        "a type used through `Loader.fetch()` and a top-level function"
    );
    assert_eq!(
        deps(&g, &r, "Sources/App/Store.swift", Direction::In),
        ["Sources/App/Store+More.swift", "Tests/AppTests/StoreTests.swift"],
        "the extension's file and the test through `@testable import App`; Other's own `Store` is not this one"
    );
    assert_eq!(deps(&g, &r, "Sources/App/Store+More.swift", Direction::Out), ["Sources/App/Store.swift"]);
}

#[test]
fn a_module_sees_only_itself_and_what_it_imports() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_eq!(deps(&g, &r, "Sources/Other/Thing.swift", Direction::Out), ["Sources/Other/Same.swift"], "its own `Store` shadows the imported one");
    assert_eq!(deps(&g, &r, "Sources/App/UsesKit.swift", Direction::Out), ["Packages/Kit/Sources/Kit/Kit.swift"], "`import Kit` reaches the package target");
    assert_eq!(deps(&g, &r, "Tests/AppTests/StoreTests.swift", Direction::Out), ["Sources/App/Store.swift"]);
}

#[test]
fn resolution_is_exact_when_the_module_decides_and_marked_when_it_guesses() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    let fetch = g.find_symbols(&NameMatch::Exact("fetch".into()), None, 5).data;
    let refs = g.references(fetch[0].id).data;
    assert!(refs.iter().any(|h| h.path.ends_with("Store.swift") && h.confidence == Confidence::Exact), "Loader.fetch: {refs:?}");
    let helper = g.find_symbols(&NameMatch::Exact("helper".into()), None, 5).data;
    assert!(g.references(helper[0].id).data.iter().all(|h| h.confidence == Confidence::Exact), "a unique top-level function in the module");
    // `Store().reload()` has an expression for a receiver: a unique member name is a guess.
    let reload = g.find_symbols(&NameMatch::Exact("reload".into()), None, 5).data;
    let refs = g.references(reload[0].id).data;
    let from_test = refs.iter().find(|h| h.path.ends_with("StoreTests.swift")).expect("reload called from the test");
    assert_eq!(from_test.confidence, Confidence::Fallback);
    // `reload()` inside the extension is a member of the enclosing type, in another file.
    let from_ext = refs.iter().find(|h| h.path.ends_with("Store+More.swift")).expect("reload called from the extension");
    assert_eq!(from_ext.confidence, Confidence::Exact);
}

#[test]
fn the_class_and_its_extensions_are_distinct_definitions_and_references_see_both() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    let all = g.find_symbols(&NameMatch::Exact("Store".into()), None, 10).data;
    let kinds = |p: &str| all.iter().filter(|h| h.path.ends_with(p)).map(|h| h.kind).collect::<Vec<_>>();
    assert_eq!(kinds("App/Store.swift"), [SymbolKind::Class]);
    assert_eq!(kinds("Store+More.swift"), [SymbolKind::Extension]);
    let class = all.iter().find(|h| h.path.ends_with("App/Store.swift")).unwrap();
    let from: Vec<String> = g.references(class.id).data.iter().map(|h| rel(&r.root, &h.path)).collect();
    assert!(from.contains(&"Sources/App/Store+More.swift".to_string()), "the extension names the type it extends: {from:?}");
    assert!(from.contains(&"Tests/AppTests/StoreTests.swift".to_string()));
}

/// The overlay path must give exactly the answer a full rebuild of the same content gives.
fn assert_overlay_equals_full(r: &Repo, edit: impl Fn(&Path)) -> Arc<ViewGraph> {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let base_view = e.view_for_path(&r.root).unwrap();
    e.build(&base_view, &[], |_| {}).unwrap();
    let base = e.graph(&base_view).unwrap();
    edit(&r.root);
    let dirty_view = e.view_for_path(&r.root).unwrap();
    e.build(&dirty_view, &[], |_| {}).unwrap();
    let incremental = e.graph(&dirty_view).unwrap();
    assert_ne!(base.fingerprint(), incremental.fingerprint(), "the edit must change something");
    commit_all(&r.root, "edits");
    let e2 = Engine::open(&store).unwrap();
    let full = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert_eq!(incremental.fingerprint(), full.fingerprint());
    incremental
}

#[test]
fn overlay_adding_a_file_to_a_module_resolves_names_that_had_no_definition() {
    let r = init_repo();
    write(&r.root, "Sources/App/A.swift", "struct A { let b: Later }\n");
    commit_all(&r.root, "init");
    let g = assert_overlay_equals_full(&r, |root| write(root, "Sources/App/Later.swift", "struct Later {}\n"));
    assert_eq!(deps(&g, &r, "Sources/App/A.swift", Direction::Out), ["Sources/App/Later.swift"]);
}
