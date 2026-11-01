//! History text: for each symbol, the subjects and changed lines of the recent commits that
//! touched it, searchable with BM25. It answers prose ("refuse a release the preview would
//! refuse") where no identifier matches, because the words that describe a change were written in
//! the commit that made it.
//!
//! Like co-change, history belongs to a repository at a commit, not to a worktree's content: the
//! daemon builds one index per repository at HEAD (`compute`) and rebuilds it in the background
//! when HEAD moves. A search names documents by `(path, qualified name)`; the caller maps them onto
//! the symbols of the view it answers from, so a symbol whose lines moved since still matches and a
//! symbol that no longer exists drops out.
//!
//! How a commit becomes text:
//! - `git log -p -U0 --raw` over the last `max_commits` non-merge commits that changed an indexable
//!   file. A commit that changes more than `MAX_FILES_PER_COMMIT` indexable files is a sweep (a
//!   rename, a format pass) and relates its subject to everything, so it is skipped.
//! - Each hunk's old lines are mapped onto the symbols of the old blob and its new lines onto the
//!   new blob (tree-sitter facts, read from the store when present, else parsed here). A hunk is
//!   credited to the innermost symbols it overlaps (a method, not its class), and always to the
//!   file itself, whose document ranks files.
//! - A credited symbol's document gains the commit subject once, plus at most `MAX_HUNK_TOKENS`
//!   words of the changed lines (`Options::hunks`, on by default: on the relevance harness the
//!   changed lines lift File@10 by 11-13 points over subjects alone, for 2.2-2.7x the memory).
//!
//! Every posting carries its commit, so a search can be restricted to a subset of the history: the
//! relevance harness asks "as of the task's parent commit", which keeps a task's own commit (and
//! everything after it) out of its answer.

use crate::error::{Error, Result};
use crate::facts::{BlobFacts, Symbol};
use crate::lang;
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, BufReader};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Instant;

pub const MAX_COMMITS: usize = 2000;
/// Postings store a commit's position in 16 bits.
const COMMIT_CAP: usize = u16::MAX as usize;
pub const MAX_FILES_PER_COMMIT: usize = 40;
/// Words of changed lines credited to one symbol by one commit (`Options::hunk_tokens`): a rewrite
/// of a long function must not drown the subjects of every other commit that touched it.
pub const MAX_HUNK_TOKENS: usize = 64;
/// BM25's usual constants.
const K1: f64 = 1.2;
const B: f64 = 0.75;

#[derive(Debug, Clone)]
pub struct Options {
    pub max_commits: usize,
    /// Add the words of changed lines to the subjects.
    pub hunks: bool,
    /// At most this many changed-line words per symbol and commit (four times as many for the
    /// file's own document).
    pub hunk_tokens: usize,
}

impl Default for Options {
    fn default() -> Options {
        Options { max_commits: MAX_COMMITS, hunks: true, hunk_tokens: MAX_HUNK_TOKENS }
    }
}

/// One term occurrence: a document, the commit that put the term there, how often. Eight bytes:
/// postings are most of the index.
#[derive(Debug, Clone, Copy)]
struct Posting {
    doc: u32,
    commit: u16,
    tf: u16,
}

#[derive(Debug, Clone)]
pub struct CommitInfo {
    pub id: String,
    pub subject: String,
    /// Committer time, seconds: the newer of two equally good commits is shown.
    pub time: i64,
}

/// What building the index cost, for logs and the harness.
#[derive(Debug, Clone, Default)]
pub struct BuildStats {
    /// Commits were added to a previous index rather than read from scratch.
    pub incremental: bool,
    pub commits_scanned: usize,
    pub commits_indexed: usize,
    pub mass_skipped: usize,
    pub blobs: usize,
    pub blobs_parsed: usize,
    pub docs: usize,
    pub postings: usize,
    pub millis: u128,
}

/// One search result: a symbol (or, with an empty `symbol`, a file) and its best commit.
#[derive(Debug, Clone, PartialEq)]
pub struct HistoryHit {
    pub path: String,
    /// Qualified name, `Parent.name`; empty for the file's own document.
    pub symbol: String,
    pub score: f64,
    /// Index into `HistoryIndex::commits` of the commit whose words scored highest.
    pub commit: u32,
}

