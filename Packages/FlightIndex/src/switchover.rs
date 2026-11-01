//! `fdindex switchover`: move this machine's agents from qartez to `fdindex` (spec §11a step 8).
//!
//! ```text
//! fdindex switchover [--dry-run]     print the plan: every file, every change (the default; touches nothing)
//! fdindex switchover --apply         do it, with backups and a manifest
//! fdindex switchover --rollback      undo the last apply from its manifest
//! fdindex switchover --list-old-dbs  list the per-project .qartez/index.db files with sizes (never deletes)
//! options: --home DIR (default $HOME)  --store DIR  --no-service  --root DIR (list-old-dbs, repeatable)
//! ```
//!
//! What it changes, and only this:
//!
//! 1. **The binary.** Copies the running `fdindex` to `~/.local/bin/fdindex` (a stable absolute path
//!    for hooks, MCP configs and the launchd unit).
//! 2. **Hooks.** In every `~/.claude*/settings.json` and `~/.gemini/settings.json`, a `PreToolUse`
//!    command whose program is `qartez-guard` becomes `<fdindex> guard`, and `qartez-setup
//!    --session-start` becomes `<fdindex> session-start`. Their flags are kept.
//! 3. **MCP servers.** Every server entry named `qartez` that runs the qartez binary (Claude's
//!    `mcpServers` in `settings.json` and `.claude.json`, Codex's `[mcp_servers.qartez]`, opencode's
//!    `mcp`, Zed's `context_servers`, Cursor's and Gemini's `mcpServers`) runs `<fdindex> mcp`
//!    instead. The server keeps its name, so tools stay `mcp__qartez__*`. Codex's per-tool tables
//!    (`[mcp_servers.qartez.tools.*]`) are keyed by tool name, which has not changed, so they stay
//!    as they are; one for a tool that no longer exists (`qartez_project`) is inert.
//! 4. **The `qartez` name.** `~/.local/bin/qartez` becomes a symlink to `fdindex` (the alias), after
//!    the old binary is renamed to `qartez.orig`. `qartez-guard` and `qartez-setup` are left where
//!    they are: nothing points at them any more.
//! 5. **The service.** `fdindex service install` (a launchd user agent), unless `--no-service`.
//! 6. **The skill.** The drafted `qartez` skill overlays each existing `~/.claude*/skills/qartez/`.
//!
//! Config files are edited by byte span (see `textedit`), so every other byte stays as it was; the
//! swap is atomic and retried if a running Claude rewrote the file in between; the original bytes
//! are saved first. `.qartez/index.db` files are never touched.
//!
//! Backups and the manifest live in `<store>/switchover/<UTC timestamp>/`. The manifest is written
//! after every step, so a half-finished apply can always be rolled back; an apply that fails rolls
//! itself back. A rollback puts the original bytes back when the file is still what apply wrote; if
//! something (a running Claude) has changed it since, it reverts only the values apply changed.

use crate::error::{Error, Result};
use crate::runtime::Paths;
use crate::service_install::{Manager, Service};
use crate::textedit::{self, Edit, Kind, Node};
use serde::{Deserialize, Serialize};
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

const SKILL_FILES: &[(&str, &str)] = &[
    ("SKILL.md", include_str!("../../../docs/superpowers/specs/2026-11-01-qartez-skill-draft/SKILL.md")),
    ("references/runtime-contract.md", include_str!("../../../docs/superpowers/specs/2026-11-01-qartez-skill-draft/references/runtime-contract.md")),
    ("references/guard.md", include_str!("../../../docs/superpowers/specs/2026-11-01-qartez-skill-draft/references/guard.md")),
    ("references/subagent-contract.md", include_str!("../../../docs/superpowers/specs/2026-11-01-qartez-skill-draft/references/subagent-contract.md")),
    ("references/tools.md", include_str!("../../../docs/superpowers/specs/2026-11-01-qartez-skill-draft/references/tools.md")),
    ("references/host-matrix.md", include_str!("../../../docs/superpowers/specs/2026-11-01-qartez-skill-draft/references/host-matrix.md")),
];

/// How many times a config file is re-read and re-edited when something else keeps rewriting it.
const ATTEMPTS: usize = 8;

#[derive(Debug, Clone)]
pub struct Options {
    pub home: PathBuf,
    /// The binary to install (normally the running one).
    pub exe: PathBuf,
    pub store: PathBuf,
    pub paths: Paths,
    pub label: Option<String>,
    pub service: bool,
}

impl Options {
    fn bin_dir(&self) -> PathBuf {
        self.home.join(".local/bin")
    }
    fn installed(&self) -> PathBuf {
        self.bin_dir().join("fdindex")
    }
    fn alias(&self) -> PathBuf {
        self.bin_dir().join("qartez")
    }
    fn backups(&self) -> PathBuf {
        self.store.join("switchover")
    }
    /// The installed binary as a command-line word.
    fn command_word(&self) -> String {
        shell_word(&self.installed().to_string_lossy())
    }
}

fn shell_word(s: &str) -> String {
    if !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "_./-+=:@,".contains(c)) { s.to_string() } else { format!("'{}'", s.replace('\'', "'\\''")) }
}

fn basename(program: &str) -> &str {
    program.rsplit('/').next().unwrap_or(program)
}

fn io<T>(path: &Path, r: std::io::Result<T>) -> Result<T> {
    r.map_err(|e| Error::io(path, e))
}

// ---- what to change in a JSON config ------------------------------------------------------------

/// One replaced value: where it was (path from the document root), what it said, what it says now.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Rec {
    pub path: Vec<String>,
    pub old: String,
    pub new: String,
}

/// For the dry run: the lines a change touches, before and after.
#[derive(Debug, Clone)]
pub struct Change {
    pub line: usize,
    pub before: Vec<String>,
    pub after: Vec<String>,
}

#[derive(Debug, Default)]
pub struct JsonPlan {
    pub edits: Vec<Edit>,
    pub recs: Vec<Rec>,
    pub changes: Vec<Change>,
    /// Things found but left alone, said in the dry run.
    pub notes: Vec<String>,
}

/// `qartez-guard [flags]` -> `<fd> guard [flags]`; `qartez-setup --session-start` -> `<fd> session-start`.
pub fn rewrite_hook(command: &str, fd: &str) -> Option<String> {
    let mut words = command.split_whitespace();
    let first = words.next()?;
    let rest: Vec<&str> = words.collect();
    match basename(first) {
        "qartez-guard" => Some(if rest.is_empty() { format!("{fd} guard") } else { format!("{fd} guard {}", rest.join(" ")) }),
        "qartez-setup" if rest.contains(&"--session-start") => Some(format!("{fd} session-start")),
        _ => None,
    }
}

fn is_qartez_binary(program: &str) -> bool {
    matches!(basename(program), "qartez" | "qartez-mcp")
}

