//! The compiler's own answers for Swift, read from an Xcode or SwiftPM index store.
//!
//! A build with indexing on (Xcode always, `swift build` with `-index-store-path`) writes a
//! `DataStore` of USR-resolved occurrences. Where it is present and no older than the file on disk,
//! it says exactly which declaration each reference means, so it outranks every heuristic
//! (`Confidence::Precise`, applied by `ViewGraph::with_precise`). It only describes the worktree
//! that was built, as it was at build time: files edited since are left to the heuristics, and so
//! is every other view.
//!
//! `libIndexStore.dylib` ships with Xcode and with the Command Line Tools. It is opened at run time
//! (`dlopen`), never linked, so fdindex runs without it and simply has no precise layer. Its C API
//! is private but has been stable for years; every entry point is looked up by name and a missing
//! one disables the layer rather than failing.

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{Instant, UNIX_EPOCH};

#[repr(C)]
#[derive(Clone, Copy)]
struct StrRef {
    data: *const c_char,
    len: usize,
}

impl StrRef {
    fn as_str(&self) -> &str {
        if self.data.is_null() {
            return "";
        }
        // SAFETY: libIndexStore hands out (pointer, length) views valid for the callback's duration.
        let b = unsafe { std::slice::from_raw_parts(self.data.cast::<u8>(), self.len) };
        std::str::from_utf8(b).unwrap_or("")
    }
}

type P = *mut c_void;
type UnitCb = extern "C" fn(P, StrRef) -> bool;
type ItemCb = extern "C" fn(P, P) -> bool;

/// The entry points used, resolved once per process.
struct Lib {
    store_create: unsafe extern "C" fn(*const c_char, *mut P) -> P,
    store_dispose: unsafe extern "C" fn(P),
    error_description: unsafe extern "C" fn(P) -> *const c_char,
    error_dispose: unsafe extern "C" fn(P),
    units_apply: unsafe extern "C" fn(P, u32, P, UnitCb) -> bool,
    unit_reader_create: unsafe extern "C" fn(P, *const c_char, *mut P) -> P,
    unit_reader_dispose: unsafe extern "C" fn(P),
    unit_deps_apply: unsafe extern "C" fn(P, P, ItemCb) -> bool,
    dep_kind: unsafe extern "C" fn(P) -> c_int,
    dep_name: unsafe extern "C" fn(P) -> StrRef,
    dep_filepath: unsafe extern "C" fn(P) -> StrRef,
    record_reader_create: unsafe extern "C" fn(P, *const c_char, *mut P) -> P,
    record_reader_dispose: unsafe extern "C" fn(P),
    occurrences_apply: unsafe extern "C" fn(P, P, ItemCb) -> bool,
    occ_symbol: unsafe extern "C" fn(P) -> P,
    occ_roles: unsafe extern "C" fn(P) -> u64,
    occ_line_col: unsafe extern "C" fn(P, *mut u32, *mut u32),
    sym_name: unsafe extern "C" fn(P) -> StrRef,
    sym_usr: unsafe extern "C" fn(P) -> StrRef,
}

// SAFETY: plain function pointers into a library that is never unloaded.
unsafe impl Send for Lib {}
unsafe impl Sync for Lib {}

const DEP_RECORD: c_int = 2;
const ROLE_DEFINITION: u64 = 1 << 1;
const ROLE_REFERENCE: u64 = 1 << 2;
const ROLE_IMPLICIT: u64 = 1 << 8;

/// Where libIndexStore lives: next to the selected toolchain's `swift`, then the usual installs.
fn lib_candidates() -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(p) = std::env::var_os("FDINDEX_LIBINDEXSTORE") {
        out.push(PathBuf::from(p));
    }
    if let Ok(o) = std::process::Command::new("xcrun").args(["--find", "swift"]).output()
        && o.status.success()
    {
        let swift = PathBuf::from(String::from_utf8_lossy(&o.stdout).trim());
        if let Some(usr) = swift.parent().and_then(Path::parent) {
            out.push(usr.join("lib/libIndexStore.dylib"));
        }
    }
    out.push("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib".into());
    out.push("/Library/Developer/CommandLineTools/usr/lib/libIndexStore.dylib".into());
    out
}