#[derive(Debug, Default, Clone)]
pub struct HistoryIndex {
    /// Newest first; postings refer to commits by position here.
    pub commits: Vec<CommitInfo>,
    docs: Vec<(String, String)>,
    terms: HashMap<String, u32>,
    /// term -> occurrences.
    postings: Vec<Vec<Posting>>,
    /// doc -> (commit, words that commit added).
    lens: Vec<Vec<(u16, u32)>>,
    pub stats: BuildStats,
}

/// Which commits a search may use. `All` is the daemon's view; `Only` is "history as of some
/// commit", the set of indexed commits that are its ancestors.
#[derive(Debug, Clone, Copy)]
pub enum Scope<'a> {
    All,
    Only(&'a HashSet<u32>),
}

impl Scope<'_> {
    fn allows(&self, c: u32) -> bool {
        match self {
            Scope::All => true,
            Scope::Only(s) => s.contains(&c),
        }
    }
}

/// What the tools see: an index ready to search (restricted to `allow` when set), one still being
/// built, or none for this view (not a git repository, no commits).
#[derive(Debug, Clone)]
pub enum HistoryState {
    Ready { index: Arc<HistoryIndex>, allow: Option<Arc<HashSet<u32>>> },
    Building,
    Unavailable(String),
}

const STOPWORDS: &[&str] = &[
    "the", "and", "for", "with", "that", "this", "from", "into", "not", "are", "was", "were", "but", "its", "has", "have", "had",
    "now", "when", "then", "than", "one", "two", "all", "any", "each", "every", "only", "also", "own", "out", "off", "via", "who",
    "what", "which", "where", "why", "how", "can", "cannot", "does", "doesn", "don", "did", "will", "would", "should", "could",
    "may", "must", "never", "always", "still", "just", "same", "new", "old", "more", "less", "most", "some", "other", "they",
    "them", "their", "there", "these", "those", "our", "you", "your", "his", "her", "being", "been", "too", "very", "fix", "feat",
    "docs", "chore", "round", "add", "use", "make", "instead", "without", "while", "after", "before", "about", "over", "under",
    "between", "per", "again", "once", "is", "it", "in", "on", "of", "to", "an", "as", "at", "by", "be", "or", "so", "no", "if",
    "do", "up", "we", "let", "var", "self", "return", "pub", "fn", "func", "true", "false", "nil", "none", "null", "else", "end",
];

/// Lower-case words of prose or code: split on anything not alphanumeric and at camelCase and
/// acronym boundaries (`HTTPClient` -> `http`, `client`), two or more characters, stopwords out,
/// with a light plural fold (`refuses` -> `refuse`, `entries` -> `entry`) so a subject's verb
/// meets the query's.
pub fn words(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for chunk in text.split(|c: char| !c.is_alphanumeric()) {
        let chars: Vec<char> = chunk.chars().collect();
        let mut cur = String::new();
        for i in 0..chars.len() {
            let c = chars[i];
            let boundary = i > 0
                && c.is_uppercase()
                && (chars[i - 1].is_lowercase() || chars[i - 1].is_ascii_digit() || (chars[i - 1].is_uppercase() && chars.get(i + 1).is_some_and(|n| n.is_lowercase())));
            if boundary && !cur.is_empty() {
                push_word(&mut out, &cur);
                cur.clear();
            }
            cur.push(c);
        }
        if !cur.is_empty() {
            push_word(&mut out, &cur);
        }
    }
    out
}

fn push_word(out: &mut Vec<String>, w: &str) {
    let w = w.to_lowercase();
    if w.chars().count() < 2 || w.chars().all(|c| c.is_ascii_digit()) || STOPWORDS.contains(&w.as_str()) {
        return;
    }
    out.push(fold(w));
}

fn fold(w: String) -> String {
    if w.len() > 4 && w.ends_with("ies") {
        return format!("{}y", &w[..w.len() - 3]);
    }
    if w.len() > 3 && w.ends_with('s') && !w.ends_with("ss") && !w.ends_with("us") && !w.ends_with("is") {
        return w[..w.len() - 1].to_string();
    }
    w
}

/// One file of one commit, as `git log --raw -p -U0` reports it.
#[derive(Debug, Default)]
struct FileChange {
    path: String,
    old_blob: Option<String>,
    new_blob: Option<String>,
    /// (old start, old count, new start, new count, changed-line words)
    hunks: Vec<(u32, u32, u32, u32, Vec<String>)>,
}

