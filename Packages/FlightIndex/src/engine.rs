//! Build orchestration: from a view to stored facts, and from stored facts to a graph.
//!
//! `build` lists the view, finds the blobs the store lacks, and parses the requested files and
//! their direct imports first so a waiting request can be answered from that slice while the rest
//! of the repository finishes (`Progress` says when). A second worktree on an indexed commit finds
//! every blob already stored and parses nothing; a worktree on a new commit parses only the blobs
//! the store has never seen. That "parse each blob once, whatever worktree holds it" property is
//! the point of keying facts by git blob.

use crate::error::{Error, Result};
use crate::facts::BlobFacts;
use crate::git::{self, FileRef, Overlay, View, MAX_FILE_BYTES};
use crate::graph::{facts_bytes, FileChange, ViewGraph};
use crate::lang;
use crate::resolve::{Resolved, Resolver};
use crate::store::{GcStats, ParsedBlob, Reader, Writer};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

/// Blobs per parse-then-write step: big enough to amortise a transaction and keep every core fed,
/// small enough that progress moves and memory stays bounded.
const BATCH: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Parsing the requested files and their direct imports.
    Priority,
    /// That slice is stored: a request waiting on it can be answered now.
    PriorityDone,
    /// Parsing the rest of the view.
    Rest,
    Done,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Progress {
    pub phase: Phase,
    /// Files of the view whose facts are stored.
    pub done: usize,
    pub total: usize,
}

#[derive(Debug, Clone, Default)]
pub struct BuildReport {
    pub total_files: usize,
    /// Files whose facts were already in the store when the build began.
    pub already_stored: usize,
    /// Blobs actually parsed by this build.
    pub parsed: usize,
    pub parsed_by_language: BTreeMap<String, usize>,
    /// Blobs recorded as skipped (not UTF-8).
    pub skipped: usize,
    /// Overlay files that changed on disk between the view and the read.
    pub changed_during_build: usize,
    /// Files in the priority slice (requested files plus their direct imports).
    pub priority_files: usize,
    pub elapsed: Duration,
}

#[derive(Clone, PartialEq, Eq, Hash)]
struct Key {
    blob_id: String,
    language: &'static str,
}

pub struct Engine {
    store_root: PathBuf,
    writers: Mutex<HashMap<PathBuf, Arc<Mutex<Writer>>>>,
    /// Parsing runs on its own pool with big stacks: the extractors recurse, and a pathological
    /// generated file must not overflow a 2 MB worker stack.
    pool: rayon::ThreadPool,
    parses: AtomicUsize,
    graphs: Mutex<GraphCache>,
    /// Commits of a repository whose whole tree has facts stored, so a request against a clean
    /// worktree on one needs no per-file check and no build, only its overlay looked at.
    complete: Mutex<HashSet<(PathBuf, String)>>,
    /// One lock per graph being built, so two requests for the same cold graph build it once
    /// instead of twice at 100 MB a time.
    key_locks: Mutex<HashMap<GraphKey, Arc<Mutex<()>>>>,
    /// Blob facts shared between every graph that holds them. Weak, so a blob nobody's graph holds
    /// any more is freed: ten graphs of ten commits of one repository hold one copy of each blob
    /// they share, not ten.
    facts: Mutex<HashMap<(String, &'static str), (Weak<BlobFacts>, usize)>>,
}

/// Default budget for resolved graphs: with hundreds of worktrees on many commits the daemon
/// cannot hold them all (one tessera graph is ~100 MB), so the least recently used are dropped.
pub const DEFAULT_GRAPH_BUDGET: usize = 1536 << 20;

#[derive(Clone, PartialEq, Eq, Hash)]
enum GraphKey {
    /// The clean graph of one commit; every clean worktree on it shares this.
    Base(PathBuf, String),
    /// A worktree's last graph with its overlay applied. One per worktree: an edit makes the
    /// previous one garbage, so it is replaced rather than kept.
    Overlay(PathBuf),
}

struct CachedGraph {
    graph: Arc<ViewGraph>,
    /// `Overlay` entries: which overlay (and commit) it was built for.
    stamp: String,
    own_bytes: usize,
    used: u64,
}

#[derive(Default)]
struct GraphCache {
    map: HashMap<GraphKey, CachedGraph>,
    tick: u64,
    budget: usize,
    evictions: u64,
}

#[derive(Debug, Clone, Default)]
pub struct GraphCacheStats {
    pub graphs: usize,
    /// Own bytes of every cached graph plus the distinct facts still held by anything.
    pub bytes: usize,
    pub facts_bytes: usize,
    pub budget: usize,
    pub evictions: u64,
}

impl Engine {
    pub fn open(store_root: impl Into<PathBuf>) -> Result<Engine> {
        let store_root = store_root.into();
        std::fs::create_dir_all(&store_root).map_err(|e| Error::io(&store_root, e))?;
        let pool = rayon::ThreadPoolBuilder::new()
            .stack_size(64 << 20)
            .thread_name(|i| format!("fdindex-parse-{i}"))
            .build()
            .map_err(|e| Error::Msg(e.to_string()))?;
        Ok(Engine { store_root, writers: Mutex::new(HashMap::new()), pool, parses: AtomicUsize::new(0),
            graphs: Mutex::new(GraphCache { budget: DEFAULT_GRAPH_BUDGET, ..Default::default() }),
            complete: Mutex::new(HashSet::new()),
            key_locks: Mutex::new(HashMap::new()),
            facts: Mutex::new(HashMap::new()),
        })
    }