// Each transmute's target is the `Lib` field it initialises, whose type spells the C signature.
#[allow(clippy::missing_transmute_annotations)]
fn load_lib() -> Option<Lib> {
    for path in lib_candidates() {
        let Ok(c) = CString::new(path.as_os_str().as_encoded_bytes()) else { continue };
        // SAFETY: dlopen of a path; RTLD_LOCAL keeps its symbols out of the global namespace.
        let h = unsafe { libc::dlopen(c.as_ptr(), libc::RTLD_NOW | libc::RTLD_LOCAL) };
        if h.is_null() {
            continue;
        }
        macro_rules! sym {
            ($name:literal) => {{
                let n = concat!($name, "\0");
                // SAFETY: the name is NUL-terminated; a missing symbol yields null, checked here.
                let p = unsafe { libc::dlsym(h, n.as_ptr() as *const c_char) };
                if p.is_null() {
                    continue;
                }
                // SAFETY: the symbol's C signature is the one the field declares (libIndexStore's
                // indexstore.h, unchanged since Xcode 9).
                unsafe { std::mem::transmute::<*mut c_void, _>(p) }
            }};
        }
        return Some(Lib {
            store_create: sym!("indexstore_store_create"),
            store_dispose: sym!("indexstore_store_dispose"),
            error_description: sym!("indexstore_error_get_description"),
            error_dispose: sym!("indexstore_error_dispose"),
            units_apply: sym!("indexstore_store_units_apply_f"),
            unit_reader_create: sym!("indexstore_unit_reader_create"),
            unit_reader_dispose: sym!("indexstore_unit_reader_dispose"),
            unit_deps_apply: sym!("indexstore_unit_reader_dependencies_apply_f"),
            dep_kind: sym!("indexstore_unit_dependency_get_kind"),
            dep_name: sym!("indexstore_unit_dependency_get_name"),
            dep_filepath: sym!("indexstore_unit_dependency_get_filepath"),
            record_reader_create: sym!("indexstore_record_reader_create"),
            record_reader_dispose: sym!("indexstore_record_reader_dispose"),
            occurrences_apply: sym!("indexstore_record_reader_occurrences_apply_f"),
            occ_symbol: sym!("indexstore_occurrence_get_symbol"),
            occ_roles: sym!("indexstore_occurrence_get_roles"),
            occ_line_col: sym!("indexstore_occurrence_get_line_col"),
            sym_name: sym!("indexstore_symbol_get_name"),
            sym_usr: sym!("indexstore_symbol_get_usr"),
        });
    }
    None
}

fn lib() -> Option<&'static Lib> {
    static LIB: OnceLock<Option<Lib>> = OnceLock::new();
    LIB.get_or_init(load_lib).as_ref()
}

/// Is libIndexStore available on this machine?
pub fn available() -> bool {
    lib().is_some()
}

/// Index stores that may describe `worktree`, most specific first: Xcode's `DerivedData` inside
/// the worktree, SwiftPM's `.build/**/index/store`, then the per-user `DerivedData` folders whose
/// `info.plist` names the worktree (its `WorkspacePath`; a byte search works on XML and binary
/// plists alike, since an ASCII path is stored verbatim in both).
pub fn discover(worktree: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let local = worktree.join("DerivedData/Index.noindex/DataStore");
    if local.join("v5").is_dir() {
        out.push(local);
    }
    let build = worktree.join(".build");
    for a in std::fs::read_dir(&build).into_iter().flatten().flatten() {
        let a = a.path();
        for p in [a.join("index/store"), a.join("debug/index/store"), a.join("release/index/store")] {
            if p.join("v5").is_dir() && !out.contains(&p) {
                out.push(p);
            }
        }
    }
    if let Some(home) = std::env::var_os("HOME") {
        let dd = PathBuf::from(home).join("Library/Developer/Xcode/DerivedData");
        let needle = worktree.to_string_lossy().into_owned();
        for e in std::fs::read_dir(dd).into_iter().flatten().flatten() {
            let p = e.path();
            let store = p.join("Index.noindex/DataStore");
            let names_worktree = std::fs::read(p.join("info.plist"))
                .is_ok_and(|b| b.windows(needle.len()).any(|w| w == needle.as_bytes()));
            if names_worktree && store.join("v5").is_dir() {
                out.push(store);
            }
        }
    }
    out
}

/// Where a reference points, per the compiler: the declaration's file (relative to the worktree)
/// and the line of its name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DefSite {
    /// Shared by every site in the file: a quarter of a million references point into 1,800 files.
    pub path: std::sync::Arc<str>,
    pub line: u32,
}

#[derive(Debug, Clone, Default)]
pub struct ReadStats {
    pub units: usize,
    pub records_read: usize,
    pub occurrences: usize,
    pub fresh_files: usize,
    /// Files whose newest record is older than the file on disk: edited since the build.
    pub stale_files: usize,
    pub elapsed_ms: u128,
}

