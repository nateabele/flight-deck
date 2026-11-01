//! How Python imports bind names in the importing file.

use super::GraphData;
use crate::facts::Import;
use crate::resolve::Resolved;
use std::collections::HashMap;

impl GraphData {
    /// Record what `imp` (already resolved to `r`) makes visible: a module under its alias or dotted
    /// name, imported names as `locals`, and `from pkg import submodule` as a module of its own.
    /// `from pkg import name` cannot tell a submodule from an attribute without looking, so the
    /// submodule file is tried first, as the import system does.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn python_bindings(
        &self,
        from: &str,
        imp: &Import,
        r: &Resolved,
        edges: &mut Vec<u32>,
        qualifiers: &mut HashMap<String, Resolved>,
        locals: &mut HashMap<String, (Resolved, String)>,
        globs: &mut Vec<Resolved>,
    ) {
        if imp.names.is_empty() {
            // `import a.b.c` binds `a` but is used as `a.b.c.f()`, so the whole dotted name is
            // the qualifier; with `as`, the alias is.
            qualifiers.insert(imp.alias.clone().unwrap_or_else(|| imp.specifier.clone()), r.clone());
            return;
        }
        for n in &imp.names {
            if n.name == "*" {
                globs.push(r.clone());
                continue;
            }
            let sub = if imp.specifier.ends_with('.') { format!("{}{}", imp.specifier, n.name) } else { format!("{}.{}", imp.specifier, n.name) };
            let module = self.resolver.python_module(from, &sub);
            if let Some(t) = self.file_of(&module) {
                if !edges.contains(&t) {
                    edges.push(t);
                }
                qualifiers.insert(n.local().to_string(), module);
            } else {
                locals.insert(n.local().to_string(), (r.clone(), n.name.clone()));
            }
        }
    }
}
