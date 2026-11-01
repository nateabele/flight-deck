//! Tools that locate and show code: `find`, `grep`, `read`, `outline`.

use super::args::{FILE, SYMBOL};
use super::{compile_regex, range, status, Ctx, ToolError, ToolResult};
use crate::facts::SymbolKind;
use crate::near::Near;
use crate::query::{NameMatch, SymbolHit};
use std::fmt::Write;
use std::path::Path;

const DEFAULT_FIND_LIMIT: usize = 100;
const DEFAULT_GREP_LIMIT: usize = 200;
const DEFAULT_MAX_BYTES: usize = 25_000;
const OUTLINE_PAGE: usize = 100;

pub fn find(c: &Ctx) -> ToolResult {
    let name = c.args.str(SYMBOL).ok_or_else(|| ToolError::bad("find requires `name` (aliases: symbol, symbol_name)"))?;
    let kind = c.kind()?;
    let regex = c.args.flag(&["regex"], false);
    let limit = c.args.num(&["limit"]).unwrap_or(DEFAULT_FIND_LIMIT);
    let matcher = if regex { NameMatch::Regex(compile_regex(&name)?) } else { NameMatch::Exact(name.clone()) };
    let views = c.views();
    let mut hits = views.find_symbols(&matcher, kind);
    let pkgs: Vec<_> = if regex { Vec::new() } else { super::pkg::candidates(c, &name, hits.len()) }
        .into_iter()
        .filter(|s| kind.is_none_or(|k| k.as_str() == s.kind.as_str()))
        .collect();
    let history = super::history::section(c, &name, hits.is_empty() && pkgs.is_empty());
    if hits.is_empty() && pkgs.is_empty() {
        return Ok(format!("No symbol found with name '{name}'\nTry `grep query={name}*` for prefix search, or pass regex=true for a pattern match.{history}"));
    }
    let near = Near::of(c);
    if let Some(n) = &near {
        n.sort_hits(c.graph, &mut hits);
    }
    let mut out = format!("Found {} match(es) for '{name}':\n", hits.len() + pkgs.len());
    if let Some(n) = &near {
        let _ = writeln!(out, "{}", n.note());
    }
    for h in hits.iter().take(limit) {
        let _ = writeln!(out, "{} ({})", h.name, h.kind.as_str());
        let _ = writeln!(out, "File: {} {}", h.path.display(), range(h));
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
        let _ = writeln!(out, "… {} more match(es); pass limit={total} to see all", total - limit);
    }
    out.push_str(history.trim_start_matches('\n'));
    Ok(out)
}

pub fn grep(c: &Ctx) -> ToolResult {
    let query = c.args.str(&["query", "pattern"]).ok_or_else(|| ToolError::bad("grep requires `query` (alias: pattern)"))?;
    let kind = c.kind()?;
    let regex = c.args.flag(&["regex"], false);
    let limit = c.args.num(&["limit"]).unwrap_or(DEFAULT_GREP_LIMIT);
    if c.args.flag(&["search_bodies"], false) {
        return grep_bodies(c, &query, regex, limit);
    }
    // A symbol-name search: `Foo` and `Foo*` both mean "names starting with Foo", so a file path
    // that merely contains the text never matches.
    let re = if regex { compile_regex(&query)? } else { compile_regex(&format!("^{}", regex::escape(query.trim_end_matches('*'))))? };
    let views = c.views();
    let mut hits = views.find_symbols(&NameMatch::Regex(re), kind);
    hits.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()).then(a.path.cmp(&b.path)).then(a.start_line.cmp(&b.start_line)));
    let history = super::history::section(c, &query, hits.is_empty());
    if hits.is_empty() {
        return Ok(c.fit(format!("No symbols match `{query}`{history}")));
    }
    // With a seed set, nearest first; equally near rows stay alphabetical (the sort is stable).
    let near = Near::of(c);
    if let Some(n) = &near {
        n.sort_hits(c.graph, &mut hits);
    }
    let mut out = format!("Found {} result(s) for `{query}`:\n", hits.len());
    if let Some(n) = &near {
        let _ = writeln!(out, "{}", n.note());
    }
    for h in hits.iter().take(limit) {
        let tag = views.tag(h.view).map(|t| format!("  [view: {t}]")).unwrap_or_default();
        let _ = writeln!(out, "{:<30} {:<12} {} {}  {}{tag}", h.name, h.kind.as_str(), h.path.display(), range(h), status(h));
    }
    if hits.len() > limit {
        let _ = writeln!(out, "… {} more; pass limit={} to see all", hits.len() - limit, hits.len());
    }
    out.push_str(history.trim_start_matches('\n'));
    Ok(c.fit(out))
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
    let mut found: Vec<(String, SymbolKind, std::path::PathBuf, u32, String)> = files
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
                    rows.push((s.name.clone(), s.kind, graph.abs(fi), line_no, line.trim().chars().take(160).collect::<String>()));
                }
            }
            rows.into_iter()
        })
        .collect();
    found.sort_by(|a, b| a.2.cmp(&b.2).then(a.3.cmp(&b.3)));
    if found.is_empty() {
        return Ok(format!("No function body matches `{query}`"));
    }
    let mut out = format!("Found {} body match(es) for `{query}`:\n", found.len());
    for (name, kind, path, line, text) in found.iter().take(limit) {
        let _ = writeln!(out, "{}:L{} in {} ({}): {}", path.display(), line, name, kind.as_str(), text);
    }
    if found.len() > limit {
        let _ = writeln!(out, "… {} more; pass limit={} to see all", found.len() - limit, found.len());
    }
    Ok(c.fit(out))
}

