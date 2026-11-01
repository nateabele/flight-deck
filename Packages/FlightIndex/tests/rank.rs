//! PageRank solved to a tolerance, warm-started from a nearby graph (proposal #10).
mod common;
use common::*;
use flightindex::engine::Engine;
use flightindex::graph::rank::{pagerank, solve, solve_with, TOL};
use flightindex::graph::ViewGraph;
use flightindex::query::NameMatch;
use std::path::Path;

/// The model, written the slow obvious way and run far past convergence: the oracle.
fn reference(edges: &[Vec<u32>], alive: &[bool]) -> Vec<f64> {
    let live = alive.iter().filter(|a| **a).count() as f64;
    let d = 0.85;
    let mut r: Vec<f64> = alive.iter().map(|a| if *a { 1.0 / live } else { 0.0 }).collect();
    for _ in 0..3000 {
        let mut next: Vec<f64> = alive.iter().map(|a| if *a { (1.0 - d) / live } else { 0.0 }).collect();
        let mut dangling = 0.0;
        for (u, out) in edges.iter().enumerate().filter(|(u, _)| alive[*u]) {
            let outs: Vec<u32> = out.iter().copied().filter(|t| alive[*t as usize]).collect();
            if outs.is_empty() {
                dangling += r[u];
            }
            for t in &outs {
                next[*t as usize] += d * r[u] / outs.len() as f64;
            }
        }
        for (v, x) in next.iter_mut().enumerate() {
            if alive[v] {
                *x += d * dangling / live;
            }
        }
        r = next;
    }
    r
}

fn l1(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b).map(|(x, y)| (x - y).abs()).sum()
}

/// Deterministic pseudo-random graph shaped like a call graph: most vertices dangle (leaf
/// functions), a few hubs, some cycles, one long chain.
fn graph(n: usize, seed: u64) -> Vec<Vec<u32>> {
    let mut s = seed;
    let mut next = move || {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        s
    };
    let mut edges = vec![Vec::new(); n];
    for (u, out) in edges.iter_mut().enumerate() {
        if next() % 3 == 0 {
            continue;
        }
        for _ in 0..(next() % 6) {
            let t = if next() % 4 == 0 { next() % 8 } else { next() % n as u64 };
            if t as usize != u {
                out.push(t as u32);
            }
        }
    }
    for (u, out) in edges.iter_mut().enumerate().skip(n / 2).take(60) {
        out.push(u as u32 + 1);
    }
    edges
}

const AGREE: f64 = 20.0 * TOL;

#[test]
fn a_cold_solve_converges_on_a_long_chain_where_thirty_sweeps_did_not() {
    // A 400-vertex chain ending in a dangling sink: rank keeps flowing down it for hundreds of
    // sweeps, so the old fixed 30 sweeps stopped with ranks far from the fixed point.
    let n = 400;
    let edges: Vec<Vec<u32>> = (0..n as u32).map(|u| if u + 1 < n as u32 { vec![u + 1] } else { vec![] }).collect();
    let alive = vec![true; n];
    let want = reference(&edges, &alive);
    let got = pagerank(&edges, &alive);
    assert!(l1(&got, &want) < AGREE, "L1 {} from the fixed point", l1(&got, &want));
}

#[test]
fn a_cold_solve_matches_the_model_with_dead_and_dangling_vertices() {
    let edges = graph(3000, 7);
    let mut alive = vec![true; edges.len()];
    for v in (0..edges.len()).step_by(37) {
        alive[v] = false;
    }
    let got = pagerank(&edges, &alive);
    assert!(l1(&got, &reference(&edges, &alive)) < AGREE);
    assert!(got.iter().zip(&alive).all(|(r, a)| *a || *r == 0.0), "dead vertices hold no rank");
    assert!((got.iter().sum::<f64>() - 1.0).abs() < 1e-9);
}

/// `edges` with a few vertices rewired and `added` new vertices wired in, like a commit that
/// edits a handful of functions and adds some.
fn perturb(edges: &[Vec<u32>], added: usize) -> Vec<Vec<u32>> {
    let mut e = edges.to_vec();
    let n = e.len();
    for u in [11usize, 500, 1203, 2999] {
        e[u] = vec![(u as u32 * 7) % n as u32, 3];
    }
    for i in 0..added {
        e.push(vec![(i as u32 * 13) % n as u32]);
        e[(i * 101) % n].push((n + i) as u32);
    }
    e
}

#[test]
fn a_warm_solve_agrees_with_a_cold_one_in_far_fewer_sweeps() {
    let old = graph(3000, 11);
    let (old_rank, old_stats) = solve(&old, &vec![true; old.len()], None);
    let new = perturb(&old, 5);
    let alive = vec![true; new.len()];
    let mut prior = old_rank.clone();
    prior.resize(new.len(), f64::NAN); // the added vertices are new
    let (cold, cs) = solve(&new, &alive, None);
    let (warm, ws) = solve(&new, &alive, Some((&prior, old_stats.scale)));
    assert!(ws.warm && !cs.warm);
    assert!(l1(&warm, &cold) < AGREE, "warm vs cold L1 {}", l1(&warm, &cold));
    assert!(l1(&warm, &reference(&new, &alive)) < AGREE);
    // Dynamic Frontier: the change reaches a fraction of the graph, and the closing full sweeps
    // pass at once, so a warm solve does a few full sweeps plus local work.
    assert!(ws.frontier_updates > 0, "{ws:?}");
    assert!(ws.sweeps <= 3 && cs.sweeps >= 15, "warm {ws:?} cold {cs:?}");
    assert!((ws.frontier_updates as usize) < 5 * new.len(), "{ws:?}");
}

