//! Elixir module resolution through the graph: modules do not map to paths, so a module-name
//! index over the view is the only way a remote call finds its file.

mod common;
use common::*;
use flightindex::engine::Engine;
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

fn fixture() -> Repo {
    let r = init_repo();
    // Deliberately not at the path the module name suggests: Elixir does not care.
    write(
        &r.root,
        "lib/shop/order.ex",
        "defmodule Shop.Order do\n  alias Shop.{Item, Pricing}\n  import Shop.Helpers, only: [slug: 1]\n  require Logger\n\n  def total(items) do\n    Logger.info(\"x\")\n    %Item{} = hd(items)\n    Pricing.price(items) + slug(1)\n  end\nend\n",
    );
    write(
        &r.root,
        "lib/shop/catalog.ex",
        "defmodule Shop.Item do\n  defstruct [:sku]\nend\n\ndefmodule Shop.Pricing do\n  def price(items), do: length(items)\n  defmodule Rules do\n    def price(_), do: 0\n  end\nend\n",
    );
    write(&r.root, "lib/helpers.ex", "defmodule Shop.Helpers do\n  def slug(s), do: s\n  def info(x), do: x\nend\n");
    write(&r.root, "lib/shop.ex", "defmodule Shop do\n  def run(o), do: Shop.Order.total(o)\nend\n");
    commit_all(&r.root, "init");
    r
}

fn out_deps(g: &ViewGraph, r: &Repo, file: &str) -> Vec<String> {
    let mut v: Vec<String> =
        g.file_deps(&r.root.join(file), Direction::Out, 1).data.unwrap().iter().map(|d| rel(&r.root, &d.path)).collect();
    v.sort();
    v
}

#[test]
fn imports_land_on_the_file_that_defines_the_module() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    assert_eq!(out_deps(&g, &r, "lib/shop/order.ex"), ["lib/helpers.ex", "lib/shop/catalog.ex"]);
    assert_eq!(out_deps(&g, &r, "lib/shop.ex"), ["lib/shop/order.ex"], "a fully-qualified call needs no alias");
}

#[test]
fn remote_calls_bind_to_the_function_in_the_named_module() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    // Two `price` functions live in one file; only Shop.Pricing's is the target.
    let prices = g.find_symbols(&NameMatch::Exact("price".into()), None, 10).data;
    assert_eq!(prices.len(), 2);
    let pricing = prices.iter().find(|h| h.start_line == 6).expect("Shop.Pricing.price");
    let refs = g.references(pricing.id).data;
    assert!(refs.iter().any(|h| rel(&r.root, &h.path) == "lib/shop/order.ex" && h.confidence == Confidence::Exact), "{refs:?}");
    let rules = prices.iter().find(|h| h.start_line == 8).unwrap();
    assert!(g.references(rules.id).data.is_empty(), "Shop.Pricing.Rules.price is not called");
}

#[test]
fn struct_literals_and_imported_functions_resolve_exactly() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    let item = g.find_symbols(&NameMatch::Exact("Shop.Item".into()), None, 5).data;
    assert_eq!(item.len(), 1);
    assert!(g.references(item[0].id).data.iter().any(|h| rel(&r.root, &h.path) == "lib/shop/order.ex"), "%Item{{}} through the alias group");
    let slug = g.find_symbols(&NameMatch::Exact("slug".into()), None, 5).data;
    assert!(g.references(slug[0].id).data.iter().any(|h| rel(&r.root, &h.path) == "lib/shop/order.ex" && h.confidence == Confidence::Exact), "import only: [slug: 1]");
}

#[test]
fn a_call_into_a_package_does_not_bind_to_a_same_named_repository_function() {
    let r = fixture();
    let (_d, _e, g) = graph_of(&r);
    // `Logger.info/1` is not Shop.Helpers.info/1, even though `info` is a unique name in the view.
    let info = g.find_symbols(&NameMatch::Exact("info".into()), None, 5).data;
    assert_eq!(info.len(), 1);
    assert!(g.references(info[0].id).data.is_empty(), "{:?}", g.references(info[0].id).data);
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
fn overlay_adding_a_module_resolves_a_fully_qualified_call_that_had_no_target() {
    let r = init_repo();
    write(&r.root, "lib/a.ex", "defmodule A do\n  def go, do: Other.Mod.run()\nend\n");
    commit_all(&r.root, "init");
    let g = assert_overlay_equals_full(&r, |root| write(root, "lib/z.ex", "defmodule Other.Mod do\n  def run, do: 1\nend\n"));
    assert_eq!(out_deps(&g, &r, "lib/a.ex"), ["lib/z.ex"]);
}

#[test]
fn overlay_removing_a_function_unbinds_the_calls_that_reached_it() {
    let r = fixture();
    let g = assert_overlay_equals_full(&r, |root| write(root, "lib/shop/order.ex", "defmodule Shop.Order do\nend\n"));
    assert!(out_deps(&g, &r, "lib/shop.ex").is_empty(), "`total` is gone, so the call has no target and no edge");
}
