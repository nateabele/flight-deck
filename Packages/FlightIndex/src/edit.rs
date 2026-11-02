//! The text-editing layer under the mutators: byte-range edits collected against one original,
//! a lexical mask that blanks comments and strings, a unified diff for previews, and the
//! all-or-nothing write that lands the result on disk.
//!
//! Nothing here knows about symbols or views. The mutators decide *what* to change from the
//! graph; this module makes the change safe: edits that overlap are refused rather than merged
//! into garbage, a path outside the view's root is refused before any file is touched, and a
//! multi-file write that fails half way puts back the files it had already written.

use std::fmt::Write as _;
use std::path::{Component, Path, PathBuf};

// ---- source text ------------------------------------------------------------------------------

/// A file's text with its line starts, so a 1-based line (what the index stores) maps to bytes.
pub struct SourceText {
    pub text: String,
    starts: Vec<usize>,
}

impl SourceText {
    pub fn new(text: String) -> SourceText {
        let mut starts = vec![0];
        starts.extend(text.match_indices('\n').map(|(i, _)| i + 1));
        // A trailing newline starts no further line.
        if text.ends_with('\n') {
            starts.pop();
        }
        SourceText { text, starts }
    }

    pub fn line_count(&self) -> usize {
        if self.text.is_empty() { 0 } else { self.starts.len() }
    }

    /// Byte offset where 1-based `line` starts; one past the last line is the end of the text.
    pub fn line_start(&self, line: usize) -> usize {
        self.starts.get(line.saturating_sub(1)).copied().unwrap_or(self.text.len())
    }

    /// Byte offset just after `line`'s newline (or the end of the text for an unterminated last line).
    pub fn line_end(&self, line: usize) -> usize {
        self.line_start(line + 1)
    }

    /// The line without its line ending.
    pub fn line(&self, line: usize) -> &str {
        let (s, e) = (self.line_start(line), self.line_end(line));
        self.text[s..e].trim_end_matches(['\n', '\r'])
    }

    /// 1-based line holding byte `offset`.
    pub fn line_of(&self, offset: usize) -> usize {
        self.starts.partition_point(|&s| s <= offset).max(1)
    }

    pub fn uses_crlf(&self) -> bool {
        self.text.find('\n').is_some_and(|i| i > 0 && self.text.as_bytes()[i - 1] == b'\r')
    }
}

// ---- edits ------------------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Edit {
    start: usize,
    end: usize,
    repl: String,
}

/// Replacements expressed against the original text, applied together. Collecting them first
/// (rather than editing as we go) is what keeps every offset valid: a rename touching three
/// places on one line cannot shift the second place under the first edit.
#[derive(Debug, Default)]
pub struct Edits {
    items: Vec<Edit>,
}

impl Edits {
    pub fn replace(&mut self, start: usize, end: usize, repl: impl Into<String>) {
        self.items.push(Edit { start, end, repl: repl.into() });
    }

