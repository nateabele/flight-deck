//! Relevance evaluation: how often do `map`, `find`, `grep` (and any ranking variant someone
//! plugs in) put the code a change really touched near the top?
//!
//! Tasks are mined from git history. A non-merge commit that is not a mass change becomes one
//! task: its message is the task text, the indexable files it modified are the gold files, and
//! the function-like symbols its hunks overlap in the parent tree are the gold symbols. Each task
//! is answered from the parent commit's tree, indexed straight from git's object store (no
//! checkout): the view's listing is `git ls-tree <parent>` and blobs come from `cat-file`, so the
//! blob-keyed store parses each distinct blob once across every task and every later run.
//!
//! A strategy turns `(graph, task)` into a ranked list of files and symbols. Scores are File@k
//! (k = 1, 5, 10) and Function@k (k = 5, 10), each the share of the gold set found in the top k,
//! normalised by `min(k, |gold|)` so a perfect ranking scores 1. Built-in strategies call the
//! real tool code (`tools::run`) and read the locations back out of its text, so what is scored
//! is what an agent sees. See `docs/superpowers/specs/2026-11-01-index-eval-harness.md`.

use crate::engine::Engine;
use crate::facts::SymbolKind;
use crate::git::{self, View, ViewLabel};
use crate::graph::ViewGraph;
use crate::tools::{self, args::Args, Ctx, Format};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::Instant;

/// A commit that changes more files than this is a mass change (a rename sweep, a format pass).
pub const MAX_CHANGED_FILES: usize = 25;
/// Gold sets larger than this say little about ranking; such commits are skipped too.
pub const MAX_GOLD_FILES: usize = 12;
/// How deep each strategy is asked to rank. Ten is all the metrics read; the slack lets
/// `map_open` drop its seed file and still have ten.
pub const DEPTH: usize = 20;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Task {
    pub repo: String,
    pub commit: String,
    pub parent: String,
    pub subject: String,
    pub body: String,
    /// Modified indexable files (old path for a rename), relative to the repository root.
    pub gold_files: Vec<String>,
    /// Old-side line ranges each hunk touched, per gold file. A pure insertion after line `a`
    /// is recorded as `(a, a)`, which the enclosing symbol overlaps.
    pub hunks: Vec<(String, Vec<(u32, u32)>)>,
    /// Filled per run from the parent's graph: `(path, start_line, name)`.
    #[serde(skip)]
    pub gold_symbols: Vec<(String, u32, String)>,
    /// The text a strategy should treat as the request (subject, or subject + body).
    #[serde(skip)]
    pub query: String,
}

impl Task {
    /// Words of the request that could name code: identifier-shaped, three or more characters,
    /// not a stopword; deduplicated case-insensitively, original case kept, at most 12.
    pub fn terms(&self) -> Vec<String> {
        crate::words::query_tokens(&self.query)
    }
}

pub use crate::words::{split_words, STOPWORDS};

/// A ranking, best first. `exclude` names files to drop from both the ranking and the gold set
/// (the "open file" a seeded strategy was handed is not something it found).
#[derive(Debug, Default, Clone)]
pub struct Ranking {
    pub files: Vec<String>,
    /// `(path, start_line)` of each symbol.
    pub symbols: Vec<(String, u32)>,
    pub exclude: Vec<String>,
}

/// What a strategy may look at: the parent tree's graph, and the real tools over it.
pub struct Probe<'a> {
    pub graph: &'a ViewGraph,
    pub root: &'a Path,
    /// Extra tool arguments from `--args <strategy>=<json>`, merged into every `tool` call, so a
    /// variant that lives behind a tool argument is scored without touching the harness.
    pub extra: &'a Map<String, Value>,
}

