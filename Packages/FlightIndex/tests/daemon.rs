mod common;
use common::*;
use flightindex::client::Client;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Output};

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

    fn fdindex(&self, cwd: &std::path::Path, args: &[&str]) -> Output {
        Command::new(BIN).args(["--store", self.store.to_str().unwrap(), "--socket", self.socket.to_str().unwrap()]).args(args).current_dir(cwd).output().unwrap()
    }

    fn stdout(&self, cwd: &std::path::Path, args: &[&str]) -> String {
        let o = self.fdindex(cwd, args);
        assert!(o.status.success(), "{args:?}: {}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr));
        String::from_utf8_lossy(&o.stdout).to_string()
    }

    fn pid(&self, cwd: &std::path::Path) -> u64 {
        // `status` only asks; `hello` is what starts a daemon that is not there.
        self.stdout(cwd, &["hello"]);
        let v: serde_json::Value = serde_json::from_str(&self.stdout(cwd, &["status", "--json"])).unwrap();
        v["data"]["pid"].as_u64().unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = Command::new(BIN).args(["--store", self.store.to_str().unwrap(), "--socket", self.socket.to_str().unwrap(), "stop"]).output();
    }
}

fn repo() -> Repo {
    let r = init_repo();
    write(&r.root, "web/a.ts", "export function entry() { return 1; }\n");
    commit_all(&r.root, "init");
    r
}

#[test]
fn a_query_starts_the_daemon_and_later_queries_reuse_it() {
    let d = Daemon::new();
    let r = repo();
    assert!(!d.socket.exists());
    let out = d.stdout(&r.root, &["find", "entry"]);
    assert!(out.starts_with("view: ") && out.contains("entry (function)"), "{out}");
    assert!(d.socket.exists(), "the client started a daemon");
    let first = d.pid(&r.root);
    d.stdout(&r.root, &["outline", "web/a.ts"]);
    assert_eq!(d.pid(&r.root), first, "one daemon, however many clients");
    assert!(d.store.join("daemon.log").exists(), "it logs next to the store");
}

#[test]
fn a_second_daemon_on_the_same_store_exits_cleanly() {
    let d = Daemon::new();
    let r = repo();
    d.stdout(&r.root, &["hello"]);
    let pid = d.pid(&r.root);
    let o = d.fdindex(&r.root, &["daemon"]);
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    assert!(String::from_utf8_lossy(&o.stderr).contains("already running"));
    assert_eq!(d.pid(&r.root), pid, "the first daemon is untouched");
}

#[test]
fn the_socket_is_private_to_the_user() {
    let d = Daemon::new();
    let r = repo();
    d.stdout(&r.root, &["hello"]);
    let mode = std::fs::metadata(&d.socket).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
}

#[test]
fn a_stale_socket_file_from_a_dead_daemon_does_not_block_a_new_one() {
    let d = Daemon::new();
    let r = repo();
    std::fs::create_dir_all(&d.store).unwrap();
    std::fs::write(&d.socket, b"left over").unwrap();
    assert!(d.stdout(&r.root, &["find", "entry"]).contains("entry (function)"));
}

#[test]
fn bad_input_is_an_error_line_and_the_connection_survives() {
    let d = Daemon::new();
    let r = repo();
    d.stdout(&r.root, &["hello"]);
    let mut s = UnixStream::connect(&d.socket).unwrap();
    s.write_all(b"this is not json\n").unwrap();
    let mut rd = BufReader::new(s.try_clone().unwrap());
    let mut line = String::new();
    rd.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!((v["ok"].as_bool(), v["state"].as_str()), (Some(false), Some("BAD_REQUEST")));
    // Same connection, a good request.
    let req = serde_json::json!({"id": 9, "cwd": r.root, "tool": "find", "args": {"name": "entry"}});
    s.write_all(format!("{req}\n").as_bytes()).unwrap();
    line.clear();
    rd.read_line(&mut line).unwrap();
    let v: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(v["id"], 9);
    assert!(v["ok"].as_bool().unwrap() && v["text"].as_str().unwrap().contains("entry (function)"));
}

#[test]
fn the_client_refuses_a_daemon_that_speaks_another_protocol() {
    let d = Daemon::new();
    let r = repo();
    d.stdout(&r.root, &["hello"]);
    let mut c = Client::connect(&d.socket).unwrap();
    let mut args = serde_json::Map::new();
    args.insert("name".into(), "x".into());
    // A request claiming a newer protocol is refused by the daemon, not guessed at.
    let line = serde_json::json!({"v": 99, "id": 1, "cwd": r.root, "tool": "find", "args": {"name": "x"}});
    let mut s = UnixStream::connect(&d.socket).unwrap();
    s.write_all(format!("{line}\n").as_bytes()).unwrap();
    let mut reply = String::new();
    BufReader::new(s).read_line(&mut reply).unwrap();
    assert!(reply.contains("VERSION_MISMATCH"), "{reply}");
    c.handshake().unwrap();
}

#[test]
fn stop_removes_the_socket_and_a_new_query_starts_a_fresh_daemon() {
    let d = Daemon::new();
    let r = repo();
    let first = d.pid(&r.root);
    assert!(d.stdout(&r.root, &["stop"]).contains("stopped"));
    assert!(!d.socket.exists());
    assert_ne!(d.pid(&r.root), first);
}

#[test]
fn a_socket_path_too_long_for_the_os_is_reported_with_the_fix() {
    let d = Daemon::new();
    let r = repo();
    let long = d.store.join("x".repeat(120)).join("d.sock");
    let o = Command::new(BIN).args(["--store", d.store.to_str().unwrap(), "--socket", long.to_str().unwrap(), "daemon"]).current_dir(&r.root).output().unwrap();
    assert!(!o.status.success());
    assert!(String::from_utf8_lossy(&o.stderr).contains("pass a shorter --socket"));
}

#[test]
fn a_daemon_that_cannot_start_reports_unavailable() {
    let r = repo();
    let o = Command::new(BIN).args(["--store", "/proc/definitely/not/writable", "--socket", "/proc/nope.sock", "find", "entry"]).current_dir(&r.root).output().unwrap();
    assert_eq!(o.status.code(), Some(3));
    assert!(String::from_utf8_lossy(&o.stderr).contains("state: UNAVAILABLE"));
}

#[test]
fn a_query_straight_after_stop_gets_a_fresh_daemon_not_a_race_with_the_dying_one() {
    // `stop` used to return while the daemon still held its lock; the next client's new daemon
    // then found the lock held, exited, and the client waited out its timeout for a socket that
    // never came.
    let d = Daemon::new();
    let r = repo();
    for round in 0..12 {
        let out = d.stdout(&r.root, &["find", "entry"]);
        assert!(out.contains("entry (function)"), "round {round}: {out}");
        d.stdout(&r.root, &["stop"]);
    }
}
