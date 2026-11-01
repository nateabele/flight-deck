//! Tools that locate and show code: `find`, `grep`, `read`, `outline`.

use super::args::FILE;
use super::caps::{parse_symbol_id, symbol_id, Fit, LIST_LIMIT};
use super::{compile_regex, range, status, Ctx, Format, ToolError, ToolResult};
use crate::facts::SymbolKind;
use crate::near::Near;
use crate::query::{NameMatch, SymbolHit};
use std::fmt::Write;
use std::path::Path;

const DEFAULT_MAX_BYTES: usize = 25_000;
const OUTLINE_PAGE: usize = 100;
/// `find` prints full blocks up to this many hits and one row per hit past it (`detail`).
const FIND_FULL_UP_TO: usize = 10;
/// `grep` adds each hit's signature up to this many hits (`detail`).
const GREP_FULL_UP_TO: usize = 5;
/// A whole-file `read` of a longer file returns its outline and the first `READ_WINDOW` lines.
const READ_WHOLE_UP_TO: usize = 150;
const READ_WINDOW: usize = 100;

/// `detail`: `full` or `rows`, defaulting from the hit count.
fn detail_full(c: &Ctx, hits: usize, full_up_to: usize) -> std::result::Result<bool, ToolError> {
    match c.args.str(&["detail"]).as_deref() {
        None => Ok(hits <= full_up_to),
        Some("full") => Ok(true),
        Some("rows") => Ok(false),
        Some(other) => Err(ToolError::bad(format!("unknown detail '{other}': use full or rows"))),
    }
}

pub fn find(c: &Ctx) -> ToolResult {
    let (name, file) = c.symbol_arg().ok_or_else(|| ToolError::bad("find requires `name` (aliases: symbol, symbol_name)"))?;
    let kind = c.kind()?;
    let regex = c.args.flag(&["regex"], false);
    let limit = c.args.num(&["limit"]).unwrap_or(LIST_LIMIT);
    let matcher = if regex { NameMatch::Regex(compile_regex(&name)?) } else { NameMatch::Exact(name.clone()) };
    let views = c.views();
    let mut hits = views.find_symbols(&matcher, kind);
    if let Some(f) = &file {
        hits.retain(|h| h.path == *f);
    }
    let pkgs: Vec<_> = if regex || file.is_some() { Vec::new() } else { super::pkg::candidates(c, &name, hits.len()) }
        .into_iter()
        .filter(|s| kind.is_none_or(|k| k.as_str() == s.kind.as_str()))
        .collect();
    let history = super::history::section(c, &name, hits.is_empty() && pkgs.is_empty());
    if hits.is_empty() && pkgs.is_empty() {
        let mut out = format!("No symbol found with name '{name}'\nTry `grep query={name}*` for prefix search, or pass regex=true for a pattern match.");
        if !regex && let Some(rows) = super::ranked::find_fallback(c, &name, kind) {
            out.push('\n');
            out.push_str(&rows);
        }
        out.push_str(&history);
        return Ok(out);
    }
    let near = Near::of(c);
    if let Some(n) = &near {
        n.sort_hits(c.graph, &mut hits);
    }
    let full = detail_full(c, hits.len().min(limit), FIND_FULL_UP_TO)?;
    let mut out = format!("Found {} match(es) for '{name}':\n", hits.len() + pkgs.len());
    if let Some(n) = &near {
        let _ = writeln!(out, "{}", n.note());
    }
    for h in hits.iter().take(limit) {
        if !full {
            let tag = views.tag(h.view).map(|t| format!("  [view: {t}]")).unwrap_or_default();
            let _ = writeln!(out, "{} {} {} {}  {}{tag}", h.name, h.kind.as_str(), h.path.display(), range(h), status(h));
            continue;
        }
        let _ = writeln!(out, "{} ({})", h.name, h.kind.as_str());
        let _ = writeln!(out, "File: {} {}", h.path.display(), range(h));
        if c.format != Format::Concise {
            let _ = writeln!(out, "Id: {}", symbol_id(h));
        }
        if let Some(tag) = views.tag(h.view) {
            let _ = writeln!(out, "View: {tag}");
        }
        if let Some(m) = &h.module {
            let _ = writeln!(out, "Module: {m}");
        }
        if let Some(p) = &h.parent {
            let _ = writeln!(out, "In: {p}");
        }
        if let Some(s) = &h.signature {
            let _ = writeln!(out, "Signature: {s}");
        }
        let _ = writeln!(out, "Status: {}", status(h));
    }
    // Package symbols go after the repository's, inside the same limit.
    for s in pkgs.iter().take(limit.saturating_sub(hits.len())) {
        super::pkg::find_block(&mut out, s);
    }
    let total = hits.len() + pkgs.len();
    if total > limit {
        let _ = writeln!(out, "… {} more match(es) ({limit} of {total} shown, most important first); narrow with kind= or file_path=; or pass limit={total} to see all", total - limit);
    }
    out.push_str(history.trim_start_matches('\n'));
    Ok(out)
}