    pub fn insert(&mut self, at: usize, text: impl Into<String>) {
        self.replace(at, at, text);
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// Does an edit already cover any byte of `start..end`?
    pub fn touches(&self, start: usize, end: usize) -> bool {
        self.items.iter().any(|e| e.start < end.max(start + 1) && start < e.end.max(e.start + 1))
    }

    pub fn apply(&self, text: &str) -> Result<String, String> {
        let mut items = self.items.clone();
        items.sort_by_key(|e| (e.start, e.end));
        let mut out = String::with_capacity(text.len());
        let mut at = 0;
        for e in &items {
            if e.start < at {
                // Two mutators' edits landing on the same bytes means a bug in site collection;
                // writing one of them silently would corrupt the file.
                return Err(format!("overlapping edits at byte {} (internal error; nothing was written)", e.start));
            }
            if e.end > text.len() || !text.is_char_boundary(e.start) || !text.is_char_boundary(e.end) {
                return Err(format!("edit range {}..{} is not valid for the file text", e.start, e.end));
            }
            out.push_str(&text[at..e.start]);
            out.push_str(&e.repl);
            at = e.end;
        }
        out.push_str(&text[at..]);
        Ok(out)
    }
}

// ---- lexical mask -----------------------------------------------------------------------------

/// `text` with every comment and string literal blanked to spaces (newlines and byte offsets
/// kept), so a token search never matches `helper` inside `"helper"` or `// helper`. The index's
/// reference facts say which *lines* mention a name; this decides which occurrences on the line
/// are code.
pub fn mask(lang: &str, text: &str) -> String {
    let b = text.as_bytes();
    let mut out = b.to_vec();
    let blank = |out: &mut Vec<u8>, from: usize, to: usize| {
        for c in &mut out[from..to.min(b.len())] {
            if *c != b'\n' && *c != b'\r' {
                *c = b' ';
            }
        }
    };
    let elm = lang == "elm";
    let rust = lang == "rust";
    let backtick = matches!(lang, "typescript" | "tsx" | "javascript");
    let mut i = 0;
    // Template literals nest code (`${ … }`), so the brace depth to return to is kept on a stack.
    let mut template_stack: Vec<usize> = Vec::new();
    let mut brace_depth = 0usize;
    while i < b.len() {
        let c = b[i];
        let next = b.get(i + 1).copied();
        if elm {
            if c == b'-' && next == Some(b'-') {
                let end = text[i..].find('\n').map_or(b.len(), |n| i + n);
                blank(&mut out, i, end);
                i = end;
                continue;
            }
            if c == b'{' && next == Some(b'-') {
                let end = nested_block_end(b, i, b"{-", b"-}");
                blank(&mut out, i, end);
                i = end;
                continue;
            }
            if text[i..].starts_with("\"\"\"") {
                let end = text[i + 3..].find("\"\"\"").map_or(b.len(), |n| i + 3 + n + 3);
                blank(&mut out, i, end);
                i = end;
                continue;
            }
        } else {
            if c == b'/' && next == Some(b'/') {
                let end = text[i..].find('\n').map_or(b.len(), |n| i + n);
                blank(&mut out, i, end);
                i = end;
                continue;
            }
            if c == b'/' && next == Some(b'*') {
                let end = if rust { nested_block_end(b, i, b"/*", b"*/") } else { text[i + 2..].find("*/").map_or(b.len(), |n| i + 2 + n + 2) };
                blank(&mut out, i, end);
                i = end;
                continue;
            }
            if rust && (c == b'r') && (i == 0 || !is_ident_byte(b[i - 1], false)) {
                // r"…" / r#"…"#
                let mut j = i + 1;
                while b.get(j) == Some(&b'#') {
                    j += 1;
                }
                if b.get(j) == Some(&b'"') {
                    let hashes = j - i - 1;
                    let close = format!("\"{}", "#".repeat(hashes));
                    let end = text[j + 1..].find(&close).map_or(b.len(), |n| j + 1 + n + close.len());
                    blank(&mut out, i, end);
                    i = end;
                    continue;
                }
            }
            if backtick {
                if c == b'`' {
                    let end = template_end(b, i + 1, &mut template_stack, brace_depth);
                    match end {
                        TemplateEnd::Closed(e) => {
                            blank(&mut out, i, e);
                            i = e;
                        }
                        TemplateEnd::Code(e) => {
                            // Stopped at `${`: the text up to it is string, what follows is code.
                            blank(&mut out, i, e);
                            brace_depth += 1;
                            i = e;
                        }
                    }
                    continue;
                }
                if !template_stack.is_empty() {
                    if c == b'{' {
                        brace_depth += 1;
                    } else if c == b'}' {
                        brace_depth -= 1;
                        if Some(&brace_depth) == template_stack.last() {
                            template_stack.pop();
                            // Back inside the template text after the closing `}`.
                            match template_end(b, i + 1, &mut template_stack, brace_depth) {
                                TemplateEnd::Closed(e) => {
                                    blank(&mut out, i, e);
                                    i = e;
                                }
                                TemplateEnd::Code(e) => {
                                    blank(&mut out, i, e);
                                    brace_depth += 1;
                                    i = e;
                                }
                            }
                            continue;
                        }
                    }
                }
            }
        }
        if c == b'"' || (c == b'\'' && !rust && !elm) {
            let end = string_end(b, i + 1, c);
            blank(&mut out, i, end);
            i = end;
            continue;
        }
        if c == b'\'' && (rust || elm) && (i == 0 || !is_ident_byte(b[i - 1], elm)) {
            // A char literal (`'a'`, `'\n'`) or, in Rust, a lifetime (`'a`), which is code.
            if next == Some(b'\\') {
                let end = string_end(b, i + 1, b'\'');
                blank(&mut out, i, end);
                i = end;
                continue;
            }
            if let Some(ch) = text[i + 1..].chars().next() {
                let after = i + 1 + ch.len_utf8();
                if b.get(after) == Some(&b'\'') && ch != '\'' {
                    blank(&mut out, i, after + 1);
                    i = after + 1;
                    continue;
                }
            }
        }
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_string())
}

enum TemplateEnd {
    /// The closing backtick was found; the index after it.
    Closed(usize),
    /// A `${` was found at this index (past it); code follows.
    Code(usize),
}

fn template_end(b: &[u8], mut i: usize, stack: &mut Vec<usize>, depth: usize) -> TemplateEnd {
    while i < b.len() {
        match b[i] {
            b'\\' => i += 2,
            b'`' => return TemplateEnd::Closed(i + 1),
            b'$' if b.get(i + 1) == Some(&b'{') => {
                stack.push(depth);
                return TemplateEnd::Code(i + 2);
            }
            _ => i += 1,
        }
    }
    TemplateEnd::Closed(b.len())
}

fn string_end(b: &[u8], mut i: usize, quote: u8) -> usize {
    while i < b.len() {
        match b[i] {
            b'\\' => i += 2,
            c if c == quote => return i + 1,
            _ => i += 1,
        }
    }
    b.len()
}

fn nested_block_end(b: &[u8], start: usize, open: &[u8], close: &[u8]) -> usize {
    let (mut depth, mut i) = (0usize, start);
    while i < b.len() {
        if b[i..].starts_with(open) {
            depth += 1;
            i += open.len();
        } else if b[i..].starts_with(close) {
            depth -= 1;
            i += close.len();
            if depth == 0 {
                return i;
            }
        } else {
            i += 1;
        }
    }
    b.len()
}

pub fn is_ident_byte(c: u8, elm: bool) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'$' || c >= 0x80 || (elm && c == b'\'')
}

