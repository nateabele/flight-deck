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

/// Block until no daemon holds the pidfile lock, up to `timeout`. A daemon answers `shutdown` and
/// then exits a moment later; anything that starts a new daemon straight after a stop must wait for
/// the lock to be free, or the new one finds it held and exits.
pub fn wait_until_stopped(pidfile: &Path, timeout: std::time::Duration) -> bool {
    let until = std::time::Instant::now() + timeout;
    loop {
        match DaemonLock::acquire(pidfile) {
            Ok(LockResult::Busy(_)) if std::time::Instant::now() < until => std::thread::sleep(std::time::Duration::from_millis(10)),
            Ok(LockResult::Busy(_)) => return false,
            _ => return true,
        }
    }
}

/// Resident set size of this process in bytes, 0 when the platform will not say. Cheap enough to
/// sample after every build (no process is spawned).
pub fn rss_bytes() -> u64 {
    #[cfg(target_os = "linux")]
    {
        let pages: u64 = std::fs::read_to_string("/proc/self/statm").ok().and_then(|s| s.split_whitespace().nth(1)?.parse().ok()).unwrap_or(0);
        pages * 4096
    }
    #[cfg(target_os = "macos")]
    {
        // SAFETY: `task_info` fills the struct we pass for the flavor we name; `count` is its size in words.
        unsafe {
            let mut info: libc::mach_task_basic_info = std::mem::zeroed();
            let mut count = (std::mem::size_of::<libc::mach_task_basic_info>() / std::mem::size_of::<libc::integer_t>()) as libc::mach_msg_type_number_t;
            #[allow(deprecated)]
            let task = libc::mach_task_self();
            let rc = libc::task_info(task, libc::MACH_TASK_BASIC_INFO, (&mut info as *mut libc::mach_task_basic_info).cast(), &mut count);
            if rc == 0 { info.resident_size } else { 0 }
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        0
    }
}

/// What the kernel says about this process's pages (macOS only; zero elsewhere).
#[derive(Debug, Clone, Copy, Default)]
pub struct VmInfo {
    /// Resident, including pages the allocator freed with `MADV_FREE_REUSABLE` that the kernel has not yet taken back.
    pub resident: u64,
    /// Dirty anonymous memory the process owns.
    pub internal: u64,
    /// Freed by the allocator and marked reusable, but still counted in `resident`.
    pub reusable: u64,
    pub compressed: u64,
    /// What Activity Monitor calls Memory: dirty + compressed, without reusable pages.
    pub footprint: u64,
}

#[cfg(target_os = "macos")]
pub fn vm_info() -> VmInfo {
    // The head of `task_vm_info` (mach/task_info.h) up to `phys_footprint`; the kernel fills as many words as the count allows.
    #[repr(C)]
    #[derive(Default)]
    struct TaskVmInfo {
        virtual_size: u64,
        region_count: i32,
        page_size: i32,
        resident_size: u64,
        resident_size_peak: u64,
        device: u64,
        device_peak: u64,
        internal: u64,
        internal_peak: u64,
        external: u64,
        external_peak: u64,
        reusable: u64,
        reusable_peak: u64,
        purgeable_volatile_pmap: u64,
        purgeable_volatile_resident: u64,
        purgeable_volatile_virtual: u64,
        compressed: u64,
        compressed_peak: u64,
        compressed_lifetime: u64,
        phys_footprint: u64,
    }
    const TASK_VM_INFO: libc::task_flavor_t = 22;
    let mut info = TaskVmInfo::default();
    let mut count = (std::mem::size_of::<TaskVmInfo>() / std::mem::size_of::<libc::integer_t>()) as libc::mach_msg_type_number_t;
    // SAFETY: `task_info` fills at most `count` words of the struct we pass.
    let rc = unsafe {
        #[allow(deprecated)]
        let task = libc::mach_task_self();
        libc::task_info(task, TASK_VM_INFO, (&mut info as *mut TaskVmInfo).cast(), &mut count)
    };
    if rc != 0 {
        return VmInfo::default();
    }
    VmInfo { resident: info.resident_size, internal: info.internal, reusable: info.reusable, compressed: info.compressed, footprint: info.phys_footprint }
}

#[cfg(not(target_os = "macos"))]
pub fn vm_info() -> VmInfo {
    VmInfo { resident: rss_bytes(), ..VmInfo::default() }
}