/// The JSON that runs `<fd> mcp` in place of an entry that runs the qartez binary: `command` and
/// `args` for most hosts, one `command` array for opencode.
fn plan_server(doc: &str, entry: &Node, path: &[String], fd_path: &str, plan: &mut JsonPlan) -> Result<()> {
    let label = path.join(".");
    let Some(command) = entry.get("command") else {
        plan.notes.push(format!("{label}: has no `command` (left alone)"));
        return Ok(());
    };
    match &command.kind {
        Kind::Str(program) if is_qartez_binary(program) => {
            let Some(args) = entry.get("args") else {
                plan.notes.push(format!("{label}: runs {program} but has no `args` to add `mcp` to (left alone)"));
                return Ok(());
            };
            let Kind::Arr(old) = &args.kind else { return Ok(()) };
            let mut new_args = vec!["mcp".to_string()];
            new_args.extend(old.iter().filter_map(|a| a.as_str().map(str::to_string)));
            let literal = format!("[{}]", new_args.iter().map(|a| textedit::quote(a)).collect::<Vec<_>>().join(", "));
            plan.splice(doc, command, textedit::quote(fd_path), [path, &["command".to_string()]].concat());
            plan.splice(doc, args, literal, [path, &["args".to_string()]].concat());
        }
        Kind::Arr(items) if items.first().and_then(Node::as_str).is_some_and(is_qartez_binary) => {
            let mut words = vec![fd_path.to_string(), "mcp".to_string()];
            words.extend(items.iter().skip(1).filter_map(|a| a.as_str().map(str::to_string)));
            let old = command.text(doc);
            let literal = if old.contains('\n') {
                let first = &items[0];
                let line_start = doc[..first.start].rfind('\n').map_or(0, |i| i + 1);
                let item_indent = &doc[line_start..first.start];
                let close_start = doc[..command.end].rfind('\n').map_or(0, |i| i + 1);
                let close_indent = &doc[close_start..command.end - 1];
                format!("[\n{}\n{close_indent}]", words.iter().map(|w| format!("{item_indent}{}", textedit::quote(w))).collect::<Vec<_>>().join(",\n"))
            } else {
                format!("[{}]", words.iter().map(|w| textedit::quote(w)).collect::<Vec<_>>().join(", "))
            };
            plan.splice(doc, command, literal, [path, &["command".to_string()]].concat());
        }
        Kind::Str(program) if basename(program) == "fdindex" => {}
        Kind::Arr(items) if items.first().and_then(Node::as_str).is_some_and(|p| basename(p) == "fdindex") => {}
        _ => plan.notes.push(format!("{label}: runs something other than the qartez binary (left alone)")),
    }
    Ok(())
}

impl JsonPlan {
    fn splice(&mut self, doc: &str, node: &Node, text: String, path: Vec<String>) {
        if node.text(doc) == text {
            return;
        }
        self.recs.push(Rec { path, old: node.text(doc).to_string(), new: text.clone() });
        self.edits.push(Edit { start: node.start, end: node.end, text });
    }
}

/// Plan the hook and server rewrites of one JSON config. `servers` are the paths of the entries
/// named `qartez`; `hooks` says to look under the `hooks` key.
pub fn plan_json(doc: &str, fd_command: &str, fd_path: &str, hooks: bool, servers: &[&[&str]]) -> Result<JsonPlan> {
    let root = textedit::parse(doc).map_err(Error::Msg)?;
    let mut plan = JsonPlan::default();
    if hooks && let Some(h) = root.get("hooks") {
        for (rel, node) in textedit::strings_under_key(h, "command") {
            let command = node.as_str().expect("strings_under_key yields strings");
            if let Some(new) = rewrite_hook(command, fd_command) {
                plan.splice(doc, node, textedit::quote(&new), [vec!["hooks".to_string()], rel].concat());
            }
        }
    }
    for path in servers {
        let path: Vec<String> = path.iter().map(|s| s.to_string()).collect();
        if let Some(entry) = root.at(&path) {
            plan_server(doc, entry, &path, fd_path, &mut plan)?;
        }
    }
    plan.edits.sort_by_key(|e| e.start);
    plan.recs.sort_by(|a, b| a.path.cmp(&b.path));
    let (mut delta, mut changes) = (0isize, Vec::new());
    let new_doc = textedit::apply(doc, &plan.edits);
    for e in &plan.edits {
        let new_start = (e.start as isize + delta) as usize;
        changes.push(Change { line: textedit::line_number(doc, e.start), before: textedit::lines_of(doc, e.start, e.end), after: textedit::lines_of(&new_doc, new_start, new_start + e.text.len()) });
        delta += e.text.len() as isize - (e.end - e.start) as isize;
    }
    plan.changes = changes;
    Ok(plan)
}

/// Put back the values `recs` replaced, where they still read what apply wrote.
pub fn revert_json(doc: &str, recs: &[Rec]) -> Result<(String, Vec<String>)> {
    let root = textedit::parse(doc).map_err(Error::Msg)?;
    let (mut edits, mut notes) = (Vec::new(), Vec::new());
    for r in recs {
        match root.at(&r.path) {
            Some(n) if n.text(doc) == r.new => edits.push(Edit { start: n.start, end: n.end, text: r.old.clone() }),
            Some(_) => notes.push(format!("{}: changed since the switch-over; left as it is now", r.path.join("."))),
            None => notes.push(format!("{}: no longer there; nothing to put back", r.path.join("."))),
        }
    }
    Ok((textedit::apply(doc, &edits), notes))
}

// ---- Codex config.toml --------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LineRec {
    pub old: String,
    pub new: String,
}

/// In `[mcp_servers.qartez]`, point `command` at fdindex and put `mcp` first in `args`. Only that
/// table's own two lines change; its per-tool sub-tables and everything else stay as they are.
pub fn plan_toml(doc: &str, fd_path: &str) -> (String, Vec<LineRec>, Vec<String>) {
    let (mut out, mut recs, mut notes) = (String::with_capacity(doc.len()), Vec::new(), Vec::new());
    let mut in_table = false;
    for raw in doc.split_inclusive('\n') {
        let line = raw.trim_end_matches(['\n', '\r']);
        let eol = &raw[line.len()..];
        let t = line.trim();
        if t.starts_with('[') {
            in_table = t == "[mcp_servers.qartez]";
            out.push_str(raw);
            continue;
        }
        let new = if in_table { rewrite_toml_line(line, fd_path) } else { None };
        match new {
            Some(new) if new != line => {
                recs.push(LineRec { old: line.to_string(), new: new.clone() });
                out.push_str(&new);
                out.push_str(eol);
            }
            _ => out.push_str(raw),
        }
    }
    if !doc.contains("[mcp_servers.qartez]") {
        notes.push("no [mcp_servers.qartez] table".to_string());
    }
    (out, recs, notes)
}

