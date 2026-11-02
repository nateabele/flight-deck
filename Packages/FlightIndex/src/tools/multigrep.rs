//! `grep search_bodies=true worktrees=…`: one body search over many worktrees of a repository.
//!
//! The worktrees of one repository hold mostly the same files. Measured on the 85 tessera
//! worktrees: 198,902 indexed files are 9,481 distinct blobs (21x on files, 12x on bytes). The
//! single-view search reads every file of its view from disk, so asking it once per worktree reads
//! the same content 21 times over; most of its cost is opening and reading files, not matching
//! (the regex over all 210 MB of distinct content takes 3-5 ms once it is in memory). Here each
//! distinct blob is read once, from one worktree whose file is that blob, and its hits are fanned
//! out to every `(worktree, path)` holding it. Measured in a prototype on the same files: 73 ms
//! instead of 2.3 s for all 86 worktrees, 49 ms instead of 175 ms for 10.
//!
//! Nothing here builds a graph. The body rule (a line counts when it falls in a function-like
//! body, reported against the innermost one) needs only each blob's own symbols, which the store
//! holds per blob; a resolved `ViewGraph` per worktree would charge the graph cache 3.5 GB for an
//! all-worktree search of tessera and buy nothing.
//!
//! Which worktree, path and blob are current is the caller's job (`service::multi`); this module
//! takes the effective file lists as given and does the reading, matching and grouping.
//!
//! With the trigram index (`crate::trigram`) the caller also passes the candidate ordinals and
//! each base tree's ordinals: an indexed blob outside the candidates is dropped before the blob
//! table is even built, so neither its bytes nor its 40-character id are touched.

use super::nav::is_body;
use super::ToolError;
use crate::facts::{Symbol, SymbolKind};
use crate::git::{self, FileRef, Overlay, MAX_FILE_BYTES};
use crate::trigram::{TreeOrdinals, NOT_INDEXED};
use roaring::RoaringBitmap;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// One worktree's files as the search sees them: its base tree with its overlay applied.
pub struct Worktree {
    pub root: PathBuf,
    pub label: String,
    pub base: Arc<Vec<FileRef>>,
    pub overlay: Vec<Overlay>,
    /// The trigram index's ordinal of each `base` file, when the search has an index.
    pub ords: Option<Arc<TreeOrdinals>>,
}

impl Worktree {
    /// Every effective file: its trigram ordinal (`NOT_INDEXED` for overlay files and blobs the
    /// index lacks), and whether it came from the overlay (working-tree content that may not be in
    /// git's object store).
    fn files(&self) -> impl Iterator<Item = (u32, &FileRef, bool)> {
        let shadowed: HashSet<&str> = self.overlay.iter().map(|o| o.path()).collect();
        let ords = self.ords.as_ref().filter(|o| o.ords.len() == self.base.len());
        let base = self
            .base
            .iter()
            .enumerate()
            .filter(move |(_, f)| !shadowed.contains(f.path.as_str()))
            .map(move |(i, f)| (ords.map(|o| o.ords[i]).unwrap_or(NOT_INDEXED), f, false));
        let over = self.overlay.iter().filter_map(|o| match o {
            Overlay::Present(f) => Some((NOT_INDEXED, f, true)),
            Overlay::Deleted(_) => None,
        });
        base.chain(over)
    }
}

/// One line inside a body.
pub struct Hit {
    pub line: u32,
    pub name: String,
    pub kind: SymbolKind,
    pub text: String,
}

/// The hits of one blob at one path, and every worktree (index into the input) that holds it there.
pub struct Group {
    pub path: String,
    pub worktrees: Vec<usize>,
    pub hits: Vec<Hit>,
}

#[derive(Default)]
pub struct Outcome {
    pub groups: Vec<Group>,
    /// Distinct blobs scanned.
    pub blobs: usize,
    /// Distinct indexed blobs the trigram index ruled out: never read.
    pub ruled_out: u64,
    /// Committed blobs (of a base tree, so in git's object store) the trigram index lacks: what
    /// the caller queues for indexing.
    pub not_indexed: Vec<String>,
    /// Blobs no worktree's file matched any more (edited since it was recorded), read from git.
    pub from_git: usize,
    /// Blobs that could be read neither from a worktree nor from git: working-tree content that
    /// has changed again since it was recorded.
    pub unreadable: usize,
    /// Blobs with matching lines but no stored facts, so no body to place them in.
    pub unindexed: usize,
    /// Reading and matching, and then placing the hits in bodies: for the daemon log.
    pub scan_took: std::time::Duration,
    pub facts_took: std::time::Duration,
}

