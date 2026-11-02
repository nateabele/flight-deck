//! `qartez_analyze`: the analysis tier behind one tool. `report` picks the analysis; `report=help`
//! returns the parameter docs of every report.
//!
//! qartez gave each analysis its own MCP tool (43 in all), and every tool's schema is paid for in
//! every session's context whether the agent uses it or not. Here the six analyses share one
//! schema of common parameters (`file_path`, `files`, `terms`, `symbol`, `limit`); the
//! parameters only one report reads (`direction`, `depth`, `min_support`, `include_tests`, `kind`)
//! are described by `report=help` instead of in the schema. The A/B that chose this organization
//! is in the tool contract (`docs/superpowers/specs/2026-11-01-index-tool-contract.md`, "Analysis
//! tier").
//!
//! Every report is a pure function of the `Ctx` like the other tools: the graph of the answering
//! view (and its linked views), the repository's co-change table and the worktree diff.

use super::caps::parse_symbol_id;
use super::{impact, is_test_path, Ctx, ToolError, ToolResult};
use crate::facts::{HierarchyKind, SymbolKind};
use crate::graph::ViewGraph;
use crate::words::query_words;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt::Write;
use std::path::{Path, PathBuf};

/// The reports, in the order `help` lists them.
pub const REPORTS: &[&str] = &["unused", "cochange", "context", "hierarchy", "diff_impact", "hotspots"];

/// What `report=help` answers. The shim answers it too, without the daemon, so the docs are there
/// even when the index is not.
pub const HELP: &str = "qartez_analyze reports (report=<name>; every report also takes limit and token_budget):\n\
- unused: exported symbols nothing references or imports by name, in this view and its linked views. file_path: a file or directory to narrow to. kind: one symbol kind. include_tests: list test files' exports too (default false). Methods, fields and constructors are left out (dynamic dispatch hides their callers). limit default 50.\n\
- cochange: files that changed in the same commits as file_path, or as any of files, by confidence (shared commits / commits that touched the seed). min_support: shared commits needed (default 2). limit default 20.\n\
- context: files related to a task, by personalized PageRank from files and from the symbols whose names match terms (default seeds: changed and recently read files). limit default 15.\n\
- hierarchy: supertypes and subtypes of a type, trait, protocol or interface (symbol), transitively. direction: up, down or both (default). depth: levels (default 5).\n\
- diff_impact: what the worktree's uncommitted changes could break: importers of every changed file and co-change partners, interleaved, plus the tests to run. files: another seed set instead of the diff. include_tests: tests in the ranked list too. limit default 30.\n\
- hotspots: files by churn x size (commits that touched the file in recent history x lines), with the longest function. file_path: a file or directory to narrow to. include_tests (default false). limit default 15.\n\
Paths in results are absolute; each result starts with the view: line.";

pub fn analyze(c: &Ctx) -> ToolResult {
    let report = report(c.args)?;
    match report.as_str() {
        "help" => Ok(HELP.to_string()),
        "unused" => unused(c),
        "cochange" => cochange(c),
        "context" => context(c),
        "hierarchy" => hierarchy(c),
        "diff_impact" => diff_impact(c),
        "hotspots" => hotspots(c),
        _ => unreachable!("report() checked it"),
    }
}

/// The `report` argument, checked against the list.
pub fn report(args: &super::args::Args) -> std::result::Result<String, ToolError> {
    let Some(r) = args.str(&["report", "analysis", "mode"]) else {
        return Err(ToolError::bad(format!("analyze requires report: one of {}, or help", REPORTS.join(", "))));
    };
    let r = r.trim().to_ascii_lowercase().replace('-', "_");
    if r == "help" || REPORTS.contains(&r.as_str()) {
        Ok(r)
    } else {
        Err(ToolError::bad(format!("unknown report '{r}': use one of {}, or help", REPORTS.join(", "))))
    }
}

/// Does this report follow links into other views? The ones that look at who uses what do.
pub fn uses_links(args: &super::args::Args) -> bool {
    matches!(report(args).as_deref(), Ok("unused" | "hierarchy" | "diff_impact"))
}

fn limit(c: &Ctx, default: usize) -> usize {
    match c.args.num(&["limit", "top_n"]) {
        Some(0) | None => default,
        Some(n) => n,
    }
}

