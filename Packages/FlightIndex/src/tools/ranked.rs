//! Ranked symbol search by words (`crate::words`): `grep` with a sentence (or `rank=true`), and
//! the fallbacks of a prefix `grep` and an exact `find` that match no name.
//!
//! Exact and prefix hits are never put in front of ranked rows for a sentence: commit-message
//! words that happen to be symbol names are mostly in the wrong files (measured File@10 40 ->
//! 9.5 on tessera when exact hits went first). Names stay first where a name was asked for: a
//! one-word `grep` or `find` that matches is answered as before, and words are only its fallback.

use super::nav::is_body;
use super::{compile_regex, range, status, Ctx, ToolResult};
use crate::facts::SymbolKind;
use crate::query::SymbolHit;
use crate::words::{query_tokens, query_words};
use std::fmt::Write;

/// Rows a ranked `grep` shows unless `limit` says otherwise: the tail of a BM25 list is noise.
pub const DEFAULT_RANKED_LIMIT: usize = 20;
/// Rows a zero-hit fallback appends.
pub const FALLBACK_ROWS: usize = 10;
/// At or below this many matches, each row is followed by its symbol's code.
const FULL_CODE_HITS: usize = 3;
/// Lines of code shown per symbol in that case.
const FULL_CODE_LINES: usize = 80;

/// A symbol row, the same as a prefix `grep` row.
fn row(c: &Ctx, h: &SymbolHit) -> String {
    let tag = c.views().tag(h.view).map(|t| format!("  [view: {t}]")).unwrap_or_default();
    format!("{:<30} {:<12} {} {}  {}{tag}", h.name, h.kind.as_str(), h.path.display(), range(h), status(h))
}

fn code(out: &mut String, h: &SymbolHit) {
    let Ok(text) = std::fs::read_to_string(&h.path) else { return };
    let lines: Vec<&str> = text.lines().collect();
    let start = (h.start_line as usize).saturating_sub(1).min(lines.len());
    let end = (h.end_line as usize).min(lines.len()).max(start);
    let shown = end.min(start + FULL_CODE_LINES);
    let width = shown.to_string().len();
    for (i, l) in lines[start..shown].iter().enumerate() {
        let _ = writeln!(out, "{:>width$} | {l}", start + 1 + i);
    }
    if shown < end {
        let _ = writeln!(out, "… {} more lines; read symbol_name={} for all", end - shown, h.name);
    }
}

/// `grep` when the query is a sentence or `rank=true`. The history tier (`tools::history`) is a
/// separate section after the ranked rows, as it is after a prefix search's.
pub fn grep(c: &Ctx, query: &str, kind: Option<SymbolKind>, limit: Option<usize>) -> ToolResult {
    let words = query_words(query);
    if words.is_empty() {
        let history = super::history::section(c, query, true);
        return Ok(format!("No words to rank in `{query}` (words under three letters and stopwords are skipped){history}"));
    }
    let limit = limit.unwrap_or(DEFAULT_RANKED_LIMIT);
    let (hits, total) = c.views().ranked_by_words(&words, kind, limit);
    let history = super::history::section(c, query, hits.is_empty());
    if hits.is_empty() {
        return Ok(c.fit(match bodies(c, query, kind, limit)? {
            Some(rows) => format!("No symbol has the words {}; function bodies that contain them:\n{rows}{history}", query_tokens(query).join(" ")),
            None => format!("No symbol or function body has the words {}{history}", query_tokens(query).join(" ")),
        }));
    }
    let mut out = format!("Ranked by words: {} ({total} matching symbol(s), best first)\n", words.join(" "));
    for h in &hits {
        let _ = writeln!(out, "{}", row(c, h));
        if total <= FULL_CODE_HITS {
            code(&mut out, h);
        }
    }
    if total > hits.len() {
        let _ = writeln!(out, "… {} more; pass limit=N to see more", total - hits.len());
    }
    out.push_str(&history);
    Ok(c.fit(out))
}

