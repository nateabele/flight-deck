//! Freshness by looking: what changed in a worktree since the last request, found by `stat`.
//!
//! This is the mechanism read-your-writes rests on. It replaced a file-event barrier after
//! measurement showed the barrier unsound (see "Why not events" below), and it is also cheaper:
//! about 1 to 2 ms on tessera (1.5k indexed files, 320 directories) against 10 ms for the barrier
//! and 14 to 20 ms for `git status`.
//!
//! ## What is compared
//!
//! * every indexed file the view knows (the base tree's and the overlay's): `(inode, size, mtime,
//!   ctime)` against what was seen last time. A write, an atomic replace (`sed -i`, an editor's
//!   save), a deletion, a `touch -t` (it moves ctime, which cannot be set) all change the tuple.
//! * every directory git would not ignore: a file created, removed or renamed inside moves the
//!   directory's mtime. Only a directory whose stat changed is read, and what is new in it is
//!   handed on as a candidate; what git decides about a candidate (ignored? nested repository?)
//!   is asked of git, for that path alone (`refresh`).
//! * the ignore files themselves (`.gitignore` anywhere, `info/exclude`, the global ignore): any
//!   change means what counts as ignored may have changed, and the worktree is read in full.
//!
//! ## Racy timestamps
//!
//! A stat that has not changed proves nothing if the file could have been written again within
//! the clock's resolution after it was taken (git calls this "racy git"; ext4's clock ticks every
//! few milliseconds). An entry whose ctime is within `RACY` of the moment it was observed is not
//! trusted: it is read again on the next sweep until it has aged past the window. This is also
//! what makes the order of "read the worktree" and "take the snapshot" irrelevant: an edit made
//! between the two has a ctime inside the window.
//!
//! ## Why not events
//!
//! The first version waited for FSEvents to report a *cookie* file written after the request
//! arrived, on the argument that one stream delivers in order. Over 115,000 external writes
//! under load it missed 4: an event for an edit made before the cookie was delivered after it.
//! In a trace, a `mv` that had finished before the cookie was created produced events whose ids
//! were *higher* than the cookie's own creation event, so the order the kernel (or fseventsd)
//! emitted them in is not the order the operations happened in, whatever the stream then
//! preserves. That is a one-in-30,000 chance of answering from a stale index after an edit,
//! which `stat` does not have. Events are still used for what they are good at (see `watch`):
//! noticing refs move, so a new commit can be prepared before the next question.

use crate::git::View;
use crate::lang;
use rayon::prelude::*;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

/// An entry changed this recently when it was observed is read again next time. Two seconds is
/// git's own margin on file systems with coarse timestamps.
const RACY_SECS: f64 = 2.0;

/// More candidates than this is a bulk operation (a checkout, a generator): one `git status`
/// beats asking about each path.
const MAX_CANDIDATES: usize = 4096;

#[derive(Clone, Copy, PartialEq, Debug)]
struct Stat {
    ino: u64,
    size: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
    /// Old enough that an unchanged stat means unchanged content.
    settled: bool,
}

fn stat(path: &Path, now: f64, racy: f64) -> Option<Stat> {
    let m = std::fs::symlink_metadata(path).ok()?;
    let ctime = m.ctime() as f64 + m.ctime_nsec() as f64 / 1e9;
    Some(Stat { ino: m.ino(), size: m.size(), mtime: (m.mtime(), m.mtime_nsec()), ctime: (m.ctime(), m.ctime_nsec()), settled: now - ctime > racy })
}

/// Did it change since `old` was recorded? An unsettled `new` counts as changed: it may change
/// again without the tuple showing it.
fn differs(old: Option<Stat>, new: Option<Stat>) -> bool {
    match (old, new) {
        (None, None) => false,
        (Some(o), Some(n)) => !n.settled || o.ino != n.ino || o.size != n.size || o.mtime != n.mtime || o.ctime != n.ctime,
        _ => true,
    }
}

fn ignore_hash(path: &Path) -> Option<String> {
    std::fs::read(path).ok().map(|b| crate::git::blob_id(&b))
}

fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// What a sweep found.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Changes {
    /// Absolute paths, in a language the index understands, that may differ from the view.
    pub paths: BTreeSet<PathBuf>,
    /// Directories that vanished: everything the view had under them is to be looked at.
    pub subtrees: BTreeSet<PathBuf>,
    /// The sweep cannot vouch for the view (an ignore file changed, a bulk change): read in full.
    pub rescan: bool,
}

impl Changes {
    pub fn is_empty(&self) -> bool {
        !self.rescan && self.paths.is_empty() && self.subtrees.is_empty()
    }
}

