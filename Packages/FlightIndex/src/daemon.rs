//! The socket server: accept connections, read request lines, hand them to the `Service`.
//!
//! Plain threads rather than an async runtime. Every request is CPU- or disk-bound work on a
//! shared graph, an idle connection costs one parked thread, and there are tens of clients on a
//! machine, not thousands. A gate bounds how many requests *run* at once (one per core, doubled
//! because requests also wait on builds), so thirty simultaneous clients queue rather than all
//! resolving graphs at the same instant.
//!
//! Writes are serialised below this layer: the store has one `Writer` per repository file behind a
//! mutex, so two clients can never both write one database, and a reader (a read-only WAL
//! connection) is never blocked by it. That is what makes "database is locked" between clients
//! impossible rather than merely unlikely.

use crate::error::{Error, Result};
use crate::proto::{state, Request, Response, MAX_LINE_BYTES};
use crate::runtime::{DaemonLock, LockResult, Paths};
use crate::service::{log, Config, Service};
use serde_json::Value;
use std::ffi::CString;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, OnceLock};

pub struct Options {
    pub paths: Paths,
    pub config: Config,
}

/// Bounds concurrently running requests.
struct Gate {
    free: Mutex<usize>,
    cv: Condvar,
}

impl Gate {
    fn enter(&self) -> GateGuard<'_> {
        let mut free = self.free.lock().unwrap();
        while *free == 0 {
            free = self.cv.wait(free).unwrap();
        }
        *free -= 1;
        GateGuard(self)
    }
}

struct GateGuard<'a>(&'a Gate);

impl Drop for GateGuard<'_> {
    fn drop(&mut self) {
        *self.0.free.lock().unwrap() += 1;
        self.0.cv.notify_one();
    }
}

static SOCKET_C: OnceLock<CString> = OnceLock::new();

extern "C" fn on_signal(_: libc::c_int) {
    // Only async-signal-safe calls: remove the socket so the next client sees "not running"
    // instead of connecting to a dead file, then leave. The pidfile lock dies with the process.
    if let Some(p) = SOCKET_C.get() {
        // SAFETY: `unlink` and `_exit` are async-signal-safe; the pointer is a live CString.
        unsafe {
            libc::unlink(p.as_ptr());
            libc::_exit(0);
        }
    }
}

/// Run the daemon until it is told to shut down. A second daemon on the same store finds the lock
/// held and returns `Ok` at once: starting one is idempotent, which is what lets every client
/// start it without coordinating.
pub fn run(opts: Options) -> Result<()> {
    opts.paths.check_socket_len()?;
    let lock = match DaemonLock::acquire(&opts.paths.pidfile)? {
        LockResult::Held(l) => l,
        LockResult::Busy(pid) => {
            eprintln!("fdindex daemon already running{}", pid.map(|p| format!(" (pid {p})")).unwrap_or_default());
            return Ok(());
        }
    };
    log::open(&opts.paths.log);
    let svc = Service::open(opts.config.clone())?;

    // We hold the lock, so any socket file left is from a daemon that died without cleaning up.
    let _ = std::fs::remove_file(&opts.paths.socket);
    let listener = UnixListener::bind(&opts.paths.socket).map_err(|e| Error::io(&opts.paths.socket, e))?;
    // The socket is the daemon's whole access control: a path argument reads any file the user
    // can, so only the user may connect.
    let _ = std::fs::set_permissions(&opts.paths.socket, std::fs::Permissions::from_mode(0o600));
    if let Ok(c) = CString::new(opts.paths.socket.as_os_str().as_encoded_bytes()) {
        let _ = SOCKET_C.set(c);
        // SAFETY: installing a handler that only calls async-signal-safe functions.
        unsafe {
            libc::signal(libc::SIGTERM, on_signal as *const () as libc::sighandler_t);
            libc::signal(libc::SIGINT, on_signal as *const () as libc::sighandler_t);
        }
    }
    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let gate = Arc::new(Gate { free: Mutex::new((cores * 2).max(8)), cv: Condvar::new() });
    log::info(&format!("daemon up: pid {}, socket {}, store {}", std::process::id(), opts.paths.socket.display(), opts.paths.store.display()));

    let socket = opts.paths.socket.clone();
    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
        let (svc, gate, socket) = (svc.clone(), gate.clone(), socket.clone());
        let spawned = std::thread::Builder::new().name("fdindex-conn".into()).stack_size(8 << 20).spawn(move || serve(stream, svc, gate, &socket));
        if let Err(e) = spawned {
            log::info(&format!("could not start a connection thread: {e}"));
        }
    }
    drop(lock);
    Ok(())
}

fn serve(stream: UnixStream, svc: Arc<Service>, gate: Arc<Gate>, socket: &Path) {
    let Ok(read_half) = stream.try_clone() else { return };
    let mut reader = BufReader::new(read_half);
    let mut out = stream;
    loop {
        let mut line = String::new();
        // A line is read into memory before it is parsed, so its length is capped first.
        match reader.by_ref().take(MAX_LINE_BYTES + 1).read_line(&mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        if line.len() as u64 > MAX_LINE_BYTES {
            let _ = write_response(&mut out, &Response::error(Value::Null, state::BAD_REQUEST, "request line too long"));
            return;
        }
        let req: Request = match serde_json::from_str(line.trim()) {
            Ok(r) => r,
            Err(e) => {
                if write_response(&mut out, &Response::error(Value::Null, state::BAD_REQUEST, format!("not a request: {e}"))).is_err() {
                    return;
                }
                continue;
            }
        };
        if req.tool == "shutdown" {
            let _ = write_response(&mut out, &Response::text(req.id, "shutting down".into()));
            log::info("shutdown requested");
            let _ = std::fs::remove_file(socket);
            std::process::exit(0);
        }
        let resp = {
            let _running = gate.enter();
            svc.handle(req)
        };
        if write_response(&mut out, &resp).is_err() {
            return;
        }
    }
}

fn write_response(out: &mut UnixStream, resp: &Response) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(resp).unwrap_or_default();
    bytes.push(b'\n');
    out.write_all(&bytes)
}
