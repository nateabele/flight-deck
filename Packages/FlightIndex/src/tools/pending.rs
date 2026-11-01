//! `impact pending=true`: the call sites the worktree's diff still owes an edit.
//!
//! A refactor changes a signature in one file and then has to visit every caller. The step that
//! goes wrong is the last one: a call site is forgotten. This view finds, from the facts alone,
//! the symbols whose *call shape* changed between the base tree and the worktree (a parameter
//! added or dropped, a type changed, the symbol renamed or deleted), then lists their references,
//! implementers and overriders on lines the diff has not touched yet.
//!
//! Three pieces, each a pure function so the tests can drive them without a daemon:
//! * `call_shape` reduces a signature to what a caller depends on. In Rust, TypeScript,
//!   JavaScript, Elixir and annotated Elm a parameter's *name* is invisible at the call site, so
//!   renaming one is not a change; Python keyword arguments and Swift labels are, so those
//!   languages compare the signature as written.
//! * `changes` pairs a file's base symbols with its worktree symbols by (parent chain, name, kind
//!   family) and reports the pairs whose shapes differ and the base symbols with no partner.
//! * `LineDiff` is a line LCS between the base blob and the file on disk. A reference counts as
//!   edited when a changed line falls on it or within `CALL_WINDOW` lines after it (the rest of a
//!   call spread over several lines).
//!
//! The sites of a changed symbol are its resolved references (this view and the linked ones),
//! the base graph's references for a removed symbol, the same-named members of types that
//! implement or extend a changed member's parent, and `text_sites`: `name(` in the files that
//! import the symbol, for calls the parsers do not see (Rust macro arguments, TypeScript template
//! substitutions).

use super::{is_test_path, Ctx, ToolError, ToolResult};
use crate::facts::{InternedFacts, RefKind, Symbol, SymbolKind};
use crate::graph::{Confidence, SymId, ViewGraph};
use crate::links::Views;
use std::collections::{BTreeSet, HashMap};
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Lines after a reference's own line that still belong to the call: an argument added on the
/// next line of a multi-line call edits the call without touching the line the name is on.
pub const CALL_WINDOW: u32 = 2;
/// Rows of one changed symbol's list, unless `limit` says otherwise.
const LIST_CAP: usize = 30;
/// Above this many cells the LCS table is not built and the differing middle of the file counts
/// as edited (16 MB of `u32`).
const LCS_MAX_CELLS: usize = 4_000_000;

/// Reads a base-tree blob's text by blob id.
pub type BlobText = Box<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// What the view's base commit looked like: its resolved graph (re-pointed at this worktree) and
/// a way to read one of its blobs. Built by the service only when `pending` asks for it.
pub struct Baseline {
    pub graph: Arc<ViewGraph>,
    /// The text of a base-tree blob, by blob id.
    pub text: BlobText,
}

// ---- call shapes ------------------------------------------------------------------------------

/// The part of `sig` a caller depends on, for comparing two versions of one symbol.
pub fn call_shape(lang: &str, sig: &str) -> String {
    let sig = sig.split_whitespace().collect::<Vec<_>>().join(" ");
    match lang {
        "rust" | "typescript" | "tsx" | "javascript" => strip_param_names(&sig),
        // `f : A -> B` is the annotation; without one the index keeps the left side `f a b`.
        "elm" if sig.split_whitespace().nth(1) != Some(":") => {
            let mut words = sig.split_whitespace();
            let name = words.next().unwrap_or("");
            std::iter::once(name.to_string()).chain(words.map(|_| "_".to_string())).collect::<Vec<_>>().join(" ")
        }
        _ => sig,
    }
}

/// Byte offsets of the first top-level `(` and its matching `)`, skipping generic brackets
/// (`fn f<F: Fn(u8)>(…)`). Arrows (`->`, `=>`) are not closing angle brackets.
fn param_list(s: &str) -> Option<(usize, usize)> {
    let b = s.as_bytes();
    let mut angle = 0i32;
    let mut open = None;
    let mut depth = 0i32;
    for (i, &c) in b.iter().enumerate() {
        let arrow = c == b'>' && i > 0 && matches!(b[i - 1], b'-' | b'=');
        match open {
            None => match c {
                b'<' => angle += 1,
                b'>' if !arrow => angle -= 1,
                b'(' if angle <= 0 => {
                    open = Some(i);
                    depth = 1;
                }
                _ => {}
            },
            Some(o) => match c {
                b'(' | b'[' | b'{' => depth += 1,
                b'<' => depth += 1,
                b'>' if !arrow => depth -= 1,
                b')' | b']' | b'}' => {
                    depth -= 1;
                    if depth == 0 && c == b')' {
                        return Some((o, i));
                    }
                }
                _ => {}
            },
        }
    }
    None
}

