//! `grep search_bodies=true worktrees=all|[paths]`: which worktrees, and which of their files, a
//! multi-worktree body search reads. The reading and matching are `tools::multigrep`.
//!
//! The question is how current each worktree's file list has to be, and what that costs. Asking
//! `git status` of every worktree, which is what a single-view request does for its one view, was
//! measured at 1.3-1.5 s for the 85 tessera worktrees (8 or 18 at a time, load 20-25): more than
//! the whole search is allowed to take. So a worktree is refreshed from git only when there is a
//! reason to think its recorded state is out of date:
//!
//! - It is the caller's own worktree, or has a view kept between requests (the watcher's stat
//!   sweep makes that a few milliseconds), or `refresh=true` asks for every worktree.
//! - The store has no row for it, its HEAD (read from the files git keeps, no process) is not the
//!   recorded one, or the store has no tree for that HEAD.
//! - A file of its recorded file list, or a directory holding one, was modified after the row was
//!   last written. Edits, deletions and new files in an existing directory all show here; a stat
//!   per path, in parallel, is all it costs.
//!
//! Every other worktree is answered from its recorded tree and overlay. The content read for each
//! blob is hashed against the blob id, so a file edited since is never passed off as the blob.
//!
//! No per-worktree read gate is held: this is a read-only snapshot, and holding 85 gates would make
//! a mutation in any of them wait for the whole search.

use super::{check_indexable, Readiness, Service};
use crate::git::{self, FileRef, Overlay, View};
use crate::lang;
use crate::tools::{self, args::Args, multigrep, ToolError};
use crate::trigram;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, UNIX_EPOCH};

const DEFAULT_LIMIT: usize = 200;

/// A refreshed worktree's view and whether its build is still running, or why it could not be read.
type Refreshed = std::result::Result<(View, bool), String>;

/// A worktree to search: root, base tree, overlay, and the base commit (keys the tree's ordinals).
type Found = (PathBuf, Arc<Vec<FileRef>>, Vec<Overlay>, Option<String>);

/// A worktree answered from the store: its HEAD, and when its row was last written.
struct Recorded {
    root: PathBuf,
    head: String,
    seen: i64,
}

