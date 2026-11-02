//! Leak-free seed sets for scoring `near` (graph-distance ordering), the inputs an agent's
//! default seed set (`Ctx::recent`: its diff plus the files it read last) would hold at the start
//! of a task.
//!
//! * [`author_files`]: the files the same author's previous `n` commits touched, reachable from
//!   the task's parent: a stand-in for "what the agent was just working on". Nothing of the task's
//!   own diff can leak, since every commit read is an ancestor of the task's parent.
//! * The open file (the task's first gold file) needs no git: the strategies hand it over and
//!   exclude it from scoring.

use std::path::Path;
use std::process::Command;

/// How far back (in non-merge commits from the parent) to look for the author's earlier work.
pub const AUTHOR_LOOKBACK: usize = 200;

fn git(root: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git").arg("-C").arg(root).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Files touched by the last `n` non-merge commits by `commit`'s author that are ancestors of
/// `parent` (the parent itself included), newest commit first, de-duplicated, relative to the
/// repository root. Empty when the author has no earlier commit within [`AUTHOR_LOOKBACK`].
pub fn author_files(root: &Path, commit: &str, parent: &str, n: usize) -> Vec<String> {
    let Some(email) = git(root, &["show", "-s", "--format=%ae", commit]).map(|s| s.trim().to_string()) else { return Vec::new() };
    let Some(log) = git(root, &["log", "--no-merges", "--format=%H %ae", &format!("-n{AUTHOR_LOOKBACK}"), parent]) else { return Vec::new() };
    let mut files: Vec<String> = Vec::new();
    for sha in log.lines().filter_map(|l| l.split_once(' ')).filter(|(_, e)| *e == email).map(|(h, _)| h).take(n) {
        let touched = git(root, &["diff-tree", "--no-commit-id", "--name-only", "-r", "--no-renames", "--root", sha]).unwrap_or_default();
        for f in touched.lines() {
            if !files.iter().any(|x| x == f) {
                files.push(f.to_string());
            }
        }
    }
    files
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(dir: &Path, args: &[&str], email: &str) -> String {
        let out = Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .env("GIT_AUTHOR_NAME", "a")
            .env("GIT_AUTHOR_EMAIL", email)
            .env("GIT_COMMITTER_NAME", "a")
            .env("GIT_COMMITTER_EMAIL", email)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn commit(dir: &Path, file: &str, email: &str) -> String {
        std::fs::write(dir.join(file), format!("{file} {email}\n{}", std::fs::read_to_string(dir.join(file)).unwrap_or_default())).unwrap();
        run(dir, &["add", file], email);
        run(dir, &["commit", "-q", "-m", file], email);
        run(dir, &["rev-parse", "HEAD"], email)
    }

    #[test]
    fn author_files_are_the_same_authors_earlier_commits_and_never_the_task_itself() {
        let d = tempfile::tempdir().unwrap();
        let dir = d.path();
        run(dir, &["init", "-q"], "me@x");
        commit(dir, "old.rs", "me@x");
        commit(dir, "mine.rs", "me@x");
        commit(dir, "theirs.rs", "you@x");
        let parent = commit(dir, "latest.rs", "me@x");
        let task = commit(dir, "gold.rs", "me@x");
        assert_eq!(author_files(dir, &task, &parent, 1), vec!["latest.rs"]);
        // Another author's commit in between is skipped, not counted.
        assert_eq!(author_files(dir, &task, &parent, 2), vec!["latest.rs", "mine.rs"]);
        assert_eq!(author_files(dir, &task, &parent, 3), vec!["latest.rs", "mine.rs", "old.rs"]);
        // The task's own files never appear: only ancestors of its parent are read.
        assert!(!author_files(dir, &task, &parent, 10).contains(&"gold.rs".to_string()));
        // An author with no earlier commit gets no seed.
        let theirs = commit(dir, "new.rs", "new@x");
        assert!(author_files(dir, &theirs, &task, 3).is_empty());
    }
}
