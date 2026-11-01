//! The index-store layer: where a build's index store covers a file unchanged since the build,
//! the compiler's answer replaces the heuristic one.

mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::graph::{Confidence, ViewGraph};
use flightindex::indexstore;
use std::path::Path;
use std::process::Command;

const MAILER: &str = "final class Mailer {\n    func send(_ s: String) {}\n    func send(_ i: Int, to: String) {}\n    func advanced(by n: Int) {}\n}\n";
const USE: &str = "func go(m: Mailer, xs: [Int]) {\n    m.send(1, to: \"x\")\n    _ = xs.reversed().first!.advanced(by: 1)\n}\n";

/// Compile the fixture with indexing on, as `swift build` would, into `.build/debug/index/store`.
/// `None` when this machine has no Swift compiler or no libIndexStore: the layer is optional.
fn indexed_fixture() -> Option<Repo> {
    if !indexstore::available() {
        eprintln!("skipped: no libIndexStore");
        return None;
    }
    let r = init_repo();
    write(&r.root, "Sources/App/Mailer.swift", MAILER);
    write(&r.root, "Sources/App/Use.swift", USE);
    write(&r.root, ".gitignore", ".build/\n");
    commit_all(&r.root, "init");
    let objs = r.root.join(".build/debug/obj");
    std::fs::create_dir_all(&objs).unwrap();
    let store = r.root.join(".build/debug/index/store");
    let out = Command::new("xcrun")
        .args(["swiftc", "-parse-as-library", "-c", "-module-name", "App", "-index-ignore-system-modules", "-index-store-path"])
        .arg(&store)
        .arg(r.root.join("Sources/App/Mailer.swift"))
        .arg(r.root.join("Sources/App/Use.swift"))
        .current_dir(&objs)
        .output()
        .ok()?;
    if !out.status.success() {
        eprintln!("skipped: swiftc failed: {}", String::from_utf8_lossy(&out.stderr));
        return None;
    }
    Some(r)
}

fn send_target(g: &ViewGraph, r: &Repo) -> (Option<u32>, Confidence) {
    target_of(g, r, "send")
}

fn target_of(g: &ViewGraph, r: &Repo, name: &str) -> (Option<u32>, Confidence) {
    let f = g.file_idx(&r.root.join("Sources/App/Use.swift")).unwrap();
    let i = g.file(f).facts.refs.iter().position(|x| g.name(x.name) == name).unwrap();
    let rr = &g.resolution(f).refs[i];
    (rr.target.map(|t| g.symbol(t).start_line), rr.confidence)
}

#[test]
fn a_store_is_found_where_swiftpm_writes_it() {
    let Some(r) = indexed_fixture() else { return };
    assert_eq!(indexstore::discover(&r.root), [r.root.join(".build/debug/index/store")]);
    assert!(indexstore::discover(Path::new("/nonexistent")).is_empty());
}

#[test]
fn the_compiler_picks_the_overload_the_ladder_cannot() {
    let Some(r) = indexed_fixture() else { return };
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    // Both overloads are members of `Mailer`; by name alone the ladder takes the first.
    assert_eq!(send_target(&e.graph(&v).unwrap(), &r), (Some(2), Confidence::Inferred));
    let (g, stats) = e.precise_graph(&v).unwrap().expect("a store covers this worktree");
    assert_eq!(stats.fresh_files, 2);
    assert_eq!(send_target(&g, &r), (Some(3), Confidence::Precise), "`send(_:to:)`, the one called");
}

#[test]
fn a_file_edited_since_the_build_keeps_the_heuristic_answer() {
    let Some(r) = indexed_fixture() else { return };
    let later = std::time::SystemTime::now() + std::time::Duration::from_secs(60);
    std::fs::File::options().append(true).open(r.root.join("Sources/App/Use.swift")).unwrap().set_modified(later).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let (g, stats) = e.precise_graph(&v).unwrap().expect("a store covers this worktree");
    assert_eq!((stats.fresh_files, stats.stale_files), (1, 1));
    assert_eq!(send_target(&g, &r), (Some(2), Confidence::Inferred), "the store's line numbers may no longer hold");
}

#[test]
fn a_reference_the_compiler_resolves_outside_the_repository_has_no_target() {
    let Some(r) = indexed_fixture() else { return };
    let dir = tempfile::tempdir().unwrap();
    let e = Engine::open(dir.path().join("store")).unwrap();
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    // An untyped receiver: by its unique name, `advanced` is guessed to be `Mailer.advanced`.
    assert_eq!(target_of(&e.graph(&v).unwrap(), &r, "advanced"), (Some(4), Confidence::Fallback));
    let (g, _) = e.precise_graph(&v).unwrap().unwrap();
    assert_eq!(target_of(&g, &r, "advanced"), (None, Confidence::Precise), "the standard library's `Int.advanced(by:)`");
}