/// Byte offsets in `masked[from..to]` where `name` appears as a whole identifier.
pub fn tokens(masked: &str, name: &str, from: usize, to: usize, elm: bool) -> Vec<usize> {
    let b = masked.as_bytes();
    let to = to.min(b.len());
    let mut out = Vec::new();
    if name.is_empty() || from >= to {
        return out;
    }
    let mut at = from;
    while let Some(n) = masked[at..to].find(name) {
        let s = at + n;
        let e = s + name.len();
        let before_ok = s == 0 || !is_ident_byte(b[s - 1], elm);
        let after_ok = e >= b.len() || !is_ident_byte(b[e], elm);
        if before_ok && after_ok {
            out.push(s);
        }
        at = s + name.len().max(1);
        if at >= to {
            break;
        }
    }
    out
}

// ---- unified diff -----------------------------------------------------------------------------

/// `diff -u` style output for one file, 3 lines of context. Created files diff against
/// `/dev/null` and deleted ones to it, so a preview reads like `git diff`.
pub fn unified_diff(path: &Path, old: Option<&str>, new: Option<&str>) -> String {
    let a: Vec<&str> = old.map(|t| t.split_inclusive('\n').collect()).unwrap_or_default();
    let b: Vec<&str> = new.map(|t| t.split_inclusive('\n').collect()).unwrap_or_default();
    let mut out = String::new();
    let shown = path.display();
    let _ = writeln!(out, "--- {}", if old.is_some() { shown.to_string() } else { "/dev/null".into() });
    let _ = writeln!(out, "+++ {}", if new.is_some() { shown.to_string() } else { "/dev/null".into() });
    let ops = diff_ops(&a, &b);
    const CTX: usize = 3;
    let mut i = 0;
    while i < ops.len() {
        if matches!(ops[i], Op::Same(..)) {
            i += 1;
            continue;
        }
        // A hunk runs from 3 lines before the first change to 3 after the last, merging changes
        // closer than twice the context.
        let first = i.saturating_sub(CTX);
        let mut last = i;
        let mut j = i;
        while j < ops.len() {
            if !matches!(ops[j], Op::Same(..)) {
                last = j;
            } else if j - last > 2 * CTX {
                break;
            }
            j += 1;
        }
        let end = (last + CTX + 1).min(ops.len());
        let (mut a_start, mut b_start) = (0usize, 0usize);
        let (mut a_len, mut b_len) = (0usize, 0usize);
        let mut body = String::new();
        let mut counted = false;
        for op in ops.iter().take(end).skip(first) {
            let (ai, bi) = match op {
                Op::Same(x, y) | Op::Del(x, y) | Op::Add(x, y) => (*x, *y),
            };
            if !counted {
                (a_start, b_start) = (ai, bi);
                counted = true;
            }
            match op {
                Op::Same(x, _) => {
                    a_len += 1;
                    b_len += 1;
                    push_line(&mut body, ' ', a[*x]);
                }
                Op::Del(x, _) => {
                    a_len += 1;
                    push_line(&mut body, '-', a[*x]);
                }
                Op::Add(_, y) => {
                    b_len += 1;
                    push_line(&mut body, '+', b[*y]);
                }
            }
        }
        let fmt = |start: usize, len: usize| if len == 0 { format!("{start},0") } else if len == 1 { format!("{}", start + 1) } else { format!("{},{}", start + 1, len) };
        let _ = writeln!(out, "@@ -{} +{} @@", fmt(a_start, a_len), fmt(b_start, b_len));
        out.push_str(&body);
        i = end;
    }
    out
}

