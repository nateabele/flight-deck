//! Elm package views: references into dependencies resolve to package symbols read from a fake
//! `ELM_HOME` (tests/fixtures/elm-home), never from the real `~/.elm`.
mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::graph::{Confidence, ViewGraph};
use flightindex::pkgview;
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::json;
use std::path::Path;
use std::sync::Arc;

fn fixture_home() {
    pkgview::set_elm_home(Some(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/elm-home")));
}

fn graph_of(repo: &Repo) -> (tempfile::TempDir, Engine, Arc<ViewGraph>) {
    fixture_home();
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(&repo.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let g = e.graph(&v).unwrap();
    (dir, e, g)
}

const ELM_JSON: &str = r#"{
    "type": "application",
    "source-directories": ["src"],
    "elm-version": "0.19.1",
    "dependencies": {
        "direct": { "elm/core": "1.0.5", "elm/json": "1.1.3", "elm/html": "1.0.0" },
        "indirect": {}
    },
    "test-dependencies": {
        "direct": { "elm-explorations/test": "2.1.1" },
        "indirect": {}
    }
}"#;

const TOKEN: &str = "module Expression.Token exposing (Token(..))\n\ntype Token\n    = String Int\n    | Number Int\n";

const MAIN: &str = r#"module Main exposing (decoder, encode, names, step, subs, view)

import Expression.Token exposing (Token(..))
import Html exposing (div)
import Json.Decode as D exposing (Decoder, Step(..))
import Json.Encode exposing (..)


names : List String -> List String
names xs =
    List.map identity xs


view : Maybe Int -> Int
view m =
    Maybe.withDefault 0 (Just 1)


decoder : Decoder String
decoder =
    D.field "name" D.string


encode : Int -> Value
encode n =
    int n


step : Step Int
step =
    Loop 1


subs : Cmd msg -> Sub msg
subs c =
    Sub.none


page =
    div


tok =
    Number 1
"#;

const MAIN_TEST: &str = "module MainTest exposing (suite)\n\nimport Expect\n\n\nsuite =\n    Expect.equal 1 1\n";

fn project() -> Repo {
    let r = init_repo();
    write(&r.root, "elm.json", ELM_JSON);
    write(&r.root, "src/Expression/Token.elm", TOKEN);
    write(&r.root, "src/Main.elm", MAIN);
    write(&r.root, "tests/MainTest.elm", MAIN_TEST);
    commit_all(&r.root, "init");
    r
}

/// Every reference of `path` named `name` (on `line`, when given): what it resolved to.
fn resolved(g: &ViewGraph, path: &str, name: &str, line: Option<u32>) -> Vec<(Confidence, Option<String>, Option<String>)> {
    let f = g.file_idx(Path::new(path)).unwrap_or_else(|| panic!("no file {path}"));
    let facts = &g.file(f).facts;
    let res = g.resolution(f);
    let mut out = Vec::new();
    for (i, (fr, rr)) in facts.refs.iter().zip(&res.refs).enumerate() {
        if g.name(fr.name) == name && line.is_none_or(|l| l == fr.line) {
            let local = rr.target.map(|t| format!("{}#{}", g.file(t.file).path, g.symbol(t).name));
            let pkg = g.package_target(f, i as u32).map(|s| s.display());
            out.push((rr.confidence, local, pkg));
        }
    }
    assert!(!out.is_empty(), "no reference {name} in {path}");
    out
}

fn assert_pkg(g: &ViewGraph, path: &str, name: &str, line: Option<u32>, want: &str) {
    for (c, local, pkg) in resolved(g, path, name, line) {
        assert_eq!((c, local, pkg.as_deref()), (Confidence::Package, None, Some(want)), "{path}: {name}");
    }
}

fn line_of(text: &str, needle: &str) -> u32 {
    text.lines().position(|l| l.contains(needle)).unwrap_or_else(|| panic!("no line with {needle}")) as u32 + 1
}

#[test]
fn qualified_default_imports_resolve_to_elm_core() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "src/Main.elm", "map", None, "elm/core@1.0.5 List.map");
    assert_pkg(&g, "src/Main.elm", "withDefault", None, "elm/core@1.0.5 Maybe.withDefault");
    // Basics is imported `exposing (..)`.
    assert_pkg(&g, "src/Main.elm", "identity", None, "elm/core@1.0.5 Basics.identity");
}

