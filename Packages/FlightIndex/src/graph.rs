//! The resolved graph of one view, computed in memory from blob facts.
//!
//! Not persisted, on purpose: resolving a few thousand files from facts takes milliseconds, and a
//! persisted graph would need its own invalidation against every file edit in every worktree. What
//! is cached is the graph of a *base tree* (see `Engine::graph`); a worktree with local edits gets
//! `ViewGraph::with_changes`, which keeps the base's per-file resolutions and recomputes only the
//! changed files and what depends on them:
//!
//! * the changed files themselves;
//! * their importers (a symbol they used may have moved, been renamed, or gone), and the files
//!   whose resolved references land in them without an import (`ref_dependents`: qualified Rust
//!   paths, re-exports followed through a barrel file) -- unless the edit left the file's export
//!   surface (`surface_hash`: what another file's resolution can read from it) unchanged, as a
//!   body-only edit does;
//! * if any file was added or removed (or an Elm module renamed), every file with an unresolved
//!   import, since it may resolve now (or a resolved one may now be dangling), and every file
//!   with an import resolved to a package module that the changed file could now provide;
//! * every file holding an unresolved or fallback-resolved reference to a name whose definitions
//!   changed, because "the unique symbol with this name" may have changed (looked up in the
//!   base's `soft_index`, built on the first overlay, rather than scanned). A reference resolved
//!   to a package symbol is neither (see `elm_pkg`).
//!
//! File indices are stable across `with_changes` (removed files become tombstones, added files are
//! appended), so reused per-file results never need re-mapping. `fingerprint` exists so a test can
//! prove the incremental result equals a full rebuild.
//!
//! PageRank is solved for every graph to the same tolerance (see `rank`), started from a nearby
//! graph's ranks when there is one: the base for an overlay graph, a cached commit of the same
//! repository for a new base graph. The start changes only how many sweeps the solve takes.
//!
//! Graphs of one repository built by the engine (`build_shared`) also share across commits: each
//! file's resolution is a block hash-consed by content in the repository's `blocks::Share`, and
//! file indices follow that share's numbering so equal blocks really are equal. A graph owns only
//! its block pointers and its per-view indexes (`compact`) and ranks.

pub mod blocks;
mod compact;
mod elixir;
mod elm_pkg;
mod precise;
pub(crate) mod ppr;
mod python;
pub mod rank;
mod surface;
mod swift;
mod swift_types;

pub use blocks::Share;
pub use surface::surface_hash;
use compact::{Incoming, NameIndex};

use crate::facts::*;
use crate::git::{FileRef, ViewLabel};
use crate::names::{NameId, NamePool};
use crate::resolve::{Resolved, Resolver};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

/// Reference name, qualifier, or "qualifier.name" -> the files (ascending, deduplicated) holding a
/// reference by that key that binds by name alone: unresolved, fallback-resolved, or Swift.
type SoftIndex = HashMap<String, Vec<u32>>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct SymId {
    pub file: u32,
    pub local: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Confidence {
    /// Resolved through the import table, a qualifier, or the same file.
    Exact,
    /// The only symbol with this name in the view; no import justified it.
    Fallback,
    /// A symbol of a dependency (`List.map`, `Json.Decode.field`): `target` is `None`, because
    /// it is in no file of the view, and `GraphData::package_target` names it. Every consumer of
    /// `target` (incoming index, ranks, rename, move) therefore ignores it.
    Package,
    /// A member looked up on a receiver whose type the file's own declarations give (a parameter,
    /// a `let x = T(...)`, a property's declared type): typed by declaration, not by a compiler.
    Inferred,
    /// The compiler's answer, read from the build's index store (`crate::indexstore`).
    Precise,
}

/// Where an imported name points outside the worktree: a file (relative to the worktree root, see
/// `Resolved::External`) and the name to look up in it. The graph cannot say which symbol that is,
/// because the file belongs to another view; `links.rs` looks it up there.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ExtTarget {
    pub path: PathBuf,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RefRes {
    pub target: Option<SymId>,
    pub confidence: Confidence,
    /// The reference leaves this worktree through an import (cross-repo link): one target when an
    /// import names it, several when it may come from any of the `exposing (..)` imports of
    /// linked modules. Boxed: nearly every reference leaves it empty, and an inline
    /// `Option<Vec<_>>` is 24 bytes a reference (16 MB on a 650k-reference repository).
    pub external: Option<Box<Vec<ExtTarget>>>,
}

/// One file's resolution: a *block*, shared by every graph that resolved the file the same way
/// (see `blocks`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct FileRes {
    pub imports: Vec<Resolved>,
    pub refs: Vec<RefRes>,
    /// Files this file depends on (deduplicated, no self edge).
    pub edges: Vec<u32>,
    /// The package symbol of each `Confidence::Package` reference. A side table rather than a
    /// field of `RefRes`: only package references pay for it.
    pub pkg_refs: elm_pkg::PkgRefs,
}

#[derive(Debug, Clone)]
pub struct FileNode {
    pub path: String,
    pub blob_id: String,
    pub language: &'static str,
    pub facts: Arc<InternedFacts>,
    pub alive: bool,
    names: Arc<NameMap>,
}

/// A file's symbols by name (local ids in source order).
pub(crate) type NameMap = HashMap<String, Vec<u32>>;

fn name_map(facts: &InternedFacts) -> NameMap {
    let mut names: NameMap = HashMap::new();
    for s in &facts.symbols {
        names.entry(s.name.clone()).or_default().push(s.local_id);
    }
    names
}

fn name_map_bytes(n: &NameMap) -> usize {
    use std::mem::size_of;
    const ALLOC: usize = 16;
    n.capacity() * (size_of::<String>() + size_of::<Vec<u32>>() + 1) + n.iter().map(|(k, v)| k.len() + v.capacity() * 4 + 2 * ALLOC).sum::<usize>()
}

impl FileNode {
    fn new(f: &FileRef, facts: Arc<InternedFacts>, share: Option<&Share>) -> FileNode {
        let names = match share {
            Some(s) => s.names(&facts),
            None => Arc::new(name_map(&facts)),
        };
        FileNode { path: f.path.clone(), blob_id: f.blob_id.clone(), language: f.language, facts, alive: true, names }
    }

    /// A slot of the repository's file numbering that this graph has no file in.
    fn gap(empty: &Arc<InternedFacts>, names: &Arc<NameMap>) -> FileNode {
        FileNode { path: String::new(), blob_id: String::new(), language: "", facts: empty.clone(), alive: false, names: names.clone() }
    }

    fn tombstone(&self) -> FileNode {
        FileNode {
            alive: false,
            facts: Arc::new(InternedFacts::default()),
            names: Arc::new(HashMap::new()),
            ..self.clone()
        }
    }

    pub fn symbol(&self, local: u32) -> &Symbol {
        &self.facts.symbols[local as usize]
    }
}

pub enum FileChange {
    Upsert(FileRef, Arc<InternedFacts>),
    Remove(String),
}

