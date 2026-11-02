//! The Swift receiver ladder: the type of `recv` in `recv.m()`, from declarations alone.
//!
//! The root of the receiver is typed by the first rule that applies: `self` is the enclosing
//! type; a lowercase name is the innermost visible binding (parameter, local `let x: T` or
//! `let x = T(...)`, `if`/`guard let`, `for x in [T]`), else a property of the enclosing type or
//! one of its supertypes; `T(...)` and `T.init(...)` build a `T`; `f(...)` returns what `f` is
//! declared to return. Each later segment is typed through the view's property and return-type
//! tables. A binding with no type (a closure parameter) still hides an outer name, so the
//! receiver stays untyped rather than typed wrongly.
//!
//! The tables are global derived facts: one file's `let item: Car` types `h.item` in every other
//! file. `changed_names` says which names an edit retyped, so `with_changes` can re-resolve every
//! file whose receivers mention them (as the unique-name fallback already does for definitions).

use super::GraphData;
use crate::names::NamePool;
use crate::facts::{Binding, InternedFacts, HierarchyKind, SymbolKind, TypeSource};
use std::collections::{HashMap, HashSet};

/// The type of an expression built from a type the repository does not declare: no member of
/// the repository's is looked up on it.
pub(super) const OPAQUE: &str = "<external>";

/// How deep a binding's initialiser may lean on other bindings (`let b = a.x; let c = b.y`).
const MAX_DEPTH: u8 = 6;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SwiftTypes {
    /// (type, property) -> its type; `None` when two declarations disagree (same-named types in
    /// two modules), so the result never depends on which file was read first.
    props: HashMap<(String, String), Option<String>>,
    /// (type or "" for top level, function) -> return type; `None` when overloads disagree.
    rets: HashMap<(String, String), Option<String>>,
    /// type -> the types it inherits from or conforms to, sorted.
    supers: HashMap<String, Vec<String>>,
    /// class -> its superclass, for `super.m()`; `None` when two declarations disagree.
    superclass: HashMap<String, Option<String>>,
}

/// What an edit did to the tables: nothing, retyped these member and function names, or changed
/// a supertype (which can retype anything).
#[derive(Debug, PartialEq, Eq)]
pub(super) enum TypeChange {
    None,
    Names(HashSet<String>),
    All,
}

fn merge(map: &mut HashMap<(String, String), Option<String>>, key: (String, String), ty: Option<String>) {
    match map.get(&key) {
        None => {
            map.insert(key, ty);
        }
        Some(prev) if *prev != ty => {
            map.insert(key, None);
        }
        _ => {}
    }
}

fn is_container(k: SymbolKind) -> bool {
    matches!(k, SymbolKind::Class | SymbolKind::Struct | SymbolKind::Enum | SymbolKind::Trait | SymbolKind::Extension)
}

impl SwiftTypes {
    pub(super) fn build<'a>(files: impl Iterator<Item = &'a InternedFacts>) -> SwiftTypes {
        let mut t = SwiftTypes::default();
        for f in files {
            for m in &f.types.members {
                merge(&mut t.props, (m.owner.clone(), m.member.clone()), Some(m.ty.clone()));
            }
            for r in &f.types.returns {
                merge(&mut t.rets, (r.owner.clone(), r.name.clone()), r.ty.clone());
            }
            for h in &f.hierarchy {
                let owner = &f.symbols[h.symbol as usize].name;
                t.supers.entry(owner.clone()).or_default().push(h.target.clone());
                if h.kind == HierarchyKind::Extends && f.symbols[h.symbol as usize].kind == SymbolKind::Class {
                    match t.superclass.get(owner) {
                        None => {
                            t.superclass.insert(owner.clone(), Some(h.target.clone()));
                        }
                        Some(prev) if prev.as_deref() != Some(h.target.as_str()) => {
                            t.superclass.insert(owner.clone(), None);
                        }
                        _ => {}
                    }
                }
            }
        }
        for v in t.supers.values_mut() {
            v.sort();
            v.dedup();
        }
        t
    }

    /// `ty`, then its supertypes, nearest first.
    pub(super) fn lineage(&self, ty: &str) -> Vec<String> {
        let mut out: Vec<String> = vec![ty.to_string()];
        let mut i = 0;
        while i < out.len() {
            for s in self.supers.get(&out[i]).into_iter().flatten() {
                if !out.contains(s) {
                    out.push(s.clone());
                }
            }
            i += 1;
        }
        out
    }

    fn lookup(&self, map: &HashMap<(String, String), Option<String>>, ty: &str, name: &str) -> Option<String> {
        self.lineage(ty).into_iter().find_map(|t| map.get(&(t, name.to_string())).cloned())?
    }

    fn prop(&self, ty: &str, name: &str) -> Option<String> {
        self.lookup(&self.props, ty, name)
    }

    fn ret(&self, ty: &str, name: &str) -> Option<String> {
        self.lookup(&self.rets, ty, name)
    }

    pub(super) fn changed_names(old: &SwiftTypes, new: &SwiftTypes) -> TypeChange {
        if old == new {
            return TypeChange::None;
        }
        if old.supers != new.supers || old.superclass != new.superclass {
            return TypeChange::All;
        }
        let mut names = HashSet::new();
        for (a, b) in [(&old.props, &new.props), (&new.props, &old.props), (&old.rets, &new.rets), (&new.rets, &old.rets)] {
            for (k, v) in a {
                if b.get(k) != Some(v) {
                    names.insert(k.1.clone());
                }
            }
        }
        TypeChange::Names(names)
    }
}