#[test]
fn an_import_alias_reaches_the_package_module() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "src/Main.elm", "field", None, "elm/json@1.1.3 Json.Decode.field");
    assert_pkg(&g, "src/Main.elm", "string", Some(line_of(MAIN, "D.field")), "elm/json@1.1.3 Json.Decode.string");
    assert_pkg(&g, "src/Main.elm", "Decoder", None, "elm/json@1.1.3 Json.Decode.Decoder");
}

#[test]
fn exposing_everything_and_type_constructors_bring_unqualified_names() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    // `import Json.Encode exposing (..)`
    assert_pkg(&g, "src/Main.elm", "int", None, "elm/json@1.1.3 Json.Encode.int");
    assert_pkg(&g, "src/Main.elm", "Value", None, "elm/json@1.1.3 Json.Encode.Value");
    // `exposing (Step(..))`, and the implicit `Maybe(..)`.
    assert_pkg(&g, "src/Main.elm", "Loop", None, "elm/json@1.1.3 Json.Decode.Loop");
    assert_pkg(&g, "src/Main.elm", "Just", None, "elm/core@1.0.5 Maybe.Just");
    assert_pkg(&g, "src/Main.elm", "Maybe", None, "elm/core@1.0.5 Maybe.Maybe");
}

#[test]
fn cmd_and_sub_are_aliases_of_the_platform_modules() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "src/Main.elm", "none", None, "elm/core@1.0.5 Platform.Sub.none");
    assert_pkg(&g, "src/Main.elm", "Cmd", None, "elm/core@1.0.5 Platform.Cmd.Cmd");
    assert_pkg(&g, "src/Main.elm", "Sub", None, "elm/core@1.0.5 Platform.Sub.Sub");
}

#[test]
fn the_list_type_is_a_compiler_built_in() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "src/Main.elm", "List", Some(line_of(MAIN, "names : ")), "elm/core@1.0.5 List.List");
}

#[test]
fn a_package_name_beats_the_unique_repository_symbol_of_that_name() {
    // `String` in a signature is elm/core's type, not Token.elm's constructor `String`: the only
    // repository symbol so named, which the unique-name fallback used to bind it to (12,052 such
    // references on tessera made that constructor the top symbol of `map`).
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "src/Main.elm", "String", Some(line_of(MAIN, "names : ")), "elm/core@1.0.5 String.String");
    let token = g.file_idx(Path::new("src/Expression/Token.elm")).unwrap();
    let ctor = g.file(token).facts.symbols.iter().find(|s| s.name == "String").unwrap().local_id;
    let refs = g.references(flightindex::graph::SymId { file: token, local: ctor }).data;
    assert!(refs.is_empty(), "nothing refers to Token.String: {refs:?}");
    // A repository name still wins over a package one.
    for (c, local, _) in resolved(&g, "src/Main.elm", "Number", None) {
        assert_eq!((c, local.as_deref()), (Confidence::Exact, Some("src/Expression/Token.elm#Number")));
    }
}

#[test]
fn test_dependencies_resolve() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "tests/MainTest.elm", "equal", None, "elm-explorations/test@2.1.1 Expect.equal");
}

#[test]
fn a_package_without_docs_json_stays_unresolved_and_is_reported() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    for (c, local, pkg) in resolved(&g, "src/Main.elm", "div", None) {
        assert_eq!((c, local, pkg), (Confidence::Exact, None, None), "elm/html has no docs.json");
    }
    assert!(pkgview::stats().missing_docs.contains(&"elm/html@1.0.0".to_string()), "{:?}", pkgview::stats().missing_docs);
}