    pub fn store_root(&self) -> &Path {
        &self.store_root
    }

    pub fn view_for_path(&self, abs: &Path) -> Result<View> {
        git::view_for_path(abs)
    }

    /// Total blobs parsed (extractor calls) by this engine since it opened. Tests assert on deltas.
    pub fn parse_count(&self) -> usize {
        self.parses.load(Ordering::Relaxed)
    }

    fn writer(&self, repo: &Path) -> Result<Arc<Mutex<Writer>>> {
        let mut map = self.writers.lock().unwrap();
        if let Some(w) = map.get(repo) {
            return Ok(w.clone());
        }
        let w = Arc::new(Mutex::new(Writer::open(&self.store_root, repo)?));
        map.insert(repo.to_path_buf(), w.clone());
        Ok(w)
    }

    pub fn reader(&self, repo: &Path) -> Result<Reader> {
        // Make sure the file exists and has its schema before a read-only open.
        drop(self.writer(repo)?);
        Reader::open(&self.store_root, repo)
    }

    pub fn gc(&self, repo: &Path) -> Result<GcStats> {
        // Facts may be about to go: no tree of this repository can be called complete any more.
        self.complete.lock().unwrap().retain(|(r, _)| r != repo);
        self.writer(repo)?.lock().unwrap().gc()
    }

    pub fn incremental_vacuum(&self, repo: &Path, pages: u32) -> Result<u64> {
        self.writer(repo)?.lock().unwrap().incremental_vacuum(pages)
    }

    /// Does the store already hold facts for every file of `view`? True means a request can be
    /// answered from `graph` without a build. For a view on a commit this build has verified, only
    /// the overlay (the files edited since) is checked, which is what keeps a warm request cheap.
    pub fn is_ready(&self, view: &View) -> Result<bool> {
        let tree_done = view.label.base_commit.as_ref().is_some_and(|c| self.complete.lock().unwrap().contains(&(view.label.repo.clone(), c.clone())));
        let files: Vec<FileRef> = if tree_done {
            view.overlay.iter().filter_map(|o| if let Overlay::Present(f) = o { Some(f.clone()) } else { None }).collect()
        } else if view.label.base_commit.is_none() {
            view.files()
        } else {
            return Ok(false);
        };
        let reader = self.reader(&view.label.repo)?;
        for f in &files {
            let v = lang::by_id(f.language).map(|l| l.parser_version()).unwrap_or(0);
            if !reader.has_facts(&f.blob_id, f.language, v)? {
                return Ok(false);
            }
        }
        Ok(true)
    }