/// Split at top-level occurrences of `sep` (outside (), [], {}, <>).
fn split_top(s: &str, sep: u8) -> Vec<&str> {
    let b = s.as_bytes();
    let (mut depth, mut start, mut out) = (0i32, 0usize, Vec::new());
    for (i, &c) in b.iter().enumerate() {
        let arrow = c == b'>' && i > 0 && matches!(b[i - 1], b'-' | b'=');
        match c {
            b'(' | b'[' | b'{' | b'<' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b'>' if !arrow => depth -= 1,
            _ if c == sep && depth == 0 => {
                out.push(&s[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    out.push(&s[start..]);
    out
}

/// Top-level position of a single `:` (not `::`) or `=` (not `==`, `=>`), whichever is asked.
fn find_top(s: &str, want: u8) -> Option<usize> {
    let b = s.as_bytes();
    let mut depth = 0i32;
    for (i, &c) in b.iter().enumerate() {
        let arrow = c == b'>' && i > 0 && matches!(b[i - 1], b'-' | b'=');
        match c {
            b'(' | b'[' | b'{' | b'<' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b'>' if !arrow => depth -= 1,
            _ if c == want && depth == 0 => {
                let prev = if i > 0 { b[i - 1] } else { 0 };
                let next = b.get(i + 1).copied().unwrap_or(0);
                let lone = match want {
                    b':' => prev != b':' && next != b':',
                    b'=' => !matches!(prev, b'=' | b'!' | b'<' | b'>') && !matches!(next, b'=' | b'>'),
                    _ => true,
                };
                if lone {
                    return Some(i);
                }
            }
            _ => {}
        }
    }
    None
}

/// `fn f(a: u8, mut b: &str) -> X` → `fn f(u8, &str) -> X`; `function f(a, b?: T, c = 1)` →
/// `function f(_, ?T, _=)`. A receiver (`&mut self`) is kept as written.
fn strip_param_names(sig: &str) -> String {
    let Some((open, close)) = param_list(sig) else { return sig.to_string() };
    let inner = &sig[open + 1..close];
    let params: Vec<String> = split_top(inner, b',')
        .into_iter()
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (head, default) = match find_top(p, b'=') {
                Some(i) => (p[..i].trim(), true),
                None => (p, false),
            };
            let (name, ty) = match find_top(head, b':') {
                Some(i) => (head[..i].trim(), Some(head[i + 1..].trim())),
                None => (head, None),
            };
            if ty.is_none() && name.split(|c: char| !c.is_alphanumeric() && c != '_').any(|w| w == "self" || w == "this") {
                return name.to_string();
            }
            let rest = if name.starts_with("...") { "..." } else { "" };
            let opt = if name.ends_with('?') { "?" } else { "" };
            format!("{rest}{opt}{}{}", ty.unwrap_or("_"), if default { "=" } else { "" })
        })
        .collect();
    format!("{}({}){}", &sig[..open], params.join(", "), &sig[close + 1..])
}

// ---- symbol pairing ---------------------------------------------------------------------------

/// What happened to one base symbol.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    /// Present on both sides with a different call shape.
    Changed { base: u32, cur: u32 },
    /// Gone from the file: deleted, renamed or moved.
    Removed { base: u32 },
}

/// Kinds that are only containers: their members are compared, not their header line.
fn container(k: SymbolKind) -> bool {
    matches!(k, SymbolKind::Module | SymbolKind::Impl | SymbolKind::Extension)
}

/// Kinds that can turn into each other without the symbol becoming another one: an Elm value
/// that gains an argument goes from `Const` to `Function`.
fn family(k: SymbolKind) -> u8 {
    match k {
        SymbolKind::Function | SymbolKind::Method | SymbolKind::Const | SymbolKind::Variable | SymbolKind::Macro | SymbolKind::Port => 0,
        SymbolKind::Struct | SymbolKind::Enum | SymbolKind::Class | SymbolKind::Interface | SymbolKind::TypeAlias | SymbolKind::Trait => 1,
        SymbolKind::Constructor => 2,
        SymbolKind::Field => 3,
        SymbolKind::Module | SymbolKind::Impl | SymbolKind::Extension => 4,
    }
}

fn parent_chain(f: &InternedFacts, s: &Symbol) -> String {
    let mut parts = Vec::new();
    let mut p = s.parent;
    while let Some(id) = p {
        let Some(ps) = f.symbols.get(id as usize) else { break };
        parts.push(ps.name.as_str());
        p = ps.parent;
    }
    parts.reverse();
    parts.join("::")
}

fn shape(lang: &str, s: &Symbol) -> String {
    call_shape(lang, s.signature.as_deref().unwrap_or(&s.name))
}

/// The base symbols of one file whose call shape changed or that disappeared. Symbols sharing a
/// key (overloads, Elixir clauses of several arities) are paired by equal shape first, then in
/// order, so adding an arity next to an old one changes nothing.
pub fn changes(lang: &str, base: &InternedFacts, cur: &InternedFacts) -> Vec<Change> {
    type Key = (String, String, u8);
    let key = |f: &InternedFacts, s: &Symbol| -> Key { (parent_chain(f, s), s.name.clone(), family(s.kind)) };
    let mut cur_by: HashMap<Key, Vec<u32>> = HashMap::new();
    for s in cur.symbols.iter().filter(|s| !container(s.kind)) {
        cur_by.entry(key(cur, s)).or_default().push(s.local_id);
    }
    let mut base_by: Vec<(Key, Vec<u32>)> = Vec::new();
    for s in base.symbols.iter().filter(|s| !container(s.kind)) {
        let k = key(base, s);
        match base_by.iter_mut().find(|(bk, _)| *bk == k) {
            Some((_, v)) => v.push(s.local_id),
            None => base_by.push((k, vec![s.local_id])),
        }
    }
    let mut out = Vec::new();
    for (k, bs) in base_by {
        let mut cs: Vec<u32> = cur_by.remove(&k).unwrap_or_default();
        let mut left: Vec<u32> = Vec::new();
        for b in bs {
            let bshape = shape(lang, &base.symbols[b as usize]);
            match cs.iter().position(|&c| shape(lang, &cur.symbols[c as usize]) == bshape) {
                Some(i) => {
                    cs.remove(i);
                }
                None => left.push(b),
            }
        }
        for (i, b) in left.into_iter().enumerate() {
            out.push(match cs.get(i) {
                Some(&c) => Change::Changed { base: b, cur: c },
                None => Change::Removed { base: b },
            });
        }
    }
    out
}

// ---- line diff --------------------------------------------------------------------------------

/// Which lines of the worktree file differ from the base blob, and where an unchanged base line
/// now sits.
pub struct LineDiff {
    /// Per worktree line (0-based): not part of the common subsequence.
    changed: Vec<bool>,
    /// Per base line (0-based): its worktree line, if it survived unchanged.
    to_cur: Vec<Option<u32>>,
}

impl LineDiff {
    pub fn new(base: &str, cur: &str) -> LineDiff {
        let a: Vec<&str> = base.lines().collect();
        let b: Vec<&str> = cur.lines().collect();
        let mut changed = vec![true; b.len()];
        let mut to_cur = vec![None; a.len()];
        let mut pre = 0;
        while pre < a.len() && pre < b.len() && a[pre] == b[pre] {
            changed[pre] = false;
            to_cur[pre] = Some(pre as u32);
            pre += 1;
        }
        let mut suf = 0;
        while suf < a.len() - pre && suf < b.len() - pre && a[a.len() - 1 - suf] == b[b.len() - 1 - suf] {
            changed[b.len() - 1 - suf] = false;
            to_cur[a.len() - 1 - suf] = Some((b.len() - 1 - suf) as u32);
            suf += 1;
        }
        let (ma, mb) = (&a[pre..a.len() - suf], &b[pre..b.len() - suf]);
        let (n, m) = (ma.len(), mb.len());
        if n > 0 && m > 0 && (n + 1) * (m + 1) <= LCS_MAX_CELLS {
            // lcs[i][j]: length of the LCS of ma[i..] and mb[j..].
            let w = m + 1;
            let mut lcs = vec![0u32; (n + 1) * w];
            for i in (0..n).rev() {
                for j in (0..m).rev() {
                    lcs[i * w + j] = if ma[i] == mb[j] { lcs[(i + 1) * w + j + 1] + 1 } else { lcs[(i + 1) * w + j].max(lcs[i * w + j + 1]) };
                }
            }
            let (mut i, mut j) = (0, 0);
            while i < n && j < m {
                if ma[i] == mb[j] {
                    changed[pre + j] = false;
                    to_cur[pre + i] = Some((pre + j) as u32);
                    i += 1;
                    j += 1;
                } else if lcs[(i + 1) * w + j] >= lcs[i * w + j + 1] {
                    i += 1;
                } else {
                    j += 1;
                }
            }
        }
        LineDiff { changed, to_cur }
    }

    /// Whether 1-based worktree `line` was edited. Past the end of the file: no.
    pub fn edited(&self, line: u32) -> bool {
        line >= 1 && self.changed.get(line as usize - 1).copied().unwrap_or(false)
    }

    /// Whether `line` or one of the `CALL_WINDOW` lines after it was edited. The window stops
    /// before `next`, the next reference to the same symbol in the file, so editing one of two
    /// adjacent calls does not mark the other edited.
    pub fn edited_near(&self, line: u32, next: Option<u32>) -> bool {
        let end = next.map(|n| n.saturating_sub(1)).unwrap_or(u32::MAX).min(line + CALL_WINDOW).max(line);
        (line..=end).any(|l| self.edited(l))
    }

    /// The worktree line (1-based) of unchanged base `line`, or `None` if that line was edited.
    pub fn to_cur(&self, line: u32) -> Option<u32> {
        if line == 0 {
            return None;
        }
        self.to_cur.get(line as usize - 1).copied().flatten().map(|l| l + 1)
    }
}

// ---- the tool ---------------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum SiteKind {
    Call,
    Use,
    Type,
    Implements,
}

impl SiteKind {
    fn of(k: RefKind) -> SiteKind {
        match k {
            RefKind::Call => SiteKind::Call,
            RefKind::Use => SiteKind::Use,
            RefKind::Type => SiteKind::Type,
        }
    }
    fn label(self) -> &'static str {
        match self {
            SiteKind::Call => "call",
            SiteKind::Use => "use",
            SiteKind::Type => "type",
            SiteKind::Implements => "implementer",
        }
    }
}