/// Everything derived from a file set: shared (`Arc`) by every worktree graph that resolves to
/// the same content, so a second worktree on an indexed commit costs a pointer, not a copy of the
/// graph.
#[derive(Clone)]
pub struct GraphData {
    /// The root the resolver read manifests under when this data was built.
    pub(crate) root: PathBuf,
    pub(crate) files: Vec<FileNode>,
    /// Path -> file index of every live file. Shared with the base when an overlay adds or removes
    /// no path (an `Arc`, copied on write by `with_changes`).
    pub(crate) index: Arc<HashMap<String, u32>>,
    pub(crate) res: Vec<Arc<FileRes>>,
    /// The `Arc`s from here to `elm_modules` are the base's own when an overlay's came out equal,
    /// and the two reference indexes are layers over the base's (see `compact`).
    pub(crate) importers: Arc<Vec<Vec<u32>>>,
    /// target file -> files with a resolved reference into it that do not import it: a qualified
    /// Rust path (`a::m::f()` records no import), or a re-export followed through a barrel
    /// (`import { helper } from './lib'` lands in `lib/impl.ts`). `with_changes` re-resolves these
    /// next to `importers`, or their references keep a target whose local id has moved.
    pub(crate) ref_dependents: Arc<Vec<Vec<u32>>>,
    /// Every definition (but `impl` blocks) by name; look up with `named`.
    name_index: Arc<NameIndex>,
    /// target symbol -> (file, index into that file's `refs`) of every resolved reference to it
    pub(crate) incoming: Arc<Incoming>,
    /// External file (relative to the root, as in `Resolved::External`) -> (file, index into that
    /// file's `refs`) of every reference that may land in it.
    pub(crate) external_refs: HashMap<PathBuf, Vec<(u32, u32)>>,
    /// External file -> the files of this view that import it.
    pub(crate) external_importers: HashMap<PathBuf, Vec<u32>>,
    /// Some resolution looked outside the root, so the per-file results hold for the root this
    /// was built under and must be redone for a worktree that stands elsewhere.
    pub(crate) location_sensitive: bool,
    pub(crate) file_rank: Vec<f64>,
    /// per file, per local symbol id
    pub(crate) symbol_rank: Vec<Vec<f64>>,
    /// How the file and symbol ranks were solved (sweeps, warm or cold).
    pub rank_stats: [rank::SolveStats; 2],
    resolver: Arc<Resolver>,
    elm_modules: Arc<HashMap<String, Vec<u32>>>,
    /// The repository's shared numbering and block table, if the graph was built with one; the
    /// blocks and name tables are then charged there, once, not to each graph.
    share: Option<Arc<Share>>,
    /// Resolves every `RefSite` of `files`. The repository's pool as of this build; a later one
    /// would do as well (ids only append), which is what `with_changes` relies on.
    names: Arc<NamePool>,
    /// Built on first use by `with_changes` on this graph, from this graph's own `res`; never
    /// carried into a derived graph (`with_changes` resets it), so it always describes the data it
    /// sits in, even if overlays are ever chained. An `Arc` so cloning `GraphData` stays cheap.
    soft_index: Arc<OnceLock<SoftIndex>>,
    /// How many files this graph resolved itself rather than reused from its base (all of them
    /// for `build`): what the overlay dirty rules cost, and what tests assert they skip.
    resolved: usize,
    /// Property, return and supertype tables of the view's Swift files (the receiver ladder).
    swift_types: Arc<swift_types::SwiftTypes>,
    /// BM25 over symbol words (`crate::words`), built on the first ranked query, not here.
    pub(crate) words: std::sync::OnceLock<Arc<crate::words::WordIndex>>,
    /// The weighted adjacency personalized PageRank walks (`graph/ppr.rs`), built on the first
    /// seeded `map` and dropped with everything else `finalize` derives. Lazy because most graphs
    /// (a base tree behind a dirty worktree, a linked view) are never asked for a seeded rank.
    ppr: std::sync::OnceLock<Arc<ppr::PprGraph>>,
}

/// A graph as one worktree sees it: shared data, plus the worktree's own root and label (the only
/// things that differ between two clean worktrees of one commit).
#[derive(Clone)]
pub struct ViewGraph {
    pub label: ViewLabel,
    pub(crate) root: PathBuf,
    data: Arc<GraphData>,
}

impl std::ops::Deref for ViewGraph {
    type Target = GraphData;
    fn deref(&self) -> &GraphData {
        &self.data
    }
}

impl ViewGraph {
    /// Resolve every file from scratch. `names` must resolve every input's references
    /// (`InternedFacts::name_bound`).
    pub fn build(label: ViewLabel, inputs: Vec<(FileRef, Arc<InternedFacts>)>, names: Arc<NamePool>) -> ViewGraph {
        Self::build_in(label, inputs, names, None, None)
    }

    /// `build`, with PageRank started from `near`'s ranks (a graph of the same repository at a
    /// nearby commit). Resolution is unaffected; ranks agree with a cold build within tolerance.
    pub fn build_near(label: ViewLabel, inputs: Vec<(FileRef, Arc<InternedFacts>)>, names: Arc<NamePool>, near: Option<&ViewGraph>) -> ViewGraph {
        Self::build_in(label, inputs, names, None, near)
    }

    /// Resolve every file from scratch, numbering files the way `share`'s repository does and
    /// taking every block and name table some other graph of the repository already holds from
    /// there instead of keeping a copy (see `blocks`). PageRank starts from `near`'s ranks when
    /// given (files match by path, so the two numberings need not agree).
    pub fn build_shared(label: ViewLabel, inputs: Vec<(FileRef, Arc<InternedFacts>)>, names: Arc<NamePool>, share: Arc<Share>, near: Option<&ViewGraph>) -> ViewGraph {
        Self::build_in(label, inputs, names, Some(share), near)
    }

    fn build_in(label: ViewLabel, inputs: Vec<(FileRef, Arc<InternedFacts>)>, names: Arc<NamePool>, share: Option<Arc<Share>>, near: Option<&ViewGraph>) -> ViewGraph {
        let root = label.worktree.clone();
        let files: Vec<FileNode> = match &share {
            None => inputs.iter().map(|(f, facts)| FileNode::new(f, facts.clone(), None)).collect(),
            Some(s) => {
                let (ids, slots) = s.layout(inputs.iter().map(|(f, _)| f.path.as_str()));
                let (empty, no_names) = (Arc::new(InternedFacts::default()), Arc::new(NameMap::new()));
                let mut files = vec![FileNode::gap(&empty, &no_names); slots];
                for ((f, facts), i) in inputs.iter().zip(ids) {
                    files[i as usize] = FileNode::new(f, facts.clone(), Some(s));
                }
                files
            }
        };
        let empty_res = Arc::new(FileRes::default());
        let mut g = GraphData {
            root: root.clone(),
            res: vec![empty_res; files.len()],
            files,
            index: Arc::default(),
            importers: Arc::default(),
            ref_dependents: Arc::default(),
            name_index: Arc::default(),
            incoming: Arc::default(),
            external_refs: HashMap::new(),
            external_importers: HashMap::new(),
            location_sensitive: false,
            file_rank: Vec::new(),
            symbol_rank: Vec::new(),
            rank_stats: Default::default(),
            resolver: Arc::new(Resolver::new(Path::new(""), &[])),
            elm_modules: Arc::default(),
            share,
            names,
            resolved: 0,
            soft_index: Arc::default(),
            swift_types: Arc::default(),
            words: std::sync::OnceLock::new(),
            ppr: std::sync::OnceLock::new(),
        };
        g.reindex(None);
        for f in 0..g.files.len() as u32 {
            if g.files[f as usize].alive {
                g.res[f as usize] = g.intern(g.resolve_file(f));
            }
        }
        g.resolved = g.files.iter().filter(|f| f.alive).count();
        g.finalize(near.map(|n| &*n.data), None);
        ViewGraph { label, root, data: Arc::new(g) }
    }