#[derive(Debug, Default)]
struct RawCommit {
    id: String,
    subject: String,
    time: i64,
    files: Vec<FileChange>,
    raw_count: usize,
}

fn null_oid(s: &str) -> bool {
    s.bytes().all(|b| b == b'0')
}

/// `:(glob)**/*.ext` for every extension a language module handles.
fn pathspecs() -> Vec<String> {
    lang::all().iter().flat_map(|l| l.extensions().iter().map(|e| format!(":(glob)**/*.{e}"))).collect()
}

/// Stream `git log` and hand each commit to `each` as soon as it is complete, so only one
/// commit's diff is held at a time. Without `patches` only the `--raw` file list is read.
fn read_log(worktree: &Path, commit: &str, opts: &Options, patches: bool, each: &mut dyn FnMut(RawCommit)) -> Result<()> {
    let mut cmd = Command::new("git");
    cmd.args(["log", "-n", &opts.max_commits.min(COMMIT_CAP).to_string(), "--no-merges", "--no-renames", "--raw", "--no-abbrev", "--no-color", "--no-ext-diff"])
        .args(if patches { &["-p", "-U0"][..] } else { &[][..] })
        .arg("--format=%x01%H%x02%ct%x02%s")
        .arg(commit)
        .arg("--")
        .args(pathspecs())
        .current_dir(worktree)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| Error::io(worktree, e))?;
    let stdout = child.stdout.take().unwrap();
    let mut current: Option<RawCommit> = None;
    let mut by_path: HashMap<String, usize> = HashMap::new();
    let mut current_file: Option<usize> = None;
    let mut buf = Vec::new();
    let mut r = BufReader::new(stdout);
    loop {
        buf.clear();
        if r.read_until(b'\n', &mut buf).map_err(|e| Error::io(worktree, e))? == 0 {
            break;
        }
        let line = String::from_utf8_lossy(&buf);
        let line = line.trim_end_matches(['\n', '\r']);
        if let Some(rest) = line.strip_prefix('\x01') {
            let mut parts = rest.splitn(3, '\x02');
            let (id, time, subject) = (parts.next().unwrap_or(""), parts.next().unwrap_or("0"), parts.next().unwrap_or(""));
            let next = RawCommit { id: id.to_string(), subject: subject.to_string(), time: time.parse().unwrap_or(0), ..Default::default() };
            if let Some(done) = current.replace(next) {
                each(done);
            }
            by_path.clear();
            current_file = None;
            continue;
        }
        let Some(c) = current.as_mut() else { continue };
        if let Some(raw) = line.strip_prefix(':') {
            // :old_mode new_mode old_oid new_oid status\tpath
            let Some((meta, path)) = raw.split_once('\t') else { continue };
            let f: Vec<&str> = meta.split_whitespace().collect();
            if f.len() < 5 {
                continue;
            }
            c.raw_count += 1;
            if lang::for_path(Path::new(path)).is_none() {
                continue;
            }
            by_path.insert(path.to_string(), c.files.len());
            c.files.push(FileChange {
                path: path.to_string(),
                old_blob: (!null_oid(f[2])).then(|| f[2].to_string()),
                new_blob: (!null_oid(f[3])).then(|| f[3].to_string()),
                hunks: Vec::new(),
            });
        } else if let Some(p) = line.strip_prefix("diff --git a/") {
            // `diff --git a/x b/x`: no renames, so both sides are the same path.
            let half = p.len().saturating_sub(3) / 2;
            current_file = p.get(..half).and_then(|path| by_path.get(path).copied());
        } else if let Some(h) = line.strip_prefix("@@ -") {
            let Some(i) = current_file else { continue };
            let mut parts = h.split_whitespace();
            let (Some(old), Some(new)) = (parts.next(), parts.next()) else { continue };
            let range = |s: &str| -> (u32, u32) {
                match s.split_once(',') {
                    Some((a, n)) => (a.parse().unwrap_or(0), n.parse().unwrap_or(1)),
                    None => (s.parse().unwrap_or(0), 1),
                }
            };
            let (a, n) = range(old);
            let (cs, m) = range(new.trim_start_matches('+'));
            c.files[i].hunks.push((a, n, cs, m, Vec::new()));
        } else if opts.hunks && (line.starts_with('+') || line.starts_with('-')) && !line.starts_with("+++") && !line.starts_with("---") {
            let Some(i) = current_file else { continue };
            if let Some(h) = c.files[i].hunks.last_mut()
                && h.4.len() < opts.hunk_tokens * 4
            {
                h.4.extend(words(&line[1..]));
            }
        }
    }
    if let Some(done) = current.take() {
        each(done);
    }
    let status = child.wait().map_err(|e| Error::io(worktree, e))?;
    if !status.success() {
        let mut err = String::new();
        if let Some(mut e) = child.stderr.take() {
            use std::io::Read;
            let _ = e.read_to_string(&mut err);
        }
        return Err(Error::Git { args: "log -p --raw".into(), message: err.trim().to_string() });
    }
    Ok(())
}

