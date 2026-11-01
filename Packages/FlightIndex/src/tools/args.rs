//! Reading tool arguments the way the clients send them.
//!
//! MCP clients send typed JSON; the CLI sends everything as strings (`--limit 5`, `--regex`).
//! Every getter therefore accepts both, and every parameter has the aliases the contract lists,
//! so an agent that calls `qartez_find symbol_name=x` and one that calls `fdindex find --name x`
//! reach the same code.

use serde_json::{Map, Value};
use std::path::{Component, Path, PathBuf};

pub const FILE: &[&str] = &["file_path", "file", "path"];
pub const SYMBOL: &[&str] = &["symbol", "name", "symbol_name"];

pub struct Args {
    map: Map<String, Value>,
    pub cwd: PathBuf,
}

impl Args {
    pub fn new(map: Map<String, Value>, cwd: PathBuf) -> Args {
        Args { map, cwd }
    }

    fn get(&self, names: &[&str]) -> Option<&Value> {
        names.iter().find_map(|n| self.map.get(*n)).filter(|v| !v.is_null())
    }

    pub fn str(&self, names: &[&str]) -> Option<String> {
        match self.get(names)? {
            Value::String(s) if !s.is_empty() => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        }
    }

    pub fn flag(&self, names: &[&str], default: bool) -> bool {
        match self.get(names) {
            Some(Value::Bool(b)) => *b,
            Some(Value::String(s)) => !matches!(s.as_str(), "false" | "0" | "no" | "off"),
            Some(Value::Number(n)) => n.as_i64() != Some(0),
            _ => default,
        }
    }

    pub fn num(&self, names: &[&str]) -> Option<usize> {
        match self.get(names)? {
            Value::Number(n) => n.as_u64().map(|n| n as usize),
            Value::String(s) => s.trim().parse().ok(),
            _ => None,
        }
    }

    /// A list given as an array, a comma-separated string, or (from the CLI) a repeated flag.
    pub fn list(&self, names: &[&str]) -> Vec<String> {
        match self.get(names) {
            Some(Value::Array(a)) => a.iter().filter_map(|v| v.as_str().map(String::from)).collect(),
            Some(Value::String(s)) => s.split(',').map(|p| p.trim().to_string()).filter(|p| !p.is_empty()).collect(),
            _ => Vec::new(),
        }
    }

    /// A path argument made absolute against the caller's cwd (never against a project root).
    pub fn path(&self, names: &[&str]) -> Option<PathBuf> {
        self.str(names).map(|p| resolve_path(&self.cwd, &p))
    }

    pub fn has(&self, names: &[&str]) -> bool {
        self.get(names).is_some()
    }
}

/// Make `p` absolute against `cwd`, collapse `.` and `..`, and resolve symlinks in the part that
/// exists. The path itself may not exist (an agent about to create it), so only its deepest
/// existing ancestor is canonicalised: the result then compares equal to a worktree root, which
/// `git::locate` canonicalises too (macOS `/tmp` is really `/private/tmp`).
pub fn resolve_path(cwd: &Path, p: &str) -> PathBuf {
    let joined = if Path::new(p).is_absolute() { PathBuf::from(p) } else { cwd.join(p) };
    let mut norm = PathBuf::new();
    for c in joined.components() {
        match c {
            Component::ParentDir => {
                norm.pop();
            }
            Component::CurDir => {}
            other => norm.push(other),
        }
    }
    let mut existing = norm.as_path();
    let mut tail: Vec<&std::ffi::OsStr> = Vec::new();
    while !existing.exists() {
        match (existing.file_name(), existing.parent()) {
            (Some(n), Some(parent)) => {
                tail.push(n);
                existing = parent;
            }
            _ => break,
        }
    }
    let mut out = existing.canonicalize().unwrap_or_else(|_| existing.to_path_buf());
    for t in tail.iter().rev() {
        out.push(t);
    }
    out
}
