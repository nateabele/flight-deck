//! Identity: repository, worktree, view.
//!
//! * **Repository** = the canonical `git rev-parse --git-common-dir`. Every worktree of a repo
//!   shares it, so all of them land in one store file and share parses.
//! * **Worktree** = the directory holding the nearest `.git` (a directory for a main checkout, a
//!   file for a linked worktree).
//! * **View** = the HEAD commit's tree plus an overlay of the paths whose working-tree content
//!   differs from it. A directory that is not in git is a repository with no commits whose whole
//!   content is overlay, with blob ids computed the way git computes them so content keying is
//!   uniform.
//!
//! We shell out to `git` rather than link libgit2: `ls-tree` hands over every path's blob id for
//! free, and `status` already encodes git's own ignore rules. `GIT_OPTIONAL_LOCKS=0` keeps our
//! `status` calls from taking `index.lock`, which would otherwise make an agent's concurrent
//! `git add` fail with "Unable to create index.lock".

use crate::error::{Error, Result};
use crate::lang;
use sha1::{Digest, Sha1};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Files above this are not parsed. Generated bundles and data dumps dominate parse time and
/// produce symbols nobody searches for.
pub const MAX_FILE_BYTES: u64 = 1_000_000;

/// Project manifests that mark the root of a directory that is not in git.
const ROOT_MARKERS: &[&str] =
    &["elm.json", "Cargo.toml", "package.json", "mix.exs", "Package.swift", "pyproject.toml"];

/// Where a view came from. Every query result carries one so an agent can tell which checkout
/// answered.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ViewLabel {
    /// The repository: its canonical git common dir, or the root directory for a non-git tree.
    pub repo: PathBuf,
    pub worktree: PathBuf,
    pub base_commit: Option<String>,
    pub dirty: bool,
    pub is_git: bool,
}

/// An indexable file in a view: path relative to the worktree (always `/`-separated).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRef {
    pub path: String,
    pub blob_id: String,
    pub language: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Overlay {
    /// Working-tree content that differs from (or is absent from) the base tree.
    Present(FileRef),
    /// Present in the base tree, gone (or too large to index) in the working tree.
    Deleted(String),
}

impl Overlay {
    pub fn path(&self) -> &str {
        match self {
            Overlay::Present(f) => &f.path,
            Overlay::Deleted(p) => p,
        }
    }
}

#[derive(Debug, Clone)]
pub struct View {
    pub label: ViewLabel,
    pub base: Vec<FileRef>,
    pub overlay: Vec<Overlay>,
}

impl View {
    /// The files a query sees: base tree with the overlay applied, sorted by path.
    pub fn files(&self) -> Vec<FileRef> {
        let mut by_path: HashMap<&str, &FileRef> = self.base.iter().map(|f| (f.path.as_str(), f)).collect();
        for o in &self.overlay {
            match o {
                Overlay::Present(f) => {
                    by_path.insert(&f.path, f);
                }
                Overlay::Deleted(p) => {
                    by_path.remove(p.as_str());
                }
            }
        }
        let mut out: Vec<FileRef> = by_path.into_values().cloned().collect();
        out.sort_by(|a, b| a.path.cmp(&b.path));
        out
    }

    pub fn abs(&self, rel: &str) -> PathBuf {
        self.label.worktree.join(rel)
    }
}

/// Git's blob object id: SHA-1 of `blob <len>\0<bytes>`.
pub fn blob_id(bytes: &[u8]) -> String {
    let mut h = Sha1::new();
    h.update(format!("blob {}\0", bytes.len()).as_bytes());
    h.update(bytes);
    hex(&h.finalize())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// A worktree found by walking up from some path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Located {
    pub root: PathBuf,
    pub is_git: bool,
    /// `.git` was a file: a linked worktree (or a submodule).
    pub linked: bool,
}