impl Service {
    pub(super) fn grep_worktrees(self: &Arc<Self>, args: &Args, wait: Duration) -> std::result::Result<String, ToolError> {
        use rayon::prelude::*;
        if !args.flag(&["search_bodies"], false) {
            return Err(ToolError::bad("worktrees is only supported with search_bodies=true: a symbol-name grep already searches the linked views"));
        }
        let query = args.str(&["query", "pattern"]).ok_or_else(|| ToolError::bad("grep requires `query` (alias: pattern)"))?;
        let pattern = if args.flag(&["regex"], false) { query.clone() } else { regex::escape(&query) };
        let kind = match args.str(&["kind"]).map(|k| k.to_ascii_lowercase()) {
            None => None,
            Some(k) => {
                let k = if k == "type" { "type_alias".to_string() } else { k };
                Some(crate::facts::SymbolKind::parse(&k).ok_or_else(|| ToolError::bad(format!("unknown kind '{k}'")))?)
            }
        };
        let limit = args.num(&["limit"]).unwrap_or(DEFAULT_LIMIT);
        let (_, token_budget) = tools::common_params("grep", args)?;
        let wanted = args.list(&["worktrees"]);
        if wanted.is_empty() {
            return Err(ToolError::bad("worktrees takes `all` or a list of worktree paths"));
        }

        let located = git::locate(&args.cwd)?;
        check_indexable(&located, &args.cwd)?;
        if !located.is_git {
            return Err(ToolError::bad(format!("{} is not in a git repository, so it has no other worktrees", args.cwd.display())));
        }
        let started = std::time::Instant::now();
        let caller = self.view(&args.cwd)?;
        self.touch(&caller);
        let caller_building = match self.ensure_built(&caller, &[], false, Some(wait))? {
            Readiness::Ready => None,
            Readiness::Building { done, total } => Some((done, total)),
        };
        let repo = caller.label.repo.clone();
        let root = caller.label.worktree.clone();
        let reader = self.engine.reader(&repo)?;
        let caller_took = started.elapsed();
        let rows: HashMap<PathBuf, (Option<String>, i64)> = reader.worktree_rows()?.into_iter().map(|(p, h, s)| (p, (h, s))).collect();

        let mut skipped: Vec<(PathBuf, String)> = Vec::new();
        let mut targets: Vec<PathBuf> = if wanted.len() == 1 && wanted[0] == "all" {
            rows.keys().cloned().chain(std::iter::once(root.clone())).collect()
        } else {
            let mut t = Vec::new();
            for w in &wanted {
                let p = tools::args::resolve_path(&args.cwd, w);
                match git::locate(&p) {
                    Ok(l) if l.is_git => t.push(l.root),
                    _ => skipped.push((p, "not a git worktree".into())),
                }
            }
            t
        };
        targets.sort();
        targets.dedup();

        // Which worktrees git must be asked about, and which the store can answer for.
        let refresh_all = args.flag(&["refresh"], false);
        let mut to_refresh: Vec<PathBuf> = Vec::new();
        let mut recorded: Vec<Recorded> = Vec::new();
        for t in targets {
            if t == root {
                continue;
            }
            let Ok((gitdir, common)) = git::git_dirs(&t) else {
                skipped.push((t, "gone".into()));
                continue;
            };
            if common != repo {
                skipped.push((t, "another repository".into()));
                continue;
            }
            match rows.get(&t) {
                Some((Some(head), seen)) if !refresh_all && self.freshness.kept_info(&t).is_none() && git::read_head(&gitdir, &common).as_ref() == Some(head) => {
                    recorded.push(Recorded { root: t, head: head.clone(), seen: *seen })
                }
                _ => to_refresh.push(t),
            }
        }

        let mut trees: HashMap<String, Option<Arc<Vec<FileRef>>>> = HashMap::new();
        let mut from_store: Vec<(Recorded, Arc<Vec<FileRef>>, Vec<Overlay>)> = Vec::new();
        for r in recorded {
            let tree = match trees.get(&r.head) {
                Some(t) => t.clone(),
                None => {
                    let t = reader.get_tree(&r.head)?.map(Arc::new);
                    trees.insert(r.head.clone(), t.clone());
                    t
                }
            };
            match tree {
                Some(base) => {
                    let overlay = reader.get_overlay(&r.root)?;
                    from_store.push((r, base, overlay));
                }
                None => to_refresh.push(r.root),
            }
        }
        let loaded = std::time::Instant::now();
        let (current, stale): (Vec<_>, Vec<_>) = from_store.into_par_iter().partition(|(r, base, overlay)| !changed_since(&r.root, base, overlay, r.seen));
        to_refresh.extend(stale.iter().map(|(r, _, _)| r.root.clone()));

        let planned = std::time::Instant::now();
        let (stat_checked, refreshing) = (current.len() + stale.len(), to_refresh.len());
        // Views first, all at once; then the store is asked, here and not per view, which of them
        // need a build: a view on its recorded HEAD whose overlay blobs all have facts needs none,
        // and `ensure_built` would open a database connection per worktree to learn that.
        let viewed: Vec<(PathBuf, crate::error::Result<View>)> = to_refresh
            .into_par_iter()
            .map(|t| {
                let v = self.view(&t);
                if let Ok(v) = &v {
                    self.touch(v);
                }
                (t, v)
            })
            .collect();
        let viewed_took = planned.elapsed();
        let mut needs_build: Vec<bool> = Vec::with_capacity(viewed.len());
        for (t, v) in &viewed {
            let Ok(v) = v else {
                needs_build.push(false);
                continue;
            };
            let same_head = rows.get(t).is_some_and(|(h, _)| h.is_some() && *h == v.label.base_commit);
            let overlay_parsed = v.overlay.iter().all(|o| match o {
                Overlay::Present(f) => reader.has_facts(&f.blob_id, f.language, lang::by_id(f.language).map(|l| l.parser_version()).unwrap_or(0)).unwrap_or(false),
                Overlay::Deleted(_) => true,
            });
            needs_build.push(!(same_head && overlay_parsed));
        }
        let to_build = needs_build.iter().filter(|b| **b).count();
        let refreshed: Vec<(PathBuf, Refreshed)> = viewed
            .into_par_iter()
            .zip(needs_build)
            .map(|((t, v), build)| {
                let got = v.and_then(|v| {
                    let building = build && matches!(self.ensure_built(&v, &[], false, Some(wait))?, Readiness::Building { .. });
                    Ok((v, building))
                });
                (t, got.map_err(|e| e.to_string()))
            })
            .collect();
        let refreshed_count = refreshed.len();
        let refresh_took = planned.elapsed();

        let mut worktrees: Vec<Found> =
            vec![(root.clone(), caller.base.clone(), caller.overlay.clone(), caller.label.base_commit.clone())];
        worktrees.extend(current.into_iter().map(|(r, base, overlay)| (r.root, base, overlay, Some(r.head))));
        let mut building: Vec<PathBuf> = caller_building.map(|_| root.clone()).into_iter().collect();
        for (t, got) in refreshed {
            match got {
                Ok((v, b)) => {
                    if b {
                        building.push(t.clone());
                    }
                    let commit = v.label.base_commit.clone();
                    worktrees.push((t, v.base.clone(), v.overlay, commit));
                }
                Err(e) => skipped.push((t, e)),
            }
        }
        worktrees.sort_by(|a, b| a.0.cmp(&b.0));
        let roots: Vec<PathBuf> = worktrees.iter().map(|w| w.0.clone()).collect();
        let labels = multigrep::labels(&roots);
        // The trigram index: the plan, its candidates, and each tree's ordinals. A pattern the
        // planner cannot read plans to "every blob"; the matcher then reports the error.
        let tri_started = std::time::Instant::now();
        let tri = trigram::for_dir(&trigram::dir_for_db(reader.path()));
        let snap = tri.snapshot();
        let plan = trigram::plan(&pattern).unwrap_or(trigram::Query::All);
        let candidates = if snap.blobs() > 0 { snap.candidates(&plan) } else { None };
        let worktrees: Vec<multigrep::Worktree> = worktrees
            .into_iter()
            .zip(labels)
            .map(|((root, base, overlay, commit), label)| {
                let ords = (snap.blobs() > 0).then(|| tri.tree(&snap, commit.as_deref(), &base));
                multigrep::Worktree { root, label, base, overlay, ords }
            })
            .collect();
        let tri_took = tri_started.elapsed();

        let mut symbols = |id: &str, language: &'static str| {
            let v = lang::by_id(language).map(|l| l.parser_version()).unwrap_or(0);
            reader.get_symbols(id, language, v)
        };
        let out = multigrep::search(&worktrees, &pattern, kind, &root, candidates.as_ref(), &mut symbols)?;
        // Committed blobs the index lacks are indexed in the background, from the repository's
        // object store; this search has already read them.
        tri.enqueue(&repo, out.not_indexed.clone());
        // One line per search, so its cost can be read off a running daemon: where the time went
        // is what decides whether freshness or reading dominates on a given machine.
        super::log::info(&format!(
            "grep across {} worktrees: caller view {caller_took:?}, plan {:?} (store {:?}, stat {:?} for {stat_checked}), refresh {refresh_took:?} ({refreshing}: views {viewed_took:?}, {to_build} built), trigrams {tri_took:?} ({} of {} blobs indexed, {} candidates, {} ruled out, {} queued), scan {:?} ({} blobs, {} from git), facts {:?}, total {:?}",
            worktrees.len(),
            planned.duration_since(started) - caller_took,
            loaded.duration_since(started) - caller_took,
            planned.duration_since(loaded),
            snap.blobs(),
            snap.blobs() as usize + out.not_indexed.len(),
            candidates.as_ref().map(|c| c.len().to_string()).unwrap_or_else(|| "all".into()),
            out.ruled_out,
            out.not_indexed.len(),
            out.scan_took,
            out.blobs,
            out.from_git,
            out.facts_took,
            started.elapsed()
        ));