pub fn grep(c: &Ctx) -> ToolResult {
    let query = c.args.str(&["query", "pattern"]).ok_or_else(|| ToolError::bad("grep requires `query` (alias: pattern)"))?;
    let kind = c.kind()?;
    let regex = c.args.flag(&["regex"], false);
    let limit = c.args.num(&["limit"]).unwrap_or(LIST_LIMIT);
    if c.args.flag(&["search_bodies"], false) {
        return grep_bodies(c, &query, regex, limit);
    }
    // A sentence is a ranked search by words: no symbol name has a space in it. Its own default
    // row count (`ranked::DEFAULT_RANKED_LIMIT`) applies unless `limit` is given.
    if c.args.flag(&["rank"], false) || (!regex && query.trim().contains(char::is_whitespace)) {
        return super::ranked::grep(c, &query, kind, c.args.num(&["limit"]));
    }
    // A symbol-name search: `Foo` and `Foo*` both mean "names starting with Foo", so a file path
    // that merely contains the text never matches.
    let re = if regex { compile_regex(&query)? } else { compile_regex(&format!("^{}", regex::escape(query.trim_end_matches('*'))))? };
    let views = c.views();
    let mut hits = views.find_symbols(&NameMatch::Regex(re), kind);
    // Ranked before the cut: the files the codebase leans on most (PageRank) first, then name,
    // path and line. Alphabetical order put the first gold mention a median 24-37% down a cut
    // list; this order lifted File@10 by 1.3 (tessera) and 4.7 (flight-deck) points in the eval.
    // Putting exact-name matches first cost 1.4 points on tessera, where an Elm `view` or `Model`
    // is defined in hundreds of modules, so `find` stays the tool for an exact name. A `near` seed
    // set reorders on top of this (its sort is stable), nearest first.
    let file_rank = |h: &SymbolHit| views.graph(h.view).file_rank.get(h.id.file as usize).copied().unwrap_or(0.0);
    hits.sort_by(|a, b| {
        file_rank(b)
            .partial_cmp(&file_rank(a))
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            .then(a.path.cmp(&b.path))
            .then(a.start_line.cmp(&b.start_line))
    });
    let history = super::history::section(c, &query, hits.is_empty());
    if hits.is_empty() {
        let mut out = match (!regex).then(|| super::ranked::prefix_fallback(c, &query, kind)).flatten() {
            Some(rows) => rows,
            None => format!("No symbols match `{query}`"),
        };
        out.push_str(&history);
        return Ok(c.fit(out));
    }
    // With a seed set, nearest first; equally near rows stay alphabetical (the sort is stable).
    let near = Near::of(c);
    if let Some(n) = &near {
        n.sort_hits(c.graph, &mut hits);
    }
    let full = detail_full(c, hits.len().min(limit), GREP_FULL_UP_TO)?;
    let mut f = Fit::new();
    f.line(format!("Found {} result(s) for `{query}`:", hits.len()));
    if let Some(n) = &near {
        f.line(n.note());
    }
    let s = f.section(hits.len(), "", "kind=, a longer prefix, or regex=true", Some("limit"), "");
    for h in hits.iter().take(limit) {
        let tag = views.tag(h.view).map(|t| format!("  [view: {t}]")).unwrap_or_default();
        let mut row = format!("{:<30} {:<12} {} {}  {}{tag}", h.name, h.kind.as_str(), h.path.display(), range(h), status(h));
        if full && let Some(sig) = &h.signature {
            row.push_str(&format!("\n    {}", one_line(sig)));
        }
        f.row(s, row);
    }
    f.footer(s);
    for l in history.trim_start_matches('\n').lines() {
        f.line(l);
    }
    Ok(f.render(c.token_budget))
}

