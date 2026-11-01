//! The read-only tools: the compatibility surface agents already know (`qartez_map`, `find`,
//! `grep`, `read`, `outline`, `deps`, `stats`, `impact`, `refs`, `calls`), answered from a
//! `ViewGraph`. See `docs/superpowers/specs/2026-11-01-index-tool-contract.md` for the shapes.
//!
//! A tool is a function of a `Ctx`: the graph of the view that answers, the arguments, and what
//! state that view's index is in. Locating the view, building it and the header line every result
//! starts with belong to the service; nothing here touches git or the store, which keeps each tool
//! a pure function of a graph that tests can drive without a daemon.

mod analysis;
pub mod args;
pub mod mutate;
mod nav;
mod ranked;

use crate::cochange::CoChange;
use crate::error::Result;
use crate::facts::SymbolKind;
use crate::graph::ViewGraph;
use crate::links::{Member, Views};
use crate::proto::state;
use crate::query::SymbolHit;
use args::Args;
use regex::Regex;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub const TOOLS: &[&str] = &["map", "find", "grep", "read", "outline", "deps", "stats", "impact", "refs", "calls"];

/// Default `token_budget`. A token is counted as four characters, which is close enough for a
/// bound whose job is to stop a tool flooding a context window.
pub const DEFAULT_TOKEN_BUDGET: usize = 4000;

#[derive(Debug)]
pub struct ToolError {
    pub state: &'static str,
    pub message: String,
}

impl ToolError {
    pub fn bad(message: impl Into<String>) -> ToolError {
        ToolError { state: state::BAD_REQUEST, message: message.into() }
    }
    pub fn failed(message: impl Into<String>) -> ToolError {
        ToolError { state: state::ERROR, message: message.into() }
    }
}

impl From<crate::error::Error> for ToolError {
    fn from(e: crate::error::Error) -> ToolError {
        ToolError::failed(e.to_string())
    }
}

pub type ToolResult = std::result::Result<String, ToolError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Detailed,
    Concise,
    Mermaid,
}

pub struct Ctx<'a> {
    pub graph: &'a ViewGraph,
    pub args: &'a Args,
    pub format: Format,
    pub token_budget: usize,
    /// `(done, total)` while the view's build is still running: a file or symbol that is missing
    /// may simply not have been parsed yet.
    pub building: Option<(usize, usize)>,
    /// The views linked to `graph`'s (or depending on it) that the request pulled in; empty for a
    /// tool that answers from one view (`links.rs`).
    pub members: &'a [Member],
    pub cochange: &'a (dyn Fn() -> Result<Arc<CoChange>> + Sync),
}

/// Strip the `qartez_` / `fdindex_` prefix an MCP client adds and return the tool's own name.
pub fn canonical(tool: &str) -> Option<&'static str> {
    let bare = tool.strip_prefix("qartez_").or_else(|| tool.strip_prefix("fdindex_")).unwrap_or(tool);
    TOOLS.iter().copied().find(|t| *t == bare)
}

/// `format` and `token_budget` are shared by every tool; `mermaid` only makes sense for graphs.
pub fn common_params(tool: &str, args: &Args) -> std::result::Result<(Format, usize), ToolError> {
    let format = match args.str(&["format"]).as_deref() {
        None | Some("detailed") => Format::Detailed,
        Some("concise") => Format::Concise,
        Some("mermaid") if matches!(tool, "deps" | "calls") => Format::Mermaid,
        Some("mermaid") => return Err(ToolError::bad(format!("format=mermaid is only supported by deps and calls, not {tool}"))),
        Some(other) => return Err(ToolError::bad(format!("unknown format '{other}': use detailed, concise or mermaid"))),
    };
    Ok((format, args.num(&["token_budget"]).unwrap_or(DEFAULT_TOKEN_BUDGET)))
}

