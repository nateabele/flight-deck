//! Elixir package views: references into the standard library (read from a fake Elixir root of
//! `.beam` files, tests/fixtures/elixir-home) and into `mix.lock` dependencies (sources under
//! `deps/`) resolve to package symbols; `use` brings what `__using__` imports.
mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::graph::{Confidence, ViewGraph};
use flightindex::hexview;
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::json;
use std::path::Path;
use std::sync::Arc;

fn fixture_home() {
    hexview::set_elixir_home(Some(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/elixir-home")));
}

fn graph_at(root: &Path) -> (tempfile::TempDir, Engine, Arc<ViewGraph>) {
    fixture_home();
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let g = e.graph(&v).unwrap();
    (dir, e, g)
}

const MIX_LOCK: &str = r#"%{
  "jason": {:hex, :jason, "1.4.4", "abc", [:mix], [], "hexpm", "def"},
  "phoenix": {:hex, :phoenix, "1.7.0", "abc", [:mix], [], "hexpm", "def"},
  "props": {:hex, :stream_props, "0.2.0", "abc", [:mix], [], "hexpm", "def"},
}
"#;

const JASON: &str = r#"defmodule Jason do
  @type t :: term
  def encode!(value, opts \\ []), do: {value, opts}
  defp secret(x), do: x
end
"#;

const PROPS: &str = r#"defmodule Props do
  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__)
      import Props.Gen, only: [int: 0]
      alias Props.Gen, as: G
    end
  end

  defmacro check(x), do: x
end

defmodule Props.Gen do
  def int, do: 1
  def float, do: 1.0
end
"#;

const APP: &str = r#"defmodule App do
  alias Jason, as: J
  import Enum, only: [count: 1]
  import Props.Gen

  @spec name(String.t()) :: Jason.t()
  def name(s), do: s

  def run(xs) do
    ys = Enum.map(xs, fn x -> x end)
    J.encode!(ys)
    String.upcase("a")
    count(xs)
    then(xs, fn x -> x end)
    put_elem({1}, 0, 2)
    int()
    %MapSet{}
    NoDocs.plain(1, 2)
    NoDocs.shaped(1)
    Phoenix.json(xs)
    Missing.call()
  end
end
"#;

const UTIL: &str = "defmodule App.Util do\n  def put_elem(t, i, v), do: {t, i, v}\nend\n";

const CASE: &str = r#"defmodule App.Case do
  use ExUnit.CaseTemplate

  using do
    quote do
      import App.Case
      use Props
      alias App.Util
    end
  end

  def helper, do: 1
end
"#;

const APP_TEST: &str = r#"defmodule AppTest do
  use App.Case

  test "runs" do
    assert App.run([1])
    helper()
    check(1)
    int()
    Util.put_elem({1}, 0, 2)
    G.float()
  end
end
"#;

const PLAIN_TEST: &str = r#"defmodule PlainTest do
  use ExUnit.Case
  doctest App

  setup do
    on_exit(fn -> :ok end)
  end

  describe "x" do
    test "y" do
      assert 1
      refute 2
    end
  end
end
"#;

fn write_deps(root: &Path) {
    write(root, "deps/jason/hex_metadata.config", "{<<\"name\">>,<<\"jason\">>}.\n{<<\"version\">>,<<\"1.4.4\">>}.\n");
    write(root, "deps/jason/lib/jason.ex", JASON);
    write(root, "deps/phoenix/hex_metadata.config", "{<<\"version\">>,<<\"1.6.0\">>}.\n");
    write(root, "deps/phoenix/lib/phoenix.ex", "defmodule Phoenix do\n  def json(x), do: x\nend\n");
    write(root, "deps/props/hex_metadata.config", "{<<\"version\">>,<<\"0.2.0\">>}.\n");
    write(root, "deps/props/lib/props.ex", PROPS);
}

