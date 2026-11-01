//! Scores the history-text tier (`src/history.rs`) next to the built-in strategies.
//!
//! The history index of each repository is built once, at `FDI_HIST_REV` (default `master`), over
//! the last `FDI_HIST_COMMITS` (default 2000) commits. Each task searches it "as of" the task's
//! parent: only commits that are ancestors of the parent count, so the task's own commit and every
//! later one are out (`hist*`). `hist` is the shipped default (subjects plus up to 64 changed-line
//! words per symbol and commit); `hist_subj` is subjects only and `hist_h<N>` caps the words at N.
//! `hist_loo` drops only the task's own commit (leave-one-out), which
//! lets later commits that mention the same work leak in; it bounds the leak, it is not a result.
//!
//! `find_hist`, `grep_hist`, `bm25_hist`: the built-in ranking and the history tier read side by
//! side (round-robin), what an agent that ran both would see. `find_tier` and `grep_tier` call the
//! real `find`/`grep` tools with the prose query and the history tier wired in.
//!
//! `cargo build --release --features eval --example eval_history`, then run it with the flags of
//! `examples/eval.rs` and `FDI_HIST_STORE=<the --store dir>` so stored facts are reused.
use flightindex::eval::{self, interleave, Probe, Ranking, Strategy, Task};
use flightindex::history::{qualified_name, HistoryIndex, HistoryState, Options, Scope};
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

/// (hunks, hunk words per symbol and commit)
type Variant = (bool, usize);
type Indexes = Mutex<HashMap<(PathBuf, Variant), Arc<HistoryIndex>>>;

const DEFAULT: Variant = (true, flightindex::history::MAX_HUNK_TOKENS);

fn indexes() -> &'static Indexes {
    static I: OnceLock<Indexes> = OnceLock::new();
    I.get_or_init(Default::default)
}

fn git(root: &Path, args: &[&str]) -> String {
    let out = Command::new("git").arg("-C").arg(root).args(args).output().expect("git");
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn index_for(root: &Path, (hunks, hunk_tokens): Variant) -> Arc<HistoryIndex> {
    let mut m = indexes().lock().unwrap();
    if let Some(i) = m.get(&(root.to_path_buf(), (hunks, hunk_tokens))) {
        return i.clone();
    }
    let rev = std::env::var("FDI_HIST_REV").unwrap_or_else(|_| "master".into());
    let commits: usize = std::env::var("FDI_HIST_COMMITS").ok().and_then(|v| v.parse().ok()).unwrap_or(2000);
    let head = git(root, &["rev-parse", &rev]).trim().to_string();
    let repo = PathBuf::from(git(root, &["rev-parse", "--path-format=absolute", "--git-common-dir"]).trim()).canonicalize().unwrap();
    let reader = std::env::var("FDI_HIST_STORE").ok().and_then(|s| flightindex::store::Reader::open(Path::new(&s), &repo).ok());
    let known = |blob: &str, lang: &'static str| -> Option<flightindex::facts::BlobFacts> {
        let v = flightindex::lang::by_id(lang)?.parser_version();
        reader.as_ref()?.get_facts(blob, lang, v).ok().flatten()
    };
    let opts = Options { max_commits: commits, hunks, hunk_tokens };
    let t = Instant::now();
    let idx = Arc::new(HistoryIndex::compute(root, &head, &opts, &known).expect("history"));
    eprintln!(
        "[history] {} hunks={hunks} cap={hunk_tokens}: {:.2}s, {:.1} MB, {:?}; load {}",
        root.display(),
        t.elapsed().as_secs_f64(),
        idx.bytes() as f64 / 1e6,
        idx.stats,
        load()
    );
    m.insert((root.to_path_buf(), (hunks, hunk_tokens)), idx.clone());
    idx
}