    /// A graph for `self` with `changes` applied, reusing every per-file resolution the changes
    /// cannot affect (see the module docs for the exact dirty set). `names` is the pool for the
    /// changed files' facts: the same store's, at least as new as the one `self` was built with.
    pub fn with_changes(&self, label: ViewLabel, changes: Vec<FileChange>, names: Arc<NamePool>) -> ViewGraph {
        debug_assert_eq!(names.store_id(), self.data.names.store_id(), "a pool of another store");
        let mut g: GraphData = (*self.data).clone();
        if names.len() > g.names.len() {
            g.names = names;
        }
        g.root = label.worktree.clone();
        g.soft_index = Arc::default();
        g.words = std::sync::OnceLock::new(); // the base's word index describes the base's symbols
        let old_files_len = g.files.len();

        let mut changed: HashSet<u32> = HashSet::new();
        // Changed in place with the same export surface: no other file can resolve differently.
        let mut same_surface: HashSet<u32> = HashSet::new();
        let mut structural = false; // a path appeared/disappeared or an Elm module name moved
        let mut old_names: HashSet<String> = HashSet::new();
        let mut new_names: HashSet<String> = HashSet::new();
        let names_of = |n: &FileNode| -> Vec<String> { n.facts.symbols.iter().map(|s| s.name.clone()).collect() };
        // Elm module names a changed file has, had, or could be found under: an import of one of
        // them that resolved to a package may now resolve to the file (or back).
        let mut changed_modules: HashSet<String> = HashSet::new();
        let mut note_module = |n: &FileNode| {
            if n.language == "elm" {
                changed_modules.extend(n.facts.module_name.clone());
                let stem = n.path.trim_end_matches(".elm");
                changed_modules.extend(stem.match_indices('/').map(|(i, _)| stem[i + 1..].replace('/', ".")));
                changed_modules.insert(stem.replace('/', "."));
            }
        };
        // Swift members whose owner changed: `x.drive()` may now mean another type's `drive`.
        let mut old_members: HashSet<(String, String)> = HashSet::new();
        let mut new_members: HashSet<(String, String)> = HashSet::new();
        let swift_members = |n: &FileNode| if n.language == "swift" { swift_types::member_pairs(&n.facts) } else { HashSet::new() };

        for ch in changes {
            match ch {
                FileChange::Upsert(f, facts) => {
                    let node = FileNode::new(&f, facts, g.share.as_deref());
                    match g.index.get(&f.path).copied() {
                        Some(i) => {
                            let old = &g.files[i as usize];
                            if surface_hash(&old.facts) == surface_hash(&node.facts) {
                                same_surface.insert(i);
                            }
                            note_module(old);
                            note_module(&node);
                            old_names.extend(names_of(old));
                            old_members.extend(swift_members(old));
                            new_members.extend(swift_members(&node));
                            structural |= old.facts.module_name != node.facts.module_name;
                            new_names.extend(names_of(&node));
                            g.files[i as usize] = node;
                            changed.insert(i);
                        }
                        None => {
                            structural = true;
                            note_module(&node);
                            new_names.extend(names_of(&node));
                            new_members.extend(swift_members(&node));
                            g.files.push(node);
                            let i = g.files.len() as u32 - 1;
                            Arc::make_mut(&mut g.index).insert(f.path.clone(), i);
                            changed.insert(i);
                        }
                    }
                }
                FileChange::Remove(path) => {
                    if let Some(i) = Arc::make_mut(&mut g.index).remove(&path) {
                        structural = true;
                        note_module(&g.files[i as usize]);
                        old_names.extend(names_of(&g.files[i as usize]));
                        old_members.extend(swift_members(&g.files[i as usize]));
                        g.files[i as usize] = g.files[i as usize].tombstone();
                        g.res[i as usize] = Arc::default();
                        changed.insert(i);
                    }
                }
            }
        }
        g.res.resize(g.files.len(), Arc::default());
        let changed_names: HashSet<String> = old_names.symmetric_difference(&new_names).cloned().collect();
        g.reindex(Some((&self.data, &changed, structural)));
        // Receivers typed through a table entry an edit changed must be typed again, wherever
        // they are: one file's `let item: Car` types `h.item` in every other file.
        let type_change = match swift_types::SwiftTypes::changed_names(&self.data.swift_types, &g.swift_types) {
            swift_types::TypeChange::None => {
                // Unchanged tables: share the base's rather than hold a second copy per overlay.
                g.swift_types = self.data.swift_types.clone();
                swift_types::TypeChange::Names(HashSet::new())
            }
            c => c,
        };
        let type_change = match type_change {
            swift_types::TypeChange::Names(mut names) => {
                names.extend(old_members.symmetric_difference(&new_members).map(|(_, m)| m.clone()));
                names.extend(self.data.swift_types.typed_as(&changed_names).cloned());
                names.extend(g.swift_types.typed_as(&changed_names).cloned());
                names.extend(changed_names.iter().cloned());
                if names.is_empty() { swift_types::TypeChange::None } else { swift_types::TypeChange::Names(names) }
            }
            c => c,
        };

        let mut dirty: HashSet<u32> = changed.iter().copied().filter(|i| g.files[*i as usize].alive).collect();
        let relocated = self.data.location_sensitive && self.data.root != label.worktree;
        if relocated {
            // `../lib` is another directory from here: nothing resolved outside the root carries over.
            dirty.extend((0..g.files.len() as u32).filter(|i| g.files[*i as usize].alive));
        }
        for &c in &changed {
            // Early cutoff: the edit left everything another file reads from `c` alone (see
            // `surface_hash`), so its importers' and dependents' resolutions still hold.
            if (c as usize) < old_files_len && !same_surface.contains(&c) {
                dirty.extend(self.data.importers[c as usize].iter().copied());
                dirty.extend(self.data.ref_dependents[c as usize].iter().copied());
            }
        }
        // A path appeared or disappeared, or an Elm module was renamed: an unresolved import may
        // resolve now, and so may one resolved to a package module a changed file could now
        // provide. (A removed file's importers resolved into it; they are dirty via `importers`.)
        if structural && !relocated {
            for (i, r) in g.res.iter().enumerate() {
                let unresolved = r.imports.iter().any(|x| match x {
                    Resolved::Unresolved => true,
                    Resolved::Package(m) => changed_modules.contains(&*m.name),
                    _ => false,
                });
                if g.files[i].alive && unresolved {
                    dirty.insert(i as u32);
                }
            }
        }
        if !changed_names.is_empty() && !relocated {
            // Looked up rather than scanned (19.7 ms over every reference of tessera, against
            // microseconds). Exact: `self.res` of every file not already dirty is what `g.res` holds,
            // and the index was built from `self.res`. Dirty files are re-resolved anyway.
            let soft = self.data.soft_index();
            for name in &changed_names {
                for &i in soft.get(name).into_iter().flatten() {
                    if g.files[i as usize].alive {
                        dirty.insert(i);
                    }
                }
            }
        }
        // Receivers typed through a table entry an edit changed (`swift_types`) are typed again,
        // wherever they are. Not covered by `surface_hash`: it is this rule, not the importers',
        // that keeps a Swift file's `h.item.m()` right when another file's `item` changes type.
        if !matches!(type_change, swift_types::TypeChange::None) && !relocated {
            for (i, node) in g.files.iter().enumerate() {
                let retyped = node.alive
                    && node.language == "swift"
                    && match &type_change {
                        swift_types::TypeChange::None => false,
                        swift_types::TypeChange::All => true,
                        swift_types::TypeChange::Names(names) => swift_types::mentions(&g.names, &node.facts, names),
                    };
                if retyped {
                    dirty.insert(i as u32);
                }
            }
        }
        g.resolved = 0;
        for f in dirty {
            if g.files[f as usize].alive {
                g.res[f as usize] = g.intern(g.resolve_file(f));
                g.resolved += 1;
            }
        }
        g.finalize(Some(&self.data), Some(&self.data));
        ViewGraph { root: label.worktree.clone(), label, data: Arc::new(g) }
    }
}

impl GraphData {
    /// `r` as a block: the shared copy when another graph of the repository holds an equal one.
    fn intern(&self, r: FileRes) -> Arc<FileRes> {
        match &self.share {
            Some(s) => s.block(r),
            None => Arc::new(r),
        }
    }

