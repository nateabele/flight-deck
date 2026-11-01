//! The ref watcher: noticing that a repository's refs moved.
//!
//! One FSEvents stream covers the common dir of every known repository. A commit, checkout,
//! rebase or `git branch` writes `HEAD`, `refs/` or `packed-refs` (or, for a linked worktree,
//! `worktrees/<name>/HEAD`), and the watcher turns that into one debounced call per repository:
//! the service re-reads its branch heads for garbage collection and prepares the new base tree
//! of every worktree whose HEAD moved, so the next question finds it parsed.
//!
//! What this is *not* used for is deciding whether a request sees the caller's own edits. That
//! rests on `sweep`, which reads the file system. A first version did rest on file events and a
//! barrier, and it was measured unsound; the measurement is recorded in `sweep`'s docs. A ref
//! event that arrives late costs a late warm-up, never a wrong answer: every request compares the
//! HEAD it finds on disk with the one its view was built on (`git::read_head`).
//!
//! The platform part (`fsevents`) only turns notifications into `Raw` events; the meaning of a
//! path lives here and is the same everywhere. Without a platform backend (Linux today) there is
//! no `Watcher`, branch heads are read at each collection instead, and nothing else changes.

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, SystemTime};

#[cfg(target_os = "macos")]
mod fsevents;

#[derive(Debug, Clone)]
pub struct WatchConfig {
    /// Watch refs, and keep each active worktree's view between requests (`sweep`). Off, every
    /// request reads `git status`.
    pub enabled: bool,
    /// A worktree not queried or written for this long drops its kept view (spec §5.4): its next
    /// query reads it in full with `git status`.
    pub active_for: Duration,
}

impl Default for WatchConfig {
    fn default() -> Self {
        WatchConfig { enabled: true, active_for: Duration::from_secs(6 * 3600) }
    }
}

/// What a backend reports. Paths are absolute and canonical (FSEvents reports real paths).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Raw {
    /// Something at this path changed. A coalesced subtree (`MustScanSubDirs`) is reported as a
    /// change of its root, which is conservative: it is read as "refs may have moved".
    Changed(PathBuf),
    /// The backend lost events altogether.
    Overflow,
}

pub(crate) type Sink = Arc<dyn Fn(&[Raw]) + Send + Sync>;

pub(crate) trait Backend: Send + Sync {
    /// Replace the watched directories. Must not lose events under directories present before and
    /// after.
    fn set_paths(&self, paths: &[PathBuf]) -> io::Result<()>;
}

fn new_backend(_sink: Sink) -> Option<Box<dyn Backend>> {
    #[cfg(target_os = "macos")]
    return fsevents::FsEvents::new(_sink).ok().map(|b| Box::new(b) as Box<dyn Backend>);
    #[cfg(not(target_os = "macos"))]
    return None;
}

#[derive(Default)]
struct Repo {
    refs_dirty: bool,
    last_event: Option<SystemTime>,
    events: u64,
}

#[derive(Default)]
struct State {
    repos: BTreeMap<PathBuf, Repo>,
    total_events: u64,
}

struct Shared {
    state: Mutex<State>,
    cv: Condvar,
}

/// One per daemon.
pub struct Watcher {
    shared: Arc<Shared>,
    backend: Box<dyn Backend>,
    /// Serialises changes of the watched set; the backend replaces it wholesale.
    set_lock: Mutex<()>,
}

#[derive(Debug, Clone)]
pub struct RefWatchInfo {
    pub common: PathBuf,
    pub events: u64,
    pub last_event: Option<SystemTime>,
}

impl Watcher {
    /// `on_refs(common_dir)` is called, off every request path and debounced, after a repository's
    /// refs changed. `None` when disabled or when the platform offers no backend.
    pub fn start(cfg: &WatchConfig, on_refs: impl Fn(&Path) + Send + Sync + 'static) -> Option<Arc<Watcher>> {
        if !cfg.enabled {
            return None;
        }
        let shared = Arc::new(Shared { state: Mutex::new(State::default()), cv: Condvar::new() });
        let sink: Sink = {
            let shared = Arc::downgrade(&shared);
            Arc::new(move |batch: &[Raw]| {
                if let Some(s) = shared.upgrade() {
                    s.deliver(batch);
                }
            })
        };
        let backend = new_backend(sink)?;
        let weak = Arc::downgrade(&shared);
        std::thread::Builder::new().name("fdindex-refs".into()).spawn(move || refs_loop(weak, on_refs)).ok()?;
        Some(Arc::new(Watcher { shared, backend, set_lock: Mutex::new(()) }))
    }

    /// Never called with the state lock held: replacing an FSEvents stream waits for callbacks
    /// already running, and a callback needs that lock to record its events.
    fn apply(&self, st: std::sync::MutexGuard<'_, State>) -> io::Result<()> {
        let paths: Vec<PathBuf> = st.repos.keys().cloned().collect();
        drop(st);
        self.backend.set_paths(&paths)
    }

    /// Watch a repository's refs. Idempotent. Its refs are read once, shortly after the first call.
    pub fn watch_repo(&self, common: &Path) -> bool {
        // Called on every request, so the common case takes one lock and no more.
        if self.shared.state.lock().unwrap().repos.contains_key(common) {
            return true;
        }
        let _set = self.set_lock.lock().unwrap();
        let mut st = self.shared.state.lock().unwrap();
        if st.repos.contains_key(common) {
            return true;
        }
        st.repos.insert(common.to_path_buf(), Repo { refs_dirty: true, ..Default::default() });
        if self.apply(st).is_err() {
            self.shared.state.lock().unwrap().repos.remove(common);
            return false;
        }
        self.shared.cv.notify_all();
        true
    }

