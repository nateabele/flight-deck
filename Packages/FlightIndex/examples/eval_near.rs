//! Scores `near` (graph-distance ordering) on `find`, `grep`, `refs` and `impact`, on and off,
//! under leak-free seeds handed to the tools the way the service hands its default seed set:
//! through `Ctx::recent` (the agent's diff plus the files it read last), not the `near` argument.
//! So a cell scores what a tool does by default, and the per-tool default is set from them.
//!
//! Seeds (`src/eval/seeds.rs`):
//!
//! * `auth1`, `auth3`: the files the same author's previous 1 or 3 commits touched, all ancestors
//!   of the task's parent: what the agent was just working on. Every task is answered; a task
//!   whose author has no earlier commit gets no seed and so the `off` answer.
//! * `open`: the task's first gold file (the file the agent has open), on tasks with 2 or more
//!   gold files; the seed is dropped from the ranking and the gold set. `openoff` is the same task
//!   set and exclusion with no seed.
//!
//! An earlier version seeded with the files the parent commit changed. The measuring loop that
//! put tessera `grep` File@10 at 39.2 seeded with files it had itself just changed, which leaks.
//!
//! Cells: `{find,grep,refs}_{off,auth1,auth3,openoff,open}`, each `<tool> <key>=<term>` per term
//! of the task, merged round-robin. `impact` asks about the first gold file (tasks with 2+ gold
//! files, the file excluded) with co-change from the parent's history: `impact_{off,auth1,auth3,
//! open}` read the whole main text (the `Ranked impact` list first, which the default seeds do
//! not reorder), `impactrad_*` only the `Direct importers` and `Transitive blast radius` lists
//! (which they do), and `impact_{auth3,open}x` pass the same seeds as an explicit `near`, which
//! reorders the ranked list too.
//!
//! ```text
//! cargo build --release --features eval --example eval_near
//! ./target/release/examples/eval_near --repo tessera=/path@master --tasks 200 --store S --out O \
//!   --only find_off,find_auth1,… --label near
//! ```
use flightindex::cochange::CoChange;
use flightindex::eval::{interleave, main_with, seeds, Probe, Ranking, Strategy, Task, DEPTH};
use flightindex::tools::{self, args::Args, Ctx, Format};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

type Cache<T> = Mutex<HashMap<String, T>>;

static AUTHOR: std::sync::LazyLock<Cache<Vec<String>>> = std::sync::LazyLock::new(Default::default);
static CO: Mutex<Option<(String, Arc<CoChange>)>> = Mutex::new(None);

fn author(p: &Probe, t: &Task, n: usize) -> Vec<String> {
    let key = format!("{}:{n}", t.commit);
    if let Some(v) = AUTHOR.lock().unwrap().get(&key) {
        return v.clone();
    }
    let v = seeds::author_files(p.root, &t.commit, &t.parent, n);
    AUTHOR.lock().unwrap().insert(key, v.clone());
    v
}

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

#[derive(Clone, Copy, PartialEq)]
enum Seed {
    Off,
    Author(usize),
    OpenOff,
    Open,
}

impl Seed {
    fn name(self) -> String {
        match self {
            Seed::Off => "off".into(),
            Seed::Author(n) => format!("auth{n}"),
            Seed::OpenOff => "openoff".into(),
            Seed::Open => "open".into(),
        }
    }
    fn needs_two(self) -> bool {
        matches!(self, Seed::OpenOff | Seed::Open)
    }
    /// Relative paths of the seed set, `None` when the seeding does not apply to the task.
    fn files(self, p: &Probe, t: &Task) -> Option<Vec<String>> {
        if self.needs_two() && t.gold_files.len() < 2 {
            return None;
        }
        Some(match self {
            Seed::Off | Seed::OpenOff => Vec::new(),
            Seed::Author(n) => author(p, t, n),
            Seed::Open => vec![t.gold_files[0].clone()],
        })
    }
}

fn abs(p: &Probe, files: &[String]) -> Vec<PathBuf> {
    files.iter().map(|f| p.root.join(f)).collect()
}

fn per_term(p: &Probe, t: &Task, tool: &str, key: &str, seed: Seed) -> Option<Ranking> {
    let terms = t.terms();
    if terms.is_empty() {
        return None;
    }
    let recent = abs(p, &seed.files(p, t)?);
    let mut r = interleave(terms.iter().map(|w| p.ranking_from(&p.tool_recent(tool, json!({ key: w, "limit": DEPTH }), &recent))).collect());
    if seed.needs_two() {
        r.exclude = vec![t.gold_files[0].clone()];
    }
    Some(r)
}

