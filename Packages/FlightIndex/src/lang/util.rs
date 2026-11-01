//! Helpers shared by the language extractors.

use crate::facts::{Symbol, SymbolKind};
use tree_sitter::{Language, Node, Parser, Tree};

pub fn parse(lang: &Language, source: &str) -> Option<Tree> {
    let mut parser = Parser::new();
    parser.set_language(lang).ok()?;
    parser.parse(source, None)
}

pub fn text<'a>(n: Node, src: &'a str) -> &'a str {
    &src[n.byte_range()]
}

pub fn field_text<'a>(n: Node, field: &str, src: &'a str) -> Option<&'a str> {
    n.child_by_field_name(field).map(|c| text(c, src))
}

/// A symbol positioned at `n`. `local_id` is assigned by `BlobFacts::push_symbol`.
pub fn symbol(
    n: Node,
    name: &str,
    kind: SymbolKind,
    signature: Option<String>,
    parent: Option<u32>,
    exported: bool,
) -> Symbol {
    Symbol {
        local_id: 0,
        name: name.to_string(),
        kind,
        start_line: n.start_position().row as u32 + 1,
        start_col: n.start_position().column as u32,
        end_line: n.end_position().row as u32 + 1,
        end_col: n.end_position().column as u32,
        signature,
        parent,
        exported,
    }
}

/// Collapse runs of whitespace so a multi-line signature fits on one line, and cap its length:
/// a generated 5 KB type annotation must not bloat every row that mentions it.
pub fn one_line(s: &str) -> String {
    let mut out = String::with_capacity(s.len().min(200));
    for word in s.split_whitespace() {
        if !out.is_empty() {
            out.push(' ');
        }
        out.push_str(word);
        if out.len() > 240 {
            let mut cut = 240;
            while !out.is_char_boundary(cut) {
                cut -= 1;
            }
            out.truncate(cut);
            out.push('…');
            break;
        }
    }
    out
}

/// Source from the start of `n` up to the start of its `body` field (or all of `n` when it has
/// none): the declaration line without the implementation.
pub fn signature_before_body(n: Node, src: &str) -> String {
    let end = n.child_by_field_name("body").map(|b| b.start_byte()).unwrap_or(n.end_byte());
    one_line(src[n.start_byte()..end].trim_end_matches(['{', ' ', '\n', '\t', '=']))
}

pub fn line_count(src: &str) -> u32 {
    if src.is_empty() { 0 } else { src.lines().count() as u32 }
}

/// Split `a.b.C` (or `a::b::c`) at the final separator into (qualifier, name).
pub fn split_qualified<'a>(s: &'a str, sep: &str) -> (Option<&'a str>, &'a str) {
    match s.rfind(sep) {
        Some(i) => (Some(&s[..i]), &s[i + sep.len()..]),
        None => (None, s),
    }
}
