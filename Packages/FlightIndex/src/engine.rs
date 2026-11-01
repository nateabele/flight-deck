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
use crate::graph::{FileChange, ViewGraph};
use crate::lang;
use crate::resolve::{Resolved, Resolver};
use crate::store::{GcStats, ParsedBlob, Reader, Writer};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
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
    graphs: Mutex<HashMap<(PathBuf, String), Arc<ViewGraph>>>,
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
        Ok(Engine { store_root, writers: Mutex::new(HashMap::new()), pool, parses: AtomicUsize::new(0), graphs: Mutex::new(HashMap::new()) })
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
        self.writer(repo)?.lock().unwrap().gc()
    }

    pub fn incremental_vacuum(&self, repo: &Path, pages: u32) -> Result<u64> {
        self.writer(repo)?.lock().unwrap().incremental_vacuum(pages)
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
            if let Some(c) = &view.label.base_commit {
                w.put_tree(c, &view.base)?;
            }
            w.set_worktree(root, view.label.base_commit.as_deref(), &view.overlay)?;
        }

        let version = |lang: &str| lang::by_id(lang).map(|l| l.parser_version()).unwrap_or(0);
        let mut pending: HashMap<Key, Vec<usize>> = HashMap::new(); // blob -> indexes into `files`
        let mut stored = 0usize;
        {
            let w = writer.lock().unwrap();
            for (i, f) in files.iter().enumerate() {
                if w.has_facts(&f.blob_id, f.language, version(f.language))? {
                    stored += 1;
                } else {
                    pending.entry(Key { blob_id: f.blob_id.clone(), language: f.language }).or_default().push(i);
                }
            }
        }
        let mut report = BuildReport { total_files: total, already_stored: stored, ..Default::default() };
        let mut done = stored;
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
        progress(Progress { phase: Phase::Done, done, total });
        report.elapsed = started.elapsed();
        Ok(report)
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

    /// The resolved graph of `view`. The view must have been built. A base tree's graph is cached
    /// per (repository, commit); a view with an overlay re-resolves only the overlay's files and
    /// what depends on them.
    pub fn graph(&self, view: &View) -> Result<Arc<ViewGraph>> {
        let reader = self.reader(&view.label.repo)?;
        let load = |files: &[FileRef]| -> Result<Vec<(FileRef, Arc<BlobFacts>)>> {
            let mut cache: HashMap<(&str, &str), Arc<BlobFacts>> = HashMap::new();
            let mut out = Vec::with_capacity(files.len());
            for f in files {
                let facts = match cache.get(&(f.blob_id.as_str(), f.language)) {
                    Some(a) => a.clone(),
                    None => {
                        let v = lang::by_id(f.language).map(|l| l.parser_version()).unwrap_or(0);
                        // A file the build could not store (vanished, changed) is an empty file.
                        let a = Arc::new(reader.get_facts(&f.blob_id, f.language, v)?.unwrap_or_default());
                        cache.insert((f.blob_id.as_str(), f.language), a.clone());
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
        let key = (view.label.repo.clone(), commit.clone());
        let cached = self.graphs.lock().unwrap().get(&key).cloned();
        let base = match cached {
            Some(b) => b,
            None => {
                let mut base_label = view.label.clone();
                base_label.dirty = false;
                let b = Arc::new(ViewGraph::build(base_label, load(&view.base)?));
                self.graphs.lock().unwrap().insert(key, b.clone());
                b
            }
        };
        if view.overlay.is_empty() {
            return Ok(if base.label.worktree == view.label.worktree {
                let mut g = (*base).clone();
                g.label = view.label.clone();
                Arc::new(g)
            } else {
                Arc::new(base.for_worktree(view.label.clone()))
            });
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
        // `with_changes` is relative to the base graph's root; re-point it at this worktree first
        // so the resolver reads this worktree's manifests.
        let rebased = if base.label.worktree == view.label.worktree { (*base).clone() } else { base.for_worktree(view.label.clone()) };
        Ok(Arc::new(rebased.with_changes(view.label.clone(), changes)))
    }
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