        let mut head = tools::header(&caller.label, caller.overlay.len(), caller_building);
        let mut summary = format!(
            "\nworktrees: {} searched (repo {}), {} distinct blob(s) scanned, {} refreshed from git",
            worktrees.len(),
            tools::repo_name(&caller.label),
            out.blobs,
            refreshed_count
        );
        if out.ruled_out > 0 {
            summary.push_str(&format!(", {} ruled out by the trigram index", out.ruled_out));
        }
        if out.from_git > 0 {
            summary.push_str(&format!(", {} read from git", out.from_git));
        }
        if out.unreadable > 0 {
            summary.push_str(&format!(", {} unreadable (changed again since recorded)", out.unreadable));
        }
        if !skipped.is_empty() {
            summary.push_str(&format!(", {} skipped", skipped.len()));
        }
        head.push_str(&summary);
        skipped.sort();
        for (p, why) in &skipped {
            head.push_str(&format!("\nskipped: {} ({why})", p.display()));
        }
        if !building.is_empty() {
            head.push_str(&format!("\nindex: building in {} worktree(s); hits in files not parsed yet are missing", building.len()));
        }
        if out.unindexed > 0 {
            head.push_str(&format!("\nnote: {} blob(s) with matching lines have no stored facts yet, so their lines are not placed in a body", out.unindexed));
        }
        let body = tools::truncate(multigrep::render(&worktrees, &out, &query, limit), token_budget);
        Ok(format!("{head}\n{body}"))
    }
}

