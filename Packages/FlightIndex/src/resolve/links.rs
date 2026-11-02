//! Imports through manifest links: the names a manifest gives to code in another directory.
//!
//! `links.rs` finds which repositories a view's manifests point into; this module makes imports
//! *through* those manifests land on files. Four kinds, each read from the manifests of the view
//! (never from parsed facts, like the rest of the resolver):
//!
//! - **Cargo path dependencies.** `dep = { path = "../dep" }` (or `[dependencies.dep]`,
//!   `[workspace.dependencies]`) makes `use dep::store::open` start at that crate's root file
//!   (`[lib] path`, else `src/lib.rs`) and walk its modules on disk.
//! - **npm package names.** A `package.json` `file:`/`link:` dependency, or a member of a
//!   `workspaces` / `pnpm-workspace.yaml` glob, makes `import { x } from "name"` or
//!   `"name/sub/path"` land in that package's source: its `source`/`types`/`exports`/`module`/
//!   `main` entry (a `dist/`, `lib/`, `build/` or `out/` entry is tried under `src/` first, since
//!   built output is not indexed), else `src/index`, `index`.
//! - **tsconfig `paths`.** The nearest directory with a `tsconfig.json` or `tsconfig.*.json`
//!   (Vite keeps `paths` in `tsconfig.app.json`) gives the aliases, following relative `extends`;
//!   the longest matching pattern wins, as in `tsc`. An explicit `baseUrl` also resolves bare
//!   specifiers under it.
//! - **mix path dependencies.** Elixir modules do not map to paths (`CALCEngine` lives in
//!   `lib/calc.ex`, not `lib/calc_engine.ex`), so each path dependency's `lib/` is scanned once
//!   for `defmodule` lines and a module name is looked up in that table.
//!
//! A target inside the worktree resolves to `Resolved::File` (a workspace package is usually in the
//! same repository); one outside to `Resolved::External`, which `links::Views` follows into the
//! linked view. Anything read outside the worktree marks the resolver `probed_outside`.

use super::{absolute, crate_name, normalize, relative_to, Resolved, Resolver};
use regex::Regex;
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex, OnceLock};

/// Most `defmodule` files scanned in one mix path dependency: a bound on a pathological target
/// (a dependency pointing at a home directory), far above any real library.
const MIX_SCAN_LIMIT: usize = 5000;

#[derive(Default)]
pub(super) struct LinkState {
    tables: OnceLock<Tables>,
    /// Directory (worktree-relative, "" = root) -> the tsconfig files there, merged; `None` when
    /// the directory has none.
    tsconfig: Mutex<HashMap<String, Option<Arc<TsPaths>>>>,
    /// Module -> absolute file, over every mix path dependency outside the worktree.
    elixir: OnceLock<HashMap<String, PathBuf>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum CrateRoot {
    /// A crate root file in this view (worktree-relative).
    Inside(String),
    /// One outside the worktree (absolute).
    Outside(PathBuf),
}

#[derive(Default)]
struct Tables {
    /// Crate name as code writes it (`-` as `_`) -> its root file.
    rust: HashMap<String, CrateRoot>,
    /// npm package name -> absolute package directory, longest names first.
    npm: Vec<(String, PathBuf)>,
    /// Absolute directories of mix path dependencies outside the worktree.
    mix: Vec<PathBuf>,
}

#[derive(Default)]
struct TsPaths {
    /// `(pattern, absolute targets)`; a pattern has at most one `*`.
    paths: Vec<(String, Vec<String>)>,
    base: Option<PathBuf>,
}

impl Resolver {
    fn link_tables(&self) -> &Tables {
        self.links.tables.get_or_init(|| self.read_link_tables())
    }