    /// Files holding a reference that binds by name alone, keyed by every name an edit could make
    /// it bind to: its own name (`stray()`), its qualifier (`Shop.Order.total()` names the module
    /// in its qualifier) and "qualifier.name" (`%Shop.Item{}` splits the module name across both).
    /// Swift references count whatever they resolved to, because a nearer definition can shadow
    /// an exact one.
    fn soft_index(&self) -> &SoftIndex {
        self.soft_index.get_or_init(|| {
            let mut idx: SoftIndex = HashMap::new();
            for (i, (f, r)) in self.files.iter().zip(&self.res).enumerate() {
                if !f.alive {
                    continue;
                }
                let i = i as u32;
                let mut push = |k: &str| match idx.get_mut(k) {
                    Some(v) => {
                        if v.last() != Some(&i) {
                            v.push(i);
                        }
                    }
                    None => {
                        idx.insert(k.to_string(), vec![i]);
                    }
                };
                for (fr, rr) in f.facts.refs.iter().zip(&r.refs) {
                    // A package reference is not soft: the scope that found it is consulted only after
                    // the file's own imports and before any fallback, so no name appearing in another
                    // file can take it over.
                    if (rr.target.is_none() && rr.confidence != Confidence::Package) || rr.confidence == Confidence::Fallback || f.language == "swift" {
                        let name = self.name(fr.name);
                        push(name);
                        if let Some(q) = self.qualifier(fr) {
                            push(q);
                            push(&format!("{q}.{name}"));
                        }
                    }
                }
            }
            idx
        })
    }

    /// Rebuild the path index, resolver and name/module indexes from `files`. With `base` (the
    /// graph `with_changes` derives this one from, the files it changed, and whether a path came
    /// or went), what the change cannot have touched is the base's: the path index (`with_changes`
    /// keeps it up to date itself) and, with no path added or removed, the resolver's path set;
    /// the name index becomes a layer over the base's with the changed files masked.
    fn reindex(&mut self, base: Option<(&GraphData, &HashSet<u32>, bool)>) {
        if base.is_none() {
            self.index = Arc::new(self.files.iter().enumerate().filter(|(_, f)| f.alive).map(|(i, f)| (f.path.clone(), i as u32)).collect());
        }
        self.resolver = Arc::new(match base {
            Some((b, _, false)) => Resolver::with_paths(&self.root, b.resolver.paths().clone()),
            _ => {
                let refs: Vec<FileRef> = self
                    .files
                    .iter()
                    .filter(|f| f.alive)
                    .map(|f| FileRef { path: f.path.clone(), blob_id: f.blob_id.clone(), language: f.language })
                    .collect();
                Resolver::new(&self.root, &refs)
            }
        });
        let mut elm_modules: HashMap<String, Vec<u32>> = HashMap::new();
        let mut defs: Vec<SymId> = Vec::new();
        let masked: Option<Vec<u32>> = base.map(|(_, changed, _)| {
            let mut m: Vec<u32> = changed.iter().copied().collect();
            m.sort_unstable();
            m
        });
        for (fi, f) in self.files.iter().enumerate().filter(|(_, f)| f.alive) {
            // A layer holds only the changed files' definitions; the base answers for the rest.
            if masked.as_ref().is_none_or(|m| m.binary_search(&(fi as u32)).is_ok()) {
                for s in &f.facts.symbols {
                    if s.kind != SymbolKind::Impl {
                        defs.push(SymId { file: fi as u32, local: s.local_id });
                    }
                }
            }
            if let Some(m) = &f.facts.module_name {
                elm_modules.entry(m.clone()).or_default().push(fi as u32);
            }
        }
        self.elm_modules = match base {
            Some((b, _, _)) if *b.elm_modules == elm_modules => b.elm_modules.clone(),
            _ => Arc::new(elm_modules),
        };
        let files = &self.files;
        let name_of = |id: SymId| files[id.file as usize].symbol(id.local).name.as_str();
        // As for the incoming index (`finalize`): a layer pays while it masks a small part.
        let layered = match (base, masked) {
            (Some((b, _, _)), Some(m)) if m.len() * 4 <= files.len() => NameIndex::over(&b.name_index, m, defs.clone(), name_of),
            _ => None,
        };
        self.name_index = Arc::new(match layered {
            Some(ix) => ix,
            None if base.is_some() => {
                // The base is itself a layer, or most files changed: index every file.
                let all = files.iter().enumerate().filter(|(_, f)| f.alive).flat_map(|(fi, f)| f.facts.symbols.iter().filter(|s| s.kind != SymbolKind::Impl).map(move |s| SymId { file: fi as u32, local: s.local_id })).collect();
                NameIndex::build(all, name_of)
            }
            None => NameIndex::build(defs, name_of),
        });
        let swift = self.files.iter().filter(|f| f.alive && f.language == "swift").map(|f| &*f.facts);
        self.swift_types = Arc::new(swift_types::SwiftTypes::build(swift));
    }

    /// Every definition named `name` (but `impl` blocks), in file then source order.
    pub(crate) fn named(&self, name: &str) -> Option<std::borrow::Cow<'_, [SymId]>> {
        self.name_index.get(name, |id| self.symbol(id).name.as_str())
    }

    /// Everything derived from `files` + `res`: importers, the incoming-reference index, ranks
    /// (warm-started from `prior` when given). With `base` (the graph `with_changes` derives this
    /// one from), indexes that came out equal are the base's, and the incoming-reference index is
    /// a layer over the base's that masks only the files whose resolution differs from it.
    fn finalize(&mut self, prior: Option<&GraphData>, base: Option<&GraphData>) {
        let n = self.files.len();
        self.ppr = std::sync::OnceLock::new();
        let mut importers = vec![Vec::new(); n];
        for (i, r) in self.res.iter().enumerate() {
            for &t in &r.edges {
                importers[t as usize].push(i as u32);
            }
        }
        // Files whose resolution is not the base's block (by pointer, or by content for a graph
        // built without a share): only their references can differ from the base's.
        let masked: Option<Vec<u32>> = base.map(|b| {
            (0..n as u32)
                .filter(|&i| match b.res.get(i as usize) {
                    Some(old) => !Arc::ptr_eq(old, &self.res[i as usize]) && **old != *self.res[i as usize],
                    None => true,
                })
                .collect()
        });
        // A layer pays when it masks a small part of the graph; past a quarter, index it all.
        let masked = masked.filter(|m| m.len() * 4 <= n && base.is_some_and(|b| !b.incoming.is_layer()));
        let mut pairs: Vec<(SymId, (u32, u32))> = Vec::new();
        let mut ref_dependents = vec![Vec::new(); n];
        for (fi, r) in self.res.iter().enumerate() {
            let fi = fi as u32;
            let own = masked.as_ref().is_none_or(|m| m.binary_search(&fi).is_ok());
            for (ri, rr) in r.refs.iter().enumerate() {
                if let Some(t) = rr.target {
                    if own {
                        pairs.push((t, (fi, ri as u32)));
                    }
                    // `importers[t]` is sorted (filled in file order above), so this check is a
                    // binary search; `deps.last()` dedups because one file's refs are visited together.
                    let deps = &mut ref_dependents[t.file as usize];
                    if t.file != fi && deps.last() != Some(&fi) && importers[t.file as usize].binary_search(&fi).is_err() {
                        deps.push(fi);
                    }
                }
            }
        }
        let same = |mine: Vec<Vec<u32>>, theirs: Option<&Arc<Vec<Vec<u32>>>>| match theirs {
            Some(t) if **t == mine => t.clone(),
            _ => Arc::new(mine),
        };
        self.importers = same(importers, base.map(|b| &b.importers));
        self.ref_dependents = same(ref_dependents, base.map(|b| &b.ref_dependents));
        self.incoming = Arc::new(match (base, masked) {
            (Some(b), Some(m)) => Incoming::over(&b.incoming, m, pairs).expect("checked: the base is not a layer"),
            _ => Incoming::build(pairs),
        });
        self.external_refs.clear();
        self.external_importers.clear();
        for (fi, r) in self.res.iter().enumerate() {
            for (ri, rr) in r.refs.iter().enumerate() {
                for t in rr.external.iter().flat_map(|v| v.iter()) {
                    self.external_refs.entry(t.path.clone()).or_default().push((fi as u32, ri as u32));
                }
            }
            for imp in &r.imports {
                if let Resolved::External(p) = imp {
                    let v = self.external_importers.entry(p.clone()).or_default();
                    if v.last() != Some(&(fi as u32)) {
                        v.push(fi as u32);
                    }
                }
            }
        }
        self.location_sensitive |= self.resolver.probed_outside();
        self.rank(prior);
    }

}