fn rewrite_toml_line(line: &str, fd_path: &str) -> Option<String> {
    let (key, value) = line.split_once('=')?;
    match key.trim() {
        "command" => {
            let program = value.trim().strip_prefix('"')?.strip_suffix('"')?;
            is_qartez_binary(program).then(|| format!("command = {}", textedit::quote(fd_path)))
        }
        "args" => {
            let inner = value.trim().strip_prefix('[')?.strip_suffix(']')?.trim();
            (!inner.starts_with("\"mcp\"")).then(|| if inner.is_empty() { "args = [\"mcp\"]".to_string() } else { format!("args = [\"mcp\", {inner}]") })
        }
        _ => None,
    }
}

pub fn revert_toml(doc: &str, recs: &[LineRec]) -> (String, Vec<String>) {
    let (mut out, mut notes) = (String::new(), Vec::new());
    let mut pending: Vec<&LineRec> = recs.iter().collect();
    let mut in_table = false;
    for raw in doc.split_inclusive('\n') {
        let line = raw.trim_end_matches(['\n', '\r']);
        let eol = &raw[line.len()..];
        if line.trim().starts_with('[') {
            in_table = line.trim() == "[mcp_servers.qartez]";
        }
        match pending.iter().position(|r| in_table && r.new == line) {
            Some(i) => {
                out.push_str(&pending.remove(i).old);
                out.push_str(eol);
            }
            None => out.push_str(raw),
        }
    }
    notes.extend(pending.iter().map(|r| format!("config.toml: `{}` changed since the switch-over; left as it is now", r.new)));
    (out, notes)
}

// ---- the plan -------------------------------------------------------------------------------------

/// Where each config lives and what in it is ours to change.
struct JsonTarget {
    file: PathBuf,
    hooks: bool,
    servers: &'static [&'static [&'static str]],
}

fn json_targets(home: &Path) -> Vec<JsonTarget> {
    const MCP: &[&[&str]] = &[&["mcpServers", "qartez"]];
    let mut out = Vec::new();
    let mut profiles: Vec<PathBuf> = std::fs::read_dir(home)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with(".claude") && e.path().is_dir())
        .map(|e| e.path())
        .collect();
    profiles.sort();
    for dir in &profiles {
        out.push(JsonTarget { file: dir.join("settings.json"), hooks: true, servers: MCP });
    }
    out.push(JsonTarget { file: home.join(".claude.json"), hooks: false, servers: MCP });
    for dir in &profiles {
        out.push(JsonTarget { file: dir.join(".claude.json"), hooks: false, servers: MCP });
    }
    out.push(JsonTarget { file: home.join(".gemini/settings.json"), hooks: true, servers: MCP });
    out.push(JsonTarget { file: home.join(".cursor/mcp.json"), hooks: false, servers: MCP });
    out.push(JsonTarget { file: home.join(".config/zed/settings.json"), hooks: false, servers: &[&["context_servers", "qartez"]] });
    out.push(JsonTarget { file: home.join(".config/opencode/opencode.json"), hooks: false, servers: &[&["mcp", "qartez"]] });
    out.retain(|t| t.file.is_file());
    out
}

fn skill_dirs(home: &Path) -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(home)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with(".claude"))
        .map(|e| e.path().join("skills/qartez"))
        .filter(|p| p.is_dir())
        .collect();
    dirs.sort();
    dirs
}

#[derive(Debug)]
pub enum Step {
    Binary { src: PathBuf, dst: PathBuf, state: BinaryState },
    Json { file: PathBuf, plan: JsonPlan },
    Toml { file: PathBuf, recs: Vec<LineRec>, notes: Vec<String> },
    Symlink { link: PathBuf, target: String, state: LinkState },
    Service { label: String, unit: PathBuf, argv: Vec<String>, existed: bool, running: bool },
    Skill { dir: PathBuf, files: Vec<(String, SkillFile)> },
}

#[derive(Debug, PartialEq)]
pub enum BinaryState {
    New { bytes: u64 },
    Replace { bytes: u64 },
    Same,
}

#[derive(Debug, PartialEq)]
pub enum LinkState {
    Done,
    Missing,
    /// A regular file (the qartez binary) or a symlink elsewhere: renamed to `.orig` first.
    Occupied { what: String, bytes: Option<u64> },
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub enum SkillFile {
    New,
    Changed,
    Same,
}

impl Step {
    fn needed(&self) -> bool {
        match self {
            Step::Binary { state, .. } => *state != BinaryState::Same,
            Step::Json { plan, .. } => !plan.edits.is_empty(),
            Step::Toml { recs, .. } => !recs.is_empty(),
            Step::Symlink { state, .. } => *state != LinkState::Done,
            Step::Service { .. } => true,
            Step::Skill { files, .. } => files.iter().any(|(_, s)| *s != SkillFile::Same),
        }
    }
}

pub fn plan(o: &Options) -> Result<Vec<Step>> {
    let mut steps = Vec::new();
    let (dst, fd_command) = (o.installed(), o.command_word());
    let bytes = io(&o.exe, std::fs::metadata(&o.exe))?.len();
    let state = match std::fs::read(&dst) {
        Err(_) => BinaryState::New { bytes },
        Ok(have) if have == io(&o.exe, std::fs::read(&o.exe))? => BinaryState::Same,
        Ok(_) => BinaryState::Replace { bytes },
    };
    steps.push(Step::Binary { src: o.exe.clone(), dst: dst.clone(), state });

    for t in json_targets(&o.home) {
        let doc = io(&t.file, std::fs::read_to_string(&t.file))?;
        let plan = plan_json(&doc, &fd_command, &dst.to_string_lossy(), t.hooks, t.servers).map_err(|e| Error::Msg(format!("{}: {e}", t.file.display())))?;
        steps.push(Step::Json { file: t.file, plan });
    }
    let codex = o.home.join(".codex/config.toml");
    if codex.is_file() {
        let doc = io(&codex, std::fs::read_to_string(&codex))?;
        let (_, recs, notes) = plan_toml(&doc, &dst.to_string_lossy());
        steps.push(Step::Toml { file: codex, recs, notes });
    }

    let link = o.alias();
    let state = match std::fs::symlink_metadata(&link) {
        Err(_) => LinkState::Missing,
        Ok(m) if m.file_type().is_symlink() => {
            let to = std::fs::read_link(&link).unwrap_or_default();
            if to == Path::new("fdindex") || to == dst { LinkState::Done } else { LinkState::Occupied { what: format!("a symlink to {}", to.display()), bytes: None } }
        }
        Ok(m) => LinkState::Occupied { what: "the qartez binary".into(), bytes: Some(m.len()) },
    };
    steps.push(Step::Symlink { link, target: "fdindex".into(), state });

    if o.service {
        let svc = service_for(o);
        let running = crate::client::Client::connect(&o.paths.socket).is_ok();
        steps.push(Step::Service { label: svc.label.clone(), unit: svc.unit_path(), argv: svc.daemon_argv(), existed: svc.unit_path().exists(), running });
    }

    for dir in skill_dirs(&o.home) {
        let files = SKILL_FILES
            .iter()
            .map(|(rel, text)| {
                let state = match std::fs::read_to_string(dir.join(rel)) {
                    Err(_) => SkillFile::New,
                    Ok(have) if have == *text => SkillFile::Same,
                    Ok(_) => SkillFile::Changed,
                };
                (rel.to_string(), state)
            })
            .collect();
        steps.push(Step::Skill { dir, files });
    }
    Ok(steps)
}

fn service_for(o: &Options) -> Service {
    Service { manager: Manager::native(), label: o.label.clone().unwrap_or_else(|| crate::service_install::DEFAULT_LABEL.to_string()), exe: o.installed(), paths: o.paths.clone(), home: o.home.clone() }
}

fn human(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_048_576.0)
}