    /// Store everything `view` needs. `priority` (absolute paths, or directories) and their direct
    /// imports are parsed first; `progress` is called after every batch.
    pub fn build(&self, view: &View, priority: &[PathBuf], mut progress: impl FnMut(Progress)) -> Result<BuildReport> {
        let started = Instant::now();
        let files = view.files();
        let total = files.len();
        let root = &view.label.worktree;
        let writer = self.writer(&view.label.repo)?;

        // Record what this view needs before parsing it, so a concurrent gc treats the blobs we
        // are about to store as referenced rather than as orphans.
        {
            let mut w = writer.lock().unwrap();
            // A commit's tree never changes, so one already recorded is not rewritten (that is a
            // delete and a few thousand inserts per request on a warm view).
            if let Some(c) = &view.label.base_commit
                && !w.has_tree(c)?
            {
                w.put_tree(c, &view.base)?;
            }
            w.set_worktree(root, view.label.base_commit.as_deref(), &view.overlay)?;
        }

        let version = |lang: &str| lang::by_id(lang).map(|l| l.parser_version()).unwrap_or(0);
        let tree_done = view.label.base_commit.as_ref().is_some_and(|c| self.complete.lock().unwrap().contains(&(view.label.repo.clone(), c.clone())));
        let overlay_present: HashSet<&str> =
            view.overlay.iter().filter_map(|o| if let Overlay::Present(f) = o { Some(f.path.as_str()) } else { None }).collect();
        let mut pending: HashMap<Key, Vec<usize>> = HashMap::new(); // blob -> indexes into `files`
        {
            let w = writer.lock().unwrap();
            for (i, f) in files.iter().enumerate() {
                if tree_done && !overlay_present.contains(f.path.as_str()) {
                    continue; // verified by an earlier build of this commit
                }
                if !w.has_facts(&f.blob_id, f.language, version(f.language))? {
                    pending.entry(Key { blob_id: f.blob_id.clone(), language: f.language }).or_default().push(i);
                }
            }
        }
        let stored = total - pending.values().map(Vec::len).sum::<usize>();
        let mut report = BuildReport { total_files: total, already_stored: stored, ..Default::default() };
        let mut done = stored;
        progress(Progress { phase: if pending.is_empty() { Phase::Done } else { Phase::Priority }, done, total });
        if pending.is_empty() {
            self.mark_complete(view);
            report.elapsed = started.elapsed();
            return Ok(report);
        }

        // Priority slice: requested files, then their direct imports (known only from facts, so
        // the requested files must be stored first).
        let overlay_paths: HashMap<&str, &FileRef> = view
            .overlay
            .iter()
            .filter_map(|o| match o {
                Overlay::Present(f) => Some((f.path.as_str(), f)),
                Overlay::Deleted(_) => None,
            })
            .collect();
        let wanted: HashSet<String> = priority
            .iter()
            .filter_map(|p| p.strip_prefix(root).ok())
            .map(|p| p.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/"))
            .collect();
        let in_priority = |path: &str| wanted.iter().any(|w| path == w || path.starts_with(&format!("{w}/")));
        let first: Vec<usize> = (0..total).filter(|i| in_priority(&files[*i].path)).collect();
        let mut priority_set: HashSet<usize> = first.iter().copied().collect();
        self.parse_files(&writer, view, &overlay_paths, &first, &mut pending, &mut done, &mut report, total, Phase::Priority, &mut progress)?;

        if !first.is_empty() {
            let resolver = Resolver::new(root, &files);
            let by_path: HashMap<&str, usize> = files.iter().enumerate().map(|(i, f)| (f.path.as_str(), i)).collect();
            let mut imports: Vec<usize> = Vec::new();
            {
                let w = writer.lock().unwrap();
                for &i in &first {
                    let f = &files[i];
                    let Some(facts) = w.get_facts(&f.blob_id, f.language, version(f.language))? else { continue };
                    for imp in &facts.imports {
                        if let Resolved::File { path, .. } = resolver.resolve_import(&f.path, f.language, imp)
                            && let Some(&t) = by_path.get(path.as_str())
                                && priority_set.insert(t) {
                                    imports.push(t);
                                }
                    }
                }
            }
            self.parse_files(&writer, view, &overlay_paths, &imports, &mut pending, &mut done, &mut report, total, Phase::Priority, &mut progress)?;
        }
        report.priority_files = priority_set.len();
        if !priority_set.is_empty() {
            progress(Progress { phase: Phase::PriorityDone, done, total });
        }

        let rest: Vec<usize> = (0..total).filter(|i| !priority_set.contains(i)).collect();
        self.parse_files(&writer, view, &overlay_paths, &rest, &mut pending, &mut done, &mut report, total, Phase::Rest, &mut progress)?;
        self.mark_complete(view);
        progress(Progress { phase: Phase::Done, done, total });
        report.elapsed = started.elapsed();
        Ok(report)
    }

    fn mark_complete(&self, view: &View) {
        if let Some(c) = &view.label.base_commit {
            self.complete.lock().unwrap().insert((view.label.repo.clone(), c.clone()));
        }
    }

    /// Parse the still-pending blobs among `indexes` in batches: read, parse on the pool, then
    /// write the whole batch in one transaction.
    #[allow(clippy::too_many_arguments)]
    fn parse_files(
        &self,
        writer: &Arc<Mutex<Writer>>,
        view: &View,
        overlay_paths: &HashMap<&str, &FileRef>,
        indexes: &[usize],
        pending: &mut HashMap<Key, Vec<usize>>,
        done: &mut usize,
        report: &mut BuildReport,
        total: usize,
        phase: Phase,
        progress: &mut impl FnMut(Progress),
    ) -> Result<()> {
        let files = view.files();
        // Unique pending keys in file order (stable, so the build is deterministic).
        let mut todo: Vec<(Key, String)> = Vec::new();
        let mut queued: HashSet<Key> = HashSet::new();
        for &i in indexes {
            let key = Key { blob_id: files[i].blob_id.clone(), language: files[i].language };
            if pending.contains_key(&key) && queued.insert(key.clone()) {
                todo.push((key, files[i].path.clone()));
            }
        }
        for chunk in todo.chunks(BATCH) {
            // Overlay blobs come from disk, tree blobs from git's object store in one cat-file.
            let mut sources: Vec<Option<Vec<u8>>> = vec![None; chunk.len()];
            let mut git_ids: Vec<(usize, &str)> = Vec::new();
            for (n, (key, path)) in chunk.iter().enumerate() {
                match overlay_paths.get(path.as_str()).filter(|f| f.blob_id == key.blob_id) {
                    Some(_) => {
                        sources[n] = std::fs::read(view.abs(path)).ok();
                        if let Some(bytes) = &sources[n]
                            && git::blob_id(bytes) != key.blob_id {
                                report.changed_during_build += 1;
                            }
                    }
                    None => git_ids.push((n, key.blob_id.as_str())),
                }
            }
            if !git_ids.is_empty() {
                let ids: Vec<&str> = git_ids.iter().map(|(_, id)| *id).collect();
                for ((n, _), bytes) in git_ids.iter().zip(cat_file_batch(&view.label.worktree, &ids)?) {
                    sources[*n] = bytes;
                }
            }

            let parsed: Vec<(ParsedBlob, bool)> = self.pool.install(|| {
                use rayon::prelude::*;
                chunk
                    .par_iter()
                    .zip(sources.par_iter())
                    .filter_map(|((key, _), bytes)| {
                        let bytes = bytes.as_ref()?; // vanished between listing and reading
                        let l = lang::by_id(key.language)?;
                        let text = (bytes.len() as u64 <= MAX_FILE_BYTES).then(|| std::str::from_utf8(bytes).ok()).flatten();
                        let facts = text.and_then(|t| {
                            // A parser bug must cost one file, not the build.
                            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| l.extract(t))).ok()
                        });
                        let was_parsed = facts.is_some();
                        Some((
                            ParsedBlob {
                                blob_id: key.blob_id.clone(),
                                language: key.language,
                                parser_version: l.parser_version(),
                                facts,
                            },
                            was_parsed,
                        ))
                    })
                    .collect()
            });
            for (p, was_parsed) in &parsed {
                if *was_parsed {
                    self.parses.fetch_add(1, Ordering::Relaxed);
                    report.parsed += 1;
                    *report.parsed_by_language.entry(p.language.to_string()).or_default() += 1;
                } else {
                    report.skipped += 1;
                }
                let key = Key { blob_id: p.blob_id.clone(), language: p.language };
                *done += pending.remove(&key).map(|v| v.len()).unwrap_or(0);
            }
            let batch: Vec<ParsedBlob> = parsed.into_iter().map(|(p, _)| p).collect();
            writer.lock().unwrap().put_facts(&batch)?;
            progress(Progress { phase, done: *done, total });
        }
        Ok(())
    }

