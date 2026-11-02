//! Rust references into crates: the per-file scope of crate names (the file's `use`s of
//! dependency paths, the extern prelude of `Cargo.lock` dependencies plus std/core/alloc, and
//! std's prelude), consulted exactly where the Elm package scope is (see `elm_pkg`): after the
//! file's own resolution found nothing or only a unique-name `Fallback`, before giving up.
//!
//! So a definition in the file, a `use crate::…` and a glob of a repository module still win;
//! a crate name beats a guess, as rustc's own lookup order has it (a name neither defined nor
//! imported in the file can only come from the prelude). The scope reads the file's imports as
//! the extractor wrote them; a `use` of a dependency path resolves to `Resolved::Unresolved` in
//! the import table, as before, and only this scope looks it up in the crate views.

use super::elm_pkg::ElmPkgScope;
use super::GraphData;
use crate::facts::{Import, ImportKind, RefKind};
use crate::pkgview::cargo::{RustDeps, Target};
use crate::pkgview::PkgSymbol;
use crate::resolve::Resolved;
use std::collections::HashMap;
use std::sync::Arc;

/// The package names one file can use, by language.
pub(super) enum PkgScope {
    Elm(ElmPkgScope),
    Rust(RustPkgScope),
}

impl PkgScope {
    pub(super) fn lookup(&self, name: &str, qualifier: Option<&str>, kind: RefKind) -> Option<Arc<PkgSymbol>> {
        match self {
            PkgScope::Elm(s) => s.lookup(name, qualifier, kind),
            PkgScope::Rust(s) => s.lookup(name, qualifier, kind),
        }
    }
}

pub(super) struct RustPkgScope {
    deps: Arc<RustDeps>,
    /// Names the file's `use`s bind to crate paths (`HashMap`, `json`, `io`).
    names: HashMap<String, Target>,
    /// `use dep::module::*`
    globs: Vec<Target>,
}

/// `Vec::<u8>` -> `Vec`
fn segments(path: &str) -> impl Iterator<Item = &str> {
    path.split("::").map(|s| s.trim().trim_start_matches("r#")).filter(|s| !s.is_empty() && !s.starts_with('<'))
}

impl RustPkgScope {
    pub(super) fn new(deps: Arc<RustDeps>, imports: &[Import], resolved: &[Resolved]) -> RustPkgScope {
        let mut s = RustPkgScope { deps, names: HashMap::new(), globs: Vec::new() };
        for (imp, r) in imports.iter().zip(resolved) {
            // A module declaration, or a path that reached a repository file.
            if imp.kind != ImportKind::Import || !matches!(r, Resolved::Unresolved) {
                continue;
            }
            let segs: Vec<&str> = segments(&imp.specifier).collect();
            let Some((first, rest)) = segs.split_first() else { continue };
            if matches!(*first, "crate" | "self" | "super") {
                continue;
            }
            let Some(mut base) = s.deps.krate(first).map(|k| k.root()) else { continue };
            let mut ok = true;
            for seg in rest {
                match base.child(seg) {
                    Some(t) => base = t,
                    None => {
                        ok = false;
                        break;
                    }
                }
            }
            if !ok {
                continue;
            }
            if imp.names.is_empty() {
                // `use std;` / `use serde_json;`
                s.names.insert(segs.last().unwrap_or(first).to_string(), base);
                continue;
            }
            for n in &imp.names {
                match n.name.as_str() {
                    "*" => s.globs.push(base.clone()),
                    "self" => {
                        let bound = n.alias.clone().unwrap_or_else(|| segs.last().unwrap_or(first).to_string());
                        s.names.insert(bound, base.clone());
                    }
                    name => {
                        if let Some(t) = base.child(name.trim_start_matches("r#")) {
                            s.names.insert(n.local().to_string(), t);
                        }
                    }
                }
            }
        }
        s
    }

    /// What the path a qualifier spells names: its first segment through the file's `use`s,
    /// the extern prelude, its globs, then std's prelude (`Vec::new`, `Option::Some`).
    fn qualifier_target(&self, q: &str) -> Option<Target> {
        let mut segs = segments(q);
        let first = segs.next()?;
        if matches!(first, "crate" | "self" | "super" | "Self") {
            return None;
        }
        let mut cur = self
            .names
            .get(first)
            .cloned()
            .or_else(|| self.deps.krate(first).map(|k| k.root()))
            .or_else(|| self.globs.iter().find_map(|g| g.child(first)))
            .or_else(|| self.deps.prelude(first))?;
        for seg in segs {
            cur = cur.child(seg)?;
        }
        Some(cur)
    }

    pub(super) fn lookup(&self, name: &str, qualifier: Option<&str>, kind: RefKind) -> Option<Arc<PkgSymbol>> {
        match qualifier {
            Some(q) => self.qualifier_target(q)?.child(name)?.pick(kind),
            None => {
                if let Some(t) = self.names.get(name) {
                    return t.pick(kind);
                }
                if let Some(hit) = self.globs.iter().find_map(|g| g.child(name)?.pick(kind)) {
                    return Some(hit);
                }
                self.deps.prelude(name)?.pick(kind)
            }
        }
    }
}

impl GraphData {
    /// Crate symbols `find`/`refs` can show for `query` (`HashMap::new`, `serde_json::json`,
    /// `Value`): a path through a dependency or std's prelude, and every crate symbol the view's
    /// Rust files reference whose path ends with the query.
    pub(super) fn find_rust_package_symbols(&self, query: &str) -> Vec<Arc<PkgSymbol>> {
        let mut out: Vec<Arc<PkgSymbol>> = Vec::new();
        let mut push = |s: &Arc<PkgSymbol>| {
            if !out.iter().any(|o| **o == **s) {
                out.push(s.clone());
            }
        };
        let segs: Vec<&str> = segments(query).collect();
        let Some((last, init)) = segs.split_last() else { return out };
        if !init.is_empty() {
            for deps in self.resolver.rust_packages_seen() {
                let scope = RustPkgScope { deps, names: HashMap::new(), globs: Vec::new() };
                if let Some(t) = scope.qualifier_target(&init.join("::")).and_then(|t| t.child(last)) {
                    t.items.iter().for_each(&mut push);
                }
            }
        }
        let suffix = format!("::{}", segs.join("::"));
        for (fi, r) in self.res.iter().enumerate() {
            if !self.files[fi].alive || self.files[fi].language != "rust" {
                continue;
            }
            for (_, s) in r.pkg_refs.iter() {
                if s.name == *last && format!("::{}::{}", s.module, s.name).ends_with(&suffix) {
                    push(s);
                }
            }
        }
        out
    }
}