/// The precise layer for one worktree: for each fresh Swift file, the declarations its references
/// mean, keyed by (line, base name); an empty list means outside the repository. Only what is needed is kept: no columns, no roles, and USRs
/// only while reading.
#[derive(Debug, Clone, Default)]
pub struct PreciseIndex {
    pub(crate) files: HashMap<String, HashMap<(u32, String), Vec<DefSite>>>,
    pub stats: ReadStats,
}

impl PreciseIndex {
    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }

    /// Does the layer hold `path` (a Swift file unchanged since the build)?
    pub fn covers(&self, path: &str) -> bool {
        self.files.contains_key(path)
    }

    /// The declarations the compiler says the reference named `name` on `line` of `path` means;
    /// empty when they are all outside the repository.
    pub fn lookup(&self, path: &str, line: u32, name: &str) -> Option<&[DefSite]> {
        self.files.get(path)?.get(&(line, name.to_string())).map(Vec::as_slice)
    }
}

fn mtime_secs(p: &Path) -> Option<f64> {
    let t = std::fs::metadata(p).and_then(|m| m.modified()).ok()?;
    Some(t.duration_since(UNIX_EPOCH).ok()?.as_secs_f64())
}

/// Read the occurrences of every Swift file under `worktree` that the store holds and that has not
/// changed on disk since its newest record. `Err` when the library or the store is unusable.
pub fn read(store: &Path, worktree: &Path) -> Result<PreciseIndex, String> {
    let t0 = Instant::now();
    let lib = lib().ok_or("libIndexStore.dylib not found")?;
    let cpath = CString::new(store.as_os_str().as_encoded_bytes()).map_err(|e| e.to_string())?;
    let mut err: P = std::ptr::null_mut();
    // SAFETY: valid C string; on failure `err` is set and the result is null.
    let st = unsafe { (lib.store_create)(cpath.as_ptr(), &mut err) };
    if st.is_null() {
        let msg = if err.is_null() {
            "cannot open index store".to_string()
        } else {
            // SAFETY: a non-null error owns a NUL-terminated description until disposed.
            let m = unsafe { CStr::from_ptr((lib.error_description)(err)).to_string_lossy().into_owned() };
            unsafe { (lib.error_dispose)(err) };
            m
        };
        return Err(msg);
    }
    let out = read_store(lib, st, store, worktree, t0, None);
    // SAFETY: created above, disposed once.
    unsafe { (lib.store_dispose)(st) };
    Ok(out)
}

/// (line, base name) -> the USR of the declaration outside the repository, per file.
type ExternalUsrs = HashMap<String, HashMap<(u32, String), String>>;

/// The index store as an answer key: the precise layer plus, for every reference the compiler
/// resolves outside the repository, the USR of what it means (`s:10Foundation4UUIDV`,
/// `c:objc(cs)NSFileManager`), which says whether a package binding named the right declaration.
/// For measurement (`examples/swiftres.rs`): the USRs cost memory the daemon's layer does not keep.
#[derive(Debug, Default)]
pub struct AnswerKey {
    pub precise: PreciseIndex,
    pub stats: ReadStats,
    external: ExternalUsrs,
}

impl AnswerKey {
    /// The USR the compiler resolved the reference named `name` on `line` of `path` to, when it
    /// lies outside the repository.
    pub fn external_usr(&self, path: &str, line: u32, name: &str) -> Option<&str> {
        self.external.get(path)?.get(&(line, name.to_string())).map(String::as_str)
    }
}

/// `read`, keeping the USRs of references outside the repository (see `AnswerKey`).
pub fn read_with_external(store: &Path, worktree: &Path) -> Result<AnswerKey, String> {
    let t0 = Instant::now();
    let lib = lib().ok_or("libIndexStore.dylib not found")?;
    let cpath = CString::new(store.as_os_str().as_encoded_bytes()).map_err(|e| e.to_string())?;
    let mut err: P = std::ptr::null_mut();
    // SAFETY: valid C string; on failure `err` is set and the result is null.
    let st = unsafe { (lib.store_create)(cpath.as_ptr(), &mut err) };
    if st.is_null() {
        if !err.is_null() {
            unsafe { (lib.error_dispose)(err) };
        }
        return Err("cannot open index store".into());
    }
    let mut external = ExternalUsrs::new();
    let precise = read_store(lib, st, store, worktree, t0, Some(&mut external));
    // SAFETY: created above, disposed once.
    unsafe { (lib.store_dispose)(st) };
    Ok(AnswerKey { stats: precise.stats.clone(), precise, external })
}

