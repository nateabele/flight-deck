//! One file being edited: its text, its lexical mask, and the edits collected so far; plus the
//! statement-level helpers (import extents, bracketed lists) the rename and move planners share.

use crate::edit::{self, Edits, SourceText};
use std::path::PathBuf;

pub struct Doc {
    pub path: PathBuf,
    pub lang: &'static str,
    /// The bytes read from disk (`None` for a file this plan creates).
    pub before: Option<Vec<u8>>,
    pub src: SourceText,
    /// `src.text` with comments and strings blanked, same byte offsets.
    pub masked: String,
    pub edits: Edits,
    /// The file is removed (its content moved to a new path by `rename_file`).
    pub deleted: bool,
    /// Permission bits a created file gets (the file it was moved from).
    pub mode: Option<u32>,
}

impl Doc {
    pub fn new(path: PathBuf, lang: &'static str, before: Option<Vec<u8>>, text: String) -> Doc {
        let masked = edit::mask(lang, &text);
        Doc { path, lang, before, src: SourceText::new(text), masked, edits: Edits::default(), deleted: false, mode: None }
    }

    pub fn elm(&self) -> bool {
        self.lang == "elm"
    }

    pub fn nl(&self) -> &'static str {
        if self.src.uses_crlf() { "\r\n" } else { "\n" }
    }

    /// Byte range of line `line` (1-based) without its line ending, in the masked text or the raw one.
    pub fn line_span(&self, line: usize) -> (usize, usize) {
        let s = self.src.line_start(line);
        (s, s + self.src.line(line).len())
    }

    /// Offsets of whole-identifier `name` on `line`, in code (not strings or comments).
    pub fn line_tokens(&self, line: usize, name: &str) -> Vec<usize> {
        let (s, e) = self.line_span(line);
        edit::tokens(&self.masked, name, s, e, self.elm())
    }

    /// Offsets of a dotted module name (`Expr.Node`) that is not part of a longer dotted name.
    pub fn dotted_tokens(&self, name: &str) -> Vec<usize> {
        let b = self.masked.as_bytes();
        let mut out = Vec::new();
        let mut at = 0;
        while let Some(n) = self.masked[at..].find(name) {
            let s = at + n;
            let e = s + name.len();
            let before_ok = s == 0 || !(edit::is_ident_byte(b[s - 1], true) || b[s - 1] == b'.');
            let after_ok = e >= b.len() || !(edit::is_ident_byte(b[e], true) || b[e] == b'.' && b.get(e + 1).is_some_and(|c| c.is_ascii_uppercase()));
            if before_ok && after_ok {
                out.push(s);
            }
            at = s + 1;
        }
        out
    }

    pub fn tokens_in(&self, from: usize, to: usize, name: &str) -> Vec<usize> {
        edit::tokens(&self.masked, name, from, to, self.elm())
    }

    /// First and last line of the statement starting at `line`: for Elm the line plus the
    /// indented lines under it (a declaration starts in column 0); elsewhere until the brackets
    /// opened on it are closed.
    pub fn extent(&self, line: usize) -> (usize, usize) {
        let total = self.src.line_count();
        if self.elm() {
            let mut last = line;
            while last < total {
                let next = self.src.line(last + 1);
                if next.starts_with([' ', '\t']) && !next.trim().is_empty() {
                    last += 1;
                } else {
                    break;
                }
            }
            return (line, last);
        }
        let mut depth: i64 = 0;
        let mut last = line;
        while last <= total && last < line + 500 {
            let (s, e) = self.line_span(last);
            for c in self.masked[s..e].bytes() {
                match c {
                    b'(' | b'{' | b'[' => depth += 1,
                    b')' | b'}' | b']' => depth -= 1,
                    _ => {}
                }
            }
            if depth <= 0 {
                break;
            }
            last += 1;
        }
        (line, last.min(total.max(line)))
    }

    /// Byte range of lines `a..=b` including the last line's ending.
    pub fn lines_bytes(&self, a: usize, b: usize) -> (usize, usize) {
        (self.src.line_start(a), self.src.line_end(b))
    }

    pub fn raw(&self, a: usize, b: usize) -> &str {
        &self.src.text[a..b]
    }

    /// Replace the token at `at` (length `len`) with `new`, unless something already edits it.
    pub fn replace_token(&mut self, at: usize, len: usize, new: &str) -> bool {
        if self.edits.touches(at, at + len) {
            return false;
        }
        self.edits.replace(at, at + len, new);
        true
    }

    /// Insert whole lines before 1-based `line` (or at the end of the file for `line_count + 1`).
    /// `text` carries no trailing newline; one is added in the file's own style.
    pub fn insert_lines_before(&mut self, line: usize, text: &str) {
        let at = self.src.line_start(line);
        let nl = self.nl();
        let mut s = text.replace("\r\n", "\n").replace('\n', nl);
        s.push_str(nl);
        // Appending to a file whose last line has no newline: end that line first.
        if at == self.src.text.len() && !self.src.text.is_empty() && !self.src.text.ends_with('\n') {
            s.insert_str(0, nl);
        }
        self.edits.insert(at, s);
    }

    pub fn delete_lines(&mut self, a: usize, b: usize) {
        let (s, e) = self.lines_bytes(a, b);
        self.edits.replace(s, e, "");
    }

    /// Line after the last import statement, or `None` if the file has no imports.
    pub fn after_last_import(&self, imports: &[crate::facts::Import]) -> Option<usize> {
        imports.iter().map(|i| self.extent(i.line as usize).1 + 1).max()
    }
}

