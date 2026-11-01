//! PageRank over a file or symbol graph, solved to a tolerance rather than for a fixed number of
//! sweeps, and optionally started from a nearby graph's ranks.
//!
//! The model is the one the old fixed-30-sweep `pagerank` computed: damping 0.85, dangling nodes
//! spread their rank evenly over the live nodes, dead nodes (removed files) neither give nor
//! receive. Its fixed point is `r = G·1 + d·A·r`, where `A` moves each live non-dangling vertex's
//! rank evenly along its live out-edges and `G` (teleport plus spread dangling mass) is the same for
//! every vertex. So `r = G·(I - dA)⁻¹·1`: `r` is `x = 1 + d·A·x` normalized to sum 1. Solving for
//! `x` instead of `r` removes every global term from the iteration, which matters twice:
//!
//! * A change in vertex count or dangling mass no longer moves every vertex, so a warm start's
//!   error stays where the graph changed and Dynamic Frontier rounds can stay local. (Solving for
//!   `r` directly, the first measured frontier on tessera covered the whole graph: one added file
//!   shifts `G`, hence every vertex, by more than any useful per-vertex tolerance.)
//! * Sweeps can update in place (Gauss-Seidel), which converges in fewer sweeps than the old
//!   Jacobi sweep, with the same fixed point.
//!
//! A solve stops when one full sweep changes `x` by less than `TOL` of its sum (L1), whether it
//! started from all ones (cold) or from a nearby graph's ranks (warm), so the two answers agree
//! within a small multiple of `TOL`. A warm solve first sweeps once, then re-solves only the
//! out-neighbours of vertices that moved more than `TOL / live` of the sum, round after round
//! (Dynamic Frontier, Sahu, arXiv 2401.03256), and always finishes with full sweeps that must pass
//! the cold solve's test: they are the convergence proof and the fallback when the frontier gave up
//! (it does once it covers half the graph, where full sweeps are cheaper).

use super::GraphData;
use crate::facts::SymbolKind;
use std::collections::HashMap;

/// Stop when one full sweep changes the solution by less than this fraction of its sum (L1, so
/// the normalized ranks move by about this much in total).
pub const TOL: f64 = 1e-6;
const DAMPING: f64 = 0.85;
/// A guard, never reached on real graphs: each sweep contracts the error by at least `DAMPING`.
const MAX_SWEEPS: u32 = 500;

/// What a solve did, for the build log and the tests.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct SolveStats {
    /// Full sweeps over every edge.
    pub sweeps: u32,
    /// Vertex updates made by frontier rounds (each costs that vertex's in-degree).
    pub frontier_updates: u64,
    pub warm: bool,
    /// `sum(x)`, the factor from normalized ranks back to `x` (`1/G`). A later warm start from
    /// these ranks needs it: re-deriving it from the ranks on the new graph gets the vertex count
    /// and dangling set of the new graph, and that scale error moves every vertex at once.
    pub scale: f64,
}

/// Edges in pull (in-edge CSR) form with each source's damped out-share precomputed, so a sweep is
/// one pass over flat arrays: no per-sweep allocation and no re-filtering of dead targets, which
/// was most of the old solver's cost (measured on the 374k-edge tessera symbol graph: 2.7 ms per
/// sweep before, about 0.5 ms after).
struct Pull {
    alive: Vec<bool>,
    live: usize,
    /// DAMPING / live out-degree, or 0 for dead and dangling nodes.
    share: Vec<f64>,
    dangling: Vec<u32>,
    in_off: Vec<u32>,
    in_src: Vec<u32>,
    out_off: Vec<u32>,
    out_dst: Vec<u32>,
}

impl Pull {
    fn new(edges: &[Vec<u32>], alive: &[bool]) -> Pull {
        let n = edges.len();
        let live = alive.iter().filter(|a| **a).count();
        let mut indeg = vec![0u32; n + 1];
        let mut share = vec![0.0; n];
        let mut dangling = Vec::new();
        let mut out_off = Vec::with_capacity(n + 1);
        let mut out_dst = Vec::new();
        out_off.push(0);
        for (u, out) in edges.iter().enumerate() {
            if alive[u] {
                // Duplicate edges count once each, as they did in the old solver.
                let before = out_dst.len();
                out_dst.extend(out.iter().copied().filter(|t| alive[*t as usize]));
                let deg = out_dst.len() - before;
                for &t in &out_dst[before..] {
                    indeg[t as usize + 1] += 1;
                }
                if deg == 0 {
                    dangling.push(u as u32);
                } else {
                    share[u] = DAMPING / deg as f64;
                }
            }
            out_off.push(out_dst.len() as u32);
        }
        for i in 0..n {
            indeg[i + 1] += indeg[i];
        }
        let in_off = indeg;
        let mut fill = in_off.clone();
        let mut in_src = vec![0u32; out_dst.len()];
        for u in 0..n {
            for &t in &out_dst[out_off[u] as usize..out_off[u + 1] as usize] {
                in_src[fill[t as usize] as usize] = u as u32;
                fill[t as usize] += 1;
            }
        }
        Pull { alive: alive.to_vec(), live, share, dangling, in_off, in_src, out_off, out_dst }
    }