extern "C" fn unit_cb(ctx: P, name: StrRef) -> bool {
    // SAFETY: ctx is the `Vec<String>` passed by `read_store`.
    unsafe { (*(ctx as *mut Vec<String>)).push(name.as_str().to_string()) };
    true
}

struct DepCtx<'a> {
    lib: &'a Lib,
    deps: Vec<(String, String)>,
}

extern "C" fn dep_cb(ctx: P, d: P) -> bool {
    // SAFETY: ctx is a `DepCtx`; `d` is valid for the callback.
    let c = unsafe { &mut *(ctx as *mut DepCtx) };
    unsafe {
        if (c.lib.dep_kind)(d) == DEP_RECORD {
            c.deps.push(((c.lib.dep_name)(d).as_str().to_string(), (c.lib.dep_filepath)(d).as_str().to_string()));
        }
    }
    true
}

/// One record's occurrences, reduced to what the layer keeps, with USRs interned.
struct OccCtx<'a> {
    lib: &'a Lib,
    usrs: &'a mut HashMap<String, u32>,
    file: u32,
    defs: &'a mut Vec<(u32, u32, u32)>,
    refs: &'a mut Vec<(u32, u32, String, u32)>,
    count: usize,
}

extern "C" fn occ_cb(ctx: P, o: P) -> bool {
    // SAFETY: ctx is an `OccCtx`; `o` and its symbol are valid for the callback.
    let c = unsafe { &mut *(ctx as *mut OccCtx) };
    let roles = unsafe { (c.lib.occ_roles)(o) };
    let def = roles & ROLE_DEFINITION != 0;
    let reference = roles & ROLE_REFERENCE != 0 && roles & ROLE_IMPLICIT == 0;
    if !(def || reference) {
        return true;
    }
    let s = unsafe { (c.lib.occ_symbol)(o) };
    let (mut line, mut col) = (0u32, 0u32);
    unsafe { (c.lib.occ_line_col)(o, &mut line, &mut col) };
    let usr = unsafe { (c.lib.sym_usr)(s) };
    let next = c.usrs.len() as u32;
    let id = match c.usrs.get(usr.as_str()) {
        Some(&id) => id,
        None => {
            c.usrs.insert(usr.as_str().to_string(), next);
            next
        }
    };
    c.count += 1;
    if def {
        c.defs.push((id, c.file, line));
    } else {
        let name = unsafe { (c.lib.sym_name)(s) };
        let base = name.as_str().split('(').next().unwrap_or("").to_string();
        c.refs.push((c.file, line, base, id));
    }
    true
}

