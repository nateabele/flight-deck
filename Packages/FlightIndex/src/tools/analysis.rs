//! Tools that answer structural questions from the graph: `map`, `deps`, `stats`, `impact`,
//! `refs`, `calls`.

use super::args::SYMBOL;
use super::{is_test_path, range, Ctx, Format, ToolError, ToolResult};
use crate::facts::{RefKind, SymbolKind};
use crate::graph::{Confidence, SymId};
use crate::query::{CallEntry, Direction, SymbolHit};
use crate::links::Views;
use crate::resolve::Resolved;
use std::collections::{BTreeMap, HashSet};
use std::fmt::Write;
use std::path::{Path, PathBuf};

const MAP_DEFAULT_TOP: usize = 20;
const MAP_SIGNATURES_PER_FILE: usize = 6;
const MAX_CANDIDATES: usize = 10;
/// Rows of one list in `impact` and `refs`. The sections after a long list (co-change, hot
/// symbols) are worth more than its tail, so each list is capped before the token budget can cut
/// those sections off.
const LIST_CAP: usize = 30;
/// Rows of one view in a list that spans several: see `shown`.
const VIEW_CAP: usize = 40;

/// The rows of a list to print. A list from one view is cut at `cap`; a list that spans several
/// views is cut at `VIEW_CAP` rows *per view*, so a long list in one view cannot push another
/// view's rows (the cross-view ones the caller asked about) past the end of the token budget.
fn shown<T>(rows: &[T], view_of: impl Fn(&T) -> usize, cap: usize) -> Vec<&T> {
    let multi = rows.iter().map(&view_of).collect::<HashSet<_>>().len() > 1;
    if !multi {
        return rows.iter().take(cap).collect();
    }
    let mut per_view: BTreeMap<usize, usize> = BTreeMap::new();
    rows.iter()
        .filter(|r| {
            let n = per_view.entry(view_of(r)).or_default();
            *n += 1;
            *n <= VIEW_CAP.min(cap)
        })
        .collect()
}

/// Whether `h` can be called: what `calls` treats as a function-like definition.
fn function_like(k: SymbolKind) -> bool {
    matches!(k, SymbolKind::Function | SymbolKind::Method | SymbolKind::Const | SymbolKind::Constructor | SymbolKind::Macro | SymbolKind::Port)
}

/// Files that transitively import `path`, in its view and in the views linked to it.
fn blast(c: &Ctx, path: &Path) -> usize {
    c.graph.file_idx(path).map(|fi| c.views().blast_radius(0, fi).len()).unwrap_or(0)
}