#[test]
fn a_wrong_prior_still_gives_the_cold_answer() {
    let edges = graph(2000, 3);
    let alive = vec![true; edges.len()];
    let cold = pagerank(&edges, &alive);
    let reversed: Vec<f64> = cold.iter().rev().copied().collect();
    let nan = vec![f64::NAN; edges.len()];
    for (prior, scale) in [(&reversed, 0.0), (&reversed, 1e6), (&nan, 5.0), (&cold, 0.0)] {
        for frontier in [true, false] {
            let (got, _) = solve_with(&edges, &alive, Some((prior, scale)), frontier);
            assert!(l1(&got, &cold) < AGREE, "scale {scale} frontier {frontier}: L1 {}", l1(&got, &cold));
        }
    }
    // A prior of the wrong length is ignored rather than misapplied.
    let (got, s) = solve(&edges, &alive, Some((&cold[..10], 1.0)));
    assert!(!s.warm && l1(&got, &cold) < AGREE);
}

// ---- through the engine ------------------------------------------------------------------------

fn fixture() -> Repo {
    let r = init_repo();
    write(&r.root, "Cargo.toml", "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n");
    let mods: String = (0..8).map(|i| format!("pub mod m{i};\n")).collect();
    write(&r.root, "src/lib.rs", &format!("{mods}pub fn root() {{ m0::f0(); m1::f1(); }}\n"));
    for i in 0..8 {
        let body: String = (0..4).map(|j| format!("pub fn f{j}() {{ crate::m{}::f{}(); }}\n", (i + j + 1) % 8, (i * j) % 4)).collect();
        write(&r.root, &format!("src/m{i}.rs"), &body);
    }
    commit_all(&r.root, "init");
    r
}

fn ranks(g: &ViewGraph, root: &Path) -> Vec<f64> {
    let mut out: Vec<f64> = std::iter::once("src/lib.rs".to_string()).chain((0..8).map(|i| format!("src/m{i}.rs"))).map(|p| g.file_rank_of(&root.join(p)).unwrap_or(-1.0)).collect();
    let mut syms = g.find_symbols(&NameMatch::Regex(regex::Regex::new("^(f[0-9]|root|extra)$").unwrap()), None, 1000).data;
    syms.sort_by(|a, b| (&a.path, &a.name).cmp(&(&b.path, &b.name)));
    out.extend(syms.iter().map(|h| h.rank));
    out
}

#[test]
fn a_new_commit_graph_warm_starts_from_the_cached_one_and_matches_a_cold_build() {
    let r = fixture();
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let first = e.graph(&v).unwrap();
    assert!(!first.rank_stats[0].warm && !first.rank_stats[1].warm, "nothing cached to start from");

    write(&r.root, "src/m3.rs", "pub fn f0() { crate::m5::f2(); }\npub fn f1() {}\npub fn f2() { crate::m0::f0(); }\npub fn f3() {}\npub fn extra() { f1(); }\n");
    commit_all(&r.root, "edit m3");
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    let warm = e.graph(&v).unwrap();
    assert!(warm.rank_stats[0].warm && warm.rank_stats[1].warm, "{:?}", warm.rank_stats);

    let e2 = Engine::open(&store).unwrap(); // empty graph cache: a cold build of the same commit
    let cold = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert!(!cold.rank_stats[1].warm);
    let (w, c) = (ranks(&warm, &r.root), ranks(&cold, &r.root));
    assert_eq!(w.len(), c.len());
    assert!(l1(&w, &c) < 2.0 * AGREE, "warm {w:?}\ncold {c:?}");
}

#[test]
fn an_overlay_graph_warm_starts_from_its_base_and_matches_a_cold_build() {
    let r = fixture();
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    let e = Engine::open(&store).unwrap();
    let v = e.view_for_path(&r.root).unwrap();
    e.build(&v, &[], |_| {}).unwrap();
    e.graph(&v).unwrap();

    write(&r.root, "src/m6.rs", "pub fn f0() { crate::m1::f1(); crate::m2::f2(); }\npub fn f1() {}\npub fn f2() {}\npub fn f3() { f0(); }\n");
    let v = e.view_for_path(&r.root).unwrap();
    assert!(v.label.dirty);
    e.build(&v, &[], |_| {}).unwrap();
    let warm = e.graph(&v).unwrap();
    assert!(warm.rank_stats[0].warm && warm.rank_stats[1].warm, "{:?}", warm.rank_stats);

    commit_all(&r.root, "edit m6");
    let e2 = Engine::open(&store).unwrap();
    let cold = e2.graph(&e2.view_for_path(&r.root).unwrap()).unwrap();
    assert!(!cold.rank_stats[1].warm);
    assert!(l1(&ranks(&warm, &r.root), &ranks(&cold, &r.root)) < 2.0 * AGREE);
}