/// Worktree-relative paths of `file_path` and `files`, as the co-change table and the diff name them.
fn seed_rels(c: &Ctx) -> Vec<String> {
    let g = c.graph;
    let mut raw: Vec<PathBuf> = c.args.path(super::args::FILE).into_iter().collect();
    raw.extend(c.args.list(&["files"]).iter().map(|f| super::args::resolve_path(&c.args.cwd, f)));
    let mut out: Vec<String> = Vec::new();
    for p in raw {
        let rel = match g.file_idx(&p) {
            Some(i) => g.file(i).path.clone(),
            None => p.strip_prefix(&g.root).map(|r| r.to_string_lossy().to_string()).unwrap_or_else(|_| p.to_string_lossy().to_string()),
        };
        if !out.contains(&rel) {
            out.push(rel);
        }
    }
    out
}

/// `file_path` read as a scope: a file, or a directory whose files are in scope.
fn scope(c: &Ctx) -> Option<PathBuf> {
    c.args.path(super::args::FILE)
}

fn in_scope(g: &ViewGraph, fi: u32, scope: &Option<PathBuf>) -> bool {
    scope.as_ref().is_none_or(|s| g.abs(fi).starts_with(s))
}

fn is_test(g: &ViewGraph, fi: u32) -> bool {
    is_test_path(&g.file(fi).path)
}

// ---- unused ---------------------------------------------------------------------------------

/// Kinds whose uses the graph sees reliably enough to call one unused. A method's caller is often
/// a receiver the resolver could not type; a field or constructor is used through its parent.
fn unused_kind(k: SymbolKind) -> bool {
    matches!(
        k,
        SymbolKind::Function | SymbolKind::Struct | SymbolKind::Enum | SymbolKind::Trait | SymbolKind::Interface | SymbolKind::Class | SymbolKind::TypeAlias | SymbolKind::Const | SymbolKind::Port | SymbolKind::Macro | SymbolKind::Variable
    )
}

/// What a runtime or framework uses without a reference in the code: `main`, Python dunders,
/// OTP and LiveView callbacks, a Rust `extern "C"` function (called across an FFI or wasm
/// boundary), a Swift `@main` type, and a type alias nested in a type (a protocol witness such as
/// NIO's `InboundIn`).
fn entry_point(s: &crate::facts::Symbol, f: &crate::graph::FileNode) -> bool {
    let name = s.name.as_str();
    name == "main"
        || (name.starts_with("__") && name.ends_with("__"))
        || (f.language == "elixir" && (name.starts_with("handle_") || matches!(name, "init" | "start_link" | "child_spec" | "terminate" | "code_change" | "mount" | "render" | "start")))
        || (f.language == "rust" && s.signature.as_deref().is_some_and(|sig| sig.contains("extern \"")))
        || (f.language == "swift" && (s.signature.as_deref().is_some_and(|sig| sig.contains("@main")) || (s.kind == SymbolKind::TypeAlias && s.parent.is_some())))
}

struct Cand {
    file: u32,
    local: u32,
    start: u32,
    end: u32,
    used: bool,
}

