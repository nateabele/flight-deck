//! Mutators and linked views: who else a rename, move, safe_delete or rename_file would break, and,
//! when the agent names those views in `views`, the edits that make them follow.
//!
//! A mutator writes into the view that answers its lookup. If views whose manifests link into it
//! (*dependent* views: the caller's checkout, and views seen before that are indexed) use the
//! symbol or import the file, the change is refused unless every such view is named in `views`;
//! then it is planned in each named view too and written together. The rules:
//!
//! - **Only named views are written.** A dependent view with sites that the agent did not name
//!   still refuses the whole change (listing its sites); a named view that does not link into the
//!   target is refused, so a typo cannot redirect a write.
//! - **Gates in a fixed order.** The target's and every named view's write gate are taken before
//!   the first look at any of them, sorted by worktree path. Two cross-view mutators therefore
//!   always queue in the same order, and queries (which take a linked view's gate only with
//!   `read_unless_blocked`) never hold one gate while blocking on another.
//! - **All files or none.** Every view's changes go to `edit::apply_change_sets` as one set: each
//!   file is checked against its own worktree and recorded bytes first, and a failed write puts
//!   back the files already written in every view.
//! - **Re-indexed before the answer.** Each written view's graph is rebuilt from disk before the
//!   answer, so the next query from either checkout sees the change.

use super::{read_unless_blocked, PlannedMember, Readiness, Service, MAX_BUILD_WAIT};
use crate::git::{self, View};
use crate::proto::state;
use crate::tools::mutate::{self, external, MutCtx, Plan};
use crate::tools::{self, args::Args, ToolError};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

/// The mutators whose change another view can depend on.
pub(super) fn crosses(tool: &str) -> bool {
    matches!(tool, "rename" | "move" | "safe_delete" | "rename_file")
}

/// A dependent view's share of a cross-view change.
pub(super) struct Side {
    pub(super) root: PathBuf,
    pub(super) plan: Plan,
}

impl Service {
    /// The worktrees a mutator may write, sorted (the order their write gates are taken in): the
    /// target's and each one `views` names.
    pub(super) fn writable_roots(&self, tool: &str, args: &Args, target: &Path) -> std::result::Result<Vec<PathBuf>, ToolError> {
        let named = args.list(&["views", "view"]);
        if !named.is_empty() && !crosses(tool) {
            return Err(ToolError::bad(format!("views applies to rename, move, safe_delete and rename_file; {tool} changes no name or path another view uses")));
        }
        let mut roots = vec![target.to_path_buf()];
        for p in named {
            let abs = tools::args::resolve_path(&args.cwd, &p);
            let loc = git::locate(&abs).map_err(|e| ToolError::bad(format!("views: {}: {e}", abs.display())))?;
            roots.push(loc.root);
        }
        roots.sort();
        roots.dedup();
        Ok(roots)
    }