impl Probe<'_> {
    /// Run one read-only tool over the graph exactly as the service would, with an unlimited
    /// token budget so nothing is cut before the metrics read it.
    pub fn tool(&self, tool: &str, args: Value) -> String {
        let none = || crate::history::HistoryState::Unavailable("no history in eval".into());
        self.tool_with(tool, args, &none)
    }

    /// `tool` with a history tier (`src/history.rs`): a strategy hands it the index restricted to
    /// what the task's parent commit could have known.
    pub fn tool_with(&self, tool: &str, args: Value, history: &(dyn Fn() -> crate::history::HistoryState + Sync)) -> String {
        let mut map = match args {
            Value::Object(m) => m,
            _ => Map::new(),
        };
        map.entry("token_budget").or_insert(json!(1_000_000_000u64));
        map.entry("format").or_insert(json!("concise"));
        for (k, v) in self.extra {
            map.insert(k.clone(), v.clone());
        }
        let args = Args::new(map, self.root.to_path_buf());
        let none = || -> crate::error::Result<Arc<crate::cochange::CoChange>> { Err(crate::error::Error::Msg("no co-change in eval".into())) };
        let no_base = || -> crate::error::Result<Option<tools::Baseline>> { Ok(None) };
        let ctx = Ctx { graph: self.graph, args: &args, format: Format::Concise, token_budget: 1_000_000_000, building: None, members: &[], recent: &[], cochange: &none, diff: &[], base: &no_base, history };
        tools::run(tool, &ctx).unwrap_or_default()
    }

    /// Every location a tool's text names, in order: `(relative path, start line if shown)`.
    /// Paths are recognised by the worktree prefix, so this reads `map`, `find` and `grep` alike.
    pub fn locations(&self, text: &str) -> Vec<(String, Option<u32>)> {
        let prefix = format!("{}/", self.root.display());
        let mut out = Vec::new();
        for line in text.lines() {
            let Some(at) = line.find(&prefix) else { continue };
            let rest = &line[at + prefix.len()..];
            let end = [rest.find(" ["), rest.find(" | "), rest.find("  ")].into_iter().flatten().min().unwrap_or(rest.len());
            let path = rest[..end].trim_end().to_string();
            let start = rest[end..].strip_prefix(" [L").and_then(|r| r.split('-').next()).and_then(|n| n.parse().ok());
            out.push((path, start));
        }
        out
    }

    /// A ranking from tool text: files in first-mention order, symbols where a line is shown.
    pub fn ranking_from(&self, text: &str) -> Ranking {
        let mut r = Ranking::default();
        for (path, line) in self.locations(text) {
            if !r.files.contains(&path) {
                r.files.push(path.clone());
            }
            if let Some(l) = line {
                r.symbols.push((path, l));
            }
        }
        r
    }
}

pub type Strategy = Arc<dyn Fn(&Probe, &Task) -> Option<Ranking> + Send + Sync>;

/// Round-robin merge of several rankings (one per query term), deduplicated: what an agent
/// that ran one search per word and read the heads of each would see.
pub fn interleave(parts: Vec<Ranking>) -> Ranking {
    let mut out = Ranking::default();
    let longest = parts.iter().map(|p| p.files.len().max(p.symbols.len())).max().unwrap_or(0);
    for i in 0..longest {
        for p in &parts {
            if let Some(f) = p.files.get(i)
                && !out.files.contains(f) {
                    out.files.push(f.clone());
                }
            if let Some(s) = p.symbols.get(i)
                && !out.symbols.contains(s) {
                    out.symbols.push(s.clone());
                }
        }
    }
    out
}

fn map_ranking(p: &Probe, seed: Value) -> Ranking {
    let mut files_args = seed.clone();
    files_args["top_n"] = json!(DEPTH);
    let mut sym_args = seed;
    sym_args["top_n"] = json!(DEPTH);
    sym_args["by"] = json!("symbols");
    let files = p.ranking_from(&p.tool("map", files_args)).files;
    let symbols = p.ranking_from(&p.tool("map", sym_args)).symbols;
    Ranking { files, symbols, exclude: Vec::new() }
}

