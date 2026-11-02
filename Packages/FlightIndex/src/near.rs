//! `near`: order a tool's rows by graph distance from what the agent is working on.
//!
//! A cap (`limit`, the 30-row lists, `token_budget`) keeps the head of a list, so the order
//! decides which rows an agent ever sees. Without `near`, `find` leads with the most-imported
//! definition and `grep` / `refs` go alphabetically, which puts a popular `parse` far away ahead
//! of the one next to the file being edited. With a seed set, each row is scored
//!
//! `S = DECAY^hops + LINK_BONUS·linked + PR_WEIGHT·log-PageRank`
//!
//! (Portfolio's `S = λPR·PR + λSAN·SAN`, ICSE 2011; OrcaLoca's distance pruning, ICML 2025) and
//! rows are stably sorted by it, so ties keep the tool's own order.
//!
//! * **Distance**: breadth-first hops from the nearest seed file over file dependencies in both
//!   directions (imports and importers), up to `MAX_HOPS`; a seed scores 1, each hop multiplies
//!   by `DECAY`, and a file further away scores 0. The file graph is used, not the symbol graph:
//!   it has ~3k nodes against ~650k references on the largest repository, so a request pays
//!   microseconds, and file-level distance is what the measured systems used.
//!   Measured against true spreading activation (3 pulses summed over paths, each hop divided by
//!   the square root of the sender's degree, capped at 1) on the eval harness's 200 + 200 tasks:
//!   plain hops won the paired per-task comparison in 22 of 24 tool × seed × metric cells (e.g.
//!   tessera `grep` seeded by the previous commit, File@10: 29 tasks better, 5 worse; +3.4 pp).
//!   Fan-out damping starves the neighbours of a well-connected seed, which is exactly the file
//!   being worked on, so the PageRank term then decides and the popular rows come back.
//! * **Linked**: a symbol that calls into a seed file, or is called from one, gets `LINK_BONUS`:
//!   the symbol-level hop the file graph cannot see (two symbols in one big file are not equally
//!   near the seed). Without it, flight-deck File@5 fell 0.6–1.2 pp; tessera was unchanged.
//! * **PageRank** breaks ties among equally near rows and orders the rows nothing reaches, so a
//!   seed that touches nothing still gives the tool's ordinary ranking.
//!
//! Seeds: the `near` argument (files, absolute or relative to the cwd, or symbol names). Without
//! it, the worktree's changed files plus the files the agent read last (`Ctx::recent`, kept by
//! the service). `near: []` (or `near: false`) turns ordering off. Only the answering view is
//! scored; rows from linked views score by PageRank alone and keep their place among themselves.
//!
//! The default seed set is on for every tool that orders by nearness. Scored with seeds an agent
//! could really hold (the same author's previous 1-3 commits, or the open file left out of the
//! gold set; `examples/eval_near.rs`), it raised `find`/`grep`/`refs` File@10 on both measured
//! repositories in every seeding, each paired comparison at p < 0.001 (e.g. tessera `grep`
//! 13.2 -> 24.7 from the previous commit). `impact` never re-sorts its ranked interleave by it,
//! explicit `near` included: that lost File@10 in all four cells (see `tools/analysis.rs`).

use crate::graph::{SymId, ViewGraph};
use crate::query::{NameMatch, SymbolHit};
use crate::tools::{args, Ctx};
use std::path::{Path, PathBuf};

pub const MAX_HOPS: usize = 3;
pub const DECAY: f64 = 0.6;
pub const LINK_BONUS: f64 = 0.5;
pub const PR_WEIGHT: f64 = 0.15;
/// The default seed set (diff plus reads) is cut at this many files. A worktree with a hundred
/// regenerated files would otherwise light up most of the graph and order nothing.
pub const MAX_DEFAULT_SEEDS: usize = 32;
/// Files the service remembers per worktree as "read last".
pub const RECENT_READS: usize = 8;

pub struct Near {
    act: Vec<f64>,
    seed: Vec<bool>,
    /// ln(file PageRank) normalised to [0, 1] over live files.
    file_pr: Vec<f64>,
    seeds: usize,
}

impl Near {
    /// The seed set of a request, or `None` when ordering is off: `near` given empty, or no seed
    /// names a file of the answering view.
    pub fn of(c: &Ctx) -> Option<Near> {
        let g = c.graph;
        let mut files: Vec<u32> = Vec::new();
        if c.args.has(&["near"]) {
            for entry in c.args.list(&["near"]) {
                if matches!(entry.as_str(), "none" | "false") {
                    return None;
                }
                files.extend(seed_files(g, &c.args.cwd, &entry));
            }
        } else {
            files.extend(c.recent.iter().filter_map(|p| g.file_idx(p)).take(MAX_DEFAULT_SEEDS));
        }
        Near::from_files(g, &files)
    }

    pub fn from_files(g: &ViewGraph, files: &[u32]) -> Option<Near> {
        let n = g.files.len();
        let mut seed = vec![false; n];
        for &f in files {
            if g.file(f).alive {
                seed[f as usize] = true;
            }
        }
        let seeds = seed.iter().filter(|s| **s).count();
        if seeds == 0 {
            return None;
        }
        Some(Near { act: activation(g, &seed), seed, file_pr: log_norm(&g.file_rank, |i| g.file(i as u32).alive), seeds })
    }

    /// The line a tool adds when it reordered: says why the order is not the usual one and how
    /// to turn it off. Counts only, never paths: every path in a result names a row.
    pub fn note(&self) -> String {
        format!("(ordered by nearness to {} seed file(s); near=[] turns this off)", self.seeds)
    }

    /// Score of a file of the answering view (`None`: a row of another view).
    pub fn file_score(&self, file: Option<u32>) -> f64 {
        match file {
            Some(f) => self.act[f as usize] + PR_WEIGHT * self.file_pr[f as usize],
            None => 0.0,
        }
    }