    pub fn set_graph_budget(&self, bytes: usize) {
        self.graphs.lock().unwrap().budget = bytes;
    }

    pub fn graph_cache_stats(&self) -> GraphCacheStats {
        let (graphs, own, budget, evictions) = {
            let c = self.graphs.lock().unwrap();
            (c.map.len(), c.map.values().map(|g| g.own_bytes).sum::<usize>(), c.budget, c.evictions)
        };
        let facts_bytes = self.live_facts_bytes();
        GraphCacheStats { graphs, bytes: own + facts_bytes, facts_bytes, budget, evictions }
    }

    fn live_facts_bytes(&self) -> usize {
        self.facts.lock().unwrap().values().filter(|(w, _)| w.strong_count() > 0).map(|(_, b)| *b).sum()
    }

    /// Evict least recently used graphs until the cache fits its budget; the entry just touched
    /// (`keep`) always stays, because a request is about to use it.
    fn enforce_budget(&self, keep: &GraphKey) {
        loop {
            let facts = self.live_facts_bytes();
            let mut c = self.graphs.lock().unwrap();
            let own: usize = c.map.values().map(|g| g.own_bytes).sum();
            if own + facts <= c.budget || c.map.len() <= 1 {
                return;
            }
            let Some(victim) = c.map.iter().filter(|(k, _)| *k != keep).min_by_key(|(_, g)| g.used).map(|(k, _)| k.clone()) else {
                return;
            };
            c.map.remove(&victim);
            c.evictions += 1;
            drop(c);
            // Facts nothing holds any more are dead weight in the index of weak pointers.
            self.facts.lock().unwrap().retain(|_, (w, _)| w.strong_count() > 0);
        }
    }