fn parent(p: &str) -> &str {
    p.rsplit_once('/').map(|(d, _)| d).unwrap_or("")
}

/// Was anything of this worktree modified after its row was last written (`seen`, unix seconds)?
/// Every effective file, and every directory holding one or holding a deleted path, is looked at:
/// an edit or delete changes the file, a new file changes its directory. Strictly after: the row's
/// own second counts as covered, or a worktree recorded in the second it was edited would be
/// refreshed on every search, since a refresh that finds nothing new writes nothing.
fn changed_since(root: &Path, base: &[FileRef], overlay: &[Overlay], seen: i64) -> bool {
    use std::os::unix::fs::MetadataExt;
    let newer = |m: &std::fs::Metadata| {
        let mtime = m.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64).unwrap_or(i64::MAX);
        mtime.max(m.ctime()) > seen
    };
    let shadowed: HashSet<&str> = overlay.iter().map(|o| o.path()).collect();
    let mut dirs: HashSet<&str> = HashSet::from([""]);
    let files = base.iter().filter(|f| !shadowed.contains(f.path.as_str())).map(|f| f.path.as_str());
    let present = overlay.iter().filter_map(|o| if let Overlay::Present(f) = o { Some(f.path.as_str()) } else { None });
    for p in files.chain(present) {
        match std::fs::symlink_metadata(root.join(p)) {
            Ok(m) if !newer(&m) => {}
            _ => return true,
        }
        dirs.insert(parent(p));
    }
    for o in overlay {
        if let Overlay::Deleted(p) = o {
            dirs.insert(parent(p));
        }
    }
    dirs.into_iter().any(|d| std::fs::symlink_metadata(root.join(d)).map(|m| newer(&m)).unwrap_or(false))
}
