//! Elm references into packages: the per-file scope of package names (implicit default imports
//! plus explicit imports of dependency modules), and the table that records which package
//! symbol each `Confidence::Package` reference names.
//!
//! The scope is consulted only after the file's own resolution found nothing or only a
//! unique-name `Fallback`: a local definition or an import of a repository module always wins,
//! and a package name always beats a guess. That ordering is what removed the 14,893 wrong
//! fallbacks measured on tessera (`String` bound to a constructor in Token.elm, `Result` to a
//! TypeScript type), and it is also why a package reference never needs re-resolving when some
//! other file's names change (see `GraphData::with_changes`).

use super::GraphData;
use crate::facts::RefKind;
use crate::pkgview::{Exposing, ModuleExports, PkgSymbol, ProjectPackages, ELM_DEFAULT_IMPORTS};
use crate::resolve::Resolved;
use std::collections::HashMap;
use std::sync::Arc;

/// Reference index -> package symbol, sorted by index. Two vectors, not one of pairs: a pair
/// pads to 16 bytes, these cost 12 a package reference.
/// Equal and hashed with the rest of a `FileRes`, so a shared block (see `blocks`) is only ever
/// shared between files that name the same package symbols.
#[derive(Debug, Clone, Default, PartialEq, Eq, Hash)]
pub struct PkgRefs {
    idx: Vec<u32>,
    sym: Vec<Arc<PkgSymbol>>,
}

impl PkgRefs {
    pub(super) fn push(&mut self, ref_idx: u32, sym: Arc<PkgSymbol>) {
        debug_assert!(self.idx.last().is_none_or(|l| *l < ref_idx));
        self.idx.push(ref_idx);
        self.sym.push(sym);
    }

    pub fn get(&self, ref_idx: u32) -> Option<&Arc<PkgSymbol>> {
        self.idx.binary_search(&ref_idx).ok().map(|i| &self.sym[i])
    }

    pub fn iter(&self) -> impl Iterator<Item = (u32, &Arc<PkgSymbol>)> {
        self.idx.iter().copied().zip(&self.sym)
    }

    pub fn len(&self) -> usize {
        self.idx.len()
    }

    pub fn is_empty(&self) -> bool {
        self.idx.is_empty()
    }

    pub(super) fn heap_bytes(&self) -> usize {
        self.idx.capacity() * 4 + self.sym.capacity() * std::mem::size_of::<Arc<PkgSymbol>>()
    }
}

/// The package names one Elm file can use.
#[derive(Default)]
pub(super) struct ElmPkgScope {
    /// Qualifier (`List`, `D`, `Cmd`) -> the package modules it names. Several: Elm allows
    /// `import Json.Decode as D` next to `import Json.Decode.Extra as D`.
    quals: HashMap<String, Vec<Arc<ModuleExports>>>,
    /// Unqualified names exposed one by one, explicit imports over the implicit ones.
    names: HashMap<String, Arc<ModuleExports>>,
    /// `exposing (..)`: explicit ones first, then the implicit `Basics`.
    globs: Vec<Arc<ModuleExports>>,
}

impl ElmPkgScope {
    /// The scope of a file whose imports resolved to `resolved` (`Resolved::Package` for a
    /// dependency module), in a project that depends on `pkgs`.
    pub(super) fn new(pkgs: &ProjectPackages, imports: &[crate::facts::Import], resolved: &[Resolved]) -> ElmPkgScope {
        let mut s = ElmPkgScope::default();
        let mut default_globs = Vec::new();
        for (module, alias, exposing) in ELM_DEFAULT_IMPORTS {
            // An import of a repository module with a default module's name shadows it (and a
            // project without elm/core gets nothing here at all).
            let shadowed = imports.iter().zip(resolved).any(|(i, r)| i.specifier == *module && !matches!(r, Resolved::Package(_)));
            let Some(m) = pkgs.modules.get(*module).filter(|_| !shadowed) else { continue };
            s.quals.entry(alias.unwrap_or(module).to_string()).or_default().push(m.clone());
            match exposing {
                Exposing::Nothing => {}
                Exposing::All => default_globs.push(m.clone()),
                Exposing::Names(names) => {
                    for (n, subs) in *names {
                        s.expose(m, n, *subs);
                    }
                }
            }
        }
        for (imp, r) in imports.iter().zip(resolved) {
            let Resolved::Package(m) = r else { continue };
            let q = s.quals.entry(imp.alias.clone().unwrap_or_else(|| imp.specifier.clone())).or_default();
            if !q.contains(m) {
                q.push(m.clone());
            }
            for n in &imp.names {
                if n.name == "*" {
                    s.globs.push(m.clone());
                } else {
                    s.expose(m, &n.name, n.subs);
                }
            }
        }
        s.globs.extend(default_globs);
        s
    }