    fn key_lock(&self, key: &GraphKey) -> Arc<Mutex<()>> {
        let mut m = self.key_locks.lock().unwrap();
        if m.len() > 256 {
            m.retain(|_, l| Arc::strong_count(l) > 1);
        }
        m.entry(key.clone()).or_default().clone()
    }

    fn cached(&self, key: &GraphKey, stamp: &str) -> Option<Arc<ViewGraph>> {
        let mut c = self.graphs.lock().unwrap();
        c.tick += 1;
        let tick = c.tick;
        let e = c.map.get_mut(key).filter(|e| e.stamp == stamp)?;
        e.used = tick;
        Some(e.graph.clone())
    }

    fn remember(&self, key: GraphKey, stamp: String, graph: Arc<ViewGraph>) {
        {
            let mut c = self.graphs.lock().unwrap();
            c.tick += 1;
            let used = c.tick;
            c.map.insert(key.clone(), CachedGraph { own_bytes: graph.own_bytes(), graph, stamp, used });
        }
        self.enforce_budget(&key);
    }

    /// The resolved graph of `view`. The view must have been built; for one that is still being
    /// built use `graph_partial`. A base tree's graph is cached per (repository, commit); a view
    /// with an overlay re-resolves only the overlay's files and what depends on them, and that
    /// result is cached per worktree until the overlay changes.
    pub fn graph(&self, view: &View) -> Result<Arc<ViewGraph>> {
        self.graph_with(view, true)
    }

    /// The graph of whatever part of `view` is stored so far: files the build has not reached
    /// resolve as empty. Never cached, because a half-built graph cached under its commit would
    /// answer every later request as if the commit really were that small.
    pub fn graph_partial(&self, view: &View) -> Result<Arc<ViewGraph>> {
        self.graph_with(view, false)
    }

    fn graph_with(&self, view: &View, complete: bool) -> Result<Arc<ViewGraph>> {
        let reader = self.reader(&view.label.repo)?;
        let load = |files: &[FileRef]| -> Result<Vec<(FileRef, Arc<BlobFacts>)>> {
            let mut local: HashMap<(&str, &str), Arc<BlobFacts>> = HashMap::new();
            let mut out = Vec::with_capacity(files.len());
            for f in files {
                let facts = match local.get(&(f.blob_id.as_str(), f.language)) {
                    Some(a) => a.clone(),
                    None => {
                        let a = self.facts_for(&reader, f)?;
                        local.insert((f.blob_id.as_str(), f.language), a.clone());
                        a
                    }
                };
                out.push((f.clone(), facts));
            }
            Ok(out)
        };

        let Some(commit) = &view.label.base_commit else {
            return Ok(Arc::new(ViewGraph::build(view.label.clone(), load(&view.files())?)));
        };
        let base_key = GraphKey::Base(view.label.repo.clone(), commit.clone());
        let base = match self.cached(&base_key, "").filter(|_| complete) {
            Some(b) => b,
            None => {
                let lock = self.key_lock(&base_key);
                let _building = complete.then(|| lock.lock().unwrap());
                // Whoever held the lock before us may have built it.
                match self.cached(&base_key, "").filter(|_| complete) {
                    Some(b) => b,
                    None => {
                        let mut base_label = view.label.clone();
                        base_label.dirty = false;
                        let b = Arc::new(ViewGraph::build(base_label, load(&view.base)?));
                        if complete {
                            self.remember(base_key.clone(), String::new(), b.clone());
                        }
                        b
                    }
                }
            }
        };
        if view.overlay.is_empty() {
            return Ok(Arc::new(base.for_worktree(view.label.clone())));
        }

        let overlay_key = GraphKey::Overlay(view.label.worktree.clone());
        let stamp = overlay_stamp(commit, &view.overlay);
        if complete && let Some(g) = self.cached(&overlay_key, &stamp) {
            return Ok(g);
        }
        let lock = self.key_lock(&overlay_key);
        let _building = complete.then(|| lock.lock().unwrap());
        if complete && let Some(g) = self.cached(&overlay_key, &stamp) {
            return Ok(g);
        }
        let present: Vec<FileRef> = view
            .overlay
            .iter()
            .filter_map(|o| match o {
                Overlay::Present(f) => Some(f.clone()),
                Overlay::Deleted(_) => None,
            })
            .collect();
        let mut changes: Vec<FileChange> = load(&present)?.into_iter().map(|(f, facts)| FileChange::Upsert(f, facts)).collect();
        changes.extend(view.overlay.iter().filter_map(|o| match o {
            Overlay::Deleted(p) => Some(FileChange::Remove(p.clone())),
            Overlay::Present(_) => None,
        }));
        // `with_changes` re-points the resolver at this worktree's root itself, so the base graph
        // of another worktree of the same commit can be used as is.
        let g = Arc::new(base.with_changes(view.label.clone(), changes));
        if complete {
            self.remember(overlay_key, stamp, g.clone());
        }
        Ok(g)
    }

