//! Tools that answer structural questions from the graph: `map`, `deps`, `stats`, `impact`,
//! `refs`, `calls`.

use super::caps::{by_proximity, counts, symbol_id, Fit, LIST_LIMIT};
use super::{impact, impact_index, is_test_path, range, Ctx, Format, ToolError, ToolResult};
use crate::facts::{RefKind, SymbolKind};
use crate::graph::{Confidence, SymId};
use crate::query::{CallEntry, Direction, SymbolHit};
use crate::links::Views;
use crate::near::Near;
use crate::resolve::Resolved;
use std::collections::{BTreeMap, HashSet};
use std::fmt::Write;
use std::path::{Path, PathBuf};

const MAP_DEFAULT_TOP: usize = 20;
const MAP_SIGNATURES_PER_FILE: usize = 6;
const MAX_CANDIDATES: usize = 10;
/// Rows of one list in `impact` and `refs`. The sections after a long list (the tests group, hot
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
pub(super) fn function_like(k: SymbolKind) -> bool {
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
    let personalize = c.args.flag(&["personalize"], true);
    let live = graph.stats().data;
    let name = graph.label.worktree.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let mut out = format!("Codebase: {name} ({} files, {} symbols indexed)\n", live.files, live.symbols);

    // The files the caller is working on seed a personalized PageRank (`graph/ppr.rs`): the ones
    // it names, or else the worktree's modified files, which the service passes as `diff_files`.
    // On the eval's seeded tasks this took the top ten from 0.3% to 32% of gold files (tessera)
    // and from 2.7% to 57% (flight-deck). Not for `by=symbols`: ranked that way
    // the walk found 1-3% of gold functions, worse than the symbol PageRank it would replace.
    let seed_paths: Vec<PathBuf> = if !personalize || by_symbols {
        Vec::new()
    } else if !boost_files.is_empty() {
        boost_files.clone()
    } else {
        c.args.list(&["diff_files"]).iter().map(|f| super::args::resolve_path(&c.args.cwd, f)).collect()
    };
    let seeds: Vec<u32> = seed_paths.iter().filter_map(|p| graph.file_idx(p)).filter(|f| graph.file(*f).alive).collect::<std::collections::BTreeSet<u32>>().into_iter().collect();
    let personalized = (!seeds.is_empty()).then(|| {
        let weights: Vec<(u32, f64)> = seeds.iter().map(|f| (*f, 1.0)).collect();
        graph.personalized_file_rank(&weights, crate::graph::ppr::DEFAULT_REVERSE)
    });

    // A boost multiplies the PageRank of what the caller says it is working on, so the map leans
    // toward it without hiding the rest of the codebase. A seeded map has already ranked by the
    // boosted files; terms still multiply, after the walk: fed into the restart vector they
    // dilute the seed (measured 2-3 pp worse).
    let weight = |fi: u32| -> f64 {
        let node = graph.file(fi);
        let mut w = 1.0;
        if personalized.is_none() && boost_files.iter().any(|b| *b == graph.abs(fi)) {
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

    // A seeded map lists the seeds once, apart, and ranks the rest: the caller already knows its
    // own files. It shows test files too, because a change's other files are tests 35-46% of the
    // time (the eval's gold sets); an unseeded map keeps hiding them, as it always has.
    let ranks = personalized.as_ref().unwrap_or(&graph.file_rank);
    let all = all || personalized.is_some();
    if personalized.is_some() {
        let names: Vec<String> = seeds.iter().map(|f| graph.abs(*f).display().to_string()).collect();
        let _ = writeln!(out, "Seeds: {}", names.join(", "));
    }
    let mut rows: Vec<(f64, u32)> = (0..graph.files.len() as u32)
        .filter(|i| graph.file(*i).alive)
        .filter(|i| all || (!is_test_path(&graph.file(*i).path) && !graph.file(*i).facts.symbols.is_empty()))
        .filter(|i| personalized.is_none() || seeds.binary_search(i).is_err())
        .map(|i| (ranks[i as usize] * weight(i), i))
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
            Resolved::Package(_) | Resolved::Unresolved => None,
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
            Resolved::Package(_) | Resolved::Unresolved => false,
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
    // How much of this view's code crosses each link: a link whose imports do not resolve shows
    // 0 here, which is the difference between "linked" and "followed".
    let views = c.views();
    if views.len() > 1 {
        out.push_str("links (file imports, references that cross):\n");
        for v in 1..views.len() {
            let (imports, refs) = views.crossing(v);
            let dir = if c.members[v - 1].role == crate::links::Role::Linked { "into it" } else { "from it" };
            let _ = writeln!(out, "  {} via {}: {imports} import(s), {refs} reference(s) {dir}", views.tag(v).unwrap_or_default(), c.members[v - 1].via.join(", "));
        }
    }
    Ok(out)
}

pub fn impact(c: &Ctx) -> ToolResult {
    if c.args.flag(&["pending"], false) {
        return super::pending::pending(c);
    }
    let (path, fi) = c.file()?;
    let g = c.graph;
    let include_tests = c.args.flag(&["include_tests"], false);
    let views = c.views();
    let is_test = |v: usize, p: &Path| is_test_path(&p.strip_prefix(&views.graph(v).root).unwrap_or(p).to_string_lossy());
    let keep = |v: usize, p: &Path| include_tests || !is_test(v, p);
    // Importers in this view and in the views linked to it, the latter labelled with their view.
    let at = |v: usize, p: &Path| format!("{}{}", p.display(), views.tag(v).map(|t| format!("  [view: {t}]")).unwrap_or_default());
    // Both lists are ranked before the 30-row cap: nearest directory to the file first, then
    // PageRank, then depth. The old order (direct importers by path, the radius by PageRank)
    // kept 66.5% / 65.3% of later co-edited files inside the caps (tessera / flight-deck
    // history); this order keeps 75.1% / 77.5%. A `near` seed set reorders on top (stable).
    let mut direct: Vec<(usize, PathBuf, f64)> =
        views.importers(0, fi).into_iter().map(|(v, f)| (v, views.graph(v).abs(f), views.graph(v).file_rank[f as usize])).filter(|(v, p, _)| keep(*v, p)).collect();
    direct.sort_by(|a, b| by_proximity(&path, (&a.1, 1, a.2), (&b.1, 1, b.2)).then(a.0.cmp(&b.0)));
    let all_radius = views.blast_radius(0, fi);
    let mut radius: Vec<_> = all_radius.iter().filter(|(v, e)| keep(*v, &e.path)).cloned().collect();
    radius.sort_by(|a, b| by_proximity(&path, (&a.1.path, a.1.depth, a.1.rank), (&b.1.path, b.1.depth, b.1.rank)).then(a.0.cmp(&b.0)));
    let narrow = if include_tests { "include_tests=false, or " } else { "" };
    let near = Near::of(c);
    let local = |v: usize, p: &Path| if v == 0 { g.file_idx(p) } else { None };
    if let Some(n) = &near {
        n.sort_by_file(&mut direct, |r| local(r.0, &r.1));
        n.sort_by_file(&mut radius, |r| local(r.0, &r.1.path));
    }

    // Seeds: the file asked about, then what the worktree has changed (`seed_diff=false` drops
    // those). Co-change is seeded by all of them; importers by the file asked about.
    let rel = g.file(fi).path.clone();
    let mut seeds: Vec<&str> = vec![rel.as_str()];
    if c.args.flag(&["seed_diff"], true) {
        seeds.extend(c.diff.iter().map(String::as_str).filter(|d| *d != rel));
    }
    let seed_paths: HashSet<PathBuf> = seeds.iter().map(|s| g.root.join(s)).collect();
    let mut reasons: impact::Reasons<(usize, PathBuf)> = impact::Reasons::default();
    let cochanged = |p: &impact::Partner| impact::Why::CoChanged { together: p.together, of: p.of, with: (p.seed != rel).then(|| p.seed.clone()) };
    // List A: every transitive importer, nearest first, then by PageRank (`blast_radius` order).
    let mut by_depth: Vec<&(usize, crate::query::RadiusEntry)> = all_radius.iter().collect();
    by_depth.sort_by_key(|(_, e)| e.depth);
    let mut importers: Vec<(usize, PathBuf)> = Vec::new();
    for (v, e) in &by_depth {
        let k = (*v, e.path.clone());
        reasons.add(&k, impact::Why::Importer { depth: e.depth });
        if keep(*v, &e.path) && !seed_paths.contains(&e.path) {
            importers.push(k);
        }
    }
    // List B: co-change partners by confidence, among the files this view has.
    // Each seed's partners among the view's files are read once per graph and HEAD (`impact_index`).
    let co = (c.cochange)();
    let index = g.impact_index();
    let partners: Vec<impact::Partner> = match &co {
        Ok(co) => impact_index::ranked_partners(index, co, &seeds, |p| impact_index::has_file(g, p)),
        Err(_) => Vec::new(),
    };
    let mut partner_keys: Vec<(usize, PathBuf)> = Vec::new();
    for p in &partners {
        let k = (0, g.root.join(&p.path));
        reasons.add(&k, cochanged(p));
        if keep(0, &k.1) {
            partner_keys.push(k);
        }
    }
    // The interleave is the measured order (see impact.rs), and `near` never re-sorts it, even
    // when passed explicitly: that cost File@10 in every seeding measured on both repositories
    // (tessera -1.7 / -2.5, flight-deck -4.8 / -2.3; contract doc, "near"). Nearness pulls the
    // importers up and the co-change half down, undoing the 50:50 split.
    let ranked = impact::interleave(&importers, &partner_keys);

    let mut out = format!("Impact analysis: {}\n", path.display());
    if let Some(n) = &near {
        let _ = writeln!(out, "{}", n.note());
    }
    if seeds.len() > 1 {
        let _ = writeln!(out, "Seeds: {}, and the worktree diff: {}", seeds[0], seeds[1..].join(", "));
    }
    match &co {
        Ok(co) => {
            let _ = writeln!(out, "Ranked impact ({}: importers and co-change partners interleaved; co-change from the last {} commits):", ranked.len(), co.commits_scanned);
        }
        Err(e) => {
            let _ = writeln!(out, "Ranked impact ({}: importers only; co-change unavailable: {e}):", ranked.len());
        }
    }
    let rows = shown(&ranked, |r| r.0, LIST_CAP);
    for k in rows.iter().map(|r| &**r) {
        let _ = writeln!(out, "  {}  ({})", at(k.0, &k.1), reasons.label(k));
    }
    if rows.len() < ranked.len() {
        let _ = writeln!(out, "  … {} more", ranked.len() - rows.len());
    }

    // Tests: every one linked to a seed, uncapped and whatever `include_tests` says.
    let seed_keys: Vec<(String, &'static str)> = seeds.iter().filter_map(|s| g.file_idx(Path::new(s)).map(|i| (impact::source_key(s), g.file(i).language))).collect();
    let name_matches: Vec<(usize, PathBuf)> = index.name_matches(&seed_keys, fi).into_iter().map(|i| (0, g.abs(i))).collect();
    let test_importers: Vec<((usize, PathBuf), u32)> =
        by_depth.iter().filter(|(v, e)| e.depth == 1 && is_test(*v, &e.path)).map(|(v, e)| ((*v, e.path.clone()), e.depth)).collect();
    let test_partners: Vec<((usize, PathBuf), impact::Why)> =
        partners.iter().map(|p| ((0, g.root.join(&p.path)), cochanged(p))).filter(|(k, _)| is_test(0, &k.1)).collect();
    let tests = impact::order_tests(&name_matches, &test_importers, &test_partners, &mut reasons);
    let _ = writeln!(out, "Tests ({}):", tests.len());
    for k in &tests {
        let _ = writeln!(out, "  {}  ({})", at(k.0, &k.1), reasons.label(k));
    }

    let _ = writeln!(out, "Direct importers ({}):", direct.len());
    let rows = shown(&direct, |r| r.0, LIST_CAP);
    for (v, p, _) in rows.iter().map(|r| &**r) {
        let _ = writeln!(out, "  {}", at(*v, p));
    }
    if rows.len() < direct.len() {
        let _ = writeln!(out, "  … {} more (ranked by directory proximity); narrow with {narrow}`deps` for the importers with their specifiers", direct.len() - rows.len());
    }
    let _ = writeln!(out, "Transitive blast radius: {} file(s)", radius.len());
    let rows = shown(&radius, |r| r.0, LIST_CAP);
    for (v, e) in rows.iter().map(|r| &**r) {
        let _ = writeln!(out, "- {} (depth {})", at(*v, &e.path), e.depth);
    }
    if rows.len() < radius.len() {
        let _ = writeln!(out, "… {} more (ranked by directory proximity); narrow with {narrow}`deps` / `refs transitive=true` for the chain", radius.len() - rows.len());
    }

    let mut hot: Vec<SymbolHit> = g.file(fi).facts.symbols.iter().filter(|s| !matches!(s.kind, SymbolKind::Field | SymbolKind::Impl)).map(|s| g.hit(SymId { file: fi, local: s.local_id })).collect();
    hot.sort_by(|a, b| b.rank.partial_cmp(&a.rank).unwrap_or(std::cmp::Ordering::Equal).then(a.start_line.cmp(&b.start_line)));
    let _ = writeln!(out, "Hot symbols in this file {}:", counts(hot.len().min(5), hot.len()));
    for h in hot.iter().take(5) {
        let _ = writeln!(out, "  {} ({}) pr={:.4} {}", h.name, h.kind.as_str(), h.rank, range(h));
    }
    Ok(c.fit(out))
}

pub fn refs(c: &Ctx) -> ToolResult {
    let (name, file) = c.symbol_arg().ok_or_else(|| ToolError::bad("refs requires `symbol` (aliases: name, symbol_name)"))?;
    let views = c.views();
    let include_tests = c.args.flag(&["include_tests"], true);
    let transitive = c.args.flag(&["transitive"], false);
    let kind = c.kind()?;
    let mut defs = c.definitions(&name, kind, file.as_deref());
    let pkgs: Vec<_> = if file.is_some() { Vec::new() } else { super::pkg::candidates(c, &name, defs.len()) }
        .into_iter()
        .filter(|s| kind.is_none_or(|k| k.as_str() == s.kind.as_str()))
        .collect();
    if defs.is_empty() && pkgs.is_empty() {
        return Ok(format!("No symbol found with name '{name}'\nTry `grep query={name}*` for prefix search, or pass regex=true for a pattern match."));
    }
    let near = Near::of(c);
    let mut f = Fit::new();
    if let Some(n) = &near {
        n.sort_hits(c.graph, &mut defs);
        f.line(n.note());
    }
    for s in pkgs.iter().take(MAX_CANDIDATES) {
        let mut text = String::new();
        super::pkg::refs_section(c, &mut text, s, include_tests);
        text.lines().for_each(|l| f.line(l));
    }
    if defs.len() > 1 {
        f.line(format!("{} matches for name '{name}'; refs reports each candidate in order. Pass file_path, kind or an id (path:Type.name) to narrow.", defs.len()));
    }
    let narrow = {
        let mut n: Vec<&str> = Vec::new();
        if file.is_none() {
            n.push("file_path=");
        }
        if !c.args.has(&["kind"]) {
            n.push("kind=");
        }
        if include_tests {
            n.push("include_tests=false");
        }
        n.join(" / ")
    };
    for d in defs.iter().take(MAX_CANDIDATES) {
        f.line(format!("Symbol: {} ({})", d.name, d.kind.as_str()));
        f.line(format!("Defined in: {} {}{}", d.path.display(), range(d), tag_suffix(&views, d.view)));
        // References in the defining view and, through the links, in the views that import it.
        let is_test = |v: usize, p: &Path| is_test_path(&p.strip_prefix(&views.graph(v).root).unwrap_or(p).to_string_lossy());
        let refs: Vec<(usize, crate::query::RefHit)> = views.references(d).into_iter().filter(|(v, r)| include_tests || !is_test(*v, &r.path)).collect();
        let mut by_file: BTreeMap<(usize, &Path), Vec<&crate::query::RefHit>> = BTreeMap::new();
        for (v, r) in &refs {
            by_file.entry((*v, r.path.as_path())).or_default().push(r);
        }
        // Files ranked before any cut: the defining view first, then nearest the definition.
        let rank_of = |v: usize, p: &Path| views.graph(v).file_idx(p).map(|i| views.graph(v).file_rank[i as usize]).unwrap_or(0.0);
        let mut files: Vec<((usize, &Path), Vec<&crate::query::RefHit>)> = by_file.into_iter().collect();
        files.sort_by(|a, b| (a.0.0 != d.view).cmp(&(b.0.0 != d.view)).then(by_proximity(&d.path, (a.0.1, 0, rank_of(a.0.0, a.0.1)), (b.0.1, 0, rank_of(b.0.0, b.0.1)))));
        // The same order, then a `near` seed set on top (stable): nearest first.
        if let Some(n) = &near {
            n.sort_by_file(&mut files, |f| if (f.0).0 == 0 { c.graph.file_idx((f.0).1) } else { None });
        }
        let listed = shown(&files, |f| (f.0).0, usize::MAX);
        if refs.is_empty() {
            f.line("No references found.");
        } else {
            f.line(format!("References ({} in {} file(s)):", refs.len(), files.len()));
        }
        let sec = f.section(refs.len(), "reference(s)", narrow.clone(), None, "");
        for ((v, p), rs) in listed.into_iter().map(|f| (&f.0, &f.1)) {
            let (v, p) = (*v, *p);
            f.group(sec, format!("{}{}", p.display(), tag_suffix(&views, v)));
            for r in rs {
                let by_name = if r.confidence == Confidence::Fallback { " (matched by name)" } else { "" };
                f.row(sec, format!("  L{} {}{}{by_name}", r.line, ref_kind(r.kind), r.enclosing.as_ref().map(|e| format!(" in {e}")).unwrap_or_default()));
            }
        }
        // Files a per-view cap left out count as hidden rows in the footer, like a budget cut.
        f.footer(sec);
        if transitive {
            let mut radius: Vec<_> = views.blast_radius(d.view, d.id.file).into_iter().filter(|(v, e)| include_tests || !is_test(*v, &e.path)).collect();
            radius.sort_by(|a, b| by_proximity(&d.path, (&a.1.path, a.1.depth, a.1.rank), (&b.1.path, b.1.depth, b.1.rank)).then(a.0.cmp(&b.0)));
            let total = radius.len();
            f.line(format!("Transitive dependents ({total} file(s)):"));
            let sec = f.section(total, "", "`impact file_path=` for the ranked radius with co-change", None, "  ");
            for (v, e) in radius.iter().take(LIST_CAP) {
                f.row(sec, format!("  {}{} (depth {})", e.path.display(), tag_suffix(&views, *v), e.depth));
            }
            f.footer(sec);
        }
        f.line("");
    }
    Ok(f.render(c.token_budget))
}

/// `  [view: tessera @ /path]` for a row from a view other than the one the header names.
pub(super) fn tag_suffix(views: &Views, view: usize) -> String {
    views.tag(view).map(|t| format!("  [view: {t}]")).unwrap_or_default()
}

fn ref_kind(k: RefKind) -> &'static str {
    match k {
        RefKind::Call => "call",
        RefKind::Type => "type",
        RefKind::Use => "use",
        RefKind::Macro => "macro",
    }
}

pub fn calls(c: &Ctx) -> ToolResult {
    let (name, file) = c.symbol_arg().ok_or_else(|| ToolError::bad("calls requires `name` (aliases: symbol, symbol_name)"))?;
    let views = c.views();
    let direction = c.args.str(&["direction"]).unwrap_or_else(|| "both".into());
    let (want_callers, want_callees) = match direction.as_str() {
        "callers" => (true, false),
        "callees" => (false, true),
        "both" => (true, true),
        other => return Err(ToolError::bad(format!("unknown direction '{other}': use callers, callees or both"))),
    };
    let depth = c.args.num(&["depth"]).unwrap_or(1).min(10);
    let limit = c.args.num(&["limit"]).unwrap_or(LIST_LIMIT);
    let include_tests = c.args.flag(&["include_tests"], false);
    let kind = c.kind()?;

    let candidates: Vec<SymbolHit> = c.definitions(&name, kind, file.as_deref()).into_iter().filter(|h| function_like(h.kind)).collect();
    let target = match candidates.as_slice() {
        [] => return Ok(format!("No function-like symbol found with name '{name}'")),
        [one] => one.clone(),
        many if file.is_none() && kind.is_none() => {
            let mut out = format!("'{name}' resolves to {} function-like candidate(s). Pass one of these ids as name, or `file_path` / `kind`, to pick one.\ncandidates:\n", many.len());
            for h in many.iter().take(MAX_CANDIDATES * 3) {
                let _ = writeln!(out, "- {} ({}) [L{}-L{}]{}", symbol_id(h), h.kind.as_str(), h.start_line, h.end_line, tag_suffix(&views, h.view));
            }
            if many.len() > MAX_CANDIDATES * 3 {
                let _ = writeln!(out, "… {} more candidate(s); narrow with file_path= or kind=", many.len() - MAX_CANDIDATES * 3);
            }
            return Ok(out);
        }
        many => many[0].clone(),
    };

    let keep = |h: &SymbolHit| include_tests || !is_test_path(&h.path.strip_prefix(&views.graph(h.view).root).unwrap_or(&h.path).to_string_lossy());
    if depth >= 2 && c.format != Format::Mermaid {
        return Ok(super::calltree::render(c, &views, &target, want_callers, want_callees, depth as u32, limit, &keep));
    }
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
    // Ranked before the limit: level by level, and within a level nearest the target's file,
    // then PageRank, so the cut drops far, minor call sites first.
    let rank = |h: &SymbolHit| views.graph(h.view).file_rank.get(h.id.file as usize).copied().unwrap_or(0.0);
    let ranked = |mut edges: Vec<(SymbolHit, CallEntry)>| {
        edges.sort_by(|a, b| {
            a.1.depth
                .cmp(&b.1.depth)
                .then(by_proximity(&target.path, (&a.1.hit.path, 0, rank(&a.1.hit)), (&b.1.hit.path, 0, rank(&b.1.hit))))
                .then(a.1.hit.start_line.cmp(&b.1.hit.start_line))
                .then(a.1.line.cmp(&b.1.line))
        });
        edges
    };
    let mut callers = if want_callers { ranked(walk(Direction::In)) } else { Vec::new() };
    let mut callees = if want_callees { ranked(walk(Direction::Out)) } else { Vec::new() };
    // A `near` seed set: nearest first within each depth (the sort is stable, so equally near
    // rows keep the order above), so `limit` keeps the near rows; depth order stays, which keeps
    // every row after the one its `via` names.
    let near = Near::of(c);
    if let Some(n) = &near {
        for rows in [&mut callers, &mut callees] {
            let scores = n.hit_scores(c.graph, &rows.iter().map(|r| &r.1.hit).collect::<Vec<_>>());
            let mut keyed: Vec<(f64, (SymbolHit, CallEntry))> = scores.into_iter().zip(rows.drain(..)).collect();
            keyed.sort_by(|a, b| (a.1).1.depth.cmp(&(b.1).1.depth).then(b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal)));
            rows.extend(keyed.into_iter().map(|(_, r)| r));
        }
    }

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

    let mut f = Fit::new();
    f.line(format!("Call hierarchy for {} ({}) @ {}:L{}-{}{}", target.name, target.kind.as_str(), target.path.display(), target.start_line, target.end_line, tag_suffix(&views, target.view)));
    if let Some(n) = &near {
        f.line(n.note());
    }
    for (title, rows) in [("Callers", &callers), ("Callees", &callees)] {
        if (title == "Callers" && !want_callers) || (title == "Callees" && !want_callees) {
            continue;
        }
        let mut narrow: Vec<String> = Vec::new();
        if direction == "both" {
            narrow.push(format!("direction={}", title.to_lowercase()));
        }
        if depth > 1 {
            narrow.push(format!("depth={}", depth - 1));
        }
        if include_tests {
            narrow.push("include_tests=false".into());
        }
        let hint = narrow.join(" / ");
        let sec = f.section(rows.len(), "", hint, Some("limit"), "");
        f.title(sec, move |shown, total| format!("{title} {}:", counts(shown, total)));
        for (from, e) in rows.iter().take(limit) {
            let by_name = if e.confidence == Confidence::Fallback { " (matched by name)" } else { "" };
            // `In`: the call is in the caller's file; `Out`: in the origin's file.
            let (at, at_view) = if title == "Callers" { (&e.hit.path, e.hit.view) } else { (&from.path, from.view) };
            let via = if e.depth > 1 { format!(" via {}", from.name) } else { String::new() };
            // A callee in another view than the call: say where it is defined.
            let defined = if title == "Callees" && e.hit.view != from.view { format!(" (defined in {}{})", e.hit.path.display(), tag_suffix(&views, e.hit.view)) } else { String::new() };
            f.row(sec, format!("{}[d{}] {} ({}) {}:L{}{via}{by_name}{defined}{}", "  ".repeat(e.depth as usize), e.depth, e.hit.name, e.hit.kind.as_str(), at.display(), e.line, tag_suffix(&views, at_view)));
        }
        f.footer(sec);
    }
    Ok(f.render(c.token_budget))
}
