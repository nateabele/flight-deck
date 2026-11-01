//! The mutators: `replace_symbol`, `insert_before_symbol`, `insert_after_symbol`, `rename`, `move`,
//! `safe_delete`, `rename_file`.
//!
//! A mutator is a function from the graph of one view and the arguments to a `Plan`: the files to
//! change, as before/after bytes. Planning only reads (the graph, and the files on disk); it never
//! writes. The service then either prints the plan as a diff (the default) or, with `apply=true`,
//! writes it atomically inside that view's worktree and re-indexes before answering. Keeping
//! "decide what changes" apart from "write it" is what lets every safety rule live in one place
//! (`edit::apply_changes`) instead of in seven tools.
//!
//! Sites to change come from the index's facts (a reference's line, name and qualifier; an
//! import's line and names; a symbol's span), and the occurrence on the line is then located by an
//! exact identifier match on the code-only text, so `helper` in a string or a comment is never
//! touched. Every span is checked against the file on disk first: a file whose bytes no longer
//! hash to the blob the index parsed is refused, never spliced into shifted lines.

mod doc;
mod relocate;
mod rename;

use super::args::{Args, FILE, SYMBOL};
use super::ToolError;
use crate::edit::Change;
use crate::facts::SymbolKind;
use crate::git;
use crate::graph::{SymId, ViewGraph};
use crate::query::{NameMatch, SymbolHit};
use doc::Doc;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const MUTATORS: &[&str] =
    &["replace_symbol", "insert_before_symbol", "insert_after_symbol", "rename", "move", "safe_delete", "rename_file"];

/// Prefix of the error a stale file produces. The service recomputes the view and plans again when
/// it sees it: the index lagged an edit made in the last few milliseconds, which is not the
/// agent's problem.
pub const STALE: &str = "stale index:";

/// Is `path` a file the index parses? (A manifest a mutator edited is not, so it has no blob to check.)
pub fn indexable(path: &Path) -> bool {
    crate::lang::for_path(path).is_some()
}

pub fn canonical(tool: &str) -> Option<&'static str> {
    let bare = tool.strip_prefix("qartez_").or_else(|| tool.strip_prefix("fdindex_")).unwrap_or(tool);
    MUTATORS.iter().copied().find(|t| *t == bare)
}

pub struct MutCtx<'a> {
    pub graph: &'a ViewGraph,
    pub args: &'a Args,
}

/// What a mutator wants to do, ready to preview or to write.
pub struct Plan {
    /// One line: `rename helper -> assist (function in /abs/src/A.elm)`.
    pub summary: String,
    /// Things the agent should know that are not problems.
    pub notes: Vec<String>,
    /// Things that may need a follow-up: sites that could not be located, occurrences left alone.
    pub warnings: Vec<String>,
    pub changes: Vec<Change>,
}

/// The arguments that name the symbol a mutator works on, or `None` for one that works on a file.
pub fn symbol_keys(tool: &str) -> Option<&'static [&'static str]> {
    match tool {
        "rename" => Some(&["old_name", "symbol", "name", "symbol_name"]),
        "rename_file" => None,
        _ => Some(SYMBOL),
    }
}

/// Where the lookup for a mutator starts: the view containing this path.
pub fn anchor_path(tool: &str, args: &Args) -> Result<PathBuf, ToolError> {
    let key: &[&str] = match tool {
        "rename_file" => &["from", "old_path", "file_path"],
        _ => FILE,
    };
    Ok(args.path(key).unwrap_or_else(|| args.cwd.clone()))
}

/// Paths a mutator will read first so a cold view parses them before the rest of its build.
pub fn priority_paths(tool: &str, args: &Args) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = Vec::new();
    match tool {
        "rename_file" => v.extend(args.path(&["from", "old_path", "file_path"])),
        _ => v.extend(args.path(FILE)),
    }
    v
}

pub fn plan(tool: &str, c: &MutCtx) -> Result<Plan, ToolError> {
    match tool {
        "replace_symbol" => replace_symbol(c),
        "insert_before_symbol" => insert(c, true),
        "insert_after_symbol" => insert(c, false),
        "safe_delete" => safe_delete(c),
        "rename" => rename::rename(c),
        "move" => relocate::move_symbol(c),
        "rename_file" => relocate::rename_file(c),
        other => Err(ToolError::bad(format!("unknown mutator '{other}'"))),
    }
}

// ---- the set of files being edited ------------------------------------------------------------

