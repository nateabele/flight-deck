//! `fdindex guard`: the PreToolUse hook that replaces `qartez-guard` (spec §11a step 8). It keeps
//! the old hook's observable contract, characterised from the binary as a black box (contract doc,
//! "The acknowledgement gate"), and changes only where its facts come from: PageRank and blast
//! radius are asked of the daemon (the view that holds the edited file) instead of read from
//! `<root>/.qartez/index.db`, and the acks are the ones the `impact` tool writes (`ack.rs`).
//!
//! What the old hook does, which this keeps:
//!
//! - It reads Claude Code's PreToolUse JSON on stdin and answers on stdout with a
//!   `hookSpecificOutput` object that denies, or with nothing to allow. The exit status is always 0.
//! - `Glob` and `Grep` (Gemini's `glob` and `grep_search` too; the old hook words `grep_search` like `Glob`) are denied whenever the working
//!   directory is in an indexed project, whatever the pattern: the message routes the agent to the
//!   index tools. Not indexed, nothing is said.
//! - `Edit`, `Write`, `MultiEdit` (Gemini's `replace` and `write_file`) of a file whose PageRank
//!   is at least `--pagerank-min` (env `QARTEZ_GUARD_PAGERANK_MIN`, default 0.05) or whose blast
//!   radius is at least `--blast-min` (`QARTEZ_GUARD_BLAST_MIN`, default 10) are denied unless an
//!   ack for the file is no older than `--ack-ttl-secs` (`QARTEZ_GUARD_ACK_TTL_SECS`, default 600).
//!   A file the index does not know (a new file, a README) is not guarded.
//! - `QARTEZ_GUARD_DISABLE` set to anything but empty, `0` or `false` turns the whole hook off.
//! - Input it cannot make sense of is allowed, silently.
//!
//! What differs, on purpose:
//!
//! - **The index being unavailable never blocks an agent.** The daemon not running, not answering,
//!   or still building the view allows the call and says why on stderr. The old hook had nothing
//!   comparable to fail: it read a file.
//! - A file in any worktree is judged by that worktree's view and its acks (`<worktree>/.qartez/acks`),
//!   found from the file's path through the daemon, not from the project directory the session
//!   started in. `$CLAUDE_PROJECT_DIR` and `--project-root` only stand in for a missing `cwd`.
//! - `--db` is accepted and ignored: there is no per-project database any more.
//! - The blast radius is the files that transitively import the file inside its own view and in
//!   the dependent views (repositories whose manifests link into it) whose graphs the daemon
//!   already holds. The `impact` tool builds the linked views it needs; a hook that must answer in
//!   milliseconds never builds, loads or reads git for one, so a dependent nobody has asked about
//!   does not count.

use crate::ack;
use crate::client::{unreachable_message, Client};
use crate::runtime::Paths;
use serde_json::{json, Map, Value};
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

pub const DEFAULT_PAGERANK_MIN: f64 = 0.05;
pub const DEFAULT_BLAST_MIN: usize = 10;
/// How long the hook waits for the daemon before it gives up and allows the call.
const DAEMON_TIMEOUT: Duration = Duration::from_millis(2500);
/// How long the daemon may spend building a view that is not ready before the hook allows the call.
const BUILD_WAIT_MS: u64 = 1500;

const GLOB_ROUTE: &str = "STOP: qartez MCP is available. Use `qartez_map` for project structure or `qartez_find` to locate symbols. Use Glob ONLY for non-code file patterns (e.g., *.toml, *.json) — if so, use Bash find/ls instead.";
const GREP_ROUTE: &str = "STOP: qartez MCP is available. Use `qartez_grep` for symbol search or `qartez_find` for definitions. Use Grep ONLY for non-symbol text search (e.g., TODO comments, string literals) — if so, use Bash grep instead.";

#[derive(Debug, Clone)]
pub struct Settings {
    pub pagerank_min: f64,
    pub blast_min: usize,
    pub ack_ttl: Duration,
    /// `--project-root`: only a stand-in for a `cwd` the hook input lacks.
    pub project_root: Option<String>,
}