impl SwiftTypes {
    /// Members and functions whose declared type is one of `types`: when a name starts or stops
    /// being a repository type, receivers typed through them type differently (an undeclared type
    /// is opaque), even in files that never spell the type's name.
    pub(super) fn typed_as<'a>(&'a self, types: &'a HashSet<String>) -> impl Iterator<Item = &'a String> + 'a {
        self.props
            .iter()
            .chain(&self.rets)
            .filter(move |(_, v)| v.as_ref().is_some_and(|t| types.contains(t.trim_start_matches('[').trim_end_matches(']'))))
            .map(|((_, m), _)| m)
    }
}

/// `(owner, member)` for every member a file declares: an edit that moves `drive` from one type
/// to another keeps the name, but retypes every `x.drive()`.
pub(super) fn member_pairs(f: &InternedFacts) -> HashSet<(String, String)> {
    f.symbols
        .iter()
        .filter_map(|s| s.parent.map(|p| (f.symbols[p as usize].name.clone(), s.name.clone())))
        .collect()
}

/// The identifiers a receiver text or initialiser mentions, for matching against `TypeChange`.
pub(super) fn tokens(s: &str) -> impl Iterator<Item = &str> {
    s.split(|c: char| !(c.is_alphanumeric() || c == '_')).filter(|t| !t.is_empty())
}

/// Does a file's resolution depend on any of `names` through its receivers?
pub(super) fn mentions(pool: &NamePool, f: &InternedFacts, names: &HashSet<String>) -> bool {
    let hit = |s: &str| tokens(s).any(|t| names.contains(t));
    f.refs.iter().any(|r| names.contains(pool.resolve(r.name)) || r.qualifier().map(|q| pool.resolve(q)).is_some_and(hit))
        || f.types.bindings.iter().any(|b| match &b.ty {
            Some(TypeSource::Expr(e) | TypeSource::Each(e)) => hit(e),
            Some(TypeSource::Named(t)) => hit(t),
            None => false,
        })
}

/// One segment of a receiver: `name`, `name(...)` (or a trailing closure), generic arguments and
/// `?`/`!` dropped.
#[derive(Debug, PartialEq)]
struct Seg<'a> {
    name: &'a str,
    call: bool,
}