    /// Every directory of the view that holds an indexed file, and their ancestors: where a
    /// manifest may be (manifests are not indexed files themselves).
    fn manifest_dirs(&self) -> BTreeSet<String> {
        let mut dirs: BTreeSet<String> = BTreeSet::from([String::new()]);
        for p in self.paths.iter() {
            let mut d = Path::new(p).parent();
            while let Some(x) = d {
                if x.as_os_str().is_empty() || !dirs.insert(x.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/")) {
                    break;
                }
                d = x.parent();
            }
        }
        dirs
    }

    fn read_link_tables(&self) -> Tables {
        let mut t = Tables::default();
        let mut npm: Vec<(String, PathBuf)> = Vec::new();
        let mix_path = Regex::new(r#"path:\s*"([^"]+)""#).expect("static regex");
        for d in self.manifest_dirs() {
            let dir = self.root.join(&d);
            if let Ok(text) = std::fs::read_to_string(dir.join("Cargo.toml")) {
                for (key, path, renamed) in cargo_path_deps(&text) {
                    let target = normalize(&dir.join(&path));
                    let Ok(manifest) = std::fs::read_to_string(target.join("Cargo.toml")) else { continue };
                    // A renamed dependency is written by its key; otherwise by the target's lib name.
                    let name = if renamed { key } else { crate_name(&manifest).unwrap_or(key) }.replace('-', "_");
                    let root_file = normalize(&target.join(lib_path(&manifest)));
                    let entry = match root_file.strip_prefix(&self.root) {
                        Ok(rel) => {
                            let rel = rel.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
                            if !self.paths.contains(&rel) {
                                continue;
                            }
                            CrateRoot::Inside(rel)
                        }
                        Err(_) => {
                            self.probed_outside.store(true, Ordering::Relaxed);
                            if !root_file.is_file() {
                                continue;
                            }
                            CrateRoot::Outside(root_file)
                        }
                    };
                    t.rust.entry(name).or_insert(entry);
                }
            }
            if let Ok(text) = std::fs::read_to_string(dir.join("package.json"))
                && let Ok(j) = serde_json::from_str::<serde_json::Value>(&text)
            {
                for section in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
                    for (key, v) in j.get(section).and_then(|d| d.as_object()).into_iter().flatten() {
                        let Some(p) = v.as_str().and_then(|s| s.strip_prefix("file:").or_else(|| s.strip_prefix("link:"))) else { continue };
                        let target = normalize(&dir.join(p));
                        if !target.starts_with(&self.root) {
                            self.probed_outside.store(true, Ordering::Relaxed);
                        }
                        if target.is_dir() {
                            npm.push((key.clone(), target));
                        }
                    }
                }
                let ws = match j.get("workspaces") {
                    Some(serde_json::Value::Array(a)) => a.iter().filter_map(|x| x.as_str().map(String::from)).collect(),
                    Some(w) => w.get("packages").and_then(|p| p.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default(),
                    None => Vec::new(),
                };
                npm.extend(self.workspace_packages(&dir, &ws));
            }
            if let Ok(text) = std::fs::read_to_string(dir.join("pnpm-workspace.yaml")) {
                npm.extend(self.workspace_packages(&dir, &pnpm_packages(&text)));
            }
            if let Ok(text) = std::fs::read_to_string(dir.join("mix.exs")) {
                for c in mix_path.captures_iter(&text) {
                    let target = normalize(&dir.join(&c[1]));
                    if !target.starts_with(&self.root) {
                        self.probed_outside.store(true, Ordering::Relaxed);
                        if target.join("lib").is_dir() && !t.mix.contains(&target) {
                            t.mix.push(target);
                        }
                    }
                }
            }
        }
        // First declaration of a name wins (manifests in path order); then longest name first, so
        // `@scope/pkg-extra` is tried before `@scope/pkg`.
        let mut seen = std::collections::HashSet::new();
        npm.retain(|(n, _)| seen.insert(n.clone()));
        npm.sort_by(|a, b| b.0.len().cmp(&a.0.len()).then(a.0.cmp(&b.0)));
        t.npm = npm;
        t
    }

    /// The packages (`name`, directory) the workspace globs of the manifest in `dir` cover.
    fn workspace_packages(&self, dir: &Path, globs: &[String]) -> Vec<(String, PathBuf)> {
        let mut out = Vec::new();
        for g in globs.iter().filter(|g| !g.starts_with('!')) {
            let segs: Vec<&str> = g.trim_start_matches("./").split('/').filter(|s| !s.is_empty() && *s != ".").collect();
            let mut found = Vec::new();
            expand_glob(&normalize(dir), &segs, 0, &mut found);
            for d in found {
                if !d.starts_with(&self.root) {
                    self.probed_outside.store(true, Ordering::Relaxed);
                }
                let name = std::fs::read_to_string(d.join("package.json"))
                    .ok()
                    .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
                    .and_then(|j| j.get("name").and_then(|n| n.as_str()).map(String::from));
                if let Some(name) = name {
                    out.push((name, d));
                }
            }
        }
        out
    }

    // ---- Rust ----------------------------------------------------------------------------

    /// A Cargo path dependency inside the view that `rust_crates` does not know by this name
    /// (a renamed one): its root file.
    pub(super) fn rust_linked_inside(&self, name: &str) -> Option<String> {
        match self.link_tables().rust.get(name)? {
            CrateRoot::Inside(rel) => Some(rel.clone()),
            CrateRoot::Outside(_) => None,
        }
    }

    /// A Rust path whose first segment is a Cargo path dependency outside the worktree: the file
    /// it reaches (relative to the root, as `Resolved::External`) and what is left of it.
    pub fn rust_external(&self, segs: &[String]) -> Option<(PathBuf, Vec<String>)> {
        let first = segs.first()?;
        if self.rust_crates.contains_key(first) {
            return None;
        }
        let CrateRoot::Outside(root_file) = self.link_tables().rust.get(first)? else { return None };
        Some(self.rust_walk_outside(root_file, &segs[1..]))
    }

    /// From a file outside the worktree (`External` path), down its child modules on disk.
    pub fn rust_external_from(&self, file: &Path, segs: &[String]) -> (PathBuf, Vec<String>) {
        self.rust_walk_outside(&absolute(&self.root, file), segs)
    }

    fn rust_walk_outside(&self, start: &Path, segs: &[String]) -> (PathBuf, Vec<String>) {
        self.probed_outside.store(true, Ordering::Relaxed);
        let mut cur = start.to_path_buf();
        let mut rest = segs;
        while let Some(seg) = rest.first() {
            let dir = match cur.file_name().and_then(|n| n.to_str()) {
                Some("lib.rs" | "main.rs" | "mod.rs") => cur.parent().map(Path::to_path_buf).unwrap_or_default(),
                _ => cur.with_extension(""),
            };
            match [dir.join(format!("{seg}.rs")), dir.join(seg).join("mod.rs")].into_iter().find(|c| c.is_file()) {
                Some(next) => {
                    cur = next;
                    rest = &rest[1..];
                }
                None => break,
            }
        }
        (relative_to(&cur, &self.root), rest.to_vec())
    }

    // ---- TypeScript ----------------------------------------------------------------------

    /// A specifier that is neither relative nor absolute: a tsconfig alias, a path under an
    /// explicit `baseUrl`, or a package of the view's workspaces and path dependencies.
    pub(super) fn ts_bare(&self, from: &str, spec: &str) -> Resolved {
        if let Some(cfg) = self.ts_config(from) {
            let best = cfg
                .paths
                .iter()
                .filter_map(|(pat, targets)| match pat.split_once('*') {
                    None => (pat == spec).then_some((pat.len(), "", targets)),
                    Some((pre, suf)) => (spec.len() >= pre.len() + suf.len() && spec.starts_with(pre) && spec.ends_with(suf))
                        .then(|| (pre.len(), &spec[pre.len()..spec.len() - suf.len()], targets)),
                })
                .max_by_key(|(n, _, _)| *n);
            if let Some((_, star, targets)) = best {
                for t in targets {
                    if let Some(r) = self.ts_find(Path::new(&t.replacen('*', star, 1))) {
                        return r;
                    }
                }
            }
            if let Some(base) = &cfg.base
                && let Some(r) = self.ts_find(&base.join(spec))
            {
                return r;
            }
        }
        let tables = self.link_tables();
        for (name, dir) in &tables.npm {
            let sub = if spec == name {
                ""
            } else if let Some(s) = spec.strip_prefix(name.as_str()).and_then(|s| s.strip_prefix('/')) {
                s
            } else {
                continue;
            };
            let cands: Vec<PathBuf> = if sub.is_empty() { package_entries(dir).into_iter().map(|e| dir.join(e)).collect() } else { vec![dir.join(sub), dir.join("src").join(sub)] };
            return cands.iter().find_map(|c| self.ts_find(c)).unwrap_or(Resolved::Unresolved);
        }
        Resolved::Unresolved
    }

    /// The file an absolute import base names: a file of this view, or a source file outside it
    /// (never a declaration file or something under `node_modules`).
    fn ts_find(&self, base: &Path) -> Option<Resolved> {
        let base = normalize(base);
        if let Ok(rel) = base.strip_prefix(&self.root) {
            let rel = rel.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
            return self.ts_candidates(&rel).into_iter().find(|c| self.paths.contains(c) && !c.ends_with(".d.ts")).map(|path| Resolved::File { path, rest: vec![] });
        }
        self.probed_outside.store(true, Ordering::Relaxed);
        self.ts_candidates(&base.to_string_lossy())
            .into_iter()
            .map(PathBuf::from)
            .find(|c| !c.to_string_lossy().ends_with(".d.ts") && !c.components().any(|x| x.as_os_str() == "node_modules") && c.is_file())
            .map(|f| Resolved::External(relative_to(&f, &self.root)))
    }

    /// The tsconfig paths in force for `from`: those of the nearest directory above it that has
    /// any tsconfig file.
    fn ts_config(&self, from: &str) -> Option<Arc<TsPaths>> {
        let mut dir = Path::new(from).parent();
        while let Some(d) = dir {
            let key = d.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/");
            let got = self.links.tsconfig.lock().unwrap().entry(key).or_insert_with(|| read_tsconfigs(&self.root.join(d))).clone();
            if got.is_some() {
                return got;
            }
            dir = d.parent();
        }
        None
    }

    // ---- Elixir --------------------------------------------------------------------------

    /// The file outside the worktree that defines `module`, in one of the view's mix path
    /// dependencies (relative to the root, as `Resolved::External`).
    pub fn elixir_external(&self, module: &str) -> Option<PathBuf> {
        let tables = self.link_tables();
        if tables.mix.is_empty() {
            return None;
        }
        self.probed_outside.store(true, Ordering::Relaxed);
        let map = self.links.elixir.get_or_init(|| scan_mix_modules(&tables.mix));
        map.get(module).map(|f| relative_to(f, &self.root))
    }
}

/// `(key, path, renamed)` of every path dependency in a `Cargo.toml`: inline tables in any
/// `…dependencies` section (`[workspace.dependencies]` and target-specific ones included), and
/// `[dependencies.key]` tables.
fn cargo_path_deps(text: &str) -> Vec<(String, String, bool)> {
    let path_re = Regex::new(r#"\bpath\s*=\s*"([^"]+)""#).expect("static regex");
    let pkg_re = Regex::new(r#"\bpackage\s*=\s*""#).expect("static regex");
    let mut out = Vec::new();
    let mut section = String::new();
    // `[dependencies.key]`: (key, path, renamed) gathered over the table's lines.
    let mut table: Option<(String, Option<String>, bool)> = None;
    let flush = |table: &mut Option<(String, Option<String>, bool)>, out: &mut Vec<(String, String, bool)>| {
        if let Some((k, Some(p), r)) = table.take() {
            out.push((k, p, r));
        }
    };
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            flush(&mut table, &mut out);
            section = line.trim_matches(|c| c == '[' || c == ']').to_string();
            if let Some((head, key)) = section.rsplit_once('.')
                && head.ends_with("dependencies")
            {
                table = Some((key.trim_matches('"').to_string(), None, false));
            }
            continue;
        }
        if let Some((_, p, r)) = &mut table {
            if let Some(c) = path_re.captures(line).filter(|_| line.starts_with("path")) {
                *p = Some(c[1].to_string());
            }
            *r |= line.starts_with("package");
            continue;
        }
        if !section.ends_with("dependencies") {
            continue;
        }
        if let Some((key, value)) = line.split_once('=')
            && let Some(c) = path_re.captures(value)
        {
            out.push((key.trim().trim_matches('"').to_string(), c[1].to_string(), pkg_re.is_match(value)));
        }
    }
    flush(&mut table, &mut out);
    out
}

/// A crate's root file relative to its directory: `[lib] path`, else `src/lib.rs`.
fn lib_path(manifest: &str) -> String {
    let mut section = "";
    for line in manifest.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            section = line;
        } else if section == "[lib]"
            && let Some(v) = line.strip_prefix("path")
            && let Some(v) = v.trim_start().strip_prefix('=')
        {
            return v.trim().trim_matches('"').to_string();
        }
    }
    "src/lib.rs".to_string()
}

