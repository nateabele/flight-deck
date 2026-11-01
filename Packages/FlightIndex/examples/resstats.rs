//! Per-language symbol, edge and reference-resolution counts, plus a file's direct dependencies and
//! dependents when given one: `cargo run --release --example resstats -- <path> <store> [file]...`.
use flightindex::engine::Engine;
use flightindex::graph::Confidence;
use flightindex::query::Direction;
use std::collections::BTreeMap;
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let e = Engine::open(&a[2]).unwrap();
    let v = e.view_for_path(std::path::Path::new(&a[1])).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let g = e.graph(&v).unwrap();
    // lang -> (files, symbols, files with an out edge, edges, exact, fallback, unresolved)
    let mut by: BTreeMap<&str, [u64; 7]> = BTreeMap::new();
    for i in 0..g.file_count() as u32 {
        let f = g.file(i);
        let r = g.resolution(i);
        let s = by.entry(f.language).or_default();
        s[0] += 1;
        s[1] += f.facts.symbols.len() as u64;
        s[2] += !r.edges.is_empty() as u64;
        s[3] += r.edges.len() as u64;
        for rr in &r.refs {
            match (rr.target, rr.confidence) {
                (Some(_), Confidence::Exact) => s[4] += 1,
                (Some(_), Confidence::Fallback) => s[5] += 1,
                _ => s[6] += 1,
            }
        }
    }
    for (l, s) in by {
        println!("{l}: files={} symbols={} files_with_out_edges={} edges={} refs exact={} fallback={} unresolved={}", s[0], s[1], s[2], s[3], s[4], s[5], s[6]);
    }
    for file in &a[3..] {
        for (label, dir) in [("depends on", Direction::Out), ("depended on by", Direction::In)] {
            let deps = g.file_deps(std::path::Path::new(&a[1]).join(file).as_path(), dir, 1).data.unwrap_or_default();
            println!("{file} {label} {} files: {}", deps.len(), deps.iter().take(8).map(|d| d.path.display().to_string().replace(&a[1], "")).collect::<Vec<_>>().join(", "));
        }
    }
}
