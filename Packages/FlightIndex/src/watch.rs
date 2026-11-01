//! File and ref watching, and the barrier that makes "read your own writes" provable.
//!
//! The platform part (`fsevents`, `inotify`) only turns kernel notifications into `Raw` events.
//! Everything that decides what an event *means* lives here, and is the same on every platform:
//! which worktree owns a path, what is worth remembering about it, when a worktree can no longer
//! be trusted and needs a full `git status`, and how a request proves it has seen every change
//! made before it.
//!
//! ## The barrier
//!
//! A watcher alone cannot answer "have I heard about everything that happened before this
//! request?": FSEvents delivers after a delay of its own, and an edit made a millisecond ago may
//! still be in the kernel's queue. So `sync` does what watchman does: it creates (and removes) a
//! uniquely named *cookie* file inside the worktree's git dir and waits until the stream reports
//! that file. Events on one stream arrive in the order the kernel saw them, so once the cookie has
//! been delivered, every earlier change has been too, however the edit was made (an editor, `sed
//! -i`, a patch tool, another process). The wait is about 10 ms on macOS (p50 10.3, p95 12.1,
//! measured over 100 external writes): `FSEventStreamFlushSync`/`FlushAsync` and every latency
//! and flag setting tried left it unchanged, so it is fseventsd's own delay, not ours. Against
//! 14 to 20 ms for the `git status` it replaces (a 2.5k-file repository to tessera), and no longer
//! growing with repository size. The git dir is used because git ignores unknown files there, so a cookie
//! never shows up as an untracked file in the user's own `git status`.
//!
//! ## What is remembered
//!
//! Per worktree, only a set of paths that *might* differ from what the index has and whether
//! the whole worktree must be re-read. Filtering happens on arrival, by extension, so a build
//! writing thousands of files under `target/` or `node_modules/` costs a hash lookup each and no
//! memory: only files in a language the index understands (plus `.gitignore`) are kept.

use crate::lang;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant, SystemTime};

#[cfg(target_os = "macos")]
mod fsevents;
#[cfg(target_os = "linux")]
mod inotify;

/// Prefix of the barrier files. Anything with this name is consumed by the watcher, never
/// interpreted as a change.
const COOKIE_PREFIX: &str = "fdindex-cookie-";

/// How long a request waits for its cookie before giving up on the watcher and re-reading the
/// worktree with `git status`. An FSEvents round trip is a few milliseconds; this only matters
/// when the stream is wedged, and then a slow answer beats a wrong one.
const COOKIE_TIMEOUT: Duration = Duration::from_millis(1500);

/// More remembered paths than this means a bulk operation (a checkout, a generator): cheaper to
/// ask git once than to stat each path.
const MAX_PENDING_PATHS: usize = 4096;

#[derive(Debug, Clone)]
pub struct WatchConfig {
    pub enabled: bool,
    /// A worktree not queried or written for this long loses its watch and is re-checked against
    /// `git status` on its next query (spec §5.4).
    pub active_for: Duration,
    /// Upper bound on kernel watches (inotify only; FSEvents has no per-directory cost).
    pub max_watches: usize,
}

impl Default for WatchConfig {
    fn default() -> Self {
        WatchConfig { enabled: true, active_for: Duration::from_secs(6 * 3600), max_watches: 4096 }
    }
}

/// What a backend reports. Paths are absolute and canonical (the backends are handed canonical
/// roots, and FSEvents reports real paths).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Raw {
    /// Something at `path` changed. `structural` is set for a directory that was created, removed
    /// or renamed: the files inside changed with it, though no event names them.
    Changed { path: PathBuf, dir: bool, structural: bool },
    /// Events beneath `path` were coalesced or dropped: anything under it may have changed.
    Rescan(PathBuf),
    /// The backend lost events altogether: nothing is trusted until re-read.
    Overflow,
    /// A watched root was moved or deleted.
    RootGone(PathBuf),
}

/// What the platform is asked to watch.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Spec {
    /// A worktree: everything beneath it, honouring ignore rules where the platform needs to.
    Tree(PathBuf),
    /// A repository's common dir: `HEAD`, `refs/`, `packed-refs`, `worktrees/*/HEAD`.
    Refs(PathBuf),
    /// One directory, not recursively: where a worktree's cookies are written.
    Dir(PathBuf),
}

pub(crate) type Sink = Arc<dyn Fn(&[Raw]) + Send + Sync>;

pub(crate) trait Backend: Send + Sync {
    /// Replace the watched set. Must not lose events for specs present before and after.
    fn set_specs(&self, specs: &[Spec]) -> io::Result<()>;
}