/// `search_bodies`: lines of function bodies containing the query, reported against the function
/// they sit in. Bodies are read from the worktree (the view's own disk), not stored: reading the
/// ~2000 source files of a large repository takes well under a second from the page cache, and a
/// persisted body index would be one more thing to invalidate per edit.
fn grep_bodies(c: &Ctx, query: &str, regex: bool, limit: usize) -> ToolResult {
    use rayon::prelude::*;
    let re = if regex { compile_regex(query)? } else { compile_regex(&regex::escape(query))? };
    let kind = c.kind()?;
    let graph = c.graph;
    let files: Vec<u32> = (0..graph.files.len() as u32).filter(|i| graph.file(*i).alive).collect();
    let mut found: Vec<(String, SymbolKind, std::path::PathBuf, u32, String, f64)> = files
        .par_iter()
        .flat_map_iter(|&fi| {
            let node = graph.file(fi);
            let bodies: Vec<_> = node.facts.symbols.iter().filter(|s| is_body(s.kind) && kind.is_none_or(|k| s.kind == k)).collect();
            if bodies.is_empty() {
                return Vec::new().into_iter();
            }
            let Ok(text) = std::fs::read_to_string(graph.abs(fi)) else { return Vec::new().into_iter() };
            let mut rows = Vec::new();
            for (n, line) in text.lines().enumerate() {
                let line_no = n as u32 + 1;
                if !re.is_match(line) {
                    continue;
                }
                // The innermost body containing the line.
                let owner = bodies.iter().filter(|s| s.start_line <= line_no && line_no <= s.end_line).min_by_key(|s| s.end_line - s.start_line);
                if let Some(s) = owner {
                    rows.push((s.name.clone(), s.kind, graph.abs(fi), line_no, line.trim().chars().take(160).collect::<String>(), graph.file_rank[fi as usize]));
                }
            }
            rows.into_iter()
        })
        .collect();
    // Files the codebase leans on most first; within a file, in line order.
    found.sort_by(|a, b| b.5.partial_cmp(&a.5).unwrap_or(std::cmp::Ordering::Equal).then(a.2.cmp(&b.2)).then(a.3.cmp(&b.3)));
    if found.is_empty() {
        return Ok(format!("No function body matches `{query}`"));
    }
    let mut f = Fit::new();
    f.line(format!("Found {} body match(es) for `{query}`:", found.len()));
    let s = f.section(found.len(), "", "a longer query, kind=, or regex=true", Some("limit"), "");
    for (name, kind, path, line, text, _) in found.iter().take(limit) {
        f.row(s, format!("{}:L{} in {} ({}): {}", path.display(), line, name, kind.as_str(), text));
    }
    f.footer(s);
    Ok(f.render(c.token_budget))
}

pub(super) fn is_body(k: SymbolKind) -> bool {
    matches!(k, SymbolKind::Function | SymbolKind::Method | SymbolKind::Constructor | SymbolKind::Macro | SymbolKind::Const)
}

