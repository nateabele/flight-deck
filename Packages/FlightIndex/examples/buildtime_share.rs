//! Graph build time with every blob's facts already in memory:
//! `cargo run --release --example buildtime -- <store> <runs> <worktree> [<warm worktree>...]`.
//! Builds the first worktree's graph `runs` times from the same inputs and prints min / median ms,
//! both plainly (`ViewGraph::build`) and against a repository `Share` already holding the blocks of
//! the warm worktrees' graphs (`ViewGraph::build_shared`), which is what the daemon does.
use flightindex::engine::Engine;
use flightindex::git::FileRef;
use flightindex::graph::{Share, ViewGraph};
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

fn inputs(g: &ViewGraph) -> Vec<(FileRef, Arc<flightindex::facts::BlobFacts>)> {
    let mut v: Vec<_> = (0..g.files_len() as u32)
        .map(|i| g.file(i))
        .filter(|f| f.alive)
        .map(|f| (FileRef { path: f.path.clone(), blob_id: f.blob_id.clone(), language: f.language }, f.facts.clone()))
        .collect();
    v.sort_by(|a, b| a.0.path.cmp(&b.0.path));
    v
}

fn stats(mut ms: Vec<f64>) -> String {
    ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    format!("min {:.0} ms, median {:.0} ms", ms[0], ms[ms.len() / 2])
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let e = Engine::open(&a[1]).unwrap();
    let runs: usize = a[2].parse().unwrap();
    let graph = |wt: &str| {
        let v = e.view_for_path(Path::new(wt)).unwrap();
        e.build(&v, &[], |_| {}).unwrap();
        e.graph(&v).unwrap()
    };
    let target = graph(&a[3]);
    let label = target.label.clone();
    let inp = inputs(&target);
    let share = Arc::new(Share::new());
    let warm: Vec<ViewGraph> = a[4..].iter().map(|w| ViewGraph::build_shared(graph(w).label.clone(), inputs(&graph(w)), share.clone(), None)).collect();
    let mut plain = Vec::new();
    let mut shared = Vec::new();
    for _ in 0..runs {
        let t = Instant::now();
        drop(ViewGraph::build(label.clone(), inp.clone()));
        plain.push(t.elapsed().as_secs_f64() * 1000.0);
        let t = Instant::now();
        let g = ViewGraph::build_shared(label.clone(), inp.clone(), share.clone(), None);
        shared.push(t.elapsed().as_secs_f64() * 1000.0);
        drop(g);
    }
    println!("{} files; plain: {}; shared ({} warm graphs): {}", inp.len(), stats(plain), warm.len(), stats(shared));
}