/// The strategies every run knows by name.
pub fn builtin_strategies() -> Vec<(String, Strategy)> {
    let mut v: Vec<(String, Strategy)> = Vec::new();
    v.push(("map".into(), Arc::new(|p, _t| Some(map_ranking(p, json!({}))))));
    v.push((
        "map_terms".into(),
        Arc::new(|p, t| {
            let terms: Vec<String> = t.terms().iter().map(|w| w.to_lowercase()).collect();
            (!terms.is_empty()).then(|| map_ranking(p, json!({ "boost_terms": terms })))
        }),
    ));
    v.push((
        "map_open".into(),
        Arc::new(|p, t| {
            // The first gold file plays the file the agent has open; it needs a second to find.
            if t.gold_files.len() < 2 {
                return None;
            }
            let seed = t.gold_files[0].clone();
            let mut r = map_ranking(p, json!({ "boost_files": [p.root.join(&seed).display().to_string()] }));
            r.exclude = vec![seed];
            Some(r)
        }),
    ));
    v.push((
        "find".into(),
        Arc::new(|p, t| {
            let terms = t.terms();
            (!terms.is_empty()).then(|| interleave(terms.iter().map(|w| p.ranking_from(&p.tool("find", json!({ "name": w, "limit": DEPTH })))).collect()))
        }),
    ));
    v.push((
        "grep".into(),
        Arc::new(|p, t| {
            let terms = t.terms();
            (!terms.is_empty()).then(|| interleave(terms.iter().map(|w| p.ranking_from(&p.tool("grep", json!({ "query": w, "limit": DEPTH })))).collect()))
        }),
    ));
    v.push(("bm25".into(), Arc::new(bm25)));
    v.push((
        "grep_words".into(),
        // The whole request as one `grep` query: a sentence is ranked by words. 200 rows, so the
        // files of the best 200 symbols are what File@10 reads, as for `bm25`.
        Arc::new(|p, t| (!t.terms().is_empty()).then(|| p.ranking_from(&p.tool("grep", json!({ "query": t.query, "rank": true, "limit": DEPTH * 10 }))))),
    ));
    v
}

// ---- BM25 over split qualified symbol ids (the report's tier 3) ------------------------------

/// The graph's own word index (`crate::words`), queried directly: the same ranking `grep`
/// gives a sentence, without the tool's text round trip. Files in first-mention order of the
/// best 200 symbols.
fn bm25(p: &Probe, t: &Task) -> Option<Ranking> {
    let words = crate::words::query_words(&t.query);
    if words.is_empty() {
        return None;
    }
    let mut r = Ranking::default();
    for (_, id) in p.graph.words().search(&words).into_iter().take(DEPTH * 10) {
        let path = &p.graph.file(id.file).path;
        if !r.files.contains(path) {
            r.files.push(path.clone());
        }
        if r.symbols.len() < DEPTH {
            r.symbols.push((path.clone(), p.graph.symbol(id).start_line));
        }
    }
    Some(r)
}

// ---- mining tasks from git history -----------------------------------------------------------

