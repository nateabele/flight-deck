//! Where the daemon's files live, and the one-daemon-per-store lock.
//!
//! Everything defaults from the store root, so pointing `--store` somewhere else gives a fully
//! separate daemon (own socket, own lock, own log): the tests and a scratch run never touch the
//! real one. Only the Linux default socket leaves the store dir, for `$XDG_RUNTIME_DIR`, which
//! systemd cleans up on logout.

use crate::error::{Error, Result};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

/// macOS `sun_path` is 104 bytes including the NUL; Linux 108. Binding a longer path fails with an
/// opaque `InvalidInput`, so it is checked up front and reported with the fix.
const MAX_SOCKET_PATH: usize = 100;

#[derive(Debug, Clone)]
pub struct Paths {
    pub store: PathBuf,
    pub socket: PathBuf,
    pub pidfile: PathBuf,
    pub log: PathBuf,
}

impl Paths {
    /// `socket` of `None` picks the default: `$FLIGHTDECK_INDEX_SOCKET`, else (default store on
    /// Linux) `$XDG_RUNTIME_DIR/fdindex.sock`, else `<store>/fdindex.sock`.
    pub fn new(store: impl Into<PathBuf>, socket: Option<PathBuf>) -> Paths {
        let store = store.into();
        let socket = socket
            .or_else(|| std::env::var_os("FLIGHTDECK_INDEX_SOCKET").map(PathBuf::from))
            .or_else(|| {
                let default_store = store == crate::store::default_store_root();
                let xdg = std::env::var_os("XDG_RUNTIME_DIR").filter(|v| !v.is_empty());
                (cfg!(not(target_os = "macos")) && default_store).then(|| xdg.map(|x| PathBuf::from(x).join("fdindex.sock"))).flatten()
            })
            .unwrap_or_else(|| store.join("fdindex.sock"));
        Paths { pidfile: store.join("daemon.pid"), log: store.join("daemon.log"), store, socket }
    }

    pub fn check_socket_len(&self) -> Result<()> {
        let n = self.socket.as_os_str().len();
        if n > MAX_SOCKET_PATH {
            return Err(Error::Msg(format!(
                "socket path is {n} bytes, over the {MAX_SOCKET_PATH}-byte limit of a Unix socket: {} (pass a shorter --socket)",
                self.socket.display()
            )));
        }
        Ok(())
    }
}

/// Holds an exclusive `flock` on the pidfile for as long as it lives. The kernel drops the lock
/// when the process dies, however it dies, so a crashed daemon never leaves a lock that blocks its
/// successor (a stale pid in the file is harmless: only the lock decides).
pub struct DaemonLock {
    _file: File,
}

pub enum LockResult {
    Held(DaemonLock),
    /// Another daemon holds it; the pid it wrote, if readable.
    Busy(Option<u32>),
}

impl DaemonLock {
    pub fn acquire(pidfile: &Path) -> Result<LockResult> {
        if let Some(dir) = pidfile.parent() {
            std::fs::create_dir_all(dir).map_err(|e| Error::io(dir, e))?;
        }
        let mut file = OpenOptions::new().read(true).write(true).create(true).truncate(false).open(pidfile).map_err(|e| Error::io(pidfile, e))?;
        // SAFETY: `flock` on a descriptor we own for the call's duration.
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc != 0 {
            let err = std::io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EWOULDBLOCK) {
                let pid = std::fs::read_to_string(pidfile).ok().and_then(|s| s.trim().parse().ok());
                return Ok(LockResult::Busy(pid));
            }
            return Err(Error::io(pidfile, err));
        }
        file.set_len(0).map_err(|e| Error::io(pidfile, e))?;
        write!(file, "{}", std::process::id()).map_err(|e| Error::io(pidfile, e))?;
        Ok(LockResult::Held(DaemonLock { _file: file }))
    }
}

/// Resident set size of this process in bytes, 0 when the platform will not say.
pub fn rss_bytes() -> u64 {
    #[cfg(target_os = "linux")]
    {
        let pages: u64 = std::fs::read_to_string("/proc/self/statm").ok().and_then(|s| s.split_whitespace().nth(1)?.parse().ok()).unwrap_or(0);
        pages * 4096
    }
    #[cfg(not(target_os = "linux"))]
    {
        // No portable API without a mach binding; `ps` is the same number Activity Monitor shows.
        let out = std::process::Command::new("ps").args(["-o", "rss=", "-p", &std::process::id().to_string()]).output();
        out.ok().and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<u64>().ok()).map(|kb| kb * 1024).unwrap_or(0)
    }
}