pub fn read(c: &Ctx) -> ToolResult {
    // Each name may be an id (`path:Type.name`) carrying its own file.
    let mut names: Vec<String> = c.args.list(&["symbols"]);
    if let Some(n) = c.args.str(super::args::SYMBOL) {
        names.insert(0, n);
    }
    let max_bytes = c.args.num(&["max_bytes"]).unwrap_or(DEFAULT_MAX_BYTES);
    // `with`: what to attach to each definition. Opt-in, because retrieved context is not always
    // worth its tokens.
    let mut with_callers = false;
    for w in c.args.list(&["with"]) {
        match w.as_str() {
            "callers" => with_callers = true,
            other => return Err(ToolError::bad(format!("unknown `with` value '{other}': use callers"))),
        }
    }
    if with_callers && names.is_empty() {
        return Err(ToolError::bad("with=callers needs symbol_name (or symbols): a line range has no callers"));
    }
    let body = if names.is_empty() { read_range(c)? } else { read_symbols(c, &names, with_callers)? };
    Ok(cap_bytes(body, max_bytes))
}

/// Cut at `max_bytes`, at a line, and say where to read on: the next line, and, inside a symbol's
/// source, that symbol's range, so the agent can page through a long definition.
fn cap_bytes(text: String, max: usize) -> String {
    if text.len() <= max {
        return text;
    }
    let mut cut = max;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    let cut = text[..cut].rfind('\n').unwrap_or(cut);
    let kept = &text[..cut];
    let last_line = kept.lines().rev().find_map(|l| l.split_once(" | ").and_then(|(n, _)| n.trim().parse::<usize>().ok()));
    // The last `// name kind @ path:Ls-Le` heading above the cut, if the cut is inside a symbol.
    let within = kept.lines().rev().find(|l| l.starts_with("// ")).and_then(|h| {
        let (what, at) = h.strip_prefix("// ")?.split_once(" @ ")?;
        let name = what.split(' ').next()?;
        let (path, lines) = at.split(" (view: ").next()?.rsplit_once(":L")?;
        let (a, b) = lines.split_once('-')?;
        Some((name.to_string(), path.to_string(), a.parse::<usize>().ok()?, b.trim().parse::<usize>().ok()?))
    });
    let next = match (within, last_line) {
        (Some((name, path, a, b)), Some(n)) if n < b => {
            format!("inside {name} [L{a}-L{b}]: pass file_path={path} start_line={} end_line={b} to read on", n + 1)
        }
        (_, Some(n)) => format!("pass start_line={} (or limit=) to read on", n + 1),
        _ => "pass start_line / limit to read on".to_string(),
    };
    format!("{kept}\n… truncated at max_bytes={max} {next}, or raise max_bytes")
}

fn numbered(out: &mut String, lines: &[&str], first: usize, width: usize) {
    for (i, l) in lines.iter().enumerate() {
        let _ = writeln!(out, "{:>width$} | {l}", first + i);
    }
}

fn read_symbols(c: &Ctx, names: &[String], with_callers: bool) -> ToolResult {
    let kind = c.kind()?;
    let file = c.args.path(FILE);
    let context = c.args.num(&["context_lines"]).unwrap_or(0);
    let mut out = String::new();
    let views = c.views();
    for raw in names {
        let (name, from_id) = parse_symbol_id(raw, &c.args.cwd);
        let file = file.clone().or(from_id);
        let name = &name;
        let defs: Vec<SymbolHit> = c.definitions(name, kind, file.as_deref());
        if defs.is_empty() {
            let _ = writeln!(out, "// no symbol '{name}' found{}", file.as_ref().map(|f| format!(" in {}", f.display())).unwrap_or_default());
            continue;
        }
        if defs.len() > 1 {
            let ids: Vec<String> = defs.iter().take(MAX_LISTED_IDS).map(symbol_id).collect();
            let more = if defs.len() > MAX_LISTED_IDS { format!(" and {} more", defs.len() - MAX_LISTED_IDS) } else { String::new() };
            let _ = writeln!(out, "// warning: symbol '{name}' has {} definitions: {}{more}. Pass one of these ids as symbol_name, or file_path / kind, to pick one.", defs.len(), ids.join(", "));
        }
        for d in defs.iter().take(MAX_READ_DEFS) {
            let text = std::fs::read_to_string(&d.path).map_err(|e| ToolError::failed(format!("{}: {e}", d.path.display())))?;
            let lines: Vec<&str> = text.lines().collect();
            let start = (d.start_line as usize).saturating_sub(1 + context);
            let end = (d.end_line as usize + context).min(lines.len());
            let tag = views.tag(d.view).map(|t| format!(" (view: {t})")).unwrap_or_default();
            let _ = writeln!(out, "// {} {} @ {}:L{}-{}{tag}", d.name, d.kind.as_str(), d.path.display(), d.start_line, d.end_line);
            // Before the body, so a body cut at max_bytes still leaves its callers on screen.
            if with_callers {
                super::calltree::read_callers(&views, d, &mut out);
            }
            numbered(&mut out, &lines[start..end], start + 1, end.to_string().len());
        }
        if defs.len() > MAX_READ_DEFS {
            let _ = writeln!(out, "// … {} more definition(s) of '{name}' not shown ({MAX_READ_DEFS} of {}); pass an id from the warning above", defs.len() - MAX_READ_DEFS, defs.len());
        }
    }
    Ok(out)
}

