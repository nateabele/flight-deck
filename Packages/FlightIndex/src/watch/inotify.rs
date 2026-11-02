//! Linux: one inotify instance over the ref directories of every known repository.
//!
//! inotify watches one directory, not a subtree, so each repository costs a watch per directory
//! that can hold a ref the watcher acts on (`watch::ref_dir`): the common dir (`HEAD`,
//! `packed-refs`), `refs`, every directory under `refs/heads`, `worktrees` and each
//! `worktrees/<name>` (a linked worktree's `HEAD`). `refs/tags` and `refs/remotes` are not
//! watched: nothing the watcher does reads them, and a fetch would otherwise wake it for each.
//! A directory created under a watched one (`git branch feature/x` makes `refs/heads/feature`) is
//! watched as soon as its creation is read, and reported as a change, which covers a ref written
//! into it before the watch existed.
//!
//! The watches are bounded: at most `PER_REPO` per repository and `TOTAL` (or a quarter of the
//! kernel's `max_user_watches`, whichever is smaller) altogether, so a repository with thousands of
//! branch folders cannot exhaust a limit other programs share. A directory left unwatched by the
//! bound costs a late warm-up for refs inside it, never a wrong answer: every request reads HEAD
//! itself, and collection reads the branch heads again.
//!
//! Replacing the path set adds and removes watches by difference, so a directory watched before
//! and after is never unwatched in between. One thread reads the descriptor, waiting in `poll`
//! on it and on an `eventfd` that dropping the backend signals.

use super::{Backend, Raw, Sink, ref_dir};
use std::collections::{BTreeSet, HashMap};
use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const PER_REPO: usize = 256;
const TOTAL: usize = 8192;

const MASK: u32 = libc::IN_CREATE | libc::IN_MOVED_TO | libc::IN_MOVED_FROM | libc::IN_DELETE | libc::IN_CLOSE_WRITE | libc::IN_ONLYDIR | libc::IN_DONT_FOLLOW;

#[derive(Default)]
struct Watches {
    by_wd: HashMap<i32, PathBuf>,
    by_path: HashMap<PathBuf, i32>,
    /// The common dirs being watched, and how many watches each holds.
    roots: HashMap<PathBuf, usize>,
    limit: usize,
    /// Logged once, the first time the bound leaves a directory unwatched.
    bounded: bool,
}

struct Inner {
    fd: OwnedFd,
    stop: OwnedFd,
    watches: Mutex<Watches>,
    sink: Sink,
}

pub(crate) struct Inotify {
    inner: Arc<Inner>,
}

fn cvt(rc: libc::c_int) -> io::Result<libc::c_int> {
    if rc < 0 { Err(io::Error::last_os_error()) } else { Ok(rc) }
}

fn kernel_limit() -> usize {
    std::fs::read_to_string("/proc/sys/fs/inotify/max_user_watches").ok().and_then(|s| s.trim().parse::<usize>().ok()).map_or(TOTAL, |n| (n / 4).min(TOTAL))
}

impl Inotify {
    pub(crate) fn new(sink: Sink) -> io::Result<Inotify> {
        // SAFETY: plain syscalls; each returned descriptor is owned from here on.
        let fd = unsafe { OwnedFd::from_raw_fd(cvt(libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK))?) };
        let stop = unsafe { OwnedFd::from_raw_fd(cvt(libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK))?) };
        let inner = Arc::new(Inner { fd, stop, watches: Mutex::new(Watches { limit: kernel_limit(), ..Default::default() }), sink });
        let reader = Arc::clone(&inner);
        std::thread::Builder::new().name("fdindex-inotify".into()).spawn(move || reader.run())?;
        Ok(Inotify { inner })
    }

    #[cfg(test)]
    fn watched(&self) -> BTreeSet<PathBuf> {
        self.inner.watches.lock().unwrap().by_path.keys().cloned().collect()
    }
}

impl Drop for Inotify {
    fn drop(&mut self) {
        let one: u64 = 1;
        // SAFETY: writes eight bytes from a live u64 to our own eventfd.
        unsafe { libc::write(self.inner.stop.as_raw_fd(), (&one as *const u64).cast(), 8) };
    }
}

impl Backend for Inotify {
    fn set_paths(&self, paths: &[PathBuf]) -> io::Result<()> {
        let wanted: BTreeSet<&PathBuf> = paths.iter().collect();
        let mut w = self.inner.watches.lock().unwrap();
        let gone: Vec<PathBuf> = w.roots.keys().filter(|r| !wanted.contains(r)).cloned().collect();
        for root in gone {
            self.inner.forget_root(&mut w, &root);
        }
        let mut failed = None;
        for root in paths {
            if w.roots.contains_key(root) {
                continue;
            }
            w.roots.insert(root.clone(), 0);
            if let Err(e) = self.inner.add_tree(&mut w, root, root) {
                self.inner.forget_root(&mut w, root);
                failed = Some(e);
            }
        }
        failed.map_or(Ok(()), Err)
    }
}