fn git_out(root: &Path, args: &[&str]) -> String {
    let out = Command::new("git").arg("-C").arg(root).args(args).output().expect("git");
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// Up to `want` tasks from the first-parent-agnostic, merge-free history of `rev`, newest first,
/// after skipping the newest `skip` eligible ones (a holdout).
pub fn mine(name: &str, root: &Path, rev: &str, want: usize, skip: usize) -> Vec<Task> {
    let log = git_out(root, &["log", "--no-merges", "--format=%H %P", &format!("-n{}", (want + skip) * 6), rev]);
    let mut tasks = Vec::new();
    let mut eligible = 0;
    for line in log.lines() {
        let ids: Vec<&str> = line.split_whitespace().collect();
        let [commit, parent] = ids[..] else { continue };
        let status = git_out(root, &["diff", "--name-status", "-z", "-M", parent, commit]);
        let fields: Vec<&str> = status.split('\0').filter(|s| !s.is_empty()).collect();
        let (mut changed, mut gold, mut i) = (0usize, Vec::new(), 0);
        while i < fields.len() {
            let st = fields[i];
            let paths = if st.starts_with('R') || st.starts_with('C') { 2 } else { 1 };
            let old = fields.get(i + 1).copied().unwrap_or("");
            changed += 1;
            if (st == "M" || st.starts_with('R')) && crate::lang::for_path(Path::new(old)).is_some() {
                gold.push(old.to_string());
            }
            i += 1 + paths;
        }
        if gold.is_empty() || changed > MAX_CHANGED_FILES || gold.len() > MAX_GOLD_FILES {
            continue;
        }
        eligible += 1;
        if eligible <= skip {
            continue;
        }
        let mut args = vec!["diff", "-U0", "--no-color", "--no-ext-diff", "-M", parent, commit, "--"];
        args.extend(gold.iter().map(String::as_str));
        let hunks = parse_hunks(&git_out(root, &args), &gold);
        let msg = git_out(root, &["show", "-s", "--format=%s%x00%b", commit]);
        let (subject, body) = msg.split_once('\0').unwrap_or((&msg, ""));
        tasks.push(Task {
            repo: name.to_string(),
            commit: commit.to_string(),
            parent: parent.to_string(),
            subject: subject.trim().to_string(),
            body: body.trim().to_string(),
            gold_files: gold,
            hunks,
            gold_symbols: Vec::new(),
            query: String::new(),
        });
        if tasks.len() == want {
            break;
        }
    }
    tasks
}

fn parse_hunks(diff: &str, gold: &[String]) -> Vec<(String, Vec<(u32, u32)>)> {
    let mut out: Vec<(String, Vec<(u32, u32)>)> = Vec::new();
    let mut current = false;
    for line in diff.lines() {
        if let Some(p) = line.strip_prefix("--- ") {
            let p = p.strip_prefix("a/").unwrap_or(p);
            current = gold.iter().any(|g| g == p);
            if current {
                out.push((p.to_string(), Vec::new()));
            }
        } else if !current {
            continue;
        } else if let Some(h) = line.strip_prefix("@@ -") {
            let old = h.split_whitespace().next().unwrap_or("");
            let (a, n) = match old.split_once(',') {
                Some((a, n)) => (a.parse::<u32>().unwrap_or(0), n.parse::<u32>().unwrap_or(1)),
                None => (old.parse().unwrap_or(0), 1),
            };
            if let Some(last) = out.last_mut() {
                last.1.push(if n == 0 { (a.max(1), a.max(1)) } else { (a, a + n - 1) });
            }
        }
    }
    out
}

fn function_like(k: SymbolKind) -> bool {
    matches!(k, SymbolKind::Function | SymbolKind::Method | SymbolKind::Constructor | SymbolKind::Macro | SymbolKind::Port)
}

/// Function-like symbols of the parent tree that the commit's hunks overlap.
pub fn gold_symbols(g: &ViewGraph, t: &Task) -> Vec<(String, u32, String)> {
    let mut out = Vec::new();
    for (path, ranges) in &t.hunks {
        let Some(fi) = g.file_idx(Path::new(path)) else { continue };
        for s in &g.file(fi).facts.symbols {
            if function_like(s.kind) && ranges.iter().any(|(a, b)| s.start_line <= *b && *a <= s.end_line) {
                out.push((path.clone(), s.start_line, s.name.clone()));
            }
        }
    }
    out.sort();
    out.dedup();
    out
}

// ---- scoring ----------------------------------------------------------------------------------

pub const FILE_KS: [usize; 3] = [1, 5, 10];
pub const FUNC_KS: [usize; 2] = [5, 10];

/// Share of `gold` in the first `k` of `ranked`, out of `min(k, |gold|)`.
pub fn recall_at<T: Eq + std::hash::Hash>(ranked: &[T], gold: &HashSet<T>, k: usize) -> f64 {
    if gold.is_empty() {
        return 0.0;
    }
    let hits = ranked.iter().take(k).filter(|x| gold.contains(x)).count();
    hits as f64 / k.min(gold.len()) as f64
}

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Score {
    pub tasks: usize,
    pub func_tasks: usize,
    pub file: [f64; 3],
    pub func: [f64; 2],
    pub millis: f64,
}

impl Score {
    fn mean(&self) -> Score {
        let n = self.tasks.max(1) as f64;
        let m = self.func_tasks.max(1) as f64;
        Score {
            tasks: self.tasks,
            func_tasks: self.func_tasks,
            file: self.file.map(|x| x / n),
            func: self.func.map(|x| x / m),
            millis: self.millis / n,
        }
    }
}

#[derive(Debug, Serialize)]
struct TaskResult<'a> {
    repo: &'a str,
    commit: &'a str,
    strategy: &'a str,
    gold_files: Vec<String>,
    top_files: Vec<String>,
    file: [f64; 3],
    func: Option<[f64; 2]>,
}

