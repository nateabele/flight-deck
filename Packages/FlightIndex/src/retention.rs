//! Keeping the store from growing without bound as worktrees come and go (spec §4.4, §10).
//!
//! What is kept: a blob's facts live while a tree of some live worktree's HEAD, an overlay, or a
//! branch head names the blob. A collection removes the rest, in this order, per repository:
//!
//! 1. branch heads are re-read from git (so a branch moved while the daemon was down still roots
//!    the right tree);
//! 2. roots are settled: worktree rows whose directory is gone, then trees nothing roots;
//! 3. facts nothing names are deleted a chunk at a time, the writer released between chunks;
//! 4. free pages are returned to the filesystem 256 at a time and the WAL is folded back, because
//!    in WAL mode the file only shrinks at a checkpoint.
//!
//! A repository whose common dir is gone is not collected, it is deleted: no request will ever
//! name it again, and its file is the largest single thing a vanished project leaves behind.
//!
//! Collection never blocks queries: readers are read-only WAL connections, which a writer never
//! blocks, and builds wait on the writer only for one chunk at a time. The cost of a collection
//! that finds nothing is a few queries per repository.

use crate::engine::Engine;
use crate::store;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime};

/// How often the scheduled collection runs when nothing asks for one sooner.
pub const GC_INTERVAL: Duration = Duration::from_secs(3600);

/// A daemon that has only just started does not collect at once: it is about to be asked for
/// things, and nothing has had time to go stale.
pub const FIRST_GC_AFTER: Duration = Duration::from_secs(60);

/// How long the maintenance thread sleeps between looks at the world. Each look is a stat per
/// known worktree and a few mutex locks, so a short tick costs nothing measurable, and a removed
/// worktree is noticed within it even if the watcher never reported it.
pub const TICK: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Default)]
pub struct GcReport {
    pub at: Option<SystemTime>,
    pub took: Duration,
    pub repos: usize,
    pub repos_dropped: usize,
    pub worktrees_dropped: usize,
    pub trees_dropped: usize,
    pub facts_dropped: usize,
    pub pages_vacuumed: u64,
    pub bytes_before: u64,
    pub bytes_after: u64,
    /// Free pages left across every repository after the vacuum (nonzero only when a vacuum
    /// could not finish, or a build wrote while it ran).
    pub free_pages_after: u64,
    pub errors: Vec<String>,
}

impl GcReport {
    pub fn reclaimed(&self) -> u64 {
        self.bytes_before.saturating_sub(self.bytes_after)
    }

    pub fn summary(&self) -> String {
        format!(
            "{} repo(s), {} dropped; {} worktree row(s), {} tree(s), {} fact(s) collected; {} page(s) vacuumed; {} -> {} bytes ({} reclaimed); {} free page(s) left; took {:.2}s{}",
            self.repos,
            self.repos_dropped,
            self.worktrees_dropped,
            self.trees_dropped,
            self.facts_dropped,
            self.pages_vacuumed,
            self.bytes_before,
            self.bytes_after,
            self.reclaimed(),
            self.free_pages_after,
            self.took.as_secs_f64(),
            if self.errors.is_empty() { String::new() } else { format!("; {} error(s): {}", self.errors.len(), self.errors.join("; ")) }
        )
    }

    pub fn to_json(&self) -> Value {
        json!({
            "at": self.at.and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok()).map(|d| d.as_secs()),
            "took_seconds": self.took.as_secs_f64(),
            "repos": self.repos, "repos_dropped": self.repos_dropped,
            "worktrees_dropped": self.worktrees_dropped, "trees_dropped": self.trees_dropped, "facts_dropped": self.facts_dropped,
            "pages_vacuumed": self.pages_vacuumed,
            "bytes_before": self.bytes_before, "bytes_after": self.bytes_after, "bytes_reclaimed": self.reclaimed(),
            "free_pages_after": self.free_pages_after,
            "errors": self.errors,
        })
    }
}

