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
    /// One build at a time per repository. Worktrees of a repository share most of their blobs, so
    /// two concurrent builds would each parse the shared ones (measured: 10,764 parses for 3,700
    /// distinct blobs when five worktrees were first queried at once); run one after the other, the
    /// second finds the first's blobs stored and parses only its own. Parsing already uses every
    /// core, so nothing is lost by not overlapping them.
    build_locks: Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>,
    /// File listings of recently seen commits (see `view_for_path`).
    bases: Mutex<HashMap<(PathBuf, String), BaseListing>>,
    /// One lock per graph being built, so two requests for the same cold graph build it once
    /// instead of twice at 100 MB a time.
    key_locks: Mutex<HashMap<GraphKey, Arc<Mutex<()>>>>,
    /// Blob facts shared between every graph that holds them. Weak, so a blob nobody's graph holds
    /// any more is freed: ten graphs of ten commits of one repository hold one copy of each blob
    /// they share, not ten.
    facts: Mutex<HashMap<(String, &'static str), SharedFacts>>,
    /// What the store's `worktrees` row says for each worktree, so a request whose view has not
    /// changed writes nothing (see `record_view`).
    recorded: Mutex<HashMap<PathBuf, Recorded>>,
}

/// A worktree's view as last written to the store.
#[derive(Clone)]
struct Recorded {
    repo: PathBuf,
    commit: Option<String>,
    stamp: String,
    at: Instant,
}

/// A commit's indexable files, shared by every view on it.
type BaseListing = Arc<Vec<FileRef>>;

/// Commits whose listing `Engine::view_for_path` keeps (about 2000 entries each for a large repo).
const MAX_KNOWN_BASES: usize = 64;

/// What the budget charges for `bytes` of estimated graph. The estimate counts struct sizes and
/// string payloads but not allocator rounding or hash-table slack; measured against the daemon's
/// RSS on tessera it runs about a fifth low, so the budget is charged 5/4 of it.
fn charged(estimate: usize) -> usize {
    estimate / 4 * 5
}