struct Site {
    view: usize,
    path: PathBuf,
    line: u32,
    kind: SiteKind,
    enclosing: Option<String>,
    fallback: bool,
    /// Found by `text_sites`, not through a resolved reference.
    by_text: bool,
    rank: f64,
}

struct Seed {
    name: String,
    kind: SymbolKind,
    /// Where the symbol is (worktree) or was (base, for a removed one).
    path: PathBuf,
    line: u32,
    before: String,
    after: Option<String>,
    pending: Vec<Site>,
    edited: usize,
}

/// Per-request caches: diffs of worktree files against their base blob, and file texts.
struct Diffs<'a> {
    cur: &'a ViewGraph,
    base: &'a Baseline,
    diffs: HashMap<String, Option<Arc<LineDiff>>>,
    /// Worktree file texts, read once per request however many changed symbols scan them.
    texts: HashMap<PathBuf, Option<Arc<str>>>,
}

impl Diffs<'_> {
    fn text(&mut self, abs: &Path) -> Option<Arc<str>> {
        self.texts.entry(abs.to_path_buf()).or_insert_with(|| std::fs::read_to_string(abs).ok().map(Arc::from)).clone()
    }

    /// The diff of worktree file `rel` against base, or `None` when it is unchanged. A file with
    /// no base version diffs against the empty file, so every line of it is edited.
    fn of(&mut self, rel: &str) -> Option<Arc<LineDiff>> {
        if let Some(d) = self.diffs.get(rel) {
            return d.clone();
        }
        let bg = &self.base.graph;
        let cur_blob = self.cur.file_idx(Path::new(rel)).map(|i| self.cur.file(i).blob_id.clone());
        let base_blob = bg.file_idx(Path::new(rel)).filter(|&i| bg.file(i).alive).map(|i| bg.file(i).blob_id.clone());
        let d = if cur_blob.is_some() && cur_blob == base_blob {
            None
        } else {
            let old = base_blob.and_then(|b| (self.base.text)(&b)).unwrap_or_default();
            let new = self.text(&self.cur.root.join(rel)).unwrap_or_default();
            Some(Arc::new(LineDiff::new(&old, &new)))
        };
        self.diffs.insert(rel.to_string(), d.clone());
        d
    }
}

