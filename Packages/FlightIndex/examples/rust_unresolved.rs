//! Rust reference resolution on a real repository: exact, fallback, package and unresolved
//! counts, the most frequent unresolved shapes, and a sample of package bindings to check by
//! hand. `cargo run --release --example rust_unresolved -- <worktree> <store> [sample-size]`.
use flightindex::engine::Engine;
use flightindex::graph::Confidence;
use std::collections::HashMap;

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let sample: usize = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(40);
    let e = Engine::open(&a[2]).unwrap();
    let v = e.view_for_path(std::path::Path::new(&a[1])).unwrap();
    let t = std::time::Instant::now();
    e.build(&v, &[], |_| {}).unwrap();
    let parsed = t.elapsed();
    let live = flightindex::alloc::live_bytes;
    let (t, h0) = (std::time::Instant::now(), live());
    let g = e.graph(&v).unwrap();
    let (first, h1) = (t.elapsed(), live());
    // The same graph again from a second engine on the store: package views already loaded.
    let e2 = Engine::open(&a[2]).unwrap();
    let v2 = e2.view_for_path(std::path::Path::new(&a[1])).unwrap();
    let t = std::time::Instant::now();
    let g2 = e2.graph(&v2).unwrap();
    let (warm, h2) = (t.elapsed(), live());
    drop(g2);
    // The first graph's heap growth holds the crate views too; the second's is a graph alone.
    let mb = |b: usize| b as f64 / 1048576.0;
    println!("heap: first graph +{:.1} MB, second graph +{:.1} MB, so crate views about {:.1} MB", mb(h1 - h0), mb(h2 - h1), mb((h1 - h0).saturating_sub(h2 - h1)));
    let st = flightindex::pkgview::stats().crates;
    println!("build {parsed:?}, first graph {first:?}, graph with crate views loaded {warm:?}; crates {} names {} heap live {:.1} MB", st.crates, st.names, flightindex::alloc::live_bytes() as f64 / 1048576.0);
    if !st.missing.is_empty() {
        println!("not read: {}", st.missing.join(", "));
    }
    let (mut exact, mut fallback, mut package, mut none) = (0u64, 0u64, 0u64, 0u64);
    let mut shapes: HashMap<String, u64> = HashMap::new();
    let mut pkg_names: HashMap<String, u64> = HashMap::new();
    let mut lower_q: HashMap<String, u64> = HashMap::new();
    let mut picks = Vec::new();
    let mut n_pkg = 0u64;
    for i in 0..g.files_len() as u32 {
        let f = g.file(i);
        if !f.alive || f.language != "rust" {
            continue;
        }
        let r = g.resolution(i);
        for (ri, (fr, rr)) in f.facts.refs.iter().zip(&r.refs).enumerate() {
            match (rr.target, rr.confidence) {
                (Some(_), Confidence::Fallback) => fallback += 1,
                (Some(_), _) => exact += 1,
                (None, Confidence::Package) => {
                    package += 1;
                    let s = g.package_target(i, ri as u32).unwrap();
                    *pkg_names.entry(s.package.name.clone()).or_default() += 1;
                    // A one-word lowercase qualifier is also how a method call on a local reads
                    // (`json.get()`): the binding to audit.
                    if let Some(q) = g.qualifier(fr).filter(|q| !q.contains("::") && q.starts_with(|c: char| c.is_lowercase())) {
                        *lower_q.entry(format!("{q}::{} -> {}", g.name(fr.name), s.display())).or_default() += 1;
                    }
                    n_pkg += 1;
                    // Deterministic spread over the repository: every 293rd package reference.
                    if n_pkg.is_multiple_of(293) && picks.len() < sample {
                        let q = g.qualifier(fr).map(|q| format!("{q}::")).unwrap_or_default();
                        picks.push(format!("{}:{} {q}{} -> {}", f.path, fr.line, g.name(fr.name), s.display()));
                    }
                }
                (None, _) if rr.external.is_some() => exact += 1,
                (None, _) => {
                    none += 1;
                    let q = match g.qualifier(fr) {
                        None => String::new(),
                        Some(q) if q.contains("::") || q.chars().next().is_some_and(|c| c.is_uppercase()) => format!("{q}::"),
                        Some(_) => "<recv>.".to_string(),
                    };
                    *shapes.entry(format!("{:?} {q}{}", fr.kind, g.name(fr.name))).or_default() += 1;
                }
            }
        }
    }
    println!("rust refs exact={exact} fallback={fallback} package={package} unresolved={none}");
    let mut top: Vec<_> = shapes.into_iter().collect();
    top.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    println!("top unresolved:");
    for (s, n) in top.iter().take(40) {
        println!("  {n:6} {s}");
    }
    let mut pk: Vec<_> = pkg_names.into_iter().collect();
    pk.sort_by_key(|a| std::cmp::Reverse(a.1));
    println!("package refs by crate: {}", pk.iter().take(15).map(|(n, c)| format!("{n}={c}")).collect::<Vec<_>>().join(" "));
    let mut lq: Vec<_> = lower_q.into_iter().collect();
    lq.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    println!("package refs through a lowercase one-word qualifier: {} ({} distinct)", lq.iter().map(|x| x.1).sum::<u64>(), lq.len());
    for (k, n) in lq.iter().take(40) {
        println!("  {n:5} {k}");
    }
    println!("sample:");
    for p in picks {
        println!("  {p}");
    }
}
