#![allow(dead_code)]
//! Temp-repo helpers shared by the integration tests.

use std::path::{Path, PathBuf};
use std::process::Command;
use tempfile::TempDir;

pub fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

pub fn write(root: &Path, rel: &str, content: &str) {
    let p = root.join(rel);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, content).unwrap();
}

/// An initialised repo (no commits) in a temp dir. The dir path is canonicalised: macOS temp dirs
/// live behind the `/var` -> `/private/var` symlink and identity compares canonical paths.
pub struct Repo {
    pub dir: TempDir,
    pub root: PathBuf,
}

pub fn init_repo() -> Repo {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    git(&root, &["init", "-q", "-b", "main"]);
    Repo { dir, root }
}

pub fn commit_all(root: &Path, msg: &str) -> String {
    git(root, &["add", "-A"]);
    git(root, &["commit", "-q", "-m", msg]);
    git(root, &["rev-parse", "HEAD"])
}

pub const ELM_A: &str = "module A exposing (a)\n\nimport B\n\na : Int\na =\n    B.b\n";
pub const ELM_B: &str = "module B exposing (b)\n\nb : Int\nb =\n    1\n";
