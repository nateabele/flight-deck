mod common;
use common::*;
use serde_json::{json, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

const BIN: &str = env!("CARGO_BIN_EXE_fdindex");

struct Daemon {
    _dir: tempfile::TempDir,
    store: PathBuf,
    socket: PathBuf,
}

impl Daemon {
    fn new() -> Daemon {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        Daemon { store: root.join("store"), socket: root.join("d.sock"), _dir: dir }
    }

    fn cmd(&self, args: &[&str]) -> Command {
        let mut c = Command::new(BIN);
        c.args(["--store", self.store.to_str().unwrap(), "--socket", self.socket.to_str().unwrap()]).args(args);
        c
    }

    fn run(&self, cwd: &Path, args: &[&str]) -> Output {
        self.cmd(args).current_dir(cwd).output().unwrap()
    }

    /// Run a hook with `input` on stdin and the given env.
    fn hook(&self, verb: &str, input: &str, env: &[(&str, &str)], flags: &[&str]) -> Output {
        let mut c = self.cmd(&[verb]);
        c.args(flags).env_remove("QARTEZ_GUARD_DISABLE").env_remove("CLAUDE_PROJECT_DIR").envs(env.iter().copied());
        let mut child = c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
        child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
        child.wait_with_output().unwrap()
    }

    fn start_and_build(&self, repo: &Path) {
        assert!(self.run(repo, &["hello"]).status.success());
        let o = self.run(repo, &["build", repo.to_str().unwrap(), "--wait-ms", "60000"]);
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.cmd(&["stop"]).output();
    }
}

/// `core.ts` is imported by `importers` files (so it is both the PageRank hub and has a blast
/// radius of `importers`); `leaf.ts` is imported by nobody.
fn project(importers: usize) -> Repo {
    let r = init_repo();
    write(&r.root, "src/core.ts", "export function core() { return 1 }\n");
    write(&r.root, "src/leaf.ts", "export const leaf = 1\n");
    write(&r.root, "README.md", "# readme\n");
    for i in 0..importers {
        write(&r.root, &format!("src/u{i}.ts"), &format!("import {{ core }} from './core'\nexport const u{i} = () => core()\n"));
    }
    commit_all(&r.root, "init");
    r
}

fn call(tool: &str, file: &Path, cwd: &Path) -> String {
    json!({"session_id": "s", "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": {"file_path": file, "pattern": "x"}, "cwd": cwd}).to_string()
}

fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).to_string()
}

fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).to_string()
}

fn reason(o: &Output) -> String {
    let v: Value = serde_json::from_str(&stdout(o)).unwrap_or_else(|e| panic!("not a denial ({e}): {:?}", stdout(o)));
    assert_eq!(v["hookSpecificOutput"]["hookEventName"], "PreToolUse");
    assert_eq!(v["hookSpecificOutput"]["permissionDecision"], "deny");
    v["hookSpecificOutput"]["permissionDecisionReason"].as_str().unwrap().to_string()
}