impl Settings {
    /// Flags win over the environment, which wins over the defaults, as the old hook's did.
    pub fn from(flags: &Map<String, Value>, env: &dyn Fn(&str) -> Option<String>) -> Settings {
        let flag = |k: &str| flags.get(k).and_then(|v| v.as_str().map(str::to_string));
        let number = |k: &str, vars: &[&str]| flag(k).or_else(|| vars.iter().find_map(|v| env(v)));
        Settings {
            pagerank_min: number("pagerank_min", &["QARTEZ_GUARD_PAGERANK_MIN"]).and_then(|v| v.trim().parse().ok()).unwrap_or(DEFAULT_PAGERANK_MIN),
            blast_min: number("blast_min", &["QARTEZ_GUARD_BLAST_MIN"]).and_then(|v| v.trim().parse().ok()).unwrap_or(DEFAULT_BLAST_MIN),
            ack_ttl: number("ack_ttl_secs", &["QARTEZ_GUARD_ACK_TTL_SECS", "QARTEZ_ACK_TTL_SECS"]).and_then(|v| v.trim().parse().ok()).map(Duration::from_secs).unwrap_or(ack::DEFAULT_TTL),
            project_root: flag("project_root"),
        }
    }
}

/// What the hook knows about its surroundings besides stdin.
pub struct Env {
    pub disable: Option<String>,
    pub project_dir: Option<String>,
    pub process_cwd: String,
}

impl Env {
    pub fn current() -> Env {
        Env {
            disable: std::env::var("QARTEZ_GUARD_DISABLE").ok(),
            project_dir: std::env::var("CLAUDE_PROJECT_DIR").ok().filter(|v| !v.is_empty()),
            process_cwd: std::env::current_dir().map(|p| p.to_string_lossy().to_string()).unwrap_or_default(),
        }
    }
}

/// What the hook prints. The exit status is 0 whatever the verdict.
#[derive(Debug, Default, PartialEq)]
pub struct Verdict {
    pub stdout: String,
    pub stderr: String,
}

/// The daemon's side of a guard decision.
pub trait Index {
    /// `Err` when the daemon cannot be reached or does not answer; the text says why.
    fn lookup(&mut self, cwd: &str, file: Option<&str>) -> Result<Value, String>;
}

/// The real thing: one connection to the daemon's socket, never started from here (a hook that
/// forks a daemon on a cold machine would eat its own timeout).
pub struct Socket {
    pub paths: Paths,
}

impl Index for Socket {
    fn lookup(&mut self, cwd: &str, file: Option<&str>) -> Result<Value, String> {
        let mut client = Client::connect(&self.paths.socket).map_err(|e| unreachable_message(&self.paths.socket, &e))?;
        client.set_timeout(DAEMON_TIMEOUT).map_err(|e| e.to_string())?;
        let mut args = Map::new();
        args.insert("build_wait_ms".into(), json!(BUILD_WAIT_MS));
        if let Some(f) = file {
            args.insert("file_path".into(), json!(f));
        }
        let resp = client.call(cwd, 0, "guard", args).map_err(|e| e.to_string())?;
        match (resp.ok, resp.data) {
            (true, Some(d)) => Ok(d),
            _ => Err(format!("the index daemon refused the question: {}{}", resp.state.map(|s| format!("{s}: ")).unwrap_or_default(), resp.error.unwrap_or_default())),
        }
    }
}

fn truthy(v: &Option<String>) -> bool {
    v.as_deref().is_some_and(|v| !matches!(v.trim().to_ascii_lowercase().as_str(), "" | "0" | "false"))
}

enum Kind {
    Search { glob: bool },
    Edit,
}

fn kind(tool: &str) -> Option<Kind> {
    match tool {
        "Edit" | "Write" | "MultiEdit" | "replace" | "write_file" => Some(Kind::Edit),
        t if t.eq_ignore_ascii_case("glob") => Some(Kind::Search { glob: true }),
        t if t.eq_ignore_ascii_case("grep") => Some(Kind::Search { glob: false }),
        // The old hook gives Gemini's `grep_search` the Glob message (it routes to `qartez_map`);
        // kept as it was, since agents were trained on it.
        t if t.eq_ignore_ascii_case("grep_search") => Some(Kind::Search { glob: true }),
        _ => None,
    }
}