impl ViewGraph {
    // ---- accessors ---------------------------------------------------------------------

    /// Files this graph resolved rather than reused from the graph it was derived from.
    pub fn resolved_files(&self) -> usize {
        self.resolved
    }

    pub fn file_count(&self) -> usize {
        self.files.iter().filter(|f| f.alive).count()
    }

    pub fn file_idx(&self, abs_or_rel: &Path) -> Option<u32> {
        let rel = abs_or_rel.strip_prefix(&self.root).unwrap_or(abs_or_rel);
        self.index.get(&rel.to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/")).copied()
    }

    /// Absolute path of a file in this view. Paths are derived from the root rather than stored,
    /// so a base-tree graph can be re-pointed at another worktree of the same commit.
    pub fn abs(&self, i: u32) -> PathBuf {
        self.root.join(&self.files[i as usize].path)
    }

    /// Whether anything besides this handle holds the resolved data: a request working from a
    /// `for_worktree` copy of a cached graph does, and evicting the cached one frees nothing.
    pub(crate) fn data_shared(&self) -> bool {
        Arc::strong_count(&self.data) > 1
    }

    /// The same graph for another worktree whose resolved content is identical (same base tree,
    /// empty overlay): only the root, label and root-dependent resolver change.
    pub fn for_worktree(&self, label: ViewLabel) -> ViewGraph {
        if self.data.location_sensitive && self.data.root != label.worktree {
            return self.with_changes(label, Vec::new(), self.data.names.clone());
        }
        ViewGraph { root: label.worktree.clone(), label, data: self.data.clone() }
    }

    /// A stable text summary of every resolution, keyed by path. Two graphs of the same file set
    /// have equal fingerprints; used to prove incremental == full.
    pub fn fingerprint(&self) -> Vec<String> {
        let mut out = Vec::new();
        let sym = |id: SymId| format!("{}#{}", self.files[id.file as usize].path, id.local);
        for (i, f) in self.files.iter().enumerate().filter(|(_, f)| f.alive) {
            let r = &self.res[i];
            let mut edges: Vec<&str> = r.edges.iter().map(|e| self.files[*e as usize].path.as_str()).collect();
            edges.sort();
            out.push(format!("{} edges={:?}", f.path, edges));
            for (ri, (rr, fr)) in r.refs.iter().zip(&f.facts.refs).enumerate() {
                out.push(format!(
                    "{} ref {}:{} -> {:?} {:?} {:?} {:?}",
                    f.path,
                    fr.line,
                    self.names.resolve(fr.name),
                    rr.target.map(sym),
                    rr.confidence,
                    rr.external,
                    r.pkg_refs.get(ri as u32).map(|s| s.scip())
                ));
            }
            // The indexes queries read, which an overlay layers over its base's (`compact`).
            let paths = |v: &[u32]| -> Vec<&str> {
                let mut p: Vec<&str> = v.iter().map(|&j| self.files[j as usize].path.as_str()).collect();
                p.sort();
                p
            };
            out.push(format!("{} importers={:?} dependents={:?}", f.path, paths(&self.importers[i]), paths(&self.ref_dependents[i])));
            for s in &f.facts.symbols {
                let id = SymId { file: i as u32, local: s.local_id };
                let mut named: Vec<String> = self.named(&s.name).unwrap_or_default().iter().map(|&d| sym(d)).collect();
                named.sort();
                let mut incoming: Vec<String> = self.incoming.get(&id).unwrap_or_default().iter().map(|&(fi, ri)| format!("{}:{ri}", self.files[fi as usize].path)).collect();
                incoming.sort();
                out.push(format!("{} named {} -> {named:?}; incoming {incoming:?}", sym(id), s.name));
            }
        }
        out.sort();
        out
    }

}

impl GraphData {
    /// File ranks with the random walk restarting at `seeds` (file index, weight) and reverse
    /// edges at `reverse` times their forward weight; the plain `file_rank` when no seed is live.
    /// See `graph/ppr.rs`.
    pub fn personalized_file_rank(&self, seeds: &[(u32, f64)], reverse: f64) -> Vec<f64> {
        ppr::personalized_file_rank(self, seeds, reverse)
    }

    pub(crate) fn ppr_graph(&self) -> &ppr::PprGraph {
        self.ppr.get_or_init(|| Arc::new(ppr::build(self)))
    }

    // ---- resolution --------------------------------------------------------------------

    pub fn file(&self, i: u32) -> &FileNode {
        &self.files[i as usize]
    }

    /// File slots, dead ones included: indices run `0..files_len()`, and a slot whose file is not
    /// in this view (removed, or numbered for another commit of the repository) is not `alive`.
    pub fn files_len(&self) -> usize {
        self.files.len()
    }

    pub fn symbol(&self, id: SymId) -> &Symbol {
        self.files[id.file as usize].symbol(id.local)
    }

    pub fn resolution(&self, file: u32) -> &FileRes {
        &self.res[file as usize]
    }

    /// The repository's name pool this graph resolves references through.
    pub fn names(&self) -> &Arc<NamePool> {
        &self.names
    }

    /// The text of an interned name (a reference's name or qualifier).
    pub fn name(&self, id: NameId) -> &str {
        self.names.resolve(id)
    }

    /// A reference's qualifier as text.
    pub fn qualifier(&self, r: &RefSite) -> Option<&str> {
        r.qualifier().map(|q| self.names.resolve(q))
    }

    /// The resolver this graph was built with, so a mutator rewriting an import resolves a path
    /// exactly the way the graph did (a second resolver could disagree about which file it names).
    pub(crate) fn resolver(&self) -> &Resolver {
        &self.resolver
    }

    fn file_of(&self, r: &Resolved) -> Option<u32> {
        match r {
            Resolved::File { path, .. } => self.index.get(path).copied(),
            _ => None,
        }
    }

    /// `names` of `file` visible to an unqualified reference: top-level, constructors and module
    /// members. Methods and fields need a qualifier (`self.`, `Type::`), so a bare `open()` never
    /// binds to some type's `open` method.
    fn unqualified_visible(&self, file: u32, name: &str) -> Option<SymId> {
        let f = &self.files[file as usize];
        let cands = f.names.get(name)?;
        let visible = |l: &&u32| {
            let s = f.symbol(**l);
            match s.parent {
                None => true,
                Some(p) => s.kind == SymbolKind::Constructor || f.symbol(p).kind == SymbolKind::Module,
            }
        };
        let pick = cands.iter().filter(visible).max_by_key(|l| {
            let s = f.symbol(**l);
            (s.parent.is_none(), s.exported)
        })?;
        Some(SymId { file, local: *pick })
    }

