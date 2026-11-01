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
use std::sync::Arc;

/// Files above this are not parsed. Generated bundles and data dumps dominate parse time and
/// produce symbols nobody searches for.
pub const MAX_FILE_BYTES: u64 = 1_000_000;

/// Most files a directory outside git may hold before it is refused as an index root.
const MAX_PLAIN_FILES: usize = 100_000;

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
    /// Shared: every worktree on one commit holds the same listing, and the daemon keeps one copy.
    pub base: Arc<Vec<FileRef>>,
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

pub(crate) fn git(root: &Path, args: &[&str]) -> Result<Vec<u8>> {
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

/// The text of blob `id` (lossy UTF-8), or `None` if git cannot read it.
pub fn blob_text(root: &Path, id: &str) -> Option<String> {
    git(root, &["cat-file", "blob", id]).ok().map(|b| String::from_utf8_lossy(&b).into_owned())
}

/// Finds the file listing of `(repository, commit)` if the caller already holds one.
pub type KnownBase<'a> = dyn Fn(&Path, &str, &Path) -> Option<Arc<Vec<FileRef>>> + 'a;

/// Build the view for any absolute path.
pub fn view_for_path(path: &Path) -> Result<View> {
    view_for_path_with(path, &|_, _, _| None)
}

/// Like `view_for_path`, but `known_base(repo, commit, worktree)` may hand back a commit's file listing
/// already held, which skips the `ls-tree` over the whole repository. On a warm request what is
/// left is one `git status`, which is also what makes the overlay fresh.
pub fn view_for_path_with(path: &Path, known_base: &KnownBase) -> Result<View> {
    let loc = locate(path)?;
    if loc.is_git { git_view(&loc.root, known_base) } else { plain_view(&loc.root) }
}

/// The repository's common git dir, canonical. Read from the `.git` file of a linked worktree
/// (`gitdir: …/worktrees/x`, whose `commondir` points back at the repository) because spawning
/// `git rev-parse` just to learn this costs more than the rest of a warm request; any surprise in
/// those files falls back to asking git.
fn common_dir(root: &Path) -> Result<PathBuf> {
    let dot_git = root.join(".git");
    let quick = || -> Option<PathBuf> {
        if dot_git.is_dir() {
            return dot_git.canonicalize().ok();
        }
        let text = std::fs::read_to_string(&dot_git).ok()?;
        let gitdir = root.join(text.trim().strip_prefix("gitdir:")?.trim());
        let common = std::fs::read_to_string(gitdir.join("commondir")).ok()?;
        gitdir.join(common.trim()).canonicalize().ok()
    };
    if let Some(c) = quick() {
        return Ok(c);
    }
    let out = git(root, &["rev-parse", "--git-common-dir"])?;
    let common = root.join(String::from_utf8_lossy(&out).trim());
    common.canonicalize().map_err(|e| Error::io(&common, e))
}

fn git_view(root: &Path, known_base: &KnownBase) -> Result<View> {
    let repo = common_dir(root)?;
    // One `status` yields both the overlay and the commit it is relative to, so the two cannot
    // disagree if HEAD moves between two commands.
    let (overlay, dirty, base_commit) = read_overlay(root)?;
    let base = match &base_commit {
        Some(c) => match known_base(&repo, c, root) {
            Some(b) => b,
            None => Arc::new(list_tree(root, c)?),
        },
        None => Arc::new(Vec::new()),
    };
    Ok(View { label: ViewLabel { repo, worktree: root.to_path_buf(), base_commit, dirty, is_git: true }, base, overlay })
}

/// `git ls-tree -r -z -l --full-tree <commit>`: `<mode> <type> <oid> <size>\t<path>` per entry.
///
/// Submodules (mode 160000) are skipped on purpose: a submodule is its own repository, found by
/// its own `.git`, and descending from the parent would index it twice under two identities.
/// Symlinks (120000) are skipped so a link pointing out of the tree can never pull foreign files
/// into this view.
pub fn list_tree(root: &Path, commit: &str) -> Result<Vec<FileRef>> {
    let out = git(root, &["ls-tree", "-r", "-z", "-l", "--full-tree", commit])?;
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

/// `git status --porcelain=v2 --branch -z --untracked-files=all` -> overlay of the working tree
/// against HEAD, whether it is dirty, and HEAD's commit (`None` before the first commit).
fn read_overlay(root: &Path) -> Result<(Vec<Overlay>, bool, Option<String>)> {
    let out = git(root, &["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])?;
    let mut head: Option<String> = None;
    let mut recs = out.split(|b| *b == 0).filter(|r| !r.is_empty());
    let mut overlay = Vec::new();
    let mut dirty = false;
    while let Some(rec) = recs.next() {
        let line = String::from_utf8_lossy(rec).to_string();
        if let Some(oid) = line.strip_prefix("# branch.oid ") {
            head = Some(oid.to_string()).filter(|o| o != "(initial)");
            continue;
        }
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
        if let Some(orig) = deleted_origin
            && lang::for_path(Path::new(&orig)).is_some() {
                overlay.push(Overlay::Deleted(orig));
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
    Ok((overlay, dirty, head))
}

/// Hash a working-tree file for the overlay; `None` when it is gone, a symlink, or too large.
pub fn read_overlay_file(root: &Path, rel: &str, language: &'static str) -> Option<FileRef> {
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
    let mut walked = 0usize;
    for entry in walker.flatten() {
        if !entry.file_type().is_some_and(|t| t.is_file()) {
            continue;
        }
        // A manifest in a home directory or a data dump would otherwise make a request read
        // hundreds of thousands of files; a real project outside git is nowhere near this.
        walked += 1;
        if walked > MAX_PLAIN_FILES {
            return Err(Error::Msg(format!("{} has more than {MAX_PLAIN_FILES} files and is not a git repository: not indexing it", root.display())));
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
        base: Arc::new(Vec::new()),
        overlay,
    })
}

/// A worktree's git dir (where its `HEAD` lives) and its repository's common dir, both canonical.
/// For a main checkout they are the same directory.
pub fn git_dirs(root: &Path) -> Result<(PathBuf, PathBuf)> {
    let common = common_dir(root)?;
    let dot_git = root.join(".git");
    if dot_git.is_dir() {
        return Ok((common.clone(), common));
    }
    let text = std::fs::read_to_string(&dot_git).map_err(|e| Error::io(&dot_git, e))?;
    let gitdir = root.join(text.trim().strip_prefix("gitdir:").unwrap_or("").trim());
    let gitdir = gitdir.canonicalize().map_err(|e| Error::io(&gitdir, e))?;
    Ok((gitdir, common))
}

/// HEAD's commit, read from the files git keeps instead of asking git: a warm request compares it
/// with the commit its cached view was built on, and spawning a process for that would cost more
/// than the rest of the request. `None` when it cannot be resolved this way (unborn branch,
/// reftable, a file mid-write); the caller then re-reads the worktree with `git status`, which is
/// slower and always right.
pub fn read_head(gitdir: &Path, common: &Path) -> Option<String> {
    let head = std::fs::read_to_string(gitdir.join("HEAD")).ok()?;
    let head = head.trim();
    let Some(name) = head.strip_prefix("ref:").map(str::trim) else {
        return (head.len() == 40 && head.bytes().all(|b| b.is_ascii_hexdigit())).then(|| head.to_string());
    };
    // A branch's loose ref wins over the packed one, as in git.
    if let Ok(v) = std::fs::read_to_string(common.join(name)) {
        let v = v.trim();
        return (v.len() == 40).then(|| v.to_string());
    }
    let packed = std::fs::read_to_string(common.join("packed-refs")).ok()?;
    packed.lines().filter(|l| !l.starts_with('#') && !l.starts_with('^')).find_map(|l| {
        let (oid, r) = l.split_once(' ')?;
        (r == name && oid.len() == 40).then(|| oid.to_string())
    })
}

/// What `git status` lists, among exactly `paths`, as present and not ignored: untracked, added,
/// modified. For paths the base tree does not have, git is the authority on whether a file is
/// ignored (nested `.gitignore`, `info/exclude`, global excludes, nested repositories), and
/// re-implementing that would put an ignored build artefact in the overlay or leave a real new
/// file out of it. Costs one process, so it is only asked about paths that are new.
pub fn status_of(root: &Path, paths: &[String]) -> Result<std::collections::HashSet<String>> {
    let mut cmd = Command::new("git");
    cmd.args(["status", "--porcelain=v2", "-z", "--untracked-files=all", "--"])
        .args(paths)
        .current_dir(root)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_LITERAL_PATHSPECS", "1");
    let out = cmd.output().map_err(|e| Error::io(root, e))?;
    if !out.status.success() {
        return Err(Error::Git { args: "status -- <paths>".into(), message: String::from_utf8_lossy(&out.stderr).trim().to_string() });
    }
    let mut listed = std::collections::HashSet::new();
    let mut recs = out.stdout.split(|b| *b == 0).filter(|r| !r.is_empty());
    while let Some(rec) = recs.next() {
        let line = String::from_utf8_lossy(rec);
        match line.as_bytes()[0] {
            b'?' => {
                listed.insert(line[2..].to_string());
            }
            b'1' | b'u' => {
                let n = if line.as_bytes()[0] == b'1' { 9 } else { 11 };
                if let Some(p) = line.splitn(n, ' ').last() {
                    listed.insert(p.to_string());
                }
            }
            b'2' => {
                if let Some(p) = line.splitn(10, ' ').last() {
                    listed.insert(p.to_string());
                }
                recs.next(); // the rename's origin path
            }
            _ => {}
        }
    }
    Ok(listed)
}

/// The listing of `new_commit` derived from the listing of `old_commit` and the diff between
/// them, instead of listing the whole tree again: after a commit or a checkout a few files
/// differ, and `git diff-tree` of those costs a fraction of `ls-tree` over every file. `None`
/// when the diff is too large for this to be the cheaper way (the caller lists the tree).
pub fn derive_listing(root: &Path, old: &[FileRef], old_commit: &str, new_commit: &str) -> Result<Option<Vec<FileRef>>> {
    const MAX_DIFF: usize = 5000;
    let out = git(root, &["diff-tree", "-r", "-z", "--raw", "--no-renames", "--no-abbrev", old_commit, new_commit])?;
    let mut recs = out.split(|b| *b == 0).filter(|r| !r.is_empty());
    let mut files: HashMap<String, FileRef> = old.iter().map(|f| (f.path.clone(), f.clone())).collect();
    // (path, blob, language) of entries that need their size looked up before they may join.
    let mut added: Vec<(String, String, &'static str)> = Vec::new();
    let mut n = 0;
    while let Some(meta) = recs.next() {
        let Some(path) = recs.next() else { break };
        n += 1;
        if n > MAX_DIFF {
            return Ok(None);
        }
        let meta = String::from_utf8_lossy(meta);
        let path = String::from_utf8_lossy(path).to_string();
        // `:<old mode> <new mode> <old oid> <new oid> <status>`
        let f: Vec<&str> = meta.trim_start_matches(':').split(' ').collect();
        let (Some(new_mode), Some(new_oid)) = (f.get(1), f.get(3)) else { continue };
        files.remove(&path);
        if matches!(*new_mode, "100644" | "100755")
            && let Some(language) = lang::for_path(Path::new(&path))
        {
            added.push((path, new_oid.to_string(), language.id()));
        }
    }
    if !added.is_empty() {
        let input: String = added.iter().map(|(_, oid, _)| format!("{oid}\n")).collect();
        let mut child = Command::new("git")
            .args(["cat-file", "--batch-check=%(objecttype) %(objectsize)"])
            .current_dir(root)
            .env("GIT_OPTIONAL_LOCKS", "0")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|e| Error::io(root, e))?;
        let mut stdin = child.stdin.take().expect("piped");
        let writer = std::thread::spawn(move || {
            use std::io::Write;
            let _ = stdin.write_all(input.as_bytes());
        });
        let mut sizes = String::new();
        {
            use std::io::Read;
            let _ = child.stdout.take().expect("piped").read_to_string(&mut sizes);
        }
        let _ = writer.join();
        let _ = child.wait();
        for ((path, oid, language), line) in added.into_iter().zip(sizes.lines()) {
            let mut p = line.split(' ');
            if p.next() == Some("blob") && p.next().and_then(|s| s.parse::<u64>().ok()).is_some_and(|sz| sz <= MAX_FILE_BYTES) {
                files.insert(path.clone(), FileRef { path, blob_id: oid, language });
            }
        }
    }
    let mut out: Vec<FileRef> = files.into_values().collect();
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(Some(out))
}

/// `(refname, commit)` for every branch head of a repository, from its common dir.
pub fn branch_heads(common: &Path) -> Result<Vec<(String, String)>> {
    let out = Command::new("git")
        .arg("--git-dir")
        .arg(common)
        .args(["for-each-ref", "--format=%(refname) %(objectname)", "refs/heads"])
        // git reads its working directory before it looks at `--git-dir`, and fails outright when
        // that directory was deleted. The daemon inherits its starter's, which is often a worktree
        // that is later removed; without this every collection skipped its repository.
        .current_dir(common)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .output()
        .map_err(|e| Error::io(common, e))?;
    if !out.status.success() {
        return Err(Error::Git { args: "for-each-ref refs/heads".into(), message: String::from_utf8_lossy(&out.stderr).trim().to_string() });
    }
    Ok(String::from_utf8_lossy(&out.stdout).lines().filter_map(|l| l.split_once(' ')).map(|(n, c)| (n.to_string(), c.to_string())).collect())
}