    /// Score of a definition; `pr` is its symbol rank already normalised over the candidates.
    fn hit_score(&self, g: &ViewGraph, h: &SymbolHit, pr: f64) -> f64 {
        if h.view != 0 {
            return PR_WEIGHT * pr;
        }
        let link = if self.linked(g, h.id) { LINK_BONUS } else { 0.0 };
        self.act[h.id.file as usize] + link + PR_WEIGHT * pr
    }

    /// A reference from a seed file lands on `id`, or `id`'s body refers into a seed file.
    fn linked(&self, g: &ViewGraph, id: SymId) -> bool {
        if g.incoming.get(&id).is_some_and(|v| v.iter().any(|(fi, _)| *fi != id.file && self.seed[*fi as usize])) {
            return true;
        }
        let f = g.file(id.file);
        let s = f.symbol(id.local);
        let res = &g.resolution(id.file).refs;
        f.facts.refs.iter().zip(res).any(|(r, rr)| {
            r.line >= s.start_line && r.line <= s.end_line && rr.target.is_some_and(|t| t.file != id.file && self.seed[t.file as usize])
        })
    }

    /// Scores of definitions; their PageRank term is normalised over this list.
    pub fn hit_scores(&self, g: &ViewGraph, hits: &[&SymbolHit]) -> Vec<f64> {
        let pr = log_norm(&hits.iter().map(|h| h.rank).collect::<Vec<_>>(), |_| true);
        hits.iter().zip(pr).map(|(h, p)| self.hit_score(g, h, p)).collect()
    }

    /// Stably sort definitions, nearest first.
    pub fn sort_hits(&self, g: &ViewGraph, hits: &mut Vec<SymbolHit>) {
        let scores = self.hit_scores(g, &hits.iter().collect::<Vec<_>>());
        let mut keyed: Vec<(f64, SymbolHit)> = scores.into_iter().zip(hits.drain(..)).collect();
        keyed.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        hits.extend(keyed.into_iter().map(|(_, h)| h));
    }

    /// Stably sort rows by the file each sits in, nearest first. `file` gives the row's file
    /// index in the answering view, `None` for a row of another view.
    pub fn sort_by_file<T>(&self, rows: &mut [T], file: impl Fn(&T) -> Option<u32>) {
        rows.sort_by(|a, b| self.file_score(file(b)).partial_cmp(&self.file_score(file(a))).unwrap_or(std::cmp::Ordering::Equal));
    }
}

/// Files a `near` entry names: a file of the view, else the files defining a symbol of that name.
fn seed_files(g: &ViewGraph, cwd: &Path, entry: &str) -> Vec<u32> {
    if let Some(f) = g.file_idx(&args::resolve_path(cwd, entry)) {
        return vec![f];
    }
    if entry.contains('/') {
        return Vec::new();
    }
    g.find_symbols(&NameMatch::Exact(entry.to_string()), None, 16).data.into_iter().map(|h| h.id.file).collect()
}

/// `DECAY^hops` from the nearest seed over the undirected file graph, 0 beyond `MAX_HOPS`.
fn activation(g: &ViewGraph, seed: &[bool]) -> Vec<f64> {
    let neighbours = |i: usize| g.res[i].edges.iter().chain(g.importers[i].iter()).copied().filter(|j| g.file(*j).alive);
    let mut act: Vec<f64> = seed.iter().map(|s| if *s { 1.0 } else { 0.0 }).collect();
    let mut frontier: Vec<usize> = (0..seed.len()).filter(|i| seed[*i]).collect();
    let mut weight = 1.0;
    for _ in 0..MAX_HOPS {
        weight *= DECAY;
        let mut next = Vec::new();
        for &i in &frontier {
            for j in neighbours(i) {
                if act[j as usize] == 0.0 {
                    act[j as usize] = weight;
                    next.push(j as usize);
                }
            }
        }
        frontier = next;
    }
    act
}

/// `ln(v)` rescaled to [0, 1] over the entries `keep` admits (others get 0). PageRank spans
/// orders of magnitude; on a linear scale every file but the top few would round to 0.
fn log_norm(v: &[f64], keep: impl Fn(usize) -> bool) -> Vec<f64> {
    let logs: Vec<Option<f64>> = v.iter().enumerate().map(|(i, x)| (keep(i) && *x > 0.0).then(|| x.ln())).collect();
    let lo = logs.iter().flatten().copied().fold(f64::INFINITY, f64::min);
    let hi = logs.iter().flatten().copied().fold(f64::NEG_INFINITY, f64::max);
    let span = hi - lo;
    logs.iter().map(|l| l.map_or(0.0, |l| if span > 0.0 { (l - lo) / span } else { 1.0 })).collect()
}

/// The files a `read` or `outline` call looked at, for the service's recent-reads list.
pub fn read_files(c: &Ctx) -> Vec<PathBuf> {
    if let Some(p) = c.args.path(args::FILE) {
        return c.graph.file_idx(&p).map(|_| p).into_iter().collect();
    }
    let mut names = c.args.list(&["symbols"]);
    names.extend(c.args.str(args::SYMBOL));
    names.iter().filter_map(|n| c.graph.find_symbols(&NameMatch::Exact(n.clone()), None, 1).data.into_iter().next()).map(|h| h.path).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_norm_spans_zero_to_one_and_skips_excluded() {
        let v = log_norm(&[1.0, 10.0, 100.0, 5.0], |i| i != 3);
        assert_eq!(v[0], 0.0);
        assert!((v[1] - 0.5).abs() < 1e-9);
        assert_eq!(v[2], 1.0);
        assert_eq!(v[3], 0.0);
    }
}