pub struct RepoSpec {
    pub name: String,
    pub root: PathBuf,
    pub rev: String,
}

pub struct Config {
    pub repos: Vec<RepoSpec>,
    pub tasks: usize,
    pub skip: usize,
    pub store: PathBuf,
    pub out: PathBuf,
    pub full_message: bool,
    pub only: Option<Vec<String>>,
    pub extra: HashMap<String, Map<String, Value>>,
    pub label: String,
    pub compare: Option<PathBuf>,
}

fn load_avg() -> String {
    let out = Command::new("sysctl").args(["-n", "vm.loadavg"]).output().ok();
    out.map(|o| String::from_utf8_lossy(&o.stdout).trim().trim_matches(['{', '}']).trim().to_string()).unwrap_or_default()
}

/// Mine (or reuse the cached) tasks, answer each from its parent tree with every strategy, print
/// and save the scores. Returns `repo -> strategy -> mean score`.
pub fn run(cfg: &Config, strategies: &[(String, Strategy)]) -> BTreeMap<String, BTreeMap<String, Score>> {
    std::fs::create_dir_all(&cfg.out).expect("out dir");
    let engine = Engine::open(&cfg.store).expect("open store");
    // Tasks never revisit a parent tree, so caching graphs only grows RSS; keep about one.
    engine.set_graph_budget(256 << 20);
    let selected: Vec<&(String, Strategy)> = strategies.iter().filter(|(n, _)| cfg.only.as_ref().is_none_or(|o| o.contains(n))).collect();
    let mut summary: BTreeMap<String, BTreeMap<String, Score>> = BTreeMap::new();
    let mut per_task = std::fs::File::create(cfg.out.join(format!("{}-tasks.jsonl", cfg.label))).expect("results file");
    for spec in &cfg.repos {
        let started = Instant::now();
        let head = git_out(&spec.root, &["rev-parse", &spec.rev]).trim().to_string();
        let cache = cfg.out.join(format!("tasks-{}-{}-{}-{}.json", spec.name, &head[..head.len().min(12)], cfg.tasks, cfg.skip));
        let mut tasks: Vec<Task> = match std::fs::read(&cache).ok().and_then(|b| serde_json::from_slice(&b).ok()) {
            Some(t) => t,
            None => {
                let t = mine(&spec.name, &spec.root, &head, cfg.tasks, cfg.skip);
                std::fs::write(&cache, serde_json::to_vec_pretty(&t).unwrap()).expect("write task cache");
                t
            }
        };
        eprintln!("[{}] {} tasks ({:.1}s to mine or load; load {})", spec.name, tasks.len(), started.elapsed().as_secs_f64(), load_avg());
        let repo = PathBuf::from(git_out(&spec.root, &["rev-parse", "--path-format=absolute", "--git-common-dir"]).trim()).canonicalize().expect("git dir");
        let root = spec.root.canonicalize().expect("repo root");
        let mut sums: BTreeMap<String, Score> = BTreeMap::new();
        let (mut build_ms, mut graph_ms, mut skipped) = (0.0, 0.0, 0);
        let total = tasks.len();
        for (n, t) in tasks.iter_mut().enumerate() {
            t.query = if cfg.full_message && !t.body.is_empty() { format!("{}\n{}", t.subject, t.body) } else { t.subject.clone() };
            let base = Arc::new(git::list_tree(&root, &t.parent).expect("ls-tree"));
            let view = View {
                label: ViewLabel { repo: repo.clone(), worktree: root.clone(), base_commit: Some(t.parent.clone()), dirty: false, is_git: true },
                base,
                overlay: Vec::new(),
            };
            let b = Instant::now();
            engine.build(&view, &[], |_| {}).expect("build");
            build_ms += b.elapsed().as_secs_f64() * 1000.0;
            let b = Instant::now();
            let graph = engine.graph(&view).expect("graph");
            graph_ms += b.elapsed().as_secs_f64() * 1000.0;
            t.gold_files.retain(|f| graph.file_idx(Path::new(f)).is_some());
            if t.gold_files.is_empty() {
                skipped += 1;
                continue;
            }
            t.gold_symbols = gold_symbols(&graph, t);
            for (name, strat) in &selected {
                let empty = Map::new();
                let probe = Probe { graph: &graph, root: &root, extra: cfg.extra.get(name).unwrap_or(&empty) };
                let s = Instant::now();
                let Some(mut r) = strat(&probe, t) else { continue };
                let ms = s.elapsed().as_secs_f64() * 1000.0;
                r.files.retain(|f| !r.exclude.contains(f));
                r.symbols.retain(|(f, _)| !r.exclude.contains(f));
                let gold_files: HashSet<String> = t.gold_files.iter().filter(|f| !r.exclude.contains(f)).cloned().collect();
                if gold_files.is_empty() {
                    continue;
                }
                let gold_syms: HashSet<(String, u32)> = t.gold_symbols.iter().filter(|(f, _, _)| !r.exclude.contains(f)).map(|(f, l, _)| (f.clone(), *l)).collect();
                let file = FILE_KS.map(|k| recall_at(&r.files, &gold_files, k));
                let func = (!gold_syms.is_empty()).then(|| FUNC_KS.map(|k| recall_at(&r.symbols, &gold_syms, k)));
                let acc = sums.entry(name.clone()).or_default();
                acc.tasks += 1;
                acc.millis += ms;
                for (sum, v) in acc.file.iter_mut().zip(file) {
                    *sum += v;
                }
                if let Some(f) = func {
                    acc.func_tasks += 1;
                    acc.func[0] += f[0];
                    acc.func[1] += f[1];
                }
                let row = TaskResult {
                    repo: &spec.name,
                    commit: &t.commit,
                    strategy: name,
                    gold_files: gold_files.into_iter().collect(),
                    top_files: r.files.iter().take(10).cloned().collect(),
                    file,
                    func,
                };
                use std::io::Write;
                let _ = writeln!(per_task, "{}", serde_json::to_string(&row).unwrap());
            }
            if (n + 1) % 25 == 0 {
                eprintln!("[{}] {}/{} tasks, {:.0}s, load {}", spec.name, n + 1, total, started.elapsed().as_secs_f64(), load_avg());
            }
        }
        eprintln!(
            "[{}] done in {:.1}s: build {:.1}s, graphs {:.1}s ({:.0} ms/task), {} tasks lost their gold files; load {}",
            spec.name,
            started.elapsed().as_secs_f64(),
            build_ms / 1000.0,
            graph_ms / 1000.0,
            graph_ms / total.max(1) as f64,
            skipped,
            load_avg()
        );
        summary.insert(spec.name.clone(), sums.into_iter().map(|(k, v)| (k, v.mean())).collect());
    }
    let previous: Option<BTreeMap<String, BTreeMap<String, Score>>> =
        cfg.compare.as_ref().and_then(|p| std::fs::read(p).ok()).and_then(|b| serde_json::from_slice(&b).ok());
    print_table(&summary, previous.as_ref());
    std::fs::write(cfg.out.join(format!("{}-summary.json", cfg.label)), serde_json::to_vec_pretty(&summary).unwrap()).expect("write summary");
    summary
}

