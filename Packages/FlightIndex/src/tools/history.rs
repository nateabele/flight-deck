//! The history tier of `find` and `grep`: symbols whose recent commits were described in the
//! query's words (`crate::history`). It runs when the query is prose (has a space) or the name
//! search found nothing, or when `history=true`; `history=false` turns it off.

use super::Ctx;
use crate::history::{qualified_name, HistoryState, Scope};
use std::collections::{HashMap, HashSet};
use std::fmt::Write;

/// Rows the tier shows unless `limit` asks for fewer.
pub const HISTORY_LIMIT: usize = 10;
/// `limit` can raise it this far: past it, the words of a query match noise.
const MAX_LIMIT: usize = 50;
const SUBJECT_CHARS: usize = 100;

/// The section to append to a `find`/`grep` answer: empty, or a block that starts with a newline.
pub fn section(c: &Ctx, query: &str, primary_empty: bool) -> String {
    let asked = c.args.has(&["history"]).then(|| c.args.flag(&["history"], true));
    let regex = c.args.flag(&["regex"], false);
    let wanted = asked.unwrap_or(!regex && (query.trim().contains(char::is_whitespace) || primary_empty));
    if !wanted {
        return String::new();
    }
    let (index, allow) = match (c.history)() {
        HistoryState::Ready { index, allow } => (index, allow),
        HistoryState::Building => return "\nhistory: indexing this repository's commits; retry shortly for matches by commit subject\n".into(),
        HistoryState::Unavailable(why) => return if asked == Some(true) { format!("\nhistory: unavailable ({why})\n") } else { String::new() },
    };
    let limit = c.args.num(&["limit"]).map(|l| l.clamp(1, MAX_LIMIT)).unwrap_or(HISTORY_LIMIT);
    let scope = match &allow {
        Some(set) => Scope::Only(set),
        None => Scope::All,
    };
    let hits = index.search(query, scope, limit * 8);
    let g = c.graph;
    // Map each hit onto the view: a symbol by qualified name in its file, a file by path.
    let mut names: HashMap<u32, Vec<String>> = HashMap::new();
    let mut rows: Vec<(String, Option<u32>, u32)> = Vec::new(); // (path, symbol index, commit)
    for h in &hits {
        let Some(fi) = g.file_idx(std::path::Path::new(&h.path)) else { continue };
        if h.symbol.is_empty() {
            rows.push((h.path.clone(), None, h.commit));
            continue;
        }
        let node = g.file(fi);
        let q = names.entry(fi).or_insert_with(|| node.facts.symbols.iter().map(|s| qualified_name(&node.facts.symbols, s)).collect());
        if let Some(si) = q.iter().position(|n| *n == h.symbol) {
            rows.push((h.path.clone(), Some(si as u32), h.commit));
        }
    }
    // A file's own row where it ranks, unless one of its symbols is already listed above it: the
    // file's document gathers every commit that changed it, so it can outrank each symbol in it.
    let mut listed: HashSet<&str> = HashSet::new();
    let rows: Vec<&(String, Option<u32>, u32)> = rows.iter().filter(|r| listed.insert(r.0.as_str()) || r.1.is_some()).take(limit).collect();
    if rows.is_empty() {
        return format!("\nNo history matches for '{query}' in the last {} commits\n", index.commits.len());
    }
    let mut out = format!("\nHistory matches for '{query}' (by the subjects and changed lines of the last {} commits):\n", index.commits.len());
    for (path, sym, commit) in rows {
        let fi = g.file_idx(std::path::Path::new(path)).expect("mapped above");
        let info = &index.commits[*commit as usize];
        let subject: String = info.subject.chars().take(SUBJECT_CHARS).collect();
        let short: String = info.id.chars().take(7).collect();
        match sym {
            Some(si) => {
                let s = g.file(fi).symbol(*si);
                let _ = writeln!(out, "{:<30} {:<12} {} [L{}-L{}]  — {subject} ({short})", s.name, s.kind.as_str(), g.abs(fi).display(), s.start_line, s.end_line);
            }
            None => {
                let _ = writeln!(out, "{:<30} {:<12} {}  — {subject} ({short})", "(file)", "", g.abs(fi).display());
            }
        }
    }
    out
}