pub fn render(o: &Options, steps: &[Step]) -> String {
    let mut out = String::new();
    let _ = writeln!(out, "fdindex switchover: DRY RUN. Nothing was changed. `--apply` does it; `--rollback` undoes it.");
    let _ = writeln!(out, "home:      {}", o.home.display());
    let _ = writeln!(out, "fdindex:   {} -> {} (the path hooks, MCP configs and the service will use)", o.exe.display(), o.installed().display());
    let _ = writeln!(out, "backups:   {}/<UTC timestamp>/ (every file changed is copied there first, with manifest.json)", o.backups().display());
    let _ = writeln!(out);
    for (i, s) in steps.iter().enumerate() {
        let n = i + 1;
        match s {
            Step::Binary { src, dst, state } => {
                let _ = writeln!(out, "{n}. install the fdindex binary");
                match state {
                    BinaryState::New { bytes } => {
                        let _ = writeln!(out, "     copy {} -> {} (new file, {})", src.display(), dst.display(), human(*bytes));
                    }
                    BinaryState::Replace { bytes } => {
                        let _ = writeln!(out, "     copy {} -> {} ({}; the existing file is backed up first)", src.display(), dst.display(), human(*bytes));
                    }
                    BinaryState::Same => {
                        let _ = writeln!(out, "     {} is already this binary: nothing to do", dst.display());
                    }
                }
            }
            Step::Json { file, plan } => {
                let _ = writeln!(out, "{n}. {} ({})", file.display(), if plan.edits.is_empty() { "nothing to change".to_string() } else { format!("{} change(s)", plan.edits.len()) });
                for c in &plan.changes {
                    let _ = writeln!(out, "     line {}:", c.line);
                    for l in &c.before {
                        let _ = writeln!(out, "       - {}", l.trim());
                    }
                    for l in &c.after {
                        let _ = writeln!(out, "       + {}", l.trim());
                    }
                }
                for note in &plan.notes {
                    let _ = writeln!(out, "     note: {note}");
                }
            }
            Step::Toml { file, recs, notes } => {
                let _ = writeln!(out, "{n}. {} ({})", file.display(), if recs.is_empty() { "nothing to change".to_string() } else { format!("{} change(s) in [mcp_servers.qartez]", recs.len()) });
                for r in recs {
                    let _ = writeln!(out, "       - {}\n       + {}", r.old.trim(), r.new.trim());
                }
                let _ = writeln!(out, "     the per-tool tables ([mcp_servers.qartez.tools.*], approval_mode) are kept as they are");
                for note in notes {
                    let _ = writeln!(out, "     note: {note}");
                }
            }
            Step::Symlink { link, target, state } => {
                let _ = writeln!(out, "{n}. the `qartez` name: {}", link.display());
                match state {
                    LinkState::Done => {
                        let _ = writeln!(out, "     already a symlink to {target}: nothing to do");
                    }
                    LinkState::Missing => {
                        let _ = writeln!(out, "     create symlink {} -> {target}", link.display());
                    }
                    LinkState::Occupied { what, bytes } => {
                        let _ = writeln!(out, "     {} is {what}{}", link.display(), bytes.map(|b| format!(" ({})", human(b))).unwrap_or_default());
                        let _ = writeln!(out, "     rename it to {}.orig (kept), then create symlink {} -> {target}", link.display(), link.display());
                    }
                }
                let _ = writeln!(out, "     {} (-> qartez, if present) keeps working: the alias accepts that name too", link.with_file_name("qartez-mcp").display());
            }
            Step::Service { label, unit, argv, existed, running } => {
                let _ = writeln!(out, "{n}. service: fdindex service install ({label})");
                let _ = writeln!(out, "     unit {} ({})", unit.display(), if *existed { "exists; rewritten if different" } else { "new" });
                let _ = writeln!(out, "     runs {}", argv.join(" "));
                let _ = writeln!(out, "     {}", if *running { "a daemon is running now: it is stopped so the service's daemon owns the lock (sessions reconnect on their next call)" } else { "no daemon is running now" });
            }
            Step::Skill { dir, files } => {
                let _ = writeln!(out, "{n}. skill: overlay {}", dir.display());
                let _ = writeln!(out, "     the old directory is copied to the backup first; other files in it (doctrine-*.md) stay");
                for (rel, s) in files {
                    let _ = writeln!(out, "     {rel}: {}", match s {
                        SkillFile::New => "new",
                        SkillFile::Changed => "replaced",
                        SkillFile::Same => "already current",
                    });
                }
            }
        }
        let _ = writeln!(out);
    }
    let _ = writeln!(out, "left alone on purpose:");
    let _ = writeln!(out, "  - {0}/qartez-guard and {0}/qartez-setup (the old hooks; nothing points at them after this)", o.bin_dir().display());
    let _ = writeln!(out, "  - every .qartez/index.db (`fdindex switchover --list-old-dbs` lists them for a separate, deliberate deletion)");
    let _ = writeln!(out, "  - running sessions keep the qartez processes they already started until they restart; their configs now start fdindex");
    let todo = steps.iter().filter(|s| s.needed()).count();
    let _ = writeln!(out, "\n{todo} of {} step(s) would change something.", steps.len());
    out
}

// ---- manifest -------------------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Done {
    Binary { dst: PathBuf, backup: Option<String>, sha: String, installed: bool },
    Json { file: PathBuf, backup: String, before_sha: String, after_sha: String, recs: Vec<Rec> },
    Toml { file: PathBuf, backup: String, before_sha: String, after_sha: String, recs: Vec<LineRec> },
    Symlink { link: PathBuf, backup: Option<PathBuf>, target: String },
    Service { label: String, existed: bool },
    Skill { dir: PathBuf, backup: String },
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Manifest {
    pub version: u32,
    pub created: String,
    pub home: PathBuf,
    pub fdindex: PathBuf,
    pub steps: Vec<Done>,
    pub rolled_back: Option<String>,
}

