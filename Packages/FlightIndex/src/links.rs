//! Links between views (spec §5.3): the repositories a manifest points into, and queries that
//! cross the line.
//!
//! Two halves.
//!
//! **Discovery.** A manifest names directories outside its worktree (`elm.json`
//! `source-directories`, a `tsconfig.json` `paths` target, a `package.json` `file:` dependency, a
//! `mix.exs` or `Cargo.toml` `path:`). Each is a *literal path* (requirement 14): `../tessera/designer/src`
//! means whatever worktree sits at that path, the `tessera` main checkout, not a worktree of it
//! paired with this one. The directory resolves to the worktree containing it, and that worktree's
//! view is the *linked view*. `LinkIndex` records each view's links and re-reads them when a
//! manifest's content changes.
//!
//! **Crossing.** A graph never holds another view's symbols: its imports that leave the worktree
//! resolve to `Resolved::External` paths and its references to `ExtTarget`s. `Views` is the
//! request's set of graphs (the one that answers, then its members) and does the lookups that
//! need two of them: which symbol an `ExtTarget` names, who references or imports a symbol from
//! another view, the blast radius across views. A member is either *linked* (the answering view's
//! manifests point into it) or *dependent* (its manifests point into the answering view), so a
//! query from `formula-editor` about an `tessera` file finds the `formula-editor` importers.

use crate::facts::{RefKind, SymbolKind};
use crate::git::{self, View};
use crate::graph::{Confidence, ExtTarget, SymId, ViewGraph};
use crate::query::{CallEntry, NameMatch, RadiusEntry, RefHit, SymbolHit};
use crate::resolve::{absolute, Resolved};
use regex::Regex;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Manifest names looked for in every directory of a view that holds source.
const MANIFESTS: &[&str] = &["elm.json", "tsconfig.json", "package.json", "mix.exs", "Cargo.toml"];

// ---- discovery --------------------------------------------------------------------------------

/// A linked worktree and why: the directories of it that manifests of the linking view declare.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LinkedRoot {
    pub root: PathBuf,
    /// Canonical directories inside `root` that the manifests name. A pathless symbol search of
    /// the linked view stays inside them: `tessera` has 1,583 files and the link is two of its
    /// source directories.
    pub scopes: Vec<PathBuf>,
    /// Manifest names that declare the link (`elm.json`, `Cargo.toml`), sorted.
    pub via: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ViewLinks {
    pub roots: Vec<LinkedRoot>,
}