fn project() -> Repo {
    let r = init_repo();
    write(&r.root, ".gitignore", "deps/\n_build/\n");
    write(&r.root, "mix.exs", "defmodule App.MixProject do\n  use Mix.Project\nend\n");
    write(&r.root, "mix.lock", MIX_LOCK);
    write(&r.root, "lib/app.ex", APP);
    write(&r.root, "lib/app/util.ex", UTIL);
    write(&r.root, "lib/app/types.ex", "defmodule App.Types do\n  import Props.Gen\n\n  @spec gen() :: int()\n  def gen, do: int()\nend\n");
    write(&r.root, "test/support/case.ex", CASE);
    write(&r.root, "test/app_test.exs", APP_TEST);
    write(&r.root, "test/plain_test.exs", PLAIN_TEST);
    commit_all(&r.root, "init");
    write_deps(&r.root);
    r
}

/// Every reference of `path` named `name`: what it resolved to.
fn resolved(g: &ViewGraph, path: &str, name: &str) -> Vec<(Confidence, Option<String>, Option<String>)> {
    let f = g.file_idx(Path::new(path)).unwrap_or_else(|| panic!("no file {path}"));
    let facts = &g.file(f).facts;
    let res = g.resolution(f);
    let mut out = Vec::new();
    for (i, (fr, rr)) in facts.refs.iter().zip(&res.refs).enumerate() {
        if g.name(fr.name) == name {
            let local = rr.target.map(|t| format!("{}#{}", g.file(t.file).path, g.symbol(t).name));
            let pkg = g.package_target(f, i as u32).map(|s| s.display());
            out.push((rr.confidence, local, pkg));
        }
    }
    assert!(!out.is_empty(), "no reference {name} in {path}");
    out
}

fn assert_pkg(g: &ViewGraph, path: &str, name: &str, want: &str) {
    for (c, local, pkg) in resolved(g, path, name) {
        assert_eq!((c, local, pkg.as_deref()), (Confidence::Package, None, Some(want)), "{path}: {name}");
    }
}

fn assert_unresolved(g: &ViewGraph, path: &str, name: &str) {
    for (c, local, pkg) in resolved(g, path, name) {
        assert_eq!((c, local, pkg), (Confidence::Exact, None, None), "{path}: {name}");
    }
}

fn assert_local(g: &ViewGraph, path: &str, name: &str, want: &str) {
    for (c, local, pkg) in resolved(g, path, name) {
        assert_eq!((c, local.as_deref(), pkg), (Confidence::Exact, Some(want), None), "{path}: {name}");
    }
}

#[test]
fn remote_calls_resolve_into_the_standard_library() {
    let r = project();
    let (_d, _e, g) = graph_at(&r.root);
    assert_pkg(&g, "lib/app.ex", "map", "elixir@1.99.0 Enum.map");
    assert_pkg(&g, "lib/app.ex", "upcase", "elixir@1.99.0 String.upcase");
    // A type in a spec, and a module mention.
    for (c, _, pkg) in resolved(&g, "lib/app.ex", "t") {
        assert_eq!(c, Confidence::Package);
        assert!(matches!(pkg.as_deref(), Some("elixir@1.99.0 String.t") | Some("jason@1.4.4 Jason.t")), "{pkg:?}");
    }
    assert_pkg(&g, "lib/app.ex", "MapSet", "elixir@1.99.0 MapSet");
}

#[test]
fn a_module_without_docs_is_read_from_its_export_table() {
    let r = project();
    let (_d, _e, g) = graph_at(&r.root);
    assert_pkg(&g, "lib/app.ex", "plain", "elixir@1.99.0 NoDocs.plain");
    // Exported as `MACRO-shaped/2`.
    assert_pkg(&g, "lib/app.ex", "shaped", "elixir@1.99.0 NoDocs.shaped");
}

#[test]
fn an_alias_reaches_a_dependency_at_its_locked_version() {
    let r = project();
    let (_d, _e, g) = graph_at(&r.root);
    assert_pkg(&g, "lib/app.ex", "encode!", "jason@1.4.4 Jason.encode!");
}

