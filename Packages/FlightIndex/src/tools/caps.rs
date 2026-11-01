//! Capped, ranked lists and readable symbol ids, shared by the list tools.
//!
//! A list tool ranks its rows first and then cuts. Whatever cut it (the tool's own `limit`, a
//! fixed row cap, or the `token_budget`), the list ends with one footer line that says how many
//! rows are hidden and how to narrow the question, so nothing is ever dropped without a word.
//! The plain `truncate` cuts text at a line and its footer can only say "raise token_budget";
//! `Fit` cuts at whole rows and reserves room for each list's own footer before it fills.
//!
//! A symbol id is `path:Name` or `path:Type.name`: the file the definition is in and its name,
//! qualified by the enclosing type when it has one. `find` prints ids and every tool that takes a
//! symbol accepts one, so the agent can pass an answer straight to the next tool.

use super::args::resolve_path;
use super::is_test_path;
use crate::query::SymbolHit;
use std::cmp::Ordering;
use std::path::{Path, PathBuf};

/// Default row cap of the list tools that have a `limit` (`grep`, `find`, `calls`).
pub const LIST_LIMIT: usize = 50;

struct Section {
    total: usize,
    unit: &'static str,
    hint: String,
    /// The tool's parameter that would show every row, when it has one.
    limit_param: Option<&'static str>,
    indent: &'static str,
    shown: usize,
}

enum Part {
    Fixed(String),
    Title(usize, Box<dyn Fn(usize, usize) -> String>),
    /// A row of a section, counting `items` toward its total: a file heading over its references
    /// counts 0, so it is kept only together with its first reference.
    Row { sec: usize, text: String, items: usize },
    Footer(usize),
}

/// A result made of fixed lines and ranked sections, cut at whole rows to a token budget.
#[derive(Default)]
pub struct Fit {
    parts: Vec<Part>,
    sections: Vec<Section>,
}

impl Fit {
    pub fn new() -> Fit {
        Fit::default()
    }

    /// A line that is always kept.
    pub fn line(&mut self, text: impl Into<String>) {
        self.parts.push(Part::Fixed(text.into()));
    }

    /// A ranked list of `total` rows (more than the rows given when a cap already dropped some).
    /// `hint` names the arguments that narrow it; `limit_param` the one that would show all.
    pub fn section(&mut self, total: usize, unit: &'static str, hint: impl Into<String>, limit_param: Option<&'static str>, indent: &'static str) -> usize {
        self.sections.push(Section { total, unit, hint: hint.into(), limit_param, indent, shown: 0 });
        self.sections.len() - 1
    }

    /// A heading that names the section's counts, rendered once the cut is known.
    pub fn title(&mut self, sec: usize, f: impl Fn(usize, usize) -> String + 'static) {
        self.parts.push(Part::Title(sec, Box::new(f)));
    }

    pub fn row(&mut self, sec: usize, text: impl Into<String>) {
        self.parts.push(Part::Row { sec, text: text.into(), items: 1 });
    }

    /// A row that only groups the rows after it (a file over its references).
    pub fn group(&mut self, sec: usize, text: impl Into<String>) {
        self.parts.push(Part::Row { sec, text: text.into(), items: 0 });
    }

    /// Where the section's "… N more" line goes, if any rows end up hidden.
    pub fn footer(&mut self, sec: usize) {
        self.parts.push(Part::Footer(sec));
    }

    fn footer_text(s: &Section, shown: usize, budget: Option<usize>) -> String {
        let more = s.total.saturating_sub(shown);
        let mut t = format!("{}… {more} more {}({shown} of {} shown", s.indent, if s.unit.is_empty() { String::new() } else { format!("{} ", s.unit) }, s.total);
        if let Some(b) = budget {
            t.push_str(&format!(", token_budget={b}"));
        }
        t.push(')');
        if !s.hint.is_empty() {
            t.push_str(&format!("; narrow with {}", s.hint));
        }
        match (budget, s.limit_param) {
            (Some(_), _) => t.push_str("; or raise token_budget"),
            (None, Some(p)) => t.push_str(&format!("; or pass {p}={} to see all", s.total)),
            (None, None) => {}
        }
        t
    }