fn is_body(k: SymbolKind) -> bool {
    matches!(k, SymbolKind::Function | SymbolKind::Method | SymbolKind::Constructor | SymbolKind::Macro | SymbolKind::Const)
}

pub fn read(c: &Ctx) -> ToolResult {
    let mut names = c.args.list(&["symbols"]);
    if let Some(n) = c.args.str(SYMBOL) {
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

fn cap_bytes(text: String, max: usize) -> String {
    if text.len() <= max {
        return text;
    }
    let mut cut = max;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    let cut = text[..cut].rfind('\n').unwrap_or(cut);
    format!("{}\n… truncated at max_bytes={max}; pass start_line / limit to read on, or raise max_bytes", &text[..cut])
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
    for name in names {
        let defs: Vec<SymbolHit> = c.definitions(name, kind, file.as_deref());
        if defs.is_empty() {
            let _ = writeln!(out, "// no symbol '{name}' found{}", file.as_ref().map(|f| format!(" in {}", f.display())).unwrap_or_default());
            continue;
        }
        let files: std::collections::BTreeSet<String> = defs.iter().map(|d| d.path.display().to_string()).collect();
        if files.len() > 1 {
            let _ = writeln!(out, "// warning: symbol '{name}' defined in {} files: {}. Pass file_path=<one-of> to disambiguate.", files.len(), files.into_iter().collect::<Vec<_>>().join(", "));
        }
        for d in defs.iter().take(5) {
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
    }
    Ok(out)
}

/// A line range of a file, or all of it. Reads the file from disk: no index is needed, so it works
/// on any file under any path, built or not.
fn read_range(c: &Ctx) -> ToolResult {
    let path = c.args.path(FILE).ok_or_else(|| ToolError::bad("read requires symbol_name (or symbols) and/or file_path"))?;
    let text = read_text(&path)?;
    let lines: Vec<&str> = text.lines().collect();
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

pub fn outline(c: &Ctx) -> ToolResult {
    let (path, _) = c.file()?;
    let entries = c.graph.outline(&path).data.ok_or_else(|| c.missing(&path))?;
    let offset = c.args.num(&["offset"]).unwrap_or(0);
    let total = entries.len();
    let page: Vec<_> = entries.iter().skip(offset).take(OUTLINE_PAGE).collect();
    let mut out = format!("# Outline: {} ({total} symbols)\n", path.display());
    let mut sections: std::collections::BTreeMap<(u8, &str), Vec<&crate::query::OutlineEntry>> = Default::default();
    for e in &page {
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
    if offset + page.len() < total {
        let _ = writeln!(out, "next_offset: {} (of {total})", offset + page.len());
    }
    Ok(c.fit(out))
}
