//! macOS: one FSEvents stream over the common dir of every known repository.
//!
//! Declared directly against CoreServices rather than through a wrapper crate: the surface is a
//! dozen functions, and a wrapper would hide the two things this needs (a stream we can replace
//! without a gap, and per-event flags).
//!
//! Replacing the path set creates the *new* stream and starts it before the old one is stopped, so
//! a change under a path both streams cover is seen by at least one of them (a duplicate is
//! harmless: the watcher only remembers that refs moved). Stopping first would leave a window in
//! which a ref change made while a repository was being added is lost.
//!
//! Callbacks run on a private serial dispatch queue, not a run loop, so there is no thread of ours
//! to park and no run-loop mode to get wrong.

use super::{Backend, Raw, Sink};
use std::ffi::{c_char, c_void, CStr, CString};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

type CFRef = *const c_void;
type StreamRef = *mut c_void;

const SINCE_NOW: u64 = u64::MAX;
// FSEventStreamCreateFlags
const NO_DEFER: u32 = 0x2;
const FILE_EVENTS: u32 = 0x10;
// FSEventStreamEventFlags
const USER_DROPPED: u32 = 0x2;
const KERNEL_DROPPED: u32 = 0x4;
const EVENT_IDS_WRAPPED: u32 = 0x8;

const UTF8: u32 = 0x0800_0100;

#[repr(C)]
struct StreamContext {
    version: isize,
    info: *mut c_void,
    retain: Option<extern "C" fn(*const c_void) -> *const c_void>,
    release: Option<extern "C" fn(*const c_void)>,
    copy_description: Option<extern "C" fn(*const c_void) -> CFRef>,
}

type Callback = extern "C" fn(StreamRef, *mut c_void, usize, *mut c_void, *const u32, *const u64);

#[link(name = "CoreServices", kind = "framework")]
unsafe extern "C" {
    fn FSEventStreamCreate(allocator: CFRef, callback: Callback, context: *const StreamContext, paths: CFRef, since: u64, latency: f64, flags: u32) -> StreamRef;
    fn FSEventStreamSetDispatchQueue(stream: StreamRef, queue: *mut c_void);
    fn FSEventStreamStart(stream: StreamRef) -> bool;
    fn FSEventStreamStop(stream: StreamRef);
    fn FSEventStreamInvalidate(stream: StreamRef);
    fn FSEventStreamRelease(stream: StreamRef);
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    static kCFTypeArrayCallBacks: c_void;
    fn CFStringCreateWithBytes(alloc: CFRef, bytes: *const u8, len: isize, encoding: u32, is_external: bool) -> CFRef;
    fn CFArrayCreate(alloc: CFRef, values: *const CFRef, count: isize, callbacks: *const c_void) -> CFRef;
    fn CFRelease(cf: CFRef);
}

unsafe extern "C" {
    fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> *mut c_void;
    fn dispatch_sync_f(queue: *mut c_void, context: *mut c_void, work: extern "C" fn(*mut c_void));
}

extern "C" fn nothing(_: *mut c_void) {}

thread_local! {
    /// Set while this thread is inside a stream callback, i.e. running on the private queue.
    static IN_CALLBACK: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

struct Live {
    stream: StreamRef,
    /// The callback's context, freed only after the stream is gone and its queue has drained.
    sink: *mut Sink,
    paths: Vec<PathBuf>,
}

pub(super) struct FsEvents {
    queue: *mut c_void,
    sink: Sink,
    live: Mutex<Option<Live>>,
}

// SAFETY: the raw pointers are a dispatch queue (thread-safe by definition) and a stream and sink
// pointer that are only touched under `live`'s lock.
unsafe impl Send for FsEvents {}
unsafe impl Sync for FsEvents {}

impl FsEvents {
    pub(super) fn new(sink: Sink) -> io::Result<FsEvents> {
        let label = CString::new("dev.flightdeck.fdindex.fsevents").expect("no NUL");
        // SAFETY: a NULL attribute is a serial queue.
        let queue = unsafe { dispatch_queue_create(label.as_ptr(), std::ptr::null()) };
        if queue.is_null() {
            return Err(io::Error::other("dispatch_queue_create failed"));
        }
        Ok(FsEvents { queue, sink, live: Mutex::new(None) })
    }

    fn start(&self, paths: &[PathBuf]) -> io::Result<Live> {
        // SAFETY: every CF object created here is released before return, and the stream copies
        // the path array.
        unsafe {
            let strings: Vec<CFRef> = paths.iter().map(|p| CFStringCreateWithBytes(std::ptr::null(), p.as_os_str().as_bytes().as_ptr(), p.as_os_str().len() as isize, UTF8, false)).collect();
            let array = CFArrayCreate(std::ptr::null(), strings.as_ptr(), strings.len() as isize, &raw const kCFTypeArrayCallBacks);
            let sink = Box::into_raw(Box::new(self.sink.clone()));
            let ctx = StreamContext { version: 0, info: sink as *mut c_void, retain: None, release: None, copy_description: None };
            // File events, so a ref rewritten inside `refs/heads` names its path; no latency.
            let stream = FSEventStreamCreate(std::ptr::null(), on_events, &ctx, array, SINCE_NOW, 0.0, NO_DEFER | FILE_EVENTS);
            CFRelease(array);
            for s in strings {
                CFRelease(s);
            }
            if stream.is_null() {
                drop(Box::from_raw(sink));
                return Err(io::Error::other("FSEventStreamCreate failed"));
            }
            FSEventStreamSetDispatchQueue(stream, self.queue);
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream);
                FSEventStreamRelease(stream);
                drop(Box::from_raw(sink));
                return Err(io::Error::other("FSEventStreamStart failed"));
            }
            Ok(Live { stream, sink, paths: paths.to_vec() })
        }
    }

    fn stop(&self, live: Live) {
        // SAFETY: the stream is ours; after `Invalidate` no new callback is queued, and the empty
        // synchronous block runs behind any already queued, so none is running when the sink
        // is freed.
        unsafe {
            FSEventStreamStop(live.stream);
            FSEventStreamInvalidate(live.stream);
            FSEventStreamRelease(live.stream);
            // `dispatch_sync` onto the queue the caller is running on is a libdispatch trap
            // (SIGTRAP). That happens if the last reference to the watcher is dropped by code a
            // callback runs. Nothing can be waiting on this thread's own callback, so the sink is
            // simply leaked in that case: a few bytes, once, at teardown.
            if IN_CALLBACK.with(|c| c.get()) {
                return;
            }
            dispatch_sync_f(self.queue, std::ptr::null_mut(), nothing);
            drop(Box::from_raw(live.sink));
        }
    }
}

