//! Personalized PageRank over files: "what matters *to the files I am working on*", for `map`
//! when the caller names files (`boost_files`) or the worktree has uncommitted edits.
//!
//! Plain `file_rank` answers "what is central to the whole repository", which is the right map
//! for a newcomer and close to useless mid-task: on the eval's seeded tasks (an open or modified
//! file standing in for the task) the global map put a gold file in the top ten 0.3% (tessera) and
//! 2.7% (flight-deck) of the time. Restarting the walk at the seed files instead lifts it to 32%
//! and 57% (eval `map_open`, 159 and 176 tasks; 35% and 53% on the next 200 commits of each).
//!
//! The edge weights start from Aider's `repomap.py` (`get_ranked_tags`), reworked by measurement:
//!
//! * An edge runs from the file holding a resolved reference to the file defining its target, one
//!   per `(name, referencer, definer)`, weighted `sqrt(count)`, x10 for a distinctive name (snake,
//!   kebab or camel case and eight or more characters), x0.1 for a leading underscore, and x0.1
//!   when more than five files define the name. Only *resolved* targets count: Aider's "every
//!   definer of the name" edges cost 0.5-1.3 s a call on tessera and gained nothing.
//! * Each edge also runs backwards, definer -> referencer, at `reverse` times its weight. This is
//!   the lever that matters. A forward-only walk from a seed only reaches what the seed uses, and
//!   the rest of a change is as often what *uses* the seed (its callers, its tests). Measured
//!   File@10 for reverse = 0, 1, 5, 20: 6.4, 29.7, 31.8, 32.2 (tessera); 12.1, 55.8, 56.8, 57.2
//!   (flight-deck). On held-out tasks (`--skip 200`) 1, 5, 20 gave 28.3, 31.2, 34.8 and 50.2,
//!   52.2, 52.9, so twenty is the default; past five the gain is small, and the constant is tuned,
//!   not a principle.
//! * Aider's x10 for a name the chat mentions and x50 for edges out of a chat file are left out:
//!   both measured neutral or harmful (mentioned names dilute the seed by 2-3 pp).
//! * A definition nobody references gets Aider's 0.1 self edge, so a file of unused definitions
//!   holds some of its mass rather than counting as dangling.
//!
//! The walk follows networkx's `pagerank`: damping 0.85, restart and dangling mass both go to the
//! seed vector, at most 100 iterations, stop when the L1 change is under 1e-6 per live file.
//!
//! The weighted adjacency does not depend on the seeds, so it is built once per graph, on the
//! first seeded call, and kept (`GraphData::ppr_graph`); each call then runs only the iteration.
//! Measured on tessera (2963 files): the build 41 ms and +344 KB, each later call 1.2 ms
//! (flight-deck: 16 ms, +169 KB, 0.6 ms), at load 37. The prototype rebuilt it per call and spent
//! 40-130 ms.

use super::GraphData;
use std::collections::{HashMap, HashSet};

/// Default weight of a reverse (definer -> referencer) edge relative to its forward edge.
pub const DEFAULT_REVERSE: f64 = 20.0;

const ALPHA: f64 = 0.85;
const MAX_ITER: usize = 100;
const TOL: f64 = 1e-6;

/// The static part of the walk: one entry per (referencer, definer) file pair, weights summed over
/// the names that link them. Kept in flat arrays: 12 bytes an edge, and on tessera a few hundred
/// kilobytes a graph.
#[derive(Debug, Default)]
pub(crate) struct PprGraph {
    src: Vec<u32>,
    dst: Vec<u32>,
    w: Vec<f32>,
    /// Per file: total forward weight out, total forward weight in (which becomes its reverse
    /// out-weight times `reverse`), and the self-loop weight (same-file references and unreferenced
    /// definitions).
    out_w: Vec<f64>,
    in_w: Vec<f64>,
    self_w: Vec<f64>,
    alive: Vec<bool>,
}

impl PprGraph {
    pub(crate) fn bytes(&self) -> usize {
        self.src.len() * 12 + self.out_w.len() * 25
    }
}

/// Aider's "distinctive identifier": snake, kebab or camel case, and at least eight characters.
fn distinctive(name: &str) -> bool {
    let alpha = name.chars().any(|c| c.is_alphabetic());
    let snake = name.contains('_') && alpha;
    let kebab = name.contains('-') && alpha;
    let camel = name.chars().any(|c| c.is_uppercase()) && name.chars().any(|c| c.is_lowercase());
    (snake || kebab || camel) && name.chars().count() >= 8
}