#[test]
fn a_package_project_takes_the_highest_installed_version_in_range() {
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"package","name":"me/lib","version":"1.0.0","exposed-modules":["Lib"],"dependencies":{"elm/core":"1.0.0 <= v < 2.0.0"},"test-dependencies":{}}"#);
    write(&r.root, "src/Lib.elm", "module Lib exposing (x)\n\nimport Dict\n\n\nx =\n    Dict.empty\n");
    commit_all(&r.root, "init");
    let (_d, _e, g) = graph_of(&r);
    assert_pkg(&g, "src/Lib.elm", "empty", None, "elm/core@1.0.5 Dict.empty");
}

#[test]
fn version_ranges() {
    assert!(pkgview::version_in_range("1.0.0 <= v < 2.0.0", "1.0.5"));
    assert!(!pkgview::version_in_range("1.0.0 <= v < 2.0.0", "2.0.0"));
    assert!(pkgview::version_in_range("1.0.0 <= v <= 2.0.0", "2.0.0"));
    assert!(!pkgview::version_in_range("1.0.1 <= v < 2.0.0", "1.0.0"));
    assert!(pkgview::version_in_range("1.0.5", "1.0.5"));
}

#[test]
fn package_symbols_get_no_rank_and_no_file_edges() {
    let r = project();
    let (_d, _e, g) = graph_of(&r);
    let main = g.file_idx(Path::new("src/Main.elm")).unwrap();
    let token = g.file_idx(Path::new("src/Expression/Token.elm")).unwrap();
    assert_eq!(g.resolution(main).edges, vec![token], "package imports add no file edge");
}

#[test]
fn incremental_resolution_with_packages_equals_a_full_rebuild() {
    let r = project();
    fixture_home();
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let base_view = e.view_for_path(&r.root).unwrap();
    e.build(&base_view, &[], |_| {}).unwrap();
    let base = e.graph(&base_view).unwrap();
    // A local module now defines `identity`, and Main imports it: the import beats Basics. A
    // new file named like a package module (`Json/Encode.elm`) shadows the package.
    write(&r.root, "src/Util.elm", "module Util exposing (identity)\n\nidentity x =\n    x\n");
    write(&r.root, "src/Json/Encode.elm", "module Json.Encode exposing (int)\n\nint n =\n    n\n");
    write(&r.root, "src/Main.elm", &MAIN.replace("import Html exposing (div)", "import Html exposing (div)\nimport Util exposing (identity)"));
    let dirty = e.view_for_path(&r.root).unwrap();
    e.build(&dirty, &[], |_| {}).unwrap();
    let incremental = e.graph(&dirty).unwrap();
    assert_ne!(base.fingerprint(), incremental.fingerprint());
    let local = |g: &ViewGraph, name: &str| resolved(g, "src/Main.elm", name, None).into_iter().all(|(c, l, _)| c == Confidence::Exact && l.is_some());
    assert!(local(&incremental, "identity"), "{:?}", resolved(&incremental, "src/Main.elm", "identity", None));
    assert!(local(&incremental, "int"), "{:?}", resolved(&incremental, "src/Main.elm", "int", None));
    commit_all(&r.root, "edits");
    let e2 = Engine::open(&store).unwrap();
    let full = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert_eq!(incremental.fingerprint(), full.fingerprint());
}

#[test]
fn an_unchanged_importer_of_a_newly_shadowed_package_module_is_re_resolved() {
    // Only `src/Json/Encode.elm` is added; Main itself is untouched and (without the elm/html
    // import, which stays unresolved) has no unresolved import, so it is dirty only through the
    // rule that a package import may now resolve to a file.
    let r = init_repo();
    write(&r.root, "elm.json", ELM_JSON);
    write(&r.root, "src/Expression/Token.elm", TOKEN);
    write(&r.root, "src/Main.elm", &MAIN.replace("import Html exposing (div)\n", "").replace("page =\n    div\n", ""));
    commit_all(&r.root, "init");
    fixture_home();
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let _base = e.graph(&v).unwrap();
    write(&r.root, "src/Json/Encode.elm", "module Json.Encode exposing (int)\n\nint n =\n    n\n");
    let dirty = e.view_for_path(&r.root).unwrap();
    e.build(&dirty, &[], |_| {}).unwrap();
    let incremental = e.graph(&dirty).unwrap();
    commit_all(&r.root, "edits");
    let e2 = Engine::open(&store).unwrap();
    let full = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert_eq!(incremental.fingerprint(), full.fingerprint());
}