#[test]
fn an_edit_of_a_load_bearing_file_is_denied_until_impact_acknowledges_it() {
    let r = project(12);
    let d = Daemon::new();
    d.start_and_build(&r.root);
    let core = r.root.join("src/core.ts");

    let denied = d.hook("guard", &call("Edit", &core, &r.root), &[], &[]);
    assert_eq!(denied.status.code(), Some(0));
    let why = reason(&denied);
    assert!(why.starts_with("STOP: `src/core.ts` is load-bearing (PageRank "), "{why}");
    assert!(why.contains("blast radius 12 >= 10"), "{why}");
    assert!(why.contains("Call `qartez_impact` with file_path=\"src/core.ts\" FIRST"), "{why}");
    assert!(why.contains("Hot symbols in this file: core (pr="), "{why}");
    assert!(stdout(&denied).ends_with("}}\n"));

    // `impact` writes the old guard's ack in the view's worktree: fnv1a64 name, "<secs>\n<rel>\n".
    let o = d.run(&r.root, &["impact", "src/core.ts"]);
    assert!(o.status.success(), "{}", stderr(&o));
    let ack = r.root.join(".qartez/acks").join(format!("{:016x}", flightindex::ack::fnv1a64("src/core.ts")));
    let body = std::fs::read_to_string(&ack).unwrap();
    assert!(body.ends_with("\nsrc/core.ts\n") && body.split('\n').next().unwrap().parse::<u64>().is_ok(), "{body:?}");

    for tool in ["Edit", "Write", "MultiEdit", "replace"] {
        let allowed = d.hook("guard", &call(tool, &core, &r.root), &[], &[]);
        assert_eq!((allowed.status.code(), stdout(&allowed), stderr(&allowed)), (Some(0), String::new(), String::new()), "{tool}");
    }
    // A file with neither a high rank nor a wide blast radius was never guarded.
    assert_eq!(stdout(&d.hook("guard", &call("Edit", &r.root.join("src/leaf.ts"), &r.root), &[], &[])), "");
}

#[test]
fn thresholds_unknown_files_disable_and_other_tools() {
    let r = project(12);
    let d = Daemon::new();
    d.start_and_build(&r.root);
    let core = r.root.join("src/core.ts");
    let edit = call("Edit", &core, &r.root);
    // Flags and env raise the bar; the blast radius (12) alone still trips its own threshold.
    assert!(stdout(&d.hook("guard", &edit, &[], &["--pagerank-min", "0.99"])).contains("blast radius 12 >= 10"));
    assert_eq!(stdout(&d.hook("guard", &edit, &[("QARTEZ_GUARD_PAGERANK_MIN", "0.99")], &["--blast-min", "13"])), "");
    assert!(stdout(&d.hook("guard", &edit, &[], &["--pagerank-min", "0.99", "--blast-min", "12"])).contains("blast radius 12 >= 12"));
    // `--db` is accepted and ignored.
    assert!(!stdout(&d.hook("guard", &edit, &[], &["--db", "/nowhere/index.db"])).is_empty());
    // Not guarded: a file the index does not know, a new file, QARTEZ_GUARD_DISABLE, other tools.
    for (tool, file) in [("Edit", "README.md"), ("Write", "src/brand_new.ts")] {
        assert_eq!(stdout(&d.hook("guard", &call(tool, &r.root.join(file), &r.root), &[], &[])), "", "{file}");
    }
    assert_eq!(stdout(&d.hook("guard", &edit, &[("QARTEZ_GUARD_DISABLE", "1")], &[])), "");
    assert_eq!(stdout(&d.hook("guard", &call("Read", &core, &r.root), &[], &[])), "");
    assert_eq!(stdout(&d.hook("guard", "not json", &[], &[])), "");
    // A relative path resolves against the call's cwd, and a missing cwd against $CLAUDE_PROJECT_DIR.
    let rel = json!({"tool_name": "Edit", "tool_input": {"file_path": "src/core.ts"}, "cwd": r.root}).to_string();
    assert!(!stdout(&d.hook("guard", &rel, &[], &[])).is_empty());
    let no_cwd = json!({"tool_name": "Edit", "tool_input": {"file_path": "src/core.ts"}}).to_string();
    assert!(!stdout(&d.hook("guard", &no_cwd, &[("CLAUDE_PROJECT_DIR", r.root.to_str().unwrap())], &[])).is_empty());
}