/// Walk up from `path` (which need not exist) to the nearest `.git`; failing that, to the nearest
/// project manifest; failing that, the path itself (its directory when it is a file).
pub fn locate(path: &Path) -> Result<Located> {
    let abs = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map_err(|e| Error::io(path, e))?.join(path)
    };
    // The path may name a file that does not exist yet (an agent about to create it), so start
    // from the closest ancestor that does.
    let mut start = abs.as_path();
    while !start.exists() {
        start = start.parent().ok_or_else(|| Error::Msg(format!("no existing ancestor of {}", abs.display())))?;
    }
    let start = start.canonicalize().map_err(|e| Error::io(start, e))?;
    let dir = if start.is_dir() { start.clone() } else { start.parent().unwrap_or(&start).to_path_buf() };

    for d in dir.ancestors() {
        let dot_git = d.join(".git");
        if let Ok(meta) = std::fs::symlink_metadata(&dot_git) {
            return Ok(Located { root: d.to_path_buf(), is_git: true, linked: meta.is_file() });
        }
    }
    for d in dir.ancestors() {
        if ROOT_MARKERS.iter().any(|m| d.join(m).is_file()) {
            return Ok(Located { root: d.to_path_buf(), is_git: false, linked: false });
        }
    }
    Ok(Located { root: dir, is_git: false, linked: false })
}

fn git(root: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let out = Command::new("git")
        .args(args)
        .current_dir(root)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .map_err(|e| Error::io(root, e))?;
    if out.status.success() {
        Ok(out.stdout)
    } else {
        Err(Error::Git {
            args: args.join(" "),
            message: String::from_utf8_lossy(&out.stderr).trim().to_string(),
        })
    }
}

/// Build the view for any absolute path.
pub fn view_for_path(path: &Path) -> Result<View> {
    let loc = locate(path)?;
    if loc.is_git { git_view(&loc.root) } else { plain_view(&loc.root) }
}

fn git_view(root: &Path) -> Result<View> {
    let common = git(root, &["rev-parse", "--git-common-dir"])?;
    let common = String::from_utf8_lossy(&common).trim().to_string();
    let common = root.join(common);
    let repo = common.canonicalize().map_err(|e| Error::io(&common, e))?;

    // A repository with no commits has no HEAD: everything is overlay.
    let base_commit = git(root, &["rev-parse", "--verify", "-q", "HEAD^{commit}"])
        .ok()
        .map(|o| String::from_utf8_lossy(&o).trim().to_string())
        .filter(|s| !s.is_empty());

    let base = match &base_commit {
        Some(_) => list_tree(root)?,
        None => Vec::new(),
    };
    let (overlay, dirty) = read_overlay(root)?;
    Ok(View {
        label: ViewLabel { repo, worktree: root.to_path_buf(), base_commit, dirty, is_git: true },
        base,
        overlay,
    })
}

/// `git ls-tree -r -z -l --full-tree HEAD`: `<mode> <type> <oid> <size>\t<path>` per entry.
///
/// Submodules (mode 160000) are skipped on purpose: a submodule is its own repository, found by
/// its own `.git`, and descending from the parent would index it twice under two identities.
/// Symlinks (120000) are skipped so a link pointing out of the tree can never pull foreign files
/// into this view.
fn list_tree(root: &Path) -> Result<Vec<FileRef>> {
    let out = git(root, &["ls-tree", "-r", "-z", "-l", "--full-tree", "HEAD"])?;
    let mut files = Vec::new();
    for rec in out.split(|b| *b == 0).filter(|r| !r.is_empty()) {
        let Some(tab) = rec.iter().position(|b| *b == b'\t') else { continue };
        let meta = String::from_utf8_lossy(&rec[..tab]);
        let path = String::from_utf8_lossy(&rec[tab + 1..]).to_string();
        let mut parts = meta.split_whitespace();
        let (mode, kind, oid, size) = (parts.next(), parts.next(), parts.next(), parts.next());
        let (Some(mode), Some("blob"), Some(oid), Some(size)) = (mode, kind, oid, size) else { continue };
        if mode == "120000" {
            continue;
        }
        let Some(language) = lang::for_path(Path::new(&path)) else { continue };
        if size.parse::<u64>().unwrap_or(u64::MAX) > MAX_FILE_BYTES {
            continue;
        }
        files.push(FileRef { path, blob_id: oid.to_string(), language: language.id() });
    }
    Ok(files)
}

