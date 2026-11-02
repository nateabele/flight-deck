//! The other side of a mutation applied across linked views: the edits a *dependent* view (one
//! whose manifest points into the view being changed, as `formula-editor`'s `elm.json` points
//! into `tessera/designer/src`) needs so that its uses follow a `rename`, `move`, `safe_delete`
//! or `rename_file` made in the view that defines the symbol or file.
//!
//! The target view plans its own change as it always has (`rename::rename`, `relocate::*`). A
//! dependent view's graph never holds the target's symbols, so its planner works from the sites
//! `links::Views` finds there instead of from `incoming`: the references that bind to the symbol
//! through an import that leaves the worktree (`Views::external_referrers`) and the import
//! statements that land on the target file (`Views::cross_imports`). From there each edit is the
//! same one the single-view planner makes, through the same helpers, so a name in a string or a
//! comment is still never touched and a stale file is still refused.

use super::relocate::{drop_from_imports, elm_module_at, import_line, is_ts, module_exposing_item, new_specifier, replace_literal, rewrite_elm_importer, rewrite_user, RelocCx};
use super::rename::{collisions, follow_reexports, refuse_collisions, rewrite_imports, rewrite_refs, warn_left_alone, RefSites};
use super::{Plan, Work};
use crate::facts::{ImportKind, SymbolKind};
use crate::graph::ViewGraph;
use crate::query::SymbolHit;
use crate::tools::ToolError;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::path::{Path, PathBuf};

/// What a dependent view holds that points at the symbol or file being changed.
pub struct Dependent<'a> {
    pub g: &'a ViewGraph,
    /// `(file, ref index)`: references of this view that bind to the symbol (or to what it
    /// contains: a type's constructors).
    pub refs: Vec<(u32, u32)>,
    /// `(file, import index)`: import statements of this view that land on the target file.
    pub imports: Vec<(u32, usize)>,
}