    fn update(&self, x: &[f64], v: usize) -> f64 {
        1.0 + self.in_src[self.in_off[v] as usize..self.in_off[v + 1] as usize].iter().map(|&u| x[u as usize] * self.share[u as usize]).sum::<f64>()
    }

    fn outs(&self, v: usize) -> &[u32] {
        &self.out_dst[self.out_off[v] as usize..self.out_off[v + 1] as usize]
    }

    /// One in-place sweep over every live vertex: (L1 change, sum of the result).
    fn sweep(&self, x: &mut [f64], mut moved: impl FnMut(usize, f64)) -> (f64, f64) {
        let (mut delta, mut sum) = (0.0, 0.0);
        for v in 0..x.len() {
            if self.alive[v] {
                let new = self.update(x, v);
                let d = (new - x[v]).abs();
                moved(v, d);
                delta += d;
                sum += new;
                x[v] = new;
            }
        }
        (delta, sum)
    }

    /// Full sweeps until one moves the normalized ranks by less than `TOL` (L1). Only the
    /// direction of `x` matters, so the test is on `x / sum(x)`, not on `x`: the cold iterates grow
    /// along `x` itself for many sweeps after the ranks have stopped moving.
    fn converge(&self, x: &mut [f64], stats: &mut SolveStats) {
        let mut old = x.to_vec();
        let mut old_sum: f64 = x.iter().sum();
        while stats.sweeps < MAX_SWEEPS {
            old.copy_from_slice(x);
            let (_, sum) = self.sweep(x, |_, _| {});
            stats.sweeps += 1;
            let delta: f64 = x.iter().zip(&old).map(|(n, o)| (n / sum - o / old_sum).abs()).sum();
            old_sum = sum;
            if delta < TOL {
                break;
            }
        }
    }

    /// Dynamic Frontier rounds over `marked`, in place: re-solve each marked vertex and mark the
    /// out-neighbours of any that moved more than `tau`, until no vertex moves that much. Gives up
    /// (leaving the rest to full sweeps) once the frontier covers half the graph.
    fn frontier(&self, x: &mut [f64], mut marked: Vec<u32>, tau: f64, stats: &mut SolveStats) {
        let mut queued = vec![false; x.len()];
        let mut rounds = 0;
        while !marked.is_empty() && marked.len() * 2 <= self.live && rounds < MAX_SWEEPS {
            rounds += 1;
            let mut next = Vec::new();
            for &v in &marked {
                let v = v as usize;
                let new = self.update(x, v);
                let moved = (new - x[v]).abs();
                x[v] = new;
                stats.frontier_updates += 1;
                if moved > tau {
                    for &t in self.outs(v) {
                        if !queued[t as usize] {
                            queued[t as usize] = true;
                            next.push(t);
                        }
                    }
                }
            }
            for &t in &next {
                queued[t as usize] = false;
            }
            marked = next;
        }
    }
}

/// PageRank from a uniform start.
pub fn pagerank(edges: &[Vec<u32>], alive: &[bool]) -> Vec<f64> {
    solve(edges, alive, None).0
}

/// PageRank started from `prior` when given: one normalized rank per vertex from a nearby graph,
/// `f64::NAN` for a vertex that graph did not have. Any prior gives the same answer within
/// tolerance; a close one only takes fewer sweeps.
pub fn solve(edges: &[Vec<u32>], alive: &[bool], prior: Option<(&[f64], f64)>) -> (Vec<f64>, SolveStats) {
    solve_with(edges, alive, prior, true)
}

/// `solve`, with the Dynamic Frontier rounds optional (off: warm start plus full sweeps only).
pub fn solve_with(edges: &[Vec<u32>], alive: &[bool], prior: Option<(&[f64], f64)>, frontier: bool) -> (Vec<f64>, SolveStats) {
    let n = edges.len();
    let p = Pull::new(edges, alive);
    let mut stats = SolveStats::default();
    if p.live == 0 {
        return (vec![0.0; n], stats);
    }
    let mut x: Vec<f64> = alive.iter().map(|a| if *a { 1.0 } else { 0.0 }).collect();
    match prior.filter(|v| v.0.len() == n) {
        None => p.converge(&mut x, &mut stats),
        Some((prior, scale)) => {
            stats.warm = true;
            // Back from ranks to `x` with the prior graph's own scale, so a vertex the change does
            // not reach starts exactly where it ends. A vertex the prior lacks starts at 1, as in
            // a cold solve. Without a scale (0), estimate it on this graph: still correct, just
            // more sweeps.
            let scale = if scale > 0.0 {
                scale
            } else {
                let dangling: f64 = p.dangling.iter().map(|&u| prior[u as usize]).filter(|r| r.is_finite()).sum();
                p.live as f64 / ((1.0 - DAMPING) + DAMPING * dangling)
            };
            for v in 0..n {
                if alive[v] && prior[v].is_finite() && prior[v] >= 0.0 {
                    x[v] = prior[v] * scale;
                }
            }
            // One full sweep finds where the prior is wrong: the out-neighbours of whatever moved
            // are the first frontier.
            let mut moved = Vec::new();
            let (delta, sum) = p.sweep(&mut x, |v, d| moved.push((v, d)));
            stats.sweeps += 1;
            if delta >= TOL * sum {
                if frontier {
                    let tau = TOL * sum / p.live as f64;
                    let mut queued = vec![false; n];
                    let mut marked = Vec::new();
                    for (v, d) in moved {
                        if d > tau {
                            for &t in p.outs(v) {
                                if !queued[t as usize] {
                                    queued[t as usize] = true;
                                    marked.push(t);
                                }
                            }
                        }
                    }
                    p.frontier(&mut x, marked, tau, &mut stats);
                }
                p.converge(&mut x, &mut stats);
            }
        }
    }
    let sum: f64 = x.iter().sum();
    x.iter_mut().for_each(|v| *v /= sum);
    stats.scale = sum;
    (x, stats)
}

