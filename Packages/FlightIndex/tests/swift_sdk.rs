//! Swift package views: references to SDK names resolve to package symbols read from a fake SDK
//! (tests/fixtures/swift-sdk), never from the real one, whose contents differ between machines.
mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::graph::{Confidence, ViewGraph};
use flightindex::proto::{Request, PROTOCOL_VERSION};
use flightindex::pkgview_swift::{self, Sdk};
use flightindex::service::{Config, Service};
use serde_json::json;
use std::path::Path;
use std::sync::Arc;

fn fixture_sdk() {
    let base = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/swift-sdk");
    pkgview_swift::set_sdk(Some(Sdk { root: base.join("SDKs/MacOSX.sdk"), platform_dev: Some(base.join("Developer")), name: "macosx".into(), version: "1.0".into() }));
}

fn graph_of(repo: &Repo) -> (tempfile::TempDir, Engine, Arc<ViewGraph>) {
    fixture_sdk();
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(&repo.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let g = e.graph(&v).unwrap();
    (dir, e, g)
}

const MAIN: &str = r#"import Foundation

func go() {
    let text = UUID().uuidString
    print(text)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: "/x"))
    let names: [String] = ["a"]
    _ = names.map { $0 }
}
"#;

const TESTS: &str = r#"import XCTest

final class GoTests: XCTestCase {
    func testGo() {
        let e = expectation(description: "done")
        XCTAssertEqual(UUID(), UUID())
    }
}
"#;