/// What a hunk needs of a blob: each symbol's line span and qualified name. Full facts (refs,
/// imports) of thousands of historical blobs would cost hundreds of MB while the index builds.
struct Spans {
    lines: Vec<(u32, u32)>,
    names: Vec<String>,
}

impl Spans {
    fn of(facts: &BlobFacts) -> Spans {
        Spans {
            lines: facts.symbols.iter().map(|s| (s.start_line, s.end_line)).collect(),
            names: facts.symbols.iter().map(|s| qualified_name(&facts.symbols, s)).collect(),
        }
    }
}

/// `Parent.Inner.name` from a symbol and the symbols of its file.
pub fn qualified_name(symbols: &[Symbol], s: &Symbol) -> String {
    let mut parts = vec![s.name.as_str()];
    let mut p = s.parent;
    let mut guard = 0;
    while let Some(pi) = p {
        let Some(ps) = symbols.get(pi as usize) else { break };
        parts.push(ps.name.as_str());
        p = ps.parent;
        guard += 1;
        if guard > 16 {
            break;
        }
    }
    parts.reverse();
    parts.join(".")
}

/// Innermost symbols overlapping lines `a..=b`: a hunk inside a method credits the method, not
/// the class around it.
fn innermost(spans: &[(u32, u32)], a: u32, b: u32) -> Vec<usize> {
    let over: Vec<usize> = (0..spans.len()).filter(|&i| spans[i].0 <= b && a <= spans[i].1).collect();
    over.iter()
        .copied()
        .filter(|&i| {
            let (s, e) = spans[i];
            !over.iter().any(|&j| j != i && s <= spans[j].0 && spans[j].1 <= e && spans[j] != spans[i])
        })
        .collect()
}

/// Lines a hunk side covers. A side with no lines (pure insertion or deletion) sits after line
/// `start`, which the eval harness also credits to the symbol enclosing that line.
fn side(start: u32, count: u32) -> Option<(u32, u32)> {
    if start == 0 && count == 0 {
        return None;
    }
    Some(if count == 0 { (start.max(1), start.max(1)) } else { (start, start + count - 1) })
}

/// Symbol spans of every blob the commits of `rev` need: stored facts where `known` has them,
/// else read from git and parsed. Returns the spans and how many blobs were parsed.
fn spans_for(worktree: &Path, rev: &str, opts: &Options, known: &dyn Fn(&str, &'static str) -> Option<BlobFacts>) -> Result<(HashMap<String, Spans>, usize)> {
    let mut wanted: HashMap<String, &'static str> = HashMap::new();
    read_log(worktree, rev, opts, false, &mut |c| {
        if c.raw_count > MAX_FILES_PER_COMMIT {
            return;
        }
        for f in c.files {
            let Some(l) = lang::for_path(Path::new(&f.path)) else { continue };
            for b in [f.old_blob, f.new_blob].into_iter().flatten() {
                wanted.entry(b).or_insert(l.id());
            }
        }
    })?;
    let mut facts: HashMap<String, Spans> = HashMap::with_capacity(wanted.len());
    let mut missing: Vec<(String, &'static str)> = Vec::new();
    for (blob, l) in wanted {
        match known(&blob, l) {
            Some(f) => {
                facts.insert(blob, Spans::of(&f));
            }
            None => missing.push((blob, l)),
        }
    }
    missing.sort();
    let parsed_count = missing.len();
    for chunk in missing.chunks(512) {
        let ids: Vec<&str> = chunk.iter().map(|(b, _)| b.as_str()).collect();
        let bytes = crate::engine::cat_file_batch(worktree, &ids)?;
        use rayon::prelude::*;
        let parsed: Vec<(String, Spans)> = chunk
            .par_iter()
            .zip(bytes.par_iter())
            .filter_map(|((blob, l), bytes)| {
                let bytes = bytes.as_ref()?;
                if bytes.len() as u64 > crate::git::MAX_FILE_BYTES {
                    return None;
                }
                let text = std::str::from_utf8(bytes).ok()?;
                let l = lang::by_id(l)?;
                let f = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| l.extract(text))).ok()?;
                Some((blob.clone(), Spans::of(&f)))
            })
            .collect();
        facts.extend(parsed);
    }
    Ok((facts, parsed_count))
}