pub fn map(c: &Ctx) -> ToolResult {
    let graph = c.graph;
    let top = match c.args.num(&["top_n"]) {
        Some(0) => usize::MAX,
        Some(n) => n,
        None => MAP_DEFAULT_TOP,
    };
    let all = c.args.flag(&["all_files"], false);
    let by_symbols = c.args.str(&["by"]).as_deref() == Some("symbols");
    let boost_files: Vec<PathBuf> = c.args.list(&["boost_files"]).iter().map(|f| super::args::resolve_path(&c.args.cwd, f)).collect();
    let boost_terms: Vec<String> = c.args.list(&["boost_terms"]).iter().map(|t| t.to_lowercase()).collect();
    let live = graph.stats().data;
    let name = graph.label.worktree.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let mut out = format!("Codebase: {name} ({} files, {} symbols indexed)\n", live.files, live.symbols);

    // A boost multiplies the PageRank of what the caller says it is working on, so the map leans
    // toward it without hiding the rest of the codebase.
    let weight = |fi: u32| -> f64 {
        let node = graph.file(fi);
        let mut w = 1.0;
        if boost_files.iter().any(|b| *b == graph.abs(fi)) {
            w *= 10.0;
        }
        if !boost_terms.is_empty() {
            let path = node.path.to_lowercase();
            if boost_terms.iter().any(|t| path.contains(t) || node.facts.symbols.iter().any(|s| s.name.to_lowercase().contains(t))) {
                w *= 5.0;
            }
        }
        w
    };

    if by_symbols {
        let mut rows: Vec<(f64, SymbolHit)> = Vec::new();
        for fi in (0..graph.files.len() as u32).filter(|i| graph.file(*i).alive) {
            if !all && is_test_path(&graph.file(fi).path) {
                continue;
            }
            for s in &graph.file(fi).facts.symbols {
                if matches!(s.kind, SymbolKind::Field | SymbolKind::Impl) || (!all && !s.exported) {
                    continue;
                }
                let h = graph.hit(SymId { file: fi, local: s.local_id });
                rows.push((h.rank * weight(fi), h));
            }
        }
        rows.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal).then(a.1.path.cmp(&b.1.path)).then(a.1.start_line.cmp(&b.1.start_line)));
        out.push_str("  # | Symbol | Kind | File | PageRank\n");
        for (i, (rank, h)) in rows.iter().take(top).enumerate() {
            let _ = writeln!(out, "{:>3} | {} | {} | {} {} | {:.4}", i + 1, h.name, h.kind.as_str(), h.path.display(), range(h), rank);
        }
        return Ok(c.fit(out));
    }

    let mut rows: Vec<(f64, u32)> = (0..graph.files.len() as u32)
        .filter(|i| graph.file(*i).alive)
        .filter(|i| all || (!is_test_path(&graph.file(*i).path) && !graph.file(*i).facts.symbols.is_empty()))
        .map(|i| (graph.file_rank[i as usize] * weight(i), i))
        .collect();
    rows.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal).then(graph.file(a.1).path.cmp(&graph.file(b.1).path)));
    out.push_str("  # | File | PageRank | Exports | Blast\n");
    let shown: Vec<&(f64, u32)> = rows.iter().take(top).collect();
    for (i, (rank, fi)) in shown.iter().enumerate() {
        let exports = graph.file(*fi).facts.symbols.iter().filter(|s| s.exported && !matches!(s.kind, SymbolKind::Field | SymbolKind::Impl)).count();
        let _ = writeln!(out, "{:>3} | {} | {:.4} | {:>3} | →{}", i + 1, graph.abs(*fi).display(), rank, exports, blast(c, &graph.abs(*fi)));
    }
    if c.format == Format::Detailed {
        for (_, fi) in &shown {
            let node = graph.file(*fi);
            let sigs: Vec<&crate::facts::Symbol> = node
                .facts
                .symbols
                .iter()
                .filter(|s| s.exported && s.parent.is_none() && !matches!(s.kind, SymbolKind::Field | SymbolKind::Impl))
                .collect();
            if sigs.is_empty() {
                continue;
            }
            let _ = writeln!(out, "\n{}", graph.abs(*fi).display());
            for s in sigs.iter().take(MAP_SIGNATURES_PER_FILE) {
                let sig = s.signature.as_deref().and_then(|x| x.lines().next()).unwrap_or(&s.name);
                let _ = writeln!(out, "  {sig}");
            }
            if sigs.len() > MAP_SIGNATURES_PER_FILE {
                let _ = writeln!(out, "  ⋯ {} more", sigs.len() - MAP_SIGNATURES_PER_FILE);
            }
        }
    }
    Ok(c.fit(out))
}

/// Imports of `fi` as `(target, specifier, external)`, deduplicated by target.
fn imports_of(c: &Ctx, fi: u32) -> Vec<(PathBuf, String, bool)> {
    let g = c.graph;
    let node = g.file(fi);
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for (imp, res) in node.facts.imports.iter().zip(&g.resolution(fi).imports) {
        let target = match res {
            Resolved::File { path, .. } => g.file_idx(Path::new(path)).map(|t| (g.abs(t), false)),
            Resolved::External(p) => Some((g.external_abs(p), true)),
            Resolved::Unresolved => None,
        };
        if let Some((p, ext)) = target
            && p != g.abs(fi)
            && seen.insert(p.clone())
        {
            out.push((p, imp.specifier.clone(), ext));
        }
    }
    out.sort();
    out
}

/// The specifier by which `importer` (view, file) imports `target`, in the same view or across
/// a link.
fn specifier_into(views: &Views, importer: (usize, u32), target: (usize, u32)) -> String {
    let g = views.graph(importer.0);
    g.file(importer.1)
        .facts
        .imports
        .iter()
        .zip(&g.resolution(importer.1).imports)
        .find(|(_, r)| match r {
            Resolved::File { path, .. } => importer.0 == target.0 && g.file_idx(Path::new(path)) == Some(target.1),
            Resolved::External(p) => views.locate(&g.external_abs(p)) == Some(target),
            Resolved::Unresolved => false,
        })
        .map(|(i, _)| i.specifier.clone())
        .unwrap_or_default()
}

