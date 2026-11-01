//! The process allocator: the system one, counting what is live.
//!
//! The daemon's memory target is about the process, but what the daemon can free is heap. Knowing
//! live heap bytes next to RSS says how much of the resident set is data in use and how much is
//! the allocator holding on to freed pages (macOS `malloc` returns little unless asked, see
//! `runtime::release_free_memory`). One relaxed atomic add per allocation: below the noise of a
//! parse.

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering::Relaxed};

pub struct Counting;

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);

/// The most `live_bytes` has been since the process started (or since `reset_peak`).
pub fn peak_bytes() -> usize {
    PEAK.load(Relaxed)
}

/// Start measuring the peak afresh from what is live now.
pub fn reset_peak() {
    PEAK.store(LIVE.load(Relaxed), Relaxed);
}

fn grew(by: usize) {
    let now = LIVE.fetch_add(by, Relaxed) + by;
    // A load first: the peak rarely moves, and an RMW per allocation would be the costly part.
    if now > PEAK.load(Relaxed) {
        PEAK.fetch_max(now, Relaxed);
    }
}

/// Bytes allocated and not yet freed (what was asked for, before allocator rounding).
pub fn live_bytes() -> usize {
    LIVE.load(Relaxed)
}

// SAFETY: every call is forwarded unchanged to `System`; the counter only observes sizes.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(l) };
        if !p.is_null() {
            grew(l.size());
        }
        p
    }

    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        unsafe { System.dealloc(p, l) };
        LIVE.fetch_sub(l.size(), Relaxed);
    }

    unsafe fn alloc_zeroed(&self, l: Layout) -> *mut u8 {
        let p = unsafe { System.alloc_zeroed(l) };
        if !p.is_null() {
            grew(l.size());
        }
        p
    }

    unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
        let q = unsafe { System.realloc(p, l, new) };
        if !q.is_null() {
            grew(new);
            LIVE.fetch_sub(l.size(), Relaxed);
        }
        q
    }
}