fn new_backend(_cfg: &WatchConfig, _sink: Sink) -> Option<Box<dyn Backend>> {
    #[cfg(target_os = "macos")]
    return fsevents::FsEvents::new(_sink).ok().map(|b| Box::new(b) as Box<dyn Backend>);
    #[cfg(target_os = "linux")]
    return inotify::Inotify::new(_sink, _cfg.max_watches).ok().map(|b| Box::new(b) as Box<dyn Backend>);
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    return None;
}

/// What happened under a worktree since the last `sync`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Pending {
    /// The watcher cannot vouch for the worktree (dropped events, a coalesced subtree): re-read
    /// it with `git status`.
    pub rescan: bool,
    /// Files, in a language the index understands, that were written, created, removed or renamed.
    pub paths: BTreeSet<PathBuf>,
    /// Directories created, removed or renamed: everything inside may have changed.
    pub subtrees: BTreeSet<PathBuf>,
    /// A `.gitignore` changed, so what counts as ignored may have changed.
    pub gitignore: bool,
}

impl Pending {
    pub fn is_empty(&self) -> bool {
        !self.rescan && !self.gitignore && self.paths.is_empty() && self.subtrees.is_empty()
    }
}

#[derive(Debug)]
pub enum SyncError {
    /// Nothing watches this worktree.
    Unwatched,
    /// The cookie never came back: the stream is not delivering.
    Timeout,
    Io(io::Error),
}

struct Wt {
    gitdir: PathBuf,
    common: PathBuf,
    pending: Pending,
    last_event: Option<SystemTime>,
    events: u64,
    watched_since: SystemTime,
}

#[derive(Default)]
struct Repo {
    refs_dirty: bool,
    last_event: Option<SystemTime>,
    events: u64,
}

#[derive(Default)]
struct State {
    roots: BTreeMap<PathBuf, Wt>,
    repos: BTreeMap<PathBuf, Repo>,
    seen_cookies: HashSet<String>,
    next_cookie: u64,
    total_events: u64,
    /// A worktree root vanished, or a linked worktree was added or removed: the maintenance sweep
    /// should look now rather than at its next tick.
    sweep_wanted: bool,
}

struct Shared {
    state: Mutex<State>,
    cv: Condvar,
}

/// One per daemon. Cheap to share.
pub struct Watcher {
    shared: Arc<Shared>,
    backend: Box<dyn Backend>,
    /// Serialises changes of the watched set; the backend replaces the set wholesale.
    set_lock: Mutex<()>,
    /// Makes cookie names unique across daemons that share a git dir.
    pid: u32,
}

/// A snapshot of one worktree for `status`.
#[derive(Debug, Clone)]
pub struct WatchInfo {
    pub worktree: PathBuf,
    pub events: u64,
    pub last_event: Option<SystemTime>,
    pub watched_since: SystemTime,
}

#[derive(Debug, Clone)]
pub struct RefWatchInfo {
    pub common: PathBuf,
    pub events: u64,
    pub last_event: Option<SystemTime>,
}

