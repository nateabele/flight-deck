//! Bring a cached view up to date from what a sweep found, without asking git about the whole
//! worktree.
//!
//! `git status` over a worktree costs 14 to 20 ms however little changed. Once a sweep has found
//! every change since the view was computed, only those paths need looking at:
//!
//! * a path the base tree has: read it and compare its blob with the base's (no process spawned);
//! * a path the base tree does not have: ask git, for that path only, whether it is a new file or
//!   an ignored one (see `git::status_of`);
//! * a directory that was created, moved or deleted: every path under it that the base tree or the
//!   overlay knows, plus whatever now exists beneath it.
//!
//! The result must equal what `git status` would have produced. `tests/refresh.rs` checks that
//! after a series of edits made by other processes.

use crate::error::Result;
use crate::git::{self, FileRef, Overlay, View};
use crate::lang;
use crate::sweep::Changes;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::Path;
use std::sync::Arc;

/// A walk that finds more indexable files than this under one new directory is a bulk operation
/// (an unpacked archive, a generator's output): one `git status` is cheaper than checking each.
const MAX_WALK_FILES: usize = 2000;

/// More paths git would have to be asked about than this is also cheaper as a full status.
const MAX_UNKNOWN: usize = 200;

/// The base tree by path, so "is this path in git?" is a lookup. Built once per commit.
pub struct BaseIndex {
    by_path: HashMap<String, FileRef>,
    pub commit: Option<String>,
}

impl BaseIndex {
    pub fn new(view: &View) -> BaseIndex {
        BaseIndex { by_path: view.base.iter().map(|f| (f.path.clone(), f.clone())).collect(), commit: view.label.base_commit.clone() }
    }

    pub fn contains(&self, path: &str) -> bool {
        self.by_path.contains_key(path)
    }
}

pub enum Refreshed {
    View(View),
    /// Too much changed, or something is not understood: the caller computes the view from
    /// `git status`.
    Rescan,
}

/// `prev` with `pending` applied. `pending.rescan` is the caller's to handle (it means "ask git");
/// this assumes it is not set.
pub fn refresh(prev: &View, index: &BaseIndex, pending: &Changes) -> Result<Refreshed> {
    let root = &prev.label.worktree;
    let rel = |p: &Path| -> Option<String> {
        let r = p.strip_prefix(root).ok()?;
        if r.components().next().is_some_and(|c| c.as_os_str() == ".git") {
            return None;
        }
        Some(r.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/"))
    };
    let mut overlay: BTreeMap<String, Overlay> = prev.overlay.iter().map(|o| (o.path().to_string(), o.clone())).collect();

    let mut candidates: BTreeSet<String> = pending.paths.iter().filter_map(|p| rel(p)).filter(|p| lang::for_path(Path::new(p)).is_some()).collect();
    for dir in &pending.subtrees {
        let Some(d) = rel(dir) else { continue };
        let prefix = format!("{d}/");
        candidates.extend(index.by_path.keys().filter(|p| p.starts_with(&prefix)).cloned());
        candidates.extend(overlay.keys().filter(|p| p.starts_with(&prefix)).cloned());
        // Whatever exists there now. `ignore` applies `.gitignore` while walking so a new
        // `node_modules/` is not enumerated; the exact answer for each new file still comes from git.
        if dir.is_dir() {
            let walker = ignore::WalkBuilder::new(dir).hidden(false).git_global(false).require_git(false).follow_links(false).filter_entry(|e| e.file_name() != ".git").build();
            let mut found = 0;
            for entry in walker.flatten() {
                if !entry.file_type().is_some_and(|t| t.is_file()) {
                    continue;
                }
                let Some(r) = rel(entry.path()) else { continue };
                if lang::for_path(Path::new(&r)).is_none() {
                    continue;
                }
                found += 1;
                if found > MAX_WALK_FILES {
                    return Ok(Refreshed::Rescan);
                }
                candidates.insert(r);
            }
        }
    }

    // Paths git must classify: present now, indexable, and not in the base tree.
    let mut unknown: Vec<(String, FileRef)> = Vec::new();
    for path in &candidates {
        let Some(language) = lang::for_path(Path::new(path)) else { continue };
        let now = git::read_overlay_file(root, path, language.id());
        match (index.by_path.get(path), now) {
            (Some(base), Some(f)) if f.blob_id == base.blob_id => {
                overlay.remove(path);
            }
            (Some(_), Some(f)) => {
                overlay.insert(path.clone(), Overlay::Present(f));
            }
            (Some(_), None) => {
                overlay.insert(path.clone(), Overlay::Deleted(path.clone()));
            }
            (None, Some(f)) => unknown.push((path.clone(), f)),
            (None, None) => {
                overlay.remove(path);
            }
        }
    }
    if unknown.len() > MAX_UNKNOWN {
        return Ok(Refreshed::Rescan);
    }
    if !unknown.is_empty() {
        let names: Vec<String> = unknown.iter().map(|(p, _)| p.clone()).collect();
        let listed = git::status_of(root, &names)?;
        for (path, f) in unknown {
            if listed.contains(&path) {
                overlay.insert(path, Overlay::Present(f));
            } else {
                overlay.remove(&path); // ignored, or inside a nested repository
            }
        }
    }

    let overlay: Vec<Overlay> = overlay.into_values().collect();
    // A change to a file the index does not parse never reaches this function, so whether the
    // checkout is dirty *only* through such files is carried over from the last full read: dirty
    // with an empty overlay then means exactly that.
    let carried = prev.label.dirty && prev.overlay.is_empty();
    let mut label = prev.label.clone();
    label.dirty = carried || !overlay.is_empty();
    Ok(Refreshed::View(View { label, base: Arc::clone(&prev.base), overlay }))
}