/// Exports with no reference or import by name anywhere in the view or its linked views. Matching
/// by name, not by resolved target, keeps the answer conservative: a reference the resolver could
/// not bind still counts as a use, so what is listed is unused by any name the index can see.
fn unused(c: &Ctx) -> ToolResult {
    let g = c.graph;
    let include_tests = c.args.flag(&["include_tests"], false);
    let kind = c.kind()?;
    let scope = scope(c);
    let limit = limit(c, 50);
    let mut cands: Vec<Cand> = Vec::new();
    let mut by_name: HashMap<String, Vec<usize>> = HashMap::new();
    for fi in (0..g.files_len() as u32).filter(|i| g.file(*i).alive) {
        if (!include_tests && is_test(g, fi)) || !in_scope(g, fi, &scope) {
            continue;
        }
        let f = g.file(fi);
        for s in &f.facts.symbols {
            if !s.exported || !unused_kind(s.kind) || kind.is_some_and(|k| k != s.kind) || entry_point(s, f) {
                continue;
            }
            by_name.entry(s.name.clone()).or_default().push(cands.len());
            cands.push(Cand { file: fi, local: s.local_id, start: s.start_line, end: s.end_line, used: false });
        }
    }
    let views = c.views();
    for v in 0..views.len() {
        let vg = views.graph(v);
        let mut mark = |name: &str, fi: u32, line: u32| {
            if let Some(ids) = by_name.get(name) {
                for &i in ids {
                    let k = &mut cands[i];
                    // A use inside the symbol's own definition (recursion, a signature line) is not a use.
                    if !(v == 0 && k.file == fi && line >= k.start && line <= k.end) {
                        k.used = true;
                    }
                }
            }
        };
        for fi in (0..vg.files_len() as u32).filter(|i| vg.file(*i).alive) {
            let f = vg.file(fi);
            for r in &f.facts.refs {
                mark(vg.name(r.name), fi, r.line);
            }
            for imp in &f.facts.imports {
                for n in &imp.names {
                    mark(&n.name, fi, imp.line);
                }
            }
        }
    }
    text_uses(&views, &mut cands, &by_name);
    let mut rows: Vec<&Cand> = cands.iter().filter(|k| !k.used).collect();
    rows.sort_by(|a, b| g.file(a.file).path.cmp(&g.file(b.file).path).then(a.start.cmp(&b.start)));
    let mut out = format!(
        "Unused exports: {} (exported; no reference or import by that name in this view{}{})\n",
        rows.len(),
        if views.len() > 1 { " or its linked views" } else { "" },
        if include_tests { "" } else { "; test files left out" }
    );
    for k in rows.iter().take(limit) {
        let s = g.file(k.file).symbol(k.local);
        let _ = writeln!(out, "  - {} ({}) {}:L{}-L{}", s.name, s.kind.as_str(), g.abs(k.file).display(), k.start, k.end);
    }
    if rows.len() > limit {
        let _ = writeln!(out, "  … {} more; raise limit or narrow with file_path", rows.len() - limit);
    }
    out.push_str("Callers outside these views (other repositories, reflection, a framework) are not seen: check qartez_refs before deleting.\n");
    Ok(c.fit(out))
}

/// The extractors record calls and type uses as references, not every mention: tree-sitter reads
/// a Rust macro's arguments as a token tree (`println!("{}", m::helper())` names no `helper`),
/// and a Python or Swift read of a constant (`return LIMIT`) is no reference. On flight-deck's
/// index crate four of seven "unused" exports were Rust macro arguments, and across the repository
/// most Swift and Python hits were constants read in code. So a candidate still standing is
/// looked for as a word in the source of every view, outside its own definition and outside line
/// comments. Only the survivors are searched for, so files are read only when something is left.
fn text_uses(views: &crate::links::Views, cands: &mut [Cand], by_name: &HashMap<String, Vec<usize>>) {
    let mut names: Vec<&str> = by_name.iter().filter(|(_, ids)| ids.iter().any(|i| !cands[*i].used)).map(|(n, _)| n.as_str()).collect();
    if names.is_empty() {
        return;
    }
    names.sort_unstable();
    let pattern = format!(r"\b(?:{})\b", names.iter().map(|n| regex::escape(n)).collect::<Vec<_>>().join("|"));
    // Thousands of names compile to a large automaton; the default 10 MB cap would refuse it and
    // leave every survivor reported.
    let Ok(re) = regex::RegexBuilder::new(&pattern).size_limit(256 << 20).build() else { return };
    for v in 0..views.len() {
        let g = views.graph(v);
        for fi in (0..g.files_len() as u32).filter(|i| g.file(*i).alive) {
            let comment = line_comment(g.file(fi).language);
            let Ok(text) = std::fs::read_to_string(g.abs(fi)) else { continue };
            if !re.is_match(&text) {
                continue;
            }
            for (n, line) in text.lines().enumerate() {
                let code = line.split(comment).next().unwrap_or("");
                for m in re.find_iter(code) {
                    let line_no = n as u32 + 1;
                    for &i in by_name.get(m.as_str()).into_iter().flatten() {
                        let k = &mut cands[i];
                        if !(v == 0 && k.file == fi && line_no >= k.start && line_no <= k.end) {
                            k.used = true;
                        }
                    }
                }
            }
        }
    }
}