pub(crate) fn build(g: &GraphData) -> PprGraph {
    let n = g.files.len();
    let alive: Vec<bool> = g.files.iter().map(|f| f.alive).collect();
    // Files defining each name; a name defined in more than five is too common to say much.
    let definers = |name: &str| -> usize {
        g.name_index.get(name).map(|ids| ids.iter().map(|s| s.file).collect::<HashSet<u32>>().len()).unwrap_or(0)
    };
    let mut counts: HashMap<(&str, u32, u32), u32> = HashMap::new();
    for (fi, r) in g.res.iter().enumerate() {
        if !alive[fi] {
            continue;
        }
        for rr in &r.refs {
            if let Some(t) = rr.target
                && alive[t.file as usize]
            {
                let name = g.files[t.file as usize].symbol(t.local).name.as_str();
                *counts.entry((name, fi as u32, t.file)).or_default() += 1;
            }
        }
    }
    let mut def_count: HashMap<&str, usize> = HashMap::new();
    let mut pair: HashMap<(u32, u32), f64> = HashMap::new();
    let mut self_w = vec![0.0f64; n];
    let mut referenced: HashSet<&str> = HashSet::new();
    for (&(name, src, dst), &c) in &counts {
        referenced.insert(name);
        let mut mul = 1.0;
        if distinctive(name) {
            mul *= 10.0;
        }
        if name.starts_with('_') {
            mul *= 0.1;
        }
        if *def_count.entry(name).or_insert_with(|| definers(name)) > 5 {
            mul *= 0.1;
        }
        let w = mul * (c as f64).sqrt();
        if src == dst {
            self_w[src as usize] += w;
        } else {
            *pair.entry((src, dst)).or_default() += w;
        }
    }
    for (name, ids) in &g.name_index {
        if referenced.contains(name.as_str()) {
            continue;
        }
        let files: HashSet<u32> = ids.iter().map(|s| s.file).filter(|f| alive[*f as usize]).collect();
        for f in files {
            self_w[f as usize] += 0.1;
        }
    }
    let mut edges: Vec<((u32, u32), f64)> = pair.into_iter().collect();
    edges.sort_unstable_by_key(|e| e.0);
    let mut p = PprGraph { out_w: vec![0.0; n], in_w: vec![0.0; n], self_w, alive, ..Default::default() };
    for ((s, d), w) in edges {
        p.src.push(s);
        p.dst.push(d);
        p.w.push(w as f32);
        p.out_w[s as usize] += w as f32 as f64;
        p.in_w[d as usize] += w as f32 as f64;
    }
    p
}

/// File ranks with the walk restarting at `seeds` (file index, weight; weights need not sum to
/// one). `reverse` weighs definer -> referencer edges against referencer -> definer ones. With no
/// live seed this is the plain `file_rank`, unchanged, so a caller can always go through here.
pub(crate) fn personalized_file_rank(g: &GraphData, seeds: &[(u32, f64)], reverse: f64) -> Vec<f64> {
    let n = g.files.len();
    let mut pers = vec![0.0f64; n];
    for &(f, w) in seeds {
        if (f as usize) < n && g.files[f as usize].alive && w > 0.0 {
            pers[f as usize] += w;
        }
    }
    let total: f64 = pers.iter().sum();
    if total <= 0.0 {
        return g.file_rank.clone();
    }
    pers.iter_mut().for_each(|v| *v /= total);
    let p = g.ppr_graph();
    let live = p.alive.iter().filter(|a| **a).count().max(1);
    let wsum: Vec<f64> = (0..n).map(|i| p.out_w[i] + reverse * p.in_w[i] + p.self_w[i]).collect();
    // Start from the seed vector, not uniform: the answer is the same fixed point, and starting
    // near it converges in fewer rounds on a walk that keeps most mass close to the seeds.
    let mut x = pers.clone();
    let mut next = vec![0.0f64; n];
    for _ in 0..MAX_ITER {
        let dangling: f64 = (0..n).filter(|&i| p.alive[i] && wsum[i] == 0.0).map(|i| x[i]).sum();
        let base = ALPHA * dangling + (1.0 - ALPHA);
        for i in 0..n {
            next[i] = base * pers[i] + if wsum[i] > 0.0 { ALPHA * x[i] * p.self_w[i] / wsum[i] } else { 0.0 };
        }
        for e in 0..p.src.len() {
            let (s, d, w) = (p.src[e] as usize, p.dst[e] as usize, p.w[e] as f64);
            next[d] += ALPHA * x[s] * w / wsum[s];
            if reverse > 0.0 {
                next[s] += ALPHA * x[d] * w * reverse / wsum[d];
            }
        }
        let err: f64 = next.iter().zip(&x).map(|(a, b)| (a - b).abs()).sum();
        std::mem::swap(&mut x, &mut next);
        if err < live as f64 * TOL {
            break;
        }
    }
    x
}