/// The closest symbols by words, as rows under `note`, or `None` when no symbol shares a word.
fn closest(c: &Ctx, name: &str, kind: Option<SymbolKind>, note: impl FnOnce(&[String]) -> String) -> Option<String> {
    let words = query_words(name);
    if words.is_empty() {
        return None;
    }
    let (hits, _) = c.views().ranked_by_words(&words, kind, FALLBACK_ROWS);
    if hits.is_empty() {
        return None;
    }
    let mut out = note(&words);
    out.push('\n');
    for h in &hits {
        let _ = writeln!(out, "{}", row(c, h));
    }
    Some(out)
}

/// A prefix `grep` that matched no name: the closest symbols by words instead.
pub fn prefix_fallback(c: &Ctx, query: &str, kind: Option<SymbolKind>) -> Option<String> {
    let q = query.trim_end_matches('*');
    closest(c, q, kind, |_| format!("No symbol names start with `{q}`; closest by words:"))
}

/// An exact `find` that matched nothing: the closest symbols by words, to append.
pub fn find_fallback(c: &Ctx, name: &str, kind: Option<SymbolKind>) -> Option<String> {
    closest(c, name, kind, |w| format!("Closest by words ({}):", w.join(" ")))
}

/// Function bodies of the answering view that contain any of the query's words, one row per
/// enclosing symbol (its first matching line), most distinct words first. Read from the
/// worktree, as `search_bodies` is.
fn bodies(c: &Ctx, query: &str, kind: Option<SymbolKind>, limit: usize) -> Result<Option<String>, super::ToolError> {
    use rayon::prelude::*;
    let tokens = query_tokens(query);
    if tokens.is_empty() {
        return Ok(None);
    }
    let alternation = tokens.iter().map(|t| regex::escape(t)).collect::<Vec<_>>().join("|");
    let re = compile_regex(&format!("({alternation})"))?;
    let graph = c.graph;
    let files: Vec<u32> = (0..graph.files.len() as u32).filter(|i| graph.file(*i).alive).collect();
    // (distinct words, matching lines, path, first line, name, kind, text)
    let mut found: Vec<(usize, usize, std::path::PathBuf, u32, String, SymbolKind, String)> = files
        .par_iter()
        .flat_map_iter(|&fi| {
            let node = graph.file(fi);
            let owners: Vec<_> = node.facts.symbols.iter().filter(|s| is_body(s.kind) && kind.is_none_or(|k| s.kind == k)).collect();
            if owners.is_empty() {
                return Vec::new().into_iter();
            }
            let Ok(text) = std::fs::read_to_string(graph.abs(fi)) else { return Vec::new().into_iter() };
            // owner index -> (words seen, lines, first line, its text)
            let mut per: std::collections::BTreeMap<usize, (std::collections::HashSet<String>, usize, u32, String)> = Default::default();
            for (n, line) in text.lines().enumerate() {
                let line_no = n as u32 + 1;
                let seen: Vec<String> = re.find_iter(line).map(|m| m.as_str().to_lowercase()).collect();
                if seen.is_empty() {
                    continue;
                }
                let owner = owners.iter().enumerate().filter(|(_, s)| s.start_line <= line_no && line_no <= s.end_line).min_by_key(|(_, s)| s.end_line - s.start_line);
                if let Some((i, _)) = owner {
                    let e = per.entry(i).or_insert_with(|| (Default::default(), 0, line_no, line.trim().chars().take(160).collect()));
                    e.0.extend(seen);
                    e.1 += 1;
                }
            }
            let abs = graph.abs(fi);
            per.into_iter()
                .map(|(i, (words, lines, first, text))| (words.len(), lines, abs.clone(), first, owners[i].name.clone(), owners[i].kind, text))
                .collect::<Vec<_>>()
                .into_iter()
        })
        .collect();
    if found.is_empty() {
        return Ok(None);
    }
    found.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)).then(a.2.cmp(&b.2)).then(a.3.cmp(&b.3)));
    let mut out = String::new();
    for (_, _, path, line, name, kind, text) in found.iter().take(limit) {
        let _ = writeln!(out, "{}:L{} in {} ({}): {}", path.display(), line, name, kind.as_str(), text);
    }
    if found.len() > limit {
        let _ = writeln!(out, "… {} more; pass limit=N to see more", found.len() - limit);
    }
    Ok(Some(out))
}