/// Collect every repository in the store. `forget(repo)` is told about each repository dropped, so
/// the caller can stop watching it.
pub fn collect(engine: &Engine, forget: &dyn Fn(&Path)) -> GcReport {
    let started = Instant::now();
    let mut r = GcReport { at: Some(SystemTime::now()), ..Default::default() };
    let dbs = store::list_dbs(engine.store_root());
    r.bytes_before = dbs.iter().map(|(db, _)| store::db_bytes(db)).sum();
    for (db, repo) in &dbs {
        let Some(repo) = repo else { continue }; // unreadable: the writer rebuilds it when next opened
        if !repo.exists() {
            engine.drop_repo(repo);
            forget(repo);
            r.repos_dropped += 1;
            continue;
        }
        r.repos += 1;
        if repo.join("HEAD").exists()
            && let Err(e) = engine.refresh_known_refs(repo)
        {
            // Collecting without current refs would drop a tree a branch still names; skip the
            // repository this round instead.
            r.errors.push(format!("{}: refs: {e}", db.display()));
            continue;
        }
        match engine.gc(repo) {
            Ok(s) => {
                r.worktrees_dropped += s.worktrees_dropped;
                r.trees_dropped += s.trees_dropped;
                r.facts_dropped += s.facts_dropped;
            }
            Err(e) => {
                r.errors.push(format!("{}: gc: {e}", db.display()));
                continue;
            }
        }
        match engine.vacuum(repo) {
            Ok(pages) => r.pages_vacuumed += pages,
            Err(e) => r.errors.push(format!("{}: vacuum: {e}", db.display())),
        }
        r.free_pages_after += engine.reader(repo).and_then(|rd| rd.stats()).map(|s| s.free_pages).unwrap_or(0);
    }
    // Repositories dropped above are gone from disk; measure what is left.
    r.bytes_after = store::list_dbs(engine.store_root()).iter().map(|(db, _)| store::db_bytes(db)).sum();
    r.took = started.elapsed();
    r
}

/// What the maintenance thread waits on, and what it remembers.
#[derive(Default)]
pub struct Maintenance {
    wake: Mutex<bool>,
    cv: Condvar,
    stop: AtomicBool,
    gc_wanted: AtomicBool,
    /// One collection at a time, whoever asked.
    pub(crate) gc_lock: Mutex<()>,
    last: Mutex<Option<GcReport>>,
    last_run: Mutex<Option<Instant>>,
    runs: std::sync::atomic::AtomicU64,
    reclaimed_total: std::sync::atomic::AtomicU64,
}

impl Maintenance {
    pub fn wake(&self) {
        *self.wake.lock().unwrap() = true;
        self.cv.notify_all();
    }

    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
        self.wake();
    }

    pub fn stopped(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    /// Sleep until woken or `TICK` passes.
    pub fn wait(&self) {
        let mut w = self.wake.lock().unwrap();
        if !*w {
            w = self.cv.wait_timeout(w, TICK).unwrap().0;
        }
        *w = false;
    }

    pub fn request_gc(&self) {
        self.gc_wanted.store(true, Ordering::Relaxed);
        self.wake();
    }

    /// Is a scheduled collection due: asked for, or an hour since the last, or the first one after
    /// startup?
    pub fn gc_due(&self, uptime: Duration) -> bool {
        if self.gc_wanted.swap(false, Ordering::Relaxed) {
            return true;
        }
        match *self.last_run.lock().unwrap() {
            Some(t) => t.elapsed() >= GC_INTERVAL,
            None => uptime >= FIRST_GC_AFTER,
        }
    }

    pub fn record(&self, report: GcReport) {
        *self.last_run.lock().unwrap() = Some(Instant::now());
        self.runs.fetch_add(1, Ordering::Relaxed);
        self.reclaimed_total.fetch_add(report.reclaimed(), Ordering::Relaxed);
        *self.last.lock().unwrap() = Some(report);
    }

    pub fn last(&self) -> Option<GcReport> {
        self.last.lock().unwrap().clone()
    }

    pub fn runs(&self) -> u64 {
        self.runs.load(Ordering::Relaxed)
    }

    pub fn reclaimed_total(&self) -> u64 {
        self.reclaimed_total.load(Ordering::Relaxed)
    }
}

/// Free pages and size on disk of every repository database, for `status`.
pub fn store_overview(engine: &Engine) -> Vec<(PathBuf, Option<PathBuf>, u64, u64)> {
    store::list_dbs(engine.store_root())
        .into_iter()
        .map(|(db, repo)| {
            let free = repo.as_ref().and_then(|r| engine.reader(r).ok()).and_then(|rd| rd.stats().ok()).map(|s| s.free_pages).unwrap_or(0);
            let bytes = store::db_bytes(&db);
            (db, repo, bytes, free)
        })
        .collect()
}