    /// A definition named `name` in `file`, following re-exports up to a few hops.
    pub(crate) fn lookup_in_file(&self, file: u32, name: &str, depth: u8) -> Option<SymId> {
        let f = &self.files[file as usize];
        if let Some(cands) = f.names.get(name) {
            let best = cands.iter().max_by_key(|l| {
                let s = f.symbol(**l);
                (s.parent.is_none(), s.exported, s.kind != SymbolKind::Field)
            });
            if let Some(l) = best {
                return Some(SymId { file, local: *l });
            }
        }
        if depth == 0 {
            return None;
        }
        // Re-exports: an import in the target that brings in `name` (TS `export { x } from`,
        // Rust `pub use`, Elm has none).
        // Resolved afresh rather than read from `self.res`: that file's own resolution may not
        // have been computed yet, and a result that depends on build order is a result that
        // differs between a full build and an incremental one.
        for imp in &f.facts.imports {
            let matches = imp.names.iter().find(|n| n.local() == name || n.name == "*");
            let res = self.resolver.resolve_import(&f.path, f.language, imp);
            if let (Some(n), Some(t)) = (matches, self.file_of(&res)) {
                let orig = if n.name == "*" { name } else { n.name.as_str() };
                if t != file
                    && let Some(found) = self.lookup_in_file(t, orig, depth - 1) {
                        return Some(found);
                    }
            }
        }
        None
    }

    /// The `member` child of any definition named `container` in `file`.
    fn member_of(&self, file: u32, container: &str, member: &str) -> Option<SymId> {
        let f = &self.files[file as usize];
        let cands = f.names.get(member)?;
        cands
            .iter()
            .find(|l| f.symbol(**l).parent.is_some_and(|p| f.symbol(p).name == container))
            .map(|l| SymId { file, local: *l })
    }

    /// For `self.x` / `Self::x` / `this.x`: the member `x` of the container around `enclosing`.
    fn member_of_enclosing(&self, file: u32, enclosing: Option<u32>, member: &str) -> Option<SymId> {
        let f = &self.files[file as usize];
        let mut cur = enclosing;
        let is_container = |k: SymbolKind| matches!(k, SymbolKind::Impl | SymbolKind::Class | SymbolKind::Struct | SymbolKind::Trait | SymbolKind::Interface | SymbolKind::Enum);
        while let Some(c) = cur {
            let s = f.symbol(c);
            if is_container(s.kind) {
                // Rust splits a type across `struct Foo` and `impl Foo`: match by container name.
                return self.member_of(file, &s.name.clone(), member);
            }
            cur = s.parent;
        }
        None
    }

    fn fallback(&self, from_file: u32, name: &str, kind: RefKind, qualified: bool) -> Option<SymId> {
        // Only a definition the referring language could call: a TypeScript `Result` is not the
        // Elm `Result`, and an Elm type position cannot name a constructor. Measured on tessera,
        // 8,896 of 24,982 fallbacks crossed a language family (JavaScript -> Elixir 2,495, Rust ->
        // Elm 1,687, Elm -> TypeScript 1,556, …).
        let from_lang = self.files[from_file as usize].language;
        let elm_type = from_lang == "elm" && kind == RefKind::Type;
        let cands: Vec<SymId> = self
            .named(name)?
            .iter()
            .copied()
            .filter(|c| c.file != from_file && language_family(self.files[c.file as usize].language) == language_family(from_lang))
            .filter(|c| !elm_type || self.symbol(*c).kind != SymbolKind::Constructor)
            .collect();
        let type_like = |id: &SymId| {
            matches!(
                self.symbol(*id).kind,
                SymbolKind::Struct | SymbolKind::Enum | SymbolKind::Trait | SymbolKind::Interface | SymbolKind::Class | SymbolKind::TypeAlias
            )
        };
        let pool: Vec<SymId> = match kind {
            RefKind::Type => {
                let t: Vec<_> = cands.iter().copied().filter(type_like).collect();
                if t.is_empty() { cands } else { t }
            }
            _ if qualified => cands.into_iter().filter(|c| self.symbol(*c).parent.is_some() || !type_like(c)).collect(),
            _ => cands,
        };
        (pool.len() == 1).then(|| pool[0])
    }

    fn resolve_file(&self, f: u32) -> FileRes {
        let node = &self.files[f as usize];
        let facts = &node.facts;
        let lang = node.language;

        // Imports -> targets, and the lookup tables references go through.
        let mut imports: Vec<Resolved> = Vec::with_capacity(facts.imports.len());
        let mut edges: Vec<u32> = Vec::new();
        let mut qualifiers: HashMap<String, Resolved> = HashMap::new();
        let mut locals: HashMap<String, (Resolved, String)> = HashMap::new();
        let mut subs_types: Vec<(Resolved, String)> = Vec::new();
        let mut globs: Vec<Resolved> = Vec::new();
        let add_edge = |edges: &mut Vec<u32>, t: u32| {
            if t != f && !edges.contains(&t) {
                edges.push(t);
            }
        };

        for imp in &facts.imports {
            let mut r = self.resolver.resolve_import(&node.path, lang, imp);
            if lang == "elm" && matches!(r, Resolved::Unresolved) {
                // No usable elm.json: fall back to the module name each file declares.
                if let Some([only]) = self.elm_modules.get(&imp.specifier).map(|v| v.as_slice()) {
                    r = Resolved::File { path: self.files[*only as usize].path.clone(), rest: vec![] };
                }
            }
            if lang == "elixir" && matches!(r, Resolved::Unresolved) {
                r = self.elixir_import(&imp.specifier);
            }
            if let Some(t) = self.file_of(&r) {
                add_edge(&mut edges, t);
            }
            match lang {
                "elm" => {
                    qualifiers.insert(imp.alias.clone().unwrap_or_else(|| imp.specifier.clone()), r.clone());
                    for n in &imp.names {
                        if n.name == "*" {
                            globs.push(r.clone());
                        } else {
                            locals.insert(n.local().to_string(), (r.clone(), n.name.clone()));
                            if n.subs {
                                subs_types.push((r.clone(), n.name.clone()));
                            }
                        }
                    }
                }
                "rust" => {
                    if imp.kind == ImportKind::ModDecl {
                        qualifiers.insert(imp.specifier.clone(), r.clone());
                    }
                    for n in &imp.names {
                        if n.name == "*" {
                            globs.push(r.clone());
                            continue;
                        }
                        if n.name == "self" {
                            let last = imp.specifier.rsplit("::").next().unwrap_or("").to_string();
                            qualifiers.insert(n.alias.clone().unwrap_or(last), r.clone());
                            continue;
                        }
                        // `use a::b::{c}`: is `c` a module (its own file) or an item in `b`?
                        let mut segs: Vec<String> = imp.specifier.split("::").filter(|s| !s.is_empty()).map(String::from).collect();
                        segs.push(n.name.clone());
                        let deeper = self.resolver.rust_path(&node.path, &segs);
                        match (&deeper, &r) {
                            (Resolved::File { path: dp, rest }, Resolved::File { path: rp, .. }) if rest.is_empty() && dp != rp => {
                                if let Some(t) = self.file_of(&deeper) {
                                    add_edge(&mut edges, t);
                                }
                                qualifiers.insert(n.local().to_string(), deeper.clone());
                            }
                            _ => {
                                locals.insert(n.local().to_string(), (r.clone(), n.name.clone()));
                            }
                        }
                    }
                    if imp.names.is_empty() && imp.kind == ImportKind::Import {
                        // `use foo;` / `use std;` — binds the module itself under its last segment.
                        let last = imp.specifier.rsplit("::").next().unwrap_or("").to_string();
                        qualifiers.insert(last, r.clone());
                    }
                }
                "elixir" => self.elixir_bindings(imp, &r, &mut qualifiers, &mut locals, &mut globs),
                "python" => {
                    self.python_bindings(&node.path, imp, &r, &mut edges, &mut qualifiers, &mut locals, &mut globs);
                }
                _ => {
                    if let Some(a) = &imp.alias {
                        qualifiers.insert(a.clone(), r.clone());
                    }
                    for n in &imp.names {
                        if n.name == "*" {
                            if imp.kind == ImportKind::Reexport {
                                globs.push(r.clone());
                            }
                        } else if imp.kind == ImportKind::Import {
                            locals.insert(n.local().to_string(), (r.clone(), n.name.clone()));
                        }
                    }
                }
            }
            imports.push(r);
        }

        let mut refs = Vec::with_capacity(facts.refs.len());
        let swift_keys = (lang == "swift").then(|| self.swift_keys(f));
        let pkg_scope = (lang == "elm")
            .then(|| self.resolver.elm_packages(&node.path))
            .flatten()
            .filter(|p| !p.modules.is_empty())
            .map(|p| elm_pkg::ElmPkgScope::new(&p, &facts.imports, &imports));
        let mut pkg_refs = elm_pkg::PkgRefs::default();
        for (ri, r) in facts.refs.iter().enumerate() {
            let mut rr = match &swift_keys {
                Some(keys) => self.swift_ref(f, r, keys),
                None => self.resolve_ref(f, r, lang, &qualifiers, &locals, &subs_types, &globs),
            };
            // Nothing in the view, or only a unique-name guess: a package name beats both.
            if let Some(scope) = &pkg_scope
                && (rr.confidence == Confidence::Fallback || rr.target.is_none() && rr.external.is_none())
                && let Some(sym) = scope.lookup(self.name(r.name), self.qualifier(r), r.kind)
            {
                pkg_refs.push(ri as u32, sym);
                rr = RefRes { target: None, confidence: Confidence::Package, external: None };
            }
            refs.push(rr);
        }
        // No import is needed to call `Shop.Order.total()` or to use a type from the same Swift
        // module, so for these languages a resolved reference is itself the dependency.
        if lang == "swift" {
            edges = self.swift_edges(f, &refs);
        } else if lang == "elixir" {
            for t in refs.iter().filter_map(|rr| rr.target) {
                add_edge(&mut edges, t.file);
            }
        }
        FileRes { imports, refs, edges, pkg_refs }
    }

