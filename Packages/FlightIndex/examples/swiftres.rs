//! Swift reference resolution, counted and scored against the build's index store:
//! `cargo run --release --example swiftres -- <worktree> <store> [top] [--no-sdk]`.
//!
//! Prints the Swift references by confidence (exact, inferred, fallback, package, unresolved),
//! the most frequent unresolved names by shape, and, when an index store covers the worktree
//! (`indexstore::discover`), precision and recall of the heuristic answers per confidence with the
//! compiler's answers as the key:
//! - an in-repository target is right when it is the symbol the compiler names;
//! - a package binding is right when the compiler resolves the reference outside the repository
//!   to a declaration of the same module and name (its USR, see `pkgview_swift::symbol_matches`);
//! - an unresolved reference the compiler resolves into the repository is a miss.
use flightindex::engine::Engine;
use flightindex::graph::Confidence;
use flightindex::indexstore;
use std::collections::{BTreeMap, HashMap};

fn main() {
    let mut a: Vec<String> = std::env::args().collect();
    // `--no-sdk`: the resolution without Swift package views, for a before/after on one checkout.
    if let Some(i) = a.iter().position(|x| x == "--no-sdk") {
        a.remove(i);
        flightindex::pkgview_swift::set_sdk(None);
    }
    let top: usize = a.get(3).and_then(|s| s.parse().ok()).unwrap_or(25);
    // `--warm`: parse the SDK modules flight-deck imports first, so `graph` times resolution alone.
    if let Some(i) = a.iter().position(|x| x == "--warm") {
        a.remove(i);
        if let Some(sdk) = flightindex::pkgview_swift::sdk() {
            let (t, c) = (std::time::Instant::now(), cpu_ms());
            let m = flightindex::pkgview_swift::closure(&sdk, &["Foundation", "SwiftUI", "AppKit", "XCTest", "UIKit", "Network", "OSLog", "CryptoKit", "Combine", "Security", "WebKit"]);
            println!("sdk warm: {} modules, {} ms wall, {} ms cpu", m.len(), t.elapsed().as_millis(), cpu_ms() - c);
        }
    }
    let e = Engine::open(&a[2]).unwrap();
    let root = std::path::Path::new(&a[1]);
    let v = e.view_for_path(root).unwrap();
    let t0 = std::time::Instant::now();
    e.build(&v, &[], |_| {}).unwrap();
    println!("build: {} ms", t0.elapsed().as_millis());
    let (t0, c0) = (std::time::Instant::now(), cpu_ms());
    let g = e.graph(&v).unwrap();
    println!("graph: {} ms wall, {} ms cpu", t0.elapsed().as_millis(), cpu_ms() - c0);
    let mut by: BTreeMap<&str, u64> = BTreeMap::new();
    let mut unresolved: HashMap<(String, &'static str), u64> = HashMap::new();
    let mut pkg_modules: BTreeMap<String, u64> = BTreeMap::new();
    for i in 0..g.files_len() as u32 {
        let f = g.file(i);
        if !f.alive || f.language != "swift" {
            continue;
        }
        let r = g.resolution(i);
        for (ri, (fr, rr)) in f.facts.refs.iter().zip(&r.refs).enumerate() {
            let k = match (rr.target, rr.confidence) {
                (_, Confidence::Package) => {
                    if let Some(s) = g.package_target(i, ri as u32) {
                        *pkg_modules.entry(s.module.to_string()).or_default() += 1;
                    }
                    "package"
                }
                (Some(_), Confidence::Exact) => "exact",
                (Some(_), Confidence::Fallback) => "fallback",
                (Some(_), Confidence::Inferred) => "inferred",
                (Some(_), Confidence::Precise) => "precise",
                _ => {
                    let name = g.name(fr.name);
                    let shape = match g.qualifier(fr) {
                        None if name.starts_with(|c: char| c.is_uppercase()) => "Type",
                        None => "bare",
                        Some("self" | "Self") => "self.",
                        Some(q) if q.rsplit('.').next().is_some_and(|l| l.starts_with(|c: char| c.is_uppercase())) => "Type.",
                        Some(_) => "recv.",
                    };
                    *unresolved.entry((name.to_string(), shape)).or_default() += 1;
                    if std::env::var("SWIFTRES_DEBUG").is_ok_and(|d| d == name) && unresolved[&(name.to_string(), shape)] <= 5 {
                        let imports: Vec<&str> = f.facts.imports.iter().map(|i| i.specifier.as_str()).collect();
                        println!("  debug {name}: {}:{} q={:?} imports={imports:?}", f.path, fr.line, g.qualifier(fr));
                    }
                    "unresolved"
                }
            };
            *by.entry(k).or_default() += 1;
        }
    }
    println!("swift refs: {by:?}");
    let mut shapes: BTreeMap<&str, u64> = BTreeMap::new();
    for ((_, s), n) in &unresolved {
        *shapes.entry(s).or_default() += n;
    }
    println!("unresolved by shape: {shapes:?}");
    let mut u: Vec<_> = unresolved.into_iter().collect();
    u.sort_by_key(|a| std::cmp::Reverse(a.1));
    for ((name, shape), n) in u.iter().take(top) {
        println!("  {n:>6} {shape:<6} {name}");
    }
    let mut pm: Vec<_> = pkg_modules.into_iter().collect();
    pm.sort_by_key(|a| std::cmp::Reverse(a.1));
    println!("package refs by module: {pm:?}");

    // ---- the index store as the answer key ----
    // The precise layer itself (`Engine::precise_graph`): what the compiler's answers replace.
    let (t2, c2) = (std::time::Instant::now(), cpu_ms());
    if let Ok(Some((pg, st))) = e.precise_graph(&v) {
        let mut by: BTreeMap<&str, u64> = BTreeMap::new();
        for i in 0..pg.files_len() as u32 {
            let f = pg.file(i);
            if f.alive && f.language == "swift" {
                for rr in &pg.resolution(i).refs {
                    *by.entry(conf(rr.target.is_some(), rr.confidence)).or_default() += 1;
                }
            }
        }
        println!("with the precise layer ({} fresh files, {} ms wall, {} ms cpu): {by:?}", st.fresh_files, t2.elapsed().as_millis(), cpu_ms() - c2);
    }
    let Some(store) = indexstore::discover(root).into_iter().next() else {
        println!("no index store covers {}", root.display());
        return;
    };
    let t1 = std::time::Instant::now();
    let key = match indexstore::read_with_external(&store, root) {
        Ok(k) => k,
        Err(err) => {
            println!("index store unreadable: {err}");
            return;
        }
    };
    println!("store {}: {:?}, read {} ms", store.display(), key.stats, t1.elapsed().as_millis());
    // confidence -> [right, wrong, not in key]
    let mut score: BTreeMap<&str, [u64; 3]> = BTreeMap::new();
    // compiler says "in the repository": [found by us, left unresolved, bound to a package]
    let mut recall = [0u64; 3];
    // compiler says "outside the repository": [we bound a package, we left it unresolved, we bound into the repository]
    let mut outside = [0u64; 3];
    let mut wrong_pkg: HashMap<String, u64> = HashMap::new();
    // Package bindings in a file the store covers but at a (line, name) it has no occurrence for.
    let mut unkeyed_pkg: HashMap<String, u64> = HashMap::new();
    for i in 0..g.files_len() as u32 {
        let f = g.file(i);
        if !f.alive || f.language != "swift" {
            continue;
        }
        let r = g.resolution(i);
        for (ri, (fr, rr)) in f.facts.refs.iter().zip(&r.refs).enumerate() {
            let name = g.name(fr.name);
            let Some(sites) = key.precise.lookup(&f.path, fr.line, name) else {
                let k = conf(rr.target.is_some(), rr.confidence);
                score.entry(k).or_default()[2] += 1;
                if let Some(s) = g.package_target(i, ri as u32)
                    && key.precise.covers(&f.path)
                {
                    *unkeyed_pkg.entry(s.display()).or_default() += 1;
                }
                continue;
            };
            let k = conf(rr.target.is_some(), rr.confidence);
            if sites.is_empty() {
                let usr = key.external_usr(&f.path, fr.line, name);
                match (rr.target, rr.confidence) {
                    (_, Confidence::Package) => {
                        outside[0] += 1;
                        let s = g.package_target(i, ri as u32).unwrap();
                        let ok = usr.is_some_and(|u| flightindex::pkgview_swift::symbol_matches(u, s));
                        let e = score.entry(k).or_default();
                        if ok {
                            e[0] += 1;
                        } else {
                            e[1] += 1;
                            *wrong_pkg.entry(format!("{}.{} [{}] vs {}", s.module, s.name, s.signature.as_deref().filter(|g| g.starts_with('@') || g.starts_with("c ")).unwrap_or(""), usr.unwrap_or("?"))).or_default() += 1;
                        }
                    }
                    (None, _) => {
                        outside[1] += 1;
                        score.entry(k).or_default()[0] += 1;
                    }
                    (Some(_), _) => {
                        outside[2] += 1;
                        score.entry(k).or_default()[1] += 1;
                    }
                }
                continue;
            }
            match (rr.target, rr.confidence) {
                (Some(t), _) => {
                    recall[0] += 1;
                    let tf = g.file(t.file);
                    let ts = g.symbol(t);
                    let ok = sites.iter().any(|s| *s.path == *tf.path && ts.start_line <= s.line && s.line <= ts.end_line);
                    score.entry(k).or_default()[if ok { 0 } else { 1 }] += 1;
                }
                (None, Confidence::Package) => {
                    recall[2] += 1;
                    score.entry(k).or_default()[1] += 1;
                }
                (None, _) => {
                    recall[1] += 1;
                    score.entry(k).or_default()[1] += 1;
                }
            }
        }
    }
    println!("scored against the store (right, wrong, not in key):");
    for (k, [r, w, n]) in &score {
        let p = if r + w > 0 { *r as f64 / (r + w) as f64 } else { 0.0 };
        println!("  {k:<10} right={r} wrong={w} precision={p:.3} not_in_key={n}");
    }
    let tot = recall.iter().sum::<u64>().max(1);
    println!("compiler -> repository: found={} unresolved={} bound_to_package={} recall={:.3}", recall[0], recall[1], recall[2], recall[0] as f64 / tot as f64);
    let tot = outside.iter().sum::<u64>().max(1);
    println!(
        "compiler -> outside: package={} unresolved={} bound_into_repo={} package_share={:.3}",
        outside[0],
        outside[1],
        outside[2],
        outside[0] as f64 / tot as f64
    );
    let mut w: Vec<_> = unkeyed_pkg.into_iter().collect();
    w.sort_by_key(|a| std::cmp::Reverse(a.1));
    for (s, n) in w.iter().take(top) {
        println!("  package, not in key {n:>5} {s}");
    }
    let mut w: Vec<_> = wrong_pkg.into_iter().collect();
    w.sort_by_key(|a| std::cmp::Reverse(a.1));
    for (s, n) in w.iter().take(top) {
        println!("  wrong package {n:>5} {s}");
    }
}

fn conf(target: bool, c: Confidence) -> &'static str {
    match (target, c) {
        (_, Confidence::Precise) => "precise",
        (_, Confidence::Package) => "package",
        (true, Confidence::Exact) => "exact",
        (true, Confidence::Fallback) => "fallback",
        (true, Confidence::Inferred) => "inferred",
        (false, _) => "unresolved",
    }
}

/// User plus system CPU time of this process so far: steadier than wall time on a loaded machine.
fn cpu_ms() -> u128 {
    // SAFETY: getrusage fills the struct it is given.
    let mut u: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut u) };
    let ms = |t: libc::timeval| t.tv_sec as u128 * 1000 + t.tv_usec as u128 / 1000;
    ms(u.ru_utime) + ms(u.ru_stime)
}