fn utc_stamp() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}{m:02}{d:02}-{:02}{:02}{:02}", rem / 3600, rem % 3600 / 60, rem % 60)
}

struct Run {
    dir: PathBuf,
    manifest: Manifest,
    n: usize,
}

impl Run {
    fn save(&self) -> Result<()> {
        let path = self.dir.join("manifest.json");
        let tmp = self.dir.join("manifest.json.tmp");
        let text = serde_json::to_string_pretty(&self.manifest).map_err(|e| Error::Msg(e.to_string()))?;
        io(&tmp, std::fs::write(&tmp, text))?;
        io(&path, std::fs::rename(&tmp, &path))
    }

    /// Save `bytes` as a backup file, owner-only, and return its name relative to the run directory.
    fn backup_bytes(&self, label: &str, bytes: &[u8]) -> Result<String> {
        let rel = format!("files/{:02}-{}", self.n, label.trim_start_matches('/').replace('/', "_"));
        let path = self.dir.join(&rel);
        io(&path, std::fs::create_dir_all(path.parent().expect("has a parent")))?;
        io(&path, std::fs::write(&path, bytes))?;
        io(&path, std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o600)))?;
        Ok(rel)
    }
}

fn copy_tree(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for e in std::fs::read_dir(from)? {
        let e = e?;
        let (src, dst) = (e.path(), to.join(e.file_name()));
        let ft = e.file_type()?;
        if ft.is_symlink() {
            std::os::unix::fs::symlink(std::fs::read_link(&src)?, &dst)?;
        } else if ft.is_dir() {
            copy_tree(&src, &dst)?;
        } else {
            std::fs::copy(&src, &dst)?;
        }
    }
    Ok(())
}

fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> std::io::Result<()> {
    let tmp = path.with_file_name(format!(".{}.fdindex-switchover.tmp", path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default()));
    std::fs::write(&tmp, bytes)?;
    std::fs::set_permissions(&tmp, std::os::unix::fs::PermissionsExt::from_mode(mode))?;
    std::fs::rename(&tmp, path)
}

// ---- apply ----------------------------------------------------------------------------------------

pub fn apply(o: &Options) -> Result<String> {
    let steps = plan(o)?;
    if !steps.iter().any(Step::needed) {
        return Ok("already switched over: nothing to change.\n".into());
    }
    let dir = o.backups().join(utc_stamp());
    io(&dir, std::fs::create_dir_all(&dir))?;
    io(&dir, std::fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o700)))?;
    let mut run = Run { dir, manifest: Manifest { version: 1, created: utc_stamp(), home: o.home.clone(), fdindex: o.installed(), steps: Vec::new(), rolled_back: None }, n: 0 };
    run.save()?;
    let mut report = format!("backups and manifest: {}\n", run.dir.display());
    for step in steps.iter().filter(|s| s.needed()) {
        run.n += 1;
        match apply_step(o, &mut run, step) {
            Ok(done) => {
                let line = describe_done(&done);
                run.manifest.steps.push(done);
                run.save()?;
                let _ = writeln!(report, "done: {line}");
            }
            Err(e) => {
                let undone = rollback_manifest(o, &mut run.manifest, &run.dir).unwrap_or_else(|re| format!("rollback also failed: {re}"));
                run.save()?;
                return Err(Error::Msg(format!("{e}\n{report}the switch-over failed and was rolled back:\n{undone}")));
            }
        }
    }
    match verify(o) {
        Ok(v) => report.push_str(&v),
        Err(e) => {
            let undone = rollback_manifest(o, &mut run.manifest, &run.dir).unwrap_or_else(|re| format!("rollback also failed: {re}"));
            run.save()?;
            return Err(Error::Msg(format!("{e}\n{report}verification failed, so it was rolled back:\n{undone}")));
        }
    }
    let _ = writeln!(report, "\nswitched over. `fdindex switchover --rollback` undoes it.");
    Ok(report)
}

fn describe_done(d: &Done) -> String {
    match d {
        Done::Binary { dst, installed, .. } => format!("{} {}", if *installed { "installed" } else { "kept" }, dst.display()),
        Done::Json { file, recs, .. } => format!("{} ({} value(s))", file.display(), recs.len()),
        Done::Toml { file, recs, .. } => format!("{} ({} line(s))", file.display(), recs.len()),
        Done::Symlink { link, backup, .. } => format!("{} -> fdindex{}", link.display(), backup.as_ref().map(|b| format!(" (old one kept as {})", b.display())).unwrap_or_default()),
        Done::Service { label, .. } => format!("service {label} installed"),
        Done::Skill { dir, .. } => format!("skill {}", dir.display()),
    }
}

fn apply_step(o: &Options, run: &mut Run, step: &Step) -> Result<Done> {
    match step {
        Step::Binary { src, dst, state } => {
            io(dst, std::fs::create_dir_all(dst.parent().expect("has a parent")))?;
            let backup = match state {
                BinaryState::Replace { .. } => Some(run.backup_bytes("fdindex.previous", &io(dst, std::fs::read(dst))?)?),
                _ => None,
            };
            let bytes = io(src, std::fs::read(src))?;
            io(dst, write_atomic(dst, &bytes, 0o755))?;
            // The copy must run before anything points at it.
            let out = io(dst, std::process::Command::new(dst).arg("guard").stdin(std::process::Stdio::null()).output())?;
            if !out.status.success() || !out.stdout.is_empty() {
                return Err(Error::Msg(format!("the installed {} does not run (`guard` exited {})", dst.display(), out.status)));
            }
            Ok(Done::Binary { dst: dst.clone(), backup, sha: textedit::sha1_hex(&bytes), installed: true })
        }
        Step::Json { file, .. } => apply_json(o, run, file),
        Step::Toml { file, .. } => apply_toml(o, run, file),
        Step::Symlink { link, target, state } => {
            let backup = match state {
                LinkState::Occupied { .. } => {
                    let mut orig = PathBuf::from(format!("{}.orig", link.display()));
                    if std::fs::symlink_metadata(&orig).is_ok() {
                        orig = PathBuf::from(format!("{}.orig.{}", link.display(), utc_stamp()));
                    }
                    io(link, std::fs::rename(link, &orig))?;
                    Some(orig)
                }
                _ => None,
            };
            io(link, std::os::unix::fs::symlink(target, link))?;
            // The alias must start an MCP server before any config is left pointing at it.
            smoke_mcp(link, &[]).map_err(|e| Error::Msg(format!("{} as the qartez alias: {e}", link.display())))?;
            Ok(Done::Symlink { link: link.clone(), backup, target: target.clone() })
        }
        Step::Service { label, existed, .. } => {
            service_for(o).install()?;
            Ok(Done::Service { label: label.clone(), existed: *existed })
        }
        Step::Skill { dir, files } => {
            let backup = format!("skills/{:02}-{}", run.n, dir.to_string_lossy().trim_start_matches('/').replace('/', "_"));
            io(dir, copy_tree(dir, &run.dir.join(&backup)))?;
            for (rel, state) in files {
                if *state == SkillFile::Same {
                    continue;
                }
                let path = dir.join(rel);
                io(&path, std::fs::create_dir_all(path.parent().expect("has a parent")))?;
                let text = SKILL_FILES.iter().find(|(r, _)| r == rel).map(|(_, t)| *t).expect("a planned file exists");
                io(&path, write_atomic(&path, text.as_bytes(), 0o644))?;
            }
            Ok(Done::Skill { dir: dir.clone(), backup })
        }
    }
}

