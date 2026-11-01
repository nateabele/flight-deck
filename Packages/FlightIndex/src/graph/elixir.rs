//! Elixir module resolution. Modules do not map to paths (one file may define several, and
//! `Shop.Order` need not live in `shop/order.ex`), so a module name is looked up among the module
//! symbols of the view instead of through the resolver.

use super::{RefRes, SymId, ViewGraph};
use crate::facts::{Import, Reference, SymbolKind};
use crate::resolve::Resolved;
use std::collections::HashMap;

impl ViewGraph {
    /// The one module symbol called `full`; `None` when no Elixir file in the view defines it
    /// (a package such as `Logger`) or when two files claim it and picking one would be a guess.
    fn elixir_module(&self, full: &str) -> Option<SymId> {
        let mut hits = self.name_index.get(full)?.iter().copied().filter(|id| {
            self.files[id.file as usize].language == "elixir" && matches!(self.symbol(*id).kind, SymbolKind::Module | SymbolKind::Trait)
        });
        let first = hits.next()?;
        hits.next().is_none().then_some(first)
    }

    pub(super) fn elixir_import(&self, module: &str) -> Resolved {
        match self.elixir_module(module) {
            Some(id) => Resolved::File { path: self.files[id.file as usize].path.clone(), rest: vec![] },
            None => Resolved::Unresolved,
        }
    }

    /// Imports bind by full module name: the extractor already expanded every qualifier through
    /// `alias`, so a remote call arrives as `Foo.Bar` whatever it was written as.
    pub(super) fn elixir_bindings(
        &self,
        imp: &Import,
        r: &Resolved,
        qualifiers: &mut HashMap<String, Resolved>,
        locals: &mut HashMap<String, (Resolved, String)>,
        globs: &mut Vec<Resolved>,
    ) {
        qualifiers.insert(imp.specifier.clone(), r.clone());
        for n in &imp.names {
            if n.name == "*" {
                globs.push(r.clone());
            } else {
                locals.insert(n.local().to_string(), (r.clone(), n.name.clone()));
            }
        }
    }

    /// Module mentions (`%Foo.Bar{}`, a bare `Foo.Bar`) and remote calls (`Foo.Bar.baz()`).
    /// `None` leaves local calls to the generic path. A qualifier that names no module in the view
    /// is a package, and must not fall back to "the only function called `info`": that would bind
    /// `Logger.info` to an unrelated repository function.
    pub(super) fn elixir_ref(&self, r: &Reference, qualifiers: &HashMap<String, Resolved>) -> Option<RefRes> {
        let exact = |id: SymId| RefRes { target: Some(id), confidence: super::Confidence::Exact, external: None };
        let none = RefRes { target: None, confidence: super::Confidence::Exact, external: None };
        if r.name.starts_with(|c: char| c.is_uppercase()) {
            let full = match &r.qualifier {
                Some(q) => format!("{q}.{}", r.name),
                None => r.name.clone(),
            };
            return Some(self.elixir_module(&full).map(exact).unwrap_or(none));
        }
        let q = r.qualifier.as_deref()?;
        let file = qualifiers
            .get(q)
            .and_then(|res| self.file_of(res))
            .or_else(|| self.elixir_module(q).map(|id| id.file));
        Some(file.and_then(|t| self.member_of(t, q, &r.name)).map(exact).unwrap_or(none))
    }
}