/// Adds commits to an index.
struct Builder<'a> {
    idx: HistoryIndex,
    doc_ids: HashMap<(String, String), u32>,
    opts: &'a Options,
}

impl<'a> Builder<'a> {
    fn new(idx: HistoryIndex, opts: &'a Options) -> Builder<'a> {
        let doc_ids = idx.docs.iter().enumerate().map(|(i, k)| (k.clone(), i as u32)).collect();
        Builder { idx, doc_ids, opts }
    }

    fn doc(&mut self, key: (String, String)) -> u32 {
        if let Some(&d) = self.doc_ids.get(&key) {
            return d;
        }
        let d = self.idx.docs.len() as u32;
        self.idx.docs.push(key.clone());
        self.idx.lens.push(Vec::new());
        self.doc_ids.insert(key, d);
        d
    }

    /// Credit one commit's subject and changed-line words to the documents its hunks touch.
    fn add(&mut self, c: RawCommit, facts: &HashMap<String, Spans>) {
        let stats = &mut self.idx.stats;
        stats.commits_scanned += 1;
        if c.raw_count > MAX_FILES_PER_COMMIT {
            stats.mass_skipped += 1;
            return;
        }
        if c.files.is_empty() {
            return;
        }
        let ci = self.idx.commits.len() as u16;
        let subject = words(&c.subject);
        let cap = self.opts.hunk_tokens;
        let mut per_doc: HashMap<u32, HashMap<String, u32>> = HashMap::new();
        for f in &c.files {
            let file_doc = self.doc((f.path.clone(), String::new()));
            let mut credited: HashMap<u32, usize> = HashMap::new(); // doc -> hunk words so far
            credited.insert(file_doc, 0);
            for (a, n, cs, m, hunk_words) in &f.hunks {
                let mut targets: Vec<u32> = vec![file_doc];
                for (blob, range) in [(&f.old_blob, side(*a, *n)), (&f.new_blob, side(*cs, *m))] {
                    let (Some(blob), Some((lo, hi))) = (blob, range) else { continue };
                    let Some(bf) = facts.get(blob) else { continue };
                    for si in innermost(&bf.lines, lo, hi) {
                        let d = self.doc((f.path.clone(), bf.names[si].clone()));
                        if !targets.contains(&d) {
                            targets.push(d);
                        }
                    }
                }
                for d in targets {
                    let used = credited.entry(d).or_insert(0);
                    let limit = if d == file_doc { cap * 4 } else { cap };
                    let take = limit.saturating_sub(*used).min(hunk_words.len());
                    *used += take;
                    let tf = per_doc.entry(d).or_default();
                    for w in &hunk_words[..take] {
                        *tf.entry(w.clone()).or_default() += 1;
                    }
                }
            }
            for d in credited.keys() {
                let tf = per_doc.entry(*d).or_default();
                for w in &subject {
                    *tf.entry(w.clone()).or_default() += 1;
                }
            }
        }
        let idx = &mut self.idx;
        for (d, tf) in per_doc {
            let len: u32 = tf.values().sum();
            if len == 0 {
                continue;
            }
            idx.lens[d as usize].push((ci, len));
            for (w, n) in tf {
                let next = idx.terms.len() as u32;
                let t = *idx.terms.entry(w).or_insert(next);
                if t as usize == idx.postings.len() {
                    idx.postings.push(Vec::new());
                }
                idx.postings[t as usize].push(Posting { doc: d, commit: ci, tf: n.min(u16::MAX as u32) as u16 });
            }
        }
        idx.commits.push(CommitInfo { id: c.id, subject: c.subject, time: c.time });
    }

    fn finish(self) -> HistoryIndex {
        let mut idx = self.idx;
        for p in &mut idx.postings {
            p.shrink_to_fit();
        }
        for l in &mut idx.lens {
            l.shrink_to_fit();
        }
        idx.docs.shrink_to_fit();
        idx.stats.commits_indexed = idx.commits.len();
        idx.stats.docs = idx.docs.len();
        idx.stats.postings = idx.postings.iter().map(Vec::len).sum();
        idx
    }
}

/// `rev` read in two passes: file lists to find the blobs, then diffs streamed into the builder.
fn ingest(b: &mut Builder, worktree: &Path, rev: &str, known: &dyn Fn(&str, &'static str) -> Option<BlobFacts>) -> Result<()> {
    let (facts, parsed) = spans_for(worktree, rev, b.opts, known)?;
    b.idx.stats.blobs += facts.len();
    b.idx.stats.blobs_parsed += parsed;
    let opts = b.opts;
    read_log(worktree, rev, opts, true, &mut |c| b.add(c, &facts))
}

impl HistoryIndex {
    /// Build the index of the last `opts.max_commits` commits reachable from `commit`. `known`
    /// returns stored facts for `(blob, language)` when the store has them; the rest are read
    /// from git and parsed here (and not stored: a historical blob is no view's, so gc would
    /// collect it anyway).
    pub fn compute(worktree: &Path, commit: &str, opts: &Options, known: &dyn Fn(&str, &'static str) -> Option<BlobFacts>) -> Result<HistoryIndex> {
        let started = Instant::now();
        let mut b = Builder::new(HistoryIndex::default(), opts);
        ingest(&mut b, worktree, commit, known)?;
        let mut idx = b.finish();
        idx.stats.millis = started.elapsed().as_millis();
        Ok(idx)
    }

    /// The index at `commit`, from this one built at `prev`. When HEAD only moved forward by a
    /// few commits, those commits are added to a copy (seconds of work become milliseconds, and
    /// the window grows by them); otherwise, or once the window has grown a tenth past
    /// `max_commits`, it is a full `compute`.
    pub fn update(&self, prev: &str, worktree: &Path, commit: &str, opts: &Options, known: &dyn Fn(&str, &'static str) -> Option<BlobFacts>) -> Result<HistoryIndex> {
        let started = Instant::now();
        let slack = (opts.max_commits / 10).max(1);
        let forward = Command::new("git")
            .args(["merge-base", "--is-ancestor", prev, commit])
            .current_dir(worktree)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .status()
            .is_ok_and(|s| s.success());
        let ahead = if forward {
            let out = Command::new("git").args(["rev-list", "--count", "--no-merges", &format!("{prev}..{commit}")]).current_dir(worktree).env("GIT_OPTIONAL_LOCKS", "0").output();
            out.ok().and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<usize>().ok())
        } else {
            None
        };
        match ahead {
            Some(n) if n <= slack && self.commits.len() + n <= opts.max_commits + slack => {
                let mut fresh = self.clone();
                fresh.stats = BuildStats { incremental: true, ..Default::default() };
                let mut b = Builder::new(fresh, opts);
                ingest(&mut b, worktree, &format!("{prev}..{commit}"), known)?;
                let mut idx = b.finish();
                idx.stats.millis = started.elapsed().as_millis();
                Ok(idx)
            }
            _ => HistoryIndex::compute(worktree, commit, opts, known),
        }
    }

    /// Approximate heap bytes held, for the build log and the harness.
    pub fn bytes(&self) -> usize {
        let strings: usize = self.commits.iter().map(|c| c.id.len() + c.subject.len() + 48).sum::<usize>()
            + self.docs.iter().map(|(p, s)| p.len() + s.len() + 48).sum::<usize>()
            + self.terms.keys().map(|k| k.len() + 32).sum::<usize>();
        let postings: usize = self.postings.iter().map(|p| p.capacity() * std::mem::size_of::<Posting>() + 24).sum();
        let lens: usize = self.lens.iter().map(|l| l.capacity() * std::mem::size_of::<(u16, u32)>() + 24).sum();
        strings + postings + lens
    }

    /// The `limit` best documents for `query` by BM25 over the commits `scope` allows.
    pub fn search(&self, query: &str, scope: Scope, limit: usize) -> Vec<HistoryHit> {
        let mut q = words(query);
        q.sort();
        q.dedup();
        let terms: Vec<u32> = q.iter().filter_map(|w| self.terms.get(w).copied()).collect();
        if terms.is_empty() {
            return Vec::new();
        }
        let restricted = !matches!(scope, Scope::All);
        // Document lengths over the allowed commits.
        let mut n_docs = 0usize;
        let mut total = 0u64;
        let doc_len: Vec<u32> = self
            .lens
            .iter()
            .map(|l| {
                let len: u32 = if restricted { l.iter().filter(|(c, _)| scope.allows(*c as u32)).map(|(_, n)| n).sum() } else { l.iter().map(|(_, n)| n).sum() };
                if len > 0 {
                    n_docs += 1;
                    total += len as u64;
                }
                len
            })
            .collect();
        if n_docs == 0 {
            return Vec::new();
        }
        let avg = total as f64 / n_docs as f64;
        let n = n_docs as f64;
        // doc -> (score, best commit, best commit's matched words)
        let mut acc: HashMap<u32, (f64, u32, u32)> = HashMap::new();
        let mut per_commit: HashMap<(u32, u32), u32> = HashMap::new();
        for t in terms {
            let mut tf: HashMap<u32, u32> = HashMap::new();
            for &Posting { doc: d, commit, tf: f } in &self.postings[t as usize] {
                let c = commit as u32;
                if scope.allows(c) {
                    *tf.entry(d).or_default() += f as u32;
                    *per_commit.entry((d, c)).or_default() += 1;
                }
            }
            let df = tf.len() as f64;
            if df == 0.0 {
                continue;
            }
            let idf = ((n - df + 0.5) / (df + 0.5) + 1.0).ln();
            for (d, f) in tf {
                let f = f as f64;
                let len = doc_len[d as usize] as f64;
                let s = idf * f * (K1 + 1.0) / (f + K1 * (1.0 - B + B * len / avg));
                acc.entry(d).or_insert((0.0, u32::MAX, 0)).0 += s;
            }
        }
        // Best commit per document: the one matching the most query words, newest on a tie.
        // Ties on time (commits of the same second) fall to the id, so an index grown by `update`
        // names the same commit as a full build.
        let key = |c: u32| (self.commits[c as usize].time, &self.commits[c as usize].id);
        let newer = |a: u32, b: u32| b == u32::MAX || key(a) > key(b);
        for ((d, c), m) in per_commit {
            if let Some(e) = acc.get_mut(&d)
                && (m > e.2 || (m == e.2 && newer(c, e.1)))
            {
                e.1 = c;
                e.2 = m;
            }
        }
        let mut hits: Vec<HistoryHit> = acc
            .into_iter()
            .map(|(d, (score, commit, _))| {
                let (path, symbol) = &self.docs[d as usize];
                HistoryHit { path: path.clone(), symbol: symbol.clone(), score, commit }
            })
            .collect();
        hits.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal).then(a.path.cmp(&b.path)).then(a.symbol.cmp(&b.symbol)));
        hits.truncate(limit);
        hits
    }

    /// Position of a commit id in `commits`, for building a `Scope::Only`.
    pub fn commit_positions(&self) -> HashMap<&str, u32> {
        self.commits.iter().enumerate().map(|(i, c)| (c.id.as_str(), i as u32)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_split_code_and_fold_plurals() {
        assert_eq!(words("HTTPClient refuses entries"), ["http", "client", "refuse", "entry"]);
        assert_eq!(words("fix: the InfraPreflight.checkTofu path"), ["infra", "preflight", "check", "tofu", "path"]);
        assert_eq!(words("class status bus 2026"), ["class", "status", "bus"]);
    }

    #[test]
    fn innermost_prefers_the_method_over_its_class() {
        let sym = |name: &str, a, b, parent| Symbol {
            local_id: 0,
            name: name.into(),
            kind: crate::facts::SymbolKind::Function,
            start_line: a,
            start_col: 0,
            end_line: b,
            end_col: 0,
            signature: None,
            parent,
            exported: true,
        };
        let syms = vec![sym("C", 1, 30, None), sym("m", 5, 10, Some(0)), sym("n", 12, 20, Some(0))];
        let spans: Vec<(u32, u32)> = syms.iter().map(|s| (s.start_line, s.end_line)).collect();
        assert_eq!(innermost(&spans, 6, 7), vec![1]);
        assert_eq!(innermost(&spans, 9, 13), vec![1, 2]);
        assert_eq!(innermost(&spans, 25, 26), vec![0]);
        assert_eq!(qualified_name(&syms, &syms[1]), "C.m");
    }
}
