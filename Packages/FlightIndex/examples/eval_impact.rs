//! Scores `impact` with the relevance harness: each task with 2+ gold files is seeded with its
//! first touched file (the file an agent would ask `impact` about), and the files `impact` lists
//! are scored against the other files the commit touched. Co-change is computed from the history
//! reachable from the task's parent, so the commit being predicted never informs its own answer.
//!
//! Besides the harness's File@k (recall normalised by `min(k, |gold|)`), this prints plain
//! precision@k (hits / k) and recall@k (hits / |gold|), the metrics of Gethers et al. (ICSE
//! 2012), and the recall of the gold test files by the `Tests` group.
//!
//! ```text
//! cargo build --release --features eval --example eval_impact
//! ./target/release/examples/eval_impact --repo fd=/path@master --tasks 200 --store S --out O --label L
//! ```
//! Strategies: `impact` (the tool's text, `Tests` group excluded from the ranking), `impact_tests`
//! (main list then the `Tests` group, against all gold), `impact_imports` / `impact_cochange`
//! (only the ranked rows carrying that reason, in the tool's order: single-source ablations), and
//! `impact_diff` / `impact_nodiff` (tasks with 3+ gold files: the second gold file is the worktree
//! diff, or not, and both seeds are left out of the gold set).

use flightindex::cochange::CoChange;
use flightindex::eval::{self, Probe, Ranking, Strategy, Task};
use flightindex::tools::{self, args::Args, is_test_path, Ctx, Format};
use serde_json::{json, Map};
use std::collections::{BTreeMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};

#[derive(Default, Clone, Copy)]
struct Acc {
    tasks: usize,
    p: [f64; 2],
    r: [f64; 2],
    test_tasks: usize,
    test_recall: f64,
    test_rows: usize,
}

const KS: [usize; 2] = [5, 10];

type CoCache = Mutex<Option<(String, Arc<CoChange>)>>;

static ACC: Mutex<BTreeMap<String, Acc>> = Mutex::new(BTreeMap::new());
static CO: CoCache = Mutex::new(None);

fn cochange(root: &Path, parent: &str) -> Arc<CoChange> {
    let mut slot = CO.lock().unwrap();
    if let Some((p, co)) = slot.as_ref()
        && p == parent
    {
        return co.clone();
    }
    let co = Arc::new(CoChange::compute(root, parent).unwrap_or_default());
    *slot = Some((parent.to_string(), co.clone()));
    co
}

/// `impact` on the task's first gold file, as the service would answer it, with co-change.
fn impact_text(p: &Probe, t: &Task, seed: &str, diff: &[String]) -> String {
    let mut map = Map::new();
    map.insert("file_path".into(), json!(p.root.join(seed).display().to_string()));
    map.insert("format".into(), json!("concise"));
    map.insert("token_budget".into(), json!(1_000_000_000u64));
    for (k, v) in p.extra {
        map.insert(k.clone(), v.clone());
    }
    let args = Args::new(map, p.root.to_path_buf());
    let co = cochange(p.root, &t.parent);
    let get = move || -> flightindex::error::Result<Arc<CoChange>> { Ok(co.clone()) };
    let no_base = || -> flightindex::error::Result<Option<tools::Baseline>> { Ok(None) };
    let ctx = Ctx { graph: p.graph, args: &args, format: Format::Concise, token_budget: 1_000_000_000, building: None, members: &[], recent: &[], cochange: &get, diff, base: &no_base };
    tools::run("impact", &ctx).unwrap_or_default()
}

/// Split the text into the main sections and the `Tests` group (whose rows end at the next
/// heading, a line that does not start with a space).
fn split_tests(text: &str) -> (String, String) {
    let (mut main, mut tests, mut in_tests) = (String::new(), String::new(), false);
    for line in text.lines() {
        if !line.starts_with(' ') && !line.starts_with('-') && !line.starts_with('…') {
            in_tests = line.starts_with("Tests (");
        }
        let into = if in_tests { &mut tests } else { &mut main };
        into.push_str(line);
        into.push('\n');
    }
    (main, tests)
}

