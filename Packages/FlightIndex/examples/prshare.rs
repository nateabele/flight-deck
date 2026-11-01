//! PageRank's share of graph build, and what a warm start saves:
//! `cargo run --release --example prshare -- <store> <runs> <near-path> <path>`.
//! Indexes both paths. Per run, a fresh engine (empty graph cache) times the graph of <path> built
//! cold, then the graph of <near-path> followed by <path> (warm-started from it). Separately times
//! file and symbol PageRank alone on <path>'s edges: the old fixed-30-sweep solver, the tolerance
//! solver cold, warm with full sweeps only, and warm with Dynamic Frontier rounds, each with its
//! L1 distance from a 300-sweep reference.
use flightindex::engine::Engine;
use flightindex::graph::rank::{solve_with, SolveStats};
fn cpu_ms() -> f64 {
    let mut t = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    unsafe { libc::clock_gettime(libc::CLOCK_THREAD_CPUTIME_ID, &mut t) };
    t.tv_sec as f64 * 1000.0 + t.tv_nsec as f64 / 1e6
}
use std::time::Instant;

/// The solver as it was before the tolerance solver (allocates a filtered out-list per vertex per sweep).
fn legacy(edges: &[Vec<u32>], alive: &[bool], sweeps: usize) -> Vec<f64> {
    let n = edges.len();
    let live = alive.iter().filter(|a| **a).count();
    let d = 0.85;
    let base = (1.0 - d) / live as f64;
    let mut rank: Vec<f64> = alive.iter().map(|a| if *a { 1.0 / live as f64 } else { 0.0 }).collect();
    for _ in 0..sweeps {
        let mut next: Vec<f64> = alive.iter().map(|a| if *a { base } else { 0.0 }).collect();
        let mut dangling = 0.0;
        for (i, out) in edges.iter().enumerate() {
            if !alive[i] {
                continue;
            }
            let outs: Vec<&u32> = out.iter().filter(|t| alive[**t as usize]).collect();
            if outs.is_empty() {
                dangling += rank[i];
            } else {
                let share = d * rank[i] / outs.len() as f64;
                for t in outs {
                    next[*t as usize] += share;
                }
            }
        }
        let spread = d * dangling / live as f64;
        for (i, v) in next.iter_mut().enumerate() {
            if alive[i] {
                *v += spread;
            }
        }
        rank = next;
    }
    let _ = n;
    rank
}

fn ms<T>(f: impl FnOnce() -> T) -> (T, f64) {
    let t = Instant::now();
    let r = f();
    (r, t.elapsed().as_secs_f64() * 1000.0)
}

/// Thread CPU time: the solvers are single-threaded, and on a machine at load 100 wall time
/// mostly measures the scheduler.
fn cpu<T>(f: impl FnOnce() -> T) -> (T, f64) {
    let t = cpu_ms();
    let r = f();
    (r, cpu_ms() - t)
}

fn l1(a: &[f64], b: &[f64]) -> f64 {
    a.iter().zip(b).map(|(x, y)| (x - y).abs()).sum()
}

fn med(mut v: Vec<f64>) -> f64 {
    v.sort_by(|x, y| x.partial_cmp(y).unwrap());
    v[v.len() / 2]
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (store, runs) = (&a[1], a[2].parse::<usize>().unwrap());
    let (near, path) = (std::path::Path::new(&a[3]), std::path::Path::new(&a[4]));
    {
        let e = Engine::open(store).unwrap();
        for p in [near, path] {
            let v = e.view_for_path(p).unwrap();
            e.build(&v, &[], |_| {}).unwrap();
        }
    }
    let (mut cold_build, mut warm_build) = (Vec::new(), Vec::new());
    let mut warm_stats = [SolveStats::default(); 2];
    // [legacy, cold, warm-full, warm-frontier] x [file, symbol]
    let mut t: Vec<Vec<f64>> = vec![Vec::new(); 8];
    let mut err = [0.0f64; 8];
    let mut sweeps = [SolveStats::default(); 8];
    let mut sizes = (0, 0, 0, 0);
    let mut top_same = [0usize; 2];
    for _ in 0..runs {
        let e = Engine::open(store).unwrap();
        let v = e.view_for_path(path).unwrap();
        let (g, b) = ms(|| e.graph(&v).unwrap());
        cold_build.push(b);
        let e2 = Engine::open(store).unwrap();
        let vn = e2.view_for_path(near).unwrap();
        let gn = e2.graph(&vn).unwrap();
        let v2 = e2.view_for_path(path).unwrap();
        let (gw, b) = ms(|| e2.graph(&v2).unwrap());
        warm_build.push(b);
        warm_stats = gw.rank_stats;

        let (fe, alive) = g.rank_file_edges();
        let (se, off) = g.rank_symbol_edges();
        let salive = vec![true; se.len()];
        let (fp, sp) = g.rank_prior(&gn, &off, se.len());
        sizes = (fe.len(), fe.iter().map(Vec::len).sum::<usize>(), se.len(), se.iter().map(Vec::len).sum::<usize>());
        for (k, (edges, alive, prior)) in [(&fe, &alive, &fp), (&se, &salive, &sp)].into_iter().enumerate() {
            let scale = gn.rank_stats[k].scale;
            let reference = legacy(edges, alive, 300);
            let (r, x) = cpu(|| legacy(edges, alive, 30));
            // How many of the old solver's top 20 keep their exact position with the new one.
            let top = |v: &[f64]| {
                let mut i: Vec<usize> = (0..v.len()).collect();
                i.sort_by(|a, b| v[*b].partial_cmp(&v[*a]).unwrap());
                i.truncate(20);
                i
            };
            let (old_top, new_top) = (top(&r), top(&solve_with(edges, alive, None, false).0));
            top_same[k] = old_top.iter().zip(&new_top).filter(|(a, b)| a == b).count();
            t[k].push(x);
            err[k] = l1(&r, &reference);
            sweeps[k].sweeps = 30;
            for (j, (pr, fr)) in [(None, false), (Some((prior.as_slice(), scale)), false), (Some((prior.as_slice(), scale)), true)].into_iter().enumerate() {
                let ((r, s), x) = cpu(|| solve_with(edges, alive, pr, fr));
                let i = 2 * (j + 1) + k;
                t[i].push(x);
                err[i] = l1(&r, &reference);
                sweeps[i] = s;
            }
        }
    }
    println!("{}: files={} file_edges={} symbols={} sym_edges={}", path.display(), sizes.0, sizes.1, sizes.2, sizes.3);
    println!("graph build p50: cold {:.1} ms, warm-started {:.1} ms (warm stats file {:?} symbol {:?})", med(cold_build), med(warm_build), warm_stats[0], warm_stats[1]);
    println!("top-20 positions unchanged, legacy vs cold-tol: file {}/20, symbol {}/20", top_same[0], top_same[1]);
    for (j, name) in ["legacy-30", "cold-tol", "warm-full", "warm-frontier"].iter().enumerate() {
        for (k, kind) in ["file", "symbol"].iter().enumerate() {
            let i = 2 * j + k;
            println!(
                "  {name:<14} {kind:<6} cpu p50 {:>8.2} ms  sweeps {:>3}  frontier_updates {:>8}  L1 vs ref {:.2e}",
                med(t[i].clone()),
                sweeps[i].sweeps,
                sweeps[i].frontier_updates,
                err[i]
            );
        }
    }
}