struct Entry {
    /// What the manifest walk was done for; the walk is repeated only when it changes.
    stamp: String,
    manifests: Vec<(String, &'static str)>,
    /// Content (git blob id) of every manifest read, which is what the links were parsed from.
    blobs: Vec<String>,
    links: Arc<ViewLinks>,
}

/// The links of every view the daemon has looked at, by worktree. Reverse lookups (who links
/// *into* this worktree) read the same table.
#[derive(Default)]
pub struct LinkIndex {
    entries: Mutex<HashMap<PathBuf, Entry>>,
}

impl LinkIndex {
    /// The links of `view`, recorded. Which manifests exist is found by walking the view's
    /// directories, which is repeated only when the commit or the overlay changes; each manifest
    /// is read on every call (a few small files) and the links re-parsed only when one's content
    /// changed.
    pub fn of(&self, view: &View) -> Arc<ViewLinks> {
        let root = &view.label.worktree;
        let stamp = view_stamp(view);
        let (prev_manifests, prev_blobs, prev_links) = match self.entries.lock().unwrap().get(root) {
            Some(e) => (
                (e.stamp == stamp).then(|| e.manifests.clone()),
                e.blobs.clone(),
                Some(e.links.clone()),
            ),
            None => (None, Vec::new(), None),
        };
        let manifests = prev_manifests.unwrap_or_else(|| find_manifests(view));
        let texts: Vec<Option<Vec<u8>>> = manifests.iter().map(|(rel, _)| std::fs::read(root.join(rel)).ok()).collect();
        let blobs: Vec<String> = texts.iter().map(|t| t.as_deref().map(git::blob_id).unwrap_or_default()).collect();
        let links = match prev_links {
            Some(l) if blobs == prev_blobs && self.has_same_manifests(root, &manifests) => l,
            _ => {
                let found: Vec<(PathBuf, &'static str, Vec<PathBuf>)> = manifests
                    .iter()
                    .zip(&texts)
                    .filter_map(|((rel, kind), text)| {
                        let text = String::from_utf8_lossy(text.as_deref()?).to_string();
                        let dir = root.join(rel).parent()?.to_path_buf();
                        Some((dir, *kind, manifest_targets(kind, &text)))
                    })
                    .collect();
                Arc::new(resolve_links(root, &found))
            }
        };
        self.entries.lock().unwrap().insert(root.clone(), Entry { stamp, manifests, blobs, links: links.clone() });
        links
    }

    fn has_same_manifests(&self, root: &Path, manifests: &[(String, &'static str)]) -> bool {
        self.entries.lock().unwrap().get(root).is_some_and(|e| e.manifests == manifests)
    }

    /// Worktrees (other than `root`) whose recorded links point into `root`, with the manifests
    /// that say so. Worktrees that no longer exist are skipped.
    pub fn dependents_of(&self, root: &Path) -> Vec<(PathBuf, Vec<String>)> {
        let mut out: Vec<(PathBuf, Vec<String>)> = self
            .entries
            .lock()
            .unwrap()
            .iter()
            .filter(|(wt, _)| wt.as_path() != root && wt.exists())
            .filter_map(|(wt, e)| e.links.roots.iter().find(|r| r.root == root).map(|r| (wt.clone(), r.via.clone())))
            .collect();
        out.sort();
        out
    }
}

/// The commit and overlay a view was computed from, as one string.
fn view_stamp(view: &View) -> String {
    let mut s = view.label.base_commit.clone().unwrap_or_default();
    for o in &view.overlay {
        match o {
            git::Overlay::Present(f) => s.push_str(&format!("\0+{}\0{}", f.path, f.blob_id)),
            git::Overlay::Deleted(p) => s.push_str(&format!("\0-{p}")),
        }
    }
    s
}

/// Manifests of a view: every directory above a source file is a candidate, because a manifest
/// (`elm.json`, `Cargo.toml`) is not itself an indexed file and has no entry in the view.
fn find_manifests(view: &View) -> Vec<(String, &'static str)> {
    let mut dirs: BTreeSet<String> = BTreeSet::from([String::new()]);
    for f in view.files() {
        let mut d = Path::new(&f.path).parent();
        while let Some(p) = d {
            if p.as_os_str().is_empty() || !dirs.insert(p.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/")) {
                break; // everything above an already seen directory has been seen
            }
            d = p.parent();
        }
    }
    let root = &view.label.worktree;
    let mut out = Vec::new();
    for d in &dirs {
        for name in MANIFESTS {
            let rel = if d.is_empty() { name.to_string() } else { format!("{d}/{name}") };
            if root.join(&rel).is_file() {
                out.push((rel, *name));
            }
        }
    }
    out
}

/// The paths a manifest names, relative to its own directory. Not filtered: most are inside the
/// worktree and `resolve_links` drops those.
pub fn manifest_targets(kind: &str, text: &str) -> Vec<PathBuf> {
    let json = || serde_json::from_str::<serde_json::Value>(&strip_jsonc(text)).ok();
    let strings = |v: Option<&serde_json::Value>| -> Vec<String> {
        v.and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
    };
    match kind {
        "elm.json" => json().map(|j| strings(j.get("source-directories")).into_iter().map(PathBuf::from).collect()).unwrap_or_default(),
        "tsconfig.json" => {
            let Some(j) = json() else { return Vec::new() };
            let opts = j.get("compilerOptions");
            let base = opts.and_then(|o| o.get("baseUrl")).and_then(|b| b.as_str()).unwrap_or(".");
            let mut out: Vec<PathBuf> = Vec::new();
            if let Some(paths) = opts.and_then(|o| o.get("paths")).and_then(|p| p.as_object()) {
                for targets in paths.values() {
                    for t in strings(Some(targets)) {
                        // `../shared/src/*` names the directory; `../util/index.ts` a file in it.
                        let dir = t.trim_end_matches('*').trim_end_matches('/');
                        out.push(Path::new(base).join(if dir.is_empty() { "." } else { dir }));
                    }
                }
            }
            if let Some(refs) = j.get("references").and_then(|r| r.as_array()) {
                out.extend(refs.iter().filter_map(|r| r.get("path").and_then(|p| p.as_str())).map(PathBuf::from));
            }
            out
        }
        "package.json" => {
            let Some(j) = json() else { return Vec::new() };
            let mut out: Vec<PathBuf> = Vec::new();
            for section in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
                for v in j.get(section).and_then(|d| d.as_object()).into_iter().flat_map(|o| o.values()) {
                    let Some(spec) = v.as_str() else { continue };
                    if let Some(p) = spec.strip_prefix("file:").or_else(|| spec.strip_prefix("link:"))
                        && !(p.ends_with(".tgz") || p.ends_with(".tar.gz") || p.ends_with(".tar"))
                    {
                        out.push(PathBuf::from(p));
                    }
                }
            }
            let ws = match j.get("workspaces") {
                Some(w) if w.is_array() => strings(Some(w)),
                Some(w) => strings(w.get("packages")),
                None => Vec::new(),
            };
            // `../shared/*` names the directory above the packages: stop at the first glob segment.
            out.extend(ws.iter().map(|p| Path::new(p).components().take_while(|c| !c.as_os_str().to_string_lossy().contains(['*', '{'])).collect::<PathBuf>()));
            out
        }
        "mix.exs" => {
            let re = Regex::new(r#"path:\s*"([^"]+)""#).expect("static regex");
            re.captures_iter(text).map(|c| PathBuf::from(&c[1])).collect()
        }
        "Cargo.toml" => {
            let re = Regex::new(r#"\bpath\s*=\s*"([^"]+)""#).expect("static regex");
            let mut section = "";
            let mut out = Vec::new();
            for line in text.lines() {
                let line = line.trim();
                if line.starts_with('[') {
                    section = line;
                } else if section.contains("dependencies") || section.starts_with("[patch") || section.starts_with("[replace") {
                    out.extend(re.captures_iter(line).map(|c| PathBuf::from(&c[1])));
                }
            }
            out
        }
        _ => Vec::new(),
    }
}

/// Targets -> the worktrees containing them. A target inside `root`, one that does not exist, and
/// one in a directory that is neither a repository nor a recognised project (so there is no index
/// to answer from) are not links.
fn resolve_links(root: &Path, found: &[(PathBuf, &'static str, Vec<PathBuf>)]) -> ViewLinks {
    let mut by_root: BTreeMap<PathBuf, (BTreeSet<PathBuf>, BTreeSet<String>)> = BTreeMap::new();
    for (dir, kind, targets) in found {
        for t in targets {
            let abs = absolute(dir, t);
            if abs.starts_with(root) || !abs.exists() {
                continue;
            }
            let target_dir = if abs.is_dir() { abs } else { abs.parent().map(Path::to_path_buf).unwrap_or(abs) };
            let Ok(loc) = git::locate(&target_dir) else { continue };
            if loc.root == root || crate::service::check_indexable(&loc, &target_dir).is_err() {
                continue;
            }
            let scope = target_dir.canonicalize().unwrap_or(target_dir);
            let e = by_root.entry(loc.root).or_default();
            e.0.insert(scope);
            e.1.insert(kind.to_string());
        }
    }
    ViewLinks { roots: by_root.into_iter().map(|(root, (scopes, via))| LinkedRoot { root, scopes: scopes.into_iter().collect(), via: via.into_iter().collect() }).collect() }
}

/// JSON with the `//` and `/* */` comments and trailing commas a `tsconfig.json` may carry.
pub fn strip_jsonc(text: &str) -> String {
    let b: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            '"' => {
                out.push('"');
                i += 1;
                while i < b.len() {
                    out.push(b[i]);
                    if b[i] == '\\' && i + 1 < b.len() {
                        out.push(b[i + 1]);
                        i += 2;
                        continue;
                    }
                    i += 1;
                    if b[i - 1] == '"' {
                        break;
                    }
                }
            }
            '/' if b.get(i + 1) == Some(&'/') => {
                while i < b.len() && b[i] != '\n' {
                    i += 1;
                }
            }
            '/' if b.get(i + 1) == Some(&'*') => {
                i += 2;
                while i + 1 < b.len() && !(b[i] == '*' && b[i + 1] == '/') {
                    i += 1;
                }
                i += 2;
            }
            ',' => {
                // Trailing: the next thing that is not whitespace or a comment closes the container.
                let mut j = i + 1;
                loop {
                    match (b.get(j), b.get(j + 1)) {
                        (Some(c), _) if c.is_whitespace() => j += 1,
                        (Some('/'), Some('/')) => {
                            while j < b.len() && b[j] != '\n' {
                                j += 1;
                            }
                        }
                        (Some('/'), Some('*')) => {
                            j += 2;
                            while j + 1 < b.len() && !(b[j] == '*' && b[j + 1] == '/') {
                                j += 1;
                            }
                            j += 2;
                        }
                        _ => break,
                    }
                }
                if !matches!(b.get(j), Some('}' | ']')) {
                    out.push(',');
                }
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    out
}

// ---- the views of one request -----------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// The answering view's manifests point into it.
    Linked,
    /// Its manifests point into the answering view.
    Dependent,
}

/// A view that takes part in a request besides the one that answers it.
pub struct Member {
    pub graph: Arc<ViewGraph>,
    pub role: Role,
    /// Linked views: where a pathless symbol search looks (see `LinkedRoot::scopes`).
    pub scopes: Vec<PathBuf>,
    pub via: Vec<String>,
    pub dirty_files: usize,
    /// `(done, total)` while its build is still running.
    pub building: Option<(usize, usize)>,
}

/// The graphs of a request: index 0 answers, `1 + n` is `members[n]`.
pub struct Views<'a> {
    graphs: Vec<&'a ViewGraph>,
    members: &'a [Member],
}

impl<'a> Views<'a> {
    pub fn new(primary: &'a ViewGraph, members: &'a [Member]) -> Views<'a> {
        let mut graphs = vec![primary];
        graphs.extend(members.iter().map(|m| &*m.graph));
        Views { graphs, members }
    }

    pub fn len(&self) -> usize {
        self.graphs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.graphs.is_empty()
    }

    pub fn graph(&self, view: usize) -> &'a ViewGraph {
        self.graphs[view]
    }

    /// Repository name and worktree of a view other than the one that answers: the label on a
    /// cross-view row. `None` for the answering view, whose label is the result's header.
    pub fn tag(&self, view: usize) -> Option<String> {
        (view != 0).then(|| crate::tools::view_tag(&self.graphs[view].label))
    }

    /// The file `abs` is, as `(view, file index)`.
    pub fn locate(&self, abs: &Path) -> Option<(usize, u32)> {
        let find = |p: &Path| self.graphs.iter().enumerate().find_map(|(v, g)| p.starts_with(&g.root).then(|| g.file_idx(p).map(|f| (v, f))).flatten());
        find(abs).or_else(|| abs.canonicalize().ok().and_then(|c| find(&c)))
    }

    /// Does a pathless search of `view` cover `path`? The answering view always; a linked view
    /// inside the directories its manifests name; a dependent view never (it is not something
    /// the answering view's manifests reach).
    fn searches(&self, view: usize, path: &Path) -> bool {
        match view {
            0 => true,
            n => {
                let m = &self.members[n - 1];
                m.role == Role::Linked && m.scopes.iter().any(|s| path.starts_with(s))
            }
        }
    }

    /// Definitions by name in the answering view, then in its linked views.
    pub fn find_symbols(&self, m: &NameMatch, kind: Option<SymbolKind>) -> Vec<SymbolHit> {
        let mut out = Vec::new();
        for (v, g) in self.graphs.iter().enumerate() {
            for mut h in g.find_symbols(m, kind, usize::MAX).data {
                if self.searches(v, &h.path) {
                    h.view = v;
                    out.push(h);
                }
            }
        }
        out
    }

    /// Symbols ranked by their words (`crate::words`), the answering view's first, then each
    /// linked view's. Each view is scored by its own index: document frequencies differ between
    /// views, so scores are not compared across them. At most `per_view` hits from each view;
    /// the second value counts every match.
    pub fn ranked_by_words(&self, words: &[String], kind: Option<SymbolKind>, per_view: usize) -> (Vec<SymbolHit>, usize) {
        let mut out = Vec::new();
        let mut total = 0;
        for (v, g) in self.graphs.iter().enumerate() {
            let mut taken = 0;
            for (_, id) in g.words().search(words) {
                if kind.is_some_and(|k| g.symbol(id).kind != k) || (v != 0 && !self.searches(v, &g.abs(id.file))) {
                    continue;
                }
                total += 1;
                if taken < per_view {
                    let mut h = g.hit(id);
                    h.view = v;
                    out.push(h);
                    taken += 1;
                }
            }
        }
        (out, total)
    }

    /// `(referring view, file, index into that file's refs)` of the references from other views
    /// that bind to `d`: each external target of each other view is looked up in the file it
    /// names, which is how it is known which symbol it is.
    fn external_referrers(&self, d: &SymbolHit) -> Vec<(usize, u32, u32)> {
        let mut out = Vec::new();
        let mut lookups: HashMap<(PathBuf, String), Option<SymId>> = HashMap::new();
        for (v, g) in self.graphs.iter().enumerate().filter(|(v, _)| *v != d.view) {
            for (rel, entries) in &g.external_refs {
                let abs = g.external_abs(rel);
                let Some((tv, tf)) = self.locate(&abs) else { continue };
                if tv != d.view {
                    continue;
                }
                for &(fi, ri) in entries {
                    let Some(res) = &g.res[fi as usize].refs[ri as usize].external else { continue };
                    for t in res.iter().filter(|t| t.path == *rel) {
                        let found = lookups.entry((abs.clone(), t.name.clone())).or_insert_with(|| self.graphs[tv].lookup_in_file(tf, &t.name, 3));
                        if *found == Some(d.id) {
                            out.push((v, fi, ri));
                            break;
                        }
                    }
                }
            }
        }
        out
    }

    /// Every resolved reference to `d`: in its own view, and from the other views that import it.
    pub fn references(&self, d: &SymbolHit) -> Vec<(usize, RefHit)> {
        let mut out: Vec<(usize, RefHit)> = self.graphs[d.view].references(d.id).data.into_iter().map(|r| (d.view, r)).collect();
        for (v, fi, ri) in self.external_referrers(d) {
            let g = self.graphs[v];
            let f = g.file(fi);
            let r = &f.facts.refs[ri as usize];
            out.push((
                v,
                RefHit {
                    path: g.abs(fi),
                    line: r.line,
                    enclosing: r.enclosing().map(|e| f.symbol(e).name.clone()),
                    kind: r.kind,
                    confidence: g.res[fi as usize].refs[ri as usize].confidence,
                },
            ));
        }
        out.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.path.cmp(&b.1.path)).then(a.1.line.cmp(&b.1.line)));
        out.dedup_by(|a, b| a.0 == b.0 && a.1.path == b.1.path && a.1.line == b.1.line && a.1.kind == b.1.kind);
        out
    }

    /// Symbols that call `h`, one level: callers in its own view, and those in other views.
    pub fn callers(&self, h: &SymbolHit) -> Vec<(SymbolHit, u32, Confidence)> {
        let mut out: Vec<(SymbolHit, u32, Confidence)> = self.graphs[h.view]
            .calls(h.id, crate::query::Direction::In, 1)
            .data
            .into_iter()
            .map(|e: CallEntry| (SymbolHit { view: h.view, ..e.hit }, e.line, e.confidence))
            .collect();
        for (v, fi, ri) in self.external_referrers(h) {
            let g = self.graphs[v];
            let r = &g.file(fi).facts.refs[ri as usize];
            if r.kind == RefKind::Type {
                continue;
            }
            if let Some(e) = r.enclosing() {
                let mut caller = g.hit(SymId { file: fi, local: e });
                caller.view = v;
                if !out.iter().any(|(c, _, _)| c.view == v && c.id == caller.id) {
                    out.push((caller, r.line, g.res[fi as usize].refs[ri as usize].confidence));
                }
            }
        }
        out
    }

    /// Symbols `h` calls, one level: callees in its own view, and those its external references
    /// reach in the other views.
    pub fn callees(&self, h: &SymbolHit) -> Vec<(SymbolHit, u32, Confidence)> {
        let g = self.graphs[h.view];
        let mut out: Vec<(SymbolHit, u32, Confidence)> = g
            .calls(h.id, crate::query::Direction::Out, 1)
            .data
            .into_iter()
            .map(|e| (SymbolHit { view: h.view, ..e.hit }, e.line, e.confidence))
            .collect();
        let callable = |k: SymbolKind| matches!(k, SymbolKind::Function | SymbolKind::Method | SymbolKind::Const | SymbolKind::Constructor | SymbolKind::Macro | SymbolKind::Port);
        let f = g.file(h.id.file);
        for (r, rr) in f.facts.refs.iter().zip(&g.res[h.id.file as usize].refs) {
            let Some(ext) = &rr.external else { continue };
            if r.kind == RefKind::Type || !r.enclosing().is_some_and(|e| g.within(h.id.file, e, h.id.local)) {
                continue;
            }
            for (tv, id) in self.resolve_external(h.view, ext) {
                let mut hit = self.graphs[tv].hit(id);
                if callable(hit.kind) && !out.iter().any(|(c, _, _)| c.view == tv && c.id == id) {
                    hit.view = tv;
                    out.push((hit, r.line, rr.confidence));
                    break;
                }
            }
        }
        out
    }

    /// The symbols external targets of `from` name, looked up in the files they point at.
    pub fn resolve_external(&self, from: usize, targets: &[ExtTarget]) -> Vec<(usize, SymId)> {
        targets
            .iter()
            .filter_map(|t| {
                let (tv, tf) = self.locate(&self.graphs[from].external_abs(&t.path))?;
                self.graphs[tv].lookup_in_file(tf, &t.name, 3).map(|id| (tv, id))
            })
            .collect()
    }

    /// For each file of any view: the files of other views that import it.
    fn cross_importers(&self) -> HashMap<(usize, u32), Vec<(usize, u32)>> {
        let mut out: HashMap<(usize, u32), Vec<(usize, u32)>> = HashMap::new();
        for (v, g) in self.graphs.iter().enumerate() {
            for (rel, files) in &g.external_importers {
                if let Some(target) = self.locate(&g.external_abs(rel)) {
                    out.entry(target).or_default().extend(files.iter().map(|f| (v, *f)));
                }
            }
        }
        out
    }

    /// Files that import `(view, file)` directly: in its own view, and in the others.
    pub fn importers(&self, view: usize, file: u32) -> Vec<(usize, u32)> {
        let mut out: Vec<(usize, u32)> = self.graphs[view].importers[file as usize].iter().map(|f| (view, *f)).collect();
        out.extend(self.cross_importers().remove(&(view, file)).unwrap_or_default());
        out.sort();
        out.dedup();
        out
    }

    /// Everything that transitively imports `(view, file)`, across views, most important first.
    pub fn blast_radius(&self, view: usize, file: u32) -> Vec<(usize, RadiusEntry)> {
        let cross = self.cross_importers();
        let mut seen: HashSet<(usize, u32)> = HashSet::from([(view, file)]);
        let mut queue: VecDeque<((usize, u32), u32)> = VecDeque::from([((view, file), 0)]);
        let mut out = Vec::new();
        while let Some(((v, f), d)) = queue.pop_front() {
            let direct = self.graphs[v].importers[f as usize].iter().map(|i| (v, *i));
            for n in direct.chain(cross.get(&(v, f)).into_iter().flatten().copied()) {
                if seen.insert(n) {
                    let g = self.graphs[n.0];
                    out.push((n.0, RadiusEntry { path: g.abs(n.1), depth: d + 1, rank: g.file_rank[n.1 as usize] }));
                    queue.push_back((n, d + 1));
                }
            }
        }
        out.sort_by(|a, b| b.1.rank.partial_cmp(&a.1.rank).unwrap_or(std::cmp::Ordering::Equal).then(a.1.path.cmp(&b.1.path)));
        out
    }

    /// The edges that cross between the answering view and member `view` (1-based, as in
    /// `graph`), in the direction the link runs: from the answering view into a linked view, from
    /// a dependent view into the answering one. `(file imports, references)`: an import counts
    /// once per importing file and target file; a reference counts when the symbol it names is
    /// found in the other view. What `stats` reports, and how link resolution is measured.
    pub fn crossing(&self, view: usize) -> (usize, usize) {
        let (from, to) = match self.members[view - 1].role {
            Role::Linked => (0, view),
            Role::Dependent => (view, 0),
        };
        let g = self.graphs[from];
        let mut imports = 0;
        for (rel, files) in &g.external_importers {
            if self.locate(&g.external_abs(rel)).is_some_and(|(v, _)| v == to) {
                imports += files.len();
            }
        }
        let mut refs = 0;
        let mut seen: HashSet<(u32, u32)> = HashSet::new();
        for entries in g.external_refs.values() {
            for &(fi, ri) in entries {
                if !seen.insert((fi, ri)) {
                    continue;
                }
                let Some(ext) = &g.res[fi as usize].refs[ri as usize].external else { continue };
                if self.resolve_external(from, ext).iter().any(|(v, _)| *v == to) {
                    refs += 1;
                }
            }
        }
        (imports, refs)
    }

    /// The import lines (file and line) in other views that bring in `file` of `view`, and, if
    /// `name` is given, name it.
    pub fn import_sites(&self, view: usize, file: u32, name: Option<&str>) -> Vec<(usize, PathBuf, u32)> {
        let mut out = Vec::new();
        for (v, fi) in self.cross_importers().remove(&(view, file)).unwrap_or_default() {
            let g = self.graphs[v];
            let node = g.file(fi);
            for (imp, res) in node.facts.imports.iter().zip(&g.res[fi as usize].imports) {
                let Resolved::External(p) = res else { continue };
                if self.locate(&g.external_abs(p)) != Some((view, file)) {
                    continue;
                }
                if name.is_none_or(|n| imp.names.iter().any(|x| x.name == n || x.name == "*")) {
                    out.push((v, g.abs(fi), imp.line));
                }
            }
        }
        out.sort();
        out.dedup();
        out
    }
}