/// The rows of the ranked section that carry `reason`, as text `ranking_from` can read.
fn ranked_rows_with(text: &str, reason: &str) -> String {
    let mut out = String::new();
    let mut inside = false;
    for line in text.lines() {
        if !line.starts_with(' ') {
            inside = line.starts_with("Ranked impact");
            continue;
        }
        if inside && line.contains(reason) {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

fn record(name: &str, r: &Ranking, t: &Task, exclude: &[String], tests: Option<&[String]>) {
    let gold: HashSet<&String> = t.gold_files.iter().filter(|f| !exclude.contains(f)).collect();
    if gold.is_empty() {
        return;
    }
    let mut acc = ACC.lock().unwrap();
    let a = acc.entry(format!("{:<8} {name}", t.repo)).or_default();
    a.tasks += 1;
    for (i, k) in KS.iter().enumerate() {
        let hits = r.files.iter().filter(|f| !exclude.contains(f)).take(*k).filter(|f| gold.contains(f)).count() as f64;
        a.p[i] += hits / *k as f64;
        a.r[i] += hits / gold.len() as f64;
    }
    if let Some(listed) = tests {
        let gold_tests: Vec<&&String> = gold.iter().filter(|f| is_test_path(f)).collect();
        a.test_rows += listed.len();
        if !gold_tests.is_empty() {
            a.test_tasks += 1;
            a.test_recall += gold_tests.iter().filter(|g| listed.contains(g)).count() as f64 / gold_tests.len() as f64;
        }
    }
}

fn strategy(name: &'static str) -> Strategy {
    Arc::new(move |p: &Probe, t: &Task| {
        // `*_diff` strategies play an agent that has already edited the second gold file and asks
        // `impact` about the first: the second is the worktree diff. `impact_nodiff` answers the
        // same tasks without it, so the two differ only in the diff seed.
        let with_diff = name.contains("diff");
        if t.gold_files.len() < if with_diff { 3 } else { 2 } {
            return None;
        }
        let seed = t.gold_files[0].clone();
        let diff: Vec<String> = if name == "impact_diff" { vec![t.gold_files[1].clone()] } else { Vec::new() };
        let text = impact_text(p, t, &seed, &diff);
        let (main, tests) = split_tests(&text);
        let listed_tests = p.ranking_from(&tests).files;
        let mut r = match name {
            n if n == "impact" || n.contains("diff") => p.ranking_from(&main),
            "impact_tests" => {
                let mut r = p.ranking_from(&main);
                let main_k: Vec<String> = r.files.iter().take(10).cloned().collect();
                // What an agent reads: the head of the main list, then the whole tests group.
                r.files = main_k.into_iter().chain(listed_tests.iter().cloned()).collect();
                r
            }
            "impact_imports" => p.ranking_from(&ranked_rows_with(&main, "importer")),
            "impact_cochange" => p.ranking_from(&ranked_rows_with(&main, "co-changed")),
            _ => unreachable!(),
        };
        // The harness's location reader ends a path at two spaces or ` [`; the radius rows
        // (`- path (depth 2)`) and the old co-change rows (`path (changed together 3×)`) put one
        // space before the parenthesis, so cut it here or those rows never match a gold file.
        let mut files: Vec<String> = Vec::new();
        for f in r.files.drain(..) {
            let f = f.split(" (").next().unwrap_or(&f).to_string();
            if !files.contains(&f) {
                files.push(f);
            }
        }
        r.files = files;
        r.exclude = if with_diff { vec![seed.clone(), t.gold_files[1].clone()] } else { vec![seed.clone()] };
        record(name, &r, t, &r.exclude.clone(), (name == "impact").then_some(listed_tests.as_slice()));
        Some(r)
    })
}

fn main() {
    let names = ["impact", "impact_tests", "impact_imports", "impact_cochange", "impact_diff", "impact_nodiff"];
    eval::main_with(names.iter().map(|n| (n.to_string(), strategy(n))).collect());
    println!("\nrepo     strategy          tasks   P@5    R@5    P@10   R@10  | test tasks  test recall  test rows/task");
    for (name, a) in ACC.lock().unwrap().iter() {
        let n = a.tasks.max(1) as f64;
        println!(
            "{name:<25} {:>6}  {:>5.1}  {:>5.1}  {:>5.1}  {:>5.1}  | {:>10}  {:>11.1}  {:>14.1}",
            a.tasks,
            100.0 * a.p[0] / n,
            100.0 * a.r[0] / n,
            100.0 * a.p[1] / n,
            100.0 * a.r[1] / n,
            a.test_tasks,
            100.0 * a.test_recall / a.test_tasks.max(1) as f64,
            a.test_rows as f64 / n
        );
    }
}