/// The `packages:` list of a `pnpm-workspace.yaml` (block style, as pnpm writes it).
fn pnpm_packages(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut inside = false;
    for line in text.lines() {
        if !line.starts_with([' ', '\t', '-']) {
            inside = line.trim_end() == "packages:";
            continue;
        }
        if inside && let Some(item) = line.trim().strip_prefix('-') {
            out.push(item.trim().trim_matches(|c| c == '\'' || c == '"').to_string());
        }
    }
    out
}

/// Directories under `base` that the glob segments match (`*` within a segment, `**` any depth up
/// to a few levels), skipping `node_modules` and hidden directories.
fn expand_glob(base: &Path, segs: &[&str], depth: usize, out: &mut Vec<PathBuf>) {
    let Some((seg, rest)) = segs.split_first() else {
        out.push(base.to_path_buf());
        return;
    };
    if *seg == ".." {
        return expand_glob(&normalize(&base.join("..")), rest, depth, out);
    }
    if !seg.contains('*') {
        let next = base.join(seg);
        if next.is_dir() {
            expand_glob(&next, rest, depth, out);
        }
        return;
    }
    if depth > 4 {
        return;
    }
    let Ok(rd) = std::fs::read_dir(base) else { return };
    let mut children: Vec<PathBuf> = rd
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.path())
        .filter(|p| p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n != "node_modules" && !n.starts_with('.')))
        .collect();
    children.sort();
    if *seg == "**" {
        expand_glob(base, rest, depth + 1, out);
        for c in children {
            expand_glob(&c, segs, depth + 1, out);
        }
        return;
    }
    for c in children {
        if c.file_name().and_then(|n| n.to_str()).is_some_and(|n| wildcard(seg, n)) {
            expand_glob(&c, rest, depth + 1, out);
        }
    }
}