    fn expose(&mut self, m: &Arc<ModuleExports>, name: &str, subs: bool) {
        self.names.insert(name.to_string(), m.clone());
        if subs {
            for c in m.ctors_of.get(name).into_iter().flatten() {
                self.names.insert(c.clone(), m.clone());
            }
        }
    }

    /// The package symbol a reference named `name` (under `qualifier`, of `kind`) means in this scope.
    pub(super) fn lookup(&self, name: &str, qualifier: Option<&str>, kind: RefKind) -> Option<Arc<PkgSymbol>> {
        let ty = kind == RefKind::Type;
        match qualifier {
            Some(q) => self.quals.get(q)?.iter().find_map(|m| m.lookup(name, ty)).cloned(),
            None => {
                if let Some(hit) = self.names.get(name).and_then(|m| m.lookup(name, ty)) {
                    return Some(hit.clone());
                }
                self.globs.iter().find_map(|m| m.lookup(name, ty)).cloned()
            }
        }
    }
}

impl GraphData {
    /// The package symbol reference `ref_idx` of `file` names, if it names one.
    pub fn package_target(&self, file: u32, ref_idx: u32) -> Option<&Arc<PkgSymbol>> {
        self.res.get(file as usize)?.pkg_refs.get(ref_idx)
    }

    /// (file, reference index) of every reference to the package symbol `sym` (any version).
    pub fn package_references(&self, module: &str, name: &str) -> Vec<(u32, u32, &Arc<PkgSymbol>)> {
        let mut out = Vec::new();
        for (fi, r) in self.res.iter().enumerate().filter(|(i, _)| self.files[*i].alive) {
            for (ri, s) in r.pkg_refs.iter() {
                if s.name == name && &*s.module == module {
                    out.push((fi as u32, ri, s));
                }
            }
        }
        out
    }

    /// The dependency sets of every Elm project in the view, each once.
    pub fn elm_projects(&self) -> Vec<Arc<ProjectPackages>> {
        let mut out: Vec<Arc<ProjectPackages>> = Vec::new();
        for f in self.files.iter().filter(|f| f.alive && f.language == "elm") {
            if let Some(p) = self.resolver.elm_packages(&f.path)
                && !out.iter().any(|o| Arc::ptr_eq(o, &p))
            {
                out.push(p);
            }
        }
        out
    }

    /// Package symbols named `name` (`map`) or `Module.name` (`List.map`, `Json.Decode.field`)
    /// in the dependencies of the view's Elm projects, the npm modules its TypeScript and JavaScript
    /// files import (`ecma_pkg`), the crate symbols of `find_rust_package_symbols` and the SDK
    /// symbols its Swift files can name (`UUID`, `FileManager.default`), deduplicated, sorted by
    /// display name.
    pub fn find_package_symbols(&self, query: &str) -> Vec<Arc<PkgSymbol>> {
        let (module, name) = match query.rfind('.') {
            // `List.::`-style operators are not looked up qualified; `(::)` would need parsing.
            Some(i) if i + 1 < query.len() => (Some(&query[..i]), &query[i + 1..]),
            _ => (None, query),
        };
        let mut out: Vec<Arc<PkgSymbol>> = Vec::new();
        for p in self.elm_projects() {
            for (mname, m) in &p.modules {
                if module.is_some_and(|q| q != mname) {
                    continue;
                }
                for s in [m.values.get(name), m.types.get(name)].into_iter().flatten() {
                    if !out.iter().any(|o| **o == **s) {
                        out.push(s.clone());
                    }
                }
            }
        }
        self.find_npm_symbols(query, &mut out);
        for s in self.find_rust_package_symbols(query).into_iter().chain(self.find_swift_package_symbols(query)) {
            if !out.iter().any(|o| **o == *s) {
                out.push(s);
            }
        }
        out.sort_by_key(|s| (s.display(), s.kind.as_str()));
        out
    }
}