impl Inner {
    /// Watch `dir` and, recursively, every directory under it the watcher acts on.
    fn add_tree(&self, w: &mut Watches, root: &Path, dir: &Path) -> io::Result<()> {
        self.add_one(w, root, dir)?;
        let Ok(entries) = std::fs::read_dir(dir) else { return Ok(()) };
        for e in entries.flatten() {
            let p = e.path();
            if e.file_type().is_ok_and(|t| t.is_dir()) && ref_dir(root, &p) {
                // Below the root, a directory that vanished or hit the bound is skipped, not fatal.
                let _ = self.add_tree(w, root, &p);
            }
        }
        Ok(())
    }

    fn add_one(&self, w: &mut Watches, root: &Path, dir: &Path) -> io::Result<()> {
        if w.by_path.contains_key(dir) {
            return Ok(());
        }
        let used = w.roots.get(root).copied().unwrap_or(0);
        if used >= PER_REPO || w.by_wd.len() >= w.limit {
            if !std::mem::replace(&mut w.bounded, true) {
                crate::service::log::info(&format!(
                    "ref watch bound reached ({PER_REPO} per repository, {} in all): {} is not watched; its refs are read at the next request or collection",
                    w.limit,
                    dir.display()
                ));
            }
            return Err(io::Error::other("ref watch bound reached"));
        }
        let c = CString::new(dir.as_os_str().as_bytes()).map_err(io::Error::other)?;
        // SAFETY: a NUL-terminated path and our own inotify descriptor.
        let wd = cvt(unsafe { libc::inotify_add_watch(self.fd.as_raw_fd(), c.as_ptr(), MASK) })?;
        // Two paths can name one directory (a hard-linked tree is not possible, but a bind mount
        // is); the kernel then returns the existing descriptor, which keeps its first path.
        if w.by_wd.contains_key(&wd) {
            return Ok(());
        }
        w.by_wd.insert(wd, dir.to_path_buf());
        w.by_path.insert(dir.to_path_buf(), wd);
        *w.roots.entry(root.to_path_buf()).or_default() += 1;
        Ok(())
    }

    fn forget_root(&self, w: &mut Watches, root: &Path) {
        // A submodule's common dir sits under its parent's (`.git/modules/<name>`) and is a root of
        // its own, so a watch belongs to the nearest root above it, not to every root above it.
        let wds: Vec<(i32, PathBuf)> = w.by_wd.iter().filter(|(_, p)| Self::root_of(w, p).as_deref() == Some(root)).map(|(wd, p)| (*wd, p.clone())).collect();
        for (wd, p) in wds {
            // SAFETY: removing a descriptor we added; an already-removed one fails harmlessly.
            unsafe { libc::inotify_rm_watch(self.fd.as_raw_fd(), wd) };
            w.by_wd.remove(&wd);
            w.by_path.remove(&p);
        }
        w.roots.remove(root);
    }

    fn root_of(w: &Watches, path: &Path) -> Option<PathBuf> {
        path.ancestors().find(|a| w.roots.contains_key(*a)).map(Path::to_path_buf)
    }

