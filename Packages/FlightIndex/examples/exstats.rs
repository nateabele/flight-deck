//! Elixir reference resolution on a real repository: exact / fallback / package / unresolved per
//! language, the unresolved Elixir references grouped by qualifier, and a random sample of package
//! bindings to check by hand.
//! `cargo run --release --example exstats -- <path> <store> [sample_n]`.
use flightindex::engine::Engine;
use flightindex::graph::Confidence;
use std::collections::{BTreeMap, HashMap};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let sample_n: usize = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(40);
    let e = Engine::open(&a[2]).unwrap();
    let v = e.view_for_path(std::path::Path::new(&a[1])).unwrap();
    if let Ok(dir) = std::env::var("EXSTATS_LOCK_DIR") {
        // The package views alone, cold: the standard library, then one project's dependencies.
        let heap0 = flightindex::alloc::live_bytes();
        let t = std::time::Instant::now();
        let _ = flightindex::hexview::bare_project();
        let stdlib = t.elapsed();
        let lock = std::fs::read_to_string(std::path::Path::new(&a[1]).join(&dir).join("mix.lock")).unwrap_or_default();
        let t = std::time::Instant::now();
        let p = flightindex::hexview::project(std::path::Path::new(&a[1]), std::path::Path::new(&dir), &lock);
        let st = flightindex::hexview::stats();
        let ms = t.elapsed().as_millis();
        eprintln!("stdlib {} ms; project ({} packages, {} modules) {ms} ms; {} names parsed; heap +{} bytes", stdlib.as_millis(), p.packages.len(), p.modules.len(), st.names, flightindex::alloc::live_bytes() - heap0);
    }
    let t = std::time::Instant::now();
    e.build(&v, &[], |_| {}).unwrap();
    let g = e.graph(&v).unwrap();
    eprintln!("build+graph {} ms; own_bytes {}", t.elapsed().as_millis(), g.own_bytes());
    // lang -> (exact, fallback, package, unresolved)
    let mut by: BTreeMap<&str, [u64; 4]> = BTreeMap::new();
    let mut unres_q: HashMap<String, u64> = HashMap::new();
    let mut pkg_by: HashMap<String, u64> = HashMap::new();
    let mut samples: Vec<String> = Vec::new();
    let mut bare_samples: Vec<String> = Vec::new();
    let mut bare_by: HashMap<String, u64> = HashMap::new();
    let mut seed: u64 = 0x9e3779b97f4a7c15;
    // EXSTATS_DUMP=<file>: every Elixir reference and what it resolved to, to diff two builds.
    let mut dump: Vec<String> = Vec::new();
    for i in 0..g.files_len() as u32 {
        let f = g.file(i);
        if !f.alive {
            continue;
        }
        let r = g.resolution(i);
        let s = by.entry(f.language).or_default();
        for (ri, (rr, fr)) in r.refs.iter().zip(&f.facts.refs).enumerate() {
            let slot = match (rr.target, rr.confidence) {
                (Some(_), Confidence::Fallback) => 1,
                (Some(_), _) => 0,
                (None, Confidence::Package) => 2,
                _ => 3,
            };
            s[slot] += 1;
            if f.language != "elixir" {
                continue;
            }
            let q = g.qualifier(fr).map(str::to_string);
            let name = g.name(fr.name);
            let to = match (rr.target, slot) {
                (Some(t), 1) => format!("fallback {}:{}", g.file(t.file).path, g.symbol(t).name),
                (Some(t), _) => format!("exact {}:{}", g.file(t.file).path, g.symbol(t).name),
                (None, 2) => format!("package {}", g.package_target(i, ri as u32).map(|p| p.display()).unwrap_or_default()),
                _ => "none".to_string(),
            };
            dump.push(format!("{}:{}\t{}{}\t{to}", f.path, fr.line, q.as_deref().map(|q| format!("{q}.")).unwrap_or_default(), name));
            if slot == 3 && rr.external.is_none() {
                let key = match &q {
                    Some(q) => format!("{q}.*"),
                    None if name.starts_with(|c: char| c.is_uppercase()) => format!("<module> {name}"),
                    None => format!("<bare> {name}"),
                };
                *unres_q.entry(key).or_default() += 1;
            }
            if slot == 2 {
                let p = g.package_target(i, ri as u32).unwrap();
                *pkg_by.entry(p.package.to_string()).or_default() += 1;
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                let written = match &q {
                    Some(q) => format!("{q}.{name}"),
                    None => name.to_string(),
                };
                let row = format!("{}:{} `{written}` -> {}", f.path, fr.line, p.display());
                if q.is_none() && !name.starts_with(|c: char| c.is_uppercase()) {
                    *bare_by.entry(format!("{} {}", p.package, p.module)).or_default() += 1;
                    if seed.is_multiple_of(89) && bare_samples.len() < sample_n {
                        bare_samples.push(row);
                    }
                } else if seed.is_multiple_of(97) && samples.len() < sample_n {
                    samples.push(row);
                }
            }
        }
    }
    if let Some(path) = std::env::var_os("EXSTATS_DUMP") {
        dump.sort();
        std::fs::write(path, dump.join("\n")).unwrap();
    }
    for (l, s) in &by {
        println!("{l}: exact={} fallback={} package={} unresolved={}", s[0], s[1], s[2], s[3]);
    }
    let mut v: Vec<_> = unres_q.into_iter().collect();
    v.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    println!("\nelixir unresolved by qualifier (top 60 of {}):", v.len());
    for (k, n) in v.iter().take(60) {
        println!("{n:>7} {k}");
    }
    let mut p: Vec<_> = pkg_by.into_iter().collect();
    p.sort_by_key(|x| std::cmp::Reverse(x.1));
    println!("\nelixir package refs by package:");
    for (k, n) in p.iter().take(40) {
        println!("{n:>7} {k}");
    }
    let mut b: Vec<_> = bare_by.into_iter().collect();
    b.sort_by_key(|x| std::cmp::Reverse(x.1));
    println!("\nbare (unqualified) package refs by module:");
    for (k, n) in b.iter().take(25) {
        println!("{n:>7} {k}");
    }
    println!("\nsample of qualified package bindings:");
    for s in samples {
        println!("  {s}");
    }
    println!("\nsample of bare package bindings:");
    for s in bare_samples {
        println!("  {s}");
    }
}
