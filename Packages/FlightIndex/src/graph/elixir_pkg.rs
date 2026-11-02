//! Elixir references into packages (see `hexview`): the per-file scope of package names, and what
//! `use` brings into a file.
//!
//! - A remote call `Enum.map` (its qualifier already expanded through `alias` by the extractor)
//!   names a package module when no repository module has that name.
//! - A bare call resolves through, in order: the file's own definitions and imports of repository
//!   modules (the generic path), then package modules imported by name (`import Enum, only:
//!   [map: 2]`) or wholesale, then what each `use` imports, then the auto-imported `Kernel` and
//!   `Kernel.SpecialForms`. A package name beats a unique-name guess, as in Elm.
//! - `use M` imports what `M.__using__` imports. For a repository module those are the imports
//!   inside its `defmacro __using__` (or ExUnit's `using do … end`, which the extractor records as
//!   one), followed through nested `use`s, and a module that itself uses `ExUnit.CaseTemplate` also
//!   brings `use ExUnit.Case`. For a dependency they come from its sources the same way; for the
//!   standard library, from a measured table (`hexview::stdlib_using`). Repository modules a `use`
//!   imports become ordinary imports of the file (globs, or names), with a file edge, so `deps`,
//!   `impact` and incremental re-resolution see them.

use super::{Confidence, GraphData, RefRes, SymId};
use crate::facts::{RefKind, RefSite, SymbolKind};
use crate::hexview::{ExProject, UsingImport, AUTO_IMPORTS, CASE, CASE_TEMPLATE};
use crate::pkgview::{ModuleExports, PkgSymbol};
use crate::resolve::Resolved;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

/// How deep `use` is followed: `use App.Case` -> `use ExUnit.Case` -> its imports is two.
const USE_DEPTH: u32 = 4;

impl GraphData {
    /// Reads the standard library and the locked dependencies the view's Elixir files can call,
    /// while the other languages' packages load: the first Elixir file asks for them, and the
    /// answer is kept per Mix project.
    pub(super) fn preload_elixir_packages(&self) {
        if let Some(node) = self.files.iter().find(|n| n.alive && n.language == "elixir") {
            self.resolver.elixir_packages(&node.path);
        }
    }
}

/// The package names one Elixir file can use.
pub(super) struct ExPkgScope {
    project: Arc<ExProject>,
    /// Imported by name, in import order (a later import of the same name wins).
    names: HashMap<String, Arc<ModuleExports>>,
    /// Imported wholesale, explicit and `use`d ones first, then the auto-imports.
    globs: Vec<Arc<ModuleExports>>,
    /// Short name -> module, for each `alias` a `use` brings (`alias App.Isolate.Fake` inside a
    /// case template lets every test write `Fake.install()`). The file's own aliases never get
    /// here: the extractor has already expanded them.
    aliases: HashMap<String, String>,
}

impl ExPkgScope {
    /// `q` with its first segment expanded through a `use`d alias, when it has one.
    fn expand(&self, q: &str) -> Option<String> {
        let (head, rest) = match q.split_once('.') {
            Some((h, r)) => (h, Some(r)),
            None => (q, None),
        };
        let full = self.aliases.get(head)?;
        Some(match rest {
            Some(r) => format!("{full}.{r}"),
            None => full.clone(),
        })
    }
}

/// The repository bindings `use` adds, applied by `resolve_file` beside the file's own imports.
#[derive(Default)]
pub(super) struct UseBindings {
    pub globs: Vec<Resolved>,
    pub locals: Vec<(String, Resolved)>,
    pub files: Vec<u32>,
}

impl GraphData {
    /// Is `full` a module some Elixir file of the view defines (once or more)? A repository module
    /// shadows a package one of the same name, even when two files claim it.
    fn elixir_defines(&self, full: &str) -> bool {
        self.named(full).is_some_and(|ids| {
            ids.iter().any(|id| self.files[id.file as usize].language == "elixir" && matches!(self.symbol(*id).kind, SymbolKind::Module | SymbolKind::Trait))
        })
    }

    /// The one repository module called `full` (`None` when absent or ambiguous).
    fn elixir_repo_module(&self, full: &str) -> Option<SymId> {
        let named = self.named(full)?;
        let mut hits = named.iter().copied().filter(|id| {
            self.files[id.file as usize].language == "elixir" && matches!(self.symbol(*id).kind, SymbolKind::Module | SymbolKind::Trait)
        });
        let first = hits.next()?;
        hits.next().is_none().then_some(first)
    }