    /// Render within `token_budget` (four characters a token). Rows are kept in order until the
    /// first that does not fit; room for every footer that could appear is set aside first.
    pub fn render(mut self, token_budget: usize) -> String {
        let max = token_budget.saturating_mul(4);
        let line_len = |s: &str| s.len() + 1;
        let mut fixed = 0usize;
        for p in &self.parts {
            fixed += match p {
                Part::Fixed(t) => line_len(t),
                Part::Title(s, f) => line_len(&f(self.sections[*s].total, self.sections[*s].total)),
                Part::Footer(s) => line_len(&Self::footer_text(&self.sections[*s], self.sections[*s].total, Some(token_budget))),
                Part::Row { .. } => 0,
            };
        }
        // Everything fits as it is: only the footers of lists a cap already shortened appear.
        let rows: usize = self.parts.iter().map(|p| if let Part::Row { text, .. } = p { line_len(text) } else { 0 }).sum();
        let given: Vec<usize> = (0..self.sections.len())
            .map(|s| self.parts.iter().map(|p| if let Part::Row { sec, items, .. } = p { if *sec == s { *items } else { 0 } } else { 0 }).sum())
            .collect();
        let whole: usize = self
            .parts
            .iter()
            .map(|p| match p {
                Part::Fixed(t) => line_len(t),
                Part::Title(s, f) => line_len(&f(given[*s], self.sections[*s].total)),
                Part::Footer(s) if given[*s] < self.sections[*s].total => line_len(&Self::footer_text(&self.sections[*s], given[*s], None)),
                _ => 0,
            })
            .sum::<usize>()
            + rows;
        let mut room = if whole <= max { usize::MAX } else { max.saturating_sub(fixed) };
        let mut keep = vec![false; self.parts.len()];
        let mut cut = false;
        let mut i = 0;
        while i < self.parts.len() {
            if let Part::Row { text, items, .. } = &self.parts[i] {
                // A grouping row needs its first row beside it.
                let need = line_len(text)
                    + if *items == 0 {
                        match self.parts.get(i + 1) {
                            Some(Part::Row { text: next, items: 1, .. }) => line_len(next),
                            _ => 0,
                        }
                    } else {
                        0
                    };
                if !cut && need <= room {
                    room -= line_len(text);
                    keep[i] = true;
                } else {
                    cut = true;
                }
            }
            i += 1;
        }
        let mut cut_secs = vec![false; self.sections.len()];
        for (p, k) in self.parts.iter().zip(&keep) {
            if let Part::Row { sec, items, .. } = p {
                if *k {
                    self.sections[*sec].shown += items;
                } else {
                    cut_secs[*sec] = true;
                }
            }
        }
        let mut out = String::new();
        for (p, k) in self.parts.iter().zip(&keep) {
            match p {
                Part::Fixed(t) => {
                    out.push_str(t);
                    out.push('\n');
                }
                Part::Title(s, f) => {
                    out.push_str(&f(self.sections[*s].shown, self.sections[*s].total));
                    out.push('\n');
                }
                Part::Row { text, .. } if *k => {
                    out.push_str(text);
                    out.push('\n');
                }
                Part::Row { .. } => {}
                Part::Footer(s) => {
                    let sec = &self.sections[*s];
                    if sec.shown < sec.total {
                        out.push_str(&Self::footer_text(sec, sec.shown, cut_secs[*s].then_some(token_budget)));
                        out.push('\n');
                    }
                }
            }
        }
        // The fixed lines alone can exceed a tiny budget: fall back to the plain cut.
        super::truncate(out, token_budget)
    }
}

/// `"(12 of 80)"` when a cut hid rows, `"(80)"` when it did not.
pub fn counts(shown: usize, total: usize) -> String {
    if shown < total { format!("({shown} of {total})") } else { format!("({total})") }
}

/// Directory proximity of `path` to `anchor`: the leading directories they share, less half a
/// point for a test file. Higher is nearer. Measured on tessera and flight-deck history, ordering
/// `impact`'s capped lists by it keeps 75-78% of the files later co-edited with the anchor inside
/// the 30-row caps, against 65-67% for PageRank alone.
pub fn proximity(anchor: &Path, path: &Path) -> f64 {
    let a = anchor.parent().unwrap_or(anchor).components();
    let p = path.parent().unwrap_or(path).components();
    let shared = a.zip(p).take_while(|(x, y)| x == y).count() as f64;
    let test = if is_test_path(&path.to_string_lossy()) { 0.5 } else { 0.0 };
    shared - test
}

/// The ranked order of a capped file list: nearest to `anchor` first, then higher PageRank, then
/// shallower, then path. PageRank before depth kept 75.1% / 77.5% of co-edited files inside
/// `impact`'s caps (tessera / flight-deck); depth before PageRank kept 74.4% / 79.3%.
pub fn by_proximity(anchor: &Path, a: (&Path, u32, f64), b: (&Path, u32, f64)) -> Ordering {
    proximity(anchor, b.0)
        .partial_cmp(&proximity(anchor, a.0))
        .unwrap_or(Ordering::Equal)
        .then(b.2.partial_cmp(&a.2).unwrap_or(Ordering::Equal))
        .then(a.1.cmp(&b.1))
        .then(a.0.cmp(b.0))
}

