//! TypeScript/JavaScript reference resolution in one view, split by why a reference is unresolved:
//! `cargo run --release --example ecma_refs -- <path> <store> [sample]`.
//!
//! Per language: exact, fallback, package and unresolved counts; unresolved split into references
//! whose name or qualifier an import of a bare specifier (`react`, `@scope/pkg`) binds, and the
//! rest. Then the top unresolved names of each kind, and `sample` (default 0) random package
//! bindings (`file line qualifier name package symbol`, tab-separated) for a wrong-binding check.
use flightindex::engine::Engine;
use flightindex::graph::Confidence;
use std::collections::{BTreeMap, HashMap};

fn bare(spec: &str) -> bool {
    !(spec.starts_with('.') || spec.starts_with('/'))
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let sample: usize = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(0);
    let e = Engine::open(&a[2]).unwrap();
    let v = e.view_for_path(std::path::Path::new(&a[1])).unwrap();
    let t = std::time::Instant::now();
    e.build(&v, &[], |_| {}).unwrap();
    eprintln!("build {:?}", t.elapsed());
    // Graph resolution twice, each from a fresh engine: the first parses whatever package
    // declarations it needs, the second finds them in the process-wide cache.
    let live = flightindex::alloc::live_bytes();
    for pass in ["cold", "warm"] {
        let e2 = Engine::open(&a[2]).unwrap();
        let v2 = e2.view_for_path(std::path::Path::new(&a[1])).unwrap();
        let (t, cpu) = (std::time::Instant::now(), cpu_ms());
        let g2 = e2.graph(&v2).unwrap();
        println!("graph {pass}: wall {:.0} ms, process cpu {:.0} ms, own_bytes {}", t.elapsed().as_secs_f64() * 1e3, cpu_ms() - cpu, g2.own_bytes());
    }
    // Both engines are gone: what stays live is the process-wide package caches.
    println!("live heap after both passes: +{} bytes", flightindex::alloc::live_bytes() as i64 - live as i64);
    let g = e.graph(&v).unwrap();
    // lang -> [exact, fallback, package, unresolved via bare import, other unresolved]
    let mut by: BTreeMap<&str, [u64; 5]> = BTreeMap::new();
    let mut top_pkg: HashMap<String, u64> = HashMap::new();
    let mut top_other: HashMap<String, u64> = HashMap::new();
    let mut bound: Vec<String> = Vec::new();
    for i in 0..g.files_len() as u32 {
        let f = g.file(i);
        if !f.alive || !matches!(f.language, "typescript" | "tsx" | "javascript") {
            continue;
        }
        let r = g.resolution(i);
        let mut via_pkg: HashMap<&str, &str> = HashMap::new();
        for imp in f.facts.imports.iter().filter(|i| bare(&i.specifier)) {
            if let Some(al) = &imp.alias {
                via_pkg.insert(al, &imp.specifier);
            }
            for n in &imp.names {
                via_pkg.insert(n.local(), &imp.specifier);
            }
        }
        let s = by.entry(f.language).or_default();
        for (ri, (rr, fr)) in r.refs.iter().zip(&f.facts.refs).enumerate() {
            let name = g.name(fr.name);
            let q = g.qualifier(fr);
            match (rr.target, rr.confidence) {
                (Some(_), Confidence::Fallback) => s[1] += 1,
                (_, Confidence::Package) => {
                    s[2] += 1;
                    if let Some(sym) = g.package_target(i, ri as u32) {
                        // Tab-separated, for a script to check against the TypeScript checker.
                        bound.push(format!("{}\t{}\t{}\t{}\t{}\t{}", f.path, fr.line, q.unwrap_or(""), name, sym.package.name, sym.name));
                    }
                }
                (Some(_), _) => s[0] += 1,
                (None, _) if rr.external.is_some() => s[0] += 1,
                (None, _) => {
                    let key = q.unwrap_or(name);
                    let label = format!("{}{}", q.map(|q| format!("{q}.")).unwrap_or_default(), name);
                    if let Some(spec) = via_pkg.get(key) {
                        s[3] += 1;
                        *top_pkg.entry(format!("{spec} :: {label}")).or_default() += 1;
                    } else {
                        s[4] += 1;
                        *top_other.entry(label).or_default() += 1;
                    }
                }
            }
        }
    }
    for (l, s) in &by {
        println!("{l}: exact={} fallback={} package={} unresolved={} (bare-import {} other {})", s[0], s[1], s[2], s[3] + s[4], s[3], s[4]);
    }
    for (title, m) in [("unresolved through a bare import", &top_pkg), ("other unresolved", &top_other)] {
        let mut v: Vec<_> = m.iter().collect();
        v.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
        println!("-- top {title}");
        for (k, n) in v.iter().take(40) {
            println!("{n:>7} {k}");
        }
    }
    if sample > 0 && !bound.is_empty() {
        println!("-- {sample} sampled package bindings of {}", bound.len());
        // A fixed-step sample: reproducible without a random number crate.
        let step = (bound.len() / sample).max(1);
        for b in bound.iter().step_by(step).take(sample) {
            println!("{b}");
        }
    }
}

/// User plus system CPU time of this process so far.
fn cpu_ms() -> f64 {
    let mut u: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) };
    let ms = |t: libc::timeval| t.tv_sec as f64 * 1e3 + t.tv_usec as f64 / 1e3;
    ms(u.ru_utime) + ms(u.ru_stime)
}