/// `*` matches any run of characters within one path segment.
fn wildcard(pat: &str, s: &str) -> bool {
    let parts: Vec<&str> = pat.split('*').collect();
    let (first, last) = (parts[0], parts[parts.len() - 1]);
    if !s.starts_with(first) || s.len() < first.len() + last.len() || !s.ends_with(last) {
        return false;
    }
    let mut at = first.len();
    for p in &parts[1..parts.len() - 1] {
        match s[at..s.len() - last.len()].find(p) {
            Some(i) => at += i + p.len(),
            None => return false,
        }
    }
    true
}

/// Where a package's source starts, relative to its directory, most specific first. Built
/// entries (`dist/index.js`) are tried as their `src/` twin first: built output is not indexed.
fn package_entries(dir: &Path) -> Vec<String> {
    let j = std::fs::read_to_string(dir.join("package.json")).ok().and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok());
    let mut raw: Vec<String> = Vec::new();
    if let Some(j) = &j {
        for k in ["source", "types", "typings", "module", "main"] {
            if let Some(s) = j.get(k).and_then(|v| v.as_str()) {
                raw.push(s.to_string());
            }
        }
        let dot = j.get("exports").map(|e| e.get(".").unwrap_or(e));
        let mut strings = |v: &serde_json::Value| {
            if let Some(s) = v.as_str() {
                raw.push(s.to_string());
            }
        };
        if let Some(e) = dot {
            strings(e);
            for k in ["types", "import", "default", "require"] {
                if let Some(v) = e.get(k) {
                    strings(v);
                    for k2 in ["types", "default"] {
                        if let Some(v2) = v.get(k2) {
                            strings(v2);
                        }
                    }
                }
            }
        }
    }
    let mut out: Vec<String> = Vec::new();
    for e in raw {
        let e = e.trim_start_matches("./");
        let stem = e.strip_suffix(".d.ts").unwrap_or(e);
        if let Some((top, rest)) = stem.split_once('/')
            && matches!(top, "dist" | "lib" | "build" | "out")
        {
            out.push(format!("src/{rest}"));
        }
        out.push(stem.to_string());
    }
    out.extend(["src/index".to_string(), "index".to_string()]);
    let mut seen = std::collections::HashSet::new();
    out.retain(|e| seen.insert(e.clone()));
    out
}

