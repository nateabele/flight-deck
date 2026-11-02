//! What an overlay graph costs next to its base. A worktree with a few edited files gets a graph
//! derived from its base commit's (`ViewGraph::with_changes`). Its per-file blocks were already
//! shared; its indexes (names, incoming references, importers, paths) were whole copies, 6.5 MB a
//! dirty tessera worktree against 0.1 MB of resolutions that actually differ. An overlay should
//! own about what its edit changed, not another copy of the repository.
//!
//! The counting allocator is process-wide, so this file holds a single test: nothing else runs in
//! the process while it measures.
mod common;
use common::*;
use flightindex::alloc::live_bytes;
use flightindex::engine::Engine;

#[test]
fn an_overlay_graph_owns_little_more_than_what_its_edit_changed() {
    let r = init_repo();
    const FILES: usize = 400;
    for i in 0..FILES {
        // Each file defines a few functions and calls into the previous file and the first.
        let prev = if i == 0 { 0 } else { i - 1 };
        write(
            &r.root,
            &format!("src/m{i:03}.ts"),
            &format!(
                "import {{ f{prev}, g{prev} }} from './m{prev:03}';\nimport {{ f0 }} from './m000';\nexport function f{i}() {{ return f{prev}() + f0(); }}\nexport function g{i}() {{ return g{prev}() + f{i}(); }}\nexport function h{i}() {{ return g{i}() + f{i}() + h{i}(); }}\n"
            ),
        );
    }
    commit_all(&r.root, "init");
    let d = tempfile::tempdir().unwrap();
    let e = Engine::open(d.path().join("store")).unwrap();
    let clean = e.view_for_path(&r.root).unwrap();
    e.build(&clean, &[], |_| {}).unwrap();
    let base = e.graph(&clean).unwrap();
    // What the base graph owns beyond the facts and blocks every graph of the repository shares.
    let base_bytes = base.own_bytes();

    // A body edit in the middle of the chain: a new function, nothing else moves.
    let p = r.root.join("src/m200.ts");
    let mut text = std::fs::read_to_string(&p).unwrap();
    text.push_str("export function probe() { return f0(); }\n");
    std::fs::write(&p, text).unwrap();
    let dirty = e.view_for_path(&r.root).unwrap();
    e.build(&dirty, &[], |_| {}).unwrap();
    let before = live_bytes();
    let overlay = e.graph(&dirty).unwrap();
    let overlay_bytes = live_bytes().saturating_sub(before);
    assert!(overlay.resolved_files() < 10);
    assert!(
        overlay_bytes * 2 < base_bytes,
        "the overlay graph holds {overlay_bytes} bytes against the {base_bytes} its base graph owns"
    );
    drop(base);
}