/// What starts a line comment in a language: what follows it on a line is not a use.
fn line_comment(language: &str) -> &'static str {
    match language {
        "python" | "elixir" => "#",
        "elm" => "--",
        _ => "//",
    }
}

// ---- cochange -------------------------------------------------------------------------------

fn cochange(c: &Ctx) -> ToolResult {
    let g = c.graph;
    let seeds = seed_rels(c);
    if seeds.is_empty() {
        return Err(ToolError::bad("cochange requires file_path or files"));
    }
    let min = c.args.num(&["min_support"]).map(|n| n as u32).unwrap_or(impact::MIN_SUPPORT).max(1);
    let limit = limit(c, 20);
    let co = (c.cochange)().map_err(|e| ToolError::failed(format!("co-change unavailable: {e}")))?;
    let seed_refs: Vec<&str> = seeds.iter().map(String::as_str).collect();
    let partners: Vec<impact::Partner> = impact::ranked_partners(&co, &seed_refs, min).into_iter().filter(|p| g.file_idx(Path::new(&p.path)).is_some()).collect();
    let mut out = format!("Co-change seeds: {} (last {} commits; mass commits skipped)\n", seeds.join(", "), co.commits_scanned);
    for s in &seeds {
        let _ = writeln!(out, "  {} changed in {} commit(s)", s, co.touches(s));
    }
    let _ = writeln!(out, "Co-change partners ({}; confidence = shared commits / the seed's commits, at least {min} shared):", partners.len());
    for p in partners.iter().take(limit) {
        let pct = 100 * p.together / p.of.max(1);
        let with = if seeds.len() > 1 { format!(" with {}", p.seed) } else { String::new() };
        let _ = writeln!(out, "  {}  {}/{} ({pct}%){with}", g.root.join(&p.path).display(), p.together, p.of);
    }
    if partners.len() > limit {
        let _ = writeln!(out, "  … {} more; raise limit", partners.len() - limit);
    }
    Ok(c.fit(out))
}

// ---- context --------------------------------------------------------------------------------