    /// Forget a repository whose common dir is gone.
    pub fn unwatch_repo(&self, common: &Path) {
        let _set = self.set_lock.lock().unwrap();
        let mut st = self.shared.state.lock().unwrap();
        if st.repos.remove(common).is_some() {
            let _ = self.apply(st);
        }
    }

    pub fn repos(&self) -> Vec<RefWatchInfo> {
        let st = self.shared.state.lock().unwrap();
        st.repos.iter().map(|(p, r)| RefWatchInfo { common: p.clone(), events: r.events, last_event: r.last_event }).collect()
    }

    pub fn total_events(&self) -> u64 {
        self.shared.state.lock().unwrap().total_events
    }
}

impl Shared {
    fn deliver(&self, batch: &[Raw]) {
        let mut st = self.state.lock().unwrap();
        for raw in batch {
            st.route(raw);
        }
        drop(st);
        self.cv.notify_all();
    }
}

impl State {
    fn route(&mut self, raw: &Raw) {
        self.total_events += 1;
        let now = SystemTime::now();
        match raw {
            Raw::Overflow => {
                for r in self.repos.values_mut() {
                    r.refs_dirty = true;
                }
            }
            Raw::Changed(path) => {
                let Some(common) = path.ancestors().find(|a| self.repos.contains_key(*a)).map(Path::to_path_buf) else { return };
                let Ok(rel) = path.strip_prefix(&common) else { return };
                let first = rel.components().next().and_then(|c| c.as_os_str().to_str()).unwrap_or("");
                // The common dir itself (a coalesced subtree) may have moved anything.
                let refish = rel.as_os_str().is_empty() || matches!(first, "HEAD" | "packed-refs" | "refs" | "worktrees");
                // Inside `worktrees/<name>/` only `HEAD` (that worktree moving) is a ref; the
                // bookkeeping files git keeps there are not.
                let inside_worktree = first == "worktrees" && rel.components().count() > 2 && path.file_name().is_none_or(|n| n != "HEAD");
                // A ref is written to `<name>.lock` and renamed over the real file; the rename is
                // the event that matters.
                let lock = path.extension().is_some_and(|e| e == "lock");
                if !refish || inside_worktree || lock {
                    return;
                }
                if let Some(r) = self.repos.get_mut(&common) {
                    r.refs_dirty = true;
                    r.last_event = Some(now);
                    r.events += 1;
                }
            }
        }
    }
}

/// Waits for repositories whose refs changed and hands each to `on_refs`, after a short quiet
/// period so a rebase that moves a ref fifty times is read once.
fn refs_loop(shared: Weak<Shared>, on_refs: impl Fn(&Path)) {
    const QUIET: Duration = Duration::from_millis(250);
    loop {
        {
            let Some(s) = shared.upgrade() else { return };
            let mut st = s.state.lock().unwrap();
            while !st.repos.values().any(|r| r.refs_dirty) {
                if Arc::strong_count(&s) == 1 {
                    return; // the Watcher is gone; this thread held the last reference
                }
                st = s.cv.wait_timeout(st, Duration::from_secs(30)).unwrap().0;
            }
        }
        std::thread::sleep(QUIET);
        let Some(s) = shared.upgrade() else { return };
        let todo: Vec<PathBuf> = {
            let mut st = s.state.lock().unwrap();
            st.repos.iter_mut().filter_map(|(p, r)| std::mem::take(&mut r.refs_dirty).then(|| p.clone())).collect()
        };
        for common in todo {
            on_refs(&common);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state() -> State {
        let mut st = State::default();
        st.repos.insert("/w/app/.git".into(), Repo::default());
        st
    }

    fn changed(path: &str) -> Raw {
        Raw::Changed(path.into())
    }

    fn dirty(st: &State) -> bool {
        st.repos["/w/app/.git".as_ref() as &Path].refs_dirty
    }

    #[test]
    fn objects_and_the_index_are_not_refs() {
        // `git commit` writes dozens of objects; waking the ref reader for each would be noise.
        let mut st = state();
        st.route(&changed("/w/app/.git/index"));
        st.route(&changed("/w/app/.git/objects/ab/cdef"));
        st.route(&changed("/w/app/src/a.rs"));
        assert!(!dirty(&st));
    }

    #[test]
    fn a_moved_branch_head_or_packed_refs_is_a_ref_change() {
        for p in ["/w/app/.git/refs/heads/main", "/w/app/.git/HEAD", "/w/app/.git/packed-refs", "/w/app/.git/refs/heads/feature/x"] {
            let mut st = state();
            st.route(&changed(p));
            assert!(dirty(&st), "{p}");
        }
    }

    #[test]
    fn git_lock_files_are_not_a_ref_change() {
        let mut st = state();
        st.route(&changed("/w/app/.git/refs/heads/main.lock"));
        st.route(&changed("/w/app/.git/HEAD.lock"));
        assert!(!dirty(&st));
    }

    #[test]
    fn a_linked_worktrees_head_counts_but_its_bookkeeping_does_not() {
        let mut st = state();
        st.route(&changed("/w/app/.git/worktrees/x/gitdir"));
        assert!(!dirty(&st));
        st.route(&changed("/w/app/.git/worktrees/x/HEAD"));
        assert!(dirty(&st));
    }

    #[test]
    fn lost_events_and_a_coalesced_common_dir_distrust_every_repository() {
        let mut st = state();
        st.route(&Raw::Overflow);
        assert!(dirty(&st));
        let mut st = state();
        st.route(&changed("/w/app/.git"));
        assert!(dirty(&st));
    }
}