fn deny(reason: &str) -> Verdict {
    let out = json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": reason}});
    Verdict { stdout: format!("{out}\n"), stderr: String::new() }
}

fn allow_with(note: impl Into<String>) -> Verdict {
    Verdict { stdout: String::new(), stderr: format!("fdindex guard: {}\n", note.into()) }
}

/// Decide one PreToolUse call. `input` is the hook's stdin.
pub fn decide(input: &str, settings: &Settings, env: &Env, now: SystemTime, index: &mut dyn Index) -> Verdict {
    if truthy(&env.disable) {
        return Verdict::default();
    }
    let Ok(call) = serde_json::from_str::<Value>(input) else { return Verdict::default() };
    let tool = call["tool_name"].as_str().unwrap_or("");
    let Some(kind) = kind(tool) else { return Verdict::default() };
    // The directory relative paths and the project are judged from: what the call says, else what
    // the session was started with.
    let cwd = [call["cwd"].as_str().map(str::to_string), env.project_dir.clone(), settings.project_root.clone(), Some(env.process_cwd.clone())]
        .into_iter()
        .flatten()
        .find(|c| std::path::Path::new(c).is_absolute());
    let Some(cwd) = cwd else { return Verdict::default() };

    let file = match kind {
        Kind::Edit => match call["tool_input"]["file_path"].as_str().filter(|f| !f.is_empty()) {
            Some(f) => Some(f.to_string()),
            None => return Verdict::default(),
        },
        Kind::Search { .. } => None,
    };
    let answer = match index.lookup(&cwd, file.as_deref()) {
        Ok(a) => a,
        Err(why) => return allow_with(format!("{why}; allowing {tool}. `fdindex status` says what is wrong, `fdindex start` starts it.")),
    };
    match answer["state"].as_str().unwrap_or("NONE") {
        "READY" => {}
        "BUILDING" => {
            let (done, total) = (answer["done"].as_u64().unwrap_or(0), answer["total"].as_u64().unwrap_or(0));
            return allow_with(format!("the index of this project is still being built ({done} of {total} files); allowing {tool}"));
        }
        _ => return Verdict::default(),
    }
    match kind {
        Kind::Search { glob } => deny(if glob { GLOB_ROUTE } else { GREP_ROUTE }),
        Kind::Edit => {
            if !answer["in_index"].as_bool().unwrap_or(false) {
                return Verdict::default();
            }
            let (rel, worktree) = (answer["rel"].as_str().unwrap_or(""), answer["worktree"].as_str().unwrap_or(""));
            let pagerank = answer["pagerank"].as_f64().unwrap_or(0.0);
            let blast = answer["blast"].as_u64().unwrap_or(0) as usize;
            let mut reasons = Vec::new();
            if pagerank >= settings.pagerank_min {
                reasons.push(format!("PageRank {pagerank:.4} >= {:.4}", settings.pagerank_min));
            }
            if blast >= settings.blast_min {
                reasons.push(format!("blast radius {blast} >= {}", settings.blast_min));
            }
            if reasons.is_empty() || ack::is_fresh(&PathBuf::from(worktree), rel, settings.ack_ttl, now) {
                return Verdict::default();
            }
            let hot: Vec<String> = answer["hot"].as_array().into_iter().flatten().map(|h| format!("{} (pr={:.3})", h["name"].as_str().unwrap_or(""), h["pr"].as_f64().unwrap_or(0.0))).collect();
            let mut reason = format!(
                "STOP: `{rel}` is load-bearing ({}). Call `qartez_impact` with file_path=\"{rel}\" FIRST to review direct and transitive importers, then retry the edit. Opt out for this project: `QARTEZ_GUARD_DISABLE=1`.",
                reasons.join(", ")
            );
            if !hot.is_empty() {
                reason.push_str(&format!(" Hot symbols in this file: {}.", hot.join(", ")));
            }
            deny(&reason)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake(Result<Value, String>);
    impl Index for Fake {
        fn lookup(&mut self, _: &str, _: Option<&str>) -> Result<Value, String> {
            self.0.clone()
        }
    }

    fn settings() -> Settings {
        Settings::from(&Map::new(), &|_| None)
    }

    fn env() -> Env {
        Env { disable: None, project_dir: None, process_cwd: "/work".into() }
    }

    fn run(input: Value, answer: Result<Value, String>) -> Verdict {
        decide(&input.to_string(), &settings(), &env(), SystemTime::now(), &mut Fake(answer))
    }

    fn edit(path: &str) -> Value {
        json!({"tool_name": "Edit", "cwd": "/work", "tool_input": {"file_path": path}})
    }

    #[test]
    fn flags_beat_the_environment_which_beats_the_defaults() {
        let s = Settings::from(&Map::new(), &|_| None);
        assert_eq!((s.pagerank_min, s.blast_min, s.ack_ttl), (0.05, 10, Duration::from_secs(600)));
        let env = |k: &str| match k {
            "QARTEZ_GUARD_PAGERANK_MIN" => Some("0.2".to_string()),
            "QARTEZ_GUARD_ACK_TTL_SECS" => Some("50".to_string()),
            _ => None,
        };
        let flags: Map<String, Value> = [("blast_min".to_string(), json!("3")), ("pagerank_min".to_string(), json!("0.9"))].into_iter().collect();
        let s = Settings::from(&flags, &env);
        assert_eq!((s.pagerank_min, s.blast_min, s.ack_ttl), (0.9, 3, Duration::from_secs(50)));
        assert_eq!(Settings::from(&Map::new(), &env).pagerank_min, 0.2);
    }

    #[test]
    fn disable_follows_the_old_hooks_truthiness() {
        for (v, off) in [("1", true), ("true", true), ("yes", true), ("0", false), ("false", false), ("", false)] {
            let e = Env { disable: Some(v.into()), ..env() };
            let out = decide(&edit("/work/a.rs").to_string(), &settings(), &e, SystemTime::now(), &mut Fake(Err("down".into())));
            assert_eq!(out.stderr.is_empty(), off, "QARTEZ_GUARD_DISABLE={v:?}");
        }
    }

    #[test]
    fn unreadable_input_and_other_tools_are_allowed_silently() {
        for input in ["", "garbage", "{}", r#"{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/work"}"#, r#"{"tool_name":"Edit","cwd":"/work"}"#] {
            assert_eq!(decide(input, &settings(), &env(), SystemTime::now(), &mut Fake(Err("must not be asked".into()))), Verdict::default(), "{input}");
        }
    }

    #[test]
    fn the_daemon_being_down_allows_and_says_so_on_stderr() {
        let v = run(edit("/work/a.rs"), Err("the index daemon is not running (No such file)".into()));
        assert_eq!(v.stdout, "");
        assert!(v.stderr.starts_with("fdindex guard: the index daemon is not running"), "{}", v.stderr);
        assert!(v.stderr.contains("allowing Edit"));
        let v = run(json!({"tool_name": "Glob", "cwd": "/work", "tool_input": {"pattern": "*.rs"}}), Err("down".into()));
        assert_eq!(v.stdout, "");
    }

    #[test]
    fn a_view_still_building_allows_and_says_so() {
        let v = run(edit("/work/a.rs"), Ok(json!({"state": "BUILDING", "done": 3, "total": 90})));
        assert_eq!(v.stdout, "");
        assert!(v.stderr.contains("3 of 90 files"), "{}", v.stderr);
    }

    #[test]
    fn glob_and_grep_are_routed_to_the_index_only_when_it_is_ready() {
        let ready = json!({"state": "READY"});
        let glob = run(json!({"tool_name": "Glob", "cwd": "/work", "tool_input": {"pattern": "**/*.toml"}}), Ok(ready.clone()));
        assert_eq!(glob.stdout, format!("{}\n", json!({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": GLOB_ROUTE}})));
        assert!(glob.stdout.starts_with(r#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"STOP: qartez MCP is available."#));
        let grep = run(json!({"tool_name": "Grep", "cwd": "/work", "tool_input": {"pattern": "x"}}), Ok(ready.clone()));
        assert!(grep.stdout.contains("Use `qartez_grep` for symbol search"));
        let gemini = run(json!({"tool_name": "grep_search", "cwd": "/work", "tool_input": {"pattern": "x"}}), Ok(ready));
        assert!(gemini.stdout.contains("Use `qartez_map` for project structure"), "the old hook gives grep_search the Glob message");
        let none = run(json!({"tool_name": "Grep", "cwd": "/work", "tool_input": {"pattern": "x"}}), Ok(json!({"state": "NONE"})));
        assert_eq!(none, Verdict::default());
    }

    fn hub(pagerank: f64, blast: u64, worktree: &str) -> Value {
        json!({"state": "READY", "in_index": true, "rel": "src/core.ts", "worktree": worktree, "pagerank": pagerank, "blast": blast,
               "hot": [{"name": "core", "pr": 0.433}, {"name": "core2", "pr": 0.071}]})
    }

    #[test]
    fn a_load_bearing_edit_is_denied_in_the_old_wording_with_both_reasons() {
        let v = run(edit("/work/src/core.ts"), Ok(hub(0.4675, 20, "/nonexistent")));
        let reason: Value = serde_json::from_str(&v.stdout).unwrap();
        assert_eq!(
            reason["hookSpecificOutput"]["permissionDecisionReason"],
            "STOP: `src/core.ts` is load-bearing (PageRank 0.4675 >= 0.0500, blast radius 20 >= 10). Call `qartez_impact` with file_path=\"src/core.ts\" FIRST to review direct and transitive importers, then retry the edit. Opt out for this project: `QARTEZ_GUARD_DISABLE=1`. Hot symbols in this file: core (pr=0.433), core2 (pr=0.071)."
        );
        let blast_only = run(edit("/work/src/core.ts"), Ok(hub(0.01, 10, "/nonexistent")));
        assert!(blast_only.stdout.contains("load-bearing (blast radius 10 >= 10)"), "{}", blast_only.stdout);
        let rank_only = run(edit("/work/src/core.ts"), Ok(hub(0.05, 9, "/nonexistent")));
        assert!(rank_only.stdout.contains("load-bearing (PageRank 0.0500 >= 0.0500)"));
        assert_eq!(run(edit("/work/src/core.ts"), Ok(hub(0.049, 9, "/nonexistent"))), Verdict::default());
    }

    #[test]
    fn a_fresh_ack_in_the_views_worktree_lets_the_edit_through() {
        let dir = tempfile::tempdir().unwrap();
        let wt = dir.path().to_str().unwrap();
        assert!(!run(edit("/work/src/core.ts"), Ok(hub(0.4, 20, wt))).stdout.is_empty());
        ack::write(dir.path(), "src/core.ts").unwrap();
        assert_eq!(run(edit("/work/src/core.ts"), Ok(hub(0.4, 20, wt))), Verdict::default());
        // An ack for another file does not count.
        let other = tempfile::tempdir().unwrap();
        ack::write(other.path(), "src/other.ts").unwrap();
        assert!(!run(edit("/work/src/core.ts"), Ok(hub(0.4, 20, other.path().to_str().unwrap()))).stdout.is_empty());
    }

    #[test]
    fn a_file_the_index_does_not_know_is_not_guarded() {
        assert_eq!(run(edit("/work/README.md"), Ok(json!({"state": "READY", "in_index": false}))), Verdict::default());
    }

    #[test]
    fn a_relative_path_needs_an_absolute_cwd_from_somewhere() {
        let no_cwd = json!({"tool_name": "Edit", "tool_input": {"file_path": "a.rs"}});
        let e = Env { process_cwd: String::new(), ..env() };
        assert_eq!(decide(&no_cwd.to_string(), &settings(), &e, SystemTime::now(), &mut Fake(Err("asked".into()))), Verdict::default());
        let e = Env { project_dir: Some("/proj".into()), process_cwd: String::new(), ..env() };
        assert!(!decide(&no_cwd.to_string(), &settings(), &e, SystemTime::now(), &mut Fake(Err("asked".into()))).stderr.is_empty());
    }
}