    #[allow(clippy::too_many_arguments)]
    fn resolve_ref(
        &self,
        f: u32,
        r: &RefSite,
        lang: &str,
        qualifiers: &HashMap<String, Resolved>,
        locals: &HashMap<String, (Resolved, String)>,
        subs_types: &[(Resolved, String)],
        globs: &[Resolved],
    ) -> RefRes {
        let exact = |id: SymId| RefRes { target: Some(id), confidence: Confidence::Exact, external: None };
        let none = RefRes { target: None, confidence: Confidence::Exact, external: None };
        let external = |targets: Vec<ExtTarget>| RefRes { target: None, confidence: Confidence::Exact, external: Some(Box::new(targets)) };
        let name = self.names.resolve(r.name);

        // Where an imported name lands.
        let through = |res: &Resolved, orig: &str| -> RefRes {
            match res {
                Resolved::File { .. } => match self.file_of(res) {
                    Some(t) => {
                        let found = self.lookup_in_file(t, orig, 3).or_else(|| {
                            // Default imports bind whatever the file exports.
                            (orig == "default").then(|| self.default_export(t, name)).flatten()
                        });
                        found.map(exact).unwrap_or(none.clone())
                    }
                    None => none.clone(),
                },
                Resolved::External(p) => external(vec![ExtTarget { path: p.clone(), name: orig.to_string() }]),
                // Left to the package scope, which also sees the implicit imports.
                Resolved::Package(_) | Resolved::Unresolved => none.clone(),
            }
        };

        if lang == "elixir"
            && let Some(rr) = self.elixir_ref(r, qualifiers)
        {
            return rr;
        }
        match self.qualifier(r) {
            None => {
                if let Some(id) = self.unqualified_visible(f, name) {
                    return exact(id);
                }
                if let Some((res, orig)) = locals.get(name) {
                    return through(res, orig);
                }
                // Elm `exposing (Type(..))`: the constructors come with the type. They are values:
                // a type position never names one (`exposing (Token(..))` with a constructor
                // `String` leaves the type `String` elm/core's).
                let ctor_position = !(lang == "elm" && r.kind == RefKind::Type);
                for (res, ty) in subs_types.iter().filter(|_| ctor_position) {
                    if let Some(t) = self.file_of(res)
                        && let Some(id) = self.member_of(t, ty, name) {
                            return exact(id);
                        }
                }
                for g in globs {
                    if let Some(t) = self.file_of(g)
                        && let Some(id) = self.lookup_in_file(t, name, 3) {
                            return exact(id);
                        }
                }
                match self.fallback(f, name, r.kind, false) {
                    Some(id) => RefRes { target: Some(id), confidence: Confidence::Fallback, external: None },
                    // Nothing in this view: it may be a constructor or a name a linked module
                    // exposes through `Type(..)` or `(..)`. Which one is for the linked view to say.
                    None => {
                        let maybe: Vec<ExtTarget> = subs_types
                            .iter()
                            .map(|(res, _)| res)
                            .chain(globs)
                            .filter_map(|res| match res {
                                Resolved::External(p) => Some(ExtTarget { path: p.clone(), name: name.to_string() }),
                                _ => None,
                            })
                            .collect();
                        if maybe.is_empty() { none } else { external(maybe) }
                    }
                }
            }
            Some(q) => {
                if matches!(q, "self" | "Self" | "this" | "cls") {
                    if let Some(id) = self.member_of_enclosing(f, r.enclosing(), name) {
                        return exact(id);
                    }
                    return match self.fallback(f, name, r.kind, true) {
                        Some(id) => RefRes { target: Some(id), confidence: Confidence::Fallback, external: None },
                        None => none,
                    };
                }
                let first = q.split("::").next().unwrap_or(q);
                // Module-qualified: `List.map`, `ns.go`, `store::open`.
                if let Some(res) = qualifiers.get(first) {
                    let rest: Vec<String> = q.split("::").skip(1).map(String::from).collect();
                    if lang == "rust" && !rest.is_empty() {
                        let mut segs = vec!["self".to_string()];
                        segs.extend(rest);
                        segs.push(name.to_string());
                        if let Resolved::File { path, .. } = res
                            && let Resolved::File { path: p2, rest } = self.resolver.rust_path(path, &segs) {
                                return self.rust_item(&p2, &rest, name).map(exact).unwrap_or(none);
                            }
                        return none;
                    }
                    return through(res, name);
                }
                if lang == "rust" && (q.contains("::") || matches!(q, "crate" | "super")) {
                    let mut segs: Vec<String> = q.split("::").map(String::from).collect();
                    segs.push(name.to_string());
                    if let Resolved::File { path, rest } = self.resolver.rust_path(&self.files[f as usize].path, &segs) {
                        return self.rust_item(&path, &rest, name).map(exact).unwrap_or(none);
                    }
                    return none;
                }
                if lang == "elm" {
                    // A qualifier that is not an import names a default import (`List`, `Cmd`),
                    // which the package scope in `resolve_file` looks up next, or nothing.
                    return none;
                }
                // `Type::method`, `obj.method`, `Class.method`.
                if self.unqualified_visible(f, q).is_some()
                    && let Some(id) = self.member_of(f, q, name) {
                        return exact(id);
                    }
                if let Some((res, orig)) = locals.get(q) {
                    if let Some(t) = self.file_of(res)
                        && let Some(id) = self.member_of(t, orig, name) {
                            return exact(id);
                        }
                    if !matches!(res, Resolved::File { .. }) {
                        return none; // a member of something from a package
                    }
                }
                match self.fallback(f, name, r.kind, true) {
                    Some(id) => RefRes { target: Some(id), confidence: Confidence::Fallback, external: None },
                    None => none,
                }
            }
        }
    }

