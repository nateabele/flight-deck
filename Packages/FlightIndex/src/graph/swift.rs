//! Swift name resolution. There are no file imports, so a reference is looked up by name among
//! the files of its own module and of the modules it imports; the result is both the link to the
//! definition and the file dependency (see `resolve_file`).

use super::{Confidence, RefRes, SymId, GraphData};
use crate::facts::{Reference, SymbolKind};
use crate::resolve::swift_module_key;

fn is_type_kind(k: SymbolKind) -> bool {
    matches!(k, SymbolKind::Class | SymbolKind::Struct | SymbolKind::Enum | SymbolKind::Trait | SymbolKind::TypeAlias)
}

fn is_container_kind(k: SymbolKind) -> bool {
    is_type_kind(k) || k == SymbolKind::Extension
}

/// `Foo`, `Foo.Bar`: a dotted chain of identifiers ending in a capitalised one, i.e. a type used
/// as a namespace rather than an expression whose type we cannot know.
fn is_type_qualifier(q: &str) -> bool {
    let last = q.rsplit('.').next().unwrap_or(q);
    q.split('.').all(|s| !s.is_empty() && s.chars().all(|c| c.is_alphanumeric() || c == '_')) && last.starts_with(|c: char| c.is_uppercase())
}

/// Member names the standard library and Foundation define on nearly every receiver. When a
/// repository also defines exactly one member of such a name, `x.contains(..)` is still almost
/// certainly the library's, so a unique-name guess would be wrong more often than right.
const LIBRARY_MEMBERS: &[&str] = &[
    "decode", "encode", "contains", "map", "compactMap", "flatMap", "filter", "forEach", "reduce", "sorted", "sort",
    "first", "last", "append", "insert", "remove", "removeAll", "merge", "withLock", "joined", "split", "reversed",
    "min", "max", "count", "isEmpty", "prefix", "suffix", "dropFirst", "dropLast", "firstIndex", "lastIndex",
    "enumerated", "hasPrefix", "hasSuffix", "write", "read", "close", "reset", "cancel", "send", "next", "value",
    "keys", "values", "items", "add", "get", "set", "update", "run", "start", "stop",
];

impl GraphData {
    /// Module keys visible from file `f`, its own first: the files of those directories are what
    /// an unqualified name can mean.
    pub(super) fn swift_keys(&self, f: u32) -> Vec<String> {
        let node = &self.files[f as usize];
        let mut keys = vec![swift_module_key(&node.path)];
        for imp in &node.facts.imports {
            let module = imp.specifier.split('.').next().unwrap_or("");
            for k in self.resolver.swift_modules_named(module) {
                if !keys.contains(k) {
                    keys.push(k.clone());
                }
            }
        }
        keys
    }