/// Skip a balanced group opening at `s[i]`; returns the index after its close. Angle brackets
/// count only in a generic group (`{ $0 > 1 }` is a comparison); string literals are skipped whole.
fn skip_group(s: &[u8], mut i: usize) -> Option<usize> {
    let angle = s.get(i) == Some(&b'<');
    let (open, close): (&[u8], &[u8]) = if angle { (b"<", b">") } else { (b"([{", b")]}") };
    let mut depth = 0usize;
    while i < s.len() {
        match s[i] {
            c if open.contains(&c) => depth += 1,
            c if close.contains(&c) => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some(i + 1);
                }
            }
            b'"' => {
                i += 1;
                while i < s.len() && s[i] != b'"' {
                    i += if s[i] == b'\\' { 2 } else { 1 };
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// `a.b(x).c?.d` as segments; `None` for anything else (a subscript, an operator, a literal).
fn segments(q: &str) -> Option<Vec<Seg<'_>>> {
    let mut q = q.trim();
    for p in ["try? ", "try! ", "try ", "await "] {
        while let Some(rest) = q.strip_prefix(p) {
            q = rest.trim_start();
        }
    }
    let s = q.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    loop {
        while i < s.len() && s[i] == b' ' {
            i += 1;
        }
        let start = i;
        while i < s.len() && (s[i].is_ascii_alphanumeric() || s[i] == b'_') {
            i += 1;
        }
        if i == start {
            return None;
        }
        let name = &q[start..i];
        let mut call = false;
        loop {
            match s.get(i) {
                Some(b'?' | b'!' | b' ') => i += 1,
                // Generic arguments only right after a type name: `Box<Int>(...)`.
                Some(b'<') if name.starts_with(|c: char| c.is_uppercase()) && !call => i = skip_group(s, i)?,
                Some(b'(' | b'{') => {
                    call = true;
                    i = skip_group(s, i)?;
                }
                _ => break,
            }
        }
        out.push(Seg { name, call });
        match s.get(i) {
            None => return Some(out),
            Some(b'.') => i += 1,
            _ => return None,
        }
    }
}

impl GraphData {
    /// The type the file's declarations give the receiver text `q` at `line`, if any. An array
    /// type is untyped here: a member called on it is the library's.
    pub(super) fn swift_receiver_type(&self, f: u32, q: &str, line: u32, enclosing: Option<u32>) -> Option<String> {
        let ty = self.swift_eval(f, q, line, enclosing, &mut Vec::new())?;
        (!ty.starts_with('[')).then_some(ty)
    }

    /// The nearest type (or extension) around symbol `enclosing` in file `f`.
    fn swift_enclosing_type(&self, f: u32, mut cur: Option<u32>) -> Option<&str> {
        let node = &self.files[f as usize];
        while let Some(c) = cur {
            let s = node.symbol(c);
            if is_container(s.kind) {
                return Some(s.name.as_str());
            }
            cur = s.parent;
        }
        None
    }

    /// Evaluate receiver text; `active` holds the bindings being typed (no binding types itself).
    fn swift_eval(&self, f: u32, q: &str, line: u32, enclosing: Option<u32>, active: &mut Vec<usize>) -> Option<String> {
        if active.len() > MAX_DEPTH as usize {
            return None;
        }
        let segs = segments(q)?;
        let (root, rest) = segs.split_first()?;
        let types = &self.swift_types;
        let encl = self.swift_enclosing_type(f, enclosing);
        let mut ty = match root.name {
            "self" | "Self" if !root.call => encl?.to_string(),
            // The superclass, when the class names one; its members are looked up from there, so
            // a platform superclass (`NSTextView`) gives no target rather than the override.
            "super" if !root.call => types.superclass.get(encl?).cloned()??,
            n if n.starts_with(|c: char| c.is_uppercase()) => {
                // `T(...)` builds a `T`; a bare `T` is a namespace whose members follow.
                if !root.call && rest.is_empty() {
                    return None;
                }
                n.to_string()
            }
            n if root.call => encl.and_then(|e| types.ret(e, n)).or_else(|| types.ret("", n))?,
            n => match self.swift_binding(f, n, line, active) {
                Some(i) => {
                    let b: &Binding = &self.files[f as usize].facts.types.bindings[i];
                    active.push(i);
                    let t = match &b.ty {
                        None => None,
                        Some(TypeSource::Named(t)) => Some(t.clone()),
                        Some(TypeSource::Expr(e)) => self.swift_eval(f, e, b.decl_line, b.enclosing, active),
                        Some(TypeSource::Each(e)) => self
                            .swift_eval(f, e, b.decl_line, b.enclosing, active)
                            .and_then(|c| c.strip_prefix('[').and_then(|x| x.strip_suffix(']')).map(str::to_string)),
                    };
                    active.pop();
                    t?
                }
                None => types.prop(encl?, n)?,
            },
        };
        for s in rest {
            if ty.starts_with('[') {
                return None;
            }
            let next = match (s.call, s.name) {
                (true, "init") => Some(ty.clone()),
                (true, n) => types.ret(&ty, n),
                (false, n) => types.prop(&ty, n),
            };
            ty = match next {
                Some(t) => t,
                // A member of a type the repository does not declare (`Text(..).font(..)`) has a
                // type the repository does not declare either.
                None if !self.swift_is_repo_type(&ty) => return Some(OPAQUE.to_string()),
                None => return None,
            };
        }
        Some(ty)
    }

    /// Does a Swift file of the view declare a type (not an extension) named `ty`?
    fn swift_is_repo_type(&self, ty: &str) -> bool {
        self.named(ty).unwrap_or_default().iter().any(|id| {
            let f = &self.files[id.file as usize];
            f.language == "swift"
                && matches!(f.symbol(id.local).kind, SymbolKind::Class | SymbolKind::Struct | SymbolKind::Enum | SymbolKind::Trait | SymbolKind::TypeAlias)
        })
    }

    /// The innermost binding of `name` visible at `line`, skipping those being typed.
    fn swift_binding(&self, f: u32, name: &str, line: u32, active: &[usize]) -> Option<usize> {
        let bindings = &self.files[f as usize].facts.types.bindings;
        bindings
            .iter()
            .enumerate()
            .filter(|(i, b)| b.name == name && b.decl_line <= line && b.scope_start <= line && line <= b.scope_end && !active.contains(i))
            .min_by_key(|(i, b)| (b.scope_end - b.scope_start, u32::MAX - b.decl_line, usize::MAX - i))
            .map(|(i, _)| i)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn receiver_text_splits_into_named_segments() {
        let s = segments("g.car(x: (1, 2)).engine?.start { $0 > 1 }").unwrap();
        assert_eq!(
            s,
            [Seg { name: "g", call: false }, Seg { name: "car", call: true }, Seg { name: "engine", call: false }, Seg { name: "start", call: true }]
        );
        assert_eq!(segments("try await Box<Int>.init()").unwrap()[0], Seg { name: "Box", call: false });
        assert_eq!(segments("repos[at.repo]"), None, "a subscript has no declared type here");
        assert_eq!(segments("a + b"), None);
        assert_eq!(segments(".shared"), None);
    }
}