/// Read, plan, splice, swap; start over if something else wrote the file in between.
fn apply_json(o: &Options, run: &mut Run, file: &Path) -> Result<Done> {
    let (fd_command, fd_path) = (o.command_word(), o.installed().to_string_lossy().to_string());
    let target = json_targets(&o.home).into_iter().find(|t| t.file == file).ok_or_else(|| Error::Msg(format!("{} is no longer a config to edit", file.display())))?;
    for _ in 0..ATTEMPTS {
        let (bytes, stamp) = io(file, textedit::read_stamped(file))?;
        let doc = String::from_utf8(bytes.clone()).map_err(|_| Error::Msg(format!("{} is not UTF-8", file.display())))?;
        let plan = plan_json(&doc, &fd_command, &fd_path, target.hooks, target.servers)?;
        if plan.edits.is_empty() {
            return Err(Error::Msg(format!("{}: nothing left to change (it changed under us)", file.display())));
        }
        let new = textedit::apply(&doc, &plan.edits);
        let backup = run.backup_bytes(&file.to_string_lossy(), &bytes)?;
        if !io(file, textedit::replace_file(file, new.as_bytes(), &stamp))? {
            continue;
        }
        // Verify against the file as it is now: a writer that raced the rename may have put its
        // own copy back, in which case start over from that.
        let after = io(file, std::fs::read_to_string(file))?;
        let root = textedit::parse(&after).map_err(Error::Msg)?;
        if plan.recs.iter().all(|r| root.at(&r.path).is_some_and(|n| n.text(&after) == r.new)) {
            return Ok(Done::Json { file: file.to_path_buf(), backup, before_sha: stamp.sha, after_sha: textedit::sha1_hex(after.as_bytes()), recs: plan.recs });
        }
    }
    Err(Error::Msg(format!("{} kept changing while it was being edited ({ATTEMPTS} attempts); nothing was lost, try again when it is quiet", file.display())))
}

fn apply_toml(o: &Options, run: &mut Run, file: &Path) -> Result<Done> {
    let fd_path = o.installed().to_string_lossy().to_string();
    for _ in 0..ATTEMPTS {
        let (bytes, stamp) = io(file, textedit::read_stamped(file))?;
        let doc = String::from_utf8(bytes.clone()).map_err(|_| Error::Msg(format!("{} is not UTF-8", file.display())))?;
        let (new, recs, _) = plan_toml(&doc, &fd_path);
        if recs.is_empty() {
            return Err(Error::Msg(format!("{}: nothing left to change (it changed under us)", file.display())));
        }
        let backup = run.backup_bytes(&file.to_string_lossy(), &bytes)?;
        if !io(file, textedit::replace_file(file, new.as_bytes(), &stamp))? {
            continue;
        }
        let after = io(file, std::fs::read_to_string(file))?;
        if plan_toml(&after, &fd_path).1.is_empty() {
            return Ok(Done::Toml { file: file.to_path_buf(), backup, before_sha: stamp.sha, after_sha: textedit::sha1_hex(after.as_bytes()), recs });
        }
    }
    Err(Error::Msg(format!("{} kept changing while it was being edited ({ATTEMPTS} attempts); nothing was lost, try again when it is quiet", file.display())))
}

/// Start `program args...` as an MCP server and see it answer `initialize`. The daemon is not started.
fn smoke_mcp(program: &Path, args: &[&str]) -> std::result::Result<(), String> {
    use std::io::{Read, Write};
    let mut child = std::process::Command::new(program)
        .args(args)
        .env("FLIGHTDECK_INDEX_NO_START", "1")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("cannot run it: {e}"))?;
    let init = r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"switchover","version":"0"}}}"#;
    let mut stdin = child.stdin.take().expect("piped");
    writeln!(stdin, "{init}").map_err(|e| e.to_string())?;
    drop(stdin); // end of input: the server answers what it has and exits
    let mut stdout = child.stdout.take().expect("piped");
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut text = String::new();
        let _ = stdout.read_to_string(&mut text);
        let _ = tx.send(text);
    });
    let reply = rx.recv_timeout(std::time::Duration::from_secs(10)).map_err(|_| {
        let _ = child.kill();
        "no answer to initialize within 10 s".to_string()
    })?;
    let _ = child.wait();
    if reply.contains("\"serverInfo\"") {
        Ok(())
    } else {
        Err(format!("it did not answer initialize like an MCP server: {}", reply.trim()))
    }
}

/// After apply: the installed binary and the alias answer as MCP servers, and every config reads
/// as intended.
fn verify(o: &Options) -> Result<String> {
    let mut out = String::from("verified:\n");
    smoke_mcp(&o.installed(), &["mcp", "--no-start"]).map_err(|e| Error::Msg(format!("{} mcp: {e}", o.installed().display())))?;
    let _ = writeln!(out, "  {} mcp answers initialize", o.installed().display());
    smoke_mcp(&o.alias(), &[]).map_err(|e| Error::Msg(format!("{} (the alias): {e}", o.alias().display())))?;
    let _ = writeln!(out, "  {} (the alias) answers initialize", o.alias().display());
    for t in json_targets(&o.home) {
        let doc = io(&t.file, std::fs::read_to_string(&t.file))?;
        let p = plan_json(&doc, &o.command_word(), &o.installed().to_string_lossy(), t.hooks, t.servers)?;
        if !p.edits.is_empty() {
            return Err(Error::Msg(format!("{} still has qartez entries after the edit (something rewrote it); run --apply again when it is quiet", t.file.display())));
        }
        let _ = writeln!(out, "  {} parses and has no qartez hook or server left", t.file.display());
    }
    let codex = o.home.join(".codex/config.toml");
    if codex.is_file() {
        let doc = io(&codex, std::fs::read_to_string(&codex))?;
        if !plan_toml(&doc, &o.installed().to_string_lossy()).1.is_empty() {
            return Err(Error::Msg(format!("{} still runs the qartez binary", codex.display())));
        }
        let _ = writeln!(out, "  {} runs fdindex mcp", codex.display());
    }
    Ok(out)
}

// ---- rollback -------------------------------------------------------------------------------------