fn context(c: &Ctx) -> ToolResult {
    let g = c.graph;
    let limit = limit(c, 15);
    let given: Vec<u32> = c.args.list(&["files"]).iter().chain(c.args.path(super::args::FILE).map(|p| p.to_string_lossy().to_string()).iter()).filter_map(|f| g.file_idx(&super::args::resolve_path(&c.args.cwd, f))).collect();
    let terms = c.args.list(&["terms", "query", "boost_terms"]);
    let words = query_words(&terms.join(" "));
    // Files whose symbols match the terms, best first, with the names that matched.
    let mut matched: Vec<u32> = Vec::new();
    let mut names: HashMap<u32, Vec<String>> = HashMap::new();
    if !words.is_empty() {
        for (_, id) in g.words().search(&words).into_iter().take(40) {
            // A symbol can match by its parent's or path's words; a row names only the symbols
            // whose own name carries a word, so the reason reads true.
            let name = g.symbol(id).name.clone();
            let n = names.entry(id.file).or_default();
            if !n.contains(&name) && words.iter().any(|w| name.to_lowercase().contains(w.as_str())) {
                n.push(name);
            }
            if !matched.contains(&id.file) {
                matched.push(id.file);
            }
        }
    }
    let defaulted = given.is_empty() && words.is_empty();
    let seeds: Vec<u32> = if defaulted { c.recent.iter().filter_map(|p| g.file_idx(p)).take(crate::near::MAX_DEFAULT_SEEDS).collect() } else { given.clone() };
    if seeds.is_empty() && matched.is_empty() {
        return Err(ToolError::bad(if words.is_empty() && !terms.is_empty() {
            "context: the terms have no word of three letters or more to match".to_string()
        } else {
            "context requires files or terms (nothing is changed or recently read here to default to)".to_string()
        }));
    }
    // Explicit files restart the walk at weight 1; matched files at a weight that falls with
    // their match rank, so the best match leads without the tenth drowning the given files.
    let mut weights: BTreeMap<u32, f64> = seeds.iter().map(|f| (*f, 1.0)).collect();
    for (i, f) in matched.iter().take(10).enumerate() {
        *weights.entry(*f).or_default() += 1.0 / (1.0 + i as f64);
    }
    let w: Vec<(u32, f64)> = weights.into_iter().filter(|(f, _)| g.file(*f).alive).collect();
    let ranks = g.personalized_file_rank(&w, crate::graph::ppr::DEFAULT_REVERSE);
    let seed_set: HashSet<u32> = seeds.iter().copied().collect();
    let imports_of = |fi: u32| -> HashSet<u32> { g.importers.iter().enumerate().filter(|(_, imps)| imps.contains(&fi)).map(|(t, _)| t as u32).collect() };
    let seed_imports: HashMap<u32, HashSet<u32>> = seeds.iter().map(|s| (*s, imports_of(*s))).collect();
    let mut rows: Vec<(f64, u32)> = (0..g.files_len() as u32)
        .filter(|i| g.file(*i).alive && !seed_set.contains(i))
        .map(|i| (ranks[i as usize] * if names.contains_key(&i) { 5.0 } else { 1.0 }, i))
        .filter(|(r, _)| *r > 0.0)
        .collect();
    rows.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal).then(g.file(a.1).path.cmp(&g.file(b.1).path)));
    let mut out = String::new();
    let seed_names: Vec<String> = seeds.iter().map(|s| g.file(*s).path.clone()).collect();
    let _ = writeln!(
        out,
        "Context for {}{}{} (personalized PageRank; seeds and term matches restart the walk)",
        if seed_names.is_empty() { String::new() } else { format!("files {}", seed_names.join(", ")) },
        if !seed_names.is_empty() && !words.is_empty() { " and " } else { "" },
        if words.is_empty() { String::new() } else { format!("terms {}", terms.join(" ")) },
    );
    if defaulted {
        out.push_str("(seeded by the changed and recently read files; pass files or terms to choose)\n");
    }
    let _ = writeln!(out, "Related files ({}):", rows.len().min(limit));
    for (score, fi) in rows.iter().take(limit) {
        let mut why: Vec<String> = Vec::new();
        if let Some(n) = names.get(fi).filter(|n| !n.is_empty()) {
            why.push(format!("matches {}", n.iter().take(3).cloned().collect::<Vec<_>>().join(", ")));
        }
        for s in &seeds {
            if g.importers[*s as usize].contains(fi) {
                why.push(format!("imports {}", g.file(*s).path));
            } else if seed_imports.get(s).is_some_and(|i| i.contains(fi)) {
                why.push(format!("imported by {}", g.file(*s).path));
            }
        }
        let _ = writeln!(out, "  {}  {:.4}{}", g.abs(*fi).display(), score, if why.is_empty() { String::new() } else { format!(" ({})", why.join("; ")) });
    }
    Ok(c.fit(out))
}

// ---- hierarchy ------------------------------------------------------------------------------

/// `Foo<T>`, `mod::Foo`, `Mod.Foo` -> `Foo`.
fn last_segment(s: &str) -> &str {
    let s = s.split('<').next().unwrap_or(s).trim();
    s.rsplit([':', '.']).next().unwrap_or(s)
}

struct Rel {
    view: usize,
    file: u32,
    child: u32,
    target: String,
    kind: HierarchyKind,
}

fn type_like(k: SymbolKind) -> bool {
    matches!(k, SymbolKind::Struct | SymbolKind::Enum | SymbolKind::Trait | SymbolKind::Interface | SymbolKind::Class | SymbolKind::TypeAlias | SymbolKind::Module)
}