fn rel_of(root: &Path, p: &Path) -> String {
    p.strip_prefix(root).unwrap_or(p).to_string_lossy().replace(std::path::MAIN_SEPARATOR, "/")
}

fn last_segment(s: &str) -> &str {
    let s = s.split('<').next().unwrap_or(s).trim();
    s.rsplit([':', '.']).next().unwrap_or(s)
}

pub fn pending(c: &Ctx) -> ToolResult {
    let Some(base) = (c.base)().map_err(ToolError::from)? else {
        return Ok("Pending edits: none (the view has no base commit or no uncommitted changes; the diff is what pending=true follows up)\n".to_string());
    };
    let cur = c.graph;
    let bg = &*base.graph;
    let views = c.views();
    let include_tests = c.args.flag(&["include_tests"], true);
    let only: Option<String> = c.args.path(super::args::FILE).map(|p| rel_of(&cur.root, &p));
    let keep = |v: usize, p: &Path| include_tests || !is_test_path(&rel_of(&views.graph(v).root, p));
    let cap = c.args.num(&["limit"]).filter(|&n| n > 0).unwrap_or(LIST_CAP);
    let mut diffs = Diffs { cur, base: &base, diffs: HashMap::new(), texts: HashMap::new() };

    // Files that differ from the base tree, and the base files the worktree deleted.
    let mut differing = 0usize;
    let mut seeds: Vec<Seed> = Vec::new();
    for fi in 0..cur.files.len() as u32 {
        let node = cur.file(fi);
        let bi = bg.file_idx(Path::new(&node.path)).filter(|&i| bg.file(i).alive);
        if !node.alive || bi.is_some_and(|i| bg.file(i).blob_id == node.blob_id) {
            continue;
        }
        differing += 1;
        let Some(bi) = bi else { continue }; // a new file only adds symbols
        if only.as_deref().is_some_and(|o| o != node.path) {
            continue;
        }
        for ch in changes(node.language, &bg.file(bi).facts, &node.facts) {
            seeds.push(match ch {
                Change::Changed { base: b, cur: s } => changed_seed(&views, &mut diffs, &keep, bi, SymId { file: fi, local: s }, b),
                Change::Removed { base: b } => removed_seed(&mut diffs, &keep, SymId { file: bi, local: b }),
            });
        }
    }
    for bi in 0..bg.files.len() as u32 {
        let node = bg.file(bi);
        if !node.alive || cur.file_idx(Path::new(&node.path)).is_some_and(|i| cur.file(i).alive) {
            continue;
        }
        differing += 1;
        if only.as_deref().is_some_and(|o| o != node.path) {
            continue;
        }
        for s in node.facts.symbols.iter().filter(|s| !container(s.kind)) {
            seeds.push(removed_seed(&mut diffs, &keep, SymId { file: bi, local: s.local_id }));
        }
    }

    // A removed private symbol nobody referenced is noise: an edit inside one file.
    seeds.retain(|s| s.after.is_some() || !s.pending.is_empty() || s.edited > 0);
    for s in &mut seeds {
        s.pending.sort_by(|a, b| {
            (a.by_text, a.fallback, a.kind, a.view)
                .cmp(&(b.by_text, b.fallback, b.kind, b.view))
                .then(b.rank.partial_cmp(&a.rank).unwrap_or(std::cmp::Ordering::Equal))
                .then(a.path.cmp(&b.path))
                .then(a.line.cmp(&b.line))
        });
    }
    seeds.sort_by(|a, b| b.pending.len().cmp(&a.pending.len()).then(a.path.cmp(&b.path)).then(a.line.cmp(&b.line)));

    let total: usize = seeds.iter().map(|s| s.pending.len()).sum();
    let mut out = String::new();
    if seeds.is_empty() {
        let _ = writeln!(out, "Pending edits: no signature changed in the diff ({differing} file(s) differ from the base); nothing to follow up.");
        return Ok(c.fit(out));
    }
    let _ = writeln!(out, "Pending edits: {} signature change(s) in the diff; {total} site(s) not yet edited", seeds.len());
    for s in &seeds {
        out.push('\n');
        match &s.after {
            Some(after) => {
                let _ = writeln!(out, "Changed: {} ({}) {}:L{}", s.name, s.kind.as_str(), s.path.display(), s.line);
                let _ = writeln!(out, "  was: {}", s.before);
                let _ = writeln!(out, "  now: {after}");
            }
            None => {
                let _ = writeln!(out, "Removed or renamed: {} ({}), was {}:L{}", s.name, s.kind.as_str(), s.path.display(), s.line);
                let _ = writeln!(out, "  was: {}", s.before);
            }
        }
        if s.pending.is_empty() {
            let _ = writeln!(out, "  Not yet edited: none ({} site(s) already edited)", s.edited);
            continue;
        }
        let _ = writeln!(out, "  Not yet edited ({}; {} already edited):", s.pending.len(), s.edited);
        for site in s.pending.iter().take(cap) {
            let text = diffs.text(&site.path);
            let code = text.as_deref().and_then(|t| t.lines().nth(site.line as usize - 1)).map(|l| {
                let l = l.trim();
                let cut = l.char_indices().nth(120).map(|(i, _)| i).unwrap_or(l.len());
                format!(": `{}{}`", &l[..cut], if cut < l.len() { "…" } else { "" })
            });
            let _ = writeln!(
                out,
                "    {}:L{} {}{}{}{}{}",
                site.path.display(),
                site.line,
                site.kind.label(),
                site.enclosing.as_ref().map(|e| format!(" in {e}")).unwrap_or_default(),
                if site.fallback { " (matched by name)" } else if site.by_text { " (matched by text)" } else { "" },
                views.tag(site.view).map(|t| format!("  [view: {t}]")).unwrap_or_default(),
                code.unwrap_or_default(),
            );
        }
        if s.pending.len() > cap {
            let _ = writeln!(out, "    … {} more (pass limit={} to see all, or file_path to follow one changed file)", s.pending.len() - cap, s.pending.len());
        }
    }
    Ok(c.fit(out))
}