    /// Facts for one file, from the shared in-memory copy when some graph still holds it. A file
    /// the build could not store (vanished, changed) is an empty file.
    fn facts_for(&self, reader: &Reader, f: &FileRef) -> Result<Arc<BlobFacts>> {
        let key = (f.blob_id.clone(), f.language);
        if let Some((w, _)) = self.facts.lock().unwrap().get(&key)
            && let Some(a) = w.upgrade()
        {
            return Ok(a);
        }
        let v = lang::by_id(f.language).map(|l| l.parser_version()).unwrap_or(0);
        match reader.get_facts(&f.blob_id, f.language, v)? {
            Some(facts) => {
                let bytes = facts_bytes(&facts);
                let a = Arc::new(facts);
                self.facts.lock().unwrap().insert(key, (Arc::downgrade(&a), bytes));
                Ok(a)
            }
            None => Ok(Arc::new(BlobFacts::default())),
        }
    }
}

/// Identifies one overlay on one commit, so a cached overlay graph is reused only for exactly the
/// content it was built from.
fn overlay_stamp(commit: &str, overlay: &[Overlay]) -> String {
    use sha1::{Digest, Sha1};
    let mut h = Sha1::new();
    h.update(commit.as_bytes());
    for o in overlay {
        match o {
            Overlay::Present(f) => h.update(format!("\0+{}\0{}\0{}", f.path, f.blob_id, f.language)),
            Overlay::Deleted(p) => h.update(format!("\0-{p}")),
        }
    }
    h.finalize().iter().map(|b| format!("{b:02x}")).collect()
}

/// `git cat-file --batch`: contents for each id, `None` if git does not have it. Feeding stdin
/// from a second thread keeps a full stdout pipe from deadlocking the writer.
fn cat_file_batch(root: &Path, ids: &[&str]) -> Result<Vec<Option<Vec<u8>>>> {
    let mut child = Command::new("git")
        .args(["cat-file", "--batch"])
        .current_dir(root)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| Error::io(root, e))?;
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let input: String = ids.iter().map(|i| format!("{i}\n")).collect();
    let out = std::thread::scope(|s| -> Result<Vec<Option<Vec<u8>>>> {
        s.spawn(move || {
            let _ = stdin.write_all(input.as_bytes());
        });
        let mut r = BufReader::new(stdout);
        let mut out = Vec::with_capacity(ids.len());
        for _ in ids {
            let mut header = String::new();
            if r.read_line(&mut header).map_err(|e| Error::io(root, e))? == 0 {
                return Err(Error::Git { args: "cat-file --batch".into(), message: "output ended early".into() });
            }
            let parts: Vec<&str> = header.split_whitespace().collect();
            if parts.len() == 3 && parts[1] == "blob" {
                let size: usize = parts[2].parse().map_err(|_| Error::Msg(format!("bad cat-file header {header:?}")))?;
                let mut buf = vec![0u8; size + 1];
                r.read_exact(&mut buf).map_err(|e| Error::io(root, e))?;
                buf.truncate(size);
                out.push(Some(buf));
            } else {
                out.push(None);
            }
        }
        Ok(out)
    })?;
    let _ = child.wait();
    Ok(out)
}