pub fn deps(c: &Ctx) -> ToolResult {
    let (path, fi) = c.file()?;
    let views = c.views();
    let imports = imports_of(c, fi);
    // Importers in this view, then in the views linked to it: `formula-editor` files that
    // import an `tessera` file are listed, with the view they are in.
    let mut importers: Vec<(PathBuf, String, usize)> =
        views.importers(0, fi).into_iter().map(|(v, f)| (views.graph(v).abs(f), specifier_into(&views, (v, f), (0, fi)), v)).collect();
    importers.sort_by(|a, b| a.2.cmp(&b.2).then(a.0.cmp(&b.0)));
    importers.dedup();
    if c.format == Format::Mermaid {
        let mut ids: BTreeMap<PathBuf, usize> = BTreeMap::new();
        let mut id = |p: &Path| {
            let n = ids.len();
            *ids.entry(p.to_path_buf()).or_insert(n)
        };
        let mut edges = Vec::new();
        let me = id(&path);
        for (p, _, _) in &imports {
            edges.push((me, id(p)));
        }
        for (p, _, _) in &importers {
            edges.push((id(p), me));
        }
        let mut out = String::from("graph LR\n");
        for (p, n) in &ids {
            let _ = writeln!(out, "  n{n}[\"{}\"]", p.display());
        }
        for (a, b) in edges {
            let _ = writeln!(out, "  n{a} --> n{b}");
        }
        return Ok(c.fit(out));
    }
    let concise = c.format == Format::Concise;
    let mut out = format!("# Dependencies: {} (blast →{})\n", path.display(), blast(c, &path));
    let _ = writeln!(out, "Imports from ({}):", imports.len());
    for (p, spec, ext) in &imports {
        // A file outside this worktree is labelled with the linked view it is in, if one is.
        let tag = views.locate(p).and_then(|(v, _)| views.tag(v));
        let label = match (ext, &tag) {
            (_, Some(t)) => format!("view: {t}, "),
            (true, None) => "external, ".to_string(),
            (false, None) => String::new(),
        };
        let _ = if concise {
            writeln!(out, "-> {}{}", p.display(), tag.map(|t| format!("  [view: {t}]")).unwrap_or_default())
        } else {
            writeln!(out, "-> {} ({label}import: {spec})", p.display())
        };
    }
    let _ = writeln!(out, "Imported by ({}):", importers.len());
    let rows = shown(&importers, |r| r.2, usize::MAX);
    for (p, spec, v) in rows.iter().map(|r| &**r) {
        let tag = views.tag(*v);
        let _ = if concise {
            writeln!(out, "<- {}{}", p.display(), tag.map(|t| format!("  [view: {t}]")).unwrap_or_default())
        } else {
            writeln!(out, "<- {} ({}import: {spec})", p.display(), tag.map(|t| format!("view: {t}, ")).unwrap_or_default())
        };
    }
    if rows.len() < importers.len() {
        let _ = writeln!(out, "… {} more importer(s); `impact` lists them with their views", importers.len() - rows.len());
    }
    Ok(c.fit(out))
}

pub fn stats(c: &Ctx) -> ToolResult {
    let g = c.graph;
    if c.args.has(super::args::FILE) {
        let (path, fi) = c.file()?;
        let node = g.file(fi);
        let exported = node.facts.symbols.iter().filter(|s| s.exported).count();
        return Ok(format!(
            "{}\nLOC: {} | Symbols: {} ({exported} exported) | Imports: {} | Importers: {}\nLanguage: {} | PageRank: {:.4}",
            path.display(),
            node.facts.line_count,
            node.facts.symbols.len(),
            imports_of(c, fi).len(),
            g.importers[fi as usize].len(),
            node.language,
            g.file_rank[fi as usize]
        ));
    }
    let st = g.stats().data;
    let live: Vec<u32> = (0..g.files.len() as u32).filter(|i| g.file(*i).alive).collect();
    let tests = live.iter().filter(|i| is_test_path(&g.file(**i).path)).count();
    let edges: usize = live.iter().map(|i| g.resolution(*i).edges.len()).sum();
    let mut out = format!("files={} (src={}/test={tests}) loc={} syms={} edges={edges} (distinct directed file imports)\n", st.files, st.files as usize - tests, st.lines, st.symbols);
    out.push_str("languages:\n");
    for (lang, l) in &st.by_language {
        let _ = writeln!(out, "  {lang}: {} files, {} lines, {} symbols", l.files, l.lines, l.symbols);
    }
    let mut top: Vec<u32> = live.clone();
    top.sort_by(|a, b| g.importers[*b as usize].len().cmp(&g.importers[*a as usize].len()).then(g.file(*a).path.cmp(&g.file(*b).path)));
    out.push_str("most imported:\n");
    for fi in top.into_iter().take(5).filter(|i| !g.importers[*i as usize].is_empty()) {
        let _ = writeln!(out, "  {} ×{}", g.abs(fi).display(), g.importers[fi as usize].len());
    }
    Ok(out)
}