fn project() -> Repo {
    let r = init_repo();
    write(&r.root, "Sources/App/Main.swift", MAIN);
    write(&r.root, "Tests/AppTests/GoTests.swift", TESTS);
    commit_all(&r.root, "init");
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
            out.push((rr.confidence, local, g.package_target(f, i as u32).map(|s| s.display())));
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

#[test]
fn sdk_names_resolve_to_package_symbols() {
    let (_d, _e, g) = graph_of(&project());
    assert_pkg(&g, "Sources/App/Main.swift", "UUID", "macosx@1.0 Foundation.UUID");
    assert_pkg(&g, "Sources/App/Main.swift", "print", "macosx@1.0 Swift.print");
    assert_pkg(&g, "Sources/App/Main.swift", "URL", "macosx@1.0 Foundation.URL");
    assert_pkg(&g, "Sources/App/Main.swift", "uuidString", "macosx@1.0 Foundation.UUID.uuidString");
}

#[test]
fn objective_c_names_take_their_swift_names() {
    let (_d, _e, g) = graph_of(&project());
    // `NSFileManager` is `FileManager` by the API notes; `defaultManager` is `default` by
    // omit-needless-words; of `removeItemAtPath:` and `removeItemAtURL:` the URL one.
    assert_pkg(&g, "Sources/App/Main.swift", "FileManager", "macosx@1.0 Foundation.FileManager");
    assert_pkg(&g, "Sources/App/Main.swift", "default", "macosx@1.0 Foundation.FileManager.default");
    assert_pkg(&g, "Sources/App/Main.swift", "removeItem", "macosx@1.0 Foundation.FileManager.removeItem");
    let f = g.file_idx(Path::new("Sources/App/Main.swift")).unwrap();
    let i = g.file(f).facts.refs.iter().position(|r| g.name(r.name) == "removeItem").unwrap();
    assert_eq!(g.package_target(f, i as u32).unwrap().signature.as_deref(), Some("@method removeItemAtURL:"));
}

#[test]
fn an_array_receiver_reaches_the_standard_library() {
    let (_d, _e, g) = graph_of(&project());
    assert_pkg(&g, "Sources/App/Main.swift", "map", "macosx@1.0 Swift.Sequence.map");
}

#[test]
fn reexports_and_inherited_members_reach_test_code() {
    let (_d, _e, g) = graph_of(&project());
    // XCTest's headers import Foundation, which `import XCTest` therefore re-exports.
    assert_pkg(&g, "Tests/AppTests/GoTests.swift", "UUID", "macosx@1.0 Foundation.UUID");
    assert_pkg(&g, "Tests/AppTests/GoTests.swift", "XCTAssertEqual", "macosx@1.0 XCTest.XCTAssertEqual");
    assert_pkg(&g, "Tests/AppTests/GoTests.swift", "XCTestCase", "macosx@1.0 XCTest.XCTestCase");
    // A bare call in an `XCTestCase` subclass is the inherited method.
    assert_pkg(&g, "Tests/AppTests/GoTests.swift", "expectation", "macosx@1.0 XCTest.XCTestCase.expectation");
}

#[test]
fn a_repository_declaration_shadows_the_sdk_and_a_missing_import_hides_it() {
    let r = project();
    write(&r.root, "Sources/App/Ids.swift", "struct UUID {}\n");
    write(&r.root, "Sources/Lib/Plain.swift", "func plain() {\n    let u = URL(fileURLWithPath: \"/\")\n    print(u)\n}\n");
    commit_all(&r.root, "shadow");
    let (_d, _e, g) = graph_of(&r);
    for (c, local, pkg) in resolved(&g, "Sources/App/Main.swift", "UUID") {
        assert_eq!((c, local.as_deref(), pkg), (Confidence::Exact, Some("Sources/App/Ids.swift#UUID"), None));
    }
    // No `import Foundation`: `URL` is not nameable; the standard library always is.
    for (c, local, pkg) in resolved(&g, "Sources/Lib/Plain.swift", "URL") {
        assert_eq!((c, local, pkg), (Confidence::Exact, None, None));
    }
    assert_pkg(&g, "Sources/Lib/Plain.swift", "print", "macosx@1.0 Swift.print");
}

#[test]
fn package_symbols_draw_no_file_edges() {
    let (_d, _e, g) = graph_of(&project());
    let f = g.file_idx(Path::new("Sources/App/Main.swift")).unwrap();
    assert!(g.resolution(f).edges.is_empty());
}

#[test]
fn incremental_resolution_with_sdk_names_equals_a_full_rebuild() {
    let r = project();
    fixture_sdk();
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let base_view = e.view_for_path(&r.root).unwrap();
    e.build(&base_view, &[], |_| {}).unwrap();
    let base = e.graph(&base_view).unwrap();
    // A repository `UUID` now shadows Foundation's in Main, which is itself unchanged.
    write(&r.root, "Sources/App/Ids.swift", "struct UUID {}\n");
    let dirty = e.view_for_path(&r.root).unwrap();
    e.build(&dirty, &[], |_| {}).unwrap();
    let incremental = e.graph(&dirty).unwrap();
    assert_ne!(base.fingerprint(), incremental.fingerprint());
    assert!(resolved(&incremental, "Sources/App/Main.swift", "UUID").iter().all(|(c, l, _)| *c == Confidence::Exact && l.is_some()));
    commit_all(&r.root, "edits");
    let e2 = Engine::open(&store).unwrap();
    let full = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert_eq!(incremental.fingerprint(), full.fingerprint());
}

// ---- tools -------------------------------------------------------------------------------------

fn tool(svc: &Arc<Service>, cwd: &Path, name: &str, args: serde_json::Value) -> String {
    let r = svc.handle(Request { v: Some(PROTOCOL_VERSION), id: json!(1), cwd: cwd.to_string_lossy().to_string(), seq: 0, tool: name.into(), args: args.as_object().cloned().unwrap_or_default() });
    assert!(r.ok, "{name} failed: {:?} {:?}", r.state, r.error);
    r.text.unwrap()
}

#[test]
fn find_refs_and_status_show_sdk_symbols() {
    fixture_sdk();
    let r = project();
    let dir = tempfile::tempdir().unwrap();
    let svc = Service::open(Config::new(dir.path().join("store"))).unwrap();
    let found = tool(&svc, &r.root, "find", json!({"name": "UUID"}));
    assert!(found.contains("Package: macosx@1.0 Foundation.UUID"), "{found}");
    assert!(found.contains("Status: package"), "{found}");
    let found = tool(&svc, &r.root, "find", json!({"name": "FileManager.default"}));
    assert!(found.contains("Package: macosx@1.0 Foundation.FileManager.default"), "{found}");
    let refs = tool(&svc, &r.root, "refs", json!({"symbol": "UUID"}));
    assert!(refs.contains("Defined in: package macosx@1.0 Foundation.UUID"), "{refs}");
    assert!(refs.contains(&r.root.join("Sources/App/Main.swift").display().to_string()), "{refs}");
    let st = tool(&svc, &r.root, "status", json!({}));
    assert!(st.contains("swift sdk: macosx@1.0"), "{st}");
}