    fn run(self: Arc<Self>) {
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let mut fds = [
                libc::pollfd { fd: self.fd.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: self.stop.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            ];
            // SAFETY: two initialised pollfds.
            let rc = unsafe { libc::poll(fds.as_mut_ptr(), 2, -1) };
            if rc < 0 {
                if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return;
            }
            if fds[1].revents != 0 {
                return;
            }
            // SAFETY: reads into our own buffer, at most its length.
            let n = unsafe { libc::read(self.fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
            if n <= 0 {
                continue; // EAGAIN after a spurious wake-up, or EINTR
            }
            let batch = self.decode(&buf[..n as usize]);
            if !batch.is_empty() {
                (self.sink)(&batch);
            }
        }
    }

    /// Turn a buffer of `inotify_event`s into `Raw` events, watching new ref directories on the way.
    fn decode(&self, buf: &[u8]) -> Vec<Raw> {
        const HEADER: usize = std::mem::size_of::<libc::inotify_event>();
        let mut out = Vec::new();
        let mut w = self.watches.lock().unwrap();
        let mut at = 0;
        while at + HEADER <= buf.len() {
            // SAFETY: the kernel writes whole events; the header may be unaligned in our buffer.
            let ev: libc::inotify_event = unsafe { std::ptr::read_unaligned(buf[at..].as_ptr().cast()) };
            let name_bytes = &buf[at + HEADER..(at + HEADER + ev.len as usize).min(buf.len())];
            at += HEADER + ev.len as usize;
            if ev.mask & libc::IN_Q_OVERFLOW != 0 {
                out.push(Raw::Overflow);
                continue;
            }
            if ev.mask & libc::IN_IGNORED != 0 {
                // The directory is gone (or we removed it): its descriptor is dead.
                if let Some(p) = w.by_wd.remove(&ev.wd) {
                    w.by_path.remove(&p);
                    if let Some(root) = Self::root_of(&w, &p)
                        && let Some(n) = w.roots.get_mut(&root)
                    {
                        *n = n.saturating_sub(1);
                    }
                }
                continue;
            }
            let Some(dir) = w.by_wd.get(&ev.wd).cloned() else { continue };
            let name = name_bytes.split(|b| *b == 0).next().unwrap_or(&[]);
            let path = if name.is_empty() { dir } else { dir.join(std::ffi::OsStr::from_bytes(name)) };
            if ev.mask & libc::IN_ISDIR != 0
                && ev.mask & (libc::IN_CREATE | libc::IN_MOVED_TO) != 0
                && let Some(root) = Self::root_of(&w, &path)
                && ref_dir(&root, &path)
            {
                let _ = self.add_tree(&mut w, &root, &path);
            }
            out.push(Raw::Changed(path));
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn backend() -> (Inotify, Arc<Mutex<Vec<Raw>>>) {
        let seen = Arc::new(Mutex::new(Vec::new()));
        let s = Arc::clone(&seen);
        let sink: Sink = Arc::new(move |b: &[Raw]| s.lock().unwrap().extend_from_slice(b));
        (Inotify::new(sink).unwrap(), seen)
    }

    fn until(seen: &Mutex<Vec<Raw>>, want: &Path) -> bool {
        let end = Instant::now() + Duration::from_secs(5);
        while Instant::now() < end {
            if seen.lock().unwrap().iter().any(|r| r == &Raw::Changed(want.to_path_buf())) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        false
    }

    fn common() -> (tempfile::TempDir, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let c = d.path().canonicalize().unwrap().join("repo.git");
        for sub in ["refs/heads/team", "refs/tags", "refs/remotes/origin", "objects/ab", "worktrees/wt1"] {
            std::fs::create_dir_all(c.join(sub)).unwrap();
        }
        (d, c)
    }

    #[test]
    fn only_the_directories_that_can_hold_a_watched_ref_are_watched() {
        let (_d, c) = common();
        let (b, _) = backend();
        b.set_paths(std::slice::from_ref(&c)).unwrap();
        let want: BTreeSet<PathBuf> = ["", "refs", "refs/heads", "refs/heads/team", "worktrees", "worktrees/wt1"].iter().map(|s| if s.is_empty() { c.clone() } else { c.join(s) }).collect();
        assert_eq!(b.watched(), want);
        b.set_paths(&[]).unwrap();
        assert!(b.watched().is_empty());
    }

    #[test]
    fn a_ref_renamed_into_place_and_one_in_a_new_folder_are_both_reported() {
        let (_d, c) = common();
        let (b, seen) = backend();
        b.set_paths(std::slice::from_ref(&c)).unwrap();
        std::fs::write(c.join("refs/heads/main.lock"), "x\n").unwrap();
        std::fs::rename(c.join("refs/heads/main.lock"), c.join("refs/heads/main")).unwrap();
        assert!(until(&seen, &c.join("refs/heads/main")));
        std::fs::create_dir(c.join("refs/heads/feature")).unwrap();
        assert!(until(&seen, &c.join("refs/heads/feature")));
        // The new folder is watched from its creation on.
        let end = Instant::now() + Duration::from_secs(5);
        while !b.watched().contains(&c.join("refs/heads/feature")) && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(10));
        }
        std::fs::write(c.join("refs/heads/feature/x"), "y\n").unwrap();
        assert!(until(&seen, &c.join("refs/heads/feature/x")));
        std::fs::write(c.join("worktrees/wt1/HEAD"), "z\n").unwrap();
        assert!(until(&seen, &c.join("worktrees/wt1/HEAD")));
    }

    #[test]
    fn the_per_repository_bound_leaves_the_rest_unwatched_but_keeps_the_repository() {
        let (_d, c) = common();
        for i in 0..PER_REPO + 10 {
            std::fs::create_dir(c.join(format!("refs/heads/f{i}"))).unwrap();
        }
        let (b, _) = backend();
        b.set_paths(std::slice::from_ref(&c)).unwrap();
        let n = b.watched().len();
        assert_eq!(n, PER_REPO);
        assert!(b.watched().contains(&c));
    }
}