const MAX_READ_DEFS: usize = 5;
const MAX_LISTED_IDS: usize = 20;

/// A line range of a file, or all of it. Reads the file from disk: no index is needed, so it works
/// on any file under any path, built or not.
///
/// With only `file_path`, a source file longer than `READ_WHOLE_UP_TO` lines comes back as its outline
/// and its first `READ_WINDOW` lines. Measured on 200 commits each of tessera and flight-deck, a
/// whole-file read shipped 4-5k tokens at the median and cut 23-25% of the later edit sites off at
/// `max_bytes` with no map of the rest; the outline points at every symbol by line range instead.
fn read_range(c: &Ctx) -> ToolResult {
    let path = c.args.path(FILE).ok_or_else(|| ToolError::bad("read requires symbol_name (or symbols) and/or file_path"))?;
    let text = read_text(&path)?;
    let lines: Vec<&str> = text.lines().collect();
    let ranged = c.args.has(&["start_line", "offset", "start", "end_line", "end", "limit"]);
    // Only source files: the measurement covered them, and the outline is what makes the window
    // safe. A long Markdown spec or config file is still read whole.
    if !ranged && !c.args.has(&["max_bytes"]) && lines.len() > READ_WHOLE_UP_TO && crate::lang::for_path(&path).is_some() {
        let outline = c.graph.outline(&path).data;
        return Ok(read_window(&path, &lines, outline.as_deref()));
    }
    let start = c.args.num(&["start_line", "offset", "start"]).unwrap_or(1).max(1);
    let end = match (c.args.num(&["end_line", "end"]), c.args.num(&["limit"])) {
        (Some(e), _) => e,
        (None, Some(l)) => start + l.saturating_sub(1),
        (None, None) => lines.len(),
    }
    .min(lines.len());
    if start > lines.len().max(1) {
        return Err(ToolError::failed(format!("{} has {} lines; start_line {start} is past the end", path.display(), lines.len())));
    }
    let mut out = format!("// {} [L{start}-L{end} of {}]\n", path.display(), lines.len());
    if start <= end {
        numbered(&mut out, &lines[start - 1..end], start, end.to_string().len());
    }
    Ok(out)
}

/// The outline of a long file (when it is indexed) and its first `READ_WINDOW` lines.
pub fn read_window(path: &Path, lines: &[&str], outline: Option<&[crate::query::OutlineEntry]>) -> String {
    let end = READ_WINDOW.min(lines.len());
    let mut out = format!("// {} [L1-L{end} of {}]\n", path.display(), lines.len());
    if let Some(entries) = outline.filter(|e| !e.is_empty()) {
        let page: Vec<&crate::query::OutlineEntry> = entries.iter().take(OUTLINE_PAGE).collect();
        let _ = writeln!(out, "// outline ({} symbols):", entries.len());
        out.push_str(&outline_rows(&page));
        if entries.len() > page.len() {
            let _ = writeln!(out, "// … {} more symbols: outline file_path={} offset={}", entries.len() - page.len(), path.display(), page.len());
        }
    }
    numbered(&mut out, &lines[..end], 1, end.to_string().len());
    let _ = writeln!(
        out,
        "… lines {}-{} not shown: pass symbol_name= (or an id path:Name), start_line/end_line, or limit= to read on; max_bytes= reads the whole file",
        end + 1,
        lines.len()
    );
    out
}

