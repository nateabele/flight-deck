//! Regression cells for the seeded (personalized) map: the task's first gold file plays the file
//! the agent has open or has modified, and is excluded from both the ranking and the gold set.
//!
//! `map_open` (a built-in) scores the shipped path: `map` with `boost_files`, which runs
//! personalized PageRank (`graph/ppr.rs`). The cells here keep what that number is judged
//! against, so a later change to the walk is scored against its alternatives in the same run:
//!
//! * `ppr_open_rev{0,1,5,20}`: the walk called directly at a fixed reverse-edge weight, over every
//!   file (tests included). `rev0` is Aider's forward-only walk; `rev20` is what `map` ships. The
//!   constant was picked on these same tasks, so rerun with `--skip 100` before trusting a change.
//! * `nbr_open`: the seed's direct imports and importers by global rank, then the global rank.
//!   The cheap control: personalized PageRank has to beat a one-hop list to earn its cost.
//! * `bm25_open`, and `bm25_map_open` / `bm25_nbr_open`, its reciprocal-rank fusion (k = 60) with
//!   the seeded map and with the one-hop list. Files are fused; symbols stay BM25's (the walk
//!   ranks symbols poorly: Func@10 1-3%, and fusing them cut BM25's from 12.4 to 9.0 on fd).
//!
//! Gate (`--gate map_open=20` on tessera, `=40` on flight-deck): map_open File@10.

use super::{bm25, Probe, Ranking, Strategy, Task, DEPTH};
use serde_json::json;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

/// The seed file, when the task has a second gold file to find.
fn seed(t: &Task) -> Option<&String> {
    (t.gold_files.len() >= 2).then(|| &t.gold_files[0])
}

/// Live files other than the seed by `score`, best first, as relative paths.
fn ranked(p: &Probe, skip: u32, score: &[f64]) -> Vec<String> {
    let g = p.graph;
    let mut v: Vec<u32> = (0..g.files.len() as u32).filter(|f| *f != skip && g.file(*f).alive).collect();
    v.sort_by(|a, b| score[*b as usize].partial_cmp(&score[*a as usize]).unwrap_or(std::cmp::Ordering::Equal).then(a.cmp(b)));
    v.into_iter().take(DEPTH).map(|f| g.file(f).path.clone()).collect()
}

fn ppr_open(p: &Probe, t: &Task, reverse: f64) -> Option<Ranking> {
    let s = seed(t)?;
    let fi = p.graph.file_idx(Path::new(s))?;
    let rank = p.graph.personalized_file_rank(&[(fi, 1.0)], reverse);
    Some(Ranking { files: ranked(p, fi, &rank), symbols: Vec::new(), exclude: vec![s.clone()] })
}

fn nbr_open(p: &Probe, t: &Task) -> Option<Ranking> {
    let s = seed(t)?;
    let g = p.graph;
    let fi = g.file_idx(Path::new(s))?;
    let rank = &g.file_rank;
    let mut score: Vec<f64> = rank.clone();
    // Neighbours first (offset past every global score), each in global-rank order.
    for &n in g.res[fi as usize].edges.iter().chain(g.importers[fi as usize].iter()) {
        score[n as usize] = 1.0 + rank[n as usize];
    }
    Some(Ranking { files: ranked(p, fi, &score), symbols: Vec::new(), exclude: vec![s.clone()] })
}

fn map_open(p: &Probe, t: &Task) -> Option<Ranking> {
    let s = seed(t)?;
    let text = p.tool("map", json!({ "top_n": DEPTH, "boost_files": [p.root.join(s).display().to_string()] }));
    let mut r = p.ranking_from(&text);
    r.symbols.clear();
    r.exclude = vec![s.clone()];
    Some(r)
}

/// Reciprocal-rank fusion (k = 60) of the file lists; symbols are the first part's.
fn rrf(parts: &[Ranking]) -> Ranking {
    let mut score: HashMap<&String, f64> = HashMap::new();
    for r in parts {
        for (i, f) in r.files.iter().enumerate() {
            *score.entry(f).or_default() += 1.0 / (60.0 + i as f64);
        }
    }
    let mut files: Vec<(&String, f64)> = score.into_iter().collect();
    files.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal).then(a.0.cmp(b.0)));
    Ranking {
        files: files.into_iter().take(DEPTH).map(|(f, _)| f.clone()).collect(),
        symbols: parts.first().map(|r| r.symbols.clone()).unwrap_or_default(),
        exclude: Vec::new(),
    }
}

fn fused(p: &Probe, t: &Task, other: fn(&Probe, &Task) -> Option<Ranking>) -> Option<Ranking> {
    let s = seed(t)?.clone();
    let a = bm25(p, t)?;
    let b = other(p, t)?;
    let mut r = rrf(&[a, b]);
    r.exclude = vec![s];
    Some(r)
}

pub(super) fn strategies() -> Vec<(String, Strategy)> {
    let mut v: Vec<(String, Strategy)> = Vec::new();
    for rev in [0u32, 1, 5, 20] {
        v.push((format!("ppr_open_rev{rev}"), Arc::new(move |p, t| ppr_open(p, t, rev as f64))));
    }
    v.push(("nbr_open".into(), Arc::new(nbr_open)));
    v.push((
        "bm25_open".into(),
        Arc::new(|p, t| {
            let s = seed(t)?.clone();
            let mut r = bm25(p, t)?;
            r.exclude = vec![s];
            Some(r)
        }),
    ));
    v.push(("bm25_map_open".into(), Arc::new(|p, t| fused(p, t, map_open))));
    v.push(("bm25_nbr_open".into(), Arc::new(|p, t| fused(p, t, nbr_open))));
    v
}
