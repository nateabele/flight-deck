//! Import resolution: which file does this import specifier land on?
//!
//! Everything here is a function of the view's *set of paths* plus a few manifests read from the
//! worktree (`elm.json`, `Cargo.toml`) and the package caches (`ELM_HOME`, `node_modules`, see
//! `pkgview`), never of parsed facts. That is deliberate: the build
//! orchestrator needs "the direct imports of the requested file" to decide parse order *before*
//! the rest of the repository has facts, and the graph needs exactly the same answer afterwards.
//! One resolver serves both, so they cannot disagree.
//!
//! A path that leaves the worktree (an Elm source directory `../tessera/designer/src`, a TypeScript
//! import `../../shared/x`) resolves to `External`: the file's path *relative to the worktree
//! root*, climbing out with `..`. Relative, because a graph is shared by every clean worktree of
//! one commit (`ViewGraph::for_worktree`) and `../tessera` means a different directory from each
//! of them; each worktree makes it absolute against its own root (`absolute`). `links.rs` turns
//! that path into a file of the linked view.

mod python;
mod swift;

pub use swift::swift_module_key;

use crate::facts::Import;
use crate::pkgview::{ModuleExports, ProjectPackages};
use std::collections::{HashMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Resolved {
    /// A file in this view (worktree-relative path). `rest` is the unresolved tail of a Rust
    /// path: items inside the file (`crate::store::open` -> file `store.rs`, rest `["open"]`).
    File { path: String, rest: Vec<String> },
    /// A file that exists on disk outside this worktree, relative to the worktree root
    /// (`../tessera/designer/src/Expression/Node.elm`).
    External(PathBuf),
    /// A module of a dependency whose exports a package view knows (`Json.Decode` from
    /// `elm/json@1.1.3`, see `pkgview`).
    Package(Arc<ModuleExports>),
    /// A package no package view covers (`lodash`, `std`) or something we could not find.
    Unresolved,
}

pub struct Resolver {
    root: PathBuf,
    /// Every path of the view. An `Arc`: an overlay that adds or removes no file shares its base's.
    paths: Arc<HashSet<String>>,
    /// Rust crate name -> its `src/lib.rs`, from every `Cargo.toml` next to a `src/lib.rs`.
    rust_crates: HashMap<String, String>,
    /// elm.json directory (relative to root, "" = root) -> that project.
    elm_projects: Mutex<HashMap<String, Option<Arc<ElmProject>>>>,
    /// Set when a lookup went outside the worktree. What it found there depends on where the
    /// worktree stands (`../lib` is a different directory from each), so a graph resolved by this
    /// resolver is exact only for the root it was resolved under.
    probed_outside: AtomicBool,
    /// Swift module name -> the module keys (directories) bearing it.
    swift_modules: HashMap<String, Vec<String>>,
    /// (importing directory, bare specifier) -> the npm package module it names (`pkgview::npm`).
    npm: Mutex<HashMap<(String, String), NpmHit>>,
}

/// A bare specifier's package module, or none (no declarations installed).
type NpmHit = Option<Arc<ModuleExports>>;

/// One `elm.json`.
struct ElmProject {
    /// Absolute-normalised source directories.
    dirs: Vec<PathBuf>,
    /// The manifest's text, for the dependencies.
    manifest: String,
    packages: OnceLock<Arc<ProjectPackages>>,
}

const TS_EXTS: &[&str] = &["ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs"];

impl Resolver {
    pub fn new(root: &Path, files: &[crate::git::FileRef]) -> Resolver {
        Resolver::with_paths(root, Arc::new(files.iter().map(|f| f.path.clone()).collect()))
    }

    /// A resolver for the view under `root` whose files are `paths` (another resolver's, shared).
    pub fn with_paths(root: &Path, paths: Arc<HashSet<String>>) -> Resolver {
        let mut rust_crates = HashMap::new();
        for p in paths.iter().filter(|p| *p == "src/lib.rs" || p.ends_with("/src/lib.rs")) {
            let dir = p.trim_end_matches("src/lib.rs").trim_end_matches('/');
            let manifest = root.join(dir).join("Cargo.toml");
            if let Some(name) = std::fs::read_to_string(manifest).ok().and_then(|t| crate_name(&t)) {
                rust_crates.insert(name.replace('-', "_"), p.clone());
            }
        }
        let swift_modules = swift::swift_module_names(paths.iter());
        Resolver { root: root.to_path_buf(), paths, rust_crates, elm_projects: Mutex::new(HashMap::new()), probed_outside: AtomicBool::new(false), swift_modules, npm: Mutex::new(HashMap::new()) }
    }

    /// Did any resolution look outside the worktree (whether or not it found anything)?
    pub fn probed_outside(&self) -> bool {
        self.probed_outside.load(Ordering::Relaxed)
    }

    /// The view's paths, to share with a resolver of the same files elsewhere (`with_paths`).
    pub fn paths(&self) -> &Arc<HashSet<String>> {
        &self.paths
    }

    pub fn has_path(&self, p: &str) -> bool {
        self.paths.contains(p)
    }

    pub fn resolve_import(&self, from: &str, language: &str, imp: &Import) -> Resolved {
        use crate::facts::ImportKind;
        match language {
            "elm" => self.elm_module(from, &imp.specifier),
            "python" => self.python_module(from, &imp.specifier),
            "typescript" | "tsx" | "javascript" => self.ts_specifier(from, &imp.specifier),
            "rust" => {
                if imp.kind == ImportKind::ModDecl {
                    return self.rust_mod_decl(from, &imp.specifier, imp.alias.as_deref());
                }
                let segs: Vec<String> = imp.specifier.split("::").filter(|s| !s.is_empty()).map(String::from).collect();
                self.rust_path(from, &segs)
            }
            _ => Resolved::Unresolved,
        }
    }

    // ---- Elm ---------------------------------------------------------------------------

    /// The nearest `elm.json` above `from`, parsed once per directory.
    fn elm_project(&self, from: &str) -> Option<Arc<ElmProject>> {
        let mut dir = Path::new(from).parent();
        while let Some(d) = dir {
            let key = d.to_string_lossy().to_string();
            let mut cache = self.elm_projects.lock().unwrap();
            let entry = cache.entry(key).or_insert_with(|| {
                let manifest = self.root.join(d).join("elm.json");
                let text = std::fs::read_to_string(manifest).ok()?;
                let json: serde_json::Value = serde_json::from_str(&text).ok()?;
                // Packages have no source-directories and always use `src`.
                let dirs: Vec<String> = match json.get("source-directories").and_then(|v| v.as_array()) {
                    Some(a) => a.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
                    None => vec!["src".to_string()],
                };
                let dirs = dirs.iter().map(|s| normalize(&self.root.join(d).join(s))).collect();
                Some(Arc::new(ElmProject { dirs, manifest: text, packages: OnceLock::new() }))
            });
            if let Some(p) = entry.clone() {
                return Some(p);
            }
            drop(cache);
            dir = d.parent();
        }
        None
    }

    /// Source directories of the nearest `elm.json` above `from`, as normalised absolute paths.
    fn elm_source_dirs(&self, from: &str) -> Option<Vec<PathBuf>> {
        self.elm_project(from).map(|p| p.dirs.clone())
    }

    /// The package modules the nearest `elm.json` above `from` can import, read from the
    /// package caches on first use: once per project per resolver, and each docs.json once per
    /// process (`pkgview`).
    pub fn elm_packages(&self, from: &str) -> Option<Arc<ProjectPackages>> {
        let p = self.elm_project(from)?;
        Some(p.packages.get_or_init(|| Arc::new(crate::pkgview::elm_project_packages(&p.manifest, crate::pkgview::elm_home().as_deref()))).clone())
    }

    fn elm_module(&self, from: &str, module: &str) -> Resolved {
        let rel_file = format!("{}.elm", module.replace('.', "/"));
        if let Some(dirs) = self.elm_source_dirs(from) {
            for d in dirs {
                let candidate = d.join(&rel_file);
                if let Ok(inside) = candidate.strip_prefix(&self.root) {
                    let key = inside.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
                    if self.paths.contains(&key) {
                        return Resolved::File { path: key, rest: vec![] };
                    }
                } else {
                    self.probed_outside.store(true, Ordering::Relaxed);
                    if candidate.is_file() {
                        return Resolved::External(relative_to(&candidate, &self.root));
                    }
                }
            }
            // Not a source file anywhere: a dependency's module, if a package view has it.
            if let Some(m) = self.elm_packages(from).and_then(|p| p.modules.get(module).cloned()) {
                return Resolved::Package(m);
            }
            return Resolved::Unresolved;
        }
        // No elm.json: any ancestor directory may be the source root.
        let mut dir = Path::new(from).parent();
        while let Some(d) = dir {
            let key = join_rel(d, &rel_file);
            if self.paths.contains(&key) {
                return Resolved::File { path: key, rest: vec![] };
            }
            dir = d.parent();
        }
        Resolved::Unresolved
    }

    // ---- TypeScript / JavaScript -------------------------------------------------------

    fn ts_specifier(&self, from: &str, spec: &str) -> Resolved {
        if !(spec.starts_with("./") || spec.starts_with("../") || spec == "." || spec == "..") {
            return self.npm_module(from, spec);
        }
        let base = normalize_rel(&join_rel(Path::new(from).parent().unwrap_or(Path::new("")), spec));
        let Some(base) = base else { return self.ts_external(from, spec) };
        let found = self.ts_candidates(&base).into_iter().find(|c| self.paths.contains(c));
        match found {
            Some(path) => Resolved::File { path, rest: vec![] },
            None => Resolved::Unresolved,
        }
    }

    /// A bare specifier: the package module whose declarations the nearest `node_modules` holds
    /// (see `pkgview::npm`), once per directory and specifier. `node_modules` is read where it
    /// is, under this worktree's root, and never above it.
    fn npm_module(&self, from: &str, spec: &str) -> Resolved {
        if spec.is_empty() || spec.starts_with('/') || spec.contains(':') && !spec.starts_with("node:") {
            return Resolved::Unresolved;
        }
        let dir = Path::new(from).parent().unwrap_or(Path::new("")).to_string_lossy().to_string();
        let key = (dir, spec.to_string());
        if let Some(m) = self.npm.lock().unwrap().get(&key) {
            return m.clone().map_or(Resolved::Unresolved, Resolved::Package);
        }
        let m = crate::pkgview::npm::resolve(&self.root, &self.root.join(&key.0), spec);
        self.npm.lock().unwrap().insert(key, m.clone());
        m.map_or(Resolved::Unresolved, Resolved::Package)
    }

    /// A relative import that climbs out of the worktree (`../../shared/util`): a file of the
    /// directory it names, whichever checkout that is. Only a file that exists counts.
    fn ts_external(&self, from: &str, spec: &str) -> Resolved {
        self.probed_outside.store(true, Ordering::Relaxed);
        let abs = absolute(&self.root, &Path::new(from).parent().unwrap_or(Path::new("")).join(spec));
        let found = self.ts_candidates(&abs.to_string_lossy()).into_iter().map(PathBuf::from).find(|c| c.is_file());
        match found {
            Some(file) => Resolved::External(relative_to(&file, &self.root)),
            None => Resolved::Unresolved,
        }
    }

    fn ts_candidates(&self, base: &str) -> Vec<String> {
        let mut out = vec![base.to_string()];
        // `import './x.js'` in TypeScript means `./x.ts`.
        for (from_ext, to_exts) in [(".js", &["ts", "tsx"][..]), (".jsx", &["tsx"]), (".mjs", &["mts"]), (".cjs", &["cts"])] {
            if let Some(stem) = base.strip_suffix(from_ext) {
                out.extend(to_exts.iter().map(|e| format!("{stem}.{e}")));
            }
        }
        out.extend(TS_EXTS.iter().map(|e| format!("{base}.{e}")));
        out.extend(TS_EXTS.iter().map(|e| format!("{}/index.{e}", base.trim_end_matches('/'))));
        out
    }

    // ---- Rust --------------------------------------------------------------------------

    /// `mod foo;` in `from`: `<dir>/foo.rs` or `<dir>/foo/mod.rs`, where `<dir>` depends on whether
    /// `from` is a module-root file (`lib.rs`, `main.rs`, `mod.rs`) or a plain `x.rs`.
    /// `mod name;` in `from`. `path` is its `#[path = "..."]`, relative to `from`'s own directory
    /// (the rule for a declaration outside an inline module); a path that names no file of the
    /// view falls back to the usual places.
    fn rust_mod_decl(&self, from: &str, name: &str, path: Option<&str>) -> Resolved {
        if let Some(p) = path
            && let Some(cand) = normalize_rel(&join_rel(Path::new(from).parent().unwrap_or(Path::new("")), p))
            && self.paths.contains(&cand)
        {
            return Resolved::File { path: cand, rest: vec![] };
        }
        let dir = rust_child_dir(from);
        for cand in [join_rel(Path::new(&dir), &format!("{name}.rs")), join_rel(Path::new(&dir), &format!("{name}/mod.rs"))] {
            if self.paths.contains(&cand) {
                return Resolved::File { path: cand, rest: vec![] };
            }
        }
        Resolved::Unresolved
    }

    /// The crate root file (`…/src/lib.rs` or `main.rs`) a Rust file belongs to, and its module
    /// path from that root.
    pub fn rust_crate_of(&self, file: &str) -> Option<(String, Vec<String>)> {
        // A file under src/bin/ or tests/ etc. is a root of its own.
        let own_root = file.contains("/bin/") && file.contains("src/")
            || file.starts_with("tests/") || file.contains("/tests/")
            || file.starts_with("examples/") || file.contains("/examples/")
            || file.starts_with("benches/") || file.contains("/benches/");
        if own_root {
            return Some((file.to_string(), vec![]));
        }
        let mut dir = Path::new(file).parent();
        while let Some(d) = dir {
            if d.file_name().is_some_and(|n| n == "src") || d.as_os_str().is_empty() {
                for root_name in ["lib.rs", "main.rs"] {
                    let cand = join_rel(d, root_name);
                    if self.paths.contains(&cand) {
                        let rel = Path::new(file).strip_prefix(d).ok()?;
                        let mut segs: Vec<String> =
                            rel.components().map(|c| c.as_os_str().to_string_lossy().to_string()).collect();
                        let last = segs.pop()?;
                        let stem = last.trim_end_matches(".rs");
                        if stem != "mod" && cand != file {
                            segs.push(stem.to_string());
                        }
                        if cand == file {
                            segs.clear();
                        }
                        return Some((cand, segs));
                    }
                }
            }
            dir = d.parent();
        }
        None
    }

    /// Resolve a Rust path (as written in a `use` or an expression) from file `from`: walk the
    /// leading segments through module files for as long as they exist; whatever is left names
    /// items inside the last file reached.
    pub fn rust_path(&self, from: &str, segs: &[String]) -> Resolved {
        let Some(first) = segs.first() else { return Resolved::Unresolved };
        let Some((crate_root, module)) = self.rust_crate_of(from) else {
            return Resolved::Unresolved;
        };
        let (mut cur, mut rest): (String, &[String]) = match first.as_str() {
            "crate" => (crate_root.clone(), &segs[1..]),
            "self" => (from.to_string(), &segs[1..]),
            "super" => {
                let mut module = module.clone();
                let mut rest = segs;
                while rest.first().is_some_and(|s| s == "super") {
                    module.pop();
                    rest = &rest[1..];
                }
                match self.rust_file_for_module(&crate_root, &module) {
                    Some(f) => (f, rest),
                    None => return Resolved::Unresolved,
                }
            }
            other => {
                if let Some(lib) = self.rust_crates.get(other) {
                    (lib.clone(), &segs[1..])
                } else {
                    // 2018 relative path: `use child::item` where `child` is a module of this file.
                    let dir = rust_child_dir(from);
                    let is_child = [join_rel(Path::new(&dir), &format!("{other}.rs")), join_rel(Path::new(&dir), &format!("{other}/mod.rs"))]
                        .iter()
                        .any(|c| self.paths.contains(c));
                    if is_child { (from.to_string(), segs) } else { return Resolved::Unresolved }
                }
            }
        };
        // Descend through child modules.
        while let Some(seg) = rest.first() {
            match self.rust_mod_decl(&cur, seg, None) {
                Resolved::File { path, .. } => {
                    cur = path;
                    rest = &rest[1..];
                }
                _ => break,
            }
        }
        Resolved::File { path: cur, rest: rest.to_vec() }
    }

    fn rust_file_for_module(&self, crate_root: &str, module: &[String]) -> Option<String> {
        let mut cur = crate_root.to_string();
        for seg in module {
            match self.rust_mod_decl(&cur, seg, None) {
                Resolved::File { path, .. } => cur = path,
                _ => return None,
            }
        }
        Some(cur)
    }
}

/// Directory holding a Rust file's child modules: beside `lib.rs`/`main.rs`/`mod.rs`, inside a
/// same-named directory for a plain `x.rs`.
fn rust_child_dir(file: &str) -> String {
    let p = Path::new(file);
    let parent = p.parent().unwrap_or(Path::new(""));
    match p.file_name().and_then(|n| n.to_str()) {
        Some("lib.rs" | "main.rs" | "mod.rs") => parent.to_string_lossy().to_string(),
        _ => parent.join(p.file_stem().unwrap_or_default()).to_string_lossy().to_string(),
    }
}

fn crate_name(cargo_toml: &str) -> Option<String> {
    let mut section = "";
    let mut package = None;
    let mut lib = None;
    for line in cargo_toml.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            section = line;
        } else if let Some(v) = line.strip_prefix("name") {
            let v = v.trim_start().strip_prefix('=')?.trim().trim_matches('"').to_string();
            match section {
                "[package]" => package = Some(v),
                "[lib]" => lib = Some(v),
                _ => {}
            }
        }
    }
    lib.or(package)
}

fn join_rel(dir: &Path, rel: &str) -> String {
    let joined = dir.join(rel);
    joined.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/")
}

/// Collapse `.` and `..` lexically (symlinks are never followed: a link must not pull foreign
/// files into a view).
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// `rel` made absolute against `root`, with `.` and `..` collapsed lexically: where an
/// `External` path lands for the worktree at `root`.
pub(crate) fn absolute(root: &Path, rel: &Path) -> PathBuf {
    normalize(&root.join(rel))
}

/// `abs` relative to `base` (both normalised absolute paths), climbing with `..` where `abs` is
/// not under `base`.
pub(crate) fn relative_to(abs: &Path, base: &Path) -> PathBuf {
    let (a, b): (Vec<_>, Vec<_>) = (abs.components().collect(), base.components().collect());
    let common = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let mut out: PathBuf = std::iter::repeat_n("..", b.len() - common).collect();
    out.extend(a[common..].iter().map(|c| c.as_os_str()));
    out
}

/// Like `normalize` for a worktree-relative path; `None` if it climbs out of the root.
fn normalize_rel(p: &str) -> Option<String> {
    let mut parts: Vec<&str> = Vec::new();
    for seg in p.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            s => parts.push(s),
        }
    }
    Some(parts.join("/"))
}