    /// The package scope of Elixir file `f`, and the repository imports its `use`s bring.
    pub(super) fn elixir_scope(&self, f: u32) -> Option<(ExPkgScope, UseBindings)> {
        let node = &self.files[f as usize];
        let project = self.resolver.elixir_packages(&node.path)?;
        let mut s = ExPkgScope { project, names: HashMap::new(), globs: Vec::new(), aliases: HashMap::new() };
        let mut b = UseBindings::default();
        let mut seen: HashSet<(String, bool)> = HashSet::new();
        for imp in &node.facts.imports {
            self.elixir_bind(&mut s, &mut b, &mut seen, &UsingImport::from_import(imp), 0);
        }
        for m in AUTO_IMPORTS {
            if let Some(m) = s.project.modules.get(*m)
                && !s.globs.contains(m)
            {
                s.globs.push(m.clone());
            }
        }
        Some((s, b))
    }

    fn elixir_bind(&self, s: &mut ExPkgScope, b: &mut UseBindings, seen: &mut HashSet<(String, bool)>, u: &UsingImport, depth: u32) {
        if let Some(short) = &u.alias {
            if depth > 0 {
                s.aliases.entry(short.clone()).or_insert_with(|| u.module.clone());
            }
            return;
        }
        if !seen.insert((u.module.clone(), u.is_use)) {
            // Imported twice (`import M` and a `use` that imports it): the first `only` stands.
            return;
        }
        let repo = self.elixir_repo_module(&u.module);
        if !u.is_use {
            if let Some(id) = repo {
                // The file's own `import` of a repository module is already bound by
                // `elixir_bindings`; one a `use` brings is bound here.
                if depth > 0 {
                    let r = Resolved::File { path: self.files[id.file as usize].path.clone(), rest: vec![] };
                    match &u.only {
                        None => b.globs.push(r),
                        Some(names) => b.locals.extend(names.iter().map(|n| (n.clone(), r.clone()))),
                    }
                    b.files.push(id.file);
                }
            } else if !self.elixir_defines(&u.module)
                && let Some(m) = s.project.modules.get(&u.module).cloned()
            {
                match &u.only {
                    None => {
                        if !s.globs.contains(&m) {
                            s.globs.push(m);
                        }
                    }
                    Some(names) => {
                        for n in names {
                            s.names.insert(n.clone(), m.clone());
                        }
                    }
                }
            }
            return;
        }
        if depth >= USE_DEPTH {
            return;
        }
        match repo {
            Some(id) => {
                let file = &self.files[id.file as usize];
                if depth > 0 {
                    b.files.push(id.file);
                }
                let syms = &file.facts.symbols;
                let module = &syms[id.local as usize];
                let using = syms.iter().find(|x| x.name == "__using__" && x.parent == Some(id.local) && x.kind == SymbolKind::Macro);
                let mut nested: Vec<UsingImport> = Vec::new();
                for imp in &file.facts.imports {
                    let in_using = using.is_some_and(|x| imp.line >= x.start_line && imp.line <= x.end_line);
                    let in_module = imp.line >= module.start_line && imp.line <= module.end_line;
                    if in_using {
                        nested.push(UsingImport::from_import(imp));
                    } else if in_module && imp.specifier == CASE_TEMPLATE && imp.names.is_empty() && imp.alias.is_none() {
                        nested.push(UsingImport { module: CASE.to_string(), only: None, is_use: true, alias: None });
                    }
                }
                for n in nested {
                    self.elixir_bind(s, b, seen, &n, depth + 1);
                }
            }
            None if !self.elixir_defines(&u.module) => {
                let nested = s.project.using.get(&u.module).cloned();
                for n in nested.iter().flat_map(|n| n.iter()) {
                    self.elixir_bind(s, b, seen, n, depth + 1);
                }
            }
            None => {}
        }
    }

    /// A reference whose module is written through an alias some `use` brought: resolved as if
    /// written in full. `None` for every other reference (the generic path takes it).
    pub(super) fn elixir_aliased_ref(&self, s: &ExPkgScope, r: &RefSite) -> Option<RefRes> {
        if s.aliases.is_empty() {
            return None;
        }
        let name = self.name(r.name);
        let exact = |id: SymId| RefRes { target: Some(id), confidence: Confidence::Exact, external: None };
        let none = RefRes { target: None, confidence: Confidence::Exact, external: None };
        let module = name.starts_with(|c: char| c.is_uppercase());
        let q = match (self.qualifier(r), module) {
            (Some(q), _) => s.expand(q)?,
            (None, true) => {
                let full = s.expand(name)?;
                return Some(self.elixir_repo_module(&full).map(exact).unwrap_or(none));
            }
            (None, false) => return None,
        };
        if module {
            return Some(self.elixir_repo_module(&format!("{q}.{name}")).map(exact).unwrap_or(none));
        }
        Some(self.elixir_repo_module(&q).and_then(|id| self.member_of(id.file, &q, name)).map(exact).unwrap_or(none))
    }