#[test]
fn imports_and_kernel_auto_imports_bring_bare_names() {
    let r = project();
    let (_d, _e, g) = graph_at(&r.root);
    assert_pkg(&g, "lib/app.ex", "count", "elixir@1.99.0 Enum.count");
    assert_pkg(&g, "lib/app.ex", "int", "props@0.2.0 Props.Gen.int");
    assert_pkg(&g, "lib/app.ex", "then", "elixir@1.99.0 Kernel.then");
}

#[test]
fn a_type_position_never_names_an_imported_function() {
    // `int()` in the spec is a type; Props.Gen exports a function `int/0`, not a type.
    let r = project();
    let (_d, _e, g) = graph_at(&r.root);
    let mut got: Vec<_> = resolved(&g, "lib/app/types.ex", "int").into_iter().map(|(c, _, p)| (c, p)).collect();
    got.sort_by_key(|(_, p)| p.clone());
    assert_eq!(got, vec![(Confidence::Exact, None), (Confidence::Package, Some("props@0.2.0 Props.Gen.int".to_string()))]);
}

#[test]
fn a_kernel_name_beats_the_unique_repository_function_of_that_name() {
    // `put_elem` is defined once in the repository (App.Util), which the unique-name fallback used
    // to bind every bare `put_elem` to; App neither defines nor imports it, so it is Kernel's.
    let r = project();
    let (_d, _e, g) = graph_at(&r.root);
    assert_pkg(&g, "lib/app.ex", "put_elem", "elixir@1.99.0 Kernel.put_elem");
}

#[test]
fn a_dependency_at_another_version_or_none_stays_unresolved_and_is_reported() {
    let r = project();
    let (_d, _e, g) = graph_at(&r.root);
    assert_unresolved(&g, "lib/app.ex", "json");
    assert_unresolved(&g, "lib/app.ex", "call");
    let missing = hexview::stats().missing;
    assert!(missing.contains(&"phoenix@1.7.0 (deps/phoenix is 1.6.0)".to_string()), "{missing:?}");
}

#[test]
fn use_of_ex_unit_case_imports_assertions_callbacks_and_test_macros() {
    let r = project();
    let (_d, _e, g) = graph_at(&r.root);
    let t = "test/plain_test.exs";
    assert_pkg(&g, t, "assert", "ex_unit@1.99.0 ExUnit.Assertions.assert");
    assert_pkg(&g, t, "refute", "ex_unit@1.99.0 ExUnit.Assertions.refute");
    assert_pkg(&g, t, "test", "ex_unit@1.99.0 ExUnit.Case.test");
    assert_pkg(&g, t, "describe", "ex_unit@1.99.0 ExUnit.Case.describe");
    assert_pkg(&g, t, "setup", "ex_unit@1.99.0 ExUnit.Callbacks.setup");
    assert_pkg(&g, t, "on_exit", "ex_unit@1.99.0 ExUnit.Callbacks.on_exit");
    assert_pkg(&g, t, "doctest", "ex_unit@1.99.0 ExUnit.DocTest.doctest");
}

#[test]
fn use_of_a_case_template_brings_its_using_block_and_ex_unit_case() {
    let r = project();
    let (_d, _e, g) = graph_at(&r.root);
    let t = "test/app_test.exs";
    // `use ExUnit.CaseTemplate` makes `use App.Case` also `use ExUnit.Case`.
    assert_pkg(&g, t, "assert", "ex_unit@1.99.0 ExUnit.Assertions.assert");
    assert_pkg(&g, t, "test", "ex_unit@1.99.0 ExUnit.Case.test");
    // `import App.Case` in the using block: a repository import of the test.
    assert_local(&g, t, "helper", "test/support/case.ex#helper");
    // `use Props` in the using block, followed into the dependency's `__using__`.
    assert_pkg(&g, t, "check", "props@0.2.0 Props.check");
    assert_pkg(&g, t, "int", "props@0.2.0 Props.Gen.int");
    // Aliases made by the using blocks.
    assert_local(&g, t, "put_elem", "lib/app/util.ex#put_elem");
    assert_pkg(&g, t, "float", "props@0.2.0 Props.Gen.float");
    // The template's file is a dependency of the test.
    let test = g.file_idx(Path::new(t)).unwrap();
    let case = g.file_idx(Path::new("test/support/case.ex")).unwrap();
    assert!(g.resolution(test).edges.contains(&case));
}