fn push_line(out: &mut String, sign: char, line: &str) {
    out.push(sign);
    out.push_str(line.trim_end_matches('\n'));
    out.push('\n');
    if !line.ends_with('\n') {
        out.push_str("\\ No newline at end of file\n");
    }
}

enum Op {
    /// (index in a, index in b)
    Same(usize, usize),
    Del(usize, usize),
    Add(usize, usize),
}

/// Line diff by longest common subsequence over what is left after trimming the common head and
/// tail. A mutation touches a few places in a file, so the middle is small; past 16M cells (two
/// 4000-line stretches that differ throughout) the middle is reported as replaced wholesale, which
/// is a correct diff, only not a minimal one.
fn diff_ops(a: &[&str], b: &[&str]) -> Vec<Op> {
    let head = a.iter().zip(b).take_while(|(x, y)| x == y).count();
    let tail = a[head..].iter().rev().zip(b[head..].iter().rev()).take_while(|(x, y)| x == y).count();
    let (am, bm) = (&a[head..a.len() - tail], &b[head..b.len() - tail]);
    let mut ops: Vec<Op> = (0..head).map(|i| Op::Same(i, i)).collect();
    let (n, m) = (am.len(), bm.len());
    if n * m > 16_000_000 {
        ops.extend((0..n).map(|i| Op::Del(head + i, head)));
        ops.extend((0..m).map(|j| Op::Add(head + n, head + j)));
    } else {
        // lcs[i][j] = length of the LCS of am[i..] and bm[j..]
        let mut lcs = vec![0u32; (n + 1) * (m + 1)];
        let w = m + 1;
        for i in (0..n).rev() {
            for j in (0..m).rev() {
                lcs[i * w + j] = if am[i] == bm[j] { lcs[(i + 1) * w + j + 1] + 1 } else { lcs[(i + 1) * w + j].max(lcs[i * w + j + 1]) };
            }
        }
        let (mut i, mut j) = (0, 0);
        while i < n || j < m {
            if i < n && j < m && am[i] == bm[j] {
                ops.push(Op::Same(head + i, head + j));
                i += 1;
                j += 1;
            } else if j >= m || (i < n && lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]) {
                ops.push(Op::Del(head + i, head + j));
                i += 1;
            } else {
                ops.push(Op::Add(head + i, head + j));
                j += 1;
            }
        }
    }
    ops.extend((0..tail).map(|k| Op::Same(a.len() - tail + k, b.len() - tail + k)));
    ops
}

// ---- writing ----------------------------------------------------------------------------------

/// One file's change. `before: None` creates the file; `after: None` deletes it.
#[derive(Debug, Clone)]
pub struct Change {
    pub path: PathBuf,
    pub before: Option<Vec<u8>>,
    pub after: Option<Vec<u8>>,
    /// Permission bits for a created file (a moved file keeps its mode); an existing file keeps its own.
    pub mode: Option<u32>,
}

/// Lexically normalise `p` (no `.`/`..`), without touching the disk.
fn normalise(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other),
        }
    }
    out
}