#[test]
fn fallback_never_crosses_a_language_family() {
    // `Widget` is defined only in Elm; a TypeScript call `Widget()` is not a reference to it.
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/W.elm", "module W exposing (Widget)\n\ntype alias Widget =\n    { x : Int }\n");
    write(&r.root, "web/a.ts", "export function go() {\n  return Widget();\n}\n");
    write(&r.root, "web/b.js", "export function helperOnlyHere() {}\n");
    write(&r.root, "web/c.ts", "export function c() {\n  return helperOnlyHere();\n}\n");
    commit_all(&r.root, "init");
    let (_d, _e, g) = graph_of(&r);
    for (c, local, _) in resolved(&g, "web/a.ts", "Widget", None) {
        assert_eq!((c, local), (Confidence::Exact, None), "no TypeScript -> Elm fallback");
    }
    // TypeScript and JavaScript are one family.
    for (c, local, _) in resolved(&g, "web/c.ts", "helperOnlyHere", None) {
        assert_eq!((c, local.as_deref()), (Confidence::Fallback, Some("web/b.js#helperOnlyHere")));
    }
}

#[test]
fn an_elm_type_reference_never_falls_back_to_a_constructor() {
    // No elm.json dependencies here, so no package view: the only defence is the fallback itself.
    let r = init_repo();
    write(&r.root, "elm.json", r#"{"type":"application","source-directories":["src"]}"#);
    write(&r.root, "src/Token.elm", TOKEN.replace("Expression.Token", "Token").as_str());
    write(&r.root, "src/Main.elm", "module Main exposing (f)\n\nf : String -> Int\nf s =\n    1\n");
    commit_all(&r.root, "init");
    let (_d, _e, g) = graph_of(&r);
    for (c, local, _) in resolved(&g, "src/Main.elm", "String", None) {
        assert_eq!((c, local), (Confidence::Exact, None), "a type position cannot name a constructor");
    }
}

// ---- tools -------------------------------------------------------------------------------------

fn tool(svc: &Arc<Service>, cwd: &Path, name: &str, args: serde_json::Value) -> String {
    let r = svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: name.into(), args: args.as_object().cloned().unwrap_or_default() });
    assert!(r.ok, "{name} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

#[test]
fn find_and_refs_show_package_symbols_labelled_as_package() {
    fixture_home();
    let r = project();
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    let found = tool(&svc, &r.root, "find", json!({"name": "List.map"}));
    assert!(found.contains("Package: elm/core@1.0.5 List.map"), "{found}");
    assert!(found.contains("Signature: (a -> b) -> List a -> List b"), "{found}");
    assert!(found.contains("Status: package"), "{found}");
    let refs = tool(&svc, &r.root, "refs", json!({"symbol": "Json.Decode.field"}));
    assert!(refs.contains("Defined in: package elm/json@1.1.3 Json.Decode.field"), "{refs}");
    assert!(refs.contains(&r.root.join("src/Main.elm").display().to_string()), "{refs}");
    assert!(refs.contains(&format!("L{} call in decoder", line_of(MAIN, "D.field"))), "{refs}");
    // An unqualified name that the repository defines lists only the repository's definitions.
    let map = tool(&svc, &r.root, "map", json!({"by": "symbols", "top_n": 0}));
    assert!(!map.contains("elm/core"), "package symbols stay out of map: {map}");
    // `find map` matches repository symbols? No: none is called `map` here, so the package ones show.
    let found = tool(&svc, &r.root, "find", json!({"name": "map"}));
    assert!(found.contains("Package: elm/core@1.0.5 List.map") && found.contains("Package: elm/core@1.0.5 Maybe.map"), "{found}");
    // ... but a repository definition hides the unqualified package ones.
    let found = tool(&svc, &r.root, "find", json!({"name": "view"}));
    assert!(!found.contains("Package:"), "{found}");
    let st = tool(&svc, &r.root, "status", json!({}));
    assert!(st.contains("no docs.json: elm/html@1.0.0"), "{st}");
}
