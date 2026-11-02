//! A repository's trigram index: a chain of segment files beside its SQLite database, the blob
//! ordinal map they define, and the one writer that appends to them.
//!
//! Directory `<store>/<repo>-<hash>.tri/` holds `seg-<n>.tri` files. The chain a reader uses is the
//! newest segment starting at ordinal 0 (the base) followed by each later segment that starts where
//! the previous one ended (deltas). Anything else in the directory is the leftover of a merge or a
//! write that did not finish, and is removed by the next writer. Ordinals never change: a merge
//! concatenates postings, so a blob keeps its ordinal for the life of the directory.

use super::plan::Query;
use super::segment::{self, BlobKey, Segment};
use roaring::RoaringBitmap;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, OnceLock, RwLock};

/// Merge the chain into one segment once it is this long.
const MAX_SEGMENTS: usize = 8;
/// A delta segment holds at most this much content, which bounds the inversion's memory.
const BATCH_BYTES: usize = 16 << 20;
/// Blobs larger than this are not indexed; the search reads them every time.
pub const MAX_BLOB_BYTES: usize = 1 << 20;

/// What a query sees: an immutable chain of segments and the ordinals of their blobs.
pub struct Snapshot {
    segments: Vec<Arc<Segment>>,
    ordinals: HashMap<BlobKey, u32>,
}

impl Snapshot {
    pub fn blobs(&self) -> u32 {
        self.segments.last().map(|s| s.end()).unwrap_or(0)
    }

    pub fn segments(&self) -> usize {
        self.segments.len()
    }

    pub fn bytes(&self) -> usize {
        self.segments.iter().map(|s| s.bytes()).sum()
    }

    pub fn trigrams(&self) -> usize {
        self.segments.iter().map(|s| s.trigram_count() as usize).sum()
    }

    pub fn ordinal(&self, blob_hex: &str) -> Option<u32> {
        self.ordinals.get(&key(blob_hex)?).copied()
    }

    /// The ordinals that may hold a match of `q`; `None` for every blob (`Query::All`).
    pub fn candidates(&self, q: &Query) -> Option<RoaringBitmap> {
        match q {
            Query::All => None,
            Query::Tri(t) => {
                let mut bits = RoaringBitmap::new();
                for s in &self.segments {
                    if let Some(p) = s.postings(*t) {
                        bits |= p;
                    }
                }
                Some(bits)
            }
            Query::And(parts) => {
                let mut acc: Option<RoaringBitmap> = None;
                for p in parts {
                    if let Some(bits) = self.candidates(p) {
                        acc = Some(match acc {
                            None => bits,
                            Some(a) => a & bits,
                        });
                        if acc.as_ref().is_some_and(RoaringBitmap::is_empty) {
                            break;
                        }
                    }
                }
                acc
            }
            Query::Or(parts) => {
                let mut acc = RoaringBitmap::new();
                for p in parts {
                    acc |= self.candidates(p)?;
                }
                Some(acc)
            }
        }
    }
}

/// A 40-hex SHA-1 blob id as 20 bytes; `None` for anything else (such a blob is never indexed).
pub fn key(hex: &str) -> Option<BlobKey> {
    let b = hex.as_bytes();
    if b.len() != 40 {
        return None;
    }
    let nib = |c: u8| match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        _ => None,
    };
    let mut out = [0u8; 20];
    for i in 0..20 {
        out[i] = nib(b[2 * i])? << 4 | nib(b[2 * i + 1])?;
    }
    Some(out)
}

/// The tri directory of a repository database path (`x.db` -> `x.tri`).
pub fn dir_for_db(db: &Path) -> PathBuf {
    db.with_extension("tri")
}

fn seg_number(p: &Path) -> Option<u64> {
    p.file_name()?.to_str()?.strip_prefix("seg-")?.strip_suffix(".tri")?.parse().ok()
}

/// Every `seg-<n>.tri` in `dir`, by number.
fn listing(dir: &Path) -> Vec<(u64, PathBuf)> {
    let Ok(rd) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut out: Vec<(u64, PathBuf)> = rd.filter_map(|e| e.ok()).map(|e| e.path()).filter_map(|p| Some((seg_number(&p)?, p))).collect();
    out.sort();
    out
}

/// The chain in `dir` (see the module doc), and the files outside it.
fn load(dir: &Path) -> (Vec<(u64, Arc<Segment>)>, Vec<PathBuf>) {
    let opened: Vec<(u64, PathBuf, Option<Segment>)> = listing(dir)
        .into_iter()
        .map(|(n, p)| {
            let s = Segment::open(&p).ok();
            (n, p, s)
        })
        .collect();
    let base = opened.iter().rposition(|(_, _, s)| s.as_ref().is_some_and(|s| s.first == 0));
    let mut chain: Vec<(u64, Arc<Segment>)> = Vec::new();
    let mut stray: Vec<PathBuf> = Vec::new();
    for (i, (n, p, s)) in opened.into_iter().enumerate() {
        let next = chain.last().map(|(_, s)| s.end()).unwrap_or(0);
        match s {
            Some(s) if base.is_some_and(|b| i >= b) && s.first == next => chain.push((n, Arc::new(s))),
            _ => stray.push(p),
        }
    }
    (chain, stray)
}

