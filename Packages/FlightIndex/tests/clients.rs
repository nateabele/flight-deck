//! The clients of the daemon, end to end: the MCP shim over real pipes, the `qartez` invocation
//! name, and the service unit's rendering against the real binary.

mod common;
use common::*;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

const BIN: &str = env!("CARGO_BIN_EXE_fdindex");

struct Env {
    _dir: tempfile::TempDir,
    store: PathBuf,
    socket: PathBuf,
    repo: Repo,
}

impl Env {
    fn new() -> Env {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let repo = init_repo();
        write(&repo.root, "web/a.ts", "export function entry() { return 1; }\n");
        commit_all(&repo.root, "init");
        Env { store: root.join("store"), socket: root.join("d.sock"), _dir: dir, repo }
    }

    fn base(&self, program: &str) -> Command {
        let mut c = Command::new(program);
        c.args(["--store", self.store.to_str().unwrap(), "--socket", self.socket.to_str().unwrap()]);
        c
    }

    fn stop(&self) {
        let _ = self.base(BIN).arg("stop").output();
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        self.stop();
    }
}

struct Session {
    child: Child,
    stdin: ChildStdin,
    out: BufReader<ChildStdout>,
    next: u64,
}

impl Session {
    fn start(env: &Env, program: &str, extra: &[&str]) -> Session {
        let mut child = env.base(program).arg("mcp").args(extra).current_dir(&env.repo.root).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap();
        let stdin = child.stdin.take().unwrap();
        let out = BufReader::new(child.stdout.take().unwrap());
        Session { child, stdin, out, next: 1 }
    }

    fn rpc(&mut self, method: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        writeln!(self.stdin, "{}", json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params})).unwrap();
        let mut line = String::new();
        self.out.read_line(&mut line).unwrap();
        let v: Value = serde_json::from_str(&line).unwrap_or_else(|e| panic!("reply {line:?}: {e}"));
        assert_eq!(v["id"], id);
        v
    }

    fn call(&mut self, tool: &str, args: Value) -> (bool, String) {
        let r = self.rpc("tools/call", json!({"name": tool, "arguments": args}));
        (r["result"]["isError"].as_bool().unwrap(), r["result"]["content"][0]["text"].as_str().unwrap().to_string())
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[test]
fn the_shim_answers_tool_calls_from_the_daemon_with_the_callers_cwd() {
    let env = Env::new();
    let mut s = Session::start(&env, BIN, &[]);
    let init = s.rpc("initialize", json!({"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}));
    assert_eq!(init["result"]["serverInfo"]["name"], "flightdeck-index");
    writeln!(s.stdin, "{}", json!({"jsonrpc": "2.0", "method": "notifications/initialized"})).unwrap();
    assert_eq!(s.rpc("tools/list", json!({}))["result"]["tools"].as_array().unwrap().len(), 19);

    let (err, text) = s.call("qartez_find", json!({"name": "entry"}));
    assert!(!err && text.starts_with("view: ") && text.contains("entry (function)"), "{text}");
    // A path relative to the shim's launch directory, and an absolute one.
    let (err, text) = s.call("qartez_outline", json!({"file_path": "web/a.ts"}));
    assert!(!err && text.contains("entry"), "{text}");
    let abs = env.repo.root.join("web/a.ts");
    let (err, text) = s.call("qartez_read", json!({"file_path": abs.to_str().unwrap(), "start_line": null}));
    assert!(!err && text.contains("export function entry"), "{text}");
    let (err, text) = s.call("qartez_find", json!({"name": "entry", "format": "mermaid"}));
    assert!(err && text.starts_with("state: "), "a daemon refusal keeps its state: {text}");
}

#[test]
fn without_a_daemon_and_with_no_auto_start_every_call_says_unavailable_then_recovers() {
    let env = Env::new();
    let mut s = Session::start(&env, BIN, &["--no-start"]);
    let (err, text) = s.call("qartez_find", json!({"name": "entry"}));
    assert!(err && text.starts_with("state: UNAVAILABLE\n") && text.lines().count() == 2, "{text}");
    assert!(!env.socket.exists(), "no daemon was started behind the caller's back");
    // The daemon comes up (a client starts it); the next call reconnects.
    assert!(Command::new(BIN).args(["--store", env.store.to_str().unwrap(), "--socket", env.socket.to_str().unwrap(), "hello"]).output().unwrap().status.success());
    let (err, text) = s.call("qartez_find", json!({"name": "entry"}));
    assert!(!err && text.contains("entry (function)"), "{text}");
    // It goes away mid-session and comes back: UNAVAILABLE in between, then answers again.
    env.stop();
    let (err, text) = s.call("qartez_find", json!({"name": "entry"}));
    assert!(err && text.starts_with("state: UNAVAILABLE"), "{text}");
    assert!(Command::new(BIN).args(["--store", env.store.to_str().unwrap(), "--socket", env.socket.to_str().unwrap(), "hello"]).output().unwrap().status.success());
    let (err, _) = s.call("qartez_find", json!({"name": "entry"}));
    assert!(!err);
}

#[test]
fn a_daemon_restart_between_calls_is_invisible_to_the_session() {
    let env = Env::new();
    let mut s = Session::start(&env, BIN, &[]);
    let (err, _) = s.call("qartez_find", json!({"name": "entry"}));
    assert!(!err);
    env.stop();
    let (err, text) = s.call("qartez_find", json!({"name": "entry"}));
    assert!(!err && text.contains("entry (function)"), "the shim started a new daemon: {text}");
}

#[test]
fn started_as_qartez_it_is_the_alias() {
    let env = Env::new();
    let bin_dir = tempfile::tempdir().unwrap();
    let alias: PathBuf = bin_dir.path().join("qartez");
    std::os::unix::fs::symlink(BIN, &alias).unwrap();
    // `qartez --root <dir> find …`: the root is the cwd, wherever the process runs.
    let elsewhere = tempfile::tempdir().unwrap();
    let out = env.base(alias.to_str().unwrap()).args(["--root", env.repo.root.to_str().unwrap(), "find", "entry"]).current_dir(elsewhere.path()).output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(out.status.success() && text.contains("entry (function)"), "{text}{}", String::from_utf8_lossy(&out.stderr));
    // `qartez mcp` is the shim.
    let mut s = Session::start(&env, alias.to_str().unwrap(), &[]);
    let (err, text) = s.call("qartez_find", json!({"name": "entry"}));
    assert!(!err && text.contains("entry (function)"), "{text}");
}

#[test]
fn service_status_reports_a_stopped_daemon_and_never_starts_one() {
    let env = Env::new();
    let o = env.base(BIN).args(["service", "status", "--label", "dev.test.nothing"]).env("HOME", env.store.parent().unwrap()).output().unwrap();
    let text = String::from_utf8_lossy(&o.stdout);
    assert_eq!(o.status.code(), Some(3), "{text}");
    assert!(text.contains("not installed") && text.contains("daemon:   not running"), "{text}");
    assert!(!env.socket.exists());
    // Once it runs, the same command reports it.
    assert!(env.base(BIN).arg("hello").output().unwrap().status.success());
    let o = env.base(BIN).args(["status"]).output().unwrap();
    let text = String::from_utf8_lossy(&o.stdout);
    assert!(o.status.success() && text.contains("daemon:   running, pid ") && text.contains("views:"), "{text}");
}
