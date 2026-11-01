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

/// A directory nobody can enter: a connect through it fails with EACCES, as a sandbox's EPERM does.
struct Sealed {
    dir: PathBuf,
}

impl Sealed {
    fn new(env: &Env) -> Sealed {
        let dir = env.store.parent().unwrap().join("sealed");
        std::fs::create_dir(&dir).unwrap();
        std::fs::set_permissions(&dir, std::os::unix::fs::PermissionsExt::from_mode(0o000)).unwrap();
        Sealed { dir }
    }

    fn socket(&self) -> PathBuf {
        self.dir.join("d.sock")
    }
}

impl Drop for Sealed {
    fn drop(&mut self) {
        let _ = std::fs::set_permissions(&self.dir, std::os::unix::fs::PermissionsExt::from_mode(0o755));
    }
}

const SANDBOX: &str = "a sandbox is blocking Unix sockets";

#[test]
fn a_socket_the_sandbox_forbids_is_reported_as_that_and_no_daemon_is_started() {
    let env = Env::new();
    let sealed = Sealed::new(&env);
    let out = Command::new(BIN).args(["--store", env.store.to_str().unwrap(), "--socket", sealed.socket().to_str().unwrap(), "find", "entry"]).current_dir(&env.repo.root).output().unwrap();
    let err = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(3), "{err}");
    assert!(err.starts_with("state: UNAVAILABLE\ncannot connect to ") && err.contains(SANDBOX) && err.contains("fall back to rg"), "{err}");
    assert!(!err.contains("exited on startup"), "{err}");
    assert!(!env.store.exists(), "no daemon was spawned to find out");

    // The MCP shim says the same, with auto-start on.
    let mut child = Command::new(BIN).args(["--store", env.store.to_str().unwrap(), "--socket", sealed.socket().to_str().unwrap(), "mcp"]).current_dir(&env.repo.root).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut out = BufReader::new(child.stdout.take().unwrap());
    writeln!(stdin, "{}", json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "qartez_find", "arguments": {"name": "entry"}}})).unwrap();
    let mut line = String::new();
    out.read_line(&mut line).unwrap();
    let _ = child.kill();
    let _ = child.wait();
    assert!(line.contains("state: UNAVAILABLE") && line.contains(SANDBOX), "{line}");
    assert!(!env.store.exists());

    // The guard still allows, and says why the index is out.
    let mut guard = Command::new(BIN).args(["--store", env.store.to_str().unwrap(), "--socket", sealed.socket().to_str().unwrap(), "guard"]).env_remove("QARTEZ_GUARD_DISABLE").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
    let input = json!({"tool_name": "Edit", "tool_input": {"file_path": env.repo.root.join("web/a.ts")}, "cwd": env.repo.root}).to_string();
    guard.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
    let g = guard.wait_with_output().unwrap();
    assert!(g.status.success() && g.stdout.is_empty(), "{}", String::from_utf8_lossy(&g.stdout));
    assert!(String::from_utf8_lossy(&g.stderr).contains(SANDBOX), "{}", String::from_utf8_lossy(&g.stderr));
}

#[test]
fn no_start_is_honoured_by_every_query_verb() {
    let env = Env::new();
    for (flags, env_var) in [(vec!["--no-start", "find", "entry"], false), (vec!["find", "entry", "--no-start"], false), (vec!["find", "entry"], true), (vec!["--no-start", "map"], false)] {
        let mut c = env.base(BIN);
        c.args(&flags).current_dir(&env.repo.root);
        if env_var {
            c.env("FLIGHTDECK_INDEX_NO_START", "1");
        }
        let out = c.output().unwrap();
        let err = String::from_utf8_lossy(&out.stderr);
        assert_eq!(out.status.code(), Some(3), "{flags:?}: {err}");
        assert!(err.starts_with("state: UNAVAILABLE\n") && err.contains("auto-start is disabled"), "{flags:?}: {err}");
        assert!(!env.socket.exists() && !env.store.exists(), "{flags:?} started a daemon");
    }
}

/// `--help` prints usage and starts nothing. Two agents ran `fdindex daemon --help` expecting
/// help and got a daemon on the real default store.
#[test]
fn help_prints_usage_and_starts_no_daemon() {
    let dir = tempfile::tempdir().unwrap();
    let store = dir.path().join("store");
    for args in [vec!["daemon", "--help"], vec!["--help"], vec!["help"], vec!["find", "--help"]] {
        let mut full = vec!["--store", store.to_str().unwrap()];
        full.extend(args.iter().copied());
        let out = Command::new(BIN).args(&full).output().unwrap();
        assert!(out.status.success(), "{args:?} exits 0");
        assert!(String::from_utf8_lossy(&out.stdout).contains("usage: fdindex"), "{args:?} prints usage");
        assert!(!store.join("daemon.pid").exists() && !store.join("daemon.log").exists(), "{args:?} started a daemon");
    }
}
