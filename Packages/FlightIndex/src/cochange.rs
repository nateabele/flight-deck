//! Files that change together, from git history.
//!
//! Co-change is a property of a repository's history, not of one worktree's content, so it is
//! computed per repository at a commit (the daemon caches one per repo and recomputes when HEAD
//! moves) and then filtered to the files of the view being asked about.
//!
//! Two filters keep it meaningful and cheap. A commit touching more than `MAX_FILES_PER_COMMIT`
//! files is a rename, a format run or a vendor import: it relates everything to everything and
//! costs files² pairs, so it is skipped. Only files a language module handles are counted, which
//! keeps lockfiles and docs from crowding out the partners an edit actually implies.

use crate::error::{Error, Result};
use crate::lang;
use std::collections::HashMap;
use std::path::Path;
use std::process::Command;

pub const MAX_COMMITS: usize = 2000;
const MAX_FILES_PER_COMMIT: usize = 40;

#[derive(Debug, Default)]
pub struct CoChange {
    /// path (worktree-relative) -> partners with how many commits touched both, most first.
    partners: HashMap<String, Vec<(String, u32)>>,
    pub commits_scanned: usize,
}

impl CoChange {
    /// Scan the last `MAX_COMMITS` non-merge commits reachable from `commit`.
    pub fn compute(worktree: &Path, commit: &str) -> Result<CoChange> {
        let out = Command::new("git")
            .args(["log", "-n", &MAX_COMMITS.to_string(), "--no-merges", "--no-renames", "--name-only", "--pretty=format:%x01", commit])
            .current_dir(worktree)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .output()
            .map_err(|e| Error::io(worktree, e))?;
        if !out.status.success() {
            return Err(Error::Git { args: "log --name-only".into(), message: String::from_utf8_lossy(&out.stderr).trim().to_string() });
        }
        let text = String::from_utf8_lossy(&out.stdout);
        let mut pairs: HashMap<(&str, &str), u32> = HashMap::new();
        let mut commits_scanned = 0;
        for chunk in text.split('\x01').filter(|c| !c.trim().is_empty()) {
            commits_scanned += 1;
            let mut files: Vec<&str> = chunk.lines().map(str::trim).filter(|l| !l.is_empty() && lang::for_path(Path::new(l)).is_some()).collect();
            if files.len() < 2 || files.len() > MAX_FILES_PER_COMMIT {
                continue;
            }
            files.sort_unstable();
            files.dedup();
            for (i, a) in files.iter().enumerate() {
                for b in &files[i + 1..] {
                    *pairs.entry((a, b)).or_default() += 1;
                }
            }
        }
        let mut partners: HashMap<String, Vec<(String, u32)>> = HashMap::new();
        for ((a, b), n) in pairs {
            partners.entry(a.to_string()).or_default().push((b.to_string(), n));
            partners.entry(b.to_string()).or_default().push((a.to_string(), n));
        }
        for v in partners.values_mut() {
            v.sort_by(|x, y| y.1.cmp(&x.1).then(x.0.cmp(&y.0)));
        }
        Ok(CoChange { partners, commits_scanned })
    }

    /// Partners of `path` that changed together in at least `min` commits, most often first.
    pub fn partners_of(&self, path: &str, min: u32) -> Vec<(&str, u32)> {
        self.partners.get(path).map(|v| v.iter().filter(|(_, n)| *n >= min).map(|(p, n)| (p.as_str(), *n)).collect()).unwrap_or_default()
    }
}