fn hierarchy(c: &Ctx) -> ToolResult {
    let Some(raw) = c.args.str(super::args::SYMBOL) else {
        return Err(ToolError::bad("hierarchy requires symbol: a type, trait, protocol or interface name"));
    };
    let (name, _) = parse_symbol_id(&raw, &c.args.cwd);
    let name = last_segment(&name).to_string();
    let dir = c.args.str(&["direction"]).unwrap_or_else(|| "both".into()).to_ascii_lowercase();
    let (up, down) = match dir.as_str() {
        "up" | "supertypes" | "parents" => (true, false),
        "down" | "subtypes" | "children" | "implementors" => (false, true),
        "both" => (true, true),
        other => return Err(ToolError::bad(format!("unknown direction '{other}': use up, down or both"))),
    };
    let depth = c.args.num(&["depth"]).unwrap_or(5).clamp(1, 10) as u32;
    let limit = limit(c, 50);
    let views = c.views();
    let mut rels: Vec<Rel> = Vec::new();
    for v in 0..views.len() {
        let g = views.graph(v);
        for fi in (0..g.files_len() as u32).filter(|i| g.file(*i).alive) {
            for r in &g.file(fi).facts.hierarchy {
                rels.push(Rel { view: v, file: fi, child: r.symbol, target: last_segment(&r.target).to_string(), kind: r.kind });
            }
        }
    }
    let child_name = |r: &Rel| views.graph(r.view).file(r.file).symbol(r.child).name.clone();
    let at = |v: usize, fi: u32, line: u32| format!("{}:L{}{}", views.graph(v).abs(fi).display(), line, views.tag(v).map(|t| format!(" [view: {t}]")).unwrap_or_default());
    // Where a type is defined: its type-like definitions in the views, best ranked first.
    let defs_of = |n: &str| {
        let mut d: Vec<_> = views.find_symbols(&crate::query::NameMatch::Exact(n.to_string()), None).into_iter().filter(|h| type_like(h.kind)).collect();
        d.sort_by(|a, b| a.view.cmp(&b.view).then(b.rank.partial_cmp(&a.rank).unwrap_or(std::cmp::Ordering::Equal)));
        d
    };
    let defs = defs_of(&name);
    let known = !defs.is_empty() || rels.iter().any(|r| r.target == name || child_name(r) == name);
    if !known {
        let note = if c.building.is_some() { " yet (index: building)" } else { "" };
        return Err(ToolError::failed(format!("no type named {name} and no relation to one in this view{note}")));
    }
    let mut out = format!("Type hierarchy of {name}");
    match defs.first() {
        Some(h) => {
            let _ = writeln!(out, " ({}) @ {}", h.kind.as_str(), at(h.view, h.id.file, h.start_line));
        }
        None => out.push_str(" (not defined in these views)\n"),
    }
    if up {
        let mut seen: HashSet<String> = HashSet::from([name.clone()]);
        let mut frontier = vec![name.clone()];
        let mut rows: Vec<String> = Vec::new();
        for d in 1..=depth {
            let mut next = Vec::new();
            for n in &frontier {
                for r in rels.iter().filter(|r| child_name(r) == *n) {
                    if !seen.insert(r.target.clone()) {
                        continue;
                    }
                    let verb = if r.kind == HierarchyKind::Implements { "implemented by" } else { "extended by" };
                    let row = match defs_of(&r.target).first() {
                        Some(h) => format!("  {}  {} ({}), {verb} {n} [depth {d}]", at(h.view, h.id.file, h.start_line), r.target, h.kind.as_str()),
                        None => format!("  {} (not defined in these views), {verb} {n} at {} [depth {d}]", r.target, at(r.view, r.file, views.graph(r.view).file(r.file).symbol(r.child).start_line)),
                    };
                    rows.push(row);
                    next.push(r.target.clone());
                }
            }
            frontier = next;
        }
        let _ = writeln!(out, "Supertypes ({}):", rows.len());
        for r in rows.iter().take(limit) {
            let _ = writeln!(out, "{r}");
        }
    }
    if down {
        let mut seen: HashSet<String> = HashSet::from([name.clone()]);
        let mut frontier = vec![name.clone()];
        let mut rows: Vec<String> = Vec::new();
        for d in 1..=depth {
            let mut next = Vec::new();
            for n in &frontier {
                for r in rels.iter().filter(|r| r.target == *n) {
                    let child = child_name(r);
                    let s = views.graph(r.view).file(r.file).symbol(r.child);
                    let verb = if r.kind == HierarchyKind::Implements { "implements" } else { "extends" };
                    rows.push(format!("  {}  {} ({}) {verb} {n} [depth {d}]", at(r.view, r.file, s.start_line), child, s.kind.as_str()));
                    if seen.insert(child.clone()) {
                        next.push(child);
                    }
                }
            }
            frontier = next;
        }
        let _ = writeln!(out, "Subtypes ({}):", rows.len());
        for r in rows.iter().take(limit) {
            let _ = writeln!(out, "{r}");
        }
        if rows.len() > limit {
            let _ = writeln!(out, "  … {} more; raise limit or lower depth", rows.len() - limit);
        }
    }
    Ok(c.fit(out))
}