    /// `rest` is what was left of a Rust path inside `file`: `[]` (a module), `[item]`, or
    /// `[Type, member]`.
    fn rust_item(&self, path: &str, rest: &[String], name: &str) -> Option<SymId> {
        let file = *self.index.get(path)?;
        match rest {
            [] => None,
            [_] => self.lookup_in_file(file, name, 3),
            [.., container, _] => self.member_of(file, container, name).or_else(|| self.lookup_in_file(file, name, 3)),
        }
    }

    /// What `import X from './file'` binds: an exported top-level symbol named like the local
    /// binding or like the file, else the file's only exported class/function.
    fn default_export(&self, file: u32, local: &str) -> Option<SymId> {
        let f = &self.files[file as usize];
        let top: Vec<&Symbol> = f.facts.symbols.iter().filter(|s| s.parent.is_none() && s.exported).collect();
        let stem = Path::new(&f.path).file_stem().and_then(|s| s.to_str()).unwrap_or("");
        let pick = top
            .iter()
            .find(|s| s.name == "default")
            .or_else(|| top.iter().find(|s| s.name == local))
            .or_else(|| top.iter().find(|s| s.name == stem))
            .or_else(|| {
                let callable: Vec<_> = top.iter().filter(|s| matches!(s.kind, SymbolKind::Class | SymbolKind::Function)).collect();
                (callable.len() == 1).then(|| callable[0])
            })?;
        Some(SymId { file, local: pick.local_id })
    }
}

/// Languages that can name each other's definitions without a manifest in between: a
/// TypeScript file imports JavaScript and the reverse; every other language only itself.
fn language_family(lang: &str) -> &str {
    match lang {
        "typescript" | "tsx" | "javascript" => "ecma",
        other => other,
    }
}

/// Estimated heap bytes of one blob's facts (struct sizes plus string payloads, with a flat
/// allocator overhead per string). An estimate on purpose: it only has to rank graphs for the
/// memory budget, and the daemon reports measured RSS next to it.
pub fn facts_bytes(f: &InternedFacts) -> usize {
    use std::mem::size_of;
    const ALLOC: usize = 16;
    let st = |s: &str| if s.is_empty() { 0 } else { s.len() + ALLOC };
    let ost = |s: &Option<String>| s.as_deref().map(st).unwrap_or(0);
    let mut n = size_of::<InternedFacts>() + ost(&f.module_name);
    n += f.symbols.len() * size_of::<Symbol>() + f.symbols.iter().map(|s| st(&s.name) + ost(&s.signature)).sum::<usize>();
    // Names live once per repository in its `NamePool`, charged by the engine (`names_bytes`).
    n += f.refs.capacity() * size_of::<RefSite>();
    n += f.imports.len() * size_of::<Import>()
        + f.imports
            .iter()
            .map(|i| st(&i.specifier) + ost(&i.alias) + i.names.len() * size_of::<ImportName>() + i.names.iter().map(|n| st(&n.name) + ost(&n.alias)).sum::<usize>())
            .sum::<usize>();
    n += f.hierarchy.len() * size_of::<TypeRelation>() + f.hierarchy.iter().map(|h| st(&h.target)).sum::<usize>();
    let t = &f.types;
    let src = |s: &Option<TypeSource>| match s {
        Some(TypeSource::Named(x) | TypeSource::Expr(x) | TypeSource::Each(x)) => st(x),
        None => 0,
    };
    n += t.bindings.len() * size_of::<Binding>() + t.bindings.iter().map(|b| st(&b.name) + src(&b.ty)).sum::<usize>();
    n += t.members.len() * size_of::<MemberType>() + t.members.iter().map(|m| st(&m.owner) + st(&m.member) + st(&m.ty)).sum::<usize>();
    n += t.returns.len() * size_of::<ReturnType>() + t.returns.iter().map(|r| st(&r.owner) + st(&r.name) + ost(&r.ty)).sum::<usize>();
    n
}

impl GraphData {
    /// Estimated heap bytes this graph owns beyond the (shared) facts of its files, and beyond the
    /// blocks and name tables its `Share` holds when it has one.
    pub fn own_bytes(&self) -> usize {
        self.own_bytes_parts().iter().map(|(_, n)| n).sum()
    }

    /// `own_bytes`, part by part, for measuring where a graph's memory goes.
    pub fn own_bytes_parts(&self) -> Vec<(&'static str, usize)> {
        use std::mem::size_of;
        const ALLOC: usize = 16;
        let shared = self.share.is_some();
        let mut parts = Vec::new();
        let mut files = self.files.len() * size_of::<FileNode>() + self.res.len() * size_of::<Arc<FileRes>>();
        for f in &self.files {
            files += f.path.len() + f.blob_id.len() + 2 * ALLOC;
            if !shared {
                files += name_map_bytes(&f.names);
            }
        }
        parts.push(("files", files));
        // A part shared with another graph (an overlay's, equal to its base's) is charged to the
        // graph it was built for: the one cached first, which held it alone when it was counted.
        let alone = |n: usize| -> usize { if n == 1 { 1 } else { 0 } };
        let index = self.index.len() * (size_of::<String>() + 4 + ALLOC + 8) + self.index.keys().map(|k| k.len()).sum::<usize>();
        parts.push(("path index", index * alone(Arc::strong_count(&self.index))));
        if !shared {
            parts.push(("blocks", self.res.iter().map(|r| blocks::block_bytes(r)).sum::<usize>()));
        }
        let adj = |v: &Vec<Vec<u32>>| v.iter().map(|v| size_of::<Vec<u32>>() + v.len() * 4).sum::<usize>();
        parts.push(("importers", adj(&self.importers) * alone(Arc::strong_count(&self.importers)) + adj(&self.ref_dependents) * alone(Arc::strong_count(&self.ref_dependents))));
        parts.push((
            "external",
            self.external_refs.iter().map(|(k, v)| k.as_os_str().len() + 2 * ALLOC + v.len() * 8).sum::<usize>()
                + self.external_importers.iter().map(|(k, v)| k.as_os_str().len() + 2 * ALLOC + v.len() * 4).sum::<usize>(),
        ));
        parts.push(("name index", self.name_index.bytes()));
        parts.push(("incoming", self.incoming.bytes()));
        parts.push(("ranks", self.file_rank.len() * 8 + self.symbol_rank.iter().map(|v| size_of::<Vec<f64>>() + v.len() * 8).sum::<usize>()));
        parts.push(("ppr", self.ppr.get().map(|p| p.bytes()).unwrap_or(0)));
        parts.push(("elm modules", self.elm_modules.iter().map(|(k, v)| k.len() + 3 * ALLOC + v.len() * 4).sum::<usize>() * alone(Arc::strong_count(&self.elm_modules))));
        // Only once built (lazily, on the first overlay derived from this graph): about 1-2 MB on
        // tessera (15k keys, 144k entries).
        parts.push((
            "soft index",
            self.soft_index.get().map_or(0, |idx| idx.iter().map(|(k, v)| size_of::<String>() + k.len() + ALLOC + size_of::<Vec<u32>>() + ALLOC + v.len() * 4 + 8).sum::<usize>()),
        ));
        parts.push(("words", self.words_if_built().map_or(0, |w| w.bytes())));
        // The resolver keeps every path of the view in a set.
        let paths = self.files.iter().filter(|f| f.alive).map(|f| f.path.len() + size_of::<String>() + ALLOC + 8).sum::<usize>();
        parts.push(("resolver", paths * alone(Arc::strong_count(self.resolver.paths()))));
        parts
    }
}

pub use rank::pagerank;