/// One repository's index. Readers take the current snapshot; one writer at a time appends.
pub struct RepoIndex {
    dir: PathBuf,
    current: RwLock<Arc<Snapshot>>,
    /// The chain's file numbers, parallel to the snapshot's segments: the writer's view.
    numbers: Mutex<Vec<u64>>,
    /// Blob lists waiting for the writer, and whether it is running.
    queue: Mutex<(Vec<String>, bool)>,
    idle: Condvar,
    /// Per commit: the ordinal of each file of its tree (`u32::MAX`: not indexed) and the bitmap
    /// of those ordinals, valid for the blob count it was made at.
    trees: Mutex<HashMap<String, (u32, Arc<TreeOrdinals>)>>,
    /// Blobs the writer cannot index (not 40-hex, missing from git, over `MAX_BLOB_BYTES`), so a
    /// search that meets them again does not queue them again.
    refused: Mutex<std::collections::HashSet<String>>,
}

pub struct TreeOrdinals {
    pub ords: Vec<u32>,
    pub bits: RoaringBitmap,
}

pub const NOT_INDEXED: u32 = u32::MAX;

impl RepoIndex {
    pub fn open(dir: &Path) -> RepoIndex {
        let (chain, _) = load(dir);
        let numbers = chain.iter().map(|(n, _)| *n).collect();
        let segments: Vec<Arc<Segment>> = chain.into_iter().map(|(_, s)| s).collect();
        let mut ordinals = HashMap::new();
        for s in &segments {
            for i in 0..s.blobs {
                ordinals.insert(s.blob(i), s.first + i);
            }
        }
        RepoIndex {
            dir: dir.to_path_buf(),
            current: RwLock::new(Arc::new(Snapshot { segments, ordinals })),
            numbers: Mutex::new(numbers),
            queue: Mutex::new((Vec::new(), false)),
            idle: Condvar::new(),
            trees: Mutex::new(HashMap::new()),
            refused: Mutex::new(std::collections::HashSet::new()),
        }
    }