/// The tsconfig files of one directory (`tsconfig.json`, then `tsconfig.*.json` by name), merged:
/// the first to give a pattern or a `baseUrl` wins. `None` when the directory has none.
fn read_tsconfigs(dir: &Path) -> Option<Arc<TsPaths>> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n.starts_with("tsconfig.") && n.ends_with(".json") && n != "tsconfig.json")
        .collect();
    names.sort();
    if dir.join("tsconfig.json").is_file() {
        names.insert(0, "tsconfig.json".to_string());
    }
    if names.is_empty() {
        return None;
    }
    let mut out = TsPaths::default();
    for n in names {
        merge_tsconfig(&dir.join(n), &mut out, 0);
    }
    Some(Arc::new(out))
}

/// One tsconfig file into `out`, then what it `extends` (relative paths only; a package such as
/// `@tsconfig/node20` sets no paths).
fn merge_tsconfig(file: &Path, out: &mut TsPaths, depth: u8) {
    let Some(j) = std::fs::read_to_string(file).ok().and_then(|t| serde_json::from_str::<serde_json::Value>(&crate::links::strip_jsonc(&t)).ok()) else { return };
    let dir = file.parent().unwrap_or(Path::new(""));
    let opts = j.get("compilerOptions");
    let base = opts.and_then(|o| o.get("baseUrl")).and_then(|b| b.as_str()).map(|b| normalize(&dir.join(b)));
    if let Some(paths) = opts.and_then(|o| o.get("paths")).and_then(|p| p.as_object()) {
        // `paths` are relative to `baseUrl` when one is set (here or inherited), else to this file.
        let anchor = base.clone().or_else(|| out.base.clone()).unwrap_or_else(|| dir.to_path_buf());
        for (pat, targets) in paths {
            if out.paths.iter().any(|(p, _)| p == pat) {
                continue;
            }
            let abs: Vec<String> = targets.as_array().into_iter().flatten().filter_map(|t| t.as_str()).map(|t| normalize(&anchor.join(t)).to_string_lossy().to_string()).collect();
            out.paths.push((pat.clone(), abs));
        }
    }
    if out.base.is_none() {
        out.base = base;
    }
    let extends: Vec<String> = match j.get("extends") {
        Some(serde_json::Value::String(s)) => vec![s.clone()],
        Some(serde_json::Value::Array(a)) => a.iter().filter_map(|x| x.as_str().map(String::from)).collect(),
        _ => Vec::new(),
    };
    for e in extends.iter().filter(|e| e.starts_with('.')) {
        if depth < 4 {
            let p = dir.join(e);
            let p = if p.extension().is_some_and(|x| x == "json") { p } else { p.with_extension("json") };
            merge_tsconfig(&normalize(&p), out, depth + 1);
        }
    }
}

