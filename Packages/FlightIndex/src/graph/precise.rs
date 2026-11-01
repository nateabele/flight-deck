//! The index-store layer over the heuristic resolution (see `crate::indexstore`).

use super::{Confidence, FileRes, GraphData, RefRes, SymId, ViewGraph};
use crate::indexstore::PreciseIndex;
use std::sync::Arc;

impl GraphData {
    /// The symbol of file `file` the compiler means by a definition of `name` on `line`: the
    /// innermost one of that name whose span holds the line (an attribute line above the name
    /// starts the span, so the name's line is inside it, not at its start).
    fn symbol_at(&self, file: u32, name: &str, line: u32) -> Option<SymId> {
        let f = &self.files[file as usize];
        f.names
            .get(name)?
            .iter()
            .map(|l| (l, f.symbol(*l)))
            .filter(|(_, s)| s.start_line <= line && line <= s.end_line)
            .min_by_key(|(_, s)| s.end_line - s.start_line)
            .map(|(l, _)| SymId { file, local: *l })
    }
}

impl ViewGraph {
    /// This graph with every reference the index store resolves replaced by the compiler's
    /// answer (`Confidence::Precise`), including "nothing in this repository". A reference the store does not cover, or whose declaration
    /// fdindex cannot place, keeps its heuristic answer. Only meaningful for the worktree the store
    /// was built from: `p` holds only files unchanged since that build.
    pub fn with_precise(&self, p: &PreciseIndex) -> ViewGraph {
        if p.is_empty() {
            return self.clone();
        }
        let mut g: GraphData = (*self.data).clone();
        let names = g.names.clone();
        let mut touched = false;
        for fi in 0..g.files.len() as u32 {
            let node = &g.files[fi as usize];
            if !node.alive || node.language != "swift" || !p.files.contains_key(&node.path) {
                continue;
            }
            let mut res: FileRes = (*g.res[fi as usize]).clone();
            let mut changed = false;
            for (ri, r) in node.facts.refs.iter().enumerate() {
                let Some(sites) = p.lookup(&node.path, r.line, names.resolve(r.name)) else { continue };
                if sites.is_empty() {
                    res.refs[ri] = RefRes { target: None, confidence: Confidence::Precise, external: None };
                    changed = true;
                    continue;
                }
                let mut targets = sites.iter().filter_map(|s| g.index.get(&*s.path).and_then(|&t| g.symbol_at(t, names.resolve(r.name), s.line)));
                let Some(first) = targets.next() else { continue };
                // Two calls on one line to different declarations: the line cannot say which is which.
                if targets.any(|t| t != first) {
                    continue;
                }
                res.refs[ri] = RefRes { target: Some(first), confidence: Confidence::Precise, external: None };
                changed = true;
            }
            if changed {
                res.edges = g.swift_edges(fi, &res.refs);
                g.res[fi as usize] = g.intern(res);
                touched = true;
            }
        }
        if !touched {
            return self.clone();
        }
        g.finalize(Some(&self.data));
        ViewGraph { label: self.label.clone(), root: self.root.clone(), data: Arc::new(g) }
    }
}