/// A blob's facts as held weakly by the shared cache, with their estimated size.
type SharedFacts = (Weak<BlobFacts>, usize);

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
    /// Estimated bytes of every cached graph plus the distinct facts still held by anything, as
    /// charged against the budget (the raw estimate scaled to RSS).
    pub bytes: usize,
    /// The distinct facts part of the estimate, unscaled.
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
            bases: Mutex::new(HashMap::new()),
            build_locks: Mutex::new(HashMap::new()),
            facts: Mutex::new(HashMap::new()),
            recorded: Mutex::new(HashMap::new()),
        })
    }

    pub fn store_root(&self) -> &Path {
        &self.store_root
    }

    /// The view of the worktree containing `abs`, as of now. The listing of a commit this engine
    /// has seen is reused, so a warm call costs one `git status`.
    pub fn view_for_path(&self, abs: &Path) -> Result<View> {
        let view = git::view_for_path_with(abs, &|repo, commit, root| self.base_listing(repo, commit, root))?;
        if let Some(c) = &view.label.base_commit {
            let mut bases = self.bases.lock().unwrap();
            if bases.len() >= MAX_KNOWN_BASES {
                bases.clear(); // listings are cheap to recompute; a bounded cache beats a tidy eviction order
            }
            bases.entry((view.label.repo.clone(), c.clone())).or_insert_with(|| view.base.clone());
        }
        Ok(view)
    }

    /// The file listing of `commit`, if this engine has it or can derive it cheaply: a worktree
    /// that moved to a new commit (a commit, a checkout, a rebase step) differs from the commit it
    /// was on by a few files, and `git diff-tree` of those is a fraction of listing the whole tree.
    /// "Nearest" is the worktree's own previous commit, else the most recently recorded commit of
    /// the repository. When the old commit was fully indexed and every changed file already has
    /// facts (a commit of edits the worktree was already showing does), the new one is marked fully
    /// indexed too, so the request that moved HEAD parses nothing and builds nothing.
    fn base_listing(&self, repo: &Path, commit: &str, root: &Path) -> Option<BaseListing> {
        let key = (repo.to_path_buf(), commit.to_string());
        if let Some(b) = self.bases.lock().unwrap().get(&key) {
            return Some(b.clone());
        }
        let (old, old_list) = {
            let recorded = self.recorded.lock().unwrap();
            let bases = self.bases.lock().unwrap();
            let own = recorded.get(root).filter(|r| r.repo == repo).and_then(|r| r.commit.clone());
            let nearest = own.or_else(|| {
                recorded.values().filter(|r| r.repo == repo && r.commit.is_some()).max_by_key(|r| r.at).and_then(|r| r.commit.clone())
            })?;
            let list = bases.get(&(repo.to_path_buf(), nearest.clone()))?.clone();
            (nearest, list)
        };
        let derived = Arc::new(git::derive_listing(root, &old_list, &old, commit).ok()??);
        let was_complete = self.complete.lock().unwrap().contains(&(repo.to_path_buf(), old.clone()));
        if was_complete && let Ok(reader) = self.reader(repo) {
            let old_blobs: HashMap<&str, &str> = old_list.iter().map(|f| (f.path.as_str(), f.blob_id.as_str())).collect();
            let all_stored = derived.iter().filter(|f| old_blobs.get(f.path.as_str()) != Some(&f.blob_id.as_str())).all(|f| {
                let v = lang::by_id(f.language).map(|l| l.parser_version()).unwrap_or(0);
                reader.has_facts(&f.blob_id, f.language, v).unwrap_or(false)
            });
            if all_stored {
                self.complete.lock().unwrap().insert(key);
            }
        }
        Some(derived)
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

    /// Write the view's tree and overlay to the store, unless they are what it already holds for
    /// this worktree. The `worktrees` row and its overlay are what garbage collection treats as
    /// roots, so every view a request answers from must be recorded: a worktree on an indexed
    /// commit needs no build, and without this it would never get a row, and its tree and overlay
    /// blobs would be collected from under it.
    pub fn record_view(&self, view: &View) -> Result<()> {
        let stamp = overlay_stamp(view.label.base_commit.as_deref().unwrap_or(""), &view.overlay);
        let key = view.label.worktree.clone();
        if self.recorded.lock().unwrap().get(&key).is_some_and(|r| r.commit == view.label.base_commit && r.stamp == stamp) {
            return Ok(());
        }
        let writer = self.writer(&view.label.repo)?;
        {
            let mut w = writer.lock().unwrap();
            // A commit's tree never changes, so one already recorded is not rewritten (that is a
            // delete and a few thousand inserts per request on a warm view).
            if let Some(c) = &view.label.base_commit
                && !w.has_tree(c)?
            {
                w.put_tree(c, &view.base)?;
            }
            w.set_worktree(&key, view.label.base_commit.as_deref(), &view.overlay)?;
        }
        self.recorded.lock().unwrap().insert(key, Recorded { repo: view.label.repo.clone(), commit: view.label.base_commit.clone(), stamp, at: Instant::now() });
        Ok(())
    }

    /// A worktree whose directory is gone: drop its row and overlay, its graph, and the graph of
    /// its commit when `commit_in_use` says no other worktree is on it. The blobs go with the next
    /// collection.
    pub fn release_worktree(&self, repo: &Path, worktree: &Path, commit: Option<&str>, commit_in_use: bool) {
        self.recorded.lock().unwrap().remove(worktree);
        {
            let mut g = self.graphs.lock().unwrap();
            g.map.remove(&GraphKey::Overlay(worktree.to_path_buf()));
            if let (Some(c), false) = (commit, commit_in_use) {
                g.map.remove(&GraphKey::Base(repo.to_path_buf(), c.to_string()));
            }
        }
        self.facts.lock().unwrap().retain(|_, (w, _)| w.strong_count() > 0);
        // Not through `writer`, which would create the database of a repository that was just
        // dropped because its directory went too.
        if crate::store::db_path(&self.store_root, repo).exists()
            && let Ok(w) = self.writer(repo)
        {
            let _ = w.lock().unwrap().remove_worktree(worktree);
        }
    }

    /// Forget a repository whose common dir no longer exists: its database file goes, and every
    /// cache entry that could name it.
    pub fn drop_repo(&self, repo: &Path) {
        self.writers.lock().unwrap().remove(repo);
        self.complete.lock().unwrap().retain(|(r, _)| r != repo);
        self.bases.lock().unwrap().retain(|(r, _), _| r != repo);
        self.recorded.lock().unwrap().retain(|_, r| r.repo != repo);
        self.graphs.lock().unwrap().map.retain(|k, g| match k {
            GraphKey::Base(r, _) => r != repo,
            GraphKey::Overlay(_) => g.graph.label.repo != repo,
        });
        self.facts.lock().unwrap().retain(|_, (w, _)| w.strong_count() > 0);
        crate::store::remove_repo_db(&self.store_root, repo);
    }

    /// Replace a repository's known refs with its branch heads, read from git. Trees of those
    /// commits survive collection, so a branch tip someone looked at is still warm after the
    /// worktree that showed it is gone.
    pub fn refresh_known_refs(&self, repo: &Path) -> Result<usize> {
        let refs = git::branch_heads(repo)?;
        self.writer(repo)?.lock().unwrap().set_known_refs(&refs)?;
        Ok(refs.len())
    }

    /// Collect one repository: its roots first, then orphan facts a chunk at a time. The writer
    /// is released between chunks so a build or a read waiting on it is never held up for the
    /// whole collection.
    pub fn gc(&self, repo: &Path) -> Result<GcStats> {
        const CHUNK: usize = 2000;
        let writer = self.writer(repo)?;
        let (mut stats, dead) = writer.lock().unwrap().gc_roots()?;
        // Commits whose trees went are no longer vouched for: their facts may be next.
        self.complete.lock().unwrap().retain(|(r, c)| r != repo || !dead.contains(c));
        // A worktree row that went with its directory must be written again if the directory returns.
        self.recorded.lock().unwrap().retain(|wt, r| r.repo != repo || wt.exists());
        loop {
            let n = writer.lock().unwrap().gc_facts(CHUNK)?;
            stats.facts_dropped += n;
            if n < CHUNK {
                break;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        Ok(stats)
    }

    pub fn incremental_vacuum(&self, repo: &Path, pages: u32) -> Result<u64> {
        self.writer(repo)?.lock().unwrap().incremental_vacuum(pages)
    }

    /// Return every free page to the filesystem, 256 pages (1 MB) at a time with the writer
    /// released in between, then fold the WAL back so the file really shrinks. Returns pages freed.
    pub fn vacuum(&self, repo: &Path) -> Result<u64> {
        let writer = self.writer(repo)?;
        let mut freed = 0;
        loop {
            let n = writer.lock().unwrap().incremental_vacuum(256)?;
            freed += n;
            if n == 0 {
                break;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        let _ = writer.lock().unwrap().checkpoint();
        Ok(freed)
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
        let repo_lock = self.build_locks.lock().unwrap().entry(view.label.repo.clone()).or_default().clone();
        let _one_build_per_repo = repo_lock.lock().unwrap();
        let files = view.files();
        let total = files.len();
        let root = &view.label.worktree;
        let writer = self.writer(&view.label.repo)?;

        // Record what this view needs before parsing it, so a concurrent gc treats the blobs we
        // are about to store as referenced rather than as orphans.
        self.record_view(view)?;

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
        if pending.is_empty() {
            self.mark_complete(view); // before the Done event: a waiter woken by it must find the view ready
        }
        progress(Progress { phase: if pending.is_empty() { Phase::Done } else { Phase::Priority }, done, total });
        if pending.is_empty() {
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
        GraphCacheStats { graphs, bytes: charged(own + facts_bytes), facts_bytes, budget, evictions }
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
            if charged(own + facts) <= c.budget || c.map.len() <= 1 {
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

    /// The most recently used cached commit graph of `repo`, to warm-start a new commit's
    /// PageRank from. Recency stands in for ancestry: the graph a worktree was on just before it
    /// moved is almost always its parent or a near neighbour, and asking git which cached commit
    /// is nearest would cost more than the sweeps it saves. A far one is still correct (the solve
    /// runs to the same tolerance from any start), it just takes more sweeps.
    fn nearest_base(&self, repo: &Path) -> Option<Arc<ViewGraph>> {
        let c = self.graphs.lock().unwrap();
        c.map
            .iter()
            .filter(|(k, _)| matches!(k, GraphKey::Base(r, _) if r == repo))
            .max_by_key(|(_, e)| e.used)
            .map(|(_, e)| e.graph.clone())
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
        // Opened only when a graph actually has to be built: a cached one needs no connection.
        let load = |files: &[FileRef]| -> Result<Vec<(FileRef, Arc<BlobFacts>)>> {
            let reader = self.reader(&view.label.repo)?;
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
                        let near = self.nearest_base(&view.label.repo);
                        let b = Arc::new(ViewGraph::build_near(base_label, load(&view.base)?, near.as_deref()));
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
            Some(mut facts) => {
                // Rows arrive from SQLite one at a time, so these vectors grew by doubling and
                // carry up to 2x slack; on a 650k-reference repository that is tens of MB held
                // for as long as the graph lives.
                facts.symbols.shrink_to_fit();
                facts.refs.shrink_to_fit();
                facts.imports.shrink_to_fit();
                facts.hierarchy.shrink_to_fit();
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
    // By path, so the same overlay hashes the same whether `git status` or the watcher produced it
    // (they list in different orders), and a graph cached from one is reused by the other.
    let mut sorted: Vec<&Overlay> = overlay.iter().collect();
    sorted.sort_by(|a, b| a.path().cmp(b.path()));
    for o in sorted {
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