/// The stat of everything a worktree's view depends on, as of the last sweep.
pub struct Snapshot {
    root: PathBuf,
    /// Indexed files of the base tree and of the overlay, by path relative to the root.
    files: HashMap<String, Option<Stat>>,
    /// Directories git would not ignore ("" is the root).
    dirs: HashMap<String, Option<Stat>>,
    /// Ignore files by content: they are few and small, so they are read each sweep rather than
    /// trusted to a stat, which would send a worktree whose `.gitignore` is under two seconds old
    /// back to a full read on every request.
    ignores: Vec<(PathBuf, Option<String>)>,
    /// New indexed files git said it ignores: not asked about again until an ignore file changes
    /// (which discards the snapshot).
    known_ignored: HashSet<String>,
    /// The racy window, in seconds.
    racy: f64,
}

/// Directories (relative, root included), indexed files and ignore files under the worktree, the
/// way git would see them. `only` limits the walk to that directory and its subtree (the chain
/// of ancestors is still visited, so their ignore files apply).
fn walk(root: &Path, only: Option<&Path>) -> (Vec<String>, Vec<String>, Vec<PathBuf>) {
    let only = only.map(Path::to_path_buf);
    let walk_root = root.to_path_buf();
    let walker = ignore::WalkBuilder::new(root)
        .hidden(false)
        // Ignore files above the worktree are not git's business and must not hide anything.
        .parents(false)
        .git_global(true)
        .git_exclude(true)
        .require_git(false)
        .follow_links(false)
        .filter_entry(move |e| {
            let p = e.path();
            if e.file_name() == ".git" {
                return false;
            }
            let is_dir = e.file_type().is_some_and(|t| t.is_dir());
            // A directory with its own `.git` is another repository (a nested clone, a linked
            // worktree kept inside this one): its files belong to its own view.
            if is_dir && p != walk_root && p.join(".git").exists() {
                return false;
            }
            match &only {
                Some(o) if is_dir => p.starts_with(o) || o.starts_with(p),
                Some(o) => p.starts_with(o),
                None => true,
            }
        })
        .build();
    let (mut dirs, mut files, mut ignores) = (Vec::new(), Vec::new(), Vec::new());
    for e in walker.flatten() {
        let Ok(rel) = e.path().strip_prefix(root) else { continue };
        let rel = rel.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
        match e.file_type() {
            Some(t) if t.is_dir() => dirs.push(rel),
            Some(t) if t.is_file() || t.is_symlink() => {
                if e.file_name() == ".gitignore" {
                    ignores.push(e.path().to_path_buf());
                }
                if lang::for_path(Path::new(&rel)).is_some() {
                    files.push(rel);
                }
            }
            _ => {}
        }
    }
    (dirs, files, ignores)
}

/// Files whose change alters what git ignores, other than `.gitignore` files in the worktree.
fn fixed_ignores(common: &Path) -> Vec<PathBuf> {
    let mut v = vec![common.join("info/exclude")];
    let home = std::env::var_os("HOME").map(PathBuf::from);
    if let Some(c) = std::env::var_os("XDG_CONFIG_HOME").filter(|x| !x.is_empty()).map(PathBuf::from).or_else(|| home.map(|h| h.join(".config"))) {
        v.push(c.join("git/ignore"));
    }
    v
}

impl Snapshot {
    /// Look at everything `view` depends on. Call it right after the view was computed: whatever
    /// changes in between is inside the racy window and read again.
    pub fn take(view: &View, common: &Path) -> Snapshot {
        Self::take_with_window(view, common, RACY_SECS)
    }

    /// `take` with another racy window. Tests pass zero, which makes every entry count as
    /// settled at once, so what they exercise is the comparison itself and not the
    /// "unsettled entries are always read again" rule that would otherwise mask it.
    pub fn take_with_window(view: &View, common: &Path, racy_secs: f64) -> Snapshot {
        let racy = racy_secs;
        let root = view.label.worktree.clone();
        let t = now();
        let (dirs, _, gitignores) = walk(&root, None);
        let mut paths: BTreeSet<String> = view.base.iter().map(|f| f.path.clone()).collect();
        paths.extend(view.overlay.iter().filter(|o| matches!(o, crate::git::Overlay::Present(_))).map(|o| o.path().to_string()));
        let files = paths.into_par_iter().map(|p| (root.join(&p), p)).map(|(abs, p)| (p, stat(&abs, t, racy))).collect();
        let dirs = dirs.into_iter().map(|d| (stat(&root.join(&d), t, racy), d)).map(|(s, d)| (d, s)).collect();
        let ignores = gitignores.into_iter().chain(fixed_ignores(common)).map(|p| (ignore_hash(&p), p)).map(|(h, p)| (p, h)).collect();
        Snapshot { root, files, dirs, ignores, known_ignored: HashSet::new(), racy }
    }