// ---- diff_impact ----------------------------------------------------------------------------

fn diff_impact(c: &Ctx) -> ToolResult {
    let g = c.graph;
    let include_tests = c.args.flag(&["include_tests"], false);
    let limit = limit(c, 30);
    let named = c.args.has(&["files"]);
    let seeds: Vec<String> = if named { seed_rels(c) } else { c.diff.to_vec() };
    if seeds.is_empty() {
        return Ok("Diff impact: no uncommitted changes in this worktree (the diff is what diff_impact follows; pass files to name a set)\n".to_string());
    }
    let views = c.views();
    let seed_idx: Vec<u32> = seeds.iter().filter_map(|s| g.file_idx(Path::new(s))).collect();
    let seed_paths: HashSet<PathBuf> = seeds.iter().map(|s| g.root.join(s)).collect();
    let is_test_at = |v: usize, p: &Path| is_test_path(&p.strip_prefix(&views.graph(v).root).unwrap_or(p).to_string_lossy());
    let keep = |v: usize, p: &Path| include_tests || !is_test_at(v, p);
    // List A: transitive importers of any seed, at the depth of the nearest seed, then PageRank.
    let mut depth: HashMap<(usize, PathBuf), (u32, f64)> = HashMap::new();
    for &fi in &seed_idx {
        for (v, e) in views.blast_radius(0, fi) {
            let slot = depth.entry((v, e.path.clone())).or_insert((e.depth, e.rank));
            slot.0 = slot.0.min(e.depth);
        }
    }
    let mut radius: Vec<((usize, PathBuf), u32, f64)> = depth.into_iter().map(|(k, (d, r))| (k, d, r)).collect();
    radius.sort_by(|a, b| a.1.cmp(&b.1).then(b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal)).then(a.0.cmp(&b.0)));
    let mut reasons: impact::Reasons<(usize, PathBuf)> = impact::Reasons::default();
    let mut importers: Vec<(usize, PathBuf)> = Vec::new();
    for (k, d, _) in &radius {
        reasons.add(k, impact::Why::Importer { depth: *d });
        if keep(k.0, &k.1) && !seed_paths.contains(&k.1) {
            importers.push(k.clone());
        }
    }
    // List B: co-change partners of any seed.
    let co = (c.cochange)();
    let seed_refs: Vec<&str> = seeds.iter().map(String::as_str).collect();
    let partners: Vec<impact::Partner> = match &co {
        Ok(co) => impact::ranked_partners(co, &seed_refs, impact::MIN_SUPPORT).into_iter().filter(|p| g.file_idx(Path::new(&p.path)).is_some()).collect(),
        Err(_) => Vec::new(),
    };
    let cochanged = |p: &impact::Partner| impact::Why::CoChanged { together: p.together, of: p.of, with: (seeds.len() > 1).then(|| p.seed.clone()) };
    let mut partner_keys: Vec<(usize, PathBuf)> = Vec::new();
    for p in &partners {
        let k = (0, g.root.join(&p.path));
        reasons.add(&k, cochanged(p));
        if keep(0, &k.1) {
            partner_keys.push(k);
        }
    }
    let ranked = impact::interleave(&importers, &partner_keys);
    let at = |k: &(usize, PathBuf)| format!("{}{}", k.1.display(), views.tag(k.0).map(|t| format!("  [view: {t}]")).unwrap_or_default());

    let mut out = format!("Diff impact: {} {} file(s): {}\n", seeds.len(), if named { "named" } else { "changed" }, seeds.join(", "));
    match &co {
        Ok(co) => {
            let _ = writeln!(out, "Ranked impact ({}: importers of the changed files and their co-change partners interleaved; last {} commits):", ranked.len(), co.commits_scanned);
        }
        Err(e) => {
            let _ = writeln!(out, "Ranked impact ({}: importers only; co-change unavailable: {e}):", ranked.len());
        }
    }
    for k in ranked.iter().take(limit) {
        let _ = writeln!(out, "  {}  ({})", at(k), reasons.label(k));
    }
    if ranked.len() > limit {
        let _ = writeln!(out, "  … {} more; raise limit, or qartez_impact on one file for its own list", ranked.len() - limit);
    }

    // Tests: changed tests, then name matches of the changed sources, test importers, test partners.
    let mut changed_tests: Vec<(usize, PathBuf)> = seeds.iter().filter(|s| is_test_path(s) && g.file_idx(Path::new(s)).is_some()).map(|s| (0, g.root.join(s))).collect();
    let seed_keys: HashSet<(String, &str)> = seed_idx.iter().filter(|i| !is_test(g, **i)).map(|i| (impact::source_key(&g.file(*i).path), g.file(*i).language)).collect();
    let live: Vec<u32> = (0..g.files_len() as u32).filter(|i| g.file(*i).alive).collect();
    let mut sources: HashMap<(String, &str), usize> = HashMap::new();
    for i in live.iter().filter(|i| !is_test(g, **i)) {
        *sources.entry((impact::source_key(&g.file(*i).path), g.file(*i).language)).or_default() += 1;
    }
    let name_matches: Vec<(usize, PathBuf)> = live
        .iter()
        .filter(|i| is_test(g, **i))
        .filter_map(|i| impact::test_subject(&g.file(*i).path).map(|s| ((s, g.file(*i).language), *i)))
        .filter(|(k, _)| seed_keys.contains(k) && sources.get(k) == Some(&1))
        .map(|(_, i)| (0, g.abs(i)))
        .collect();
    let test_importers: Vec<((usize, PathBuf), u32)> = radius.iter().filter(|(k, d, _)| *d == 1 && is_test_at(k.0, &k.1)).map(|(k, d, _)| (k.clone(), *d)).collect();
    let test_partners: Vec<((usize, PathBuf), impact::Why)> = partners.iter().map(|p| ((0, g.root.join(&p.path)), cochanged(p))).filter(|(k, _)| is_test_at(0, &k.1)).collect();
    let tests = impact::order_tests(&name_matches, &test_importers, &test_partners, &mut reasons);
    changed_tests.retain(|k| !tests.contains(k));
    let _ = writeln!(out, "Tests ({}):", tests.len() + changed_tests.len());
    for k in &changed_tests {
        let _ = writeln!(out, "  {}  (changed)", at(k));
    }
    for k in &tests {
        let _ = writeln!(out, "  {}  ({})", at(k), reasons.label(k));
    }
    Ok(c.fit(out))
}

