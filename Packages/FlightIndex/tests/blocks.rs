//! Per-file resolved blocks are hash-consed: the graphs of two commits of one repository hold one
//! copy of every file resolution that came out the same, and never share one that did not.
mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::graph::ViewGraph;
use std::path::Path;
use std::sync::Arc;

fn graph(e: &Engine, root: &Path) -> Arc<ViewGraph> {
    let v = e.view_for_path(root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    e.graph(&v).unwrap()
}

fn idx(g: &ViewGraph, p: &str) -> u32 {
    g.file_idx(Path::new(p)).unwrap_or_else(|| panic!("no {p}"))
}

fn fixture() -> Repo {
    let r = init_repo();
    write(&r.root, "lib.ts", "export function helper() {}\nexport function other() {}\n");
    write(&r.root, "app.ts", "import { helper } from './lib';\nexport function main() { helper(); stray(); }\n");
    write(&r.root, "loose.js", "function stray() {}\n");
    write(&r.root, "edit.ts", "export function edited() { return 1; }\n");
    commit_all(&r.root, "one");
    r
}

/// Store and engine in one temp dir, so each test drives its own graph cache.
fn engine() -> (tempfile::TempDir, Engine) {
    let d = tempfile::tempdir().unwrap();
    let e = Engine::open(d.path().join("store")).unwrap();
    (d, e)
}

#[test]
fn nearby_commits_share_the_blocks_of_files_whose_resolution_did_not_change() {
    let (_d, e) = engine();
    let r = fixture();
    let g1 = graph(&e, &r.root);
    // A file that sorts first is added and an unrelated one edited: in a graph that numbers its
    // files 0..n by path every index moves, so only a per-repository numbering keeps them.
    write(&r.root, "0first.ts", "export function first() {}\n");
    write(&r.root, "edit.ts", "export function edited() { return 2; }\nexport function more() {}\n");
    commit_all(&r.root, "two");
    let g2 = graph(&e, &r.root);
    for p in ["lib.ts", "app.ts", "loose.js"] {
        assert_eq!(idx(&g1, p), idx(&g2, p), "{p} keeps its file index across commits");
        assert!(std::ptr::eq(g1.resolution(idx(&g1, p)), g2.resolution(idx(&g2, p))), "{p}'s block is shared, not copied");
    }
    assert!(!std::ptr::eq(g1.resolution(idx(&g1, "edit.ts")), g2.resolution(idx(&g2, "edit.ts"))) || g1.resolution(idx(&g1, "edit.ts")).refs.is_empty());
}

#[test]
fn a_graph_laid_out_around_another_commits_files_equals_a_fresh_build() {
    let (_d, e) = engine();
    let r = fixture();
    let _g1 = graph(&e, &r.root);
    std::fs::remove_file(r.root.join("loose.js")).unwrap();
    write(&r.root, "0first.ts", "import { other } from './lib';\nexport function first() { other(); }\n");
    commit_all(&r.root, "two");
    // The second graph has a hole where loose.js was, and 0first.ts after every first-commit file.
    let g2 = graph(&e, &r.root);
    let (_d2, fresh) = engine();
    let full = graph(&fresh, &r.root);
    assert_eq!(g2.fingerprint(), full.fingerprint());
    assert_eq!(g2.file_count(), full.file_count());
    assert_eq!(g2.stats().data.files, full.stats().data.files);
}

#[test]
fn a_block_whose_fallback_answer_changed_is_not_shared() {
    let (_d, e) = engine();
    let r = fixture();
    let g1 = graph(&e, &r.root);
    let app1 = g1.resolution(idx(&g1, "app.ts"));
    assert!(app1.refs.iter().any(|x| x.target.is_some() && x.confidence == flightindex::graph::Confidence::Fallback), "stray() is a fallback");
    // app.ts is byte-identical, but `stray` now has two definitions: the fallback must not answer.
    write(&r.root, "loose2.js", "function stray() {}\n");
    commit_all(&r.root, "two");
    let g2 = graph(&e, &r.root);
    let app2 = g2.resolution(idx(&g2, "app.ts"));
    assert!(!std::ptr::eq(app1, app2));
    assert!(app2.refs.iter().all(|x| x.confidence != flightindex::graph::Confidence::Fallback));
    let (_d2, fresh) = engine();
    assert_eq!(g2.fingerprint(), graph(&fresh, &r.root).fingerprint());
}

#[test]
fn the_cache_charges_a_shared_block_once() {
    let (_d, e) = engine();
    let r = fixture();
    let _g1 = graph(&e, &r.root);
    let one = e.graph_cache_stats();
    write(&r.root, "edit.ts", "export function edited() { return 2; }\n");
    commit_all(&r.root, "two");
    let _g2 = graph(&e, &r.root);
    let two = e.graph_cache_stats();
    assert_eq!(two.graphs, 2);
    // Four files in each graph, three resolutions identical across commits: one more block at most.
    // Within one graph the files that import and reference nothing share one empty block too.
    assert!(one.blocks < 4 && two.blocks <= one.blocks + 1, "{} -> {} blocks", one.blocks, two.blocks);
    assert!(two.block_bytes < 2 * one.block_bytes);
}