impl Outcome {
    pub fn rows(&self) -> usize {
        self.groups.iter().map(|g| g.hits.len()).sum()
    }
}

/// A body search's pattern, compiled twice: once to find candidate lines in a whole file at a time,
/// once to decide each candidate line on its own exactly as the single-view search does.
struct Matcher {
    buf: regex::bytes::Regex,
    line: regex::Regex,
    /// `\A`, `\z`: anchors whose meaning differs between a file and a line, so the whole-file
    /// prefilter could miss a line. Those patterns are matched line by line throughout.
    per_line: bool,
}

impl Matcher {
    fn new(pattern: &str) -> Result<Matcher, ToolError> {
        let line = super::compile_regex(pattern)?;
        // `multi_line` and `crlf` give `^` and `$` the per-line meaning they have against one line
        // of `str::lines()`, so no line that matches alone is missed by the whole-file search.
        let buf = regex::bytes::RegexBuilder::new(pattern)
            .case_insensitive(true)
            .multi_line(true)
            .crlf(true)
            .build()
            .map_err(|e| ToolError::bad(format!("invalid regex '{pattern}': {e}")))?;
        let per_line = pattern.contains("\\A") || pattern.contains("\\z");
        Ok(Matcher { buf, line, per_line })
    }

    /// `(line number, trimmed text)` of every line of `bytes` that matches on its own: the lines
    /// `str::lines()` would yield, with its line numbers. Non-UTF-8 content yields nothing, as
    /// `read_to_string` does for the single-view search.
    ///
    /// The whole-file regex only proposes spans; each line a match touches is then decided alone.
    /// A pattern such as `a\s+b` can match across a newline in the file but never within one line,
    /// and that span is no hit. Every line that does match alone is reached: the search resumes at
    /// the start of the line after each span, and a match within that line starts no later than its
    /// own text.
    fn scan(&self, bytes: &[u8]) -> Vec<(u32, String)> {
        if !self.per_line && !self.buf.is_match(bytes) {
            return Vec::new();
        }
        let Ok(text) = std::str::from_utf8(bytes) else { return Vec::new() };
        let mut out = Vec::new();
        let keep = |out: &mut Vec<(u32, String)>, n: u32, line: &str| out.push((n, line.trim().chars().take(160).collect()));
        if self.per_line {
            for (i, line) in text.lines().enumerate() {
                if self.line.is_match(line) {
                    keep(&mut out, i as u32 + 1, line);
                }
            }
            return out;
        }
        let (mut pos, mut counted_to, mut line_no) = (0usize, 0usize, 1u32);
        while pos < bytes.len() {
            let Some(m) = self.buf.find_at(bytes, pos) else { break };
            if m.start() >= bytes.len() {
                break;
            }
            let start = bytes[pos..m.start()].iter().rposition(|&b| b == b'\n').map(|i| pos + i + 1).unwrap_or(pos);
            let last = if m.end() > m.start() { m.end() - 1 } else { m.start() };
            let span_end = bytes[last..].iter().position(|&b| b == b'\n').map(|i| last + i).unwrap_or(bytes.len());
            let mut a = start;
            while a <= span_end && a < bytes.len() {
                let b = bytes[a..].iter().position(|&c| c == b'\n').map(|i| a + i).unwrap_or(bytes.len());
                line_no += bytes[counted_to..a].iter().filter(|&&c| c == b'\n').count() as u32;
                counted_to = a;
                // `str::lines()` drops the `\r` of a `\r\n`, never a bare one at the end.
                let line = if b < bytes.len() && b > a && bytes[b - 1] == b'\r' { &text[a..b - 1] } else { &text[a..b] };
                if self.line.is_match(line) {
                    keep(&mut out, line_no, line);
                }
                a = b + 1;
            }
            pos = span_end + 1;
        }
        out
    }
}

/// A blob's stored symbols by `(blob id, language)`; `None` when the store has no facts for it.
pub type SymbolSource<'a> = dyn FnMut(&str, &'static str) -> crate::error::Result<Option<Vec<Symbol>>> + 'a;