/// Files loaded for editing, keyed by absolute path. A file is read once, checked against the
/// blob the index parsed, and every planner step edits the same `Doc`.
pub struct Work<'a> {
    pub g: &'a ViewGraph,
    pub docs: BTreeMap<PathBuf, Doc>,
    pub notes: Vec<String>,
    pub warnings: Vec<String>,
}

impl<'a> Work<'a> {
    pub fn new(g: &'a ViewGraph) -> Work<'a> {
        Work { g, docs: BTreeMap::new(), notes: Vec::new(), warnings: Vec::new() }
    }

    /// An indexed file of the view, read from disk. Refuses a file that no longer matches what the
    /// index parsed: its symbol spans would point at shifted lines.
    pub fn doc(&mut self, fi: u32) -> Result<&mut Doc, ToolError> {
        let abs = self.g.abs(fi);
        if !self.docs.contains_key(&abs) {
            let node = self.g.file(fi);
            let bytes = std::fs::read(&abs).map_err(|e| ToolError::failed(format!("{}: {e}", abs.display())))?;
            if git::blob_id(&bytes) != node.blob_id {
                return Err(ToolError::failed(format!("{STALE} {} changed on disk after the index parsed it, so its recorded line ranges may be shifted; retry", abs.display())));
            }
            let text = String::from_utf8(bytes.clone()).map_err(|_| ToolError::failed(format!("{} is not valid UTF-8 text", abs.display())))?;
            self.docs.insert(abs.clone(), Doc::new(abs.clone(), node.language, Some(bytes), text));
        }
        Ok(self.docs.get_mut(&abs).expect("just inserted"))
    }

    /// A file that is not an indexed source file of the view: a manifest, or a file this plan
    /// creates. `lang` is the language to mask it as.
    pub fn doc_at(&mut self, abs: &Path, lang: &'static str) -> Result<&mut Doc, ToolError> {
        if !self.docs.contains_key(abs) {
            let bytes = std::fs::read(abs).ok();
            let text = match &bytes {
                Some(b) => String::from_utf8(b.clone()).map_err(|_| ToolError::failed(format!("{} is not valid UTF-8 text", abs.display())))?,
                None => String::new(),
            };
            self.docs.insert(abs.to_path_buf(), Doc::new(abs.to_path_buf(), lang, bytes, text));
        }
        Ok(self.docs.get_mut(abs).expect("just inserted"))
    }

    pub fn finish(self, summary: String) -> Result<Plan, ToolError> {
        let mut changes = Vec::new();
        for (path, d) in self.docs {
            let after = d.edits.apply(&d.src.text).map_err(ToolError::failed)?;
            let after = if d.deleted { None } else { Some(after.into_bytes()) };
            if after != d.before || (d.before.is_none() && after.is_some()) {
                changes.push(Change { path, before: d.before, after, mode: d.mode });
            }
        }
        Ok(Plan { summary, notes: self.notes, warnings: self.warnings, changes })
    }
}

// ---- choosing the symbol ----------------------------------------------------------------------

pub fn kind_arg(args: &Args) -> Result<Option<SymbolKind>, ToolError> {
    let Some(k) = args.str(&["kind"]) else { return Ok(None) };
    let k = k.to_ascii_lowercase();
    let k = if k == "type" { "type_alias".to_string() } else { k };
    SymbolKind::parse(&k).map(Some).ok_or_else(|| ToolError::bad(format!("unknown kind '{k}'")))
}

/// The one definition the arguments name, or a refusal listing the candidates with their absolute
/// paths and kinds. `keys` are the argument names (and aliases) that hold the symbol name.
pub fn select(c: &MutCtx, keys: &[&str]) -> Result<SymbolHit, ToolError> {
    let name = c.args.str(keys).ok_or_else(|| ToolError::bad(format!("{} is required", keys[0])))?;
    let kind = kind_arg(c.args)?;
    let file = c.args.path(FILE);
    let view = c.graph.label.worktree.display();
    if let Some(f) = &file
        && !f.is_dir()
        && c.graph.file_idx(f).is_none()
    {
        return Err(ToolError::failed(format!("{} is not an indexed source file of view {view}", f.display())));
    }
    let mut defs: Vec<SymbolHit> = c.graph.find_symbols(&NameMatch::Exact(name.clone()), kind, usize::MAX).data;
    // `impl Foo` blocks are named Foo too; they are not what anyone means by "the symbol Foo".
    defs.retain(|h| h.kind != SymbolKind::Impl || kind == Some(SymbolKind::Impl));
    if let Some(f) = &file {
        defs.retain(|h| h.path == *f);
    }
    defs.sort_by(|a, b| a.path.cmp(&b.path).then(a.start_line.cmp(&b.start_line)));
    match defs.len() {
        1 => Ok(defs.remove(0)),
        0 => Err(ToolError::failed(format!(
            "no definition named '{name}'{}{} in view {view}. A mutator looks only in the view that answers it (your worktree, or the checkout a path you name is in); to change another checkout, pass file_path inside it.",
            kind.map(|k| format!(" of kind {}", k.as_str())).unwrap_or_default(),
            file.as_ref().map(|f| format!(" in {}", f.display())).unwrap_or_default()
        ))),
        n => {
            let mut m = format!("refusing: '{name}' matches {n} definitions in view {view}; nothing was changed. Pass file_path=<one of these> and/or kind=<kind>, or a qualified name (Type::{name}):\ncandidates:\n");
            for h in &defs {
                m.push_str(&format!("  {} {} [L{}-L{}]{}\n", h.kind.as_str(), h.path.display(), h.start_line, h.end_line, h.parent.as_ref().map(|p| format!(" in {p}")).unwrap_or_default()));
            }
            Err(ToolError::failed(m.trim_end().to_string()))
        }
    }
}

pub fn sym_id(h: &SymbolHit) -> SymId {
    h.id
}

/// Does the symbol occupy whole lines? A method sharing its line with `impl Foo {` does not, and
/// replacing or deleting by line would take the rest of the line with it.
pub fn whole_lines(d: &Doc, h: &SymbolHit, start_col: u32, end_col: u32) -> bool {
    let line = |n: u32| d.src.line(n as usize);
    let before = &line(h.start_line)[..(start_col as usize).min(line(h.start_line).len())];
    let after = &line(h.end_line)[(end_col as usize).min(line(h.end_line).len())..];
    let modifiers = ["export", "default", "declare", "abstract", "pub", "async", "unsafe", "const", "static", "public", "private", "protected", "readonly", "override"];
    let prefix_ok = before.split_whitespace().all(|w| modifiers.contains(&w) || w.starts_with("pub("));
    let suffix_ok = after.trim().trim_matches([';', ',']).is_empty();
    prefix_ok && suffix_ok
}

/// First line of the doc comments, attributes and decorators attached above `line`, so an insert
/// or a delete takes the documentation with the definition rather than leaving it orphaned.
pub fn leading_trivia(d: &Doc, line: usize) -> usize {
    let elm = d.elm();
    let mut l = line;
    while l > 1 {
        let p = d.src.line(l - 1).trim();
        let line_comment = if elm { p.starts_with("--") } else { p.starts_with("//") };
        let attr = !elm && (p.starts_with("#[") || p.starts_with("#![") || (p.starts_with('@') && !p.contains(' ')));
        let block_end = if elm { p.ends_with("-}") } else { p.ends_with("*/") };
        if line_comment || attr {
            l -= 1;
        } else if block_end {
            let open = if elm { "{-" } else { "/*" };
            let mut k = l - 1;
            while k > 1 && !d.src.line(k).contains(open) {
                k -= 1;
            }
            l = k;
        } else {
            break;
        }
    }
    l
}

// ---- replace / insert / delete ----------------------------------------------------------------

/// The first line of `code` that is code, with comments, strings, doc comments and attributes
/// skipped (masked text, so a `fn` inside a comment never counts).
fn first_code_line(lang: &str, code: &str) -> Option<String> {
    let masked = crate::edit::mask(lang, code);
    let mut attr_depth = 0i32;
    for line in masked.lines() {
        let t = line.trim();
        if attr_depth > 0 || t.starts_with("#[") || t.starts_with("#![") || (t.starts_with('@') && lang != "elm") {
            attr_depth += t.matches('[').count() as i32 - t.matches(']').count() as i32;
            if attr_depth < 0 {
                attr_depth = 0;
            }
            continue;
        }
        if !t.is_empty() {
            return Some(t.to_string());
        }
    }
    None
}

/// `new_code` must start like a definition in the file's language. Without this, a snippet that
/// is an expression or half a function replaces a whole definition and the file stops parsing.
pub fn validate_introducer(lang: &str, kind: SymbolKind, code: &str) -> Result<(), String> {
    let first = first_code_line(lang, code).ok_or("new_code is empty or only comments")?;
    let word = |s: &str, i: usize| s.split(|c: char| !(c.is_alphanumeric() || c == '_' || c == '!')).filter(|w| !w.is_empty()).nth(i).map(str::to_string);
    let (introducers, modifiers): (&[&str], &[&str]) = match lang {
        "rust" => (
            &["fn", "struct", "enum", "trait", "impl", "type", "const", "static", "mod", "macro_rules!", "union", "extern"],
            &["pub", "async", "unsafe", "const", "extern", "default"],
        ),
        "typescript" | "tsx" | "javascript" => (
            &["function", "class", "interface", "type", "enum", "const", "let", "var", "namespace", "module"],
            &["export", "default", "declare", "abstract", "async"],
        ),
        "elm" => (&["type", "port"], &[]),
        _ => (
            &["func", "class", "struct", "enum", "protocol", "extension", "def", "defp", "defmodule", "defmacro", "defstruct", "defprotocol", "defimpl", "let", "var", "const", "fn", "typealias", "interface", "trait", "type", "actor"],
            &["public", "private", "internal", "open", "final", "static", "async", "export", "pub", "override", "mutating", "indirect"],
        ),
    };
    let mut i = 0;
    while let Some(w) = word(&first, i) {
        if introducers.contains(&w.as_str()) {
            return Ok(());
        }
        if !modifiers.contains(&w.as_str()) {
            break;
        }
        i += 1;
    }
    // Members and variants have no introducer: `go() { … }`, `Stop Int`, `name: Type`.
    let member_kind = matches!(kind, SymbolKind::Method | SymbolKind::Field | SymbolKind::Constructor | SymbolKind::Const | SymbolKind::Port);
    let starts_ident = first.trim_start_matches(['|', '=', ' ']).chars().next().is_some_and(|c| c.is_alphabetic() || c == '_' || c == '#' || c == '[' || c == '*');
    match lang {
        // An Elm function begins with its name (an annotation `name : T` or a clause `name x =`).
        "elm" if matches!(kind, SymbolKind::Function | SymbolKind::Const) && first.chars().next().is_some_and(|c| c.is_lowercase()) => return Ok(()),
        "elm" if kind == SymbolKind::Constructor && starts_ident => return Ok(()),
        "typescript" | "tsx" | "javascript" if member_kind && starts_ident => return Ok(()),
        "rust" if matches!(kind, SymbolKind::Field | SymbolKind::Constructor) && starts_ident => return Ok(()),
        _ => {}
    }
    Err(format!(
        "new_code must begin with a definition introducer for {lang} ({}); it begins with `{}`",
        introducers.join(", "),
        first.chars().take(60).collect::<String>()
    ))
}

fn new_code_arg(c: &MutCtx) -> Result<String, ToolError> {
    c.args.str(&["new_code", "code"]).ok_or_else(|| ToolError::bad("new_code is required"))
}

fn replace_symbol(c: &MutCtx) -> Result<Plan, ToolError> {
    let code = new_code_arg(c)?;
    let t = select(c, SYMBOL)?;
    let g = c.graph;
    let s = g.symbol(t.id).clone();
    let mut w = Work::new(g);
    let lang = g.file(t.id.file).language;
    validate_introducer(lang, t.kind, &code).map_err(ToolError::bad)?;
    let d = w.doc(t.id.file)?;
    let whole = whole_lines(d, &t, s.start_col, s.end_col);
    let (start, end) = if whole {
        d.lines_bytes(t.start_line as usize, t.end_line as usize)
    } else {
        (d.src.line_start(t.start_line as usize) + s.start_col as usize, d.src.line_start(t.end_line as usize) + s.end_col as usize)
    };
    let nl = d.nl();
    let mut text = code.replace("\r\n", "\n");
    if whole {
        if !text.ends_with('\n') {
            text.push('\n');
        }
        text = text.replace('\n', nl);
    } else {
        text = text.trim_end_matches('\n').replace('\n', nl);
    }
    d.edits.replace(start, end, text);
    if !code.contains(t.name.as_str()) {
        w.warnings.push(format!("new_code does not mention `{}`: references to it elsewhere will no longer resolve", t.name));
    }
    w.notes.push(format!("replaces L{}-L{} of {}{}", t.start_line, t.end_line, t.path.display(), if whole { "" } else { " (only the symbol's own columns: other code shares its lines)" }));
    w.finish(format!("replace_symbol {} ({}) in {}", t.name, t.kind.as_str(), t.path.display()))
}

fn insert(c: &MutCtx, before: bool) -> Result<Plan, ToolError> {
    let code = new_code_arg(c)?;
    let t = select(c, SYMBOL)?;
    let g = c.graph;
    let s = g.symbol(t.id).clone();
    let mut w = Work::new(g);
    let d = w.doc(t.id.file)?;
    if !whole_lines(d, &t, s.start_col, s.end_col) {
        return Err(ToolError::failed(format!("{} shares its lines with other code, so a line-based insert next to it would land inside that code; use replace_symbol on the enclosing definition", t.name)));
    }
    let text = code.trim_end_matches(['\n', '\r']).to_string();
    let line = if before { leading_trivia(d, t.start_line as usize) } else { t.end_line as usize + 1 };
    d.insert_lines_before(line, &text);
    let verb = if before { "before" } else { "after" };
    w.notes.push(format!("inserts {} line(s) {verb} {} (L{}-L{}) in {}", text.lines().count(), t.name, t.start_line, t.end_line, t.path.display()));
    w.finish(format!("insert_{verb}_symbol {} ({}) in {}", t.name, t.kind.as_str(), t.path.display()))
}

fn safe_delete(c: &MutCtx) -> Result<Plan, ToolError> {
    let t = select(c, SYMBOL)?;
    let force = c.args.flag(&["force"], false);
    let g = c.graph;
    let s = g.symbol(t.id).clone();
    let tf = t.id.file;

    // The symbol and what it contains (a type's constructors) go together, and a use of any of
    // them from outside is a live reference.
    let file = g.file(tf);
    let inside = |local: u32| {
        let mut cur = Some(local);
        while let Some(c) = cur {
            if c == t.id.local {
                return true;
            }
            cur = file.symbol(c).parent;
        }
        false
    };
    let targets: Vec<u32> = file.facts.symbols.iter().filter(|x| inside(x.local_id)).map(|x| x.local_id).collect();
    let mut live: Vec<String> = Vec::new();
    for &local in &targets {
        for &(fi, ri) in g.incoming.get(&SymId { file: tf, local }).unwrap_or(&[]) {
            let r = &g.file(fi).facts.refs[ri as usize];
            let own = fi == tf && r.enclosing.is_some_and(&inside);
            if !own {
                live.push(format!("{}:L{} ({})", g.abs(fi).display(), r.line, r.kind.as_str()));
            }
        }
    }
    for (fi, node) in g.files.iter().enumerate().filter(|(_, n)| n.alive) {
        for (ii, imp) in node.facts.imports.iter().enumerate() {
            let hits_file = matches!(&g.res[fi].imports[ii], crate::resolve::Resolved::File { path, .. } if path == &file.path);
            if hits_file && imp.names.iter().any(|n| n.name == t.name) && fi as u32 != tf {
                live.push(format!("{}:L{} (import)", g.abs(fi as u32).display(), imp.line));
            }
        }
    }
    live.sort();
    live.dedup();
    if !live.is_empty() && !force {
        let mut m = format!("refusing: {} ({}) has {} live reference(s); nothing was changed. Pass force=true to delete it anyway.\n", t.name, t.kind.as_str(), live.len());
        for l in live.iter().take(30) {
            m.push_str(&format!("  {l}\n"));
        }
        if live.len() > 30 {
            m.push_str(&format!("  … {} more\n", live.len() - 30));
        }
        return Err(ToolError::failed(m.trim_end().to_string()));
    }

    let mut w = Work::new(g);
    let d = w.doc(tf)?;
    if !whole_lines(d, &t, s.start_col, s.end_col) {
        return Err(ToolError::failed(format!("{} shares its lines with other code; deleting by line would remove that too. Use replace_symbol on the enclosing definition", t.name)));
    }
    let first = leading_trivia(d, t.start_line as usize);
    let (mut a, mut b) = (first, t.end_line as usize);
    // Leave one blank line between the neighbours, not two.
    let blank = |d: &Doc, l: usize| l >= 1 && l <= d.src.line_count() && d.src.line(l).trim().is_empty();
    if blank(d, b + 1) && (a == 1 || blank(d, a - 1)) {
        b += 1;
    } else if blank(d, a.saturating_sub(1)) && b == d.src.line_count() {
        a -= 1;
    }
    d.delete_lines(a, b);
    if d.elm() {
        // An Elm module that exposes a name it no longer defines does not compile.
        relocate::remove_from_module_exposing(d, &t.name);
    }
    if !live.is_empty() {
        w.warnings.push(format!("deleted with force: {} reference(s) remain and will no longer resolve (first: {})", live.len(), live[0]));
    }
    w.notes.push(format!("removes L{a}-L{b} of {}", t.path.display()));
    w.finish(format!("safe_delete {} ({}) in {}", t.name, t.kind.as_str(), t.path.display()))
}