/// Refuse a path that would land outside `root`, resolving symlinks in whatever part exists. This
/// is the check that stops a mutation reaching another worktree of the same repository (the way
/// qartez's mutators wrote into the main checkout when run from a worktree) or following a
/// symlink out of the view.
pub fn check_within(root: &Path, path: &Path) -> Result<(), String> {
    let root_real = root.canonicalize().map_err(|e| format!("cannot resolve the view root {}: {e}", root.display()))?;
    let path = normalise(path);
    let mut existing = path.as_path();
    while !existing.exists() {
        match existing.parent() {
            Some(p) => existing = p,
            None => break,
        }
    }
    let real = existing.canonicalize().map_err(|e| format!("cannot resolve {}: {e}", path.display()))?;
    if !real.starts_with(&root_real) {
        return Err(format!("refusing to write {}: it is outside the view's worktree {}", path.display(), root_real.display()));
    }
    if path.symlink_metadata().is_ok_and(|m| m.file_type().is_symlink()) {
        return Err(format!("refusing to write {}: it is a symbolic link", path.display()));
    }
    Ok(())
}

fn write_atomic(path: &Path, bytes: &[u8], mode_from: Option<&std::fs::Permissions>) -> std::io::Result<()> {
    use std::io::Write;
    let dir = path.parent().unwrap_or(Path::new("."));
    let tmp = dir.join(format!(".fdindex-{}-{}.tmp", std::process::id(), TMP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)));
    let result = (|| {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        if let Some(p) = mode_from {
            std::fs::set_permissions(&tmp, p.clone())?;
        }
        drop(f);
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

static TMP_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// What was done to one path, enough to undo it.
struct Done {
    path: PathBuf,
    before: Option<Vec<u8>>,
    perms: Option<std::fs::Permissions>,
    created_dirs: Vec<PathBuf>,
}

/// Write every change under `root`, or none.
///
/// All paths are checked first, and each file's current bytes must still equal `before`: a file
/// someone else changed since the plan read it is a refusal, never an overwrite. Each write is a
/// temp file plus rename in the same directory (so a reader sees the old file or the new one,
/// never half), keeping the original's permissions. If any step fails, the files already written
/// are put back and directories this call created are removed.
pub fn apply_changes(root: &Path, changes: &[Change]) -> Result<(), String> {
    apply_change_sets(&[(root, changes)])
}

/// `apply_changes` for several worktrees at once (a mutation applied across linked views): every
/// change is checked against its own root and its recorded bytes before anything is written, and
/// a failure in any root puts back the files already written in all of them. A half-applied
/// cross-repository rename is worse than none.
pub fn apply_change_sets(sets: &[(&Path, &[Change])]) -> Result<(), String> {
    for (root, changes) in sets {
        for c in changes.iter() {
            check_within(root, &c.path)?;
            let now = std::fs::read(&c.path).ok();
            if now != c.before {
                return Err(format!("{} changed on disk while the edit was being prepared; nothing was written, retry", c.path.display()));
            }
        }
    }
    let mut done: Vec<Done> = Vec::new();
    for c in sets.iter().flat_map(|(_, changes)| changes.iter()) {
        let existing = std::fs::metadata(&c.path).ok().map(|m| m.permissions());
        let perms = existing.clone().or_else(|| {
            use std::os::unix::fs::PermissionsExt;
            c.mode.map(std::fs::Permissions::from_mode)
        });
        let mut created_dirs = Vec::new();
        let step = (|| -> std::io::Result<()> {
            match &c.after {
                Some(bytes) => {
                    if let Some(dir) = c.path.parent() {
                        let mut missing = Vec::new();
                        let mut d = dir;
                        while !d.exists() {
                            missing.push(d.to_path_buf());
                            match d.parent() {
                                Some(p) => d = p,
                                None => break,
                            }
                        }
                        std::fs::create_dir_all(dir)?;
                        created_dirs = missing;
                    }
                    write_atomic(&c.path, bytes, perms.as_ref())
                }
                None => std::fs::remove_file(&c.path),
            }
        })();
        done.push(Done { path: c.path.clone(), before: c.before.clone(), perms: existing, created_dirs });
        if let Err(e) = step {
            let restored = rollback(&done);
            let scope = if sets.len() > 1 { "every worktree is" } else { "the worktree is" };
            return Err(format!("writing {} failed: {e}. Rolled back {restored} file(s); {scope} as it was.", c.path.display()));
        }
    }
    Ok(())
}

/// Put back every file in `done` (newest first). Returns how many were restored.
fn rollback(done: &[Done]) -> usize {
    let mut n = 0;
    for d in done.iter().rev() {
        let ok = match &d.before {
            Some(bytes) => write_atomic(&d.path, bytes, d.perms.as_ref()).is_ok(),
            None => !d.path.exists() || std::fs::remove_file(&d.path).is_ok(),
        };
        for dir in &d.created_dirs {
            let _ = std::fs::remove_dir(dir);
        }
        n += ok as usize;
    }
    n
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mask_blanks_strings_and_comments_but_keeps_offsets() {
        let src = "let a = helper(); // helper\nlet s = \"helper\"; /* helper */ helper()\n";
        let m = mask("rust", src);
        assert_eq!(m.len(), src.len());
        assert_eq!(tokens(&m, "helper", 0, m.len(), false).len(), 2, "{m}");
    }

    #[test]
    fn mask_keeps_template_expressions_as_code() {
        let src = "const s = `a helper ${helper()} b`;\n";
        let m = mask("typescript", src);
        assert_eq!(tokens(&m, "helper", 0, m.len(), false).len(), 1, "{m}");
    }

    #[test]
    fn mask_knows_a_lifetime_from_a_char_literal() {
        let m = mask("rust", "fn f<'a>(x: &'a str) { let c = 'x'; let d = '\\n'; helper(c) }\n");
        assert_eq!(tokens(&m, "helper", 0, m.len(), false).len(), 1);
        assert!(m.contains("'a"), "a lifetime is code: {m}");
    }

    #[test]
    fn elm_primes_are_part_of_the_identifier() {
        let m = mask("elm", "foo' = foo\n-- foo\n{- foo -}\n");
        assert_eq!(tokens(&m, "foo", 0, m.len(), true), vec![7]);
    }

    #[test]
    fn overlapping_edits_are_refused() {
        let mut e = Edits::default();
        e.replace(0, 4, "x");
        e.replace(2, 6, "y");
        assert!(e.apply("abcdefgh").is_err());
    }

    #[test]
    fn diff_reports_hunks_with_context() {
        let d = unified_diff(Path::new("/w/a.txt"), Some("1\n2\n3\n4\n5\n6\n7\n8\n9\n"), Some("1\n2\n3\n4\nX\n6\n7\n8\n9\n"));
        assert!(d.contains("@@ -2,7 +2,7 @@"), "{d}");
        assert!(d.contains("-5\n+X\n"), "{d}");
    }

    #[test]
    fn a_failed_second_write_restores_the_first() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        std::fs::write(root.join("a.txt"), "one").unwrap();
        // `blocker` is a file, so a path below it can never be created.
        std::fs::write(root.join("blocker"), "x").unwrap();
        let changes = vec![
            Change { path: root.join("a.txt"), before: Some(b"one".to_vec()), after: Some(b"two".to_vec()), mode: None },
            Change { path: root.join("blocker/b.txt"), before: None, after: Some(b"new".to_vec()), mode: None },
        ];
        let err = apply_changes(&root, &changes).unwrap_err();
        assert!(err.contains("Rolled back") || err.contains("outside") || err.contains("cannot"), "{err}");
        assert_eq!(std::fs::read_to_string(root.join("a.txt")).unwrap(), "one");
    }

    #[test]
    fn a_path_outside_the_root_is_refused_before_anything_is_written() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("wt");
        let other = dir.path().join("other");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::create_dir_all(&other).unwrap();
        std::fs::write(root.join("a.txt"), "one").unwrap();
        let changes = vec![
            Change { path: root.join("a.txt"), before: Some(b"one".to_vec()), after: Some(b"two".to_vec()), mode: None },
            Change { path: root.join("../other/x.txt"), before: None, after: Some(b"no".to_vec()), mode: None },
        ];
        let err = apply_changes(&root, &changes).unwrap_err();
        assert!(err.contains("outside the view's worktree"), "{err}");
        assert_eq!(std::fs::read_to_string(root.join("a.txt")).unwrap(), "one");
        assert!(!other.join("x.txt").exists());
    }
}