pub fn impact(c: &Ctx) -> ToolResult {
    let (path, fi) = c.file()?;
    let g = c.graph;
    let include_tests = c.args.flag(&["include_tests"], false);
    let views = c.views();
    let keep = |v: usize, p: &Path| include_tests || !is_test_path(&p.strip_prefix(&views.graph(v).root).unwrap_or(p).to_string_lossy());
    // Importers in this view and in the views linked to it, the latter labelled with their view.
    let at = |v: usize, p: &Path| format!("{}{}", p.display(), views.tag(v).map(|t| format!("  [view: {t}]")).unwrap_or_default());
    let mut direct: Vec<(usize, PathBuf)> = views.importers(0, fi).into_iter().map(|(v, f)| (v, views.graph(v).abs(f))).filter(|(v, p)| keep(*v, p)).collect();
    direct.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    let radius: Vec<_> = views.blast_radius(0, fi).into_iter().filter(|(v, e)| keep(*v, &e.path)).collect();

    let mut out = format!("Impact analysis: {}\n", path.display());
    let _ = writeln!(out, "Direct importers ({}):", direct.len());
    let rows = shown(&direct, |r| r.0, LIST_CAP);
    for (v, p) in rows.iter().map(|r| &**r) {
        let _ = writeln!(out, "  {}", at(*v, p));
    }
    if rows.len() < direct.len() {
        let _ = writeln!(out, "  … {} more", direct.len() - rows.len());
    }
    let _ = writeln!(out, "Transitive blast radius: {} file(s)", radius.len());
    let rows = shown(&radius, |r| r.0, LIST_CAP);
    for (v, e) in rows.iter().map(|r| &**r) {
        let _ = writeln!(out, "- {} (depth {})", at(*v, &e.path), e.depth);
    }
    if rows.len() < radius.len() {
        let _ = writeln!(out, "… {} more (`deps` and `refs transitive=true` list the chain)", radius.len() - rows.len());
    }

    match (c.cochange)() {
        Ok(co) => {
            let rel = &g.file(fi).path;
            let partners: Vec<(PathBuf, u32)> =
                co.partners_of(rel, 2).into_iter().filter(|(p, _)| g.file_idx(Path::new(p)).is_some()).map(|(p, n)| (g.root.join(p), n)).filter(|(p, _)| keep(0, p)).take(10).collect();
            let _ = writeln!(out, "Co-change partners ({}, from the last {} commits):", partners.len(), co.commits_scanned);
            for (p, n) in partners {
                let _ = writeln!(out, "  {} (changed together {n}×)", p.display());
            }
        }
        Err(e) => {
            let _ = writeln!(out, "Co-change partners: unavailable ({e})");
        }
    }

    let mut hot: Vec<SymbolHit> = g.file(fi).facts.symbols.iter().filter(|s| !matches!(s.kind, SymbolKind::Field | SymbolKind::Impl)).map(|s| g.hit(SymId { file: fi, local: s.local_id })).collect();
    hot.sort_by(|a, b| b.rank.partial_cmp(&a.rank).unwrap_or(std::cmp::Ordering::Equal).then(a.start_line.cmp(&b.start_line)));
    let _ = writeln!(out, "Hot symbols in this file ({}):", hot.len().min(5));
    for h in hot.iter().take(5) {
        let _ = writeln!(out, "  {} ({}) pr={:.4} {}", h.name, h.kind.as_str(), h.rank, range(h));
    }
    Ok(c.fit(out))
}