impl Drop for FsEvents {
    fn drop(&mut self) {
        if let Some(live) = self.live.lock().unwrap().take() {
            self.stop(live);
        }
    }
}

/// Paths to hand FSEvents: the existing ones, with any path inside another dropped (FSEvents is
/// recursive, and an overlapping pair would deliver everything under the inner one twice).
fn stream_paths(paths: &[PathBuf]) -> Vec<PathBuf> {
    let mut all: Vec<&Path> = paths.iter().map(PathBuf::as_path).filter(|p| p.exists()).collect();
    all.sort();
    all.dedup();
    let mut out: Vec<PathBuf> = Vec::new();
    for p in all {
        if !out.iter().any(|o| p.starts_with(o)) {
            out.push(p.to_path_buf());
        }
    }
    out
}

impl Backend for FsEvents {
    fn set_paths(&self, paths: &[PathBuf]) -> io::Result<()> {
        let paths = stream_paths(paths);
        let mut live = self.live.lock().unwrap();
        if live.as_ref().is_some_and(|l| l.paths == paths) {
            return Ok(());
        }
        let old = live.take();
        let new = if paths.is_empty() { None } else { Some(self.start(&paths)?) };
        *live = new;
        if let Some(old) = old {
            self.stop(old);
        }
        Ok(())
    }
}

extern "C" fn on_events(_: StreamRef, info: *mut c_void, n: usize, paths: *mut c_void, flags: *const u32, _ids: *const u64) {
    // SAFETY: `info` is the boxed sink installed by `start`, alive until the stream is stopped
    // and its queue drained; FSEvents hands `n` NUL-terminated paths and `n` flags.
    let (sink, paths, flags) = unsafe { (&*(info as *const Sink), std::slice::from_raw_parts(paths as *const *const c_char, n), std::slice::from_raw_parts(flags, n)) };
    let mut batch: Vec<Raw> = Vec::with_capacity(n);
    for (p, &f) in paths.iter().zip(flags) {
        // SAFETY: see above.
        let path = PathBuf::from(std::ffi::OsStr::from_bytes(unsafe { CStr::from_ptr(*p) }.to_bytes()));
        batch.push(classify(path, f));
    }
    // A panic must not unwind into CoreServices.
    IN_CALLBACK.with(|c| c.set(true));
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| sink(&batch)));
    IN_CALLBACK.with(|c| c.set(false));
}

fn classify(path: PathBuf, f: u32) -> Raw {
    if f & (USER_DROPPED | KERNEL_DROPPED | EVENT_IDS_WRAPPED) != 0 {
        return Raw::Overflow;
    }
    // A coalesced subtree or a mount change says only "something under here": the common dir (or
    // `refs/`) as a whole, which the watcher reads as "refs may have moved".
    Raw::Changed(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MUST_SCAN_SUBDIRS: u32 = 0x1;

    #[test]
    fn dropped_events_are_never_read_as_ordinary_changes() {
        // Reading a dropped batch as a plain change of one path would lose every ref in it.
        assert_eq!(classify("/a".into(), KERNEL_DROPPED), Raw::Overflow);
        assert_eq!(classify("/a".into(), USER_DROPPED), Raw::Overflow);
        assert_eq!(classify("/a".into(), EVENT_IDS_WRAPPED), Raw::Overflow);
        assert_eq!(classify("/a".into(), MUST_SCAN_SUBDIRS), Raw::Changed("/a".into()));
    }

    #[test]
    fn nested_watch_paths_collapse_into_the_outer_one() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().canonicalize().unwrap();
        std::fs::create_dir_all(p.join("wt/.git")).unwrap();
        let got = stream_paths(&[p.join("wt"), p.join("wt/.git"), p.join("gone")]);
        assert_eq!(got, vec![p.join("wt")]);
    }
}