/// Search `trees` for `pattern` (already a regex; escape a plain query first). `symbols(blob,
/// language)` gives a blob's stored symbols, `None` when it has no facts; it is asked only about
/// blobs with matching lines, one at a time. `git_dir` is where `git cat-file` finds the
/// repository's objects. `candidates`, from the trigram index, are the ordinals that may hold a
/// match: an indexed blob outside them is skipped unread (`None`: read every blob).
pub fn search(
    trees: &[Worktree],
    pattern: &str,
    kind: Option<SymbolKind>,
    git_dir: &Path,
    candidates: Option<&RoaringBitmap>,
    symbols: &mut SymbolSource,
) -> Result<Outcome, ToolError> {
    use rayon::prelude::*;
    let matcher = Matcher::new(pattern)?;
    let started = std::time::Instant::now();

    // Blob ordinals, and who holds each: (worktree, path, from the overlay).
    let mut ordinal: HashMap<(&str, &'static str), u32> = HashMap::new();
    let mut blobs: Vec<(&str, &'static str)> = Vec::new();
    let mut holders: Vec<Vec<(u32, &str, bool)>> = Vec::new();
    let mut ruled_out = RoaringBitmap::new();
    let mut not_indexed: HashSet<&str> = HashSet::new();
    for (w, t) in trees.iter().enumerate() {
        for (ord, f, over) in t.files() {
            if ord != NOT_INDEXED && candidates.is_some_and(|c| !c.contains(ord)) {
                ruled_out.insert(ord);
                continue;
            }
            if ord == NOT_INDEXED && !over {
                not_indexed.insert(f.blob_id.as_str());
            }
            let o = *ordinal.entry((f.blob_id.as_str(), f.language)).or_insert_with(|| {
                blobs.push((f.blob_id.as_str(), f.language));
                holders.push(Vec::new());
                blobs.len() as u32 - 1
            });
            holders[o as usize].push((w as u32, f.path.as_str(), over));
        }
    }
    drop(ordinal);

    // Each blob read once, from the holder most likely to still be that blob: a committed file in a
    // clean worktree first, an overlay file last. The bytes are hashed, so a file edited since it
    // was recorded is never mistaken for the blob; a few holders are tried, then git.
    const TRIES: usize = 4;
    let scanned: Vec<Option<Vec<(u32, String)>>> = (0..blobs.len())
        .into_par_iter()
        .map(|b| {
            let (id, _) = blobs[b];
            let mut order: Vec<&(u32, &str, bool)> = holders[b].iter().collect();
            order.sort_by_key(|(w, _, over)| (*over, !trees[*w as usize].overlay.is_empty()));
            for (w, path, _) in order.into_iter().take(TRIES) {
                let abs = trees[*w as usize].root.join(path);
                let Ok(meta) = std::fs::symlink_metadata(&abs) else { continue };
                if !meta.is_file() || meta.len() > MAX_FILE_BYTES {
                    continue;
                }
                let Ok(bytes) = std::fs::read(&abs) else { continue };
                if git::blob_id(&bytes) == id {
                    return Some(matcher.scan(&bytes));
                }
            }
            None
        })
        .collect();
    let mut out = Outcome { blobs: blobs.len(), ruled_out: ruled_out.len(), not_indexed: not_indexed.into_iter().map(String::from).collect(), ..Default::default() };
    let mut hits: Vec<(usize, Vec<(u32, String)>)> = Vec::new();
    let mut missing: Vec<usize> = Vec::new();
    for (b, s) in scanned.into_iter().enumerate() {
        match s {
            Some(lines) if !lines.is_empty() => hits.push((b, lines)),
            Some(_) => {}
            None => missing.push(b),
        }
    }
    if !missing.is_empty() {
        let ids: Vec<&str> = missing.iter().map(|&b| blobs[b].0).collect();
        let contents = crate::engine::cat_file_batch(git_dir, &ids)?;
        for (&b, content) in missing.iter().zip(contents) {
            match content {
                Some(bytes) => {
                    out.from_git += 1;
                    let lines = matcher.scan(&bytes);
                    if !lines.is_empty() {
                        hits.push((b, lines));
                    }
                }
                None => out.unreadable += 1,
            }
        }
    }

    out.scan_took = started.elapsed();
    let placing = std::time::Instant::now();
    // The body rule of the single-view search: the innermost function-like body containing the line.
    for (b, lines) in hits {
        let (id, language) = blobs[b];
        let Some(syms) = symbols(id, language)? else {
            out.unindexed += 1;
            continue;
        };
        let bodies: Vec<&Symbol> = syms.iter().filter(|s| is_body(s.kind) && kind.is_none_or(|k| s.kind == k)).collect();
        let kept: Vec<(u32, &Symbol, String)> = lines
            .into_iter()
            .filter_map(|(n, text)| {
                let owner = bodies.iter().filter(|s| s.start_line <= n && n <= s.end_line).min_by_key(|s| s.end_line - s.start_line)?;
                Some((n, *owner, text))
            })
            .collect();
        if kept.is_empty() {
            continue;
        }
        let mut by_path: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
        for (w, path, _) in &holders[b] {
            by_path.entry(path).or_default().push(*w as usize);
        }
        for (path, mut worktrees) in by_path {
            worktrees.sort_unstable();
            worktrees.dedup();
            let hits = kept.iter().map(|(n, s, text)| Hit { line: *n, name: s.name.clone(), kind: s.kind, text: text.clone() }).collect();
            out.groups.push(Group { path: path.to_string(), worktrees, hits });
        }
    }
    out.facts_took = placing.elapsed();
    out.groups.sort_by(|a, b| a.path.cmp(&b.path).then(a.worktrees.cmp(&b.worktrees)));
    Ok(out)
}

/// How many worktree labels a group lists before `+k`: a blob held by 85 worktrees would otherwise
/// spend a line's worth of tokens per group naming them.
const LABELS_SHOWN: usize = 6;

/// The rows, grouped: `[N worktrees: a, b, … +k]` then that group's `path:Lline in name (kind):
/// text` rows. `limit` counts rows (distinct blob, path and line), not worktrees.
pub fn render(trees: &[Worktree], out: &Outcome, query: &str, limit: usize) -> String {
    let rows = out.rows();
    if rows == 0 {
        return format!("No function body matches `{query}`\n");
    }
    let mut text = format!("Found {rows} body match(es) for `{query}` in {} group(s) of worktrees holding the same file:\n", out.groups.len());
    let mut shown = 0usize;
    for g in &out.groups {
        if shown >= limit {
            break;
        }
        let mut names: Vec<&str> = g.worktrees.iter().map(|&w| trees[w].label.as_str()).collect();
        names.sort_unstable();
        names.truncate(LABELS_SHOWN);
        let more = g.worktrees.len().saturating_sub(LABELS_SHOWN);
        let noun = if g.worktrees.len() == 1 { "worktree" } else { "worktrees" };
        let tail = if more > 0 { format!(" +{more}") } else { String::new() };
        let _ = writeln!(text, "[{} {noun}: {}{tail}]", g.worktrees.len(), names.join(", "));
        for h in g.hits.iter().take(limit - shown) {
            let _ = writeln!(text, "{}:L{} in {} ({}): {}", g.path, h.line, h.name, h.kind.as_str(), h.text);
            shown += 1;
        }
    }
    if rows > shown {
        let _ = writeln!(text, "… {} more; pass limit={rows} to see all", rows - shown);
    }
    text
}

/// Labels for worktrees: the directory name, or the whole path where two share a name.
pub fn labels(roots: &[PathBuf]) -> Vec<String> {
    let name = |p: &Path| p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_else(|| p.display().to_string());
    let mut count: HashMap<String, usize> = HashMap::new();
    for r in roots {
        *count.entry(name(r)).or_default() += 1;
    }
    roots.iter().map(|r| if count[&name(r)] > 1 { r.display().to_string() } else { name(r) }).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines_of(pattern: &str, text: &str) -> Vec<(u32, String)> {
        Matcher::new(pattern).unwrap().scan(text.as_bytes())
    }

    /// The reference: what the single-view search does with one file.
    fn per_line(pattern: &str, text: &str) -> Vec<(u32, String)> {
        let re = crate::tools::compile_regex(pattern).unwrap();
        text.lines().enumerate().filter(|(_, l)| re.is_match(l)).map(|(i, l)| (i as u32 + 1, l.trim().chars().take(160).collect())).collect()
    }

    #[test]
    fn whole_file_scan_finds_exactly_the_lines_a_line_by_line_scan_finds() {
        let texts = [
            "fn a() {\n  needle();\n}\n\nfn b() { needle; needle }\n",
            "a\nb ab\r\nNEEDLE\r\n  x\n\nlast needle",
            "",
            "\n\n\n",
            "needle",
            "x\r\ny\r",
        ];
        let patterns = ["needle", r"a\s*b", "^needle$", "^$", "^", r"y\r?$", "x*", r"\Aa", r"b\z", "(?s)a.b", r"\n", "ab|needle"];
        for t in texts {
            for p in patterns {
                assert_eq!(lines_of(p, t), per_line(p, t), "pattern {p:?} on {t:?}");
            }
        }
    }

    #[test]
    fn non_utf8_content_has_no_lines() {
        assert!(Matcher::new("needle").unwrap().scan(b"needle \xff\n").is_empty());
    }

    #[test]
    fn labels_are_directory_names_unless_two_collide() {
        let roots = [PathBuf::from("/a/x"), PathBuf::from("/b/x"), PathBuf::from("/c/y")];
        assert_eq!(labels(&roots), vec!["/a/x".to_string(), "/b/x".to_string(), "y".to_string()]);
    }
}