    /// What changed since the last sweep. Records the new stats first, so a path that changes
    /// again while it is being read is seen as changed by the next sweep.
    pub fn check(&mut self) -> Changes {
        let t = now();
        let mut out = Changes::default();

        for (p, old) in &mut self.ignores {
            let new = ignore_hash(p);
            if *old != new {
                out.rescan = true;
            }
            *old = new;
        }
        if out.rescan {
            return out;
        }

        let (root, racy) = (self.root.clone(), self.racy);
        let changed: Vec<(String, Option<Stat>)> = self
            .files
            .par_iter()
            .filter_map(|(p, old)| {
                let new = stat(&root.join(p), t, racy);
                differs(*old, new).then(|| (p.clone(), new))
            })
            .collect();
        for (p, new) in changed {
            out.paths.insert(root.join(&p));
            self.files.insert(p, new);
        }

        let changed_dirs: Vec<(String, Option<Stat>)> = self
            .dirs
            .par_iter()
            .filter_map(|(d, old)| {
                let new = stat(&root.join(d), t, racy);
                differs(*old, new).then(|| (d.clone(), new))
            })
            .collect();
        let mut new_dirs: Vec<String> = Vec::new();
        for (d, new) in changed_dirs {
            let abs = root.join(&d);
            if new.is_none() {
                // Gone: it and everything below it.
                let prefix = format!("{d}/");
                self.dirs.retain(|k, _| *k != d && !k.starts_with(&prefix));
                out.subtrees.insert(abs);
                continue;
            }
            self.dirs.insert(d.clone(), new);
            let Ok(rd) = std::fs::read_dir(&abs) else { continue };
            for entry in rd.flatten() {
                let name = entry.file_name().to_string_lossy().to_string();
                let rel = if d.is_empty() { name.clone() } else { format!("{d}/{name}") };
                let Ok(ft) = entry.file_type() else { continue };
                if ft.is_dir() {
                    if name != ".git" && !self.dirs.contains_key(&rel) {
                        new_dirs.push(rel);
                    }
                } else if lang::for_path(Path::new(&rel)).is_some() && !self.files.contains_key(&rel) && !self.known_ignored.contains(&rel) {
                    self.files.insert(rel.clone(), stat(&root.join(&rel), t, racy));
                    out.paths.insert(root.join(&rel));
                }
            }
        }
        // A directory that appeared (or was moved in): its subdirectories and what is in them.
        let mut seen: HashSet<String> = HashSet::new();
        for d in new_dirs {
            if !seen.insert(d.clone()) || self.dirs.contains_key(&d) {
                continue;
            }
            let (dirs, files, ignores) = walk(&root, Some(&root.join(&d)));
            for sub in dirs {
                self.dirs.entry(sub.clone()).or_insert_with(|| stat(&root.join(&sub), t, racy));
            }
            for f in files {
                if !self.files.contains_key(&f) && !self.known_ignored.contains(&f) {
                    self.files.insert(f.clone(), stat(&root.join(&f), t, racy));
                    out.paths.insert(root.join(&f));
                }
            }
            for i in ignores {
                // A `.gitignore` arrived with the directory: what is ignored may have changed.
                if !self.ignores.iter().any(|(p, _)| *p == i) {
                    out.rescan = true;
                }
            }
        }
        if out.paths.len() + out.subtrees.len() > MAX_CANDIDATES {
            out.rescan = true;
        }
        out
    }

    /// After `refresh` has decided what the view now holds: a candidate that is neither in the
    /// base tree nor in the overlay is not part of the view (git ignores it, or it is gone), so it
    /// leaves the snapshot, and one that still exists is remembered as ignored.
    pub fn settle(&mut self, view: &View, in_base: &dyn Fn(&str) -> bool, changes: &Changes) {
        let present: HashSet<&str> = view.overlay.iter().filter(|o| matches!(o, crate::git::Overlay::Present(_))).map(|o| o.path()).collect();
        for abs in &changes.paths {
            let Ok(rel) = abs.strip_prefix(&self.root) else { continue };
            let rel = rel.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
            if in_base(&rel) || present.contains(rel.as_str()) {
                continue;
            }
            if self.files.remove(&rel).flatten().is_some() {
                self.known_ignored.insert(rel);
            }
        }
    }

    pub fn counts(&self) -> (usize, usize) {
        (self.files.len(), self.dirs.len())
    }
}
