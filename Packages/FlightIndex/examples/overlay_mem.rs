//! What an overlay graph and a kept view cost in live heap:
//! `cargo run --release --example overlay_mem -- <store> <clean worktree> <dirty worktree>...`.
//!
//! Builds and caches the clean worktree's graph, then each dirty worktree's overlay graph, and
//! prints the live heap each overlay added (the counting allocator, so this is exact) next to its
//! estimated `own_bytes` and their parts. Then keeps a view of every worktree given (what the
//! daemon's watcher holds between requests) and prints the live heap per kept view.
use flightindex::alloc::live_bytes;
use flightindex::engine::Engine;
use flightindex::service::Freshness;
use std::path::Path;

fn mb(n: usize) -> String {
    format!("{:.2} MB", n as f64 / 1e6)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let e = Engine::open(&a[1]).unwrap();
    let clean = e.view_for_path(Path::new(&a[2])).unwrap();
    e.build(&clean, &[], |_| {}).unwrap();
    let dirty: Vec<_> = a[3..].iter().map(|w| e.view_for_path(Path::new(w)).unwrap()).collect();
    for v in &dirty {
        e.build(v, &[], |_| {}).unwrap();
    }
    let l0 = live_bytes();
    let base = e.graph(&clean).unwrap();
    println!("base graph: live +{} (own_bytes {})", mb(live_bytes() - l0), mb(base.own_bytes()));
    let mut graphs = Vec::new();
    let mut total = 0usize;
    for v in &dirty {
        let before = live_bytes();
        let g = e.graph(v).unwrap();
        let grew = live_bytes().saturating_sub(before);
        total += grew;
        let parts: Vec<String> = g.own_bytes_parts().iter().filter(|(_, n)| *n > 0).map(|(k, n)| format!("{k} {}", mb(*n))).collect();
        println!(
            "{}: {} overlay file(s), {} resolved; live +{}; own_bytes {} [{}]",
            v.label.worktree.file_name().unwrap().to_string_lossy(),
            v.overlay.len(),
            g.resolved_files(),
            mb(grew),
            mb(g.own_bytes()),
            parts.join(", ")
        );
        graphs.push(g);
    }
    if !dirty.is_empty() {
        println!("overlays: {} graphs, live +{} total, {} each", dirty.len(), mb(total), mb(total / dirty.len()));
    }
    let fresh = Freshness::new(true);
    let before = live_bytes();
    let n = a.len() - 2;
    let mut views = Vec::new();
    for w in &a[2..] {
        views.push(fresh.view(&e, Path::new(w)).unwrap());
    }
    drop(views);
    let kept = live_bytes().saturating_sub(before);
    println!("kept views: {n}, live +{} total, {} each", mb(kept), mb(kept / n));
}