    /// The package symbol an Elixir reference names in scope `s`, if it names one.
    pub(super) fn elixir_package_ref(&self, s: &ExPkgScope, r: &RefSite) -> Option<Arc<PkgSymbol>> {
        let name = self.name(r.name);
        let expanded = self.qualifier(r).map(|q| s.expand(q).unwrap_or_else(|| q.to_string()));
        let qualifier = expanded.as_deref();
        let module_sym = |full: &str, last: &str| -> Option<Arc<PkgSymbol>> {
            if self.elixir_defines(full) {
                return None;
            }
            s.project.modules.get(full)?.types.get(last).cloned()
        };
        if name.starts_with(|c: char| c.is_uppercase()) {
            // A module mention: `%MapSet{}`, `raise ArgumentError`, `Phoenix.Socket`.
            return match qualifier {
                Some(q) => module_sym(&format!("{q}.{name}"), name),
                None => match s.expand(name) {
                    Some(full) => module_sym(&full, name),
                    None => module_sym(name, name),
                },
            };
        }
        // A type position (`@spec`, `@type`) names types and a call names functions and macros,
        // never the other: `integer()` in a spec is the built-in type even where StreamData's
        // `integer/0` generator is imported.
        let ty = r.kind == RefKind::Type;
        let pick = |m: &Arc<ModuleExports>| -> Option<Arc<PkgSymbol>> { if ty { m.types.get(name) } else { m.values.get(name) }.cloned() };
        match qualifier {
            Some(q) => {
                if self.elixir_defines(q) {
                    return None;
                }
                pick(s.project.modules.get(q)?)
            }
            None => {
                if let Some(hit) = s.names.get(name).and_then(pick) {
                    return Some(hit);
                }
                s.globs.iter().find_map(pick)
            }
        }
    }

    /// The Elixir projects of the view's Elixir files, each once.
    pub fn elixir_projects(&self) -> Vec<Arc<ExProject>> {
        let mut out: Vec<Arc<ExProject>> = Vec::new();
        for f in self.files.iter().filter(|f| f.alive && f.language == "elixir") {
            if let Some(p) = self.resolver.elixir_packages(&f.path)
                && !out.iter().any(|o| Arc::ptr_eq(o, &p))
            {
                out.push(p);
            }
        }
        out
    }

    /// Elixir package symbols named `name` (`map`), `Module.name` (`Enum.map`) or a module's full
    /// name (`Phoenix.Socket`), deduplicated, sorted by display name.
    pub fn find_elixir_package_symbols(&self, query: &str) -> Vec<Arc<PkgSymbol>> {
        let mut out: Vec<Arc<PkgSymbol>> = Vec::new();
        let mut push = |s: &Arc<PkgSymbol>| {
            if !out.iter().any(|o| **o == **s) {
                out.push(s.clone());
            }
        };
        let (module, name) = match query.rfind('.') {
            Some(i) if i + 1 < query.len() => (Some(&query[..i]), &query[i + 1..]),
            _ => (None, query),
        };
        for p in self.elixir_projects() {
            if let Some(m) = p.modules.get(query) {
                let last = query.rsplit('.').next().unwrap_or(query);
                if let Some(s) = m.types.get(last) {
                    push(s);
                }
            }
            match module {
                Some(q) => {
                    if let Some(m) = p.modules.get(q) {
                        for s in [m.values.get(name), m.types.get(name).filter(|s| s.kind != crate::pkgview::PkgKind::Module)].into_iter().flatten() {
                            push(s);
                        }
                    }
                }
                // An unqualified name is looked up in the auto-imported modules only: `count` in
                // every module that defines one would bury the one people mean.
                None => {
                    for m in AUTO_IMPORTS.iter().filter_map(|m| p.modules.get(*m)) {
                        if let Some(s) = m.values.get(name) {
                            push(s);
                        }
                    }
                }
            }
        }
        out.sort_by_key(|s| (s.display(), s.kind.as_str()));
        out
    }
}