#[test]
fn glob_and_grep_are_routed_to_the_index_in_an_indexed_project_only() {
    let r = project(2);
    let plain = tempfile::tempdir().unwrap();
    let plain_dir = plain.path().canonicalize().unwrap();
    let d = Daemon::new();
    d.start_and_build(&r.root);
    assert!(reason(&d.hook("guard", &call("Glob", &r.root, &r.root), &[], &[])).contains("Use `qartez_map` for project structure"));
    assert!(reason(&d.hook("guard", &call("Grep", &r.root, &r.root), &[], &[])).contains("Use `qartez_grep` for symbol search"));
    assert!(reason(&d.hook("guard", &call("glob", &r.root, &r.root.join("src")), &[], &[])).contains("qartez_map"));
    assert!(reason(&d.hook("guard", &call("grep_search", &r.root, &r.root), &[], &[])).contains("qartez_map"));
    // A directory that is no project is nobody's index: nothing is said, and nothing is built.
    let o = d.hook("guard", &call("Glob", &plain_dir, &plain_dir), &[], &[]);
    assert_eq!((stdout(&o), stderr(&o)), (String::new(), String::new()));
}

#[test]
fn a_daemon_that_is_down_never_blocks_the_agent() {
    let r = project(12);
    let d = Daemon::new(); // never started
    for tool in ["Edit", "Glob", "Grep"] {
        let o = d.hook("guard", &call(tool, &r.root.join("src/core.ts"), &r.root), &[], &[]);
        assert_eq!((o.status.code(), stdout(&o)), (Some(0), String::new()), "{tool}");
        let err = stderr(&o);
        assert!(err.starts_with("fdindex guard: the index daemon is not running") && err.contains(&format!("allowing {tool}")), "{err}");
    }
    // And the guard did not start one.
    assert!(!d.socket.exists());
}

#[test]
fn session_start_warms_the_view_prints_nothing_when_all_is_well_and_never_fails() {
    let r = project(2);
    let d = Daemon::new();
    let input = json!({"session_id": "s", "hook_event_name": "SessionStart", "source": "startup", "cwd": r.root}).to_string();
    let o = d.hook("session-start", &input, &[], &[]);
    assert_eq!(o.status.code(), Some(0), "{}", stderr(&o));
    // The daemon is up now, and the build it started finishes by itself.
    assert!(d.socket.exists());
    let o = d.run(&r.root, &["status"]);
    assert!(o.status.success(), "{}", stderr(&o));
    let ready = (0..100).any(|_| {
        std::thread::sleep(std::time::Duration::from_millis(100));
        d.run(&r.root, &["stats"]).status.success() && !stdout(&d.run(&r.root, &["stats"])).contains("index: building")
    });
    assert!(ready, "the session's view never finished building");
    assert_eq!(stdout(&d.hook("session-start", &input, &[], &[])), "");
    // A directory that is no project: silent, and not indexed.
    let plain = tempfile::tempdir().unwrap();
    let elsewhere = json!({"cwd": plain.path().canonicalize().unwrap()}).to_string();
    let o = d.hook("session-start", &elsewhere, &[], &[]);
    assert_eq!((o.status.code(), stdout(&o)), (Some(0), String::new()));
    // No stdin content at all still works, from $CLAUDE_PROJECT_DIR.
    let o = d.hook("session-start", "", &[("CLAUDE_PROJECT_DIR", r.root.to_str().unwrap())], &[]);
    assert_eq!((o.status.code(), stdout(&o)), (Some(0), String::new()));
}

#[test]
fn session_start_says_so_when_the_daemon_cannot_start_and_still_exits_zero() {
    let r = project(1);
    let dir = tempfile::tempdir().unwrap();
    // A store under a regular file cannot be created, so the daemon dies on startup.
    let blocker = dir.path().join("file");
    std::fs::write(&blocker, "x").unwrap();
    let mut c = Command::new(BIN);
    c.args(["--store", blocker.join("store").to_str().unwrap(), "--socket", dir.path().join("s.sock").to_str().unwrap(), "session-start"]);
    let mut child = c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    child.stdin.take().unwrap().write_all(json!({"cwd": r.root}).to_string().as_bytes()).unwrap();
    let o = child.wait_with_output().unwrap();
    assert_eq!(o.status.code(), Some(0));
    let out = stdout(&o);
    assert!(out.starts_with("fdindex: the index daemon is not running and could not be started"), "{out}");
    assert!(out.contains("state: UNAVAILABLE") && out.contains("fall back to rg"), "{out}");
}
