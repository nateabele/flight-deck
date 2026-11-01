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
//!
//! Besides the pair counts it keeps how many (non-mass) commits touched each file, so a partner
//! can be ranked by confidence `P(B changed | A changed) = together(A, B) / touches(A)` rather
//! than by raw count. Raw count favours partners of files that change all the time; confidence is
//! the measure Zimmermann et al.'s co-change rules (ICSE 2004) rank by. A commit that touches A
//! alone still counts towards `touches(A)`: leaving it out would inflate every confidence of a
//! file that is usually edited by itself.

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
    /// path -> how many scanned, non-mass commits touched it (alone or with others).
    touches: HashMap<String, u32>,
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
        Ok(CoChange::from_log(&String::from_utf8_lossy(&out.stdout)))
    }

    /// Build from `git log --name-only --pretty=format:%x01` output: one `\x01`-led chunk of file
    /// names per commit.
    pub fn from_log(text: &str) -> CoChange {
        let mut pairs: HashMap<(&str, &str), u32> = HashMap::new();
        let mut touches: HashMap<String, u32> = HashMap::new();
        let mut commits_scanned = 0;
        for chunk in text.split('\x01').filter(|c| !c.trim().is_empty()) {
            commits_scanned += 1;
            let mut files: Vec<&str> = chunk.lines().map(str::trim).filter(|l| !l.is_empty() && lang::for_path(Path::new(l)).is_some()).collect();
            if files.is_empty() || files.len() > MAX_FILES_PER_COMMIT {
                continue;
            }
            files.sort_unstable();
            files.dedup();
            for f in &files {
                *touches.entry((*f).to_string()).or_default() += 1;
            }
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
        CoChange { partners, touches, commits_scanned }
    }

    /// Partners of `path` that changed together in at least `min` commits, most often first.
    pub fn partners_of(&self, path: &str, min: u32) -> Vec<(&str, u32)> {
        self.partners.get(path).map(|v| v.iter().filter(|(_, n)| *n >= min).map(|(p, n)| (p.as_str(), *n)).collect()).unwrap_or_default()
    }

    /// How many scanned, non-mass commits touched `path`: the denominator of its confidences.
    pub fn touches(&self, path: &str) -> u32 {
        self.touches.get(path).copied().unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn log(commits: &[&[&str]]) -> String {
        commits.iter().map(|c| format!("\x01\n{}\n", c.join("\n"))).collect()
    }

    #[test]
    fn touches_count_every_commit_that_changed_a_file_including_solo_ones() {
        let co = CoChange::from_log(&log(&[&["a.rs", "b.rs"], &["a.rs"], &["a.rs", "c.rs"], &["README.md", "b.rs"]]));
        assert_eq!(co.touches("a.rs"), 3, "two pairs and one solo commit");
        assert_eq!(co.touches("b.rs"), 2, "a docs file beside it does not make the commit vanish");
        assert_eq!(co.touches("README.md"), 0, "files no language module handles are not counted");
        assert_eq!(co.partners_of("a.rs", 1), vec![("b.rs", 1), ("c.rs", 1)]);
    }

    #[test]
    fn a_mass_commit_counts_towards_nothing() {
        let many: Vec<String> = (0..=MAX_FILES_PER_COMMIT).map(|i| format!("f{i}.rs")).collect();
        let many: Vec<&str> = many.iter().map(String::as_str).collect();
        let co = CoChange::from_log(&log(&[&many, &["f0.rs", "f1.rs"]]));
        assert_eq!(co.touches("f0.rs"), 1);
        assert_eq!(co.partners_of("f0.rs", 1), vec![("f1.rs", 1)]);
    }
}