/// Where a request's view is found from, and what to build first.
pub struct Anchor {
    /// The view is the one containing this path (the caller's cwd when the query names none).
    pub path: PathBuf,
    /// Paths to parse first when the view is not built yet.
    pub priority: Vec<PathBuf>,
    /// `read` of a plain file range needs no index, only the file; it must not wait for a build.
    pub needs_index: bool,
    /// The answer depends only on the requested files and their direct imports, so the build's
    /// priority slice is enough. Tools that look at who imports or calls what need the whole view.
    pub slice_ok: bool,
}

pub fn anchor(tool: &str, args: &Args) -> std::result::Result<Anchor, ToolError> {
    let file = args.path(args::FILE);
    let requires_file = matches!(tool, "outline" | "deps" | "impact");
    if requires_file && file.is_none() {
        return Err(ToolError::bad(format!("{tool} requires file_path")));
    }
    let by_symbol = args.has(args::SYMBOL) || args.has(&["symbols"]);
    let needs_index = tool != "read" || by_symbol;
    let slice_ok = matches!(tool, "outline" | "read");
    Ok(match file {
        Some(f) => Anchor { priority: vec![f.clone()], path: f, needs_index, slice_ok },
        None => Anchor { path: args.cwd.clone(), priority: Vec::new(), needs_index, slice_ok },
    })
}

/// Does this tool look beyond the view that answers it? `find` and the like search the linked
/// views; `refs`, `calls`, `deps` and `impact` follow imports across them. `outline`, `map` and
/// `stats` describe one view, and `read` of a file range needs only the file.
pub fn uses_links(tool: &str, args: &Args) -> bool {
    match tool {
        "find" | "refs" | "calls" | "deps" | "impact" => true,
        "grep" => !args.flag(&["search_bodies"], false),
        "read" => !args.has(args::FILE) && (args.has(args::SYMBOL) || args.has(&["symbols"])),
        _ => false,
    }
}

pub fn run(tool: &str, c: &Ctx) -> ToolResult {
    let text = match tool {
        "find" => nav::find(c),
        "grep" => nav::grep(c),
        "read" => nav::read(c),
        "outline" => nav::outline(c),
        "map" => analysis::map(c),
        "deps" => analysis::deps(c),
        "stats" => analysis::stats(c),
        "impact" => analysis::impact(c),
        "refs" => analysis::refs(c),
        "calls" => analysis::calls(c),
        other => Err(ToolError::bad(format!("unknown tool '{other}'"))),
    }?;
    Ok(text)
}

// ---- helpers shared by the tools ------------------------------------------------------------

impl Ctx<'_> {
    pub fn kind(&self) -> std::result::Result<Option<SymbolKind>, ToolError> {
        let Some(k) = self.args.str(&["kind"]) else { return Ok(None) };
        let k = k.to_ascii_lowercase();
        let k = if k == "type" { "type_alias".to_string() } else { k };
        SymbolKind::parse(&k).map(Some).ok_or_else(|| ToolError::bad(format!("unknown kind '{k}'")))
    }

    /// Index of the file `file_path` names, in this view. A file that is not there is an error,
    /// but a different one while the build is running: it may just not be parsed yet.
    pub fn file(&self) -> std::result::Result<(PathBuf, u32), ToolError> {
        let p = self.args.path(args::FILE).ok_or_else(|| ToolError::bad("file_path is required"))?;
        match self.graph.file_idx(&p) {
            Some(i) => Ok((p, i)),
            None => Err(self.missing(&p)),
        }
    }

    pub fn missing(&self, p: &Path) -> ToolError {
        match self.building {
            Some((done, total)) => ToolError {
                state: state::BUILDING,
                message: format!("{} is not indexed yet (index: building, {done} of {total} files); retry shortly", p.display()),
            },
            None => ToolError::failed(format!(
                "{} is not an indexed source file of view {} (unsupported language, ignored, or too large)",
                p.display(),
                self.graph.label.worktree.display()
            )),
        }
    }

    /// The answering view and the views linked to it.
    pub fn views(&self) -> Views<'_> {
        Views::new(self.graph, self.members)
    }

    /// Definitions of `name`, optionally of one kind and in one file: the answering view's first,
    /// then its linked views' (`SymbolHit::view` says which).
    pub fn definitions(&self, name: &str, kind: Option<SymbolKind>, file: Option<&Path>) -> Vec<SymbolHit> {
        let hits = self.views().find_symbols(&crate::query::NameMatch::Exact(name.to_string()), kind);
        match file {
            Some(f) => hits.into_iter().filter(|h| h.path == f).collect(),
            None => hits,
        }
    }

    /// Keep the head of `text` that fits `token_budget`, cut at a line, and say how to see more.
    pub fn fit(&self, text: String) -> String {
        truncate(text, self.token_budget)
    }
}

