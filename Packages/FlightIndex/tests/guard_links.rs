//! The guard's blast radius counts importers in dependent views (repositories whose manifests link
//! into the edited file's) when the daemon already holds their graphs, and never builds one.
mod common;
use common::*;
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::service::{Config, Service};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

const NODE: &str = "module Expression.Node exposing (Node(..), toString)\n\n\ntype Node\n    = Leaf Int\n\n\ntoString : Node -> String\ntoString node =\n    \"n\"\n";
const UTIL: &str = "module Expression.Util exposing (render)\n\nimport Expression.Node as Node\n\n\nrender : Node.Node -> String\nrender n =\n    Node.toString n\n";
const MAIN: &str = "module Main exposing (view)\n\nimport Expression.Node as Node\n\n\nview : Int -> String\nview n =\n    Node.toString (Node.Leaf n)\n";
const APP_ELM_JSON: &str = r#"{"type":"application","source-directories":["src","../lib/src"],"elm-version":"0.19.1"}"#;

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

fn call(svc: &Arc<Service>, cwd: &Path, tool: &str, args: Value) -> flightindex::proto::Response {
    svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: tool.into(), args: args.as_object().cloned().unwrap_or_default() })
}

fn blast(svc: &Arc<Service>, cwd: &Path, file: &Path) -> u64 {
    let r = call(svc, cwd, "guard", json!({"file_path": file, "build_wait_ms": 30000}));
    assert!(r.ok, "{:?}", r.error);
    let d = r.data.unwrap();
    assert_eq!(d["state"], "READY", "{d}");
    d["blast"].as_u64().unwrap()
}

#[test]
fn the_guard_counts_importers_in_dependent_views_it_already_holds() {
    let outer = tempfile::tempdir().unwrap();
    let parent = outer.path().canonicalize().unwrap();
    let lib = repo_at(&parent, "lib", &[("src/Expression/Node.elm", NODE), ("src/Expression/Util.elm", UTIL)]);
    let app = repo_at(&parent, "app", &[("elm.json", APP_ELM_JSON), ("src/Main.elm", MAIN)]);
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    let node = lib.join("src/Expression/Node.elm");

    // Nothing has seen app yet: only lib's own importer.
    assert_eq!(blast(&svc, &lib, &node), 1);
    // A query from app indexes it and records its link into lib.
    assert!(call(&svc, &app, "find", json!({"name": "view"})).ok);
    assert_eq!(blast(&svc, &lib, &node), 2, "app's Main.elm imports Node through the link");

    // app changes in a way its held graph does not cover: the guard does not build the new one,
    // and still counts what it held.
    write(&app, "src/Other.elm", "module Other exposing (x)\n\nimport Expression.Node as Node\n\n\nx : String\nx =\n    Node.toString (Node.Leaf 1)\n");
    let parsed = svc.engine.parse_count();
    assert_eq!(blast(&svc, &lib, &node), 2);
    assert_eq!(svc.engine.parse_count(), parsed, "the guard parsed nothing for the dependent view");
    // Once something asks app again, its new importer counts too.
    assert!(call(&svc, &app, "find", json!({"name": "x"})).ok);
    assert_eq!(blast(&svc, &lib, &node), 3);
}