fn load() -> String {
    let out = Command::new("sysctl").args(["-n", "vm.loadavg"]).output().unwrap();
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

/// Positions (in `idx.commits`) of the indexed commits that are ancestors of `parent`, or every
/// indexed commit except `commit` when `loo`.
fn allowed(p: &Probe, idx: &HistoryIndex, t: &Task, loo: bool) -> HashSet<u32> {
    let pos = idx.commit_positions();
    if loo {
        return pos.iter().filter(|(c, _)| **c != t.commit).map(|(_, i)| *i).collect();
    }
    let n = (idx.commits.len() * 3).to_string();
    git(p.root, &["rev-list", "--no-merges", "-n", &n, &t.parent]).lines().filter_map(|c| pos.get(c).copied()).collect()
}

/// History hits mapped onto the parent tree: files in hit order, symbols that still exist.
fn hist_ranking(p: &Probe, t: &Task, v: Variant, loo: bool) -> Option<Ranking> {
    let idx = index_for(p.root, v);
    let allow = allowed(p, &idx, t, loo);
    let hits = idx.search(&t.query, Scope::Only(&allow), eval::DEPTH * 20);
    let g = p.graph;
    let mut r = Ranking::default();
    let mut names: HashMap<u32, Vec<String>> = HashMap::new();
    for h in hits {
        let Some(fi) = g.file_idx(Path::new(&h.path)) else { continue };
        if !r.files.contains(&h.path) {
            r.files.push(h.path.clone());
        }
        if h.symbol.is_empty() || r.symbols.len() >= eval::DEPTH {
            continue;
        }
        let node = g.file(fi);
        let q = names.entry(fi).or_insert_with(|| node.facts.symbols.iter().map(|s| qualified_name(&node.facts.symbols, s)).collect());
        if let Some(si) = q.iter().position(|n| *n == h.symbol) {
            let loc = (h.path.clone(), node.facts.symbols[si].start_line);
            if !r.symbols.contains(&loc) {
                r.symbols.push(loc);
            }
        }
    }
    Some(r)
}

fn tier(p: &Probe, t: &Task, tool: &str) -> Option<Ranking> {
    let idx = index_for(p.root, DEFAULT);
    let allow = Arc::new(allowed(p, &idx, t, false));
    let state = HistoryState::Ready { index: idx, allow: Some(allow) };
    let key = if tool == "find" { "name" } else { "query" };
    let text = p.tool_with(tool, json!({ key: t.query, "limit": eval::DEPTH }), &|| state.clone());
    Some(p.ranking_from(&text))
}

/// `FDI_HIST_BENCH=<repo path>`: time a full build at `master~20`, the update to `master`, and a
/// full build at `master`.
fn bench(root: &Path) {
    let opts = Options::default();
    let none = |_: &str, _: &'static str| None;
    // `FDI_HIST_BENCH_ONE`: one full build only, so peak RSS is one index's.
    let runs: &[(&str, &str)] = if std::env::var("FDI_HIST_BENCH_ONE").is_ok() { &[("full at master", "master")] } else { &[("full at master~20", "master~20"), ("full at master", "master")] };
    for &(label, at) in runs {
        let t = Instant::now();
        let idx = HistoryIndex::compute(root, at, &opts, &none).expect("history");
        eprintln!("{label}: {:.2}s, {:.1} MB, {:?}; load {}", t.elapsed().as_secs_f64(), idx.bytes() as f64 / 1e6, idx.stats, load());
        if at == "master~20" {
            let prev = git(root, &["rev-parse", at]).trim().to_string();
            let t = Instant::now();
            let up = idx.update(&prev, root, "master", &opts, &none).expect("update");
            eprintln!("update master~20 -> master: {:.3}s, {:?}; load {}", t.elapsed().as_secs_f64(), up.stats, load());
        }
    }
}

fn main() {
    if let Ok(root) = std::env::var("FDI_HIST_BENCH") {
        return bench(Path::new(&root));
    }
    let builtins: HashMap<String, Strategy> = eval::builtin_strategies().into_iter().collect();
    let with = |base: &str| -> Strategy {
        let b = builtins[base].clone();
        Arc::new(move |p: &Probe, t: &Task| {
            let h = hist_ranking(p, t, DEFAULT, false)?;
            let base = b(p, t).unwrap_or_default();
            Some(interleave(vec![base, h]))
        })
    };
    let v: Vec<(String, Strategy)> = vec![
        ("hist_subj".into(), Arc::new(|p, t| hist_ranking(p, t, (false, 0), false))),
        ("hist".into(), Arc::new(|p, t| hist_ranking(p, t, DEFAULT, false))),
        ("hist_h16".into(), Arc::new(|p, t| hist_ranking(p, t, (true, 16), false))),
        ("hist_h32".into(), Arc::new(|p, t| hist_ranking(p, t, (true, 32), false))),
        ("hist_h128".into(), Arc::new(|p, t| hist_ranking(p, t, (true, 128), false))),
        ("hist_loo".into(), Arc::new(|p, t| hist_ranking(p, t, DEFAULT, true))),
        ("find_hist".into(), with("find")),
        ("grep_hist".into(), with("grep")),
        ("bm25_hist".into(), with("bm25")),
        ("find_tier".into(), Arc::new(|p, t| tier(p, t, "find"))),
        ("grep_tier".into(), Arc::new(|p, t| tier(p, t, "grep"))),
    ];
    eval::main_with(v);
}