pub fn truncate(text: String, token_budget: usize) -> String {
    let max = token_budget.saturating_mul(4);
    if text.len() <= max {
        return text;
    }
    let mut cut = max;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    let cut = text[..cut].rfind('\n').unwrap_or(cut);
    let total = text.lines().count();
    let shown = text[..cut].lines().count();
    format!("{}\n… truncated: {shown} of {total} lines shown (token_budget={token_budget}); raise token_budget to see more", &text[..cut])
}

pub fn compile_regex(pattern: &str) -> std::result::Result<Regex, ToolError> {
    regex::RegexBuilder::new(pattern).case_insensitive(true).build().map_err(|e| ToolError::bad(format!("invalid regex '{pattern}': {e}")))
}

/// Test files by convention: a test directory, or a name like `x_test.rs`, `x.spec.ts`, `XTests.swift`.
pub fn is_test_path(path: &str) -> bool {
    let lower = path.to_ascii_lowercase();
    if lower.split('/').any(|s| matches!(s, "test" | "tests" | "__tests__" | "spec" | "specs" | "e2e")) {
        return true;
    }
    let name = lower.rsplit('/').next().unwrap_or("");
    let stem = name.split('.').next().unwrap_or("");
    // `FooTests.swift` / `FooTest.java`: the capital marks a word, which `lower` has erased.
    let cased = path.rsplit('/').next().unwrap_or("").split('.').next().unwrap_or("");
    name.contains(".test.") || name.contains(".spec.") || stem.ends_with("_test") || stem.ends_with("_spec") || stem.starts_with("test_") || cased.ends_with("Tests") || cased.ends_with("Test")
}

pub fn range(h: &SymbolHit) -> String {
    format!("[L{}-L{}]", h.start_line, h.end_line)
}

pub fn status(h: &SymbolHit) -> &'static str {
    if h.exported { "exported" } else { "private" }
}

/// The repository's short name, as the header prints it.
pub fn repo_name(label: &crate::git::ViewLabel) -> String {
    if label.is_git {
        let r = label.repo.as_path();
        let base = if r.file_name().is_some_and(|n| n == ".git") { r.parent().unwrap_or(r) } else { r };
        base.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()
    } else {
        label.worktree.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()
    }
}

/// The label on a row that came from a view other than the one the header names:
/// `tessera @ /Users/me/Projects/Tessera/tessera`.
pub fn view_tag(label: &crate::git::ViewLabel) -> String {
    format!("{} @ {}", repo_name(label), label.worktree.display())
}

/// The view header: the first line of every result.
///
/// `view: /abs/worktree (repo name, base 1a2b3c4, dirty 3 files)`, with ` index: building, N of M
/// files` appended while the index is still being built.
pub fn header(label: &crate::git::ViewLabel, dirty_files: usize, building: Option<(usize, usize)>) -> String {
    let repo = repo_name(label);
    let base = match (&label.base_commit, label.is_git) {
        (Some(c), _) => c.chars().take(7).collect::<String>(),
        (None, true) => "no commits".to_string(),
        (None, false) => "not git".to_string(),
    };
    let state = if dirty_files == 0 && !label.dirty { "clean".to_string() } else { format!("dirty {dirty_files} files") };
    let mut line = format!("view: {} (repo {repo}, base {base}, {state})", label.worktree.display());
    if let Some((done, total)) = building {
        line.push_str(&format!(" index: building, {done} of {total} files"));
    }
    line
}