#[test]
fn a_repository_module_shadows_a_package_module_and_incremental_equals_full() {
    let r = project();
    fixture_home();
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let base = e.graph(&v).unwrap();
    assert_pkg(&base, "lib/app.ex", "encode!", "jason@1.4.4 Jason.encode!");
    // The repository now defines `Jason` itself (in an existing file, so no path changes), and App
    // defines its own `then`.
    write(&r.root, "lib/app/util.ex", &format!("{UTIL}\ndefmodule Jason do\n  def encode!(x), do: x\nend\n"));
    write(&r.root, "lib/app.ex", &APP.replace("  def name(s), do: s\n", "  def name(s), do: s\n  def then(a, b), do: {a, b}\n"));
    let dirty = e.view_for_path(&r.root).unwrap();
    e.build(&dirty, &[], |_| {}).unwrap();
    let incremental = e.graph(&dirty).unwrap();
    assert_local(&incremental, "lib/app.ex", "encode!", "lib/app/util.ex#encode!");
    assert_local(&incremental, "lib/app.ex", "then", "lib/app.ex#then");
    commit_all(&r.root, "edits");
    let e2 = Engine::open(&store).unwrap();
    let full = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert_eq!(incremental.fingerprint(), full.fingerprint());
}

#[test]
fn a_linked_worktree_without_deps_reads_the_main_worktrees() {
    let r = project();
    // A lockfile no other test has, so no project another test resolved is reused.
    write(&r.root, "mix.lock", &format!("{MIX_LOCK}# linked\n"));
    commit_all(&r.root, "lock");
    let wt_dir = tempfile::tempdir().unwrap();
    let wt = wt_dir.path().canonicalize().unwrap().join("linked");
    git(&r.root, &["worktree", "add", "--detach", wt.to_str().unwrap()]);
    assert!(!wt.join("deps").exists());
    let (_d, _e, g) = graph_at(&wt);
    assert_pkg(&g, "lib/app.ex", "encode!", "jason@1.4.4 Jason.encode!");
}

#[test]
fn a_file_outside_any_mix_project_gets_the_standard_library() {
    let r = init_repo();
    write(&r.root, "scripts/run.exs", "Enum.map([1], fn x -> x end)\n");
    commit_all(&r.root, "init");
    let (_d, _e, g) = graph_at(&r.root);
    assert_pkg(&g, "scripts/run.exs", "map", "elixir@1.99.0 Enum.map");
}

// ---- tools -------------------------------------------------------------------------------------

fn tool(svc: &Arc<Service>, cwd: &Path, name: &str, args: serde_json::Value) -> String {
    let r = svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: name.into(), args: args.as_object().cloned().unwrap_or_default() });
    assert!(r.ok, "{name} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

#[test]
fn find_and_refs_show_elixir_package_symbols() {
    fixture_home();
    let r = project();
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    let found = tool(&svc, &r.root, "find", json!({"name": "Enum.map"}));
    assert!(found.contains("Package: elixir@1.99.0 Enum.map"), "{found}");
    assert!(found.contains("Signature: map(enumerable, fun)"), "{found}");
    let found = tool(&svc, &r.root, "find", json!({"name": "MapSet"}));
    assert!(found.contains("Package: elixir@1.99.0 MapSet"), "{found}");
    let refs = tool(&svc, &r.root, "refs", json!({"symbol": "Jason.encode!"}));
    assert!(refs.contains("Defined in: package jason@1.4.4 Jason.encode!"), "{refs}");
    assert!(refs.contains(&r.root.join("lib/app.ex").display().to_string()), "{refs}");
    let st = tool(&svc, &r.root, "status", json!({}));
    assert!(st.contains("elixir packages: ") && st.contains("phoenix@1.7.0 (deps/phoenix is 1.6.0)"), "{st}");
}