    pub(super) fn swift_ref(&self, f: u32, r: &Reference, keys: &[String]) -> RefRes {
        let exact = |id: SymId| RefRes { target: Some(id), confidence: Confidence::Exact, external: None };
        let guess = |id: SymId| RefRes { target: Some(id), confidence: Confidence::Fallback, external: None };
        let none = RefRes { target: None, confidence: Confidence::Exact, external: None };

        // Definitions of this name in visible modules, with how near their module is (0 = own).
        let cands: Vec<(SymId, usize)> = self
            .named(&r.name)
            .into_iter()
            .flatten()
            .filter(|id| self.files[id.file as usize].language == "swift")
            .filter_map(|id| {
                let key = swift_module_key(&self.files[id.file as usize].path);
                keys.iter().position(|k| *k == key).map(|rank| (*id, rank))
            })
            .collect();
        let sym = |id: SymId| self.symbol(id);
        let parent_name = |id: SymId| sym(id).parent.map(|p| self.files[id.file as usize].symbol(p).name.as_str());
        // The nearest module wins (a module's own `Store` shadows an imported one), then the same
        // file, then a stable order so full and incremental builds agree on overloads.
        let best = |pool: Vec<(SymId, usize)>| -> Option<(SymId, bool)> {
            let nearest = pool.iter().map(|(_, rank)| *rank).min()?;
            let mut group: Vec<SymId> = pool.into_iter().filter(|(_, rank)| *rank == nearest).map(|(id, _)| id).collect();
            group.sort_by_key(|id| (id.file != f, id.file, id.local));
            let first = group[0];
            // Several files each defining it (not overloads in one file) make the pick a guess.
            let ambiguous = group.iter().any(|id| id.file != first.file);
            Some((first, ambiguous))
        };
        let enclosing_chain: Vec<&str> = {
            let node = &self.files[f as usize];
            let mut chain = Vec::new();
            let mut cur = r.enclosing;
            while let Some(c) = cur {
                let s = node.symbol(c);
                if is_container_kind(s.kind) {
                    chain.push(s.name.as_str());
                }
                cur = s.parent;
            }
            chain
        };
        let members_of_chain = || -> Vec<(SymId, usize)> {
            cands.iter().copied().filter(|(id, _)| parent_name(*id).is_some_and(|p| enclosing_chain.contains(&p)) && sym(*id).kind != SymbolKind::Extension).collect()
        };
        // Last resorts shared by every branch: a unique member name in scope, then a unique name
        // anywhere in the view. Both are guesses and say so.
        let unique_member = || -> Option<RefRes> {
            if LIBRARY_MEMBERS.contains(&r.name.as_str()) && r.qualifier.is_some() {
                return None;
            }
            let members: Vec<_> = cands.iter().copied().filter(|(id, _)| sym(*id).parent.is_some() && sym(*id).kind != SymbolKind::Extension).collect();
            (members.len() == 1).then(|| guess(members[0].0))
        };
        // A name nothing in scope defines. Only test targets may look view-wide: an Xcode test
        // bundle compiles other targets' sources straight in (`CLIRunner` with no `import`), but
        // anywhere else a view-wide match is a platform name colliding with an unrelated type
        // (`Task`, `Error`) and would draw an edge from a library into the app. Only top-level
        // definitions qualify: a nested one is nameable only through its parent.
        let global = |_qualified: bool| -> RefRes {
            let key = &keys[0];
            if !(key.starts_with("Tests") || key.contains("/Tests/") || key.starts_with("UITests")) {
                return none.clone();
            }
            let pool: Vec<SymId> = self
                .named(&r.name)
                .into_iter()
                .flatten()
                .copied()
                .filter(|id| id.file != f && self.files[id.file as usize].language == "swift" && sym(*id).kind != SymbolKind::Extension && sym(*id).parent.is_none())
                .collect();
            if pool.len() == 1 { guess(pool[0]) } else { none.clone() }
        };

        match r.qualifier.as_deref() {
            None if r.name.starts_with(|c: char| c.is_uppercase()) => {
                // A nested type (`Store.Kind`) is nameable bare only from inside its parent, so
                // an `Error` or `Entry` nested somewhere else is not what a bare `Error` means.
                let types: Vec<_> = cands
                    .iter()
                    .copied()
                    .filter(|(id, _)| is_type_kind(sym(*id).kind))
                    .filter(|(id, _)| parent_name(*id).is_none_or(|p| enclosing_chain.contains(&p)))
                    .collect();
                match best(types) {
                    Some((id, ambiguous)) => {
                        let top_level = sym(id).parent.is_none();
                        if ambiguous || !(top_level || id.file == f) { guess(id) } else { exact(id) }
                    }
                    None => global(false),
                }
            }
            None => {
                if let Some((id, _)) = best(members_of_chain()) {
                    return exact(id);
                }
                let top: Vec<_> = cands.iter().copied().filter(|(id, _)| sym(*id).parent.is_none() && sym(*id).kind != SymbolKind::Extension).collect();
                if let Some((id, ambiguous)) = best(top) {
                    return if ambiguous { guess(id) } else { exact(id) };
                }
                unique_member().unwrap_or_else(|| global(false))
            }
            Some("self" | "Self") => match best(members_of_chain()) {
                Some((id, _)) => exact(id),
                None => unique_member().unwrap_or_else(|| global(true)),
            },
            Some(q) if is_type_qualifier(q) => {
                let container = q.rsplit('.').next().unwrap_or(q);
                let members: Vec<_> = cands.iter().copied().filter(|(id, _)| parent_name(*id) == Some(container)).collect();
                match best(members) {
                    Some((id, ambiguous)) => if ambiguous { guess(id) } else { exact(id) },
                    // A type the module does not define (`Date.now`, `FileManager.default`) is the
                    // platform's, and must not be matched to an unrelated member of the same name.
                    None => none,
                }
            }
            // A receiver expression: its type is unknown to a syntax-only index.
            Some(_) => {
                unique_member().unwrap_or_else(|| global(true))
            }
        }
    }
}