/// `impact` on the first gold file as the service answers it: co-change on, `recent` as the
/// default seed set, and (when `explicit`) the same seeds as the `near` argument.
fn impact_text(p: &Probe, t: &Task, recent: &[PathBuf], explicit: bool) -> String {
    let mut map = Map::new();
    map.insert("file_path".into(), json!(p.root.join(&t.gold_files[0]).display().to_string()));
    map.insert("format".into(), json!("concise"));
    map.insert("token_budget".into(), json!(1_000_000_000u64));
    if explicit {
        map.insert("near".into(), Value::from(recent.iter().map(|f| f.display().to_string()).collect::<Vec<_>>()));
    }
    for (k, v) in p.extra {
        map.insert(k.clone(), v.clone());
    }
    let args = Args::new(map, p.root.to_path_buf());
    let co = cochange(p.root, &t.parent);
    let get = move || -> flightindex::error::Result<Arc<CoChange>> { Ok(co.clone()) };
    let no_base = || -> flightindex::error::Result<Option<tools::Baseline>> { Ok(None) };
    let no_history = || flightindex::history::HistoryState::Unavailable("no history in eval".into());
    let ctx = Ctx { graph: p.graph, args: &args, format: Format::Concise, token_budget: 1_000_000_000, building: None, members: &[], recent, cochange: &get, diff: &[], base: &no_base, history: &no_history };
    tools::run("impact", &ctx).unwrap_or_default()
}

/// The rows of the sections whose heading starts with one of `headings`, as text the harness's
/// location reader can read. A heading is a line that does not start with a space.
fn sections(text: &str, headings: &[&str]) -> String {
    let (mut out, mut inside) = (String::new(), false);
    for line in text.lines() {
        if !line.starts_with(' ') && !line.starts_with('-') && !line.starts_with('…') {
            inside = headings.iter().any(|h| line.starts_with(h));
            continue;
        }
        if inside {
            out.push_str(line);
            out.push('\n');
        }
    }
    out
}

fn impact(p: &Probe, t: &Task, seed: Seed, radius_only: bool, explicit: bool) -> Option<Ranking> {
    if t.gold_files.len() < 2 {
        return None;
    }
    let recent = abs(p, &seed.files(p, t)?);
    let text = impact_text(p, t, &recent, explicit);
    let wanted: &[&str] = if radius_only { &["Direct importers", "Transitive blast radius"] } else { &["Ranked impact", "Direct importers", "Transitive blast radius"] };
    let mut r = p.ranking_from(&sections(&text, wanted));
    // Radius rows (`- path (depth 2)`) put one space before the parenthesis, which the location
    // reader keeps; cut it so those rows match a gold file.
    let mut files: Vec<String> = Vec::new();
    for f in r.files.drain(..) {
        let f = f.split(" (").next().unwrap_or(&f).to_string();
        if !files.contains(&f) {
            files.push(f);
        }
    }
    r.files = files;
    r.symbols.clear();
    r.exclude = vec![t.gold_files[0].clone()];
    Some(r)
}

fn main() {
    let mut extra: Vec<(String, Strategy)> = Vec::new();
    let all = [Seed::Off, Seed::Author(1), Seed::Author(3), Seed::OpenOff, Seed::Open];
    for (tool, key) in [("find", "name"), ("grep", "query"), ("refs", "symbol")] {
        for seed in all {
            extra.push((format!("{tool}_{}", seed.name()), Arc::new(move |p, t| per_term(p, t, tool, key, seed))));
        }
    }
    // `impact` asks about the first gold file, so every cell is on the 2+ gold subset already and
    // `off` is its own `openoff`.
    for seed in [Seed::Off, Seed::Author(1), Seed::Author(3), Seed::Open] {
        extra.push((format!("impact_{}", seed.name()), Arc::new(move |p, t| impact(p, t, seed, false, false))));
        extra.push((format!("impactrad_{}", seed.name()), Arc::new(move |p, t| impact(p, t, seed, true, false))));
    }
    for seed in [Seed::Author(3), Seed::Open] {
        extra.push((format!("impact_{}x", seed.name()), Arc::new(move |p, t| impact(p, t, seed, false, true))));
    }
    main_with(extra);
}