/// A symbol still in the worktree whose call shape changed: its references (in this view and the
/// linked ones) and the implementers of a changed trait/interface/class member.
fn changed_seed(views: &Views, diffs: &mut Diffs, keep: &dyn Fn(usize, &Path) -> bool, base_file: u32, id: SymId, base_local: u32) -> Seed {
    let cur = diffs.cur;
    let hit = cur.hit(id);
    let base_sym = diffs.base.graph.file(base_file).symbol(base_local).clone();
    let mut seed = Seed {
        name: hit.name.clone(),
        kind: hit.kind,
        path: hit.path.clone(),
        line: cur.symbol(id).start_line,
        before: base_sym.signature.clone().unwrap_or_else(|| base_sym.name.clone()),
        after: Some(hit.signature.clone().unwrap_or_else(|| hit.name.clone())),
        pending: Vec::new(),
        edited: 0,
    };
    let mut seen: BTreeSet<(usize, PathBuf, u32)> = BTreeSet::new();
    let refs = views.references(&hit);
    let lines = ref_lines(refs.iter().map(|(v, r)| (*v, r.path.as_path(), r.line)));
    for (v, r) in refs {
        if !keep(v, &r.path) || !seen.insert((v, r.path.clone(), r.line)) {
            continue;
        }
        let g = views.graph(v);
        let rank = g.file_idx(&r.path).map(|i| g.file_rank[i as usize]).unwrap_or(0.0);
        let next = next_line(&lines, v, &r.path, r.line);
        let edited = v == 0 && diffs.of(&rel_of(&cur.root, &r.path)).is_some_and(|d| d.edited_near(r.line, next));
        let site = Site { view: v, path: r.path, line: r.line, kind: SiteKind::of(r.kind), enclosing: r.enclosing, fallback: r.confidence == Confidence::Fallback, by_text: false, rank };
        if edited { seed.edited += 1 } else { seed.pending.push(site) }
    }
    let sym = cur.symbol(id);
    let mut files: BTreeSet<u32> = views.importers(0, id.file).into_iter().filter(|(v, _)| *v == 0).map(|(_, f)| f).collect();
    files.insert(id.file);
    files.extend(seen.iter().filter(|(v, _, _)| *v == 0).filter_map(|(_, p, _)| cur.file_idx(p)));
    text_sites(diffs, keep, &sym.name, files, &seen, Some((id.file, sym.start_line, sym.end_line)), &mut seed);
    // Implementers and overriders: same-named members of types that extend or implement the
    // changed member's parent type.
    let parent = sym.parent.map(|p| cur.file(id.file).symbol(p));
    if let Some(parent) = parent.filter(|p| matches!(p.kind, SymbolKind::Trait | SymbolKind::Interface | SymbolKind::Class)) {
        for fi in 0..cur.files.len() as u32 {
            let f = cur.file(fi);
            if !f.alive || f.facts.hierarchy.is_empty() {
                continue;
            }
            for rel in f.facts.hierarchy.iter().filter(|r| last_segment(&r.target) == parent.name) {
                for m in f.facts.symbols.iter().filter(|m| m.parent == Some(rel.symbol) && m.name == sym.name && family(m.kind) == family(sym.kind)) {
                    let path = cur.abs(fi);
                    if (fi == id.file && m.local_id == id.local) || !keep(0, &path) || !seen.insert((0, path.clone(), m.start_line)) {
                        continue;
                    }
                    let edited = diffs.of(&f.path).is_some_and(|d| d.edited_near(m.start_line, None));
                    let enclosing = Some(f.symbol(rel.symbol).name.clone());
                    let site = Site { view: 0, path, line: m.start_line, kind: SiteKind::Implements, enclosing, fallback: false, by_text: false, rank: cur.file_rank[fi as usize] };
                    if edited { seed.edited += 1 } else { seed.pending.push(site) }
                }
            }
        }
    }
    seed
}