fn read_store(lib: &Lib, st: P, store: &Path, worktree: &Path, t0: Instant, mut external: Option<&mut ExternalUsrs>) -> PreciseIndex {
    let mut idx = PreciseIndex::default();
    let mut units: Vec<String> = Vec::new();
    // SAFETY: ctx outlives the call.
    unsafe { (lib.units_apply)(st, 0, &mut units as *mut _ as P, unit_cb) };
    idx.stats.units = units.len();
    let units_dir = store.join("v5/units");
    let root = worktree.canonicalize().unwrap_or_else(|_| worktree.to_path_buf());
    let prefix = format!("{}/", root.to_string_lossy());
    // file path -> (record, newest unit's mtime): a file compiled by several units (targets,
    // configurations) is described by the most recent one.
    let mut newest: HashMap<String, (String, f64)> = HashMap::new();
    let mut err: P = std::ptr::null_mut();
    for u in &units {
        let Ok(cu) = CString::new(u.as_str()) else { continue };
        // SAFETY: valid C string; null on failure.
        let r = unsafe { (lib.unit_reader_create)(st, cu.as_ptr(), &mut err) };
        if r.is_null() {
            if !err.is_null() {
                unsafe { (lib.error_dispose)(err) };
                err = std::ptr::null_mut();
            }
            continue;
        }
        let mt = mtime_secs(&units_dir.join(u)).unwrap_or(0.0);
        let mut ctx = DepCtx { lib, deps: Vec::new() };
        unsafe { (lib.unit_deps_apply)(r, &mut ctx as *mut _ as P, dep_cb) };
        unsafe { (lib.unit_reader_dispose)(r) };
        for (rec, path) in ctx.deps {
            if !(path.starts_with(&prefix) && path.ends_with(".swift")) {
                continue;
            }
            let e = newest.entry(path).or_insert_with(|| (rec.clone(), mt));
            if mt > e.1 {
                *e = (rec, mt);
            }
        }
    }
    let mut paths: Vec<std::sync::Arc<str>> = Vec::new();
    let mut usrs: HashMap<String, u32> = HashMap::new();
    let mut defs: Vec<(u32, u32, u32)> = Vec::new();
    let mut refs: Vec<(u32, u32, String, u32)> = Vec::new();
    let mut fresh: Vec<bool> = Vec::new();
    let mut sorted: Vec<(&String, &(String, f64))> = newest.iter().collect();
    sorted.sort_by(|a, b| a.0.cmp(b.0));
    for (path, (rec, mt)) in sorted {
        // One second of slack: the unit is written just after the compiler read the file.
        let is_fresh = mtime_secs(Path::new(path)).is_some_and(|m| m <= mt + 1.0);
        if is_fresh {
            idx.stats.fresh_files += 1;
        } else {
            idx.stats.stale_files += 1;
        }
        let Ok(cr) = CString::new(rec.as_str()) else { continue };
        let r = unsafe { (lib.record_reader_create)(st, cr.as_ptr(), &mut err) };
        if r.is_null() {
            if !err.is_null() {
                unsafe { (lib.error_dispose)(err) };
                err = std::ptr::null_mut();
            }
            continue;
        }
        idx.stats.records_read += 1;
        let file = paths.len() as u32;
        paths.push(std::sync::Arc::from(&path[prefix.len()..]));
        fresh.push(is_fresh);
        // A stale file's definitions still tell a fresh file's reference which file it lands in,
        // but their lines may have moved, so they are dropped below; its references are unused.
        let mut ctx = OccCtx { lib, usrs: &mut usrs, file, defs: &mut defs, refs: &mut refs, count: 0 };
        unsafe { (lib.occurrences_apply)(r, &mut ctx as *mut _ as P, occ_cb) };
        idx.stats.occurrences += ctx.count;
        unsafe { (lib.record_reader_dispose)(r) };
    }
    let usr_names: Vec<String> = match external {
        Some(_) => {
            let mut v = vec![String::new(); usrs.len()];
            for (u, id) in usrs {
                v[id as usize] = u;
            }
            v
        }
        None => {
            drop(usrs);
            Vec::new()
        }
    };
    // Declared in some record of this worktree, fresh or stale. A reference to anything else
    // resolves outside the repository (the SDK, a package checkout): the compiler says it has no
    // repository target, which outranks a same-named guess.
    let declared_here: std::collections::HashSet<u32> = defs.iter().filter(|(_, f, _)| !paths[*f as usize].starts_with(".build/")).map(|(u, _, _)| *u).collect();
    let mut def_of: HashMap<u32, Vec<DefSite>> = HashMap::new();
    for (usr, file, line) in defs {
        if fresh[file as usize] {
            let v = def_of.entry(usr).or_default();
            let site = DefSite { path: paths[file as usize].clone(), line };
            if !v.contains(&site) {
                v.push(site);
            }
        }
    }
    for (file, line, name, usr) in refs {
        if !fresh[file as usize] {
            continue;
        }
        let sites = match def_of.get(&usr) {
            Some(s) => s.as_slice(),
            None if !declared_here.contains(&usr) => {
                if let Some(ext) = external.as_deref_mut() {
                    ext.entry(paths[file as usize].to_string()).or_default().entry((line, name.clone())).or_insert_with(|| usr_names[usr as usize].clone());
                }
                &[]
            }
            // Declared only in a file edited since the build: its line is not to be trusted.
            None => continue,
        };
        let slot = idx.files.entry(paths[file as usize].to_string()).or_default().entry((line, name)).or_default();
        for s in sites {
            if !slot.contains(s) {
                slot.push(s.clone());
            }
        }
    }
    idx.stats.elapsed_ms = t0.elapsed().as_millis();
    idx
}

impl crate::engine::Engine {
    /// The graph of `view` with the index-store layer over it, read from the first store
    /// `discover` finds for the view's worktree, with what reading it found. `None` when there is
    /// no usable store (or no libIndexStore). Not cached: reading takes about two seconds on a
    /// 1,800-file Swift repository, so a caller keeps the result for as long as the build it came
    /// from is current, and the store describes only this worktree's files as they are on disk.
    pub fn precise_graph(&self, view: &crate::git::View) -> crate::error::Result<Option<(std::sync::Arc<crate::graph::ViewGraph>, ReadStats)>> {
        let g = self.graph(view)?;
        for store in discover(&view.label.worktree) {
            if let Ok(p) = read(&store, &view.label.worktree)
                && p.stats.records_read > 0
            {
                let stats = p.stats.clone();
                return Ok(Some((std::sync::Arc::new(g.with_precise(&p)), stats)));
            }
        }
        Ok(None)
    }
}