pub fn rollback(o: &Options, manifest: Option<&Path>) -> Result<String> {
    let path = match manifest {
        Some(p) => p.to_path_buf(),
        None => latest_manifest(&o.backups())?,
    };
    let text = io(&path, std::fs::read_to_string(&path))?;
    let mut m: Manifest = serde_json::from_str(&text).map_err(|e| Error::Msg(format!("{}: {e}", path.display())))?;
    if let Some(when) = &m.rolled_back {
        return Ok(format!("{} was already rolled back ({when}).\n", path.display()));
    }
    let dir = path.parent().expect("has a parent").to_path_buf();
    let report = rollback_manifest(o, &mut m, &dir)?;
    let text = serde_json::to_string_pretty(&m).map_err(|e| Error::Msg(e.to_string()))?;
    io(&path, std::fs::write(&path, text))?;
    Ok(report)
}

fn latest_manifest(backups: &Path) -> Result<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::fs::read_dir(backups).map_err(|_| Error::Msg(format!("no switch-over has been applied (no {})", backups.display())))?.flatten().map(|e| e.path()).collect();
    dirs.sort();
    dirs.into_iter()
        .rev()
        .map(|d| d.join("manifest.json"))
        .find(|p| std::fs::read_to_string(p).ok().and_then(|t| serde_json::from_str::<Manifest>(&t).ok()).is_some_and(|m| m.rolled_back.is_none() && !m.steps.is_empty()))
        .ok_or_else(|| Error::Msg(format!("nothing to roll back in {}", backups.display())))
}

/// Undo `m`'s steps, last first. A step that cannot be undone is reported and the rest still run.
fn rollback_manifest(o: &Options, m: &mut Manifest, dir: &Path) -> Result<String> {
    let mut out = String::new();
    for step in m.steps.iter().rev() {
        let line = match undo(o, step, dir) {
            Ok(l) => l,
            Err(e) => format!("could not undo ({e})"),
        };
        let _ = writeln!(out, "  {}: {line}", describe_done(step));
    }
    m.rolled_back = Some(utc_stamp());
    Ok(out)
}

fn undo(o: &Options, step: &Done, dir: &Path) -> Result<String> {
    match step {
        Done::Skill { dir: target, backup } => {
            let from = dir.join(backup);
            let old = PathBuf::from(format!("{}.fdindex-removing", target.display()));
            io(target, std::fs::rename(target, &old))?;
            io(target, copy_tree(&from, target))?;
            io(&old, std::fs::remove_dir_all(&old))?;
            Ok("restored from backup".into())
        }
        Done::Service { label, existed } => {
            if *existed {
                return Ok("the service unit existed before; left installed".into());
            }
            let mut svc = service_for(o);
            svc.label = label.clone();
            svc.uninstall()?;
            Ok("uninstalled".into())
        }
        Done::Symlink { link, backup, target } => {
            if std::fs::read_link(link).is_ok_and(|t| t == Path::new(target)) {
                io(link, std::fs::remove_file(link))?;
            } else if std::fs::symlink_metadata(link).is_ok() {
                return Err(Error::Msg(format!("{} is no longer the symlink apply made; left alone", link.display())));
            }
            match backup {
                Some(b) => {
                    io(b, std::fs::rename(b, link))?;
                    Ok(format!("restored {}", link.display()))
                }
                None => Ok("removed".into()),
            }
        }
        Done::Toml { file, backup, after_sha, recs, .. } => {
            let (bytes, stamp) = io(file, textedit::read_stamped(file))?;
            let original = io(&dir.join(backup), std::fs::read(dir.join(backup)))?;
            if stamp.sha == *after_sha {
                io(file, write_back(file, &original, &stamp))?;
                return Ok("original bytes restored".into());
            }
            let doc = String::from_utf8_lossy(&bytes).to_string();
            let (new, notes) = revert_toml(&doc, recs);
            io(file, write_back(file, new.as_bytes(), &stamp))?;
            Ok(format!("changed since apply: reverted only our lines{}", notes.iter().map(|n| format!("; {n}")).collect::<String>()))
        }
        Done::Json { file, backup, after_sha, recs, .. } => {
            for _ in 0..ATTEMPTS {
                let (bytes, stamp) = io(file, textedit::read_stamped(file))?;
                let original = io(&dir.join(backup), std::fs::read(dir.join(backup)))?;
                let (new, how) = if stamp.sha == *after_sha {
                    (original, "original bytes restored".to_string())
                } else {
                    let (new, notes) = revert_json(&String::from_utf8_lossy(&bytes), recs)?;
                    (new.into_bytes(), format!("changed since apply (a running Claude writes it): reverted only the values we changed{}", notes.iter().map(|n| format!("; {n}")).collect::<String>()))
                };
                if io(file, textedit::replace_file(file, &new, &stamp))? {
                    return Ok(how);
                }
            }
            Err(Error::Msg(format!("{} kept changing; try again when it is quiet", file.display())))
        }
        Done::Binary { dst, backup, sha, installed } => {
            if !*installed {
                return Ok("nothing was installed".into());
            }
            if std::fs::read(dst).map(|b| textedit::sha1_hex(&b)).ok().as_deref() != Some(sha) {
                return Ok(format!("{} is not the binary apply installed; left alone", dst.display()));
            }
            match backup {
                Some(b) => {
                    io(dst, write_atomic(dst, &io(&dir.join(b), std::fs::read(dir.join(b)))?, 0o755))?;
                    Ok("previous binary restored".into())
                }
                None => {
                    io(dst, std::fs::remove_file(dst))?;
                    Ok("removed".into())
                }
            }
        }
    }
}

fn write_back(file: &Path, bytes: &[u8], read: &textedit::Stamp) -> std::io::Result<()> {
    if textedit::replace_file(file, bytes, read)? { Ok(()) } else { Err(std::io::Error::other("it changed while it was being restored; run --rollback again")) }
}

// ---- --list-old-dbs -------------------------------------------------------------------------------

/// Directory names never worth walking into.
const SKIP_DIRS: &[&str] = &["node_modules", ".git", "target", ".build", "Pods", ".venv", "_build", "deps", "DerivedData", ".Trash", "Library"];