impl Watcher {
    /// `on_refs(common_dir)` is called, off the request path and debounced, after a repository's
    /// refs or worktree list changed. `None` when the platform offers no watcher; callers then use
    /// `git status` on every request.
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
        let backend = new_backend(cfg, sink)?;
        let w = Arc::new(Watcher { shared: shared.clone(), backend, set_lock: Mutex::new(()), pid: std::process::id() });
        let weak = Arc::downgrade(&shared);
        let spawned = std::thread::Builder::new().name("fdindex-refs".into()).spawn(move || refs_loop(weak, on_refs));
        spawned.ok()?;
        Some(w)
    }

    fn specs(st: &State) -> Vec<Spec> {
        let mut v: Vec<Spec> = Vec::new();
        v.extend(st.roots.keys().cloned().map(Spec::Tree));
        v.extend(st.repos.keys().cloned().map(Spec::Refs));
        v.extend(st.roots.values().map(|w| Spec::Dir(w.gitdir.clone())));
        v.sort();
        v.dedup();
        v
    }

    /// Push the watched set to the backend. Never called with the state lock held: replacing an
    /// FSEvents stream waits for callbacks already running, and a callback needs that lock to
    /// record its events, so holding it here would deadlock the two.
    fn apply(&self, st: std::sync::MutexGuard<'_, State>) -> io::Result<()> {
        let specs = Self::specs(&st);
        drop(st);
        self.backend.set_specs(&specs)
    }

    /// Watch a repository's refs. Idempotent.
    pub fn watch_repo(&self, common: &Path) -> bool {
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

    pub fn info(&self, root: &Path) -> Option<WatchInfo> {
        let st = self.shared.state.lock().unwrap();
        st.roots.get(root).map(|w| WatchInfo { worktree: root.to_path_buf(), events: w.events, last_event: w.last_event, watched_since: w.watched_since })
    }

    pub fn is_watching(&self, root: &Path) -> bool {
        self.shared.state.lock().unwrap().roots.contains_key(root)
    }

    /// Start watching a worktree and wait until the watch is provably live (its own cookie comes
    /// back), so that every change after this returns will be reported. Returns whether it is
    /// watched. Idempotent.
    pub fn watch_worktree(&self, root: &Path, gitdir: &Path, common: &Path) -> bool {
        {
            let _set = self.set_lock.lock().unwrap();
            let mut st = self.shared.state.lock().unwrap();
            if st.roots.contains_key(root) {
                return true;
            }
            st.roots.insert(
                root.to_path_buf(),
                Wt { gitdir: gitdir.to_path_buf(), common: common.to_path_buf(), pending: Pending::default(), last_event: None, events: 0, watched_since: SystemTime::now() },
            );
            st.repos.entry(common.to_path_buf()).or_insert_with(|| Repo { refs_dirty: true, ..Default::default() });
            if self.apply(st).is_err() {
                self.shared.state.lock().unwrap().roots.remove(root);
                return false;
            }
        }
        self.shared.cv.notify_all();
        match self.cookie(root) {
            Ok(_) => true,
            Err(_) => {
                self.unwatch_worktree(root);
                false
            }
        }
    }

    pub fn unwatch_worktree(&self, root: &Path) {
        let _set = self.set_lock.lock().unwrap();
        let mut st = self.shared.state.lock().unwrap();
        if st.roots.remove(root).is_some() {
            let _ = self.apply(st);
        }
    }

    /// Forget a repository whose common dir is gone.
    pub fn unwatch_repo(&self, common: &Path) {
        let _set = self.set_lock.lock().unwrap();
        let mut st = self.shared.state.lock().unwrap();
        if st.repos.remove(common).is_some() {
            let _ = self.apply(st);
        }
    }

    /// Write a cookie in the worktree's git dir and wait for the stream to report it. On return
    /// every change made before the call has been delivered.
    fn cookie(&self, root: &Path) -> std::result::Result<(), SyncError> {
        let (path, name) = {
            let mut st = self.shared.state.lock().unwrap();
            let gitdir = st.roots.get(root).ok_or(SyncError::Unwatched)?.gitdir.clone();
            st.next_cookie += 1;
            let name = format!("{COOKIE_PREFIX}{}-{}", self.pid, st.next_cookie);
            (gitdir.join(&name), name)
        };
        // Created and removed at once: FSEvents and inotify both report the pair, and nothing is
        // left behind if the daemon dies while waiting.
        std::fs::write(&path, b"").map_err(SyncError::Io)?;
        let _ = std::fs::remove_file(&path);
        let deadline = Instant::now() + COOKIE_TIMEOUT;
        let mut st = self.shared.state.lock().unwrap();
        loop {
            if st.seen_cookies.remove(&name) {
                return Ok(());
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(SyncError::Timeout);
            }
            st = self.shared.cv.wait_timeout(st, left).unwrap().0;
        }
    }

    /// The barrier plus a drain: when this returns `Ok`, `Pending` holds every change made under
    /// `root` before the call that the caller has not yet been given.
    pub fn sync(&self, root: &Path) -> std::result::Result<Pending, SyncError> {
        self.cookie(root)?;
        let mut st = self.shared.state.lock().unwrap();
        let wt = st.roots.get_mut(root).ok_or(SyncError::Unwatched)?;
        Ok(std::mem::take(&mut wt.pending))
    }

    /// Take what has been remembered for `root` without a barrier: right after the watch went live,
    /// to discard whatever it saw while the caller was not yet reading the worktree.
    pub fn drain(&self, root: &Path) -> Pending {
        self.shared.state.lock().unwrap().roots.get_mut(root).map(|w| std::mem::take(&mut w.pending)).unwrap_or_default()
    }

    /// Something went wrong that the watcher cannot see (a request found a `git status` that
    /// disagrees with the cache): the next `sync` reports a rescan.
    pub fn distrust(&self, root: &Path) {
        if let Some(w) = self.shared.state.lock().unwrap().roots.get_mut(root) {
            w.pending.rescan = true;
        }
    }

    /// Did a worktree root vanish, or a linked worktree appear or go, since this was last asked?
    /// The maintenance sweep checks it so a removal is noticed at once, not at its next tick.
    pub fn take_sweep_wanted(&self) -> bool {
        std::mem::take(&mut self.shared.state.lock().unwrap().sweep_wanted)
    }

    pub fn worktrees(&self) -> Vec<WatchInfo> {
        let st = self.shared.state.lock().unwrap();
        st.roots.iter().map(|(p, w)| WatchInfo { worktree: p.clone(), events: w.events, last_event: w.last_event, watched_since: w.watched_since }).collect()
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

/// Is this a file the index would ever parse, or a `.gitignore`?
fn interesting(path: &Path) -> bool {
    lang::for_path(path).is_some() || path.file_name().is_some_and(|n| n == ".gitignore")
}

impl State {
    /// Who owns `path`: the innermost watched worktree root or repository common dir containing it.
    fn owner(&self, path: &Path) -> Option<Owner> {
        for a in path.ancestors() {
            if self.repos.contains_key(a) {
                return Some(Owner::Repo(a.to_path_buf()));
            }
            if self.roots.contains_key(a) {
                return Some(Owner::Worktree(a.to_path_buf()));
            }
        }
        None
    }

    fn route(&mut self, raw: &Raw) {
        self.total_events += 1;
        let now = SystemTime::now();
        match raw {
            Raw::Overflow => {
                for w in self.roots.values_mut() {
                    w.pending.rescan = true;
                }
                for r in self.repos.values_mut() {
                    r.refs_dirty = true;
                }
                self.sweep_wanted = true;
            }
            Raw::RootGone(path) => {
                self.sweep_wanted = true;
                if let Some(w) = self.roots.get_mut(path) {
                    w.pending.rescan = true;
                }
            }
            Raw::Rescan(path) => match self.owner(path) {
                Some(Owner::Worktree(r)) => {
                    let w = self.roots.get_mut(&r).expect("owner is a key");
                    w.pending.rescan = true;
                    w.last_event = Some(now);
                    w.events += 1;
                }
                Some(Owner::Repo(c)) => self.repo_event(&c, path, now),
                None => {}
            },
            Raw::Changed { path, dir, structural } => {
                // Barrier files are consumed wherever they are seen.
                if let Some(name) = path.file_name().and_then(|n| n.to_str())
                    && name.starts_with(COOKIE_PREFIX)
                {
                    if self.seen_cookies.len() > 1024 {
                        self.seen_cookies.clear(); // cookies of requests that gave up; never read again
                    }
                    self.seen_cookies.insert(name.to_string());
                    return;
                }
                match self.owner(path) {
                    Some(Owner::Repo(c)) => self.repo_event(&c, path, now),
                    Some(Owner::Worktree(r)) => {
                        let w = self.roots.get_mut(&r).expect("owner is a key");
                        let mut touched = false;
                        // Already distrusted: the whole worktree is about to be re-read, so
                        // remembering individual paths would only grow the set.
                        if w.pending.rescan {
                            touched = true;
                        } else if *dir {
                            if *structural {
                                w.pending.subtrees.insert(path.clone());
                                touched = true;
                            }
                        } else if interesting(path) {
                            if path.file_name().is_some_and(|n| n == ".gitignore") {
                                w.pending.gitignore = true;
                            }
                            w.pending.paths.insert(path.clone());
                            touched = true;
                        }
                        if w.pending.paths.len() + w.pending.subtrees.len() > MAX_PENDING_PATHS {
                            w.pending.paths.clear();
                            w.pending.subtrees.clear();
                            w.pending.rescan = true;
                        }
                        if touched {
                            w.last_event = Some(now);
                            w.events += 1;
                        }
                    }
                    None => {}
                }
            }
        }
    }

    /// A change inside a repository's common dir: only refs matter here.
    fn repo_event(&mut self, common: &Path, path: &Path, now: SystemTime) {
        let Ok(rel) = path.strip_prefix(common) else { return };
        let first = rel.components().next().and_then(|c| c.as_os_str().to_str()).unwrap_or("");
        let refish = matches!(first, "HEAD" | "packed-refs" | "refs" | "worktrees");
        if !refish {
            return;
        }
        if first == "worktrees" {
            // `worktrees/<name>` appearing or going means a worktree was added or pruned, which
            // the maintenance sweep should look at; a `HEAD` inside is that worktree moving. The
            // cookies and lock files git keeps in there are neither.
            let depth = rel.components().count();
            let is_head = path.file_name().is_some_and(|n| n == "HEAD");
            if depth <= 2 {
                self.sweep_wanted = true;
            } else if !is_head {
                return;
            }
        }
        if let Some(r) = self.repos.get_mut(common) {
            r.refs_dirty = true;
            r.last_event = Some(now);
            r.events += 1;
        }
    }
}

enum Owner {
    Worktree(PathBuf),
    Repo(PathBuf),
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

    fn wt(gitdir: &str, common: &str) -> Wt {
        Wt { gitdir: gitdir.into(), common: common.into(), pending: Pending::default(), last_event: None, events: 0, watched_since: SystemTime::now() }
    }

    fn state() -> State {
        let mut st = State::default();
        st.roots.insert("/w/app".into(), wt("/w/app/.git", "/w/app/.git"));
        // A linked worktree nested inside the main one, as `.worktrees/x` conventionally is.
        st.roots.insert("/w/app/.worktrees/x".into(), wt("/w/app/.git/worktrees/x", "/w/app/.git"));
        st.repos.insert("/w/app/.git".into(), Repo::default());
        st
    }

    fn changed(path: &str) -> Raw {
        Raw::Changed { path: path.into(), dir: false, structural: false }
    }

    #[test]
    fn a_change_belongs_to_the_innermost_worktree() {
        // The outer worktree sees the nested one as an untracked directory; crediting it with the
        // nested worktree's edits would put another checkout's files in its overlay.
        let mut st = state();
        st.route(&changed("/w/app/.worktrees/x/src/a.rs"));
        assert!(st.roots["/w/app/.worktrees/x".as_ref() as &Path].pending.paths.contains(Path::new("/w/app/.worktrees/x/src/a.rs")));
        assert!(st.roots["/w/app".as_ref() as &Path].pending.is_empty());
    }

    #[test]
    fn files_the_index_cannot_parse_are_not_remembered() {
        // A build writing thousands of files under target/ must cost no memory and no rescan.
        let mut st = state();
        for i in 0..10_000 {
            st.route(&changed(&format!("/w/app/target/debug/deps/x{i}.o")));
        }
        assert!(st.roots["/w/app".as_ref() as &Path].pending.is_empty());
    }

    #[test]
    fn git_internals_are_refs_not_file_changes() {
        let mut st = state();
        st.route(&changed("/w/app/.git/index"));
        st.route(&changed("/w/app/.git/objects/ab/cdef"));
        assert!(st.roots["/w/app".as_ref() as &Path].pending.is_empty());
        assert!(!st.repos["/w/app/.git".as_ref() as &Path].refs_dirty, "objects and index are not refs");
        st.route(&changed("/w/app/.git/refs/heads/main"));
        assert!(st.repos["/w/app/.git".as_ref() as &Path].refs_dirty);
    }

    #[test]
    fn a_cookie_is_consumed_wherever_it_lands() {
        let mut st = state();
        st.route(&changed("/w/app/.git/worktrees/x/fdindex-cookie-1-2"));
        assert!(st.seen_cookies.contains("fdindex-cookie-1-2"));
        assert!(!st.repos["/w/app/.git".as_ref() as &Path].refs_dirty, "a barrier is not a ref change");
    }

    #[test]
    fn lost_events_distrust_every_worktree() {
        let mut st = state();
        st.route(&Raw::Overflow);
        assert!(st.roots.values().all(|w| w.pending.rescan));
        assert!(st.repos.values().all(|r| r.refs_dirty));
    }

    #[test]
    fn a_coalesced_subtree_distrusts_only_its_worktree() {
        let mut st = state();
        st.route(&Raw::Rescan("/w/app/src".into()));
        assert!(st.roots["/w/app".as_ref() as &Path].pending.rescan);
        assert!(!st.roots["/w/app/.worktrees/x".as_ref() as &Path].pending.rescan);
    }

    #[test]
    fn a_bulk_change_degrades_to_a_rescan_instead_of_growing_without_bound() {
        let mut st = state();
        for i in 0..(MAX_PENDING_PATHS + 5) {
            st.route(&changed(&format!("/w/app/src/f{i}.rs")));
        }
        let p = &st.roots["/w/app".as_ref() as &Path].pending;
        assert!(p.rescan && p.paths.is_empty());
    }

    #[test]
    fn a_worktree_appearing_or_going_wakes_the_sweep() {
        let mut st = state();
        st.route(&Raw::Changed { path: "/w/app/.git/worktrees/y".into(), dir: true, structural: true });
        assert!(st.sweep_wanted);
        st.sweep_wanted = false;
        st.route(&changed("/w/app/.git/worktrees/x/gitdir")); // git rewriting its own bookkeeping
        assert!(!st.sweep_wanted);
    }
}