// ---- bracketed lists --------------------------------------------------------------------------

/// One entry of an import list (`helper`, `Kind(..)`, `other as o`), with its byte range.
#[derive(Debug, Clone)]
pub struct Item {
    pub start: usize,
    pub end: usize,
    /// The first identifier: the name the entry imports.
    pub base: String,
}

/// The entries of the list between `open` and its matching bracket, split at top-level commas.
/// `masked` decides where brackets and commas are, `raw` supplies the text.
pub fn list_items(raw: &str, masked: &str, open: usize) -> Option<(Vec<Item>, usize)> {
    let b = masked.as_bytes();
    let (opener, closer) = match b.get(open)? {
        b'(' => (b'(', b')'),
        b'{' => (b'{', b'}'),
        _ => return None,
    };
    let mut depth = 0i32;
    let mut item_start = open + 1;
    let mut items: Vec<Item> = Vec::new();
    let mut close = None;
    let push = |from: usize, to: usize, items: &mut Vec<Item>| {
        let text = &raw[from..to];
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return;
        }
        let lead = text.len() - text.trim_start().len();
        let start = from + lead;
        let end = start + trimmed.len();
        let base: String = trimmed.trim_start_matches("type ").chars().take_while(|c| c.is_alphanumeric() || *c == '_' || *c == '$' || *c == '\'').collect();
        items.push(Item { start, end, base });
    };
    let mut i = open;
    while i < b.len() {
        let c = b[i];
        if c == opener || c == b'(' || c == b'[' || c == b'{' {
            depth += 1;
        } else if c == closer || c == b')' || c == b']' || c == b'}' {
            depth -= 1;
            if depth == 0 {
                push(item_start, i, &mut items);
                close = Some(i);
                break;
            }
        } else if c == b',' && depth == 1 {
            push(item_start, i, &mut items);
            item_start = i + 1;
        }
        i += 1;
    }
    close.map(|c| (items, c))
}

/// Delete entry `idx` of `items` from the text with its comma, leaving the neighbours' layout alone.
pub fn remove_item(edits: &mut Edits, items: &[Item], idx: usize) {
    let it = &items[idx];
    if idx + 1 < items.len() {
        edits.replace(it.start, items[idx + 1].start, "");
    } else if idx > 0 {
        edits.replace(items[idx - 1].end, it.end, "");
    } else {
        edits.replace(it.start, it.end, "");
    }
}