fn read_text(path: &Path) -> std::result::Result<String, ToolError> {
    match std::fs::read(path) {
        Ok(bytes) => String::from_utf8(bytes).map_err(|_| ToolError::failed(format!("{} is not valid UTF-8 text", path.display()))),
        Err(e) => Err(ToolError::failed(format!("{}: {e}", path.display()))),
    }
}

/// A signature's first line, cut at 160 characters: a type alias of a union can be a paragraph.
fn one_line(sig: &str) -> String {
    let line = sig.lines().next().unwrap_or("");
    if line.chars().count() > 160 { format!("{}…", line.chars().take(160).collect::<String>()) } else { line.to_string() }
}

/// Section order and titles of `outline`.
fn group(k: SymbolKind) -> (u8, &'static str) {
    match k {
        SymbolKind::Module => (0, "Modules:"),
        SymbolKind::Struct | SymbolKind::Class | SymbolKind::Enum | SymbolKind::Trait | SymbolKind::Interface | SymbolKind::TypeAlias => (1, "Types:"),
        SymbolKind::Impl => (2, "Impls:"),
        SymbolKind::Constructor => (3, "Constructors:"),
        SymbolKind::Function => (4, "Functions:"),
        SymbolKind::Method => (5, "Methods:"),
        SymbolKind::Port => (6, "Ports:"),
        SymbolKind::Macro => (7, "Macros:"),
        SymbolKind::Const => (8, "Consts:"),
        SymbolKind::Field => (9, "Fields:"),
        SymbolKind::Extension => (10, "Extensions:"),
        SymbolKind::Variable => (11, "Variables:"),
    }
}

/// Outline rows, grouped by section, each indented under its parent.
fn outline_rows(page: &[&crate::query::OutlineEntry]) -> String {
    let mut out = String::new();
    let mut sections: std::collections::BTreeMap<(u8, &str), Vec<&crate::query::OutlineEntry>> = Default::default();
    for e in page {
        sections.entry(group(e.hit.kind)).or_default().push(e);
    }
    for ((_, title), rows) in sections {
        let _ = writeln!(out, "{title}");
        for e in rows {
            let h = &e.hit;
            let sig = h.signature.as_deref().map(|s| format!(" — {}", one_line(s))).unwrap_or_default();
            let _ = writeln!(out, "{}{} {} {}{sig}", "  ".repeat(e.depth as usize), if h.exported { "+" } else { "-" }, h.name, range(h));
        }
    }
    out
}

pub fn outline(c: &Ctx) -> ToolResult {
    let (path, _) = c.file()?;
    let entries = c.graph.outline(&path).data.ok_or_else(|| c.missing(&path))?;
    let offset = c.args.num(&["offset"]).unwrap_or(0);
    let total = entries.len();
    let head = format!("# Outline: {} ({total} symbols)\n", path.display());
    let max = c.token_budget.saturating_mul(4);
    // A page is a run of symbols in source order, so a page the budget shortens still ends at a
    // usable `next_offset`: shrink the page until it fits, rather than cutting its text.
    let mut size = OUTLINE_PAGE.min(total.saturating_sub(offset));
    loop {
        let page: Vec<&crate::query::OutlineEntry> = entries.iter().skip(offset).take(size).collect();
        let mut out = head.clone();
        out.push_str(&outline_rows(&page));
        let next = offset + page.len();
        let cut = size < OUTLINE_PAGE.min(total.saturating_sub(offset));
        if cut {
            let _ = writeln!(out, "… truncated: {} of {total} symbols shown (token_budget={}); next_offset: {next} (of {total}), or raise token_budget", page.len(), c.token_budget);
        } else if next < total {
            let _ = writeln!(out, "next_offset: {next} (of {total})");
        }
        if out.len() <= max || size == 0 {
            return Ok(if size == 0 { c.fit(out) } else { out });
        }
        // Shrink in proportion to the overshoot, at least one symbol a step.
        let fit = (size * max / out.len()).min(size - 1);
        size = fit;
    }
}