    /// Check the views that depend on what `plan` changes in `view`. A view that uses it and is not
    /// in `writable` refuses the change; each one that is gets its share planned here. `writable`
    /// holds write gates the caller has taken, so they are not read-locked again.
    pub(super) fn cross_view(self: &Arc<Self>, tool: &str, args: &Args, view: &View, plan: &mut Plan, cwd: &str, writable: &[PathBuf]) -> std::result::Result<Vec<Side>, ToolError> {
        if !crosses(tool) {
            return Ok(Vec::new());
        }
        let target = view.label.worktree.clone();
        let named: Vec<PathBuf> = writable.iter().filter(|r| **r != target).cloned().collect();
        // A named view counts as a dependent once its links are recorded, and must be complete:
        // a rename that misses a site because the view was half built leaves it broken.
        for root in &named {
            let v = self.view(root)?;
            self.links.of(&v);
            self.touch(&v);
            if let Readiness::Building { done, total } = self.ensure_built(&v, &[], false, Some(MAX_BUILD_WAIT))? {
                return Err(ToolError {
                    state: state::BUILDING,
                    message: format!("{tool} needs the complete index of {}, which is still building (index: building, {done} of {total} files); nothing was changed, retry shortly", root.display()),
                });
            }
        }
        let planned: Vec<PlannedMember> = self.plan_members(view, cwd, true);
        let strays: Vec<String> = named.iter().filter(|r| !planned.iter().any(|p| p.root == **r)).map(|r| r.display().to_string()).collect();
        if !strays.is_empty() {
            return Err(ToolError::failed(format!(
                "refusing: views names {}, which does not link into {} (no manifest there points into it), so {tool} has nothing to follow there; nothing was changed",
                strays.join(", "),
                target.display()
            )));
        }
        if planned.is_empty() {
            return Ok(Vec::new());
        }
        let member_gates: Vec<Arc<RwLock<()>>> = planned.iter().filter(|p| !named.contains(&p.root)).map(|p| self.gate(&p.root)).collect();
        let _reading: Vec<_> = member_gates.iter().filter_map(|g| read_unless_blocked(g)).collect();
        let roots: Vec<PathBuf> = planned.iter().map(|p| p.root.clone()).collect();
        let begun = self.begin_members(planned, cwd);
        let members = self.finish_members(begun, MAX_BUILD_WAIT);
        let unchecked: Vec<String> = roots.iter().filter(|r| !members.iter().any(|m| m.graph.label.worktree == **r)).map(|r| r.display().to_string()).collect();
        let graph = self.engine.graph(view)?;
        let views = crate::links::Views::new(&graph, &members);
        let ctx = MutCtx { graph: &graph, args };

        // What the change touches in the target: a symbol (with what it contains, for a type's
        // constructors) or a file.
        let (file, hit) = match mutate::symbol_keys(tool) {
            Some(keys) => {
                let h = mutate::select(&ctx, keys)?;
                (h.id.file, Some(h))
            }
            None => match args.path(&["from", "old_path", "file_path"]).and_then(|p| graph.file_idx(&p)) {
                Some(f) => (f, None),
                None => return Ok(Vec::new()),
            },
        };
        let mut symbols = Vec::new();
        if let Some(h) = &hit {
            symbols.push(h.clone());
            if tool != "rename" {
                let f = graph.file(file);
                for s in f.facts.symbols.iter().filter(|s| s.local_id != h.id.local && graph.within(file, s.local_id, h.id.local)) {
                    symbols.push(graph.hit(crate::graph::SymId { file, local: s.local_id }));
                }
            }
        }
        let mut refs: Vec<(usize, u32, u32)> = symbols.iter().flat_map(|s| views.external_referrers(s)).collect();
        refs.sort();
        refs.dedup();
        let imports = views.cross_imports(0, file);
        let name = hit.as_ref().map(|h| h.name.clone());
        let names_it = |v: usize, fi: u32, ii: usize| {
            let imp = &views.graph(v).file(fi).facts.imports[ii];
            name.as_deref().is_none_or(|n| imp.names.iter().any(|x| x.name == n || x.name == "*"))
        };

        // Sites per view, for the refusal and the safe_delete count.
        let mut sites: std::collections::BTreeMap<usize, Vec<(PathBuf, u32)>> = Default::default();
        for &(v, fi, ri) in &refs {
            let g = views.graph(v);
            sites.entry(v).or_default().push((g.abs(fi), g.file(fi).facts.refs[ri as usize].line));
        }
        for &(v, fi, ii) in imports.iter().filter(|&&(v, fi, ii)| names_it(v, fi, ii)) {
            let g = views.graph(v);
            sites.entry(v).or_default().push((g.abs(fi), g.file(fi).facts.imports[ii].line));
        }
        for rows in sites.values_mut() {
            rows.sort();
            rows.dedup();
        }
        if sites.is_empty() {
            if !unchecked.is_empty() {
                plan.warnings.push(format!("views that link into this one were not indexed, so their uses were not checked: {}", unchecked.join(", ")));
            }
            for root in &named {
                plan.notes.push(format!("no change needed in {}: it does not use what changes", root.display()));
            }
            return Ok(Vec::new());
        }

        let root_of = |v: usize| views.graph(v).label.worktree.clone();
        let unnamed: Vec<usize> = sites.keys().copied().filter(|v| !named.contains(&root_of(*v))).collect();
        if !unnamed.is_empty() {
            let mut m = format!("refusing: {} would break views that use it; nothing was changed.\n", plan.summary);
            m.push_str(&format!("in this view ({}), it would change {} file(s):\n", tools::view_tag(&graph.label), plan.changes.len()));
            for c in &plan.changes {
                m.push_str(&format!("  {}\n", c.path.display()));
            }
            for (v, rows) in &sites {
                m.push_str(&format!("in {} it is used at {} site(s) that would no longer resolve:\n", views.tag(*v).unwrap_or_default(), rows.len()));
                for (p, l) in rows {
                    m.push_str(&format!("  {}:{l}\n", p.display()));
                }
            }
            let all: Vec<String> = sites.keys().map(|v| format!("\"{}\"", root_of(*v).display())).collect();
            m.push_str(&format!(
                "A {tool} writes only into the views you name. To apply it in all of them at once (all files or none), pass views=[{}]; or make the change in each view, dependent one(s) first, or drop it.",
                all.join(", ")
            ));
            return Err(ToolError::failed(m));
        }
        if tool == "safe_delete" && !args.flag(&["force"], false) {
            let n: usize = sites.values().map(Vec::len).sum();
            let mut m = format!("refusing: {} has {n} live reference(s) in other views; nothing was changed. Pass force=true to delete it anyway (their imports of it are removed; the uses are yours to fix).\n", name.unwrap_or_default());
            for (v, rows) in &sites {
                for (p, l) in rows.iter().take(30) {
                    m.push_str(&format!("  {}:{l} [view: {}]\n", p.display(), views.tag(*v).unwrap_or_default()));
                }
            }
            return Err(ToolError::failed(m.trim_end().to_string()));
        }

        let up = external::upstream(tool, &graph, args, hit.as_ref())?;
        let mut sides = Vec::new();
        for v in sites.keys().copied() {
            let dep = external::Dependent {
                g: views.graph(v),
                refs: refs.iter().filter(|r| r.0 == v).map(|r| (r.1, r.2)).collect(),
                imports: imports.iter().filter(|i| i.0 == v).map(|i| (i.1, i.2)).collect(),
            };
            let side = external::plan(&dep, &up)?;
            if side.changes.is_empty() {
                plan.notes.push(format!("no change needed in {}", views.tag(v).unwrap_or_default()));
                plan.warnings.extend(side.warnings);
                continue;
            }
            sides.push(Side { root: root_of(v), plan: side });
        }
        for root in named.iter().filter(|r| !sites.keys().any(|v| root_of(*v) == **r)) {
            plan.notes.push(format!("no change needed in {}: it does not use what changes", root.display()));
        }
        Ok(sides)
    }
}