/// `path:Type.name`: the id `find` prints and every symbol argument accepts.
pub fn symbol_id(h: &SymbolHit) -> String {
    match &h.parent {
        Some(p) => format!("{}:{p}.{}", h.path.display(), h.name),
        None => format!("{}:{}", h.path.display(), h.name),
    }
}

/// Split a symbol argument into `(name, file)` when it is an id (`path:Name`, `path:Type.name`).
/// The path part must look like a file (a `/` or an extension), and `::` is a qualifier
/// (`store::open`), never the separator. A relative path is read against `cwd`.
pub fn parse_symbol_id(raw: &str, cwd: &Path) -> (String, Option<PathBuf>) {
    let bytes = raw.as_bytes();
    let sep = (0..bytes.len()).rev().find(|&i| bytes[i] == b':' && (i == 0 || bytes[i - 1] != b':') && bytes.get(i + 1) != Some(&b':'));
    if let Some(i) = sep {
        let (path, name) = (&raw[..i], &raw[i + 1..]);
        let file_like = path.contains('/') || Path::new(path).extension().is_some();
        if !path.is_empty() && !name.is_empty() && file_like {
            return (name.to_string(), Some(resolve_path(cwd, path)));
        }
    }
    (raw.to_string(), None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_split_at_the_last_single_colon_of_a_file_like_path() {
        let cwd = Path::new("/nonexistent-cwd");
        assert_eq!(parse_symbol_id("/x/a.rs:Store.open", cwd), ("Store.open".into(), Some(PathBuf::from("/x/a.rs"))));
        assert_eq!(parse_symbol_id("src/a.ts:open", cwd), ("open".into(), Some(PathBuf::from("/nonexistent-cwd/src/a.ts"))));
        assert_eq!(parse_symbol_id("store::open", cwd), ("store::open".into(), None));
        assert_eq!(parse_symbol_id("/x/a.rs:store::open", cwd), ("store::open".into(), Some(PathBuf::from("/x/a.rs"))));
        assert_eq!(parse_symbol_id("Expression.Node.toString", cwd), ("Expression.Node.toString".into(), None));
        assert_eq!(parse_symbol_id("Foo:bar", cwd), ("Foo:bar".into(), None));
    }

    #[test]
    fn a_budget_cut_keeps_whole_rows_and_the_footer() {
        let mut f = Fit::new();
        f.line("head");
        let s = f.section(100, "rows", "kind=", Some("limit"), "");
        f.title(s, |n, t| format!("Rows {}:", counts(n, t)));
        for i in 0..100 {
            f.row(s, format!("row {i:03} with some padding text"));
        }
        f.footer(s);
        let out = f.render(100);
        let last = out.lines().last().unwrap();
        assert!(last.contains("of 100 shown, token_budget=100") && last.contains("narrow with kind=") && last.ends_with("raise token_budget"), "{out}");
        assert!(out.len() <= 400, "{}", out.len());
        assert!(out.lines().nth(1).unwrap().starts_with("Rows (") && out.lines().nth(1).unwrap().contains("of 100)"), "{out}");
        // Uncut but capped by a limit: the footer offers the limit.
        let mut f = Fit::new();
        let s = f.section(10, "", "kind=", Some("limit"), "");
        f.row(s, "one");
        f.footer(s);
        assert_eq!(f.render(4000), "one\n… 9 more (1 of 10 shown); narrow with kind=; or pass limit=10 to see all\n");
    }

    #[test]
    fn a_group_row_is_never_left_without_its_first_row() {
        let mut f = Fit::new();
        let s = f.section(2, "references", "", None, "");
        f.group(s, "a".repeat(10));
        f.row(s, "b".repeat(10));
        f.group(s, "c".repeat(10));
        f.row(s, "d".repeat(200));
        f.footer(s);
        let out = f.render(40);
        assert!(out.contains("aaaa") && out.contains("bbbb") && !out.contains("cccc"), "{out}");
    }

    #[test]
    fn nearer_directories_rank_first_and_tests_drop_half_a_point() {
        let a = Path::new("/r/lib/core/x.ts");
        assert!(proximity(a, Path::new("/r/lib/core/y.ts")) > proximity(a, Path::new("/r/lib/z.ts")));
        assert!(proximity(a, Path::new("/r/lib/core/y.test.ts")) < proximity(a, Path::new("/r/lib/core/y.ts")));
    }
}