/// Every `.qartez/index.db` under `roots` with its size (the database plus its `-wal` and `-shm`),
/// largest first. Nothing is deleted: that is a separate, deliberate step.
pub fn list_old_dbs(roots: &[PathBuf]) -> String {
    let mut found: Vec<(u64, PathBuf)> = Vec::new();
    for root in roots {
        let walker = ignore::WalkBuilder::new(root).hidden(false).git_ignore(false).git_global(false).git_exclude(false).ignore(false).parents(false).filter_entry(|e| !SKIP_DIRS.contains(&e.file_name().to_string_lossy().as_ref())).build();
        for entry in walker.flatten() {
            if entry.file_name() == "index.db" && entry.path().parent().is_some_and(|p| p.file_name().is_some_and(|n| n == ".qartez")) {
                let db = entry.path().to_path_buf();
                let size: u64 = ["", "-wal", "-shm"].iter().filter_map(|s| std::fs::metadata(format!("{}{s}", db.display())).ok()).map(|m| m.len()).sum();
                found.push((size, db));
            }
        }
    }
    found.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    found.dedup_by(|a, b| a.1 == b.1);
    let total: u64 = found.iter().map(|f| f.0).sum();
    let mut out = String::new();
    for (size, db) in &found {
        let _ = writeln!(out, "{:>10}  {}", human_size(*size), db.display());
    }
    let _ = writeln!(out, "{} database(s), {} in all, under {}", found.len(), human_size(total), roots.iter().map(|r| r.display().to_string()).collect::<Vec<_>>().join(", "));
    let _ = writeln!(out, "Nothing was deleted. To remove one: rm -r <its .qartez directory> (the directory also holds acks and a lock).");
    out
}

fn human_size(b: u64) -> String {
    if b >= 1 << 30 { format!("{:.1} GB", b as f64 / (1u64 << 30) as f64) } else { format!("{:.1} MB", b as f64 / (1u64 << 20) as f64) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hooks_keep_their_flags_and_only_qartez_hooks_change() {
        let fd = "/h/.local/bin/fdindex";
        assert_eq!(rewrite_hook("/Users/n/.local/bin/qartez-guard", fd).as_deref(), Some("/h/.local/bin/fdindex guard"));
        assert_eq!(rewrite_hook("/x/qartez-guard --pagerank-min 0.1", fd).as_deref(), Some("/h/.local/bin/fdindex guard --pagerank-min 0.1"));
        assert_eq!(rewrite_hook("/x/qartez-setup --session-start", fd).as_deref(), Some("/h/.local/bin/fdindex session-start"));
        assert_eq!(rewrite_hook("/x/qartez-setup --update", fd), None);
        assert_eq!(rewrite_hook("/x/grep-guard", fd), None);
        assert_eq!(rewrite_hook("[ -n \"$X\" ] && notify.sh || true", fd), None);
    }

    #[test]
    fn a_server_entry_changes_command_and_args_and_nothing_else() {
        let doc = "{\n  \"keep\": 1.50,\n  \"mcpServers\": {\n    \"other\": {\"command\": \"npx\", \"args\": []},\n    \"qartez\": {\n      \"args\": [],\n      \"command\": \"/h/.local/bin/qartez\",\n      \"env\": {}\n    }\n  }\n}\n";
        let p = plan_json(doc, "/h/.local/bin/fdindex", "/h/.local/bin/fdindex", false, &[&["mcpServers", "qartez"]]).unwrap();
        let new = textedit::apply(doc, &p.edits);
        assert_eq!(new, doc.replace("\"args\": [],\n      \"command\": \"/h/.local/bin/qartez\"", "\"args\": [\"mcp\"],\n      \"command\": \"/h/.local/bin/fdindex\""));
        // Planned again on the result: nothing left to do.
        assert!(plan_json(&new, "/h/.local/bin/fdindex", "/h/.local/bin/fdindex", false, &[&["mcpServers", "qartez"]]).unwrap().edits.is_empty());
        let (back, notes) = revert_json(&new, &p.recs).unwrap();
        assert_eq!((back, notes.len()), (doc.to_string(), 0));
    }

    #[test]
    fn opencode_keeps_its_command_array_layout() {
        let doc = "{\n  \"mcp\": {\n    \"qartez\": {\n      \"command\": [\n        \"/h/.local/bin/qartez\"\n      ],\n      \"enabled\": false\n    }\n  }\n}\n";
        let p = plan_json(doc, "fd", "/h/.local/bin/fdindex", false, &[&["mcp", "qartez"]]).unwrap();
        let new = textedit::apply(doc, &p.edits);
        assert_eq!(new, "{\n  \"mcp\": {\n    \"qartez\": {\n      \"command\": [\n        \"/h/.local/bin/fdindex\",\n        \"mcp\"\n      ],\n      \"enabled\": false\n    }\n  }\n}\n");
        assert_eq!(revert_json(&new, &p.recs).unwrap().0, doc);
    }

    #[test]
    fn a_reverted_file_that_changed_meanwhile_keeps_the_other_changes() {
        let doc = "{\"hooks\": {\"PreToolUse\": [{\"hooks\": [{\"command\": \"/x/qartez-guard\"}]}]}, \"n\": 1}";
        let p = plan_json(doc, "/f/fdindex", "/f/fdindex", true, &[]).unwrap();
        let new = textedit::apply(doc, &p.edits);
        assert!(new.contains("\"/f/fdindex guard\""));
        let later = new.replace("\"n\": 1", "\"n\": 2, \"added\": true");
        let (back, notes) = revert_json(&later, &p.recs).unwrap();
        assert_eq!(back, doc.replace("\"n\": 1", "\"n\": 2, \"added\": true"));
        assert!(notes.is_empty());
        // A value somebody changed in the meantime is not put back over their change.
        let (kept, notes) = revert_json(&new.replace("/f/fdindex guard", "/z/else"), &p.recs).unwrap();
        assert!(kept.contains("/z/else") && notes.len() == 1, "{kept} {notes:?}");
    }

    #[test]
    fn codex_changes_only_the_two_lines_of_the_qartez_table() {
        let doc = "model = \"x\"\n# <qartez-mcp-begin>\n[mcp_servers.qartez]\ncommand = \"/h/.local/bin/qartez\"\nargs = []\n\n[mcp_servers.qartez.tools.qartez_project]\napproval_mode = \"approve\"\n\n[other]\ncommand = \"/h/.local/bin/qartez\"\nargs = []\n";
        let (new, recs, _) = plan_toml(doc, "/h/.local/bin/fdindex");
        assert_eq!(new, doc.replacen("command = \"/h/.local/bin/qartez\"\nargs = []", "command = \"/h/.local/bin/fdindex\"\nargs = [\"mcp\"]", 1));
        assert_eq!(recs.len(), 2);
        assert!(plan_toml(&new, "/h/.local/bin/fdindex").1.is_empty());
        assert_eq!(revert_toml(&new, &recs).0, doc);
    }

    #[test]
    fn crlf_and_missing_final_newline_survive_in_toml() {
        let doc = "[mcp_servers.qartez]\r\ncommand = \"/h/qartez\"\r\nargs = []";
        let (new, recs, _) = plan_toml(doc, "/h/fdindex");
        assert_eq!(new, "[mcp_servers.qartez]\r\ncommand = \"/h/fdindex\"\r\nargs = [\"mcp\"]");
        assert_eq!(revert_toml(&new, &recs).0, doc);
    }

    #[test]
    fn the_stamp_is_a_utc_date() {
        let s = utc_stamp();
        assert_eq!(s.len(), 15);
        assert!(s.starts_with("20"), "{s}");
    }
}