fn print_table(s: &BTreeMap<String, BTreeMap<String, Score>>, prev: Option<&BTreeMap<String, BTreeMap<String, Score>>>) {
    println!("repo        strategy     tasks  File@1  File@5  File@10 | ftasks  Func@5  Func@10 | ms/task");
    for (repo, rows) in s {
        for (name, sc) in rows {
            let p = prev.and_then(|p| p.get(repo)).and_then(|r| r.get(name));
            let cell = |v: f64, old: Option<f64>| match old {
                Some(o) => format!("{:>6.1}{:+5.1}", v * 100.0, (v - o) * 100.0),
                None => format!("{:>6.1}", v * 100.0),
            };
            println!(
                "{:<11} {:<12} {:>5}  {}  {}  {}  | {:>6}  {}  {}  | {:>7.1}",
                repo,
                name,
                sc.tasks,
                cell(sc.file[0], p.map(|p| p.file[0])),
                cell(sc.file[1], p.map(|p| p.file[1])),
                cell(sc.file[2], p.map(|p| p.file[2])),
                sc.func_tasks,
                cell(sc.func[0], p.map(|p| p.func[0])),
                cell(sc.func[1], p.map(|p| p.func[1])),
                sc.millis
            );
        }
    }
}

/// Parse the command line and run with the built-in strategies plus `extra`. A variant written
/// as a function is scored from a small example of its own:
/// `fn main() { flightindex::eval::main_with(vec![("mine".into(), Arc::new(|p, t| ...))]) }`.
pub fn main_with(extra: Vec<(String, Strategy)>) {
    let usage = "eval --repo NAME=PATH[@REV]... [--tasks 200] [--skip 0] [--store DIR] [--out DIR] [--message subject|full] \
                 [--only a,b] [--args STRATEGY=JSON]... [--label NAME] [--compare SUMMARY.json]";
    let mut a = std::env::args().skip(1);
    let mut cfg = Config {
        repos: Vec::new(),
        tasks: 200,
        skip: 0,
        store: PathBuf::from("eval-store"),
        out: PathBuf::from("eval-out"),
        full_message: false,
        only: None,
        extra: HashMap::new(),
        label: "run".into(),
        compare: None,
    };
    while let Some(flag) = a.next() {
        let mut val = || a.next().unwrap_or_else(|| panic!("{flag} needs a value\n{usage}"));
        match flag.as_str() {
            "--repo" => {
                let v = val();
                let (name, rest) = v.split_once('=').expect("--repo NAME=PATH[@REV]");
                let (path, rev) = rest.rsplit_once('@').unwrap_or((rest, "HEAD"));
                cfg.repos.push(RepoSpec { name: name.into(), root: PathBuf::from(path), rev: rev.into() });
            }
            "--tasks" => cfg.tasks = val().parse().expect("--tasks N"),
            "--skip" => cfg.skip = val().parse().expect("--skip N"),
            "--store" => cfg.store = PathBuf::from(val()),
            "--out" => cfg.out = PathBuf::from(val()),
            "--message" => cfg.full_message = val() == "full",
            "--only" => cfg.only = Some(val().split(',').map(String::from).collect()),
            "--args" => {
                let v = val();
                let (name, json) = v.split_once('=').expect("--args STRATEGY=JSON");
                let Value::Object(m) = serde_json::from_str(json).expect("--args JSON") else { panic!("--args takes a JSON object") };
                cfg.extra.insert(name.into(), m);
            }
            "--label" => cfg.label = val(),
            "--compare" => cfg.compare = Some(PathBuf::from(val())),
            _ => panic!("unknown flag {flag}\n{usage}"),
        }
    }
    assert!(!cfg.repos.is_empty(), "{usage}");
    let mut strategies = builtin_strategies();
    strategies.extend(extra);
    run(&cfg, &strategies);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recall_is_normalised_by_the_smaller_of_k_and_gold() {
        let gold: HashSet<&str> = ["a", "b", "c"].into_iter().collect();
        assert_eq!(recall_at(&["a", "x"], &gold, 1), 1.0);
        assert!((recall_at(&["x", "a", "b"], &gold, 5) - 2.0 / 3.0).abs() < 1e-9);
    }

    #[test]
    fn hunks_record_old_side_ranges() {
        let diff = "--- a/src/x.rs\n+++ b/src/x.rs\n@@ -10,3 +10,4 @@ fn a\n@@ -40,0 +41,2 @@\n--- a/other.md\n@@ -1 +1 @@\n";
        assert_eq!(parse_hunks(diff, &["src/x.rs".into()]), vec![("src/x.rs".to_string(), vec![(10, 12), (40, 40)])]);
    }
}