impl GraphData {
    /// File graph for PageRank: importers vote for what they import.
    pub fn rank_file_edges(&self) -> (Vec<Vec<u32>>, Vec<bool>) {
        (self.res.iter().map(|r| r.edges.clone()).collect(), self.files.iter().map(|f| f.alive).collect())
    }

    /// Symbol graph for PageRank, flattened file-major (`offsets[file] + local`): a symbol votes,
    /// via the references inside it, for what it uses.
    pub fn rank_symbol_edges(&self) -> (Vec<Vec<u32>>, Vec<usize>) {
        let mut offset = Vec::with_capacity(self.files.len());
        let mut total = 0usize;
        for f in &self.files {
            offset.push(total);
            total += f.facts.symbols.len();
        }
        let mut sedges: Vec<Vec<u32>> = vec![Vec::new(); total];
        for (fi, r) in self.res.iter().enumerate() {
            for (rr, fr) in r.refs.iter().zip(&self.files[fi].facts.refs) {
                if let (Some(t), Some(e)) = (rr.target, fr.enclosing) {
                    sedges[offset[fi] + e as usize].push((offset[t.file as usize] + t.local as usize) as u32);
                }
            }
        }
        (sedges, offset)
    }

    /// `prior`'s ranks laid out on this graph's vertices, for a warm start: files match by path;
    /// symbols match by local id when the file's blob is unchanged, else by (name, kind, n-th
    /// occurrence in the file). Unmatched vertices are NaN (uniform start).
    pub fn rank_prior(&self, prior: &GraphData, offsets: &[usize], total: usize) -> (Vec<f64>, Vec<f64>) {
        let mut file = vec![f64::NAN; self.files.len()];
        let mut sym = vec![f64::NAN; total];
        for (fi, f) in self.files.iter().enumerate().filter(|(_, f)| f.alive) {
            let Some(&pi) = prior.index.get(&f.path) else { continue };
            let pi = pi as usize;
            let (Some(&pr), Some(psr)) = (prior.file_rank.get(pi), prior.symbol_rank.get(pi)) else { continue };
            file[fi] = pr;
            let pf = &prior.files[pi];
            let out = &mut sym[offsets[fi]..offsets[fi] + f.facts.symbols.len()];
            if pf.blob_id == f.blob_id && psr.len() == out.len() {
                out.copy_from_slice(psr);
                continue;
            }
            let mut by_name: HashMap<(&str, SymbolKind, u32), f64> = HashMap::new();
            let mut seen: HashMap<(&str, SymbolKind), u32> = HashMap::new();
            for (s, r) in pf.facts.symbols.iter().zip(psr) {
                let k = seen.entry((s.name.as_str(), s.kind)).or_default();
                by_name.insert((s.name.as_str(), s.kind, *k), *r);
                *k += 1;
            }
            seen.clear();
            for (s, o) in f.facts.symbols.iter().zip(out.iter_mut()) {
                let k = seen.entry((s.name.as_str(), s.kind)).or_default();
                if let Some(r) = by_name.get(&(s.name.as_str(), s.kind, *k)) {
                    *o = *r;
                }
                *k += 1;
            }
        }
        (file, sym)
    }

    /// File and symbol ranks, warm-started from `prior` when there is one.
    pub(super) fn rank(&mut self, prior: Option<&GraphData>) {
        let (edges, alive) = self.rank_file_edges();
        let (sedges, offset) = self.rank_symbol_edges();
        let priors = prior.map(|p| self.rank_prior(p, &offset, sedges.len()));
        let scale = prior.map(|p| [p.rank_stats[0].scale, p.rank_stats[1].scale]).unwrap_or_default();
        let (file_rank, fs) = solve(&edges, &alive, priors.as_ref().map(|p| (p.0.as_slice(), scale[0])));
        let (flat, ss) = solve(&sedges, &vec![true; sedges.len()], priors.as_ref().map(|p| (p.1.as_slice(), scale[1])));
        self.file_rank = file_rank;
        self.symbol_rank = self.files.iter().enumerate().map(|(i, f)| flat[offset[i]..offset[i] + f.facts.symbols.len()].to_vec()).collect();
        self.rank_stats = [fs, ss];
    }
}