/// The change made in the target view, as much of it as a dependent view needs to follow.
pub enum Upstream {
    Rename { old: String, new: String, allow_collision: bool },
    Move { name: String, lang: &'static str, from: PathBuf, to: PathBuf, elm: Option<(String, String)>, elm_item: Option<String> },
    Delete { name: String },
    RenameFile { lang: &'static str, from: PathBuf, to: PathBuf, elm: Option<(String, String)> },
}

/// Describe `tool`'s change in the target view `g`. `h` is the symbol for the symbol mutators.
pub fn upstream(tool: &str, g: &ViewGraph, args: &crate::tools::args::Args, h: Option<&SymbolHit>) -> Result<Upstream, ToolError> {
    let lang_of = |fi: u32| crate::lang::by_id(g.file(fi).language).map(|l| l.id()).unwrap_or("rust");
    match (tool, h) {
        ("rename", Some(h)) => Ok(Upstream::Rename {
            old: h.name.clone(),
            new: args.str(&["new_name", "to_name"]).ok_or_else(|| ToolError::bad("new_name is required"))?,
            allow_collision: args.flag(&["allow_collision"], false),
        }),
        ("safe_delete", Some(h)) => Ok(Upstream::Delete { name: h.name.clone() }),
        ("move", Some(h)) => {
            let to = args.path(&["to_file", "to", "destination"]).ok_or_else(|| ToolError::bad("to_file is required"))?;
            let sf = h.id.file;
            let lang = lang_of(sf);
            let from = g.abs(sf);
            let (elm, elm_item) = if lang == "elm" {
                let old_module = g.file(sf).facts.module_name.clone().ok_or_else(|| ToolError::failed("the source file has no `module` declaration"))?;
                let new_module = match g.file_idx(&to) {
                    Some(ti) => g.file(ti).facts.module_name.clone().ok_or_else(|| ToolError::failed("the destination file has no `module` declaration"))?,
                    None => elm_module_at(&from, &old_module, &to)?,
                };
                let mut w = Work::new(g);
                let listed = module_exposing_item(w.doc(sf)?, &h.name);
                let item = listed.unwrap_or_else(|| if h.kind == SymbolKind::Enum { format!("{}(..)", h.name) } else { h.name.clone() });
                (Some((old_module, new_module)), Some(item))
            } else {
                (None, None)
            };
            Ok(Upstream::Move { name: h.name.clone(), lang, from, to, elm, elm_item })
        }
        ("rename_file", _) => {
            let from = args.path(&["from", "old_path", "file_path"]).ok_or_else(|| ToolError::bad("from is required"))?;
            let to = args.path(&["to", "new_path", "to_file"]).ok_or_else(|| ToolError::bad("to is required"))?;
            let fi = g.file_idx(&from).ok_or_else(|| ToolError::failed(format!("{} is not an indexed source file", from.display())))?;
            let lang = lang_of(fi);
            let elm = if lang == "elm" {
                let old_module = g.file(fi).facts.module_name.clone().ok_or_else(|| ToolError::failed(format!("{} has no `module` declaration", from.display())))?;
                let new_module = elm_module_at(&from, &old_module, &to)?;
                Some((old_module, new_module))
            } else {
                None
            };
            Ok(Upstream::RenameFile { lang, from, to, elm })
        }
        _ => Err(ToolError::bad(format!("{tool} is not applied across views"))),
    }
}

/// The edits `dep` needs to follow `up`.
pub fn plan(dep: &Dependent, up: &Upstream) -> Result<Plan, ToolError> {
    let tag = crate::tools::view_tag(&dep.g.label);
    match up {
        Upstream::Rename { old, new, allow_collision } => rename(dep, old, new, *allow_collision, &tag),
        Upstream::Move { name, lang, from, to, elm, elm_item } => move_users(dep, name, lang, from, to, elm.as_ref(), elm_item.as_deref(), &tag),
        Upstream::Delete { name } => delete(dep, name, &tag),
        Upstream::RenameFile { lang, from, to, elm } => rename_file(dep, lang, from, to, elm.as_ref(), &tag),
    }
}

fn imports_by_file(dep: &Dependent) -> BTreeMap<u32, Vec<usize>> {
    let mut out: BTreeMap<u32, Vec<usize>> = BTreeMap::new();
    for &(fi, ii) in &dep.imports {
        out.entry(fi).or_default().push(ii);
    }
    out
}

fn rename(dep: &Dependent, old: &str, new: &str, allow_collision: bool, tag: &str) -> Result<Plan, ToolError> {
    let g = dep.g;
    let mut sites: RefSites = BTreeMap::new();
    for &(fi, ri) in &dep.refs {
        let r = &g.file(fi).facts.refs[ri as usize];
        if g.name(r.name) == old {
            sites.entry(fi).or_default().entry(r.line).or_default().push(g.qualifier(r).map(String::from));
        }
    }
    let mut seed: BTreeMap<u32, BTreeSet<usize>> = BTreeMap::new();
    for &(fi, ii) in &dep.imports {
        if g.file(fi).facts.imports[ii].names.iter().any(|n| n.name == old) {
            seed.entry(fi).or_default().insert(ii);
        }
    }
    // A file that re-exports it (a TypeScript barrel) passes it on to the rest of this view.
    let providers: HashSet<u32> = seed.keys().copied().collect();
    let import_sites = follow_reexports(g, providers, seed, old);
    if !allow_collision {
        let touched: BTreeSet<u32> = sites.keys().chain(import_sites.keys()).copied().collect();
        refuse_collisions(collisions(g, &touched, None, old, new), old, new)?;
    }
    let mut w = Work::new(g);
    let refs = rewrite_refs(&mut w, &sites, old, new)?;
    let imports = rewrite_imports(&mut w, &import_sites, old, new)?;
    warn_left_alone(&mut w, old);
    w.notes.push(format!("in {tag}: {refs} reference, {imports} import site(s) rewritten"));
    w.finish(format!("rename {old} -> {new} in {tag}"))
}

#[allow(clippy::too_many_arguments)]
fn move_users(dep: &Dependent, name: &str, lang: &str, from: &Path, to: &Path, elm: Option<&(String, String)>, elm_item: Option<&str>, tag: &str) -> Result<Plan, ToolError> {
    let g = dep.g;
    if !(lang == "elm" || is_ts(lang)) {
        return Err(ToolError::failed(format!("a {lang} move cannot be followed into {tag}: its paths to the moved item cannot be rewritten across repositories. Nothing was changed.")));
    }
    let mut uses: BTreeMap<u32, Vec<(usize, bool)>> = BTreeMap::new();
    for &(fi, ri) in &dep.refs {
        let r = &g.file(fi).facts.refs[ri as usize];
        uses.entry(fi).or_default().push((ri as usize, r.qualifier().is_some()));
    }
    let imports = imports_by_file(dep);
    let files: BTreeSet<u32> = uses.keys().chain(imports.keys()).copied().collect();
    let cx = RelocCx { g, t_name: name, lang, sfile_rel: "", from_path: from, to, elm, elm_item, rust_to: None };
    let mut w = Work::new(g);
    let mut sites = 0usize;
    for gi in files {
        let node = g.file(gi);
        let u = uses.remove(&gi).unwrap_or_default();
        let imps: Vec<usize> = imports
            .get(&gi)
            .into_iter()
            .flatten()
            .copied()
            .filter(|&ii| {
                let imp = &node.facts.imports[ii];
                imp.names.iter().any(|n| n.name == name || n.name == "*") || imp.alias.is_some() || imp.kind == ImportKind::Import
            })
            .collect();
        if u.is_empty() && !imps.iter().any(|&ii| node.facts.imports[ii].names.iter().any(|n| n.name == name)) {
            continue;
        }
        let file_imports = node.facts.imports.clone();
        let d = w.doc(gi)?;
        let stmts = rewrite_user(d, &cx, gi, &u, &imps, false, &mut sites)?;
        let mut added: HashSet<String> = HashSet::new();
        for s in stmts {
            if added.insert(s.text.clone()) {
                let at = import_line(d, &file_imports, &s.text);
                d.insert_lines_before(at, &s.text);
            }
        }
    }
    w.notes.push(format!("in {tag}: {sites} importer site(s) rewritten"));
    w.finish(format!("move {name} to {} in {tag}", to.display()))
}

fn delete(dep: &Dependent, name: &str, tag: &str) -> Result<Plan, ToolError> {
    let g = dep.g;
    let mut w = Work::new(g);
    let mut sites = 0usize;
    for (gi, imps) in imports_by_file(dep) {
        let lang = g.file(gi).language;
        if !g.file(gi).facts.imports.iter().enumerate().any(|(ii, imp)| imps.contains(&ii) && imp.names.iter().any(|n| n.name == name)) {
            continue;
        }
        let d = w.doc(gi)?;
        drop_from_imports(d, g, gi, &imps, name, lang, &mut sites);
    }
    let live: BTreeSet<(u32, u32)> = dep.refs.iter().map(|&(fi, ri)| (fi, g.file(fi).facts.refs[ri as usize].line)).collect();
    if let Some(&(fi, line)) = live.iter().next() {
        w.warnings.push(format!("in {tag}: {} reference(s) remain and will no longer resolve (first: {}:L{line})", live.len(), g.abs(fi).display()));
    }
    w.notes.push(format!("in {tag}: {sites} import entry(ies) removed"));
    w.finish(format!("safe_delete {name}: imports of it in {tag}"))
}

fn rename_file(dep: &Dependent, lang: &str, from: &Path, to: &Path, elm: Option<&(String, String)>, tag: &str) -> Result<Plan, ToolError> {
    let g = dep.g;
    let mut w = Work::new(g);
    let mut sites = 0usize;
    for (gi, rewrites) in imports_by_file(dep) {
        let imports = g.file(gi).facts.imports.clone();
        match (lang, elm) {
            ("elm", Some((old_module, new_module))) => {
                let plain = rewrites.iter().any(|&ii| imports[ii].alias.is_none());
                let d = w.doc(gi)?;
                sites += rewrite_elm_importer(d, &imports, &rewrites, plain, old_module, new_module);
            }
            (l, _) if is_ts(l) => {
                let importer_dir = g.abs(gi).parent().unwrap_or(Path::new("/")).to_path_buf();
                for ii in rewrites {
                    let imp = &imports[ii];
                    let new_spec = new_specifier(&imp.specifier, &importer_dir, to);
                    if new_spec == imp.specifier {
                        continue;
                    }
                    let d = w.doc(gi)?;
                    let (a, b) = d.extent(imp.line as usize);
                    let (s, e) = d.lines_bytes(a, b);
                    if replace_literal(d, s, e, &imp.specifier, &new_spec) {
                        sites += 1;
                    } else {
                        w.warnings.push(format!("{}:L{}: could not find the specifier '{}' to rewrite", g.abs(gi).display(), imp.line, imp.specifier));
                    }
                }
            }
            _ => {
                return Err(ToolError::failed(format!(
                    "a {lang} rename_file cannot be followed into {tag}: its paths to {} cannot be rewritten across repositories. Nothing was changed.",
                    from.display()
                )))
            }
        }
    }
    w.notes.push(format!("in {tag}: {sites} importer site(s) rewritten"));
    w.finish(format!("rename_file {}: importers in {tag}", from.display()))
}