pub fn refs(c: &Ctx) -> ToolResult {
    let name = c.args.str(SYMBOL).ok_or_else(|| ToolError::bad("refs requires `symbol` (aliases: name, symbol_name)"))?;
    let views = c.views();
    let include_tests = c.args.flag(&["include_tests"], true);
    let transitive = c.args.flag(&["transitive"], false);
    let file = c.args.path(super::args::FILE);
    let defs = c.definitions(&name, c.kind()?, file.as_deref());
    if defs.is_empty() {
        return Ok(format!("No symbol found with name '{name}'\nTry `grep query={name}*` for prefix search, or pass regex=true for a pattern match."));
    }
    let mut out = String::new();
    if defs.len() > 1 {
        let _ = writeln!(out, "{} matches for name '{name}'; refs reports each candidate in order. Pass file_path or kind to narrow.", defs.len());
    }
    for d in defs.iter().take(MAX_CANDIDATES) {
        let _ = writeln!(out, "Symbol: {} ({})", d.name, d.kind.as_str());
        let _ = writeln!(out, "Defined in: {} {}{}", d.path.display(), range(d), tag_suffix(&views, d.view));
        // References in the defining view and, through the links, in the views that import it.
        let is_test = |v: usize, p: &Path| is_test_path(&p.strip_prefix(&views.graph(v).root).unwrap_or(p).to_string_lossy());
        let refs: Vec<(usize, crate::query::RefHit)> = views.references(d).into_iter().filter(|(v, r)| include_tests || !is_test(*v, &r.path)).collect();
        let mut by_file: BTreeMap<(usize, &Path), Vec<&crate::query::RefHit>> = BTreeMap::new();
        for (v, r) in &refs {
            by_file.entry((*v, r.path.as_path())).or_default().push(r);
        }
        if refs.is_empty() {
            let _ = writeln!(out, "No references found.");
        } else {
            let _ = writeln!(out, "References ({} in {} file(s)):", refs.len(), by_file.len());
        }
        let files: Vec<((usize, &Path), Vec<&crate::query::RefHit>)> = by_file.into_iter().collect();
        let listed = shown(&files, |f| (f.0).0, usize::MAX);
        let omitted = files.len() - listed.len();
        for ((v, p), rs) in listed.into_iter().map(|f| (&f.0, &f.1)) {
            let (v, p) = (*v, *p);
            let _ = writeln!(out, "{}{}", p.display(), tag_suffix(&views, v));
            for r in rs {
                let by_name = if r.confidence == Confidence::Fallback { " (matched by name)" } else { "" };
                let _ = writeln!(out, "  L{} {}{}{by_name}", r.line, ref_kind(r.kind), r.enclosing.as_ref().map(|e| format!(" in {e}")).unwrap_or_default());
            }
        }
        if omitted > 0 {
            let _ = writeln!(out, "… {omitted} more file(s) in the views above; narrow with file_path or include_tests=false");
        }
        if transitive {
            let radius: Vec<_> = views.blast_radius(d.view, d.id.file).into_iter().filter(|(v, e)| include_tests || !is_test(*v, &e.path)).collect();
            let _ = writeln!(out, "Transitive dependents ({} file(s)):", radius.len());
            for (v, e) in radius.iter().take(LIST_CAP) {
                let _ = writeln!(out, "  {}{} (depth {})", e.path.display(), tag_suffix(&views, *v), e.depth);
            }
        }
        out.push('\n');
    }
    Ok(c.fit(out))
}

/// `  [view: tessera @ /path]` for a row from a view other than the one the header names.
fn tag_suffix(views: &Views, view: usize) -> String {
    views.tag(view).map(|t| format!("  [view: {t}]")).unwrap_or_default()
}

fn ref_kind(k: RefKind) -> &'static str {
    match k {
        RefKind::Call => "call",
        RefKind::Type => "type",
        RefKind::Use => "use",
    }
}

