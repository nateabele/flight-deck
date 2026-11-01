//! Query primitives over a `ViewGraph`: what the read-only tools (step 3) are built from.
//!
//! Every result is an `Answer`: the data plus the `ViewLabel` of the view that produced it, so a
//! caller can always tell which checkout answered (the spec's anti-goal is an unlabelled answer
//! from the wrong one). Every path in a result is absolute.

use crate::facts::*;
use crate::git::ViewLabel;
use crate::graph::{Confidence, SymId, ViewGraph};
use crate::resolve::Resolved;
use regex::Regex;
use std::collections::{BTreeMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Answer<T> {
    pub view: ViewLabel,
    pub data: T,
}

#[derive(Debug, Clone)]
pub struct SymbolHit {
    pub id: SymId,
    pub name: String,
    pub kind: SymbolKind,
    pub path: PathBuf,
    pub start_line: u32,
    pub end_line: u32,
    pub signature: Option<String>,
    /// Name of the enclosing symbol (the type of a constructor, the impl of a method).
    pub parent: Option<String>,
    pub exported: bool,
    /// The file's Elm module name, when it has one.
    pub module: Option<String>,
    pub rank: f64,
    /// Which view of the request holds it: 0 is the view that answers, `n` is its `n`th linked
    /// view (`links::Member`). `hit` leaves it 0; whoever merges views sets it.
    pub view: usize,
}

pub enum NameMatch {
    Exact(String),
    Prefix(String),
    Regex(Regex),
}

#[derive(Debug, Clone)]
pub struct OutlineEntry {
    pub depth: u32,
    pub hit: SymbolHit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// Files this file imports / symbols this symbol calls.
    Out,
    /// Files that import this file / symbols that call this symbol.
    In,
}

#[derive(Debug, Clone)]
pub struct DepEntry {
    pub path: PathBuf,
    pub depth: u32,
    /// Outside this worktree: reached through a manifest path (e.g. elm.json `../tessera/...`).
    pub external: bool,
}

#[derive(Debug, Clone)]
pub struct RefHit {
    pub path: PathBuf,
    pub line: u32,
    /// The symbol the reference sits in, when it sits in one.
    pub enclosing: Option<String>,
    pub kind: RefKind,
    pub confidence: Confidence,
}

#[derive(Debug, Clone)]
pub struct CallEntry {
    pub hit: SymbolHit,
    pub depth: u32,
    /// Line of the call: in the caller's file for `In`, in the origin's file for `Out`.
    pub line: u32,
    pub confidence: Confidence,
}

#[derive(Debug, Clone)]
pub struct RadiusEntry {
    pub path: PathBuf,
    pub depth: u32,
    pub rank: f64,
}

#[derive(Debug, Clone, Default)]
pub struct LangStats {
    pub files: u64,
    pub lines: u64,
    pub symbols: u64,
}

#[derive(Debug, Clone, Default)]
pub struct ProjectStats {
    pub files: u64,
    pub lines: u64,
    pub symbols: u64,
    pub by_language: BTreeMap<String, LangStats>,
}

fn callable(k: SymbolKind) -> bool {
    matches!(k, SymbolKind::Function | SymbolKind::Method | SymbolKind::Const | SymbolKind::Constructor | SymbolKind::Macro | SymbolKind::Port)
}

impl ViewGraph {
    fn answer<T>(&self, data: T) -> Answer<T> {
        Answer { view: self.label.clone(), data }
    }

    /// Absolute path of a file outside this worktree that an import reached (`Resolved::External`).
    pub fn external_abs(&self, rel: &Path) -> PathBuf {
        crate::resolve::absolute(&self.root, rel)
    }

    pub fn hit(&self, id: SymId) -> SymbolHit {
        let f = self.file(id.file);
        let s = f.symbol(id.local);
        SymbolHit {
            id,
            name: s.name.clone(),
            kind: s.kind,
            path: self.abs(id.file),
            start_line: s.start_line,
            end_line: s.end_line,
            signature: s.signature.clone(),
            parent: s.parent.map(|p| f.symbol(p).name.clone()),
            exported: s.exported,
            module: f.facts.module_name.clone(),
            rank: self.symbol_rank[id.file as usize][id.local as usize],
            view: 0,
        }
    }

    /// Find definitions by exact, prefix or regex name, optionally of one kind.
    ///
    /// An exact name containing `.` or `::` is qualified: `Expression.Node.toString` matches the
    /// symbol `toString` in the Elm module `Expression.Node` (or a member `toString` of a type
    /// `Node` in module `Expression`; or in a file whose path ends `…/Node`).
    pub fn find_symbols(&self, m: &NameMatch, kind: Option<SymbolKind>, limit: usize) -> Answer<Vec<SymbolHit>> {
        let mut ids: Vec<SymId> = Vec::new();
        match m {
            NameMatch::Exact(n) => {
                let (qual, name) = match n.rfind(['.']).map(|i| (i, 1)).or_else(|| n.rfind("::").map(|i| (i, 2))) {
                    Some((i, w)) => (Some(&n[..i]), &n[i + w..]),
                    None => (None, n.as_str()),
                };
                if let Some(c) = self.named(name) {
                    ids.extend(c.iter().copied().filter(|id| qual.is_none_or(|q| self.qualifier_matches(*id, q))));
                }
                // Elixir module symbols carry dots in their own name (`Shop.Order`), so the whole
                // string can be a definition rather than a qualified lookup.
                if qual.is_some() && let Some(c) = self.named(n.as_str()) {
                    ids.extend(c.iter().copied());
                    ids.sort();
                    ids.dedup();
                }
            }
            NameMatch::Prefix(_) | NameMatch::Regex(_) => {
                for (fi, f) in self.files.iter().enumerate().filter(|(_, f)| f.alive) {
                    for s in &f.facts.symbols {
                        let ok = match m {
                            NameMatch::Prefix(p) => s.name.starts_with(p.as_str()),
                            NameMatch::Regex(r) => r.is_match(&s.name),
                            NameMatch::Exact(_) => unreachable!(),
                        };
                        if ok && (s.kind != SymbolKind::Impl || kind == Some(SymbolKind::Impl)) {
                            ids.push(SymId { file: fi as u32, local: s.local_id });
                        }
                    }
                }
            }
        }
        let mut hits: Vec<SymbolHit> = ids.into_iter().filter(|id| kind.is_none_or(|k| self.symbol(*id).kind == k)).map(|id| self.hit(id)).collect();
        // Definitions people mean first: exported, then important, then stable by path/line.
        hits.sort_by(|a, b| {
            b.exported
                .cmp(&a.exported)
                .then(b.rank.partial_cmp(&a.rank).unwrap_or(std::cmp::Ordering::Equal))
                .then(a.path.cmp(&b.path))
                .then(a.start_line.cmp(&b.start_line))
        });
        hits.truncate(limit);
        self.answer(hits)
    }

    fn qualifier_matches(&self, id: SymId, qual: &str) -> bool {
        let f = self.file(id.file);
        let s = f.symbol(id.local);
        let module = f.facts.module_name.as_deref();
        if module == Some(qual) {
            return true;
        }
        let parent = s.parent.map(|p| f.symbol(p).name.as_str());
        if let Some(p) = parent {
            if qual == p {
                return true;
            }
            // `Module.Type.member`
            if let Some((m, t)) = qual.rsplit_once('.').or_else(|| qual.rsplit_once("::"))
                && t == p && module.is_none_or(|fm| fm == m) {
                    return true;
                }
        }
        // Path-shaped qualifier (`store::open` -> `…/store.rs`).
        let tail = qual.rsplit(['.', ':']).next().unwrap_or(qual);
        Path::new(&f.path).file_stem().is_some_and(|st| st == tail)
    }

    pub fn outline(&self, path: &Path) -> Answer<Option<Vec<OutlineEntry>>> {
        let Some(fi) = self.file_idx(path) else { return self.answer(None) };
        let f = self.file(fi);
        let mut out: Vec<OutlineEntry> = f
            .facts
            .symbols
            .iter()
            .map(|s| {
                let mut depth = 0;
                let mut cur = s.parent;
                while let Some(p) = cur {
                    depth += 1;
                    cur = f.symbol(p).parent;
                }
                OutlineEntry { depth, hit: self.hit(SymId { file: fi, local: s.local_id }) }
            })
            .collect();
        out.sort_by_key(|e| (e.hit.start_line, e.depth));
        self.answer(Some(out))
    }

    /// Transitive imports (`Out`) or importers (`In`) of a file up to `depth` hops.
    pub fn file_deps(&self, path: &Path, dir: Direction, depth: u32) -> Answer<Option<Vec<DepEntry>>> {
        let Some(start) = self.file_idx(path) else { return self.answer(None) };
        let mut seen: HashSet<u32> = HashSet::from([start]);
        let mut queue: VecDeque<(u32, u32)> = VecDeque::from([(start, 0)]);
        let mut out = Vec::new();
        let mut externals: HashSet<PathBuf> = HashSet::new();
        while let Some((f, d)) = queue.pop_front() {
            if d >= depth {
                continue;
            }
            let next: Vec<u32> = match dir {
                Direction::Out => self.res[f as usize].edges.clone(),
                Direction::In => self.importers[f as usize].clone(),
            };
            if dir == Direction::Out {
                for r in &self.res[f as usize].imports {
                    if let Resolved::External(p) = r {
                        let abs = self.external_abs(p);
                        if externals.insert(abs.clone()) {
                            out.push(DepEntry { path: abs, depth: d + 1, external: true });
                        }
                    }
                }
            }
            for n in next {
                if seen.insert(n) {
                    out.push(DepEntry { path: self.abs(n), depth: d + 1, external: false });
                    queue.push_back((n, d + 1));
                }
            }
        }
        out.sort_by(|a, b| a.depth.cmp(&b.depth).then(a.path.cmp(&b.path)));
        self.answer(Some(out))
    }

    pub fn references(&self, id: SymId) -> Answer<Vec<RefHit>> {
        let mut out: Vec<RefHit> = self
            .incoming
            .get(&id)
            .unwrap_or(&[])
            .iter()
            .map(|&(fi, ri)| {
                let f = self.file(fi);
                let r = &f.facts.refs[ri as usize];
                RefHit {
                    path: self.abs(fi),
                    line: r.line,
                    enclosing: r.enclosing.map(|e| f.symbol(e).name.clone()),
                    kind: r.kind,
                    confidence: self.res[fi as usize].refs[ri as usize].confidence,
                }
            })
            .collect();
        out.sort_by(|a, b| a.path.cmp(&b.path).then(a.line.cmp(&b.line)));
        self.answer(out)
    }

    /// Callers (`In`) or callees (`Out`) of a symbol, breadth-first to `depth`. Type mentions are
    /// references but not calls, so they are left out.
    pub fn calls(&self, id: SymId, dir: Direction, depth: u32) -> Answer<Vec<CallEntry>> {
        let mut seen: HashSet<SymId> = HashSet::from([id]);
        let mut queue: VecDeque<(SymId, u32)> = VecDeque::from([(id, 0)]);
        let mut out = Vec::new();
        while let Some((cur, d)) = queue.pop_front() {
            if d >= depth {
                continue;
            }
            let mut step: Vec<(SymId, u32, Confidence)> = Vec::new();
            match dir {
                Direction::In => {
                    for &(fi, ri) in self.incoming.get(&cur).unwrap_or(&[]) {
                        let f = self.file(fi);
                        let r = &f.facts.refs[ri as usize];
                        if r.kind == RefKind::Type {
                            continue;
                        }
                        if let Some(e) = r.enclosing {
                            step.push((SymId { file: fi, local: e }, r.line, self.res[fi as usize].refs[ri as usize].confidence));
                        }
                    }
                }
                Direction::Out => {
                    let f = self.file(cur.file);
                    for (r, rr) in f.facts.refs.iter().zip(&self.res[cur.file as usize].refs) {
                        let Some(t) = rr.target else { continue };
                        if r.kind == RefKind::Type || !callable(self.symbol(t).kind) {
                            continue;
                        }
                        if r.enclosing.is_some_and(|e| self.within(cur.file, e, cur.local)) {
                            step.push((t, r.line, rr.confidence));
                        }
                    }
                }
            }
            for (s, line, confidence) in step {
                if seen.insert(s) {
                    out.push(CallEntry { hit: self.hit(s), depth: d + 1, line, confidence });
                    queue.push_back((s, d + 1));
                }
            }
        }
        out.sort_by(|a, b| a.depth.cmp(&b.depth).then(a.hit.path.cmp(&b.hit.path)).then(a.hit.start_line.cmp(&b.hit.start_line)));
        self.answer(out)
    }

    /// Is symbol `inner` the same as, or nested inside, `outer` (same file)?
    pub(crate) fn within(&self, file: u32, inner: u32, outer: u32) -> bool {
        let f = self.file(file);
        let mut cur = Some(inner);
        while let Some(c) = cur {
            if c == outer {
                return true;
            }
            cur = f.symbol(c).parent;
        }
        false
    }

    /// Everything that transitively imports `path`, most important first.
    pub fn blast_radius(&self, path: &Path) -> Answer<Option<Vec<RadiusEntry>>> {
        let Some(start) = self.file_idx(path) else { return self.answer(None) };
        let mut seen: HashSet<u32> = HashSet::from([start]);
        let mut queue: VecDeque<(u32, u32)> = VecDeque::from([(start, 0)]);
        let mut out = Vec::new();
        while let Some((f, d)) = queue.pop_front() {
            for &imp in &self.importers[f as usize] {
                if seen.insert(imp) {
                    out.push(RadiusEntry { path: self.abs(imp), depth: d + 1, rank: self.file_rank[imp as usize] });
                    queue.push_back((imp, d + 1));
                }
            }
        }
        out.sort_by(|a, b| b.rank.partial_cmp(&a.rank).unwrap_or(std::cmp::Ordering::Equal).then(a.path.cmp(&b.path)));
        self.answer(Some(out))
    }

    /// How many references resolved exactly, by unique-name fallback, or not at all: the quick
    /// health check of a resolver on a real repository.
    pub fn resolution_counts(&self) -> (u64, u64, u64) {
        let (mut exact, mut fallback, mut none) = (0, 0, 0);
        for r in self.res.iter().flat_map(|r| &r.refs) {
            match (r.target, r.confidence) {
                (Some(_), Confidence::Exact) => exact += 1,
                (Some(_), Confidence::Fallback) => fallback += 1,
                (None, _) => none += 1,
            }
        }
        (exact, fallback, none)
    }

    pub fn file_rank_of(&self, path: &Path) -> Option<f64> {
        self.file_idx(path).map(|i| self.file_rank[i as usize])
    }

    pub fn stats(&self) -> Answer<ProjectStats> {
        let mut st = ProjectStats::default();
        for f in self.files.iter().filter(|f| f.alive) {
            let l = st.by_language.entry(f.language.to_string()).or_default();
            l.files += 1;
            l.lines += f.facts.line_count as u64;
            l.symbols += f.facts.symbols.len() as u64;
            st.files += 1;
            st.lines += f.facts.line_count as u64;
            st.symbols += f.facts.symbols.len() as u64;
        }
        self.answer(st)
    }
}