    pub fn snapshot(&self) -> Arc<Snapshot> {
        self.current.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The ordinals of `files` (the tree of `commit`), cached per commit until the index grows.
    pub fn tree(&self, snap: &Snapshot, commit: Option<&str>, files: &[crate::git::FileRef]) -> Arc<TreeOrdinals> {
        let blobs = snap.blobs();
        if let Some(c) = commit
            && let Some((at, t)) = self.trees.lock().unwrap().get(c)
            && *at == blobs
            && t.ords.len() == files.len()
        {
            return t.clone();
        }
        let ords: Vec<u32> = files.iter().map(|f| snap.ordinal(&f.blob_id).unwrap_or(NOT_INDEXED)).collect();
        let mut sorted: Vec<u32> = ords.iter().copied().filter(|&o| o != NOT_INDEXED).collect();
        sorted.sort_unstable();
        sorted.dedup();
        let bits = RoaringBitmap::from_sorted_iter(sorted).expect("sorted");
        let t = Arc::new(TreeOrdinals { ords, bits });
        if let Some(c) = commit {
            let mut trees = self.trees.lock().unwrap();
            if trees.len() > 512 {
                trees.clear();
            }
            trees.insert(c.to_string(), (blobs, t.clone()));
        }
        t
    }

    /// Index `blobs` (hex ids of committed blobs, read from `git_dir`) on a background thread.
    /// Ids already indexed or already waiting are dropped; a writer already running takes the rest
    /// when it finishes its batch.
    pub fn enqueue(self: &Arc<Self>, git_dir: &Path, blobs: Vec<String>) {
        let blobs: Vec<String> = {
            let refused = self.refused.lock().unwrap();
            blobs.into_iter().filter(|b| !refused.contains(b)).collect()
        };
        if blobs.is_empty() {
            return;
        }
        let mut q = self.queue.lock().unwrap();
        q.0.extend(blobs);
        if q.1 {
            return;
        }
        q.1 = true;
        drop(q);
        let me = self.clone();
        let git_dir = git_dir.to_path_buf();
        let spawned = std::thread::Builder::new().name("fdindex-trigram".into()).spawn(move || me.run(&git_dir));
        if spawned.is_err() {
            let mut q = self.queue.lock().unwrap();
            q.0.clear();
            q.1 = false;
            self.idle.notify_all();
        }
    }

    /// Whether a background writer is running now.
    pub fn is_writing(&self) -> bool {
        self.queue.lock().unwrap().1
    }

    /// Block until no writer is running (tests, and the eval harness).
    pub fn settle(&self) {
        let mut q = self.queue.lock().unwrap();
        while q.1 {
            q = self.idle.wait(q).unwrap();
        }
    }

    fn run(&self, git_dir: &Path) {
        loop {
            let pending = {
                let mut q = self.queue.lock().unwrap();
                if q.0.is_empty() {
                    q.1 = false;
                    self.idle.notify_all();
                    return;
                }
                std::mem::take(&mut q.0)
            };
            let (started, asked, before) = (std::time::Instant::now(), pending.len(), self.snapshot().blobs());
            let added = self.append(git_dir, pending);
            if let Ok(bytes) = &added {
                let snap = self.snapshot();
                crate::service::log::info(&format!(
                    "trigram index {}: {} of {asked} blob(s) added ({bytes} content bytes) in {:?}; now {} blobs, {} trigram entries in {} segment(s), {} bytes",
                    self.dir.display(),
                    snap.blobs() - before,
                    started.elapsed(),
                    snap.blobs(),
                    snap.trigrams(),
                    snap.segments(),
                    snap.bytes()
                ));
            }
            if let Err(e) = added {
                crate::service::log::info(&format!("trigram index {}: {e}", self.dir.display()));
                let mut q = self.queue.lock().unwrap();
                q.0.clear();
                q.1 = false;
                self.idle.notify_all();
                return;
            }
        }
    }

    /// Read `blobs` from git and index them (see [`RepoIndex::add`]).
    pub fn append(&self, git_dir: &Path, blobs: Vec<String>) -> std::io::Result<usize> {
        let mut seen = std::collections::HashSet::new();
        let snap = self.snapshot();
        let (todo, bad): (Vec<String>, Vec<String>) = blobs.into_iter().filter(|b| snap.ordinal(b).is_none() && seen.insert(b.clone())).partition(|b| key(b).is_some());
        drop(snap);
        self.refused.lock().unwrap().extend(bad);
        if todo.is_empty() {
            return Ok(0);
        }
        // `cat-file --batch` in chunks: a chunk's content is held at once.
        const CHUNK: usize = 256;
        let mut adder = self.adder()?;
        for ids in todo.chunks(CHUNK) {
            let refs: Vec<&str> = ids.iter().map(String::as_str).collect();
            let contents = crate::engine::cat_file_batch(git_dir, &refs).map_err(|e| std::io::Error::other(e.to_string()))?;
            let mut items: Vec<(&str, Vec<u8>)> = Vec::with_capacity(ids.len());
            for (id, c) in ids.iter().zip(contents) {
                match c {
                    Some(c) if c.len() <= MAX_BLOB_BYTES => items.push((id.as_str(), c)),
                    _ => {
                        self.refused.lock().unwrap().insert(id.clone());
                    }
                }
            }
            adder.add(self, &items)?;
        }
        let bytes = adder.total;
        adder.finish(self)?;
        Ok(bytes)
    }

    /// Index `items` (blob id, content) as delta segments of at most `BATCH_BYTES` of content each,
    /// publishing each as it lands, and merge the chain when it grows long. The caller vouches that
    /// each content is that blob's.
    pub fn add(&self, items: &[(&str, Vec<u8>)]) -> std::io::Result<()> {
        let mut adder = self.adder()?;
        adder.add(self, items)?;
        adder.finish(self)
    }

    fn adder(&self) -> std::io::Result<Adder> {
        std::fs::create_dir_all(&self.dir)?;
        self.sweep();
        Ok(Adder { batch: Vec::new(), bytes: 0, total: 0 })
    }

    fn next_number(&self) -> u64 {
        listing(&self.dir).last().map(|(n, _)| n + 1).unwrap_or(1)
    }

    fn write_delta(&self, batch: Vec<(BlobKey, Vec<u32>)>) -> std::io::Result<()> {
        let snap = self.snapshot();
        // A blob indexed by an earlier batch of this run (two ids, one content) is not added twice.
        let mut seen = std::collections::HashSet::new();
        let batch: Vec<(BlobKey, Vec<u32>)> = batch.into_iter().filter(|(k, _)| !snap.ordinals.contains_key(k) && seen.insert(*k)).collect();
        if batch.is_empty() {
            return Ok(());
        }
        let first = snap.blobs();
        let keys: Vec<BlobKey> = batch.iter().map(|(k, _)| *k).collect();
        let sets: Vec<Vec<u32>> = batch.into_iter().map(|(_, s)| s).collect();
        let postings = segment::invert(first, &sets);
        drop(sets);
        let n = self.next_number();
        let path = self.dir.join(format!("seg-{n:06}.tri"));
        segment::write(&path, first, &keys, postings.into_iter())?;
        let seg = Arc::new(Segment::open(&path)?);
        let mut ordinals = snap.ordinals.clone();
        for (i, k) in keys.iter().enumerate() {
            ordinals.insert(*k, first + i as u32);
        }
        let mut segments = snap.segments.clone();
        segments.push(seg);
        self.numbers.lock().unwrap().push(n);
        *self.current.write().unwrap_or_else(|e| e.into_inner()) = Arc::new(Snapshot { segments, ordinals });
        Ok(())
    }

    /// Merge the whole chain into one new base segment and publish it; the old files are removed
    /// (a reader still holding one keeps its mapping).
    pub fn merge(&self) -> std::io::Result<()> {
        let snap = self.snapshot();
        if snap.segments.len() <= 1 {
            return Ok(());
        }
        let mut keys: Vec<BlobKey> = Vec::with_capacity(snap.blobs() as usize);
        for s in &snap.segments {
            for i in 0..s.blobs {
                keys.push(s.blob(i));
            }
        }
        let n = self.next_number();
        let path = self.dir.join(format!("seg-{n:06}.tri"));
        let refs: Vec<&Segment> = snap.segments.iter().map(|s| s.as_ref()).collect();
        segment::write(&path, 0, &keys, segment::merged(&refs))?;
        let seg = Segment::open(&path)?;
        let old = std::mem::replace(&mut *self.numbers.lock().unwrap(), vec![n]);
        *self.current.write().unwrap_or_else(|e| e.into_inner()) = Arc::new(Snapshot { segments: vec![Arc::new(seg)], ordinals: snap.ordinals.clone() });
        for o in old {
            let _ = std::fs::remove_file(self.dir.join(format!("seg-{o:06}.tri")));
        }
        Ok(())
    }

    /// Remove files outside the chain: leftovers of an interrupted write or merge.
    fn sweep(&self) {
        let (_, stray) = load(&self.dir);
        for p in stray {
            let _ = std::fs::remove_file(p);
        }
        if let Ok(rd) = std::fs::read_dir(&self.dir) {
            for e in rd.flatten() {
                if e.path().extension().is_some_and(|x| x == "tmp") {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
    }
}

/// Blobs collected for the next delta segment.
struct Adder {
    batch: Vec<(BlobKey, Vec<u32>)>,
    bytes: usize,
    total: usize,
}

impl Adder {
    fn add(&mut self, index: &RepoIndex, items: &[(&str, Vec<u8>)]) -> std::io::Result<()> {
        use rayon::prelude::*;
        let sets: Vec<Option<(BlobKey, Vec<u32>, usize)>> = items
            .par_iter()
            .map(|(id, c)| {
                if c.len() > MAX_BLOB_BYTES {
                    return None;
                }
                Some((key(id)?, segment::trigrams_of(c), c.len()))
            })
            .collect();
        for (k, set, n) in sets.into_iter().flatten() {
            self.batch.push((k, set));
            self.bytes += n;
            self.total += n;
            if self.bytes >= BATCH_BYTES {
                index.write_delta(std::mem::take(&mut self.batch))?;
                self.bytes = 0;
            }
        }
        Ok(())
    }

    fn finish(self, index: &RepoIndex) -> std::io::Result<()> {
        if !self.batch.is_empty() {
            index.write_delta(self.batch)?;
        }
        if index.snapshot().segments() > MAX_SEGMENTS {
            index.merge()?;
        }
        Ok(())
    }
}

/// The process's open indexes, by directory: one writer per directory, shared by every request.
pub fn for_dir(dir: &Path) -> Arc<RepoIndex> {
    let mut open = registry().lock().unwrap();
    open.entry(dir.to_path_buf()).or_insert_with(|| Arc::new(RepoIndex::open(dir))).clone()
}

fn registry() -> &'static Mutex<HashMap<PathBuf, Arc<RepoIndex>>> {
    static OPEN: OnceLock<Mutex<HashMap<PathBuf, Arc<RepoIndex>>>> = OnceLock::new();
    OPEN.get_or_init(Default::default)
}

/// Close `dir`'s index and delete it: its repository is gone from the store. A writer still
/// running finishes into a directory that no longer exists, and fails quietly.
pub fn forget(dir: &Path) {
    registry().lock().unwrap().remove(dir);
    let _ = std::fs::remove_dir_all(dir);
}


/// Block until no index of this process has a writer running (tests).
pub fn settle_all() {
    let open: Vec<Arc<RepoIndex>> = registry().lock().unwrap().values().cloned().collect();
    for i in open {
        i.settle();
    }
}