pub fn calls(c: &Ctx) -> ToolResult {
    let name = c.args.str(SYMBOL).ok_or_else(|| ToolError::bad("calls requires `name` (aliases: symbol, symbol_name)"))?;
    let views = c.views();
    let direction = c.args.str(&["direction"]).unwrap_or_else(|| "both".into());
    let (want_callers, want_callees) = match direction.as_str() {
        "callers" => (true, false),
        "callees" => (false, true),
        "both" => (true, true),
        other => return Err(ToolError::bad(format!("unknown direction '{other}': use callers, callees or both"))),
    };
    let depth = c.args.num(&["depth"]).unwrap_or(1).min(10);
    let limit = c.args.num(&["limit"]).unwrap_or(50);
    let include_tests = c.args.flag(&["include_tests"], false);
    let file = c.args.path(super::args::FILE);
    let kind = c.kind()?;

    let candidates: Vec<SymbolHit> = c.definitions(&name, kind, file.as_deref()).into_iter().filter(|h| function_like(h.kind)).collect();
    let target = match candidates.as_slice() {
        [] => return Ok(format!("No function-like symbol found with name '{name}'")),
        [one] => one.clone(),
        many if file.is_none() && kind.is_none() => {
            let mut out = format!("'{name}' resolves to {} function-like candidate(s). Pass `file_path` or `kind` to pick one.\ncandidates:\n", many.len());
            for h in many.iter().take(MAX_CANDIDATES * 3) {
                let _ = writeln!(out, "- {} ({}) @ {}:L{}-{}{}", h.name, h.kind.as_str(), h.path.display(), h.start_line, h.end_line, tag_suffix(&views, h.view));
            }
            return Ok(out);
        }
        many => many[0].clone(),
    };

    let keep = |h: &SymbolHit| include_tests || !is_test_path(&h.path.strip_prefix(&views.graph(h.view).root).unwrap_or(&h.path).to_string_lossy());
    // Level by level, so each edge knows its parent: the flat `calls()` answer is enough for a
    // list but not for a tree or a diagram.
    let walk = |dir: Direction| -> Vec<(SymbolHit, CallEntry)> {
        let mut edges: Vec<(SymbolHit, CallEntry)> = Vec::new();
        let mut seen: HashSet<(usize, SymId)> = HashSet::from([(target.view, target.id)]);
        let mut frontier: Vec<SymbolHit> = vec![target.clone()];
        for d in 0..depth {
            let mut next = Vec::new();
            for from in &frontier {
                let step = if dir == Direction::In { views.callers(from) } else { views.callees(from) };
                for (hit, line, confidence) in step {
                    if keep(&hit) && seen.insert((hit.view, hit.id)) {
                        next.push(hit.clone());
                        edges.push((from.clone(), CallEntry { hit, depth: d as u32 + 1, line, confidence }));
                    }
                }
            }
            frontier = next;
        }
        edges
    };
    let callers = if want_callers { walk(Direction::In) } else { Vec::new() };
    let callees = if want_callees { walk(Direction::Out) } else { Vec::new() };

    if c.format == Format::Mermaid {
        let mut ids: BTreeMap<(usize, SymId), usize> = BTreeMap::new();
        let mut labels: Vec<(usize, String)> = Vec::new();
        let mut node = |h: &SymbolHit| {
            let n = ids.len();
            *ids.entry((h.view, h.id)).or_insert_with(|| {
                labels.push((n, format!("{} {}:L{}", h.name, h.path.display(), h.start_line)));
                n
            })
        };
        let mut lines = Vec::new();
        node(&target);
        for (from, e) in callers.iter().take(limit) {
            lines.push(format!("  n{} --> n{}", node(&e.hit), node(from)));
        }
        for (from, e) in callees.iter().take(limit) {
            lines.push(format!("  n{} --> n{}", node(from), node(&e.hit)));
        }
        let mut out = String::from("graph LR\n");
        for (n, l) in labels {
            let _ = writeln!(out, "  n{n}[\"{l}\"]");
        }
        for l in lines {
            let _ = writeln!(out, "{l}");
        }
        return Ok(c.fit(out));
    }

    let mut out = format!("Call hierarchy for {} ({}) @ {}:L{}-{}{}\n", target.name, target.kind.as_str(), target.path.display(), target.start_line, target.end_line, tag_suffix(&views, target.view));
    for (title, rows) in [("Callers", &callers), ("Callees", &callees)] {
        if (title == "Callers" && !want_callers) || (title == "Callees" && !want_callees) {
            continue;
        }
        let _ = writeln!(out, "{title} ({}):", rows.len().min(limit));
        for (from, e) in rows.iter().take(limit) {
            let by_name = if e.confidence == Confidence::Fallback { " (matched by name)" } else { "" };
            // `In`: the call is in the caller's file; `Out`: in the origin's file.
            let (at, at_view) = if title == "Callers" { (&e.hit.path, e.hit.view) } else { (&from.path, from.view) };
            let via = if e.depth > 1 { format!(" via {}", from.name) } else { String::new() };
            // A callee in another view than the call: say where it is defined.
            let defined = if title == "Callees" && e.hit.view != from.view { format!(" (defined in {}{})", e.hit.path.display(), tag_suffix(&views, e.hit.view)) } else { String::new() };
            let _ = writeln!(out, "{}[d{}] {} ({}) {}:L{}{via}{by_name}{defined}{}", "  ".repeat(e.depth as usize), e.depth, e.hit.name, e.hit.kind.as_str(), at.display(), e.line, tag_suffix(&views, at_view));
        }
        if rows.len() > limit {
            let _ = writeln!(out, "… {} more; pass limit={} to see all", rows.len() - limit, rows.len());
        }
    }
    Ok(c.fit(out))
}