/// `git status --porcelain=v2 -z --untracked-files=all` -> overlay of the working tree against HEAD.
fn read_overlay(root: &Path) -> Result<(Vec<Overlay>, bool)> {
    let out = git(root, &["status", "--porcelain=v2", "-z", "--untracked-files=all"])?;
    let mut recs = out.split(|b| *b == 0).filter(|r| !r.is_empty());
    let mut overlay = Vec::new();
    let mut dirty = false;
    while let Some(rec) = recs.next() {
        let line = String::from_utf8_lossy(rec).to_string();
        let mut deleted_origin: Option<String> = None;
        let path = match line.as_bytes()[0] {
            b'1' | b'2' | b'u' => {
                dirty = true;
                let n = match line.as_bytes()[0] {
                    b'1' => 9,
                    b'2' => 10,
                    _ => 11,
                };
                let fields: Vec<&str> = line.splitn(n, ' ').collect();
                // Field 3 is the submodule state: `S...` means this path is a submodule.
                if fields.get(2).is_some_and(|s| s.starts_with('S')) {
                    if line.as_bytes()[0] == b'2' {
                        recs.next();
                    }
                    continue;
                }
                if line.as_bytes()[0] == b'2' {
                    deleted_origin = recs.next().map(|r| String::from_utf8_lossy(r).to_string());
                }
                fields.last().map(|s| s.to_string()).unwrap_or_default()
            }
            b'?' => {
                dirty = true;
                line[2..].to_string()
            }
            _ => continue, // ignored files, headers
        };
        if let Some(orig) = deleted_origin {
            if lang::for_path(Path::new(&orig)).is_some() {
                overlay.push(Overlay::Deleted(orig));
            }
        }
        // `? dir/` is an untracked nested repository: its own view, not ours.
        if path.ends_with('/') {
            continue;
        }
        let Some(language) = lang::for_path(Path::new(&path)) else { continue };
        overlay.push(match read_overlay_file(root, &path, language.id()) {
            Some(f) => Overlay::Present(f),
            None => Overlay::Deleted(path),
        });
    }
    Ok((overlay, dirty))
}

/// Hash a working-tree file for the overlay; `None` when it is gone, a symlink, or too large.
fn read_overlay_file(root: &Path, rel: &str, language: &'static str) -> Option<FileRef> {
    let abs = root.join(rel);
    let meta = std::fs::symlink_metadata(&abs).ok()?;
    if !meta.is_file() || meta.len() > MAX_FILE_BYTES {
        return None;
    }
    let bytes = std::fs::read(&abs).ok()?;
    Some(FileRef { path: rel.to_string(), blob_id: blob_id(&bytes), language })
}

/// A directory with no git: no commits, all content is overlay. Walks respecting `.gitignore` if
/// one exists (the `ignore` crate reads it without requiring a repository).
fn plain_view(root: &Path) -> Result<View> {
    let walker = ignore::WalkBuilder::new(root)
        .follow_links(false)
        .require_git(false)
        .filter_entry(|e| e.file_name() != "node_modules")
        .build();
    let mut overlay = Vec::new();
    for entry in walker.flatten() {
        if !entry.file_type().is_some_and(|t| t.is_file()) {
            continue;
        }
        let Ok(rel) = entry.path().strip_prefix(root) else { continue };
        let rel = rel.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
        let Some(language) = lang::for_path(Path::new(&rel)) else { continue };
        if let Some(f) = read_overlay_file(root, &rel, language.id()) {
            overlay.push(Overlay::Present(f));
        }
    }
    overlay.sort_by(|a, b| a.path().cmp(b.path()));
    let dirty = !overlay.is_empty();
    Ok(View {
        label: ViewLabel { repo: root.to_path_buf(), worktree: root.to_path_buf(), base_commit: None, dirty, is_git: false },
        base: Vec::new(),
        overlay,
    })
}