/// Reference lines per (view, file), sorted: where each reference's call window must stop.
fn ref_lines<'p>(refs: impl Iterator<Item = (usize, &'p Path, u32)>) -> HashMap<(usize, PathBuf), Vec<u32>> {
    let mut m: HashMap<(usize, PathBuf), Vec<u32>> = HashMap::new();
    for (v, p, l) in refs {
        m.entry((v, p.to_path_buf())).or_default().push(l);
    }
    for v in m.values_mut() {
        v.sort_unstable();
        v.dedup();
    }
    m
}

fn next_line(lines: &HashMap<(usize, PathBuf), Vec<u32>>, v: usize, p: &Path, line: u32) -> Option<u32> {
    lines.get(&(v, p.to_path_buf())).and_then(|ls| ls.iter().copied().find(|&l| l > line))
}

/// A symbol the worktree no longer has: its references in the base graph, carried to where those
/// lines are now. A line the diff changed or deleted counts as edited.
fn removed_seed(diffs: &mut Diffs, keep: &dyn Fn(usize, &Path) -> bool, id: SymId) -> Seed {
    let bg = diffs.base.graph.clone();
    let cur = diffs.cur;
    let s = bg.symbol(id);
    let mut seed = Seed {
        name: s.name.clone(),
        kind: s.kind,
        path: cur.root.join(&bg.file(id.file).path),
        line: s.start_line,
        before: s.signature.clone().unwrap_or_else(|| s.name.clone()),
        after: None,
        pending: Vec::new(),
        edited: 0,
    };
    let refs = bg.references(id).data;
    let lines = ref_lines(refs.iter().map(|r| (0, r.path.as_path(), r.line)));
    let alive = |rel: &str| cur.file_idx(Path::new(rel)).filter(|&i| cur.file(i).alive);
    let mut files: BTreeSet<u32> = bg.importers[id.file as usize].iter().filter_map(|&f| alive(&bg.file(f).path)).collect();
    files.extend(alive(&bg.file(id.file).path));
    let mut covered: BTreeSet<(usize, PathBuf, u32)> = BTreeSet::new();
    for r in refs {
        let next = next_line(&lines, 0, &r.path, r.line);
        let rel = rel_of(&bg.root, &r.path);
        let Some(fi) = alive(&rel) else { continue }; // file deleted
        let path = cur.abs(fi);
        files.insert(fi);
        if !keep(0, &path) {
            continue;
        }
        let line = match diffs.of(&rel) {
            None => Some(r.line),
            // The window is measured in base lines (where `next` is), then carried over.
            Some(d) => {
                let at = d.to_cur(r.line);
                covered.extend(at.map(|l| (0, path.clone(), l)));
                at.filter(|&l| !d.edited_near(l, next.map(|n| l + n.saturating_sub(r.line))))
            }
        };
        covered.extend(line.map(|l| (0, path.clone(), l)));
        match line {
            Some(line) => seed.pending.push(Site {
                view: 0,
                path,
                line,
                kind: SiteKind::of(r.kind),
                enclosing: r.enclosing,
                fallback: r.confidence == Confidence::Fallback,
                by_text: false,
                rank: cur.file_rank[fi as usize],
            }),
            None => seed.edited += 1,
        }
    }
    // The symbol is gone from its file, so it has no span of its own left to skip.
    let name = seed.name.clone();
    text_sites(diffs, keep, &name, files, &covered, None, &mut seed);
    seed
}