/// Module -> file over the `lib/` of each mix path dependency, from the `defmodule` lines. A
/// nested `defmodule` is named after the modules around it, as the Elixir extractor names it.
fn scan_mix_modules(dirs: &[PathBuf]) -> HashMap<String, PathBuf> {
    let re = Regex::new(r"^(\s*)(?:defmodule|defprotocol)\s+([A-Z][\w.]*)\s+do\b").expect("static regex");
    let mut out = HashMap::new();
    for dir in dirs {
        let mut files = Vec::new();
        let mut stack = vec![dir.join("lib")];
        while let Some(d) = stack.pop() {
            let Ok(rd) = std::fs::read_dir(&d) else { continue };
            for e in rd.filter_map(|e| e.ok()) {
                let p = e.path();
                if e.file_type().is_ok_and(|t| t.is_dir()) {
                    stack.push(p);
                } else if p.extension().is_some_and(|x| x == "ex") && files.len() < MIX_SCAN_LIMIT {
                    files.push(p);
                }
            }
        }
        files.sort();
        for f in files {
            let Ok(text) = std::fs::read_to_string(&f) else { continue };
            let mut open: Vec<(usize, String)> = Vec::new();
            for line in text.lines() {
                let Some(c) = re.captures(line) else { continue };
                let indent = c[1].len();
                while open.last().is_some_and(|(i, _)| *i >= indent) {
                    open.pop();
                }
                let full = match open.last() {
                    Some((_, parent)) => format!("{parent}.{}", &c[2]),
                    None => c[2].to_string(),
                };
                out.entry(full.clone()).or_insert_with(|| f.clone());
                open.push((indent, full));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cargo_path_deps_inline_tables_and_renames() {
        let text = "[package]\nname = \"x\"\n[lib]\npath = \"src/lib.rs\"\n[dependencies]\na-b = { path = \"../a\" }\nc = { package = \"real-c\", path = \"../c\" }\nd = \"1\"\n[dev-dependencies.e]\npath = \"../e\"\n[workspace.dependencies]\nf = { version = \"1\", path = \"crates/f\" }\n[target.'cfg(unix)'.dependencies]\ng = { path = \"../g\" }\n";
        assert_eq!(
            cargo_path_deps(text),
            vec![
                ("a-b".into(), "../a".into(), false),
                ("c".into(), "../c".into(), true),
                ("e".into(), "../e".into(), false),
                ("f".into(), "crates/f".into(), false),
                ("g".into(), "../g".into(), false),
            ]
        );
    }

    #[test]
    fn pnpm_globs_and_wildcards() {
        assert_eq!(pnpm_packages("packages:\n  - 'packages/*'\n  - \"apps/*\"\n  - '!**/test/**'\ncatalog:\n  - x\n"), ["packages/*", "apps/*", "!**/test/**"]);
        assert!(wildcard("*", "ui") && wildcard("pkg-*", "pkg-ui") && !wildcard("pkg-*", "app-ui") && wildcard("a*b*c", "aXbYc") && !wildcard("a*b*c", "ac"));
    }

    #[test]
    fn built_entries_are_tried_as_their_source_twin_first() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("package.json"), r#"{"name":"p","main":"./dist/index.js","types":"dist/index.d.ts"}"#).unwrap();
        assert_eq!(package_entries(dir.path()), ["src/index", "dist/index", "src/index.js", "dist/index.js", "index"]);
    }
}