// ---- hotspots -------------------------------------------------------------------------------

fn hotspots(c: &Ctx) -> ToolResult {
    let g = c.graph;
    let include_tests = c.args.flag(&["include_tests"], false);
    let scope = scope(c);
    let limit = limit(c, 15);
    let co = (c.cochange)().map_err(|e| ToolError::failed(format!("churn needs git history: {e}")))?;
    let mut rows: Vec<(u64, u32, u32, u32)> = Vec::new();
    for fi in (0..g.files_len() as u32).filter(|i| g.file(*i).alive) {
        if (!include_tests && is_test(g, fi)) || !in_scope(g, fi, &scope) {
            continue;
        }
        let f = g.file(fi);
        let touches = co.touches(&f.path);
        if touches == 0 {
            continue;
        }
        let lines = f.facts.line_count.max(1);
        rows.push((touches as u64 * lines as u64, touches, lines, fi));
    }
    rows.sort_by(|a, b| b.0.cmp(&a.0).then(g.file(a.3).path.cmp(&g.file(b.3).path)));
    let mut out = format!("Hotspots ({} files changed in the last {} commits; score = commits x lines):\n", rows.len(), co.commits_scanned);
    for (score, touches, lines, fi) in rows.iter().take(limit) {
        let longest = g
            .file(*fi)
            .facts
            .symbols
            .iter()
            .filter(|s| matches!(s.kind, SymbolKind::Function | SymbolKind::Method))
            .max_by_key(|s| s.end_line.saturating_sub(s.start_line))
            .map(|s| format!("; longest function {} L{}-L{} ({} lines)", s.name, s.start_line, s.end_line, s.end_line - s.start_line + 1))
            .unwrap_or_default();
        let _ = writeln!(out, "  {}  {score} = {touches} commits x {lines} lines{longest}", g.abs(*fi).display());
    }
    if rows.len() > limit {
        let _ = writeln!(out, "  … {} more; raise limit or narrow with file_path", rows.len() - limit);
    }
    Ok(c.fit(out))
}