/// Line starts that make a line a comment or an import, never a call site.
const NOT_CODE: &[&str] = &["//", "/*", "*", "#", "--", "{-", "import ", "use ", "pub use ", "alias ", "from ", "require ", "export {", "export *"];
/// Words right before a name that make the match a definition, not a call.
const DEFINES: &[&str] = &["fn", "def", "defp", "defmacro", "defmacrop", "function", "func", "@spec", "@callback", "async", "get", "set"];

/// Whether a match after `before` sits inside a string literal: an odd count of unescaped
/// double quotes before it (and of single quotes where they delimit strings; in Rust and Swift a
/// `'` is a lifetime or a character). Backticks are left alone: a call inside a template
/// substitution is a real call.
fn in_string(before: &str, lang: &str) -> bool {
    let odd = |q: char| {
        let mut n = 0;
        let mut esc = false;
        for ch in before.chars() {
            if esc {
                esc = false;
            } else if ch == '\\' {
                esc = true;
            } else if ch == q {
                n += 1;
            }
        }
        n % 2 == 1
    };
    odd('"') || (matches!(lang, "typescript" | "tsx" | "javascript" | "python" | "elixir") && odd('\''))
}

/// Calls of `name` that no reference covers, in `files` (worktree file indexes): a call inside a
/// macro's arguments or a template substitution, which the parsers do not descend into. Comment,
/// import and definition lines are skipped, and so are lines in `covered` (already a reference
/// site) and in `own` (the changed symbol's own span: `(file, start, end)`). Elm is left out: its
/// calls have no parentheses to anchor on, and its references are complete.
fn text_sites(diffs: &mut Diffs, keep: &dyn Fn(usize, &Path) -> bool, name: &str, files: BTreeSet<u32>, covered: &BTreeSet<(usize, PathBuf, u32)>, own: Option<(u32, u32, u32)>, seed: &mut Seed) {
    let cur = diffs.cur;
    let Ok(re) = regex::Regex::new(&format!(r"(?:^|[^A-Za-z0-9_$]){}\s*\(", regex::escape(name))) else { return };
    for fi in files {
        let f = cur.file(fi);
        let path = cur.abs(fi);
        if !f.alive || f.language == "elm" || !keep(0, &path) {
            continue;
        }
        // A file with a function of its own by that name calls that one (a local wrapper, a
        // shadowing helper); its calls to the changed symbol are qualified and resolved already.
        let defines_own = f.facts.symbols.iter().any(|s| s.name == name && family(s.kind) == 0 && own.is_none_or(|(of, st, _)| of != fi || s.start_line != st));
        if defines_own {
            continue;
        }
        let Some(text) = diffs.text(&path) else { continue };
        let mut found: Vec<u32> = Vec::new();
        for (i, l) in text.lines().enumerate() {
            let line = i as u32 + 1;
            let t = l.trim_start();
            if NOT_CODE.iter().any(|c| t.starts_with(c)) || covered.contains(&(0, path.clone(), line)) {
                continue;
            }
            if own.is_some_and(|(of, s, e)| of == fi && (s..=e).contains(&line)) {
                continue;
            }
            let Some(m) = re.find(l) else { continue };
            // The match may begin with the character before the name (the boundary).
            let before = &l[..m.start() + m.as_str().find(name).unwrap_or(0)];
            if before.contains("//") || in_string(before, f.language) || DEFINES.iter().any(|d| before.trim_end().rsplit(|c: char| c.is_whitespace()).next() == Some(d)) {
                continue;
            }
            found.push(line);
        }
        if found.is_empty() {
            continue;
        }
        let mut stops: Vec<u32> = covered.iter().filter(|(_, p, _)| *p == path).map(|(_, _, l)| *l).chain(found.iter().copied()).collect();
        stops.sort_unstable();
        let diff = diffs.of(&f.path);
        for line in found {
            let next = stops.iter().copied().find(|&l| l > line);
            if diff.as_ref().is_some_and(|d| d.edited_near(line, next)) {
                seed.edited += 1;
                continue;
            }
            // The innermost function-like symbol around the line, for the row's `in …`.
            let enclosing = f
                .facts
                .symbols
                .iter()
                .filter(|s| family(s.kind) == 0 && s.start_line <= line && line <= s.end_line)
                .min_by_key(|s| s.end_line - s.start_line)
                .map(|s| s.name.clone());
            seed.pending.push(Site { view: 0, path: path.clone(), line, kind: SiteKind::Call, enclosing, fallback: false, by_text: true, rank: cur.file_rank[fi as usize] });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_renamed_parameter_keeps_the_call_shape_where_names_are_invisible_to_callers() {
        assert_eq!(call_shape("rust", "pub fn f(a: u8, mut b: &str) -> X"), call_shape("rust", "pub fn f(x: u8, b: &str) -> X"));
        assert_eq!(call_shape("typescript", "export function f(a: number, b?: string)"), call_shape("typescript", "export function f(n: number, opt?: string)"));
        assert_eq!(call_shape("javascript", "function f(a, b = 1)"), "function f(_, _=)");
        assert_eq!(call_shape("elm", "f a b"), call_shape("elm", "f x y"));
        assert_eq!(call_shape("rust", "fn m(&mut self, n: u8)"), "fn m(&mut self, u8)");
    }

    #[test]
    fn arity_types_and_keyword_names_change_the_call_shape() {
        assert_ne!(call_shape("rust", "fn f(a: u8)"), call_shape("rust", "fn f(a: u8, b: u8)"));
        assert_ne!(call_shape("typescript", "function f(a: number)"), call_shape("typescript", "function f(a: string)"));
        assert_ne!(call_shape("typescript", "function f(a: number)"), call_shape("typescript", "function f(a?: number)"));
        assert_ne!(call_shape("elm", "f : Int -> Int"), call_shape("elm", "f : Int -> Int -> Int"));
        assert_ne!(call_shape("python", "def f(a, b)"), call_shape("python", "def f(a, c)"));
        assert_ne!(call_shape("rust", "fn f<F: Fn(u8) -> u8>(g: F)"), call_shape("rust", "fn f<F: Fn(u8) -> u8>(g: F, n: Map<K, V>)"));
        assert_eq!(call_shape("rust", "fn f<F: Fn(u8) -> u8>(g: F, n: Map<K, V>)"), "fn f<F: Fn(u8) -> u8>(F, Map<K, V>)");
    }

    #[test]
    fn the_line_diff_marks_edited_lines_and_carries_unchanged_ones() {
        let d = LineDiff::new("a\nb\nc\nd\n", "a\nX\nb\nc2\nd\n");
        assert!(!d.edited(1) && d.edited(2) && !d.edited(3) && d.edited(4) && !d.edited(5));
        assert_eq!(d.to_cur(2), Some(3));
        assert_eq!(d.to_cur(3), None, "c was edited into c2");
        assert_eq!(d.to_cur(4), Some(5));
        assert!(d.edited_near(3, None), "line 4 is within the window after line 3");
        assert!(!d.edited_near(3, Some(4)), "but not when line 4 holds the next reference");
    }
}
